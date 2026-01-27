// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    toBeforeSwapDelta
} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {
    SwapParams,
    ModifyLiquidityParams
} from "v4-core/types/PoolOperation.sol";
import {BondingCurveLib} from "./BondingCurveLib.sol";

interface IMintBurnERC20 {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function totalSupply() external view returns (uint256);
}

contract BondingCurveHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;

    IMintBurnERC20 public immutable token;
    bool public graduated;

    constructor(IPoolManager m, address t) BaseHook(m) {
        token = IMintBurnERC20(t);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
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

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        require(graduated, "LP disabled until graduation");

        return this.beforeAddLiquidity.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        require(!graduated, "ended");

        address user = abi.decode(hookData, (address));

        if (user == address(0))
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        bool buy = params.amountSpecified < 0;
        uint256 amt = uint256(
            buy ? -params.amountSpecified : params.amountSpecified
        );
        uint256 s = token.totalSupply();
        if (buy) {
            require(s + amt <= BondingCurveLib.SUPPLY_CAP, "cap");
            uint256 cost = BondingCurveLib.cost(s, amt);
            token.mint(user, amt);
            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(int128(int256(cost)), -int128(int256(amt))),
                0
            );
        } else {
            uint256 refund = BondingCurveLib.cost(s - amt, amt);
            token.burn(user, amt);
            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(-int128(int256(refund)), int128(int256(amt))),
                0
            );
        }
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (!graduated && token.totalSupply() >= BondingCurveLib.SUPPLY_CAP) {
            graduated = true;
        }

        return (this.afterSwap.selector, 0);
    }
}
