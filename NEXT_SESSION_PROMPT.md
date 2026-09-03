SESSION HANDOFF — QUEUE, after Phase 11 (2026-09-03)

**Read order: this file → `AGENTS.md` → `BUSINESS.md` → `PITFALLS.md` §5.175–5.182 → `PLAN.md` when
you write code.**

**This file is self-contained. You do not have the conversation that produced it and you do not need
it.**

---

## 0. START HERE — VERIFY THE TREE YOURSELF, DO NOT TRUST THIS FILE

```bash
git log --oneline -12                        # expect ~12 Phase 11 commits on top of 66a7568
git status --porcelain                       # expect CLEAN
ls .forge-snapshots/MUTATION_IN_PROGRESS     # MUST NOT EXIST
forge test                                   # GET YOUR OWN NUMBER. Expect 316 / 0 / 1 skipped.
wc -l docs/research/seat-economics/*.txt     # NO ZEROES. One of these was the empty git blob.
```

**That last line is not paranoia.** `results-book.txt` — the evidence for the result that closed the
project's last open question — was committed at **zero bytes** and stayed that way for a phase,
because `book_report.py` truncates its own output before it computes. `git status` reads CLEAN with
the headline evidence gone. Check the sizes, not the status.

**Stop your agents before you run `forge` or `mutate.py`.** A prior phase relayed a mutation result
measured against the wrong suite because the orchestrator took the toolchain while a teammate held
the tree.

---

## 1. WHAT THIS PROJECT IS, IN FIVE LINES

* **QUEUE is a Uniswap v4 hook.** It gives the LPs funding one position a **rank** and fills them in
  order, front first, instead of pro-rata.
* **Being first is bad** — the front seat absorbs adverse selection first, at the worst prices. That
  is measured, and it is the entire product.
* So QUEUE is **subordination for Uniswap liquidity**: one LP takes structurally worse fills so
  another gets structurally better ones, enforced inside `swap`.
* The application we lead with is **emissions-free liquidity incentives**: a protocol stands at the
  front with its own capital instead of printing tokens.
* **It is a transfer, not creation.** `Σ cᵢrᵢ = LP` as an identity. We say that first, not last.

**`BUSINESS.md` was fully rewritten on 2026-09-03 and is the business document.** It has the ASCII
flows, the worked dollar example, what the hook demonstrates beat by beat, and every limitation. Read
it before writing a word of pitch material. The pre-Phase-11 version is at
`archive/2026-09-03/BUSINESS-pre-phase-11.md` and is **superseded, not a second opinion**.

---

## 2. THE STATE OF THE BUILD

| | |
|---|---|
| tests | **316 passed / 0 failed / 1 skipped** |
| mutations | **85 / 85 RED, 0 survivors** — unchanged since Phase 10; `src/` was not touched in Phase 11 |
| shipped premium | `PREMIUM_BPS = 5_100` (re-derived in Phase 11 — see §3.1) |
| gas | 153,177 vs 69,970 on a plain pool = **+119%**, measured at the shipped φ |
| outstanding | the two stale research files (§4.1), the README (§4.2), broadcast (§4.3), video (§4.4) |

---

## 3. WHAT PHASE 11 DID — read this before you quote any number

Phase 11 began as two small handoff items and became an audit of the project's own instruments. Five
findings, in descending order of how much they matter.

### 3.1 Every published rate number measured a rule the contract had replaced (PITFALLS 5.178, 5.180)

`sim.py:66` defaults `PREM_WEIGHT = 'inventory'` — the premium divided over seats' post-fill
holdings. **The hook divides by contributed liquidity with the payers excluded, and has since Phase
8.** `report_shipping.py`, `report_tranche.py` and `book_report.py` never override the default.

So the feasible window `[7455, 8312]` and the shipped constant derived as its midpoint described a
mechanism the contract does not implement. **The repo already knew** — `report_depth_basis.py` says
so in its own header — and that script **had never been run**, because it only prints to stdout and
nobody redirected it.

Both basis sweeps now exist, each with a control that must be exact and is:

| regime | old window (stale) | **new window (contract's basis)** |
|---|---|---|
| BENIGN | [7455, 8312] | **[4542, 5670]** |
| NORMAL | [4114, 8921] | **[2560, 6251]** |
| TOXIC | EMPTY | **EMPTY** — seat 2 never clears the LP |

**`PREMIUM_BPS` re-derived 7,900 → 5,100.** The old value sat 2,230 bps above the top of the real
window. **The divergence was not all bad news:** the contract's real rule is materially better at
moving value backward — the back clears the LP from φ = 4,542 in BENIGN instead of 7,455.

### 3.2 The headline evidence file was empty, and 5.160 partly does not reproduce (5.177)

`results-book.txt` was the empty git blob. Regenerated: **the load-bearing falsification control
reproduces exactly** (`+4.487 pp`, t = +61.96 against `−1.277 pp`, t = −20.10 — the sign flip that
killed the two-ended book). **Three of 5.160's numbers do not:** its LP bar of "+135.9 bps" appears
nowhere (the reproducible figure is +50.2), its rows mix φ blocks, and **"−476 bps" is not
reproducible** — computed consistently it is 392, and the figure for **what we ship is 133 bps**.
5.160 is amended in place. **Do not quote 476.**

### 3.3 The flagship application is takeable by a stranger for gas (5.181, PROVEN)

`buySeat(frontSeat, 0, 0)` costs nothing, evacuates the subsidiser's capital out of the position,
drops pool depth, demotes the emptied seat to the tail — **and promotes whoever was second into the
front**, so the external LP who bought a *subordinated back seat* lands in the first-loss position.

**Not a contract defect** — a never-priced seat quoting zero is the documented bootstrap. **The
remedy is operational and belongs in the deploy script and the pitch:** price the subsidiser's seat
in the transaction that funds it, and pay rent on it. `test_4_44` asserts every link.

### 3.4 Three copies of the shipped premium had drifted apart (5.180, 5.182)

`Invariant.t.sol` and `Gas.t.sol` both hardcoded `8_500` — the first behind a comment naming the
deploy script, which held `7_900`. So the campaign that claims to run at the shipping φ never had,
and the **"+119% gas" figure we quote was measured at a φ we do not ship**. Both re-pointed;
`Hygiene.t.sol::test_7_8` now pins them by reading all three source files.

**The gas headline survived** — 153,177 against the old 152,947 — because the premium's cost is the
machinery, not the rate.

**Still open, and recorded rather than left implicit:** `test_7_8` pins the mirrors that were
*found*. A fourth `_premiumBps` override would still be unpinned. The durable fix is a single shared
source the overrides read; not done because it touches five suites' fixtures.

### 3.5 The two handoff items, closed

* **INVARIANT W (5.175, closes 5.164).** 5.164's recorded safety argument was **stale** — it assumed
  balance weighting, which was replaced. The conclusion survives for a different reason:
  `min(cursor0, cursor1) == 0`, so every fill walks from the front. Asserted in 124 tests, as
  `invariant_I10`, and with a negative control that asserts the negation.
* **The campaign is aimed at the premium (5.133, closed).** Three actions with *outcome* floors, not
  call counts: 5 premium claims cashed, 3 exact-exhaust boundary fills, 4 whole-book sweeps.
* **Found on the way (5.176):** the campaign's solvency meter omitted `premiums()`, so its reported
  "surplus" of 3.6e19 wei was entirely instrument (now 0 exactly) and every shortfall was
  understated. No mechanism defect — the asserted invariant was always exact.

---

## 4. WHAT TO DO NEXT, IN ORDER

### 4.1 Re-run the two remaining research files on the contract's premium basis

**`results-tranche.txt` and `results-exec.txt` are still on the stale basis. No per-seat number from
either is quotable.** The theses they killed still stand — those rest on identities and sign tests
that no weighting changes — but every magnitude in them does not.

**Follow the pattern that already works.** `report_shipping_basis.py` imports `report_shipping.py`
**unchanged**, sets `sim.PREM_WEIGHT = 'liquidity_excl'` at module level, wraps
`multiprocessing.Pool` to inject an initializer, and calls `main()`. Copy it for tranche and exec.

**The control is non-negotiable and it is cheap:** at φ = 0 no premium is withheld and the weight
vector is never read, so the φ = 0 column **must** be identical to the old run. If it is not, the
basis switch touched something it must not and every other number is void. Both existing basis runs
pass this exactly (`0.000e+00`).

### 4.2 Rewrite `README.md`

It is a Phase-9 correction banner bolted over a Phase-4 body, and the banner now contradicts the body
on gas, roster size, test counts and the value claim. Anyone reading past line 65 reads a different
product than the one `BUSINESS.md` describes. Known live problems, all verified:

* six instances of *"32 paid desks / 32 seats"* when the deploy script ships **five** — the banner
  itself says to fix this and it was never done;
* *"Nobody has been able to price being first… the first pool where that number exists on-chain"* —
  refuted by our own PITFALLS 5.161: the tick structure already sells distance from spot for free;
* *"QUEUE is a membership market for fill priority… the fee is paid to the members you stand in
  front of"* — **inverted**. The front pays; priority is worth negative money;
* a superseded "buy the deep tail when…" decision rule presented as the answer in the verdict table;
* pre-premium 32-seat figures (*"24 to 29 of the 32 seats lose money"*) that the shipped premium
  made false.

**`BUSINESS.md` §1–§5 is the correct content.** Rewrite the body against it or delete the body — a
banner is not a correction.

### 4.3 Broadcast to Unichain Sepolia

Funded `PRIVATE_KEY`, chain **1301**. `script/QueueDeployBase.sol` holds the sequence; `Deploy.t.sol`
and `DeployFork.t.sol` already execute it, the latter against a **live fork** (`QUEUE_FORK=true`,
off by default, skips loudly).

**Before broadcasting, apply 5.181's remedy:** the deploy sequence must `setSelfPrice` the front seat
in the same transaction that funds it, or the demo roster is takeable by anyone watching for the
price of gas — and that is a live, on-camera failure mode.

### 4.4 The video — under 5 minutes, human voice

**Frame, decided with the panel: one primitive, one flagship demonstrated live, adjacent
applications named as unbuilt.** *Not* "here is a mechanism and some ideas" — after five killed
theses that reads as *they built a thing and don't know what it's for*.

```
  30s  THE PROBLEM   protocols print tokens to rent liquidity. Dilution,
                     sell pressure, and it stops the day emissions stop.
  60s  THE MECHANISM Uniswap fills pro-rata — the only thing it does. QUEUE
                     ranks the funders. BEING FIRST IS BAD, and we measured it.
  60s  THE APPLICATION  the protocol stands at the front. Live on Unichain
                     Sepolia, on the roster the script actually deploys.
                     Say the transfer out loud.
  30s  THE NUMBER    one point the front gives up buys the back exactly half a
                     point. Σcᵢrᵢ = LP. Show the algebra, not a simulation.
  30s  THE EVIDENCE  316 tests, 85/85 mutations, four evacuation exploits found
                     against ourselves and closed. ONE LINE on the five killed
                     theses — not a section.
  30s  THE CAVEATS   all of them, said by us: it is a transfer; simulation only;
                     real capital required; +119% gas; TOXIC HAS NO WORKING
                     SETTING; the front seat is a bad investment on purpose.
```

**Keep negation under ~15% of runtime.** Judges count minutes of "what does not work", not
pre-registered criteria.

### 4.5 Optional, if time allows

* The durable fix for §3.4: one shared source for `_premiumBps`, so a fourth mirror cannot appear.
* `book_report.py` writes its output with mode `"w"` at the top of `main()`. **Write to a tempfile
  and `os.replace` on success** — this is PITFALLS 5.79's remedy, applied to `mutate.py` long ago
  and never generalised to the tools that write evidence. It is why 3.2 happened.

---

## 5. PROVEN IMPOSSIBLE — DO NOT RE-OPEN

1. **Every seat beating a passive LP.** Identity, 2.98e-14, invariant to φ.
2. **Any ordering rule creating value.** `SLACK = c₁(LP − B₁)` is independent of it.
3. **Selling priority to any buyer, constrained or not.** Priority is worth negative money to its
   holder; our shipped front seat costs 133 bps against the position it displaces. *(Direction and
   monotonicity reproduce; the old "−476 bps" does not — see §3.2.)*
4. **A two-ended book.** Execution price worse, and the advantage flips sign under mirrored drift.
5. **A senior/junior tranche.** Downdev ratio 0.0–1.6× and the tail is worse. LIFO. `sponsor()`.
   A DAO paying rent from *outside* the pool is FLOW C and is **unbuilt and unmeasured** — do not
   attach its promise to what we ship.
6. **Reducing LVR with a curve; detecting toxic flow.** `AGENTS.md` §6.
7. **Rolling the band without paying the keeper's conversion bill.** `recenter()` stays unshipped.

**A vanilla ERC-4626 vault over a ranked seat.** Any redeem of any size permanently destroys the rank
for every other depositor, nothing ever promotes a seat back, and whoever sits behind the vault is
*paid* to trigger it. Reasoned from source, not measured. The shape that works is an async-redeem
(ERC-7540) vault on the **tail** seat — see `BUSINESS.md` §11.

---

## 6. HOW TO WORK HERE — the hazards that have actually bitten

* **Read `AGENTS.md` §3's five laws of testing.** They were each paid for. LAW 1 (never 1:1, never
  equal decimals) cost a shipped feature when it was treated as optional.
