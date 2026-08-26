# CLAUDE.md — UHI10 project constitution

**Read this file first, every session. Then `docs/NEXT_SESSION_ASSAY.md`, then `README.md`.**
Update the Operational Log (§8) at the end of every working session. This file is the memory;
chat is not.

---

## 1. Who you are

Senior smart-contract **exploit researcher** + **static-analysis architect** + **orchestrator**.
You are building an exploit machine, not a pattern matcher. You own the project and hold only
**distilled** results; context-heavy work is delegated to sub-agents that are then closed.

### The mindset — paste this verbatim into every sub-agent prompt

> Brutally honest. You are NOT here to validate the owner or yourself. A false "PASS" is worse than
> an honest "FAIL". Over-fitting and green-number-chasing are the #1 sin. When a test passes on the
> first run, that is a reason for suspicion, not satisfaction. When an assertion is aspirational,
> assert what is actually true and say what is not. If a direction is weak, say so plainly and
> challenge it.

### How you talk to the owner

Direct, not diplomatic. Not polite. Concrete over elegant. **Volunteer disagreement** — if a
direction is lame or suboptimal, say so before doing the work, not after. The owner has explicitly
asked to be challenged. Realistic exploit assembly > elegant theory.

### Method: PDCA

One thing at a time. Start small. **Validate the riskiest assumption BEFORE building on it.** That
discipline is what killed Hardcap before it was submitted, and it is worth more than any feature in
the repo.

---

## 2. The panel of experts

Consult on **every** delivered task or sub-task. When they raise a concern, look into it carefully
and address it. If unsure whether a concern is in scope, ask the owner.

```
Lead Exploit Developer ......... overall exploit strategy
Taint Analysis Specialist ...... data flow and state corruption
Edge Case Hunter ............... boundary conditions
Economic Incentives Analyst .... profitability and game theory
Devil's Advocate ............... challenge assumptions, find weaknesses
State Transition Expert ........ state-machine vulnerabilities
Symbolic Execution Expert ...... path constraints and reachability
Skeptic Web3 Expert ............ real-world attack feasibility
Skeptic vulnerability triager .. is this actually a bug?
Bug-bounty Triager ............. would this pay out?
Asymmetry Attacker ............. paired functions, branches, writer/reader mismatches.
                                 "The bug is not in one wrong line; it's in what's missing or
                                 different across two places that should match."
Economic Security Expert ....... external deps, value flows, incentives. Unlimited capital + flash
                                 loans. Every dependency failure is an extraction opportunity.
Execution Trace Expert ......... entry point -> final state through encoding, storage, branching,
                                 external calls. Every unenforced assumption is an opportunity.
First Principles Expert ........ ignore known patterns; read the code's own logic, name every
                                 implicit assumption, violate them systematically.
Periphery Agent ................ libraries, helpers, encoders, base contracts. Core trusts these
                                 implicitly; one bug in a 20-line library compromises every caller.
```

---

## 3. Mission

Win **UHI10** (Atrium Academy / Uniswap Hook Incubator, cohort 10). Theme:
**"Sustainable Liquidity and MEV Protection."**

- **Exactly ONE** official submission is allowed. Choosing the right hook matters more than
  polishing the wrong one.
- **Deadline: ~2026-11-03. LOCKED, owner-confirmed 2026-08-26** (deck said 2026-09-03; the +2 month
  extension is confirmed by the owner and is no longer an open question — do not re-litigate it).
  ~8 working weeks. That is a reason to choose well, not a reason to drift.
- **Off-theme is ACCEPTABLE to the owner**, at a stated cost of lower prize odds. Note the shots an
  off-theme project has: General Prize, Unichain ("best innovation of any kind"), any sponsor track
  we genuinely integrate, and the Uniswap Prize — which is **not** strictly theme-gated (UHI9's went
  to Orbital, an off-theme stableswap curve). There is **no** security/tooling/DX track.
- The video gate is **not a concern for now** (owner-confirmed, 2026-08-22). Do not re-raise it
  unless the owner asks.

### Owner's selection criteria — stated 2026-08-26, these govern the choice

1. **"Clearly interesting" is the bar.** Not "solid". Not "well-executed". Interesting.
2. **Small and high-quality beats spread thin.** Default to one sharp mechanism delivered robustly.
3. **The exception, and it is explicit:** a genuine **WOW** concept may be shipped as a
   *good-enough demonstration* rather than a finished product — because the thing may be a protocol
   rather than a hackathon deliverable, and that is understandable to a judge. **Do not use this as
   licence to under-build an ordinary idea.** It applies only when the concept itself is the
   contribution.
4. **Robust and sustainable code is a hard requirement**, in every branch.
5. **Security is an acceptable route** — but if taken, we must position explicitly against
   **OpenZeppelin's `uniswap-hooks`**, **Trail of Bits** (audits + `building-secure-contracts` +
   Echidna/Medusa), and **Uniswap's own security guidance**. Anything a developer already gets free
   from OZ today is not a submission. Apply the delete test.
6. **Open research question:** Uniswap may favour invariants *in some form* — but which form (runtime
   on-chain check / off-chain property suite / formal spec / audit artifact) is decision-critical and
   was NOT established by earlier research. See `docs/research/SECURITY_LANDSCAPE.md`.

### Current state of the decision

| Candidate | Status |
|---|---|
| `HardcapHook` — fail-closed MEV cap | **DEAD.** Economically inverted, freely bypassable, vault drainable. Demoted to "reference hook" only. See §6. |
| **Assay** — hooks carrying a machine-checked spec, bonded | **IMPLEMENTED, NOT DECIDED.** ~160 tests green. Must be assessed for 5/5 potential before it is adopted. |
| A new, better-fitting hook | **OPEN.** Reachable via ideation + frontier-model research, then assessment. |

### The phase plan (do not skip ahead)

1. **Assess Assay** — honest score, business brief, is it 5/5? *(in progress)*
2. **Research** — hackathon requirements, past winners, saturated lanes, white space.
   Persist to `docs/research/` so it is never redone.
3. **Ideate** — panel brainstorm + frontier models (Grok, Perplexity deep research). Produce a
   handful of candidates explained in **business language**: what it is, why interesting, who would
   use it, what is novel, how it is used, pros/cons.
