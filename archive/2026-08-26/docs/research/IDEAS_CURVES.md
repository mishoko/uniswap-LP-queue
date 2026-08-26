# IDEAS_CURVES — four invariants for a v4 pool, and the theorem that bounds all of them

*Written 2026-08-26, quantitative market-design seat. Every prior-art count was produced by a `jq`
query against `docs/research/data/hook_directory_662.json` run during this session; the regex is
printed beside the count. Every gas figure is labelled **ESTIMATE** unless it says measured — none of
these are measured, and per the repo's standing orders nobody may quote them as if they were.*

---

## 0. THE STRAIGHT ANSWER

**One of the four is, in my honest judgement, a 4.3–4.5: §3 TIDE.** The other three are 3.5–3.9 and
I say why. I am not going to inflate them; the owner asked for 4.5 and the useful output of this
session is one candidate plus the reason the other twelve hours produced nothing.

**And here is that reason, which I think is worth more than any of the four.** I derived it while
trying to build a curve that prices adverse selection, and it says such a curve cannot exist:

> ### THEOREM (depth ≡ adverse selection). For **any** AMM, with `V(p)` the LP's value function and `x(p)` the risky-reserve schedule,
> ```
> LVR rate       ℓ(σ,p) = ½·σ²·p²·|x'(p)|          (Milionis–Moallemi–Roughgarden–Zhang)
> marginal depth  d(p)  = |dx/d ln p|·p = p²·|x'(p)|   (value tradeable per unit log-price)
> ```
> ### These are the SAME QUANTITY. `ℓ = ½σ²·d`, identically, for every invariant, at every price.
>
> Check against the known constant: CPMM has `x = L/√p`, so `p²|x'| = L√p/2 = V/4`, and
> `ℓ = ½σ²·V/4 = σ²V/8` ✓ — the textbook result, recovered from the depth side.
>
> **Corollary — the no-free-lunch law of curve design.** No static geometry can improve an LP's
> adverse selection *per unit of depth offered*. A curve that halves LVR halves depth by exactly the
> same factor. Concentrated liquidity, StableSwap, Orbital, weighted pools, Lambert — all of them move
> along the same line; none of them changes its slope. **Depth is not a good the LP sells and LVR is
> not a tax on it. They are one object seen twice.**

That closes the lead's direction #1 ("a curve that prices adverse selection directly") as stated: **a
function of the current reserves cannot do it, because pricing adverse selection down *is* pricing
depth down.** The only remaining degrees of freedom are the three the theorem leaves open:

| Free dimension | What it means | Candidate here |
|---|---|---|
| **(a) time** — *when* depth is offered | depth in the favourable direction can be made to vest | **§2 RATCHET** |
| **(b) direction** — asymmetric depth | you may be deep one way and thin the other | §2 RATCHET, and Nezlobin (curriculum) |
| **(c) unforgeable conditioning state** | the curve reads something the arb cannot cheaply fake | **§4 PARITY** |
| **(d) a different axis entirely** | the theorem is about the *swap* manifold. The **liquidity axis is untouched by it.** | **§3 TIDE ← this is why TIDE is the best one** |

§5 TILT is the honest attempt to beat the theorem head-on. It fails, and the *way* it fails is a
result in itself, so it is written up in full.

---

## 1. GROUND RULES ESTABLISHED BEFORE GENERATING

Checked every candidate against `CLAUDE.md` §5 **first**, not after:

| Fact | Consequence for a curve |
|---|---|
| §5.17 **Splitting Lemma** | A curve may not key on a per-swap or per-action **magnitude**. Every charge below is a **path integral with no per-unit threshold** — I state the integrand each time. *No minimum-charge floors anywhere: a floor is a threshold and the Lemma eats it.* |
| §5.18 **A hook cannot pay the trader** | Kills every rebate design. All four settle **only into LPs**. This also independently kills §6.1 SPRING. |
| §5.19 four evasions | Each candidate gets an explicit 4-row table. Anything failing a row is killed, not caveated. |
| §5.16 `sender` is the router | No candidate reads identity. This is why **TIDE beats the repo's own TENURE**, which is age-keyed and therefore address-shoppable for 52,700 gas. |
| §5.11 `donate()` pays who is in range **NOW** | Load-bearing for TIDE: the donate must be ordered *before* the entrant's liquidity exists. v4's callback order gives exactly that, for free. |
| §5.10 non-unit price fixture | Every candidate below compares quantities across the two sides. **All numerical work must be done at a non-1:1 price with a negative control**, or it proves nothing. |

**The settlement constraint, confirmed by execution in this repo** (`docs/DECISION_CANDIDATES.md:17`,
`IDEAS_MECHANISM.md` Q1/Q4): a NoOp'd swap returning **zero** output reverts through `V4Router` with
`IV4Router.V4TooLittleReceived(1, 0)` and through `UniswapV4Router04` with `SlippageExceeded()`. But
Q4 proves the escape: `beforeSwapDelta.specified = +amountIn` **plus a nonzero negative unspecified
delta** is **router-clean with real slippage protection on (minOut = 98%)**, and leaves
`slot0.sqrtPriceX96` bit-identical. **⇒ A custom curve is fully router-compatible provided it returns
a real, nonzero output. The NoOp constraint bites only designs that defer the fill.** None of the
four defer.

---

## 2. RATCHET — the executable price is a low-pass filter of the pool's own price

### 2.1 The invariant

Ordinary AMMs expose the marginal price `p` to everyone symmetrically. RATCHET keeps a second state
variable — an EMA of the pool's own log-price — and makes the **executable** price a one-sided clamp
against it:

```
p̄ ← p̄ + α·(ln p − p̄)                     α = 2^-n  (pure integer shift, in tick space)

executable price for a BUYER  :  p_exec = max( p ,  e^p̄ )
executable price for a SELLER :  p_exec = min( p ,  e^p̄ )
```

In one line: **a price improvement must age before anyone may trade on it.** A move against you is
available immediately; a move in your favour vests with time constant τ = 1/α.

Equivalently as geometry: the pool's quote correspondence is the **upper concave envelope of the
CPMM curve and its own τ-delayed shadow**. It is not a spread (the two sides are not symmetric about
`p`) — it is a *ratchet*, which is why it costs honest flow far less than a spread of equal
protective power (see 2.5).

### 2.2 What the geometry solves that parameters/governance don't

A sandwich is profitable **iff the back-run leg can access the price improvement the victim created.**
Every existing answer is a *parameter*: a dynamic-fee hook that guesses when to raise the fee, a
governance-set surge fee, an off-chain private mempool. RATCHET removes the access **geometrically** —
the improvement does not exist in the quote function yet.

### 2.3 Mechanism

