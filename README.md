# QUEUE

**A Uniswap v4 hook that gives a pool a fill queue, and makes your place in it a tradeable,
continuously-priced asset.**

---

## The decision this challenges

Every Uniswap version — v1 through v4 — fills **pro-rata**. Inside a tick, every liquidity provider
is filled in proportion to their size. Nobody is first. Nobody is last. No amount of money buys a
better place in line.

That was not an accident and it is not a bug. Pro-rata is stateless, needs no ordering, and is
trivially permissionless. It is the right default, and it is a large part of why AMMs work at all.

But it is a **choice**, and in seven years and four major versions it has never been compared against
anything — because on Uniswap there has never been anything to compare it against.

## What the choice costs, stated precisely

Pro-rata makes LP capital **undifferentiated**. Two LPs at the same price with the same capital hold
*identical* assets. There is exactly one competitive dimension — size — and exactly one way to
express a view — move your range.

Three consequences follow, and not one of them is priced today:

- **You cannot buy priority, so priority has no price.** In every other electronic market on earth,
  being early is the single most valuable thing a maker owns. Firms spend nine figures on microwave
  towers and colocation for it. On Uniswap it is worth exactly zero, by construction.
- **You cannot sell subordination either.** There is no way to say *"fill me last, and pay me for
  it."* Senior/subordinate tranching exists in every credit, insurance and securitisation market
  ever built. It has never existed in an AMM.
- **Ordering value does not vanish — it relocates.** Ordering inside a block is real and valuable,
  and on an L2 it is already being sold, at the sequencer and builder layer. The pool's own LPs,
  whose P&L that ordering determines, receive none of it.

That third point is the one worth putting in front of a Uniswap engineer:

> **Uniswap did not eliminate the value of queue position. It made it unpriceable *inside* the pool —
> which means it gets captured *outside* the pool.**

QUEUE is the missing half. The hook custodies the pool's entire liquidity as one position and
allocates each swap **front-first** through an ordered list of seats. Two LPs with identical capital
at identical prices now hold **different assets**: one is filled by every swap that arrives, the
other only when a swap is large enough to sweep through. That rank is an ERC-6909 token —
transferable, and priced by whoever wants it.

## Why *paid seats*, and why that is not a compromise

This is the question the design lives or dies on, so here it is head-on.

The obvious alternative is an **open, arrival-ordered queue**: whoever deposits first is first,
anyone may join the back, nobody pays anything. That is what "a queue" normally means, and it is
what a reader expects when they hear the word. It fails immediately, and this repository has the
corpse:

- **Free rank is griefable rank.** If arrival grants rank, the head of the book costs one wei. Dust
  the head and you own the front of the queue forever for the price of gas, extracting the best fill
  on every trade. That was literally the first version of this hook; it is why `deposit()` no longer
  creates a seat (`PLAN.md` §B.8, §E.16; `PITFALLS.md` 5.8).
- **Unbounded rank is worthless rank.** If anyone may join the back, ordering slots are not scarce.
  A non-scarce asset has no price. With no price there is no rent; with no rent there is no payment
  to the LPs you are standing in front of; and the mechanism collapses into *"whoever arrived first
  holds a permanent free option on everyone else's flow."*

So the roster is **bounded** and the seats are **paid for**. Scarcity is not a gas concession made
reluctantly — **scarcity is the mechanism.** It is the only thing that makes rank an asset at all.

Which raises the obvious objection: a fixed set of 32 tradeable seats is a cartel. The founding
holders sit on them forever and extract rent from everyone behind them.

That is precisely why a seat is **leased, not owned** — a self-assessed, always-for-sale
**Harberger** lease:

- You post your own `selfPrice`. No oracle, no mark, no admin, nobody else's opinion.
- You pay **continuous rent on your own number**, in elapsed seconds, and it goes to **the seats
  behind you** — the tail's compensation for standing aside.
- **Anyone may take your seat at your own price, at any time.** Under-price it and you lose it.
  Over-price it and you pay for it. There is no third option.
- Rent comes from a **prepaid meter**. Let it run dry and you are **demoted to the back** — not
  liquidated, not seized. You keep the seat and every wei of its capital. You lose only your place.