4. **Assess & choose** — one submission. Only switch to something genuinely interesting,
   well-suited, not already built, and aligned with Uniswap's direction.
5. **Build.**

A switch is justified **only** by a candidate that is materially better on theme fit + novelty.
"New and shiny" is not a reason.

---

## 4. Repo map

```
src/assay/            the current candidate
  AssayBaseHook.sol   every value-capable callback implemented WITHOUT `virtual`
  AssayHook.sol       immutable declared invariants (max 4), fail-closed
  AssayFlowMeter.sol  per-block extraction ceiling, entry-to-exit off PoolManager's ledger
  PredicateSandbox.sol evaluates untrusted predicates; revert/OOG/mutation/reentrancy/bomb ->
                       INCONCLUSIVE, never VIOLATED
  HookBond.sol        capital staked per assertion; commit-reveal challenges
  AssayRegistry.sol   stateless per-hook report + per-claim bond breakdown
  AssayStack.sol      several untrusted sub-hooks on one pool, each budget-bounded
  predicates/         DeltaBudget, BalanceFloor, Permission*, Solvency, TickBand
  testing/AssaySuite  drop-in invariant campaign for any hook repo
src/HardcapHook.sol   dead candidate, kept as reference hook
docs/                 plans, spikes, handoffs
docs/research/        durable research artifacts (hackathon, winners, ground truth)
```

Commands:
```bash
forge test                          # full suite, ~60s (invariant campaigns dominate)
forge test --match-path "test/assay/*"
```

---

## 5. Hard-won facts — DO NOT REDISCOVER

These cost real time. Violating one silently produces a green test that proves nothing.

1. **No constructor gate is possible.** During construction `address(this).code` is empty, so any
   predicate that calls back into the hook reverts on `extcodesize` and reads INCONCLUSIVE. Also
   unnecessary — fail-closed runtime enforcement bricks a mis-specced hook on arrival.
2. **`verifySpec()` must evaluate at the RUNTIME gas budget**, not the adjudication one. Otherwise a
   predicate needing 50k reports HOLDS to the registry while the 30k callback check refuses every
   swap, and the registry calls a bricked hook healthy.
3. **LP exits must NOT fail closed on INCONCLUSIVE.** The invariant set is immutable with no
   recovery path, so a predicate that stops answering would trap every LP's capital forever.
   VIOLATED still blocks — a violation during withdrawal is the hook extracting from the exiting LP.
4. **Measure the entry-to-exit INCREASE in ledger debt, never the absolute.** Under
   `afterSwapReturnDelta` a hook's `take()` debt is netted to zero by the delta it returns, so a
   running total scores the second extraction of a transaction as zero; under other settlement
   patterns debt accumulates and the same total counts one extraction many times.
