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
     │  33% of  │   │        │   │      │   │    │   │  │
     │  the book│   │        │   │      │   │    │   │  │
     └──────────┘   └────────┘   └──────┘   └────┘   └──┘
       filled by      reached      rarely     almost never
       ~96% of        by large     reached    reached
       all trades     trades

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

        At the SHIPPED c₁ = 1/3:
        ────────────────────────────────────────────────────────────
        ONE POINT the front gives up  buys the back  EXACTLY HALF A POINT.
        100% efficient. Zero leakage. Zero creation.
```

**Verified against simulation on the contract's real premium rule, all three regimes:**
closed form `+0.87 / +1.44 / +0.77 pp` against simulated `+0.87 / +1.47 / +0.73 pp`.

---

## 4. THE APPLICATION WE LEAD WITH — emissions-free liquidity incentives

### The problem, in business terms

* Protocols rent liquidity by **printing their own token** and handing it to LPs.
* That **dilutes existing holders**, creates **structural sell pressure**, and the capital **leaves
  the day emissions stop**.
* And the promise is a **governance decision** — it can be voted down, changed, or quietly reduced.

### What QUEUE offers instead

* The protocol posts **its own capital at the FRONT** and accepts the worse fills.
* External LPs fund the **BACK** and out-earn passive LPing.
* **Nothing is printed. Nobody is diluted. The protocol keeps its capital** — it simply earns less
  on it, on purpose.
* **It is not a promise.** It is the order the contract fills people in, executed inside `swap`.
  There is no payment step to withhold, no keeper to fund, no vote to reverse.

### The flow, with real dollars

```
   SETUP — the roster QueueDeployBase actually deploys
   ─────────────────────────────────────────────────────────────────────────
   $1,000,000 book · 5 seats · capital weights 5:4:3:2:1 · band ±10% · fee 0.30%

        PROTOCOL TREASURY            EXTERNAL LPs
             $333,333                   $666,667
           (c₁ = 1/3)              (ranks 2,3,4,5)
                │                         │
                ▼                         ▼
        ┌───────────────┐   ┌──────┬──────┬──────┬──────┐
        │    RANK 1     │──▶│ R2   │ R3   │ R4   │ R5   │
        │  first-loss   │   │$266k │$200k │$133k │ $67k │
        └───────────────┘   └──────┴──────┴──────┴──────┘


   OVER ONE 61-DAY BAND, BENIGN CONDITIONS (φ = 5,100, contract basis)
   ─────────────────────────────────────────────────────────────────────────
   A passive pro-rata LP on the same path returns              +5.02%

        RANK 1  realises  +3.28%   →  gives up  1.74 pp  →  −$5,800
        RANKS 2–5 realise +5.89%   →  gain      0.87 pp  →  +$5,800
                                                             ═══════
                                     net created                  $0
```

**The two figures are equal because they must be.** 1.74% of $333,333 and 0.87% of $666,667 are the
same $5,800. That is the identity in §3, in dollars.

### Annualised, and compared honestly against emissions

```
   61-day band → ~6 bands a year

   COST TO THE PROTOCOL      $5,800 × 6  =  ~$34,700/yr
                             on its own $333,333  =  10.4%/yr of its capital

   BENEFIT TO EXTERNAL LPs   +0.87 pp × 6  =  ~+5.2%/yr
                             on $666,667 of external TVL

   THE SAME BOOST VIA EMISSIONS would cost ~$34,700/yr of printed tokens.
   ─────────────────────────────────────────────────────────────────────────
   SO: QUEUE IS NOT CHEAPER. IT IS THE SAME DOLLAR NUMBER, PAID DIFFERENTLY.

     emissions            QUEUE
     ─────────            ─────
     dilutes holders      no dilution
     creates sell         no new supply
       pressure
     zero capital         requires ~$333k of REAL capital, locked in a
       required             fixed band
     reversible by a      mechanical — enforced in the fill order
       vote
     capital leaves       capital stays until the band is redeployed
       when it stops
