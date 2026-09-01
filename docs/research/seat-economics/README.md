# Seat economics — is there a buyer for seat 5, 15, 30?

**Status: ANALYSIS (simulated). 2026-09-01.** Not a measurement of a live pool; there is no live
pool. Read `BUSINESS.md` §0.5 for the conclusions in decision form — this directory is the working.

Reproduce:

```bash
cd docs/research/seat-economics
python3 report_seats.py    > results-seats.txt     # per-seat return by regime, average vs marginal
python3 report_sizing.py   > results-sizing.txt    # does sizing the head remove the trap?
```

---

## Why this exists

The project could describe what the head earns and could not answer, with a number, why anyone
would buy seat 15. The prior attempt at that answer (`BUSINESS.md` §0.5, superseded) used a model
with **no inventory and no cursors**: it let the head refill for free on every trade. That is not
what the contract does — `_allocate` empties a seat, advances a cursor past it, and does not touch
it again until the flow reverses — and the error ran in the head's favour on every trade.

`sim.py` reproduces the mechanism as executed: one constant-liquidity v3 band with `L` minted once
and held fixed, seats holding `(a0, a1)`, the outgoing token drained front-first from a cursor,
both pricing rules (`marginal=True|False`), retail noise and a closed-form single-shot arbitrage
back to the no-arb edge, and termination when the price leaves the fixed band. P&L is
mark-to-market against buy-and-hold of the same opening inventory — no decomposition into "fees"
and "markout", just the money.

Two modelling choices are worth naming because both were wrong in a first draft and both changed
the answer:

* **The arbitrageur trades ONCE, not in slices.** An early version stepped the arb back to the true
  price in $2,000 slices. That erases the only thing that distinguishes the front of the book from
  the back — a large trade's price impact — and made marginal and average pricing indistinguishable.
* **The price walk is not clamped inside the band.** Clamping it produced a pool with almost no
  LVR, where a pro-rata LP earned +62%/yr and every regime looked benign.

---

## What it found

### 1. Average pricing was a free lane for the head

```
                                    BENIGN      NORMAL       TOXIC
  ordinary pro-rata LP              +21.2%      -31.8%     -752.6%
  seat 1, AVERAGE pricing          +934.0%     +675.3%     -439.9%    beats an LP in ALL THREE
  seat 1, MARGINAL pricing         +911.0%     +566.1%     -796.2%    loses in the toxic regime
```

The head took all of the volume *and* the same price as the seats behind it, so it beat an ordinary
LP in every state of the world including the one designed to punish whoever is first into a stale
price. **This is the finding that justified changing the allocator**, and it is a mechanism-design
argument, not a tuning preference: AGENTS.md §5 names the "free lane" as the failure that has killed
seven mechanisms here.

Marginal pricing credits each seat the price segment it actually absorbed. The head is filled
first, so it eats the stalest prices, and being first becomes a trade-off. Total return is
unchanged to the wei — this moved value, it did not create any.

### 2. The middle of the book loses under every condition, and marginal pricing does not save it

32 equal seats, %/yr while in band, marginal pricing, 60 paths:

```
                BENIGN     NORMAL      TOXIC
  ordinary LP   +21.2%     -31.8%    -752.6%
  seat 1       +911.0%    +566.1%    -796.2%
  seat 5         -8.3%     -76.8%   -1267.1%
  seat 10       -12.9%     -79.9%   -1123.0%
  seat 20        -9.3%     -49.1%    -659.9%
  seat 32        +0.0%      +0.0%      -2.3%
```

Seats 5–20 are reached often enough to absorb the large toxic trades and not often enough to earn
the small profitable ones. Marginal pricing *improves* them and they remain negative.

### 3. The deep tail is not "paid to wait" — it is untouched

Seat 32's ~0% is not a coupon. It is the return of capital the flow never reached; its P&L is the
P&L of holding the tokens. That is still a **win in the pools QUEUE is for**, because the benchmark
there is an LP returning −31.8%. It is a bond-like claim, and it should be sold as one.

### 4. The tail's only real income is rent, and τ = 10% is too low

θ = τ/(τ+k) of the head's advantage flows backward. With the head's advantage at $186,852/yr and a
$968,750 tail:

```
    tau     theta     rent/yr    TAIL COUPON
    10%      33%       62,284        6.4%      <-- what script/QueueDeployBase.sol ships
    25%      56%      103,807       10.7%
    50%      71%      133,466       13.8%
```

### 5. Sizing the head compresses the trap but cannot remove it

```
  NORMAL regime            pro-rata    head     worst of seats 2-21   seats >= LP
  32 equal   ($31k each)     -31.8%   +566.1%        -109.6%              10/32
  head $300k + 31 x $22.6k   -31.8%    -12.1%         -82.6%              13/32
  head $600k + 31 x $12.9k   -31.8%    -38.4%         -49.9%              21/32
```

A bigger head halves the middle's loss and doubles the number of seats that beat an LP — and
collapses the head from +566% to −38%. **They are the same money.** In the benign regime only ONE
seat beats an ordinary LP under every sizing tested.

---

## The conclusion the numbers force

**QUEUE redistributes one Uniswap position's return; it does not create return.** Against its own
pro-rata benchmark the book is zero-sum, so there is no configuration in which all 32 seats beat an
ordinary LP, and there cannot be one.

What survives is **two products, not 32**: an equity-like head and a bond-like tail, with the
middle left unfunded. Seat capital is chosen by holders, so the contract already supports this and
no code change follows from it — but the pitch must say it, and the demo's default of 32 equal
seats is the configuration that manufactures the trap.

## What this does NOT establish

* No live-pool measurement. Flow is synthetic: Poisson retail with power-law sizes and a
  perfectly-informed single-shot arbitrageur. A real pool's flow is neither.
* The Harberger equilibrium is **assumed**, not simulated: `P* = A/(τ+k)` with `k = 20%/yr` taken as
  given. Nobody has simulated seat holders bidding against each other, and the self-price the market
  would actually discover could be far from `A/(τ+k)`.
* Gas is ignored entirely. At the head's turnover it is not material; for a marginal deep seat
  collecting a 6.4% coupon it may well be.
