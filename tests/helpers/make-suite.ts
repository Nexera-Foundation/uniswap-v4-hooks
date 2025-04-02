import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import {ethers} from "hardhat";

let snapshotId: string;

export interface TestEnv {
    deployer: SignerWithAddress;
    minter: SignerWithAddress;
    admin: SignerWithAddress;
    users: SignerWithAddress[];
}

const setSnapshot = async () => {
    snapshotId = await ethers.provider.send("evm_snapshot", []);
};

const revertHead = async () => {
    await ethers.provider.send("evm_revert", [snapshotId]);
};

const testEnv: TestEnv = {
    deployer: {} as SignerWithAddress,
    minter: {} as SignerWithAddress,
    admin: {} as SignerWithAddress,
    users: [] as SignerWithAddress[],
} as TestEnv;

export function makeSuite(name: string, tests: (testEnv: TestEnv) => void) {
    describe(name, () => {
        before(async () => {
            await setSnapshot();
        });
        tests(testEnv);
        after(async () => {
            await revertHead();
        });
    });
}

// Used outside of the test suite to deploy a contract
export function exposeTestEnv(): TestEnv {
    return testEnv;
}

export async function initializeMakeSuite() {
    const [deployer, admin, minter, ...restSigners] = await ethers.getSigners();

    testEnv.deployer = deployer;
    testEnv.admin = admin;
    testEnv.minter = minter;

    for (const signer of restSigners) {
        testEnv.users.push(signer);
    }
}
