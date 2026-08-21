# Next session — Assay

**Status 2026-08-22.** 160 tests green. The pivot is implemented and committed (`206f60b`).
You are a new agent; there is no prior chat. Read this, then `README.md`, then
`docs/SPIKE-predicate-sandbox.md`. Do not re-derive anything in the spike doc.

---

## 0. Read this first: the submission is at risk for a non-code reason

UHI10 Gate 1 requires a **video ≤5 minutes with a human voice** before **3 Sep 2026 23:59 PST**
(Demo Day 11 Sep). The owner has said to drop the video. **Dropping a required submission artifact
disqualifies the entry regardless of how good the code is.** Confirm with the owner that they have
independently verified the video is optional this cohort. If they have not, this is the single
highest-priority item in the repo and everything below is worth less than it.

---

## 1. What we pivoted to, and why

**Was:** `HardcapHook`, framed as MEV recapture. That framing is withdrawn. It was reviewed and
found economically inverted (the block's first swap was tax-exempt, which *subsidises* the
top-of-block race), freely bypassable (a dust in-range liquidity add zeroed the claw for the whole
block, permanently, for the price of gas), and its vault was drainable by a one-block JIT position.
Three of those were written in the repo as "accepted weaknesses" or enshrined as passing tests.
Originality in that lane was ~2/5 against a field of MEV-recapture hooks.

**Is:** **Assay** — hooks that carry a machine-checked spec they cannot violate, capital staked
behind each claim, and a public record.

**Why this wins where the old thing could not.** It rests on two properties that exist only in
Uniswap v4, both verified in-repo:

1. PoolManager keeps every account's live flash-accounting delta in **transient** storage at
   `keccak256(abi.encode(account, currency))`, and `exttload` is **`external view`**. So mid-callback
   anyone can read exactly how much a hook is into the pool for — **from PoolManager's ledger, not
   the hook's own accounting.** The hook does not own that number and cannot misreport it.
2. Hook permissions are in the low 14 bits of the **address** and PoolManager enforces them, so what
   a hook is *permitted* to do is provable with zero calls, for any address, deployed or not.

The thesis that follows, and the sentence to lead every conversation with:

> **Assay does not enumerate bug classes. It bounds the damage at the ledger.** Any defect —
> authorization (Cork), arithmetic (Bunni), reentrancy, a lying oracle — whose *effect* is the hook
> extracting beyond a declared budget becomes unexecutable, whatever its cause.

This answers "name a real exploit you would have stopped" without having to predict the exploit,
which is where every enumerate-the-bug-classes tool fails.

## 2. What exists (do not rewrite)

| Contract | What it does |
|---|---|
| `AssayHook` | Declared invariants, immutable, capped at 4, in immutable slots. Fail-closed. |
| `AssayBaseHook` | Every value-capable callback implemented **without `virtual`**, so an integrator cannot omit enforcement. Subclasses implement `_assayX`. |
| `AssayFlowMeter` | Per-block extraction ceiling, measured entry-to-exit off PoolManager's ledger. |
| `PredicateSandbox` | Evaluates untrusted predicates: revert / OOG / mutation / reentrancy / bomb / malformed all read INCONCLUSIVE, never VIOLATED. |
| `HookBond` | Capital staked per assertion; commit-reveal challenges; exit gated on the spec still holding. |
| `AssayRegistry` | Stateless per-hook report + `bondBreakdown` (stake per individual claim). |
| `AssayStack` | Several untrusted hooks on one pool; guests hold no PoolManager authority. |
| `AssaySuite` | Drop-in invariant campaign for any hook repo. |
| `HardcapHook` | Reference hook. Sealed callback envelope, LP vault, no owner/rescue/sweep. |

**Measured, warm swap:** 192 gas machinery, 3,497 per balance invariant, 4,509 per ledger invariant,
5,766 flow metering. Quote these; they were measured like-for-like and an earlier bogus 23.5k figure
was an artefact of comparing a hook that transfers against one that does not.

## 3. Hard-won facts — do not rediscover

1. **No constructor gate is possible.** During construction `address(this).code` is empty, so any
   predicate that calls back into the hook reverts on the extcodesize check and reads INCONCLUSIVE.
   A constructor gate would only ever accept predicates that never inspect the hook. It is also
   unnecessary: fail-closed runtime enforcement bricks a mis-specced hook on arrival.
2. **`verifySpec()` must evaluate at the RUNTIME budget**, not the adjudication one. Otherwise a
   predicate needing 50k reports HOLDS to the registry while the 30k callback check refuses every
   swap — the registry would call a bricked hook healthy.
3. **LP exits must not fail closed on INCONCLUSIVE.** The invariant set is immutable with no
   recovery path, so a predicate that permanently stops answering would trap every LP's capital.
   VIOLATED still blocks, because a violation during withdrawal is the hook extracting from the LP
   who is leaving.
