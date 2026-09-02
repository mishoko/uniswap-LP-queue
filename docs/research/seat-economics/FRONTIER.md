# THE FRONTIER — how much value QUEUE can create, in closed form

> ## 🛑 SETTLED, 2026-09-02 — THE SLACK IS ZERO OR NEGATIVE **BY IDENTITY**, NOT BY MEASUREMENT.
> ## THE FORMULA BELOW IS CORRECT. THE PRODUCT IT PRICES DOES NOT EXIST.
>
> The derivation is right and was re-derived independently. **The input `B₁` was wrong, and the
> correct value makes the answer structural rather than empirical.**
>
> **`wing.check_null` (`wing.py:151-161`) proves that a STATIC position spanning exactly the pool's
> own band `[pa, pb]` with capital `cap` IS `cap/BOOK` of the undivided pool.** Measured, paired,
> per regime: BENIGN `+6.035%` against `+6.035%`, NORMAL `+0.767%` against `+0.767%`, TOXIC
> `−2.181%` against `−2.181%` — differences of `−0.000%` at SE `0.000`, max absolute deviation
> **4.3e-14**.
>
> **So rank 1 can always, for free, hold a plain never-touched Uniswap position returning EXACTLY the
> pro-rata LP return. Therefore `B₁ ≥ LP` by construction, with equality achievable at zero cost,
> and `SLACK = c₁·(LP − B₁) ≤ 0` BEFORE ANY MEASUREMENT IS TAKEN.**
>
> **THE `B₁ = LP → slack = 0` CASE BELOW WAS NEVER A SANITY CONTROL. IT IS THE ANSWER.** It was
> written to prove the machinery could compute a known value, it returned exactly `0.0000 pp`, and
> the significance of what it was saying was walked straight past. That is LAW 5's own lesson
> inverted: a control whose answer is known in advance was built, fired correctly, and its result
> was read as a checkmark instead of as a finding.
>
> **WHY THE EARLIER `B₁` WAS WRONG.** It used the best *managed* wing (w = 10%, `+4.45%`). **That is
> a strategy, not a bar** — it pays a conversion cost the STATIC position over the same range does
> not, and the static position over the BAND returns `LP` exactly. Rank 1's outside option is not
> "the best keeper bot"; it is **"the best of everything rank 1 may freely do", and that set contains
> ordinary passive LPing.** Sweeping static widths, the alternative converges to `LP` **from ABOVE**:
> best free alternative is `+6.415%` (static w = 8%) in BENIGN against `LP = +6.035%`, `+0.809%`
> (w = 12%) in NORMAL against `+0.767%`, and `−0.732%` (w = 30%) in TOXIC against `−2.181%`.
>
> **HONEST LIMIT ON THAT LAST CLAIM:** taking the argmax over 13 widths *ex post* inflates the
> t-statistics (PITFALLS 5.34), so `B₁ > LP` is **NOT** established in BENIGN or NORMAL at n = 30.
> In TOXIC it is not close (t = +67). **It does not matter which reading is taken: `B₁ = LP` gives
> slack exactly `0.000`, `B₁ > LP` gives slack negative. There is no reading in which slack is
> positive.**
>
> **⚠ AND A PRECISION LIMIT ON EVERYTHING NUMERIC BELOW, WHICH MUST NOT BE GLOSSED.** The BENIGN
> `LP` bar carries a **standard error of 0.573 pp over 120 paths**, while the entire ceiling under
> discussion is **0.2875 pp** — half the SE of one of its own inputs. A 40-path subsample moved `LP`
> by 0.565 pp. **So the SIGN of the slack is NOT resolvable at 120 paths; both the published
> "+0.19 pp" and the corrected "−0.39 pp" sit inside the noise.**
>
> **This does not weaken the conclusion, because the conclusion does not rest on the simulation.**
> `SLACK ≤ 0` follows from the `check_null` IDENTITY (4.3e-14) — a static position over the band
> returns exactly `LP`, so `B₁ ≥ LP` by construction. That is exact. **What is NOT established is
> `SLACK < 0` strictly, and it must not be claimed.** No positive surplus is proven; *how* negative
> is unknown. Anyone re-opening this must size the path count to resolve `LP − B₁` first, or accept
> that the answer comes from the identity alone.
>
> **CONCLUSION: no ordering rule, no φ, no roster, no band width and no capital schedule can make
> this mechanism create surplus for its participants.** The identity forbids it and the outside
> option caps it. What remains is a redistribution with a real cost attached (+119% gas), and the
> only parties who can rationally take a seat are those whose mandate forbids the free alternative —
> which is not something a simulator can price, and is not something we have evidence for.

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

**⛔ THE SENTENCE THAT STOOD HERE — "a window DOES exist in BENIGN and NORMAL … 0.16-0.19 pp,
roughly 1.0-1.1%/yr" — IS RETRACTED.** It used the handicapped `B₁`; against the true bar the
windows are EMPTY in all three regimes, and `SLACK ≤ 0` by the identity at the top of this file.
The rows below are kept as the arithmetic that WAS computed, not as a result. TOXIC is empty for a different and
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
| ~~a keeper at its BEST width (w=10%, own-pool)~~ **RETRACTED — a handicapped bar; 1 positive cell out of 105** | ~~+0.57 pp~~ | ~~0.19 pp~~ → **≤ 0** |
| a keeper at 1% width (-69.19%) | +74.2 pp | 24.7 pp — but nobody rational runs that |

**Three consequences, all of which change what this project should do:**

1. **The product's entire value is `LP - B1`.** QUEUE is worth something exactly to the extent that
   its front-seat buyer would otherwise be running a strategy that LOSES to passive LPing. That is a
   strange thing to sell, and it is the truth. It also means the one number worth any more simulator
   time is `B1` — the keeper's best achievable return, swept over width. If some managed width beats
   passive LPing, `B1 > LP`, the slack is NEGATIVE, and the mechanism cannot clear at any `phi`.

2. **Depth was never the economic variable — `c_1` was.** Surplus is LINEAR in the head's capital
   share, so a 32-seat roster is worth **11x less than the shipped one at any bar** — and since the
   bar makes the whole quantity <= 0, that is 11x less than nothing. The RATIO is what survives;
   the magnitudes below are the retracted arithmetic. Shipped 5-seat linear (`c_1 = 0.333`)
   -> ~0.19 pp under the handicapped bar. Thirty-two EQUAL seats
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
