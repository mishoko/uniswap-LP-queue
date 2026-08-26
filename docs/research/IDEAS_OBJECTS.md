# IDEAS_OBJECTS — five tradeable objects a v4 hook can mint

*Written 2026-08-26 by the First Principles / Economic Incentives seat, on the brief:
"stop inventing fee mechanisms; invent objects." Every prior-art count below was produced by a regex
I ran in-session against `docs/research/data/hook_directory_662.json`; the regex is printed next to
the count. Nothing is quoted from memory of the directory.*

---

## 0. THE STRAIGHT ANSWER, UP FRONT

**One of the five is worth the owner's attention: §1 QUEUE, honestly scored 4.18.** That is the
highest anything in this project has scored, and it is the first candidate that is *not* a fee rule.
It is **not a certain 4.5**, and I will not pretend it is — its Functionality score is the weak leg
and I explain exactly why below. But it is the first idea I have written here where the sentence
*"nobody has done this and it is obvious in hindsight"* survives my own attack.

Two of the five (§4 MOAT, §3 STRIPS) are honest 3.5s — no better than the standing shortlist, and I
would not switch for them. One (§5 PICKOFF) **I killed while writing it**, on prior art that is
prized. §2 TENANT is real, novel by count, and has a build risk I do not think we clear in 8 weeks.

### The structural finding that organised the whole pass — and it is reusable

> **A v4 hook can address its LPs. It can NEVER address its traders.**
>
> `sender` in every swap callback is the router (`CLAUDE.md` §5.16, asserted in-repo); `hookData` is
> caller-supplied and empty through every standard router; the hook never sees the recipient. So no
> object can ever be *minted to a swapper* — not a rebate claim, not a receipt, not a refund, not a
> loyalty token. But a hook that **custodies its own liquidity** transacts with its depositors
> directly, in its own `unlock()`, and knows exactly who they are.
>
> ⇒ **Every mintable object in Uniswap v4 is LP-side or pool-side. The trader-side object class is
> empty and provably so.** *(This is `CLAUDE.md` §16 + §18 restated as a statement about **objects**
> rather than about gates and refunds. I derived it independently during this pass and then found §18
> already in the constitution — treat it as corroboration, not a new discovery.)* That is why `Tidehook` is 1 of 662 (W8), why the fee-rebate-for-good-flow
> prompt (official example #3) has no clean implementation, and why uniform-price batch clearing
> needed FHE *and* custom periphery to appear once (W7). It also means the "unbundle the LP position"
> seed in the brief is the *only* seed that is structurally open. I generated against it deliberately.

### On the brief's IL-vs-adverse-selection question — they are genuinely distinct, and it does not save us

They are not the same thing renamed. **IL is a terminal, path-independent function of price** (it
nets out if price returns). **LVR is a path-dependent, monotonically-accumulating rate** (it never
nets out; it is the integral of what arbitrageurs took on the way). Unistrata / Schizō / StructuredYield /
Vixa split the *IL* axis. Splitting the *LVR* axis is a real, separate, unbuilt object —
**and I killed it anyway in §5**, because `VFA Hook` (UHI8, **prized**) already tokenises pool
realised variance and `Divergence Index & Swap` (UHI9) already built a perpetual on the LP-loss index.
The axis is distinct; the lane is occupied.

---

## 1. QUEUE — price-time priority for AMM liquidity

### 1.1 What the object IS

> **A transferable claim on *where in the fill order* your capital sits.** Two LPs at the same tick
> with the same capital hold different assets: one is filled first by every swap, the other only when
> a swap is large enough to sweep through. The claim is fungible per pool, transferable, and priced by
> the market — including, if we want the demo, in its own Uniswap pool.

### 1.2 Mechanism sentence

> **State:** the hook custodies all of the pool's liquidity in its own position (a wide band or full
> range) and keeps an ordered list of depositors — a head cursor plus per-entry token0/token1 balances.
> Each entry's rank is an ERC-6909 balance, freely transferable.
> **Trigger:** every swap. In `afterSwap` the hook has the realised `BalanceDelta` and therefore the
> swap's realised average price. It allocates the fill **front-first**, not pro-rata: the head entry
> gives up as much of the outgoing token as it holds, receives the incoming token at the swap's
> realised average price, and keeps the fee on the slice it filled. The cursor advances only when an
> entry is exhausted; a typical small swap touches one entry, so the allocation is O(1) amortised.
> **Settlement:** a depositor withdraws whatever their entry currently holds. Rank transfers move the
> position in the queue, not the capital.

