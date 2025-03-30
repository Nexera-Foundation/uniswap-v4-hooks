// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import "@uniswap/v4-core/src/libraries/Hooks.sol";
import "./ZeroILSwapSamePoolHook.sol";

/**
 * @title Factory for deterministic deployment of Uniswap v4 Hooks
 * Usage of this deploy helper:
 * 1. Use `computeAddress()` to calculate salt which produces correct Hook Address, 
 *    `verifyHookAddress()` can be used to find out if computed address is correct
 * 2. Use `deploy()` to actually deploy the Hook
 */
contract UniswapV4HookFactory is Ownable {
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

    function verifyHookAddress(IHooks hookAddress, Hooks.Calls calldata calls) public pure returns(bool){
        return (
            calls.beforeInitialize == Hooks.shouldCallBeforeInitialize(hookAddress)
            && calls.afterInitialize == Hooks.shouldCallAfterInitialize(hookAddress)
            && calls.beforeModifyPosition == Hooks.shouldCallBeforeModifyPosition(hookAddress)
            && calls.afterModifyPosition == Hooks.shouldCallAfterModifyPosition(hookAddress)
            && calls.beforeSwap == Hooks.shouldCallBeforeSwap(hookAddress) && calls.afterSwap == Hooks.shouldCallAfterSwap(hookAddress)
            && calls.beforeDonate == Hooks.shouldCallBeforeDonate(hookAddress) && calls.afterDonate == Hooks.shouldCallAfterDonate(hookAddress)
        );
    }

    function _computeBytecode(bytes calldata hookBytecode, bytes calldata hookConstructorArguments) private pure returns(bytes memory) {
        return abi.encodePacked(hookBytecode, hookConstructorArguments);
    }

}