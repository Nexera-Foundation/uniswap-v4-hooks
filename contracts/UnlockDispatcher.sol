// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BaseHook} from "./lib/oz-uniswap-hooks/base/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

abstract contract UnlockDispatcher is IUnlockCallback, BaseHook {
    error UnknownUnlockOperation();

    enum UnlockOperation {
        SWAP,
        MODIFY_LIQUIDITY
        // TODO Add BATCH operation, which executes a sequence of others
    }

    struct UnlockData {
        UnlockOperation op;
        bytes opData;
    }

    function unlockCallback(bytes calldata rawData) external virtual override onlyPoolManager returns (bytes memory returnData) {
        UnlockData memory ud = abi.decode(rawData, (UnlockData));
        if (ud.op == UnlockOperation.SWAP) {
            SwapParams memory swapParams = abi.decode(ud.opData, (SwapParams));
            BalanceDelta swapDelta = _unlockedSwap(swapParams);
            return abi.encode(swapDelta);
        } else if (ud.op == UnlockOperation.MODIFY_LIQUIDITY) {
            ModifyLiquidityParams memory modifyLiquidityParams = abi.decode(ud.opData, (ModifyLiquidityParams));
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _unlockedModifyLiquidity(modifyLiquidityParams);
            return abi.encode(callerDelta, feesAccrued);
        } else {
            revert UnknownUnlockOperation();
        }
    }

    /**
     * Calls the `PoolManager` to unlock and call back the hook's `unlockCallback` function.
     * @param unlockData The encoded unlock operation and it's arguments
     * @return result of the operation
     */
    function _unlock(UnlockData memory unlockData) internal virtual returns (bytes memory) {
        return poolManager.unlock(abi.encode(unlockData));
    }

    /**
     * @dev Calls the `PoolManager` to unlock and call back the hook's `unlockCallback` function.
     *
     * @param params The ModifyLiquidityParams struct for the liquidity modification
     * @return callerDelta The balance delta from the liquidity modification. This is the total of both principal and fee deltas.
     * @return feesAccrued The balance delta of the fees generated in the liquidity range.
     */
    function _modifyLiquidity(ModifyLiquidityParams memory params) internal virtual returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        bytes memory resultData = _unlock(UnlockData({op: UnlockOperation.MODIFY_LIQUIDITY, opData: abi.encode(params)}));
        (callerDelta, feesAccrued) = abi.decode(resultData, (BalanceDelta, BalanceDelta));
    }

    /**
     * @dev Calls the `PoolManager` to unlock and call back the hook's `unlockCallback` function.
     *
     * @param params The SwapParams struct for the swap 
     * @return swapDelta The balance delta of the address swapping
     */
    function _swap(SwapParams memory params) internal virtual returns (BalanceDelta swapDelta) {
        bytes memory resultData = _unlock(UnlockData({op: UnlockOperation.SWAP, opData: abi.encode(params)}));
        swapDelta = abi.decode(resultData, (BalanceDelta));
    }

    function _unlockedSwap(SwapParams memory params) internal virtual returns (BalanceDelta swapDelta);

    function _unlockedModifyLiquidity(ModifyLiquidityParams memory params) internal virtual returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);
}
