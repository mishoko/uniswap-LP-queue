# Rotation — making every seat worth funding

> # ⛔ SUPERSEDED — NOT BUILT, AND NOT BECAUSE WE RAN OUT OF TIME
>
> **Status: REJECTED 2026-09-01, later the same day, on evidence.** An adversarial pass was
> commissioned against this document and **broke all three numbers the decision rested on.** What
> replaced it is the **priority premium** (`PREMIUM_BPS`, §B.13) — see `NEXT_SESSION_PROMPT.md`.
>
> **1. "0/32 seats negative" is SEED-SELECTED.** The guarantee was measured on `SEEDS = range(30)`
> and nowhere else. On the *shipping* configuration (±30% band, 45% vol), re-run on fresh seed
> ranges with the same code:
>
> ```
>     0-29 (headline)  pool +14.9%   worst  +2.8%   neg 0/32
>          100-129     pool  +8.3%   worst  -3.2%   neg 2/32
>          200-229     pool +23.9%   worst +11.2%   neg 0/32
>        1000-1029     pool  +5.4%   worst -10.2%   neg 6/32
> ```
>
> The pool is PROFITABLE in every row. "0/32 negative whenever the pool is profitable" — the
> sentence this whole document is sold on — is false.
>
> **2. "+0.0000%, now proven rather than argued" is a TAUTOLOGY.** `_fill` was replaced with a
> maximally corrupt allocator that credits 100% of every swap's input to the head, and it scored
> `vol diff +0.000000%, P&L diff +0.000000 pts` as well. Availability is identical for *every*
> allocator, so this measures conservation and is blind to any split. It is a valid one-line
> algebraic refutation of inventory-recycling and it is not evidence about ordering.
>
> **3. "No seat loses money" counts ENSEMBLE MEANS.** `seats()` averages across 30 seeds and then
> counts `(mean < 0)`. Per individual (path, seat) cell on the shipping configuration: **27% of
> outcomes lose money, and 25 of 30 futures contain at least one losing seat.** A seat holder lives
> one path.
>
> **Also wrong in this file:** the TOXIC lock table below is described as inverting so that "the
> longest lock is the worst position". Its own checked-in numbers say lock3 (−826.7%) is worse than
> lock4 (−781.6%). And every annualised figure linearly extrapolates a position that has already
> died — TOXIC's −602.9% is roughly a −6% realised loss multiplied by ~100.
>
> **The design objection, which is separate from the arithmetic.** Uniform rotation makes every seat
> earn the pro-rata return exactly. A seat is then an ordinary Uniswap LP position plus a lock, a
> 32-holder cap, rent, an unrollable band, and (measured since) **+133% gas**. It removes the only
> differentiated thing the product sells in order to fix the symptom that nothing was paying for the
> differentiation. Harberger becomes vestigial under it, and lock-weighting does not clear its own
> equilibrium — nobody funds the lowest tier, the mix collapses to uniform, and uniform reduces to
> pro-rata with extra steps.
>
> **What survives, and it is not nothing.** The diagnosis was right: under permanent rank most seats
> lose money and the product cannot ship that way. The band-width result is the most useful finding
> in this directory and is unaffected. `rank(i) = (i + epoch) mod N` remains the correct construction
> if a rotating schedule is ever wanted, including its refusal to use a builder-chosen block hash.
>
> Everything below is preserved as written. Read it as the record of a direction that was taken
> seriously and then refuted, not as instructions.

**Original status line: DECIDED (design), UNBUILT (code). 2026-09-01.** Simulated, not measured on a
live pool. Reproduce every table with `python3 report_rotation.py` (output checked in as
`results-rotation.txt`).

This supersedes the "two products, not 32" conclusion in `README.md` of this directory. That
conclusion was correct about the *diagnosis* and wrong about the *remedy*.

---

## The question

Under permanent rank, seats ~2–20 lose money under every market regime. A product where 28 of 32
positions are unbuyable is not a product. Can every position be made worth funding?