### 1.3 THE THESIS — the best sentence in this document

> **Every concentrated AMM in existence is a pro-rata market. Every real electronic market on earth is
> price–time priority, and queue position is the single most valuable asset in electronic market
> making. Uniswap has never had a queue, so it has never had a price for one.**
>
> And the price of that queue is the thing this hackathon says cannot be measured. Open problem #3 is
> *"dynamic fees alone can't distinguish good retail flow from bad toxic flow."* QUEUE does not try to
> detect toxicity — `IDEAS_CONSTRAINED` §1 proves no forgeable-proof signal exists. **It sells LPs
> different slices of the flow and lets them bid.** A pool where the front seat trades at a premium is
> a pool with benign flow; a pool where the front must be *paid* to stand there is a toxic pool, and
> the size of that payment is the toxicity, denominated in the pool's own numéraire, discovered by
> capital rather than asserted by a formula. **Unforgeable, because the bid costs real money.**

### 1.4 WHO BUYS IT AND WHO SELLS IT — both sides, concretely

This is the question that kills most candidates in this space. It does not kill this one, and — this
is the important part — **the mechanism works whichever way the price goes.**

| | Buys the front | Sells the front |
|---|---|---|
| **Who** | A professional market maker, a searcher, a JIT bot, an internaliser | Passive capital: a treasury, an LST/stable issuer, a yield vault, retail LP |
| **Why** | Front-of-queue sees **every** swap, including the small ones that never reach the back. That is maximal flow per unit of capital. A party that can hedge its inventory elsewhere wants maximum flow and does not fear the inventory. | The back only trades when a swap is big enough to sweep — i.e. only against the flow most likely to be informed. Passive capital would rather be paid a known amount up front than discover its adverse-selection cost after the fact. |
| **If flow is toxic instead** | The front eats every informed slice first and **must be paid to stand there**. That payment is a bid *from* the back *to* the front. | The back is now the safe seat and pays for it. |

**What is actually created:** today, adverse selection is an unpriced, undiversifiable cost smeared
pro-rata across every LP. QUEUE turns it into a **priced, transferable, tradeable position**, and
routes it to whoever is best equipped to bear it. That is exactly what a designated-market-maker
franchise does in TradFi, and exactly what payment-for-order-flow does — **except the payment goes to
the LPs instead of to a broker.**

**Price discovery, three options, cheapest first:** (a) let the rank token trade in its own Uniswap
pool — elegant, zero extra code, and the demo is *Uniswap pricing Uniswap's own toxicity*;
(b) a **Harberger tax** — your rank is always for sale at your self-declared price and you pay
`τ × price` per block to the entries behind you, which forces honest self-assessment and needs no
bidders to show up; (c) a per-block bid auction — **rejected**, it is am-AMM's shape and lands us in
Atrium's AVOID list.

### 1.5 The free-lane audit — the cheapest way to get the benefit without paying

This project has been killed seven times by a mechanism whose deterrent becomes the cheapest action.
I looked for it here specifically.

1. **Split your order to stay at the head.** An informed trader slices into N small swaps so each
   hits only the front. Cost is gas — fractions of a cent on Unichain, per the ledger theorem's own
   measurement. **This is real and it is not a hole, it is the design.** Splitting concentrates the
   informed flow *onto the front seat*, which is precisely the seat that is priced. The market
   responds by repricing the front downward until someone is willing to hold it. The mechanism never
   assumed size ⇒ toxicity, which is what every previous flow-segmentation attempt did assume.
   **This is why QUEUE survives the §1 impossibility proof and Tidehook did not.**
2. **Wash-trade from the front to farm fees.** You pay the fee and you receive the fee, because you
   are the seat being filled. Net ≈ −gas. **Closed by construction.**
3. **Sit at the back and free-ride on the depth the front provides.** You cannot: depth is your own
   capital, and the back is filled on exactly the trades that hurt most. Free-riding is not available
   — the back is a *worse* seat, which is why it is paid.
