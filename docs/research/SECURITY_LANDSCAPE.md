# SECURITY_LANDSCAPE — does Uniswap reward invariants, and is there room for us?

*Research date 2026-08-26. Commissioned to answer the owner's question: "I think Uniswap are liking
invariants in some form, maybe not ours — research that. If we go the security route we must always
consider OpenZeppelin, Trail of Bits, and Uniswap's own security guidelines."*

**Every mechanism claim below is from a file I fetched or an API I called. Anything I could not
reach a primary source for is marked `UNVERIFIED` and is not used in the verdict.**

---

## 0. PROVENANCE

### Fetched successfully

| Source | Method | Gave |
|---|---|---|
| `developers.uniswap.org/llms.mdx/docs/protocols/v4/security` (40,240 bytes) | `curl -L`, full text read | **Uniswap's own Security Framework, verbatim.** The decisive source for Task A |
| `github.com/uniswapfoundation/security-framework` | GitHub trees API | The framework is a single `README.md` (40,503 B) + 2 images. That is the whole artifact |
| `Uniswap/v4-core` full file tree (203 files) | GitHub trees API | Every test, config, audit PDF and workflow in v4-core |
| `Uniswap/v4-core` `.github/workflows/{tests-pr,tests-merge,mythx,lint}.yml` | `curl` raw | **What actually runs in CI** |
| `Uniswap/v4-core/echidna.config.yml` + `src/test/TickOverflowSafetyEchidnaTest.sol` | `curl` raw | Scope of Uniswap's own property testing |
| `Uniswap/v4-periphery` full file tree (229 files) | GitHub trees API | Exactly one invariant test exists |
| `Uniswap/v4-periphery/test/ReservesLens.invariant.t.sol` (86 lines) | `curl` raw, read in full | What that one invariant actually asserts |
| `OpenZeppelin/uniswap-hooks` full file tree, `README.md`, `docs/.../index.adoc`, `src/base/BaseHook.sol`, `.github/workflows/checks.yml`, releases API, repo meta | GitHub API + `curl` raw | **Exactly what a hook author gets free from OZ today** |
| `trailofbits/v4-core` repo meta + branch list + `compare/Uniswap:main...trailofbits:add-stateful-properties` | GitHub API | ToB's v4 property suite: 35 files, 13 commits ahead |
| `trailofbits/v4-core@add-stateful-properties`: `test/trailofbits/README.md`, `ShadowAccounting.sol`, `actionprops/SwapActionProps.sol`, `medusa.json` | `curl` raw | **What ToB's properties assert, and whether hooks are in scope** |
| `crytic/building-secure-contracts` full tree (311 files) | GitHub trees API, `truncated: false` | Zero Uniswap/v4/hook content |
| `crytic/properties` full tree (155 files) | GitHub trees API, `truncated: false` | ERC20/721/4626/ABDKMath only. No v4, no hook |
| `hknio/uni-v4-hooks-checker` tree + `README.md` + repo meta | GitHub API + `curl` raw | The hook test harness Uniswap itself links to |
| `Certora/uniswap-v4-periphery-cantina-fv` tree | GitHub trees API | Real CVL specs + a mutation corpus for v4-periphery |
| `certora.com/blog/securing-uniswap-v4-part-5` | WebFetch | Certora's published v4 hook rule |
| `uniswapfoundation.org/blog/grant-update-ufsf-adds-16-new-security-providers` | WebFetch | Where Uniswap's security money actually goes |
| GitHub repo search: `certora uniswap v4`, `uniswap v4 hook invariant`, `v4 hook security` | GitHub search API | The field of existing hook-security projects and their star counts |
| `docs/research/data/hook_directory_662.json` (local, 662 rows) | read + scripted | **Nine cohorts of counted evidence on what security-shaped hooks won** |

### Failed / not used

