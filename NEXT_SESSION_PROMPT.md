# NEXT SESSION — finish the priority premium. Everything you need is here.

Read this file first, then `AGENTS.md` → `PLAN.md` → `PROGRESS.md` (top entry) → `PITFALLS.md`.

**State: `forge test` → 224 passed, 0 failed, 1 skipped. `forge lint src/` clean, `forge fmt` clean.
The 7 new Phase-7 mutations (M81–M87) are all RED with 0 survivors.**

**THE FULL 86-MUTATION CAMPAIGN HAS NOT BEEN RUN AGAINST THIS TREE. Run it first:
`python3 script/mutate.py`.** It was started and interrupted at 14/86 — all RED, no survivors, no
BAD-PATTERNs — so the existing mutations that target lines Phase 7 edited are UNVERIFIED. That is the
`BAD-PATTERN` risk PITFALLS 5.111 names: `_allocate`'s loop body, the seat-balance writes and the
degenerate fill were all touched, and a mutation whose pattern has gone stale reports `BAD-PATTERN`
in a column nobody reads while the summary still says "0 SURVIVED". Before that, run
`sh script/install-hooks.sh`.

---

## 1. What changed, and why the last plan was thrown away

**The previous session's decision was ROTATION. It is dead.** Its case rested on three numbers and
an adversarial pass broke all three — seed-selected guarantee, a tautological "zero-sum proof", and
an ensemble-mean that hid 27% losing outcomes. The full autopsy is the banner at the top of
`docs/research/seat-economics/ROTATION.md`. **Do not re-open it without reading that banner.**

What replaced it came from one new measurement. Per rank, 30 paths, static rank, no premium:

```
      rank    fee %/yr   inventory   net %/yr   turnover %/yr
         0    +1240.1%    -328.3%    +911.8%       +411,877%
         1      +66.9%     -54.8%     +12.0%        +22,186%
         7       +5.7%     -26.2%     -20.5%         +1,903%
        31       +0.1%      -0.0%      +0.1%            +34%
```

**The head does not out-earn the book on PRICE — marginal pricing already makes it fill at the
stalest end of every move. It out-earns on VOLUME**, four orders of magnitude of it, and keeps the
whole fee on it. That single fact rules out both instruments this project reached for first: a price
tweak cannot touch a quantity difference, and a Harberger rent on an assessed value is ~6%/yr against
a 20–160%/yr inventory drag. Only a share of **fee flow** is denominated in the same thing the
advantage is.

So: **`PREMIUM_BPS` (φ). A filled seat keeps `(10000−φ)/10000` of the fee it earned; the rest goes to
the seats still standing in the line it jumped, weighted by the OPPOSITE token.** You are paid, in
the token the swapper brought, for the token you did not get to sell. A seat drained to zero carries
no weight and collects nothing from the pot it generated — the payer does not pay itself.

φ = 0 reduces **exactly** to the pre-Phase-7 contract. That is the null control every suite except
the gas one runs at, which is what makes "this is a strict extension" checked rather than hoped.

---

## 2. Do these three things, in this order

### Step 1 — TEACH THE REFERENCE ALLOCATOR THE PREMIUM. This is the biggest hole.

`QueueFixture._refAllocate` is the project's independent witness — written from `PLAN.md`'s prose,
not from `src/` — and it does **not** model the premium. So at φ > 0 the seat-by-seat composition
check `_check()` is unavailable, and **no test currently asserts the per-seat SPLIT against an
independent source.** `Premium.t.sol` works around it with quantities that do not need the witness
(PoolManager balances, INVARIANT F, the two independently-maintained totals, a live φ = 0 control
pool), and its two negative controls are real — but that is a weaker instrument than the witness and
you should not leave it that way.

The right shape, and it keeps the witness independent: the contract distributes LAZILY through an
accumulator; **make the witness distribute IMMEDIATELY and exactly, O(n) per swap, straight from the
spec.** Two completely different shapes for one rule cannot be wrong in the same way. They will
differ by rounding (the accumulator floors once at settle, the witness floors every swap), so either
bound that divergence and say so, or make the witness mirror the flooring and admit it is no longer
independent on that axis. **Do not widen a tolerance until it passes** (PITFALLS 5.53).

### Step 2 — RUN THE PREMIUM THROUGH THE INVARIANT CAMPAIGN AT φ > 0.

`test/queue/Invariant.t.sol` and `handlers/QueueHandler.sol` currently run at φ = 0, so the campaign
has never seen the premium. On this project the campaign found **three real bugs** in code that had
already passed 135 tests and 61 mutations. Add a φ > 0 subclass of the invariant suite. INVARIANT F
already carries the `premiumOwed` term it needs.