**Scarce, but never capturable.** That pairing is the entire answer to *"why paid seats"*, and
neither half survives alone: a bounded roster without Harberger is a cartel, and Harberger without a
bounded roster prices nothing.

## What this makes possible that Uniswap cannot express today

**(a) The maker who wants to be *first*, not *bigger*.**
Today the only way to get more fill is more capital — and more capital means more of *everything*,
including the toxic tail. A firm with a good model and a limited balance sheet cannot say *"give me
the first $50k of flow and I will pay for it."* On QUEUE it can, and the price it pays is public,
on-chain, and updated continuously.

**(b) The LP who wants to be *last*, and be paid for it.**
The mirror is the more interesting half and nobody talks about it. Standing at the back means lower
turnover — you are reached only when a trade sweeps through the front — **and you are paid rent by
the front for standing aside.** That is a *subordinated* liquidity position with a coupon. It has
never existed in an AMM. Whether it beats the front on a risk-adjusted basis is an open empirical
question, and the point is that QUEUE is the first venue where the market can answer it.

**(c) The ordering value the sequencer is already selling.**
On any chain with an auctioned or centralised sequencer, intra-block ordering is already a priced
asset — just not one the pool participates in. QUEUE is the pool asserting that the ordering *inside
its own liquidity* belongs to its LPs, and will be priced by them.

## What it honestly is: an experiment that produces a number nobody has

We are not claiming to know the answer. We are claiming the experiment.

> Uniswap has run exactly one fill rule for seven years and hundreds of billions of dollars of
> volume. Nobody knows what the alternative is worth, because nobody has been able to build it.
> QUEUE is the first pool where you can ask **"what is being filled first actually worth?"** and get
> a continuously-updating, on-chain answer: the self-assessed price of the head seat.

It is falsifiable in both directions, and **both outcomes are results**:

- **The head seat prices near zero** → priority is worth nothing inside an AMM, pro-rata was right
  all along, and we now *know* that instead of assuming it.
- **The head seat prices high** → Uniswap has been giving away for free the one asset every other
  market in the world charges the most for.

## The objections, named and answered

| Objection | Answer |
|---|---|
| *"Pro-rata is what makes an AMM permissionless. A queue reintroduces privilege."* | The privileged position exists — and **nobody can hold it except by continuously paying for it, and nobody can be excluded from taking it.** The shipping contract has no admin, no whitelist, no upgrade path and no privileged role of any kind. Compare the status quo, where ordering privilege also exists, is unpriced, and is decided by whoever sequences the block. |
| *"32 seats is an oligopoly."* | 32 is roughly the number of serious market makers in any given pair on any venue. And the **capital is unbounded** — anyone may deposit any amount into a seat they hold. Only the *ordering slots* are scarce, and they have to be, or they have no price. |
| *"This is am-AMM."* | am-AMM auctions **management rights over the whole pool** to **one winner per block**. QUEUE sells **an ordering over the existing LPs' own capital**, perpetually, to **many simultaneous holders**, with no auction, no winner, and no per-block reference anywhere in the contract. |
| *"Toxic-flow detection is impossible."* | Correct, we proved it, and QUEUE never attempts it. It **does not classify anyone.** It sells different slices of the flow and lets capital bid — which is unforgeable precisely because the bid costs real money. |
| *"+36% gas."* | Measured: 117,989 vs 86,820 on an identical pool with no hook. It is a **constant a trader can price** — flat from 1 to 32 seats, a spread of 21 gas — not a slope that grows with book depth. That is the cost of the pool having a book at all. |

## In plain business terms — who pays whom, and for what

Strip the mechanism away and QUEUE is three cashflows between people who already exist in every
pool today:

