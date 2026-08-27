# QUEUE × v4 protocol fee — exposure analysis

**Status: RESOLVED BY EXECUTION.** Every number below was produced today by
`docs/research/protocol-fee/ProtocolFeeExposure.t.sol` against a real etched `PoolManager`, a real
`V4SwapRouter`, and the archived spike hook, unmodified.

Reproduce:
```bash
FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/protocol-fee forge test --match-contract ProtocolFeeExposureTest -vv
```

**One-line verdict: the hazard is REAL, it is ~10^17× larger than the residual PLAN §E.4 documents,
the plan's own proposed test for it is BLIND to it, the plan's justification for the recommended
remedy is factually wrong — and none of that is fatal, because the fix is ~10 lines and withdrawals
are structurally safe from the naive refusal.**

---

## 1. ARCHITECTURE — where the liquidity actually is

**A real v4 LP position, held by the hook, earning fee growth. Not flat custody, not a NoOp, not a
return-delta.** The plan and the spike agree; the spike is the evidence.

Spike, `QueueAllocator.t.sol:124-133` — the hook owns the position because it is the unlocker:

```solidity
function unlockCallback(bytes calldata data) external override returns (bytes memory) {
    require(msg.sender == address(poolManager), "pm");
    int256 ld = abi.decode(data, (int256));
    (BalanceDelta d,) = poolManager.modifyLiquidity(
        key, ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: ld, salt: bytes32(0)}), ""
    );
```

Plan agrees at `PLAN.md:392-406` (`uint128 internal liquidity; // the hook's single position`) and
`PLAN.md:452-470` (`beforeAddLiquidity` refuses every LP that is not the hook itself). The queue is a
**bookkeeping overlay on one full-range position** — `q[]` says who owns which slice of a position
the hook holds as a whole.

Permissions are exactly two, `PLAN.md:354-368` and spike `:59-62`:
`beforeAddLiquidity` + `afterSwap`. **`AFTER_SWAP_RETURNS_DELTA` is off** (`PLAN.md:373`,
*"QUEUE takes nothing from the swap"*), and **`beforeRemoveLiquidity` is off** (`PLAN.md:378-381`).
Both of those facts matter later (§5).

No ambiguity, no plan/spike divergence. ✅

## 2. PROVENANCE OF `amtIn` — whose delta is it?

**It is the SWAPPER's delta, gross of the protocol fee.** Not the hook's position delta, not a
`poolManager.swap()` result.

The chain, in v4-core (`lib/uniswap-hooks/lib/v4-core/src/`):

1. `PoolManager.sol:206-217` — `swapDelta = _swap(pool, id, ..., inputCurrency)`.
2. `PoolManager.sol:234-238` — `_swap` calls `pool.swap(params)`, gets back
   `(delta, amountToProtocol, ...)` and routes the protocol's cut to a **separate accumulator**:
   ```solidity
   // the fee is on the input currency
   if (amountToProtocol > 0) _updateProtocolFees(inputCurrency, amountToProtocol);
   ```
   `ProtocolFees.sol:66-70` — `_updateProtocolFees` only does `protocolFeesAccrued[currency] += amount`.
   **The tokens stay inside `PoolManager`'s ERC-20 balance** until `collectProtocolFees` moves them
   (`ProtocolFees.sol:44-57`). This is the whole reason the ledger test goes green — see §4.
3. `PoolManager.sol:221` — `(swapDelta, hookDelta) = key.hooks.afterSwap(key, params, swapDelta, ...)`.
   **That `swapDelta` is what lands in `BalanceDelta d`.**
4. `PoolManager.sol:226` — `_accountPoolBalanceDelta(key, swapDelta, msg.sender)`, `msg.sender` being
   the router. Confirms whose delta it is.

And it is **gross**, because `Pool.sol` accumulates the swapper's amounts using the *composed* fee
*before* the protocol's cut is carved out:

```solidity
// Pool.sol:307   — swapper is charged protocolFee ⊕ lpFee
swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
...
// Pool.sol:376-380 — the swapper's delta accumulates amountIn + feeAmount (composed fee)
amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
amountCalculated         += step.amountOut.toInt256();

// Pool.sol:384-397 — ONLY NOW is the protocol's slice removed, and only from feeGrowth
if (protocolFee > 0) {
    uint256 delta = (swapFee == protocolFee)
        ? step.feeAmount
        : (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
    step.feeAmount -= delta;
    amountToProtocol += delta;
}
// Pool.sol:401-407 — LPs get only what's LEFT
step.feeGrowthGlobalX128 += UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
```

