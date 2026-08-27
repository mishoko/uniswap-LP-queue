# PREMISE REVIEW — is front-of-queue an ASSET or a LIABILITY?

**Panel:** Economic Incentives Analyst · Devil's Advocate · Skeptic Web3 Expert (attack feasibility).
**Date:** 2026-08-26. **Scope:** the central economic premise of QUEUE only. The protocol-fee hazard
(§E.5) is explicitly out of scope and untouched here.

**Tags:** [MEASURED] executed code · [SOURCED] quoted from a repo doc with line numbers ·
[ANALYSIS] reasoning, not measurement. **Everything numeric below that is not [MEASURED] is
[ANALYSIS] — a closed-form model, not an empirical study. No on-chain flow data was fitted.**

---

## 0. VERDICT UP FRONT

> **The premise HOLDS. Front-of-queue is an ASSET, not a liability. The team-lead's attack — "no
> cancel ⇒ front concentrates adverse selection ⇒ rank is worth negative" — is WRONG, and it is
> wrong for a specific, checkable reason: the CLOB analogy imports the wrong asymmetry.**
>
> **Confidence: HIGH (~85%) on the sign. LOW on the magnitude.** The sign result is a two-line
> identity, not a judgment call. The magnitude depends on a seat market that does not exist.

**But three things that ARE broken, in descending order of how badly they will embarrass you:**

1. **The capital-efficiency hole (NEW, not in any doc).** The hook is the sole LP holding **one
   full-range position** (`PLAN.md:64`, `:325`, `BUSINESS.md:264`, `:306`). A full-range CPMM offers
   roughly **1/100th to 1/200th the depth per dollar** of a ±1% concentrated position. A v4-native
   judge will ask *"who routes to a pool that is 200× thinner than the vanilla pool next door?"* —
   and **neither `BUSINESS.md` nor `PLAN.md` contains a single sentence about this.** This is a
   sharper attack than the toxicity one and it is currently unanswered. §6.
2. **"The seat price measures toxicity" is overclaimed.** Under the correct model the front seat is a
   **leverage** instrument, so its price measures `C/c₁ × (expected LP return)` — a quantity that is
   already computable from public swap data. The novel part is that it is *forward-looking and
   on-chain*, not that it reveals something unobservable. And under Harberger the signal is
   **censored at zero** on exactly the toxic side where it would be interesting (`BUSINESS.md:448-451`
   already half-admits this). §5.
3. **In the SUBMITTABLE state (Phase 3), the tail seat is strictly worse off than a normal v4 LP,
   with zero compensation.** The compensation channel is Harberger rent, which is **Phase 4**
   (`PLAN.md:1035` marks Phase 3 as `◀ SUBMITTABLE STATE`). So Phase 4 is not optional for the
   rank-then-run hole alone — **it is what makes the tail's participation rational at all.** §7.

---

## 1. DOES `BUSINESS.md` ALREADY ADDRESS THE ATTACK? — QUOTED, THEN JUDGED

It addresses it **three times, and all three are honest but incomplete.** None of them is the actual
answer; two of them are closer to a concession than a rebuttal.

### 1.1 `BUSINESS.md:33-36` — the framing sentence

> *"The front of the line is not automatically the better seat. When the flow is ordinary two-way
> trading, the front collects the whole fee on a small capital base and is worth a great deal. When
> the flow is one-directional and informed, the front is the seat that absorbs the entire adverse
> move first, and it is worth less than the back. **Which way the price points is the information.**"*

**Judgment: sound as far as it goes, but it is a restatement of the question, not an answer.** It
asserts a two-regime structure without deriving the boundary between the regimes, and it silently
assumes the mechanism still works when the front is worth less than the back — which §7.4 later
concedes is **false under Harberger**, the only price-discovery mechanism the plan actually
recommends (`PLAN.md:760-771`).

### 1.2 `BUSINESS.md:374-379` — the 50× identity and "the honest other half"

> *"S1 is 2% of the pool and earned 100% of the fee: a **50× multiple**, which is not a result, it is
> an identity — the ratio is exactly `total capital / front seat capital`. **The honest other half:**
> S1 also bore **100% of this swap's adverse selection** instead of 2%. The front seat is 50×
> leverage on the flow, in both directions."*

**Judgment: this is the correct answer and the document does not realise it.** "50× leverage on the
flow, in both directions" **is** the resolution of the central question — see §3 — but it is written
as a caveat and then abandoned. The document never asks the one question that follows from it:
*is the leverage on the benign stream equal to, greater than, or less than the leverage on the toxic
stream?* That single ratio is the entire product, and nobody in this repo has computed it. We do,
below.

### 1.3 `BUSINESS.md:708-712` (and `PLAN.md:1172`) — the splitting concession

> *"An informed trader who slices their order to stay inside the head is **not evading QUEUE** — they
> are concentrating the informed flow onto the one seat that is explicitly priced."*

`PLAN.md:1172` is even more explicit, as an acceptance criterion:

> *"**Split your order to stay at the head** — **Works, and is the design.** Assert that it
> concentrates informed flow onto the priced seat and does not break accounting. Do not 'fix' it."*

**Judgment: this is hand-waving, and it is the weakest paragraph in the business case.** It is a
literal statement of the team lead's attack, relabelled as a feature. "The seat is priced" is not a
defence — a priced liability is still a liability, and if the price is negative the Harberger variant
cannot express it (§7.4). The paragraph survives only because the *quantitative* version (§3) happens
to come out in QUEUE's favour — but the document never does that work, so as written it is an
unearned assertion. **Rewrite it.**

### 1.4 What is NOT addressed anywhere

- The **price-path** effect: a trend split across k swaps fills the front at the *early, worse* prices
  and the tail at the *late, better* ones. Every worked example (`§7.2`, `§7.3`) models a toxic event
  as **one swap**, which is exactly the case where this effect vanishes. It roughly **doubles** the
  front seat's relative loss versus the doc's own numbers. §4.3.
- The **exhaustion cap**: the front seat cannot absorb more than its own inventory, so it drops out of
  a sustained trend after one fill. This is the strongest pro-QUEUE argument in the whole design and
  it is written down nowhere. §4.4.
- The **full-range depth penalty**. §6.
- **Who actually buys**, beyond role archetypes. `BUSINESS.md:213-214` grades the professional market
  maker's buy-in as strong-ish and the JIT bot's as *"weak and should be stated as weak"*; we think
  the doc has the two most important buyers **backwards and missing**, respectively. §8.

---

## 2. THE ATTACK, STEELMANNED PROPERLY BEFORE IT IS ANSWERED

The team lead's argument, at full strength:

> In a CLOB, queue priority is valuable **because of the cancel**. A resting limit order is a free
> option written to the market; being at the front means being exercised first. That is only good if
> you can pull the quote when the option goes in-the-money against you. Priority without cancel is
> *"be the first to be run over."* QUEUE provably cannot cancel (no off-chain component, `AGENTS.md`
> §6) and provably cannot detect toxicity (`PLAN.md` §E.19, `IDEAS_CONSTRAINED` §1). Therefore the
> front seat is first in line for every arbitrageur, LVR concentrates on it, and rank is worth
> negative — which inverts the product.

**This is a serious argument and it is the right one to press.** It is also wrong, and the reason it
is wrong is precise.

### The refutation, in one paragraph

**A CLOB order rests at a FIXED price. A QUEUE seat does not.** `PLAN.md` §B.5 Step 3: every seat
filled by a swap is filled at `amtIn / amtOut` — *the swap's own realised average price* — and
`PLAN.md:503` states it plainly: *"The ratio `amtIn / amtOut` **is** the swap's realised average
price. It is the only price in the entire mechanism."* Front and tail, filled by the same swap, get
**identical execution prices**; only the **quantities** differ.

So the front seat is **not** holding a stale quote. There is no option being written that the tail
is not writing on identical terms. **Cancel is what manages a stale price; QUEUE has no stale price
to manage.** The thing that makes CLOB priority dangerous without a cancel — *your price is now
wrong and everyone else's is right* — has no analogue here.

What front-of-queue buys in QUEUE is **priority over QUANTITY, not priority at a stale PRICE.** That
is a categorically different object from CLOB queue position, and the cancel objection does not
transfer to it. The residual question is therefore not "is the front seat writing a bad option" but
"is the front seat's leverage tilted toward the good stream or the bad one" — which is arithmetic.

---

## 3. THE P&L DECOMPOSITION [ANALYSIS]

### 3.1 Setup

Pool capital `C` across seats; front seat capital `c₁`. Flow is a stream of swaps `j` of size `sⱼ`
(in value filled) with per-unit-filled P&L `τⱼ` (fee minus markout). Noise flow has `τ > 0`; informed
flow has `τ < 0`.

**Front seat fills `min(sⱼ, c₁)` of every swap. A pro-rata seat of the same capital fills
`sⱼ · c₁/C`.**

Define the **relative leverage** of the front seat on swap `j`:

```
                     min(sⱼ, c₁)        C
        L(sⱼ)  =  ───────────────  =  ─── · min(1, c₁/sⱼ)
                     sⱼ · c₁/C          c₁
```

**Two facts follow immediately, and they are the whole analysis:**

1. `L(s) = C/c₁` — the **maximum** — for every swap at or below the head's size.
2. `L(s) = C/s` — **decaying** — for every swap larger than the head. `L(s) ≥ 1` always.

⇒ **The front seat is levered on everything, and MOST levered on SMALL swaps.**

This reproduces both of `BUSINESS.md`'s own worked examples exactly, which is a useful check:
- §7.1, `s = $3,000` retail on `C=$1M, c₁=$20k`: `L = min(50, 333) = 50`. Doc says 50×. ✓
- §7.3, `s = $300,000` toxic sweep: `L = min(50, 3.33) = 3.33`. Doc says −123bps vs −36.8bps
  = **3.34×**. ✓

