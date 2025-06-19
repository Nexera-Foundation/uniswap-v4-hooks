// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "./lib/oz-uniswap-hooks/utils/CurrencySettler.sol";
import "./UnlockDispatcher.sol";

abstract contract CurrencyWithdrawals is UnlockDispatcher {
    using CurrencySettler for Currency;

    struct CurrencyAmount {
        Currency currency;
        uint256 amount;
    }
    struct WithdrawRequest {
        address to;
        CurrencyAmount[] withdrawals;
    }

    function _withdraw(address to, Currency currency, uint256 amount) internal {
        WithdrawRequest memory request;
        request.to = to;
        request.withdrawals = new CurrencyAmount[](1);
        request.withdrawals[0] = CurrencyAmount({currency: currency, amount: amount});
        _unlock(UnlockData({op: UnlockOperation.WITHDRAW_CURRENCIES, opData: abi.encode(request)}));
    }

    function _withdraw(address to, Currency[2] memory currencies, uint256[2] memory amounts) internal {
        WithdrawRequest memory request;
        request.to = to;
        request.withdrawals = new CurrencyAmount[](currencies.length);
        for (uint256 i; i < currencies.length; i++) {
            request.withdrawals[i] = CurrencyAmount({currency: currencies[i], amount: amounts[i]});
        }
        _unlock(UnlockData({op: UnlockOperation.WITHDRAW_CURRENCIES, opData: abi.encode(request)}));
    }

    function _withdraw(address to, Currency[] memory currencies, uint256[] memory amounts) internal {
        require(currencies.length == amounts.length, "Currencies array length does not match amounts array length");
        WithdrawRequest memory request;
        request.to = to;
        request.withdrawals = new CurrencyAmount[](currencies.length);
        for (uint256 i; i < currencies.length; i++) {
            request.withdrawals[i] = CurrencyAmount({currency: currencies[i], amount: amounts[i]});
        }
        _unlock(UnlockData({op: UnlockOperation.WITHDRAW_CURRENCIES, opData: abi.encode(request)}));
    }

    function _unlockedWithdrawCurrencies(bytes memory data) internal override returns (bytes memory) {
        WithdrawRequest memory request = abi.decode(data, (WithdrawRequest));
        for (uint256 i; i < request.withdrawals.length; i++) {
            CurrencyAmount memory ca = request.withdrawals[i];
            ca.currency.take(poolManager, request.to, ca.amount, true);
        }
        return "";
    }
}
