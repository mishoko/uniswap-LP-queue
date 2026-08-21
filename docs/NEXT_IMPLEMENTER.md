# Next-session implementer prompt — Hardcap v1+ ToB-spot

**Status (2026-08-19):** Variant A is implemented. `HardcapHook` snapshots open spot; `extraFeeBps = 0` is ToB-spot; envelope tests still use extra = 5. See the plan spike section. Do not re-spike. Remaining: video (human voice, later), not a second product.

You are a **new** agent. There is no prior chat. Do not invent a second product. Do not write a second design doc.

**Win goal:** UHI10 first is not promised. This pivot is the highest-EV on-chain path that (a) matches official “defense + recapture,” (b) ToB/OZ/Certora can respect (no tick-walk OOG), (c) is not MRLV / DualPool / FairFlow / cohort white-space. Execute it brutally well.

**Status 2026-08-18:** Variant A ToB-spot is implemented (`extraFeeBps = 0`). Spike answers are in the Implementation Plan. Envelope (42 unit + 3 invariants) stays on the `extraFeeBps = 5` tax path. Next: human-voice video, not a second product. Do not "fix" same-dir into a claw.

---

## 0. Read this order, then stop reading and spike

1. This file.
2. [`docs/Hardcap Fail-Closed MEV Cap Hook - Implementation Plan.md`](./Hardcap%20Fail-Closed%20MEV%20Cap%20Hook%20-%20Implementation%20Plan.md) — **plan wins** on conflict; then fix this file.
3. [`docs/SPIKE-sender-and-afterSwapReturnDelta.md`](./SPIKE-sender-and-afterSwapReturnDelta.md) — already solved. Do not rediscover.
4. `src/HardcapHook.sol`, `src/libraries/HardcapMath.sol`, `src/HardcapHookFinal.sol`.
5. `test/Hardcap.t.sol`, `test/HardcapForkAttacks.t.sol`, `test/HardcapInvariant.t.sol`.

Repo: `/Users/mishoko/projects/UHI10`. Foundry, solc 0.8.30, OZ `uniswap-hooks` BaseHook, remappings already set. `forge test --match-contract Hardcap` must stay the demo.

---

## 1. What already exists (do not rewrite)

A working **envelope**:

- `BaseHook`; permissions: `beforeSwap`, `afterSwap`, `afterSwapReturnDelta`, `afterAddLiquidity`, `beforeRemoveLiquidity`.
- Cork: only PoolManager, `hookData.length == 0`, bound `PoolKey` (immutables + `hooks == this`).
- Vault **inside** the hook. No owner / rescue / sweep / `donate()`.
- Shares: pending until `OFFSET`; claim weight = `totalShares + pendingTotal`; receipt requires age; `_burnRights` matured then pending; claim `min(shares, live L)` via `StateLibrary.getPositionInfo`.
- JIT: `beforeRemove` reverts if `block.number < lastAdd + OFFSET`. Key = `Position.calculatePositionKey(sender, ticks, salt)`. `sender` = unlock caller, **not** EOA, **not** hook `msg.sender`.
- Take path: unspecified currency, `FeeTakingHook` signs (`take` then return `+feeAmount`). Notional = `abs(unspecified BalanceDelta)`.
- Production name: `HardcapHookFinal`. Tests use virtual `_computeSurplus` / `_boundTake` on `HardcapHook`.
- **42 unit tests + 3 invariants.** If you break Cork / JIT / vault / cap-rail, you failed.

`EXTRA_FEE_BPS` tax is **no longer the judging product**. Leave the code path if useful for the cap-rail test hook; default deploy **`extraFeeBps = 0`**.

---

## 2. What you are implementing (one product)

**ToB-spot claw.**