| Attempt | Status |
|---|---|
| `Uniswap/v4-core/docs/security/Known_Effects_of_Hook_Permissions.pdf` | **Downloaded (57,234 B) but NOT READ.** Font-subset encoded; no `pdftotext` on this machine and stream extraction returned only glyph tables. **Its existence is verified; its contents are not. No claim in this document rests on it.** |
| Certora's promised "comprehensive set of CVL rules for the v4-core in an external Git repository" | **UNVERIFIED.** Certora's blog promises it. I scanned 100 repos in the `Certora` org and found `uniswap-v4-periphery-cantina-fv` (periphery, Oct 2024) but no v4-**core** CVL repo. Absence in the org listing is not proof it does not exist elsewhere. |
| The five audit PDFs in `v4-core/docs/security/audits/` (ABDK, Certora, Spearbit, OpenZeppelin, Trail of Bits) | **Filenames and sizes verified; contents not read.** |
| Uniswap Hooks Security Worksheet (Google Sheets) | Not fetched. |
| Devcon "Formal Verification of Uniswap v4 Hooks" talk (DeFi Security Summit 2025) | **UNVERIFIED** — appeared in search results only. Not used. |

---

## 1. TASK A — WHAT FORM OF INVARIANT DOES UNISWAP ACTUALLY REWARD?

**Answer: an audit artifact first, an off-chain property/invariant suite second, an optional formal
spec third. Uniswap has never, in any primary source I can reach, endorsed a runtime on-chain
invariant check inside a hook. Its only runtime-shaped recommendation is a kill switch plus
off-chain anomaly monitoring.**

Four independent lines of evidence converge.

### 1.1 What Uniswap says — the Security Framework

`developers.uniswap.org/docs/protocols/v4/security`, mirrored at
`github.com/uniswapfoundation/security-framework`. This is a **self-assessment worksheet**: nine
risk dimensions, a tier calculation, and a per-tier list of required safeguards. Verbatim:

> "It also provides a consistent rubric for classifying risk tiers and choosing an appropriate
> combination of **audits, monitoring services, bug bounties, and optional formal verification**."

> "The Uniswap Foundation **does not review, audit, or certify** any submissions, scores, or
> implementations derived from it. Use of this framework is voluntary and self-directed."

The named requirements, quoted:

| Where | Verbatim |
|---|---|
| High-risk tier | "Extended test suite recommended including **invariants and stateful fuzzing** *(e.g., delta conservation, fee bounds, no unintended reentrancy, monotonicity of curve functions)*" |
| High-risk tier | "**Mandatory monitoring with anomaly detection.** … identify silent failure modes where math or accounting begins drifting" |
| High-risk tier | "**Optional formal verification** to help validate: Invariant preservation (balance conservation, fee bounds)" |
| Autonomy flag | "**Invariant testing required for accounting logic**" |
| State-machine flag | "**Invariant testing required for state transitions**" |
| Feature triggers | "A hook with a score of 3 but with autonomy, **requires state invariant testing**" |
| Best-practices checklist | "**Invariant & Integration Testing** use invariant and stateful fuzz testing (**e.g., with Foundry or Echidna**) to check properties such as delta conservation, fee bounds, and balance consistency across full PoolManager flows." |
| High-TVL / autonomy | "**Liquidity limits or kill switches should be considered**" |
| OPSEC | "regularly test their **pause or kill-switch** procedures" |

The framework's own **Security Resources** section is the definitive statement of whose tools
Uniswap points hook authors at:

- **Hook libraries:** OpenZeppelin `uniswap-hooks`; OpenZeppelin Uniswap Hooks Contract Wizard
- **Monitoring:** Hypernative; Hexagate
- **Formal verification:** Certora; Halmos; Solidity SMTChecker
- **Audits:** Areta; Spearbit; Code4rena / Cantina; OpenZeppelin
- **Testing tools:** Foundry; Echidna; Diligence Scribble; **Hacken `hknio/uni-v4-hooks-checker`**
- **OPSEC:** Security Alliance framework; Safe; Fireblocks

**There is no entry for a runtime on-chain enforcement library, an attestation, a bond, or a hook
registry.** The one word "runtime" in the entire document attaches to Scribble — an *annotation-based
instrumentation tool for testing*, not a production mechanism.