4. **⚠ THE ONE I CANNOT CLOSE: rank-then-run.** Buy the front cheaply during a quiet stretch, and hop
   out before a scheduled event (a listing, an unlock, a CPI print) by dumping the rank token. The
   rank token's price will gap, so you eat the gap — but you eat it *only if there is a bid*. **In a
   thin secondary market the front seat is abandonable at the exact moment it matters.** The Harberger
   variant closes it (you cannot leave your slot; you can only lower your self-assessment and pay
   rent, and someone buys you out at your own number). **If we build this, build the Harberger
   variant.** Disclose the thin-market failure of the plain-token variant on camera.
5. **Grief the front by dusting.** Depositing dust to occupy the head is only possible if rank is
   granted by deposit order. **Rank must be bought or Harberger-held, never granted.**

### 1.6 The attack — unlimited capital, flash loans

- **Mint and dump atomically?** No. The rank token is not minted against a payout; it *is* your slot.
  Buying it and selling it in one transaction leaves you exactly where you started minus fees.
- **JIT-shaped entry/exit capturing a payout without the exposure?** The payout *is* the exposure —
  there is no separate reward stream to capture. A JIT bot that buys the front for one block pays the
  incumbent (recapture ✓) and bears that block's fills (exposure ✓). **This is the desired behaviour,
  not an attack.**
- **Flash-loan the whole queue.** You become every LP for one transaction. You then trade against
  yourself: you pay yourself the fee and flip your own inventory. Zero-sum minus gas. Closed.
- **Manipulate the realised average price used for allocation.** The allocation price is the swap's
  *own* realised average, taken from PoolManager's returned `BalanceDelta` — it is not a mark, not an
  oracle, and not a quantity the hook chooses. There is nothing to push. **This is the single biggest
  structural advantage QUEUE has over §2 TENANT and every mark-to-market design in this repo.**

### 1.7 v4 feasibility — checked against all 17 hard-won facts

| Fact | Status |
|---|---|
| §5.16 `sender` is the router | **Not touched.** All authentication is LP-side, inside the hook's own `unlock()`. |
| §5.12 PoolManager keys positions by the unlock's `msg.sender` | **Satisfied by construction** — the hook *is* the unlocker and the position owner. This is the design, not a workaround. |
| §5.11 `donate()` pays whoever is in range now | **Not used.** Fees are allocated inside the hook's own ledger. |
| NoOp'd swap returning zero output reverts through the router | **Not used.** Swaps execute normally, at the normal price, through any router. **QUEUE is router-clean by construction — the trader's experience is unchanged.** |
| `beforeAddLiquidity` returns `bytes4` only | Sufficient: we *revert* every external add so the hook is the sole LP. |
| §5.17 fairness/history are not present-state | Rank is present state. No history, no markout, no fairness claim. |
| §5.10 a 1:1 fixture hides unit-mixing bugs | **THE LIVE RISK.** The allocator splits a two-token delta at a realised ratio. **Every test must run at a non-unit price with a negative control**, or a token0/token1 mix-up passes green. |
| §5.5 unbounded returndata copy | No calls out to untrusted code. |

**Honest build assessment.** The allocator is deterministic arithmetic over an ordered list, which is
testable and provable — but it is also the *entire* pool's accounting, rewritten by us. A bug there is
not a degraded feature, it is lost funds, and "robust code is a hard requirement." The saving grace is
that using a **single wide-band position** removes all per-tick maths: the hook never has to attribute
a fill across ticks, only across the queue at one realised average price. That is the design I would
build, and it is the reason I score Functionality 3.5 rather than 2.5.

### 1.8 Prior art

- `queue|price.time|time priority|fill priority|pro.?rata|fifo` → **6 / 662, and none of them are
  this.** The six are order queues for *swaps* (SwapPilot's NoOp queue, ZeanHook's batch, RWAsync),
  not an ordering over *liquidity*.
- `designated market maker|dmm|market maker.*(seat|franchise|obligation)` → **0 / 662.**
- `harberger|self.assess|common ownership|always for sale` → **0 / 662** (a naive `\bcost\b` in my
  first regex produced 10 false positives; corrected).
- `payment for order flow|pfof|internali[sz]` → 2 / 662, both am-AMM auction hooks.
- Nearest real neighbours: **am-AMM family** (`am-AMM hook` UHI1, `Maestro` UHI6 ✳, `AuctionPool`
  UHI7, `Chronus` UHI2) — they auction **pool-management and fee-setting rights to one winner per
  block**. QUEUE sells **an ordering over the existing LPs' capital**, perpetually, to many holders,
  with no auction and no per-block winner. That distinction is one sentence deep and **a judge will
  test it**, so the pitch must lead with the pro-rata-vs-queue framing, not with the word "auction."
  **`Non-Fungible LP Positions Hook` (UHI8, unprized)** fractionalises a position into fungible shares
  — fungibility of capital, not of *rank*. Different object.

