// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { PoolManager } from "v4-core/PoolManager.sol";
import { SwapParams, ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { PoolId } from "v4-core/types/PoolId.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import { ERC1155TokenReceiver } from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import { BondingCurveHook } from "../src/BondingCurveHook.sol";
import { BondingToken } from "../src/BondingToken.sol";

contract TestPointsHook is Test, Deployers, ERC1155TokenReceiver {
    BondingToken token; // our token to use in the ETH-TOKEN pool

    // Native tokens are represented by address(0)
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    BondingCurveHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);

        address hookAddress = address(flags);

        deployCodeTo("BondingCurveHook.sol", abi.encode(manager), hookAddress);

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
        (key,) = initPool(
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
}
