# NEXT_SESSION_PROMPT.md

**Paste the block below verbatim as the first message to a fresh agent** (Claude Code, or any other
frontier model with file and shell access). It assumes zero prior knowledge.

---

```
You are picking up an in-progress Uniswap v4 hook project called QUEUE, in the repository at
/Users/mishoko/projects/UHI10. You have no prior context and you do not need any — everything
required is in the repo.

START BY READING, IN THIS ORDER, AND DO NOT SKIP ANY OF THEM:
  1. AGENTS.md    — how to work here: the rules, the five laws of testing, the decision framework
  2. PLAN.md      — what to build, phased, with runnable acceptance criteria
  3. PROGRESS.md  — what is proven, what is open, what the next action is (newest entry first)
  4. PITFALLS.md  — the standing hazard ledger. 120+ rows, every one graded by evidence.
                    READ SECTION 5 (open hazards) BEFORE YOU WRITE ANY CODE.
  5. BUSINESS.md  — what QUEUE is, why it exists, what may honestly be claimed about it

WHAT QUEUE IS, IN ONE PARAGRAPH:
Every concentrated automated market maker is a pro-rata market — all liquidity at a price level is
filled proportionally. Every real electronic market on earth uses price-time priority, where being
early in the queue is the single most valuable asset in market making. Uniswap has never had a
queue, so it has never had a price for one. QUEUE is a hook that custodies the pool's liquidity and
allocates each swap FRONT-FIRST through an ordered list of depositors, making "where you sit in the
fill order" a transferable, priced asset.

=======================================================================
YOUR NEXT ACTION — in this order, and do not reorder them
=======================================================================

STEP 1. PHASE 0 (PLAN.md §C.0). Reproduce the reference spike from
  archive/2026-08-26/test/spike/QueueAllocator.t.sol in a new test/queue/ tree and confirm its
  THREE negative controls still go RED. A harness already exists: foundry.toml has a
  [profile.spike] pointing src/test at the archived tree. Run it with:
      export PATH="$HOME/.foundry/bin:$PATH"
      FOUNDRY_PROFILE=spike forge test --match-path "archive/2026-08-26/test/spike/QueueAllocator.t.sol"
  VERIFIED 2026-08-26: that command gives 9 passed / 0 failed, including the three negative
  controls (proRata, flooredShares, offByOneCursor) and a positive control on the same harness.
  Do NOT use a wildcard over the whole spike/ directory — it pulls in CowNonSafeFork.t.sol, which
  needs SEPOLIA_RPC_URL and will hand you a spurious RED on your first run.
  Do NOT write mechanism code until Phase 0 is green AND the controls are red.

STEP 2. ✅ ALREADY DONE 2026-08-26 — DO NOT REDO IT. Per-seat withdrawal feasibility is SETTLED:
  FEASIBLE via a two-slot shared float. 22/22 tests green in docs/research/withdrawal/
  (FloatWithdraw.t.sol + feasibility.md). Read feasibility.md §9 before writing Phase 1 state.
  Reproduce if you want confidence (recommended, ~10s):
      export PATH="$HOME/.foundry/bin:$PATH"
      FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/withdrawal forge test \
        --match-path "docs/research/withdrawal/FloatWithdraw.t.sol"

  WHAT IT PROVED: a 100%-converted seat (ledger 100% one token) redeems its EXACT entitlement in
  both tokens, with NO poolManager.swap, in any withdrawal order, at 1:4 and at 18/6 decimals,
  zero conservation slack, 252,672 gas cold.
  INVARIANT F (PROVEN):  sum(q[i].aX) == redeemable X + floatX, to within the §E.4 residual.
  The aggregate is consistent; only PER-SEAT composition is unpayable from a proportional removal.
  THE ALLOCATOR IS UNCHANGED — character-for-character the spike's FRONT_FIRST path. Phase 1's
  arithmetic is unaffected.

  STATE YOU MUST ADD (PLAN §B.3), and the reason Phase 1 waited for this:
      uint256 internal float0;   // token0 held OUTSIDE the position, owed to the queue
      uint256 internal float1;   // token1 held OUTSIDE the position, owed to the queue
  Plus: withdraw MUST decrement `liquidity` by D (§B.7 never does — every later sizing computation
  is wrong without it), and INVARIANT F must sit next to the declarations in §B.3.

STEP 2b. BUILD sweepFloatIntoPosition() — REQUIRED, UNBUILT, and the biggest remaining gap.
  Permissionless, no privileged role, no admin function: re-add D' = min(float0/f0, float1/f1)
  worth of liquidity, credit nobody, decrement both floats by the actual consumed amounts.
  WITHOUT IT POOL DEPTH DEGRADES MONOTONICALLY as seats withdraw imbalanced legs. UNPROVEN.

STEP 3. PHASE 1 (PLAN.md §C.1), incorporating the decisions already taken (see below) and the
  float state from STEP 2. NOTE: P2-and-the-float DO compose — that is settled, 19/19 tests,
  INVARIANT F survives a MAXIMUM protocol fee with a 0-wei residual in the balance form and the
  residual does NOT scale with the fee. What is NOT settled is P2's own mechanism (see decision 1
  above — it is a Phase 1 blocker). Also still open: lpFee == 0 under P2.

STEP 4. ASK THE OWNER before implementing deposit: PLAN §B.7 says "refund any unconsumed remainder
  to msg.sender". Under a float the better answer is to absorb the remainder into floatX and credit
  it to the seat — cheaper, and it reduces the float. This CHANGES WHO GETS WHAT, so it is an
  AGENTS.md §4 escalation. Not built, not tested. Do not decide it yourself.

=======================================================================
DECISIONS ALREADY TAKEN — do not re-litigate these
=======================================================================

1. PROTOCOL FEE: the DECISION is P2 (account for it), NOT P1 (refuse). Owner decision 2026-08-26.
   Net out the protocol fee so the ledger credits only what the position actually received.
   WHY NOT P1: Uniswap governance Proposal 100 reportedly executed 2026-07-27, activating v4
   protocol fees on mainnet and 6+ chains with no opt-out for hook developers. P1 would ship a
   product a governance vote can switch off. (Press-sourced, UNVERIFIED — verify on-chain with
   poolManager.protocolFeeController() and StateLibrary.getSlot0(poolId).)

   *** BUT THE OBVIOUS IMPLEMENTATION IS BROKEN. READ THIS BEFORE WRITING A LINE OF IT. ***
   Do NOT implement P2 by diffing poolManager.protocolFeesAccrued(currency). That mapping is
   GLOBAL PER CURRENCY, not per pool (ProtocolFees.sol:21 — mapping(Currency => uint256), there is
   no PoolId in it). Diffing it absorbs the protocol fees of EVERY OTHER v4 POOL sharing either
   currency. PROVEN, with tests, in docs/research/withdrawal/fee-float-composition.md §6:
     - X1 SILENT UNDER-CREDIT: a foreign pool on the same pair took 2e15 wei; QUEUE's next swap
       under-credited the queue by exactly that, stranded and owed to nobody. No attacker needed —
       ordinary volume on any other pool of the same token does it continuously.
     - X2 PERMANENT BRICK: if foreign accrual exceeds the next swap's input, `amtIn -= pfDelta`
       underflows inside afterSwap and the swap reverts. The failed swap never advances pfSeen, so
       every later swap recomputes the same oversized delta. THE POOL IS DEAD, permanently.
     - pfSeen starting at 0 bricks or mis-credits the hook's FIRST EVER swap on a currency that
       already carries accrued fees.
   Reproduce both before designing the replacement:
       FOUNDRY_PROFILE=spike FOUNDRY_TEST=docs/research/withdrawal forge test \
         --match-path "docs/research/withdrawal/FeeFloatComposition.t.sol"

   YOUR FIRST REAL TASK IS TO REPLACE THE MECHANISM, and it is NOT a one-liner. Derive the protocol
   fee arithmetically from the swap instead. Constraints that make it hard, all already documented:
     - lpFee == 0 ⇒ swapFee == protocolFee ⇒ v4 takes the ENTIRE feeAmount by a different formula
       (Pool.sol:391-392, PITFALLS §1.5)
     - exact-output swaps round the other way (PITFALLS §1.12)
     - amountToProtocol is summed PER SWAP STEP with per-step rounding across tick crossings, so
       `amtIn * pf / 1e6` will NOT be wei-exact
     - clamping pfDelta to a locally-derived upper bound removes the BRICK but NOT the UNDER-CREDIT
   Give it its own experiment and its own negative control. A single-pool fixture CANNOT test this —
   see the doctrine note below.

   *** THE DOCTRINE LESSON, do not repeat it. *** The test that originally "MEASURED P2 closing the
   gap to 3 wei" (test_M3) ran in a SINGLE-POOL fixture. The mechanism was right about WHAT to
   subtract; the INSTRUMENT was wrong and the fixture could not see it. Before trusting any
   measurement on this project, ask what the fixture is structurally incapable of representing.

2. FAIRNESS: build NO new fairness mechanism. Ship the argument instead.
   THE FAIRNESS THEOREM: QUEUE is exactly ZERO-SUM against pro-rata, so the tail seat's excess
   return over pro-rata has the OPPOSITE SIGN to the pool's own net LP P&L. Profitable pool =>
   the tail is strictly worse off; loss-making pool => strictly better off. Both seats cannot
   beat pro-rata, and no ordering, banding, rotation or partial blend can change that. Fairness
   is therefore a TRANSFER problem, not an allocation problem, and the design already names the
   transfer: sell or rent the rank.
   Six variants were generated and KILLED with reasons (PITFALLS.md §3, fairness.md). Rank
   decay/rotation is FATAL — rank becomes free by waiting. Do not re-propose any of them.

=======================================================================
THE FIVE LAWS OF TESTING — all five were paid for
=======================================================================

1. NEVER test at a 1:1 price. Use 1:4 or worse, and unequal decimals (18/6) where you can. A 1:1
   fixture hides every token0/token1 unit-mixing bug, and that exact mistake destroyed an earlier
   project in this repo.
2. Every claim needs a negative control that goes RED, and you MUST assert the revert REASON. A
   control that fails for an unrelated reason proves nothing. That mistake was made here.
3. Measure conservation on PoolManager's own token balances, never on the hook's bookkeeping.
   *** AMENDED 2026-08-26, AND THIS AMENDMENT IS LOAD-BEARING ***
   The RAW-balance form is BLIND to a whole bug class. protocolFeesAccrued money sits INSIDE
   PoolManager's ERC20 balance until collected, so a raw-balance conservation test PASSES AT 0 WEI
   ERROR while the position is short 0.354e18. Measure against
       PoolManager balance - protocolFeesAccrued(currency)
   or directly against redeemAll(). Second corollary: conservation of the LEDGER and redeemability
   of the POSITION are two different claims needing two different assertions.
4. Measure gas with vm.cool(). Forge keeps storage warm inside a test body; a real measurement
   here was 2.5x optimistic until cold-access pricing was restored.
5. A first-run pass is a reason for SUSPICION, not satisfaction. On this project, mutation testing
   or a negative control caught a defective test in 7 out of 7 cases where one was run — several
   times belonging to the person who wrote the control. Before believing any suite, deliberately
   break the code it covers and confirm it goes red.

=======================================================================
HOW TO WORK
=======================================================================

- BRUTAL HONESTY. You are not here to validate the owner or yourself. A false "PASS" is worse than
  an honest "FAIL". If a direction is weak, say so plainly. Report outcomes faithfully: if tests
  fail, show the output; if you skipped something, say so; never describe a plan as a result.
- VALIDATE THE RISKIEST ASSUMPTION BEFORE BUILDING ON IT. One thing at a time. That rule is why
  this project killed three bad designs before writing production code rather than after, and it
  is exactly why the withdrawal question (STEP 2) was settled BEFORE Phase 1, not after.
- DELEGATE context-heavy work to sub-agents and keep your own context clean. Put the honesty
  mandate in every sub-agent prompt. Retire them when done.
- CONSULT THE EXPERT PANEL (AGENTS.md) when a task or sub-task is delivered. It has repeatedly
  found things the author missed.
- WHEN SOMETHING IS AMBIGUOUS, use the decision framework in AGENTS.md §4. Short version: if a
  test passes that you expected to fail, STOP and prove the test can fail at all. If an
  unspecified choice is cosmetic, pick the simpler option and record it in PROGRESS.md. If a
  choice changes the mechanism's economics or security — who receives fees, how seats are
  allocated, adding an admin function or an external dependency — stop and ask the owner.

HARD CONSTRAINTS, do not violate:
- No off-chain components. No server, relay, keeper service, watch-tower or scanner. The product
  is a contract.
- No mainnet deployment.
- Do not try to detect toxic flow. Proven impossible for a v4 hook, and QUEUE's entire premise is
  that it does not classify anyone.
- Do not attempt a curve that reduces LVR. Proven impossible.
- Do not add an admin function, upgrade path or privileged role without asking.
- Never let untrusted code choose how much memory you allocate. Use bounded assembly copies. This
  bug was introduced THREE times in this repo by people who knew about it.
- Rank must be BOUGHT or Harberger-held, never granted by deposit order (dust-griefing the head).

=======================================================================
KNOWN WEAK POINTS — be ready for these, do not discover them on camera
=======================================================================

- FULL-RANGE DEPTH is the sharpest unanswered attack and it appears in NO document. The hook mints
  one full-range position, which offers roughly 1/200th the depth per dollar of a +/-1%
  concentrated position: a $1M pool quotes the depth of a ~$5-10k concentrated position, and a
  $10k swap costs ~4% slippage. A v4-native judge will ask "who routes to this?". You need an
  ANSWER, not necessarily a fix — the allocator is range-agnostic, so a bounded band is a config
  change. WARNING: narrowing the range makes seats go single-token MORE easily, which stresses the
  float (STEP 2) and accelerates the depth decay that sweepFloatIntoPosition (STEP 2b) exists to
  fix. Do not "fix" depth before 2b is built and proven.
- PHASE 3 IS A ONE-SIDED MARKET. The tail's compensation channel is Harberger rent, which is
  Phase 4. In Phase 3 the honest answer to "why would anyone hold seat 5?" is "they wouldn't."
  Disclose it or reach Phase 4.
- "THE SEAT PRICE IS THE TOXICITY" IS OVERCLAIMED. It measures leverage x expected LP return —
  already computable from public swap data — and under Harberger the signal is censored at zero on
  exactly the toxic side. The defensible framing is that QUEUE is a LEVERAGE instrument on the
  pool's own LP return, with L(s) = (C/c1) * min(1, c1/s): levered on everything, most levered on
  small swaps. Write that formula into BUSINESS.md; its two worked examples are special cases of
  it and it never states it.
- DO NOT CLAIM "the queue's face value is redeemable". The float does NOT solve the §E.4 residual —
  they are orthogonal. Measured: exact payout makes the LAST withdrawer revert `FloatShort` short by
  3 wei; policy F1 (pay min(face, available)) drains everyone but leaves 3-8 wei of ledger dust
  unpaid. Choose F1 (§B.7 already recommends it). The claim stays forbidden until the dust fix.

=======================================================================
BEFORE YOU FINISH
=======================================================================

UPDATE PROGRESS.md — phase, status, what was proven, what failed, decisions taken, open questions.
ADD ANY NEW HAZARD TO PITFALLS.md with an evidence grade (PROVEN / MEASURED / REASONED /
UNVERIFIED / OPINION) and a file:line pointer. If PLAN.md turns out to be wrong, UPDATE PLAN.md —
it is a living document, not scripture. Those files are the project's memory; the conversation is
not.

Begin by reading the five files above, then state briefly what you understand the next action to be
and what you would need to prove for it to count as done. Then do it.
```

