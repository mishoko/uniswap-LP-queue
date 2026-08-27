# NEXT_SESSION_PROMPT.md

**Paste the block below verbatim as the first message to a fresh agent** (Claude Code, or any other
frontier model with file and shell access). It assumes zero prior knowledge.

Last updated **2026-08-27**, after Phases 0, 1 and 2 closed. Every command in it was verified by
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
Phases 0, 1 and 2 are COMPLETE and committed. The mechanism works.

    forge test        ->  59 passed, 0 failed        (7 suites)
    forge lint src/   ->  clean
    20 production mutations run across Phases 1-2, ZERO survivors.

WHAT EXISTS:
  src/queue/QueueHook.sol             the hook: allocator, cursors, deposit/withdraw, float, sweep
  src/queue/libraries/Allocation.sol  the allocation arithmetic, pure and fuzzable
  test/queue/                         6 suites + a shared fixture + a TEST-ONLY harness
  test/spike/QueueAllocator.t.sol     the archived reference implementation (do not edit)

WHAT IS PROVEN:
  - Front-first allocation is exact to the wei in both tokens, at 1:4, 1:1000, 1000:1, and at
    18/6 AND 6/18 decimals.
  - The protocol fee is handled correctly, including at a MAXIMUM fee and with lpFee == 0, and
    verified against a FOREIGN POOL sharing a currency.
  - Per-seat withdrawal works from a shared two-slot float, in all six orderings, with no
    poolManager.swap anywhere in the contract.
  - The redemption residual is ~0.15 wei per swap per token, LINEAR and converging (asserted).

THE ONE THING BLOCKING A SHIPPABLE PRODUCT: rank is still granted by ARRIVAL ORDER. One wei of
each token currently buys the head seat. That is Phase 3's job and it is your next action.

=======================================================================
START BY READING, IN THIS ORDER, AND DO NOT SKIP ANY
=======================================================================
  1. AGENTS.md    — how to work here. The five laws of testing, the decision framework, and
                    §3b THE TESTING ARCHITECTURE, which tells you exactly how this codebase is
                    tested and why it is NOT TDD. Read §3b carefully; it is the working method.
  2. PLAN.md      — starts with a BUILD STATUS dashboard showing exactly which phases and which
                    individual criteria are closed. Then §C.3 (Phase 3) and §D.5 (its gate).
  3. PROGRESS.md  — the narrative, newest first. The status board at the top mirrors PLAN's.
  4. PITFALLS.md  — the standing hazard ledger, 150+ rows, every one graded by evidence.
                    READ SECTION 5 BEFORE YOU WRITE ANY CODE. Closed rows are marked ✅ and kept.
  5. BUSINESS.md  — what QUEUE is, why it exists, what may honestly be claimed about it.

Verify the ground before building on it (about 3 seconds):

    export PATH="$HOME/.foundry/bin:$PATH"
    forge test

Expect 59 passed / 0 failed. If not, STOP and report it rather than working around it.

=======================================================================
YOUR NEXT ACTION — PHASE 3: THE ERC-6909 RANK TOKEN (PLAN §C.3, gate §D.5)
=======================================================================
Phase 3 is the SUBMITTABLE state. It replaces the provisional `seatOwner` mapping in
src/queue/QueueHook.sol with a real ERC-6909 rank token, so a seat can be held, priced and SOLD.

WHAT MUST BE TRUE WHEN YOU ARE DONE:
  - Rank is BOUGHT or Harberger-held, NEVER granted by deposit order. This is a HARD RULE
    (PITFALLS 5.8, 6.x). While rank is granted, the head is dust-griefable.
  - Transferring rank moves the SEAT, and you must decide and document what happens to the
    capital sitting in it. PLAN §B.8 says "rank moves; capital does not" — read it before
    designing anything.
  - DELETE test_KNOWN_HOLE_rankIsGrantedByArrivalOrder in test/queue/Deposit.t.sol. It exists
    solely to assert the hole you are closing. If it still passes, you have not closed it.
  - The capital-evacuation controls in §D.5 must be red before you believe any of it.

