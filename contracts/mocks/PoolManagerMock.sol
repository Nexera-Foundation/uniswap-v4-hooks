// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

contract PoolManagerMock is PoolManager {
    constructor(address initialOwner) PoolManager(initialOwner) {}
}