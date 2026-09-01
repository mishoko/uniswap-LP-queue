# NEXT SESSION — start here

Read `AGENTS.md` → `PLAN.md` → `PROGRESS.md` (top entry) → `PITFALLS.md` (§5.92–5.102 are new). This
file tells you what to do; those tell you why.

**State: `forge test` → 199 passed, 0 failed, 1 skipped. `forge lint src/` clean. Nothing is broken.**

---

## 1. The one rule that cost this session two hours

**`src/` IS READ-ONLY WHILE `script/mutate.py` RUNS — INCLUDING FOR YOU.** The 5.86 interlock stops a
concurrent `forge test`. It does **nothing** about a concurrent *write*: the campaign restores the
original file in a `finally`, so every edit made while it runs is silently reverted. It ate ~200 lines
and the only symptom was a compiler error pointing at the caller of a function that no longer existed.
Either wait for it, or fix `mutate.py` to checksum its backup and refuse to restore over a changed
file (PITFALLS 5.100 — worth doing, ~10 lines).

---

## 2. What is actually left, in priority order

### PRIORITY 1 — the submission gates. Neither is optional and neither is code.

1. **Broadcast to Unichain Sepolia.** Needs a funded key. Everything it will do is already asserted
   against a fork of that chain (`QUEUE_FORK=true forge test`), so the risk is operational, not
   technical. One command, in the README. **There is no deployed address anywhere yet**, which means
   `frontend/index.html`'s header pill can never leave `SIMULATED` and its `hookAddr` box has nothing
   to paste.
2. **The video, under five minutes, human voice.** The shot plan already exists. The demo is the
   0:00–0:30 shot: open `frontend/index.html`, drag the swap-size slider, watch the front bar empty
   while the others do not.

Functionality is 15% of the rubric and the hook is done. **Presentation is 10% and is currently zero.**

### PRIORITY 2 — `recenter()` v2. Unit-green, campaign-red, cause unlocated.

Everything is in **`docs/wip/recenter-v2/`**: the implementation, its eight passing tests, the
bisection evidence and three ranked suspects. Do not start from scratch — the three v1 defects are
genuinely fixed and the fixes are believed correct.

**The bisection method is what to repeat** (one 40-second run per hypothesis): reduce the invariant
handler's selector set to two or three actions. `swap`+`recenter` is GREEN; adding either path that
**deploys float into the position** (`addToSeat`, `sweepFloatIntoPosition`) turns it RED.

**The lead:** a v2 band sits *beside* spot and never contains it, so the pool has **zero active
liquidity at the current tick** — a state the rest of the contract has never operated in, and one
where a deposit can only be absorbed on one side.

Note `_solvent`'s over-backing branch is deliberately still `require(backing == owed)`. It is an
*asymmetry*, not a stronger claim (PITFALLS 5.102); if you ship a band move you must apply the same
bound to both signs — and be aware that doing so is what let the campaign find the large divergences,
so a strict assertion had been hiding a bigger defect behind a smaller one.

### PRIORITY 3 — the product. This is the one that decides whether it is worth anything.

The economics are now settled and written up in `BUSINESS.md` §0.5 and the matching demo section.
**Read §0.5 before touching the pitch.** The short version:

- QUEUE is the first AMM position where capital can choose *which half of the flow it takes*
  (retail +32.85%/yr, arbitrage −21.90%/yr, and an ordinary LP dollar must take both).
- The **head** buys the retail flow and is a strong instrument. The **tail** declines the arbitrage
  flow and beats a wallet always, an ordinary LP only when the pool loses more to arbitrageurs than
  ~89% of its fee income. The **middle of the book is a trap that loses under every condition** —
  it takes all the toxicity and none of the fees.
- Therefore: **two products, not 32 seats.** Size the head to the largest routine *arbitrage* trade
  and no middle seat exists. Equal seats are the mistake.

**The single highest-value unbuilt thing is MARGINAL PRICING.** Today `Allocation.init(amtIn, amtOut)`
gives every seat a trade reaches that trade's *average* price, so the tail gets no price advantage —
only the option to sit out. Credit each seat the **segment of the trade it actually absorbed** and the
tail systematically fills nearer the post-move price, which is strictly better for an LP in both
directions. That is what turns the tail from "idle capital collecting a small coupon" into a genuine
senior tranche. **It is a different allocator, not a parameter.** Scope it before building it.

Second: **τ is 10% and is set against every seat but the front.** θ = τ/(τ+k) = 29% of the head's
advantage moves backward; τ = 25–50% gets 51–81%. It is already a constructor argument, so this is a
deployment decision, not a code change — but nothing has tested the mechanism's behaviour at those
values.

---

## 3. Things that are true and that you should not re-derive

- **`BAND_HALF_WIDTH` is now a deployment parameter**, not a constant. It is the main economic dial:
  in-band life scales as `w²` while depth scales as `1/w`, so doubling the band quadruples the pool's
  life and only halves its depth. **The shipped ±10% is sized for a demo, not a deployment.**
- **The band never moves** (no `recenter()`), which is what makes `_beforeAddLiquidity`'s add-time
  disjointness test a *complete* guard rather than a snapshot of a moving target. The honest cost is
  that a QUEUE LP cannot re-mint around the price the way every ordinary v4 LP can: it is a
  **rolling fixed-term instrument**, ~16 days of in-band life on a 45%-vol pair.
- **Gas is re-measured on the production band.** Head-only 128,625 vs 87,039 hookless = **+48%**,
  flat in roster depth. Full 32-seat sweep is **764,200**, not the 426,470 this project published —
  the old figure came from a fixture where the "sweep" could not actually reach the back of the book.
- **A green mutation campaign is not evidence of correctness** (PITFALLS 5.92). It ran 74/74 RED while
  a panel reading the same source found four real defects that sailed straight through, because the
  mutations were written against the same mental model as the tests. Attack the code, not the suite.

## 4. Do not

- Do not claim the tail is "paid to wait" without showing the coverage ratio (rent covers ~30% of the
  fee income it forgoes; the demo's own example is **8.6 bps/yr**).
- Do not write that a pro-rata LP "holds a slice of the poisoned middle." **It does not** — the depth
  coordinate is *created* by front-first ordering, not revealed by it, and a microstructure reader
  will catch it.
- Do not use `extra P&L / τ` as a fair-ask rule. It is the zero-discount-rate limit and overstates by
  3.4×. The correct form is `A/(τ + k)`.
- Do not re-add a `recenter()` without the invariant campaign green.
