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
Phases 0, 1, 2, 3 and 4 are COMPLETE and committed. **THE PROJECT IS AT ITS SUBMITTABLE STATE, and
Phase 4 is what makes the pitch true rather than aspirational.**

    forge test                 ->  125 passed, 0 failed        (9 suites)
    forge lint src/            ->  clean, zero notes
    python3 script/mutate.py   ->  53 mutations, ZERO survivors

WHAT EXISTS:
  src/queue/QueueHook.sol             the hook: allocator, cursors, fund/withdraw, float, sweep,
                                      seat evacuation, pending claims, the rank permutation, and
                                      the whole Harberger lease
  src/queue/QueueSeats.sol            the ERC-6909 rank token: one id per seat, supply one
  src/queue/libraries/Allocation.sol  the allocation arithmetic, pure and fuzzable
  src/queue/libraries/Rent.sol        the rent arithmetic; its DISTRIBUTION reuses Allocation, so
                                      there is one remainder line in the codebase, not two
  test/queue/                         8 suites + a shared fixture + a TEST-ONLY harness
  test/spike/QueueAllocator.t.sol     the archived reference implementation (do not edit)
  script/mutate.py                    the mutation harness. NOT part of the build. RUN IT.

WHAT IS PROVEN (all executed, all against real v4 contracts deployed locally):
  - Front-first allocation is exact to the wei in both tokens, at 1:4, 1:1000, 1000:1, and at
    18/6 AND 6/18 decimals.
  - The protocol fee is handled correctly at a MAXIMUM fee, with lpFee == 0, and against a
    FOREIGN POOL sharing a currency.
  - Per-seat withdrawal works from a shared two-slot float, in all six orderings, with no
    poolManager.swap anywhere in the contract.
  - Rank is an ERC-6909 seat with supply exactly one, STRUCTURALLY: ownership is a single address
    slot and the token surface is a view over it.
  - The roster is fixed at deployment and there is NO runtime path that creates a seat.
  - Rent accrues exactly linearly in elapsed SECONDS, splits to the seats behind to the wei,
    is HELD rather than lost when nobody is eligible, and cannot be captured by a flash loan.
  - Under-pricing a seat gets it bought out; over-pricing pays for it. Both numerically.
  - Foreclosure DEMOTES to the tail — the holder keeps the seat and every wei of its capital.
  - The always-for-sale guarantee survives a holder who front-runs their own buyout.
  - The redemption residual is ~0.15 wei per swap per token, LINEAR and converging (asserted).

=======================================================================
START BY READING, IN THIS ORDER, AND DO NOT SKIP ANY
=======================================================================
  1. AGENTS.md    — how to work here. The five laws of testing, the decision framework, and
                    §3b THE TESTING ARCHITECTURE, which is the working method. It is NOT TDD.
  2. PLAN.md      — opens with a BUILD STATUS dashboard showing exactly which phases and which
                    individual criteria are closed. Then §C.5 (Phase 5) and §D.7 (its gate).
                    **Read §B.10 before touching anything Harberger** — two of its rows are marked
                    CORRECTED and the correction is the interesting part.
  3. PROGRESS.md  — the narrative, newest first. The status board at the top mirrors PLAN's.
  4. PITFALLS.md  — the standing hazard ledger, 65 rows in §5. **READ §5 BEFORE YOU WRITE CODE.**
                    Rows 5.57–5.65 are from the Phase 4 session; 5.60, 5.61 and 5.62 are about
                    mistakes that WILL recur.
  5. BUSINESS.md  — what QUEUE is and what may honestly be claimed about it.

Verify the ground before building on it (about 3 seconds):

    export PATH="$HOME/.foundry/bin:$PATH"
    forge test

Expect 125 passed / 0 failed. If not, STOP and report it rather than working around it.

