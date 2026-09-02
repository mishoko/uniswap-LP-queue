# QUEUE

**A Uniswap v4 hook that lets the people putting up the money buy and sell their place in line — so whoever wants to be filled first pays whoever is willing to go last.**

> ## ⚠ CORRECTED 2026-09-02 (Phase 9) — READ THIS BEFORE THE BODY
>
> The mechanism below is accurate. **The product description is not**, and it has now been corrected
> twice. This version is derived rather than asserted, and the derivation is reproducible:
> `python3 docs/research/seat-economics/frontier.py`.
>
> **0. 🛑 SETTLED — THIS MECHANISM CANNOT CREATE SURPLUS FOR ITS PARTICIPANTS, BY IDENTITY.**
> A static Uniswap position over exactly this pool's band returns **exactly** the pro-rata LP return
> (measured to 4.3e-14). Rank 1 can hold one for free. So its outside option `B₁ ≥ LP` by
> construction, and `SLACK = c₁·(LP − B₁) ≤ 0` **before any measurement**. No φ, no ordering rule, no
> roster, no band width changes it. Point 1 below is the correct formula; the "+1.1%/yr" once
> published against it came from using a *keeper bot* as the bar — a strategy, not a bar. Rank 1's
> alternative set contains ordinary passive LPing. **Do not quote any positive surplus figure.**
> See `docs/research/seat-economics/FRONTIER.md` and PITFALLS 5.156.
>
> **1. THE VALUE OF THIS MECHANISM IS A FORMULA, AND IT IS SMALL.** With `c₁` = rank 1's share of the
> capital, `LP` = what a passive LP earns and `B₁` = what rank 1 would earn doing its next best
> thing, the surplus the whole roster can share is
>
> ```
>            SURPLUS  =  c₁ × ( LP − B₁ )
> ```
>
> Rank 1's own return **cancels** — and so do the roster size, the ordering rule, the premium's
> weighting and φ. Confirmed to 2.4e-16. **The "0.19 pp / 1.1%/yr" once quoted here is RETRACTED —
> see point 0 above: `B₁ ≥ LP` by identity, so the value is ≤ 0.** See
> [`FRONTIER.md`](docs/research/seat-economics/FRONTIER.md).
>
> **2. SO IT ONLY WORKS FOR CAPITAL THAT CANNOT SIMPLY BE AN LP.** Set `B₁ = LP` — a yield seeker's
> alternative — and the surplus is **exactly zero**, at any φ. QUEUE is for *constrained* capital: a
> desk that must hold at-the-money inventory, a treasury working a position, an issuer distributing
> supply. **The size of the product is the size of the constraint.**
>
> **3. THE PREVIOUS HEADLINE WAS MEASURED AGAINST A HANDICAPPED COMPETITOR.** "Rank 1 beats a keeper
> bot by 30–758 points" was computed with the keeper swept only to 5% width. At the band's own 10%
> the keeper does **zero re-mints**, pays ~0 conversion cost, and beats every narrower setting —
> against which **every published φ window was empty, including the shipped φ = 7,900.** See
> PITFALLS 5.136.
>
> **4. IT SHIPS FIVE SEATS, NOT 32, AND `c₁` IS WHY.** Surplus is *linear* in the head's capital
> share, so a deep roster is worth **11× less** than the shipped one at any bar (`c₁ = 0.333` vs
> `0.031`). The RATIO is the point; the magnitudes once quoted here are retracted and the value is
> ≤ 0 either way. `MAX_SEATS = 32` is structural — one byte per rank in a 32-byte word — and was never an
> economic recommendation. Every "32 desks" below should read "five".
>
> **5. RANKS 2–5 ARE A POOL, NOT A LADDER.** Adjacent-rank separation is 2.37 between seats 1 and 2
> and 0.01–0.09 everywhere else. The premium is shared by depth contributed, not by rank.
>
> **6. IT IS A FIXED-TERM INSTRUMENT AND THAT IS THE PRODUCT.** The band never moves; expected life
> is 61 days benign / 19 normal / 1.4 toxic. Rolling it would require holding both tokens while
> holding one — a trade at market, which is exactly the cost rank 1 is here to avoid. **The term is
> the boundary of the property being sold.** Band width is a deploy parameter: life scales as
> `width²`, depth as `1/width`.
>
> **7. GAS: +119%** — 152,947 against 69,970, same swap, same storage state. The figure has been
> wrong twice before, both times in our favour.
>
> **WHAT IS STILL NOT ESTABLISHED:** what a buyer will actually PAY for first fill. We measured what
> the property costs to replicate; we did not measure demand, and no simulator can. That question
> decides whether this product exists.

Think of a shop with a **paid counter** and a **public warehouse**.

- Around today's price (~±10%) sit **32 paid desks**. Desk 1 serves every customer. Desk 32 only serves a customer so large that 1–31 are already empty. You buy a desk. You pay rent to the desks behind you. Anyone can take your desk at the price you posted.
- **Away from today's price**, anyone can put up cash the ordinary Uniswap way. No desk. No rent. Same old "everyone is hit a little."
- Every desk that serves a customer hands **85% of the fee it just earned** to the desks still waiting behind it. That is the price of standing in front of them, and it is why desk 32 is worth funding at all.
- The **customer** still walks in through any Uniswap router, pays the same 0.30% shop fee, and gets the same price. They never talk to the desks. They do pay **~119% more network compute** on a typical swap (153,177 vs 69,970 units). That is a longer checkout, not a worse bill of goods. On an L2 it is cents. Routers that optimise for gas may still skip this pool.

It is not sandwich protection. It is not a cheaper trade. It is not Uniswap-for-everyone. If you do not have professional desks that want *first fill* and other capital that wants to be *paid to wait*, this is the wrong product.

---

## In 90 seconds, for someone who does not live in DeFi

