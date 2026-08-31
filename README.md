# QUEUE

**A Uniswap v4 hook that lets the people putting up the money buy and sell their place in line — so whoever wants to be filled first pays whoever is willing to go last.**

This is not a public Uniswap pool. It is not sandwich protection. It is not a cheaper trade. It is a **32-desk professional venue** sitting on top of Uniswap's ordinary price curve.

If that is not a product you have buyers for, stop here.

---

## In 90 seconds, for someone who does not live in DeFi

A Uniswap pool is a shared cash register. When a customer trades, **every** cash provider behind that register is hit a little, in proportion to how much they put in. Nobody is first. Nobody is last. The only way to get more of the action is to put more money in.

That is not how any other market in the world works.

On the NYSE, on Nasdaq, in FX, in futures — **being first in line is an asset**. Firms spend hundreds of millions of dollars on microwave towers and colocation just to stand at the front. The people they jump in front of are not paid. The money goes to the tower vendors. On a blockchain the same value is sold by whoever orders the block. The pool's own cash providers get none of it.

QUEUE does one thing: it puts a **numbered line** inside a Uniswap pool, and it **sells the numbers**.

- Seat 1 is filled by every trade that arrives, including the small ones.
- Seat 32 is filled only when a trade is so large it has already emptied seats 1 through 31.
- You cannot join by arriving first. You **buy** a seat from whoever holds it, at a price they posted themselves.
- While you hold the front, you **pay rent** to everyone behind you.
- Anyone can take your seat at your posted price, at any time. Under-price it, you lose it. Over-price it, you pay for it.

The customer on the other side of the pool does not see any of this. They trade through the same Uniswap router, at the same price, at the same trading fee. The line is among the **cash providers**, not among the customers.

**This is not an order book.** An order book lines up *customers' orders* ("I will buy if the price hits $3,000"). QUEUE lines up *the people putting up the money* ("fill me first" vs "fill me last and pay me for waiting"). There is no limit price, no matching engine, and no cancel button. The customer never talks to the queue.

---

## The verdict, before the pitch

| Question | Honest answer |
|---|---|
| Is it well built? | **Yes, as accounting.** 172 tests, 68 mutations with zero survivors, three real bugs found in code that had already passed 135 tests — all fixed. This is not an audit. |
| Is it interesting? | **Yes, as a missing product.** Uniswap has run one fill rule for seven years. Nobody has been able to price "being first." QUEUE is the first pool where that number exists on-chain. 0 of 662 prior hook submissions sold an ordering over LP capital. |
| Does it make Uniswap better for ordinary users? | **No.** Same price, same fee, extra network cost, thinner book. The trader is not the customer of this product. |
| Does it stop MEV / sandwiches? | **No, and claiming it does is mis-selling.** The hackathon theme is two halves. QUEUE can claim **sustainable liquidity** (the right desks can choose to stay). It cannot claim MEV protection. |
| Does it make LPs lose less in total? | **No.** Total pool P&L is identical. QUEUE **redistributes** who bears a bad trade, and **prices** that redistribution. Anyone who writes "QUEUE reduced LP losses" is lying. |
| Who is this for? | Professional market makers who want first fill without posting more capital, and treasuries / vaults who want to be paid to stand behind. Roughly 10–32 serious desks on a pair — not 10,000 retail LPs. |
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

## What ships today: one queue for the whole pair

Yes. **The entire queue is for the entire pair**, not per tick. One pool, one full-range position, one line of ≤32 seats. A trade at any price walks that same line. Uniswap already has price priority *across* ticks; this version throws the ticks away to get a simple queue. That is why depth is ~1/200th of a tight book, and why Uniswap will not adopt *this* blob as a primitive.

**Per-tick seats would be more interesting for Uniswap** — that is the actual missing half of price–time priority — and it is a different product, not a setting. The honest version is *per-seat ranges*: each of 32 seats picks a tick band like a v3 NFT; fill is price-first, then rank among whoever is in range. `afterSwap` gives the hook one number, not a per-tick tape, so this is a research project. The fastest step that is *not* that: concentrate the one blob. The allocator already does not care about its range.

A seat **can hold only one of the two tokens**. After a fill, the front usually does. Depositing both in the current ratio is how you add *depth*. Depositing one, on this full-range version, typically mints **zero** liquidity — the tokens sit as a claim in the float. Rent is paid in token0, weighted by token0: a seat holding only token1 earns **$0** of the coupon. That matters.

This project is **only the queue**. There is no sandwich shield and no new curve. The buy-in *is* the product: liquidity in, ask posted, fees ± markout ± rent. If those numbers do not work for a desk, nothing else in the repo matters.

**Move the sliders:** open [`frontend/index.html`](frontend/index.html) and press *Quiet two-way — you are the front*, then *Event day*, then *Quiet — you are the back*. Rank 4 in that five-seat book is the stand-in for seat 32. Worked numbers and the over/under-price picture: [`BUSINESS.md`](BUSINESS.md) §11.4. What would make Uniswap actually want this: §16.

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
                (see "+36%" below)
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

## The "+36%" — it is not 36% more expensive trades

This is the number that will kill the pitch if you say it wrong.

What was measured: a typical swap on QUEUE uses **117,989 units of network compute**. The same swap on a pool with no hook uses **86,820**. That is **+36%**.

What a business person hears: *"customers pay 36% more."*

What it actually is:

| | |
|---|---|
| A trading fee? | **No.** The pool's 0.30% (or whatever was set) is unchanged. |
| A worse price? | **No.** The customer gets the same tokens out. |
| Extra network cost? | **Yes.** Like a slightly longer checkout taking a slightly larger card-processing tick. |
| Same at 1 seat as at 32? | **Yes, for a normal trade.** 1 seat: 117,971. 32 seats: 117,992. Difference: 21 units. The 36% is the cost of the pool *having a book at all*. |
| Always 36%? | **No.** If a single trade is large enough to walk many seats, add ~8,070 units per extra seat. A full 32-seat walk is a 416,053-unit transaction — not +36%, closer to 5× a hookless swap. That is a large, unusual trade. |
| Dollars? | This product belongs on an L2. 31,000 extra units is **cents or less**, not 36% of the notional. On Ethereum mainnet it would be a real bill. **QUEUE is an L2 product.** |

The honest commercial risk is not "36% more expensive trades." It is: **routers pick the pool with the same price and the lower network cost.** If they skip QUEUE, this pool does not see retail flow. Retail flow is the "good" flow the front seat wants. That loop is the adoption problem, and it is not solved.

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
| Same price. Same trading fee. Any Uniswap router. They never touch the queue. | +36% network compute on a typical swap. A constant, not a slope. |
| | A very large trade that walks many seats costs more still. |
| | This version holds one wide-range position — roughly **1/200th the depth per dollar** of a tight Uniswap v3-style range. Worse price impact for the same dollars. **This is the sharpest commercial objection and it is not shipped as a product.** The queue maths is proven not to care about the range; concentrating it is a next-version parameter, unbuilt. |

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
| Produces a public number: the head-seat price. Both "near zero" and "high" are useful results. | Thin full-range depth until the range is concentrated. Routers may not route. |
| No admin, no upgrade, no privileged role — you cannot be asked to freeze it. | You also cannot freeze it. The founding 32 is an endowment worth one transaction of head start. |

### JIT bots / searchers

Weak buy-in, stated as weak. They cannot jump this pool with a tight-range mint (nobody except the hook can add liquidity). They can buy the seat for a block and resell it. Honest answer: they trade elsewhere. QUEUE's claim against them is structural, not persuasive.

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
| "A bug loses the money" | **Real, and the most serious risk in the table.** The hook *is* the pool's accounting. A bug is lost funds, not a degraded feature. 172 tests, 68 mutations with zero survivors, three production bugs found by attacking our own code. This is not an audit. |
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
│        pay it the incoming token at THIS SWAP's average price            │
│        if seat 1 is empty, walk to seat 2                                │
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
- The queue maths does not care about the position's price range (proven on a ±10% band). Concentrating the book is a parameter, not a rewrite — **unbuilt as a product**.
- Three real bugs were found in code that had already passed 135 tests, including one that bricked both deposit paths on any pool with accrued fees. All three are fixed. Mutation testing on this project has found a real defect **every time it was run**.
- 0 of 662 prior hook submissions sold an ordering over LP capital.

**Still a story**

- That a liquid market in seats will form. It does not exist. The "toxicity signal" is only as good as that market.
- That professional LPs will pay for this versus running JIT bots on ordinary pools.
- That routers will send flow to a full-range 32-seat pool.
- That the lease works when the front is worth less than zero. It cannot express that.

Both "the head seat prices near zero" and "the head seat prices high" are results. Claiming to know which in advance is the thing that would make this uninteresting.

---

## What it does not do — say these out loud

| Claim we do not make | The truth |
|---|---|
| "QUEUE stops sandwich attacks." | It does not. Trades execute normally, at the normal price, through any router. |
| "QUEUE reduces LVR / LP losses." | Total pool P&L is unchanged. What changes is *who bears it, at a known price*. |
| "QUEUE recaptures value from searchers." | It does not, except one vector: the tight-range JIT jump is structurally unavailable (external adds revert) and the equivalent right must be bought from an incumbent. |
| "QUEUE detects toxic flow." | It does not, and it must not try — proven impossible for a v4 hook. It sells different slices of the flow and lets capital bid. |
| "The queue's face value is redeemable." | Face value is an **upper bound**. Last people out eat a rounding residual. |
| "Sweeps are free / O(1)." | They cost 8,070 compute units per seat walked. |
| "This is price–time priority." | It is not. Rank goes to willingness to pay rent, not to arrival. |
| "A queue is obviously better than pro-rata." | We do not know. That is the experiment. |
| "The overhead is negligible." | It is +36% vs a bare pool on a typical swap. The defensible claim is that it is a **constant a router can price**, not that it is small. |

The longer form of every row, with numbers, is in [`BUSINESS.md`](BUSINESS.md).

---

## Status — Phases 0–6 complete, Phase 7 shipping, 2026-08-31

```
forge test               ->  172 passed, 0 failed, 1 skipped   (16 suites)
forge lint src/          ->  clean, zero notes
python3 script/mutate.py ->  68 mutations on production code, ZERO survivors
```

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
| **This file** | The 15-minute read. What it is, who it is for, why 32, why +36%, what breaks, what does not. |
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
python3 script/mutate.py                                      # 68 mutations, must be 0 survivors
```

`script/mutate.py` edits `src/` in place, runs the suite, and puts it back. **Do not run `forge` against the repo while it is going**; it holds a deliberate bug on disk for the duration of each case, and the suite will refuse to run and tell you so.

Open `frontend/index.html` in a browser for the side-by-side: same swap, pro-rata vs front-first.

---

## License

MIT. No mainnet deployment. No off-chain components.
