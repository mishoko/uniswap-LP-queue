# QUEUE — the business case

**Rewritten from scratch 2026-09-03 (Phase 11).** The previous version is preserved at
`archive/2026-09-03/BUSINESS-pre-phase-11.md`. It was not edited into this one, and that is
deliberate: it carried a Phase-9 correction banner over a Phase-4 body, and by the end its headline
numbers came from a roster the deploy script does not deploy, at a premium rate we do not ship, on a
premium *rule* the contract replaced in Phase 8. Correcting it in place would have left two live
answers in one file, which is exactly what this project's own conventions forbid.

**Every number below names the file, the fixture and the parameter block it came from.** Four
retractions on this project came from mixing fixtures; the rule now is that an unsourced number is
not quotable.

---

## 0. THE ONE-PARAGRAPH VERSION

> Uniswap fills every liquidity provider in a position **pro-rata** — every trade takes a little from
> everybody, in proportion. That is not a setting; it is the only thing the AMM does. **QUEUE gives
> each funder a rank and fills them in order.** The surprising part, which we measured and which is
> the entire product: **being first is bad.** The front seat absorbs the adverse selection first, at
> the earliest and worst prices of every move. So the front is a *first-loss position*, and everyone
> behind it does measurably better because it is there. That makes QUEUE the first mechanism where
> one LP inside a single Uniswap position can take structurally worse fills so another gets
> structurally better ones — **enforced by the contract, not promised by a vote.**

---

## 1. WHAT CHANGES, IN ONE PICTURE

```
   TODAY — every concentrated AMM, no exceptions
   ────────────────────────────────────────────────────────────────────────

     a trade arrives
          │
          ▼
     ┌─────────────────────────────────────────────────┐
     │  ONE POSITION — everybody is filled PRO-RATA     │
     │                                                  │
     │   LP A ▓▓▓▓▓▓   LP B ▓▓▓▓   LP C ▓▓   LP D ▓     │
     │        ↑ every trade takes a slice of each ↑     │
     └─────────────────────────────────────────────────┘

     You cannot opt out. You cannot go first. You cannot go last.
     There is exactly one fill quality and everybody gets it.


   WITH QUEUE — the same position, the same pool, the same router
   ────────────────────────────────────────────────────────────────────────

     a trade arrives
          │
          ▼
     ┌──────────┐   ┌────────┐   ┌──────┐   ┌────┐   ┌──┐
     │  RANK 1  │──▶│ RANK 2 │──▶│ RANK3│──▶│ R4 │──▶│R5│
     │  45% of  │   │  22%   │   │ 16.5%│   │11% │   │5%│
     │  the book│   │        │   │      │   │    │   │  │
     └──────────┘   └────────┘   └──────┘   └────┘   └──┘
      filled by       reached      reached    reached    reached on
      EVERY trade     on every     on 92%     on 26%     26% of paths
      (111 turns)     trade        of paths   of paths   (0.09 turns)

       ▲                                              ▲
       │                                              │
   WORST prices.                              BEST prices.
   Absorbs the adverse                        Fills only when the
   move first.                                move is already large.
```

**The trade is filled identically from the outside.** Same price, same 0.30% fee, any router. A
trader cannot see the queue and does not interact with it. What changed is *which LP inside the
position ate that trade*.

---

## 2. THE ONE CLAIM WE MAKE

> **QUEUE is subordination for Uniswap liquidity.**
> One LP inside a single position takes structurally worse fills so that another gets structurally
> better ones — and the ordering is enforced inside `swap`, not by a payment step somebody could
> withhold.

### What we never claim — each of these is disproven in our own repo

* ❌ **"LPs earn more here."** The capital-weighted average return **is** the passive-LP return, by
  identity. It is a transfer, and we say so first, not last.
* ❌ **"Priority is valuable to the person who holds it."** It is worth *negative* money. Our shipped
  front seat executes ~133 bps **worse** than the pro-rata position it displaces.
* ❌ **"A senior tranche with protected downside."** Measured downside-deviation ratio against a
  passive LP: 0.0–1.6×, and the tail is *worse*, not better.
* ❌ **Any per-seat number without naming its roster, its φ and its premium basis.** Three roster
  configurations and two premium rules are in play in the research directory.

---

## 3. WHERE THE VALUE IS — and where it is not

### It is not in creating money

The seats share **one** Uniswap position, so this is an identity, not a result:

```
        Σ (capital share of seat i) × (return of seat i)  ==  passive LP return
                                                   measured residual: 2.98e-14
```

One seat above the line requires another below it by exactly as much. **There is no configuration,
no ordering rule and no premium rate that changes this.** We tried; §7 lists the attempts and the
numbers that killed them.

### It is in *who* is above and below the line, and in that being mechanical

The exchange rate is a closed form. It needs no simulation and cannot be quoted against the wrong
fixture:

```
        back's excess over a passive LP  =  c₁ × (LP − r₁) / (1 − c₁)

        where c₁ = the front seat's capital share
              r₁ = the front seat's realised return
              LP = what a passive pro-rata LP made on the same path

        At the SHIPPED c₁ = 45%:   0.45 / 0.55  =  0.818
        ────────────────────────────────────────────────────────────
        ONE POINT the front gives up buys the back  0.82 OF A POINT.
        100% efficient. Zero leakage. Zero creation.

        The back gets LESS than a point because there is more capital
        behind the front than in it — the same dollars, spread wider.
        (At the old c₁ = 1/3 the ratio was exactly 0.5.)
```

**Verified against simulation on the contract's real premium rule, all three regimes** — and this is
an independent check, because the closed form knows nothing about the allocator:

```
                        BENIGN     NORMAL      TOXIC
   closed form          +2.65 pp   +2.26 pp   +1.11 pp
   simulated            +2.66 pp   +2.26 pp   +1.17 pp
```

---

## 4. THE APPLICATION WE LEAD WITH — emissions-free liquidity incentives

### The problem, in business terms

* Protocols rent liquidity by **printing their own token** and handing it to LPs.
* That **dilutes existing holders**, creates **structural sell pressure**, and the capital **leaves
  the day emissions stop**.
