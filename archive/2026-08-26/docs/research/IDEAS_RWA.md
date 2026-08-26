# IDEAS_RWA — the seven permissioned-pool / RWA ideas, assessed

> Author: Devil's Advocate + Economic Incentives Analyst + Skeptic Web3 Expert. Date **2026-08-26**.
> Inputs: `docs/CANDIDATE_BRIEF.md`, `docs/research/HACKATHON_CONTEXT.md` §1/§2/§7,
> `docs/research/WINNERS_LANDSCAPE.md` §2/§4, `CLAUDE.md` §5, `data/hook_directory_662.json` (re-queried
> by me, regexes inline), `lib/*/IHooks.sol` (read), `test/spike/RouterCompatibility.t.sol` (read).
> **No web fetches.** Every interface named by the owner (`transfer agent`, `TRADING_WINDOW`,
> `SWAP_ALLOWED`, "the adapter", "the checker") is **UNVERIFIED** — see §0.3. RWAScout owns that.

---

## 0. THREE FINDINGS THAT GOVERN ALL SEVEN — read before the per-idea sections

### 0.1 A `beforeSwap` allowlist gate cannot bind the allowlist to the person who gets the tokens

This is proven in this repo, not reasoned.

- `test_Q3_senderIsTheRouterNotTheTrader` (commit `55c2ae2`): `sender` in `beforeSwap` **is the
  router**, asserted, with the negative assertion `lastSender() != address(this)` alongside it.
- The only channel carrying the trader's identity is `hookData` — **which the caller supplies.**
  `test_Q3_emptyHookDataLeavesNoBeneficiary` shows the default is *empty*.
- The hook **never sees the recipient.** The router calls `poolManager.take(currency, recipient, amt)`
  *after* the hook's last callback. `afterSwap` gets `sender`, `key`, `params`, `delta`, `hookData` —
  no recipient. Read `IHooks.sol:115-121`.

Therefore a KYC/ZK/lockup/hours gate reading identity out of `hookData` proves *"some allowlisted
address was named in the calldata"*, **not** *"the person receiving the security is allowlisted."*
Anyone copies a whitelisted address into `hookData` and takes delivery elsewhere. The gate is
decorative unless one of:

| Escape | Cost |
|---|---|
| The hook **is** the periphery (custom router, users must use ours) | no aggregator, no UniversalRouter, no 1inch — the "permissioned pool" is now a private app, and Gate-1 "direct interface to a hook" is met but Impact collapses |
| An issuer **signature over `(trader, nonce, deadline)`** in `hookData` | works, but is a per-trade off-chain oracle: the issuer is now live infrastructure on the swap path, and can censor any trade by declining to sign |
| The **token itself** enforces (ERC-3643 / ERC-1400 style `canTransfer`) | works perfectly — **and makes the hook redundant.** PoolManager's `take()` to a non-allowlisted recipient simply reverts. |

**The third row is the delete test and it fails four of the seven ideas outright.** A real tokenized
security already refuses to move to a non-allowlisted wallet. Bolting a second, weaker copy of that
check onto the swap path adds nothing except a place for it to disagree with the token.

### 0.2 The lane's saturation, counted

| Query over 662 rows | Matches | Prized |
|---|---|---|
| `rwa\|real.world asset\|compliance\|compliant\|kyc\|permission` | **78** | **13** |
| of which cohort UHI8 alone | **32** | — |
| `nav\|net asset value\|transfer agent\|primary market\|issuer` | 4 | 1 |
| `market hours\|circuit breaker\|halt\|nyse\|trading window` | 5 | 2 |
| `lockup\|holding period\|wash sale` | **0** | 0 |
| `share class\|feeder\|accredit` | **0** | 0 |
| `markout\|retrospectiv\|ex.post` | **0** | 0 |
| `sybil` | **0** | 0 |

