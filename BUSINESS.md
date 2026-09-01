# QUEUE — the business case

A decision memo for people who will fund, deploy, or reject this. You do not need to know DeFi. You do need to know what you are actually buying.

The 15-minute version is [`README.md`](README.md). This file is the numbers, the "when," the fears, and the claims that survive contact with a skeptic.

Every number carries a tag:

| Tag | Meaning |
|---|---|
| **[MEASURED]** | Produced by executing code. Source named. |
| **[COUNTED]** | A query run against `archive/2026-08-26/docs/research/data/hook_directory_662.json` (662 rows). The query is printed so it can be re-run. |
| **[SOURCED]** | Quoted from a primary document that was actually fetched and read. |
| **[ESTIMATE]** | A worked example. Assumptions stated inline. Not a measurement and not a projection. |
| **[ANALYSIS]** | Reasoning, not measurement. Flagged wherever it appears. |

Nothing in this document is a revenue, TVL, or adoption forecast. There is no basis for one and none is offered.

---

## 0. THE VERDICT A DECISION-MAKER CAN ACT ON

**What you are buying:** a 32-desk paid counter around today's price, plus ordinary Uniswap liquidity anyone can add further out with Uniswap's own tools. Cash providers at the counter buy and sell *place in line*. The customer still trades through ordinary Uniswap, at the ordinary price, at the ordinary trading fee. The hook does not replace Uniswap's curve. It orders the people who are already at that price, and it gets out of the way everywhere else.

**What you are not buying:** sandwich protection, lower LP losses in total, cheaper execution, or a better deal for the shopper. The shopper pays ~48% extra network compute and gets the same trade. The **desks** are the customer of this product.

| If you wanted… | You got… | Decision |
|---|---|---|
| Anyone with $50 can LP | 32 paid seats, always for sale | **Reject.** Ordinary Uniswap. |
| Stop sandwiches / MEV | Unchanged. Same prices, same attacks. | **Reject.** Different product. |
| LPs lose less overall | Total pool P&L identical to the cent [ESTIMATE, §7]. Redistribution, not reduction. | **Reject** if that was the KPI. |
| Professional desks that want first fill without posting more capital, and passive capital that wants to be paid to wait | That instrument, which Uniswap cannot express today | **Consider**, in the cases in §2. |
| A public, on-chain number for "what is being first worth?" | The head seat's self-posted price. Both "near zero" and "high" are results. | **Consider**, as an experiment. The market that would produce that number **does not exist yet**. |

**Do the benefits outweigh the costs?** Only in a professional venue where (a) the front can hedge, (b) rent actually flows to the back, and (c) the extra network cost is acceptable because the desks already chose this book. In a retail ETH/USDC pool the answer is **no**: you paid +48% extra compute [MEASURED] for a reshuffle of LP P&L that the shopper cannot see. Ordinary Uniswap liquidity *outside* the desks restores permissionless depth away from the money; it does not make the paid counter as deep per dollar as a tight market-maker range.

**The founding 32 names are an endowment**, not a purchase. Whoever deploys picks them. After one transaction they belong to whoever values them — every founding seat starts unpriced, and an unpriced seat is free to take. There is no admin to undo that.

---

## 0.5 WHO BUYS WHICH SEAT, AND WHEN THEY LOSE

The product is the seats. If no seat pays, there is no product. This section is the arithmetic, per
seat, with the conditions written next to it — and it is deliberately the least flattering section
in this document.

> **SUPERSEDED IN PART, 2026-09-01 — read `docs/research/seat-economics/ROTATION.md` first.**
> The diagnosis below is right and the numbers stand: under PERMANENT rank, 28–29 of 32 seats lose
> under every regime. The REMEDY below — "two products, not 32", leave the middle unfunded — was
> the wrong call. The book is now proven zero-sum against its own pro-rata benchmark (+0.0000%
> difference in volume and total P&L), which means the ceiling is all 32 seats EQUAL to a pro-rata
> LP, and **deterministic time-rotation of rank reaches it: 0/32 seats negative whenever the pool
> is profitable.** It also found that BAND WIDTH dominates everything here — the ±10% band these
> numbers were taken on is a losing LP position on a volatile pair whatever the hook does. Do not
> quote §0.5's "two products" conclusion or its per-seat table as current.

**[SIMULATED] — and read this before quoting any number below.** Every figure here comes from
`docs/research/seat-economics/`, a simulation of the mechanism **as the contract actually executes
it**: one constant-liquidity band, seats holding `(a0, a1)`, the outgoing token drained front-first
from a cursor, seats emptied and skipped until the flow reverses. It is not a measurement of a live
pool and there is no live pool to measure. It replaces an earlier model that let the head refill
for free on every trade, which overstated the head and understated everything behind it; the
conclusions changed enough that the old numbers are not reproduced here.

**One caveat governs everything.** The band is fixed for the life of the pool. On a 45%-vol pair
that life is **~18 days** before the price leaves it. Every annual rate below is a rate *while in
band*. QUEUE is a **rolling fixed-term instrument** — like rolling three-week paper, not a
perpetual venue.

### The one sentence that governs the whole section

> **QUEUE does not create return. It redistributes the return of one ordinary Uniswap position.**

The band earns exactly what the same band would earn with no hook on it. Front-first ordering
decides *who gets which part*. So the seats are, against each other, **zero-sum**: if the head beats
an ordinary pro-rata LP by 500 points, the rest of the book is behind by 500 points in total.
Nothing in the design can change that, and any pitch that implies otherwise is wrong.

What the mechanism *can* do — and what it now does — is make the split reflect a real economic
difference rather than an arbitrary one.

### Where the money comes from

```
  A TRADE ARRIVES
       |
       v
  Uniswap sets the PRICE (unchanged: same curve, same 0.30% fee, any router)
       |
       v
  QUEUE decides WHOSE MONEY FILLS IT, in seat order, AND AT WHICH PRICE
       |
       +--> seat 1 fills first, at the STALEST prices of the move
       |    then seat 2, at slightly better prices
       |    ... then seat 32, nearest the post-move price
       v
  small trades  reach seat 1 only
  large trades  reach deep into the book

  RETAIL / noise flow  = many small trades   -> PROFITABLE to fill (fees > markout)
  ARBITRAGE flow       = few large trades    -> LOSS-MAKING to fill (markout > fees)
```

An ordinary Uniswap dollar takes **both halves and cannot decline either**. Sitting at the front
buys the retail flow. Sitting at the back declines the arbitrage flow. **That is the entire product.**

### What marginal pricing changed, and why it was not optional

Until this build, every seat a swap reached was credited the swap's **average** price. The head
therefore took all of the volume *and* the same price as the seats behind it. Simulated across three
regimes, that made the head strictly better than an ordinary LP **in every state of the world**:

```
                                    BENIGN      NORMAL       TOXIC
  ordinary pro-rata LP              +21.2%      -31.8%     -752.6%
  ------------------------------------------------------------------
  seat 1, AVERAGE pricing (old)    +934.0%     +675.3%     -439.9%   beats an LP in ALL THREE
  seat 1, MARGINAL pricing (new)   +911.0%     +566.1%     -796.2%   loses in the toxic regime
```

A position that wins in every state of the world is not a market position, it is a subsidy paid by
the rest of the book — the "free lane" failure that has killed seven mechanisms in this project's
history. Marginal pricing closes it: the head is filled first, so it eats the **stalest** prices of
every move it is first into, and it now underperforms an ordinary LP exactly when being first is
supposed to hurt. Being first became a trade-off instead of a gift.

It did **not** make the book more profitable. Total return is unchanged to the wei. It moved value
from the head to the seats immediately behind it, and made the head's risk honest.

### The book, per seat, and where it is bad

Per year while in band. 32 equal seats of $31,250 on a $1M book, marginal pricing, 60 price paths.

```
                        BENIGN        NORMAL         TOXIC
  in-band life          63.7 d        18.5 d         1.3 d
  ordinary LP           +21.2%        -31.8%       -752.6%
  --------------------------------------------------------
  seat 1   (head)      +911.0%       +566.1%       -796.2%
  seat 5                 -8.3%        -76.8%      -1267.1%   <-- TRAP
  seat 10               -12.9%        -79.9%      -1123.0%   <-- TRAP
  seat 15                -7.6%        -70.2%       -888.2%   <-- TRAP
  seat 20                -9.3%        -49.1%       -659.9%   <-- TRAP
  seat 32  (tail)        +0.0%         +0.0%         -2.3%
  --------------------------------------------------------
  seats beating an LP     1/32         10/32         15/32
```

Three things in that table, and none of them are comfortable:

1. **The middle of the book loses under every condition.** Seats 5–20 are reached often enough to
   absorb the large, toxic trades but not often enough to earn the small, profitable ones. This is
   not a pricing artefact — marginal pricing *improves* these seats and they are still negative.
2. **The deep tail is not "paid to wait", it is UNTOUCHED.** Seat 32's ~0% is not a coupon, it is
   the return of capital that the flow never reached. Its P&L is the P&L of holding the tokens.
