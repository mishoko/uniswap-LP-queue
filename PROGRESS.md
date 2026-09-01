# PROGRESS.md — the project's memory

**Update this at the end of every working session. This file, `PLAN.md` and `AGENTS.md` are the
handoff. If those three do not tell the next person what to do, the handoff failed.**

Newest entry first. Never delete an entry — supersede it.

---

## Status board

| Phase | Name | Status | Proven? |
|---|---|---|---|
| 0 | Harness + reproduce the reference spike | **COMPLETE 2026-08-27** | **YES** — 9/9, every §D.2 number exact, +2 fresh mutations red |
| 1 | Allocator core | **COMPLETE 2026-08-27** | **YES** — 27 tests, all 12 exit criteria met, 9 production mutations red |
| 2 | Deposit / withdraw + redemption-dust fix | **COMPLETE 2026-08-27** | **YES** — 59 tests, all §D.4 criteria, 11 Phase 2 mutations red, 0 survivors |
| 3 | ERC-6909 rank token + transfer | **COMPLETE 2026-08-27** | **YES** — 77 tests, all 10 §D.5 criteria plus 2 added, 29 Phase 3 mutations red, 0 survivors |
| 4 | Harberger rent variant ◀ **SUBMITTABLE** | **COMPLETE 2026-08-27** | **YES** — 125 tests, all 10 §D.6 criteria plus 16 added, **53 mutations red, 0 survivors** |
| 5 | Gas + scale | **COMPLETE 2026-08-28** | **YES** — 135 tests, all 6 §D.7 criteria, **61 mutations red, 0 survivors**. The O(1) redesign is **NOT SHIPPED** (§B.11) |
| 6 | Adversarial + invariant campaign | **COMPLETE 2026-08-28** | **YES** — 163 tests, all 5 §D.8 criteria, **66 mutations red, 0 survivors**. **FOUND AND FIXED THREE REAL BUGS** (PITFALLS 5.73, 5.74, 5.76/5.77) |
| 7 | Testnet deploy + demo + video | **IN PROGRESS 2026-08-31** | **PARTLY** — 171 tests. Wings shipped: overlap refused, disjoint LP allowed, crossing clip proven, M70/M71 RED. **Broadcast and video still outstanding.** |

*(Phase definitions, entry/exit criteria and acceptance tests are in `PLAN.md` §C and §D.)*

---

## 2026-08-31f — Recenter + PositionManager wings

`recenter()`: permissionless, burns the old band, snaps ±10% around spot, remints from float. Seat ledger unchanged. Reverts `BandStillInRange` if still in, `DestinationOccupied` if the new ticks have L (a wing). Empty ticks: follows the price. `_burnPosition(0)` is a no-op (a zero poke reverts `CannotUpdateEmptyPosition`).

Wings mint/burn through the real `PositionManager`. Overlap still `OverlappingLiquidity`.

Invariant handler includes `recenter`. I1 ghost unchanged (no wing mints in that campaign — PM-delta ghost).

183 tests. M72/M73/M74 RED.

---

## 2026-08-31e — DMM on the touch, ordinary Uniswap in the wings

The 32-seat closed pool was the wrong object for a Uniswap submission. What a Uniswap team can use, integrate, or experiment on is: a paid queue **on the concentrated band**, and permissionless v4 LPs **in the disjoint wings**.

**What shipped**

- `_beforeAddLiquidity` allows `sender == this` or a range strictly disjoint of `[tickLower, tickUpper)`. Overlap reverts `OverlappingLiquidity`. Adjacent at a boundary is disjoint (Uniswap ranges are `[lower, upper)`).
- `_afterSwap` credits only the in-band fill. A swap that starts and ends inside the band is the identity (ticks, not `getSqrtPriceAtTick` — that was the gas). A swap that leaves or enters is one `SwapMath.computeSwapStep` over the overlap. The result is a **cap**: if the replay is not more than 1 wei tighter than PoolManager's delta, keep the delta. That 1 wei is SwapMath vs Pool.swap rounding (I1), not a wing fill.
- `test/queue/Wings.t.sol` — overlap same-range / partial / full-range RED by name; disjoint mint; small in-band swap does not move wing principal and `_check` still holds; crossing swap credits the band only and `redeemAll` covers the ledger; no-wings in-band is identity.
- M70 (skip the clip) RED. M71 (allow overlap) RED.
- Skeptic pass (2026-08-31f): crossing tests were inequality-only; now wei-equal to an independent SwapMath replay. Added reverse, re-entry, full traverse, exact-out, protocol-fee crossing, salt, overlap-from-above, already-outside. **Not claimed:** invariant+wings (ghost is whole-pool), PositionManager glue, band recenter after drift.
- Head-only gas is now **128,406 vs 86,820 = +48%**, still flat 1–32, still under the 50% ceiling. Sweep slope unchanged at 8,070/seat. 32-seat sweep 426,470.
- PITFALLS 3.4 SUPERSEDED by 3.14.

**What this is not.** 32 seats per tick. NFT-per-seat ranges. A full re-campaign of the pre-wings 69 mutations (not run this session; do not claim it).

**Suite:** see 2026-08-31f. Recenter + PositionManager wings shipped; M72/M73/M74 RED.

---

## 2026-08-31d — The shipping position is a Uniswap band, not the whole curve

**The v2a/v2b/v3 labels were a mistake.** What Uniswap engineers vibe with is not extra NFTs and not three bands. It is: Uniswap already orders by PRICE. QUEUE orders LPs *inside that price*. Same curve, same router, one concentrated position, 32 seats sharing it.

**What shipped:** `_afterInitialize` snaps a ±960-tick (~10%) band around the start price. `BAND_HALF_WIDTH` is a constant, not a constructor arg (that would have touched every encode site). Seats are still ERC-6909, not Uniswap NFTs, and they do not pick ranges.

**What caught us:** `_positionValue` in the fixture hardcoded `minUsableTick`/`maxUsableTick`, so INVARIANT F valued a concentrated L as if it were full-range (~20x too much token). The instrument, not the hook. PITFALLS 5.75 again. Both the fixture and the invariant handler now read `hook.pool()`.

**M69** (full-range again) is RED, 2 failing. `test_7_9` pins the band. `test_7_5` still walks the demo sweep — concentrating made the walk *more* visible, not less.

Tests written against a full-range blob (packing fuzz, the reentrancy control) restore that fixture via `QueueHarness.forceRange` BEFORE any mint. Production has no equivalent.

---

## 2026-08-31c — Spike: price-then-queue is an afterSwap walk, not a new AMM

**Status: 8/8 on `test/spike/PriceThenQueue.t.sol`. No production code. Queue suite untouched.**

The shipping hook is misaligned with Uniswap: it throws ticks away to get a queue. The Uniswap-shaped object is **price then queue**. The riskiest assumption was that `afterSwap`'s one `BalanceDelta` is enough to attribute a crossing swap to the bands the price actually walked.

**It holds.** `SwapMath.computeSwapStep` over a three-band ladder (below / at / above, non-overlapping, 1:4, 18/6, real PoolManager) matches PM net input and output **to the wei**. A small swap stays 100% in the middle band. A crossing zeroForOne credits below and not above; the other direction credits above and not below. There is no tick-crossing hook flag (14 named bits).

**Two mutants, both red, identical fixture:**
- Smear the aggregate by L: conservation holds, composition is a lie (untouched wing gets a share).
- Dump the whole fill on the middle band: `slot0` has left the band, mutant still reports the wing at 0.

**A false claim the spike caught in itself:** "concentrated is deeper per unit L." Same L is the same instantaneous depth. The 1/200th figure is same *tokens*, not same L. Replaced with `test_spike_sameLCostsMoreTokensAtFullRange`.

**What this is not:** 32 queues per tick; overlapping v3-style ranges; a shipping feature; protocol-fee-on; exact-out; a gas number.

**Build order, do not skip:** v2a concentrate the blob (`test_1_11`) → v2b 3-band ladder (this spike) reusing `Allocation.sol` → v3 arbitrary overlapping ranges (new spike required). Do not take over the swap with `beforeSwapReturnDelta`.

Verdict: `docs/research/price-then-queue/SPIKE.md`.

---

## 2026-08-31b — Pair-wide vs per-tick, one-sided seats, and a buy-in calculator

**Status: no production code changed.** Frontend gained a pay-vs-earn slider; README / BUSINESS.md gained the pair-wide and Uniswap-adoption answers.

Confirmed from the shipping hook, not from memory:

- **One queue for the whole pair.** One full-range position, `tickLower`/`tickUpper` set once to the usable range. Not per tick.
- **A seat can hold one token.** `addToSeat` allows a zero leg. In range, `_liquidityForAmounts` takes the min of the two legs, so a zero leg mints **0 L**; the tokens go to float. Rent weights **token0 only** — a token1-only seat earns nothing.
- **Per-tick / per-seat ranges is the Uniswap-shaped v2, and it is not a config change.** `afterSwap` is one `BalanceDelta`. 32 queues × ticks is not a program. Fastest real v2: concentrate the one blob (`test_1_11`).
- **The project is only the queue.** The buy-in was missing from the demo. `frontend/index.html` now has rank / liquidity / ask / small volume / sweep / two markouts, with Quiet / Event / Back / Under / Over presets, on the same $1M five-seat book. Labeled ESTIMATE. Rank 4 stands in for seat 32.
- **Sustainable liquidity, not MEV protection.** Claim the half we earn. Do not also claim sandwiches.

Do not treat the calculator as a measurement. It is the identities with a flow mix the viewer types in.

---

## 2026-08-31 — Pitch rewrite: the docs were written for Uniswap engineers, and that was a miss

**Status: no production code changed. README, BUSINESS.md, frontend copy, and PITFALLS §7 pointers. The 172-test / 68-mutation board is untouched.**

### Why this session existed

The owner asked, bluntly, whether QUEUE is well implemented and interesting *from the Uniswap Foundation / hackathon-judge chair*, and whether a business person who barely knows DeFi could tell: what a queue is, why 32, why not 100, whether +36% is 36% more expensive trades, whether 32 desks cancelling bricks the pool, and whether benefits outweigh. The existing README and BUSINESS.md already had the right *answers* and the wrong *audience*. A CFO hears "pro-rata" and "+36% gas" and files this as a cartel with a 36% tax. A Foundation engineer files it as "order book bolted onto an AMM" and stops listening. Both readings were invited by the prose.

### Verdict from the panel (exploit / economic / state / periphery / triager), not from the pitch

- **Accounting quality is Foundation-grade.** Wei-exact front-first fill, conservation against PoolManager, mutation-driven paired-path closures, three live bugs found after 135 tests. This is not an audit.
- **The object is a 32-desk specialist venue, not a Uniswap pool and not MEV protection.** Theme fit is the weakest joint (PITFALLS 5.16). Do not reuse the spike's 4.33. Honest rubric this session: Original ~4, Unique Execution ~4–4.5, **Impact ~2–2.5**, Functionality ~4, Presentation *was* ~2.5 and is the thing this session changed.
- **"+36%" is a constant venue tax on a typical (head-only) swap, flat 1→32 seats (21 units).** It is not 36% of the notional, not a trading fee, not a worse price. A full-line walk is a *different* number (416k). Quote both or you are lying.
- **"32 cancel and the pool dies" is a category error as a revert, and a real thin-book run as economics.** `withdraw` does not destroy the seat. Empty book: swap no-ops, then v4's own price-limit revert, not QUEUE. 32 desks *can* empty the position. The failure mode the pitch should actually fear: they post `selfPrice = 0`, rent stops, the tail's deal becomes irrational.
- **32 is packing + quadratic `addToSeat` (2.61M) + scarcity.** 100 or 500 is not a bigger QUEUE. It is a different, currently unexecutable program.
- **Benefits outweigh only** where professional desks want first fill without more capital *and* passive capital is actually paid rent. In a retail aggregator pool: no.

### What changed in the docs

- `README.md` rewritten as the 15-minute read: 90-second version, when-to-use table, NYSE-seat vs DMV-line, ASCII flows, +36% in dollars, mass-exit translation, pros/cons by role, fear table, architecture picture. Leads with business language. **Diverges from `PLAN.md` §A.3's "say the technical sentence first"** — recorded as PITFALLS 7.11, owner-directed, do not silently revert.
- `BUSINESS.md` rewritten as the decision memo. Verdict-first. Worked examples, 662-row novelty check, gas table, limitations kept and moved to §14. Native-ETH hole named (it was a comment lie). CFO 90-second script is §16.
- `frontend/index.html` copy only (selectors untouched): hero, +36% card, 32-seat limit, footer counts 172 / 68. Hygiene `test_7_6` is the interlock.
- `PITFALLS.md` §7.10 marked partly closed; line-number citations into BUSINESS.md replaced with section refs (they rot; 7.5 already said so).

### What this session did **not** do, on purpose

No production code. No video. No broadcast. No concentrated-range v2. No syndicate wrapper. No audit. The mechanism is what it was yesterday; the claim about who it is for is now the one the panel would actually defend.

**Where to look:** `README.md` first, then `BUSINESS.md` §0 and §2. If those two do not tell a non-engineer what to do, the rewrite failed.

---

## 2026-08-29 — Phase 7a: the deployment path had never run, and four of our own instruments were wrong

**Status: 172 tests green, 68 mutations with zero survivors, six deployment tests passing against a
live Unichain Sepolia fork. The broadcast and the video are outstanding.**

### The finding that mattered

