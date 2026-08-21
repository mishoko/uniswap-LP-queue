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

## 1.5 Scorecard — original review findings vs. what actually shipped

The 2026-08-21 review of `HardcapHook` raised eight findings. Their status now, so nobody assumes
"we pivoted" means "we fixed them":

| # | Finding | Status |
|---|---|---|
| F1 | Vault is a pot, not an accrual index: late depositors capture surplus accrued before they arrived | **Open, deliberate.** Fairness is not a present-state property, so it can never be a predicate. The response was to stop claiming it. Fix with accrual-index accounting *before* Hardcap is ever presented as a product again. |
| F2 | Dust in-range liquidity add zeroes the ToB claw for a whole block, for the price of gas | **Moot** — the claw is no longer claimed to do anything. |
| F3 | Canonical v4 `PositionManager` LPs can never call `claim`, so their surplus is stranded | **Open.** Still a real defect in the reference hook. `claimFor` is roughly half a day. |
| F4 | Shares are raw `liquidityDelta`, so tick-wide positions dominate the vault | **Moot** with F1's claim withdrawn; returns if F1 is ever fixed. |
| F5/F6 | First-swap-of-block exemption subsidises the top-of-block race; the claw taxed uninformed retail | **Resolved by withdrawal**, not by code. |
| F7 | Constructor accepted out-of-range `fee` (incl. the dynamic-fee flag) and `tickSpacing` | **Fixed.** |
| F8 | `claim` mis-accounts when `liveL < recorded`; minor gas | **Open, low value.** |

And the three ideas proposed as the way out of the MEV lane:

| Idea | Status |
|---|---|
| A — hook risk registry / permission decoding | **Shipped, better than proposed:** on-chain and stateless (`AssayRegistry`) rather than an off-chain table. The off-chain sweep that *populates* it is still missing — see §4.3. |
| B — bonded hook, permissionless slashing ("Immunefi in the hook") | **Shipped and hardened:** commit-reveal, exit gated on the spec, per-assertion tranches. |
| HookStack — capability-sandboxed multi-hook composition | **Shipped as `AssayStack`.** It was correctly refused as a *second product* in August and became viable only once extraction was bounded at the ledger. |

The largest thing in the repo — **runtime enforcement** (`AssayHook` / `AssayBaseHook`) — was in
none of those proposals. It came from the panel objection "name a real exploit you would have
stopped", which the bonding-only design could not answer. Post-hoc compensation cannot help with a
drain: by the time insolvency is provable the tokens are gone.

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

## 4. What is still missing, in order

The code is strong and **the evidence around it is thin**. Everything below is about making the work
legible to someone who will spend eight minutes on it, which is the actual scoring condition.

1. **Video** (see §0), if it is in fact required. Nothing else matters if this gates the entry.

2. **Nothing is deployed.** There is no Assay deploy script and no live address; `script/` still
   only deploys the old hook. Write `script/DeployAssay.s.sol` — `HookBond`, `AssayRegistry`, the
   predicate library, one reference `AssayBaseHook`, bonded — and deploy to a v4 testnet. "It exists
   on chain" is cheap to obtain and disproportionately convincing.

3. **The gap table does not exist, and it is the strongest single artifact available.** Sweep
   PoolManager `Initialize` logs (`cast logs`) for hook addresses, decode permission bits with zero
   calls, feed them to `AssayRegistry.reportMany`, print it. The headline writes itself: *N deployed
   hooks, X of them able to move a swap delta, **zero** declaring a spec, **zero** bonded.* That
   sentence is the argument for the whole project, it is measured rather than asserted, and it is
   perhaps a day's work.

4. **Every demo uses hooks we wrote.** `LeakyHook`, `GreedyHook`, `DrippingHook`, `PoliteSubHook` —
   all straw men, and a skeptic will say so. Wrap a **real third-party hook** (an OZ
   `uniswap-hooks` example is the obvious candidate) in `AssayBaseHook`, declare a spec for it, show
   the diff and the gas. That converts "a base contract you could inherit" into "a base contract
   that demonstrably wraps someone else's real code."

5. **We do not dogfood.** `AssaySuite` runs against one demo hook. Point it at `HardcapHook` and at
   `AssayStack` and let it attack our own work. If it finds nothing, that is a result worth
   reporting; if it finds something, better us than a judge.

6. **`describeSpec()` is not surfaced by the registry.** The report carries predicate addresses; a
   human reads sentences. Add the strings to `bondBreakdown` output — "40 ETH on *hook's outstanding
   debt to PoolManager stays within its declared budget*" is the readable form of the price signal.

7. **Two-phase challenge auction** — award the oldest valid commit rather than the first reveal.
   Closes the residual asserted in `test_knownLimit_preCommittedSearcherCanStillRace`.

8. **A victim-claim path for `forfeited`.** Slashed capital is locked forever today. That is
   deliberate — it must leave the author's reach — but it is not compensation, and must not be
   described as such until this exists.

9. **`HardcapHook` F3 (`claimFor`)**, so the reference hook is not visibly broken for LPs using the
   canonical `PositionManager`. Half a day.

10. **More predicates**, in value order: per-block price deviation (stateful, needs a meter-style
    mixin, `TickBandPredicate` is the present-state version); a Cork-class callback-authorization
    attestation; ERC-6909 claim-balance solvency.

CI now runs on push and pull request (it was `workflow_dispatch`-only, so it had never run).

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
