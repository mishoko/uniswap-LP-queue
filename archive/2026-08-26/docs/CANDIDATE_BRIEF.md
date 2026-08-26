# UHI10 — candidate brief for the decision-maker

*2026-08-26. Written in business language. Every number here was measured or counted by someone on
this team; where something is modelled or unverified it says so. Deadline locked ~2026-11-03,
~8 working weeks. One submission allowed.*

**Incumbent verification COMPLETE** (2026-08-26, on-chain): the differentiation holds, on a narrower
claim than we started with — and a new risk to SWITCHBACK was found that outranks the pitch question.
See §1 cons 5 and 6.

---

## The one-page version

| Candidate | What it sells | Build | Biggest risk | Verdict |
|---|---|---|---|---|
| **SWITCHBACK** | Charges the *shape* of a trade — price pushed out and walked back | ~4 wks | Recapture leg needs rebuilding; **may erode its own reference price** | **Lead candidate** |
| **HASTE** | Sells immediacy, so the impatient sort themselves | ~6 wks | One unmeasured number (λ) can kill it outright | Strong second |
| **SLUICE** | Routes toxic flow to a real auction, pays LPs the surplus | ~6 wks | The half that pays can't be demonstrated on testnet | High ceiling, high variance |
| **Assay** | Hooks that carry a spec they cannot violate | ~2 wks to fix | Nothing fixes theme fit or demonstrability | **Publish, don't submit** |
| **Capstone (VPIN)** | — | — | Fails 3 binary gates; 2 critical bugs | **Leave it** |

---

## 1. SWITCHBACK — *charge the round trip*

### The business idea

Almost every way of extracting value from a liquidity pool has the same signature: **the price is
pushed away from where it started, and then walked back.** A sandwich does it. A self-liquidation
does it. Most JIT extraction does it. Ordinary honest trading does not — it moves price and leaves it
moved.

SWITCHBACK doesn't try to identify attackers, score reputations, or guess intent. **It charges the
shape.** If your trade walks the price back toward where the block opened, you pay a fee in
proportion to how far you retraced. The money goes to the liquidity providers who were exposed.

> **The pitch sentence:** *We don't detect attacks. We price the round trip — and the round trip is
> the leg that must exist for the attack to be worth doing.*

### Who buys it

| Who | Why they care |
|---|---|
| **LPs on volatile pairs** | They are currently the exit liquidity for round-trip extraction and receive nothing for it. |
| **Pool deployers / DAO treasuries** | A pool with SWITCHBACK is measurably less attractive to extract from, so it attracts deeper liquidity at lower fees — which is literally the cohort's stated goal. |
| **Ordinary traders** | ⚠ **RETRACTED — see §1 con 7.** Roughly **45% of honest swaps ARE charged**, ~3.79 bps, a **+76% increase in all-in trading cost**. The money goes to LPs, so it is a transfer, not a leak — but "the honest path is free" was **false** and must never appear on a slide. |

### How it works

```
BLOCK OPENS
   price = 100  ──────────────────────────────────────────► recorded as the block-open mark
      │
      ▼
  swap A: buy, pushes price 100 ──► 104          extension      fee: NONE
      │                                          (watermark now 104)
      ▼
  swap B: buy, pushes price 104 ──► 106          extension      fee: NONE
      │                                          (watermark now 106)
      ▼
  swap C: sell, walks price 106 ──► 101          RETRACEMENT    fee: charged on 5 ticks retraced,
      │                                                         capped by the 6 ticks extended
      ▼
  fee escrowed ──► paid to the LPs who were exposed when the extension happened
```

### Worked example — a sandwich pays for itself

```
  Attacker front-run   : buys, price 100 ──► 104   (extension, no fee)
  Victim's swap        : buys, price 104 ──► 105   (extension, no fee — the victim pays NOTHING)
  Attacker back-run    : sells, 105 ──► 100        (retracement of 5 — FEE CHARGED HERE)

  Attacker's gross profit .............. + 5 ticks of victim slippage
  SWITCHBACK fee on the retracement .... − proportional to 5 ticks
  ────────────────────────────────────────────────────────────────────
  Net: the profitable leg is the taxed leg. The victim is never charged.
```

