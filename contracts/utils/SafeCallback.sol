// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

/**
 * @title Safe Callback
 * @notice A contract that only allows the Uniswap v4 PoolManager to call the unlockCallback
 * @dev Copied from https://github.com/Uniswap/v4-periphery/blob/main/src/base/SafeCallback.sol
 * because using it with BaseHook (https://github.com/Uniswap/v4-periphery/blob/main/src/BaseHook.sol)
 * introduces problems with ImmutableState constructor called twice.
 */
abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    /// @inheritdoc IUnlockCallback
    /// @dev We force the onlyPoolManager modifier by exposing a virtual function after the onlyPoolManager check.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev to be implemented by the child contract, to safely guarantee the logic is only executed by the PoolManager
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