5. **Never let untrusted code choose how much memory you allocate.** Solidity's `(bool, bytes
   memory)` call form copies ALL returndata. Use bounded assembly copies. This bug was fixed once in
   `PredicateSandbox` and **reintroduced** in `AssayStack`. Check for it in any new code that calls out.
6. **Sibling mixins that both override the same hook form a diamond** that every integrator must
   disambiguate by hand — which invites them to resolve it by disabling the safety feature.
   `AssayFlowMeter` extends `AssayBaseHook` for this reason. Keep it a chain, never a diamond.
7. **`targetSelector` without `targetContract`** leaves the fuzz target set as *every* contract
   deployed in `setUp`. Always call `targetContract`. (This is how an invariant suite "passes on luck.")
8. **Proxy upgrades are not detectable on-chain** — a contract cannot read another contract's
   storage. Codehash pinning catches metamorphic redeploy only. Never claim otherwise.
9. **`IHookPredicate.check(address)` selector is `0xc23697a8`**, hardcoded in assembly and pinned by
   a test. A guessed selector silently turns every verdict into INCONCLUSIVE.
10. **A 1:1 test fixture hides EVERY token0/token1 unit-mixing bug.** The capstone's VPIN metric
    subtracts token1-denominated volume from token0-denominated volume; on its 1:1/18-dec fixture the
    error is invisible, on a 1:4 pool the same balanced flow reads 0.607 instead of 0.003, and on
    ETH/USDC it pins at max fee forever. **Test every new mechanism at a NON-UNIT price with a
    negative control.** SWITCHBACK's watermarks and HASTE's minOut floor both compare quantities
    across the two sides of a pool — both are exposed to exactly this.
11. **`poolManager.donate()` pays whoever is in range NOW.** There is no primitive that pays "the
    liquidity present at block open". Any escrow-and-donate-later design must solve beneficiary
    selection itself (aged-LP escrow + JIT activation delay via `bornBlock`, key including `salt`).
    OZ's `LiquidityPenaltyHook` documents the bypass in its own NatSpec: dust from a second account
    at an empty tick, push price there, collect your own penalty donation. OZ calls it "rarely
    profitable" — on thin volatile pairs it is cheap.
12. **`PoolManager` keys POSITIONS by the unlock's `msg.sender`** — usually the router, not the
    trader. Same root cause as audit A-1 and §5.5. Settle this before writing any aged-LP logic.
13. **"0 matches" can mean the road was deliberately not built.** Before treating an empty search as
    white space, ask whether the incumbent standard *routes around* that position on purpose. The
    runtime-on-chain hook-safety slot is empty because Uniswap's own Security Framework points
    authors at audits, monitoring, off-chain invariant suites and optional FV instead — **not because
    nobody thought of it.** Every prior research pass in this project read emptiness as opportunity;
    that was wrong at least once.
14. **Never cite "Uniswap uses invariant testing" to support a runtime on-chain product.** What they
    ship is not what the docs imply (v4-core CI = `forge test --isolate`; commented-out v3 Echidna
    config; `mythx.yml` pointing at a non-existent dir; v4-periphery has one invariant test, on a
    *hookless* pool). And Certora's published v4 rule verifies **PoolManager against arbitrary
    hooks** — the opposite direction from verifying a hook against itself.
15. **Ask a frontier model for a MECHANISM or you get an ADJECTIVE.** Measured: one 1,261-line Grok
    session prompted for *"something even the boldest Uniswap people would find hard to believe"*
    produced **zero** candidates and a vocabulary (autopoiesis, homeostasis, apoptosis, membrane,
    metabolism). Three sessions prompted for mechanisms plus adversarial kill-rounds produced five.
    **Always demand: state kept / trigger / settlement path.** And run the delete test on the answer.
16. **A v4 hook CANNOT bind an allowlist to the party that receives the tokens.** `sender` in
    `beforeSwap` is the **router** (asserted, `test_Q3_senderIsTheRouterNotTheTrader`), `hookData` is
    **caller-supplied** and empty by default, and the hook **never sees the recipient** — the router
    calls `poolManager.take(currency, recipient, amt)` *after* the hook's last callback. So any
    KYC / ZK / lockup / trading-hours gate proves *"some allowlisted address appeared in the
    calldata"*, **not** *"the recipient is allowlisted"*. Three escapes: be the periphery (kills
    aggregator routing); an issuer signature per trade (a live off-chain censor on the swap path); or
    **the token enforces it itself (ERC-3643/1400) — which makes the hook redundant.**
    ⇒ **The entire hook-based compliance-gate lane fails the delete test.** True of all 78
    compliance-tagged submissions in the directory; none of them say it. **Publish this.**
17. **Fairness is not a present-state property** and therefore can never be a predicate. "This swap
    was unfairly priced", "the hook stole in block N" are not expressible. Do not claim them.

### The two v4-only properties the whole Assay thesis rests on

Both verified in-repo. If either is wrong, Assay collapses — re-verify before betting further.

- PoolManager keeps every account's live flash-accounting delta in **transient** storage at
  `keccak256(abi.encode(account, currency))`, and **`exttload` is `external view`**. Mid-callback,
  from outside, anyone can read exactly how much a hook is into the pool for — from PoolManager's
  ledger, not the hook's own accounting. The hook does not own that number and cannot misreport it.
- Hook permissions live in the **low 14 bits of the address** and PoolManager enforces them. What a
  hook is *permitted* to do is provable with **zero calls, zero bytecode, zero trust** — for any
  address, deployed or not.

No other class of contract on Ethereum offers either property.

---

## 6. Hypotheses — what worked, what did not

| Hypothesis | Verdict | Evidence |
|---|---|---|
| "Cap hook extraction per block and call it MEV recapture" (Hardcap) | **FAILED** | First swap of block was tax-exempt → *subsidises* the top-of-block race. A dust in-range liquidity add zeroed the claw for a whole block, permanently, for gas. Vault drainable by a one-block JIT position. Three of these were written up as "accepted weaknesses" or enshrined as passing tests — the review, not the suite, caught them. |
| "Enumerate bug classes and write a detector per class" | **FAILED by construction** | Fails at the next bug class. Replaced by: bound the damage at the ledger, don't care what caused it. |
| "Post-hoc bonding/compensation is enough" | **FAILED** | By the time insolvency is provable, the tokens are gone. This objection ("name a real exploit you would have stopped") is what produced runtime enforcement — the largest thing in the repo, and it was in none of the original proposals. |
| "Read hook extraction from PoolManager's transient ledger via `exttload`" | **WORKED** | The load-bearing insight. Verified in-repo. |
| "Permissions are provable from the address alone" | **WORKED** | Zero calls, zero bytecode. Defeats Hardcap's own README in one place — `NoSwapDeltaPredicate` refuses to let its author bond that claim. That self-refutation is the strongest demo in the repo. |
| "Make enforcement non-`virtual` so integrators cannot omit it" | **WORKED** | `test_enforcementSurvivesAnIntegratorWhoNeverCallsIt`: a hook that declares a spec, drains every swap, never calls the assertion — cannot complete a single swap. |
| "Sandbox untrusted predicates so hostile ones can't produce false VIOLATED" | **WORKED** | Revert / OOG / mutation / reentrancy / returndata bomb / malformed all read INCONCLUSIVE. |
| "23.5k gas overhead" | **BOGUS, retracted** | Artefact of comparing a hook that transfers against one that does not. Real like-for-like: 192 gas machinery, 3,497 balance invariant, 4,509 ledger invariant, 5,766 flow metering. **Quote only these.** |

---

## 7. Known-open weaknesses — state them, never hide them

Every one of these must be said out loud in any pitch. Hiding one is the fastest way to lose
credibility with a technical judge.

1. **A bond below the value a hook controls does not deter a rational attacker.** Unfixable. One
   plain sentence, every time. It is a costly signal + challenger funding, not insurance.
2. **A spec can be padded with cheap claims.** Tranches price each assertion and `bondBreakdown`
   publishes them, but nothing forces real money onto the assertion that matters. Disclosure, not
   prevention.
3. **Assay binds only hooks that chose to bind themselves.** A malicious author simply would not
   inherit it. The guarantee is against *defects* in opted-in hooks.
4. **Fail-closed can brick a pool's trading.** Stated trade-off. LP exits are the deliberate exception.
5. **Only present-state invariants are provable.** One staticcall, public state, no privileged
   input, no history.
6. **Proxy upgrades are invisible on-chain.** (§5.8)
7. **Challenge front-running is reduced, not eliminated.** A searcher blanket-pre-committing across
   every (bond, predicate) pair can still race the reveal. Asserted in
   `test_knownLimit_preCommittedSearcherCanStillRace`.
8. **Slashed capital is locked forever** — deliberate (it must leave the author's reach) but it is
   NOT compensation and must never be described as such until a victim-claim path exists.
9. **Hardcap F1 unfixed by choice** — its vault pays late depositors out of historically accrued
   surplus. Fairness is not expressible as a predicate (§5.10), so the claim was withdrawn instead.

---

## 8. Operational log

Newest first. One entry per working session: what was decided, what was proven, what was killed.

### 2026-08-26 — REFLEXIVITY TESTED: fear false, but a FIFTH free lane found
`docs/research/IDEAS_MECHANISM.md` REFLEXIVITY section; seeded model
`docs/research/data/switchback_reflexivity.py` + frozen `.out`. LVR gate carried over and PASSES
(σ²V/8 to 0.2–0.4%) in all four vol regimes.

**✅ The reflexivity hypothesis is FALSE and the sign is backwards.** OZ's warning does not transfer:
**`T0` is the pool's OWN tick at block open, not a price estimate — it cannot be stale relative to
the quantity the fee measures, because it IS that quantity's origin.** Corollary that kills the
analogy: **the top-of-block corrective arb is NEVER taxed**, because the first swap of a block moves
*away* from `T0` by construction. SWITCHBACK therefore cannot deter the arbitrage anchoring its own
reference. Simulated: suppressing 95% of arbitrage raises staleness 13× and *reduces* honest cost
3.79 → 2.62 bps. Loop converges fast (saturates ~14 ticks even at 16× fee slope); LP cost −1.4%
pool-vs-HODL. **Risk closed.**

**⚠ A HEADLINE CLAIM I PUT IN THE BRIEF WAS FALSE — retracted.** "Ordinary traders unaffected, the
honest path is free" is wrong. A corrective arb extends price at the top of nearly every block, so
**~half of one-way honest flow arrives in the retracing direction and is charged**: at γ=1, **44.6%
of honest swaps pay ~3.79 bps, a +76% increase in all-in cost.** ~44% of that is the reference
channel; **~56% is intrinsic** two-sided flow inside one block and cannot be engineered away (a
perfect oracle reference only improves it to 2.13 bps). **In a low-extraction pool 67% of what
SWITCHBACK collects is billed to honest traders, not attackers.** Must be said on camera.

**⚠⚠ FIFTH APPEARANCE OF THE FREE LANE — the reset IS the exemption.** If the first swap of a block
can never be a retracement, **every top-of-block swap is fee-exempt by construction.** Attack:
front-run + victim in block N (front-run = extension, free), unwind at the **top of block N+1** where
`T0` has re-set to the displaced price (extension, free). **Total fee 0.00, asserted every trial.**
Still-profitable 27.9% in-block → **82.6% cross-block**; keeps 1.7% → **90.6%**. Break-even race-win
probability **1.9%** (5 bps pool). **Refutes §2.4a's load-bearing mitigation** — it is not "~12s of
price risk", it is **one block boundary = 200 ms on Unichain, our target chain.** Unsimulated
counter: the N+1 first slot is contested by the top-of-block arb, so surplus is partly bid away **to
the sequencer, not the LPs** ⇒ true statement is *"SWITCHBACK collects nothing on this route."*

**BUILD: the watermarks are DEAD WEIGHT.** A closed form on `T0` + ticks before/after reproduces every
number bit-for-bit. **One storage slot, not three.** And "the fee is capped by how far price was
extended" is a **TAUTOLOGY**, not a separate defence — do not pitch it as one. (Dust-poison cap does
hold exactly: 0.25-tick poison then a 199-tick opposite swap charges 0.250 ticks.)

**SWITCHBACK downgraded HIGH → MEDIUM.** GO-WITH-FIX, fix not yet in hand.

### 2026-08-26 — SECURITY ROUTE CLOSED, with primary-source evidence
Full report + PROVENANCE: `docs/research/SECURITY_LANDSCAPE.md`.

**The owner's hypothesis was right in FORM and wrong in KIND.** Uniswap does like invariants — as an
**off-chain, pre-deployment artifact handed to an auditor.** Never as a runtime on-chain check.

**Uniswap's own Security Framework** (`developers.uniswap.org/docs/protocols/v4/security`, read in
full): *"an appropriate combination of **audits, monitoring services, bug bounties, and optional
formal verification**"*; *"use invariant and stateful fuzz testing (**e.g., with Foundry or
Echidna**)"*; *"**invariant testing required for accounting logic**"*. Its Security Resources list —
the definitive statement of whose tools Uniswap points hook authors at — is OZ (library), Hypernative
/ Hexagate (monitoring), Certora / Halmos / SMTChecker (FV), Areta / Spearbit / C4 / Cantina (audit),
Foundry / Echidna / Scribble / **Hacken `uni-v4-hooks-checker`** (testing).
**ZERO entries for runtime enforcement, bonding, attestation, or registry.**
Money follows the same road: **$1.2M to Areta for audit subsidies** across 16 firms.

**⚠ Uniswap ships far less than its docs imply — never cite "Uniswap uses invariant testing" to
support a runtime product.** v4-core CI is `forge test --isolate` and nothing else; its
`echidna.config.yml` is commented-out v3 leftover; Echidna covers three pure-math libs;
`mythx.yml` points at a `contracts/` dir that does not exist in v4-core. v4-periphery has **exactly
one** invariant test, on a **hookless** pool. Real assurance = 5 audit PDFs.
Certora's published v4 hook rule verifies **PoolManager against arbitrary hooks** — not hooks against
themselves. **Direction matters.**

**What is already free:** OZ `uniswap-hooks` (v1.1.1, named first in Uniswap's framework, Contract
Wizard) ships base + fee + AntiSandwich/LiquidityPenalty/LimitOrder/ReHypothecation — and, verified
by exhaustive tree scan, **zero invariant tests and no Echidna/Medusa/Certora/Halmos config.**
**Trail of Bits** wrote the v4 property suite (`trailofbits/v4-core` branch `add-stateful-properties`,
~4,000 lines, shadow accounting + state machine + Medusa) — **targeting PoolManager; hooks are out of
scope.** `building-secure-contracts` and `crytic/properties` have **zero** v4/hook content.
**Hacken `uni-v4-hooks-checker`** already occupies the endorsed slot — and has **7 stars.** That is
what `AssaySuite` was, shallower, already blessed. Plus a graveyard of 0–5★ clones (hookrisk,
hookguard, HookVault, v4-hooks-analyzer, v4-hook-invariants, aegis). **Many have had this idea;
nobody has traction.**

**THE COUNTED KILL:** 75 hooks in the directory are tagged Security. The **nine** whose product IS
hook-safety infrastructure — AegisHook (×2), Hook Safety As A Service, reCEPTION-guard, Vedyx, Hook
Bazaar, Uniroid, StakeShield, RugGuard — won **nothing. 0 for 9, across eight cohorts.** The one
honest counter-example, UniGuard (UHI3), won the **EigenLayer** prize for its AVS integration, not
for safety. Every other security-tagged winner won for compliance, privacy, or composition.

**THE STRUCTURAL POINT — the best sentence of the day:** the runtime-on-chain position is unoccupied
**because Uniswap's own framework routes around it. That is not white space; it is a road they chose
not to build.** A judge holding the framework asks which tier of the worksheet this satisfies, and
the answer is none.
**Judge's one-liner:** *"OZ already gives me the safe base contracts, ToB already published the
stateful property harness, the Foundation will pay for my audit, and Uniswap's own framework tells me
to run Foundry invariants and wire up Hypernative — so what is this for?"*

**VERDICT: no defensible, unoccupied, submittable security position. The security route is not
viable.** This does not overturn the standing decision; it removes the last reason to reconsider it.

**WHERE THE ASSAY WORK GOES — now evidence-backed.** Uniswap's framework §10 "Future Extensions"
explicitly asks for **"open source testing patterns"** and **"standardized reference hooks"**. The one
verified unoccupied gap is a **hook-facing stateful invariant suite** built on ToB's shadow-accounting
technique (ToB is core-facing, Hacken is conformance-shallow, OZ has none). Grant-shaped and
public-good-shaped, **consumes none of the one submission** — the destination for Assay alongside the
permission census and the ERC-6909 laundering finding. It is **not** a submission: fails Gate 3
("a real v4 hook, or a direct interface to one"), cannot score 30% Original, and fails the delete
test badly.

### 2026-08-26 — ASSAY REMEDIATION SCOPED: sound, safe, fixable, still not the submission
Full costing: `docs/research/ASSAY_REMEDIATION.md`. Deadline now LOCKED at ~2026-11-03, so this was
re-asked without the eight-day clock. **The answer did not change, and the reasoning got stronger:
the fixes are cheap, so "we couldn't fix it" was never the reason.**

**Three-way verdict (stop conflating these):**
- **IDEA — SOUND**, but ~30% smaller than the pitch.
- **IMPLEMENTATION — SAFE TO HOLD MONEY.** A hunting auditor found **no third-party fund-loss path**;
  `HookBond`'s CEI / reentrancy / collision handling is clean. Exactly **one** real third-party vuln
  (A-1). **The real problem category is not security — it is that the evidence is unreliable.**
- **CLAIMS — FALSE in four places outright**, unscoped in several more.
Remediation moves **none** of theme fit 2/5, demonstrability 2/5, adoption 2/5.

**NEW STRUCTURAL FACT — the enforceable and the bondable sets are DISJOINT.** Transient storage is
live inside a callback and **zero at top level**. `HookBond.bond():184` and `challenge()` both
evaluate predicates at top level ⇒ `DeltaBudgetPredicate.check()` is **unconditionally true on every
bonding path**. The strongest predicate in the library can never be slashed and never blocks an exit.
The README's own worked example — *"40 ETH on never exceeding its budget"* — **is the one number that
can never be lost.** (This is audit A-6, confirmed in source.)

**NEW: a v4 hook extracts through THREE channels, not two.**
1. **take/mint** — only the `exttload` ledger sees it. Genuinely irreplaceable, genuinely novel (1/662).
2. **the returned hook delta** — closed by **arithmetic**; needs none of the v4-only properties.
3. **any non-callback external the subclass declares** (A-10) — **UNFIXABLE BY INHERITANCE.** Best
   available fix is an opt-in modifier, i.e. back to trusting the integrator, which is the exact
   failure `AssayBaseHook` exists to eliminate. §1.7's exploit used this channel to sweep, and
   **`HardcapHook` ships such a function.**
Novelty was already 4/5 **before** §1.7 was known — it was never the constraint. Remediated Assay
weights ≈3.0–3.3 vs a shortlist at 3.95–4.10.

**The Orbital precedent cuts the wrong way:** off-theme **new math** has taken the top prize;
off-theme **infrastructure** has not. Assay creates an **attestation, not a tradeable object** —
which is precisely what P5 says winners have.

**Costed (1 senior dev, 25 h/wk, ~200h to the deadline):** all 17 findings + §1.7 = 87h; ~100h with
regression. **Minimum honest ≈55h** (an honest narrow library; not a submission). **Full fix ≈145h**
— ends at ≈3.0 and **eats the submission**; its 25h "wrap a real third-party hook" item is HIGH RISK
and may return nothing. **Reframe small ≈75h**, only ~20h of it on the submission — and **2 hours of
DELETION** (`AssayStack`, `AssayRegistry`, `AssaySuite`) removes A-1, A-2, A-3 and A-4 outright.

**DECISION: publish Assay, submit something else, and DOGFOOD a reduced Assay on what we submit.**
The submitted hook inherits `AssayBaseHook`, declares and bonds a ceiling on **its own escrow**, and
goes on-chain. Per the ledger theorem that is case (a) — the hook's own debt — the one place the
meter is sound. Deletable from the mechanism, but it scores under Unique Execution (25%) +
Presentation (10%), and *"we bonded 1 ETH we lose if our own escrow exceeds its declared ceiling,
here is the address"* beats another feature. ~20h.
**HARD CONDITION: dogfood only if §1.7 is fixed first.** Shipping "carries a spec it cannot violate"
with the return-delta blind spot open hands a technical judge the thread that unravels the
submission. 16h buys the right to say that sentence; without them, **delete the claim.**

**Bond+meter INSIDE HASTE or SLUICE: NO to both.**
- **HASTE — decoration, killed by HASTE's own adopted fix.** The strongest version genuinely works
  (the searcher-filler bundles front-run + crank + back-run in ONE tx, so the front-run leg's debt is
  live in the filler's ledger at the crank callback, and a registered filler cannot address-shop).
  But settling at **block-open price** makes front-running your own crank worthless *whether or not
  anyone detects it*. Delete the meter and HASTE is unchanged — the definition of decoration.
  Residual value: filler **liveness is historical**, therefore not expressible as an `IHookPredicate`;
  we would reuse `HookBond`'s escrow plumbing (~6–10h saved) and nothing else.
- **SLUICE — inapplicable, cannot be built.** `GPv2Settlement.settle()` runs in a **different
  transaction**: no PoolManager unlock, no transient delta to read. And requiring solvers to register
  would shrink the solver set and therefore the surplus — **making SLUICE worse.**
- The non-decorative shape is an **in-transaction auction whose winner executes inside our own
  unlock** (GRAZE-ish). Neither shortlist candidate has it.

**ORDER OF WORK (~60h Assay spend, none on the submission's critical path):** 2h delete three
contracts → 12h retract every false claim + re-measure gas on the sealed path → 16h fix §1.7 → 10h
permission census (true under every branch) → build the submission inheriting `AssayBaseHook`, bond
two real invariants, deploy (~20h Assay-side) → publish the ERC-6909 laundering finding + census.

### 2026-08-26 — PHASE CLOSE: assess → research → ideate → assess, all four done
Decision doc: `docs/DECISION_CANDIDATES.md`. Business brief: `docs/ASSAY_BUSINESS_BRIEF.md`.
Research: `docs/research/{HACKATHON_CONTEXT,WINNERS_LANDSCAPE,ASSAY_GROUND_TRUTH,IDEAS_*}.md`.

**ASSAY: do not submit. Do publish.** Two independent passes converged, then execution finished it —
its novelty (the `exttload` ledger read) covers **one of two** extraction channels, and the other is
closed by ordinary arithmetic needing none of the v4-only properties the pitch rests on.

**SHORTLIST, all three within noise:**

| | Score | Proven by execution | Still unproven |
|---|---|---|---|
| **SWITCHBACK** | 3.95 | Router-clean. No oracle/keeper/randomness/periphery/off-chain part. | Fee curve, JIT-refund attack, dust-poison cap — economics untested. |
| **SLUICE** | 4.05 | Real `GPv2Settlement.settle()` on fork + mutation-tested. Non-Safe EIP-1271 path works. | Recapture undemonstrable on Sepolia (one solver); needs our watch-tower; toxicity classification untouched. |
| **HASTE** | 4.10 | Router path scoped 14–20h. Economics modelled w/ LVR + closed-form gates. | **λ (retail impatience)** — the deciding number; block-open fix reasoned only. |

**THE SYNTHESIS THAT SETTLED IT.** HASTE's fix for the searcher-filler hole is *settle at block-open
price*, which needs a block-open reference tick — **exactly the state SWITCHBACK already keeps.**
They are not alternatives. **SWITCHBACK is the substrate.** Build order, not a fork:
Layer 1 (block-open tick + watermarks) → SWITCHBACK ships alone → HASTE extends it, gated on λ.
**Recommendation is therefore unconditional on the deadline: build SWITCHBACK now.**

**HASTE economics, headline:** σ cancels — **N_max = 2·(0.581/λ)² − 1**. The boundary is retail
impatience, not volatility. λ ≤ 0.15 works comfortably; **λ ≥ 0.35 is dead.** λ is behavioural, cannot
be derived, only measured. **Next experiment: measure λ from observed deadline/slippage settings on
real v4 swaps.** Also: the deferred fill is a *forward*, not an option (linear payoff, no gamma) — the
delta-neutral-placer objection is dead; **the refund** is the real option at 1.6–3.5× the arb's edge,
closed by flooring minOut at 2σ√E[T].

**TWO NEW HARDCAP-SHAPED HOLES, both found by attacking our own favourite idea:**
- The searcher-**filler knows the fill block because it is their own transaction** — randomised
  maturity buys nothing against them.
- **On a pool with no arb competition HASTE collects nothing and defends nothing** (monopolist arb
  defers free). It is a mechanism for *competitively arbitraged* pairs and must be pitched as that.
- Disclose in any pitch: the premium is paid by **widening the no-arb band**, not from the arb's
  pocket (urgent trader's true cost ≈ 2× premium); and **HASTE is regressive** — the filler must clear
  gas, so it protects large retail and taxes small retail.

**KILLED, with reasoning that transfers:** Flashbots/MEV-Blocker integration is **impossible as a hook**
— a category error, no contract exists in the stack; **corollary: a hook cannot detect protected flow**,
and the only on-chain correlate (`tx.gasprice == block.basefee`) is forgeable for free. LP governance
over the MEV mechanism — liquidity-weighted voting on a pool holding a revenue stream is flash-loanable,
**the prize funds the attack**. Searcher bonding for priority access — Sybil; a sandwicher runs the two
legs from two addresses, so nothing is attributable.

**OPEN, owner-only:** the deadline. Primary sources say **2026-09-03** (Demo Day Sept 11); no evidence
of the +2 month extension was found, and the next cohort opens Oct 1, which a November UHI10 would
overlap. Blind spot: X/Discord. **The authoritative check is the owner's email for the `HK-UHI10-####`
Project ID and the Progress Update 2 form dated Aug 31.**

