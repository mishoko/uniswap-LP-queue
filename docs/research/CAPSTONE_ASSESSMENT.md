# CAPSTONE_ASSESSMENT — `mishoko/uniswap-hooks-capstone-mishoko` (VPIN Dynamic Fee Hook)

> Assessed 2026-08-26. Repo cloned to `/tmp/capstone-assess/`, submodules initialised, built and
> tested with forge 1.5.0-stable. Every number below was measured, not read off the README.
> Adversarial probes are preserved at `docs/research/data/capstone_vpin_probe.t.sol`.

**VERDICT: LEAVE IT.** Do not extend, do not harvest. Details in §6.

---

## 0. The headline, before the detail

Three things settle this and none of them is a matter of taste:

1. **The owner already decided this, twice, in writing.** `docs/IMPLEMENTER_BRIEF.md:143` — *"Prior
   **VPIN** repo code does not count as hookathon work. New files only."*
   `docs/Hardcap … Implementation Plan.md:265` — *"Returning-team / prior capstone: VPIN repo code
   does **not** count. All Hardcap code must be new."* Same file, line 50, kills the idea by name:
   *"VPIN-as-title (course homework; 57% of 2025 UHI projects were LP/dynamic fee)."* Line 60:
   *"Nezlobin-as-title (taught this cohort)."* This assessment is re-litigating a closed question,
   and it reaches the same answer with execution behind it.
2. **The core metric is arithmetically wrong on every pool that is not priced 1:1**, and I proved it
   with a passing negative control. Perfectly balanced round-trip flow — the least toxic flow that
   can exist — reads VPIN 0.003 on a 1:1 pool and **VPIN 0.607 on a 1:4 pool**, charging 7,248 bps
   instead of 3,000. On ETH/USDC the metric pins at ~0.9995 and the pool charges MAX_FEE forever.
3. **The suite does not test the product.** I deleted the entire directional-fee mechanism — one of
   the two headline features — and all 10 tests passed. I then made the hook compute VPIN correctly
   and **never charge it**, returning a flat `BASE_FEE` to the PoolManager on every swap: all 10
   tests passed again. The hook's one job has zero coverage.

---

## 1. What it actually is

| | |
|---|---|
| Name | VPIN Dynamic Fee Hook |
| Mechanism | Volume-bucketed order-flow-imbalance metric (VPIN, Easley/López de Prado/O'Hara 2012) drives a linear fee between `BASE_FEE` and `MAX_FEE`, plus a "Nezlobin-style" directional surcharge/discount |
| Callbacks | `beforeInitialize` (require dynamic-fee flag), `afterInitialize` (seed tick), `beforeSwap` (return fee with `OVERRIDE_FEE_FLAG`), `afterSwap` (accumulate volume) |
| Return deltas | **None.** All four `*ReturnDelta` permissions are `false`. The hook never calls `take`, `settle`, `mint`, `burn`, or `donate`. It holds no funds and has no periphery. |
| Contracts | `src/VPINDynamicFeeHook.sol` (228 L), `src/libraries/VPINMath.sol` (104 L) |
| Tests | `test/VPINDynamicFeeHook.t.sol` (461 L, 10 tests) |
| Script | `script/DeployVPINHook.s.sol` (53 L, HookMiner boilerplate, Unichain Sepolia PoolManager hardcoded) |
| **Total** | **846 LOC**, of which **332 LOC is `src/`** |
| Git history | **2 commits.** `cc58bbe` 2026-05-14 "initial VPIN hook" (the entire project, 1,096 insertions, single dump — no incremental history). `8a4cd82` 2026-05-18, README-only. |
| Build | **Fails on a naive clone** (nested submodule `v4-hooks-public/lib/v4-core` does not check out). Passes after `git submodule update --init --recursive --force`. Submodules float on `main` — nothing is pinned, so "it builds" is time-dependent. |
| Tests | **10 passed / 0 failed**, 72 ms. Confirmed by me, not taken from the README. |
| Demo video | Public YouTube, `2Nmq0-C-P5g`, published ~May 2026 — i.e. **three months before the hookathon window opened**. |

Everything the README claims about test results is accurate as far as it goes. §3 is about what
those tests do not test.

---

## 2. GATE CHECK

### Gate 6 — *"New Code for Returning Teams — previously judged code doesn't count again."*
**NEEDS-OWNER-CONFIRMATION, but the practical answer is FAIL.**

- The repo is not in the 662-row hook directory. The only VPIN row in nine cohorts is **LP Hub
  (UHI5, Uniswap Prize)**. So this was **not submitted to any Hookathon**.
- It is, by its own name and by a 5-minute explainer video shot in May 2026, **a UHI course
  capstone** — work produced for and reviewed inside the programme.
- The owner has twice recorded the conclusion that this code "does not count" (§0.1). Nothing found
  today contradicts that. **The only question left for the owner is whether the capstone was
  formally graded/judged**, which decides FAIL vs. merely-unoriginal. Either way the code is
  100% pre-window: the last commit is 2026-05-18, the window opened 2026-08-17.

### Gate 7 — *"Originality — no copied code from workshops, curriculum, or past projects, unless credited."*
**FAIL as-is.** Two independent hits:

- **Nezlobin's Directional Fee is on the curriculum-taught list** (`HACKATHON_CONTEXT.md` §6a,
  verbatim: *"Nezlobin's Directional Fee — asymmetrically raises/lowers fee in one direction to
  deter arbitrage-driven toxic flow"*). The hook implements it and names it in the contract title
  comment. The owner's own note at `Hardcap … Plan.md:60` reads *"Nezlobin-as-title (taught this
  cohort)"*.
