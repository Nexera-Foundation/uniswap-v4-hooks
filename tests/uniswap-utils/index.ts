import { BigNumber, BigNumberish } from "ethers";

export function sqrtPriceToPrice(sqrtPriceX96: BigNumber, token0Decimals: BigNumber, token1Decimals: BigNumber) {
    let mathPrice = sqrtPriceX96.pow(2).div(BigNumber.from(2).pow(192));
    const decimalAdjustment = BigNumber.from(10).pow(token0Decimals.sub(token1Decimals));
    const price = mathPrice.mul(decimalAdjustment);
    return price;
};

export function getQ96Percentage(percentageDesired: BigNumberish): BigNumber {
    return (BigNumber.from("1208925819614629174706176").mul(percentageDesired).div("100")).mul(BigNumber.from("2").pow("16"));
}

export function addressAIsGreater(addressA: string, addressB: string): boolean {
    return BigNumber.from(addressA).gt(BigNumber.from(addressB));
}