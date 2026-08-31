# SPIKE — price-then-queue (per-seat ranges)

**Date:** 2026-08-31. **Status:** EXECUTED. **Code:** `test/spike/PriceThenQueue.t.sol`.
**8 tests, 0 failed.** Real `PoolManager`, real router, price 1:4, decimals 18/6.

Tags as elsewhere: **[MEASURED]** executed · **[PROVEN]** source or test · **[ANALYSIS]** not executed · **[UNPROVEN]** named, not done.

---

## 0. VERDICT UP FRONT

> **The riskiest assumption HOLDS.** A swap that crosses from one concentrated band into the next can be attributed **to the wei** from a single `afterSwap` `BalanceDelta`, by replaying `SwapMath.computeSwapStep` over the hook's own bands. Sum of per-band fills = PoolManager's token delta net of protocol fees. Price priority is recovered. The naive "smear the delta by L" split is **wrong**, and a mutant that does it is red.
>
> **Price-then-queue is therefore an afterSwap allocator, not a new AMM.** It does not take over the swap (`beforeSwapReturnDelta`). It does not break v4's curve. v4 still walks ticks; the hook then knows *which of its bands* that walk used.
>
> **What this is NOT:** 32 queues per tick. Overlapping arbitrary v3-style ranges. A shipping feature. Protocol-fee-on, exact-out, and overlapping ranges are **UNPROVEN**.

Uniswap-alignment, stated as a sequence, not a leap:

```
TODAY (shipping)          v2a                    v2b (this spike)              v3
one full-range blob  →    concentrate that   →   3-band ladder,            →  arbitrary
one queue                 blob (test_1_11         non-overlapping,             per-seat
                          already PROVEN          walk MEASURED                ranges
                          orthogonal)             queue-within-band            (overlapping)
                                                  reuses Allocation.sol        UNPROVEN
```

Do **not** skip to v3. Do **not** custom-account the swap. Do **not** add an admin, a classifier, or a curve.

---

## 1. WHAT WAS THE QUESTION

v4 already has **price** priority: nearer ticks fill first. QUEUE today implements the missing **queue** half by destroying the ticks — one blob, one line. That is misaligned with Uniswap. The object that would be aligned:

```
A swap arrives
    │
    ▼
v4 walks ticks (unchanged) ──────────── price priority, already exists
    │
    ▼
afterSwap: one BalanceDelta
    │
    ▼
hook attributes the fill to the bands the price actually walked
    │
    ▼
within each band, Allocation.sol front-first ── the QUEUE half
```

The riskiest assumption was that the middle box is possible: **one number in, per-band fill out, to the wei, against a real PoolManager.**

A second assumption, already [PROVEN] from source: there is **no tick-crossing hook flag**. `Hooks.ALL_HOOK_MASK` is 14 bits, all named. `test_spike_v4HasNoTickCrossingCallback`. Reconstruction is mandatory; it is not a shortcut around a callback we forgot to turn on.

---

## 2. WHAT RAN

Sole-LP spike hook, three adjacent concentrated bands around `SQRT_PRICE_1_4`:

```
   below              at               above
[ mid-2w, mid-w ) [ mid-w, mid+w ) [ mid+w, mid+2w )
                         ^
                       price
w = 600 ticks ≈ 6% log-width, snapped to spacing 60. L = 1e18 each.
```

`MODE` is the mutation switch, identical test body:

| MODE | What it does | Expected on a crossing zeroForOne |
|---|---|---|
| **WALK (0)** | `SwapMath.computeSwapStep` per band in price order | below > 0, at > 0, above = 0, sums = PM delta |
| **PRO_RATA (1)** | smear the aggregate by L | **above > 0** — credits a band v4 did not touch |
| **HEAD_ONLY (2)** | dump the whole fill on `at` | **below = 0** — misses the band v4 did touch |

---

## 3. RESULTS [MEASURED]