4. **Measure the entry-to-exit INCREASE in ledger debt, never the absolute.** Under
   `afterSwapReturnDelta` a hook's `take()` debt is netted to zero by the delta it returns, so a
   running total scores the second extraction of a transaction as zero; under other settlement
   patterns debt accumulates and the same total counts one extraction many times.
5. **Never let untrusted code choose how much memory you allocate.** Solidity's
   `(bool, bytes memory)` call form copies all returndata. Both `PredicateSandbox` and `AssayStack`
   use bounded assembly copies. This bug was fixed once and reintroduced in the stack — check for it
   in any new code that calls out.
6. **Sibling mixins that both override the same hook form a diamond** every integrator must
   disambiguate by hand, inviting them to resolve it by disabling the safety feature.
   `AssayFlowMeter` extends `AssayBaseHook` for this reason. Keep it a chain.
7. **`targetSelector` without `targetContract`** leaves the default fuzz target set as every contract
   deployed in `setUp`. Always call `targetContract`.
8. **Proxy upgrades are not detectable on-chain** — a contract cannot read another contract's
   storage. Codehash pinning catches metamorphic redeploy only.
9. `IHookPredicate.check(address)` selector is **`0xc23697a8`**, hardcoded in assembly and pinned by
   a test. A guessed selector silently turns every verdict into INCONCLUSIVE.

## 4. What to build next, in order

1. **Video** (see §0), if it is in fact required.
2. **Deploy scripts + a testnet deployment.** `script/DeployAssay.s.sol`: `HookBond`,
   `AssayRegistry`, the predicate library, one `AssayBaseHook` reference deployment, one bonded.
   Nothing is deployed today; a live address is worth a great deal in judging.
3. **`AssayReport` script.** Sweep `Initialize` logs (`cast logs`) for hook addresses, feed them to
   `AssayRegistry.reportMany`, print the table. The headline is the gap: N deployed hooks, X of them
   able to move a swap delta, **0 declaring a spec and 0 bonded**. That table is the argument.
4. **Two-phase challenge auction** — award the oldest valid commit rather than the first reveal.
   Closes the residual in `test_knownLimit_preCommittedSearcherCanStillRace`.
5. **A victim-claim path for `forfeited`.** Slashed capital is currently locked forever, which is
   deliberate (it must leave the author's reach) but is not compensation. Do not claim otherwise
   until this exists.
6. **More predicates**, in value order: per-block price deviation (stateful, needs a meter-style
   mixin); a Cork-class callback-authorization attestation; ERC-6909 claim-balance solvency.

## 5. Open, honestly

- **A spec can be padded with cheap claims.** Tranches price each assertion and `bondBreakdown`
  publishes them, but nothing forces real money onto the assertion that matters. Disclosure, not
  prevention. Say so.
- **A bond below the value a hook controls does not deter a rational attacker.** Unfixable. One
  plain sentence, every time.
- **Assay binds hooks that chose to bind themselves.** A malicious author simply would not inherit
  it. The guarantee is against *defects* in hooks that opted in; capital at risk and a public record
  are what make opting in credible.
- **Fail-closed can brick a pool's trading.** Stated trade-off; exits are the deliberate exception.
- **Hardcap's F1 remains unfixed by choice.** Its vault pays late depositors out of historically
  accrued surplus (`test_unagedAddThenClaimNextBlockCapturesRemainder` demonstrates it). That is a
  *fairness* property, which §3 of the spike doc establishes is not expressible as a present-state
  invariant, so it can never be a predicate. The correct response was to stop claiming it, which the
  README now does. If Hardcap is ever presented as a product again rather than a reference hook,
  fix it with accrual-index accounting first.

## 6. Mindset (paste into every sub-agent)

Brutally honest. You are not here to validate the owner or yourself. A false PASS is worse than an
honest FAIL. Over-fitting and green-number chasing are the first sin — this repo has already shipped
one bogus gas measurement and one invariant suite that passed on luck, and both were caught by
distrusting a green result, not by producing one. When a test passes on the first run, that is a
reason for suspicion, not satisfaction. When an assertion is aspirational, assert what is actually
true and say what is not.

Panel to consult on every delivered sub-task: Lead Exploit, Taint, Edge Case, Economic Incentives,
Devil's Advocate, State Transition, Symbolic, Skeptic Web3, vuln triager, bounty triager, Asymmetry
attacker, Economic Security, Execution Trace, First Principles, Periphery.

## 7. First commands

```bash
cd /Users/mishoko/projects/UHI10
forge test            # 160 pass, ~60s (invariant campaigns dominate)
forge test --match-path "test/assay/*"
```
