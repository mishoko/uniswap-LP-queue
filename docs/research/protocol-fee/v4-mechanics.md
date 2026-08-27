# Uniswap v4 Protocol Fee — Ground Truth from Vendored Source

**Scope.** Every claim below is read from the source vendored in this repo, or produced by a
throwaway Foundry probe run against that exact source (probe deleted after the run; tree left clean).
Nothing here is recalled from memory of Uniswap v4. Where I could not verify something from code,
it is marked **UNVERIFIED**.

**Sources under test**
- `lib/uniswap-hooks/lib/v4-core/` @ `d153b048868a60c2403a3ef5b2301bb247884d46` (`git describe` = `v4.0.0-19-gd153b048`), `package.json` version `1.0.2`
- `lib/uniswap-hooks/` @ `01a87ba5e69a3f75d0157cbf8ea49971ad83599a` (`v1.1.1-13-g01a87ba`)

All `file:line` references below are relative to `lib/uniswap-hooks/lib/v4-core/`.

---

## 1. Where the protocol fee is applied in the swap math

### Call chain

| Step | Location |
|---|---|
| `PoolManager.swap(key, params, hookData)` | `src/PoolManager.sol:187` |
| `key.hooks.beforeSwap(...)` → returns `amountToSwap`, `beforeSwapDelta`, `lpFeeOverride` | `src/PoolManager.sol:202` |
| `PoolManager._swap(pool, id, Pool.SwapParams{...}, inputCurrency)` | `src/PoolManager.sol:206-217`, body at `src/PoolManager.sol:230` |
| `pool.swap(params)` → returns `(delta, amountToProtocol, swapFee, result)` | `src/PoolManager.sol:234-235`; `src/libraries/Pool.sol:279` |
| protocol fee credited | `src/PoolManager.sol:238` — `if (amountToProtocol > 0) _updateProtocolFees(inputCurrency, amountToProtocol);` |
| accrual storage write | `src/ProtocolFees.sol:66-70` — `protocolFeesAccrued[currency] += amount` (unchecked) |

Note `src/PoolManager.sol:216`: the currency passed is `params.zeroForOne ? key.currency0 : key.currency1` — **the protocol fee is always taken in the INPUT currency**. Confirmed by the comment at `src/PoolManager.sol:237` ("the fee is on the input currency").

### The fee composition formula

`src/libraries/Pool.sol:286-287` reads the direction's protocol fee out of `slot0` **once, at the top of the swap**:

```solidity
uint256 protocolFee =
    zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : slot0Start.protocolFee().getOneForZeroFee();
```

`src/libraries/Pool.sol:302-308` composes it with the LP fee (which may be a hook override):

```solidity
uint24 lpFee = params.lpFeeOverride.isOverride()
    ? params.lpFeeOverride.removeOverrideFlagAndValidate()
    : slot0Start.lpFee();

swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
```

`src/libraries/ProtocolFeeLibrary.sol:34-46`:

```solidity
// The protocol fee is taken from the input amount first and then the LP fee is taken from the remaining
// The swap fee is capped at 100%
// Equivalent to protocolFee + lpFee(1_000_000 - protocolFee) / 1_000_000 (rounded up)
function calculateSwapFee(uint16 self, uint24 lpFee) internal pure returns (uint24 swapFee) {
    // protocolFee + lpFee - (protocolFee * lpFee / 1_000_000)
    ...
    swapFee := sub(add(self, lpFee), div(numerator, PIPS_DENOMINATOR))
}
```

**Exact arithmetic** (all quantities in pips; `PIPS_DENOMINATOR = 1_000_000`, `ProtocolFeeLibrary.sol:15`):

```
swapFee = pf + lp - floor(pf * lp / 1e6)
```

`div` rounds down, and it is subtracted, so `swapFee` rounds **up** (matching the natspec).

Equivalently, exactly (ignoring integer truncation):

```
1 - swapFee/1e6  ==  (1 - pf/1e6) * (1 - lp/1e6)
```

