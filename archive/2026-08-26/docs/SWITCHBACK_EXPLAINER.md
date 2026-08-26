# SWITCHBACK — what it is, who it is for, and whether anyone would buy it

*2026-08-26. Every number here comes from the seeded simulation in
`docs/research/data/switchback_reflexivity.py` (frozen output alongside it) or from an executed
Foundry test. Where something is unmeasured it says so.*

---

## 0. First question: do we build the other hooks too?

**No. One hook. SWITCHBACK only.**

- **The rules allow exactly one submission** per team. A second hook cannot be entered.
- **The rubric rewards depth, not breadth** — 30% Original Idea, 25% Unique Execution. Two half-built
  hooks score worse than one finished one on both.
- **The owner's own stated preference** is small and high quality over spread thin.

What about HASTE and SLUICE?

| | Status if we pick SWITCHBACK |
|---|---|
| **HASTE** | **A later extension, not a parallel build.** Its anti-front-running fix needs a carried block-open reference — which is exactly SWITCHBACK's one storage slot. So SWITCHBACK is HASTE's substrate. If we ever build HASTE it is an addition to a working, deployed hook, gated on measuring retail impatience first. **Not in scope for the submission.** |
| **SLUICE** | **Shelved, not dead.** Its CoW integration is proven by a real settlement on a fork, so it stays the fallback if SWITCHBACK fails a gate. Building both is not an option. |
| **Assay** | **Not a hook we submit.** It becomes ~20h of credibility on the submitted hook: SWITCHBACK inherits it and bonds a ceiling on its own escrow, deployed. Plus a published census and two research findings. |

**So: one hook, one mechanism, one storage slot, deployed, with a spec it bonds against.**

---

## 1. What it actually does — and the framing that survives scrutiny

### The mechanism in one sentence

**The pool charges a trade for the distance it moves the price *back toward* where the block started,
and pays that money to liquidity providers.**

### The naive pitch, and why it fails

*"It stops sandwich attacks."* Do not say this. Three reasons:

1. A sandwich is only one of the things it charges.
2. Recent research finds sandwiches are **rare and mostly unprofitable on private-mempool rollups,
   with >95% of sandwich-shaped patterns being false positives.** On Unichain, a judge who has read
   that hears *"a lock for a door that has already been removed."*
3. It is not even accurate: **the mechanism does not detect attacks at all.**

### The framing that is actually true

> **Almost every way of taking value out of a pool is a round trip. Almost every way of using a pool
> is not.**
>
> An arbitrageur pushes price and comes back. A sandwicher pushes price and comes back. A JIT
> position appears and leaves. Someone genuinely buying an asset pushes the price and **leaves it
> pushed** — that is what it means to have bought something.
>
> **SWITCHBACK charges the return leg.** It does not know who you are, does not score you, does not
> guess your intent. It prices a *shape*.

### The commercial framing — this is the one to lead with

Because the pool now earns from reverting flow, **it can charge a lower base fee to everyone else.**

That converts SWITCHBACK from "an anti-MEV tax" (defensive, contested, off-putting) into
**price discrimination for an AMM**: the pool stops charging one flat price to a passive buyer and to
a round-tripping arbitrageur, and starts charging each closer to the cost they impose.

That is literally the cohort's stated goal — *"make volatile-pair liquidity sustainable at low fees."*

> ⚠ **This claim is not yet proven and must be before it is pitched.** Our simulation shows LP total
> revenue rising (28.65 → 31.82 per block at α=0.5), but **we have never run the no-hook control**, so
> we cannot yet state "a SWITCHBACK pool can run X bps lower and match a vanilla pool's LP return."
> That control is one run and it is the single highest-value experiment left.

---

## 2. Who the roles are