A Uniswap pool is a shared cash register. When a customer trades, **every** cash provider behind that register is hit a little, in proportion to how much they put in. Nobody is first. Nobody is last. The only way to get more of the action is to put more money in.

That is not how any other market in the world works.

On the NYSE, on Nasdaq, in FX, in futures — **being first in line is an asset**. Firms spend hundreds of millions of dollars on microwave towers and colocation just to stand at the front. The people they jump in front of are not paid. The money goes to the tower vendors. On a blockchain the same value is sold by whoever orders the block. The pool's own cash providers get none of it.

QUEUE does one thing: it puts a **numbered line** inside a Uniswap pool, and it **sells the numbers**.

- Seat 1 is filled by every trade that arrives, including the small ones.
- Seat 32 is filled only when a trade is so large it has already emptied seats 1 through 31.
- You cannot join by arriving first. You **buy** a seat from whoever holds it, at a price they posted themselves.
- **Every time you are filled, you hand most of the fee you just earned to the seats behind you.** This is the mechanism, and it is worth being precise about why.

  We measured what each rank actually earns over 30 simulated price paths. Seat 1 turns its inventory over **411,877% a year** and earns **1,240%** of its own capital in fees. Seat 32 turns over **34%** and earns **0.1%**. Seats 2–31 trade just often enough to be picked off by the large moves and almost never often enough to collect a fee for it — which is why, with nothing flowing backwards, **24 to 29 of the 32 seats lose money in every regime we tested.**

  The front's advantage is a **quantity**, not a price. So the only thing that can pay for it is a share of the **fee flow** — not a tax on an assessed value, which at any sane rate is ~6%/yr against a 20–160%/yr drag. Hence: a filled seat keeps 15% of its fee and the rest goes to whoever is still standing in the line it jumped, in proportion to the inventory they are standing there with.

- While you hold the front, you **also pay rent** to everyone behind you, and the seat is **always for sale at a price you post yourself**. Under-price it, you lose it. Over-price it, you pay for it. That is how a closed roster of 32 lets new capital in.

The customer on the other side of the pool does not see any of this. They trade through the same Uniswap router, at the same price, at the same trading fee. The line is among the **cash providers**, not among the customers.

**This is not an order book.** An order book lines up *customers' orders* ("I will buy if the price hits $3,000"). QUEUE lines up *the people putting up the money* ("fill me first" vs "fill me last and pay me for waiting"). There is no limit price, no matching engine, and no cancel button. The customer never talks to the queue.

---

## The verdict, before the pitch

| Question | Honest answer |
|---|---|
| Is it well built? | **Yes, as accounting — and we keep proving that is not the same as correct.** 316 tests. Three real bugs were once found in code that had already passed 135. Most recently the mutation campaign ran **85/85 red, zero survivors**, while an expert panel reading the same source found **four more defects that sailed straight through it** — because the mutations had been written against the same mental model as the tests. One of them (`recenter()`) was deleted rather than patched, then rebuilt — and the rebuild passed all eight of its own tests while failing the invariant campaign, so it is **still not shipped**. This is not an audit. |
| Is it interesting? | **Yes, as a missing product.** Uniswap has run one fill rule for seven years. Nobody has been able to price "being first." QUEUE is the first pool where that number exists on-chain. 0 of 662 prior hook submissions sold an ordering over LP capital. |
| Does it make Uniswap better for ordinary users? | **No.** Same price, same fee, extra network cost, thinner book. The trader is not the customer of this product. |
| Does it stop MEV / sandwiches? | **No, and claiming it does is mis-selling.** The hackathon theme is two halves. QUEUE can claim **sustainable liquidity** (the right desks can choose to stay). It cannot claim MEV protection. |
| Does it make LPs lose less in total? | **No.** Total pool P&L is identical. QUEUE **redistributes** who bears a bad trade, and **prices** that redistribution. Anyone who writes "QUEUE reduced LP losses" is lying. |
| Who is this for? | **The front desk, and — at the shipped parameters — essentially nobody else.** See the next row; this is the most important line in the document. |
| Is a back seat worth buying? | **Only inside a window, and we can name it.** A seat the trade never reaches is never written — so it is not an LP position at all, it is a static basket, and a basket that does not trade has **zero LVR**. That is loss avoidance, not deferral: the conversion never happened. So a tail seat **declines the arbitrage half of the flow and gives up the retail half.** In this pool's decomposition a pro-rata dollar earns `+32.85%` from retail and `−21.90%` from arbitrage, net `+10.95%`, and cannot decline either half. **Buy the deep tail when your pool loses more to arbitrageurs than ~89% of what it collects in fees; stop above ~168%, where a plain wallet dominates.** Below that window ordinary LPing wins outright. Full arithmetic, the trough, and the deployment rule in [`BUSINESS.md` §0.5](BUSINESS.md). |
| What does a seat actually earn? | **Less than the annualised tables suggest, because the band is fixed.** `recenter()` is not shipped, so the pool is a **fixed-term instrument** — a ±10% band on a 45%/yr-vol pair has an expected in-band life of ~16–18 days. The tail's whole lifetime edge is **~2.2% of capital, once, plus a coupon worth ~0.13%**. Band width is now a deployment parameter and is the dial that pays for this: in-band life scales as `w²` while depth scales as `1/w`, so **doubling the band quadruples the life and only halves the depth**. The shipped ±10% is sized for a demo, not a deployment. |
| Who should NOT buy one? | Anyone at ranks 2–4 of a naively sized roster. Depth past the largest *noise* trade sees only large trades, and large trades are the informed ones — so the middle of the book takes **all the toxicity and none of the fees** (−241%, −110%, −22% on capital at 60 bps markout, while rank 1 is +723%). The fix is a sizing rule, not a code change: **make the head seat's capital the largest routine *informed* trade**, and no trough seat exists. |
| Should a business person be afraid of it? | They should be afraid of **the closed club and the extra cost**, which are real. They should not be afraid that "32 people cancel and the pool explodes" — that is the wrong picture of the machine. Details below. |