BEFORE YOU WRITE THE MECHANISM, note two things already settled — do not re-litigate them:
  - FAIRNESS IS CLOSED. QUEUE is exactly zero-sum against pro-rata, so the tail seat's excess
    return has the OPPOSITE SIGN to the pool's own LP P&L. Both seats cannot beat pro-rata. That
    makes fairness a TRANSFER problem, not an allocation problem, and the transfer is: sell or
    rent the rank. Six mechanisms were generated and KILLED (PITFALLS §3). Rank decay/rotation is
    FATAL — rank becomes free by waiting. Do not re-propose any of them.
  - PHASE 3 ALONE IS A ONE-SIDED MARKET. The tail's compensation channel is Harberger rent,
    which is Phase 4. The honest Phase 3 answer to "why would anyone hold seat 5?" is "they
    wouldn't." Either disclose that out loud or reach Phase 4.

=======================================================================
HOW TO WORK HERE — THIS IS NOT TDD
=======================================================================
The method is BUILD FAITHFULLY -> ATTACK IT -> FIX WHAT THE ATTACK FINDS, and the third step is
the one that matters. Tests written alongside code encode the author's assumptions; a mutation
does not care what the author assumed.

ON THIS PROJECT, MUTATION TESTING HAS FOUND A REAL DEFECT EVERY SINGLE TIME IT WAS RUN.

At every gate, mutate each load-bearing line you wrote, run the suite, confirm RED, then revert.
A mutation that SURVIVES is a finding with exactly three honest responses:
  (a) write the missing test,
  (b) DELETE the line if nothing depends on it — this happened, see PITFALLS 5.49,
  (c) write down why it cannot be tested.
Widening a tolerance until it "passes" is none of these. AGENTS.md §3b has the full method.

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

THREE MORE RULES THIS PROJECT PAID FOR, AND THEY KEEP BITING:
6. MUTATE EVERY DIRECTION-SYMMETRIC RULE SEPARATELY. A rule appearing once per direction can be
   perfectly covered one way and covered by NOTHING the other way. This has happened TWICE, in
   two different functions (PITFALLS 5.37, 5.50). Phase 3 will have symmetric rules too.
7. ASSERT ON THE CONTRACT'S NUMBERS, NEVER ON THE FIXTURE'S OWN MEASUREMENTS. Comparing two
   fixture-side quantities is tautological and WILL pass against a broken implementation
   (PITFALLS 5.34).
8. BEFORE BELIEVING ANY MEASUREMENT, ASK WHAT THE FIXTURE CANNOT REPRESENT. A single-pool
   fixture cannot see a global counter being corrupted. A principal-only position valuation
   cannot see accrued LP fees — that one produced a 9.6e15-wei-per-swap phantom that looked
   exactly like catastrophic ledger corruption (PITFALLS 5.27, 5.46).

BRUTAL HONESTY. You are not here to validate the owner or yourself. A false "PASS" is worse than
an honest "FAIL". If a direction is weak, say so plainly. Never describe a plan as a result.

DO NOT just label a flaw or add a comment when you find one. The owner's standing instruction
(2026-08-27) is that problems get PROPERLY FIXED in a robust, sustainable way — even if that
means deleting docs or tests. The end product must have no hidden caveats.

You may decide implementation details and course corrections yourself, with the expert panel in
AGENTS.md. Stop and ask the owner only when a choice changes the mechanism's ECONOMICS or
SECURITY — who receives fees, how seats are allocated, adding an admin function or an external
dependency — or when it would materially hurt the end product.

=======================================================================
HARD CONSTRAINTS — DO NOT VIOLATE
=======================================================================
- No off-chain components. No server, relay, keeper, watch-tower or scanner. The product is a
  contract.
- No mainnet deployment. Unichain Sepolia only, and not before Phase 3's gate is green.
- Do not try to detect toxic flow. Proven impossible for a v4 hook, and QUEUE's entire premise
  is that it does not classify anyone.
- Do not attempt a curve that reduces LVR. Proven impossible.
- No admin function, upgrade path or privileged role without asking. THE SHIPPING CONTRACT
  CURRENTLY HAS NO PERMISSIONLESS STATE-CHANGING ENTRY POINT IT SHOULD NOT HAVE, and no
  privileged role at all. Keep it that way.
- Never let untrusted code choose how much memory you allocate. Use bounded assembly copies.
  This bug was introduced THREE times in this repo by people who knew about it.
- Rank must be BOUGHT or Harberger-held, never granted by deposit order.

