# Assay — Ground Truth

Engineer-level audit of `src/assay/*` and `test/assay/*`, written against the code, not the README.
Every claim below was checked against source or a test run. Where the README and the code disagree,
the code wins and the disagreement is called out.

- **Tree state at audit:** `master` @ `5e99379`, working tree dirty (`README.md`, `docs/NEXT_SESSION_ASSAY.md`).
- **`forge build`:** clean (one pre-existing shadow warning, `AssayStack.sol:90` `subHooks` param vs getter).
- **`forge test --match-path "test/assay/*"`:** **17 suites, 81 tests, 81 passed, 0 failed** (77 `test_*` + 4 `invariant_*`). `docs/NEXT_SESSION_ASSAY.md` claims 160 for the *whole* repo; the assay subset is 81.
- **Not in that 81:** `test/spike/PredicateSandbox.t.sol` (13 tests) — the sandbox kill-suite the README cites lives outside `test/assay/*` **and does not import `src/`**. See A-8.
- Proof-of-concept exploits were written and run during this audit: A-1 (stack brick) and A-4 (registry returndata bomb) as Foundry tests, A-3, A-6 and A-7 empirically. The temp files were deleted; PoC source is inline below so they can be re-added. `forge test` is green and the tree is unchanged.

---

## 1. Mechanics, per contract

### 1.1 `IHookPredicate.sol` — the interface everything hangs off

```solidity
enum Verdict { HOLDS, VIOLATED, INCONCLUSIVE }

interface IHookPredicate {
    function check(address hook) external view returns (bool);
    function describe() external view returns (string memory);
}
```

`check(address)` selector is `0xc23697a8`, hardcoded in `PredicateSandbox` assembly and pinned by a
test. `describe()` is registry decoration only and is **never sandboxed** — see A-13.

### 1.2 `PredicateSandbox.sol` — library, no state, no trust

```solidity
function evaluate(address predicate, address hook) internal view returns (Verdict);           // STIPEND=200k, HEADROOM=120k
function evaluate(address predicate, address hook, uint256 stipend, uint256 headroom) internal view returns (Verdict);
```

Mechanism: `staticcall(stipend, predicate, <0xc23697a8 ++ hook>, 0x24, 0x00, 0x20)` — a **bounded
32-byte returndata copy in assembly**, so the callee cannot choose the caller's memory allocation.
Verdict mapping is total and fail-safe:

| Condition | Verdict |
|---|---|
| `predicate.code.length == 0` | INCONCLUSIVE |
| `gasleft() < stipend*64/63 + headroom` | **reverts** `InsufficientGas()` (answers nothing rather than wrong) |
| call failed (revert / OOG / attempted SSTORE under staticcall) | INCONCLUSIVE |
| `returndatasize() != 32` | INCONCLUSIVE |
| returned word `> 1` (dirty bool) | INCONCLUSIVE |
| word `== 1` | HOLDS |
| word `== 0` | VIOLATED |

This is the strongest single piece of the codebase by design. `staticcall` buys mutation-rejection
and reentrancy-blocking for free; making "cannot tell" un-fakeable as "guilty" is the correct
direction for a slashing primitive.

> **But it is the least-tested contract in `src/` (A-8).** `grep -rn "PredicateSandbox" test/`
> outside `test/spike/` returns nothing. The 13-test adversarial kill-suite in
> `test/spike/PredicateSandbox.t.sol` **does not import `src/`** — it re-declares its own `Verdict`,
> `IHookPredicate`, `PredicateSandbox` and `NoSwapDeltaPredicate` inside the test file, and tests
> *those*. The library was promoted to `src/` (gaining a parameterised
> `evaluate(predicate, hook, stipend, headroom)` overload the spike copy never had); the tests were
> not. So the shipped code's bomber / mutator / reenterer / dirty-bool / short-return / OOG /
> `InsufficientGas` paths have **zero direct coverage**, and are exercised only indirectly through
> `HookBond`/`AssayHook` against benign predicates. `PredicateSandbox.sol:45` claims the selector is
> *"pinned by `test_selector_matches_interface`"* — that test pins the **spike file's own local
> interface**, not `src/assay/IHookPredicate.sol`. The selectors happen to coincide, so the comment
> is accidentally true and its provenance claim is false.

Two callers use two different budgets:

| Caller | stipend | headroom | gas that must be retained |
|---|---|---|---|
| `HookBond` (adjudication) | 200,000 | 120,000 | ~323,175 |
| `AssayHook` (runtime + `verifySpec`) | 30,000 | 20,000 | ~50,476 |

### 1.3 `PoolLedger.sol` — library

```solidity
function delta(IPoolManager pm, address account, Currency c) internal view returns (int256);
function debt (IPoolManager pm, address account, Currency c) internal view returns (uint256); // = -delta if negative, else 0
function slot (address account, Currency c) internal pure returns (bytes32); // keccak256(abi.encode(account, currency))
```

Reads PoolManager transient storage via `exttload`. The v4 property the whole project rests on is
real: `exttload` is `external view`, the slot formula matches v4-core `CurrencyDelta._computeSlot`,
and the number is PoolManager's, not the hook's. **Nothing about this is overstated.**

### 1.4 `AssayHook.sol` — abstract, the spec carrier

State: five `immutable`s (`_inv0.._inv3`, `_invCount`). **No mutable state. No admin. No setter. No
recovery path.** Constants: `RUNTIME_GAS = 30_000`, `RUNTIME_HEADROOM = 20_000`,
`MAX_RUNTIME_INVARIANTS = 4`.

```solidity
constructor(address[] memory invariants_);                     // reverts TooManyInvariants if > 4
function runtimeInvariants() public view returns (address[] memory);
function describeSpec()      external view returns (string[] memory);
function verifySpec()        external view returns (Verdict[] memory);   // evaluated at RUNTIME budget
function _assertInvariants()            internal view;                   // fail-closed on VIOLATED and INCONCLUSIVE
function _assertInvariantsAllowingExit() internal;                       // fail-closed on VIOLATED only
function _assayEnter() internal view virtual returns (uint256);          // hook for AssayFlowMeter
function _assayExit(uint256) internal virtual;
```

Errors: `TooManyInvariants`, `InvariantViolated(address)`, `InvariantInconclusive(address)`.
Events: `RuntimeInvariantsDeclared(address[])`, `SpecUnevaluableOnExit(address)`.

> **Documentation defect (D-1).** The constructor NatSpec (`AssayHook.sol:51-52`) says *"Every
> declared invariant must HOLD at construction. A hook cannot ship with a spec that is already
> broken"*, and the contract header (`:24-25`) lists *"invariants are evaluated at construction and
> must HOLD"* as a mitigation. **The constructor does no such thing** — it only bounds the count.
> Lines 145-153 of the same file correctly explain why a constructor gate is impossible. The repo's
> own `test_hookWithBrokenSpecCannotServeASwap` deploys a hook whose spec is already VIOLATED and it
> deploys fine. Two of the four stated mitigations for the fail-closed bricking risk are fiction.

`verifySpec()` deliberately uses the *runtime* budget so the registry cannot report a bricked hook
as healthy. This is correct and is proven by `test_verifySpecAgreesWithRuntime_notWithAGenerousBudget`.

### 1.5 `AssayBaseHook.sol` — abstract, the seal

Extends OZ `BaseHook` + `AssayHook`. **Verified against `lib/.../uniswap-hooks/src/base/BaseHook.sol`:**
the ten `external` v4 entrypoints are `external onlyPoolManager` with **no `virtual`**, and
`AssayBaseHook` overrides the eight value-capable `internal` `_callback`s **without `virtual`**. A
subclass therefore cannot override either layer — the compiler rejects it. The seal is real.

Each sealed callback is exactly:

```solidity
uint256 mark = _assayEnter();
(...)  = _assayX(...);                 // integrator's code
_assertInvariants();                   // or _assertInvariantsAllowingExit() on the two remove paths
_assayExit(mark);
```

| v4 callback | wrapped? | assertion used |
|---|---|---|
| `beforeSwap`, `afterSwap` | yes | strict |
| `beforeAddLiquidity`, `afterAddLiquidity` | yes | strict |
| `beforeRemoveLiquidity`, `afterRemoveLiquidity` | yes | **allowing-exit** |
| `beforeDonate`, `afterDonate` | yes | strict |
| `beforeInitialize`, `afterInitialize` | **no** | — (documented: cannot move value) |

**Integration surface an outside developer touches:** inherit `AssayBaseHook`, pass
`(IPoolManager, address[] invariants)` to the constructor, override `getHookPermissions()`, and
implement any of `_assayBeforeSwap / _assayAfterSwap / _assayBeforeAddLiquidity /
_assayAfterAddLiquidity / _assayBeforeRemoveLiquidity / _assayAfterRemoveLiquidity /
_assayBeforeDonate / _assayAfterDonate` (all `internal virtual`, all defaulting to a no-op that
returns the right selector). That is the whole API. It is genuinely small.

