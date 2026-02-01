// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    IPositionManager
} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {
    LiquidityAmounts
} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title UniswapV4Lib
/// @notice Library for creating Uniswap V4 liquidity positions
library UniswapV4Lib {
    /// @notice Parameters for creating an LP position
    struct CreateLPParams {
        IPositionManager positionManager;
        IHooks hook;
        address tokenAddr;
        uint256 ethAmount;
        uint256 tokenAmount;
        uint24 fee;
        int24 tickSpacing;
        address owner;
    }

    /// @notice Creates a Uniswap V4 liquidity position with ETH and a token
    /// @param params The parameters for creating the LP position
    /// @return tokenId The NFT token ID of the created position
    function createLP(
        CreateLPParams memory params
    ) internal returns (uint256 tokenId) {
        PoolKey memory key = _buildPoolKey(
            params.tokenAddr,
            params.hook,
            params.fee,
            params.tickSpacing
        );

        uint160 sqrtPriceX96 = _calculateSqrtPriceX96(
            params.ethAmount,
            params.tokenAmount
        );

        // Initialize the pool
        int24 currentTick = params.positionManager.initializePool(
            key,
            sqrtPriceX96
        );
        require(currentTick != type(int24).max, "Pool initialization failed");

        // Get next token ID before minting
        tokenId = params.positionManager.nextTokenId();

        // Build and execute mint
        _executeMint(
            params.positionManager,
            key,
            currentTick,
            sqrtPriceX96,
            params.ethAmount,
            params.tokenAmount,
            params.tickSpacing,
            params.owner
        );
    }

    function _buildPoolKey(
        address tokenAddr,
        IHooks hook,
        uint24 fee,
        int24 tickSpacing
    ) private pure returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(address(0)), // ETH
                currency1: Currency.wrap(tokenAddr),
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: hook
            });
    }

    function _executeMint(
        IPositionManager positionManager,
        PoolKey memory key,
        int24 currentTick,
        uint160 sqrtPriceX96,
        uint256 ethAmount,
        uint256 tokenAmount,
        int24 tickSpacing,
        address owner
    ) private {
        // Calculate tick range (wide range around current tick, aligned to spacing)
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 tickLower = ((currentTick - 6000) / tickSpacing) * tickSpacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 tickUpper = ((currentTick + 6000) / tickSpacing) * tickSpacing;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount,
            tokenAmount
        );

        bytes memory unlockData = _buildMintParams(
            key,
            tickLower,
            tickUpper,
            liquidity,
            ethAmount,
            tokenAmount,
            owner
        );

        positionManager.modifyLiquidities{value: ethAmount}(
            unlockData,
            block.timestamp
        );
    }

    function _buildMintParams(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 ethAmount,
        uint256 tokenAmount,
        address owner
    ) private pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        require(ethAmount <= type(uint128).max, "ethAmount overflow");
        require(tokenAmount <= type(uint128).max, "tokenAmount overflow");
        // casting to uint128 is safe because of the require checks above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 ethAmountMax = uint128(ethAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 tokenAmountMax = uint128(tokenAmount);

        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            ethAmountMax,
            tokenAmountMax,
            owner,
            bytes("")
        );

        params[1] = abi.encode(key.currency0, key.currency1);

        return abi.encode(actions, params);
    }

    /// @notice Calculate sqrtPriceX96 from ETH and token amounts
    /// @dev sqrtPriceX96 = sqrt(token/eth) * 2^96 for currency0=ETH, currency1=token
    function _calculateSqrtPriceX96(
        uint256 ethAmount,
        uint256 tokenAmount
    ) private pure returns (uint160) {
        // price = token/eth (how many tokens per ETH)
        // sqrtPrice = sqrt(token/eth)
        // sqrtPriceX96 = sqrtPrice * 2^96

        // To avoid overflow, we compute: sqrt(tokenAmount * 2^192 / ethAmount)
        // = sqrt(tokenAmount / ethAmount) * 2^96

        uint256 ratioX192 = (tokenAmount << 192) / ethAmount;
        uint256 sqrtRatioX96 = _sqrt(ratioX192);

        require(sqrtRatioX96 <= type(uint160).max, "sqrtRatioX96 overflow");
        // casting to uint160 is safe because of the require check above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtRatioX96);
    }

    /// @notice Compute the square root of a number using the Babylonian method
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
