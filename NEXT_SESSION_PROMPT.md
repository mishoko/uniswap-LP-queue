# NEXT SESSION — build rotation. Everything you need is here.

Read this file first, then `AGENTS.md` → `docs/research/seat-economics/ROTATION.md` → `PLAN.md` →
`PROGRESS.md` (top entry) → `PITFALLS.md` (§5.103–5.112 are new).

**State: `forge test` → 205 passed, 0 failed, 1 skipped. `forge lint src/` clean. Full mutation
campaign 79 RED, 0 survivors, 0 NO-COMPILE, 0 BAD-PATTERN. Nothing is broken. The hook works. Its
ECONOMICS do not, and that is the whole job.**

---

## 1. The problem you are solving, in one table

Per-seat return, %/yr while in band, mechanism-faithful simulation, 30 price paths, shipped ±10%
band, PERMANENT rank (what the contract does today):

```
                BENIGN     NORMAL
  pool          +19.5%     -18.6%
  seat 1       +911.8%    +576.0%
  worst seat    -20.5%     -90.8%
  seats < 0      29/32      28/32
```

**29 of 32 positions lose money.** A product where 28 of 32 positions are unbuyable is not a
product. That is the finding that triggered this work, and the owner is right that it cannot ship.

## 2. The constraint you cannot design around — it is PROVEN, not argued

Front-first ordering vs ONE undivided pro-rata LP, same capital, same flow, same seeds:

```
  BENIGN  volume  queue $ 24.5M  pro-rata $ 24.5M   diff +0.0000%
  BENIGN  P&L     queue +4.79%   pro-rata +4.79%    diff +0.0000 pts
  NORMAL  volume  queue $ 10.9M  pro-rata $ 10.9M   diff +0.0000%
  NORMAL  P&L     queue +0.55%   pro-rata +0.55%    diff +0.0000 pts
```

Zero to four decimal places. **QUEUE redistributes one Uniswap position's return and cannot create
any.** So no ordering scheme makes all 32 seats *beat* a pro-rata LP. The best achievable is all 32
*equal* to it. Do not go looking for a scheme that beats it; the search is closed.

(The inventory-recycling hypothesis — that front-first serves more volume per dollar because the
head is emptied and refilled by reversing flow — is dead. Availability is identical: the cursor only
advances past EMPTY seats, so the inventory reachable behind it never changes.)

## 3. The decision

**Ship deterministic time-rotation of rank.**

```
rank(seat i) = (i + floor((block.timestamp - genesis) / EPOCH)) mod N
```

A pure function of time. No stored rotation, no transaction, no keeper, no randomness, no oracle,
zero storage cost for the rotation itself. Over one cycle every seat occupies every rank once.

Measured, ±10% band, BENIGN pool (+19.5%): static gives a 932-point spread with 29/32 negative;
**rotation gives a 13–18 point spread with 0/32 negative.** Per-seat mean equals the pro-rata
benchmark exactly, which is what conservation demands.

**Round-robin, NOT random, and this is not a preference.** On-chain randomness is a block hash, a
block hash is chosen by whoever builds the block, and a head slot worth several hundred percent a
year is worth grinding for. A VRF is an external dependency (AGENTS.md §6 — ask first). Round-robin
is unmanipulable, costs nothing, and equalises *exactly* rather than in expectation.

### Three things that come with it

1. **The cycle must complete inside the band's life.** At 24h epochs a 32-seat cycle is 32 days; the
   ±10% band on a 45%-vol pair lives ~18. The cycle never completes and rotation cannot equalise.
   **Epochs are hours, not days.** 4h → 5.3-day cycle. 1h and 4h perform the same; prefer 4h.
2. **BAND WIDTH MATTERS MORE THAN THE QUEUE DOES.** This is the most important number in the file:

   ```
         band    vol   exited      pool     worst      best   seats<0
        +-10%   0.45    30/30    -18.6%    -47.8%    +23.6%     24/32
        +-30%   0.45    27/30    +14.9%     +2.8%    +27.7%      0/32
   ```

   A ±10% band on a 45%-vol pair is a losing LP position **whatever the hook does** — it dies in ~18
   days and the terminal traversal is one lumpy loss landing on whoever is at the front. Rotation
   equalises the *flow* and cannot equalise a single terminal event. `BAND_HALF_WIDTH` is already a
   constructor argument; the shipped 960 ticks was sized for a demo. **Size it to the pair.**
