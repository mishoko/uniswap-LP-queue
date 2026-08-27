# NEXT_SESSION_PROMPT.md

**Paste the block below verbatim as the first message to a fresh agent** (Claude Code, or any other
frontier model with file and shell access). It assumes zero prior knowledge.

Last updated **2026-08-27**, after Phases 0, 1, 2 and 3 closed. Every command in it was verified by
execution at that time.

---

```
You are picking up an in-progress Uniswap v4 hook project called QUEUE, in the repository at
/Users/mishoko/projects/UHI10. You have no prior context and you do not need any — everything
required is in the repo.

=======================================================================
WHAT QUEUE IS, IN ONE PARAGRAPH
=======================================================================
Every concentrated automated market maker is a pro-rata market — all liquidity at a price level is
filled proportionally. Every real electronic market on earth uses price-time priority, where being
early in the queue is the single most valuable asset in market making. Uniswap has never had a
queue, so it has never had a price for one. QUEUE is a hook that custodies the pool's entire
liquidity as ONE position and allocates each swap FRONT-FIRST through an ordered list of seats,
making "where you sit in the fill order" a transferable, priced asset.

=======================================================================
WHERE THE PROJECT IS RIGHT NOW
=======================================================================
Phases 0, 1, 2 and 3 are COMPLETE and committed. THE PROJECT IS AT ITS SUBMITTABLE STATE.

    forge test        ->  77 passed, 0 failed        (8 suites)
    forge lint src/   ->  clean, zero notes
    49 production mutations run across Phases 1-3, ZERO survivors.

WHAT EXISTS:
  src/queue/QueueHook.sol             the hook: allocator, cursors, fund/withdraw, float, sweep,
                                      seat evacuation, pending claims
  src/queue/QueueSeats.sol            the ERC-6909 rank token: one id per seat, supply one
  src/queue/libraries/Allocation.sol  the allocation arithmetic, pure and fuzzable
  test/queue/                         7 suites + a shared fixture + a TEST-ONLY harness
  test/spike/QueueAllocator.t.sol     the archived reference implementation (do not edit)

WHAT IS PROVEN:
  - Front-first allocation is exact to the wei in both tokens, at 1:4, 1:1000, 1000:1, and at
    18/6 AND 6/18 decimals.
  - The protocol fee is handled correctly, including at a MAXIMUM fee and with lpFee == 0, and
    verified against a FOREIGN POOL sharing a currency.
  - Per-seat withdrawal works from a shared two-slot float, in all six orderings, with no
    poolManager.swap anywhere in the contract.
  - Rank is an ERC-6909 seat with supply exactly one, STRUCTURALLY: ownership is a single address
    slot and the token surface is a view over it, so there is no storage in which "two" fits.
  - Transferring a seat moves RANK and returns the CAPITAL to the seller, through `transfer`,
    through an allowance, and through an operator.
  - The roster is fixed at deployment. There is NO runtime path that creates a seat.
  - The redemption residual is ~0.15 wei per swap per token, LINEAR and converging (asserted).

=======================================================================
START BY READING, IN THIS ORDER, AND DO NOT SKIP ANY
=======================================================================
  1. AGENTS.md    — how to work here. The five laws of testing, the decision framework, and
                    S3b THE TESTING ARCHITECTURE, which tells you exactly how this codebase is
                    tested and why it is NOT TDD. Read S3b carefully; it is the working method.
  2. PLAN.md      — starts with a BUILD STATUS dashboard showing exactly which phases and which
                    individual criteria are closed. Then SC.4 (Phase 4) and SD.6 (its gate).
                    Read SB.10 before designing anything.
  3. PROGRESS.md  — the narrative, newest first. The status board at the top mirrors PLAN's.
  4. PITFALLS.md  — the standing hazard ledger, 56 rows in S5 alone, every one graded by evidence.
                    READ SECTION 5 BEFORE YOU WRITE ANY CODE. Closed rows are marked with a tick
                    and kept. Rows 5.51 to 5.56 are from the Phase 3 session and several of them
                    are about mistakes that WILL recur.
  5. BUSINESS.md  — what QUEUE is, why it exists, what may honestly be claimed about it.

Verify the ground before building on it (about 3 seconds):

    export PATH="$HOME/.foundry/bin:$PATH"
    forge test

Expect 77 passed / 0 failed. If not, STOP and report it rather than working around it.

=======================================================================
YOUR NEXT ACTION — PHASE 4: THE HARBERGER RENT VARIANT (PLAN SC.4, gate SD.6)
=======================================================================
PHASE 4 IS NOT OPTIONAL POLISH. It is what makes the project's central claim true. Three separate
open holes all close in it, and all three are currently things you would have to disclose on
camera:

  1. RANK IS NOT YET *BOUGHT*. The founding roster is fixed in the constructor — an endowment
     chosen by whoever deploys, exactly as an exchange's founding memberships were granted and
     then traded. What Phase 3 DID close is that rank cannot be obtained by dusting, by being
     early, or at any price the incumbent has not accepted. Continuous pricing needs Harberger.
     (PITFALLS 5.8, amended — read the amended row, not the headline.)
  2. PHASE 3 ALONE IS A ONE-SIDED MARKET (PITFALLS 5.19). The honest answer to "why would anyone
     hold seat 5?" is "they wouldn't." Rent is the tail's compensation channel.
  3. RANK-THEN-RUN IS OPEN (PITFALLS 5.9). Under plain transferable rank you can buy the front
     cheaply and dump it before a scheduled event — you eat the gap only if there is a bid, and
     PITFALLS 5.11 says the secondary market does not exist. Harberger closes it: you cannot
     leave your slot, only lower your self-assessment and pay rent on it.

WHAT PHASE 4 MUST DO (PLAN SB.10 has the full specification):
  - `selfPrice` per seat, denominated in currency0 only. NO oracle, NO external asset, NO price
    the hook chooses. Pricing a two-token basket needs a price, and that is forbidden (SE.11).
  - Rent accrues on block.timestamp, never block numbers. Tau and RENT_PERIOD are immutables.
  - Rent is paid to the seats BEHIND you, pro-rata by their currency0 balance only.
  - Foreclosure is a DEMOTION, not a seizure. No collateral, no liquidation crank, no health
    factor. A previous candidate in this repo died for exactly that.
  - Buyout: anyone may pay `selfPrice` to the holder at any time. The seat transfers EMPTY.

TWO THINGS PHASE 3 BUILT THAT PHASE 4 DEPENDS ON — do not undo either:
  - THE EVACUATION PATH IS UNBLOCKABLE ON PURPOSE. A buyout must be able to take the seat at the
    incumbent's own price at any time. If a funded seat could not move, every incumbent would hold
    a permanent veto over their own buyout by keeping one wei in it. This is why a seat transfer
    PAYS THE CAPITAL OUT rather than refusing, and why the residual becomes a `pendingWithdraw`
    claim rather than a revert. See QueueHook::_onSeatTransfer and PITFALLS 5.51.
  - SEAT ID EQUALS RANK INDEX, and Phase 4 is what breaks that. Foreclosure demotes a seat to the
    tail, so ids must stop being indices: you will need `idAtRank` / `rankOfId`. It was left out
    of Phase 3 deliberately — carrying an indirection that nothing can permute is carrying state
    no test can distinguish from a bug (PITFALLS 5.49). THE ALLOCATOR IS RANK-INDEXED AND DOES NOT
    READ SEAT IDS AT ALL, so the change is confined to the ownership lookups.

=======================================================================
HOW TO WORK HERE — THIS IS NOT TDD
=======================================================================
The method is BUILD FAITHFULLY -> ATTACK IT -> FIX WHAT THE ATTACK FINDS, and the third step is
the one that matters. Tests written alongside code encode the author's assumptions; a mutation
does not care what the author assumed.

ON THIS PROJECT, MUTATION TESTING HAS FOUND A REAL DEFECT EVERY SINGLE TIME IT WAS RUN. In the
Phase 3 session it found FOUR, including one that let anyone take any seat for free and be paid
its capital on the way out, past 71 passing tests.

At every gate, mutate each load-bearing line you wrote, run the suite, confirm RED, then revert.
A mutation that SURVIVES is a finding with exactly three honest responses:
  (a) write the missing test,
  (b) DELETE the line if nothing depends on it — this happened, see PITFALLS 5.49,
  (c) write down why it cannot be tested.
Widening a tolerance until it "passes" is none of these. AGENTS.md S3b has the full method.

THE FIVE LAWS OF TESTING — all five were paid for:
1. NEVER test at a 1:1 price. Use 1:4 or worse, with unequal decimals. BUT NOTE: v4 works
   entirely in RAW units, so fixture amounts must be in the pool's RAW ratio regardless of
   decimals. Getting this backwards sent 98% of every deposit into float and produced a
   completely fictitious residual (PITFALLS 5.48).
2. Every claim needs a negative control that goes RED, and you MUST assert the revert REASON.
   A control that fails for an unrelated reason proves nothing.
3. Measure conservation on PoolManager's own balances, never on the hook's bookkeeping — and
   NET OF protocolFeesAccrued, because accrued protocol fees sit inside PoolManager's ERC20
   balance until collected. Conservation of the LEDGER and redeemability of the POSITION are two
   different claims needing two different assertions.
4. Measure gas with vm.cool(). A defect that made a head-only swap read the ENTIRE queue was
   invisible to all 31 correctness tests until gas was measured properly (PITFALLS 5.38).
5. A first-run pass is a reason for SUSPICION, not satisfaction.

SEVEN MORE RULES THIS PROJECT PAID FOR, AND THEY KEEP BITING:
6. MUTATE EVERY COPY OF A RULE SEPARATELY — per direction, per branch, and PER ENTRY POINT. This
   has now happened FOUR times in four functions (PITFALLS 5.37, 5.50, 5.52 twice). The fourth
   was seat theft: `transferFrom` had a test, `transfer` had none. Phase 4 is full of paired
   rules — rent charged vs rent credited, buyout vs foreclosure. Mutate both sides of each.
7. A BOUND IN THE RIGHT DIRECTION IS NOT A CORRECTNESS ASSERTION. `assertLt(leftover, 1_000)` is
   blind to every defect that moves `leftover` the way the fix does; one such mutant passed MORE
   comfortably than the real code. Assert the identity, not the magnitude (PITFALLS 5.53).
   Phase 4's remainder rule — "sum(credited) + unallocated == charged, to the wei" — is exactly
   an identity. Write it that way.
8. BEFORE BELIEVING A PATH IS COVERED, CHECK THAT IT WAS ENTERED. An entire pendingWithdraw path
   was dead code under test while a test asserted things about it that all held vacuously at zero
   (PITFALLS 5.54). Make the test say so: assertTrue(x != 0, "...this test proves nothing").
9. ASSERT ON THE CONTRACT'S NUMBERS, NEVER ON THE FIXTURE'S OWN MEASUREMENTS (PITFALLS 5.34).
10. BEFORE BELIEVING ANY MEASUREMENT, ASK WHAT THE FIXTURE CANNOT REPRESENT. A single-pool
    fixture cannot see a global counter being corrupted; a principal-only position valuation
    cannot see accrued LP fees (PITFALLS 5.27, 5.46).
11. NEVER HARDCODE A STORAGE LAYOUT IN A TEST. A test assumed `q` sat at slot 0; a new base
    contract put three mappings in front of it. Read the slot from the contract.
12. WRITE DOWN WHAT YOU PROVED, NOT WHAT THE GUARD IS FOR. The reentrancy guard's first comment
    described a theft that could not be reproduced; it now says exactly what was and was not
    demonstrated (PITFALLS 5.55).

BRUTAL HONESTY. You are not here to validate the owner or yourself. A false "PASS" is worse than
an honest "FAIL". If a direction is weak, say so plainly. Never describe a plan as a result.

DO NOT just label a flaw or add a comment when you find one. The owner's standing instruction
(2026-08-27) is that problems get PROPERLY FIXED in a robust, sustainable way — even if that
means deleting docs or tests. The end product must have no hidden caveats. In Phase 3 this meant
overriding PLAN SB.8's specified transfer design, because building it faithfully revealed it was
a free denial of service; the plan was corrected and the rejected alternatives written down.

You may decide implementation details and course corrections yourself, with the expert panel in
AGENTS.md. Stop and ask the owner only when a choice changes the mechanism's ECONOMICS or
SECURITY — who receives fees, how seats are allocated, adding an admin function or an external
dependency — or when it would materially hurt the end product. NOTE: tau and RENT_PERIOD are
economics. Ask.

=======================================================================
HARD CONSTRAINTS — DO NOT VIOLATE
=======================================================================
- No off-chain components. No server, relay, keeper, watch-tower or scanner. The product is a
  contract.
- No mainnet deployment. Unichain Sepolia only.
- Do not try to detect toxic flow. Proven impossible for a v4 hook, and QUEUE's entire premise
  is that it does not classify anyone.
- Do not attempt a curve that reduces LVR. Proven impossible.
- No admin function, upgrade path or privileged role without asking. THE SHIPPING CONTRACT HAS
  NO PRIVILEGED ROLE AT ALL, and its only permissionless state-changing entry points are the
  seat holder's own (fund / withdraw / transfer / claim) plus `sweepFloatIntoPosition`, which
  credits nobody. Keep it that way.
- Never let untrusted code choose how much memory you allocate. Use bounded assembly copies.
  This bug was introduced THREE times in this repo by people who knew about it.
- Harberger is NOT a margin engine. No collateral, no oracle, no mark, no liquidation crank.
- Do not call it an auction. It is a self-assessed, always-for-sale lease with continuous rent,
  with no bidders required and no per-block winner. The nearest neighbours (the am-AMM family)
  auction pool-management rights to one winner per block, and a judge will probe the difference.

=======================================================================
KNOWN WEAK POINTS — BE READY, DO NOT DISCOVER THEM ON CAMERA
=======================================================================
- THE FOUNDING ROSTER IS AN ENDOWMENT (PITFALLS 5.8 as amended). Whoever deploys picks the
  initial holders. Say it plainly; Phase 4 is the answer.
- HARBERGER CANNOT EXPRESS A NEGATIVE SEAT VALUE (PITFALLS 5.10). Under toxic flow everyone
  declares near-zero and no rent flows. The variant that closes rank-then-run has its own
  unsolved gap. Disclose it.
- TAU IS A LOAD-BEARING PARAMETER, and this project's history says that is where a pitch dies.
  Do not defend a specific value. Show the mechanism at several, and make the SIGN of the seat
  price the finding.
- FULL-RANGE DEPTH is the sharpest unanswered attack (PITFALLS 5.17). One full-range position
  offers roughly 1/200th the depth per dollar of a +/-1% concentrated position. OWNER DECISION
  2026-08-27: answer it, do not fix it, until the float sweep is proven in the wild.
- THE SWEEP IS BOUNDED BY THE SMALLER LEG (PITFALLS 5.43), and a SEAT TRANSFER IS A SECOND
  TRIGGER FOR THE SAME DRAIN (5.56). Do not claim seat trading is depth-neutral.
- "THE SEAT PRICE IS THE TOXICITY" IS OVERCLAIMED (PITFALLS 5.20). The defensible framing is
  that QUEUE is a LEVERAGE instrument on the pool's own LP return, L(s) = (C/c1) * min(1, c1/s).
- DO NOT CLAIM "the queue's face value is redeemable". The defensible claim, now measured, is:
  each seat redeems its entitlement to within a bound that grows LINEARLY at ~0.15 wei per swap
  and never compounds.
- THE REENTRANCY GUARD PROTECTS A MEASUREMENT, NOT A PROVEN THEFT (PITFALLS 5.55). The window is
  real and PoolManager's lock does not close it. No value-extracting sequence was found. Say
  that, not more.

=======================================================================
COMMANDS — ALL VERIFIED BY EXECUTION 2026-08-27
=======================================================================
    export PATH="$HOME/.foundry/bin:$PATH"

    forge build
    forge test                                            # 77 passed
    forge test --match-path "test/queue/*"                # 68 passed
    forge test --match-path "test/queue/Rank.t.sol" -vv   # 19 passed, Phase 3's gate
    forge test --match-path "test/spike/QueueAllocator.t.sol"   # 9 passed, the reference
    forge test --match-test <name> -vvv
    forge fmt src/ test/queue/
    forge lint src/                                       # must stay CLEAN, zero notes

NOTE ON DEPLOYING THE HOOK IN TESTS: the constructor now takes a FOUNDING ROSTER as its last
argument, so every deployCodeTo call passes
    abi.encode(poolManager, c0, c1, FEE, SPACING, roster)
The fixture has `_roster(a)`, `_roster(a, b)`, `_roster(a, b, c)` and `_syntheticRoster(n)`.
`BaseHook` validates the deployment address in ITS constructor, which runs FIRST — so a plain
`new QueueHarness(...)` dies on the hook-flags check and never reaches your roster assertion.
Use the etch-and-call helper `_expectDeployRevert` in Rank.t.sol to assert constructor reverts.
```