```

**We are stating clearly:** the case for QUEUE over emissions is *not*
cost. It is **no dilution, no sell pressure, and the subsidy being an invariant rather than a
promise** — bought at the price of locking real treasury capital.

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

**Fixture, stated once and true of every row:** 5 seats, capital 5:4:3:2:1, $333,333 head
(c₁ = 1/3), $1,000,000 book, band ±10%, fee 0.30%, retail flow 15/hr, 4 disjoint seed ranges × 30 =
120 paths per cell, **φ = 5,100**, premium weighted by **contributed liquidity with the payers
excluded — the rule the contract implements**. Source: `docs/research/seat-economics/results-shipping-basis.txt`.

| regime | band life | passive LP | rank 1 | front gives up | ranks 2–5 gain | outcomes beating LP |
|---|---|---|---|---|---|---|
| **Benign** | 61.0 d | +5.02% | +3.28% | **−1.74 pp** | **+0.87 pp** | 68.1% |
| **Normal** | 19.1 d | +0.49% | −2.40% | **−2.89 pp** | **+1.47 pp** | 84.8% |
| **Toxic** | 1.4 d | −2.17% | −3.70% | **−1.53 pp** | **+0.73 pp** | 75.8% |

*"Outcomes beating LP" is the fraction of individual (path, seat) results in ranks 2–5 that beat a
pro-rata LP, at the φ = 5,000 grid point. **It is not 100%, and we do not say it is.***

### The premium rate, and how it was chosen

`PREMIUM_BPS` is the share of the fee the front seat hands backward. Two constraints, solved rather
than swept for a nice number:

```
   the BACK needs φ high enough to beat a passive LP        →  φ ≥ 4,542
   the FRONT needs φ low enough to still beat its own
     cheapest alternative (a keeper-managed ATM range)      →  φ ≤ 5,670
                                                               ────────────
   feasible window [4542, 5670]  ·  midpoint  ·  SHIPPED φ = 5,100
```

**The sensitivity that decides the product, and we state it ourselves:** hold the front to the
*passive-LP* bar instead of the managed-range bar and it falls below at 4,317 — under the 4,542 the
back needs — so **both windows are empty and no shipping constant exists**. The window is non-empty
only because re-anchoring is worth something to the front. What that costs to replicate is measured;
**what a buyer would pay for it is not, and no simulator can say.**

---

## 6B. WHAT EACH SEAT EARNS — the per-seat P&L, in dollars

**This is the table the whole product stands on.** Fixture stated once and true of every row: 5
seats, capital 5:4:3:2:1 on a $1,000,000 book, band ±10%, fee 0.30%, φ = 5,100, **BENIGN** regime,
61-day band. Source: `docs/research/seat-economics/results-shipping-basis.txt`. The benchmark is
**the same capital in an ordinary pro-rata Uniswap position on the same pair, band and path** —
"going elsewhere" — which returned **+5.02%** over that band.

```
  ┌────────┬───────────┬────────┬───────────┬───────────┬────────────┬──────────┐
  │  SEAT  │  CAPITAL  │  RATE  │ $ EARNED  │ $ AS A    │  DIFFERENCE│  BEATS   │
  │        │           │        │           │ PLAIN LP  │            │ PLAIN LP?│
  ├────────┼───────────┼────────┼───────────┼───────────┼────────────┼──────────┤
  │ RANK 1 │  $333,333 │ +3.28% │   $10,933 │   $16,733 │    -$5,800 │  NO — by │
  │        │           │        │           │           │            │  DESIGN  │
  ├────────┼───────────┼────────┼───────────┼───────────┼────────────┼──────────┤
  │ RANK 2 │  $266,667 │ +5.50% │   $14,667 │   $13,387 │    +$1,280 │   YES    │
  │ RANK 3 │  $200,000 │ +5.90% │   $11,800 │   $10,040 │    +$1,760 │   YES    │
  │ RANK 4 │  $133,333 │ +6.00% │    $8,000 │    $6,693 │    +$1,307 │   YES    │
  │ RANK 5 │   $66,667 │ +6.10% │    $4,067 │    $3,347 │      +$720 │   YES    │
  ├────────┼───────────┼────────┼───────────┼───────────┼────────────┼──────────┤
  │ TOTAL  │$1,000,000 │        │           │           │        ~$0 │          │
  └────────┴───────────┴────────┴───────────┴───────────┴────────────┴──────────┘
   The column sums to -$733 rather than to exactly $0 because the published per-seat
   rates are rounded to 0.1pp. The identity itself is exact: the capital-weighted mean
   IS the LP return, measured residual 2.98e-14. Do not read the -$733 as leakage.
```

### The same table annualised, and what a seat is actually worth

```
   ~6 benign bands a year
   ─────────────────────────────────────────────────────────────────────
     RANK 1   -$34,800/yr   =  -10.4%/yr  on its own capital
     RANK 2    +$7,680/yr   =   +2.9%/yr  ON TOP OF an ordinary LP
     RANK 3   +$10,560/yr   =   +5.3%/yr  ON TOP OF an ordinary LP
     RANK 4    +$7,840/yr   =   +5.9%/yr  ON TOP OF an ordinary LP
     RANK 5    +$4,320/yr   =   +6.5%/yr  ON TOP OF an ordinary LP
   ─────────────────────────────────────────────────────────────────────
   ▶ SO THE PITCH TO AN EXTERNAL LP IS: the same pair, the same band, the
     same fee tier, +2.9% to +6.5% a year MORE than the pool next door —
     paid by a named counterparty who volunteered, not by a token print.