**So `amtIn` = `step.amountIn + step.feeAmount` summed over steps, with `feeAmount` computed at the
COMBINED rate — while the position's fee growth only ever receives `feeAmount − delta`.** The
allocator (`PLAN.md:486-519`, spike `:169-176`) reads the first number and credits it to the queue.
The position never sees `delta`. **Nothing in the allocator path ever observes the position's actual
fee growth.** That is the bug in one sentence.

## 3. THE ACTUAL FAILURE MODE — the arithmetic, measured

Per swap:

```
credited to queue   =  amtIn                                        (gross)
delivered to position = amtIn − amountToProtocol                    (net)
over-credit         =  amountToProtocol
                    =  Σ_steps floor(grossStepInput · protocolFee / 1e6)
                    ≈  protocolFee/1e6 × (the whole swap input notional)
```

`protocolFee` is capped at **1000 pips = 0.1%** per direction
(`ProtocolFeeLibrary.sol:6-8`, `MAX_PROTOCOL_FEE = 1000`), packed as
`(oneForZero << 12) | zeroForOne`.

**Measured** — spike's own 4-swap scenario at `SQRT_PRICE_1_4`, protocol fee at MAX in both
directions (`test_E5_protocolFeeMax_ledgerOvercredits`):

```
ledger t0                        : 2248684765720959878379
PoolManager-ERC20-measured expT0 : 2248684765720959878379   <- LAW-3 conservation PASSES
protocolFeesAccrued c0           :     353999999999999999
redeemed token0 (real ERC20)     : 2248330765720959878377
SHORTFALL token0                 :    -354000000000000002
shortfall0 − accrued0            :                      3   <- = the pre-existing §E.4 residual
```

**The shortfall IS the accrued protocol fee, to the wei, plus the 3-wei baseline residual.** Same in
token1: 20e15 shortfall on 20e18 of reverse-direction input. Single-swap control
(`test_E5_swapperPaysMore_lpIncomeRoughlyUnchanged`): 100e18 in → 100000000000000000 accrued →
`redeem − ledger = −100000000000000002`. Zero-fee control on the identical path: `−2`.

**Magnitude vs §E.4.** The documented residual is **0.26 wei/swap**. This is **0.1% of the swap's
input notional** — 1.18 × 10^17 wei/swap in the fixture above. That is a factor of ≈ **4.5 × 10^17**.
Any intuition carried over from §E.4 ("dust, unfarmable, twenty orders of magnitude") is worthless
here.

**Who is short-changed, and when.** Nobody is short-changed *at allocation time* — every seat's
balance goes up correctly relative to the others; the ledger is internally consistent and conserves
against `PoolManager`'s gross balance. The deficit is **pool-level and latent**: the sum of all seat
balances exceeds what the one shared position can produce, by exactly Σ`amountToProtocol`.

It therefore surfaces **only at withdrawal, and it lands entirely on the tail**. Withdrawals draw
from a single position; the first callers get their face value in full; the position runs dry
`Σ amountToProtocol` short of the last claim. This is the **same shape** as the §E.4 residual — a
last-withdrawer loss — with the magnitude moved from dust to a real fraction of principal.
*(REASONED, not proven — `withdraw()` does not exist yet. What is PROVEN is the pool-level deficit
and its exact size.)*

Two further points, both REASONED:
- Under the plan's recommended dust fix **F1** (`PLAN.md:702-706`, "pay what `modifyLiquidity`
  actually returned"), a *dust* shortfall degrades gracefully. A *0.1%-of-notional* shortfall does
  not: the tail withdrawer's `modifyLiquidity(−Δ)` for their face-value amount asks for more
  liquidity than the position still has, so the honest failure is a **revert / stuck funds**, not a
  partial payment. F1 is not a mitigation for this.
- **Front-first makes the concentration worse, not better.** The head seat sees every swap and turns
  its inventory over constantly; the back of the queue is the natural last-out. So the loss
  concentrates on exactly the seats that have earned the least — and, in Phase 3+, on whoever *paid*
  for a back-of-queue seat.

