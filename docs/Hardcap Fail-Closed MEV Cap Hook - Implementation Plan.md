# Hardcap Fail-Closed MEV Cap Hook — Sceptic Checklist and Implementation Plan

**Status:** this file is the only plan and source of truth. Do not invent a second design doc. Do not expand scope without editing this file first.

## Overview

This document specifies a security-focused Uniswap v4 hook (“Hardcap”) that enforces an immutable cap on hook-level value extraction and guarantees that any extracted surplus can only be credited to liquidity providers (LPs), while fail-closing against known Uniswap v4 hook exploit patterns. It first applies a sceptic checklist over four critical test cases; conditional on passing these, it outlines a detailed implementation plan, milestones, validation steps, and references.[^1][^2][^3][^4]

## Honest rating of this plan (as of 2026-08-18)

| Axis | Score | Why |
|---|---|---|
| Theme fit (Sustainable Liquidity + MEV Protection) | 3.5 / 5 | Bounds *hook* extraction and JIT hit-and-run. Does **not** kill sandwiches, LVR, or CEX–DEX arb. Liquidity thesis is “LPs can size in because worst-case hook take is printed.” |
| Originality (30% of judging) | 3.5–4 / 5 | Empty-ish lane (executable SDSF/ToB/Cork, not another fee curve). Not a new AMM. Loses if pitched as “yesterday’s LPs get today’s swap fees.” |
| Unique execution (25%) | 4 / 5 **if** Cork + OZ-donate + JIT + vault-drain tests are the demo. 2 / 5 if README-only. |
| Impact (20%) | 3.5 / 5 | Real for “I will not LP a hooked pool after Cork/Bunni.” Not a venue that beats Aerodrome on volume. |
| 3-week shipability | 4 / 5 | No oracle, no searchers, no Flashblocks, no upgrade proxy. Dies if surplus accounting is invented from scratch instead of copying a known `afterSwapReturnDelta` pattern. |
| Honesty of v1 surplus | **Weak unless scoped** | A fixed extra bps on *every* swap is a tax, not MEV recapture. See “Surplus honesty.” |

**Verdict:** proceed as a **security-as-liquidity** hook with four kill tests. Do not upgrade the slogan. Do not add auctions, delays, VPIN, Flashblocks, or an AI agent.

## What this is not (killed in prior review — do not revive)

Do not spend tokens re-deriving these. They are dead unless this file is explicitly amended with new evidence.

- Hermes / off-chain parameter agent / public decision log as the product
- VPIN-as-title (course homework; 57% of 2025 UHI projects were LP/dynamic fee)
- Stock-hours / Robinhood Session AMM (RH sells 24/7; they will not adopt a student hook; stocks ~10% of RH DEX vol)
- Leftover *auction* that needs searchers to bid
- Diamond / generic first-in-block LVR auction (official avoid; 53 prior)
- FlashClear “kill sandwiches on Unichain” (Gogol 2026: sandwiches rare on private-mempool L2s; Flashtestations not production)
- “Donate leftover from sr-AMM” (`donate` pays *current* in-range LPs; failed-sandwich inventory never left the pool)
- Public FairFlow @ start-of-block (= OZ AntiSandwich)
- DualPool + JIT lock (DualPool already blocks external add/remove)
- Fill warranty vs start-of-block (pays every second swap)
- Lottery / Feeling Lucky as the product
- Nezlobin-as-title (taught this cohort)
- am-AMM / delay / TWAMM-first as the *title* (user rejected as overcrowded categories)
- Two OZ hooks on one pool (v4 allows **one hook address** per pool)
- Two-sided Umbra in v1 (OZ left one direction off on purpose)
- On-chain census of every LP at block start (cannot iterate positions)

Official UHI10 white-space (VRF settlement, builder-attested flow, searcher bonds, LP-governed auction) was published to the whole cohort. Do not file those as-is.

## Surplus honesty (read before writing Solidity)

v4 native swap fees accrue inside PoolManager to **whoever is in range during the swap**. Hardcap **cannot** redirect that 0.30% to “yesterday’s LPs” without replacing v4 fee accounting. Do not claim that.

Hardcap only controls **hook take** (return-delta surplus / extra hook fee).

v1 allowed surplus definitions, in order of honesty:

1. **Preferred v1:** `EXTRA_FEE_BPS` immutable, `EXTRA_FEE_BPS <= MAX_TAKE_BPS`. Every swap pays that extra to the LP vault. The cap is a **safety rail** (bug → revert), not a toxicity detector. Pitch: “worst-case hook extraction is `MAX_TAKE_BPS` and the payee is LPs.” Do **not** call this leftover recapture.
2. **Optional v1+ if (1) is green:** surplus = excess vs a **start-of-block** simulated output (OZ AntiSandwich / `BaseDynamicAfterFee` pattern). Still no oracle. Still clamp to cap. Still no `donate()`.
3. **Forbidden in v1:** Chainlink/Pyth CEX gap, VPIN, Nezlobin overlay, manager auction, Flashblock clock.

