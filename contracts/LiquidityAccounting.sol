// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "./lib/oz-uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "./lib/oz-uniswap-hooks/utils/CurrencySettler.sol";
import {IHookEvents} from "./lib/oz-uniswap-hooks/interfaces/IHookEvents.sol";
import {LiquidityAmountsExtra} from "./utils/LiquidityAmountsExtra.sol";
import {BasePoolHelper} from "./BasePoolHelper.sol";

/**
 * Manages 2 types of liquidity in the Uniswap V4 Pool:
 * - Liquidity in the Position
 * - Liquidity in ERC6909 tokens (used for reserves)
 *
 * This contract is Abstract because it needs to be extended to manage position using provided functions:
 * - _createPosition()
 * - _removePosition()
 */
abstract contract LiquidityAccounting is ERC20, BasePoolHelper, IHookEvents {
    bytes32 constant MANAGED_POSITION_SALT = bytes32(0); // We aer only using one position

    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /**
     * @dev Native currency was not sent with the correct amount.
     */
    error InvalidNativeValue();

    /**
     * @dev Pool was not initialized.
     */
    error PoolNotInitialized();

    /**
     * @dev A liquidity modification order was attempted to be executed after the deadline.
     */
    error ExpiredPastDeadline();

    /**
     * @dev Principal delta of liquidity modification resulted in too much slippage.
     */
    error TooMuchSlippage();

    error ManagedPositionExists();
    error ManagedPositionNotExists();

    struct AddLiquidityParams {
        uint256 amount0Desired; // Desired amount of token0 to provide
        uint256 amount1Desired; // Desired amount of token1 to provide
        uint256 amount0Min; // Min amount of token0 to provide
        uint256 amount1Min; // Min amount of token1 to provide
        uint256 deadline; // Timestamp when order is outdated
    }

    struct RemoveLiquidityParams {
        uint256 shares; // Shares to burn
        uint256 amount0Min; // Min amount of token0 to receive
        uint256 amount1Min; // Min amount of token1 to receive
        uint256 deadline; // Timestamp when order is outdated
    }

    struct ManagedPosition {
        bytes32 key; // Key is calculated by Position.calculatePositionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        int24 tickLower;
        int24 tickUpper;
    }


    ManagedPosition public position;

    /**
     * @dev Ensure the deadline of a liquidity modification request is not expired.
     *
     * @param deadline Deadline of the request, passed in by the caller.
     */
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function reservesBalances() public view returns (uint256 balance0, uint256 balance1) {
        balance0 = poolKey.currency0.balanceOf(address(this));
        balance1 = poolKey.currency0.balanceOf(address(this));
        // TODO Solve: The code bellow looks incorrect because we have to settle all debts before operation can be complete. But I don't know...
        // balance0 = IERC6909Claims(address(_poolManager)).balanceOf(address(this), pk.currency0.toId());
        // balance1 = IERC6909Claims(address(_poolManager)).balanceOf(address(this), pk.currency1.toId());
    }

    /**
     * @notice Adds liquidity to the hook's pool.
     *
     * @dev To cover all possible scenarios, `msg.sender` should have already given the hook an allowance
     * of at least amount0Desired/amount1Desired on token0/token1. Always adds assets at the ideal ratio,
     * according to the price when the transaction is executed.
     *
     * NOTE: The `amount0Min` and `amount1Min` parameters are relative to the principal delta, which excludes
     * fees accrued from the liquidity modification delta.
     *
     * @param params The parameters for the liquidity addition.
     * @return delta The principal delta of the liquidity addition.
     * @return shares Shares minted
     */
    function addLiquidity(
        AddLiquidityParams calldata params
    ) external payable virtual ensure(params.deadline) returns (BalanceDelta delta, uint256 shares) {
        uint160 sqrtPriceX96 = _currentSqrtPriceX96();

        // Revert if msg.value is non-zero but currency0 is not native
        bool isNative = poolKey.currency0.isAddressZero();
        if (!isNative && msg.value > 0) revert InvalidNativeValue();

        // Get the liquidity modification parameters and the amount of liquidity shares to mint
        ModifyLiquidityParams memory modifyParams;
        (modifyParams, shares) = _getAddLiquidity(sqrtPriceX96, params);

        // Apply the liquidity modification
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(modifyParams);

        // Mint the liquidity shares to sender
        _mint(_msgSender(), shares);

        // Get the principal delta by subtracting the fee delta from the caller delta (-= is not supported)
        delta = callerDelta - feesAccrued;

        // Check for slippage on principal delta
        uint128 amount0 = uint128(-delta.amount0());
        if (amount0 < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }

        // If the currency0 is native, refund any remaining msg.value that wasn't used based on the principal delta
        if (isNative) {
            // Check that delta amount was covered by msg.value given that settle would be valid if hook can pay for difference
            // It also allows users to provide more native value than the desired amount
            if (msg.value < amount0) revert InvalidNativeValue();
            poolKey.currency0.transfer(msg.sender, msg.value - amount0);
        }
    }

    /**
     * @notice Removes liquidity from the hook's pool.
     * @param params The parameters for the liquidity removal.
     * @return delta The principal delta of the liquidity removal.
     * @return shares Shares burned
     */
    function removeLiquidity(RemoveLiquidityParams calldata params) external virtual ensure(params.deadline) returns (BalanceDelta delta, uint256) {
        uint160 sqrtPriceX96 = _currentSqrtPriceX96();

        // Get the liquidity modification parameters and the amount of liquidity shares to burn
        (ModifyLiquidityParams memory modifyParams, uint256 shares) = _getRemoveLiquidity(sqrtPriceX96, params);

        // Apply the liquidity modification
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _modifyLiquidity(modifyParams);

        // Burn the liquidity shares from the sender
        _burn(_msgSender(), shares);

        // Get the principal delta by subtracting the fee delta from the caller delta (-= is not supported)
        delta = callerDelta - feesAccrued;

        // Check for slippage
        if (uint128(delta.amount0()) < params.amount0Min || uint128(delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    /**
     * @dev Get the liquidity modification to apply for a given liquidity addition,
     * and the amount of liquidity shares would be minted to the sender.
     *
     * @param sqrtPriceX96 The current square root price of the pool.
     * @param params The parameters for the liquidity addition.
     * @return modify The parameters for the liquidity addition.
     * @return shares The liquidity shares to mint.
     *     */
    function _getAddLiquidity(
        uint160 sqrtPriceX96,
        AddLiquidityParams memory params
    ) internal virtual returns (ModifyLiquidityParams memory modify, uint256 shares) {
        // Calculating modify position params
        ManagedPosition memory position_ = position;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(position_.tickLower),
            TickMath.getSqrtPriceAtTick(position_.tickUpper),
            params.amount0Desired,
            params.amount1Desired
        );
        modify = ModifyLiquidityParams({
            liquidityDelta: int256(uint256(liquidityDelta)),
            tickLower: position_.tickLower,
            tickUpper: position_.tickUpper,
            salt: MANAGED_POSITION_SALT
        });

        // Calculating shares
        (uint256 reserve0, uint256 reserve1) = reservesBalances();
        uint256 reservesLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(position_.tickLower),
            TickMath.getSqrtPriceAtTick(position_.tickUpper),
            reserve0,
            reserve1
        );
        uint256 currentLiquidity = _liquidityOfManagedPosition() + reservesLiquidity;
        shares = (totalSupply() * liquidityDelta) / currentLiquidity;
    }

    /**
     * @dev Get the liquidity modification to apply for a given liquidity removal,
     * and the amount of liquidity shares would be burned from the sender.
     *
     * @param sqrtPriceX96 The current square root price of the pool.
     * @param params The parameters for the liquidity removal.
     * @return modify The encoded parameters for the liquidity removal, which must follow the
     * same encoding structure as in `_getAddLiquidity` and `_modifyLiquidity`.
     * @return shares The liquidity shares to burn.
     *
     */
    function _getRemoveLiquidity(
        uint160 sqrtPriceX96,
        RemoveLiquidityParams memory params
    ) internal virtual returns (ModifyLiquidityParams memory modify, uint256 shares) {
        ManagedPosition memory position_ = position;

        // Calculating liquidity of shares
        (uint256 reserve0, uint256 reserve1) = reservesBalances();
        uint256 reservesLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(position_.tickLower),
            TickMath.getSqrtPriceAtTick(position_.tickUpper),
            reserve0,
            reserve1
        );
        uint256 currentLiquidity = _liquidityOfManagedPosition() + reservesLiquidity;
        uint256 liquidityDelta = (params.shares * currentLiquidity) / totalSupply();

        modify = ModifyLiquidityParams({
            liquidityDelta: int256(liquidityDelta), // TODO check for overflow
            tickLower: position_.tickLower,
            tickUpper: position_.tickUpper,
            salt: MANAGED_POSITION_SALT
        });

        // TODO Handle when position does not have enough liquidity (it is in reserves)
    }

    function _currentSqrtPriceX96() internal view returns (uint160) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        return sqrtPriceX96;
    }

    function _liquidityOfManagedPosition() internal view returns (uint128) {
        if (position.key == bytes32(0)) return 0;
        return poolManager.getPositionLiquidity(poolId, position.key);
    }

    function _createPosition(uint128 liquidity, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96) internal virtual {
        _createPosition(liquidity, TickMath.getTickAtSqrtPrice(sqrtPriceAX96), TickMath.getTickAtSqrtPrice(sqrtPriceBX96));
    }

    function _createPosition(uint128 liquidity, int24 tickLower, int24 tickUpper) internal virtual {
        require(position.key == bytes32(0), ManagedPositionExists());
        _modifyLiquidity(
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: MANAGED_POSITION_SALT})
        );
        position = ManagedPosition({
            key: Position.calculatePositionKey(address(this), tickLower, tickUpper, MANAGED_POSITION_SALT),
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }

    function _removePosition() internal virtual returns (uint128 liquidity) {
        ManagedPosition memory position_ = position;
        require(position_.key != bytes32(0), ManagedPositionNotExists());
        liquidity = poolManager.getPositionLiquidity(poolId, position_.key);
        if (liquidity != 0) {
            _modifyLiquidity(
                ModifyLiquidityParams({
                    tickLower: position_.tickLower,
                    tickUpper: position_.tickUpper,
                    liquidityDelta: -int256(uint256(liquidity)),
                    salt: MANAGED_POSITION_SALT
                })
            );
        }
        position = ManagedPosition({key: bytes32(0), tickLower: 0, tickUpper: 0});
    }

    /**
     * @dev Callback from the `PoolManager` when liquidity is modified, either adding or removing.
     * Note: Based on OZ `BaseCustomAccounting.unlockCallback()`
     *
     * @param params `ModifyLiquidityParams` struct
     * @return callerDelta The encoded caller delta.
     * @return feesAccrued The encoded fees accrued delta
     */
    function _unlockedModifyLiquidity(ModifyLiquidityParams memory params) internal override returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        PoolKey memory key = poolKey;

        // Get liquidity modification deltas
        (callerDelta, feesAccrued) = poolManager.modifyLiquidity(key, params, "");

        // Calculate the principal delta
        BalanceDelta principalDelta = callerDelta - feesAccrued;

        // Handle each currency amount based on its sign after applying the liquidity modification
        if (principalDelta.amount0() < 0) {
            // If amount0 is negative, send tokens from the Liquidity Manager to the pool
            key.currency0.settle(poolManager, address(this), uint256(int256(-principalDelta.amount0())), false);
        } else {
            // If amount0 is positive, send tokens from the pool to the Liquidity Manager
            key.currency0.take(poolManager, address(this), uint256(int256(principalDelta.amount0())), false);
        }

        if (principalDelta.amount1() < 0) {
            // If amount1 is negative, send tokens from the Liquidity Manager to the pool
            key.currency1.settle(poolManager, address(this), uint256(int256(-principalDelta.amount1())), false);
        } else {
            // If amount1 is positive, send tokens from the pool to the Liquidity Manager
            key.currency1.take(poolManager, address(this), uint256(int256(principalDelta.amount1())), false);
        }

        // Handle any accrued fees (by default, transfer all fees to the Liquidity Manager)
        _handleAccruedFees(params, callerDelta, feesAccrued);

        emit HookModifyLiquidity(PoolId.unwrap(poolKey.toId()), address(this), principalDelta.amount0(), principalDelta.amount1());

        // Return both deltas so that slippage checks can be done on the principal delta
        return (callerDelta, feesAccrued);
    }

    /**
     * @dev Handle any fees accrued in a liquidity position. By default, this function transfers the tokens to the
     * owner of the liquidity position. However, this function can be overriden to take fees accrued in the position,
     * or any other desired logic.
     * Note: Based on OZ BaseCustomAccounting
     *
     * @param params The encoded `ModifyLiquidityParams` struct: parameters for the liquidity modification.
     * param callerDelta The balance delta from the liquidity modification.
     * @param feesAccrued The balance delta of the fees generated in the liquidity range.
     */
    function _handleAccruedFees(ModifyLiquidityParams memory params, BalanceDelta /*callerDelta*/, BalanceDelta feesAccrued) internal virtual {
        poolKey.currency0.take(poolManager, address(this), uint256(int256(feesAccrued.amount0())), false);
        poolKey.currency1.take(poolManager, address(this), uint256(int256(feesAccrued.amount1())), false);
        // TODO Do we need to do some accounting here?
    }
}
