# Withdrawal feasibility — settling PITFALLS §5.5 / §5.6

**Date:** 2026-08-26 · **Status of every claim below is tagged.**
**Artefact:** `docs/research/withdrawal/FloatWithdraw.t.sol` (22 tests, 22 pass, 8 negative controls).
**Raw output:** `raw-forge-output.txt` (this spike) and `raw-probe-output.txt` (the reproduction).

```bash
export PATH="$HOME/.foundry/bin:$PATH"
FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/withdrawal \
  forge test --match-path "docs/research/withdrawal/FloatWithdraw.t.sol" -vv
```

**VERDICT: FEASIBLE-WITH-CAVEATS.** The float works, at the hard case, to the wei. Three caveats are
listed in §9 and none of them is the withdrawal question — they are dust policy, a required
float-reinjection path that is UNBUILT, and the fact that everything here ran at protocol fee 0.

---

## 1. Reproduction — PROVEN, numbers identical

`raw-probe-output.txt`. After the spike's own four-swap scenario at `SQRT_PRICE_1_4`:

| seat | ledger a0 | ledger a1 | releases t0 at Δ=min | releases t1 at Δ=min | short t1 |
|---|---:|---:|---:|---:|---:|
| 0 | 66531939204193927195 | 20000000000000000000 | 66531939204193927193 | 13171468664062121000 | −6828531335937879000 |
| **1** | **258877453809749247723** | **0** | **0** | **0** | 0 |
| 2 | 1923143752983751253742 | 425000573750774563494 | 1923143752983751253740 | 380728834630383879473 | −44271739120390684021 |

Seat 1 withdraws **nothing**. Re-asserted as a test (`test_R1`), which also proves §B.7-as-specified
reverts with the *specific* error `NaiveReleasedNothing(258877453809749247723, 0)`.

---

## 2. The aggregate invariant — **PROVEN TRUE, and the probe was reading the wrong number**

`test_A1_aggregateInvariant_ledgerSumEqualsRedeemable`.

The probe's line *"position releases token0: 2247491145997694428657"* is **principal only**. It is
computed with `LiquidityAmounts.getAmountsForLiquidity`, which does not know about accrued LP fees.
The apparent 1.062e18 gap is not a gap:

```
ledger sum a0                  : 2248553145997694428660
position PRINCIPAL only  t0    : 2247491145997694428657
  gap (ledger - principal) t0  : 1062000000000000003
LP fee earned on token0 in     : 1062000000000000000     <- 0.30% x 354e18 in.  EXACT.

ledger sum a1                  : 445000573750774563494
position PRINCIPAL only  t1    : 444940573750774563491
  gap (ledger - principal) t1  : 60000000000000003
LP fee earned on token1 in     :   60000000000000000     <- 0.30% x 20e18 in.   EXACT.
```

Measured against **real ERC20 out of a full `redeemAll()`** — principal *plus* fees owed:

```
REDEEMED token0 (real ERC20)   : 2248553145997694428657
REDEEMED token1 (real ERC20)   :  445000573750774563490
residual token0 (redeemed-ledg): -3
residual token1 (redeemed-ledg): -4
```

> **INVARIANT F (PROVEN):** `Σ q[i].a0 == redeemable token0 + float0`, and the same for token1, to
> within v4's known §E.4 rounding residual (~0.26 wei/swap, always in the pool's favour).

The float hypothesis is **not** dead. The aggregate is consistent; only the per-seat composition is
unpayable. Asserted, with the residual bounded at ≤ 8 wei — if that bound ever breaks, the design
breaks with it and the test says so.

---

## 3. The mechanism

```
withdraw(seat, w0, w1):
  require w0 <= q[seat].a0 and w1 <= q[seat].a1
  d0 = max(0, w0 - float0);  d1 = max(0, w1 - float1)      // spend the float FIRST
  if d0 or d1:
      L0 = getLiquidityForAmount0(sqrtP, hi, d0)
      L1 = getLiquidityForAmount1(lo, sqrtP, d1)
      Δ  = min(liquidity, max(L0, L1) + 1)                 // THE LOAD-BEARING LINE: the LARGER leg
      modifyLiquidity(-Δ); take() both currencies
      float0 += released0;  float1 += released1
  require float0 >= w0 and float1 >= w1
  float0 -= w0; float1 -= w1;  q[seat] -= (w0, w1);  transfer(w0, w1)
```

