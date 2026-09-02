#!/usr/bin/env python3
"""On-disk mutation harness. NOT part of the build.

Applies one edit to `src/`, runs `forge test`, records RED / SURVIVED, reverts. A mutation that
SURVIVES is a finding with exactly three honest answers (AGENTS.md §3b): write the missing test,
delete the line, or write down why it cannot be tested. Widening a tolerance is none of them.

    python3 script/mutate.py            # all
    python3 script/mutate.py M17 M18    # a subset
"""
import subprocess, sys, os, shutil, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "src/queue/QueueHook.sol")
RENT = os.path.join(ROOT, "src/queue/libraries/Rent.sol")
ALLOC = os.path.join(ROOT, "src/queue/libraries/Allocation.sol")

# **THE INTERLOCK.** While this harness runs it holds a MUTANT on disk, so any OTHER `forge test`
# started against the repo compiles mutated production source and reports a failure that has nothing
# to do with what its author changed. AGENTS.md has warned about this in prose since Phase 6; prose
# does not stop it, and it has now cost time twice. So the campaign publishes a marker while it is
# live and `test/queue/Hygiene.t.sol` refuses to run when it sees one — except for the campaign's
# OWN `forge test` invocations, which are distinguished by `QUEUE_MUTATION_RUN` in their env.
# It lives under `.forge-snapshots/` because that path already carries write permission in
# `foundry.toml`, so the guard needs no new filesystem grant to read it.
MARKER = os.path.join(ROOT, ".forge-snapshots", "MUTATION_IN_PROGRESS")