3. **Lock-weighted priority is the differentiator, and it is a DIAL, not the default.** Head-time
   share proportional to committed lock length. Shipping config (±30%, 4h, tiers 4:3:2:1):

   ```
     BENIGN  pool +32.8%   lock4 +56.1%  lock3 +40.0%  lock2 +24.7%  lock1 +10.5%   negative  0/32
     NORMAL  pool +14.9%   lock4 +31.5%  lock3 +23.8%  lock2  +8.1%  lock1  -3.8%   negative  6/32
   ```

   A monotone duration curve; tier mean equals the pool return, so the split is still conserved —
   **only its AXIS changed, from "which seat number you bought" to "how long you commit".** This is
   what the pitch is: *pay for sticky liquidity with fill priority instead of token emissions.*
   Uniswap cannot price how long you will stay; this can.

   **Ship uniform as the default** (all weights equal reduces exactly to uniform) so the 0/32
   guarantee holds out of the box, and make weighting opt-in. Note the honest cost: lock-weighting
   re-introduces a below-average tier (`lock1` −3.8% in NORMAL where uniform had nobody negative),
   and **front-time is leverage on the pool's own outcome** — the curve inverts in a losing pool.

Evidence, both models, all tables and the reproduction scripts: **`docs/research/seat-economics/`**
(`ROTATION.md` is the decision, `report_rotation.py` regenerates every number).

---

## 4. Implementation plan — in this order, and validate the riskiest thing FIRST

**The riskiest assumption is not the economics (simulated) — it is that CURSORS SURVIVE ROTATION.**
Test that before writing anything else.

### Step 0 — the cursor question, before any other code

`cursor0`/`cursor1` are **RANKS**, and INVARIANT C says every seat at rank < cursorX holds
`aX == 0`. If the rank→seat map rotates under them, that is violated immediately and a cursor can
**LEAD a funded seat, which is silent theft of rank** — the exact defect N2 and N4 exist to catch.

Proposed fix, **UNVERIFIED, prove or refute it first**: store `lastEpoch`; on the first swap of a
new epoch reset both cursors to 0. A lagging cursor costs gas but never money, so 0 is always safe.
One SSTORE per epoch, not per swap. Cases to check explicitly:
- a swap that straddles an epoch boundary (`beforeSwap` in one epoch, `afterSwap` in the next);
- two swaps in the same block either side of a boundary;
- the `amtOut == 0` degenerate-fill path, which also writes cursors (`_afterSwap` Step 2c);
- foreclosure, which permutes `order` and pulls cursors back — does it compose with a derived rank?

### Step 1 — rank derivation composed with `order`

Keep the packed `order` word as the BASE permutation (foreclosure still mutates it) and compose the
epoch offset on top: effective rank = `_idAt(order, (i + epoch) mod n)`. Verify it composes with
`buySeat`, `transfer`, and demotion.

### Step 2 — the lock, on EVERY path

Capital must not be able to leave before one full cycle, or a holder deposits before their turn and
withdraws after — which captures head-time without bearing tail-time and is fatal.

