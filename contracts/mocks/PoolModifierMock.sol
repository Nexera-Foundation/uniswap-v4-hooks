// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolTestBase} from "./PoolTestBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract PoolModifierMock is PoolTestBase {
    using CurrencyLibrary for Currency;
    using Hooks for IHooks;

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
    }

    function modifyPosition(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        (delta,) = manager.modifyLiquidity(key, params, hookData);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0 && CurrencyLibrary.isAddressZero(key.currency0)) {
            key.currency0.transfer(msg.sender, ethBalance);
        }
    }

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (BalanceDelta delta,) = manager.modifyLiquidity(data.key, data.params, data.hookData);

        (, , , int256 delta0) = _fetchBalances(data.key.currency0, data.sender);
        (, , , int256 delta1) = _fetchBalances(data.key.currency1, data.sender);

        if (data.params.liquidityDelta > 0) {
            if (delta0 > 0) _settle(data.key.currency0, data.sender, delta.amount0(), true);
            if (delta1 > 0) _settle(data.key.currency1, data.sender, delta.amount1(), true);
        } else {
            if (delta0 < 0) _take(data.key.currency0, data.sender, delta.amount0(), true);
            if (delta1 < 0) _take(data.key.currency1, data.sender, delta.amount1(), true);
        }

        return abi.encode(delta);
    }
}
