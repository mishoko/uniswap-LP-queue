> [!WARNING]
> **SUPERSEDED 2026-08-21 — do not follow the instructions in this file.**
> It describes Hardcap framed as MEV recapture, a framing that was reviewed and withdrawn. Every
> "win goal", "judging product" and "do not build X" instruction below is void. The current plan is
> [`NEXT_SESSION_ASSAY.md`](./NEXT_SESSION_ASSAY.md); start at [`docs/README.md`](./README.md).
> Kept because its v4 mechanics and spike results are still accurate.

# Hardcap Fail-Closed MEV Cap Hook — Sceptic Checklist and Implementation Plan

**Status:** this file is the only **product / scope** plan. Do not invent a second design doc. Do not expand scope without editing this file first.

Spike record (not a second design): [`docs/SPIKE-sender-and-afterSwapReturnDelta.md`](./SPIKE-sender-and-afterSwapReturnDelta.md).

**Phase status (2026-08-18 evening pivot):** v1 rail (5 bps tax) is **implemented and stays as the envelope**. Product for judging is **v1+ ToB-spot claw**. `EXTRA_FEE_BPS = 0`. First swap of a block: take 0. Later in-range swaps that beat the block-open spot: claw `min(excess, cap)` to the aged vault. Tick-crossing swaps: take 0 (no OZ tick walk). Next implementer: [`docs/NEXT_IMPLEMENTER.md`](./NEXT_IMPLEMENTER.md).

**Hackathon odds:** v1 rail cannot take first. Pivot is the official win shape (defense + recapture) without cloning OZ AntiSandwich, DualPool, FairFlow, MRLV (4 signals + 3% fee), or the cohort white-space slide. Still not DualPool. Still not Aerodrome. Highest-EV on-chain path that security firms can respect (no MemoryOOG).

**Must not lie:** (1) tick-crossing sandwiches are not clawed; (2) native 0.30% still goes to in-range LPs; (3) this is not LVR recapture, not leftover auction, not FairFlow.

---

## Overview

This document specifies a security-focused Uniswap v4 hook (“Hardcap”) that enforces an immutable cap on hook-level value extraction and guarantees that any extracted surplus can only be credited to liquidity providers (LPs), while fail-closing against known Uniswap v4 hook exploit patterns.[^1][^2][^3][^4]

It first applies a sceptic checklist over four critical test cases; conditional on passing these, it outlines a detailed implementation plan, milestones, validation steps, and references.

---

## Honest rating of this plan (as of 2026-08-18)

| Axis | Score | Why |
|---|---|---|
| Theme fit (Sustainable Liquidity + MEV Protection) | 3.5 / 5 | Bounds *hook* extraction and JIT hit-and-run. Does **not** kill sandwiches, LVR, or CEX–DEX arb. Liquidity thesis is “LPs can size in because worst-case hook take is printed.” |
| Originality (30% of judging) | 3.5–4 / 5 | Empty-ish lane (executable SDSF/ToB/Cork, not another fee curve). Not a new AMM. Loses if pitched as “yesterday’s LPs get today’s swap fees.” |
| Unique execution (25%) | 4 / 5 **if** Cork + OZ-donate + JIT + vault-drain tests are the demo. 2 / 5 if README-only. |
| Impact (20%) | 3.5 / 5 | Real for “I will not LP a hooked pool after Cork/Bunni.” Not a venue that beats Aerodrome on volume. |
| 3-week shipability | 4 / 5 | No oracle, no searchers, no Flashblocks, no upgrade proxy. Dies if surplus accounting is invented from scratch instead of copying a known `afterSwapReturnDelta` pattern. |
| Honesty of v1 surplus | **Scoped (ToB-spot)** | Tax path remains for envelope tests. Production surplus is backrun-vs-open, not same-dir, not tick-cross. |

**Verdict:** proceed as a **security-as-liquidity** hook with four kill tests. Do not upgrade the slogan. Do not add auctions, delays, VPIN, Flashblocks, or an AI agent.

---

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

Official UHI10 white-space (VRF settlement, builder-attested flow, searcher bonds, LP-governed auction) was published to the whole cohort. Do not file those as-is.[^28]

---

## Surplus honesty (read before writing Solidity)

v4 native swap fees accrue inside `PoolManager` to **whoever is in range during the swap**. Hardcap **cannot** redirect that 0.30% to “yesterday’s LPs” without replacing v4 fee accounting. Do not claim that.[^3]

Hardcap only controls **hook take** (return-delta surplus / extra hook fee).

Surplus definitions:

1. **Shipped v1 (envelope, keep the tests):** `EXTRA_FEE_BPS` tax. Useful as a rail. **Not** the judging product.

2. **Current product (v1+ ToB-spot — this is the pivot):** `EXTRA_FEE_BPS = 0`. Surplus = taker’s unspecified amount beating a **block-open spot quote** computed with `SwapMath.computeSwapStep` on the snapshotted `(sqrtPriceX96, liquidity)` only. **No** `Pool.State` clone, **no** tick-bitmap walk (OZ AntiSandwich MemoryOOG). If **this swap** crossed a tick, surplus = 0. `take = min(surplus, notional * MAX_TAKE_BPS / 1e4)`. First swap of the block: take = 0 (snapshot only). Both directions. Still no oracle. Still no `donate()`.[^22][^23]

3. **Forbidden:** Chainlink/Pyth CEX gap, VPIN, Nezlobin overlay, manager auction, Flashblock clock, OZ tick-walk ToB, 4-signal “MEV detector” (MRLV), leftover *auction*.

**Cap vs user swap:** if computed leftover *would* exceed the cap, **clamp take to cap**. Do not revert Alice’s swap because leftover is large. **Revert** only if internal math would credit the vault more than `notional * MAX_TAKE_BPS / 1e4` (bug path).

---

## v1+ ToB-spot (judging product — required)

Keep the Hardcap envelope. Change only surplus.

**State (one pool):** `openBlock`, `openSqrtPriceX96`, `openLiquidity`, `openTick`. Transient per-swap: `swapStartTick`.

**`_beforeSwap`:** Cork checks. If `openBlock != block.number`, snapshot `getSlot0` + `getLiquidity` → open*. Always store `swapStartTick = current tick`. Return zero `BeforeSwapDelta`. No fee override.

**`_afterSwap`:** Cork checks. `notional = abs(unspecified BalanceDelta)` (spike). If this is the first swap of the block → take 0. If `slot0.tick != swapStartTick` → take 0 (this swap crossed). If `getLiquidity() != openLiquidity` → take 0 (book changed; quote is a lie). Else quote unspecified at `(openSqrtPriceX96, openLiquidity)` via **one** `SwapMath.computeSwapStep` toward the open tick’s boundary (if the step would consume the boundary before filling, treat as would-cross-at-open → take 0).  
`surplus = max(0, actualUnspecified − target)` on exact-in output, or `max(0, target − actualUnspecified)` on exact-out input.  
`take = min(surplus, cap)`. Settle like FeeTakingHook.

**Kill tests (new — FAIL = stop):**

