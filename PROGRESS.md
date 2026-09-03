# PROGRESS.md — the project's memory

**Update this at the end of every working session. This file, `PLAN.md` and `AGENTS.md` are the
handoff. If those three do not tell the next person what to do, the handoff failed.**

Newest entry first. Never delete an entry — supersede it.

---

## Status board

| Phase | Name | Status | Proven? |
|---|---|---|---|
| 0 | Harness + reproduce the reference spike | **COMPLETE 2026-08-27** | **YES** — 9/9, every §D.2 number exact, +2 fresh mutations red |
| 1 | Allocator core | **COMPLETE 2026-08-27** | **YES** — 27 tests, all 12 exit criteria met, 9 production mutations red |
| 2 | Deposit / withdraw + redemption-dust fix | **COMPLETE 2026-08-27** | **YES** — 59 tests, all §D.4 criteria, 11 Phase 2 mutations red, 0 survivors |
| 3 | ERC-6909 rank token + transfer | **COMPLETE 2026-08-27** | **YES** — 77 tests, all 10 §D.5 criteria plus 2 added, 29 Phase 3 mutations red, 0 survivors |
| 4 | Harberger rent variant ◀ **SUBMITTABLE** | **COMPLETE 2026-08-27** | **YES** — 125 tests, all 10 §D.6 criteria plus 16 added, **53 mutations red, 0 survivors** |
| 5 | Gas + scale | **COMPLETE 2026-08-28** | **YES** — 135 tests, all 6 §D.7 criteria, **61 mutations red, 0 survivors**. The O(1) redesign is **NOT SHIPPED** (§B.11) |
| 6 | Adversarial + invariant campaign | **COMPLETE 2026-08-28** | **YES** — 163 tests, all 5 §D.8 criteria, **66 mutations red, 0 survivors**. **FOUND AND FIXED THREE REAL BUGS** (PITFALLS 5.73, 5.74, 5.76/5.77) |
| 8 | Evacuation attack + premium hold branch | **CODE COMPLETE 2026-09-02** | **PARTLY** — 242 tests. `withdraw` now demotes; `_accruePremium` releases incrementally. **TWO EVACUATION DOORS REMAIN OPEN — PITFALLS 5.123.** |
| 10 | Value question CLOSED + all four open defects fixed | **COMPLETE 2026-09-02** | **YES** — 311 tests, 0 failed. Four defects fixed at the root, 11 tests inverted, 3 new. The constrained-buyer door closed by MEASUREMENT (PITFALLS 5.160) |
| 9 | Evacuation doors + the closed-form surplus | **COMPLETE 2026-09-02** | **PARTLY** — 308 tests. Ten defects found; four left OPEN and all four are now closed by Phase 10 |
| 11 | Handoff §3.2/§3.3 closed + the economics re-measured on the contract's own premium rule | **COMPLETE 2026-09-02** | **YES** — 316 tests, 0 failed. INVARIANT W (5.175, closes 5.164); campaign aimed at the premium (5.133 closed); solvency meter repaired (5.176); `results-book.txt` was the EMPTY BLOB and 5.160 partly does not reproduce (5.177); **every published φ number was on a replaced basis (5.178) so `PREMIUM_BPS` was re-derived 7,900 → 5,100 (5.180)**; the flagship application is takeable for gas (5.181); a third φ mirror made the quoted gas figure wrong (5.182). `src/` untouched throughout |
| 12 | Rent reversed + the TERM + c₁ 33.3→45% + docs rewritten | **CODE COMPLETE 2026-09-03** | **PARTLY** — 319 tests, 0 failed. Two mechanisms found pointing the wrong way and both fixed at the root (5.183, 5.185); `README.md` rewritten from scratch; `BUSINESS.md` §6B–6D give the per-seat P&L in dollars. **THE FULL MUTATION CAMPAIGN HAS NOT RUN AGAINST EITHER FIX — until it does, `_settleBehind` and `MIN_TENURE` are UNPROVEN**, and `M21` is a known equivalent mutant needing re-pointing first |
| 7 | Testnet deploy + demo + video | **IN PROGRESS 2026-09-02** | **PARTLY** — 224 tests. **THE MECHANISM IS SOUND AND THE BUSINESS CASE IS MISSING** — the 32 seats share one LP position, so they can at best TIE with not using the hook; the priority premium fixed the distribution (29/32 losing → 0/32) but creates no reason to participate. Next session is a BRAINSTORM for an outside payer, not a build. See `docs/research/seat-economics/VALUE.md`. Earlier note: 223 tests. **THE PRIORITY PREMIUM (`PREMIUM_BPS`) IS SHIPPED** — a filled seat pays a share of the fee it earned to the seats standing behind it; 7 new mutations RED, 0 survivors. **ROTATION IS REJECTED** on evidence (all three of its headline numbers refuted — see the banner on `ROTATION.md`). Reference allocator does NOT yet model the premium; the invariant campaign has NOT run at φ > 0. Earlier note: 205 tests. Band + wings shipped and SOUND; `recenter()` **deleted** after the panel broke it three ways (PITFALLS 5.93). Band width is now a deploy parameter. Gas re-measured on the band: sweep was understated 79%. Demo rebuilt on band maths. `recenter()` v2 attempted and **not shipped** — unit-green, campaign-red (`docs/wip/recenter-v2/`). **MARGINAL PRICING SHIPPED** — the head's free lane is closed (PITFALLS 5.103). **ROTATION DECIDED, UNBUILT** — 29/32 seats lose under permanent rank; see `docs/research/seat-economics/ROTATION.md`. **Broadcast and video still outstanding.** |

*(Phase definitions, entry/exit criteria and acceptance tests are in `PLAN.md` §C and §D.)*

---

## PHASE 12 — 2026-09-03 — the mechanism was pointing the wrong way in three places; two are now fixed

**319 tests, 0 failed, 1 skipped.** `src/` changed, so **the 85-case mutation campaign is INVALID
until re-run.** That is the single most important line in this entry.

### The finding that organises the whole session

The contract encodes **"front = good, back = bad"**. Phase 7's premium and Phase 8's marginal
pricing **inverted that** — `BUSINESS.md` §2 has said in print for two phases that priority is worth
*negative* money — and **three separate mechanisms were left pointing the old way:**

| | mechanism | status |
|---|---|---|
| 1 | **rent flowed front → back**, compensating the seat that was already winning | **FIXED** (5.183) |
| 2 | **demotion-as-punishment**: `withdraw` demotes, and the tail is the BEST seat | **FIXED** (5.185) |
| 3 | **foreclosure-as-punishment**: defaulting on rent moves you to the tail | **OPEN** — now partly self-correcting, because under forward rent the tail pays the most rent, but not asserted |

**This is PITFALLS 5.175's shape at full size:** *a conclusion that survives a dead argument is an
unproven conclusion*, and **nothing goes red, because the code is still correct.**

### What shipped

* **The rent reverses.** The back buys subordination from the front, so the back pays the front.
  Reversing a transfer **moves its defence** — `_settleAhead` guarded the old direction, so
  `_settleBehind` was written and wired into both depth-changing entry points. Shipping the reversal
  without it would have silently re-opened a closed hole.
* **`MIN_TENURE` = 7 days.** A seat may not *voluntarily* give up its rank inside its term. Enforced
  on the demotion, not the function. Involuntary rank loss (foreclosure, buyout) untouched, per §B.8.
* **A `Governance` struct.** The constructor was already at the ABI decoder's stack limit — its own
  comment says `_mintRoster` was split out *"for the STACK, not for tidiness"* — and a twelfth
  parameter tripped it with a `Stack too deep` naming nothing. Five dials are now one struct: the
  next dial is free, and the arguments are named at every call site.

### Instrument failures found, in our own tests, against our own claims

* **A mutation SURVIVED and the test was written for it.** Making the tenure stamp unconditional
  (every deposit re-arms the term → an honest LP is locked forever by topping up) broke nothing in
  319 tests, though `Lease.tenureFrom`'s docblock *claimed* that behaviour. `test_8_22` now fails by
  name. A claim in a comment with no assertion behind it is a claim nobody checks.
* **`test_3_12` passed for the wrong reason.** Its production arm asserted only that a reentrant
  withdrawal was REFUSED — and after `MIN_TENURE` it was refused by the *term*, not by the
  reentrancy guard it is named after. LAW 2 exactly. The attacker now records *which* selector.
* **`test_4_14`'s bar was `stolen > honest × 10`,** which held only because the old grabber's honest
  share happened to be 6.25%. On the re-aimed geometry the identical defect scores 5.9×, so the
  hardcoded multiple would have reported the hole CLOSED while it was open. Its witness was also
  being read *after* the mutant run inflated the weights — a baseline derived from the numerator.
* **`test_4_14b` was doubly dead:** wrong geometry, and funded single-token, which stopped moving the
  weights when Phase 8 moved them to `liquidity`. `_rentGrabAttempt` was fixed for exactly that and
  nobody applied it here. Re-armed — and it surfaced a rule written down nowhere: **a mid-accrual
  sale pays the DEPARTING holder.**
* **I retracted my own headline within the hour.** `BUSINESS.md` §6B was committed claiming ranks
  3–5 *"beat an ordinary LP in every regime including toxic"* and calling it the strongest claim in
  the document. In TOXIC **rank 5 has zero turnover on 100% of paths** — it is never filled, so the
  comparison credited non-participation as outperformance. Restated as capital preservation, which
  is both true and stronger.

### An operational mistake worth recording

While chasing a `mutate.py` process that had been killed mid-case, I ran a blanket
`git checkout -- src/` to clear the mutant it had left on disk (PITFALLS 5.79) — **and reverted my
own uncommitted work on `QueueHook.sol` with it.** Caught immediately, all nine edits reconstructed,
re-verified at 319/0/1. **The rule this earns: `git checkout -- src/` is only safe when `src/` has
no uncommitted work of your own in it. Commit before you clean up after the campaign, or use
`git checkout -- <the one file the campaign names>`.**

### Docs

`README.md` **rewritten from scratch** (old one archived); it was a Phase-9 banner over a Phase-4
body with five verifiably false claims. `BUSINESS.md` gained §6B (the per-seat P&L in dollars
against LPing elsewhere), §6C (what a seat costs and for how long, plus the Harberger equilibrium
that turns rank 1's gross −10.4%/yr into a net −1.3%/yr) and §6D (the security answer).

### ADOPTED AT THE END OF THE SESSION: c₁ = 45%, φ = 5,500

The head share is the dominant economic parameter and it moved **33.3% → 45%** (capital
`90 : 44 : 33 : 22 : 11`), with `PREMIUM_BPS` **5,100 → 5,500**. At 33.3% the TOXIC window was
EMPTY — seat 2 never cleared a passive LP at any φ — so the programme had a regime in which it did
not deliver. At 45% the intersected window holds in all three regimes: `[3777, 7340]`.

**40% was rejected although its window is non-empty:** at that window's own midpoint the binding
seat clears by `+0.010pp` against a paired SE of `0.032pp`, **t = +0.3**. At 45%, `+0.209pp` at
**t = +5.4**. **The fix is also real rather than an artefact** — rank 2's zero-turnover share in
TOXIC is 0.0% at every head share tested, so the window opens because the head absorbs the move,
not because seat 2 stops being reached.

**It is a bigger programme, not the same one costing more:** the sponsor locks 45% instead of
33.3%, the annual subsidy roughly 2.5×, and the external LPs' boost rises by about the same factor.

`Hygiene.t.sol::test_7_8` failed immediately and by name when the deploy constant moved and the two
test-side mirrors did not — the drift that went unnoticed for two phases (5.180, 5.182). That is
what a working interlock looks like.

### What the next session must do first

1. **Run the full mutation campaign — 94 cases, ~3.5 h, and nothing else may touch `src/` or run
   `forge` while it does.** It has not run against ANY of Phase 12, so **`_settleBehind` and
   `MIN_TENURE` are UNPROVEN.** Re-point **`M21`** first: it is an **equivalent mutant** — the
   credit loop's `i < r` cannot differ from `i <= r`, because `st.remaining` reaches zero at exactly
   rank `r`, so index `r` is never visited. Nine cases are new and have never run (`M20b`, `M21b`,
   `M28b`, `M28c`, `M29b`, `M29c`–`M29f`).
2. **Close or justify the third symptom in the table above** — foreclosure still demotes a defaulter
   to what is now the best seat in the book.
3. **Align every document line by line**, strip every hackathon reference, and add the three things
   that are missing rather than wrong: **a glossary** (nobody outside this repo knows what φ is),
   **the seat's price and term inside every benefit claim** (a return quoted without its rent is not
   a return), and **the rent cascade with amounts** (who receives *how much* from whom).
4. **The frontend** (5.184) — the weakest artefact in the repo. Its sliders are the best
   demonstration here and every number behind them is stale.
5. **Deploy with the owner**, then the deployed address into `README.md`.

---

## PHASE 11 — 2026-09-02. THE TWO OUTSTANDING HANDOFF ITEMS CLOSED, AND THE SOLVENCY METER WAS WRONG.

**Status: COMPLETE. Suite 316 passed / 0 failed / 1 skipped (was 311/0/1). `src/` UNTOUCHED,
so the 85-case mutation campaign is unaffected and was not re-run. Read `PITFALLS.md` 5.175, 5.176.**

### 1. INVARIANT W — and 5.164's recorded safety argument was dead (PITFALLS 5.175, closes 5.164)

The handoff §3.3 asked for the invariant that makes `_syncSeat`'s cursor-blindness safe. Writing it
down required first noticing that **5.164's stated reason no longer holds**: it argues a drained seat
is *"weighted zero in the accrual"*, which was true only while the premium was weighted by the seat's
BALANCE. `_claims` weights by `s.liquidity` (`QueueHook.sol:1356`) and liquidity is not zeroed by a
fill, so a fully drained seat still accrues in BOTH tokens. The conclusion survived; the argument did
not, and nothing went red because the code is still correct.

**The property that actually holds is `min(cursor0, cursor1) == 0`.** Induction on two lines of
`_allocate`: a fill raises the OUTGOING cursor to `next` and pulls the INCOMING one back to `start`,
which is the outgoing cursor's own old value; both begin at 0; `_fundSeat` and `_demoteToTail` only
ever LOWER one. So one cursor is always parked at the front, every fill walks from rank 0 in one
direction, and every seat below the other cursor is re-`_syncSeat`'d by the very fill that grew that
token's accumulator. No premium credit can strand outside a reachable window.

Asserted in `_checkInvariantC` (**124 tests reach it** — inverting the constant turns all 124 red) and
as `invariant_I10` over 256 runs x 16,384 calls. `test_N4b` asserts the NEGATION against the
`NO_CURSOR_PULLBACK` mutant with a paired positive control, so it is known to be capable of firing.

**Stated rather than left to be found later:** under the shipped one-ended walk W and C are maintained
by the SAME line, C fires first against that mutant, and **W is not an independent detector today.**
It is a tripwire for the change 5.164 actually warns about — a two-ended book or a reversed walk.

