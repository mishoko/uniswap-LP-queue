# Hardcap demo video script (≤5 minutes)

**Rules:** human voice only. No AI voice (UHI10 score hit + Demo Day block). Kill-test replay first. Comparison second. Do not say leftover recapture, LVR recapture, or “yesterday’s LPs get today’s 0.30%.”

**On-screen command (keep a terminal full-screen for the first half):**

```bash
forge test --match-contract Hardcap -vv
```

---

## 0:00–0:20 — One sentence

Hardcap is a Uniswap v4 hook you attach like any v4-template hook. Worst-case hook extraction is `MAX_TAKE_BPS` and the payee is LPs. Native 0.30% still goes to whoever is in range. We do not redirect that.

## 0:20–2:20 — Kill tests (this is the demo)

Replay, do not narrate theory.

1. **Cork (0:20–1:00)**  
   Show `test_revert_directCallback`, `test_revert_nonEmptyHookData`, `test_revert_wrongPoolKey` passing.  
   Say: Cork lost ~$11–12M because callbacks were callable and `hookData` was trusted. Hardcap only talks to PoolManager, rejects nonempty `hookData`, and binds one `PoolKey`.

2. **Cap (1:00–1:35)**  
   Show `test_take_clampedToMaxBps` and `test_revert_bugPathOverTake`.  
   Say: large leftover is clamped; the user swap still succeeds. A branch that would credit more than the cap reverts the unlock.

3. **JIT (1:35–2:00)**  
   Show `test_revert_sameBlockAddRemove` and `test_jitCannotClaimVault`.  
   Say: same-block add → remove reverts. That position cannot claim. Key includes `salt`. We do **not** steal the native 0.30% from a one-block LP.

4. **Vault (2:00–2:20)**  
   Show `test_ownerCannotDrainVault`, `test_fullRemoveBurnsSharesCannotClaim`, `test_twoAgedLockersSplitVault`.  
   Say: no owner rescue. Full exit burns shares. Two aged lockers split. No `donate()`.

## 2:20–3:10 — Comparison number

Show `test_vanillaVsHardcap_sameSwaps_vaultAccruesExtra`.  
One sentence: same swaps, Hardcap vault grows by `EXTRA_FEE_BPS` of unspecified notional. That is a printed tax with a rail, not an APR and not MEV recapture.

## 3:10–4:10 — How you attach it

Mode A: mine flags, deploy `HardcapHook`, `initialize` the pool with that hook.  
Mode B: inherit `HardcapHook`, call `super`, never widen take, never add `owner.withdraw`.  
v4 allows one hook address per pool. You cannot attach Hardcap beside DualPool.

## 4:10–4:50 — Honest limits (say these out loud)

- Five basis points on every swap is a tax.
- `OFFSET` is one block, not a lockup.
- `claim` is the locker, not the EOA behind a router.
- Share unit is liquidity L, not token notional.

## 4:50–5:00 — Close

Public repo. No partner integrations. Tests are the product.

---

Do **not** record until this script is read aloud once and stays under 5:00. Cut theory, not tests.
