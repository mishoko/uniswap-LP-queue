# QUEUE

**A Uniswap v4 hook that gives a pool a fill queue, and makes your place in it a tradeable asset.**

---

Every concentrated automated market maker is a **pro-rata** market. Inside a tick, every liquidity
provider is filled in proportion to their size — nobody can be first, nobody can be last, and no
amount of money can buy a better place in line.

Every real electronic market on earth is **price–time priority**, where queue position is the single
most valuable asset in market making.

> **Uniswap has never had a queue, so it has never had a price for one.**

QUEUE is the missing half. The hook custodies the pool's liquidity and allocates each swap
**front-first** through an ordered list of depositors. Two LPs with identical capital at identical
prices now hold **different assets**: one is filled by every swap that arrives, the other only when a
swap is large enough to sweep through. That rank is an ERC-6909 balance — transferable, and priced by
whoever wants it.

## Why that matters

The organizers of this cohort named an open problem: *"dynamic fees alone can't distinguish good
retail flow from bad toxic flow."* We proved two things about it before choosing this design:

- **No forgeable-proof toxicity signal exists for a v4 hook.** Every candidate — trade size, slippage
  budget, priority fee, identity, history — is either invisible to the hook or free to fake.
- **No curve can escape it either.** LVR rate and marginal depth are the same quantity, so any
  invariant that halves adverse selection halves depth by exactly the same factor.

So QUEUE does not classify anyone. **It sells LPs different slices of the flow and lets them bid.**
A pool where the front seat trades at a premium has benign flow. A pool where the front must be *paid*
to stand there has toxic flow — and the size of that payment **is** the toxicity, denominated in the
pool's own numéraire, discovered by capital rather than asserted by a formula. Unforgeable, because
the bid costs real money.

## What it does not do

It does not stop sandwich attacks. It does not reduce total LVR. It does not recapture value from
searchers. It **prices** adverse selection and routes it to whoever bears it cheapest. Full
limitations are in [`BUSINESS.md`](BUSINESS.md) §9, stated at full strength.

## How rank is held: a self-assessed, always-for-sale lease

A seat is not just an ordering — it is a **lease you price yourself**.

- You post a `selfPrice` in the pool's `currency0`. Nobody else sets it; there is no oracle, no
  mark, and no admin.
- You pay **rent** on that number, continuously, in elapsed seconds. It goes to **the seats behind
  you** — the tail's compensation for standing aside — pro-rata by their `currency0` balance, and
  the split sums to what you were charged **to the wei**.
- **Anyone may take your seat at your own price, at any time.** Price it low and somebody will.
- Rent is paid from a **prepaid meter** you top up. Let it run dry and you are **demoted to the back
  of the queue** — not liquidated, not seized. You keep the seat, you keep every wei of your capital,
  you lose your place.

Two properties are worth stating because they are what make the above true rather than decorative:

**Your ask is firm.** A seat stays available at the *lowest* price it has been asked at, or paid for,
within a fixed window. Without that, a holder watching the mempool raises the price the instant they
see a buyer, for the cost of a few seconds of rent — four parts in ten million, per block — and
"always for sale" means nothing. A raise applies immediately to what you *pay* and only after the
window to what you can be *taken* at.

**The founding endowment dissolves itself.** Every seat on the deployed roster starts unpriced, and
an unpriced seat is free for anyone to take. Whoever deploys chooses the first holders, and that
choice is worth a head start of one transaction.

## Status — Phases 0-5 built and green, 2026-08-28

```
forge test              ->  135 passed, 0 failed
forge lint src/         ->  clean, zero notes
python3 script/mutate.py -> 61 mutations on production code, ZERO survivors
```

Everything runs against **real v4 contracts deployed locally** — a real `PoolManager`,
`PositionManager` and `V4SwapRouter`. Nothing is mocked; the rounding is v4's own.

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
seizes. The whole always-for-sale guarantee survives a holder who front-runs their own buyout.

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
- **The roster is bounded at 32 seats,** because a full sweep of a thousand positions cannot be paid
  for — and because the queue's whole order is one 32-byte word. This is a professional venue, not a
  replacement for every Uniswap pool.
- **A swap through QUEUE costs 36% more than the same swap on a pool with no hook** — measured,
  117,989 vs 86,820 gas. The overhead is a constant a trader can price: it is **flat from 1 to 32
  seats**, a spread of 21 gas. Walking the queue costs a further 8,070 gas per seat, so a full
  32-seat sweep is a 416,053-gas transaction. Depositing into a seat with 31 priced seats ahead of
  it is the expensive path at 2,610,805 gas, and it is that number — not the sweep — that bounds
  the roster.
- **One full-range position is thin.** ~1/200th the depth per dollar of a ±1% concentrated position.
- **Face value is an upper bound, not a promise.** Each seat redeems to within a gap that grows
  linearly at ~0.15 wei per swap and never compounds.
- **Seat trading is not depth-neutral.** Evacuating a single-token seat moves position into float,
  exactly as withdrawal churn does.

**Open hazards are not hidden.** Every one is listed with its evidence grade in
[`PITFALLS.md`](PITFALLS.md) §5, including the ones found by attacking our own work: a free
denial-of-service in the transfer design this repo's own plan specified, a seat-theft hole that 71
passing tests did not see, a rent payment source the plan specified that would have set rank by
which way the market traded, and two brand-new entry points that shipped with no ownership check
past a 99-test green suite.

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