=======================================================================
YOUR NEXT ACTION — PHASE 5: GAS AND SCALE (PLAN §C.5, gate §D.7)
=======================================================================
Do it in this order and DO NOT SKIP TO 5c.

  5a — MEASURE HONESTLY. Reproduce §B.9's gas table against OUR hook, with `vm.cool()`, under
       `--gas-report`. Derive the real slope and intercept. **Do not reuse the spike's numbers** —
       the spike had no cursors, no owners, no seat tokens and no lease, so our gas is different
       and probably worse. Phase 4 added one SLOAD and a shift to the allocator's hot loop, and a
       lease read to the transfer path (measured: a pure-rank transfer went 17,939 -> 24,969).
  5b — CHEAP WINS, EACH INDIVIDUALLY MEASURED. Pack a0/a1 into one slot as uint128 with a CHECKED
       cast (overflow must revert, never wrap). Hoist repeated SLOADs. Each change gets a
       before/after number AND a differential test against the uint256 implementation over a
       randomised swap sequence proving wei-identical results.
  5c — THE O(1) PREFIX-SUM REDESIGN, ONLY IF 5a/5b LEAVE A REAL PROBLEM. Per §B.11, and only under
       its exit criterion: wei-exact agreement with the O(N) reference over >=1000 randomised swaps
       including direction reversals, or an explicitly bounded, proven-non-farmable divergence.
       **Otherwise it is not shipped, and PROGRESS.md says so.** §B.11 explains why it is suspect:
       the thing that makes the O(N) allocator exact is the remainder line applied to the LAST SEAT
       FILLED, and a lazy accumulator has no notion of that at the time the scalar is updated.

ONE NUMBER PHASE 5 SHOULD LOOK AT FIRST: the worst-case `addToSeat` is **2,337,576 gas** at a full
32-seat roster with every seat ahead priced and funded (`test_4_44`). That is the price of closing
the flash-loan rent grab, it fits a 30M block thirteen times over, and the configuration costs an
attacker rent paid to the very seat they are trying to price out. If you make it cheaper, the
differential test is not optional.

FOUR THINGS PHASE 4 BUILT THAT LATER PHASES DEPEND ON — do not undo any of them:
  - **THE ORDER IS ONE `uint256`, ONE SEAT ID PER BYTE.** `MAX_SEATS == 32` and the 32 bytes of a
    word are THE SAME FACT (`test_4_41` asserts the coupling). A demotion rewrites the whole order
    in one SSTORE; the allocator reads it in one SLOAD. There is deliberately NO `rankOfId` mapping
    — a second copy of the order is a writer/reader pair that can disagree, and on this project
    that has been wrong four times. `rankOfId` SCANS the word.
  - **EVERYTHING KEYED TO A SEAT IS KEYED BY ID AND NEVER MOVES.** Capital, holder, lease. Only the
    ORDER moves. The cursors are RANKS. Confusing the two leaves a cursor LEADING a funded seat,
    which is silent theft of rank (PITFALLS 5.61).
  - **THE EVACUATION PATH IS UNBLOCKABLE ON PURPOSE**, and the buyout leans on it harder than the
    transfer did. A buyout must be able to take the seat at the incumbent's own price at any time.
    That is also why the sale price is CREDITED to the seller as a `pendingWithdraw` claim rather
    than transferred on — a seller that is a contract could otherwise refuse payment and thereby
    veto their own buyout.
  - **RENT NEVER TOUCHES THE POSITION, `float0`, OR THE ALLOCATOR.** It moves inside its own pot,
    escrow to escrow. That is what lets Phase 4 add zero risk to the proven Phase 1–3 arithmetic,
    and INVARIANT F is untouched by any settlement. Keep it that way.

=======================================================================
HOW TO WORK HERE — THIS IS NOT TDD
=======================================================================
The method is BUILD FAITHFULLY -> ATTACK IT -> FIX WHAT THE ATTACK FINDS, and the third step is the
one that matters.

**MUTATION TESTING HAS FOUND A REAL DEFECT EVERY SINGLE TIME IT HAS BEEN RUN ON THIS PROJECT —
SEVEN FOR SEVEN.** In the Phase 4 session the suite was 99/99 green and every review lens in
AGENTS.md §5 had been walked when `script/mutate.py` ran for the first time. **It left 21 of 53
mutations alive**, including two unguarded external entry points — anyone could drain anyone's rent
meter, and anyone could reprice anyone's seat, which is not griefing but theft (set a rival's price
to zero, buy their seat). Neither was found by reading the code.

    python3 script/mutate.py            # all 53
    python3 script/mutate.py M17 M18    # a subset