| Test | Result | What it actually says |
|---|---|---|
| `smallSwapStaysInTheMiddleBand` | PASS | A head-only fill on a concentrated blob is 100% the middle band. The walk does not leak. |
| `crossingSwapSplitsAtTheBandEdge_toTheWei` | PASS | zeroForOne, 200e18 in: below and at both nonzero, above zero, sums = PM net input and output **to the wei**. Price left the middle band (`slot0.tick < tickLower_at`). |
| `crossingTheOtherWayHitsTheAboveBand` | PASS | oneForZero, 200e18 in: above and at both nonzero, below zero, sums match. (800e6 and 50e9 of the 6-decimal token **stayed inside** the middle band — the middle holds more token0 at 1:4, so the other direction needs a much larger input. Asserted by entering the band, not by hoping.) |
| `proRataByL_isWrongOnACrossingSwap` | PASS (control RED) | Sum still conserves. Composition is a lie: the untouched above band got a share. A conservation-only test is blind to this. |
| `headOnly_missesTheBelowBandOnACrossingSwap` | PASS (control RED) | Price left the middle band; HEAD_ONLY still reports below = 0. |
| `unmutatedCrossing_isThePositiveControlForTheMutants` | PASS | Same swap as the mutants, WALK is green. LAW 2's sibling. |
| `v4HasNoTickCrossingCallback` | PASS | 14 named bits, `ALL_HOOK_MASK = 2^14 - 1`. |
| `sameLCostsMoreTokensAtFullRange` | PASS | Same L is the same instantaneous depth (a first draft that claimed otherwise was **false** and the test caught it). The 1/200th claim is **same tokens**, not same L: full-range 1e18 L cost more of both tokens per unit L than the concentrated bands. |

**What a false first draft taught:** "concentrated is deeper per unit L" is wrong. Instantaneous depth is L. Concentration is how many *tokens* you spend to mint that L, and how far the price can walk before L drops to zero. The shipping full-range blob is thin because a dollar buys ~1/200th the L of a ±1% band, not because v4 treats L differently.

---

## 4. WHAT THIS KILLS, AND WHAT IT DOES NOT

**Killed**

- "Per-tick is a config change." It is a walk. `MAX_SEATS` does not grow with ticks.
- "You have to take over the swap with `beforeSwapReturnDelta`." You do not. That would *be* a new AMM. The spike did not.
- "You cannot know which range was filled from one delta." You can, for a **non-overlapping ladder**, to the wei.
- "Smear by L and call it price-priority." The mutant is red.

**Not killed, not claimed**

