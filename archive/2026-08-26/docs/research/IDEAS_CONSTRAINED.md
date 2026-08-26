# IDEAS_CONSTRAINED — four candidates under the owner's 2026-08-26 hard constraints

*Written 2026-08-26 by the Lead Exploit Developer / First Principles / Economic Incentives seat.
Every prior-art count in this document was produced by a query I ran against
`docs/research/data/hook_directory_662.json` during this session; the regex is printed next to the
count so anyone can re-run it. Nothing here is quoted from a model's memory of the directory.*

**Constraints applied FIRST, before any idea was written down:** no off-chain component of any kind
(no watch-tower, relay, server, keeper network, scanner, signer); no mainnet counterparty; one hook,
one mechanism, 8 minutes to explain; robust code is a hard requirement.

---

## 0. THE STRAIGHT ANSWER, UP FRONT

**Nothing in this document beats SWITCHBACK at 3.95, honestly scored.** Best of the four is 3.85 and
it is not really a rival — it is a *replacement part* for SWITCHBACK.

The one thing in here worth the session is **§2 (BALLAST)**, and specifically the structural finding
in §2.7, which I did not expect and which changes how the SWITCHBACK wound should be read:

> **The block-boundary free lane and the reflexivity exemption are the same knob, turned in opposite
> directions.** SWITCHBACK's reference (`T0`, the pool's own tick at block open) is *safe from
> reflexivity precisely because it resets* — that is what makes the top-of-block corrective arb
> permanently exempt, which is the fact that killed the OZ stale-reference fear on 2026-08-26. It is
> *vulnerable to the cross-block unwind for exactly the same reason* — the reset is the exemption, and
> the exemption is claimable by anyone who waits 200 ms.
> **Any reference that cannot be reset by the attacker also cannot exempt the honest arb.** You cannot
> fix free lane #5 with a better reference without re-opening the reflexivity question. Every hour
> spent looking for a reference that does both is wasted; the real choice is *which of the two costs
> we accept*, and that is an owner-level decision, not a research one.

---

## 1. THE FILTER THAT PRODUCED THESE FOUR — and why the space is so thin

Before generating, I asked what signals a v4 hook can actually act on, given three facts already
proven in this repo:

- `sender` in every callback is the **router**, not the trader (`CLAUDE.md` §5.16, asserted by
  `test_Q3_senderIsTheRouterNotTheTrader`).
- `hookData` is caller-supplied and empty through every standard router.
- Value moves between addresses inside one unlock for **52,700 gas** (the ledger theorem,
  `test/spike/LedgerAddressShoppingTest`), so any inference about a counterparty is purchasable.

⇒ **No identity-based, reputation-based, allowlist-based or per-trader-refund mechanism can work.**
That is not a design preference, it is a proof, and it deletes the entire "segment good flow from bad"
lane — which is exactly why W8 has **1 entry in 662** (`Tidehook`). I looked hard for a forgeable-proof
flow signal and found none:

| Candidate signal | Why it fails |
|---|---|
| `sqrtPriceLimitX96` (visible in `SwapParams`) | Retail routers pass the sentinel; a searcher can pass the sentinel too. **Free to forge.** |
| `amountOutMinimum` / slippage budget | **The hook cannot see it at all** — it is enforced in the router *after* the last callback. |
| exact-in vs exact-out (`amountSpecified` sign) | Free to forge. |
| priority fee (`tx.gasprice − block.basefee`) | Angstrom L2 already ships this, and it is zero under private orderflow. |
| `tx.origin` / EOA-vs-contract | `sender` is the router; and forgeable. |

**What CANNOT be forged is anything that costs real money to produce.** There are exactly four such
currencies available to a hook, and every candidate below (and every candidate in our shortlist) is a
way of charging in one of them:

| Currency | Charging mechanism | Ours |
|---|---|---|
| **Price path** — you must move the price, and that costs | fee ∝ path shape | **SWITCHBACK**, **BALLAST** (§2), **SKEW** (§3) |
| **Time** — you must wait, and waiting is risk | sell immediacy | **HASTE** |
| **Liquidity** — you must post capital and bear its risk | vest fees with position age | **TENURE** (§4) |
| **Optionality** — you must pay a premium to hold a right | sell the option explicitly | **FIRM** (§5) |

That taxonomy is the most useful output of the generation pass, and it explains the thinness: it is a
closed list, and three of the four cells are already occupied by our own shortlist.

---

## 2. BALLAST — a reference price made of liquidity, not of trades

### 2.1 Mechanism sentence

> **State:** two running signed accumulators, `S1 += liquidityDelta × (tickLower+tickUpper)/2` and
> `S0 += liquidityDelta`, updated **only** in `beforeAddLiquidity` / `beforeRemoveLiquidity`, giving a
> capital-weighted **consensus tick** `C = S1/S0` in O(1) with no tick iteration; plus a `bornBlock`
> per position so that liquidity younger than `K` blocks does not count toward `C`.
> **Trigger:** every swap. The hook measures how many ticks of the swap's traversal move the price
> **toward** `C` (retracement) versus **away** (extension).
> **Settlement:** the retracing ticks are charged a fee taken from the swap's output via
> `afterSwapReturnDelta`, escrowed, and paid to aged in-range liquidity. Extension is free.

### 2.2 New tradeable object? (P5)

**No.** This is a fee-assignment rule, not an object. That is a real scoring cost — P5 says winners
create one — and it is the same cost SWITCHBACK already pays.

### 2.3 The free-lane audit

**What I searched for:** the cheapest way to make my trade read as "extension".

1. **Reset the reference by crossing a block boundary.** This is SWITCHBACK's fatal free lane #5 —
   and it is **gone**, because `C` is not derived from price at all and has no per-block reset. The
   cross-block unwind (front-run + victim in block N, unwind at the top of N+1) now moves price back
   toward `C` and is charged in full. **This is the whole reason BALLAST exists.**
2. **Move the reference instead.** To move `C` you must *add real liquidity* at a tick you choose,
   and you must leave it there for `K` blocks (the `bornBlock` gate) — during which it is in the pool
   bearing real adverse-selection risk, at a tick of your own choosing which is by construction where
   you intend to push the price. The cost is not gas, it is **capital × time × the risk of the very
   move you are engineering.** This is the first reference in any of our candidates that cannot be
   moved for a fee measured in gas.
3. **Dust-poison `C`.** `C` is *liquidity-weighted*, so a dust position moves it by
   `dustL/(dustL+totalL)` — negligible by construction. This is a real improvement on SWITCHBACK's
   dust-poison story, which needed an explicit cap to hold.
4. **The lane I could not close:** wait. `C` moves as LPs re-centre around the price, so after a
   genuine repricing `C` follows within hours. An attacker who is willing to hold a position for that
   long is no longer running MEV — they are taking directional risk. **I accept this one.**
5. **The lane that is worse than SWITCHBACK's:** see §2.7. The corrective top-of-block arb is now
   charged roughly half the time, where under SWITCHBACK it was *never* charged.

### 2.4 Attack — unlimited capital, flash loans

A flash loan can add enormous liquidity and swing `C` inside one transaction — **and the `bornBlock`
gate is exactly what defeats it**: liquidity younger than `K` blocks is excluded from `S1`/`S0`, so a
flash-loaned position contributes zero. A multi-block version requires holding real capital at a
chosen tick across `K` blocks, unhedged, in a pool that is about to move — the cost is the LVR the
attacker is trying to extract. **Mitigable, and the mitigation is one storage word per position.**

The residual: `K` is a parameter. `K` too small ⇒ cheap manipulation; `K` too large ⇒ `C` is stale and
honest LPs' capital does not count. It is one parameter with a clear failure mode in both directions —
better than SWITCHBACK's `γ`, which is a whole fee *curve* whose economics are still untested.