- `test_tob_firstSwapInBlock_takeIsZero`
- `test_tob_secondSwapSameDir_inRange_clawsExcess` — **name kept; assertion is take = 0.** Same-dir cannot beat the open quote (price already moved against the taker). Do not invent surplus.
- `test_tob_backrunOppositeDir_inRange_clawsExcess` — this is the real claw (classic backrun, stays in-tick).
- `test_tob_sizeMatchedSandwich_takeIsZero` — dump + equal opposite recrosses; **not** clawed. Honesty test.
- `test_tob_tickCross_takeIsZero`
- `test_tob_liquidityChangedSinceOpen_takeIsZero`
- `test_tob_bothDirections`
- `test_tob_largeExcess_clampedUserSwapSucceeds`
- All existing Cork / cap-rail / JIT / vault tests stay green (`extraFeeBps > 0` keeps the tax path for those tests; cap-rail still uses `HardcapOverSurplusHook` / `HardcapBugTakeHook`).

**Pitch:** “First swap of the block is vanilla. Same-block in-range fills better than the open are clawed to aged LPs, at most `MAX_TAKE_BPS`. Cork cannot call us. We do not walk ticks.”

### Spike answers (2026-08-19, Variant A shipped — do not rediscover)

Read `SwapMath.computeSwapStep` + `test/libraries/SwapMath.t.sol` + `Pool.swap` in this repo's v4-core.

| Arg | Decision | Why |
|---|---|---|
| `sqrtPriceCurrentX96` | `openSqrtPriceX96` | Block-open snapshot, not current spot |
| `sqrtPriceTargetX96` | `TickMath.getSqrtPriceAtTick(openTick ± tickSpacing)` | Direction is **inferred** (`current >= target` ⇒ zeroForOne). Do not pass a direction flag. |
| `liquidity` | `openLiquidity` | If live L changed, skip (quote is a lie) |
| `amountRemaining` | executed specified `BalanceDelta`, same sign as `amountSpecified` | Request lies on partial fills |
| `feePips` | `PoolKey.fee` (**3000** = 0.30% = 3000/1e6) | Include LP fee. Omit-fee **under-claws** exact-in (`targetOut` inflates). The brief's "omit-fee ⇒ phantom surplus" is backwards for this surplus formula. |
| would-cross | `sqrtPriceNextX96 == target` | Step hit the open-tick spaced boundary before filling |
| exact-in target | `amountOut` | Unspecified is output |
| exact-out target | `amountIn + feeAmount` | Unspecified is input; Pool.sol charges both |

**Honesty the named DoD test gets wrong:** a second **same-direction** swap cannot beat the open quote (price is monotonic). `test_tob_secondSwapSameDir_inRange_clawsExcess` asserts take = 0. The claw is `test_tob_backrunOppositeDir_inRange_clawsExcess`. Do not invent same-dir surplus.

**Tick-cross skip is tight:** any `zeroForOne` from an exact tick bound (`SQRT_PRICE_1_1` = tick 0 lower edge) decrements `slot0.tick`. A 1e16 backrun after a 1e16 dump from 1:1 recrosses. Claw sizes in tests are `DUMP=1e18` then `CLAW=1e15` so the *second* swap stays in-tick. Tick-crossing sandwiches are not clawed. That is the product, not a bug.

Variant A works. B/C not used.

---

## v1 Scope Hard Cap (non-negotiable)

To keep this buildable in 3 weeks and auditably safe:

- No multi-claim per position (v1 = single claim per position key).
- No oracles, no off-chain analytics, no CEX price feeds.
- No Flashblocks, Flashtestations, or chain-specific mempool tricks.
- No AI agents, governance controllers, or auto-tuning of `EXTRA_FEE_BPS`.

---

## Vault accounting — now required (review catch, 2026-08-18)

The first hook incrementing `shares` on add and never writing on remove **failed the vault kill**. An exited position could still `claim`. Recycle could stack rights. An unaged add could dilute an in-flight claim.

These are **requirements**, not style. If any is missing, vault exclusivity is FAIL.

| Requirement | Original plan expectation? | Status |
|---|---|---|
| New liquidity is **pending** until `OFFSET`. `_sync` lazy-matures that key on the next touch. | Implied (“denominator over aged positions”) but **not specified** as a pending bucket. First code put all L into `totalShares` immediately. | **Required. Implemented.** |
| Claim **receipt** is aged-only. Claim **weight** is all live L (`totalShares + pendingTotal`). | “Aged denom only” is **not implementable** without iterating every position (`_sync` is per-key). Lazy aged-only denom lets the first claimer take 100% of other aged LPs who have not been touched. Two aged lockers must split. | **Required. Implemented.** |
| Remove burns matured first, then pending (`_burnRights`). Full exit zeros both buckets. | Remove used to write matured only. Safe today only because `_sync` runs first. A later “same-block-only” JIT would reopen claim-after-exit. | **Required. Implemented.** |
| Claim pays `min(recorded shares, live position L)`. Ghost shares cannot over-claim. | Asymmetry: claim read shares, never read PoolManager L. | **Required. Implemented.** |
| `test_fullRemoveBurnsSharesCannotClaim` | **No** — added because the first suite could not see the hole. | **Required. Passing.** |
| `test_recycleDoesNotStackShares` | **No** — same. | **Required. Passing.** |
| `test_twoAgedLockersSplitVault` | Plan said pro-rata LP claims. First suite was one locker. | **Required. Passing.** |
| `test_unagedDilutesButCannotClaim` | Replaces `test_unagedAddDoesNotDiluteAgedClaim`. Unaged L is in the weight (cannot iterate to exclude it) but cannot receive. | **Required. Passing.** |

Do not revert to “shares += L on add, never burn.” That is the 1-wei-then-dump hole inverted.

Share **unit** remains `liquidityDelta` (L), not token notional. That was the plan. Tight-range L-per-token inflation is a **known weakness**, not a second unit. See below.

---

## Known v1 weaknesses (do not sell past these)

These are **accepted**. They are not bugs to “fix” into a new product. README and pitch must stay inside this list.

| Weakness | Why it stays |
|---|---|
| 5 bps on every swap is a **tax**. | **No longer the judging product.** `EXTRA_FEE_BPS = 0`. ToB-spot is. |
| Tick-crossing sandwiches are **not** clawed. Size-matched dump+backrun recrosses. | Honest skip. No OZ tick walk. |
| A same-block 1-wei add after the open snapshot sets `getLiquidity() != openL` and blinds ToB for the rest of the block. | Spec: L change ⇒ quote is a lie ⇒ take 0. JIT still cannot exit. Do not invent a materiality threshold. |
| JIT lock does **not** take the native 0.30%. A one-block LP still earns in-range fees. We only block same-block **exit** and **vault claim**. | v4 fee accounting is inside PoolManager. Hardcap cannot redirect it. |
| `OFFSET = 1`. An LP who stays one block **and is still in the pool** can claim a capital-weighted slice. That is the model, not a lockup. | Same minimum as OZ `MIN_BLOCK_NUMBER_OFFSET`. Raising OFFSET is a parameter change, not a new feature, but do not market it as time-weighted. |
| Share unit is `liquidityDelta`, not token notional. A tight-range position mints more L per token. | Plan said use L. Do not invent a second unit in v1. |
| v1 `claim` is the **locker** (unlock caller), not the EOA behind a router. | Spike. Documented and tested (`test_claimRequiresPositionOwnerNotEoa`). |
| Template `.gitignore` ignored `docs/`. | Process. Removed from `.gitignore`. Keep `docs/` committable. |

---

