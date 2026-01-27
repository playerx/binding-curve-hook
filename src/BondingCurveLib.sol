// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BondingCurveLib
/// @notice Library for constant product bonding curve calculations (pump.fun style)
library BondingCurveLib {
    // Virtual AMM reserves
    uint256 public constant VIRTUAL_TOKEN_RESERVE = 800_000_000e18; // 800M virtual tokens
    uint256 public constant VIRTUAL_ETH_RESERVE = 30 ether; // 30 ETH virtual reserve
    uint256 public constant K = VIRTUAL_TOKEN_RESERVE * VIRTUAL_ETH_RESERVE; // constant product
    uint256 public constant SUPPLY_CAP = 200_000_000e18; // 200M tokens (graduation threshold)

    /// @notice Calculate cost using constant product curve (x * y = k)
    /// @param currentSupply Current supply (tokens already minted)
    /// @param amount Amount of tokens to buy
    /// @return ETH cost for purchasing 'amount' tokens
    function cost(uint256 currentSupply, uint256 amount) internal pure returns (uint256) {
        // Available tokens in virtual reserve decreases as supply increases
        uint256 currentTokenReserve = VIRTUAL_TOKEN_RESERVE - currentSupply;
        uint256 newTokenReserve = currentTokenReserve - amount;

        // Constant product: eth_reserve * token_reserve = K
        // Cost = new_eth_reserve - current_eth_reserve
        uint256 currentEthReserve = K / currentTokenReserve;
        uint256 newEthReserve = K / newTokenReserve;

        return newEthReserve - currentEthReserve;
    }
}
