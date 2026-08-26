# IDEAS_FROM_PERPLEXITY — archaeology of `docs/research/perp_chat.md`

*Written 2026-08-26. Source: the owner's Perplexity session, 508 lines, two prompts (one open
"what's missing in the ecosystem, ideally security", one "what wins a Sustainable-Liquidity-and-MEV
hackathon"). Every prior-art count below was produced by a regex I ran against
`docs/research/data/hook_directory_662.json` in this session; the regex is printed next to the count.
Every v4 mechanic below was checked against source in `lib/` or against a recorded in-repo proof —
nothing is quoted from a model's memory.*

---

## 0. THE STRAIGHT ANSWER, UP FRONT

**There is no 4.5 in this transcript, and it is the weakest of the three model transcripts this
project has mined.** Numbers:

- **22 distinct ideas.** **9 of them (41%) have an off-chain component as their *product*** — a CLI,
  a web UI, a dashboard, a simulator, a signing agent. The owner's no-off-chain constraint deletes
  them before any analysis. `SECURITY_LANDSCAPE.md` deletes them a second time (0 prizes from 9
  hook-safety projects across 8 cohorts; Hacken's `uni-v4-hooks-checker` already occupies the
  endorsed slot).
- **0 NEW-WORTH-EVALUATING.** Every on-chain idea in the transcript is already triaged in
  `IDEAS_FROM_GROK.md`, already saturated in the directory, or has a live incumbent.
- **Best honestly-scored thing I could build out of it: 3.2**, below the standing 3.95.

**But the pass is not empty.** Pushing three of its seeds to their strongest form produced two things
worth keeping, and both are *deletions*, which is what this project has repeatedly found is worth
more than another candidate:

1. **THE SPLITTING LEMMA (§3.2)** — a one-sentence rule that retires **six** transcript ideas at
   once and belongs in `CLAUDE.md` §5 as fact #18.
2. **The fill-warranty family is dead twice over, and the second reason is decisive and new (§3.1)**
   — you cannot pay the trader at all. Not "it drains", not "it pays ordinary impact": the hook never
   sees the recipient. This also *retroactively justifies* SWITCHBACK's donate-to-LPs design as the
   only option rather than a choice, which is worth saying on camera.
3. A **free positioning upgrade for SWITCHBACK (§5)** — the verifiable-sequencing-rule frame — that
   answers the "you reinvented Angstrom's intra-block rule" objection at zero engineering cost.

---

## 1. INVENTORY — every distinct idea in the transcript

### Prompt 1 — "what's missing in the ecosystem, ideally security" (L1–L332)

| # | Idea | Lines |
|---|---|---|
| P1 | **Hook Wizard & Template Library** — web UI + CLI generating audit-ready hooks with permissions, buckets, invariants baked in | L8–L43 |
| P2 | **Static-analysis + threat-modelling toolkit** — extend HookScan / Zealynx Krait; permission-bit checks, `onlyPoolManager` enforcement, delta/bucket dataflow, donation-griefing detection | L45–L80 |
| P3 | **Hook Risk Registry + on-chain security score (HookRank++)** — off-chain index + on-chain oracle contract routers read to avoid risky hooks | L82–L127 |
| P4 | **Permissioned-Pools compliance DSL + policy orchestrator** — rules→allowlist-checker codegen, 7-step onboarding UX, multi-hop leakage harness | L129–L164 |
| P5 | **DualPool risk simulator & config assistant** — model ERC-4626 APY vs fees, stress vault pause/outage, suggest ranges | L166–L197 |
| P6 | **Production-grade median price oracle hook** — running/approximate median, per-block move bounds, standard interface for other hooks | L199–L228 |
| P7 | **IL-hedge hook (Makemake v2)** — buy OTM calls on Lyra at `beforeAddLiquidity`, unwind at `beforeRemoveLiquidity` | L230–L259 |
| P8 | **MEV-safety hook *library*** — Magna Carta-style verifiable sequencing rules + Arb-Controller dynamic fee + JIT guardrails, packaged | L261–L290 |
| P9 | **Hook dev & attack-simulation playground** — local PoolManager, scripted Cork-style attacks, delta visualisation | L292–L321 |

### Prompt 2 — "what wins this hackathon" (L334–L509)

