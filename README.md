# QUEUE — subordination for Uniswap liquidity

**A Uniswap v4 hook that gives the LPs funding one position a RANK, and fills them in order
instead of pro-rata.**

```
  tests            319 passed · 0 failed · 1 skipped   (real v4 contracts, nothing mocked)
  source           1,047 lines of Solidity + 2,534 lines of commentary
  status           NOT AUDITED. Testnet only. No mainnet deployment.
  written for      Uniswap Hooks Incubator
```

> **Written from scratch 2026-09-03 (Phase 12).** The previous README is preserved at
> `archive/2026-09-03/README-pre-phase-12.md` and is **superseded, not a second opinion** — it was a
> Phase-9 correction banner bolted over a Phase-4 body, and the banner had come to contradict the
> body on gas, roster size, test counts and the value claim. This project's convention is that two
> live answers in one file is worse than a rewrite.

**Read `BUSINESS.md` for the full business case and every dollar figure.** This file is the
high-level tour: what it does, what every parameter means, what we tested, and how to run it.

---

## 1. THE WHOLE IDEA IN ONE PICTURE

```
   TODAY — every concentrated AMM, no exceptions
   ─────────────────────────────────────────────────────────────────────────
     a trade arrives
          │
          ▼
     ┌──────────────────────────────────────────────────┐
     │  ONE POSITION — everybody filled PRO-RATA         │
     │   LP A ▓▓▓▓▓▓  LP B ▓▓▓▓  LP C ▓▓  LP D ▓         │
     │        ↑ every trade takes a slice of each ↑      │
     └──────────────────────────────────────────────────┘
     You cannot opt out, go first, or go last. One fill quality, for everyone.


   WITH QUEUE — same pool, same router, same 0.30% fee
   ─────────────────────────────────────────────────────────────────────────
     a trade arrives
          │
          ▼
     ┌──────────┐   ┌────────┐   ┌──────┐   ┌────┐   ┌──┐
     │  RANK 1  │──▶│ RANK 2 │──▶│RANK 3│──▶│ R4 │──▶│R5│
     │ 33% of   │   │        │   │      │   │    │   │  │
     │ the book │   │        │   │      │   │    │   │  │
     └──────────┘   └────────┘   └──────┘   └────┘   └──┘
      filled by       reached      rarely     almost never
      ~96% of all     by large     reached    reached
      trades          trades

   THE TRADER SEES NOTHING. Same price, same fee, any router. What changed is
   WHICH LP inside the position ate that trade.
```

### What is genuinely new, stated precisely

Uniswap already sells **distance from spot** — liquidity near the price fills first and worst,
liquidity far away fills rarely and best. The tick structure gives you that for free.

> **QUEUE is the first mechanism that orders LPs *inside one position, at one distance*.** That
> ordering is what makes contract-enforced subordination possible: one LP takes structurally worse
> fills so another gets structurally better ones, executed inside `swap` — no payment step anyone
> can withhold, no keeper to fund, no vote to reverse.

---

## 2. THE HONEST HEADLINE — read this before anything else

**It is a transfer, not creation.** The seats share one Uniswap position, so:

```
     Σ (capital share of seat i) × (return of seat i)  ==  passive LP return
                                             measured residual: 2.98e-14
```

One seat above the line requires another below it by exactly as much. **No configuration, no
ordering rule and no premium rate changes this.** We tried; five pre-registered theses died and the
numbers that killed them are in the repo.

**And a second thing that surprises people:** with the premium dial OFF, the front seat is the
*best* seat in calm markets — it is filled by ~96% of trades, so it earns +14.7% against a plain
LP's +5.02%. **Being first is only bad in a crash.** The premium φ is what converts the front's
calm-market advantage into a subsidy for everyone behind it. See `BUSINESS.md` §6B.

---

## 3. WHO EARNS WHAT — the short version

Benchmark throughout: **the same capital in an ordinary pro-rata Uniswap position, same pair, same
band, same path.** Benign regime, 61-day band, φ = 5,100.

