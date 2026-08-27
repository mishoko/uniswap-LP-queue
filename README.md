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

## Status — Phases 0-3 built and green, 2026-08-27

```
forge test        ->  77 passed, 0 failed
forge lint src/   ->  clean
49 mutations run on production code across Phases 1-3, ZERO survivors
```

Everything runs against **real v4 contracts deployed locally** — a real `PoolManager`,
`PositionManager` and `V4SwapRouter`. Nothing is mocked; the rounding is v4's own.

**What is proven.** Front-first allocation is exact to the wei in both tokens, at 1:4, 1:1000 and
1000:1, at 18/6 and 6/18 decimals. The protocol fee is handled correctly at a maximum fee, with
`lpFee == 0`, and against a foreign pool sharing a currency. Per-seat withdrawal works from a shared
float in all six orderings. Rank is an ERC-6909 seat, supply one, and transferring it moves the rank
while the capital goes back to the seller.

**What is not.** These are stated at full strength, here rather than in a footnote:

- **Rank is not yet *bought*.** The founding roster is fixed at deployment — an endowment, as an
  exchange's founding memberships were. What is closed is that rank cannot be obtained by dusting,
  by being early, or at any price the incumbent has not accepted. Continuous pricing is the
  Harberger lease, which is the next phase.
- **This is a one-sided market until then.** The honest answer to *"why would anyone hold seat 5?"*
  is "they wouldn't" — the tail's compensation channel is rent, and rent is the next phase.
- **The roster is bounded at 32 seats,** because a full sweep of a thousand positions cannot be paid
  for. This is a professional venue, not a replacement for every Uniswap pool.
- **One full-range position is thin.** ~1/200th the depth per dollar of a ±1% concentrated position.
- **Face value is an upper bound, not a promise.** Each seat redeems to within a gap that grows
  linearly at ~0.15 wei per swap and never compounds.

**Open hazards are not hidden.** Every one is listed with its evidence grade in
[`PITFALLS.md`](PITFALLS.md) §5, including the ones found by attacking our own work — a free
denial-of-service in the transfer design this repo's own plan specified, and a seat-theft hole that
71 passing tests did not see.

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
