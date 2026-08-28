You are picking up an in-progress Uniswap v4 hook project called QUEUE, in the repository at
`/Users/mishoko/projects/UHI10`. You have no prior context and you do not need any — everything
required is in the repo.

=======================================================================
WHAT QUEUE IS, IN ONE PARAGRAPH
=======================================================================
Every concentrated automated market maker is a pro-rata market — all liquidity at a price level is
filled proportionally. Every real electronic market on earth uses price–time priority, where being
early in the queue is the single most valuable asset in market making. Uniswap has never had a
queue, so it has never had a price for one. QUEUE is a hook that custodies the pool's entire
liquidity as ONE position and allocates each swap FRONT-FIRST through an ordered list of seats.
Each seat is held under a **self-assessed, always-for-sale Harberger lease**: you post your own
price, you pay continuous rent on it to the seats behind you, and anyone may take the seat from you
at your own number, at any time.

=======================================================================
WHERE THE PROJECT IS RIGHT NOW
=======================================================================
Phases 0, 1, 2, 3, 4 and 5 are COMPLETE and committed. **THE PROJECT IS AT ITS SUBMITTABLE STATE.**

    forge test                 ->  135 passed, 0 failed        (11 suites)
    forge lint src/            ->  clean, zero notes
    python3 script/mutate.py   ->  61 mutations, ZERO survivors

WHAT EXISTS:
  src/queue/QueueHook.sol             the hook: allocator, cursors, fund/withdraw, float, sweep,
                                      seat evacuation, pending claims, the rank permutation, and
                                      the whole Harberger lease
  src/queue/QueueSeats.sol            the ERC-6909 rank token: one id per seat, supply one
  src/queue/libraries/Allocation.sol  the allocation arithmetic, pure and fuzzable
  src/queue/libraries/Rent.sol        the rent arithmetic; its DISTRIBUTION reuses Allocation, so
                                      there is one remainder line in the codebase, not two
  test/queue/                         10 suites + a shared fixture + a TEST-ONLY harness
  test/queue/Gas.t.sol                EVERY gas measurement in the project. Read its header before
                                      you measure anything, anywhere — see the LAW 4 note below
  test/spike/QueueAllocator.t.sol     the archived reference implementation (do not edit)
  script/mutate.py                    the mutation harness. NOT part of the build. RUN IT.

WHAT IS PROVEN (all executed, all against real v4 contracts deployed locally):
  - Front-first allocation is exact to the wei in both tokens, at 1:4, 1:1000, 1000:1, and at
    18/6 AND 6/18 decimals.
  - The protocol fee is handled correctly at a MAXIMUM fee, with lpFee == 0, and against a
    FOREIGN POOL sharing a currency.
  - Per-seat withdrawal works from a shared two-slot float, in all six orderings, with no
    poolManager.swap anywhere in the contract.
  - Rank is an ERC-6909 seat with supply exactly one, STRUCTURALLY.
  - The roster is fixed at deployment and there is NO runtime path that creates a seat.
  - Rent accrues exactly linearly in elapsed SECONDS, splits to the wei, is HELD rather than lost
    when nobody is eligible, and cannot be captured by a flash loan.
  - Under-pricing a seat gets it bought out; over-pricing pays for it. Both numerically.
  - Foreclosure DEMOTES to the tail — the holder keeps the seat and every wei of its capital.
  - The always-for-sale guarantee survives a holder who front-runs their own buyout.
  - The redemption residual is ~0.15 wei per swap per token, LINEAR and converging (asserted).
  - **NEW IN PHASE 5** — the seat balance pair is packed into one slot, every narrowing goes through
    one checked cast that REVERTS rather than wraps, and the packed ledger is wei-identical to an
    independent uint256 reference over >2,000 randomised swaps in both directions at three decimal
    pairs.

=======================================================================
THE ONE THING PHASE 5 FOUND THAT CHANGES HOW YOU WORK
=======================================================================
**`vm.cool()` IS NOT ENOUGH TO MEASURE GAS, AND EVERY NUMBER THIS PROJECT HAD RECORDED BEFORE
2026-08-28 WAS OPTIMISTIC.**

`vm.cool()` resets the EIP-2929 ACCESS LIST, so the next SLOAD costs 2,100 again. It does NOT reset
the value EIP-2200 meters a WRITE against. A slot the current test body already wrote is "dirty",
and writing it again costs **100 gas** instead of 2,900 or 20,000. So a suite that deploys, seeds
and then measures inside one test body is measuring a contract whose entire storage is free to
write. Measured, same swap, same `vm.cool()`:

    roster seeded in the test body   172,263
    roster seeded in setUp()         252,966      +47%

