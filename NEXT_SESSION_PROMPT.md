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
allocates each swap FRONT-FIRST through an ordered list of up to 32 seats. Each seat is held under a
self-assessed, always-for-sale HARBERGER lease: you post your own price, you pay continuous rent on
it to the seats behind you, and anyone may take the seat from you at your own number, at any time.

**READ `README.md` FIRST AND DO NOT RE-DERIVE THE PITCH.** It is the canonical framing. Four things
it says that you must not lose:

  1. **The decision being challenged is pro-rata fill.** Sharpest form: *Uniswap did not eliminate
     the value of queue position — it made it unpriceable INSIDE the pool, which means it gets
     captured OUTSIDE the pool, at the sequencer.*
  2. **Why PAID seats rather than an open, arrival-ordered queue.** Free rank is griefable rank (if
     arrival grants rank, the head costs one wei — dust it and you own the book). Unbounded rank is
     worthless rank (a non-scarce asset has no price, so no rent flows to the tail). **Scarcity IS
     the mechanism**, and the Harberger lease is what stops a scarce roster becoming a cartel.
  3. **"So it isn't really a queue" — the answer, added 2026-08-29, is in README and it is stronger
     than what the docs used to concede.** Do NOT say "the roster is closed": it is false. Under an
     always-for-sale lease anyone may enter at any moment at a price the incumbent posted. What is
     scarce is the **slot**, not the **participant**. And the deeper point: *every market prices
     queue position; most price it in TIME, which is burnt on latency and colocation and paid to
     nobody in the market. QUEUE deletes time — on-chain "arrival" is just a gas auction — and keeps
     price, paid to the LPs you are standing in front of.*
  4. **It is an experiment that produces a number nobody has**: the self-assessed price of the head
     seat. Both answers are results — near zero says pro-rata was right all along and now we KNOW;
     high says Uniswap has been giving away for free the asset every other market charges most for.

DO NOT say "every real electronic market is price–time priority" as the headline. QUEUE is NOT
price–time priority and a judge who knows markets will say so in the first thirty seconds.

=======================================================================
WHERE THE PROJECT IS RIGHT NOW
=======================================================================
Phases 0 through 6 are COMPLETE and committed. **Phase 7 is IN PROGRESS.**

    forge test                 ->  172 passed, 0 failed, 1 skipped   (16 suites)
    forge lint src/            ->  clean, zero notes
    python3 script/mutate.py   ->  68 mutations, ZERO survivors

The one skip is `DeployFork.t.sol`, off unless `QUEUE_FORK=true`, because the default suite must not
need a network. It skips LOUDLY via `vm.skip`, never silently.

WHAT EXISTS:
  src/queue/QueueHook.sol             the hook: allocator, cursors, fund/withdraw, float, sweep,
                                      seat evacuation, pending claims, the rank permutation, the
                                      whole Harberger lease, and `pool()` disclosure
  src/queue/QueueSeats.sol            the ERC-6909 rank token: one id per seat, supply one
  src/queue/libraries/Allocation.sol  the allocation arithmetic, pure and fuzzable
  src/queue/libraries/Rent.sol        the rent arithmetic; its DISTRIBUTION reuses Allocation
  script/QueueDeployBase.sol          **the deploy + demo sequence, written ONCE**
  script/DeployQueue.s.sol            the broadcast wrapper (HookMiner + canonical CREATE2 proxy)
  frontend/index.html                 one static file: the comparison, the live book, the grief demo
  test/queue/                         14 suites + shared fixture + a TEST-ONLY harness
  test/queue/Deploy.t.sol             **the deployment path itself**, asserted beat by beat
  test/queue/DeployFork.t.sol         the same tests against a LIVE Unichain Sepolia fork
  test/queue/Hygiene.t.sol            tests about our own INSTRUMENTS
  script/mutate.py                    the mutation harness. NOT part of the build. RUN IT.

=======================================================================
YOUR NEXT ACTION — exactly two things remain
=======================================================================

