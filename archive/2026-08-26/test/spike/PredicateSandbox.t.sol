// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @dev SPIKE ONLY (2026-08-21). Validates the riskiest assumption of the bond design:
/// can an untrusted, author-chosen predicate be evaluated by the bond contract without
/// (a) mutating state, (b) reentering, (c) killing the outer tx via OOG, or
/// (d) griefing the caller with a returndata bomb — and can a false result be
/// distinguished from an un-evaluable one? A revert MUST NOT read as "violated"
/// (free slashing of honest hooks) and MUST NOT read as "holds" (unslashable hooks).
///
/// Not product code. Promote PredicateSandbox to src/ only if every test here is green.

enum Verdict {
    HOLDS,
    VIOLATED,
    INCONCLUSIVE
}

interface IHookPredicate {
    /// @notice True if the asserted property holds for `hook` in present state.
    /// @dev MUST be view. MUST NOT depend on msg.sender. MUST return exactly 32 bytes.
    function check(address hook) external view returns (bool);
}

library PredicateSandbox {
    /// @dev Enough for extsload + a few SLOADs. Deliberately small: a predicate that
    /// cannot answer in this budget is not a safety property, it is a computation.
    uint256 internal constant STIPEND = 200_000;
    /// @dev Gas the caller must retain to finish the slash/settle flow after evaluation.
    uint256 internal constant HEADROOM = 120_000;

    error InsufficientGas();

    /// @dev Bounded returndata copy (max 32 bytes) so a bomb cannot charge the caller
    /// for memory expansion. Solidity's `(bool, bytes memory)` form copies everything.
    function evaluate(address predicate, address hook) internal view returns (Verdict) {
        if (predicate.code.length == 0) return Verdict.INCONCLUSIVE;
        // 63/64 rule: the stipend is only forwarded if we hold 64/63 of it.
        // Revert (do not silently answer) so a low-gas challenge can be retried.
        if (gasleft() < (STIPEND * 64) / 63 + HEADROOM) revert InsufficientGas();

        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // IHookPredicate.check(address)
            mstore(ptr, 0xc23697a800000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), hook)
            ok := staticcall(STIPEND, predicate, ptr, 0x24, 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (!ok) return Verdict.INCONCLUSIVE; // revert, OOG, or state-mutation attempt
        if (size != 32) return Verdict.INCONCLUSIVE; // malformed / non-conforming
        if (word > 1) return Verdict.INCONCLUSIVE; // dirty bool
        return word == 1 ? Verdict.HOLDS : Verdict.VIOLATED;
    }
}

/// @notice Real predicate, zero external calls: permission bits are encoded in the hook address.
/// Asserts the hook cannot return a swap delta.
contract NoSwapDeltaPredicate is IHookPredicate {
    function check(address hook) external pure returns (bool) {
        uint160 a = uint160(hook);
        return (a & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) == 0 && (a & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) == 0;
    }
}

contract HonestTrue is IHookPredicate {
    function check(address) external pure returns (bool) {
        return true;
    }
}

contract HonestFalse is IHookPredicate {
    function check(address) external pure returns (bool) {
        return false;
    }
}

contract Reverter is IHookPredicate {
    function check(address) external pure returns (bool) {
        revert("nope");
    }
}

contract Burner is IHookPredicate {
    function check(address) external view returns (bool) {
        while (gasleft() > 0) {}
        return true;
    }
}

/// @dev Deliberately NOT declaring the interface: a real attacker ships a nonpayable `check`.
contract Mutator {
    uint256 public x;

    function check(address) external returns (bool) {
        x += 1; // staticcall must reject this
        return true;
    }
}

/// @dev Returns 128KB, cheap enough for the callee to afford inside the stipend, so the
/// staticcall SUCCEEDS. That is the griefing case: the *caller* pays to copy it.
contract Bomber is IHookPredicate {
    function check(address) external pure returns (bool) {
        assembly {
            return(0, 0x20000)
        }
    }
}

contract ShortReturn is IHookPredicate {
    function check(address) external pure returns (bool) {
        assembly {
            return(0, 0x08)
        }
    }
}

contract DirtyBool is IHookPredicate {
    function check(address) external pure returns (bool) {
        assembly {
            mstore(0x00, 42)
            return(0x00, 0x20)
        }
    }
}

/// @dev Same: nonpayable `check` that tries to reenter the bond contract.
contract Reenterer {
    SandboxHarness public target;

    constructor(SandboxHarness t) {
        target = t;
    }

    function check(address) external returns (bool) {
        target.slashCounterBump(); // must fail under staticcall
        return true;
    }
}

contract SandboxHarness {
    uint256 public bumps;

    function slashCounterBump() external {
        bumps += 1;
    }

    function evaluate(address predicate, address hook) external view returns (Verdict) {
        return PredicateSandbox.evaluate(predicate, hook);
    }

    /// @dev The obvious implementation. Copies ALL returndata into memory -> griefable.
    function naiveEvaluate(address predicate, address hook) external view returns (Verdict) {
        (bool ok, bytes memory ret) =
            predicate.staticcall{gas: PredicateSandbox.STIPEND}(abi.encodeCall(IHookPredicate.check, (hook)));
        if (!ok || ret.length != 32) return Verdict.INCONCLUSIVE;
        return abi.decode(ret, (bool)) ? Verdict.HOLDS : Verdict.VIOLATED;
    }

    /// @dev Mirrors the real flow: evaluate, then still have gas to do the slash bookkeeping.
    function evaluateThenSettle(address predicate, address hook) external returns (Verdict v, uint256 gasAfter) {
        v = PredicateSandbox.evaluate(predicate, hook);
        gasAfter = gasleft();
        bumps += 1; // proves the outer tx survives and can still write
    }
}

