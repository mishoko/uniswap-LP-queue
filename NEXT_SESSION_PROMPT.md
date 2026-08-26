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
  3. PROGRESS.md  — what is already proven, what is open, and what the next action is
  4. BUSINESS.md  — what QUEUE is, why it exists, and what may honestly be claimed about it

Then do exactly what PROGRESS.md names as the next action, following PLAN.md's phase gates.

WHAT QUEUE IS, IN ONE PARAGRAPH SO YOU HAVE THE SHAPE BEFORE YOU READ:
Every concentrated automated market maker is a pro-rata market — all liquidity at a price level is
filled proportionally. Every real electronic market on earth uses price-time priority, where being
early in the queue is the single most valuable asset in market making. Uniswap has never had a
queue, so it has never had a price for one. QUEUE is a hook that custodies the pool's liquidity and
allocates each swap FRONT-FIRST through an ordered list of depositors, making "where you sit in the
fill order" a transferable, priced asset.

HOW TO WORK — these are not style preferences, they are the method:

- BRUTAL HONESTY. You are not here to validate the owner or yourself. A false "PASS" is worse than
  an honest "FAIL". If a direction is weak, say so plainly. Report outcomes faithfully: if tests
  fail, show the output; if you skipped something, say so; never describe a plan as a result.

- DISTRUST GREEN RESULTS. A test that passes on the first run is a reason for suspicion, not
  satisfaction. On this project, mutation testing or a negative control caught a defective test in
  7 out of 7 cases where one was run — several times belonging to the person who wrote the control.
  Before you believe any suite, deliberately break the code it covers and confirm it goes red.

- NEVER TEST AT A 1:1 PRICE. Use 1:4 or worse. A 1:1 fixture hides every token0/token1 unit-mixing
  bug, and that exact mistake destroyed an earlier project in this repo.

- MEASURE GAS WITH vm.cool(). Forge keeps storage warm inside a test body; a real measurement here
  was 2.5x optimistic until cold-access pricing was restored.

- MEASURE CONSERVATION ON POOLMANAGER'S OWN TOKEN BALANCES, never on the hook's bookkeeping.

- VALIDATE THE RISKIEST ASSUMPTION BEFORE BUILDING ON IT. One thing at a time. This rule is why
  this project killed three bad designs before writing production code rather than after.

- ASSERT THE REVERT REASON in every negative control. A control that fails for an unrelated reason
  proves nothing, and that mistake was made here.

WHEN YOU HIT SOMETHING AMBIGUOUS, use the decision framework in AGENTS.md section 4. Short version:
if a test passes that you expected to fail, STOP and prove the test can fail at all. If an
unspecified choice is cosmetic, pick the simpler option and record it in PROGRESS.md. If a choice
changes the mechanism's economics or security — who receives fees, how seats are allocated, adding
an admin function or an external dependency — stop and ask the owner.

HARD CONSTRAINTS, do not violate:
- No off-chain components. No server, relay, keeper service, watch-tower or scanner. The product is
  a contract.
- No mainnet deployment.
- Do not try to detect toxic flow. It is proven impossible for a v4 hook and QUEUE's entire premise
  is that it does not classify anyone.
- Do not add an admin function, upgrade path or privileged role without asking.

UPDATE PROGRESS.md at the end of every working session — phase, status, what was proven, what
failed, decisions taken, open questions. That file is the project's memory; the conversation is not.
If PLAN.md turns out to be wrong about something, update PLAN.md too — it is a living document.

Begin by reading the four files above, then state briefly what you understand the next action to be
and what you would need to prove for it to count as done. Then do it.
```

---

## Notes for the human handing this over

- **The prompt above is deliberately self-contained.** It repeats the five testing laws inline rather
  than only pointing at `AGENTS.md`, because a cheaper or non-Claude model may not reliably follow a
  file reference before starting work.
- **If the agent's first move is to write mechanism code, stop it.** Phase 0 is reproducing the
  archived reference spike and confirming its three negative controls go red. An agent that skips
  straight to features has not read `PLAN.md`.
- **The most likely failure mode is a confident green result.** If it reports everything passing on
  the first attempt, ask it to mutate the allocator and show you the failure. If it cannot, it has
  not really tested anything.
- **The second most likely failure mode is silent scope drift** — adding an admin function "for
  flexibility", or an off-chain helper "just for the demo". Both are forbidden and both will be
  proposed.
