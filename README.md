# Hardcap

Hardcap is a **pool hook you attach like any v4-template hook**, and a **base contract you inherit if you must add features**. It is not a second hook you compose at the PoolManager. Use it when the main risk you care about is unbounded hook extraction and callback trust, not when you need a different AMM.

Worst-case hook extraction is `MAX_TAKE_BPS` and the payee is LPs.

**No partner integrations.**

Plan: [`docs/Hardcap Fail-Closed MEV Cap Hook - Implementation Plan.md`](docs/Hardcap%20Fail-Closed%20MEV%20Cap%20Hook%20-%20Implementation%20Plan.md).  
Spike: [`docs/SPIKE-sender-and-afterSwapReturnDelta.md`](docs/SPIKE-sender-and-afterSwapReturnDelta.md).  
Video script: [`docs/VIDEO_SCRIPT.md`](docs/VIDEO_SCRIPT.md).

## What it does

A single Uniswap v4 hook on one pool:

- May take a hook-level amount on a swap, at most `MAX_TAKE_BPS` of unspecified notional. **Judging product (ToB-spot):** first swap of the block is vanilla. Later same-block in-range fills that beat a one-step `SwapMath.computeSwapStep` quote at the block-open `(sqrtPrice, liquidity)` are clawed to aged LPs, at most `MAX_TAKE_BPS`. Production `extraFeeBps = 0`.
- That take can only go to an in-hook LP vault with **no owner, rescue, sweep, or `donate()`**.
- Callbacks fail closed: only `PoolManager`, empty `hookData`, bound `PoolKey`.
- Same-block add → remove reverts. Vault `claim` requires the position to age `OFFSET` blocks.
- Positions are keyed by `Position.calculatePositionKey(owner, tickLower, tickUpper, salt)`. The owner is the PoolManager unlock caller, not the EOA behind a router.

v4 native 0.30% fees still go to whoever is in range. Hardcap does **not** redirect those. It only controls hook take.

## What it is not (must not lie)

1. Tick-crossing sandwiches are **not** clawed. If this swap's `slot0.tick` moved, take is 0. We do not walk the tick bitmap.
2. Native 0.30% still goes to whoever is in range during the swap, including a one-block JIT LP.
3. This is not LVR recapture, not a leftover auction, not FairFlow, not OZ AntiSandwich.

Same-direction second fills are worse than the open. They do not generate surplus. The claw is the opposite-direction backrun that stays inside one tick. Cork cannot call us.

## Defaults

| Constant | Value |
|---|---|
| `extraFeeBps` (production) | 0 (ToB-spot) |
| `MAX_TAKE_BPS` | 15 |
| `OFFSET` | 1 block |

`extraFeeBps <= MAX_TAKE_BPS` is enforced in the constructor. Envelope tests still deploy `extraFeeBps = 5` to keep the tax-path cap rail.

## How to use

**Mode A (this repo):** mine flags, deploy `HardcapHookFinal`, `initialize` a pool with that hook.

**Mode B:** `contract MyHook is HardcapHook`. Call `super` on callbacks. `_creditVault` is not virtual — do not add a second take path. Do not add `owner.withdraw`. Do not honor `hookData` unless you leave this threat model. Re-mine the address if permission bits change.

v4 allows **one hook address per pool**. You cannot attach Hardcap beside DualPool.

v1 assumes **direct LP → PoolManager** interaction. If a router is the unlock caller, that router owns the position and must call `claim`. Top-up (`increaseLiquidity`) refreshes `lastAddBlock` and increases vault shares; honest LPs who add more wait `OFFSET`. Claim is **single-shot** per position key: after claiming, add again to earn a share of later surplus.

v1 tokens: standard ERC-20 only. No native ETH, fee-on-transfer, rebasing, or ERC-777.

