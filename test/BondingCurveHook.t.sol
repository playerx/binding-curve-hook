// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {
    SwapParams,
    ModifyLiquidityParams
} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {
    LiquidityAmounts
} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {BondingCurveHook} from "../src/BondingCurveHook.sol";
import {BondingToken} from "../src/BondingToken.sol";

import {console} from "forge-std/console.sol";

contract TestBondingCurveHook is Test, Deployers, ERC1155TokenReceiver {
    BondingToken token; // our token to use in the ETH-TOKEN pool

    // Native tokens are represented by address(0)
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    BondingCurveHook hook;

    function setUp() public {
        vm.deal(address(this), 100 ether);

        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(
            uint256(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            )
        );

        address hookAddress = address(flags);

        deployCodeTo(
            "BondingCurveHook.sol:BondingCurveHook",
            abi.encode(manager),
            hookAddress
        );

        // Deploy our TOKEN contract
        token = new BondingToken("Test Token", "TEST", hookAddress);
        tokenCurrency = Currency.wrap(address(token));

        // // Mint a bunch of TOKEN to ourselves and to address(1)
        // token.mint(address(this), 1000 ether);
        // token.mint(address(1), 1000 ether);

        // Deploy our hook
        hook = BondingCurveHook(payable(hookAddress));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        // token.approve(address(swapRouter), type(uint256).max);
        // token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // Add some liquidity to the pool
        // uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        // uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        // uint256 ethToAdd = 0.003 ether;
        // uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
        //     SQRT_PRICE_1_1,
        //     sqrtPriceAtTickUpper,
        //     ethToAdd
        // );
        // uint256 tokenToAdd = LiquidityAmounts.getAmount1ForLiquidity(
        //     sqrtPriceAtTickLower,
        //     SQRT_PRICE_1_1,
        //     liquidityDelta
        // );

        // modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
        //     key,
        //     ModifyLiquidityParams({
        //         tickLower: -60,
        //         tickUpper: 60,
        //         liquidityDelta: int256(uint256(liquidityDelta)),
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
    }

    function test_buy_basic() public {
        uint256 amountToBuy = 1_000_000e18; // 1M tokens
        uint256 maxEth = 1 ether;

        uint256 balanceBefore = address(this).balance;
        uint256 tokenBalanceBefore = token.balanceOf(address(this));

        uint256 ethCharged = hook.buy{value: maxEth}(
            address(token),
            amountToBuy,
            maxEth
        );

        uint256 balanceAfter = address(this).balance;
        uint256 tokenBalanceAfter = token.balanceOf(address(this));

        // Verify eth was charged
        assert(ethCharged > 0);

        // Verify tokens were received
        assertEq(
            tokenBalanceAfter - tokenBalanceBefore,
            amountToBuy,
            "Should receive exact token amount"
        );

        // Verify ETH was charged (with refund of excess)
        assertEq(
            balanceBefore - balanceAfter,
            ethCharged,
            "ETH balance should decrease by charged amount"
        );

        // Verify token supply increased
        assertEq(
            token.totalSupply(),
            amountToBuy,
            "Total supply should equal bought amount"
        );

        console.log("ETH charged for 1M tokens:", ethCharged);
    }

    function test_buy_with_excess_eth_refund() public {
        uint256 amountToBuy = 1_000_000e18; // 1M tokens
        uint256 excessEth = 10 ether; // Send way more ETH than needed

        uint256 balanceBefore = address(this).balance;

        uint256 ethCharged = hook.buy{value: excessEth}(
            address(token),
            amountToBuy,
            excessEth
        );

        uint256 balanceAfter = address(this).balance;

        // Should only charge actual cost, refund the rest
        assertEq(
            balanceBefore - balanceAfter,
            ethCharged,
            "Should refund excess ETH"
        );
        assertLt(ethCharged, excessEth, "Charged should be less than sent");

        console.log("ETH sent:", excessEth);
        console.log("ETH charged:", ethCharged);
        console.log("ETH refunded:", excessEth - ethCharged);
    }

    function test_buy_slippage_protection() public {
        uint256 amountToBuy = 1_000_000e18;
        uint256 tooLowMaxEth = 0.00001 ether; // Way too low

        vm.expectRevert(bytes("slippage"));
        hook.buy{value: 1 ether}(address(token), amountToBuy, tooLowMaxEth);
    }

    function test_buy_insufficient_eth() public {
        uint256 amountToBuy = 1_000_000e18;
        uint256 maxEth = 1 ether;
        uint256 sentEth = 0.00001 ether; // Send less than needed

        vm.expectRevert(bytes("insufficient ETH"));
        hook.buy{value: sentEth}(address(token), amountToBuy, maxEth);
    }

    function test_buy_multiple_buys_increase_price() public {
        uint256 amountPerBuy = 10_000_000e18; // 10M tokens each

        // First buy
        uint256 cost1 = hook.buy{value: 10 ether}(
            address(token),
            amountPerBuy,
            10 ether
        );

        // Second buy (should cost more due to bonding curve)
        uint256 cost2 = hook.buy{value: 10 ether}(
            address(token),
            amountPerBuy,
            10 ether
        );

        assertGt(cost2, cost1, "Second buy should cost more than first");

        console.log("First 10M tokens cost:", cost1);
        console.log("Second 10M tokens cost:", cost2);
    }

    function test_buy_cap_enforcement() public {
        uint256 supplyCap = 200_000_000e18; // From BondingCurveLib

        vm.expectRevert(bytes("cap"));
        hook.buy{value: 100 ether}(
            address(token),
            supplyCap + 1, // Try to buy more than cap
            100 ether
        );
    }
}
