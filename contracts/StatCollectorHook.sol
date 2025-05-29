// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LiquidityAmountsExtra} from "./utils/LiquidityAmountsExtra.sol";

abstract contract StatCollectorHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    // using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    error AlreadyInitialized();
    error WrongPool(PoolId managedPoolId, PoolId providedPoolId);
    error WrongLiquidityDeltaSign(bool expectPositive, int256 liquidityDelta);

    PoolId public managedPoolId;
    uint256 public liquidity0;
    uint256 public liquidity1;

    modifier onlyManagedPool(PoolKey calldata pk) {
        PoolId pid = pk.toId();
        require(PoolId.unwrap(pid) == PoolId.unwrap(managedPoolId), WrongPool(managedPoolId, pid));
        _;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false, //todo maybe intercept donate to exclude donations from fees?
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _afterInitialize(address, PoolKey calldata pk, uint160, int24) internal override returns (bytes4) {
        require(PoolId.unwrap(managedPoolId) == bytes32(0), AlreadyInitialized());
        managedPoolId = pk.toId();
        return IHooks.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata pk,
        ModifyLiquidityParams calldata change,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override onlyManagedPool(pk) returns (bytes4, BalanceDelta) {
        require(change.liquidityDelta > 0, WrongLiquidityDeltaSign(true, change.liquidityDelta));
        (uint160 currentSqrtPriceX96, /*int24 tick*/, /*uint24 protocolFee*/, /*uint24 lpFee*/) = poolManager.getSlot0(poolId);
        (uint256 amount0, uint256 amount1) = LiquidityAmountsExtra.getAmountsForLiquidity(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(change.tickLower),
            TickMath.getSqrtPriceAtTick(change.tickUpper),
            uint128(int128(change.liquidityDelta))
        );
        liquidity0 += amount0;
        liquidity1 += amount1;
        return  (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata pk,
        ModifyLiquidityParams calldata change,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override onlyManagedPool(pk) returns (bytes4, BalanceDelta) {
        if(change.liquidityDelta == 0) {
            // This is a call used to receive fee
            return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA); 
        }

        require(change.liquidityDelta < 0, WrongLiquidityDeltaSign(false, change.liquidityDelta));
        (uint160 currentSqrtPriceX96, /*int24 tick*/, /*uint24 protocolFee*/, /*uint24 lpFee*/) = poolManager.getSlot0(poolId);
        (uint256 amount0, uint256 amount1) = LiquidityAmountsExtra.getAmountsForLiquidity(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(change.tickLower),
            TickMath.getSqrtPriceAtTick(change.tickUpper),
            uint128(int128(-change.liquidityDelta))
        );
        liquidity0 -= amount0;
        liquidity1 -= amount1;
        return  (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterSwap(
        address,
        PoolKey calldata pk,
        SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override onlyManagedPool(pk) returns (bytes4, int128) {
        // As specified in IHooks: swapDelta The amount owed to the caller (positive) or owed to the pool (negative)
        // So positive amount should be subtracted from the liquidity (it is sent to the swapper)
        // and the value of negative amount should be added to liquidity (this is provided by swapper), so we subtract the negative value
        // NOTE: How to take fee from this is a big question
        liquidity0 = uint256(int256(liquidity0) - int256(swapDelta.amount0()));
        liquidity1 = uint256(int256(liquidity1) - int256(swapDelta.amount1()));

        // All of this is commented out because Fee  calcculation is extremly complicated:
        // it is taken from unspecifed currnct (which can be in or out), it is calculated in steps during the swap math cycle...
        //
        // //require(swap.amountSpecified != 0, "wrong swap amount"); // commented-out because this is checked py the PoolManager.swap()
        // if(swapParams.zeroForOne) {
        //     if(swap.amountSpecified > 0) {
        //         // Swapping token0 to token1, exact out (token1) specified
        //         liquidity1 -= swapParams.amountSpecified; // -= because we are removing positive amount of taken tokens
        //         liquidity0 -= swapDelta.amount0();
        //     } else {
        //         // Swapping token0 to token1, exact in (token0) specified
        //         liquidity0 -= swapParams.amountSpecified; // -= because we are adding negative amount of provided tokens
        //         liquidity1 -= swapDelta.amount1();
        //     }
            
        // } else {
        //     if(swap.amountSpecified > 0) {
        //         // Swapping token1 to token0, exact out (token0) specified
        //         liquidity0 -= swapParams.amountSpecified; // -= because we are removing positive amount of taken tokens
        //         liquidity1 -= swapDelta.amount1();
        //     } else {
        //         // Swapping token1 to token0, exact in (token1) specified
        //         liquidity1 -= swapParams.amountSpecified; // -= because we are adding negative amount of provided tokens
        //         liquidity0 -= swapDelta.amount0();
        //     }
        // }
        return  (IHooks.afterSwap.selector, 0);

    }

    /**
     * Returns fee collected by the Pool
     * Note: Donations to the pool are also included (so results can be artificially inflated)
     * @return token0 fee
     * @return token1 fee
     */
    function _poolFees() internal view returns(uint256, uint256) {
        return poolManager.getFeeGrowthGlobals(managedPoolId);
    }    
}