* And the promise is a **governance decision** — it can be voted down, changed, or quietly reduced.

### What QUEUE offers instead

* The protocol posts **its own capital at the FRONT** and accepts the worse fills.
* External LPs fund the **BACK**. They are filled last, so they trade LESS than a plain LP — and
  a coupon paid forward out of the front seat's fees more than compensates them for it. **They
  are not better LPs; they are LPs who are PAID to stand behind someone.** §6B proves this with
  a φ = 0 control in which they collapse.
* **Nothing is printed. Nobody is diluted. The protocol keeps its capital** — it simply earns less
  on it, on purpose.
* **It is not a promise.** It is the order the contract fills people in, executed inside `swap`.
  There is no payment step to withhold, no keeper to fund, no vote to reverse.

### The flow, with real dollars

```
   SETUP — the roster QueueDeployBase actually deploys
   ─────────────────────────────────────────────────────────────────────────
   $1,000,000 book · 5 seats · capital 90:44:33:22:11 · band ±10% · fee 0.30%

        PROTOCOL TREASURY            EXTERNAL LPs
             $450,000                   $550,000
            (c₁ = 45%)              (ranks 2,3,4,5)
                │                         │
                ▼                         ▼
        ┌───────────────┐   ┌──────┬──────┬──────┬──────┐
        │    RANK 1     │──▶│ R2   │ R3   │ R4   │ R5   │
        │  first-loss   │   │$220k │$165k │$110k │ $55k │
        └───────────────┘   └──────┴──────┴──────┴──────┘


   OVER ONE 61-DAY BAND, BENIGN CONDITIONS (φ = 5,500, contract basis)
   ─────────────────────────────────────────────────────────────────────────
   A passive pro-rata LP on the same path returns              +5.02%

        RANK 1  realises  +1.78%  →  gives up 3.24 pp  →  −$14,604
        RANKS 2-5 realise +7.68%  →  gain     2.66 pp  →  +$14,603
                                                          ═════════
                                     net created                 −$0
```

**The two figures are equal because they must be.** 3.24% of $450,000 and 2.66% of $550,000 are the
same $14,604. That is the identity in §3, in dollars.

### Annualised, and compared honestly against emissions

```
   61-day band → ~6 bands a year

   WHAT THE EXTERNAL LPs RECEIVE     +$87,624/yr on $550,000 of TVL
                                      = a +15.9% APR UPLIFT over the pool
                                        next door

   COST TO THE PROTOCOL, GROSS       −$87,624/yr, on its own $450,000
                                      = 19.5%/yr of its capital
   LESS RENT IT COLLECTS BACK        +$18,936/yr  (Harberger equilibrium,
                                      §6C — the back pays the front)
                                     ─────────────
   NET COST OF THE PROGRAMME         −$68,688/yr  = 15.3% of its capital


   BUYING THAT SAME +15.9% UPLIFT WITH EMISSIONS costs ~$87,624/yr of
   printed tokens.
   ─────────────────────────────────────────────────────────────────────────
   ▶ SO QUEUE IS ~22% CHEAPER IN CASH — and that is the SMALLER half of
     the argument. The bigger half is WHAT KIND of cost it is:

     emissions                      QUEUE
     ─────────                      ─────
     dilutes every holder           nobody is diluted
     permanent new sell pressure    no new supply, ever
     value is issued away and       the cost is OPPORTUNITY COST on capital
       never comes back               the treasury STILL OWNS
     zero capital required          requires ~$450k of REAL capital locked
                                      in a fixed band
     reversible by a vote           mechanical — enforced in the fill order
     capital leaves when it stops   capital stays until the band is redeployed
```

**Said plainly, because the older version of this section said the opposite:** QUEUE is now
*cheaper* than emissions as well as cleaner — but **only when the seats are contested.** If nobody
bids for a seat, no rent flows, and the sponsor pays the full $87,624/yr. §6C gives both bookends
and refuses to quote only the flattering one.

---

## 5. WHAT THE HOOK DEMONSTRATES, EXACTLY

The deploy sequence lives in `script/QueueDeployBase.sol` and is executed by **both** the broadcast
script and a test — including against a **fork of live Unichain Sepolia**. Five beats, each asserted:

```
  BEAT 1  FIVE FUNDED SEATS, IN FOUNDING ORDER
          ranking() == [0,1,2,3,4], every seat holds both tokens.
          ▶ proves: the roster exists and is ordered.

  BEAT 2  A SMALL SWAP FILLS THE HEAD AND NOBODY ELSE      ◀ THE HEADLINE
          seat 0's outgoing balance falls; seats 1-4 do not move AT ALL.
          ▶ proves: this is NOT pro-rata. No other AMM can do this.

  BEAT 3  A SWEEPING SWAP WALKS THE QUEUE IN RANK ORDER
          more than one seat moves, and no seat is touched while a seat
          ahead of it still holds stock (exhaustion is prefix-shaped).
          ▶ proves: the ORDER is real, not "some seats moved".

  BEAT 4  A TRANSFER MOVES RANK; CAPITAL GOES BACK TO THE SELLER
          seat changes hands EMPTY; seller made whole to the wei.
          ▶ proves: rank is a separable, tradeable object.

  BEAT 5  AN UNDER-PRICED SEAT IS TAKEN AT ITS OWNER'S OWN NUMBER
          holder posts an ask; a buyer pays it AND replaces the depth.
          ▶ proves: rank is Harberger-priced — you set your own price and
            anyone may take it there.
```

**What is genuinely new, stated precisely:** Uniswap already sells *distance from spot* — liquidity
near the price fills first and worst, liquidity far away fills rarely and best, and the tick
structure gives you that for free. **QUEUE is the first mechanism that orders LPs *inside one
position at one distance*.** That ordering is what makes contract-enforced subordination possible.

---

## 6. THE NUMBERS — shipped configuration only

