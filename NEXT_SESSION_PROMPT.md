# NEXT SESSION — start here

Read `AGENTS.md` → `PLAN.md` → `PROGRESS.md` (top entry) → `PITFALLS.md` (§5.103–5.111 are new).
This file tells you what to do; those tell you why.

**State: `forge test` → 205 passed, 0 failed, 1 skipped. `forge lint src/` clean. Full mutation
campaign 79 RED, 0 survivors, 0 NO-COMPILE, 0 BAD-PATTERN. Nothing is broken.**

---

## 0. Two things that will bite you, and one that no longer will

* **`BAD-PATTERN` in a mutation summary is a FAILURE, not a status.** It means that mutation matched
  nothing and tested nothing, while the line everybody quotes still reads "0 SURVIVED". If you edit
  a line a mutation targets, re-run that mutation in the same commit (PITFALLS 5.111).
* **Do not run `forge test` while `script/mutate.py` is running.** The 5.86 interlock will stop you
  with a loud message; that is the marker doing its job, not a bug.
* **`src/` is no longer silently clobbered by a background campaign.** `mutate.py` now tracks what
  it wrote and REFUSES to restore over anything else, saving the original to `<file>.mutate-backup`
  and telling you what to check. It also refuses to run on an unknown flag — `--help` used to launch
  the full campaign. You still should not edit `src/` during a run, but a mistake is now loud
  (PITFALLS 5.100, CLOSED).

---

## 1. What is actually left, in priority order

### PRIORITY 1 — the two submission gates. Neither is optional and neither is code.

1. **Broadcast to Unichain Sepolia.** Needs a funded key. Everything it will do is already asserted
   against a fork of that chain (`QUEUE_FORK=true forge test`), so the risk is operational, not
   technical. One command, in the README. **There is no deployed address anywhere yet**, which means
   `frontend/index.html`'s header pill can never leave `SIMULATED` and its `hookAddr` box has
   nothing to paste.
2. **The video, under five minutes, human voice.** The shot plan already exists.

   **The demo now has a much better opening shot than the one the old plan describes.** Open
   `frontend/index.html`, drag the swap-size slider, and watch the **Fill price** column: rank 0
   fills *worse* than the swap's own average and the seats behind it fill *better*, in basis points,
   live. That is the whole mechanism in one column — "being first means being filled at the stalest
   price" — and it is the thing that makes QUEUE a market rather than a subsidy. Lead with it.

**Functionality is 15% of the rubric and the hook is done. Presentation is 10% and is still zero.**

### PRIORITY 2 — τ. A deployment decision, not a code change, and it is currently indefensible.

`script/QueueDeployBase.sol` ships `RENT_BPS = 1_000` — τ = 10%/yr. Simulated, that gives the tail a
**6.4%/yr coupon** against a head earning six figures. 25–50% gives 10.7–13.8%. τ is already a
constructor argument, so this costs nothing to change — **but nothing has ever been tested at those
values**, and `Rent.MAX_BPS` caps it at one whole period. Before changing it: run the Harberger
suite at 2_500 and 5_000 and see what moves. This is the cheapest available improvement to the
product and it is sitting behind a constant.

### PRIORITY 3 — `recenter()` v2. Unit-green, campaign-red, cause unlocated.

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
bound to both signs — and be aware that doing so is what let the campaign find the large
divergences, so a strict assertion had been hiding a bigger defect behind a smaller one.

**One new thing to check first:** `recenter()` moves `(tickLower, tickUpper)`, and the price curve is
anchored at the band via `_bandEntry`. Any band move must keep the replay and the pricing reading
the same band — that is why they share one function now (5.109).

---

## 2. Things that are true and that you should not re-derive

* **Each seat is credited the PRICE SEGMENT it absorbed, not the swap average.** The head fills worse
  than the swap's own average and the tail better, in both directions, by ~400 bps across the book
  in the test fixture. Asserted in `test/queue/Marginal.t.sol`; N6 in `Controls.t.sol` restores
  average pricing and the suite goes red at swap 2 on the seat ledger.
* **This closed a free lane, and that is why it was worth the gas.** Under average pricing the head
  beat an ordinary pro-rata LP in benign, normal AND toxic regimes. It now loses in toxic. Total
  return is unchanged to the wei — value moved, none was created. `docs/research/seat-economics/`.