```
open of block: snapshot sqrtPriceX96 + liquidity + tick from PoolManager
first swap of block: take = 0
later swap:
  if THIS swap crossed a tick (tick after != tick stored at beforeSwap): take = 0
  if getLiquidity() != openLiquidity: take = 0
  else:
    target = one SwapMath.computeSwapStep at (openSqrt, openL) toward the open tick boundary
    if that step would hit the boundary before filling: take = 0   // would-cross-at-open
    surplus = "how much better than target the taker did" on the unspecified currency
    take = min(surplus, notional * MAX_TAKE_BPS / 1e4)
    settle to hook ERC-20; vaultAccrued += take
```

Both `zeroForOne` directions. Exact-in and exact-out.

**“Better”:**

- Exact-in (`amountSpecified < 0`): unspecified is **output**. Surplus = `actualOut − targetOut` if positive.
- Exact-out (`amountSpecified > 0`): unspecified is **input**. Surplus = `targetIn − actualIn` if positive.

Use **executed** unspecified from `afterSwap` `BalanceDelta`, not `amountSpecified`.

**Do not:**

- Clone OZ `AntiSandwichHook` / copy `Pool.State` / iterate ticks (`MemoryOOG`).
- Use `beforeSwapReturnDelta` to eat the swap.
- Use `donate()`.
- Honor `hookData`.
- Add oracles, VPIN, auctions, DualPool, FairFlow, Flashblocks, AI, `owner.rescue`.
- Say leftover recapture, LVR recapture, or “yesterday’s LPs get today’s 0.30%.”
- Tax every swap with 5 bps (that is the old product).

---

## 3. Variants (implement A; B/C only if A’s spike fails)

### Variant A — canonical (do this)

Snapshot `(sqrtPriceX96, liquidity, tick)` at first `_beforeSwap` of the block. Quote later swaps with **one** `SwapMath.computeSwapStep` from `openSqrt` using `openLiquidity`, target = open tick’s next boundary (`TickMath.getSqrtPriceAtTick(openTick ± tickSpacing)` depending on direction).

### Variant B — if computeSwapStep direction/fee args are a mess

Same snapshot. Quote using `SqrtPriceMath.getAmount0Delta` / `getAmount1Delta` between `openSqrt` and the price after a **same-tick** step only. Same skip-if-this-swap-crossed.

### Variant C — last resort (weaker; document in plan)

No SwapMath. Surplus = improvement vs the **first swap of this block’s realized unspecified per unit specified**, same direction only. If you land here, write why A/B failed into the plan. Do not pretend this is ToB spot.

**Spike (≤2 hours) before writing production ToB:** read `SwapMath.computeSwapStep` and one v4-core test that calls it. Write a 15-line comment in `HardcapHook.sol` or a note under the plan’s v1+ section: which args, fee pips (`3000` = 0.30% unless you pass 0 — **decide and test**; recommend **include the pool’s LP fee** so the quote is comparable to the real swap). If you omit the fee, you will claw phantom surplus.

---

## 4. Gotchas already burned (do not rediscover)

1. **Position owner = unlock caller.** Hook `msg.sender` is PoolManager. Tests: `HardcapLP` must `claim`. EOA claim = `NoShares`.
2. **`afterSwap` return delta is unspecified-only.** Copy `FeeTakingHook` / OZ `BaseHookFee`.
3. **`amountSpecified` lies** on partial fills. Use `BalanceDelta`.
4. **`donate()`** pays current in-range LPs; OZ natspec admits a second account at an empty tick. Banned.
5. **One hook per `PoolKey`.** Inheritance only.
6. **Salt** is part of the position key.
7. **Top-up** refreshes `lastAddBlock`. Honest LPs wait `OFFSET`.
8. **Shares:** pending until OFFSET; claim weight includes pending; remove burns matured **then** pending; claim capped to live L.
9. **Lazy `_sync` is per-key.** Matured-only denom = first claimer takes 100%. Do not revert that.
10. **Template `.gitignore` used to ignore `docs/`.** Keep docs committable.
11. **Unichain sandwich** is not a pitch (Gogol 2026).
12. **Native ETH / FoT / rebase / ERC-777** out of scope.
13. **`final` on functions is not valid Solidity 0.8.** `HardcapHookFinal` is a named deploy target; `_creditVault` is the non-virtual rail.
14. **PoolModifyLiquidityTest / routers own positions.** Do not assume EOA.