**Six phases were green while not one line of the actual deployment sequence had ever executed.**
Every suite in this repo reaches the pool one of two ways: `QueueHarness.seed()`, which is TEST-ONLY
code, or `_deployHookUnfunded` → `deployCodeTo`, which *places* a hook at an address of your
choosing. Neither is how a v4 hook reaches a chain. The real path is: mine a CREATE2 salt whose
address carries the permission bits → deploy through the canonical deterministic proxy →
`PoolManager.initialize` → `addToSeat` into a virgin position. Its first execution would have been a
live broadcast with a judge watching.

Fixed **structurally**, not by adding a script. The sequence lives in `script/QueueDeployBase.sol`
and is executed by two callers — `script/DeployQueue.s.sol` broadcasts it, `test/queue/Deploy.t.sol`
runs the same functions and asserts every beat — and the only thing that differs is who signs, behind
`_as` / `_stopActing`. `DeployFork.t.sol` then runs the same five tests against a live fork, which is
what actually proves the vendored `AddressConstants` is not stale, the CREATE2 proxy is present on
that chain, and the numbers are identical. (PITFALLS 5.81.)

### Four instruments that were wrong, in the session's own order

1. **`PLAN.md` §H.3's hook flag mask was stale** — `0x0840` for a contract whose permissions are
   `0x18C0`, four phases after `afterInitialize` and `beforeAddLiquidity` were added. §F.2 of the
   same document already recorded `0x18C0`: **the plan disagreed with itself.** Mining for a stale
   mask yields an address `BaseHook`'s constructor rejects, with no diagnosis attached. Now derived
   from `Hooks.Permissions` and asserted against `getHookPermissions()` by `test_7_1`. (5.82.)
2. **`test_2_20` and `test_2_21` were LAW 2 violations**, and `test_2_21` was worse than that: it
   re-initialized the IDENTICAL key, which `PoolManager` refuses from its own state before the hook
   is ever called, so it passed **whether or not `_afterInitialize` had an `AlreadyBound` guard at
   all**. Demonstrated by deleting the guard and watching both tests stay green in their old form.
   Both now unwrap v4's `CustomRevert.WrappedError` and assert the selector; kept honest by the new
   **M67**. (5.83, 5.84.)
3. **The frontend's four hardcoded call selectors were three-quarters wrong.** Written from memory;
   only `ownerOf(uint256)` was right. The failure mode is the worst available — an `eth_call` to a
   selector that does not exist returns EMPTY DATA, so the page renders zeros and looks like a
   working demo of an empty queue. Closed the way every writer/reader pair here is closed:
   `test_7_6` reads the page, extracts the live `const` bindings, and asserts each against the
   compiler's own. (5.85.)
4. **PITFALLS 5.79's corollary was violated by the agent who had just read it.** `forge test` was
   run while `mutate.py` held a mutant on disk, and the result was briefly believed. A hazard that
   recurs after being documented needs an interlock, not a louder note: `mutate.py` now publishes
   `.forge-snapshots/MUTATION_IN_PROGRESS` and `test_7_7` refuses to run when it sees one, while the
   campaign's own runs pass through on `QUEUE_MUTATION_RUN=1`. Both directions have a control.
   (5.86.)

### Two wrong predictions, written down next to the right answers

- **"A 400e18 sweep will walk several seats."** It touched exactly one. The allocator was correct and
  the trade was small: the queue IS the pool's liquidity, so reaching rank 2 means removing ranks 0
  and 1's whole stock of the outgoing token from a FULL-RANGE position, and a constant-product curve
  releases 60% of a leg only for a 6.25x price move. 2,500e18 walks it. **This is the measured form
  of the README's "the back is reached only by trades large enough to sweep the front", and it is
  5.17 (thin full-range depth) showing up in the demo.** (5.87.)
- **"Settling rent reduces `escrowTotal`."** It does not — `_distributeRent` moves the money from the
  payer's escrow to the recipients' escrow, so the total is CONSERVED, exactly as `AGENTS.md` says
  ("rent moves escrow to escrow"). The draft assertion would have passed against a *leaking*
  implementation. Replaced with the identity: payer falls by `due`, the seats behind rise by `due` in
  total, `escrowTotal` unchanged, `unallocatedRent0` zero while eligible recipients exist — which is
  also the business model stated as an assertion. (5.88, and 5.53 again.)

### Decisions taken under ambiguity

- **Built a frontend, against `PLAN.md` §H.4's "do not build a frontend just in case."** That
  guidance was written when the mechanism was unproven and a frontend would have been a distraction.
  The mechanism is now proven and the remaining score sits almost entirely in what a judge can see.
  It is one static file, read-only, no build step and no server — so it is a *viewer*, not an
  off-chain component, and §6.1 is untouched. Its simulator was validated against the contract before
  being trusted: 2,500 in gives 3,745.7 on the page and 3,746.34 on chain, 0.02% apart.
- **The demo needs exactly two signing accounts**, not five. The counterparty key is derived
  deterministically from the deployer's, so the operator manages one secret. Every extra funded
  testnet key is another way for a live demo to fail.
- **Sharpened the "so it isn't really a queue" answer in the README.** The old framing conceded a
  "closed roster", which is false: under an always-for-sale lease anyone may enter at any moment at a
  price the incumbent posted. What is scarce is the SLOT, not the PARTICIPANT. The stronger and more
  accurate statement is that every market prices queue position, most price it in *time* which is
  burnt on infrastructure and paid to nobody, and QUEUE prices it in money paid to the LPs you are
  standing in front of.

### Two things the product was missing, found by trying to use it

- **The pool a deployed hook serves was not readable on chain at all.** `key` is written once by
  `_afterInitialize`, the contract emits no event of its own, and every field was `internal` — so an
  integrator had to scan `PoolManager`'s `Initialize` logs and match on the hook address, and
  anything wanting the token *decimals* to render a balance simply could not. The frontend was
  hardcoding 18/6 to work around it, which would have shown balances a million times off on any
  other deployment, silently. Closed with `pool()`, a pure-disclosure view returning the key, the
  bound flag and the two ticks. `isBound` is returned rather than inferred from a zero key because
  `Currency.wrap(address(0))` is legal native ETH. **A hook that cannot say what it is attached to
  is not integrable.** (PITFALLS 5.89, 5.90; mutation M68.)
- **§5.17 — thin full-range depth, "the sharpest unanswered attack" — now has half an answer, and
  it is executed rather than argued.** The row always claimed the range was "a reversible design
  choice, not a v4 constraint"; that was ANALYSIS. `tickLower`/`tickUpper` turn out to appear in
  exactly two places — the sizing helpers and `modifyLiquidity` — and nowhere in the allocator, which
  sees only realised deltas. `test_1_11` seeds the identical roster over a **±10% band** and runs
  both directions against the independent witness: conservation, per-seat composition and INVARIANT
  C hold to the wei, and the sweep exhausts the head exactly as at full range. **Concentrating the
  custodied position is a v2 parameter, not a redesign.** Still unbuilt and NOT claimed: out-of-range
  behaviour, rebalancing, the depth/coverage trade-off. (PITFALLS 5.17, upgraded.)

### A third wrong prediction, worth recording because it was about a CONTROL

The first negative control for `test_1_11` mutated `_allocate` to index by seat id instead of rank
(M5) and the test stayed **green** — which briefly read as the new test having no teeth. It does not.
The founding order is the identity permutation, so `_idAt(ord, i) == i` wherever nothing has been
foreclosed, and that mutation is a genuine no-op in this fixture; M5 is caught by the rank suites,
which permute the order. The replacement controls discriminate: M60 makes it revert, and forcing the
range back to full makes the narrowness guard fire naming both numbers. **Before concluding a test is
weak, check the control can be detected in that fixture at all.** (PITFALLS 5.91.)

### What is left

The broadcast (needs a funded Unichain Sepolia key) and the video. Everything the broadcast will do
is already executed and asserted against a fork of that chain, so the remaining risk there is
operational, not mechanical.


**Where to look for status, so nobody has to read the log to find it:** `PLAN.md` opens with a
**BUILD STATUS** dashboard, each completed phase carries a ✅ block at its own §C section, and the
individual exit criteria inside those sections are ticked one by one. This board mirrors it. If the
two ever disagree, PLAN's dashboard and the ticked criteria win, because they sit next to the
criteria they describe.

**Verified 2026-08-29 (end of the Phase 7a session):** `forge test` is **172 passed / 0 failed /
1 loudly skipped** (`DeployFork.t.sol`, off unless `QUEUE_FORK=true`, because the default suite must
not need a network). `forge lint src/` CLEAN. `python3 script/mutate.py` runs **67 mutations with
ZERO survivors**. The six deployment tests also pass **against a live fork of Unichain Sepolia**,
producing numbers identical to the local run.

*(Superseded — 2026-08-28, end of the Phase 6 session:* Phases 0-6 are done. `forge test` is
**163/163 green**, `forge lint src/` is CLEAN with zero notes, and `python3 script/mutate.py` runs
**66 mutations with ZERO survivors**. **The Phase 6 campaign found THREE REAL BUGS in code that had
already passed 135 tests and 61 mutations**, all reachable through the ordinary public API — see the
entry below and PITFALLS 5.73-5.80.*)*

*(Superseded — 2026-08-28, end of the Phase 5 session:* Phases 0-5 are done. `forge test` is
**135/135 green**, `forge lint src/` is CLEAN, `script/mutate.py` runs **61 mutations with ZERO
survivors**. **Every gas number recorded before that session was optimistic** and all three affected
tests were re-measured — see LAW 4.*)*

*(Superseded — 2026-08-27, end of the Phase 4 session:* Phases 0-4 are done. `src/queue/QueueHook.sol`,
`src/queue/QueueSeats.sol`, `src/queue/libraries/Allocation.sol` and `src/queue/libraries/Rent.sol`
are the mechanism. `forge test` is **125/125 green** and `forge lint src/` is CLEAN with zero notes.
`python3 script/mutate.py` runs 53 mutations against the Phase 4 code and **none survive**.*)*

*(Superseded — earlier the same day:* Phases 0-3 are done. `src/queue/QueueHook.sol`,
`src/queue/QueueSeats.sol` and `src/queue/libraries/Allocation.sol` are the mechanism. `forge test`
is **77/77 green** and `forge lint src/` is CLEAN with zero notes.*)*

*(Superseded — earlier the same day:* Phases 0, 1 and 2 are done, 59/59 green.*)*

*(Superseded — 2026-08-26 doc-audit:* every row above is still accurate — **no `src/` directory exists
at the repo root** and no mechanism code has been written.*)* The two 2026-08-26 sessions below produced
research and documents only. `PITFALLS.md` §5 is the standing list of what is open.

---

## 2026-08-28 — Phase 5: the gas numbers were all wrong, and the roster bound was never justified

**Status: COMPLETE. 135/135 green, `forge lint src/` clean, 61 mutations with ZERO survivors.**

### The finding that mattered was not a gas number

I set out to reproduce §B.9's table against our hook. The first honest table disagreed with the EVM
cost model by about 35%, which is the sort of gap you are supposed to chase rather than round off.
It resolved into something that invalidated every gas figure this project had ever recorded:

> **`vm.cool()` restores cold ACCESS pricing. It does not restore cold WRITE pricing.**

`vm.cool()` resets the EIP-2929 access list, so the next `SLOAD` costs 2,100 again. EIP-2200 meters
a *write* against the slot's value **at the start of the transaction** — and a slot the current test
body already wrote is "dirty", so writing it again costs **100 gas** instead of 2,900 or 20,000. A
suite that deploys, seeds and then measures inside one test body is measuring a contract whose
entire storage is free to write.

Measured, same swap, same `vm.cool()`:

| | gas |
|---|---:|
| roster seeded **in the test body** | 172,263 |
| roster seeded **in `setUp()`** | 252,966 |

**47% optimistic.** Forge commits `setUp()` as its own transaction, so state built there is metered
honestly. `vm.snapshotState()` + `vm.revertToState()` is not a substitute — I tested it, identical
numbers to the wei. **LAW 4 is amended** and PITFALLS 5.66 carries it.

Three existing tests were affected. All three were re-measured from `setUp()`-built state, and the
optimistic copies were deleted rather than left standing next to the honest ones:

| test | was | now |
|---|---:|---:|
| head-only flatness (`Allocator.t.sol`) | — | moved to `test_5_1` |
| pure-rank transfer (`test_3_16`) | 24,969 | **23,208** (it went *down*: packing more than paid for the correction) |
| worst-case `addToSeat` (`test_4_44`) | 2,337,576 | **2,610,805** |

### And a second measurement artefact that produced a confident, wrong story

The first table showed a 21,179-gas excess on its depth-1 row. I explained it twice — swap size,
then `cursor1`'s first non-zero write — and both explanations were plausible and wrong. Running the
identical pair of measurements **in both orders** settled it: the excess followed the ORDER, not the
depth. `vm.cool` is per-account and a v4 swap crosses six of them; the first call in a test body
warms whatever was not named. Comparative series now burn a swap on a roster they never measure
(PITFALLS 5.67).

### §B.9's table was a different contract, and `MAX_SEATS = 32` was not justified by it

§B.9 quoted **6,753 gas per seat** from the Phase-0 spike — no cursors, no owners, no seat tokens,
no lease — and chose the roster bound as "comfortably inside a 300k budget". Re-measured against the
shipping hook:

| | per seat | queue cost at 32 seats | verdict |
|---|---:|---:|---|
| §B.9's inherited figure | 6,753 | 216,096 | ✅ (but not this contract) |
| this hook, measured | **12,254** | **412,028** | ❌ **37% over budget** |
| after Phase 5b's packing | **8,070** | **278,110** | ✅ 7% to spare |