**1. BROADCAST TO UNICHAIN SEPOLIA.** Everything the broadcast will do is already executed and
   asserted against a fork of that chain, so the remaining risk is operational, not mechanical.
   You need a funded key (faucet: https://faucet.quicknode.com/unichain/sepolia).

       export PATH="$HOME/.foundry/bin:$PATH"
       export PRIVATE_KEY=0x...
       forge script script/DeployQueue.s.sol:DeployQueue \
         --rpc-url https://sepolia.unichain.org --broadcast -vvv

   It prints the full seat table after every beat. **Paste the addresses and that transcript into
   `README.md`** (there is a "Deploying it" section waiting for them), and paste the hook address
   into the frontend's live-read box to confirm it renders. Verify the contracts on the explorer.

**2. THE VIDEO, UNDER 5:00, HUMAN VOICE.** **THE SHOT-BY-SHOT PLAN IS ALREADY WRITTEN — see
   `README.md` "The video — what it must show, and why".** Minute-by-minute table, the business
   point each beat must make, and an explicit list of what NOT to do. Do not re-derive it. The two
   things it exists to prevent:
     - a viewer filing this under "order book bolted onto an AMM" in the first twenty seconds
       (which is why the mechanism must be SHOWN, wordlessly, before 0:30 — **open
       `frontend/index.html` and drag the swap-size slider; that IS the shot**), and
     - the "why not just an open queue?" objection landing before we answer it (which is why
       1:15-2:15 grieves a naive open queue on screen and then shows the lease taking a seat back
       off someone who under-priced it — **the frontend has both as buttons**).
   Limitations are read out at 4:00, not skipped. The am-AMM comparison is the closing line.

**§D.9 in PLAN.md is the gate and every line must be a yes.**

=======================================================================
WHAT PHASE 7 FOUND — READ THIS BEFORE YOU TOUCH ANYTHING
=======================================================================
**THE DEPLOYMENT PATH HAD NEVER EXECUTED.** Six green phases, 163 tests, and not one line of the
real sequence had ever run: every suite reached the pool through the TEST-ONLY `QueueHarness.seed()`
or through `deployCodeTo`, which *places* a hook at an address of your choosing. Fixed structurally —
the sequence lives in `script/QueueDeployBase.sol` and TWO callers execute it, the broadcast script
and a test, with only the identity seam (`_as` / `_stopActing`) differing. **Do not move it back into
the script.** (PITFALLS 5.81.)

Four of our own instruments were wrong, not the code:
  - **5.82 — PLAN §H.3's hook flag mask was stale**, `0x0840` for a contract whose permissions are
    `0x18C0`, while §F.2 of the same document already had the right value. `BaseHook` validates the
    address in ITS constructor, which runs first, so a stale mask reverts at deploy time with no
    diagnosis. **DERIVE A MASK FROM `getHookPermissions()`, NEVER COPY ONE.** `test_7_1` asserts it.
  - **5.83 / 5.84 — two pool-binding tests were LAW 2 violations**, and `test_2_21` was worse: it
    re-initialized the IDENTICAL key, which PoolManager refuses from its own state before the hook is
    called, so it passed **whether or not the `AlreadyBound` guard existed at all**. Proven by
    deleting the guard and watching both stay green. **v4 wraps a hook's own error in
    `CustomRevert.WrappedError(target, selector, reason, details)`** — that is why bare
    `vm.expectRevert()` is tempting on callbacks. Kept honest by M67.
  - **5.85 — the frontend's four hardcoded call selectors were three-quarters wrong.** An `eth_call`
    to a selector that does not exist returns EMPTY DATA, so the page renders zeros and looks like a
    working demo of an empty queue. `test_7_6` reads the page and asserts each against the compiler's
    own; `test_7_8` pins the `pool()` returndata LAYOUT the page decodes by byte offset.
  - **5.86 — 5.79's corollary was violated by the agent who had just read it.** `forge test` was run
    while `mutate.py` held a mutant on disk. **PROSE IS NOT AN INTERLOCK:** the campaign now
    publishes `.forge-snapshots/MUTATION_IN_PROGRESS` and `test_7_7` refuses to run while it exists;
    the campaign's own runs pass through on `QUEUE_MUTATION_RUN=1`.

Two product gaps closed:
  - **5.89 — the pool a deployed hook serves was not readable on chain at all.** Closed with
    `pool() -> (PoolKey, bool isBound, int24 lower, int24 upper)`. `isBound` is RETURNED rather than
    inferred from a zero key because `Currency.wrap(address(0))` is legal native ETH.
  - **5.17 UPGRADED FROM ANALYSIS TO PROVEN on its orthogonality half.** Thin full-range depth is
    "the sharpest attack", and the row always claimed the range was "a reversible design choice".
    That is now executed: `tickLower`/`tickUpper` appear in exactly two places — the sizing helpers
    and `modifyLiquidity` — and NOWHERE in the allocator. `test_1_11` seeds the identical roster over
    a **±10% band** and everything holds to the wei. **Concentrating the position is a v2 parameter,
    not a redesign.** Do NOT over-claim: out-of-range behaviour and rebalancing are unbuilt.

Three wrong predictions, recorded next to the right answers:
  - **"A 400e18 sweep walks several seats."** It touched one. The queue IS the pool's liquidity, so
    reaching rank 2 means removing ranks 0 and 1's whole stock from a FULL-RANGE position, and a
    constant-product curve releases 60% of a leg only for a 6.25x price move. 2,500e18 walks it.
    This is the MEASURED form of "the back is reached only by large trades". (5.87.)
  - **"Settling rent reduces `escrowTotal`."** It does not — rent moves escrow to escrow, so the
    total is CONSERVED. The draft assertion would have passed against a LEAKING implementation.
    Assert the identity, never a direction. (5.88, and 5.53 again.)
  - **"This control proves the new test has no teeth."** The control (M5, index by seat id not rank)
    is a genuine NO-OP where the order is the identity permutation. **Before concluding a test is
    weak, check the control can be detected in that fixture at all.** (5.91.)

=======================================================================
START BY READING, IN THIS ORDER, AND DO NOT SKIP ANY
=======================================================================
  1. README.md     — THE FRAME, the business-language sections, the limitations, the video plan.
  2. AGENTS.md     — how to work here. The five laws (LAW 4 amended), the decision framework,
                     §3b THE TESTING ARCHITECTURE. It is NOT TDD.
  3. PLAN.md       — opens with a BUILD STATUS dashboard. Then §C.7 (Phase 7) and §D.9 (the gate).
                     §B.9 before quoting any gas number, §B.10 before touching Harberger, §A.3 for
                     the thesis, §H for deployment.
  4. PROGRESS.md   — the narrative, newest first.
  5. PITFALLS.md   — the standing hazard ledger, 91 rows in §5. READ §5 BEFORE YOU WRITE CODE.
                     5.81-5.91 are from this session and every one of them will recur.
  6. BUSINESS.md   — §0 the frame; §9 the honest-limitations list.

Verify the ground before building on it:

    export PATH="$HOME/.foundry/bin:$PATH"
    forge test

Expect 172 passed / 0 failed / 1 skipped. If not, STOP and report it rather than working around it.

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
    transfer does. A revert there is an incumbent veto on their own buyout. The sale price is
    CREDITED as a `pendingWithdraw` claim rather than transferred on, for the same reason.
  - **RENT NEVER TOUCHES THE POSITION, `float0`, OR THE ALLOCATOR.** It moves escrow to escrow, and
    `escrowTotal` is therefore CONSERVED by a settlement.
  - **A SEAT IS ONE STORAGE SLOT: `uint128 a0; uint128 a1;`** Every narrowing goes through `_u128`,
    which REVERTS rather than wrapping.
  - **THE POSITION MEASUREMENT IS SIGNED** (`_moved`), and the removal side asserts the sign it can
    predict (`UnexpectedPositionDebit`). Do not "simplify" it back to an unsigned subtraction.

=======================================================================
THREE OPTIMISATIONS ALREADY MEASURED AND REJECTED — do not re-propose without a better number
=======================================================================
  - **Copying the packed seat through memory**: WORSE, 8,477 vs 8,070 gas per seat.
  - **Hoisting `q.length` into an immutable**: 85 gas per swap (0.07%) and it BROKE `test_3_9`.
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

**MUTATION TESTING HAS FOUND A REAL DEFECT EVERY SINGLE TIME IT HAS BEEN RUN — TEN FOR TEN.**

    python3 script/mutate.py                    # all 68, against the full suite
    python3 script/mutate.py M17 M18            # a subset
    python3 script/mutate.py --campaign M62 M63 # against the INVARIANT SUITE ONLY, naming the
                                                #   invariant that caught it (PLAN §D.8 V3)

**NEVER RUN `forge` AGAINST THE REPO WHILE `mutate.py` IS GOING.** It holds a deliberate bug on disk
for the duration of each case. The suite now refuses and tells you so (`test_7_7`) instead of
reporting a failure unrelated to your change — but do not rely on the interlock, just wait.

ADD A MUTATION FOR EVERY LOAD-BEARING LINE YOU WRITE. A mutation that SURVIVES is a finding with
exactly three honest responses: (a) write the missing test, (b) DELETE the line if nothing depends
on it, (c) write down why it cannot be tested. Widening a tolerance is none of these.

THE FIVE LAWS OF TESTING — all five were paid for:
1. NEVER test at a 1:1 price. Use 1:4 or worse, with unequal decimals. v4 works in RAW units, so
   fixture amounts must be in the pool's RAW ratio regardless of decimals. **This applies to the
   DEMO and the deployment too** — `_sqrtPriceX96` folds the decimals in.
2. Every claim needs a negative control that goes RED, and you MUST assert the revert REASON.
   On a hook callback that means unwrapping `CustomRevert.WrappedError` (5.84).
3. Measure conservation on PoolManager's own balances, NET OF protocolFeesAccrued. Conservation of
   the LEDGER and redeemability of the POSITION are two claims needing two assertions.
4. Measure gas with `vm.cool()` AND BUILD THE STATE IN `setUp()`. `vm.cool()` resets the EIP-2929
   access list but NOT the value EIP-2200 meters a WRITE against.
5. A first-run pass is a reason for SUSPICION, not satisfaction.

THE RULES PHASES 6 AND 7 ADDED, ALL OF WHICH WILL RECUR:
6.  **NEVER PREDICT THE SIGN OF A BALANCE CHANGE FROM THE SIGN OF THE REQUEST YOU MADE** (5.74).
7.  **A LEG THAT IS NOT BINDING MUST NOT DECIDE THE OUTCOME** — minima in full width, narrow once.
8.  **A ZERO SPAN IS AN ANSWER, NOT AN ERROR**, and an EMPTY revert is a bare `require` below you.
9.  **UNDER `fail_on_revert = false`, AN ASSERTION INSIDE A HANDLER IS A REVERT AND IS SWALLOWED.**
10. **A COVERAGE FLOOR CANNOT LIVE IN `afterInvariant`** — use a scripted campaign (`test_6_0`).
11. **A TOOL THAT EDITS `src/` MUST RESTORE IT IN A `finally`** (5.79).
12. **BEFORE BELIEVING A MEASUREMENT, SUSPECT THE INSTRUMENT** (5.75, 5.79, and four more this
    session — the instruments have now been wrong more often than the mechanism).
13. **A DEPLOY SCRIPT IS NOT A TESTED PATH** (5.81).
14. **DERIVE A PERMISSION MASK, NEVER COPY ONE** (5.82).
15. **ASSERT THE IDENTITY, NOT A DIRECTION** — "escrowTotal fell" passes against a leak (5.88).
16. **PROSE IS NOT AN INTERLOCK** (5.86).
17. **A CONTROL THAT PASSES MAY BE AN UNDETECTABLE CONTROL, NOT A WEAK TEST** (5.91).

=======================================================================
HARD CONSTRAINTS — DO NOT VIOLATE
=======================================================================
- No off-chain components. No server, relay, keeper, watch-tower or scanner. `frontend/index.html`
  is a READ-ONLY static viewer with no keys and no backend — it is not a component of the mechanism.
- No mainnet deployment. Unichain Sepolia only. `DeployQueue._requireTestnet` enforces an ALLOW-LIST.
- Do not try to detect toxic flow. Proven impossible for a v4 hook.
- Do not attempt a curve that reduces LVR. Proven impossible.
- **NO PER-BLOCK REFERENCE, EVER.** PLAN §B.12 counts "waiting one block boundary" as a PROVEN
  evasion — 200 ms on Unichain — and QUEUE passes that table precisely because it has none.
- No admin function, upgrade path or privileged role without asking. THE SHIPPING CONTRACT HAS NO
  PRIVILEGED ROLE AT ALL. (`pool()` is pure disclosure of already-public data.)
- Never let untrusted code choose how much memory you allocate. Use bounded assembly copies.
- Harberger is NOT a margin engine. No collateral, no oracle, no mark, no liquidation crank.
- Do not call it an auction. It is a self-assessed, always-for-sale lease with continuous rent.

=======================================================================
KNOWN WEAK POINTS — BE READY, DO NOT DISCOVER THEM ON CAMERA
=======================================================================
- HARBERGER CANNOT EXPRESS A NEGATIVE SEAT VALUE (5.10). Under toxic flow everyone declares near
  zero, no rent flows, and the front is free to take. Unsolved, and not solvable in this design.
- RENT IS `currency0`, WEIGHTED BY `currency0` (5.19). A tail holding only `currency1` is paid
  nothing and the rent waits in `unallocatedRent0`. `test_4_43` and `test_7_5` assert this rather
  than hiding it.
- ENFORCEMENT NEEDS SOMEBODY TO POKE `settleRent` (5.64). Nothing ships that does.
- TAU IS A LOAD-BEARING PARAMETER. Do not defend a value. Do NOT claim the sign of the seat price
  reveals toxicity — 5.20 says that is overclaimed.
- **FULL-RANGE DEPTH (5.17) NOW HAS HALF AN ANSWER, NOT A WHOLE ONE.** The queue is PROVEN
  orthogonal to the range (`test_1_11`), so concentrating is a v2 parameter. The economics of a thin
  pool — no aggregator routes retail to it — still stand. Say both halves.
- THE SWEEP IS BOUNDED BY THE SMALLER LEG (5.43), and A SEAT TRANSFER IS A SECOND TRIGGER FOR THE
  SAME DRAIN (5.56). Do not claim seat trading is depth-neutral.
- **THE REDEMPTION RESIDUAL IS NOT A PER-SWAP CONSTANT** (5.80). Under 1 ppb of lifetime inflow,
  surplus exactly 0 — and the LAST holders to withdraw bear it. Do not say face value is redeemable.
- THE REENTRANCY GUARD PROTECTS A MEASUREMENT, NOT A PROVEN THEFT (5.55).
- THE FOUNDING ROSTER IS CHOSEN BY WHOEVER DEPLOYS, and every founding seat starts UNPRICED and
  therefore FREE TO TAKE. **That is the bootstrap, not a hole** — a roster that could not be taken
  from its founders would be the cartel the lease exists to prevent. Say it that way.
- **QUEUE COSTS A TRADER 36% MORE PER SWAP THAN A BARE v4 POOL** (5.71). Say the number.
- **`addToSeat` IS QUADRATIC IN THE ROSTER** at 2,610,805 gas worst case (5.72).

=======================================================================
COMMANDS — ALL VERIFIED BY EXECUTION 2026-08-29
=======================================================================
    export PATH="$HOME/.foundry/bin:$PATH"

    forge build
    forge test                                                   # 172 passed, 1 skipped
    forge test --match-path "test/queue/Deploy.t.sol"      -vv    # 6 passed, the deployment path
    forge test --match-path "test/queue/Invariant.t.sol"   -vv    # 13 passed, GATE 6 + coverage log
    forge test --match-path "test/queue/Adversarial.t.sol"        # 15 passed, the named attacks
    forge test --match-path "test/queue/Gas.t.sol"         -vv    # 7 passed, the printed gas table
    forge test --match-path "test/queue/Harberger.t.sol"          # 47 passed, Phase 4's gate
    forge test --match-path "test/queue/Rank.t.sol"               # 19 passed, Phase 3's gate
    forge test --match-path "test/queue/Hygiene.t.sol"            # 2 passed, the instrument checks
    forge test --match-test <name> -vvv
    forge fmt src/ test/queue/ script/
    forge lint src/                                               # must stay CLEAN, zero notes
    python3 script/mutate.py                                      # 68 mutations, must be 0 survivors
    python3 script/mutate.py --campaign M62 M63 M64 M65 M66       # §D.8 V3, names the invariant

    # The deployment tests against the LIVE chain (needs network, no funds):
    QUEUE_FORK=true forge test --match-path "test/queue/DeployFork.t.sol" -vv    # 6 passed

    # The frontend — one static file, no build step:
    open frontend/index.html

    # If an invariant replay gets stuck on a stale counterexample:
    rm -rf cache/invariant/failures

NOTE ON DEPLOYING THE HOOK IN TESTS: the constructor takes NINE arguments —
    (poolManager, c0, c1, FEE, SPACING, roster, rentBps, rentPeriod, firmWindow)
**Never write that list out by hand.** There are exactly TWO places it is written:
`QueueFixture._ctorArgs(roster)` (plus two overloads) for the suites, and
`QueueDeployBase._ctorArgs(pm, c0, c1, roster)` for deployment.

`BaseHook` validates the deployment address in ITS constructor, which runs FIRST — so a plain
`new QueueHarness(...)` dies on the hook-flags check. Use `_expectDeployRevert` (Rank.t.sol) or
`_expectCtorRevert` (Harberger.t.sol) to assert constructor reverts.

FIXTURE HELPERS YOU WILL NEED:
    hook.ranking() / hook.idAtRank(r) / hook.rankOfId(id) / hook.orderWord() / hook.pool()
    _swap(zeroForOne, amountIn)          — witness-aware, traded from address(this)
    _swapFrom(who, zeroForOne, amountIn) — witness-aware, traded from a chosen actor
    _withdrawTracked(seatId, w0, w1)     — witness-aware withdrawal; debits by what was PAID (F1)
    _refDemote(seatId)                   — the witness's copy of a demotion
    _check(tag)                          — ledger conservation AND every seat against the witness
    _checkOrder(tag) / _checkInvariantC(tag) / _checkInvariantF(tag, tol) / _checkInvariantR(tag)
    _open(bps)                           — seed over the FULL range
    _openRange(bps, tl, tu)              — seed over a CHOSEN range (see test_1_11)

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
