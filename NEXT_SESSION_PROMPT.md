You are picking up an in-progress Uniswap v4 hook project called QUEUE, in the repository at
`/Users/mishoko/projects/UHI10`. You have no prior context and you do not need any — everything
required is in the repo.

=======================================================================
WHAT QUEUE IS — AND THE FRAME MATTERS AS MUCH AS THE CODE
=======================================================================
Every Uniswap version — v1 through v4 — fills PRO-RATA. Inside a tick, every LP is filled in
proportion to their size. Nobody is first, nobody is last, and no amount of money buys a better
place in line. That was not an accident: pro-rata is stateless, needs no ordering, and is trivially
permissionless. But it is a CHOICE, and in seven years and four major versions it has never been
compared against anything, because on Uniswap there has never been anything to compare it against.

QUEUE is the comparison. The hook custodies the pool's entire liquidity as ONE position and
allocates each swap FRONT-FIRST through an ordered list of 32 seats. Each seat is held under a
self-assessed, always-for-sale HARBERGER lease: you post your own price, you pay continuous rent on
it to the seats behind you, and anyone may take the seat from you at your own number, at any time.

**READ `README.md` FIRST AND DO NOT RE-DERIVE THE PITCH.** It was rewritten on 2026-08-28 and it is
now the canonical framing. The three things it says that you must not lose:

  1. **The decision being challenged is pro-rata fill**, and the sharpest form of the claim is:
     *Uniswap did not eliminate the value of queue position — it made it unpriceable INSIDE the
     pool, which means it gets captured OUTSIDE the pool, at the sequencer.*
  2. **Why PAID seats rather than an open, arrival-ordered queue.** This is the question the design
     lives or dies on. Free rank is griefable rank (if arrival grants rank, the head costs one wei —
     dust it and you own the book). Unbounded rank is worthless rank (a non-scarce asset has no
     price, so no rent flows to the tail). **Scarcity IS the mechanism, not a gas concession** — and
     the Harberger lease is what stops a scarce roster becoming a cartel. *Scarce, but never
     capturable.*
  3. **It is an experiment that produces a number nobody has**: the self-assessed price of the head
     seat. Both answers are results — near zero says pro-rata was right all along and now we KNOW;
     high says Uniswap has been giving away for free the asset every other market charges most for.

DO NOT say "every real electronic market is price–time priority" as the headline. QUEUE is NOT
price–time priority — its roster is closed and the "time" is gone — and a judge who knows markets
will say so in the first thirty seconds. `PLAN.md` §A.3 explains why the sharpened form is both
honest and stronger.

=======================================================================
WHERE THE PROJECT IS RIGHT NOW
=======================================================================
Phases 0 through 6 are COMPLETE and committed. **THE PROJECT IS PAST ITS SUBMITTABLE STATE.**

    forge test                 ->  163 passed, 0 failed        (13 suites)
    forge lint src/            ->  clean, zero notes
    python3 script/mutate.py   ->  66 mutations, ZERO survivors

WHAT EXISTS:
  src/queue/QueueHook.sol             the hook: allocator, cursors, fund/withdraw, float, sweep,
                                      seat evacuation, pending claims, the rank permutation, and
                                      the whole Harberger lease
  src/queue/QueueSeats.sol            the ERC-6909 rank token: one id per seat, supply one
  src/queue/libraries/Allocation.sol  the allocation arithmetic, pure and fuzzable
  src/queue/libraries/Rent.sol        the rent arithmetic; its DISTRIBUTION reuses Allocation
  test/queue/                         12 suites + a shared fixture + a TEST-ONLY harness
  test/queue/handlers/QueueHandler.sol  the Phase 6 bounded actor
  test/queue/Invariant.t.sol          11 invariants x 256 runs x 64 depth, plus test_6_0
  test/queue/Adversarial.t.sol        every named attack in PLAN §C.6, each with an asserted outcome
  test/queue/Gas.t.sol                EVERY gas measurement in the project
  script/mutate.py                    the mutation harness. NOT part of the build. RUN IT.