```
  ┌────────┬───────────┬────────┬────────────┬──────────────────────────────┐
  │  SEAT  │  CAPITAL  │  RATE  │ vs PLAIN LP│  WHAT YOU ARE BUYING         │
  ├────────┼───────────┼────────┼────────────┼──────────────────────────────┤
  │ RANK 1 │  $333,333 │ +3.28% │   -$5,800  │ FIRST-LOSS. Highest fee      │
  │        │           │        │            │ turnover, worst prices, pays │
  │        │           │        │            │ the coupon backward.         │
  ├────────┼───────────┼────────┼────────────┼──────────────────────────────┤
  │ RANK 2 │  $266,667 │ +5.50% │   +$1,280  │ MEZZANINE. Real stress       │
  │        │           │        │            │ exposure — the thin margin.  │
  ├────────┼───────────┼────────┼────────────┼──────────────────────────────┤
  │ RANK 3 │  $200,000 │ +5.90% │   +$1,760  │ SENIOR. Coupon on capital    │
  │ RANK 4 │  $133,333 │ +6.00% │   +$1,307  │ that is rarely reached, and  │
  │ RANK 5 │   $66,667 │ +6.10% │     +$720  │ spared entirely in a crash.  │
  └────────┴───────────┴────────┴────────────┴──────────────────────────────┘
   ~6 benign bands a year → ranks 2-5 earn +2.9% to +6.5% a year MORE than
   the pool next door. Paid by a named counterparty who volunteered, not by
   a token print.
```

**Full table, all three regimes, the toxic caveat and the annualisation assumptions:
`BUSINESS.md` §6B.** The one number to carry: in the toxic regime rank 5 "beats" a plain LP by
**not being filled at all** — that is capital preservation, not yield, and `BUSINESS.md` says so.

---

## 4. EVERY PARAMETER, EXPLAINED

All are **immutable**, set once in the constructor. There is no admin function, no upgrade path and
no privileged role.

| parameter | shipped | what it is | what moving it does |
|---|---|---|---|
| `foundingRoster` | 5 addresses | who holds the seats at deployment, in rank order | the roster is **closed** — there is no `mint`. Capital joins by funding an existing seat or buying one |
| capital weights | `5:4:3:2:1` | how the book is split across the seats | this sets `c₁`, the head share, which is **the dominant economic parameter** — see §5 |
| `BAND_HALF_WIDTH` | ±10% | the tick band the single position occupies | narrower dies faster; band width dominates every other economic parameter and must be sized to the pair |
| `FEE` / `SPACING` | 0.30% / 60 | the pool's own fee tier | unchanged from a normal pool; traders pay exactly what they would |
| `PREMIUM_BPS` (φ) | **5,100** | the share of the LP fee that filled seats hand BACKWARD | the subordination dial. φ=0 → the front is the best seat. φ high → the front subsidises everyone behind it |
| `RENT_BPS` (τ) | **1,000** (10%/yr) | Harberger rent on each seat's own posted self-price | this is how the front gets PAID for the protection it supplies. Flows **forward** |
| `RENT_PERIOD` | 365 days | the period τ is quoted against — seconds, never blocks | block times differ by chain; a block-denominated rate changes meaning on redeployment |
| `FIRM_WINDOW` | 1 hour | how long a posted price stays binding after you change it | stops a holder repricing out of a buyout they can see coming |
| `MIN_TENURE` | **7 days** | the TERM — how long a seat may not voluntarily give up its rank | this is what stops a seat being dropped the moment toxic flow arrives. See §7 |
| `MAX_SEATS` | 32 | a **structural** ceiling — one byte per rank in one 32-byte word | ⚠ this is a storage fact, **not an economic endorsement**. See §5 |

### The two dials that decide the product

```
   φ  (PREMIUM_BPS)  =  HOW MUCH the front hands backward
                        skimmed from swap fees → scales with VOLUME
                        → powerless in a crash, where volume collapses

   τ  (RENT_BPS)     =  WHAT THE BACK PAYS the front for standing there
                        accrues in elapsed time  → scales with TIME
                        → the only channel that survives when trading stops
```

**φ was solved, not swept for a nice number.** Two constraints: the back needs φ high enough to beat
a passive LP (≥ 4,542); the front needs φ low enough to still beat its own cheapest alternative, a
keeper-managed at-the-money range (≤ 5,670). Shipped at the midpoint of `[4542, 5670]`.

---

## 5. WHY FIVE SEATS — and is that realistic?

**Yes, and it is not a demo shortcut: five is near the measured maximum.** Source:
`docs/research/seat-economics/results-depth-basis.txt`.

```
   N     head    BENIGN window    NORMAL window   TOXIC window   binding seat
   ─────────────────────────────────────────────────────────────────────────
    2   66.7%   [2104, 9500+]    [788, 9500+]    [0, 9500+]     rank 2   ✓
    5   33.3%   [4542, 5670]     [2565, 6252]    EMPTY          rank 2   ← SHIPPED
    8   22.2%   EMPTY (crossed)  [3170, 3960]    EMPTY          rank 2
   16   11.8%   EMPTY            EMPTY           EMPTY          ranks 2-5
   32    6.1%   EMPTY            EMPTY           EMPTY          ranks 2-17
```