**METHOD NOTE — distrust-green went 6 for 6 today.** Mutation testing or a control caught a defective
test in *every* agent that ran one: the router spike (`reason.length > 0` passing on the wrong revert),
the CoW spike (a circular magic-value assertion, green 6/6 before the real `settle()` existed), the CoW
liveness scan (a broken `cast logs` caught only by running it against mainnet as a control), and the
HASTE model (a sign error caught by the closed-form cross-check). **No agent that skipped a negative
control produced a trustworthy number.** Make the control mandatory, not optional.

### 2026-08-26 — THE LEDGER THEOREM, and a hole in Assay's central claim
Full analysis: `docs/research/IDEAS_LEDGER_FOLD.md`. PoC: `test/spike/LedgerAddressShoppingTest`.

**The theorem — memorise this, it governs every future use of the primitive:**

> The ledger tells the truth about an *address*. The adversary chooses which address faces your hook.
> A hook only ever learns the *locker* address from its callback, and value moves between addresses
> inside one unlock for **52,700 gas**. Therefore every ledger-derived claim about a counterparty's
> *behaviour* is an inference, and the inference is purchasable.
>
> The only accounts whose ledger state a hook can trust are **(a) itself, (b) an account whose debt
> the hook itself caused, (c) an account that agreed in advance to be inspected at a named address
> and posted something it loses by walking away.**