### 1.9 HONEST score

| Original 30% | Unique Exec 25% | Impact 20% | Functionality 15% | Presentation 10% | **Weighted** |
|---:|---:|---:|---:|---:|---:|
| 4.5 | 4.5 | 4.0 | 3.5 | 4.5 | **4.18** |

**Where I am NOT giving myself credit:** Impact is 4.0 and not higher because **QUEUE reallocates
adverse selection; it does not reduce it.** Total LVR paid by the pool is unchanged. What changes is
*who bears it and at what known price*, which is a real economic good (it is how insurance and
market-making franchises create value) but it is **not** "we stopped the sandwich," and I will not
let anyone write that sentence. Functionality is 3.5 because we are rewriting a pool's entire fill
accounting. Original is 4.5 not 5.0 because the am-AMM adjacency is one sentence away.

---

## 2. TENANT — the LP position, leased, settled in kind

### 2.1 What the object IS

> **A fixed-term lease on a live LP position.** The lessee holds the position's entire P&L — fees and
> inventory both — for N blocks. The lessor holds a claim to get their **original token basket back**
> at maturity, plus rent paid up front.

### 2.2 Mechanism sentence

> **State:** the hook custodies liquidity and records, per lease, the exact basket `(x₀, y₀)` handed
> over and the maturity block. **Trigger:** a lessee calls `lease(shares, term)`, pays rent in either
> token (settled straight to the lessors) and posts collateral. **Settlement:** at maturity anyone can
> close the lease; the lessee must return `(x₀, y₀)` **in kind** and keeps everything else; the
> shortfall in either token is taken from collateral, and a lease whose collateral is exhausted mid-term
> is closable early by anyone.

### 2.3 The thesis

> **am-AMM auctions the right to set the fee. It does not move the inventory.** But LVR is not a fee
> problem — it is an *inventory* problem: LPs lose because they are holding the wrong side while
> someone else knows the price moved. **If the arbitrageur holds the inventory, there is nobody to
> pick off.** TENANT does not deter the arb; it makes the arb the LP. LVR is internalised rather than
> extracted, and the passive lessor swaps an uncertain adverse-selection cost for a fixed rent.

### 2.4 Both sides

- **Lessee:** a market maker or arbitrage desk. They already run this book; they want AMM flow at a
  known cost of capital, and they can hedge the delta on a perp venue. Renting the pool's inventory
  is strictly better for them than arbing it, because they capture the fee stream too.
- **Lessor:** any passive LP. They receive the original basket back plus rent — **no IL, no LVR, in
  token terms, guaranteed up to lessee solvency.** That is the single most-demanded product in this
  whole dataset (38/662 on `insur|indemnif|tranche|senior|junior`), and TENANT delivers it without an
  insurance pool, without a premium model, and without an oracle.

### 2.5 The free-lane audit

1. **Manipulate the settlement mark.** **Closed, and this is the design's one piece of real
   cleverness: there is no mark.** Settlement is in kind — return `x₀` and `y₀`, the exact tokens.
   No price is ever read, so there is nothing to push. Every mark-to-market variant of this idea dies
   to a settlement-instant price push; the in-kind version does not.
2. **Lease and walk away when the position moves against you.** This is the whole risk, and it is
   *unbounded* — the shortfall in one token grows without limit as price moves. Requires collateral
   plus permissionless early close. **That is a margin engine, and it is a liquidation crank.**
3. **Lease the pool and then refuse to trade** — park the capital, pay rent, provide no depth. The
   lessor is unharmed (they get their basket + rent). The *pool* is harmed. Uncloseable without a
   depth obligation, which reintroduces §5's griefing problem.

### 2.6 The attack

Flash-loan a lease at the top of a block, front-run yourself into a huge price move, close early.
Blocked by term minimums and by in-kind settlement — moving the price hurts the position you are
holding. The genuine attack is **undercollateralisation into a gap**: on a volatile pair a 20% move
in one block leaves the collateral short and the lessor eats it. Mitigated only by conservative
collateral, which crushes the lessee's return, which is exactly the tension that makes this hard.