| Role | What they do | What SWITCHBACK does to them | Do they want it? |
|---|---|---|---|
| **Passive LP** | Deposits into the pool, earns fees | Receives the retracement fees on top of normal fees | **Yes — they are the beneficiary.** |
| **Pool deployer** (DAO, protocol, market maker) | Chooses the hook when creating the pool | Gets a pool that is less attractive to extract from, so it can quote tighter | **Yes — this is the buyer.** |
| **One-way trader** (buying/selling to hold) | Swaps in one direction | Pays nothing extra **if** the block has not already moved against them — roughly half the time | Neutral to positive |
| **Round-trip trader** (in and out same block) | Two legs | Pays on the return leg | **No — and that is the point.** |
| **CEX-DEX arbitrageur** | Corrects price at the top of the block | **Never charged.** The first swap of a block moves *away* from the reference by construction | Indifferent — important, see §7 |
| **Sandwicher** | Front-run, victim, back-run | Front-run free, victim free, **back-run charged** — the only profitable leg is the taxed one | No |
| **JIT LP** | Adds liquidity for one block, removes | Their exit is a retracement-shaped event | No |
| **Router / aggregator** | Quotes and routes | Must read the published fee cap; the fee sits inside the user's slippage budget | Needs one integration |

**The buyer is the pool deployer, not the trader.** That matters for the pitch: we are selling a
*pool configuration* to whoever decides what a pool looks like, and the benefit accrues to their LPs.

---

## 3. Business flow

```
   ┌── POOL DEPLOYER ─────────────────────────────────────────────────────────┐
   │  Creates a pool with the SWITCHBACK hook.                                │
   │  Chooses ONE parameter: γ, how hard reverting flow is charged.           │
   │  Publishes the fee cap so aggregators can quote it.                      │
   └────────────────────────────┬─────────────────────────────────────────────┘
                                │
   ┌── LIQUIDITY PROVIDERS ─────▼─────────────────────────────────────────────┐
   │  Deposit as normal. No new interface, no lockup, no new token.           │
   │  Earn: normal swap fees  +  the retracement fees collected from takers.  │
   └────────────────────────────┬─────────────────────────────────────────────┘
                                │
   ┌── TRADERS ─────────────────▼─────────────────────────────────────────────┐
   │  Trade as normal, through any router.                                    │
   │  Moving price further from the reference ......... no extra charge       │
   │  Moving price back toward the reference .......... charged, ∝ distance   │
   └────────────────────────────┬─────────────────────────────────────────────┘
                                │
   ┌── SETTLEMENT ──────────────▼─────────────────────────────────────────────┐
   │  Charge is taken out of the swap's OUTPUT (not an extra charge on input) │
   │  → escrowed → paid to the liquidity that was actually exposed.           │
   └──────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Technical flow

The whole mechanism is **one storage slot** and about ten lines of arithmetic.

```
STORAGE:  int24 T0          // the carried reference tick. ONE slot. That is all.

ON EACH BLOCK'S FIRST TOUCH:
    T0 = T0 + α · (currentTick − T0)        // EMA carry, NOT a reset
                                            // α is a WALL-CLOCK half-life:
                                            //   0.5000 on 12s Ethereum blocks
                                            //   0.0115 on 200ms Unichain blocks

ON EACH SWAP:
    beforeSwap:  d0 = tickBefore − T0       // where we were, relative to the reference
    afterSwap:   d1 = tickAfter  − T0       // where we ended up

    charged = (d0 · d1 >= 0)                // did we stay on the same side of T0?
                ? max(0, |d0| − |d1|)       //   yes → the distance we came back
                : |d0|                      //   no  → we crossed; charge the whole approach

    fee = γ · charged                       // taken via afterSwapReturnDelta,
                                            // OUT OF THE OUTPUT, capped and published