**Cap vs user swap:** if computed leftover *would* exceed the cap, **clamp take to cap**. Do not revert Alice’s swap because leftover is large. **Revert** only if internal math would credit the vault more than `notional * MAX_TAKE_BPS / 1e4` (bug path).

## Judging constraints (UHI10)

- Weighted score: 30% original / 25% execution / 20% impact / 15% function / 10% pitch.
- Video ≤5 min, **no AI voice** (AI voice = score hit + Demo Day block).
- Tests **or** frontend. Prefer tests. Frontend is optional; do not burn Phase 4 on UI before kill tests are green.
- Testnet deploy is **not** mandatory.
- Returning-team / prior capstone: VPIN repo code does **not** count. All Hardcap code must be new.
- Partner integrations: README must list them or say `No partner integrations.` Do not claim Flashbots/CoW/Aegis unless the code calls them.
- Hookathon window: 17 Aug–3 Sep 2026 23:59 PST; Demo Day 11 Sep 2026.

## Sceptic Checklist — Four Kill Tests

The project only proceeds if a concrete implementation can pass these four classes of tests. Failure on any item kills the project.

### 1. Cork Exploit Fork — Callback and hookData Hardening

**Threat:** Cork Protocol lost ~$11–12M due to missing access control and trusting arbitrary hookData in its Uniswap v4 hook. An attacker called hook callbacks directly and fed malicious hookData to mint claims on real reserves.[^2][^5][^6]

**Required properties for Hardcap:**

- All hook callbacks must be unreachable except via PoolManager. Prefer inheriting `BaseHook` (OZ or v4-periphery), which already gates `msg.sender`; still **test** direct calls. Do not hand-roll a broken `onlyPoolManager`.
- Callbacks to implement in v1 (and only these): `beforeSwap`, `afterSwap` (+ `afterSwapReturnDelta`), `beforeAddLiquidity` or `afterAddLiquidity`, `beforeRemoveLiquidity`. There is **no** `beforeModifyPosition` hook in current v4 `IHooks`. PoolManager’s `modifyLiquidity` dispatches to add vs remove hooks. Params type is `ModifyLiquidityParams` (`tickLower`, `tickUpper`, `liquidityDelta`, `salt`).
- Hook must reject non-empty `hookData` in v1 (`hookData.length == 0` or revert). No business logic may depend on user-provided hookData (Cork class).
- Hook must validate `PoolKey` equals the single immutable configured key (ToB: do not trust a caller-supplied key). v1 is **one pool per hook deployment**.

**Validation plan:**

- Build a minimal Cork-style exploit harness in Foundry: direct calls into hook callbacks and crafted hookData via PoolManager.[^6][^2]
- Assert:
  - Direct calls to callbacks revert.
  - Any swap routed through PoolManager with non-empty `hookData` causes the hook to either revert or ignore `hookData` and maintain correct accounting.
  - Any attempt to use an incorrect `PoolKey` results in revert.

If any of the above assertions fails, the project is killed.

### 2. Extraction Cap Enforcement — `take <= MAX_TAKE_BPS`

**Threat:** Trail of Bits and other security guides show that application-level accounting in hooks can drift while still satisfying PoolManager’s settlement invariants; hooks can silently over-extract value.[^4][^7][^1]

**Required properties for Hardcap:**

- The hook defines an immutable `MAX_TAKE_BPS` constant in the constructor (e.g., 15 basis points).
- On each swap, the hook computes a `computedSurplus` and then sets:
  \(\text{take} = \min(\text{computedSurplus}, \text{notional} \cdot \text{MAX\_TAKE\_BPS} / 10^4)\).
- If computed surplus *exceeds* the cap, **clamp** `take` to the cap (user swap still succeeds). If any code path would *credit* more than the cap, **revert** the unlock (bug). These are different.

**Validation plan:**

- Create unit tests that:
  - Simulate swaps with various `computedSurplus` values (including extreme, overflow, and negative scenarios) and assert `take <= cap` always.
  - Instrument a branch that deliberately tries to set `take > cap` and verify the transaction reverts.
- Fuzz tests over `notional`, `computedSurplus`, and fee parameters to ensure no combination yields `take > cap`.

If any scenario allows `take > MAX_TAKE_BPS * notional / 10^4` without revert, the project is killed.

### 3. JIT Attack Fork — Same-Block Add→Swap→Remove

**Threat:** Umbra’s sandwich-resistant AMM and Uniswap’s own JIT analyses show that same-window/same-block liquidity add→swap→remove patterns remain profitable and harmful to LPs unless explicitly blocked or penalized.[^8][^9]

**Required properties for Hardcap:**

