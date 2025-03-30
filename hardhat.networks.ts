const networks: any = {
  localhost: {
    chainId: 31337,
    url: "http://127.0.0.1:8545",
    allowUnlimitedContractSize: true,
    timeout: 1000 * 60,
  },
  hardhat: {
    live: false,
    // forking: {
    //   url: `https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_KEY}`,
    //   blockNumber: 5734000,
    // },
    allowUnlimitedContractSize: true,
    gas: 30000000,
    saveDeployments: true,
  },
};

export default networks;
