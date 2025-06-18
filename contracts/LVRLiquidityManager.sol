// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {OAppRead} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import {BaseHook} from "./lib/oz-uniswap-hooks/base/BaseHook.sol";
import {LiquidityAccounting} from "./LiquidityAccounting.sol";
import {PositionManager} from "./PositionManager.sol";
import {Rebalancer} from "./Rebalancer.sol";
import {LZReadStatDataProvider} from "./LZReadStatDataProvider.sol";
import {StatCollectorHook} from "./StatCollectorHook.sol";
import {BasePoolHelper} from "./BasePoolHelper.sol";

contract LVRLiquidityManager is PositionManager, LZReadStatDataProvider {
    error NotReadyToUpdatePosition();

    struct LZReadConfig {
        address endpoint;
        uint32 eid;
        uint32 readChannel;
        uint16 confirmations;
        address delegate; 
    }

    uint256 public lastRebalancingTimestamp;

    constructor(
        IPoolManager poolManager_,
        PoolKey memory poolKey_,
        string memory name_,
        string memory symbol_,
        LZReadConfig memory lzReadConfig
    )
        Ownable(msg.sender)
        ERC20(name_, symbol_)
        BaseHook(poolManager_)
        BasePoolHelper(poolKey_)
        OAppRead(lzReadConfig.endpoint, lzReadConfig.delegate)
        LZReadStatDataProvider(lzReadConfig.eid, lzReadConfig.readChannel, lzReadConfig.confirmations)
    {
    }


    function isReadyToUpdatePosition() public view returns(bool){
        return
         (lastFeeRate != 0) // if it is 0, then we had no feeRate update yet, so no point to rebalancing
         && (lastRebalancingTimestamp < lastFeeRateUpdateTimestamp); // We should have new feeRate
    }

    function updatePosition() external {
        require(isReadyToUpdatePosition(), NotReadyToUpdatePosition());
        _updatePosition(lastFeeRate);
    }

    // ========== Functions required by Solidity for correct inheritance =============

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) internal virtual override(BaseHook, StatCollectorHook) returns (bytes4) {
        super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override(BaseHook, StatCollectorHook) returns (bytes4, int128) {
        return super._afterSwap(sender, key, params, delta, hookData);
    }
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta delta1,
        bytes calldata hookData
    ) internal virtual override(BaseHook, StatCollectorHook) returns (bytes4, BalanceDelta) {
        super._afterAddLiquidity(sender, key, params, delta0, delta1, hookData);
    }
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta delta1,
        bytes calldata hookData
    ) internal virtual override(BaseHook, StatCollectorHook) returns (bytes4, BalanceDelta) {
        return super._afterRemoveLiquidity(sender, key, params, delta0, delta1, hookData);
    }
}
