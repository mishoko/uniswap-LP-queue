# Fairness review — is QUEUE's tail getting a bad deal?

**Panel:** Lead Exploit Developer · State Transition Expert · Edge Case Hunter · Economic Security.
**Date:** 2026-08-26. **Status of the code being reviewed:** Phase 0 NOT STARTED. Everything here is
ANALYSIS against `PLAN.md` §B/§E and `BUSINESS.md` §7–§9, plus the archived spike. **Nothing in this
document was executed.** Where a claim would need a test, it is labelled UNPROVEN.

---

## VERDICT IN ONE BOX

> **The owner's prior is half right, and the half that is wrong is the half that matters.**
>
> A tail seat **beats** pro-rata in the toxic / one-directional regime — `BUSINESS.md` §7.2 and §7.3
> both show it, and those are the only two worked examples in the repo. A tail seat **loses** to
> pro-rata in the benign two-way regime, which has **no worked example anywhere in the documents**.
> The docs' own examples are drawn entirely from the regime where the tail wins, which is why the
> prior survived this long.
>
> **Which regime you are in is not a matter of opinion: it is the sign of the pool's own net LP P&L.**
> QUEUE is exactly zero-sum against pro-rata (proven in §7.2 to the cent and structurally below), so
> the tail's excess return over pro-rata has the **opposite sign** to the pool's net profitability.
> Profitable pool ⇒ the tail is strictly worse off. Loss-making pool ⇒ the tail is strictly better off.
> **Both seats cannot beat pro-rata. No ordering, banding, rotation or partial-blend can change that.**
>
> **Therefore fairness in QUEUE is not an allocation problem. It is a transfer problem, and the design
> already names the transfer: sell or rent the rank.** The real defect is that in the *submittable*
> state (Phase 3, plain transferable rank) the transfer channel is a secondary market that
> `BUSINESS.md` §9.7 already concedes **does not exist**. The tail's deal is sound in theory and
> **empty in the demo**.
>
> **And the largest actual value leak to the tail today is not the ordering at all.** It is two
> accounting leaks — the protocol fee (§E.5, MEASURED at 0.1% of input, *100% absorbed by the tail*)
> and the redemption residual (§E.4) — both of which settle on **the last withdrawer**, and the tail
> is structurally the last withdrawer. Those are already scoped in Phases 1–2 and are worth more to
> the tail than any mechanism in Part B.

---

# PART A — IS IT ACTUALLY UNFAIR?

## A.1 The correct baseline, and the zero-sum identity

The alternative to a QUEUE seat is being a pro-rata LP **in the same pool, against the same flow, at
the same prices**. That is the only honest comparison and it makes the analysis nearly trivial,
because of one structural fact:

> **Within a single swap, every filled seat trades at the same realised average price
> `amtIn / amtOut`.** (`PLAN.md` §B.5 step 3 — `give = mulDiv(amtIn, take, amtOut)`.) There is no
> intra-swap price discrimination between the head and the tail.

Two consequences follow immediately, and they are the whole of Part A.

**(1) Per unit of fill, the head and the tail earn identical economics.** Same price, same
fee-per-unit-filled, same markout. Front-first does **not** decouple fee income from adverse
selection — they are the *same fill*. What differs between seats is only the **frequency** of fill
and the **conditioning** of fill.

**(2) QUEUE is exactly zero-sum against pro-rata.** Total fees `F` and total adverse selection `L`
are fixed by the swaps, which QUEUE does not change (`BUSINESS.md` §9.2, and §7.2 measures the pool
total identical *to the cent*). So `Σ_i (fee_i − loss_i) = F − L` under both regimes. Under pro-rata
every seat's return per unit capital is exactly `(F − L)/C`. Under QUEUE the seats' returns are a
permutation of the same total.

> **THE FAIRNESS THEOREM.** Because the aggregate is invariant, **it is arithmetically impossible for
> both the front and the tail to beat pro-rata.** Every claim of the form "QUEUE gives the front more
> flow *and* protects the tail" is false as stated. One of them is below the pro-rata line, always.

This kills, in one line, every design option whose pitch is "make it fairer for everyone by
reallocating differently". There is no such option. Part B is therefore restricted to (a) **transfers**
(someone actually pays someone) and (b) **fixing leaks** (value currently going nowhere).

## A.2 Testing the owner's prior — the two regimes, with numbers

Let `u_i` = seat `i`'s **utilization**: the fraction of total flow that reaches it. The head has
`u ≈ 1` (capped by its own inventory per direction, which recycles). A deep tail has `u ≈ 0`.

Since per-unit economics are identical (A.1), seat `i`'s net is approximately
`u_i × (F − L) × (capital_i / C)` — i.e. **`u_i` scales fee income and adverse selection together, by
the same factor.** So:

| Regime | Pool net `F − L` | Tail vs pro-rata | Front vs pro-rata |
|---|---|---|---|
| **Benign two-way flow** (fees exceed markout) | **> 0** | **WORSE** — forgoes most of its share of a positive number | Better |
| **Toxic / one-directional** (markout exceeds fees) | **< 0** | **BETTER** — forgoes most of its share of a negative number | Worse |