### ⚠ Worked example — RETRACTED. An honest trader is charged about half the time.

A corrective arbitrage extends the price at the top of nearly every block. So roughly **half of all
one-way honest flow arrives in the retracing direction and is charged.** Simulated at γ=1:
**44.6% of honest swaps pay a mean 3.79 bps** — on top of a 5 bps pool fee, a **+76% increase in
their all-in cost.**

```
  Trader sells 10 ETH. Price 100 ──► 97.
    If the block already went UP (an arb corrected it)  ──► this is a RETRACEMENT ──► CHARGED
    If the block already went DOWN                      ──► this is an EXTENSION   ──► free
  It is a coin flip, not a property.
```

**~44% of that false positive comes from the stale reference; ~56% is intrinsic** — ordinary
two-sided honest flow inside one block, which has nothing to do with staleness and cannot be
engineered away. With a *perfect* oracle reference it only improves to 2.13 bps.

**The money goes to LPs, so this is a transfer rather than a loss** — but in a low-extraction pool
**67% of what SWITCHBACK collects is billed to honest traders, not to attackers.** Say that on
camera; do not let a judge find it.

### Pros

- **No external dependencies whatsoever.** No oracle, no keeper, no randomness, no off-chain
  component, no partner, no custom periphery.
- **Proven to work through the standard routers by execution** (13 tests, two independent router
  paths, commit `55c2ae2`). This is the only candidate with that box already ticked.
- **The honest path costs nothing**, which is rare in this category and very easy to demo.
- **It is a substrate.** HASTE's anti-front-running fix needs the block-open reference tick that
  SWITCHBACK maintains. Building this first keeps HASTE available as an extension rather than a
  competing bet.

### Cons — stated at full strength

1. **The recapture leg does not exist as originally designed, and I told you otherwise. That was
   wrong.** Uniswap's `donate()` pays whoever is in range *at that moment*. There is no primitive
   that pays "the liquidity that was there at block open." The escrow-and-pay-next-block plan does
   not do what it says.
2. **The obvious repair is itself attackable, and OpenZeppelin documents the attack in their own
   code comments.** An attacker adds a dust position at an empty tick from a second address, pushes
   the price there, and collects the penalty payment he caused. OZ ships this and calls it "rarely
   profitable." On the thin volatile pairs this targets, it is cheap. **This is the same failure that
   killed our previous hook, and it was papered over the same way.** The fix — an aged-LP escrow plus
   a JIT activation delay — is week-one work, and it must be proven in tests, not asserted in a
   README.
3. **Do not lead the pitch with the word "sandwich."** Recent research (Gogol et al., Jan 2026) finds
   that on private-mempool rollups sandwiches are rare, mostly unprofitable, and **over 95% of
   sandwich-shaped patterns are false positives.** On Unichain, a judge who has read that hears *"a
   lock for a door that has already been removed."* Lead with the shape. JIT extraction and
   self-liquidation are unaffected by that research and are chain-independent.
4. **The fee comes out of the user's slippage budget**, so a trade quoted without knowing the fee can
   revert. Fix is a published cap plus a quote view — half a day. It actually cuts *with* the
   mechanism: an attacker's back-run reverting on slippage is a win.
5. **Live incumbents — now verified on-chain, and the differentiation holds on a NARROWER claim.**
   **Kyber FairFlow** is real and large: $3.2B across 22 pools on five chains since Aug 2025.
   **Angstrom** is real on Ethereum mainnet and Base — *not* Unichain (all three published addresses
   hold zero bytecode there; our earlier claim was wrong).
   Every shipped incumbent handles the intra-block price path by **removing** it (Angstrom mainnet:
   uniform-price batch clearing), **flooring** it (OpenZeppelin's anti-sandwich hook: no fill better
   than block open), **ignoring** it and pricing the bid for ordering instead (Angstrom on Base: a
   tax on the priority fee above a floor), or **closing the pool** (FairFlow: exclusive taker).
   **None of them price the path.** Verified against four primary sources — much stronger than a
   keyword count.
   ⚠ **But be precise or be caught:** "Angstrom taxes the gas tip" is true only of their **Base**
   deployment. Their **mainnet** design is a different mechanism entirely. Say it unqualified and a
   judge who knows mainnet concludes we read one page.
   **FairFlow cannot simply switch to permissionless** — the exclusivity *is* the mechanism; open the
   pool and its captured value goes to zero. So "permissionless, any aggregator can route it" is a
   real, uncopyable differentiator. But it buys **routability, not more recapture** — do not claim we
   recapture more than Kyber does.