**Rate of accumulation.** 0.1% of every swap's notional. A pool turning over 1× TVL per day is
0.1% insolvent per day, ~1% in ten days. This is not a slow leak; it is a leak on the same order as
the LP fee itself (0.1% protocol vs 0.2997% net LP at a 0.30% pool — the protocol takes **a third of
the fee income's worth of the queue's solvency**).

## 4. IS IT ACTUALLY A BUG? — the steelman, and why it fails

**Steelman:** *"the hook only ever credits what `PoolManager` actually received. The protocol fee
never leaves `PoolManager`. So the ledger and the ERC-20 balance agree, and there is no hazard."*

**The first half is true and the second half does not follow — and this is the dangerous part.**

`protocolFeesAccrued` is a *claim against* `PoolManager`'s balance, not a transfer out of it
(`ProtocolFees.sol:66-70`). So `PoolManager`'s ERC-20 balance **does** rise by the full gross input.
Therefore **the plan's LAW 3 measurement — the project's primary and most-trusted instrument — is
structurally blind to this bug.**

That is not a prediction. It is executed:

```
ledger t0                        : 2248684765720959878379
PoolManager-ERC20-measured expT0 : 2248684765720959878379
assertEq(t0, expT0, "LAW-3 conservation token0");   // PASSES with the protocol fee at MAX
```

**Consequence — `PLAN.md:2092` is a defective acceptance test:**

> | 3 | Protocol fee does not break the ledger | **UNTESTED** | set a protocol fee, run the conservation test (§E.5) |

Executing that instruction *exactly as written* produces **GREEN**, and green there means
"unresolved", not "safe". It is a LAW-5 trap of the plan's own making
(`PLAN.md:1353` — *"a first-run pass is a reason for suspicion"*).

The plan already contains the correct instrument and does not wire it to this criterion —
`PLAN.md:1322-1328`, LAW 3's second corollary:

> **Second corollary (solvency, and it is separate):** conservation of the *ledger* and
> *redeemability of the position* are two different claims. […] `assertEq(ledger, expected)` and
> `assertLe(ledger, actuallyRedeemable + K)` are different tests and you need both.

**Verdict: the hazard is real; confidence HIGH (executed, with a zero-fee control on the identical
path, and the shortfall equals `protocolFeesAccrued` to the wei).** The steelman does not survive —
but it survives long enough to produce a green test, which makes it worse than a hazard that fails
loudly.

The correct assertion for criterion 1.10 is against **`PoolManager` balance minus
`protocolFeesAccrued`**, or directly against `redeemAll()`.

## 5. THE TWO REMEDIES

### The plan's justification for P1 is factually wrong

`PLAN.md:1708-1709`:

> **(P1) Refuse.** Read the pool's protocol fee and revert/disable if nonzero. Simple, honest, and
> **losing nothing since we control the pool we deploy.** **Recommended.**

**We do not control the protocol fee on the pool we deploy.** `ProtocolFees.sol:35-41`:

```solidity
function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external {
    if (msg.sender != protocolFeeController) InvalidCaller.selector.revertWith();
```

`protocolFeeController` is set by the `PoolManager` **owner** (`ProtocolFees.sol:29-32`), i.e.
Uniswap governance. There is **no hook callback on `setProtocolFee`**, no pool-creator consent, no
opt-out. Deploying the pool ourselves buys us exactly nothing here. Any P1/P2 decision made on the
plan's stated reasoning is made on a false premise, and the "and it can never happen to us" comfort
must be deleted from §E.5.

### P1 — refuse if `protocolFee != 0`

- **Code:** ~4 lines. `using StateLibrary for IPoolManager;` then
  `(,, uint24 pf,) = poolManager.getSlot0(key.toId()); if (pf != 0) revert ProtocolFeeIsOn(pf);`
- **Gas: +3,303, measured** (`test_E5_P1_refuseInAfterSwap_doesNotBrickWithdrawal`). Cold and warm
  are identical, because the swap itself has necessarily already touched that pool's `slot0`. Against
  the spike's 31,874-gas head-only allocation that is **+10.4%**. Real, small, honest.
- **Leak in the fee-on window: ZERO.** The guard runs before allocation and the whole swap reverts
  atomically, so no over-credited swap can ever land. Fail-closed.

