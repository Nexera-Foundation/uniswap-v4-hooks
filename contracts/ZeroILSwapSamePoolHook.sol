// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ZeroILHook} from "./ZeroILHook.sol";

contract ZeroILSwapSamePoolHook is ZeroILHook {
    using PoolIdLibrary for PoolKey;

    error NotEnoughLiquidity(PoolId poolId);

    constructor(IPoolManager _poolManager, string memory _uri) ZeroILHook(_poolManager, _uri) Ownable(_msgSender()) {}

    /**
     * @dev Executes IL compensation swap on the provided Uniswap V4 pool
     * @inheritdoc ZeroILHook
     */
    function _executeCompensateILSwapWhileUnlocked(PoolId poolId, bool zeroForOne, uint256 amount) internal override returns (BalanceDelta) {
        PoolKey memory pk = _recoverPoolKey(poolData[poolId]);
        // TODO: Verify implementation above as same as commented varian below.
        // especially check uint256 to int256 conversion
        return _swap(pk, zeroForOne, int256(amount), "");
    }

    /**
     * @notice Execute a swap and return the balance delta
     * @dev if amountSpecified < 0, the swap is exactInput, otherwise exactOutput
     * NOTE: Copied from uniswap/v4-periphery/src/base/BaseV4Quoter.sol
     */
    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal returns (BalanceDelta swapDelta) {
        swapDelta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        // Check that the pool was not illiquid.
        int128 amountSpecifiedActual = (zeroForOne == (amountSpecified < 0)) ? swapDelta.amount0() : swapDelta.amount1();
        if (amountSpecifiedActual != amountSpecified) {
            revert NotEnoughLiquidity(poolKey.toId());
        }
    }

    //
    // uint256 MAX_SWAP_SLIPPAGE_PERCENTAGE_X96 = FixedPoint96.Q96 / 100; //  = 0.1% (100% = FixedPoint96.Q96)
    // /**
    //  * @notice Executes IL compensation swap
    //  * @dev Called by the ZeroILHook when already inside the lock.
    //  * @dev If this function requires funds transferred to or from the PoolManager, it SHOULD do it itself: call IPoolManager.settle() or IPoolManager.take()
    //  * @param poolId Id of the pool
    //  * @param zeroForOne Defines swap direction: if true, sell token0 to buy token1
    //  * @param amount amount to sell
    //  */
    // function executeCompensateILSwapInsideLock(PoolId poolId, bool zeroForOne, uint256 amount) internal override {
    //     PoolKey memory pk = _recoverPoolKey(poolData[poolId]);
    //     (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    //     uint160 priceLimitX96 = uint160(zeroForOne?
    //         currentSqrtPriceX96 - FullMath.mulDiv(currentSqrtPriceX96, MAX_SWAP_SLIPPAGE_PERCENTAGE_X96, FixedPoint96.Q96):
    //         currentSqrtPriceX96 + FullMath.mulDiv(currentSqrtPriceX96, MAX_SWAP_SLIPPAGE_PERCENTAGE_X96, FixedPoint96.Q96));
    //     swapDelta = poolManager.swap(pk,  IPoolManager.SwapParams({
    //         zeroForOne: zeroForOne,
    //         amountSpecified: int256(amount),
    //         sqrtPriceLimitX96: priceLimitX96
    //     }), "");
    // }
}
