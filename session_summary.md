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