# NEXT SESSION — QUEUE. The value question is ANSWERED. Read this file, then `AGENTS.md`.

**Read order: this file → `AGENTS.md` (how to work here — LAWS 1 and 5 were amended on 2026-09-02
and the amendments are load-bearing) → `PITFALLS.md` §5.124–5.135 → `PLAN.md` only when you write
code.** `BUSINESS.md` §0 and `README.md` both open with correction banners dated 2026-09-02; those
banners are current, the bodies beneath them are being rewritten.

---

## 0. THE ASSESSMENT, OPENING AND CLOSING

**Yes, this hook is worth shipping — and the reason is one sentence, narrower and better evidenced
than anything the project claimed before 2026-09-02.**

> **QUEUE sells the front seat: costlessly re-anchoring at-the-money exposure that no LP can buy any
> other way — and the people it jumps in front of are paid for it, automatically, out of the fees it
> earns by being first.**

Measured against a keeper-managed narrow ATM range — modelled **optimistically**, with instant
re-mints, no latency, no missed blocks and no MEV on its own conversion trade — **rank 1 wins by 30
to 758 points** at φ = 0. Replicating the property costs **80–123%/yr** in conversion fee and price
impact at the widths that actually compete.

**And the one thing that is NOT established, stated first rather than buried.** Rank 1 accepts a
**below-LP return** in exchange for that property. Hold it to the passive-LP bar instead and it falls
below at φ = 6,397, while the seats behind need φ ≥ 7,455 to beat passive LPing at all — **both
windows empty, no shipping constant exists.** We measured what the property COSTS to replicate. We
did not measure what a buyer will PAY for it, and no simulator can. **That single question decides
whether this product exists.** It is a go-to-market question, not an engineering one.

---

## 1. THE BUSINESS CASE, IN PLAIN LANGUAGE

### The money flow

```
                    ┌──────────────────────────────────────────┐
   A TRADER  ──────▶│  ORDINARY UNISWAP POOL                   │
   (any router,     │  same price · same 0.30% fee             │
    never sees      │  +119% network compute                   │
    the queue)      └───────────────────┬──────────────────────┘
                                        │  the 0.30% fee
                                        ▼
                         ┌──────────────────────────┐
                         │  SEAT 1 — filled FIRST   │
                         │  by every single trade   │
                         └───────┬──────────────────┘
                 keeps ~21% ─────┤
                                 │  hands 79% (φ) to the seats it
                                 │  jumped, in proportion to the
                                 ▼  DEPTH each of them contributed
              ┌──────────┬──────────┬──────────┬──────────┐
              │  SEAT 2  │  SEAT 3  │  SEAT 4  │  SEAT 5  │
              └──────────┴──────────┴──────────┴──────────┘
                 rarely filled · they ARE the depth that
                 makes the pool worth trading against

     PLUS: seat 1 posts its own price and pays RENT on it.
           Anyone may buy the seat at that price, any time.
```

### Worked example — $1m book, ±10% band, benign market, 61-day band life

```
   seat   capital     role                        realised over the band
   ─────────────────────────────────────────────────────────────────────
    1     $333,333    filled by EVERY trade            +2.7%   ◀ below LP
    2     $266,667    rarely filled                    +5.3%
    3     $200,000    rarely filled                    +6.1%
    4     $133,333    rarely filled                    +7.2%
    5     $ 66,667    almost never filled              +7.9%
   ─────────────────────────────────────────────────────────────────────
   an ordinary Uniswap LP, same money, same range     +5.02%

   capital-weighted mean of the five seats  ==  +5.02%   ← EXACTLY the LP
```

**That last line is an IDENTITY, measured to 1.4e-12.** The five seats share one Uniswap position, so
their returns must average to what one ordinary LP earns. **φ creates nothing. It decides who is paid
to lose.** Any pitch implying otherwise is false and this project has made that mistake twice.

### Why each party is there