i.e. **the protocol fee is taken off the input FIRST, then the LP fee applies to the remainder.** The
protocol fee is *not* a cut of the LP fee — it is a separate layer stacked in front of it.

### Where the split actually happens

`src/libraries/SwapMath.computeSwapStep` (`src/libraries/SwapMath.sol:51`) is called with the **composed** `swapFee`
(`src/libraries/Pool.sol:362-368`) and returns `(sqrtPriceNextX96, amountIn, amountOut, feeAmount)` where
`feeAmount` is the **whole** composed fee. The swapper's delta is accumulated *before* the split, at
`src/libraries/Pool.sol:370-382` (`amountCalculated -= (step.amountIn + step.feeAmount)` / `amountSpecifiedRemaining += (step.amountIn + step.feeAmount)`).

Only afterwards, at `src/libraries/Pool.sol:384-398`, is the fee split:

```solidity
if (protocolFee > 0) {
    unchecked {
        uint256 delta = (swapFee == protocolFee)
            ? step.feeAmount                                                       // lpFee == 0: protocol takes all
            : (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
        step.feeAmount -= delta;
        amountToProtocol += delta;
    }
}
```

and the **residual** `step.feeAmount` is what feeds LP fee growth at `src/libraries/Pool.sol:400-407`:

```solidity
if (result.liquidity > 0) {
    step.feeGrowthGlobalX128 += UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
}
```

flushed to storage at `src/libraries/Pool.sol:444-449`.

So: **protocol take per step = `pf/1e6` of the step's GROSS input (`amountIn + feeAmount`, i.e. including the LP-fee portion)**, rounded down ("this rounds down to favor LPs over the protocol", `src/libraries/Pool.sol:390`).

Upstream's own fuzz test states the same invariant: `test/DynamicFees.t.sol:311`
`uint256 expectedProtocolFee = uint256(uint128(-delta.amount0())) * protocolFee0 / 1e6;`
— i.e. **protocol fee = protocolFee_pips × (total input the swapper paid)**. This test passes on the vendored
copy (1000 fuzz runs, run 2026-08-26, `forge test --match-path test/DynamicFees.t.sol` → 16/16 PASS).

---

## 2. Effect on swapper delta vs. LP fee growth vs. protocolFeesAccrued

**Both** the swapper and the LP are affected, but **asymmetrically, and it depends on exact-in vs exact-out.**

### Derivation (single step, exact arithmetic ignoring rounding)

Let `G = amountIn + feeAmount` (gross input for the step), `pf`, `lp` in pips, `f = swapFee`.

- protocol take: `P = G·pf/1e6`
- LP take: `L = G·f/1e6 − G·pf/1e6 = G·lp/1e6 · (1 − pf/1e6)`
- curve input: `A = G·(1 − f/1e6) = G·(1 − pf/1e6)(1 − lp/1e6)`

**Exact input** (`amountSpecified < 0`): `G` is pinned to the swapper's specified input `X`
(`SwapMath.sol:63-83`: `amountRemainingLessFee = X·(1e6−f)/1e6`, `feeAmount = X − amountIn`).
Therefore:
- (a) swapper's delta: **input leg invariant** (`−X`), **output leg falls** — the curve only sees `A`, which shrinks by the factor `(1 − pf/1e6)`.
- (b) LP fee growth: **falls by exactly the relative factor `pf/1e6`** (`L = X·lp/1e6·(1−pf/1e6)`).
- (c) `protocolFeesAccrued`: **rises by `X·pf/1e6`**.

**Exact output** (`amountSpecified > 0`): `amountOut` is pinned, so the curve input `A` is pinned
(`SwapMath.sol:87-104`: `amountIn` derived from the price move, `feeAmount = ceil(amountIn·f/(1e6−f))`).
Therefore `G = A·1e6/(1e6−f)` grows, and:
- LP take `= A·f/(1e6−f) − A·pf/(1e6−f) = A·(f−pf)/(1e6−f)`. Substituting `f = pf+lp−pf·lp/1e6`:
  `f − pf = lp(1e6−pf)/1e6` and `1e6−f = (1e6−pf)(1e6−lp)/1e6`, so **LP take `= A·lp/(1e6−lp)` — completely independent of `pf`.**
