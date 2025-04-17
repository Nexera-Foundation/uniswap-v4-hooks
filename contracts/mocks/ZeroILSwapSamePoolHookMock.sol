// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../ZeroILSwapSamePoolHook.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ZeroILSwapSamePoolHookMock is ZeroILSwapSamePoolHook {
    struct TestSettings {
        bool withdrawTokens;
        bool settleUsingTransfer;
    }

    constructor(IPoolManager _poolManager, string memory _uri) ZeroILSwapSamePoolHook(_poolManager, _uri) {}

    /**
     * @notice Execute Swap
     * @param zeroForOne Defines swap direction: if true, sell token0 to buy token1
     * @param amount amount to sell
     * @param data Encoded data of new zeroIL position
     */
    function swap(PoolKey memory key, bool zeroForOne, int256 amount, bytes memory data) external payable {
        _swap(key, zeroForOne, amount, data);
    }

    function makeSwap(address sender, PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory data) external {
        (TestSettings memory testSettings, bytes memory hookData) = abi.decode(data, (TestSettings, bytes));
        BalanceDelta delta = _swap(key, params.zeroForOne, int256(params.amountSpecified), hookData);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                if (testSettings.settleUsingTransfer) {
                    IERC20(Currency.unwrap(key.currency0)).transferFrom(sender, address(poolManager), uint128(delta.amount0()));
                    poolManager.settle();
                } else {
                    poolManager.burn(address(this), key.currency0.toId(), uint128(delta.amount0()));
                }
            }
            if (delta.amount1() < 0) {
                if (testSettings.withdrawTokens) {
                    poolManager.take(key.currency1, sender, uint128(-delta.amount1()));
                } else {
                    poolManager.mint(sender, key.currency1.toId(), uint128(-delta.amount1()));
                }
            }
        } else {
            if (delta.amount1() > 0) {
                if (testSettings.settleUsingTransfer) {
                    IERC20(Currency.unwrap(key.currency1)).transferFrom(sender, address(poolManager), uint128(delta.amount1()));
                    poolManager.settle();
                } else {
                    poolManager.burn(address(this), key.currency1.toId(), uint128(delta.amount1()));
                }
            }
            if (delta.amount0() < 0) {
                if (testSettings.withdrawTokens) {
                    poolManager.take(key.currency0, sender, uint128(-delta.amount0()));
                } else {
                    poolManager.mint(sender, key.currency1.toId(), uint128(-delta.amount0()));
                }
            }
        }
    }
}
