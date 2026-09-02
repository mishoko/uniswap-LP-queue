# SESSION HANDOFF — QUEUE, after Phase 10 (2026-09-02)

**Read order: this file → `AGENTS.md` → `PITFALLS.md` §5.160–5.171 → `PLAN.md` when you write code.**

**This file is self-contained. You do not have the conversation that produced it and you do not need
it.**

---

## 0. START HERE — THE TREE IS CLEAN AND GREEN. VERIFY IT YOURSELF.

```bash
git log --oneline -5                        # expect 4 Phase 10 commits on top of 8ef0ef0
git status --porcelain                      # expect CLEAN
ls .forge-snapshots/MUTATION_IN_PROGRESS    # MUST NOT EXIST
forge test                                  # GET YOUR OWN NUMBER. Expect 311 / 0 / 1 skipped.
```

**Every number in this file was produced on a quiesced tree with no agents running.** That is not a
courtesy — Phase 10 relayed a mutation result measured against the WRONG test suite (309 tests
instead of 346) because the orchestrator took the toolchain while a teammate still held the tree.
**Stop your agents before you run `forge` or `mutate.py`.**

---

## 0b. THE STRATEGY — WHAT WE SHIP AND HOW WE FRAME IT. THIS IS DECIDED; EXECUTE IT.

**Do not re-open the value question. Do not hunt for a better story. Build the four deliverables in
§0c and say the words in §0d.** Four theses were killed with pre-registered criteria (§4). Exactly
one claim survived, it is measured, and it is enough.

### THE ONE CLAIM WE MAKE

> **QUEUE is subordination for Uniswap liquidity. It is the first mechanism that lets one LP inside a
> single position take structurally worse fills so that another LP gets structurally better ones —
> enforced by the contract, not by a promise.**

### THE ONE APPLICATION WE LEAD WITH

> **Emissions-free liquidity incentives.** A protocol posts its own capital at the FRONT of the queue
> and accepts the worse fills. External LPs fund the BACK and provably out-earn passive LPing. No
> tokens printed, no dilution, no vesting, no forum post that can be reversed — the subsidy is fill
> order and rent routing, and it is mechanical.

### ⚠ THE NUMBERS — RETRACTED AND NOT YET REPLACED. DO NOT FILM UNTIL THIS IS FIXED.

**The table that stood here was wrong on four axes at once (roster, rank, φ, and premium basis) and
it is retracted in full. See PITFALLS 5.177–5.179. Nothing below is safe to say on camera yet.**

**1. It cherry-picked by omission.** It claimed *"p5 excess positive in EVERY regime, beats a passive
LP on 100% of paths."* `results-tranche.txt` has SIX config blocks; the table quoted four. The two it
omitted are where the claim fails — BENIGN ±30% (`results-tranche.txt:585-590`) reads rank 28 and
rank 32 at **p5 −4.96%, beat LP 77%**. "Every regime" was assembled out of the blocks that had been
read. Not intended; false as published, which is the only thing that matters.

**2. THE BASIS IS THE PRE-PHASE-8 PREMIUM RULE — the big one.** `sim.py:66` sets
`PREM_WEIGHT = 'inventory'` and **no report overrides it** (`report_shipping.py`, `report_tranche.py`,
`book_report.py` all inherit the default). The contract has weighted by CONTRIBUTED LIQUIDITY with the
payers excluded since Phase 8. **So `results-shipping.txt`, `results-tranche.txt`, `results-book.txt`,
the feasible window `[7455, 8312]` and the shipped `PREMIUM_BPS = 7,900` derived as its midpoint are
all on a basis the deployed contract does not implement.** PITFALLS 5.142 said this at the start of
Phase 10 and it was read, quoted, and then not applied. `report_depth_basis.py` exists to fix exactly
this and has no committed output.

**3. Several 5.160 magnitudes do not reproduce.** Regenerated from the (empty-committed)
`results-book.txt`: the pro-rata LP bar **+135.9 bps does not exist — +50.2 does**, the rows mixed φ
blocks, and the "−476 bps" cost of priority computes as **−391.9**. What DOES reproduce exactly is the
load-bearing falsification control: **+4.487 pp / −1.277 pp at t = +61.96 / −20.10.** So the
CONCLUSION of 5.160 stands — priority is a direction bet, not a gain — and its arithmetic does not.

### WHAT SURVIVES, AND MAY BE SAID

* **The mechanism.** Fill order inside one position is non-pro-rata, transferable and self-priced.
  That is a property of the code, not of a simulation. 314/0/1, 85/85 mutations RED.
