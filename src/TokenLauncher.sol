// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { BondingCurveLib } from "./helpers/BondingCurveLib.sol";
import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { UniswapV4Lib } from "./helpers/UniswapV4Lib.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { BondingToken } from "./BondingToken.sol";

interface IMintBurnERC20 {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function totalSupply() external view returns (uint256);

    function approve(address addr, uint256 amount) external;
    function renounceOwnership() external;
}

contract TokenLauncher is ReentrancyGuard {
    enum TokenStatus {
        None, // 0 - default/uninitialized
        Registered, // 1
        Graduated // 2
    }

    event TokenCreated(address indexed token);
    event TokenGraduated(address indexed token, uint256 ethAmount, uint256 tokenId);

    uint24 public constant LP_FEE = 3000; // 0.3%
    int24 public constant TICK_SPACING = 60;

    IPositionManager public positionManager;

    mapping(address => TokenStatus) public tokenStatus;
    mapping(address => uint256) public ethReserves;

    constructor(address positionManagerAddr) {
        positionManager = IPositionManager(positionManagerAddr);
    }

    receive() external payable { }

    // public api
    function create(string calldata name, string calldata symbol) external returns (address tokenAddr) {
        BondingToken token = new BondingToken(name, symbol, address(this));
        tokenAddr = address(token);

        tokenStatus[tokenAddr] = TokenStatus.Registered;

        emit TokenCreated(tokenAddr);
    }

    function buy(address tokenAddr, uint256 amt, uint256 maxEthAmt) public payable nonReentrant returns (uint256) {
        require(tokenStatus[tokenAddr] == TokenStatus.Registered, "Token not registered or already graduated");

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

    function sell(address tokenAddr, uint256 amt, uint256 minEthAmount) public nonReentrant returns (uint256) {
        require(tokenStatus[tokenAddr] == TokenStatus.Registered, "Token not registered or already graduated");

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

    // helpers
    function _graduate(address tokenAddr) internal returns (uint256 ethAmount) {
        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);

        tokenStatus[tokenAddr] = TokenStatus.Graduated;

        ethAmount = ethReserves[tokenAddr];
        ethReserves[tokenAddr] = 0;

        // Calculate tokens to mint for LP based on graduation price
        // At graduation: virtual token reserve = 600M, virtual ETH reserve = 40 ETH
        // Price = 40 ETH / 600M tokens
        // For the ETH we have, mint proportional tokens
        uint256 tokensForLp = (ethAmount * BondingCurveLib.VIRTUAL_TOKEN_RESERVE)
            / (BondingCurveLib.K / (BondingCurveLib.VIRTUAL_TOKEN_RESERVE - BondingCurveLib.SUPPLY_CAP));

        // Mint tokens for LP
        token.mint(address(this), tokensForLp);

        // Approve position manager to spend tokens
        token.approve(address(positionManager), tokensForLp);

        // Create LP position using UniswapV4Lib
        uint256 tokenId = UniswapV4Lib.createLP(
            UniswapV4Lib.CreateLPParams({
                positionManager: positionManager,
                hook: IHooks(address(0)),
                tokenAddr: tokenAddr,
                ethAmount: ethAmount,
                tokenAmount: tokensForLp,
                fee: LP_FEE,
                tickSpacing: TICK_SPACING,
                owner: address(this)
            })
        );

        // Renounce admin after LP creation
        token.renounceOwnership();

        emit TokenGraduated(tokenAddr, ethAmount, tokenId);
    }
}