```

**Annualisation assumes the band is redeployed when it dies.** `recenter()` is deliberately
unshipped (§7 of `PITFALLS`), so redeployment is manual today. We do **not** annualise the NORMAL
and TOXIC regimes: their bands die in 19 and 1.4 days, so multiplying them by 19 and 260 would
produce enormous numbers that assume a redeployment loop nobody has built.

### Are they motivated in every regime? Three of the four back seats, yes. One, no.

```
              BENIGN      NORMAL      TOXIC        BEATS A PLAIN LP IN…
   LP bar     +5.02%      +0.49%      -2.17%              —
   ────────────────────────────────────────────────────────────────────
   RANK 1     +3.28%      -2.40%      -3.70%        0 of 3   ON PURPOSE
   RANK 2     +5.50%      +1.50%      -2.50%        2 of 3   ◀ THE GAP
   RANK 3     +5.90%      +2.00%      -1.40%        3 of 3   ✓
   RANK 4     +6.00%      +2.20%      -0.40%        3 of 3   ✓
   RANK 5     +6.10%      +2.80%      +0.50%        3 of 3   ✓
   ────────────────────────────────────────────────────────────────────
   ▶ RANKS 3, 4 AND 5 BEAT AN ORDINARY UNISWAP LP IN EVERY REGIME WE
     MEASURED, INCLUDING THE TOXIC ONE — but READ THE NEXT BLOCK BEFORE
     QUOTING THAT, because in TOXIC it is not what it sounds like.
   ▶ RANK 2 MISSES IN TOXIC, BY 0.33 pp. It is the mezzanine: nearest the
     first-loss seat, so it is reached second by any move large enough to
     exhaust rank 1. We do not hide this and no premium rate fixes it —
     the coupon is skimmed from VOLUME, and a toxic band has almost none.
```

### ⚠ THE TOXIC ROW IS CAPITAL PRESERVATION, NOT YIELD — and the difference is the product

**Caught by our own instrument review, against our own headline.** In the TOXIC regime **rank 5 has
zero turnover on 100% of paths.** It does not out-earn the LP; **it is never filled at all.** An
unreached seat scores exactly `0.0000` while a plain LP is down 2.17%, so a naive reading of "beats
the LP in every regime" credits non-participation as outperformance. That is the seat-32 trap
`AGENTS.md` LAW 5 names, live in a number we were about to lead with.

```
   WHAT "RANK 5 BEATS THE LP IN TOXIC" ACTUALLY MEANS
   ─────────────────────────────────────────────────────────────────────
     a plain LP    is converted at bad prices all the way down   -2.17%
     rank 5        IS NEVER REACHED. Its inventory is untouched.  +0.50%
                            ▲
                            └── this is not a fee. It is the ABSENCE of
                                adverse selection, which is exactly what
                                the seats in front of it were there for.

   ▶ SAY IT THIS WAY INSTEAD, because it is both true and stronger:
     "In a crash the deep seats are not filled. Their capital keeps its
      composition while a plain LP's is converted at the worst prices of
      the move. That is what subordination BUYS, and it is the only
      regime where the mechanism pays out as protection rather than
      as yield."

   ▶ AND SAY THE COST OF IT: an unreached seat earns almost no fees
     either. In TOXIC the deep seats are idle capital that was spared,
     not capital that worked. In BENIGN they are filled and DO earn —
     rank 5 makes +6.10% against the LP's +5.02%.