- Track `lastAddBlock[positionKey]`, **not** `lastAddBlock[lp]`. Position key is `Position.calculatePositionKey(owner, tickLower, tickUpper, salt)` (OZ PenaltyHook). The same address can open a second position with a different salt and bypass an address-keyed lock.
- On **any** liquidity increase (`liquidityDelta > 0`), including `increaseLiquidity` on an existing range, update `lastAddBlock` for that key. Honest LPs who top up look like JIT until `OFFSET` elapses. Document this; do not hide it.
- `beforeRemoveLiquidity`: if `block.number == lastAddBlock[positionKey]`, revert.
- Vault `claim` only if `lastAddBlock[positionKey] + OFFSET <= block.number`. `OFFSET` default `1` (same minimum as OZ `MIN_BLOCK_NUMBER_OFFSET`).
- Partial remove then add in the same block still updates last-add; keep the rule local and stupid.

**Validation plan:**

- Build a JIT attack harness: in a single block, LP adds liquidity, executes a high-fee swap, and then attempts to remove liquidity.
- Assert:
  - The removal reverts for same-block add→remove.
  - LP cannot claim vault surplus for positions that have not aged past `OFFSET`.

If same-block add→remove succeeds or JIT positions can claim vault surplus, the project is killed.

### 4. Vault Non-Drainability — Owner Cannot Steal Surplus

**Threat:** Donation-based penalties and miswired vaults can be redirected or drained by malicious owners or in-range attackers, as acknowledged in OpenZeppelin’s LiquidityPenaltyHook audit.[^10][^11]

**Required properties for Hardcap:**

- LP vault must not have any owner-only withdraw function.
- Only LPs with positions that satisfy the ageing rule can call `claim`.
- No other code path can transfer vault funds to arbitrary addresses.

**Validation plan:**

- Static analysis and tests over the vault contract to assert:
  - No function exists that allows owner or arbitrary addresses to withdraw vault balances.
  - Attempts by non-LP or owner addresses to move vault funds revert.
  - The only permitted outflow is pro-rata LP claims.

If any code path allows vault funds to be moved to non-LP addresses or owner, the project is killed.


## Conditional Verdict: Does Hardcap Pass the Sceptic Checklist?

Based on current v4 security guidance, Cork incident analysis, Umbra’s JIT findings, and OpenZeppelin’s audit notes, Hardcap’s proposed design can satisfy all four tests in principle; there is no conceptual blocker or conflicting invariant in v4 that prevents implementing these checks. The remaining risk is execution quality: the implementation must actually bake these properties into code and tests.[^11][^3][^1][^2][^8][^4]

Therefore, the project is allowed to proceed to implementation planning, with the explicit rule that week-1 development focuses solely on making all four sceptic tests pass.


## Design Summary — Hardcap Hook

### Core Idea

Hardcap is a single Uniswap v4 hook attached to a volatile pool that:

- Enforces an immutable cap `MAX_TAKE_BPS` on any surplus value the hook can extract per swap.[^3][^12]
- Credits all extracted surplus to an LP-exclusive vault; no owner withdraw, no donation semantics vulnerable to in-range attackers.[^11][^4]
- Fail-closes against direct callback calls, untrusted hookData, misbound PoolKeys, and same-block JIT add→remove patterns.[^1][^2][^8]

### Behavior at a High Level

- **Normal swaps:** execute as usual; if there is minimal or no surplus (e.g., little arb or priority-fee), `take` is 0 and the hook does nothing beyond enforcing callback access control.
- **Toxic or high-margin flows:** the hook calculates a surplus (in v1 this can be a fixed extra fee in bps) and caps extraction at `MAX_TAKE_BPS` of notional, sending that amount to the LP vault.
- **JIT liquidity:** same-block add→remove reverts, and LP vault claims are restricted to aged positions.
- **Exploits / misconfigurations:** direct callback calls, non-empty hookData, and *bug-path* attempts to credit more than the cap all result in revert. Large leftover is clamped, not used to revert the user.


## Implementation Plan — Phases, Steps, and Milestones

### Phase 0 — Specification and Threat Modeling (2–3 days)

**Goals:** finalize Hardcap spec, align with Uniswap Foundation security frameworks, and document invariants for developers and auditors.[^13][^3][^1]

**Tasks:**

1. **Threat model:**
   - Enumerate adversaries: JIT LPs, sandwich attackers, malicious hook deployer, misconfigured router, and exploiter trying Cork-style callback abuse.[^2][^8][^4]
   - List assets: pool reserves, LP positions, vault surplus.
   - List trusted components: PoolManager, v4 core math, LP vault contract.

2. **Formalize invariants:**
   - Access control: only PoolManager can call hook callbacks; only one configured PoolKey is valid.[^3][^1]
   - Surplus cap: for every swap, `take <= notional * MAX_TAKE_BPS / 1e4` and any attempt to set `take > cap` reverts.
   - Vault exclusivity: vault balances can only be claimed by LPs that meet ageing criteria.
   - JIT block rule: same-block add→remove is forbidden.