- Permissions: `beforeSwap` + `BEFORE_SWAP_RETURNS_DELTA` (or the cheaper `afterSwapReturnDelta`
  form; see 2.4). No `donate` needed if the clamp surplus is retained as hook-held ERC-6909 and paid
  to LPs at a later `donate` — but §5.11 applies to that donate, so **compose with TIDE (§3), which
  fixes exactly that.**
- State: one `int24 emaTickX` and one `uint32 lastUpdate` per pool. **Two slots, and they pack into
  one.**
- Trigger: every swap.
- Return: the hook returns the surplus `(p_exec − p)·size` as a positive `int128` in the **unspecified**
  currency, i.e. the standard `FeeTakingHook` sign convention already spiked in
  `docs/SPIKE-sender-and-afterSwapReturnDelta.md` §2. **The hook only ever takes; it never pays.**
  Complies with §5.18 by construction.

### 2.4 Is it computable on-chain? — YES, and this is the cheapest of the four

Do the whole thing in **tick space**, where log-price is already an integer:

```solidity
int256 d = int256(currentTick) - emaTick;
emaTick += d >> n;                       //  α = 2^-n exactly. No transcendental. No fixed point.
```

- EMA update: **~1 SLOAD + 1 SSTORE + 3 arithmetic ops. ESTIMATE ~2,300 gas** (dominated by the warm
  SSTORE).
- Clamp: one comparison in tick space, then `TickMath.getSqrtPriceAtTick` — already in v4-core, **~1,000
  gas ESTIMATE**.
- Surplus: one `FullMath.mulDiv`. **~700 gas ESTIMATE.**
- **Total ESTIMATE ~4,000–6,000 gas/swap.** Same order as the repo's *measured* 4,509–5,766 for
  Assay's ledger and metering paths, which is the only like-for-like anchor I have.

**Precision loss — and it is NOT exploitable, for a structural reason worth naming.** The clamp is
**unilaterally adverse to the trader**: `p_exec` is never better for them than `p`. Therefore any
rounding error, tick-granularity error, or EMA staleness can only cause the pool to **overcharge**,
never to underpay. **RATCHET cannot lose money; it can only be too expensive.** That is a much
stronger safety posture than any custom curve that must quote a price it will honour, and it should
be the first sentence of any pitch. The residual: sandwiches smaller than 1 tick (1 bp) of price
impact escape the clamp entirely — and are unprofitable at any realistic gas cost anyway.

### 2.5 Free-lane audit

| Where | Verdict |
|---|---|
| **Manipulate p̄ up, then sell into it** | To raise p̄ you must hold the price up for ~τ, paying the ordinary manipulation cost and eating the clamp on the way in. **Closed, but only up to the cost of manipulation — it is expensive, not impossible.** |
| **Trade at the moment p̄ = p** | No clamp, no surplus. This is the *quiet* pool state — the top-of-block arb after a quiet period sits exactly here. **RATCHET does nothing against LVR. State this.** |
| **liquidity → 0** | The clamp is a price cap, not a quantity; it degrades gracefully. No division by L anywhere. ✓ |
| **Pool init / long dormancy** | p̄ must be seeded to the init tick. A dormant pool has p̄ ≈ p, so the clamp is inert — no stale-reference lane. ✓ |
| **Honest cost, and it is real** | An honest trader **selling into a rally** (or buying into a dump) within τ pays the full clamp. That is mean-reverting flow — the flow that makes the pool's price accurate. **RATCHET taxes the price-correctors.** Disclose on camera. |

### 2.6 Attack, unlimited capital + flash loans

Flash-loan the price to `p+X`, wait for p̄ to follow (requires holding it — flash loans do not survive
a block), then unwind. **Not a single-transaction attack**, so flash loans buy nothing; it degenerates
to ordinary multi-block price manipulation priced at the usual cost.

### 2.7 Prior art — and this is where RATCHET loses its novelty

- **OpenZeppelin `AntiSandwichHook`** ships in `lib/uniswap-hooks` (v1.2.0, read in full this session).
  Its NatSpec: *"this hook guarantees that no swaps get filled at a price better than the price at the
  beginning of the slot window (i.e. one block)"*, crediting umbraresearch.xyz. **That is RATCHET with
  `τ = 1 block` and a hard reset.** It is free, it is in the library Uniswap's own Security Framework
  names first, and it is already written.
- **Our only differentiators, and I will state them precisely because they are the whole case:**
  1. OZ resets at the block boundary. `CLAUDE.md` §5.19 row 3: **waiting one block boundary costs 200 ms
     on Unichain.** OZ's protection is therefore defeated by a cross-block sandwich for 200 ms of price
     risk — the *identical* hole this repo already found and measured in SWITCHBACK (free lane #5,
     "still-profitable 27.9% in-block → 82.6% cross-block"). **An EMA has no boundary to wait for.**
  2. OZ's own NatSpec: *"The Anti-sandwich mechanism only protects swaps in the zeroForOne swap
     direction. Swaps in the !zeroForOne direction are not protected by this hook design."* RATCHET is
     symmetric by construction.
  3. OZ's own NatSpec: *"the hook iterates over all ticks between last tick and current tick… could lead
     to `MemoryOOG`."* RATCHET is O(1).
- ⚠ **But `CLAUDE.md` §5.20 already contains the measurement**: *"the EMA horn closes the cross-block
  route completely and costs 7.2% of LP P&L."* **This team has already modelled an EMA reference.**
  RATCHET is a different device (an executable-price clamp, not a fee reference) but it lives on the
  same knob, and §5.20 says the knob has exactly two settings and we only choose which cost to pay.
- Directory: `anti.?sandwich|sandwich.resist|block.open|clamp|uniform price|batch auction` → **1 / 662**
  (`VeiledBatch`, UHI7, Fhenix Prize — FHE batch auction, unrelated device).

### 2.8 Score

Original **3.0** (it is OZ's shipped hook with a better filter — three real defects fixed, but a judge
holding `uniswap-hooks` asks "so it's the OZ one with an EMA?") · Unique Execution **3.5** · Impact
**4.0** · Functionality **4.5** (by far the most buildable thing in this document; O(1), integer-only,
cannot lose money) · Presentation **4.0** ⇒ **weighted 3.68.**

**Verdict: the best engineering, the worst novelty. Ship it as a component, not as the submission.**

---

## 3. TIDE — the liquidity axis gets an invariant  ★ THE ONE I WOULD BET ON

### 3.1 The observation the whole thing rests on

In every AMM ever shipped, the pool's state space has a **flat direction**. Swapping moves you along a
curve and costs you the spread. But minting and burning liquidity at the current price is
**value-neutral by construction, path-independent, and free** — you can move along the `L` axis at
zero cost, forever, in both directions.