| Party | What they do today | What they do under QUEUE | What they pay or receive |
|---|---|---|---|
| **The front-seat LP** (a market maker who thinks the flow is good) | Deposits more capital to get a bigger slice of *everything*, including the trades that hurt | Holds a seat at the front and is filled **first** on every trade | **Pays rent**, continuously, on a price they set themselves |
| **The back-seat LP** (a treasury, a passive allocator, a hedger) | Is filled pro-rata on every trade whether they want to be or not | Sits behind, and is reached only when a trade is large enough to sweep through the front | **Receives that rent** — a coupon for standing aside |
| **The trader** | Pays the pool's fee | Pays the same fee at the same price, through any router — the queue is invisible to them | **Pays a fixed +36% gas overhead.** No fee change, no worse price, no new counterparty |

That is the whole business model. **The rent is a transfer between two kinds of LP that both already
exist; no new party is taxed to fund it.** No value is extracted from traders, nothing is taken from
searchers, and the protocol takes no cut. The one cost that does fall outside that transfer is the
**fixed +36% gas overhead a trader pays**, and it is a real cost — it is named in the table above
and again in the limitations, not netted out of the pitch.

Two things follow that are worth saying to a non-engineer:

**It creates an instrument that has never existed in an AMM.** The back seat is a *subordinated*
liquidity position with a coupon: lower turnover, and paid to be patient. Every credit, insurance and
securitisation market on earth has senior and subordinated tranches, because different balance
sheets want different risk. AMMs have never had them — every LP dollar is the same dollar — so QUEUE
is the first venue where an LP can choose to be paid for going last.

> **And "subordinated" here does not mean "safer", so do not sell it that way.** The back is reached
> only by trades large enough to sweep the front, and large trades are disproportionately *informed*
> trades. So the back seat takes fewer fills but a worse mix, plus a coupon. Whether that is better
> risk-adjusted than the front is **an open empirical question this design does not answer** — it is
> the question the design makes *askable*, which is a different and more honest claim.

**It puts a public price on something the market currently pays for in secret.** Today the value of
being early is real, and it is paid — in latency spend on traditional venues, and in fees to whoever
sequences the block on-chain. Neither payment reaches the LPs whose money is being ordered. QUEUE's
head-seat price is that number, on-chain, updated continuously, denominated in the pool's own token.

## What the engineering results mean commercially

The repository proves things in wei and gas. Here is what each one is actually saying about the
product:

| The technical result | What it means for the business |
|---|---|
| Front-first allocation is **exact to the wei** in both tokens, at four price ratios and two decimal pairs | The ordering is not approximate. A seat's fill is a contractual quantity, not a best-effort. That is the difference between an instrument you can price and a feature you have to trust |
| The queue is **never over-backed** — surplus measured at **exactly 0 wei** across 16,384 randomised operations | Every claim on the pool is matched by assets in the pool. There is no float of unbacked entitlement anywhere in the system |
| Shortfall stays **under 1 part per billion** of everything ever deposited | Redemption is not exact — v4's own rounding sees to that — but the leakage is a rounding artefact, not a business risk. **It is borne by the last holders to exit**, and we say so rather than burying it |
| Seat overhead is **flat from 1 to 32 seats** (a 21-gas spread), on top of a constant **+36%** vs a bare pool | The cost to a trader is a **fixed toll they can price into a route**, not a penalty that grows as the book gets deeper. A queue that got more expensive as it got more useful would not be a product |
| Rent **cannot be captured by a flash loan**, and settlement conserves the rent pot to the wei | The coupon paid to back-seat LPs cannot be farmed by someone who was not there. The income is real, not gameable |
| Foreclosure **demotes, never seizes** — the holder keeps the seat and every wei of capital | Running out of prepaid rent costs you your place in line, not your money. That is what makes the seat holdable by an institution: there is no liquidation risk, no collateral call, and no oracle to argue with |
| The contract has **no admin, no upgrade path, and no privileged role of any kind** | There is nobody to trust, nobody to lobby, and nobody who can change the rent rate after you have bought a seat |
| The invariant campaign **found three real bugs** in code that had already passed 135 tests | Stated plainly because it is the most commercially relevant fact in this section: this mechanism was attacked by its own authors and it broke. Everything above is what survived that |

## The video — what it must show, and why

**Why a video is needed at all, in one sentence:** QUEUE's value is not in any single line of code,
it is in a *comparison* — the same swap arriving at a pro-rata pool and at a queued pool — and a
comparison is something you watch, not something you read.