**Fixture, stated once and true of every row:** 5 seats, capital **90 : 44 : 33 : 22 : 11** on a
$1,000,000 book (head $450,000, **c₁ = 45%**), band ±10%, fee 0.30%, retail flow 15/hr, 4 disjoint
seed ranges × 30 = 120 paths per cell, **φ = 5,500**, premium weighted by **contributed liquidity
with the payers excluded — the rule the contract implements**. Source:
`docs/research/seat-economics/results-shipped45.txt`.

| regime | band life | passive LP | rank 1 | front gives up | ranks 2–5 gain | worst back seat, t |
|---|---|---|---|---|---|---|
| **Benign** | 61.0 d | +5.02% | +1.78% | **−3.24 pp** | **+2.66 pp** | +8.2 |
| **Normal** | 19.1 d | +0.49% | −2.27% | **−2.76 pp** | **+2.26 pp** | +6.6 |
| **Toxic** | 1.4 d | −2.17% | −3.53% | **−1.36 pp** | **+1.17 pp** | +5.4 |

*The last column is the **paired** t-statistic of the worst-performing back seat against a plain
pro-rata LP in that regime — the queue run and the LP run share a seed and therefore a
bit-identical price path. **Every back seat clears in every regime, and the tightest margin is
still t = +5.4.** At the old 33.3% head the toxic column had no working φ at all.*

**But read §6B before quoting any of this.** The back seats' gain is a **coupon**, not better
trading: strip the premium and they fall 4.6–5.0 pp *below* a plain LP.

### The premium rate, and how it was chosen

`PREMIUM_BPS` (φ) is the share of the LP fee a **filled** seat hands **backward** to the seats it
did not reach. It was solved for, not swept for a nice number: two constraints have to hold at once
in **every** regime, and the shipped 5,500 is the midpoint of what survives.

```
   the BACK needs φ HIGH enough that every back seat beats a plain LP    →  φ ≥ 3,777
   the FRONT needs φ LOW enough that the sponsor still beats ITS OWN
     best alternative — a keeper-managed ATM range, gas itemised        →  φ ≤ 7,340
                                                                           ─────────────
   all-regime window [3777, 7340]  ·  midpoint  ·  SHIPPED φ = 5,500
```

**§6E has the full sweep, the head shares that produce no window at all, and — the part that
matters — why the 40% head was rejected even though its point estimate crosses.**

> **⚠ AND ONE CLAIM WE ARE WALKING BACK.** This document has said that five seats is *near the
> measured maximum*. The evidence for that sweeps the seat count while the head share collapses
> alongside it — two variables, one attribution — and head share is the dominant parameter. **That
> five seats is a CEILING is UNPROVEN**; the mechanism AT five is what is measured. `PITFALLS.md`
> §5.189, and `README.md` §5 states it in full.

**The sensitivity that decides the product, and we state it ourselves:** the upper bound exists only
because *re-anchoring is worth something to the front.* Hold the front to the **passive-LP** bar
instead of the managed-range bar and the ceiling collapses. What the managed alternative costs to
replicate is measured; **what a buyer would pay for the seat is not simulated at all — it is set by
the on-chain seat market, and §6C explains why that is a feature rather than a gap.**

---

## 6B. WHAT EACH SEAT EARNS — the per-seat P&L, in dollars

**This is the table the whole product stands on.** Fixture stated once and true of every row:
**5 seats, capital 90 : 44 : 33 : 22 : 11 on a $1,000,000 book** (so the head is $450,000 = **c₁ =
45%**), band ±10%, fee 0.30%, **φ = 5,500**, premium weighted on the basis the contract actually
implements (`liquidity_excl`), 120 paths per cell. Source:
`docs/research/seat-economics/results-shipped45.txt`. The benchmark is **the same capital in an
ordinary pro-rata Uniswap position on the same pair, band and price path** — "going elsewhere".

```
  BENIGN — a calm 61-day band. Passive pro-rata LP returns +5.02%.
  ┌──────┬───────────┬────────┬──────────┬──────────┬──────────┬───────┬────────┐
  │ SEAT │  CAPITAL  │ RETURN │ $ EARNED │ $ AS A   │DIFFERENCE│ TURNS │ FILLED │
  │      │           │        │          │ PLAIN LP │          │       │        │
  ├──────┼───────────┼────────┼──────────┼──────────┼──────────┼───────┼────────┤
  │RANK 1│  $450,000 │ +1.78% │  +$8,230 │ +$22,833 │ -$14,604 │111.57 │  100%  │
  ├──────┼───────────┼────────┼──────────┼──────────┼──────────┼───────┼────────┤
  │RANK 2│  $220,000 │ +7.29% │ +$16,187 │ +$11,163 │  +$5,024 │  2.22 │  100%  │
  │RANK 3│  $165,000 │ +7.97% │ +$13,238 │  +$8,372 │  +$4,866 │  1.52 │  100%  │
  │RANK 4│  $110,000 │ +7.84% │  +$8,671 │  +$5,582 │  +$3,089 │  0.80 │   92%  │
  │RANK 5│   $55,000 │ +7.99% │  +$4,415 │  +$2,791 │  +$1,624 │  0.09 │   26%  │
  ├──────┼───────────┼────────┼──────────┼──────────┼──────────┼───────┼────────┤
  │TOTAL │$1,000,000 │ +5.02% │ +$50,741 │ +$50,741 │      -$0 │       │        │
  └──────┴───────────┴────────┴──────────┴──────────┴──────────┴───────┴────────┘
   TURNS = how many times the seat's own capital was traded through.
   FILLED = the share of the 120 paths on which the seat was reached at all.
   ▶ READ THE RETURN AND THE TURNOVER TOGETHER, NEVER THE RETURN ALONE.
```

### ⚠ WHERE THE BACK SEATS' MONEY ACTUALLY COMES FROM — read this before quoting any row above

The rows above are true and they are **not** what a reader assumes. A seat's edge over a plain LP
splits **exactly** into two legs, as an identity rather than an inference:

```
        edge  =  ACTIVITY  +  COUPON

   ACTIVITY  what the seat earned by TRADING — its own fills and its own
             inventory markout — measured against the plain LP.
   COUPON    the premium φ handed BACKWARD to it by the seats in front
             that were filled and it was not.
```

```
  ACTIVITY LEG — what each seat earned by TRADING, coupon stripped out (pp vs LP)
  ─────────────────────────────────────────────────────────────────────────────
   regime        RANK 1     RANK 2     RANK 3     RANK 4     RANK 5
   BENIGN        -3.26      -5.21      -4.69      -5.00      -5.03
   NORMAL        -2.77      -1.10      -0.99      -0.74      -0.45
   TOXIC         -1.37      -0.07      +0.79      +1.61      +2.15
  ─────────────────────────────────────────────────────────────────────────────
   ▶ IN CALM AND NORMAL MARKETS EVERY BACK SEAT TRADES **WORSE** THAN A PLAIN
     LP. It is rarely filled, so it earns few fees. The coupon is the entire
     reason it comes out ahead.
   ▶ ONLY IN A CRASH do ranks 3-5 out-trade on their own leg — because the
     seats in front absorbed the bad fills. That is subordination paying out.
```

**The negative control that proves it, and it could have gone the other way.** Set φ = 0 so nothing
is handed backward, and the back seats collapse:

```
   BENIGN, φ = 0        passive LP  +5.02%
   ──────────────────────────────────────────────────────────
     RANK 2   +0.02%  ┐
     RANK 3   +0.44%  │  every one of them 4.6 – 5.0 pp BELOW
     RANK 4   +0.07%  │  the pool next door
     RANK 5   -0.00%  ┘
   ──────────────────────────────────────────────────────────
   ▶ THE BACK SEATS ARE NOT BETTER LPs. THEY ARE WORSE LPs WHO ARE PAID.
     That is the honest sentence, and it is also the product: the payment
     comes from a named counterparty who volunteered, not from a token print.
```

### The two things a seat actually is

```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  RANK 1 — WORKING CAPITAL                                               │
  │  111 turns · fees +7.54% · markout −5.77% · filled by 100% of paths     │
  │  High volume, high adverse selection. Held by the SPONSOR.              │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  RANK 5 — STANDBY CAPITAL                                               │
  │  0.09 turns · fees +0.01% · coupon +8.00% · idle on 74% of paths        │
  │  It is not trading. It holds capacity in reserve and is PAID for it.    │
  │  A standby facility, not a trading position.                            │
  └─────────────────────────────────────────────────────────────────────────┘
```

### All three regimes, and the verdict per seat

```
                BENIGN      NORMAL      TOXIC       BEATS A PLAIN LP IN…
   LP bar       +5.02%      +0.49%      -2.17%             —
   ──────────────────────────────────────────────────────────────────────
   RANK 1       +1.78%      -2.27%      -3.53%       0 of 3   ON PURPOSE
   RANK 2       +7.29%      +2.42%      -1.96%       3 of 3   ✓
   RANK 3       +7.97%      +2.67%      -1.04%       3 of 3   ✓
   RANK 4       +7.84%      +3.06%      -0.13%       3 of 3   ✓
   RANK 5       +7.99%      +3.57%      +0.60%       3 of 3   ✓
   ──────────────────────────────────────────────────────────────────────
   ▶ EVERY BACK SEAT NOW BEATS A PLAIN LP IN EVERY REGIME MEASURED, and the
     binding one (rank 2 in TOXIC) clears by +0.209pp against a paired
     standard error of 0.039pp — t = +5.4.
   ▶ AT THE OLD 33.3% HEAD THIS WAS FALSE: rank 2 lost in TOXIC and no φ
     fixed it. Closing that hole is what the 45% head was adopted for, and
     §6E prices what it cost.
```

**And the caveat we put next to every mean:** a seat holder lives **one path, not an ensemble.**
Rank 5 is *never reached at all* on 74% of benign paths — its return on those paths is pure coupon.
These are better odds than a plain LP position on the same pair, and they are not certainty; we
never present them as certainty.

### The mechanism is exactly zero-sum — in dollars, because a percentage hides it

```
   regime     RANK 1 vs LP    RANKS 2-5 vs LP        NET CREATED
   ──────────────────────────────────────────────────────────────
   BENIGN         -$14,604         +$14,603                 -$0
   NORMAL         -$12,434         +$12,432                 -$2
   TOXIC           -$6,434          +$6,425                 -$9
   ──────────────────────────────────────────────────────────────
   ▶ QUEUE DOES NOT CREATE RETURN. It moves return from the seat at the
     front to the seats behind it. The residual is undistributed premium
     still held at path end, not accounting slippage.
```

---

## 6C. WHAT A SEAT COSTS, AND FOR HOW LONG YOU HAVE IT

**A return quoted without its rent and its purchase price is not a return.** Every benefit claim in
this document carries five numbers, and this section defines them. All are on-chain and visible
before you buy.

```
   1. THE PRICE OF THE RANK  —  paid ONCE, to the incumbent
   ─────────────────────────────────────────────────────────────────────
      Whatever that seat's holder has posted as their own self-price.
      `buyPrice(seatId)` is the ask. You pay it to THEM, not to us.
      A never-priced seat asks ZERO — the founding roster starts there.

   2. YOUR CAPITAL  —  not a cost, you still own it
   ─────────────────────────────────────────────────────────────────────
      The seat changes hands EMPTY: the seller's capital is returned to
      the seller, to the wei. You then fund the seat yourself, or it
      drops to the tail for want of depth. RANK IS BACKED BY DEPTH.

   3. RENT  —  paid CONTINUOUSLY, FORWARD, to the seats ahead of you
   ─────────────────────────────────────────────────────────────────────
      τ = 10%/yr of YOUR OWN posted self-price. You set the number.
      Post high and you are safe but you pay for it; post low and you
      pay little but anyone may take the seat at it. That is Harberger.

   4. WHAT YOU RECEIVE IN RENT  —  from every seat BEHIND you
   ─────────────────────────────────────────────────────────────────────
      Each seat's rent is split over the seats AHEAD of it, weighted by
      the depth each of them contributed. Worked example below.

   THE TERM  —  7 days  (`MIN_TENURE`)
   ─────────────────────────────────────────────────────────────────────
      For 7 days after funding a seat you may NOT voluntarily give up its
      rank. You can still SELL it at your own posted price, in any block.
      IT IS A LOCK ON THE RANK, NEVER ON THE CAPITAL.
```

