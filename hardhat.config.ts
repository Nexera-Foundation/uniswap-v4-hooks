import * as dotenv from "dotenv";
import "@nomicfoundation/hardhat-toolbox";
import { HardhatUserConfig } from "hardhat/config";
import "hardhat-gas-reporter";
import "hardhat-contract-sizer";
import "@typechain/hardhat";

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
          viaIR: true,
          evmVersion: `cancun`,
        },
      },
      {
        version: "0.8.26",
        settings: {
          optimizer: {
            enabled: true,
          },
          viaIR: true,
          evmVersion: `cancun`,
        },
      }
    ],
  },
  networks,
  namedAccounts: {
    deployer: 0,
    admin: 1,
    minter: 2,
    user: 3,
  },
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
  typechain: {
    alwaysGenerateOverloads: true,
    outDir: "typechain",
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./tests",
  },
};

export default config;