---

## Notes for the human handing this over

- **The prompt is deliberately self-contained** — it repeats the five laws inline rather than only
  pointing at `AGENTS.md`, because a cheaper or non-Claude model may not reliably follow a file
  reference before starting work.
- **If the agent's first move is to write mechanism code, stop it.** Phase 0 is reproducing the
  archived spike and confirming its three negative controls go red.
- **STEP 2 is closed — if the agent starts re-spiking withdrawal feasibility, stop it.** It is
  settled FEASIBLE with 22 passing tests. What is genuinely open is STEP 2b
  (`sweepFloatIntoPosition`, required and unbuilt) and the float x protocol-fee interaction.
- **If the agent adds the float state but forgets to decrement `liquidity` on withdraw, stop it.**
  PLAN §B.7 never decrements it and every later sizing computation is silently wrong.
- **The most likely failure mode is a confident green result.** If it reports everything passing on
  the first attempt, ask it to mutate the allocator and show you the failure. If it cannot, it has
  not really tested anything. This is doubly true now that LAW 3 is known to have a blind form —
  a green conservation test is not evidence of solvency.
- **The second most likely failure mode is silent scope drift** — adding an admin function "for
  flexibility", or an off-chain helper "just for the demo". Both are forbidden and both will be
  proposed. A sub-agent in the last session also quietly edited `.gitignore` to un-ignore private
  files; watch for that class of thing.
- **Do not let it redesign for fairness.** That question is closed (the Fairness Theorem) and the
  answer is an argument, not code. Six mechanisms were already generated and killed.