3. **Align with SDSF:**
   - Map Hardcap’s behavior to Uniswap v4 Self-Directed Security Framework risk dimensions (access control, external calls, dynamic fees, hookData usage, etc.).[^3]
   - Document that Hardcap deliberately avoids hookData and upgradeability, and treats `BeforeSwapDelta`/`AfterSwapReturnDelta` as controlled extraction paths.

4. **Define v1 surplus logic:**
   - For initial implementation, surplus can be defined as a simple extra fee in bps (e.g., fixed 5 bps on each swap) rather than a complex MEV estimator.[^4][^3]

**Milestone:** `SPEC.md` including threat model, invariants, SDSF mapping, and v1 surplus definition.


### Phase 1 — Contract Skeletons and Access Control (3–4 days)

**Goals:** implement basic Hardcap hook and LP vault contracts with strict access control and no surplus logic yet.

**Tasks:**

1. **Hook contract skeleton:**
   - Inherit `BaseHook` from OpenZeppelin uniswap-hooks or Uniswap `v4-periphery`. Do not implement `IHooks` from scratch.
   - Enable **only** these permission bits (must match mined address): `beforeSwap`, `afterSwap`, `afterSwapReturnDelta`, `beforeAddLiquidity` (or `afterAddLiquidity`), `beforeRemoveLiquidity`.
   - Store immutable `poolManager`, `PoolKey` (or currency0/1 + fee + tickSpacing + hook self-check), `MAX_TAKE_BPS`, `EXTRA_FEE_BPS` (`<= MAX_TAKE_BPS`), `OFFSET`, vault address.
   - **Hook address mining:** deploy via CREATE2 / `HookMiner` so the address flags match `getHookPermissions()`. A flag mismatch means PoolManager never calls you (or calls a function you did not implement → revert). This is a day-1 task, not a deploy surprise.

2. **Callback gating:**
   - Rely on `BaseHook` + explicit tests that raw `hardcap.beforeSwap(...)` reverts.
   - Validate `key.toId()` / currencies against the immutable pool.
   - Revert on `hookData.length != 0`.

3. **LP vault:**
   - Prefer **accounting inside the hook** (balances + claim) over a second privileged contract, unless the vault has **zero** admin. Two contracts = two steal surfaces.
   - No `owner` / `rescue` / `sweep` that can move vault tokens. If a rescue is added later, the project has failed test 4.
   - Do **not** use `poolManager.donate()` to pay LPs.

4. **Foundry environment:**
   - Use official v4-template / OZ hooks remappings. Copy test deploy patterns from OZ hook tests (`Deployers`, `PoolSwapTest`, `PoolModifyLiquidityTest`).
   - Do not write a custom PoolManager mock.

**Milestone:** `HardcapHook.sol` and `LPVault.sol` compile; basic access control tests passing (PoolManager-only, PoolKey binding).


### Phase 2 — Surplus Cap Logic and JIT Rule (3–4 days)

**Goals:** implement surplus calculation, extraction cap enforcement, JIT add→remove rule, and aged LP claim logic.

**Tasks:**

1. **Surplus calculation (v1 = extra hook fee):**
   - `notional` = actual executed input amount from `BalanceDelta` (absolute value of the specified input), **not** `amountSpecified` (partial fills / `sqrtPriceLimit` lie).
   - `computedSurplus = notional * EXTRA_FEE_BPS / 1e4`.
   - Apply via `afterSwap` + `afterSwapReturnDelta` so PoolManager’s CL math still runs. **Do not** use `beforeSwapReturnDelta` to consume the whole swap in v1 (that is a NoOp/custom curve — SDSF high-risk, Bunni-class).
   - **Copy sign conventions** from OZ `BaseDynamicAfterFee` / `FeeTakingHook` / `LPFeeTakingHook` in v4-core test hooks. Do not invent delta signs. User-perspective: negative = user paid.
   - Take in the **input** currency unless a cited OZ pattern says otherwise. Exact-in vs exact-out both need a test.

2. **Cap enforcement:**
   - `take = min(computedSurplus, notional * MAX_TAKE_BPS / 1e4)`.
   - If `take` after min() still `>` cap (overflow / bad cast) → revert.
   - Use `uint256` then `SafeCast` to `int128`. OZ PenaltyHook already does this.

3. **Vault crediting:**
   - Hook keeps the taken amount (return-delta credits the hook; settle into hook-owned balances).
   - Credit `vaultAccrued0/1` or a single surplus token. No `donate()`.