---

## Does this make sense? Only in these cases

```
USE IT                                              DO NOT USE IT
──────                                              ─────────────
The pair already has ~10–30 serious                 You want anyone with $50 to
market makers, not thousands of retail LPs          provide liquidity

Someone wants FIRST FILL without putting            Everyone in the pool wants the
up more capital, AND someone else wants             same thing — then ordinary Uniswap
LAST FILL plus a coupon                             is correct and cheaper

You are building a professional venue:              You are competing with a vanilla
a designated-market-maker book, an RWA              ETH/USDC pool for retail aggregators
desk list, a permissioned stable pair

You want a public number for                        You need the pool to stop
"what is being first actually worth?"               sandwiches, or to make LPs lose
                                                    less in total. QUEUE does neither.

The desks can hedge elsewhere                       The LPs cannot hedge and cannot
                                                    rebalance. The back seat is not "safe."
```

**One line:** QUEUE is a **membership market for fill priority**. The membership fee is paid to the members you are standing in front of, not to an exchange.

If that sentence does not describe buyers you have, this is the wrong object.

---

## Does this even make sense?

**Sometimes. Not for a public ETH/USDC pool.**

Every Uniswap pool today fills every cash provider a little, in proportion to size. That is fair, and it is also why being first is worthless *inside* the pool and valuable *outside* it (to whoever orders the block, and to firms that spend on latency). QUEUE makes "being first" a chair you can buy, with rent paid to the people you are standing in front of.

| Player | What they get | What they pay | Do they want this? |
|---|---|---|---|
| **Shopper (end user)** | Same tokens out, same 0.30% fee, any Uniswap router. They do not see the queue. | ~119% extra network compute on a typical swap. On an L2: cents. Not 48% of the trade. | **Usually no.** They get nothing extra. Aggregators may route around this pool for that reason. |
| **Desk at the front** | Every small trade, 100%, on a fraction of the capital. Like paying for the specialist post on the NYSE instead of a microwave tower. | Rent to the desks behind, plus the risk that this trade was informed. | **Yes, if they can hedge elsewhere.** |
| **Desk at the back / treasury** | Paid to wait. Only hit by trades large enough to empty everyone ahead. | Forgoes most fee income on quiet days. Large trades are often the informed ones — not "safer." | **Yes, only if rent actually shows up.** |
| **Ordinary Uniswap LP (outside the paid desks)** | Normal Uniswap. No seat, no rent. Filled only when a trade is so large it has already walked through the paid desks. | Nothing extra. | **Yes, as optional extra depth.** They are not buying the product; they are using Uniswap next to it. |
| **The pool / process** | A public number: what people will pay to be first. Liquidity that can *choose* its place in line instead of being smeared. | Extra compute. A 32-name club at the money. | Useful as an **experiment** Uniswap has never been able to run. Not a default for every pair. |
| **Router / aggregator** | Same interface: `V4SwapRouter` / any v4 router. No custom router. The pool *is* a Uniswap pool; the hook is on the key. | The extra gas is visible. Routers that rank by gas will prefer a hookless pool at the same price. | They will **serve** it if someone swaps this pool. They will not **prefer** it. |

**NYSE analogy, not a crypto one.** On the NYSE, designated market makers buy a seat, stand at the post, and pay for the privilege of seeing flow first. The public can still trade. Nobody claims the specialist post makes the *customer's* commission cheaper. QUEUE is that seat, inside a Uniswap pool, with the rent paid to the other seats instead of to an exchange.

**Why would anyone pay ~50% more gas?** The shopper should not, and mostly will not, unless they are already swapping this pool (professional venue, RWA book, a pair the desks chose). The *desks* pay it because they chose this book: they want first fill without posting more capital, or they want the coupon for standing last. The extra compute is the cost of keeping a numbered line on-chain. It is a constant, not a tax that grows with 32 desks (21 units of difference from 1 seat to 32 on a normal trade).

---

## How Uniswap's router sees this

Tightly coupled to Uniswap as it works **today**. Not a new AMM. Not a forked router.

```
Customer
   │
   │  ordinary Uniswap router  (Uniswap, 1inch, a frontend — same as any v4 pool)
   ▼
PoolManager.swap
   │
   ├─ Uniswap walks PRICE first (nearer ticks fill first). Unchanged.
   │
   ├─ around today's price (~±10%):
   │     32 paid desks, filled FRONT-FIRST
   │     Desk 1 emptied before desk 2 is touched
   │
   └─ further away from today's price:
         ordinary Uniswap LPs, filled the usual way (everyone a little)
         minted with Uniswap's own Position Manager. No desk required.
```

A small $3,000 sale of token A:

```
TODAY (every Uniswap pool)                  QUEUE (paid desks at the money)
──────────────────────────                  ──────────────────────────────
$3,000 hits EVERYONE a little               $3,000 hits Desk 1 only

Alice  2% of the till →  $60 of the trade   Desk 1  $20k  →  takes the whole $3,000
Bob    5%            → $150                 Desk 2  $50k  →  not touched
Carol 10%            → $300                 Desk 3 $100k  →  not touched
...                                         ...
                                            Desk 1 pays rent to 2–32 for that privilege.
                                            Customer got the same price, same 0.30%.
```

A *huge* trade that blows through today's price: the paid desks are emptied first, then ordinary Uniswap liquidity further out takes the rest. That is Uniswap's price order, then QUEUE's line inside it.

You **cannot** put ordinary Uniswap liquidity *on top of* the paid desks. That would be cutting in line for free. The contract refuses it.

