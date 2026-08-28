// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice The QUEUE allocation arithmetic.
///
/// Every concentrated AMM is a PRO-RATA market: all liquidity at a price level fills
/// proportionally. Every real electronic market is PRICE-TIME PRIORITY. This library is the
/// difference: a swap is allocated FRONT-FIRST through an ordered list, at the swap's own realised
/// average price `amtIn / amtOut`.
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
    /// @dev THE REMAINDER LINE LIVES HERE, and it is the whole mechanism.
    ///
    ///      `give` is floored for every seat EXCEPT THE LAST FILLED ONE, which absorbs
    ///      `amtIn - assigned`. Without that, each floored share loses up to one wei, the queue is
    ///      short up to k-1 wei on EVERY swap, and the shortfall compounds forever.
    ///
    ///      It is only observable on a MULTI-SEAT fill: a single-seat fill takes the whole of
    ///      `amtOut`, so its share is `mulDiv(amtIn, amtOut, amtOut)` — a fraction of exactly one,
    ///      which floors to `amtIn` with zero loss. A refactor that survives a one-seat test proves
    ///      nothing (PLAN §B.5 step 4).
    function step(State memory st, uint256 bal) internal pure returns (uint256 take, uint256 give) {
        take = bal < st.remaining ? bal : st.remaining;
        st.remaining -= take;
        give = st.remaining == 0 ? st.amtIn - st.assigned : FullMath.mulDiv(st.amtIn, take, st.amtOut);
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
    /// @return fills one entry per seat touched, in rank order
    function allocate(uint256[] memory balances, uint256 start, uint256 amtIn, uint256 amtOut)
        internal
        pure
        returns (Fill[] memory fills)
    {
        State memory st = init(amtIn, amtOut);
        fills = new Fill[](balances.length);
        uint256 touched;

        for (uint256 i = start; i < balances.length && st.remaining > 0; i++) {
            uint256 bal = balances[i];
            if (bal == 0) continue;
            (uint256 take, uint256 give) = step(st, bal);
            fills[touched] = Fill({index: i, take: take, give: give});
            touched++;
        }

        if (st.remaining != 0) revert QueueUnderflow(st.remaining);

        assembly ("memory-safe") {
            mstore(fills, touched)
        }
    }
}
