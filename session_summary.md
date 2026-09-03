Committed and clean. 2d2a26f, 34 files, 8,274 insertions.

Final state

forge test         →  248 passed, 0 failed, 1 skipped   (was 224 at session start)
mutation campaign  →  80 RED, 0 SURVIVED, 0 NO-COMPILE, 0 BAD-PATTERN
invariant campaign →  13/13 green at φ > 0, for the first time
tree               →  clean

Five defects found and fixed, all reachable through the public API:

┌─────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│     │                                                   defect                                                   │
├─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 1   │ The premium was inert on the pool we ship — 0 wei of token0 premium reached the roster, 0 of 4 accruals,   │
│     │ against an 18/18 control stranding 0%. Phase 7's headline feature did not exist in production              │
├─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 2   │ A seat standing with 1 wei claimed 100% of a 2.667e17 pot                                                  │
├─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 3   │ A single-token deposit minted zero liquidity, added no depth, collected the full premium                   │
├─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 4   │ The front could evacuate atomically for +267 bps, rank intact — and the premium made it more attractive    │
├─────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 5   │ The hold branch was a monotone ratchet                                                                     │
└─────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

Three of those were one fix. The fourth prices the dodge (~1.05 days of tenure) rather than preventing it — no rule can claw back a loss the attacker never took, and claiming otherwise would have been false. The hot path got cheaper: 152,947 against 162,766.

φ moved 8,500 → 7,900, and the old value was never measured — PROGRESS.md claimed the sweep was "checked in" when it didn't exist. That claim is retracted in place, so a reader can check.

On your question

Yes — there is a value proposition, and it's narrower and better evidenced than anything this project has claimed. QUEUE sells the front seat: costlessly re-anchoring at-the-money exposure no LP can buy otherwise, worth 30–758 points against an optimistically-modelled keeper bot. Seats 2–5 are the depth that buys the flow, not a ladder. No φ makes every seat beat an LP — the capital-weighted mean is the LP's return, to 1.4e-12.

And the one thing that decides it is not an engineering question: rank 1 accepts a below-LP return for that property. We measured what it costs to replicate (80–123%/yr). We did not measure what a buyer will pay. Hold rank 1 to the passive-LP bar and the φ window is empty at any value. That's in BUSINESS.md §0, the README banner, the deploy constant's docblock and the handoff — four places, because it's the sentence that matters most.

Left undone, written up rather than hidden

- The reference witness still doesn't model φecause half-built it turns every check green
  for the wrong reason. Its derived bound (0 laim ≤ k − 1) is solved and recorded, so thenext session starts cold with the hard part done.
- The invariant handler is premium-blind (PITFALLS 5.133), so "13/13 green" is not the coverage it looks like.
- MAX_SEATS = 32 against a budget that now pays for 27 — open, with the real number pinned in a test.
- Broadcast and video.

NEXT_SESSION_PROMPT.md is self-contained: the business case with the flows, the four proven-impossible directions so nobody re-opens them, the full technical stateps.



---

❯ SESSION HANDOFF — QUEUE, after Phase 11 (2026-09-03)

  **Read order: this file → `AGENTS.md` → `BUSINESS.md` → `PITFALLS.md` §5.175–5.182 → `PLAN.md` when
  you write code.**

  **This file is self-contained. You do not have the conversation that produced it and you do not need
  it.**

  ---

  ## 0. START HERE — VERIFY THE TREE YOURSELF, DO NOT TRUST THIS FILE

  ```bash
  git log --oneline -12                        # expect ~12 Phase 11 commits on top of 66a7568
  git status --porcelain                       # expect CLEAN
  ls .forge-snapshots/MUTATION_IN_PROGRESS     # MUST NOT EXIST
  forge test                                   # GET YOUR OWN NUMBER. Expect 316 / 0 / 1 skipped.
  wc -l docs/research/seat-economics/*.txt     # NO ZEROES. One of these was the empty git blob.
  ```

  **That last line is not paranoia.** `results-book.txt` — the evidence for the result that closed the
  project's last open question — was committed at **zero bytes** and stayed that way for a phase,
  because `book_report.py` truncates its own output before it computes. `git status` reads CLEAN with
  the headline evidence gone. Check the sizes, not the status.

  **Stop your agents before you run `forge` or `mutate.py`.** A prior phase relayed a mutation result
  measured against the wrong suite because the orchestrator took the toolchain while a teammate held
  the tree.

  ---

  ## 1. WHAT THIS PROJECT IS, IN FIVE LINES

  * **QUEUE is a Uniswap v4 hook.** It gives the LPs funding one position a **rank** and fills them in
    order, front first, instead of pro-rata.
  * **Being first is bad** — the front seat absorbs adverse selection first, at the worst prices. That
    is measured, and it is the entire product.
  * So QUEUE is **subordination for Uniswap liquidity**: one LP takes structurally worse fills so
    another gets structurally better ones, enforced inside `swap`.
  * The application we lead with is **emissions-free liquidity incentives**: a protocol stands at the
    front with its own capital instead of printing tokens.
  * **It is a transfer, not creation.** `Σ cᵢrᵢ = LP` as an identity. We say that first, not last.

  **`BUSINESS.md` was fully rewritten on 2026-09-03 and is the business document.** It has the ASCII
  flows, the worked dollar example, what the hook demonstrates beat by beat, and every limitation. Read
  it before writing a word of pitch material. The pre-Phase-11 version is at
  `archive/2026-09-03/BUSINESS-pre-phase-11.md` and is **superseded, not a second opinion**.

  ---

  ## 2. THE STATE OF THE BUILD


  ──── (268 lines hidden) ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  nds as needed until you figure what and how we have to do to make this work with solid proff and nhis should be solid work.

  our last session is seeking the value proposition, have we found it yet ? do we have the clear buisness case that the hook provdes valu and seems interesting to particpate in from all LPs standpoint and what position 1 gains if not $ and how do they monetize what they gain. do we have to prvoe any of it. we will not stop untill we find the valu epropsoition and it should be worthy and clean. even if this means innovation. no half ass shit, no bandaid

  i want you to clearly exaplin in business language always your entire output in this session so that management could understad with not much technical specifics and in conscie way, ideally in the form of ascii flows with examples and summaries and bullet points.


  when you have some checks or implementation that could be outsourced to cmux subagetns - do so to preserve context and keep the leading postion. be carefull and keep everythign under control - do not waste tokens unless needed.

  i propoer we work with business.md as a majro business doc and then README should really haeve all the high levels and also some ascii flows with examples, all parameters expalined, why do we have only 5 seats, is it realistic, what have we tested and what were the results and why. we should demonstrate in the readme how to start and run the project, how to potentially integrate if applicable. what exactly is delivered. prefere summaires, busiens management language and summariues with ascii flows.

  as a side question i want to ask you review the entire hook once we are done, i see it is like 300rythign makes sense. i see most hooks for the UHI have abeen like 300 rows and then some importedfiles, making all at around 1000 rows, why is this hook so long, are there specifci aspects that n readme.

  what we display on the pforntend should also be re-checked and updated, after so many changes everything line by line ahs to be checkedm but this is  a task for th eend of the session when we are done with evertyhing.
  once we are fully done we will deploy - have to check if we are ready, if we hav the scripts correctly and then we can deploy together and update the address in the readme. I prefer to not have much detiales in text form but rather fill in existing docs so that the data eprssts sessions and agents. are you clear ?