# SESSION HANDOFF — QUEUE, after Phase 9 (2026-09-02)

**Read order: this file → `AGENTS.md` → `docs/research/seat-economics/FRONTIER.md` → `PITFALLS.md`
§5.136–5.149 (fourteen new rows, four of them retractions of our own published numbers) → `PLAN.md`
when you write code.**

**This file is self-contained. You do not have the conversation that produced it and you do not need
it.**

---

## 0. START HERE — THE STATE OF THE TREE, WHICH IS UNUSUAL

**Phase 9 ran as a multi-agent session and it ended with a large UNCOMMITTED working tree.** Before
you do anything:

```bash
git log --oneline -4          # expect 76e788e, f82ad28, 8eb3d44 on top of 2d2a26f
git status --porcelain        # expect ~19 modified + ~5 untracked
ls .forge-snapshots/MUTATION_IN_PROGRESS   # MUST NOT EXIST. If it does, see §6.
git diff --stat src/          # expect a few hundred insertions across QueueHook.sol +
                              # QueueSeats.sol. Do NOT match an exact count -- it moved while
                              # agents worked. What matters is that the ADDED SYMBOLS are the
                              # Phase 9 list in section 7 and nothing else.
forge build                   # must succeed
forge test                    # GET YOUR OWN NUMBER. Every count in this file was taken
                              # on a tree that other agents were still writing to, and two of
                              # them turned out to be phantoms. Trust nothing here you did not
                              # re-run yourself.
```

**THE THREE COMMITS OF PHASE 9 ARE DOCS-ONLY, DELIBERATELY.** `git diff --stat 2d2a26f..HEAD` is
nine `.md`/`.py` files and zero Solidity. **The committed contract is byte-identical to Phase 8's.**
That was a policy, and it is what made the session auditable: at any moment
`git checkout -- src/ test/ script/` returns a known-good contract with all the documentation intact.

**The uncommitted work is real, coherent, and was written by five different agents with single-writer
file ownership.** It was audited at session end for mutants, duplicated symbols and cross-agent
conflicts, and was clean on all three. **It was NOT committed because a teammate was still holding a
manual mutant on disk when the session closed, and committing a mutant is PITFALLS 5.121.**

**YOUR FIRST JOB: verify the marker is gone, run the suite, and commit the working tree yourself
after you have a number you trust.** Do not trust the numbers below without re-running.

---

## 1. THE ASSESSMENT — is this hook still interesting?

**As engineering: yes, unusually so. As a product: not as measured, and we can now say exactly why in
one line instead of by argument.**

> ### SLACK = c₁ · (LP − B₁)
>
> `c₁` = rank 1's share of the book's capital · `LP` = what a passive Uniswap LP earns on the same
> range · `B₁` = what rank 1 would earn doing its **next best thing**.
>
> **Rank 1's own return CANCELS** — and so do `N`, the capital schedule beyond `c₁`, the ordering
> rule, the premium's weighting, the rent, and φ.

Derived from the identity `Σ cᵢ rᵢ == LP`, confirmed to **2.4e-16** against an independent long-form
computation over 120 paths. The identity itself: 36 cells, worst residual **2.98e-14**, invariant to
φ. Reproduce: `python3 docs/research/seat-economics/frontier.py`.

**WHAT IT SETTLES PERMANENTLY — do not re-litigate any of it:**