**Why deeper rosters fail, mechanically.** Every seat pays the coupon on fills it takes and receives
it on fills it misses, so **each seat is subordinate to everything behind it — it is a ladder, not
two tiers.** Widen the ladder and the head shrinks to 6% of the book, at which point the front is
*extracting* from the back (+80% return on 6% of capital) rather than subsidising it, and the first
seventeen seats are underwater.

> **So `MAX_SEATS = 32` advertises a capability the economics do not support.** It is there because
> 32 ranks fit in one storage word, which is a real engineering win on the hot path. It is not a
> claim that a 32-seat book works. **Stated here rather than left to be discovered**, along with the
> measured cost: the worst-case `addToSeat` at 32 seats with 31 priced ahead is **2,586,639 gas.**

**A 5-seat book is realistic for the thing we are selling** — one sponsor at the front and a handful
of sized allocations behind it is exactly how a subordinated facility is syndicated. It is not
realistic as "open LPing for everyone", and we do not claim it is.

---

## 6. WHAT A SEAT COSTS, AND FOR HOW LONG YOU HAVE IT

```
   1. THE RANK       paid ONCE, to the incumbent. Their posted self-price.
                     `buyPrice(seatId)` is the ask. A never-priced seat
                     asks ZERO — the founding roster starts there.

   2. YOUR CAPITAL   NOT a cost. The seat changes hands EMPTY: the seller
                     is refunded to the wei. You fund it yourself, or the
                     seat drops to the tail. Rank is BACKED BY DEPTH.

   3. RENT           paid CONTINUOUSLY, FORWARD, to the seats ahead of you.
                     10%/yr of YOUR OWN posted price. You set the number.
                     High price → safe but expensive. Low price → cheap but
                     anyone may take the seat at it. That is Harberger.

   THE TERM          7 days. You may not voluntarily give up the RANK inside
                     it. You may always SELL at your own posted price.
```

**Rent runs forward, and that is the business model.** The front supplies subordination; the back
consumes it; the consumer pays the provider. In a contested market the back's excess return
capitalises into self-prices and flows forward as rent, which is **how rank 1 monetises what it
provides** — turning a gross −10.4%/yr subsidy into a net −1.3%/yr. Bookends and the derivation:
`BUSINESS.md` §6C.

---

## 7. SECURITY — can a seat be dropped when toxic flow arrives?

**We found this hole ourselves and it is now closed at the free end.** `test_8_20` executes it:

```
   see an adverse swap coming → withdraw(seat, 1 WEI)
       → land at the TAIL with your depth intact
       → AND push the seat behind you into the rank you left
   Our own numbers make the tail a strict upgrade in every regime.
```

Three layers answer it:

| | |
|---|---|
| **1. Any payout costs the rank** | you cannot be subordinate and liquid at the same time |
| **2. The seat you land on is under-priced** | you posted a number for the rank you *left*; for `FIRM_WINDOW` anyone can take it at that number |
| **3. `MIN_TENURE` — 7 days** | inside it, a demoting withdrawal is **refused by name** (`SeatWithinTerm`). The one-wei dodge and the atomic evacuation round-trip are both off the menu |

**What the term does NOT do, said by us:** a holder whose 7 days have elapsed can still step aside.
Nothing mechanical can stop that — *no rule can claw back a loss the attacker never took*. Layer 2
prices that case. `test_8_4` asserts **both** halves so neither can be quoted alone.

**It is a lock on RANK, never on capital.** A locked holder is still sellable at their own posted
price, in any block (`test_8_21`, claim 3).

---

## 8. WHAT WE TESTED, WHAT WE FOUND, AND WHY IT IS BUILT THAT WAY

```
   THE METHOD, AND IT IS NOT TDD
   ─────────────────────────────────────────────────────────────────────
     build faithfully  →  ATTACK IT  →  fix what the attack finds
                          ▲
                          └── the load-bearing step. Tests written
                              alongside code encode the author's
                              assumptions; a mutation does not care
                              what the author assumed.
```

| what | how many | why it exists |
|---|---|---|
| **scenario / acceptance** | the four-swap scenario at several prices and decimal pairs | proves the mechanism does what it claims |
| **negative controls** | one-line mutant subclasses, asserting the **exact revert reason** | a control that fails for an unrelated reason proves nothing — that mistake was made here and cost a phase |
| **fuzz + invariants** | 16,384 randomised calls per invariant, plus a deterministic scripted campaign with coverage floors | the invariant campaign found **three real bugs** in code that had already passed 135 tests and 61 mutations |
| **gas regression** | measured with cold storage and state built in `setUp()` | a warm slot reads **47% optimistic** — every gas number this project had was wrong until that was fixed |
| **mutation testing** | on-disk edits to `src/`, reverted in a `finally` | **found a real defect every single time it was run** |