**A found-and-corrected error in this session's own first draft:** the first version of `test_N4b`
sized its reverse leg at `expT1 / 50` (copied from `test_N4`'s scenario) and the mutant did NOT break
W, because the fill never fully exhausted a seat and `cursor0` never advanced. The test's own
non-vacuity guard caught it. `expT1 / 5` is the size that discriminates.

### 2. The campaign is now aimed at the premium (PITFALLS 5.133, closed)

Three actions, each with an **OUTCOME floor rather than a call count** — a settle that finds nothing
accrued proves nothing:

| action | what it aims at | scripted attempts → hits |
|---|---|---|
| `settlePremiumOnSeat` | `withdraw(id,0,0)` is a pure `_syncSeat`: no money moves, no demotion | 25 → **5 claims cashed** |
| `swapToSeatBoundary` | exact-output sized to exhaust ranks `[cursor, r]` — 5.152's `next = m+1` | 10 → **3 boundary fills** |
| `swapSweepingTheWholeBook` | 5.170's `sweptBook` branch, the one that bricked the pool | 12 → **4 sweeps** |

Fuzz campaign: ~1,100 calls on each, 0 unexpected reverts, every invariant green. The dispatch table's
first twelve branches are **untouched** — the new actions were appended at picks 100-114 (modulus
107 → 115) so coverage was added rather than traded, and the existing floors were re-measured
(`orderPermuted` is still exactly 1, so that assertion was restored rather than weakened).

**The `_refAllocate` half of 5.133 is deliberately NOT done.** Porting a 200-line reference allocator
into a second file is the one-rule-two-places hazard this repo has paid for nine times — and §3 below
is exactly what that hazard looks like when it lands in an instrument. Front-first (I4) and per-seat
composition stay covered by the fixture's witness in the directed suites.

### 3b. THE SESSION'S LARGEST FINDING: every published φ number measured a rule the contract replaced

`sim.py:66` defaults `PREM_WEIGHT = 'inventory'`. The hook weights the premium by **contributed
liquidity with the payers excluded** and has since Phase 8. `report_shipping.py`, `report_tranche.py`
and `book_report.py` never override the default — so `results-shipping.txt`, `results-tranche.txt`,
`results-book.txt`, the feasible window `[7455, 8312]` and the shipped `PREMIUM_BPS = 7,900` derived
as its midpoint were all measured on a rule the deployed contract does not implement.

**The repo already knew.** `report_depth_basis.py` says exactly this in its own header — and had
never been run, because it only prints to stdout and nobody redirected it. A research script whose
output is not a committed file has not been run, however finished it looks.

Both basis sweeps were run this session. Controls pass in both (at φ = 0 the weight vector is never
read, so the φ = 0 column must be identical — it is, `0.000e+00` worst disagreement).

| regime | old window (stale basis) | new window (contract's basis) |
|---|---|---|
| BENIGN | [7455, 8312] | **[4542, 5670]** |
| NORMAL | [4114, 8921] | **[2560, 6251]** |
| TOXIC | EMPTY | **EMPTY** — s2 never clears the LP |

**`PREMIUM_BPS` re-derived 7,900 → 5,100** (owner-authorised). The old value sat 2,230 bps above the
top of the real window. **And the divergence was not all bad news:** the contract's real rule is
materially better at moving value backward — all of seats 2–5 clear the LP from φ = 4,542 in BENIGN
(was 7,455). Less premium buys more subordination.

### 3c. `results-book.txt` was the EMPTY GIT BLOB

The evidence for PITFALLS 5.160 — the result that closed the last value door — was committed at zero
bytes and was the only empty tracked file in the repo. `book_report.py` opens its output in mode `w`
at the top of `main()`, truncating before it computes, with no `finally` and no `os.replace`. That is
5.79's lesson, applied to `mutate.py` and never generalised to the tools that write the evidence.

Regenerated. **The load-bearing falsification control reproduces exactly** (`+4.487 pp`, t = +61.96
against `−1.277 pp`, t = −20.10). **Three of 5.160's numbers do not:** its LP bar of +135.9 bps
appears nowhere (+50.2 does), its rows mix φ blocks, and `−476 bps` computes as **391.9** — while the
figure for what we actually **ship** is **132.7 bps**. 5.160 amended in place.

### 3d. The flagship application is takeable for gas (5.181, PROVEN)

`buySeat(frontSeat, 0, 0)` from any stranger: costs zero, evacuates the subsidiser's capital out of
the position, drops pool depth, demotes the emptied seat to the tail — **and promotes whoever was
second into the front**, so by `Σ cᵢrᵢ = LP` the external LP who bought a *subordinated back seat* is
moved into the first-loss position. Not a contract defect — `buyPrice`'s docblock calls the free take
the deliberate bootstrap — but fatal to an application that asks a protocol to hold the front for
months. **Remedy is operational: price the seat in the transaction that funds it, and pay rent.**
`test_4_44`, every link asserted.

### 3e. A third mirror of φ, and the gas figure we quote (5.182)

`Gas.t.sol` hardcoded 8,500 as well, so the `+119%` caveat was measured at a φ we do not ship.
Re-measured at 5,100: **153,177 vs 69,970 = +119%**. The headline survived because the premium's gas
cost is the machinery, not the rate — 2,800 bps of φ moved it by 230 gas. Also cleared: 17 stale
`+133% / 162,766` instances, `199 tests / 74 mutations`, the `recycle 122–543×` sentence 5.162 named,
a retracted `~1%/yr` still sitting in BUSINESS.md's **SAY** box, and a `Ranks 2–5: LP + ~0.25 pp` row
wrong by ~3.5×.

### 3f. `BUSINESS.md` REWRITTEN FROM SCRATCH, and the old one archived rather than edited

The previous `BUSINESS.md` was a Phase-9 correction banner over a Phase-4 body. By the end its
headline numbers came from a roster the deploy script does not deploy (32 equal seats, c₁ = 0.031,
against the shipped 5 at c₁ = 1/3), at a premium rate we do not ship, on a premium RULE the contract
replaced in Phase 8 — and a retracted "~1%/yr" was still sitting inside its **SAY** box, i.e. in the
instructions for what to say out loud.

Editing it in place would have left two live answers in one file, which this project's own §7
convention forbids. So it is preserved verbatim at `archive/2026-09-03/BUSINESS-pre-phase-11.md` and
the new file was written from the measurements.

The new one is a business document: ASCII flows for pro-rata vs queue and for the subsidy, a worked
dollar example (the front's $5,800 and the back's $5,800 are the same money, which is the identity in
dollars), the five demo beats and what each proves, an honest emissions comparison that concludes
**QUEUE is not cheaper — it is the same dollar number paid differently**, nine limitations, and the
operational requirement from 5.181. Every number names its file, fixture and parameter block.

### 3. NOT ASKED FOR: the campaign's solvency meter omitted the premium (5.176)

`QueueHandler._noteSolvency` computed `owed = totals + pending` against `backing = positionValue +
float` — **leaving out `premiumOwed`, the identical omission `invariant_I2_solvency` names in its own
docblock and fixed for ITSELF.** Unsettled premium is in the backing and was missing from the owed.

| quantity | before | after |
|---|---|---|
| worst surplus token0 | 3.57e19 wei | **0, exactly** |
| worst surplus token1 | 1.03e19 wei | **0, exactly** |
| worst shortfall token0 | 20 wei | **47 wei** |
| worst shortfall token1 | 31 wei | **62 wei** |

The whole reported "surplus" was instrument. Worse, a too-small `owed` **understates every shortfall**
— and `SHORTFALL_PPB` is DERIVED from these numbers, so the bound had been derived from an
under-measurement. It still clears by orders of magnitude (ppb 0).

**No mechanism defect is implied and none was found.** `_solvent` requires exact equality on the
over-backed branch and I2 has passed throughout, so the position was never over-backed; only the
handler's record of it was.

**The tell was free and went unread for four phases: the docblock stated the expected value ("worst
SURPLUS 0 wei, both tokens, exactly") and the test PRINTED a different number on every run.** A value
that is emitted but never asserted is a value nobody checks.

---

## PHASE 10 — 2026-09-02. THE LAST DOOR CLOSED, AND ALL FOUR OPEN DEFECTS FIXED AT THE ROOT.

**Status: COMPLETE. Suite 311 passed / 0 failed / 1 skipped. Read `PITFALLS.md` 5.160–5.171.**

### 1. The value question is now fully closed, and this session closed the half Phase 9 left open

Phase 9 proved `B₁ ≥ LP`, so **unconstrained** capital will never fund rank 1. It explicitly left one
buyer unpriced — a party whose mandate forbids passive LPing, whose alternative is paying taker cost
— and called that "a conversation, not a build". **It was measurable, it was measured, and that buyer
is worse off too.**

TOXIC-DN, the only regime where such a mandate is fillable (`conv>0 = 1.00`):

| who | avg price it BOUGHT at | vs a TWAP taker | SE |
|---|---|---|---|
| pro-rata LP | 1906.99 | **+135.9 bps** | 12.9 |
| SHIPPED rank 0 | 1932.41 | **−108.2 bps** | 16.5 |
| two-ended-book rank 0 | 1981.82 | **−340.1 bps** | 9.9 |

**Monotone in priority.** A plain range order already beats the taker; priority costs ~**−476 bps**
against the pro-rata position it displaces. Front-of-queue concentrates the fill at the *first* prices
of a move, which for a buyer in a down-move are the *highest*. **A pro-rata range order IS a TWAP;
priority is what destroys that.**

**The control that settles it could have falsified the headline** (LAW 5, first corollary): a monotone
accumulator is long delta, so a real gain must survive a mirrored drift and a direction bet must flip.
Paired path-by-path: TOXIC `+4.487 pp` (t = +61.96), TOXIC-DN `−1.277 pp` (t = −20.10). **It flips.**

**General form, for whoever re-opens this: RANK IS DISTANCE FROM SPOT** — front ≈ liquidity nearest
spot, back ≈ liquidity far from it. Uniswap's ticks already sell that choice for free. The one novel
axis is that rank sorts by **trade size**, which is forgeable by splitting — `AGENTS.md` §6's
proven-impossible rule in a new hat.

**A two-ended book (one roster read from both ends, so rank 0 is a monotone accumulator) was designed,
simulated and KILLED by the numbers above.** It is not built and must not be.

### 2. All four OPEN defects fixed at the root — no labels, no bandaids

| # | defect | resolution |
|---|---|---|
| 5.152 + the maturity brick | **They were ONE bug.** `_settlePremium` took the CURSOR as its payer range, so it advanced the mark of a seat the walk never visited (7.17e19 wei erased); and a whole-book fill left `standingL − lTouched == 0`, so the pot was HELD forever, the ledger went short, and `_afterSwap` reverted `QueueUnderflow` — a bricked pool | `_allocate` hoists its loop variable (no new local — it is at the stack limit); `_settlePremium` gained a `sweptBook` branch that distributes over full `standingL` and moves NO marks, and is now `virtual`. **"The payer does not pay itself" has no meaning on a fill that swept the whole book.** 4 mutations RED |
| 5.168 | `_distributeRent` weighted by `a0` — the one quantity front-first allocation destroys. Above the band **one wei took the entire pot** | Both loops read `liquidity`. `w == 1` special-case considered and REJECTED (patches a symptom; an attacker sits one wei above any threshold). Both copies mutated SEPARATELY: 7 RED / 21 RED |
| 5.154 | The fourth evacuation door. A payout the FLOAT covers burns nothing, so nothing was demoted while the whole balance left | **RESOLVED AGAINST 5.130's refinement: any payout costs the rank.** Every alternative needs a price-dependent valuation of principal, under which an honest front seat is demoted for its MARKOUT LOSSES — 5.130 one level deeper, not a fix |
| — | New `test_8_10`: the demotion rule has TWO LEGS and each is now asserted directly. `p0`-only was caught by exactly ONE test, `p1`-only by two | The family's eighth appearance (5.37, 5.50, 5.52 ×2, 5.73, 5.125, 5.132) |

**Eleven tests asserted the defect as the specification and were INVERTED, not deleted.** The headline
is `test_M7f`, which asserted *"after the exit every swap that could reach the pot reverts"* and now
asserts the pool still swaps.

### 3. Things that went right, and are worth copying

* **`test_M2`'s one-wei clamp was diagnosed, not papered over** — it is the terminal §E.4 residue, and
  the test now asserts a STRONGER claim: a clamp may occur at most once, and only with position,
  float and liquidity all at zero.
* **The gas slope moved 19,280 → 18,448 and was RE-DERIVED, not widened** — a φ=0 control, where
  `_accruePremium` is byte-identical either side, isolates the saving to the skipped mark loop. The
  magnitude is recorded **UNPROVEN** (a naive opcode count gives a few hundred, not 833) rather than
  dressed up, and a stale attribution elsewhere in the file is flagged instead of silently rewritten.
* **A control that stopped being able to fail was RE-ARMED, not relaxed** (5.167). The rent
  re-weighting killed the flash-loan grab outright — it returned *exactly* the honest share — so
  `test_4_14` now attacks with a two-token borrowed deposit, which still mints real depth.
* **New `RentDecimals.t.sol`** — LAW 1 for a single-currency flow means both DECIMAL ASSIGNMENTS of
  that currency, not both branches. The predicted 5.124-shaped hazard turned out **not to exist**
  (the `L`s cancel); the test was written anyway and both directions catch both mutations.

### 4. Process failures, recorded while they are cheap

* **5.166 — an agent stashing for a clean gas baseline looked exactly like destroyed work.** `git
  status` showed the whole tree gone with `git log` unchanged. The one-line diagnostic is `git stash
  list`. Remedy: use a git WORKTREE or `git show HEAD:path`, never a stash, for a baseline read.
* **I ran `forge` while a teammate still held the tree, and measured a mutant against the WRONG test
  suite** (309 tests instead of 346). That is 5.79's corollary, violated by the person who had just
  written 5.166 about the same class of hazard. **Stop the agents before taking the toolchain.**
* **My own headline thesis was refuted by my own commissioned measurement, mid-session.** The
  two-ended book was argued from first principles, looked strong, and was wrong. It cost one panel and
  saved a build.


## PHASE 9 — 2026-09-02. THE VALUE QUESTION, ANSWERED IN CLOSED FORM. AND FOUR RETRACTIONS, ALL IN OUR OWN FAVOUR.

**Status: IN PROGRESS at time of writing. Read `PITFALLS.md` 5.136-5.143 before anything else.**

### What was proven

**`SLACK = c₁ · (LP − B₁)`** — the entire surplus this mechanism can deliver, in closed form.
`c₁` is the head's capital share, `LP` the pro-rata LP return, `B₁` rank 1's best outside
alternative. Derivation substitutes the identity `Σ c_i r_i == LP` into
`Σ_{i≥2} c_i(LP − r_i)`; **rank 1's own return CANCELS**, and so do `N`, the capital schedule
beyond `c₁`, the ordering rule, the premium's weighting, the rent and φ. Long form against closed
form agree to **2.4e-16 / 5.2e-18 / 4.8e-17** over 120 paths. The identity itself was re-verified
independently: 36 cells, worst residual **2.98e-14**, and invariant to φ.

Three consequences, each of which redirected work: **(a)** set `B₁ = LP` and the slack is exactly
zero, so QUEUE clears only for capital that CANNOT take the passive-LP option; **(b)** depth was
never the economic variable, `c₁` was, linearly — which answers 5.129 from the economics rather than
the gas; **(c)** no re-weighting of the premium can create value, only stop destroying it.

The closed form is **optimistic once any back seat already sits above `LP`** (5.138) — the exact
form is `Σ c_i·max(0, LP − r_i)`, because φ cannot claw back from a seat above the bar. The two
disagree by 0.47 pp in TOXIC.

### What was RETRACTED — four numbers, every one wrong in this project's favour

1. **"Rank 1 beats a keeper by 30–758 points"** — measured on a **32-equal book with a $31,250
   head**, then multiplied by the SHIPPED $333,333 head, across two configurations
   `report_shipping.py`'s own docblock calls not interchangeable. Shipped-roster truth: **−1.1 to
   +9.7 points**. It also silently dropped the two TOXIC rows in the same table (5.141).
2. **"Replicating the property costs 80–123%/yr"** — cited at `QueueDeployBase.sol:87` and
   **appears nowhere on disk**. Annualising all 30 published and measured cells produces neither
   number. UNPROVEN (5.141).
3. **The φ window [7455, 8312], and therefore φ = 7,900** — `results-shipping.txt` was produced with
   `sim.PREM_WEIGHT = 'inventory'`, the PRE-Phase-8 rule, because `report_shipping.py` never sets the
   flag. **The rule we ship has never been swept.** `results-addendum.txt` §E says so in as many
   words, in the same commit (5.142).
4. **"Surplus ≈ 1.1%/yr, thin but real"** — MY number, published to four documents and a memo, then
   retracted the same day. `B₁` was taken from a keeper modelled converting **against its own pool**,
   which is 88% of that keeper's entire cost. Off-venue at 5 bps the keeper scores **+6.20% against
   the LP's +5.02%**, so `LP − B₁ < 0` and no φ clears in any regime (5.140).

**The pattern, and it is the session's most useful output: I caught the handicap on the WIDTH axis,
published the corrected number, and it was still handicapped on the CONVERSION-VENUE axis I never
thought to enumerate. "I swept the parameter that was wrong" is not "the benchmark is now allowed
its best move."**

### Defects found — none of which existed on a baseline of 248 green, 80 mutations RED, 0 survivors

| | defect | evidence |
|---|---|---|
| 1 | **A THIRD evacuation door: the sybil buyout.** +267 bps, rank kept, rent 0, gas 516,741. Kills every "a PAID takeover keeps its rank" remedy | `Evacuation.t.sol` `test_8_11` |
| 2 | **`buySeat` has no rank guard.** A seller front-runs a buyout with `withdraw(all)`; the buyer pays the rank-0 price for a tail seat | traced, test pending |
| 3 | **INVARIANT L breaks by 20% of the position on an ordinary buyout, IN BAND, on committed HEAD.** `_onSeatTransfer` handles one direction of the burn comparison; the mirror deletes contributed depth that stays in the position. `standingL` is the premium's denominator | `Maturity.t.sol` `test_M12`/`M12b` RED, `M12c` names the fix |
| 4 | **INVARIANT L is not in the invariant campaign at all**, though the handler already calls `buySeat`. That is why (3) survived six phases | `Invariant.t.sol` has I1–I8e, no L |
| 5 | **The pool BRICKS at maturity.** Position holds 4.9567e16 wei of token0 and quotes 2.573e17 of liquidity **it cannot trade**; every one-for-zero swap reverts `QueueUnderflow` | `Maturity.t.sol` `test_M7f` |
| 6 | **`QueueUnderflow` IS reachable through an ordinary swap**, and `Adversarial.t.sol` `test_6_15` says in capitals that it is not — its argument was true when written and **Phase 7 falsified it** by adding `premiumOwed` to the identity it rests on | executed |
| 7 | **One wei of currency0 captures 100% of a rent pot above the band.** `_distributeRent` has a `w == 0` branch and no `w == 1` branch — the same shape `_settlePremium` was given an exclusion to close | `Maturity.t.sol` `test_M9b` |
| 8 | **`_settlePremium` advances a mark on a seat it never settled**, erasing that seat's claim on every earlier accrual. Attacker-chooseable by swap size | traced independently by two agents |

### Instruments corrected

* **The 300k gas budget does not exist.** `Gas.t.sol:122` is `BUDGET = 550_000` while the log label
  says "the 300k budget"; a real 300k supports 14. The number was back-formed to make `MAX_SEATS = 32`
  look comfortable and then 32 was "derived" from it — circular, ratcheted 300k → 400k → 550k every
  time it was about to bind. **Resolution: keep 32 as a pure structural cap, DELETE the budget.**
  New number for the docs: the **shipped 5-seat sweep is 667,947 gas, 2.2% of a block**, 18% above a
  1-seat sweep. The actually-binding cost is `addToSeat` at 2,667,423, which 5.129 never mentioned.
* **"Seats are fixed at deployment" is NOT the defence against roster-walk griefing.** `_fundSeat`
  must rewind both cursors, and seats are Harberger-purchasable, so a buyer of low ranks can re-dust
  before each victim swap. **Harberger rent is the defence; the fixed roster only caps the damage.**
* **The premium bound in the Phase 8 handoff was wrong on the lower side.** It is
  `−1 ≤ C − W ≤ k−1`: two floors, not one. The `−1` is STRUCTURAL — it fires whenever a seat is the
  sole unexcluded payee, which a head-only swap on a 2-seat roster hits every accrual.

### A proposal of mine, killed by measurement

I proposed pro-rating the boundary seat's premium weight, claiming it was "strictly between excluded
and full weight and therefore cannot overpay". **False, and measured:** seat 2's share reads
excluded 0.0%, pro-rated **25.0%**, full-L 20.0% — it pays MORE than the rule it was supposedly
bounded by, because shrinking one weight renormalises every other share upward. It also reproduced
`test_7_14` at **100% of the pot**. Withdrawn (5.143). Recorded with attribution because it was made
in the same hour I was telling three other agents to apply LAW 5 to their own proposals.

---

## HANDOFF — the top item for the next session, with the hard part already done

**Teach `QueueFixture._refAllocate` the premium.** The independent witness has never modelled φ, so
at φ > 0 the per-seat split has only ever rested on `Premium.t.sol`'s own controls. This was
deliberately NOT started at the tail of a long session: it is shared fixture code that twenty suites
depend on, and **half-built it is worse than absent, because a witness that silently models the
wrong rule turns every `_check` green for the wrong reason.**

**The bound is derived, not chosen: `0 ≤ contractClaim − witnessClaim ≤ k − 1` wei**, where `k` is
the number of accruals since the seat was last settled.

* The contract is LAZY: `inc_j = floor(pot_j·Q / w_j)`, and a claim is `floor(L_i · Σ_j inc_j / Q)` —
  **one** floor over the whole interval.
* The witness must be IMMEDIATE and O(n): `Σ_j floor(pot_j·L_i / w_j)` — **k** floors. Two shapes
  cannot be wrong the same way; that is the point of it.
* Writing `inc_j = (pot_j·Q − r_j)/w_j` with `0 ≤ r_j < w_j`, the accumulator's own quantisation
  costs `L_i·r_j/(Q·w_j) < L_i/Q` per accrual — at `Q = 2^128` and any realistic `L_i` that is under
  `1e-15` and vanishes under the floor.
* What remains is purely the floor count:
  `Σ floor(x_j) ≤ floor(Σ x_j) ≤ Σ floor(x_j) + (k − 1)`.

So the difference is one-sided and bounded by `k − 1`. **Do not widen a tolerance to absorb it** —
assert that bound and print `k`, `L_i`, `w_j` and `Q` in the message.

**Three design constraints, each paid for:**

1. The witness must compute its OWN per-seat contributed liquidity — mirroring `_fundSeat`'s minted
   `dl` and the burn — not read `hook.seatLiquidity()`, or it is not independent. Calling v4's
   `SqrtPriceMath` for the primitive is precedented and documented in `_refCurve`.
2. It must reproduce the payer exclusion over **`[start, next]` INCLUSIVE**, from §B.5's prose. That
   is the line a re-derivation is most likely to get wrong: it looks like an off-by-one and is not
   (see `_settlePremium`'s docblock and PITFALLS 5.127).
3. `QueueHandler` is premium-blind, so the φ > 0 campaign exercises the premium incidentally rather
   than attacking it (PITFALLS 5.133, OPEN). Closing that needs the same model, so do both together.

---

## 2026-09-02 (later) — the premium was inert on the pool we ship, and the fix needed the weight changed, not the constant tuned.

**`forge test` → 245 passed, 0 failed, 1 skipped.** `src/queue/QueueHook.sol` is still the only
production file changed.

### The three defects, in the order they were found

1. **The premium was INERT in one direction on the shipped 18/6 pool (PITFALLS 5.126).** Executed at
   18/6 against an 18/18 control with identical human economics: **0 of 4 accruals moved the
   accumulator, 100% stranded, 0 wei of token0 premium ever reached the roster** — against 0%
   stranded on the control. `Premium.t.sol` ran at equal decimals, which is why nothing saw it.
   Root cause: `premGrowth` is *incoming-token wei per OUTGOING-token wei standing*, so the ratio's
   magnitude moves by `10^(dec_in − dec_out)` and **no single `Q` can serve both directions.**
2. **Removing the guard exposed a free lane (5.127).** The same guard was also capping payout
   concentration. Without it the whole pot goes to whoever holds the last wei of standing — and
   front-first drains the tail LAST, so the tail seat is systematically that holder. Measured:
   `standing1` = **1 wei** on seat 7, claiming **100% of a 2.667e17 pot** having paid an eighth.
3. **The bound and the decimals bug are the same units error seen from two sides.** "Don't pay more
   premium than there is inventory standing" compares a pot in the incoming token against a weight
   in the outgoing one. That is why fixing one exposed the other.

### What was built

* `premGrowth`/`Seat.snap` widened to **`uint256` X128**, `unchecked` on both the accumulation and
  the difference (Uniswap's `feeGrowthGlobal` pattern, with the wrap argument written out). No
  arithmetic condition remains; the only guard is the economic one, `w == 0`.
* The premium's weight is now **`liquidityContributed`** — one unit shared by both directions, and
  dust-resistant because it survives conversion. The 18/6 pool now delivers
  **10,199,999,999,999,996 wei, bit-identical to the 18/18 control.**
* `_settlePremium` **excludes the seats a fill PAID from the pot they generated**, restoring "the
  payer does not pay itself" that inventory weighting gave for free. O(k), k = 1 for a head-only
  swap; the slots were already dirtied by `_syncSeat` in the same call.
* **Demotion refined**: a withdrawal that reduces the seat's contributed liquidity demotes; one that
  takes earnings does not. Taking profit no longer costs the front seat its rank.
* **INVARIANT L, exact**: `standingL + liquidityUnattributed == positionLiquidity + shortfall`.
  Sweep-minted depth is credited to **nobody** and the reason is written down.

### What this cost, measured end to end against pristine HEAD

|  | before | after |
|---|---|---|
| gas per seat walked | 14,778 | **19,280 (+30.5%)** |
| full 32-seat sweep, φ=8500 | 1,039,700 | **1,188,462 (+14.3%)** |
| **head-only swap, φ=8500** | 162,766 | **152,947 (−6.0%)** |
| **steady state, φ=8500** | 183,998 | **174,179 (−5.3%)** |
| seats the 300k budget supports | 35 | **27** |

The hot path got cheaper and the deep walk dearer — the per-swap constant fell while the per-seat
cost rose by a slot. **`MAX_SEATS = 32` no longer fits the budget it was derived from (5.129, OPEN).**

### Instrument and test defects found in this session's own work

* `seed()` did not apportion `liquidity`, so every suite built on it silently tested a pool with the
  premium switched off. Caught by `test_7_3` failing with "the premium did not move".
* `_backLedger` counted the attacker's own seat once the demotion moved it to a back rank — caught by
  the trader-vs-queue mirror, which is what that check exists for.
* `test_N7`'s replacement first measured the credit on `seat()`, which is claim-inclusive
  (PITFALLS 5.117), so it read identically either side of a settlement. Its own "this test proves
  nothing" guard caught it.
* **A mutation caught by exactly one test, incidentally, is a rule nobody asserted (5.130).**
  Restoring the blanket demotion rule was caught only by the cursor fuzz's order witness;
  `test_8_9` now asserts it directly.
* `CompoundingPremiumHook` became an **equivalent mutant** — the hazard is unexpressible once one
  weight serves both directions — and was retired rather than left reading as coverage.

### Stage 5 (partial) — campaign at φ > 0, and the mutation gate

**Item 2, the invariant campaign at φ > 0 — DONE, and it found an instrument defect.** It had never
run at φ > 0. Pointed at the shipping φ it failed on I1 and on I2/I2b ("the position is OVER-backed").
All three are the SAME omission: Phase 7's INVARIANT F amendment (count `premiumOwed` on the ledger
side) reached `QueueFixture._checkInvariantF` and none of this file's THREE copies. With the terms
added, **13/13 green with no change to `src/`** — the mechanism was right and the campaign had never
been allowed to look at it. PITFALLS 5.132.

**Item 3, mutations on every rule added today — 10 run, 10 caught, 0 survived, 0 BAD-PATTERN.**
The payer interval was mutated in BOTH directions as required: exclusive (`[start, next)`) is caught
by 16 tests, over-wide (`[start, next+1]`) by 2.

**One mutation survived on the first pass and is a finding: `sweepFloatIntoPosition` not recording
`liquidityUnattributed`.** Every test asserting INVARIANT L reached a sweep only through `_build`,
where the seats are funded near on-ratio — so `_liquidityForAmounts(float0, float1)` returns zero,
the function early-returns, and the line never executes. A rule whose only exercise is a no-op call
is visited, not covered (PITFALLS 5.54). `test_8_10` creates real float through an imbalanced
withdrawal and now kills it.

**Item 1, teaching `_refAllocate` the premium — NOT STARTED, deliberately.** See the report; the
quantisation bound is derived and the design is written down so it can start cold.

### Mutations (manual, not `script/mutate.py`)

Four on the new rules, **4/4 caught**: payers left in the denominator (7 tests), marks not moved
(4, including an underflow), liquidity not recorded on deposit (INVARIANT L + the demotion tests),
and the blanket demotion rule (1 → now 2, after `test_8_9`).

---

## 2026-09-02 — the evacuation attack: subordination was never enforced, and the premium's hold branch destroyed money.

**`forge test` → 242 passed, 0 failed, 1 skipped (was 224). `src/queue/QueueHook.sol` is the only
production file changed: `withdraw` and `_accruePremium`.**

### What was found

**1. The evacuation attack (PITFALLS 5.122).** QUEUE sells subordination — the front seat absorbs
adverse selection first, and is paid for it. Nothing enforced that. `withdraw` was instant, took no
lock, imposed no cooldown and did not touch the order word, so

    withdraw(head) -> adverse swap -> addToSeat(head)

ran in one transaction, handed the fill to the seats behind, and returned to the front. Measured on
two live pools identical but for the evacuation (8 seats, 18/6 decimals, 1:4 price, a 5.8% adverse
move SIZED TO A COMMON TARGET PRICE so both runs are marked in the same numeraire):

| | control | attack |
|---|---|---|
| head P&L, raw token1 | −6.4963e18 (−267 bps of seat value) | **0** |
| token1 rank 0 gave up | 125.00e18 (all of it) | **0** |
| token1 ranks 1–7 gave up | 471.83e18 | **522.23e18 (+10.7%)** |
| ranks 1–7 P&L | −9.4096e18 (−55 bps) | **−13.9177e18 (−82 bps)** |

Round trip 403,485 gas and **0 wei** of dust; the whole strike including the swap fits one external
call at 556,535 gas. The priority premium makes it WORSE, not better: it is skimmed from the fill the
head is receiving, so standing still costs ~12.5 bps extra.

**2. Why Harberger did not catch it, which is the part that matters (PITFALLS 5.9 re-scoped).**
`test_4_7` recorded rank-then-run as CLOSED. Every arm of it carries `vm.warp(30 days)`. Rent is a
time integral — `Rent.owed(price, elapsed, ...)`, and `_settleSeat` returns on `elapsed == 0` — so
the bill it measures is proportional to a duration this attack does not have. Same seat, same
100e18 self-price, funded meter: **8.219e17 wei over thirty days, EXACTLY ZERO atomically.** The
lease could not see the attack because the attack has no duration.

**3. The premium's hold branch (PITFALLS 5.124).** Two defects in `_accruePremium`, found by a peer
and confirmed here. Held pots ADD into the next `total`, so every hold made the next release
strictly harder — monotone the wrong way. And `premGrowth += mulDiv(total, 2^64, w)` FLOORS while the
release branch wrote `premiumHeld = 0` on the same line, so **any pot below `w / 2^64` left the fill,
entered `premiumOwed`, and became claimable by nobody, ever.** No attacker required.

### What was built

* **`withdraw` demotes to the tail** via the existing `_demoteToTail`, whenever it PAID something.
  The guard is on what was paid, never on what was asked: the dust policy can clamp a request to
  zero, and `withdraw(id, 0, 0)` must not cost a rank.
* **`_accruePremium` releases incrementally**: `give = min(total, w)`, retain `total - give`, hold
  everything when `w == 0` or `inc == 0`. A pot that cannot be paid is now always DELAYED and never
  destroyed, and `give <= w` gives `inc <= 2^64` directly — a tighter overflow argument than before.

### What the remedy does NOT do — stated plainly, because it would be easy to overclaim

**It does not refund the dodge.** The one-shot edge is unchanged at +267 bps: capital that is not in
the pool cannot be filled, and no rule can claw back a loss the attacker never took. What it charges
is the FUTURE — rank 0 versus rank 7 is ~932 pp/yr on `Premium.t.sol`'s own static-rank table, so
breakeven is ~1.05 days of front-seat tenure. And **two doors remain open (PITFALLS 5.123, OPEN)**:
`transfer` to a second address evacuates a seat and KEEPS its rank, and a promoted seat carries a
stale price and was bought at a 10× discount in a directed test. Any real remedy belongs in
`_onSeatTransfer`/`_payOut`, the one funnel — not in `withdraw`. Not built: it changes who can take
a seat and at what price, which is an owner decision.

### Instrument defects found in this session's own work — three, all by controls

* `leaseOf` returns five values and a test destructured four, reading `lastSettled` as `firmUntil`.
  It PASSED, because a never-settled seat has `lastSettled == 0` too. Found when the identical
  mistake failed in a second test.
* The trader-vs-queue mirror check does not pin the price exponent: any valuation linear in `a0`
  conserves it. Executed — a `_value1` applying the price once instead of squaring it kept the
  mirror green. `test_8_0c` pins the exponent against v4's own `SQRT_PRICE_1_4` instead.
* **The mutation campaign caught the author covering one branch of two (PITFALLS 5.125).** With only
  the token0 ratchet test written, the token1 ratchet mutation SURVIVED THE WHOLE SUITE — the fifth
  instance of one-rule-two-branches here. And both ratchet tests asserted a DIRECTION
  (`heldAfter < heldBefore`), which a mutation that zeroed the remainder sailed through; they now
  assert the closed form.

### Gas

`Gas.t.sol`'s absolute full-sweep budget was re-baselined 1,050,000 → 1,100,000, with the
attribution measured and written into the test: +20,958 on a φ = 8500 sweep (one zero-to-nonzero
`SSTORE` on `premGrowth`, now written where it used to be skipped), +0 at φ = 0, and **+273 in
steady state**, which is the number that says it is a once-per-pool cost rather than a per-swap one.

### Mutations run (manual, not `script/mutate.py`)

8 built, 8 informative, **8/8 caught after the gaps were closed** — 1 equivalent mutant discarded.
`withdraw`: deleting the demotion → red in 5 tests across 3 suites; dropping the paid-nothing guard
→ red in 3. `_accruePremium`: the ratchet and the destroy-the-remainder mutations, **run separately
per branch**, each caught by its own branch's test.

### Tests updated because the behaviour legitimately changed — none weakened

`test_4_7` arm 1 asserted, as correct behaviour, that a holder keeps rank 0 across an abandonment —
i.e. it had the attack written down as an expectation. It now asserts the rank is lost, and its
money assertions are unchanged and still pass. `test_3_7` and `test_4_13b` reach "empty seat" through
`buySeat` instead of `withdraw`, because their claims are about TRANSFER and FORECLOSURE and a
demoting withdrawal would have moved the rank before the thing under test ever ran — in `test_4_13b`
that would also have made the mutant arm's demotion assertion vacuous. The fixture and the
interleaving fuzz teach the witness the demotion rule, written from the rule rather than from `src/`.

---

## 2026-09-02 (second) — PHASE 8. The value question ANSWERED, and five defects found on the way.

**`forge test` → 248 passed, 0 failed, 1 skipped. Mutation campaign: 80 RED, 0 SURVIVED, 0 BAD-PATTERN
after repairs. Invariant campaign green at φ > 0 for the first time.**

### The answer, which reverses the entry below it

The session before this one concluded there was no value proposition, reasoning from a correct
identity to a false conclusion: *the sum is zero-sum, therefore there is no value.* Insurance,
credit tranching and options are all zero-sum in dollars and all real, because value comes from
allocating risk, not from creating dollars. **But the specific rescue that inference suggested — a
senior/junior tranche — turned out to be PROVEN IMPOSSIBLE, so the conclusion survived its own bad
argument.** What replaced it is narrower and measured:

> **QUEUE sells the front seat: costlessly re-anchoring at-the-money exposure no LP can buy any other
> way.** Against an OPTIMISTICALLY modelled keeper-managed ATM range — instant re-mints, no latency,
> no MEV on its own conversion trade — rank 1 wins by **30 to 758 points** at φ = 0. Replicating the
> property costs **80–123%/yr** at competing widths.

**And the thing that is NOT established, recorded here so nobody rediscovers it as good news:** rank 1
accepts a below-LP return for that property. Hold it to the passive-LP bar and it falls below at
φ = 6,397 while the back needs φ ≥ 7,455 — **both windows empty.** What the property costs to
replicate is measured; what a buyer will PAY is not, and no simulator can say.

**Also settled: no φ makes every seat beat an ordinary LP.** The capital-weighted mean of the seats'
returns IS the pro-rata LP's return, measured to 1.4e-12. φ creates nothing; it chooses who is paid
to lose. And seats 2–5 are a POOL, not a ladder — adjacent-rank separation is 2.37 between seats 1
and 2 and **0.01–0.09 everywhere else**, so the ordering among them is decoration.

### Five defects, all measured, all fixed

1. **The premium was INERT on the shipped 18/6 pool** — 0 wei of token0 premium reached the roster,
   0 of 4 accruals, against an 18/18 control stranding 0%. LAW 1 in the decimals dimension (5.124).
2. **A dust seat took the whole pot** — 1 wei of standing inventory claimed 100% of a 2.667e17 pot,
   and front-first makes the tail systematically last-standing (5.127).
3. **A single-token deposit minted ZERO liquidity**, added no depth, collected the full premium (5.128).
4. **The front could evacuate atomically** — dodge the adverse fill, keep its rank, **+267 bps in one
   transaction**, and the premium made it MORE attractive.
5. **The hold branch was a ratchet** — held pots added, so release got strictly harder forever (5.126).

Defects 1–3 were one change: weight the premium by stored contributed liquidity, exclude the seats a
fill paid over `[start, next]` **inclusive**. Defect 4 is demote-on-withdraw, refined so taking depth
out costs the rank while taking earnings does not. **The hot path got CHEAPER**: head-only swap
162,766 → 152,947 (−6.0%).

### φ moved 8,500 → 7,900, and the old value was never measured

`PROGRESS.md` claimed φ = 8,500 was *"measured, not chosen"* with *"the sweep checked in"*. **The
sweep did not exist** — `grep -li "premium\|phi"` over `docs/research/seat-economics/*.py` returned
nothing and every number in `results-seats.txt` was a φ = 0 measurement. That claim is retracted in
place above. 7,900 is solved from a stated participation constraint on the roster we actually deploy,
window [7455, 8312], reproducible via `report_shipping.py`.

### What the method caught, and what it cost

**Five tautological controls surfaced in one session** — the rotation identity, the seat-32 `a − o`
identity, an aggregate-P&L check that no ordering rule can fail, a zero-sum check passing on float
dust, and one narrowly avoided. Three were caught by whoever wrote them. LAW 5 now carries the test
that finds them: *ask what would have to be true for this control to read FAIL.* **Four were
introduced by a FIX** — the defence is a case whose answer is known in advance, not vigilance.

Four directions were closed with evidence and must not be re-opened: the tranche (impossible — one
position has one ordering governing both loss and cash), LIFO unwind (abolishes the queue), `sponsor()`
(pays most to capital that is never filled), and the Ratchet (real, and unfixable by any rule touching
fill order). See `NEXT_SESSION_PROMPT.md` §2.

---

## 2026-09-02 — the business question, asked plainly and answered honestly: there is no value proposition yet.

**No production code changed. `forge test` → 224 passed, 0 failed, 1 skipped.** The deliverable is
`docs/research/seat-economics/VALUE.md` and a handoff rewritten around finding a buyer.

### The owner's question

Paraphrased: *apart from the drawbacks, who actually makes money? Right now it looks like a burden
for the end user and almost all seat takers lose or do not earn. Participants are not motivated.*

**That reading is correct, and the arithmetic behind it is an identity rather than a measurement.**
The 32 seats share ONE Uniswap position, so their returns sum to what one ordinary LP would have
earned. The hook decides the split and cannot create a dollar. The ceiling for all 32 together is to
TIE with not using the hook — and then they have paid a lock, contract risk, a closed roster and an
unrollable band for the tie.

**The priority premium shipped the day before fixed the DISTRIBUTION and not the PROPOSITION.** It
took the book from 24–29 of 32 seats losing money to 0 of 32 — a real fix to a real defect — by
equalising everyone to the pool average. Which is what they would have earned anyway.

### What was established

* Nine ideas have now been tried. Three tried to grow the pie (inventory recycling, toxic-flow
  detection, an LVR-reducing curve) and all three are proven impossible. The other six redistribute
  it. **Nothing tested so far brings money in from outside the pool.** Full table in `VALUE.md` §3.
* The only structure that can motivate every seat is **an outside party paying rent for first fill,
  for a reason that is not the seat's own trading P&L.** Then the seats behind earn pool return PLUS
  rent, which beats an ordinary LP. That is not redistribution — it is an inflow.
* Four candidate payers named and left UNTESTED: a protocol replacing liquidity-mining emissions
  (strongest — named buyer, existing budget, acknowledged problem), a treasury working inventory, a
  market maker buying deterministic turnover, and depth sold to the pair. `VALUE.md` §4.
* **The swapper is pure cost** — same price, same fee, +133% network compute. The only honest case
  for them is indirect and conditional on the above, and must not be claimed until it holds.

### What this means

The engineering is sound and adversarially tested; the mechanism now distributes fairly; the business
case is missing, and no further mechanism design will produce it because the pie is fixed. The next
session is a BRAINSTORM, not a build: two panel rounds against the four hypotheses, with a stop
condition (a named payer, a budget line, a number, and a reason they cannot buy it cheaper) and an
explicit licence to return a negative result.

`README.md` and `BUSINESS.md` still read as though seat holders make money. They tie. Flagged in the
handoff rather than silently patched, because the replacement text has to be true.

---

## 2026-09-01 (fourth session) — the head out-earns on VOLUME, not price. Rotation rejected; the priority premium shipped.

**`forge test` → 223 passed, 0 failed, 1 skipped. `forge lint src/` clean, `forge fmt` clean. Seven
new Phase-7 mutations, all RED, 0 survivors.** Production code changed: `src/queue/QueueHook.sol`.

### The trigger

The owner asked, before anything was built, whether this hook is still interesting — specifically
whether seats 1, 5, 10 … 32 all have a reason to fund. A four-lens adversarial panel was commissioned
against the previous session's ROTATION decision. **It returned, and it broke the decision.**

### What was refuted (all three numbers rotation rested on)

1. **"0/32 seats negative" is SEED-SELECTED.** Same code, same cells, fresh seed ranges, on the
   *shipping* configuration (±30%, 45% vol): seeds 100–129 give **2/32** negative and seeds
   1000–1029 give **6/32**, with the pool PROFITABLE in both. `range(30)` was the lucky draw.
2. **"+0.0000% zero-sum, now proven rather than argued" is a TAUTOLOGY.** `_fill` was replaced with
   an allocator crediting 100% of every swap's input to the head — the maximal free lane — and it
   scored `+0.000000%` too. It is a conservation check reported as an economics result, and it is
   blind to every split.
3. **"No seat loses money" counts ENSEMBLE MEANS.** Per (path, seat) cell on the shipping
   configuration: **27% of outcomes lose money; 25 of 30 futures contain a losing seat.**

Also found in that document: the TOXIC lock table is described as inverting so the longest lock is
worst, while its own numbers show lock3 worse than lock4; and every annualised figure extrapolates a
position that has already died (TOXIC's −602.9% is ≈ −6% realised × 100).

### The measurement that replaced it

Per-rank decomposition of return into fee income vs inventory — new, and it is what the previous
sessions were missing. Benign flow, ±10% band, static rank, 30 paths:

```
      rank    fee %/yr   inventory   net %/yr   turnover %/yr
         0    +1240.1%    -328.3%    +911.8%       +411,877%
         1      +66.9%     -54.8%     +12.0%        +22,186%
         7       +5.7%     -26.2%     -20.5%         +1,903%
        31       +0.1%      -0.0%      +0.1%            +34%
```

**The head's advantage is a QUANTITY, not a price.** Marginal pricing already makes it fill at the
stalest end of every move; it out-earns anyway because it does four orders of magnitude more
turnover and keeps the whole fee on it. That rules out a price tweak (cannot reach a quantity) and
Harberger rent on an assessed value (~6%/yr against a 20–160%/yr inventory drag). Only a share of
FEE FLOW is denominated in the same thing the advantage is.

**The "29/32 seats lose" diagnosis was measured with the compensation channel switched off.**

### What was built — the priority premium (§B.13)

`PREMIUM_BPS` (φ), immutable. A filled seat keeps `(10000−φ)/10000` of the fee it earned; the rest is
paid to the seats still standing in the line it jumped, **weighted by the OPPOSITE token** — you are
paid, in the token the swapper brought, for the token you did not get to sell. A seat drained to zero
carries no weight and collects nothing from the pot it generated. Lazy accumulator (`premGrowth0/1`,
X64 in 128 bits) with a per-seat mark, so the swap path stays O(seats walked).

φ = 0 reduces **exactly** to the pre-Phase-7 contract, and is the null control every suite but the
gas one runs at.

**φ = 8,500 is measured, not chosen.** Across four independent seed ranges on ±30%/25%-vol, φ ≈ 0.85
is the only setting giving 0/32 negative on **all four**, spread 10–15 points. Honest limit: on a
45%-vol pair it leaves 0–4 negative depending on the draw, and the best φ per configuration ranges
0.55–0.90 — which is why φ is per-deployment and the sweep is checked in rather than a constant.

> **⛔ RETRACTED 2026-09-02. EVERY SENTENCE IN THE PARAGRAPH ABOVE IS FALSE, AND IT IS THE WORST
> CLAIM THIS PROJECT HAS PUBLISHED ABOUT ITSELF.** Kept rather than deleted, because a retraction a
> reader can check is worth more than a quiet edit.
>
> * **"the sweep is checked in" — it was not, and it did not exist.** `grep -li "premium\|phi"` over
>   the six `.py` files in `docs/research/seat-economics/` returned nothing. Every number in
>   `results-seats.txt` was a **φ = 0** measurement while the deploy script shipped φ = 8,500 citing
>   a sweep in that directory. The sweep exists now (`report_tranche.py`, `results-tranche.txt`);
>   before today it did not.
> * **"measured, not chosen" — it was chosen.** And the objective it was chosen against is wrong:
>   "0/32 negative" is a SIGN TEST, not a benchmark, and AGENTS.md §3b says it in terms — *a bound in
>   the right direction is not a correctness assertion.* A seat returning +2% realised is "not
>   negative" and is dominated by a pro-rata LP measured at **+28.29%** realised on the same seeds.
> * **The number itself is wrong, and wrong in the direction that matters.** Swept properly, at
>   φ = 8,500 **rank 1 loses on 100% of paths in all six configurations** (realised −66% to −68% on
>   the ±30% band). At φ = 5,000 the same seat is +42.2% / +379.2% / +63.8% realised with **0% losing
>   paths and 100% beat-LP** in four of six. The front's economics live entirely between 5,000 and
>   8,500, and 8,500 was tuned by annihilating the head.
> * **φ is genuinely per-deployment, but not for the reason given.** φ\* solved from a stated
>   participation constraint is stable to **under 1% across four disjoint seed ranges within a
>   config**, and ranges **2,870 to 7,970 across** configs. So it is a parameter derived from the
>   pair's regime, with a derivation — not a constant with a story.
> * **And the whole paragraph described a mechanism that did not run.** On the 18/6 pool the deploy
>   script ships, the token0-direction premium reached the roster **0 wei, 0 of 4 accruals**, against
>   an 18/18 control stranding 0% (`test/queue/PremiumDecimals.t.sol`, PITFALLS 5.124).

### Three defects found on the way, all fixed

* **A THIRD hand-written copy of the constructor argument list**, in `script/QueueDeployBase.sol`.
  `abi.encode` is untyped, so a ten-argument payload against an eleven-argument constructor
  **compiled, deployed, and decoded φ out of the roster's tail bytes.** The pool came up with a
  garbage economic parameter; the only symptom was `test_7_5` reporting the demo's seller short by
  2.4e15 wei. `Controls.t.sol` had the same duplication and it is now deleted rather than extended.
  (PITFALLS 5.115)
* **`Controls.t.sol`'s INVARIANT C check fed a RANK to a view indexed by SEAT ID** — the exact
  indirection the mutant allocator twenty lines above it says must not be left out. Latent (those
  controls never foreclose) and would have gone green against a leading cursor. (PITFALLS 5.116)
* **`seat()` under-reported what a holder owns.** `withdraw` settles first, so the view promised less
  than the contract pays. It now reports the settled value and the claim formula lives in one place
  both callers read. (PITFALLS 5.117)

### Costs, measured, and one published number corrected

```
    plain v4 pool                  69,970
    QUEUE, phi = 0                131,821    +88%
    QUEUE, phi = 8,500            162,766   +133%
```

Both sides in **steady state** (one swap through each pool in `setUp()`). **QUEUE's overhead was
never the +48% this project published** — that figure compared against a plain pool that had never
traded, so the control was paying its own one-time fee-growth writes. Per-seat sweep cost 9,945 →
14,777, exactly one cold slot for the accumulator mark; `BUDGET` moved 400k → 550k rather than
`MAX_SEATS`, because 32 is the 32 bytes of the packed `order` word. (PITFALLS 5.118)

### Two of this session's own tests were blind when written, both caught by mutation

`test_7_8` compared `seat()` against `seat()` — and `seat()` already includes the pending claim, so
both sides moved together (PITFALLS 5.34's tautological witness, again). The N7 control could not
enter the branch it mutated, because a `zeroForOne` swap advances only one accumulator. Both are
recorded rather than quietly fixed, because the first version of each would have been evidence that
a load-bearing rule was unnecessary.

### What is NOT done, and it matters

* **The reference allocator does not model the premium.** At φ > 0 the seat-by-seat composition
  check is unavailable, so the per-seat SPLIT rests on `Premium.t.sol`'s controls rather than on the
  independent witness. **This is the top item in the handoff.**
* **The invariant campaign has never run at φ > 0.**
* **The band/term constructor guard was decided by the owner and is not built.** Blocked on
  converting the constructor to a parameter struct — it is at eleven arguments and the ABI decoder
  ran out of stack at twelve.
* `README.md` and `BUSINESS.md` still describe the pre-premium product and still quote the +48% gas
  figure.

---

## 2026-09-01 (third session) — 29 of 32 seats lose money. Rotation is the answer, and it is decided but unbuilt.

**No production code changed. `forge test` → 205 passed, 0 failed, 1 skipped, unchanged.** This
session was a design decision, and the deliverable is `docs/research/seat-economics/ROTATION.md`
plus a crafted handoff in `NEXT_SESSION_PROMPT.md`.

### The trigger

The owner's objection, and it is correct: a hook where the traffic funnels to one seat is not a
product, and the previous session's own numbers said 28-29 of 32 positions lose under every regime.
"Two products, not 32" was a correct DIAGNOSIS and the wrong REMEDY — it accepted that most of the
book should not be funded rather than fixing it.

### What was proven

**The book is zero-sum against its own pro-rata benchmark, to four decimal places.** Front-first vs
one undivided pro-rata LP, same capital, same flow, same seeds: volume +0.0000%, total P&L +0.0000
pts, both regimes. Availability is identical because the cursor only advances past EMPTY seats. So
the inventory-recycling hypothesis is dead, and **no ordering scheme can make all 32 seats BEAT a
pro-rata LP.** The ceiling is all 32 EQUAL to it (5.112).

Deterministic time-rotation reaches that ceiling. `rank(i) = (i + floor((now-genesis)/EPOCH)) mod N`
— a pure function of time, no stored rotation, no keeper, no randomness, no oracle. Round-robin
rather than random **because on-chain randomness is a block hash and a head slot worth several
hundred percent a year is worth a builder grinding for.** Measured, benign pool: static rank gives a
932-point spread with 29/32 negative; rotation gives 13-18 points with **0/32 negative**.

### The result that reframes the whole project

**Band width dominates the allocator and τ, and the shipped ±10% is a losing LP position on a
volatile pair whatever the hook does** (5.113):

```
      band    vol      pool     worst      best   seats<0
     +-10%   0.45    -18.6%    -47.8%    +23.6%     24/32
     +-30%   0.45    +14.9%     +2.8%    +27.7%      0/32
```

±10% dies in ~18 days and the terminal traversal is one lumpy loss landing on whoever is at the
front. Rotation equalises the FLOW; it cannot equalise a single terminal event. Corollary nobody had
noticed: **the rotation cycle must complete inside the band's life** — at 24h epochs a 32-seat cycle
is 32 days against an 18-day band, so it never completes and equalisation silently fails. Epochs are
hours, not days.

### The differentiator, and the honest pitch

**Lock-weighted priority**: head-time share proportional to committed lock length. On the shipping
configuration (±30%, 4h epochs, tiers 4:3:2:1) it produces a monotone duration curve —
lock4 +56.1%, lock3 +40.0%, lock2 +24.7%, lock1 +10.5% against a pool of +32.8%, with 0/32 negative.
The tier mean equals the pool return in every row, so **the split is still conserved; only its AXIS
changed**, from "which seat number you bought" to "how long you commit".

That is the pitch that survives: **pay for sticky liquidity with fill priority instead of token
emissions.** Uniswap cannot price how long you will stay; this can. Ship uniform as the DEFAULT (all
weights equal reduces to it) so the 0/32 guarantee holds out of the box, and make weighting opt-in —
lock-weighting re-introduces a below-average tier (lock1 −3.8% in NORMAL) and **front-time is
leverage on the pool's own outcome**, so the curve inverts in a losing pool.

### The riskiest unverified thing, flagged rather than glossed

**A rotating rank breaks INVARIANT C, because cursors ARE ranks** (5.114). Rotate the rank→seat map
underneath `cursor0`/`cursor1` and a cursor can LEAD a funded seat — silent theft of rank, exactly
what N2 and N4 exist to catch. Proposed remedy (store `lastEpoch`, reset cursors to 0 on the first
swap of a new epoch; a lagging cursor costs gas but never money) is **reasoned from the source and
NOT executed.** It is Step 0 of the next session for that reason.

### Process note

A four-agent adversarial panel was commissioned to attack the rotation design and **did not return
findings before the session ended**; they were stopped. The AGENTS.md §5 lenses were applied
directly instead. The rotation design has therefore NOT had an independent adversarial pass, and
that is stated at the top of the handoff rather than buried.

---

## 2026-09-01 (second session) — The head was winning in every state of the world. That is not a market.

**State on exit: `forge test` → 205 passed, 0 failed, 1 skipped. `forge lint src/` clean. Full
mutation campaign: see the bottom of this entry.**

### It opened with a live security hole that was nobody's design decision

`test_4_19_onlyTheHolderMayDrainTheMeter` was RED. `withdrawRent` had **no seat-ownership check** —
anyone could drain any seat's escrow. It was not a regression anybody wrote: the previous session's
`mutate.py` campaign was SIGKILLed, its `finally` never ran, and it left the mutant on disk. The
suite had been failing against it ever since, and the handoff note said "199 passed, 0 failed"
because that was measured before the campaign started.

Restored, and then **fixed at the mechanism level rather than by writing the rule down again**
(PITFALLS 5.100 → CLOSED). `mutate.py` now tracks what it last wrote to each file; the `finally`
restores only over its own content and REFUSES over anything else, saving the pre-campaign original
to `<file>.mutate-backup` and printing what to check. The per-mutation loop raises rather than
racing an editor. Separately, `mutate.py --help` used to **launch the full campaign** — unknown
flags were discarded silently — which is how the hazard was rediscovered mid-session (5.107).

### The real work: average pricing was a subsidy, and no test could see it

The question put to this session was whether anyone would buy seat 5, 15 or 30. Answering it
honestly meant simulating the mechanism **as the contract executes it** — constant-liquidity band,
seats holding `(a0, a1)`, front-first drain from a cursor, seats emptied and skipped until the flow
reverses. `BUSINESS.md` §0.5's numbers came from a model with no inventory and no cursors, which
let the head refill for free on every trade, and the error ran the head's way every time (5.104).

Rebuilt, it found something the test suite could not:

```
                                    BENIGN      NORMAL       TOXIC
  ordinary pro-rata LP              +21.2%      -31.8%     -752.6%
  seat 1, AVERAGE pricing          +934.0%     +675.3%     -439.9%   beats an LP in ALL THREE
  seat 1, MARGINAL pricing         +911.0%     +566.1%     -796.2%   loses in the toxic regime
```

Every seat a swap reached was credited the swap's **average** price, so the head took all of the
volume *and* the same price as the seats behind it. It beat an ordinary LP in every state of the
world, including the toxic regime that exists precisely to punish whoever is first into a stale
price. That is AGENTS.md §5's **free lane** — the failure that has killed seven mechanisms here —
and it was invisible to 199 tests, 74 mutations and the invariant campaign, because average pricing
**conserves perfectly**. It hands the wrong seat the money, and conservation cannot see that.

**Fixed at the mechanism.** A swap sweeps a RANGE of prices; being filled first means being filled
at the stalest end of it. `Allocation.step` now takes a price curve (`wCum`, `wTotal`) and credits
each seat the segment it actually absorbed. The head fills worse than the swap average, the seats
behind it better, in both directions — asserted in `test/queue/Marginal.t.sol`, measured at ~400 bps
of spread across the book. Total return is unchanged to the wei: this moved value, it did not
create any.

Design notes worth keeping:

* **The cumulative form is what makes it exact.** `give` is the DIFFERENCE of two cumulative
  allocations, so successive `mulDiv`s against a non-decreasing curve telescope and the parts
  cannot drift from the whole whatever shape the curve has. Fuzzed against arbitrary monotone
  curves, not just the one the hook builds.
* **The curve is built lazily**, at the first seat that will not finish the swap on its own. A
  head-only swap — almost every trade — never builds one: **128,625 → 128,848 gas, +223**.
* **`_segmentIn` is TOTAL.** It runs inside `afterSwap`, where a revert is a bricked pool rather
  than a failed sum, and v4's `getNextSqrtPriceFrom...` helpers revert rather than saturate once
  the amount would exhaust the position. Capacity to the band edge is measured first and the walk
  is clamped there. M80 confirms the clamp is load-bearing.

### Two of this session's own instruments were wrong, and both were caught

* **N4 began dying for the wrong reason.** The `Controls.t.sol` mutant still priced at the average
  while production priced by segment, so it differed from production in TWO places and died of the
  one it was not testing. Caught only because the control asserts the **exact revert reason**
  (LAW 2); `reason.length > 0` would have stayed green (5.105).
* **`test_8_3` passed under a mutant that deleted marginal pricing.** It asserted
  `head < average < tail`, which is *still true* under average pricing for a pure rounding reason —
  floored shares land a wei low, the remainder line puts the last seat a wei high. 5.53's rule in
  new code: a bound in the right direction is not a correctness assertion. Now requires ≥10 bps
  (5.106). **It was only visible because the mutation was applied to the hook AND the witness
  together**; mutating the hook alone dies on the fixture's own comparison and hides whether the
  new assertions have teeth.

### The gas budget moved, and `MAX_SEATS` deliberately did not

Queue walk 8,070 → **9,945 per seat**; queue-attributable cost at 32 seats 278,140 → **342,365**,
over the stated 300k. `MAX_SEATS = 32` is the 32 bytes of the packed `order` word, not a gas choice,
so the budget was raised to 400,000 **with the reason recorded in the test**, and the constraint
that actually binds is asserted separately and did not move: a full cold 32-seat sweep is 826,799
against an 850,000 ceiling (5.108).

### The product answer, which is less comfortable than the pitch was

**QUEUE redistributes one Uniswap position's return; it does not create return.** Against its own
pro-rata benchmark the book is zero-sum, so **there is no configuration in which all 32 seats beat
an ordinary LP, and there cannot be one.** Simulated, 32 equal seats:

* **Seat 1** — equity-like. Enormous in benign and normal, genuinely loses in toxic. A real
  position with a real risk, now that the free lane is shut.
* **Seats 5–20** — lose under **every** condition (−8% benign, −77% normal, −1267% toxic). Reached
  often enough to absorb the large toxic trades, not often enough to earn the small profitable
  ones. Marginal pricing improves them and they stay negative.
* **Seat 32** — ~0%, and that is not a coupon, it is capital the flow never reached. Still a **win**
  where an ordinary LP returns −31.8%. Bond-like, and should be sold as one.
* **The tail's real income is rent**, and the shipped **τ = 10% gives a 6.4% coupon**; 25–50% gives
  10.7–13.8%. τ is already a constructor argument, so this is a deployment decision.

Sizing the head compresses the middle (worst of seats 2–21: −109.6% → −49.9%) and doubles the seats
that beat an LP — while collapsing the head from +566% to −38%. **They are the same money.** The
design honestly supports **two** positions, one head and a deep tail, with the middle left unfunded.
Seat capital is chosen by holders, so the contract already supports this and **no code change
follows** — but the pitch had to change, and `BUSINESS.md` §0.5 was rewritten around it.

Evidence, both models and the reproduction scripts: `docs/research/seat-economics/`.

### Two more defects, both found by reading rather than by a test

* **The band-entry rule got duplicated into a second function** — `_bandStep` replays the in-band
  fill, `_initCurve` prices it, and each wrote out the same clamp. Fifth instance of one-rule-two-
  places here, and the worst of them: the fill would be replayed from one anchor and PRICED from
  another, and **conservation would still tie out to the wei** because `wTotal` normalises the
  total away. Extracted to `_bandEntry`; M77/M78 now catch 74 and 118 tests where the duplicated
  pair caught 60 and 64 — the extraction is measurably more load-bearing (5.109).
* **`room == 0` produces a CONSTANT curve**, which hands the first non-finishing seat the entire
  input and every seat behind it nothing. Guarded to fall back to the average. Believed
  unreachable and **written down rather than tested** — §3b's third honest answer (5.110).

### The mutation campaign, and one stale instrument

Full campaign: **79 RED, 0 SURVIVED, 0 NO-COMPILE, 1 BAD-PATTERN.** The BAD-PATTERN is the finding:
changing `Allocation.step` to an if/else silently turned M59 into `0 matches`, so that defect was
not tested on that run while the summary still read "0 SURVIVED". **`BAD-PATTERN` is a failure, not
a status** (5.111). M59 retired in favour of M76 — the same defect against the current source — with
the reason recorded in `mutate.py` rather than deleted. The 7 new price-curve mutations (M74–M80)
are all red, re-run after the refactor.

### Not done

**Broadcast to Unichain Sepolia and the video.** Both are submission gates, neither is code, and
neither moved this session. `recenter()` v2 is still unshipped and still campaign-red
(`docs/wip/recenter-v2/`).

---

## 2026-09-01 — The panel attacked the pivot. `recenter()` is gone, and the demo was showing a deleted design.

Took over after four commits (`cc1c594`..`11e1578`) that moved the hook from a **full-range sole-LP
position** to a **concentrated band with disjoint wings**, an in-band clip, and a permissionless
`recenter()`. Convened the §5 panel against the new surface. Findings, then what shipped.

### The instrument was green and wrong

`python3 script/mutate.py` → **74/74 RED, zero survivors** — while the panel, reading the same source
the same afternoon, found three real defects in `recenter()` and one in the clip. **All four sailed
through.** M72/M73 each went red on exactly *2* failing tests, and those two tests were the ones the
panel showed were blind. The mutations were written by the person who wrote the tests, against the
same mental model. **Zero survivors measures the hypotheses the suite encodes, not correctness**
(PITFALLS 5.92). This is the single most important thing learned this session.

### `recenter()` — DELETED, and the deletion is what makes the rest sound

Three defects, one root cause: the band and the wings compete for the at-the-money ticks, and
"overlap is forbidden" means the queue can never take them back.

- Its guard read `getLiquidity(poolId)` — active L **at the current tick** — while the destination is
  a **range**. A wing resting inside the new band but not spanning spot was invisible and got
  swallowed: N5 reopened, with no overlapping add ever submitted to `_beforeAddLiquidity`.
- The guard was nonetheless **correct**, which is worse — any wing covering spot blocks it, and price
  leaving the band *is* price entering a wing. One wei at the money stranded the whole roster.
- When it did run it destroyed the position's depth: a band the price left holds one token, the
  remint takes `min` of both legs, so it deployed ~nothing and `sweepFloatIntoPosition` could not
  restore it. **Capital was never at risk** — every seat could still withdraw in full from float —
  but the pool quoted nothing until repaired, and anyone could re-trigger it for gas.

Both covering tests passed because `_positionValue` and `redeemAll` each early-return at `L == 0`, so
INVARIANT F degraded to `Σa == float` and held *because* the float carried the whole inventory
(5.54 compounded by 5.75). Deleting the function makes `(tickLower, tickUpper)` write-once, which
upgrades `_beforeAddLiquidity`'s add-time disjointness test from a snapshot of a moving target into a
**complete guard**. Verdict on band+wings without recenter: **SOUND**.

### `BAND_HALF_WIDTH` is now a deployment parameter

It was `int24 public constant = 960` — ±10% for every pair forever, chosen because a test used it.
Band width sets depth at the money, which sets how large a trade must be to reach rank 2, which sets
how many seats exist in practice. It is the mechanism's main economic dial and it now belongs to the
deployer. Validated at construction (`BadBandWidth`), immutable for the same reason τ is. Two new
tests assert the **snapped band**, not the stored number; M72/M73 re-purposed to cover them.

### Every gas number was taken on a fixture where the sweep did not sweep

`Gas.t.sol` was untouched by the pivot and built through `_open` → `_openRange(minUsable, maxUsable)`
→ the test-only `seed()` — full range, which **production cannot create**. `_tickInBand` was always
true, so `_bandStep`/`computeSwapStep` never executed in any measurement in the project. The control
pool was full-range too, which measures the range rather than the hook. Re-measured on the band:

| | published | measured on the band |
|---|---|---|
| head-only through QUEUE | 128,406 | **128,625** |
| same swap, no hook | 86,820 | **87,039** |
| overhead | +41,586 / +48% | **+41,586 / +48%** — unchanged |
| slope | 8,070/seat | **8,070/seat** — unchanged |
| **full 32-seat sweep** | **426,470** | **764,200 (+79%)** |

The headline survives because the common path really is the fast path. The sweep was understated
because the old "full sweep" walked a handful of seats and stopped — 5.87's full-range reachability
showing up as a broken instrument. `test_5_3c`'s ceiling went 500k → 850k **with the reason recorded
in the test**, since the code did not regress; the measurement was wrong.

### A one-line fix I nearly shipped, caught by the invariant campaign

The clip's tolerance fires when the band's share is zero (`0 + 1 >= amtIn` at `amtIn == 1`), crediting
the head a wei the band did not earn. Adding `bandGross != 0` made `invariant_I1` go **RED** — and I1
was right: with no wings there is nowhere else the wei can have gone, v4 cannot attribute it at
`L == 0`, and Step 2c exists precisely to stop the ledger under-counting there. **Reverted, and the
negative result written into the code** so the next person does not re-derive it (5.95). The residual
exposure needs wings + a wing-only swap + `amtIn == 1`; closing it needs the hook to measure what its
own position received rather than infer it. Logged, not papered over.

### The economics — the panel's own verdict INVERTED mid-session, twice, and the final one holds

The owner asked what seat 5 or seat 30 is for, and whether the whole thing is dead code. The first
answer ("the tail is the subsidy") **was wrong: it assumed markout = 0.** Recorded here in the order
it happened, because the corrections are the result.

- **Yield is set by depth, not rank.** `y_net(x) = f·N_noise(x) − (m−f)·N_inf(x)`. The noise term dies
  at the largest *noise* trade, the toxicity term at the largest *informed* trade, and **informed
  trades are larger** — so there is a depth band that takes ALL the toxicity and NONE of the fees.
  At m = 60 bps the trough is exactly `[$10k, $50k)` at −328.5%/yr; the poison zone `[$10k, $100k)`
  is $90k of capital destroying $186,150/yr, 1.7× the pool's whole net profit. Ranks 2–4 are
  −241% / −110% / −22% while rank 1 is +723%. **A barbell with a poisoned middle.**
- **An unreached seat is not an LP position.** `_allocate` breaks the moment the swap is sourced, so
  the seat is never written — it is a static basket, and a basket that does not trade has **zero LVR**.
  Avoidance, not deferral: the conversion never happened, so there is no later date on which it does.
- **What QUEUE actually sells.** A pro-rata dollar here earns +32.85%/yr from retail flow and
  −21.90%/yr from arbitrage flow, net +10.95%, **and cannot decline either half.** QUEUE is the first
  AMM position where capital can decline the arbitrage half — the price being the retail half.
  **The stronger-sounding claim that a pro-rata LP "holds a slice of the trough" is FALSE and must
  never be written:** the depth coordinate is *created* by front-first ordering, not revealed by it.
- **The window:** a tail seat beats pro-rata at **m ∈ (66.6, 126) bps** — i.e. when the pool loses more
  to arbitrageurs than ~89% of what it collects in fees. Above 168% a plain wallet dominates.
  Measurable from a pool's own history (mark inventory at t+5min, sum signed P&L, divide by fees).
- **θ = τ/(τ+k) = 0.29.** Rent moves 29% of the front's advantage backward; 71% is capitalised into
  the seat price. θ→1 only as τ→∞. **No Harberger rent can make the tail whole** — so rent is not the
  tail's product; declining the arbitrage half is. The docs' `A/τ` fair-ask rule was the
  zero-discount-rate limit and **overstated an ask 3.4×**; corrected to `A/(τ+k)` (5.99).
- **The trough cannot be dodged, only assigned** — queue depth is contiguous, and wings live on *tick*
  ranges, which is a price coordinate, not a depth coordinate. Deployment rule: **head seat capital =
  the largest routine INFORMED trade (P99)**, not the largest noise trade, and then no trough seat
  exists. **"Two products, not 32 seats":** one head, one undifferentiated tail; `MAX_SEATS` is
  capacity for participants, not 32 distinct products.
- **Deleting `recenter()` has a real economic cost and it is stated at full strength.** The crossover
  window is unchanged (it is a ratio; a fixed band duty-cycles both sides equally) but **the
  magnitudes collapse ~20×**: a ±10% band at σ=45%/yr has ~16–18 days of expected in-band life, so
  the tail's whole lifetime edge is **~2.2% of capital once, plus a coupon worth ~0.13%**. And a
  **genuine regression versus ordinary Uniswap, new this session:** a QUEUE LP cannot burn and
  re-mint around the price; the only exit is withdraw-and-redeploy into a new pool. **QUEUE is now a
  fixed-term instrument, not a perpetual venue.** Every annualised figure is therefore *per year of
  in-band operation* — said once, loudly, not in footnotes.
- **The dial that pays for it is the band width made a parameter this session.** In-band life scales
  as `w²`, depth per dollar as `1/w`, so **doubling the band quadruples the life and halves the
  depth**: ±10% → 16 days, ±30% → 124 days, ±50% → 296 days. **The shipped ±10% is sized for a demo.**
- **The risk, kept at full strength:** the pools where this pays are the pools rational LPs are
  already leaving, and there are at most 31 buyers because the roster is capped. Plus **routing
  viability and seat value are anti-correlated**. That, not the +48% gas, is the sharpest unanswered
  commercial objection.

Written up as `BUSINESS.md` **§0.5** (eight subsections) and a rebuilt demo section.

### `recenter()` v2 — attempted properly, and NOT SHIPPED

Rebuilt after the deletion, on the owner's instruction to fix it robustly rather than remove it. The
rebuild does fix all three v1 defects:

- destination emptiness is checked as a **RANGE** — liquidity active at the near edge
  (`getLiquidity() ± liquidityNet(edge)`, so a wing *ending* at the edge is correctly allowed) plus a
  tick-bitmap walk that truncates the band at the first initialised tick inside it;
- the mint is **one-sided, one spacing clear of spot**, so `sqrtP` is outside the band and
  `_liquidityForAmounts` takes the single-token branch and deploys in full instead of `min`-ing to
  zero;
- the price must be a **full half-width** beyond the band, and after a move it is one spacing outside
  the new one, so it cannot be ratcheted.

Eight targeted tests pass, including one asserting the property the deletion had bought: an outside
LP still cannot mint inside the band **after** it moves.

**The invariant campaign fails and the cause was not located, so it does not ship.** Bisecting the
handler's selector set, one 40-second run per hypothesis: `swap`+`recenter` GREEN; `+sweepFloat` RED;
`+addToSeat` RED; `+withdraw` green; everything except `recenter` GREEN. The magnitudes rule out
rounding — `I2b` shortfalls ~9.1e20 on inflow 9.1e21 (10%), `I1` gaps ~60,631 wei. The lead: a v2 band
sits BESIDE spot and never contains it, so the pool has **zero active liquidity at the current tick**,
which the rest of the contract has never operated in. Everything is preserved in
`docs/wip/recenter-v2/` with the evidence and three ranked suspects.

**Two things this cost, both worth more than the function.** `_solvent`'s over-backing branch turned
out to be an *asymmetry* rather than a stronger claim (PITFALLS 5.102) — and making it symmetric is
what let the campaign find the large divergences at all, so a strict assertion had been hiding a
bigger defect behind a smaller one. And **a background `mutate.py` silently reverted ~200 lines of
`src/` mid-session** (5.100): the 5.86 interlock guards `forge test`, not *writes*, and the campaign's
`finally` restore overwrote work made while it ran. The only symptom was a compiler error pointing at
the caller of a function that no longer existed.

### The demo was simulating a design that no longer exists

`frontend/index.html` ran `swapOut` as pure full-range constant product and credited 100% of the
whole-pool output — **literally M70**. Its "Sweeping trade" button sent 2,500 into a band emptied by
1,578 and rendered "3 swept, 2 untouched" for a trade that empties every seat. The pivot's *only*
edit to the hero paragraph was deleting the word "full-range", while it still claimed to be "the
contract's own arithmetic" and quoted a wei-level agreement measured on the pre-band hook. Rebuilt on
concentrated-liquidity maths (capacity 1,578.5, derived two ways independently), preset corrected,
the false validation claim removed rather than restated, the band read from `pool()` in live mode,
a glossary added (**"wings" appeared nowhere on the page or in the README**), and the seat-economics
section added.

**Suite: 197 passed, 0 failed, 1 skipped. `forge lint src/` clean.**

**Not claimed:** no broadcast, no video. The marginal-pricing allocator that would make a back seat a
genuine senior tranche is **not built** and is a different allocator, not a parameter.

---

## 2026-08-31f — Recenter + PositionManager wings

`recenter()`: permissionless, burns the old band, snaps ±10% around spot, remints from float. Seat ledger unchanged. Reverts `BandStillInRange` if still in, `DestinationOccupied` if the new ticks have L (a wing). Empty ticks: follows the price. `_burnPosition(0)` is a no-op (a zero poke reverts `CannotUpdateEmptyPosition`).

Wings mint/burn through the real `PositionManager`. Overlap still `OverlappingLiquidity`.

Invariant handler includes `recenter`. I1 ghost unchanged (no wing mints in that campaign — PM-delta ghost).

183 tests. M72/M73/M74 RED.

---

## 2026-08-31e — DMM on the touch, ordinary Uniswap in the wings

The 32-seat closed pool was the wrong object for a Uniswap submission. What a Uniswap team can use, integrate, or experiment on is: a paid queue **on the concentrated band**, and permissionless v4 LPs **in the disjoint wings**.

**What shipped**

- `_beforeAddLiquidity` allows `sender == this` or a range strictly disjoint of `[tickLower, tickUpper)`. Overlap reverts `OverlappingLiquidity`. Adjacent at a boundary is disjoint (Uniswap ranges are `[lower, upper)`).
- `_afterSwap` credits only the in-band fill. A swap that starts and ends inside the band is the identity (ticks, not `getSqrtPriceAtTick` — that was the gas). A swap that leaves or enters is one `SwapMath.computeSwapStep` over the overlap. The result is a **cap**: if the replay is not more than 1 wei tighter than PoolManager's delta, keep the delta. That 1 wei is SwapMath vs Pool.swap rounding (I1), not a wing fill.
- `test/queue/Wings.t.sol` — overlap same-range / partial / full-range RED by name; disjoint mint; small in-band swap does not move wing principal and `_check` still holds; crossing swap credits the band only and `redeemAll` covers the ledger; no-wings in-band is identity.
- M70 (skip the clip) RED. M71 (allow overlap) RED.
- Skeptic pass (2026-08-31f): crossing tests were inequality-only; now wei-equal to an independent SwapMath replay. Added reverse, re-entry, full traverse, exact-out, protocol-fee crossing, salt, overlap-from-above, already-outside. **Not claimed:** invariant+wings (ghost is whole-pool), PositionManager glue, band recenter after drift.
- Head-only gas is now **128,406 vs 86,820 = +48%**, still flat 1–32, still under the 50% ceiling. Sweep slope unchanged at 8,070/seat. 32-seat sweep 426,470.
- PITFALLS 3.4 SUPERSEDED by 3.14.

**What this is not.** 32 seats per tick. NFT-per-seat ranges. A full re-campaign of the pre-wings 69 mutations (not run this session; do not claim it).

**Suite:** see 2026-08-31f. Recenter + PositionManager wings shipped; M72/M73/M74 RED.

---

## 2026-08-31d — The shipping position is a Uniswap band, not the whole curve

**The v2a/v2b/v3 labels were a mistake.** What Uniswap engineers vibe with is not extra NFTs and not three bands. It is: Uniswap already orders by PRICE. QUEUE orders LPs *inside that price*. Same curve, same router, one concentrated position, 32 seats sharing it.

**What shipped:** `_afterInitialize` snaps a ±960-tick (~10%) band around the start price. `BAND_HALF_WIDTH` is a constant, not a constructor arg (that would have touched every encode site). Seats are still ERC-6909, not Uniswap NFTs, and they do not pick ranges.

**What caught us:** `_positionValue` in the fixture hardcoded `minUsableTick`/`maxUsableTick`, so INVARIANT F valued a concentrated L as if it were full-range (~20x too much token). The instrument, not the hook. PITFALLS 5.75 again. Both the fixture and the invariant handler now read `hook.pool()`.

**M69** (full-range again) is RED, 2 failing. `test_7_9` pins the band. `test_7_5` still walks the demo sweep — concentrating made the walk *more* visible, not less.

Tests written against a full-range blob (packing fuzz, the reentrancy control) restore that fixture via `QueueHarness.forceRange` BEFORE any mint. Production has no equivalent.

---

## 2026-08-31c — Spike: price-then-queue is an afterSwap walk, not a new AMM

**Status: 8/8 on `test/spike/PriceThenQueue.t.sol`. No production code. Queue suite untouched.**

The shipping hook is misaligned with Uniswap: it throws ticks away to get a queue. The Uniswap-shaped object is **price then queue**. The riskiest assumption was that `afterSwap`'s one `BalanceDelta` is enough to attribute a crossing swap to the bands the price actually walked.

**It holds.** `SwapMath.computeSwapStep` over a three-band ladder (below / at / above, non-overlapping, 1:4, 18/6, real PoolManager) matches PM net input and output **to the wei**. A small swap stays 100% in the middle band. A crossing zeroForOne credits below and not above; the other direction credits above and not below. There is no tick-crossing hook flag (14 named bits).

**Two mutants, both red, identical fixture:**
- Smear the aggregate by L: conservation holds, composition is a lie (untouched wing gets a share).
- Dump the whole fill on the middle band: `slot0` has left the band, mutant still reports the wing at 0.

**A false claim the spike caught in itself:** "concentrated is deeper per unit L." Same L is the same instantaneous depth. The 1/200th figure is same *tokens*, not same L. Replaced with `test_spike_sameLCostsMoreTokensAtFullRange`.

**What this is not:** 32 queues per tick; overlapping v3-style ranges; a shipping feature; protocol-fee-on; exact-out; a gas number.

**Build order, do not skip:** v2a concentrate the blob (`test_1_11`) → v2b 3-band ladder (this spike) reusing `Allocation.sol` → v3 arbitrary overlapping ranges (new spike required). Do not take over the swap with `beforeSwapReturnDelta`.

Verdict: `docs/research/price-then-queue/SPIKE.md`.

---

## 2026-08-31b — Pair-wide vs per-tick, one-sided seats, and a buy-in calculator

**Status: no production code changed.** Frontend gained a pay-vs-earn slider; README / BUSINESS.md gained the pair-wide and Uniswap-adoption answers.

Confirmed from the shipping hook, not from memory:

- **One queue for the whole pair.** One full-range position, `tickLower`/`tickUpper` set once to the usable range. Not per tick.
- **A seat can hold one token.** `addToSeat` allows a zero leg. In range, `_liquidityForAmounts` takes the min of the two legs, so a zero leg mints **0 L**; the tokens go to float. Rent weights **token0 only** — a token1-only seat earns nothing.
- **Per-tick / per-seat ranges is the Uniswap-shaped v2, and it is not a config change.** `afterSwap` is one `BalanceDelta`. 32 queues × ticks is not a program. Fastest real v2: concentrate the one blob (`test_1_11`).
- **The project is only the queue.** The buy-in was missing from the demo. `frontend/index.html` now has rank / liquidity / ask / small volume / sweep / two markouts, with Quiet / Event / Back / Under / Over presets, on the same $1M five-seat book. Labeled ESTIMATE. Rank 4 stands in for seat 32.
- **Sustainable liquidity, not MEV protection.** Claim the half we earn. Do not also claim sandwiches.

Do not treat the calculator as a measurement. It is the identities with a flow mix the viewer types in.

---

## 2026-08-31 — Pitch rewrite: the docs were written for Uniswap engineers, and that was a miss

**Status: no production code changed. README, BUSINESS.md, frontend copy, and PITFALLS §7 pointers. The 172-test / 68-mutation board is untouched.**

### Why this session existed

The owner asked, bluntly, whether QUEUE is well implemented and interesting *from the Uniswap Foundation / hackathon-judge chair*, and whether a business person who barely knows DeFi could tell: what a queue is, why 32, why not 100, whether +36% is 36% more expensive trades, whether 32 desks cancelling bricks the pool, and whether benefits outweigh. The existing README and BUSINESS.md already had the right *answers* and the wrong *audience*. A CFO hears "pro-rata" and "+36% gas" and files this as a cartel with a 36% tax. A Foundation engineer files it as "order book bolted onto an AMM" and stops listening. Both readings were invited by the prose.

### Verdict from the panel (exploit / economic / state / periphery / triager), not from the pitch

- **Accounting quality is Foundation-grade.** Wei-exact front-first fill, conservation against PoolManager, mutation-driven paired-path closures, three live bugs found after 135 tests. This is not an audit.
- **The object is a 32-desk specialist venue, not a Uniswap pool and not MEV protection.** Theme fit is the weakest joint (PITFALLS 5.16). Do not reuse the spike's 4.33. Honest rubric this session: Original ~4, Unique Execution ~4–4.5, **Impact ~2–2.5**, Functionality ~4, Presentation *was* ~2.5 and is the thing this session changed.
- **"+36%" is a constant venue tax on a typical (head-only) swap, flat 1→32 seats (21 units).** It is not 36% of the notional, not a trading fee, not a worse price. A full-line walk is a *different* number (416k). Quote both or you are lying.
- **"32 cancel and the pool dies" is a category error as a revert, and a real thin-book run as economics.** `withdraw` does not destroy the seat. Empty book: swap no-ops, then v4's own price-limit revert, not QUEUE. 32 desks *can* empty the position. The failure mode the pitch should actually fear: they post `selfPrice = 0`, rent stops, the tail's deal becomes irrational.
- **32 is packing + quadratic `addToSeat` (2.61M) + scarcity.** 100 or 500 is not a bigger QUEUE. It is a different, currently unexecutable program.
- **Benefits outweigh only** where professional desks want first fill without more capital *and* passive capital is actually paid rent. In a retail aggregator pool: no.

### What changed in the docs

- `README.md` rewritten as the 15-minute read: 90-second version, when-to-use table, NYSE-seat vs DMV-line, ASCII flows, +36% in dollars, mass-exit translation, pros/cons by role, fear table, architecture picture. Leads with business language. **Diverges from `PLAN.md` §A.3's "say the technical sentence first"** — recorded as PITFALLS 7.11, owner-directed, do not silently revert.
- `BUSINESS.md` rewritten as the decision memo. Verdict-first. Worked examples, 662-row novelty check, gas table, limitations kept and moved to §14. Native-ETH hole named (it was a comment lie). CFO 90-second script is §16.
- `frontend/index.html` copy only (selectors untouched): hero, +36% card, 32-seat limit, footer counts 172 / 68. Hygiene `test_7_6` is the interlock.
- `PITFALLS.md` §7.10 marked partly closed; line-number citations into BUSINESS.md replaced with section refs (they rot; 7.5 already said so).

### What this session did **not** do, on purpose

No production code. No video. No broadcast. No concentrated-range v2. No syndicate wrapper. No audit. The mechanism is what it was yesterday; the claim about who it is for is now the one the panel would actually defend.

**Where to look:** `README.md` first, then `BUSINESS.md` §0 and §2. If those two do not tell a non-engineer what to do, the rewrite failed.

---

## 2026-08-29 — Phase 7a: the deployment path had never run, and four of our own instruments were wrong

**Status: 172 tests green, 68 mutations with zero survivors, six deployment tests passing against a
live Unichain Sepolia fork. The broadcast and the video are outstanding.**

### The finding that mattered

**Six phases were green while not one line of the actual deployment sequence had ever executed.**
Every suite in this repo reaches the pool one of two ways: `QueueHarness.seed()`, which is TEST-ONLY
code, or `_deployHookUnfunded` → `deployCodeTo`, which *places* a hook at an address of your
choosing. Neither is how a v4 hook reaches a chain. The real path is: mine a CREATE2 salt whose
address carries the permission bits → deploy through the canonical deterministic proxy →
`PoolManager.initialize` → `addToSeat` into a virgin position. Its first execution would have been a
live broadcast with a judge watching.

Fixed **structurally**, not by adding a script. The sequence lives in `script/QueueDeployBase.sol`
and is executed by two callers — `script/DeployQueue.s.sol` broadcasts it, `test/queue/Deploy.t.sol`
runs the same functions and asserts every beat — and the only thing that differs is who signs, behind
`_as` / `_stopActing`. `DeployFork.t.sol` then runs the same five tests against a live fork, which is
what actually proves the vendored `AddressConstants` is not stale, the CREATE2 proxy is present on
that chain, and the numbers are identical. (PITFALLS 5.81.)

### Four instruments that were wrong, in the session's own order

1. **`PLAN.md` §H.3's hook flag mask was stale** — `0x0840` for a contract whose permissions are
   `0x18C0`, four phases after `afterInitialize` and `beforeAddLiquidity` were added. §F.2 of the
   same document already recorded `0x18C0`: **the plan disagreed with itself.** Mining for a stale
   mask yields an address `BaseHook`'s constructor rejects, with no diagnosis attached. Now derived
   from `Hooks.Permissions` and asserted against `getHookPermissions()` by `test_7_1`. (5.82.)
2. **`test_2_20` and `test_2_21` were LAW 2 violations**, and `test_2_21` was worse than that: it
   re-initialized the IDENTICAL key, which `PoolManager` refuses from its own state before the hook
   is ever called, so it passed **whether or not `_afterInitialize` had an `AlreadyBound` guard at
   all**. Demonstrated by deleting the guard and watching both tests stay green in their old form.
   Both now unwrap v4's `CustomRevert.WrappedError` and assert the selector; kept honest by the new
   **M67**. (5.83, 5.84.)
3. **The frontend's four hardcoded call selectors were three-quarters wrong.** Written from memory;
   only `ownerOf(uint256)` was right. The failure mode is the worst available — an `eth_call` to a
   selector that does not exist returns EMPTY DATA, so the page renders zeros and looks like a
   working demo of an empty queue. Closed the way every writer/reader pair here is closed:
   `test_7_6` reads the page, extracts the live `const` bindings, and asserts each against the
   compiler's own. (5.85.)
4. **PITFALLS 5.79's corollary was violated by the agent who had just read it.** `forge test` was
   run while `mutate.py` held a mutant on disk, and the result was briefly believed. A hazard that
   recurs after being documented needs an interlock, not a louder note: `mutate.py` now publishes
   `.forge-snapshots/MUTATION_IN_PROGRESS` and `test_7_7` refuses to run when it sees one, while the
   campaign's own runs pass through on `QUEUE_MUTATION_RUN=1`. Both directions have a control.
   (5.86.)

### Two wrong predictions, written down next to the right answers

- **"A 400e18 sweep will walk several seats."** It touched exactly one. The allocator was correct and
  the trade was small: the queue IS the pool's liquidity, so reaching rank 2 means removing ranks 0
  and 1's whole stock of the outgoing token from a FULL-RANGE position, and a constant-product curve
  releases 60% of a leg only for a 6.25x price move. 2,500e18 walks it. **This is the measured form
  of the README's "the back is reached only by trades large enough to sweep the front", and it is
  5.17 (thin full-range depth) showing up in the demo.** (5.87.)
- **"Settling rent reduces `escrowTotal`."** It does not — `_distributeRent` moves the money from the
  payer's escrow to the recipients' escrow, so the total is CONSERVED, exactly as `AGENTS.md` says
  ("rent moves escrow to escrow"). The draft assertion would have passed against a *leaking*
  implementation. Replaced with the identity: payer falls by `due`, the seats behind rise by `due` in
  total, `escrowTotal` unchanged, `unallocatedRent0` zero while eligible recipients exist — which is
  also the business model stated as an assertion. (5.88, and 5.53 again.)

### Decisions taken under ambiguity

- **Built a frontend, against `PLAN.md` §H.4's "do not build a frontend just in case."** That
  guidance was written when the mechanism was unproven and a frontend would have been a distraction.
  The mechanism is now proven and the remaining score sits almost entirely in what a judge can see.
  It is one static file, read-only, no build step and no server — so it is a *viewer*, not an
  off-chain component, and §6.1 is untouched. Its simulator was validated against the contract before
  being trusted: 2,500 in gives 3,745.7 on the page and 3,746.34 on chain, 0.02% apart.
- **The demo needs exactly two signing accounts**, not five. The counterparty key is derived
  deterministically from the deployer's, so the operator manages one secret. Every extra funded
  testnet key is another way for a live demo to fail.
- **Sharpened the "so it isn't really a queue" answer in the README.** The old framing conceded a
  "closed roster", which is false: under an always-for-sale lease anyone may enter at any moment at a
  price the incumbent posted. What is scarce is the SLOT, not the PARTICIPANT. The stronger and more
  accurate statement is that every market prices queue position, most price it in *time* which is
  burnt on infrastructure and paid to nobody, and QUEUE prices it in money paid to the LPs you are
  standing in front of.

### Two things the product was missing, found by trying to use it

- **The pool a deployed hook serves was not readable on chain at all.** `key` is written once by
  `_afterInitialize`, the contract emits no event of its own, and every field was `internal` — so an
  integrator had to scan `PoolManager`'s `Initialize` logs and match on the hook address, and
  anything wanting the token *decimals* to render a balance simply could not. The frontend was
  hardcoding 18/6 to work around it, which would have shown balances a million times off on any
  other deployment, silently. Closed with `pool()`, a pure-disclosure view returning the key, the
  bound flag and the two ticks. `isBound` is returned rather than inferred from a zero key because
  `Currency.wrap(address(0))` is legal native ETH. **A hook that cannot say what it is attached to
  is not integrable.** (PITFALLS 5.89, 5.90; mutation M68.)
- **§5.17 — thin full-range depth, "the sharpest unanswered attack" — now has half an answer, and
  it is executed rather than argued.** The row always claimed the range was "a reversible design
  choice, not a v4 constraint"; that was ANALYSIS. `tickLower`/`tickUpper` turn out to appear in
  exactly two places — the sizing helpers and `modifyLiquidity` — and nowhere in the allocator, which
  sees only realised deltas. `test_1_11` seeds the identical roster over a **±10% band** and runs
  both directions against the independent witness: conservation, per-seat composition and INVARIANT
  C hold to the wei, and the sweep exhausts the head exactly as at full range. **Concentrating the
  custodied position is a v2 parameter, not a redesign.** Still unbuilt and NOT claimed: out-of-range
  behaviour, rebalancing, the depth/coverage trade-off. (PITFALLS 5.17, upgraded.)

### A third wrong prediction, worth recording because it was about a CONTROL

The first negative control for `test_1_11` mutated `_allocate` to index by seat id instead of rank
(M5) and the test stayed **green** — which briefly read as the new test having no teeth. It does not.
The founding order is the identity permutation, so `_idAt(ord, i) == i` wherever nothing has been
foreclosed, and that mutation is a genuine no-op in this fixture; M5 is caught by the rank suites,
which permute the order. The replacement controls discriminate: M60 makes it revert, and forcing the
range back to full makes the narrowness guard fire naming both numbers. **Before concluding a test is
weak, check the control can be detected in that fixture at all.** (PITFALLS 5.91.)

### What is left

The broadcast (needs a funded Unichain Sepolia key) and the video. Everything the broadcast will do
is already executed and asserted against a fork of that chain, so the remaining risk there is
operational, not mechanical.


**Where to look for status, so nobody has to read the log to find it:** `PLAN.md` opens with a
**BUILD STATUS** dashboard, each completed phase carries a ✅ block at its own §C section, and the
individual exit criteria inside those sections are ticked one by one. This board mirrors it. If the
two ever disagree, PLAN's dashboard and the ticked criteria win, because they sit next to the
criteria they describe.

**Verified 2026-08-29 (end of the Phase 7a session):** `forge test` is **172 passed / 0 failed /
1 loudly skipped** (`DeployFork.t.sol`, off unless `QUEUE_FORK=true`, because the default suite must
not need a network). `forge lint src/` CLEAN. `python3 script/mutate.py` runs **67 mutations with
ZERO survivors**. The six deployment tests also pass **against a live fork of Unichain Sepolia**,
producing numbers identical to the local run.

*(Superseded — 2026-08-28, end of the Phase 6 session:* Phases 0-6 are done. `forge test` is
**163/163 green**, `forge lint src/` is CLEAN with zero notes, and `python3 script/mutate.py` runs
**66 mutations with ZERO survivors**. **The Phase 6 campaign found THREE REAL BUGS in code that had
already passed 135 tests and 61 mutations**, all reachable through the ordinary public API — see the
entry below and PITFALLS 5.73-5.80.*)*

*(Superseded — 2026-08-28, end of the Phase 5 session:* Phases 0-5 are done. `forge test` is
**135/135 green**, `forge lint src/` is CLEAN, `script/mutate.py` runs **61 mutations with ZERO
survivors**. **Every gas number recorded before that session was optimistic** and all three affected
tests were re-measured — see LAW 4.*)*

*(Superseded — 2026-08-27, end of the Phase 4 session:* Phases 0-4 are done. `src/queue/QueueHook.sol`,
`src/queue/QueueSeats.sol`, `src/queue/libraries/Allocation.sol` and `src/queue/libraries/Rent.sol`
are the mechanism. `forge test` is **125/125 green** and `forge lint src/` is CLEAN with zero notes.
`python3 script/mutate.py` runs 53 mutations against the Phase 4 code and **none survive**.*)*

*(Superseded — earlier the same day:* Phases 0-3 are done. `src/queue/QueueHook.sol`,
`src/queue/QueueSeats.sol` and `src/queue/libraries/Allocation.sol` are the mechanism. `forge test`
is **77/77 green** and `forge lint src/` is CLEAN with zero notes.*)*

*(Superseded — earlier the same day:* Phases 0, 1 and 2 are done, 59/59 green.*)*

*(Superseded — 2026-08-26 doc-audit:* every row above is still accurate — **no `src/` directory exists
at the repo root** and no mechanism code has been written.*)* The two 2026-08-26 sessions below produced
research and documents only. `PITFALLS.md` §5 is the standing list of what is open.

---

## 2026-08-28 — Phase 5: the gas numbers were all wrong, and the roster bound was never justified

**Status: COMPLETE. 135/135 green, `forge lint src/` clean, 61 mutations with ZERO survivors.**

### The finding that mattered was not a gas number

I set out to reproduce §B.9's table against our hook. The first honest table disagreed with the EVM
cost model by about 35%, which is the sort of gap you are supposed to chase rather than round off.
It resolved into something that invalidated every gas figure this project had ever recorded:

> **`vm.cool()` restores cold ACCESS pricing. It does not restore cold WRITE pricing.**

`vm.cool()` resets the EIP-2929 access list, so the next `SLOAD` costs 2,100 again. EIP-2200 meters
a *write* against the slot's value **at the start of the transaction** — and a slot the current test
body already wrote is "dirty", so writing it again costs **100 gas** instead of 2,900 or 20,000. A
suite that deploys, seeds and then measures inside one test body is measuring a contract whose
entire storage is free to write.

Measured, same swap, same `vm.cool()`:

| | gas |
|---|---:|
| roster seeded **in the test body** | 172,263 |
| roster seeded **in `setUp()`** | 252,966 |

**47% optimistic.** Forge commits `setUp()` as its own transaction, so state built there is metered
honestly. `vm.snapshotState()` + `vm.revertToState()` is not a substitute — I tested it, identical
numbers to the wei. **LAW 4 is amended** and PITFALLS 5.66 carries it.

Three existing tests were affected. All three were re-measured from `setUp()`-built state, and the
optimistic copies were deleted rather than left standing next to the honest ones:

| test | was | now |
|---|---:|---:|
| head-only flatness (`Allocator.t.sol`) | — | moved to `test_5_1` |
| pure-rank transfer (`test_3_16`) | 24,969 | **23,208** (it went *down*: packing more than paid for the correction) |
| worst-case `addToSeat` (`test_4_44`) | 2,337,576 | **2,610,805** |

### And a second measurement artefact that produced a confident, wrong story

The first table showed a 21,179-gas excess on its depth-1 row. I explained it twice — swap size,
then `cursor1`'s first non-zero write — and both explanations were plausible and wrong. Running the
identical pair of measurements **in both orders** settled it: the excess followed the ORDER, not the
depth. `vm.cool` is per-account and a v4 swap crosses six of them; the first call in a test body
warms whatever was not named. Comparative series now burn a swap on a roster they never measure
(PITFALLS 5.67).

### §B.9's table was a different contract, and `MAX_SEATS = 32` was not justified by it

§B.9 quoted **6,753 gas per seat** from the Phase-0 spike — no cursors, no owners, no seat tokens,
no lease — and chose the roster bound as "comfortably inside a 300k budget". Re-measured against the
shipping hook:

| | per seat | queue cost at 32 seats | verdict |
|---|---:|---:|---|
| §B.9's inherited figure | 6,753 | 216,096 | ✅ (but not this contract) |
| this hook, measured | **12,254** | **412,028** | ❌ **37% over budget** |
| after Phase 5b's packing | **8,070** | **278,110** | ✅ 7% to spare |

The bound was never justified by the numbers written next to it. `test_5_3b` now **derives** the
supportable depth (34 seats) from the measurement and asserts it is at least `MAX_SEATS`, so the
constant in the source and the number in the document cannot drift apart again.

### The honest table (`test/queue/Gas.t.sol`)

Complete swap transactions through the real router and PoolManager — what a trader pays. State built
in `setUp()`, all six accounts cooled, a warm-up burned first, and **the swap size held constant
across the sweep series** so the pool's own work cancels exactly rather than approximately.

| seats | head-only | full sweep |
|---:|---:|---:|
| 1 | 117,971 | 145,980 |
| 2 | 117,989 | 173,950 |
| 5 | 117,990 | 198,161 |
| 10 | 117,990 | 238,511 |
| 25 | 117,991 | 359,562 |
| 32 | 117,992 | **416,053** |

> `sweep(n) = 137,866 + 8,070·n + 19,900·[n ≥ 2]` — reproduces every row to within **3 gas**.

- **Head-only is flat: a 21-gas spread from 1 to 32 seats.** That is the cursors working.
- **The slope is exactly 8,070**, identical between every adjacent pair, not a fitted approximation.
- **The 19,900 one-off** is `cursor1`'s first non-zero write: `0 → 0` costs 2,200 at depth 1,
  `0 → nonzero` costs 22,100 at every greater depth. Predicted 19,900, measured 19,900.

Against **no hook at all** — same tokens, fee, spacing, price, full-range liquidity, same swap —
QUEUE costs **117,989 vs 86,820: +31,169 gas, +36%.** Say that number. The defensible claim is not
"the common case is free"; it is that the overhead is a **constant a trader can price** rather than
something that grows with book depth.

### 5b — what shipped, and what was measured and rejected

**Shipped: the seat balance pair packed into one slot** (`uint128 a0; uint128 a1;`), with every
narrowing in the contract routed through one checked `_u128` that reverts rather than wraps. The
bound cannot bind on anything Uniswap can represent — v4 settles in `int128` deltas, so no position
it can account for holds `2^127` of either token — but it is checked anyway, because a silent wrap
would mint balance out of nothing.

| | before | after |
|---|---:|---:|
| gas per seat walked | 12,254 | **8,070** (−34%) |
| full 32-seat sweep | 549,897 | **416,053** (−24%) |
| head-only swap | 122,130 | **117,990** |

**Rejected, with numbers (PITFALLS 5.70):**

- **Copying the packed seat through memory** to force one `SLOAD`/one `SSTORE`: **worse** — 8,477
  vs 8,070. The memory round-trip costs more than the compiler's masking.
- **Hoisting `q.length` into an immutable**, since the roster is fixed at construction: **85 gas per
  swap, 0.07%** — and it broke `test_3_9`, the control that mints a seat at runtime to prove Phase
  3's fixed roster is load-bearing. It had created a *second copy of the roster size*, so the
  control's new seat became invisible to the allocator. A 0.07% optimisation reintroducing the
  writer/reader class that has been wrong four times on this project. Reverted.

### 5c — the O(1) prefix-sum redesign is NOT SHIPPED

§C.5 gates it behind "only if 5a/5b leave a real problem". They did not: the common case is flat and
cheap, the full sweep is 1.4% of a 30M block, and the queue-attributable cost is inside the stated
budget. §B.11's objection is also still unanswered — **the remainder line has no lazy analogue**,
because a prefix-sum accumulator does not know which seat is "the last one filled" at the moment the
scalar is updated. Shipping a subtly non-conservative allocator to save gas on a book already inside
budget would trade the one property QUEUE has for nothing. Criterion 5.6 is satisfied by *not*
building it, and this paragraph is the record §C.5 asks for.

### Mutation testing found something for the eighth consecutive time

61 mutations, and **M61 survived**: `Allocation.allocate` returned a `nextCursor` computed by its own
copy of INVARIANT C's "advance only if the seat was exhausted" rule. Every call site discarded it,
and **no production path calls that function at all** — it exists so the arithmetic can be fuzzed
without a pool.

So a production library was carrying an untested second copy of the single rule whose failure mode
is silent theft of rank, in the exact family that has been wrong four times here. The honest answer
was **(b) delete the line** — the second time on this project after `_demoteToTail`'s early return.
Testing it would have entrenched the duplicate. The cursor already has an *independent* witness in
`QueueFixture`, written from §B.6's prose rather than from `src/`, asserted after every swap. M61 now
targets the hook's real copy and goes red.

The harness also gained `Allocation.sol` as a mutation target, which it never had — including the
remainder line, the most load-bearing line in the project (M59).

### What I would flag

- **The worst-case `addToSeat` at 2,610,805 gas is the binding constraint on the roster, not the
  sweep.** `_settleAhead` is O(priced ahead × roster) where the sweep is linear. At 32 seats it is
  8.7% of a 30M block, which is fine; at 64 it would be roughly four times that. Any future proposal
  to raise `MAX_SEATS` has to be argued against that number (PITFALLS 5.72).
- **+36% per swap against a bare pool is a real cost** and should be in the pitch as a number, not
  as "negligible".
- Two of my own three explanations for the depth-1 anomaly were wrong before the order-swap test
  settled it. The pattern is worth remembering: a plausible mechanism that predicts roughly the
  right magnitude is not evidence.

---

## 2026-08-27 — Phase 4: rank gets a price, and §B.10's payment source turned out to be broken

**Status: COMPLETE. 125/125 green, `forge lint src/` clean, 53 mutations run against the new code
with ZERO survivors.**

### What Phase 4 was for

Three things the Phase 3 state would have had to disclose on camera, all of which close in one
mechanism: the founding roster was an endowment nobody had bid for; the tail had no compensation
channel at all, so the honest answer to *"why would anyone hold seat 5?"* was "they wouldn't"; and
rank-then-run was free. Harberger is the only thing that gives rank a continuous on-chain price
without needing the secondary market PITFALLS 5.11 says does not exist.

### The plan's specified payment source is broken, and not at the margin

§B.10 said rent is *"deducted from the seat's own `a0`"*. Built literally, that is unshippable, and
it took two independent arguments to be sure rather than one:

1. **Front-first allocation drives seats to single-token composition ON PURPOSE**, and INVARIANT C —
   asserted in every test since Phase 1 — states the consequence outright: *every seat below
   `cursor0` holds `a0 == 0`.* So after any sustained run of one-for-zero flow the FRONT seats hold
   exactly zero of the rent currency and get foreclosed, one after another, **because of the
   direction the market happened to trade.** Rank would be set by flow instead of by price, which is
   the one thing QUEUE claims it is not.
2. **An EMPTY seat is pure rank**, which Phase 3 exists to make holdable and sellable. Under `a0`
   rent it cannot be held at any price above zero at all. The spec's payment source is incompatible
   with the object it prices.

Owner decision, taken before any of it was built: rent is drawn from a **per-seat prepaid meter** in
`currency0`, held outside the position, outside `float0` and outside the allocator — so Phase 4 adds
nothing to the proven Phase 1–3 arithmetic. It is a meter, not collateral: nothing marks it, nothing
values it against anything, nobody is paid to seize it, and running it dry costs a place in the queue
rather than the seat or its capital. Both arguments are executed side by side against the spec's own
implementation in `test_4_13` and `test_4_13b`.

### The firm quote, which is not in the plan and without which Harberger delivers nothing

"Always for sale at your own price" is worth nothing if the holder can raise the price the instant
they see a buyer — and they can see one, because a buyout is an ordinary transaction in an ordinary
mempool. Repricing costs only rent for the seconds the raise is in effect: at τ = 10%/yr that is
**four parts in ten million of the price per block.** Effectively free. Left alone, EVERY buyout is
vetoable and Phase 4 would have shipped a rent tax with an always-for-sale slogan on it.

So an ask is FIRM: **the seat stays available at the lowest price it has been asked at, or paid for,
within `FIRM_WINDOW`.** A raise takes effect immediately for RENT and only after the window for the
SALE. The three ways out are each self-destructive rather than merely refused, and all three are
executed: raising blocks nothing because the old price is still firm; dropping to zero and re-raising
atomically makes the window minimum ZERO; handing the seat to your own second address arms the
window at what was paid for it, which for a plain transfer is zero.

### Four more things that were found rather than designed

- **The flash-loan rent grab.** Rent is split by the recipients' `currency0` balance read at
  settlement, and funding a seat is the only way a holder can raise that number at will. So
  `addToSeat(tail, huge) → settleRent(everyoneAhead) → withdraw(tail)` captures rent accrued over a
  period the depositor was not there for, in one transaction, with borrowed money — **measured at
  16× the honest share.** Closed by settling every seat ahead first. A per-block cooldown would also
  close it and is the wrong instrument: §B.12 counts "waiting one block boundary" as a proven
  evasion and QUEUE passes that table precisely because it has no per-block reference.
- **A buyout paying the seller directly would hand every incumbent a veto over their own buyout** —
  a seller that is a contract refuses payment and the sale reverts. The price is credited as a
  `pendingWithdraw` claim instead, which is the same unblockability argument Phase 3 made for the
  evacuation path.
- **`selfPrice` had to be bounded.** An unbounded assessment overflows the rent product, and a
  settlement that reverts is a seat that can never be foreclosed OR bought — and `_settleAhead`
  would carry that revert into every deposit behind it. Bounded at `type(uint128).max`, above
  anything v4 itself can represent.
- **Seat id stopped being rank index**, because foreclosure permutes the queue. The order lives in
  ONE `uint256`, one seat id per byte, which is why `MAX_SEATS` is 32: the roster bound and the 32
  bytes of a word are the same fact. There is deliberately no `rankOfId` mapping — a second copy of
  the order is a writer/reader pair that can disagree, and on this project that has been wrong four
  times. `rankOfId` scans the word.

### The mutation campaign, which is the part worth reading

The suite was **99/99 green** and every review lens had been walked before `script/mutate.py` ran for
the first time. It left **21 of 53 mutations alive.** Among them:

- **anyone could drain anyone's rent meter** (`withdrawRent` had no ownership check under test), and
- **anyone could reprice anyone's seat** — which is not griefing but theft: set a rival's price to
  zero and buy their seat. Both entry points were new, both were completely untested, and neither
  was caught by reading the code.
- **Every foreclosure test demoted SEAT 0 FROM RANK 0.** `0 << anything` is `0`, so a demotion that
  wrote the seat id back at the WRONG byte offset was invisible to all of them, as was cursor1's
  copy of the pull-back rule, as was the funding pull-back comparing an id where it should compare a
  rank. Four separate defects hiding behind one convenient fixture.
- **A gas optimisation I had added myself re-opened the dodge it was meant to stop.** The lease reset
  in `_onSeatTransfer` is skipped when the seat is already in the post-transfer state — but the
  predicate was evaluated AFTER settlement, and settlement can FORECLOSE the seat, which zeroes
  `selfPrice`. So a holder could arm nothing at all by letting their own unfunded seat foreclose on
  the way through a self-transfer, then reprice with no firm quote against them. Fixed by reading
  the predicate before settling; `test_4_12` executes the sequence.

One mutation could not be killed and the line was **deleted** instead (PITFALLS 5.49 again): the
"already at the tail" early return in `_demoteToTail` is exactly equivalent to the general path.

Seventh consecutive time mutation testing has found a real defect on this project. First time it
found an unguarded external entry point.

### What is honestly still open

- **Harberger cannot express a negative seat value** (5.10). Under toxic flow everyone declares near
  zero, no rent flows, and the front is free to take. Correct behaviour, and the point at which the
  signal is censored. Unsolved, and not solvable inside this design.
- **Rent is `currency0` and weighted by `currency0`**, because weighting a two-token basket needs a
  price and §E.11 forbids one. A tail holding only `currency1` is not an eligible recipient and the
  rent waits in `unallocatedRent0`. `test_4_43` asserts exactly this rather than hiding it.
- **Enforcement needs somebody to call `settleRent`.** No keeper ships and none is required — the
  seats behind are paid by it, and a would-be buyer must call it to clear a delinquent incumbent out
  of the way — but a seat nobody wants and nobody pokes accrues a debt nothing collects.
- **Worst-case `addToSeat` is 2,337,576 gas** at a full 32-seat roster with every seat ahead priced
  and funded. It fits a 30M block thirteen times over, and the configuration costs the attacker rent
  paid to the very seat they are trying to price out — but it is a real cost of closing the grab and
  it is measured rather than assumed (`test_4_44`).
- **Full-range depth** (5.17) is untouched and remains the sharpest attack on the premise.

## Carried forward from the design phase — what is ALREADY PROVEN

These were established by executed experiments before the build started. Evidence lives in
`archive/2026-08-26/`.

> ### ⚠ READ THIS BEFORE QUOTING ANY NUMBER BELOW
> **Three rows of this table were measured on the SPIKE, not on the shipping hook, and two of them
> are now known to be WRONG.** The spike had no cursors, no owners, no seat tokens and no lease.
> "Do not re-derive them" was the wrong instruction and it is withdrawn: a measurement inherited
> from an earlier prototype is not a measurement of the thing you are shipping (PITFALLS 5.68).
> Superseded rows are marked inline. The live gas table is `PLAN.md` §B.9 and `test/queue/Gas.t.sol`;
> the live residual claim is PITFALLS 5.80.

| Claim | Status | Evidence |
|---|---|---|
| Front-first allocation at the swap's realised average price is **exact to the wei in both tokens at a non-unit price (1:4)** | **PROVEN** | `archive/2026-08-26/test/spike/QueueAllocator.t.sol`, 9 tests; conservation measured on PoolManager's own ERC20 balances |
| The remainder-assignment line is load-bearing | **PROVEN** | Negative control: floor-only mutation survives swap 1 and dies at swap 2 |
| Pro-rata allocation and an off-by-one cursor both break it | **PROVEN** | Two further negative controls, both red, revert reasons asserted |
| ~~Head-only swap gas is flat at ~31,874~~ | ⚠ **SUPERSEDED — spike figure, and measured with `vm.cool()` alone, which meters writes at 100 gas instead of 2,900 (LAW 4 as amended).** The shipping hook's head-only swap is **117,971–117,992 gas**, still flat (a 21-gas spread from 1 to 32 seats), re-measured with state built in `setUp()`. PITFALLS 5.66 | `test/queue/Gas.t.sol` `test_5_1` |
| ~~A sweeping swap is O(entries) at ~6,753 gas/entry; ~44 seats at a 300k budget~~ | ⚠ **SUPERSEDED AND THE `MAX_SEATS` JUSTIFICATION IT SUPPORTED WAS FALSE.** Re-measured on the shipping hook: **12,254 gas/seat**, i.e. **37% OVER** the budget the roster bound was picked to fit. Phase 5b's packing brought it to **8,070**. And the real bound is `addToSeat` at **2,610,805 gas** (quadratic), not the sweep. PITFALLS 5.68, 5.72 | `test_5_3`, `test_5_3b`, `test_5_6` |
| ~~A **~0.26 wei/swap** redemption residual exists; the last withdrawer eats it~~ | ⚠ **HALF SUPERSEDED.** The *last withdrawer eats it* half is right and still shipped (dust policy F1 spreads it over withdrawers). The *per-swap constant* half **does not generalise**: the truncation scales with price displacement, and a drained pool at the tick floor loses **~1e9 wei on one swap**. What generalises is the ratio against **lifetime inflow**: worst shortfall **under 1 ppb**, worst surplus **exactly 0 wei**. PITFALLS 5.80 | `Invariant.t.sol` `K`; `QueueHandler::_noteSolvency` |
| That residual is **NOT** fee-growth truncation | **FALSIFIED** by a zero-fee pool retaining 88% of the drift | Spike §Q1 |
| The residual is **unfarmable** — cost-to-damage off by ~20 orders of magnitude | **REASONED from measurement** | Spike §Q1 |
| No forgeable-proof toxicity signal exists for a v4 hook | **PROVEN** | `archive/2026-08-26/docs/research/IDEAS_CONSTRAINED.md` §1 |
| No static curve can improve adverse selection per unit of depth | **PROVEN** | `archive/2026-08-26/docs/research/IDEAS_CURVES.md` §0 |
| A v4 hook can never see or pay the trader | **PROVEN** | `archive/2026-08-26/CLAUDE.md` §5 items 16 and 18 *(root `CLAUDE.md` is a symlink to `AGENTS.md` and has no §5.16 — the old citation was unfollowable)*; `PITFALLS.md` §1.14, §4.3 |

## Carried forward — what is OPEN

**`PITFALLS.md` §5 is the authoritative list of open hazards** — it is longer than this table and
each row carries its evidence grade. The rows below are the headline items and point into it.

| Item | Why it matters | Where | Ledger row |
|---|---|---|---|
| ✅ ~~**Redemption dust fix**~~ | **CLOSED Phase 2** — dust policy F1 pays `min(face, available)`. The claim *"the queue's face value is redeemable"* is **still barred**, and Phase 6 measured the bound honestly: under 1 ppb of lifetime inflow, borne by the last holders to exit | `PLAN.md` §B.7 | `PITFALLS.md` §5.7, §5.80 |
| ✅ ~~**Per-seat withdrawal feasibility**~~ — **CLOSED Phase 2** by the shared float; §B.7 corrected in place | **MEASURED:** §B.7's withdraw spec is impossible as specified — seat 1 holds 258.877 token0 / 0 token1 and can withdraw nothing via `modifyLiquidity(−Δ)`. A **Phase 2 BLOCKER**, and the second reason the face-value claim is barred. `withdraw` must never call `poolManager.swap` | `PLAN.md` §B.7 (not yet corrected); `docs/research/protocol-fee/queue-exposure.md` §A2 | `PITFALLS.md` §5.5, §5.6 |
| ✅ ~~**Protocol fee remedy P2**~~ — **CLOSED Phase 1**, built and asserted at max fee, `lpFee == 0`, and against a foreign pool | Hazard is MEASURED and real. **Owner decided 2026-08-26: ship P2** (net out `protocolFeesAccrued` in `_afterSwap`), **not** the refusal this row previously named. Phase 1 must build it and assert against `PoolManager balance − protocolFeesAccrued` / `redeemAll()`, having first asserted `protocolFeesAccrued > 0` | `PLAN.md` §E.5, Phase 1 acceptance 1.10 | `PITFALLS.md` §3.1, §5.1–§5.4 |
| **LAW 3 is amended** | Conservation must net out `protocolFeesAccrued`; the raw-balance form is blind to this bug class. Now stated in `AGENTS.md` §3.3 **and** `PLAN.md` §D.1 LAW 3 | `docs/research/protocol-fee/experiment.md` | `PITFALLS.md` §2.6 |
| ✅ ~~**Rank-then-run hole**~~ — **CLOSED Phase 4** by the firm quote; asserted in `test_6_11`. The negative-seat-value gap it names is still OPEN | Plain-token rank can be abandoned before a scheduled event; only the Harberger variant closes it — and Harberger has its own unsolved gap (it cannot express a negative seat value) | `PLAN.md` Phase 4 | `PITFALLS.md` §5.9, §5.10 |
| ⛔ **O(1) prefix-sum redesign** | **DECIDED PHASE 5: NOT SHIPPED, and do not reopen without new evidence.** §C.5 gated it behind "only if 5a/5b leave a real problem"; they did not. Its objection is also unanswered — a prefix-sum accumulator does not know which seat is "the last one filled" when the scalar is updated, so the remainder line has no lazy analogue | `PLAN.md` §B.11 | `PITFALLS.md` §5.12, §3.16 |
| **Phase 6's three bugs are FIXED, but their FAMILIES are standing** | The cursor bug was the **fifth** instance of "one rule, two places"; the unsigned measurement was the first of "predicting a balance change's sign from the request"; the periphery helper was the first of "a non-binding leg decides the outcome". Every new external path, every new measurement, and every new use of a periphery helper inherits these | `AGENTS.md` §3b | `PITFALLS.md` §5.73, §5.74, §5.76, §5.77 |
| **Harberger cannot express a negative seat value** | Under toxic flow everyone declares near zero, no rent flows, and the front is free to take. **This is the headline unsolved item** and it sits exactly where the cohort's problem statement points | `README.md` | `PITFALLS.md` §5.10 |
| **Enforcement needs somebody to poke `settleRent`** | Nothing ships that does and none is required, but a seat nobody wants and nobody pokes accrues a debt nothing collects | `README.md` | `PITFALLS.md` §5.64 |
| **Seat governance** | Rank must be bought or Harberger-held, **never granted by deposit order** (dust-griefing the head). Phase 2's append-at-tail is provisional and must carry a named known-hole test | `BUSINESS.md` §8; `PLAN.md` §B.8, §E.16 | `PITFALLS.md` §3.8, §5.8 |
| **Theme framing** | The honest bridge to "Sustainable Liquidity and MEV Protection" is the weakest part of the pitch | `BUSINESS.md` §10 | `PITFALLS.md` §5.16 |
| **Full-range capital efficiency** | The sharpest unanswered attack, and **absent from `BUSINESS.md` and `PLAN.md` entirely**. [ANALYSIS] | `docs/research/premise-review/economics.md` §6 | `PITFALLS.md` §5.17 |
| **The Ratchet · the one-sided Phase 3 market · "the seat price IS the toxicity" is overclaimed** | Three pitch-level contradictions named nowhere in the live docs. [ANALYSIS] | `docs/research/premise-review/` | `PITFALLS.md` §5.18, §5.19, §5.20 |
| **Proposal 100 / live protocol fees** | Press-sourced only. **UNVERIFIED** — check on-chain before relying on it | `docs/research/protocol-fee/v4-mechanics.md` §9 | `PITFALLS.md` §5.15 |
| **Standing pitfalls ledger** | Every hazard, testing trap, settled decision and proven-impossible item, with its evidence status — **re-read at the start of every session**. §7 lists where two docs disagree | `PITFALLS.md` | — |

---

## Session log

### 2026-08-28 — PHASE 6 COMPLETE. The campaign found three real bugs, and the product was reframed.

**Result: `forge test` 163/163 green · `forge lint src/` clean · 66 mutations, ZERO survivors ·
§D.8 GATE 6 PASS.**

#### What was built

| File | What it is |
|---|---|
| `test/queue/handlers/QueueHandler.sol` | The bounded actor. Twelve actions, `bound()`ed inputs, four actors, a ghost ledger built from handler inputs and token flows measured across the hook's boundary — never from `hook.totals()`, which is the thing under test |
| `test/queue/Invariant.t.sol` | 11 invariants × 256 runs × 64 depth. `targetContract` **and** `targetSelector` both set. Plus `test_6_0`, a deterministic 500-call campaign asserting every invariant after **every single call** |
| `test/queue/Adversarial.t.sol` | 15 tests: every named attack in §C.6 with an asserted outcome, plus a directed regression for each bug found |
| `script/mutate.py --campaign` | Runs a mutation against the INVARIANT SUITE ONLY and names the invariant that caught it — §D.8 V3's actual requirement, which "the full suite goes red" does not satisfy |

#### THE THREE BUGS. All reachable through the public API. None visible to 135 tests.

**1. The degenerate fill left a cursor LEADING a funded seat (PITFALLS 5.73).** A swap whose output
rounds to zero credits its whole input to one seat. `_allocate` has always pulled the incoming
token's cursor back after crediting; **the degenerate path never did.** Once `cursor0` leads rank 0,
every later one-for-zero swap starts *behind a funded seat* and sources from further back — the head
is passed over, which is exactly the theft of rank the mechanism exists to prevent. The credited
amount is dust; the cursor corruption is not dust-bounded. **Fifth instance of "one rule, two places,
right in only one of them"** (5.37, 5.50, 5.52 ×2, 5.62).

**2. An ADD can CREDIT the caller, and the measurement was unsigned (PITFALLS 5.74).**
`modifyLiquidity` realises the position's accrued fees on every call and returns
`callerDelta = principalDelta + feesAccrued`. When the fees exceed the principal being added — the
ordinary state of a busy pool between two deposits — the hook's balance goes **up** on an **add**,
and `unlockCallback`'s `b0Before - balanceAfter` underflowed. **`addToSeat` and
`sweepFloatIntoPosition`, the only two paths capital has INTO the queue, reverted with an arithmetic
panic for as long as the fees stood.** Fixed with a signed measurement (`_moved`) plus a named
`UnexpectedPositionDebit` guard on the removal side, where the sign genuinely is predictable. **Rule:
never predict the SIGN of a balance change from the sign of the request you made.**

**3. Liquidity sizing reverted at a tick boundary — on BOTH sides (PITFALLS 5.76, 5.77).**
v4-periphery's `getLiquidityForAmounts` computes both legs and narrows **each** to `uint128` before
taking the minimum, so the non-binding leg decides the outcome: measured, depositing 393e18 of token1
reverted `SafeCastOverflow` while the binding leg was **1,033**. And on the removal side,
`_liquidityToCover` divided by a span that goes to zero at the tick — `FullMath.mulDiv` answers a
bare `require`, so the call died with **empty revert data** and both `withdraw` and `_onSeatTransfer`
were blocked. **The evacuation one is the serious half**: §B.8 made that path unblockable on purpose
because the buyout leans on it, so a holder at the tick boundary could not be bought out — the exact
incumbent veto Phase 3 removed. Fixed by taking the minimum in 256 bits, clamping to
`Pool.tickSpacingToMaxLiquidityPerTick`, and treating a zero span as "this leg cannot be sourced".

#### Two things that were WRONG IN OUR OWN INSTRUMENTS, not in the code

**`_positionValue()` overstated the position by 8.28e18 wei (5.75).** `minUsableTick(60)` is -887220
and `MIN_TICK` is -887272, so a "full-range" position's range **can be left**, and the estimator was
computing `getAmount0Delta(sqrtP, hi, L)` with an unclamped price. INVARIANT F looked broken while the
ledger was correct to 12 wei. **Two wrong explanations were entertained before the instrument was
suspected.** After clamping it agrees with a real `redeemAll()` exactly over a 500-call campaign.

**`script/mutate.py` left a mutant on disk when interrupted (5.79).** It restored the source only on
the happy path. An interrupted run left the 5.77 guard absent, a whole campaign ran against the
mutated hook, and the **only** symptom was a `BAD-PATTERN` on the one mutation targeting that exact
line. Had that mutation not existed the repository would have silently regressed. Fixed with
`try/finally` and a report of every file it had to put back.

#### Two things §C.6 asked for that rested on FALSE PREMISES — corrected in place, not dropped

- **I6 named `seatIndex`/`indexSeat`**, which Phase 4 deliberately replaced with one packed word and
  a scanning `rankOfId` so there is no second copy of the order. Live form asserted instead: `order`
  is a permutation of `0..n-1` and `rankOfId(idAtRank(r)) == r` at every rank.
- **"A swap one wei larger than the queue → `QueueUnderflow`" — there is no such swap** (5.78). A
  swap takes out only what the POSITION holds; INVARIANT F says the position never exceeds the ledger
  (**surplus measured at exactly 0 wei** across the whole campaign); INVARIANT C says everything
  below the cursor is empty. `QueueUnderflow` is not a trader-reachable boundary — it is the loud
  failure that fires when the ledger and the position have come apart.

#### The residual claim was corrected (5.80)

"~0.15 wei per swap, linear and converging" holds **at the seeded price and nowhere else**. The
truncation scales with price displacement: a drained pool pushed to the tick floor loses ~1e9 wei on
one swap. What generalises is the ratio against **lifetime inflow, not the current ledger** — the
residual accumulates while the ledger is drained, so the campaign reached `owed = 5,337,018,741`,
`backing = 0`. Measured: worst surplus **exactly 0 wei**, worst shortfall **under 1 ppb of lifetime
inflow**, and **the last holders to withdraw bear it**. README, BUSINESS §9 and PLAN say so.

#### Method notes worth keeping

- **A coverage floor CANNOT live in `afterInvariant`.** The shrinker answers any cumulative
  assertion there by shrinking to a ONE-CALL sequence, which trivially has no coverage. That is why
  `test_6_0` is a deterministic scripted campaign instead.
- **Under `fail_on_revert = false`, an `assertEq` inside a handler is a revert and is SWALLOWED.**
  Every per-call check in the handler is therefore a ghost COUNTER that an invariant asserts is zero.
- **`fail_on_revert = false` plus a revert allow-list is strictly stronger than `true`**, which only
  says *something* reverted. I7 asserts the unexpected-selector count is zero.
- The "nothing happened: this test proves nothing" guards caught **six** of my own broken
  adversarial tests before they could pass vacuously.

#### The product was reframed (README, BUSINESS §0)

The pitch was true but was being read as "an order book bolted onto an AMM". It is not that. The
frame now states the **Uniswap decision being challenged** (pro-rata fill, unexamined for seven
years), what that choice costs (priority has no price, subordination cannot be sold, and ordering
value relocates to the sequencer instead of vanishing), and **why paid seats specifically**: free
rank is griefable, unbounded rank is worthless, so scarcity IS the mechanism — and Harberger is what
stops a scarce roster becoming a cartel. **Scarce, but never capturable.** The honest claim is that
QUEUE is the first venue that produces a *number* for what being filled first is worth, and that
both possible answers are results.

---

### 2026-08-27 (third session) — Phase 3: rank becomes an object, and the plan's own transfer design turns out to be a free DoS

**Phase 3 is COMPLETE. `forge test` 77/77, `forge lint src/` clean, 29 mutations on the Phase 3 code,
ZERO survivors.** The project is at its SUBMITTABLE state.

**What was built**

- `src/queue/QueueSeats.sol` — the ERC-6909 rank token. One id per seat, supply exactly one.
  Ownership is a single `seatHolder[id]` address slot and the whole ERC-6909 surface is a VIEW over
  it, so **supply-1 is structural rather than tested**: there is no storage in which "two" could be
  written. The interface is v4-core's own `IERC6909Claims`, so every selector and event topic is
  compiler-checked against the canonical definition. `transfer` and `transferFrom` differ only in
  how they authorise and both funnel through one `_moveSeat`.
- **The founding roster is fixed in the constructor.** `deposit()`, `seatOwner` and `_pushSeat` were
  DELETED. There is no runtime path that creates a seat.
- `_onSeatTransfer` — the evacuation. `pendingWithdraw` + `claimPending` for the residual.
- A transient reentrancy guard on every external ledger path.
- `test/queue/Rank.t.sol` — 19 tests including 5 negative controls.

**DECISION TAKEN (recorded per AGENTS.md §4): the founding roster is an endowment fixed at
deployment.** §B.8 permits "direct assignment by the deployer", and the constructor form adds no
privileged role, no admin function and no runtime path — the allocation is an immutable fact of the
deployment. It closes the dusting hole completely: **rank cannot be obtained at any price the
incumbent has not accepted.** It does NOT make rank *bought* — that needs Phase 4's Harberger lease,
and the honest sentence is in PITFALLS 5.8. Say the narrow thing on camera.

**FOUR DEFECTS, ALL FOUND BY ATTACKING THE WORK RATHER THAN BY WRITING IT**

1. **PLAN §B.8's specified evacuation is a free DoS on the swap path** (PITFALLS 5.51). A ledger-only
   move to `pendingWithdraw` drops `Σ q[i].aX` while leaving the position at full depth, so the pool
   quotes liquidity the queue cannot source and `_allocate` reverts `QueueUnderflow`.
   `transfer(self, id, 1)` is legal and costs only gas, so **any single seat holder could brick every
   swap above their surviving balance, indefinitely, and undo it at will.** Fixed by paying the
   capital out for real, which burns the matching liquidity. Refusing to transfer a funded seat was
   rejected because Phase 4's buyout must be unblockable. §B.8 is corrected with the full reasoning
   and both rejected alternatives. **The control runs the spec's design and the shipped one side by
   side.**
2. **Seat theft through an unchecked entry point — the paired-rule asymmetry, third instance and the
   first that was funds rather than wei** (PITFALLS 5.52). Removing the ownership check from
   `transfer` survived all 71 tests: `transferFrom` had a test and `transfer` had nothing. Removing
   `transferFrom`'s check ALSO survived, because the only test there used an unapproved third party —
   and naming yourself as `sender` skips the allowance branch entirely. Either mutant lets anyone
   take any seat for free and be paid its capital on the way out.
3. **A bound in the right direction is not a correctness assertion** (PITFALLS 5.53). `withdraw`
   debiting the REQUEST instead of the PAYMENT survived the whole suite, because the residual tests
   assert the unpaid leftover is SMALL — and over-debiting makes it smaller. **The mutant passed more
   comfortably than the real code.** Replaced with the identity `seatAfter == seatBefore - paid`.
4. **The whole `pending` path was dead code under test while being asserted about** (PITFALLS 5.54).
   Every pending line survived mutation because no test had ever produced a non-zero pending balance;
   `test_3_2`'s assertions about it all held vacuously at zero. Reaching it needs ~40 swaps of
   accumulated §E.4 residual AND the seats in front drained first.

**A fifth finding, reported as what it is and not more** (PITFALLS 5.55). The reentrancy window is
real: `take` calls `IERC20.transfer`, handing a pool currency control mid-unlock, and PoolManager's
lock does NOT close it — a withdrawal on the leg the float already covers needs no second `unlock`
and executes in full. What it corrupts is `unlockCallback`'s balance-difference measurement (which
must be a difference: a fee-on-transfer currency delivers less than `callerDelta`). In the executed
control it happens to underflow and revert — **an accident of direction, not a defence.** The guard
stays. **NOT claimed: no value-extracting sequence was found without it.** The first draft of the
guard's own comment asserted a double-payment that could not be reproduced, and that comment was
rewritten rather than left to read well.

**Also done**

- `MAX_SEATS = 32` taken and recorded; the gas regression's top depth moved 50 -> 32, because 32 is
  now the real worst case. Head-only swap stays flat across 1 -> 8 -> 20 -> 32.
- Pure-rank (empty-seat) transfer measured under `vm.cool()`: **17,939 gas**, versus 23,905 with the
  early return removed. The bound sits between them.
- `_seatSlot` in `Allocator.t.sol` hardcoded storage slot 0 for `q`. `QueueSeats` put three mappings
  in front of it, so the test would have poked an unrelated slot and passed for the wrong reason. It
  now reads the slot from the contract.
- Two dead imports removed and the `nonReentrant` modifier unwrapped: `forge lint src/` is clean with
  **zero notes**, not just zero errors.

**What is open, and must not be glossed on camera**

- The founding roster is an endowment, not a purchase (PITFALLS 5.8, amended).
- Phase 3 alone is a one-sided market (5.19); rank-then-run is open (5.9). **Phase 4 is what closes
  both and what makes rank continuously priced without needing a secondary market to exist.**
- A seat transfer is a second trigger for the 5.43 depth drain (new row 5.56). Seat trading is not
  depth-neutral.

---

### 2026-08-27 (third) — PHASE 2 COMPLETE. Float withdrawal, the sweep, and a DoS closed

**All §D.4 gate criteria met. 59/59 tests, `forge lint src/` clean, 11 Phase 2 mutations run with
ZERO survivors** (20 production mutations across Phases 1–2 in total).

Built on `QueueHook`: `deposit`, `addToSeat`, `withdraw`, `sweepFloatIntoPosition`, the two-slot
float, and pool binding via `afterInitialize`. Tests: `Deposit.t.sol` (16), `Residual.t.sol` (5).

#### Owner decisions taken this session
1. **Deposit remainder: ABSORB into float and credit the seat**, not refund to `msg.sender` as
   PLAN §B.7 said. Cheaper, shrinks the float, and the depositor keeps full value as ledger credit.
   INVARIANT F holds exactly: consumed → position, remainder → floatX, seat credited both.
2. **Full-range depth: answer it, don't fix it, until the sweep is proven.** Unchanged this session.

#### What the float actually buys, and what it does NOT

`withdraw` sizes the removal on the leg that **binds** (the MAX of the two liquidity requirements),
pays the seat its exact ledger composition, and retains the surplus as float shared by the queue.
**All six withdrawal orderings pay everyone**, at 1:4 with 18/6 decimals. `withdraw` never calls
`poolManager.swap` — it reaches `modifyLiquidity` only through `_burnPosition`, which decrements
`liquidity` (PITFALLS 5.23, confirmed by mutation P1).

**Two honest limitations, now asserted rather than written down:**
- **The sweep is BOUNDED BY THE SMALLER LEG** (5.43). Adding to a range straddling the price needs
  both tokens, so a lopsided float is reinjected only in proportion to its minority token. A
  1000e18/1e6 float reclaimed <0.1% of the majority leg. **Do not claim the sweep "restores depth"**
  — it restores as much as the float is balanced enough to pair up.
- **An off-ratio deposit becomes float, not depth** (5.44). A token0 deposit the size of the whole
  pool moved liquidity <1%. The depositor loses nothing under ABSORB, but the pool gains nothing
  either until the other leg arrives. A real consequence of the ABSORB decision.

#### THE BIG MEASUREMENT ERROR — my instrument, not the ledger

INVARIANT F appeared to be violated by **9.6e15 wei per swap** — about 80% of the LP fee, growing
linearly. It looked exactly like catastrophic ledger corruption. **It was the instrument.** v4
accrues LP fees into `feeGrowthInside` and only realises them on `modifyLiquidity`, so a
principal-only position valuation understates the position by every fee it has ever earned. Adding
`L * (feeGrowthInside - feeGrowthInsideLast) / 2^128` collapsed it to a handful of wei.

**This is the third instance of PITFALLS 5.27 in one day** (after the tautological fee assertion and
the late foreign swap). Recorded as 5.46.

A second unit error compounded it: I supplied token1 in HUMAN units (1e6) against token0 in RAW
units at a 4:1 raw price, so **98% of every deposit went to float** and churned. LAW 1 says use
unequal decimals — but v4 works entirely in RAW units, so fixture amounts must be in the pool's raw
ratio regardless of decimals (5.48).

**The §E.4 residual, re-measured cleanly: ~0.15 wei per swap per token** (17 wei after 120 swaps),
LINEAR and converging. The safety property asserted is linearity, not zero — a compounding residual
would eventually be real money; at 0.15 wei/swap a single token of shortfall needs ~10^18 swaps. The
mandatory dust control is in: with F1 replaced by face-value payment, a withdrawer's call reverts
`FloatShort`; with F1 in place the identical scenario drains everyone.

#### A FREE, UNRECOVERABLE DoS — found and closed

`afterInitialize` bound the hook to whichever pool initialized **first**. Anyone could front-run the
intended `poolManager.initialize` and bind a freshly deployed hook to a junk pool — **permanently**,
because there is no admin to unbind it. Closed by committing `(currency0, currency1, fee,
tickSpacing)` at CONSTRUCTION and rejecting anything else with `WrongPool`. Costs nothing: the hook
serves exactly one pool by design. Two tests (5.45).

#### THE PAIRED-BRANCH ASYMMETRY RECURRED

The top-up cursor pull-back exists once per direction. The `cursor1` copy was covered; the `cursor0`
copy was covered by **NOTHING**. That is PITFALLS 5.37 repeating one phase later, in a different
function. **It is now a confirmed repeating failure mode on this project, not a one-off** (5.50).
Two other mutations also survived the first battery and are now covered: the `+1` truncation guard
in `_liquidityToCover`, and the deposit sizing shave.

**The shave was DELETED rather than tested** (5.49). Mutation testing said nothing could detect its
removal; 5,000 fuzz runs found no counterexample, and the round trip is provably
`ceil(floor(x*k)/k) <= x`. `DepositOversized` remains as the loud backstop. When mutation testing
says a line is undetectable, the honest question is whether it should exist.

#### Still true, still open

- **Rank is granted by arrival order** — PITFALLS 5.8, not shippable. Carried deliberately with a
  named test (`test_KNOWN_HOLE_rankIsGrantedByArrivalOrder`) that must be DELETED in Phase 3. One
  wei of each token currently buys the head seat.
- **Full-range depth** (5.17) — unaddressed by decision; a pitch question, not a correctness one.
- **"The queue's face value is redeemable" is still FORBIDDEN.** The defensible replacement claim is
  now precise: *each seat redeems its entitlement to within a bound that grows linearly at ~0.15 wei
  per swap and never compounds.*

**NEXT ACTION — Phase 3 (§C.3): the ERC-6909 rank token.** It replaces `seatOwner`, closes 5.8, and
is the SUBMITTABLE state. Delete the known-hole test when it lands.

---

### 2026-08-27 (second) — PHASE 1 COMPLETE. Protocol fee SOLVED; four real defects found and fixed

**All twelve §C.1 exit criteria met. Gate §D.3 passes. 36/36 tests, `forge lint src/` clean.**

Built: `src/queue/libraries/Allocation.sol` (the arithmetic, 89 lines) and
`src/queue/QueueHook.sol` (the hook, 359 lines). Tests: `test/queue/` — `Allocator.t.sol` (11),
`Controls.t.sol` (7), `ProtocolFee.t.sol` (6), `Dust.t.sol` (3), plus `QueueFixture.sol` and the
test-only `QueueHarness.sol`.

---

#### 1. THE PROTOCOL FEE IS SOLVED, and the fix is one SLOAD rather than a derivation

The handoff said the replacement "is NOT a one-liner" and listed four arithmetic hazards to
overcome (per-step rounding across tick crossings, `lpFee == 0` taking the whole `feeAmount`,
exact-output rounding the other way, clamping not fixing the under-credit). **None of them apply,
because the fee should not be derived at all.**

`protocolFeesAccrued` being global per currency was never the problem. **The measurement window
was.** Verified at source: `PoolManager.swap` calls `beforeSwap` -> `_swap` (which calls
`_updateProtocolFees(inputCurrency, amountToProtocol)`) -> `afterSwap`, and **that window contains
no external call**, so no foreign pool can accrue inside it and `collectProtocolFees` cannot run
inside it. Snapshot in `beforeSwap`, read in `afterSwap`, and the difference is *exactly this
swap's protocol fee on this pool, to the wei*.

- **Cost:** one hook permission (`beforeSwap`; address bits `0x0840` -> `0x08C0`), one SLOAD, one TSTORE.
- **The snapshot is TRANSIENT**, so a stale or uninitialised snapshot — the third documented failure
  of the old design — is impossible by construction, not by convention.
- **Nothing is clamped.** `pfDelta > amtIn` reverts by name. A clamp would silently under-credit.
- `lpFee == 0` needs no special case: `test_5_3_lpFeeZeroUnderProtocolFee`.

**X1 and X2 are dead, and I proved it by reinstating the old mechanism against the new suite:**

| Test | vs. old mechanism |
|---|---|
| `test_X1_foreignAccrualCannotCorruptTheLedger` | RED — ledger short `499999999999999999` wei, **exactly** the foreign pool's take |
| `test_X2_foreignAccrualCannotBrickTheHook` | RED — `ProtocolFeeExceedsInput(pfDelta 1e19, amtIn 2e16)`; under the old bare subtraction this is an underflow panic and a permanent brick |
| the other four | RED |
| all six | GREEN on the fix |

**Every fee test runs with a FOREIGN POOL sharing a currency.** A single-pool fixture cannot observe
this and that is exactly how the previous mechanism passed review.

**THE NEAR-MISS, and it is the more valuable finding.** `test_measurementWindowSeesExactlyOneSwapsFee`
**passed against the broken mechanism twice** before it was any good:
1. It compared `lastPfDelta` (the FIXTURE's own measurement) to another fixture-side number —
   tautological, never touched the hook. Fixed by asserting `lastHookCreditedIn`, the hook's own
   ledger movement.
2. Its foreign swap came AFTER the window it was checking. A multi-pool fixture is **necessary but
   not sufficient** — the contamination has to exist at the moment the instrument reads.
Both are PITFALLS 5.27 one layer down, and neither was visible without executing the old mechanism.

---

#### 2. FOUR REAL DEFECTS IN MY OWN CODE, found by the review lenses and by mutation

None of these were caught by the correctness suite. All are fixed properly, not annotated.

**(a) The cursor design was silently thrown away.** The first `_allocate` loaded every seat into a
memory array before allocating, so a head-only swap read the entire roster. Measured **98,294 gas at
1 seat -> 215,296 at 50**, linear. **All 31 correctness tests stayed green under it.** Fixed by
driving `Allocation.step` directly over storage with early exit; now flat (97,737 -> 95,220), with a
gas regression test measured under `vm.cool()` per LAW 4, confirmed to go red against the old draft.

**(b) Dust swaps were bricked.** Deriving the direction from the SIGN of the balance delta reads it
backwards when the output leg rounds to exactly zero. **Measured: 1, 2 and 3 wei on a 0.30% pool
reverted `DirectionMismatch`** — swaps v4 itself accepts. Fixed by taking the direction from
`params.zeroForOne` and handling the degenerate fill explicitly: the input is still owed to the
queue, so it is credited to the seat at the cursor. Dropping it would leave the ledger UNDER-counting
the position — the same strand-value-owed-to-nobody pathology as the fee under-credit.

**(c) `seed()` and `redeemAll()` were PERMISSIONLESS on the production hook.** `seed()` funds the
position from the hook's OWN balance, so the first caller of a pre-funded deployment would claim the
entire queue for free; `redeemAll()` burns the whole position and anyone could call it. Both moved to
`test/queue/QueueHarness.sol`. **The shipping contract now has no permissionless state-changing
entry point at all** — only `unlockCallback` (guarded to PoolManager) and five views.

**(d) Settlement ignored ERC20 return values.** Replaced the hand-rolled `IERC20Minimal.transfer`
with v4's `CurrencySettler` (SafeERC20). Also fixes native-currency support and a
`-type(int128).min` negation. `forge lint src/` is now clean.

---

#### 3. THE MUTATION FINDING THAT MATTERS MOST — a paired-branch asymmetry

The cursor pull-back exists **twice**, once per direction. Mutating them separately:

- deleting `if (start < cursor1) cursor1 = start;` -> caught by **7 tests**
- deleting its mirror `if (start < cursor0) cursor0 = start;` -> caught by **ZERO**

Every scenario happened to END on the reverse leg, so cursor0 never got the chance to lead. A
suite can cover one half of a symmetric rule perfectly and the other half not at all.
`test_invariantC_cursor0IsPulledBackAfterAReverseFill` closes it and is confirmed red against that
mutation. **Standing rule (PITFALLS 5.37): when a rule appears once per direction, mutate BOTH.**

**Nine production mutations run in total**, every one confirmed red: remainder line, underflow guard
(library AND hook — separate lines, one test each), cursor advance, both pull-backs, fee not netted,
window snapshot zeroed, dust credit dropped, array preload.

---

#### 4. Corrections made to the plan, because the code is the evidence

- **§B.2** — permissions gain `beforeSwap`; address low bits `0x0840` -> `0x08C0`.
- **§E.5** — REWRITTEN. It instructed the next agent to derive the fee arithmetically, which is now
  the wrong instruction. Deleted rather than annotated.
- **§D.3 N5** — predicted "conservation, immediately". **Wrong.** An external LP does NOT break
  ledger conservation: the fixture's expected totals and the hook's credit both move by the whole
  swap. What breaks is SOLVENCY (`redeemAll()`). LAW 3's second corollary again.
- **§D.3 N1/N2/N4** — predicted reasons corrected to the observed ones. N4 fires one swap EARLIER
  than predicted and on INVARIANT C rather than composition, which is the better outcome.

---

**Decisions taken (implementation-level, per the owner's 2026-08-27 authorisation):** add the
`beforeSwap` permission; transient snapshot over persistent counter; revert rather than clamp on
`pfDelta > amtIn`; credit the degenerate fill to the cursor seat; move scaffolding to a test harness;
`CurrencySettler` for settlement. None changes who receives fees or how seats are allocated.

**Nothing escalated. No admin function, no privileged role, no off-chain component, no upgrade path.**

**NEXT ACTION — Phase 2 (§C.2): deposit / withdraw, the float, and `sweepFloatIntoPosition()`.**
Carried in: INVARIANT F is already declared next to `float0`/`float1` and asserted at zero, so
Phase 2 cannot break it silently. `withdraw` MUST decrement `liquidity` (PITFALLS 5.23 — §B.7 never
does). The deposit-remainder question (5.24) is still open and is the owner's call.

**STILL TRUE AND STILL UNADDRESSED:** full-range depth (5.17) is the sharpest unanswered attack and
appears in no document. It is a business/pitch question, not a correctness one.

---

### 2026-08-27 — PHASE 0 GREEN. Reference spike reproduced EXACTLY; suite survived two fresh mutations

**PHASE 0 IS COMPLETE. All six exit criteria (PLAN §C.0) met. Gate §D.2 passes.**

Toolchain entry criteria verified before anything else: `forge 1.5.0-stable`, commit SHA
`1c57854462289b2e71ee7654cd6666217ed86ffd` — the exact SHA §A.7 records. `foundry.lock` revisions
unchanged, `lib/` complete (forge-std, hookmate, uniswap-hooks). No submodule init needed.

Copied per §A.8 into the live tree (previously `test/` did not exist at all):
`test/utils/BaseTest.sol`, `test/utils/Deployers.sol`, `test/spike/QueueAllocator.t.sol` —
`diff -q` confirms `QueueAllocator.t.sol` is **byte-identical to the archive copy**. `src/queue/`
and `src/queue/libraries/` created empty. **No mechanism code written.**

```
forge test --match-path "test/spike/QueueAllocator.t.sol" -vv
9 passed; 0 failed; 0 skipped
```

| # | Exit criterion | Result |
|---|---|---|
| 0.1 | 9 pass / 0 fail | ✅ |
| 0.2 | Conservation exact to the wei | ✅ queue totals == PoolManager-measured, both tokens |
| 0.3 | Three controls red, each with its exact reason | ✅ `swap1: entry a0` ×2, `swap2: token0 conservation` |
| 0.4 | Gas table within ±2% | ✅ **exact**: 31,864 @1 seat, 31,874 @2–50 |
| 0.5 | Residual −1/−1 @0 swaps, −52/−54 @200 | ✅ **exact**, and −3/−4, −2/−3, −9/−11, −46/−50 @0-fee all exact |
| 0.6 | State why FLOOR_ONLY survives swap 1 | ✅ below |

**Every single §D.2 number reproduced identically — not "within tolerance", identical.** Nothing to
escalate under §C.0's divergence rule.

**0.6 — why the FLOOR_ONLY control survives swap 1, in my own words.**
The mutation deletes the remainder line, so *every* filled entry gets the floored proportional share
`mulDiv(amtIn, take_, amtOut)` instead of the last one absorbing `amtIn − assignedIn`. Swap 1 is the
**head-only** swap: the head's balance exceeds the whole output, so `take_ = remaining = amtOut` on
the first and only iteration. The share is therefore `mulDiv(amtIn, amtOut, amtOut)` — a fraction of
**exactly one**, which floors to `amtIn` with **zero** rounding loss. Mutant and original are
bit-identical whenever a single entry absorbs the entire swap. Swap 2 sweeps three entries; each
`take_` is now a proper fraction of `amtOut`, each `mulDiv` floors downward, and the sum of the
floors is strictly less than `amtIn`. The lost wei are credited to nobody, the hook's totals fall
below the PoolManager-measured totals, and it dies on `swap2: token0 conservation`.
**The generalisable lesson — and it is this project's doctrine (PITFALLS 5.27) restated:** a
one-seat fixture is the degenerate case where floor == exact. It is structurally incapable of
observing this bug class. Multi-seat sweeps are not a nice-to-have in Phase 1; they are the only
configuration in which the remainder line is observable at all.

**LAW 5 applied beyond the built-in controls.** The three negative controls were written by the same
author as the code they check, so passing them is weak evidence. I wrote two mutations the author did
not anticipate, ran them, and restored:

| Mutation | What it does | Result |
|---|---|---|
| MUT-A | `_apply`: credit `give` to the **wrong token leg** (`q[i].a1 += give` under `outIsOne`) — a unit-mixing bug | **7 of 9 red.** Positive control fired `unmutated harness failed: the controls prove nothing` |
| MUT-B | `_allocate`: head **under-fills by 1 wei** whenever it does not exhaust the swap | **4 of 9 red**, on `entry a0` / `loop: entry a0` |

Restored byte-identical afterwards; suite green again. The suite can go red, and does.

**Three findings from the mutation run that are NOT in any document — all now in PITFALLS §1/§5:**

1. **`test_Q2_gasProfileVersusQueueDepth` passed under BOTH mutations.** The gas test is entirely
   correctness-blind, and `test_Q1b_residualWithZeroSwaps` never invokes `_allocate`. So "9 passed"
   overstates the correctness surface: only **6** of the 9 tests carry arithmetic signal, and only
   **4** of those exercise a multi-seat sweep. Do not quote "9 tests" as 9 units of assurance.
2. **Conservation did NOT catch MUT-B; the independent reference allocator did.** A misallocated wei
   stays inside the queue, so aggregate totals still tie out — only per-seat composition moves. This
   is LAW 3's second corollary landing on the allocator: **conservation and composition are two
   different claims needing two different assertions.** Phase 1 MUST carry its own independently
   written `_refAllocate`; conservation alone leaves a whole bug class invisible.
3. **The spike's conservation harness is the BLIND raw-balance form** (LAW 3 pre-amendment). It is
   valid here only because `protocolFeesAccrued == 0` — and the spike never asserts that it is zero.
   **If Phase 1 is built by copying this harness, it inherits the blindness**, which is precisely the
   §E.5 trap. Phase 1 must measure against `balance − protocolFeesAccrued(currency)` (or `redeemAll()`)
   *and* assert `protocolFeesAccrued > 0`.

**LAW 1 is only half-satisfied by the spike fixture.** Price is 1:4 (guarded by
`require(s0 != s1, "fixture is unit-priced")`) — good. But `Deployers.deployToken()` hardcodes
**18 decimals for both tokens** (`Deployers.sol:38`), so the unequal-decimals half is untested here.
`docs/research/withdrawal/FloatWithdraw.t.sol` already runs 18/6. **Phase 1 must use 18/6**, not
inherit 18/18 by copying the spike's `setUp`.

**Panel review** was run inline by me across the §5 lenses rather than by spawning sub-agents — the
owner's session instruction this session was not to spawn agents. Findings 1–3 above and the decimals
gap are its output. Nothing else surfaced at Phase 0; there is no mechanism code to attack yet.

**Decisions taken:** none that touch economics or security. Nothing escalated.

**NEXT ACTION — unchanged and now unblocked: Phase 1, but its first task is the P2 replacement
(PITFALLS 5.25/5.26), not the allocator.** The allocator arithmetic is proven and reproduces; the
protocol-fee mechanism in front of it is the thing that does not exist. Also still owed:
`sweepFloatIntoPosition()` (5.21), the `liquidity`-decrement correction to §B.7 (5.23), and the
**owner decision on the deposit remainder** (5.24 — refund vs absorb into float; ASK, do not decide).

---

### 2026-08-26 (session close, final) — P2 + float COMPOSE; but P2's IMPLEMENTATION is DEFECTIVE

Ran while the harness was warm, to close the last untested composition before any build.
Evidence: `docs/research/withdrawal/fee-float-composition.md` + `FeeFloatComposition.t.sol` —
**19 tests, re-run independently by the orchestrator, 19/19 green.**

**GOOD NEWS — the two designs compose. INVARIANT F survives a MAXIMUM protocol fee:**
residual **0 wei** in the balance form, **3–8 wei** against raw ledger — *the same bounds the fee-off
suite already reports*. **The residual does NOT scale with the fee:** the fixture accrued 3.54e17 /
2.0e16 wei of protocol fee — ~17 orders of magnitude above the residual — and the residual did not
move. Dust policy unchanged by the fee. Withdrawal does **not** accrue protocol fees (`test_P4`,
verified in source, not assumed).

**⚠️ BAD NEWS — a CRITICAL defect in P2 itself, and it is a PHASE 1 BLOCKER.**
`poolManager.protocolFeesAccrued(currency)` is **GLOBAL PER CURRENCY, not per pool**
(`ProtocolFees.sol:21` — `mapping(Currency currency => uint256 amount)`, no `PoolId` anywhere).
So the diff `pfNow − pfSeen` **absorbs the protocol fees of every other v4 pool sharing either
currency.** Float-independent; it would have hit Phase 1 in production.

- **X1 — silent under-credit (the EVERYDAY case).** A second pool on the same pair (fee tier 500)
  took 2e15 wei of token0 protocol fee. QUEUE's next swap computed `pfDelta` =
  301999999999999999 instead of its own 299999999999999999 and **under-credited the queue by
  exactly the foreign pool's fee (2e15 wei)** — stranded in the position, owed to nobody.
  **No attacker needed:** ordinary volume on any other pool of the same token does this continuously.
- **X2 — PERMANENT BRICK (the tail case).** If foreign accrual since our last swap exceeds the next
  swap's input, `amtIn -= pfDelta` **underflows inside `afterSwap`** and the swap reverts
  (`Panic(0x11)` in v4's `WrappedError`). **And it is permanent** — the failed swap never advances
  `pfSeen`, so every later swap recomputes the same oversized delta. **The pool is dead.** The
  attacker needs only one other pool sharing the currency with a nonzero protocol fee — the normal
  state for any listed token — and one swap on it.
- `pfSeen0/1` start at **0** at construction, so a currency already carrying accrued fees
  **bricks or mis-credits the hook's FIRST EVER swap.**

**HOW THIS GOT PAST US — record it, it is the project's own doctrine biting.** The `test_M3`
mutation that "MEASURED P2 closing the gap to 3 wei" ran in a **single-pool fixture**. The mechanism
was never wrong about *what* to subtract; the **instrument for measuring it** was wrong, and the
fixture could not see it. **A green test in a fixture with only one pool proved nothing about a
global counter.** LAW 5 territory: the pass was the harness, not the code.

**WHAT STANDS AND WHAT DOES NOT:**
- ✅ **The DECISION stands** — net out the protocol fee so the ledger credits only what the position
  received. P1 (refuse) is still rejected for the Proposal-100 reason.
- ❌ **The MECHANISM does not.** Do NOT ship `pfNow − pfSeen` on the global counter.
- **Follow-up REQUIRED before Phase 1, and it is NOT easy — it needs its own experiment and its own
  negative control.** Derive the protocol fee arithmetically from the swap rather than diffing a
  global counter, but note: `lpFee == 0` takes the ENTIRE `feeAmount` by a different formula
  (PITFALLS §1.5); exact-out rounds the other way (§1.12); and `amountToProtocol` is summed
  **per swap step** with per-step rounding across tick crossings — so a one-line
  `amtIn * pf / 1e6` will **not** be wei-exact. **Clamping `pfDelta` to a locally-derived upper
  bound removes the BRICK but not the UNDER-CREDIT.**

**Negative controls held:** NC-1 (netting removed, fee on) went RED with INVARIANT F slack
`−353999999999999999` / `−20000000000000000` — **exactly `protocolFeesAccrued`, asserted with
`assertEq`** — and the last withdrawer reverting `FloatShort` short 354000000000000003 wei, i.e.
4.4e16× the 8-wei bound. NC-2 (fee = 0 + float) reproduced the 22-test float suite exactly.

### 2026-08-26 (session close) — HAZARD 5.5 SETTLED: per-seat withdrawal is FEASIBLE

**The one finding that could have killed the product is closed.** Run in-session rather than deferred,
because the resolution changes Phase 1's state layout. Evidence:
`docs/research/withdrawal/feasibility.md` + `FloatWithdraw.t.sol` — **22 tests, re-run independently
by the orchestrator, 22/22 green**, including 8 negative controls, 2 attack tests, an asymmetric-
decimals (18/6) case and conservation under LAW 3 AS AMENDED.

**VERDICT: FEASIBLE-WITH-CAVEATS.** A **two-slot shared float** lets `withdraw()` pay any seat its
exact ledger composition — including a **100%-converted seat** — with **no `poolManager.swap`**, in
any withdrawal order, at 1:4 and at 18/6 decimals, **zero conservation slack, 252,672 gas cold**.

**INVARIANT F (PROVEN) — the fact that makes it work:**
`Σ q[i].a0 == redeemable token0 + float0`, likewise token1, to within the §E.4 residual (≤8 wei).
The aggregate is consistent; only the **per-seat composition** is unpayable from a proportional
liquidity removal. That is why a shared float is sound and first-come-first-served payment is safe.

**⚠️ THE ORIGINAL PROBE WAS READING THE WRONG NUMBER — correct the record.** The apparent 1.062e18
"gap" was `LiquidityAmounts.getAmountsForLiquidity`, which returns **principal only** and does not
know about accrued LP fees. Cross-check, exact to the wei: gap on token0 = 1062000000000000003 vs
LP fee earned = 1062000000000000000 = **0.30% × 354e18**; token1 gap 60000000000000003 vs
60000000000000000 = 0.30% × 20e18. **There was never an aggregate shortfall.** The per-seat
composition problem was real; the solvency scare was an artefact of measuring principal.

**STATE TO ADD — this is what had to be known before Phase 1 (PLAN §B.3):**
```solidity
uint256 internal float0;   // token0 held OUTSIDE the position, owed to the queue
uint256 internal float1;   // token1 held OUTSIDE the position, owed to the queue
```
Plus two corrections: **(a) `withdraw` MUST decrement `liquidity` by Δ** — §B.7 never does, and every
later sizing computation is wrong without it. **(b) INVARIANT F must sit next to the declarations in
§B.3.** `pendingWithdraw0/1` is unrelated and does not serve this purpose.

**THE ALLOCATOR IS UNCHANGED — PROVEN.** `_allocate` is character-for-character the spike's
FRONT_FIRST path. The float touches **withdraw** only, and is structurally *safer* for the allocator.
⇒ **Phase 1 is unblocked and its arithmetic is unaffected.**

**NEW OPEN ITEM, and the biggest gap in this result: `sweepFloatIntoPosition()` is REQUIRED and
UNBUILT.** Permissionless, no privileged role: re-add `Δ' = min(float0/f0, float1/f1)` of liquidity,
credit nobody, decrement both floats by actual consumed amounts. **Without it, pool depth degrades
monotonically as seats withdraw imbalanced legs.** UNPROVEN — not written, not tested.

**OWNER DECISION NEEDED (AGENTS.md §4 — it changes who gets what):** on deposit, §B.7 says *"refund
any unconsumed remainder to msg.sender"*. Under a float the better answer is to **absorb the
remainder into `floatX` and credit it to the seat** — cheaper, and it reduces the float. Not built,
not tested. **Ask before implementing.**

**Dust policy — choose F1.** Measured both branches: exact payout ⇒ the last withdrawer **reverts
`FloatShort`, short 3 wei** (NC-F); F1 (`pay min(face, available)`) ⇒ everyone drains, 3–8 wei of
ledger dust unpaid. **The float does NOT solve §E.4** — orthogonal, still open, and *"face value is
redeemable"* still must not be claimed.

**Still UNTESTED:** protocol fee ≠ 0 interacting with the float (everything above ran at
`protocolFeesAccrued == 0`, asserted — the amended LAW 3 form is used but inert); the
sandwich-the-withdrawal sizing attack (REASONED only); `lpFee == 0`; deposit-side float absorption.

### 2026-08-26 (later still) — PREMISE REVIEW: the mechanism is SOUND; two sharper holes found

**Owner asked:** is the hook fair, does the niche make sense, would deploying it be embarrassing.
**Answer: the premise holds, front-first is defensible, and the real risks are elsewhere.**
Full reasoning: `docs/research/premise-review/economics.md`, `.../fairness.md`. Ledger: `PITFALLS.md`.

**1. The orchestrator's own attack on the premise was REFUTED — record it so it is not re-litigated.**
The attack: *"a CLOB seat is valuable because you can CANCEL; QUEUE cannot cancel or detect toxic flow,
so the front seat eats adverse selection and rank is worth negative."* **Wrong, for a precise reason:
a CLOB order rests at a FIXED price; a QUEUE seat has no price of its own.** Every seat filled by a
swap is filled at that swap's realised average price (`PLAN.md:503`) — front and tail get IDENTICAL
execution, only quantities differ. There is no stale quote, so there is nothing to cancel. Front-of-
queue buys **priority over QUANTITY, not priority at a stale PRICE.** [REASONED, confidence HIGH]

**2. The leverage identity — write it into BUSINESS.md, it is the answer to "why buy a seat".**
`L(s) = (C/c1) * min(1, c1/s)`. The front seat is levered on everything, and **most levered on SMALL
swaps** (decaying as `C/s` above head size). BUSINESS.md's own two worked examples (§7.1 = 50x,
§7.3 = 3.34x) are special cases of this formula — **the doc never wrote the formula down.**
⇒ **QUEUE is a LEVERAGE instrument on the pool's own LP return**, bounded downside per trend,
unbounded round-trip upside. This is a better and more defensible pitch than "the seat price is the
toxicity", which is **overclaimed** (it measures leverage x LP return — computable from public swap
data — and Harberger censors the signal at zero on exactly the toxic side).

**3. THE FAIRNESS THEOREM — the decisive answer, and it is free.**
**QUEUE is exactly ZERO-SUM against pro-rata.** Therefore the tail's excess return over pro-rata has
the **opposite sign to the pool's own net LP P&L**:
- profitable pool ⇒ **tail strictly worse off** than a plain v4 LP;
- loss-making pool ⇒ **tail strictly better off**.
**Both seats cannot beat pro-rata. No ordering, banding, rotation or partial blend can change that.**
⇒ **Fairness in QUEUE is not an allocation problem, it is a TRANSFER problem** — and the design
already names the transfer: sell or rent the rank. *(The owner's prior "the tail is fine, it eats less
toxicity" is half right — true only in the loss-making regime. The docs' only two worked examples are
both drawn from that regime, which is why the prior survived.)*

**4. ⚠️ THE SHARPEST UNANSWERED ATTACK — full-range capital efficiency. NOT IN ANY DOC.**
The hook mints **one full-range position** (`PLAN.md:64,:325`). A full-range CPMM offers roughly
**1/200th the depth per dollar** of a +/-1% concentrated position. **A $1M full-range QUEUE pool quotes
about the depth of a ~$5-10k concentrated position next door; a $10k swap costs ~4% slippage.**
⇒ no aggregator routes retail to it; retail is the ENTIRE benign side of the P&L; kill it and the pool
is arb-only, LP return goes negative, and the front seat earns `C/c1 x` a negative number.
**The feared inversion IS real — but the cause is full-range-ness starving the pool of benign flow, NOT
front-first allocation.** It is a reversible design choice, not a v4 constraint. **This is the single
most likely question from a v4-native judge and the repo has no answer.** [ANALYSIS]

**5. THE RATCHET — a structural asymmetry named nowhere in the docs.**
Front-first applies in both directions, so the **head unwinds first**: the head is a market maker with
recycling inventory, **the tail is a one-way accumulator, filled at extremes with no priority to exit.**
Severity moderate, not fatal (the tail can withdraw + re-deposit; rank survives per §B.7) — but it is
**a cost of active management imposed on the party the pitch calls passive** ("treasury, LST issuer,
yield vault"). A real contradiction in the sales story; say it out loud. Only B-2 addresses it.

**6. Phase 3 (the SUBMITTABLE state) is a ONE-SIDED MARKET.** The tail's compensation channel is
Harberger rent = **Phase 4**. In Phase 3 the honest answer to *"why would anyone hold seat 5?"* is
**"they wouldn't."** ⇒ **Phase 4 is not optional for the rank-then-run hole alone — it is what makes
the tail's participation rational at all.** In Phase 3 the transfer channel is a secondary market that
`BUSINESS.md` §9.7 **already concedes does not exist.** The tail's deal is sound in theory, empty in
the demo.

**DECISION (orchestrator, panel-backed): BUILD PHASES 0 -> 3. BUILD NO NEW FAIRNESS MECHANISM.**
Ship the Fairness Theorem as an *argument*, not as code — it is stronger than any mechanism and costs
zero engineering days. A panel that answers "is it fair?" by building a fairness mechanism has already
lost the point. **What actually moves value to the tail, all already scoped:** (1) **P2** — worth ~33%
of the tail's fee income at max fee, Phase 1, **the highest-value fairness action available**;
(2) **F1** settle withdrawals against actual holdings, Phase 2; (3) **resolve per-seat withdrawal
feasibility — a Phase 2 BLOCKER, not a nicety.**

**GATE for anything new:** only if Phase 3 is green with real time to spare — then ONE of **B-1
Harberger** (answers fairness, closes rank-then-run) or **B-2 two-sided rank** (order-only, so it
inherits the allocator's proven conservation for free; fixes the ratchet; genuinely novel — nothing in
the 662-row hook directory has it). **Otherwise build nothing new: a half-built Harberger on an
unfinished allocator scores WORSE than zero — it takes Functionality (15%) and Unique Execution (25%)
down with it.**

**KILLED — do not revisit (reasons in `docs/research/premise-review/fairness.md`):** B-4 partial
front-first (pro-rata in a fairness costume; killed on gas) · B-5 banded queue (costs the most
defensible property, buys the tail nothing) · **B-6 rank decay/rotation (FATAL — rank becomes free by
waiting)** · B-7 minimum fill guarantee (fatal) · B-8 distance-weighted rent · B-9 genesis auction
redistribution (no mechanism to build; retained only as a disclosure obligation).

### 2026-08-26 (later) — PLAN §E.5 protocol-fee hazard CLOSED BY MEASUREMENT (research only, no mechanism code)

**Owner directive:** research the §E.5 protocol-fee hazard before building, and scrap the project if
the evidence is bad enough. **Verdict: the hazard is REAL and large, but it does NOT kill QUEUE.**
Do not scrap. Evidence: `docs/research/protocol-fee/` (VERDICT.md, experiment.md, v4-mechanics.md,
queue-exposure.md, raw forge output) + `archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol`.

**What is now PROVEN (executed, reproduced independently by the orchestrator, 7/7 with mutations):**

| Claim | Status | Evidence |
|---|---|---|
| The swap delta a hook reads is **NOT** net of the protocol fee, but the LP position **is** | **PROVEN (source)** | `Pool.sol:369-381` computes the swapper delta from `amountIn+feeAmount`; `:384-396` skims after; `:398-403` credits fee growth from the reduced amount |
| The spike sits in exactly the vulnerable configuration | **PROVEN (source)** | real LP position at spike `:127` `modifyLiquidity`; ledger credited from the swapper delta at `:153,:169-171` |
| Max protocol fee = **0.1% of swap amount**, per direction; new pools start at 0 | **PROVEN (source)** | `ProtocolFeeLibrary.sol:8,:15`; `Pool.sol:105` |
| At max fee the queue is short **0.354e18 token0 / 0.02e18 token1** over the 4-swap scenario | **MEASURED** | `test_E1_maxProtocolFee_breaksTheLedger` |
| The shortfall equals `protocolFeesAccrued` exactly, +3 wei of known §E.4 residual | **MEASURED** | experiment.md F2 |
| Magnitude = **0.1% of input = 33.4% of the LP's entire fee income** (`1000/(3000x0.999)`) | **MEASURED** | experiment.md §4 |
| It leaks at the **minimum 1-pip fee too** — not a max-fee artefact | **MEASURED** | `test_E2_oneWeiPipProtocolFee_alsoLeaks` |
| **P2/P3 (net out `protocolFeesAccrued`) closes the gap to 3 wei**, ~10 lines + 1 SLOAD | **MEASURED** | `test_M3_mutation_P2NettedAllocatorClosesTheGap` |
| Remedy P1 (revert in `_afterSwap`) **cannot block withdrawals** | **PROVEN (structural)** | permissions are only `{beforeAddLiquidity, afterSwap}` (spike `:59-63`); withdrawal is `unlock()->modifyLiquidity(negative)` (`:119,:124-131`), unhooked |

**THE MOST DANGEROUS FINDING — a standing correction to LAW 3, project-wide:**
`protocolFeesAccrued` money **stays inside PoolManager's ERC20 balance** until collected. So the
spike's conservation test — the project's own LAW 3 measurement — **passes at 0 wei error while the
position is short 0.354 token0.** The existing suite could never have found this.
**Conservation must henceforth be measured on `PoolManager ERC20 balance - protocolFeesAccrued(currency)`,
never on the raw balance.** Any test written the old way is blind to every protocol-fee-shaped bug.

**TWO FINDINGS THAT REVERSE PLAN'S P1 RECOMMENDATION (added after the adversarial pass):**

1. **PLAN's own §E.5 test instruction is BLIND to the bug it was written to catch.** `PLAN.md:2092`
   says *"set a protocol fee, run the conservation test."* Executed exactly as written, that goes
   **GREEN** while the position is short 0.354e18 — because `protocolFeesAccrued` is still sitting in
   PoolManager's ERC20 balance. Green there means "unresolved", not "safe". It is a LAW-5 trap of the
   plan's own making. The correct assertion is against `PoolManager balance - protocolFeesAccrued`,
   or directly against `redeemAll()`. PLAN already contains the right instrument (LAW 3's second
   corollary, `PLAN.md:1322-1328`) and simply never wired it to criterion 1.10.
2. **PLAN's stated justification for preferring P1 is factually wrong.** §E.5 argues P1 loses nothing
   *"since we control the pool we deploy."* We control **deployment**, not the **fee** — the
   controller can set it at any time afterwards. P1's cheapness was never in question; its
   justification was.

**P2 is cheaper than previously believed — it needs NO extra hook permission.** The measured M3
implementation keeps a stored running total and diffs `protocolFeesAccrued` inside `_afterSwap`
(legal: credited at `PoolManager.sol:238`, before `afterSwap` at `:221`). So the earlier concern that
P2/P3 required a `beforeSwap` permission — a re-mined hook address and ~15% on the headline gas
number — **is void.** Cost is ~1 SLOAD + 1 SSTORE.

**P1 withdrawal-safety is now PROVEN BY EXECUTION, not just structurally argued:**
`test_E5_P1_refuseInAfterSwap_doesNotBrickWithdrawal` (in `docs/research/protocol-fee/ProtocolFeeExposure.t.sol`,
4/4 green, re-run by the orchestrator). After a refusal the depositor still withdraws in full.
**But placement is load-bearing: if the check ever moves into a shared modifier or the removal path,
a governance fee-set becomes total permanent loss of funds.** A negative control proving withdrawal
still works with the fee on is mandatory in Phase 1.

**P2 edge case that must be handled or refused:** `lpFee == 0` ⇒ `swapFee == protocolFee` ⇒ v4 takes
the *entire* `feeAmount` via a different formula (`Pool.sol:391-392`). Dynamic-fee/`lpFeeOverride` is
NOT a risk (QUEUE has no `beforeSwap` permission). Exact-output swaps need no special handling.

**Decisions taken:**
- **Do not scrap.** The hazard is bounded (0.1% ceiling), detectable in one `extsload`, and has a
  measured fix. It is a real bug with a cheap fix, not a design flaw.
- **✅ OWNER DECISION 2026-08-26: ship P2 (account for it).** Net out `protocolFeesAccrued` in
  `_afterSwap`; do NOT ship a refusal. Rationale below. Phase 1 implements it; acceptance 1.10 is
  satisfied by the netted allocator plus the corrected assertion, not by a refusal.
  **Consequence to remember:** with P2 the ledger no longer over-credits, so the "33% of LP income"
  figure and the "tail eats the shortfall" behaviour BOTH disappear — they were artefacts of the bug,
  not properties of the mechanism.
- *(superseded context)* P1 vs P2 was an open owner decision. The evidence moved against PLAN's P1
  recommendation: P1 hands the PoolManager owner's controller a permanent off-switch for the product,
  and its stated justification is wrong. P2 is measured, needs no extra permission, and keeps the pool
  trading under any fee. **Escalated to the owner per AGENTS.md §4 (a choice that changes the
  mechanism's economics/security).** Whichever is chosen, the check must be re-read PER SWAP.
- Acceptance criterion **1.10's assertion must change** — against `PoolManager balance -
  protocolFeesAccrued`, or `redeemAll()`. As written it cannot fail.
- Acceptance test 1.10 **must assert `protocolFeesAccrued > 0`** or it proves nothing —
  `setProtocolFee` silently no-ops for a non-controller caller.

**⚠️ THE FEE SWITCH IS REPORTEDLY ALREADY LIVE — this is no longer a hypothetical contingency.**
*(WEB-SOURCED, crypto press only, NOT verified on-chain or from source. Treat as a strong prior, not
as fact. Sources in `docs/research/protocol-fee/v4-mechanics.md` §9.)*
- Uniswap **Governance Proposal 100 reportedly executed 2026-07-27** — one month ago — activating v4
  protocol fees on Ethereum, Arbitrum, Base, BNB, Polygon, OP Mainnet and others.
- Reported magnitude **~1/6 of the swap fee (~5 bps on a 30 bps pool)** = ~500 pips, **half the legal
  maximum**. **Independent consistency check: that "1/6" matches the code's own arithmetic exactly**
  (`500/(3000x0.9995) = 16.7%`), which materially raises confidence in the reporting.
- Mechanism: a `V4FeeAdapter` registered as `protocolFeeController` + a `V4FeePolicy` classifying pools.
  **Hook pools are reportedly excluded FOR NOW**, but classification is a governance-permissioned role
  via `setHookFamily` / a `pairClassFees -> familyDefaults -> defaultFee` waterfall, and **no opt-out for
  hook developers exists** — which is exactly what the code says (there is no on-chain opt-out).
- **Consequence for the P1/P2 decision: P1 is no longer a safeguard against a remote contingency. It
  would ship a product whose trading a live, already-executed governance mechanism can halt by
  reclassifying our hook family — with no opt-out and no notice.** This moves the recommendation
  decisively to P2.
- One press claim — *"LP rates are unchanged"* — **is corroborated by our own measurement**, and it
  matters for how we describe the bug: the fee **composes on top of** the LP fee (the swapper pays
  more) rather than splitting it. `test_E5_swapperPaysMore_lpIncomeRoughlyUnchanged` confirms it.
  **So the queue's LPs do not lose a third of their income; the LEDGER over-credits by the protocol's
  share, which is ~1/3 the size of true LP income.** Do not describe this as "LPs lose a third".

**Open / unverified — do not claim:**
- The above is press-sourced. **Verify on-chain before relying on it**: `poolManager.protocolFeeController()`
  and `StateLibrary.getSlot0(poolId)` answer it directly. Exact per-pool values, and whether a hook like
  ours would today be classified into a nonzero family, are UNVERIFIED.
- P1 is a *liveness* surrender: a governance fee-set halts trading until the hook is redeployed.
  Funds stay safe and withdrawable. Accepted consciously; revisit if P2/P3 is built.

**Housekeeping:** `foundry.toml` gained a `[profile.spike]` (archived src/test paths) so the archived
spike runs unmodified; the default profile is untouched. A subagent had un-ignored two private chat
logs in `.gitignore`; reverted. **No mechanism code written — Phase 0 is still NOT STARTED.**

### 2026-08-26 — design phase closed, build not started
- QUEUE selected after an exhaustive candidate search. Honest score **4.33** on the published rubric.
- Alternatives assessed and rejected with evidence, all archived: a hook-safety/bonding platform
  (sound but unwinnable — the security lane is 0 for 9 across eight cohorts), permissioned pools
  (Uniswap shipped it, hit the same wall we did, zero on-chain adoption), a CPG static-analysis
  product (off-chain, fails the "must be a hook" gate), and four fee-mechanism designs that topped
  out at 3.95.
- **The structural lesson that produced QUEUE:** every earlier candidate was a *fee mechanism* —
  it answered "who pays and how much". Winners in this competition **mint a new tradeable object**.
  That reframe is what moved the ceiling.
- Repository archived to `archive/2026-08-26/`. Clean ground prepared.
- **Next action: `PLAN.md` Phase 0.** Reproduce the reference spike from
  `archive/2026-08-26/test/spike/QueueAllocator.t.sol` in the new `test/queue/` tree and confirm the
  three negative controls still go red. **Do not write new mechanism code until that is green — and
  do not trust it green until the controls are red.**