Forge commits `setUp()` as its own transaction. `vm.snapshotState()` + `vm.revertToState()` is NOT
a substitute — tested, identical numbers. AGENTS.md LAW 4 is amended; PITFALLS 5.66 has it.

Two corollaries you will hit immediately:
  - `vm.cool` is PER ACCOUNT and a v4 swap crosses six of them (hook, PoolManager, router, Permit2,
    both ERC20s). The FIRST measurement in a test body costs ~21,200 gas more than every later one.
    Burn a warm-up swap on a fixture you never measure. (PITFALLS 5.67)
  - **Before attributing a gas difference to the variable you were varying, RUN IT IN BOTH ORDERS
    and check it does not follow the order instead.** I explained that 21,179-gas artefact twice —
    plausibly, with the right order of magnitude — and was wrong both times.

=======================================================================
THE GAS NUMBERS, ALL RE-MEASURED HONESTLY (test/queue/Gas.t.sol)
=======================================================================
Complete swap transactions through the real V4SwapRouter against the real PoolManager.

    seats     head-only        full sweep
      1        117,971          145,980
      2        117,989          173,950
      5        117,990          198,161
     10        117,990          238,511
     25        117,991          359,562
     32        117,992          416,053

    sweep(n) = 137,866 + 8,070*n + 19,900*[n >= 2]      (every row to within 3 gas)

  - Head-only is FLAT: a 21-gas spread from 1 to 32 seats. That is the cursors working.
  - The slope is EXACTLY 8,070 — identical between every adjacent pair, not a fitted line.
  - vs NO HOOK AT ALL, same pool shape, same swap:  117,989 vs 86,820  =  **+31,169, +36%**.
    Say +36%. Do NOT claim the common case is free. The claim worth making is that the overhead is
    a CONSTANT a trader can price rather than something that grows with book depth.
  - Queue-attributable cost at MAX_SEATS = **278,110**, inside the stated 300,000 budget.
  - **Worst-case addToSeat = 2,610,805.** This, NOT the sweep, is what bounds the roster: it is
    O(priced ahead x roster), i.e. QUADRATIC, where the sweep is linear. Any proposal to raise
    MAX_SEATS must be argued against this number (PITFALLS 5.72).

PLAN §B.9's old table came from the Phase-0 SPIKE (no cursors, no owners, no seat tokens, no lease)
at 6,753 gas/seat, and MAX_SEATS=32 was justified as "comfortably inside 300k" on it. The real
figure was 12,254 — 37% OVER that budget. Packing brought it to 8,070. §B.9 is corrected in place
and `test_5_3b` now DERIVES the supportable depth (34) from the measurement, so the constant in the
source and the number in the document cannot drift apart again.

=======================================================================
START BY READING, IN THIS ORDER, AND DO NOT SKIP ANY
=======================================================================
  1. AGENTS.md    — how to work here. The five laws of testing (**LAW 4 was amended 2026-08-28**),
                    the decision framework, and §3b THE TESTING ARCHITECTURE, which is the working
                    method. It is NOT TDD.
  2. PLAN.md      — opens with a BUILD STATUS dashboard showing exactly which phases and which
                    individual criteria are closed. Then §C.6 (Phase 6) and §D.8 (its gate).
                    **Read §B.9 before quoting any gas number** and **§B.10 before touching
                    anything Harberger** — both carry corrections, and the corrections are the
                    interesting part.
  3. PROGRESS.md  — the narrative, newest first. The status board at the top mirrors PLAN's.
  4. PITFALLS.md  — the standing hazard ledger, 72 rows in §5. **READ §5 BEFORE YOU WRITE CODE.**
                    5.66–5.72 are from the Phase 5 session; 5.66, 5.67 and 5.70 are about mistakes
                    that WILL recur.
  5. BUSINESS.md  — what QUEUE is and what may honestly be claimed about it. §8.1 is re-measured.

Verify the ground before building on it (about 3 seconds):

    export PATH="$HOME/.foundry/bin:$PATH"
    forge test

Expect 135 passed / 0 failed. If not, STOP and report it rather than working around it.

