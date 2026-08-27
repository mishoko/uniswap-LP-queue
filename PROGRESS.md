# PROGRESS.md — the project's memory

**Update this at the end of every working session. This file, `PLAN.md` and `AGENTS.md` are the
handoff. If those three do not tell the next person what to do, the handoff failed.**

Newest entry first. Never delete an entry — supersede it.

---

## Status board

| Phase | Name | Status | Proven? |
|---|---|---|---|
| 0 | Harness + reproduce the reference spike | **NOT STARTED** | — |
| 1 | Allocator core | NOT STARTED | — |
| 2 | Deposit / withdraw + redemption-dust fix | NOT STARTED | — |
| 3 | ERC-6909 rank token + transfer | NOT STARTED | — |
| 4 | Harberger rent variant | NOT STARTED | — |
| 5 | Gas + scale (O(1) prefix-sum redesign) | NOT STARTED | — |
| 6 | Adversarial + invariant campaign | NOT STARTED | — |
| 7 | Testnet deploy + demo + video | NOT STARTED | — |

*(Phase definitions, entry/exit criteria and acceptance tests are in `PLAN.md` §C and §D.)*

**Verified 2026-08-26 (doc-audit):** every row above is still accurate — **no `src/` directory exists
at the repo root** and no mechanism code has been written. The two 2026-08-26 sessions below produced
research and documents only. `PITFALLS.md` §5 is the standing list of what is open.

---

## Carried forward from the design phase — what is ALREADY PROVEN

These were established by executed experiments before the build started. **Do not re-derive them.**
Evidence lives in `archive/2026-08-26/`.

| Claim | Status | Evidence |
|---|---|---|
| Front-first allocation at the swap's realised average price is **exact to the wei in both tokens at a non-unit price (1:4)** | **PROVEN** | `archive/2026-08-26/test/spike/QueueAllocator.t.sol`, 9 tests; conservation measured on PoolManager's own ERC20 balances |
| The remainder-assignment line is load-bearing | **PROVEN** | Negative control: floor-only mutation survives swap 1 and dies at swap 2 |
| Pro-rata allocation and an off-by-one cursor both break it | **PROVEN** | Two further negative controls, both red, revert reasons asserted |
| Head-only swap gas is **flat at ~31,874** regardless of queue depth | **MEASURED** (with `vm.cool()`) | Spike §Q2 |
| A sweeping swap is O(entries) at **~6,753 gas/entry**; ~44 seats at a 300k budget | **MEASURED** | Spike §Q2 |
| A **~0.26 wei/swap** redemption residual exists; the last withdrawer eats it | **MEASURED** | Spike §Q1 |
| That residual is **NOT** fee-growth truncation | **FALSIFIED** by a zero-fee pool retaining 88% of the drift | Spike §Q1 |
| The residual is **unfarmable** — cost-to-damage off by ~20 orders of magnitude | **REASONED from measurement** | Spike §Q1 |
| No forgeable-proof toxicity signal exists for a v4 hook | **PROVEN** | `archive/2026-08-26/docs/research/IDEAS_CONSTRAINED.md` §1 |
| No static curve can improve adverse selection per unit of depth | **PROVEN** | `archive/2026-08-26/docs/research/IDEAS_CURVES.md` §0 |
| A v4 hook can never see or pay the trader | **PROVEN** | `archive/2026-08-26/CLAUDE.md` §5 items 16 and 18 *(root `CLAUDE.md` is a symlink to `AGENTS.md` and has no §5.16 — the old citation was unfollowable)*; `PITFALLS.md` §1.14, §4.3 |

## Carried forward — what is OPEN

**`PITFALLS.md` §5 is the authoritative list of open hazards** — it is longer than this table and
each row carries its evidence grade. The rows below are the headline items and point into it.

