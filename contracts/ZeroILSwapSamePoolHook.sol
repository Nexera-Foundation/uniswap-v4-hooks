// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ZeroILHook.sol";

contract ZeroILSwapSamePoolHook is ZeroILHook {
    uint256 MAX_SWAP_SLIPPAGE_PERCENTAGE_X96 = FixedPoint96.Q96 / 100; //  = 0.1% (100% = FixedPoint96.Q96)

    constructor(IPoolManager _poolManager, string memory _uri) ZeroILHook(_poolManager, _uri) Ownable(_msgSender()) {
    }

    /**
     * @notice Executes IL compensation swap
     * @dev Called by the ZeroILHook when already inside the lock.
     * @dev If this function requires funds transferred to or from the PoolManager, it SHOULD do it itself: call IPoolManager.settle() or IPoolManager.take()
     * @param poolId Id of the pool
     * @param zeroForOne Defines swap direction: if true, sell token0 to buy token1
     * @param amount amount to sell
     */
    function executeCompensateILSwapInsideLock(PoolId poolId, bool zeroForOne, uint256 amount) internal override {
        PoolKey memory pk = _recoverPoolKey(poolData[poolId]);
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 priceLimitX96 = uint160(zeroForOne?
            currentSqrtPriceX96 - FullMath.mulDiv(currentSqrtPriceX96, MAX_SWAP_SLIPPAGE_PERCENTAGE_X96, FixedPoint96.Q96):
            currentSqrtPriceX96 + FullMath.mulDiv(currentSqrtPriceX96, MAX_SWAP_SLIPPAGE_PERCENTAGE_X96, FixedPoint96.Q96));
        poolManager.swap(pk,  IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: priceLimitX96
        }), "");
    }

}