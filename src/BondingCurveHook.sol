// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseHook } from "v4-periphery/src/utils/BaseHook.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { SwapParams, ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";
import { BondingCurveLib } from "./BondingCurveLib.sol";

interface IMintBurnERC20 {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function totalSupply() external view returns (uint256);

    function setAdmin(address) external;
}

contract BondingCurveHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;

    mapping(address => bool) public graduated;

    constructor(IPoolManager m) BaseHook(m) { }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4)
    {
        (address tokenAddr,) = abi.decode(hookData, (address, address));
        require(graduated[tokenAddr], "LP disabled until graduation");

        return this.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (address tokenAddr, address user) = abi.decode(hookData, (address, address));
        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);

        if (graduated[tokenAddr]) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        if (user == address(0)) {
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        bool isBuy = params.zeroForOne;
        uint256 amt = uint256(params.amountSpecified);

        if (isBuy) {
            uint256 cost = _buy(token, amt, 1000, user);

            return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(cost)), -int128(int256(amt))), 0);
        } else {
            uint256 refund = _sell(token, amt, 0, user);

            return (this.beforeSwap.selector, toBeforeSwapDelta(-int128(int256(refund)), int128(int256(amt))), 0);
        }
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        (address tokenAddr,) = abi.decode(hookData, (address, address));
        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);

        if (!graduated[tokenAddr] && token.totalSupply() >= BondingCurveLib.SUPPLY_CAP) {
            graduated[tokenAddr] = true;
            token.setAdmin(address(0));
        }

        return (this.afterSwap.selector, 0);
    }

    function buy(address tokenAddr, uint256 amt, uint256 maxEthAmt) public returns (uint256) {
        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);
        address user = msg.sender;

        return _buy(token, amt, maxEthAmt, user);
    }

    function sell(IMintBurnERC20 tokenAddr, uint256 amt, uint256 minEthAmount) public returns (uint256) {
        IMintBurnERC20 token = IMintBurnERC20(tokenAddr);
        address user = msg.sender;

        return _sell(token, amt, minEthAmount, user);
    }

    function _buy(IMintBurnERC20 token, uint256 amt, uint256 maxEthAmount, address user) internal returns (uint256) {
        uint256 s = token.totalSupply();

        require(s + amt <= BondingCurveLib.SUPPLY_CAP, "cap");
        uint256 cost = BondingCurveLib.cost(s, amt);

        require(cost <= maxEthAmount, "slippage");

        token.mint(user, amt);

        return cost;
    }

    function _sell(IMintBurnERC20 token, uint256 amt, uint256 minEthAmount, address user) internal returns (uint256) {
        uint256 s = token.totalSupply();

        uint256 refund = BondingCurveLib.cost(s - amt, amt);

        require(refund >= minEthAmount, "slippage");

        token.burn(user, amt);

        return refund;
    }
}