> **Every zero-cost direction in a state space is a free option, and every free option gets extracted.
> JIT liquidity is not an exploit. It is the pool's flat `L`-direction being priced by the market,
> correctly, at zero.**

That is why `LiquidityPenaltyHook` exists, why "sustainable liquidity" is half of this hackathon's
title, and why every answer so far has been a *heuristic* bolted on from outside — position age,
`bornBlock`, a lockup, a governance-set exit fee. **Nobody has given the `L` axis a curve.**

### 3.2 The invariant

Extend the pool's manifold from `(x, y)` to `(x, y, L, A)` where `A` is the **accumulated total
variation of log-liquidity**, decaying with time constant τ_L:

```
Φ(x, y, L, A) :   x·y  =  L²·e^{-2·g(A)}                     ( = L² when A = 0, i.e. plain CPMM )

dA = |dL| / L                     (total variation — a PATH INTEGRAL, see 3.5)
A(t) = A(t₀)·e^{-(t-t₀)/τ_L}      (decay between actions)
g(A) = ½·c·A²    ⇒   g'(A) = c·A          c is the single parameter — the analogue of the fee tier
```

Read it in words:

> **Churning liquidity does not merely cost a fee — it converts your nominal `L` into less effective
> depth, and the difference is capitalised to the LPs who did not churn. The pool's depth remembers
> how much its liquidity has moved recently. Depth decayed by churn is restored, continuously, at rate
> 1/τ_L, to whoever is still there.**

The marginal charge on an LP action `dL` at pool value `V`:

```
dC  =  V · g'(A) · |dL| / L        =  V · c · A · |dL| / L
```

and for a **round trip** of size ΔL = m·L (adding m× the pool and removing it again):

```
C_round-trip  =  V·c·m·(2A + m)   ≈   c·m²·V     for small A
              =  (cost as a fraction of the JIT's own deposited capital)  =  c·m
```

### 3.3 Why the depth≡LVR theorem does not apply

§0's theorem is a statement about the **swap** manifold — it constrains `x(p)` and nothing else. `L` is
not in it. **TIDE is the only one of the four that is not bounded by it**, which is exactly why it is
the only one I think can reach 4.5. It is not trying to beat adverse selection; it is charging for an
option (the option to supply depth **only when it is safe to**) that is currently given away at zero.

The economic sentence: **a JIT LP is long the fee and short nothing. A resident LP is long the fee and
short the LVR. TIDE prices the difference, and it prices it as geometry rather than as an age check.**

### 3.4 Mechanism — and the v4 callback order does the hard part for free

The load-bearing problem in every JIT defence is §5.11: **`poolManager.donate()` pays whoever is in
range NOW**, so a penalty paid to "the LPs" is partly refunded to the attacker — an entrant who adds
10× the pool owns 10/11 of it and gets 10/11 of their own penalty back. **That kills the naive design
outright, and it is the reason OZ's `LiquidityPenaltyHook` had to go age-based instead.**

v4's callback ordering solves it exactly:

| Action | Callback | What TIDE does | Why it is correct |
|---|---|---|---|
| **add** | `beforeAddLiquidity` | `poolManager.donate(key, ...)` the charge | The entrant's liquidity **does not exist yet**. 100% of the donate lands on incumbents. |
| | `afterAddLiquidity` + `AFTER_ADD_LIQUIDITY_RETURNS_DELTA` | return the charge as a delta, settling the debt opened above | Both callbacks are inside **one unlock**; the deltas net. |
| **remove** | `beforeRemoveLiquidity` | compute the charge, take it via the remove-delta flag | |
| | `afterRemoveLiquidity` | `donate` | The exiter's liquidity is **already gone**. 0% refund. |

**Permissions needed:** `BEFORE/AFTER_ADD_LIQUIDITY`, `BEFORE/AFTER_REMOVE_LIQUIDITY`,
`AFTER_ADD_LIQUIDITY_RETURNS_DELTA` (`1 << 1`), `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` (`1 << 0`) —
verified present in `Hooks.sol`. **No swap-path callbacks at all**, so TIDE adds **zero gas to swaps**
and composes with any swap-side hook — including RATCHET (§2), whose one weakness is exactly the
donate it needs to make. **The two compose into a single hook and each fixes the other's hole.**

### 3.5 The Splitting Lemma — passed by construction, and this is not a caveat, it is the design