**The doc's own numbers are a special case of this formula. It just never wrote the formula down.**

### 3.2 The sign condition

Let `Vₙ` = noise volume, `Vₐ` = arb volume, `f` = fee rate, `m` = markout per unit of arb volume
(`m > f`). Let `αₙ, αₐ ∈ (0,1]` be the fraction of each stream the head captures,
`α = E[min(s,c₁)]/E[s]` over that stream's size distribution.

```
Front seat P&L per unit of its own capital:     Π₁  = [ f·αₙ·Vₙ + (f−m)·αₐ·Vₐ ] / c₁
Pro-rata seat P&L per unit capital:             Π_pr = [ f·Vₙ    + (f−m)·Vₐ    ] / C
```

**Front seat is profitable ⟺  f/(m−f) > (αₐ·Vₐ)/(αₙ·Vₙ)**
**Pool is profitable      ⟺  f/(m−f) >      Vₐ / Vₙ**

> **⇒ THE FRONT SEAT AND THE POOL HAVE THE SAME SIGN CONDITION, MODULATED ONLY BY THE RATIO
> `αₐ/αₙ`.**

- **`αₐ = αₙ` ⇒ rank is PURE LEVERAGE.** The front seat's return is exactly `C/c₁ ×` the pool's
  return. Its price is positive iff the pool's LP return is positive. Since a pool with a negative LP
  return has no LPs, **the front seat is positive-value in any pool that continues to exist.**
  Rank is a leverage instrument. **Defensible.**
- **`αₐ > αₙ` ⇒ the front is tilted TOXIC.** Requires arb trades to be *smaller* than noise trades.
- **`αₐ < αₙ` ⇒ the front is tilted BENIGN.** The head acts as a size filter that lets big toxic
  sweeps run past it. Requires arb trades to be *larger* than noise trades.

**This is the question the whole product turns on, and it is empirical, not philosophical.**

### 3.3 What is `αₐ` in a full-range v4 pool? — the decisive number

For a CPMM, correcting a relative mispricing `δ` requires a trade of value

```
    s  ≈  C · δ / 4
```

*(Derivation: `x·y=k`, `V = 2px`, moving price by `(1+δ)` needs `Δx = x(1 − (1+δ)^(−1/2)) ≈ xδ/2`,
so `p·Δx ≈ Cδ/4`.)*