| # | Idea | Lines |
|---|---|---|
| P10 | **LP-friendly dynamic fee + anti-sandwich suite** — fee on price impact + volatility; max-impact cap; min time between trades; **fee equalisation across LPs** | L358–L379 |
| P11 | **Agentic MEV-capture manager hook** — hook checks for a profitable arb vs a reference market, performs the arb leg itself, donates proceeds to LPs; optional off-chain signing agent | L380–L405 |
| P12 | **JIT + rehypothecation "regenerative liquidity"** — pull from ERC-4626 just in time, rebuild position, re-vault; guardrails = max JIT size per address, min lock time, short-life surtax | L406–L431 |
| P13 | **MEV-safe TWAMM / batch-auction hook** — slice a committed large order per block, impact thresholds, anti-sandwich delay per slice | L432–L457 |
| P14 | **Small-LP protector & detox hook** — fee/reward curve favouring small, long-tenure LPs; launch-snipe filter; attacker-punish / victim-refund | L458–L479 |
| P15 | **MEV-aware liquidity rebalancer** — move ranges on realized vol + observed arb frequency | L480–L499 |

### Sub-ideas asserted in passing, extracted separately because several are the actual load-bearing part

| # | Sub-idea | Lines |
|---|---|---|
| S1 | Anti-sandwich **minimum time between trades / no same-origin follow-up** | L360, L374, L452 |
| S2 | **Max price impact per trade**, enforced in `beforeSwap` | L360, L374, L440 |
| S3 | **Fee equalisation across LP positions** so toxic flow doesn't selectively enrich some positions | L360 |
| S4 | **Victim fee refunds / attacker punishment** | L356, L466 |
| S5 | **`donate()` captured arb profit to LPs** | L396 |
| S6 | **`aroundSwap` callback** | L394 |
| S7 | **Bound how far one block/trade may move a price output** | L213 |

---

## 2. TRIAGE

Counts are mine, regex printed. `n` = matching rows of 662; `p` = of those, rows carrying ≥1 prize.

### OFF-CHAIN PRODUCT — deleted by the owner's constraint before any other analysis (9)

| # | Verdict |
|---|---|
| P1 Hook Wizard | **DEAD ×3.** (a) It is a web UI + CLI, not a hook — fails Gate 3 ("a real v4 hook, or a direct interface to one"). (b) `SECURITY_LANDSCAPE.md`: Uniswap's own framework already names **OZ `uniswap-hooks` + the Uniswap Hooks Contract Wizard** — the transcript itself concedes this at L13 and then proposes building it anyway. (c) `wizard\|codegen\|template librar` → n=1 (`UniHaas`), p=0. |
| P2 Static-analysis toolkit | **DEAD.** This is `AssaySuite` and Hacken's `uni-v4-hooks-checker` (7 stars, already in Uniswap's endorsed Security Resources list). `static analys\|slither\|linter\|scanner` → **n=0** in 662 — and §5.13 applies: 0 matches here means the road was deliberately not built. 0-for-9 on hook-safety projects. |
| P3 HookRank++ | **DEAD.** Off-chain index; and the on-chain half is `AssayRegistry`, which this repo already built, audited (A-3: `bond()` is permissionless and the 256-entry scan window is push-past-able) and decided not to submit. `registry\|scoring\|rank\|rating` → n=34, p=4, incl. **`Hook Safety As A Service`** — one of the nine that won nothing. |
| P4 Compliance DSL | **DEAD by proof, not by taste.** `CLAUDE.md` §5.16: a v4 hook cannot bind an allowlist to the party that receives the tokens. Uniswap Labs hit the same wall and shipped a **forked router + forked posm** plus the token's own ERC-3643 restrictions; their hook is the redundant half. A DSL that compiles rules into that hook compiles rules into the redundant half. 72/662 in the lane, off-theme. |
| P5 DualPool simulator | **DEAD.** Off-chain simulator. And see §4.4 — DualPool is real but holds **~$411 of TVL across four dust instances**. |
| P9 Attack playground | **DEAD.** Off-chain; and it is `test/spike/` with a frontend. |
| P8 "MEV-safety *library*" | **DEAD as packaged.** A library of patterns is not one hook with one mechanism, and "understandable in 8 minutes" fails on a suite. Its one genuinely interesting component (verifiable sequencing rules) is developed in §3.1. |
| P7 IL-hedge via Lyra | **DEAD + SATURATED.** Needs an external options venue as a live counterparty (not off-chain, but a mainnet dependency, and Lyra is not on our chain). `option` → n=37, **p=12**; IL/hedging lane = 81/662 and it was **UHI9's theme — freshly exhausted** (`WINNERS_LANDSCAPE` §2 rank 5). |
| P11's off-chain agent half | **DEAD** by constraint. The on-chain half is triaged below. |