6. ⚠ **THE BIGGEST RISK, and it is new: the mechanism may erode its own reference price.**
   OpenZeppelin's anti-sandwich hook carries this warning **in its own source**: *"Since this hook
   makes MEV not profitable, there's not as much arbitrage in the pool, making prices at beginning of
   the block not necessarily close to market price."*
   **SWITCHBACK measures its entire fee from the block-open price.** The closest shipped analogue is
   reporting that succeeding at deterring round trips degrades the arbitrage that keeps that reference
   honest. On a stale reference, ordinary two-sided flow looks like a large retracement and gets
   charged, while genuine repricing looks like extension-then-retracement and gets charged. **That is
   Hardcap's inversion arriving through the reference instead of through an exemption.**
   Not automatically fatal — we *charge* rather than *refuse*, so some arbitrage survives and the loop
   may settle at a fixed point. **But that is a hypothesis, and it is now the first experiment, ahead
   of the fee curve and ahead of the dust-poison fix.**

### The originality claim worth making

Our own earlier brainstorm built a taxonomy of how a pool can assign captured value — by **age**, by
**bond**, by **auction**, or to **protocol-owned liquidity** — and concluded *"there is no fifth
object."*

**SWITCHBACK is a fifth: it assigns by intra-block price-path shape.** That claim survives a judge
who knows every incumbent. "Zero matches in a keyword search" does not.

7. ⚠⚠ **THE RESET IS THE EXEMPTION — and it is Hardcap's shape, fifth appearance.** Found by
   simulation, not hypothesised. If the first swap of a block can never be a retracement (because
   `T0` re-sets to the pool's own tick), then **every top-of-block swap is fee-exempt by
   construction.** The attack: front-run + victim in block N (the front-run is an extension — free),
   then unwind at the **top of block N+1**, where `T0` has re-set to the displaced price so the
   unwind is an extension too — free. **Total SWITCHBACK fee: 0.00, asserted across every trial.**

   | | in-block sandwich (γ=1) | cross-block unwind |
   |---|---|---|
   | still profitable | 27.9% | **82.6%** |
   | keeps, of untaxed gross | 1.7% | **90.6%** |

   Break-even race-win probability is **1.9%** on a 5 bps pool (0–0.3% on 30 bps). **Winning ~1 race
   in 50 makes the cross-block route strictly better than paying the fee.**
   **This refutes §2.4a's load-bearing mitigation** — *"holding inventory across a block turns a
   risk-free atomic sandwich into a directional position exposed to ~12s of price risk."* It is not
   12 seconds; it is **one block boundary, which on Unichain — our target chain — is 200 ms.** The
   mitigation is backwards on the chain we are aiming at.
   *Honest counter-argument, unsimulated:* the first slot of N+1 is contested by the top-of-block
   arb, so in a competitive priority-fee auction the attacker's surplus is partly bid away — **to the
   sequencer, not to the LPs.** So the true statement is *"SWITCHBACK collects nothing on this route
   and the value goes to the block producer."* **Sizing that auction is the next experiment.**

8. **BUILD SIMPLIFICATION — the watermarks are dead weight.** A closed form using only `T0` and the
   ticks before/after reproduces **every number bit-for-bit**. The mechanism needs **one storage
   slot, not three**. And "the fee is capped by how far price was extended" — previously called the
   load-bearing invariant of the design — is a **tautology**: it is just what *"distance walked back
   toward `T0`"* means. It is not a separate defence and must not be pitched as one. (The dust-poison
   cap does hold exactly: a 0.25-tick poison followed by a 199-tick opposite swap is charged for
   0.250 ticks.)