- (a) swapper's delta: **output leg invariant**, **input leg grows** by exactly the protocol take.
- (b) LP fee growth: **EXACTLY INVARIANT.**
- (c) `protocolFeesAccrued`: rises by `G·pf/1e6`.

### Empirical confirmation (throwaway Foundry probe, since deleted)

Two identical pools (`lpFee = 3000` = 0.30%, liquidity `1e18` over ticks `[-120, 120]`, price 1:1),
one with `protocolFee = 0`, one with `protocolFee = 1000` (zeroForOne), `zeroForOne` swap:

**Exact input, `X = 1e15`:**

| quantity | pf = 0 | pf = 1000 | delta |
|---|---|---|---|
| `amount0` (swapper pays) | −1_000_000_000_000_000 | −1_000_000_000_000_000 | **invariant** |
| `amount1` (swapper gets) | 996_006_981_039_903 | 995_011_965_097_726 | −995_015_942_177 (**−999 ppm**) |
| `feeGrowthGlobal0X128` | 1020847100762815390390123822295304 | 1019826253662052574999733698473009 | **−999 ppm (relative)** |
| `protocolFeesAccrued(c0)` | 0 | 1_000_000_000_000 | **+1000 ppm of input** |

**Exact output, `amountOut = 1e15`:**

| quantity | pf = 0 | pf = 1000 | delta |
|---|---|---|---|
| `amount0` (swapper pays) | −1_004_013_040_121_367 | −1_005_018_058_179_546 | **+1_005_018_058_179 more input** |
| `amount1` (swapper gets) | 1_000_000_000_000_000 | 1_000_000_000_000_000 | **invariant** |
| `feeGrowthGlobal0X128` | 1024943801136263662990517543963260 | 1024943801136263662990517543963260 | **BIT-IDENTICAL (0 ppm)** |
| `protocolFeesAccrued(c0)` | 0 | 1_005_018_058_179 | = the extra input, to the wei |

**Bottom line:** the protocol fee is overwhelmingly borne by the **swapper**, not the LP. At the
maximum setting the LP's fee revenue drops by 0.1% *relative* on exact-in swaps and by **zero** on
exact-out swaps. The LP does *not* lose 0.1% of volume.

---

## 3. Maximum protocol fee

`src/libraries/ProtocolFeeLibrary.sol:6-8`:

```solidity
/// @notice Max protocol fee is 0.1% (1000 pips)
/// @dev Increasing these values could lead to overflow in Pool.swap
uint16 public constant MAX_PROTOCOL_FEE = 1000;
```

