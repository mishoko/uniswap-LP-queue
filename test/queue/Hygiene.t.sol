// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {QueueHook} from "../../src/queue/QueueHook.sol";
import {QueueSeats} from "../../src/queue/QueueSeats.sol";

/// @notice PHASE 7 — tests about the project's OWN INSTRUMENTS, not about the mechanism.
///
/// `PITFALLS.md` 5.75 and 5.79 are both cases where the instrument was wrong and the code was
/// right, and both cost more time than any real bug. This file exists so the two instruments that
/// can still lie to us are checked by the suite rather than by discipline.
contract HygieneTest is Test {
    // ------------------------------------------------------------------ the viewer's selectors

    /// @dev 7.6 — `frontend/index.html` reads chain state with raw `eth_call` and therefore carries
    ///      four function selectors as string literals. That is a WRITER/READER PAIR THAT CAN
    ///      DISAGREE — the shape of defect this repository has been bitten by five times — and its
    ///      failure mode is the worst kind: an `eth_call` to a selector that no longer exists
    ///      returns EMPTY DATA, so the page renders zeros and looks like a working demo of an empty
    ///      queue. Not hypothetical: the first draft of that block was written from memory and
    ///      THREE OF THE FOUR were wrong.
    function test_7_6_theViewersSelectorsMatchTheContract() public view {
        string memory page = vm.readFile("frontend/index.html");
        _assertSelector(page, "S_RANKING", QueueHook.ranking.selector, "ranking()");
        _assertSelector(page, "S_SEAT", QueueHook.seat.selector, "seat(uint256)");
        _assertSelector(page, "S_LEASE", QueueHook.leaseOf.selector, "leaseOf(uint256)");
        _assertSelector(page, "S_OWNER", QueueSeats.ownerOf.selector, "ownerOf(uint256)");
        _assertSelector(page, "S_POOL", QueueHook.pool.selector, "pool()");
    }

    // ------------------------------------------------------------- the mutation-harness interlock

    /// @dev 7.7 — **REFUSE TO RUN WHILE A MUTATION CAMPAIGN HOLDS A MUTANT ON DISK.**
    ///
    ///      `script/mutate.py` edits `src/` in place for the duration of each case. A concurrent
    ///      `forge test` therefore compiles PRODUCTION SOURCE WITH A DELIBERATE BUG IN IT and
    ///      reports a failure that has nothing to do with the change its author was testing.
    ///      `AGENTS.md` has warned about this in prose since Phase 6 and the prose did not work —
    ///      it cost a confusing minute then and cost time again in Phase 7, to the agent who had
    ///      just read the warning. A hazard that recurs after being documented needs an interlock,
    ///      not a louder note.
    ///
    ///      The campaign's own runs carry `QUEUE_MUTATION_RUN=1` and are let through; anything else
    ///      fails here with an instruction rather than somewhere confusing with a wrong diagnosis.
    function test_7_7_noMutationCampaignIsHoldingAMutantOnDisk() public view {
        if (vm.envOr("QUEUE_MUTATION_RUN", false)) return; // this IS the campaign's own run
        string memory marker = ".forge-snapshots/MUTATION_IN_PROGRESS";
        if (!vm.exists(marker)) return;
        revert(
            string.concat(
                "A mutation campaign is running and is holding a MUTANT in src/ right now, so this ",
                "run is compiling deliberately broken production source. Wait for it, or if it died ",
                "hard (SIGKILL), delete ",
                marker,
                " and check `git diff src/` before believing anything. Marker says: ",
                vm.readFile(marker)
            )
        );
    }

    // ------------------------------------------------------------------------------- the plumbing

    /// @dev Matches the LIVE BINDING `const <name> = '0x........'`, not merely the presence of the
    ///      selector somewhere in the file — which would pass while the constant in use was wrong
    ///      and the right value sat in a comment.
    function _assertSelector(string memory page, string memory name, bytes4 want, string memory sig) internal pure {
        bytes memory hay = bytes(page);
        uint256 at = _find(hay, bytes(string.concat("const ", name)), 0);
        assertTrue(at != type(uint256).max, string.concat("frontend no longer declares ", name));

        uint256 q = _find(hay, bytes("'0x"), at);
        assertTrue(q != type(uint256).max && q < at + 64, string.concat("no selector literal after ", name));

        bytes memory got = new bytes(8);
        for (uint256 i; i < 8; i++) {
            got[i] = hay[q + 3 + i];
        }
        assertEq(
            _lower(string(got)),
            _hex4(want),
            string.concat("frontend selector for ", sig, " does not match the contract")
        );
    }

    function _find(bytes memory hay, bytes memory needle, uint256 from) internal pure returns (uint256) {
        if (needle.length == 0 || hay.length < needle.length) return type(uint256).max;
        for (uint256 i = from; i + needle.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 j; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    function _hex4(bytes4 v) internal pure returns (string memory) {
        bytes memory D = "0123456789abcdef";
        bytes memory o = new bytes(8);
        for (uint256 i; i < 4; i++) {
            o[i * 2] = D[uint8(v[i]) >> 4];
            o[i * 2 + 1] = D[uint8(v[i]) & 0x0f];
        }
        return string(o);
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }
}
