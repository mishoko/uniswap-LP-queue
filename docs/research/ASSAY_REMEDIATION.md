# ASSAY — REMEDIATION AND DISPOSITION

> Pass date **2026-08-26**. Role: senior smart-contract architect / delivery lead.
> Question from the owner, verbatim: *"did we decide the Assay idea is not good enough in terms of
> safety / not sound? Or is it just not considered winnable? How hard would it be to fix all the
> issues, and does it still make sense?"*
>
> Inputs: `docs/research/ASSAY_GROUND_TRUTH.md` (17 findings, 4 execution-confirmed),
> `docs/research/IDEAS_LEDGER_FOLD.md` §1.4 + EXECUTION, `CLAUDE.md` §5–§7,
> `docs/ASSAY_BUSINESS_BRIEF.md`, and direct reading of `src/assay/*`.
>
> **Re-verified in this pass, by execution, not by quotation:**
> - `forge test` → **179 passed, 1 failed**. The failure is `test/spike/CowNonSafeFork.t.sol`
>   `setUp()` missing `SEPOLIA_RPC_URL`; unrelated to Assay. Baseline is green.
> - **A-6 confirmed by source read**, not taken on the audit's word: `HookBond.bond()`
>   (`:184`) and `challenge()` call `PredicateSandbox.evaluate(predicate, hook)` from the top level of
>   an ordinary transaction. `DeltaBudgetPredicate.check()` is
>   `PoolLedger.debt(pm, hook, currency) <= maxDebt` over **transient** storage, which is zeroed
>   there. The strongest predicate in the library is unconditionally true on every bonding path.
> - **The §1.7 fix surface confirmed by source read**: `AssayBaseHook` has exactly four sealed
>   callbacks that return a hook delta — `_beforeSwap` (`BeforeSwapDelta`), `_afterSwap` (`int128`),
>   `_afterAddLiquidity` / `_afterRemoveLiquidity` (`BalanceDelta`). Each already holds the value in a
>   local variable between the integrator's code and the assertion. The fix is four insertion points.

---

## 0. THE SHORT ANSWER

The owner's question contains a false dichotomy — "unsound" vs "unwinnable" — and the honest answer is
**neither, and that is the problem.**

- The idea is **sound but smaller than the pitch**, in a specific structural way that is not in the
  audit: the half of the product you can *enforce* and the half you can *bond* cover **disjoint sets
  of claims**, and the README joins them where they do not join.
- The implementation is **not dangerous to user funds** and is above hackathon average, but it has one
  real third-party griefing vulnerability (A-1) and its **evidence is unreliable** (A-2, A-8, §1.7).
- The claims are **oversold, in four places outright false.**
- All of it is fixable in **≈85–110 engineering hours**, which is affordable inside 8 weeks.
- **And a fully fixed, fully honest Assay still scores ≈3.0 on the rubric**, because the binding
  constraint was never soundness. It is theme fit (2/5), demonstrability (2/5), adoption (2/5), and
  the absence of any prize track that rewards what it is.

**So: it was not killed for being unsound. It was killed for being un-winnable — and that verdict
survives the remediation, because remediation does not move any of the three scores that killed it.**

Recommendation, defended in §4: **PUBLISH ASSAY, SUBMIT SOMETHING ELSE, and dogfood a reduced Assay
on whatever we do submit.** That third clause is new and is the only part of the disposition that
changes as a result of this pass.

---

## 1. SOUND vs SAFE vs TRUE — the three things that keep getting conflated

### (a) Is the core idea sound? — **YES, in two halves that do not join where the pitch says they do.**

The core idea is three mechanisms. Scored separately, because they deserve separate verdicts.

**1. Fail-closed runtime predicates on present state. SOUND. This is the good part.**

The design decisions here are better than the rest of the repo and better than most audited
production code:

- **Three verdicts, not two.** `INCONCLUSIVE` is load-bearing and is routed correctly at every call
  site. Making "cannot tell" un-fakeable as "guilty" is the correct direction for a slashing
  primitive, and the `staticcall` implementation gets mutation-rejection and reentrancy-blocking from
  the EVM rather than from code that could be wrong.
- **The 63/64 gas check reverts rather than answering.** A sandbox that answered "INCONCLUSIVE"
  because it was starved would be a free off-switch. It refuses instead.
- **`verifySpec()` deliberately evaluates at the *runtime* budget, not the adjudication budget**, so
  the registry cannot certify a hook that is actually bricked. This is second-order thinking that
  most submissions never reach, and it is proven by a test.
- **The LP-exit asymmetry** (VIOLATED blocks, INCONCLUSIVE does not, on the two remove paths) is a
  genuine trade-off reasoned through from the immutability of the invariant set, not stumbled into.
- **The seal is real.** Verified: OZ `BaseHook`'s ten externals are non-`virtual`, and
  `AssayBaseHook`'s eight overrides are non-`virtual`. A subclass physically cannot omit enforcement.