| party | what they get | what they pay | when they walk |
|---|---|---|---|
| **Seat 1** | First fill in BOTH directions, always, free. Inventory recycles **122–543×** over the band's life; it collects **528× seat 2's** fees. This is a market-maker position. | φ of every fee it earns, plus rent on its own posted price. Eats every adverse move first. | If φ > 8,312 — the keeper bot becomes cheaper |
| **Seats 2–5** | A share of seat 1's fee flow, proportional to depth contributed. **+5.3% to +7.9% against the LP's +5.02%.** | Their capital is rarely traded (turnover 0.04–1.03× over the whole band life) | If φ < 7,455 — they stop beating passive LPing |
| **Trader** | Nothing. Same price, same fee. | **+119% compute.** Cents on an L2, but a cost with no benefit and we do not dress it up | Always, if their router optimises gas |
| **Router** | Only reason to route here is DEPTH | Worse gas for the same price | A gas-optimising router **should skip this pool.** Real adoption risk |
| **Wing LPs** | Ordinary Uniswap outside the band. No rent, no roster, cancel any block | Nothing | Never — they are unaffected |
| **Deployer** | A **public price for "what is being first worth in my pair?"** — a number that exists nowhere else in DeFi | Picks band, φ, τ, roster, founders | — |

### The bootstrapping circle, stated honestly

```
   seat 1 worth holding ──▶ seats fund the book ──▶ pool is deep
            ▲                                             │
            └────────────── flow arrives ◀────────────────┘

   The deployer breaks the circle by seeding the founding roster.
   This is the same circle every new venue has. It is not solved by the mechanism.
```

### Seats 2–5 are a POOL, not a ladder

Adjacent-rank separation on the shipped roster is **2.37 between seats 1 and 2 and 0.01–0.09
everywhere else.** The premium is shared by inventory weight, not by rank. **So the ordering among
seats 2–5 is decoration.** Say "rank 1 plus a four-member premium-sharing pool", never "five ranked
desks".

---

## 2. PROVEN IMPOSSIBLE — DO NOT RE-OPEN ANY OF THESE

Each cost a session. They are closed with evidence, not opinion.

1. **A senior/junior tranche.** In a single pro-rata position the loss ordering and the cash ordering
   are the SAME ordering, because getting out of token0 IS getting into token1. One queue necessarily
   governs both legs. Seniority needs two independent orderings, and the moment you have two you have
   doubled the auction, not created a tranche. **SEARCH CLOSED.**
2. **LIFO / "unwind backward" to fix the Ratchet.** Measured: it flattens the head/middle turnover
   ratio from 35–7,704 to 1.0–4.2 — *it abolishes the queue*. Also: "unwind" is not observable to the
   contract (a seat receiving token0 for token1 has ROTATED, not acquired), so it needs a direction
   flag, which is a two-transaction free lane. `sim_lifo.py` is a headstone with the four kill
   reasons.
3. **`sponsor()` / a DAO paying rent instead of emissions.** Weighted by inventory, so "ranked" does
   no work and Merkl/gauges already do it uncapped and permissionless. It pays MOST to capital that is
   never filled — the emissions pathology it claims to cure. It capitalises into the seat price and is
   captured once, at announcement, by incumbents. **The outside payer already exists and is the
   queue-jumper, paying via τ and buyout.**
4. **The Ratchet itself.** Real and measured (recycling holds to ~rank 8, dead from ~24) and **not
   fixable by any rule that touches fill order**, because turnover concentration IS the priced object.
5. **Making every seat beat an ordinary LP.** Identity, measured to 1.4e-12. See §1.
6. **Reducing LVR, and detecting toxic flow.** Closed before this session; still closed.

---

## 3. TECHNICAL STATE

```
forge test        →  248 passed, 0 failed, 1 skipped (the fork suite; needs QUEUE_FORK=true)
mutation campaign →  80 RED, 0 SURVIVED, 0 NO-COMPILE, 0 BAD-PATTERN after repairs
invariant campaign→  13/13 green at φ > 0 for the first time (but see PITFALLS 5.133)
```

**Run the campaign as `python3 script/mutate.py > /tmp/c.log 2>&1; echo $?` — NEVER pipe it.** A
pipeline's status is the last command's, so a pipe masks the exit code, which is the only
machine-readable signal it has (PITFALLS 5.134).

### What Phase 8 fixed — five defects, all measured

| | defect | evidence |
|---|---|---|
| 1 | **The premium was INERT on the shipped 18/6 pool.** 0 wei of token0 premium reached the roster, 0 of 4 accruals, against an 18/18 control stranding 0%. The guard compared incoming-token wei against outgoing-token wei | `PremiumDecimals.t.sol`, PITFALLS 5.124 |
| 2 | **A dust seat took the whole pot.** 1 wei of standing inventory claimed 100% of a 2.667e17 pot; front-first makes the tail systematically last-standing | PITFALLS 5.127 |
| 3 | **A single-token deposit minted ZERO liquidity**, added no depth, and collected the full premium | PITFALLS 5.128 |
| 4 | **The front could evacuate atomically**, dodge the adverse fill and keep its rank — **+267 bps in one transaction** | `Evacuation.t.sol` |
| 5 | **The hold branch was a ratchet** — held pots added, so release got strictly harder forever | PITFALLS 5.126 |