# (id, file, description, find, replace)
MUTS = [
    # ---------------------------------------------------------------- rank / the order word
    ("M1", HOOK, "demotion does not pull cursor0 back",
     "        if (cursor0 > r) cursor0 -= 1;", "        // MUT"),
    ("M2", HOOK, "demotion does not pull cursor1 back",
     "        if (cursor1 > r) cursor1 -= 1;", "        // MUT"),
    ("M3", HOOK, "demoted seat is written back at its OLD rank, not the tail",
     "        order = low | shifted | (seatId << (8 * (n - 1)));",
     "        order = low | shifted | (seatId << (8 * r));"),
    ("M4", HOOK, "the demoted seat keeps the rank it was demoted FROM",
     "        newRank = n - 1;", "        newRank = r;"),
    # M5 REPAIRED 2026-09-02. The pattern was the bare line `Seat storage seat_ = q[_idAt(ord, i)];`,
    # which was unique until Phase 8's `_settlePremium` introduced a character-identical line. Two
    # matches is a BAD-PATTERN, not a mutation, and the campaign said so. It now carries the loop
    # header above it, which belongs to `_allocate` alone.
    ("M5", HOOK, "the allocator indexes by SEAT ID instead of by rank",
     # REPAIRED 2026-09-02 (Phase 10): `_allocate` HOISTED `i` out of the `for` header so the
     # premium could be handed the last rank TOUCHED rather than the cursor. The old header no
     # longer exists and this case silently stopped running.
     "        uint256 i = start;\n"
     "        for (; i < n && st.remaining > 0; i++) {\n"
     "            Seat storage seat_ = q[_idAt(ord, i)];",
     "        uint256 i = start;\n"
     "        for (; i < n && st.remaining > 0; i++) {\n"
     "            Seat storage seat_ = q[i];"),
    ("M6", HOOK, "the degenerate fill indexes by rank instead of resolving the seat",
     "                uint256 idx = _idAt(order, rank);", "                uint256 idx = rank;"),
    ("M7", HOOK, "the cursor0 pull-back on funding compares against the SEAT ID",
     "        uint256 rank = rankOfId(seatId);\n        if (rank < cursor0) cursor0 = rank;",
     "        uint256 rank = rankOfId(seatId);\n        if (seatId < cursor0) cursor0 = seatId;"),
    ("M8", HOOK, "the cursor1 pull-back on funding compares against the SEAT ID",
     "        if (rank < cursor1) cursor1 = rank;\n    }",
     "        if (seatId < cursor1) cursor1 = seatId;\n    }"),

    # ---------------------------------------------------------------------------- rent maths
    ("M9", RENT, "rent ignores tau",
     "        return (selfPrice * bps * elapsed) / (MAX_BPS * period);",
     "        return (selfPrice * elapsed) / period;"),
    ("M10", RENT, "rent ignores elapsed time",
     "        return (selfPrice * bps * elapsed) / (MAX_BPS * period);",
     "        return (selfPrice * bps) / MAX_BPS;"),
    ("M11", RENT, "the distribution never reaches its last recipient, so the remainder is never absorbed",
     "        Allocation.State memory st = Allocation.init(amount, total);",
     "        Allocation.State memory st = Allocation.init(amount, total + 1);"),

    # ------------------------------------------------------------------------- settlement
    ("M12", HOOK, "settlement credits the recipients without debiting the payer",
     "        l.escrow = esc - charged;", "        // MUT"),
    ("M13", HOOK, "settlement never advances the clock (the same rent is charged again)",
     "        l.escrow = esc - charged;\n        l.lastSettled = uint64(block.timestamp);",
     "        l.escrow = esc - charged;"),
    ("M14", HOOK, "foreclosure fires one wei early (due >= escrow)",
     "        bool short_ = due > esc;", "        bool short_ = due >= esc;"),
    ("M15", HOOK, "an unpayable bill charges the whole amount instead of what the meter holds",
     "        uint256 charged = short_ ? esc : due;", "        uint256 charged = due;"),
    ("M16", HOOK, "foreclosure leaves the self-price standing",
     "            l.selfPrice = 0;\n            emit Foreclosed", "            emit Foreclosed"),
    ("M17", HOOK, "foreclosure does not demote",
     "            emit Foreclosed(seatId, due, charged, _demoteToTail(seatId));",
     "            emit Foreclosed(seatId, due, charged, rankOfId(seatId));"),
    ("M18", HOOK, "an unpriced seat is still charged (stale lastSettled is used)",
     "        uint256 price = l.selfPrice;\n        if (price == 0) return;",
     "        uint256 price = l.selfPrice;"),
    ("M19", HOOK, "rent is distributed from the payer's rank AFTER it has been demoted",
     "        _distributeRent(seatId, charged);\n\n        if (short_) {\n            l.selfPrice = 0;\n            emit Foreclosed(seatId, due, charged, _demoteToTail(seatId));\n        }",
     "        uint256 nr = rankOfId(seatId);\n        if (short_) {\n            l.selfPrice = 0;\n            nr = _demoteToTail(seatId);\n        }\n        _distributeRent(seatId, charged);\n        if (short_) emit Foreclosed(seatId, due, charged, nr);"),

    # ----------------------------------------------------------------------- distribution
    ("M20", HOOK, "the payer receives its own rent (loop starts at its own rank)",
     # REPAIRED 2026-09-02 (Phase 10): rent is weighted by `liquidity`, not `a0`.
     "        for (uint256 i = r + 1; i < n; i++) {\n            w += q[_idAt(ord, i)].liquidity;",
     "        for (uint256 i = r; i < n; i++) {\n            w += q[_idAt(ord, i)].liquidity;"),
    ("M21", HOOK, "the credit loop starts at the payer's own rank",
     "        for (uint256 i = r + 1; i < n && st.remaining > 0; i++) {",
     "        for (uint256 i = r; i < n && st.remaining > 0; i++) {"),
    ("M22", HOOK, "the rent split never absorbs its remainder (the last recipient is short)",
     "        Allocation.State memory st = Allocation.init(pot, w);",
     "        Allocation.State memory st = Allocation.init(pot, w + 1);"),
    ("M23", HOOK, "undistributable rent leaves the escrow aggregate untouched",
     "            escrowTotal -= amount;\n            unallocatedRent0 = pot;", "            unallocatedRent0 = pot;"),
    ("M24", HOOK, "the previously-held pot is dropped when there is no recipient",
     "            unallocatedRent0 = pot;\n            emit RentSettled", "            unallocatedRent0 = amount;\n            emit RentSettled"),
    ("M25", HOOK, "the held pot is not cleared after being paid out (double spend)",
     "        unallocatedRent0 = 0;\n        emit RentSettled(payerId, amount, pot, 0);",
     "        emit RentSettled(payerId, amount, pot, 0);"),
    ("M26", HOOK, "the escrow aggregate is not moved by a distribution",
     "        escrowTotal = escrowTotal - amount + pot;", "        // MUT"),
    ("M27", HOOK, "the held pot is never folded into the next distribution",
     "        uint256 pot = amount + held;", "        uint256 pot = amount;"),

    # -------------------------------------------------------------------------- settleAhead
    ("M28", HOOK, "funding a seat does not settle the seats in front of it",
     "        _settleAhead(rankOfId(seatId));\n        _fundSeat", "        _fundSeat"),
    ("M29", HOOK, "settleAhead does not compensate for a demotion shifting the ranks",
     "            if (order == before) i++;\n            else rank--;", "            i++;"),

    # ------------------------------------------------------------------ self-price / firm quote
    ("M30", HOOK, "repricing does not settle first (the raise is retroactive)",
     "        _settleSeat(seatId);\n\n        Lease storage l = lease[seatId];\n        uint256 old = l.selfPrice;",
     "        Lease storage l = lease[seatId];\n        uint256 old = l.selfPrice;"),
    ("M31", HOOK, "the firm quote is not the running minimum over the window",
     "            if (newPrice < l.firmPrice) l.firmPrice = newPrice;", "            // MUT"),
    ("M32", HOOK, "a first assessment is armed at zero, leaving every new price free for the window",
     # REPAIRED 2026-09-02: Phase 9 added `&& !promoted` and this case has not run since.
     "        } else if (old != 0 && !promoted) {", "        } else {"),
    ("M33", HOOK, "the firm quote keeps the NEW price rather than the lower of the two",
     "            l.firmPrice = old < newPrice ? old : newPrice;", "            l.firmPrice = newPrice;"),
    ("M34", HOOK, "repricing does not reset the rent clock",
     "        l.selfPrice = newPrice;\n        l.lastSettled = uint64(block.timestamp);",
     "        l.selfPrice = newPrice;"),
    ("M35", HOOK, "the firm quote is ignored by the ask",
     "        if (block.timestamp < l.firmUntil) {\n            uint256 f = l.firmPrice;\n            if (f < p) return f;\n        }",
     "        // MUT"),
    ("M36", HOOK, "the self-price bound is removed",
     "        if (newPrice > Rent.MAX_SELF_PRICE) revert SelfPriceTooLarge(newPrice, Rent.MAX_SELF_PRICE);",
     "        // MUT"),

    # ------------------------------------------------------------------------------- buyout
    ("M37", HOOK, "the buyer's price cap is not enforced",
     "        if (price > maxPrice) revert PriceAboveMax(price, maxPrice);", "        // MUT"),
    ("M38", HOOK, "the buyout does not settle the seller's rent first",
     # REPAIRED 2026-09-02: Phase 9 inserted the rank guards between `_settleSeat` and the holder
     # read, so the old two-line pattern stopped matching. Anchored on the comment above the call,
     # which belongs to `_buySeat` alone.
     "        // then pays whatever the seat is actually worth after that, not before it.\n"
     "        _settleSeat(seatId);",
     "        // then pays whatever the seat is actually worth after that, not before it.\n"
     "        // MUT: the seller's rent is not settled before the sale"),
    ("M39", HOOK, "the seller is not credited the sale price",
     "            pending0[holder] += price;\n            pendingTotal0 += price;",
     "            pendingTotal0 += price;"),
    ("M40", HOOK, "the sale price is not added to the float that backs the claim",
     "            float0 += price;", "            // MUT"),
    ("M41", HOOK, "the firm quote is not armed at what the buyer paid",
     # REPAIRED 2026-09-02: Phase 9's `buySeatAndFund` inserted `fundOnTransfer0/1` between these.
     "        paidForSeat = price;\n        fundOnTransfer0", "        fundOnTransfer0"),
    ("M42", HOOK, "buying your own seat is allowed",
     "        if (holder == msg.sender) revert CannotBuyOwnSeat(seatId);", "        // MUT"),
    ("M43", HOOK, "the buyer's own assessment is not applied",
     "        _setPrice(seatId, newSelfPrice);\n        emit SeatBought", "        emit SeatBought"),

    # -------------------------------------------------------------------------- seat transfer
    ("M44", HOOK, "the prepaid meter is not refunded to the departing holder",
     "        _send(from, p0 + esc, p1);", "        _send(from, p0, p1);"),
    ("M45", HOOK, "the escrow aggregate is not reduced when the meter is refunded",
     "                l.escrow = 0;\n                escrowTotal -= esc;", "                l.escrow = 0;"),
    ("M46", HOOK, "the new holder inherits the old holder's self-price",
     "            l.selfPrice = 0;\n            l.firmPrice = paid;", "            l.firmPrice = paid;"),
    ("M47", HOOK, "the transfer predicate is read AFTER settling, so a foreclosure erases it",
     "        bool live = l.selfPrice != 0 || l.escrow != 0 || paid != 0 || l.firmUntil > block.timestamp;\n\n        _settleSeat(seatId);",
     "        _settleSeat(seatId);\n        bool live = l.selfPrice != 0 || l.escrow != 0 || paid != 0 || l.firmUntil > block.timestamp;"),
    ("M48", HOOK, "the departing holder's rent is not settled on the way out",
     "        _settleSeat(seatId);\n\n        uint256 esc = l.escrow;", "        uint256 esc = l.escrow;"),

    # ------------------------------------------------------------------- meter funding / draining
    ("M49", HOOK, "withdrawing the meter does not settle what is owed first",
     "        _settleSeat(seatId);\n\n        Lease storage l = lease[seatId];\n        if (amount > l.escrow)",
     "        Lease storage l = lease[seatId];\n        if (amount > l.escrow)"),
    ("M50", HOOK, "anyone can drain anyone's meter",
     "        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);\n        _settleSeat(seatId);\n\n        Lease storage l = lease[seatId];\n        if (amount > l.escrow)",
     "        _settleSeat(seatId);\n\n        Lease storage l = lease[seatId];\n        if (amount > l.escrow)"),
    ("M51", HOOK, "draining the meter does not reduce the escrow aggregate",
     "        l.escrow -= amount;\n        escrowTotal -= amount;", "        l.escrow -= amount;"),
    ("M52", HOOK, "funding the meter does not raise the escrow aggregate",
     "        lease[seatId].escrow += amount;\n        escrowTotal += amount;", "        lease[seatId].escrow += amount;"),
    ("M53", HOOK, "anyone can set anyone's self-price",
     "        if (seatHolder[seatId] != msg.sender) revert NotSeatOwner(seatId, msg.sender);\n        _setPrice(seatId, price);",
     "        _setPrice(seatId, price);"),

    # ------------------------------------------------- Phase 5b: the packed seat and its narrowing
    ("M54", HOOK, "the narrowing to uint128 truncates instead of reverting",
     "        if (x > type(uint128).max) revert SeatBalanceOverflow(x);\n        // casting",
     "        // casting"),
    ("M55", HOOK, "the allocator does not debit the seat it just filled (token1 out)",
     "                seat_.a1 = _u128(bal - take);", "                seat_.a1 = _u128(bal);"),
    ("M56", HOOK, "the allocator does not debit the seat it just filled (token0 out)",
     "                seat_.a0 = _u128(bal - take);", "                seat_.a0 = _u128(bal);"),
    ("M57", HOOK, "the incoming token is never credited to the seat (token1 out)",
     "                seat_.a0 = _u128(uint256(seat_.a0) + give);", "                // MUT"),
    ("M58", HOOK, "the incoming token is never credited to the seat (token0 out)",
     "                seat_.a1 = _u128(uint256(seat_.a1) + give);", "                // MUT"),

    # ------------------------------------------------------- the remainder line (PLAN B.5 step 4)
    # Never previously in this harness, and it is the single most load-bearing line in the project:
    # without it every floored share loses up to a wei and the shortfall compounds forever. It is
    # ONE implementation shared by the swap allocator and the rent distribution, so one mutation
    # reaches both.
    # M59 RETIRED 2026-09-01 and SUPERSEDED BY M76, which is the same defect against the current
    # source. It targeted the one-line ternary `give = st.remaining == 0 ? ... : ...`, which no
    # longer exists: `Allocation.step` became an if/else when it started taking a price curve.
    # It is recorded here rather than deleted because a BAD-PATTERN is how the campaign REPORTED
    # the staleness, and that report is the only reason anyone noticed the mutation had stopped
    # testing anything. Do not re-add it without checking M76 first.
    ("M60", ALLOC, "the fill takes the whole balance even when less is needed",
     "        take = bal < st.remaining ? bal : st.remaining;", "        take = bal;"),
    # M61 was "the array form's cursor advances past a partially filled seat". It SURVIVED, and
    # the honest answer was to DELETE the line rather than test it: no production path calls
    # `Allocation.allocate`, every caller discarded its cursor, and the rule already lives in
    # `_allocate` (covered below) and in the fixture's independent witness. See PITFALLS 5.49 —
    # an unnecessary line is indistinguishable from an untested one.
    ("M61", HOOK, "the allocator's cursor advances past a seat that was only partially filled",
     "            next = take == bal ? i + 1 : i;", "            next = i + 1;"),

    # ============================================================ PHASE 6 — the campaign's findings
    #
    # Five lines the invariant campaign was what caught. Each is written here so the fix is proven
    # load-bearing the same way every other line in this contract is, and §D.8 V3 names the
    # invariant that goes red for each (`--campaign`).
    # M62/M63 REPAIRED 2026-09-02. The credit used to read the slot directly
    # (`_u128(uint256(sd.a0) + amtIn)`); it now reads the settled balance `_syncSeat` returns, and a
    # `standing0 += amtIn` line sits between the credit and the cursor pull-back. Same defect, same
    # line deleted — only the surrounding text moved.
    ("M62", HOOK, "the degenerate fill credits token0 without pulling cursor0 back (PITFALLS 5.73)",
     "                    sd.a0 = _u128(has0 + amtIn);\n"
     "                    standing0 += amtIn;\n"
     "                    if (rank < cursor0) cursor0 = rank;",
     "                    sd.a0 = _u128(has0 + amtIn);\n"
     "                    standing0 += amtIn;"),
    ("M63", HOOK, "the degenerate fill credits token1 without pulling cursor1 back (PITFALLS 5.73)",
     "                    sd.a1 = _u128(has1 + amtIn);\n"
     "                    standing1 += amtIn;\n"
     "                    if (rank < cursor1) cursor1 = rank;",
     "                    sd.a1 = _u128(has1 + amtIn);\n"
     "                    standing1 += amtIn;"),
    ("M64", HOOK, "the position measurement is unsigned again: an ADD net-credited by fees underflows (5.74)",
     "        return nowBal >= before ? int256(nowBal - before) : -int256(before - nowBal);",
     "        return int256(before - nowBal);"),
    ("M65", HOOK, "the deposit sizing narrows each leg before taking the minimum, as the periphery helper does (5.76)",
     "            uint256 a = _liq0(sqrtP, hi, amount0);\n            uint256 b = _liq1(lo, sqrtP, amount1);\n            l = a < b ? a : b;",
     "            uint256 a = _liq0(sqrtP, hi, amount0);\n            uint256 b = _liq1(lo, sqrtP, amount1);\n            require(a <= type(uint128).max && b <= type(uint128).max);\n            l = a < b ? a : b;"),
    ("M66", HOOK, "the removal sizing divides by a zero span at the tick boundary again (5.77)",
     "        uint256 l1 = (need1 == 0 || p == lo) ? 0 : _liq1(lo, p, need1);",
     "        uint256 l1 = need1 == 0 ? 0 : _liq1(lo, p, need1);"),

    # PHASE 7. The pool-binding guard was covered by TWO tests that could not tell this mutant from
    # a healthy contract: both used a bare `vm.expectRevert()`, and the mutant still reverts — with
    # `WrongPool` instead of `AlreadyBound`. LAW 2 exists for exactly this, and the violation
    # survived six phases. Both assertions now unwrap v4's `WrappedError` and name the selector.
    ("M67", HOOK, "an already-bound hook can be re-bound to a second pool (LAW 2: the reason matters)",
     "        if (bound) revert AlreadyBound();",
     "        // MUT"),
    ("M68", HOOK, "the pool disclosure lies about being bound, so an integrator reads an unbound hook",
     "        return (key, bound, tickLower, tickUpper);",
     "        return (key, false, tickLower, tickUpper);"),
    ("M69", HOOK, "the custodied position is full-range again, so a dollar of QUEUE is 200x thinner than a v3 LP",
     "        (tickLower, tickUpper) = _bandAround(sqrtPriceX96, k.tickSpacing);",
     "        tickLower = TickMath.minUsableTick(k.tickSpacing);\n        tickUpper = TickMath.maxUsableTick(k.tickSpacing);"),
    ("M70", HOOK, "the queue is credited the whole swap including wing fill, so a disjoint LP bricks solvency",
     "        (amtIn, amtOut) = _queueShare(k, params, amtIn, amtOut, pfDelta);",
     "        if (pfDelta > amtIn) revert ProtocolFeeExceedsInput(pfDelta, amtIn);\n        amtIn -= pfDelta;"),
    ("M71", HOOK, "overlapping liquidity is allowed, which is the N5 free lane on the band",
     "        if (params.tickUpper <= tickLower || params.tickLower >= tickUpper) {\n            return BaseHook.beforeAddLiquidity.selector;\n        }\n        revert OverlappingLiquidity(params.tickLower, params.tickUpper, tickLower, tickUpper);",
     "        return BaseHook.beforeAddLiquidity.selector;"),
    ("M72", HOOK, "the band half-width deploy parameter is ignored and 960 is hardcoded again",
     "        int24 half = _floorToSpacing(BAND_HALF_WIDTH, spacing);",
     "        int24 half = _floorToSpacing(int24(960), spacing);"),
    ("M73", HOOK, "a band narrower than one spacing is accepted, so the position has zero width",
     "        if (bandHalfWidth < tickSpacing || bandHalfWidth > TickMath.MAX_TICK / 2) {\n            revert BadBandWidth(bandHalfWidth, tickSpacing);\n        }",
     "        // MUT"),

    # ------------------------------------------------------- marginal pricing (the price curve)
    ("M74", ALLOC, "the price curve is ignored: every seat is credited the swap's AVERAGE price, "
                   "which is the head's free lane restored",
     "        } else if (wTotal == 0) {\n            give = FullMath.mulDiv(st.amtIn, take, st.amtOut);\n        } else {",
     "        } else if (true) {\n            give = FullMath.mulDiv(st.amtIn, take, st.amtOut);\n        } else {"),
    ("M75", ALLOC, "the cumulative form is broken into per-seat rounded shares, so the parts stop "
                   "summing to the whole",
     "            uint256 g = FullMath.mulDiv(st.amtIn, wCum, wTotal);",
     "            uint256 g = st.assigned + FullMath.mulDiv(st.amtIn, wCum, wTotal) / 2;"),
    ("M76", ALLOC, "the remainder line is deleted, so the last filled seat is short",
     "        if (st.remaining == 0) {\n            give = st.amtIn - st.assigned;",
     "        if (false) {\n            give = st.amtIn - st.assigned;"),
    # M77/M78 target `_bandEntry`, which is the SINGLE definition of where a swap meets the band.
    # Mutating it moves BOTH the in-band replay and the price curve, which is the point: the whole
    # reason it is one function is that the two must never disagree.
    ("M77", HOOK, "the swap is anchored at the far band edge instead of where it entered, so the "
                  "head is credited a price move that happened in someone else's wing",
     "        return zeroForOne ? (start < hi ? start : hi, lo) : (start > lo ? start : lo, hi);",
     "        return zeroForOne ? (hi, lo) : (lo, hi);"),
    ("M78", HOOK, "the band walk heads for the WRONG edge, reversing which end of the book is "
                  "priced better",
     "        return zeroForOne ? (start < hi ? start : hi, lo) : (start > lo ? start : lo, hi);",
     "        return zeroForOne ? (start < hi ? start : hi, hi) : (start > lo ? start : lo, lo);"),
    ("M79", HOOK, "the curve is evaluated at the seat's own take instead of the CUMULATIVE take, so "
                  "every seat is priced as if it were the head",
     "                if (cv.total != 0) wCum = _segmentIn(cv, outIsOne, amtOut - st.remaining + bal);",
     "                if (cv.total != 0) wCum = _segmentIn(cv, outIsOne, bal);"),
    ("M80", HOOK, "the band-edge clamp is removed from the price walk, so a swap that exhausts the "
                  "band reverts inside afterSwap and bricks the pool",
     "        if (outAmt >= cv.room) {\n            next = edge;",
     "        if (false) {\n            next = edge;"),

    # ---- PHASE 7: the priority premium. Every load-bearing line of it.
    ("M81", HOOK, "the premium is withheld from the seats but NOT deducted from the fill, so the "
                  "ledger credits the whole input AND accrues a pot: the queue claims more than the "
                  "position holds",
     "        Allocation.State memory st = Allocation.init(amtIn - _premiumOn(amtIn), amtOut);",
     "        Allocation.State memory st = Allocation.init(amtIn, amtOut);"),
    # M82 REPAIRED 2026-09-02, AND THE REPAIR IS NOT COSMETIC — the defect is the same and the way
    # to express it changed completely.
    #
    # It used to be "accrue BEFORE the fill". That worked because the weight WAS the seat's
    # inventory: accruing early meant a seat still held the token the swap was about to take, so it
    # carried weight and was handed back the pot it had just generated. Phase 8 made the weight
    # `liquidityContributed`, which a fill does not move at all — so accrual ORDER no longer decides
    # anything and the old mutation would have tested nothing even if its pattern had matched.
    #
    # What now stops a payer being paid out of its own pot is the EXCLUSION: `_settlePremium`
    # subtracts the paid seats' liquidity from the denominator and moves their marks past the
    # accrual. Accruing with an empty exclusion set is therefore the identical defect against the
    # current source, and it is what this mutation now does.
    ("M82", HOOK, "the seats a fill PAID are not excluded from the pot they generated, so the head is "
                  "handed back a share of its own payment",
     # REPAIRED 2026-09-02 (Phase 10): `_settlePremium` now receives `i`, the rank one past the
     # last TOUCHED, rather than the cursor `next`.
     "        _settlePremium(ord, start, i, outIsOne, amtIn - st.amtIn);",
     "        _accruePremium(outIsOne, amtIn - st.amtIn, 0);"),
    ("M83", HOOK, "a seat's mark is only advanced when its claim was non-zero, so a claim that "
                  "floored away leaves the interval claimable AGAIN later against a bigger balance",
     "        s.snap0 = premGrowth0;\n        s.snap1 = premGrowth1;",
     "        if (owed0 != 0) s.snap0 = premGrowth0;\n        if (owed1 != 0) s.snap1 = premGrowth1;"),
    ("M84", HOOK, "the settled premium is not added to `standing`, so the accumulator's denominator "
                  "drifts below the ledger it is supposed to weigh",
     "            standing0 += owed0;",
     "            standing0 += 0;"),
    ("M85", HOOK, "the allocator tests a seat for empty BEFORE settling it, so a seat holding "
                  "nothing but an unsettled premium is skipped — silent theft of rank",
     "            uint256 bal = _syncBal(seat_, outIsOne);\n            if (bal == 0) continue;",
     "            uint256 bal = outIsOne ? seat_.a1 : seat_.a0;\n            if (bal == 0) continue;\n"
     "            _syncBal(seat_, outIsOne);"),
    # M86 RETIRED 2026-09-02 — NOT SUPERSEDED, because the DEFECT IT POLICED CANNOT BE WRITTEN ANY
    # MORE. It compounded the two claims: weight the token1 claim by an `a0` that had already
    # absorbed the token0 credit, so the pot is handed out faster than it was accrued and the last
    # seats to settle find it empty. That required `_claims` to read TWO weights — `a1` for one
    # direction and `a0` for the other — which is exactly what made the premium's scale depend on
    # the pair's decimals (PITFALLS 5.126).
    #
    # Phase 8 weights BOTH directions by `s.liquidity`, one quantity that a settlement does not
    # touch. There is no longer a "first" credit that can contaminate a "second" weight, so any
    # attempt to write this mutation produces a contract identical to production — an EQUIVALENT
    # MUTANT, which reads as coverage while proving nothing. `Premium.t.sol`'s matching negative
    # control (`CompoundingPremiumHook`) was retired for the same reason on the same day, and
    # `test_N7_settlingCannotMoveTheWeightItIsPaidOn` replaced it: it asserts the structural
    # property this whole hazard rested on, so if a settlement ever moves the weight again, the
    # compounding class is live once more and that test goes red.
    #
    # Recorded rather than deleted, per M59's precedent: a retired case with a reason is evidence,
    # a deleted one is a gap.
    # M87 REPAIRED 2026-09-02. The hold branch was `if (w < total) { premiumHeld0 = total;
    # premiumOwed0 += pot; return; }`; it is now `if (inc == 0) { premiumHeld0 = total; return; }`
    # with `premiumOwed0 += pot` hoisted above it, because the release condition stopped being a
    # comparison between a pot and a weight in two different tokens. Same defect, same line deleted:
    # the wei is counted in `premiumOwed0` and held by nothing, so no seat can ever claim it.
    ("M87", HOOK, "a pot with nobody standing is DROPPED rather than held, so the wei leaves the "
                  "allocation and is never credited to anybody",
     "            if (inc == 0) {\n                premiumHeld0 = total;\n                return;\n            }",
     "            if (inc == 0) {\n                return;\n            }"),
]