* Set `B₁ = LP` (a yield seeker's alternative) and the slack is **exactly 0.0000** at any φ. **QUEUE
  can only clear for CONSTRAINED capital that cannot take the passive-LP option. The size of the
  product is the size of the constraint.**
* **Depth was never the economic variable; `c₁` was, linearly.** Shipped 5-seat (`c₁ = 0.333`) vs 32
  equal seats (`c₁ = 0.031`) is an 11× difference. **The dial is the head's capital share and the
  band width — never the seat count, never φ.**
* **No re-weighting of the premium can create value, only stop destroying it.**

**AND THE PART THAT DECIDES EVERYTHING: every `B₁` we can model sits AT OR ABOVE `LP`** — passive
LP, keeper at its best width, keeper routing conversions off-venue. **So measured slack is ≤ 0 and no
φ clears in any regime, by identity.** The product exists only if a real constrained desk has
`B₁ < LP`. **No simulator can measure that. Answer it with a phone call, not Solidity.**

### The direct answer to "what does seat N gain?"

| seat | gains | monetises how | why they'd fund |
|---|---|---|---|
| **1** | First fill, both directions, every trade, **with no rebalancing trade ever** | **A COST AVOIDED, not revenue** — you stop paying a keeper's conversion bill | only if you must hold ATM inventory anyway |
| **2–5** | A coupon out of seat 1's fee income | Yield above a passive LP | only if seat 1 accepts below-LP |
| **6–32** | **Essentially nothing.** At 32 equal seats `c₁ = 3%` and the whole surplus is 0.018 pp | — | **They would not. That is why we ship 5.** |

---

## 2. FOUR RETRACTIONS — every one was wrong in this project's own favour

Do not quote these; they appear in commits before `8eb3d44`.

| retracted | truth |
|---|---|
| "rank 1 beats a keeper by **30–758 points**" | Measured on a **32-equal book, $31,250 head**, then multiplied by the SHIPPED $333,333 head — across configurations our own docblock calls not interchangeable. Shipped-roster truth: **−1.1 to +9.7**. It also silently dropped the two TOXIC rows (5.141) |
| "replication costs **80–123%/yr**" | **Appears nowhere on disk.** Annualising all 30 cells produces neither number. **UNPROVEN** (5.141) |
| "φ window **[7455, 8312]** → φ = 7,900" | The sweep ran with `sim.PREM_WEIGHT = 'inventory'`, the **PRE-Phase-8 rule**. `report_shipping.py` never sets the flag; `sim.py:66` defaults to it. **The rule we ship has never been swept.** `results-addendum.txt` §E admits it, in the same commit (5.142) |
| "surplus ≈ **1.1%/yr**, thin but real" | Published to four documents and retracted the same day. `B₁` came from a keeper converting **against its own pool** — 88% of its cost. Off-venue at 5 bps it scores **+6.20% vs LP +5.02%** (5.140) |

**THE TRANSFERABLE LESSON:** the width-axis handicap was caught, the corrected number published, and
it was **still** handicapped on the conversion-venue axis nobody enumerated.

> **"I swept the parameter that was wrong" is NOT "the benchmark is now allowed its best move."**
> Enumerate a benchmark's axes before trusting a max. **The handicap survives in the direction that
> flatters you, because a baseline that makes your number look good is the one nobody re-reads.**

---

## 3. DEFECTS FOUND IN PHASE 9 — against a baseline of 248 green / 80 mutations RED / 0 survivors

| | defect | status |
|---|---|---|
| 1 | **A THIRD evacuation door: the sybil buyout.** +267 bps, rank kept, rent 0, 516,741 gas. Kills every "a PAID takeover keeps its rank" remedy | **FIXED** — "rank is backed by depth" |
| 2 | **`buySeat` had NO RANK GUARD.** Seller front-runs a buyout with `withdraw(all)`; buyer pays rank-0 price for a tail seat | **FIXED** — `maxRank` param |
| 3 | **INVARIANT L broke by 20% of the position on an ordinary buyout, IN BAND**, on committed HEAD. `standingL` is the premium's denominator — corrupt it and the premium switches itself OFF | **FIXED** — the mirror branch in `_onSeatTransfer` |
| 4 | **INVARIANT L was not in the invariant campaign at all**, though the handler already called `buySeat`. That is *why* (3) survived six phases | **FIXED** — `invariant_I9` + ghost counter |
| 5 | **THE POOL BRICKS AT MATURITY.** Position holds 4.9567e16 wei of token0 and quotes 2.573e17 of liquidity **it cannot trade**; every one-for-zero swap reverts `QueueUnderflow` | ⚠ **OPEN — see §4.1** |
| 6 | **`QueueUnderflow` IS reachable through an ordinary swap.** `test_6_15` said in capitals it was not; its argument was true when written and **Phase 7 falsified it** | **FIXED** in 4 places |
| 7 | **One wei of currency0 takes 100% of a rent pot above the band.** `_distributeRent` has a `w == 0` branch and no `w == 1` branch | ⚠ **OPEN — see §4.2** |
| 8 | **`_settlePremium` erases a seat's accrued premium** at an exact-fill boundary — advances a mark on a seat the walk never visited | ⚠ **OPEN, CONFIRMED — 7.17e19 wei erased, both directions** |
| 9 | **A FOURTH evacuation door.** `withdraw` demotes only when it PAID, and paying is conditional on a BURN — but a payout the FLOAT covers burns nothing. Pre-fund the float, withdraw everything, keep the rank. Measured: 500e18 + 125e18 out, **zero burn, rank 1 retained** | ⚠ **OPEN — and it CONTRADICTS a shipped rule, see §4.1a** |
| 10 | **The pure-rank early return in `_onSeatTransfer` never zeroed `s.liquidity` at all** — the sibling branch of defect 3, found only after 3 was fixed | **FIXED** — `test_8_16` |

---

## 4. WHAT TO DO NEXT, IN STRICT ORDER

**Each depends on the previous being trustworthy. This ordering was derived, not chosen.**

### 4.0 FIRST: verify and commit the inherited tree
Run §0's checklist. Get your own suite number. Then run the mutation campaign —
`python3 script/mutate.py > /tmp/c.log 2>&1; echo $?` — **never piped** (5.134). Then commit.
**Phase 9 could not do this because a teammate held a mutant at session end.**

### 4.1a ⚠ DECIDE THIS FIRST — TWO SHIPPED RULES CONTRADICT EACH OTHER

**This is an OWNER DECISION, not a bug fix, and everything about rank stability sits on it.**

`withdraw` demotes only when it PAID something (5.122's remedy). What it pays is conditional on a
BURN. **A payout the FLOAT can cover burns nothing.** So: pre-fund the float, withdraw your entire
balance, burn zero, keep your rank — executed as `test_8_15`, **500e18 + 125e18 out, zero burn, rank
1 retained.** The float is nearly free to build, because a single-token in-range deposit mints zero
liquidity and lands in the float whole while the depositing seat is credited every wei.

**But it cannot simply be patched, because it contradicts `test_8_9`.** 5.130 exists precisely
because "any payout demotes" cost an honest LP their rank for taking profit, and `test_8_9` encodes
the refined rule — *taking earnings does not cost a rank, taking DEPTH does* — by defining
"earnings" as a withdrawal the float can cover. **Pre-funding the float makes everything look like
earnings.** The same observable means "profit" to one test and "evacuation" to the other. **They
cannot both stand as written, and choosing changes who keeps rank.**

**The likely resolution, not built:** stop asking what was BURNED and ask whether the seat's
`liquidityContributed` fell across the call — the quantity `_settleRankOnTransfer` already uses on
the transfer path, which would make one rule serve both writers. **Verify that against BOTH tests
before believing it.**

### 4.1 THE BRICKED POOL — highest-value defect remaining
Root-caused. The degenerate-fill branch is gated on `if (amtOut == 0)` — a **total** absence of
output, with no notion of a partial fill. **Do NOT widen that gate**: that branch credits the whole
input to a seat, so applied here it credits seats for output they did not provide and breaks
INVARIANT F in the other direction — **a loud revert traded for a silent insolvency.**

**THE FIX, designed and NOT built:** in `_settlePremium`, when excluding the payers leaves `w == 0`
— which happens *only* when the fill reached the tail — fall back to distributing over the full
`standingL`. *"The payer does not pay itself" has no meaning on a fill that sweeps the whole book.*
It cannot be gamed into `test_7_14` (that needed **one** unexcluded seat; this fires only at **zero**).
**If the pot never forms, the ledger is never short and the pool never bricks — defects 5 and 8 are
one bug.**

**⚠ THE TRAP:** `_settlePremium` removes the payers' weight AND moves their marks. Its docstring
warns that doing only the *second* strands the money; doing only the *first* strands it differently
(proved by `test_M7d`). **In the fallback branch the marks must move BEFORE the accrual.** It could
not be proven in a subclass because `_accruePremium` is `virtual` and `_settlePremium` is not.
**Diagnosis PROVEN; fix UNPROVEN. Label it that way until your tests say otherwise.**

**DO THIS FIRST, IT IS FREE:** mark `_settlePremium` `virtual`. It is the only member of its
neighbourhood that is not (`_allocate`, `_accruePremium`, `_syncSeat` and `_u128` all are), and its
absence is why the erasure fix in §4.3 could NOT be proven in a subclass the way `test_M12c` was —
a control would have to clone the whole allocator. One keyword makes a `test_M12c`-shaped control
writable in minutes.

**Backstop to ship alongside, not instead:** let `_allocate` draw a shortfall from `premiumHeld` up
to that pot and revert beyond it — keeping `QueueUnderflow` as the alarm for genuine divergence while
making it impossible to brick a live pool over provably claimant-less money.

### 4.2 RENT RE-WEIGHTING — designed at diff level, approved in principle, NOT built
Two lines in `_distributeRent`: replace `q[...].a0` with `q[...].liquidity` in both the weight loop
and the distribution loop. A `w == 1` special case is a **patch on a symptom** — no principled
threshold exists and an attacker sits just above it. **The real defect is that the weight is
denominated in the quantity front-first allocation deliberately destroys**, and `fundRent`'s own
docstring already makes that argument against `a0` for the rent SOURCE — nobody applied it to the SINK.

* `test_M9` (below band) is the positive control and must stay proportional.
* **`test_M9b` must INVERT** — it currently asserts the defect as an identity. **Invert it, do not
  delete it: the executed defect is the evidence the fix was needed.**
* Units become (liquidity ratio) × tokens — a cross-dimension divide, so **LAW 1 as amended: test at
  18/6 in BOTH directions.** Precedented (`_accruePremium` already does this shape), not novel.
* **⚠ CORRELATED FAILURE:** afterwards rent and premium are weighted by the SAME quantity, so one
  wrong `standingL` corrupts both streams at once, where today an error in one is visible against the
  other. **That is why `invariant_I9` had to land first — it now has.**

### 4.3 THE PREMIUM ERASURE — confirmed, unfixed
`test_W6`/`test_W7` in `PremiumWitness.t.sol` execute it: **7.17e19 wei erased** at an exact-fill
boundary, both directions. They currently fail by **one wei** against the witness's derived bound —
that is a bound question, not the defect. `_settlePremium`'s docblock calls this "deferred, never
destroyed"; deferral is what a HELD pot does and this is not one. **Correct the docblock as part of
the fix.** Likely closed by 4.1's fallback — check before building anything separate.

### 4.4 Then: re-sweep φ on the rule we actually ship
And evaluate **pure L-weighting with no exclusion** as the leading alternative: it caps `test_7_14`'s
dust attack at 12.5% (the attacker's own capital share), removes the over-exclusion, and converts
"the payer pays itself" from a hazard into a **known constant rescaling of φ** (measured: effective
8500 → 6800 at n=5). **A hazard converted into a change of units is a good trade.**

### 4.5 Then: close PITFALLS 5.133 — `QueueHandler` still never calls `_refAllocate`
The invariant campaign's 14/14 is incidental premium coverage, not aimed coverage. A spec exists.

### 4.6 Finally: broadcast (funded `PRIVATE_KEY`, chain 1301) and the video (<5 min, human voice)

---

## 5. PROVEN IMPOSSIBLE — DO NOT RE-OPEN

1. **Every seat beating a passive LP.** Identity, 2.98e-14, invariant to φ.
2. **Creating value by any ordering rule.** `SLACK = c₁(LP − B₁)` is independent of it.
3. **A senior/junior tranche.** One pro-rata position has ONE ordering.
4. **LIFO / unwind-backward.** Abolishes the queue; "unwind" is not observable to the contract.
5. **`sponsor()` / a DAO paying rent.** Pays MOST to capital that is never filled.
6. **Reducing LVR; detecting toxic flow.**
7. **Rolling the band without paying the keeper's conversion bill.** Both-tokens-to-span-spot is an
   identity, and **self-conversion recaptures EXACTLY ZERO** (the wallet gains what the position
   loses). **A pool whose wings are smaller than its roster cannot supply the conversion at any
   price.** `recenter()` stays unshipped — and its shelf README **overstates its own fix**: the
   over-broad guard (5.93b) is still there, so any full-range wing blocks it permanently.

---

## 6. HOW TO WORK HERE — the hazards Phase 9 paid for

* **Never pipe the mutation campaign.** `python3 script/mutate.py > /tmp/c.log 2>&1; echo $?` (5.134).
* **The interlock now covers manual mutations too** (5.146). If `.forge-snapshots/MUTATION_IN_PROGRESS`
  exists, `forge test` refuses. If a run died hard, delete it **and check `git diff src/` before
  believing anything.**
* **NEVER measure a tree that is being written to.** Phase 9 relayed **two phantom failures** as real
  findings because full-suite runs landed inside another agent's edit window. **The diagnostic is the
  message itself: a failure whose text exactly matches a mutation somebody is running IS that
  mutation.**
* **`git add <file>` commits a teammate's uncommitted work under your message** (5.147). Stage hunks,
  or read `git diff --cached` before every commit.
* **A comment asserting a safety property the code does not have is worse than no comment.** Three
  were found in Phase 9, one load-bearing for a security claim.
* **A number measured on one configuration is not portable to another** just because both are "the
  model". That produced two of the four retractions.
* **A mutant reading "0 wei caught" may be UNREACHED rather than undetected** (5.148). Before
  recording a survivor, prove the mutated line executed and could reach an assertion.
* **If you run agents in parallel: assign single-writer file ownership, and QUIESCE BEFORE YOU
  MEASURE.** Phase 9's throughput was real and so was the measurement noise.

---

## 7. WHAT PHASE 9 BUILT, so you can recognise it in the diff

`_settleRankOnTransfer` + `buySeatAndFund` + `fundOnTransfer0/1` (door a) · `rankAtPrice` +
`lastDemotionBlock` + `SeatWasJustPromoted` (door b) · `RankBelowMinimum` + `maxRank` (the rank
guard) · the INVARIANT L mirror branch in `_onSeatTransfer` · `invariant_I9` + its ghost counter ·
`Maturity.t.sol` (36 tests, the exit path, which had ZERO coverage before) · `PremiumWitness.t.sol`
(the premium witness, 4 mutants RED at 8.6e19–2.2e20 wei against a single-wei allowance) · the
premium half of `QueueFixture`'s reference witness (+734 lines) · `BUDGET` deleted from `Gas.t.sol`
and replaced with a derived slope assertion · `test_4_41` made a real coupling test.