**Does it brick withdrawals? NO — and this is PROVEN, not argued.**

The structural reason: `beforeRemoveLiquidity` / `afterRemoveLiquidity` are **not** in the hook's
permissions (`PLAN.md:378-381`, spike `:59-62`), so `modifyLiquidity(−Δ)` invokes **no hook callback
at all**. Deposit (`beforeAddLiquidity`) and swap (`afterSwap`) are the only gated paths. Executed:

```
swap with protocolFee=0: OK
swap with protocolFee!=0: REVERTED (pool is dead)
WITHDRAWAL after refusal, token0: 2007999999999999999944
WITHDRAWAL after refusal, token1:  498013920485105399611
```

Governance turns the fee on mid-life, every swap dies, **and the LPs still get their money out in
full.** P1 is a pool-level pause, not a fund-level trap.

**⚠ THE MIS-IMPLEMENTATION THAT WOULD BE CATASTROPHIC.** That safety comes *entirely* from where the
check lives. Put the same `require(protocolFee == 0)` in `unlockCallback`, in a shared
`_guard()` used by every path, in a `beforeRemoveLiquidity` added "for symmetry", or in a hook-wide
modifier — and withdrawal reverts too. That converts a governance switch into **total, permanent loss
of every depositor's principal.** The guard belongs in `_afterSwap` (and optionally
`_beforeAddLiquidity`, where bricking deposits is *desirable*). **It must never touch the removal
path.** A negative control that proves withdrawal still works with the fee on is mandatory.

**Costs P1 actually carries** (none of which §E.5 mentions):
1. **Uniswap governance owns an off-switch for our product.** Not a bug, a business fact, and it must
   be said out loud rather than waved away.
2. **The gap-open on resume.** While swaps revert, the pool's price is frozen while the market moves.
   The instant the fee is switched off (or the hook is migrated), the first arbitrage swap crosses
   the whole accumulated gap — and **front-first hands that entire loss to the head seat**, which is
   the seat that paid the most for its rank. P1 does not lose principal; it can lose a great deal of
   value on resume, concentrated on exactly one depositor.

### P2 — subtract the protocol fee from `amtIn`

- **Code:** ~10 lines. Same `getSlot0` read, then pick the direction —
  `pf = zeroForOne ? pfPacked & 0xfff : pfPacked >> 12` (`ProtocolFeeLibrary.sol:17-22`) — and
  `amtIn -= FullMath.mulDiv(amtIn, pf, 1e6)`.
- **Gas:** the same +3,303 read, plus one `mulDiv` (~100). Effectively identical to P1.
- **Rounding — and it lands on the SAFE side, with a proven bound.** v4 floors *per step*
  (`Pool.sol:391-393`); a single aggregate `mulDiv` on the summed input is ≥ the sum of the per-step
  floors, so the deduction is an **over**-estimate by at most 1 wei per step. Confirmed numerically in
  the run: 354e18 gross input over 3 swaps → aggregate estimate `354e15`, actual accrued
  `353999999999999999` — **exactly 1 wei of drift, in the under-credit (solvent) direction**. That is
  the same order as the §E.4 residual the project has already accepted. QUEUE's single full-range
  position also means a swap is nearly always one step, so step-multiplicity barely arises.
- **Edge cases P2 must handle** (all real, all cheap):
  - `lpFee == 0` ⇒ `swapFee == protocolFee` ⇒ v4 takes the *entire* `feeAmount`, a different formula
    (`Pool.sol:391-392`). Either handle it or refuse that configuration.
  - Dynamic fees / `beforeSwap` `lpFeeOverride` — **not a risk for QUEUE**: it has no `beforeSwap`
    permission, so `lpFee` is the static one in the `PoolKey`.
  - Exact-output swaps: the protocol fee is still on the input currency, and `amtIn` is still the
    swapper's input leg, so the same deduction applies unchanged.
- **Product:** the pool keeps trading under any protocol fee. Nothing is bricked, nothing is
  paused, no gap-open, no governance off-switch. The queue simply credits what the position was
  actually given.
- **Test-harness consequence:** LAW 3's conservation assertion must become
  `assertEq(ledger, PoolManagerBalance − protocolFeesAccrued)`. Leave it as-is and P2 makes the
  conservation test go **red** while the code is correct.