3. **In a benign pool only ONE seat beats an ordinary LP.** If the pool is healthy, the honest
   advice to everyone except the head is: do not buy a seat, just LP.

### So why would anyone take seat 32?

Because ~0% is a *good* number in the pools QUEUE is for. An ordinary LP in the normal regime
returns **−31.8%**; the deep tail returns ~0% plus rent. The tail is not buying upside, it is
declining a loss — a **bond-like** claim against an **equity-like** one.

Its income is **rent**, and rent is the only reason the deep book is worth funding at all. The head's
advantage is competed into its self-price by Harberger, and θ = τ/(τ+k) of that flows backward:

```
  head's advantage over an ordinary LP (NORMAL, marginal):  $186,852/yr
  tail capital (seats 2..32):                                $968,750

    tau     theta    head's self-price     rent/yr     TAIL COUPON
    10%      33%              622,839      62,284           6.4%     <-- what the script ships
    25%      56%              415,226     103,807          10.7%
    50%      71%              266,931     133,466          13.8%
   100%      83%              155,710     155,710          16.1%
```

**τ is a constructor argument and the deployed 10% is the least defensible number in the project.**
It hands the tail a 6.4% coupon against a head earning six figures. 25–50% is the honest range, and
nothing but a deployment decision stands in the way.

### The answer to "should all 32 seats hold the same capital"

**No, and equal seats are what manufactures the trap.** Simulated, sizing the head to swallow the
routine arbitrage compresses the middle and roughly doubles the number of seats that beat an LP:

```
  NORMAL regime            pro-rata    head     worst of seats 2-21   seats >= LP
  32 equal   ($31k each)     -31.8%   +566.1%        -109.6%              10/32
  head $300k + 31 x $22.6k   -31.8%    -12.1%         -82.6%              13/32
  head $600k + 31 x $12.9k   -31.8%    -38.4%         -49.9%              21/32
```

But note what it costs: the head's return collapses from +566% to −38%. **You cannot have both a
spectacular head and a survivable middle** — they are the same money. The design honestly supports
exactly **two** positions, and the contract already lets holders choose their own capital, so
nothing needs to change in the code:

| | **HEAD** — one seat | **TAIL** — the deep seats | **MIDDLE** |
|---|---|---|---|
| What it is | equity-like market making | bond-like rent coupon | nothing |
| Capital | sized to the routine arbitrage trade | whatever is idle | **do not fund it** |
| Income | fees on huge turnover, minus stale fills | rent, plus ~0 flow P&L | fees on almost nothing |
| Benchmark | an ordinary LP | a wallet, or an LP in a toxic pool | — |
| Wins when | the pool is benign or normal | the pool loses to arbitrage | **never** |
| Loses when | the pool is toxic | the pool is benign | **always** |

`MAX_SEATS = 32` is room for *participants*, not 32 things to sell.

### The crossover, testable against a real pool with no model of ours

> **Buy the tail when your pool loses more to arbitrageurs than it collects in fees.** Measure it
> from the pool's own history: mark inventory at t+5min on every swap, sum the signed P&L, divide by
> fees. A subgraph query, no model required. Stablecoin pairs: never. Volatile and long-tail pairs:
> common.

### What is honestly wrong with this

1. **It is zero-sum against its own benchmark.** Every point the head gains, the book loses. The
   only external gain is that capital which would otherwise sit in a wallet now provides depth.
2. **The pools where the tail pays are the pools rational LPs are already leaving.** The addressable
   market is people who have concluded LPing there loses money and want the exposure anyway — and
   there are at most 31 of them, because the roster is capped.
3. **Routing viability and seat value are anti-correlated.** QUEUE is routed only where it is the
   deepest venue — long-tail pairs — which are exactly the pairs with thin, adversely-selected flow.
   That, not the +48% gas, is the sharpest objection, and no engineering closes it.
4. **The middle of the book has no buyer at any price**, and the roster is contiguous, so it cannot
   be left out — only left unfunded. A seat with no capital still holds rank.
5. **A QUEUE LP cannot re-mint around the price**, which every ordinary v4 LP can. Fixed-term, roll
   it. See §5 in `README.md`.

### What would make this stronger, none of it built

| | why |
|---|---|
| **τ at 25–50%, not 10%** | Raises the tail's coupon from 6.4% to 10.7–13.8%. Already a constructor argument: a deployment decision, not a code change. Nothing has been tested at those values. |
| **A correct `recenter()`** | Ends the fixed term, which is worth more than any pricing change: it is the difference between an 18-day instrument and a perpetual one. Attempted twice; unit-green, campaign-red, not shipped (`docs/wip/recenter-v2/`). |
| **A big book** | The trap is a fixed *depth range*, not a fixed fraction. Diluting it across a larger book is the only lever that does not cost the head. |

---

## 1. NINETY SECONDS

A Uniswap pool is a shared cash register. Every trade hits every cash provider a little, in proportion to size. Nobody is first. Nobody is last. The only way to get more of the action is to put more money in.

Every other electronic market on earth already prices "being first." They just pay for it in **latency** — microwave towers, colocation — which is burnt on infrastructure and paid to nobody inside the market. On a blockchain the same value is sold by whoever orders the block. The pool's own cash providers get none of it.

QUEUE puts a numbered line inside the pool and sells the numbers.

```
  Customer trades $3,000
  same price · same 0.30% trading fee
                    │
                    ▼
         ┌──────────────────┐
         │ Seat 1   $20k    │  ← emptied. Took 100% of this trade.
         ├──────────────────┤     Pays rent to everyone behind.
         │ Seat 2   $50k    │  untouched
         ├──────────────────┤
         │ Seat 3  $100k    │  untouched
         ├──────────────────┤
         │  … up to 32      │
         └──────────────────┘
```

- Seat 1 is filled by every trade, including the small ones.
- Seat 32 is filled only when a trade has already emptied 1 through 31.
- You cannot join by arriving. You **buy** a seat at the holder's posted price.
- The front pays **rent** to the back, continuously, on a number they set themselves.
- Anyone can take the seat at that number, at any time.

**This is not an order book.** An order book lines up *customers' orders*. QUEUE lines up *the people putting up the money*. No limit price, no matching, no cancel. The customer never talks to the queue.

Think **NYSE seat**, not **DMV line**.

---

## 2. WHEN THIS MAKES SENSE — AND WHEN IT DOES NOT

[ANALYSIS] throughout this section. The cases are the claim; the numbers that follow are the evidence.

### Use it

| Venue | Why QUEUE is the right object |
|---|---|
| A pair that already has ~10–30 serious market makers | 32 seats is about the size of that pit. Capital per seat is unbounded; only the numbers in line are scarce. |
| A designated-market-maker / franchise book | This is what a DMM franchise *is*: a paid, obligated position at the front. Uniswap has never been able to express one. `designated market maker` → **0/662** prior hooks [COUNTED]. |
| A permissioned or RWA book that already names its dealers | You already have a closed roster. QUEUE makes the roster's *order* a priced asset instead of a handshake. |
| A market-maker who wants *first fill*, not *more size* | Today the only route to more fill is more capital, which also buys more of the toxic tail. QUEUE lets them buy the first $50k of flow. |
| A treasury / LST issuer / vault that wants to LP without taking every small trade | The back seat is a subordinated liquidity position with a coupon. It has never existed in an AMM. **It is not "safer"** — see §8. |

### Do not use it

| Venue | Why it is the wrong object |
|---|---|
| A retail ETH/USDC pool competing for aggregator flow | Routers pick same price + lower network cost. QUEUE is +48% compute [MEASURED] on a typical swap. They will skip you. |
| "We want to stop sandwiches" | QUEUE does not. Same prices, same attacks. |
| "We want LPs to lose less" | Total P&L is identical. Redistribution, not reduction. |
| "We want anyone to LP" | 32 seats. A small LP needs a syndicate wrapper. That wrapper is unbuilt and recreates the intermediary the pitch claims to delete. |
| A long-tail pair with no professional desks | There is no buyer for the front, so there is no rent, so the back is strictly worse than ordinary Uniswap in the regime where LPing is profitable. |

**The honest one-liner:** QUEUE is a **membership market for fill priority**. The membership fee is paid to the members you are standing in front of, not to an exchange. If that is not a sentence you can take to a buyer, this is the wrong product.

---

## 2b. WHAT SHIPS TODAY — one queue for the whole pair, not per tick

Yes. **The queue is for the band, not per tick**, and the band sits inside a normal Uniswap pool. There is one pool, one hook-owned concentrated position (~±10%), and one ordered list of ≤32 seats that share that position. Seats are not NFTs and they do not pick ranges.