* **A number that is emitted but never asserted is a number nobody checks.** 5.176 sat in plain
  sight for four phases: the docblock stated the expected value and the test printed a different one
  on every run.
* **A comment naming its source is the failure mode, not the fix** (5.180). Three copies of one
  constant drifted behind exactly such a comment. Use an interlock.
* **A research script whose output is not a committed FILE has not been run**, however finished it
  looks (5.178).
* **A conclusion that survives a dead argument is an unproven conclusion** (5.175). When a weight, a
  unit or a denominator changes, every safety argument quoting the old one is stale — and nothing
  goes red, because the code is still correct.
* **Name the fixture on every number.** Roster, φ, and premium basis. Five retractions came from
  mixing them, the fifth inside the strategy document itself.
* **Prefer the config-free form.** `back's excess = c₁(LP − r₁)/(1 − c₁)` needs no simulator and
  cannot be quoted against the wrong fixture.
* **`git stash list` before concluding work was destroyed.** An agent stashing for a clean baseline
  empties the tree transiently; use a worktree or `git show HEAD:path`.
* **A BAD-PATTERN or NO-COMPILE in the mutation campaign is an UNRUN case, never a pass.**
  `mutate.py` now preflights every pattern and exits 2 naming any that no longer matches.
* **Do not wait on the campaign with `until ! pgrep -f "script/mutate.py"`** — the waiter's own
  command line matches the pattern and it never terminates. Poll
  `.forge-snapshots/MUTATION_IN_PROGRESS` instead.
* **When a fix makes a control vacuous, re-arm it at the residual attack surface — never relax it.**
  That the control went vacuous is itself a finding.
