// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookBond} from "./HookBond.sol";
import {Verdict} from "./IHookPredicate.sol";

/// @title AssayRegistry
/// @notice One view call that says everything checkable about a deployed v4 hook: what it is
/// PERMITTED to do, what it CLAIMS about itself, whether that claim currently holds, and how much
/// capital stands behind the claim.
///
/// Stateless and permissionless. There is nothing to register — a "registry entry" is derived from
/// the chain on demand, so no hook can be listed inaccurately, omitted, or squatted.
///
/// The headline number is deliberately NOT a grade. A letter grade invites the reader to outsource
/// the judgement; `bondedWei` next to what the hook is permitted to take is a price, and a price is
/// something the reader can reason about. A hook bonded below the value it controls is not safe, and
/// no scoring rubric should be allowed to imply otherwise.
contract AssayRegistry {
    struct HookReport {
        address hook;
        // --- what it is PERMITTED to do (decoded from the address, zero external calls)
        uint16 permissionBits;
        bool canReturnSwapDelta;
        bool canReturnLiquidityDelta;
        bool canBlockInitialize;
        // --- what it CLAIMS, and whether the claim holds right now
        bool hasRuntimeSpec;
        /// @dev The probe reverted or returned something unreadable. Distinct from `!hasRuntimeSpec`:
        /// one means "declares nothing", the other means "we could not tell". Collapsing them would
        /// report a hook with a perfectly good spec as having none.
        bool specProbeFailed;
        uint256 invariantCount;
        /// @dev The predicate addresses themselves. Slashing is all-or-nothing, which pushes an
        /// author toward the loosest spec that survives, so a count alone makes a vacuous spec and a
        /// tight one look identical. A reader must be able to go and read what is actually asserted.
        address[] invariants;
        uint256 violatedCount;
        uint256 inconclusiveCount;
        bool metered;
        uint256 flowLimitPerBlock;
        // --- what stands behind the claim
        uint256 bondedWei;
        uint256 liveBondCount;
        uint256 slashedBondCount;
        // --- how quickly that backing can disappear
        bool anyExitRequested;
        bool anyExitMatured;
        /// @dev True if the bond scan hit MAX_BOND_SCAN and the figures above are a lower bound.
        /// Reporting a partial total as if it were complete would be worse than reporting nothing.
        bool bondScanTruncated;
    }

    /// @dev Bond lists are per-hook and permissionless, so their length is attacker-influenced. An
    /// unbounded loop in a view function is still a denial of service for every UI that calls it.
    uint256 public constant MAX_BOND_SCAN = 256;

    HookBond public immutable hookBond;

    constructor(HookBond hookBond_) {
        hookBond = hookBond_;
    }

    function report(address hook) public view returns (HookReport memory r) {
        r.hook = hook;

        uint160 a = uint160(hook);
        r.permissionBits = uint16(a & Hooks.ALL_HOOK_MASK);
        r.canReturnSwapDelta =
            (a & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) != 0 || (a & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0;
        r.canReturnLiquidityDelta = (a & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG) != 0
            || (a & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG) != 0;
        r.canBlockInitialize = (a & Hooks.BEFORE_INITIALIZE_FLAG) != 0;

        (r.hasRuntimeSpec, r.specProbeFailed, r.invariantCount, r.violatedCount, r.inconclusiveCount) = _spec(hook);
        r.invariants = _invariants(hook);
        (r.metered, r.flowLimitPerBlock) = _flow(hook);
        (r.bondedWei, r.liveBondCount, r.slashedBondCount, r.anyExitRequested, r.anyExitMatured, r.bondScanTruncated) =
            _bonds(hook);
    }

    /// @notice Capital staked on each individual assertion, flattened across every live bond on the
    /// hook. This is the number tranches exist to publish: "40 ETH on never exceeding its budget,
    /// 0.01 ETH on its codehash" tells a reader something a single total cannot, and it is the only
    /// defence against a spec padded with claims nobody is really backing.
    /// @dev Separate from `report` so the common call stays cheap.
    function bondBreakdown(address hook)
        external
        view
        returns (address[] memory predicates, uint256[] memory stakes, bool truncated)
    {
        bytes32[] memory ids = hookBond.bondsOfHook(hook);
        uint256 nIds = ids.length;
        if (nIds > MAX_BOND_SCAN) {
            nIds = MAX_BOND_SCAN;
            truncated = true;
        }

        uint256 count;
        for (uint256 i = 0; i < nIds; ++i) {
            count += hookBond.predicatesOf(ids[i]).length;
        }
        predicates = new address[](count);
        stakes = new uint256[](count);

        uint256 k;
        for (uint256 i = 0; i < nIds; ++i) {
            address[] memory ps = hookBond.predicatesOf(ids[i]);
            uint96[] memory st = hookBond.stakesOf(ids[i]);
            for (uint256 j = 0; j < ps.length; ++j) {
                predicates[k] = ps[j];
                // Zero here is meaningful, not noise: that assertion was slashed and settled.
                stakes[k] = st.length > j ? st[j] : 0;
                ++k;
            }
        }
    }

    function reportMany(address[] calldata hooks) external view returns (HookReport[] memory out) {
        out = new HookReport[](hooks.length);
        for (uint256 i = 0; i < hooks.length; ++i) {
            out[i] = report(hooks[i]);
        }
    }

    /// @dev Every probe is a bounded staticcall whose failure is a data point, not an error. Most
    /// deployed hooks implement none of this, and "does not declare a spec" is exactly what the
    /// registry exists to show.
    /// @dev Gas: `verifySpec` needs roughly `RUNTIME_GAS * 64/63 + RUNTIME_HEADROOM` retained per
    /// invariant and REVERTS rather than answering wrong when short. A stingy cap therefore turns a
    /// healthy spec into "no spec". Budget generously; this is a view call and the caller pays.
    function _spec(address hook)
        private
        view
        returns (bool hasSpec, bool probeFailed, uint256 count, uint256 violated, uint256 inconclusive)
    {
        (bool ok, bytes memory data) = hook.staticcall{gas: 8_000_000}(abi.encodeWithSignature("verifySpec()"));
        if (!ok) {
            // A contract with no matching selector reverts with EMPTY returndata; one that
            // implements the function and then failed reverts with a reason. That is the only
            // signal available, so it is the one used.
            //
            // Honest limit: a hook that implements `verifySpec` and reverts with no reason at all
            // is indistinguishable from one that does not implement it, and will be reported as
            // declaring nothing. That error runs in the safe direction — understating a hook's
            // claims never overstates its safety.
            return (false, data.length > 0, 0, 0, 0);
        }
        if (data.length < 64) return (false, false, 0, 0, 0);
        Verdict[] memory verdicts = abi.decode(data, (Verdict[]));
        if (verdicts.length == 0) return (false, false, 0, 0, 0);
        hasSpec = true;
        count = verdicts.length;
        for (uint256 i = 0; i < verdicts.length; ++i) {
            if (verdicts[i] == Verdict.VIOLATED) violated++;
            else if (verdicts[i] == Verdict.INCONCLUSIVE) inconclusive++;
        }
    }

    function _invariants(address hook) private view returns (address[] memory out) {
        (bool ok, bytes memory data) = hook.staticcall{gas: 500_000}(abi.encodeWithSignature("runtimeInvariants()"));
        if (!ok || data.length < 64) return new address[](0);
        return abi.decode(data, (address[]));
    }

    function _flow(address hook) private view returns (bool metered, uint256 limit) {
        (bool ok, bytes memory data) = hook.staticcall{gas: 100_000}(abi.encodeWithSignature("flowLimitPerBlock()"));
        if (!ok || data.length != 32) return (false, 0);
        limit = abi.decode(data, (uint256));
        metered = limit != 0;
    }

    function _bonds(address hook)
        private
        view
        returns (uint256 bonded, uint256 live, uint256 slashed, bool exitRequested, bool exitMatured, bool truncated)
    {
        bytes32[] memory ids = hookBond.bondsOfHook(hook);
        uint256 n = ids.length;
        if (n > MAX_BOND_SCAN) {
            n = MAX_BOND_SCAN;
            truncated = true;
        }
        for (uint256 i = 0; i < n; ++i) {
            (, address author, uint96 amount, uint64 unbondingAt, bool wasSlashed) = hookBond.bonds(ids[i]);
            if (wasSlashed) {
                slashed++;
                continue;
            }
            if (author == address(0) || amount == 0) continue; // withdrawn, or never opened
            live++;
            bonded += amount;
            if (unbondingAt != 0) {
                exitRequested = true;
                if (block.timestamp >= unbondingAt) exitMatured = true;
            }
        }
    }
}