### 2.7 Prior art

`transfer.*(p&l|pnl)|position swap|position transfer` → **0 / 662.** `lease|rent|tenant|am-amm` →
8 / 662, 3 prized — all of them auction **management rights**, not the position's P&L. The nearest
is `PerpDexHook` (UHI3, **Uniswap Prize**): *"traders can rent underlying liquidity to take leveraged
directional trades"* — renting liquidity as *leverage*, with the LP still holding the pool risk.
Opposite direction. **The object is genuinely unoccupied.**

### 2.8 HONEST score

| Original | Unique Exec | Impact | Functionality | Presentation | **Weighted** |
|---:|---:|---:|---:|---:|---:|
| 4.0 | 4.0 | 3.5 | 2.5 | 4.0 | **3.68** |

**Why I am not recommending it:** Functionality 2.5. This is a **margin engine with liquidations on a
volatile pair**, shipped in 8 weeks, under a hard robustness requirement, by a team that has already
found three unbounded-returndata bugs in its own code. The idea is good. The build is the kind that
produces a green suite and a drained contract.

---

## 3. STRIPS — per-tick liquidity, made fungible

### 3.1 What the object IS

> **One fungible token per tick band.** Holding `STRIP[T]` means owning a share of whatever liquidity
> sits at tick band `T`, and earning exactly the fees generated when the price trades through `T`.
> An LP position stops being an indivisible NFT bundle and becomes a **portfolio of strips**.

### 3.2 Mechanism sentence

> **State:** the hook holds one position per tick band and an ERC-6909 supply per band. **Trigger:**
> `afterSwap` attributes the realised fee to the bands the price actually crossed, using only the
> pre/post ticks it stored itself. **Settlement:** burn `STRIP[T]` to withdraw that band's current
> composition. Strips transfer freely and can be bought and sold against each other.

### 3.3 Both sides, and the thing that makes it interesting

Buyer and seller are two LPs with different views on **where the price will spend its time** — which
is a view on the *distribution*, not the direction, and today there is no way to express it. The
by-product is the real prize: **the relative prices of the strips are an on-chain, oracle-free,
market-implied distribution of future price, produced by an AMM about itself, and unforgeable because
distorting it requires posting real capital.** That is a genuine new dataset in DeFi.

### 3.4 Free lane / attack

Wash-trading through a band you own recovers your own fee minus leakage — no gain. The real hole is
**gas**: one position and one token per band is expensive, and capping the number of bands is capping
the pool. Second hole: a strip near the price is worth more than one far away for reasons that have
nothing to do with the view being expressed (it just trades more), so the "implied distribution"
needs normalising by expected volume before it means anything — **and that normalisation is a model,
which is exactly the kind of thing this project keeps having to retract.**

### 3.5 Prior art

`per.tick|tick.level|tokeni[sz]ed tick|tick share|fungible.*(position|liquidity)` → 10 / 662, none
per-tick. `residence|time.in.range|dwell` → **0 / 662.** Nearest: `Non-Fungible LP Positions Hook`
(UHI8, unprized), which fractionalises a *whole* position. Unoccupied but adjacent.

### 3.6 HONEST score

| 3.5 | 3.5 | 3.5 | 3.5 | 3.5 | **3.50** |
|---:|---:|---:|---:|---:|---:|

**Off-theme** (no MEV protection, no defense, no recapture) and no better than the standing shortlist.
Not a switch candidate. Its one genuinely striking output — the implied distribution — is a *by-product*
we would have to argue for, and P5 says winners have a tradeable object, not an interesting readout.

---

## 4. MOAT — tail depth, leased and paid for out of touch fees

### 4.1 What the object IS

> **A transferable claim on a slice of the pool's fee stream, sold in exchange for an irrevocable
> commitment of depth at a *distant* tick band for a fixed term.** A bond whose coupon is paid by the
> liquidity at the touch and whose principal is at risk only in a crash.

### 4.2 Mechanism sentence

> **State:** per-band committed notional and maturity. **Trigger:** every swap routes a fixed share of
> the realised fee into a rent pot, paid pro-rata to committed tail bands. **Settlement:** at maturity
> the commitment is released and the depositor withdraws whatever composition the band now holds.

### 4.3 Both sides