> **Scope limit the README never states (A-10).** The seal covers the v4 callback surface *only*. Any
> other external function a subclass declares — `harvest()`, `sweep()`, `rescue()`, an owner-gated
> withdrawal, or anything that calls `poolManager.unlock` itself — runs with **zero** invariant
> enforcement. "A hook that cannot violate its spec" is true only of what happens inside the eight
> wrapped callbacks.

### 1.6 `AssayFlowMeter.sol` — abstract, extends `AssayBaseHook`

```solidity
constructor(IPoolManager pm, address[] memory invariants_, Currency currency_, uint256 perBlockLimit_);
function flowLimitPerBlock() public view returns (uint256);   // 0 disables
function flowThisBlock()     public view returns (uint256);
function _assayEnter() internal view override returns (uint256);  // override WITHOUT virtual — cannot be switched off
function _assayExit(uint256 mark) internal override;
```

Mutable state: `uint48 _meterBlock`, `uint208 _flowThisBlock` (packed, one slot). Immutables:
`_flowPoolManager`, `_flowCurrency`, `_perBlockLimit`. No admin, no setter.

`_meterSince(mark)` charges `debt(now) - mark` per callback and reverts `FlowLimitExceeded` when the
per-block running total crosses the limit. Measuring the **increase** rather than the absolute is
correct and non-obvious — under `afterSwapReturnDelta` the hook's `take()` debt is netted to zero by
the returned delta, so an absolute running total would score every extraction after the first as
zero. The reasoning in the NatSpec is sound.

> **Undisclosed limits (A-11).** The meter covers **exactly one currency**, fixed at deployment. A
> hook can be metered on `currency1` and extract `currency0` freely. It is also per-hook, not
> per-pool: a hook serving several pools shares one allowance. Neither is mentioned in the README's
> "per-block extraction ceiling".

### 1.7 `HookBond.sol` — the only contract holding user funds

Non-upgradeable, no owner, no admin, `ReentrancyGuard` on every state-changing external.

```solidity
function bondIdOf(address hook, address author) public pure returns (bytes32);              // keccak256(abi.encodePacked(hook, author))
function challengeCommitment(bytes32 bondId, uint256 index, bytes32 salt, address challenger) public pure returns (bytes32);
function commitChallenge(bytes32 commitment) external;                                       // ANYONE
function bond(address hook, address[] calldata predicates, uint96[] calldata stakes) external payable returns (bytes32);  // ANYONE, on ANY hook
function addPredicate(bytes32 bondId, address predicate) external payable;                   // author only
function topUp(bytes32 bondId, uint256 index) external payable;                              // author only, RESETS exit clock
function requestExit(bytes32 bondId) external;                                               // author only
function withdraw(bytes32 bondId) external;                                                  // author only
function challenge(bytes32 bondId, uint256 index, bytes32 salt) external payable;            // ANYONE
function bondsOfHook(address) / predicatesOf(bytes32) / stakesOf(bytes32) external view;
mapping(address hook => uint256) public forfeited;                                           // NO withdrawal path, ever
```

Constants: `UNBONDING_DELAY 7d`, `ESCAPE_DELAY 90d`, `BOUNTY_BPS 1000` (10%), `CHALLENGER_STAKE
0.01 ETH`, `MIN_BOND 0.01 ETH`, `MIN_TRANCHE 0.001 ETH`, `MAX_PREDICATES 8`, `COMMIT_DELAY 1` block,
`REVEAL_WINDOW 256` blocks.

Trust assumptions: none on the hook, none on the predicate (sandboxed), none on the challenger. The
author is trusted with nothing. Everything mutable is per-bond and author-gated except `challenge`
and `commitChallenge`, which are open by design.

Verdict routing in `challenge()`:

| Verdict | Effect |
|---|---|
| HOLDS | challenger's 0.01 ETH is **burned into `forfeited[hook]`** (not paid to the author), `ChallengeFailed` |
| INCONCLUSIVE | stake **refunded**, `ChallengeFailed` — only gas is lost |
| VIOLATED | tranche zeroed; 10% bounty + stake to challenger; 90% to `forfeited[hook]`; `everSlashed = true` |

`withdraw()` re-evaluates every **non-zero** tranche's predicate: VIOLATED blocks forever,
INCONCLUSIVE blocks until `unbondingAt + 90 days`.

Two structural notes on the open functions:

- `commitChallenge` takes **no stake, has no per-address cap, and never expires from storage**
  (`commits[c]` is deleted only on a successful reveal, `:287`). A commitment is one `SSTORE`, ~22k
  gas. See A-14 and A-14.
- `_liveBond()` reverts `BondEmpty` when `amount == 0` but `bonds[id].author` is only cleared by
  `withdraw()`, never by a slash. See A-13 (tombstone).

### 1.8 `AssayRegistry.sol` — stateless view contract

```solidity
constructor(HookBond hookBond_);
function report(address hook) public view returns (HookReport memory);
function reportMany(address[] calldata hooks) external view returns (HookReport[] memory);
function bondBreakdown(address hook) external view returns (address[] predicates, uint256[] stakes, bool truncated);
uint256 public constant MAX_BOND_SCAN = 256;
```

`HookReport` carries 17 fields: permission bits decoded from the address with zero calls
(`canReturnSwapDelta`, `canReturnLiquidityDelta`, `canBlockInitialize`), spec state
(`hasRuntimeSpec`, `specProbeFailed`, `invariantCount`, `invariants[]`, `violatedCount`,
`inconclusiveCount`), metering (`metered`, `flowLimitPerBlock`), and money (`bondedWei`,
`liveBondCount`, `slashedBondCount`, `anyExitRequested`, `anyExitMatured`, `bondScanTruncated`).

Probes are `staticcall` with gas caps 8,000,000 / 500,000 / 100,000 for `verifySpec()` /
`runtimeInvariants()` / `flowLimitPerBlock()`. Separating "declares nothing" from "could not tell"
(`specProbeFailed`) is a genuinely careful touch.

