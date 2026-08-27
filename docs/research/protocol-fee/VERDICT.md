# Protocol fee hazard (PLAN §E.5) — research verdict

> # ⚠️ SUPERSEDED IN PART — READ THIS FIRST
>
> **This document was written BEFORE the experiment was run.** It is kept as the record of what was
> believed from source-reading alone. **§1–§4 stand** (they are source-traced and were confirmed by
> execution). **§5, §6 and §7 are SUPERSEDED — do not act on them:**
>
> | Superseded here | What is true now | Where |
> |---|---|---|
> | §5: *"P2 is worse than it looks… **Do not do this**"* — it claimed a netted allocator must reimplement v4's swap loop and would break wei-exactness | **P2 was built as a prototype and MEASURED to close the gap from −0.354e18 to −3 wei** (the §E.4 baseline), in ~10 lines. It does not replicate the swap loop; it diffs `protocolFeesAccrued` | `experiment.md` §5 (`test_M3_mutation_P2NettedAllocatorClosesTheGap`) |
> | §5: P3 needs a **`beforeSwap` permission**, a re-mined hook address and ~15% on the headline gas number | **False.** `_updateProtocolFees` runs at `PoolManager.sol:238`, **before** `afterSwap` at `:221`, so the diff can be taken inside `_afterSwap` with **no extra permission**. Cost ≈ 1 SLOAD + 1 SSTORE | `experiment.md`; `PITFALLS.md` §1.9, §7.2 |
> | §6.1: *"Phase 1 ships **P1**"* | **OWNER DECISION 2026-08-26: ship P2**, not a refusal. P1 hands the `protocolFeeController` a permanent off-switch, and the justification PLAN gave for it ("we control the pool we deploy") was factually wrong and has been retracted | `PROGRESS.md` 2026-08-26; `PITFALLS.md` §3.1; `PLAN.md` §E.5 |
> | §7: *"**no test has yet been run** with a nonzero protocol fee"* | **False since the same day** — 7 tests including 3 mutations were executed, reproduced independently | `experiment.md`; `archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol` |
>
> §6.3 (*a protocol-fee test must assert `protocolFeesAccrued > 0`*) **survives and is now a standing
> rule** (`PITFALLS.md` §2.13). §7's first bullet — that live protocol fees are unverified — also
> survives: the Proposal-100 reporting is **press-sourced only** (`v4-mechanics.md` §9, `PITFALLS.md`
> §5.15). Nothing here is deleted; supersession is recorded, not hidden.

**Date:** 2026-08-26 · **Status of hazard:** REAL, CONFIRMED AT SOURCE · **Fatal to project:** NO
**All claims below are traced to vendored source under `lib/uniswap-hooks/lib/v4-core/src/`.
Nothing here is from memory of Uniswap v4.**

---

## 1. The hazard is real. The "it evaporates" steelman is dead.

PLAN §E.5 worried the ledger over-credits when a protocol fee is set. There was an obvious escape
hatch: *maybe the delta the hook reads is already net of the protocol fee*. It is not. Order of
operations in `libraries/Pool.sol`:

| Line | What happens |
|---|---|
| 361-367 | `computeSwapStep` runs with the **composed** `swapFee` (`ProtocolFeeLibrary:37-45`) |
| 369-381 | **The swapper's delta is computed from `step.amountIn + step.feeAmount`** |
| 384-396 | *Only then:* `step.feeAmount -= delta; amountToProtocol += delta;` |
| 398-403 | LP fee growth credited from the **reduced** `step.feeAmount` |

**The swap delta a hook reads is NOT net of the protocol fee. The LP position is.**
The swapper pays the full fee-inclusive input; the position receives strictly less. The gap is
exactly `amountToProtocol`.

## 2. The reference spike sits in precisely the vulnerable configuration

From `archive/2026-08-26/test/spike/QueueAllocator.t.sol`:

- **line 127** — `poolManager.modifyLiquidity(...)`: the hook holds a **real v4 LP position**.
  Its redeemable value is therefore governed by fee growth, i.e. the *post-skim* number.
- **line 153, 169-171** — `_afterSwap(..., BalanceDelta d, ...)` → `_allocate(d)` →
  `e0 = -d.amount0()`: the ledger credit is the **swapper's** delta, i.e. the *pre-skim* number.

