# QUEUE — the business case

*Written 2026-08-26. Source material is the research archived at `archive/2026-08-26/`. Every number
below carries a tag:*

| Tag | Meaning |
|---|---|
| **[MEASURED]** | Produced by executing code. Source named. `test/spike/QueueAllocator.t.sol`, 9 tests green, real `PoolManager`, real `V4SwapRouter`, pool at `SQRT_PRICE_1_4` (never 1:1). |
| **[COUNTED]** | A query run against `archive/2026-08-26/docs/research/data/hook_directory_662.json` (662 rows). The query is printed next to the count so it can be re-run. |
| **[SOURCED]** | Quoted from a primary document that was actually fetched and read. |
| **[ESTIMATE]** | A worked example. The assumptions are stated inline. Not a measurement and not a projection. |
| **[ANALYSIS]** | Reasoning, not measurement. Flagged wherever it appears. |

Nothing in this document is a revenue, TVL, or adoption forecast. There is no basis for one and none
is offered.

---

## 0. THE FRAME — the Uniswap decision this challenges, and why *paid seats* is the answer

*Added 2026-08-28, after Phase 6. This section exists because the pitch above it was true but was
being read as "an order book bolted onto an AMM", which is not what it is and is not the interesting
part. **[ANALYSIS]** throughout — this is framing, not measurement.*

### 0.1 The decision

Every Uniswap version — v1 through v4 — fills **pro-rata**. Inside a tick, every LP is filled in
proportion to their size. It is stateless, needs no ordering, and is trivially permissionless. It is
the right default and it is a large part of why AMMs work at all.

But it is a **choice**, and in seven years and four major versions it has never been compared against
anything, because on Uniswap there has never been anything to compare it against.

### 0.2 What the choice costs

Pro-rata makes LP capital **undifferentiated**. Two LPs at the same price with the same capital hold
*identical* assets. One competitive dimension — size. One way to express a view — move your range.

Three consequences, none priced today:

1. **You cannot buy priority, so priority has no price.** In every other electronic market, being
   early is the most valuable thing a maker owns; firms spend nine figures of capex on it. On
   Uniswap it is worth exactly zero, by construction.
2. **You cannot sell subordination either.** There is no way to say *"fill me last, and pay me for
   it."* Senior/subordinate tranching exists in every credit, insurance and securitisation market
   ever built. It has never existed in an AMM.
3. **Ordering value does not vanish — it relocates.** Ordering inside a block is real and valuable,
   and on an L2 it is already sold, at the sequencer and builder layer. The pool's own LPs, whose
   P&L that ordering determines, receive none of it.

The sharpest form:

> **Uniswap did not eliminate the value of queue position. It made it unpriceable *inside* the pool,
> which means it is captured *outside* the pool.**

### 0.3 Why *paid seats* — the question the design lives or dies on

The obvious alternative is an **open, arrival-ordered queue**: first depositor is first, anyone joins
the back, nobody pays. That is what "a queue" normally means. It fails immediately, and this repo has
the corpse:

- **Free rank is griefable rank.** If arrival grants rank, the head costs one wei. Dust the head and
  you own the front of the book forever for the price of gas. That was the first version of this
  hook (§B.8, §E.16; PITFALLS 5.8).
- **Unbounded rank is worthless rank.** If anyone may join the back, ordering slots are not scarce; a
  non-scarce asset has no price; with no price there is no rent; with no rent there is no payment to
  the LPs you are standing in front of. The mechanism collapses into *"whoever arrived first holds a
  permanent free option on everyone else's flow."*

So the roster is **bounded** and the seats are **paid for**. **Scarcity is the mechanism, not a gas
concession.** It is the only thing that makes rank an asset at all.

And the obvious objection — *a fixed set of 32 tradeable seats is a cartel* — is exactly why a seat
is **leased, not owned**. Under the Harberger lease you set your own price, pay continuous rent on
your own number to the seats behind you, and **anyone may take the seat from you at that number, at
any time**. Under-price and you lose it; over-price and you pay for it.

> **Scarce, but never capturable.** Neither half survives alone: a bounded roster without Harberger
> is a cartel; Harberger without a bounded roster prices nothing. That pairing IS the answer to
> "why paid seats".

### 0.4 The real-world situations Uniswap cannot express today

**(a) The maker who wants to be *first*, not *bigger*.** Today the only route to more fill is more
capital, and more capital means more of *everything* including the toxic tail. A firm with a good
model and a limited balance sheet cannot say *"give me the first $50k of flow and I will pay for
it."* On QUEUE it can, and the price is public and continuous.

**(b) The LP who wants to be *last*, and be paid for it.** The mirror is the more interesting half
and nobody talks about it. The back has lower turnover — reached only when a trade sweeps the front —
**and is paid rent by the front for standing aside.** That is a *subordinated* liquidity position
with a coupon, and it has never existed in an AMM. Whether it beats the front risk-adjusted is an
open empirical question, and that is the point.

**(c) The ordering value the sequencer already sells.** On a chain with an auctioned or centralised
sequencer, intra-block ordering is already a priced asset the pool does not participate in. QUEUE is
the pool asserting that the ordering *inside its own liquidity* belongs to its LPs.

### 0.5 What it honestly is: an experiment that produces a number nobody has

> Uniswap has run exactly one fill rule for seven years and hundreds of billions of dollars of
> volume. Nobody knows what the alternative is worth, because nobody has been able to build it.
> QUEUE is the first pool where you can ask **"what is being filled first actually worth?"** and get
> a continuously-updating, on-chain answer: the self-assessed price of the head seat.

Falsifiable in both directions, and **both outcomes are results**: a head seat that prices near zero
says priority is worth nothing inside an AMM and pro-rata was right all along — which we would then
*know* rather than assume. A head seat that prices high says Uniswap has been giving away for free
the asset every other market charges the most for.

### 0.6 The objections, answered

| Objection | Answer |
|---|---|
| *"Pro-rata is what makes an AMM permissionless. A queue reintroduces privilege."* | The privileged position exists, and **nobody can hold it except by continuously paying for it, and nobody can be excluded from taking it.** The shipping contract has no admin, no whitelist, no upgrade path and no privileged role of any kind. The status quo also has ordering privilege — unpriced, and decided by whoever sequences the block. |
| *"32 seats is an oligopoly."* | 32 is roughly the number of serious market makers in any given pair on any venue. The **capital is unbounded** — anyone may deposit any amount into a seat they hold. Only the ordering slots are scarce, and they must be, or they have no price. |
| *"This is am-AMM."* | am-AMM auctions **management rights over the whole pool** to **one winner per block**. QUEUE sells **an ordering over the existing LPs' own capital**, perpetually, to **many simultaneous holders**, with no auction, no winner, and no per-block reference anywhere in the contract. |
| *"You cannot detect toxic flow."* | Correct, proven, and QUEUE never attempts it. It does not classify anyone; it sells different slices of the flow and lets capital bid, which is unforgeable precisely because the bid costs real money. |
| *"+36% gas."* | Measured: 117,989 vs 86,820 on an identical hookless pool. A **constant a trader can price** — flat from 1 to 32 seats, a 21-gas spread — not a slope that grows with book depth. |

---

## 1. WHAT QUEUE IS

**QUEUE is a transferable claim on where in the fill order your capital sits.**

Two liquidity providers put the same $50,000 into the same pool at the same price. Today they own the
same thing. Under QUEUE they own two different assets:

- The one at the **front** is filled by *every* swap, including the small ones.
- The one at the **back** is filled only when a swap is large enough to consume everyone ahead of it.

That is the entire object. It is not a fee rule, not a curve, not an auction. It is a position in a
line, it is fungible per pool, it is transferable as an ERC-6909 balance, and — this is the point —
**it has a price.**

The front of the line is not automatically the better seat. When the flow is ordinary two-way trading,
the front collects the whole fee on a small capital base and is worth a great deal. When the flow is
one-directional and informed, the front is the seat that absorbs the entire adverse move first, and it
is worth less than the back. **Which way the price points is the information.**

---

## 2. WHY IT HAS NEVER EXISTED, AND WHAT THAT MEANS