The failure mode we are guarding against is specific and likely. A viewer who knows AMMs hears "fill
queue" and immediately files this under *order book bolted onto an AMM*, decides it is either
impossible or uninteresting, and stops listening in about twenty seconds. Everything below is
structured to prevent that.

**Recommended structure, under five minutes:**

| Time | What is on screen | The business point it makes |
|---|---|---|
| **0:00 – 0:30** | Two identical pools, one swap arriving at each. Pro-rata: everyone's bar shrinks a little. QUEUE: the front bar empties, the rest do not move. | The mechanism, before any words about it. **This is the whole idea and it should land before the first sentence ends.** |
| **0:30 – 1:15** | The question: *"which of those LPs would you rather be?"* — and the observation that on Uniswap today you cannot choose, because there is only one answer available. | Frames it as a **missing product**, not a missing feature. Uniswap sells one thing to LPs; QUEUE sells two. |
| **1:15 – 2:15** | **Why paid seats.** Show the naive open queue and grief it live: one wei of dust takes the head, and the mechanism is dead. Then show the bounded roster, and the Harberger lease taking the seat back off someone who under-priced it. | **This is the objection every informed viewer forms, and it must be answered before they form it.** The pair of demonstrations is the argument: *free rank is griefable, unbounded rank is worthless — so scarcity is the mechanism, and the lease is what stops scarcity becoming a cartel.* |
| **2:15 – 3:15** | The rent flowing from the front seat to the back seats, on-chain, with the numbers moving. | The **business model in one shot**: a transfer between two kinds of LP, funded by nobody else. |
| **3:15 – 4:00** | The head seat's price, changing. Say out loud that nobody knows what this number should be, and that **both answers are results**. | Positions the project as an **experiment that produces data**, not a claim that needs to be believed. This is the most defensible thing we can say and it should not be buried. |
| **4:00 – 4:45** | The limitations, read out, not skipped: +36% gas, 32 seats, thin full-range depth, and Harberger's inability to price a seat below zero under toxic flow. | Credibility. A judge who finds a limitation you did not mention discounts everything else you said; a judge who hears you name it first does the opposite. |
| **4:45 – 5:00** | The comparison to am-AMM, in one sentence. | It **will** be asked. Answering it unprompted is worth more than answering it under questioning. |

**What the video should deliberately NOT do:** open with the architecture, explain the cursor
optimisation, show a test suite scrolling past, or claim QUEUE reduces LVR, stops sandwiches or
detects toxic flow. It does none of those and saying so early buys credibility for everything else.

**What it reveals, stated as the takeaway we want a viewer to leave with:**

> Uniswap made one choice about how liquidity gets filled, in 2018, and has never had a way to test
> it. QUEUE is that test. It costs a trader a fixed 36% more gas, it works for about 32 professional
> LPs per pool rather than for everyone, and it produces one number nobody has ever had: what being
> filled first is actually worth.

## Why this problem, and what we ruled out first

The organizers of this cohort named an open problem: *"dynamic fees alone can't distinguish good
retail flow from bad toxic flow."* We proved two things about it before choosing this design:

- **No forgeable-proof toxicity signal exists for a v4 hook.** Every candidate — trade size,
  slippage budget, priority fee, identity, history — is either invisible to the hook or free to fake
  by splitting a quantity, shopping addresses, or waiting one block.
- **No curve can escape it either.** LVR rate and marginal depth are the same quantity, so any
  invariant that halves adverse selection halves depth by exactly the same factor.

So QUEUE does not classify anyone. **It sells LPs different slices of the flow and lets them bid.**

## What it does not do

It does not stop sandwich attacks. It does not reduce total LVR. It does not recapture value from
searchers. It **prices** adverse selection and routes it to whoever bears it cheapest. Full
limitations are in [`BUSINESS.md`](BUSINESS.md) §9, stated at full strength.

## How rank is held, in detail

Two properties are worth stating because they are what make "always for sale" true rather than
decorative:

**Your ask is firm.** A seat stays available at the *lowest* price it has been asked at, or paid
for, within a fixed window. Without that, a holder watching the mempool raises the price the instant
they see a buyer, for the cost of a few seconds of rent — four parts in ten million, per block — and
"always for sale" means nothing. A raise applies immediately to what you *pay* and only after the
window to what you can be *taken* at.

**The founding endowment dissolves itself.** Every seat on the deployed roster starts unpriced, and
an unpriced seat is free for anyone to take. Whoever deploys chooses the first holders, and that
choice is worth a head start of exactly one transaction.

## Status — Phases 0-6 built and green, 2026-08-28

```
forge test               ->  163 passed, 0 failed      (13 suites)
forge lint src/          ->  clean, zero notes
python3 script/mutate.py ->  66 mutations on production code, ZERO survivors
```

Everything runs against **real v4 contracts deployed locally** — a real `PoolManager`,
`PositionManager` and `V4SwapRouter`. Nothing is mocked; the rounding is v4's own.

**Phase 6 was an adversarial and invariant campaign, and it found three real bugs in code that had
already survived 135 tests and 61 mutations.** All three are fixed, each has a directed regression
test and a mutation of its own, and each is written up at full strength in
[`PITFALLS.md`](PITFALLS.md) §5.73–5.77:

| # | What was broken | Why it mattered |
|---|---|---|
| 5.73 | A swap whose output rounds to zero credited a seat and left the *other* token's cursor leading it | Every later swap in that direction started **behind a funded seat** — silent theft of rank, the one failure the whole mechanism exists to prevent |
| 5.74 | `modifyLiquidity` realises accrued fees on every call, so an *add* can **credit** the caller — and the hook measured the move as an unsigned decrease | `addToSeat` and `sweepFloatIntoPosition` — **the only two paths capital has into the queue** — reverted with an arithmetic panic on any pool with real accrued fees |
| 5.76 / 5.77 | v4-periphery's liquidity helper narrows each leg before taking the minimum, and the removal sizing divided by a span that goes to zero at a tick boundary | Deposits reverted on one side; **withdrawals and seat evacuations reverted on the other** — and a revert on the evacuation path is an incumbent **veto on their own buyout**, which §B.8 removed on purpose |

The campaign itself: **11 invariants × 256 runs × 64 calls = 16,384 calls per invariant**, plus a
deterministic 500-call scripted campaign that asserts every invariant after *every single call* and
proves each path was actually entered. `targetContract` and `targetSelector` are both set, so the
fuzz surface is exactly one contract and exactly twelve actions.

**What the gas costs, said plainly.** Every figure is a complete swap transaction through the real
router, with state built in `setUp()` so writes are metered at real prices — `vm.cool()` alone is
not enough, and finding that out is what Phase 5 was actually for (`AGENTS.md` LAW 4).

**What is proven.** Front-first allocation is exact to the wei in both tokens, at 1:4, 1:1000 and
1000:1, at 18/6 and 6/18 decimals. The protocol fee is handled correctly at a maximum fee, with
`lpFee == 0`, and against a foreign pool sharing a currency. Per-seat withdrawal works from a shared
float in all six orderings. Rank is an ERC-6909 seat, supply one, and transferring it moves the rank
while the capital goes back to the seller. Rent accrues exactly linearly in time, splits to the wei,
is never lost when nobody is eligible, and cannot be captured by a flash loan. A seat that
under-prices itself is bought out; one that over-prices pays for it. Foreclosure demotes and never
seizes. The whole always-for-sale guarantee survives a holder who front-runs their own buyout. And
**the queue is never over-backed — the surplus of position-plus-float over the ledger measured
exactly 0 wei across the entire campaign**, in both tokens, after every action.

**What is not.** Stated at full strength, here rather than in a footnote:

- **Harberger cannot express a negative seat value.** Under toxic flow every holder declares near
  zero, no rent flows, and the front is free to take. That is the mechanism behaving correctly and
  it is also the point at which the price signal is censored. Unsolved, and not solvable inside this
  design.
- **Rent is `currency0`, weighted by `currency0`.** Weighting a two-token basket needs a price and
  QUEUE is not allowed to have one. A tail holding only `currency1` is paid nothing; the rent waits
  until an eligible recipient exists.
