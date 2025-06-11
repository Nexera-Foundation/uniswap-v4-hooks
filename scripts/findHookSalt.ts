import { task } from "hardhat/config";

task("findHookSalt")
  .addParam("uniswapV4HookFactoryAddress", "The address of the UniswapV4HookFactory contract")
  .addParam("limit", "The number of salts to check")
  .addParam("hookBytecode", "The bytecode of the hook contract")
  .addVariadicPositionalParam("hookArgs", "The constructor arguments of the hook contract")
  .addParam("permissions", "The permissions for the hook contract")
  .setAction(async (taskArgs, hre) => {
    const uniswapV4HookFactory = await hre.ethers.getContractAt(
      "UniswapV4HookFactory",
      taskArgs.uniswapV4HookFactoryAddress
    );

    for (let i = 0; i < Number(taskArgs.limit); i++) {
        const salt = hre.ethers.keccak256(hre.ethers.solidityPacked(["uint"], [i + 12000]));

        const computedAddress = await uniswapV4HookFactory.computeAddress(
            taskArgs.hookBytecode,
            taskArgs.hookArgs,
            salt
        );
        const found = await uniswapV4HookFactory.verifyHookAddressPermissions(computedAddress, JSON.parse(taskArgs.permissions));

        if (found) {
            console.log(`Found matching salt: ${salt}`);
            return salt;
        }
    }
  });
