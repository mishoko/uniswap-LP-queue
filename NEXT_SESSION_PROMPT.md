# NEXT SESSION — find the buyer, or say the project has none. Everything you need is here.

**Read this file, then `docs/research/seat-economics/VALUE.md` (short, and it is the whole problem),
then `AGENTS.md`. `PLAN.md` / `PROGRESS.md` / `PITFALLS.md` are the technical record and can wait
until you start writing code.**

---

## 0. THE ONE THING THIS SESSION IS FOR

**The contract works. The product has no reason to exist yet. Your job is to find one — or to
establish, honestly and with evidence, that there is none.**

Do not design a tenth ordering rule. Nine have been tried (`VALUE.md` §3) and they all fail the same
way, because they are all redistribution.

### The constraint, and it is an identity rather than a measurement

The 32 seats share **one** Uniswap position. Their returns sum to what one ordinary LP would have
earned in the same range. The hook decides the split and cannot create a dollar.

```
   sum of all 32 seats  ==  one ordinary Uniswap LP position
   => the CEILING for all 32 together is to TIE with not using the hook
   => minus lock, contract risk, closed roster, unrollable band
   => a seat is currently STRICTLY WORSE than just LPing
```

The priority premium shipped last session fixed the *distribution* — 29 of 32 seats used to lose
money, now 0 of 32 do. It did **not** create a reason to participate: it equalised everyone to the
pool average, which is what they would earn anyway.

### Therefore the only thing that can work

**Money entering the pool from outside, paid by somebody who wants first fill for a reason that is
not the seat's own trading P&L.** Then the seats behind them earn *pool return + rent*, which is
strictly better than an ordinary LP, and every seat is motivated. `VALUE.md` FLOW C draws it.

---

## 1. THE BRAINSTORM — run this before touching code. Two rounds minimum.

Convene the `AGENTS.md` §5 panel. **Scope each agent narrowly and demand a written return** — an
earlier open-ended panel returned nothing in 50 minutes; a tightly-scoped one returned four strong
reports in under 10.

### ROUND 1 — attack each hypothesis on its own terms

One hypothesis per agent. All four are in `VALUE.md` §4.

* **H1 — the protocol / DAO replacing emissions.** Protocols burn large budgets on token emissions
  for mercenary liquidity and everyone calls it wasteful. Could a protocol pay *rent into a QUEUE
  pool* instead, for committed priority-ranked depth? **Strongest candidate: named buyer, existing
  budget, acknowledged problem.** Attack it: is priority what the protocol actually wants, or do they
  want depth and TVL (which QUEUE does not add)? What would they pay per dollar of committed
  liquidity versus what emissions cost them today? Does the closed 32-seat roster help them (a
  curated LP set) or block them?
* **H2 — a treasury or issuer working inventory.** Wants its own inventory traded first when
  accumulating or distributing. Is head position genuinely better execution than simply trading, or
  is it a worse TWAP? Be specific about what they save.
* **H3 — a market maker buying deterministic turnover.** The classic reason queue position is worth
  microwave towers everywhere else. Does that motive survive translation to an AMM, where you cannot
  choose *not* to be filled?
* **H4 — depth sold to the pair / the swapper.** Only real if H1–H3 work. Quantify: how much extra
  committed capital would make the swapper's price improvement exceed their +133% gas?

**Required output per agent:** who signs the cheque, what budget line it comes from, what they get
that they cannot buy elsewhere, roughly what they would pay, and **the single strongest reason they
would walk away.**

### ROUND 2 — kill the survivors, then design against the winner

Take whatever survives Round 1 and run the adversarial lenses at it:

* **Economic incentives / free lane** — is there a state where the outside payer is better off *not*
  paying, or where a seat holder captures the rent without providing the service?
* **Devil's advocate** — what is the buyer's real alternative, and is it cheaper? (For H1: keep
  paying emissions. For H2: just trade. Both are strong.)
* **Skeptic / real-world feasibility** — has anyone actually done this, and if not, why not?
* **First principles** — is there a *fifth* source of outside money nobody listed? Unexamined
  candidates: charging takers for something, selling the pool's ordering as data, an issuer
  subsidising its own pair's spread, a fund wanting a legibly-ranked LP position for reporting.

**Stop condition:** a named payer, a budget line, a number they would plausibly pay, and a reason
they cannot get the same thing more cheaply. **If two full rounds do not produce that, write it down
as a negative result** — a legitimate and valuable outcome. `VALUE.md` §6 says what to do with it.

### What NOT to do in the brainstorm

* Do not re-open rotation. Its three headline numbers are refuted with counter-measurements in the
  banner on `ROTATION.md`.
* Do not propose reducing LVR or detecting toxic flow. Both are proven impossible for a v4 hook and
  are hard rules in `AGENTS.md` §6.
* Do not accept "the seats are equal now, so it is fair" as a value proposition. Fair and pointless
  are compatible, and that is exactly where the product sits.

---

## 2. TECHNICAL STATE — what you are inheriting

**`forge test` -> 224 passed, 0 failed, 1 skipped. `forge lint src/` clean, `forge fmt` clean.**

### First two commands, before anything else

```bash
sh script/install-hooks.sh     # see section 4 — this is not optional
python3 script/mutate.py       # THE FULL CAMPAIGN HAS NOT BEEN RUN AGAINST THIS TREE
```

The campaign was started and interrupted at 14/86 (all RED, no survivors, no BAD-PATTERNs). Phase 7
edited lines that **existing** mutations target — `_allocate`'s loop body, the seat-balance writes,
the degenerate fill — so a stale pattern reports `BAD-PATTERN` in a column nobody reads while the
summary still says "0 SURVIVED" (PITFALLS 5.111). **Run it and read the BAD-PATTERN count.**