- **The whole thing is a past project** (§Gate 6).

Crediting fixes the *gate*. It does not fix the *score*: 30% of the rubric is "Original Idea —
is the idea new to Uniswap or DeFi?" A credited re-run of a taught exercise scores near zero there.

### Gate 4 — *"Written & Workable Code — some code must be newly written during the Hookathon."*
**FAIL as-is / PASS only with substantial new work.** 100% of the 846 LOC predates 2026-08-17.
Extending it means the delta is what gets judged, and the delta would sit on a base whose core
arithmetic is wrong (§3.1).

### Gate 5 — *"README with Partner Integrations."*
**FAIL as-is.** The README lists none and does not say "No partner integrations." Trivially fixable.

### Gates 1, 3, 8 — public repo / valid hook / tests-or-frontend
**PASS on the letter.** Public, a real v4 hook, 10 tests that run. But Gate 8 exists so judges can
*verify functionality*, and §3.5 shows these tests cannot do that.

### Curriculum-hook cross-check (§6a list)
| Curriculum hook | Implemented here? |
|---|---|
| Nezlobin's Directional Fee | **YES — by name** |
| Gas Price Fees | No (same family: a taught dynamic-fee exercise) |
| JiT Rebalancing / CSMM / LAMMBert / Async Swap / CoW | No |

---

## 3. QUALITY — findings

### 3.1 CRITICAL — the VPIN metric subtracts two different tokens. `VPINDynamicFeeHook.sol:159-163`
```solidity
int128 inputAmount = params.zeroForOne ? delta.amount0() : delta.amount1();
uint256 volume = ...abs(inputAmount);
VPINMath.accumulate(_vpinStates[poolId], isBuy, volume, BUCKET_SIZE);
```
Sell volume is accumulated in **token0 units**; buy volume in **token1 units**. `VPINMath.sol:94-98`
then computes `|buyVol - sellVol|` — subtracting USDC from ETH. `bucketSize` is likewise a single
raw number applied to both.

**Measured** (`docs/research/data/capstone_vpin_probe.t.sol`, 20 perfectly balanced round trips —
swap in, immediately swap the whole output back; zero net position, the least toxic flow possible):

| Pool price | VPIN read | Fee charged |
|---|---|---|
| 1 : 1 *(negative control — passes)* | **0.0031** | 3,021 |
| 1 : 4 *(same flow, same code)* | **0.607** | **7,248** |

0.607 ≈ (4−1)/(4+1) exactly as the arithmetic predicts. Extrapolate to ETH/USDC at ~4000: VPIN
≈ 0.9995 permanently, `MAX_FEE` on every swap forever, regardless of flow. **Decimals compound it**
— a USDC/WETH pool mixes 6-dp and 18-dp integers, and a single immutable `BUCKET_SIZE`
(`VPINDynamicFeeHook.sol:33`) is shared by every pool the hook serves, so on USDC the 10e18 default
bucket is 10 trillion USDC and never fills. **The hook is correct only on an 18/18-decimal pool
priced at 1:1.** Every one of the 10 shipped tests uses exactly that pool.