### ALREADY-KILLED — with the kill already recorded in this repo (6)

| # | Killed by |
|---|---|
| **P11** (hook performs the arb leg itself, donates to LPs) | **`IDEAS_FROM_GROK` B16**, killed twice: a hook that pays out of its own inventory "is no longer a queue — it is a market maker… needs inventory, a quoting rule and a hedging policy, and it re-opens the free-option problem in a worse form." And **`IDEAS_FROM_GROK` B12**: with a start-of-block reference there is nothing to skim (the value never left the pool); with an *oracle* reference you have reintroduced the oracle dependency. Plus **§5.11**: `donate()` pays whoever is in range NOW — a JIT position minted in the same tx harvests the donation. |
| **P10 / S4** (victim refunds, attacker punishment) | **`IDEAS_FROM_GROK` B18 (fill warranty)**: *"worse than start-of-block price is true of roughly every second swap in a block, not of victims — the pot pays ordinary price impact and drains without deterring anything."* **And a second, decisive reason this repo had not stated: §5.16 — the hook never sees the recipient.** Developed in §3.1. |
| **S1** (min time between trades / no same-origin follow-up) | **The ledger theorem** (`test/spike/LedgerAddressShoppingTest`): value moves between addresses inside one unlock for **52,700 gas**; and `sender` is the router (§5.16), so "same origin" is the router for every honest user and is address-shoppable for the attacker. Also the **splitting lemma**, §3.2. |
| **S3** (fee equalisation across LPs) | **§5.12**, unresolved and load-bearing: `PoolManager` keys positions by the unlock's `msg.sender` — usually posm, not the LP. Every position added through the canonical position manager presents to the hook as **the same address**. There is nothing to equalise *between* without shipping your own periphery. |
| **P12's guardrails** (max JIT size per address, min lock time) | Max-size-per-address: **splitting lemma (§3.2) + address shopping.** Min lock time: this is OZ `LiquidityPenaltyHook` / `sentry` (UHI7) / `ParityTax` — and §5.11 records OZ's *own NatSpec* documenting the bypass. |
| **P13** (TWAMM / batch slices) | `twamm` → **n=10, p=0. Ten submissions, zero prizes, nine cohorts.** And the deferred-fill path is already scoped: a NoOp'd swap returning zero output **reverts through the standard router** (proven by execution, `IDEAS_MECHANISM` SPIKE Q1). |

### SATURATED (5)

| # | Count |
|---|---|
| P6 median oracle | Oracle/TWAP lane = **108/662, p=25** (`WINNERS_LANDSCAPE` §2 rank 4). `median` alone → n=0, but that is a naming artefact: truncated/geomean/volatility oracles all exist. Off-theme for UHI10 besides. |
| P10 dynamic fee | **189/662 — 29% of everything, the #1 dead lane.** *"Do not submit a dynamic fee hook."* |
| P12 rehypothecation | `rehypothec\|idle capital\|aave\|morpho\|euler` → **n=29, p=10**; `4626` → n=14. OZ `uniswap-hooks` **already ships a `ReHypothecation` hook.** |
| P14 anti-snipe half | `snipe\|anti-snip` → n=6, p=1; broader launchpad lane 37/662, p=13. Off-theme. |
| P15 rebalancer | Auto-rebalancing LP = **40/662, p=8**, and it is taught in the curriculum (JiT Rebalancing). `OscillonHook`, `Mantua.AI`, `Novara` occupy the auto-widening variant. |

### INCUMBENT-EXISTS (4)

| # | Incumbent |
|---|---|
| P8 / verifiable sequencing (Magna Carta) | **Umbra Research sr-AMM** (published) and **Angstrom** (live v4 hook on Base + Unichain) both enforce the intra-block rule. See `INCUMBENTS.md` §2–§3. |
| P10 anti-sandwich | **OZ `AntiSandwichHook` v1.2.0** — free, in the library Uniswap's own framework names first. Note §4.3 of `IDEAS_FROM_GROK`: it protects **exactly one swap direction**. |
| P12 JIT-from-vault | **`DualPoolHook`, live on Ethereum mainnet**, `0x00000078bd49d5279a99b5f4011a5c61ee8caac0`, 23,999 bytes, OZ-audited. Exactly the transcript's architecture, already shipped by Uniswap. |
| P4 permissioned pools | **`PermissionedHooks`, live on mainnet**, `0x499a724Ab630549f14C995EC41a8E04fA3fd28c0`, 3 audits. |