**The asymmetry that makes it work for hooks and fail for counterparties:**

| Direction | Cost to adversary |
|---|---|
| Hide a **debt** | must supply real value ⇒ genuinely impossible |
| Hide a **credit** | ~52,700 gas, zero capital, zero ERC-20 movement |
| Move a position to a clean address | same 52,700 gas |
| **Inflate** your own debt to look poorer | free (`take`, settle back later) |

`ERC-6909 mint`/`burn` is a general-purpose **delta-laundering rail**: it converts a live transient
credit into a persistent transferable token and back, between arbitrary addresses, inside one unlock.
Executed against a real PoolManager; negative control fails red, so the test is not vacuous.

**§1.7 — CONFIRMED BY EXECUTION.** `test/spike/AssayReturnDeltaBlindSpot.t.sol`, 5 tests, full suite
179 pass / 0 fail. One hook, one immutable boolean separating attack from control; spec is the
tightest Assay can express (two `DeltaBudgetPredicate`s at **`maxDebt = 1 wei`** + flow meter at
**1 wei/block**). Measured across three independent ERC-20 balances, nothing on the hook's word:

```
hook extracted   474,829,737,581,559,268 wei     declared ceiling  1 wei
AssayFlowMeter reading                    0      both predicates   true
hook's live debt at every observable point 0
```

