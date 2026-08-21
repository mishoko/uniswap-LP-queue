// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AssayHook} from "../AssayHook.sol";
import {Verdict} from "../IHookPredicate.sol";
import {AssayHandler} from "./AssayHandler.sol";

/// @title AssaySuite
/// @notice Drop-in invariant campaign for any hook that declares an Assay spec. Inherit it, point
/// `assayedHook()` and `handler()` at your deployment, and a stateful fuzz campaign will spend
/// thousands of randomised swaps and liquidity operations actively trying to make your declared
/// spec false.
///
/// The point is that a declared spec is a claim, and an unchallenged claim is decoration. This is
/// the part that attacks it.
///
/// Deliberately NOT asserted here: that the hook's ledger debt settles to zero between
/// transactions. PoolManager already reverts any transaction that leaves an unsettled delta, so
/// such an invariant can never fail and would be a green number that tests nothing.
abstract contract AssaySuite is Test {
    function assayedHook() internal view virtual returns (AssayHook);

    function assayHandler() internal view virtual returns (AssayHandler);

    /// @notice Override to point at a hook that also inherits `AssayFlowMeter`.
    function meteredHook() internal view virtual returns (address) {
        return address(0);
    }

    /// @notice The spec must never be false. A VIOLATED verdict reachable by any sequence of
    /// ordinary pool traffic means the hook's declared guarantee is not a guarantee.
    function invariant_assay_specNeverViolated() public view {
        Verdict[] memory verdicts = assayedHook().verifySpec();
        for (uint256 i = 0; i < verdicts.length; ++i) {
            assertTrue(verdicts[i] != Verdict.VIOLATED, "declared spec became false under ordinary traffic");
        }
    }

    /// @notice The spec must never become un-evaluable either. Because enforcement fails closed, an
    /// INCONCLUSIVE verdict means the hook can no longer serve a callback: the pool is bricked. That
    /// is a real, findable defect and it is the direct cost of the fail-closed choice, so the
    /// campaign hunts for it explicitly rather than leaving it to be discovered in production.
    function invariant_assay_specNeverBecomesUnevaluable() public view {
        Verdict[] memory verdicts = assayedHook().verifySpec();
        for (uint256 i = 0; i < verdicts.length; ++i) {
            assertTrue(verdicts[i] != Verdict.INCONCLUSIVE, "spec became un-evaluable; the hook is bricked");
        }
    }

    /// @notice Metered flow must never exceed the declared per-block limit.
    function invariant_assay_flowWithinDeclaredLimit() public view {
        address h = meteredHook();
        if (h == address(0)) return;
        (bool okLimit, bytes memory limitData) = h.staticcall(abi.encodeWithSignature("flowLimitPerBlock()"));
        (bool okFlow, bytes memory flowData) = h.staticcall(abi.encodeWithSignature("flowThisBlock()"));
        if (!okLimit || !okFlow) return;
        uint256 limit = abi.decode(limitData, (uint256));
        if (limit == 0) return;
        assertLe(abi.decode(flowData, (uint256)), limit, "per-block flow limit was exceeded");
    }

    /// @notice Guards the campaign itself: a run in which nothing ever succeeded would satisfy every
    /// invariant above while proving nothing at all. This is the difference between a passing suite
    /// and a suite that did any work.
    function invariant_assay_campaignActuallyExercisedTheHook() public view {
        assertGt(assayHandler().swaps(), 0, "no swap ever succeeded; the campaign proved nothing");
    }
}