ADD A MUTATION FOR EVERY LOAD-BEARING LINE YOU WRITE. A mutation that SURVIVES is a finding with
exactly three honest responses:
  (a) write the missing test,
  (b) DELETE the line if nothing depends on it — this has now happened twice (PITFALLS 5.49, and
      `_demoteToTail`'s early return in Phase 4),
  (c) write down why it cannot be tested.
Widening a tolerance until it "passes" is none of these.

THE FIVE LAWS OF TESTING — all five were paid for:
1. NEVER test at a 1:1 price. Use 1:4 or worse, with unequal decimals. BUT NOTE: v4 works entirely
   in RAW units, so fixture amounts must be in the pool's RAW ratio regardless of decimals.
2. Every claim needs a negative control that goes RED, and you MUST assert the revert REASON.
3. Measure conservation on PoolManager's own balances, NET OF protocolFeesAccrued. Conservation of
   the LEDGER and redeemability of the POSITION are two different claims needing two assertions.
4. Measure gas with `vm.cool()`.
5. A first-run pass is a reason for SUSPICION, not satisfaction.

NINE MORE RULES THIS PROJECT PAID FOR, AND THEY KEEP BITING:
6.  MUTATE EVERY COPY OF A RULE SEPARATELY — per direction, per branch, PER ENTRY POINT. Five
    instances now (5.37, 5.50, 5.52 x2, 5.62). **Every new external function gets its authorisation
    mutated on the day it is written, not at the gate.**
7.  A BOUND IN THE RIGHT DIRECTION IS NOT A CORRECTNESS ASSERTION. Assert the identity, not the
    magnitude (5.53). Phase 4's remainder rule is written as an identity for exactly this reason.
8.  BEFORE BELIEVING A PATH IS COVERED, CHECK THAT IT WAS ENTERED (5.54). The Phase 4 suite is full
    of `assertTrue(x != 0, "...: this test proves nothing")` and three of them fired on first run.
9.  ASSERT ON THE CONTRACT'S NUMBERS, NEVER ON THE FIXTURE'S OWN MEASUREMENTS (5.34).
10. BEFORE BELIEVING ANY MEASUREMENT, ASK WHAT THE FIXTURE CANNOT REPRESENT (5.27, 5.46).
11. NEVER HARDCODE A STORAGE LAYOUT IN A TEST. Read the slot from the contract.
12. WRITE DOWN WHAT YOU PROVED, NOT WHAT THE GUARD IS FOR (5.55).
13. **ANY GUARD THAT DECIDES WHETHER TO WRITE STATE MUST BE EVALUATED BEFORE ANYTHING THAT CAN
    CHANGE WHAT IT READS.** A Phase 4 gas optimisation re-opened the hole it sat next to because its
    predicate was read after a settlement that can foreclose the seat and wipe the evidence (5.60).
14. **AN AGGREGATE IS A SECOND WRITER OF THE FACT ITS MEMBERS HOLD.** Assert the aggregate against
    the SUM it claims to be, or a control that credits without charging passes everything (5.63).
15. **A FIXTURE THAT ONLY EVER EXERCISES INDEX 0 AT POSITION 0 CANNOT SEE AN INDEXING BUG**, because
    `0 << anything` is `0`. Four Phase 4 defects hid behind one convenient fixture (5.61).

BRUTAL HONESTY. You are not here to validate the owner or yourself. A false "PASS" is worse than an
honest "FAIL". If a direction is weak, say so plainly. Never describe a plan as a result.

DO NOT just label a flaw or add a comment when you find one. The owner's standing instruction is
that problems get PROPERLY FIXED in a robust, sustainable way — even if that means deleting docs or
tests. The end product must have no hidden caveats. In Phase 3 this meant overriding PLAN §B.8's
transfer design; in Phase 4 it meant overriding §B.10's rent payment source and adding a firm-quote
rule the plan never mentioned. Both plans were corrected in place and the rejected alternatives
written down.

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
  evasion — 200 ms on Unichain — and QUEUE passes that table precisely because it has none. A
  per-block cooldown would have closed the Phase 4 flash-loan grab and was rejected for this reason.
- No admin function, upgrade path or privileged role without asking. THE SHIPPING CONTRACT HAS NO
  PRIVILEGED ROLE AT ALL. Its permissionless state-changing entry points are the seat holder's own
  (fund / withdraw / transfer / claim / setSelfPrice / fundRent / withdrawRent), plus `buySeat`,
  `settleRent` and `sweepFloatIntoPosition`, none of which pay their caller anything. Keep it that way.
- Never let untrusted code choose how much memory you allocate. Use bounded assembly copies.
- Harberger is NOT a margin engine. No collateral, no oracle, no mark, no liquidation crank. The
  rent meter is a PREPAYMENT and foreclosure is a DEMOTION — `test_4_8` reads the shipping source
  and greps it to keep that true.
- Do not call it an auction. It is a self-assessed, always-for-sale lease with continuous rent, no
  bidders required and no per-block winner. The am-AMM family auctions pool-management rights to one
  winner per block; a judge will probe the difference.

=======================================================================
KNOWN WEAK POINTS — BE READY, DO NOT DISCOVER THEM ON CAMERA
=======================================================================
- HARBERGER CANNOT EXPRESS A NEGATIVE SEAT VALUE (PITFALLS 5.10). Under toxic flow everyone declares
  near zero, no rent flows, and the front is free to take. That is the mechanism behaving correctly
  AND the point at which the price signal is censored. Unsolved, and not solvable in this design.
- RENT IS `currency0`, WEIGHTED BY `currency0` (5.19 as amended). Weighting a two-token basket needs
  a price and §E.11 forbids one, so a tail holding only `currency1` is paid nothing and the rent
  waits in `unallocatedRent0`. `test_4_43` asserts this rather than hiding it.
- ENFORCEMENT NEEDS SOMEBODY TO POKE `settleRent` (5.64). Nothing ships that does. The incentive is
  on-chain and real — the seats behind are paid by it, and a buyer must poke to clear a delinquent
  incumbent — but a seat nobody wants and nobody pokes accrues a debt nothing collects.
- TAU IS A LOAD-BEARING PARAMETER, and this project's history says that is where a pitch dies. Do
  not defend a value. `test_4_15` runs the mechanism at 1% / 5% / 10% / 50% and asserts exact
  linearity; the shipped default is 10%/yr because it is the conventional Harberger figure, i.e. a
  citation rather than a number somebody picked. **Do NOT claim the sign of the seat price reveals
  toxicity** — 5.20 says that is overclaimed and no simulation supports it.
- FULL-RANGE DEPTH is the sharpest unanswered attack (5.17). One full-range position offers roughly
  1/200th the depth per dollar of a ±1% concentrated position. OWNER DECISION: answer it, do not fix
  it, until the float sweep is proven in the wild.
- THE SWEEP IS BOUNDED BY THE SMALLER LEG (5.43), and a SEAT TRANSFER IS A SECOND TRIGGER FOR THE
  SAME DRAIN (5.56). Do not claim seat trading is depth-neutral.
- DO NOT CLAIM "the queue's face value is redeemable". The defensible claim, measured, is that each
  seat redeems its entitlement to within a bound that grows LINEARLY at ~0.15 wei per swap and never
  compounds.
- THE REENTRANCY GUARD PROTECTS A MEASUREMENT, NOT A PROVEN THEFT (5.55). The window is real and
  PoolManager's lock does not close it. No value-extracting sequence was found. Say that, not more.
- THE FOUNDING ROSTER IS STILL CHOSEN BY WHOEVER DEPLOYS. What Phase 4 changed is that the choice is
  worth a head start of one transaction: every founding seat starts UNPRICED, and an unpriced seat is
  free for anyone to take.

=======================================================================
COMMANDS — ALL VERIFIED BY EXECUTION 2026-08-27
=======================================================================
    export PATH="$HOME/.foundry/bin:$PATH"

    forge build
    forge test                                                  # 125 passed
    forge test --match-path "test/queue/*"                       # 116 passed
    forge test --match-path "test/queue/Harberger.t.sol" -vv     # 48 passed, Phase 4's gate
    forge test --match-path "test/queue/Rank.t.sol" -vv          # 19 passed, Phase 3's gate
    forge test --match-path "test/spike/QueueAllocator.t.sol"    # 9 passed, the reference
    forge test --match-test <name> -vvv
    forge fmt src/ test/queue/
    forge lint src/                                              # must stay CLEAN, zero notes
    python3 script/mutate.py                                     # 53 mutations, must be 0 survivors

NOTE ON DEPLOYING THE HOOK IN TESTS: the constructor now takes NINE arguments —
    (poolManager, c0, c1, FEE, SPACING, roster, rentBps, rentPeriod, firmWindow)
**Never write that list out by hand.** The fixture has ONE place it is written, `_ctorArgs(roster)`,
plus two overloads: `_ctorArgs(roster, fee)` for a hook on a different fee tier, and
`_ctorArgs(roster, bps, period, window)` for the τ sweep. The fixture also has `_roster(a)` through
`_roster(a, b, c, d)` and `_syntheticRoster(n)`.

`BaseHook` validates the deployment address in ITS constructor, which runs FIRST — so a plain
`new QueueHarness(...)` dies on the hook-flags check and never reaches your own assertion. Use the
etch-and-call helpers `_expectDeployRevert` (Rank.t.sol) or `_expectCtorRevert` (Harberger.t.sol) to
assert constructor reverts.

FIXTURE HELPERS ADDED IN PHASE 4, which you will need the moment a test involves a demotion:
    hook.ranking() / hook.idAtRank(r) / hook.rankOfId(id) / hook.orderWord()
    _refDemote(seatId)        — the witness's copy of a demotion; call it after every foreclosure
    _checkOrder(tag)          — the packed order word against the witness's plain array
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
