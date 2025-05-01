// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./HookMiner.sol";
import {ZeroILSwapSamePoolHookMock} from "./ZeroILSwapSamePoolHookMock.sol";

/// @notice Mines the address of the Hook contract
contract HookMinerMock {
    function getSalt(address poolManager, address hookFactory) public returns (bytes32) {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) = HookMiner.find(hookFactory, flags, type(ZeroILSwapSamePoolHookMock).creationCode, constructorArgs);

        return salt;
    }
}