**Enumerate every path that moves capital OR rank before writing the check.** At minimum:
`withdraw`, `buySeat` (a Harberger buyout evacuates the SELLER's capital), `transfer` AND
`transferFrom` **separately**, foreclosure/demotion, and any pending-withdrawal path.

> A rule implemented in one of two paired paths is this project's single most repeated bug —
> PITFALLS 5.37, 5.50, 5.52 (twice) and 5.105 this week. Removing the ownership check from
> `transfer` alone once survived all 71 tests. **Mutate each path separately.**

Also decide what happens when the band dies while capital is locked — a lock with no exit is a DoS,
and an exit that is too easy is the JIT attack back again.

### Step 3 — does Harberger survive?

With rotation every seat has an identical schedule, so "the seats behind you" changes every epoch
and **rent looks like a wash over a cycle**. But something must still force an IDLE seat to be
reallocated: an empty seat holds one of 32 slots for free, and the allocator simply skips it. Decide
the minimal mechanism that does that, and delete whatever no longer earns its place. This is a
design decision that changes the economics — **ask the owner before deleting the lease** (AGENTS.md
§4). 47 of the 205 tests are Harberger's.

### Step 4 — timestamp safety

Rank derived from `block.timestamp` on an OP-stack chain. Quantify the sequencer drift that is
possible and what one epoch of drift buys a seat holder. If it is material, derive the epoch from
block number instead and state the chain-portability cost.

### Step 5 — the tests that must exist before you believe any of it

- **A negative control that deletes rotation** (rank stays static) and asserts the EXACT revert
  reason. Bare `vm.expectRevert()` is not acceptable — v4 wraps a hook's own error in
  `CustomRevert.WrappedError`, which is how two LAW 2 violations survived six phases (5.83, 5.84).
- **A property test that every seat occupies every rank exactly once per cycle**, asserted on the
  contract's own view, not on the fixture's expectation.
- **An invariant-campaign run**, not just unit tests. `recenter()` v2 was unit-green and
  campaign-red and that is why it never shipped.
- **Mutate the cursor reset, the epoch derivation, and each lock enforcement point separately.**

---

## 5. Things that are true and that you should not re-derive

* **Each seat is credited the PRICE SEGMENT it absorbed, not the swap average.** Shipped this
  session. The head fills worse than the swap's own average and the tail better, ~400 bps across the
  book in the fixture. `test/queue/Marginal.t.sol`; N6 in `Controls.t.sol` restores average pricing
  and the suite goes red at swap 2. This closed a **free lane**: under average pricing the head beat
  an ordinary LP in benign, normal AND toxic. **Rotation does not replace it** — it still decides
  who bears the stale end of each move, and rotation only decides who stands there.
* **Marginal pricing is free on the path that matters**: head-only swap 128,625 → **128,848**
  (+223), because the curve is built lazily. A multi-seat walk costs **9,945/seat**.
* **The gas budget is 400,000, deliberately.** `MAX_SEATS = 32` is the 32 bytes of the packed
  `order` word, not a gas choice, so the budget moved rather than the roster. The binding constraint
  is `test_5_3c`: a full cold 32-seat sweep at **826,799** against an 850,000 ceiling.
* **`_bandEntry` is the SINGLE definition of where a swap meets the band**, used by both the in-band
  replay and the price curve. They were separate for one commit; that divergence would have been
  silent, because `wTotal` normalises the total away (5.109). Keep it single.
* **`BAD-PATTERN` in a mutation summary is a FAILURE, not a status** (5.111). If you edit a line a
  mutation targets, re-run that mutation in the same commit.
* **`mutate.py` now refuses to restore over a file it did not write** and refuses to run on an
  unknown flag (`--help` used to launch the full campaign). `src/` is still read-only during a run,
  but a mistake is now loud (5.100, CLOSED).
* **A green mutation campaign is not evidence of correctness** (5.92). 199 tests, 74 mutations and
  the invariant campaign were all green over a pricing rule that handed the head a subsidy, because
  **average pricing conserves perfectly**. Conservation cannot see who got the money.

## 6. Still outstanding, and both are submission gates

1. **Broadcast to Unichain Sepolia.** Needs a funded key. Already fork-asserted
   (`QUEUE_FORK=true forge test`), so the risk is operational. **There is no deployed address
   anywhere yet.**
2. **The video, under five minutes, human voice.** The demo's **Fill price** column is the opening
   shot: drag the swap-size slider and watch rank 0 fill worse than the swap average while the seats
   behind it fill better, live, in basis points.

`recenter()` v2 remains unshipped and campaign-red (`docs/wip/recenter-v2/`). Note it interacts with
rotation: it moves the band, and the price curve is anchored to the band via `_bandEntry`.

## 7. Do not

* Do not look for a scheme that makes all 32 seats **beat** a pro-rata LP. Proven impossible
  (+0.0000% total difference). All 32 **equal** to it is the ceiling, and rotation reaches it.
* Do not use randomness for the rotation. It is a block hash and the builder chooses it.
* Do not say a seat is credited "the swap's average price". That was the old design and it was the
  head's free lane.
* Do not claim the tail is "paid to wait" — at τ = 10% the coupon is 6.4%/yr, and under rotation
  rent is close to a wash anyway.
* Do not ship lock-weighting as the default. Uniform is what carries the 0/32 guarantee.
* Do not add a mutation for `_initCurve`'s `room == 0` guard — believed unreachable and written down
  as such (5.110); it would survive by construction and break the zero-survivor gate.
* Do not re-add `recenter()` without the invariant campaign green.

## 8. One honest note about how this decision was reached

The economics here are **SIMULATED, not measured on a live pool**, and there is no live pool to
measure. The simulator reproduces the contract's own mechanism (constant-liquidity band, seats
holding `(a0,a1)`, front-first drain from a cursor, marginal pricing, rank separated from ownership)
and every table is reproducible from `docs/research/seat-economics/`. Two modelling errors were
found and fixed inside it — an arbitrageur sliced into $2k trades erases the price impact that
distinguishes the front of the book from the back, and clamping the price walk inside the band
produces a pool with almost no LVR — so treat the simulator as evidence that has already been wrong
twice and check it before trusting a new number from it.

A four-agent adversarial panel (economic incentives, exploit development, devil's advocate, first
principles) was commissioned to attack this design and **did not return findings before the session
ended**. The review lenses in AGENTS.md §5 were applied directly instead, which is how the duplicated
`_bandEntry` rule and the `room == 0` constant-curve defect were caught this session — but **the
rotation design has NOT had an independent adversarial pass, and Step 0's cursor fix in particular
is unverified.** Commission that panel again before writing production code.