So on `C = $1,000,000` with a `$20,000` head seat (`BUSINESS.md` §7's own fixture):

| mispricing corrected `δ` | arb trade size | head's share | leverage `L` |
|---|---:|---:|---:|
| 0.1 % | $250 | 100 % | **50×** |
| 0.5 % | $1,250 | 100 % | **50×** |
| 2 % | $5,000 | 100 % | **50×** |
| **8 %** | **$20,000** | **100 %** | **50×** ← head exactly exhausts |
| 20 % | $50,000 | 40 % | 20× |

> **It takes an 8% instantaneous price move to sweep past the head seat.** Every routine CEX–DEX
> arbitrage — which is what LVR *is* — is smaller than that and is absorbed **entirely** by the front
> seat, at full `C/c₁` leverage.

**⇒ `αₐ ≈ αₙ ≈ 1` in the realistic regime. Rank is PURE LEVERAGE. It does not change the mix.**

This is the honest answer to the team lead's question 3: **front-first scales both streams up by the
same factor. It is a leverage instrument, not a trap.** The size-toxicity filter people imagine (big
trades = toxic, so let them sweep past) **does not operate**, because arb trades on a pool this size
are small. The tilt only appears at the extremes, and there it is **favourable** (`L` is capped at
`C/s` for big sweeps, never above `C/c₁` for small ones).

> **KEY: the front seat's leverage on the benign small-swap fee stream is `C/c₁`, the MAXIMUM
> possible. Its leverage on the toxic stream is `min(C/c₁, C/s) ≤ C/c₁`. The tilt is therefore
> WEAKLY FAVOURABLE, everywhere, for every size distribution. There is no size distribution that
> makes the front seat tilted toxic relative to the pool.**

That last sentence is the strongest form of the result and it is worth stating on camera: **`L` is a
non-increasing function of size, so the front seat can never be MORE levered on large flow than on
small flow. If toxicity is weakly increasing in size — which is the standard empirical prior — the
tilt is strictly favourable. If toxicity is size-independent, it is exactly neutral leverage. The
adverse case requires toxicity to be strictly DECREASING in size, which nobody believes.**

### 3.4 The regime table the pitch should carry

| Regime | Condition | Front seat | Rank price |
|---|---|---|---|
| **Benign two-way, high turnover** | `f·Vₙ > (m−f)·Vₐ` | `C/c₁ ×` a positive number | **Strong premium.** Best case. |
| **Balanced** | `f·Vₙ ≈ (m−f)·Vₐ` | ≈ 0, at high variance | Near zero, high vol of the price itself |
| **Arb-dominated / low retail** | `f·Vₙ < (m−f)·Vₐ` | `C/c₁ ×` a negative number | **Negative — and Harberger cannot express it (§7.4). The mechanism degenerates (see §5.3).** |
| **Event day (one-directional)** | trend of size `S` | loses `≈ 2C/S ×` pro-rata, capped by own capital | irrelevant intraday; feeds the forward price |

The honest headline: **rank is positive-value exactly when the pool is a good pool.** QUEUE does not
create value out of a bad pool; it levers a good one. That is a smaller claim than
`BUSINESS.md`'s appendix makes, and it is true.

---

## 4. DIRECTION, THE PRICE PATH, AND THE EXHAUSTION CAP

### 4.1 Does direction matter? Yes — and the design already handles it correctly

`PLAN.md` §B.6 specifies **two cursors**, one per token, with `INVARIANT C`: *"for each token X,
every seat at index `< cursorX` holds `aX == 0`."* A seat exhausted in `token1` **still holds
`token0` and is refilled first on the reverse leg.** [SOURCED, `PLAN.md:593-628`]

So the front seat is front-first in **both** directions. Consequences:

- Under **two-way / mean-reverting** flow, the head **round-trips continuously**: it sells `a₁`,
  collects a fee; buys it back, collects another fee. Its inventory oscillates around flat and its
  fee income accrues **without bound in the number of round-trips**. The tail seats collect
  **nothing**.
- Under **one-directional** flow, the head is converted into the depreciating asset **first and at
  the worst prices** — but only once (§4.4).

**Being filled in both directions HELPS.** It is what converts the front seat from a directional bet
into a market-making position. If the design had a single cursor, the head would be permanently
stranded on one side after the first sweep and the seat would be worth far less.

### 4.2 One thing the two-cursor design gets right that nobody has said out loud

`PLAN.md:614-624` — *"`cursorY = min(cursorY, start)` ... The second line is the one people forget.
A lagging cursor costs gas; a leading cursor loses money."* This is not just a correctness note: it
is what **preserves the round-trip property**, which is the front seat's entire economic value. If
the `min` is dropped, the head silently stops being refilled and the seat's value collapses. **The
negative control at §D.5 is therefore an ECONOMIC test, not just an accounting one. Label it as such
so nobody optimises it away.**

### 4.3 The price-path effect — MISSING FROM EVERY WORKED EXAMPLE

`BUSINESS.md` §7.2 and §7.3 both model a toxic event as **a single swap**, so every filled seat gets
the same realised average price and the only difference is quantity. **Real informed flow is not one
swap.** It arrives as a sequence across blocks — and by the project's own Splitting Lemma (§E.15) a
sophisticated actor splits at fractions of a cent.

Under front-first, a trend split into `k` swaps fills the **front seat in swap 1** — at the *earliest,
least-moved, worst* price — and the tail in swap `k`, at the *latest, most-moved, best* price.

Model: a trend of total size `S` moving price by `Δ`, in `k` equal slices, head capital `c₁ ≤ S/k`:

```
front seat loss     ≈  Δ · c₁ · (1 − 1/2k)   →   Δ·c₁       for large k
pro-rata seat loss  ≈  (c₁/C) · S·Δ/2
ratio               ≈  2C/S
```

| trend size `S` | doc's single-swap ratio | **split-trend ratio `2C/S`** |
|---|---:|---:|
| `S = 0.3C` (the §7.3 example) | 3.34× | **6.7×** |
| `S = C` | ~2× | **2×** |
| `S = 0.1C` | ~10× | **20×** |

> **The front seat's adverse selection on a trend is roughly DOUBLE what `BUSINESS.md` §7.3 shows,
> because the doc's model has no price path. Fix the worked example before it is shown to a judge who
> can do this arithmetic.**

**Does it flip the sign? No.** The fee leverage on small benign flow is `C/c₁ = 50×`; the toxic
leverage on a split trend is `2C/S`, which equals 50× only when `S = 0.04C` — a trend *smaller than
twice the head seat*. For any trend larger than that, the toxic leverage is **below** the benign
leverage. The tilt stays favourable. But the margin is thinner than the doc implies, and the doc
should stop implying it.

### 4.4 The exhaustion cap — the strongest pro-QUEUE argument in the design, and it is written down NOWHERE

`PLAN.md` §B.5 Step 3: `take := min(bal, remaining)`; `if bal == 0: continue`; cursor advances
monotonically. **A seat can only be filled up to its own inventory in the outgoing token.** Once the
head's `a₁` hits zero it is *skipped* for every subsequent same-direction swap.

⇒ **The front seat's loss on any one-directional move is BOUNDED at one full conversion of its own
capital. Its fee income under two-way flow is UNBOUNDED in the number of round-trips.**

```
        DOWNSIDE:  bounded per trend      (converts once, then drops out)
        UPSIDE:    unbounded per unit time (round-trips forever, collecting 100% of the fee)
```

**That asymmetry is exactly the payoff a market maker wants, and it is precisely why queue position
is valuable in a CLOB — and it survives the absence of a cancel.** A trending market "uses up" the
front seat and then moves on to the tail; a chopping market pays the front seat over and over and
never touches the tail.

This is the argument the pitch should lead with when a judge raises the cancel objection. It is
mechanically true, it follows from three lines of the allocator, and no document in this repo
contains it.

---

## 5. WHAT THIS DOES TO THE HEADLINE CLAIM — "the seat price IS the toxicity"

### 5.1 The claim, and what survives

> `BUSINESS.md:433-435` — *"That number — the price of moving from the front to the back — is the
> pool's toxicity, in the pool's own numéraire, discovered by capital rather than asserted by a
> formula. It is unforgeable because the bid costs real money."*

Under the pure-leverage result (§3.3), the front/back price spread is
`≈ (C/c₁ − c₅-leverage) × E[pool LP return]`. So:

- **The SIGN of the spread does track the sign of the pool's LP return.** ✔ The claim's direction is
  correct and the "unforgeable because the bid costs real money" part is genuinely true — there is no
  free way to move the seat price.
- **The MAGNITUDE is leverage-contaminated.** It is `C/c₁ ×` the thing you care about, so it is
  sensitive to a *governance parameter* (seat sizing) as much as to flow. Two pools with identical
  toxicity and different seat-size distributions produce different spreads. **The spread is not a
  clean toxicity measurement; it is a leveraged expected-return measurement.**
- **The novelty is narrower than pitched.** "Is this pool's LP return positive" is already computable
  from public swap data by anyone who can compute markout. QUEUE's contributions are that the number
  is (a) **forward-looking** — a market forecast, not a backward markout — and (b) **on-chain and
  binding**. Both are real. Neither is "the measurement the organizers say does not exist."

**Recommendation: retire the sentence at `:433-435` in its current form.** Replace with something you
can defend under questioning, e.g.:

> *"The seat price is a market-forecast, on-chain, capital-backed estimate of the pool's forward LP
> return, levered by the seat's share of the book. Its **sign** tells you whether this pool's flow is
> net-benign. That number does not exist today in any AMM."*

That is still a strong, novel, defensible claim and it does not require anyone to believe the
uncontaminated version.

### 5.2 The Harberger censoring problem — worse than §7.4 admits

`BUSINESS.md:448-451` concedes: *"A standard Harberger tax prices a non-negative self-declared value
and cannot express 'pay me to sit here.' Under toxic flow every holder declares near-zero and no rent
flows... Anyone building the Harberger variant must solve this, and it is not solved today."*

**We confirm this and sharpen it.** The Harberger price is `max(0, true value)` — a **floor-censored
signal.** It reports "benign, by this much" on one side and "not benign" on the other, with no
magnitude. That is not fatal (a censored signal is still a signal), but note the consequence: **the
signal is informative exactly in the regime where the answer was already obvious, and goes silent in
the regime where you would actually want to consult it.** Say that plainly rather than being caught
with it.

`PLAN.md:760-771` recommends *skipping the secondary market entirely* and using Harberger for price
discovery ("strictly the better demo"). **If you do that, the censoring problem is no longer a
Phase-4 footnote — it is the only price the product produces.** Weigh accordingly.

### 5.3 The degeneracy under toxic flow — a mechanism failure mode, stated precisely

This is not a "free lane" in the `AGENTS.md` §5 sense (QUEUE deters nothing, so nothing can become
the cheapest deterred action), but it is a real degeneracy and it should be on the risk list:

1. Flow turns toxic. The front seat's expected return goes negative at `C/c₁` leverage.
2. Under Harberger the holder declares `selfPrice = 0` ⇒ `rentOwed = 0` ⇒ **never forecloses**
   (`PLAN.md` §B.10: `rentOwed = τ·selfPrice·Δt/RENT_PERIOD`). Foreclosure — which demotes you to the
   tail — is a **reward** in this regime, so the enforcement mechanism points the wrong way.
3. The rational move is therefore not to lower the price but to **withdraw the capital entirely**
   (`PLAN.md` §B.7: *"Withdrawing to zero does NOT destroy the seat"*). The seat becomes empty rank.
4. An empty head is skipped by the allocator (`if bal == 0: continue`). The next funded seat becomes
   the effective front. Repeat.
5. **The queue unwinds from the front until it reaches a seat whose holder will bear it — i.e. until
   the pool is small enough that `C/c₁` leverage is tolerable. In the limit, QUEUE becomes a normal
   pool with extra gas.**

**This is a graceful failure, not a catastrophic one — no funds are at risk and the pool keeps
trading — but it means QUEUE's mechanism has an operating range, not a universal domain.** Disclose
it. It is far less embarrassing to name than to be shown.

---

## 6. THE HOLE NOBODY HAS LOOKED AT: FULL-RANGE CAPITAL EFFICIENCY

**This is the single most likely question from a v4-native judge and there is no answer in the repo.**

The hook mints **one full-range position** and reverts every external add:
- `PLAN.md:64` — *"full-range position that it owns itself, and refuses every external attempt"*
- `PLAN.md:325` — *"one pool, one full-range position"*
- `BUSINESS.md:264,306` — *"one full-range position"*, *"one wide band. No per-tick maths."*

Grep confirms: **`BUSINESS.md` and `PLAN.md` contain zero occurrences of any discussion of the
depth-per-dollar cost of that choice.**

**The arithmetic.** For a full-range CPMM, marginal depth `d = C/4`, so a trade of value `s` moves
price by `δ ≈ 4s/C`. A ±1% concentrated position has a capital-efficiency multiplier of roughly
`2/r ≈ 200×` for `r = 1%`.

⇒ **A $1,000,000 full-range QUEUE pool quotes approximately the same depth as a ~$5,000–$10,000
concentrated position in the vanilla pool next door.** A $10,000 swap into it costs **~4% slippage.**

**Consequences, stated bluntly:**

1. **No aggregator will route retail to it.** Retail flow is the *entire* benign side of the P&L. If
   `Vₙ → 0`, then by §3.2 the pool is arb-only, the pool's LP return is negative, and — by the pure
   leverage result — **the front seat's return is `C/c₁ ×` a negative number.** The team lead's
   feared inversion **does happen**, but the cause is not front-first allocation; it is
   **full-range-ness starving the pool of benign flow.**
2. **The two design constraints fight each other.** To be depth-competitive at full range you need
   ~100–200× the TVL of a concentrated pool. But the roster is capped at **~32–44 seats** by gas
   (`BUSINESS.md:459-490` [MEASURED]). So each seat must be enormous — a $200M pool over 32 seats is
   ~$6M/seat. That is a coherent *professional venue* story, and it is also a very long way from a
   demo.
3. **This is not a v4 constraint, it is a design choice, and it is reversible.** Nothing in the
   allocator depends on full range — §B.5 works off the swap's realised delta and never touches
   ticks. **The hook could hold one concentrated band instead**, at the cost of out-of-range
   handling (the queue's inventory goes one-sided, which the two-cursor design already tolerates)
   and a rebalancing question. **This is the highest-value unexplored design axis in the project.**

**Recommendation:** either (a) concede this in the first minute alongside the 44-seat concession —
*"QUEUE is a professional venue; it needs depth, and full range is what buys the accounting
simplicity that makes the allocator provably exact"* — or (b) spike a bounded-band variant. Do **not**
let a judge find it first. **Note the honest trade: full-range-ness is exactly what makes the
allocator's wei-exactness [MEASURED] tractable. It is a real trade, not an oversight — but it is
currently an undisclosed one.**

---

## 7. THE TAIL — IS IT TREATED UNFAIRLY BY THE DESIGN ITSELF?

*(The protocol-fee bug is excluded from this section by instruction.)*

### 7.1 The conservation identity forces the answer

`BUSINESS.md:406` [MEASURED-adjacent, structural]: *"The total is unchanged to the cent... This is
redistribution, not reduction."*

Total pool P&L is conserved. Front seats take leverage `> 1`. **Therefore tail seats necessarily take
leverage `< 1`. This is an identity, not a modelling choice.**

⇒ **In a pool with a POSITIVE LP return, the tail seat earns STRICTLY LESS per unit capital than the
same capital would earn as a normal pro-rata v4 LP.** In a pool with a NEGATIVE LP return it earns
strictly more (loses less). **The tail is a de-levered / short-beta position on the pool.**

### 7.2 So: unfair, or exactly what they signed up for?

**Neither, as currently specified — it is UNCOMPENSATED, which is a different and worse problem.**

- It is **not unfair in the design's own sense.** `BUSINESS.md:744-747` (Counter 5) is right: rank is
  present state, nobody is *assigned* to the tail, and `PLAN.md` §E.18 correctly refuses to make
  fairness a predicate. Front-first is not a bug; it is the product. A tail holder who paid less for a
  lower-beta seat got what they bought.
- **But the compensation channel is Phase 4, and the submittable state is Phase 3.**
  `PLAN.md:1035` marks Phase 3 `◀ SUBMITTABLE STATE`. Harberger rent — the mechanism that pays the
  tail, *"the seats **behind** you, pro-rata by their `currency0` balance"* (`PLAN.md` §B.10) — is
  **Phase 4**. And the secondary market that would otherwise let a tail holder charge for selling the
  front **does not exist** (`BUSINESS.md:604-608` §9.7; `PLAN.md:760-771` says a supply-1 ERC-6909 id
  is not poolable without a wrapper).

> **⇒ In the Phase-3 submittable state, a tail depositor in a benign pool is STRICTLY WORSE OFF than
> they would be as an ordinary pro-rata v4 LP, and receives NOTHING in exchange. There is no
> economically rational reason for anyone to hold a tail seat in Phase 3.**

**This is the sharpest finding in this review after §6, and it has a clean consequence:**

> **Phase 4 (Harberger) is NOT optional and it is NOT merely the fix for the rank-then-run hole
> (`PLAN.md` §E.13). It is the ONLY thing that makes the non-front side of the market rational. A
> Phase-3 demo is a one-sided market: it shows the front seat's leverage and has no story for why
> anyone else is in the pool.**

If Phase 4 cannot be reached in time, the honest Phase-3 framing is *"the tail seat is a lower-beta
LP position whose compensation mechanism is the next phase"* — said out loud, not omitted.

### 7.3 Two things the tail does get, honestly

1. **Lower variance.** `BUSINESS.md:402` [ANALYSIS]: S5 at −0.4bps vs S1–S4 at −71bps on the sweeping
   swap. Real, and worth something to a treasury with a mandate.
2. **Better prices on trends.** Per §4.3, the tail is filled at the *late* prices of a split trend.
   This is a genuine, unpriced advantage that the doc's single-swap examples cannot show, and it is
   the mirror image of the front's price-path penalty. **Add it to §7.3's table.**

---

## 8. WHO REALISTICALLY BUYS A SEAT?

We can name buyers. **This is not fatal.** But `BUSINESS.md` §5's role table has the two most
important ones **inverted and missing** respectively.

### 8.1 The buyers, ranked by how coherent the economic reason is

**1. A flow ORIGINATOR who routes its own benign flow — wallet, front-end, aggregator, RFQ desk.**
**[STRONGEST BUYER IN THE DESIGN. COMPLETELY ABSENT FROM `BUSINESS.md`.]**
Motive: they hold **private information that the flow hitting this pool is benign — because it is
theirs.** They buy the front seat and internalise their own retail flow at `C/c₁` leverage. They do
not need the hook to identify the trader (which `PLAN.md` §E.8 proves is impossible) — they simply
route their users to the pool where they own the front.

**This is on-chain PFOF where the payment goes to the LPs instead of to a broker — and
`BUSINESS.md:168-172` already builds the PFOF comparison table and then fails to close the loop.**
Its own line `:172` says *"Who receives: **The LPs.**"* — that is the product, and the buyer it
implies is never named in §5. **Add this row. It is the best answer to "who buys" in the whole
document.**

**2. A professional market maker with an off-venue hedge (Wintermute / SCP / Auros class; on-chain,
the shops that run JIT today).** [`BUSINESS.md:213` grades this "gains a durable ownable position" —
correct, but the doc then grades the JIT bot's buy-in as *"weak and should be stated as weak"* at
`:214` and conflates the two roles.] **We disagree with the doc's grading.** The JIT *bot* and the
market *maker* are different businesses. The bot's business **is** the free lane and it will indeed
trade elsewhere. The maker's business is durable, uncontestable priority — which is the one thing a
vanilla pool cannot sell at any price, because tick concentration is contestable by anyone with more
capital in the same block. **The MM's buy-in is the second strongest in the table, not the weakest.**

**3. An inventory accumulator.** A DAO or issuer that genuinely wants to be filled first when its
token is being sold — the front seat is a levered, always-on limit-buy programme with fee income
attached. Small but real, and it is the only buyer whose motive is *non-financial* (treasury policy),
which makes it price-insensitive and therefore a good marginal bidder.

**4. Speculators on the seat itself / the toxicity view.** Someone who thinks this pool's flow is
better than the market does buys the front. This is the buyer that makes the *signal* work, and it is
thin by construction in a new pool (`BUSINESS.md:604-608` concedes this is *"the weakest point in the
entire design"* — agreed).

### 8.2 Who does NOT buy, and this matters

**The CEX–DEX arbitrageur does NOT buy the front seat, and the reason is worth understanding.**
If arbitrageur A owns the front seat and continues arbing the pool, A is the counterparty to A's own
arbitrage: seat P&L `= −μq + fq`, trading P&L `= +(μ−f)q`, **net exactly zero.** A has neutralised
its own edge. Since on-chain arb is competitive at the margin, A's alternative (don't own the seat,
keep the edge) strictly dominates.

**⇒ The searcher is the natural SELLER of the front seat, not its buyer.** That is a *good* property —
it means the seat naturally migrates to parties whose flow is benign — and it is the cleanest
mechanism-design argument QUEUE has. **It is not in any document. Put it in the pitch.**

### 8.3 The buyer-side threat the docs undersell

**The front seat is a substitute for tick concentration, and tick concentration is nearly free.** A
market maker who wants `50×` fill leverage today mints a tight range in the vanilla pool and pays
gas. `BUSINESS.md:128` and `:190-201` (§4.3) touch this from the *defence* angle ("the jump is not
available in a QUEUE pool") but never from the *competitive* angle: **why come to the QUEUE pool at
all?**

The answer exists and should be stated: **concentration gives you CONTESTABLE priority (a JIT bot
mints 100× your size in the same block and your pro-rata share collapses) and imposes RANGE RISK
(out of range = zero income). Rank gives you UNCONTESTABLE priority with no range risk.** That is a
real, defensible differentiator — and it is the actual DMM analogy, properly stated. **It bounds the
seat's price above by the cost of replicating the leverage elsewhere, which is not huge — so expect
seat prices to be modest, and do not build a pitch around a large number.**

---

## 9. IS THERE A CONFIGURATION WHERE THE PREMISE HOLDS ROBUSTLY?

**Yes. State it as a configuration, not as a universal claim.**

```
ROBUST CONFIGURATION
  ├─ High-turnover, two-way pair            (maximises round-trip fee income, §4.4)
  ├─ Deep pool                              (so full-range depth is still competitive, §6)
  ├─ Meaningful fee tier (≥30bps)           (raises f, the whole benign side of §3.2)
  ├─ Head seat NOT tiny relative to routine arb size   (see below)
  ├─ Harberger rent live (Phase 4)          (compensates the tail, §7.2)
  └─ Retail actually routes there           (the binding constraint — §6)
```

**One tuning result worth acting on.** Leverage is `min(C/c₁, C/s)`. Since routine arb is *small*
(§3.3), a *tiny* head seat maximises leverage on **both** streams equally and buys no tilt. A head
seat sized **at or slightly above the routine arb size** does something better: it still captures
~100% of retail (retail is small) while beginning to let genuinely large toxic sweeps run past it.
**Seat sizing is therefore an economically load-bearing parameter, and the design currently treats it
as free.** Recommendation: make head-seat sizing an explicit, discussed deployer parameter alongside
`MAX_SEATS = 32` (`PLAN.md` §B.9), and say on camera that its optimum is `≈` the pool's routine arb
clip size.

**Does Harberger fix the selection problem, or just price it?** **It prices it, and it censors the
price at zero.** §5.2, §5.3. It closes the rank-then-run hole (`PLAN.md` §E.13) and it compensates
the tail (§7.2) — both essential — but it does **not** repair the toxic-flow regime, and under toxic
flow its foreclosure mechanism points the wrong way (demotion to the tail is a reward). **Do not
present Harberger as the fix for the economics. Present it as the fix for abandonment and tail
compensation, which is what it actually is.**

---

## 10. BOTTOM LINE

**Deploy it. Demo it. You will not be ridiculed on the economics of front-first allocation — that
part is sound and the sceptical case against it is refutable in one sentence about stale prices.**

**You WILL be embarrassed if you:**

1. Show the current `BUSINESS.md` §7.3 to anyone who can compute a price path (§4.3 — the number is
   ~2× understated).
2. Claim the seat price "is the toxicity" without the leverage caveat and the zero-censoring
   (§5.1, §5.2).
3. Ship Phase 3 and let a judge ask *"why would anyone hold seat 5?"* — because in Phase 3 the honest
   answer is **"they wouldn't"** (§7.2).
4. Get asked *"how deep is a $1M full-range pool"* and not have an answer (§6). **This is the one to
   prepare for. It is the sharpest unanswered question in the project.**

**Ranked actions:**

| # | Action | Where | Why |
|---|---|---|---|
| 1 | **Write §3's leverage formula `L(s) = (C/c₁)·min(1, c₁/s)` into `BUSINESS.md`** and derive both worked examples from it | `BUSINESS.md` §7 | It is the answer to the central question and it reproduces the doc's own numbers |
| 2 | **Prepare the full-range depth answer, or spike a bounded-band variant** | new | Sharpest unanswered attack; not a v4 constraint, a reversible design choice |
| 3 | **Add the exhaustion-cap argument (bounded downside / unbounded upside)** | `BUSINESS.md` §1, pitch | Strongest pro-QUEUE argument in the design; currently written nowhere |
| 4 | **Reach Phase 4, or state the tail's uncompensated status out loud** | `PLAN.md` C.4 | Phase 3 is a one-sided market |
| 5 | **Add the two missing buyer rows: the flow ORIGINATOR (strongest) and the searcher-as-SELLER** | `BUSINESS.md` §5 | Best answer to "who buys"; currently absent |
| 6 | **Fix `BUSINESS.md` §7.3 for the price path; add the tail's late-price advantage** | `BUSINESS.md` §7.3 | Both directions of a missing effect |
| 7 | **Rewrite `:433-435` and `:708-712`** — the first overclaims, the second hand-waves | `BUSINESS.md` | Both are quotable against you |
| 8 | **Label `PLAN.md` §D.5's `cursorY = min(...)` control as an ECONOMIC test** | `PLAN.md` §D.5 | It protects the round-trip property, i.e. the seat's value |
| 9 | **Make head-seat sizing an explicit deployer parameter with a stated optimum** | `PLAN.md` §B.9 | Currently free; it is load-bearing |

**The one-sentence verdict:**

> **Front-of-queue in QUEUE is a LEVERAGE instrument on the pool's own LP return — `C/c₁` on the
> benign stream and at most `C/c₁` on the toxic stream — with a bounded per-trend downside and an
> unbounded round-trip upside. It is an asset, not a liability, in any pool worth being an LP in.
> The premise is sound. The two things that can still kill the product are a full-range pool nobody
> routes to, and a Phase-3 demo where the tail has no reason to exist — and neither of those is the
> objection that was raised.**
