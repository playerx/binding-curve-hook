// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { BondingCurveLib } from "./BondingCurveLib.sol";
import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { UniswapV4Lib } from "./UniswapV4Lib.sol";

interface IMintBurnERC20 {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function totalSupply() external view returns (uint256);

    function approve(address addr, uint256 amount) external;
    function setAdmin(address) external;
}

contract TokenLauncher {
    event Graduated(address indexed token, uint256 ethAmount, uint256 tokenId);

    uint24 public constant LP_FEE = 3000; // 0.3%
    int24 public constant TICK_SPACING = 60;

    IPositionManager public positionManager;
    IHooks public hook;

    mapping(address => bool) public graduated;
    mapping(address => uint256) public ethReserves;

    constructor(address positionManagerAddr, address hookAddr) {
        positionManager = IPositionManager(positionManagerAddr);
        hook = IHooks(hookAddr);
    }

    receive() external payable { }

    // public api
    function buy(address tokenAddr, uint256 amt, uint256 maxEthAmt) public payable returns (uint256) {
        require(!graduated[tokenAddr], "Token already graduation, please use LP for swaps");

        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);
        address user = msg.sender;

        uint256 supply = token.totalSupply();

        uint256 ethToCharge = BondingCurveLib.cost(supply, amt);

        require(ethToCharge <= maxEthAmt, "slippage");

        token.mint(user, amt);

        require(msg.value >= ethToCharge, "insufficient ETH");

        ethReserves[tokenAddr] += ethToCharge;

        uint256 ethToRefund = msg.value - ethToCharge;
        if (ethToRefund > 0) {
            (bool success,) = user.call{ value: ethToRefund }("");
            require(success, "ETH refund failed");
        }

        if (supply + amt >= BondingCurveLib.SUPPLY_CAP) {
            _graduate(tokenAddr);
        }

        return ethToCharge;
    }

    function sell(address tokenAddr, uint256 amt, uint256 minEthAmount) public returns (uint256) {
        require(!graduated[tokenAddr], "Token already graduation, please use LP for swaps");

        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);
        address user = msg.sender;

        uint256 s = token.totalSupply();

        uint256 refund = BondingCurveLib.cost(s - amt, amt);

        require(refund >= minEthAmount, "slippage");

        token.burn(user, amt);

        ethReserves[tokenAddr] -= refund;

        (bool success,) = user.call{ value: refund }("");
        require(success, "ETH transfer failed");

        return refund;
    }

    function swap() public { }

    // helpers
    function _graduate(address tokenAddr) internal returns (uint256 ethAmount) {
        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);

        graduated[tokenAddr] = true;

        ethAmount = ethReserves[tokenAddr];
        ethReserves[tokenAddr] = 0;

        // Calculate tokens to mint for LP based on graduation price
        // At graduation: virtual token reserve = 600M, virtual ETH reserve = 40 ETH
        // Price = 40 ETH / 600M tokens
        // For the ETH we have, mint proportional tokens
        uint256 tokensForLP = (ethAmount * BondingCurveLib.VIRTUAL_TOKEN_RESERVE)
            / (BondingCurveLib.K / (BondingCurveLib.VIRTUAL_TOKEN_RESERVE - BondingCurveLib.SUPPLY_CAP));

        // Mint tokens for LP
        token.mint(address(this), tokensForLP);

        // Approve position manager to spend tokens
        token.approve(address(positionManager), tokensForLP);

        // Create LP position using UniswapV4Lib
        uint256 tokenId = UniswapV4Lib.createLP(
            UniswapV4Lib.CreateLPParams({
                positionManager: positionManager,
                hook: hook,
                tokenAddr: tokenAddr,
                ethAmount: ethAmount,
                tokenAmount: tokensForLP,
                fee: LP_FEE,
                tickSpacing: TICK_SPACING,
                owner: address(this)
            })
        );

        // Renounce admin after LP creation
        token.setAdmin(address(0));

        emit Graduated(tokenAddr, ethAmount, tokenId);
    }
}
