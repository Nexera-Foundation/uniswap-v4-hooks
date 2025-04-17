// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

abstract contract PoolTestBase {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function _take(Currency currency, address recipient, int128 amount, bool withdrawTokens) internal {
        assert(amount < 0);
        if (withdrawTokens) {
            manager.take(currency, recipient, uint128(-amount));
        } else {
            manager.mint(address(this), currency.toId(), uint128(-amount));
        }
    }

    function _settle(Currency currency, address payer, int128 amount, bool settleUsingTransfer) internal {
        assert(amount > 0);
        if (settleUsingTransfer) {
            if (currency.isAddressZero()) {
                manager.settle{value: uint128(amount)}();
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint128(amount));
                manager.settle();
            }
        } else {
            manager.burn(address(this), currency.toId(), uint128(amount));
        }
    }

    function _fetchBalances(Currency currency, address user) internal view returns (uint256 userBalance, uint256 poolBalance, uint256 reserves, int256 delta) {
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(manager));
    }
}