### ✅ The reflexivity fear was FALSE, and the sign was backwards
The OZ warning does not transfer. **`T0` is the pool's own tick at block open — not a price estimate
— so it cannot be "stale" relative to the quantity the fee measures, because it IS that quantity's
origin.** And the top-of-block corrective arb is **never taxed**, because the first swap of a block
moves *away* from `T0` by construction. SWITCHBACK therefore **cannot deter the arbitrage that
anchors its own reference.** Simulated: suppressing 95% of arbitrage raises staleness 13× and
*reduces* honest cost from 3.79 → 2.62 bps, with separation essentially unchanged. The loop
**converges fast** (staleness saturates ~14 ticks even at a 16× fee slope) and costs LPs **−1.4%**
pool-vs-HODL. That risk is closed.

### ✅ THE CROSS-BLOCK HOLE IS FIXED — one parameter, ~free (2026-08-26, same seeded rig, negative control asserted in-script)

Replace the block-open **reset** with an **EMA carry**: `T0_new = T0_old + α·(tick_at_open − T0_old)`.
The unwind at N+1 then starts `(1−α)·displacement` away from `T0`, so walking it back **is** a
retracement and is charged. **Still one storage slot.**

| | shipped (α=1) | fixed (α=0.5) |
|---|---|---|
| **cross-block unwind keeps** | **87.3%** | **1.6%** — identical to in-block, *no advantage at all* |
| in-block sandwich keeps | 1.6% | 1.6% |
| honest flow | 44.6% charged, 3.79 bps | 49.0% charged, **3.63 bps** (slightly cheaper) |
| honest flow in a 5 tick/block trend | 2.57 bps | 3.16 bps |
| reference steering (+5 ticks) | $5 | $15, ≈**5× underwater** |
| escape by waiting | one block boundary — **200 ms on Unichain** | ~3–5 half-lives (~30–60 s), contested by every arb bot |

**⚠ α must be specified as a WALL-CLOCK half-life, not per-block.** For a 12-second half-life:
**α = 0.5 on Ethereum, α = 0.0115 on Unichain.** Get this wrong on a 200 ms chain and the EMA is 60×
too weak.

**The parameter has an interior optimum** — α=0 ("never reset") is *not* the answer: 10.05 bps and a
130-tick lag. "Carry it further" is wrong.

**The strongest property the mechanism has, found here and previously missed:** the charge on any swap
is `min(its own tick impact, the standing displacement)`. **A swap can only be charged for distance it
actually walks, so reference staleness cannot produce an unbounded bill** — at a 5-tick median retail
impact, retail never pays more than ~5 bps *however stale `T0` is*. The α=0 row shows a 10,120-tick lag
still costing only 7.40 bps. The brief's fear — "a fix that closes a 1.9% attack by taxing
trend-following retail 40 bps is not a fix" — **does not happen, for structural reasons.**

**The multi-block-window variant is DEAD and must not be revisited.** A window never closes the route,
it *rations* it — and `block.number % N` is public, so the reset is **not raced, it is diarised**. The
attacker picks a victim in the last block of a window and unwinds in the first block of the next,
keeping 69–87% of gross every time, out to N≈60 blocks. **That is the Hardcap shape in its purest
form: a periodic, publicly-scheduled amnesty.**

**The cost of the fix, to disclose on camera:** taxing the price-correcting arb harder makes it
under-correct (shortfall 27% → 48%), costing LPs **−7.2% of P&L**. It buys closing a route worth 87%
of gross to an attacker. **Present it as a trade, not a free lunch.**

**⚠ THE LOAD-BEARING UNSIMULATED CLAIM:** the wall-clock invariance argument is *analytic*. The rig
runs 12-second blocks only — **nothing was simulated at 200 ms.** If the lag is not invariant to block
time, α on Unichain is not 0.0115 and the table above does not transfer. **Re-run the α sweep at
Unichain block parameters before building. It is one constant.**

### Viability: **HIGH again — the hole is closed, at a disclosed cost.** ~4 weeks. ~4 weeks. Router compatibility is proven by
execution — still the only candidate with that box ticked. Against that: one known correctness problem
with a known fix (the beneficiary/JIT issue), and one **unproven reflexivity hypothesis** (does the fee
still separate extraction from honest flow when the block-open reference is stale?). Originality is a
solid **3/5 — one honest step beyond OpenZeppelin's shipped library, not a leap.** Do not oversell it.