If the market price walks more than ~10%, the paid desks go out of range and stop earning — exactly like any concentrated Uniswap position that the price has left behind. **The band does not move.** A `recenter()` was built, deleted, rebuilt and left out again — v1 could plant the desks on top of somebody else's liquidity and destroyed the position's depth when it ran; v2 fixes all of that, passes eight targeted tests, and **fails the invariant campaign for a reason we have not found**, so it does not ship (`docs/wip/recenter-v2/`). Holders withdraw and a new pool is deployed. **QUEUE is a rolling fixed-term instrument, not a perpetual venue** — ~16 days of in-band life on a 45%-vol pair — and band width is chosen at deployment to set that term: in-band life scales as `w²` while depth scales as `1/w`, so doubling the band quadruples the life and only halves the depth.

---

## What a "queue" is here — the word is doing too much work

In ordinary English a queue is: you arrive, you stand at the back, you wait, you get served.

**QUEUE is not that.** Pretending it is will lose a room that knows markets in thirty seconds. Think **NYSE seat**, not **DMV line**.

```
ORDINARY QUEUE                          THIS PRODUCT
──────────────                          ────────────
Arrive → join the back                  There is no "join the back"
Position = who got here first           Position = who pays the rent
Anyone can enter                        32 seats. Always.
Free                                    Paid, continuously
You cannot be jumped                    You CAN be bought out, at your own price
Leaving the line gives up your place    Taking your money out does NOT destroy
                                        the seat. An empty seat is still a
                                        numbered place, still for sale.
```

The ordinary version is dead on arrival, and this repository has the corpse:

1. **If arriving first gets you the front, the front costs one wei.** An attacker deposits dust, owns every small trade forever, and the real cash providers get the leftovers. That was version 1 of this hook.
2. **If anyone can join, a "place in line" is not scarce.** Something that is not scarce has no price. With no price, the people at the back are not paid. Then nobody wants the back. Then the product is "whoever got here first has a free option on everyone else's flow."

So: **32 paid seats, always for sale.** Scarcity is the product. The always-for-sale lease is what stops scarcity from becoming a cartel.

> **Scarce, but never capturable.** A bounded roster without the lease is a cartel. A lease without a bounded roster prices nothing. That pairing is the whole design.

---

## What a Uniswap engineer is looking at

Uniswap already orders by **price**. QUEUE orders the cash providers **at that price**. One concentrated Uniswap position (width chosen at deployment; ~±10% by default), 32 seats sharing it, not 32 NFT ranges. Ordinary Uniswap liquidity is allowed only *outside* that position. The band is written once at initialisation and never moves — which is what makes the no-overlap rule a complete guard rather than a snapshot of a moving target.

A seat **can hold only one of the two tokens**. After a fill, the front usually does. Depositing both in the current ratio is how you add *depth*. Depositing one typically mints **zero** liquidity — the tokens sit as a claim in the float. Rent is paid in token0, weighted by token0.

This project is **only the queue**. There is no sandwich shield and no new curve. The buy-in *is* the product: liquidity in, ask posted, fees ± markout ± rent.

### Being first is a trade-off, not a gift

A swap does not execute at one price — it sweeps a **range** of them. Being first in line means being filled first, and the first fills happen at the **stalest** end of that range. QUEUE credits each seat the price segment it actually absorbed, so the head systematically fills *worse* than the swap's own average and the seats behind it fill *better*, in both directions. It is asserted, not asserted-about: `test/queue/Marginal.t.sol`.

This is the one place the mechanism changed late, and it changed for a reason worth stating. The hook used to credit every seat the swap's **average** price, which handed the head all of the volume *and* the same price as the seats behind it. Simulated across benign, normal and toxic pools, that made the head beat an ordinary Uniswap LP **in every state of the world** — including the toxic one that exists precisely to punish whoever is first into a stale price. A position that wins in every state is not a market position, it is a subsidy paid by the rest of the book. Under segment pricing the head loses to an ordinary LP in the toxic regime, which is what makes the rent it pays defensible rather than extracted. Evidence and the simulation: [`docs/research/seat-economics/`](docs/research/seat-economics/).

It is close to free where it matters: a swap the head absorbs alone — almost every trade — never builds a price curve at all and pays **+223 gas**. Only a trade large enough to walk several seats pays for the walk.

**Move the sliders:** open [`frontend/index.html`](frontend/index.html). Worked numbers: [`BUSINESS.md`](BUSINESS.md) §11.4. The measured walk that would let seats sit in *different* bands later: [`docs/research/price-then-queue/SPIKE.md`](docs/research/price-then-queue/SPIKE.md). Not shipping.

---

## Two cash registers, same customer, different staff

A $3,000 customer trade. Same price. Same 0.30% trading fee. Five cash providers, 

$1,000,000 in the till.

```
TODAY — every Uniswap pool                     QUEUE
──────────────────────────                     ─────

  Customer sells $3,000                         Customer sells $3,000
  Price: the same                               Price: the same
  Trading fee: 0.30%                            Trading fee: 0.30%
           │                                             │
           ▼                                             ▼
  ┌─────────────────────────────┐             ┌──────────────────┐
  │  THE WHOLE TILL, mixed      │             │ Seat 1  $20k     │ ← emptied
  │                             │             ├──────────────────┤
  │  Alice  2%                  │             │ Seat 2  $50k     │   untouched
  │  Bob    5%                  │             ├──────────────────┤
  │  Carol 10%                  │             │ Seat 3  $100k    │   untouched
  │  Dana  30%                  │             ├──────────────────┤
  │  Eve   53%                  │             │ Seat 4  $300k    │   untouched
  └─────────────────────────────┘             ├──────────────────┤
           │                                  │ Seat 5  $530k    │   untouched
           ▼                                  └──────────────────┘
  Everyone gives up the same fraction
  of their pile. Alice, with 2% of            Alice (seat 1) took 100% of a
  the money, got 2% of the trade.             $3,000 trade on $20k of capital.
                                              That is 50× more flow per dollar.
  There is nothing to buy.                    She also ate 100% of the risk
  There is nothing to sell.                   that this was a bad trade.
                                              She pays rent to Bob–Eve for that.
```