`max`, not `min`. Amounts released are linear in Δ at a fixed price and range, so sizing on the leg
with the larger liquidity requirement guarantees **both** legs are covered. The `+1` absorbs the two
round-downs (`getLiquidityForAmountX` and `modifyLiquidity`'s own release). The surplus is float.

**No `poolManager.swap`.** Asserted mechanically, not by reading the source: `test_NC_H` records all
logs across two withdrawals and counts `IPoolManager.Swap` events emitted by PoolManager. Result:
9 logs, **0 Swap events**, with a guard that the recording was not vacuous. PITFALLS §5.6 satisfied.

---

## 4. The hard case — PROVEN

`test_F1_hardCase_fullyConvertedSeatFirst`. Seat 1, ledger 100% token0:

```
seat1 paid token0             : 258877453809749247723   <- EXACT face value, to the wei
seat1 paid token1             : 0
liquidity pulled              : 115185082829249470667
float0 retained after         : 1062000000000000000     <- the position's whole fee debt
float1 retained after         : 51310516841576750919    <- the token1 that came along
```

Asserted: `p0 == a0`, `p1 == a1`, both arrivals confirmed on the withdrawer's **own ERC20 balance**,
seat zeroed, float reconciled against real ERC20, ledger conservation against PoolManager.

### All seats, four orderings + interleaved with swaps — PROVEN

`test_F2a..F2d`, `test_F3`. Every seat withdraws its full face value in every order. Under the §B.7
**F1** dust policy (pay `min(face, available)`), all three seats drain, the float ends at 0, the
position ends at 0, and the only thing left behind is v4's residual:

| order | leftover ledger dust t0 | dust t1 | who was short |
|---|---:|---:|---|
| `[1,0,2]` converted FIRST | 3 | 5 | seat 2 (last), 3 and 5 wei |
| `[0,2,1]` converted LAST | 3 | 4 | seat 1 (last), 3 wei |
| `[2,1,0]` reverse | 4 | 5 | seat 0 (last), 4 and 5 wei |
| `[0,1,2]` in order | 3 | 5 | seat 2 (last), 3 and 5 wei |
| interleaved w/ 3 extra swaps + a partial withdrawal | 6 | 8 | seat 2, 6 and 8 wei |

`test_F3` proves the allocator keeps working against the shrunken position: two swaps in both
directions after seat 1's withdrawal, a **partial** withdrawal of half of each of seat 0's legs, a
third swap, then a full drain — with ledger conservation asserted after every single step.

### Asymmetric decimals (18 / 6) — PROVEN

`test_X1`. Token0 sorts as the 6-decimal token; the price is derived from the decimals so the pool
is a human 1 : 4 (1,000,000 token0 against 4,000,000 token1 — never 1:1, never unit decimals).
The head converts fully (`seat 1: a0 129438726904, a1 0`), withdraws its exact face value, all
seats drain, leftover dust **2 wei / 1 wei**.

---

## 5. Conservation — LAW 3 AS AMENDED

`test_C1_conservation_amendedForm`. Solvency is measured as
`PoolManager balance(c) − protocolFeesAccrued(c) + hook float(c)`, never the raw-balance form.

```
PRE-WITHDRAW  ledger t0 : 2248553145997694428660    backing t0 : 2248553145997694428660
POST-WITHDRAW ledger t0 : 1989675692187945180937    backing t0 : 1989675692187945180937   slack 0
POST-WITHDRAW ledger t1 :  445000573750774563494    backing t1 :  445000573750774563494   slack 0
```

Slack is **exactly zero** on both currencies after the hard-case withdrawal, and the test also
asserts the slack cannot exceed 8 wei in the other direction — over-collateralisation would mean
something leaked in.

Two separate assertions, per LAW 3's second corollary:
- **ledger conservation** — `Σ q[i].aX + paidX == running total measured on PoolManager's balances`
  across every swap. Asserted after every withdrawal in every test.
- **float backing** — `hook's real ERC20 balance − its post-seed baseline == floatX`. The hook's
  start-of-life mint is subtracted out, so a slush fund cannot hide insolvency.

⚠️ **HONEST LIMIT:** this scenario runs at `protocolFeesAccrued == 0` (asserted). The amended form
is *used* but not *exercised* — nothing here tests the §E.5 interaction.

---

## 6. Negative controls — 8, each asserting a specific reason or number

| # | Control | Result |
|---|---|---|
| **NC-G** | **the load-bearing mutation**: size Δ on the `min` leg (i.e. §B.7's sizing) | RED with `FloatShort(want 20000000000000000000, have 13231468664062121000)` — short by **6.77e18**, not dust. Selector asserted. |
| NC-A | float debited by `w-1` | float claims `1062000000000000001`, real ERC20 is `1062000000000000000`; overstatement asserted `== 1`; the suite's own reconciliation goes red |
| NC-B | token1 leg paid out of currency0 | withdrawer gets `86531939204193927195` token0 (= a0+a1) and **0** token1; both numbers asserted; reconciliation goes red |
| **NC-C** | **baseline**: §B.7 naive withdraw | seat 1 reverts `NaiveReleasedNothing`. Seats 0 and 2 strand **6.77e18** and **44.27e18** token1, *and* release `1061999999999999998` token0 the §B.7 ledger has **no home for** |
| NC-D | over-entitlement, 4 ways | all four revert `OverEntitlement(want, have)` with exact operands — including a *different* seat trying to reach the float seat 1's withdrawal created |
| NC-F | exact-payout mode, last withdrawer | reverts `FloatShort`, **shortfall exactly 3 wei**. The residual is not silently swallowed |
| NC-H | mechanical no-swap check | 0 `Swap` events across two withdrawals, with a non-vacuity guard |
| NC-E | positive control | unmutated hook passes the identical path |

**NC-C is the important one:** it proves the float is load-bearing. §B.7 as specified fails at seat 1
*and* fails differently at seats 0 and 2 — because `modifyLiquidity` settles the position's **entire**
fee debt regardless of how small Δ is, so it always over-releases. §B.7 has nowhere to book that.

---

## 7. Gas — measured with `vm.cool()`

`test_G1`. `vm.cool` applied to the hook, PoolManager, and both tokens before each measurement.

| path | gas |
|---|---:|
| **hard case** (fully-converted seat; unlock + modifyLiquidity + 2 takes + 1 transfer) | **252,672** total, **227,954** measured inside the hook |
| paid **entirely from float** (no `modifyLiquidity` at all) | **45,358** |

The float is therefore also a gas *win* for every withdrawer who fits inside it.

---

## 8. Attacking the design

| Vector | Result | Status |
|---|---|---|
| Take more than entitlement | Impossible. `OverEntitlement`, 4 variants, incl. reaching another seat's float | PROVEN |
| Drain the float from an emptied seat | Impossible. 5 repeated zero-withdrawals move neither float nor position | PROVEN (`ATK_2`) |
| Steal from another seat via the float | The float is fungible *backing*; each withdrawal pays exactly face and debits exactly face. First-come-first-served is safe **only because INVARIANT F is exact**. The one place it is not exact is the §E.4 residual — 3–5 wei, eaten by the last withdrawer | PROVEN + MEASURED |
| **Depth grief: withdraw only the minority leg** | **REAL.** Seat 2 withdraws only its token1 leg → **95.51% of pool depth** torn out in one call, `float0` = 2147.83e18 sitting idle. Swaps still work (no DoS) | **MEASURED** (`ATK_1`) |
| ↳ is it cheap? | **No — self-funded and proportional.** The liquidity torn out is bounded by the attacker's own entitlement, and the idled capital is the attacker's own (`1923143752983751253742` token0 earning nothing). Collateral damage is the *other* seats' fee income | REASONED from the measurement |
| Sandwich a victim's withdrawal | Δ is sized at the **current** `sqrtP`. Pushing the price to an extreme before someone else's withdrawal maximises the teardown. Same mechanism as `ATK_1`, but triggerable by a third party | **REASONED, UNTESTED** |
| Allocator DoS via `QueueUnderflow` | Cannot happen: `ledger_X = position_X + float_X ≥ position_X ≥` any swap's output in X. The float makes underflow strictly *less* likely, never more | REASONED + exercised in `F3`/`ATK_1` |

### Does the standing float cost pool depth? YES — measured

`test_D1`. After seat 1 (the fully-converted seat) withdraws:

```
liquidity            1000000000000000000000  ->  884814917170750529333   (-11.52%)
float1 idle            51310516841576750919
position t1 left      393690056909197812571
  -> 13.03% of the pool's remaining token1 depth is sitting idle
```

In value terms at the 1:4 price: **6.43% of the pool's value was paid out, 11.52% of its depth was
destroyed, and 5.12% of its value is now idle float.** ≈ **1.79× depth destroyed per unit of value
withdrawn**, in the worst (fully-converted) case.

The float drains as later seats withdraw — but if nobody withdraws, it sits. **A permissionless
float-reinjection sweep is REQUIRED and is UNBUILT.** See §9.

---

## 9. What must change — the precise answers

### 9.1 State to add to PLAN §B.3 — exactly two slots

```solidity
// Phase 2 additions (withdrawal float) - REQUIRED, see docs/research/withdrawal/feasibility.md
uint256 internal float0;   // token0 held by the hook OUTSIDE the position, owed to the queue
uint256 internal float1;   // token1 held by the hook OUTSIDE the position, owed to the queue
```

Nothing else is new. Two further **corrections** to §B.3/§B.7 as written:

1. `uint128 internal liquidity` is already listed, but §B.7 never decrements it. **`withdraw` MUST
   decrement it by Δ**, or every later sizing computation is wrong.
2. §B.3 must carry **INVARIANT F** next to the declarations:
   `Σ q[i].aX == (what the position would release in X) + floatX`, to within the §E.4 residual.
   That single line is what makes first-come-first-served payment from a shared float safe.

`pendingWithdraw0/1` (Phase 2, rank transfers) is unrelated and does not serve this purpose.

### 9.2 Does the float change the ALLOCATOR? **No.** — PROVEN

`_allocate` in the spike hook is unchanged from `QueueAllocator.t.sol` (FRONT_FIRST path,
character-for-character). It changes **withdraw** and it has an implication for **deposit**:

- **withdraw** — the whole mechanism.
- **deposit** — §B.7 says "refund any unconsumed remainder to msg.sender". With a float that is the
  wrong answer: absorb the remainder into `floatX` and credit it to the seat, which is both cheaper
  and reduces the float. **This is a design choice that touches who gets what — owner decision,
  AGENTS.md §4. Not built, not tested here.**
- **allocator** — untouched, and structurally *safer* under a float (§8, underflow row).

### 9.3 Required and UNBUILT: `sweepFloatIntoPosition()`

Permissionless, no privileged role, no admin function: re-add
`Δ' = min(float0 / f0, float1 / f1)` worth of liquidity, credit nobody, decrement both floats by the
actual consumed amounts. Without it, depth degrades monotonically as seats withdraw imbalanced legs
(§8). **UNPROVEN — not written, not tested.** This is the single biggest gap in this result.

### 9.4 The dust policy must be chosen — PLAN §B.7's F1

Measured, both branches:
- **exact payout** → the last withdrawer's call **reverts** `FloatShort`, short by **3 wei** (NC-F).
- **F1 (`pay min(face, available)`)** → everyone drains; 3–8 wei of ledger dust is left unpaid,
  spread over whoever happens to be last.

F1 is what §B.7 already recommends and it is what the four ordering tests run under. **The float does
NOT solve §E.4 / PITFALLS §5.7.** It is orthogonal, still open, and the "face value is redeemable"
claim still must not be made.

### 9.5 Untested

- **Protocol fee ≠ 0.** Everything above ran at `protocolFeesAccrued == 0` (asserted). The amended
  LAW 3 form is used but inert. The §E.5 interaction with the float is UNTESTED.
- **The sandwich-the-withdrawal sizing attack** (§8) is REASONED only.
- **`lpFee == 0`** (PITFALLS §1.5) is untested here.
- Deposit-side float absorption (§9.2) is unwritten.

---

## 10. One-line verdict

**FEASIBLE-WITH-CAVEATS.** A two-slot shared float makes `withdraw()` pay any seat its exact ledger
composition — including a 100%-converted seat — with no `poolManager.swap`, in any order, at a 1:4
price and at 18/6 decimals, with zero conservation slack and 252,672 gas cold. The aggregate
invariant that makes it possible is exact and now asserted. What is *not* settled: the float
reinjection sweep (required, unbuilt), the dust policy (choose F1), the deposit-side interaction
(owner decision), and anything at a nonzero protocol fee.