The negative control passing is what makes this a finding and not a test artefact.

### 3.2 CRITICAL — the toxic swap always pays the pre-toxicity fee. `:117` vs `:163`
`_beforeSwap` reads `_vpinStates[poolId].lastVPIN` (`:117`). `lastVPIN` is only recomputed inside
`VPINMath.accumulate` **on bucket completion** (`VPINMath.sol:66`), which runs in `_afterSwap`.
So the swap that creates the imbalance is priced off the *previous* bucket's VPIN and the surcharge
lands on **whoever trades next** — typically the innocent retail flow the hook claims to attract.

This is structurally identical to the inversion that killed HardcapHook (`CLAUDE.md` §6: *"First
swap of block was tax-exempt → subsidises the top-of-block race"*). A metric that can only fire
after the damage taxes the victim, not the attacker.

Compounding: `lastVPIN` **never decays with time**, only with volume. A pool that sees one toxic
burst and then goes quiet charges the elevated fee indefinitely. The repo's own
`test_vpinDecaysAfterBalancing` needed **40 swaps** to come down from 1.0 to 0.09.

### 3.3 HIGH — the Nezlobin component fires on at most one swap per block, and is ~a no-op. `:127-130`, `:194-196`
```solidity
if (block.number > lastBlockNumbers[poolId]) { ...tickDelta = currentTick - lastTicks[poolId]; }
```
`tickDelta` is non-zero **only when this is the first swap of a new block**; `_afterSwap:166-169`
then advances `lastBlockNumbers`. Every subsequent swap in the block gets `tickDelta == 0` and
`_applyDirectionalAdjustment` returns the fee untouched (`:185`).

**Measured:** two identical momentum-aligned 0.001-ether swaps in the same block —
swap #1 out `970,356,444,191,636`, swap #2 out `970,550,173,796,704`. Swap #2 executed at a *worse*
price and still received **more**, because it escaped the surcharge entirely.

Separately, the reference window is wrong: `lastTicks` is written in `_afterSwap` of the first swap
of the block, so the "momentum" measured is (tick before block N's first swap) − (tick after block
N−1's *first* swap), discarding everything that happened in the rest of block N−1.

And the magnitude is negligible. `:194` comments *"relative to a reference of 100 ticks"*; `:196`
divides by **10000**. At |Δtick| = 100 the adjustment is 1% of the fee — 30 bps → 30.3 bps. Reaching
the 50% cap needs |Δtick| ≈ 5,000, a ~65% price move in one block.

### 3.4 HIGH — unbounded storage loop in `afterSwap`; large swaps are bricked. `VPINMath.sol:37-77`
`accumulate` loops once per `bucketSize` of volume, and calls `_computeVPIN` — a 50-iteration loop
over two storage arrays — **inside** that loop. Cost is O(volume / bucketSize × 100 SLOADs).

**Measured:** with a full 50-bucket buffer, one 200-ether swap at `BUCKET_SIZE = 1 ether` costs
**10,271,593 gas**. Linear extrapolation puts the 30M block-gas limit at ~600 ether of volume in a
single swap — past which **the swap cannot be executed at all**. `BUCKET_SIZE` is immutable and
shared across every pool, so there is no per-pool remedy. Note that both `_computeVPIN` results
except the last are discarded — the work is not merely expensive, it is wasted.

### 3.5 HIGH — test theatre. Mutation results, run today
The repo's standing order is *distrust green*. Three mutations:

| Mutation | Tests that caught it |
|---|---|
| Delete the **entire** directional-fee mechanism (`return fee;` at the top of `_applyDirectionalAdjustment`) | **0 / 10.** `test_directionalFeeAsymmetry` — the test whose only purpose is this feature — still passes. |
| `_beforeSwap` returns a flat `BASE_FEE` and **never charges the VPIN fee** | **0 / 10.** |
| Halve `_computeVPIN`'s output (a subtle 2× error) | 1 / 10 (`test_toxicFlowRaisesVPIN`) |

`test_directionalFeeAsymmetry:314` asserts `outputAgainstMomentum > outputWithMomentum`. Both legs
move the price, so the assertion is satisfied by ordinary AMM price impact. It measures the curve,
not the hook. Per §3.3 the counter-momentum leg receives no discount at all — the test passes
*because* the mechanism is absent from it.

Individually named:
- `test_feeBoundsRespected:321` — `view`, zero swaps, VPIN = 0. Asserts `BASE_FEE >= BASE_FEE` and
  `BASE_FEE <= MAX_FEE`. Tautological. It never touches the fee actually charged, which is the only
  one that can exceed `MAX_FEE` (§3.6).
- `test_bucketRotation:331` — comment says *"Fill more than NUM_BUCKETS (50)"*; the test's own next
  comment admits it produces 30, and the run prints **`Filled buckets: 30`**. The circular buffer
  **never wraps**. Wrap-around — the only thing a circular buffer can get wrong — is untested. The
  assertion `assertLe(filledBuckets, 50)` is true even at zero.
- `test_vpinOracleView:391` — re-implements the function under test inside the assertion. Circular.
- `test_rejectsNonDynamicFeePool:101` — bare `vm.expectRevert()` with no selector; passes on any
  revert. This is verbatim the defect the repo caught in its own router spike (`CLAUDE.md` §8,
  *"`reason.length > 0` passing on the wrong revert"*).

### 3.6 MEDIUM — constructor does not validate against `MAX_LP_FEE`. `:49`
`if (_maxFee < _baseFee) revert InvalidFeeRange();` is the only check. `_applyDirectionalAdjustment`
can return `fee * 1.5`, so a deployer choosing `MAX_FEE > 666_666` produces an override above
`LPFeeLibrary.MAX_LP_FEE` (1e6) and **every swap on that pool reverts** with no recovery path
(all config is immutable). `test_feeBoundsRespected` does not cover this.

### 3.7 LOW — false novelty claim in the source. `:19`
`/// @dev First on-chain implementation of VPIN (Easley, Lopez de Prado, O'Hara 2012).`
**LP Hub (UHI5)** shipped *"evidence based metrics (VPIN, Illiq, Inventory Exposure) … to empower
LPs with highly effective dynamic fees"* and won the **Uniswap Prize** for it. A judge who greps the
hook directory finds this in one query. The README was already corrected once for over-claiming
(commit `8a4cd82`, "fix overclaimed VPIN accuracy statement"); this claim survived.

### 3.8 Access control
No findings. The hook holds no funds, has no admin, and `BaseHook`'s `onlyPoolManager` covers all
four callbacks. Its blast radius is fee mispricing, not theft.

---

## 4. SATURATION

From `docs/research/data/hook_directory_662.json` and `WINNERS_LANDSCAPE.md` §2:

| Lane it sits in | Submissions | Prized | Landscape verdict |
|---|---:|---:|---|
| **Dynamic fee** (rank 1 of 20) | **189** (29% of all 662) | 42 | *"**Dead lane.** This is a curriculum exercise. Nezlobin directional fee alone appears repeatedly. **Do not submit 'a dynamic fee hook.'**"* |
| MEV / toxic flow (rank 3) | 139 | 30 | *"literally the UHI10 theme, and the 3rd most-built lane in history"* |
| Nezlobin / directional fee (my query) | 7 | 1 | Two projects are literally named "Nezlobin Directional Fee" (UHI2, UHI3) |
| VPIN specifically | **1** | 1 | LP Hub, UHI5, **Uniswap Prize** — the prior art §3.7 denies |

It sits in the single most-built lane in UHI history, in its most-taught sub-lane, with a named
prize-winning precedent. Atrium's own deck lists *"Dynamic fees alone can't distinguish 'good'
retail flow from 'bad' toxic flow"* as **open problem #3** — i.e. the organizers name this exact
approach as the thing that does not work.

---

## 5. REUSABLE PARTS

Checked explicitly against what the shortlist needs. **Nothing here shortens any of it.**

| Shortlist need | Is it here? |
|---|---|
| **SWITCHBACK** — block-open tick + intra-block watermarks | **No, and worse than no.** `lastTicks`/`lastBlockNumbers` (`:39-40`, `:127-130`, `:166-169`) record the tick **after the first swap of the block**, which is precisely the wrong reference — SWITCHBACK needs the tick *before* any swap. ~12 lines, and copying them imports the §3.3 bug. Write it fresh. |
| **HASTE** — periphery for a deferred / NoOp swap lane | **No.** `beforeSwapReturnDelta: false` (`:74`). No NoOp, no custom router, no settle/take, no escrow. Zero overlap. |
| **SLUICE** — escrow + claim machinery | **No.** The hook never holds a token. No ERC-6909, no `take`/`settle`, no claims. Zero overlap. |
| Tested library worth lifting | **No.** `VPINMath` is 104 lines whose central subtraction is dimensionally invalid (§3.1) and whose loop is a gas bomb (§3.4). |
| Deploy script | `script/DeployVPINHook.s.sol` — stock `HookMiner.find` + CREATE2 boilerplate, identical to the v4 template. Saves ~20 min, and the hardcoded Unichain Sepolia PoolManager needs re-verifying anyway. |
| CI workflow | `.github/workflows/test.yml` — 38 lines of stock `foundry-toolchain` CI. Saves ~10 min. This repo already has CI. |
| Test harness | Textbook `Deployers` `setUp`. This repo already runs ~180 tests on its own harness. Zero savings. |

Total honest harvest: **under half an hour of boilerplate**, both pieces available upstream, neither
on any critical path.

---

## 6. VERDICT — **LEAVE IT**

Not "harvest parts". Leave it.

**Why a clean sheet is faster and safer:**

1. **There is nothing to extend.** 332 lines of `src/`, of which the metric (§3.1) and the
   directional overlay (§3.3) are both wrong, and the fee application (§3.5) is untested. Fixing
   §3.1 means changing the unit basis of the metric, which changes `bucketSize`, which changes the
   struct, the accumulate loop, and every threshold in every test. That is a rewrite with a
   misleading git history attached.
2. **Extending it cannot buy back the 30% originality weight.** Even if every bug were fixed, the
   answer to "is the idea new to Uniswap or DeFi?" is: it is a taught curriculum exercise, in the
   #1 saturated lane (189/662), with a prize-winning VPIN precedent already in the directory. Best
   case is a mid-table score on the largest single rubric weight.
3. **It puts three binary gates at risk to save nothing.** Gates 4, 6 and 7 all have exposure here
   (§2). The upside being defended is ~30 minutes of CI and deploy-script boilerplate.
4. **The deadline is not the constraint.** ~8 working weeks to 2026-11-03. There is no schedule
   argument for standing on a broken base.
5. **Sunk cost is the only thing pulling toward it.** The repo's own §8 already made this call —
   twice, before I looked. Execution today only added the reasons.

**What is genuinely worth keeping — and it is not code.** The measurement in §3.1 is a clean,
transferable lesson for the shortlist: *any per-swap metric that mixes token0-denominated and
token1-denominated amounts is silently correct at 1:1 and silently wrong everywhere else, and a
1:1 test fixture will never show it.* SWITCHBACK's watermarks and HASTE's minOut floor both compare
quantities across the two sides of a pool. Fixture-priced-1:1 is now a known blind spot; test every
new mechanism at a non-unit price with a negative control.

### Method note
Distrust-green went **3 for 3** again. The suite is 10/10 green and 461 lines long, and it does not
detect (a) deletion of a headline mechanism, (b) the fee never being charged, or (c) the metric
being wrong on every real pool. The two findings that matter came from a probe written by someone
attacking the code rather than demonstrating it — `CLAUDE.md` §8's standing order, confirmed once
more.

---

## APPENDIX — reproducing

```bash
git clone https://github.com/mishoko/uniswap-hooks-capstone-mishoko /tmp/cap && cd /tmp/cap
git submodule update --init --recursive --force     # required; a plain clone does not build
forge test -vv                                       # 10 passed
cp <repo>/docs/research/data/capstone_vpin_probe.t.sol test/Probe.t.sol
forge test --match-path test/Probe.t.sol -vv         # CONTROL passes, PROBE_1to4 fails
```
Mutations used in §3.5, applied one at a time to a clean tree:
- `_applyDirectionalAdjustment`: insert `return fee;` as the first statement → 10/10 still pass.
- `_beforeSwap:135`: `uint24 feeWithFlag = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;` → 10/10 still pass.
- `VPINMath.sol:102`: append `/ 2` → 9/10 pass, 1 fails.