## The constraint, now proven rather than argued

Front-first ordering against ONE undivided pro-rata LP, same capital, same flow, same seeds:

```
  BENIGN  volume  queue $  24.5M  pro-rata $  24.5M   diff +0.0000%
  BENIGN  P&L     queue  +4.79%  pro-rata  +4.79%   diff +0.0000 pts
  NORMAL  volume  queue $  10.9M  pro-rata $  10.9M   diff +0.0000%
  NORMAL  P&L     queue  +0.55%  pro-rata  +0.55%   diff +0.0000 pts
```

**Zero to four decimal places, both regimes.** The queue serves exactly the same volume and earns
exactly the same total as an undivided position, because availability is identical — the cursor only
advances past *empty* seats, so the inventory reachable behind it never changes.

The inventory-recycling hypothesis (that front-first serves more volume per dollar because the head
is emptied and refilled by reversing flow) is therefore **dead**.

> **QUEUE redistributes one Uniswap position's return. It cannot create any.**
> So no ordering scheme makes all 32 seats beat a pro-rata LP. The best achievable is all 32 seats
> EQUAL to it — and that is exactly what rotation delivers.

## The fix: deterministic time-rotation of rank

```
rank(seat i) = (i + floor((block.timestamp - genesis) / EPOCH)) mod N
```

A pure function of time. **No stored rotation, no transaction, no keeper, no randomness, no oracle,
zero storage cost.** Over one full cycle every seat occupies every rank exactly once.

**Round-robin, not random, and this is not a preference.** On-chain randomness is a block hash; a
block hash is chosen by whoever builds the block; a head slot worth several hundred percent a year
is worth grinding for. A VRF is an external dependency and AGENTS.md §6 forbids adding one without
asking. Round-robin is unmanipulable, needs nothing, and is *fairer* than random — it equalises
exactly rather than in expectation.

### Measured, on the shipped ±10% band

```
  --- BENIGN  (pool +19.5%) ---
        scheme      worst       best    spread   seats<0
        STATIC     -20.5%    +911.8%     932.3     29/32
     rotate 1h     +14.0%     +27.4%      13.3      0/32
     rotate 4h     +11.4%     +29.8%      18.4      0/32
```

Spread collapses from 932 points to 13–18, and **no seat loses money**. Epoch length barely matters
between 1h and 4h.

### The constraint nobody had noticed

**The rotation cycle must complete inside the band's life.** At 24h epochs a 32-seat cycle takes 32
days; the ±10% band on a 45%-vol pair lives ~18. The cycle never completes, so rotation cannot
equalise. **Epochs must be hours, not days.** 4h gives a 5.3-day cycle.

## The band, not the queue, is what makes seats lose

The one result that reframes everything else:

```
      band    vol   exited      pool     worst      best   spread   seats<0
     +-10%   0.25    30/30    +19.5%    +11.4%    +29.8%     18.4      0/32
     +-10%   0.45    30/30    -18.6%    -47.8%    +23.6%     71.4     24/32
     +-30%   0.25    15/30    +32.8%    +30.2%    +36.9%      6.7      0/32
     +-30%   0.45    27/30    +14.9%     +2.8%    +27.7%     24.9      0/32
```

A ±10% band on a 45%-vol pair is a **losing LP position whatever the hook does**: it dies in ~18 days
and the terminal traversal is one lumpy loss that lands on whoever is at the front when it happens.
Rotation equalises the *flow*, and cannot equalise a single terminal event.

Widen the band to ±30% and the pool is profitable in both regimes, and **rotation delivers 0/32
losing seats with a 7–25 point spread.** `BAND_HALF_WIDTH` is already a constructor argument; the
shipped 960 ticks was sized for a demo. It is the dominant economic parameter, ahead of τ and ahead
of the allocator.

## The differentiator: lock-weighted priority

Uniform rotation makes every seat equal — which is the guarantee, but it also means the product
offers nothing a pro-rata pool does not. The extension that gives it a reason to exist:

> **Head-time share proportional to how long you COMMIT your capital.**

Shipping configuration (±30% band, 4h epochs, 8 seats at each of four lock lengths, 4:3:2:1):

```
  BENIGN  pool   +32.8%
     uniform      :   +30.2% ..   +36.9%    negative  0/32
     lock-weighted: lock4 +56.1%  lock3 +40.0%  lock2 +24.7%  lock1 +10.5%   negative  0/32
  NORMAL  pool   +14.9%
     uniform      :    +2.8% ..   +27.7%    negative  0/32
     lock-weighted: lock4 +31.5%  lock3 +23.8%  lock2  +8.1%  lock1  -3.8%   negative  6/32
```

A monotone duration curve. The tier mean equals the pool return in every row — **the split is still
conserved; only its AXIS changed**, from "which seat number you happened to buy" to "how long you
commit". Nobody is *assigned* a losing rank.

**What this prices that Uniswap cannot: how long you will stay.** Protocols today buy sticky
liquidity with token emissions, which dilute. QUEUE buys it with fill priority, which costs the
protocol nothing and is funded by the LPs who choose flexibility over commitment.

### The honest cost

**Front-time is leverage on the pool's own outcome.** The duration curve is monotone when the pool
makes money and *inverts* when it does not — in the toxic regime the longest lock is the worst
position. And lock-weighting re-introduces a below-average tier: `lock1` is −3.8% in the normal
regime, where uniform rotation had nobody negative. That is the price of differentiation, and it is
**chosen** rather than assigned.

## The decision

1. **Uniform rotation is the default and the guarantee**: 0/32 seats negative whenever the pool is
   profitable. Ship this.
2. **Lock-weighting is a dial**, with all-weights-equal reducing exactly to uniform. Opt-in
   differentiation, so the default keeps the guarantee.
3. **Band width is sized to the pair at deployment.** It matters more than everything above.

## What must be re-examined in the contract, not assumed

* **Cursors are RANKS.** If the rank→seat map rotates under them, INVARIANT C ("every seat at rank
  < cursorX holds aX == 0") breaks immediately and a cursor can LEAD a funded seat, which is silent
  theft of rank. Proposed fix: store `lastEpoch`, and on the first swap of a new epoch reset both
  cursors to 0 — a lagging cursor costs gas but never money. One SSTORE per epoch, not per swap.
  **UNVERIFIED.**
* **Rank derivation must compose with `order`**, which foreclosure still permutes: effective rank
  = `_idAt(order, (i + epoch) mod n)`. **UNVERIFIED.**
* **The lock must be enforced on EVERY path that moves capital or rank** — `withdraw`, `buySeat`
  (a Harberger buyout evacuates the seller's capital), `transfer` AND `transferFrom` separately,
  foreclosure, and any pending-withdrawal path. A rule implemented in one of two paired paths is
  this project's single most repeated bug (PITFALLS 5.37, 5.50, 5.52 twice, 5.105).
* **Does Harberger survive?** With rotation every seat has an identical schedule, so "the seats
  behind you" changes every epoch and rent looks like a wash over a cycle. But something must still
  force an IDLE seat to be reallocated, because an empty seat blocks one of 32 slots for free. The
  minimal mechanism for that is an open question.
* **Timestamp safety** on an OP-stack chain: how much sequencer drift is possible, and what does one
  epoch of drift buy a seat holder?

## What this does NOT establish

* No live-pool measurement. Flow is synthetic: Poisson retail with power-law sizes and a
  perfectly-informed single-shot arbitrageur.
* The lock-weighted tiers are simulated with an **assumed** 4:3:2:1 split. Nobody has modelled what
  mix of lock lengths a real market would choose, and the curve depends on that mix.
* Gas for rotation is estimated as one SSTORE per epoch. Not measured.
* The TOXIC regime is a losing pool in every configuration tested. Rotation does not fix a pool that
  should not exist.
