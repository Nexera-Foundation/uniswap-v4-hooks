import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import {deployments, ethers} from "hardhat";
import {makeSuite, TestEnv} from "./helpers/make-suite";
import {deployContract} from "../shared/fixtures";
import {ZeroILSwapSamePoolHookMock, UniswapV4HookFactory, PoolManagerMock, ERC20Mock, PoolModifierMock} from "../typechain";
import {expect} from "chai";
import { addressAIsGreater, getQ96Percentage } from "./uniswap-utils";
import { BigNumber } from "ethers";

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
    afterRemoveLiquidityReturnDelta: false
}


const ONE_TOKEN = ethers.utils.parseEther("1")

export default async function suite() {
    makeSuite("UniswapV4", (testEnv: TestEnv) => {
        let deployer: SignerWithAddress;
        let users: SignerWithAddress[];
        
        let PoolManager: PoolManagerMock;
        let PoolModifier: PoolModifierMock;

        let initialLiquidityCurrency0: BigNumber;
        let initialLiquidityCurrency1: BigNumber;

        let ZeroILHook: ZeroILSwapSamePoolHookMock;
        let UniswapV4Hook: UniswapV4HookFactory;
        
        let token_A: ERC20Mock;
        let token_B: ERC20Mock;
        
        const SQRT_RATIO_1_1 = "79228162514264337593543950336";

        let PoolConfig;
        let PoolKey;
        let PoolId: string;
        
        let snap: string;
        
        before(async () => {
            deployer = (await hre.ethers.getSigners())[0];
            
            users = testEnv.users;
            
            token_A = await deployContract("ERC20Mock", [], deployer) as ERC20Mock;
            token_B = await deployContract("ERC20Mock", [], deployer) as ERC20Mock;

            if (addressAIsGreater(token_A.address, token_B.address)) {
                [token_A, token_B] = [token_B, token_A];
            }

            token_A.mint(ethers.utils.parseEther("10000000"));
            token_B.mint(ethers.utils.parseEther("10000000"));

            for(let i = 0; i < users.length; i++) {
                token_A.connect(users[i]).mint(ethers.utils.parseEther("100000"));
                token_B.connect(users[i]).mint(ethers.utils.parseEther("100000"));
            }
            // Deploy and get contracts
            PoolManager = (await deployContract("PoolManagerMock", [ethers.utils.parseUnits("1", "2")], deployer)) as PoolManagerMock;
            UniswapV4Hook = (await deployContract("UniswapV4HookFactory", [], deployer)) as UniswapV4HookFactory;
            PoolModifier = (await deployContract("PoolModifierMock", [PoolManager.address], deployer)) as PoolModifierMock;

            let hookBytecode = (await deployments.getArtifact("ZeroILSwapSamePoolHookMock")).bytecode;
            const hookArgs = ethers.utils.defaultAbiCoder.encode(["address", "string"], [PoolManager.address, "uniswapHook"]);
            
            let salt = 0;
            let found;
            let computedAddress;
            
            do {
                salt +=1;
                computedAddress = await UniswapV4Hook.computeAddress(hookBytecode, hookArgs, ethers.utils.hexZeroPad(ethers.utils.hexlify(salt), 32));
                found = await UniswapV4Hook.verifyHookAddressPermissions(computedAddress, HOOK_PERMISSIONS);
            }  while(!found && salt < 1000);
            if(!found) {
                console.error("Could not find correct salt. Deployment failed.");
            }

            const zeroILHookAddress = await UniswapV4Hook.callStatic.deployOwnable(hookBytecode, hookArgs, ethers.utils.hexZeroPad(ethers.utils.hexlify(salt), 32));
            
            await UniswapV4Hook.deployOwnable(hookBytecode, hookArgs, ethers.utils.hexZeroPad(ethers.utils.hexlify(salt), 32));
            
            ZeroILHook = await ethers.getContractAt("ZeroILSwapSamePoolHookMock", zeroILHookAddress) as ZeroILSwapSamePoolHookMock;
            
            PoolKey = {
                currency0: token_A.address,
                currency1: token_B.address,
                fee: 0,
                tickSpacing: 10,
                hooks: zeroILHookAddress
            };
            
            PoolConfig = {
                desiredPositionRangeTickLower: -100,
                desiredPositionRangeTickUpper: 100,
                shiftPositionLowerTickDistance: -50,
                shiftPositionUpperTickDistance: 50,
                il0percentageToSwapX96: getQ96Percentage(1),
                il1percentageToSwapX96: getQ96Percentage(1)
            };
            
            await ZeroILHook.setConfig(PoolKey, PoolConfig);
            
            PoolId = await ZeroILHook.getPoolId(PoolKey);

            await PoolManager.initialize(PoolKey, SQRT_RATIO_1_1, "0x00");

            await token_A.increaseAllowance(PoolModifier.address, ONE_TOKEN.mul("1000"));
            await token_B.increaseAllowance(PoolModifier.address, ONE_TOKEN.mul("1000"));
            
            const initialLiquidity = {
                tickLower: -100,
                tickUpper: 100,
                liquidityDelta: ONE_TOKEN.mul("200000")
            };

            await PoolModifier.modifyPosition(PoolKey, initialLiquidity, "0x00");
            
            initialLiquidityCurrency0 = await token_A.balanceOf(PoolManager.address);
            initialLiquidityCurrency1 = await token_B.balanceOf(PoolManager.address);

            expect(initialLiquidityCurrency0).to.be.equal(ONE_TOKEN.mul("997").add("454414149819226701"));
            expect(initialLiquidityCurrency1).to.be.equal(ONE_TOKEN.mul("997").add("454414149819226701"));

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
                await token_A.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("1000"));
                await token_B.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("1000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN.mul("1000"), ONE_TOKEN.mul("1000"));

                expect(await token_A.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency0.add(ONE_TOKEN.mul("1000")));
                expect(await token_B.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency1.add(ONE_TOKEN.mul("1000")));
            });

            it("Should Add Liquidity of A & B by 5 users", async () => {
                for (let i = 0; i < 5; i++) {
                    await token_A.connect(users[i]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("1000"));
                    await token_B.connect(users[i]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("1000"));

                    await ZeroILHook.connect(users[i]).addLiquidity(PoolId, ONE_TOKEN.mul("1000"), ONE_TOKEN.mul("1000"));

                    expect(await token_A.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency0.add(ONE_TOKEN.mul(`${i + 1}000`)));
                    expect(await token_B.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency1.add(ONE_TOKEN.mul(`${i + 1}000`)));
                }
            });

            it("Should Increase Liquidity and Withdraw position", async () => {
                await token_A.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("1000"));
                await token_B.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("1000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN.mul("1000"), ONE_TOKEN.mul("1000"));

                expect(await token_A.balanceOf(PoolManager.address)).equal(initialLiquidityCurrency0.add(ONE_TOKEN.mul("1000")));
                expect(await token_B.balanceOf(PoolManager.address)).equal(initialLiquidityCurrency0.add(ONE_TOKEN.mul("1000")));

                await ZeroILHook.connect(users[0]).withdrawLiquidity(PoolId, ONE_TOKEN.mul("200000"));

                expect(await token_A.balanceOf(PoolManager.address)).to.be.equal(ONE_TOKEN.mul("1000").add("1"));
                expect(await token_A.balanceOf(users[0].address)).to.be.equal(ONE_TOKEN.mul("100000").sub("2545585850180773300"));

                expect(await token_B.balanceOf(PoolManager.address)).to.be.equal(ONE_TOKEN.mul("1000").add("1"));
                expect(await token_B.balanceOf(users[0].address)).to.be.equal(ONE_TOKEN.mul("100000").sub("2545585850180773300"));
            });

            it("Should swap token A to B", async () => {
                await token_A.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("10000"));
                await token_B.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("10000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN.mul("1000"), ONE_TOKEN.mul("1000"));

                expect(await token_A.balanceOf(PoolManager.address)).equal(initialLiquidityCurrency0.add(ONE_TOKEN.mul("1000")));
                expect(await token_B.balanceOf(PoolManager.address)).equal(initialLiquidityCurrency1.add(ONE_TOKEN.mul("1000")));

                const ZERO_FOR_ONE = true;

                const TEST_SETTINGS = [
                    true,
                    true
                ]

                const SWAP_DATA = ethers.utils.defaultAbiCoder.encode(["int24", "int24", "int24"], [10, -100, 100]);

                const HOOK_DATA = ethers.utils.defaultAbiCoder.encode(["tuple(bool,bool)", "bytes"], [TEST_SETTINGS, SWAP_DATA]);

                await ZeroILHook.connect(users[0]).swap(PoolId, ZERO_FOR_ONE, ONE_TOKEN.mul("1000"), HOOK_DATA);

                expect(await token_A.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency0.add(ONE_TOKEN.mul("2000")));
                expect(await token_B.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency1.add("2490595409128807800"));

            });

            it("Should swap token B to A", async () => {
                await token_A.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("10000"));
                await token_B.connect(users[0]).increaseAllowance(ZeroILHook.address, ONE_TOKEN.mul("10000"));

                await ZeroILHook.connect(users[0]).addLiquidity(PoolId, ONE_TOKEN.mul("1000"), ONE_TOKEN.mul("1000"));

                expect(await token_A.balanceOf(PoolManager.address)).equal(initialLiquidityCurrency0.add(ONE_TOKEN.mul("1000")));
                expect(await token_B.balanceOf(PoolManager.address)).equal(initialLiquidityCurrency1.add(ONE_TOKEN.mul("1000")));

                const ZERO_FOR_ONE = false;

                const TEST_SETTINGS = [
                    true,
                    true
                ]

                const SWAP_DATA = ethers.utils.defaultAbiCoder.encode(["int24", "int24", "int24"], [10, -100, 100]);

                const HOOK_DATA = ethers.utils.defaultAbiCoder.encode(["tuple(bool,bool)", "bytes"], [TEST_SETTINGS, SWAP_DATA]);

                await ZeroILHook.connect(users[0]).swap(PoolId, ZERO_FOR_ONE, ONE_TOKEN.mul("1000"), HOOK_DATA);

                expect(await token_B.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency1.add(ONE_TOKEN.mul("2000")));
                expect(await token_A.balanceOf(PoolManager.address)).to.be.equal(initialLiquidityCurrency0.add("2490595409128807800"));

            });
        });
    });
}