### THE RENT CASCADE, WITH AMOUNTS — who receives *how much*, from whom

`_distributeRent` pays the seats **ahead** of the payer, **weighted by contributed depth**. Worked
on the shipped weights, with demo self-prices that rise with rank because the deep seats are the
protected ones:

```
   ONE YEAR · SHIPPED ROSTER 90:44:33:22:11 · τ = 10%/yr
   ┌──────┬────────┬────────────┬──────────┬─────────────┬──────────┐
   │ RANK │ WEIGHT │ SELF-PRICE │ PAYS/yr  │ RECEIVES/yr │  NET/yr  │
   ├──────┼────────┼────────────┼──────────┼─────────────┼──────────┤
   │  1   │   90   │    100e18  │   10.00  │      85.52  │  +75.52  │
   │  2   │   44   │    200e18  │   20.00  │      32.03  │  +12.03  │
   │  3   │   33   │    300e18  │   30.00  │      16.63  │  -13.37  │
   │  4   │   22   │    400e18  │   40.00  │       5.82  │  -34.18  │
   │  5   │   11   │    500e18  │   50.00  │       0.00  │  -50.00  │
   └──────┴────────┴────────────┴──────────┴─────────────┴──────────┘
    HELD (rank 1 has nobody ahead, so its own rent has no recipient): 10.00
    CONSERVATION:  Σ(net) + held  =  0.000000  exactly

   HOW ONE ROW IS BUILT — rank 4 pays 40.00, split over ranks 1,2,3 by depth:
        rank 1 gets 40.00 × 90/(90+44+33) = 40.00 × 90/167 = 21.56
        rank 2 gets 40.00 × 44/167                         = 10.54
        rank 3 gets 40.00 × 33/167                         =  7.90
```

> **Read the direction carefully: the BACK pays the FRONT.** The front supplies subordination and
> the back consumes it, so the back pays for it — the same way round as every insurance market.
> Until Phase 12 this ran backward, charging the seat that absorbs the losses and paying the seats
> it was already subsidising. Reversed, tested, and the old direction is now the negative control
> (`Harberger.t.sol::test_4_9b`).

### WHAT A SEAT IS WORTH — and the pricing rule this document previously got wrong

```
   ✗ THE OLD RULE, and it was self-defeating:      value = excess ÷ τ
   ✓ THE CORRECT RULE:                             value = excess ÷ (τ + k)

     k is the buyer's cost of capital. A buyer does not only pay rent on
     the seat — they also want a RETURN on the money. At τ = 10% and a 24%
     cost of capital that is ÷ 0.34, NOT ÷ 0.10.
   ─────────────────────────────────────────────────────────────────────
   ▶ WHY THE OLD RULE WAS WRONG AND NOT MERELY IMPRECISE: dividing by τ
     alone sets the seat price so that rent EXACTLY equals the excess. The
     back seats then net ZERO and the sponsor pays ZERO — a degenerate
     equilibrium in which nobody gains anything and the product has no
     reason to exist. It overstated the fair ask by (τ+k)/τ = 3.4×, in our
     own favour, and the frontend had already corrected it.
```

### THE FIVE NUMBERS, PER SEAT — the honest bottom line

Benign regime, ~6 bands a year, at the Harberger equilibrium (`value = excess ÷ (τ+k)`):

```
  ┌──────┬──────────┬──────────┬──────────┬──────────┬──────────┬────────┐
  │ RANK │ CAPITAL  │ EARNS/yr │ RENT PAID│ RENT RECD│  NET/yr  │ ON ITS │
  │      │          │ (fees +  │  (τ × own│  (from   │          │ CAPITAL│
  │      │          │  premium)│self-price)│ behind) │          │        │
  ├──────┼──────────┼──────────┼──────────┼──────────┼──────────┼────────┤
  │  1   │ $450,000 │ -$87,624 │       -$0│ +$18,936 │ -$68,688 │ -15.3% │
  ├──────┼──────────┼──────────┼──────────┼──────────┼──────────┼────────┤
  │  2   │ $220,000 │ +$30,144 │  -$8,866 │  +$4,923 │ +$26,201 │ +11.9% │
  │  3   │ $165,000 │ +$29,196 │  -$8,587 │  +$1,578 │ +$22,187 │ +13.5% │
  │  4   │ $110,000 │ +$18,534 │  -$5,451 │    +$334 │ +$13,416 │ +12.2% │
  │  5   │  $55,000 │  +$9,744 │  -$2,866 │      +$0 │  +$6,878 │ +12.5% │
  └──────┴──────────┴──────────┴──────────┴──────────┴──────────┴────────┘
   "EARNS" is the measured edge OVER a plain LP, annualised at 6 benign
   bands. "ON ITS CAPITAL" is that edge net of rent, over the seat's own
   capital — i.e. HOW MUCH BETTER THAN THE POOL NEXT DOOR, after all costs.

   PLUS, for every back seat:
     THE RANK COST   paid once to the incumbent — at equilibrium
                     rank 2 $88,659 · rank 3 $85,871 · rank 4 $54,512
                     · rank 5 $28,659.  Rank 1 posts ZERO: its excess is
                     negative, so the seat is worth nothing to a buyer.
     THE TERM        7 days, on the RANK. The capital is never locked.
```

```
   ▶ THE IDENTITY THAT POLICES ALL OF IT:

        the sponsor's NET COST   ≡   the back seats' NET EXCESS
             -$68,688                      +$68,682
                        (differ by $6 on rounding)

     The Harberger rent CREATES NOTHING. It slides one quantity between
     the two sides of the same trade. Raising τ does not make the product
     better — it moves money from the LPs to the sponsor, and the LPs
     then require a lower seat price to compensate.
```