| Item | Why it matters | Where | Ledger row |
|---|---|---|---|
| **Redemption dust fix** | Until built, *"the queue's face value is redeemable"* must not be claimed | `PLAN.md` Phase 2 | `PITFALLS.md` §5.7 |
| **Per-seat withdrawal feasibility** | **MEASURED:** §B.7's withdraw spec is impossible as specified — seat 1 holds 258.877 token0 / 0 token1 and can withdraw nothing via `modifyLiquidity(−Δ)`. A **Phase 2 BLOCKER**, and the second reason the face-value claim is barred. `withdraw` must never call `poolManager.swap` | `PLAN.md` §B.7 (not yet corrected); `docs/research/protocol-fee/queue-exposure.md` §A2 | `PITFALLS.md` §5.5, §5.6 |
| **Protocol fee remedy P2** *(was P1 — superseded)* | Hazard is MEASURED and real. **Owner decided 2026-08-26: ship P2** (net out `protocolFeesAccrued` in `_afterSwap`), **not** the refusal this row previously named. Phase 1 must build it and assert against `PoolManager balance − protocolFeesAccrued` / `redeemAll()`, having first asserted `protocolFeesAccrued > 0` | `PLAN.md` §E.5, Phase 1 acceptance 1.10 | `PITFALLS.md` §3.1, §5.1–§5.4 |
| **LAW 3 is amended** | Conservation must net out `protocolFeesAccrued`; the raw-balance form is blind to this bug class. Now stated in `AGENTS.md` §3.3 **and** `PLAN.md` §D.1 LAW 3 | `docs/research/protocol-fee/experiment.md` | `PITFALLS.md` §2.6 |
| **Rank-then-run hole** | Plain-token rank can be abandoned before a scheduled event; only the Harberger variant closes it — and Harberger has its own unsolved gap (it cannot express a negative seat value) | `PLAN.md` Phase 4 | `PITFALLS.md` §5.9, §5.10 |
| **O(1) prefix-sum redesign** | Named but **unbuilt and unverified** — do not quote it as a property | `PLAN.md` Phase 5 | `PITFALLS.md` §5.12, §3.16 |
| **Seat governance** | Rank must be bought or Harberger-held, **never granted by deposit order** (dust-griefing the head). Phase 2's append-at-tail is provisional and must carry a named known-hole test | `BUSINESS.md` §8; `PLAN.md` §B.8, §E.16 | `PITFALLS.md` §3.8, §5.8 |
| **Theme framing** | The honest bridge to "Sustainable Liquidity and MEV Protection" is the weakest part of the pitch | `BUSINESS.md` §10 | `PITFALLS.md` §5.16 |
| **Full-range capital efficiency** | The sharpest unanswered attack, and **absent from `BUSINESS.md` and `PLAN.md` entirely**. [ANALYSIS] | `docs/research/premise-review/economics.md` §6 | `PITFALLS.md` §5.17 |
| **The Ratchet · the one-sided Phase 3 market · "the seat price IS the toxicity" is overclaimed** | Three pitch-level contradictions named nowhere in the live docs. [ANALYSIS] | `docs/research/premise-review/` | `PITFALLS.md` §5.18, §5.19, §5.20 |
| **Proposal 100 / live protocol fees** | Press-sourced only. **UNVERIFIED** — check on-chain before relying on it | `docs/research/protocol-fee/v4-mechanics.md` §9 | `PITFALLS.md` §5.15 |
| **Standing pitfalls ledger** | Every hazard, testing trap, settled decision and proven-impossible item, with its evidence status — **re-read at the start of every session**. §7 lists where two docs disagree | `PITFALLS.md` | — |

---

## Session log

### 2026-08-26 (session close, final) — P2 + float COMPOSE; but P2's IMPLEMENTATION is DEFECTIVE

Ran while the harness was warm, to close the last untested composition before any build.
Evidence: `docs/research/withdrawal/fee-float-composition.md` + `FeeFloatComposition.t.sol` —
**19 tests, re-run independently by the orchestrator, 19/19 green.**

**GOOD NEWS — the two designs compose. INVARIANT F survives a MAXIMUM protocol fee:**
residual **0 wei** in the balance form, **3–8 wei** against raw ledger — *the same bounds the fee-off
suite already reports*. **The residual does NOT scale with the fee:** the fixture accrued 3.54e17 /
2.0e16 wei of protocol fee — ~17 orders of magnitude above the residual — and the residual did not
move. Dust policy unchanged by the fee. Withdrawal does **not** accrue protocol fees (`test_P4`,
verified in source, not assumed).