**Seller of protection (buyer of the bond):** yield capital that wants fee income *without* adverse
selection — and tail depth is exactly that, because it is almost never traded, so its LVR is near
zero and its return is almost pure carry. **Buyer of protection:** the touch LPs and the pool itself,
who want a book that does not gap in a crash, because a pool that gaps loses its routing forever.
This is how exchanges pay designated market makers, and it is a real market.

### 4.4 The free lane — and it is not fatal, but it is not clean either

Post depth so far out it can never be hit, and collect rent for nothing. Bounding the eligible bands
turns the whole thing into a parameter fight (how far is far enough?), and this project's history says
a load-bearing parameter is where the pitch dies. The honest framing is that the rent *is* payment for
standing there and the risk is genuine, but there is no clean on-chain line between "insurance depth"
and "depth that will never trade."

### 4.5 Prior art

`tail liquidity|deep tick|backstop|wide range.*(incentiv|rent)` → 2 / 662, neither this.
But the *mechanism* is one sentence from "range-targeted liquidity mining," and
`Auction Managed AMM & Active Range Incentives in Any Currency` (UHI3, **prized**) already pays
incentives by range — for the *active* range, the opposite target, but a judge will hear the same word.

### 4.6 HONEST score

| 3.5 | 3.5 | 4.0 | 4.0 | 3.5 | **3.68** |
|---:|---:|---:|---:|---:|---:|

Highest Functionality of the five and the most on-theme of the non-QUEUE four ("sustainable liquidity"
is literally the theme). But Original 3.5 caps it, and 30% of the score is Original.

---

## 5. PICKOFF — the LVR strip. **I KILLED THIS WHILE WRITING IT.**

**What it was:** the pool mints and sells its own realised quadratic variation as a perpetual claim,
funded from fee accrual, with no oracle — the LP flattens their short gamma without leaving the pool
and the buyer gets the cheapest long-variance instrument in DeFi. The brief's "adverse-selection axis
may not be taken" hypothesis, built out.

**Why it is dead, and this took one query:**

- `VFA Hook` (UHI8, **PRIZED — Reactive Network**): *"a Uniswap v4 volatility futures primitive that
  lets users trade long/short volatility exposure instead of price direction. It captures onchain
  telemetry (tick movement, variance, volume) and settles epoch payouts deterministically."*
  **That is this object, with a prize already attached to it.**
- `Divergence Index & Swap` (UHI9): *"Index is the annualized LP loss as a fraction of pool due to IL,
  and created a perpetual market on top of it."* **That is the perpetual form.**
- `PegGuard — Measured IL Insurance` (UHI9) measures LVR/correcting flow and pays it out as insurance.
- `realized vari|variance swap|quadratic variation|volatility swap` → only 2/662 on the narrow regex,
  which is exactly the trap §5.13 warns about: **the lane looked empty on my first query and was not.**

**And the economics were bad anyway, which I want on the record so nobody rebuilds it:** a claim on
realised variance is **manufacturable**. Creating a tick move of `δ` costs fees roughly linear in `δ`;
the variance payout is quadratic in `δ`. **For large enough `δ` the manipulator always wins.** The only
fixes are a payout cap or a notional cap, and both cap the product to irrelevance. This is the standard
variance-swap manipulation problem and an AMM is the *easiest* place on earth to run it, because you
are manipulating the very index you are paid on, using the venue that publishes it.

**Score: 2.8. Do not build. Do not re-derive.** The brief's hypothesis was right that IL ≠ adverse
selection; it was wrong that the adverse-selection axis is unoccupied.

---

## 6. ALSO KILLED WHILE WRITING — so nobody re-derives them