```

**Three properties of that arithmetic, all verified:**

1. **`charge = min(your own price impact, the standing displacement)`.** You can only ever be charged
   for distance *you actually walked*. This is why a stale reference cannot produce a surprise bill —
   at a 5-tick median retail impact, retail never pays more than ~5 bps **however far the reference
   has drifted.** A 10,120-tick drift still costs only 7.40 bps.
2. **The "extension budget" everyone talks about is this identity, not a separate mechanism.** We
   originally designed three storage slots of high-water-mark tracking; replacing all of it with the
   formula above reproduces every simulated number **bit-for-bit.** The watermarks were dead weight.
3. **The reference must be carried, never reset.** A per-block reset creates a free lane: front-run
   and victim in block N, unwind at the top of N+1 where the reference has re-set to the displaced
   price, and **both legs are extensions — total fee zero, 87% of gross retained.** The EMA carry
   drops that to 1.6%, identical to the in-block route, i.e. **no advantage at all.**

---

## 5. Worked examples

### Example A — the sandwich pays, the victim does not

```
  block opens, reference T0 = 100

  attacker front-run : buys, 100 ──► 104     moving AWAY from T0   → free
  victim's swap      : buys, 104 ──► 105     moving AWAY from T0   → FREE. The victim pays nothing.
  attacker back-run  : sells, 105 ──► 100    moving BACK toward T0 → CHARGED on 5 ticks

  Result: 1.6% of the untaxed gross retained. The attack stops being worth doing,
          and the person who was attacked was never charged for the protection.
```

### Example B — a genuine buyer is untouched

```
  reference T0 = 100, price at 100

  buyer: buys 50 ETH, 100 ──► 106            moving AWAY from T0   → free

  They wanted the asset. They pushed the price and left it pushed. That is what buying is.
```

### Example C — the awkward one, and we show it on camera

```
  reference T0 = 100
  top-of-block arb corrects the price:  100 ──► 106      (away from T0 → free)

  now an ordinary seller arrives, unrelated, no MEV intent:
  sells 10 ETH:  106 ──► 101                             (BACK toward T0 → CHARGED)

  They pay ~3.6 bps. They did nothing wrong.