### NEW-BUT-BAD (2)

| # | One-line reason |
|---|---|
| **S2** max price impact per trade | The only enforcement a hook has is `revert`. A pool that reverts large swaps is a pool aggregators route around, and the cap is defeated by splitting (§3.2) at ~zero cost on Unichain. `circuit break\|price band\|rate.?limit\|max.{0,6}impact` → **n=6, p=0**. |
| **S7** bound per-block price movement | Same. It is S2 with a block counter, and it inherits the block-boundary reset (free lane #5): 200 ms on Unichain. |

### NEW-WORTH-EVALUATING (0)

**Zero. I looked hard and I am not going to manufacture one to fill the row.**

---

## 3. GENERATION — three seeds pushed past where the transcript stopped

The brief was to push the best seeds to a 5/5, not to triage. I took the three seeds with the most
unexplored kernel: **P8's verifiable sequencing rules**, **P10/S3's fee equalisation**, and
**P12's JIT guardrails**. Here is where each actually lands.

### 3.1 PUSH A — **PARITY**: the strongest on-chain form of a verifiable sequencing rule

**Where the transcript stops.** "Sequencing constraints inspired by Magna Carta" (L272). One line, no
mechanism. That is the adjective, not the mechanism (§5.15).

**Where I pushed it.** The academic object behind Magna Carta is the **Greedy Sequencing Rule**
(Ferreira & Parkes): a block is valid only if every user transaction receives a price at least as
good as it would have received *first in the block*. Nobody has enforced a GSR inside the AMM itself
— every published version enforces it on the *proposer*, which needs a slashing venue and an
off-chain prover. The pool can enforce it on itself, with no proposer involvement at all:

> **Mechanism sentence.** *State:* `blockOpenSqrtPrice` (one slot, lazily initialised on the first
> swap of a block) plus a per-block escrow balance held as ERC-6909. *Trigger:* every swap. The hook
> computes the counterfactual output the swap would have received against the curve **at
> `blockOpenSqrtPrice`**. *Settlement:* if the actual output is **better** than the counterfactual,
> the surplus is confiscated via `afterSwapReturnDelta` into the escrow; if it is **worse**, the
> deficit is paid to the swapper out of the escrow, capped at the escrow balance; whatever is left
> at the first swap of block N+1 is donated to liquidity that was in range at block open.

That is strictly more than sr-AMM/Angstrom, which are **one-sided**: they refuse to let you do
*better* than block-open, so the sandwich earns nothing, but the victim is still worse off than they
would have been alone. PARITY is **two-sided and self-financing**: in a sandwich, the back-run's
confiscated surplus is, to first order, exactly the victim's deficit. *"The attacker funds the
victim's refund, in the same block, from the same pool, with no oracle and no auction"* is a genuinely
better sentence than anything in this repo's shortlist.

**New tradeable object?** The escrow claim, as ERC-6909. **Weak** — it is an accounting entry with no
secondary market, the same weakness `TENURE` had (`IDEAS_CONSTRAINED` §4.2). Does not satisfy P5.

**FREE-LANE AUDIT — and it is fatal, in three independent places.**

1. **The compensation lane is a subsidy to arbitrage, not a defence.** If every swap is filled at
   block-open price, the CEX-DEX arb splits its trade into N pieces and captures the entire
   inter-block price displacement **at the stale price with zero price impact** — it pays the
   block-open price instead of the curve integral. Extraction is then bounded only by depth. This is
   **Hardcap's economic inversion rebuilt with a clock** (§6): the behaviour the mechanism exists to
   deter becomes the cheapest available action. Capping compensation at the escrow balance bounds the
   damage but does not remove the lane — a patient attacker drains the escrow every block.
2. **The ordering problem makes same-block compensation impossible anyway.** The victim swaps
   *before* the back-run, so the escrow that is supposed to pay them does not exist yet. Paying
   forward requires identifying the victim in a later transaction.
3. **⚠ AND THAT IS WHERE IT DIES OUTRIGHT, FOR A REASON THIS REPO HAD NOT STATED: THE HOOK CANNOT PAY
   THE TRADER AT ALL.** `CLAUDE.md` §5.16 — `sender` in every callback is the **router**, `hookData`
   is caller-supplied and empty through every standard router, and the hook **never sees the
   recipient**; the router calls `poolManager.take(currency, recipient, amt)` *after* the hook's last
   callback. A hook returning a positive `afterSwapReturnDelta` credits **the router**, not the
   person who swapped. For the Universal Router that value flows on to the recipient by accident of
   its accounting, but the hook has no way to *bind* it, and against a hostile or custom router the
   "refund" is simply a gift to the router. **Any mechanism whose settlement path ends at "and we pay
   the trader" is not implementable as a v4 hook.**

**The attack** (unlimited capital, flash loans): flash-loan to maximum depth, split into N swaps in
the arb direction, collect the whole block-open-priced fill; on the next block, repeat. No bond, no
identity, nothing to slash.

**Prior art — and it kills the idea by itself.** `IDEAS_FROM_GROK` **B18, "fill warranty"**, already
proposed and already killed with the cleaner argument: *"worse than start-of-block price is true of
roughly every second swap in a block, not of victims — the pot pays ordinary price impact and drains
without deterring anything."* Directory: `batch\|uniform.?price\|clearing` → n=10, p=2. Off-directory:
**Umbra sr-AMM** and **Angstrom**, both named in `INCUMBENTS.md`.

**Honest score.** Original 3 · Unique Execution 3 · Impact 2 · Functionality 2 · Presentation 4 =
**2.75.** Below SWITCHBACK by more than a point.

**What survives, and it is worth more than the idea was.** The §5.16 argument is **general and new to
this repo's stated form**, and it has two consequences we should bank:

- It retires an entire family in one line: fill warranties, victim refunds, trader rebates,
  loyalty discounts, per-swapper anything. Six transcript sub-ideas (S4, P10, P14, and the refund
  halves of P11/P13/P15) die on it simultaneously.
- **It retroactively converts SWITCHBACK's donate-to-LPs settlement from a design choice into the
  only available option.** That is a strong thing to say on camera when a judge asks "why don't you
  give it back to the victim?" — the answer is *"because no v4 hook can, and here is the line of
  `PoolManager` that proves it."*

### 3.2 PUSH B — the seeds that key on *size*, and **THE SPLITTING LEMMA**

**Where the transcript stops.** Five separate ideas quietly assume the hook can act on **how big
something is**: max price impact per trade (S2), max JIT position size per address (P12), fee
curves favouring **small** LPs (P14), min time between trades (S1), per-block price-move bounds (S7).

**Where I pushed it.** I tried to build the strongest member of that family — a **concave fee split**,
where a position's fee rate per unit of liquidity *decreases* in its size, on the theory that
adverse-selection liquidity (JIT, and the LVR arb's own hedge) is necessarily large because it must
clear gas and wants capital efficiency, so concavity is an unforgeable proxy for toxicity that never
needs to identify anybody. It is the most attractive idea in this transcript and I wanted it to work.

**It does not, and neither does any of the other five, for one reason:**

> **THE SPLITTING LEMMA.** *A mechanism whose input is a **size** is defeated by splitting the
> quantity into k parts, at a cost of (k−1) × marginal gas. On Unichain that cost is fractions of a
> cent. Therefore no v4 hook mechanism may key on a per-swap, per-position, or per-address
> **magnitude** unless the charge is a **path integral with no per-unit threshold**, in which case it
> is charging the path, not the size — and then the size was never the input.*

This is the same shape as the ledger theorem (52,700 gas to move value between addresses) and the
same shape as SWITCHBACK's own §2.4(b) defence ("defeated by construction *if and only if* the fee is
a path integral over retraced ticks with no per-swap threshold"). It has been used implicitly three
times in this repo and never written down. **It should be `CLAUDE.md` §5 fact #18.** It kills, in one
sentence and without further analysis: S1, S2, S7, P12's size caps, P14's concave split, and K4 from
`IDEAS_CONSTRAINED` §6.

Corollary worth stating separately, because it explains a directory count nobody had explained:
`circuit break\|price band\|rate.?limit\|max.{0,6}impact` → **n=6, p=0** and
`markout\|realized (pnl|profit)\|profit.?shar` → **n=0 of 662**. Both lanes are empty *and* unrewarded
because both key on a magnitude, and the whole ecosystem has been paying gas to find that out one
project at a time.

**Honest score for the best member of the family (concave fee split):** Original 3 · Unique Execution
2 · Impact 1 · Functionality 2 · Presentation 3 = **2.15.** Dead.

### 3.3 PUSH C — P12 (JIT + rehypothecation) pushed to its strongest form, and where it lands

**Where the transcript stops.** "Pull from an ERC-4626 vault just in time, rebuild the position,
re-vault, with guardrails." That is `DualPoolHook`, live on mainnet, OZ-audited, plus three
guardrails that die to the splitting lemma.

**Where I pushed it.** Drop the guardrails and take the architecture seriously. If inventory is
materialised **only at swap time**, the hook chooses *how much depth to build* on each swap. That is
a real, unexploited degree of freedom, and it points at the one honest form: **make depth a
decreasing function of how far the price has already been pushed away from the block-open tick.** A
searcher who wants to move the price finds the pool getting thinner as they push; a trader arriving
after a correction finds it thick.

**And that is SWITCHBACK, expressed in depth instead of in fee.** Same state (`blockOpenTick`), same
trigger (distance from it), same settlement economics, and — decisively — the **same block-boundary
free lane**: the reference resets at block open, so the attacker extends in block N and unwinds at the
top of block N+1 where the tick has re-anchored, paying nothing. That is **free lane #5**, already
measured: still-profitable 27.9% in-block → **82.6% cross-block**, break-even race-win probability
**1.9%**, and on Unichain the wait is **200 ms**.

**This is the substantive generative finding of the pass and it is a negative one:** the
JIT/inventory framing is not an alternative mechanism family. It is a change of *unit* — charging in
depth rather than in basis points — over the same state. It inherits every wound of the price-path
family and adds two of its own: a vault dependency whose availability an attacker can manipulate, and
`DualPoolHook` as a live, audited, Uniswap-authored incumbent.

**Honest score:** Original 3 · Unique Execution 3 · Impact 3 · Functionality 3 · Presentation 3 =
**3.0**, and it is a strictly worse SWITCHBACK.

---

## 4. FACT-CHECK OF THE TRANSCRIPT

Contradictions first, since those are the high-value items.

### 4.1 ⚠ **`aroundSwap` does not exist.** (L394)

The transcript proposes implementing P11 "in `aroundSwap` or `beforeSwap`". Checked against primary
source, `lib/uniswap-hooks/lib/v4-core/src/interfaces/IHooks.sol`. The complete callback set is:

```
beforeInitialize  afterInitialize
beforeAddLiquidity  afterAddLiquidity
beforeRemoveLiquidity  afterRemoveLiquidity
beforeSwap  afterSwap
beforeDonate  afterDonate
```

**There are ten callbacks and `aroundSwap` is not one of them.** This matters beyond the typo: the
idea it is attached to (the hook wrapping the swap so it can arb "around" it) is exactly the shape
v4 does *not* give you — the hook gets two discrete callbacks with the swap executed between them by
`PoolManager`, and `beforeSwap`'s view of the outcome is a forecast, not a fact.

### 4.2 ⚠ **`donate()` cannot pay "LPs" in the sense the transcript means.** (L396, L498)

Two ideas (P11, P15) settle by donating captured value "back to LPs". `CLAUDE.md` §5.11, verified in
this repo: **`poolManager.donate()` pays whoever is in range NOW.** There is no primitive that pays
the liquidity present when the value was extracted. OZ's own `LiquidityPenaltyHook` NatSpec documents
the bypass — dust from a second account at an empty tick, push price there, collect your own donation.
Any "donate the arb profit to LPs" mechanism is a **self-payment** for the price of gas.

### 4.3 ⚠ **"Anti-sandwich delay: no same-origin follow-up trade" cannot be implemented.** (L360, L452)

`sender` in every callback is the **router** — asserted by execution in this repo
(`test_Q3_senderIsTheRouterNotTheTrader`). Every honest user of the Universal Router shares one
"origin" from the hook's point of view; the attacker uses two addresses at a cost the ledger theorem
measured at **52,700 gas**. The rule punishes exactly the users it means to protect and nobody else.

### 4.4 ◐ **"DualPool, live as of July 2026" is TRUE but the framing is wrong, and the TVL is $411.** (L166–L197)

Verified in `RWA_PERMISSIONED_POOLS.md` against Uniswap's own repos and on-chain state:
`DualPoolHook` is real (`v4-hooks-public/src/alf/DualPoolHook.sol`, ported 2026-07-18/21, OZ-audited),
live at `0x00000078bd49d5279a99b5f4011a5c61ee8caac0`, 23,999 bytes. **But** it is the ALF reference
strategy for a **market maker**, not "idle yield for LPs" — ordinary pool liquidity is **zero between
swaps** and routers must discover capacity through `IALFHook` views. And **its TVL is ~$411 across
four dust instances**, against $150M sitting in plain v4. Two siblings were withdrawn on 2026-07-27.
**Building a simulator, or a defence, for a $411 hook is not an Impact story.**

### 4.5 ◐ **"Permissioned Pools, July 2026, audited and deployed" is TRUE — and it is the strongest evidence *against* P4.** (L134)

Announced 2026-07-23, merged to `v4-periphery/main`, 3 audits (Cantina + 2× OpenZeppelin), deployed
at `0x499a724Ab630549f14C995EC41a8E04fA3fd28c0` (6,909 bytes, perms `0x28C0`). The transcript reads
"deployed but no production pools yet" as *opportunity*. It is the opposite: **zero adapters have ever
been created** (verified by `eth_getLogs` on hook + factory with a PoolManager positive control), and
the reason is structural — the load-bearing parts of Uniswap's own design are a **forked router** and
**the token's own ERC-3643 restrictions**. Neither is a hook. A DSL that generates the hook generates
the redundant half.

### 4.6 ◐ Load-bearing and **UNVERIFIED** — do not build on any of these

| Claim | Status |
|---|---|
| "A 2025 **SEC comment letter** proposes a Hook-based On-Chain Policy Orchestration Architecture with a Hook Manager" (L134) | **UNVERIFIED.** This is the entire justification for P4 and no citation is given beyond "the SEC input". Treat as hallucinated until a URL is produced. |
| "**HookRank** tracks TVL/volume/success-rate for hundreds of hooks and has a user base" (L87) | **UNVERIFIED.** Appears in no source in `docs/research/`. `SECURITY_LANDSCAPE.md` catalogued the adjacent graveyard (hookrisk, hookguard, HookVault, v4-hooks-analyzer, v4-hook-invariants, aegis) — all 0–5 stars. |
| "**HookScan**" (Composable Security) and "**Krait**" (Zealynx) (L47, L50) | **UNVERIFIED** as products. The one tool this project *did* verify in the endorsed slot is **Hacken `uni-v4-hooks-checker` — 7 GitHub stars.** That is the ceiling of demand in this lane. |
| "**Sentinel Agent**: AMM LPs lose **5–7% annually** to LVR; its Manager Hook uses flash accounting to intercept MEV" (L386) | **UNVERIFIED number, unverified project.** The repo's own LVR modelling (`switchback_reflexivity.py`) works in σ²V/8 terms and lands at **0.2–0.4%** of volume, which is not comparable to a 5–7%-of-capital figure. Do not quote 5–7% anywhere. |
| "Cork ~$12M, Cork + Bunni > $20M, and these are hook-side bugs" (L6, L127) | **PLAUSIBLE, uncited.** But the inference drawn from it — *"which creates a strong demand for better hook patterns and tooling"* — is **contradicted by counted evidence**: nine hook-safety-infrastructure projects across eight cohorts won **zero** prizes, and there is no security track. Losses create demand for **audits**, and the Foundation is already paying **$1.2M to Areta** for exactly that. |
| "Uniswap Foundation **hook data standards** / standard hook events" (L31, L313) | **UNVERIFIED.** No such standard is referenced in any primary source this project has read. |

### 4.7 What the transcript gets right — worth recording, since §4 is otherwise negative

- **The theme statement is accurate**, and its three named design axes (durable liquidity / clear MEV
  story / auditable-composable) match the organizers' framing.
- **L339's observation that Uniswap's own Hook Design Lab pushes JIT, dynamic fees and
  rehypothecation is correct** — and it is a *warning*, not an opportunity: those three are
  respectively 20, 189 and 29 submissions deep in the directory.
- **P8's instinct that verifiable sequencing rules are the most interesting under-used academic
  object in this space is, in my judgement, correct** — it is just that the incumbents (sr-AMM,
  Angstrom) already occupy it and the pool-enforced version collapses (§3.1).
- **It correctly names the two brand-new Uniswap primitives** (Permissioned Pools, DualPool) that
  post-date the entire 662-row directory. `dualpool\|dual pool` → **n=0 of 662**. That is a real
  observation; it is just that both are worth **$411 and $0** respectively, and §4.4/§4.5 explain why.

---

## 5. THE ONE DELIVERABLE THAT IS WORTH TAKING FORWARD

Not a candidate. A free upgrade to the standing candidate, extracted from P8.

`IDEAS_MECHANISM` §2.5 records SWITCHBACK's live objection and refuses to score around it:

> *"you reinvented Angstrom's intra-block rule with a fee" is a live objection and it caps
> Originality at 3, not 4. I refuse to score it 4.*

The verifiable-sequencing-rule frame answers that objection precisely, and it costs nothing to adopt:

> **sr-AMM and Angstrom enforce a sequencing rule as a *binary constraint* — you may not do better
> than the block-open price, and violations are simply refused. SWITCHBACK *prices* the violation on
> a continuous curve and routes the price to LPs. A rule gives you defence. A price gives you defence
> **and** recapture, and it is the only one of the two a pool can enforce on itself with three
> storage slots and no proposer, no node network, and no off-chain prover.**

That is one paragraph, it is true, it is checkable, and it is aimed at exactly the judge who knows the
prior art. Pair it with §3.1's §5.16 result — *"and we cannot refund the victim, because no v4 hook
can see the recipient; here is the line of `PoolManager` that proves it"* — and the two hardest
questions in the Q&A both have prepared, evidence-backed answers.

**Recommended additions to `CLAUDE.md` §5:**
- **#18, the splitting lemma** (§3.2 above).
- **#19** — extend §5.16: a hook cannot *pay* the trader either, only the router. Any settlement path
  ending at "and we refund the swapper" is not implementable. (§3.1)

---

## 6. STRAIGHT ANSWER

**No. There is no genuine 4.5 in this transcript, and I am not going to dress a 3.0 up as one.**

The reason is structural, and it is the same one the last three passes hit from three different
directions. Under the owner's constraints, a v4 hook mechanism must key on one of exactly four
unforgeable currencies — **price path, time, liquidity, optionality** (`IDEAS_CONSTRAINED` §1) — and
its input must survive four proven evasions:

| Evasion | Measured cost | Kills |
|---|---|---|
| Splitting a quantity | ~gas, fractions of a cent on Unichain | every size-keyed idea (§3.2) |
| Address shopping inside one unlock | **52,700 gas** | every identity-, reputation-, or history-keyed idea |
| Waiting one block boundary | **200 ms** on Unichain | every idea anchored on a per-block reference |
| The router opacity wall (§5.16) | free — it is structural | every idea that must see, gate, or pay the trader |

**Every one of the 22 ideas in this transcript keys on size, identity, history, the trader, or an
off-chain component.** That is not a failure of the model; it is the shape of the space, and the
transcript never had the four facts above, so it could not have known. What it produced is a clean
census of the ideas that *look* obvious to a well-read outsider — which is itself useful, because it
is a good proxy for what the other 100–160 UHI10 teams are about to build.

**Do not switch. Build SWITCHBACK.** Take §5's positioning paragraph and the two new §5 facts, and
spend nothing further on this transcript.

---

## PROVENANCE

- **Source mined:** `docs/research/perp_chat.md`, 508 lines, read in full.
- **Directory queries:** all counts produced in-session against
  `docs/research/data/hook_directory_662.json` (662 rows); regexes printed inline.
- **Primary-source checks run in-session:** callback set read from
  `lib/uniswap-hooks/lib/v4-core/src/interfaces/IHooks.sol` (§4.1); `grep -ril aroundSwap lib src` → 0.
- **Repo facts reused, not re-derived:** `CLAUDE.md` §5.4, §5.11, §5.12, §5.13, §5.15, §5.16, §5.17
  and §6; `IDEAS_MECHANISM` §2 + SPIKE Q1; `IDEAS_CONSTRAINED` §1, §2.7, §6; `IDEAS_FROM_GROK`
  B12/B16/B18 and §4.3; `SECURITY_LANDSCAPE` §3.1; `RWA_PERMISSIONED_POOLS` §DualPool +
  §PermissionedHooks; `INCUMBENTS` §2–§3; `WINNERS_LANDSCAPE` §2–§4.
- **Not fetched:** nothing. No network access was used; every external claim in the transcript is
  marked VERIFIED against an existing repo artifact or **UNVERIFIED** in §4.6.