The framework's §10 "Future Extensions — Community Driven" names what Uniswap would welcome:
"Additional risk dimensions · **Standardized reference hooks** · Shared post-mortems · Community
driven scoring improvements · **Open source testing patterns** · Example design patterns and anti
patterns." Every item is an **off-chain artifact or a document**.

### 1.2 Where the money goes

The **Uniswap Foundation Security Fund**: **$1.2M committed to Areta** to run a marketplace that
**subsidises security audits** for hook teams. 16 providers — 33Audits, Certora, Consensys Diligence,
Cyfrin, Dedaub, Fuzzland, Guardian, Hacken, Mixbytes, OpenZeppelin, Spearbit/Cantina, Trail of Bits,
ABDK, ChainSecurity, Halborn, Zellic. Cohort 1 subsidised nine hook teams.

Uniswap's stated preference is not ambiguous: **it pays for audits.**

### 1.3 What Uniswap actually ships in its own repos — and this is thinner than the docs imply

**`Uniswap/v4-core` (203 files):**
- `echidna.config.yml` exists — and is **a v3 leftover with every meaningful option commented out**
  (only `format`, `checkAsserts`, `coverage`, `dictFreq` are live).
- Echidna targets are **three pure-math library harnesses only**: `SqrtPriceMathEchidnaTest.sol`,
  `TickMathEchidnaTest.sol`, `TickOverflowSafetyEchidnaTest.sol`. No PoolManager, no hook.
- **Echidna does not run in CI.** The complete workflow set is `deploy.yaml`, `lint.yml`,
  `mythx.yml`, `tests-pr.yml`, `tests-merge.yml`. Both test workflows run exactly
  `forge test --isolate -vvv`. Nothing else.
- `mythx.yml` is `workflow_dispatch`-only **and is dead config**: it points at
  `contracts/test/TickBitmapEchidnaTest.sol` etc., and **v4-core has no `contracts/` directory** —
  those are v3 paths. It also names files (`SwapMathEchidnaTest`, `TickEchidnaTest`,
  `TickBitmapEchidnaTest`) that do not exist in this repo.
- Real assurance lives in `docs/security/audits/`: **five audit PDFs** — ABDK, Certora, Spearbit,
  OpenZeppelin, Trail of Bits — plus `docs/security/Known_Effects_of_Hook_Permissions.pdf`.
  *(Filenames verified; contents not read — see PROVENANCE.)*
- Assurance also lives in `snapshots/*.json` — 21 gas-snapshot files enforced in CI via
  `FORGE_SNAPSHOT_CHECK: true`.

**`Uniswap/v4-periphery` (229 files):** grep for `invariant|certora|halmos|echidna|medusa|kontrol`
returns **exactly one file**: `test/ReservesLens.invariant.t.sol`, 86 lines. I read it in full. It
is a **differential correctness** invariant — `ReservesLens.getPoolTVL()` must equal a hand-written
`ReservesReference.aggregate()` over the recorded positions — on a pool initialised with
`IHooks(address(0))`. **It is not a security invariant, and there is no hook in it.**
(Credit where due: it calls `targetContract` as well as `targetSelector` — the §5.7 mistake avoided.)

**Read that honestly: Uniswap's own repos contain less property-based testing than this repo does.**
Uniswap's assurance model is audits + unit tests + gas snapshots. The invariant language in the
Security Framework is advice to *other people*, not a description of Uniswap's own practice.

### 1.4 The formal-verification work that does exist — and who it protects

- **`Certora/uniswap-v4-periphery-cantina-fv`** (Oct 2024): a real Cantina formal-verification
  competition on v4-periphery. `certora/specs/{PositionManager,V4Router}.spec`, harnesses, and a
  **mutation corpus** (`certora/mutations/` — 12 PositionManager mutants, 5 V4Router, 2
  DeltaResolver) used to score whether a spec actually catches injected bugs.
