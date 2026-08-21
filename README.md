# Assay

**A Uniswap v4 hook can prove things about itself that no other contract on Ethereum can.** Assay is the machinery that makes it do so: hooks that carry a machine-checked spec they cannot violate, capital staked behind that spec, and a public record anyone can read.

**No partner integrations.**

---

## The problem

A v4 hook runs on every swap, holds the most authority in the system, and is the least reviewed code in it. Today a hook asks you to trust it. The README says what it does; nothing checks. Cork was a callback-authorization bug. Bunni was rebalancing math. Neither was visible from outside before it fired, and neither was compensated after.

The usual response is to enumerate bug classes and write a detector for each. That fails at the next bug class.

## What Assay does instead

**It bounds the damage at the ledger, and does not care what caused it.**

Uniswap v4 keeps every account's live flash-accounting delta in *transient* storage, at `keccak256(abi.encode(account, currency))`, and exposes transient storage through `exttload`, which is `external view`. So mid-callback, from outside, anyone can read **exactly how much a hook is into the pool for right now** — from PoolManager's ledger, not from the hook's own accounting.

That is a number the hook does not own and cannot misreport. Any defect — authorization, arithmetic, reentrancy, a lying oracle — whose *effect* is the hook extracting beyond a declared budget becomes unexecutable, whatever its cause.

A hook's permissions are also encoded in the low 14 bits of its **address**, which PoolManager enforces. So what a hook is *permitted* to do is provable with zero calls, zero bytecode, and zero trust — for any address, deployed or not.

No other class of contract offers either property.

## Three parts

| | Contract | Role |
|---|---|---|
| **Prevent** | `AssayBaseHook` / `AssayHook` | Declared invariants evaluated **inside the callbacks**, fail-closed. The violation cannot complete. |
| **Meter** | `AssayFlowMeter` | Per-block extraction ceiling. A per-transaction bound is defeated by repetition; this is not. |
| **Back** | `HookBond` | Capital staked **per assertion**. Anyone can prove one predicate false and take a bounty out of that assertion's tranche; the others stay backed. |
| **Publish** | `AssayRegistry` | One view call: what a hook is permitted to do, what it claims, whether the claim holds, and how much money stands behind each individual claim. |
| **Compose** | `AssayStack` | Several untrusted hooks on one pool, each inside a bounded budget. |

Prevention handles what is cheap enough to check on every swap. Bonding covers the rest. Neither is sufficient alone, and the README does not pretend otherwise.

### Enforcement is not optional

`AssayBaseHook` implements every value-capable callback **without `virtual`**. A subclass physically cannot override them — it implements `_assayX` instead, and the assertion runs whether or not the author remembers it exists. `test_enforcementSurvivesAnIntegratorWhoNeverCallsIt` deploys a hook that declares a spec, drains on every swap, and never calls the assertion anywhere. It cannot complete a single swap.

### Cost

Measured like-for-like on a warm second swap (`test_gasCostOfRuntimeEnforcement`, `test_gasCostOfLedgerInvariant`, `test_gasCostOfMetering`):

| | gas |
|---|---|
| `AssayHook` machinery, zero invariants | 192 |
| one balance-floor invariant | 3,497 |
| one ledger-budget invariant | 4,509 |
| per-block flow metering | 5,766 |

## What this is not (must not lie)

1. **The bond does not cover losses.** A bond smaller than the value a hook controls does not deter a rational attacker. It is a costly signal plus challenger funding. The registry reports `bondedWei` next to what the hook is permitted to take, deliberately instead of a grade — a grade invites you to outsource the judgement, a price does not.
2. **Only present-state invariants are provable.** One staticcall, public state, no privileged input, no history. "This swap was unfairly priced" and "the hook stole from a user in block N" are not expressible and are never claimed.
3. **Assay binds hooks that chose to bind themselves.** A deliberately malicious author simply would not inherit it. The guarantee is against *defects* in hooks that opted in; what makes opting in credible to a third party is capital at risk and a public, machine-readable record.
4. **Fail-closed means a bad invariant can brick a pool's trading.** Stated trade-off, not an oversight: a hook whose claim is "I cannot violate my spec" must not proceed while unable to tell. Mitigations are a capped, immutable invariant set and a small per-invariant gas budget — **plus one deliberate asymmetry: LP exits never fail closed.** The invariant set is immutable with no recovery path, so failing closed on withdrawal would trap LP capital permanently whenever a predicate broke. An un-evaluable spec is recorded and the withdrawal proceeds; a genuinely VIOLATED one still blocks, because a violation during a withdrawal is the hook extracting from the LP who is leaving.
5. **A spec can still be padded with cheap claims.** Capital is staked per assertion, so slashing one settles that claim and leaves the rest backed — but nothing forces an author to put real money on the assertion that matters. `AssayRegistry.bondBreakdown` therefore publishes the stake behind *each* predicate: "40 ETH on never exceeding its budget, 0.01 ETH on its codehash" is legible in a way a single total is not. The defence is disclosure, not prevention.
6. **Proxy upgrades are not detectable on-chain.** A contract cannot read another contract's storage, so the EIP-1967 implementation slot is off-chain only. `CodehashPredicate` catches selfdestruct-and-redeploy, not a proxy upgrade, and says so.
7. **Challenge front-running is reduced, not eliminated.** Commit-reveal defeats a reactive mempool copier. A searcher who blanket pre-commits across every (bond, predicate) pair can still race the reveal — asserted in `test_knownLimit_preCommittedSearcherCanStillRace`. The slash still happens; only the payee changes.