## Outstanding (not required to call v1 product-done)

Do not add items here without editing this file. Do **not** start video or transcripts.

| Item | Why it is still open | Required for v1 product? |
|---|---|---|
| Testnet deploy + hooklist | Needs RPC, keys, a real address. UHI10 does not require testnet. | No |
| Tight-range L inflation documentation test | Known weakness. Do not change the share unit. | No |
| Formal verification / second audit / monitoring | SDSF optional at this TVL. | No |
| Human-voice demo recording | Gate 1. After ToB-spot is green. Human voice only. | Yes before 3 Sep |
| ToB-spot implementation | **Done (Variant A).** Envelope green. Same-dir does not claw (honest). | Shipped |

---

## How Hardcap Is Used and By Whom

v4 rule: **each pool has exactly one hook address.** A protocol that also wants limit orders, DualPool vaults, or a custom curve cannot “add Hardcap beside” those. They either inherit Hardcap and merge callbacks, or they do not use Hardcap. There is no hook middleware bus in v4-core.[^3]

### Who would attach this hook as-is (no extra features)

These users want a **pool**, not a library:

| User | Why they would bother | Why security alone can be enough |
|---|---|---|
| LP / vault curator on a volatile pair | After Cork (~$11–12M) and Bunni (~$8.4M), “the hook can take unbounded value or get exploited” is a reason **not** to deposit. A printed `MAX_TAKE_BPS` and no owner drain is a number they can underwrite. | Yes, if they were going to use a **vanilla** or lightly customized pool anyway. Hardcap replaces the hook slot. |
| Token / memecoin launcher | They already lock LP (pools.trade, Doppler). They still get blamed for a malicious or buggy hook. Immutable cap + fail-closed callbacks is a cheap “we cannot silently raise take to 50%” story. | Yes for simple launch pools that do not need a second hook. |
| Integrator who is afraid of their **own** hook | Teams shipping return-delta / extra fees. SDSF says those paths extract. Hardcap is the fee path with a hard ceiling and LP-only payee. | Yes if their product **is** “take a bit, give it to LPs, don’t steal.” |
| UHI judges / demo | Replay Cork + JIT + vault drain. | N/A |

Security is **enough** when the alternative is: no hook, or a hook they wrote themselves with the same attack surface and no cap. It is **not** enough when the protocol’s product is DualPool, a custom curve, UniswapX-only flow, or Kyber-exclusive FairFlow. Those already occupy the single hook slot. They will not drop DualPool to get Hardcap.

Honest limit: Hardcap does not make sandwiches −EV, does not recapture CEX–DEX LVR, and a 5 bps extra on all flow is a tax. Users who want “beat Aerodrome” will not pick this over Angstrom/FairFlow/Aegis. Users who want “this hook cannot Cork us and cannot raise take” might.

### How people start v4 hooks today (checked)

Official path is **not** “npm install a production hook and compose.” It is:

1. Clone [uniswapfoundation/v4-template](https://github.com/uniswapfoundation/v4-template) (Foundry + v4-core + periphery, example `Counter.sol`).[^14]
2. `import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol"` (or OZ `BaseHook`). Implement `getHookPermissions` + internal `_beforeSwap` / `_afterSwap`.[^1]
3. Mine CREATE2 address so flags match. Deploy. `initialize` a pool with `hooks = that address`.

OpenZeppelin’s library is the same shape: inherit `BaseHook`, optionally `BaseDynamicAfterFee`, not a diamond proxy of many hooks.

So Hardcap should ship the **same way as v4-template + OZ general hooks**:

| Mode | Who | How |
|---|---|---|
| **A. Attach as the pool hook** | Launchers, simple volatile pools, the UHI demo | Deploy `HardcapHook`, mine flags, `initialize(poolKey with hook=Hardcap)`. Same as attaching `Counter` or `AntiSandwichHook`. |
| **B. Inherit as a base (the real reuse path)** | Teams that need *another* feature | `contract MyHook is HardcapHook { ... }` override `_afterSwap` / liquidity hooks, call `super`, **never** widen take above `MAX_TAKE_BPS`, never add `owner.withdraw`, never honor `hookData` unless they accept leaving Hardcap’s threat model. Re-mine address if permissions bits change. |
| **C. Copy-paste the four checks** | Teams already committed to another parent (DualPool, custom curve) | They will not use Hardcap as the hook. They can copy I1–I6 (only PoolManager, ignore hookData, validate PoolKey, cap take, no donate, JIT exit revert). That is a checklist, not this product. Do not pretend C is Hardcap. |

v1 of **this repo** is mode A: one deployable hook, tests, README. Mode B is the intended post-hackathon shape (abstract `HardcapHook` + `HardcapHookFinal` that only sets constants). Do not build a HookManager or multi-hook router in v1 (not in v4-core; SDSF complexity).

### When they should **not** use Hardcap

- They need DualPool / custom curve / TWAMM / limit orders as the hook — inherit or don’t use Hardcap.
- They need `hookData` for permits, referrers, or protect flags — v1 rejects nonempty `hookData`. Forking that back in undoes Cork hardening.
- They want native ETH, fee-on-transfer, or multi-pool one hook — out of v1 scope.
- They think attaching Hardcap *and* their hook works. It does not.

### Product sentence for README

“Hardcap is a **pool hook you attach like any v4-template hook**, and a **base contract you inherit if you must add features**. It is not a second hook you compose at the PoolManager. Use it when the main risk you care about is unbounded hook extraction and callback trust, not when you need a different AMM.”
- No second chain; one v4-enabled chain is enough.
- No router integration beyond the minimal patterns tested in Foundry.
- No admin controls or upgradability; new behavior requires new deployments.

If any of the above is needed, this document must be edited first and the risk re-scored.

---

## Judging constraints (UHI10)

- Weighted score: 30% original / 25% execution / 20% impact / 15% function / 10% pitch.[^28]
- Video ≤5 min, **no AI voice** (AI voice = score hit + Demo Day block).
- Tests **or** frontend. Prefer tests. Frontend is optional; do not burn Phase 4 on UI before kill tests are green.
- Testnet deploy is **not** mandatory.
- Returning-team / prior capstone: VPIN repo code does **not** count. All Hardcap code must be new.
- Partner integrations: README must list them or say `No partner integrations.` Do not claim Flashbots/CoW/Aegis unless the code calls them.
- Hookathon window: 17 Aug–3 Sep 2026 23:59 PST; Demo Day 11 Sep 2026.

---

## Sceptic Checklist — Four Kill Tests

The project only proceeds if a concrete implementation can pass these four classes of tests. Failure on any item kills the project.

### 1. Cork Exploit Fork — Callback and hookData Hardening

**Threat:** Cork Protocol lost ~$11–12M due to missing access control and trusting arbitrary hookData in its Uniswap v4 hook. An attacker called hook callbacks directly and fed malicious hookData to mint claims on real reserves.[^2][^5][^6]

**Required properties for Hardcap:**

- All hook callbacks must be unreachable except via `PoolManager`. Prefer inheriting `BaseHook` (OZ or v4-periphery), which already gates `msg.sender`; still **test** direct calls. Do not hand-roll a broken `onlyPoolManager`.[^1][^7][^51]
- Callbacks to implement in v1 (and only these): `beforeSwap`, `afterSwap` (+ `afterSwapReturnDelta`), `beforeAddLiquidity` or `afterAddLiquidity`, `beforeRemoveLiquidity`. There is **no** `beforeModifyPosition` hook in current v4 `IHooks`. `PoolManager.modifyLiquidity` dispatches to add vs remove hooks. Params type is `ModifyLiquidityParams` (`tickLower`, `tickUpper`, `liquidityDelta`, `salt`).[^30]
- Hook must reject non-empty `hookData` in v1 (`hookData.length == 0` or revert). No business logic may depend on user-provided `hookData` (Cork class).
- Hook must validate `PoolKey` equals the single immutable configured key (ToB: do not trust a caller-supplied key). v1 is **one pool per hook deployment**.[^1][^51]

**Validation plan:**

- Build a minimal Cork-style exploit harness in Foundry: direct calls into hook callbacks and crafted `hookData` via `PoolManager`.[^6][^2]
- Assert:
  - Direct calls to callbacks revert.
  - Any swap routed through `PoolManager` with non-empty `hookData` causes the hook to either revert or ignore `hookData` and maintain correct accounting.
  - Any attempt to use an incorrect `PoolKey` results in revert.

If any of the above assertions fails, the project is killed.

---

### 2. Extraction Cap Enforcement — `take <= MAX_TAKE_BPS`

**Threat:** Trail of Bits and other security guides show that application-level accounting in hooks can drift while still satisfying `PoolManager`’s settlement invariants; hooks can silently over-extract value.[^4][^7][^1]

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

---

### 3. JIT Attack Fork — Same-Block Add→Swap→Remove

**Threat:** Umbra’s sandwich-resistant AMM and Uniswap’s own JIT analyses show that same-window/same-block liquidity add→swap→remove patterns remain profitable and harmful to LPs unless explicitly blocked or penalized.[^8][^9]

**Required properties for Hardcap:**

- Track `lastAddBlock[positionKey]`, **not** `lastAddBlock[lp]`. Position key is `Position.calculatePositionKey(owner, tickLower, tickUpper, salt)` (OZ PenaltyHook). The same address can open a second position with a different salt and bypass an address-keyed lock.[^23][^30]
- On **any** liquidity increase (`liquidityDelta > 0`), including `increaseLiquidity` on an existing range, update `lastAddBlock` for that key. Honest LPs who top up look like JIT until `OFFSET` elapses. Document this; do not hide it.
- `beforeRemoveLiquidity`: if `block.number == lastAddBlock[positionKey]`, revert. (Generalizing to `block.number < lastAddBlock + OFFSET` is allowed if you want a window.)
- Vault `claim` only if `lastAddBlock[positionKey] + OFFSET <= block.number`. `OFFSET` default `1` (same minimum as OZ `MIN_BLOCK_NUMBER_OFFSET`).[^23]
- Partial remove then add in the same block still updates `lastAddBlock`; keep the rule local and dumb.

**Validation plan:**

- Build a JIT attack harness: in a single block, LP adds liquidity, executes a high-fee swap, and then attempts to remove liquidity.
- Assert:
  - The removal reverts for same-block add→remove.
  - LP cannot claim vault surplus for positions that have not aged past `OFFSET`.

If same-block add→remove succeeds or JIT positions can claim vault surplus, the project is killed.

---

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

---

## Conditional Verdict: Does Hardcap Pass the Sceptic Checklist?

Based on current v4 security guidance, Cork incident analysis, Umbra’s JIT findings, and OpenZeppelin’s audit notes, Hardcap’s proposed design can satisfy all four tests in principle; there is no conceptual blocker or conflicting invariant in v4 that prevents implementing these checks. The remaining risk is execution quality: the implementation must actually bake these properties into code and tests.[^11][^3][^1][^2][^8][^4]

Therefore, the project is allowed to proceed to implementation planning, with the explicit rule that week-1 development focuses solely on making all four sceptic tests pass.

---

## Design Summary — Hardcap Hook

### Core Idea

Hardcap is a single Uniswap v4 hook attached to a volatile pool that:

- Enforces an immutable cap `MAX_TAKE_BPS` on any surplus value the hook can extract per swap.[^3][^12]
- Credits all extracted surplus to an LP-exclusive vault; no owner withdraw, no donation semantics vulnerable to in-range attackers.[^11][^4]
- Fail-closes against direct callback calls, untrusted `hookData`, misbound `PoolKey`s, and same-block JIT add→remove patterns.[^1][^2][^8]

### Behavior at a High Level

- **Normal swaps:** execute as usual; if there is minimal or no surplus (e.g., little arb or priority-fee), `take` is 0 and the hook does nothing beyond enforcing callback access control.
- **Toxic or high-margin flows:** the hook calculates a surplus (in v1 this can be a fixed extra fee in bps) and caps extraction at `MAX_TAKE_BPS` of notional, sending that amount to the LP vault.
- **JIT liquidity:** same-block add→remove reverts, and LP vault claims are restricted to aged positions.
- **Exploits / misconfigurations:** direct callback calls, non-empty `hookData`, and *bug-path* attempts to credit more than the cap all result in revert. Large leftover is clamped, not used to revert the user.

---

## Implementation Plan — Phases, Steps, and Milestones

### Phase 0 — Specification and Threat Modeling (2–3 days)

**Goals:** finalize Hardcap spec, align with Uniswap Foundation security frameworks, and document invariants for developers and auditors.[^13][^3][^1]

**Tasks:**

1. **Threat model:**
   - Enumerate adversaries: JIT LPs, sandwich attackers, malicious hook deployer, misconfigured router, and exploiter trying Cork-style callback abuse.[^2][^8][^4]
   - List assets: pool reserves, LP positions, vault surplus.
   - List trusted components: `PoolManager`, v4 core math, LP vault contract.

2. **Formalize invariants:**
   - Access control: only `PoolManager` can call hook callbacks; only one configured `PoolKey` is valid.[^3][^1]
   - Surplus cap: for every swap, `take <= notional * MAX_TAKE_BPS / 1e4` and any attempt to set `take > cap` reverts.
   - Vault exclusivity: only aged, still-shareholding lockers can `claim`. Pending does not sit in the denom. Remove burns matching shares. No owner/rescue/sweep/`donate()`.
   - JIT block rule: same-block add→remove is forbidden.

3. **Align with SDSF:**
   - Map Hardcap’s behavior to Uniswap v4 Self-Directed Security Framework risk dimensions (access control, external calls, dynamic fees, `hookData` usage, etc.).[^3][^49]
   - Document that Hardcap deliberately avoids `hookData` and upgradeability, and treats `BeforeSwapDelta`/`AfterSwapReturnDelta` as controlled extraction paths.[^12]

4. **Define v1 surplus logic:**
   - For initial implementation, surplus is defined as a simple extra fee in bps (e.g., fixed 5 bps on each swap) rather than a complex MEV estimator.[^4][^3]

**Milestone:** spike answers live in [`docs/SPIKE-sender-and-afterSwapReturnDelta.md`](./SPIKE-sender-and-afterSwapReturnDelta.md) plus a short comment in `HardcapHook.sol`. Do **not** create `SPEC.md`. This plan stays the only product/scope doc.

---

### Phase 1 — Contract Skeletons and Access Control (3–4 days)

**Goals:** implement basic Hardcap hook and LP vault contracts with strict access control and no surplus logic yet.

**Tasks:**

1. **Hook contract skeleton:**
   - Inherit `BaseHook` from OpenZeppelin `uniswap-hooks` or Uniswap `v4-periphery`. Do not implement `IHooks` from scratch.[^1][^51]
   - Enable **only** these permission bits (must match mined address): `beforeSwap`, `afterSwap`, `afterSwapReturnDelta`, `beforeAddLiquidity` (or `afterAddLiquidity`), `beforeRemoveLiquidity`.[^30]
   - Store immutable `poolManager`, `PoolKey` (or `currency0/1 + fee + tickSpacing + hook` self-check), `MAX_TAKE_BPS`, `EXTRA_FEE_BPS` (`<= MAX_TAKE_BPS`), `OFFSET`, and vault bookkeeping.
   - **Hook address mining:** deploy via CREATE2 / `HookMiner` so the address flags match `getHookPermissions()`. A flag mismatch means `PoolManager` never calls you (or calls a function you did not implement → revert). This is a day-1 task, not a deploy surprise.[^51]

2. **Callback gating:**
   - Rely on `BaseHook` + explicit tests that raw `hardcap.beforeSwap(...)` reverts.[^1][^7]
   - Validate `key.toId()` / currencies against the immutable pool.
   - Revert on `hookData.length != 0`.

3. **LP vault:**
   - Prefer **accounting inside the hook** (balances + claim) over a second privileged contract, unless the vault has **zero** admin. Two contracts = two steal surfaces.
   - No `owner` / `rescue` / `sweep` that can move vault tokens. If a rescue is added later, the project has failed test 4.
   - Do **not** use `poolManager.donate()` to pay LPs.[^23]

4. **Foundry environment:**
   - Use official v4 template / OZ hooks remappings. Copy test deploy patterns from OZ hook tests (`Deployers`, `PoolSwapTest`, `PoolModifyLiquidityTest`).[^23][^30]
   - Do not write a custom `PoolManager` mock.

**Milestone:** `HardcapHook.sol` compiles; basic access control tests passing (PoolManager-only, PoolKey binding).

---

### Phase 2 — Surplus Cap Logic and JIT Rule (3–4 days)

**Goals:** implement surplus calculation, extraction cap enforcement, JIT add→remove rule, and aged LP claim logic.

**Tasks:**

1. **Surplus calculation (v1 = extra hook fee):**
   - `notional` = absolute value of the **unspecified** `BalanceDelta` amount (see spike below). Not `amountSpecified` (partial fills / `sqrtPriceLimit` lie). Same currency as the take.[^\*]
   - `computedSurplus = notional * EXTRA_FEE_BPS / 1e4`.
   - Apply via `afterSwap` + `afterSwapReturnDelta` so `PoolManager`’s CL math still runs. **Do not** use `beforeSwapReturnDelta` to consume the whole swap in v1 (that is a NoOp/custom curve — SDSF high-risk, Bunni-class).[^\*][^7]
   - **Copy sign conventions** from OZ `BaseDynamicAfterFee` / test hooks (`FeeTakingHook`, `LPFeeTakingHook`) in v4-core. Do not invent delta signs.[^30]
   - Take in the **unspecified** currency (OZ `BaseHookFee` / v4-core `FeeTakingHook`). Exact-in vs exact-out both need a test. See spike doc.

2. **Cap enforcement:**
   - `take = min(computedSurplus, notional * MAX_TAKE_BPS / 1e4)`.
   - If `take` after `min()` still `>` cap (overflow / bad cast) → revert.
   - Use `uint256` then `SafeCast` to `int128`. OZ PenaltyHook already does this.[^23]

3. **Vault crediting:**
   - Hook keeps the taken amount (return-delta credits the hook; settle into hook-owned balances).
   - Credit `vaultAccrued0/1` or a single surplus token. No `donate()`.

4. **JIT rule:**
   - `afterAddLiquidity` or `beforeAddLiquidity`: if `params.liquidityDelta > 0`, set `lastAddBlock[Position.calculatePositionKey(sender, tickLower, tickUpper, salt)] = block.number` where `sender` is the **position owner** (see identity spike below).[^\*]
   - `beforeRemoveLiquidity`: same key; revert if `block.number == lastAddBlock[key]` (or more generally `block.number < lastAddBlock[key] + OFFSET` if you want PenaltyHook-style window on *exit*, not only same-block).[^\*]

5. **Aged LP claims (v1 simplification):**
   - v1 assumes **direct LP interaction** with `PoolManager` (no complex router ownership model). The address that calls `modifyLiquidity` for a position is treated as its owner and must also call `claim`.
   - On add (`liquidityDelta > 0`):
     - Compute `key = Position.calculatePositionKey(sender, tickLower, tickUpper, salt)` where `sender` is the **callback argument** (PoolManager unlock caller / position owner), **not** Solidity `msg.sender` (that is PoolManager) and **not** the EOA unless the EOA unlocked.
     - Set `lastAddBlock[key] = block.number`.
     - New liquidity is **pending** until `OFFSET` elapses (`pendingShares[key] += liquidityDelta`). `_sync` lazy-matures **that key** on the next touch. There is no global census.
     - On remove (after the JIT check): burn `min(removed, shares[key])`. Full exit zeros claim rights. Recycle cannot stack shares.
   - On claim:
     - Require `block.number >= lastAddBlock[key] + OFFSET`, then `_sync`.
     - Compute `payout = vault * shares[key] / (totalShares + pendingTotal)` (all live L). Age gates receipt. Do **not** use matured-only denom: first claimer would take 100%.
     - Transfer `payout` to `msg.sender`.
     - **Single-shot claim:** set `totalShares -= shares[key]` and `shares[key] = 0`. The position can later accrue new shares via new adds.
   - Pro-rata denominator = `totalShares` over aged positions; you do **not** recompute based on current in-range liquidity (that would pay JIT who stayed).

This v1 design deliberately allows **one claim per position key per accrual cycle** and avoids continuous rebalancing of shares. That keeps accounting simple and auditable in 3 weeks.

**Milestone:** surplus cap and JIT rule implemented; unit tests for cap enforcement and JIT behavior passing.

---

### Phase 3 — Week-1 Kill Tests Implementation (3–4 days)

**Goals:** implement full sceptic test suite based on Cork, JIT, and vault non-drainability.

**Tasks:**

1. **Cork-style exploit harness:**
   - Fork or emulate Cork’s exploit pattern in tests: direct callback calls, crafted `hookData`, incorrect `PoolKey`s.[^6][^2]
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

5. **Baseline comparison test:**
   - `test_vanillaVsHardcap_sameSwaps_vaultAccruesExtra`: run the same series of swaps on:
     - A vanilla pool, and
     - A Hardcap pool (same pair, same fee).
   - Assert that the Hardcap vault balance grows while the vanilla pool has no such surplus. This is for **demo** only; do not turn it into an APR.

**Milestone:** all four sceptic tests and baseline comparison green. If any kill test fails by the end of Phase 3, the project is killed.

---

### Phase 4 — Deployment and Integration Plan (3–4 days)

**Goals:** decide deployment targets, register the hook and pool in public registries, and plan basic demo.

**Tasks:**

1. **Chain selection:**
   - Choose testnet (e.g., Sepolia or a v4-enabled testnet) for initial deploy.[^15][^14]
   - Decide whether mainnet demo is necessary or whether testnet is sufficient for UHI10.

2. **Hook deployment:**
   - Deploy Hardcap hook.
   - Initialize one volatile pair pool (e.g., WETH/UNI) via `PoolManager` with Hardcap attached.[^14]

3. **Registry integration:**
   - If a stable address exists, submit hook details to public registries like Uniswap’s `hooklist` and relevant analytics providers.[^16][^17]
   - Document flags, chain ID, and hook behavior clearly.

4. **Demo surface:**
   - Official rule: tests **or** frontend. Prefer a Foundry script that prints the four kill tests over a web UI.
   - If a UI is built at all: swap + vault balance + claim. No marketing dashboard.

**Decision (2026-08-18):** do **not** require a testnet deploy for UHI10. Official rule is tests **or** frontend. Local `forge test --match-contract Hardcap` is the demo. Hooklist / Sepolia only after a real mined address exists. Do not submit a placeholder.

**Milestone:** Hardcap compiles and kill tests pass locally; optional testnet deploy; hooklist submission only if there is a real address.

---

### Phase 5 — Documentation, Video, and Pitch (2–3 days)

**Goals:** produce README, explainer video, and presentation that emphasize security, invariants, and exploit replays over marketing slogans.

**Tasks:**

1. **Technical README:**
   - Explain problem: hooks can over-extract or be exploited; LPs lack worst-case bounds.[^2][^4][^1]
   - Explain mechanism: immutable extraction cap, LP-only vault, fail-closed callbacks, JIT rule.[^3]
   - Include ASCII flows illustrating normal swap, toxic flow, JIT attempt, and Cork-style exploit.
   - Link to SDSF mapping and test results.[^3]

2. **Explainer video (≤5 minutes, no AI voice):**
   - Show exploit replays (Cork, JIT) failing on Hardcap.
   - Show how surplus is capped and routed to LP vault.
   - Emphasize on-chain guarantees, not hypothetical adoption.

3. **Pitch framing:**
   - Highlight originality: security-as-liquidity primitive and extraction cap rather than curve tweaks.[^18][^19]
   - Highlight execution: hard tests and exploit forks.[^1][^2]
   - Stay honest about impact: Hardcap does not magically end all MEV but makes hooked pools safer to size into.

**Milestone:** README, video script, and pitch deck complete.

---

## Implementation gotchas (session-derived — do not rediscover)

These burned review time. Implementers should treat them as given.

### Spike results (2026-08-18)

Full write-up: [`docs/SPIKE-sender-and-afterSwapReturnDelta.md`](./SPIKE-sender-and-afterSwapReturnDelta.md).

Do not rediscover: unlock caller owns the position; `afterSwapReturnDelta` is unspecified-only; notional = `abs(unspecified BalanceDelta)`; no `donate()`.

### v4 API and deploy

- Hook callbacks are `beforeAddLiquidity` / `afterAddLiquidity` / `beforeRemoveLiquidity` / `afterRemoveLiquidity`, not `beforeModifyPosition`.[^30]
- `getHookPermissions()` bits must match the CREATE2 address. Use `HookMiner.find`.[^51]
- One hook contract per pool in v1. One hook **address** per `PoolKey`. You cannot attach `AntiSandwichHook` *and* `LiquidityPenaltyHook`; merge behavior yourself.[^22][^23]
- `BaseHook` already checks `PoolManager`. Still write the direct-call test (Cork).[^\*]
- Do not support native ETH in v1 if it adds `msg.value` / refund surface (SDSF token hazards). WETH/USDC-style ERC20 only. No fee-on-transfer, rebasing, ERC-777.[^49]

### Accounting

- `amountSpecified` is the request, not the fill. Use `BalanceDelta` from `afterSwap`.[^\*]
- `afterSwapReturnDelta` is the v1 take path. `beforeSwapReturnDelta` consuming the swap = custom curve = out of scope.[^51]
- `poolManager.donate()` is banned. OZ PenaltyHook donates to *current* in-range LPs; a second account at an empty tick can catch the donate on a thin pool (OZ natspec admits this).[^^23]
- Vault tokens sit on the hook. There is no “yesterday census.” Aged `shares[positionKey]` with single-shot claim is the honest approximation.
- v1 assumes **direct LP → PoolManager** interactions. Router-based composite ownership is out of scope; document this in README.

### Economics / pitch

- Hardcap does **not** make sandwiches −EV (that is Umbra/OZ, one direction, incomplete). Do not say “kill the sandwich.”[^8][^22]
- Do not pitch Unichain-specific sandwich protection (Gogol 2026).[^^21]
- Do not pitch Robinhood or Uniswap Labs adoption.
- FairFlow (exclusive + signed price), Angstrom (priority-gas tax), Aegis (surge fee), DualPool (vault JIT, external LP blocked) already exist. Hardcap’s difference is **immutable public cap + LP-only payee + fail-closed callbacks**.[^24][^25][^26] If the README does not say that in one sentence, the pitch is slop.
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
- `test_agedLpCanClaim` (single-shot claim)
- `test_ownerCannotDrainVault` (no owner function exists)
- `test_increaseLiquidityUpdatesLastAddBlock`
- `test_differentSaltIsDifferentPosition`
- `test_vanillaVsHardcap_sameSwaps_vaultAccruesExtra`
- `test_fullRemoveBurnsSharesCannotClaim`
- `test_recycleDoesNotStackShares`
- `test_unagedDilutesButCannotClaim`
- `test_twoAgedLockersSplitVault`
- `test_take_oneForZero_chargesUnspecifiedOutput`
- `test_partialRemoveThenClaimRemaining`
- `test_partialRemoveThenAddSameBlockRefreshesLock`
- `test_offsetWindow_blocksUntilOffsetElapses`
- `test_constructor_rejectsNativeExtraAboveMaxAndZeroOffset`
- `test_hookBalanceMatchesVaultAccrued`
- `test_take_exactOut_oneForZero`

---

## Expert panel review of this plan (honest, no invented data)

**LVR / MEV quant.**  
Hardcap as specified does **not** recapture LVR. A flat extra bps is a transfer from all swappers to aged LPs. That can still help *hook-trust* and JIT fee theft; it does not mark the book to Binance. Do not put “LVR recapture” in the README unless surplus definition (2) (start-of-block excess) is implemented and tested. Theme fit is **partial** and must be sold as extraction-bounded hooked liquidity, not as FairFlow.[^24][^25]

**Hook security / ToB / SDSF.**  
The four kill tests match real incidents (Cork, OZ donate, Umbra JIT). Using `BaseHook` + banning `donate` + banning `hookData` + no proxy is the correct SDSF posture (immutability, no external deps, price-impact path is the take).[^\*][^1][^3] Missing from v1 and acceptable if documented: no formal verification, no second audit, no monitoring. Feature trigger “price impacting behavior” still applies because you take a hook fee — treat `afterSwapReturnDelta` as the dangerous permission and fuzz it.[^49]

**Agentic / 2026 hook-AI.**  
Stay out. Aeon/Sentinel/Hermes patterns are the wrong cohort (UHI11 curation) and add an operator.

**Complex systems.**  
The useful homeostasis is fail-closed + a printed cap, not a controller. Do not add autonomous fee updates (SDSF autonomy trigger).[^^49]

**Crypto primitives.**  
No VRF, no TEE attestations, no FHE. Correct. Flashtestations are not a foundation.

**What is still missing (real gaps, not flavor):**

1. **Position owner vs router `sender`** — **done** (spike doc + README + `test_claimRequiresPositionOwnerNotEoa`).
2. **Currency of `take` on exact-out swaps** — **done** (`test_take_exactOut_chargesUnspecifiedInput`).
3. **SDSF self-score worksheet** — **done** (README).
4. **Comparison baseline** — **done** (`test_vanillaVsHardcap_sameSwaps_vaultAccruesExtra`). Do not fabricate APY.

**Panel verdict:** the plan is allowed to proceed. It is a **bounded, security-first hook**, not a category-winning AMM. Quality of the four Foundry replays decides whether it places. Expanding into leftover oracles, Flashblocks, or “yesterday’s fee ownership” is how this becomes slop again.

---

## How Hardcap Is Used and By Whom (“the missing guardrail for the v4 era”)

This section is for humans (judges, LPs, PMs). No dense v4 jargon.

### Intended users

- **Hook authors** who are building custom pools (dynamic fees, custom curves, integrations) and want a **safety envelope** around hook-level extraction and JIT behavior.
- **LPs** who are willing to deposit into hooked pools **only if** they can see a public, on-chain worst-case bound on what the hook can take from them.
- **Protocol teams / DAOs** that might adopt Hardcap’s pattern (or fork it) as a **standard guardrail** for high-value pools (RWAs, correlated pairs, etc.).

Hardcap is **not** a general wrapper hook that you attach on top of another hook — v4 only allows one hook per pool. Instead:

- You either:
  - Use Hardcap as **the** hook for a pool (e.g., vanilla v4 curve + Hardcap guardrail), or
  - Integrate Hardcap’s patterns (cap + JIT lock + no donate + access control) into your own more complex hook.

This hackathon version is **not monetized**:

- All extra bps go to LPs; there is no owner fee and no DAO cut.
- If a future team wants to monetize, they can fork and add a small protocol cut — at that point it’s their moral hazard, not this project.

Realistically, many teams will copy the code. That’s fine. Your “product” is:

- The **reference implementation** that passed Cork/JIT/OZ kill tests, and
- The **story/demo** that shows Hardcap stopping real exploit patterns.

That wins grants, audits, and consulting — not a per-swap fee.

---

### Example 1: Normal user swap (vanilla vs Hardcap)

**Scenario:** Alice swaps 1,000 USDC for WETH on a volatile pool.

**Without Hardcap (vanilla v4):**

```text
Alice -> PoolManager -> Pool math
           |
           v
       [Pool LPs]

- Alice pays 0.30% pool fee.
- LPs earn these fees.
- No extra guardrail: any attached hook could, in theory, take more,
  and Alice/LPs can’t see a bound.
```

**With Hardcap:**

```text
Alice -> PoolManager -> Hardcap.beforeSwap (checks only)
           |
           v
        Pool math
           |
           v
   Hardcap.afterSwap + afterSwapReturnDelta
           |
   take = notional * EXTRA_FEE_BPS   (say 5 bps)
   take <= MAX_TAKE_BPS (say 15 bps)
           |
           v
     vaultAccrued += take
           |
           v
       [LP vault (later claims)]
```

- Alice still gets roughly the same price (slightly worse by 5 bps extra).
- LPs still get the 0.30% pool fee **plus** a tiny extra from Hardcap.
- Everyone can read `MAX_TAKE_BPS` on-chain and know the hook **can’t** take more than that per swap.

**Point:** Hardcap makes the “hook rake” visible and bounded, instead of “trust whatever the hook wants to do.”

---

### Example 2: Cork-style direct callback exploit

**Scenario:** In Cork, the attacker called the hook directly and gave fake `hookData` so the hook thought they had deposited value, minted them claims, and drained reserves.[^2][^6]

**In a broken hook:**

```text
Attacker -> call hook.beforeSwap(...) directly
                    |
                    v
            hook trusts msg.sender
            hook trusts hookData
                    |
        credits attacker with fake assets
                    |
                    v
             attacker withdraws real reserves
```

**With Hardcap:**

```text
Attacker -> call Hardcap.beforeSwap(...) directly
                    |
                    v
       require(msg.sender == PoolManager)
                    |
                 REVERT

OR

Attacker -> PoolManager -> Hardcap.beforeSwap(hookData != 0)
                    |
                    v
       if (hookData.length != 0) REVERT
                    |
                 no side effects
```

- Direct calls die because `msg.sender` is not `PoolManager`.
- Any `hookData`-based attack dies because v1 Hardcap simply does not accept `hookData`.

**Point:** Hardcap refuses to even *listen* to the attack surface Cork used.

---

### Example 3: JIT liquidity attack (same-block add→swap→remove)

**Scenario:** Bob is a JIT LP. He adds liquidity just for a single big trade, takes fees, then instantly removes in the same block.

**Without Hardcap:**

```text
Block N:

Bob -> addLiquidity()
              |
              v
           [Pool]

Sandwich/Searcher -> large swap() through pool
              |
              v
            Fees accrue to Bob

Bob -> removeLiquidity() in same block
              |
              v
         Takes all earned fees
```

- Bob was never really a long-term LP; he just sniped one trade.

**With Hardcap:**

```text
Block N:

Bob -> addLiquidity()
              |
              v
   Hardcap.afterAddLiquidity
              |
   lastAddBlock[positionKey] = N

Searcher -> large swap()
              |
              v
       Hardcap.afterSwap (may take tiny extra fee)
              |
              v
         LP vault grows

Bob -> removeLiquidity() in same block
              |
              v
   Hardcap.beforeRemoveLiquidity
              |
   if block.number == lastAddBlock[key]:
          REVERT
```

- Bob cannot exit in the same block.
- Bob also cannot claim from the LP vault until `OFFSET` blocks have passed.

**Point:** Hardcap forces **time in the pool** before collecting the extra guardrail fee, making hit-and-run JIT less attractive.

---

### Example 4: OZ LiquidityPenalty donate redirect

**Scenario:** OZ’s `LiquidityPenaltyHook` donates penalties back into the pool; the audit notes a second account can sit in-range and catch that donation.[^10][^11][^23]

**In a penalty+donate hook:**

```text
Short LP -> addLiquidity()
           -> removeLiquidity too soon
                 |
                 v
         Penalty computed
                 |
                 v
      hook calls poolManager.donate()
                 |
                 v
   whoever is in-range NOW gets donated amount

Attacker -> positions themselves in-range at the right tick
           -> receives "penalty" as a gift
```

**With Hardcap:**

```text
Short LP -> removeLiquidity too soon
                 |
                 v
   Hardcap.beforeRemoveLiquidity
       (JIT rule may revert exit)
                 |
                 v

Hardcap.afterSwap:
    take = extra fee (<= cap)
    vaultAccrued += take
                 |
                 v
     Only aged LP positions can claim vault
     No donate(), no second-account redirect
```

- No `donate()` calls into the pool.
- Surplus sits in a separate bucket (vaultAccrued) and can only be claimed by aged LP positions.

**Point:** Hardcap separates **pool balances** and **vault surplus** and removes the second-account redirect vector entirely.

---

### Example 5: Buggy hook that tries to over-extract

**Scenario:** A bug or malicious branch tries to set `take` to 5% of notional instead of respecting the 15 bps cap.

**Without Hardcap (no cap):**

```text
afterSwap:
    computedSurplus = notional * 0.05
    take = computedSurplus
    vault += take

User swap executes, but 5% extra gets silently raked by the hook.
```

**With Hardcap:**

```text
afterSwap:
    notional = 1000
    cap = notional * MAX_TAKE_BPS / 1e4   (say MAX_TAKE_BPS = 15)
        = 1000 * 15 / 10^4 = 1.5

    computedSurplus = 50   // bug: 5%
    take = min(computedSurplus, cap) = 1.5

    // If internal math tries to assign > cap directly:
    if (take > cap) REVERT

Result:
- User swap still succeeds with at most 1.5 units raked.
- If the bug path attempts to credit > cap, tx reverts entirely.
```

**Point:** Hardcap turns “hook can rug 5% silently” into either (a) a small bounded rake or (b) a revert, not silent theft.

---

## Good Practices and References from Uniswap and Security Ecosystem

### Uniswap v4 Security Framework

- Follow Uniswap’s Self-Directed Security Framework to score Hardcap on access control, `hookData` usage, external calls, fee logic, and upgradeability; document the results.[^3][^49]
- Avoid upgradeable patterns for the hook; prefer immutable constructor configuration.[^7][^49]

### Hook Attack Patterns and Best Practices

- Use Trail of Bits’ “Building secure Uniswap v4 hooks” guidance for callback gating, `PoolKey` validation, and accounting invariants.[^1][^87]
- Consult broader v4 security guides and audits for patterns like flag bypass, donation griefing, and reentrancy, ensuring Hardcap does not introduce these.[^20][^7][^4][^51]

### JIT and Sandwich Resistance Literature

- Use Umbra’s sr-AMM findings to justify the JIT block rule and ageing-based LP claims.[^8][^27]
- Ensure documentation clearly states that Hardcap is not a full sandwich-resistant AMM but contributes to sustainable liquidity by curbing JIT and bounding hook extraction.

### Registries and Analytics

- Register Hardcap in Uniswap’s `hooklist` with clear metadata: chain, pool, flags, and description.[^17][^16][^29]
- Promote transparent on-chain data so analytics platforms can track Hardcap’s effect on LP returns and surplus distribution.[^17]

---

## Conclusion

Hardcap is a security-first Uniswap v4 hook that aims to make hooked pools safer by bounding **hook-level** extraction and enforcing LP-only surplus distribution, while closing known exploit vectors like Cork-style callbacks, same-block JIT exit, and donation redirection.[^8][^2][^11][^1][^3]

It is not a sandwich AMM, not FairFlow, and not “yesterday’s LPs get today’s 0.30%.” The sceptic checklist is the path: if the implementation passes the four kill tests, proceed; if any fails, kill the project rather than narrate it.

---

## References

(unchanged from your updated plan; kept for completeness)

1. [Building secure Uniswap v4 hooks](https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/)  
2. [The $11M Cork Protocol Hack: Uniswap V4 Hook ...](https://dedaub.com/blog/the-11m-cork-protocol-hack-a-critical-lesson-in-uniswap-v4-hook-security/)  
3. [Security Framework | Uniswap Developers](https://developers.uniswap.org/docs/protocols/v4/security)  
4. [Uniswap v4 Hook Security: Architecture, Common Vulnerabilities, and Best Practices | KuCoin](https://www.kucoin.com/news/flash/uniswap-v4-hook-security-architecture-common-vulnerabilities-and-best-practices)  
5. [Cork Protocol Incident Analysis](https://www.certik.com/blog/cork-protocol-incident-analysis)  
6. [0x3 Attack Analysis](https://blocksec.com/blog/cork-protocol-incident-two-independent-flaws-combine-into-one-devastating-exploit-chain)  
7. [Uniswap v4 Security Guide: Hooks, Risks, and Audit Path](https://www.zealynx.io/research/protocol-deep-dives/uniswap-v4)  
8. [A Sandwich-Resistant AMM - Umbra Research](https://umbraresearch.xyz/writings/sandwich-resistant-amm)  
9. [Our Vision for Uniswap v4](https://blog.uniswap.org/uniswap-v4)  
10. [OpenZeppelin Uniswap Hooks v1.1.0 RC 2 Audit](https://www.openzeppelin.com/news/openzeppelin-uniswap-hooks-v1.1.0-rc-2-audit)  
11. [OpenZeppelin Uniswap Hooks v1.1.0 RC 1 Audit](https://www.openzeppelin.com/news/openzeppelin-uniswap-hooks-v1.1.0-rc-1-audit)  
12. [BeforeSwapDelta | Uniswap](https://docs.uniswap.org/contracts/v4/reference/core/types/beforeswapdelta)  
13. [v4-security-foundations — AI agent skill | explainx.ai | explainx.ai](https://explainx.ai/skills/uniswap/uniswap-ai/v4-security-foundations)  
14. [Overview | Uniswap Developers](https://developers.uniswap.org/docs/protocols/v4/overview)  
15. [Uniswap v4](https://v4.uniswap.org/)  
16. [Uniswap/hooklist: Uniswap V4 hooks registry](https://github.com/Uniswap/hooklist)  
17. [Uniswap V4 Hooks - Allium Documentation Hub](https://docs.allium.so/historical-data/supported-blockchains/evm/core-schemas/dex/uniswap-v4-hooks)  
18. [UHI10: Fair Flow Frontier Cohort for MEV Protection and ...](https://www.linkedin.com/posts/atrium-academy1_a-v4-hook-can-capture-arb-value-in-beforeswap-activity-7462170669280067584-D6Gj)  
19. [Uniswap Hook Incubator: 2025 Wrapped - Atrium Academy](https://blog.atrium.academy/uniswap-hook-incubator-2025-wrapped)  
20. [Auditing Uniswap V4 Hooks: Risks, Exploits, and Secure Implementation](https://hacken.io/discover/auditing-uniswap-v4-hooks/)  
21. [Gogol et al., How to Serve Your Sandwich? (arXiv:2601.19570)](https://arxiv.org/abs/2601.19570)  
22. [OpenZeppelin AntiSandwichHook.sol (v1.2.0)](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/AntiSandwichHook.sol)  
23. [OpenZeppelin LiquidityPenaltyHook.sol (v1.2.0)](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/LiquidityPenaltyHook.sol)  
24. [Kyber FairFlow](https://blog.kyberswap.com/introducing-fairflow/)  
25. [Angstrom L2](https://docs.angstrom.xyz/l2/intro)  
26. [DualPool hook](https://blog.uniswap.org/dualpool-hook-is-now-live)  
27. [Umbra sandwich-resistant AMM](https://www.umbraresearch.xyz/writings/sandwich-resistant-amm)  
28. [Atrium 2025 Wrapped / UHI10 theme](https://blog.atrium.academy/uniswap-hook-incubator-2025-wrapped)  
29. [Uniswap hooklist](https://github.com/Uniswap/hooklist)  
30. [v4-core IHooks / PoolManager](https://github.com/Uniswap/v4-core)  
87. [Building secure Uniswap v4 hooks — summary mirror](https://daily.dev/posts/building-secure-uniswap-v4-hooks-o14twkde6)