### Recommendation

**P2, with an explicit refusal for the `lpFee == 0` case.** It is ~6 lines more than P1, costs the
same gas, its error is bounded at ≤1 wei/swap in the solvent direction (measured), and it removes
both of P1's real costs — the governance off-switch and the gap-open-on-resume that P1 dumps on the
head seat. P1 remains a defensible *deadline* choice, and it is genuinely safe for principal —
but it must be adopted for the honest reason ("we accept a governance off-switch") and not the
plan's stated one ("we control the pool"), which is false.

**Whichever is chosen, criterion 1.10's assertion must be against `redeemAll()` or against
`balance − protocolFeesAccrued`. Never against `PoolManager`'s raw balance.**

## 6. BLAST RADIUS ON `PROGRESS.md`

| `PROGRESS.md` claim | Status under a nonzero protocol fee |
|---|---|
| L34 "Front-first allocation is **exact to the wei in both tokens**" | **SURVIVES, but its scope is now misleading.** Executed: the conservation assertion passes at MAX protocol fee. It conserves against `PoolManager`'s *gross* balance, which is no longer the LP's entitlement. Must be restated as *"the ledger conserves; the position's redeemability is a separate claim (LAW 3, second corollary) and it does NOT hold with a protocol fee."* |
| L35 remainder line is load-bearing | **Unaffected.** Pure allocator arithmetic. |
| L36 pro-rata / off-by-one controls red | **Unaffected.** |
| L37 head-only gas **flat at ~31,874** | **MUST BE RE-MEASURED.** Both P1 and P2 add a `getSlot0` read to the swap path: **+3,303 measured → ~35,177, +10.4%.** Re-measure with `vm.cool()` after the remedy lands. |
| L38 sweeping swap **~6,753 gas/entry**; ~44 seats at 300k | **Per-entry marginal cost unaffected** (the guard is once per swap, not per entry), but the **fixed** term moves, so the seats-per-budget headline shifts slightly. Restate after re-measurement. |
| L39 **~0.26 wei/swap residual; the last withdrawer eats it** | **VOID unless `protocolFee == 0`.** Measured replacement: **0.1% of the swap's input notional**, ≈ 4.5 × 10^17× larger. The claim must carry the precondition explicitly. |
| L40 residual is **NOT** fee-growth truncation | **Unaffected and still true** — that control varied the *LP* fee, not the protocol fee. Note that the mechanism named here is a *third*, distinct one. |
| L41 residual is **unfarmable — off by ~20 orders of magnitude** | **THE WORST CASUALTY. VOID unless `protocolFee == 0`.** With the fee on, a wash-trader inflicts damage equal to 0.1% of their notional at a cost of ~0.3997% per leg (plus price impact). Cost-to-damage falls from ~10^20 : 1 to roughly **4 : 1**. Still unprofitable (the damage accrues to Uniswap governance, not the attacker) — but "off by twenty orders of magnitude" becomes "off by one", and a griefer with a grudge can now do real harm for real-but-payable money. |
| L42–L44 (toxicity, curves, `sender` is the router) | **Unaffected.** |

Also invalidated: **PLAN.md:1029, criterion 2.5** — *"After 200 swaps, total paid out ≤ what the
position actually redeems for, and the gap is ≤ 1 wei per swap"* — is unachievable with a protocol
fee on, under any dust fix. It needs the same `protocolFee == 0` precondition, or the P2 remedy in
place first.

---

## Artefacts

- `docs/research/protocol-fee/ProtocolFeeExposure.t.sol` — the experiment (research artefact, **not**
  a Phase-1 gate test; the Phase-1 test must be written against `src/` when it exists).
- `foundry.toml [profile.spike]` — already present; points `src`/`test` at the archived tree.

---

# APPENDIX — adversarial attack on the P1 withdrawal-safety claim

**Claim under attack:** *"P1 (revert in `_afterSwap` when `protocolFee != 0`) halts trading but CANNOT
block withdrawals, because permissions are only `{beforeAddLiquidity, afterSwap}` and the withdrawal
path is not hooked at all."*

**Result: the claim SURVIVES, and it is now stronger than stated — but it is NOT free. It is a
design constraint on Phase 2 that §B.7 does not currently satisfy, and I can prove §B.7 is
arithmetically impossible as written.**