**The hook removed 4.7 × 10¹⁷ times its declared ceiling and every meter Assay owns read zero.**
Laundered variant: `mint`s the credit as ERC-6909 direct to an accomplice — extraction is not merely
unmetered but **unattributable on-chain afterwards**. Vacuity guard included (same attack hook + one
always-false predicate ⇒ swap reverts), so the blind spot is in what the ledger *can see*, not in
whether Assay bothered to look. Negative control (`take()` inside the callback) reverts correctly —
that is verbatim `HardcapHook.sol:232`'s own pattern.

**Precondition that bounds it:** `CurrencyNotSettled` means the credit must clear before the unlock
ends, and the hook has no execution context after its last callback. So the attack needs one call to
the hook inside the unlock, after the callback. Any hook shipping its own periphery supplies that
free (HardcapHook does, via `HardcapLP`). So this is an **adversarial-author** shape, not a *defect*
shape — a bug that forgets to `take()` is a bug that does not extract. Against Assay's narrow stated
scope it is a dent. What it falsifies **outright** is the README's "a ceiling the hook cannot exceed
no matter what bug it contains" and `DeltaBudgetPredicate`'s own doc comment claiming the debt is
"precisely what the hook has physically removed." It is not — it is what the hook removed *through
the take/mint channel*. **There is a second channel and the ledger cannot see into it.**

