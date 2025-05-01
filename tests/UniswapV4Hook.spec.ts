import {SignerWithAddress} from "@nomicfoundation/hardhat-ethers/signers";
import {ethers} from "hardhat";
import {makeSuite, TestEnv} from "./helpers/make-suite";
import {deployContract} from "../shared/fixtures";
import {ZeroILSwapSamePoolHookMock, UniswapV4HookFactory, PoolManagerMock, ERC20Mock, PoolModifierMock} from "../typechain";
import {expect} from "chai";
import {addressAIsGreater, getQ96Percentage} from "./uniswap-utils";
import {BigNumberish} from "ethers";

let mainSnap: any;

const HOOK_PERMISSIONS = {
    beforeInitialize: false,
    afterInitialize: true,
    beforeAddLiquidity: false,
    afterAddLiquidity: false,
    beforeRemoveLiquidity: false,
    afterRemoveLiquidity: false,
    beforeSwap: false,
    afterSwap: true,
    beforeDonate: false,
    afterDonate: false,
    beforeSwapReturnDelta: false,
    afterSwapReturnDelta: false,
    afterAddLiquidityReturnDelta: false,
    afterRemoveLiquidityReturnDelta: false,
};

const ONE_TOKEN = ethers.parseEther("1");

export default async function suite() {
    makeSuite("UniswapV4", (testEnv: TestEnv) => {
        let deployer: SignerWithAddress;
        let users: SignerWithAddress[];

        let PoolManager: PoolManagerMock;

        let initialLiquidityCurrency0: BigNumberish;
        let initialLiquidityCurrency1: BigNumberish;

        let ZeroILHook: ZeroILSwapSamePoolHookMock;
        let UniswapV4Hook: UniswapV4HookFactory;

        let token_A: ERC20Mock;
        let token_B: ERC20Mock;

        const SQRT_RATIO_1_1 = "79228162514264337593543950336";

        let PoolConfig;
        let PoolKey;
        let PoolId: string;

        let snap: string;

        let zeroILHookAddress: string;

        before(async () => {
            deployer = (await hre.ethers.getSigners())[0];

            users = testEnv.users;

            token_A = (await deployContract("ERC20Mock", [], deployer)) as ERC20Mock;
            token_B = (await deployContract("ERC20Mock", [], deployer)) as ERC20Mock;

            if (addressAIsGreater(await token_A.getAddress(), await token_B.getAddress())) {
                [token_A, token_B] = [token_B, token_A];
            }

            token_A.mint(ethers.parseEther("10000000"));
            token_B.mint(ethers.parseEther("10000000"));

            for (let i = 0; i < users.length; i++) {
                token_A.connect(users[i]).mint(ethers.parseEther("100000"));
                token_B.connect(users[i]).mint(ethers.parseEther("100000"));
            }
            // Deploy and get contracts
            PoolManager = (await deployContract("PoolManagerMock", [deployer.address], deployer)) as PoolManagerMock;
            UniswapV4Hook = (await deployContract("UniswapV4HookFactory", [], deployer)) as UniswapV4HookFactory;

            let hookBytecode = (await ethers.getContractFactory("ZeroILSwapSamePoolHookMock")).bytecode;
            const hookArgs = ethers.AbiCoder.defaultAbiCoder().encode(["address", "string"], [await PoolManager.getAddress(), "uniswapHook"]);

            let salt = 0;
            let found;
            let computedAddress;

            do {
                salt += 1;
                computedAddress = await UniswapV4Hook.computeAddress(hookBytecode, hookArgs, ethers.zeroPadValue(ethers.toBeHex(salt), 32));
                found = await UniswapV4Hook.verifyHookAddressPermissions(computedAddress, HOOK_PERMISSIONS);
            } while (!found && salt < 1000);
            if (!found) {
                console.error("Could not find correct salt. Deployment failed.");
            }

            const HookMinerMock = await deployContract("HookMinerMock", [], deployer) as HookMinerMock;
            const deploySalt = await HookMinerMock.getSalt(await PoolManager.getAddress(), await UniswapV4Hook.getAddress());

            zeroILHookAddress = await UniswapV4Hook.deploy.staticCall(hookBytecode, hookArgs, deploySalt);

            await UniswapV4Hook.deploy(hookBytecode, hookArgs, deploySalt);

            ZeroILHook = (await ethers.getContractAt("ZeroILSwapSamePoolHookMock", zeroILHookAddress)) as ZeroILSwapSamePoolHookMock;

            PoolKey = {
                currency0: await token_A.getAddress(),
                currency1: await token_B.getAddress(),
                fee: 0,
                tickSpacing: 10,
                hooks: zeroILHookAddress,
            };

            PoolConfig = {
                desiredPositionRangeTickLower: -100,
                desiredPositionRangeTickUpper: 100,
                shiftPositionLowerTickDistance: -50,
                shiftPositionUpperTickDistance: 50,
                il0percentageToSwapX96: getQ96Percentage(1),
                il1percentageToSwapX96: getQ96Percentage(1),
            };

            await ZeroILHook.setConfig(PoolKey, PoolConfig);

            PoolId = await ZeroILHook.getPoolId(PoolKey);

            await PoolManager.initialize(PoolKey, SQRT_RATIO_1_1);

            await token_A.approve(await PoolManager.getAddress(), ONE_TOKEN * ethers.toBigInt("1000"));
            await token_B.approve(await PoolManager.getAddress(), ONE_TOKEN * ethers.toBigInt("1000"));

            const initialLiquidity = {
                tickLower: -100,
                tickUpper: 100,
                liquidityDelta: ONE_TOKEN * ethers.toBigInt("200000"),
                salt: "0x00",
            };

            await PoolManager.modifyLiquidity(
                PoolKey,
                initialLiquidity,
                "0x00"
            )

            initialLiquidityCurrency0 = await token_A.balanceOf(await PoolManager.getAddress());
            initialLiquidityCurrency1 = await token_B.balanceOf(await PoolManager.getAddress());

            expect(initialLiquidityCurrency0).to.be.equal(ONE_TOKEN * ethers.toBigInt("997") + ethers.toBigInt("454414149819226701"));
            expect(initialLiquidityCurrency1).to.be.equal(ONE_TOKEN * ethers.toBigInt("997") + ethers.toBigInt("454414149819226701"));

            mainSnap = await ethers.provider.send("evm_snapshot", []);
        });

        beforeEach(async () => {
            snap = await ethers.provider.send("evm_snapshot", []);
        });

        afterEach(async function () {
            await ethers.provider.send("evm_revert", [snap]);
        });

        describe("UniswapV4 Tests", async () => {
            it("Should Increase Liquidity of A & B", async () => {
                await token_A.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("1000"));
                await token_B.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("1000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN * ethers.toBigInt("1000"), ONE_TOKEN * ethers.toBigInt("1000"));

                expect(await token_A.balanceOf(await PoolManager.getAddress())).to.be.equal(
                    ethers.toBigInt(initialLiquidityCurrency0) + ethers.toBigInt(ONE_TOKEN) * ethers.toBigInt("1000")
                );
                expect(await token_B.balanceOf(await PoolManager.getAddress())).to.be.equal(
                    ethers.toBigInt(initialLiquidityCurrency1) + ethers.toBigInt(ONE_TOKEN) * ethers.toBigInt("1000")
                );
            });

            it("Should Add Liquidity of A & B by 5 users", async () => {
                for (let i = 0; i < 5; i++) {
                    await token_A.connect(users[i]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("1000"));
                    await token_B.connect(users[i]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("1000"));

                    await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN * ethers.toBigInt("1000"), ONE_TOKEN * ethers.toBigInt("1000"));

                    expect(await token_A.balanceOf(await PoolManager.getAddress())).to.be.equal(
                        ethers.toBigInt(initialLiquidityCurrency0) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt(`${i + 1}000`))
                    );
                    expect(await token_B.balanceOf(await PoolManager.getAddress())).to.be.equal(
                        ethers.toBigInt(initialLiquidityCurrency1) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt(`${i + 1}000`))
                    );
                }
            });

            it("Should Increase Liquidity and Withdraw position", async () => {
                await token_A.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("1000"));
                await token_B.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("1000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN * ethers.toBigInt("1000"), ONE_TOKEN * ethers.toBigInt("1000"));

                expect(await token_A.balanceOf(await PoolManager.getAddress())).equal(
                    ethers.toBigInt(initialLiquidityCurrency0) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("1000"))
                );
                expect(await token_B.balanceOf(await PoolManager.getAddress())).equal(
                    ethers.toBigInt(initialLiquidityCurrency1) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("1000"))
                );

                await ZeroILHook.connect(users[0]).withdrawLiquidity(PoolId, ONE_TOKEN * ethers.toBigInt("200000"));

                expect(await token_A.balanceOf(await PoolManager.getAddress())).to.be.equal(ONE_TOKEN * ethers.toBigInt("1000") + ethers.toBigInt("1"));
                expect(await token_A.balanceOf(users[0].address)).to.be.equal(ONE_TOKEN * ethers.toBigInt("100000") - ethers.toBigInt("2545585850180773300"));

                expect(await token_B.balanceOf(await PoolManager.getAddress())).to.be.equal(ONE_TOKEN * ethers.toBigInt("1000") + ethers.toBigInt("1"));
                expect(await token_B.balanceOf(users[0].address)).to.be.equal(ONE_TOKEN * ethers.toBigInt("100000") - ethers.toBigInt("2545585850180773300"));
            });

            it("Should swap token A to B", async () => {
                await token_A.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("10000"));
                await token_B.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("10000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN * ethers.toBigInt("1000"), ONE_TOKEN * ethers.toBigInt("1000"));

                expect(await token_A.balanceOf(await PoolManager.getAddress())).equal(
                    ethers.toBigInt(initialLiquidityCurrency0) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("1000"))
                );
                expect(await token_B.balanceOf(await PoolManager.getAddress())).equal(
                    ethers.toBigInt(initialLiquidityCurrency1) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("1000"))
                );

                const ZERO_FOR_ONE = true;

                const TEST_SETTINGS = [true, true];

                const SWAP_DATA = ethers.AbiCoder.defaultAbiCoder().encode(["int24", "int24", "int24"], [10, -100, 100]);

                const HOOK_DATA = ethers.AbiCoder.defaultAbiCoder().encode(["tuple(bool,bool)", "bytes"], [TEST_SETTINGS, SWAP_DATA]);

                await ZeroILHook.connect(users[0]).swap(PoolKey, ZERO_FOR_ONE, ONE_TOKEN * ethers.toBigInt("1000"), HOOK_DATA);

                expect(await token_A.balanceOf(await PoolManager.getAddress())).to.be.equal(
                    ethers.toBigInt(initialLiquidityCurrency0) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("2000"))
                );
                expect(await token_B.balanceOf(await PoolManager.getAddress())).to.be.equal(
                    ethers.toBigInt(initialLiquidityCurrency1) + ethers.toBigInt("2490595409128807800")
                );
            });

            it("Should swap token B to A", async () => {
                await token_A.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("10000"));
                await token_B.connect(users[0]).approve(zeroILHookAddress, ONE_TOKEN * ethers.toBigInt("10000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN * ethers.toBigInt("1000"), ONE_TOKEN * ethers.toBigInt("1000"));

                expect(await token_A.balanceOf(await PoolManager.getAddress())).equal(
                    ethers.toBigInt(initialLiquidityCurrency0) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("1000"))
                );
                expect(await token_B.balanceOf(await PoolManager.getAddress())).equal(
                    ethers.toBigInt(initialLiquidityCurrency1) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("1000"))
                );

                const ZERO_FOR_ONE = false;

                const TEST_SETTINGS = [true, true];

                const SWAP_DATA = ethers.AbiCoder.defaultAbiCoder().encode(["int24", "int24", "int24"], [10, -100, 100]);

                const HOOK_DATA = ethers.AbiCoder.defaultAbiCoder().encode(["tuple(bool,bool)", "bytes"], [TEST_SETTINGS, SWAP_DATA]);

                await ZeroILHook.connect(users[0]).swap(PoolKey, ZERO_FOR_ONE, ONE_TOKEN * ethers.toBigInt("1000"), HOOK_DATA);

                expect(await token_B.balanceOf(await PoolManager.getAddress())).to.be.equal(
                    ethers.toBigInt(initialLiquidityCurrency1) + ethers.toBigInt(ONE_TOKEN * ethers.toBigInt("2000"))
                );
                expect(await token_A.balanceOf(await PoolManager.getAddress())).to.be.equal(
                    ethers.toBigInt(initialLiquidityCurrency0) + ethers.toBigInt("2490595409128807800")
                );
            });
        });
    });
}