- **Enforcement needs somebody to poke it.** No keeper ships and none is required — the seats behind
  are paid by the poke, and a buyer must poke to clear a delinquent incumbent out of the way — but a
  seat nobody wants and nobody pokes accrues a debt nothing collects.
- **The roster is bounded at 32 seats.** Scarcity is the mechanism, not a concession — but it does
  mean this is a professional venue, not a replacement for every Uniswap pool. What actually sets
  the number is `addToSeat` at **2,610,805 gas** with 31 priced seats ahead of it (it is quadratic
  in the roster), not the sweep, which is linear and comfortable.
- **A swap through QUEUE costs 36% more than the same swap on a pool with no hook** — measured,
  117,989 vs 86,820 gas. The overhead is a constant a trader can price: **flat from 1 to 32 seats**,
  a spread of 21 gas. Walking the queue costs a further 8,070 gas per seat, so a full 32-seat sweep
  is a 416,053-gas transaction.
- **One full-range position is thin.** ~1/200th the depth per dollar of a ±1% concentrated position.
- **Face value is an upper bound, not a promise, and the residual is NOT a per-swap constant.**
  §E.4's "~0.15 wei per swap" holds near the seeded price and **does not generalise**: the
  truncation scales with how far the price has been driven from where the liquidity sits, and a pool
  drained into the float and pushed to the tick floor loses ~1e9 wei on a single swap. Measured over
  the Phase 6 campaign the shortfall stays **under one part per billion of everything that has ever
  entered the queue** — and it is borne by **the last holders to withdraw**. Causing it costs an
  attacker six-figure multiples of the residual in swap input, so it is not an attack; it is a
  property, and it is stated here rather than discovered later.
- **Seat trading is not depth-neutral.** Evacuating a single-token seat moves position into float,
  exactly as withdrawal churn does.

**Open hazards are not hidden.** Every one is listed with its evidence grade in
[`PITFALLS.md`](PITFALLS.md) §5, including the ones found by attacking our own work: a free
denial-of-service in the transfer design this repo's own plan specified, a seat-theft hole that 71
passing tests did not see, a rent payment source the plan specified that would have set rank by
which way the market traded, two brand-new entry points that shipped with no ownership check past a
99-test green suite, and the three Phase 6 bugs above that 135 tests and 61 mutations did not see.
The ledger also records the two places our own **instruments** were wrong rather than the code
(§5.75, §5.79), because a broken measurement that looks like a broken mechanism has cost this
project more time than any real bug.

## Start here

| File | What it is |
|---|---|
| [`AGENTS.md`](AGENTS.md) | How to work in this repo. Rules, testing laws, decision framework. *(`CLAUDE.md` is a symlink to it.)* |
| [`PLAN.md`](PLAN.md) | What to build, phased, with runnable acceptance criteria. |
| [`BUSINESS.md`](BUSINESS.md) | What QUEUE is, why it has never existed, who uses it, and what may honestly be claimed. |
| [`PROGRESS.md`](PROGRESS.md) | What is proven, what is open, what to do next. |
| [`PITFALLS.md`](PITFALLS.md) | The standing hazard ledger: v4 facts that bite, testing traps, settled decisions, proven-impossible ideas, **open hazards (§5)**, and **where two documents disagree (§7)**. Every row graded PROVEN / MEASURED / REASONED / UNVERIFIED / OPINION. |
| [`docs/research/protocol-fee/`](docs/research/protocol-fee/) | The executed protocol-fee experiment (7 tests + 3 mutations) and the v4 source-level mechanics behind it. |
| [`docs/research/premise-review/`](docs/research/premise-review/) | The economic and fairness review of the premise. Analysis, nothing executed. |
| [`NEXT_SESSION_PROMPT.md`](NEXT_SESSION_PROMPT.md) | The prompt to hand a fresh agent. |
| `archive/2026-08-26/` | The design phase: 25 hard-won v4 facts, every experiment, and every rejected candidate with the evidence that killed it. |

```bash
forge build
forge test
```

## Partner integrations

None.

## License

MIT
