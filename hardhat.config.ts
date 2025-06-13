import * as dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-dependency-compiler";
import "hardhat-contract-sizer";

import "./scripts/findHookSalt";

dotenv.config();

import networks from "./hardhat.networks";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
          },
          evmVersion: `cancun`,
        },
      },
      {
        version: "0.8.26",
        settings: {
          optimizer: {
            enabled: true,
          },
          evmVersion: `cancun`,
        },
      }
    ],
  },
  networks,
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY || "",
      rinkeby: process.env.ETHERSCAN_API_KEY || "",
      polygon: process.env.POLYGONSCAN_API_KEY || "",
      polygonMumbai: process.env.POLYGONSCAN_API_KEY || "",
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    coinmarketcap: process.env.COINMARKAETCAP_KEY,
    outputFile: process.env.OUTPUT_FILE_PATH,
    currency: "USD",
    noColors: true,
    reportFormat: "markdown",
    forceTerminalOutput: true,
    forceTerminalOutputFormat: "terminal",
    // uncomment `parallel: true` in mocha config or report will be empty
  },
  mocha: {
    timeout: 200000,
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./tests",
  },
  dependencyCompiler: {
    paths: [
      "@uniswap/v4-core/src/PoolManager.sol",
      "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol",
      "@uniswap/v4-core/src/test/PoolSwapTest.sol",
    ]
  }
};

export default config;