4. **JIT rule:**
   - `afterAddLiquidity` or `beforeAddLiquidity`: if `params.liquidityDelta > 0`, set `lastAddBlock[Position.calculatePositionKey(sender, tickLower, tickUpper, salt)] = block.number`.
   - `beforeRemoveLiquidity`: same key; revert if `block.number == lastAddBlock[key]` (or more generally `block.number < lastAddBlock + OFFSET` if you want PenaltyHook-style window on *exit*, not only same-block).
   - Sender in the callback is the **modifyLiquidity caller** (router), not always the EOA. If tests use `PoolModifyLiquidityTest`, `sender` is the router. Key must use the **position owner** Uniswap uses. Read `Position.calculatePositionKey` and what PoolManager passes as `sender` before coding. **Wrong sender = lock does not bind the real position.** Verify against v4-core `PoolManager.modifyLiquidity` (it keys positions by `msg.sender` of the unlock caller, typically the router). Treat “who is `sender`?” as a week-1 spike, not an assumption.

5. **Aged LP claims:**
   - `claim(tickLower, tickUpper, salt)`: load key from `msg.sender` (the position owner who must call via the same router identity that owns the position — this is awkward). Practical v1: claim is invoked with the same `sender` identity PoolManager used, **or** store shares at add time keyed by `(owner, ticks, salt)` and have the owner claim.
   - Pro-rata denominator = sum of **aged** position notionals you recorded, not current in-range liquidity (that would pay JIT who stayed).
   - Record `shares[positionKey]` at last add (liquidity amount). On claim, `payout = vault * shares[key] / totalAgedShares`.
   - Rounding: last wei can stick in the vault. Do not “sweep” to owner.

**Milestone:** surplus cap and JIT rule implemented; unit tests for cap enforcement and JIT behavior passing.


### Phase 3 — Week-1 Kill Tests Implementation (3–4 days)

**Goals:** implement full sceptic test suite based on Cork, JIT, and vault non-drainability.

**Tasks:**

1. **Cork-style exploit harness:**
   - Fork or emulate Cork’s exploit pattern in tests: direct callback calls, crafted hookData, incorrect PoolKeys.[^6][^2]
   - Assert all such calls revert and no vault surplus is minted.

2. **Cap fuzzing:**
   - Fuzz tests over wide ranges of `notional` and `computedSurplus` to ensure `take` never exceeds cap.
   - Inject deliberate buggy paths and ensure they revert.

3. **JIT attack harness:**
   - Build same-block add→swap→remove transactions in Foundry.
   - Assert removal reverts and JIT LP cannot claim vault surplus.

4. **Vault drain tests:**
   - Attempt to interact with vault via owner or arbitrary addresses.
   - Assert all such attempts fail; only LP claim path succeeds.

**Milestone:** all four sceptic tests green. If any fails by the end of Phase 3, the project is killed.


### Phase 4 — Deployment and Integration Plan (3–4 days)

**Goals:** decide deployment targets, register the hook and pool in public registries, and plan basic frontend/demo.

**Tasks:**

1. **Chain selection:**
   - Choose testnet (e.g., Sepolia or a v4-enabled testnet) for initial deploy.[^15][^14]
   - Decide whether mainnet demo is necessary or whether testnet is sufficient for UHI10.

2. **Hook deployment:**
   - Deploy Hardcap hook contract and LP vault.
   - Initialize one volatile pair pool (e.g., WETH/UNI) via PoolManager with Hardcap attached.[^14]

3. **Registry integration:**
   - Submit hook details to public registries like Uniswap’s `hooklist` and relevant analytics providers.[^16][^17]
   - Document flags, chain ID, and hook behavior clearly.

4. **Demo surface:**
   - Official rule: tests **or** frontend. Prefer a Foundry script that prints the four kill tests over a web UI.
   - If a UI is built at all: swap + vault balance + claim. No marketing dashboard.

**Milestone:** Hardcap compiles and kill tests pass locally; optional testnet deploy; hooklist submission only if there is a real address.


### Phase 5 — Documentation, Video, and Pitch (2–3 days)

**Goals:** produce README, explainer video, and presentation that emphasize security, invariants, and exploit replays over marketing slogans.

**Tasks:**

1. **Technical README:**
   - Explain problem: hooks can over-extract or be exploited; LPs lack worst-case bounds.[^2][^4][^1]
   - Explain mechanism: immutable extraction cap, LP-only vault, fail-closed callbacks, JIT rule.[^3]
   - Include ASCII flows illustrating normal swap, toxic flow, JIT attempt, and Cork-style exploit.
   - Link to SDSF mapping and test results.

2. **Explainer video (≤5 minutes, no AI voice):**
   - Show exploit replays (Cork, JIT) failing on Hardcap.
   - Show how surplus is capped and routed to LP vault.
   - Emphasize on-chain guarantees, not hypothetical adoption.

3. **Pitch framing:**
   - Highlight originality: security-as-liquidity primitive and extraction cap rather than curve tweaks.[^18][^19]
   - Highlight execution: hard tests and exploit forks.[^1][^2]
   - Stay honest about impact: Hardcap does not magically end all MEV but makes hooked pools safer to size into.