---

## 5. Mindset (paste into every sub-agent)

Brutally honest. You are not here to validate the owner or yourself. A false PASS is worse than FAIL. Over-fitting / green-number-chasing is the #1 sin. If ToB-spot is weaker than claimed, say so in the plan — do not invent surplus.

Panel (consult on every delivered sub-task): Lead Exploit, Taint, Edge Case, Economic Incentives, Devil’s Advocate, State Transition, Symbolic, Skeptic Web3, vuln triager, bounty triager, Asymmetry attacker, Economic Security, Execution Trace, First Principles, Periphery.

PDCA: spike SwapMath **before** wiring vault. Existing kill tests stay green **before** you add ToB tests. Then ToB tests. If a ToB kill test is red at the end: **stop and say FAIL.**

---

## 6. Week definition of done

| Suite | Must happen |
|---|---|
| Cork | Direct callback reverts. Nonempty `hookData` reverts. Wrong `PoolKey` reverts. |
| Cap | `take <= notional * MAX_TAKE_BPS / 1e4`. Over-credit reverts. Large surplus **clamped**, user swap succeeds. |
| JIT | Same-block add→swap→remove: remove reverts. JIT cannot claim. Salt. Top-up refreshes lock. |
| Vault | No owner drain. Aged claim only. Burn on full exit. Two aged lockers split. No `donate()`. |
| **ToB-spot** | First swap take 0. Same-dir does **not** claw (open is better). Opposite-dir in-tick backrun claws. Size-matched sandwich take 0. Tick-cross take 0. L change since open → take 0. Both dirs. Clamp. |

Also keep: `test_oneBlockLpStillEarnsNativeFee` (0.30% still to JIT). That is honesty, not a bug.

**Must-not-lie in README (three sentences):**

1. Tick-crossing sandwiches are **not** clawed.
2. Native 0.30% still goes to whoever is in range.
3. This is not LVR recapture, not a leftover auction, not FairFlow.

Pitch: “First swap of the block is vanilla. Same-block in-range fills better than the open are clawed to aged LPs, at most `MAX_TAKE_BPS`. Cork cannot call us. We do not walk ticks.”

---

## 7. Suggested files

```
src/HardcapHook.sol              # add open-snapshot + ToB surplus; keep envelope
src/libraries/HardcapMath.sol    # add quote/surplus helpers if pure
src/HardcapHookFinal.sol         # still the deploy target; extraFeeBps=0
test/Hardcap.t.sol               # keep + ToB tests
test/HardcapToB.t.sol            # optional split
test/HardcapInvariant.t.sol      # keep vault invariants; first-swap-of-block take=0 if you can
script/DeployHardcap.s.sol       # extra=0
README.md                        # rewrite surplus section; keep No partner integrations
docs/…Implementation Plan.md     # already pivoted; append spike answers only
docs/SPIKE-sender-and-afterSwapReturnDelta.md
docs/NEXT_IMPLEMENTER.md         # this file
```

---

## 8. UHI10 Gate 1 (do not fail)

- Public repo, new code, tests (you have tests).
- README: `No partner integrations` unless the code **calls** one.
- Video ≤5 min, **human voice**, later — not this session unless asked.
- Deadline: 3 Sep 2026 23:59 PST. Demo Day 11 Sep 2026.
- Weights: 30% original / 25% execution / 20% impact / 15% function / 10% pitch.

Competitors already loud: **MRLV** (4 signals + fee to 3%), LVR Dutch auctions. Do not become them.

---

## 9. First commands

```bash
cd /Users/mishoko/projects/UHI10
forge test --match-contract Hardcap --no-match-contract HardcapInvariant
```

1. Confirm current suite green.
2. Spike `SwapMath.computeSwapStep` (fee pips, direction, boundary).
3. Write ToB test names (empty) first.
4. Implement until ToB + old kills are green.
5. `forge fmt`. Update README + plan spike note.

If ToB is still red: **stop and say so.** Do not narrate a PASS.
