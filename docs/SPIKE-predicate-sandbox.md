# SPIKE — predicate sandbox and predicate scope (2026-08-21)

**Status: PASS.** 13/13 spike tests green (`test/spike/PredicateSandbox.t.sol`), 79/79 repo-wide, no
regression on the Hardcap envelope. Do not rediscover any of this.

Riskiest assumption being validated *before* building the bond contract: can an untrusted,
author-chosen predicate be evaluated by the bond contract without mutating state, reentering,
killing the outer tx, or griefing the caller — **and can a `false` result be distinguished from an
un-evaluable one?** If a revert reads as VIOLATED, honest hooks are slashable for free. If a revert
reads as HOLDS, dishonest hooks are unslashable. Both are fatal, so this had to be settled first.

---

## 1. Read primitives (confirmed by source inspection, zero mocking)

| Primitive | Signature | Consequence |
|---|---|---|
| `Hooks.hasPermission(IHooks, uint160)` | `internal pure` | All 14 permission bits decode **from the hook address alone**. Zero calls, zero trust, no bytecode fetch. This is the property no other contract class on Ethereum has, and it is the defensible core of the pitch. |
| `PoolManager.extsload(bytes32)` / `(bytes32,uint256)` / `(bytes32[])` | `external view` | Every `StateLibrary` getter is staticcall-safe → predicates can read live pool state inside the sandbox. |
| `PoolManager.balanceOf(address,uint256)` | `public` mapping (ERC-6909) | A hook's claim-token balance is externally readable → solvency is a one-call proof. |

Flag layout: `ALL_HOOK_MASK = (1 << 14) - 1`; `BEFORE_SWAP_RETURNS_DELTA = 1 << 3`,
`AFTER_SWAP_RETURNS_DELTA = 1 << 2`, `AFTER_ADD_LIQUIDITY_RETURNS_DELTA = 1 << 1`,
`AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA = 1 << 0`.

## 2. Sandbox semantics (implemented and tested)

`IHookPredicate.check(address) external view returns (bool)`; selector **`0xc23697a8`**
(hardcoded in assembly — `test_selector_matches_interface` pins it; a guessed selector silently
turns every verdict into INCONCLUSIVE, which is how it was caught).

| Predicate behaviour | Verdict | Test |
|---|---|---|
| returns `true` | HOLDS | `test_true_holds` |
| returns `false` | VIOLATED | `test_false_violated` |
| reverts | **INCONCLUSIVE** | `test_revert_isInconclusive_notViolated` |
| burns all gas (OOG) | INCONCLUSIVE, outer tx survives and can still write | `test_oog_isInconclusive_andOuterTxSurvives` |
| tries to mutate state | INCONCLUSIVE (rejected by `staticcall`), storage unchanged | `test_mutation_isRejectedByStaticcall` |
| tries to reenter the bond contract | INCONCLUSIVE, no reentry | `test_reentrancy_isBlocked` |
| returns < 32 bytes | INCONCLUSIVE | `test_shortReturn_isInconclusive` |
| returns a dirty bool (word > 1) | INCONCLUSIVE | `test_dirtyBool_isInconclusive` |
| address has no code | INCONCLUSIVE | `test_noCode_isInconclusive` |
| caller supplies too little gas | **reverts** `InsufficientGas` — never answers wrong | `test_lowGas_reverts_ratherThanAnsweringWrong` |

`staticcall` gives mutation-rejection and reentrancy-blocking for free. Both were tested against
predicates that deliberately do **not** declare `IHookPredicate` (a real attacker ships a
nonpayable `check`; declaring the interface would not compile).

## 3. Measured, and it contradicted the assumption

128KB returndata bomb, gas charged to the caller:

```
bounded (32-byte copy), bomb    : 53,029
bounded (32-byte copy), honest  :  3,720
naive   (bytes memory), bomb    : 105,869
```

The bounded copy roughly **halves** the grief, so keep the assembly. But cost is **not** flat in
return size: the callee's own memory expansion is paid out of the caller's forwarded gas. **The
stipend is the real ceiling, not the copy bound.**

Design consequences, both non-optional:

1. **Cap the number of predicates evaluated per transaction.** Each one can burn `STIPEND`
   (200_000). A hook author who bonds N hostile predicates makes evaluation cost N × 200k.
2. Challenge flow charges the challenger up to `STIPEND` per evaluation even when the predicate is
   garbage → the anti-spam challenger stake is load-bearing, not decorative.

Constants: `STIPEND = 200_000`, `HEADROOM = 120_000`, 63/64 check is
`gasleft() >= STIPEND * 64 / 63 + HEADROOM`.

## 4. Trap 5 — predicate scope (DECIDED, do not widen)

**Present-state invariants only.** A predicate must be evaluable in one `staticcall` from public
state, with no privileged input, no historical state, and no dependence on `msg.sender`.

In scope (provable):
- solvency — `IERC20(c).balanceOf(hook) >= declaredAccrued(c)`, and the ERC-6909 equivalent
- conservation — `Σ claimed <= Σ accrued`
- no-upgrade — `implementation == frozenImplementation` (EIP-1967 slot via `extsload`-style read)
- no-owner — `owner()` is `address(0)` or reverts
- permission-match — address bits vs the hook's declared permission set
- delta-authority — hook cannot return a delta it does not hold the bit for (**implemented**:
  `NoSwapDeltaPredicate`, zero external calls, `test_realPredicate_permissionBits_zeroCalls`)
- parameter sanity — e.g. `extraFeeBps <= maxTakeBps`

Out of scope (**not** provable on-chain; do not gesture at these in the README or the video):
- "this swap was unfairly priced"
- "the hook stole from a user in block N"
- anything requiring historical state or a counterfactual execution

## 5. Settled in `HookBond` (2026-08-21)

Traps 1-3 are implemented and tested (`test/assay/HookBond.t.sol`, 23 tests).

- **Exit requires proving your own spec.** `withdraw` re-evaluates every predicate. VIOLATED blocks
  withdrawal *permanently* (tested at +3650 days), INCONCLUSIVE blocks it until `ESCAPE_DELAY`.
  This closes the front-run directly, so no separate "freeze while a challenge is open" is needed —
  a challenge resolves atomically, and an author cannot leave a broken spec at any point.
- **Unbonding delay** 7 days, and `topUp` is author-only and *restarts* it. Without the restart the
  delay covers only the first deposit: bond dust, mature the exit, then top up and leave same-block.
- **Self-slashing is not a refund.** Bounty 10% to the challenger; 90% to `forfeited[hook]`, which
  has no withdrawal path in v1. Sybil-challenging your own violated hook costs 90% of principal.
- **False challenges forfeit the stake; INCONCLUSIVE refunds it.** An un-evaluable predicate is not
  a false claim — only gas is lost — and the outcome is emitted for the registry to surface.
- **Specs can only be strengthened.** `addPredicate` exists; there is no remove.
- **Bond-time evaluation requires every predicate to HOLD**, which closes "bond an un-evaluable
  spec so nobody can ever slash you".
- **Withdraw deletes the bond** rather than zeroing it. A lingering zero bond is challengeable for a
  0-value `Slashed` event the registry would read as real, and it would permanently block re-bonding
  since `bondId = (hook, author)`.

## 6. Still open — decide before the registry and the video

1. **Challenge front-running — commit-reveal SHIPPED.** `commitChallenge(hash)` then
   `challenge(bondId, index, salt)` one block later. The commitment binds the challenger's address,
   so revealing the triple in a public transaction hands an observer nothing
   (`test_revealedSaltIsUselessToAnObserver`). `COMMIT_DELAY = 1` block is deliberate on both
   sides: it is the minimum that defeats a reactive copier, and the gap is also the window in which
   the AUTHOR can spot a commit and cure the violation, costing an honest challenger their stake —
   so shortest-that-works is correct. **Residual, asserted not hidden**
   (`test_knownLimit_preCommittedSearcherCanStillRace`): a searcher who blanket pre-commits across
   every (bond, predicate) pair can still race the reveal. That costs them gas, and note it does not
   change *whether* the slash happens — only who is paid. Real fix (out of scope): a two-phase
   auction awarding the oldest valid commit.