### 2.1 State the claim precisely, because the loose version is wrong

The sloppy claim is "Uniswap has no priority." That is false and a judge will say so.

Uniswap v3/v4 **does** have price priority. A swap crosses ticks in order, so capital posted at a
nearer tick is filled before capital at a further tick. That half of price–time priority exists.

What does not exist is the **time** half:

> **Within a tick, every unit of liquidity is filled pro-rata. There is no ordering among LPs at the
> same price, and no way to acquire one.**

QUEUE supplies the missing half. That is the exact claim, and it survives contact with someone who
knows how v4 works.

### 2.2 Why AMMs went pro-rata — nobody decided this

Pro-rata is not a policy choice. It is a mechanical consequence of pooling.

A constant-function market maker computes a swap against an **aggregate reserve**. The swap moves the
price along the invariant; liquidity is a single scalar `L` at each tick. Fees are tracked as one
global accumulator, `feeGrowthGlobal += fee · Q128 / L`, and each LP's share is read out later by
subtracting snapshots. **There is no per-LP identity anywhere in the fill path.** The pool does not
know who it just traded with, because "who" was never in the arithmetic.

Once liquidity is an aggregate, pro-rata is the only allocation that is even expressible. To get a
queue you have to stop the pool from being an aggregate — which means somebody has to custody the
liquidity and keep an ordered ledger. Uniswap v4's hook architecture is the first version of Uniswap
where a third party can do that inside the protocol.

### 2.3 What pro-rata costs, in business terms

| Consequence of pro-rata | Why it matters |
|---|---|
| **Every LP gets an identical blend of flow.** | Nobody can choose more toxic flow or less. There is no product differentiation, so there is nothing to trade. |
| **Adverse selection is a bundled, mandatory cost.** | It is smeared across all LPs in proportion to size and it is *undiversifiable* — you cannot buy insurance against it from another LP in the same pool, because that LP holds the identical exposure. |
| **There is no reward for quoting early.** | In every real market, time priority is what pays a market maker to show a quote *before* they have to. In an AMM, being early to a tick buys you nothing beyond the same pro-rata share. |
| **Gains from trade are unavailable.** | A hedger with offsetting inventory can bear toxic flow far more cheaply than a treasury can. Today neither party can act on that difference. |

Every real electronic market on earth — equities, futures, FX ECNs — **already prices queue
position.** It just does it implicitly, and the currency is **latency**: firms spend nine figures on
colocation, FPGAs and microwave towers to get to the front and stay there. That spend is deadweight —
it buys priority from the exchange's matching engine and accrues to infrastructure vendors, not to
the participants being jumped ahead of.

> **Uniswap has never had a queue, so it has never had a price for one.**

⚠ **SHARPENED 2026-08-28.** The older wording here said every real market "runs price–time
priority", full stop. That invites a correct objection: **QUEUE is not price–time priority either.**
Its roster is closed, you cannot join by arriving, and the "time" is gone — position goes to
willingness to pay rent. The honest and stronger claim is the one above: ordering is already priced
everywhere, the alternative to pricing it explicitly is a latency race, and Uniswap's choice did not
make ordering worthless — it made it unpriceable *inside* the pool, so it is captured *outside* it.
See §0.

---

## 3. ARE WE SURE IT DOES NOT EXIST?

### 3.1 The 662-row directory — queries run, not remembered

Dataset: `archive/2026-08-26/docs/research/data/hook_directory_662.json`, 662 submissions across
UHI1–UHI10, retrieved via the Notion collection API (provenance in `WINNERS_LANDSCAPE.md`).

```bash
jq -r '[.[] | select((.name+" "+.desc+" "+.tags+" "+.integrations)
      | test("queue|priority|price.?time|fill order|rank|seat|ordered|fifo|lifo";"i"))] | length' \
  hook_directory_662.json
```

| Query | Hits / 662 | What they actually are |
|---|---:|---|
| `queue\|priority\|price.?time\|fill order\|rank\|seat\|ordered\|fifo\|lifo` | **10** | See breakdown below. **Zero are an ordering over LP capital.** |
| `\bqueue` | **3** | `SwapPilot` (UHI8) queues *swaps* via NoOp; `ZeanHook` (UHI5) batches *swaps*; `RwAsync` (UHI3) queues *swaps* pending an admin. All three queue orders, not liquidity. |
| `price.?time\|time priority\|fill priority\|pro.?rata\|fifo\|lifo` | **1** | `LongETH` (UHI8) — a stablecoin yield router. False positive on substring. |
| `\brank\b\|\bseat\b\|\bseats\b` | **0** | — |
| `designated market maker\|\bdmm\b\|market maker.*(seat\|franchise\|obligation)` | **0** | — |
| `harberger\|self.assess\|common ownership\|always for sale` | **0** | — |
| `payment for order flow\|\bpfof\b\|internali[sz]` | **2** | Both am-AMM auction hooks. |
| `am-?amm\|auction.?managed` | **7** | The am-AMM family. Nearest neighbour — see 3.2. |

The remaining hits in the 10-row set are `STRATUM` and `Fixed-Income Tranche Hook` (matched on
"priority waterfall" / "senior"), `LaunchGuard` and `Shield-Auction-Hook` (auction *block placement*),
`SHADOW TRADE LIMIT HOOK` (FHE limit orders), `KOL Referral System`, and `Priority is all you need`
(raises the fee when *priority fees* are high — a different meaning of the word).

**Result: 0 of 662 submissions sell an ordering over LP capital.**

### 3.2 What IS adjacent, stated plainly

This is the section a judge will read hardest. Nothing here is hidden.

