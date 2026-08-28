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
    ("M5", HOOK, "the allocator indexes by SEAT ID instead of by rank",
     "            Seat storage seat_ = q[_idAt(ord, i)];", "            Seat storage seat_ = q[i];"),
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
     "        for (uint256 i = r + 1; i < n; i++) {\n            w += q[_idAt(ord, i)].a0;",
     "        for (uint256 i = r; i < n; i++) {\n            w += q[_idAt(ord, i)].a0;"),
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
     "        } else if (old != 0) {", "        } else {"),
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
     "        _settleSeat(seatId);\n\n        address holder = seatHolder[seatId];", "        address holder = seatHolder[seatId];"),
    ("M39", HOOK, "the seller is not credited the sale price",
     "            pending0[holder] += price;\n            pendingTotal0 += price;",
     "            pendingTotal0 += price;"),
    ("M40", HOOK, "the sale price is not added to the float that backs the claim",
     "            float0 += price;", "            // MUT"),
    ("M41", HOOK, "the firm quote is not armed at what the buyer paid",
     "        paidForSeat = price;\n        _moveSeat", "        _moveSeat"),
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
    ("M59", ALLOC, "the remainder line is gone: every share is floored and the queue is short",
     "        give = st.remaining == 0 ? st.amtIn - st.assigned : FullMath.mulDiv(st.amtIn, take, st.amtOut);",
     "        give = FullMath.mulDiv(st.amtIn, take, st.amtOut);"),
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
    ("M62", HOOK, "the degenerate fill credits token0 without pulling cursor0 back (PITFALLS 5.73)",
     "                    sd.a0 = _u128(uint256(sd.a0) + amtIn);\n                    if (rank < cursor0) cursor0 = rank;",
     "                    sd.a0 = _u128(uint256(sd.a0) + amtIn);"),
    ("M63", HOOK, "the degenerate fill credits token1 without pulling cursor1 back (PITFALLS 5.73)",
     "                    sd.a1 = _u128(uint256(sd.a1) + amtIn);\n                    if (rank < cursor1) cursor1 = rank;",
     "                    sd.a1 = _u128(uint256(sd.a1) + amtIn);"),
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
    os.makedirs(os.path.dirname(MARKER), exist_ok=True)
    with open(MARKER, "w") as f:
        f.write(f"pid {os.getpid()} started {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    try:
        return _run(src, ids, campaign)
    finally:
        if os.path.exists(MARKER):
            os.remove(MARKER)
        # **THIS `finally` IS LOAD-BEARING AND IT WAS PAID FOR.** This harness edits PRODUCTION
        # SOURCE in place. An earlier version restored the file only on the happy path, so a
        # Ctrl-C — or any interrupt from the tool driving it — left a MUTANT on disk, and the next
        # run read that mutant as its baseline. It happened: the `p == lo` guard in
        # `_liquidityToCover` was silently absent for a whole campaign, which showed up only as a
        # BAD-PATTERN on the mutation that targets it. A mutation harness that can leave the
        # repository broken is worse than no mutation harness (PITFALLS 5.79).
        for path, original in src.items():
            if open(path).read() != original:
                open(path, "w").write(original)
                print(f"restored {os.path.relpath(path, ROOT)}", flush=True)


def _run(src, ids, campaign):
    results = []
    todo = [m for m in MUTS if not ids or m[0] in ids]
    for mid, path, desc, find, repl in todo:
        original = src[path]
        if original.count(find) != 1:
            results.append((mid, "BAD-PATTERN", desc, original.count(find)))
            print(f"{mid:5} BAD-PATTERN ({original.count(find)} matches)  {desc}", flush=True)
            continue
        open(path, "w").write(original.replace(find, repl))
        env = dict(os.environ, QUEUE_MUTATION_RUN="1")
        p = subprocess.run(
            CAMPAIGN if campaign else ["forge", "test"], cwd=ROOT, capture_output=True, text=True, env=env
        )
        open(path, "w").write(original)
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
    camp = "--campaign" in args
    sys.exit(run({a for a in args if not a.startswith("--")}, campaign=camp))
