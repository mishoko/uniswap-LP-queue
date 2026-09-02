# THE FRONTIER — how much value QUEUE can create, in closed form

> ## 🚨 RETRACTION IN PROGRESS, 2026-09-02, SAME DAY AS PUBLICATION — THE FORMULA STANDS, THE NUMBER
> ## I PUT IN IT DOES NOT, AND IT WAS WRONG IN THIS PROJECT'S OWN FAVOUR FOR THE FOURTH TIME.
>
> The derivation below (`SLACK = c₁·(LP − B₁)`) is unaffected — it is algebra plus an identity and it
> was checked to 2.4e-16. **What is retracted is my value for `B₁`, and therefore every "thin but
> real" conclusion drawn from it.**
>
> I used `B₁ = +4.45%` — the best keeper over the WIDTH axis, at w = 10% — and reported
> `SLACK = +0.19 pp of book ≈ 1.1%/yr`. That keeper is modelled converting **against its own pool**,
> and `econ-audit` measured that this single term is **61.60 of the 70.23 points** of its cost (88%):
> it forces the keeper to convert its entire $333,333 against a two-thirds-sized copy of its own pool
> on **every re-mint**. A real keeper routes through an aggregator instead.
>
> **Let the keeper convert off-venue at 5 bps and it scores +6.20% at w = 5%, ABOVE the passive LP's
> +5.02%.** Then `LP − B₁ = −1.18 pp`, `SLACK = −0.39 pp`, and **NO φ CLEARS IN ANY REGIME, BY
> IDENTITY.**
>
> **This is 5.136 recurring within hours, on the axis I did not think to sweep.** I caught the
> handicap on the WIDTH axis and published a corrected number that was still handicapped on the
> CONVERSION-VENUE axis. The lesson generalises and is now the more important half of 5.136: *when a
> benchmark has free parameters, "I swept the one that was wrong" is not the same as "the benchmark
> is now allowed its best move."* Enumerate the axes before trusting the max.
>
> **Status: the exact `B₁` is being measured across the width × conversion-venue grid. Until that
> lands, treat every SLACK figure below as an UPPER BOUND that is probably negative.** Do not quote
> "1.1%/yr" — it is retracted.


**Status: DERIVED and NUMERICALLY CONFIRMED, 2026-09-02.** This supersedes every phi-window argument
in this directory, because it bounds all of them at once. Reproduce with
`python3 docs/research/seat-economics/frontier.py`.

---

## The result

Let `c_i` be seat `i`'s share of the book's capital, `r_i` its return at `phi = 0`, `LP` the return of
an ordinary pro-rata LP over the same range with the same capital, and `B1` the return of **rank 1's
own best outside alternative** — whatever that actually is.

The identity `sum_i c_i r_i == LP` holds exactly (verified independently: 36 cells, worst residual
**2.98e-14**, and **invariant to phi** — the total is untouched by the mechanism).

```
   available to take from seat 1    =  c_1 (r_1 - B1)

   needed to lift seats 2..N to LP  =  sum_{i>=2} c_i (LP - r_i)
                                    =  LP(1 - c_1) - (LP - c_1 r_1)      [substitute the identity]
                                    =  c_1 (r_1 - LP)

   SLACK = c_1 (r_1 - B1) - c_1 (r_1 - LP)
```

```
        ┌────────────────────────────────────────────────────────────┐
        │                                                            │
        │        SLACK  =  c_1 * ( LP - B1 )                         │
        │                                                            │
        │   the head's        how much WORSE the head's alternative  │
        │   capital share     is than simply being a passive LP      │
        │                                                            │
        └────────────────────────────────────────────────────────────┘

   max uniform excess-over-LP available to every back seat = SLACK / (1 - c_1)
```

### ⚠ THE CONDITION UNDER WHICH THAT LINE IS EXACT, AND IT IS NOT DECORATION

The substitution above replaces `sum_{i>=2} c_i (LP - r_i)` with `c_1 (r_1 - LP)`. That is legitimate
only if EVERY back seat actually needs lifting. What the mechanism must really fund is

```
   needed_EXACT = sum_{i>=2} c_i * max(0, LP - r_i)   >=   c_1 (r_1 - LP)
```

because you cannot claw back from a seat that is ALREADY above `LP` — `phi` only ever takes from the
seat a fill PAID. So **the closed form is EXACT while every back seat sits below `LP`, and
OPTIMISTIC otherwise.** Both forms are computed side by side in `frontier_exact.py`; the first draft
of this document carried only the optimistic one, and it disagreed by 0.47 pp in TOXIC.

**`r_1` cancels.** The head's own performance — the number this project has spent three sessions
measuring — does not enter. Neither does `N`, the capital schedule beyond `c_1`, the ordering rule,
the premium's weighting, the rent, or `phi`.

## Numerical confirmation

`frontier.py` computes the "needed" term BOTH ways — the long way, seat by seat, and by the closed
form — over the full 120-seed set on the shipped 5-seat roster:

```
   regime    long form        closed form      agree to
   BENIGN    +3.2218 pp       +3.2218 pp       2.4e-16
   NORMAL    +0.5667 pp       +0.5667 pp       5.2e-18
   TOXIC     -0.3680 pp       -0.3680 pp       4.8e-17
```

And the EXACT form against the closed form, with `B1` = the best keeper width measured
(w = 10%, which `results-shipping.txt` never swept — it stopped at 5%):

```
   regime   back seats already above LP   needed(closed)  needed(EXACT)   available   TRUE SLACK
   BENIGN   none                            +3.2218 pp     +3.2218 pp     +3.4133    +0.1915 pp   WINDOW EXISTS
   NORMAL   none                            +0.5667 pp     +0.5667 pp     +0.7286    +0.1619 pp   WINDOW EXISTS
   TOXIC    seats 3, 4, 5                   -0.3680 pp     +0.1056 pp     -0.3660    -0.4716 pp   EMPTY
```

**A window DOES exist in BENIGN and NORMAL — 98.3% of the calendar by band life — and it is thin:
0.16-0.19 pp of book over the band's life, roughly 1.0-1.1%/yr.** TOXIC is empty for a different and
simpler reason than the tables suggested: rank 1 is ALREADY below its own bar at `phi = 0`
(-3.278% against -2.18%), so there is nothing to redistribute before the first wei moves.

**The LAW 5 control, whose answer is known in advance:** set `B1 = LP` — i.e. assume rank 1's
alternative is simply being a passive LP — and the slack must be EXACTLY zero, because the identity
forbids every seat from beating the average. It reads `+0.0000 pp` in all three regimes. The control
can fire, and it fires correctly.

## What it says

| if rank 1's true alternative is… | `LP - B1` | SLACK (shipped roster, `c_1 = 1/3`) |
|---|---|---|
| a passive LP | 0 | **exactly 0** — no product, at any `phi`, ever |
| a keeper at its BEST width (measured w=10%, BENIGN) | +0.57 pp | **0.19 pp of book** / 61d ~ **1.1%/yr** |
| a keeper at 1% width (-69.19%) | +74.2 pp | 24.7 pp — but nobody rational runs that |

**Three consequences, all of which change what this project should do:**

1. **The product's entire value is `LP - B1`.** QUEUE is worth something exactly to the extent that
   its front-seat buyer would otherwise be running a strategy that LOSES to passive LPing. That is a
   strange thing to sell, and it is the truth. It also means the one number worth any more simulator
   time is `B1` — the keeper's best achievable return, swept over width. If some managed width beats
   passive LPing, `B1 > LP`, the slack is NEGATIVE, and the mechanism cannot clear at any `phi`.

2. **Depth was never the economic variable — `c_1` was.** Surplus is LINEAR in the head's capital
   share. Shipped 5-seat linear (`c_1 = 0.333`) -> 0.19 pp. Thirty-two EQUAL seats
   (`c_1 = 0.031`) -> **0.018 pp, essentially nothing.** So a deep roster does not fail because of
   depth, gas, or ordering; it fails because an equal schedule shrinks the head to 3% of the book.
   `MAX_SEATS` is a structural cap, not an economic one, and PITFALLS 5.129's gas question is
   downstream of a decision that should be made on `c_1`.

3. **No re-weighting of the premium can create value — only stop destroying it.** The ceiling is
   independent of the ordering rule. Any work on the premium's weight is bounded above by
   `c_1 (LP - B1)` and should be justified by how much of that ceiling the current rule throws away,
   not by any claim to improve the product's economics.

## What this does NOT say

* It does not say the mechanism is wrong. The allocator, the premium and the lease do what they claim.
* It does not measure `B1`. `B1` is a claim about what a real buyer's alternative is, and no
  simulator can settle it — a simulator can only price the alternatives we think to model.
* It does not settle WHICH bar is `B1`, and that is a judgement about the buyer, not about the code.
  `B1` is the best return available **to that specific capital, given its constraints**:
  - **Unconstrained capital** (a pure yield seeker) can simply be a passive LP, so `B1 >= LP`,
    `SLACK <= 0`, and there is no product for it. At any `phi`. Ever.
  - **Constrained capital** — a desk with a mandate to hold at-the-money inventory, a treasury
    working a position, an issuer distributing supply — cannot take the passive-LP option without
    abandoning its mandate. Its `B1` is the best CONSTRAINED alternative, which is the keeper bot,
    and that is measurably below `LP`.

  **So QUEUE only works for constrained capital, and the size of the product is the size of the
  constraint.** That is the sharpest true statement available about who this is for, and it should
  replace every "professional desks want first fill" formulation, which asserts the conclusion
  without naming the mechanism that makes it true.

* It does not bound value that arrives from OUTSIDE the pool. Every term here is a return on capital
  inside one Uniswap position. A payer with a non-return reason to hold rank 1 — inventory to work,
  execution certainty, a protocol substituting this for token emissions — is outside the model, and
  is the only thing that can make `B1` materially below `LP`. See `VALUE.md` §4.