**THE HONEST BOOKENDS, because the table above is an equilibrium and not a measurement:**

| how contested the seats are | rent that flows | sponsor's net cost | LPs' net excess |
|---|---|---|---|
| **nobody competes** — all self-prices stay at 0 | $0 | **−$87,624/yr (−19.5%)** | **+$87,618/yr** |
| **fully contested** — Harberger equilibrium | ~$25,770/yr | **−$68,688/yr (−15.3%)** | **+$68,682/yr** |

> **Labelled honestly: the equilibrium prices are DERIVED**, from the measured per-seat excess in
> §6B, the identity in §3, τ, and an assumed 24% cost of capital — **not simulated.** `sim.py`
> models no rent at all. **The direction is proven in the contract; the magnitude is arithmetic on
> top of measured returns, and it moves with k.** What the seat market actually prices is a public
> on-chain number that no simulator has to guess.

---

## 6D. CAN A SEAT BE DROPPED THE MOMENT TOXIC FLOW ARRIVES? — the security answer

This is the question a subordinated instrument lives or dies on, and we found the hole ourselves.

```
   THE ATTACK, EXECUTED AGAINST THE REAL CONTRACT  (`test_8_20`)
   ─────────────────────────────────────────────────────────────────────
     a holder sees an adverse swap coming
              │
              ▼
     withdraw(seat, 1 wei)   ── costs ONE WEI ──▶  lands at the TAIL
              │                                    with its depth intact
              └──▶ AND PROMOTES THE SEAT BEHIND IT INTO THE RANK IT LEFT

     Our own numbers make that a strict UPGRADE in every regime:
     the tail beats rank 2 by +0.6pp benign, +1.3pp normal, +3.0pp toxic.

   ▶ Nobody had asked this. Four evacuation doors were found and closed by
     asking "can a holder DODGE a fill and KEEP its rank?" This is the
     opposite direction, and it was wide open.
```

**Three layers now answer it, and the third is new:**

```
   LAYER 1  ANY PAYOUT COSTS THE RANK.            (Phase 10)
            You cannot be subordinate and liquid at the same time.

   LAYER 2  THE SEAT YOU LAND ON IS UNDER-PRICED. (Harberger)
            You posted a number for the rank you LEFT. For FIRM_WINDOW
            you are takeable at it. Stepping aside costs you the seat,
            or costs you a higher price and the rent on it.

   LAYER 3  THE TERM — `MIN_TENURE` = 7 DAYS.     (NEW, this phase)
            Inside it, a withdrawal that would demote is REFUSED by
            name (`SeatWithinTerm`). The one-wei dodge is not on the
            menu at all, and neither is the atomic evacuation round
            trip that Phase 10 could only PRICE (`test_8_4` part A).
```

**What the term does NOT do, said by us rather than found by a reviewer:** it does not stop a holder
whose 7 days have elapsed from stepping aside. Nothing mechanical can — Phase 10 hit the same wall
and recorded it: *no rule can claw back a loss the attacker never took.* Layer 2 prices that case;
layer 3 closes the free one. **`test_8_4` asserts both halves so neither can be quoted alone.**

**And it is a lock on RANK, not on capital.** A locked holder is still sellable at their own posted
price, in any block, by anyone (`test_8_21`, claim 3). Posting a low price is how you leave in a
hurry, and what it costs you is exactly what the rank is worth — a number you set, not one we set.

---

## 6E. WHY 45% AND φ = 5,500 — the parameter decision, and what it cost

**These numbers were measured, not chosen.** Source:
`docs/research/seat-economics/results-headsize.txt`.

### What "the window" is

A single shipped φ has to work in every market it will meet, so the object that matters is the
**intersection** across all three regimes. A φ is inside the window when **both** of these hold:

```
   LOWER BOUND   every BACK seat beats a plain pro-rata LP.
                 Below this φ the coupon is too small and somebody in the
                 back is better off in the pool next door.

   UPPER BOUND   the FRONT seat still beats ITS OWN best alternative — a
                 keeper-managed at-the-money range holding the same capital,
                 with L2 gas and re-mint costs itemised. Above this φ the
                 sponsor should just run that instead.
   ─────────────────────────────────────────────────────────────────────────
   ▶ Note what the upper bound is NOT: it is not "the front beats a passive
     LP". The front is a sponsor with a real alternative use for the money,
     and that alternative is the honest bar.
```

### The efficiency table

```
    c₁     BENIGN         NORMAL          TOXIC        ALL-REGIME      verdict
   ─────────────────────────────────────────────────────────────────────────────────
   33.3% [4542,5670]  [2560,6251]        EMPTY           EMPTY      rank 2 never
                                                                    clears in TOXIC
   35.0% [4432,5824]  [2441,6734]        EMPTY           EMPTY      same
   37.5% [4280,6104]  [2259,7535]        EMPTY           EMPTY      the front falls
                                                                    below its own
                                                                    alternative
   40.0% [4122,6447]  [2128,8444]   [5668,8628]     [5668, 6447]    t = +0.3
                                                                    ✗ COIN FLIP
   45.0% [3777,7340] [1740,9500+]    [0,9500+]      [3777, 7340]    t = +5.4
                                                                    ◀ SHIPPED
   66.7% [2189,9500+] [929,9500+]    [0,9500+]      [2189, 9500+]   sponsor posts
                                                                    2/3 of the book
   ─────────────────────────────────────────────────────────────────────────────────
   SHIPPED φ = 5,500 is the midpoint of [3777, 7340].
```

### Why 40% was rejected, and this is the part that matters