### What shipped last session — the priority premium (`PREMIUM_BPS`, phi)

A filled seat keeps `(10000-phi)/10000` of the fee it earned; the rest goes to the seats still
standing in the line it jumped, weighted by the **opposite** token — you are paid, in the token the
swapper brought, for the token you did not get to sell. A seat drained to zero carries no weight and
collects nothing from the pot it generated.

phi = 0 reduces **exactly** to the pre-Phase-7 contract, and is the null control every suite except
the gas one runs at. Shipping value 8,500. New mutations M81–M87, all RED, 0 survivors.

```
   measured, one head-only swap, 8-seat book, phi = 8500 vs a live phi = 0 control pool
   ------------------------------------------------------------------------------------
   head credit, phi = 0        220,870,896,257,107,547
   head credit, phi = 8500     220,376,980,583,426,340   <- head keeps less
   each standing seat gains         70,559,381,954,457   <- x 7 seats = the pot, exactly
```

### The measurement that justifies it, and that you should not re-derive

Per rank, 30 price paths, benign flow, +-10% band, no premium:

```
      rank    fee %/yr   inventory   net %/yr   turnover %/yr
         0    +1240.1%    -328.3%    +911.8%       +411,877%
         1      +66.9%     -54.8%     +12.0%        +22,186%
         7       +5.7%     -26.2%     -20.5%         +1,903%
        31       +0.1%      -0.0%      +0.1%            +34%
```

**The head's advantage is a QUANTITY, not a price.** Marginal pricing already makes it fill at the
stalest end of every move. That is why a price tweak and a rent on an assessed value both fail, and
why the instrument had to be a share of fee flow.

### The costs, measured steady-state on both sides

```
   plain v4 pool                  69,970
   QUEUE, premium off            131,821    +88%
   QUEUE as shipped (phi=8500)   162,766   +133%
   per extra seat walked          14,777
```

The "+48%" this project published for months was an artifact — it compared against a plain pool that
had never traded, so the control paid its own one-time storage writes. Corrected everywhere.

### Outstanding engineering (do this only after section 1 produces a reason to)

1. **Teach the reference allocator the premium.** `QueueFixture._refAllocate` is the independent
   witness and does not model it, so at phi > 0 the per-seat split rests on `Premium.t.sol`'s
   controls rather than on the witness. Keep it independent: the contract distributes **lazily**
   through an accumulator, so make the witness distribute **immediately and exactly**, O(n) per swap,
   from the spec. Two different shapes cannot be wrong the same way. **Do not widen a tolerance to
   absorb the rounding difference** (PITFALLS 5.53).
2. **Run the invariant campaign at phi > 0.** It has only ever run at phi = 0. On this project the
   campaign found three real bugs in code that had already passed 135 tests and 61 mutations.
3. **The band/term constructor guard** — approved by the owner, unbuilt. Rule:
   `half-width(ticks) x 1e-4 >= sigma * sqrt(T)`, with sigma and T stated by the deployer. **Blocked
   on converting the constructor to a parameter struct** — it is at eleven arguments and the ABI
   decoder ran out of stack at twelve.
4. **Broadcast to Unichain Sepolia.** Fork-asserted; needs a funded key. No deployed address exists.
5. **The video, under five minutes, human voice.**

---

## 3. WHAT THE DOCUMENTS SAY, AND WHICH TO TRUST

| File | What it is | Trust |
|---|---|---|
| `docs/research/seat-economics/VALUE.md` | **The business analysis. Start here.** Why there is no value proposition today and where one could come from | Current |
| `docs/research/seat-economics/ROTATION.md` | A rejected direction, preserved with a banner carrying the three counter-measurements that killed it | **Superseded — read the banner, not the body** |
| `README.md` | The 15-minute read. Now says what a seat behind the head is paid and why. **Still overstates the case: it does not yet say a seat TIES with an ordinary LP** | Partly stale |
| `BUSINESS.md` | The commercial document. Gas figures corrected; the value proposition needs rewriting once section 1 lands | Partly stale |
| `PITFALLS.md` | The standing hazard ledger, 5.115–5.121 new | Current |
| `PROGRESS.md` | Narrative, newest first | Current |

**Both `README.md` and `BUSINESS.md` still read as though seat holders make money. They tie. Fix
that when section 1 gives you something true to put in its place.**

---

## 4. DO NOT

* **Do not run `forge test`, `forge fmt` or `git commit` while `script/mutate.py` is running.** The
  commit case is not hypothetical: it happened twice in one session, snapshotting a mutant into
  `src/` under a message saying "no production code changed" (PITFALLS 5.121). **Run
  `sh script/install-hooks.sh` once in your clone** — the pre-commit hook refuses while the campaign
  marker is present. A mutant compiles and the suite passes, so nothing else can catch it.
* Do not quote "+0.0000%" as evidence about the split. It is a conservation identity and a
  deliberately corrupt allocator scores the same.
* Do not trust a number from `docs/research/seat-economics/` checked on only one seed range. That is
  how the previous decision went wrong (PITFALLS 5.119).
* Do not add a `PREMIUM_BPS == 0` fast path to flatter the gas suite. `Gas.t.sol` runs at the
  shipping phi with `PremiumOffGasTest` as its control, deliberately.
* Do not add a seventh writer of a seat balance without routing it through `_syncSeat` first.
* Do not claim the swapper benefits. They pay +133% gas for the same price and the same fee.