## Predicate library

| Predicate | Calls | Catches |
|---|---|---|
| `DeltaBudgetPredicate` | PoolManager only | extraction beyond budget, from PoolManager's own ledger |
| `BalanceFloorPredicate` | token only | a hook's holdings dropping below a floor |
| `NoSwapDeltaPredicate` | **none** | a hook whose address says it can move a swap delta |
| `PermissionMatchPredicate` | **none** | authority a hook holds but never advertised |
| `CodehashPredicate` | none | code swapped out from under the bond |
| `TickBandPredicate` | PoolManager only | spot price leaving a declared band (stable pairs; a circuit breaker) |
| `SolvencyPredicate` | hook + token | hook holding less than it says it owes |

`SolvencyPredicate` trusts the hook's own number, so a hook that under-reports satisfies it vacuously. That is not a flaw to hide — it is the reason `DeltaBudgetPredicate` exists, and `test_sameBugSameHook_solvencyPassesItLedgerStopsIt` is the controlled differential proving it: one hook, one bug, two declared specs, only the invariant varies.

## Composition — `AssayStack`

v4 allows exactly one hook address per pool, so a pool picks one behaviour and forgoes every other. Composing has meant trusting a second body of code with the full authority of the first — and unbounded authority is precisely what the rest of Assay fixes. Once extraction is bounded at the ledger, hosting a stranger's hook stops being reckless.

- **Guests never touch PoolManager.** A sub-hook observes a swap and *returns a requested amount*. It holds no authority to take, settle, or reenter, so its request is a number to be clamped rather than an action to be trusted.
- **Per-guest budget**, plus a stack-wide ceiling that binds even when the individual budgets sum higher.
- **Fail-open for the guest, fail-closed for the pool.** A sub-hook that reverts or burns its gas stipend is skipped and logged. One broken guest must not brick a pool other people's liquidity sits in.
- **Immutable guest list, no admin.** Nobody can slip a new guest into a live pool.
- The stack is itself an `AssayBaseHook`, so the whole arrangement sits inside one ledger-enforced budget however its guests behave.

`test_fourGuestsOneHostileAndThePoolStillWorks` runs four guests on one pool — one asking for `type(uint256).max`, one that reverts, one that burns all its gas — and the pool works. The hostile guest receives exactly its budget, to the wei. A guest returning 128KB of data does not charge the swapper for it, and a guest reentering mid-dispatch only forfeits its own turn.

## AssaySuite

`src/assay/testing/` ships a drop-in invariant campaign. Inherit `AssaySuite`, write a `setUp` and two getters, and thousands of randomised swaps and liquidity operations spend the campaign trying to make your declared spec false. It also asserts the campaign *did something* — a run in which every operation reverted satisfies every other invariant while proving nothing.

## Hardcap

`src/HardcapHook.sol` is the reference hook: a fail-closed, single-pool hook with a sealed callback envelope, an immutable take cap, and an LP vault with no owner, rescue, or sweep. It publishes its liability through `assayAccrued` and is bonded in `test/assay/AssayHardcap.t.sol`.

Its own address defeats it in one place, which is the point: Hardcap takes a fee through `afterSwapReturnDelta`, so `NoSwapDeltaPredicate` **refuses to let its author bond a claim to the contrary**, whatever this README says. Zero external calls establish that.

Hardcap's earlier MEV-recapture framing has been withdrawn. It bounded hook extraction honestly; it did not recapture MEV in any sense worth claiming.

## Tests

```bash
forge test
```

Kill suites: predicate sandbox (revert / OOG / mutation / reentrancy / returndata bomb / malformed return all read INCONCLUSIVE, never VIOLATED), bond mechanics (exit race, self-slash, griefing, commit-reveal, conservation, growth attacks), runtime enforcement (drain refused, forgetful integrator, bricked-spec hook), ledger budget, flow metering, registry, and the original Hardcap envelope (Cork / cap / JIT / vault).

## License

MIT
