# Does QUEUE create value for anyone? — the honest answer, and where one could come from

**Status: ANALYSIS, 2026-09-02. Written after the owner asked the question the project had been
avoiding: apart from the drawbacks, who actually makes money here?**

**Short answer: as built, nobody. Not the seat holders, not the swapper, not the pool. The mechanism
redistributes a fixed pie and charges for the privilege. This document says why, what was tried, and
the one place genuine value could still come from.**

---

## 1. The constraint that governs everything

This is an identity, not a simulation result. The 32 seats share **one** Uniswap position over one
price band. Whatever the ordering rule, the pool quotes the same price, serves the same trades, and
earns the same fees.

```
   sum of all 32 seats' returns  ==  the return of ONE ordinary Uniswap LP position
                                     in the same range with the same capital
```

Everything the hook does is decide the **split**. So:

```
   BEST POSSIBLE OUTCOME FOR THE SEATS AS A GROUP
   ┌──────────────────────────────────────────────────────────────┐
   │  all 32 seats EQUAL to an ordinary LP                         │
   │  minus: lock, contract risk, closed roster, unrollable band   │
   │  = strictly worse than not using the hook                     │
   └──────────────────────────────────────────────────────────────┘
```

**There is no ordering scheme that makes all 32 seats beat a plain LP. That search is closed.**

---

## 2. Where the money actually goes — three flows

### FLOW A — the hook as originally built (no premium). The problem.

Measured per rank, 30 price paths, benign flow, ±10% band:

```
   RETAIL FLOW (small trades, most of the volume)
        │
        ▼
   ┌─────────┐
   │ SEAT 1  │  turnover 411,877%/yr · fees +1240%/yr · net +911%/yr   ◄── takes ~everything
   └─────────┘
        │  (only reached when seat 1 is empty)
        ▼
   ┌─────────┐
   │ SEAT 2  │  turnover  22,186%/yr · fees   +67%/yr · net   +12%/yr
   └─────────┘
        │
        ▼
   ┌─────────┐
   │ SEAT 7  │  turnover   1,903%/yr · fees    +6%/yr · net   -20%/yr   ◄── LOSES
   └─────────┘
        │
        ▼
   ┌─────────┐
   │ SEAT 32 │  turnover      34%/yr · fees     0%/yr · net    +0%/yr   ◄── never trades
   └─────────┘

   RESULT: 24-29 of 32 seats lose money in every regime tested.
```

**Why:** small trades never get past seat 1, so seat 1 collects nearly all the fees. Seats 2–31 are
reached *only* by large moves — which are the informed, adverse ones. They get the toxic fill and
almost none of the fee income. **They are unpaid insurance sellers.**

### FLOW B — with the priority premium shipped this session. Fair, but pointless.

A filled seat now hands 85% of the fee it earned to the seats still standing behind it:

```
   RETAIL FLOW
        │
        ▼
   ┌─────────┐   keeps 15% of its fee
   │ SEAT 1  │───────────┐
   └─────────┘           │  85% of every fee earned
        │                ▼
        │        ┌───────────────────────────────┐
        ▼        │  shared with SEATS 2..32,      │
   ┌─────────┐   │  weighted by the inventory     │
   │ SEAT 2  │◄──┤  they are standing there with  │
   └─────────┘   └───────────────────────────────┘
        │                ▲
        ▼                │
   ┌─────────┐           │
   │ SEAT 32 │◄──────────┘
   └─────────┘

   RESULT: 0 of 32 seats negative (on a ±30% band over a 25%-vol pair).
           Spread collapses to 10-15 points. Every seat ≈ the pool average.
```

**This is a real fix to a real defect — and it creates no value.** Every seat now earns roughly what
an ordinary Uniswap LP earns. The starvation is gone; the *reason to participate* is still missing.

```
   ┌────────────────────────────────────────────────────────────┐
   │  SEAT HOLDER'S DECISION, TODAY                              │
   │                                                             │
   │   Option 1: mint an ordinary Uniswap position   → return R  │
   │   Option 2: buy a QUEUE seat and fund it        → return R  │
   │                                                  − lock      │
   │                                                  − contract  │
   │                                                    risk      │
   │                                                  − no roll   │
   │                                                             │
   │   RATIONAL CHOICE: Option 1. Every time.                    │
   └────────────────────────────────────────────────────────────┘
```

### FLOW C — the only shape that can work. External money entering the pool.

The pie is fixed **only if all the money comes from inside the pool.** If somebody outside pays to be
at the front — for a reason that is not the seat's own trading P&L — that payment is new money:

```
                 ┌──────────────────────────────────────┐
                 │   AN OUTSIDE PARTY WITH A REASON     │
                 │   TO WANT FIRST FILL                 │
                 │   (see §4 for who)                   │
                 └──────────────┬───────────────────────┘
                                │  RENT  ($ from outside the pool)
                                ▼
   RETAIL FLOW            ┌─────────┐
        │─────────────────│ SEAT 1  │  gets first fill — that is what it is buying
        │                 └─────────┘
        │                      │  rent is paid to the seats behind
        ▼                      ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐
   │ SEAT 2  │  │  ...    │  │ SEAT 32 │   each earns:  pool return  +  rent share
   └─────────┘  └─────────┘  └─────────┘                ─────────────────────────
                                                        STRICTLY BETTER than an
                                                        ordinary Uniswap LP
```