- **Certora's published v4 hook rule**, from `securing-uniswap-v4-part-5`:
  `swap_hook_sender_deltas_sum_is_preserved()` — "the sum of currency deltas of both the hook
  address and the user is preserved and remains equal to the delta in the default case", proved
  against an **arbitrary summarised hook**.

**Note the direction of that rule.** Certora verifies that **PoolManager is safe from arbitrary
hooks**. Nobody in this stack verifies that **a hook is safe**. That is a genuine gap — and §3 is
about why it is still not a submission.

---

## 2. TASK B — THE INCUMBENTS

### 2.1 OpenZeppelin `uniswap-hooks` — the one that matters

126 stars, 53 forks, last push 2026-08-07. **v1.1.1 stable** (2025-11-27); v1.2.1 is a prerelease.
Three audit PDFs in-repo (`OpenZeppelin Uniswap Hooks v1.0.0 RC 1`, `v1.1.0 RC 1`, `v1.1.0 RC 2` —
self-audited). **Named first in Uniswap's own Security Framework**, alongside a Contract Wizard at
`wizard.openzeppelin.com/uniswap-hooks`.

**Complete inventory of what a hook author gets free today** (from the file tree, not a blog):

| Module | Ships |
|---|---|
| `src/base/` | `BaseHook` · `BaseAsyncSwap` · `BaseCustomAccounting` (18 KB) · `BaseCustomCurve` (15 KB) |
| `src/fee/` | `BaseDynamicFee` · `BaseOverrideFee` · `BaseDynamicAfterFee` (11 KB) · `BaseHookFee` |
| `src/general/` | **`AntiSandwichHook`** · **`LiquidityPenaltyHook`** · `LimitOrderHook` (35 KB) · `ReHypothecationHook` (23 KB) |
| `src/oracles/panoptic/` | `BaseOracleHook` · `OracleHookWithV3Adapters` · `V3OracleAdapter` · `V3TruncatedOracleAdapter` · `Oracle` library (18 KB) |
| `src/interfaces/` | `IHookEvents` — a standard event vocabulary for hooks |
| `src/utils/` | `CurrencySettler` — **the only utility.** 3,201 bytes |
| `src/mocks/` | 15 mock hooks for testing |

**`BaseHook` is plumbing, not safety.** Read in full: an `onlyPoolManager` modifier
(`if (msg.sender != address(poolManager)) revert NotPoolManager();`), a constructor-time
`Hooks.validateHookPermissions(hook, getHookPermissions())`, and fourteen callbacks that each
`revert HookNotImplemented()` until overridden. Every one of them is `virtual`. There is **no delta
bound, no extraction ceiling, no invariant hook, no sealed enforcement path.**

**What OZ does NOT ship, verified by exhaustive tree scan:**
- **No invariant tests.** `test/` is 15 unit `.t.sol` files plus `BalanceDeltaAssertions` helpers.
  Zero files matching `invariant`.
- **No fuzzing campaign config.** No `echidna.config.yml`, no `medusa.json`, no `.certora/`, no
  Halmos, no Kontrol — anywhere in the repo.
- **CI is `lint · forge test · coverage · slither · codespell`.** That is the whole assurance stack.
- No bonding, no attestation, no registry, no runtime enforcement.

**The delete test against OZ:** for *composition and correct plumbing*, OZ gives a developer ~100%
today. For *property/invariant assurance of their own hook*, OZ gives them **zero**.

### 2.2 Trail of Bits

**They audited v4-core** (`TrailOfBits_audit_core.pdf`, in `Uniswap/v4-core/docs/security/audits/`;
their public report is `trailofbits/publications/reviews/2024-07-uniswap-v4-core-securityreview.pdf`).

**And they wrote the v4 property suite that everyone else did not.** `trailofbits/v4-core`, branch
**`add-stateful-properties`** (13 commits ahead of upstream, 35 files changed, ~4,000 added lines):

