// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice The QUEUE allocation arithmetic.
///
/// Every concentrated AMM is a PRO-RATA market: all liquidity at a price level fills
/// proportionally. This library is the difference: a swap is allocated FRONT-FIRST through an
/// ordered list, and **each seat is credited the PRICE SEGMENT IT ACTUALLY ABSORBED**.
///
/// **WHY NOT THE SWAP'S AVERAGE PRICE — this was the mechanism's one free lane, and closing it is
/// the whole point of the `wCum`/`wTotal` arguments.** Until now every seat a swap reached was
/// credited `amtIn * take / amtOut`, the swap's realised AVERAGE. That handed the head all of the
/// volume AND the same price as the seats behind it, so being first was upside with no matching
/// risk: simulated over benign, normal and toxic regimes the head beat an ordinary pro-rata LP in
/// EVERY ONE OF THEM, including the toxic regime that exists precisely to punish whoever is first
/// into a stale price. A position that wins in every state of the world is not a market, it is a
/// subsidy paid by the rest of the book, and AGENTS.md §5 names that failure by name.
///
/// A swap sweeps a RANGE of prices. Being first in line means being filled first, and the first
/// fills happen at the STALEST end of that range. So the head now eats the top of every move it is
/// first into, and the seats behind it fill nearer the post-move price — which is what makes depth
/// a senior claim rather than idle capital. Same total to the wei; only the split changes.
///
/// THERE IS EXACTLY ONE IMPLEMENTATION OF THE ARITHMETIC — `step`. The hook drives it directly over
/// storage, touching only the seats it actually fills; `allocate` drives it over a memory array so
/// the identical arithmetic can be fuzzed with no pool at all. Two callers, one algorithm, so they
/// cannot drift apart.
library Allocation {
    /// @dev The queue cannot pay out more of the outgoing token than it holds. Loud, never silent:
    ///      a silent under-fill would hand the swapper tokens no seat owns.
    error QueueUnderflow(uint256 shortfall);

    /// @notice Running state of one swap's allocation.
    struct State {
        uint256 amtIn; // incoming token the queue receives, NET of protocol fee
        uint256 amtOut; // outgoing token the queue must give up
        uint256 remaining; // outgoing token still to be sourced
        uint256 assigned; // incoming token handed out so far
    }

    struct Fill {
        uint256 index;
        uint256 take;
        uint256 give;
    }

    function init(uint256 amtIn, uint256 amtOut) internal pure returns (State memory st) {
        st = State({amtIn: amtIn, amtOut: amtOut, remaining: amtOut, assigned: 0});
    }

    /// @notice Allocate one seat holding `bal` of the outgoing token, and advance `st`.
    ///
    /// @param wCum  the price curve's CUMULATIVE weight once this seat's `take` has been sourced —
    ///              i.e. the input the pool absorbs over the whole span from the swap's start
    ///              through the end of this seat's segment. Must be non-decreasing across
    ///              successive calls, which is what makes every `give` non-negative.
    /// @param wTotal the same curve evaluated at the FULL `amtOut`. **Pass `0` to price at the
    ///              swap's average instead** — the honest fallback when there is no curve to read
    ///              (`liquidity == 0`, or a degenerate span), never a silent default.
    ///
    /// @dev THE REMAINDER LINE LIVES HERE, and it is the whole mechanism.
    ///
    ///      `give` is derived from the curve for every seat EXCEPT THE LAST FILLED ONE, which
    ///      absorbs `amtIn - assigned`. Without that, each rounded share loses up to one wei, the
    ///      queue is short up to k-1 wei on EVERY swap, and the shortfall compounds forever.
    ///
    ///      It is only observable on a MULTI-SEAT fill: a single-seat fill hits the remainder line
    ///      immediately and is handed `amtIn` whole, with zero loss and no curve consulted at all.
    ///      A refactor that survives a one-seat test proves nothing (PLAN §B.5 step 4) — and note
    ///      that this is ALSO why the head-only swap pays nothing for marginal pricing: the branch
    ///      that reads the curve is never entered.
    ///
    ///      **THE CUMULATIVE FORM IS WHAT MAKES THIS EXACT.** `give` is the DIFFERENCE of two
    ///      cumulative allocations, not a rounded share of its own. Successive `mulDiv`s of the
    ///      same `amtIn` against a non-decreasing `wCum` telescope, so the parts cannot drift from
    ///      the whole no matter how the curve is shaped; the last seat's `amtIn - assigned` then
    ///      closes it to the wei. A per-seat rounded share would not telescope and would need the
    ///      remainder to absorb an error that grows with the number of seats filled.
    function step(State memory st, uint256 bal, uint256 wCum, uint256 wTotal)
        internal
        pure
        returns (uint256 take, uint256 give)
    {
        take = bal < st.remaining ? bal : st.remaining;
        st.remaining -= take;
        if (st.remaining == 0) {
            give = st.amtIn - st.assigned;
        } else if (wTotal == 0) {
            give = FullMath.mulDiv(st.amtIn, take, st.amtOut);
        } else {
            uint256 g = FullMath.mulDiv(st.amtIn, wCum, wTotal);
            // Defensive only: `wCum` is non-decreasing and `mulDiv` is monotone, so `g` cannot
            // fall below what is already assigned. If a future caller ever breaks that, this
            // clamps to a zero share rather than underflowing and reverting the whole swap.
            if (g < st.assigned) g = st.assigned;
            if (g > st.amtIn) g = st.amtIn;
            give = g - st.assigned;
        }
        st.assigned += give;
    }

    /// @notice Array-driven form of the same allocation, for fuzzing without a pool.
    ///
    /// @dev **IT DELIBERATELY DOES NOT REPORT A CURSOR.** It used to, and Phase 5's mutation
    ///      campaign found that nothing read it: every call site discarded the value, and no
    ///      production path calls this function at all. That made the cursor rule a SECOND COPY of
    ///      INVARIANT C — the hook's `_allocate` carries the real one — with all the liability of a
    ///      rule kept in two places (wrong four times on this project: PITFALLS 5.37, 5.50, 5.52
    ///      twice) and none of the value. Deleting an unused line is one of the three honest
    ///      answers to a surviving mutation, and it was the right one here: the cursor already has
    ///      an INDEPENDENT witness in `QueueFixture`, written from PLAN §B.6's prose rather than
    ///      from this file, and asserted after every swap by `_checkInvariantC`.
    ///
    /// @param cumW  cumulative curve weights indexed by TOUCHED-seat count, mirroring the order the
    ///              hook evaluates them in. Empty (with `wTotal == 0`) prices at the swap average.
    ///              A fuzzer may pass ANY non-decreasing sequence: conservation is a property of
    ///              the cumulative form, not of this particular curve, and it should hold for all
    ///              of them.
    /// @return fills one entry per seat touched, in rank order
    function allocate(
        uint256[] memory balances,
        uint256 start,
        uint256 amtIn,
        uint256 amtOut,
        uint256[] memory cumW,
        uint256 wTotal
    ) internal pure returns (Fill[] memory fills) {
        State memory st = init(amtIn, amtOut);
        fills = new Fill[](balances.length);
        uint256 touched;

        for (uint256 i = start; i < balances.length && st.remaining > 0; i++) {
            uint256 bal = balances[i];
            if (bal == 0) continue;
            (uint256 take, uint256 give) = step(st, bal, touched < cumW.length ? cumW[touched] : 0, wTotal);
            fills[touched] = Fill({index: i, take: take, give: give});
            touched++;
        }

        if (st.remaining != 0) revert QueueUnderflow(st.remaining);

        assembly ("memory-safe") {
            mstore(fills, touched)
        }
    }
}