Specifically hunt: a seat settling across a foreclosure/demotion; `sweepFloatIntoPosition` while a
pot is held; `standing0/standing1` against `totals()` after long interleaved sequences (that is
`test_7_1`'s claim, but only over four swaps).

### Step 3 — THE BAND / TERM CONSTRUCTOR GUARD. Decided by the owner, not yet built.

The owner chose "constructor guard + deployment guide" over documentation alone. **It is not in the
code yet.** The rule that is actually calibrated against the measurements:

```
    half-width (ticks) × 1e-4  ≥  σ √T
```

where σ is the deployer's stated annualised volatility and T the stated term in years — because
expected exit time from a symmetric band is `a²/σ²`. Checks against what was measured: σ = 0.45,
T = 90 days → ≥ 2,235 ticks (≈ ±25%), and ±30% is exactly where the pool stops losing money at that
volatility. σ = 0.25, T = 90 days → ≥ 1,241 ticks, and ±10% at 25% vol was indeed viable.

Add `volatilityBps` and `termDays` as constructor parameters and enforce it. **The contract cannot
verify σ — it can only force the deployer to state it on-chain and keep the band consistent with it.**
Say exactly that in the comment; do not let it read as a viability guarantee.

**WARNING: the constructor is at eleven parameters and Solidity's ABI decoder ran out of stack at
twelve.** Two more parameters means you must convert the constructor to a **parameter struct** first.
Do that anyway — see §4.

---

## 3. What the product now is, and the numbers to quote

A seat is a claim on one Uniswap range plus a position in its fill order.

* **The head** trades first and most — high turnover, high adverse selection. A levered claim on the
  pool's own outcome. It keeps 15% of a very large fee stream.
* **The back** trades rarely and is paid a continuous coupon out of the front's fee income for
  standing behind it. **Vanilla Uniswap cannot sell this**: a range far from the price earns nothing
  until the price arrives, and nobody pays you ex-ante for depth they hope never to use.

Measured, φ = 8500, one head-only swap on an 8-seat book (`test_7_3`):

```
    head credit, phi = 0        220,870,896,257,107,547
    head credit, phi = 8500     220,376,980,583,426,340
    each standing seat's coupon      70,559,381,954,457   (x 7 seats = the pot, exactly)
```

**φ = 8,500 is measured, not chosen.** Swept across four independent seed ranges on a ±30% band over
a 25%-vol pair, φ ≈ 0.85 is the only setting that put 0 of 32 seats negative on **all four**, spread
10–15 points. Honest limits: on a 45%-vol pair the same φ leaves 0–4 seats negative depending on the
draw, and the best φ per configuration ranges 0.55–0.90. That is why φ is per-deployment.

### The costs, and none of them are hidden

```
    plain v4 pool                  69,970
    QUEUE, phi = 0                131,821    +88%
    QUEUE, phi = 8,500            162,766   +133%
```

Both sides measured in **steady state** — one swap through each pool in `setUp()` first. This
corrected a published number: **QUEUE's overhead was never the +48% this project claimed.** That
figure compared against a plain pool that had never traded, so the control was paying its own
one-time fee-growth writes. Routers rank by gas, and a pool that costs 2.3× a hookless one is a pool
some of them skip — that is real, it belongs in the pitch, and no allocator rule gives back skipped
flow.

Per-seat sweep cost went 9,945 → 14,777: exactly one cold storage slot for the accumulator mark, and
a slot is 5,000 gas whatever it holds. `BUDGET` moved 400k → 550k rather than `MAX_SEATS` moving,
because 32 is the 32 bytes of the packed `order` word.

---

## 4. Things that are true and that you should not re-derive

* **THE CONSTRUCTOR ARGUMENT LIST HAS BEEN HAND-COPIED THREE TIMES AND BROKE TWICE.**
  `QueueDeployBase._ctorArgs` used `abi.encode` — untyped — so a ten-argument payload against an
  eleven-argument constructor **compiled, deployed, and decoded φ out of the roster's tail bytes**.
  The pool came up with a garbage economic parameter and the only symptom was `test_7_5` reporting
  the demo's seller short by 2.4e15 wei. `Controls.t.sol` had the same duplication and it is deleted.
  **Give the constructor a parameter STRUCT before adding another argument.**
* **`seat()` reports the SETTLED value, `totals()` reports the RAW slot sum, and they are different
  numbers on purpose.** `withdraw` settles before it checks entitlement, so a view that reported the
  raw slot would promise a holder less than the contract pays them. The conservation identity needs
  the raw ledger plus the whole unsettled pot: `totals() + premiums().owed`.
* **`_syncSeat` must run before every write to a seat balance**, because the accumulator's weight IS
  the balance. There are six such sites in `src/` and a seventh in `QueueHarness.seed()`. M85 is the
  mutation that proves the ordering matters — it settles *after* the empty test and skips a seat
  holding nothing but an unsettled premium.
* **Both claims are weighted by the balances as they stood during the accrual, and neither sees the
  other.** Compounding them pays out more than was accrued; M86/N7 catch it. Note that
  **conservation cannot see this defect** — the wei move from `premiumOwed` into the seat, so the
  books tie out. What it steals is the other seats' unsettled claims, and it is only visible once
  the whole roster settles and the pot underflows.
* **A pot with nobody standing is HELD, not dropped** — and conservation cannot see a dropped pot
  either, because `premiumOwed` still counts it while it has become permanently unclaimable. M87
  survived the entire suite until `test_7_7` asserted the pot was actually held and actually paid.
* **`premiumHeld0` is a TOKEN0 pot and only a `zeroForOne` swap can fold it back in.** A reverse
  swap restores the book's standing inventory; it does not release that pot.
* **The accumulator is X64 in 128 bits, and the bound is `_accruePremium`'s `w < total` hold.** That
  guard is what makes a growth increment ≤ 2^64, which is what lets both marks share one slot, which
  is what keeps the per-seat cost to one slot instead of two. Unpacked it measured +52% on a
  head-only swap and pushed the supportable roster from 32 seats to 23.
* **Two of this session's own tests were blind when first written**, both caught by mutation:
  `test_7_8` compared `seat()` against `seat()` (which already includes the pending claim, so both
  sides moved together — PITFALLS 5.34's tautological witness), and the N7 control could not enter
  the branch it mutated because a `zeroForOne` swap only advances one accumulator.

---

## 5. Still outstanding

1. **The reference allocator does not model the premium** (Step 1). The per-seat split at φ > 0
   currently rests on `Premium.t.sol`'s controls rather than on the independent witness.
2. **The invariant campaign has never run at φ > 0** (Step 2).
3. **The band/term constructor guard is decided but unbuilt** (Step 3).
4. **Broadcast to Unichain Sepolia.** Needs a funded key. Fork-asserted already
   (`QUEUE_FORK=true forge test`). **There is no deployed address anywhere yet.**
5. **The video, under five minutes, human voice.** The opening shot is now the premium, not the fill
   price: drag the swap-size slider and watch the head's credit fall while every seat behind it is
   paid, live.
6. **`README.md` and `BUSINESS.md` still describe the pre-premium product** and still quote the +48%
   gas figure that this session showed was an artifact. They need rewriting around §3 above.
7. `recenter()` v2 remains unshipped and campaign-red (`docs/wip/recenter-v2/`).

---

## 6. Do not

* Do not re-open rotation without reading the banner on `ROTATION.md`. Its three headline numbers
  are refuted, with the counter-measurements written down.
* Do not trust a number from `docs/research/seat-economics/` that has been checked on only one seed
  range. That is how the last decision went wrong. The simulator reproduces `results-rotation.txt`
  byte-for-byte; that is repeatability, not robustness.
* Do not quote "+0.0000%" as evidence about the SPLIT. It is a conservation identity and a
  deliberately corrupt allocator scores the same.
* Do not add a `PREMIUM_BPS == 0` fast path to make the gas suite look better. It would make the code
  the suite measures a different path from the one the product ships; `Gas.t.sol` runs at the
  shipping φ for exactly that reason, with `PremiumOffGasTest` as its control.
* Do not add a seventh writer of a seat balance without routing it through `_syncSeat` first.
* Do not widen a tolerance to absorb a premium rounding difference. `test_7_2` compares the residual
  against a live φ = 0 control instead, and it reads 3 wei on both — which is what proves the
  residual is the pre-existing `_positionValue()` instrument and not the premium.
* Do not run `forge test`, `forge fmt` **or `git commit`** while `script/mutate.py` is running. The
  commit case is not hypothetical: it happened twice in one session, snapshotting a mutant into
  `src/` under a message saying "no production code changed" (PITFALLS 5.121). **Run
  `sh script/install-hooks.sh` once in your clone** — the pre-commit hook now refuses while the
  campaign marker is present. A mutant compiles and passes, so nothing else can catch it.
