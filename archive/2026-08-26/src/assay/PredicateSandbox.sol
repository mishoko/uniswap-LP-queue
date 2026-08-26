// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHookPredicate, Verdict} from "./IHookPredicate.sol";

/// @notice Evaluates an untrusted, hook-author-chosen predicate without letting it mutate state,
/// reenter the caller, kill the outer transaction, or grief the caller with returndata.
///
/// Spike results (measured 2026-08-21 — do not rediscover, see docs/SPIKE-predicate-sandbox.md):
/// 1. `staticcall` gives mutation-rejection and reentrancy-blocking for free.
/// 2. Bounding the returndata copy to 32 bytes roughly HALVES a 128KB bomb (106k -> 53k gas) but
///    cost is NOT flat in return size: the callee's own memory expansion is paid out of the
///    caller's forwarded gas. STIPEND, not the copy bound, is the ceiling.
/// 3. Therefore callers MUST cap how many predicates they evaluate per transaction.
library PredicateSandbox {
    /// @dev Enough for extsload plus a handful of SLOADs. Deliberately small: a property that
    /// cannot be answered in this budget is a computation, not a safety invariant.
    uint256 internal constant STIPEND = 200_000;
    /// @dev Gas the caller must retain to finish slash/settle bookkeeping after evaluation.
    uint256 internal constant HEADROOM = 120_000;

    error InsufficientGas();

    function evaluate(address predicate, address hook) internal view returns (Verdict) {
        return evaluate(predicate, hook, STIPEND, HEADROOM);
    }

    /// @param stipend gas forwarded to the predicate. Adjudication (HookBond) can afford STIPEND;
    /// runtime enforcement inside a swap callback cannot, and passes a much smaller budget.
    function evaluate(address predicate, address hook, uint256 stipend, uint256 headroom)
        internal
        view
        returns (Verdict)
    {
        if (predicate.code.length == 0) return Verdict.INCONCLUSIVE;
        // 63/64 rule: the stipend is only actually forwarded if we hold 64/63 of it. Revert rather
        // than answer wrong, so an under-funded challenge can simply be retried with more gas.
        if (gasleft() < (stipend * 64) / 63 + headroom) revert InsufficientGas();

        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // IHookPredicate.check(address) == 0xc23697a8 (pinned by test_selector_matches_interface)
            mstore(ptr, 0xc23697a800000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), hook)
            ok := staticcall(stipend, predicate, ptr, 0x24, 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (!ok) return Verdict.INCONCLUSIVE; // revert, OOG, or attempted state mutation
        if (size != 32) return Verdict.INCONCLUSIVE; // malformed / non-conforming
        if (word > 1) return Verdict.INCONCLUSIVE; // dirty bool
        return word == 1 ? Verdict.HOLDS : Verdict.VIOLATED;
    }
}