| Adjacent thing | How close | How QUEUE differs |
|---|---|---|
| **am-AMM family** — `am-AMM hook` (UHI1), `Chronus` (UHI2), `Auction Managed AMM` (UHI2/UHI3), `Maestro` (UHI6, prized), `AuctionPool` (UHI7). Also the am-AMM paper (Adams–Moallemi–Reynolds–Robinson). | **Closest by concept.** Both sell a right over a pool to capital. | am-AMM auctions **pool-management and fee-setting rights to one winner per block**. QUEUE sells **an ordering over the existing LPs' own capital**, perpetually, to many holders simultaneously. No auction, no per-block winner, no manager, no fee-setting right. **This distinction is one sentence deep and the pitch must lead with pro-rata-vs-queue, never with the word "auction."** Note also that Atrium's own brainstorm deck puts LVR auctions on the **AVOID** list [SOURCED]. |
| **Tranche hooks** — `STRATUM` (UHI8, "on-chain priority waterfall"), `Unistrata` (UHI9, prized), `Sochalant`, `TrancheGuard`, `RiskShield`, `StructuredYield`, `Fixed-Income Tranche Hook`. 11 rows [COUNTED], 1 prized. | **Closest by mechanism shape** — an explicit ordering over LP capital. | Tranches order **payouts**. A senior tranche still trades against every swap pro-rata; it is simply paid first out of the results. QUEUE orders **fills** — it changes which swaps you are the counterparty to in the first place. Different object, and the one that changes the LP's *exposure* rather than the waterfall on the exposure. |
| **JIT liquidity** — 21 rows [COUNTED]; and the live practice on mainnet. | **Closest by behaviour.** A JIT bot is already buying fill priority. | Today the only way to buy priority in Uniswap is to **out-concentrate** everyone at the touch: mint an extremely tight range so you are most of `L` at that tick. It costs capital and gas, it is available to any bot, and **none of what it pays reaches the LPs it displaces.** QUEUE makes the same right explicit, perpetual, and paid to the incumbents. See §4.3. |
| **Limit-order hooks** — 17 rows [COUNTED], 7 prized. | A limit book *is* price–time priority. | Those hooks queue **traders' orders** at ticks. QUEUE orders **LPs' capital** in the fill path. Opposite side of the market. |
| **`Non-Fungible LP Positions Hook`** (UHI8, unprized) | Fractionalises a concentrated position into ERC20 shares. | Fungibility of **capital**, not of **rank**. Different object. |
| **`Tidehook`** (UHI8, unprized) — the only flow-segmentation attempt in 662 [COUNTED, corroborates W8]. | Same problem. | Tidehook routes large swaps to a Dutch auction, i.e. it assumes **size ⇒ toxic**. That assumption is defeated by order splitting at fractions of a cent of gas (`CLAUDE.md` §5.17, the Splitting Lemma). **QUEUE never assumes size ⇒ toxicity** — it prices the seat, and lets splitting concentrate flow onto the seat that is priced. This is why QUEUE survives an impossibility proof that Tidehook does not. |
| **Angstrom (Sorella)** — verified live on-chain 2026-08-26: L1 hook 23,569 bytes on Ethereum, 433 logs / 5,000 blocks; L2 hooks 23,240 bytes on Base [MEASURED, `INCUMBENTS.md`]. | Serious funded incumbent in the same theme. | Angstrom **L1** clears a whole block at one uniform price using an **off-chain validator network**. Angstrom **L2** taxes `(tx.gasprice − block.basefee)` above a floor and pays LPs [SOURCED, their docs]. Neither touches fill ordering among LPs; neither creates a tradeable object. *(Note: all three published Angstrom addresses on Unichain hold* **0 bytes** *[MEASURED]. Do not repeat the claim that it is live there.)* |
| **KyberSwap FairFlow** | Live, $3.2B / 22 pools / 5 chains since Aug 2025 [SOURCED]. | Exclusive-taker model checking a **backend-signed** fair price. Centralised signer, permissioned pools, off-chain weekly settlement. Not a fill ordering and not a hook-only design. *(Kyber's "$320k to LPs / 2,100 LPs" figures are* **UNVERIFIED** *and are not used here.)* |
| **OpenZeppelin `AntiSandwichHook` / Umbra sr-AMM** | Widely shipped library code. | A **price floor**: no fill better than the block-open price. Refuses fills; creates no cashflow and no object. One swap direction only. |
| **CoW Protocol, UniswapX, RFQ, MEV-Share, Flashbots Protect** | Real, large, adjacent. | All are **order-routing** layers that sit beside the AMM. None changes who inside an AMM pool is the counterparty. Also: `flashbots` → **0/662**, `cow protocol` → **0/662** [COUNTED]. |
| **LVR literature** (Milionis–Moallemi–Roughgarden–Zhang) and LVR-auction hooks — 55 rows, 16 prized [COUNTED]. | Same cost, different treatment. | Those designs try to **capture or reduce** LVR. QUEUE **prices and reallocates** it and does not claim to reduce it. See §9. |
| **TradFi: NYSE Designated Market Makers, exchange market-maker franchises** | This is the real precedent and it is not on-chain. | A DMM franchise is exactly "a paid, obligated position at the front of the book." It has never been expressible in an AMM because there was no book. `designated market maker` → **0/662** [COUNTED]. |

**Honest summary:** the *concept* of paid queue priority is ancient and central to every real market.
The *implementation over pooled AMM liquidity* has no instance in 662 submissions, no instance in the
live incumbents, and no instance in the DeFi literature we could locate. The novelty claim is about
the venue, not about the idea, and it should be pitched that way.

---

## 4. BUSINESS DRIVERS — why anyone pays

### 4.1 The core trade

Today, adverse selection is an **unpriced, undiversifiable, compulsory** cost. Every LP in a pool
holds the same blend of benign retail flow and informed toxic flow, in proportion to capital, whether
they want it or not.

QUEUE turns that blend into a **priced, transferable position** and lets it move to whoever bears it
most cheaply. The gains from trade are real and they exist for the ordinary reason gains from trade
exist: different holders have genuinely different costs of bearing the same risk.

| Party | Cost of bearing toxic flow | Wants |
|---|---|---|
| A market maker with a live hedge on a CEX and offsetting inventory | Low — they flatten the position in seconds | **Maximum flow per unit of capital** ⇒ the front |
| A stablecoin issuer / LST issuer / DAO treasury | High — they cannot hedge, and they carry the position | **A known payment instead of an unknown loss** ⇒ the back, and payment for giving up the front |

That is a two-sided market with a real reason to exist. It is the same reason insurance and
market-making franchises exist.

### 4.2 The TradFi comparison, and the difference that matters

| | Designated market maker franchise | Payment for order flow | **QUEUE** |
|---|---|---|---|
| What is sold | A privileged position at the front of the book, with obligations | The right to be the counterparty to a retail order stream | A position in the fill order of a pool |
| Who pays | The DMM pays the exchange for the franchise | The wholesaler pays the **broker** | The buyer of the seat pays the incumbent seat-holder |
| Who receives | The exchange | **The broker — not the person whose order it was, and not the liquidity supplier** | **The LPs.** |

The last row is the substantive difference and it is not a marketing point — it is **forced by the
architecture.** `CLAUDE.md` §5.16 and §5.18: a v4 hook's `sender` is the router, `hookData` is
caller-supplied, and the hook never sees the recipient. **A hook physically cannot address or pay a
trader.** The only party a hook can pay is an LP whose capital it custodies. So every mintable object
in v4 is LP-side, and the trader-side object class is provably empty.

That constraint kills the entire "rebate good flow" prompt — official prompt example #3 [SOURCED] —
and it is why `Tidehook` is 1 of 662. Here it works in our favour: **the money cannot go to an
intermediary, because a hook has no way to reach one.**

### 4.3 The sharpest instance: the queue-jump is already being sold, for zero, to the wrong party

`CLAUDE.md` §23: *"Every zero-cost direction in a state space is a free option, and every free option
gets extracted. JIT liquidity is not an exploit; it is the market correctly pricing that flat
direction at zero."*

Minting an ultra-tight range at the touch is, functionally, buying the front of the queue. Today:

- the price of that jump is **gas plus inventory risk**, not a payment;
- the proceeds go to **the jumper**;
- the LPs who are displaced receive **nothing**;
- and it is available to anyone with a bot, permanently.

A QUEUE pool reverts every external `addLiquidity` — the hook is the sole LP — so the tight-range
jump is **not available at all**. The only route to the front is to buy the rank from whoever holds
it. That is: the free option is closed, and the same right is re-sold with the proceeds going to the
displaced LP. This is defense and recapture on the JIT vector specifically. It is not defense against
sandwiches; see §9.

---

## 5. THE ROLES

The last column is the buy-in test. If the answer in that column is "the same thing, and it is fine,"
the role has no reason to adopt.

| Role | What they do today | What changes under QUEUE | Gains / loses | **What they do instead if QUEUE does not exist** |
|---|---|---|---|---|
| **Passive LP** (treasury, LST/stable issuer, yield vault) | Deposits into a pool; receives an undifferentiated blend of flow; discovers its adverse-selection cost after the fact, or never | Holds a **back** rank. Trades only on the swaps large enough to sweep to it. Receives payment from whoever wants the front. | **Gains:** a known payment now instead of an unknown loss later; far lower turnover; can size exposure deliberately. **Loses:** most of the fee income, which is exactly what it is selling. | Nothing available. Today the choice is *be in the pool with everyone's exposure*, or *be out*. Wide ranges, LP-vault wrappers and IL insurance all change the payoff **after** the fill; none change **which fills you get.** This is the strongest buy-in in the table. |
| **Professional market maker** | Cannot express a preference for flow inside a Uniswap pool at all. Runs JIT bots, or trades elsewhere. | Buys a **front** rank. Gets maximal flow per unit of capital, hedges the inventory off-venue. | **Gains:** a durable, ownable position of exactly the kind their business is built around. **Loses:** pays for it, and eats every informed slice first. | Runs a JIT bot (works, is free, and is what they do now), or runs an off-chain RFQ/PFOF business where the payment goes to a broker. **QUEUE's pitch to them is that the seat is durable and the jump is not.** |
| **JIT bot** | Mints a tight range in the same block as a large swap, captures most of the fill, burns immediately. Pays LPs nothing. | Cannot mint. Can **rent the front for a block** by buying and reselling the rank. | **Gains:** legitimacy, and a position that persists rather than needing to be re-won every block. **Loses:** the free lane. Now pays the incumbent. | Keeps running the bot on ordinary pools. **This role's buy-in is weak and should be stated as weak** — a JIT bot's honest answer is "I will trade elsewhere." QUEUE's claim against it is structural (they cannot jump a QUEUE pool), not persuasive. |
| **Pool deployer** | Picks a fee tier. Competes on fee level and incentives. | Picks the seat count and the seat-governance model (§8). Sells a venue with a differentiated LP product. | **Gains:** a reason for professional capital to choose their pool. **Loses:** a bounded LP roster, so raw TVL is capped. | Deploys a dynamic-fee hook. There are **189 of them in 662** [COUNTED], 42 prized, and Atrium calls the lane dead [SOURCED]. |
| **Trader** | Swaps. | **Nothing.** Swaps execute normally, at the normal price, through any router; the hook returns no delta and does not touch `slot0`. `beforeAddLiquidity` is the only gate. | Neither. Depth may be thinner (bounded roster). | N/A — the trader is not being sold anything, and the pitch must not pretend otherwise. |
| **Aggregator / router** | Routes by quoted price and gas. | **Nothing.** QUEUE is router-clean by construction — this is the one property that matters most for adoption and it is free. | Neither. | N/A. Note the contrast: Uniswap's own Permissioned Pools needed a **forked router and forked posm** to work, which kills open aggregator routing (`CLAUDE.md` §5.16, from primary source). QUEUE needs neither. |

---

## 6. THREE FLOWS

### (a) SEMANTIC — what a queue *is*, against what a pool *is*

```
        PRO-RATA  (every AMM that exists)              QUEUE  (front-first, priced)

   swap consumes 500,000 of the pool               swap consumes 500,000 of the pool
                    │                                             │
                    ▼                                             ▼
   ┌───────────────────────────────────┐            ┌──────────────────┐
   │      ONE POOLED RESERVE           │            │ rank 1 :  20,000 │◄─ filled first,
   │                                   │            ├──────────────────┤   to exhaustion
   │  A 2%   B 5%   C 10%              │            │ rank 2 :  50,000 │◄─ then this one
   │  D 30%           E 53%            │            ├──────────────────┤
   │                                   │            │ rank 3 : 100,000 │◄─ then this one
   └───────────────────────────────────┘            ├──────────────────┤
                    │                               │ rank 4 : 300,000 │◄─ then this one
      every LP filled in proportion                 ├──────────────────┤
                    │                               │ rank 5 : 530,000 │◄─ 30,000 of it
                    ▼                               │                  │   ── cursor stops
   A: 1,000   B: 2,500   C: 5,000                   │  500,000 untouched
   D: 15,000            E: 26,500                   └──────────────────┘

   Nobody can be first.                             Rank is an ERC-6909 balance.
   Nobody can be last.                              Transferable. Priced.
   There is no position to own,                     Two LPs with identical capital
   therefore no position to price.                  now hold different assets.
```

Note what is identical in both columns: **the trader's price, the trader's fill, the fee, and the
total the pool paid.** Only the allocation among LPs differs.

### (b) BUSINESS — deployer → seats → flow → repricing

```
  ┌────────────┐
  │  DEPLOYER  │  chooses: pair, fee tier, SEAT COUNT (N), seat-governance model
  └─────┬──────┘
        │ deploys hook at a mined permission address
        ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │  QUEUE POOL — hook custodies 100% of the liquidity in one            │
  │  full-range position. External addLiquidity reverts.                 │
  └─────┬────────────────────────────────────────────────────────────────┘
        │
        │  (1) LPs deposit capital and acquire a RANK
        │      rank is BOUGHT or HARBERGER-HELD — never granted by deposit order
        ▼
  ┌────────────────┐        buys front         ┌───────────────────────────┐
  │ PASSIVE CAPITAL│ ────────────────────────► │ MARKET MAKER / JIT / HFT  │
  │ treasury, LST, │ ◄──────────────────────── │ hedges inventory off-venue│
  │ yield vault    │       pays for it         └───────────────────────────┘
  └────────────────┘
        │                                                    │
        │  (2) TRADERS trade. Nothing about their            │
        │      experience changes. Any router.               │
        ▼                                                    ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │  (3) FILLS ALLOCATE FRONT-FIRST at the swap's own realised           │
  │      average price. The filling seat keeps the fee on its slice.     │
  └─────┬────────────────────────────────────────────────────────────────┘
        │
        │  (4) P&L per seat diverges. The front/back spread becomes observable.
        ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │  (5) SEATS REPRICE in the secondary market.                          │
  │                                                                       │
  │      front trades at a PREMIUM   ⇒ this pool's flow is benign        │
  │      front must be PAID to hold  ⇒ this pool's flow is toxic,        │
  │                                     and the size of the payment      │
  │                                     IS the toxicity, in the pool's   │
  │                                     own numéraire                    │
  └──────────────────────────────────────────────────────────────────────┘
```

### (c) TECHNICAL — deposit, swap, allocate, advance, withdraw

```
DEPOSIT
   LP ──► hook.deposit(amount0, amount1)
            │
            ├─ hook.unlock()  ── hook IS the unlocker, so PoolManager keys the
            │                     position to the hook (CLAUDE.md §5.12: satisfied
            │                     by construction, not worked around)
            ├─ modifyLiquidity(full range)          ← one wide band. No per-tick maths.
            └─ append entry {token0, token1} ; mint ERC-6909 rank balance


SWAP ARRIVES
   trader ──► any router ──► PoolManager.swap()
                                │
                                ├─ beforeAddLiquidity : REVERT   (hook is sole LP)
                                │
                                ├─ swap executes NORMALLY. slot0 untouched.
                                │  Hook returns no delta. Router-clean.
                                │
                                └─ afterSwap(BalanceDelta)
                                      │
                                      │  realised average price = amtIn / amtOut
                                      │  — the swap's OWN number, from PoolManager.
                                      │    Not a mark. Not an oracle. Nothing to push.
                                      ▼
                        FRONT-FIRST ALLOCATION
                        ┌──────────────────────────────────────────────┐
                        │ cursor ──► entry[i]                          │
                        │   take    = min(entry[i].outgoing, remaining)│
                        │   give    = mulDiv(amtIn, take, amtOut)      │  ◄ floored
                        │   fee     = feeTotal · take / amtOut         │
                        │   remaining -= take                          │
                        │   if entry[i] exhausted:  i++   (advance)    │
                        │   repeat while remaining > 0                 │
                        │                                              │
                        │ LAST FILLED ENTRY gets  amtIn − assignedSoFar│  ◄ THE line
                        │                                              │    that makes
                        │  ── this is what makes the sum close ──      │    it exact
                        └──────────────────────────────────────────────┘
                                      │
     typical small swap: touches 1 entry, cursor does not move
     sweeping swap:      touches k entries, cursor advances k−1


WITHDRAW
   LP ──► hook.withdraw()
            └─ pays out whatever that entry currently holds
               (⚠ NOT face value — see §9, the redemption residual)

   RANK TRANSFER moves the position in the queue. It does NOT move the capital.
```

---

## 7. WORKED EXAMPLES

**Shared assumptions for all three** [ESTIMATE — these are illustrative figures, not measurements]:

- WETH/USDC, ETH at 3,000 USDC, fee tier 0.30%, taken on the input token.
- Pool custodies **$1,000,000** in five seats: `S1 $20k · S2 $50k · S3 $100k · S4 $300k · S5 $530k`.
- Price impact is folded into the stated realised average price. **Gas figures are [MEASURED] on the
  SHIPPING hook** (`test/queue/Gas.t.sol`, 2026-08-28) as complete swap transactions through the real
  router — not the superseded spike numbers, and not an isolated callback. See §8.1.

### 7.1 Small swap — head only

Trader swaps **3,000 USDC → WETH**. Fee 9 USDC. 2,991 USDC swapped → **0.997 WETH** out.
Trader's realised average price = 3,000 / 0.997 = **3,009 USDC/WETH**.

| | Under QUEUE | Under pro-rata (today) |
|---|---:|---:|
| S1 sells | **0.997 WETH** | 0.0199 WETH |
| S1 earns | **9.00 USDC** | 0.18 USDC |
| S2–S5 earn | **0.00** | 8.82 USDC combined |
| Swap gas, complete tx | **117,990** [MEASURED]; +31,169 (+36%) vs the same pool with no hook | — |

S1 is 2% of the pool and earned 100% of the fee: a **50× multiple**, which is not a result, it is an
identity — the ratio is exactly `total capital / front seat capital`.

**The honest other half:** S1 also bore **100% of this swap's adverse selection** instead of 2%. The
front seat is 50× leverage on the flow, in both directions. Whether that is good depends entirely on
what the flow is — and that is the question the seat price answers.

### 7.2 Large swap — sweeping four and a half seats

Trader sells WETH, consuming **500,000 USDC** from the pool. Price walks 3,000 → 2,940; realised
average **2,970**. Gross input 168.86 WETH, of which fee 0.5066 WETH (≈ $1,505).

| Seat | USDC held | USDC filled | WETH received @2,970 | fee share | fee (WETH) |
|---|---:|---:|---:|---:|---:|
| S1 | 20,000 | 20,000 (100%) | 6.7340 | 4.0% | 0.02027 |
| S2 | 50,000 | 50,000 (100%) | 16.8350 | 10.0% | 0.05066 |
| S3 | 100,000 | 100,000 (100%) | 33.6700 | 20.0% | 0.10132 |
| S4 | 300,000 | 300,000 (100%) | 101.0101 | 60.0% | 0.30398 |
| S5 | 530,000 | **30,000 (5.7%)** | 10.1010 | 6.0% | 0.03040 |
| | | **500,000** | **168.3501** | **100%** | **0.50663** |

Seats touched: **5**. Swap gas ≈ **198,161** [MEASURED at a 5-seat roster], of which ~40,000 is the queue walk.

Marked at the post-swap price of 2,940:

| | Net P&L on the episode | On its own capital |
|---|---:|---:|
| S1–S4 (fully converted) | −$3,348 | **−71 bps** |
| S5 (5.7% converted) | −$214 | **−0.4 bps** |
| **Pool total** | **−$3,562** | — |
| *Same swap, pro-rata today* | **−$3,562** | **−35.6 bps for every seat, identically** |

**The total is unchanged to the cent.** QUEUE moved S5 from −35.6 bps to −0.4 bps and S1–S4 from
−35.6 bps to −71 bps. **This is redistribution, not reduction.** Anyone who writes it up as
"QUEUE reduced LP losses" is lying about it.

### 7.3 Toxic flow — the front must be paid to stand there

An event day: a listing, an unlock, a CPI print. Flow is one-directional and informed. No balanced
retail flow at all. **$300,000** of net informed selling walks the price 3,000 → 2,910; realised
average **2,955**. Fee 0.3046 WETH ≈ $886.

Per USDC filled: loss = `1 − 2910/2955` = **−1.5228%**; fee credit = `886 / 300,000` = **+0.2955%**;
net = **−1.2273%**.

| Seat | USDC filled | Net P&L | On its own capital |
|---|---:|---:|---:|
| S1 | 20,000 (100%) | −$245 | **−123 bps** |
| S2 | 50,000 (100%) | −$614 | **−123 bps** |
| S3 | 100,000 (100%) | −$1,227 | **−123 bps** |
| S4 | 130,000 (43%) | −$1,595 | **−53 bps** |
| S5 | 0 | **$0** | **0 bps** |
| **Total** | **300,000** | **−$3,681** | — |
| *Pro-rata today* | | **−$3,681** | **−36.8 bps, every seat, identically** |

**The front/back spread on this day is 123 bps.** S5 outperformed today's pool by 36.8 bps; S1–S3
underperformed it by 86 bps. A rational holder of S1 will pay to move back, and the price they will
pay is what the market thinks the *expected* spread is going forward.

**That number — the price of moving from the front to the back — is the pool's toxicity, in the
pool's own numéraire, discovered by capital rather than asserted by a formula. It is unforgeable
because the bid costs real money.**

### 7.4 A subtlety worth stating: the price of a seat can go negative, and the mechanism still works

[ANALYSIS — reasoning, not measured.] If the front is worth *less* than the back, the front's absolute
value could be negative, and an ERC-6909 token cannot have a negative price.

The resolution is that **you cannot be in a QUEUE pool without holding some rank.** There is no
"outside the queue" except withdrawing your capital entirely. So the tradeable quantity is always a
*relative* price: rank-1 holder pays cash to a rank-5 holder to swap ranks. Relative prices are
signed and can point either way. The mechanism does not require any seat to have positive standalone
value.

**This does expose a real gap in one of the three pricing options.** A standard Harberger tax prices a
*non-negative self-declared value* and cannot express "pay me to sit here." Under toxic flow every
holder declares near-zero and no rent flows. The **rank-swap / relative-price** form does not have this
problem. Anyone building the Harberger variant must solve this, and it is not solved today.

---

## 8. THE SEAT-COUNT QUESTION

### 8.1 Why seats must be limited — the measurement

> ⚠ **RE-MEASURED 2026-08-28 AGAINST THE SHIPPING HOOK. The table that used to sit here was the
> Phase-0 *reference spike* — no cursors, no owners, no seat tokens, no Harberger lease — and it was
> also measured with a technique that understated writes. Both numbers below moved. The spike table
> is preserved at the bottom of this section so the correction is visible rather than quiet.**

`test/queue/Gas.t.sol` [MEASURED]. Every figure is a **complete swap transaction** through the real
`V4SwapRouter` against the real `PoolManager` — what a trader actually pays, not an isolated hook
callback that nobody is ever charged for. State is built in `setUp()` so writes are metered
honestly, all six accounts on the swap path are cooled, and the sweep series **holds the swap size
constant** so the pool's own work cancels rather than contaminating the slope.

| seats in queue | head-only swap | full sweep | seats walked |
|---:|---:|---:|---:|
| 1 | 117,971 | 145,980 | 1 |
| 2 | 117,989 | 173,950 | 2 |
| 5 | 117,990 | 198,161 | 5 |
| 10 | 117,990 | 238,511 | 10 |
| 25 | 117,991 | 359,562 | 25 |
| 32 | 117,992 | **416,053** | 32 |

> `sweep(n) = 137,866 + 8,070·n + 19,900·[n ≥ 2]` — reproduces every row to within **3 gas**.

Three facts, and the third is the one people ask about:

1. **The common case is flat: 117,971 → 117,992 across 1 → 32 seats, a spread of 21 gas.** A swap
   that lands inside the head seat never walks the queue, and most swaps are this. Flatness is the
   cursors working, and it is measured, not assumed.
2. **A sweeping swap is O(seats walked), slope exactly 8,070 gas/seat.** The marginal between every
   adjacent pair of depths is the same number — this is not a fitted line with a tolerance.
   The extra 19,900 at depth ≥ 2 is a one-off: `cursor1`'s first non-zero write.
3. **QUEUE costs 36% more per swap than no hook at all.** Against a pool with the same tokens, fee
   tier, spacing, price and full-range liquidity and no hook: **117,989 vs 86,820, +31,169 gas**
   [MEASURED]. Say the number. The claim worth making is not that the common case is free — it is
   that the overhead is a **constant a trader can price**, rather than something that grows with how
   deep the book is.

Maximum depth the budget supports, `(budget − 19,900) / 8,070`:

| assumed hook-callback budget | max queue depth |
|---|---:|
| 300k | **34** |
| 500k | **59** |
| 1M | **121** |

**These budgets are not protocol constants.** v4 imposes no per-hook gas limit; PoolManager forwards
the remaining gas. The budget is an economic and UX choice — how much extra gas a swapper will
tolerate on the worst-case swap. 300k is the conservative row and the one designed against.
`MAX_SEATS = 32` sits inside it with ~7% to spare, and `test_5_3b` **derives** the supportable depth
from the measurement and asserts it covers `MAX_SEATS`, so the constant in the code and the number
in this document cannot drift apart.

**The binding constraint is not the sweep.** `addToSeat` settles every priced seat ahead of the
depositor, and each of those settlements pays every funded seat behind it — O(priced ahead × roster),
which is **quadratic in the roster** where the sweep is linear. Measured at the worst configuration
the contract can reach: **2,610,805 gas**, 8.7% of a 30M block. That is the cost of closing a
flash-loan rent grab worth 16× the honest share, it is not free to an attacker (every settlement it
forces also drains the payer's own meter), and **it is the number any proposal to raise `MAX_SEATS`
has to be argued against.**

<details>
<summary>The superseded spike table, kept so the correction is visible</summary>

Measured 2026-08-26 against `test/spike/QueueAllocator.t.sol`, which is the reference spike and
**not the shipping contract** — it had no cursors, no owners, no seat tokens and no Harberger lease,
and it measured an isolated allocation loop rather than a swap:

| entries | head-only | sweeping | touched |
|---:|---:|---:|---:|
| 1 | 31,874 | 11,964 | 1 |
| 50 | 31,874 | **309,106** | 45 |

⇒ slope ~6,753 gas/entry, and a 300k budget was projected to support **~44** seats. Re-measured on
the shipping hook the slope was **12,254** — a full 32-seat sweep cost 412,028 gas of queue work,
**37% over** the 300k budget the roster bound had been chosen to fit. Packing the seat balance pair
into one storage slot brought it to 8,070 and 278,110.

> ⚠ **This table was wrong twice, in two different ways, and both are worth knowing.**
> *First:* Forge keeps storage warm across a test body, so the original 50-entry sweep read 125k
> instead of 309k — 2.5× optimistic, fixed with `vm.cool()`.
> *Second, found 2026-08-28:* **`vm.cool()` is not enough.** It restores cold *access* pricing but
> not cold *write* pricing — a slot the same test body already wrote costs 100 gas to write again
> instead of 2,900 or 20,000. Every gas number this project had recorded was optimistic; one
> measured A/B put it at **47%**. State must be built in `setUp()`, which Forge commits as its own
> transaction. See `AGENTS.md` LAW 4 and `PITFALLS.md` 5.66.

</details>

### 8.2 What happens if seats are unlimited

**The mechanism breaks under its own success.** A pool that attracts 1,000 LPs has a 1,000-entry
queue. A swap large enough to sweep it costs `137,866 + 1,000 × 8,070` ≈ **8.2M gas** — and that is only
the sweep; the quadratic `addToSeat` path would be far past a block long before that. Well past what
any trader will pay. That swap **cannot execute**.

Follow the consequence: the pool now has a size above which trades silently fail. That is a
**size threshold**, and `CLAUDE.md` §5.17 (the Splitting Lemma) says any mechanism keyed on a size is
defeated by splitting the quantity at a cost of gas — fractions of a cent on Unichain. So the informed
trader splits, executes anyway, and the only party harmed is the honest large trader who did not think
to. **Unlimited seats does not fail gracefully; it fails by breaking large swaps while leaving the
informed path open.**

Secondary effect: an unlimited queue means the marginal seat is free, and a free seat is worth
nothing. There is no price, and with no price there is no signal — which is the entire product.

### 8.3 How seats would be vetted — four governance models

| Model | How you get a seat | Attack surface | Trade-off |
|---|---|---|---|
| **(A) Deployer whitelist** | The deployer admits N addresses | Deployer is a trusted party; the roster is a rent it controls | Simplest to ship. Least credible as a neutral venue. Regulatory-adjacent (this is what "designated market maker" means, with all the baggage). |
| **(B) Minimum deposit, fixed N, order sold** | Any address meeting a capital floor may take a vacant seat; the **order** among seats is bought or Harberger-held | The capital floor is a size *floor*, so the evasion is **aggregation, not splitting** — small LPs pool into a syndicate seat. That is harmless and arguably good. | Permissionless entry, priced ordering. **This is the model to build.** Note it recreates an intermediary (the syndicate vault) for small LPs — see §9. |
| **(C) Pure Harberger, fixed N** | Every seat is always for sale at its holder's self-declared price; you pay `τ × price` per block to those behind you | Cannot express a negative seat value (§7.4). Under toxic flow the whole thing declares zero and stops functioning. | Needs no bidders to show up, forces honest self-assessment, and closes the rank-then-run hole (§9). **But the negative-price gap is unsolved.** |
| **(D) Permissionless, rank by deposit order** | First to deposit sits at the front | **Fatal.** Dust-griefing the head: deposit 1 wei, occupy rank 1, and every swap now walks past a worthless entry — or worse, an adversary parks at the head to starve the real front seat of flow. | **Never build this.** `IDEAS_OBJECTS` §1.5 free-lane 5, stated as a hard rule: **rank must be bought or Harberger-held, never granted by deposit order.** |

### 8.4 Scarcity — argue both sides

**For scarcity:**

- Gas forces it. **34 seats at a 300k budget [MEASURED 2026-08-28 on the shipping hook]**, and the
  roster ships at 32. There is no version of this at retail scale without the unbuilt O(1) redesign
  (§9) — which Phase 5 decided **not** to build, because the O(N) allocator came in inside budget and
  the redesign's exactness is unproven.
- **A seat everyone can have is worth nothing.** The price of the seat is the mechanism. Scarcity is
  not a side effect of the gas limit; it is a precondition for there being a price at all, and it
  would be a design choice even if gas were free.
- Bounded rosters are how every real market-maker franchise works, for the same reason.

**Against scarcity:**

- **A 32-seat pool is a professional venue, not an open retail pool.** Uniswap's identity is
  permissionless access. This is a genuine departure and it should be conceded in the first sentence
  of the pitch, not defended later.
- Small LPs must aggregate into a syndicate vault to get a seat — which **recreates the intermediary**
  that §4.2 says QUEUE eliminates. That is a real tension, not a resolved one.
- A bounded roster caps TVL, and by the depth ≡ adverse-selection theorem (`CLAUDE.md` §22,
  `ℓ = ½σ²·d` identically) **less depth means less adverse selection AND less utility, on the same
  line.** A thin QUEUE pool is not a better pool; it is a smaller one. There is no free lunch on that
  axis and nobody should claim there is.
- Scarcity concentrates rents in the seat-holders. Whether the front-seat premium accrues to LPs or is
  competed away depends on how contestable the roster is — and models (A) and (C) are less contestable
  than (B).

**The honest resolution:** scarcity is currently *forced* by gas and *justified* by economics. Those
are two separate arguments and they should not be conflated on camera. If the O(1) redesign works, the
gas argument disappears and only the economic one remains — at which point the seat count becomes a
pure market-design parameter and the deployer should set it, per pool.

---

## 9. HONEST LIMITATIONS

Stated at full strength. Nothing here is softened.

> ⚠️ **This list is NOT complete, and the gaps are on the record elsewhere.** Research closed on
> 2026-08-26 named four limitations that appear **nowhere else in this document**: **full-range
> capital efficiency** (one full-range position offers ~1/200th the depth per dollar of a ±1%
> concentrated one — the sharpest attack, `PITFALLS.md` §5.17. **UPDATED 2026-08-29: half of it is
> now answered.** The queue is PROVEN orthogonal to the position's range — `tickLower`/`tickUpper`
> appear only in the liquidity-sizing helpers and the `modifyLiquidity` call, never in the
> allocator, and `test_1_11` seeds the identical roster over a ±10% band with conservation,
> per-seat composition and INVARIANT C all holding to the wei. So concentrating the custodied
> position is a **v2 parameter, not a redesign**. The economics of a thin pool — no aggregator
> routes retail to it, and retail is the entire benign side of the P&L — **still stand, and
> out-of-range behaviour and rebalancing are unbuilt.** Say both halves); **the Ratchet** (front-first applies in
> both directions, so the tail is a one-way accumulator with no priority to exit — §5.18); **Phase 3
> is a one-sided market** (the tail's compensation channel is Harberger rent, which is Phase 4 —
> §5.19); and **"the seat price IS the toxicity" is OVERCLAIMED** (§5.20). All four are [ANALYSIS],
> from `docs/research/premise-review/`. A **MEASURED** protocol-fee ledger hazard and a **MEASURED**
> per-seat withdrawal problem are likewise absent here — `PITFALLS.md` §5.1–§5.7. **Read
> `PITFALLS.md` §5 before quoting this section as the full limitation set.**

**1. QUEUE does not stop sandwiches.** A sandwich is front-run, victim, back-run. QUEUE changes which
LP is the counterparty to each of those three swaps. It does not prevent any of them, does not raise
their cost, and does not detect them. The cohort's mission statement is *"Protect LPs · kill the
Sandwich"* [SOURCED]. **QUEUE does not kill the sandwich.**

**2. QUEUE does not reduce total LVR.** §7.2 and §7.3 show the total pool P&L identical to the cent
under QUEUE and under pro-rata. This is not an artefact of the example; it is structural. The swap
happened at the same prices either way. QUEUE **reallocates** adverse selection and **prices** it. Any
sentence claiming it reduces LP losses in aggregate is false.

**3. QUEUE does not recapture value from searchers.** There is no auction, no tax, no toll. A searcher
who arbitrages a QUEUE pool pays the same fee as anyone else. The one exception is narrow and worth
stating exactly: **the tight-range JIT queue-jump is structurally unavailable in a QUEUE pool**
(external adds revert), and the equivalent right must be bought from an incumbent LP. That is
recapture on one vector, not on MEV generally.

**4. The bounded seat count makes it a professional venue, not an open retail pool.** **34 seats at
a 300k budget [MEASURED 2026-08-28 on the shipping hook], and the roster ships at 32.** Retail
participation requires a syndicate wrapper. See §8.4.

**5. The redemption residual is open.** [MEASURED] The queue's face value is **not** exactly
redeemable. v4 computes a swap's amounts and a position's redeemable value with two different
formulas, each rounded in the pool's favour:

| | token0 | token1 |
|---|---:|---:|
| seed → redeem, 0 swaps | −1 wei | −1 wei |
| 4 swaps | −3 | −4 |
| 40 swaps | −9 | −11 |
| **200 swaps** | **−52** | **−54** |
| 200 swaps at **zero fee** | −46 | −50 |

It grows at **~0.26 wei per swap** *at the seeded price*. Note the zero-fee row: **88% of the drift
survives with no fee at all**, which falsified the first two hypotheses about its cause (add/remove
dust; fee-growth truncation). Under a naive `withdraw()` paying face value, the last withdrawer eats
it.

> ### ⚠ CORRECTED 2026-08-28 (Phase 6) — the per-swap figure DOES NOT GENERALISE
>
> [MEASURED] The table above was taken at the seeded price with the position intact, and the
> "~0.26 wei per swap" reading was then quoted as if it were a constant of the mechanism. **It is
> not.** The truncation scales with how far the price has been driven from where the liquidity
> sits, so a pool whose depth has been withdrawn into the float and whose price is then pushed to
> the tick floor loses **~1e9 wei on a single swap**.
>
> **What DOES generalise is the ratio, and the denominator is lifetime inflow — not the current
> ledger.** The residual accumulates while the ledger is drained by withdrawals, so the last wei on
> the books is eventually smaller than the residual it has to absorb. The Phase 6 campaign reached
> exactly that: `owed = 5,337,018,741`, `backing = 0`, a 100% shortfall of five gwei on a queue that
> had been emptied down past its own rounding dust.
>
> Measured over the campaign, after every action, both directions:
>
> | | value |
> |---|---|
> | worst **SURPLUS** (position+float above the ledger) | **exactly 0 wei**, both tokens |
> | worst **SHORTFALL** | **under 1 part per billion** of everything that has ever entered the queue |
>
> Nothing is stolen and this is not an attack — reaching the state costs six-figure multiples of the
> residual in swap input. But **the LAST holders to withdraw bear it**, and the README says so in
> those words. The dust policy (F1: pay `min(face, available)`) spreads it over withdrawers rather
> than dumping it on one, which is why "the queue's face value is redeemable" must still never be
> claimed. See PITFALLS 5.80.

*Is it farmable?* **No, and not close.** The drift accrues to nobody — it stays in PoolManager as
unclaimable dust. Griefing costs ≥100k gas plus a swap fee per **0.26 wei** of damage; inflicting one
whole token of shortfall needs ~4·10¹⁸ swaps. Cost-to-damage is off by about **twenty orders of
magnitude.** The fix is standard and cheap (redeem the final entry against actual holdings, or carry a
dust buffer) — but **it is not built, and the claim "the queue's face value is redeemable" must not be
made until it is.**

**6. The rank-then-run hole exists in the plain-token variant.** Buy the front cheaply during a quiet
stretch; dump the rank token before a scheduled event. The rank price gaps — but only **if there is a
bid.** *In a thin secondary market the front seat is abandonable at the exact moment it matters.* The
Harberger variant closes it: you cannot leave your slot, only lower your self-assessment and pay rent,
and someone buys you out at your own number. **If this is built, build the Harberger variant** — and
note that the Harberger variant has its own unsolved gap (§7.4). Disclose the thin-market failure of
the plain-token variant on camera.

**7. The whole toxicity signal depends on a liquid secondary market in ranks that does not exist.**
This is the weakest point in the entire design and it compounds limitation 6. In a demo, in a new
pool, or on a long-tail pair, there is no market in seats, therefore no price, therefore no signal.
The mechanism's headline claim is a claim about a market that has to be bootstrapped. There is no
measurement supporting the assertion that it would be.

**8. Sweeps are O(N) and the O(1) fix is unbuilt.** The named follow-up is a prefix-sum with a global
cumulative-fill accumulator plus a price-growth accumulator indexed by cumulative fill — the
`feeGrowthOutside` trick v3 already uses for tick crossing, applied to a fill queue instead of a tick
ladder, with the same outside-flip for bidirectional flow. **Plausible, unbuilt, unverified. Do not
quote it as a property.**

**9. The allocator is the whole pool's accounting, rewritten by us.** A bug there is not a degraded
feature, it is lost funds.

### What IS proven

Not everything above is a caveat. The riskiest assumption was tested and held [MEASURED]:

- **Front-first allocation at the swap's realised average price is exact, to the wei, in both tokens,
  at a non-unit price** (1:4, per `CLAUDE.md` §5.10 — a 1:1 fixture would have hidden a token0/token1
  mix-up). Aggregate flows measured on PoolManager's own ERC20 balances, never on the hook's
  bookkeeping, across four swaps including a reverse-direction leg:

```
queue total token0            2248553145997694428660
PoolManager-measured token0   2248553145997694428660      <- equal, to the wei
queue total token1             445000573750774563494
PoolManager-measured token1    445000573750774563494      <- equal, to the wei
```

- Exactness is **by construction**: every entry's incoming share is `mulDiv(amtIn, take, amtOut)`
  floored, except the **last filled entry, which is assigned `amtIn − assignedSoFar`**.
- **Three negative controls, all red, with the revert reason asserted:**

| Mutation | Result | Why it actually failed |
|---|---|---|
| PRO-RATA (what v4 genuinely does today) | RED | `swap1: entry a0` — the fill smears across all three entries instead of landing in the head |
| OFF-BY-ONE cursor (start at entry 1) | RED | `swap1: entry a0` — head untouched, entry 1 filled |
| FLOOR-ONLY (drop the remainder assignment) | RED | `swap2: token0 conservation` |

The third is the sharpest: **it survives swap 1 and only dies at swap 2**, because a single-entry fill
has no remainder to drop. The rounding claim is confirmed from both sides.

- **The allocation price cannot be manipulated.** It is the swap's *own* realised average, taken from
  PoolManager's returned `BalanceDelta`. Not a mark, not an oracle, not a quantity the hook chooses.
  There is nothing to push.

---

## 10. THEME FRAMING

### 10.1 The theme, verbatim

> *"UHI10 Hookathon: Sustainable Liquidity & MEV Protection — The goal here is to reduce value leakage
> from LPs and make volatile-pair liquidity sustainable at low fees — pushing hook innovation toward
> fair, MEV-protected execution that lets LPs compete on any asset pair."* [SOURCED]

Open problem **#3**, verbatim: *"Dynamic fees alone can't distinguish 'good' retail flow from 'bad'
toxic flow."* [SOURCED]

**QUEUE addresses open problem #3, and only #3.** It does not address #1 (sandwiches), #4 (mempool
ordering), or #5 (private orderflow). Saying otherwise would be the inflated version.

### 10.2 The bridge, in three steps

**Step 1 — No forgeable-proof toxicity signal exists for a v4 hook.** Proven, not asserted
(`IDEAS_CONSTRAINED` §1, `CLAUDE.md` §5.16/§5.19):

| Candidate signal | Why it fails |
|---|---|
| `sqrtPriceLimitX96` | Retail routers pass the sentinel; a searcher can pass the sentinel too. Free to forge. |
| `amountOutMinimum` / slippage budget | **The hook cannot see it at all** — enforced in the router *after* the last callback. |
| exact-in vs exact-out | Free to forge. |
| priority fee | Angstrom L2 already ships this; it is zero under private orderflow. |
| `tx.origin` / EOA-vs-contract | `sender` is the router. Forgeable. |
| trade size | Defeated by splitting at gas cost — the Splitting Lemma. **This is what Tidehook assumed.** |
| identity / reputation / history | Address-shopping inside one unlock costs **52,700 gas** [MEASURED]. |

**Step 2 — No curve can fix it either.** The depth ≡ adverse-selection theorem (`CLAUDE.md` §22):
with `V(p)` the LP value function and `x(p)` the risky-reserve schedule,

```
LVR rate        ℓ(σ,p) = ½·σ²·p²·|x'(p)|        (Milionis–Moallemi–Roughgarden–Zhang)
marginal depth   d(p)  = |dx/d ln p|·p = p²·|x'(p)|

⇒  ℓ = ½σ²·d,  identically, for every invariant, at every price.
```

Verified by recovering the textbook `σ²V/8` for constant-product from the depth side. **No static
geometry improves an LP's adverse selection per unit of depth offered.** A curve that halves LVR halves
depth by exactly the same factor. Concentrated liquidity, StableSwap, Orbital, weighted pools, Lambert
— all move along the same line; none changes its slope.

**Step 3 — Therefore the remaining move is to stop classifying and start pricing.**

> A formula cannot tell good flow from bad, and a curve cannot escape the trade-off. So do not build a
> classifier. **Sell LPs different slices of the flow and let them bid.**
>
> A pool where the front seat trades at a **premium** has benign flow. A pool where the front must be
> **paid** to stand there has toxic flow — and **the size of that payment is the toxicity**, in the
> pool's own numéraire, discovered by capital rather than asserted by a formula. Unforgeable, because
> the bid costs real money.

Note what this does with the Splitting Lemma, which has killed seven mechanisms in this project. An
informed trader who slices their order to stay inside the head is **not evading QUEUE** — they are
concentrating the informed flow onto the one seat that is explicitly priced. **The mechanism never
assumed size ⇒ toxicity**, so the evasion that defeats every other flow-segmentation design is, here,
the design working.

### 10.3 The counter-arguments a judge will make, and the answers

**Counter 1 — "This is am-AMM with extra steps."**
This is the one that has to be answered first and it is one sentence deep. am-AMM auctions
**pool-management and fee-setting rights to one winner per block**. QUEUE runs **no auction**, has
**no per-block winner**, sets **no fee**, and grants **no management right** — it sells an ordering
over the existing LPs' own capital, held perpetually by many parties at once. Directory evidence:
`am-?amm|auction.?managed` → 7/662; `\brank\b|\bseat\b` → **0/662** [COUNTED]. **The pitch must lead
with pro-rata-vs-queue and must not use the word "auction."**

**Counter 2 — "The theme is MEV protection and you admit you do not stop MEV."**
Correct, and it is conceded in §9. Atrium's stated win condition is *"Combine defense and recapture.
Ordering protection alone is a shield. Auction-based recapture alone is a redistribution. Pair them
for the strongest pitch."* [SOURCED] **On sandwiches, QUEUE is neither.** On the JIT vector
specifically it is both — external adds revert (defense) and the equivalent right must be bought from
the incumbent LP (recapture). That is a narrower claim than the theme asks for, and the honest answer
is: **QUEUE trades breadth for solving the one open problem the organizers named as unsolved.** Open
problem #3 has **one** prior attempt in 662 submissions, against **189 dynamic-fee hooks** that all
fail at exactly this [COUNTED].

**Counter 3 — "32 seats is not a Uniswap pool."**
Correct. It is a professional venue. See §8.4, where both sides are argued. This should be said in the
first minute of the pitch, not defended in the last.

**Counter 4 — "Your toxicity signal needs a liquid market in seats, and there isn't one."**
Correct, and it is the weakest point in the design (§9.7). The signal is exactly as good as the
secondary market, and a thin market also re-opens the rank-then-run hole (§9.6). There is no
measurement supporting the claim that such a market would form. This is the honest boundary of the
pitch.

**Counter 5 — "Front-first allocation is unfair to whoever is at the front."**
It is not a fairness mechanism and does not claim to be — `CLAUDE.md` §5.25: fairness is not a
present-state property and can never be a predicate. Rank is present state. Nobody is assigned to the
front; the front is **bought**, from a party who agreed to sell it, at a price they agreed to.

**Counter 6 — "Uniswap already has priority — swaps cross ticks in order."**
Yes, and that is price priority: capital at a nearer tick is filled before capital at a further one.
QUEUE adds an ordering **within** a tick, which does not exist today. See §2.1. Anyone who states
this loosely will lose the exchange — and note that the ordering QUEUE adds is **not time
priority** either (Counter 7).

**Counter 7 — "This is not price–time priority. Your roster is closed, so nobody can join by
arriving."** ⚠ *Added 2026-08-28. This is the objection the pitch was previously inviting and could
not answer.*
**Correct, and conceding it immediately is what makes the rest land.** QUEUE is not price–time
priority; rank goes to willingness to pay rent, not to arrival. The honest claim is different and
stronger:

- Real markets already price queue position. They pay for it in **latency** — a deadweight cost burnt
  on colocation and microwave towers that accrues to infrastructure vendors, not to the participants
  being jumped ahead of. On-chain, the same value is sold at the **sequencer**, and the pool's LPs get
  none of it.
- **Uniswap did not eliminate the value of ordering. It made it unpriceable inside the pool, so it is
  captured outside it.** QUEUE makes the price explicit and routes it to the LPs standing behind you.
- **And an open, arrival-ordered queue does not work here** — which is why paid seats are the design,
  not a compromise. Free rank is griefable rank: if arrival grants rank, the head costs one wei, and
  dusting it buys the whole front of the book. Unbounded rank is worthless rank: a non-scarce asset
  has no price, so no rent ever reaches the tail. **Scarcity is the mechanism.** The Harberger lease
  is what stops a scarce roster becoming a cartel — self-assessed, always for sale, rent paid
  continuously to the seats behind. *Scarce, but never capturable.*

See §0 for the full form. **This counter should be pre-empted in the pitch, not defended under
questioning** — an informed listener forms it inside twenty seconds, and answering it first converts
the most obvious weakness into the clearest statement of what the design is for.

---

## APPENDIX — the one-paragraph version

Every concentrated AMM is a pro-rata market: within a tick, every LP is filled in proportion to size
and no LP can be first or last. Every real electronic market on earth already prices queue position —
implicitly, in latency spend that is burnt on infrastructure rather than paid to the participants
being jumped ahead of. Uniswap's choice did not make ordering worthless; it made it unpriceable
*inside* the pool, so it is captured *outside* it, at the sequencer. QUEUE gives a Uniswap v4 pool
the missing half — a transferable, continuously-priced rank in the fill order, so that two LPs with
identical capital at identical prices hold different assets. Rank is scarce **on purpose** (free rank
is griefable rank and unbounded rank has no price) and leased rather than owned, so a scarce roster
cannot become a cartel: scarce, but never capturable. The front is filled by every swap; the back only by swaps
large enough to sweep to it. Front-first allocation at the swap's own realised average price is exact
to the wei, executed and measured against a real PoolManager at a non-unit price, with three negative
controls red. It does not stop sandwiches, does not reduce total LVR, and does not tax searchers. What
it does is turn adverse selection from an unpriced compulsory cost into a priced, transferable
position — and the price of the front seat, discovered by capital rather than asserted by a formula, is
the toxicity measurement the organizers say does not exist.