2. **Registry must surface exit state.** A bond with a matured `unbondingAt` can vanish at any
   block. Showing only `amount` would overstate the guarantee. Columns: bond, bond/TVL, exit
   requested?, matured?, predicate count, any INCONCLUSIVE.
3. **`forfeited` has no victim-claim path.** Deliberate in v1 — value must leave the author's reach
   for slashing to cost anything — but say so plainly rather than implying compensation.
4. **Bond sizing.** A bond below TVL does not deter a rational attacker. Unfixable; state it once.

## 7. Reference hook wiring (2026-08-21)

`HardcapHook.assayAccrued(address)` publishes the hook's declared liability so `SolvencyPredicate`
can compare it against the chain's view of its assets. Constructor now rejects `fee >
LPFeeLibrary.MAX_LP_FEE` (which also rejects the dynamic-fee flag `0x800000`, whose `key.fee` is a
flag rather than a rate and would feed garbage `feePips` to `SwapMath.computeSwapStep`) and
out-of-range `tickSpacing`. Six end-to-end tests in `test/assay/AssayHardcap.t.sol`.

The one worth putting in the video: **`test_hardcapCannotBondAClaimItsAddressContradicts`.**
Hardcap takes a fee through `afterSwapReturnDelta`, so its *address* says it can move a swap delta,
and `NoSwapDeltaPredicate` refuses to let its own author bond a claim to the contrary — regardless
of what the README says. Zero external calls are made to establish this.

## 8. Pivot — runtime enforcement (2026-08-22)

Panel round on the *submission* rather than the diff produced three objections with one shared fix:

1. **"Name a real hook exploit this would have prevented or compensated."** Cork was callback
   authorization; Bunni was rebalancing math. Solvency / codehash / permission-bit predicates catch
   neither. Post-hoc bonding cannot help with a drain: by the time insolvency is provable, the
   tokens are gone.
2. **Strip the vocabulary and `HookBond` is an escrow with a callback.** The v4-native content was
   ~15 lines of address-bit decoding.
3. **UHI10 is a hook incubator and the headline artifact was not a hook.**

Fix: `src/assay/AssayHook.sol`. A base contract other hook devs inherit — the same slot as OZ's
`BaseHook` — that evaluates declared invariants INSIDE its callbacks and fails closed. Bonding
becomes the backstop for what runtime checks cannot see, not the primary mechanism.

- **Fail-closed including on doubt.** INCONCLUSIVE reverts the user's transaction exactly as
  VIOLATED does. Stated trade-off, not an oversight: a badly written invariant can brick the pool.
  Mitigations: invariants must HOLD at construction, the set is immutable, capped at 4, each gets a
  30k budget. Anything richer belongs in a bonded predicate.
- **`_assertInvariants()` is `view`**, so the extension point exposed to inheritors can only refuse
  — it can never move value. That is what makes it safe to expose at all.
- Invariants live in immutable slots, not a dynamic array, because this runs on every swap.

**Measured cost (like-for-like, warm second swap):** machinery 192 gas, **one runtime invariant
3,497 gas**. A first measurement read 23.5k; that was almost entirely a cold zero-to-nonzero SSTORE
on the recipient's balance slot which only the guarded hook paid — an artefact of comparing a hook
that transfers against one that does not. Both arms now perform the same transfer.

Demo pair in `test/assay/AssayHook.t.sol`: `LeakyHook` drains 1e18 per swap and keeps draining;
`AssayedLeakyHook` has the identical bug and cannot complete a single swap — not one wei leaves.

## 9. Harness defect found while running the full suite (2026-08-22)

`test/HardcapInvariant.t.sol` called `targetSelector` without `targetContract`, so the default fuzz
target set was every contract deployed in `setUp` — including the MockERC20s. A run that called
`MockERC20.burn(hook, ...)` directly broke `invariant_vaultCoveredByHookBalance`. That is a harness
defect, not a hook defect: nothing on-chain lets an attacker burn another account's balance.
`targetSelector` constrains which selectors of the handler are called, not which contracts are
targeted. Fixed with `targetContract(address(handler))`; three consecutive clean runs. The invariant
suite had been passing on luck.

## 10. Flagship — ledger-bounded extraction (2026-08-22)

The capability the project was missing, and it does not exist outside v4:

- PoolManager keeps every account's live flash-accounting delta in **transient** storage at
  `keccak256(abi.encode(account, currency))` (v4-core `CurrencyDelta._computeSlot`).
- `PoolManager.exttload(bytes32)` is **`external view`**.

So mid-callback, from outside, anyone can read exactly how much a hook is currently into the pool
for. `DeltaBudgetPredicate` asserts that number stays inside a declared budget.

**Why this outranks every other predicate:** it reads POOLMANAGER'S ledger, not the hook's
self-reported accounting. A hook that under-reports its liabilities makes a solvency assertion
vacuously true. It cannot make this one true, because it does not own the number.

**Consequence for the pitch — this is the sentence:** Assay does not enumerate bug classes. It
bounds the damage at the ledger. Any defect — authorization (Cork), arithmetic (Bunni), reentrancy,
a lying oracle — whose *effect* is the hook extracting beyond its declared budget becomes
unexecutable, whatever its cause. That is the answer to "name a real exploit this stops", and it
does not require predicting the exploit.

Sign convention: negative delta = the account owes PoolManager, i.e. has taken value out and not
paid for it. Bound the negative side. Timing: evaluate at the END of a callback, before the hook's
returned delta is applied, when outstanding debt is exactly what was physically removed.

**Measured: 4,509 gas** for the ledger check on a warm swap (vs 3,497 for a balance-floor check).

Proof is a controlled differential, `test_sameBugSameHook_solvencyPassesItLedgerStopsIt`: one hook,
one bug, two declared specs, only the invariant varies. The hook reports owing nothing;
`SolvencyPredicate` is satisfied by the lie and the drain completes; `DeltaBudgetPredicate` refuses
the identical swap. Revert reason verified as `InvariantViolated`, wrapped four deep by v4's
`CustomRevert`.

## 11. Design defect found and fixed: no constructor gate is possible

`_validateInvariantsAtDeploy()` was removed. During construction `address(this).code` is empty, so
any predicate that calls back into the hook — which is most of the interesting ones — reverts on the
extcodesize check and reads INCONCLUSIVE. A constructor gate would therefore only ever accept
predicates that never inspect the hook, i.e. exactly the useless ones. `BalanceFloorPredicate`
appeared to work only because it calls the token, never the hook.

It is also unnecessary: because `_assertInvariants` fails closed, a hook deployed with a spec that
does not hold cannot serve a single callback. It is bricked on arrival, publicly and immediately —
a stronger guarantee than a deploy-time check. Replaced by `verifySpec()`, an external view
returning per-invariant verdicts for the registry and for `HookBond`.

## 12. Original open list — settled above, kept for provenance

1. **Unbonding race.** Withdrawal delay length, and freezing withdrawal while a challenge is open.
   Non-negotiable; without it the bond is theatre.
2. **Self-slashing.** Bounty must be a small fraction (≤10%); the remainder must go somewhere the
   author cannot reach (victim pot claimable by that pool's LPs, or burned). `donate()` stays
   banned. Otherwise a sybil challenger makes slashing a refund.
3. **Hostile predicate selection.** The author picks which predicates their bond backs, so they can
   pick un-evaluable ones. Mitigations: evaluate every predicate at bond time and require HOLDS;
   ship a canonical frozen predicate library; surface INCONCLUSIVE publicly and flag
   "custom predicate" as a risk in the registry.
4. **Bond sizing.** A bond smaller than TVL does not deter a rational attacker. This is unfixable
   and must be stated in one plain sentence. Registry headline column is **bond/TVL**, not a letter
   grade — a price on trust, not a badge.

## 6. What was reused

`PredicateSandbox` is the same fail-closed shape as `HardcapHook._validateCallback` /
`_creditVault`: bounded, non-virtual, and biased toward refusing to act rather than acting wrongly.
The `test/hooks/HardcapAttackHooks.sol` harness is the model for the broken-hook fleet.