CAMPAIGN = ["forge", "test", "--match-path", "test/queue/Invariant.t.sol"]


def failing_invariants(out):
    """The invariant/test names that went red, for §D.8 V3's 'name the failing invariant' column."""
    names = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("invariant_") or line.startswith("test_6_"):
            name = line.split("(")[0].strip()
            if name not in names:
                names.append(name)
    return names


def run(ids, campaign=False):
    src = {HOOK: open(HOOK).read(), RENT: open(RENT).read(), ALLOC: open(ALLOC).read()}
    # What THIS PROCESS believes it last wrote to each file. Anything else on disk is somebody
    # else's edit and must never be overwritten -- see the `finally` below.
    disk = dict(src)
    os.makedirs(os.path.dirname(MARKER), exist_ok=True)
    with open(MARKER, "w") as f:
        f.write(f"pid {os.getpid()} started {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    try:
        return _run(src, disk, ids, campaign)
    finally:
        if os.path.exists(MARKER):
            os.remove(MARKER)
        # **THIS `finally` IS LOAD-BEARING AND IT WAS PAID FOR TWICE.** This harness edits
        # PRODUCTION SOURCE in place.
        #
        # ROUND ONE (PITFALLS 5.79): an earlier version restored the file only on the happy path,
        # so a Ctrl-C left a MUTANT on disk and the next run read that mutant as its baseline. It
        # happened: the `p == lo` guard in `_liquidityToCover` was silently absent for a whole
        # campaign, visible only as a BAD-PATTERN on the mutation that targets it.
        #
        # ROUND TWO (PITFALLS 5.100), which is what the `disk` bookkeeping below is for: the fix
        # for round one restored the snapshot whenever the file differed from it -- INCLUDING when
        # the difference was somebody else's work. An agent editing `src/` while a campaign ran in
        # the background lost ~200 lines, and the only symptom was a compiler error pointing at the
        # caller of a function that no longer existed. A restore is only safe over content THIS
        # PROCESS put there; over anything else it is data loss, so it refuses and says so.
        for path, original in src.items():
            now = open(path).read()
            if now == original:
                continue
            if now != disk[path]:
                rel = os.path.relpath(path, ROOT)
                bak = path + ".mutate-backup"
                with open(bak, "w") as f:
                    f.write(original)
                print(
                    f"\n!! REFUSING TO RESTORE {rel} !!\n"
                    f"   It is not what this campaign last wrote, so something else edited it while\n"
                    f"   the campaign was running. Overwriting it would destroy that work.\n"
                    f"   The pre-campaign original has been written to {os.path.relpath(bak, ROOT)}.\n"
                    f"   Check `git diff {rel}` before doing anything else; a MUTANT may still be on\n"
                    f"   disk, or your own edit may be intact. Do not trust any test run until you\n"
                    f"   have looked.",
                    flush=True,
                )
                continue
            open(path, "w").write(original)
            disk[path] = original
            print(f"restored {os.path.relpath(path, ROOT)}", flush=True)


def preflight(src, todo):
    """Validate EVERY pattern against the source BEFORE running a single case.

    **A BAD-PATTERN IS AN UNRUN CASE, NEVER A PASS, AND A TRUNCATED RUN USED TO HIDE THAT.**
    Phase 9's campaign was interrupted at 30 of 85 and reported `0 BAD-PATTERN` — true of the 30 it
    reached and silent about the 55 it did not. Three cases (M32, M38, M41) had in fact been
    disarmed by Phase 9's own edits and did not run again until Phase 10, which is two phases of a
    free firm-quote window, a buyout that skips the seller's rent settlement, and a firm quote not
    armed at what the buyer paid, all going untested.

    Patterns are literal source text, so ANY edit to `src/` can silently disarm one. Checking them
    all up front costs milliseconds and makes the failure loud at second zero instead of at the case
    that may never be reached. Prose did not prevent this (AGENTS §3b: prose is not an interlock);
    this does.
    """
    broken = [(mid, desc, src[path].count(find)) for mid, path, desc, find, _ in todo
              if src[path].count(find) != 1]
    if broken:
        print("==== PREFLIGHT FAILED: patterns that do not match the source EXACTLY ONCE ====")
        for mid, desc, n in broken:
            print(f"  {mid:5} ({n} matches)  {desc}", flush=True)
        print("\nThese cases CANNOT RUN. A BAD-PATTERN is an unrun case, never a pass.")
        print("Re-point each pattern at the current source, then re-run.")
        print("Check the source with `git show HEAD:src/queue/QueueHook.sol`, NOT the working tree,")
        print("in case something is already holding a mutant there.")
    return broken


def _run(src, disk, ids, campaign):
    results = []
    todo = [m for m in MUTS if not ids or m[0] in ids]
    if preflight(src, todo):
        return 2
    for mid, path, desc, find, repl in todo:
        original = src[path]
        # Before touching the file, confirm it is still what we last left there. If it is not,
        # somebody is editing `src/` right now and continuing would overwrite their work on the
        # next mutation. Stop the whole run rather than race them.
        if open(path).read() != disk[path]:
            raise RuntimeError(
                f"{os.path.relpath(path, ROOT)} changed underneath this campaign. "
                f"Stopping so the edit is not overwritten. Check `git diff src/`."
            )
        if original.count(find) != 1:
            results.append((mid, "BAD-PATTERN", desc, original.count(find)))
            print(f"{mid:5} BAD-PATTERN ({original.count(find)} matches)  {desc}", flush=True)
            continue
        mutated = original.replace(find, repl)
        open(path, "w").write(mutated)
        disk[path] = mutated
        env = dict(os.environ, QUEUE_MUTATION_RUN="1")
        p = subprocess.run(
            CAMPAIGN if campaign else ["forge", "test"], cwd=ROOT, capture_output=True, text=True, env=env
        )
        open(path, "w").write(original)
        disk[path] = original
        out = p.stdout + p.stderr
        if "Compiler run failed" in out or "Error (" in out:
            verdict = "NO-COMPILE"
        elif p.returncode != 0:
            verdict = "RED"
        else:
            verdict = "SURVIVED"
        n_fail = out.count("[FAIL")
        results.append((mid, verdict, desc, n_fail))
        who = ""
        if campaign and verdict == "RED":
            who = "  <- " + ", ".join(failing_invariants(out)[:4])
        print(f"{mid:5} {verdict:10} ({n_fail} failing)  {desc}{who}", flush=True)

    print("\n==== SUMMARY ====")
    for v in ("SURVIVED", "NO-COMPILE", "BAD-PATTERN", "RED"):
        got = [r for r in results if r[1] == v]
        print(f"{v}: {len(got)}")
        if v != "RED":
            for r in got:
                print(f"    {r[0]}  {r[2]}")
    return 0 if not [r for r in results if r[1] != "RED"] else 1


if __name__ == "__main__":
    args = sys.argv[1:]
    # `--campaign` runs each mutation against the Phase 6 INVARIANT SUITE ONLY and names the
    # invariant that caught it. That is a different claim from "the full suite goes red" — §D.8 V3
    # requires the CAMPAIGN to be the thing that catches it.
    #
    # **UNKNOWN FLAGS ARE REFUSED, and that is not pedantry.** Every flag used to be discarded
    # silently, so `mutate.py --help` did not print help — it launched the FULL campaign, held a
    # mutant in `src/` for the duration, and locked the repository against `forge test`. A tool
    # that edits production source must not do anything at all on a typo.
    KNOWN = {"--campaign"}
    unknown = {a for a in args if a.startswith("-")} - KNOWN
    if unknown or "-h" in args or "--help" in args:
        if unknown - {"-h", "--help"}:
            print(f"unknown option(s): {' '.join(sorted(unknown - {'-h', '--help'}))}\n")
        print(
            "usage: python3 script/mutate.py [--campaign] [MID ...]\n\n"
            "  Edits src/ IN PLACE, one mutation at a time, and restores it in a `finally`.\n"
            "  NOTHING ELSE MAY TOUCH src/ OR RUN forge WHILE THIS IS RUNNING.\n\n"
            "  --campaign   run each mutation against test/queue/Invariant.t.sol alone and name\n"
            "               the invariant that caught it (§D.8 V3). Default is the full suite.\n"
            "  MID ...      run only these mutation ids (e.g. M75 M76). Default is all of them.\n"
        )
        sys.exit(0 if not (unknown - {"-h", "--help"}) else 2)
    camp = "--campaign" in args
    sys.exit(run({a for a in args if not a.startswith("--")}, campaign=camp))