### 2.5 v4 feasibility against the 17 facts

- **§5.11 (`donate()` pays whoever is in range NOW):** BALLAST must use the aged-LP escrow, not
  `donate()`. Inherited from SWITCHBACK; unchanged.
- **§5.12 (positions keyed by the unlock's `msg.sender`):** `C` needs no ownership — only
  `tickLower`, `tickUpper`, `liquidityDelta`, which are in `ModifyLiquidityParams`. **`bornBlock` DOES
  need identity**, and the natural key `(sender, tickLower, tickUpper, salt)` is the router's. This is
  the one place BALLAST brushes a fact that has bitten us three times (A-1, §5.5, §5.12). It is
  survivable — the age gate is per *position slot*, and a JIT bot cannot un-age a slot by changing
  routers because the slot itself is what ages — but **it must be settled before any code is written.**
- **§5.3 / §7.4 (fail-closed can trap LPs):** BALLAST never refuses a swap, only charges. No exit trap.
- **OZ's `MemoryOOG` warning (INCUMBENTS §3):** avoided by construction — `C` is O(1) per liquidity
  event, with **no tick iteration at all**, unlike both OZ's `AntiSandwichHook` and SWITCHBACK's
  original watermarks.
- **§5.10 (test at a NON-UNIT price):** `C` is a tick, and ticks are price-ratio-native, so the
  token0/token1 unit-mixing hazard does not arise in `C` itself. It still arises in the fee settlement.
  **Test at 1:4 with a negative control anyway.**
- Router-clean: charging out of output via `afterSwapReturnDelta` is the same path SWITCHBACK was
  measured on (Q5, router-clean confirmed).

### 2.6 Prior art

- `liquidity distribution|center of mass|centroid|book shape|weighted tick|where LPs` → **0 / 662.**
  The state variable is genuinely unused in nine cohorts.
- `monotonic|ratchet|retrace|round.?trip|reversal` → **0 / 662** (same as SWITCHBACK's).
- **Nearest incumbent:** OZ `AntiSandwichHook` — floors at block-open, one direction, creates no
  cashflow, and carries the stale-reference warning that BALLAST's reference is immune to.
- **Nearest UHI project:** none on the reference; the *fee* half is SWITCHBACK's, so a judge who sees
  both sees one project, not two.

### 2.7 ⚠ THE FINDING — and it is a trade, not a fix

Read `CLAUDE.md` §8 (2026-08-26 reflexivity entry) carefully. The reason OZ's stale-reference warning
does **not** transfer to SWITCHBACK is stated there exactly:

> *"`T0` is the pool's OWN tick at block open… **the top-of-block corrective arb is NEVER taxed**,
> because the first swap of a block moves away from `T0` by construction."*

That exemption **is** the reset. Remove the reset — which is the only way to close free lane #5 — and
the corrective arb is taxed whenever it happens to move toward `C`, which is roughly half the time.
**BALLAST closes the 82.6%-profitable cross-block unwind and re-opens the reflexivity question that
was closed six hours ago.** I am not going to pretend that is a strict improvement. It is a swap of
one known cost for another, and the simulation that settles it is a re-run of
`docs/research/data/switchback_reflexivity.py` with `T0` replaced by a liquidity-centroid reference —
**one afternoon, and it is the highest-value experiment left on the board**, ahead of the fee curve.

### 2.8 Scores

| Criterion | Wt | Score | One blunt sentence |
|---|---|---|---|
| Original Idea | 30% | **3.5** | The reference is new (0/662) and genuinely clever; the fee mechanism is SWITCHBACK's, and a judge scores the pair once. |
| Unique Execution | 25% | **4.0** | O(1) capital-weighted reference with no tick iteration is a real engineering answer to the hazard OZ ships a warning about. |
| Impact | 20% | **4.0** | It closes the one hole that currently makes SWITCHBACK 82.6% profitable to attack on our target chain. |
| Functionality | 15% | **4.0** | Two accumulators and a `bornBlock`; the risky part is the age-key, not the math. |
| Presentation | 10% | **4.0** | *"Our reference price is made of liquidity, not of trades — you can't move it with gas, only with capital."* |
| **Weighted** | | **3.85** | Below the standing pick as a standalone. As a *part of* SWITCHBACK it raises it. |

---

## 3. SKEW — the pool quotes two-sided, and the offsetting trade is paid

### 3.1 Mechanism sentence

> **State:** a per-pool signed flow accumulator `F` (net signed notional, exponentially decayed per
> block) and a self-funded escrow `E`.
> **Trigger:** every swap. A swap on the same side as `F` (the side that keeps hitting the pool) pays a
> surcharge `s(|F|)` taken from output; a swap on the opposite side receives a **rebate** `r(|F|)`
> paid as *extra* output out of `E`.
> **Settlement:** surcharge → `E` and LPs; rebate ≤ `E`; hard invariant `r(|F|) < s(|F|)` for all `F`,
> so a round trip through both sides is never profitable and `E` can never be drained.

### 3.2 New tradeable object? **No.**

### 3.3 The free-lane audit

1. **Split the flow across two directions to keep `F` near zero.** To hold `F` down you must sell
   nearly as much as you buy — i.e. hold no position — which is the same as not doing the trade.
   Costs real spread. **Closed.**
2. **Farm the rebate.** A searcher trades the offsetting side purely to collect `r`. This is the
   intended behaviour (it restores balance) and it is bounded: `r < s` and `r ≤ E` make the round trip
   strictly loss-making and the escrow non-drainable. **This is a provable arithmetic invariant, and it
   is the single strongest thing about SKEW — the safety property is a theorem, not a simulation.**
3. **The lane I could not close, and it is the killer:** the rebate is paid as extra output, which
   means **an honest one-way trader arriving on the offsetting side is paid, and an honest one-way
   trader arriving on the persistent side is charged, with no relationship whatsoever to whether either
   is informed.** On a trending pair, *every* honest trader on the trend side pays. This is exactly the
   inversion that killed Hardcap, arriving through the flow accumulator instead of the block reset.

### 3.4 Attack

Unlimited capital makes this worse, not better: a whale can hold `F` pinned to one side for as long as
they like, forcing every counterparty to pay the maximum surcharge while the whale collects the rebate
on their own unwind. Bounded by `r < s`, so not profitable in isolation — but combined with a real
directional view it is a subsidy to the largest participant. **Mitigable, not clean.**

### 3.5 v4 feasibility

Router-clean in both directions — a *rebate* is extra output, which never trips `amountOutMinimum` (a
useful fact: `afterSwapReturnDelta` can pay the swapper more, and unlike a NoOp'd zero-output swap
(§5, proven to revert through `V4Router`) this is always safe). No fact violated.

### 3.6 Prior art — **this is where SKEW dies**

- `nezlobin|directional fee|toxicity fee|order flow imbalance` → **8 / 662, 2 prized.** The surcharge
  half is literally the **Nezlobin directional fee**, which is *taught in the curriculum* and appears
  under its own name three times in the directory.
- **`EvenFlow` (UHI8, prized)**, verbatim: *"an oracle-free directional-toxicity fee … escrows the
  toxicity premium during adverse flow and drips it back to in-range LPs once the market goes quiet."*
  That is state + trigger + escrow + settlement, and it is 80% of SKEW.
- `skew|inventory|rebate|negative fee` → 10/662 incl. `Gated Trade Rebate Hook` (UHI7) and
  `SafeSwap — LVR rebate for LPs` (UHI9).
- **I am killing this myself.** The only new part is "pay the offsetting side out of a self-funded
  escrow with `r < s`", and that is a paragraph, not a submission. It fails the delete test: delete the
  rebate and you have EvenFlow.

### 3.7 Scores

Original **2.5** (Nezlobin + EvenFlow) · Unique Execution **3.5** (the `r<s` invariant is genuinely
provable) · Impact **3.0** · Functionality **4.0** · Presentation **3.5** ⇒ **weighted 3.10. KILLED.**

---

## 4. TENURE — fees vest with position age, and unvested fees are paid to liquidity that was actually there

### 4.1 Mechanism sentence

> **State:** `bornBlock` per position slot; a per-(tickRange, epoch) escrow accumulator.
> **Trigger:** every swap's LP fee is intercepted by the hook instead of accruing natively.
> **Settlement:** a position's share vests linearly from 0 at `bornBlock` to 1 at `bornBlock + K`; the
> unvested remainder is escrowed **tagged with the tick range and block in which it was earned**, and
> is claimable only by positions that were (a) in range **at that time** and (b) already aged. Never
> `donate()`.

### 4.2 New tradeable object? **Weak** — an aged-LP escrow claim. It is an accounting entry, not a
market. Same objection that demoted Assay (`CLAUDE.md` §8: *"an attestation, not a tradeable object"*).

### 4.3 The free-lane audit

1. **OZ's own documented bypass** (`LiquidityPenaltyHook` NatSpec, verbatim): *"bypass JIT protection
   by using a secondary account to add minimal liquidity at a target tick with no other liquidity, then
   moving the price there after a JIT attack… penalty fees [are] redirected to the attacker's secondary
   account."* **TENURE closes this by construction** — the escrow remembers *which range and which
   block* the fee came from, so a dust position at an empty tick is paid nothing unless it was in range
   when the fee was earned, and to be in range at that moment it must bear real risk. This is the one
   candidate here that beats a shipped OpenZeppelin hook at a hole OpenZeppelin wrote down itself.
2. **Age a dust position, then JIT with it.** The vesting weight is `liquidity × vestedFraction`, so an
   aged dust position earns dust. **Closed.**
3. **Add early, remove late, repeat around predictable flow.** Real; requires holding through `K`
   blocks of price risk. **Accepted — that is the mechanism working.**
4. **The lane I could not close:** the position-slot key is the router's address (§5.12). Two traders
   using the same router share a slot unless `salt` separates them, and `salt` is caller-chosen. A JIT
   bot running its own periphery controls its own slot, so ageing is honest for *it*; the risk is that
   an ordinary LP's slot is polluted by another user of the same router. **This must be settled by
   execution before any TENURE code is written; it is A-1 / §5.5 / §5.12 for the fourth time.**

### 4.4 Attack

Flash loans are useless — vesting is measured in blocks, and a flash-loaned position vests at zero.
This is the most flash-loan-resistant candidate on the board. **Not fatal.**

### 4.5 v4 feasibility

Brushes **§5.11** (must never call `donate()` — that is the point), **§5.12** (the position key,
above), **§5.3** (must NOT block exits — an LP forfeiting unvested fees is fine, trapping principal is
not), and the `beforeAddLiquidity` return-type fact (we only observe there; the charge is on the swap).

### 4.6 Prior art — respectable but not original

`jit|just.?in.?time` → **21 / 662, 5 prized.** `sentry` (UHI7): *"taxes short-lived liquidity positions
on an exponential decay curve (65% at t=0, near 0% after ~1.7 hours) and redistributes."* `ParityTax`
(UHI5/6, twice): *"progressive tax based on the time an LP leaves their liquidity."* And OZ ships
`LiquidityPenaltyHook` in the library judges compare us to. **The idea is not new. The correct
settlement is.** That is a 3, not a 4.

### 4.7 Scores

Original **3.0** · Unique Execution **4.0** · Impact **3.5** · Functionality **4.5** (by far the most
buildable and the most testable — and the only candidate whose headline demo is *a third-party
contract failing*, satisfying `CLAUDE.md` §9's "never demo only against straw men") · Presentation
**4.0** ⇒ **weighted 3.68.**

**Verdict: the safest thing on this page and the least interesting. Do not submit it. Its escrow design
is, however, the correct implementation of SWITCHBACK's recapture leg, which `IDEAS_FROM_GROK` §4.2
records as "not implementable as written".**

---

## 5. FIRM — the pool sells the option it currently gives away

### 5.1 Mechanism sentence

> **State:** an outstanding-convexity accumulator `C_out` and a premium curve `p(C_out)` that **rises
> with each sale and decays per block** — no volatility model, no oracle, no parameter fitting beyond a
> floor.
> **Trigger:** anyone calls `buyQuote(direction, size, tenor)` on the hook, pays `p` in the input
> token; the premium is settled straight into the pool as LP revenue and the hook mints a transferable
> ERC-6909 **firm quote** (strike = current tick, expiry = `block + tenor`, size).
> **Settlement:** the holder calls `exercise(id)`; the hook opens its own `poolManager.unlock()` and
> fills at the strike, bounded by the declared size; unexercised quotes expire and the premium stays
> with the LPs.

### 5.2 New tradeable object? **YES — and it is the only one on this page.**

A transferable, short-dated forward on the pool's own price, written by the pool, priced by demand.
`forward|firm quote|lock.?in price|price lock|guaranteed price` → **1 / 662** (`UniCast`, and it is an
event-driven fee hook, not this).

### 5.3 The thesis, which is the best sentence I produced today

> **An LP is short a straddle and gives it away for free. Every LVR paper says so. Nobody has made the
> pool sell it.** Every existing answer (Angstrom, am-AMM, all 55 LVR-auction submissions) *auctions*
> the option to one winner per block. FIRM *posts a price* for it, continuously, in any size and tenor,
> to anyone — which needs no bidders, no off-chain auctioneer and no block-time coordination.

### 5.4 The free-lane audit — and it is fatal for the theme, not for the design

1. **Manipulate the premium down, buy cheap convexity.** Closed by construction: the premium is set by
   *purchases*, not by a measured volatility, so the only way to lower it is to not buy.
2. **Buy at the floor.** The floor is the one parameter and it is the whole risk — an underpriced floor
   is free convexity, bounded only by the per-period notional cap. Same shape of exposure as
   SWITCHBACK's `γ`, and no easier to set.
3. **Flash-loan the exercise.** Exercising at the strike and dumping into the same pool is a round trip
   through your own price impact; there is no single-transaction profit. **Closed.**
4. **⚠ THE LANE THAT KILLS IT: don't buy.** Ask who actually buys a firm quote. **The LVR arbitrageur
   never does** — he trades on information he has *now*, at the stale price that is on the screen. FIRM
   sells convexity to people with a *view about the future*, which is a legitimate and interesting
   product and is **not the party extracting from LPs.** It does not capture LVR, does not deter a
   sandwich, and does not price the intra-block path. **This is a new derivatives primitive wearing an
   MEV-protection label, and a judge holding the theme slide will notice within the first minute.**

### 5.5 Attack

Buy the maximum notional at the floor across many quiet blocks, wait for a real move, exercise
everything. Loss to LPs is bounded by the notional cap; the cap is what makes it safe and also what
makes the revenue small. **Mitigable, but the mitigation caps the upside.**

### 5.6 v4 feasibility

- The purchase and the exercise are **non-callback external functions on the hook** — the A-10
  extraction channel (`CLAUDE.md` §8), which is *unfixable by inheritance*. If we ever dogfood Assay on
  a hook with this shape, that channel is open by design and must be disclosed.
- The exercise goes through the hook's own unlock, **not** through a router — which is what makes it
  work at all, because §5.16 means the hook could never authenticate an ERC-6909 holder arriving
  through a router (`sender` is the router).
- Solvency: outstanding notional must be bounded by pool liquidity or an exercise reverts and the
  "firm" quote is not firm. That is a hard invariant and it is where the robustness risk lives.

### 5.7 Prior art — worse than it looks

`option|premium|straddle|convexity|implied vol|panoptic|covered call` → **49 / 662, 15 prized.** In
particular **`Voltaire` (UHI8, prized)**: *"turns any ETH/USDC liquidity pool into a fully on-chain
European options market"*, and **`OpSwap` (UHI6, prized)**: *"American Options created Just in Time…
users can swap for tokenized exercisable options."* Also `Lumis` (UHI1, prized). The *thesis* is
different from all three — they build an options market *on* a pool, FIRM makes the pool internalise
its own written option — but "options hook" is a lane with 15 prizes in it, and the distinction is one
sentence deep.

### 5.8 Scores

Original **4.0** (the thesis is genuinely strong and the demand-priced premium removes the usual
on-chain-options failure mode) · Unique Execution **4.0** · Impact **3.0** · Functionality **2.0**
(an options book with a solvency invariant, in 8 weeks, under a hard robustness requirement — this is
the one candidate I think we would fail to finish) · Presentation **4.0** ⇒ **weighted 3.50.**

**Verdict: the most interesting idea here and the wrong hackathon for it. Off-theme *and* the highest
build risk is the combination the owner's criterion #3 explicitly refuses to license.**

---

## 6. KILLED BY MY OWN AUDIT — eight, with the reason, so nobody re-derives them

| # | Idea | Killed by |
|---|---|---|
| K1 | **Atomic-cycle detector** — in `beforeSwap`, read the locker's `exttload` delta in the *output* currency; a pre-existing debt there means this swap is closing a leg opened earlier in the same transaction, i.e. an atomic arb. | **The ledger theorem, with an in-repo PoC.** `PoolManager.swap()` is `onlyWhenUnlocked`, not `onlyLocker` — leg 2 runs from a second address inside the same unlock for **52,700 gas** (`test/spike/LedgerAddressShoppingTest`). Fractions of a cent on Unichain. |
| K2 | **In-unlock RFQ** — custody the swap, offer it to bonded on-chain fillers before the curve; read each filler's ledger via `exttload` (case (c) of the theorem holds!). | **Last look is an option, and we are in the business of not giving options away.** A filler declines exactly when the trade is worth sandwiching. Bonding does not help: refusing to quote is not a slashable offence. This is Kyber's exclusive-taker cage rebuilt with the searcher inside it. |
| K3 | **Capture the slippage budget** — fill every swap at the trader's own declared limit and pay the difference to LPs, so the sandwich has no prize left on the table. | Killed **twice**: (a) the hook **cannot see `amountOutMinimum`** — it is router-level, checked after the last callback; `sqrtPriceLimitX96` is the sentinel through every standard router. (b) Even if it could, every user with a default 0.5% router setting silently pays 0.5% on every trade. |
| K4 | **Volume-Dutch toll** — the first `V₀` of notional in a block pays `f_max`, decaying to `f_min`; a posted price for top-of-block instead of an auction. Splitting-proof (decay is in volume, not swap count). | **On a quiet pool, every honest trade is the first trade of its block.** SWITCHBACK's disclosed 44.6% honest-payer problem, at 100%. Hardcap's inversion with a Dutch clock. |
| K5 | **Term liquidity** — LPs commit for N blocks, receive a tradeable term bond, and get a senior claim on fees; a yield curve for AMM depth. | Prior art: `Cleave` (UHI9) *"Pendle, but for liquidity"*, `Sentry` (UHI7), `ParityTax`, `Mochi Yield` (UHI9, prized), `TrancheHook`. 37/662 on `term\|maturity\|lockup\|duration`. And it has **neither defense nor recapture**. |
| K6 | **Sibling-pool consensus** — one hook over two fee tiers of the same pair; the inter-pool dislocation is an unforgeable arb signal (faking it means moving the other pool). | **The dominant LVR arb moves both pools in the same direction**, so the gap never opens and the signal never fires. Also halves depth and makes "which pool is right" undecidable. |
| K7 | **Healing liquidity** — a fee proportional to price impact, settled as *new liquidity minted across the exact ticks the trade crossed*, so the pool thickens where it was cut. | **Economically inverted.** Deeper liquidity at the ticks that get crossed means *more* inventory exposed exactly where the picking-off happens. LVR rises with depth. Hardcap's disease with a nicer story. |
| K8 | **Quote withdrawal** — hook-owned positions that deactivate when the price breaks out of a recent range, like a real MM pulling quotes on news. | Cheap to grief (push X ticks in a thin pool ⇒ the pool has no liquidity ⇒ nobody can trade), and prior art in the auto-widening lane (`OscillonHook`, `Mantua.AI`, `Novara`). |

Also considered and folded rather than listed: the **block-extreme ratchet** (within a block, never
fill better than the block's running extreme; surplus to LPs). It is **SWITCHBACK at γ→∞** — no
parameter to justify, recapture equal to the exact round-trip profit — but it is the *same family*,
it has the *same* block-boundary reset, and it charges honest two-sided flow strictly more. It is a
variant to test, not a candidate to score.

---

## 7. SCOREBOARD

| | Original 30% | Unique Exec 25% | Impact 20% | Functionality 15% | Presentation 10% | **Weighted** |
|---|---:|---:|---:|---:|---:|---:|
| **SWITCHBACK** (standing) | 3.5 | 4.0 | 4.0 | 4.5 | 4.0 | **3.95** |
| **BALLAST** §2 | 3.5 | 4.0 | 4.0 | 4.0 | 4.0 | **3.85** |
| **TENURE** §4 | 3.0 | 4.0 | 3.5 | 4.5 | 4.0 | **3.68** |
| **FIRM** §5 | 4.0 | 4.0 | 3.0 | 2.0 | 4.0 | **3.50** |
| **SKEW** §3 | 2.5 | 3.5 | 3.0 | 4.0 | 3.5 | **3.10** |

---

## 8. WHAT I WOULD ACTUALLY DO

1. **Do not switch.** `CLAUDE.md` §3 says a switch is justified only by a candidate materially better
   on theme fit + novelty. None of these is better on *either*, let alone both.
2. **Run the BALLAST reference through `switchback_reflexivity.py`.** Replace `T0` with the
   liquidity-centroid reference and re-run all four vol regimes. One afternoon. It answers the only
   open question that matters: whether we accept the 82.6%-profitable cross-block unwind, or accept
   taxing the corrective arb. **These are the same knob (§2.7) and we must choose one.**
3. **Take TENURE's escrow accounting into SWITCHBACK** as the recapture leg — tagged by tick range and
   block, never `donate()`. It closes OZ's own documented bypass and gives us the one demo in this
   whole project that runs against third-party code rather than a straw man we wrote.
4. **Settle the position-slot key (§5.12) by execution before writing either.** It has now bitten this
   repo four times (A-1, §5.5, §5.12, and both §2.5 and §4.3 above). It is the single highest-frequency
   defect class in our history and we keep discovering it late.
5. **Publish the §1 table.** *"There is no forgeable-proof flow-segmentation signal available to a v4
   hook, and here are the five candidates and why each fails"* is a genuine, counted, checkable
   finding, it explains why W8 has 1 entry in 662, and it costs us nothing — it is a blog post, not a
   submission.

**Bottom line for the owner: nothing here beats the standing pick. The interesting output of this pass
is not a fifth candidate, it is the discovery that SWITCHBACK's remaining wound cannot be fixed by
finding a better reference — because the property that makes a reference safe from staleness is the
same property that makes it resettable. That is a decision to take, not a bug to fix.**