**Five laws we pay for continuously** (`AGENTS.md` §3): never test at a 1:1 price or equal decimals;
every claim needs a negative control that goes red *for the stated reason*; measure conservation on
PoolManager's own balances net of protocol fees; measure gas cold **and** build state in `setUp()`;
**a first-run pass is a reason for suspicion, not satisfaction.**

### Results that matter

* **Four evacuation exploits** found against our own mechanism and closed at the root.
* **The premium was inert on the pool we ship** — zero wei of token0 premium reached the roster on
  an 18/6 pool, while an 18/18 control looked perfect. LAW 1, one dimension over.
* **Every published rate number once measured a rule the contract had replaced.** Found, re-run,
  and the shipped constant moved 7,900 → 5,100 as a result.
* **The evidence file for a headline result was committed at zero bytes** and `git status` read
  clean for a whole phase.
* **Three separate copies of the shipped φ had drifted apart** behind a comment naming their source.
  A comment is not an interlock; there is a test now.

> **We publish the defects in our own instruments as loudly as the ones in the contract.** A broken
> measurement that looks like a broken mechanism has cost this project more time than any real bug.

---

## 9. WHY THE HOOK IS 3,000 LINES AND NOT 300

A fair question — most hooks in this cohort are ~300 lines plus imports. **The answer is that only
1,047 lines are executable, and the mechanism itself is 194 of them.**

```
  QueueHook.sol — 3,208 lines total
  ├── 1,155  docblocks     ┐
  ├──   776  inline notes  ├── 60.2% commentary: the audit trail, not the program
  ├──   230  blank         ┘
  └── 1,047  EXECUTABLE SOLIDITY

  WHERE THE 1,047 GO                        code    share
  ─────────────────────────────────────────────────────────
  Harberger rent + the seat market           251    28.6%
  deposit / withdraw / liquidity lifecycle   146    16.6%
  v4 callbacks + pool binding                145    16.5%
  helpers, guards, tick and unit maths       119    13.6%
  THE ALLOCATOR — the actual mechanism       104    11.9%
  THE PREMIUM                                 90    10.3%
  views for the frontend                      22     2.5%
```

**Two structural reasons, both real:**

1. **A typical hook adds a fee tweak on top of Uniswap's accounting. QUEUE replaces the allocation
   rule**, so it must own the accounting itself — the position, the float, per-seat ledgers,
   conservation to the wei. That is the 291 lines of lifecycle and plumbing.
2. **It ships a second product on top**: a transferable, self-priced, foreclosable property market
   on rank. That is another 251 lines, and it is load-bearing — it is what pays the front seat.

**There is no dead code.** All 31 public/external functions were checked against `test/`, `script/`
and `frontend/`; every one has callers except `unlockCallback` (called by PoolManager) and
`getHookPermissions` (the v4 interface).

---

## 10. RUNNING IT

```bash
# prerequisites: foundry (forge), python3
forge build
forge test                        # 319 passed, 0 failed, 1 skipped

# the interesting ones, individually
forge test --match-path "test/queue/Deploy.t.sol"      -vv   # the deployment path, beat by beat
forge test --match-path "test/queue/Invariant.t.sol"   -vv   # the invariants + the scripted campaign
forge test --match-path "test/queue/Evacuation.t.sol"        # every evacuation attack, with an outcome
forge test --match-path "test/queue/Harberger.t.sol"         # the rent and seat market
forge test --match-path "test/queue/Gas.t.sol"         -vv   # prints the gas table

# against a LIVE fork of Unichain Sepolia (off by default, skips loudly)
QUEUE_FORK=true forge test --match-path "test/queue/DeployFork.t.sol" -vv

# the mutation campaign. EDITS src/ IN PLACE and restores in a finally.
# NOTHING ELSE MAY TOUCH src/ OR RUN forge WHILE THIS RUNS.
python3 script/mutate.py                    # every case
python3 script/mutate.py --campaign         # against the invariant suite alone

# the economics
python3 docs/research/seat-economics/report_shipping_basis.py    # the shipped phi window
python3 docs/research/seat-economics/report_depth_basis.py       # roster size vs feasibility
```

**The gas table, freshly measured on this tree:**