**This is the only structure in which every seat holder beats their alternative.** It is not a
redistribution — the rent is an inflow. And it is exactly what the project's founding sentence
claimed ("the price of queue position, paid to the LPs you are standing in front of"); what was
missing was ever asking *who pays it and why*.

---

## 3. What was tried, and why each failed — business summary

| # | Idea | What it was meant to do | Verdict |
|---|---|---|---|
| 1 | **Front-first ordering serves more volume** ("inventory recycling") | Make the queue earn more than pro-rata by emptying and refilling the head | **DEAD.** Availability is identical; the pool serves exactly the same trades. Proven identity |
| 2 | **Detect and penalise toxic flow** | Protect LPs from informed traders | **FORBIDDEN / IMPOSSIBLE** for a v4 hook — every signal is forgeable by splitting a trade or waiting a block |
| 3 | **A curve that reduces LVR** | Reduce the structural LP loss | **PROVEN IMPOSSIBLE.** LVR rate and market depth are the same quantity; halving one halves the other |
| 4 | **Marginal (segment) pricing** | Stop the head getting both the volume *and* the best price | **SHIPPED, and correct** — but it adjusts price, and the head's advantage is *quantity*. Too small to fix the problem |
| 5 | **Harberger rent on an assessed seat value** | Make the front pay the back | **TOO SMALL.** ~6%/yr against a 20–160%/yr inventory drag — two orders of magnitude short |
| 6 | **Deterministic rotation of rank** | Give every seat an equal turn at the front | **REJECTED.** Its evidence broke under adversarial review, and it deletes the differentiation the product sells. Ends at "pro-rata with extra steps" |
| 7 | **Lock-weighted priority** (more front-time for longer commitment) | Pay for sticky liquidity with priority instead of token emissions | **DOES NOT CLEAR.** The lowest tier earns below an ordinary LP and receives nothing for it, so nobody funds it; the mix collapses to uniform and reduces to #6 |
| 8 | **The priority premium** (share of fee flow, φ) | Pay the back of the book out of the front's fee income | **SHIPPED and it works as designed** — 0/32 negative instead of 29/32. But it equalises to the pool average, so it removes the loser without creating a winner |
| 9 | **Let seats choose their own deposit size** | Let capital find its own equilibrium across ranks | **NOT MODELLED, and it may make the queue moot** — if capital concentrates where returns are high, returns equalise by depth and the ordering stops mattering |

**Pattern:** every idea tried so far redistributes the same pie. Ideas 1–3 tried to grow it and are
proven impossible. **Nothing yet tested brings money in from outside.**

---

## 4. Who could plausibly pay — the untested hypotheses

These are the candidates for the outside party in FLOW C. **None of them has been tested. This is the
next session's job.**

**H1 — A protocol or DAO replacing liquidity-mining emissions.** Protocols spend enormous budgets on
token emissions to rent mercenary liquidity, and everyone agrees it is wasteful and dilutive. If a
protocol instead pays *rent into the pool* for a committed, priority-ranked book, that is real
external money, the seats earn pool return + protocol payment, and the protocol may pay less than it
currently burns. **This is the strongest candidate: there is an existing budget, an acknowledged
problem, and a named buyer.**

**H2 — A treasury or issuer with inventory to work.** An entity that wants to accumulate or
distribute a token over time wants *its own* inventory traded first, not a pro-rata slice. Being at
the head is execution, not P&L, so they will pay for it out of a different budget.

**H3 — A market maker wanting deterministic inventory turnover.** The classic reason queue position
is valuable in every other market. They pay for execution certainty.

**H4 — Depth as the product, sold to the pair.** If the mechanism makes LPs willing to commit more
capital, the pool is deeper and the swapper gets better prices. That is a genuine benefit to the end
user — but it is a *consequence* of H1–H3 working, not an independent source of value.

### And the honest failure case

**If no such buyer exists, rent goes to zero, every seat earns the pool average, and QUEUE is an
ordinary Uniswap position with extra steps.** It is not harmful — nobody is expropriated — but there
is no reason for it to exist. That must be stated in the pitch, not discovered by a seat buyer.

---

## 5. What about the end user (the swapper)?

Today the swapper is **pure cost**: same price, same trading fee, **+133% network compute**. On an L2
that is cents, but it is not a benefit and should never be presented as one.

The only honest case for the swapper is **indirect and conditional**: if the mechanism attracts
committed capital that would not otherwise be there, the pool is deeper and their price improves.
That depends entirely on §4 working. **Do not claim it until it does.**

---

## 6. What this means for the project

* The **engineering** is sound, adversarially tested, and unusually honest about its own numbers.
* The **mechanism** now distributes fairly — a real fix, shipped this session.
* The **business case is missing**, and no amount of further mechanism design will produce it,
  because the pie is fixed. The next session must test §4's hypotheses, not invent a tenth ordering
  rule.

**Do not present this as "LPs make more money." They do not. Present it as what it is — or find the
outside payer first.**