- Units: **hundredths of a bip (pips)**, denominator `1_000_000` (`ProtocolFeeLibrary.sol:15`).
- **1000 pips = 0.1% OF THE SWAP INPUT** (the swapper's total input, including the LP-fee portion of it) —
  **NOT** of the LP fee. Established in §1/§2 above and by `test/DynamicFees.t.sol:311`.
- **Per-direction**: yes. Packed `uint24`, low 12 bits = zeroForOne, high 12 bits = oneForZero
  (`src/types/Slot0.sol:9,19-22`; `ProtocolFeeLibrary.sol:17-23`). Each direction is capped at 1000
  independently (`ProtocolFeeLibrary.sol:25-32`). Test constant confirming the packed maximum:
  `test/ProtocolFeesImplementation.t.sol:23` — `MAX_PROTOCOL_FEE_BOTH_TOKENS = (1000 << 12) | 1000`.

**The sharp consequence:** 0.1% of input is an **absolute** cap, not a fraction of the LP fee.
Relative to the pool's own LP fee it is:

| pool LP fee | max protocol fee as % of LP fee revenue |
|---|---|
| 1.00% (10000 pips) | 10% |
| 0.30% (3000 pips)  | 33% |
| 0.05% (500 pips)   | **200%** |
| 0.01% (100 pips)   | **1000%** |
| 0 (dynamic-fee hook returning 0) | protocol takes the *entire* fee (`Pool.sol:391-392`) |

A low-fee or zero-LP-fee pool can have a protocol fee that dwarfs its own LP fee — the swapper's
all-in cost rises to `pf + lp − pf·lp/1e6` pips.

---

## 4. Who can set it; can it be forced on our pool; can a hook block it

**Setter** — `src/ProtocolFees.sol:35-41`:

```solidity
function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external {
    if (msg.sender != protocolFeeController) InvalidCaller.selector.revertWith();
    if (!newProtocolFee.isValidProtocolFee()) ProtocolFeeTooLarge.selector.revertWith(newProtocolFee);
    PoolId id = key.toId();
    _getPool(id).setProtocolFee(newProtocolFee);
    emit ProtocolFeeUpdated(id, newProtocolFee);
}
```

- **Only `protocolFeeController`.** The only other check is the ≤1000-per-direction validity check.
- The controller is set by the PoolManager **owner**: `src/ProtocolFees.sol:29-32`
  `setProtocolFeeController(address) external onlyOwner`; `Owned` is solmate's single-owner mixin
  (`lib/solmate/src/auth/Owned.sol:19-23`), owner injected in `PoolManager`'s constructor
  (`src/PoolManager.sol:101` — `constructor(address initialOwner) ProtocolFees(initialOwner) {}`).
  On mainnet that owner is Uniswap governance (**UNVERIFIED from this repo** — no deployment address is
  pinned in the vendored source).
- `Pool.setProtocolFee` (`src/libraries/Pool.sol:109-112`) does exactly one thing besides the write:
  `self.checkPoolInitialized()`. **There is no per-pool opt-out, no hook consent, no allowlist.**

**Can a hook refuse or block it? NO.**
- **No hook callback exists for protocol-fee changes.** The complete hook permission set is 14 flags,
  `src/libraries/Hooks.sol:27-47`: before/after Initialize, AddLiquidity, RemoveLiquidity, Swap, Donate,
  plus 4 `*_RETURNS_DELTA` flags. **None** relates to protocol fees. `setProtocolFee` calls no hook.
- The only revert path is "pool not initialized". Once our pool exists, the controller can flip the
  protocol fee to 1000/1000 **unilaterally, without our consent, without notice, and with no callback
  we could observe or veto in the same transaction.** The only signal is the `ProtocolFeeUpdated` event
  (`src/interfaces/IProtocolFees.sol:23`).
- A dynamic-fee hook returning an `lpFeeOverride` in `beforeSwap` **cannot escape** it: the override is
  composed with the protocol fee at `src/libraries/Pool.sol:303-307`.

**No lock guard (code-verified anomaly).** `_isUnlocked()` is declared at `src/ProtocolFees.sol:60` and
implemented at `src/PoolManager.sol:392` (`return Lock.isUnlocked()`), but **`grep -rn "_isUnlocked" src/`
shows it is never called by any function in `ProtocolFees.sol`.** Consequences in this vendored copy:
- `setProtocolFee` can be called while the manager is unlocked (i.e. re-entered mid-transaction from a
  controller contract), changing the fee between two swaps in one tx.
- `collectProtocolFees` natspec at `src/interfaces/IProtocolFees.sol:40` says *"This will revert if the
  contract is unlocked"* — **the implementation contains no such check** (`src/ProtocolFees.sol:44-57`);
  the only guard is the synced-currency check at `:49-52`. This is a doc/code mismatch in the vendored copy.
  Whether upstream `v4-core` differs is **UNVERIFIED** — this is what is in *our* `lib/`.

Both require a malicious/compromised `protocolFeeController`, so this is a trust-assumption note, not an
exploit against us as written.

---

## 5. Can a hook read the current protocol fee on-chain at swap time?

**Yes — one `extsload` of one word.** `src/libraries/StateLibrary.sol:40-63`:

```solidity
function getSlot0(IPoolManager manager, PoolId poolId)
    internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
{
    bytes32 stateSlot = _getPoolStateSlot(poolId);
    bytes32 data = manager.extsload(stateSlot);
    ...
    protocolFee := and(shr(184, data), 0xFFFFFF)
```

Snippet a hook would write:

```solidity
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
// ...
using StateLibrary for IPoolManager;
using ProtocolFeeLibrary for uint24;

(, , uint24 packedProtocolFee, uint24 lpFee) = poolManager.getSlot0(key.toId());
uint16 pfThisDirection = params.zeroForOne
    ? packedProtocolFee.getZeroForOneFee()   // low 12 bits
    : packedProtocolFee.getOneForZeroFee();  // high 12 bits
```

**Cost:** one `STATICCALL` into `Extsload.extsload(bytes32)` + one `SLOAD`. Not free but cheap —
~2100 gas cold / ~100 warm for the SLOAD plus call overhead. (Exact figure **UNMEASURED**; the point
that it is a *single* storage word is code-verified.)

**Timing is correct for a hook:** `PoolManager.swap` calls `hooks.beforeSwap` at `src/PoolManager.sol:202`
**before** `Pool.swap` reads `slot0Start` at `src/libraries/Pool.sol:283`. So the value a hook reads in
`beforeSwap` is exactly the value the swap will use.

`slot0` is also the same word carrying `sqrtPriceX96`, `tick` and `lpFee` — a hook already reading price
gets the protocol fee for free in the same word.

---

## 6. Is the protocol fee nonzero by default on a new pool?

**No. Always exactly zero at initialization.**

`src/PoolManager.sol:117-142` (`initialize`) never touches the protocol fee; it computes only
`uint24 lpFee = key.fee.getInitialLPFee()` (`:128`) and calls `_pools[id].initialize(sqrtPriceX96, lpFee)` (`:134`).

`src/libraries/Pool.sol:100-107`:

```solidity
// the initial protocolFee is 0 so doesn't need to be set
self.slot0 = Slot0.wrap(bytes32(0)).setSqrtPriceX96(sqrtPriceX96).setTick(tick).setLpFee(lpFee);
```

The slot is built from `bytes32(0)`, so the 24 protocol-fee bits are zero. Corroborating test:
`test/PoolManager.t.sol:786-787` — on a freshly initialized pool, `getSlot0(...)` is asserted to return
`slot0ProtocolFee == 0` *before* any `setProtocolFee` call.

**It only becomes nonzero via `setProtocolFee` by the controller** (§4).

---

## 7. Exact-output vs exact-input

Same code path, same accrual site (`src/libraries/Pool.sol:384-398` runs for both), but three real differences:

1. **Who pays.** Exact-in: the swapper's output shrinks and LP fee growth shrinks by `pf/1e6` relative.
   Exact-out: the swapper's *input* grows by the protocol take and **LP fee growth is bit-identical**
   (proved algebraically and measured, §2). Branch: `src/libraries/SwapMath.sol:63` (`exactIn = amountRemaining < 0`),
   fee derivation at `:72-82` (exact-in) vs `:104` (exact-out, `feeAmount = mulDivRoundingUp(amountIn, f, 1e6−f)`).

2. **A 100% swap fee reverts exact-out only.** `src/libraries/Pool.sol:310-316`:
   ```solidity
   if (swapFee >= SwapMath.MAX_SWAP_FEE) {
       if (params.amountSpecified > 0) InvalidFeeForExactOut.selector.revertWith();
   }
   ```
   Because the protocol fee is *added on top* of the LP fee, **turning the protocol fee on can push a
   high dynamic LP fee across the 100% line and break exact-output swaps that previously worked.**
   Upstream test proving exactly this: `test/DynamicFees.t.sol:231-242` — `lpFee = 999_999` plus
   `protocolFee = 1000` ⇒ `swapFee = 1_000_000` ⇒ `Pool.InvalidFeeForExactOut`. (Whereas the same
   `lpFee = 1_000_000` + `protocolFee = 1000` on an **exact-input** swap succeeds and the protocol takes
   `X·1000/1e6`: `test/DynamicFees.t.sol:245-265`.)

3. **Rounding.** Exact-out `feeAmount` rounds **up** (`SwapMath.sol:104`) while the protocol split rounds
   **down** (`Pool.sol:390`), so LPs get the dust. Exception at `Pool.sol:391-392`: when `lpFee == 0`,
   `swapFee == protocolFee` and the protocol takes `step.feeAmount` **whole** (including the rounded-up
   dust) — upstream's fuzz test explicitly compensates for this: `test/DynamicFees.t.sol:312-315`.

---

## 8. Things that would surprise a hook developer who is the pool's sole LP

1. **You are not the one being taxed — your swappers are.** The protocol fee stacks *in front of* your
   LP fee (`swapFee = pf + lp − pf·lp/1e6`), it does not carve out of it. At the 1000-pip max your fee
   revenue drops by 0.1% *relative* on exact-in and **0%** on exact-out. What actually changes is your
   pool's all-in price for takers: a 0.30% pool becomes a 0.3997% pool. If you compete on quoted price
   (aggregator routing, RFQ, arbitrage-driven flow), **the damage is volume loss, not fee loss.**

2. **Protocol fees are skimmed in real tokens out of the PoolManager.** `protocolFeesAccrued` is a
   *global per-currency* counter across all pools (`src/ProtocolFees.sol:21`) and
   `collectProtocolFees` does a real `currency.transfer(recipient, amountCollected)`
   (`src/ProtocolFees.sol:56`). **Any hook invariant of the form "PoolManager's balance of currency0
   equals what my accounting says the pool holds" will break** once a protocol fee is enabled — those
   tokens are counted for the controller, not for you, and can leave the contract at any time.

3. **A `beforeSwapReturnDelta` hook that swallows the whole swap pays ZERO protocol fee.**
   `Hooks.beforeSwap` mutates `amountToSwap += hookDeltaSpecified` (`src/libraries/Hooks.sol:273-279`);
   if the hook consumes the entire specified amount, `Pool.swap` short-circuits at
   `src/libraries/Pool.sol:320` (`if (params.amountSpecified == 0) return (ZERO_DELTA, 0, swapFee, result);`)
   and `amountToProtocol` is 0. Custom-accounting / full-range-custody hooks that route flow *around*
   the AMM curve are structurally outside the protocol fee. (`PoolManager.sol:193` only rejects a
   *user-specified* zero amount, not a post-hook zero.)

4. **`donate()` and `modifyLiquidity()` are untaxed.** `PoolManager.donate` (`src/PoolManager.sol:256-275`)
   calls `pool.donate` (`src/libraries/Pool.sol:466-480`, which only touches `feeGrowthGlobal*`) and never
   calls `_updateProtocolFees` — donated fees go 100% to LPs. Likewise, adding or removing liquidity
   accrues no protocol fee even with a nonzero protocol fee set (`test/PoolManager.t.sol:795-807`).
   **`swap` is the only accrual site** — `_updateProtocolFees` has exactly one call site in `src/`:
   `src/PoolManager.sol:238`.

5. **The protocol fee is read ONCE per swap**, at `src/libraries/Pool.sol:283-287`, from `slot0Start`
   — before any tick crossing. It is stable for the whole multi-tick swap.

6. **The `MAX_PROTOCOL_FEE = 1000` cap is a safety-against-overflow constant, not an economic promise**
   (`ProtocolFeeLibrary.sol:7`: "Increasing these values could lead to overflow in Pool.swap"). It is a
   compile-time constant of the deployed `PoolManager`, so it cannot be raised without a new deployment —
   that part *is* a hard guarantee for an already-deployed manager.

7. **`_updateProtocolFees` is `unchecked`** (`src/ProtocolFees.sol:67-69`). Not exploitable at realistic
   magnitudes; noted for completeness.

8. **No lock guard on the controller entry points** — see §4. A compromised/malicious controller can
   move the fee mid-transaction; there is no hook-visible notification.

---

## 9. Web-sourced (NOT code-sourced) — has governance actually enabled it?

⚠️ **Everything in this section is from web search, not from source, and is not independently verified.
Treat magnitudes and dates as approximate. Do not build economics on this section without checking
on-chain state directly.**

- Uniswap **Governance Proposal 100** reportedly **executed on 2026-07-27**, activating v4 protocol fees
  on **Ethereum, Arbitrum, Base, BNB Chain, Polygon, OP Mainnet, and Robinhood Chain**, with a follow-up
  covering Celo, World Chain, X Layer, Soneium, Zora. Vote reported as 46.6M UNI for / 1.27M against.
  So: **YES, the fee switch is live on v4 as of mid-2026 — this is no longer hypothetical.**
- Reported magnitude: **~1/6 of the swap fee, i.e. ~5 bps on a 30 bps pool.** In v4 units that is ~500
  pips of input — **half the 1000-pip protocol maximum**, and consistent with the code (§3).
- Mechanism: a `V4FeeAdapter` registered as `protocolFeeController`, with a `V4FeePolicy` classifying
  pools; permissionless `triggerFeeUpdate`/`collect` push fees to the PoolManager and route proceeds to
  a per-chain `TokenJar` (→ UNI buy-and-burn). Repo: `github.com/Uniswap/protocol-fees`.
- **Scope reportedly excludes generic hook pools for now:** the initial proposal is described as covering
  static-fee pools with no hooks, CCA pools, and aggregator-hook pools; the adapter targets "pools with no
  `*_RETURNS_DELTA` hook bits and static LP fee", with custom-accounting/dynamic-fee hooks handled through
  a governance-controlled classification waterfall (`pairClassFees` → `familyDefaults` → `defaultFee`) and
  a `setHookFamily` mechanism.
- **No opt-out for hook developers was found.** Classification is a governance-permissioned role. This is
  consistent with the code: there is no on-chain opt-out (§4).
- Uniswap leadership publicly argued LP rates are unchanged. **The code agrees with that framing** (§2):
  the fee composes on top of the LP fee rather than splitting it.

**Uncertainty flags:** exact per-pool fee values, whether a hook like ours would today be classified into
a nonzero family, and whether the current controller is the `V4FeeAdapter` on the chain we deploy to —
all **UNVERIFIED**. These are answerable on-chain (`poolManager.protocolFeeController()` and
`StateLibrary.getSlot0(poolId)`) and should be checked before relying on "our pool is at zero".

**Sources (web):**
- https://cryptobriefing.com/uniswap-fee-switch-v4-pools-325k-revenue/
- https://cryptobriefing.com/uniswap-governance-v4-protocol-fees/
- https://cryptobriefing.com/uniswap-v4-protocol-fees-proposal/
- https://www.cryptotimes.io/2026/07/29/uniswap-activates-v4-protocol-fees-as-adams-rebuts-lp-cut-claims/
- https://crypto.news/uniswap-v4-fees-leave-lp-rates-unchanged-adams-says/
- https://github.com/Uniswap/protocol-fees

---

## 10. Verdict

**At the maximum setting the protocol can divert exactly 0.1% (1000 pips) of the swapper's total input
amount, per direction, and it is charged ON TOP of the LP fee — so the sole-LP hook loses at most 0.1%
of its fee revenue *relatively* on exact-input swaps and 0% on exact-output swaps; the cost lands on the
swapper, whose all-in fee rises from `lp` to `pf + lp − pf·lp/1e6` pips (0.30% → 0.3997%).**

The real exposure for a hook that custodies all the liquidity is therefore **not** direct fee theft — it
is (a) **competitive: a 10 bps worse quote** you cannot veto, refuse, or observe via any callback, and
(b) **accounting: real tokens leave the PoolManager into `protocolFeesAccrued`**, which will break any
balance-equals-my-books invariant the hook holds.

### Reproduction

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd lib/uniswap-hooks/lib/v4-core
forge test --match-path test/DynamicFees.t.sol -vv   # 16/16 PASS, incl. test_fuzz_ProtocolAndLPFee (1000 runs)
```

The pf=0 vs pf=1000 comparison table in §2 came from a temporary probe test placed at
`test/_ZZProbeProtocolFee.t.sol`, run, and then deleted (`git status` in the submodule verified clean
afterwards). Re-create it from the numbers/params documented in §2 if you need to re-run it.
