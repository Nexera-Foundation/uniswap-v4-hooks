# Nexera Uniswap V4 - Zero Impermanent Loss Hook

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
<!-- Optional: Add other relevant badges like build status, coverage, etc. -->
<!-- e.g., [![Build Status](...)](...) [![Coverage Status](...)](...) -->

This repository, developed by the [Nexera Foundation](https://nexera.foundation/), contains an implementation of a Uniswap V4 Hook designed to mitigate Impermanent Loss (IL) for liquidity providers (LPs). It also includes a specialized factory for deterministic deployment of these hooks.

## Table of Contents

-   [Introduction](#introduction)
-   [What are Uniswap V4 Hooks?](#what-are-uniswap-v4-hooks)
-   [Core Contracts](#core-contracts)
    -   [`LVRLiquidityManager` (LVR-Based Liquidity Management Hook)](#lvrliquiditymanager-lvr-based-liquidity-management-hook)
    -   [`ZeroILHook` (Abstract Base Contract)](#zeroilhook-abstract-base-contract)
    -   [`ZeroILSwapSamePoolHook` (Concrete Implementation)](#zeroilswapsamepoolhook-concrete-implementation)
    -   [`UniswapV4HookFactory` (Deployment Factory)](#uniswapv4hookfactory-deployment-factory)
    -   [Peripheral Contracts](#peripheral-contracts)
-   [How It Works: Zero IL Strategy](#how-it-works-zero-il-strategy)
-   [How It Works: LVR Liquidity Management Strategy](#how-it-works-lvr-liquidity-management-strategy)
    -   [IL Calculation & Compensation Trigger](#il-calculation--compensation-trigger)
    -   [Compensation Swap Mechanism](#compensation-swap-mechanism)
    -   [Concentrated Liquidity Position Management](#concentrated-liquidity-position-management)
    -   [Position Shifting](#position-shifting)
    -   [LP Shares (ERC1155)](#lp-shares-erc1155)
    -   [Reserve Mechanism](#reserve-mechanism)
    -   [PoolManager Lock](#poolmanager-lock)
-   [Prerequisites](#prerequisites)
-   [Getting Started](#getting-started)
    -   [Cloning the Repository](#cloning-the-repository)
    -   [Installing Dependencies](#installing-dependencies)
-   [Configuration](#configuration)
    -   [Environment Variables](#environment-variables)
-   [Usage (Hardhat)](#usage-hardhat)
    -   [Compiling Contracts](#compiling-contracts)
    -   [Running Tests](#running-tests)
    -   [Deploying Hooks](#deploying-hooks)
        -   [Deploying ZeroILSwapSamePoolHook](#deploying-zeroilswapsamepoolhook)
            -   [Step 1: Deploy the `UniswapV4HookFactory`](#step-1-deploy-the-uniswapv4hookfactory)
            -   [Step 2: Find the Correct Salt](#step-2-find-the-correct-salt)
            -   [Step 3: Deploy the Hook via the Factory](#step-3-deploy-the-hook-via-the-factory)
        -   [Deploying LVRLiquidityManager](#deploying-lvrliquiditymanager)
    -   [Configuring the Deployed Hook](#configuring-the-deployed-hook)
    -   [Integrating Hooks with Uniswap V4 Pools](#integrating-hooks-with-uniswap-v4-pools)
-   [Development Environment](#development-environment)
-   [Contributing](#contributing)
-   [License](#license)
-   [Support & Contact](#support--contact)

## Introduction

Uniswap V4's hook architecture allows for powerful customization of pool behavior. This repository implements advanced liquidity management strategies for liquidity providers, featuring two distinct approaches:

1. **`ZeroILHook`:** A strategy aimed at reducing or eliminating impermanent loss by monitoring LP positions and executing compensatory swaps when IL exceeds configurable thresholds. LP shares are represented by ERC1155 tokens.

2. **`LVRLiquidityManager`:** A sophisticated liquidity optimization system based on Loss-Versus-Rebalancing (LVR) analysis. This hook uses LayerZero's cross-chain reading capabilities to analyze historical fee rates and automatically rebalance positions for optimal returns. LP shares are represented by ERC20 tokens.

A `UniswapV4HookFactory` contract is provided for deterministic `CREATE2` deployment, ensuring hook addresses meet Uniswap V4's specific requirements.

## What are Uniswap V4 Hooks?

Hooks are external smart contracts called by the central Uniswap V4 `PoolManager` at specific points during pool operations (e.g., before/after swap, modify position). They allow developers to add custom logic without modifying the core Uniswap protocol.

Key aspects:

*   **Modularity:** Hooks are deployed independently.
*   **Callbacks:** Execute logic at predefined points (`afterInitialize`, `afterSwap` used here).
*   **State:** Hooks can manage their own state.
*   **Composability:** Enable features like dynamic fees, limit orders, on-chain oracles, risk management, and IL mitigation strategies like the one in this repository.

For a deeper understanding, consult the [official Uniswap V4 documentation](https://docs.uniswap.org/contracts/v4/overview). <!-- Verify link -->

## Core Contracts

### `LVRLiquidityManager` (LVR-Based Liquidity Management Hook)

*   **File:** `contracts/LVRLiquidityManager.sol`
*   **Inherits:** `PositionManager`, `LZReadStatDataProvider`, `Ownable`, `ERC20`, `BaseHook`, `BasePoolHelper`, `OAppRead`
*   **Description:** A sophisticated liquidity management hook that optimizes liquidity provision based on Loss-Versus-Rebalancing (LVR) analysis. This hook automatically rebalances positions using historical fee rate data obtained through LayerZero's cross-chain reading capabilities.

*   **Key Components:**
    *   **`StatCollectorHook` & `LZReadStatDataProvider`:** Collects liquidity change data from the pool and retrieves historical data via LayerZero Read to calculate the pool's fee rate over time.
    *   **`LiquidityAccounting`:** Manages liquidity addition/removal operations and handles minting/burning of ERC20 share tokens representing LP positions.
    *   **`PositionManager` & `Rebalancer`:** Analyzes the calculated fee rate and determines optimal fund allocation, then executes rebalancing to match the target proportions.
    *   **`LVRLiquidityManager`:** The main contract that orchestrates all components into a unified liquidity management system.

*   **Configuration:**
    *   **Creation Time (Constructor Parameters):**
        *   `poolManager`: Address of the Uniswap V4 Pool Manager
        *   `poolKey`: Pool configuration (can be constructed before pool creation)
        *   `name` & `symbol`: ERC20 share token identifiers
        *   `LZReadConfig`: LayerZero configuration including:
            *   `endpoint`: LayerZero endpoint address
            *   `eid`: Endpoint ID for the target chain
            *   `readChannel`: LayerZero read channel identifier
            *   `confirmations`: Required block confirmations before LZ read can query chain state
            *   `delegate`: Address authorized to modify low-level LZ configuration (recommended: multisig for production)
    
    *   **Runtime Configuration (Modifiable During Lifetime):**
        *   Algorithm parameters (scaled to 1e18, based on [LVR research](https://www.notion.so/nuant/Uniswap-Liquidity-Allocation-1cada1ba918d805895f6c5fbf40bfd53)):
            *   `gamma`: Risk aversion parameter
            *   `volatility`: Expected asset volatility
            *   `drift`: Expected price drift
        *   LayerZero Read configuration:
            *   `feeRateReadingInterval`: Fee rate calculation frequency (seconds)
            *   `intermediateLiquidityPoints`: Additional liquidity sampling points for averaging between updates

*   **Backend Requirements:**
    *   **Fee Rate Updates:** Periodically call `isReadyToReadFeeRate()` and execute `initiateReadFeeRate()` when it returns `true`
    *   **Position Updates:** Periodically call `isReadyToUpdatePosition()` and execute `updatePosition()` when it returns `true` (typically after successful fee rate updates)

*   **Usage Functions:**
    *   **`addLiquidity(amount0Desired, amount1Desired, amount0Min, amount1Min, deadline)`:** Adds liquidity to the hook and mints ERC20 shares. Parameters define maximum amounts to deposit, minimum amounts required, and transaction deadline.
    *   **`removeLiquidity(shares, amount0Min, amount1Min, deadline)`:** Burns ERC20 shares and withdraws underlying liquidity. Parameters specify shares to burn, minimum token amounts to receive, and transaction deadline.

### `ZeroILHook` (Abstract Base Contract)

*   **File:** `contracts/ZeroILHook.sol` <!-- Verify Path -->
*   **Inherits:** `BaseHook` (modified periphery), `ERC1155`, `Ownable`
*   **Description:** An abstract contract defining the core logic and state management for the Zero IL strategy. It cannot be deployed directly but serves as the foundation for concrete implementations.
*   **Key Features:**
    *   **Hook Callbacks:** Implements `afterInitialize` and `afterSwap`.
    *   **State Management (`PoolData`):** Tracks pool currencies, fees, tick spacing, last known tick, current LP position bounds (`currentPosition`), and the zero IL baseline state (`zeroILTick`, `zeroILPosition`, `zeroILReserveAmount`, `zeroILReserveZeroSide`).
    *   **Configuration (`PoolConfig`):** Allows the owner to set parameters per pool:
        *   `desiredPositionRangeTickLower`/`Upper`: Defines the desired width of the concentrated liquidity position relative to the current tick.
        *   `shiftPositionLower`/`UpperTickDistance`: Thresholds defining how far the price can drift before the position is recentered.
        *   `il0percentageToSwapX96`/`il1percentageToSwapX96`: Percentage thresholds of IL (relative to initial amounts) that trigger a compensatory swap (Q96 fixed-point).
    *   **IL Calculation:** Contains logic (`_calculateIL`) to determine the impermanent loss compared to the `zeroILTick` baseline.
    *   **Position Shifting Trigger:** Logic (`_isPositionShiftRequired`) to determine if the price has moved enough to warrant shifting the liquidity position.
    *   **Liquidity Management:** Provides external functions (`addLiquidity`, `withdrawLiquidity`) for LPs to interact with the hook.
    *   **LP Tokens:** Mints/burns ERC1155 tokens to represent LP shares, where the `tokenId` is derived from the `PoolId`.
    *   **Abstract Swap Execution:** Defines an `internal virtual` function `executeCompensateILSwapInsideLock` which must be implemented by child contracts to specify *how* the compensation swap is performed.
    *   **Ownership:** Uses OpenZeppelin's `Ownable` for configuration control.

### `ZeroILSwapSamePoolHook` (Concrete Implementation)

*   **File:** `contracts/ZeroILSwapSamePoolHook.sol` <!-- Verify Path -->
*   **Inherits:** `ZeroILHook`
*   **Description:** The deployable implementation of the `ZeroILHook`. It specifies that the IL compensation swap should occur *within the same Uniswap V4 pool* where the liquidity is provided.
*   **Key Features:**
    *   **Implements `executeCompensateILSwapInsideLock`:** Provides the concrete logic for the IL compensation swap using `poolManager.swap` on the *same* pool key (`pk`).
    *   **Slippage Protection:** Uses `MAX_SWAP_SLIPPAGE_PERCENTAGE_X96` (default 0.1%) to calculate `sqrtPriceLimitX96` for the compensatory swap, preventing excessive slippage.
    *   **Deployable:** Contains a constructor and is intended to be deployed via the factory.

### `UniswapV4HookFactory` (Deployment Factory)

*   **File:** `contracts/UniswapV4HookFactory.sol` <!-- Verify Path -->
*   **Inherits:** `Ownable`
*   **Description:** A factory contract designed for deterministic deployment of hooks (specifically `ZeroILSwapSamePoolHook` as coded) using `CREATE2`. This ensures the hook address meets Uniswap V4's requirements based on its implemented flags.
*   **Key Features:**
    *   **Deterministic Deployment (`deploy`):** Uses `Create2.deploy` with a provided `salt` to deploy the hook bytecode. Requires bytecode, ABI-encoded constructor arguments, and the `salt`. Transfers ownership of the deployed `ZeroILSwapSamePoolHook` to the factory deployer (msg.sender). Only callable by the factory owner.
    *   **Address Computation (`computeAddress`):** Calculates the predicted deployment address for a given bytecode, constructor arguments, and `salt` *without* actually deploying. Essential for finding a `salt` that results in a valid hook address.
    *   **Address Verification (`verifyHookAddress`):** A utility function to check if a given hook address correctly implements the expected callbacks based on Uniswap V4's `Hooks.shouldCall...` functions. This helps confirm the validity of an address computed via `computeAddress`.
    *   **Ownership:** `Ownable` restricts deployment capabilities to the owner.

### Peripheral Contracts

*   **`BaseHook`:** (`contracts/uniswap-v4-periphery/BaseHook.sol`) A modified version of a standard base hook implementation, likely including necessary modifiers (`poolManagerOnly`, `selfOnly`) and potentially adapting the `lockAcquired` callback for the hook's internal calls.
*   **`LiquidityAmounts`:** (`contracts/uniswap-v4-periphery/LiquidityAmounts.sol`) A library providing helper functions to convert between token amounts and liquidity amounts for specific price ranges (sqrtPriceX96 values), crucial for managing concentrated liquidity positions.

## How It Works: Zero IL Strategy

The `ZeroILHook` aims to counteract impermanent loss through the following mechanisms:

1.  **IL Calculation & Compensation Trigger:**
    *   The hook maintains a "zero IL" state (`zeroILTick`, `zeroILPosition`) which represents the price and position bounds at which the LP's portfolio value was last considered "whole" (i.e., after the last compensation or initial deposit).
    *   After each swap in the pool (`afterSwap` callback), the hook calculates the current value of the liquidity position (`_getAmountsForLiquidity`) based on the `currentTick` and `currentPosition`.
    *   It compares this to the theoretical value the position *would* have had if held since the `zeroILTick` (`_getAmountsForLiquidity` using `zeroILTick` and `zeroILPosition`).
    *   The difference represents the IL (`il0`, `il1`). This IL is converted to a percentage (`il0PercentageX96`, `il1PercentageX96`) relative to the initial amounts at the `zeroILTick`.
    *   If either percentage exceeds the configured threshold (`il0percentageToSwapX96` or `il1percentageToSwapX96`), a compensation swap is triggered.

2.  **Compensation Swap Mechanism (`ZeroILSwapSamePoolHook`):**
    *   The triggered compensation swap aims to convert the token that has increased in relative quantity (due to price moves) back into the token that has decreased.
    *   This specific implementation (`ZeroILSwapSamePoolHook`) performs this swap directly within the *same Uniswap V4 pool* using `poolManager.swap`.
    *   It calculates the required liquidity amount to swap (`_getLiquidityForAmount`) based on the IL amount and may interact with the hook's reserve (`compensateILSwapInsideLock` logic).
    *   Slippage protection (`sqrtPriceLimitX96`) is applied.
    *   After the swap, the `zeroILTick` and `zeroILPosition` are updated to reflect the new baseline state (`_afterCompensateILSwap`).

3.  **Concentrated Liquidity Position Management:**
    *   LPs don't provide liquidity directly to the Uniswap pool but rather through the hook's `addLiquidity` function.
    *   The hook manages a single concentrated liquidity position per pool on behalf of all its LPs.
    *   The width of this position is determined by the owner-set `PoolConfig` (`desiredPositionRangeTickLower`/`Upper`) relative to the current market price (tick).

4.  **Position Shifting:**
    *   To keep the concentrated liquidity position effective, it needs to follow the market price.
    *   The `_isPositionShiftRequired` function checks if the `currentTick` has moved beyond the configured `shiftPositionLower/UpperTickDistance` from the *center* of the current position.
    *   If a shift is required, the `shiftPositionInsideLock` function is called (within the `PoolManager` lock). This function withdraws the *entire* liquidity from the old position range and redeposits it into a new range centered around the `newPositionCenter` (the current tick), using the configured width.
    *   The hook's `currentPosition` state is updated. If there was no liquidity, only the position bounds are updated.

5.  **LP Shares (ERC1155):**
    *   When an LP calls `addLiquidity`, they provide tokens (Token0, Token1, or Native Currency + Token1) to the hook.
    *   The hook calculates the corresponding liquidity amount (`_calculateAddLiquidityAmount`) and adds it to its managed position via `poolManager.modifyPosition`.
    *   The LP receives ERC1155 tokens (`_mint`) where the `tokenId` is the `PoolId` (casted to `uint256`) and the `amount` represents the liquidity units contributed.
    *   `withdrawLiquidity` allows LPs to burn their ERC1155 tokens (`_burn`) and receive back the underlying tokens, withdrawn proportionally from the hook's position and reserve.

6.  **Reserve Mechanism:**
    *   The hook maintains a reserve (`zeroILReserveAmount`) of one of the pool's tokens (`zeroILReserveZeroSide` indicates which one).
    *   The logic in `addLiquidity` and `withdrawLiquidity` suggests that deposits/withdrawals might interact proportionally with this reserve (details depend on `_calculateLiquidityInReserve`).
    *   The `compensateILSwapInsideLock` logic also considers the reserve when determining how much liquidity needs to be added/removed from the main position before/after the swap. The reserve acts as a buffer to facilitate swaps without constantly adjusting the main LP position for *every* compensation.

7.  **`PoolManager.lock`:**
    *   All operations modifying pool state (swaps, position modifications) performed by the hook are wrapped in `poolManager.lock(...)`. This ensures atomicity and prevents reentrancy issues by granting the hook temporary exclusive access to the pool state. The hook calls its own internal functions (e.g., `addLiquidityInsideLock`, `compensateILSwapInsideLock`) via this lock mechanism using `abi.encodeCall`.

## How It Works: LVR Liquidity Management Strategy

The `LVRLiquidityManager` implements an advanced liquidity optimization strategy based on Loss-Versus-Rebalancing (LVR) research. This approach analyzes historical trading patterns to optimize liquidity allocation and maximize returns while minimizing losses from adverse selection.

### Key Components & Workflow:

1.  **Data Collection & Analysis:**
    *   **`StatCollectorHook`:** Monitors and records all liquidity changes, swaps, and other pool activities in real-time.
    *   **`LZReadStatDataProvider`:** Uses LayerZero's cross-chain reading capabilities to retrieve historical pool data from previous time periods.
    *   **Fee Rate Calculation:** Combines current and historical data to calculate the pool's effective fee rate over configurable time intervals.

2.  **Algorithm-Based Position Optimization:**
    *   **LVR Analysis:** Implements research-based algorithms that analyze the relationship between fee earnings and losses from adverse selection (LVR).
    *   **Risk Parameters:** Uses configurable parameters (gamma, volatility, drift) scaled to 1e18 precision to model market conditions and risk preferences.
    *   **Optimal Allocation:** Calculates the theoretically optimal liquidity distribution based on the analyzed fee rates and market parameters.

3.  **Automated Rebalancing:**
    *   **`PositionManager`:** Determines when current positions deviate significantly from optimal allocations.
    *   **`Rebalancer`:** Executes necessary position adjustments to realign with target proportions.
    *   **Scheduled Updates:** Rebalancing occurs at regular intervals defined by `feeRateReadingInterval`.

4.  **ERC20 Share Management:**
    *   **`LiquidityAccounting`:** Manages the relationship between user deposits and their proportional shares in the optimized position.
    *   **Token Representation:** Users receive ERC20 tokens representing their stake in the managed liquidity pool.
    *   **Proportional Withdrawals:** Users can redeem shares for their proportional share of the current pool value.

5.  **Cross-Chain Data Integration:**
    *   **LayerZero Read:** Enables the hook to access historical data from other chains or previous time periods without relying on centralized oracles.
    *   **Configurable Confirmations:** Ensures data integrity by requiring a specified number of block confirmations before reading chain state.
    *   **Decentralized Operation:** Reduces reliance on external data providers while maintaining access to comprehensive historical information.

### Operational Requirements:

*   **Backend Automation:** Requires automated systems to trigger fee rate updates and position rebalancing at appropriate intervals.
*   **LayerZero Integration:** Depends on LayerZero infrastructure for cross-chain data access and historical analysis.
*   **Continuous Monitoring:** Benefits from continuous monitoring of market conditions and algorithm performance.

## Prerequisites

Ensure you have the following installed before starting:

*   [Node.js](https://nodejs.org/) (Version `^18.0` or `^20.0` recommended - check `package.json` engines field)
*   [Yarn](https://yarnpkg.com/) or [npm](https://www.npmjs.com/)
*   [Git](https://git-scm.com/)

## Getting Started

Set up the project on your local machine.

### Cloning the Repository

```bash
git clone https://github.com/Nexera-Foundation/uniswap-v4-hooks.git
cd uniswap-v4-hooks
```


### Installing Dependencies

Install the necessary project dependencies using Yarn or npm:

```bash
# Using Yarn (Recommended if yarn.lock is present)
yarn install

# Or using npm
npm install
```

## Configuration

### Environment Variables

Deployment scripts and Hardhat tasks rely on environment variables for network RPC endpoints, deployer private keys, and potentially Etherscan API keys for verification.

1.  Create a `.env` file in the root directory by copying the example file:
    ```bash
    cp .env.example .env
    ```
2.  Edit the `.env` file and add your specific credentials and endpoints:

    ```dotenv
    # .env Example - Fill with your actual values

    # RPC URLs for connecting to blockchain networks (e.g., Alchemy, Infura)
    # Required for deployment and potentially for running tests against forks
    MAINNET_RPC_URL="https://mainnet.infura.io/v3/YOUR_INFURA_PROJECT_ID"
    SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/YOUR_INFURA_PROJECT_ID"
    # Add other networks from hardhat.networks.ts as needed (e.g., POLYGON_RPC_URL)

    # Deployer Private Key
    # The private key of the account you want to use for deploying contracts.
    # This account will own the Factory and, initially, the deployed hooks.
    # IMPORTANT: Use a dedicated deployer account with limited funds. NEVER commit a private key for an account holding significant assets.
    # Ensure the key starts with 0x.
    DEPLOYER_PRIVATE_KEY="0x..."

    # Etherscan API Key (Optional, but needed for automatic contract verification)
    ETHERSCAN_API_KEY="YOUR_ETHERSCAN_API_KEY"
    # Add API keys for other block explorers if listed in hardhat.config.ts (e.g., POLYGONSCAN_API_KEY)

    # Optional: CoinMarketCap API Key for gas reporter (if REPORT_GAS is enabled)
    # COINMARKAETCAP_KEY="YOUR_CMC_API_KEY"
    ```

**Security Warning:** **NEVER** commit your `.env` file to Git history, especially if it contains private keys. The provided `.gitignore` file should prevent this, but always double-check.

## Usage (Hardhat)

This project utilizes [Hardhat](https://hardhat.org/) as the development environment for compiling, testing, and deploying Solidity smart contracts.

### Compiling Contracts

Compile the Solidity contracts and generate TypeChain artifacts:

```bash
npx hardhat compile
```
Compiled artifacts will be placed in the `artifacts/` directory, and TypeChain bindings (if using TypeScript) will be generated in `typechain-types/.`

### Running Tests

Execute the automated test suite. Tests are typically located in the `tests/` directory.

```bash
npx hardhat test
```

To run tests for a specific file:

    # Example: Run tests for the Zero IL hook
    npx hardhat test tests/ZeroILHook.test.ts
    # Adjust the path and file extension (.js) based on your test setup


<!-- Optional: Add if code coverage is configured -->
<!--
To generate a code coverage report:
```bash
npx hardhat coverage

The report will typically be saved in the  `coverage/` directory.
-->

### Deploying Hooks

Both hook implementations can be deployed through different approaches depending on the specific requirements:

#### Deploying ZeroILSwapSamePoolHook

Deploying the `ZeroILSwapSamePoolHook` requires using the `UniswapV4HookFactory` to ensure the hook address meets Uniswap V4's validation requirements.

#### Step 1: Deploy the `UniswapV4HookFactory`

First, deploy the factory contract to your target network. You should have a deployment script for this (e.g., `scripts/deployFactory.ts`).

```bash
# Example: Deploying the factory to the Sepolia test network
npx hardhat run scripts/deployFactory.ts --network sepolia
```
Record the deployed factory address. The account used for this deployment will be the owner of the factory.

#### Step 2: Find the Correct Salt

The hook needs to be deployed using `CREATE2` at an address that correctly reflects its implemented callbacks (`afterInitialize`, `afterSwap`). The factory's `computeAddress` function helps find a `salt` (a `bytes32` value) that results in such an address.

*   **Mechanism:** You need to iterate through different `salt` values, calculate the potential address using `factory.computeAddress`, and check if that address is valid using `factory.verifyHookAddress` or `Hooks.validateHookAddress`.
*   **Tooling:** Create a Hardhat script or task (e.g., `scripts/findHookSalt.ts`) to automate this search. This script would typically:
    1.  Get the creation bytecode for `ZeroILSwapSamePoolHook`.
    2.  ABI-encode the constructor arguments required by `ZeroILSwapSamePoolHook` (likely `poolManagerAddress` and `erc1155TokenURI`).
    3.  Loop through potential `salt` values (e.g., `keccak256(abi.encodePacked(uint256(i)))`).
    4.  Call `factory.computeAddress(hookBytecode, constructorArgs, salt)` on the *deployed* factory instance.
    5.  Call `factory.verifyHookAddress(computedAddress, expectedFlags)` or `Hooks.validateHookAddress(computedAddress, expectedFlags)`. The `expectedFlags` for `ZeroILHook` should correspond to `afterInitialize` and `afterSwap` being true.
    6.  Stop when a valid salt/address combination is found.

**Record the `salt` that yields a valid hook address.**

#### Step 3: Deploy the Hook via the Factory

Once you have the correct `salt` and the factory address, the *owner* of the factory can deploy the hook.

*   **Mechanism:** Use another Hardhat script or task (e.g., `scripts/deployHookViaFactory.ts`) that calls the `deploy` function on the deployed factory instance.
*   **Arguments:** The script will need the hook's creation bytecode, the ABI-encoded constructor arguments, and the validated `salt`.
*   **Ownership:** The `deploy` function in the provided `UniswapV4HookFactory` is coded to transfer ownership of the newly deployed `ZeroILSwapSamePoolHook` to the `msg.sender` (who is the factory owner calling the `deploy` function).

```bash
# Example: Deploy hook via factory (requires factory address and correct salt)
npx hardhat run scripts/deployHookViaFactory.ts --network sepolia \
  --factory <FACTORY_CONTRACT_ADDRESS> \
  --salt <CORRECT_SALT_FOUND_IN_STEP_2> \
  --uri <YOUR_ERC1155_TOKEN_URI> \
  # --poolmanager <POOL_MANAGER_ADDRESS> (if not hardcoded in script)
```
Record the deployed hook address. This is the address you will use when initializing the Uniswap V4 pool.

### Configuring the Deployed Hook

After deployment and *before* initializing a pool with it, the hook must be configured for that specific pool. The owner of the *hook* contract (which should be the account that deployed the factory) needs to call `setConfig`.

1.  **Identify PoolKey:** Determine the parameters (`currency0`, `currency1`, `fee`, `tickSpacing`) for the Uniswap V4 pool you intend to create. The `hooks` address in the key will be your newly deployed hook address.
2.  **Define Config:** Decide on the `PoolConfig` values:
    *   `desiredPositionRangeTickLower`/`Upper`: How wide should the liquidity range be (relative to the center tick)? Must be multiples of `tickSpacing`.
    *   `shiftPositionLower`/`UpperTickDistance`: How far can the price move from the position bounds before it's recentered? Must be multiples of `tickSpacing`.
    *   `il0percentageToSwapX96`/`il1percentageToSwapX96`: What percentage of IL triggers a compensation swap? Use `ethers.utils.parseUnits` or similar tools to handle the Q96 fixed-point representation correctly (e.g., 1% = `(1 * 2**96) / 100`).
3.  **Call `setConfig`:** Use a script or Hardhat task to call the `setConfig` function on the deployed hook contract instance, passing the `PoolKey` struct and the `PoolConfig` struct.

```javascript
// Example using ethers.js in a configuration script/task

const hookAddress = "0x..."; // Your deployed hook address
const hookOwnerSigner = await ethers.getSigner(factoryOwnerAddress); // Signer for the hook owner
const hookContract = await ethers.getContractAt("ZeroILSwapSamePoolHook", hookAddress, hookOwnerSigner);

const poolKey = {
  currency0: "0xTokenAAddress...",
  currency1: "0xTokenBAddress...",
  fee: 3000,       // e.g., 0.3%
  tickSpacing: 60, // Must match the intended pool's tickSpacing
  hooks: hookAddress
};

// Example: 1% IL threshold (adjust Q96 calculation as needed)
const ONE_PERCENT_X96 = ethers.BigNumber.from("2").pow(96).div(100);

const poolConfig = {
  desiredPositionRangeTickLower: -600, // 10 * tickSpacing below center
  desiredPositionRangeTickUpper: 600,  // 10 * tickSpacing above center
  shiftPositionLowerTickDistance: -120, // Shift if price moves 2 ticks below lower bound
  shiftPositionUpperTickDistance: 120,  // Shift if price moves 2 ticks above upper bound
  il0percentageToSwapX96: ONE_PERCENT_X96,
  il1percentageToSwapX96: ONE_PERCENT_X96
};

console.log(`Configuring hook ${hookAddress} for pool key:`, poolKey);
console.log(`With config:`, poolConfig);

const tx = await hookContract.setConfig(poolKey, poolConfig);
const receipt = await tx.wait();
console.log("Hook configured successfully. Tx:", receipt.transactionHash);
```

#### Deploying LVRLiquidityManager

The `LVRLiquidityManager` can be deployed directly without requiring the factory, as it doesn't need specific address validation for hook flags in the same way.

1.  **Prepare Deployment Parameters:**
    *   `poolManager`: Address of the Uniswap V4 Pool Manager
    *   `poolKey`: Pool configuration structure
    *   `name` & `symbol`: ERC20 token identifiers for LP shares
    *   `LZReadConfig`: LayerZero configuration object containing endpoint, EID, read channel, confirmations, and delegate addresses

2.  **Deploy the Contract:**
    ```bash
    # Example deployment script for LVRLiquidityManager
    npx hardhat run scripts/deployLVRManager.ts --network sepolia
    ```

3.  **Post-Deployment Configuration:**
    *   Set algorithm parameters (gamma, volatility, drift)
    *   Configure LayerZero read settings (feeRateReadingInterval, intermediateLiquidityPoints)
    *   Set up backend automation for fee rate updates and position rebalancing

### Integrating Hooks with Uniswap V4 Pools

With either hook deployed and configured for the specific pool parameters, you can now initialize the pool via the `PoolManager`.

1.  **Pool Parameters:** Have the `token0`, `token1`, `fee`, `tickSpacing`, the deployed `hookAddress`, and the desired `initialSqrtPriceX96` ready.
2.  **Construct `PoolKey`:** Create the `PoolKey` struct, ensuring the `hooks` field points to your deployed hook address.
3.  **Call `PoolManager.initialize`:** Interact with the official Uniswap V4 `PoolManager` contract on your target network. Call its `initialize` function.
    *   `key`: The `PoolKey` constructed above.
    *   `sqrtPriceX96`: The starting price for the pool.
    *   `hookData`: `bytes("")` (empty bytes) for this hook, as its `afterInitialize` implementation doesn't require initialization data.

```solidity
// Conceptual Solidity Snippet for Pool Initialization

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// --- Assume these are defined ---
address poolManagerAddress = 0x...; // Official V4 PoolManager
address token0Address = 0x...;
address token1Address = 0x...;
uint24 poolFee = 3000;
int24 poolTickSpacing = 60;
address deployedHookAddress = 0x...; // Your deployed ZeroILHook address
uint160 initialSqrtPriceX96 = ...; // Calculated initial sqrt price
// ---

IPoolManager poolManager = IPoolManager(poolManagerAddress);

PoolKey memory key = PoolKey({
    currency0: CurrencyLibrary.wrap(token0Address),
    currency1: CurrencyLibrary.wrap(token1Address),
    fee: poolFee,
    tickSpacing: poolTickSpacing,
    hooks: IHooks(deployedHookAddress) // <-- Assign your hook address here
});

// Verify hook's setConfig was called for this specific key beforehand

// Initialize the pool - PoolManager handles pool contract deployment internally
poolManager.initialize(key, initialSqrtPriceX96, bytes("")); // Empty hookData

// Pool is now live and managed by the ZeroILHook.
// LPs should interact via hook.addLiquidity / hook.withdrawLiquidity.
```

### Development Environment

This project leverages a standard Hardhat setup:

*   **Framework:** [Hardhat](https://hardhat.org/) (`hardhat.config.ts`)
*   **Solidity Versions:** Primarily `^0.8.0` and `^0.8.19`, `^0.8.28` (check `hardhat.config.ts` and contract pragmas). Uses `viaIR` and `cancun` EVM version.
*   **Core Libraries:**
    *   [Ethers.js](https://docs.ethers.io/): For blockchain interaction in scripts and tests.
    *   [TypeChain](https://github.com/dethcrypto/TypeChain): For generating TypeScript contract bindings (`@typechain/hardhat`).
    *   [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts): For `Ownable`, `ERC1155`, `ERC20`, `Create2`, `SafeERC20`.
    *   [Uniswap V4 Core](https://github.com/Uniswap/v4-core): Interfaces (`IPoolManager`, `IHooks`), types (`PoolKey`, `BalanceDelta`), and libraries (`Hooks`, `TickMath`, etc.). Referenced via `@uniswap/v4-core`.
    *   [LayerZero OApp](https://github.com/LayerZero-Labs/oapp-evm): For cross-chain functionality and data reading capabilities (`@layerzerolabs/oapp-evm`).
*   **Testing:** Mocha, Chai (implicitly via Hardhat).
*   **Helpers/Plugins:**
    *   `hardhat-gas-reporter`: For estimating gas costs (`hardhat-gas-reporter`).
    *   `hardhat-contract-sizer`: For checking contract size limits.
    *   (Potentially others - check `package.json`)

Review `hardhat.config.ts`, `hardhat.networks.ts`, `package.json`, and `yarn.lock` for full dependency and configuration details.

### Contributing

Contributions are highly appreciated! If you'd like to contribute, please adhere to the following process:

1.  **Fork the Repository:** Create your personal fork of the project on GitHub.
2.  **Create a Branch:** Make a new branch in your fork for your contribution (`git checkout -b feat/my-improvement` or `fix/bug-description`).
3.  **Develop:** Implement your changes, adhering to the existing code style and conventions.
4.  **Test:** Write comprehensive unit tests for any new functionality or bug fixes. Ensure all tests pass using `npx hardhat test`.
5.  **Lint/Format:** Run any configured linters or formatters to maintain code consistency.
6.  **Commit:** Make clear and concise commit messages, potentially following conventional commit standards (e.g., `feat:`, `fix:`, `docs:`, `refactor:`).
7.  **Push:** Push your branch to your forked repository (`git push origin feat/my-improvement`).
8.  **Open a Pull Request:** Submit a pull request from your branch to the `main` branch of the `Nexera-Foundation/uniswap-v4-hooks` repository. Clearly describe the purpose and changes in your PR.

Consider opening an issue first to discuss significant changes or new features before investing development time.

### License

This project is distributed under the **MIT License**. See the `LICENSE` file for details. (SPDX-License-Identifier: MIT found in contracts).

### Support & Contact

For assistance, questions, or to report issues related to these hooks:

1.  **Check Existing Issues:** Browse the [GitHub Issues](https://github.com/Nexera-Foundation/uniswap-v4-hooks/issues) page for existing reports or discussions.
2.  **Open a New Issue:** If your issue is new, please [create a new issue](https://github.com/Nexera-Foundation/uniswap-v4-hooks/issues/new), providing detailed information:
    *   The specific contract or function involved.
    *   Steps to reproduce the problem.
    *   Expected behavior vs. actual behavior.
    *   Network (if applicable).
    *   Any relevant transaction hashes or error messages.

To learn more about the Nexera Foundation:

*   **Website:** [https://nexera.network/](https://nexera.network/)
*   **Discord:** [https://discord.com/invite/fB4tkF52H5](https://discord.com/invite/fB4tkF52H5)
*   **Twitter / X:** [https://nexera.network/](https://x.com/Nexera_Official)
*   **Contact Email:** [contact@nexera.network](contact@nexera.network)

---


