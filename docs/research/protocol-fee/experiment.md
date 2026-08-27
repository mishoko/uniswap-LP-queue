# PLAN §E.5 — the protocol-fee hazard, MEASURED

**Date:** 2026-08-26 · **Status:** hazard **CONFIRMED**, quantified, and the §E.5 option-P2 fix
measured to close it. Nothing here is committed.

---

## 0. What I changed to make anything run

The repo has `src = "src"` in `[profile.default]` and neither `src/` nor `test/` exists — everything
lives under `archive/`. **The default profile was NOT touched.** One addition to `foundry.toml`:

```toml
# TEMPORARY research profile (protocol-fee experiment, PLAN §E.5). Does not touch the default
# profile. Points src/test at the archived tree so the archived spike can run unmodified.
[profile.spike]
src = "archive/2026-08-26/src"
test = "archive/2026-08-26/test"
```

No `src/` or `test/` was created at the repo root. Phase 0 was not started.

Everything below runs as:

```
FOUNDRY_PROFILE=spike forge test --match-path '<path>' -vv
```

`forge 1.5.0-stable`, solc 0.8.30. Note: `forge` is not on the default cmux `PATH`; prefix with
`export PATH="$HOME/.foundry/bin:$PATH"`.

**Files:**

| file | role |
|---|---|
| `archive/2026-08-26/test/spike/QueueAllocator.t.sol` | the archived baseline spike — **unmodified** |
| `archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol` | **NEW.** The experiment. |

`ProtocolFeeHazard.t.sol` contains `PFQueueHook`, a **verbatim** copy of the spike's `QueueHook`
(`diff` clean apart from the `QueueHook`→`PFQueueHook` rename and a 5-line header comment). The
allocator was not touched. Only the fixture around it differs.

---

## 1. Baseline — the archived spike, unmodified, GREEN

```
Ran 9 tests for archive/2026-08-26/test/spike/QueueAllocator.t.sol:QueueAllocatorSpikeTest
[PASS] test_Q1_allocationIsExact_butFaceValueRedemptionIsNot() (gas: 1427493)
  queue total token0: 2248553145997694428660
  queue total token1: 445000573750774563494
  PoolManager-measured token0: 2248553145997694428660
  PoolManager-measured token1: 445000573750774563494
  redeemed token0 (real ERC20): 2248553145997694428657
  redeemed token1 (real ERC20): 445000573750774563490
  residual token0 (redeemed - queue): -3
  residual token1 (redeemed - queue): -4
[PASS] test_Q1b_residualWithZeroSwaps() (gas: 911307)
  ZERO-SWAP residual token0: -1
  ZERO-SWAP residual token1: -1
[PASS] test_Q1c_residualDoesNotGrowWithSwapCount() (gas: 22605842)
  residual token0 @2 swaps: -2      residual token1 @2 swaps: -3
  residual token0 @40 swaps: -9     residual token1 @40 swaps: -11
  residual token0 @200 swaps: -52   residual token1 @200 swaps: -54
[PASS] test_Q1d_mechanism_zeroFeePoolDoesNotAccumulate() (gas: 35129728)
  200 swaps @ 0.30% fee, residual token0: -52   token1: -54
  200 swaps @ 0    fee, residual token0: -46    token1: -50
[PASS] test_Q2_gasProfileVersusQueueDepth() (gas: 11392306)
  entries 1  : head-only 31864 · sweep 11964  · touched 1
  entries 2  : head-only 31874 · sweep 18717  · touched 2
  entries 5  : head-only 31874 · sweep 38976  · touched 5
  entries 10 : head-only 31874 · sweep 65998  · touched 9
  entries 25 : head-only 31874 · sweep 160540 · touched 23
  entries 50 : head-only 31874 · sweep 309106 · touched 45
[PASS] test_negativeControl_flooredSharesGoesRed() (gas: 1265674)
     control reverted with: swap2: token0 conservation
[PASS] test_negativeControl_offByOneCursorGoesRed() (gas: 1162935)
     control reverted with: swap1: entry a0
[PASS] test_negativeControl_proRataGoesRed() (gas: 1171262)
     control reverted with: swap1: entry a0
[PASS] test_positiveControl_sameHarnessPassesUnmutated() (gas: 1435546)
Suite result: ok. 9 passed; 0 failed; 0 skipped; finished in 87.93ms
```

Baseline benign redemption residual over the 4-swap scenario: **−3 wei (token0), −4 wei (token1)**.
That is the §E.4 number and it is the yardstick everything below is measured against.

---

## 2. The instrument — how the protocol fee is set, and what "maximum" is

Read from source, not guessed:

* `lib/uniswap-hooks/lib/v4-core/src/libraries/ProtocolFeeLibrary.sol:8`
  `uint16 public constant MAX_PROTOCOL_FEE = 1000;` — **0.1 %, 1000 pips**, per direction.