The limits are narrow and — unusually — honestly stated in the source: one `staticcall`, present state
only, no history, no `msg.sender`, ≤30k gas. `CLAUDE.md` §5.10 ("fairness is not a present-state
property") was applied against the repo's own prior work rather than fudged. That is real
intellectual discipline and it should not be thrown away.

**2. Per-claim bonding. SOUND AS A COSTLY SIGNAL, and the repo says so — but structurally mis-joined.**

`CLAUDE.md` §7.1 ("a bond below the value a hook controls does not deter a rational attacker") is
stated everywhere and never hedged. Fine. That is not the problem.

The problem is **A-6, and it is worse than the audit's MEDIUM rating suggests, because it is not a
bug — it is a seam in the idea.** Bonding evaluates predicates from the top level of an ordinary
transaction. Runtime enforcement evaluates them inside a callback. **Transient storage is zero in the
first context and live in the second.** Therefore:

| | Enforceable at runtime | Bondable / slashable |
|---|---|---|
| `DeltaBudgetPredicate` (ledger) — **the strongest claim in the library** | ✅ yes, with teeth | ❌ **never**. Unconditionally true. Un-slashable, never blocks an exit. |
| `BalanceFloorPredicate`, `SolvencyPredicate`, `CodehashPredicate` (persistent state) | ✅ yes | ✅ yes |
| `NoSwapDeltaPredicate`, `PermissionMatchPredicate` (address bits) | ✅ yes (trivially) | ✅ yes, but they can never change, so they can never be slashed either |

I confirmed this in source, not from the audit. The consequence: **the set of claims you can enforce
and the set of claims you can put money behind overlap only on the weak ones.** The README's own
worked example of the price signal — *"40 ETH on never exceeding its budget"* — is precisely the
number that can never be lost. Not a lie the authors told; a seam nobody noticed.

This is fixable (tag predicates bondable vs runtime-only, refuse the latter in `bond()`, rewrite the
example) but **the fix shrinks the product**. After it, the honest sentence is: *"you can enforce a
ledger bound but not bond it; you can bond a balance floor but the hook self-reports the number it is
floored against."* That is materially less than "a machine-checked spec, with money behind it."

**3. The public registry. SOUND AS A CONCEPT, broken as built.** A-3 (256-entry scan window,
permissionless append-only list ⇒ a hook's `bondedWei` is permanently zeroable for the price of gas)
and A-4 (unbounded returndata copy in all three probes, 78× measured blow-up). Both are ordinary
engineering bugs in a design that is otherwise fine. Not idea-level.

**Verdict (a): the idea is sound. It is also ~30% smaller than the pitch, and the shortfall is
structural (the enforce/bond seam), not cosmetic.**

### (b) Is the current implementation safe? — **YES for funds. NO for one component's liveness. NO for its own evidence.**

Precision matters here, because "17 findings" reads worse than it is.

**No third-party fund loss was found, by an auditor who was actively hunting.** `HookBond` is the only
contract holding value and it survived: `nonReentrant` on every state-changing external, correct CEI
in `challenge()` (`st[index]` zeroed and `b.amount` decremented before `_send`), no `bondId`
collision, `uint96` truncation unreachable below ~7.9e10 ETH, no sandbox escape (the EVM enforces
`staticcall`). The audit's own "checked and NOT a problem" list is longer than most hackathon repos'
findings list.

**One real vulnerability against third parties: A-1.** A twelve-line `AssayStack` guest calling
`poolManager.take(currency, self, 1)` inside its 150k stipend makes **every swap on that pool revert
forever**, because the guest list is immutable, there is no admin and no removal path. The victim is
other people's liquidity. That is a genuine HIGH and it deserves it. Note where it came from: it is
the first hostile contract written by someone who did not write the defence, and it broke a headline
guarantee on the first attempt.

**Everything else that touches money is self-inflicted or a griefing nuisance:** A-7 (a fully-slashed
bond is a permanent tombstone — the author DoSes their own future bonding), A-12 (`_send` push-payment
bricks the author's own withdrawal if they cannot receive ETH), A-9 (an author with a genuinely broken
spec self-slashes the smallest tranche for 0.0009 ETH and frees the rest — a real economic escape
hatch, and the README's "blocks withdrawal permanently" is false for a multi-tranche bond), A-14
(free unbounded commitment state growth on an admin-less contract).

**The category that actually matters, and it is not a security category: the evidence is unreliable.**

- **A-2.** The flagship `AssaySuite` campaign — 256 runs × 128,000 calls, 46 seconds of every CI run —
  asserts four things that are **structurally incapable of failing**, because it evaluates a transient
  predicate from the invariant runner where transient storage is zero. This is `CLAUDE.md` §5.7's own
  warning, shipped.
- **A-8.** The 13-test sandbox kill-suite does not import `src/`. It re-declares the library and tests
  its own copy. The shipped `PredicateSandbox` — the strongest contract in the repo — has **zero
  adversarial coverage**, including the parameterised overload that only exists in `src/`.
- **§1.7.** A hook using the most ordinary v4 fee pattern extracts 4.7 × 10¹⁷ times its declared
  ceiling and every meter reads zero.
- **Seven `HookBond` test names claim more than they assert**, and all 33 bond tests run against a
  mapping-plus-a-setter with no PoolManager deployed.

**Verdict (b): the implementation is safe to hold money and unsafe to believe.** One component
(`AssayStack`) should be deleted or fixed before it is shown to anyone. The rest is above average code
with below average proof.

### (c) Are the marketing claims true? — **NO. Four are false, several more are unscoped.**

| README headline | Status |
|---|---|
| *"a ceiling the hook cannot exceed no matter what bug it contains"* | **FALSE.** §1.7, execution-confirmed. |
| *"hooks that carry a machine-checked spec they cannot violate"* | **FALSE AS WRITTEN.** True of the eight v4 callbacks only. Any other external the subclass declares is unguarded (A-10). |
| *"one broken guest must not brick a pool"* / *"guests never touch PoolManager"* | **FALSE.** A-1, PoC-confirmed. The second is a convention; `_dispatchOne` uses `call`, not `staticcall`. |
| *"no hook can be listed inaccurately, omitted, or squatted"* | **FALSE.** A-3. |
| *"invariants are evaluated at construction and must HOLD"* (`AssayHook.sol:24, :51-52`) | **FICTION.** The constructor only bounds the count. The repo's own test deploys a hook whose spec is already VIOLATED. Two of the four stated bricking mitigations do not exist. |
| `DeltaBudgetPredicate` NatSpec: *"the outstanding debt is precisely what the hook has physically removed"* | **FALSE.** It is what the hook removed *through the take/mint channel*. |
| Gas table (192 / 3,497 / 4,509 / 5,766) | **2 of 4 stale.** Re-measured 170 and 4,631. Also measured on the mixin path, not the sealed path an actual integrator pays for. |
| *"AssaySuite spends the campaign trying to make your declared spec false"* | **UNSUPPORTED as shipped.** A-2. |
| *"sandbox: revert/OOG/mutation/reentrancy/bomb all read INCONCLUSIVE"* | **TRUE OF A COPY, unproven for the shipped file.** A-8. |

Against that, the things that are **true and good and should be kept in any pitch**: the seal is real
and proven (`test_enforcementSurvivesAnIntegratorWhoNeverCallsIt`); the sandbox logic is correct on
review; `verifySpec()` at the runtime budget; the LP-exit carve-out; `test_hardcapCannotBondAClaimIts
AddressContradicts` (the repo refuses to let its own author bond a false claim — the single best demo
in the tree); and the consistent refusal to claim fairness is expressible.

### Which of the three is the real problem?

**The owner's working hypothesis is correct — idea sound, implementation fixable, claims oversold —
and it is answering the wrong question.**

All three are cheap relative to eight weeks. The blocker is a fourth thing none of the three names:

> Assay's rubric ceiling is set by **theme fit 2/5, demonstrability 2/5, adoption 2/5**, and none of
> those three moves when you fix a finding. Demonstrability moves when you *deploy and wrap a real
> third-party hook*, which is 30+ hours with a real chance of no result. Theme fit does not move at
> all — Assay is about hook trustworthiness, which is a different problem from MEV and LP
> sustainability, and the repo is honest enough to say so.

Fixing all 17 findings produces a **sound, safe, truthfully-described project that still loses.**
That is the answer to the owner's question, and it is why "not sound" and "not winnable" were never
the right alternatives.

---

## 2. THE CRUX — what survives §1.7 as genuinely v4-specific and genuinely novel

### 2.1 The fix is real and it is cheap. Confirmed in source.

`AssayBaseHook` already holds every returned hook delta in a local variable between the integrator's
code and the assertion. Four insertion points, verified by reading the file:

```solidity
function _afterSwap(...) internal override returns (bytes4, int128) {
    uint256 mark = _assayEnter();
    (bytes4 s, int128 d) = _assayAfterSwap(sender, key, params, delta, hookData);
    _assertReturnedDelta(d);        // <-- NEW. `d > 0` is value the hook is about to receive.
    _assertInvariants();
    _assayExit(mark);
    return (s, d);
}
```

Same shape for `_beforeSwap` (`BeforeSwapDelta`, two packed `int128`s), `_afterAddLiquidity` and
`_afterRemoveLiquidity` (`BalanceDelta`, two packed `int128`s). **One caveat that raises the cost
slightly and that the fold analysis did not state:** a per-callback bound is defeated by repetition
inside one transaction — the exact D-2 defect it is replacing. To close the channel properly the
returned delta must be **charged to the cumulative per-block `AssayFlowMeter`**, not merely
range-checked. That is still plain arithmetic on a number the hook hands over anyway, and it is
cheaper than the `tload` it replaces.

### 2.2 What is left, enumerated honestly

| # | Claimed novelty | v4-specific? | Genuinely novel? | Survives §1.7? |
|---|---|---|---|---|
| N1 | Reading a hook's own live flash-accounting delta from PoolManager's **transient** storage via `exttload`, mid-callback, from outside | **Yes, uniquely** | **Yes** — `transient storage\|flash accounting\|exttload\|tload` = 1 hit in 662 prior submissions, and that hit is unrelated | **Yes, but demoted** — see below |
| N2 | Permissions provable from the low 14 address bits, zero calls, works on an undeployed address | Yes | **No, as a fact** — every hook deployer CREATE2-mines for these bits and `Hooks.hasPermission` ships in v4-periphery. **Partly, as a move** — using it as a *bondable negative attestation* is new | Yes, untouched |
| N3 | Non-`virtual` sealed callbacks so enforcement cannot be omitted | **No** — any base contract in any language can do this | No. A Solidity idiom, applied well | Yes, untouched |
| N4 | `PredicateSandbox` INCONCLUSIVE-never-VIOLATED | No, entirely chain-generic | Good engineering, not a discovery | Yes, untouched |
| N5 | Per-claim bonding with commit-reveal challenges | No | No — TCRs, bonded oracles, Immunefi-style escrow are well-trodden | Yes, but see the A-6 seam |
| N6 | Per-block extraction ceiling metered off PoolManager's ledger | Yes | Derivative of N1 | Yes, demoted with N1 |

### 2.3 The demotion, stated without softening

Before §1.7, the pitch was: *"v4 gives us a number the hook does not own and cannot misreport, and we
bound extraction with it."*

After §1.7, the true sentence is: **a v4 hook can extract through at least three channels, and the
v4-only superpower covers exactly one of them.**

1. **take / mint against PoolManager.** Creates debt. Visible on PoolManager's own ledger. **This is
   N1's channel, and nothing but N1 can see it** — the hook's own accounting is a self-report, and
   arithmetic on the returned delta is blind to a `take` that is never mentioned in a return value.
   N1 is genuinely irreplaceable here.
2. **the returned hook delta.** Applied by PoolManager *after* the callback returns, so the ledger is
   structurally blind (measured: the signed delta at the instant `_assertInvariants()` runs is `0`,
   not merely non-negative). Closed by **addition on a number the hook already holds.** Needs no
   transient storage, no `exttload`, none of the v4-only properties.
3. **any non-callback external the subclass declares** (A-10) — `harvest()`, `sweep()`, `collectFees()`.
   Neither meter runs. **Inheritance cannot close this**, because the sealing trick only works on
   functions the base class declares. The best available fix is an opt-in `assayGuarded` modifier,
   which is exactly the "trust the integrator to remember one line" failure mode `AssayBaseHook`
   exists to eliminate. Note that the §1.7 exploit *used* this channel to sweep, and note that
   `HardcapHook` — our own reference hook — ships such a function (`claim()`).

So the honest headline after full remediation is:

> *"Extraction inside the eight v4 callbacks is bounded: one channel by a number PoolManager owns and
> the hook cannot misreport, one by arithmetic. Extraction through any other function the hook
> declares is not bounded at all, and inheritance cannot bound it."*

That is a **true** sentence and it is a considerably weaker product than the README's.

### 2.4 Is the remaining novelty enough to carry a submission? — **No.**

Three reasons, in descending force:

1. **The novelty was never the binding constraint.** The auditor scored novelty **4/5** *before*
   §1.7 was even known. Even leaving it at 4/5, the rubric is 30 Original + 25 Unique Execution +
   20 Impact + 15 Functionality + 10 Presentation. Impact for a security base class with zero
   deployments, zero third-party adopters and zero readers of its registry is a 2, and Unique
   Execution is capped by the fact that every demo runs against straw men we wrote to be caught.
   4 · 0.30 + 3.5 · 0.25 + 2 · 0.20 + 4 · 0.15 + 4 · 0.10 ≈ **3.3**, and that is with generous
   Functionality and Presentation. The shortlist sits at 3.95–4.10.

2. **The off-theme escape hatch does not fit this shape.** The Uniswap Prize is not theme-gated —
   UHI9's went to Orbital, an off-theme stableswap curve. But Orbital won on being **a genuinely new
   AMM primitive**, a new tradeable object (`WINNERS_LANDSCAPE` P5). Assay creates no tradeable
   object; it creates an attestation nobody has asked for. "Good infrastructure" is not the thing
   that has historically taken the off-theme prize, and there is **no security or tooling track** —
   all 13 prize values are Uniswap, General, Unichain, and ten sponsor names.

3. **The scope caveat eats the headline in the first thirty seconds of judging.** "A hook that cannot
   violate its spec" → *"inside eight callbacks; not in any other function it declares; and only for
   present-state properties, so not fairness, not history, not sandwiches."* That is a fair
   description and it is not a winning one.

**Does Assay reduce to "a well-built base contract with bonding"?** Close, but be precise, because
the precise version is the one that determines what we do with it: it reduces to **a well-built base
contract, plus one real v4-only meter that no one else in nine cohorts has built, covering one of
three extraction channels, plus a bonding rail whose slashable claims are disjoint from the meter's.**
The v4-only meter is the part worth keeping. Everything else is competent, generic, and replaceable.

---

## 3. REMEDIATION PLAN, COSTED

**Assumptions, stated so the numbers can be argued with:** one senior Solidity engineer plus this
orchestrator, **25 productive engineering hours per week**, 8 calendar weeks to 2026-11-03 ⇒ a
**~200-hour budget**, from which the actual submission must also be built. Hours include tests and a
negative control per fix (mandatory per the 2026-08-26 method note: *no agent that skipped a negative
control produced a trustworthy number*). Hours exclude re-audit by a second party.

### 3.1 Every finding

| # | Sev | Fix | Hrs | Kind |
|---|---|---|---|---|
| **§1.7** | **HIGH** (falsifies the headline) | Charge the returned hook delta to the cumulative per-block meter at all four delta-returning sealed callbacks; move `test/spike/AssayReturnDeltaBlindSpot.t.sol` into `test/assay/` as a regression, add a control per callback | **16** | **CODE** |
| A-1 | HIGH | `AssayStack` guest dispatch via an external self-call so a guest's revert unwinds its PoolManager state, + snapshot `NonzeroDeltaCount` around each dispatch and skip-and-revert the guest's turn if it moved. **Or delete `AssayStack` (0h) — see §3.4** | **10** | CODE |
| A-2 | HIGH (method) | Give the demo hook a `BalanceFloorPredicate` (persistent state) alongside the budget predicate; add a handler action performing a multi-callback swap; **verify by mutation that each invariant can go red** | 6 | TEST |
| A-3 | MED-HIGH | Paginate `bondsOfHook(offset, limit)`; non-refundable listing fee on first bond per (hook, author) | 5 | CODE |
| A-4 | MED | Bounded assembly returndata copy in all three registry probes (the `PredicateSandbox` pattern) | 4 | CODE |
| A-5 | MED | Fail closed on `afterRemoveLiquidity` when the hook address carries `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG` — readable with zero calls, so it costs nothing when it does not apply | 3 | CODE |
| A-6 | MED | Tag predicates `bondable` vs `runtime-only`; `bond()`/`addPredicate()` reject runtime-only; rewrite the README's worked price-signal example, which currently uses the un-slashable one | 4 | CODE + CLAIM |
| A-7 | MED | Clear `bonds[id]` / `_predicates` / `_stakes` when the last live tranche is slashed; move `everSlashed` to a separate permanent mapping | 3 | CODE |
| A-8 | MED | Delete the local re-declarations, import `src/assay/`, move the file into `test/assay/`, re-run the full 13-test battery against the **parameterised** overload at the 30k runtime budget | 5 | TEST |
| A-9 | MED (econ) | Partially fixable only. Enforce a minimum tranche as a fraction of total bond, and block `withdraw()` for N days after any slash. Retract D-6 ("blocks withdrawal permanently" is false for multi-tranche) | 4 | CODE + CLAIM |
| A-10 | MED | **UNFIXABLE BY INHERITANCE.** Ship an `assayGuarded` modifier for integrator-authored externals so an omission is at least visible, and state the scope in the README as a first-class limitation | 3 | **PARTIAL + CLAIM** |
| A-11 | MED | Store up to 4 `(currency, limit)` pairs as immutables, exactly as `AssayHook` already does for invariants; meter each in `_assayEnter`/`_assayExit`. Also state the per-hook-not-per-pool allowance | 6 | CODE |
| A-12 | LOW-MED | Pull payment (`credits[to] += amount`) for both `withdraw()` and `challenge()` payouts | 4 | CODE |
| A-13 | LOW-MED | Bound / gas-cap the `describeSpec()` call-out | 2 | CODE |
| A-14 | LOW | Require `CHALLENGER_STAKE` at **commit** time rather than reveal; prices the state growth and makes a blanket pre-commit genuinely speculative. Retract D-8 | 4 | CODE + CLAIM |
| A-15 | LOW | None needed — deliberate and accurately documented. Keep never describing it as compensation | 0 | — |
| A-16 | LOW | Add the post-EIP-6780 residual: the metamorphic vector is largely dead, the proxy vector is the one that matters and is invisible | 1 | CLAIM |
| A-17 / D-1 | INFO | Delete the constructor-gate NatSpec fiction at `AssayHook.sol:24` and `:51-52`; two of the four stated bricking mitigations do not exist | 1 | CLAIM |
| D-2 | — | Rewrite `DeltaBudgetPredicate`'s NatSpec: it bounds the **take/mint channel**, not "what the hook has physically removed" | 1 | CLAIM |
| D-3 | — | Re-measure the gas table **on the sealed `AssayBaseHook` path**, at 1 and 4 invariants, and publish the ~50,476-gas retention floor that determines whether a 4-invariant spec bricks a hook | 3 | TEST + CLAIM |
| D-4, D-5, D-7 | — | README "Tests" section, README §Composition, `PredicateSandbox.sol:45` provenance | 2 | CLAIM |
| | | **TOTAL** | **87** | |

Add **~15h** for regression, re-running the full suite under mutation, and a second-party re-audit of
the four HIGH/MED-HIGH fixes (standing order: whoever writes the defence does not write the attacker).
**Realistic engineering floor: ≈100 hours = 4 weeks of the 8.**

### 3.2 The three missing evidence items, costed separately

| Item | Hrs | Risk |
|---|---|---|
| **Deploy it.** Deploy script, CREATE2-mine the permission bits, deploy `HookBond` + `AssayRegistry` + one specced hook to Sepolia or Unichain Sepolia, verify, initialise a live pool, post a real bond | 8 | Low |
| **Wrap one real third-party hook.** Find a deployed v4 hook with public source, fork it to inherit `AssayBaseHook`, give it a genuine spec, demonstrate enforcement against its real behaviour on a fork | **25** | **HIGH — may produce no result.** The hook may not fit the eight-callback model, may depend on its own periphery, or may have no meaningful present-state invariant to declare. This is the item that would move Demonstrability, and it is the one that can fail. |
| **The permission census.** Sweep every `Initialize` log from PoolManager on mainnet + Unichain + Base, decode the low 14 bits with zero calls, publish *"N deployed hooks, X able to move a swap delta, zero declaring a spec, zero bonded"* | 10 | Low. **True regardless of what we submit.** |

### 3.3 The three scoped options

#### OPTION A — MINIMUM HONEST · **≈55 hours (2.2 weeks)**

Retract every false claim; fix only what a third party can exploit against someone else, plus the
evidence defects, because shipping false evidence is the single thing we most need not to do.

- §1.7 (16) · A-1 (10) · A-2 (6) · A-3 (5) · A-4 (4) · A-14 (4) · all claim retractions + gas
  re-measure (10) = **55h**.
- Everything else — A-5, A-6, A-7, A-9, A-11, A-12, A-13 — is documented as a known limitation and
  **left in the code**, because each is either self-inflicted by the hook author or a disclosure gap.

**What the product becomes:** an honest, narrow library. *"A base contract that makes a hook's
declared present-state invariants unbypassable inside its eight v4 callbacks; a bond that prices
claims about persistent state; a registry. Scope: not other externals, not history, not fairness, and
the claims you can enforce are not the claims you can bond."* Useful. Publishable. **Not a
submission** — the true version of the pitch has three caveats in the first paragraph.

#### OPTION B — FULL FIX · **≈145 hours (5.8 weeks), and it ends at ≈3.0**

- All 17 findings + §1.7 + regression + re-audit: **100h**
- Deploy (8) + wrap a real third-party hook (25) + permission census (10): **43h**
- README rewrite, pitch, video: **~15h** — but that overlaps the submission's own presentation time.

**≈145h of a 200h budget, leaving ~2 weeks for everything else.** In practice this means **Assay is
the submission**, because there is no room for a second product. And at the end you hold: theme fit
still 2/5, novelty 4/5, technical depth risen to 4/5, demonstrability risen to 3/5 *only if the
third-party wrap succeeds*, adoption still 2/5. Weighted ≈ **3.0–3.3** against a shortlist of
3.95–4.10.

**This option is a deliberate bet that a 3.2 off-theme infrastructure project takes the Uniswap
Prize the way Orbital did. Orbital was a new AMM curve. This is a base class. I would not take that
bet.**

#### OPTION C — REFRAME SMALL · **≈75 hours, and it is not a submission — it is a feature of one**

Drop the platform. Keep only what makes the sentence *"this hook carries a spec it cannot violate,
and it is bonded, and it is deployed"* true.

- **Delete** `AssayStack` (kills A-1, 10h saved), `AssayRegistry` (kills A-3, A-4, most of A-13),
  `AssaySuite` (kills A-2). **2h of deletion removes three of the four worst findings.**
- **Keep** `AssayHook` + `AssayBaseHook` + `PredicateSandbox` + `PoolLedger` + `AssayFlowMeter` +
  `DeltaBudgetPredicate` + `BalanceFloorPredicate` + `HookBond`.
- Fix: §1.7 (16) · A-5 (3) · A-6 (4) · A-7 (3) · A-8 (5) · A-11 (6) · A-12 (4) · A-14 (4) ·
  docs (8) = **53h**
- Deploy (8) + permission census (10) + integrate into whatever we actually ship (~10, see §5) =
  **28h**, of which the census is independently worth doing.
- **Total ≈75h**, and **~20h of that is the part that touches the submission.**

**What it is:** the minimum viable version is *one real hook — SWITCHBACK, SLUICE, whatever we
choose — that inherits `AssayBaseHook`, declares two invariants about its own escrow, is metered, is
bonded on-chain for a real amount, and is deployed.* Plus the census published alongside as a
standalone artifact.

**This option makes the actual submission's credibility claim true, costs a fifth of Option B, and
does not consume the one submission.** It is the option I recommend, and §5 tests whether the
integration is load-bearing or decoration.

---

## 4. DOES IT STILL MAKE SENSE? — **PUBLISH ASSAY, SUBMIT SOMETHING ELSE, DOGFOOD A REDUCED ASSAY ON IT.**

### The recommendation

1. **DO NOT SUBMIT ASSAY.** Unchanged from the 2026-08-26 phase close, and this pass strengthens
   rather than weakens the verdict — because the remediation is cheap, which means "we couldn't fix
   it" was never the reason and can no longer be mistaken for it.
2. **DO PUBLISH.** Option A or C's cleanup, plus the two findings that are worth more than the code:
   the **ERC-6909 delta-laundering rail** (1 project in 662 has ever noticed it) and the **permission
   census**. Both are true regardless of what we submit, both are grant- and standard-shaped, and
   neither consumes the one submission.
3. **DO DOGFOOD.** Spend ~20h making the submitted hook an `AssayBaseHook` with a real bonded spec.
   Conditional — see §5's delete test and the condition below.

### Defending it against the rubric, which is the only thing that decides

- **30% Original.** Assay scores well here (4/5) and this is its best category. It is not enough on
  its own, and §1.7 demotes the strongest sentence in the pitch from "a ceiling no bug can exceed" to
  "one of three channels."
- **25% Unique Execution.** Capped by self-refereed evidence. **Every demo runs against straw men we
  wrote to be caught**, and the one hostile contract written by someone who did not write the defence
  broke a headline guarantee in twelve lines on the first attempt. A judge who probes finds what the
  auditor found. Moving this requires the 25h third-party wrap, which can return nothing.
- **20% Impact.** The weakest and the most honest. Zero deployments, zero adopters, zero readers of
  the registry, and the adoption ask is brutal: *bet your pool's liveness on a 30k-gas staticcall you
  can never change, forever, in exchange for a reputational signal nobody currently reads.*
- **15% Functionality / 10% Presentation.** Fine either way. The seal demo and the
  `NoSwapDeltaPredicate`-refuses-its-own-author demo are both excellent and take thirty seconds.
- **Prize surface.** There is **no security/tooling/DX track**. The 13 prize values are Uniswap,
  General, Unichain, and ten sponsor names. Assay integrates no sponsor. Its realistic shots are the
  General Prize and Unichain's "best innovation of any kind" — the two smallest doors.
- **The Orbital precedent cuts the wrong way.** Yes, the Uniswap Prize is not theme-gated. Orbital
  won off-theme on being a **genuinely new AMM primitive**. The historical pattern (P5) is *winners
  create a new tradeable object.* Assay creates an attestation. Off-theme *infrastructure* has not
  taken the top prize; off-theme *new math* has.
- **7 of 12 UHI9 winners matched the cohort theme.** Assay is theme fit 2/5 and the repo knows it —
  Hardcap's MEV framing was withdrawn rather than defended, which was the right call and is also the
  admission.

### Steelmanning "submit it anyway", and why it loses

The strongest version: *"Nobody in nine cohorts has used flash accounting as a sensor. That is a
verifiable first. 30% of the rubric is originality. A 4/5 there plus a clean deploy plus the census
headline — 'N deployed hooks, zero declaring a spec, zero bonded' — is a real pitch."*

It loses on arithmetic. A 4/5 on 30% buys 1.2. The three 2/5s on 20% + the demonstrability drag cost
more than that, and the shortlist is not sitting at 3.0 waiting to be caught — it is at 3.95–4.10
with **executed evidence** behind it (SLUICE: real `GPv2Settlement.settle()` on a fork, mutation-tested.
HASTE: LVR reproduced to 0.1–0.7%, sign error caught by a closed-form cross-check. SWITCHBACK:
router-clean, no external dependency). We would be trading a 4.0 with proof for a 3.2 with caveats.

### The condition on dogfooding — say it plainly

**Dogfood only if §1.7 is actually fixed first.** A submitted hook that advertises "carries a spec it
cannot violate" while shipping the return-delta blind spot is **worse than not dogfooding at all** —
it hands a technical judge the exact thread that unravels our credibility, and `CLAUDE.md` §7 is
explicit that hiding a known weakness is the fastest way to lose one. 16 hours buys the right to say
the sentence. Without them, delete the claim.

---

## 5. THE LEGO BLOCKS — does the bond + meter improve HASTE or SLUICE?

**Straight answer: NO for both, and for two different reasons. Both fail the delete test.**

The ledger theorem says the meter is sound against exactly three classes of account: (a) itself,
(b) an account whose debt the hook itself caused, (c) an account that agreed in advance to be
inspected at a named address and posted something it loses by walking. HASTE's filler *looks* like
case (c). That is the trap, and it is worth walking through carefully, because "we already built a
bond and they have a privileged actor" is exactly the shape of reasoning that produced Hardcap.

### HASTE's filler — **DECORATION. Killed by HASTE's own adopted fix.**

Construct the strongest version first. Cranking is permissioned to registered fillers who post a
`HookBond`. A filler nominates its address, so case (c) genuinely holds. At the crank callback the
hook reads the filler's transient delta. The searcher-filler attack (§4b) is
front-run → crank → back-run **bundled in one transaction**, which is what makes the fill block
certain — and because it is one transaction, the front-run leg's debt **is live in the filler's
ledger entry at the crank callback.** So the meter genuinely detects "the filler arrived at my own
crank carrying a position in this pool's currencies", oracle-free, in-transaction, non-self-reported,
and slashes the bond. Address-shopping does not help, because an unregistered address cannot crank.

That is a real mechanism. It is also **already dead**, because HASTE's adopted fix for the same hole
is **settle matured orders at the block-open price** — which means front-running your own crank
**cannot move the fill**. The sandwich is worthless whether or not anybody detects it. And the
block-open tick is state SWITCHBACK maintains anyway (§4c), so it is free.

**Delete test: remove the bond + meter and HASTE is unchanged.** Decoration.

The residual, stated fairly: a bond could secure filler **liveness** ("crank matured orders or be
slashed"). But liveness is **historical** — "did you crank block N" — and per §2.4 / `CLAUDE.md` §5.10
that is not expressible as an `IHookPredicate`. It would need a bespoke challenge-with-proof
mechanism sharing nothing with `HookBond` except the escrow-and-commit-reveal plumbing. **Reuse value
≈ 6–10h of saved plumbing, zero mechanism value.** Take the plumbing if we build filler bonding;
do not call it an Assay integration.

### SLUICE's solver — **NOT DECORATION, INAPPLICABLE. It cannot be built.**

Two independent blockers, either one sufficient:

1. **The settlement is out of band.** `GPv2Settlement.settle()` executes in a **different
   transaction** from any v4 callback. It calls our EIP-1271 `isValidSignature` /
   `getTradeableOrder()`, but there is no PoolManager unlock and therefore **no transient delta to
   read.** The meter has nothing to look at. This is a fact about where the code runs, not a
   judgement call.
2. **Requiring registration would damage the mechanism it is attached to.** SLUICE's entire value is
   *the surplus solvers compete away* — the audit's own delete test says that number "cannot be
   manufactured in-house." Solvers are bonded to CoW, not to us; we do not know the winner's address
   in advance. Making them register with our hook **shrinks the solver set and therefore shrinks the
   surplus.** The integration would make SLUICE worse.

The watch-tower/cranker in SLUICE is permissionless by design and its failure mode is again
liveness — same non-expressibility as HASTE's.

### Where the meter genuinely would not be decoration

For completeness, so this is not read as "the component is worthless": the non-decorative shape is a
hook running an **in-transaction auction whose winner executes inside the same unlock and must hand
back a bounded amount** — a designated backrunner / LVR-auction winner. There, the winner registers,
posts a bond, executes at a moment we control, inside our unlock, at an address they nominated. Case
(c) holds *and* the reading bounds the thing that matters, and it replaces the off-chain AVS that
every LVR project in the hook directory needed. **GRAZE has roughly that shape. HASTE and SLUICE do
not.** If GRAZE ever comes off the bench, revisit this in one hour, not five.

### The one integration that IS load-bearing, and it is case (a), not case (c)

**Point the meter at ourselves.** Whatever we submit will hold escrowed value — SWITCHBACK escrows
the retracement fee for next-block donation; SLUICE escrows the swapper's input while the CoW order
is live. A hook that declares *"my un-settled debt to PoolManager never exceeds X"* and
*"`balanceOf(me) ≥ what I owe depositors"*, enforced fail-closed on every callback, **bonded on-chain
for a real amount, deployed**, is case (a) of the theorem — the case where the measurement and the
thing measured are the same object, which is the only reason Assay ever worked.

Apply the delete test honestly: **delete it and the mechanism still runs.** By the strict test, that
is decoration. But the strict test is about mechanisms, and this is not claiming to be one — it is a
credibility claim, and it is scored under Unique Execution (25%) and Presentation (10%), where
"we bonded 1 ETH that we lose if our own escrow ever exceeds its declared ceiling, here is the
address" is worth more than another feature. **~20 hours, conditional on §1.7 being fixed first.**

---

## 6. WHAT I WOULD DO, IN ORDER

1. **Now, 2h.** Delete `AssayStack`, `AssayRegistry`, `AssaySuite` from the shipping surface. Three of
   the four worst findings (A-1, A-2, A-3, A-4) go with them, and none is load-bearing for the
   sentence we actually want to say.
2. **Now, 12h.** Retract every false claim in the README and in NatSpec — §1.7, A-10's scope, D-1's
   constructor fiction, D-2, D-6, D-7, D-8 — and re-measure the gas table on the sealed path. This is
   the cheapest credibility purchase available and it is true under every branch.
3. **Week 1–2, 16h.** Fix §1.7 properly: charge the returned hook delta to the cumulative per-block
   meter at all four delta-returning callbacks. Promote the existing attacker test out of
   `test/spike/`. This is the fix that buys back the headline, in weakened but true form.
4. **Week 1–2, 10h, in parallel.** Build the permission census. True regardless of the submission,
   writes its own headline, does not consume the submission.
5. **Weeks 2–7.** Build **SWITCHBACK** (per the standing recommendation — unconditional on the
   deadline, and it is the substrate HASTE needs anyway). Inherit `AssayBaseHook`. Declare two real
   invariants about its own escrow. Bond them for a real amount. Deploy. **~20h of Assay-side work
   inside the submission's own build.**
6. **Publish** the ERC-6909 delta-laundering finding and the census as standalone artifacts.

**Total Assay spend: ~60h across 8 weeks, none of it competing with the submission's critical path,
and it makes the submission's credibility claim true rather than aspirational.**

---

## 7. ONE-LINE ANSWERS TO THE OWNER'S ACTUAL QUESTIONS

- *"Did we decide the Assay idea is not good enough in terms of safety / not sound?"* — **No. The idea
  is sound, the code is safe to hold money, and the one third-party vulnerability (A-1) is in a
  component we should delete anyway.**
- *"Or is it just not considered winnable?"* — **Yes. That is the reason, and this pass confirms it
  rather than softening it: the fixes are cheap, so 'we couldn't fix it' was never the reason.**
- *"How hard would it be to fix all the issues?"* — **≈100 engineering hours for all 17 findings plus
  §1.7. ≈145h including the three missing evidence items. ≈55h for a minimum honest version. ≈75h to
  reduce it to a component. All affordable inside 8 weeks; only Option B eats the submission.**
- *"Does it still make sense?"* — **Yes, as a published artifact and as ~20 hours of the submitted
  hook's credibility. No, as the one submission — a fully fixed, fully honest Assay still scores
  ≈3.0–3.3 against a shortlist at 3.95–4.10, and remediation moves none of the three scores that
  killed it.**

---

*Pass performed 2026-08-26. `forge test` re-run (179 pass / 1 unrelated env failure), A-6 and the
§1.7 fix surface re-verified against source rather than quoted from the audit. Hour estimates are the
author's, at 25 productive hours/week, and include tests with a negative control per fix.*