=======================================================================
WHAT PHASE 6 FOUND — READ THIS BEFORE YOU TOUCH ANYTHING
=======================================================================
The invariant campaign found **THREE REAL BUGS** in code that had already passed 135 tests and 61
mutations. All three were reachable through the ordinary public API and none was visible to any
correctness test. All three are fixed, each has a directed regression and a mutation of its own.

  1. **PITFALLS 5.73 — the degenerate fill left a cursor LEADING a funded seat.** A swap whose
     output rounds to zero credits its whole input to one seat. `_allocate` has always pulled the
     incoming token's cursor back; the degenerate path never did. Every later swap in that direction
     then starts BEHIND a funded seat — silent theft of rank. FIFTH instance of "one rule, two
     places, right in only one of them".
  2. **PITFALLS 5.74 — an ADD can CREDIT the caller, and the measurement was unsigned.**
     `modifyLiquidity` realises accrued fees on every call, so when fees exceed the principal being
     added the hook's balance goes UP on an ADD. `unlockCallback` underflowed, and `addToSeat` and
     `sweepFloatIntoPosition` — THE ONLY TWO PATHS CAPITAL HAS INTO THE QUEUE — reverted with an
     arithmetic panic on any pool with real accrued fees. **NEVER PREDICT THE SIGN OF A BALANCE
     CHANGE FROM THE SIGN OF THE REQUEST YOU MADE.**
  3. **PITFALLS 5.76 / 5.77 — liquidity sizing reverted at a tick boundary, on BOTH sides.**
     v4-periphery's `getLiquidityForAmounts` narrows EACH leg to uint128 before taking the minimum,
     so a leg that decides nothing reverted the deposit (measured: 393e18 of token1 reverted while
     the binding leg was 1,033). And `_liquidityToCover` divided by a span that goes to zero at the
     tick, which `FullMath.mulDiv` reports as EMPTY REVERT DATA — blocking `withdraw` AND the seat
     evacuation. **A revert on the evacuation path is an incumbent VETO on their own buyout**, which
     §B.8 removed on purpose.

TWO THINGS THAT WERE WRONG IN OUR OWN INSTRUMENTS, NOT IN THE CODE:
  - **PITFALLS 5.75** — `_positionValue()` overstated the position by 8.28e18 wei because
    `minUsableTick(60)` is -887220 while `MIN_TICK` is -887272, so a "full-range" position's range
    CAN be left. INVARIANT F looked broken while the ledger was correct to 12 wei, and TWO WRONG
    EXPLANATIONS were entertained before the instrument was suspected.
  - **PITFALLS 5.79** — `script/mutate.py` left a mutant on disk when interrupted. A whole campaign
    ran against the mutated hook and the only symptom was a BAD-PATTERN on the one mutation that
    targeted that exact line. Now fixed with `try/finally`.

TWO THINGS PLAN §C.6 ASKED FOR THAT RESTED ON FALSE PREMISES — corrected in place, do not re-add:
  - I6 named `seatIndex`/`indexSeat`, which Phase 4 deliberately replaced with one packed `order`
    word and a scanning `rankOfId`. Live form: `order` is a permutation of `0..n-1` and
    `rankOfId(idAtRank(r)) == r` at every rank.
  - **`QueueUnderflow` IS STRUCTURALLY UNREACHABLE THROUGH THE POOL** (PITFALLS 5.78). A swap takes
    out only what the POSITION holds; INVARIANT F says the position never exceeds the ledger
    (surplus measured at EXACTLY 0 wei over the whole campaign); INVARIANT C says everything below
    the cursor is empty. There is no "swap one wei larger than the queue".

THE RESIDUAL CLAIM WAS CORRECTED (PITFALLS 5.80). "~0.15 wei per swap" holds AT THE SEEDED PRICE AND
NOWHERE ELSE. A drained pool pushed to the tick floor loses ~1e9 wei on one swap. What generalises is
the ratio against LIFETIME INFLOW, not the current ledger. Measured: worst SURPLUS exactly 0 wei,
worst SHORTFALL under 1 part per billion of lifetime inflow — and **the LAST holders to withdraw
bear it**. Say that; do not say face value is redeemable.