* Packing: bits 0–11 = zeroForOne fee, bits 12–23 = oneForZero fee
  (`getZeroForOneFee`/`getOneForZeroFee`). Maximum legal packed value =
  `1000 | (1000 << 12)` = **4097000**.
* `ProtocolFees.setProtocolFee` requires `msg.sender == protocolFeeController`;
  `setProtocolFeeController` is `onlyOwner`. The PoolManager in `Deployers.sol` is deployed with
  owner `address(0x4444)` (`V4PoolManagerDeployer.deploy(address(0x4444))`). So:
  `vm.prank(0x4444) → setProtocolFeeController(test) → setProtocolFee(key, 4097000)`.
* `ProtocolFeeLibrary.calculateSwapFee`: **the protocol fee is taken from the input FIRST, then the
  LP fee is taken from the remainder.**
* `PoolManager.sol:238` credits `protocolFeesAccrued` inside `_swap()`, **before** the `afterSwap`
  hook call at `:221`.

### The measurement subtlety that matters

`protocolFeesAccrued` money **stays inside PoolManager's ERC20 balance** until
`collectProtocolFees` is called. So a conservation check written against PoolManager's raw ERC20
balance — which is what LAW 3 and the archived spike both prescribe — **cannot see this hazard.**
The queue-claimable balance is `PoolManager ERC20 balance − protocolFeesAccrued`. Both are reported
below.

---

## 3. THE EXPERIMENT — max protocol fee, same 4 swaps, same 1:4 price

`test_E1_maxProtocolFee_breaksTheLedger`, protocol fee `4097000`:

```
=============== E1: protocolFee = MAX (1000|1000<<12)
  protocol fee packed (uint24): 4097000
  queue ledger total token0: 2248684765720959878379
  queue ledger total token1: 445064332912949525426
  PoolManager-measured GROSS token0: 2248684765720959878379
  PoolManager-measured GROSS token1: 445064332912949525426
  protocolFeesAccrued(c0): 353999999999999999
  protocolFeesAccrued(c1): 20000000000000000
  GROSS conservation gap token0 (ledger - PM): 0
  GROSS conservation gap token1 (ledger - PM): 0
  NET  conservation gap token0 (ledger - (PM - pfAccrued)): 353999999999999999
  NET  conservation gap token1 (ledger - (PM - pfAccrued)): 20000000000000000
  --- swap #1  0 -> 1
      input  4000000000000000000     output   994022900418229484
      protocol fee skimmed        4000000000000000   (1000 ppm of input)
      LP fee (derived)           11988000000000000   → protocol fee = 333667 ppm of LP fee
  --- swap #2  0 -> 1
      input  300000000000000000000   output 64749180127828813328
      protocol fee skimmed      299999999999999999   ( 999 ppm of input — v4 floors it)
      LP fee (derived)          899100000000000000   → 333667 ppm of LP fee
  --- swap #3  0 -> 1
      input  50000000000000000000    output  9192464058803431708
      protocol fee skimmed       50000000000000000   (1000 ppm of input)
      LP fee (derived)          149850000000000000   → 333667 ppm of LP fee
  --- swap #4  1 -> 0
      input  20000000000000000000    output 105315234279040121567
      protocol fee skimmed       20000000000000000   (1000 ppm of input)
      LP fee (derived)           59940000000000000   → 333667 ppm of LP fee
  redeemed token0 (real ERC20): 2248330765720959878377
  redeemed token1 (real ERC20): 445044332912949525423
  REDEMPTION residual token0 (redeemed - ledger): -354000000000000002
  REDEMPTION residual token1 (redeemed - ledger): -20000000000000003
  protocolFeesAccrued(c0) at end: 353999999999999999
  protocolFeesAccrued(c1) at end: 20000000000000000
  shortfall0 - protocolFeesAccrued(c0): 3
  shortfall1 - protocolFeesAccrued(c1): 3
  shortfall token0 per swap (wei): 88500000000000000
```

### Three findings

**F1 — the hazard is REAL.** The queue's ledger claims `2248684765720959878379` token0; the position
redeems for `2248330765720959878377`. **Shortfall 354000000000000002 wei ≈ 0.354 token0**, and
`20000000000000003 wei = 0.02 token1`.

**F2 — the shortfall is EXACTLY the accrued protocol fee, plus the benign residual.**
`shortfall − protocolFeesAccrued = 3 wei` in **both** currencies — i.e. the §E.4 rounding residual
and nothing else. The mechanism is confirmed, not merely correlated: `amtIn` credits money that was
skimmed to the protocol.