**UHI8 was a "specialized markets" cohort and this lane was strip-mined in it.** Named, all UHI8
unless stated: `RWAComplyHook` ("tier-based access, volatility-aware dynamic fees, admin safeguards"),
`The Citadel Hook` ("institutional RWA compliance … enforces st[andards]"), `Vaultex` ("tiered dynamic
fees, on-chain compliance enforcement, **settlement windows**"), `RWAMarket Hook` ("first compliant,
KYC-gated liquidity pool for tokenized real-world assets such as **treasury bills**, bonds, real
estate"), `HooK Template for specialized markets`, `DobDex` (UHI8, **Unichain Prize**), `Rayls
Compliance & Privacy` (UHI6), `kvhook` (UHI5, **Ink Prize** — "KYC-gated pools … authorized through
Kraken Verify"), `ZK Proof-of-Compliance Hook` (UHI7, no prize), `KYC Hook` (UHI2, Brevis Prize),
`Satisfy` (UHI8, **Unichain Prize** — "a credential-aware policy layer for Uniswap v4 that evaluates
**zk and attestation proofs in the hook path** and only allows swaps or liquidity when on-chain
[credentials pass]"), `uniguard.exchange` (**untagged/UHI10-era** — "NASDAQ-inspired **circuit
breaker** solutions").

`Satisfy` is idea #5, built and prized. `uniguard.exchange` is idea #3 and is **live competition this
cohort.** `kvhook` is idea #5's Ink-track version, built and prized. This is not white space; it is a
worked seam.

Two honest counterweights, stated because they cut against my verdict:
1. **Ink's sponsor track literally asks for "Permissioned Pools via Kraken Verify"** (HACKATHON_CONTEXT
   §7). A competent compliance gate has a live shot at the Ink Prize. It also repeats a prior Ink
   winner, which is exactly what EigenLayer's page warns against in its own words.
2. **13/78 ≈ 17% prize rate** in this lane is at the 15% cohort baseline (P2) — it is not a *death*
   lane like TWAMM (0/10) or FHE (6/66). It is a *mediocrity* lane: people place, nobody dominates.

### 0.3 Interface risk — flag every idea that rests on an unverified primitive

The owner's seven use vocabulary I could not verify offline: **"the adapter"**, **"the checker"**,
**`SWAP_ALLOWED`**, **`TRADING_WINDOW` flag**, **"the transfer agent"**. Two consequences:

- Ideas **3, 4, 5, 7** are *predicates supplied to somebody else's checker interface*. If that
  interface is a published Uniswap/Ink/ERC standard, then the "hook work" is **implementing an
  interface someone else specified** — the owner already said this of #5, and it is equally true of
  3, 4 and 7. #3's own phrasing — *"add a TRADING_WINDOW flag"* — is **a pull request to a spec, not
  a hook.**
- Idea **2** ("mint/redeem against the transfer agent") assumes an on-chain, atomic, permissionless
  issuer mint/redeem endpoint. **I have not verified one exists for any RWA on Unichain.** If it does
  not, #2 is unbuildable except against a mock we wrote — which is `CLAUDE.md` §9 "never demo only
  against straw men we wrote," in the one lane where the straw man *is* the counterparty.

---

## 1. IDEA-BY-IDEA

Scoring uses the real rubric: **30% Original Idea · 25% Unique Execution · 20% Impact · 15%
Functionality · 10% Presentation**. Weighted total in the last column.

---

### #1 — Public price, private fill

**HOOK or CONFIG?** **A hook, and an ambitious one — but it is really two hooks and a synthetic
asset.** Most of the work is not in either hook.

**Mechanism sentence.** *State:* a permissionless pool over a non-transferable virtual index and a
permissioned pool over the real token. *Trigger:* a swap on the quote pool. *Settlement path:* **I
cannot finish this sentence, and that is the finding.** The quote pool's "trade" must settle in
*something*. If it settles in the real token, the trader must be permissioned and the public pool is
a lie. If it settles in nothing, no capital is at risk and the price is not a price.

**New tradeable object?** The virtual index — but only nominally: non-transferable and non-settling
means it is not tradeable, which is the whole problem.

**The attack.** Decisive and cheap. **An unbacked price is free to move.** In a real pool, pushing
price costs you inventory you must later unwind at a loss — that cost is what makes the price
informative. Strip settlement and you have removed the only thing that punishes a liar. An adversary
with capital does not even need flash loans: they take the quote pool to any level they want, then
transact in the permissioned pool (or off-chain, or against an NAV-linked lender) against a mark
they authored. **This is an oracle you built for your attacker.** If instead you back it with
collateral and cash-settle it, you have built a perp — `ParaDex` (UHI8, Unichain + Uniswap Prize),
`PerpHinge`, `OracleSettle` — 53 submissions, off-theme, and the permissioned leg is now irrelevant.

**Regulatory attack.** A cash-settled synthetic tracking a registered security, sold to whoever
turns up, is a security-based swap. That is not a footnote; it is the reason this product does not
exist already.

**v4 feasibility.** The quote pool needs a NoOp'd or fully-synthetic swap. `test_Q1_*` proves a NoOp
returning zero output **reverts** through both `UniswapV4Router04` (`SlippageExceeded()`) and
`V4Router` (`V4TooLittleReceived`). Only `minOut = 0` passes — i.e. reachable **only with slippage
protection disabled** (`test_Q2_zeroMinOutPasses_userReceivesNothing`). So the "public" pool is
unreachable from public infrastructure. That is a self-contradiction in the pitch.

**Prior art.** Dark-pool/hidden-order lane: 16 direct, 66 with FHE — **6/66 prized, the worst
conversion of any large lane, and Atrium's own AVOID list.** `Milady Pool` (UHI2, prized), `AZEx`
(UHI6, Uniswap Prize), `TWAMM-X`, `Schrodinger Hook`. None solves the settlement problem; they all
hide the *order*, not the *fill*, which is a different and buildable thing.

**Scores.** Original 3 · Execution 2 · Impact 1 · Functionality 2 · Presentation 3 → **2.20**
> The unbacked mark is not a rescuable flaw. It is the idea.

---

### #2 — Primary market inside the AMM (mint/redeem against the issuer past a NAV band)

**HOOK or CONFIG?** **A hook — the only one of the seven with a real settlement path.** This is the
best of the seven and it is the one worth arguing about.

**Mechanism sentence.** *State:* issuer NAV (oracle) + a deviation band + the hook's own inventory of
token and cash. *Trigger:* a swap that would push the pool price outside ±X% of NAV. *Settlement
path:* `beforeSwap` returns a `BeforeSwapDelta` filling the trader out of the **hook's** inventory at
NAV ± fee, leaving the curve untouched, and the hook later reconciles its inventory with the issuer's
mint/redeem window.

**Feasible in v4 — and this is the one piece of good news in the whole pass.**
`test_Q4_inventoryBackedFillIsRouterCleanWithRealSlippage` proves exactly this shape works through
`V4Router` with a **real** `minOut` (98% demanded, hook quotes 99%), and
`test_Q4_inventoryFillLeavesThePoolPriceUntouched` proves the curve is untouched. No NoOp problem, no
router problem. **Router-clean, proven, in this repo.**

**New tradeable object?** Weakly — "the pool's redemption claim". If you go further and let LPs sell
that claim, yes. Nobody has. That is the seed of something.

**The attack, and it is fatal in the form proposed.**
1. **The availability inversion — Hardcap's shape, sixth appearance.** A transfer agent operates
   during business hours, T+0 at best, T+2 typically. **The primary market is open exactly when the
   pool is least stressed, and shut exactly when the pool needs it** — the weekend gap, the halt, the
   depeg. So the mechanism is present when redundant and absent when load-bearing. This is
   structurally identical to Hardcap's "first swap of the block is tax-exempt": the exemption lands
   precisely on the case the mechanism exists for.
2. **The delete test, backwards.** If the issuer really offers atomic permissionless mint/redeem at
   NAV, then **nobody needs the pool** — the arb is riskless and the AMM is strictly dominated. The
   pool has value only in the window where the primary market is closed, which is the window the
   mechanism cannot serve. You cannot have both halves true at once.
3. **The NAV feed is a single trusted number that decides who gets paid.** A lying or stale NAV lets
   an attacker with capital buy the pool's entire inventory at the false mark; there is no arbitrage
   that corrects it, because *the hook itself is the arbitrageur and it is using the corrupt number*.
   A hook that quotes off an oracle is a hook that pays out at whatever the oracle says. Flash loans
   make the size unbounded; the only limit is the hook's inventory, and the whole point is that the
   inventory is large.
4. **Issuer offline / censoring.** The hook accumulates one-sided inventory it cannot reconcile.
   Whoever is long that inventory is the LP. So the LPs have been silently converted into
   **unsecured creditors of the issuer**, and were not told.

**Prior art.** `nav|transfer agent|primary market|issuer` → **4 rows**, 1 prized, none doing this.
Nearest built things: `Peg-Hooks` (UHI8, "pegCore enable FX onchain clearing"), `TermStructure AMM`
(UHI5, Uniswap + Circle Prize), MakerDAO's PSM off-hookathon. The general shape — "AMM routes to an
external redemption facility" — is a stablecoin PSM, well known outside UHI, so novelty is real
inside the directory and thin in the wider field. **§5.13 applies: check whether this is empty
because it does not work, and I believe the answer is yes, per attack 2.**

**Scores.** Original 3 · Execution 3 · Impact 2 · Functionality 2 · Presentation 3 → **2.65**
> Best of the seven. Still a full point below the shortlist, and its central economics invert.

---

### #3 — Market hours + circuit breakers

**CONFIG.** `beforeSwap` reverts on a flag. That is the entire mechanism. Adding a `TRADING_WINDOW`
flag to somebody else's checker enum is a spec PR.

**Mechanism sentence.** *State:* a window + a halt boolean (both written by a trusted party).
*Trigger:* any swap. *Settlement path:* **there isn't one.** It reverts. Nothing settles, nothing
accrues, nothing is redistributed. A mechanism with no settlement path is a gate.

**New tradeable object?** No.

**The attack — and this one is an own goal, not a bypass.**
- **A circuit breaker on an AMM strictly helps the informed trader.** The uninformed seller who
  needs out *now* is blocked; the informed trader is indifferent to twelve hours and simply waits.
  You have removed the impatient party's option and left the patient party's option intact. That is
  the *opposite* of HASTE, and it is the wrong sign.
- **The halt guarantees the LVR it claims to prevent.** LPs are frozen in-position at a
  known-stale price for the whole halt. The reopening is a scheduled, publicly-announced gap with a
  queue of arbitrageurs in front of it. You have converted diffuse continuous LVR into one
  concentrated, perfectly predictable extraction event. On-theme cohort, wrong direction.
- **Stale/absent flag = permanent brick or permanent open.** Fail-closed traps LP capital (`CLAUDE.md`
  §5.3 — we already learned this the expensive way). Fail-open makes the feature a no-op precisely
  during the incident.
- **Censorship is the feature working as designed.** Whoever writes the halt flag can stop any
  holder from exiting. There is no threat model in which that is acceptable to a judge who asks.
- **10% in N seconds** is measured against the pool's own price, so it is **poisonable for gas** — one
  dust swap trips the breaker and shuts the pool. This is exactly `CLAUDE.md` §6's Hardcap finding
  ("a dust in-range liquidity add zeroed the claw for a whole block, for gas"), rebuilt.

**Prior art.** `uniguard.exchange` — *"NASDAQ-Inspired Circuit Breaker Solutions"* — is in the
directory **untagged/UHI10-era, i.e. plausibly a competitor this cohort.** Plus `Mantua.AI Stable
Protection Hook` ("automatic circuit breaker"), `Vaultex` ("settlement windows"), `OscillonHook`,
`PEGKEEPER`, `AegisHook` (pause an at-risk pool). Six built versions.

**Scores.** Original 1 · Execution 1 · Impact 1 · Functionality 4 · Presentation 3 → **1.65**
> Buildable in a day, and the mechanism has the wrong sign for this cohort's theme. Do not submit it.

---

### #4 — Share-class book on one inventory (accredited LPs vs retail feeder)

**Mostly CONFIG, with an unbuildable half.**

**Mechanism sentence.** *State:* two allowlists over one pool's liquidity, plus a retail wrapper
token. *Trigger:* `beforeAddLiquidity` / `beforeSwap`. *Settlement path:* the retail wrapper accrues
a claim on the accredited pool's NAV. **The trigger half does not work in v4** — see below — so what
survives is "two checkers", i.e. #5 twice.

**New tradeable object?** **Yes — the retail feeder wrapper.** This is the only P5-positive answer in
the seven, and it is the reason #4 deserves more than one line. But see the economics.

**v4 feasibility — the LP half is not buildable as described.** `IHooks.sol:39-44`:
`beforeAddLiquidity` returns **`bytes4` only.** It cannot mutate `params`, cannot re-key the
position, cannot route an LP into a class. Its **only** power is to revert. And per `CLAUDE.md` §5.12
+ `test_Q3`, PoolManager keys the position by the **unlock's `msg.sender`** — the router — so the hook
cannot even tell which class the depositor belongs to. Class assignment therefore has to live in a
vault contract that is the LP-of-record. **That vault is the product, and it is not a hook.** What
the hook contributes is one `revert`.

**The attack — economic, and it is well documented outside crypto.** A feeder whose redemption depends
on the accredited class's liquidity is **structurally subordinated**. In calm markets the wrapper
trades at NAV; in stress the accredited side exits first and the wrapper trades at a discount that
does not close. That is a **closed-end fund**, and persistent NAV discounts are its defining, unsolved
pathology. You have shipped retail the illiquid tail of a security while telling them it is the
security's price. Under stress, the retail holder's loss is *caused by* the mechanism.

**Regulatory attack.** "Retail gets a wrapper claim, not the security" is the exact structure that
economic-substance analysis collapses. If it tracks the security's economics it is treated as the
security. This is not a hook risk; it is why the product is not sold.

**Prior art.** `share class|feeder|accredit` → **0/662**. Tranching generally is built and prized:
`Unistrata`, `Sochalant` (senior/junior 70/30), `Kinetic Capital Hook`, `Mochi Yield` (PT/YT, General
Prize). So the *tranche* is proven to score; the *compliance framing* is what is new, and it is the
part that fails.

**Scores.** Original 2 · Execution 2 · Impact 2 · Functionality 2 · Presentation 2 → **2.00**

---

### #5 — ZK allowlist checker

**CHECKER. The owner's own note is correct and if anything understated:** *"Hook work: almost none."*

**Mechanism sentence.** *State:* a Merkle root of the issuer's set. *Trigger:* `beforeSwap`.
*Settlement path:* none — verify or revert.

**New tradeable object?** No.

**The attack.**
- **§0.1 kills it outright.** The proof must be over an address in `hookData` (`sender` is the
  router). Anyone can put a member's address in `hookData` and take delivery elsewhere. **A ZK proof
  of membership that is not bound to the recipient proves the set is non-empty.** Binding it requires
  either a fresh issuer signature per trade (an off-chain oracle with a censorship switch) or custom
  periphery (no aggregators).
- **Revocation lags the root.** A sanctioned or revoked member's proof stays valid until the issuer
  rotates and republishes the root. The window is however long that takes. For a compliance product
  that is the one failure that matters.
- **The issuer is the whole trust model** and it can censor a holder's exit by omission. Say so.

**Prior art — this is built and it is prized.** `Satisfy` (UHI8, **Unichain Prize**): *"a
credential-aware policy layer for Uniswap v4 that evaluates **zk and attestation proofs in the hook
path** and only allows swaps or liquidity when on-chain [checks pass]."* Also `ZK Proof-of-Compliance
Hook` (UHI7, no prize) — same sentence, no prize; `KYC Hook` (UHI2, Brevis Prize); `kvhook` (UHI5,
**Ink Prize**); `Rayls Compliance & Privacy` (UHI6); `TrustLayer` (UHI6). `zk|zero-knowledge|proof of
membership|semaphore|world id` → **35 rows, 9 prized.** And Brevis's own page (HACKATHON_CONTEXT §7)
**explicitly disqualifies** its nearest neighbour as "already built."

**Scores.** Original 1 · Execution 2 · Impact 2 · Functionality 3 · Presentation 3 → **1.95**
> Gate-1 valid, rubric-dead. 30% of the score is Original Idea and `Satisfy` already won with it.

---

### #6 — DualPool × permissioned inventory (idle side in an ERC-4626)

**CONFIG, and it is somebody else's shipped contract.**

**Mechanism sentence.** *State:* idle reserve share balance. *Trigger:* swap/liquidity events.
*Settlement path:* deposit/withdraw the 4626. Fine — but that sentence describes
**OpenZeppelin's `ReHypothecationHook`**, which ships today in `lib/uniswap-hooks` in this very repo.

**Delete test.** Delete the RWA/permissioned framing and you have OZ's contract. Delete OZ's contract
and you have nothing. That is the definition of a wrapper.

**The attack.** Standard and well known: the 4626 is a solvency dependency on the swap path. If the
vault is illiquid, paused, or suffers a loss, **swaps stop and LP exits stop**, because the pool's
inventory is inside it. On a T-bill vault, redemption is not instantaneous — so a run on the pool
hits a queue. Plus the classic donation/inflation share-price manipulation on a fresh vault. And
`CLAUDE.md` §5.3's lesson applies again: never make an LP exit depend on a third party answering.

**Prior art.** 38 submissions, 10 prized, curriculum-taught, plus `ForgeX: Vult`, `1Tx` (UHI8,
Uniswap Prize), `Revert Hook`, `Holdfast`. And OZ ships it free — `CLAUDE.md` §3 criterion 5: *"anything
a developer already gets free from OZ today is not a submission."*

**Scores.** Original 1 · Execution 1 · Impact 2 · Functionality 4 · Presentation 3 → **1.85**

---

### #7 — Holding-period / lockup module (T+365, or blocking wash sales inside 30 days)

**CHECKER.** A different predicate in the same `beforeSwap` revert.

**Mechanism sentence.** *State:* per-address acquisition timestamp. *Trigger:* `beforeSwap`.
*Settlement path:* none — revert.

**New tradeable object?** No. (An interesting near-miss: a *transferable* seasoned-lot claim would be
one. Not proposed here, and it would defeat the lockup.)

**The attack — three, any one sufficient.**
- **ERC-20 fungibility destroys lot accounting.** "T+365 from mint" needs FIFO lots. A fungible
  balance has no lots. Track per-address and the holder moves to a fresh address; the move is
  gated by the *token*, not by us, so if the token permits transfers between allowlisted wallets
  (it does — that is the point of an allowlist) the clock resets or launders freely between
  co-conspirators inside the same allowlist.
- **The hook only gates one venue.** Lockups have to bind the asset. This binds one Uniswap pool. The
  holder sells OTC, on another pool, on another chain, or writes a total-return swap. A lockup with a
  known hole is worse than none: it creates a false compliance record.
- **Wash-sale blocking is a *tax* rule, not a transfer rule.** A wash sale is legal; it merely
  disallows the loss deduction. Blocking the transaction does not implement the rule — it prevents a
  lawful trade and does not change the taxpayer's basis. **The mechanism does not do the thing it is
  named after.** Say this out loud before someone in the audience who does tax says it for you.
- Plus, of course, ERC-3643/ERC-1400 already implement lockups **at the token**, correctly, with lot
  data the token actually has. §0.1 row 3.

**Prior art.** `lockup|holding period|wash sale` → **0/662**. Adjacent and prized: `sentry` (UHI7,
taxes short-lived LP positions on a decay curve) — same intuition, applied to liquidity, where it
actually works. **§5.13 test: this is 0 because the token layer owns it, not because nobody thought
of it.**

**Scores.** Original 2 · Execution 1 · Impact 1 · Functionality 4 · Presentation 3 → **1.95**

---

## 2. THE COLLAPSE — the owner is right, and it is worse than he thinks

**Ideas 3, 5 and 7 are one product.** All three are:

```solidity
function _beforeSwap(address sender, PoolKey calldata k, SwapParams calldata p, bytes calldata d)
    internal override returns (bytes4, BeforeSwapDelta, uint24)
{
    require(checker.allowed(/* predicate varies */), "denied");
    return (BaseHook.beforeSwap.selector, ZERO_DELTA, 0);
}
```

They differ **only in the predicate passed to a checker somebody else specified**: `#5` = set
membership, `#3` = wall-clock, `#7` = elapsed-time-since-acquisition. Same state shape, same trigger,
same (absent) settlement path, same failure mode (§0.1), same trust model (a single off-chain writer),
same score band (1.65–1.95).

**Idea 4 is the same product twice** — its distinctive half (routing LPs into share classes) is
**unbuildable in a hook** because `beforeAddLiquidity` returns `bytes4` and cannot mutate params, and
because PoolManager keys positions by the router. What is left after that deletion is two checkers.

**Honest collapsed entry:**

> **PERMIT — a configurable compliance predicate on the v4 swap path.** One hook, one pluggable
> `IPolicy`, shipped policies for allowlist / ZK membership / trading window / holding period /
> per-tier fee. Buildable in under a week. Real Ink-track shot. Score **≈ 2.0**, capped by the fact
> that `Satisfy` (UHI8, Unichain Prize) and `kvhook` (UHI5, Ink Prize) already did it, and by §0.1
> being an unfixable hole in the honest version. **Consumes the one submission for a mid-table result.**

Four ideas → one. That is a 4× reduction in apparent option value, and the owner's instinct earned it.

---

## 3. STRAIGHT ANSWER: is there ONE mechanism-shaped idea here that beats SWITCHBACK/SLUICE?

**No. This lane is a config surface with good storytelling, and it is off-theme on top of that.**

Three reasons, in order of weight:

1. **Six of the seven have no settlement path.** Filling in the mechanism sentence — state / trigger /
   settlement — succeeds only for **#2**, and #2's settlement path is open exactly when it is not
   needed. `CLAUDE.md` §5.15's rule applied to the owner's own ideas: these are *adjectives*
   ("compliant", "permissioned", "institutional") wearing mechanism costumes. That is not a criticism
   of the owner's thinking — it is what the source material is. **A Uniswap Builders post about
   permissioned pools is a post about a config surface.** The lane is honestly described.
2. **The rubric is 55% novelty + execution distinctiveness.** Best-in-lane here is **2.65**;
   collapsed-lane is **2.00**; the shortlist sits at **3.95–4.10**. Even granting me a full point of
   error, nothing here reaches the fallback.
3. **It is off-theme in a cohort where P3 says winners match the theme heavily.** "Sustainable
   Liquidity and MEV Protection" — none of the seven protects an LP from anything or recaptures a
   basis point. The open shots (General / Unichain / Uniswap Prize) exist, but per the Orbital
   precedent they go to off-theme **new math**, not off-theme **configuration**.

The one thing this lane genuinely offers that the shortlist does not is a **sponsor track that is
asking for it by name** (Ink → "Permissioned Pools via Kraken Verify"). That is worth exactly one
sentence of consideration and it does not survive it: `kvhook` already won that track with that
product, and a repeat is the thing EigenLayer's own page warns costs you prizes.

---

## 4. MY OWN PROPOSAL — one, not two

I can write the state/trigger/settlement sentence and name the attack for exactly one idea in this
space. I am not padding it to two. **The second-best thing I generated is in §5, killed, because
showing you a dead idea's cause of death is worth more than a third-place live one.**

### ROLLCALL — run the MEV defence that only works when identity is expensive

**The inversion.** Every MEV defence in the 662 fails at the same place, and this project has already
proved it twice: `CLAUDE.md` §8 killed searcher bonding because *"a sandwicher runs the two legs from
two addresses, so nothing is attributable"*, and the **ledger theorem** says *"the ledger tells the
truth about an address; the adversary chooses which address faces your hook"* — 52,700 gas to move.
**Identity is free on a permissionless pool, so no retrospective, cross-block, per-actor mechanism can
be built there.** A permissioned pool is the one place in DeFi where an identity is *expensive* — it
costs a KYC onboarding with a named legal entity behind it, and it is one-per-entity by construction.

So: **stop using the allowlist as a gate and start using it as Sybil resistance.** Build the mechanism
that is impossible everywhere else, and let the compliance layer be load-bearing infrastructure rather
than the product.

**Mechanism sentence.**
*State kept:* per-identity `(cumulativeMarkout, openFills[])`, plus an enrolment escrow posted once by
each identity at onboarding.
*Trigger:* every swap. `beforeSwap` charges `baseFee + f(markoutScore[id])` — flow that has
historically been right about the price pays more; flow that has historically been wrong is rebated —
and records the fill as `(id, tick, block)`.
*Settlement path:* permissionlessly crankable at `fillBlock + W`. The crank reads the pool's own tick
now versus the recorded fill tick, computes the identity's realised markout, updates its score, and
`donate()`s the accrued surcharge to in-range LPs. Unpaid negative scores are collected from the
enrolment escrow, which must be topped back up before that identity may trade again.

**Why it is a mechanism and not a metric.** It never classifies anyone *ex ante*. It does not guess
toxicity from size, gas price, or an ML model. It **measures, after the fact, whether you were right**
— which is the only definition of toxic flow that is not a heuristic — and it can do that only because
you cannot come back tomorrow as somebody else. Delete the permissioning and it dies to Sybil in one
transaction. Delete the hook and there is no measurement. **Both halves are load-bearing.**

**The attacks — five, and two of them are serious.**
1. **The crank's reference price is the pool's own tick, so the party being scored can move it.** They
   push price back before cranking and score themselves benign. Mitigation is a windowed average and a
   fixed crank block, and on a thin RWA pool that manipulation is still cheap. **This is the strongest
   objection and it is unresolved.** It is also *precisely* the failure mode `CLAUDE.md` §10 warns
   about, so it must be tested at a non-unit price with a negative control before anything is built.
2. **Allowlist-slot renting is the real Sybil channel.** The identity is KYC'd; the *behaviour* behind
   it is not. An accredited entity rents its slot to a searcher for a cut. The score then attaches to
   a legal person who is willing to be paid for the reputational damage. **Priced, not prevented** —
   and it must be said out loud, in the OZ-warning style this project already uses.
3. **Walk-away.** A score is a debt, and a debt to a party you can simply stop visiting is not
   collectable. The escrow exists solely to answer this, and it must exceed the largest single-trade
   extraction or the mechanism is decorative — which is `CLAUDE.md` §7.1's unfixable bond problem
   reappearing. State it plainly, every time.
4. **The gate operator censors** by declining to enrol, or by de-listing a profitable trader. Same
   trusted-party exposure as every idea in this document; ROLLCALL does not escape it, it just does
   not pretend to.
5. **P5:** it creates **no new tradeable object.** The score is deliberately non-transferable — making
   it tradeable reintroduces Sybil. That is a real rubric cost and I am not going to dress it up.

**v4 feasibility.** `beforeSwap` fee override and `donate()` are stock. §0.1's identity problem applies
— but here it is *acceptable* rather than fatal, because a permissioned pool already requires
enrolled entry, so custom periphery costs nothing that was not already lost. `donate()` paying
whoever is in range now (§5.11) is the same beneficiary problem SWITCHBACK has, with the same known
fix (aged-LP escrow + JIT activation delay).

**Prior art.** `markout|retrospectiv|ex.post|realized pnl` → **0/662**. `sybil` → **0/662**. But
`reputation|risk scor|trader scor` → **38 rows, 7 prized** — `Glyph` (UHI8, no prize: *"Every AMM
charges a sandwich bot the same fee as a first-time user, because pools have no memory"*), `Maiat`
(UHI8, no prize, gates on trust scores), `Strata` (**UHI10, live competition**, reputation-weighted
commit-reveal dynamic fee). **A judge will pattern-match ROLLCALL to Glyph in four seconds.** The
defence — *"Glyph's registry is Sybil-forgeable and mine is not, and that is the whole difference"* —
is correct and is one sentence, but it is a sentence you have to win in the video.

**Honest score.** Original 4 · Execution 4 · Impact 3 · Functionality 3 · Presentation 4 → **3.65**

**Which is still below SWITCHBACK's 3.95.** The best idea I can construct in the owner's lane, with
the lane's one genuine structural advantage fully exploited, **does not reach the fallback candidate.**
That is my answer to the lane question, arrived at by trying to beat it rather than by asserting it.

---

## 5. KILLED WHILE WRITING THIS — reasoning that transfers

**CLUB — "you may only take from the pool in proportion to what you left in it."** In a permissioned
pool the hook can require the swapper's identity to also hold an aged LP position, and cap swap size
at a multiple of it, so every extractor internalises a share of the damage they cause. It dies on
arithmetic: an identity holding fraction *p* of the pool internalises only *p* of the LVR, so the
effective tax is *p*, and the attacker simply holds the minimum. Push back by making the *size cap*
proportional instead, and you have capped the honest trader's size too — **which is the one thing a
liquidity venue exists to provide.** That is Hardcap's economic inversion rebuilt a seventh time: the
constraint binds on the party you wanted to serve and is bought off cheaply by the party you wanted to
stop. Also already occupied in spirit — `LiquiDAO` (UHI5), `am-AMM` (UHI1), and Kyber FairFlow's
exclusive-taker structure (`CANDIDATE_BRIEF` §1 con 5).

---

## 6. WHAT RWASCOUT MUST SETTLE — and what changes if it comes back differently

| Question | If YES | If NO |
|---|---|---|
| Does a published checker/adapter interface exist (`SWAP_ALLOWED` etc.)? | #3/#5/#7 become "implement someone's enum" — **Original Idea drops toward 1** | they become "invent an interface" — marginally more novel, still no settlement path |
| Is there an on-chain, atomic, permissionless RWA mint/redeem endpoint reachable on Unichain? | **#2 becomes buildable against a real counterparty** and is worth a second look at ~3.0 — still short | #2 can only be demoed against a mock we wrote, i.e. `CLAUDE.md` §9's forbidden shape in the one place the counterparty *is* the mechanism |
| Do real permissioned RWA tokens (ERC-3643/1400) enforce transfer restrictions themselves? | **§0.1 row 3 holds and the whole compliance-gate lane fails the delete test** | the "RWA token" is an ordinary ERC-20 with a story, and the demo is a toy |
| Is `uniguard.exchange` a UHI10 submission? | #3 is being built by a competitor right now | no change to the verdict |

**None of these four answers moves the recommendation.** The best case across all four is #2 at ~3.0,
against a shortlist at 3.95–4.10.

---

## 7. RECOMMENDATION

**Do not spend the one submission in this lane.** Continue with the standing decision
(`CANDIDATE_BRIEF` §6): build SWITCHBACK, hold HASTE as a funded option gated on the λ measurement.

Two things in this document are worth carrying forward regardless of what gets built:

1. **§0.1 is a reusable, in-repo-proven result** — *a v4 hook cannot bind an allowlist to the party
   that receives the tokens, because it never sees the recipient and `sender` is the router.* That is
   true of every one of the 78 compliance-tagged submissions in the directory, and I did not find any
   of them stating it. It sits naturally alongside the ERC-6909 laundering finding and the permission
   census in the publish-don't-submit pile.
2. **ROLLCALL's inversion is the one durable idea in the lane** — *identity is free everywhere except
   behind a KYC gate, so a permissioned pool is the only venue where a retrospective per-actor
   mechanism can exist.* It scores 3.65 and loses to SWITCHBACK, but it is the right shape and it
   should be reachable if the shortlist collapses.