The bound was never justified by the numbers written next to it. `test_5_3b` now **derives** the
supportable depth (34 seats) from the measurement and asserts it is at least `MAX_SEATS`, so the
constant in the source and the number in the document cannot drift apart again.

### The honest table (`test/queue/Gas.t.sol`)

Complete swap transactions through the real router and PoolManager — what a trader pays. State built
in `setUp()`, all six accounts cooled, a warm-up burned first, and **the swap size held constant
across the sweep series** so the pool's own work cancels exactly rather than approximately.

| seats | head-only | full sweep |
|---:|---:|---:|
| 1 | 117,971 | 145,980 |
| 2 | 117,989 | 173,950 |
| 5 | 117,990 | 198,161 |
| 10 | 117,990 | 238,511 |
| 25 | 117,991 | 359,562 |
| 32 | 117,992 | **416,053** |

> `sweep(n) = 137,866 + 8,070·n + 19,900·[n ≥ 2]` — reproduces every row to within **3 gas**.

- **Head-only is flat: a 21-gas spread from 1 to 32 seats.** That is the cursors working.
- **The slope is exactly 8,070**, identical between every adjacent pair, not a fitted approximation.
- **The 19,900 one-off** is `cursor1`'s first non-zero write: `0 → 0` costs 2,200 at depth 1,
  `0 → nonzero` costs 22,100 at every greater depth. Predicted 19,900, measured 19,900.

Against **no hook at all** — same tokens, fee, spacing, price, full-range liquidity, same swap —
QUEUE costs **117,989 vs 86,820: +31,169 gas, +36%.** Say that number. The defensible claim is not
"the common case is free"; it is that the overhead is a **constant a trader can price** rather than
something that grows with book depth.

### 5b — what shipped, and what was measured and rejected

**Shipped: the seat balance pair packed into one slot** (`uint128 a0; uint128 a1;`), with every
narrowing in the contract routed through one checked `_u128` that reverts rather than wraps. The
bound cannot bind on anything Uniswap can represent — v4 settles in `int128` deltas, so no position
it can account for holds `2^127` of either token — but it is checked anyway, because a silent wrap
would mint balance out of nothing.

| | before | after |
|---|---:|---:|
| gas per seat walked | 12,254 | **8,070** (−34%) |
| full 32-seat sweep | 549,897 | **416,053** (−24%) |
| head-only swap | 122,130 | **117,990** |

**Rejected, with numbers (PITFALLS 5.70):**

- **Copying the packed seat through memory** to force one `SLOAD`/one `SSTORE`: **worse** — 8,477
  vs 8,070. The memory round-trip costs more than the compiler's masking.
- **Hoisting `q.length` into an immutable**, since the roster is fixed at construction: **85 gas per
  swap, 0.07%** — and it broke `test_3_9`, the control that mints a seat at runtime to prove Phase
  3's fixed roster is load-bearing. It had created a *second copy of the roster size*, so the
  control's new seat became invisible to the allocator. A 0.07% optimisation reintroducing the
  writer/reader class that has been wrong four times on this project. Reverted.

### 5c — the O(1) prefix-sum redesign is NOT SHIPPED

§C.5 gates it behind "only if 5a/5b leave a real problem". They did not: the common case is flat and
cheap, the full sweep is 1.4% of a 30M block, and the queue-attributable cost is inside the stated
budget. §B.11's objection is also still unanswered — **the remainder line has no lazy analogue**,
because a prefix-sum accumulator does not know which seat is "the last one filled" at the moment the
scalar is updated. Shipping a subtly non-conservative allocator to save gas on a book already inside
budget would trade the one property QUEUE has for nothing. Criterion 5.6 is satisfied by *not*
building it, and this paragraph is the record §C.5 asks for.

### Mutation testing found something for the eighth consecutive time

61 mutations, and **M61 survived**: `Allocation.allocate` returned a `nextCursor` computed by its own
copy of INVARIANT C's "advance only if the seat was exhausted" rule. Every call site discarded it,
and **no production path calls that function at all** — it exists so the arithmetic can be fuzzed
without a pool.

So a production library was carrying an untested second copy of the single rule whose failure mode
is silent theft of rank, in the exact family that has been wrong four times here. The honest answer
was **(b) delete the line** — the second time on this project after `_demoteToTail`'s early return.
Testing it would have entrenched the duplicate. The cursor already has an *independent* witness in
`QueueFixture`, written from §B.6's prose rather than from `src/`, asserted after every swap. M61 now
targets the hook's real copy and goes red.

The harness also gained `Allocation.sol` as a mutation target, which it never had — including the
remainder line, the most load-bearing line in the project (M59).

### What I would flag

- **The worst-case `addToSeat` at 2,610,805 gas is the binding constraint on the roster, not the
  sweep.** `_settleAhead` is O(priced ahead × roster) where the sweep is linear. At 32 seats it is
  8.7% of a 30M block, which is fine; at 64 it would be roughly four times that. Any future proposal
  to raise `MAX_SEATS` has to be argued against that number (PITFALLS 5.72).
- **+36% per swap against a bare pool is a real cost** and should be in the pitch as a number, not
  as "negligible".
- Two of my own three explanations for the depth-1 anomaly were wrong before the order-swap test
  settled it. The pattern is worth remembering: a plausible mechanism that predicts roughly the
  right magnitude is not evidence.

---

## 2026-08-27 — Phase 4: rank gets a price, and §B.10's payment source turned out to be broken

**Status: COMPLETE. 125/125 green, `forge lint src/` clean, 53 mutations run against the new code
with ZERO survivors.**

### What Phase 4 was for

Three things the Phase 3 state would have had to disclose on camera, all of which close in one
mechanism: the founding roster was an endowment nobody had bid for; the tail had no compensation
channel at all, so the honest answer to *"why would anyone hold seat 5?"* was "they wouldn't"; and
rank-then-run was free. Harberger is the only thing that gives rank a continuous on-chain price
without needing the secondary market PITFALLS 5.11 says does not exist.

### The plan's specified payment source is broken, and not at the margin

§B.10 said rent is *"deducted from the seat's own `a0`"*. Built literally, that is unshippable, and
it took two independent arguments to be sure rather than one:

1. **Front-first allocation drives seats to single-token composition ON PURPOSE**, and INVARIANT C —
   asserted in every test since Phase 1 — states the consequence outright: *every seat below
   `cursor0` holds `a0 == 0`.* So after any sustained run of one-for-zero flow the FRONT seats hold
   exactly zero of the rent currency and get foreclosed, one after another, **because of the
   direction the market happened to trade.** Rank would be set by flow instead of by price, which is
   the one thing QUEUE claims it is not.
2. **An EMPTY seat is pure rank**, which Phase 3 exists to make holdable and sellable. Under `a0`
   rent it cannot be held at any price above zero at all. The spec's payment source is incompatible
   with the object it prices.

Owner decision, taken before any of it was built: rent is drawn from a **per-seat prepaid meter** in
`currency0`, held outside the position, outside `float0` and outside the allocator — so Phase 4 adds
nothing to the proven Phase 1–3 arithmetic. It is a meter, not collateral: nothing marks it, nothing
values it against anything, nobody is paid to seize it, and running it dry costs a place in the queue
rather than the seat or its capital. Both arguments are executed side by side against the spec's own
implementation in `test_4_13` and `test_4_13b`.

### The firm quote, which is not in the plan and without which Harberger delivers nothing

"Always for sale at your own price" is worth nothing if the holder can raise the price the instant
they see a buyer — and they can see one, because a buyout is an ordinary transaction in an ordinary
mempool. Repricing costs only rent for the seconds the raise is in effect: at τ = 10%/yr that is
**four parts in ten million of the price per block.** Effectively free. Left alone, EVERY buyout is
vetoable and Phase 4 would have shipped a rent tax with an always-for-sale slogan on it.

So an ask is FIRM: **the seat stays available at the lowest price it has been asked at, or paid for,
within `FIRM_WINDOW`.** A raise takes effect immediately for RENT and only after the window for the
SALE. The three ways out are each self-destructive rather than merely refused, and all three are
executed: raising blocks nothing because the old price is still firm; dropping to zero and re-raising
atomically makes the window minimum ZERO; handing the seat to your own second address arms the
window at what was paid for it, which for a plain transfer is zero.

### Four more things that were found rather than designed

- **The flash-loan rent grab.** Rent is split by the recipients' `currency0` balance read at
  settlement, and funding a seat is the only way a holder can raise that number at will. So
  `addToSeat(tail, huge) → settleRent(everyoneAhead) → withdraw(tail)` captures rent accrued over a
  period the depositor was not there for, in one transaction, with borrowed money — **measured at
  16× the honest share.** Closed by settling every seat ahead first. A per-block cooldown would also
  close it and is the wrong instrument: §B.12 counts "waiting one block boundary" as a proven
  evasion and QUEUE passes that table precisely because it has no per-block reference.
- **A buyout paying the seller directly would hand every incumbent a veto over their own buyout** —
  a seller that is a contract refuses payment and the sale reverts. The price is credited as a
  `pendingWithdraw` claim instead, which is the same unblockability argument Phase 3 made for the
  evacuation path.
- **`selfPrice` had to be bounded.** An unbounded assessment overflows the rent product, and a
  settlement that reverts is a seat that can never be foreclosed OR bought — and `_settleAhead`
  would carry that revert into every deposit behind it. Bounded at `type(uint128).max`, above
  anything v4 itself can represent.
- **Seat id stopped being rank index**, because foreclosure permutes the queue. The order lives in
  ONE `uint256`, one seat id per byte, which is why `MAX_SEATS` is 32: the roster bound and the 32
  bytes of a word are the same fact. There is deliberately no `rankOfId` mapping — a second copy of
  the order is a writer/reader pair that can disagree, and on this project that has been wrong four
  times. `rankOfId` scans the word.

### The mutation campaign, which is the part worth reading

The suite was **99/99 green** and every review lens had been walked before `script/mutate.py` ran for
the first time. It left **21 of 53 mutations alive.** Among them:

- **anyone could drain anyone's rent meter** (`withdrawRent` had no ownership check under test), and
- **anyone could reprice anyone's seat** — which is not griefing but theft: set a rival's price to
  zero and buy their seat. Both entry points were new, both were completely untested, and neither
  was caught by reading the code.
- **Every foreclosure test demoted SEAT 0 FROM RANK 0.** `0 << anything` is `0`, so a demotion that
  wrote the seat id back at the WRONG byte offset was invisible to all of them, as was cursor1's
  copy of the pull-back rule, as was the funding pull-back comparing an id where it should compare a
  rank. Four separate defects hiding behind one convenient fixture.
- **A gas optimisation I had added myself re-opened the dodge it was meant to stop.** The lease reset
  in `_onSeatTransfer` is skipped when the seat is already in the post-transfer state — but the
  predicate was evaluated AFTER settlement, and settlement can FORECLOSE the seat, which zeroes
  `selfPrice`. So a holder could arm nothing at all by letting their own unfunded seat foreclose on
  the way through a self-transfer, then reprice with no firm quote against them. Fixed by reading
  the predicate before settling; `test_4_12` executes the sequence.

One mutation could not be killed and the line was **deleted** instead (PITFALLS 5.49 again): the
"already at the tail" early return in `_demoteToTail` is exactly equivalent to the general path.

Seventh consecutive time mutation testing has found a real defect on this project. First time it
found an unguarded external entry point.

### What is honestly still open

- **Harberger cannot express a negative seat value** (5.10). Under toxic flow everyone declares near
  zero, no rent flows, and the front is free to take. Correct behaviour, and the point at which the
  signal is censored. Unsolved, and not solvable inside this design.
- **Rent is `currency0` and weighted by `currency0`**, because weighting a two-token basket needs a
  price and §E.11 forbids one. A tail holding only `currency1` is not an eligible recipient and the
  rent waits in `unallocatedRent0`. `test_4_43` asserts exactly this rather than hiding it.
- **Enforcement needs somebody to call `settleRent`.** No keeper ships and none is required — the
  seats behind are paid by it, and a would-be buyer must call it to clear a delinquent incumbent out
  of the way — but a seat nobody wants and nobody pokes accrues a debt nothing collects.
- **Worst-case `addToSeat` is 2,337,576 gas** at a full 32-seat roster with every seat ahead priced
  and funded. It fits a 30M block thirteen times over, and the configuration costs the attacker rent
  paid to the very seat they are trying to price out — but it is a real cost of closing the grab and
  it is measured rather than assumed (`test_4_44`).
- **Full-range depth** (5.17) is untouched and remains the sharpest attack on the premise.

## Carried forward from the design phase — what is ALREADY PROVEN

These were established by executed experiments before the build started. Evidence lives in
`archive/2026-08-26/`.

> ### ⚠ READ THIS BEFORE QUOTING ANY NUMBER BELOW
> **Three rows of this table were measured on the SPIKE, not on the shipping hook, and two of them
> are now known to be WRONG.** The spike had no cursors, no owners, no seat tokens and no lease.
> "Do not re-derive them" was the wrong instruction and it is withdrawn: a measurement inherited
> from an earlier prototype is not a measurement of the thing you are shipping (PITFALLS 5.68).
> Superseded rows are marked inline. The live gas table is `PLAN.md` §B.9 and `test/queue/Gas.t.sol`;
> the live residual claim is PITFALLS 5.80.