```
   40% has a non-empty window on the POINT ESTIMATE. It was still rejected.

     at c₁ = 40%, φ = 6000, TOXIC, binding seat (rank 2):
         gap to the plain LP      +0.010 pp
         paired standard error     0.032 pp
         t                         +0.3      ← a COIN FLIP
     at c₁ = 45%, φ = 5500, TOXIC, binding seat (rank 2):
         gap to the plain LP      +0.209 pp
         paired standard error     0.039 pp
         t                         +5.4      ← CLEARS
   ─────────────────────────────────────────────────────────────────────
   ▶ A window whose binding seat clears by LESS THAN ITS OWN STANDARD
     ERROR is a window on a coin flip. Shipping the smallest head share
     whose point estimate happens to cross zero is exactly the
     green-number-chasing this project calls its first sin.
   ▶ SO THE SMALLEST **DEFENSIBLE** HEAD SHARE IS 45%, NOT THE 40% THE
     POINT ESTIMATE GIVES.
```

### WHAT THE 45% HEAD COST THE SPONSOR — stated because it is a real cost

Moving the head from 33.3% to 45% closed the toxic hole. It also made the sponsor's seat
substantially more expensive, because a bigger head absorbs more of every adverse move:

```
                              c₁ = 33.3%        c₁ = 45%
   ─────────────────────────────────────────────────────────────────────
   sponsor's capital            $333,333        $450,000
   gross subsidy / yr           ~$34,700        ~$87,624
   as % of its OWN capital         10.4%           19.5%
   every back seat beats a
     plain LP in every regime          NO             YES
   ─────────────────────────────────────────────────────────────────────
   ▶ THE TRADE, PLAINLY: the sponsor pays roughly TWICE as much, per
     dollar of its own capital, to buy a programme that still holds in a
     crash. We think that is the right trade — a subordination promise
     that fails in exactly the conditions it was bought for is not worth
     running — but it is the sponsor's money and the sponsor's call, and
     the number belongs on the page rather than in a footnote.
```

---

## 7. WHAT WE KILLED — five theses, pre-registered criteria, our own numbers

| the thesis | what killed it |
|---|---|
| ~~Every seat beats a passive LP~~ | **Impossible by identity.** `Σ cᵢrᵢ = LP` to 2.98e-14, invariant to φ. |
| ~~An ordering rule that creates value~~ | The distributable surplus `c₁(LP − B₁)` is **independent of the ordering rule**. Reordering moves the pie; it cannot grow it. |
| ~~Priority is worth money to its holder~~ | **Negative, and monotone in how much you hold.** A plain pro-rata range order already beats trading as a taker; adding priority takes you the other way. Our shipped front seat costs **133 bps** against the position it displaces. |
| ~~A senior tranche with a protected tail~~ | Bar set in advance at one-to-two orders of magnitude. Measured **0.0–1.6×**, and the tail is *worse*: −6.49% for the back against −6.43% for the LP. |
| ~~A two-ended book~~ | Killed by a control that **could have confirmed it**: a real mechanism gain survives a mirrored drift, a direction bet flips. It flipped — `+4.487 pp` (t = +61.96) against `−1.277 pp` (t = −20.10). |

**How to use this in a pitch: one line, not a section.** *"We pre-registered kill criteria for five
business theses and killed all five; the write-ups are in the repo with the numbers that killed
them."* Then move on. Spending a third of the runtime on what does not work reads as a post-mortem,
not as rigour.

---

## 8. WHAT IT COSTS

### To the trader

```
   plain v4 pool, same tokens/fee/price       69,970 gas
   QUEUE, premium off                        140,969 gas   (+101%)
   QUEUE as shipped (φ = 5,500)              153,110 gas   (+119%)
```

* **+119% network compute on a typical swap.** On an L2 this is cents; on mainnet it is a real bill.
  **QUEUE is an L2 product.**
* No fee change. No worse price. The trader gets exactly what the pool would have given them.
* Aggregators may route around the pool for the gas alone. That is a real commercial risk and it is
  not hypothetical.
* The premium's gas cost is the **machinery, not the rate**: moving φ by 2,800 bps moved this by 230
  gas.

### To the protocol running the programme

* **Real capital, locked.** ~$333k in a fixed band that cannot be re-centred without withdrawing and
  redeploying.
* **~10.4%/yr of that capital**, in benign conditions, handed to the seats behind it.
* **Rent on its own posted seat price** — see §9, which is not optional.
* **Uncapped, and set by the market rather than by a budget.** The subsidy is largest in exactly the
  conditions where the treasury can least afford it.

---

## 9. THE OPERATIONAL REQUIREMENT NOBODY WOULD GUESS

**The subsidiser must price its seat in the same transaction that funds it.** This is proven, not
argued (`test_4_44`).

```
   A never-priced seat quotes ZERO and is free to take.
   (Deliberate — the contract calls it the bootstrap, and for a roster meant
    to change hands it is correct. For a protocol holding the front for MONTHS
    it is fatal.)

   ANY STRANGER CALLS  buySeat(frontSeat, 0, 0)
        │
        ├─▶ pays NOTHING                          (both currencies unchanged)
        ├─▶ the protocol's capital is EVACUATED out of the position
        ├─▶ the pool's depth drops in the same transaction
        ├─▶ the emptied seat is demoted to the TAIL
        │
        ▼
   AND THE SEAT THAT WAS SECOND IS NOW FIRST.

   By  Σ cᵢrᵢ = LP  somebody must sit below the line — so the external LP who
   bought a SUBORDINATED BACK SEAT has been moved into the FIRST-LOSS position,
   by a stranger, for the price of gas.
```

**Remedy, and it is operational rather than a code change:** post a self-price on the subsidiser's
seat in the funding transaction, and pay Harberger rent on it thereafter. That rent is a **real
running cost of the programme** and belongs in the pitch rather than in whoever deploys it.

---

## 10. HONEST LIMITATIONS — we state these before anyone asks

1. **It is a transfer, not creation.** The capital-weighted average *is* the passive-LP return.
2. **Simulation only.** No live-pool data. 120 paths per cell, four disjoint seed ranges, one pair,
   one band width.
3. **The subsidiser must post real capital**, roughly comparable to what it subsidises. This is not
   leverage on a marketing budget.
4. **+119% gas for every trader** on the pool.
5. **In toxic conditions there is no premium rate that works.** Seat 2 never clears a passive LP at
   any φ, so the feasible window is **empty**. A toxic band also dies in ~1.4 days against ~61
   benign, so it is a small share of the calendar — but the honest statement is that the mechanism
   has a regime in which it does not deliver.