Claim **receipt** requires `OFFSET`. Claim **weight** is recorded rights + still-pending L. After a claim, remaining in-range L is **not** in the next weight until that key adds again (single-shot). Unaged L dilutes the split but cannot be paid. Two aged lockers split even if only one has been touched. Remove burns matured then pending. Full exit forfeits unclaimed surplus (claim first). `OFFSET` is 1 block; that is not time-weighted.

## Flows

**Normal swap (production, extraFeeBps = 0)**

```text
Alice -> PoolManager -> Hardcap.beforeSwap (snapshot open if new block)
                     -> CL math (native 0.30% still to in-range LPs)
                     -> Hardcap.afterSwap + afterSwapReturnDelta
                          first swap of block          -> take = 0
                          this swap crossed a tick     -> take = 0
                          liquidity != openLiquidity   -> take = 0
                          else take = min(open-quote surplus, cap)
                          vaultAccrued += take
```

**Cork-style callback**

```text
Attacker -> Hardcap.beforeSwap(...)     => NotPoolManager
Attacker -> PoolManager.swap(hookData!=0) => HookDataNotAllowed
Attacker -> other PoolKey + this hook   => InvalidPoolKey
```

**JIT add → swap → remove**

```text
Bob add  => lastAddBlock[key]=N, pendingShares += L
swap     => vault may grow
Bob remove same block => RemoveTooSoon
Bob claim same block  => PositionNotAged
```

**Vault (after the review fix)**

```text
add     => pending until OFFSET; not in claim denom
remove  => burn min(removed, aged shares); full exit => cannot claim
claim   => locker only, aged only, single-shot
donate  => never called
```

## Tests

```bash
forge test --match-contract Hardcap -vv
```

Kill suites: Cork (direct callback / `hookData` / wrong `PoolKey`), cap (clamp + bug-path revert + fuzz), JIT (same-block remove + salt + top-up), vault (no owner drain, aged claim only, burn-on-remove, no unaged dilution), ToB-spot (first-of-block 0, same-dir no claw, opposite-dir in-range claw, tick-cross 0, L-changed 0, both dirs, clamp).

## SDSF self-score (honest, 2026-08-18)

Uniswap v4 Self-Directed Security Framework. UF does not certify this. Higher = more risk.

| Dimension | Score | Why |
|---|---|---|
| Complexity | 2 / 5 | Five callbacks, pending/aged shares, no modes or oracles |
| Custom math | 2 / 5 | Cap `mulDiv` plus one `SwapMath.computeSwapStep` at open. No tick walk |
| External dependencies | 0 / 3 | `PoolManager` only |
| External liquidity exposure | 1 / 3 | Hook holds vault ERC-20 until `claim` |
| TVL potential | 1 / 5 | Hackathon / curator pool, not a farm |
| Team maturity | 3 / 3 | No prior production hook |
| Upgradeability | 0 / 3 | Immutable. New behavior = new deploy |
| Autonomous parameter updates | 0 / 3 | Constants fixed in constructor |
| Price impacting behavior | 2 / 3 | `afterSwapReturnDelta` extra fee |

**Tier:** medium (sum 11 / 33).

**Feature triggers that still fire:**

- **Price impacting** — hook take. Cap + fuzz + bug-path revert are the mitigation. Treat `afterSwapReturnDelta` as the dangerous bit.
- **Hook holds tokens** — vault ERC-20 on the hook. Accounting is `vaultAccrued`, not `balanceOf`. No owner drain.

**Triggers that do not fire:** custom curve / NoOp, oracle, autonomy, proxy, TVL-5.

**Not done and not claimed:** formal verification, second audit, on-chain monitor, bug bounty. Acceptable at this TVL if documented. Re-score if anyone actually LPs size.

## SDSF posture (short)

Immutable, no proxy, no oracle, no `hookData`, no `beforeSwapReturnDelta`, no `donate()`. Price-impact trigger applies because `afterSwapReturnDelta` takes a hook fee. Feature trigger “hook holds tokens” applies: vault ERC-20 sits on the hook and is paid only via `claim`.

## License

MIT