The customer's bill did not change. Only **who inside the till took the trade** changed.

On a *large* trade that walks several seats, the front is emptied and the back is barely touched. On a *toxic* day (informed one-way flow), the front takes the beating and the back is paid to have stood aside — **if rent is actually flowing.** On a *quiet profitable* day the back forgoes fee income. **Both seats cannot beat ordinary Uniswap at once.** The rent is the transfer that makes the back's deal rational. Without rent, the back is strictly worse in the regime where LPing is profitable.

---

## Who pays whom

```
                 RENT (continuous, prepaid)
   Front-seat LP ──────────────────────────► Back-seat LPs
   (market maker                          (treasury, vault,
    who wants flow)                        anyone paid to wait)
         │                                        ▲
         │ buys the seat                          │ receives the buyout
         │ at the posted price                    │ if they sell — or the
         ▼                                        │ rent if they stay
   Seat changes hands ────────────────────────────┘
   (anyone, any time, at the holder's own number)


   Customer ──► ordinary Uniswap router ──► pool
                same price, same trading fee
                plus a fixed extra network tick
                (see "network compute" below)
                The queue is invisible to them.
```

No new tax on the customer's trade. No cut for the protocol. The rent is a transfer **between two kinds of cash provider that already exist in every pool**.

The founding 32 names are an **endowment**, not a purchase — whoever deploys picks them, the way an exchange's first memberships were granted and then traded. Every founding seat starts unpriced, and an unpriced seat is **free to take**. After one transaction the seats belong to whoever values them. There is no admin to undo that.

---

## Why 32 seats, and why not 100 or 500

Three reasons. They are different. Do not conflate them on a slide.

**1. The whole line fits in one computer word.**
The order of the 32 seats is 32 bytes — one byte per seat number. Pushing someone to the back rewrites the entire line in a single write. Walking the line reads the entire order in a single read. **Raising the cap past 32 is a redesign, not a config change.** At 33 seats the current packing silently truncates; a test exists specifically so that cannot ship.

**2. Adding money to a seat gets expensive as the roster grows.**
A *normal* customer trade only hits seat 1. That cost is **the same at 1 seat as at 32 seats** (a 21-unit difference — noise). A trade big enough to empty the whole line costs extra per seat it walks. At 32, that worst-case trade still fits a conservative budget.

What actually binds is **depositing**: paying rent owed to everyone in front, each of whom pays everyone behind. That is quadratic in the roster. Measured worst case at 32 seats: **2,610,805 compute units**, 8.7% of a block. At 100 that path is a block-filling weapon. At 500 it is not a program this version can run.

Unlimited seats do not fail gently: they **break the honest large trade** while an informed trader splits their order and goes through anyway.

**3. 32 is roughly how many serious market makers sit on any given pair.**
The *money* per seat is unlimited — one seat can hold a billion dollars. Only the *numbers in line* are scarce. If they were not scarce they would have no price, and the product disappears. This reason would still apply if compute were free.

```
                    1 seat      32 seats       100 seats        500 seats
Normal trade        same        same (+21)     would be same*   would be same*
Walk-every-seat     cheap       ~416k units    ~1M+             fails
Add money to a seat cheap       2.6M worst     likely a block   impossible
What it is          monopoly    a franchise    getting cheap    free → no price

* if the "only touch the front" shortcut still works
```

**Could it be 8 or 16?** Yes. Tighter franchise, more like a designated-market-maker pit. **Could it be 64?** Not without the unbuilt redesign that makes walking the line a constant cost. **Is 32 Uniswap-for-everyone?** No. Say that in the first minute.

---

## The network-compute cost — it is not "customers pay more"

This is the number that will kill the pitch if you say it wrong, and **the figure this file used to
quote was wrong in our own favour.**

**CORRECTED 2026-09-01.** The old "+48%" compared a QUEUE pool against a plain pool **that had never
traded**, so the control was paying its own one-time storage-initialisation costs — costs a real pool
pays once in its life — and the comparison flattered us. Measured with both pools in the same state,
one swap through each first:

| | network compute, typical swap | vs a hookless pool |
|---|---|---|
| Plain Uniswap v4 pool, no hook | 69,970 | — |
| QUEUE, priority premium off | 131,821 | **+88%** |
| **QUEUE as shipped (φ = 8,500)** | **153,177** | **+119%** |

So a typical trade through QUEUE costs about **2.3× a hookless pool**. Roughly half of that is the
book existing at all; the rest is the priority premium — the mechanism that pays the back of the book
and is the reason 31 of 32 seats are worth funding.

What it actually is:

| | |
|---|---|
| A trading fee? | **No.** The pool's 0.30% (or whatever was set) is unchanged. |
| A worse price? | **No.** The customer gets the same tokens out. |
| Extra network cost? | **Yes.** Like a slightly longer checkout taking a slightly larger card-processing tick. |
| Same at 1 seat as at 32? | **Yes, for a normal trade.** Head-only is flat (21-unit spread across the whole roster). The overhead is the cost of the pool *having a book at all*. |
| Always 2.3×? | **No.** If a single trade is large enough to walk many seats, add ~14,777 units per extra seat. A full 32-seat walk is a ~997,000-unit transaction. That is a large, unusual trade — one that drains the entire book. |
| Dollars? | This product belongs on an L2. ~93,000 extra units is **cents or less**, not 119% of the notional. On Ethereum mainnet it would be a real bill. **QUEUE is an L2 product.** |