**Milestone:** README, video script, and pitch deck complete.


## Implementation gotchas (session-derived — do not rediscover)

These burned review time. Implementers should treat them as given.

### v4 API and deploy
- Hook callbacks are `beforeAddLiquidity` / `afterAddLiquidity` / `beforeRemoveLiquidity` / `afterRemoveLiquidity`, not `beforeModifyPosition`.
- `getHookPermissions()` bits must match the CREATE2 address. Use `HookMiner.find`.
- One hook contract per pool in v1. One hook **address** per `PoolKey`. You cannot attach AntiSandwichHook *and* LiquidityPenaltyHook; merge behavior yourself.
- `BaseHook` already checks PoolManager. Still write the direct-call test (Cork).
- Do not support native ETH in v1 if it adds `msg.value` / refund surface (SDSF token hazards). WETH/USDC-style ERC20 only. No fee-on-transfer, rebasing, ERC-777.

### Accounting
- `amountSpecified` is the request, not the fill. Use `BalanceDelta` from `afterSwap`.
- `afterSwapReturnDelta` is the v1 take path. `beforeSwapReturnDelta` consuming the swap = custom curve = out of scope.
- `poolManager.donate()` is banned. OZ PenaltyHook donates to *current* in-range LPs; a second account at an empty tick can catch the donate on a thin pool (OZ natspec admits this).
- Vault tokens sit on the hook. There is no “yesterday census.” Aged `shares[positionKey]` is the honest approximation.
- Router vs EOA: PoolManager keys positions by the unlock `msg.sender` (usually a periphery router). JIT locks keyed by the user’s EOA will silently not fire. Confirm against `v4-core` `PoolManager.modifyLiquidity` before writing `lastAddBlock`.

### Economics / pitch
- Hardcap does **not** make sandwiches −EV (that is Umbra/OZ, one direction, incomplete). Do not say “kill the sandwich.”
- Do not pitch Unichain-specific sandwich protection (Gogol 2026).
- Do not pitch Robinhood or Uniswap Labs adoption.
- FairFlow (exclusive + signed price), Angstrom (priority-gas tax), Aegis (surge fee), DualPool (vault JIT, external LP blocked) already exist. Hardcap’s difference is **immutable public cap + LP-only payee + fail-closed callbacks**. If the README does not say that in one sentence, the pitch is slop.
- Extra fee on *all* flow hurts the “sustainable **low** fee” theme. Keep `EXTRA_FEE_BPS` small (e.g. 5) and `MAX_TAKE_BPS` the rail (e.g. 15). Say it is a bound, not a toxicity oracle.

### Process
- Week 1 = four kill tests only. No frontend, no second hook, no oracle branch.
- If a kill test is still red at end of Phase 3, **stop**. Do not patch-narrate.
- Video: ≤5 minutes, human voice, exploit replay first, comparison second. No AI voice.
- Tests are sufficient to be judged.

### Suggested Foundry test names (write these first)
- `test_revert_directCallback`
- `test_revert_nonEmptyHookData`
- `test_revert_wrongPoolKey`
- `test_take_clampedToMaxBps`
- `test_take_neverExceedsCap_fuzz`
- `test_revert_sameBlockAddRemove`
- `test_jitCannotClaimVault`
- `test_agedLpCanClaim`
- `test_ownerCannotDrainVault` (no owner function exists)
- `test_increaseLiquidityUpdatesLastAddBlock`
- `test_differentSaltIsDifferentPosition`

## Expert panel review of this plan (honest, no invented data)

**LVR / MEV quant.**  
Hardcap as specified does **not** recapture LVR. A flat extra bps is a transfer from all swappers to aged LPs. That can still help *hook-trust* and JIT fee theft; it does not mark the book to Binance. Do not put “LVR recapture” in the README unless surplus definition (2) (start-of-block excess) is implemented and tested. Theme fit is **partial** and must be sold as extraction-bounded hooked liquidity, not as FairFlow.

**Hook security / ToB / SDSF.**  
The four kill tests match real incidents (Cork, OZ donate, Umbra JIT). Using `BaseHook` + banning `donate` + banning `hookData` + no proxy is the correct SDSF posture (immutability, no external deps, price-impact path is the take). Missing from v1 and acceptable if documented: no formal verification, no second audit, no monitoring. Feature trigger “price impacting behavior” still applies because you take a hook fee — treat `afterSwapReturnDelta` as the dangerous permission and fuzz it. **Do not** add `beforeSwapReturnDelta` in v1.

**Agentic / 2026 hook-AI.**  
Stay out. Aeon/Sentinel/Hermes patterns are the wrong cohort (UHI11 curation) and add an operator.