> **A-4, A-3.** All three probes use Solidity's `(bool, bytes memory)` form — the *unbounded*
> returndata copy that `docs/NEXT_SESSION_ASSAY.md` §3.5 explicitly forbids ("check for it in any new
> code that calls out"). Confirmed exploitable, §4. And the 256-entry scan window is a permanent,
> cheaply-poisonable smear surface, §4.

### 1.9 `AssayStack.sol` — concrete `AssayBaseHook`

```solidity
constructor(IPoolManager pm, address[] memory subHooks, uint16[] memory budgetsBps, uint16 stackMaxBps_, address[] memory invariants_);
function subHooks() public view returns (address[] memory, uint16[] memory);
function withdraw(Currency currency) external;              // guest pulls its own accrued balance
mapping(address subHook => mapping(Currency => uint256)) public accrued;
uint256 public constant SUB_HOOK_GAS = 150_000;
uint256 public constant MAX_SUB_HOOKS = 4;
uint16  public immutable stackMaxBps;
```

Guest interface is one function: `assayAfterSwap(address,PoolKey,SwapParams,BalanceDelta) returns (uint256 requested)`.
Dispatch clamps `requested` to `min(notional*budgetBps/BPS, remaining stack ceiling)`, credits an
internal ledger, and after the loop does a single `take()` for the total and returns it as the
afterSwap delta. Guest calls use **bounded 32-byte assembly `call`** (`_dispatchOne`), so a
returndata bomb is contained. Reentrancy into `_assayAfterSwap` or `withdraw` is blocked by a
transient `_dispatching` flag; the nested dispatch is *skipped*, not reverted.

Guest list, budgets and ceiling are all immutable. There is no admin and no removal path.

---

## 2. The invariant model

### 2.1 How an integrator declares an invariant

The entire declaration is a constructor argument. There is no registration, no config, no setter:

```solidity
contract MyHook is AssayBaseHook {
    constructor(IPoolManager pm, address[] memory invs) AssayBaseHook(pm, invs) {}

    function _assayAfterSwap(address, PoolKey calldata k, SwapParams calldata p, BalanceDelta d, bytes calldata)
        internal override returns (bytes4, int128) { /* ...your logic... */ }
}

// deploy site:
address[] memory invs = new address[](1);
invs[0] = address(new DeltaBudgetPredicate(poolManager, currency1, 5 ether));   // <-- the whole spec
new MyHook(poolManager, invs);   // (in practice CREATE2-mined for the permission bits)
```

Real example, verbatim from `test/assay/AssaySuiteDemo.t.sol:97-104`.

### 2.2 Why an invariant is an *address*

Because the property must be evaluated by code the hook does not control, in a context where the
evaluator can be sandboxed. An address gives four things a `bytes32` predicate-id or an inline
`require` cannot:

1. **Sandboxability.** `staticcall` to a foreign address is the enforcement of "view-only, no
   reentrancy, bounded gas, bounded returndata". You cannot sandbox your own inline code.
2. **Third-party auditability.** The claim is a deployed, verifiable contract anyone can read and
   independently call — `AssayRegistry.report()` returns the predicate addresses precisely so a
   reader is not stuck with a count.
3. **Shared identity across hooks and across the bond.** The *same* `DeltaBudgetPredicate` instance
   is both a runtime invariant in the hook and a slashable claim in `HookBond`. One address, one
   meaning.
4. **Parameterisation by deployment** (see §2.5).

The cost is one `staticcall` per invariant per callback, measured at ~3.5–4.6k gas (§5).

### 2.3 Where it is evaluated, with what budget, and what happens on each verdict

Evaluation happens in exactly three places, all via `PredicateSandbox`:

| Site | Budget | HOLDS | VIOLATED | INCONCLUSIVE |
|---|---|---|---|---|
| `AssayHook._assertInvariants()` — end of `beforeSwap`, `afterSwap`, `before/afterAddLiquidity`, `before/afterDonate` | 30k / 20k | continue | `revert InvariantViolated(inv)` | `revert InvariantInconclusive(inv)` |
| `AssayHook._assertInvariantsAllowingExit()` — end of `beforeRemoveLiquidity`, `afterRemoveLiquidity` | 30k / 20k | continue | `revert InvariantViolated(inv)` | **`emit SpecUnevaluableOnExit(inv)` and proceed** |
| `HookBond.bond` / `addPredicate` / `withdraw` / `challenge` | 200k / 120k | see §1.7 | see §1.7 | see §1.7 |
| `AssayHook.verifySpec()` (view, for the registry) | 30k / 20k | reported | reported | reported |

Evaluation order is `_inv0` → `_inv3`, short-circuiting on the first failure. With four invariants a
callback needs ~50,476 gas retained at the *last* check, i.e. the machinery reserves roughly 200k of
headroom across a full spec. Note `PredicateSandbox` **reverts** (rather than answering) when gas is
short — so on the exit path, a gas-starved `removeLiquidity` still fails closed despite the carve-out.

The asymmetry on the exit paths is the single most important design decision in the file and it is
correctly reasoned: the invariant set is immutable with no recovery path, so failing closed on
withdrawal would trap LP capital permanently the moment a predicate broke. It is proven by
`test_lpCanAlwaysExitEvenWhenTheSpecIsUnevaluable`. It also opens A-5 (§4).

### 2.4 What is and is not expressible

**Structurally expressible** — one `staticcall`, present state, public data, no privileged input, no
history, ≤30k gas, no dependence on `msg.sender` (the predicate sees `HookBond`/the hook as caller,
never the original actor), and the only argument is the hook address:

- *Ledger bounds.* "This hook's un-settled debt to PoolManager in currency X is ≤ N." (the strongest one)
- *Balance floors / solvency.* "`token.balanceOf(hook) ≥ N`", "`balanceOf(hook) ≥ hook.assayAccrued(token)`".
- *Address-encoded permissions.* "This hook cannot return a swap delta." Zero calls, works on an undeployed address.
- *Code identity.* "`hook.codehash` equals the pinned value."
- *Absolute pool-state bands.* "Spot tick ∈ [min, max]."
- Anything else readable in ≤30k gas from public storage: a paused flag, a configured recipient, a supply cap.

**Structurally NOT expressible**, with concrete examples:

| Class | Why | Example that cannot be a predicate |
|---|---|---|
| **Historical / temporal** | present state only, no memory | "the hook never took more than 1 ETH in any past block"; "the hook stole from Alice in block N" |
| **Relative / delta** | one observation, no before-value | "price moved <2% this block"; "the hook's balance did not fall this transaction". `TickBandPredicate` is the absolute-band degradation of this, and its own NatSpec admits a band wide enough not to false-trip on a volatile pair prevents nothing. |
| **Fairness / distributional** | not a function of present state | "this swap was priced fairly"; "LP surplus was distributed pro-rata by age" (this is exactly `HardcapHook`'s open finding F1 — it can never be a predicate) |
| **Actor-dependent** | `check(address hook)` takes no other argument, and `msg.sender` is the sandbox | "only the owner called `sweep()`"; "the caller was not the sequencer" |
| **Cross-transaction aggregate** | see above; needs state | "≤5 ETH extracted per block" — **this is precisely why `AssayFlowMeter` exists as a separate stateful mixin rather than a predicate** |
| **Anything over ~30k gas** | runtime budget | iterating positions; a TWAP over an oracle ring buffer; multi-hop simulation |
| **Another contract's storage** | EVM has no cross-contract SLOAD | an EIP-1967 proxy implementation slot (admitted in `CodehashPredicate`) |
| **Multi-call composition** | one staticcall from the sandbox (the predicate may make its own sub-calls, but pays for them out of 30k) | "compare this pool's price against three other venues" |

### 2.5 Parameterisation: yes, by constructor, immutably, by whoever deploys the predicate

There is no per-hook or per-pool binding mechanism. A parameterised predicate is **a separate
deployed instance per parameter set**, with the parameters as `immutable`s:

```solidity
contract DeltaBudgetPredicate is IHookPredicate {
    IPoolManager public immutable poolManager;
    Currency     public immutable currency;
    uint256      public immutable maxDebt;
    constructor(IPoolManager poolManager_, Currency currency_, uint256 maxDebt_) { ... }
    function check(address hook) external view returns (bool) {
        return PoolLedger.debt(poolManager, hook, currency) <= maxDebt;
    }
}
```

- **Who binds it:** whoever deploys the predicate instance. In every shipped test that is the hook
  author or the test harness. Nothing stops a third party from deploying it — the parameters are
  public, so anyone can verify what a given instance asserts.
- **Which hook it applies to:** *none, until used.* `check(address hook)` is parameterised by
  argument, so **one predicate instance is reusable across arbitrarily many hooks.** The binding
  hook→predicate lives in `AssayHook`'s immutables and in `HookBond._predicates[bondId]`.
- **Can it be changed after deployment?** **No, in three independent senses.** The predicate's
  `immutable`s cannot change; `AssayHook`'s invariant set is immutable with no add/remove/replace;
  `HookBond` allows `addPredicate` (strengthen) but has no remove.
- **Per-pool?** Only `TickBandPredicate` is pool-scoped (`PoolId poolId` immutable). The other six
  are hook-scoped or currency-scoped. `DeltaBudgetPredicate` is **not** pool-scoped — it bounds a
  hook's debt in one currency across every pool it serves simultaneously.

Consequence worth stating plainly: **the only way to raise a budget is to deploy a new hook.** That
is the intended discipline, but it also means every parameter is a permanent, un-tunable commitment
made before the hook has ever seen traffic.

### 2.6 Every shipped predicate

| Predicate | Constructor params | Calls | What it catches | How it is satisfied vacuously / fails |
|---|---|---|---|---|
| `DeltaBudgetPredicate` | `(IPoolManager, Currency, uint256 maxDebt)` | 1 × `exttload` on PoolManager | Hook's outstanding un-settled debt in that currency exceeding `maxDebt` | **Vacuous outside a callback — confirmed empirically.** Transient storage is zero at the top of any transaction, so `check()` returns `true` unconditionally when called by `HookBond.challenge()`, `bond()`, `withdraw()`, or `AssaySuite`'s invariants. Verified: an instance with `maxDebt = 0` — the strictest claim expressible — reports HOLDS for the bare address `0xBEEF`, **which has no code at all**, and a 1 ETH bond against `0xBEEF` succeeds. It has teeth *only* inside `_assertInvariants()`. Also: it measures instantaneous debt at one callback boundary, not cumulative extraction — a hook whose per-callback take is netted out by its returned delta can repeat within one transaction without the number ever rising. (See D-2.) |
| `BalanceFloorPredicate` | `(address token, uint256 floor)` | 1 × `balanceOf` | Hook holdings dropping below an absolute floor | Set `floor = 0`. Also blind to the hook holding ERC-6909 claims instead of tokens, and to a second token. If `balanceOf` reverts (paused/blocklisted token) → INCONCLUSIVE → the hook bricks. |
| `SolvencyPredicate` | `(address token)` | 2: `token.balanceOf(hook)` + `hook.assayAccrued(token)` | Hook holding less than it says it owes | **Trusts the hook's own number.** A hook returning `0` from `assayAccrued` satisfies it forever. This is demonstrated on purpose by `test_sameBugSameHook_solvencyPassesItLedgerStopsIt`, which is the best test in the repo. A hook that *reverts* on `assayAccrued` makes its own spec INCONCLUSIVE at will — see A-5. |
| `NoSwapDeltaPredicate` | none | **zero** | A hook whose address permits `beforeSwapReturnDelta` or `afterSwapReturnDelta` | Cannot be satisfied vacuously — it is pure address arithmetic and PoolManager enforces the same bits. Genuinely unfalsifiable. Proven with teeth by `test_hardcapCannotBondAClaimItsAddressContradicts`. |
| `PermissionMatchPredicate` | `(uint160 expectedFlags)` | **zero** | A hook holding authority beyond its advertised set | Deploy an instance whose `expectedFlags` equals whatever the hook already has — trivially true, and indistinguishable from a tight claim without reading the constructor arg. Same class of "vacuous by parameter" as `floor = 0`. |
| `CodehashPredicate` | `(address hook)` — pins `hook.codehash` at deploy | 1 × `EXTCODEHASH` | selfdestruct-and-redeploy (metamorphic) | Catches nothing for a proxy: the proxy's codehash never changes on upgrade. Correctly and prominently admitted in its own NatSpec and in the README. Note it pins whatever the hook's code was *at predicate-deploy time*, so deploying it before the hook is finalised pins nothing useful. |
| `TickBandPredicate` | `(IPoolManager, PoolId, int24 minTick, int24 maxTick)` | 1 × `getSlot0` | Spot price leaving a fixed band | Declare `[MIN_TICK, MAX_TICK]`. Its own NatSpec: on a volatile pair "a band wide enough to avoid false trips is too wide to prevent anything, and declaring one there is theatre." Correct, and worth repeating: nothing in `HookBond` or the registry distinguishes a real band from a universe-wide one. |

The recurring pattern: **five of seven predicates can be made vacuous by a constructor argument, and
neither `HookBond` nor `AssayRegistry` can tell a tight parameterisation from a loose one.** The
README's answer is `bondBreakdown` (price per claim). That is disclosure, not prevention, and the
README says so — but note it only prices the *claim*, never its *tightness*: 40 ETH on
`BalanceFloorPredicate(token, 0)` looks identical to 40 ETH on a real floor.

---

## 3. Real vs demo-ware

Every straw-man hook or predicate the demos rely on, all written in this repo:

| Fixture | File | Role |
|---|---|---|
| `LeakyHook` / `AssayedLeakyHook` | `test/assay/AssayHook.t.sol` | transfers 1e18 to a `thief` on every swap |
| `GreedyHook` / `AssayedGreedyHook` | `test/assay/DeltaBudget.t.sol` | siphons 50% of every fill and lies (`assayAccrued → 0`) |
| `DrippingHook` | `test/assay/FlowMeter.t.sol` | siphons 1% per swap |
| `ForgetfulHook`, `QuietHook`, `ExitQuietHook` | `test/assay/AssayBaseHook.t.sol` | integrator that never calls the assertion; inert hooks |
| `HungryPredicate`, `DecayingPredicate` | `test/assay/AssayBaseHook.t.sol` | burns >30k; can be killed |
| `GuardedFeeHook` | `test/assay/AssaySuiteDemo.t.sol` | 1% fee-taker, the sole `AssaySuite` subject |
| `PoliteSubHook`, `GreedySubHook`, `RevertingSubHook`, `GasBurningSubHook`, `BombingSubHook`, `ReentrantSubHook` | `test/assay/AssayStack.t.sol` | the six "hostile" guests |
| `PlainHook`, `RevertingSpecHook`, `CodehashLike` | `test/assay/AssayRegistry.t.sol` | registry probe targets |
| `MockBondedHook`, `FlipPredicate`, `BreakablePredicate`, `ReentrantChallenger` | `test/assay/HookBond.t.sol` | **`MockBondedHook` is a `mapping` plus a setter.** All 33 `HookBond` tests run against it; every slash in the file is produced by `_breakSolvency()` = `hook.setDeclared(token, 1000e18)`, i.e. telling the mock to declare a liability. No PoolManager is deployed in that file; nothing is swapped or extracted. |

**`AssayStack` is the only non-test contract in `src/` that inherits `AssayBaseHook`.** The
reference hook, `HardcapHook`, is a plain `BaseHook + ReentrancyGuard`; it carries **no runtime
spec at all** and participates only as a bonding target via `assayAccrued`. The repo does not
dogfood its own flagship.

### Claim-by-claim

| README claim | Status | Evidence / why not |
|---|---|---|
| "Enforcement is not optional — a subclass physically cannot override the callbacks" | **PROVEN** | `test_enforcementSurvivesAnIntegratorWhoNeverCallsIt`, plus direct verification that OZ `BaseHook`'s ten externals are non-`virtual` and `AssayBaseHook`'s eight overrides are non-`virtual`. Correctly scoped to the callback surface — but see A-10: it says nothing about a subclass's *other* functions. |
| "Any defect whose effect is the hook extracting beyond a declared budget becomes unexecutable" | **PARTIALLY PROVEN** | `test_assayedGreedy_cannotExceedItsDeclaredBudget` and `test_sameBugSameHook_solvencyPassesItLedgerStopsIt` prove it for extraction *inside a wrapped callback*, in *one currency*, against a straw-man bug we wrote. Not proven for: extraction through a non-callback function (A-10), a second currency (A-11), or a guest inside `AssayStack` (A-1). |
| "One staticcall, no history, present state only — and never claimed otherwise" | **PROVEN**, and unusually honest | `IHookPredicate` NatSpec, `HookBond` header, README §What this is not. Enforced by construction. |
| "Only present-state invariants are provable; fairness is not expressible" | **PROVEN** and consistently applied | Withdrawn from Hardcap's framing rather than fudged. Credit where due. |
| Gas: 192 / 3,497 / 4,509 / 5,766 | **PARTIALLY PROVEN — two numbers are stale** | Re-measured this session: machinery **170** (README says 192), balance-floor **3,497** ✓, ledger **4,631** (README says 4,509), metering **5,766** ✓. See §5. |
| "`test_fourGuestsOneHostileAndThePoolStillWorks` … one broken guest must not brick a pool" | **DISPROVEN as a general claim** | The four "hostile" guests all confine themselves to the return value. A guest that calls `poolManager.take()` bricks every swap on the pool permanently. PoC confirmed, §4 A-1. |
| "Guests never touch PoolManager" | **UNSUPPORTED — it is an aspiration, not an invariant** | `_dispatchOne` uses `call`, not `staticcall`. Nothing prevents a guest from calling PoolManager, and PoolManager is unlocked when it does. |
| "A guest returning 128KB does not charge the swapper" | **PROVEN** | `test_returndataBombDoesNotChargeTheSwapper`; the bounded assembly copy is real. |
| "A guest reentering mid-dispatch only forfeits its own turn" | **PROVEN** | `test_reentrantGuestIsRefusedAndOnlyHurtsItself`; transient `_dispatching` + skip-not-revert. |
| "Predicate sandbox: revert / OOG / mutation / reentrancy / bomb / malformed all read INCONCLUSIVE, never VIOLATED" | **PROVEN FOR A COPY OF THE CODE, NOT FOR THE SHIPPED CODE** | The 13-test kill-suite is in `test/spike/PredicateSandbox.t.sol` — outside `test/assay/*`, and it **does not import `src/`**; it re-declares the library and tests its own copy. Code review of `src/assay/PredicateSandbox.sol` confirms all six paths do map to INCONCLUSIVE, and the logic is the same — but the shipped file has zero adversarial test coverage, including for the parameterised `evaluate` overload that only exists in `src/`. A-8. |
| "LP exits never fail closed" | **PROVEN** | `test_lpCanAlwaysExitEvenWhenTheSpecIsUnevaluable`. But it is also an enforcement off-switch — A-5. |
| "Bond mechanics kill suite: exit race, self-slash, griefing, commit-reveal, conservation, growth attacks" | **PARTIALLY PROVEN** | 33 tests, all scripted linear paths, **no fuzz and no invariant test on `HookBond` anywhere**, all against `MockBondedHook`. Seven test names claim more than they assert: `test_bond_requiresEveryPredicateToHoldNow` (only ever tests N=1), `test_bond_isKeyedByHookAndAuthor_noSquatting` (reduces to `assertTrue(a != b)` — see A-3), `test_spec_canOnlyBeStrengthened` (proves adding works, asserts nothing about "only"), `test_slashedTrancheCannotBeSlashedTwice` (reverts `BondEmpty`, not `TrancheAlreadySlashed` — **the real double-slash guard at `HookBond.sol:309` has zero coverage repo-wide**), `test_conservation_acrossFullLifecycle` (asserts one internal identity at four points; never sums participant balances; never calls `requestExit`/`withdraw`, the two functions that move ETH out), `test_permissionPredicates_areZeroCall` and `test_codehashPredicate_pinsDeployedCode` (neither asserts its headline property; neither touches `HookBond` at all). |
| "Exit requires proving your own spec" | **PROVEN** | `test_authorCannotExitADrainedHook`, `test_exit_isBlockedWhileSpecIsViolated`. Note the "drain" is a `deal()` cheat-code balance write, not an exploited bug — the *bond* mechanics are proven, the *drain* is simulated. |
| "Commit-reveal defeats a reactive mempool copier; a pre-committed searcher can still race" | **PROVEN and honestly labelled** | The limit is asserted in a test named `test_knownLimit_...`. This is the right way to ship a known gap. |
| "`AssayRegistry`: one view call … no hook can be listed inaccurately, omitted, or squatted" | **DISPROVEN** | 256-entry scan window + permanent, permissionless list growth = a hook *can* be made to under-report its own backing, permanently. §4 A-3. |
| "`AssaySuite`: thousands of randomised swaps spend the campaign trying to make your declared spec false … it also asserts the campaign did something" | **UNSUPPORTED as shipped** | The framework is sound, but its one instantiation declares only a `DeltaBudgetPredicate`, whose verdict is read between transactions where transient storage is zero. All three substantive invariants are structurally incapable of failing. §4 A-2. |
| "Hardcap … publishes its liability through `assayAccrued` and is bonded" | **PROVEN**, and correctly de-scoped | The MEV-recapture framing was withdrawn rather than defended. |
| "`NoSwapDeltaPredicate` refuses to let Hardcap's author bond a claim to the contrary" | **PROVEN**, and the single best demo in the repo | `test_hardcapCannotBondAClaimItsAddressContradicts`. Zero calls, zero trust, and it has teeth against the repo's own author. |
| "Nothing is deployed" (handoff §4.2) | accurate | No `script/DeployAssay.s.sol`, no live address. |
| "The gap table does not exist" (handoff §4.3) | accurate | `docs/research/data` is empty. |

---

## 4. Security posture — findings

Ranked by severity. Four were confirmed by execution during this audit (A-1 and A-4 by PoC, A-3 and
A-6 empirically, A-7 by test); the rest are from code review.

| # | Sev | Finding | Falsifies |
|---|---|---|---|
| A-1 | HIGH | An `AssayStack` guest bricks the pool permanently via `poolManager.take()` | README §Composition 1 & 3 |
| A-2 | HIGH | The shipped `AssaySuite` campaign asserts four things that cannot fail | README §AssaySuite |
| A-3 | MED-HIGH | Registry `bondedWei` permanently zeroed by refundable sybil bonds | `AssayRegistry` header |
| A-4 | MED | Unbounded returndata copy in all three registry probes (78× measured) | handoff §3.5 |
| A-5 | MED | INCONCLUSIVE on the exit path is a hook-controllable enforcement off-switch | README §4 |
| A-6 | MED | `DeltaBudgetPredicate` is unslashable and unblockable as a bonded claim | README §Predicate library |
| A-7 | MED | A fully-slashed bond is a permanent tombstone; the author can never re-bond | `HookBond.sol:70-72` |
| A-8 | MED | The sandbox kill-suite tests a *copy* of the library, not the shipped file | README §Tests |
| A-9 | MED | Self-slashing one dust tranche releases the exit block on all others | README §HookBond rails |
| A-10 | MED | Enforcement covers the callback surface only; other externals are unguarded | README headline |
| A-11 | MED | The flow meter covers one currency, shared across every pool | README §Meter |
| A-12 | LOW-MED | `_send` push-payment bricks withdrawals and blocks valid slashes | — |
| A-13 | LOW-MED | `describeSpec()` is the one unsandboxed predicate call | — |
| A-14 | LOW | Author can burn a challenger's stake by curing inside the commit window; commits are free and unbounded | test docstring |
| A-15 | LOW | `forfeited` is unrecoverable (deliberate, accurately documented) | — |
| A-16 | LOW | Codehash pinning is largely moot post-EIP-6780; proxies remain invisible | — |
| A-17 | INFO | Accepted limits verified — two of four bricking mitigations do not exist | `AssayHook.sol:24` |


### A-1 — HIGH. Any `AssayStack` guest can permanently brick the pool by touching PoolManager directly. **CONFIRMED BY POC.**

`AssayStack._dispatchOne` invokes guests with `call`, forwarding 150,000 gas. The safety story is
"guests never touch PoolManager", but that is a *convention*, not an enforced property. PoolManager
is **unlocked** during `afterSwap`.

**Exploit path.** A guest calls `poolManager.take(currency, address(this), 1)` — well within the
stipend — and returns `0` normally. `take` credits the guest a negative delta of 1 wei that nobody
ever settles. The stack sees a clean return and carries on; the swap completes; the whole
transaction then reverts inside `PoolManager.unlock` with **`CurrencyNotSettled()`**. Because the
guest list is `immutable`, there is no admin, and there is no removal path, **every swap on that
pool fails forever.** The stack's own `DeltaBudgetPredicate` does not fire — the poisoned delta
belongs to the *guest's* address, not the stack's.

Confirmed: a two-test PoC (`LedgerPoisoningSubHook`) passes — an unarmed guest swaps fine, an armed
guest makes two consecutive swaps revert with `CurrencyNotSettled()`. LP exits survive only because
this stack does not wrap `removeLiquidity`; a stack that also declared `beforeRemoveLiquidity` would
trap LP capital too. Variants that need no `take` at all: `poolManager.sync(otherCurrency)`, or
`poolManager.donate` / `swap` on any pool.

This directly falsifies README §Composition bullet 3 ("Fail-open for the guest, fail-closed for the
pool. One broken guest must not brick a pool other people's liquidity sits in") and bullet 1
("Guests never touch PoolManager"). `test_fourGuestsOneHostileAndThePoolStillWorks` passes only
because all four straw-man guests politely confine themselves to their return value.

*Fix directions:* snapshot `PoolManager.getNonzeroDeltaCount()` (or the guest's own delta) around
each dispatch and revert-and-skip if it moved; or require guests to be deployed behind a forwarder
that cannot reach PoolManager; or `staticcall` guests (which forbids the stateful guests the design
wants). At minimum, stop asserting the guarantee.

<details><summary>PoC (add as <code>test/assay/_ZPoc.t.sol</code>)</summary>

```solidity
contract LedgerPoisoningSubHook is IAssaySubHook {
    IPoolManager public pm; Currency public c; bool public armed;
    function arm(IPoolManager pm_, Currency c_) external { pm = pm_; c = c_; armed = true; }
    function assayAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta)
        external returns (uint256)
    {
        if (armed) pm.take(c, address(this), 1);   // negative delta, never settled
        return 0;
    }
}
// stack with this as its only guest, budget 100bps, ceiling 300bps,
// invariant DeltaBudgetPredicate(poolManager, currency1, 1e15):
//   _swap();                       // passes while disarmed
//   evil.arm(poolManager, currency1);
//   vm.expectRevert(); _swap();    // CurrencyNotSettled()
//   vm.expectRevert(); _swap();    // ...forever
```
</details>

### A-2 — HIGH (methodological). The `AssaySuite` campaign is vacuous as shipped. 256 runs × 128,000 calls prove nothing.

`AssaySuiteDemoTest`'s hook declares exactly one invariant:
`DeltaBudgetPredicate(poolManager, currency1, 1e16)`. The suite's invariants call
`assayedHook().verifySpec()` — from the *invariant runner*, i.e. at the top level between
transactions, where PoolManager's **transient** storage is zeroed. `PoolLedger.debt()` therefore
returns 0 on every single evaluation and `check()` returns `true` unconditionally.

- `invariant_assay_specNeverViolated` — cannot fail. Ever.
- `invariant_assay_specNeverBecomesUnevaluable` — cannot fail; the predicate is immutable and reads
  a slot that always answers.
- `invariant_assay_flowWithinDeclaredLimit` — cannot fail; `_flowThisBlock` is only ever written by
  `_meterSince`, which reverts (rolling the write back) before it can store a value above the limit.
  Reading it back and asserting `<= limit` is a tautology.
- `invariant_assay_campaignActuallyExercisedTheHook` — the only one that can fail, and it asserts
  `swaps() > 0`, guaranteed by the warm-up swap in `setUp`.

The framework itself is not vacuous — pointed at a `BalanceFloorPredicate` or `SolvencyPredicate`
(persistent state) `specNeverViolated` would have real teeth. But **the shipped instantiation is
exactly the "invariant suite that passed on luck" the handoff doc warns about**, still in the tree,
costing 46 seconds of every CI run. `test_campaignCoverage` (`swaps > 20 && reverts > 0`) is the
only assertion in that file doing work.

*Fix:* declare a `BalanceFloorPredicate` alongside the budget predicate on the demo hook, and add a
handler action that performs a multi-callback swap so the ledger predicate is exercised where it
actually applies.

### A-3 — MEDIUM-HIGH. A hook's registry entry can be permanently poisoned for the price of gas. **CONFIRMED BY REASONING + the repo's own test.**

`HookBond._bondsOfHook[hook]` is append-only by explicit design ("rewriting history to look tidy
would let a hook shed the record of a slashing"). `bond()` is permissionless and keyed by
`(hook, author)`, so any address can open a bond on **any** hook — including one it does not own.
`AssayRegistry._bonds` and `bondBreakdown` scan only the **first 256** entries in insertion order.

**Exploit path.** Before an honest author bonds their hook (the address is public — it must be
CREATE2-mined and published for the permission bits), an attacker bonds it from 256 sybil EOAs at
`MIN_BOND` = 0.01 ETH each. After `UNBONDING_DELAY` they `withdraw()` every one and get the ETH
back; the `_bondsOfHook` entries remain forever. The honest author's real bond is now at index ≥256
and is **never scanned**. `report()` returns `bondedWei = 0`, `liveBondCount = 0`,
`bondScanTruncated = true` — permanently, with no recovery, for a net cost of gas only.

`test_scanIsBoundedAndAdmitsTruncation` inserts 260 entries and treats the bound as the *mitigation*.
It is the exploit surface. `test_rebondingDoesNotGrowTheList` closes only the single-author variant
(the `_indexed` guard); it says nothing about sybil authors, which the growth test then demonstrates
works.

Severity is capped at MEDIUM-HIGH because it is a view-layer smear, not a fund loss — but the
registry's entire value proposition is "no hook can be listed inaccurately or omitted", and this
makes both happen. It also directly attacks the handoff doc's §4.3 headline artifact.

*Fix:* require a non-refundable listing fee, or make `bondsOfHook` return a paginated window with an
`offset` so a UI can walk past the poison, or index only bonds that were ever live and prune on
withdraw while keeping a separate immutable slash record.

### A-4 — MEDIUM. Unbounded returndata copy in `AssayRegistry` — the exact bug the handoff doc forbids. **CONFIRMED BY POC.**

`_spec`, `_invariants` and `_flow` all use Solidity's `(bool, bytes memory) = hook.staticcall(...)`
form, which copies **all** returndata into the caller's memory. `docs/NEXT_SESSION_ASSAY.md` §3.5:
*"Never let untrusted code choose how much memory you allocate… This bug was fixed once and
reintroduced in the stack — check for it in any new code that calls out."* It is in the registry.

Measured this session: `report()` against a hook whose fallback returns 512KB costs **1,816,490 gas**
versus **23,148** for a quiet hook — a **78× blow-up**, and it scales with what the hook returns (the
`verifySpec` probe forwards up to 8,000,000 gas). `abi.decode(data, (Verdict[]))` on attacker-chosen
bytes is a second amplifier.

Impact is confined to view calls, but `reportMany()` is precisely the function the handoff doc's
§4.3 "gap table" would use across every deployed hook on chain — one hostile entry blows up the
batch. Every UI calling `report()` on an arbitrary address is exposed.

*Fix:* copy the `PredicateSandbox` / `AssayStack._dispatchOne` pattern — bounded assembly copy with
an explicit size cap — into all three probes.

<details><summary>PoC</summary>

```solidity
contract BombingHook { fallback() external { assembly { return(0, 0x80000) } } }  // 512KB
// registry.report(address(new BombingHook()))  ->  1,816,490 gas
// registry.report(address(quiet))              ->     23,148 gas
```
</details>

### A-5 — MEDIUM. INCONCLUSIVE on the exit path is an enforcement off-switch on the one callback where value leaves a departing LP.

`_afterRemoveLiquidity` uses `_assertInvariantsAllowingExit()`, which downgrades INCONCLUSIVE to an
event. A hook holding `afterRemoveLiquidityReturnDelta` can extract from a withdrawing LP in exactly
that callback. So the callback with the most direct victim is the one where "cannot tell" stops
blocking.

**Exploit path.** Any way to make the predicate un-evaluable at 30k gas turns enforcement off there:
- `SolvencyPredicate` calls `hook.assayAccrued(token)`. **The hook controls that function.** Making
  it revert (or consume >30k) under a chosen condition yields INCONCLUSIVE at will.
- `BalanceFloorPredicate` calls `token.balanceOf(hook)`. A pausable / blocklisting token reverting on
  `balanceOf` produces the same result with no hook involvement.
- Any predicate whose gas cost is state-dependent and crosses 30k.

The README frames the carve-out purely as protection *for* LPs ("VIOLATED still blocks, because a
violation during a withdrawal is the hook extracting from the LP who is leaving"). That sentence is
true and the reasoning for the carve-out is sound, but the completeness claim is not: only VIOLATED
blocks, and a hook that can choose INCONCLUSIVE never produces VIOLATED.

*Fix:* keep the carve-out for `beforeRemoveLiquidity` (no delta possible) and fail closed on
`afterRemoveLiquidity` when the hook's address carries `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG` —
that bit is readable with zero calls, so the asymmetry costs nothing when it does not apply.

### A-6 — MEDIUM. `DeltaBudgetPredicate` is inert as a *bonded* claim; its slashing story is decoration.

Every `HookBond` path (`bond`, `addPredicate`, `withdraw`, `challenge`) evaluates predicates from the
top level of an ordinary transaction, where the hook's transient delta is zero. `check()` therefore
returns `true` unconditionally. **A `DeltaBudgetPredicate` tranche can never be slashed and never
blocks an exit** — it is free stake that always survives, indistinguishable in `bondBreakdown` from a
claim with real risk.

No shipped test bonds a `DeltaBudgetPredicate` (only `SolvencyPredicate`, `CodehashPredicate`,
`PermissionMatchPredicate`, `NoSwapDeltaPredicate`, and toy predicates), so the gap is not visible
from the test suite. The strongest predicate in the library is exactly the one bonding cannot use.

This is not a contradiction of the architecture — `DeltaBudgetPredicate` is a *runtime* invariant and
does its job there — but it means "40 ETH on never exceeding its budget", the README's own worked
example of the price signal, is **the one number that can never be lost.** That example should be
changed.

*Fix:* have `HookBond` reject predicates that report HOLDS unconditionally when evaluated against a
freshly-created address with no code, or (better) tag predicates as runtime-only vs bondable and
refuse the former in `bond()`.

### A-7 — MEDIUM. A fully-slashed bond is a permanent tombstone: the author can never bond that hook again.

`_liveBond()` reverts `BondEmpty` when `amount == 0`, but `bonds[id].author` is cleared **only by
`withdraw()`** — never by a slash. After a single-tranche bond is fully slashed, and **even once the
author has completely cured the violation**:

- `topUp(id, 0)` → `BondEmpty`
- `addPredicate(id, …)` → `BondEmpty`
- `withdraw(id)` → `BondEmpty`
- `bond(hook, …)` from the same author → **`BondExists`** (`:181` checks only `author != address(0)`)
- `_predicates[id]` / `_stakes[id]` are never cleared; stale entries linger forever

Because `bondId = keccak256(hook, author)` is deterministic, there is **no recovery** short of a new
EOA (which discards the author identity the bond exists to establish) or a new hook address. This
contradicts the contract's own docstring at `:70-72` — *"it does not kill the bond, because the
assertions that still hold are still backed"* — and `test_slashingOneTrancheLeavesTheRestStanding`
asserts the bond stays live in the multi-tranche case. The single-tranche case being an
unrecoverable dead-end reads as unintended rather than designed. `test_withdrawnBondIsDeletedAndRebondable`
covers only the *withdraw* path; the *slash* sibling is untested.

*Fix:* clear `bonds[id]`, `_predicates[id]` and `_stakes[id]` when the last live tranche is slashed,
keeping `everSlashed` history in a separate mapping (which is where it belongs anyway, since
`_bondsOfHook` is already the permanent record).

### A-8 — MEDIUM. The sandbox kill-suite tests a *copy* of `PredicateSandbox`, not the shipped one.

`test/spike/PredicateSandbox.t.sol` is 13 genuinely good adversarial tests — revert, no-code, OOG,
attempted mutation, reentrancy, a 128KB returndata bomb measured differentially against the naive
call form, short return, dirty bool, and `InsufficientGas` rather than a wrong answer. It is the
strongest engineering in the repo.

It does **not import `src/`**. It re-declares `enum Verdict`, `interface IHookPredicate`,
`library PredicateSandbox` and `NoSwapDeltaPredicate` inside the test file and tests those. The file
header says *"SPIKE ONLY … Promote `PredicateSandbox` to `src/` only if every test here is green."*
The library was promoted. The tests were not.

Consequences:
1. `src/assay/PredicateSandbox.sol` has **zero direct test coverage**. It is reached only through
   `HookBond`/`AssayHook`, and only ever against benign predicates or `BreakablePredicate` (the
   `!ok` branch). The bomb, mutation, reentrancy, dirty-bool, short-return and `InsufficientGas`
   paths of the shipped code are never executed by any test.
2. The shipped file gained a parameterised `evaluate(predicate, hook, stipend, headroom)` overload
   that the spike copy does not have — and it is the overload every runtime call uses. Untested
   against any adversarial predicate.
3. `PredicateSandbox.sol:45` claims the selector is *"pinned by `test_selector_matches_interface`"*.
   That test pins the spike file's own local interface declaration. The selectors coincide, so the
   comment is accidentally true and the provenance claim in shipped source is false.

The code is, on review, correct. But "the sandbox is proven" is not a statement the test suite
currently supports, and this is the one contract where that matters most.

*Fix:* delete the local declarations, import from `src/assay/`, move the file into `test/assay/`, and
add the same adversarial battery against the parameterised overload at the 30k runtime budget.

### A-9 — MEDIUM (economic). Self-slashing one cheap tranche releases the exit block on every other tranche.

Three facts compose into an escape hatch nobody evaluated:

1. `withdraw()` skips tranches where `st[i] == 0` — *"a slashed tranche no longer constrains the
   exit"* (`:255-260`), proven by `test_slashedAssertionNoLongerBlocksTheExit`.
2. `challenge()` is permissionless, so the author can slash their own bond via any address.
3. A slash costs 90% of **that tranche only**; the 10% bounty returns to the self-challenger.

So an author whose spec is genuinely broken — and whose capital is therefore locked forever by
`SpecViolated` — can pay 90% of the *smallest* tranche backing the *broken* claim and immediately
free every other tranche for a normal 7-day exit. Where the broken claim is the padded, dust-backed
one (`MIN_TRANCHE` = 0.001 ETH), the cost of walking away from a violated spec is **0.0009 ETH**.

`test_selfSlash_isNotARefund` proves the author nets −0.9 ETH on a 1 ETH single-tranche bond, which
is true and is the right test to have written. It does not model the multi-tranche case, where the
ratio that matters is *slashed tranche* : *released tranches*, not *bounty* : *tranche*. The
per-assertion tranching that §1.7 correctly praises for preventing all-or-nothing over-punishment
also, unavoidably, prices the exit.

This is arguably inherent to tranching rather than a bug — but it should be stated, and the README's
*"a VIOLATED predicate blocks withdrawal permanently"* is not accurate for a multi-tranche bond.

### A-10 — MEDIUM. Enforcement covers the v4 callback surface only; any other external function is unguarded.

`AssayBaseHook` seals the eight value-capable `_callback`s, and that seal is real (verified: OZ
`BaseHook`'s ten externals are non-`virtual`, and the eight overrides are non-`virtual`). But it
constrains **only what happens inside those eight functions**. A subclass may declare any number of
additional external functions — `harvest()`, `sweep()`, `rescue()`, an owner-gated withdrawal, or
anything that calls `poolManager.unlock` itself — and `_assertInvariants()` never runs in any of
them. The flow meter never runs there either.

**Exploit path (defect, not malice):** a hook with a legitimate `collectFees()` that a bug lets an
attacker call with the wrong recipient. The hook still reports `verifySpec() -> [HOLDS]`, is still
bonded, still shows healthy in the registry, and every invariant is bypassed — not evaded, simply
never reached. The extraction leaves no trace in the meter, and `DeltaBudgetPredicate` is blind
because it is only ever evaluated inside callbacks.

The README's headline — *"hooks that carry a machine-checked spec they cannot violate"* — is true of
the callback surface and only of the callback surface. Nothing in the repo states this scope, and it
is the first question an auditor asks. `HardcapHook` itself ships such a function (`claim()`), which
is a fair illustration of how ordinary they are.

*Fix:* inheritance alone cannot close this. State the scope in the README, and ship an
`assayGuarded` modifier for integrator-authored externals so an omission is at least visible.

### A-11 — MEDIUM. The flow meter covers exactly one currency and is shared across every pool.

`AssayFlowMeter` takes a single `Currency _flowCurrency` immutable. A hook metered on `currency1`
extracts `currency0` with **no metering at all** — and the mixin cannot be instantiated twice
(sibling mixins overriding `_assayEnter`/`_assayExit` form the diamond the NatSpec correctly refuses
to create). The meter is also keyed on the hook, not the pool, so a hook serving N pools shares one
per-block allowance: a busy pool starves a quiet one, and metering one pool's drain is defeated by
routing it through another pool of the same hook, or the same pool's other currency.

`DeltaBudgetPredicate` has the same per-currency shape but can be declared up to four times, so a
spec can at least cover four currencies. The meter cannot cover two. The README's *"per-block
extraction ceiling"* states neither limit.

*Fix:* store up to four `(currency, limit)` pairs in immutables, exactly as `AssayHook` already does
for invariants, and meter each in `_assayEnter`/`_assayExit`.

### A-12 — LOW-MEDIUM. `_send` reverting bricks the author's own principal, and blocks valid slashes.

`_send` reverts `TransferFailed` if the recipient's `receive`/`fallback` reverts or lacks a payable
path. Two consequences, neither tested:
- **`withdraw()`**: a contract author (a multisig with a non-payable fallback, a DAO timelock) that
  cannot receive ETH bricks its own bond permanently. There is no `to` parameter and no pull path.
- **`challenge()`**: a challenger contract whose `receive` reverts turns a *valid* slash into a full
  transaction revert. Self-inflicted, but it means a slash can be griefed by choosing a bad payee —
  and the honest slash simply does not happen.

`test_challenge_reentrancyIsBlocked` exercises exactly this path (its `ReentrantChallenger.receive`
reverts) but asserts only `TransferFailed`, which any reverting receiver produces — so the test
cannot distinguish "the reentrancy guard fired" from "the callee just reverted". Both commits in
that test also target index 0, and `challenge` already zeroes `st[0]` before `_send` (correct CEI),
so the reentrant call would revert `BondEmpty` even with `nonReentrant` removed. The guard is real;
the test does not isolate it.

*Fix:* pull-payment (`credits[to] += amount`) instead of push, for both paths.

### A-13 — LOW-MEDIUM. `describeSpec()` is the one unsandboxed call to a predicate.

```solidity
function describeSpec() external view returns (string[] memory out) {
    for (...) out[i] = IHookPredicate(invs[i]).describe();   // no sandbox, no gas cap, no size bound
}
```
A predicate that reverts, OOGs, or returns a megabyte in `describe()` breaks or bloats the hook's
human-readable spec. Harmless to enforcement (`describeSpec` is not on any value path) but it is the
public-facing "what does this hook claim" call, and `test_assayedHook_publishesItsSpec` depends on it.
Wrap it or bound it.

### A-14 — LOW. Author can burn an honest challenger's stake by curing inside the commit window.

`COMMIT_DELAY = 1` block. A commitment is a hash, so the author cannot tell *which* bond or predicate
is targeted — but they can see that *some* commit landed and, for any curable violation (top up a
balance, restore a codehash by re-deploying at the same address, un-revert `assayAccrued`), fix it
before the reveal. The challenger then reveals into a HOLDS verdict and their 0.01 ETH is burned into
`forfeited[hook]`. The NatSpec at `HookBond.sol:56-59` **states this explicitly and accurately**,
including that the gap is chosen as the minimum that defeats a reactive copier. Correctly disclosed.

**But the characterisation of the residual limit is wrong.** `test_knownLimit_preCommittedSearcherCanStillRace`
has both parties pre-commit *in the same block, before any reveal exists*, then calls the copier's
reveal first — it demonstrates that whoever the test calls first wins, not a race. Its docstring
claims commit-reveal *"converts a free copy into a speculative, gas-costly position."* The contract
refutes that: `commitChallenge` takes **no stake**, has **no per-address cap**, and a commitment is
one `SSTORE` (~22k gas). A searcher can blanket-commit across every `(bondId, index)` pair of every
bonded hook with **zero capital at risk**, revealing only the winners. Commitments are also never
cleared unless revealed (`:287`), so the `commits` mapping grows monotonically and permanently —
free, unbounded state growth on a contract with no admin.

*Fix:* require `CHALLENGER_STAKE` at commit time rather than reveal time, which makes the
pre-commit genuinely speculative and prices the state growth. Then award the oldest valid commit
(the two-phase auction already in the handoff doc §4.7).

### A-15 — LOW. Slashed capital is locked forever; `forfeited` has no withdrawal path.

Deliberate, documented (`HookBond.sol:79-81`, handoff §4.8), and correct for v1 — value must leave
the author's reach for slashing to cost anything. **Verified: it is nowhere described as
compensation.** The `docs` and README are accurate on this. The consequence worth naming is that a
successful challenge destroys 90% of a tranche with zero benefit to any victim, which weakens the
"Immunefi in the hook" framing more than the docs let on.

### A-16 — LOW. Metamorphic / upgrade evasion.

`CodehashPredicate` catches selfdestruct-and-redeploy only; proxy upgrades are invisible because a
contract cannot read another contract's storage. **Accurately described** in the predicate's NatSpec,
the README (§6), and the handoff doc (§3.8). Note the residual: post-EIP-6780, `SELFDESTRUCT` only
clears code in the same transaction it was created, so the metamorphic vector this predicate targets
is largely dead on modern chains — the predicate mostly guards against nothing, while the vector that
matters (proxy) is the one it cannot see.

### A-17 — INFORMATIONAL. Accepted items verified as accurately described.

- Bond < TVL does not deter a rational attacker — stated plainly everywhere, never hedged. ✓
- Spec padding with cheap claims — accurately described as *disclosure, not prevention*. ✓ (with the
  A-6 caveat that the worked example is the un-slashable one, and the §2.6 caveat that tightness is
  not published, only price)
- Assay binds hooks that opted in — stated. ✓
- Fail-closed can brick a pool — stated, **but two of the four listed mitigations do not exist** (D-1).
- Pre-committed searcher can race the reveal — asserted in a test that names itself a known limit. ✓

### Findings checked and found NOT to be problems

Worth recording so they are not re-litigated:

- **Reentrancy in `HookBond`.** `nonReentrant` on every payable/state-changing external; `_send` is
  last-write-then-call in `withdraw` and post-state-update in `challenge`. Clean.
- **`bondId` collision.** `keccak256(abi.encodePacked(hook, author))` over two fixed-width types —
  not ambiguous.
- **`uint96` truncation on `msg.value`.** Reachable only above ~7.9e10 ETH.
- **Slashed-tranche double-spend.** `st[index] == 0` guard plus `b.amount -= tranche` before payout.
- **Sandbox escape via a mutating predicate.** `staticcall` — the EVM enforces it.
- **Diamond inheritance on `_assayEnter`/`_assayExit`.** Deliberately avoided by chaining
  `AssayFlowMeter` off `AssayBaseHook`; the reasoning in the NatSpec is correct.
- **`AssayStack` returndata bomb.** Genuinely fixed with a bounded assembly copy.
- **`_unspecified` operator precedence** (`params.amountSpecified < 0 == params.zeroForOne`) — parses
  as `(a < 0) == b`, which is the intended currency selection. Ugly, correct.

### D — Documentation defects (not vulnerabilities, but the README is the product)

- **D-1.** `AssayHook.sol:24` and `:51-52` claim invariants are evaluated at construction and must
  HOLD. They are not. Two of the four stated mitigations for the bricking risk are fictional.
- **D-2.** `DeltaBudgetPredicate.sol:10-11` — *"Asserts a hook has not pulled more than `maxDebt`
  out of the PoolManager in the current transaction."* It asserts **instantaneous un-settled debt at
  one callback boundary**. Under `afterSwapReturnDelta` the debt is netted to zero by the returned
  delta, so N swaps in one transaction extract N × budget without the number ever exceeding budget.
  `AssayFlowMeter`'s own NatSpec explains this correctly for the meter; the predicate's does not.
- **D-3.** README gas table: two of four figures do not reproduce (§5).
- **D-4.** README "Tests" section implies `forge test` covers the sandbox kill-suite; that suite is
  in `test/spike/`, outside `test/assay/*`, and outside the command the handoff doc gives.
- **D-5.** README §Composition asserts guarantees A-1 disproves.
- **D-6.** `HookBond.sol:23-25` and README: *"a VIOLATED predicate blocks withdrawal permanently."*
  True for a single-tranche bond; false for a multi-tranche one, where self-slashing the violated
  tranche releases every other tranche for a normal exit (A-9).
- **D-7.** `PredicateSandbox.sol:45` cites `test_selector_matches_interface` as pinning the selector.
  That test pins the spike file's own local interface, not `src/assay/IHookPredicate.sol` (A-8).
- **D-8.** `test_knownLimit_preCommittedSearcherCanStillRace`'s docstring calls a blanket pre-commit a
  *"speculative, gas-costly position."* `commitChallenge` takes no stake and has no cap (A-14).

---

## 5. Gas — re-derived, not quoted

Ran `forge test --match-test gasCost -vv` this session. Actual output:

| Measurement | README | **Measured now** | Test |
|---|---|---|---|
| `AssayHook` machinery, 0 invariants | 192 | **170** | `test_gasCostOfRuntimeEnforcement` |
| One `BalanceFloorPredicate` | 3,497 | **3,497** ✓ | `test_gasCostOfRuntimeEnforcement` |
| One `DeltaBudgetPredicate` (ledger) | 4,509 | **4,631** | `test_gasCostOfLedgerInvariant` |
| Per-block flow metering | 5,766 | **5,766** ✓ | `test_gasCostOfMetering` |

Absolute swap costs measured: plain hook 51,353 → AssayHook/0 51,523 → AssayHook/1 55,020;
unbounded 55,502 → ledger-bounded 60,133; unmetered 58,162 → metered 63,928.

**Is the methodology honest?** Substantially yes, and it is visibly the product of having been burned
once — the test carries a comment explaining that an earlier 23.5k reading was a cold zero-to-nonzero
SSTORE artefact. Specifically:

- Like-for-like: both hooks in each pair perform the **same** value-moving operation. ✓
- Warm: one throwaway swap per pool before measurement. ✓
- `gasleft()` deltas around the same router call in the same test, so the router/calldata overhead
  cancels in the difference. ✓
- The metering baseline uses `perBlockLimit = 0` (which skips the SSTORE but **still pays
  `_assayEnter`'s `exttload`**), so 5,766 correctly isolates the second read + packed SSTORE + event.
  That is the right baseline. ✓

Three caveats:

1. **Two numbers are stale.** 192 vs 170 and 4,509 vs 4,631 are deterministic measurements, so these
   are not noise — the README was not re-measured after a code change. Fix the table.
2. **"192 gas machinery" is measured on the `AssayHook` mixin path, not the `AssayBaseHook` sealed
   path.** `AssayedLeakyHook` inherits `AssayHook` and calls `_assertInvariants()` by hand; the sealed
   path additionally pays two virtual dispatches (`_assayEnter`/`_assayExit`) plus the `_assayX`
   indirection on every callback. The headline understates what an actual `AssayBaseHook` integrator
   pays. Nothing in the repo measures the sealed path's own overhead.
3. **Only the 1-invariant case is measured.** The cap is 4. A 4-invariant spec is ~4× the per-invariant
   cost *and* requires ~50,476 gas retained at the last check — which is the number that determines
   whether a spec bricks a hook under a tight gas limit, and it is never measured or asserted.

The assertions guarding these (`< 15,000`, `< 30,000`) are loose enough to be regression bumpers
rather than claims. That is fine, but it means the numbers in the README are the artifact, and two of
them are wrong.

---

## 6. Verdict

Theme: **Sustainable Liquidity and MEV Protection.**

### Theme fit — 2/5

The theme asks about MEV and liquidity sustainability. Assay is about **hook trustworthiness**, which
is a real and arguably more important problem — but it is a different problem, and the repo knows it:
Hardcap's MEV framing was explicitly withdrawn, and the README correctly refuses to claim that "this
swap was unfairly priced" is expressible. What is left touching the theme is thin: bounding hook
extraction is adjacent to LP sustainability, and `TickBandPredicate` is a circuit breaker against
single-transaction oracle manipulation. Nothing here protects a swapper from a sandwich, and the
project is honest enough not to pretend otherwise. Judges scoring against a rubric will notice.

### Novelty — 4/5

Two genuinely novel observations, both v4-specific and both verified in-repo: reading a hook's live
flash-accounting delta out of PoolManager's **transient** storage via `exttload` mid-callback (a
number the hook does not own and cannot misreport), and deriving permissions from the address bits
with zero calls for any address, deployed or not. The reframe from *enumerate bug classes* to *bound
damage at the ledger* is the right idea and it is not a thing the field is currently doing. Marks off
because bonding-plus-slashing is well-trodden, and because the sealed-callback trick, while elegant,
is a Solidity idiom rather than a discovery.

### Technical depth — 3/5

`PredicateSandbox` is genuinely good work: the INCONCLUSIVE verdict is load-bearing and correctly
routed everywhere, the 63/64 gas check answers-or-reverts rather than answering wrong, and the
bounded returndata copy is right. `verifySpec()` deliberately using the runtime budget so the registry
cannot certify a bricked hook is the kind of second-order thinking most submissions never reach. The
LP-exit asymmetry is a real trade-off reasoned through rather than stumbled into. Marks off for A-1
(the composition model's central guarantee does not hold), A-4 (the repo's own written rule violated
in the newest contract), and D-1/D-2 (two NatSpec blocks assert behaviour the code does not have).

### Demonstrability — 2/5

This is where it falls down. Nothing is deployed; there is no address to point at. **Every single
demo runs against a straw-man hook written in this repo**, and the one shipped `AssayStack` hostile
guest set is polite enough that the real attack (A-1) passes right through it. The 46-second,
128,000-call `AssaySuite` campaign asserts four things that cannot fail (A-2). The gap table — *"N
deployed hooks, X able to move a swap delta, **zero** declaring a spec, **zero** bonded"* — is the
strongest artifact available, writes its own headline, and does not exist. Working against it: the
sealed-callback demo and the `NoSwapDeltaPredicate`-refuses-its-own-author demo are both excellent and
take thirty seconds to explain.

### Real-world adoption likelihood — 2/5

The integration surface is genuinely small (inherit, pass an address array, implement `_assayX`) and
the cost is genuinely low (~3.5–4.6k gas per invariant). Against that: the invariant set is
**immutable with no recovery path**, fail-closed, and evaluated on every swap — so a hook author is
being asked to bet their pool's liveness on a 30k-gas staticcall they can never change, in exchange
for a reputational signal nobody currently reads. A-5 and A-2 mean the enforcement is weaker than
advertised in exactly the places an adopter would care about. Realistically this gets adopted, if at
all, as a *predicate library plus a testing harness* rather than as a base class — which is a fine
outcome, but not the one the README is selling.

### The single biggest weakness

**Everything is proven against hooks we wrote to be caught.** The straw men are calibrated to the
defence, and the one place I wrote a hostile contract that was not (`LedgerPoisoningSubHook`, twelve
lines) it broke a headline guarantee in the first attempt. That is the whole risk of the submission
in one sentence: the code is better than most hackathon code, and the evidence around it is
self-refereed. The fix is not more contracts — it is **one real third-party hook wrapped, one
deployment, and one measured gap table.** All three are named in the handoff doc, all three are still
missing, and all three are worth more than any additional feature.

---

*Audit performed 2026-08-26 against `master` @ `5e99379`. Test counts, gas figures, and both PoCs
were produced by running the tree, not read from the docs.*