**F3 — the spike's own conservation check is BLIND to it.** GROSS conservation against PoolManager's
ERC20 balances is **0 wei off in both tokens** under a maximum protocol fee. `test_E1` asserts this
explicitly. Protocol fees sit in PoolManager's ERC20 balance, so LAW 3 as literally written does not
catch this. **Any future conservation assertion must subtract `protocolFeesAccrued`.** This is the
part of the result that generalises beyond §E.5.

### It is not a max-fee artefact

`test_E2_oneWeiPipProtocolFee_alsoLeaks`, protocol fee = 1 pip each direction (`4097`, 0.0001 %):

```
  protocolFeesAccrued(c0): 353999999999999   protocolFeesAccrued(c1): 20000000000000
  GROSS conservation gap token0: 0           NET conservation gap token0: 353999999999999
  REDEMPTION residual token0: -354000000000002
  REDEMPTION residual token1: -20000000000003
```

Same shape, scaled by 1000×. Any nonzero protocol fee leaks; the leak is linear in the fee.

---

## 4. QUANTIFICATION (step 3)

Over the 4-swap scenario, max legal protocol fee (0.1 %):

| measure | token0 | token1 |
|---|---|---|
| **(a) absolute leak, total** | 353 999 999 999 999 999 wei (0.354e18) | 20 000 000 000 000 000 wei (0.02e18) |
| **(a) per swap** | 8.85e16 wei/swap (avg over 4) · 1.18e17 per token0-input leg | 2.0e16 on its single leg |
| **(b) fraction of swap input** | **1000 ppm = 0.1 % exactly** (= MAX_PROTOCOL_FEE; 999 ppm on swap 2 because v4 floors) | same |
| **(c) fraction of the LP fee** | **333 667 ppm = 33.3667 %** — exactly `1000 / (3000 × 0.999)`; **one third of the LP's entire fee income** | same |

**Versus the benign §E.4 residual of ~0.26 wei/swap:**

`8.85e16 / 0.26 ≈ 3.4 × 10^17`.

**The hazard is ~17 orders of magnitude larger than the benign redemption residual.** At the minimum
1-pip fee it is still `8.85e13 / 0.26 ≈ 3.4 × 10^14` — **14 orders of magnitude larger**. These are
not the same phenomenon and must never be conflated: §E.4 is dust; §E.5 is the LP fee's third being
booked twice.

**Shape of the insolvency.** Because allocation is front-first and redemption would pay face value,
the shortfall is not shared — front seats redeem whole and **the tail of the queue absorbs 100 % of
it**. With a max protocol fee the queue becomes short by a third of every LP fee it ever books.

---

## 5. NEGATIVE CONTROLS AND MUTATION (step 4 + LAW 5)

All 7 tests in `ProtocolFeeHazard.t.sol` pass:

```
Ran 7 tests for archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol:ProtocolFeeHazardTest
[PASS] test_C1_control_zeroProtocolFee_reproducesTheSpike()
[PASS] test_C2_control_maxProtocolFeeBoundaryIsReal()
[PASS] test_E1_maxProtocolFee_breaksTheLedger()
[PASS] test_E2_oneWeiPipProtocolFee_alsoLeaks()
[PASS] test_M1_mutation_E1AssertionsFailWithoutTheFee()
[PASS] test_M2_mutation_C1BoundIsViolatedWithTheFee()
[PASS] test_M3_mutation_P2NettedAllocatorClosesTheGap()
Suite result: ok. 7 passed; 0 failed; 0 skipped
```

**C1 — protocolFee = 0 in the same new file is exactly green.** `protocolFeesAccrued == 0` in both
currencies, gross conservation exact, redemption residual `−3 / −4` wei — **bit-identical to the
archived spike's `test_Q1`**. The delta in §3 is therefore attributable to the fee alone.

**C2 — the instrument is real.** `MAX_PROTOCOL_FEE` asserted `== 1000` from source;
`setProtocolFee(1001)` and `setProtocolFee(1001 << 12)` both revert with
`ProtocolFeeTooLarge(fee)` (asserted by selector **and** argument); `4097000` is accepted.

**Fee actually applied.** `test_E1` asserts `protocolFeesAccrued(c0) > 0` **and**
`protocolFeesAccrued(c1) > 0` before any other claim, with the message
`"the protocol fee was NEVER APPLIED, experiment void"`. Measured: `353999999999999999` and
`20000000000000000`. The fee was not silently rejected.

### Real RED runs (LAW 5 — a first-run pass is suspicion, not satisfaction)

Mutation 1 — swap the two fee settings (E1 gets 0, C1 gets max):

```
[FAIL: control leaked a protocol fee in token0: 353999999999999999 != 0]
      test_C1_control_zeroProtocolFee_reproducesTheSpike()
[FAIL: protocolFeesAccrued(c0) == 0: the protocol fee was NEVER APPLIED, experiment void: 0 <= 0]
      test_E1_maxProtocolFee_breaksTheLedger()
Suite result: FAILED. 0 passed; 2 failed
```