**⚠️ BAD NEWS — a CRITICAL defect in P2 itself, and it is a PHASE 1 BLOCKER.**
`poolManager.protocolFeesAccrued(currency)` is **GLOBAL PER CURRENCY, not per pool**
(`ProtocolFees.sol:21` — `mapping(Currency currency => uint256 amount)`, no `PoolId` anywhere).
So the diff `pfNow − pfSeen` **absorbs the protocol fees of every other v4 pool sharing either
currency.** Float-independent; it would have hit Phase 1 in production.

- **X1 — silent under-credit (the EVERYDAY case).** A second pool on the same pair (fee tier 500)
  took 2e15 wei of token0 protocol fee. QUEUE's next swap computed `pfDelta` =
  301999999999999999 instead of its own 299999999999999999 and **under-credited the queue by
  exactly the foreign pool's fee (2e15 wei)** — stranded in the position, owed to nobody.
  **No attacker needed:** ordinary volume on any other pool of the same token does this continuously.
- **X2 — PERMANENT BRICK (the tail case).** If foreign accrual since our last swap exceeds the next
  swap's input, `amtIn -= pfDelta` **underflows inside `afterSwap`** and the swap reverts
  (`Panic(0x11)` in v4's `WrappedError`). **And it is permanent** — the failed swap never advances
  `pfSeen`, so every later swap recomputes the same oversized delta. **The pool is dead.** The
  attacker needs only one other pool sharing the currency with a nonzero protocol fee — the normal
  state for any listed token — and one swap on it.
- `pfSeen0/1` start at **0** at construction, so a currency already carrying accrued fees
  **bricks or mis-credits the hook's FIRST EVER swap.**

**HOW THIS GOT PAST US — record it, it is the project's own doctrine biting.** The `test_M3`
mutation that "MEASURED P2 closing the gap to 3 wei" ran in a **single-pool fixture**. The mechanism
was never wrong about *what* to subtract; the **instrument for measuring it** was wrong, and the
fixture could not see it. **A green test in a fixture with only one pool proved nothing about a
global counter.** LAW 5 territory: the pass was the harness, not the code.

**WHAT STANDS AND WHAT DOES NOT:**
- ✅ **The DECISION stands** — net out the protocol fee so the ledger credits only what the position
  received. P1 (refuse) is still rejected for the Proposal-100 reason.
- ❌ **The MECHANISM does not.** Do NOT ship `pfNow − pfSeen` on the global counter.
- **Follow-up REQUIRED before Phase 1, and it is NOT easy — it needs its own experiment and its own
  negative control.** Derive the protocol fee arithmetically from the swap rather than diffing a
  global counter, but note: `lpFee == 0` takes the ENTIRE `feeAmount` by a different formula
  (PITFALLS §1.5); exact-out rounds the other way (§1.12); and `amountToProtocol` is summed
  **per swap step** with per-step rounding across tick crossings — so a one-line
  `amtIn * pf / 1e6` will **not** be wei-exact. **Clamping `pfDelta` to a locally-derived upper
  bound removes the BRICK but not the UNDER-CREDIT.**

**Negative controls held:** NC-1 (netting removed, fee on) went RED with INVARIANT F slack
`−353999999999999999` / `−20000000000000000` — **exactly `protocolFeesAccrued`, asserted with
`assertEq`** — and the last withdrawer reverting `FloatShort` short 354000000000000003 wei, i.e.
4.4e16× the 8-wei bound. NC-2 (fee = 0 + float) reproduced the 22-test float suite exactly.

### 2026-08-26 (session close) — HAZARD 5.5 SETTLED: per-seat withdrawal is FEASIBLE

**The one finding that could have killed the product is closed.** Run in-session rather than deferred,
because the resolution changes Phase 1's state layout. Evidence:
`docs/research/withdrawal/feasibility.md` + `FloatWithdraw.t.sol` — **22 tests, re-run independently
by the orchestrator, 22/22 green**, including 8 negative controls, 2 attack tests, an asymmetric-
decimals (18/6) case and conservation under LAW 3 AS AMENDED.

**VERDICT: FEASIBLE-WITH-CAVEATS.** A **two-slot shared float** lets `withdraw()` pay any seat its
exact ledger composition — including a **100%-converted seat** — with **no `poolManager.swap`**, in
any withdrawal order, at 1:4 and at 18/6 decimals, **zero conservation slack, 252,672 gas cold**.

**INVARIANT F (PROVEN) — the fact that makes it work:**
`Σ q[i].a0 == redeemable token0 + float0`, likewise token1, to within the §E.4 residual (≤8 wei).
The aggregate is consistent; only the **per-seat composition** is unpayable from a proportional
liquidity removal. That is why a shared float is sound and first-come-first-served payment is safe.

**⚠️ THE ORIGINAL PROBE WAS READING THE WRONG NUMBER — correct the record.** The apparent 1.062e18
"gap" was `LiquidityAmounts.getAmountsForLiquidity`, which returns **principal only** and does not
know about accrued LP fees. Cross-check, exact to the wei: gap on token0 = 1062000000000000003 vs
LP fee earned = 1062000000000000000 = **0.30% × 354e18**; token1 gap 60000000000000003 vs
60000000000000000 = 0.30% × 20e18. **There was never an aggregate shortfall.** The per-seat
composition problem was real; the solvency scare was an artefact of measuring principal.

**STATE TO ADD — this is what had to be known before Phase 1 (PLAN §B.3):**
```solidity
uint256 internal float0;   // token0 held OUTSIDE the position, owed to the queue
uint256 internal float1;   // token1 held OUTSIDE the position, owed to the queue
```
Plus two corrections: **(a) `withdraw` MUST decrement `liquidity` by Δ** — §B.7 never does, and every
later sizing computation is wrong without it. **(b) INVARIANT F must sit next to the declarations in
§B.3.** `pendingWithdraw0/1` is unrelated and does not serve this purpose.

**THE ALLOCATOR IS UNCHANGED — PROVEN.** `_allocate` is character-for-character the spike's
FRONT_FIRST path. The float touches **withdraw** only, and is structurally *safer* for the allocator.
⇒ **Phase 1 is unblocked and its arithmetic is unaffected.**

**NEW OPEN ITEM, and the biggest gap in this result: `sweepFloatIntoPosition()` is REQUIRED and
UNBUILT.** Permissionless, no privileged role: re-add `Δ' = min(float0/f0, float1/f1)` of liquidity,
credit nobody, decrement both floats by actual consumed amounts. **Without it, pool depth degrades
monotonically as seats withdraw imbalanced legs.** UNPROVEN — not written, not tested.

**OWNER DECISION NEEDED (AGENTS.md §4 — it changes who gets what):** on deposit, §B.7 says *"refund
any unconsumed remainder to msg.sender"*. Under a float the better answer is to **absorb the
remainder into `floatX` and credit it to the seat** — cheaper, and it reduces the float. Not built,
not tested. **Ask before implementing.**

**Dust policy — choose F1.** Measured both branches: exact payout ⇒ the last withdrawer **reverts
`FloatShort`, short 3 wei** (NC-F); F1 (`pay min(face, available)`) ⇒ everyone drains, 3–8 wei of
ledger dust unpaid. **The float does NOT solve §E.4** — orthogonal, still open, and *"face value is
redeemable"* still must not be claimed.

**Still UNTESTED:** protocol fee ≠ 0 interacting with the float (everything above ran at
`protocolFeesAccrued == 0`, asserted — the amended LAW 3 form is used but inert); the
sandwich-the-withdrawal sizing attack (REASONED only); `lpFee == 0`; deposit-side float absorption.

### 2026-08-26 (later still) — PREMISE REVIEW: the mechanism is SOUND; two sharper holes found

**Owner asked:** is the hook fair, does the niche make sense, would deploying it be embarrassing.
**Answer: the premise holds, front-first is defensible, and the real risks are elsewhere.**
Full reasoning: `docs/research/premise-review/economics.md`, `.../fairness.md`. Ledger: `PITFALLS.md`.

**1. The orchestrator's own attack on the premise was REFUTED — record it so it is not re-litigated.**
The attack: *"a CLOB seat is valuable because you can CANCEL; QUEUE cannot cancel or detect toxic flow,
so the front seat eats adverse selection and rank is worth negative."* **Wrong, for a precise reason:
a CLOB order rests at a FIXED price; a QUEUE seat has no price of its own.** Every seat filled by a
swap is filled at that swap's realised average price (`PLAN.md:503`) — front and tail get IDENTICAL
execution, only quantities differ. There is no stale quote, so there is nothing to cancel. Front-of-
queue buys **priority over QUANTITY, not priority at a stale PRICE.** [REASONED, confidence HIGH]

**2. The leverage identity — write it into BUSINESS.md, it is the answer to "why buy a seat".**
`L(s) = (C/c1) * min(1, c1/s)`. The front seat is levered on everything, and **most levered on SMALL
swaps** (decaying as `C/s` above head size). BUSINESS.md's own two worked examples (§7.1 = 50x,
§7.3 = 3.34x) are special cases of this formula — **the doc never wrote the formula down.**
⇒ **QUEUE is a LEVERAGE instrument on the pool's own LP return**, bounded downside per trend,
unbounded round-trip upside. This is a better and more defensible pitch than "the seat price is the
toxicity", which is **overclaimed** (it measures leverage x LP return — computable from public swap
data — and Harberger censors the signal at zero on exactly the toxic side).