=======================================================================
START BY READING, IN THIS ORDER, AND DO NOT SKIP ANY
=======================================================================
  1. README.md     — THE FRAME. Rewritten 2026-08-28. Do not re-derive the pitch.
  2. AGENTS.md     — how to work here. The five laws (LAW 4 amended 2026-08-28), the decision
                     framework, §3b THE TESTING ARCHITECTURE. It is NOT TDD.
  3. PLAN.md       — opens with a BUILD STATUS dashboard. Then §C.7 (Phase 7) and §D.9 (the "how to
                     know you are done" checklist). Read §B.9 before quoting any gas number, §B.10
                     before touching anything Harberger, and §A.3 for the sharpened thesis.
  4. PROGRESS.md   — the narrative, newest first.
  5. PITFALLS.md   — the standing hazard ledger, 80 rows in §5. READ §5 BEFORE YOU WRITE CODE.
                     5.73-5.80 are from the Phase 6 session and every one of them will recur.
  6. BUSINESS.md   — §0 is the new frame; §9 is the honest-limitations list, corrected.

Verify the ground before building on it (about 30 seconds):

    export PATH="$HOME/.foundry/bin:$PATH"
    forge test

Expect 163 passed / 0 failed. If not, STOP and report it rather than working around it.

=======================================================================
YOUR NEXT ACTION — PHASE 7: TESTNET, DEMO, README, VIDEO (PLAN §C.7, gate §D.9)
=======================================================================
Phase 7 is the last one and it is SHIPPING work, not mechanism work. In order:

  1. `script/DeployQueue.s.sol` using `HookMiner` + CREATE2. Templates are in
     `archive/2026-08-26/script/`. Deploy to **Unichain Sepolia only** — no mainnet, ever.
  2. The demo, run against the deployed hook: seed the roster, run a small swap (head fills), run a
     sweeping swap (the queue walks), transfer a seat, show the fills follow the rank, price a seat
     and have somebody buy it out.
  3. README — already carries the frame and the limitations. Add the deployed address and the demo
     transcript. **§7.5 requires every open weakness to be stated; they already are — do not trim
     them to make the page shorter.**
  4. The video, UNDER 5:00, human voice. Structure: the problem (Uniswap fills pro-rata and has
     never priced ordering) -> the mechanism (front-first allocation, one diagram) -> **why PAID
     seats** (free rank is griefable, unbounded rank is worthless, Harberger stops the cartel) ->
     how it compares (am-AMM auctions management rights to one winner per block; QUEUE sells an
     ordering over the existing LPs' capital, perpetually, to many holders, with no auction) ->
     the honest limitations, said out loud.

**§D.9 is the gate and every line must be a yes.** The am-AMM distinction is §7.6 and a judge WILL
test it (§E.14).

=======================================================================
SIX THINGS EARLIER PHASES BUILT THAT LATER PHASES DEPEND ON — do not undo any of them
=======================================================================
  - **THE ORDER IS ONE `uint256`, ONE SEAT ID PER BYTE.** `MAX_SEATS == 32` and the 32 bytes of a
    word are THE SAME FACT (`test_4_41` asserts the coupling). There is deliberately NO `rankOfId`
    mapping — a second copy of the order is a writer/reader pair that can disagree, and on this
    project that has now been wrong FIVE times. `rankOfId` SCANS the word.
  - **EVERYTHING KEYED TO A SEAT IS KEYED BY ID AND NEVER MOVES.** Capital, holder, lease. Only the
    ORDER moves. The cursors are RANKS.
  - **THE EVACUATION PATH IS UNBLOCKABLE ON PURPOSE**, and the buyout leans on it harder than the
    transfer does. Phase 6 found a revert on that path (5.77) and treated it as a security bug, not
    an inconvenience, because a revert there is an incumbent veto. The sale price is CREDITED as a
    `pendingWithdraw` claim rather than transferred on, for the same reason.
  - **RENT NEVER TOUCHES THE POSITION, `float0`, OR THE ALLOCATOR.** It moves escrow to escrow.
  - **A SEAT IS ONE STORAGE SLOT: `uint128 a0; uint128 a1;`** Every narrowing goes through `_u128`,
    which REVERTS rather than wrapping.
  - **THE POSITION MEASUREMENT IS SIGNED** (`_moved`), and the removal side asserts the sign it can
    predict (`UnexpectedPositionDebit`). Do not "simplify" it back to an unsigned subtraction.

=======================================================================
THREE OPTIMISATIONS ALREADY MEASURED AND REJECTED — do not re-propose without a better number
=======================================================================
  - **Copying the packed seat through memory**: WORSE, 8,477 vs 8,070 gas per seat.
  - **Hoisting `q.length` into an immutable**: 85 gas per swap (0.07%) and it BROKE `test_3_9`, the
    control proving the fixed roster is load-bearing (PITFALLS 5.70).
  - **The O(1) prefix-sum redesign (§B.11) is DECIDED: NOT SHIPPED.** Its objection is unanswered —
    a prefix-sum accumulator does not know which seat is "the last one filled" when the scalar is
    updated, so the remainder line has no lazy analogue.

=======================================================================
THE GAS NUMBERS (test/queue/Gas.t.sol) — all measured with state built in setUp()
=======================================================================
    seats     head-only        full sweep
      1        117,971          145,980
      2        117,989          173,950
      5        117,990          198,161
     10        117,990          238,511
     25        117,991          359,562
     32        117,992          416,053

    sweep(n) = 137,866 + 8,070*n + 19,900*[n >= 2]      (every row to within 3 gas)

  - Head-only is FLAT: a 21-gas spread from 1 to 32 seats. That is the cursors working.
  - vs NO HOOK AT ALL, same pool shape, same swap: 117,989 vs 86,820 = **+31,169, +36%**.
    Say +36%. The claim worth making is that the overhead is a CONSTANT a trader can price.
  - **Worst-case addToSeat = 2,610,805.** This, NOT the sweep, is what bounds the roster: it is
    O(priced ahead x roster), i.e. QUADRATIC (PITFALLS 5.72).

=======================================================================
HOW TO WORK HERE — THIS IS NOT TDD
=======================================================================
BUILD FAITHFULLY -> ATTACK IT -> FIX WHAT THE ATTACK FINDS. The third step is the one that matters.

**MUTATION TESTING HAS FOUND A REAL DEFECT EVERY SINGLE TIME IT HAS BEEN RUN — NINE FOR NINE.**

    python3 script/mutate.py                    # all 66, against the full suite
    python3 script/mutate.py M17 M18            # a subset
    python3 script/mutate.py --campaign M62 M63 # against the INVARIANT SUITE ONLY, naming the
                                                #   invariant that caught it (PLAN §D.8 V3)

ADD A MUTATION FOR EVERY LOAD-BEARING LINE YOU WRITE. A mutation that SURVIVES is a finding with
exactly three honest responses: (a) write the missing test, (b) DELETE the line if nothing depends
on it, (c) write down why it cannot be tested. Widening a tolerance is none of these. In this
session M65 survived, and the honest answer was (a) — the directed test had driven the price PAST
the tick instead of NEAR it, so it was exercising a different branch entirely.

THE FIVE LAWS OF TESTING — all five were paid for:
1. NEVER test at a 1:1 price. Use 1:4 or worse, with unequal decimals. v4 works in RAW units, so
   fixture amounts must be in the pool's RAW ratio regardless of decimals.
2. Every claim needs a negative control that goes RED, and you MUST assert the revert REASON.
3. Measure conservation on PoolManager's own balances, NET OF protocolFeesAccrued. Conservation of
   the LEDGER and redeemability of the POSITION are two claims needing two assertions.
4. Measure gas with `vm.cool()` AND BUILD THE STATE IN `setUp()`. `vm.cool()` resets the EIP-2929
   access list but NOT the value EIP-2200 meters a WRITE against.
5. A first-run pass is a reason for SUSPICION, not satisfaction.

THE RULES PHASE 6 ADDED, ALL OF WHICH WILL RECUR:
6.  **NEVER PREDICT THE SIGN OF A BALANCE CHANGE FROM THE SIGN OF THE REQUEST YOU MADE** (5.74).
7.  **A LEG THAT IS NOT BINDING MUST NOT DECIDE THE OUTCOME** — take minima in full width, narrow
    once (5.76).
8.  **A ZERO SPAN IS AN ANSWER, NOT AN ERROR**, and an EMPTY revert is a bare `require` below you
    (5.77).
9.  **UNDER `fail_on_revert = false`, AN ASSERTION INSIDE A HANDLER IS A REVERT AND IS SWALLOWED.**
    Use ghost COUNTERS that an invariant asserts are zero.
10. **A COVERAGE FLOOR CANNOT LIVE IN `afterInvariant`** — the shrinker answers it by shrinking to a
    one-call sequence. Use a deterministic scripted campaign (`test_6_0`).
11. **A TOOL THAT EDITS `src/` MUST RESTORE IT IN A `finally`** (5.79).
12. **BEFORE BELIEVING A MEASUREMENT, SUSPECT THE INSTRUMENT** — twice this session the instrument
    was wrong and the code was right (5.75, 5.79), and both cost more time than any real bug.

=======================================================================
HARD CONSTRAINTS — DO NOT VIOLATE
=======================================================================
- No off-chain components. No server, relay, keeper, watch-tower or scanner.
- No mainnet deployment. Unichain Sepolia only.
- Do not try to detect toxic flow. Proven impossible for a v4 hook.
- Do not attempt a curve that reduces LVR. Proven impossible.
- **NO PER-BLOCK REFERENCE, EVER.** PLAN §B.12 counts "waiting one block boundary" as a PROVEN
  evasion — 200 ms on Unichain — and QUEUE passes that table precisely because it has none.
- No admin function, upgrade path or privileged role without asking. THE SHIPPING CONTRACT HAS NO
  PRIVILEGED ROLE AT ALL.
- Never let untrusted code choose how much memory you allocate. Use bounded assembly copies.
- Harberger is NOT a margin engine. No collateral, no oracle, no mark, no liquidation crank.
- Do not call it an auction. It is a self-assessed, always-for-sale lease with continuous rent.

=======================================================================
KNOWN WEAK POINTS — BE READY, DO NOT DISCOVER THEM ON CAMERA
=======================================================================
- HARBERGER CANNOT EXPRESS A NEGATIVE SEAT VALUE (5.10). Under toxic flow everyone declares near
  zero, no rent flows, and the front is free to take. Unsolved, and not solvable in this design.
- RENT IS `currency0`, WEIGHTED BY `currency0` (5.19). A tail holding only `currency1` is paid
  nothing and the rent waits in `unallocatedRent0`. `test_4_43` asserts this rather than hiding it.
- ENFORCEMENT NEEDS SOMEBODY TO POKE `settleRent` (5.64). Nothing ships that does. The incentive is
  on-chain and real, but a seat nobody wants and nobody pokes accrues a debt nothing collects.
- TAU IS A LOAD-BEARING PARAMETER. Do not defend a value. Do NOT claim the sign of the seat price
  reveals toxicity — 5.20 says that is overclaimed and no simulation supports it.
- FULL-RANGE DEPTH is the sharpest unanswered attack (5.17). ~1/200th the depth per dollar of a
  ±1% concentrated position. OWNER DECISION: answer it, do not fix it.
- THE SWEEP IS BOUNDED BY THE SMALLER LEG (5.43), and a SEAT TRANSFER IS A SECOND TRIGGER FOR THE
  SAME DRAIN (5.56). Do not claim seat trading is depth-neutral.
- **THE REDEMPTION RESIDUAL IS NOT A PER-SWAP CONSTANT** (5.80). Under 1 ppb of lifetime inflow,
  surplus exactly 0 — and the LAST holders to withdraw bear it.
- THE REENTRANCY GUARD PROTECTS A MEASUREMENT, NOT A PROVEN THEFT (5.55).
- THE FOUNDING ROSTER IS STILL CHOSEN BY WHOEVER DEPLOYS. Every founding seat starts UNPRICED, and
  an unpriced seat is free for anyone to take.
- **QUEUE COSTS A TRADER 36% MORE PER SWAP THAN A BARE v4 POOL** (5.71). Say the number.
- **`addToSeat` IS QUADRATIC IN THE ROSTER** at 2,610,805 gas worst case (5.72).

=======================================================================
COMMANDS — ALL VERIFIED BY EXECUTION 2026-08-28
=======================================================================
    export PATH="$HOME/.foundry/bin:$PATH"

    forge build
    forge test                                                   # 163 passed
    forge test --match-path "test/queue/Invariant.t.sol" -vv      # 13 passed, GATE 6 + coverage log
    forge test --match-path "test/queue/Adversarial.t.sol"        # 15 passed, the named attacks
    forge test --match-path "test/queue/Gas.t.sol" -vv            # 7 passed, the printed gas table
    forge test --match-path "test/queue/Harberger.t.sol"          # 47 passed, Phase 4's gate
    forge test --match-path "test/queue/Rank.t.sol"               # 19 passed, Phase 3's gate
    forge test --match-test <name> -vvv
    forge fmt src/ test/queue/
    forge lint src/                                               # must stay CLEAN, zero notes
    python3 script/mutate.py                                      # 66 mutations, must be 0 survivors
    python3 script/mutate.py --campaign M62 M63 M64 M65 M66       # §D.8 V3, names the invariant

    # If an invariant replay gets stuck on a stale counterexample:
    rm -rf cache/invariant/failures

NOTE ON DEPLOYING THE HOOK IN TESTS: the constructor takes NINE arguments —
    (poolManager, c0, c1, FEE, SPACING, roster, rentBps, rentPeriod, firmWindow)
**Never write that list out by hand.** The fixture has ONE place it is written, `_ctorArgs(roster)`,
plus two overloads: `_ctorArgs(roster, fee)` and `_ctorArgs(roster, bps, period, window)`.

`BaseHook` validates the deployment address in ITS constructor, which runs FIRST — so a plain
`new QueueHarness(...)` dies on the hook-flags check. Use `_expectDeployRevert` (Rank.t.sol) or
`_expectCtorRevert` (Harberger.t.sol) to assert constructor reverts.

FIXTURE HELPERS YOU WILL NEED:
    hook.ranking() / hook.idAtRank(r) / hook.rankOfId(id) / hook.orderWord()
    _swap(zeroForOne, amountIn)          — witness-aware, traded from address(this)
    _swapFrom(who, zeroForOne, amountIn) — witness-aware, traded from a chosen actor (Phase 6)
    _withdrawTracked(seatId, w0, w1)     — witness-aware withdrawal; debits by what was PAID (F1)
    _refDemote(seatId)                   — the witness's copy of a demotion
    _check(tag)                          — ledger conservation AND every seat against the witness
    _checkOrder(tag) / _checkInvariantC(tag) / _checkInvariantF(tag, tol) / _checkInvariantR(tag)

Our goal is to deliver a robust Uniswap v4 hook, per the plan, that makes sense to exist and to
present to a wide audience. If something touches the impact or the quality of the end product, we
can discuss it in business terms. Otherwise decide implementation details and small course
corrections yourself, with the expert panel. The end product must make total sense and be usable
cleanly, with no hidden caveats and no uncomfortable truths. It is NOT acceptable to label a problem
or add a comment when you see one — it gets properly fixed, in a robust and sustainable way, even if
that means deleting docs or tests. No laziness. No band-aids.

At the end of the session, update the status, commit, and rewrite this document
(`NEXT_SESSION_PROMPT.md`) so the next fresh agent is productive from the first minute. It must be
self-contained, and every command in it must be verified by execution.