Mutation 2 — E1 with fee 0 **and** the "fee was applied" guards deleted, to prove the *shortfall*
assertion is itself load-bearing and not shielded by the guard:

```
[FAIL: shortfall within v4 rounding: the fee changed nothing (control C1 bound): 3 <= 8]
      test_E1_maxProtocolFee_breaksTheLedger()
```

Both mutations were reverted; the committed-to-disk file is the green one.

### M3 — the strongest control: mutate the ALLOCATOR, not the fixture

`PFQueueHookNetted` is the same allocator with **one** behavioural change — PLAN §E.5 **option P2**:

```solidity
uint256 pfNow  = outIsOne ? poolManager.protocolFeesAccrued(key.currency0)
                          : poolManager.protocolFeesAccrued(key.currency1);
uint256 pfDelta = pfNow - (outIsOne ? pfSeen0 : pfSeen1);
if (outIsOne) pfSeen0 = pfNow; else pfSeen1 = pfNow;
amtIn -= pfDelta;                       // net the skimmed protocol fee out of the credit
```

(legal because `protocolFeesAccrued` is credited at `PoolManager.sol:238`, before `afterSwap` at `:221`).

Same max protocol fee, same 4 swaps:

```
=============== M3: P2-netted allocator, protocolFee = MAX
  queue ledger total token0: 2248330765720959878380
  PoolManager-measured GROSS token0: 2248684765720959878379
  protocolFeesAccrued(c0): 353999999999999999
  GROSS conservation gap token0 (ledger - PM): -353999999999999999
  NET   conservation gap token0 (ledger - (PM - pfAccrued)): 0
  NET   conservation gap token1 (ledger - (PM - pfAccrued)): 0
  REDEMPTION residual token0 (redeemed - ledger): -3
  REDEMPTION residual token1 (redeemed - ledger): -3
```

**The shortfall collapses from −354000000000000002 wei to −3 wei — back to the §E.4 baseline.** This
proves (i) the experiment measures the allocator's over-credit and nothing incidental, (ii) the
instrument can detect the ABSENCE of the hazard, and (iii) **option P2 is measurably sufficient and
is ~10 lines** — the exactness claim survives it (NET conservation gap 0 in both tokens).

---

## 6. Verdict and recommendation for Phase 1

**The §E.5 hazard is REAL, confirmed by execution, and large.** It is not dust: at the maximum legal
protocol fee it is **one third of the LP's entire fee income**, ~17 orders of magnitude above the
benign §E.4 residual, and it accrues on **every swap in both directions**.

The insolvency is silent in exactly the way PLAN feared, and worse than assumed: **the spike's
conservation test — the project's own LAW 3 measurement — passes at 0 wei error while the position is
short 0.354 token0.** Nobody would have found this from the existing suite.

Two additional facts for the P1-vs-P2 decision:

* ⛔ **SUPERSEDED LATER THE SAME DAY — do not act on this bullet.** It read: *"**P1 (refuse)** is
  still the cheapest correct answer and PLAN's recommendation stands — we deploy the pool, so a
  nonzero protocol fee is a state we can simply forbid. But note the fee can be set **after**
  initialization by the PoolManager owner's controller, so a one-shot check at initialization is not
  enough: it must be re-read per swap (or per liquidity op) to be honest."* **The first half is the
  reasoning `PLAN.md` §E.5 has since retracted as factually wrong** — we control *deployment*, not
  the *fee*, which the second half already concedes. The adversarial pass and the **owner decision of
  2026-08-26 chose P2**; P1 would hand the `protocolFeeController` a permanent off-switch for the
  product. The per-swap-re-read point survives and applies to any fee check. See `PROGRESS.md`
  2026-08-26, `PITFALLS.md` §3.1, `PLAN.md` §E.5.
* **P2 (account for it)** now has a **measured** implementation that closes the gap to 3 wei and costs
  roughly ten lines plus one `protocolFeesAccrued` SLOAD per swap. It is no longer speculative.

**Standing correction to LAW 3 for the whole project:** conservation must be measured on
`PoolManager ERC20 balance − protocolFeesAccrued(currency)`, not on the raw balance. The raw-balance
form is blind to any protocol-fee-shaped bug.

---

## 7. Reproduce

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd /Users/mishoko/projects/UHI10
FOUNDRY_PROFILE=spike forge test --match-path 'archive/2026-08-26/test/spike/QueueAllocator.t.sol'   -vv
FOUNDRY_PROFILE=spike forge test --match-path 'archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol' -vv
```

Nothing was committed. The only non-test change is the `[profile.spike]` block appended to
`foundry.toml`.