## A1. Does a negative `liquidityDelta` invoke `beforeAddLiquidity`? — NO. Verified.

`v4-core/src/libraries/Hooks.sol:194-206`:

```solidity
function beforeModifyLiquidity(...) internal noSelfCall(self) {
    if (params.liquidityDelta > 0 && self.hasPermission(BEFORE_ADD_LIQUIDITY_FLAG)) {
        self.callHook(abi.encodeCall(IHooks.beforeAddLiquidity, (msg.sender, key, params, hookData)));
    } else if (params.liquidityDelta <= 0 && self.hasPermission(BEFORE_REMOVE_LIQUIDITY_FLAG)) {
        self.callHook(abi.encodeCall(IHooks.beforeRemoveLiquidity, (msg.sender, key, params, hookData)));
    }
}
```

The removal branch is gated on `BEFORE_REMOVE_LIQUIDITY_FLAG`, which QUEUE does not set
(`PLAN.md:378-381`, spike `:59-62`). Same on the exit side — `Hooks.sol:220-244`, the
`liquidityDelta <= 0` `else` branch requires `AFTER_REMOVE_LIQUIDITY_FLAG`, also unset. Entry point
`PoolManager.sol:156` / `:178` are the only two hook invocations in `modifyLiquidity`. **The stated
reason is exactly right.**

**A second, independent reason the lead did not claim — `noSelfCall`.** `Hooks.sol:171-175`:

```solidity
modifier noSelfCall(IHooks self) {
    if (msg.sender != address(self)) { _; }
}
```

applied to `beforeModifyLiquidity` (`:200`), and mirrored inside `afterModifyLiquidity` at `:217`
(`if (msg.sender == address(self)) return ...`). QUEUE calls `modifyLiquidity` **as itself**, from
inside its own `unlockCallback` (spike `:101`, `:119` → `:124-131`), so `msg.sender == address(self)`
and every liquidity hook is skipped **regardless of flags**. Belt and braces: the claim would hold
even if a future phase enabled `beforeRemoveLiquidity`.

## A2. Must a withdrawal ever transit a swap? — Not as specified. But §B.7 is IMPOSSIBLE as specified.

**On the letter of the spec, no.** `PLAN.md:651-661`:

```
withdraw(seatId, amount0, amount1):
  ...
  unlock():
     compute liquidityDelta to release those amounts
     modifyLiquidity(-liquidityDelta)
     take() both currencies to the hook
```

`unlock` → `unlockCallback` → `modifyLiquidity(−Δ)` → `take()`. No `poolManager.swap`. `afterSwap`
never fires. **Claim survives.**

**But `PLAN.md:655` — "compute liquidityDelta to release those amounts" — presumes a `Δ` exists that
yields an arbitrary `(amount0, amount1)` pair. It does not.** A position releases tokens in a ratio
fixed by the current price and the tick range; a seat's ledger composition is unconstrained. And
**front-first allocation deliberately drives seats to single-token composition — that IS the
mechanism** (the head surrenders all of the outgoing token and receives the incoming one,
`PLAN.md:521-548`).

Measured, `WithdrawalPathProbe.t.sol`, after the spike's own 4-swap scenario:

```
seat: 1
   ledger a0: 258877453809749247723
   ledger a1: 0
   liquidity needed to release a0: 115185082829249470666
   liquidity needed to release a1: 0
   with D=min, actually releases token0: 0
   with D=min, actually releases token1: 0
   SHORT token0 vs ledger: -258877453809749247723
```

**Seat 1 holds 258.877 token0 and zero token1, and can withdraw NOTHING** via `modifyLiquidity(−Δ)`
under the "neither leg exceeds the ledger" reading. Seat 0 and seat 2 can only extract their token0
leg, leaving 6.83 and 44.27 token1 respectively unreachable. This is not an edge case — it is the
steady state of a front-first queue.

**So Phase 2 is forced to change §B.7, and the two natural resolutions diverge sharply:**

- **(a) Swap-free — size `Δ` on the binding leg, pay the depositor that leg, hold the other leg as
  hook-side float (or immediately re-add it).** No `poolManager.swap`, so `afterSwap` never fires and
  **the claim holds.** Aggregate conservation is preserved because ledger total = position + float.
  ⚠ `PLAN.md:394-413` and `:415-424` contain **no float state** — `pendingWithdraw0/1` at `:418-419`
  is for rank transfers, not this. The state this resolution needs does not exist yet.
