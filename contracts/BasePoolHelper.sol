// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./UnlockDispatcher.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

abstract contract BasePoolHelper is UnlockDispatcher {
    /**
     * @notice Pool key of the pool we are working with
     */
    PoolKey public poolKey;
    PoolId public poolId;

    constructor(PoolKey memory poolKey_) {
        poolKey = poolKey_;
        poolId = poolKey_.toId();
    }
}