```
test/trailofbits/ActionFuzzBase.sol         328    V4StateMachine.sol            328
                 ActionFuzzEntrypoint.sol   306    ShadowAccounting.sol          112
                 PropertiesHelper.sol       379    IActionsHarness.sol             6
  actionprops/   SwapActionProps.sol        418    ModifyPositionActionProps.sol 285
                 InitializeActionProps.sol  148    DonateActionProps.sol         132
                 SettleActionProps.sol      102    BurnActionProps.sol            96
                 MintActionProps.sol         92    TakeActionProps.sol            92
                 ProtocolFeeActionProps.sol  89    ClearActionProps.sol           71
                 SettleNativeActionProps.sol 56    SyncActionProps.sol            55
  end2end/       EndToEnd.sol 324 · Harness.sol 167 · SwapActor.sol 191 · LiquidityActor.sol 155 · DonationActor.sol 112
+ medusa.json (16 workers, testLimit 200,000,000, callSequenceLength 150) + rewritten echidna.config.yml
```

The technique is **shadow accounting**, in their own NatSpec:

> "the harness maintains its own copy of the system's balances, deltas, and remittances.
> Gas-optimized protocols like v4 often need to perform indirect accounting to save gas, but this
> opens the possibility of an error in that indirect accounting that can be exploited… By
> maintaining our own, direct copy of the accounting, we can compare it to the results of v4's
> indirect accounting to verify the indirect accounting's correctness."