=======================================================================
YOUR NEXT ACTION — PHASE 6: ADVERSARIAL AND INVARIANT CAMPAIGN (PLAN §C.6, gate §D.8)
=======================================================================
Build, in this order:

  1. `test/queue/handlers/QueueHandler.sol` — a bounded actor that deposits, withdraws, swaps in
     both directions, transfers seats, sets self-prices, funds and drains rent meters, pokes
     settleRent and triggers buyouts, with `bound()`ed inputs and a ghost-variable ledger.
  2. `test/queue/Invariant.t.sol` — **`targetContract(address(handler))` MUST BE CALLED.**
     `targetSelector` alone leaves the fuzz target set as EVERY contract deployed in `setUp`, which
     makes the campaign vacuous. §D.8 V1 says to grep for it. This is how an invariant suite
     "passes on luck", and it has happened in this repo before.
  3. `test/queue/Adversarial.t.sol` — the named attacks in §C.6, each with an ASSERTED outcome.

THE INVARIANTS ARE I1–I8 IN §C.6. Note that I6 as written names `seatIndex`/`indexSeat`, which do
not exist — Phase 4 replaced them with the packed `order` word and a scanning `rankOfId`. The live
form of I6 is: **`order` is a permutation of `0..n-1`, and `rankOfId(idAtRank(r)) == r` for every
rank.** The fixture already has `_checkOrder`, `_checkInvariantC` and `_checkInvariantR` — reuse
them rather than writing a third copy of each rule.

§D.8 V3 REQUIRES **>=5 deliberate mutations each caught BY THE CAMPAIGN, with the failing invariant
named for each**. That is a different claim from "mutate.py goes red" — the campaign has to be the
thing that catches it. Suggested targets are listed under §D.8.

Decide and record `fail_on_revert`. The handler WILL hit legitimate reverts (authorisation,
over-withdrawal, buying your own seat), so `false` is the honest default — but §D.8 V5 requires you
to say which you chose and why.

=======================================================================
FIVE THINGS EARLIER PHASES BUILT THAT LATER PHASES DEPEND ON — do not undo any of them
=======================================================================
  - **THE ORDER IS ONE `uint256`, ONE SEAT ID PER BYTE.** `MAX_SEATS == 32` and the 32 bytes of a
    word are THE SAME FACT (`test_4_41` asserts the coupling). A demotion rewrites the whole order
    in one SSTORE; the allocator reads it in one SLOAD. There is deliberately NO `rankOfId` mapping
    — a second copy of the order is a writer/reader pair that can disagree, and on this project
    that has been wrong four times. `rankOfId` SCANS the word.
  - **EVERYTHING KEYED TO A SEAT IS KEYED BY ID AND NEVER MOVES.** Capital, holder, lease. Only the
    ORDER moves. The cursors are RANKS. Confusing the two leaves a cursor LEADING a funded seat,
    which is silent theft of rank (PITFALLS 5.61).
  - **THE EVACUATION PATH IS UNBLOCKABLE ON PURPOSE**, and the buyout leans on it harder than the
    transfer did. That is also why the sale price is CREDITED to the seller as a `pendingWithdraw`
    claim rather than transferred on — a seller that is a contract could otherwise refuse payment
    and thereby veto their own buyout.
  - **RENT NEVER TOUCHES THE POSITION, `float0`, OR THE ALLOCATOR.** It moves inside its own pot,
    escrow to escrow. INVARIANT F is untouched by any settlement. Keep it that way.
  - **A SEAT IS ONE STORAGE SLOT: `uint128 a0; uint128 a1;`** (Phase 5b). Every narrowing in the
    contract goes through `_u128`, which REVERTS. The bound cannot bind on anything Uniswap can
    represent — v4 settles in `int128` deltas — but it is checked anyway, because a silent wrap
    would mint balance out of nothing. Two tests poke that slot directly (`Allocator.t.sol`
    `_zeroSeatToken1`, `Packing.t.sol` `_maxOutSeatToken0`); both READ THE WRITE BACK through the
    contract's own view so a future repacking fails loudly instead of poking an unrelated slot.

=======================================================================
TWO OPTIMISATIONS ALREADY MEASURED AND REJECTED — do not re-propose without a better number
=======================================================================
  - **Copying the packed seat through memory** (`Seat memory sm = q[idx]`) to force one SLOAD and
    one SSTORE: **WORSE**, 8,477 vs 8,070 gas per seat. The memory round-trip costs more than the
    compiler's masking.
  - **Hoisting `q.length` into an immutable**, since the roster is fixed at construction: **85 gas
    per swap, 0.07%** — and it BROKE `test_3_9`, the control that mints a seat at runtime to prove
    Phase 3's fixed roster is load-bearing. It had created a second copy of the roster size, so the
    control's new seat became invisible to the allocator. A 0.07% win reintroducing the
    writer/reader class that has been wrong four times here. (PITFALLS 5.70)

