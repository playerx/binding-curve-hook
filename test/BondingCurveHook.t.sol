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
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
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

    // direct flows
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

    // uniswap flows
    function test_uniswap_swap_before_graduation() public {
        // First buy some tokens so we have supply
        uint256 initialBuy = 50_000_000e18; // 50M tokens
        hook.buy{value: 10 ether}(address(token), initialBuy, 10 ether);

        // Approve tokens for the swap router
        token.approve(address(swapRouter), type(uint256).max);

        // Verify token is not graduated
        assertFalse(
            hook.graduated(address(token)),
            "Token should not be graduated"
        );

        // Try to do a uniswap swap (buy more tokens via swap router)
        // zeroForOne = true means ETH -> Token (buy)
        uint256 tokensToBuy = 10_000_000e18; // 10M tokens
        uint256 balanceBefore = token.balanceOf(address(this));

        // Encode hook data with token address and user
        bytes memory hookData = abi.encode(address(token), address(this));

        // Perform swap via uniswap router
        // When not graduated, the hook will intercept and use bonding curve
        // For zeroForOne = true, price decreases, so sqrtPriceLimitX96 should be MIN
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(tokensToBuy),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 balanceAfter = token.balanceOf(address(this));
        assertEq(
            balanceAfter - balanceBefore,
            tokensToBuy,
            "Should have received exact tokens from swap"
        );

        console.log(
            "Tokens received via Uniswap swap:",
            balanceAfter - balanceBefore
        );
    }

    // function test_uniswap_swap_sell_before_graduation() public {
    //     // First buy some tokens
    //     uint256 initialBuy = 50_000_000e18; // 50M tokens
    //     hook.buy{value: 10 ether}(address(token), initialBuy, 10 ether);

    //     // Approve tokens for the swap router
    //     token.approve(address(swapRouter), type(uint256).max);

    //     uint256 tokensToSell = 10_000_000e18; // 10M tokens
    //     uint256 ethBalanceBefore = address(this).balance;
    //     uint256 tokenBalanceBefore = token.balanceOf(address(this));

    //     bytes memory hookData = abi.encode(address(token), address(this));

    //     // Perform sell swap via uniswap router
    //     // zeroForOne = false means Token -> ETH (sell)
    //     // For zeroForOne = false, price increases, so sqrtPriceLimitX96 should be MAX
    //     swapRouter.swap(
    //         key,
    //         SwapParams({
    //             zeroForOne: false,
    //             amountSpecified: int256(tokensToSell),
    //             sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         hookData
    //     );

    //     uint256 ethBalanceAfter = address(this).balance;
    //     uint256 tokenBalanceAfter = token.balanceOf(address(this));

    //     assertEq(
    //         tokenBalanceBefore - tokenBalanceAfter,
    //         tokensToSell,
    //         "Should have sold exact token amount"
    //     );
    //     assertGt(ethBalanceAfter, ethBalanceBefore, "Should have received ETH");

    //     console.log(
    //         "ETH received from selling:",
    //         ethBalanceAfter - ethBalanceBefore
    //     );
    // }

    // function test_graduation_at_supply_cap() public {
    //     uint256 supplyCap = 200_000_000e18; // 200M tokens

    //     // Verify not graduated initially
    //     assertFalse(
    //         hook.graduated(address(token)),
    //         "Should not be graduated initially"
    //     );
    //     assertEq(
    //         token.admin(),
    //         address(hook),
    //         "Admin should be hook initially"
    //     );

    //     // Buy tokens up to the cap via swap router to trigger _afterSwap graduation logic
    //     token.approve(address(swapRouter), type(uint256).max);
    //     bytes memory hookData = abi.encode(address(token), address(this));

    //     swapRouter.swap{value: 50 ether}(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: int256(supplyCap),
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         hookData
    //     );

    //     // Verify graduation happened
    //     assertTrue(
    //         hook.graduated(address(token)),
    //         "Should be graduated after reaching cap"
    //     );
    //     assertEq(
    //         token.admin(),
    //         address(0),
    //         "Admin should be renounced after graduation"
    //     );
    //     assertEq(
    //         token.totalSupply(),
    //         supplyCap,
    //         "Total supply should equal cap"
    //     );

    //     console.log("Token graduated at supply:", token.totalSupply());
    // }

    // function test_direct_buy_reverts_after_graduation() public {
    //     uint256 supplyCap = 200_000_000e18;

    //     // Graduate the token via swap router
    //     token.approve(address(swapRouter), type(uint256).max);
    //     bytes memory hookData = abi.encode(address(token), address(this));

    //     swapRouter.swap{value: 50 ether}(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: int256(supplyCap),
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         hookData
    //     );
    //     assertTrue(hook.graduated(address(token)), "Should be graduated");

    //     // Try to buy more via direct API - should revert
    //     vm.expectRevert(
    //         bytes("Token already graduation, please use LP for swaps")
    //     );
    //     hook.buy{value: 1 ether}(address(token), 1_000_000e18, 1 ether);
    // }

    // function test_direct_sell_reverts_after_graduation() public {
    //     uint256 supplyCap = 200_000_000e18;

    //     // Graduate the token via swap router
    //     token.approve(address(swapRouter), type(uint256).max);
    //     bytes memory hookData = abi.encode(address(token), address(this));

    //     swapRouter.swap{value: 50 ether}(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: int256(supplyCap),
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         hookData
    //     );
    //     assertTrue(hook.graduated(address(token)), "Should be graduated");

    //     // Try to sell via direct API - should revert
    //     vm.expectRevert(
    //         bytes("Token already graduation, please use LP for swaps")
    //     );
    //     hook.sell(address(token), 1_000_000e18, 0);
    // }

    // function test_uniswap_swap_after_graduation() public {
    //     uint256 supplyCap = 200_000_000e18;

    //     // Graduate the token via swap router
    //     token.approve(address(swapRouter), type(uint256).max);
    //     token.approve(address(modifyLiquidityRouter), type(uint256).max);
    //     bytes memory hookData = abi.encode(address(token), address(this));

    //     swapRouter.swap{value: 50 ether}(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: int256(supplyCap),
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         hookData
    //     );
    //     assertTrue(hook.graduated(address(token)), "Should be graduated");

    //     // Now add liquidity to the pool (allowed after graduation)
    //     uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

    //     uint256 ethToAdd = 1 ether;
    //     uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
    //         SQRT_PRICE_1_1,
    //         sqrtPriceAtTickUpper,
    //         ethToAdd
    //     );

    //     modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
    //         key,
    //         ModifyLiquidityParams({
    //             tickLower: -60,
    //             tickUpper: 60,
    //             liquidityDelta: int256(uint256(liquidityDelta)),
    //             salt: bytes32(0)
    //         }),
    //         hookData
    //     );

    //     // Perform a swap after graduation - should use normal AMM
    //     uint256 tokenBalanceBefore = token.balanceOf(address(this));

    //     swapRouter.swap{value: 0.1 ether}(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: int256(0.1 ether),
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         hookData
    //     );

    //     uint256 tokenBalanceAfter = token.balanceOf(address(this));
    //     assertGt(
    //         tokenBalanceAfter,
    //         tokenBalanceBefore,
    //         "Should receive tokens from AMM swap"
    //     );

    //     console.log(
    //         "Tokens received via AMM after graduation:",
    //         tokenBalanceAfter - tokenBalanceBefore
    //     );
    // }

    // function test_graduation_partial_then_complete() public {
    //     uint256 supplyCap = 200_000_000e18;

    //     // Buy 80% of cap via direct buy (doesn't trigger graduation)
    //     uint256 firstBuy = 160_000_000e18;
    //     hook.buy{value: 30 ether}(address(token), firstBuy, 30 ether);

    //     assertFalse(
    //         hook.graduated(address(token)),
    //         "Should not be graduated yet"
    //     );
    //     assertEq(token.admin(), address(hook), "Admin should still be hook");

    //     // Buy remaining via swap router to trigger graduation
    //     uint256 secondBuy = 40_000_000e18;
    //     token.approve(address(swapRouter), type(uint256).max);
    //     bytes memory hookData = abi.encode(address(token), address(this));

    //     swapRouter.swap{value: 30 ether}(
    //         key,
    //         SwapParams({
    //             zeroForOne: true,
    //             amountSpecified: int256(secondBuy),
    //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         hookData
    //     );

    //     assertTrue(
    //         hook.graduated(address(token)),
    //         "Should be graduated after hitting cap"
    //     );
    //     assertEq(token.admin(), address(0), "Admin should be renounced");
    //     assertEq(
    //         token.totalSupply(),
    //         supplyCap,
    //         "Total supply should equal cap"
    //     );
    // }
}