**3. THE FAIRNESS THEOREM — the decisive answer, and it is free.**
**QUEUE is exactly ZERO-SUM against pro-rata.** Therefore the tail's excess return over pro-rata has
the **opposite sign to the pool's own net LP P&L**:
- profitable pool ⇒ **tail strictly worse off** than a plain v4 LP;
- loss-making pool ⇒ **tail strictly better off**.
**Both seats cannot beat pro-rata. No ordering, banding, rotation or partial blend can change that.**
⇒ **Fairness in QUEUE is not an allocation problem, it is a TRANSFER problem** — and the design
already names the transfer: sell or rent the rank. *(The owner's prior "the tail is fine, it eats less
toxicity" is half right — true only in the loss-making regime. The docs' only two worked examples are
both drawn from that regime, which is why the prior survived.)*

**4. ⚠️ THE SHARPEST UNANSWERED ATTACK — full-range capital efficiency. NOT IN ANY DOC.**
The hook mints **one full-range position** (`PLAN.md:64,:325`). A full-range CPMM offers roughly
**1/200th the depth per dollar** of a +/-1% concentrated position. **A $1M full-range QUEUE pool quotes
about the depth of a ~$5-10k concentrated position next door; a $10k swap costs ~4% slippage.**
⇒ no aggregator routes retail to it; retail is the ENTIRE benign side of the P&L; kill it and the pool
is arb-only, LP return goes negative, and the front seat earns `C/c1 x` a negative number.
**The feared inversion IS real — but the cause is full-range-ness starving the pool of benign flow, NOT
front-first allocation.** It is a reversible design choice, not a v4 constraint. **This is the single
most likely question from a v4-native judge and the repo has no answer.** [ANALYSIS]