**Complex systems.**  
The useful homeostasis is fail-closed + a printed cap, not a controller. Do not add autonomous fee updates (SDSF autonomy trigger).

**Crypto primitives.**  
No VRF, no TEE attestations, no FHE. Correct. Flashtestations are not a foundation.

**What is still missing (real gaps, not flavor):**
1. **Position owner vs router `sender`** — must be resolved in Phase 1 with a 20-line spike reading PoolManager, or the JIT lock is fiction.
2. **Claim identity** — same spike; otherwise nobody can claim.
3. **Currency of `take`** on exact-out swaps — needs one test or accounting will leak.
4. **SDSF self-score worksheet** — 30 minutes, required for the README, not a new feature.
5. **Comparison baseline** — one test vs a vanilla pool (same swaps, show extra vault vs no vault) so the video has a number. Do not fabricate APY.

**Panel verdict:** the plan is allowed to proceed. It is a **bounded, security-first hook**, not a category-winning AMM. Quality of the four Foundry replays decides whether it places. Expanding into leftover oracles, Flashblocks, or “yesterday’s fee ownership” is how this becomes slop again.

## Good Practices and References from Uniswap and Security Ecosystem

### Uniswap v4 Security Framework

- Follow Uniswap’s Self-Directed Security Framework to score Hardcap on access control, hookData usage, external calls, fee logic, and upgradeability; document the results.[^3]
- Avoid upgradeable patterns for the hook and vault; prefer immutable constructor configuration.[^7][^3]

### Hook Attack Patterns and Best Practices

- Use Trail of Bits’ “Building secure Uniswap v4 hooks” guidance for callback gating, PoolKey validation, and accounting invariants.[^1]
- Consult broader v4 security guides and audits for patterns like flag bypass, donation griefing, and reentrancy, ensuring Hardcap does not introduce these.[^20][^7][^4]

### JIT and Sandwich Resistance Literature

- Use Umbra’s sr-AMM findings to justify the JIT block rule and ageing-based LP claims.[^8]
- Ensure documentation clearly states that Hardcap is not a full sandwich-resistant AMM but contributes to sustainable liquidity by curbing JIT and bounding hook extraction.

### Registries and Analytics

- Register Hardcap in Uniswap’s `hooklist` with clear metadata: chain, pool, flags, and description.[^17][^16]
- Promote transparent on-chain data so analytics platforms can track Hardcap’s effect on LP returns and surplus distribution.


## Conclusion

Hardcap is a security-first Uniswap v4 hook that aims to make hooked pools safer by bounding **hook-level** extraction and enforcing LP-only surplus distribution, while closing known exploit vectors like Cork-style callbacks, same-block JIT exit, and donation redirection. It is not a sandwich AMM, not FairFlow, and not “yesterday’s LPs get today’s 0.30%.” The sceptic checklist is the path: if the implementation passes the four kill tests, proceed; if any fails, kill the project rather than narrate it.[^8][^2][^11][^1][^3]

---

## References

1. [Building secure Uniswap v4 hooks](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/) - This blog post identifies seven recurring failure patterns in application and hook code, including m...

