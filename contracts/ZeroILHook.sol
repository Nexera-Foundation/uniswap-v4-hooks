// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {LiquidityAmountsExtra} from "./utils/LiquidityAmountsExtra.sol";
import {SafeCallback} from "./utils/SafeCallback.sol";

/**
 * - Users can add liquidity
 *   - directly to the Pool
 *   - via the Hook - in this case they receive ERC1155 token issued by the Hook which represents their part of Hook's liquidity and reserves in the Pool
 * - Hook maintains his position in the Pool and some reserves (funds used to compensate IL)
 * - After each swap it verifies the difference between old and new tick (tick represents ratio between Pool assets) to find out if it need to shift it's liquidity position or not yet (distance required to shift is defined on Hook initialization)
 * - If Position shift required, Hook calculates IL between old and new positions. and decides which currency it needs to buy/sell to compensate IL.
 *    - If Hook has reserves in currency it needs to buy, then it removes some liquidity and swaps it.
 *    - Otherwise (if he has reserves in currency it needs to sell) it just swaps it (or if reserve is not enough - withdraws from the Hook's position what is needed)
 */
abstract contract ZeroILHook is IUnlockCallback, BaseHook, SafeCallback, ERC1155, Ownable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for uint128;

    bytes32 private POSITION_SALT = 0; // We are going to have just one position per Pool, so not using Salt

    error InvalidPool();
    error InvalidConfig();
    error NativeCurrencyNotReceived();
    error InvalidUnlockCallbackDataLength();

    enum PoolAction {
        ADD_LIQUIDITY,
        WITHDRAW_LIQUIDITY,
        SHIFT_POSITION,
        COMPENSATE_IL_SWAP
    }

    struct PositionBounds {
        int24 lower;
        int24 upper;
    }

    struct PoolData {
        Currency currency0;
        Currency currency1;
        uint24 fee; // Used for recovering PoolKey from PoolId
        int24 tickSpacing;
        int24 lastKnownTick;
        PositionBounds currentPosition;
        int24 zeroILTick; // Tick when all IL was compensated
        PositionBounds zeroILPosition; // Position at a tick when all IL was compensated
        bool zeroILReserveZeroSide; // Reserve accumalated after IL compensation swap is in currency0 (true) or currency1 (false)
        uint256 zeroILReserveAmount; // Reserve amount accumalated after IL compensation swap
    }

    struct PoolConfig {
        int24 desiredPositionRangeTickLower; // Distance from current tick to lower bound of desired position
        int24 desiredPositionRangeTickUpper; // Distance from current tick to upper bound of desired position
        int24 shiftPositionLowerTickDistance; // If distance between current tick and hookPositionTickLower is more than this, position should be shifted
        int24 shiftPositionUpperTickDistance; // If distance between current tick and hookPositionTickLower is more than this, position should be shifted
        uint256 il0percentageToSwapX96; // Percentage of token0 amount of IL, which triggers swap, encoded so that FixedPoint96.Q96 = 100%
        uint256 il1percentageToSwapX96; // Percentage of token1 amount of IL, which triggers swap, encoded so that FixedPoint96.Q96 = 100%
    }

    mapping(PoolId => PoolData) public poolData;
    mapping(PoolId => PoolConfig) public poolConfig;

    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    /**
     * @notice Executes IL compensation swap
     * @dev Called by the ZeroILHook when already inside the lock.
     * @dev If this function requires funds transferred to or from the PoolManager, it SHOULD do it itself: call IPoolManager.settle() or IPoolManager.take()
     * @param poolId Id of the pool
     * @param zeroForOne Defines swap direction: if true, sell token0 to buy token1
     * @param amount amount to sell
     */
    function _executeCompensateILSwapWhileUnlocked(PoolId poolId, bool zeroForOne, uint256 amount) internal virtual returns (BalanceDelta swapDelta);

    function setConfig(PoolKey calldata key, PoolConfig calldata config) external onlyOwner {
        PoolId poolId = key.toId();
        if (config.desiredPositionRangeTickLower == 0 && config.desiredPositionRangeTickUpper == 0) revert InvalidConfig();
        //TODO Verify correct tickSpacing: all tick values should be multiple of key.tickSpacing
        poolConfig[poolId] = config;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * @notice The hook called after the state of a pool is initialized
     * param sender The initial msg.sender for the initialize call
     * @param key The key for the pool being initialized
     * param sqrtPriceX96 The sqrt(price) of the pool as a Q64.96
     * param tick The current tick after the state of a pool is initialized
     * @return bytes4 The function selector for the hook
     */
    function _afterInitialize(address /*sender*/, PoolKey calldata key, uint160 /*sqrtPriceX96*/, int24 /*tick*/) internal override returns (bytes4) {
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
        return IHooks.afterInitialize.selector;
    }

    /**
     * @notice The hook called after a swap
     * param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * param params The parameters for the swap
     * param delta The amount owed to the locker (positive) or owed to the pool (negative)
     * param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
     * @return bytes4 The function selector for the hook
     * @return int128 The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     */
    function _afterSwap(
        address /*sender*/,
        PoolKey calldata key,
        SwapParams calldata /*params*/,
        BalanceDelta /*delta*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        pd.lastKnownTick = _getTick(poolId);

        if (_isPositionShiftRequired(pd, pc, pd.lastKnownTick)) {
            bytes memory actionData = _encodePoolAction(PoolAction.SHIFT_POSITION, abi.encode(poolId, pd.lastKnownTick));
            poolManager.unlock(actionData);
        }

        (uint256 il0, uint256 il1, uint256 il0PercentageX96, uint256 il1PercentageX96) = _calculateIL(
            pd.zeroILTick,
            pd.lastKnownTick,
            _getHookLiquidity(poolId),
            pd.zeroILPosition,
            pd.currentPosition
        );

        if (il0PercentageX96 >= pc.il0percentageToSwapX96) {
            _compensateILSwap(poolId, pd, false, il0);
        }
        if (il1PercentageX96 >= pc.il1percentageToSwapX96) {
            _compensateILSwap(poolId, pd, true, il1);
        }

        return (IHooks.afterSwap.selector, 0);
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
            amountToAddToReserve = FullMath.mulDiv(pd.zeroILReserveZeroSide ? amount0 : amount1, liquidityToAddToReserve, liquidityProvided);
        }
        bytes memory actionData = _encodePoolAction(PoolAction.ADD_LIQUIDITY, abi.encode(poolId, liquidityToAddToPosition, amountToAddToReserve, _msgSender()));
        poolManager.unlock(actionData);

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
        uint128 liquidityToWithdrawFromReserve;
        uint128 liquidityToWithdrawFromPosition;
        uint256 amountToWithdrawFromReserve;
        if (liquidityInReserve == 0) {
            liquidityToWithdrawFromPosition = uint128(amount.toInt128());
        } else {
            liquidityToWithdrawFromReserve = uint128(FullMath.mulDiv(amount, liquidityInReserve, hookPositionLiquidity));
            liquidityToWithdrawFromPosition = uint128(amount.toInt128()) - liquidityToWithdrawFromReserve;
            amountToWithdrawFromReserve = FullMath.mulDiv(pd.zeroILReserveAmount, liquidityToWithdrawFromReserve, liquidityInReserve);
        }

        _burn(_msgSender(), uint256(PoolId.unwrap(poolId)), amount);

        bytes memory actionData = _encodePoolAction(
            PoolAction.WITHDRAW_LIQUIDITY,
            abi.encode(poolId, liquidityToWithdrawFromPosition, amountToWithdrawFromReserve, _msgSender())
        );
        poolManager.unlock(actionData);
    }

    function _encodePoolAction(PoolAction action, bytes memory arguments) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(action), arguments);
    }

    function _decodePoolAction(bytes calldata data) private pure returns (PoolAction action, bytes calldata arguments) {
        require(data.length > 0, InvalidUnlockCallbackDataLength());
        return (PoolAction(uint8(data[0])), data[1:]);
    }

    function _unlockCallback(bytes calldata data) internal virtual override returns (bytes memory) {
        (PoolAction action, bytes calldata arguments) = _decodePoolAction(data);
        if (action == PoolAction.ADD_LIQUIDITY) {
            _addLiquidityWhileUnlocked(arguments);
        } else if (action == PoolAction.WITHDRAW_LIQUIDITY) {
            _withdrawLiquidityWhileUnlocked(arguments);
        } else if (action == PoolAction.SHIFT_POSITION) {
            _shiftPositionWhileUnlocked(arguments);
        }
        /*if(action == PoolAction.COMPENSATE_IL_SWAP)*/
        else {
            _compensateILSwapWhileUnlocked(arguments);
        }
        return "";
    }

    /**
     * @notice Called by the PoolManager during execution of the `lock()` - see `addLiquidity()`
     * param poolId Id of the pool
     * param liquidityPositionDelta Amount of liquidity to add to Hook's position
     * param amountToReserve Amount to add to reserve
     * param spender Address of the user who pays for this (who adds liquidity)
     */
    function _addLiquidityWhileUnlocked(bytes calldata arguments) internal virtual {
        (PoolId poolId, uint128 liquidityPositionDelta, uint256 amountToReserve, address spender) = abi.decode(arguments, (PoolId, uint128, uint256, address));

        PoolData storage pd = poolData[poolId];
        PoolKey memory key = _recoverPoolKey(pd);
        // TODO Find out if we need to use fees delta returned by `modifyLiquidity()`
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pd.currentPosition.lower,
                tickUpper: pd.currentPosition.upper,
                liquidityDelta: liquidityPositionDelta.toInt256(),
                salt: POSITION_SALT
            }),
            ""
        );
        if (amountToReserve != 0) {
            if (pd.zeroILReserveZeroSide) {
                poolManager.mint(address(this), pd.currency0.toId(), amountToReserve);
                delta = delta + toBalanceDelta(amountToReserve.toInt128(), 0);
            } else {
                poolManager.mint(address(this), pd.currency1.toId(), amountToReserve);
                delta = delta + toBalanceDelta(0, amountToReserve.toInt128());
            }
        }

        _settleZeroILReserveAmount(pd);
        _settleDeltas(key, spender);
    }

    /**
     * @notice Called by the PoolManager during execution of the `lock()` - see `addLiquidity()`
     * param poolId Id of the pool
     * param liquidityPositionDelta Amount of liquidity to remove
     * param amountFromReserve Amount of reserved tokens to send to sender
     * param spender Address of the user who pays Hook tokens for this (who removes liquidity)
     */
    function _withdrawLiquidityWhileUnlocked(bytes calldata arguments) internal virtual {
        (PoolId poolId, uint128 liquidityPositionDelta, uint256 amountFromReserve, address spender) = abi.decode(
            arguments,
            (PoolId, uint128, uint256, address)
        );
        PoolData storage pd = poolData[poolId];
        PoolKey memory key = _recoverPoolKey(pd);
        // TODO find out if we need to use fees delta returned by `modifyLiquidity()`
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pd.currentPosition.lower,
                tickUpper: pd.currentPosition.upper,
                liquidityDelta: -(liquidityPositionDelta.toInt256()),
                salt: POSITION_SALT
            }),
            ""
        );
        if (pd.zeroILReserveZeroSide) {
            poolManager.burn(address(this), pd.currency0.toId(), amountFromReserve);
            delta = delta - toBalanceDelta(amountFromReserve.toInt128(), 0);
        } else {
            poolManager.burn(address(this), pd.currency1.toId(), amountFromReserve);
            delta = delta - toBalanceDelta(0, amountFromReserve.toInt128());
        }

        _settleZeroILReserveAmount(pd);

        _takeDeltas(key, spender);
    }

    function _shiftPositionWhileUnlocked(bytes calldata arguments) internal virtual {
        (PoolId poolId, int24 newPositionCenter) = abi.decode(arguments, (PoolId, int24));

        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        PoolKey memory key = _recoverPoolKey(pd);
        uint128 positionLiquidity = _getLiquidity(poolId, pd);

        // Calculate new position bounds
        int24 newPositionTickLower = newPositionCenter + pc.desiredPositionRangeTickLower;
        int24 newPositionTickUpper = newPositionCenter + pc.desiredPositionRangeTickUpper;

        if (positionLiquidity == 0) {
            // only update current and zeroIL position bounds and return
            pd.currentPosition.lower = newPositionTickLower;
            pd.currentPosition.upper = newPositionTickUpper;
            pd.zeroILTick = newPositionCenter;
            pd.zeroILPosition.lower = newPositionTickLower;
            pd.zeroILPosition.upper = newPositionTickUpper;
            return;
        }

        // Withdraw liquidity from current position
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pd.currentPosition.lower,
                tickUpper: pd.currentPosition.upper,
                liquidityDelta: -(positionLiquidity.toInt256()),
                salt: POSITION_SALT
            }),
            ""
        );

        // Add liquidity to new position
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: newPositionTickLower,
                tickUpper: newPositionTickUpper,
                liquidityDelta: positionLiquidity.toInt256(),
                salt: POSITION_SALT
            }),
            ""
        );

        // Update position bounds in our storage
        pd.currentPosition.lower = newPositionTickLower;
        pd.currentPosition.upper = newPositionTickUpper;
    }

    function _compensateILSwapWhileUnlocked(bytes calldata arguments) internal virtual {
        (PoolId poolId, bool zeroForOne, uint256 ilAmount) = abi.decode(arguments, (PoolId, bool, uint256));

        PoolData storage pd = poolData[poolId];
        PoolKey memory key = _recoverPoolKey(pd);

        uint128 liquidityToSwap = _getLiquidityForAmount(zeroForOne, ilAmount, pd.currentPosition);
        if (zeroForOne != pd.zeroILReserveZeroSide) {
            // We have reserve in the currency we need to buy
            // So we need to remove liquidity and swap it
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: pd.currentPosition.lower,
                    tickUpper: pd.currentPosition.upper,
                    liquidityDelta: -(liquidityToSwap.toInt256()),
                    salt: POSITION_SALT
                }),
                ""
            );

            _executeCompensateILSwapWhileUnlocked(poolId, zeroForOne, ilAmount);
        } else {
            // We need to spend reserve to buy another currency
            uint128 liquidityInReserve = _getLiquidityForAmount(zeroForOne, pd.zeroILReserveAmount, pd.currentPosition);
            if (liquidityInReserve < liquidityToSwap) {
                //We don't have enough reserve, so need to remove the diff from our position
                uint128 liquidityToRemove = liquidityToSwap - liquidityInReserve;

                // Before swap we need to remove liquidity from position
                poolManager.modifyLiquidity(
                    key,
                    ModifyLiquidityParams({
                        tickLower: pd.currentPosition.lower,
                        tickUpper: pd.currentPosition.upper,
                        liquidityDelta: -(liquidityToRemove.toInt256()),
                        salt: POSITION_SALT
                    }),
                    ""
                );
            }

            (uint256 swapAmount0, uint256 swapAmount1) = _getAmountsForLiquidity(pd.lastKnownTick, pd.currentPosition, liquidityToSwap);

            //We also need to return liquidity we had before swap to our position
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: pd.currentPosition.lower,
                    tickUpper: pd.currentPosition.upper,
                    liquidityDelta: liquidityInReserve.toInt256(),
                    salt: POSITION_SALT
                }),
                ""
            );

            _executeCompensateILSwapWhileUnlocked(poolId, zeroForOne, zeroForOne ? swapAmount0 : swapAmount1);
        }

        // Settle everything
        _settleClaimsDelta(pd.currency0);
        _settleClaimsDelta(pd.currency1);

        _settleZeroILReserveAmount(pd);
    }

    function recoverPoolKey(PoolId poolId) public view returns (PoolKey memory) {
        PoolData storage pd = poolData[poolId];
        PoolConfig storage pc = poolConfig[poolId];
        _requireValidPool(pd, pc);
        return _recoverPoolKey(pd);
    }

    function getPoolId(PoolKey memory key) external pure returns (PoolId) {
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
        bytes memory actionData = _encodePoolAction(PoolAction.COMPENSATE_IL_SWAP, abi.encode(poolId, zeroForOne, ilAmount));
        poolManager.unlock(actionData);
        _afterCompensateILSwap(poolId, pd.lastKnownTick, pd.currentPosition);
    }

    function _afterCompensateILSwap(PoolId poolId, int24 newZeroILTick, PositionBounds memory newZeroILPosition) internal {
        PoolData storage pd = poolData[poolId];
        pd.zeroILTick = newZeroILTick;
        pd.zeroILPosition = newZeroILPosition;
    }

    function _settleDeltas(PoolKey memory key, address spender) internal {
        int256 amount0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 amount1 = poolManager.currencyDelta(address(this), key.currency1);
        _settleDelta(spender, key.currency0, uint128(uint256(-amount0)));
        _settleDelta(spender, key.currency1, uint128(uint256(-amount1)));
    }

    function _takeDeltas(PoolKey memory key, address beneficiary) internal {
        int256 amount0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 amount1 = poolManager.currencyDelta(address(this), key.currency1);
        poolManager.take(key.currency0, beneficiary, uint256(amount0));
        poolManager.take(key.currency1, beneficiary, uint256(amount1));
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
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            // Here we always send from our address and require amount to be paid with `addLiquidity()` call
            if (address(this).balance != amount) revert NativeCurrencyNotReceived();
            poolManager.settle{value: amount}();
        } else {
            if (sender == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(sender, address(poolManager), amount);
            }
            poolManager.settle();
        }
    }

    /**
     * @notice Return extra currency to the user
     * @param pd Data of the pool
     * @param sender User who initiated the operation
     */
    function _settleSpenderChange(PoolData storage pd, address sender) internal {
        uint256 balance0 = pd.currency0.balanceOfSelf();
        uint256 balance1 = pd.currency1.balanceOfSelf();
        if (balance0 > 0) pd.currency0.transfer(sender, balance0);
        if (balance1 > 0) pd.currency1.transfer(sender, balance1);
    }

    function _settleClaimsDelta(Currency c) internal {
        int256 delta = poolManager.currencyDelta(address(this), c); // Delta is positive when we owe to the pool
        if (delta > 0) {
            poolManager.burn(address(this), c.toId(), uint256(delta));
        } else {
            poolManager.mint(address(this), c.toId(), uint256(-delta));
        }
    }

    function _settleZeroILReserveAmount(PoolData storage pd) internal {
        Currency c = pd.zeroILReserveZeroSide ? pd.currency0 : pd.currency1;
        pd.zeroILReserveAmount = poolManager.balanceOf(address(this), c.toId());
    }

    function _calculateAddLiquidityAmount(PoolId poolId, PoolData storage pd, uint256 amount0, uint256 amount1) internal view returns (uint128) {
        return
            LiquidityAmounts.getLiquidityForAmounts(
                _getSqrtPriceX96(poolId), // TODO maybe we can calculate this from pd.lastKnownTick
                TickMath.getSqrtPriceAtTick(pd.currentPosition.lower),
                TickMath.getSqrtPriceAtTick(pd.currentPosition.upper),
                amount0,
                amount1
            );
    }

    function _calculateLiquidityInReserve(PoolId poolId, PoolData storage pd) internal view returns (uint128) {
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
        int24 startTick,
        int24 currentTick,
        uint128 liquidity,
        PositionBounds memory startPosition,
        PositionBounds memory currentPosition
    ) internal pure returns (uint256 il0, uint256 il1, uint256 il0percentageX96, uint256 il1percentageX96) {
        (uint256 startAmount0, uint256 startAmount1) = _getAmountsForLiquidity(startTick, startPosition, liquidity);
        (uint256 currentAmount0, uint256 currentAmount1) = _getAmountsForLiquidity(currentTick, currentPosition, liquidity);

        il0 = (startAmount0 > currentAmount0) ? (startAmount0 - currentAmount0) : 0;
        il0 = (startAmount1 > currentAmount1) ? (startAmount1 - currentAmount1) : 0;
        il0percentageX96 = (il0 > 0) ? FullMath.mulDiv(il0, FixedPoint96.Q96, startAmount0) : 0;
        il1percentageX96 = (il1 > 0) ? FullMath.mulDiv(il1, FixedPoint96.Q96, startAmount1) : 0;
    }

    function _getAmountsForLiquidity(int24 tick, PositionBounds memory bounds, uint128 liquidity) private pure returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = LiquidityAmountsExtra.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(tick),
            TickMath.getSqrtPriceAtTick(bounds.lower),
            TickMath.getSqrtPriceAtTick(bounds.upper),
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
    function _getLiquidityForAmount(bool zeroForOne, uint256 amount, PositionBounds memory bounds) private pure returns (uint128) {
        if (zeroForOne) {
            return LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(bounds.lower), TickMath.getSqrtPriceAtTick(bounds.upper), amount);
        } else {
            return LiquidityAmounts.getLiquidityForAmount0(TickMath.getSqrtPriceAtTick(bounds.lower), TickMath.getSqrtPriceAtTick(bounds.upper), amount);
        }
    }

    function _isPositionShiftRequired(PoolData storage pd, PoolConfig storage pc, int24 currentTick) private view returns (bool) {
        int24 shiftLimitLower = pd.currentPosition.lower + pc.shiftPositionLowerTickDistance;
        int24 shiftLimitUpper = pd.currentPosition.upper + pc.shiftPositionUpperTickDistance;
        return (currentTick <= shiftLimitLower) || (currentTick >= shiftLimitUpper);
    }

    function _getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick, , ) = poolManager.getSlot0(poolId);
    }

    function _getSqrtPriceX96(PoolId poolId) private view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
    }

    function _getHookLiquidity(PoolId poolId) private view returns (uint128 liquidity) {
        PoolData storage pd = poolData[poolId];
        return _getLiquidity(poolId, pd);
    }

    function _getLiquidity(PoolId poolId, PoolData storage pd) private view returns (uint128 liquidity) {
        liquidity = poolManager.getPositionLiquidity(
            poolId,
            Position.calculatePositionKey(address(this), pd.currentPosition.lower, pd.currentPosition.upper, POSITION_SALT)
        );
    }

    function _recoverPoolKey(PoolData storage pd) internal view returns (PoolKey memory) {
        return PoolKey({currency0: pd.currency0, currency1: pd.currency1, fee: pd.fee, tickSpacing: pd.tickSpacing, hooks: this});
    }

    /**
     * Verifies pool is initialized
     * @param pd PoolData of the pool to check
     */
    function _requireValidPool(PoolData storage pd, PoolConfig storage pc) private view {
        // If pool is not initialized currency1 will be zero
        // currency0 can be zero for initialized pool with NATIVE currency
        if (Currency.unwrap(pd.currency1) == (address(0))) revert InvalidPool();

        // Desired position "width" should be more than 0, if pool is initialized
        if (pc.desiredPositionRangeTickLower == 0 && pc.desiredPositionRangeTickUpper == 0) revert InvalidPool();
    }
}