| # | Object | Killed by |
|---|---|---|
| O1 | **The trader's slippage claim** — mint every swapper a claim on the impact they caused, redeemable if the price mean-reverts (i.e. they were noise, not information). Solves open problem #3 *ex post*, sidestepping the "no forgeable-proof signal" proof entirely. | **§5.16, absolutely.** The hook cannot see the trader — `sender` is the router and `hookData` is empty through every standard router. Minting to the router mints to the Universal Router. The only escapes are our own periphery (kills aggregator routing) or trusting caller-supplied `hookData` (forgeable for free). **This is the single best idea I had all session and v4 cannot express it.** |
| O2 | **The uniform-price block claim** — one clearing price per block per direction, so a front-run and its victim get identical fills and sandwiching is arithmetically impossible; the object is the intra-block claim token. | Dies twice: a NoOp'd swap returning zero output **reverts through the standard router** (proven in-repo), and any refund of the difference is a **trader-side** payment, i.e. O1's wall. **This is why W7 has exactly one entry and it needed FHE *and* custom periphery.** |
| O3 | **Probabilistic settlement** (W1 — taught by the curriculum, requested by name, 1/662, zero implementations) — the fill price is a draw from a distribution, so an arbitrageur cannot pick off a price they cannot predict. | **There is no unpredictable on-chain randomness available without deferral or an oracle.** Every input to a same-transaction draw is known to the searcher who chooses when to submit. Deferring to the next block is HASTE (time), not randomness. **W1's emptiness is a difficulty result, not white space** — and the owner's no-off-chain-component constraint forbids the VRF the curriculum assumes. Worth publishing as a finding. |
| O4 | **COVENANT — a machine-checkable liquidity SLA**: an LP mints a slashable, transferable bond promising `X` depth within `Y` ticks for `Z` blocks; a token issuer buys guaranteed depth instead of paying emissions for mercenary liquidity. `\bsla\b\|depth commit\|bonded liquid` → **2/662, neither relevant.** | **Griefing, cheaply.** Push the price out of the committed band and swap in the same transaction to trigger the breach: cost is a round-trip fee, prize is the entire bond. Defining the breach relative to a *history* violates §5.17; defining it on present state is exactly what makes it purchasable. Also it is bonded-attestation infrastructure — the lane `SECURITY_LANDSCAPE.md` counted at **0 for 9**. |
| O5 | **Tick-space occupancy rights** — make tick space finite property, so JIT liquidity must buy a seat from a patient LP. | Folded into §1 (the Harberger variant is the good half) and otherwise adjacent to a real lane: `LiqOS` (UHI4) already does *"auction-driven JIT provisioning"*, plus `AetherPool`, `ZK-JIT`, `sentry`, `ParityTax`. Standalone, its own kill is that **scarcity of seats = a cap on pool depth**, and a rival pool without the cap quotes better. |
| O6 | **The SHORT-LP token** — mint matched long/short LP pairs so the mirror of the LP payoff is directly tradeable. | It is §5's payoff form, and the *lane* is `Vixa`, `StructuredYield`, `Sochalant`, `Unistrata` ✳, `Schizō` ✳, `RiskShield`, `Kinetic Capital`, `STRATUM` — 38/662 on the tranching regex, freshly exhausted by UHI9's own theme. |
| O7 | **A curve on the liquidity axis** — price the act of *entering and leaving* the pool on a bonding curve, so exiting in a panic pays the LPs who stay. Genuinely new maths for an AMM (nobody has put a curve on `L`). | It is a **withdrawal fee**, which is a fee mechanism wearing a curve, and GMX/Balancer already price imbalanced joins. Also fails the brief's explicit "no fee mechanism." |
| O8 | **New maths generally, hunted deliberately for the Orbital precedent.** | I could not find one and I will say so plainly. The theme reduces to `fee·V_uninformed > σ²V/8`, and there are exactly three levers: charge a spread (fee), make execution non-instant (time), or make the price non-deterministic (randomness). The third is O3 and is impossible on-chain. **LVR is irreducible for any deterministic curve under continuous trading — it is a property of holding inventory, not of the curve's shape.** A flat segment maximises adverse selection rather than minimising it (it is a limit order). **Orbital's move was a new *domain* (N assets), not a new answer to LVR, and a 2-asset hook has no such domain to open.** |

---

## 6b. THE §19 CHECK — run FIRST, as the constitution now requires

`CLAUDE.md` §19 says to test every new candidate against the four proven evasions before anything
else. Four ideation passes and ~100 ideas have produced zero survivors of this table. **QUEUE passes
all four, and it passes them for a structural reason worth stating.**

