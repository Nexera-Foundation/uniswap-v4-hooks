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
}
