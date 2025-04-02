// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IPoolManager} from  "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from  "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import "./ZeroILSwapSamePoolHook.sol";

/**
 * @title Factory for deterministic deployment of Uniswap v4 Hooks
 * Usage of this deploy helper:
 * 1. Use `computeAddress()` to calculate salt which produces correct Hook Address, 
 *    `verifyHookAddress()` can be used to find out if computed address is correct
 * 2. Use `deploy()` to actually deploy the Hook
 */
contract UniswapV4HookFactory is Ownable {
    using Hooks for IHooks;
    event Deployed(address deployedHook);

    constructor() Ownable(_msgSender()) {}

    /**
     * @notice Deploy a Hook with constructor arguments
     * @param hookConstructorArguments abi-encoded arguments to the Hook constructor
     * @param salt This param should be calculated so that the deployed Hook address is correct (see `Hooks.validateHookAddress()` in `@uniswap/v4-core/contracts/libraries/Hooks.sol`)
     * @return address of deployed Hook
     * @dev If Hook extends BaseHook, its constructor verifies the address to follow rules
     */
    function deploy(bytes calldata hookBytecode, bytes calldata hookConstructorArguments, bytes32 salt) external onlyOwner returns(address){
        bytes memory deployBytecode = _computeBytecode(hookBytecode, hookConstructorArguments);
        address deployed =  Create2.deploy(0, salt, deployBytecode);
        ZeroILSwapSamePoolHook(deployed).transferOwnership(msg.sender);
        emit Deployed(deployed);
        return deployed;
    }

    /**
     * @notice Compute address of the Hook with constructor arguments
     * @dev This function should be used to find salt, that generates correct address
     * @param hookBytecode Bytecode of the Hook (is Solidity this is `type(contractName).creationCode`)
     * @param hookConstructorArguments abi-encoded arguments to the Hook constructor
     * @param salt This param should be calculated so that the deployed Hook address is correct (see `Hooks.validateHookAddress()` in `@uniswap/v4-core/contracts/libraries/Hooks.sol`)
     * @return computed address of the Hook
     */
    function computeAddress(bytes calldata hookBytecode, bytes calldata hookConstructorArguments, bytes32 salt) external view returns(address){
        bytes memory deployBytecode = _computeBytecode(hookBytecode, hookConstructorArguments);
        return Create2.computeAddress(salt, keccak256(deployBytecode));
    }

    function verifyHookAddressPermissions(IHooks hookAddress, Hooks.Permissions calldata permissions) public pure returns(bool){
        if (
            permissions.beforeInitialize != hookAddress.hasPermission(Hooks.BEFORE_INITIALIZE_FLAG)
                || permissions.afterInitialize != hookAddress.hasPermission(Hooks.AFTER_INITIALIZE_FLAG)
                || permissions.beforeAddLiquidity != hookAddress.hasPermission(Hooks.BEFORE_ADD_LIQUIDITY_FLAG)
                || permissions.afterAddLiquidity != hookAddress.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_FLAG)
                || permissions.beforeRemoveLiquidity != hookAddress.hasPermission(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG)
                || permissions.afterRemoveLiquidity != hookAddress.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
                || permissions.beforeSwap != hookAddress.hasPermission(Hooks.BEFORE_SWAP_FLAG)
                || permissions.afterSwap != hookAddress.hasPermission(Hooks.AFTER_SWAP_FLAG)
                || permissions.beforeDonate != hookAddress.hasPermission(Hooks.BEFORE_DONATE_FLAG)
                || permissions.afterDonate != hookAddress.hasPermission(Hooks.AFTER_DONATE_FLAG)
                || permissions.beforeSwapReturnDelta != hookAddress.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterSwapReturnDelta != hookAddress.hasPermission(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
                || permissions.afterAddLiquidityReturnDelta != hookAddress.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                || permissions.afterRemoveLiquidityReturnDelta
                    != hookAddress.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            return false;
        }
        return true;
    }

    function _computeBytecode(bytes calldata hookBytecode, bytes calldata hookConstructorArguments) private pure returns(bytes memory) {
        return abi.encodePacked(hookBytecode, hookConstructorArguments);
    }

}