**⚠ §5.4 is incomplete:** its entry-to-exit rationale describes the *combined* take-then-return
pattern and does not cover the *pure* return-delta pattern at all.

**Fixability — settled by measurement, not argument.** The SIGNED delta at the instant
`_assertInvariants()` runs is **`0`**, not merely non-negative (asserted). So `abs(delta)` instead of
`debt()` changes nothing — the credit has not been applied yet, there is no magnitude to measure.
Moving the assertion later is structurally impossible: the hook has no code running at that moment
and never will, because the credit lands *precisely because* the callback returned. **The fix is to
stop using the ledger for this channel** — `AssayBaseHook._afterSwap` already holds the `int128` its
subclass returned, in its own hands, before passing it up. Bounding that value is plain arithmetic:
cheaper than a `tload`, exact rather than inferential, closes the channel completely.

**But note what the fix costs the thesis:** the ledger read covers ONE of the two channels a v4 hook
can extract through, and the other is closed by **ordinary arithmetic** that needs no transient
storage, no `exttload`, and none of the v4-only properties the whole Assay pitch rests on.

**(superseded — original reasoned entry follows)**
A hook extracting via `afterSwapReturnDelta` receives its credit **after** `AssayBaseHook`'s sealed
callback has already run `_assayExit`. Its delta goes `0 → +X` — **positive, never negative** — and it
can relocate that `+X` to an accomplice for 52,700 gas. But `DeltaBudgetPredicate` and
`AssayFlowMeter` both measure `PoolLedger.debt()`, i.e. **the negative side only.**
⇒ **Such a hook extracts X and every Assay meter reads zero at every observable point.**
The straw men don't exhibit this because they `take()` *inside* the callback, creating exactly the
debt the meter looks for. **`HardcapHook` — our own reference hook — takes its fee this way.** This
materially weakens "a ceiling the hook cannot exceed no matter what bug it contains."

Same root cause as audit finding A-1, which is now three-for-three with §5.5:
**we read the address we happened to be holding, not the address that did the thing.**

**Verdict on folding Assay into an on-theme hook: (c) weaker, and the pull toward it is sunk cost.**
Reasons that transfer: the ledger measures *debt*, and for a hook extraction *is* debt — measurement
and thing measured are the same object, which is why Assay works. Toxicity is not debt, so pointing
the same instrument at a swapper converts a proof into an inference worth ~$3 to evade (a fraction of
a cent on Unichain). That is Hardcap's economic inversion rebuilt with a new sensor: the honest
retail flow you cannot distinguish pays every time, and the whale evades. Also: **a sandwich is three
transactions and transient storage does not survive one**, so "does this stop a sandwich?" is "no"
for every ledger-based candidate.
**Do not value the fold at the price of the code; value it at the price of the code minus the fixes.**

Residual value goes to exactly two places, neither of them the submission:
1. As a **component**, aimed only at a party that agreed to be inspected — an auction winner,
   registered solver, designated backrunner. Then case (c) of the theorem holds and it is an
   oracle-free, in-transaction, non-self-reported meter on a privileged party, replacing the AVS
   every LVR project in the directory needed. A paragraph in someone else's hook, not a hook.
2. As a **separate non-submission artifact**: the permission census. ~1 day, true regardless of what
   we submit, does not consume the one submission.
Publish the ERC-6909 laundering finding either way — 1 of 662 projects has ever noticed it.

### 2026-08-26 — INDEPENDENT AUDIT: three README headline claims are false
Full report: `docs/research/ASSAY_GROUND_TRUTH.md` (17 findings, 4 confirmed by execution).
The green suite hid all of it. **This is the third time in this repo that distrusting a green result
found what the suite could not.**