`CLAUDE.md` §5.17 kills any mechanism keyed on a magnitude. TIDE's charge is `∫ V·g'(A)·|dL|/L`, the
**path integral of the total variation of log-liquidity**. Split one add of ΔL into k adds of ΔL/k and
the integral is *identical* (in fact marginally larger, since `A` rises along the way). **There is no
per-unit floor, no minimum charge, no threshold** — I deliberately removed the "1 wei minimum" I first
wrote, because it is precisely the threshold the Lemma eats.

### 3.6 Is it computable on-chain?

Everything is one `mulDiv` and one decay:

```solidity
// decay: exact for integer half-lives, no transcendental
A = A >> ((block.timestamp - lastTouch) / HALF_LIFE);        // coarse, exact, ~150 gas
A += FullMath.mulDiv(absDeltaL, ONE, L);                     // dA = |dL|/L
charge = FullMath.mulDiv(FullMath.mulDiv(V, c*A, ONE), absDeltaL, L);
```

- **ESTIMATE ~3,000 gas** of arithmetic, on top of `donate` (~15–25k) and the delta settlement
  (~10–20k). **Total ESTIMATE 30–50k per LP action, 0 per swap.** LP actions are rare and already cost
  150k+; a 25% overhead on an action taken twice a year is the right place to spend gas, and I would
  defend that number on camera. It is also the honest weak point: **it makes LPing measurably more
  expensive, for everyone, always.**
- Coarse half-life shifting loses precision for sub-half-life gaps. **Round the decay DOWN (i.e. keep
  `A` high, keep the charge high)** so precision loss always favours the pool. Same posture as §2.4.

### 3.7 Free-lane audit — and one lane is open

| Where | Verdict |
|---|---|
| **Split the add** | Closed by the path integral (3.5). ✓ |
| **Wait a block between legs** | τ_L ≫ 1 block by construction, so 200 ms buys ~nothing. Closed. ✓ |
| **Address-shop the position** | TIDE never reads a position, an owner, or an age. **The §5.12 router-keying problem does not arise, and the 52,700-gas evasion does not apply.** This is TIDE's single biggest advantage over the repo's own TENURE and over OZ's `LiquidityPenaltyHook`. ✓ |
| **Add in a far tick range** | With a **global** `A`, honest LPs adding at distant ranges subsidise churn at the active tick. With a per-range `A`, an attacker JITs a fresh range each time. **I would ship global and disclose it.** ⚠ |
| **Be a resident LP and JIT on top** | Their own resident position catches part of the incumbent donate. Cost of that mitigation = real capital at risk in the pool, continuously. **Reduced, not eliminated. Same shape as §5.11's documented OZ bypass. Disclose.** ⚠ |
| **liquidity → 0** | `dA = |dL|/L` **divides by L**. As `L → 0`, `A → ∞` and the pool bricks. ⚠⚠ **This is a real boundary failure and it must be handled explicitly**: clamp `dA` and floor `L` at the pool's minimum-liquidity constant, or the first LP into an empty pool pays an unbounded charge and no pool can ever be bootstrapped. **Curves die at their boundaries and this one dies at L=0.** |
| **First LP into a new pool** | `A = 0`, so charge = 0. ✓ (and the L→0 clamp above must not undo this). |

### 3.8 Attack, unlimited capital + flash loans

The strongest attack is **capital-scaled JIT below the profitability threshold**. JIT with
`ΔL = m·L` pays `c·m²·V` and captures `f·Q·m/(1+m)` of the fee it fronts, so it is profitable only
below the root of `c·m²·V = f·Q·m/(1+m)`. **Solved numerically this session** (`V = $1M`, `f = 5 bps`,
a `$1M` swap):

| `c` | JIT profitable only below | fee the surviving JIT captures | cost to an honest LP adding 10% of the pool |
|---|---|---|---|
| 0.005 | m = **9.2%** of the pool | 8.4% | 0.05% of their deposit |
| **0.02** | m = **2.4%** of the pool | **2.4%** | **0.20%** of their deposit |
| 0.05 | m = **1.0%** of the pool | 1.0% | 0.50% of their deposit |

**At `c = 0.02`, JIT is confined to ≤2.4% of the pool and captures ≤2.4% of the fee it fronts — a
~97% reduction in JIT extraction — while an honest LP adding 10% of the pool pays 20 bps once.**
⚠ **Sub-threshold JIT is NOT killed, only shrunk.** I first wrote "16%" here from a sloppier
break-even that forgot the JIT's pro-rata share `m/(1+m)`; the corrected number is better for TIDE and
it is the one that must be quoted. Repeat attempts within τ_L push `A` up, so the second JIT in the
window costs strictly more. ✓ Flash loans do not help: the charge scales with capital deployed.
**And 20 bps per LP round trip is a real cost that must clear the owner's bar — see §8.**

**What TIDE does NOT do, and it is half the theme:** it does nothing about sandwiches, nothing about
LVR, nothing about toxic swap flow. It is a sustainable-liquidity mechanism only. That is why it
should be shipped *with* RATCHET, and why the pair is the actual proposal.

### 3.9 Prior art

- `JIT|just.in.time|liquidity penalty|liquidity sniping` → **21 / 662, 4 prized** — and reading them,
  every single one is (i) an age/lockup heuristic, (ii) a JIT *provider* (the opposite side), or
  (iii) a rebalancer. `ParityTax-AMM` (UHI5, UHI6, unprized) is the nearest in *intent* — *"minimize
  fee revenue concentration by JIT liquidity providers with a progressive [tax]"* — and it is a **tax
  on fee revenue**, i.e. keyed on a magnitude, which §5.17 kills.
- **OZ `LiquidityPenaltyHook`** (in `lib/`): age-keyed, exit-side only, and §5.11 records its own
  NatSpec admitting the donate bypass. TIDE is stateless w.r.t. identity and charges both legs.
- Off-chain literature: Balancer/Curve join-exit fees (flat parameters, not path integrals); Ambient
  knockout liquidity (different device); Bunni v2 surge fee (**swap**-side, not L-side). **I found
  nothing, on-chain or in the literature, that gives the liquidity axis its own invariant with a
  decaying total-variation accumulator.** If a reviewer finds one, TIDE drops to a 3.
- `weighted pool|dynamic weight|TFMM|QuantAMM|balancer|curvature|concentration` → **6 / 662, 0 prized**,
  none related.

### 3.10 Score

Original **4.5** (the "flat direction" framing is, as far as I can find, unstated anywhere, and the
invariant follows from it in one step) · Unique Execution **4.5** (the donate-ordering construction in
3.4 is genuinely v4-specific, non-obvious, and directly resolves a §5.11 hole this repo already burned
time on) · Impact **4.0** (dead centre of "sustainable liquidity"; applies to every pool) ·
Functionality **4.0** (small, O(1), no transcendentals, zero swap-path cost — but the `L → 0` boundary
and the global-vs-per-range choice are real work) · Presentation **4.5** ("every AMM has a free
direction in its state space, and JIT is the market pricing it correctly at zero" is a 20-second
opening that a judge will remember) ⇒ **weighted 4.33.**

**This is the only thing I produced today that I would put in front of a judge.**

---

## 4. PARITY — a curve for assets with an on-chain redemption, priced by the queue

### 4.1 The asset class nobody has a curve for

Not stables (StableSwap), not volatile pairs (x·y=k), not correlated baskets (Curve/Orbital). The gap
is **assets with an on-chain mint/redeem primitive at a computable rate and a non-zero redemption
delay**: every LST (stETH via the withdrawal queue), every ERC-4626 share, every CDP stable with a PSM,
every tokenized bill. Enormous TVL, and the curve they trade on is one that does not know they are
redeemable.

Two distinct leaks, both currently paid by LPs:

1. **Yield-accrual LVR.** The redemption rate `R` rises every block. A CPMM's quote does not, so every
   accrual is a free arbitrage. `σ²V/8` does not even cover this — it is a *deterministic* leak.
2. **Depeg convexity.** In stress, the fair value is bounded below by redemption-at-`R`-in-`T`, but
   the CPMM keeps quoting all the way to zero. LPs are forced sellers below fair value.

### 4.2 The invariant

Work in **redemption-adjusted coordinates**, then add an inventory term derived from the queue:

```
x = the liquid asset, y = the redeemable claim, R = convertToAssets(1) (the token's own definition)

BASE:       x · (y·R)  =  k                 constant product in redemption-adjusted units
            ⇒ the marginal price tracks R with no trade and no arbitrage.  Leak (1): zero, arithmetically.

INVENTORY:  p_quote = R · ( 1 − θ(T_queue) · (y·R) / (x + y·R) )

            θ(T) = the pool's own cost of being forced to carry the claim for the queue length T
                 = the discount at which an instant-liquidity provider breaks even against redeeming.
```

`T_queue` is readable on-chain (Lido's withdrawal queue length; an ERC-4626's cooldown). **The pool
quotes a discount that grows with how much of the illiquid side it already holds and how long it would
take to unwind it.** That is Almgren–Chriss inventory risk written as an AMM invariant, with the
liquidation horizon *known* rather than estimated.

### 4.3 Computability

`R` is an external `staticcall` (**~5,000 gas ESTIMATE**, and see 4.5 — this is the weak point).
Everything else is two `mulDiv`s. `θ(T)` from a small monotone lookup table on queue buckets (**~2,100
gas**, one SLOAD). **Total ESTIMATE ~9,000 gas/swap.** No transcendentals. Rounding always toward the
pool.

### 4.4 Free-lane audit

- **`R` jumps down (a slashing event).** The pool is instantly stale by the full jump and eats one
  complete LVR event. **Unavoidable without a circuit breaker, and a circuit breaker is a parameter.**
- **liquidity → 0**: `(x + y·R)` in the denominator → clamp, same class of boundary bug as TIDE's.
- **θ discontinuity at bucket edges**: a searcher stands exactly at a bucket boundary and trades
  across it. **Use a piecewise-linear θ, never a step.**
- **The real lane: `R` is manipulable if the vault is.** An ERC-4626 whose `totalAssets` can be
  donated into is an inflation-attack surface, and PARITY would quote off it.

### 4.5 Attack

Flash-donate into the vault to inflate `R`, sell the claim into the pool at the inflated quote, redeem.
**Whether this is closed depends entirely on the paired vault, not on us** — which means PARITY's
safety is not a property of PARITY. Mitigation is a rate-of-change clamp on `R`, i.e. a parameter, i.e.
exactly what the brief said to avoid.

### 4.6 Prior art — this is where PARITY loses

**Curve's `stableswap-ng` already does the `R` part**, via `stored_rates` / `rate_multipliers` reading
`getPricePerFullShare`, and **Balancer has shipped "rate providers" for LSTs for years.** The
redemption-adjusted invariant is standard practice at two of the three largest AMMs. Directory:
`4626|redemption|withdrawal queue|stETH|LST|rate provider|exchange rate` → **25 / 662, 3 prized**
(`YieldAware`, `YieldSense`, `LST-Optimized Hook` all read the rate for **dynamic fees**, not for the
curve — a real distinction, but a one-sentence-deep one).

**The queue-derived inventory term `θ(T_queue)` is the genuinely new half**, and I cannot find it
anywhere. But it is one term on top of a curve two incumbents already ship.

### 4.7 Score

Original **3.0** (half of it is Curve's shipped behaviour) · Unique Execution **3.5** · Impact **4.5**
(the leak is real, continuous, and measurable in dollars today) · Functionality **4.0** ·
Presentation **3.5** ⇒ **weighted 3.58.**

**Verdict: the biggest real-world impact and the weakest novelty. And it is off-theme without the
compensating WOW that criterion #3 requires. Do not submit it.**

---

## 5. TILT — the pool solves for its own shape, and the answer is bad news

### 5.1 The idea, and it is the honest attempt to beat §0's theorem

For the weighted family `(x+a)^w·(y+b)^{1−w} = k`, everything is closed form:

```
LP value            V ∝ p^w
LVR rate            ℓ = ½·σ²·w(1−w)·V              (from V'' = w(w−1)p^{w-2})
marginal depth      d =      w(1−w)·V              ⇒ ℓ = ½σ²d  ✓ consistent with §0
fee income          F = f·Q_arb(w(1-w)) + f·Q_noise
```

`w` is a **shape** parameter — a real geometric degree of freedom. Make it state, and solve for the `w`
at which the pool's **realized** LVR equals its **realized** fee income. Both are measurable by the pool
from its own tick path with **no oracle, no volatility model, no governance**:

```
w_{n+1} = w_n − η·( ℓ̂_n − F̂_n )/V     with  ℓ̂_n = ½·Σ(Δ ln p)²·w(1−w)·V   (realized, from ticks)
```

**The pitch:** *"this pool computes, live, whether market-making this pair at this fee tier is a losing
business, and re-shapes its own curve until it isn't."*

### 5.2 The hard part, and this is the actual contribution

**Changing a curve's shape moves its quoted price, and a price move nobody traded for is free money.**
This is the general law I derived and it governs every reshaping design:

> ### THE SHIFT/SPREAD LEMMA. For a quote function decoupled from inventory, any component that moves the **mid** is a free lane (drainable: buy before, sell after). Only the **symmetric spread** component is safe.

**QuantAMM / TFMM ships exactly this problem** (Balancer v3, dynamically-updated weights driven by
on-chain rules) and rate-limits the weight change to bound the arbitrage. That is a mitigation, not a
fix.

**TILT's fix, and it is real:** re-weight along the **tangent**, using the virtual reserves `(a, b)` as
the two free parameters:

```
choose (a', b', k') such that   [w'/(1−w')]·(y+b')/(x+a')  =  p        (marginal price continuous)
                          and    the new curve passes through (x, y)   (reserve point continuous)
```

Two constraints, two free parameters — generically solvable in closed form. The new curve is then
**tangent to the old one at the current state**. Both are concave, so any round trip through the
re-shape still crosses the tangency point from the unfavourable side: **round-trip profit ≤ 0**. That
is a fuzzable invariant (`assertLe(roundTripProfit, 0)` over `(w, w', direction, size)`) and it is a
genuine improvement on the published state of the art.

### 5.3 Computability — the most expensive of the four

`(x+a)^w` needs `exp(w·ln(·))`. Solady `powWad`: **ESTIMATE ~1,500–2,500 gas each, two per swap ⇒
~5,000**, plus the swap solve. **Total ESTIMATE ~8,000–12,000 gas/swap**, versus ~3–5k for CPMM math.

**Precision loss IS exploitable here, unlike §2 and §3.** `powWad`'s ~1e-18 relative error compounds
across two calls, and a curve that must *honour* a quote can be drained by a searcher who repeatedly
trades in the direction the error favours. **The mitigation is mandatory: recompute `k` after every
swap and revert unless `k' ≥ k`.** That is a hard invariant, it is cheap, and it must be fuzz-asserted
at a **non-1:1 price with a negative control** (§5.10) — a 1:1 fixture would hide a token0/token1 unit
mixing bug in the two `pow` calls completely.

### 5.4 ⚠ THE FINDING THAT KILLS IT

Work out where the feedback law converges.

`ℓ` and the **arb** component of `F` are **both proportional to `w(1−w)`** — that is §0's theorem
restated. So the objective is:

```
maximise   f·Q_noise  +  f·c·w(1−w)  −  ½σ²·w(1−w)·V
```

The `w(1−w)` terms are **linear in the same variable**. There is no interior optimum. Either
`f·c > ½σ²V` and the law runs to `w = ½` (plain CPMM — do nothing), or `f·c < ½σ²V` and it runs to
**`w(1−w) → 0`: the corner, a pool with zero curvature and zero depth.**

**The pool's honest answer to "what shape should I be?" is "you should not exist."** Which is
*economically correct* — if the fee tier does not cover LVR, the profit-maximising depth is zero — and
it is a **terrible product**: a hook whose fixed point is turning itself off.

And the second problem: even away from the corner, drifting to `w = 0.9` means the pool's inventory
drifts to 90/10. **You did not fix the LP's LVR; you changed what the LP holds, without asking.**

### 5.5 Score

Original **4.0** (the tangent reparametrization is a real result and beats QuantAMM's rate-limit) ·
Unique Execution **3.5** · Impact **2.0** (the fixed point is degenerate) · Functionality **2.5**
(`powWad` precision + a solvency invariant + a control loop, in 8 weeks, under a hard robustness
requirement) · Presentation **3.5** ⇒ **weighted 3.20.**

**Verdict: killed by its own arithmetic, and the arithmetic is §0's theorem coming back around. Keep
the Shift/Spread Lemma (5.2) and the tangent construction — both transfer.**

---

## 6. KILLED IN GENERATION — with the reasoning, so nobody re-derives them

### 6.1 SPRING — the invariant as potential energy. **Killed by 10 lines of arithmetic.**

`x·y = k + κ·D²` where `D` is decayed net log-displacement: extending the price *charges* `κ(2Dδ+δ²)`,
retracing it *pays back*, and undecayed potential leaks to LPs. Beautiful, and it **subsidises
sandwiching**. Front-run δ, victim v, back-run δ:

```
paid     = κ[(D+δ)² − D²]
received = κ[(D+δ+v)² − (D+v)²]
NET      = +2·κ·δ·v   >  0   for every δ, v
```

**The sandwicher extends cheap and retracts dear, and the spring pays them `2κδv`.** No choice of
rebate fraction ρ fixes it (`2ρκδv > 0` for all ρ > 0). Capping the rebate at what the retractor paid
requires identity ⇒ 52,700 gas to evade. And §5.18 kills it independently: **a hook cannot pay a
trader at all.**

> **GENERAL LEMMA, and it is worth keeping:** *any curve that rebates retracement in proportion to
> accumulated displacement subsidises sandwiching.* Corollary — **SWITCHBACK and SPRING are duals**:
> charge-the-retracer (SWITCHBACK) taxes sandwiches *and* honest reverters; charge-the-extender with a
> rebate (SPRING) subsidises sandwiches. **Charge the extender, never rebate** — and that is Nezlobin's
> directional fee, which is **taught in the UHI curriculum** and therefore a Gate-1 originality problem.

### 6.2 QVAR — the pool charges its own realized gamma. **Killed by the Splitting Lemma.**

`x·y = k·exp(λ·Σ(Δ ln p)²)`: the invariant grows by exactly the realized LVR the path generated,
computed in closed form from the pool's own ticks, no vol parameter. Lovely. But the charge is `λδ²`
per swap, so splitting one move into `n` costs `λδ²/n` — **defeated by a factor of n for the price of
gas** (§5.17, precisely). Fixing it by accumulating over a window turns it into 6.1's "charge the
extender", i.e. Nezlobin.

### 6.3 BUCKET — replenishing depth (`L(t)` refills at rate `r`). **Killed by our own graveyard.**

Genuinely attractive theory: the arb's optimal control is bang-bang and LP loss per unit time is capped
at `r × gap`, **independent of σ** — "the first AMM with a bounded loss rate". But when the bucket is
full after a quiet period, the first trade takes all of it. **That is `HardcapHook`'s economic
inversion verbatim** (`CLAUDE.md` §6: *"First swap of block was tax-exempt → subsidises the
top-of-block race"*), and §5.17 corroborates from the directory:
`circuit break|price band|rate.?limit|max.{0,6}impact` → **6 built, 0 prized.**

### 6.4 Uniform-price batch clearing. **Killed by the router.**

The only geometry that makes a sandwich profit *exactly zero* rather than merely negative is a uniform
clearing price per block — the attacker's two legs net to zero, contribute nothing to `p*`, and clear
at the same price. It requires deferring the fill, and a NoOp'd swap returning zero output **reverts**
through `V4Router` (`V4TooLittleReceived`), proven by execution in this repo.

### 6.5 pm-AMM as a hook. **Killed on originality, and I want to flag the temptation.**

`pm-amm|LMSR|scoring rule` → **2 / 662, 0 prized.** Implementing Paradigm's pm-AMM as a v4 hook is
*structurally the identical move* that won Orbital the Uniswap Prize — implement a Paradigm AMM paper
as a hook. **That is exactly why it is worth less the second time**, and "we implemented a published
paper" caps the 30% Original category. Noted so nobody rediscovers it and gets excited.

---

## 7. SCOREBOARD

| | Original 30% | Unique Exec 25% | Impact 20% | Functionality 15% | Presentation 10% | **Weighted** |
|---|---|---|---|---|---|---|
| **§3 TIDE** | 4.5 | 4.5 | 4.0 | 4.0 | 4.5 | **4.33** |
| §2 RATCHET | 3.0 | 3.5 | 4.0 | 4.5 | 4.0 | **3.68** |
| §4 PARITY | 3.0 | 3.5 | 4.5 | 4.0 | 3.5 | **3.58** |
| §5 TILT | 4.0 | 3.5 | 2.0 | 2.5 | 3.5 | **3.20** |
| *(existing shortlist: SWITCHBACK 3.95 · SLUICE 4.05 · HASTE 4.10)* | | | | | | |

---

## 8. WHAT I WOULD ACTUALLY DO

**Ship TIDE + RATCHET as one hook.** They are disjoint in the callback space — TIDE touches only the
liquidity callbacks, RATCHET only the swap callbacks — so it is one contract, not two mechanisms
spread thin. And each closes the other's hole: RATCHET's clamp surplus needs a `donate` that §5.11
says an attacker can catch with JIT liquidity, and **TIDE is the thing that makes catching it
unprofitable.** That is a real, non-decorative composition, which is what §8 of `CLAUDE.md` says the
Assay fold failed to be.

The pitch is two sentences and it covers both halves of the theme:

> **"Every AMM has a free direction in its state space. Adding and removing liquidity costs nothing, in
> either direction, forever — so JIT liquidity isn't an exploit, it's the market correctly pricing a
> free option at zero. TIDE gives the liquidity axis its own invariant, and a price improvement has to
> age before anyone can trade on it."**

**Riskiest assumption, and it must be validated before any code is written** (PDCA, §1): §3.8's
table says `c = 0.02` confines JIT to 2.4% of the pool at a cost of **20 bps to an honest LP adding
10%**. That is 4× the 5 bps I would have called acceptable, and it is computed from a single
representative `(V, f, Q)` — not from real data. **The one experiment that decides TIDE:** replay real
v4 add/remove size distributions and swap sizes, and find whether any `c` simultaneously (i) confines
JIT below ~5% of the pool and (ii) costs the median honest LP under ~5 bps per round trip. Run it with
a **negative control** (`c = 0` must reproduce today's JIT profitability exactly, or the model is
wrong) and at a **non-1:1 price** (§5.10 — the charge compares `V` against `L`, both two-sided
quantities, so a 1:1 fixture would hide a unit-mixing bug completely).
**If no such `c` exists, TIDE is dead and I want that said plainly rather than the parameter tuned
until a chart looks good.** Given this repo's record — distrust-green went 6 for 6 — assume it is dead
until that simulation says otherwise.

---

## PROVENANCE

- `docs/research/data/hook_directory_662.json` — 662 rows, all counts above re-runnable via the
  printed regexes.
- `lib/uniswap-hooks/src/general/AntiSandwichHook.sol` (OZ v1.2.0) — read in full; NatSpec quoted
  verbatim, including its three self-declared limitations.
- `lib/.../v4-core/src/libraries/Hooks.sol` — the four `RETURNS_DELTA` flag values, read from source.
- `docs/DECISION_CANDIDATES.md:17`, `docs/research/IDEAS_MECHANISM.md` Q1/Q4 — the NoOp-reverts and
  inventory-fill-is-router-clean results, both proven by execution in this repo.
- `docs/SPIKE-sender-and-afterSwapReturnDelta.md` — the `afterSwapReturnDelta` sign convention.
- `CLAUDE.md` §5.10–§5.20, §6 — all constraints applied before generation.
- **§0's identity and §6.1's SPRING algebra were both verified numerically this session, with negative
  controls.** §0: `ℓ / (½σ²·d) = 1.000000000` for CPMM, a `w = 0.9` weighted pool and constant-sum;
  the CPMM case independently recovers `depth = V/4` and `ℓ = σ²V/8`; a deliberately wrong depth
  definition (dropping the `p²`) gives ratio 9.0, so the check is not vacuous. §6.1: the sandwich net
  equals `+2κδv` in all 36 grid cases, and 0 when the victim size is 0.
- LVR rate `ℓ = ½σ²p²|x'(p)|`: Milionis, Moallemi, Roughgarden, Zhang, *Automated Market Making and
  Loss-Versus-Rebalancing*. The `ℓ = ½σ²d` identity in §0 is my derivation from it; the CPMM constant
  `σ²V/8` is recovered as a check and matches.
- QuantAMM / TFMM (Balancer v3 dynamic weights), Curve `stableswap-ng` `stored_rates`, Balancer rate
  providers, umbraresearch.xyz sandwich-resistant AMM: **cited from my own knowledge, NOT fetched this
  session.** Anyone betting on §5 or §4 must verify these directly first.

---

# PARAMETER EXPERIMENT — 2026-08-26. TIDE is ALIVE, and the frontier has a closed form.

*Script: `docs/research/data/tide_parameters.py`, seed `20260826`, fully reproducible
(`python3 tide_parameters.py`). This section supersedes §3.8's table, which was computed by hand from
one representative `(V, f, Q)` and understated the honest-LP cost in one place and overstated
deterrence in another.*

## P.0 STRAIGHT ANSWER

**A viable `(c, τ_L)` window exists, and it is not a tuned point — it is a closed-form frontier that
the numerical joint search reproduces to within 5%:**

> ### `honest LP round-trip cost  ≥  f · Q_big / V`
> The minimum a resident LP can be charged, per round trip, to fully deter a sniper is **the fee
> revenue of the largest swap that sniper would target, divided by the pool's value.** No choice of
> `c`, `τ_L`, or mechanism variant beats it.

At `f = 5 bps` this clears the owner's 5 bps bar whenever **`Q_big/V ≤ 0.5`** — no single swap worth
more than half the pool. That covers essentially all real ETH/USDC-class flow and **fails exactly on
thin and newly-launched pools**, which must be said out loud.

## P.1 CONTROLS FIRST — and one caught a defective result of mine

| Control | Result |
|---|---|
| **Units** — `P = 3000` (non-1:1), decimals **18 / 6** (non-equal), per §5.10 | token→`m` matches value→`m` ✓; a deliberately unit-mixed variant does **not** match ✓ (so the control is not vacuous); a 90/10 deposit gives the same `m` as 50/50 ✓ |
| **NEGATIVE CONTROL — `c = 0` must reproduce today's JIT** | optimal `m` = **147% of the pool (pinned at the grid cap)**, capturing **59% of the fee**, `T` = 0.2 min. Unbounded appetite, near-total capture, instant exit. **PASS** — that is observed JIT behaviour. |
| **Closed form vs numerical search** | independent derivation `f·Q/V` vs joint `(c, τ_L)` grid: 0.25/0.25, 0.50/0.50, 1.25/1.26, 2.50/2.65, 5.00/5.24, 10.00/10.51 bps. **Agrees to ≤5%.** |

⚠ **DEFECTIVE-GREEN CAUGHT, IN MY OWN FIRST RUN — recorded because it is the point.** v1 reported
*"JIT capture 0.0% at every `c ≥ 0.02`, across every `τ_L`, in both regimes."* Too good, and it was.
The sim fed the sniper the **event-averaged** `A`, which is sampled *after* the actor's own `A += m`
and is therefore `A_pre + E[m]` — **24× the true ambient**. Every deterrence number in that run was
fake. **Distrust-green is now 7 for 7 on this team, and the seventh was mine.** The fix is one line —
always charge and always model the **pre-action** `A` — and it is the load-bearing detail of any
implementation.

## P.2 THE FRONTIER — the trade, not a point

Minimum honest round-trip cost (bps) at each level of JIT confinement, searched jointly over
`c ∈ [1e-4, 50]` (log grid) × `τ_L ∈ {10 min, 1 h, 6 h, 1 d, 3 d, 10 d}`:

| `Q_big/V` | closed form `f·Q/V` | **honest cost, JIT fully dead** | best `(c, τ_L)` | honest cost, JIT ≤10% capture |
|---|---|---|---|---|
| 0.05 | 0.25 bps | **0.25 bps** | c=1.6e-4, 6 h | 0.15 bps |
| 0.10 | 0.50 bps | **0.50 bps** | c=1.9e-3, 1 h | 0.29 bps |
| 0.25 | 1.25 bps | **1.26 bps** | c=2.0e-4, 1 d | 0.72 bps |
| **0.50** | 2.50 bps | **2.65 bps** ✓ | **c=0.064, 10 min** | 1.51 bps |
| 1.00 | 5.00 bps | **5.24 bps** (borderline) | c=0.126, 10 min | 2.97 bps |
| 2.00 | 10.00 bps | **10.14 bps** ✗ | c=1.6e-4, 10 d | 5.86 bps |

**The frontier is regime-independent** — a healthy pool (36.5% fee APR, 4.5% LVR) and a toxic one
(4.6% fee APR, 12.5% LVR) give the same numbers to two decimals. **And Variant B (charging only the
burst above a slow 7-day reference) does NOT beat it** — 0.51 / 1.31 / 2.59 / 5.16 / 10.19 bps against
Variant A's 0.50 / 1.26 / 2.65 / 5.24 / 10.14. **The frontier is a property of the problem, not of my
formulation**, which is the strongest thing I can say about it.

**In terms the owner can act on:** at `Q_big/V = 1.0`, honest LPs pay **5.24 bps per round trip**. An
LP holding the median 14 days pays **0.37 bps/day**. A sniper taking one opportunity a day pays 5.24
bps/day — **14×** — and at ten opportunities a day, **140×**. *That* is the discrimination: not
identity, not age, but **turnover frequency**, and it is unforgeable because turnover is a path
integral.

## P.3 WHY — and this is the honest limitation of the mechanism

There are two deterrence channels and only one of them works:

| Channel | Charge | Hits honest LPs? | Verdict |
|---|---|---|---|
| **self-term** `c·m²` — the sniper's own entry raises `A` before their own exit | only round-trippers within τ_L | **no** (they hold past τ_L) | **Worthless at the optimum.** Measured: in a healthy pool the sniper's net carry while waiting is **−6.03 bps/day** — they *earn* while waiting — so they wait ~3τ_L for free and the self-term decays to `e⁻³` = 5% of itself. Even in the toxic regime (carry **+4.91 bps/day**) waiting is cheap relative to `c·m²`. |
| **ambient** `2·c·A_pre` | every round trip, size-blind | **yes, at the same rate** | **This is what deters, and it is why the frontier is what it is.** Sniper revenue per unit deposit is `f·Q/V`; cost per unit deposit is `2cA` — the *same* `2cA` the honest LP pays. Deterrence requires `2cA > f·Q/V`, so honest cost `= 2cA > f·Q/V`. **QED.** |

⚠ **Say this on camera and do not dress it up.** At the deterrence optimum, TIDE is economically a
**split-proof, congestion-priced turnover charge**. Its content over a flat LP entry/exit fee is
genuine but narrower than §3 claims: (i) it is a path integral, so it survives the Splitting Lemma
where a per-action fee does not; (ii) it is congestion-priced, so it is ~0 in a quiet pool and rises
only where churn is actually happening; (iii) the `c·m²` self-term does kill the **instant, same-block,
mempool-bundled JIT** outright — the attack as actually practised — even though a patient sniper
escapes it. **A judge who asks "so it's a deposit fee?" deserves those three sentences, not a
deflection.**

## P.4 THE EXIT TRAP — real, and cleanly fixed

`CLAUDE.md` §5.3: never trap LP capital. Uncapped, TIDE is a **bank-run amplifier** — a mass exit is
itself a churn burst, so `A` spikes and the last LPs out pay the most. At the viable `c = 0.126`, a
50% exodus inside τ_L would cost the leaver **6.3% of their deposit.** Unacceptable.

**Fix: cap `A` at `A_max`.** Deterrence runs off *ambient* `A` (~0.002), so a cap two orders of
magnitude above ambient costs nothing:

| `A_max` | × ambient | deterrence kept? | worst-case exit cost |
|---|---|---|---|
| 0.01 | 5× | **YES** | 0.13% of deposit |
| **0.05** | **25×** | **YES** | **0.63% of deposit** |
| 0.25 | 125× | YES | 3.15% |
| uncapped | — | YES | **UNBOUNDED** ✗ |

**Ship `A_max = 25× ambient`.** Zero deterrence cost, run exposure bounded at 63 bps, §5.3 satisfied.
It is a third parameter, and I would rather have a third parameter than a mechanism that punishes
leaving.

## P.5 WHAT THIS DOES NOT SETTLE

1. **The distributions are synthetic and they are the load-bearing assumption.** No real v4 add/remove
   or swap-size data was fetched. Ambient `A_pre = ρ·τ_L` with ρ = 0.2/day (10% of pool value added and
   as much removed, daily); median add 2% of pool, lognormal σ=1.0; median hold 14 days. **The frontier
   `f·Q_big/V` is derived analytically and does not depend on them; the honest-cost *level* does.**
   Halve ρ and every honest number halves.
2. **`Q_big` is a judgement call, not a measurement.** The whole answer is "how large is the largest
   swap worth sniping, relative to the pool". That is one query against real pool data and it is the
   next thing to run.
3. **Range-rebalancing is charged too.** A remove+add to re-centre a range pays a full round trip.
   **TIDE taxes active LP management (Arrakis/Gamma-style) at the same rate it taxes snipers.** Not
   modelled here; it is a real adoption objection.
4. **A sniper who is a large resident LP catches part of their own donate** (§3.7). Unmodelled.

## P.6 REVISED SCORES

| | before | **after** | why |
|---|---|---|---|
| Original (30%) | 4.5 | **4.0** | The working channel is size-blind; the "new geometry" claim is narrower than §3.10 asserts. The flat-direction framing and the path-integral construction survive; "it beats a deposit fee" is now a three-clause answer, not a one-liner. |
| Unique Execution (25%) | 4.5 | **4.5** | Unchanged. The donate-ordering construction (§3.4) is untouched by any of this and is still the best v4-specific idea in the repo. |
| Impact (20%) | 4.0 | **3.5** | Works where `f·Q_big/V ≤ 5e-4`. **Fails on thin and new pools — which is a real part of the sustainable-liquidity problem, and the part the theme cares most about.** |
| Functionality (15%) | 4.0 | **4.0** | Unchanged. The `A_max` cap is cheap and the `L→0` clamp is known. Everything is O(1) integer math and the parameterization is now closed-form rather than fitted, which is *better* than before. |
| Presentation (10%) | 4.5 | **4.5** | Unchanged, and the frontier is a better slide than a single point. |
| **Weighted** | 4.33 | **4.08** | Still the best candidate this project has. |

**Verdict: NOT DEAD. Build it — with the `A_max` cap, and with §P.3 said out loud in the video rather
than discovered by a judge.**