| Claim | Status | Evidence |
|---|---|---|
| Front-first allocation at the swap's realised average price is **exact to the wei in both tokens at a non-unit price (1:4)** | **PROVEN** | `archive/2026-08-26/test/spike/QueueAllocator.t.sol`, 9 tests; conservation measured on PoolManager's own ERC20 balances |
| The remainder-assignment line is load-bearing | **PROVEN** | Negative control: floor-only mutation survives swap 1 and dies at swap 2 |
| Pro-rata allocation and an off-by-one cursor both break it | **PROVEN** | Two further negative controls, both red, revert reasons asserted |
| ~~Head-only swap gas is flat at ~31,874~~ | ⚠ **SUPERSEDED — spike figure, and measured with `vm.cool()` alone, which meters writes at 100 gas instead of 2,900 (LAW 4 as amended).** The shipping hook's head-only swap is **117,971–117,992 gas**, still flat (a 21-gas spread from 1 to 32 seats), re-measured with state built in `setUp()`. PITFALLS 5.66 | `test/queue/Gas.t.sol` `test_5_1` |
| ~~A sweeping swap is O(entries) at ~6,753 gas/entry; ~44 seats at a 300k budget~~ | ⚠ **SUPERSEDED AND THE `MAX_SEATS` JUSTIFICATION IT SUPPORTED WAS FALSE.** Re-measured on the shipping hook: **12,254 gas/seat**, i.e. **37% OVER** the budget the roster bound was picked to fit. Phase 5b's packing brought it to **8,070**. And the real bound is `addToSeat` at **2,610,805 gas** (quadratic), not the sweep. PITFALLS 5.68, 5.72 | `test_5_3`, `test_5_3b`, `test_5_6` |
| ~~A **~0.26 wei/swap** redemption residual exists; the last withdrawer eats it~~ | ⚠ **HALF SUPERSEDED.** The *last withdrawer eats it* half is right and still shipped (dust policy F1 spreads it over withdrawers). The *per-swap constant* half **does not generalise**: the truncation scales with price displacement, and a drained pool at the tick floor loses **~1e9 wei on one swap**. What generalises is the ratio against **lifetime inflow**: worst shortfall **under 1 ppb**, worst surplus **exactly 0 wei**. PITFALLS 5.80 | `Invariant.t.sol` `K`; `QueueHandler::_noteSolvency` |
| That residual is **NOT** fee-growth truncation | **FALSIFIED** by a zero-fee pool retaining 88% of the drift | Spike §Q1 |
| The residual is **unfarmable** — cost-to-damage off by ~20 orders of magnitude | **REASONED from measurement** | Spike §Q1 |
| No forgeable-proof toxicity signal exists for a v4 hook | **PROVEN** | `archive/2026-08-26/docs/research/IDEAS_CONSTRAINED.md` §1 |
| No static curve can improve adverse selection per unit of depth | **PROVEN** | `archive/2026-08-26/docs/research/IDEAS_CURVES.md` §0 |
| A v4 hook can never see or pay the trader | **PROVEN** | `archive/2026-08-26/CLAUDE.md` §5 items 16 and 18 *(root `CLAUDE.md` is a symlink to `AGENTS.md` and has no §5.16 — the old citation was unfollowable)*; `PITFALLS.md` §1.14, §4.3 |

## Carried forward — what is OPEN

**`PITFALLS.md` §5 is the authoritative list of open hazards** — it is longer than this table and
each row carries its evidence grade. The rows below are the headline items and point into it.

| Item | Why it matters | Where | Ledger row |
|---|---|---|---|
| ✅ ~~**Redemption dust fix**~~ | **CLOSED Phase 2** — dust policy F1 pays `min(face, available)`. The claim *"the queue's face value is redeemable"* is **still barred**, and Phase 6 measured the bound honestly: under 1 ppb of lifetime inflow, borne by the last holders to exit | `PLAN.md` §B.7 | `PITFALLS.md` §5.7, §5.80 |
| ✅ ~~**Per-seat withdrawal feasibility**~~ — **CLOSED Phase 2** by the shared float; §B.7 corrected in place | **MEASURED:** §B.7's withdraw spec is impossible as specified — seat 1 holds 258.877 token0 / 0 token1 and can withdraw nothing via `modifyLiquidity(−Δ)`. A **Phase 2 BLOCKER**, and the second reason the face-value claim is barred. `withdraw` must never call `poolManager.swap` | `PLAN.md` §B.7 (not yet corrected); `docs/research/protocol-fee/queue-exposure.md` §A2 | `PITFALLS.md` §5.5, §5.6 |
| ✅ ~~**Protocol fee remedy P2**~~ — **CLOSED Phase 1**, built and asserted at max fee, `lpFee == 0`, and against a foreign pool | Hazard is MEASURED and real. **Owner decided 2026-08-26: ship P2** (net out `protocolFeesAccrued` in `_afterSwap`), **not** the refusal this row previously named. Phase 1 must build it and assert against `PoolManager balance − protocolFeesAccrued` / `redeemAll()`, having first asserted `protocolFeesAccrued > 0` | `PLAN.md` §E.5, Phase 1 acceptance 1.10 | `PITFALLS.md` §3.1, §5.1–§5.4 |
| **LAW 3 is amended** | Conservation must net out `protocolFeesAccrued`; the raw-balance form is blind to this bug class. Now stated in `AGENTS.md` §3.3 **and** `PLAN.md` §D.1 LAW 3 | `docs/research/protocol-fee/experiment.md` | `PITFALLS.md` §2.6 |
| ✅ ~~**Rank-then-run hole**~~ — **CLOSED Phase 4** by the firm quote; asserted in `test_6_11`. The negative-seat-value gap it names is still OPEN | Plain-token rank can be abandoned before a scheduled event; only the Harberger variant closes it — and Harberger has its own unsolved gap (it cannot express a negative seat value) | `PLAN.md` Phase 4 | `PITFALLS.md` §5.9, §5.10 |
| ⛔ **O(1) prefix-sum redesign** | **DECIDED PHASE 5: NOT SHIPPED, and do not reopen without new evidence.** §C.5 gated it behind "only if 5a/5b leave a real problem"; they did not. Its objection is also unanswered — a prefix-sum accumulator does not know which seat is "the last one filled" when the scalar is updated, so the remainder line has no lazy analogue | `PLAN.md` §B.11 | `PITFALLS.md` §5.12, §3.16 |
| **Phase 6's three bugs are FIXED, but their FAMILIES are standing** | The cursor bug was the **fifth** instance of "one rule, two places"; the unsigned measurement was the first of "predicting a balance change's sign from the request"; the periphery helper was the first of "a non-binding leg decides the outcome". Every new external path, every new measurement, and every new use of a periphery helper inherits these | `AGENTS.md` §3b | `PITFALLS.md` §5.73, §5.74, §5.76, §5.77 |
| **Harberger cannot express a negative seat value** | Under toxic flow everyone declares near zero, no rent flows, and the front is free to take. **This is the headline unsolved item** and it sits exactly where the cohort's problem statement points | `README.md` | `PITFALLS.md` §5.10 |
| **Enforcement needs somebody to poke `settleRent`** | Nothing ships that does and none is required, but a seat nobody wants and nobody pokes accrues a debt nothing collects | `README.md` | `PITFALLS.md` §5.64 |
| **Seat governance** | Rank must be bought or Harberger-held, **never granted by deposit order** (dust-griefing the head). Phase 2's append-at-tail is provisional and must carry a named known-hole test | `BUSINESS.md` §8; `PLAN.md` §B.8, §E.16 | `PITFALLS.md` §3.8, §5.8 |
| **Theme framing** | The honest bridge to "Sustainable Liquidity and MEV Protection" is the weakest part of the pitch | `BUSINESS.md` §10 | `PITFALLS.md` §5.16 |
| **Full-range capital efficiency** | The sharpest unanswered attack, and **absent from `BUSINESS.md` and `PLAN.md` entirely**. [ANALYSIS] | `docs/research/premise-review/economics.md` §6 | `PITFALLS.md` §5.17 |
| **The Ratchet · the one-sided Phase 3 market · "the seat price IS the toxicity" is overclaimed** | Three pitch-level contradictions named nowhere in the live docs. [ANALYSIS] | `docs/research/premise-review/` | `PITFALLS.md` §5.18, §5.19, §5.20 |
| **Proposal 100 / live protocol fees** | Press-sourced only. **UNVERIFIED** — check on-chain before relying on it | `docs/research/protocol-fee/v4-mechanics.md` §9 | `PITFALLS.md` §5.15 |
| **Standing pitfalls ledger** | Every hazard, testing trap, settled decision and proven-impossible item, with its evidence status — **re-read at the start of every session**. §7 lists where two docs disagree | `PITFALLS.md` | — |

---

## Session log

### 2026-08-28 — PHASE 6 COMPLETE. The campaign found three real bugs, and the product was reframed.

**Result: `forge test` 163/163 green · `forge lint src/` clean · 66 mutations, ZERO survivors ·
§D.8 GATE 6 PASS.**

#### What was built

| File | What it is |
|---|---|
| `test/queue/handlers/QueueHandler.sol` | The bounded actor. Twelve actions, `bound()`ed inputs, four actors, a ghost ledger built from handler inputs and token flows measured across the hook's boundary — never from `hook.totals()`, which is the thing under test |
| `test/queue/Invariant.t.sol` | 11 invariants × 256 runs × 64 depth. `targetContract` **and** `targetSelector` both set. Plus `test_6_0`, a deterministic 500-call campaign asserting every invariant after **every single call** |
| `test/queue/Adversarial.t.sol` | 15 tests: every named attack in §C.6 with an asserted outcome, plus a directed regression for each bug found |
| `script/mutate.py --campaign` | Runs a mutation against the INVARIANT SUITE ONLY and names the invariant that caught it — §D.8 V3's actual requirement, which "the full suite goes red" does not satisfy |

#### THE THREE BUGS. All reachable through the public API. None visible to 135 tests.

**1. The degenerate fill left a cursor LEADING a funded seat (PITFALLS 5.73).** A swap whose output
rounds to zero credits its whole input to one seat. `_allocate` has always pulled the incoming
token's cursor back after crediting; **the degenerate path never did.** Once `cursor0` leads rank 0,
every later one-for-zero swap starts *behind a funded seat* and sources from further back — the head
is passed over, which is exactly the theft of rank the mechanism exists to prevent. The credited
amount is dust; the cursor corruption is not dust-bounded. **Fifth instance of "one rule, two places,
right in only one of them"** (5.37, 5.50, 5.52 ×2, 5.62).

**2. An ADD can CREDIT the caller, and the measurement was unsigned (PITFALLS 5.74).**
`modifyLiquidity` realises the position's accrued fees on every call and returns
`callerDelta = principalDelta + feesAccrued`. When the fees exceed the principal being added — the
ordinary state of a busy pool between two deposits — the hook's balance goes **up** on an **add**,
and `unlockCallback`'s `b0Before - balanceAfter` underflowed. **`addToSeat` and
`sweepFloatIntoPosition`, the only two paths capital has INTO the queue, reverted with an arithmetic
panic for as long as the fees stood.** Fixed with a signed measurement (`_moved`) plus a named
`UnexpectedPositionDebit` guard on the removal side, where the sign genuinely is predictable. **Rule:
never predict the SIGN of a balance change from the sign of the request you made.**

**3. Liquidity sizing reverted at a tick boundary — on BOTH sides (PITFALLS 5.76, 5.77).**
v4-periphery's `getLiquidityForAmounts` computes both legs and narrows **each** to `uint128` before
taking the minimum, so the non-binding leg decides the outcome: measured, depositing 393e18 of token1
reverted `SafeCastOverflow` while the binding leg was **1,033**. And on the removal side,
`_liquidityToCover` divided by a span that goes to zero at the tick — `FullMath.mulDiv` answers a
bare `require`, so the call died with **empty revert data** and both `withdraw` and `_onSeatTransfer`
were blocked. **The evacuation one is the serious half**: §B.8 made that path unblockable on purpose
because the buyout leans on it, so a holder at the tick boundary could not be bought out — the exact
incumbent veto Phase 3 removed. Fixed by taking the minimum in 256 bits, clamping to
`Pool.tickSpacingToMaxLiquidityPerTick`, and treating a zero span as "this leg cannot be sourced".

#### Two things that were WRONG IN OUR OWN INSTRUMENTS, not in the code

**`_positionValue()` overstated the position by 8.28e18 wei (5.75).** `minUsableTick(60)` is -887220
and `MIN_TICK` is -887272, so a "full-range" position's range **can be left**, and the estimator was
computing `getAmount0Delta(sqrtP, hi, L)` with an unclamped price. INVARIANT F looked broken while the
ledger was correct to 12 wei. **Two wrong explanations were entertained before the instrument was
suspected.** After clamping it agrees with a real `redeemAll()` exactly over a 500-call campaign.

**`script/mutate.py` left a mutant on disk when interrupted (5.79).** It restored the source only on
the happy path. An interrupted run left the 5.77 guard absent, a whole campaign ran against the
mutated hook, and the **only** symptom was a `BAD-PATTERN` on the one mutation targeting that exact
line. Had that mutation not existed the repository would have silently regressed. Fixed with
`try/finally` and a report of every file it had to put back.

#### Two things §C.6 asked for that rested on FALSE PREMISES — corrected in place, not dropped

- **I6 named `seatIndex`/`indexSeat`**, which Phase 4 deliberately replaced with one packed word and
  a scanning `rankOfId` so there is no second copy of the order. Live form asserted instead: `order`
  is a permutation of `0..n-1` and `rankOfId(idAtRank(r)) == r` at every rank.