---

## 2. HASTE — *sell immediacy*

### The business idea

The pool posts a price for executing **right now**. Pay it and your trade goes through immediately.
Decline it and your order settles at a random future block, free of charge. The premium is paid to
the liquidity providers.

Every other approach to "tell good flow from bad" builds a **classifier** — reputation, trade size,
oracle deviation, machine learning. Every classifier can be gamed by an attacker willing to look like
whatever it rewards.

> **HASTE never classifies anyone. Pretending to be patient *means actually being late* — and being
> late destroys the arbitrage. The attacker sorts himself.**

### How it works

```
   swap arrives
        │
        ├── "I'll pay the premium"  ──►  executes NOW at spot + premium ──► premium to in-range LPs
        │
        └── "I'll wait"             ──►  order placed IRREVOCABLY
                                              │
                                              ▼
                                    settles at a random future block
                                    at the BLOCK-OPEN price
                                              │
                                              ▼
                                    arbitrage edge has decayed; the
                                    trade is no longer worth doing
```

### Worked example — the arbitrageur has to pay

```
  CEX price moves. Arbitrageur wants to capture 2.1 bps against the pool, and must act THIS BLOCK
  because a competitor will take it otherwise.

  Wait?  ──► by settlement the edge is gone, and a competitor took it. Value of waiting: ~0.
  Pay?   ──► pays up to 2.1 bps of premium, which goes to the LPs.

  Either way the LPs are better off, and nobody had to identify him as an arbitrageur.
```

### Worked example — retail is better off waiting

```
  Someone rebalancing a portfolio does not care about ten blocks.
  Their cost of waiting at moderate impatience: ~1.3 bps.
  The premium they'd otherwise pay:            ~2.1 bps.
  ⇒ They wait, and save 0.8 bps versus trading on any pool without HASTE.
```

**The separation is real but narrow: a band between roughly 1.3 and 2.1 bps.**

### Pros

- **The most original economics of anything considered.** Its ancestors (IEX's speed bump, batch
  auctions) *delay* everyone; none of them *sell* immediacy.
- Sits on genuinely empty ground: probabilistic settlement is taught in the UHI curriculum, named as
  an official Uniswap prompt, and has **zero real implementations in 662 prior submissions.**
- **Pairs defence with recapture natively** — the queue is the defence, the premium is the recapture.
  That is the organizers' own published win condition, met without bolting two things together.

### Cons — stated at full strength

1. **One unmeasured number decides whether it works at all.** The viability boundary is *retail
   impatience*, not volatility. Modelled: it works comfortably if traders' impatience is low,
   and **is dead if it is high.** This number is behavioural — it cannot be derived, only measured.
   **Measuring it is the cheapest experiment we have and it must come before any build.**
2. **On a pool with no arbitrage competition, HASTE collects nothing and defends nothing.** A
   monopolist arbitrageur simply waits, for free. It is a mechanism for *competitively arbitraged*
   pairs and must be pitched as exactly that — not as a universal MEV hook.
3. **It is regressive.** Someone must be paid to settle matured orders, which sets a minimum order
   size. **It protects large retail and taxes small retail.** This belongs in the pitch, not the
   footnotes.
4. **The premium is not paid out of the arbitrageur's pocket** — it is paid by widening the spread.
   LPs still gain, but an urgent trader's true cost is roughly double the headline premium.
5. **Needs custom periphery (14–20 h).** The deferred lane cannot be reached through the standard
   router, because a swap that returns nothing now fails the router's slippage check. **Proven by
   execution.** So the free lane is the one that breaks, which is backwards.

### Viability: **MEDIUM-HIGH, gated on one measurement.** ~6 weeks. Do not start until impatience is
measured. If it measures badly, HASTE dies and SWITCHBACK absorbs the effort with nothing lost.

---

## 3. SLUICE — *send the toxic flow to an auction and pay the LPs the proceeds*

### The business idea