The fix for 1–3 was one change: **weight the premium by stored contributed liquidity, exclude the
seats a fill paid over `[start, next]` INCLUSIVE.** The interval looks like an off-by-one and is not —
`_settlePremium`'s docblock at `QueueHook.sol` carries the cursor-semantics argument and the
`w=(1,100), S=1.5 → D₂=+0.985` counterexample. **A mutation to the exclusive form goes red in 16
tests.** Fix for 4 is demote-on-withdraw, refined: taking depth out costs the rank, taking earnings
does not.

**Gas: the hot path got CHEAPER.** Head-only swap 162,766 → 152,947 (−6.0%); full 32-seat sweep
+14.3%; the 300k budget now supports 27 seats, not 35 (PITFALLS 5.129, OPEN).

### φ = 7,900, solved rather than swept

Window **[7455, 8312]** on the shipped 5-seat roster. Derivation is in
`script/QueueDeployBase.sol`'s docblock and reproducible via
`python3 docs/research/seat-economics/report_shipping.py`. **The old 8,500 was chosen against "0 of
32 seats negative" — a sign test, on a roster we do not deploy.**

---

## 4. WHAT TO DO NEXT, IN ORDER

1. **Teach `QueueFixture._refAllocate` the premium** — the independent witness has NEVER modelled φ,
   so at φ > 0 the per-seat split rests only on `Premium.t.sol`'s own controls. **The hard part is
   already solved:** the derived bound is `0 ≤ contractClaim − witnessClaim ≤ k − 1` wei, where k is
   the number of accruals since the seat was last settled (the contract takes ONE floor over the
   interval, an immediate witness takes k; the accumulator's own quantisation is `< L_i/Q` and
   vanishes at Q = 2^128). **Do not widen a tolerance** — print k, L_i, w_j and Q in the assertion.
   The witness must compute its OWN contributed liquidity rather than reading `seatLiquidity()`.
2. **Close PITFALLS 5.133 in the same pass** — `QueueHandler` is premium-blind, so "13/13 green" is
   not the coverage it looks like. Needs settle-a-seat, settle-ahead, and a swap sized to land the
   fill boundary on a chosen rank. Same model as (1).
3. **Resolve PITFALLS 5.129** — `MAX_SEATS = 32` against a 300k budget that pays for 27. Lower the
   cap, raise the stated budget, or accept it. `test_5_3b` pins the real number (`assertEq(supported,
   27)`) so a regression is caught either way.
4. **Rewrite `README.md` and `BUSINESS.md` bodies** beneath their correction banners, around §1 above.
5. **Broadcast to Unichain Sepolia** — needs a funded `PRIVATE_KEY` (chain 1301). Everything else is
   fork-asserted.
6. **The video** — under five minutes, human voice.

---

## 5. HOW TO WORK HERE — the two amendments that matter most

**LAW 1 gained a decimals clause and it cost a shipped feature to learn.** `18/18 is to decimals what
1:1 is to price.` The one suite testing the premium ran at `dec0 == dec1 == 18`, and the control was
green *because it is the fixture the law forbids*.

**LAW 5 gained the test that actually catches tautological controls.** Five surfaced in one session:
**ask what would have to be true for this control to read FAIL. If the answer is "nothing I could
plausibly do wrong", it is not a control.** Two corollaries: an instrument that AGREES with the
artifact it models is not thereby validated (they can share a defect); and **a tautology is most
likely to be introduced by a FIX** — four of the five were added while tightening something, one by
somebody actively hunting for that exact failure mode. **The defence is a case whose answer is known
in advance, not a careful look at the metric.**

**Never run `forge`, `git commit` or anything else against the repo while `script/mutate.py` is
running — including from a teammate.** The interlock guards `forge test` and `git commit`, but
nothing stops a concurrent agent writing to `src/`, and in a multi-agent session the orchestrator can
start a campaign while a teammate is mid-write. That happened this session and the campaign had to be
killed with **SIGINT** (never SIGKILL — the `finally` restores on INT) and restarted.