- **"A swap one wei larger than the queue → `QueueUnderflow`" — there is no such swap** (5.78). A
  swap takes out only what the POSITION holds; INVARIANT F says the position never exceeds the ledger
  (**surplus measured at exactly 0 wei** across the whole campaign); INVARIANT C says everything
  below the cursor is empty. `QueueUnderflow` is not a trader-reachable boundary — it is the loud
  failure that fires when the ledger and the position have come apart.

#### The residual claim was corrected (5.80)

"~0.15 wei per swap, linear and converging" holds **at the seeded price and nowhere else**. The
truncation scales with price displacement: a drained pool pushed to the tick floor loses ~1e9 wei on
one swap. What generalises is the ratio against **lifetime inflow, not the current ledger** — the
residual accumulates while the ledger is drained, so the campaign reached `owed = 5,337,018,741`,
`backing = 0`. Measured: worst surplus **exactly 0 wei**, worst shortfall **under 1 ppb of lifetime
inflow**, and **the last holders to withdraw bear it**. README, BUSINESS §9 and PLAN say so.

#### Method notes worth keeping

- **A coverage floor CANNOT live in `afterInvariant`.** The shrinker answers any cumulative
  assertion there by shrinking to a ONE-CALL sequence, which trivially has no coverage. That is why
  `test_6_0` is a deterministic scripted campaign instead.
- **Under `fail_on_revert = false`, an `assertEq` inside a handler is a revert and is SWALLOWED.**
  Every per-call check in the handler is therefore a ghost COUNTER that an invariant asserts is zero.
- **`fail_on_revert = false` plus a revert allow-list is strictly stronger than `true`**, which only
  says *something* reverted. I7 asserts the unexpected-selector count is zero.
- The "nothing happened: this test proves nothing" guards caught **six** of my own broken
  adversarial tests before they could pass vacuously.

#### The product was reframed (README, BUSINESS §0)

The pitch was true but was being read as "an order book bolted onto an AMM". It is not that. The
frame now states the **Uniswap decision being challenged** (pro-rata fill, unexamined for seven
years), what that choice costs (priority has no price, subordination cannot be sold, and ordering
value relocates to the sequencer instead of vanishing), and **why paid seats specifically**: free
rank is griefable, unbounded rank is worthless, so scarcity IS the mechanism — and Harberger is what
stops a scarce roster becoming a cartel. **Scarce, but never capturable.** The honest claim is that
QUEUE is the first venue that produces a *number* for what being filled first is worth, and that
both possible answers are results.

---

### 2026-08-27 (third session) — Phase 3: rank becomes an object, and the plan's own transfer design turns out to be a free DoS

**Phase 3 is COMPLETE. `forge test` 77/77, `forge lint src/` clean, 29 mutations on the Phase 3 code,
ZERO survivors.** The project is at its SUBMITTABLE state.

**What was built**

- `src/queue/QueueSeats.sol` — the ERC-6909 rank token. One id per seat, supply exactly one.
  Ownership is a single `seatHolder[id]` address slot and the whole ERC-6909 surface is a VIEW over
  it, so **supply-1 is structural rather than tested**: there is no storage in which "two" could be
  written. The interface is v4-core's own `IERC6909Claims`, so every selector and event topic is
  compiler-checked against the canonical definition. `transfer` and `transferFrom` differ only in
  how they authorise and both funnel through one `_moveSeat`.
- **The founding roster is fixed in the constructor.** `deposit()`, `seatOwner` and `_pushSeat` were
  DELETED. There is no runtime path that creates a seat.
- `_onSeatTransfer` — the evacuation. `pendingWithdraw` + `claimPending` for the residual.
- A transient reentrancy guard on every external ledger path.
- `test/queue/Rank.t.sol` — 19 tests including 5 negative controls.

**DECISION TAKEN (recorded per AGENTS.md §4): the founding roster is an endowment fixed at
deployment.** §B.8 permits "direct assignment by the deployer", and the constructor form adds no
privileged role, no admin function and no runtime path — the allocation is an immutable fact of the
deployment. It closes the dusting hole completely: **rank cannot be obtained at any price the
incumbent has not accepted.** It does NOT make rank *bought* — that needs Phase 4's Harberger lease,
and the honest sentence is in PITFALLS 5.8. Say the narrow thing on camera.

**FOUR DEFECTS, ALL FOUND BY ATTACKING THE WORK RATHER THAN BY WRITING IT**

1. **PLAN §B.8's specified evacuation is a free DoS on the swap path** (PITFALLS 5.51). A ledger-only
   move to `pendingWithdraw` drops `Σ q[i].aX` while leaving the position at full depth, so the pool
   quotes liquidity the queue cannot source and `_allocate` reverts `QueueUnderflow`.
   `transfer(self, id, 1)` is legal and costs only gas, so **any single seat holder could brick every
   swap above their surviving balance, indefinitely, and undo it at will.** Fixed by paying the
   capital out for real, which burns the matching liquidity. Refusing to transfer a funded seat was
   rejected because Phase 4's buyout must be unblockable. §B.8 is corrected with the full reasoning
   and both rejected alternatives. **The control runs the spec's design and the shipped one side by
   side.**
2. **Seat theft through an unchecked entry point — the paired-rule asymmetry, third instance and the
   first that was funds rather than wei** (PITFALLS 5.52). Removing the ownership check from
   `transfer` survived all 71 tests: `transferFrom` had a test and `transfer` had nothing. Removing
   `transferFrom`'s check ALSO survived, because the only test there used an unapproved third party —
   and naming yourself as `sender` skips the allowance branch entirely. Either mutant lets anyone
   take any seat for free and be paid its capital on the way out.
3. **A bound in the right direction is not a correctness assertion** (PITFALLS 5.53). `withdraw`
   debiting the REQUEST instead of the PAYMENT survived the whole suite, because the residual tests
   assert the unpaid leftover is SMALL — and over-debiting makes it smaller. **The mutant passed more
   comfortably than the real code.** Replaced with the identity `seatAfter == seatBefore - paid`.
4. **The whole `pending` path was dead code under test while being asserted about** (PITFALLS 5.54).
   Every pending line survived mutation because no test had ever produced a non-zero pending balance;
   `test_3_2`'s assertions about it all held vacuously at zero. Reaching it needs ~40 swaps of
   accumulated §E.4 residual AND the seats in front drained first.

**A fifth finding, reported as what it is and not more** (PITFALLS 5.55). The reentrancy window is
real: `take` calls `IERC20.transfer`, handing a pool currency control mid-unlock, and PoolManager's
lock does NOT close it — a withdrawal on the leg the float already covers needs no second `unlock`
and executes in full. What it corrupts is `unlockCallback`'s balance-difference measurement (which
must be a difference: a fee-on-transfer currency delivers less than `callerDelta`). In the executed
control it happens to underflow and revert — **an accident of direction, not a defence.** The guard
stays. **NOT claimed: no value-extracting sequence was found without it.** The first draft of the
guard's own comment asserted a double-payment that could not be reproduced, and that comment was
rewritten rather than left to read well.

**Also done**

- `MAX_SEATS = 32` taken and recorded; the gas regression's top depth moved 50 -> 32, because 32 is
  now the real worst case. Head-only swap stays flat across 1 -> 8 -> 20 -> 32.
- Pure-rank (empty-seat) transfer measured under `vm.cool()`: **17,939 gas**, versus 23,905 with the
  early return removed. The bound sits between them.
- `_seatSlot` in `Allocator.t.sol` hardcoded storage slot 0 for `q`. `QueueSeats` put three mappings
  in front of it, so the test would have poked an unrelated slot and passed for the wrong reason. It
  now reads the slot from the contract.
- Two dead imports removed and the `nonReentrant` modifier unwrapped: `forge lint src/` is clean with
  **zero notes**, not just zero errors.

**What is open, and must not be glossed on camera**

- The founding roster is an endowment, not a purchase (PITFALLS 5.8, amended).
- Phase 3 alone is a one-sided market (5.19); rank-then-run is open (5.9). **Phase 4 is what closes
  both and what makes rank continuously priced without needing a secondary market to exist.**
- A seat transfer is a second trigger for the 5.43 depth drain (new row 5.56). Seat trading is not
  depth-neutral.

---

### 2026-08-27 (third) — PHASE 2 COMPLETE. Float withdrawal, the sweep, and a DoS closed

**All §D.4 gate criteria met. 59/59 tests, `forge lint src/` clean, 11 Phase 2 mutations run with
ZERO survivors** (20 production mutations across Phases 1–2 in total).

Built on `QueueHook`: `deposit`, `addToSeat`, `withdraw`, `sweepFloatIntoPosition`, the two-slot
float, and pool binding via `afterInitialize`. Tests: `Deposit.t.sol` (16), `Residual.t.sol` (5).

#### Owner decisions taken this session
1. **Deposit remainder: ABSORB into float and credit the seat**, not refund to `msg.sender` as
   PLAN §B.7 said. Cheaper, shrinks the float, and the depositor keeps full value as ledger credit.
   INVARIANT F holds exactly: consumed → position, remainder → floatX, seat credited both.
2. **Full-range depth: answer it, don't fix it, until the sweep is proven.** Unchanged this session.

#### What the float actually buys, and what it does NOT

`withdraw` sizes the removal on the leg that **binds** (the MAX of the two liquidity requirements),
pays the seat its exact ledger composition, and retains the surplus as float shared by the queue.
**All six withdrawal orderings pay everyone**, at 1:4 with 18/6 decimals. `withdraw` never calls
`poolManager.swap` — it reaches `modifyLiquidity` only through `_burnPosition`, which decrements
`liquidity` (PITFALLS 5.23, confirmed by mutation P1).

**Two honest limitations, now asserted rather than written down:**
- **The sweep is BOUNDED BY THE SMALLER LEG** (5.43). Adding to a range straddling the price needs
  both tokens, so a lopsided float is reinjected only in proportion to its minority token. A
  1000e18/1e6 float reclaimed <0.1% of the majority leg. **Do not claim the sweep "restores depth"**
  — it restores as much as the float is balanced enough to pair up.
- **An off-ratio deposit becomes float, not depth** (5.44). A token0 deposit the size of the whole
  pool moved liquidity <1%. The depositor loses nothing under ABSORB, but the pool gains nothing
  either until the other leg arrives. A real consequence of the ABSORB decision.

#### THE BIG MEASUREMENT ERROR — my instrument, not the ledger

INVARIANT F appeared to be violated by **9.6e15 wei per swap** — about 80% of the LP fee, growing
linearly. It looked exactly like catastrophic ledger corruption. **It was the instrument.** v4
accrues LP fees into `feeGrowthInside` and only realises them on `modifyLiquidity`, so a
principal-only position valuation understates the position by every fee it has ever earned. Adding
`L * (feeGrowthInside - feeGrowthInsideLast) / 2^128` collapsed it to a handful of wei.

**This is the third instance of PITFALLS 5.27 in one day** (after the tautological fee assertion and
the late foreign swap). Recorded as 5.46.

A second unit error compounded it: I supplied token1 in HUMAN units (1e6) against token0 in RAW
units at a 4:1 raw price, so **98% of every deposit went to float** and churned. LAW 1 says use
unequal decimals — but v4 works entirely in RAW units, so fixture amounts must be in the pool's raw
ratio regardless of decimals (5.48).

**The §E.4 residual, re-measured cleanly: ~0.15 wei per swap per token** (17 wei after 120 swaps),
LINEAR and converging. The safety property asserted is linearity, not zero — a compounding residual
would eventually be real money; at 0.15 wei/swap a single token of shortfall needs ~10^18 swaps. The
mandatory dust control is in: with F1 replaced by face-value payment, a withdrawer's call reverts
`FloatShort`; with F1 in place the identical scenario drains everyone.

#### A FREE, UNRECOVERABLE DoS — found and closed

`afterInitialize` bound the hook to whichever pool initialized **first**. Anyone could front-run the
intended `poolManager.initialize` and bind a freshly deployed hook to a junk pool — **permanently**,
because there is no admin to unbind it. Closed by committing `(currency0, currency1, fee,
tickSpacing)` at CONSTRUCTION and rejecting anything else with `WrongPool`. Costs nothing: the hook
serves exactly one pool by design. Two tests (5.45).

#### THE PAIRED-BRANCH ASYMMETRY RECURRED

The top-up cursor pull-back exists once per direction. The `cursor1` copy was covered; the `cursor0`
copy was covered by **NOTHING**. That is PITFALLS 5.37 repeating one phase later, in a different
function. **It is now a confirmed repeating failure mode on this project, not a one-off** (5.50).
Two other mutations also survived the first battery and are now covered: the `+1` truncation guard
in `_liquidityToCover`, and the deposit sizing shave.

**The shave was DELETED rather than tested** (5.49). Mutation testing said nothing could detect its
removal; 5,000 fuzz runs found no counterexample, and the round trip is provably
`ceil(floor(x*k)/k) <= x`. `DepositOversized` remains as the loud backstop. When mutation testing
says a line is undetectable, the honest question is whether it should exist.

#### Still true, still open

- **Rank is granted by arrival order** — PITFALLS 5.8, not shippable. Carried deliberately with a
  named test (`test_KNOWN_HOLE_rankIsGrantedByArrivalOrder`) that must be DELETED in Phase 3. One
  wei of each token currently buys the head seat.
- **Full-range depth** (5.17) — unaddressed by decision; a pitch question, not a correctness one.
- **"The queue's face value is redeemable" is still FORBIDDEN.** The defensible replacement claim is
  now precise: *each seat redeems its entitlement to within a bound that grows linearly at ~0.15 wei
  per swap and never compounds.*

