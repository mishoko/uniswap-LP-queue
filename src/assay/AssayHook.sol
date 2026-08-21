// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHookPredicate, Verdict} from "./IHookPredicate.sol";
import {PredicateSandbox} from "./PredicateSandbox.sol";

/// @title AssayHook
/// @notice Base contract for a Uniswap v4 hook that carries its own machine-checked safety spec and
/// enforces it AT RUNTIME, inside its callbacks. A hook inheriting this cannot complete a
/// transaction that violates a declared invariant — the violation is unexecutable, not merely
/// compensable afterwards.
///
/// This is the half of Assay that prevents. `HookBond` is the half that pays for what prevention
/// cannot see. The division is deliberate and both halves are needed:
///   - Runtime invariants must be CHEAP (they run on every swap) and are therefore few and narrow.
///   - Bonded predicates can be richer, run only when a challenger pays for them, and cover the
///     properties too expensive to assert per-swap.
///
/// FAIL-CLOSED, INCLUDING ON DOUBT. A runtime invariant that reverts, runs out of its budget, or
/// returns garbage reads as INCONCLUSIVE and **reverts the user's transaction**, exactly as a
/// VIOLATED one does. This is a real, stated trade-off, not an oversight: a hook whose entire claim
/// is "I cannot violate my spec" must not proceed while unable to tell whether it is violating it.
/// The cost is that a badly written invariant can brick the pool. Mitigations: invariants are
/// evaluated at construction and must HOLD, the set is immutable, it is capped at four, and each
/// gets a small fixed budget. Anything richer belongs in a bonded predicate, not here.
///
/// Invariants are held in immutable slots rather than a dynamic array because this code runs on
/// every swap: an array costs an SLOAD per entry plus a length read, immutables cost nothing.
abstract contract AssayHook {
    /// @dev Per-invariant gas budget at runtime. Small on purpose. An invariant that cannot answer
    /// within this is not a per-swap safety property; bond it instead.
    uint256 internal constant RUNTIME_GAS = 30_000;
    uint256 internal constant RUNTIME_HEADROOM = 20_000;
    uint256 internal constant MAX_RUNTIME_INVARIANTS = 4;

    address private immutable _inv0;
    address private immutable _inv1;
    address private immutable _inv2;
    address private immutable _inv3;
    uint256 private immutable _invCount;

    error TooManyInvariants();
    error InvariantViolated(address invariant);
    error InvariantInconclusive(address invariant);

    event RuntimeInvariantsDeclared(address[] invariants);
    /// @dev A declared invariant could not be evaluated while an LP was leaving. The withdrawal was
    /// allowed anyway; this is the record that the hook is in trouble.
    event SpecUnevaluableOnExit(address invariant);

    /// @dev Every declared invariant must HOLD at construction. A hook cannot ship with a spec that
    /// is already broken, nor with one that is un-evaluable and therefore vacuous.
    constructor(address[] memory invariants_) {
        if (invariants_.length > MAX_RUNTIME_INVARIANTS) revert TooManyInvariants();

        _invCount = invariants_.length;
        _inv0 = invariants_.length > 0 ? invariants_[0] : address(0);
        _inv1 = invariants_.length > 1 ? invariants_[1] : address(0);
        _inv2 = invariants_.length > 2 ? invariants_[2] : address(0);
        _inv3 = invariants_.length > 3 ? invariants_[3] : address(0);

        emit RuntimeInvariantsDeclared(invariants_);
    }

    /// @notice The declared runtime spec, for the registry and for anyone deciding whether to trade
    /// against this hook.
    function runtimeInvariants() public view returns (address[] memory out) {
        out = new address[](_invCount);
        if (_invCount > 0) out[0] = _inv0;
        if (_invCount > 1) out[1] = _inv1;
        if (_invCount > 2) out[2] = _inv2;
        if (_invCount > 3) out[3] = _inv3;
    }

    /// @notice Human-readable spec, so the assertions are legible without reading bytecode.
    function describeSpec() external view returns (string[] memory out) {
        address[] memory invs = runtimeInvariants();
        out = new string[](invs.length);
        for (uint256 i = 0; i < invs.length; ++i) {
            out[i] = IHookPredicate(invs[i]).describe();
        }
    }

    /// @dev Call at the END of every state-changing callback. `view`, so it can only refuse — it
    /// can never move value, which is what keeps this safe to expose to inheritors.
    function _assertInvariants() internal view {
        uint256 n = _invCount;
        if (n == 0) return;
        _assertOne(_inv0);
        if (n == 1) return;
        _assertOne(_inv1);
        if (n == 2) return;
        _assertOne(_inv2);
        if (n == 3) return;
        _assertOne(_inv3);
    }

    /// @dev Called at the start of every sealed callback in `AssayBaseHook`, before the body. The
    /// default does nothing; `AssayFlowMeter` overrides it to snapshot PoolManager's ledger. Exists
    /// so a mixin that must observe a callback cannot be forgotten by an integrator, which is the
    /// same failure `AssayBaseHook` closes for the assertion itself.
    function _assayEnter() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Called at the end of every sealed callback, after `_assertInvariants`.
    function _assayExit(uint256) internal virtual {}

    /// @notice Enforcement for LP EXIT paths. Reverts on VIOLATED, but merely records INCONCLUSIVE.
    ///
    /// Everywhere else, doubt fails closed. On the way out it must not, and the asymmetry is
    /// deliberate. The invariant set is immutable and there is no recovery path, so a predicate that
    /// becomes permanently un-evaluable — an infrastructure failure, not an attack — would otherwise
    /// trap every LP's capital in the pool forever. That is a certain catastrophe traded against a
    /// bounded one.
    ///
    /// VIOLATED still blocks, because a genuine violation during a withdrawal is the hook extracting
    /// from the LP who is leaving, and refusing that protects the same person the carve-out is for.
    function _assertInvariantsAllowingExit() internal {
        uint256 n = _invCount;
        if (n == 0) return;
        _assertOneAllowingExit(_inv0);
        if (n == 1) return;
        _assertOneAllowingExit(_inv1);
        if (n == 2) return;
        _assertOneAllowingExit(_inv2);
        if (n == 3) return;
        _assertOneAllowingExit(_inv3);
    }

    function _assertOneAllowingExit(address invariant) private {
        Verdict v = PredicateSandbox.evaluate(invariant, address(this), RUNTIME_GAS, RUNTIME_HEADROOM);
        if (v == Verdict.VIOLATED) revert InvariantViolated(invariant);
        if (v == Verdict.INCONCLUSIVE) emit SpecUnevaluableOnExit(invariant);
    }

    function _assertOne(address invariant) private view {
        Verdict v = PredicateSandbox.evaluate(invariant, address(this), RUNTIME_GAS, RUNTIME_HEADROOM);
        if (v == Verdict.VIOLATED) revert InvariantViolated(invariant);
        if (v == Verdict.INCONCLUSIVE) revert InvariantInconclusive(invariant);
    }

    /// @notice Evaluate the whole declared spec under the generous adjudication budget, for the
    /// registry, for `HookBond`, and for anyone deciding whether to trade against this hook.
    /// @dev Deliberately NOT called from the constructor. During construction `address(this).code`
    /// is empty, so any predicate that calls back into the hook — which is most of the interesting
    /// ones — reverts on the extcodesize check and reads INCONCLUSIVE. A constructor gate would
    /// therefore only ever accept predicates that never look at the hook, which is the opposite of
    /// what it should enforce.
    ///
    /// It is also unnecessary. Because `_assertInvariants` fails closed, a hook deployed with a
    /// spec that does not hold simply cannot serve a callback: it is bricked on arrival, publicly
    /// and immediately. That is a stronger guarantee than a deploy-time check, not a weaker one.
    ///
    /// Evaluated at the RUNTIME budget, deliberately, not the generous adjudication one. Using the
    /// larger budget here would let a predicate needing 50k gas report HOLDS to the registry while
    /// the 30k callback check reads INCONCLUSIVE and refuses every swap — the registry would call a
    /// bricked hook healthy. This function answers the operative question: will this hook function?
    function verifySpec() external view returns (Verdict[] memory out) {
        address[] memory invs = runtimeInvariants();
        out = new Verdict[](invs.length);
        for (uint256 i = 0; i < invs.length; ++i) {
            out[i] = PredicateSandbox.evaluate(invs[i], address(this), RUNTIME_GAS, RUNTIME_HEADROOM);
        }
    }
}