| Evasion (§19) | Does it touch QUEUE? |
|---|---|
| **Splitting a quantity** (~gas) — §17 the Splitting Lemma | **No input is a magnitude.** Rank is an ordering, not a threshold. Splitting a swap into k parts does not reduce anyone's charge, because there is no charge — it merely routes all k slices to the head of the queue, which is the seat the market has already priced for exactly that. **§17 kills mechanisms whose input is a size; QUEUE's input is an order.** |
| **Address shopping inside one unlock** (52,700 gas) | **No identity, reputation or history input.** Splitting your capital across ten addresses buys you ten ranks and evades nothing; rank is a scarce ordered resource, not an attribute of who you are. |
| **Waiting one block boundary** (200 ms on Unichain) | **No per-block reference, no epoch, no reset.** The queue is continuous state. There is no boundary to wait for. |
| **The router opacity wall** (free, structural) — §16, §18 | **QUEUE never sees, gates, or pays the trader.** Every party it transacts with is a depositor inside the hook's own `unlock()`. §18's "paying LPs is the only option a v4 hook has" is not a limitation here; it is the entire design. |

**Why it passes, stated once:** §19's table constrains what a **charge** may key on, because every
candidate this project has generated has been a fee mechanism looking for a non-forgeable input.
**QUEUE charges nobody.** It creates no new payment, invents no new signal, and asks no question that
an adversary could answer falsely. It changes only *the order in which existing LPs are filled by
existing swaps at the existing price* — and then sells that order. There is nothing to forge because
there is no assertion being made. **That is the reason the table does not bite, and it is the reason
this candidate is different in kind from the seven that died before it.**

The other four in this document do **not** all pass: §2 TENANT needs a collateral magnitude and a
liquidation trigger (a threshold, hence §17 exposure via partial closes); §4 MOAT keys on committed
notional and band distance, both magnitudes; §3 STRIPS is clean on §19 but off-theme; §5 PICKOFF is
dead already.

---

## 7. SCOREBOARD, against the standing shortlist

| | Original 30% | Unique Exec 25% | Impact 20% | Functionality 15% | Presentation 10% | **Weighted** |
|---|---:|---:|---:|---:|---:|---:|
| **QUEUE** §1 | 4.5 | 4.5 | 4.0 | 3.5 | 4.5 | **4.18** |
| HASTE (standing) | — | — | — | — | — | 4.10 |
| SLUICE (standing) | — | — | — | — | — | 4.05 |
| SWITCHBACK (standing) | 3.5 | 4.0 | 4.0 | 4.5 | 4.0 | **3.95** |
| **TENANT** §2 | 4.0 | 4.0 | 3.5 | 2.5 | 4.0 | **3.68** |
| **MOAT** §4 | 3.5 | 3.5 | 4.0 | 4.0 | 3.5 | **3.68** |
| **STRIPS** §3 | 3.5 | 3.5 | 3.5 | 3.5 | 3.5 | **3.50** |
| **PICKOFF** §5 | 2.0 | 3.0 | 3.0 | 3.0 | 3.5 | **2.75** |

---

## 8. IS ANY OF THESE A GENUINE 4.5+? — my single honest answer

**No — but QUEUE is the first candidate this project has produced that could *become* one, and it is
the only idea I would spend an hour of the owner's time on.**

Honestly scored it is **4.18**, and the gap to 4.5 is entirely in **Functionality**, where I gave 3.5
because we would be rewriting a pool's whole fill accounting and I have watched this repo ship three
unbounded-returndata bugs. If a two-day spike shows the single-wide-band allocator is exact at a
non-unit price with a negative control, Functionality goes to 4.5 and the total to **4.48**. That is
the experiment, and it is cheap:

> **Deposit three entries at a 1:4 price, run one small swap and one sweeping swap, and assert that
> front-first allocation at the realised average price conserves both tokens exactly and leaves the
> queue in the predicted composition — with a negative control that goes red.** One afternoon. It is
> the riskiest assumption and it is directly testable, which is what §1's method asks for.

**What I will not claim:** QUEUE does not stop a sandwich, does not reduce total LVR, and does not
recapture value from searchers. It **prices** adverse selection and routes it to whoever will bear it
cheapest. That is a real economic good and a genuinely new object, and it is *not* the theme's
"neutralize the attack, recapture the value." A judge holding the theme slide will ask. The honest
answer — *"we did not find a way to destroy adverse selection, so we made it a tradeable asset and let
the market price it, which is the first time an AMM has produced a price for its own toxicity"* — is a
good answer, but it is an answer to a different question than the one on the slide.

**And the finding I would publish regardless of what we submit:** *a v4 hook can address its LPs and
can never address its traders, therefore the trader-side object class is empty, therefore the entire
fee-rebate-for-good-flow prompt (official example #3) is unbuildable as a hook.* That is counted,
checkable, explains three separate holes in the 662-row dataset, and nobody has said it.