**NEXT ACTION — Phase 3 (§C.3): the ERC-6909 rank token.** It replaces `seatOwner`, closes 5.8, and
is the SUBMITTABLE state. Delete the known-hole test when it lands.

---

### 2026-08-27 (second) — PHASE 1 COMPLETE. Protocol fee SOLVED; four real defects found and fixed

**All twelve §C.1 exit criteria met. Gate §D.3 passes. 36/36 tests, `forge lint src/` clean.**

Built: `src/queue/libraries/Allocation.sol` (the arithmetic, 89 lines) and
`src/queue/QueueHook.sol` (the hook, 359 lines). Tests: `test/queue/` — `Allocator.t.sol` (11),
`Controls.t.sol` (7), `ProtocolFee.t.sol` (6), `Dust.t.sol` (3), plus `QueueFixture.sol` and the
test-only `QueueHarness.sol`.

---

#### 1. THE PROTOCOL FEE IS SOLVED, and the fix is one SLOAD rather than a derivation

The handoff said the replacement "is NOT a one-liner" and listed four arithmetic hazards to
overcome (per-step rounding across tick crossings, `lpFee == 0` taking the whole `feeAmount`,
exact-output rounding the other way, clamping not fixing the under-credit). **None of them apply,
because the fee should not be derived at all.**

`protocolFeesAccrued` being global per currency was never the problem. **The measurement window
was.** Verified at source: `PoolManager.swap` calls `beforeSwap` -> `_swap` (which calls
`_updateProtocolFees(inputCurrency, amountToProtocol)`) -> `afterSwap`, and **that window contains
no external call**, so no foreign pool can accrue inside it and `collectProtocolFees` cannot run
inside it. Snapshot in `beforeSwap`, read in `afterSwap`, and the difference is *exactly this
swap's protocol fee on this pool, to the wei*.

- **Cost:** one hook permission (`beforeSwap`; address bits `0x0840` -> `0x08C0`), one SLOAD, one TSTORE.
- **The snapshot is TRANSIENT**, so a stale or uninitialised snapshot — the third documented failure
  of the old design — is impossible by construction, not by convention.
- **Nothing is clamped.** `pfDelta > amtIn` reverts by name. A clamp would silently under-credit.
- `lpFee == 0` needs no special case: `test_5_3_lpFeeZeroUnderProtocolFee`.

**X1 and X2 are dead, and I proved it by reinstating the old mechanism against the new suite:**

| Test | vs. old mechanism |
|---|---|
| `test_X1_foreignAccrualCannotCorruptTheLedger` | RED — ledger short `499999999999999999` wei, **exactly** the foreign pool's take |
| `test_X2_foreignAccrualCannotBrickTheHook` | RED — `ProtocolFeeExceedsInput(pfDelta 1e19, amtIn 2e16)`; under the old bare subtraction this is an underflow panic and a permanent brick |
| the other four | RED |
| all six | GREEN on the fix |

**Every fee test runs with a FOREIGN POOL sharing a currency.** A single-pool fixture cannot observe
this and that is exactly how the previous mechanism passed review.