* **The direction.** The front loses and the back gains, robustly, everywhere. Sign, not size.
* **The identity.** Capital-weighted return == the passive LP return, exactly. It is a TRANSFER.
* **Priority is worth negative money to its holder** (the mirror control reproduces).

### ✅ THE GATE IS CLEARED — the economics have been re-run on the contract's own premium rule

The gate this section used to set (*"re-run on `PREM_WEIGHT` matching the shipped contract, on the
shipped roster, and re-derive `PREMIUM_BPS` from that"*) was executed in Phase 11. See PITFALLS
5.178 and 5.180.

`report_shipping_basis.py` imports `report_shipping.py` **unchanged** and re-runs it at
`PREM_WEIGHT = 'liquidity_excl'`, the rule the hook implements (`_claims` reads `s.liquidity`,
`QueueHook.sol:1356`; denominator `standingL - excludedL`, `:1154`). **Control: at φ = 0 no premium
is withheld and the weight vector is never read, so the φ = 0 column must be identical between the
two runs — it is, in every row of every table, both sides, all three regimes.**

The feasible window moved, and **`PREMIUM_BPS` has been changed 7,900 → 5,100** accordingly:

| regime | old window (stale basis) | **new window (contract's basis)** |
|---|---|---|
| BENIGN | [7455, 8312] | **[4542, 5670]** |
| NORMAL | [4114, 8921] | **[2560, 6251]** |
| TOXIC | EMPTY | **EMPTY** — s2 never clears the LP |

### THE NUMBERS WE QUOTE — shipped roster, contract's basis, φ = 5,100

**Source: `results-shipping-basis.txt`. Roster: 5 seats, 5:4:3:2:1, $333,333 head, c₁ = 1/3.
Every row below names that fixture; 5.163 and 5.179 exist because rows that did not, drifted.**

| regime | band life | passive LP | rank 1 (the subsidiser) | seats 2–5, capital-weighted | (path,seat) cells beating LP |
|---|---|---|---|---|---|
| BENIGN | 61.0 d | +5.02% | +3.28% (**−1.74 pp**) | **+0.87 pp** | 68.1% |
| NORMAL | 19.1 d | +0.49% | −2.40% (**−2.89 pp**) | **+1.47 pp** | 84.8% |
| TOXIC | 1.4 d | −2.17% | −3.70% (**−1.53 pp**) | **+0.73 pp** | 75.8% |

**THE ONE NUMBER TO LEAD WITH, because it needs no simulator and cannot be quoted against the wrong
fixture.** From the identity `Σ cᵢrᵢ = LP`:

> `back's excess = c₁·(LP − r₁) / (1 − c₁)`  →  at c₁ = 1/3, **one point the front gives up buys the
> back exactly half a point.**

Verified against the contract-basis sweep in all three regimes: closed form **+0.87 / +1.44 / +0.77**
against simulated **+0.87 / +1.47 / +0.73**. It is invariant to the premium weighting, because the
premium is a transfer *inside* the book.

**AND THE DIVERGENCE WAS NOT ALL BAD NEWS.** The contract's real rule is materially better at moving
value backward than the basis we had been measuring: all of seats 2–5 clear the LP from φ = 4,542 in
BENIGN (was 7,455) and 2,560 in NORMAL (was 4,114). Less premium buys more subordination.

**WHAT IS STILL NOT SAYABLE.** `results-tranche.txt` and `results-book.txt` have NOT been re-run on
the contract's basis, so no per-seat number from either is quotable. `report_depth_basis.py` answers
the depth question and its run was still staging when Phase 11 ended.

### WHAT WE MUST NEVER CLAIM — each of these is disproven in this repo

* ❌ "LPs earn more here." The capital-weighted average IS the passive LP return, by identity.
* ❌ "Better execution / priority is valuable to the holder." Priority is worth NEGATIVE money to
  its holder — but **do not quote "476 bps"**: `results-book.txt` was committed EMPTY and, when
  regenerated, 5.160's LP bar of +135.9 bps does not exist (+50.2 does) and its rows mix φ blocks
  (PITFALLS 5.177). Computed consistently the two-ended BOOK costs **392 bps**, and **what we
  actually ship costs 133 bps**. The direction and the monotonicity reproduce; the magnitude did
  not.
* ❌ "A senior tranche with protected downside." Downdev ratio 0.0–1.6× and the TAIL IS WORSE (5.174).
* ❌ Any per-seat number without naming its roster. Three are in play (5.163); four retractions came
  from mixing them.

### THE HONEST CAVEATS WE STATE OURSELVES, BEFORE ANYONE ASKS

1. **It is a transfer, not creation.** The front pays for the back, exactly.
2. **Simulation only.** No live-pool data. 120 paths, four seed ranges, one pair.
3. **The subsidiser must post real capital** — roughly comparable to what it subsidises. This is not
   leverage on a marketing budget.
4. **+119% gas** for every trader on the pool (152,947 vs 69,970).
5. **The front seat is a bad investment and we will say so on camera.** That is the point: somebody
   has to volunteer, and the volunteer is the protocol, not a yield-seeker.

### WHY THIS EARNS RESPECT RATHER THAN RIDICULE

The Uniswap Foundation funds research concluding LPs lose money. This audience rewards measurement.
**Lead with the mechanism and the application; use the four killed theses as the credibility layer,
never as the headline.** "We tried to kill our own value proposition with pre-registered criteria and
succeeded four times, and here is the one claim that survived" is a strong position. "We found
nothing" is not the same sentence and must not be said.

## 0c. THE FOUR DELIVERABLES — nothing else

1. **The hook.** DONE. 311 tests, 85/85 mutations RED, four evacuation doors closed.
2. **A live demo on Unichain Sepolia** (funded `PRIVATE_KEY`, chain 1301) showing the subordination
   beat by beat: a protocol seat at the FRONT, external seats at the BACK, a swap, and the resulting
   split. `Deploy.t.sol` and `DeployFork.t.sol` already execute this path.
3. **A one-page results sheet**: the surviving claim with the §12 table, the four killed theses each
   with the number that killed it, and the five caveats above.
4. **The video, under 5 minutes, human voice.** Structure in §0d.

## 0d. THE SCRIPT — say it in this order

1. **The problem (30s).** Protocols print tokens to rent liquidity. It dilutes holders, the capital
   leaves when emissions stop, and the promise is a governance decision that can be reversed.
2. **The mechanism (60s).** Uniswap fills every LP in a position pro-rata — that is not a choice,
   it is the only option. QUEUE gives each funder a RANK and fills them in order. **Being first is
   BAD: you absorb the adverse selection first. We measured it.** So the front seat is a first-loss
   position, and everyone behind it does better.
3. **The application (60s).** The protocol stands at the front. External LPs stand behind. Show the
   §12 table. **State the transfer out loud.**
4. **The evidence (60s).** 311 tests, 85 mutations zero survivors, four evacuation exploits found and
   closed, and four business theses we killed ourselves with criteria written down in advance.
5. **The caveats (30s).** All five. Say them yourself.

---

## 1. THE ASSESSMENT — IS THIS HOOK STILL INTERESTING?

**The engineering is excellent and the mechanism is now sound. The investment thesis is DEAD, and as
of Phase 10 it is dead in BOTH of its halves. Do not spend another session looking. §5 is the list of
what is closed and why.**

Phase 9 closed the unconstrained buyer: `B₁ ≥ LP` by construction, because rank 1 can hold a static
position over the band for free and that returns exactly `LP` (4.3e-14). It explicitly left ONE door
open — a party whose mandate forbids passive LPing, whose alternative is paying taker cost — and
called that "a conversation, not a build."

**Phase 10 measured that party. It is worse off too.** TOXIC-DN, the only regime where such a mandate
is fillable at all (`conv>0 = 1.00`):

```
   who                       average price it BOUGHT at     vs a TWAP taker      SE
   an ordinary pro-rata LP           1906.99                    +135.9 bps      12.9
   QUEUE rank 0 (as shipped)         1932.41                    −108.2 bps      16.5
   QUEUE rank 0 (front-loaded)       1981.82                    −340.1 bps       9.9
                                       ▲
                    MONOTONE in how much priority you hold
```

**A plain Uniswap range order ALREADY beats trading as a taker by +136 bps. Buying priority takes you
to −340.** Priority is worth about **−476 bps** to its holder.

**The reason is physical, not parametric, which is why no configuration rescues it.** Pro-rata
spreads a fill across the whole move — **a pro-rata range order IS a TWAP.** Front-of-queue
concentrates the fill at the FIRST prices of a move, which for a buyer in a down-move are the HIGHEST
ones. **Being first in an AMM queue is absorbing the adverse selection first.** An end-heavy capital
schedule makes it WORSE, by putting rank 0 further forward.

**The control that settles it could have falsified the headline** (LAW 5, first corollary): a
monotone accumulator is long delta, so a genuine mechanism gain must SURVIVE a mirrored drift while a
direction bet must FLIP. Paired path-by-path: TOXIC `+4.487 pp` (t = +61.96), TOXIC-DN `−1.277 pp`
(t = −20.10). **It flips.**

### The sentence to hand anyone who re-opens this

> **A rank in the queue is the same economic object as a distance from the current price — and
> Uniswap's tick structure already sells that choice, for free, with no hook.**
> Front of queue ≈ liquidity nearest spot: fills first and most, worst prices, maximum adverse
> selection. Back of queue ≈ liquidity far from spot: fills rarely, best prices, least adverse
> selection. The ONE axis on which rank is genuinely new is that it sorts by **trade SIZE** — and
> trade size is forgeable by splitting a quantity, which is `AGENTS.md` §6's proven-impossible rule
> wearing a new hat.

### The direct answer to "what does seat N gain?"

The binding constraint is the identity `Σ cᵢrᵢ == LP` (2.98e-14, invariant to φ): the seats divide a
FIXED pie, so one seat above the line requires another below it by exactly as much.

| seat | what it gets | honest verdict |
|---|---|---|
| **1** | ~96% of all fills, the largest share of fee income — and first exposure to every adverse move | **The worst seat in the book.** Measured −108 bps against simply being a taker, where a pro-rata LP is +136 |
| **2–4** | Rarely filled (turnover 2.6 → 0.7 against rank 1's 122). Almost all of their economics is the coupon rank 1 pays | In a FALLING market they lose less than a passive LP, because rank 1 absorbs first. That part is real |
| **5–32** | Essentially never filled (`startshare` 0.0%). At 32 seats the head is 3% of capital and the whole distributable surplus is 0.018 pp | **Nobody would fund these.** |

**"Making money in all conditions" fails structurally, not by tuning:** the front seat is most exposed
in exactly the conditions where LPing loses money.

### What would make it interesting again — one paragraph, UNPROVEN, not built

The machinery that works — a transferable, Harberger-priced, rank-ordered claim with exact
conservation — is a **priority auction**. Phase 10 shows priority among LPs is worth negative money.
Priority among **takers** is not: the right to trade first against a pool in a block is worth exactly
the arbitrage it captures, and that value currently leaks to searchers rather than to LPs. `AGENTS.md`
§6 forbids a *curve* that reduces LVR; an auction is not a curve, and it detects nothing. **That is a
different product, it is a crowded field (Diamond, McAMM, Angstrom), and it is a rewrite of the
allocator — but it is the only direction consistent with everything this repo has proven.**

---

## 2. WHAT PHASE 10 BUILT

All four defects Phase 9 left OPEN are fixed **at the root**. No labels, no bandaids.

| defect | fix |
|---|---|
| **The bricked pool + the premium erasure — ONE bug** | `_settlePremium` took the CURSOR as its payer range, so it advanced the mark of a seat the walk never visited (7.17e19 wei); and a whole-book fill left `standingL − lTouched == 0`, so the pot was HELD forever, the ledger went short and `_afterSwap` reverted `QueueUnderflow`. `_allocate` now hoists its loop variable (no new local — it is at the stack limit); `_settlePremium` gained a `sweptBook` branch that distributes over full `standingL` and moves NO marks, and is `virtual`. **"The payer does not pay itself" has no meaning on a fill that swept the whole book.** |
| **Rent weighted by `a0`** | Above the band one wei took the ENTIRE pot. Both loops now read `liquidity`. A `w == 1` special case was considered and REJECTED. |
| **The fourth evacuation door** | A payout the FLOAT covers burns nothing, so nothing demoted while the whole balance left. **Resolved against 5.130: any payout costs the rank.** |
| **`test_8_10` (new)** | The demotion rule has two legs; each is now asserted directly. `p0`-only was caught by exactly ONE test before. |

Also: `RentDecimals.t.sol` (new, 18/6 AND 6/18), eleven tests INVERTED rather than deleted, the gas
slope re-derived (19,280 → 18,448) with a φ=0 control and its residual recorded UNPROVEN.

---

## 3. WHAT TO DO NEXT, IN ORDER

### 3.1 The mutation campaign is CLEAR — 85/85 RED, 0 survivors. Do not re-run it to "check".
Phase 10 ran the full campaign for the first time since Phase 8: **79 RED, 0 SURVIVED, 0 NO-COMPILE,
6 BAD-PATTERN**, then repaired all six patterns and re-ran them RED. **Effective total: 85 cases,
85 RED, 0 survivors, 0 bad patterns.**

**Three of those six had been silently dead since PHASE 9** (M32, M38, M41 — see PITFALLS 5.172), and
Phase 9's truncated run reported `0 BAD-PATTERN` because it never reached them. That is fixed with a
mechanism rather than a note: **`mutate.py` now PREFLIGHTS every pattern and exits 2 naming any that
does not match the source exactly once**, before running a single case. If you edit `src/` and a
pattern stops matching, you find out in milliseconds.
```bash
python3 script/mutate.py > /tmp/c.log 2>&1; echo $?      # NEVER pipe (5.134)
```
Note SIGINT does **not** stop it — it is absorbed. `kill -9`, then delete
`.forge-snapshots/MUTATION_IN_PROGRESS` and check `git diff src/` before believing anything.
**Never leave uncommitted work in `src/` while it runs.** And **do not wait on it with
`until ! pgrep -f "script/mutate.py"`** — that loop's own command line contains the pattern, so it
matches itself and never terminates (5.173). Poll the marker file instead.

### 3.2 Close PITFALLS 5.133 — `QueueHandler` still never calls `_refAllocate`
The invariant campaign's coverage of the premium is incidental, not aimed. A spec exists.

### 3.3 Write down the invariant 5.164 says is currently free
`_accruePremium` writes seat inventory and touches no cursor. That is safe **only because both
directions walk from the same end** — a property of the walk order, not of the code. `test_7_5` pins
the count of balance writers at six; nothing asserts the property those six must share: **every site
that credits a seat must leave it inside a window some cursor can still reach.**

### 3.4 Then: broadcast (funded `PRIVATE_KEY`, chain 1301) and the video (<5 min, human voice)

---

## 4. PROVEN IMPOSSIBLE — DO NOT RE-OPEN

1. **Every seat beating a passive LP.** Identity, 2.98e-14, invariant to φ.
2. **Any ordering rule creating value.** `SLACK = c₁(LP − B₁)` is independent of it.
3. **Selling priority to a constrained buyer.** −476 bps vs the pro-rata position it displaces
   (5.160). **This is the one Phase 10 added; Phase 9 left it open.**
4. **A two-ended book** (one roster read from both ends). Designed, simulated, killed: it makes the
   execution price WORSE, and the advantage flips sign under mirrored drift.
5. **A senior/junior tranche — RE-TESTED AND RE-KILLED IN PHASE 10, with the strongest version of
   the argument.** "Tranching allocates RISK, not return, and three sessions measured only return"
   is a good argument and it is still wrong here. `results-tranche.txt` §11 states the bar before
   the numbers — *"one to two orders of magnitude … or there is nothing being sold"* — and measures
   **0.0× to 1.6×**. In BENIGN ±30% the passive LP is strictly safer. **The tail is not protected at
   all: TOXIC ±30% worst is −6.49% for the back against −6.43% for the LP.** The seductive numbers
   (48× downside, 4,600× markout spread) are all back-vs-FRONT; the front is not a benchmark. See
   PITFALLS 5.174. **LIFO. `sponsor()` / a DAO paying rent.**
6. **Reducing LVR with a curve; detecting toxic flow.**
7. **Rolling the band without paying the keeper's conversion bill.** `recenter()` stays unshipped.

---

## 5. HOW TO WORK HERE

* **Quiesce before you measure.** Stop every agent before running `forge` or `mutate.py`. Phase 10
  measured a mutant against the wrong suite by ignoring this.
* **`git stash list` before concluding work was destroyed** (5.166). An agent stashing for a clean
  baseline empties the tree transiently. Use a WORKTREE or `git show HEAD:path` instead.
* **A BAD-PATTERN or a NO-COMPILE is an UNRUN case, never a pass.**
* **When a fix makes a control vacuous, RE-ARM it at the residual attack surface — never relax it**
  (5.167). That the control went vacuous is itself a finding.
* **Read the roster line before quoting any per-seat number** (5.163). Three configurations are in
  play: 32 equal seats of $31,250; 5 equal seats of $200,000; and the SHIPPED 5:4:3:2:1 with a
  $333,333 head. `results-exec.txt` §I is headed "THE SHIPPED ROSTER" and is **not** it.
* **Prefer a config-free form.** The subsidy needs no simulation: `back's excess = c₁(LP − r₁)/(1 − c₁)`,
  so at c₁ = 1/3 one point given up by the front buys the back exactly half a point.