- **(b) Swap-to-rebalance the payout.** This is the tempting fix and it is a trap — **though not the
  trap that was expected.** `Hooks.sol:294`:
  ```solidity
  function afterSwap(...) internal returns (BalanceDelta, BalanceDelta) {
      if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);
  ```
  A hook-initiated swap **skips the hook's own `afterSwap` entirely**. So P1's guard would not fire,
  and withdrawal would not be blocked — the claim technically survives — but **the allocator would
  not run and the protocol fee would be skimmed off the rebalance swap, unguarded and unaccounted.**
  That is worse than a block: a silent leak on the withdrawal path, invisible to both remedies.

**Is a withdrawal-safe refusal constructible? YES, plainly — resolution (a) needs no swap.** But it
must be written down as a Phase-2 constraint. The property is currently true by accident, and §B.7
cannot be implemented as written, so the accident will be revisited.

## A3. Governance sets the fee on a full queue — who eats what?

**With P1 present from deployment: nobody. Accumulated shortfall is exactly ZERO. Proven.**

The guard runs in the same swap's `afterSwap`, and the revert rolls back `_updateProtocolFees`
(`PoolManager.sol:238`). Executed:

```
swap with protocolFee=0: OK
swap with protocolFee!=0: REVERTED (pool is dead)
protocolFeesAccrued c0 after the reverted swap: 0
protocolFeesAccrued c1 after the reverted swap: 0
WITHDRAWAL after refusal, token0: 2007999999999999999944
WITHDRAWAL after refusal, token1:  498013920485105399611
```

Swaps that landed *before* the fee was set ran at `protocolFee == 0` and skimmed nothing. So **no
swap can ever execute with the fee on, the deficit never starts, and every depositor withdraws
whole** — modulo the pre-existing ~0.26 wei/swap §E.4 residual, which is unchanged.

**The last-withdrawer shortfall materialises only if P1 is absent, or added after fee-on swaps have
already landed.** Then it is 0.1% of the cumulative fee-on input notional, pool-level and latent, and
it lands entirely on the tail (§3).

**One TOCTOU assumption, checked and closed.** Both remedies read `slot0` in `afterSwap` and assume
it equals what `Pool.swap` read at `Pool.sol:286-287` at the top of the same swap. There is **no
external call between them** — `PoolManager.sol:206-221` is straight-line (`_swap` → internal
`pool.swap`, internal `_updateProtocolFees`, `emit`, then `afterSwap`), and QUEUE has no `beforeSwap`.
The window is not merely unreachable; it does not exist.

## A4. Does the plan put the check somewhere more dangerous? — It puts it NOWHERE, and points at the danger.

`PLAN.md:1708-1709`:

> **(P1) Refuse.** Read the pool's protocol fee and revert/disable if nonzero. Simple, honest, and
> losing nothing since we control the pool we deploy. **Recommended.**

**No location is specified at all.** And the acceptance criterion it must satisfy,
`PLAN.md:991` (criterion 1.10):

> **Protocol fee:** with a nonzero protocol fee set on the pool, either the ledger stays consistent,
> or **the hook refuses to operate**.

**"the hook refuses to operate" is hook-wide language.** An implementer satisfying that criterion
literally will reach for the one path every hook operation shares — `unlockCallback` (spike
`:124-133`), which **both deposit and withdraw transit**. A guard there bricks withdrawal and
converts a governance switch into permanent, total loss of principal.

So: the plan does not place the check dangerously — it fails to place it, and its own acceptance
wording steers toward the single worst location. **Required edits:**
1. §E.5 P1 must say **"in `_afterSwap` only; never in `unlockCallback`, never in a shared guard,
   never in a removal-path callback."**
2. Criterion 1.10's *"the hook refuses to operate"* must become **"the hook refuses to allocate —
   swaps revert, deposits may revert, withdrawals MUST still succeed."**
3. Add a mandatory negative control: fee on → swap reverts → **withdrawal still pays out in full**.
4. Add a Phase-2 constraint: **`withdraw` must never call `poolManager.swap`** (§A2, resolution (a)).