- **Overlapping ranges.** Two seats with different widths both covering the current tick: v4 sees `L_sum`, the walk must use combined L for the *price path*, then queue the step among covering seats. **UNPROVEN.** This is v3, not v2b.
- **Protocol fee nonzero.** The spike nets `protocolFeesAccrued` like QUEUE and charges the skim to the first band that took input. Not run with a live controller. **UNPROVEN.**
- **Exact-out.** Walk is exact-in only, matching the router the demo uses.
- **Gas.** No `vm.cool()` / `setUp()`-seeded measurement. Do not quote a number.
- **Production integration.** The spike hook has no Harberger, no ERC-6909, no float, no cursors. Wiring the walk in front of `Allocation.sol` is the next job, not this one.
- **Out-of-range seats.** A seat whose band is not in the walk gets fill 0. Rebalancing / range-move is unbuilt (same as `test_1_11`'s caveat).

---

## 5. THE IMPLEMENTATION PLAN — what happens, how, in order

PDCA. One thing at a time. The riskiest remaining assumption of each step is named. Do not start v3 because v2b is more interesting.

### v2a — concentrate the one blob (parameter)

**Why first:** already [PROVEN] orthogonal (`test_1_11`). Restores depth per dollar. Still one queue. Uniswap-shaped *inventory*, not yet Uniswap-shaped *ordering*.

**How:** `tickLower`/`tickUpper` are already only in the sizing helpers and `modifyLiquidity`. Seed a ±1% or ±10% band in `QueueDeployBase` / the demo. Out-of-range behaviour is the new hazard: a swap that walks *out* of the blob no-ops then `PriceLimitAlreadyExceeded`. Say that out loud. Do not claim a finished concentrated QUEUE.

**Mutations:** the existing suite plus "a swap that leaves the band" (must not brick deposit/withdraw). `test_1_11` is the positive control.

**Riskiest remaining assumption:** demo still works when a "sweep" has to be smaller to stay in-range. (Phase 7 already learned a 400e18 sweep touched one seat at full range.)

### v2b — three-band ladder, this spike's object

**Why:** this is the smallest thing that is *price then queue*. Below / at / above. Non-overlapping. The walk is MEASURED.

**How:**

1. Lift `RangeWalk` from the spike into `src/queue/libraries/RangeWalk.sol`. One implementation. The hook drives it over storage; a memory form exists so it can be fuzzed with no pool (same split as `Allocation.sol`).
2. Hook mints **three** positions (salts 0,1,2), not one. `beforeAddLiquidity` still sole-LP.
3. `afterSwap`: walk, get per-band `(amtIn, amtOut)`, then for each band that has a nonzero fill, run **existing** `Allocation.step` over the seats assigned to that band.
4. Seats gain a `band` id (0/1/2), not an arbitrary range. Rank is still the 32-byte word, but allocation iterates the in-band subset. Cursors become **per band, per direction** (six cursors) or a scan of the in-band subset (32 is small).
5. Rent, Harberger, ERC-6909, float: **unchanged objects.** A seat is still a seat. The band is an attribute of the seat, like capital.

**Mutations (do these, they are the ones that will find things):**

| Mutant | What must go red |
|---|---|
| Smear afterSwap delta by L, skip the walk | composition: untouched band gets fill |
| Walk bands in the wrong direction | zeroForOne credits `above` |
| One global cursor instead of per-band | a fill in `below` skips a funded `at` seat, or vice versa |
| Mint one position (union of the three ticks) | v4 L at the middle tick is wrong; depth and walk diverge |
| Remainder line dropped on the **per-band** Allocation | conservation dies on the second swap in that band |
| Protocol-fee skim applied twice (once in walk, once in QUEUE's window) | ledger short |

**Riskiest remaining assumption of v2b:** cursors / INVARIANT C across three bands. A cursor that leads a funded seat in *another* band is the 5.73 shape. Per-band cursors or a scan — pick one, mutate the other.

**Do not** let seats pick ranges in v2b. That is overlapping, that is v3.

### v3 — arbitrary per-seat ranges (overlapping)

**Why:** this is the actual Uniswap LP product: each seat is a v3 NFT plus a rank. **UNPROVEN.**

**How, if v2b is green:** a tick ladder built from every seat's `tickLower`/`tickUpper`. At each step, `L = sum of covering seats' L`, walk `computeSwapStep` with that L, then `Allocation.step` over the covering seats in rank order. This **is** reimplementing the tick walk. It is still not a new curve — the math is SwapMath, the pool still executed the swap.

**Riskiest assumption, not yet spiked:** combined-L price path + queue among a changing covering set, to the wei, including a swap that starts with two seats in range and ends with one out. Do not write production code against this until a spike like today's exists for it.

**Kill criterion:** if the overlapping spike cannot match PM delta to the wei, stop. Custom accounting (`beforeSwapReturnDelta`) is the remaining path and it *is* a new AMM. Do not take it to "be interesting."

---

## 6. WHAT NOT TO COMBINE

From `BUSINESS.md` §16.2, unchanged by this spike:

- Dynamic fee / am-AMM / LVR auction — saturated, Atrium AVOID on LVR auctions, muddies the sentence.
- `beforeSwapReturnDelta` taking over the swap — breaks "we use Uniswap's curve."
- 32 queues × every tick — not a program.
- A classifier, an admin, a keeper, an oracle.

What **does** compose, and is not this spike: JIT as `buySeat` for one block (already possible on the shipping hook). Demo it; do not redesign for it. A syndicate vault is a wrapper, not a fill rule.

---

## 7. HONEST SCORE OF THE IDEA, AFTER THE SPIKE

Before: "per-tick would be more interesting for Uniswap" was ANALYSIS.

After: **a non-overlapping ladder is implementable without breaking v4, and the walk is exact to the wei on a real PoolManager.** That is the first time this repo has a Uniswap-aligned v2 that is not "just concentrate the blob."

It is still not a prize-winning Impact slide until v2b is in the shipping hook and the demo shows a small swap filling the tight band and a large swap walking into the wing. The spike is the licence to build that, not the build.

---

## 8. HOW TO RUN

```bash
forge test --match-path test/spike/PriceThenQueue.t.sol -vv
```

Expect 8 passed, 0 failed. The two mutants are red by construction: they run as `MODE = 1` and `MODE = 2` under their own tests, which assert the *wrong composition*.