```

**Rank 2's toxic miss is a genuine fill-based result** — it *is* reached in a crash, so its −2.50%
is money actually lost at bad prices, not a non-participation artefact. The binding constraint is
therefore real, and so is the fix for it (§6E).

**Per-seat, per-regime turnover shares are being reported alongside every return** in
`docs/research/seat-economics/results-headsize.txt` §5b, so no reader can mistake one for the other
again.

**And the caveat we put next to every mean:** at φ = 5,000 the fraction of *individual* (path, seat)
outcomes in ranks 2–5 that beat a plain LP is **68.1% benign, 84.8% normal, 75.8% toxic.** A seat
holder lives one path, not an ensemble. These are better odds than a plain LP position on the same
pair — but they are not certainty and we never present them as certainty.

---

## 6C. WHAT A SEAT COSTS, AND FOR HOW LONG YOU HAVE IT

Three separate numbers, and they are often confused. All are on-chain and visible before you buy.

```
   1. THE PRICE OF THE RANK  —  paid ONCE, to the incumbent
   ─────────────────────────────────────────────────────────────────────
      Whatever that seat's holder has posted as their own self-price.
      `buyPrice(seatId)` is the ask. You pay it to THEM.
      A never-priced seat asks ZERO — the founding roster starts there.

   2. YOUR CAPITAL  —  not a cost, you still own it
   ─────────────────────────────────────────────────────────────────────
      The seat changes hands EMPTY: the seller's capital is returned to
      the seller, to the wei. You then fund the seat yourself, or the
      seat drops to the tail for want of depth. Rank is BACKED BY DEPTH.

   3. RENT  —  paid CONTINUOUSLY, forward, to the seats ahead of you
   ─────────────────────────────────────────────────────────────────────
      tau = 10%/yr of YOUR OWN posted self-price. You set the number.
      Post a high price and you are safe but you pay for it; post a low
      one and you pay little but anyone may take the seat at it.
      That is Harberger, and it is the whole of it.

   THE TERM  —  7 days  (`MIN_TENURE`)
   ─────────────────────────────────────────────────────────────────────
      For 7 days after funding a seat you may NOT voluntarily give up
      its rank. You can still SELL it at your own posted price, in any
      block. It is a lock on the RANK, never on the capital.
```

### Why the rent runs FORWARD — the reversal, and what it does to the front seat's cost

Until this phase the rent ran **backward**, from the front to the back. That was written when being
first was believed to be the prize; Phases 7–8 disproved that and nobody revisited it, so the
contract was charging the seat that absorbs the losses and paying the seats it was already
subsidising. **The front SUPPLIES subordination and the back CONSUMES it, so the back pays the
front** — the same way round as every insurance market. Reversed, tested, and the old direction is
now the negative control (`Harberger.t.sol::test_4_9b`).

**This is how rank 1 monetises what it provides, and it answers the one question we previously said
no simulator could answer.**

```
   In a Harberger market a seat's posted price settles where the RENT
   equals the EXCESS RETURN the rank delivers — otherwise somebody takes it.
   So at tau = 10%/yr the equilibrium self-prices are:

      RANK 2   excess $7,680/yr   →  posts ~$76,800   →  pays $7,680/yr
      RANK 3   excess $10,560/yr  →  posts ~$105,600  →  pays $10,560/yr
      RANK 4   excess $7,840/yr   →  posts ~$78,400   →  pays $7,840/yr
      RANK 5   excess $4,320/yr   →  posts ~$43,200   →  pays $4,320/yr
                                                        ─────────────
                                        forward to rank 1  $30,400/yr

   ┌──────────────────────────────────────────────────────────────────┐
   │  RANK 1's GROSS SUBSIDY        -$34,800/yr   (-10.4% of capital) │
   │  RENT IT COLLECTS AT EQUILIB.  +$30,400/yr                       │
   │  ────────────────────────────────────────────────────────────────│
   │  NET COST OF RUNNING THE       -$4,400/yr    ( -1.3% of capital) │
   │  PROGRAMME                                                       │
   └──────────────────────────────────────────────────────────────────┘
```

**THE HONEST BOOKENDS, because the number above is an equilibrium and not a measurement:**

| how contested the seats are | rent that flows | rank 1's net cost |
|---|---|---|
| **nobody competes** — all self-prices stay at 0 | $0 | **−$34,800/yr (−10.4%)** |
| **fully contested** — Harberger equilibrium | ~$30,400/yr | **−$4,400/yr (−1.3%)** |

> The subsidy's true cost is **set by an on-chain market, continuously, not by us.** `BUSINESS.md`
> used to say *"we did not measure demand, and no simulator can."* That is still true of the
> simulator — and it is now beside the point, because **the seat market prices demand directly and
> the price is a public number.** That is what the Harberger layer is FOR, and until the reversal it
> was pointed the wrong way and priced nothing.

**Labelled honestly: the equilibrium prices above are DERIVED** — from the measured per-seat excess,
the identity in §3, and τ — **not simulated.** `sim.py` models no rent at all. The direction is
proven in the contract; the magnitude is arithmetic on top of measured returns.

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
   QUEUE, premium off                        141,036 gas   (+102%)
   QUEUE as shipped (φ = 5,100)              153,177 gas   (+119%)
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