The honest commercial risk is not "customers pay 119% more." It is: **routers pick the pool with the same price and the lower network cost.** If they skip QUEUE, this pool does not see retail flow. Retail flow is the "good" flow the front seat wants. That loop is the adoption problem, and it is not solved.

---

## "What if the 32 cancel at once and the pool dies?"

The right instinct. The wrong machine. Translate it.

**There is no cancel button on a trade.** Customers cannot cancel the queue. They never see it.

**A cash provider can take their money out of their seat at any time.** Taking the money out does **not** destroy the seat. An empty seat is still a numbered place in line, still for sale, still collecting or paying rent. The line stays 32 long.

```
32 seats, all funded                      32 seats, 30 emptied
────────────────────                      ────────────────────
Deep book, small trades                   Thin book, same prices
hit seat 1 and stop                       A $3,000 trade now walks
                                          further and moves the price more

The pool does not "fail".                 The pool does not "fail".
It is the same as any market              It is the same as any market
where liquidity walks.                    where liquidity walks.

If ALL money leaves:                      The 32 seat tokens still exist.
trades still execute, with                Anyone can buy a seat and put
almost no depth — i.e. a                  money back in. There is no
pool nobody is using.                     admin to call. There is no
Same as a Uniswap pool                    pause switch.
whose LPs all withdrew.
```

**What is actually different from a normal pool:**

- **Concentration.** A normal Uniswap pool can have thousands of LPs; losing 32 of them is noise. Here, 32 *is* the whole market. A panic, a better venue, a regulatory event — 32 desks can actually empty this book. That is real. It is the cost of a franchise, the same as a thin CEX market-maker list pulling quotes.
- **They cannot all "cancel the seat."** They can empty it. Someone else can take it at the posted price. If they set the price at zero, it is free to take. If they set it enormous and stop paying rent, they are **pushed to the back automatically** — they keep their money, they lose their place. Nothing is seized.
- **A simultaneous-buyout storm does not halt the pool.** Taking a seat pays the current holder and sends their capital back to them. The new holder is empty until they deposit. Brief thinness, not a halt.
- **There was a real bug, now fixed**, where a withdrawal or a buyout could revert at a tick boundary — that *would* have been "the incumbent can veto being bought out." It was found by attacking the code after 135 tests had passed. Closed.

The failure mode of "everyone leaves" is **"the pool is empty,"** not "the pool is seized." There is no admin, no upgrade, no pause.

The failure mode the pitch should actually fear: **the 32 collude, post a price of zero, and rent stops.** Then the transfer that makes the back's deal rational dies, the head still eats flow, and you have ordinary Uniswap with extra network cost and a thinner book. Harberger assumes an outsider with capital. A founding roster of insiders may not provide one.

---

## Pros and cons — do the benefits outweigh?

### The customer (the trader)

| Pros | Cons |
|---|---|
| Same price. Same trading fee. Any Uniswap router. They never touch the queue. | +119% network compute on a typical swap. A constant, not a slope. |
| | A very large trade that walks many seats costs more still. |
| | **CLOSED.** This objection was real while the hook held a full-range position — roughly 1/200th the depth per dollar of a tight range. The hook now custodies a **concentrated band**, and its half-width is a deployment parameter rather than a constant, so depth at the money is a sizing decision the deployer makes. What remains true, and is stated below, is that the pool is only routed if it is genuinely the deepest venue for the pair. |

**Verdict:** the customer is not being sold anything. They should be indifferent except for the extra network tick and the thinner book. If routers skip the pool, the front seat does not get the flow it is paying for.

### The front seat (the market maker who wants flow)

