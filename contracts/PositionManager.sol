// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityAccounting} from "./LiquidityAccounting.sol";
import {Rebalancer} from "./Rebalancer.sol";

/**
 * Position management based on
 * https://www.notion.so/nuant/Uniswap-Liquidity-Allocation-1cada1ba918d805895f6c5fbf40bfd53
 */
abstract contract PositionManager is Ownable, LiquidityAccounting, Rebalancer {
    // Constant used for readability
    uint256 private constant WAD = 1e18;
    uint256 private constant WAD_SQUARE = WAD * WAD;

    enum PositionOperation {
        REBALANCE, CLOSE
    }


    uint256 gamma; // Constant parameter of calculations, scaled by WAD
    uint256 volatility; // Current volatility of the spot process, scaled by WAD
    uint256 drift; // Current drift of the spot process, scaled by WAD

    function setGamma(uint256 gamma_) external onlyOwner {
        gamma = gamma_;
    }

    function setVolatility(uint256 volatility_) external onlyOwner {
        volatility = volatility_;
    }

    function setDrift(uint256 drift_) external onlyOwner {
        drift = drift_;
    }

    function _updatePosition(uint256 feeRate) internal {
        uint160 sqrtPriceX96 = _currentSqrtPriceX96();
        uint128 liquidityOfManagedPosition = _liquidityOfManagedPosition();
        (PositionOperation pOp, uint256 w1, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96) = _calculatePositionOperation(feeRate, sqrtPriceX96);
        
        // TODO Optimisation: no need to close position if we already have one with same bounds. But needs more work on LiquidityAccounting
        if(liquidityOfManagedPosition > 0) _removePosition(); // If we have a position - closing it
        if(pOp == PositionOperation.CLOSE) return;

        // Now we have whole liquidity as ERC-6909 balances (reserves):
        (uint256 balance0, uint256 balance1) = reservesBalances();
        (balance0, balance1) = _rebalance(balance0, balance1, w1, sqrtPriceX96);

        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            balance0,
            balance1
        );

        // Create new position
        _createPosition(liquidityDelta, sqrtPriceAX96, sqrtPriceBX96);
    }


    /**
     * Calculates what to do with position
     * @param feeRate current feeRate of the pool
     * @param sqrtPriceX96 current square root price of the pool
     * @return pOp Operation: Rebalance or Close position
     * @return w1 Portion of total funds to allocate in token1, WAD = 100%
     * @return sqrtPriceAX96 A sqrt price representing lower tick of new position
     * @return sqrtPriceBX96 A sqrt price representing upper tick of new position
     */
    function _calculatePositionOperation(uint256 feeRate, uint160 sqrtPriceX96) internal view virtual returns(PositionOperation pOp, uint256 w1, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96) {
        uint256 deltaStar = _deltaStar(feeRate);
        uint256 deltaU = deltaStar + drift;
        uint256 deltaD = deltaStar - drift;

        int256 vU = int256(WAD) - int256(deltaU)/2;
        uint256 vU2_wad2 = uint256(vU * vU);        // Unlike other vars this one is scaled to WAD²
        int256 vD = int256(WAD) - int256(deltaD)/2;
        uint256 vD2_wad2 = uint256(vD * vD);        // Unlike other vars this one is scaled to WAD²
        if((vU2_wad2 < WAD_SQUARE) && (vD2_wad2 < WAD_SQUARE)) {
            pOp = PositionOperation.REBALANCE;
            w1 = WAD * deltaD / (deltaD + deltaU);
            //w0 = WAD - w1; // No need to calculate this
            sqrtPriceAX96 = uint160(uint256(sqrtPriceX96) * vD2_wad2 / WAD_SQUARE);
            sqrtPriceBX96 = uint160(uint256(sqrtPriceX96) * WAD_SQUARE / vU2_wad2);
        } else {
            pOp = PositionOperation.CLOSE;
        }
    }

    /**
     * @notice Calculates the delta*.
     * @dev Implements the formula:
     * δ* = (2γ + μt²σt²) / (8τt - σt² + 2μt(μt - σt²/2))
     * All arithmetic is performed using fixed-point math with 18 decimals (WAD).
     * - μt (mu_t) is the drift.
     * - σt (sigma_t) is the volatility.
     * - τt (tau_t) is the feeRate.
     * - γ (gamma) is the gamma parameter.
     * @param feeRate The fee rate (τt), scaled by WAD.
     * @return delta The delta (δ*), scaled by WAD.
     */
    function _deltaStar(uint256 feeRate) private view returns (uint256) {
        // Calculate σt² (volatility squared).
        // (x * y) / WAD for fixed-point multiplication.
        uint256 volatilitySquared = (volatility * volatility) / WAD;

        // Calculate μt² (drift squared).
        uint256 driftSquared = (drift * drift) / WAD;

        // Calculate the full numerator: 2γ + μt²σt²
        uint256 numerator = 2 * gamma + (driftSquared * volatilitySquared) / WAD;

        // Calculate the full numerator: (8τt + 2μt(μt - σt²/2) - σt²), addition before subtracting to avoid negative values
        uint256 denominator = 8 * feeRate + (2 * drift * (drift - (volatilitySquared / 2))) / WAD - volatilitySquared;

        // We multiply the numerator by WAD before dividing to maintain the 1e18 scale.
        return (numerator * WAD) / denominator;
    }
}