A trade that **stays at today's price** is allocated down that line, front-first. A trade that **walks away from today's price** fills the paid desks, then ordinary Uniswap LPs further out (Uniswap's own Position Manager, no seat). Parking on top of the paid desks reverts. There is no per-tick book and no per-seat range.

```
UNISWAP v3/v4 TODAY                         QUEUE TODAY (shipping)
───────────────────                         ─────────────────────
Price first: nearer ticks fill first        Price first, still (ticks unchanged)
Within a tick: everyone at that             THEN, inside the hook's band:
price is filled pro-rata                    32 paid seats, front-first
                                            Outside the band: ordinary Uniswap
                                            (anyone, PositionManager, pro-rata)
```

That is why this version is a **specialist DMM at the money**, not a replacement for Uniswap. Uniswap's product is concentrated liquidity; the wings are that product, unmodified. The queue is only who gets filled first *at the same price*. **Per-seat or per-tick ranges are a different product and are not shipping.** See §16.

### Two tokens vs one

A seat's ledger is `(token0, token1)`. It **can** hold only one.

| Action | Both tokens | One token |
|---|---|---|
| `addToSeat` | Allowed. At the current price, on a full-range in-range position, **both legs are needed to mint depth.** The min of the two legs decides how much L is added. | Allowed. On this version, in range, the other leg is 0, so **L minted is 0.** The tokens sit in the shared float. You have a claim on the books. You did **not** add pool depth. |
| After a swap | Front is driven toward one-sided: it sells the outgoing token until that side is empty. | That is the normal post-fill state. Withdrawal needs the shared float because Uniswap will not release an off-ratio pile from a position. |
| Rent received | Weighted by **token0 balance only**. [MEASURED in the contract.] | A seat holding only token1 is paid **$0** of rent. After a one-way sell of token0, the back is often sitting in token1 — so the coupon dies on the day they sat through the beating. |

**It makes a difference.** Providing both in the current ratio is how you add depth. Providing one is inventory. Earning rent requires token0. A "passive" back seat that gets converted to token1 on an event is not passive and is not paid. That is the Ratchet plus the token0-weight, stacked.

Do not tell a treasury "deposit whichever token you have." On this version that is how you add no depth and collect no rent.

---

## 3. WHAT A "QUEUE" IS HERE

The word is doing too much work. In ordinary English a queue is: arrive, stand at the back, wait, get served.

**QUEUE is not that.**

```
ORDINARY QUEUE                          THIS PRODUCT
──────────────                          ────────────
Arrive → join the back                  There is no "join the back"
Position = who got here first           Position = who pays the rent
Anyone can enter                        32 seats. Always.
Free                                    Paid, continuously
You cannot be jumped                    You CAN be bought out, at your own price
Leaving gives up your place             Taking your money out does NOT destroy
                                        the seat. Empty seat = numbered place,
                                        still for sale, still on the rent meter.
```

The ordinary version is dead on arrival, and this repository has the corpse:

1. **Free rank is griefable rank.** If arrival grants the front, the front costs one wei. Dust it, own every small trade forever. That was version 1 of this hook (`PLAN.md` §B.8, §E.16; `PITFALLS.md` 5.8).
2. **Unbounded rank is worthless rank.** If anyone may join the back, slots are not scarce. A non-scarce asset has no price. With no price there is no rent, and the back is never paid.

So the roster is **bounded** and the seats are **paid for**. Scarcity is the mechanism, not a compute concession.

Which raises the obvious objection: a fixed set of 32 tradeable seats is a cartel. That is why a seat is **leased, not owned**:

- You post your own price. No oracle, no admin, nobody else's opinion.
- You pay **continuous rent on your own number**, to the seats behind you.
- **Anyone may take the seat at that number, at any time.** Under-price it, you lose it. Over-price it, you pay for it.
- Rent comes from a **prepaid meter**. Let it run dry and you are **moved to the back** — not liquidated, not seized. You keep the seat and every wei of capital. You lose only your place.

> **Scarce, but never capturable.** A bounded roster without the lease is a cartel. A lease without a bounded roster prices nothing.

The sharpest form of the remaining objection — *"so it isn't really a queue"* — is correct, and conceding it is what makes the rest land. QUEUE is not price–time priority. Rank goes to willingness to pay rent, not to arrival. What it reproduces is the **scarcity and value** of queue position, made explicit and payable to the people you are standing in front of.

---

## 4. WHO PAYS WHOM

```
                    RENT (continuous, prepaid)
   Front-seat LP  ──────────────────────────►  Back-seat LPs
   (market maker                           (treasury, vault,
    who wants flow)                         paid to wait)
         │                                         ▲
         │  buys the seat                          │  receives the buyout
         │  at the posted price                    │  if they sell, or the
         ▼                                         │  rent if they stay
   Seat changes hands ─────────────────────────────┘
   (anyone, any time, at the holder's own number)


   Customer ──► ordinary Uniswap router ──► pool
                same price, same trading fee
                plus a fixed extra network tick (§6)
                The queue is invisible to them.
```

| Party | Today | Under QUEUE | Pays or receives |
|---|---|---|---|
| **Front-seat LP** | Deposits more capital to get a bigger slice of *everything*, including the trades that hurt | Holds the front, filled first on every trade | **Pays rent**, continuously, on a price they set |
| **Back-seat LP** | Filled pro-rata on every trade whether they want to be or not | Sits behind; reached only when a trade sweeps the front | **Receives that rent** — a coupon for standing aside |
| **Customer** | Pays the pool's trading fee | Pays the same fee at the same price, through any router | **Pays a fixed +48% network cost** on a typical swap [MEASURED]. No fee change, no worse price. |

The rent is a transfer between two kinds of LP that both already exist. No new party is taxed to fund it. No value is taken from customers or searchers. The protocol takes no cut. The one cost that falls outside that transfer is the **fixed extra network tick the customer pays**, and it is a real cost — named here, not netted out of the pitch.

**Both seats cannot beat ordinary Uniswap at once.** [ANALYSIS] QUEUE is zero-sum against pro-rata: the swap happened at the same prices either way, so total fees minus total adverse selection is the same pie. In a *profitable* pool the front takes more of a positive number and the back takes less — the back needs rent to be willing. In a *loss-making* pool the signs flip — the back is glad to have sat out, and the front wants to be paid to stand there. The current lease **cannot express a negative price**; under toxic flow everyone declares near zero, rent stops, and the compensation dies on the day the back most wants it. Unsolved. (`PITFALLS.md` 5.10, 5.20.)

---

## 5. WHY 32, NOT 100, NOT 500

Three reasons. They are different. A slide that mixes them is lying by compression.

### 5.1 The line fits in one computer word

The order of the 32 seats is stored as 32 bytes — one byte per seat number. Pushing someone to the back rewrites the entire line in a single write. Walking the line reads the entire order in a single read. `MAX_SEATS > 32` in *this* version **silently truncates rank**; `test_4_41` exists so that cannot ship.

Raising the cap past 32 is a **redesign**, not a constant change.

### 5.2 Compute — and the number people ask about

[MEASURED] `test/queue/Gas.t.sol`. Every figure is a **complete swap transaction** through the real router against the real PoolManager — what a customer actually pays. State is built in `setUp()` so writes are metered honestly.

| seats in queue | typical swap (head only) | full walk of the line | seats walked |
|---:|---:|---:|---:|
| 1 | 117,971 | 145,980 | 1 |
| 2 | 117,989 | 173,950 | 2 |
| 5 | 117,990 | 198,161 | 5 |
| 10 | 117,990 | 238,511 | 10 |
| 25 | 117,991 | 359,562 | 25 |
| 32 | 117,992 | **416,053** | 32 |

> `sweep(n) = 137,866 + 8,070·n + 19,900·[n ≥ 2]` — reproduces every row to within **3 gas**.

Three facts:

1. **A typical swap is flat: 117,971 → 117,992 across 1 → 32 seats, a spread of 21 units.** Most swaps only hit seat 1. Flatness is the cursors working.
2. **A walking swap is linear, 8,070 units per extra seat.** A full 32-seat walk is a 416,053-unit transaction.
3. **QUEUE costs 48% more than no hook at all on a typical swap.** Same tokens, fee, spacing, price, no hook: **128,625 vs 87,039, +41,586** [MEASURED, `test_5_7`]. The older +36% / 117,989 figure was the pre-wings hook.

The binding constraint is **not** the walk. Depositing (`addToSeat`) settles every priced seat ahead of the depositor, and each of those settlements pays every funded seat behind — quadratic in the roster. Measured worst case: **2,610,805 units**, 8.7% of a 30M block. **That is the number any proposal to raise `MAX_SEATS` has to be argued against** (`PITFALLS.md` 5.72).

```
                    1 seat      32 seats       100 seats        500 seats
Typical trade       same        same (+21)     would be same*   would be same*
Walk-every-seat     cheap       ~416k          ~1M+             fails
Add money to a seat cheap       2.6M worst     likely a block   impossible
What it is          monopoly    a franchise    getting cheap    free → no price

* if the "only touch the front" shortcut still works
```

Unlimited seats do not fail gently. A 1,000-entry walk is ~8.2M units on the sweep alone; the quadratic deposit path is past a block long before that. Large honest trades fail. Informed traders split and go through anyway.

### 5.3 32 is about the size of a serious pit

The *money* per seat is unbounded. Only the *numbers in line* are scarce. If they were not scarce they would have no price, and the product disappears. This reason would still apply if compute were free.

**Could it be 8 or 16?** Yes — a tighter designated-MM pit. **64?** Not without the unbuilt redesign that makes walking the line a constant cost (DECIDED NOT SHIPPED, `PLAN.md` §B.11). **100 or 500?** Not a bigger QUEUE. A different, currently unexecutable program.

**A 32-seat pool is a professional venue, not an open retail pool.** Uniswap's identity is permissionless access. This is a genuine departure and it should be the first sentence of the pitch, not a footnote.

### 5.4 Scarcity — both sides

**For:** compute forces it at this version; a seat everyone can have is worth nothing; every real market-maker franchise is bounded for the same reason.

**Against:** 32 is a club, clubs cartel; small LPs must syndicate (unbuilt wrapper, recreates an intermediary); a bounded roster caps the *number* of LPs (not dollars); less depth means less utility on the same line as less adverse selection — a thin QUEUE pool is a smaller pool, not a better one.

Honest resolution: scarcity is currently *forced* by compute and *justified* by economics. Those are two arguments. If the constant-cost redesign ships, only the economic one remains, and the seat count becomes a per-pool parameter the deployer sets.

---

## 6. THE "+48%" — IT IS NOT 48% MORE EXPENSIVE TRADES

[MEASURED] A typical swap: **128,625 vs 87,039** on an identical hookless pool = **+48%** (`test_5_7`). The extra versus the older +36% figure is the in-band clip.

What a business person hears: *"customers pay 36% more."*

| | |
|---|---|
| A trading fee? | **No.** The pool's 0.30% (or whatever was set) is unchanged. |
| A worse price? | **No.** Same tokens out. |
| Extra network cost? | **Yes.** A slightly longer checkout. |
| Same at 1 seat as at 32? | **Yes, for a typical swap.** 117,971 vs 117,992. Difference: 21 units. The 36% is the cost of the pool *having a book at all*. |
| Always 48%? | **No.** A trade that walks many seats adds ~8,070 per extra seat. A full 32-seat walk is 764,200 units — not +48%, closer to 5× a hookless swap. That is a large, unusual trade. |
| In dollars? | This product belongs on an L2. 31,000 extra units is **cents or less**, not 36% of the notional. On Ethereum mainnet it would be a real bill. **QUEUE is an L2 product.** |

The commercial risk is not "36% more expensive trades." It is: **routers pick the pool with the same price and the lower network cost.** If they skip QUEUE, this pool does not see retail flow. Retail flow is the "good" flow the front seat is paying rent to capture. That loop is the adoption problem. It is not solved.

Do not quote "+48%" as "QUEUE overhead." Quote: **+48% on a typical (head-only) fill; +8,070 per seat if the trade actually walks the line.**

---

## 7. "32 PEOPLE CANCEL AT ONCE AND THE POOL DIES"

The right instinct. The wrong machine.

**There is no cancel button on a trade.** Customers cannot cancel the queue. They never see it.

**A cash provider can take their money out of their seat at any time.** Taking the money out does **not** destroy the seat. An empty seat is still a numbered place, still for sale, still on the rent meter. The line stays 32 long. [MEASURED: `test_2_5`; comments on `withdraw` in `QueueHook.sol`.]

```
32 seats, all funded                         32 seats, 30 emptied
────────────────────                         ────────────────────
Deep book. Small trades                      Thin book. Same prices.
hit seat 1 and stop.                         A $3,000 trade now walks
                                             further and moves the price more.

The pool does not "fail".                    The pool does not "fail".
It is the same as any market                 It is the same as any market
where liquidity walks.                       where liquidity walks.

If ALL money leaves:                         The 32 seat tokens still exist.
trades still execute, with                   Anyone can buy a seat and put
almost no depth — a pool                     money back in. No admin. No
nobody is using. Same as a                   pause switch.
Uniswap pool whose LPs all
withdrew.
```

What the code actually does when the book is empty [MEASURED, `PITFALLS.md` 5.78]: a swap does **not** revert inside QUEUE. The error that would mean "swap bigger than the queue" is structurally unreachable through the pool — the swap cannot be larger than the position, and the position cannot be larger than the ledger. An empty book: the first swap is a no-op (nothing in, nothing out) that still walks the price to the limit; the next same-direction swap reverts Uniswap's own "price limit already exceeded," not the hook. One deposit restores fills.

**What is actually different from a normal pool:**

| Risk | Real? |
|---|---|
| 32 desks can actually empty the book (a panic, a better venue, a regulatory event) | **Yes.** A normal Uniswap pool has thousands of LPs; losing 32 is noise. Here 32 *is* the market. Same as a thin CEX MM list pulling quotes. Concentration risk. Real. |
| They can all "cancel the seat" and brick membership | **No.** They can empty it. Someone else can take it at the posted price. Price at zero → free to take. Price enormous + dry meter → automatically moved to the back, money kept, place lost. Nothing seized. |
| Simultaneous buyouts halt the pool | **No.** Taking a seat pays the holder and sends their capital back. New holder is empty until they deposit. Brief thinness, not a halt. A contract seller cannot refuse the tokens and block the sale. |
| Incumbent veto on being bought out | **Was real, now closed.** A withdrawal/buyout could revert at a tick boundary (`PITFALLS.md` 5.76 / 5.77). Found after 135 tests. Fixed. |
| Last people out are short | **Yes, rounding dust.** Face value is an upper bound. Worst surplus across the invariant campaign: **0 wei**. Worst shortfall: **under 1 part per billion** of everything ever deposited, borne by the last withdrawers. Not an attack — causing it costs six-figure multiples of the residual in swap input. |
| The 32 collude, post zero, rent stops | **Yes, and this is the failure mode the pitch should fear.** Then the transfer that makes the back's deal rational dies. You have ordinary Uniswap with extra network cost and a thinner book. The lease assumes an outsider with capital. A founding roster of insiders may not provide one. |

The failure mode of "everyone leaves" is **"the pool is empty,"** not "the pool is seized." There is no admin, no upgrade, no pause.

---

## 8. PROS AND CONS — DO THE BENEFITS OUTWEIGH?

### The customer (the trader)

| Pros | Cons |
|---|---|
| Same price. Same trading fee. Any Uniswap router. Never touches the queue. | +48% network compute on a typical swap [MEASURED]. A constant, not a slope. |
| | A very large trade that walks many seats costs more still (8,070/seat). |
| | **CLOSED — the band shipped.** True while the hook held a full-range position (~1/200th the depth per dollar of a tight ±1% range). The hook now custodies a concentrated band whose half-width is a **deployment parameter**, so depth at the money is sized to the pair. Queue maths is proven orthogonal to range (`test_1_11`). The surviving objection is routing, not depth: see §7. |

**Verdict:** the customer is not being sold anything. They should be indifferent except for the extra network tick and the thinner book. If routers skip the pool, the front seat does not get the flow it is paying for.

### The front seat (market maker who wants flow)

| Pros | Cons |
|---|---|
| First fill on every trade, including the small profitable ones, without posting more capital. | Pays rent continuously on a price they set. |
| Can say *"give me the first $50k of flow"* — Uniswap cannot express this at all today. | Eats 100% of a bad trade that lands in their inventory. 50× leverage on the flow, **both ways**. |
| Seat is durable (unlike JIT: mint-and-burn every block). Tight-range jump is structurally unavailable here. | If flow is toxic, the seat is a liability. The lease **cannot pay you to sit at the front** (price floor at 0). Unsolved. |
| Anyone can take it if you under-price. You can empty the capital and keep or sell the rank. | For a firm that can flatten inventory off-venue. A treasury should not sit here. |

**Verdict:** benefits outweigh **if** the firm can hedge and the flow is mixed or benign. Otherwise they will not buy the seat, which is the mechanism working.

### The back seat (treasury, vault, "pay me to wait")

| Pros | Cons |
|---|---|
| Receives rent from the front. A coupon that has never existed in an AMM. | In quiet, profitable two-way markets they **forgo most fee income**. Without rent, the back is strictly worse than ordinary Uniswap. **Rent is not optional for this role.** |
| Reached only by large trades. Lower turnover. | Large trades are the *informed* ones. Lower frequency, **worse mix**, plus a coupon. Not "safer." Selling the back as safe is lying. |
| Capital sized independently of rank. | Inventory bought on a big sell does not automatically unwind on the way up — the next buy fills the *front* first. "Passive" capital is forced to be a bit active. (`docs/research/premise-review/fairness.md`, the Ratchet.) |
| Cannot be dusted out of existence. | 32-seat cap: a small LP needs a syndicate wrapper. Unbuilt. Recreates an intermediary. |

**Worked numbers, benign day [ESTIMATE].** §7.1's $3,000 swap, fee $9, head-only, repeated 100× a day, balanced flow, markout ≈ 0:

| | Head ($20k) | Tail ($530k) |
|---|---:|---:|
| QUEUE fee income / day | **$900** (100% of every swap) | **$0** |
| Ordinary Uniswap fee income / day | $18 | **$477** |
| Tail vs ordinary Uniswap | — | **−$477 / day**, nothing back, because the thing it is "insured against" is not happening |

$477/day on $530k is ~9 bps/day of given-up income. **That is the hole rent has to fill.** If rent does not show up, the tail's participation is irrational in the regime where people LP at all.

**Worked numbers, toxic episode [ESTIMATE].** $300k of informed selling (§7.3): the $530k tail nets **$0** against **−$1,950** pro-rata. The tail beats ordinary Uniswap by $1,950 on that episode — and the lease, on that day, is the one that censors at zero.

**Verdict:** benefits outweigh **only if rent actually flows**. In the demo, in a new pool, on a long-tail pair, there is no market in seats yet. That is the weakest point in the design.

### The venue / deployer

| Pros | Cons |
|---|---|
| Differentiated LP product. A reason for professional capital to pick this pool over the 189th dynamic-fee hook [COUNTED]. | Bounded in *number of LPs* (not dollars). |
| A public number: the head-seat price. Both answers are results. | The band is ±10%. Wings are public Uniswap outside it. Routers may still skip +48% compute. |
| No admin, no upgrade, no privileged role. You cannot be asked to freeze it. | You also cannot freeze it. Founding 32 is an endowment worth one transaction of head start. |

### JIT bots / searchers

Weak buy-in, stated as weak. They cannot jump this pool with a tight-range mint. They can buy the seat for a block and resell it. Honest answer: they trade elsewhere. QUEUE's claim against them is structural, not persuasive.

---

## 9. WHAT A DECISION-MAKER WILL FEAR

| Fear | Verdict |
|---|---|
| "32 people control the pool — a cartel" | **Half real.** 32 is a franchise. The lease is the anti-cartel: anyone can buy any seat at the holder's own price, no whitelist, no admin. Collude to post infinite prices → pay infinite rent. Post zero → cartel is free to break, **and rent dies.** |
| "Customers pay 36% extra" | **Confused as a trading-fee claim; real as a routing claim.** Extra network cost, not extra trading fee. Still a reason routers skip you. |
| "If they all leave, money is trapped" | **Mostly false.** Per-seat withdrawal against actual tokens. No lockup. No pause. Last-out rounding dust, not a lock. |
| "Someone steals by being first" | **Version 1, dead.** You cannot create a seat by depositing. Dusting the head buys nothing. |
| "This is a dark / permissioned pool" | **Looks like one; is not, quite.** Entry is permissionless *at a price*. A real permissioned pool has a whitelist and a forked router. QUEUE uses the ordinary Uniswap router. Compliance will still treat 32 named seats as a designated-MM list. Do not be surprised. |
| "A bug loses the money" | **Real, and the most serious row in this table.** The hook *is* the pool's accounting. A bug is lost funds. 198 tests, 74 mutations with zero survivors, three production bugs found by attacking our own code. **This is not an audit.** |
| "We get blamed for MEV" | **Theme risk, not product risk.** QUEUE does not stop sandwiches. Shipping it as "MEV protection" is mis-selling. |

---

## 10. ARCHITECTURE

```
                    ┌──────────────────────────────────────┐
                    │      ANY UNISWAP ROUTER              │
                    │   (the customer never sees QUEUE)    │
                    └─────────────────┬────────────────────┘
                                      │ swap
                                      ▼
                    ┌──────────────────────────────────────┐
                    │      Uniswap v4 PoolManager          │
                    │  Does the swap as usual. Same price. │
                    │  Then calls the hook: "here is what  │
                    │  actually moved."                    │
                    └─────────────────┬────────────────────┘
                                      │ afterSwap(amounts)
                                      ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  QUEUE HOOK                                                              │
│                                                                          │
│  1. Holds 100% of the pool's money as ONE position it owns.              │
│     Nobody else can add liquidity. The hook's books ARE the pool.        │
│                                                                          │
│  2. 32 seats. Each = (token A, token B, owner, ask price, prepaid rent). │
│     The ORDER of the 32 is one computer word.                            │
│                                                                          │
│  3. Walks the line front-first at THIS SWAP's own average price.         │
│     Last seat filled gets the leftover wei so the sum is exact.          │
│                                                                          │
│  4. Rent: prepaid meter → seats behind you. Dry meter → moved to the     │
│     back. You keep the seat and every wei. You lose only your place.     │
│                                                                          │
│  5. Buyout: anyone pays your posted price. Your capital is sent back.    │
│     They get an empty seat at your old place.                            │
│                                                                          │
│  No admin. No upgrade. No oracle. No off-chain bot required.             │
└──────────────────────────────────────────────────────────────────────────┘
```

Why hold the whole pool: Uniswap fills from one blended pot. To have a line, someone has to keep 32 separate piles. The hook is that someone. The price it uses is not a guess — it is the swap's own average, handed back by Uniswap. There is nothing to manipulate.

A seat is an ERC-6909 token, supply exactly one. Transferring it moves **place in line**, not the capital. The capital goes back to the seller.

Deposit / swap / withdraw, the operational version:

```
DEPOSIT
  LP ──► hook.addToSeat(seat, amount0, amount1)
           ├─ settle rent owed by everyone in front (closes a flash-loan grab)
           ├─ hook IS the unlocker, so Uniswap keys the position to the hook
           └─ credit the seat's ledger; leftovers sit in a shared float


SWAP ARRIVES
  customer ──► any router ──► PoolManager.swap()
                                ├─ beforeAddLiquidity: REVERT unless the hook itself
                                ├─ swap executes NORMALLY. Price untouched.
                                │  Hook returns no delta. Router-clean.
                                └─ afterSwap(what actually moved)
                                      realised average price = amtIn / amtOut
                                      — the swap's OWN number. Not a mark.
                                      Not an oracle. Nothing to push.
                                      ▼
                                FRONT-FIRST
                                take  = min(this seat's outgoing, remaining)
                                give  = floor(amtIn × take / amtOut)
                                last filled seat gets  amtIn − assignedSoFar
                                ── that line is what makes the sum close ──

   typical small swap: touches 1 seat, the line does not move
   sweeping swap:      touches k seats


WITHDRAW
  LP ──► hook.withdraw(seat, w0, w1)
           └─ pays whatever that seat currently holds
              (NOT face value — last-out rounding, §14)
              Withdrawing to zero does NOT destroy the seat.
```

---

## 11. WORKED EXAMPLES

**Shared assumptions** [ESTIMATE — illustrative, not measurements, except gas]:

- WETH/USDC, ETH at 3,000 USDC, fee tier 0.30%, taken on the input token.
- Pool custodies **$1,000,000** in five seats: `S1 $20k · S2 $50k · S3 $100k · S4 $300k · S5 $530k`.
- Price impact is folded into the stated realised average price. **Gas figures are [MEASURED]** on the shipping hook (`test/queue/Gas.t.sol`) as complete swap transactions through the real router.

### 11.1 Small swap — head only

Trader swaps **3,000 USDC → WETH**. Fee 9 USDC. 2,991 USDC swapped → **0.997 WETH** out.
Realised average = 3,000 / 0.997 = **3,009 USDC/WETH**.

| | Under QUEUE | Under ordinary Uniswap |
|---|---:|---:|
| S1 sells | **0.997 WETH** | 0.0199 WETH |
| S1 earns | **9.00 USDC** | 0.18 USDC |
| S2–S5 earn | **0.00** | 8.82 USDC combined |
| Swap compute, complete tx | **128,625** [MEASURED]; +41,586 (+48%) vs no hook | `test_5_7` |

S1 is 2% of the pool and earned 100% of the fee: a **50× multiple**, which is not a result, it is an identity — `total capital / front seat capital`.

**The other half:** S1 also bore **100% of this swap's adverse selection** instead of 2%. The front is 50× leverage on the flow, in both directions. Whether that is good depends entirely on what the flow is — and that is the question the seat price answers.

### 11.2 Large swap — sweeping four and a half seats

Trader sells WETH, consuming **500,000 USDC**. Price walks 3,000 → 2,940; realised average **2,970**. Gross input 168.86 WETH, of which fee 0.5066 WETH (≈ $1,505).

| Seat | USDC held | USDC filled | WETH received @2,970 | fee share | fee (WETH) |
|---|---:|---:|---:|---:|---:|
| S1 | 20,000 | 20,000 (100%) | 6.7340 | 4.0% | 0.02027 |
| S2 | 50,000 | 50,000 (100%) | 16.8350 | 10.0% | 0.05066 |
| S3 | 100,000 | 100,000 (100%) | 33.6700 | 20.0% | 0.10132 |
| S4 | 300,000 | 300,000 (100%) | 101.0101 | 60.0% | 0.30398 |
| S5 | 530,000 | **30,000 (5.7%)** | 10.1010 | 6.0% | 0.03040 |
| | | **500,000** | **168.3501** | **100%** | **0.50663** |

Seats touched: **5**. Swap compute ≈ **198,161** [MEASURED at a 5-seat roster], of which ~40,000 is the queue walk.

Marked at the post-swap price of 2,940:

| | Net P&L on the episode | On its own capital |
|---|---:|---:|
| S1–S4 (fully converted) | −$3,348 | **−71 bps** |
| S5 (5.7% converted) | −$214 | **−0.4 bps** |
| **Pool total** | **−$3,562** | — |
| *Same swap, ordinary Uniswap* | **−$3,562** | **−35.6 bps for every seat, identically** |

**The total is unchanged to the cent.** QUEUE moved S5 from −35.6 bps to −0.4 bps and S1–S4 from −35.6 bps to −71 bps. **This is redistribution, not reduction.** Anyone who writes it up as "QUEUE reduced LP losses" is lying about it.

### 11.3 Toxic flow — the front must be paid to stand there

An event day. Flow is one-directional and informed. **$300,000** of net informed selling walks the price 3,000 → 2,910; realised average **2,955**. Fee 0.3046 WETH ≈ $886.

Per USDC filled: loss = `1 − 2910/2955` = **−1.5228%**; fee credit = `886 / 300,000` = **+0.2955%**; net = **−1.2273%**.

| Seat | USDC filled | Net P&L | On its own capital |
|---|---:|---:|---:|
| S1 | 20,000 (100%) | −$245 | **−123 bps** |
| S2 | 50,000 (100%) | −$614 | **−123 bps** |
| S3 | 100,000 (100%) | −$1,227 | **−123 bps** |
| S4 | 130,000 (43%) | −$1,595 | **−53 bps** |
| S5 | 0 | **$0** | **0 bps** |
| **Total** | **300,000** | **−$3,681** | — |
| *Ordinary Uniswap* | | **−$3,681** | **−36.8 bps, every seat, identically** |

The front/back spread on this day is 123 bps. S5 outperformed today's pool by 36.8 bps; S1–S3 underperformed it by 86 bps.

**Caveat on the "toxicity signal" [ANALYSIS].** The price of moving from front to back is a *forward-looking Harberger ask*, censored at zero on the toxic side where it would be most interesting. It is not an oracle of adverse selection. The novel part is that it is on-chain and costs real money to post. The overclaim "the seat price IS the toxicity" is on the record as overclaim (`PITFALLS.md` 5.20).

### 11.4 What you pay vs what you earn — the buy-in this project actually is

This repo is **queue management and nothing else.** No sandwich shield, no new curve, no fee switch. The only reason a desk shows up is: liquidity in + ask posted → fees ± markout ± rent. If those numbers do not work, the rest of the repo is a museum of exact wei.

Live sliders: [`frontend/index.html`](frontend/index.html) — rank, your liquidity, your ask, small volume, sweep volume, two markouts. Same $1M five-seat book. Rank 4 is the stand-in for seat 32.

τ = 10%/year, immutable. Rent this year = `0.10 × your ask`. A rough consistency check, not a valuation:

> If this day, repeated, gives you $X extra vs ordinary Uniswap, a rational cap on your ask is **$X / 0.10**. Above that you are paying more rent than the extra P&L. Below that a buyer takes you and keeps the residual. Ask of 0 is free to take.

**Quiet two-way. $300k/day head-only, 0 bps markout, $1M book.** [ESTIMATE] You are the $20k front, asking $50,000.

```
THIS MONTH (day × 30)
                    QUEUE          ordinary Uniswap
Fee income          $27,000        $540
Markout             $0             $0
Rent you pay        −$417          —
Rent you receive    $0             —
NET                 $26,583        $540
Δ vs ordinary       +$26,043 / month

Extra annual ≈ $312k
Rational ask cap ≈ $312k / 0.10 = $3.1M
Your ask $50k is UNDERPRICED — rent is cheap vs the extra.
A buyer pays you $50k and collects the leftover.
```

That 50× fee multiple is an identity (`pool / head`), not a result. **Move markout off zero and it dies.** At 30 bps markout on the same $300k/day, the head's markout is $2,700/day against $900 fees. The front is a liability. Press that slider.

**Event day. $30k small + $300k sweep at 123 bps markout.** You are still the $20k front.

```
The sweep empties you first. You take ~all of a −123 bps fill on your $20k
and almost none of the remaining $280k (that walks through you to the back).
Rent is still −$417/month on a $50k ask.
The front is a liability. A rational holder asks ~0. Rent stops.
The back, who sat out most of the beating, is no longer paid.
```

**Same event, you are the $530k back, asking $500.**

```
S1+S2+S3+S4 = $470k in front. A $300k sweep dies in S1–S4. You fill $0.
Fee $0, markout $0. You receive rent from whoever in front is still asking.
You beat ordinary Uniswap, which would have smeared −36.8 bps on you.
THAT is why the back exists — on this day.
On the quiet day above, the same back forgoes ~$477/day of fees.
Rent from the front has to fill that hole or the back is a bad deal.
```

**Why buy the front — the events, not the slogan**

| Event | Why the front | What a reasonable ask is doing |
|---|---|---|
| Quiet two-way flow, you can hedge | You want every small fill on a thin book. 50× turnover vs your capital. | Ask near extra-P&L / τ. Too low → you are taken. Too high → you bleed rent. |
| A scheduled print / listing / unlock, 1 hour | JIT today mints a tight range for free and pays incumbents nothing. Here you **buy the head for the hour**, harvest the first inventory of flow, re-ask. Rent for an hour on a $50k ask is ~$0.57. The real cost is the buyout capital and the firm window. | Short-hold. Ask high enough not to be flipped mid-event, not so high the hour of rent (tiny) matters. This is the closest thing to "why would a searcher buy in." |
| You are a treasury | You would **not**. You want the back, and only if rent is actually flowing. | Ask ~0. Last in line paying rent into an empty-behind pot burns escrow into `unallocatedRent0`. |

**Over-price / under-price, in one picture**

```
         extra P&L this year
                 │
    underpriced  │  fair band     overpriced
    ─────────────┼─────────────────────────────► ask
    buyer takes  │  you keep it   you pay to
    you, keeps   │  and pay rent  keep it;
    the leftover │  ≈ extra P&L   nobody takes
                 │                you; you bleed
    ask = 0 is the free seat. Founding state. Ends the product.
```

At τ = 10%, **overpaying the ask by 10× costs you 100% of a fair extra-P&L in rent.** That is the whole discipline. There is no oracle. The discipline is the bill.

These numbers are **not measured on chain.** They are the identities the mechanism imposes, with a flow mix you type in. The frontend is the way to lie less than a static table.

---

## 12. ARE WE SURE THIS DOES NOT EXIST?

### 12.1 The 662-row directory — queries run, not remembered

Dataset: `archive/2026-08-26/docs/research/data/hook_directory_662.json`, 662 submissions across UHI1–UHI10.

```bash
jq -r '[.[] | select((.name+" "+.desc+" "+.tags+" "+.integrations)
      | test("queue|priority|price.?time|fill order|rank|seat|ordered|fifo|lifo";"i"))] | length' \
  hook_directory_662.json
```

| Query | Hits / 662 | What they actually are |
|---|---:|---|
| `queue\|priority\|price.?time\|fill order\|rank\|seat\|ordered\|fifo\|lifo` | **10** | Zero are an ordering over LP capital. |
| `\bqueue` | **3** | All three queue *swaps*, not liquidity. |
| `\brank\b\|\bseat\b\|\bseats\b` | **0** | — |
| `designated market maker\|\bdmm\b` | **0** | — |
| `harberger\|self.assess\|always for sale` | **0** | — |
| `am-?amm\|auction.?managed` | **7** | The nearest neighbour — see below. |

**Result: 0 of 662 submissions sell an ordering over LP capital.** [COUNTED]

### 12.2 What IS adjacent, stated plainly

| Adjacent thing | How close | How QUEUE differs |
|---|---|---|
| **am-AMM family** (7 rows) | Closest by concept. Both sell a right over a pool to capital. | am-AMM auctions **management and fee-setting of the whole pool to one winner per block**. QUEUE sells **an ordering over the existing LPs' own capital**, perpetually, to many holders. No auction, no per-block winner, no manager, no fee-setting right. **Lead with pro-rata-vs-queue. Do not lead with the word "auction."** Atrium puts LVR auctions on the AVOID list [SOURCED]. |
| **Tranche hooks** (11 rows, 1 prized) | Closest by shape — an explicit ordering over LP capital. | Tranches order **payouts**. A senior tranche still trades against every swap pro-rata; it is paid first out of the results. QUEUE orders **fills** — which swaps you are the counterparty to. Different object. |
| **JIT liquidity** (21 rows, and live practice) | Closest by behaviour. A JIT bot is already buying fill priority. | Today the only way to buy priority is to **out-concentrate** everyone at the touch. Pays LPs nothing. QUEUE reverts every external add; the only route to the front is to buy the rank from whoever holds it. |
| **Limit-order hooks** (17 rows, 7 prized) | A limit book *is* price–time priority. | Those hooks queue **traders' orders**. QUEUE orders **LPs' capital**. Opposite side of the market. |
| **Angstrom, Kyber FairFlow, CoW, UniswapX** | Real, live, adjacent. | Order-routing layers beside the AMM. None changes who *inside* a pool is the counterparty. |
| **TradFi: NYSE Designated Market Makers** | The real precedent, and it is not on-chain. | A DMM franchise is exactly "a paid, obligated position at the front of the book." Never expressible in an AMM because there was no book. |

**Honest summary:** the *concept* of paid queue priority is ancient. The *implementation over pooled AMM liquidity* has no instance in 662 submissions, no instance in the live incumbents we could locate, and no instance in the DeFi literature we could locate. The novelty claim is about the venue, not about the idea. Pitch it that way.

---

## 13. WHAT THE ENGINEERING RESULTS MEAN COMMERCIALLY

| The technical result | What it means for the business |
|---|---|
| Front-first allocation is **exact to the wei** in both tokens, at four price ratios and two decimal pairs [MEASURED] | A seat's fill is a contractual quantity, not a best-effort. That is the difference between an instrument you can price and a feature you have to trust. |
| The queue is **never over-backed** — surplus **exactly 0 wei** across 16,384 randomised operations [MEASURED] | Every claim on the pool is matched by assets in the pool. |
| Shortfall stays **under 1 part per billion** of everything ever deposited [MEASURED] | Redemption is not exact — v4's own rounding sees to that — but the leakage is a rounding artefact, borne by **the last holders to exit**. |
| Seat overhead is **flat from 1 to 32 seats**, on top of a constant **+48%** vs a bare pool [MEASURED] | The cost to a customer is a **fixed tick a router can price**, not a penalty that grows as the book gets deeper. |
| Rent **cannot be captured by a flash loan**, and settlement conserves the rent pot to the wei [MEASURED] | The coupon paid to the back cannot be farmed by someone who was not there. |
| Foreclosure **demotes, never seizes** | Running out of prepaid rent costs you your place, not your money. No liquidation, no collateral call, no oracle. |
| **No admin, no upgrade, no privileged role** | Nobody to trust, nobody to lobby, nobody who can change the rent rate after you have bought a seat. |
| The allocator **never reads the position's range** — identical roster allocates to the wei over a ±10% band as over the full range [MEASURED, `test_1_11`] | The thin-depth limitation is a **parameter this version set conservatively**, not something baked into the mechanism. Concentrating the book is v2, unbuilt. |
| The invariant campaign **found three real bugs** in code that had already passed 135 tests | This mechanism was attacked by its own authors and it broke. Everything above is what survived that. |

---

## 14. HONEST LIMITATIONS

Stated at full strength. Nothing here is softened. The standing hazard ledger is [`PITFALLS.md`](PITFALLS.md) §5; this list is not complete without it.

**1. QUEUE does not stop sandwiches.** A sandwich is front-run, victim, back-run. QUEUE changes which LP is the counterparty to each of those three swaps. It does not prevent any of them, does not raise their cost, and does not detect them. The cohort's mission statement is *"Protect LPs · kill the Sandwich"* [SOURCED]. **QUEUE does not kill the sandwich.**

**2. QUEUE does not reduce total LVR.** §11.2 and §11.3 show the total pool P&L identical to the cent. This is not an artefact of the example; it is structural. The swap happened at the same prices either way. QUEUE **reallocates** adverse selection and **prices** it. Any sentence claiming it reduces LP losses in aggregate is false.

**3. QUEUE does not recapture value from searchers.** No auction, no tax, no toll. The one exception: the tight-range JIT queue-jump is structurally unavailable (external adds revert), and the equivalent right must be bought from an incumbent. Recapture on one vector, not on MEV generally.

**4. The bounded seat count makes it a professional venue, not an open retail pool.** 32 seats. Retail participation requires a syndicate wrapper, unbuilt.

**5. The redemption residual is open.** [MEASURED] The queue's face value is **not** exactly redeemable. v4 computes a swap's amounts and a position's redeemable value with two different formulas. The "~0.26 wei per swap" figure holds near the seeded price and **does not generalise** — a pool drained into the float and pushed to the tick floor loses ~1e9 wei on a single swap (`PITFALLS.md` 5.80). What *does* generalise: worst surplus **0 wei**, worst shortfall **under 1 part per billion** of lifetime inflow, borne by the last withdrawers. Not an attack. Still never claim "face value is redeemable."

**6. The lease cannot express a negative seat value.** Under toxic flow every holder declares near zero, no rent flows, the front is free to take. The mechanism behaving correctly, and the point at which the price signal is censored. Unsolved, and not solvable inside this design.

**7. The whole toxicity signal depends on a liquid secondary market in ranks that does not exist.** Weakest point in the design. In a demo, a new pool, or a long-tail pair, there is no market, therefore no price, therefore no signal. No measurement supporting the assertion that it would form.

**8. The band is ±10%, not ±1%.** Depth per dollar is better than the old full-range blob and worse than a tight MM range [ANALYSIS]. Wings restore permissionless depth *outside* the money; they do not make the band itself a ±1% book. Aggregators may still skip +48% compute.

**9. Rent is `currency0`, weighted by `currency0`.** Weighting a two-token basket needs a price and QUEUE is not allowed to have one. A tail holding only `currency1` is paid nothing; the rent waits until an eligible recipient exists.

**10. Enforcement needs somebody to poke it.** No keeper ships and none is required — the seats behind are paid by the poke, and a buyer must poke to clear a delinquent incumbent — but a seat nobody wants and nobody pokes accrues a debt nothing collects.

**11. Native ETH is not a supported deposit/withdraw path.** The unlock helper can settle native; `addToSeat` / `withdraw` talk ERC-20. `address(0)` as a currency blows up. Do not deploy this on an ETH pair and expect it to work.

**12. The allocator is the whole pool's accounting, rewritten by us.** A bug there is not a degraded feature. It is lost funds.

### What IS proven (the riskiest assumption, tested)

Front-first allocation at the swap's realised average price is exact, to the wei, in both tokens, at a non-unit price (1:4 — a 1:1 fixture would have hidden a token0/token1 mix-up). Aggregate flows measured on PoolManager's own ERC20 balances, never on the hook's bookkeeping:

```
queue total token0            2248553145997694428660
PoolManager-measured token0   2248553145997694428660      <- equal, to the wei
queue total token1             445000573750774563494
PoolManager-measured token1    445000573750774563494      <- equal, to the wei
```

Three negative controls, all red, with the revert reason asserted:

| Mutation | Result | Why it actually failed |
|---|---|---|
| PRO-RATA (what v4 genuinely does today) | RED | fill smears across all three entries instead of landing in the head |
| OFF-BY-ONE cursor (start at entry 1) | RED | head untouched, entry 1 filled |
| FLOOR-ONLY (drop the remainder assignment) | RED | token0 conservation on swap 2 — a single-entry fill has no remainder to drop |

The allocation price cannot be manipulated. It is the swap's *own* realised average, from PoolManager's returned `BalanceDelta`. Not a mark, not an oracle, not a quantity the hook chooses.

---

## 15. THEME FRAMING — what a hackathon judge will actually score

> *"UHI10 Hookathon: Sustainable Liquidity & MEV Protection — The goal here is to reduce value leakage from LPs and make volatile-pair liquidity sustainable at low fees — pushing hook innovation toward fair, MEV-protected execution that lets LPs compete on any asset pair."* [SOURCED]

Open problem **#3**, verbatim: *"Dynamic fees alone can't distinguish 'good' retail flow from 'bad' toxic flow."* [SOURCED]

**QUEUE addresses open problem #3, and only #3.** It does not address sandwiches, mempool ordering, or private orderflow. Saying otherwise is the inflated version.

**Does it fall under "sustainable liquidity"? Yes — that half, not the MEV half.** [ANALYSIS] "Sustainable" here does not mean LPs lose less in total. It means **the right capital can choose to stay**: a market maker who wants first fill without posting more size can buy it; a treasury that will not take every small trade can sit last and be paid a coupon; a JIT bot that today jumps the book for free has to buy the head from the incumbent. That is a sustainability argument about *who remains in the pool*, not about the pool's aggregate P&L. It still fails if rent does not actually flow. Do not also claim MEV protection. The theme is two words; we earn one of them.

The bridge, in three steps [ANALYSIS, with the impossibility claims proven in the archive]:

1. **No forgeable-proof toxicity signal exists for a v4 hook.** Trade size, slippage budget, priority fee, identity, history — every candidate is invisible to the hook or free to fake by splitting a quantity, shopping addresses, or waiting one block.
2. **No curve can escape it either.** LVR rate and marginal depth are the same quantity. Halving one halves the other.
3. **Therefore stop classifying and start pricing.** Sell LPs different slices of the flow and let them bid.

An informed trader who slices their order to stay inside the head is **not evading QUEUE** — they are concentrating the informed flow onto the one seat that is explicitly priced. The mechanism never assumed size ⇒ toxicity, so the evasion that defeats every other flow-segmentation design is, here, the design working. That paragraph is only as good as the seat actually being priced, which requires a market that does not exist yet.

### The counters a judge will make

| Counter | Answer |
|---|---|
| "This is am-AMM with extra steps." | One sentence: am-AMM auctions **management of the whole pool to one winner per block**. QUEUE runs **no auction**, has **no winner**, sets **no fee**, grants **no management right**. It sells an ordering over existing LPs' own capital, held by many parties at once. Do not lead with the word "auction." |
| "The theme is MEV protection and you admit you do not stop MEV." | Correct on sandwiches, conceded in §14. Claim the **sustainable liquidity** half: the right desks can stay because fill-slice is a product. On the JIT vector it is defense + recapture (external adds revert; the jump must be bought). Do not also claim sandwich-killing. Open problem #3 has **one** prior attempt in 662, against **189 dynamic-fee hooks** [COUNTED]. |
| "32 seats is not a Uniswap pool." | Correct. It is a professional venue. First minute of the pitch, not the last. |
| "Your toxicity signal needs a liquid market in seats, and there isn't one." | Correct. Weakest point. No measurement that it would form. |
| "Front-first is unfair to the front." | It is not a fairness mechanism. The front is **bought**, from a party who agreed to sell it, at a price they posted. |
| "Uniswap already has priority — swaps cross ticks in order." | That is *price* priority. QUEUE adds an ordering **within** a tick. And that ordering is not *time* priority either. |
| "This is not price–time priority. Your roster is closed." | Correct. Rank goes to rent, not arrival. Free rank is griefable; unbounded rank is worthless; scarcity is the mechanism; the lease is what stops scarcity becoming a cartel. Pre-empt this. An informed listener forms it in twenty seconds. |

---

## 16. WHAT WOULD MAKE UNISWAP ACTUALLY WANT THIS

[ANALYSIS] throughout. The shipping hook is a spike that proved queue arithmetic. Uniswap will not adopt a full-range 32-seat blob as a primitive. These are the combinations that are real, ranked.

### 16.1 Per-tick seats — the interesting idea, and the one that is not a config change

**Yes, that is more interesting for Uniswap.** It is also not what ships, and it is not "set MAX_SEATS per tick."

v4 already has **price** priority: nearer ticks fill first. What it does not have is an ordering **among LPs at the same tick**. That missing half is the whole pitch. The shipping hook implements the half by **destroying the ticks** — one blob, one line. Per-tick (more honestly: **per-seat ranges**) keeps Uniswap's product and adds the queue *inside* it:

```
v2 — PRICE THEN QUEUE                         NOT this: 32 queues × every tick
─────────────────────                         ────────────────────────────────
Each of 32 seats picks its own tick range     Unbounded ticks × 32 seats is
like a v3 NFT.                                not a program.

A swap fills in-range seats first             afterSwap hands the hook ONE
(price priority, already v4).                 delta, not a per-tick tape.
Among those currently in range,               Reconstructing who contributed
rank 0 then rank 1 (the QUEUE half).          was the riskiest assumption.
Depth of a ±1% book, plus a priced
intra-tick order.
```

**[MEASURED] 2026-08-31.** `test/spike/PriceThenQueue.t.sol`, 8/8. A SwapMath replay over a three-band ladder (below / at / above, non-overlapping) attributes a crossing swap **to the wei** against a real PoolManager: sum of per-band fills = PM delta net of protocol fees; the untouched wing gets 0. A mutant that smears the same delta by L is red — it credits the wing v4 did not touch. There is no tick-crossing hook flag (`Hooks.ALL_HOOK_MASK` is 14 named bits). Verdict and the build order: `docs/research/price-then-queue/SPIKE.md`.

`test_1_11` still does **not** prove this. It proves the allocator is orthogonal to the range of **the one custodied position**. Fastest v2: **concentrate that one blob**. Next: the 3-band ladder this spike measured. Arbitrary overlapping per-seat ranges are **UNPROVEN** and are v3, not a config change.

**Do not build 32 queues per tick.** Gas, state, and the afterSwap information-set all say no. **Do not take over the swap with `beforeSwapReturnDelta`.** That would be a new AMM. The spike did not.

### 16.2 Other combinations worth taking seriously

| Idea | Why Uniswap / a judge would care | Honest cost |
|---|---|---|
| **Concentrate the one position** | **DONE.** Fixed the 1/200th-depth hole; half-width is a deploy parameter. Allocator proven orthogonal (`test_1_11`). | Out-of-range behaviour is now the honest limitation: the band does not move, and `recenter()` was deleted after our own attack broke it three ways. |
| **Per-seat ranges** (16.1) | Actual missing half of price–time priority. The Foundation-shaped object. | Ladder walk **MEASURED** to the wei. Overlapping arbitrary ranges UNPROVEN (v3). |
| **JIT as a one-block head rental** | Already possible: `buySeat` → harvest → re-ask. Makes the free jump *pay the incumbent*. Demo this; do not redesign for it. | Firm window, buyout capital, rank-then-run for an hour. |
| **ERC-4626 syndicate vault** | Retail can buy a slice of a seat. "Sustainable liquidity" at more than 32 names. | Recreates the intermediary §4 claimed to delete. Unbuilt. Needed if you ever want non-professional LPs. |
| **Two-sided rank** (bid queue ≠ ask queue) | Fixes the Ratchet: tail currently accumulates at extremes and has no priority to exit. Premise-review B-2. | Two order words, twice the rent story. Not a hackathon add-on. |
| **Compose with a limit-order hook** | Opposite side of the market. Limit orders queue *traders*; QUEUE queues *LPs*. A fill can hit a ranked LP book. | Integration, not a merge. 17 prized limit-order hooks already exist. |
| **Compose with TWAMM** | TWAMM is time-sliced *flow*. QUEUE is ranked *inventory*. Time-sliced flow walking a ranked book is a story. | Two hooks on one pool is a v4 permission and routing problem. |
| **"Head price as a toxicity index" for other protocols** | Other hooks could read `selfPrice` of rank 0. | Censored at 0 on the toxic side. Do not sell an oracle you admitted cannot go negative. |
| **Dynamic fee / am-AMM / LVR auction** | 189 dynamic-fee hooks, 7 am-AMMs, Atrium AVOID on LVR auctions. | **Do not.** Saturated, and it muddies the one-sentence pitch. |

**What not to do:** add an admin, a keeper, a classifier, or a curve. Those are how this project already died, several times.

The adoption path for Uniswap is: **shipping proves the arithmetic (done) → the band plus ordinary Uniswap wings (done, this is the integrable object) → per-seat ranges (not shipping, a different product).** Pitching 32 NFT ranges or a closed full-range blob as what Uniswap should run is how you get Impact 2. The wings are how a Uniswap team can LP this pool tomorrow without buying a seat.

---

## 17. HOW TO SAY THIS TO A CFO IN NINETY SECONDS

> This is not an order book and it is not Uniswap. Same AMM price, same trading fee, any router. Thirty-two paid chairs in front of the same inventory: the front is filled first and pays the back to stand there; anyone can buy a chair at the occupant's posted price. You are not buying safer trades or lower losses in total. You are buying a **ranked split of the same P&L** among 32 professionals, at a fixed extra processing cost per trade — about 36% more network compute on a typical swap, which on an L2 is cents, and which does not grow with how many chairs are filled.
>
> Use it if you already have a pit of professional desks who want first fill without posting more capital, and passive capital that will sit behind for a coupon. Do not use it if you wanted a public pool, sandwich protection, or anyone-can-LP. The 32 can empty the book the way any thin market-maker list can pull quotes; they cannot seize it, pause it, or trap withdrawals. The dangerous version of that fear is not a crash. It is the 32 posting a price of zero so the coupon stops, and you are left with a thinner, slightly more expensive ordinary pool.

---

## APPENDIX — the one-paragraph version

Every concentrated AMM is a pro-rata market: within a tick, every LP is filled in proportion to size and no LP can be first or last. Every real electronic market already prices queue position — implicitly, in latency spend burnt on infrastructure rather than paid to the people being jumped. Uniswap's choice did not make ordering worthless; it made it unpriceable *inside* the pool, so it is captured *outside* it. QUEUE gives a Uniswap v4 pool a transferable, continuously-priced rank in the fill order. Rank is scarce **on purpose** (free rank is griefable, unbounded rank has no price) and leased rather than owned, so a scarce roster cannot become a cartel. The front is filled by every swap; the back only by swaps large enough to sweep to it. Front-first allocation at the swap's own realised average price is exact to the wei, executed against a real PoolManager at a non-unit price, with three negative controls red. It does not stop sandwiches, does not reduce total LVR, and does not tax searchers. What it does is turn adverse selection from an unpriced compulsory cost into a priced, transferable position — among 32 professional seats, on a book that is a specialist venue, not a public pool. The price of the front seat is only as good as the market in seats, and that market does not exist yet. Both "near zero" and "high" would be results. Claiming to know which in advance is the thing that would make this uninteresting.