```

**This happens to roughly half of all one-way honest flow**, because a corrective arb extends the
price at the top of nearly every block, so a coin-flip share of later trades arrive in the retracing
direction.

**Measured: 49% of honest swaps charged, mean 3.63 bps** — on top of a 5 bps pool fee, a ~76%
increase in their all-in cost. **In a pool with little extraction, 67% of what SWITCHBACK collects is
billed to ordinary traders, not to attackers.**

We do not hide Example C. We lead with it, because the answer is good: **the money goes to the LPs,
not to us or to a searcher — so the pool can charge everyone a lower base fee.** It is a transfer
from takers-who-revert to makers, not a leak out of the system.

---

## 5b. ⚠ THE FRAMING ABOVE IS A 12-SECOND-CHAIN FRAMING. On Unichain it is a different sentence.

*Simulated at Unichain parameters, 2026-08-26. Negative control asserted in-script: the 12s
configuration built by the same harness reproduces the earlier α=0.5 row exactly.*

Everything in §1–§5 describes **the price path inside one block**: price extends, then retraces, and
we charge the retrace. **That story requires a block long enough to contain several swaps.** Unichain
blocks are 200 ms.

**Three consequences, and the third is the one that matters for the video:**

**(a) The naive version of this hook is nearly INERT on Unichain.** With a per-block reference reset,
at 200 ms: it charges 5.8% of swaps a volume-weighted **0.14 bps** and lets **99.4%** of extraction
out the cross-block door. With ~0.05 swaps per block, a block almost never contains two swaps, **so
there is almost no intra-block price path to charge.** The EMA carry is therefore not a patch on the
mechanism — **on the target chain it *is* the mechanism.**

**(b) With the carry, the fix works and costs less than half what it does at 12 s.**

| config | honest charged | honest bps | in-block keeps | cross-block keeps |
|---|---|---|---|---|
| 12 s, per-block reset | 44.6% | 3.79 | 1.6% | **87.3%** |
| 12 s, 12 s half-life | 49.0% | 3.63 | 1.6% | **1.6%** |
| **200 ms, per-block reset** | 5.8% | 0.14 | 1.7% | **99.4%** |
| **200 ms, 12 s half-life** | 48.5% | **1.51** | 1.5% | **1.5%** |

**(c) THE PITCH MUST CHANGE ON UNICHAIN.** At 200 ms, **96.6% of the honest fee is attributable to
the carried reference**, versus 30.8% at 12 s. So on Unichain this is **not an intra-block-path
mechanism at all — it is a decaying-reference mechanism.**

> **12-second chain:** *"the pool's own price path turning back on itself within a block."*
> **Unichain:** *"a decaying reference price, and you pay for walking back toward it."*

Those are different sentences, and **a judge who checks Unichain's block time can ask for the second
one.** Pick the chain deliberately and pitch the matching sentence. Do not use the §5 diagrams
unqualified on a 200 ms chain.

**Two things that got better, not worse:**
- **The half-life is a dial, not a threshold.** Cross-block extraction collapses to the in-block value
  at *every* half-life tested from 1 second to 5 minutes. There is no cliff to fall off; the half-life
  buys inventory-hold time at a linear price in honest bps. 12 s ⇒ 1.51 bps; 4 s ⇒ 1.00 bps if honest
  cost is the binding constraint.
- **The "just wait" escape is harder on Unichain, not easier.** The wall clock is identical (60 s to
  halve the charge) — but at 200 ms the attacker must survive **300 blocks of other people's flow and
  300 top-of-block corrective-arb opportunities** rather than 5, while holding precisely the
  displacement the arb wants.

**And it does not need a dense arbitrage population:** pricing out 90% of arbs moves honest cost from
1.51 to 2.29 bps and leaves cross-block extraction unchanged.

**⚠ The cheapest unmeasured input in the whole project:** Unichain's actual flow density. The 0.05
swaps/block figure is our 12 s calibration rescaled, **not a measurement**, and claim (a) is only as
good as it. **One subgraph query against a live Unichain v4 pool settles it.**

---

## 6. "It seems odd to describe those trades" — you are right, and here is the fix

That instinct is correct and it is the biggest *presentation* risk in the project. "We charge
retracement" is an engineer's sentence. Nobody outside this document thinks in ticks relative to a
carried EMA reference.

**The fix is to never explain the arithmetic first.** Three levels, use whichever the listener needs:

| Audience | Sentence |
|---|---|
| **Anyone, 5 seconds** | *"A round trip costs money. A one-way trade does not."* |
| **A trader or LP, 20 seconds** | *"Taking value out of a pool means pushing the price and bringing it back. Using a pool means pushing it and leaving. We charge the coming-back part and give it to the LPs."* |
| **A technical judge, 60 seconds** | The formula in §4, plus: *"one storage slot, no oracle, no keeper, no off-chain component, and the charge is capped by your own price impact."* |

**And show, don't describe.** The demo is a live sandwich with the attacker's P&L going from positive
to negative on screen, then the same pool with an ordinary trade paying nothing. That is thirty
seconds and it needs no vocabulary at all.

---

## 7. Would a skeptical judge buy it? — the seven questions they will actually ask

I have written the questions as an adversary would, with our real answers. **Where the answer is
uncomfortable, it is uncomfortable.**

**Q1. "Sandwiches barely exist on rollups. What are you actually protecting against?"**
→ Correct, and we cite the same paper. The mechanism is not sandwich-specific: it charges JIT
extraction and self-liquidation too, both of which are atomic and chain-independent. **We lead with
the shape, not the sandwich.**

**Q2. "You charge half of all honest trades. Isn't that worse than the problem?"**
→ *The honest one, and it must be answered with the commercial frame:* the money goes to LPs, so the
pool can run a lower base fee. A one-way trader is better off than on a vanilla pool; a round-tripper
is worse off. **That is the intended discrimination.** ⚠ We must run the no-hook control before we
can say this with a number.

**Q3. "OpenZeppelin already ships an anti-sandwich hook. Why is this different?"**
→ OZ **floors** the price — it refuses to fill better than the block open, which creates no cashflow
and protects one swap direction only (their own documentation says so). Angstrom **removes** the
price path via uniform-price batch clearing. Kyber FairFlow **closes the pool** to an exclusive taker.
**None of them price the path. That is the whole claim, and it is verified against four primary
sources.**

**Q4. "Isn't the reference manipulable? Push the price early, make everyone else pay more."**
→ Measured: biasing the reference by 5 ticks costs ~$15 and earns ~$3. **About 5× underwater**, and
the attacker receives only their LP share of even that. *(Cost measured; revenue inferred from the
simulation's own derivative. Not separately simulated.)*

**Q5. "What stops me just waiting a block and unwinding for free?"**
→ That was a real hole and it is why the reference is an EMA rather than a reset. At a 12-second
half-life the attacker must hold **3–5 half-lives (~30–60 seconds)** before it pays — and the
top-of-block corrective arb takes the displacement they are sitting on in the meantime. **We found
this ourselves and fixed it; we did not wait to be told.**

**Q6. "Doesn't taxing the corrective arb make your own prices worse?"**
→ Yes, and we measured it: the corrective arb under-corrects, costing LPs **7.2% of P&L.** It buys
closing a route worth 87% of gross to an attacker. **A trade, and we present it as one.**

**Q7. "What is genuinely new here?"**
→ *The weakest answer, and it should be given plainly.* Fee assignment previously had four known
bases — age, bond, auction, protocol-owned liquidity. **SWITCHBACK assigns by intra-block price-path
shape, which is a fifth.** Honest originality: **3 out of 5.** It is one clear step beyond
OpenZeppelin's shipped library, not a leap.

---

## 8. Would anyone actually *use* it?

| | Verdict |
|---|---|
| **Pool deployers** | **Plausibly yes**, once the lower-base-fee claim is proven. Their LPs earn more for the same risk, and the hook needs no oracle, keeper or off-chain infrastructure to run. Deployment is one hook address. |
| **LPs** | **Yes**, if the numbers hold. They receive strictly more, minus the 7.2% arb-correction cost. |
| **Traders** | **Split by design.** One-way traders benefit from the lower base fee; round-trippers pay. About half of one-way flow gets caught by the reference effect and pays anyway — the real cost, disclosed. |
| **Aggregators** | **Needs one integration** — read the published fee cap. If they do not, quotes revert on slippage. **This is the adoption bottleneck and it is not solved.** |
| **Searchers** | Route around it to unprotected pools. **That is a success, not a failure** — but it does mean the *global* MEV is displaced rather than eliminated, and we should say so. |

---

## 9. Pros and cons, straight

**Pros**
- **One storage slot, ten lines of arithmetic.** No oracle, no keeper, no randomness, no off-chain
  component, no partner dependency, no custom periphery.
- **Router compatibility proven by execution**, through two independent router paths.
- **A verified, defensible claim**: nobody else prices the intra-block price path.
- **The charge is self-capping** — you can only be charged for distance you walked.
- **It is HASTE's substrate**, so it does not close a door.
- **Deliverable in ~4 weeks** with real tests, which fits the "small and high quality" preference.

**Cons**
- **It charges ~half of honest one-way flow.** The single biggest objection, unavoidable, disclosed.
- **Originality is 3/5**, not 5/5. One step beyond OZ's shipped library.
- **It costs LPs 7.2% of P&L** through impaired price correction.
- **It displaces MEV rather than eliminating it** — searchers use other pools.
- **Aggregator integration is required** and is not solved.
- **The fee sits inside the user's slippage budget**, so a quote made without knowing the fee reverts.
- **The lower-base-fee claim — the entire commercial pitch — is not yet proven.**

---

## 10. What must be true before we commit four weeks

Three experiments, in order. Each can kill or reshape the pitch, and all are cheap.

1. **The no-hook control.** Can a SWITCHBACK pool run a lower base fee and match a vanilla pool's LP
   return? **This is the commercial claim and it is unproven.** One simulation run.
2. **The 200ms re-run** *(in flight)*. The wall-clock invariance of the EMA is analytic, never
   simulated at Unichain block times. If it fails, α is not 0.0115 and the parameter table does not
   transfer.
3. **The beneficiary problem.** `donate()` pays whoever is in range *now*, not the liquidity that was
   exposed. Needs an aged-LP escrow plus a JIT activation delay, proven in tests — **at a non-unit
   price with a negative control**, because a 1:1 fixture hides every unit-mixing bug.

**Unmeasured and load-bearing throughout:** the flow calibration (3 swaps/block, 5-tick median retail
impact). Every bps figure in this document moves with it.