2. [The $11M Cork Protocol Hack: Uniswap V4 Hook ...](https://dedaub.com/blog/the-11m-cork-protocol-hack-a-critical-lesson-in-uniswap-v4-hook-security/) - On 28th of May 2025, Cork Protocol suffered an $11M exploit due multiple security weaknesses, culmin...

3. [Security Framework | Uniswap Developers](https://developers.uniswap.org/docs/protocols/v4/security) - Evaluate Uniswap v4 hook security risks with a structured framework, scoring model, and operational ...

4. [Uniswap v4 Hook Security: Architecture, Common Vulnerabilities, and Best Practices | KuCoin](https://www.kucoin.com/news/flash/uniswap-v4-hook-security-architecture-common-vulnerabilities-and-best-practices) - Uniswap v4 enables programmable liquidity through Hooks, but due to vulnerabilities such as permissi...

5. [Cork Protocol Incident Analysis](https://www.certik.com/blog/cork-protocol-incident-analysis) - On May 28, 2025, asset-pegged insurance CorK Protocol suffered a ~$12M security breach. The attacker...

6. [0x3 Attack Analysis](https://blocksec.com/blog/cork-protocol-incident-two-independent-flaws-combine-into-one-devastating-exploit-chain) - Cork Protocol exploited on Ethereum, $12M lost due to HIYA manipulation and missing access control i...

7. [Uniswap v4 Security Guide: Hooks, Risks, and Audit Path](https://www.zealynx.io/research/protocol-deep-dives/uniswap-v4) - Uniswap v4 security guide for hook risk, singleton architecture, and flash accounting. See what buil...

8. [A Sandwich-Resistant AMM - Umbra Research](https://umbraresearch.xyz/writings/sandwich-resistant-amm) - With atomic liquidity provisioning, an attacker can still sandwich high-slippage trades by providing...

9. [Our Vision for Uniswap v4](https://blog.uniswap.org/uniswap-v4) - Uniswap v4 brings fast, expressive. Enter hooks, which are plugins to customize how pools, swaps, fe...

10. [OpenZeppelin Uniswap Hooks v1.1.0 RC 2 Audit](https://www.openzeppelin.com/news/openzeppelin-uniswap-hooks-v1.1.0-rc-2-audit) - This audit report details the comprehensive analysis performed on a set of custom Uniswap V4 hooks. ...

11. [OpenZeppelin Uniswap Hooks v1.1.0 RC 1 Audit](https://www.openzeppelin.com/news/openzeppelin-uniswap-hooks-v1.1.0-rc-1-audit) - This audit report details the comprehensive analysis performed on a set of custom Uniswap V4 hooks. ...

12. [BeforeSwapDelta | Uniswap](https://docs.uniswap.org/contracts/v4/reference/core/types/beforeswapdelta) - BeforeSwapDelta is a custom type used in Uniswap V4 hook contracts to represent balance changes duri...

13. [v4-security-foundations — AI agent skill | explainx.ai | explainx.ai](https://explainx.ai/skills/uniswap/uniswap-ai/v4-security-foundations) - Security-first guide for building Uniswap v4 hooks. Hook vulnerabilities can drain user funds—unders...

14. [Overview | Uniswap Developers](https://developers.uniswap.org/docs/protocols/v4/overview) - Navigate Uniswap v4 concepts, framework guidance, and references for protocol integrations.

15. [Uniswap v4](https://v4.uniswap.org/) - Find out more about Uniswap v4: the lowest cost and most customizable version of the Uniswap Protoco...

16. [Uniswap/hooklist: Uniswap V4 hooks registry](https://github.com/Uniswap/hooklist) - A public registry of known Uniswap v4 hook deployments across all supported chains. Each hook file c...

17. [Uniswap V4 Hooks - Allium Documentation Hub](https://docs.allium.so/historical-data/supported-blockchains/evm/core-schemas/dex/uniswap-v4-hooks) - The Uniswap V4 Hooks table records each Uniswap v4 pool at initialization along with the hook contra...

18. [UHI10: Fair Flow Frontier Cohort for MEV Protection and ...](https://www.linkedin.com/posts/atrium-academy1_a-v4-hook-can-capture-arb-value-in-beforeswap-activity-7462170669280067584-D6Gj) - A v4 hook can capture arb value in beforeSwap, route it back to LPs in afterSwap, all in one transac...

19. [Uniswap Hook Incubator: 2025 Wrapped - Atrium Academy](https://blog.atrium.academy/uniswap-hook-incubator-2025-wrapped) - With hooks, we can finally build AMMs that protect liquidity providers while unlocking sustainable o...

20. [Auditing Uniswap V4 Hooks: Risks, Exploits, and Secure Implementation](https://hacken.io/discover/auditing-uniswap-v4-hooks/) - Uniswap V4 Hooks offer unprecedented flexibility for developers, enabling custom logic within liquid...

21. [Gogol et al., How to Serve Your Sandwich? (arXiv:2601.19570)](https://arxiv.org/abs/2601.19570) — sandwiches endemic on L1; rare/unprofitable on private-mempool L2s. Do not pitch Unichain sandwich-killing.

22. [OpenZeppelin AntiSandwichHook.sol (v1.2.0)](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/AntiSandwichHook.sol) — one swap direction only; `_handleCollectedFees` is the inheritor’s problem.

23. [OpenZeppelin LiquidityPenaltyHook.sol (v1.2.0)](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/LiquidityPenaltyHook.sol) — `donate` to current in-range; natspec admits second-account redirect.

24. [Kyber FairFlow](https://blog.kyberswap.com/introducing-fairflow/) — exclusive router leftover skim; not Hardcap.

25. [Angstrom L2](https://docs.angstrom.xyz/l2/intro) — priority-fee tax; not Hardcap.

26. [DualPool hook](https://blog.uniswap.org/dualpool-hook-is-now-live) — Labs+Spark vault JIT; already blocks external LP; do not clone.

27. [Umbra sandwich-resistant AMM](https://www.umbraresearch.xyz/writings/sandwich-resistant-amm) — JIT hole still open; Hardcap only takes the same-block remove revert, not full sr-AMM.

28. [Atrium 2025 Wrapped / UHI10 theme](https://blog.atrium.academy/uniswap-hook-incubator-2025-wrapped) — Fair Flow Frontier; official avoid FHE and generic LVR auctions.

29. [Uniswap hooklist](https://github.com/Uniswap/hooklist) — registry only; not routing allowlist.

30. [v4-core IHooks / PoolManager](https://github.com/Uniswap/v4-core) — callback names, `ModifyLiquidityParams`, position keying by unlock sender.