| Pros | Cons |
|---|---|
| First fill on every trade, including the small profitable ones, without posting more capital. | Pays rent continuously on a price they set themselves. |
| Can say *"give me the first $50k of flow and I will pay for it"* — which Uniswap cannot express at all today. | Eats 100% of a bad trade that lands in their inventory. 50× leverage on the flow, **both ways**. |
| The seat is durable (unlike today's JIT bots, which mint and burn every block). | If flow is toxic, the seat is a liability. The lease **cannot pay you to sit at the front** — prices cannot go below zero. Under toxic flow the signal censors at zero. Unsolved. |
| Anyone can take it from you if you under-price. You can empty the capital and keep or sell the rank. | This seat is for a firm that can flatten inventory off-venue. A treasury should not sit here. |

**Verdict:** benefits outweigh **if** the firm can hedge and the flow is mixed or benign. Otherwise they will not buy the seat, which is the mechanism working.

### The back seat (treasury, vault, "pay me to wait")

| Pros | Cons |
|---|---|
| Receives rent from the front for standing aside. A coupon that has never existed in an AMM. | In quiet, profitable two-way markets they **forgo most fee income**. Without rent, the back is strictly worse than ordinary Uniswap. **Rent is not optional for this role to make sense.** |
| Reached only by large trades. Lower turnover. | Large trades are the *informed* ones. Lower frequency, **worse mix**, plus a coupon. Not "safer." Anyone who sells the back as safe is lying. |
| Can size capital independently of rank. | Inventory bought on a big sell does not automatically unwind on the way back up — the next buy fills the *front* first. "Passive" capital is forced to be a bit active. |
| Cannot be dusted out of existence. | 32-seat cap: a small LP needs a syndicate wrapper, which recreates an intermediary. That wrapper is unbuilt. |

**Verdict:** benefits outweigh **only if rent actually flows**. In the demo, in a new pool, on a long-tail pair, there is no market in seats yet, so there is no rent. That is the weakest point in the whole design.

### The venue / deployer

| Pros | Cons |
|---|---|
| A differentiated LP product. Professional capital has a reason to pick this pool over the 189th dynamic-fee hook. | Bounded in *number of LPs* (not in dollars — seats can be huge). |
| Produces a public number: the head-seat price. Both "near zero" and "high" are useful results. | The band is ±10%, not ±1%. Wings restore permissionless depth *outside* the money. Routers may still skip the extra compute. |
| No admin, no upgrade, no privileged role — you cannot be asked to freeze it. | You also cannot freeze it. The founding 32 is an endowment worth one transaction of head start. |

### JIT bots / searchers

Weak buy-in, stated as weak. They cannot jump the paid desks with a tight-range mint. They can still do ordinary Uniswap JIT *outside* those desks, or buy a seat for a block and resell it. Honest answer: they trade elsewhere. QUEUE's claim against them is structural at the money, not persuasive.

---

## Would a decision-maker see this as dangerous?

Yes. These are the fears, tagged.

| What they will fear | Is it real? |
|---|---|
| "32 people control the pool — it's a cartel" | **Half real.** 32 slots is a franchise. The always-for-sale lease is the anti-cartel: anyone can buy any seat at the holder's own price, no whitelist, no admin. If holders collude to post infinite prices they pay infinite rent. If they post zero, the cartel is free to break — and rent, the tail's compensation, dies. |
| "Customers pay 36% extra" | **Confused as a trading-fee claim; real as a routing claim.** Extra network cost, not extra trading fee. Still a reason routers skip the pool. |
| "If they all leave, depositors are trapped" | **Mostly false.** Withdrawals are per-seat, against actual tokens. Face value is an *upper bound*, not a promise — last people out eat rounding dust so small it is not a business risk. No lockup. No pause. |
| "Someone can steal by being first" | **That was version 1, and it is dead.** You cannot create a seat by depositing. Dusting the head buys nothing. |
| "This is a dark pool / permissioned" | **Looks like one; is not, quite.** Entry is permissionless *at a price*. A real permissioned pool has a whitelist and a forked router. QUEUE uses the ordinary Uniswap router. Compliance people will still treat 32 named seats as a designated-MM list. Do not be surprised. |
| "A bug loses the money" | **Real, and the most serious risk in the table.** The hook *is* the pool's accounting. A bug is lost funds, not a degraded feature. 198 tests, 74 mutations with zero survivors, three production bugs found by attacking our own code. This is not an audit. |
| "We will get blamed for MEV" | **Theme risk, not product risk.** QUEUE does not stop sandwiches. Anyone who ships this as "MEV protection" is mis-selling. |

---

## Architecture, in one picture

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
│  2. 32 seats. Each seat = (token A, token B, owner, ask price,           │
│     prepaid rent). The ORDER of the 32 is one computer word.             │
│                                                                          │
│  3. Walks the line front-first:                                          │
│        take what seat 1 can sell                                         │
│        pay it for the SLICE OF THE PRICE MOVE IT ACTUALLY ABSORBED       │
│        if seat 1 is empty, walk to seat 2 — at a better price            │
│        last seat filled gets the leftover wei so the sum is exact        │
│                                                                          │
│  4. Rent: prepaid meter, paid to seats behind you, in elapsed time.      │
│     Dry meter → moved to the back. You keep the seat and every wei       │
│     of capital. You lose only your place.                                │
│                                                                          │
│  5. Buyout: anyone pays your posted price, your capital is sent          │
│     back to you, they get an empty seat at your old place.               │
│                                                                          │
│  No admin. No upgrade. No oracle. No off-chain bot required.             │
└──────────────────────────────────────────────────────────────────────────┘
```

Why hold the whole pool: Uniswap fills from one blended pot. To have a line, someone has to keep 32 separate piles and dole the fill out. The hook is that someone. The price it uses is not a guess — it is the swap's own average, handed back by Uniswap. There is nothing to manipulate.

A seat is an ERC-6909 token, supply exactly one. Transferring it moves **place in line**, not the capital. The capital goes back to the seller.

---

## What is actually proven, and what is still a story

Measured against a **real** Uniswap v4 PoolManager and a real router. Never a mock. Never tested at a 1:1 price (that hides unit bugs).

**Proven**

- Front-first fill is exact to the wei, in both tokens, at 1:4, 1:1000 and 1000:1, at 18/6 and 6/18 decimals.
- The queue is never over-backed: surplus **exactly 0 wei** across 16,384 randomised operations.
- Shortfall (v4's own rounding) stays under 1 part per billion of everything ever deposited, borne by the last people to withdraw.
- Typical-swap extra compute is **flat from 1 to 32 seats**.
- Rent cannot be stolen with a flash loan.
- Running out of rent demotes you; it does not seize you.
- You cannot create a seat by depositing. Dusting the head buys nothing.
- The queue maths does not care about the position's price range (proven on a ±10% band). The shipping position **is** that band. Wings are ordinary Uniswap outside it.
- Three real bugs were found in code that had already passed 135 tests, including one that bricked both deposit paths on any pool with accrued fees. All three are fixed. Mutation testing on this project has found a real defect **every time it was run**.
- 0 of 662 prior hook submissions sold an ordering over LP capital.

**Still a story**

- That a liquid market in seats will form. It does not exist. The "toxicity signal" is only as good as that market.
- That professional LPs will pay for this versus running JIT bots on ordinary pools.
- That routers will send flow to a pool whose typical swap costs +119% compute.
- That the lease works when the front is worth less than zero. It cannot express that.

Both "the head seat prices near zero" and "the head seat prices high" are results. Claiming to know which in advance is the thing that would make this uninteresting.

---

## What it does not do — say these out loud

| Claim we do not make | The truth |
|---|---|
| "QUEUE stops sandwich attacks." | It does not. Trades execute normally, at the normal price, through any router. |
| "QUEUE reduces LVR / LP losses." | Total pool P&L is unchanged. What changes is *who bears it, at a known price*. |
| "QUEUE recaptures value from searchers." | It does not. You cannot jump the paid desks with a tight-range mint. You can still do ordinary Uniswap JIT *outside* those desks. |
| "QUEUE detects toxic flow." | It does not, and it must not try — proven impossible for a v4 hook. It sells different slices of the flow and lets capital bid. |
| "The queue's face value is redeemable." | Face value is an **upper bound**. Last people out eat a rounding residual. |
| "Sweeps are free / O(1)." | They cost 14,777 compute units per seat walked. |
| "This is price–time priority." | It is not. Rank goes to willingness to pay rent, not to arrival. |
| "A queue is obviously better than pro-rata." | We do not know. That is the experiment. |
| "The overhead is negligible." | It is +119% vs a bare pool on a typical swap (and +88% even with the premium off). The defensible claim is that it is a **constant a router can price**, not that it is small. |

The longer form of every row, with numbers, is in [`BUSINESS.md`](BUSINESS.md).

---

## How this rates as a Uniswap Hooks Incubator submission

Published rubric: **30% original idea · 25% unique execution · 20% impact · 15% functionality · 10% presentation.** Binary gates: public repo, a real v4 hook, new code in the window, tests or a frontend, a video under five minutes with a human voice.

| Slice | Honest score | Why |
|---|---|---|
| Original idea (30%) | **Strong** | 0 of 662 prior hooks sold an ordering over LP capital. Uniswap cannot express "pay to be filled first" today. |
| Unique execution (25%) | **Strong** | Real v4, not a mock. Front-first at the swap's own price. Paid seats, always for sale. Ordinary Uniswap liquidity outside the desks. Tests that go red when you cheat — and a `recenter()` that is **still not shipped** because, after our own attack killed v1 and the rebuild passed all eight of its tests, the invariant campaign said no. |
| Impact (20%) | **Medium** | Uniswap will not reroute ETH/USDC through this. A professional venue *can* run it, and a Uniswap team can LP outside the desks with Position Manager tomorrow. Over-claim "every pool" and this slice collapses. |
| Functionality (15%) | **Strong as a hook** | 198 tests, 0 failed. The hook is the product. |
| Presentation (10%) | **Incomplete** | Frontend exists. **Video and live broadcast do not.** That is a binary gate, not polish. |

**Hook implementation: done. Submission: not done** until the video and the broadcast exist.

```
forge test               ->  183 passed, 0 failed, 1 skipped
python3 script/mutate.py M70 M71 M72 M73 M74 ->  RED
```

A full re-campaign of the older 69 mutations against this source is **not claimed**.

The skipped suite is `DeployFork.t.sol`, off unless you ask, because the default suite must not need a network. It skips **loudly**:

```
QUEUE_FORK=true forge test --match-path "test/queue/DeployFork.t.sol" -vv
```

Everything runs against **real v4 contracts deployed locally** — a real `PoolManager`, `PositionManager` and `V4SwapRouter`. Nothing is mocked. The rounding is v4's own.

**Still outstanding:** the live broadcast and the video. The deployment sequence has been executed and asserted against a fork of Unichain Sepolia; the remaining risk there is operational, not mechanical.

---

## Start here

| File | What it is |
|---|---|
| **This file** | The 15-minute read. What it is, who it is for, why 32, why the network-compute cost, what breaks, what does not. |
| [`BUSINESS.md`](BUSINESS.md) | The decision memo with worked numbers, the 662-row novelty check, gas tables, and the limitation list at full strength. |
| [`PLAN.md`](PLAN.md) | What to build, phased, with runnable acceptance criteria. Opens with a BUILD STATUS dashboard — that table is the authoritative answer to "what is done". |
| [`PROGRESS.md`](PROGRESS.md) | What is proven, what is open, what to do next. |
| [`PITFALLS.md`](PITFALLS.md) | The standing hazard ledger. Every row graded. Re-read at the start of every session. |
| [`AGENTS.md`](AGENTS.md) | How to work in this repo. Rules, testing laws, decision framework. (`CLAUDE.md` is a symlink to it.) |
| [`frontend/index.html`](frontend/index.html) | A read-only viewer. No keys, no server. Open the file. |
| [`docs/research/premise-review/`](docs/research/premise-review/) | The economic and fairness review of the premise. Analysis, nothing executed. |

**No partner integrations.**

---

## Running it yourself

You need [Foundry](https://book.getfoundry.sh/getting-started/installation) and nothing else — no node, no RPC, no keys, no network.

```bash
git clone --recurse-submodules https://github.com/<owner>/<repo>.git
cd <repo>
forge build
forge test
```

> **The `--recurse-submodules` matters.** The v4 stack, `forge-std` and `hookmate` are git submodules. A plain `git clone` leaves `lib/` empty and the build broken with an error that does not say why. If you have already cloned without it: `git submodule update --init --recursive`.

Expect **172 passed, 0 failed, 1 skipped** across 16 suites. Useful subsets:

```bash
forge test --match-path "test/queue/Deploy.t.sol"       -vv   # the deployment path, beat by beat
forge test --match-path "test/queue/Invariant.t.sol"    -vv   # 11 invariants + the scripted campaign
forge test --match-path "test/queue/Adversarial.t.sol"        # every named attack, with an outcome
forge test --match-path "test/queue/Gas.t.sol"          -vv   # prints the gas table
forge lint src/                                               # must stay clean, zero notes
python3 script/mutate.py                                      # 74 mutations, must be 0 survivors
```

`script/mutate.py` edits `src/` in place, runs the suite, and puts it back. **Do not run `forge` against the repo while it is going**; it holds a deliberate bug on disk for the duration of each case, and the suite will refuse to run and tell you so.

Open `frontend/index.html` in a browser for the side-by-side: same swap, pro-rata vs front-first.

---

## License

MIT. No mainnet deployment. No off-chain components.
