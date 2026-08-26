# AGENTS.md — operating manual for whoever works on this repo

**This file is model-agnostic. If you are Claude Code, `CLAUDE.md` is a symlink to this file — same
content. Read this first, then `PLAN.md`, then `BUSINESS.md`.**

You are building **QUEUE**, a Uniswap v4 hook. Everything you need is in this repo. You do not have
the conversation that produced it, and you do not need it.

---

## 1. Read this in order

| Order | File | Why |
|---|---|---|
| 1 | `AGENTS.md` (this file) | How to work here. Rules, gotchas, decision framework. |
| 2 | `PLAN.md` | What to build, phased, with runnable acceptance criteria. |
| 3 | `BUSINESS.md` | Why it exists, who uses it, what to say about it. |
| 4 | `PROGRESS.md` | What has already been done. **Update it as you go.** |
| 5 | `archive/2026-08-26/` | 25 hard-won v4 facts and every experiment behind the design. Read on demand, guided by `PLAN.md` §I. |

**The single most important sentence in the project:**

> Every concentrated AMM is a **pro-rata** market. Every real electronic market on earth is
> **price–time priority**, and queue position is the most valuable asset in electronic market making.
> **Uniswap has never had a queue, so it has never had a price for one.**

---

## 2. The mindset — this is not decoration, it is the method

> **Brutally honest. You are NOT here to validate the owner or yourself. A false "PASS" is worse than
> an honest "FAIL". Over-fitting and green-number-chasing are the first sin. When a test passes on
> the first run, that is a reason for suspicion, not satisfaction. When an assertion is aspirational,
> assert what is actually true and say what is not. If a direction is weak, say so plainly.**

This is not a style preference. On this project, **mutation testing or a negative control caught a
defective test in 7 out of 7 cases where one was run** — and in several of those the defective test
belonged to the person who wrote the control. Every single headline result that survived, survived
because somebody tried to break it.

**Report outcomes faithfully.** If tests fail, say so and show the output. If you skipped a step, say
so. If something is unproven, write UNPROVEN next to it. Never describe a plan as a result.

---

## 3. The five laws of testing here

Violating any of these produces a green test that proves nothing. All five were paid for.

1. **NEVER test at a 1:1 price.** Use 1:4 or worse, and unequal decimals (18/6) where you can. A 1:1
   fixture hides **every** token0/token1 unit-mixing bug. A prior project in this repo shipped a
   metric that subtracted token1 units from token0 units; on its 1:1 fixture the error was invisible,
   and on a real pair it pinned at maximum fee forever.
2. **Every claim needs a negative control that goes RED — and you must assert the revert REASON.**
   A control that fails for an unrelated reason proves nothing. This exact mistake was made here: a
   test asserted only `reason.length > 0` and passed under a mutation, because the mutant reverted
   with a completely different error.
3. **Measure conservation on PoolManager's own token balances**, never on the hook's own bookkeeping.
   A hook that miscounts will happily agree with itself.
4. **Measure gas with `vm.cool()`.** Forge keeps storage warm inside a test body. A real measurement
   here was **2.5× optimistic** until cold-access pricing was restored.
5. **A first-run pass is a reason for suspicion.** Before believing any suite, deliberately break the
   code it covers and confirm the suite goes red.

---

## 4. Decision framework — what to do when you are unsure

You will hit ambiguity. Use this instead of guessing or stalling.

| Situation | What to do |
|---|---|
| **A test passes that you expected to fail** | **STOP.** This is the highest-risk state in the project. Prove the test can fail at all: mutate the code under test and confirm red. Only then believe the pass. Record it in `PROGRESS.md`. |
| **The plan contradicts what the code does** | The code wins as evidence, the plan wins as intent. Record the divergence in `PROGRESS.md` and **update `PLAN.md`** — the plan is a living document, not scripture. |
| A design choice is not specified and both options are defensible | Pick the simpler one, **write down which you picked and why** in `PROGRESS.md`, and continue. Do not stall. |
| A design choice changes the mechanism's economics or its security | **Stop and ask the owner.** Examples: changing who receives fees, changing seat allocation rules, adding an admin function, adding an external dependency. |
| You find a bug in the design (not the code) | Write it up with a failing test if you can. This is valuable output, not a setback. Do not patch around it silently. |
| Something in the archive contradicts this file | This file and `PLAN.md` win. The archive is history; note the contradiction. |
| You are asked to do something the rules forbid | See §6. Say so plainly and stop. |

**One thing at a time. Validate the riskiest assumption BEFORE building on it.** That single rule is
why this project killed three bad designs before writing production code instead of after.

---

## 5. Review lenses — apply at every phase gate

Before declaring a phase complete, walk the work past each of these deliberately. They catch
different things:

- **Exploit developer** — how would I steal from this?
- **Economic incentives** — is there a state where the behaviour we deter becomes the cheapest action?
  *(This failure — a "free lane" — has killed seven mechanisms in this project's history. Hunt for it
  in your own work before someone else does.)*
- **Edge cases** — zero, one, maximum, empty queue, single entry, exact-fill boundaries.
- **Devil's advocate** — what claim am I making that the tests do not actually support?
- **State transition** — what happens if this is interrupted, reentered, or called out of order?
- **Periphery** — libraries and helpers are trusted implicitly; one bug there compromises every caller.

---

## 6. Hard rules — do not violate these

- **No off-chain components.** No server, relay, watch-tower, keeper service, scanner, or hosted
  anything. The product is a contract.
- **No mainnet deployment.**
- **Do not attempt to detect toxic flow.** It is proven impossible for a v4 hook — every signal is
  forgeable by splitting a quantity, shopping addresses, or waiting one block. QUEUE's entire premise
  is that it does **not** classify anyone. See `PLAN.md` §E.
- **Do not attempt a curve that reduces LVR.** Proven impossible: LVR rate and marginal depth are the
  same quantity, so halving one halves the other.
- **Do not add an admin function, an upgrade path, or a privileged role** without asking.
- **Never let untrusted code choose how much memory you allocate.** Solidity's `(bool, bytes memory)`
  call form copies all returndata. Use bounded assembly copies. This bug was introduced **three times**
  in this repo by people who knew about it.

---

## 7. Working conventions

**Build and test**
```bash
forge build
forge test                      # everything
forge test --match-path "test/queue/*"
forge test --match-test testName -vvv
```

**Commits.** Small, focused, and honest in the message. State what was proven, not what was attempted.
If a commit leaves something broken or unproven, say so in the message.

**Progress.** Update `PROGRESS.md` at the end of every working session — phase, status, what was
proven, what failed, decisions taken, open questions. This file is the memory. Chat is not.

**Handoff.** The next agent starts from `AGENTS.md` → `PLAN.md` → `PROGRESS.md`. If those three do
not tell them what to do next, the handoff has failed.

---

## 8. What "done" looks like

The submission is judged on a published rubric: **30% Original Idea · 25% Unique Execution ·
20% Impact · 15% Functionality · 10% Presentation.** Binary gates apply — public repo, a real v4
hook, new code written during the window, tests **or** a working frontend, and a video under five
minutes with a human voice.

**Functionality is only 15%.** Do not gold-plate at the expense of the mechanism being legible and
correct. But 15% of nothing is nothing: a hook whose core arithmetic is wrong scores zero everywhere,
because the demo will not run.

Full criteria and the phase-by-phase definition of done are in `PLAN.md` §D.