```
   plain v4 pool, same tokens/fee/price          69,992 gas
   QUEUE, premium OFF                           140,991 gas   (+101%)
   QUEUE as shipped (φ = 5,100)                 153,132 gas   (+119%)
   ─────────────────────────────────────────────────────────────────
   ▶ +119% network compute per swap. On an L2 this is cents; on mainnet
     it is a real bill. QUEUE IS AN L2 PRODUCT.
   ▶ No fee change and no worse price — the trader gets exactly what the
     pool would have given them.
   ▶ Aggregators may route around the pool for the gas alone. That is a
     real commercial risk and it is not hypothetical.
```

---

## 11. INTEGRATING WITH IT

**Traders and routers: nothing to do.** It is an ordinary v4 pool. Same `PoolKey`, same router, same
fee. The queue is invisible from outside and a trader cannot interact with it.

**LPs cannot add liquidity directly** — `beforeAddLiquidity` refuses it, because the hook must be
the sole liquidity provider for the accounting to hold. Capital enters through the seat API:

```solidity
// fund a seat you already hold
hook.addToSeat(seatId, amount0, amount1);

// take capital out. ANY payout costs the rank, and is refused inside the term.
hook.withdraw(seatId, want0, want1);

// the seat market
hook.setSelfPrice(seatId, price);                  // your own assessment; rent is charged on it
hook.buySeat(seatId, maxPrice, newSelfPrice);      // take a seat at its posted price
hook.buySeatAndFund(seatId, maxPrice, newSelfPrice, amount0, amount1, maxRank);
hook.fundRent(seatId, amount);                     // prepay the meter
hook.settleRent(seatId);                           // permissionless

// what a prospective buyer reads first
hook.ranking();          // seat ids in rank order
hook.seat(seatId);       // (token0, token1) the seat holds
hook.buyPrice(seatId);   // the ask
hook.rentDue(seatId);    // what it owes right now
hook.unlockAt(seatId);   // when its TERM ends
```

**There is no off-chain component.** No server, relay, keeper, watch-tower or scanner. The product
is a contract.

---

## 12. WHAT IS DELIVERED

| | |
|---|---|
| `src/queue/QueueHook.sol` | the hook — allocator, premium, liquidity lifecycle, Harberger seat market |
| `src/queue/QueueSeats.sol` | the seat as a transferable object, with its authorisation rules |
| `src/queue/libraries/` | `Allocation` (the fill arithmetic, one implementation, two callers) and `Rent` |
| `script/QueueDeployBase.sol` | the deployment sequence, executed by **both** the broadcast script and a test |
| `test/queue/` | 319 tests against real v4 contracts; negative controls; invariants; the gas table |
| `script/mutate.py` | the mutation campaign, with a preflight that refuses to run a stale pattern |
| `docs/research/seat-economics/` | the simulator and every economics run, with its controls |
| `frontend/index.html` | a single-page viewer for a live pool |
| `BUSINESS.md` | the business case, every dollar figure, and every limitation |
| `PITFALLS.md` | the standing hazard ledger — every trap, measured hazard and settled decision |

---

## 13. LIMITATIONS — stated before anyone asks

1. **It is a transfer, not creation.** The capital-weighted average *is* the passive-LP return.
2. **Simulation only.** No live-pool data. 120 paths per cell, one pair, one band width.
3. **The sponsor must post real capital**, roughly comparable to what it subsidises. This is not
   leverage on a marketing budget.
4. **+119% gas for every trader** on the pool.
5. **At the shipped 33.3% head there is no premium rate that works in a toxic regime** — rank 2
   never clears a passive LP. A larger head share fixes it and costs the sponsor more capital;
   that measurement is in progress and `BUSINESS.md` carries the current state.
6. **The front seat is a bad investment on its own terms, and we say so on camera.** Somebody has to
   volunteer, and the volunteer is the sponsor, not a yield-seeker.
7. **The roster is closed at deployment.** There is no `mint`.
8. **A holder cannot be subordinate and liquid at the same time.** Any withdrawal costs the rank.
9. **`MAX_SEATS = 32` is a storage fact, not an economic one** (§5).
10. **This is not an audit.**

---

## 14. WHERE TO READ NEXT

| you want | read |
|---|---|
| the business case and every dollar figure | `BUSINESS.md` |
| how to work on this repo, and the five laws of testing | `AGENTS.md` |
| what is built and what is next | `PLAN.md` (opens with a status dashboard) |
| the narrative of what has been done | `PROGRESS.md` |
| **every trap, hazard and settled decision** | `PITFALLS.md` — re-read at the start of every session |
| the economics, with their controls | `docs/research/seat-economics/` |

---

## LICENSE

UNLICENSED. Written during the Uniswap Hooks Incubator window.
