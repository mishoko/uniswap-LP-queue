# P2 (netted allocator) × the two-slot float — the composition experiment

**Date:** 2026-08-26 · **Closes:** `PITFALLS.md` §5.22, `withdrawal/feasibility.md` §9.5 bullet 1
**Artefact:** `docs/research/withdrawal/FeeFloatComposition.t.sol` (19 tests, all green)
**Raw output:** `docs/research/withdrawal/raw-fee-float-output.txt` and §7 below
**Reproduce:**
```bash
FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/withdrawal \
  forge test --match-path "docs/research/withdrawal/FeeFloatComposition.t.sol" -vv
```
Neither `FloatWithdraw.t.sol` nor `archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol` was modified.
The hook under test is `FloatQueueHook` character-for-character (float0/float1, `withdraw()`, the
`wmode` mutations) plus the one clearly-marked P2 netting block copied from `PFQueueHookNetted`.

---

## 1. Verdict

**THE TWO DESIGNS COMPOSE.** INVARIANT F survives a maximum protocol fee with a residual of
**0 wei** in the LAW-3-amended balance form and **4 wei** in the destructive `redeemAll()` form,
in both tokens. The residual **does not scale with the fee**: the fee accrued in the fixture was
`3.54e17` wei of token0 and `2.0e16` wei of token1 — ~17 orders of magnitude above the residual —
and the residual is the same 3–8 wei the fee-off suite already reports.

**BUT — a separate, float-independent CRITICAL defect in P2 itself was found by this experiment
(§6). `protocolFeesAccrued` is a GLOBAL per-currency counter, not per-pool.** Any other v4 pool
sharing either currency corrupts the diff, and can brick the hook permanently. P2-as-a-diff is not
shippable as written. That is a P2 bug, not a composition bug — the float is innocent — but Phase 1
cannot ship the diff form.

## 2. The instrument (test_P0) — the experiment is not void

| Check | Result |
|---|---|
| `ProtocolFeeLibrary.MAX_PROTOCOL_FEE` read from source | `1000` |
| Packing verified: `(1000 << 12) \| 1000` = `getZeroForOneFee`/`getOneForZeroFee` both `1000` | PASS |
| `setProtocolFee` actually took: `slot0.protocolFee == packed` | PASS (asserted, not assumed) |
| `protocolFeesAccrued(c0)` after 4 swaps | **353 999 999 999 999 999 wei** |
| `protocolFeesAccrued(c1)` after 4 swaps | **20 000 000 000 000 000 wei** |
| P2 netted, cumulative | **373 999 999 999 999 999 wei — exactly `pf(c0)+pf(c1)`, wei for wei** |

The fixture asserts `require(cumPf > 0)` inside the scenario builder: if `setProtocolFee` ever
silently no-ops, every test in the file fails loudly rather than passing vacuously.

## 3. THE CENTRAL QUESTION — INVARIANT F (test_P1, test_P2a–e)

Measured under LAW 3 AS AMENDED: `(PoolManager ERC20 balance − protocolFeesAccrued(c)) + floatX`
versus `sum(q[i].aX)`.

| Measurement | token0 | token1 |
|---|---|---|
| Balance form, before any withdrawal | **0 wei** | **0 wei** |
| Balance form, float ENGAGED (converted seat withdrawn) | **0 wei** | **0 wei** |
| Balance form, after **every** withdrawal in all 4 orders + interleaved | **0 wei** | **0 wei** |
| Destructive: `redeemAll() + float` − ledger | **−4 wei** | **−4 wei** |
| For scale: protocol fee accrued | 3.54e17 wei | 2.0e16 wei |

The balance form is exact by construction (`ledger == PMbal − pfAccrued + float` is an identity once
the allocator nets); the destructive form carries the §E.4 rounding drift — the position redeems
4 wei less than the ledger claims. Both bounds are the pre-existing fee-off bounds. **The residual
is dust and stays dust.**

Adversarial orders, all with the F1 dust policy and the MAX fee, leftover ledger dust:

| Order | token0 | token1 |
|---|---|---|
| `[1,0,2]` converted FIRST | 4 | 5 |
| `[0,2,1]` converted LAST | 3 | 4 |
| `[2,1,0]` reverse | 4 | 4 |
| `[0,1,2]` in order | 4 | 4 |
| interleaved with 3 further swaps (7 total) | 7 | 7 |
| 18/6 decimals, human 1:4, MAX fee | 2 | 3 |

## 4. DUST POLICY (test_P3a / test_P3b) — unchanged by the fee

* **Exact payout (non-F1):** the last withdrawer reverts `FloatShort(want, have)` short by
  **4 wei**. Same order of magnitude as the fee-off NC-F result (3 wei). Not fee-sized.
* **F1 (`pay min(face, available)`):** everyone drains, **4 / 5 wei** of ledger dust left unpaid.

The protocol fee does **not** land on the last withdrawer. It cannot: P2 removes it from the ledger
at allocation time, so no seat is ever credited with money the position does not hold.

## 5. Answers to the specific questions

**Does the float need netting too? NO — netting at allocation is sufficient.** Reason it from where
the money physically sits: `protocolFeesAccrued` is a counter *inside PoolManager's own ERC20
balance* (`ProtocolFees.sol:21,:56`); it can only leave via `collectProtocolFees`. The float is
tokens the hook has already `take()`n **out** of PoolManager — once they are on the hook's balance,
no protocol fee can attach to them, and no v4 code path can reduce them. Netting is needed exactly
once, at the moment the ledger is credited. Evidence: `_assertFloatIsReal` (float reconciled to the
hook's real ERC20 above its start-of-life mint, to the wei) passes in every test, and the balance
form of INVARIANT F is 0 with the float engaged.

**Ordering requirement between the P2 diff and the float bookkeeping? NONE.** Verified in source
*and* by execution, not assumed:
* `_updateProtocolFees` has exactly **one** non-test call site: `PoolManager.sol:238`, inside
  `_swap`, and it runs **before** `key.hooks.afterSwap` at `:221`. `modifyLiquidity` (`:145`) and
  `donate` (`:256`) never call it.
* `test_P4` asserts by execution that a full withdraw + a partial withdraw + `redeemAll()` leave
  `protocolFeesAccrued(c0)`/`(c1)` **and** the hook's `pfSeen0/1` snapshots **byte-identical**, and
  emit **0** PoolManager `Swap` events.

So a withdrawal can be interleaved anywhere relative to the snapshot. The *real* ordering
requirement is different and is stated in §6: the snapshot must see **every** accrual to the
currency, and it does not.

**Gas (vm.cool, cold hard case):** **252 694** with the fee on, versus the **252 672** float-only
baseline — **+22 gas**. P2 does not touch the withdraw path; the 22 gas is measurement noise from
the extra `protocolFee` bits in slot0. The allocator's own `afterSwap` cost including the P2 SLOAD
measured 48 641 gas on the last swap (no fee-off comparison was run, so no delta is claimed).

## 6. ⚠️ CRITICAL — a defect in P2 itself, surfaced by this experiment (test_X1, test_X2)

`poolManager.protocolFeesAccrued(currency)` is **global per currency**, not per pool. The diff
`pfNow − pfSeen` therefore absorbs the protocol fees of **every other v4 pool that shares either
currency**. This is float-independent and would have hit Phase 1 in production.

**X1 — silent under-credit (the everyday case).** A second pool on the same pair (fee tier 500) took
`2 000 000 000 000 000` wei of token0 protocol fee. On QUEUE's very next swap the hook's `pfDelta`
was `301 999 999 999 999 999` instead of its own `299 999 999 999 999 999`, and it credited the
queue `299 698 000 000 000 001` instead of the correct `299 700 000 000 000 001` — **under-credited
by exactly the foreign pool's fee, 2e15 wei**, stranded in the position and owed to nobody. This
needs no attacker: ordinary volume on any other pool of the same token does it continuously.

**X2 — permanent brick (the tail case).** If foreign accrual since QUEUE's last swap exceeds the
next swap's input, `amtIn -= pfDelta` **underflows inside `afterSwap`** and the swap reverts. A
1e15-wei swap succeeded as a control; after a foreign pool accrued 4e15 wei, the identical swap
**REVERTED** with `Panic(0x11)` wrapped in v4's `WrappedError`. And it is permanent: the failed swap
never advances `pfSeen0` (asserted unchanged at `1 000 000 000 000` afterwards), so every subsequent
swap re-computes the same oversized delta. **The pool is dead.** The attacker does not need to set
any fee — they need one other pool sharing the currency with a nonzero protocol fee to exist, which
is the normal state for any listed token, and then a single swap on it.

`pfSeen0/1` also start at **0** at construction, so a currency that already carries accrued fees
bricks or mis-credits the hook's *first ever* swap.

**Follow-up required before Phase 1 (NOT solved here, do not assume it is easy):** derive the
protocol fee arithmetically from the swap instead of diffing a global counter — but note
`PITFALLS` §1.5 (`lpFee == 0` takes the entire `feeAmount` by a different formula), §1.12 (exact-out
rounds the other way), and that `amountToProtocol` is summed **per swap step** with per-step
rounding across tick crossings, so a one-line `amtIn * pf / 1e6` will not be wei-exact. Clamping
`pfDelta` to a locally-derived upper bound removes the brick but not the under-credit. This needs
its own experiment with its own negative control.

## 7. Negative controls — every one asserts a specific number or reason

| # | Control | Result |
|---|---|---|
| **NC-1** | Remove P2, keep the float and the MAX fee (`W_OK`) | **RED.** INVARIANT F slack `−353 999 999 999 999 999` (token0) and `−20 000 000 000 000 000` (token1) — **exactly `protocolFeesAccrued`, asserted with `assertEq`**. The last withdrawer reverts `FloatShort` short by **354 000 000 000 000 003 wei** = 4.4e16 × the 8-wei bound. |
| **NC-1b** | LAW 5: run the *same* `_assertInvariantF` used by P1/P2 against the un-netted hook | **RED** — the assertion is load-bearing, not vacuous. |
| **NC-1c** | Remove P2, keep the float, F1 dust policy | Nobody reverts; the loss is **silent**. Unpaid ledger `354 000 000 000 000 003` / `20 000 000 000 000 004` wei — the protocol fee ±4 wei, asserted. This is the shape the amended LAW 3 was written to catch. |
| **NC-2** | `protocolFee = 0` with the float | Reproduces the existing float suite **to the wei**: seat1 `a0 == 258 877 453 809 749 247 723` (FloatWithdraw `test_R1`), post-withdrawal `liq == 884 814 917 170 750 529 333` (`test_ATK_2`), dust 3/5. The composition changes nothing when the fee is off. |
| **NC-3** | Over-entitlement with the fee ON | `OverEntitlement` on `w0+1`, on `w1=1` at a converted seat, on a re-visit after a full withdrawal, and on a seat trying to eat another seat's float. Plus: after a full teardown PoolManager's balance still `>= protocolFeesAccrued` in both currencies — **the queue cannot reach the protocol's money**. |
| **P4** | Ordering | `protocolFeesAccrued` and `pfSeen` unchanged across withdrawals; 0 `Swap` events. |

For reference, the fee-on seat-1 ledger is `258 858 901 104 999 807 724` versus
`258 877 453 809 749 247 723` fee-off — the fee changes the allocation by 1.86e16 wei, so the
fee-on and fee-off runs are genuinely different runs, not the same numbers relabelled.

## 8. What is still UNTESTED after this

* `lpFee == 0` with a protocol fee (`PITFALLS` §1.5) — the netting formula's stated blind spot.
* Exact-**output** swaps under a protocol fee with the float (§1.12).
* `sweepFloatIntoPosition()` (feasibility §9.3) still unbuilt — unchanged by this work.
* Deposit-side float absorption (feasibility §9.2) — unchanged by this work.
* The §6 remedy. Nothing here validates any fix for §6.

## 9. Suggested `PITFALLS.md` rows (for the owner to paste)

* **§5.22 → CLOSED / MEASURED.** P2 and the float compose; INVARIANT F residual 0 wei (balance form),
  4 wei (destructive), does not scale with the fee. Evidence: this file.
* **NEW row (Phase 1, CRITICAL, PROVEN by execution).** `protocolFeesAccrued` is global per currency;
  P2-as-a-diff under-credits by any foreign pool's fee and underflows-then-bricks permanently when the
  foreign accrual exceeds one swap's input. Evidence: `FeeFloatComposition.t.sol` `test_X1`, `test_X2`.

---

## 10. FULL FORGE OUTPUT

```
No files changed, compilation skipped

Ran 1 test for docs/research/withdrawal/FeeFloatComposition.t.sol:FeeFloatAsymmetricDecimalsTest
[PASS] test_X1_composition_survivesUnequalDecimalsWithMaxFee() (gas: 1546721)
Logs:
  token0 decimals: 6
  token1 decimals: 18
  seeded token0 (raw): 1000000000000
  seeded token1 (raw): 4000000000000000000000000
  protocolFeesAccrued c0: 177000000
  protocolFeesAccrued c1: 160000000000000000000
  asym INV-F slack t0: 0
  asym INV-F slack t1: 0
  asym INV-F slack t0: 0
  asym INV-F slack t1: 0
  asym INV-F slack t0: 0
  asym INV-F slack t1: 0
  asym LEFTOVER ledger dust token0: 2
  asym LEFTOVER ledger dust token1: 3

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 3.98ms (2.06ms CPU time)

Ran 18 tests for docs/research/withdrawal/FeeFloatComposition.t.sol:FeeFloatCompositionTest
[PASS] test_G1_gasOfTheFloatWithdrawUnderAProtocolFee() (gas: 1733671)
Logs:
  HARD CASE withdraw gas, fee ON (cold, incl. call overhead): 252694
  float-only baseline (FloatWithdraw.t.sol test_G1)         : 252672
  GAS DELTA vs the float-only baseline                      : 22
  allocator gas last swap (P2 SLOAD included)               : 48641

[PASS] test_NC1_nettingRemoved_goesRed() (gas: 1751755)
Logs:
  NC1 INV-F slack t0 (backing-ledger): -353999999999999999
  NC1 INV-F slack t1 (backing-ledger): -20000000000000000
  NC1 protocolFeesAccrued c0        : 353999999999999999
  NC1 protocolFeesAccrued c1        : 20000000000000000
  NC1 FloatShort want           : 1922942404817326980722
  NC1 FloatShort have           : 1922588404817326980719
  NC1 SHORTFALL (wei)           : 354000000000000003
  NC1 shortfall / DUST bound    : 44250000000000000

[PASS] test_NC1b_theInvariantFAssertionIsLoadBearing() (gas: 1404797)
Logs:
    INV-F slack t0 (backing-ledger) mutation: -353999999999999999
    INV-F slack t1 (backing-ledger) mutation: -20000000000000000

[PASS] test_NC1c_nettingRemoved_F1_silentlyStripsTheLastWithdrawers() (gas: 1557477)
Logs:
    seat            : 1
       SHORT-PAID t0: 0
       SHORT-PAID t1: 0
    seat            : 0
       SHORT-PAID t0: 0
       SHORT-PAID t1: 0
    seat            : 2
       SHORT-PAID t0: 354000000000000003
       SHORT-PAID t1: 20000000000000004
  NC1c leftover UNPAID ledger t0: 354000000000000003
  NC1c leftover UNPAID ledger t1: 20000000000000004
  NC1c protocolFeesAccrued c0   : 353999999999999999
  NC1c protocolFeesAccrued c1   : 20000000000000000
  NC1c unpaid / the 8-wei bound : 46750000000000000

[PASS] test_NC2_zeroProtocolFee_reproducesTheFloatSuiteExactly() (gas: 1562859)
Logs:
    INV-F slack t0 (backing-ledger) NC2: 0
    INV-F slack t1 (backing-ledger) NC2: 0
    INV-F slack t0 (backing-ledger) NC2/drain: 0
    INV-F slack t1 (backing-ledger) NC2/drain: 0
    INV-F slack t0 (backing-ledger) NC2/drain: 0
    INV-F slack t1 (backing-ledger) NC2/drain: 0
  NC2 leftover ledger dust t0   : 3
  NC2 leftover ledger dust t1   : 5

[PASS] test_NC3_cannotExceedEntitlement_feeOn() (gas: 1666676)
Logs:
    INV-F slack t0 (backing-ledger) NC3: 0
    INV-F slack t1 (backing-ledger) NC3: 0
  PM raw balance c0 after full teardown: 354000000000000003
  protocolFeesAccrued c0               : 353999999999999999

[PASS] test_P0_maxLegalProtocolFeeIsActuallyOn() (gas: 1491113)
Logs:
  protocolFeesAccrued(c0) after 4 swaps (wei): 353999999999999999
  protocolFeesAccrued(c1) after 4 swaps (wei): 20000000000000000
  hook cumulative NETTED out of amtIn      (wei): 373999999999999999

[PASS] test_P1_invariantF_survivesMaxProtocolFee() (gas: 1712666)
Logs:
  ledger t0                     : 2248330765720959878380
  ledger t1                     : 445044332912949525426
  PM raw balance c0             : 2248684765720959878379
  protocolFeesAccrued c0        : 353999999999999999
  PM backing c0 (raw - pfee)    : 2248330765720959878380
    INV-F slack t0 (backing-ledger) P1/pre-withdraw: 0
    INV-F slack t1 (backing-ledger) P1/pre-withdraw: 0
  seat1 ledger a0 (fee ON)      : 258858901104999807724
    INV-F slack t0 (backing-ledger) P1/float-engaged: 0
    INV-F slack t1 (backing-ledger) P1/float-engaged: 0
  REDEEMED t0 + float0          : 1989471864615960070652
  ledger t0                     : 1989471864615960070656
  RESIDUAL t0 (have - ledger)   : -4
  REDEEMED t1 + float1          : 445044332912949525422
  ledger t1                     : 445044332912949525426
  RESIDUAL t1 (have - ledger)   : -4
  protocolFeesAccrued c0 (for scale): 353999999999999999

[PASS] test_P2a_allSeats_convertedFIRST() (gas: 1844053)
Logs:
    withdrew seat: 1
       face a0  : 258858901104999807724
       paid a0  : 258858901104999807724
       face a1  : 0
       paid a1  : 0
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[1,0,2]: 0
    INV-F slack t1 (backing-ledger) fee/order[1,0,2]: 0
    withdrew seat: 0
       face a0  : 66652402203450416915
       paid a0  : 66652402203450416915
       face a1  : 19980000000000000000
       paid a1  : 19980000000000000000
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[1,0,2]: 0
    INV-F slack t1 (backing-ledger) fee/order[1,0,2]: 0
    withdrew seat: 2
       face a0  : 1922819462412509653741
       paid a0  : 1922819462412509653737
       face a1  : 425064332912949525426
       paid a1  : 425064332912949525421
       SHORT a0 : 4
       SHORT a1 : 5
    INV-F slack t0 (backing-ledger) fee/order[1,0,2]: 0
    INV-F slack t1 (backing-ledger) fee/order[1,0,2]: 0
  LEFTOVER ledger dust token0   : 4
  LEFTOVER ledger dust token1   : 5
  protocolFeesAccrued c0 (scale): 353999999999999999

[PASS] test_P2b_allSeats_convertedLAST() (gas: 1786114)
Logs:
    withdrew seat: 0
       face a0  : 66652402203450416915
       paid a0  : 66652402203450416915
       face a1  : 19980000000000000000
       paid a1  : 19980000000000000000
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[0,2,1]: 0
    INV-F slack t1 (backing-ledger) fee/order[0,2,1]: 0
    withdrew seat: 2
       face a0  : 1922819462412509653741
       paid a0  : 1922819462412509653741
       face a1  : 425064332912949525426
       paid a1  : 425064332912949525422
       SHORT a0 : 0
       SHORT a1 : 4
    INV-F slack t0 (backing-ledger) fee/order[0,2,1]: 0
    INV-F slack t1 (backing-ledger) fee/order[0,2,1]: 0
    withdrew seat: 1
       face a0  : 258858901104999807724
       paid a0  : 258858901104999807721
       face a1  : 0
       paid a1  : 0
       SHORT a0 : 3
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[0,2,1]: 0
    INV-F slack t1 (backing-ledger) fee/order[0,2,1]: 0
  LEFTOVER ledger dust token0   : 3
  LEFTOVER ledger dust token1   : 4
  protocolFeesAccrued c0 (scale): 353999999999999999

[PASS] test_P2c_allSeats_reverse() (gas: 1844920)
Logs:
    withdrew seat: 2
       face a0  : 1922819462412509653741
       paid a0  : 1922819462412509653741
       face a1  : 425064332912949525426
       paid a1  : 425064332912949525426
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[2,1,0]: 0
    INV-F slack t1 (backing-ledger) fee/order[2,1,0]: 0
    withdrew seat: 1
       face a0  : 258858901104999807724
       paid a0  : 258858901104999807724
       face a1  : 0
       paid a1  : 0
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[2,1,0]: 0
    INV-F slack t1 (backing-ledger) fee/order[2,1,0]: 0
    withdrew seat: 0
       face a0  : 66652402203450416915
       paid a0  : 66652402203450416911
       face a1  : 19980000000000000000
       paid a1  : 19979999999999999996
       SHORT a0 : 4
       SHORT a1 : 4
    INV-F slack t0 (backing-ledger) fee/order[2,1,0]: 0
    INV-F slack t1 (backing-ledger) fee/order[2,1,0]: 0
  LEFTOVER ledger dust token0   : 4
  LEFTOVER ledger dust token1   : 4
  protocolFeesAccrued c0 (scale): 353999999999999999

[PASS] test_P2d_allSeats_inOrder() (gas: 1844943)
Logs:
    withdrew seat: 0
       face a0  : 66652402203450416915
       paid a0  : 66652402203450416915
       face a1  : 19980000000000000000
       paid a1  : 19980000000000000000
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[0,1,2]: 0
    INV-F slack t1 (backing-ledger) fee/order[0,1,2]: 0
    withdrew seat: 1
       face a0  : 258858901104999807724
       paid a0  : 258858901104999807724
       face a1  : 0
       paid a1  : 0
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) fee/order[0,1,2]: 0
    INV-F slack t1 (backing-ledger) fee/order[0,1,2]: 0
    withdrew seat: 2
       face a0  : 1922819462412509653741
       paid a0  : 1922819462412509653737
       face a1  : 425064332912949525426
       paid a1  : 425064332912949525422
       SHORT a0 : 4
       SHORT a1 : 4
    INV-F slack t0 (backing-ledger) fee/order[0,1,2]: 0
    INV-F slack t1 (backing-ledger) fee/order[0,1,2]: 0
  LEFTOVER ledger dust token0   : 4
  LEFTOVER ledger dust token1   : 4
  protocolFeesAccrued c0 (scale): 353999999999999999

[PASS] test_P2e_interleavedWithSwaps() (gas: 2238474)
Logs:
    INV-F slack t0 (backing-ledger) interleave/w1: 0
    INV-F slack t1 (backing-ledger) interleave/w1: 0
    INV-F slack t0 (backing-ledger) interleave/s1: 0
    INV-F slack t1 (backing-ledger) interleave/s1: 0
    INV-F slack t0 (backing-ledger) interleave/s2: 0
    INV-F slack t1 (backing-ledger) interleave/s2: 0
    INV-F slack t0 (backing-ledger) interleave/w0partial: 0
    INV-F slack t1 (backing-ledger) interleave/w0partial: 0
    INV-F slack t0 (backing-ledger) interleave/s3: 0
    INV-F slack t1 (backing-ledger) interleave/s3: 0
    withdrew seat: 0
       face a0  : 25668612915723650303
       paid a0  : 25668612915723650303
       face a1  : 11541068011143014478
       paid a1  : 11541068011143014478
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) interleave/drain: 0
    INV-F slack t1 (backing-ledger) interleave/drain: 0
    withdrew seat: 2
       face a0  : 1922819462412509653741
       paid a0  : 1922819462412509653734
       face a1  : 425064332912949525426
       paid a1  : 425064332912949525419
       SHORT a0 : 7
       SHORT a1 : 7
    INV-F slack t0 (backing-ledger) interleave/drain: 0
    INV-F slack t1 (backing-ledger) interleave/drain: 0
    withdrew seat: 1
       face a0  : 0
       paid a0  : 0
       face a1  : 0
       paid a1  : 0
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) interleave/drain: 0
    INV-F slack t1 (backing-ledger) interleave/drain: 0
  LEFTOVER ledger dust token0   : 7
  LEFTOVER ledger dust token1   : 7
  protocolFeesAccrued c0 (scale): 383999999999999999

[PASS] test_P3a_dustPolicyExactPayout_lastWithdrawerUnderMaxFee() (gas: 1834978)
Logs:
  last seat face a0             : 1922819462412509653741
  last seat face a1             : 425064332912949525426
  float0 available              : 1
  float1 available              : 44324716953901368837
  last withdrawal succeeded?: NO
    FloatShort want             : 1922819462412509653741
    FloatShort have             : 1922819462412509653737
    SHORTFALL (wei)             : 4
    protocolFeesAccrued (scale) : 353999999999999999

[PASS] test_P3b_dustPolicyF1_lastWithdrawerUnderMaxFee() (gas: 1822799)
Logs:
    withdrew seat: 1
       face a0  : 258858901104999807724
       paid a0  : 258858901104999807724
       face a1  : 0
       paid a1  : 0
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) P3/F1: 0
    INV-F slack t1 (backing-ledger) P3/F1: 0
    withdrew seat: 0
       face a0  : 66652402203450416915
       paid a0  : 66652402203450416915
       face a1  : 19980000000000000000
       paid a1  : 19980000000000000000
       SHORT a0 : 0
       SHORT a1 : 0
    INV-F slack t0 (backing-ledger) P3/F1: 0
    INV-F slack t1 (backing-ledger) P3/F1: 0
    withdrew seat: 2
       face a0  : 1922819462412509653741
       paid a0  : 1922819462412509653737
       face a1  : 425064332912949525426
       paid a1  : 425064332912949525421
       SHORT a0 : 4
       SHORT a1 : 5
    INV-F slack t0 (backing-ledger) P3/F1: 0
    INV-F slack t1 (backing-ledger) P3/F1: 0
  F1 leftover ledger dust t0    : 4
  F1 leftover ledger dust t1    : 5
  protocolFeesAccrued c0 (scale): 353999999999999999

[PASS] test_P4_ordering_withdrawDoesNotAccrueProtocolFees() (gas: 1734743)
Logs:
  PoolManager Swap events during withdrawals: 0

[PASS] test_X1_foreignPoolSharingACurrencyCorruptsTheP2Diff() (gas: 1873845)
Logs:
  foreign pool accrued protocolFees(c0): 2000000000000000
  our swap input (PM delta)     : 300000000000000000000
  our pool's OWN protocol fee   : 299999999999999999
  CORRECT credit (in - ourFee)  : 299700000000000000001
  hook ACTUALLY credited        : 299698000000000000001
  hook lastPfDelta (over-netted): 301999999999999999
  foreign pool's fee            : 2000000000000000

[PASS] test_X2_foreignPoolCanBrickTheHookEntirely() (gas: 1961316)
Logs:
  control swap OK, hook pfSeen0: 1000000000000
  foreign fee parked in the counter: 4000000000000000
  small swap after the foreign accrual: REVERTED
  hook pfSeen0 after the failed swap (unchanged => permanent): 1000000000000

Suite result: ok. 18 passed; 0 failed; 0 skipped; finished in 7.72ms (37.41ms CPU time)

Ran 2 test suites in 168.21ms (11.70ms CPU time): 19 tests passed, 0 failed, 0 skipped (19 total tests)
```
