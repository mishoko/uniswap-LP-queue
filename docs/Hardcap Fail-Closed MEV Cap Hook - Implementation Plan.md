# Hardcap Fail-Closed MEV Cap Hook — Sceptic Checklist and Implementation Plan

## Overview

This document specifies a security-focused Uniswap v4 hook (“Hardcap”) that enforces an immutable cap on hook-level value extraction and guarantees that any extracted surplus can only be credited to liquidity providers (LPs), while fail-closing against known Uniswap v4 hook exploit patterns. It first applies a sceptic checklist over four critical test cases; conditional on passing these, it outlines a detailed implementation plan, milestones, validation steps, and references.[^1][^2][^3][^4]

## Sceptic Checklist — Four Kill Tests

The project only proceeds if a concrete implementation can pass these four classes of tests. Failure on any item kills the project.

### 1. Cork Exploit Fork — Callback and hookData Hardening

**Threat:** Cork Protocol lost ~$11–12M due to missing access control and trusting arbitrary hookData in its Uniswap v4 hook. An attacker called hook callbacks directly and fed malicious hookData to mint claims on real reserves.[^2][^5][^6]

**Required properties for Hardcap:**

- All hook callbacks (`beforeSwap`, `afterSwap`, `beforeModifyPosition`, etc.) must enforce `require(msg.sender == address(poolManager))`.
- Hook must reject or ignore non-empty `hookData` entirely in v1; no business logic may depend on user-provided hookData.
- Hook must validate the `PoolKey` to ensure it only operates on the configured pool.

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
- If internal math attempts to set `take > cap`, the hook must revert; no unlock or surplus transfer occurs.

**Validation plan:**

- Create unit tests that:
  - Simulate swaps with various `computedSurplus` values (including extreme, overflow, and negative scenarios) and assert `take <= cap` always.
  - Instrument a branch that deliberately tries to set `take > cap` and verify the transaction reverts.
- Fuzz tests over `notional`, `computedSurplus`, and fee parameters to ensure no combination yields `take > cap`.

If any scenario allows `take > MAX_TAKE_BPS * notional / 10^4` without revert, the project is killed.

### 3. JIT Attack Fork — Same-Block Add→Swap→Remove

**Threat:** Umbra’s sandwich-resistant AMM and Uniswap’s own JIT analyses show that same-window/same-block liquidity add→swap→remove patterns remain profitable and harmful to LPs unless explicitly blocked or penalized.[^8][^9]

**Required properties for Hardcap:**

- The hook tracks `lastAddBlock[lp]` for LP positions.
- `beforeRemoveLiquidity` enforces that if `block.number == lastAddBlock[lp]`, the removal reverts.
- Vault surplus must not be payable to short-lived JIT positions.

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
- **Exploits / misconfigurations:** direct callback calls, non-empty hookData, and attempts to exceed the extraction cap all result in revert.


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
   - Implement v4 hook interface with `beforeSwap`, `afterSwap`, `beforeModifyPosition`, `afterModifyPosition`, and any other required callbacks.[^14][^12]
   - Store immutable `poolManager` and `PoolKey` in the constructor.
   - Store immutable `MAX_TAKE_BPS` and LP vault address.

2. **Callback gating:**
   - Add `require(msg.sender == address(poolManager))` in every callback.[^1][^3]
   - Validate `PoolKey` on relevant callbacks.
   - Reject or ignore non-empty `hookData`.

3. **LP vault skeleton:**
   - Implement a simple ERC-20-like vault or accounting structure that tracks surplus attributable to the pool.
   - No `owner` or `admin` withdraw functions.
   - Implement an `onlyLP`-style modifier based on LP positions for later use in `claim`.

4. **Foundry environment:**
   - Set up Foundry with v4-core / v4-periphery dependencies and basic test harness for hooks.[^15][^14]

**Milestone:** `HardcapHook.sol` and `LPVault.sol` compile; basic access control tests passing (PoolManager-only, PoolKey binding).


### Phase 2 — Surplus Cap Logic and JIT Rule (3–4 days)

**Goals:** implement surplus calculation, extraction cap enforcement, JIT add→remove rule, and aged LP claim logic.

**Tasks:**

1. **Surplus calculation:**
   - Implement a v1 version where `computedSurplus = notional * EXTRA_FEE_BPS / 1e4` for a fixed `EXTRA_FEE_BPS`.
   - Use `AfterSwapReturnDelta` or equivalent to apply surplus without disrupting core swap math.[^12][^3]

2. **Cap enforcement:**
   - Set `take = min(computedSurplus, notional * MAX_TAKE_BPS / 1e4)`.
   - Add safety checks: if any path tries to set `take > cap`, revert.

3. **Vault crediting:**
   - Add internal function to credit `take` amount to LP vault.
   - Ensure no donation calls (`poolManager.donate()`) to avoid second-account redirect risks.[^11]

4. **JIT rule:**
   - Track `lastAddBlock[lp]` on `beforeModifyPosition` when adding liquidity.
   - In `beforeRemoveLiquidity`, if `block.number == lastAddBlock[lp]`, revert.

5. **Aged LP claims:**
   - Implement `claim()` that allows LPs with positions where `lastAddBlock + OFFSET <= block.number` to withdraw pro-rata vault surplus.

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

4. **Simple frontend/demo:**
   - Implement a minimal frontend showing:
     - Swaps into the Hardcap pool.
     - Vault balance growth from surplus.
     - LP claim interface with ageing rule.
   - Include visual traces of JIT and Cork-attack attempts failing.

**Milestone:** Hardcap deployed on testnet with one pool; registry entries created; basic frontend operational.


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

Hardcap is a security-first Uniswap v4 hook that aims to make hooked pools safer by bounding hook-level extraction and enforcing LP-only surplus distribution, while closing known exploit vectors like Cork-style callbacks, JIT liquidity, and donation redirection. The sceptic checklist and implementation plan in this document define a concrete path: if the implementation passes the four kill tests, the project proceeds; if any fails, the project is honestly killed rather than patched into another fragile hook.[^8][^2][^11][^1][^3]

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