=======================================================================
KNOWN WEAK POINTS — BE READY, DO NOT DISCOVER THEM ON CAMERA
=======================================================================
- FULL-RANGE DEPTH is the sharpest unanswered attack (PITFALLS 5.17). One full-range position
  offers roughly 1/200th the depth per dollar of a +/-1% concentrated position, so a $1M pool
  quotes like $5-10k. OWNER DECISION 2026-08-27: answer it, do not fix it, until the float
  sweep is proven in the wild. The allocator is range-agnostic, so a bounded band is a config
  change — but narrowing the range drives seats single-token faster and stresses the float.
- THE SWEEP IS BOUNDED BY THE SMALLER LEG (PITFALLS 5.43). sweepFloatIntoPosition can only
  reinject float in proportion to its MINORITY token, because adding to a range straddling the
  price needs both. DO NOT CLAIM IT "RESTORES DEPTH".
- AN OFF-RATIO DEPOSIT BECOMES FLOAT, NOT DEPTH (PITFALLS 5.44). The depositor is credited in
  full and loses nothing, but the pool gains almost no depth until the other leg arrives.
- "THE SEAT PRICE IS THE TOXICITY" IS OVERCLAIMED (PITFALLS 5.20). The defensible framing is
  that QUEUE is a LEVERAGE instrument on the pool's own LP return, L(s) = (C/c1) * min(1, c1/s).
- DO NOT CLAIM "the queue's face value is redeemable". The defensible claim, now measured, is:
  each seat redeems its entitlement to within a bound that grows LINEARLY at ~0.15 wei per swap
  and never compounds.

=======================================================================
COMMANDS — ALL VERIFIED BY EXECUTION 2026-08-27
=======================================================================
    export PATH="$HOME/.foundry/bin:$PATH"

    forge build
    forge test                                            # 59 passed
    forge test --match-path "test/queue/*"                # 50 passed
    forge test --match-path "test/spike/QueueAllocator.t.sol"   # 9 passed, the reference
    forge test --match-test <name> -vvv
    forge fmt src/ test/queue/
    forge lint src/                                       # must stay CLEAN

    # The archived withdrawal research, if you need to re-derive the float design:
    FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/withdrawal forge test \
      --match-path "docs/research/withdrawal/FloatWithdraw.t.sol"    # 22 passed

Do NOT use a wildcard over the whole archive spike/ directory — it pulls in CowNonSafeFork.t.sol,
which needs SEPOLIA_RPC_URL and will hand you a spurious RED on your first run.

=======================================================================
BEFORE YOU FINISH
=======================================================================
UPDATE PLAN.md's BUILD STATUS dashboard and tick the individual exit criteria you closed — the
dashboard is the authoritative answer to "what is done", not the log.
UPDATE PROGRESS.md — phase, status, what was proven, what failed, decisions taken, open questions.
ADD EVERY NEW HAZARD to PITFALLS.md with an evidence grade (PROVEN / MEASURED / REASONED /
UNVERIFIED / OPINION) and a file:line pointer. Mark closed rows ✅ and KEEP them.
If PLAN.md turns out to be wrong, FIX PLAN.md — it is a living document, not scripture. Delete
what is now false rather than annotating around it.
Those files are the project's memory. The conversation is not.

Begin by reading the five files above, then state briefly what you understand the next action to
be and what you would need to prove for it to count as done. Then do it.
```

---

## Notes for the human handing this over

- **The prompt is deliberately self-contained** — it repeats the laws and the current state inline
  rather than only pointing at files, because a cheaper or non-Claude model may not reliably follow
  a file reference before starting work.
- **If the agent's first move is to re-derive the allocator or the protocol-fee handling, stop it.**
  Both are closed, proven, and carry mutation-backed controls. Phase 3 is the rank token.
- **If it proposes a fairness mechanism, stop it.** That question is closed by the Fairness Theorem
  and the answer is an argument, not code. Six mechanisms were already generated and killed.
- **The most likely failure mode is still a confident green result.** If it reports everything
  passing on the first attempt, ask it to mutate the code it just wrote and show you the failures.
  If it cannot, it has not really tested anything.
- **The second most likely failure mode is silent scope drift** — adding an admin function "for
  flexibility", or an off-chain helper "just for the demo". Both are forbidden and both get
  proposed. A sub-agent in an earlier session also quietly edited `.gitignore` to un-ignore private
  files; watch for that class of thing.
- **Watch for tolerance-widening.** If a test starts failing and the fix is a bigger `assertApproxEqAbs`
  delta, that is green-number-chasing unless the new bound is derived from a measurement that is
  written down. This session set one bound from a fixture that was itself broken, and had to redo it.
