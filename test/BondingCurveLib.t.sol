// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BondingCurveLib } from "../src/BondingCurveLib.sol";

contract BondingCurveLibTest is Test {
    // Mirror constants for testing
    uint256 constant VIRTUAL_TOKEN_RESERVE = 800_000_000e18;
    uint256 constant VIRTUAL_ETH_RESERVE = 30 ether;
    uint256 constant K = VIRTUAL_TOKEN_RESERVE * VIRTUAL_ETH_RESERVE;
    uint256 constant SUPPLY_CAP = 200_000_000e18;

    function test_constants() public pure {
        assertEq(BondingCurveLib.VIRTUAL_TOKEN_RESERVE, VIRTUAL_TOKEN_RESERVE);
        assertEq(BondingCurveLib.VIRTUAL_ETH_RESERVE, VIRTUAL_ETH_RESERVE);
        assertEq(BondingCurveLib.K, K);
        assertEq(BondingCurveLib.SUPPLY_CAP, SUPPLY_CAP);
    }

    function test_cost_zeroSupply_smallAmount() public pure {
        // Buying 1 token when supply is 0
        uint256 amount = 1e18;
        uint256 ethCost = BondingCurveLib.cost(0, amount);

        // Manually calculate expected cost
        uint256 currentTokenReserve = VIRTUAL_TOKEN_RESERVE;
        uint256 newTokenReserve = currentTokenReserve - amount;
        uint256 currentEthReserve = K / currentTokenReserve;
        uint256 newEthReserve = K / newTokenReserve;
        uint256 expectedCost = newEthReserve - currentEthReserve;

        assertEq(ethCost, expectedCost);
    }

    function test_cost_zeroSupply_largerAmount() public pure {
        // Buying 1M tokens when supply is 0
        uint256 amount = 1_000_000e18;
        uint256 ethCost = BondingCurveLib.cost(0, amount);

        uint256 currentTokenReserve = VIRTUAL_TOKEN_RESERVE;
        uint256 newTokenReserve = currentTokenReserve - amount;
        uint256 currentEthReserve = K / currentTokenReserve;
        uint256 newEthReserve = K / newTokenReserve;
        uint256 expectedCost = newEthReserve - currentEthReserve;

        assertEq(ethCost, expectedCost);
        // Should be greater than 0
        assertGt(ethCost, 0);
    }

    function test_cost_nonZeroSupply() public pure {
        // Buying 1M tokens when 50M have already been minted
        uint256 currentSupply = 50_000_000e18;
        uint256 amount = 1_000_000e18;
        uint256 ethCost = BondingCurveLib.cost(currentSupply, amount);

        uint256 currentTokenReserve = VIRTUAL_TOKEN_RESERVE - currentSupply;
        uint256 newTokenReserve = currentTokenReserve - amount;
        uint256 currentEthReserve = K / currentTokenReserve;
        uint256 newEthReserve = K / newTokenReserve;
        uint256 expectedCost = newEthReserve - currentEthReserve;

        assertEq(ethCost, expectedCost);
    }

    function test_cost_increasesWithSupply() public pure {
        // The same amount should cost more as supply increases
        uint256 amount = 1_000_000e18;

        uint256 costAtZeroSupply = BondingCurveLib.cost(0, amount);
        uint256 costAt50MSupply = BondingCurveLib.cost(50_000_000e18, amount);
        uint256 costAt100MSupply = BondingCurveLib.cost(100_000_000e18, amount);
        uint256 costAt150MSupply = BondingCurveLib.cost(150_000_000e18, amount);

        // Cost should increase as supply increases
        assertLt(costAtZeroSupply, costAt50MSupply);
        assertLt(costAt50MSupply, costAt100MSupply);
        assertLt(costAt100MSupply, costAt150MSupply);
    }

    function test_cost_buyingFullSupplyCap() public pure {
        // Buying the entire supply cap from zero
        uint256 ethCost = BondingCurveLib.cost(0, SUPPLY_CAP);

        uint256 currentTokenReserve = VIRTUAL_TOKEN_RESERVE;
        uint256 newTokenReserve = currentTokenReserve - SUPPLY_CAP;
        uint256 currentEthReserve = K / currentTokenReserve;
        uint256 newEthReserve = K / newTokenReserve;
        uint256 expectedCost = newEthReserve - currentEthReserve;

        assertEq(ethCost, expectedCost);
        // After graduation, the ETH reserve should be 40 ETH (30 + 10 raised)
        // newEthReserve = K / (800M - 200M) = K / 600M = 40 ETH
        assertEq(newEthReserve, 40 ether);
        // So total cost to buy all 200M tokens should be 10 ETH
        assertEq(ethCost, 10 ether);
    }

    function test_cost_multipleSmallBuys_equalOneLargeBuy() public pure {
        // Due to integer division, multiple small buys may differ slightly
        // but should be approximately equal to one large buy
        uint256 totalAmount = 10_000_000e18;

        // One large buy
        uint256 largeBuyCost = BondingCurveLib.cost(0, totalAmount);

        // Multiple small buys
        uint256 smallAmount = 1_000_000e18;
        uint256 cumulativeCost = 0;
        uint256 currentSupply = 0;

        for (uint256 i = 0; i < 10; i++) {
            cumulativeCost += BondingCurveLib.cost(currentSupply, smallAmount);
            currentSupply += smallAmount;
        }

        // They should be very close (allowing for rounding errors)
        // The cumulative cost will be slightly higher due to rounding
        assertGe(cumulativeCost, largeBuyCost);
        // But difference should be minimal (less than 0.01%)
        assertLt(cumulativeCost - largeBuyCost, largeBuyCost / 10000);
    }

    function test_cost_fuzz(uint256 currentSupply, uint256 amount) public pure {
        // Bound inputs to valid ranges
        // currentSupply must be less than VIRTUAL_TOKEN_RESERVE
        currentSupply = bound(currentSupply, 0, SUPPLY_CAP - 1);
        // amount must be large enough to produce non-zero cost (at least 1e18 for meaningful results)
        // and not exceed remaining reserve
        uint256 maxAmount = VIRTUAL_TOKEN_RESERVE - currentSupply - 1;
        amount = bound(amount, 1e18, maxAmount);

        uint256 ethCost = BondingCurveLib.cost(currentSupply, amount);

        // Cost should always be positive for meaningful amounts
        assertGt(ethCost, 0);

        // Verify calculation matches expected formula
        uint256 currentTokenReserve = VIRTUAL_TOKEN_RESERVE - currentSupply;
        uint256 newTokenReserve = currentTokenReserve - amount;
        uint256 currentEthReserve = K / currentTokenReserve;
        uint256 newEthReserve = K / newTokenReserve;
        uint256 expectedCost = newEthReserve - currentEthReserve;

        assertEq(ethCost, expectedCost);
    }

    function test_cost_atSupplyCap() public pure {
        // When supply is at cap, buying more should still work
        // (as long as we don't exceed VIRTUAL_TOKEN_RESERVE)
        uint256 currentSupply = SUPPLY_CAP;
        uint256 amount = 1_000_000e18;

        uint256 ethCost = BondingCurveLib.cost(currentSupply, amount);

        // Cost should be positive and higher than at lower supplies
        assertGt(ethCost, 0);

        // Compare with cost at zero supply
        uint256 costAtZero = BondingCurveLib.cost(0, amount);
        assertGt(ethCost, costAtZero);
    }

    function test_cost_verySmallAmount() public pure {
        // Test with minimal token amount (1 wei)
        uint256 amount = 1;
        uint256 ethCost = BondingCurveLib.cost(0, amount);

        // May be zero due to integer division, but should not revert
        // This is expected behavior for very small amounts
        assertGe(ethCost, 0);
    }

    function test_cost_constantProductInvariant() public pure {
        // Verify the constant product formula holds
        uint256 currentSupply = 50_000_000e18;
        uint256 amount = 10_000_000e18;

        uint256 currentTokenReserve = VIRTUAL_TOKEN_RESERVE - currentSupply;
        uint256 newTokenReserve = currentTokenReserve - amount;

        uint256 currentEthReserve = K / currentTokenReserve;
        uint256 newEthReserve = K / newTokenReserve;

        // K should remain approximately constant (allowing for integer rounding)
        uint256 kBefore = currentTokenReserve * currentEthReserve;
        uint256 kAfter = newTokenReserve * newEthReserve;

        // Both should be <= K (due to rounding down in division)
        assertLe(kBefore, K);
        assertLe(kAfter, K);

        // And both should be very close to K
        assertGt(kBefore, K - K / 1000);
        assertGt(kAfter, K - K / 1000);
    }
}