When the hook judges a swap toxic, it doesn't execute it against the pool at all. It holds the money
and opens a **real order on CoW Protocol**, where professional solvers compete to fill it. **The
surplus they compete away is paid to the liquidity providers the flow was diverted from.** If nobody
fills it, it falls back into the pool.

### Why this is the most interesting lane on the board

Uniswap's own published prompt asks, word for word, for *"hybrid routing between private orderflow
systems (CoW, Flashbots Protect) and Uniswap."*

Across nine cohorts and 662 submissions: **Flashbots — 0. CoW Protocol — 0. UniswapX — 0.**
Thirty-two teams built CoW-*style* matching from scratch. **Not one connected to the real thing.**
The organizers call a genuine integration here *"close to guaranteed differentiation."*

**We found out why the lane is empty: everyone believes CoW's order system is Safe-wallet-only. It
isn't.** We read the contract, then proved it — a plain contract can place a real order, and we
executed a **real settlement on a fork** to confirm it end to end.

### How it works

```
  swap arrives ──► hook judges it toxic
        │
        ├── not toxic ──► executes normally against the pool
        │
        └── toxic ──► input escrowed, NOT executed
                          │
                          ▼
                 real CoW order opened, priced at pool price minus a fee
                          │
                          ▼
                 professional solvers COMPETE to fill it
                          │
                          ├── filled ──► surplus from that competition ──► paid to in-range LPs
                          └── unfilled at expiry ──► falls back into the pool
```

### Pros

- **A real, permissionless, on-chain integration** in the one lane nobody has entered — and partner
  integration nearly doubles the historical prize rate (27.5% vs 15.0%).
- **The integration is load-bearing, not decorative.** The value paid to LPs *is* the competitive
  surplus. Delete the integration and there is no product. That is the test most "integrations" fail.
- Highest ceiling of the three.

### Cons — stated at full strength

1. **The half that pays cannot be demonstrated.** The testnet has exactly **one** solver. Sluice's
   entire recapture story is *competitive* surplus, and there is no competition there. We can show
   the mechanism works; we cannot show it pays. **That must be labelled as not-demonstrated.**
2. **The version we actually want requires us to run an off-chain component.** A stock configuration
   needs nothing, but a bespoke one needs our own watcher — an off-chain box in the trust story.
   (This corrects an earlier, too-strong claim of ours.)
3. **The hard part is untouched.** *How does the hook decide a swap is toxic?* That is the whole
   mechanism and nobody has designed it yet. The natural answer is a ZK proof of a trader's realised
   historical performance (a Brevis integration — feasible, and a sponsor).
4. **Four implementation traps**, each of which silently kills it, all found by running the code. The
   nastiest inverts normal engineering hygiene, so a well-meaning future developer will "fix" it into
   a bug unless it is pinned by a test.
5. **CoW is not a sponsor.** This buys distinctiveness, not a second prize track.

### Viability: **MEDIUM.** ~6 weeks, and the schedule risk is real because the toxicity judgement is
undesigned. Highest ceiling, widest variance.

---

## 4. Assay — **publish it, don't submit it**

### The honest position

You asked whether we decided Assay is unsafe or merely unwinnable. **Neither, exactly:**

- **The idea is sound.** Nobody showed the mechanism doesn't work.
- **The implementation is safe enough to hold money.** An auditor hunting for it found **no
  third-party fund-loss path**. There is one real vulnerability, and it is fixable.
- **The claims were oversold.** Four headline sentences were false. That is a credibility problem,
  and with a technical judge it is the expensive kind.

**But remediation does not move the three scores that matter** — theme fit, demonstrability, adoption
all stay at 2/5 after every fix. The fixes are *cheap*, which is exactly why "we couldn't fix it" was
never the reason.

Two structural findings settled it:

- **The claims you can enforce and the claims you can bond are different sets.** The strongest
  guarantee in the library can never actually be slashed. The README's own worked example — *"40 ETH
  staked on never exceeding its budget"* — **is the one stake that can never be lost.**
- **A hook can extract value three ways, and the clever v4-specific mechanism only sees one of them.**
  The second is closed by ordinary arithmetic that needs none of the novelty. The third cannot be
  closed by this design at all.

### What we do instead — your investment is not lost

