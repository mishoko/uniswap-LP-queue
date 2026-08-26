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

## Status

**Design complete and validated. Build not started.**

The core allocation arithmetic is already proven exact to the wei, in both tokens, at a non-unit
price, against a real `PoolManager` — with three negative controls that go red for the right reasons.
See [`PROGRESS.md`](PROGRESS.md).

## Start here

| File | What it is |
|---|---|
| [`AGENTS.md`](AGENTS.md) | How to work in this repo. Rules, testing laws, decision framework. *(`CLAUDE.md` is a symlink to it.)* |
| [`PLAN.md`](PLAN.md) | What to build, phased, with runnable acceptance criteria. |
| [`BUSINESS.md`](BUSINESS.md) | What QUEUE is, why it has never existed, who uses it, and what may honestly be claimed. |
| [`PROGRESS.md`](PROGRESS.md) | What is proven, what is open, what to do next. |
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
