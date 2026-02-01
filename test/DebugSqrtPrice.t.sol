// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

contract DebugSqrtPrice is Test {
    function test_debug_sqrt_price() public view {
        uint160 minPrice = TickMath.MIN_SQRT_PRICE + 1;
        uint160 maxPrice = TickMath.MAX_SQRT_PRICE - 1;
        uint160 price1to1 = 79228162514264337593543950336;

        // Decode limit amounts
        uint256 limitFromMin = FullMath.mulDiv(uint256(minPrice), uint256(minPrice), 1 << 192);
        uint256 limitFromMax = FullMath.mulDiv(uint256(maxPrice), uint256(maxPrice), 1 << 192);
        uint256 limitFrom1to1 = FullMath.mulDiv(uint256(price1to1), uint256(price1to1), 1 << 192);

        console.log("MIN_SQRT_PRICE + 1:", minPrice);
        console.log("-> encodes limit:", limitFromMin);
        console.log("MAX_SQRT_PRICE - 1:", maxPrice);
        console.log("-> encodes limit (raw):", limitFromMax);
        console.log("-> encodes limit (eth):", limitFromMax / 1e18);
        console.log("SQRT_PRICE_1_1:", price1to1);
        console.log("-> encodes limit:", limitFrom1to1);

        // To get 50 ETH limit, we need sqrtPriceX96 = sqrt(50e18 * 2^192)
        // Let's work backwards - what sqrtPrice gives us 50 ETH?
        // sqrtPrice = sqrt(50e18 * 2^192) ≈ 5.6e38
        uint160 sqrtFor50Eth = 560336420176503098568846621647428000000; // computed offline
        console.log("For 50 ETH, sqrtPrice:", sqrtFor50Eth);
    }
}