6. **The front seat is a bad investment, and we say so on camera.** That is the design: somebody has
   to volunteer, and the volunteer is the protocol, not a yield-seeker.
7. **We did not measure demand, and no simulator can.** If no protocol has a reason to volunteer for
   the front seat, this is an ordinary Uniswap position with extra steps.
8. **The roster is closed at deployment.** There is no `mint` — capital joins by funding an existing
   seat or buying one.
9. **A holder cannot be subordinate and liquid at the same time.** Any withdrawal costs the rank.
   That is enforced deliberately, and it is what makes a naive ERC-4626 wrapper unsafe (§11).

---

## 11. ADJACENT IDEAS — designed, NOT built, and we label them that way

**A pooled wrapper so ordinary LPs can hold a back seat.** The obvious version is an ERC-4626 vault
on a middle seat. **It does not work, and the reason is worth saying out loud because it shows we
understood our own mechanism:**

```
   withdraw() demotes the rank on ANY payout, of ANY size.
        │
        ▼
   redeem() must call withdraw()
        │
        ▼
   ONE DUST REDEEMER permanently destroys the rank the whole vault's
   value rests on — and NOTHING ever promotes a seat back.
        │
        ▼
   Worse: anyone holding a seat BEHIND the vault is PAID to do it.
   No lockup or fee closes this. Every exit ends in a withdraw().
```

**The shape that does work:** an **async-redeem (ERC-7540) vault on the TAIL seat**, where demotion
is a no-op and the tail is the *recipient* of the subordination payment. Shares must track
contributed liquidity rather than a token-denominated NAV, and single-token deposits must be
refused. **Unbuilt. Reasoned from source, not measured.**

**Priority among takers, rather than among LPs.** The machinery that works — a transferable,
Harberger-priced, rank-ordered claim with exact conservation — is a priority auction. Priority among
*LPs* is worth negative money; the right to trade *first against the pool in a block* is not, and
that value currently leaks to searchers rather than to LPs. **Different product, crowded field, a
rewrite of the allocator. Named because it is the only direction consistent with everything this
repo has proven.**

---

## 12. WHY THIS EARNS RESPECT RATHER THAN RIDICULE

* The Uniswap Foundation funds research concluding LPs lose money. **This audience rewards
  measurement over optimism.**
* We tried to kill our own value proposition with pre-registered criteria and **succeeded five
  times**. The one claim that survived is measured, sourced and caveated.
* We found and published the defects in **our own instruments**: the evidence file for our headline
  result was committed empty; every published rate figure measured a rule the contract had replaced;
  three separate copies of the shipped premium had drifted apart. All fixed, all recorded.
* **"We found nothing" is not the same sentence as "we killed four theses and one survived."** Only
  the second one is true, and only it should be said.

---

## 13. VERIFICATION — what is actually proven

| | |
|---|---|
| **316** | tests passing, 0 failing, 1 skipped — against **real v4 contracts**, nothing mocked |
| **85 / 85** | mutations RED, zero survivors. A bad pattern or a no-compile counts as **unrun**, never as a pass |
| **16,384** | randomised calls per invariant, plus a deterministic scripted campaign with coverage floors |
| **4** | evacuation exploits found against our own mechanism and closed at the root |
| **2** | independent premium-basis sweeps, each with a φ = 0 control that must be — and is — exact |

* Conservation is measured on **PoolManager's own balances net of protocol fees**, never on the
  hook's own bookkeeping.
* Every negative control asserts the **exact revert reason** — a control that fails for an unrelated
  reason proves nothing.
* Gas is measured with **cold storage and state built in `setUp()`**, because a warm slot reads 47%
  optimistic.
* **This is not an audit.**

---

## 14. THE NINETY-SECOND VERSION, FOR SOMEONE WHO CONTROLS A BUDGET

> Protocols pay for liquidity by printing tokens. It dilutes your holders, it creates permanent sell
> pressure, and the money leaves the day you stop.
>
> Uniswap fills every LP in a position identically — pro-rata. QUEUE puts them in a line instead and
> fills them in order. **Being first is bad**: you absorb every adverse move first, at the worst
> prices. We measured exactly how bad.
>
> So you stand at the front with your own capital and take the worse fills, and every LP behind you
> does better because you are there. **You print nothing, you dilute nobody, and you keep your
> capital — you just earn less on it, on purpose. And it is not a promise anyone can vote away: it
> is the order the contract fills people in.**
>
> On our shipped configuration, one point you give up buys the people behind you exactly half a
> point. It is a transfer, not free money, and we will show you the algebra. It costs every trader
> 119% more gas, so this belongs on an L2. In toxic markets there is no setting that works. And the
> front seat is a bad investment — which is the point, because the volunteer is you, not a
> yield-seeker.

---

## APPENDIX — where the numbers live

| claim | file |
|---|---|
| the shipped economics, contract premium basis | `docs/research/seat-economics/results-shipping-basis.txt` |
| the superseded basis, kept for the diff | `docs/research/seat-economics/results-shipping.txt` |
| the two-ended book, killed | `docs/research/seat-economics/results-book.txt` |
| the tranche thesis, killed | `docs/research/seat-economics/results-tranche.txt` ⚠ **stale basis** |
| execution price by rank | `docs/research/seat-economics/results-exec.txt` ⚠ **stale basis** |
| roster size / depth | `docs/research/seat-economics/results-depth-basis.txt` |
| gas | `test/queue/Gas.t.sol` |
| the demo, beat by beat | `script/QueueDeployBase.sol`, `test/queue/Deploy.t.sol` |
| every trap, hazard and settled decision | `PITFALLS.md` |

⚠ **`results-tranche.txt` and `results-exec.txt` have NOT been re-run on the contract's premium
basis. No per-seat number from either is quotable until they are.** The theses they killed stand —
those rest on identities and on sign tests that no weighting changes — but their magnitudes do not.