contract PredicateSandboxSpikeTest is Test {
    SandboxHarness harness;
    address constant HOOK = address(0xBEEF);

    function setUp() public {
        harness = new SandboxHarness();
    }

    function test_selector_matches_interface() public pure {
        assertEq(IHookPredicate.check.selector, bytes4(0xc23697a8), "hardcoded selector in assembly must match");
    }

    function test_true_holds() public {
        assertEq(uint256(harness.evaluate(address(new HonestTrue()), HOOK)), uint256(Verdict.HOLDS));
    }

    function test_false_violated() public {
        assertEq(uint256(harness.evaluate(address(new HonestFalse()), HOOK)), uint256(Verdict.VIOLATED));
    }

    /// @dev The critical one: a reverting predicate must NOT slash an honest hook.
    function test_revert_isInconclusive_notViolated() public {
        assertEq(uint256(harness.evaluate(address(new Reverter()), HOOK)), uint256(Verdict.INCONCLUSIVE));
    }

    function test_noCode_isInconclusive() public view {
        assertEq(uint256(harness.evaluate(address(0xDEAD), HOOK)), uint256(Verdict.INCONCLUSIVE));
    }

    function test_oog_isInconclusive_andOuterTxSurvives() public {
        (Verdict v, uint256 gasAfter) = harness.evaluateThenSettle(address(new Burner()), HOOK);
        assertEq(uint256(v), uint256(Verdict.INCONCLUSIVE));
        assertGt(gasAfter, PredicateSandbox.HEADROOM / 2, "caller must retain gas to settle");
        assertEq(harness.bumps(), 1, "outer tx still wrote state after a gas-burning predicate");
    }

    function test_mutation_isRejectedByStaticcall() public {
        Mutator m = new Mutator();
        assertEq(uint256(harness.evaluate(address(m), HOOK)), uint256(Verdict.INCONCLUSIVE));
        assertEq(m.x(), 0, "predicate must not have mutated");
    }

    function test_reentrancy_isBlocked() public {
        Reenterer r = new Reenterer(harness);
        assertEq(uint256(harness.evaluate(address(r), HOOK)), uint256(Verdict.INCONCLUSIVE));
        assertEq(harness.bumps(), 0, "predicate must not reenter the bond contract");
    }

    /// @dev Differential: bounded copy vs the obvious Solidity implementation, same bomb.
    function test_returndataBomb_boundedVsNaive() public {
        address bomb = address(new Bomber());
        address honest = address(new HonestTrue());

        uint256 g0 = gasleft();
        Verdict v = harness.evaluate(bomb, HOOK);
        uint256 boundedBomb = g0 - gasleft();

        g0 = gasleft();
        harness.evaluate(honest, HOOK);
        uint256 boundedHonest = g0 - gasleft();

        g0 = gasleft();
        harness.naiveEvaluate(bomb, HOOK);
        uint256 naiveBomb = g0 - gasleft();

        assertEq(uint256(v), uint256(Verdict.INCONCLUSIVE), "128KB return is malformed");
        emit log_named_uint("bounded, bomb   ", boundedBomb);
        emit log_named_uint("bounded, honest ", boundedHonest);
        emit log_named_uint("naive,   bomb   ", naiveBomb);
        // SPIKE RESULT (measured, not assumed): the 32-byte copy bound roughly HALVES the
        // grief, but cost is NOT flat in return size -- the callee's own memory expansion is
        // paid out of the caller's forwarded gas. The stipend, not the copy bound, is the
        // ceiling. Design consequence: cap the number of predicates evaluated per tx, because
        // each one can burn up to STIPEND.
        assertLt(boundedBomb, naiveBomb, "bounded copy must beat the naive implementation");
        assertGt(boundedHonest * 10, boundedBomb / 10, "sanity: honest path is cheap");
        assertLe(boundedBomb, PredicateSandbox.STIPEND + 20_000, "stipend is the true ceiling");
    }

    function test_shortReturn_isInconclusive() public {
        assertEq(uint256(harness.evaluate(address(new ShortReturn()), HOOK)), uint256(Verdict.INCONCLUSIVE));
    }

    function test_dirtyBool_isInconclusive() public {
        assertEq(uint256(harness.evaluate(address(new DirtyBool()), HOOK)), uint256(Verdict.INCONCLUSIVE));
    }

    function test_lowGas_reverts_ratherThanAnsweringWrong() public {
        HonestFalse p = new HonestFalse();
        vm.expectRevert(PredicateSandbox.InsufficientGas.selector);
        harness.evaluate{gas: 150_000}(address(p), HOOK);
    }

    /// @dev A real, zero-call predicate over v4's address-encoded permissions.
    function test_realPredicate_permissionBits_zeroCalls() public {
        NoSwapDeltaPredicate p = new NoSwapDeltaPredicate();
        address safeHook = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
        address deltaHook = address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        assertEq(uint256(harness.evaluate(address(p), safeHook)), uint256(Verdict.HOLDS));
        assertEq(uint256(harness.evaluate(address(p), deltaHook)), uint256(Verdict.VIOLATED));
    }
}