* **Exactness does not depend on the curve.** `give` is the difference of two cumulative allocations,
  so it telescopes; `testFuzz_curvePricingNeverLosesAWei` fuzzes arbitrary monotone curves.
* **Marginal pricing is free on the path that matters.** Head-only swap 128,625 → **128,848**
  (+223), because the curve is built lazily and a one-claimant fill never builds one. A multi-seat
  walk costs **9,945/seat**, up from 8,070.
* **The gas budget is 400,000 now, deliberately.** `MAX_SEATS = 32` is the 32 bytes of the packed
  `order` word, not a gas choice, so the budget moved rather than the roster. The constraint that
  actually binds is `test_5_3c`: a full cold 32-seat sweep at **826,799** against an 850,000 ceiling.
* **`BAND_HALF_WIDTH` is a deployment parameter.** In-band life scales as `w²` while depth scales as
  `1/w`, so doubling the band quadruples the pool's life and only halves its depth. The shipped
  ±10% is sized for a demo, not a deployment.
* **The band never moves**, which is what makes `_beforeAddLiquidity`'s add-time disjointness test a
  *complete* guard. The honest cost is that a QUEUE LP cannot re-mint around the price: it is a
  **rolling fixed-term instrument**, ~18 days of in-band life on a 45%-vol pair.
* **A green mutation campaign is not evidence of correctness** (PITFALLS 5.92). It ran 74/74 RED
  while a panel reading the same source found four real defects. It has now happened again in a
  different shape: 199 tests, 74 mutations and the invariant campaign were all green over a pricing
  rule that handed the head a subsidy, because **average pricing conserves perfectly**. Conservation
  cannot see who got the money. Attack the code, not the suite.

---

## 3. The product, stated honestly — read this before touching the pitch

`BUSINESS.md` §0.5 was rewritten this session against a mechanism-faithful simulation. The short
version, and it is less comfortable than the old one:

> **QUEUE redistributes one Uniswap position's return. It does not create return.** Against its own
> pro-rata benchmark the book is zero-sum, so **there is no configuration in which all 32 seats beat
> an ordinary LP, and there cannot be one.**

* **Seat 1** — equity-like. Enormous in benign and normal, genuinely loses in toxic now that the
  free lane is shut. A real position with a real risk.
* **Seats 5–20** — lose under **every** condition (−8% benign, −77% normal, −1267% toxic). Reached
  often enough to absorb the large toxic trades, not often enough to earn the small profitable ones.
  Marginal pricing improves them and they stay negative.
* **Seat 32** — ~0%, and that is **not a coupon, it is capital the flow never reached**. Still a win
  where an ordinary LP returns −31.8%. Bond-like, and should be sold as one.
* **Two products, not 32.** Sizing the head compresses the middle (worst of seats 2–21: −109.6% →
  −49.9%) while collapsing the head from +566% to −38%. They are the same money. Seat capital is
  chosen by holders, so **the contract already supports this and no code change follows** — but the
  demo's default of 32 equal seats is the configuration that manufactures the trap.

---

## 4. Do not

* Do not say a seat is credited "the swap's average price". That was the old design and it was the
  head's free lane. Six places in `PLAN.md` said it and were corrected on 2026-09-01.
* Do not claim the tail is "paid to wait" without showing the coverage ratio — at the shipped
  τ = 10% the coupon is **6.4%/yr**, and the tail's real protection is *not being reached*, not
  being paid.
* Do not write that a pro-rata LP "holds a slice of the poisoned middle". **It does not** — the depth
  coordinate is *created* by front-first ordering, not revealed by it, and a microstructure reader
  will catch it.
* Do not use `extra P&L / τ` as a fair-ask rule. It is the zero-discount-rate limit and overstates by
  3.4×. The correct form is `A/(τ + k)`.
* Do not re-add a `recenter()` without the invariant campaign green.
* Do not add a mutation for `_initCurve`'s `room == 0` guard. It is believed unreachable and written
  down as such (PITFALLS 5.110, §3b's third honest answer); a mutation there would survive by
  construction and break the zero-survivor gate for no information.