**The O(1) prefix-sum redesign (§B.11) is DECIDED: NOT SHIPPED.** §C.5 gated it behind "only if
5a/5b leave a real problem" and they did not. Its objection is also unanswered — the remainder line
has no lazy analogue, because a prefix-sum accumulator does not know which seat is "the last one
filled" at the moment the scalar is updated. Do not reopen it without new evidence.

=======================================================================
HOW TO WORK HERE — THIS IS NOT TDD
=======================================================================
The method is BUILD FAITHFULLY -> ATTACK IT -> FIX WHAT THE ATTACK FINDS, and the third step is the
one that matters.

**MUTATION TESTING HAS FOUND A REAL DEFECT EVERY SINGLE TIME IT HAS BEEN RUN ON THIS PROJECT —
EIGHT FOR EIGHT.** In the Phase 5 session it found that `Allocation.allocate` was returning a
`nextCursor` computed by its own copy of INVARIANT C's rule, that every caller discarded it, and
that no production path called the function at all — an untested second copy of the one rule whose
failure mode is silent theft of rank, sitting in a production library. The honest answer was to
DELETE the line, not to test it.

    python3 script/mutate.py            # all 61
    python3 script/mutate.py M17 M18    # a subset

ADD A MUTATION FOR EVERY LOAD-BEARING LINE YOU WRITE. A mutation that SURVIVES is a finding with
exactly three honest responses:
  (a) write the missing test,
  (b) DELETE the line if nothing depends on it — this has now happened twice (PITFALLS 5.49, and
      `Allocation.allocate`'s cursor in Phase 5),
  (c) write down why it cannot be tested.
Widening a tolerance until it "passes" is none of these.

THE FIVE LAWS OF TESTING — all five were paid for:
1. NEVER test at a 1:1 price. Use 1:4 or worse, with unequal decimals. BUT NOTE: v4 works entirely
   in RAW units, so fixture amounts must be in the pool's RAW ratio regardless of decimals.
2. Every claim needs a negative control that goes RED, and you MUST assert the revert REASON.
3. Measure conservation on PoolManager's own balances, NET OF protocolFeesAccrued. Conservation of
   the LEDGER and redeemability of the POSITION are two different claims needing two assertions.
4. Measure gas with `vm.cool()` **AND BUILD THE STATE IN `setUp()`** — see the LAW 4 section above.
5. A first-run pass is a reason for SUSPICION, not satisfaction.

ELEVEN MORE RULES THIS PROJECT PAID FOR, AND THEY KEEP BITING:
6.  MUTATE EVERY COPY OF A RULE SEPARATELY — per direction, per branch, PER ENTRY POINT. Five
    instances (5.37, 5.50, 5.52 x2, 5.62). **Every new external function gets its authorisation
    mutated on the day it is written, not at the gate.**
7.  A BOUND IN THE RIGHT DIRECTION IS NOT A CORRECTNESS ASSERTION. Assert the identity, not the
    magnitude (5.53).
8.  BEFORE BELIEVING A PATH IS COVERED, CHECK THAT IT WAS ENTERED (5.54).
9.  ASSERT ON THE CONTRACT'S NUMBERS, NEVER ON THE FIXTURE'S OWN MEASUREMENTS (5.34).
10. BEFORE BELIEVING ANY MEASUREMENT, ASK WHAT THE FIXTURE CANNOT REPRESENT (5.27, 5.46).
11. NEVER HARDCODE A STORAGE LAYOUT IN A TEST — and where you must, READ THE WRITE BACK through the
    contract's own view so a layout change fails loudly (Phase 5b).
12. WRITE DOWN WHAT YOU PROVED, NOT WHAT THE GUARD IS FOR (5.55).
13. ANY GUARD THAT DECIDES WHETHER TO WRITE STATE MUST BE EVALUATED BEFORE ANYTHING THAT CAN CHANGE
    WHAT IT READS (5.60).
14. AN AGGREGATE IS A SECOND WRITER OF THE FACT ITS MEMBERS HOLD (5.63).
15. A FIXTURE THAT ONLY EVER EXERCISES INDEX 0 AT POSITION 0 CANNOT SEE AN INDEXING BUG (5.61).
16. **HOLD ONE VARIABLE AT A TIME IN ANY MEASUREMENT.** The first Phase 5 sweep table varied swap
    SIZE along with roster DEPTH, and read ~20,000 gas of the pool's own price-impact work as a
    queue cost.
17. **BEFORE ATTRIBUTING A DIFFERENCE TO THE VARIABLE YOU VARIED, RUN IT IN BOTH ORDERS.** Two
    plausible explanations of the right magnitude were both wrong; the order swap settled it in one
    run (5.67).

BRUTAL HONESTY. You are not here to validate the owner or yourself. A false "PASS" is worse than an
honest "FAIL". If a direction is weak, say so plainly. Never describe a plan as a result. (The first
draft of `test_5_2`'s comment in this session carried invented numbers before they were measured,
and the first draft of `test_5_7` was NAMED as though it had proven parity with a plain pool when it
had measured +36%. Both were caught by re-reading against the output. Do that.)

DO NOT just label a flaw or add a comment when you find one. The owner's standing instruction is
that problems get PROPERLY FIXED in a robust, sustainable way — even if that means deleting docs or
tests. The end product must have no hidden caveats. In Phase 3 this meant overriding PLAN §B.8's
transfer design; in Phase 4 it meant overriding §B.10's rent payment source; in Phase 5 it meant
deleting three gas tests outright rather than leaving optimistic numbers standing beside honest
ones, and correcting §B.9 and BUSINESS.md §8.1 in place.

You may decide implementation details and course corrections yourself, with the expert panel in
AGENTS.md. Stop and ask the owner only when a choice changes the mechanism's ECONOMICS or SECURITY,
or when it would materially hurt the end product.

=======================================================================
HARD CONSTRAINTS — DO NOT VIOLATE
=======================================================================
- No off-chain components. No server, relay, keeper, watch-tower or scanner. The product is a
  contract. (`settleRent` is a permissionless poke, not a keeper: it pays the caller nothing and
  moves money only where the lease already says it goes.)
- No mainnet deployment. Unichain Sepolia only.
- Do not try to detect toxic flow. Proven impossible for a v4 hook.
- Do not attempt a curve that reduces LVR. Proven impossible.
- **NO PER-BLOCK REFERENCE, EVER.** PLAN §B.12 counts "waiting one block boundary" as a PROVEN
  evasion — 200 ms on Unichain — and QUEUE passes that table precisely because it has none.
- No admin function, upgrade path or privileged role without asking. THE SHIPPING CONTRACT HAS NO
  PRIVILEGED ROLE AT ALL. Its permissionless state-changing entry points are the seat holder's own
  (fund / withdraw / transfer / claim / setSelfPrice / fundRent / withdrawRent), plus `buySeat`,
  `settleRent` and `sweepFloatIntoPosition`, none of which pay their caller anything.
- Never let untrusted code choose how much memory you allocate. Use bounded assembly copies.
- Harberger is NOT a margin engine. No collateral, no oracle, no mark, no liquidation crank. The
  rent meter is a PREPAYMENT and foreclosure is a DEMOTION — `test_4_8` reads the shipping source
  and greps it to keep that true.
- Do not call it an auction. It is a self-assessed, always-for-sale lease with continuous rent, no
  bidders required and no per-block winner.

=======================================================================
KNOWN WEAK POINTS — BE READY, DO NOT DISCOVER THEM ON CAMERA
=======================================================================
- HARBERGER CANNOT EXPRESS A NEGATIVE SEAT VALUE (PITFALLS 5.10). Under toxic flow everyone declares
  near zero, no rent flows, and the front is free to take. Unsolved, and not solvable in this design.
- RENT IS `currency0`, WEIGHTED BY `currency0` (5.19 as amended). A tail holding only `currency1` is
  paid nothing and the rent waits in `unallocatedRent0`. `test_4_43` asserts this rather than hiding
  it.
- ENFORCEMENT NEEDS SOMEBODY TO POKE `settleRent` (5.64). Nothing ships that does. The incentive is
  on-chain and real, but a seat nobody wants and nobody pokes accrues a debt nothing collects.
- TAU IS A LOAD-BEARING PARAMETER. Do not defend a value. `test_4_15` runs the mechanism at
  1% / 5% / 10% / 50% and asserts exact linearity; the shipped default is 10%/yr because it is the
  conventional Harberger figure. **Do NOT claim the sign of the seat price reveals toxicity** — 5.20
  says that is overclaimed and no simulation supports it.
- FULL-RANGE DEPTH is the sharpest unanswered attack (5.17). One full-range position offers roughly
  1/200th the depth per dollar of a ±1% concentrated position. OWNER DECISION: answer it, do not fix
  it, until the float sweep is proven in the wild.
- THE SWEEP IS BOUNDED BY THE SMALLER LEG (5.43), and a SEAT TRANSFER IS A SECOND TRIGGER FOR THE
  SAME DRAIN (5.56). Do not claim seat trading is depth-neutral.
- DO NOT CLAIM "the queue's face value is redeemable". The defensible claim, measured, is that each
  seat redeems its entitlement to within a bound that grows LINEARLY at ~0.15 wei per swap.
- THE REENTRANCY GUARD PROTECTS A MEASUREMENT, NOT A PROVEN THEFT (5.55).
- THE FOUNDING ROSTER IS STILL CHOSEN BY WHOEVER DEPLOYS. Every founding seat starts UNPRICED, and
  an unpriced seat is free for anyone to take.
- **QUEUE COSTS A TRADER 36% MORE PER SWAP THAN A BARE v4 POOL** (5.71). Measured. Say the number;
  the defensible claim is that it is a CONSTANT, not that it is small.
- **`addToSeat` IS QUADRATIC IN THE ROSTER** at 2,610,805 gas worst case (5.72). Fine at 32 seats,
  and the reason 32 is the bound.

=======================================================================
COMMANDS — ALL VERIFIED BY EXECUTION 2026-08-28
=======================================================================
    export PATH="$HOME/.foundry/bin:$PATH"

    forge build
    forge test                                                   # 135 passed
    forge test --match-path "test/queue/*"                        # 126 passed
    forge test --match-path "test/queue/Gas.t.sol" -vv            # 7 passed, Phase 5's gate + the
                                                                  #   printed gas table
    forge test --match-path "test/queue/Packing.t.sol" -vv        # 5 passed, the 5b differential
    forge test --match-path "test/queue/Harberger.t.sol" -vv      # 47 passed, Phase 4's gate
    forge test --match-path "test/queue/Rank.t.sol" -vv           # 19 passed, Phase 3's gate
    forge test --match-path "test/spike/QueueAllocator.t.sol"     # 9 passed, the reference
    forge test --match-test <name> -vvv
    forge fmt src/ test/queue/
    forge lint src/                                               # must stay CLEAN, zero notes
    python3 script/mutate.py                                      # 61 mutations, must be 0 survivors

NOTE ON DEPLOYING THE HOOK IN TESTS: the constructor takes NINE arguments —
    (poolManager, c0, c1, FEE, SPACING, roster, rentBps, rentPeriod, firmWindow)
**Never write that list out by hand.** The fixture has ONE place it is written, `_ctorArgs(roster)`,
plus two overloads: `_ctorArgs(roster, fee)` for a hook on a different fee tier, and
`_ctorArgs(roster, bps, period, window)` for the τ sweep. The fixture also has `_roster(a)` through
`_roster(a, b, c, d)` and `_syntheticRoster(n)`.

`BaseHook` validates the deployment address in ITS constructor, which runs FIRST — so a plain
`new QueueHarness(...)` dies on the hook-flags check and never reaches your own assertion. Use the
etch-and-call helpers `_expectDeployRevert` (Rank.t.sol) or `_expectCtorRevert` (Harberger.t.sol) to
assert constructor reverts.

FIXTURE HELPERS YOU WILL NEED:
    hook.ranking() / hook.idAtRank(r) / hook.rankOfId(id) / hook.orderWord()
    _refDemote(seatId)        — the witness's copy of a demotion; call it after every foreclosure
    _check(tag)               — ledger conservation AND every seat against the independent uint256
                                witness, seat by seat, plus INVARIANT C and the order word
    _checkOrder(tag)          — the packed order word against the witness's plain array
    _checkInvariantC(tag)     — no cursor LEADS a funded seat
    _checkInvariantF(tag,tol) — the ledger against the position plus the float
    _checkInvariantR(tag)     — every wei of currency0 the hook holds is spoken for, AND the escrow
                                aggregate equals the sum of the seats (see PITFALLS 5.63)

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