Credit from the pre-skim side, backing from the post-skim side. That is the bug, and it is
structural, not incidental.

## 3. Magnitude: bounded and small, but not dust

- `libraries/ProtocolFeeLibrary.sol:8` — `MAX_PROTOCOL_FEE = 1000`
- `libraries/ProtocolFeeLibrary.sol:15` — `PIPS_DENOMINATOR = 1_000_000`

**Ceiling = 0.1% of the swap amount, settable per direction.**
`Pool.sol:105` — a newly initialized pool has protocol fee **0**.

Scale against the known-benign redemption residual (~0.26 wei/swap, PLAN §E.4): on a 1e18 swap the
worst-case skim is 1e15 wei. That is ~15 orders of magnitude larger. **This would not be quietly
absorbed by the last withdrawer. It is a genuine solvency leak, not dust.**

## 4. The remedy is cheap AND withdrawal-safe — this is why the project survives

The catastrophic version of remedy P1 would be a blanket revert that also traps deposits. **It does
not, and this is structural.** Spike hook permissions (`QueueAllocator.t.sol:59-63`):

```
p.beforeAddLiquidity = true;
p.afterSwap          = true;
```

The withdrawal path is `unlock()` -> `unlockCallback` -> `modifyLiquidity(negative)`
(spike lines 119, 124-131). Liquidity **removal** is not hooked at all — `beforeRemoveLiquidity` /
`afterRemoveLiquidity` are both false, and `beforeAddLiquidity` fires only on positive deltas.

**Therefore a revert in `_afterSwap` halts trading but CANNOT block withdrawals.**
Worst case under P1: governance sets a fee, the pool stops trading, every depositor withdraws
normally. That is a liveness failure, not a loss-of-funds failure. Acceptable, and honest.

Reading the fee costs one `extsload`: `StateLibrary.getSlot0(manager, poolId)` returns
`(sqrtPriceX96, tick, protocolFee, lpFee)` (`libraries/StateLibrary.sol:40-52`).

## 5. Against P2, and a better P3 the plan did not consider — ⛔ **SUPERSEDED, see the banner at the top. P2 was measured to work in ~10 lines with no extra permission.**

**P2 ("subtract the protocol fee from amtIn") is worse than it looks.** `amountToProtocol` is
accumulated per tick-step inside the swap loop with its own rounding (`Pool.sol:391-393`).
Reproducing it in the hook means reimplementing v4's swap loop. Any approximation breaks
wei-exactness — which is the project's single headline proven claim. **Do not do this.**

**P3 (not in PLAN, and strictly better than P2):** `protocolFeesAccrued` is public
(`ProtocolFees.sol:21`, `interfaces/IProtocolFees.sol:28`). Snapshot it in `beforeSwap` and read it
again in `afterSwap`; the difference is the **exact** protocol fee taken by this swap, with zero
math replication and wei-exactness preserved. Costs: one extra hook permission (`beforeSwap`, so a
different mined hook address) and ~2 extra storage reads (~4-5k gas against a 31,874 head-only
baseline — a real ~15% hit on the headline gas number).

## 6. Recommendation — ⛔ **SUPERSEDED. The owner decided P2 on 2026-08-26; §6.1's "Phase 1 ships P1" is dead. §6.3 survives.**

1. **Phase 1 ships P1** — read `protocolFee` in `_afterSwap`, revert if nonzero, with an asserted
   specific reason. Satisfies acceptance criterion 1.10. Cheap, honest, withdrawal-safe.
2. **Record P3 as the known upgrade path.** Do not build it now: the protocol fee is 0 by default,
   and P3 taxes the headline gas metric for a contingency that has not occurred.
3. **Test 1.10 must assert `protocolFeesAccrued > 0`** to prove the fee was actually applied, not
   silently rejected by `setProtocolFee`. Without that check the test proves nothing.

## 7. UNVERIFIED — do not claim these — ⚠️ **PARTLY SUPERSEDED: the second bullet ("no test has yet been run") is false since 2026-08-26. The first bullet still stands.**

- Whether Uniswap governance has ever enabled the protocol fee on any live v4 pool, on any chain.
  Not checkable from this tree. **Do not assert "it is zero everywhere in practice" without a source.**
- The empirical measurement itself. Everything above is derived from source; **no test has yet been
  run with a nonzero protocol fee.** The number in §3 is a source-derived ceiling, NOT a measurement.
