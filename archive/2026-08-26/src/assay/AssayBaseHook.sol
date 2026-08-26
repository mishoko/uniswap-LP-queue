// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AssayHook} from "./AssayHook.sol";

/// @title AssayBaseHook
/// @notice `AssayHook` where enforcement is not optional.
///
/// WHY THIS EXISTS. `AssayHook` alone gives an integrator `_assertInvariants()` and trusts them to
/// call it at the end of every callback that can move value. Trusting an integrator to remember one
/// line is precisely the failure mode this project claims to fix: forget it in one callback and the
/// hook still advertises a spec, still bonds against it, and enforces nothing there. OpenZeppelin's
/// `BaseHook` declares its external callbacks non-virtual, so they cannot be wrapped from outside.
///
/// So this contract implements every value-capable `_callback` itself, WITHOUT `virtual`, sealing
/// them. A subclass physically cannot override them; it implements `_assayX` instead, and the
/// assertion runs afterwards whether or not the author remembers it exists. Same sealing discipline
/// `HardcapHook` uses on its own callbacks — the strongest guarantee Solidity offers short of not
/// exposing the surface at all.
///
/// LP exit paths use `_assertInvariantsAllowingExit`, which records an un-evaluable spec instead of
/// reverting. The invariant set is immutable with no recovery path, so failing closed on withdrawal
/// would trap LP capital permanently whenever a predicate broke. A genuine VIOLATED still blocks.
///
/// Initialize callbacks are deliberately not wrapped: they cannot move value, and charging every
/// integrator gas to assert an invariant over a state nothing has touched is a cost with no
/// corresponding risk.
abstract contract AssayBaseHook is BaseHook, AssayHook {
    error AssayHookNotImplemented();

    constructor(IPoolManager poolManager_, address[] memory invariants_)
        BaseHook(poolManager_)
        AssayHook(invariants_)
    {}

    // --------------------------------------------------------------- sealed callbacks

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 mark = _assayEnter();
        (bytes4 s, BeforeSwapDelta d, uint24 f) = _assayBeforeSwap(sender, key, params, hookData);
        _assertInvariants();
        _assayExit(mark);
        return (s, d, f);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        uint256 mark = _assayEnter();
        (bytes4 s, int128 d) = _assayAfterSwap(sender, key, params, delta, hookData);
        _assertInvariants();
        _assayExit(mark);
        return (s, d);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        uint256 mark = _assayEnter();
        bytes4 s = _assayBeforeAddLiquidity(sender, key, params, hookData);
        _assertInvariants();
        _assayExit(mark);
        return s;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        uint256 mark = _assayEnter();
        bytes4 s = _assayBeforeRemoveLiquidity(sender, key, params, hookData);
        _assertInvariantsAllowingExit();
        _assayExit(mark);
        return s;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 mark = _assayEnter();
        (bytes4 s, BalanceDelta d) = _assayAfterAddLiquidity(sender, key, params, delta, feesAccrued, hookData);
        _assertInvariants();
        _assayExit(mark);
        return (s, d);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        uint256 mark = _assayEnter();
        (bytes4 s, BalanceDelta d) = _assayAfterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);
        _assertInvariantsAllowingExit();
        _assayExit(mark);
        return (s, d);
    }

    function _beforeDonate(address sender, PoolKey calldata key, uint256 a0, uint256 a1, bytes calldata hookData)
        internal
        override
        returns (bytes4)
    {
        uint256 mark = _assayEnter();
        bytes4 s = _assayBeforeDonate(sender, key, a0, a1, hookData);
        _assertInvariants();
        _assayExit(mark);
        return s;
    }

    function _afterDonate(address sender, PoolKey calldata key, uint256 a0, uint256 a1, bytes calldata hookData)
        internal
        override
        returns (bytes4)
    {
        uint256 mark = _assayEnter();
        bytes4 s = _assayAfterDonate(sender, key, a0, a1, hookData);
        _assertInvariants();
        _assayExit(mark);
        return s;
    }

    // ------------------------------------------------- implement these instead

    function _assayBeforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, int128(0));
    }

    function _assayBeforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }

    function _assayBeforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function _assayAfterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _assayAfterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _assayBeforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return this.beforeDonate.selector;
    }

    function _assayAfterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return this.afterDonate.selector;
    }
}
