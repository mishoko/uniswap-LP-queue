# Spike: `sender` identity and `afterSwapReturnDelta` signs

**Date:** 2026-08-18  
**Repo sources:** `lib/uniswap-hooks/lib/v4-core` (PoolManager `d153b048`), OZ `uniswap-hooks` v1.2.0  
**Rule:** do not rediscover. Product scope stays in the Implementation Plan. This file is the spike record only.

---

## 1. Who is `sender` on add / remove?

`PoolManager.modifyLiquidity` (this repo):

```solidity
(principalDelta, feesAccrued) = pool.modifyLiquidity(
    Pool.ModifyLiquidityParams({
        owner: msg.sender,          // unlock caller
        tickLower: params.tickLower,
        tickUpper: params.tickUpper,
        liquidityDelta: params.liquidityDelta.toInt128(),
        tickSpacing: key.tickSpacing,
        salt: params.salt
    })
);
```

`Hooks.beforeModifyLiquidity` / `afterModifyLiquidity` encode:

```solidity
IHooks.beforeAddLiquidity(msg.sender, key, params, hookData)
IHooks.beforeRemoveLiquidity(msg.sender, key, params, hookData)
```

That `msg.sender` is whoever called `unlock` — typically `PoolModifyLiquidityTest`, a router, or `PositionManager`. It is **not** the EOA unless the EOA unlocked. It is **not** the hook.

On the hook, Solidity `msg.sender` is always `PoolManager` (`BaseHook.onlyPoolManager`).

**Hardcap rule:**

```
positionKey = Position.calculatePositionKey(sender, tickLower, tickUpper, salt)
```

`sender` = callback argument. `claim()` must be called by that same address. v1 is not PositionManager-compatible unless the locker itself calls `claim`.

`PoolModifyLiquidityTest.unlockCallback` confirms the position is keyed to `address(this)` (the locker), while `data.sender` is only the token payer.

---

## 2. How is `afterSwapReturnDelta` signed?

`Hooks.afterSwap` adds the hook’s `int128` to **unspecified** only:

```solidity
hookDeltaUnspecified += self.callHookWithReturnDelta(
    abi.encodeCall(IHooks.afterSwap, (msg.sender, key, params, swapDelta, hookData)),
    self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)
).toInt128();

hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
    ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
    : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);

swapDelta = swapDelta - hookDelta;
```

You cannot take the specified currency from `afterSwapReturnDelta`. Specified take requires `beforeSwapReturnDelta`, which Hardcap must not use to eat the swap (NoOp / custom curve / Bunni-class).

OZ `BaseHookFee` / `BaseDynamicAfterFee` and v4-core `FeeTakingHook` all take the **unspecified** currency:

| Swap | Unspecified | Hook take |
|---|---|---|
| exact-in (`amountSpecified < 0`) | output | output tax |
| exact-out (`amountSpecified > 0`) | input | extra input |

Pattern (FeeTakingHook / BaseHookFee):

1. `unspecified.take(poolManager, address(this), feeAmount, …)` — hook debt
2. `return (afterSwap.selector, feeAmount.toInt128())` — hook credit

Signs are not invented. Hardcap copies this and takes ERC-20 (`claims = false`) so the vault is hook-held tokens, not ERC-6909.

---

## 3. What is `notional`?

Must be the **same currency as the take**.

```
notional = abs(unspecified BalanceDelta)
```

Not `amountSpecified` (request, not fill). Not “input notional charged as output” (USDC-notional taken as WETH).

The plan originally said “input.” The API wins. Cap applies in the unspecified currency.

---

## 4. What we did **not** copy

OZ `LiquidityPenaltyHook`: position key + `lastAddedLiquidityBlock` only.  
**Do not copy `poolManager.donate()`.** OZ natspec admits a second account at an empty tick can catch the donate on a thin pool.

---

## 5. Implication for tests

Do not use `PositionManager` as the Hardcap claim actor. Use a locker the test controls (`test/utils/HardcapLP.sol`) that both `modifyLiquidity` and `claim`. An EOA `claim` of a locker-owned position must revert `NoShares`.
