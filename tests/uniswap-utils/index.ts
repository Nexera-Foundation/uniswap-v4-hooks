import {BigNumberish, toBigInt} from "ethers";

export function sqrtPriceToPrice(sqrtPriceX96: BigNumberish, token0Decimals: BigNumberish, token1Decimals: BigNumberish): bigint {
    let mathPrice = toBigInt(sqrtPriceX96) ** toBigInt(2) / toBigInt(2) ** toBigInt(192);
    const decimalAdjustment = toBigInt(10) ** (toBigInt(token0Decimals) - toBigInt(token1Decimals));
    const price = mathPrice * decimalAdjustment;
    return price;
}

export function getQ96Percentage(percentageDesired: BigNumberish): bigint {
    return ((toBigInt("1208925819614629174706176") * toBigInt(percentageDesired)) / toBigInt("100")) * toBigInt("2") ** toBigInt("16");
}

export function addressAIsGreater(addressA: string, addressB: string): boolean {
    return toBigInt(addressA) > toBigInt(addressB);
}