- **A-1 HIGH, PoC confirmed.** An `AssayStack` guest calls `poolManager.take(currency, self, 1)`
  inside its 150k stipend and returns cleanly. The unsettled 1-wei delta belongs to the *guest*, so
  the stack's own budget predicate never fires — and the whole transaction reverts in
  `PoolManager.unlock` with `CurrencyNotSettled()`. Guest list is immutable, no admin, no removal:
  **every swap on that pool fails forever, for the price of gas.** Twelve-line contract, first
  attempt. Falsifies "guests never touch PoolManager" (a convention, not an enforced property —
  `_dispatchOne` uses `call`, not `staticcall`) and "one broken guest must not brick a pool".
  `test_fourGuestsOneHostileAndThePoolStillWorks` passes only because all four straw men politely
  confine themselves to their return value.
- **A-2 HIGH.** The shipped `AssaySuite` campaign is **vacuous** — 256 runs × 128,000 calls, 46s of
  every CI run, and all four invariants are structurally incapable of failing. The demo hook declares
  only a `DeltaBudgetPredicate`, which the invariant runner evaluates *between* transactions, where
  transient storage is zeroed — so `debt()` returns 0 and `check()` is unconditionally true. This is
  precisely the "invariant suite that passed on luck" §5.7 warns about, shipped a second time.
- **A-4 MEDIUM.** Unbounded returndata copy reintroduced in `AssayRegistry` — the exact bug §5.5
  forbids, now three-for-three (sandbox → stack → registry). **Grep every new call-out for this.**
- **A-3 MEDIUM-HIGH.** `bond()` is permissionless and `_bondsOfHook` is append-only, so anyone can
  push a hook's real bonds past the registry's 256-entry scan window for gas. The hook then
  permanently under-reports its own backing.
- **A-8.** The 13-test sandbox kill-suite lives in `test/spike/` and **does not import `src/`** — it
  re-declares the library and tests its own copy. The shipped `PredicateSandbox` has zero adversarial
  coverage, including the parameterised `evaluate` overload that only exists in `src/`.
- **Seven `HookBond` test names claim more than they assert.** `test_slashedTrancheCannotBeSlashedTwice`
  reverts `BondEmpty`, not `TrancheAlreadySlashed` — the real double-slash guard at `HookBond.sol:309`
  has **zero coverage repo-wide**. `test_conservation_acrossFullLifecycle` never calls
  `requestExit`/`withdraw`, the only two functions that move ETH out. All 33 bond tests run against
  `MockBondedHook`, which is a mapping plus a setter; no PoolManager is deployed in that file.
- **Gas: two of the four published numbers are stale.** Re-measured: machinery **170** (README says
  192), ledger invariant **4,631** (README says 4,509). Balance-floor 3,497 ✓ and metering 5,766 ✓.
- **`AssayStack` is the only non-test contract inheriting `AssayBaseHook`.** `HardcapHook` carries no
  runtime spec at all. **The repo does not dogfood its own flagship.**

Auditor's scores: theme fit 2/5 · novelty 4/5 · technical depth 3/5 · demonstrability 2/5 · adoption
2/5. Its one-sentence verdict, which is the standing lesson: *"Everything is proven against hooks we
wrote to be caught. The straw men are calibrated to the defence, and the one place I wrote a hostile
contract that was not, it broke a headline guarantee on the first attempt."*

**Standing order added from this:** before any claim ships, someone who did not write the defence
must write the attacker.

### 2026-08-26 — session start: assess-then-maybe-pivot
- Owner declared Hardcap **off the table** (buggy, weak design) and Assay **not final**.
- Deadline confirmed pushed +2 months; video gate confirmed a non-issue.
- Spawned `Scout` (hackathon requirements + past-winners landscape → `docs/research/`) and
  `Auditor` (ground-truth audit of `src/assay` vs the README's claims → `docs/research/`).
- Wrote this file. Next: business brief for Assay in plain business language, then ideation.

### 2026-08-22 — Assay implemented (commit `206f60b`)
- 160 tests green. Runtime enforcement, flow meter, bond, registry, stack, suite all shipped.
- Gap list recorded in `docs/NEXT_SESSION_ASSAY.md` §4 — **nothing is deployed**, the "gap table"
  of real deployed hooks does not exist, every demo uses straw-man hooks we wrote ourselves, and
  `AssaySuite` does not dogfood our own contracts. These are the credibility gaps, not code gaps.

### 2026-08-21 — Hardcap reviewed and killed
- Eight findings; three were economic and fatal. Pivot decided.

---

## 9. Proactive measures / standing orders

- **Distrust green.** A first-run pass is a reason for suspicion. Before believing a suite, break the
  code deliberately and confirm the suite goes red.
- **Never demo only against straw men we wrote.** Any claim of the form "this catches X" must
  eventually be shown against third-party code.
- **Measure like-for-like.** Any gas number must name its baseline. See §6 for what happens otherwise.
- **Persist research.** Anything fetched from the web that we would otherwise re-fetch goes in
  `docs/research/` with a PROVENANCE block of URLs actually fetched vs. failed.
- **Delegate context-heavy work**, hold distilled results, close the sub-agent. Sub-agents run as
  named cmux teammates in split panes; see the `cmux-teamcomms` skill before spawning.
- **`cpg-solidity` MCP is orchestrator-only** — teammates cannot reach it. Do CPG verification
  yourself; delegate only raw-log-producing Bash.
- **One submission.** Every hour spent on a second product is an hour not spent on the one that
  ships.

---

## 10. References

| What | Where |
|---|---|
| Atrium Request for Hooks | https://atriumacademy.notion.site/atrium-academy-request-for-hooks |
| Atrium Hook Directory (filterable, winners) | https://atriumacademy.notion.site/hook-directory |
| Awesome Uniswap Hooks | https://github.com/fewwwww/awesome-uniswap-hooks |
| Hackathon doc 1 | https://drive.google.com/file/d/1d6Hl-x3euWebEsir5uWLPDC6MbL2fi_x/view |
| Hackathon doc 2 | https://drive.google.com/file/d/1Q1-rIQdD6DxhmSriarAwf_hofMvg7TM-/view |
| Distilled research | `docs/research/` |
| Session handoff | `docs/NEXT_SESSION_ASSAY.md` |
| Predicate sandbox spike (do not re-derive) | `docs/SPIKE-predicate-sandbox.md` |
| `sender` / `afterSwapReturnDelta` spike | `docs/SPIKE-sender-and-afterSwapReturnDelta.md` |
