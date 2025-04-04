// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/BalanceDelta.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/Position.sol";
import "@uniswap/v4-core/src/libraries/SafeCast.sol";
import "./uniswap-v4-periphery/BaseHook.sol";
import "./uniswap-v4-periphery/LiquidityAmounts.sol";

abstract contract ZeroILHook is BaseHook, ERC1155, Ownable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for uint128;

    error InvalidConfig();
    error NativeCurrencyNotReceived();


    struct PositionBounds {
        int24 lower;
        int24 upper;
    }

    struct PoolData {
        Currency currency0;
        Currency currency1;
        uint24 fee;             // Used for recovering PoolKey from PoolId
        int24 tickSpacing;
        int24 lastKnownTick;
        PositionBounds currentPosition;
        int24 zeroILTick;       // Tick when all IL was compensated
        PositionBounds zeroILPosition;  // Position at a tick when all IL was compensated
        bool zeroILReserveZeroSide;     // Reserve accumalated after IL compensation swap is in currency0 (true) or currency1 (false) 
        uint256 zeroILReserveAmount;    // Reserve amount accumalated after IL compensation swap
    }

    struct PoolConfig {
        int24 desiredPositionRangeTickLower;    // Distance from current tick to lower bound of desired position
        int24 desiredPositionRangeTickUpper;    // Distance from current tick to upper bound of desired position
        int24 shiftPositionLowerTickDistance;   // If distance between current tick and hookPositionTickLower is more than this, position should be shifted
        int24 shiftPositionUpperTickDistance;   // If distance between current tick and hookPositionTickLower is more than this, position should be shifted
        uint256 il0percentageToSwapX96;         // Percentage of token0 amount of IL, which triggers swap, encoded so that FixedPoint96.Q96 = 100%
        uint256 il1percentageToSwapX96;         // Percentage of token1 amount of IL, which triggers swap, encoded so that FixedPoint96.Q96 = 100%
    }


    mapping(PoolId => PoolData) public poolData;
    mapping(PoolId => PoolConfig) public poolConfig;

    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {
    }

    /**
     * @notice Executes IL compensation swap
     * @dev Called by the ZeroILHook when already inside the lock.
     * @dev If this function requires funds transferred to or from the PoolManager, it SHOULD do it itself: call IPoolManager.settle() or IPoolManager.take()
     * @param poolId Id of the pool
     * @param zeroForOne Defines swap direction: if true, sell token0 to buy token1
     * @param amount amount to sell
     */
    function executeCompensateILSwapInsideLock(PoolId poolId, bool zeroForOne, uint256 amount) internal virtual;

    function setConfig(PoolKey calldata key, PoolConfig calldata config) external onlyOwner {
        PoolId poolId = key.toId();
        if(config.desiredPositionRangeTickLower == 0 && config.desiredPositionRangeTickUpper == 0) revert InvalidConfig();
        //TODO Verify correct tickSpacing: all tick values should be multiple of key.tickSpacing
        poolConfig[poolId] = config;
    }

    /**
     * @notice Defines the hook calls which should be triggered by the PoolManager
     */
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    /**
    * @notice The hook called after the state of a pool is initialized
    * param sender The initial msg.sender for the initialize call
    * @param key The key for the pool being initialized
    * param sqrtPriceX96 The sqrt(price) of the pool as a Q64.96
    * param tick The current tick after the state of a pool is initialized
    * param hookData Arbitrary data handed into the PoolManager by the initializer to be be passed on to the hook
    * @return bytes4 The function selector for the hook
    */
    function afterInitialize(address /*sender*/, PoolKey calldata key, uint160 /*sqrtPriceX96*/, int24 /*tick*/, bytes calldata /*hookData*/) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId]; // This should be set before initializing Pool
        pd.currency0 = key.currency0;
        pd.currency1 = key.currency1;
        pd.fee = key.fee;
        pd.tickSpacing = key.tickSpacing;
        pd.lastKnownTick = _getTick(poolId);
        pd.currentPosition.lower = pd.lastKnownTick + pc.desiredPositionRangeTickLower;
        pd.currentPosition.upper = pd.lastKnownTick + pc.desiredPositionRangeTickUpper;
        return ZeroILHook.afterInitialize.selector;
    }

    /**
    * @notice The hook called after a swap
    * param sender The initial msg.sender for the swap call
    * @param key The key for the pool
    * param params The parameters for the swap
    * param delta The amount owed to the locker (positive) or owed to the pool (negative)
    * param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
    * @return bytes4 The function selector for the hook     
    */
    function afterSwap(address /*sender*/, PoolKey calldata key, IPoolManager.SwapParams calldata /*params*/, BalanceDelta /*delta*/, bytes calldata /*hookData*/) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        pd.lastKnownTick = _getTick(poolId);


        if(_isPositionShiftRequired(pd, pc, pd.lastKnownTick)) {
            bytes memory lockInternalCall = abi.encodeCall(this.shiftPositionInsideLock, (poolId, pd.lastKnownTick));
            poolManager.lock(lockInternalCall);
        }
        
        (uint256 il0, uint256 il1, uint256 il0PercentageX96, uint256 il1PercentageX96) = _calculateIL(
            pd.zeroILTick, pd.lastKnownTick, _getHookLiquidity(poolId),
            pd.zeroILPosition,
            pd.currentPosition
        );
        
        if(il0PercentageX96 >= pc.il0percentageToSwapX96) {
            _compensateILSwap(poolId, pd, false, il0);
        }
        if(il1PercentageX96 >= pc.il1percentageToSwapX96) {
            _compensateILSwap(poolId, pd, true, il1);
        }

        return ZeroILHook.afterSwap.selector;
    }


    /**
     * @notice Adds liquidity to the specific pool
     * @param poolId Id of the pool
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     */
    function addLiquidity(PoolId poolId, uint256 amount0, uint256 amount1) external payable {
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        _requireValidPool(pd, pc);

        // We don't need to transfer Currencies now, because it will be done inside addLiquidityInsideLock with _settleDeltas()
        //uint256 amountToReserve = (pd.zeroILReserveZeroSide?amount0:amount1) / pd.zeroILReserveAmount 


        // When adding liquidity, we also put part of it to Reserve, proportional to current reserve
        uint128 liquidityInReserve = _calculateLiquidityInReserve(poolId, pd);
        uint128 hookPositionLiquidity = _getHookLiquidity(poolId);
        uint128 liquidityProvided = _calculateAddLiquidityAmount(poolId, pd, amount0, amount1);

        uint128 liquidityToAddToReserve;
        uint128 liquidityToAddToPosition;
        uint256 amountToAddToReserve;
        if (hookPositionLiquidity == 0 && liquidityInReserve == 0) {
            liquidityToAddToPosition = liquidityProvided;
        } else {
            liquidityToAddToReserve = uint128(FullMath.mulDiv(liquidityProvided, liquidityInReserve, hookPositionLiquidity));
            liquidityToAddToPosition = liquidityProvided - liquidityToAddToReserve;
            amountToAddToReserve = FullMath.mulDiv(pd.zeroILReserveZeroSide?amount0:amount1, liquidityToAddToReserve, liquidityProvided);
        }
        bytes memory lockInternalCall = abi.encodeCall(this.addLiquidityInsideLock, (poolId, liquidityToAddToPosition, amountToAddToReserve, _msgSender()));
        poolManager.lock(lockInternalCall);

        _settleSpenderChange(pd, _msgSender()); // TODO: not shure if this is required, but just for the case when pool takes less than expected, maybe donate to pool instead

        _mint(_msgSender(), uint256(PoolId.unwrap(poolId)), uint256(liquidityProvided), "");
    }

    function withdrawLiquidity(PoolId poolId, uint256 amount) external {
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        _requireValidPool(pd, pc);

        // When withdrawing liquidity, we also withdrawing part of it from Reserve, proportional to current reserve
        uint128 liquidityInReserve = _calculateLiquidityInReserve(poolId, pd);
        uint128 hookPositionLiquidity = _getHookLiquidity(poolId);
        uint128 liquidityToWihdrawFromReserve;
        uint128 liquidityToWithdrawFromPosition;
        uint256 amountToWithdrawFromReserve;
        if (liquidityInReserve == 0) {
            liquidityToWithdrawFromPosition = uint128(amount.toInt128());
        } else {
            liquidityToWihdrawFromReserve = uint128(FullMath.mulDiv(amount, liquidityInReserve, hookPositionLiquidity));
            liquidityToWithdrawFromPosition = uint128(amount.toInt128()) - liquidityToWihdrawFromReserve;
            amountToWithdrawFromReserve = FullMath.mulDiv(pd.zeroILReserveAmount, liquidityToWihdrawFromReserve, liquidityInReserve);
        }

        _burn(_msgSender(), uint256(PoolId.unwrap(poolId)), amount);
        
        bytes memory lockInternalCall = abi.encodeCall(this.withdrawLiquidityInsideLock, (poolId, liquidityToWithdrawFromPosition, amountToWithdrawFromReserve, _msgSender()));
        poolManager.lock(lockInternalCall);
    }


    /**
     * @notice Called py the PoolManager during execution of the `lock()` - see `addLiquidity()`
     * @param poolId Id of the pool
     * @param liquidityPositionDelta Amount of liquidity to add to Hook's position
     * @param amountToReserve Amount to add to reserve
     * @param spender Address of the user who pays for this (who adds liquidity)
     */
    function addLiquidityInsideLock(PoolId poolId, uint128 liquidityPositionDelta, uint256 amountToReserve, address spender) external selfOnly {
        PoolData storage pd = poolData[poolId];
        PoolKey memory key = _recoverPoolKey(pd);
        BalanceDelta delta = poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams({
            tickLower: pd.currentPosition.lower,
            tickUpper: pd.currentPosition.upper,
            liquidityDelta: liquidityPositionDelta.toInt256()
        }), "");
        if (amountToReserve != 0) {
            if(pd.zeroILReserveZeroSide){
                poolManager.mint(pd.currency0, address(this), amountToReserve);
                delta = delta + toBalanceDelta(amountToReserve.toInt128(), 0);
            } else {
                poolManager.mint(pd.currency1, address(this), amountToReserve);
                delta = delta + toBalanceDelta(0, amountToReserve.toInt128());
            }
        }

        _settleZeroILReserveAmount(pd);

        _settleDeltas(key, spender, delta);
    }

    /**
     * @notice Called py the PoolManager during execution of the `lock()` - see `addLiquidity()`
     * @param poolId Id of the pool
     * @param liquidityPositionDelta Amount of liquidity to remove
     * @param amountFromReserve Amount of reserved tokens to send to sepnder
     * @param spender Address of the user who pays Hook tokens for this (who removes liquidity)
     */
    function withdrawLiquidityInsideLock(PoolId poolId, uint128 liquidityPositionDelta, uint256 amountFromReserve, address spender) external selfOnly {
        PoolData storage pd = poolData[poolId];
        PoolKey memory key = _recoverPoolKey(pd);
        BalanceDelta delta = poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams({
            tickLower: pd.currentPosition.lower,
            tickUpper: pd.currentPosition.upper,
            liquidityDelta: -(liquidityPositionDelta.toInt256())
        }), "");
        if(pd.zeroILReserveZeroSide){
            poolManager.burn(pd.currency0, amountFromReserve);
            delta = delta - toBalanceDelta(amountFromReserve.toInt128(), 0);
        } else {
            poolManager.burn(pd.currency1, amountFromReserve);
            delta = delta - toBalanceDelta(0, amountFromReserve.toInt128());
        }

        _settleZeroILReserveAmount(pd);

        _takeDeltas(key, spender, delta);
    }

    function shiftPositionInsideLock(PoolId poolId, int24 newPositionCenter) external selfOnly {
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        PoolKey memory key = _recoverPoolKey(pd);
        Position.Info memory position = poolManager.getPosition(poolId, address(this), pd.currentPosition.lower, pd.currentPosition.upper);

        // Calculate new position bounds
        int24 newPositionTickLower = newPositionCenter + pc.desiredPositionRangeTickLower;
        int24 newPositionTickUpper = newPositionCenter + pc.desiredPositionRangeTickUpper;

        if(position.liquidity == 0) {
            // only update current and zeroIL position bounds and return
            pd.currentPosition.lower = newPositionTickLower;
            pd.currentPosition.upper = newPositionTickUpper;
            pd.zeroILTick = newPositionCenter;
            pd.zeroILPosition.lower = newPositionTickLower;
            pd.zeroILPosition.upper = newPositionTickUpper;
            return;
        }

        // Withdraw liquidity from current position
        poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams({
            tickLower: pd.currentPosition.lower,
            tickUpper: pd.currentPosition.upper,
            liquidityDelta: -(position.liquidity.toInt256())
        }), "");

        // Add liquidity to new position
        poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams({
            tickLower: newPositionTickLower,
            tickUpper: newPositionTickUpper,
            liquidityDelta: position.liquidity.toInt256()
        }), "");

        // Update position bounds in our storage
        pd.currentPosition.lower = newPositionTickLower;
        pd.currentPosition.upper = newPositionTickUpper;
    }

    function compensateILSwapInsideLock(PoolId poolId, bool zeroForOne, uint256 ilAmount) external selfOnly {
        PoolData storage pd = poolData[poolId];
        PoolKey memory key = _recoverPoolKey(pd);

        uint128 liquidityToSwap = _getLiquidityForAmount(zeroForOne, ilAmount, pd.currentPosition);
        if(zeroForOne != pd.zeroILReserveZeroSide) {
            // We have reserve in the currency we need to buy
            // So we need to remove liquidity and swap it
            poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams({
                tickLower: pd.currentPosition.lower,
                tickUpper: pd.currentPosition.upper,
                liquidityDelta: -(liquidityToSwap.toInt256())
            }), "");

            executeCompensateILSwapInsideLock(poolId, zeroForOne, ilAmount);
        } else {
            // We need to spend reserve to buy another currency
            uint128 liquidityInReserve = _getLiquidityForAmount(zeroForOne, pd.zeroILReserveAmount, pd.currentPosition);
            if(liquidityInReserve < liquidityToSwap) {
                //We don't have enough reserve, so need to remove the diff from our position
                uint128 liquidityToRemove = liquidityToSwap - liquidityInReserve;

                // BeforeSwap we need to remove liquidity from position
                poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams({
                    tickLower: pd.currentPosition.lower,
                    tickUpper: pd.currentPosition.upper,
                    liquidityDelta: -(liquidityToRemove.toInt256())
                }), "");
            }

            (uint256 swapAmount0, uint256 swapAmount1) = _getAmountsForLiquidity(pd.lastKnownTick, pd.currentPosition, liquidityToSwap);
            
            //We also need to return liquidity we had before swap to our position
            poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams({
                tickLower: pd.currentPosition.lower,
                tickUpper: pd.currentPosition.upper,
                liquidityDelta: liquidityInReserve.toInt256()
            }), "");

            executeCompensateILSwapInsideLock(poolId, zeroForOne, zeroForOne?swapAmount0:swapAmount1);
        }

        // Settle everything
        _settleClaimsDelta(pd.currency0);
        _settleClaimsDelta(pd.currency1);
        
        _settleZeroILReserveAmount(pd);
    }

    function recoverPoolKey(PoolId poolId) public view returns(PoolKey memory) {
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        _requireValidPool(pd, pc);
        return _recoverPoolKey(pd);
    }

    function getPoolId(PoolKey memory key) external pure returns(PoolId) {
        return key.toId();
    }


    /**
     * @notice Prepares and executes the swap to compensate IL
     * @param poolId Id of the pool
     * @param pd Reference to PoolData struct
     * @param zeroForOne Direction of the swap (true: sell currency0, false: sell currency1)
     * @param ilAmount Amount we've "lost" because of IL
     */
    function _compensateILSwap(PoolId poolId, PoolData storage pd, bool zeroForOne, uint256 ilAmount) internal {
        bytes memory lockInternalCall = abi.encodeCall(this.compensateILSwapInsideLock, (poolId, zeroForOne, ilAmount));
        poolManager.lock(lockInternalCall);
        _afterCompensateILSwap(poolId, pd.lastKnownTick, pd.currentPosition);    
    }


    function _afterCompensateILSwap(PoolId poolId, int24 newZeroILTick, PositionBounds memory newZeroILPosition) internal {
        PoolData storage pd = poolData[poolId];
        pd.zeroILTick = newZeroILTick;
        pd.zeroILPosition = newZeroILPosition;
    }

    function _settleDeltas(PoolKey memory key, address spender, BalanceDelta delta) internal {
        _settleDelta(spender, key.currency0, uint128(delta.amount0()));
        _settleDelta(spender, key.currency1, uint128(delta.amount1()));
    }

    function _takeDeltas(PoolKey memory key, address beneficiary, BalanceDelta delta) internal {
        poolManager.take(key.currency0, beneficiary, uint256(uint128(-delta.amount0())));
        poolManager.take(key.currency1, beneficiary, uint256(uint128(-delta.amount1())));
    }

    /**
     * @notice Transfers Currency from user to the PoolManager
     * @dev for NATIVE currency it should be transferred from user to Hook first
     * @dev for ERC20 currency an approval for the Hook to spend User's tokens is required
     * @param sender Address of the user
     * @param currency Currency to settle
     * @param amount Amount to settle
     */
    function _settleDelta(address sender, Currency currency, uint128 amount) internal {
        if (currency.isNative()) {
            // Here we always send from our address and require amount to pe paid with `addLiquidity()` call
            if(address(this).balance != amount) revert NativeCurrencyNotReceived();
            poolManager.settle{value: amount}(currency);
        } else {
            if (sender == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(sender, address(poolManager), amount);
            }
            poolManager.settle(currency);
        }
    }

    /**
     * @notice Returnextra currency to the user
     * @param pd Data of the pool
     * @param sender user who initiated the operation
     */
    function _settleSpenderChange(PoolData storage pd, address sender) internal {
        uint256 balance0 = pd.currency0.balanceOfSelf();
        uint256 balance1 = pd.currency1.balanceOfSelf();
        if(balance0 > 0) pd.currency0.transfer(sender, balance0);
        if(balance1 > 0) pd.currency1.transfer(sender, balance1);
    }

    function _settleClaimsDelta(Currency c) internal{
        int256 delta = poolManager.currencyDelta(address(this), c); // Delta is postiv when we owe to the pool
        if(delta > 0) {
            poolManager.burn(c, uint256(delta));
        } else {
            poolManager.mint(c, address(this), uint256(-delta));
        }
    }

    function _settleZeroILReserveAmount(PoolData storage pd) internal {
        pd.zeroILReserveAmount = poolManager.balanceOf(address(this), pd.zeroILReserveZeroSide?pd.currency0:pd.currency1);
    }

    function _calculateAddLiquidityAmount(PoolId poolId, PoolData storage pd, uint256 amount0, uint256 amount1) internal view returns(uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            _getSqrtPriceX96(poolId), // TODO maybe we can calculate this from pd.lastKnownTick
            TickMath.getSqrtRatioAtTick(pd.currentPosition.lower),
            TickMath.getSqrtRatioAtTick(pd.currentPosition.upper),
            amount0,
            amount1
        );        
    }

    function _calculateLiquidityInReserve(PoolId poolId, PoolData storage pd) internal view returns(uint128) {
        (uint256 amount0, uint256 amount1) = pd.zeroILReserveZeroSide ? (pd.zeroILReserveAmount, uint256(0)) : (uint256(0), pd.zeroILReserveAmount);
        return _calculateAddLiquidityAmount(poolId, pd, amount0, amount1);
    }

    /**
     * @notice Calculates IL from start position data, current position data and liquidity
     * @return il0 Amount of token0 which is "lost" because of position change
     * @return il1 Amount of token1 which is "lost" because of position change
     * @return il0percentageX96 il0 as percentage on token0 start amount, encoded so that FixedPoint96.Q96 = 100%, 0 if il0 is negative
     * @return il1percentageX96 il1 as percentage on token1 start amount, encoded so that FixedPoint96.Q96 = 100%, 0 if il1 is negative
     */
    function _calculateIL(
        int24 startTick, int24 currentTick, uint128 liquidity,
        PositionBounds memory startPosition,
        PositionBounds memory currentPosition
    ) internal pure returns (uint256 il0, uint256 il1, uint256 il0percentageX96, uint256 il1percentageX96) {
        (uint256 startAmount0, uint256 startAmount1) = _getAmountsForLiquidity(startTick, startPosition, liquidity);
        (uint256 currentAmount0, uint256 currentAmount1) = _getAmountsForLiquidity(currentTick, currentPosition, liquidity);

        il0 = (startAmount0 > currentAmount0) ? (startAmount0 - currentAmount0):0;
        il0 = (startAmount1 > currentAmount1) ? (startAmount1 - currentAmount1):0;
        il0percentageX96 = (il0 > 0)?FullMath.mulDiv(il0, FixedPoint96.Q96, startAmount0):0;
        il1percentageX96 = (il1 > 0)?FullMath.mulDiv(il1, FixedPoint96.Q96, startAmount1):0;
    }

    function _getAmountsForLiquidity(int24 tick, PositionBounds memory bounds, uint128 liquidity) private pure returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(tick), 
            TickMath.getSqrtRatioAtTick(bounds.lower), 
            TickMath.getSqrtRatioAtTick(bounds.upper), 
            liquidity
        );
    }

    /**
     * @notice Return liquidity we need to sell in order to get specified amount
     * @param zeroForOne Direction of the swap (true: sell currency0, false: sell currency1)
     * @param amount Amount to get
     * @param bounds Position bounds
     * @return Liquidity needed
     */
    function _getLiquidityForAmount(bool zeroForOne, uint256 amount, PositionBounds memory bounds) private pure returns (uint128){
        if (zeroForOne) {
            return LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtRatioAtTick(bounds.lower), 
                TickMath.getSqrtRatioAtTick(bounds.upper), 
                amount
            );
        } else {
            return LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtRatioAtTick(bounds.lower), 
                TickMath.getSqrtRatioAtTick(bounds.upper), 
                amount
            );
        }
    }

    function _isPositionShiftRequired(PoolData storage pd, PoolConfig storage pc, int24 currentTick) private view returns(bool) {
        int24 shiftLimitLower = pd.currentPosition.lower + pc.shiftPositionLowerTickDistance;
        int24 shiftLimitUpper = pd.currentPosition.upper + pc.shiftPositionUpperTickDistance;
        return (currentTick <= shiftLimitLower) || (currentTick >= shiftLimitUpper);
    }

    function _getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function _getSqrtPriceX96(PoolId poolId) private view returns (uint160 sqrtPriceX96)  {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    function _getHookLiquidity(PoolId poolId) private view returns (uint128 liquidity) {
        PoolData storage pd = poolData[poolId];
        Position.Info memory position = poolManager.getPosition(poolId, address(this), pd.currentPosition.lower, pd.currentPosition.upper);
        liquidity = position.liquidity;
    }


    function _recoverPoolKey(PoolData storage pd) internal view returns(PoolKey memory){
        return PoolKey({
            currency0: pd.currency0,
            currency1: pd.currency1,
            fee: pd.fee,
            tickSpacing: pd.tickSpacing,
            hooks: this
        });
    }

    /**
     * Verifies pool is initialized
     * @param pd PoolData of the pool to check
     */
    function _requireValidPool(PoolData storage pd, PoolConfig storage pc) private view {
        // If pool is not initialized corrency1 will be zero
        // currency0 can be zero for initialized pool with NATIVE currency
        if(Currency.unwrap(pd.currency1) == (address(0))) revert InvalidPool();

        // Desired position "width" should be more than 0, if pool is initialized
        if(pc.desiredPositionRangeTickLower == 0 && pc.desiredPositionRangeTickUpper == 0) revert InvalidPool();
    }
}