**THE NEAR-MISS, and it is the more valuable finding.** `test_measurementWindowSeesExactlyOneSwapsFee`
**passed against the broken mechanism twice** before it was any good:
1. It compared `lastPfDelta` (the FIXTURE's own measurement) to another fixture-side number —
   tautological, never touched the hook. Fixed by asserting `lastHookCreditedIn`, the hook's own
   ledger movement.
2. Its foreign swap came AFTER the window it was checking. A multi-pool fixture is **necessary but
   not sufficient** — the contamination has to exist at the moment the instrument reads.
Both are PITFALLS 5.27 one layer down, and neither was visible without executing the old mechanism.

---

#### 2. FOUR REAL DEFECTS IN MY OWN CODE, found by the review lenses and by mutation

None of these were caught by the correctness suite. All are fixed properly, not annotated.

**(a) The cursor design was silently thrown away.** The first `_allocate` loaded every seat into a
memory array before allocating, so a head-only swap read the entire roster. Measured **98,294 gas at
1 seat -> 215,296 at 50**, linear. **All 31 correctness tests stayed green under it.** Fixed by
driving `Allocation.step` directly over storage with early exit; now flat (97,737 -> 95,220), with a
gas regression test measured under `vm.cool()` per LAW 4, confirmed to go red against the old draft.

**(b) Dust swaps were bricked.** Deriving the direction from the SIGN of the balance delta reads it
backwards when the output leg rounds to exactly zero. **Measured: 1, 2 and 3 wei on a 0.30% pool
reverted `DirectionMismatch`** — swaps v4 itself accepts. Fixed by taking the direction from
`params.zeroForOne` and handling the degenerate fill explicitly: the input is still owed to the
queue, so it is credited to the seat at the cursor. Dropping it would leave the ledger UNDER-counting
the position — the same strand-value-owed-to-nobody pathology as the fee under-credit.

**(c) `seed()` and `redeemAll()` were PERMISSIONLESS on the production hook.** `seed()` funds the
position from the hook's OWN balance, so the first caller of a pre-funded deployment would claim the
entire queue for free; `redeemAll()` burns the whole position and anyone could call it. Both moved to
`test/queue/QueueHarness.sol`. **The shipping contract now has no permissionless state-changing
entry point at all** — only `unlockCallback` (guarded to PoolManager) and five views.

**(d) Settlement ignored ERC20 return values.** Replaced the hand-rolled `IERC20Minimal.transfer`
with v4's `CurrencySettler` (SafeERC20). Also fixes native-currency support and a
`-type(int128).min` negation. `forge lint src/` is now clean.

---

#### 3. THE MUTATION FINDING THAT MATTERS MOST — a paired-branch asymmetry

The cursor pull-back exists **twice**, once per direction. Mutating them separately:

- deleting `if (start < cursor1) cursor1 = start;` -> caught by **7 tests**
- deleting its mirror `if (start < cursor0) cursor0 = start;` -> caught by **ZERO**

Every scenario happened to END on the reverse leg, so cursor0 never got the chance to lead. A
suite can cover one half of a symmetric rule perfectly and the other half not at all.
`test_invariantC_cursor0IsPulledBackAfterAReverseFill` closes it and is confirmed red against that
mutation. **Standing rule (PITFALLS 5.37): when a rule appears once per direction, mutate BOTH.**

**Nine production mutations run in total**, every one confirmed red: remainder line, underflow guard
(library AND hook — separate lines, one test each), cursor advance, both pull-backs, fee not netted,
window snapshot zeroed, dust credit dropped, array preload.

---

#### 4. Corrections made to the plan, because the code is the evidence

- **§B.2** — permissions gain `beforeSwap`; address low bits `0x0840` -> `0x08C0`.
- **§E.5** — REWRITTEN. It instructed the next agent to derive the fee arithmetically, which is now
  the wrong instruction. Deleted rather than annotated.
- **§D.3 N5** — predicted "conservation, immediately". **Wrong.** An external LP does NOT break
  ledger conservation: the fixture's expected totals and the hook's credit both move by the whole
  swap. What breaks is SOLVENCY (`redeemAll()`). LAW 3's second corollary again.
- **§D.3 N1/N2/N4** — predicted reasons corrected to the observed ones. N4 fires one swap EARLIER
  than predicted and on INVARIANT C rather than composition, which is the better outcome.

---

**Decisions taken (implementation-level, per the owner's 2026-08-27 authorisation):** add the
`beforeSwap` permission; transient snapshot over persistent counter; revert rather than clamp on
`pfDelta > amtIn`; credit the degenerate fill to the cursor seat; move scaffolding to a test harness;
`CurrencySettler` for settlement. None changes who receives fees or how seats are allocated.

**Nothing escalated. No admin function, no privileged role, no off-chain component, no upgrade path.**

**NEXT ACTION — Phase 2 (§C.2): deposit / withdraw, the float, and `sweepFloatIntoPosition()`.**
Carried in: INVARIANT F is already declared next to `float0`/`float1` and asserted at zero, so
Phase 2 cannot break it silently. `withdraw` MUST decrement `liquidity` (PITFALLS 5.23 — §B.7 never
does). The deposit-remainder question (5.24) is still open and is the owner's call.

**STILL TRUE AND STILL UNADDRESSED:** full-range depth (5.17) is the sharpest unanswered attack and
appears in no document. It is a business/pitch question, not a correctness one.

---

### 2026-08-27 — PHASE 0 GREEN. Reference spike reproduced EXACTLY; suite survived two fresh mutations

**PHASE 0 IS COMPLETE. All six exit criteria (PLAN §C.0) met. Gate §D.2 passes.**

Toolchain entry criteria verified before anything else: `forge 1.5.0-stable`, commit SHA
`1c57854462289b2e71ee7654cd6666217ed86ffd` — the exact SHA §A.8 records. `foundry.lock` revisions
unchanged, `lib/` complete (forge-std, hookmate, uniswap-hooks). No submodule init needed.

Copied per §A.9 into the live tree (previously `test/` did not exist at all):
`test/utils/BaseTest.sol`, `test/utils/Deployers.sol`, `test/spike/QueueAllocator.t.sol` —
`diff -q` confirms `QueueAllocator.t.sol` is **byte-identical to the archive copy**. `src/queue/`
and `src/queue/libraries/` created empty. **No mechanism code written.**

```
forge test --match-path "test/spike/QueueAllocator.t.sol" -vv
9 passed; 0 failed; 0 skipped
```

| # | Exit criterion | Result |
|---|---|---|
| 0.1 | 9 pass / 0 fail | ✅ |
| 0.2 | Conservation exact to the wei | ✅ queue totals == PoolManager-measured, both tokens |
| 0.3 | Three controls red, each with its exact reason | ✅ `swap1: entry a0` ×2, `swap2: token0 conservation` |
| 0.4 | Gas table within ±2% | ✅ **exact**: 31,864 @1 seat, 31,874 @2–50 |
| 0.5 | Residual −1/−1 @0 swaps, −52/−54 @200 | ✅ **exact**, and −3/−4, −2/−3, −9/−11, −46/−50 @0-fee all exact |
| 0.6 | State why FLOOR_ONLY survives swap 1 | ✅ below |

**Every single §D.2 number reproduced identically — not "within tolerance", identical.** Nothing to
escalate under §C.0's divergence rule.

**0.6 — why the FLOOR_ONLY control survives swap 1, in my own words.**
The mutation deletes the remainder line, so *every* filled entry gets the floored proportional share
`mulDiv(amtIn, take_, amtOut)` instead of the last one absorbing `amtIn − assignedIn`. Swap 1 is the
**head-only** swap: the head's balance exceeds the whole output, so `take_ = remaining = amtOut` on
the first and only iteration. The share is therefore `mulDiv(amtIn, amtOut, amtOut)` — a fraction of
**exactly one**, which floors to `amtIn` with **zero** rounding loss. Mutant and original are
bit-identical whenever a single entry absorbs the entire swap. Swap 2 sweeps three entries; each
`take_` is now a proper fraction of `amtOut`, each `mulDiv` floors downward, and the sum of the
floors is strictly less than `amtIn`. The lost wei are credited to nobody, the hook's totals fall
below the PoolManager-measured totals, and it dies on `swap2: token0 conservation`.
**The generalisable lesson — and it is this project's doctrine (PITFALLS 5.27) restated:** a
one-seat fixture is the degenerate case where floor == exact. It is structurally incapable of
observing this bug class. Multi-seat sweeps are not a nice-to-have in Phase 1; they are the only
configuration in which the remainder line is observable at all.

**LAW 5 applied beyond the built-in controls.** The three negative controls were written by the same
author as the code they check, so passing them is weak evidence. I wrote two mutations the author did
not anticipate, ran them, and restored:

| Mutation | What it does | Result |
|---|---|---|
| MUT-A | `_apply`: credit `give` to the **wrong token leg** (`q[i].a1 += give` under `outIsOne`) — a unit-mixing bug | **7 of 9 red.** Positive control fired `unmutated harness failed: the controls prove nothing` |
| MUT-B | `_allocate`: head **under-fills by 1 wei** whenever it does not exhaust the swap | **4 of 9 red**, on `entry a0` / `loop: entry a0` |

Restored byte-identical afterwards; suite green again. The suite can go red, and does.

**Three findings from the mutation run that are NOT in any document — all now in PITFALLS §1/§5:**

1. **`test_Q2_gasProfileVersusQueueDepth` passed under BOTH mutations.** The gas test is entirely
   correctness-blind, and `test_Q1b_residualWithZeroSwaps` never invokes `_allocate`. So "9 passed"
   overstates the correctness surface: only **6** of the 9 tests carry arithmetic signal, and only
   **4** of those exercise a multi-seat sweep. Do not quote "9 tests" as 9 units of assurance.
2. **Conservation did NOT catch MUT-B; the independent reference allocator did.** A misallocated wei
   stays inside the queue, so aggregate totals still tie out — only per-seat composition moves. This
   is LAW 3's second corollary landing on the allocator: **conservation and composition are two
   different claims needing two different assertions.** Phase 1 MUST carry its own independently
   written `_refAllocate`; conservation alone leaves a whole bug class invisible.
3. **The spike's conservation harness is the BLIND raw-balance form** (LAW 3 pre-amendment). It is
   valid here only because `protocolFeesAccrued == 0` — and the spike never asserts that it is zero.
   **If Phase 1 is built by copying this harness, it inherits the blindness**, which is precisely the
   §E.5 trap. Phase 1 must measure against `balance − protocolFeesAccrued(currency)` (or `redeemAll()`)
   *and* assert `protocolFeesAccrued > 0`.

**LAW 1 is only half-satisfied by the spike fixture.** Price is 1:4 (guarded by
`require(s0 != s1, "fixture is unit-priced")`) — good. But `Deployers.deployToken()` hardcodes
**18 decimals for both tokens** (`Deployers.sol:38`), so the unequal-decimals half is untested here.
`docs/research/withdrawal/FloatWithdraw.t.sol` already runs 18/6. **Phase 1 must use 18/6**, not
inherit 18/18 by copying the spike's `setUp`.

**Panel review** was run inline by me across the §5 lenses rather than by spawning sub-agents — the
owner's session instruction this session was not to spawn agents. Findings 1–3 above and the decimals
gap are its output. Nothing else surfaced at Phase 0; there is no mechanism code to attack yet.

**Decisions taken:** none that touch economics or security. Nothing escalated.

**NEXT ACTION — unchanged and now unblocked: Phase 1, but its first task is the P2 replacement
(PITFALLS 5.25/5.26), not the allocator.** The allocator arithmetic is proven and reproduces; the
protocol-fee mechanism in front of it is the thing that does not exist. Also still owed:
`sweepFloatIntoPosition()` (5.21), the `liquidity`-decrement correction to §B.7 (5.23), and the
**owner decision on the deposit remainder** (5.24 — refund vs absorb into float; ASK, do not decide).

---

### 2026-08-26 (session close, final) — P2 + float COMPOSE; but P2's IMPLEMENTATION is DEFECTIVE

Ran while the harness was warm, to close the last untested composition before any build.
Evidence: `docs/research/withdrawal/fee-float-composition.md` + `FeeFloatComposition.t.sol` —
**19 tests, re-run independently by the orchestrator, 19/19 green.**

**GOOD NEWS — the two designs compose. INVARIANT F survives a MAXIMUM protocol fee:**
residual **0 wei** in the balance form, **3–8 wei** against raw ledger — *the same bounds the fee-off
suite already reports*. **The residual does NOT scale with the fee:** the fixture accrued 3.54e17 /
2.0e16 wei of protocol fee — ~17 orders of magnitude above the residual — and the residual did not
move. Dust policy unchanged by the fee. Withdrawal does **not** accrue protocol fees (`test_P4`,
verified in source, not assumed).

**⚠️ BAD NEWS — a CRITICAL defect in P2 itself, and it is a PHASE 1 BLOCKER.**
`poolManager.protocolFeesAccrued(currency)` is **GLOBAL PER CURRENCY, not per pool**
(`ProtocolFees.sol:21` — `mapping(Currency currency => uint256 amount)`, no `PoolId` anywhere).
So the diff `pfNow − pfSeen` **absorbs the protocol fees of every other v4 pool sharing either
currency.** Float-independent; it would have hit Phase 1 in production.

- **X1 — silent under-credit (the EVERYDAY case).** A second pool on the same pair (fee tier 500)
  took 2e15 wei of token0 protocol fee. QUEUE's next swap computed `pfDelta` =
  301999999999999999 instead of its own 299999999999999999 and **under-credited the queue by
  exactly the foreign pool's fee (2e15 wei)** — stranded in the position, owed to nobody.
  **No attacker needed:** ordinary volume on any other pool of the same token does this continuously.
- **X2 — PERMANENT BRICK (the tail case).** If foreign accrual since our last swap exceeds the next
  swap's input, `amtIn -= pfDelta` **underflows inside `afterSwap`** and the swap reverts
  (`Panic(0x11)` in v4's `WrappedError`). **And it is permanent** — the failed swap never advances
  `pfSeen`, so every later swap recomputes the same oversized delta. **The pool is dead.** The
  attacker needs only one other pool sharing the currency with a nonzero protocol fee — the normal
  state for any listed token — and one swap on it.
- `pfSeen0/1` start at **0** at construction, so a currency already carrying accrued fees
  **bricks or mis-credits the hook's FIRST EVER swap.**

**HOW THIS GOT PAST US — record it, it is the project's own doctrine biting.** The `test_M3`
mutation that "MEASURED P2 closing the gap to 3 wei" ran in a **single-pool fixture**. The mechanism
was never wrong about *what* to subtract; the **instrument for measuring it** was wrong, and the
fixture could not see it. **A green test in a fixture with only one pool proved nothing about a
global counter.** LAW 5 territory: the pass was the harness, not the code.

**WHAT STANDS AND WHAT DOES NOT:**
- ✅ **The DECISION stands** — net out the protocol fee so the ledger credits only what the position
  received. P1 (refuse) is still rejected for the Proposal-100 reason.
- ❌ **The MECHANISM does not.** Do NOT ship `pfNow − pfSeen` on the global counter.
- **Follow-up REQUIRED before Phase 1, and it is NOT easy — it needs its own experiment and its own
  negative control.** Derive the protocol fee arithmetically from the swap rather than diffing a
  global counter, but note: `lpFee == 0` takes the ENTIRE `feeAmount` by a different formula
  (PITFALLS §1.5); exact-out rounds the other way (§1.12); and `amountToProtocol` is summed
  **per swap step** with per-step rounding across tick crossings — so a one-line
  `amtIn * pf / 1e6` will **not** be wei-exact. **Clamping `pfDelta` to a locally-derived upper
  bound removes the BRICK but not the UNDER-CREDIT.**

**Negative controls held:** NC-1 (netting removed, fee on) went RED with INVARIANT F slack
`−353999999999999999` / `−20000000000000000` — **exactly `protocolFeesAccrued`, asserted with
`assertEq`** — and the last withdrawer reverting `FloatShort` short 354000000000000003 wei, i.e.
4.4e16× the 8-wei bound. NC-2 (fee = 0 + float) reproduced the 22-test float suite exactly.

### 2026-08-26 (session close) — HAZARD 5.5 SETTLED: per-seat withdrawal is FEASIBLE

**The one finding that could have killed the product is closed.** Run in-session rather than deferred,
because the resolution changes Phase 1's state layout. Evidence:
`docs/research/withdrawal/feasibility.md` + `FloatWithdraw.t.sol` — **22 tests, re-run independently
by the orchestrator, 22/22 green**, including 8 negative controls, 2 attack tests, an asymmetric-
decimals (18/6) case and conservation under LAW 3 AS AMENDED.

**VERDICT: FEASIBLE-WITH-CAVEATS.** A **two-slot shared float** lets `withdraw()` pay any seat its
exact ledger composition — including a **100%-converted seat** — with **no `poolManager.swap`**, in
any withdrawal order, at 1:4 and at 18/6 decimals, **zero conservation slack, 252,672 gas cold**.

**INVARIANT F (PROVEN) — the fact that makes it work:**
`Σ q[i].a0 == redeemable token0 + float0`, likewise token1, to within the §E.4 residual (≤8 wei).
The aggregate is consistent; only the **per-seat composition** is unpayable from a proportional
liquidity removal. That is why a shared float is sound and first-come-first-served payment is safe.

**⚠️ THE ORIGINAL PROBE WAS READING THE WRONG NUMBER — correct the record.** The apparent 1.062e18
"gap" was `LiquidityAmounts.getAmountsForLiquidity`, which returns **principal only** and does not
know about accrued LP fees. Cross-check, exact to the wei: gap on token0 = 1062000000000000003 vs
LP fee earned = 1062000000000000000 = **0.30% × 354e18**; token1 gap 60000000000000003 vs
60000000000000000 = 0.30% × 20e18. **There was never an aggregate shortfall.** The per-seat
composition problem was real; the solvency scare was an artefact of measuring principal.

**STATE TO ADD — this is what had to be known before Phase 1 (PLAN §B.3):**
```solidity
uint256 internal float0;   // token0 held OUTSIDE the position, owed to the queue
uint256 internal float1;   // token1 held OUTSIDE the position, owed to the queue
```
Plus two corrections: **(a) `withdraw` MUST decrement `liquidity` by Δ** — §B.7 never does, and every
later sizing computation is wrong without it. **(b) INVARIANT F must sit next to the declarations in
§B.3.** `pendingWithdraw0/1` is unrelated and does not serve this purpose.

**THE ALLOCATOR IS UNCHANGED — PROVEN.** `_allocate` is character-for-character the spike's
FRONT_FIRST path. The float touches **withdraw** only, and is structurally *safer* for the allocator.
⇒ **Phase 1 is unblocked and its arithmetic is unaffected.**

**NEW OPEN ITEM, and the biggest gap in this result: `sweepFloatIntoPosition()` is REQUIRED and
UNBUILT.** Permissionless, no privileged role: re-add `Δ' = min(float0/f0, float1/f1)` of liquidity,
credit nobody, decrement both floats by actual consumed amounts. **Without it, pool depth degrades
monotonically as seats withdraw imbalanced legs.** UNPROVEN — not written, not tested.

**OWNER DECISION NEEDED (AGENTS.md §4 — it changes who gets what):** on deposit, §B.7 says *"refund
any unconsumed remainder to msg.sender"*. Under a float the better answer is to **absorb the
remainder into `floatX` and credit it to the seat** — cheaper, and it reduces the float. Not built,
not tested. **Ask before implementing.**

**Dust policy — choose F1.** Measured both branches: exact payout ⇒ the last withdrawer **reverts
`FloatShort`, short 3 wei** (NC-F); F1 (`pay min(face, available)`) ⇒ everyone drains, 3–8 wei of
ledger dust unpaid. **The float does NOT solve §E.4** — orthogonal, still open, and *"face value is
redeemable"* still must not be claimed.

**Still UNTESTED:** protocol fee ≠ 0 interacting with the float (everything above ran at
`protocolFeesAccrued == 0`, asserted — the amended LAW 3 form is used but inert); the
sandwich-the-withdrawal sizing attack (REASONED only); `lpFee == 0`; deposit-side float absorption.

### 2026-08-26 (later still) — PREMISE REVIEW: the mechanism is SOUND; two sharper holes found

**Owner asked:** is the hook fair, does the niche make sense, would deploying it be embarrassing.
**Answer: the premise holds, front-first is defensible, and the real risks are elsewhere.**
Full reasoning: `docs/research/premise-review/economics.md`, `.../fairness.md`. Ledger: `PITFALLS.md`.

**1. The orchestrator's own attack on the premise was REFUTED — record it so it is not re-litigated.**
The attack: *"a CLOB seat is valuable because you can CANCEL; QUEUE cannot cancel or detect toxic flow,
so the front seat eats adverse selection and rank is worth negative."* **Wrong, for a precise reason:
a CLOB order rests at a FIXED price; a QUEUE seat has no price of its own.** Every seat filled by a
swap is filled at that swap's realised average price (`PLAN.md:503`) — front and tail get IDENTICAL
execution, only quantities differ. There is no stale quote, so there is nothing to cancel. Front-of-
queue buys **priority over QUANTITY, not priority at a stale PRICE.** [REASONED, confidence HIGH]

**2. The leverage identity — write it into BUSINESS.md, it is the answer to "why buy a seat".**
`L(s) = (C/c1) * min(1, c1/s)`. The front seat is levered on everything, and **most levered on SMALL
swaps** (decaying as `C/s` above head size). BUSINESS.md's own two worked examples (§7.1 = 50x,
§7.3 = 3.34x) are special cases of this formula — **the doc never wrote the formula down.**
⇒ **QUEUE is a LEVERAGE instrument on the pool's own LP return**, bounded downside per trend,
unbounded round-trip upside. This is a better and more defensible pitch than "the seat price is the
toxicity", which is **overclaimed** (it measures leverage x LP return — computable from public swap
data — and Harberger censors the signal at zero on exactly the toxic side).

**3. THE FAIRNESS THEOREM — the decisive answer, and it is free.**
**QUEUE is exactly ZERO-SUM against pro-rata.** Therefore the tail's excess return over pro-rata has
the **opposite sign to the pool's own net LP P&L**:
- profitable pool ⇒ **tail strictly worse off** than a plain v4 LP;
- loss-making pool ⇒ **tail strictly better off**.
**Both seats cannot beat pro-rata. No ordering, banding, rotation or partial blend can change that.**
⇒ **Fairness in QUEUE is not an allocation problem, it is a TRANSFER problem** — and the design
already names the transfer: sell or rent the rank. *(The owner's prior "the tail is fine, it eats less
toxicity" is half right — true only in the loss-making regime. The docs' only two worked examples are
both drawn from that regime, which is why the prior survived.)*

**4. ⚠️ THE SHARPEST UNANSWERED ATTACK — full-range capital efficiency. NOT IN ANY DOC.**
The hook mints **one full-range position** (`PLAN.md:64,:325`). A full-range CPMM offers roughly
**1/200th the depth per dollar** of a +/-1% concentrated position. **A $1M full-range QUEUE pool quotes
about the depth of a ~$5-10k concentrated position next door; a $10k swap costs ~4% slippage.**
⇒ no aggregator routes retail to it; retail is the ENTIRE benign side of the P&L; kill it and the pool
is arb-only, LP return goes negative, and the front seat earns `C/c1 x` a negative number.
**The feared inversion IS real — but the cause is full-range-ness starving the pool of benign flow, NOT
front-first allocation.** It is a reversible design choice, not a v4 constraint. **This is the single
most likely question from a v4-native judge and the repo has no answer.** [ANALYSIS]

**5. THE RATCHET — a structural asymmetry named nowhere in the docs.**
Front-first applies in both directions, so the **head unwinds first**: the head is a market maker with
recycling inventory, **the tail is a one-way accumulator, filled at extremes with no priority to exit.**
Severity moderate, not fatal (the tail can withdraw + re-deposit; rank survives per §B.7) — but it is
**a cost of active management imposed on the party the pitch calls passive** ("treasury, LST issuer,
yield vault"). A real contradiction in the sales story; say it out loud. Only B-2 addresses it.

**6. Phase 3 (the SUBMITTABLE state) is a ONE-SIDED MARKET.** The tail's compensation channel is
Harberger rent = **Phase 4**. In Phase 3 the honest answer to *"why would anyone hold seat 5?"* is
**"they wouldn't."** ⇒ **Phase 4 is not optional for the rank-then-run hole alone — it is what makes
the tail's participation rational at all.** In Phase 3 the transfer channel is a secondary market that
`BUSINESS.md` §9.7 **already concedes does not exist.** The tail's deal is sound in theory, empty in
the demo.

**DECISION (orchestrator, panel-backed): BUILD PHASES 0 -> 3. BUILD NO NEW FAIRNESS MECHANISM.**
Ship the Fairness Theorem as an *argument*, not as code — it is stronger than any mechanism and costs
zero engineering days. A panel that answers "is it fair?" by building a fairness mechanism has already
lost the point. **What actually moves value to the tail, all already scoped:** (1) **P2** — worth ~33%
of the tail's fee income at max fee, Phase 1, **the highest-value fairness action available**;
(2) **F1** settle withdrawals against actual holdings, Phase 2; (3) **resolve per-seat withdrawal
feasibility — a Phase 2 BLOCKER, not a nicety.**

**GATE for anything new:** only if Phase 3 is green with real time to spare — then ONE of **B-1
Harberger** (answers fairness, closes rank-then-run) or **B-2 two-sided rank** (order-only, so it
inherits the allocator's proven conservation for free; fixes the ratchet; genuinely novel — nothing in
the 662-row hook directory has it). **Otherwise build nothing new: a half-built Harberger on an
unfinished allocator scores WORSE than zero — it takes Functionality (15%) and Unique Execution (25%)
down with it.**

**KILLED — do not revisit (reasons in `docs/research/premise-review/fairness.md`):** B-4 partial
front-first (pro-rata in a fairness costume; killed on gas) · B-5 banded queue (costs the most
defensible property, buys the tail nothing) · **B-6 rank decay/rotation (FATAL — rank becomes free by
waiting)** · B-7 minimum fill guarantee (fatal) · B-8 distance-weighted rent · B-9 genesis auction
redistribution (no mechanism to build; retained only as a disclosure obligation).

### 2026-08-26 (later) — PLAN §E.5 protocol-fee hazard CLOSED BY MEASUREMENT (research only, no mechanism code)

**Owner directive:** research the §E.5 protocol-fee hazard before building, and scrap the project if
the evidence is bad enough. **Verdict: the hazard is REAL and large, but it does NOT kill QUEUE.**
Do not scrap. Evidence: `docs/research/protocol-fee/` (VERDICT.md, experiment.md, v4-mechanics.md,
queue-exposure.md, raw forge output) + `archive/2026-08-26/test/spike/ProtocolFeeHazard.t.sol`.

**What is now PROVEN (executed, reproduced independently by the orchestrator, 7/7 with mutations):**

| Claim | Status | Evidence |
|---|---|---|
| The swap delta a hook reads is **NOT** net of the protocol fee, but the LP position **is** | **PROVEN (source)** | `Pool.sol:369-381` computes the swapper delta from `amountIn+feeAmount`; `:384-396` skims after; `:398-403` credits fee growth from the reduced amount |
| The spike sits in exactly the vulnerable configuration | **PROVEN (source)** | real LP position at spike `:127` `modifyLiquidity`; ledger credited from the swapper delta at `:153,:169-171` |
| Max protocol fee = **0.1% of swap amount**, per direction; new pools start at 0 | **PROVEN (source)** | `ProtocolFeeLibrary.sol:8,:15`; `Pool.sol:105` |
| At max fee the queue is short **0.354e18 token0 / 0.02e18 token1** over the 4-swap scenario | **MEASURED** | `test_E1_maxProtocolFee_breaksTheLedger` |
| The shortfall equals `protocolFeesAccrued` exactly, +3 wei of known §E.4 residual | **MEASURED** | experiment.md F2 |
| Magnitude = **0.1% of input = 33.4% of the LP's entire fee income** (`1000/(3000x0.999)`) | **MEASURED** | experiment.md §4 |
| It leaks at the **minimum 1-pip fee too** — not a max-fee artefact | **MEASURED** | `test_E2_oneWeiPipProtocolFee_alsoLeaks` |
| **P2/P3 (net out `protocolFeesAccrued`) closes the gap to 3 wei**, ~10 lines + 1 SLOAD | **MEASURED** | `test_M3_mutation_P2NettedAllocatorClosesTheGap` |
| Remedy P1 (revert in `_afterSwap`) **cannot block withdrawals** | **PROVEN (structural)** | permissions are only `{beforeAddLiquidity, afterSwap}` (spike `:59-63`); withdrawal is `unlock()->modifyLiquidity(negative)` (`:119,:124-131`), unhooked |

**THE MOST DANGEROUS FINDING — a standing correction to LAW 3, project-wide:**
`protocolFeesAccrued` money **stays inside PoolManager's ERC20 balance** until collected. So the
spike's conservation test — the project's own LAW 3 measurement — **passes at 0 wei error while the
position is short 0.354 token0.** The existing suite could never have found this.
**Conservation must henceforth be measured on `PoolManager ERC20 balance - protocolFeesAccrued(currency)`,
never on the raw balance.** Any test written the old way is blind to every protocol-fee-shaped bug.

**TWO FINDINGS THAT REVERSE PLAN'S P1 RECOMMENDATION (added after the adversarial pass):**

1. **PLAN's own §E.5 test instruction is BLIND to the bug it was written to catch.** `PLAN.md:2092`
   says *"set a protocol fee, run the conservation test."* Executed exactly as written, that goes
   **GREEN** while the position is short 0.354e18 — because `protocolFeesAccrued` is still sitting in
   PoolManager's ERC20 balance. Green there means "unresolved", not "safe". It is a LAW-5 trap of the
   plan's own making. The correct assertion is against `PoolManager balance - protocolFeesAccrued`,
   or directly against `redeemAll()`. PLAN already contains the right instrument (LAW 3's second
   corollary, `PLAN.md:1322-1328`) and simply never wired it to criterion 1.10.
2. **PLAN's stated justification for preferring P1 is factually wrong.** §E.5 argues P1 loses nothing
   *"since we control the pool we deploy."* We control **deployment**, not the **fee** — the
   controller can set it at any time afterwards. P1's cheapness was never in question; its
   justification was.

**P2 is cheaper than previously believed — it needs NO extra hook permission.** The measured M3
implementation keeps a stored running total and diffs `protocolFeesAccrued` inside `_afterSwap`
(legal: credited at `PoolManager.sol:238`, before `afterSwap` at `:221`). So the earlier concern that
P2/P3 required a `beforeSwap` permission — a re-mined hook address and ~15% on the headline gas
number — **is void.** Cost is ~1 SLOAD + 1 SSTORE.

**P1 withdrawal-safety is now PROVEN BY EXECUTION, not just structurally argued:**
`test_E5_P1_refuseInAfterSwap_doesNotBrickWithdrawal` (in `docs/research/protocol-fee/ProtocolFeeExposure.t.sol`,
4/4 green, re-run by the orchestrator). After a refusal the depositor still withdraws in full.
**But placement is load-bearing: if the check ever moves into a shared modifier or the removal path,
a governance fee-set becomes total permanent loss of funds.** A negative control proving withdrawal
still works with the fee on is mandatory in Phase 1.

**P2 edge case that must be handled or refused:** `lpFee == 0` ⇒ `swapFee == protocolFee` ⇒ v4 takes
the *entire* `feeAmount` via a different formula (`Pool.sol:391-392`). Dynamic-fee/`lpFeeOverride` is
NOT a risk (QUEUE has no `beforeSwap` permission). Exact-output swaps need no special handling.

**Decisions taken:**
- **Do not scrap.** The hazard is bounded (0.1% ceiling), detectable in one `extsload`, and has a
  measured fix. It is a real bug with a cheap fix, not a design flaw.
- **✅ OWNER DECISION 2026-08-26: ship P2 (account for it).** Net out `protocolFeesAccrued` in
  `_afterSwap`; do NOT ship a refusal. Rationale below. Phase 1 implements it; acceptance 1.10 is
  satisfied by the netted allocator plus the corrected assertion, not by a refusal.
  **Consequence to remember:** with P2 the ledger no longer over-credits, so the "33% of LP income"
  figure and the "tail eats the shortfall" behaviour BOTH disappear — they were artefacts of the bug,
  not properties of the mechanism.
- *(superseded context)* P1 vs P2 was an open owner decision. The evidence moved against PLAN's P1
  recommendation: P1 hands the PoolManager owner's controller a permanent off-switch for the product,
  and its stated justification is wrong. P2 is measured, needs no extra permission, and keeps the pool
  trading under any fee. **Escalated to the owner per AGENTS.md §4 (a choice that changes the
  mechanism's economics/security).** Whichever is chosen, the check must be re-read PER SWAP.
- Acceptance criterion **1.10's assertion must change** — against `PoolManager balance -
  protocolFeesAccrued`, or `redeemAll()`. As written it cannot fail.
- Acceptance test 1.10 **must assert `protocolFeesAccrued > 0`** or it proves nothing —
  `setProtocolFee` silently no-ops for a non-controller caller.

**⚠️ THE FEE SWITCH IS REPORTEDLY ALREADY LIVE — this is no longer a hypothetical contingency.**
*(WEB-SOURCED, crypto press only, NOT verified on-chain or from source. Treat as a strong prior, not
as fact. Sources in `docs/research/protocol-fee/v4-mechanics.md` §9.)*
- Uniswap **Governance Proposal 100 reportedly executed 2026-07-27** — one month ago — activating v4
  protocol fees on Ethereum, Arbitrum, Base, BNB, Polygon, OP Mainnet and others.
- Reported magnitude **~1/6 of the swap fee (~5 bps on a 30 bps pool)** = ~500 pips, **half the legal
  maximum**. **Independent consistency check: that "1/6" matches the code's own arithmetic exactly**
  (`500/(3000x0.9995) = 16.7%`), which materially raises confidence in the reporting.
- Mechanism: a `V4FeeAdapter` registered as `protocolFeeController` + a `V4FeePolicy` classifying pools.
  **Hook pools are reportedly excluded FOR NOW**, but classification is a governance-permissioned role
  via `setHookFamily` / a `pairClassFees -> familyDefaults -> defaultFee` waterfall, and **no opt-out for
  hook developers exists** — which is exactly what the code says (there is no on-chain opt-out).
- **Consequence for the P1/P2 decision: P1 is no longer a safeguard against a remote contingency. It
  would ship a product whose trading a live, already-executed governance mechanism can halt by
  reclassifying our hook family — with no opt-out and no notice.** This moves the recommendation
  decisively to P2.
- One press claim — *"LP rates are unchanged"* — **is corroborated by our own measurement**, and it
  matters for how we describe the bug: the fee **composes on top of** the LP fee (the swapper pays
  more) rather than splitting it. `test_E5_swapperPaysMore_lpIncomeRoughlyUnchanged` confirms it.
  **So the queue's LPs do not lose a third of their income; the LEDGER over-credits by the protocol's
  share, which is ~1/3 the size of true LP income.** Do not describe this as "LPs lose a third".

**Open / unverified — do not claim:**
- The above is press-sourced. **Verify on-chain before relying on it**: `poolManager.protocolFeeController()`
  and `StateLibrary.getSlot0(poolId)` answer it directly. Exact per-pool values, and whether a hook like
  ours would today be classified into a nonzero family, are UNVERIFIED.
- P1 is a *liveness* surrender: a governance fee-set halts trading until the hook is redeployed.
  Funds stay safe and withdrawable. Accepted consciously; revisit if P2/P3 is built.

**Housekeeping:** `foundry.toml` gained a `[profile.spike]` (archived src/test paths) so the archived
spike runs unmodified; the default profile is untouched. A subagent had un-ignored two private chat
logs in `.gitignore`; reverted. **No mechanism code written — Phase 0 is still NOT STARTED.**

### 2026-08-26 — design phase closed, build not started
- QUEUE selected after an exhaustive candidate search. Honest score **4.33** on the published rubric.
- Alternatives assessed and rejected with evidence, all archived: a hook-safety/bonding platform
  (sound but unwinnable — the security lane is 0 for 9 across eight cohorts), permissioned pools
  (Uniswap shipped it, hit the same wall we did, zero on-chain adoption), a CPG static-analysis
  product (off-chain, fails the "must be a hook" gate), and four fee-mechanism designs that topped
  out at 3.95.
- **The structural lesson that produced QUEUE:** every earlier candidate was a *fee mechanism* —
  it answered "who pays and how much". Winners in this competition **mint a new tradeable object**.
  That reframe is what moved the ceiling.
- Repository archived to `archive/2026-08-26/`. Clean ground prepared.
- **Next action: `PLAN.md` Phase 0.** Reproduce the reference spike from
  `archive/2026-08-26/test/spike/QueueAllocator.t.sol` in the new `test/queue/` tree and confirm the
  three negative controls still go red. **Do not write new mechanism code until that is green — and
  do not trust it green until the controls are red.**