```
  2h   delete three contracts        ──► removes four of the audit findings outright
  12h  retract every false claim, re-measure gas
  16h  fix the extraction blind spot ──► buys the right to say "a spec it cannot violate"
  10h  build the permission census   ──► true no matter what we submit (see below)
  20h  the SUBMITTED hook inherits Assay, bonds a ceiling on its own escrow, deployed
```

**~60 hours, none of it on the submission's critical path.** The submitted hook gets to say: *"we
have staked 1 ETH that we lose if our own escrow ever exceeds its declared ceiling — here is the
address."* That is scored under Unique Execution (25%) and Presentation (10%), and it beats another
feature.

**Hard condition:** only make that claim if the blind spot is fixed first. Shipping "carries a spec it
cannot violate" with a known hole hands a judge the thread that unravels the submission.

### The free artifact worth building regardless

Sweep every hook address that has ever created a Uniswap v4 pool, decode what each is permitted to do
**from the address alone, with zero calls**, and publish the table:

> *"N deployed hooks. X of them can move a swap's output. **Zero** declare a machine-checkable spec.
> **Zero** have any capital at risk."*

One day's work, true under every branch, doesn't consume the submission, and it is the most
persuasive single artifact available to us in any framing.

---

## 5. The capstone repo — **leave it**

Not a close call, and **you had already ruled on this twice in writing** (`IMPLEMENTER_BRIEF.md:143`
and the Hardcap plan: *"Prior VPIN repo code does not count as hookathon work. New files only."*).

- **Fails three binary gates as-is**: all code predates the window; it implements a curriculum-taught
  fee mechanism; no partner-integration line.
- **Two critical bugs, both measured.** The core metric subtracts one token's units from the other's —
  identical balanced flow reads 0.003 on a 1:1 pool and **0.607 on a 1:4 pool**, and pins at maximum
  fee forever on a real pair. And the fee is stale by one trade, so **the toxic swap pays the old fee
  and the surcharge lands on the next, innocent trader.**
- **Nothing is reusable.** Its block tick is recorded at the wrong moment, it never holds a token, and
  it has no periphery. What remains is ~30 minutes of stock boilerplate we already have.
- Its lane is the single most saturated in the dataset: **189 of 662 submissions, 29% of everything.**

The one thing worth keeping is a lesson, not code: **a 1:1 test fixture hides every unit-mixing bug.**
SWITCHBACK and HASTE both compare quantities across the two sides of a pool, so both are exposed.
Every mechanism gets tested at a non-unit price, with a negative control. That is now project law.

---

## 6. Recommendation

**Build SWITCHBACK. Publish Assay alongside it. Keep HASTE as a funded option.**

1. **Week 1 — three experiments, in parallel, before any production code.**
   (a) **The reflexivity test, first:** does the fee still separate extraction from honest two-sided
       flow when the block-open reference is stale by a realistic amount? OpenZeppelin's shipped
       analogue warns that deterring round trips degrades the arbitrage keeping that reference
       honest. **If this fails, SWITCHBACK fails, and everything after it is wasted.**
   (b) Fix the beneficiary problem (aged-LP escrow + JIT activation delay) and prove it in tests.
   (c) Measure retail impatience — the number that decides whether HASTE ever gets built.
2. **Weeks 2–5 — build SWITCHBACK**, tested at non-unit prices with negative controls throughout,
   inheriting Assay so it bonds a ceiling on its own escrow, and deploy it.
3. **In parallel, cheap —** the permission census, and publish the two research findings that are
   true regardless (the ERC-6909 delta-laundering result, and the census itself).
4. **Week 6+ — decide on HASTE** with the impatience number in hand. If it is favourable, HASTE is an
   *extension* of a working, deployed hook rather than a parallel bet. If not, nothing is lost.

**Why not SLUICE, despite the higher ceiling:** its recapture half cannot be demonstrated, its
toxicity judgement is undesigned, and it needs an off-chain component. Those are three unknowns
against SWITCHBACK's one. If the incumbent verification comes back badly for SWITCHBACK, SLUICE is
the fallback — and its CoW integration is already proven by a real settlement, so the switch is not
from zero.