**The toxic regime, from the repo's own numbers (`BUSINESS.md` §7.3).** $300k of informed selling.
S5 (the $530k tail) nets **$0 / 0 bps**; the same capital pro-rata nets **−36.8 bps = −$1,950**.
The tail beats pro-rata by **$1,950 on one episode.** §7.2 (a $500k sweep) is the same story: S5 at
**−0.4 bps** vs **−35.6 bps** pro-rata, a **$1,673** advantage.

**The benign regime — which the documents never work.** Take §7.1's swap (3,000 USDC → WETH, fee 9
USDC, head-only) and repeat it 100× a day in both directions with roughly balanced retail flow, so
markout ≈ 0. [ILLUSTRATIVE, not measured.]

| | S1 (head, $20k) | S5 (tail, $530k) |
|---|---:|---:|
| QUEUE fee income / day | **$900** (100% of every swap) | **$0** |
| Pro-rata fee income / day | $18 | **$477** |
| Adverse selection avoided by S5 | — | **≈ $0** (flow is balanced) |
| **S5's net vs pro-rata** | — | **−$477 / day** |

$477/day on $530k is **~9 bps/day**. **The tail gives up nearly all of its fee income and, in this
regime, receives nothing back**, because the thing it is "insured against" is not happening.

> **VERDICT ON THE PRIOR: the prior is correct only in the loss-making regime, and it is exactly
> backwards in the profitable one.** "Less fill ⇒ less adverse selection ⇒ better than pro-rata"
> silently assumes adverse selection dominates fees. If that were reliably true, nobody would LP at
> all. **State the regime or the claim is meaningless.**

### A.2b The conditioning effect — the prior is *further* wrong than the utilization argument shows

The utilization model above treats the tail's fills as a random sample of flow. **They are not.** By
construction the tail is filled **only when a single swap is large enough to sweep past everything
ahead of it.** That is a conditioning event, and it is not neutral:

- Informed trades are larger (standard Kyle / Easley–O'Hara result). A size-conditioned fill sample is
  **more toxic per unit filled** than the unconditional average.
- ⇒ the tail's markout-per-unit-filled is **worse** than the head's, not merely rarer.
- ⇒ **the tail is short a deep out-of-the-money gap option.** It collects almost no premium (few fills,
  therefore few fees) and pays out precisely on the large directional moves.

This does not overturn the zero-sum identity — it sharpens where the tail sits inside it. **The tail's
distribution is worse than its mean.** Any pitch that sells the back seat as "safe" is selling a short
tail-risk position as safety, and a technical judge will say so.

### A.2c THE RATCHET — a structural asymmetry not named anywhere in the docs

Front-first applies **in both directions**. Follow the consequence:

1. A large sell sweeps the queue. Every seat, including the tail, gives up `currency0` and receives
   `currency1` at a falling price. The tail is now holding inventory acquired at the extreme.
2. Price recovers. Someone buys. The fill starts **at the head again**.
3. **The head unwinds first. The tail's badly-acquired inventory is unwound only if a swap in the
   opposite direction is *equally large*.**

> **The head is a market maker with recycling inventory. The tail is a one-way accumulator with no
> priority to exit.** It is filled at extremes and has no claim on the mean reversion.

**Severity: moderate, not fatal.** The tail can rebalance manually — withdraw and re-deposit; its rank
is unaffected (rank is a fixed index, `PLAN.md` §B.7: "withdrawing to zero does NOT destroy the seat").
So this is a **cost of active management imposed on the party the pitch describes as passive**
(`BUSINESS.md` §5: "treasury, LST issuer, yield vault"). That is a real contradiction in the sales
story and it should be said out loud. **Option B-2 (two-sided rank) is the only proposal in Part B
that addresses it.**

## A.3 Is any seat strictly dominated? And what is the exit?

**Domination — YES, at the tail, asymptotically.** A seat behind more inventory than any executable
swap can consume is filled **never**. In a $1M pool a seat behind $900k needs a swap consuming >90% of
one side of the book — a price move so large it does not occur. Such a seat:

- earns **exactly zero**,
- holds a **static basket** identical to what it would hold in a wallet,
- and is **short the gap option of A.2b for free**.

> **A never-filled tail seat is weakly dominated by simply holding the two tokens in your wallet:
> identical return, plus an unpaid short tail-risk position, plus gas.**

That is the sharpest statement of unfairness available, and it is true. **But it is not a trap**, for
two reasons, and both must be stated with it:

1. **It is voluntary and priced.** Under the design's own hard rule (§E.16) the seat was **bought**.
   A rational buyer prices a never-filled seat at ~0 and pays ~0. Nobody is forced into it.
2. **Exit is free and unconditional.** `PLAN.md` §B.7 `withdraw(seatId, amount0, amount1)` — any
   amount up to the seat's balance, at any time, no lock, no exit fee, no notice period, no quorum,
   no admin. **Cost = gas + the §E.4 residual.**

> **Unfairness you can exit for gas is not unfairness. It is a price.** This single fact does more to
> answer the owner's question than any mechanism in Part B, and it should be the first sentence of the
> on-camera answer.

### A.3b ⚠ NEW HAZARD — per-seat withdrawal may not be feasible as specified. UNPROVEN. Phase 2 blocker.

**This is the most important finding in this review and it is not in `PLAN.md`, `BUSINESS.md` or the
spike.**

`PLAN.md` §B.7 specifies `withdraw` as: *"compute liquidityDelta to release those amounts;
`modifyLiquidity(-liquidityDelta)`; `take()` both currencies."* **That treats an arbitrary `(a0, a1)`
as releasable from the position. It is not.**

For a position over `[tickLower, tickUpper]` with the price in range:

```
amount0 = L · (1/√p − 1/√pb)        amount1 = L · (√p − √pa)
```

⇒ **removing liquidity returns the two tokens in a ratio fixed by the current price.** But the whole
point of QUEUE is that **individual seats deviate from that ratio by design** — the head is fully
converted one way, the tail is un-converted the other way. **Every seat's ledger ratio differs from the
position's redemption ratio; that is the product.**

Consequences, in order of severity:

- **A fully-converted seat (`a1 == 0`) cannot be paid its `a0` by removing liquidity alone.** Any `ΔL`
  large enough to return `a0` of token0 *also* returns token1 the seat does not own.
- The surplus token must go **somewhere**. The options are: (i) hold it idle in the hook — an
  out-of-position buffer that **earns no fees and belongs to the remaining seats**, i.e. a tax on
  whoever stays, which is **the tail**; (ii) redistribute it into other seats' ledgers — which needs a
  rule that does not exist yet; (iii) swap it — which re-enters `_afterSwap`, moves the price, and pays
  a fee. **All three are unspecified.**
- The archived spike **cannot have caught this**: it implements only `redeemAll()` (removes the *entire*
  position at once, where the ratio question vanishes by construction). Verified by inspection —
  `archive/2026-08-26/test/spike/QueueAllocator.t.sol:116`. **There is no per-seat withdrawal code
  anywhere in this repo.**

**The least-bad shape** (offered as a direction, not a spec): maintain a hook-held per-token reserve;
**net deposits against withdrawals through the reserve** and touch `modifyLiquidity` only for the
residual. Deposits are single-token-surplus in the opposite direction often enough that the reserve
should stay small. **This must be designed and tested in Phase 2, and the test must use a
fully-converted seat** — a seat whose ledger ratio happens to match the pool's will pass green and
prove nothing (this is LAW 1's shape in a new guise).

**Fairness placement:** whichever fix is chosen, its cost lands on **capital that stays in the pool**,
which is the tail. Add it to the tail's ledger.

## A.4 Who bears the residual, and is it material?

Not re-derived — `PLAN.md` §E.4 / §B.7 and `BUSINESS.md` §9.5 are taken as given. **Placing it:**

| Leak | Size | Who bears it | Material? |
|---|---|---|---|
| **§E.4 redemption residual** | **~0.26 wei / swap**, MEASURED | **The last withdrawer**, under a naive face-value `withdraw()` | **NO.** 200 swaps = 52 wei. Unfarmable by ~20 orders of magnitude. It is a **correctness** item, not a fairness item. |
| **§E.5 protocol fee** | **0.1% of input = ~33% of LP fee income at max**, MEASURED | **The tail — 100% of it**, stated in §E.5 itself: *"Because allocation is front-first, the tail of the queue absorbs 100% of it."* | **YES. Enormously.** |
| **A.3b withdrawal-ratio surplus** | **UNKNOWN — unmeasured** | Capital that stays = the tail | **UNKNOWN. Measure it.** |

**Three conclusions the panel wants on the record:**

1. **The 0.26 wei residual is a red herring in a fairness discussion.** It is four orders of magnitude
   below gas. Anyone spending time on it is optimising the wrong number. **Fix F1 anyway** — settle
   against actual holdings — because F1 also **stops dumping it on the last withdrawer** and spreads it
   across whoever withdraws. That is the fairness-correct fix and `PLAN.md` already recommends it.
2. **The protocol fee is the real one, it is ~10^18× larger, and it is 100% tail-incident.** It is a
   *silent, front-first-amplified transfer out of the tail*. **P2 (net out `protocolFeesAccrued` before
   allocating; MEASURED to close the gap to 3 wei in ~10 lines and 1 SLOAD) is the fairness-correct
   remedy.** P1 (refuse) also protects the tail, but it hands a live, already-executed governance
   mechanism a permanent off-switch (`PROGRESS.md`, 2026-08-26). **The panel endorses P2, and notes it
   is a fairness decision as much as a correctness one.**
3. **The single most valuable thing this project can do for the tail is finish Phase 1 correctly.** Not
   Part B. **P2 alone is worth ~33% of the tail's fee income; every mechanism in Part B is worth less
   and costs more.**

## A.5 Hard-constraint check on everything proposed below

`PROGRESS.md` / `BUSINESS.md` §8.3(D) / `PLAN.md` §E.16: **rank must be BOUGHT or HARBERGER-HELD,
never granted by deposit order.** Also binding: no off-chain component; no toxic-flow detection; no
LVR-reducing curve; no admin / upgrade / privileged role; **§E.15 — no input may be a magnitude**;
**§E.11 — no price the hook chooses**; **§B.12 — no per-block or per-epoch reference**.

| Proposal | Grants rank by deposit order? | Magnitude input? | Time/block reference? | Admin? | Verdict |
|---|---|---|---|---|---|
| **B-1 Harberger** | No — held by continuous self-assessed rent | No | Rent uses *elapsed* time, not a block/epoch boundary — **no boundary to wait for** | No (τ is an immutable, not a role) | **CLEAN** (already `PLAN.md` Phase 4) |
| **B-2 Two-sided rank** | No — both ids bought | No | No | No | **CLEAN** |
| **B-3 Fee tithe (φ on fees only)** | No | φ is a constant, not an input — **splitting is scale-invariant against a fraction** | No | φ immutable | **CLEAN** |
| **B-4 Partial front-first (whole fill)** | No | Same as B-3 | No | No | Clean but **KILLED on gas** |
| **B-5 Banded queue** | No | No | No | No | Clean but **KILLED** |
| **B-6 Rank decay / rotation** | Effectively **YES** — rank becomes free by waiting | No | **YES — fatal** | No | **KILLED** |
| **B-7 Minimum fill guarantee** | No | **YES — fatal** | Yes | No | **KILLED** |

---

# PART B — DESIGN OPTIONS

## B.0 The engineering principle that ranks all of them

> **REORDER IS FREE. RE-SPLIT IS DANGEROUS.**
>
> The allocator's proven wei-exactness (§B.5 step 5) comes from the **remainder line**: the last filled
> seat is assigned `amtIn − assignedSoFar`. **That proof is indifferent to the order of the walk.** So
> any proposal that only **permutes which seat is visited next** inherits conservation for free.
>
> Any proposal that changes **how `amtIn` is divided** puts the remainder line — the single most
> load-bearing line in the contract, whose negative control *survives swap 1 and only dies at swap 2*
> (§E.3) — back into play, and must re-prove exactness from scratch.

Order-only: **B-2, B-6.** Re-split: **B-3, B-4, B-5.** Neither (a transfer layered on top): **B-1.**
Weight this heavily. The project is at Phase 0 and the allocator is "the whole pool's accounting,
rewritten by us" (`BUSINESS.md` §9.9).

---

## B-1 · Harberger continuous rent on rank — `PLAN.md` Phase 4 · **RANKED #1 for fairness**

**Mechanism.** Each seat carries a self-declared `selfPrice` in `currency0`. Rent
`τ · selfPrice · Δt / RENT_PERIOD` accrues continuously, is deducted from the seat's own `a0`, and is
paid to **the seats behind, pro-rata by their `currency0` balance**. Anyone may buy the seat at
`selfPrice` at any time; the seat transfers **empty** (capital evacuates to the seller's
`pendingWithdraw`). If `a0` cannot cover accrued rent, the seat is **demoted to the tail** — no
collateral, no oracle, no liquidation crank.

**Does it solve fairness, or only price it?** **It prices it — and by the Fairness Theorem (A.1),
pricing it is the only available fix.** The aggregate is invariant, so the only thing that can move
value to the tail is a **transfer**, and this is the transfer. Anyone asking for a fairness fix that is
not a transfer is asking for arithmetic that does not exist.

**Who it helps:** the tail — it is the *only* proposal that gives a tail seat a **continuous income
stream with no secondary market required**. This is decisive: `BUSINESS.md` §9.7 concedes the plain
Phase-3 token has **no market and therefore no price**. Harberger produces a price **with zero bidders
present**. **Who it hurts:** the front, and any holder who stops paying attention.

**⭐ THE SIGN WORKS OUT — and this corrects `BUSINESS.md` §7.4.** §7.4 flags "a standard Harberger tax
cannot express *pay me to sit here*; under toxic flow everyone declares near-zero and no rent flows"
as an **unsolved gap**. **For the tail's fairness it is not a gap at all:**

| Regime | Front seat is | `selfPrice` | Rent to the tail | Does the tail need it? |
|---|---|---|---|---|
| Benign | valuable | high | **flows** | **YES — this is exactly the regime where the tail loses to pro-rata (A.2)** |
| Toxic | poison | ~0 | ~0 | **NO — the tail already beats pro-rata by ~37 bps (§7.3)** |

> **Harberger rent flows precisely when, and only when, the tail is the party being shortchanged.**
> §7.4's gap is a **front-seat** problem (nobody will stand at the front on a bad day), not a tail
> problem — and the front simply going empty is **graceful**: the fill walks to the next seat with
> capital and the queue self-shortens. **This materially upgrades Phase 4's case and should be recorded
> in `PLAN.md`.**

**Cost.** High. `Lease` struct; a settlement path that is **O(seats behind)** with its own exact-sum
requirement (criterion 4.2 explicitly re-imports the remainder rule); foreclosure + cursor
recomputation; buyout with an external `currency0` transfer (§E.10 bounded-copy discipline);
**10 exit criteria including reentrancy (4.10).** This is the largest single body of work left in the
plan after the allocator itself.

**HOW IT COULD BE EXPLOITED:**

1. **⚠ SELF-DEALT RENT — NEW, not in `PLAN.md`, and it partially defeats the mechanism.** Rent is paid
   to seats behind **pro-rata by `a0`**, with no notion of who owns them. A holder who owns the front
   seat **and** trailing capital **receives their own rent back**. If you control fraction `s` of the
   trailing `a0`, your effective rent rate is **`τ · (1 − s)`**, not `τ`.
   **There is no fix.** Excluding the payer's own seats requires linking addresses, and §B.12 measures
   address-shopping inside one unlock at **52,700 gas** — a rounding error against any rent worth
   dodging. A whale that buys the head *and* the two deepest seats can cut its rent by most of its
   value. **This must be disclosed, and it caps how much fairness τ can actually deliver.** It does not
   kill B-1 — a partial transfer beats no transfer — but **"the front pays the tail" is false as
   stated; the true statement is "the front pays the tail it does not own."**
2. **`selfPrice → 0` restores the free front in a thin market.** Declare zero, pay zero rent, keep the
   seat; your only exposure is being bought out at zero, which requires a bidder. **In a demo pool
   there are no bidders.** This is `BUSINESS.md` §9.7 wearing a different hat: **Harberger needs a
   market too, it just needs a much thinner one.** Honest framing: it degrades to the plain token
   rather than failing.
3. **Rent bleed in a dead pool.** With no flow, the front still pays rent — pure deadweight. Rational
   response is (2). Self-limiting, but it means rent flows **only while the seat is contested**.
4. **Foreclosure is a state-transition hazard.** Demote-to-tail mutates the ordering *and* the cursor
   invariants (`cursor0`/`cursor1` mean "every seat below holds zero"). A demotion that moves a
   **non-empty** seat below a cursor **silently skips it in every future fill** — the seat stops being
   filled and nothing reverts. **Edge Case Hunter: this is the highest-severity bug site in Phase 4.**
   Criterion 4.6 names it; make sure the test demotes a seat holding **both** tokens.
5. **Reentrancy on the buyout payout** (criterion 4.10) — a malicious `currency0` re-entering during
   the seller payout. Already specified; do not soften it.
6. **Rent-timing grief.** Rent accrues from `lastSettled`, and settlement is presumably triggered by
   *anyone*. An adversary who settles a rival's seat at a chosen moment can force foreclosure at a
   moment of their choosing (e.g. right before a large expected sweep). **Cheap. Check it.** The
   mitigation is that foreclosure is a demotion, not a seizure — but the demotion still costs the
   victim the fills they were about to receive.

---

## B-2 · Two-sided rank — separate ordering per direction · **NEW · RANKED #2**

**Mechanism.** Today one array `q` orders every fill. Instead keep **two orderings**: `order0` (the
order in which seats give up `currency0`) and `order1` (the order in which they give up `currency1`).
`PLAN.md` §B.6 **already requires two cursors** because flow is bidirectional — this generalises the
*same* insight from the cursor to the ordering itself. **Two ERC-6909 ids per seat**, independently
transferable and independently priced.

**Who it helps.** The tail, structurally: **no seat is dominated on both sides.** Being last on the
buy side is compatible with being first on the sell side. It is the **only proposal that addresses the
ratchet (A.2c)** — a seat that was swept into bad inventory can hold front rank on the *unwinding*
side and get out first. It also **doubles the objects being priced** and produces **two prices**
instead of one, which is a directly better demo: directional toxicity is real, and an event day is
one-directional by definition.

**Who it hurts.** Nobody mechanically. It halves the scarcity per object (two ids where there was one),
which is neutral-to-good for price discovery and mildly negative for the "one scarce object" pitch line.

**Cost. Low — and this is the point.** A second index array, a second `seatIndex` mapping, one extra
ERC-6909 id per seat. **Zero new gas on the hot path**: the fill still walks one array, just a different
one. **It is order-only, so by B.0 it inherits the allocator's proven conservation unchanged.** No new
storage is touched per swap.

**HOW IT COULD BE EXPLOITED:**

1. **Index mix-up — the §E.1 bug class in a new costume.** Two arrays, two cursors, two id spaces, and
   a `bool outIsOne` selecting between them. **A swapped array reference is invisible at a symmetric
   fixture** exactly as a token0/token1 swap is invisible at 1:1. **Mandatory: a test with deliberately
   asymmetric orderings** (seat A head of `order0` *and* tail of `order1`) plus a negative control that
   swaps the two arrays and asserts the specific revert. Without that, this option is a liability.
2. **Buy the head of both** — that is just plain QUEUE. No new exposure.
3. **Composition with B-1.** Foreclosure would have to demote in **both** orderings, and "the seats
   behind you" becomes ambiguous (behind on which side?). **B-1 and B-2 together is materially more
   than the sum of their parts in complexity.** If both are wanted, B-2 must land first and B-1 must be
   specified against it.
4. **A one-sided head is *not* a limit order** — the seat still trades at the swap's realised average,
   not at a chosen price. It is a *directional priority*, not a price condition. **Do not let this get
   pitched as "limit orders on Uniswap"** — that claim is false and a judge will break it in one
   question.

**Honest note:** B-2 **does not answer the owner's question.** It fixes a different, real, previously
unnamed problem (the ratchet) and it is the best originality-per-line-of-code available. It is here
because it is worth building; it is ranked below B-1 because **it moves no value to the tail.**

---

## B-3 · Fee tithe — a fraction φ of fee credit shared pro-rata · **NEW · RANKED #3**

**Mechanism.** Front-first bundles two things the tail's complaint separates: **(a) fee income** and
**(b) inventory conversion / adverse selection.** The tithe splits them. Compute the fee portion of
`amtIn` from the pool's fee (`amtIn · f / 1e6`), divert a fixed fraction **φ** of it into a pot shared
**pro-rata by every seat's `a0`**, and leave the *principal* allocation strictly front-first.
Implement as a MasterChef-style accumulator: `accPerA0 += φ·fee / totalA0`, settled **on touch** — a
seat's `a0` only changes when the allocator touches it, and it is already writing that slot.
**Result: O(1) added to the hot path**, not O(n).

**Who it helps.** The tail — a **fee floor that does not depend on being filled, and does not depend on
a secondary market existing.** In the benign regime (the one that hurts the tail, A.2) it directly
restores a φ-fraction of what the tail forgoes. **Who it hurts.** The front, exactly proportionally.

**Cost.** Medium. ~2 extra SLOAD/SSTORE per touched seat + 1 global; head-only swap plausibly
**31,874 → ~38–40k [ESTIMATE, unmeasured]**. **But it is a RE-SPLIT (B.0)**: exact conservation can no
longer come from the remainder line, because a pro-rata pot has no "last filled seat". It needs an
**explicit residual accumulator** (the same `unallocatedRent0` pattern `PLAN.md` §B.10 already accepts).
That is a second exactness proof to build and defend.

**HOW IT COULD BE EXPLOITED:**

1. **⚠ The free-riding deep tail.** A never-filled deep seat now collects φ × its pro-rata fee share
   with **~zero adverse selection**. In any pool where `L > F` — i.e. most volatile pairs, per the LVR
   literature — **that position strictly dominates pro-rata LPing.** The zero-sum identity still holds
   (it is paid for by the front), so this is a **re-pricing, not a leak**: seat prices invert and the
   tail becomes the expensive seat. **But it is uncomfortably close to the "free lane" pattern that has
   killed seven mechanisms in this repo.** It survives only because rank must be **bought** (§E.16) —
   the seat is priced, therefore not free. **φ is a subsidy dial and it will show up in the seat
   prices. Say that, do not hide it.**
2. **It re-couples the hook to the fee schedule.** Computing the fee portion means reading the pool's
   effective fee **per swap** — which walks straight back into §E.5 (protocol fee) and the `lpFee == 0`
   edge case. **Do not build B-3 until the §E.5 remedy is chosen, built and green.**
3. **Wash-trading the tithe** is a loss: you pay the whole fee and recover φ × your capital share.
   Profitable only if you own ~the whole pool, in which case it is a no-op. **Not an exploit.**
4. **φ is a load-bearing parameter**, and `PLAN.md` §B.10 already warns that a load-bearing parameter is
   where this project's pitches die. Two of them (τ and φ) is worse than one.

**Panel split — recorded honestly.** The Economic Security expert argues B-3 is **the cleanest possible
fairness fix**: it targets exactly the tail's actual complaint (fee income), leaves the adverse-selection
allocation — the actual product — untouched, and needs no market to exist. The Lead Exploit Developer
argues it **dilutes the product**: at φ=1 the front seat is pure adverse selection with zero
compensation and its price goes permanently negative, so φ is a dial from "QUEUE" to "poison the front",
and **any φ > 0 makes the headline "the head earned 100% of the fee" false**. **Both are right. B-3 is
the best mechanism here and the worst pitch here.**

---

## KILLED — with reasons

### ✖ B-4 · Partial front-first on the whole fill (φ front-first, 1−φ pro-rata)
The obvious "tunable knob between the two regimes", and it is **dead on gas**. A pro-rata leg on every
swap touches **every seat on every swap**. The measured slope is 6,753 gas/seat, so a 32-seat roster
takes the head-only case from a **flat 31,874** to **~221k on every swap** — destroying one of QUEUE's
two measured selling points and blowing the 300k budget that sets `MAX_SEATS` in the first place. The
only escape is a lazy accumulator, which is the **unbuilt, unverified B.11 O(1) redesign** whose named
reason to distrust it is that *the remainder line has no lazy analogue*. **This is a Phase-5 dependency
wearing a fairness costume. KILLED.** (B-3 is this idea restricted to the fee only, which *is*
accumulator-able. That is the salvageable half; it is already above.)

### ✖ B-5 · Tiered / banded queue (pro-rata within a band, band-first across bands)
Superficially attractive: coarser rank, more LPs per object, and small LPs could share band 1 without
the syndicate vault that §8.4 admits **recreates the intermediary QUEUE claims to remove**. **But:**
(a) pro-rata *within* a band is the exact thing QUEUE says is broken — at one band it **is** pro-rata;
(b) a head-only swap now touches every member of band 1, so the flat-gas property degrades with band
size; (c) it is a **re-split**, so the remainder line must be re-proved at band boundaries *and* within
bands; (d) the deepest band is still the tail — **it does not fix the thing it was proposed to fix**;
(e) the pitch becomes "QUEUE, but blurrier", which is strictly worse on a rubric that pays 30% for
originality. **Costs the most defensible property, buys nothing for the tail. KILLED.**

### ✖ B-6 · Rank decay / rotation (the head rotates to the tail)
**Kill it twice.**
1. **It destroys the product.** "The order IS the product" (§B.1). A rank that rotates on a schedule is
   not a durable asset; it is a lottery ticket on a cycle position, and it cannot be priced as a seat.
2. **It reintroduces a proven evasion and opens a free lane.** A rotation epoch is a **per-block or
   per-time reference**, listed in §B.12 as evaded by *waiting one block boundary — 200 ms on Unichain*.
   Worse, the schedule is deterministic and public, so a holder **deposits just before rotating to the
   front and withdraws just after rotating away** — capturing front-seat economics with none of the
   durable exposure, for **two transactions per cycle**. That is the cheapest free lane anyone has
   proposed in this repo. **KILLED. Do not revisit.**

### ✖ B-7 · Minimum fill guarantee for tail seats
**Not implementable and forbidden.** The hook does not choose the fill size — the swap does. The only
way to "guarantee" a tail fill is to allocate part of the fill out of order, which is B-4. And a
guarantee stated as "at least X per period" is a **magnitude plus a period**: the Splitting Lemma
(§E.15) defeats the magnitude for gas, and §B.12's block-boundary evasion defeats the period.
**Doubly KILLED.**

### ✖ B-8 · Distance-weighted rent (pay the deep tail more than the near tail)
A one-line variant of B-1: weight rent by `rank distance × a0` instead of `a0`. Marginal benefit, and it
creates an incentive to buy the **last** seat and sit there — which, since rent is still capital-weighted,
yields dust for dust. **Not worth a separate mechanism or a separate parameter. Folded into B-1 as a τ
note. KILLED as a standalone option.**

### ✖ B-9 · Genesis seat auction with proceeds redistributed
Considered and killed for a structural reason worth recording: **at genesis there is nobody to pay.** The
proceeds of an initial seat sale can only go to the deployer (**admin-shaped rent, §E.19**) or be burned.
`PLAN.md` §B.8 permits *"direct assignment by the deployer for the demo"* — that is fine for a hackathon
**but it is the one remaining admin-shaped thing in the design, and it must be labelled on camera**, not
discovered by a judge. **The honest alternative is to require the deployer to seed the tail seats with
their own capital.** No mechanism to build. **KILLED as an option; retained as a disclosure obligation.**

---

# PART C — SHIP / DON'T SHIP

**Rubric: 30% Original Idea · 25% Unique Execution · 20% Impact · 15% Functionality · 10% Presentation.
Binary gates: public repo, real v4 hook, new code in-window, tests **or** frontend, video under five
minutes. Phase 0 has NOT STARTED. Nothing has been built.**

### The recommendation

> **BUILD PHASES 0 → 3. BUILD NO NEW FAIRNESS MECHANISM. Ship the fairness *answer* as an argument,
> not as code.**

The Fairness Theorem (A.1) is not a limitation to apologise for — **it is the strongest thing in this
review and it is free.** "QUEUE is exactly zero-sum against pro-rata; that is measured to the cent; so
the only honest fairness fix is a transfer, and the transfer is the seat market" is a **better** answer
to a judge than any mechanism in Part B, and it costs **zero engineering days**. A panel that responds to
"is it fair?" by building a fairness mechanism has already lost the point.

**What actually moves value to the tail, in order, all of it already scoped:**

1. **P2 — net out `protocolFeesAccrued` before allocating.** ~10 lines, 1 SLOAD, MEASURED to close the
   gap to 3 wei. **Worth ~33% of the tail's fee income at max fee. This is Phase 1 and it is the single
   highest-value fairness action available.**
2. **F1 — settle withdrawals against actual holdings.** Stops the §E.4 residual being dumped on the last
   withdrawer. Phase 2, already recommended.
3. **A.3b — resolve per-seat withdrawal feasibility.** **This is a Phase 2 blocker, not a fairness
   nicety.** If a fully-converted seat cannot redeem, the product does not work and no fairness argument
   matters. **UNPROVEN — test it first, at a fully-converted seat.**

### On the top recommendation, B-1 (Harberger), honestly

**As a fairness mechanism it is correct and it is the right #1.** It is the only proposal that pays the
tail with no secondary market required, and the sign works out (the rent flows exactly in the regime
where the tail is shortchanged — §7.4's "unsolved gap" is not a tail problem). **It should stay
`PLAN.md` Phase 4.**

**As a hackathon build, do not commit to it.** Three reasons, stated bluntly:

1. **Cost.** 10 exit criteria, an O(n) exact-sum rent settlement that re-imports the remainder rule, a
   foreclosure path that can silently corrupt the cursor invariants (A.4/B-1 exploit 4), and a
   reentrancy criterion. **It is the largest remaining body of work in the plan after the allocator.**
2. **Rubric risk on its strongest axis.** §E.14 already warns that judges will pattern-match to the
   **am-AMM family**, and Harberger is the *most* pattern-matchable thing in the design — "self-assessed
   always-for-sale lease" reads as "auction" to anyone who is not listening closely, and the docs
   already instruct you not to use the word. **Phase 4 buys the least Originality per day of any work
   left.** The pro-rata-vs-queue framing is the original idea; Harberger is a governance layer on top.
3. **Newly discovered dilution.** The self-dealt-rent exploit (B-1 #1) means the effective rate is
   `τ·(1−s)`, so **the headline "the front pays the tail" is not true as stated**, and a judge who finds
   that mid-demo does more damage than not shipping Phase 4 at all.

### The gate

> **If Phase 3 is green with real time to spare, build ONE of:**
> - **B-1 (Harberger)** if the priority is answering the fairness question and closing the named
>   rank-then-run hole honestly — with the self-dealt-rent caveat disclosed; **or**
> - **B-2 (two-sided rank)** if the priority is the rubric. It is order-only, so it **inherits the
>   allocator's proven conservation for free** (B.0); it is a fraction of B-1's cost; it fixes the
>   ratchet (A.2c); and it is **genuinely novel — nothing in the 662-row directory has it.**
>
> **If Phase 3 is not green with real time to spare: build nothing new.** Ship Phase 3 + the two
> accounting fixes + the disclosures. **A more elegant mechanism that does not ship scores zero, and a
> half-built Harberger on top of an unfinished allocator scores worse than zero — it takes Functionality
> (15%) and Unique Execution (25%) down with it.**

### Disclosures the video must carry (each is a scoring *asset*, not a liability)

1. **QUEUE is exactly zero-sum against pro-rata.** Both seats cannot beat the baseline. Say the theorem.
2. **The tail's deal depends on the regime**, and the sign is the opposite of the pool's own
   profitability. **Do not show only §7.2/§7.3** — those are the two examples where the tail wins.
3. **In the plain-token variant the tail's compensation channel is a market that does not exist yet**
   (§9.7). Harberger is the answer and it is Phase 4.
4. **Rank-then-run is open in the plain-token variant** (§E.13 obligation 1 — mandatory disclosure).
5. **Exit is free and unconditional.** This is the strongest single answer to "is the tail trapped?" —
   **No. It can leave for gas.**
6. **Genesis seat allocation is deployer-assigned in the demo** (B-9). Label it.

---

## Appendix — what this review changes in the repo's own documents

| Document | Change |
|---|---|
| `PLAN.md` §B.7 | **A.3b: withdrawal of an arbitrary `(a0,a1)` is not achievable by `modifyLiquidity` alone.** Specify the reserve/netting design. **Phase 2 blocker. UNPROVEN.** |
| `PLAN.md` §B.10 / §C.4 | Add the **self-dealt-rent** exploit: effective rate is `τ·(1−s)` where `s` is the payer's share of trailing `a0`. **Unfixable — address-shopping is 52,700 gas. Disclose.** |
| `PLAN.md` §C.4 crit. 4.6 | The foreclosure test must demote a seat holding **both** tokens — a demotion below a cursor **silently stops it being filled** and nothing reverts. |
| `BUSINESS.md` §7.4 | The Harberger negative-price gap is a **front-seat** problem, **not** a tail-fairness problem. The rent's sign is correct. **This upgrades Phase 4's case.** |
| `BUSINESS.md` §7 | **Add a benign-flow worked example.** All three current examples are drawn from the regime where the tail wins. This is selection bias in the project's own evidence. |
| `PROGRESS.md` | The **P1 vs P2** open owner decision is a **fairness** decision, not only a correctness one: **the protocol fee is 100% tail-incident. P2.** |
