// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {Currency} from "v4-core/types/Currency.sol";
// import {
//     BalanceDelta,
//     BalanceDeltaLibrary
// } from "v4-core/types/BalanceDelta.sol";
// import {
//     BeforeSwapDelta,
//     toBeforeSwapDelta
// } from "v4-core/types/BeforeSwapDelta.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {
//     SwapParams,
//     ModifyLiquidityParams
// } from "v4-core/types/PoolOperation.sol";
import {BondingCurveLib} from "./BondingCurveLib.sol";
// import {
//     CurrencySettler
// } from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
// import {console} from "forge-std/console.sol";

interface IMintBurnERC20 {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function totalSupply() external view returns (uint256);

    function setAdmin(address) external;
}

contract TokenLauncher {
    mapping(address => bool) public graduated;
    mapping(address => uint256) public ethReserves;

    event Graduated(address indexed token, uint256 ethAmount);

    constructor() {}

    receive() external payable {}

    function buy(
        address tokenAddr,
        uint256 amt,
        uint256 maxEthAmt
    ) public payable returns (uint256) {
        require(
            !graduated[tokenAddr],
            "Token already graduation, please use LP for swaps"
        );

        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);
        address user = msg.sender;

        uint256 supply = token.totalSupply();

        // require(s + amt <= BondingCurveLib.SUPPLY_CAP, "cap");
        uint256 ethToCharge = BondingCurveLib.cost(supply, amt);

        require(ethToCharge <= maxEthAmt, "slippage");

        token.mint(user, amt);

        require(msg.value >= ethToCharge, "insufficient ETH");

        ethReserves[tokenAddr] += ethToCharge;

        uint256 ethToRefund = msg.value - ethToCharge;
        if (ethToRefund > 0) {
            (bool success, ) = user.call{value: ethToRefund}("");
            require(success, "ETH refund failed");
        }

        if (supply + amt >= BondingCurveLib.SUPPLY_CAP) {
            _graduate(tokenAddr);
        }

        return ethToCharge;
    }

    function sell(
        address tokenAddr,
        uint256 amt,
        uint256 minEthAmount
    ) public returns (uint256) {
        require(
            !graduated[tokenAddr],
            "Token already graduation, please use LP for swaps"
        );

        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);
        address user = msg.sender;

        uint256 s = token.totalSupply();

        uint256 refund = BondingCurveLib.cost(s - amt, amt);

        require(refund >= minEthAmount, "slippage");

        token.burn(user, amt);

        ethReserves[tokenAddr] -= refund;

        (bool success, ) = user.call{value: refund}("");
        require(success, "ETH transfer failed");

        return refund;
    }

    function _graduate(address tokenAddr) internal returns (uint256 ethAmount) {
        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);

        graduated[tokenAddr] = true;

        ethAmount = ethReserves[tokenAddr];
        ethReserves[tokenAddr] = 0;

        // renounce
        token.setAdmin(address(0));

        // create LP.

        // TODO: Create LP position with ethAmount and mint remaining tokens

        emit Graduated(tokenAddr, ethAmount);
    }
}