`SwapActionProps.sol` asserts slot0 price/tick monotonicity and bounds, fee-growth arithmetic,
`MIN/MAX_SQRT_PRICE` and `MIN/MAX_TICK` boundaries, and delta sign correctness ("For any swap, the
amount credited to the user is greater than or equal to zero").

**Critical scoping fact, checked in source: this suite targets PoolManager. Hooks are out of scope.**
`SwapActionProps.sol` imports `IHooks` and never asserts anything about a hook. There is no
mechanism to plug a third-party hook into the harness.

**What ToB does NOT ship:**
- `crytic/building-secure-contracts` — **311 files, `truncated: false`, zero matches** for
  `uniswap|v4|hook|amm`. No v4 chapter, no hook guidance, no "not-so-smart" v4 entry.
- `crytic/properties` — **155 files, zero matches.** It ships ERC20 / ERC721 / ERC4626 /
  ABDKMath64x64 property libraries. **There is no `contracts/UniswapV4/` and no hook property set.**

**Delete test against ToB:** for *core-level* v4 property testing, ToB gives ~100% and it is
adaptable. For a *hook author's own invariants*, ToB gives them a technique and a harness that does
not accept their hook.

### 2.3 Everyone else in the space

**Hacken `hknio/uni-v4-hooks-checker`** — **the one Uniswap itself links to.** A Foundry harness:
point `HOOK_ADDRESS` at any hook (local or forked), it parses the address permission bits, checks
they match `getHookPermissions()`, then runs conditional suites: access control (`onlyPoolManager`
on every entry point), delta integrity (`BeforeSwapDelta` handling and settlement accounting), pool
key validation, selector-return correctness, plus swap/liquidity/donate/initialize functional
coverage, a `FuzzTestEntry`, and a `SummaryConsole` report. **7 stars.** Last push 2025-11-27.
*This is the closest existing thing to what `AssaySuite` was, it is shallower, and it already
occupies the officially-endorsed slot.*

**The graveyard.** GitHub repo search surfaces a dense field of near-identical hook-security projects,
**none above 5 stars**: `0xmvercosa/hookrisk` (multi-engine static analysis + differential invariant
fuzzing), `chaosxcode/hookguard` (risk scanner "measured against 306 real deployed hooks"),
`trenysx/HookVault` (15 adversarial scenarios + fuzz + JSON reports + CI), `augusttw/v4-hooks-analyzer`
(CLI security analyzer, 4★), `dngr2/v4-hook-invariants`, `caliperforge/uniswap-v4-invariants`
("recurring bug classes as stateful invariants on real v4"), `dngr2/v4-hookguard`,
`StanleytheGoat/aegis`. **Many people have had this idea. Nobody has traction with it.**

**Monitoring / audit-market incumbents named by Uniswap:** Hypernative and Hexagate (runtime anomaly
detection — the actual commercial answer to "is this hook misbehaving right now"), Areta (the $1.2M
audit marketplace), Spearbit, Code4rena, Cantina.

**No hook insurance product surfaced in any primary source.** In the UHI directory, insurance has
been *attempted* repeatedly (IL Shield, Safu Hook, UniGuard, Confidential IL Insurance Hook) — see §3.

---

## 3. TASK C — THE VERDICT

### 3.1 Nine cohorts of counted evidence

From `hook_directory_662.json`, 662 rows, UHI1–UHI9:

- **75 hooks are tagged `Security`.**
- Of those, the ones whose **product is hook-safety infrastructure** — and every one of their prize
  fields:

| Project | Cohort | Prize |
|---|---|---|
| `AegisHook (Hook Safety as a Service Cross-chain)` | UHI8 | **none** |
| `AegisHook (Hook Safety as a Service Cross-chain)` — resubmitted | UHI9 | **none** |
| `Hook Safety As A Service` ("deterministic onchain firewall for v4 hooks") | UHI8 | **none** |
| `reCEPTION-guard / AI Hook Guard` (detects vulns, scores risk, suggests fixes) | UHI8 | **none** |
| `Vedyx Network` ("decentralized security infrastructure … protects v4 pools") | UHI8 | **none** |
| `Hook Bazaar — Marketplace for Uniswap v4 Hooks` | UHI7 | **none** |
| `Uniroid` ("advanced security and utility hook framework for v4") | UHI4 | **none** |
| `StakeShield` (fraud detection + operator verification in v4 swaps) | UHI3 | **none** |
| `RugGuard` ("real-time protection", DeFi security protocol) | UHI2 | **none** |

**Nine attempts. Zero prizes. Across eight cohorts.**

- The one partial counter-example, stated honestly: **`UniGuard` (UHI3, "Risk management and
  Insurance mechanisms for Uniswap hooks") won the EigenLayer Prize** — a *sponsor* track, on the
  strength of an AVS integration, not the Uniswap or General prize.
- Every *other* security-tagged winner won for something that is **not hook safety**: credential /
  compliance gating (`Satisfy` — Unichain; `kvhook` — Ink), privacy (`FrontrunThis` — Uniswap +
  EigenLayer; `PPR Hook` — Fhenix), **composition** (`modl` — Uniswap; `Bonded Hooks` — Uniswap;
  `Multihook` — Uniswap), IL insurance via FHE+AVS (`Confidential IL Insurance Hook` — Uniswap),
  LP vesting (`Proven Protocol` — Unichain).

Combine with the two facts already established in this repo: **there is no security / tooling / DX
track** (13 prize values, none of them security), and **off-theme infrastructure has never taken the
top prize while off-theme new math has.**

### 3.2 Is there a defensible, unoccupied position?

**There is exactly one genuinely unoccupied technical gap, and it is verified:**

> **Nobody ships a hook-facing stateful invariant suite.** ToB's suite is the real thing and it
> targets PoolManager with hooks out of scope. Hacken's checker accepts a hook but tests conformance
> and access control, not stateful accounting properties. OZ ships no invariant tests at all.
> `crytic/properties` has no v4 entry. Uniswap's framework says invariant testing is **required**
> for accounting logic and for state transitions — and names no artifact that does it for a hook.

That gap is real. **It is not a submission.** Four independent reasons, any one of which is fatal:

1. **It fails Gate 3.** The binary qualification is *"A real Uniswap v4 hook, or a direct interface
   to one."* A property-test library is neither. Miss one gate and it is not judged.
2. **It cannot score 30% Original Idea.** The criterion is "is the idea new to Uniswap or DeFi?" —
   and eight zero-star repos plus one Uniswap-endorsed Hacken harness already answer no.
3. **It fails the delete test outright.** A hook developer today gets: OZ's audited bases (free,
   endorsed), Hacken's hook checker (free, endorsed by Uniswap by name), ToB's shadow-accounting
   harness (free, adaptable, MIT-adjacent), Foundry's native invariant runner (free), and **$1.2M of
   subsidised audit through Areta**. That is well past 80% of the value.
4. **We already built it and it was vacuous.** `AssaySuite` is this product. Audit finding A-2:
   256 runs × 128,000 calls, 46 s of every CI run, and all four invariants structurally incapable of
   failing.

**And the runtime on-chain position — the one thing genuinely unoccupied — is unoccupied because
Uniswap's own published framework routes around it.** That is the decision-relevant finding of this
whole document, and it is the opposite of white space. A judge holding the Security Framework will
ask *"which tier of the worksheet does this satisfy?"* and the honest answer is **none**: the
framework asks for audits, off-chain invariants, monitoring, a bug bounty and a kill switch. It does
not ask for a bonded on-chain assertion, and it does not have a slot for one.

**Answer to C.1: NO. There is no defensible, unoccupied, *submittable* security-shaped position.**

**Answer to C.2:** vacated — there is no mechanism to name that survives C.1.

**Answer to C.3 — what a judge who knows OZ's library and ToB's tooling says, in one sentence:**

> *"OpenZeppelin already gives me the safe base contracts, Trail of Bits already published the
> stateful property harness, the Foundation will pay for my audit, and Uniswap's own framework tells
> me to run Foundry invariants and wire up Hypernative — so what is this for?"*

### 3.3 Recommendation

**The security route is not viable for this submission. Build SWITCHBACK.**

This research does not overturn the standing decision; it removes the last reason to reconsider it.
The owner's hypothesis was right in form and wrong in kind: **Uniswap does like invariants — as an
off-chain artifact produced before deployment and handed to an auditor.** Assay's invariants are
on-chain, at runtime, bonded. Those are different products, and only one of them has a buyer.

**What this research *does* change: it gives the non-submission Assay work a real destination.**
Uniswap's Security Framework §10 "Future Extensions — Community Driven" explicitly names **"open
source testing patterns"** and **"standardized reference hooks"** as wanted contributions. The
verified gap in §3.2 — a hook-facing stateful invariant suite, built on ToB's shadow-accounting
technique, filling the requirement Uniswap states and nobody satisfies — is exactly that. It is a
credible public good, a plausible Uniswap Foundation grant application, and it consumes **none** of
the one submission.

Alongside the two artifacts already scheduled for publication (the permission census, the ERC-6909
delta-laundering finding), that is where the Assay work should go: **published, not submitted.**

---

## 4. FACTS WORTH PROMOTING TO `CLAUDE.md` §5

1. **Uniswap's assurance model is audits + unit tests + gas snapshots.** v4-core CI runs
   `forge test --isolate` and nothing else; its Echidna config is commented-out v3 leftover covering
   three pure-math libraries; its `mythx.yml` points at a `contracts/` directory that does not exist.
   v4-periphery has exactly one invariant test and it is a lens-correctness check on a hookless pool.
   **Never cite "Uniswap uses invariant testing" as support for a runtime-invariant product.**
2. **Uniswap's Security Framework endorses a named stack and we are not in it**: OZ (library),
   Hypernative/Hexagate (monitoring), Certora/Halmos/SMTChecker (FV), Areta/Spearbit/C4/Cantina/OZ
   (audit), Foundry/Echidna/Scribble/Hacken (testing). Zero entries for runtime enforcement,
   bonding, attestation or registry.
3. **Certora verifies PoolManager against arbitrary hooks, not hooks against themselves**
   (`swap_hook_sender_deltas_sum_is_preserved`). The direction matters.
4. **ToB's v4 property suite exists and is excellent — and hooks are out of scope.**
   `trailofbits/v4-core@add-stateful-properties`. If we ever build hook property testing, that is
   the substrate, and **shadow accounting** is the technique to reuse.
5. **Hook-safety-infrastructure is 0-for-9 across eight UHI cohorts.** Counted from the 662-row
   directory. The security-tagged projects that *did* win, won for compliance, privacy or
   composition — never for safety.
