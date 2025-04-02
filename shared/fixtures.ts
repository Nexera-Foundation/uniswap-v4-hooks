import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import {ethers} from "hardhat";

export async function deployContract(name: string, args: any[], signer: SignerWithAddress) {
    const contractFactory = await ethers.getContractFactory(name);
    return await contractFactory.connect(signer).deploy(...args);
}
