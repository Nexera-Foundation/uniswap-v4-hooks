// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {UnlockDispatcher} from "./UnlockDispatcher.sol";
import {BasePoolHelper} from "./BasePoolHelper.sol";

abstract contract Rebalancer is BasePoolHelper {
    // Constant used for readability
    uint256 private constant WAD = 1e18;

    error NotEnoughLiquidity(PoolId);

    /**
     * Rebalances funds
     * @param balance0 Current balance of token0
     * @param balance1 Current balance of token1
     * @param w1 Required percentage (WAD = 100%) of token1. Percentage of token0 can be calculated as WAD - w1
     * @param sqrtPriceX96 current price
     * @return token0 New balance of token0
     * @return token1 New balance of token1
     */
    function _rebalance(uint256 balance0, uint256 balance1, uint256 w1, uint160 sqrtPriceX96) internal returns (uint256 token0, uint256 token1) {
        // Price of token0 over token1
        uint256 poolPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * WAD / 2 ** (96 * 2);

        uint256 balance0InToken1 = balance0 * poolPrice / WAD; // Convert balance0 to token1 equivalent

        uint256 w1Actual = (WAD * balance1) / (balance0InToken1 + balance1);

        if (w1Actual == w1) return (balance0, balance1);

        SwapParams memory swapParams;
        if (w1Actual > w1) {
            //Swap token1 to token0
            //zeroForOne = false; // skip bacause it's false by default
            uint256 diff = (w1Actual - w1);

            swapParams.amountSpecified = -int256(diff); // Negative means we are specifying exact in
            swapParams.sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
        } else {
            //Swap token0 to token1
            swapParams.zeroForOne = true;

            uint256 diff = (w1 - w1Actual);

            swapParams.amountSpecified = -int256(diff); // Negative means we are specifying exact in
            swapParams.sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
        }

        BalanceDelta swapDelta = _swap(swapParams);

        // Here we have 2 cases:
        //1: Swap 0 => 1: swapDelta.amount0() is negative, because it is "exact in", so when adding it to balance0 we are actually decreasing it, swapDelta.amount1() is positive
        //2: Swap 1 => 0: swapDelta.amount1() is negative, because it is "exact in", so when adding it to balance1 we are actually decreasing it, swapDelta.amount0() is positive
        token0 = uint256(int256(balance0) + int256(swapDelta.amount0()));
        token1 = uint256(int256(balance1) + int256(swapDelta.amount1()));
    }

    function _unlockedSwap(SwapParams memory params) internal virtual override returns (BalanceDelta swapDelta) {
        swapDelta = poolManager.swap(poolKey, params, "");

        // Check that the pool was not illiquid.
        int128 amountSpecifiedActual = (params.zeroForOne == (params.amountSpecified < 0)) ? swapDelta.amount0() : swapDelta.amount1();
        if (amountSpecifiedActual != params.amountSpecified) {
            revert NotEnoughLiquidity(poolKey.toId());
        }
    }
}