**5. THE RATCHET — a structural asymmetry named nowhere in the docs.**
Front-first applies in both directions, so the **head unwinds first**: the head is a market maker with
recycling inventory, **the tail is a one-way accumulator, filled at extremes with no priority to exit.**
Severity moderate, not fatal (the tail can withdraw + re-deposit; rank survives per §B.7) — but it is
**a cost of active management imposed on the party the pitch calls passive** ("treasury, LST issuer,
yield vault"). A real contradiction in the sales story; say it out loud. Only B-2 addresses it.

**6. Phase 3 (the SUBMITTABLE state) is a ONE-SIDED MARKET.** The tail's compensation channel is
Harberger rent = **Phase 4**. In Phase 3 the honest answer to *"why would anyone hold seat 5?"* is
**"they wouldn't."** ⇒ **Phase 4 is not optional for the rank-then-run hole alone — it is what makes
the tail's participation rational at all.** In Phase 3 the transfer channel is a secondary market that
`BUSINESS.md` §9.7 **already concedes does not exist.** The tail's deal is sound in theory, empty in
the demo.

**DECISION (orchestrator, panel-backed): BUILD PHASES 0 -> 3. BUILD NO NEW FAIRNESS MECHANISM.**
Ship the Fairness Theorem as an *argument*, not as code — it is stronger than any mechanism and costs
zero engineering days. A panel that answers "is it fair?" by building a fairness mechanism has already
lost the point. **What actually moves value to the tail, all already scoped:** (1) **P2** — worth ~33%
of the tail's fee income at max fee, Phase 1, **the highest-value fairness action available**;
(2) **F1** settle withdrawals against actual holdings, Phase 2; (3) **resolve per-seat withdrawal
feasibility — a Phase 2 BLOCKER, not a nicety.**

**GATE for anything new:** only if Phase 3 is green with real time to spare — then ONE of **B-1
Harberger** (answers fairness, closes rank-then-run) or **B-2 two-sided rank** (order-only, so it
inherits the allocator's proven conservation for free; fixes the ratchet; genuinely novel — nothing in
the 662-row hook directory has it). **Otherwise build nothing new: a half-built Harberger on an
unfinished allocator scores WORSE than zero — it takes Functionality (15%) and Unique Execution (25%)
down with it.**

**KILLED — do not revisit (reasons in `docs/research/premise-review/fairness.md`):** B-4 partial
front-first (pro-rata in a fairness costume; killed on gas) · B-5 banded queue (costs the most
defensible property, buys the tail nothing) · **B-6 rank decay/rotation (FATAL — rank becomes free by
waiting)** · B-7 minimum fill guarantee (fatal) · B-8 distance-weighted rent · B-9 genesis auction
redistribution (no mechanism to build; retained only as a disclosure obligation).

### 2026-08-26 (later) — PLAN §E.5 protocol-fee hazard CLOSED BY MEASUREMENT (research only, no mechanism code)

**Owner directive:** research the §E.5 protocol-fee hazard before building, and scrap the project if
the evidence is bad enough. **Verdict: the hazard is REAL and large, but it does NOT kill QUEUE.**
Do not scrap. Evidence: `docs/research/protocol-fee/` (VERDICT.md, experiment.md, v4-mechanics.md,
queue-exposure.md, raw forge output) + `archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol`.

**What is now PROVEN (executed, reproduced independently by the orchestrator, 7/7 with mutations):**

| Claim | Status | Evidence |
|---|---|---|
| The swap delta a hook reads is **NOT** net of the protocol fee, but the LP position **is** | **PROVEN (source)** | `Pool.sol:369-381` computes the swapper delta from `amountIn+feeAmount`; `:384-396` skims after; `:398-403` credits fee growth from the reduced amount |
| The spike sits in exactly the vulnerable configuration | **PROVEN (source)** | real LP position at spike `:127` `modifyLiquidity`; ledger credited from the swapper delta at `:153,:169-171` |
| Max protocol fee = **0.1% of swap amount**, per direction; new pools start at 0 | **PROVEN (source)** | `ProtocolFeeLibrary.sol:8,:15`; `Pool.sol:105` |
| At max fee the queue is short **0.354e18 token0 / 0.02e18 token1** over the 4-swap scenario | **MEASURED** | `test_E1_maxProtocolFee_breaksTheLedger` |
| The shortfall equals `protocolFeesAccrued` exactly, +3 wei of known §E.4 residual | **MEASURED** | experiment.md F2 |
| Magnitude = **0.1% of input = 33.4% of the LP's entire fee income** (`1000/(3000x0.999)`) | **MEASURED** | experiment.md §4 |
| It leaks at the **minimum 1-pip fee too** — not a max-fee artefact | **MEASURED** | `test_E2_oneWeiPipProtocolFee_alsoLeaks` |
| **P2/P3 (net out `protocolFeesAccrued`) closes the gap to 3 wei**, ~10 lines + 1 SLOAD | **MEASURED** | `test_M3_mutation_P2NettedAllocatorClosesTheGap` |
| Remedy P1 (revert in `_afterSwap`) **cannot block withdrawals** | **PROVEN (structural)** | permissions are only `{beforeAddLiquidity, afterSwap}` (spike `:59-63`); withdrawal is `unlock()->modifyLiquidity(negative)` (`:119,:124-131`), unhooked |

**THE MOST DANGEROUS FINDING — a standing correction to LAW 3, project-wide:**
`protocolFeesAccrued` money **stays inside PoolManager's ERC20 balance** until collected. So the
spike's conservation test — the project's own LAW 3 measurement — **passes at 0 wei error while the
position is short 0.354 token0.** The existing suite could never have found this.
**Conservation must henceforth be measured on `PoolManager ERC20 balance - protocolFeesAccrued(currency)`,
never on the raw balance.** Any test written the old way is blind to every protocol-fee-shaped bug.

**TWO FINDINGS THAT REVERSE PLAN'S P1 RECOMMENDATION (added after the adversarial pass):**

1. **PLAN's own §E.5 test instruction is BLIND to the bug it was written to catch.** `PLAN.md:2092`
   says *"set a protocol fee, run the conservation test."* Executed exactly as written, that goes
   **GREEN** while the position is short 0.354e18 — because `protocolFeesAccrued` is still sitting in
   PoolManager's ERC20 balance. Green there means "unresolved", not "safe". It is a LAW-5 trap of the
   plan's own making. The correct assertion is against `PoolManager balance - protocolFeesAccrued`,
   or directly against `redeemAll()`. PLAN already contains the right instrument (LAW 3's second
   corollary, `PLAN.md:1322-1328`) and simply never wired it to criterion 1.10.
2. **PLAN's stated justification for preferring P1 is factually wrong.** §E.5 argues P1 loses nothing
   *"since we control the pool we deploy."* We control **deployment**, not the **fee** — the
   controller can set it at any time afterwards. P1's cheapness was never in question; its
   justification was.

**P2 is cheaper than previously believed — it needs NO extra hook permission.** The measured M3
implementation keeps a stored running total and diffs `protocolFeesAccrued` inside `_afterSwap`
(legal: credited at `PoolManager.sol:238`, before `afterSwap` at `:221`). So the earlier concern that
P2/P3 required a `beforeSwap` permission — a re-mined hook address and ~15% on the headline gas
number — **is void.** Cost is ~1 SLOAD + 1 SSTORE.

**P1 withdrawal-safety is now PROVEN BY EXECUTION, not just structurally argued:**
`test_E5_P1_refuseInAfterSwap_doesNotBrickWithdrawal` (in `docs/research/protocol-fee/ProtocolFeeExposure.t.sol`,
4/4 green, re-run by the orchestrator). After a refusal the depositor still withdraws in full.
**But placement is load-bearing: if the check ever moves into a shared modifier or the removal path,
a governance fee-set becomes total permanent loss of funds.** A negative control proving withdrawal
still works with the fee on is mandatory in Phase 1.

**P2 edge case that must be handled or refused:** `lpFee == 0` ⇒ `swapFee == protocolFee` ⇒ v4 takes
the *entire* `feeAmount` via a different formula (`Pool.sol:391-392`). Dynamic-fee/`lpFeeOverride` is
NOT a risk (QUEUE has no `beforeSwap` permission). Exact-output swaps need no special handling.

**Decisions taken:**
- **Do not scrap.** The hazard is bounded (0.1% ceiling), detectable in one `extsload`, and has a
  measured fix. It is a real bug with a cheap fix, not a design flaw.
- **✅ OWNER DECISION 2026-08-26: ship P2 (account for it).** Net out `protocolFeesAccrued` in
  `_afterSwap`; do NOT ship a refusal. Rationale below. Phase 1 implements it; acceptance 1.10 is
  satisfied by the netted allocator plus the corrected assertion, not by a refusal.
  **Consequence to remember:** with P2 the ledger no longer over-credits, so the "33% of LP income"
  figure and the "tail eats the shortfall" behaviour BOTH disappear — they were artefacts of the bug,
  not properties of the mechanism.
- *(superseded context)* P1 vs P2 was an open owner decision. The evidence moved against PLAN's P1
  recommendation: P1 hands the PoolManager owner's controller a permanent off-switch for the product,
  and its stated justification is wrong. P2 is measured, needs no extra permission, and keeps the pool
  trading under any fee. **Escalated to the owner per AGENTS.md §4 (a choice that changes the
  mechanism's economics/security).** Whichever is chosen, the check must be re-read PER SWAP.
- Acceptance criterion **1.10's assertion must change** — against `PoolManager balance -
  protocolFeesAccrued`, or `redeemAll()`. As written it cannot fail.
- Acceptance test 1.10 **must assert `protocolFeesAccrued > 0`** or it proves nothing —
  `setProtocolFee` silently no-ops for a non-controller caller.

**⚠️ THE FEE SWITCH IS REPORTEDLY ALREADY LIVE — this is no longer a hypothetical contingency.**
*(WEB-SOURCED, crypto press only, NOT verified on-chain or from source. Treat as a strong prior, not
as fact. Sources in `docs/research/protocol-fee/v4-mechanics.md` §9.)*
- Uniswap **Governance Proposal 100 reportedly executed 2026-07-27** — one month ago — activating v4
  protocol fees on Ethereum, Arbitrum, Base, BNB, Polygon, OP Mainnet and others.
- Reported magnitude **~1/6 of the swap fee (~5 bps on a 30 bps pool)** = ~500 pips, **half the legal
  maximum**. **Independent consistency check: that "1/6" matches the code's own arithmetic exactly**
  (`500/(3000x0.9995) = 16.7%`), which materially raises confidence in the reporting.
- Mechanism: a `V4FeeAdapter` registered as `protocolFeeController` + a `V4FeePolicy` classifying pools.
  **Hook pools are reportedly excluded FOR NOW**, but classification is a governance-permissioned role
  via `setHookFamily` / a `pairClassFees -> familyDefaults -> defaultFee` waterfall, and **no opt-out for
  hook developers exists** — which is exactly what the code says (there is no on-chain opt-out).
- **Consequence for the P1/P2 decision: P1 is no longer a safeguard against a remote contingency. It
  would ship a product whose trading a live, already-executed governance mechanism can halt by
  reclassifying our hook family — with no opt-out and no notice.** This moves the recommendation
  decisively to P2.
- One press claim — *"LP rates are unchanged"* — **is corroborated by our own measurement**, and it
  matters for how we describe the bug: the fee **composes on top of** the LP fee (the swapper pays
  more) rather than splitting it. `test_E5_swapperPaysMore_lpIncomeRoughlyUnchanged` confirms it.
  **So the queue's LPs do not lose a third of their income; the LEDGER over-credits by the protocol's
  share, which is ~1/3 the size of true LP income.** Do not describe this as "LPs lose a third".

**Open / unverified — do not claim:**
- The above is press-sourced. **Verify on-chain before relying on it**: `poolManager.protocolFeeController()`
  and `StateLibrary.getSlot0(poolId)` answer it directly. Exact per-pool values, and whether a hook like
  ours would today be classified into a nonzero family, are UNVERIFIED.
- P1 is a *liveness* surrender: a governance fee-set halts trading until the hook is redeployed.
  Funds stay safe and withdrawable. Accepted consciously; revisit if P2/P3 is built.

**Housekeeping:** `foundry.toml` gained a `[profile.spike]` (archived src/test paths) so the archived
spike runs unmodified; the default profile is untouched. A subagent had un-ignored two private chat
logs in `.gitignore`; reverted. **No mechanism code written — Phase 0 is still NOT STARTED.**

### 2026-08-26 — design phase closed, build not started
- QUEUE selected after an exhaustive candidate search. Honest score **4.33** on the published rubric.
- Alternatives assessed and rejected with evidence, all archived: a hook-safety/bonding platform
  (sound but unwinnable — the security lane is 0 for 9 across eight cohorts), permissioned pools
  (Uniswap shipped it, hit the same wall we did, zero on-chain adoption), a CPG static-analysis
  product (off-chain, fails the "must be a hook" gate), and four fee-mechanism designs that topped
  out at 3.95.
- **The structural lesson that produced QUEUE:** every earlier candidate was a *fee mechanism* —
  it answered "who pays and how much". Winners in this competition **mint a new tradeable object**.
  That reframe is what moved the ceiling.
- Repository archived to `archive/2026-08-26/`. Clean ground prepared.
- **Next action: `PLAN.md` Phase 0.** Reproduce the reference spike from
  `archive/2026-08-26/test/spike/QueueAllocator.t.sol` in the new `test/queue/` tree and confirm the
  three negative controls still go red. **Do not write new mechanism code until that is green — and
  do not trust it green until the controls are red.**
