# IDEAS_INTEGRATION — four hooks whose differentiation is a REAL integration

> Author: Skeptic Web3 / Economic Security / Execution Trace. Date **2026-08-26**.
> Every address and interface below was verified this session against primary docs or an explorer.
> Anything I could not verify is marked **UNVERIFIED** and is not load-bearing for any recommendation.

---

## 0. THE QUESTION: is "integrate a real private-orderflow venue" executable by a Solidity hook, or a mirage?

**Answer: it is half a mirage, and the half that is real is real enough to build on.**

The thesis is stated as one lane. It is actually three lanes with three different verdicts, and collapsing
them is why the 0/662 count looks more mysterious than it is.

| Venue | Can a Solidity hook reach it? | Verdict |
|---|---|---|
| **Flashbots Protect / MEV-Share** | **NO.** There is no contract. | **IMPOSSIBLE AS A HOOK.** |
| **MEV-Blocker** | **NO.** Same shape — an RPC endpoint. | **IMPOSSIBLE AS A HOOK.** |
| **Atlas / FastLane** | Partially — but entry is via a frontend + off-chain Operations Relay. | **NOT REACHABLE FROM A HOOK.** |
| **UniswapX** | **YES — but the hook must be the *caller*,** not a passive callee. Filling is permissionless; exclusivity over real flow is not. | **REAL, restructured.** |
| **CoW Protocol** | **YES, both directions, permissionlessly, on-chain.** | **REAL. This is the door.** |

### Why Flashbots is impossible, precisely

Flashbots Protect is `rpc.flashbots.net` — a JSON-RPC endpoint. MEV-Share is "a specialized actor called
a MEV-Share Node" that performs selective hint disclosure and bundle simulation **off-chain**; the Flashbots
docs for both MEV-Share and MEV refunds contain **no contract address at all**, because there is no contract.
Refunds are delivered as a builder-originated payment attached to a bundle under an off-chain condition
("the user must be paid back 90% of the MEV their transactions create"), decided by the node, not by any
on-chain rule a hook could read, verify, or invoke.

Three consequences, all fatal to a hook-side integration:
1. **No callable surface.** `hook.call(flashbots)` does not typecheck against anything, because nothing exists.
2. **No verifiable receipt.** A hook cannot prove in `beforeSwap` that the swap arrived via Protect. The
   only on-chain correlate — zero priority fee, `tx.gasprice == block.basefee` — is a **heuristic that any
   searcher can forge for the price of the gas they were paying anyway.** Any hook claiming to "detect
   protected flow" is claiming something false. Do not build it and do not say it.
3. **No testnet.** Even if (1) and (2) were solved, MEV-Share matchmaking does not run on a testnet, so the
   demo would be a mock — i.e. exactly the failure mode CLAUDE.md §9 already bans ("never demo only against
   straw men we wrote").

So: **"integrate Flashbots" is not a hard problem we should be brave about. It is a category error.** Anybody
in nine cohorts who reached for the famous name and stopped at an RPC URL reached the same wall. That is most
of the explanation for the zero.

### Why CoW is genuinely different, and genuinely reachable

CoW Protocol is the only major private-orderflow venue whose **order lifecycle is anchored on-chain**:

| Contract | Address | Chains (verified) |
|---|---|---|
| `GPv2Settlement` | `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` | Ethereum, Arbitrum, Avalanche, Base, BNB, Gnosis, Ink, Linea, Optimism, Plasma, Polygon, **Sepolia** |
| `GPv2VaultRelayer` | `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` | same list incl. **Sepolia** |
| `GPv2AllowListAuthentication` (solver registry) | `0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE` | same list incl. **Sepolia** |
| `ComposableCoW` (programmatic orders) | `0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74` | Ethereum, Gnosis, Arbitrum, BNB, Linea, Ink, Plasma, **Sepolia** |
| `ExtensibleFallbackHandler` | `0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5` | same list incl. **Sepolia** |
| `HooksTrampoline` (CoW order pre/post-hooks) | per-solver instances — **do not pin** (see below) | incl. Sepolia |

Four real, permissionless surfaces a Solidity hook can use **today**:

1. **`GPv2Settlement.setPreSignature(bytes orderUid, bool signed)`** — explicitly designed for
   *"smart contracts that have neither a private key, nor implement ERC-1271, but still want to use CoW
   Protocol."* A contract authorises an order by an on-chain call. This is not an exotic reading; it is the
   documented purpose of the function.
2. **ERC-1271 `isValidSignature`** — the docs state ERC-1271 is *"the only signing method that supports both
   EOA and smart-contract traders."* A hook can be an order `owner`.
3. **`ComposableCoW.create(ConditionalOrderParams, bool dispatch)`** + `IConditionalOrderGenerator.getTradeableOrder(...)`
   — the contract emits `ConditionalOrderCreated`; a **permissionless watch-tower** (CoW runs one; there is a
   community DAppNode package for running your own) picks up the event, calls `getTradeableOrder()` on the
   author contract, and posts the discrete order to the CoW orderbook. **This closes the loop with no
   off-chain action by us.** That is the single most important fact in this document.
4. **`GPv2AllowListAuthentication.isSolver(address)`** — a public view over CoW DAO's real, governed solver
   allowlist. Any contract can read it. Un-forgeable (governed on the CoW side, not by the caller).

Plus one inbound surface: **CoW order hooks** (`HooksTrampoline`) let a *user's* CoW order carry a call into
our contract before or after settlement. `execute` is `onlySettlement`, so such a call really does arrive from
inside a real batch — **but CoW's docs explicitly warn against relying on it**: *"Developers should not design
hooks that rely on `msg.sender` being a specific trampoline instance, as this is neither secure nor reliable"*
(each solver may deploy its own trampoline), and *"hook execution is not guaranteed — your order may still get
matched even if the hook reverted."* **So you cannot build a mechanism whose safety depends on a CoW hook
running.** That kills the tempting "prove this swap arrived via CoW" design outright; the closest honest
substitute is `isSolver(tx.origin)`, which proves *a bonded CoW solver originated this transaction* — not that
you are inside a settlement. Neither candidate #1 nor #2 depends on either, which is deliberate.

### So why zero in 662, if it is possible?

Not because it is impossible. Three specific frictions, and naming them is how we avoid walking into them:

1. **Everyone reached for the famous name.** "Flashbots" is the word in the prompt and in every MEV article.
   It is the one that genuinely cannot be done. People bounced there and generalised.
2. **The CoW door is obscure and reads as Safe-only — and that reading is WRONG.** `ComposableCoW` is
   documented almost entirely through Safe + `ExtensibleFallbackHandler`, so a dev skimming it concludes "this
   is a Safe feature" and leaves. I read the source. `create()` is:
   ```solidity
   function create(IConditionalOrder.ConditionalOrderParams calldata params, bool dispatch) public {
       if (!(address(params.handler) != address(0))) revert InvalidHandler();
       singleOrders[msg.sender][hash(params)] = true;
       if (dispatch) emit ConditionalOrderCreated(msg.sender, params);
   }
   ```
   **No Safe check. No type check. `msg.sender` is the owner, whoever it is.** Any ERC-1271 contract —
   including a v4 hook — can own a conditional order. The one real cost: a non-Safe owner cannot reuse
   `ExtensibleFallbackHandler`, so **our hook must implement `isValidSignature(bytes32,bytes)` itself** and
   validate the presented order against `ComposableCoW.singleOrders(address(this), hash)`. Roughly fifty lines
   we write rather than inherit. Real work, not a blocker. **This single misreading is, I believe, the largest
   part of why the CoW lane is empty.**
3. **The settlement shape fights the Uniswap frontend.** Any real routing to CoW means the v4 swap NoOps and
   settles asynchronously. A standard router call with `amountOutMinimum > 0` reverts. **This is a real wart on
   every candidate below that diverts flow, it is not hand-waveable, and it is why "hybrid routing" is more
   than a weekend.** It is the same wart every async hook in the directory carries (SwapPilot, AsyncSwapHook),
   so precedent exists — but state it in the video rather than letting a judge find it.

**Bottom line: the thesis survives, narrowed.** Route it through CoW (and secondarily UniswapX). If anyone on
this team writes "Flashbots integration" in the README, that is a false claim and it will not survive one
technical question at Demo Day.

### The one chain where everything converges

| | Ethereum Sepolia (11155111) | Unichain Sepolia (1301) |
|---|---|---|
| v4 `PoolManager` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | `0x00b036b58a818b1bc34d502d3fe730db729e62ac` |
| CoW `GPv2Settlement` | ✅ `0x9008D19f...` | ❌ not deployed |
| Chainlink VRF v2.5 | ✅ `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | ❌ **not a supported network** |
| Chainlink Automation registry | ✅ `0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad` | ❌ |

**Ethereum Sepolia is the only chain carrying Uniswap v4, CoW Protocol, and Chainlink simultaneously.**
Deploy there. Note the corollary: **you cannot pair Chainlink with the Unichain track** — VRF does not run on
Unichain at all. Anyone proposing "VRF hook on Unichain" is proposing something that does not exist.

---

## 1. RANKED CANDIDATES

### #1 — `Sluice` — divert toxic flow into a real CoW batch, donate the solver surplus to LPs

**Mechanism (state / trigger / settlement):** The hook keeps a per-pool escrow ledger
`orderId → {payer, tokenIn, amountIn, limitOut, validTo}` and a per-address flow-quality score. **Trigger:**
in `beforeSwap`, a swap scoring above the toxicity threshold is NoOp'd — the hook takes the full input via
`beforeSwapReturnDelta` and returns zero output. **Settlement path:** the hook calls
`ComposableCoW.create()` naming itself as order owner, with `limitOut` pinned to *the price the pool would
have given, minus a diversion fee*, `receiver = hook`, and `validTo = now + T`. A CoW solver wins the batch and
`GPv2Settlement.settle()` pulls the escrowed input through the vault relayer and delivers the buy token to the
hook. A permissionless `claim(orderId)` then pays the swapper exactly `limitOut` and `poolManager.donate()`s
**everything above it — the solver-competition surplus — to the in-range LPs of the pool the flow was diverted
from.** If `validTo` passes unfilled, `settleExpired(orderId)` executes the swap on the pool as it always would
have.

**What the integration does.** `ComposableCoW.create(params, true)` on Sepolia; CoW's watch-tower reads the
`ConditionalOrderCreated` event, calls our `getTradeableOrder()`, and posts to the CoW orderbook; real CoW
solvers compete; real `GPv2Settlement.settle()` moves the tokens. Not a mock, not an SDK call from a script —
a contract-authored order in a real batch auction.

**Delete-the-integration test: PASSES, hard.** Delete CoW and the mechanism is "hold the swap and execute it
later on the same pool" — a fixed-delay async hook, which is taught in the curriculum and has 17 prior
implementations. **The recapture half cannot exist without a competitive solver auction**: the surplus we
donate to LPs is definitionally the amount by which a competitive auction beat our own pool's price. There is
no way to generate that number in-house. The integration is the mechanism.

**FEASIBILITY.** Counterparty surface: on-chain and permissionless (§0). Trust boundary: order *authoring*
is fully on-chain; order *discovery* is the watch-tower, which is off-chain but permissionless and
self-hostable — **we are not asking a gatekeeper for permission, which is what kills every other venue.**
Escrow risk is real and bounded: the hook custodies the swapper's input for at most `T`, and the only
recovery is `settleExpired`, which must be permissionless and gas-incentivised or funds strand.
**Two open risks:** (i) whether a non-Safe contract can own a ComposableCoW order — out for verification;
(ii) whether CoW's solver competition is actually alive on Sepolia or whether the testnet is a graveyard with
no solver to fill our order. If (ii) is dead, the fallback is to run CoW's own solver stack against Sepolia
ourselves — still the real contracts and the real settlement path, but "our solver" is a materially weaker
claim and must be said in the video.
**The router wart applies:** a diverted swap returns zero to a router expecting `amountOutMin`, so the demo
needs our own periphery or `minOut = 0`. Not fatal, must be shown honestly.

**The attack.** A searcher with unlimited capital, best shot: **be the filling solver.** A CoW solver who is
also the arbitrageur fills our order at exactly `limitOut`, banks the entire surplus off-chain, and donates
LPs nothing. The auction only pays LPs if it is actually competitive. *Mitigable, not eliminable:* set
`limitOut = poolPrice + surplusFloor` so no fill is possible below a floor; the residual — a monopolist solver
capturing everything above the floor — is **accepted and must be stated.**
Second attack: **classification griefing.** Note the incentive is correctly signed, unlike Hardcap — a
diverted swapper receives *at most* the pool price minus a fee, later, so being classified toxic is strictly a
penalty and never a prize. Nobody wants to be diverted. A griefer can spam to get honest retail diverted, which
degrades UX at their own cost and yields them nothing. *Accepted.*
Third: escrow lock-up griefing is self-punishing — the attacker locks only their own capital. *Not a threat.*

**Sponsor-criteria check.** CoW is **not** a sponsor: this buys Unique Execution (25% of the rubric), not a
sponsor prize. Per P8 the Uniswap Prize is 45% of all awards ever and is the one most tightly coupled to the
theme, and this hits official prompt example #4 ("hybrid routing between private orderflow systems (CoW,
Flashbots Protect) and Uniswap") verbatim while satisfying the stated win condition ("combine defense and
recapture"). **Non-decorative sponsor upgrade available — Brevis:** the genuinely hard part of this hook is
*classifying toxic flow*, and per-address realized markout over history is exactly what a hook cannot compute
on-chain and exactly what Brevis proves. That is a load-bearing pairing, not a bolt-on, and it is not the
volume-discount idea Brevis explicitly disqualified. **Brevis Sepolia deployment UNVERIFIED — check before
committing.** Do **not** bolt on Chainlink Automation to sweep expired orders: a permissionless incentivised
`settleExpired` does that job, so Automation there would be decorative and I would kill it on review.

**Scores.** Original 5 — nobody has authored a real batch-auction order from inside a v4 pool, let alone paid
the auction's surplus back to the LPs it was diverted from. Unique Execution 5 — ERC-1271 order authorship +
watch-tower discovery + `donate()` recapture is an architecture no submission in nine cohorts has. Impact 4 —
LPs stop trading against toxic flow *and* get paid for it; capped because it only helps pools with enough
volume to interest a solver. Functionality 3 — async settlement, the router `minOut` wart, and a hard
dependency on Sepolia solver liveness; this is the weakest leg and it is 15% of the score. Presentation 4 — a
live Sepolia batch settling our hook's own order is thirty seconds of video no competitor can match.
**Weighted ≈ 4.40.**

---

### #2 — `Graze` — v4 concentrated liquidity that auctions its own LVR into CoW's real solver competition

**Mechanism.** LPs opt liquidity into a hook-owned vault (the taught JIT-rebalancing custody pattern: tokens
go to the hook, not PoolManager). Each block in which the pool's tick has drifted, the hook publishes a
rebalancing conditional order via `ComposableCoW` — "I will sell up to X of token0 at no worse than my curve
price" — and **solvers bid by offering surplus to the pool.** Winner rebalances; the surplus lands in the vault
and accrues to opted-in LPs. **The defense half:** while a rebalance order is live, `beforeSwap` charges a
punitive directional fee to any swap moving price *toward* the drift, so the only cheap way to arbitrage this
pool is to win the CoW auction and pay the LPs for the privilege.

**What the integration does.** Same `ComposableCoW` surface as #1. This is CoW AMM's actual mechanism —
"solvers bid to rebalance the pool… the solver that offers the most surplus to the pool wins" — which today
exists **only for constant-product Balancer-style pools.** Porting it to v4 concentrated liquidity is real
work and has never been done.

**Delete-the-integration test: PASSES.** Without a real solver auction this degenerates into the 55 homegrown
LVR auctions already in the directory. The whole differentiator is that the auction is somebody else's, is
live, and is bonded.

**FEASIBILITY.** Same verified surface as #1, so same two open risks, plus a much heavier build: an LP vault,
share accounting, drift measurement, and reconciling vault inventory with pool state. **This is the one I would
not start eight days out.** With the owner's confirmed +2 months it is buildable.

**The attack.** Unlimited capital: **starve the auction.** A searcher who is the only bidder wins every
rebalance at the reserve price, i.e. classic monopolist capture — identical residual to #1 and equally
un-eliminable. Worse here: the punitive directional fee is a **fail-closed trading brake** and a wrong drift
estimate bricks normal trading on the pool. That is the exact Hardcap failure class (CLAUDE.md §6) and it is
**mitigable only with a conservative band and an honest statement**, never with a green test.
Third: vault custody is a much larger trust surface than #1's per-order escrow. *Accepted, and it is the reason
this ranks second.*

**Sponsor-criteria check.** Same as #1 — CoW is not a sponsor; Uniswap Prize + prompt example #5 ("protocol-
native MEV auction hooks where LPs recapture a share of extracted value"). **Warning:** LVR auctions are on
Atrium's explicit AVOID list (55 submissions, 19–20 in UHI9 alone) and a judge may pattern-match this to the
lane before hearing that the auction is real. Atrium's own escape clause is *"need a sharp mechanism or sponsor
differentiator"* — we have the sharp mechanism, but we would be spending the first 45 seconds of the video
digging out of a category.

**Scores.** Original 5 — CoW AMM's LVR capture has never been brought to concentrated liquidity. Unique
Execution 5 — genuinely novel architecture. Impact 4 — LVR is the largest real leak in the theme. Functionality
2 — heaviest build of the four, custody risk, fail-closed brake; most likely to ship half-finished. Presentation
3 — you must first talk the judge out of the AVOID list. **Weighted ≈ 4.15.**

---

### #3 — `Firstlook` — the pool sells fee-free access, priced in externally-sourced UniswapX surplus

**Mechanism (corrected against source — see feasibility).** The hook is itself the *filler*. It exposes
`fill(SignedOrder)`, which takes PoolManager's lock and, while unlocked, calls
`reactor.executeWithCallback(order, data)`. The reactor pulls the swapper's input tokens to the hook via
Permit2, then calls back into `hook.reactorCallback(...)` — **at which point PoolManager is already unlocked and
the hook is the unlocker**, so it can `swap`/`take`/`settle` against its own pool with no second unlock. The
hook pays the order's outputs, keeps the Dutch surplus (decayed order price minus pool execution price), and
`poolManager.donate()`s it to the in-range LPs whose liquidity filled it. `afterSwap` verifies the donation
actually happened by reading **PoolManager's own transient ledger via `exttload`** — the filler cannot lie about
what it donated, because the number is not its own. Settlement: atomic, or the whole unlock reverts.

**What the integration does.** UniswapX reactors are real Uniswap-deployed contracts and **filling is
permissionless — verified in source: `BaseReactor` has no access control and no filler allowlist**, and
Uniswap's own docs say *"UniswapX has one permissioned role (quoter) and one permissionless role (filler)."*
The external surplus being donated is the Dutch decay — value that today goes entirely to a third-party filler.

**Delete-the-integration test: PASSES ONLY IN THIS FORM — and this is the point.** The naive version ("a hook
that also fills UniswapX orders") **fails**: you could delete the hook and have a plain filler that happens to
route through a v4 pool, which is what every filler already does. That version is decorative and I would kill
it. It becomes load-bearing only because the hook *enforces* the surplus donation against PoolManager's ledger,
and because the hook is the unlocker when `reactorCallback` fires — the fill and the donation are one atomic
unlock that no standalone filler can replicate.

**FEASIBILITY — VERIFIED. Better than I assumed on infrastructure, worse on flow.**
`IReactorCallback` is `reactorCallback(ResolvedOrder[],bytes)`, selector `0x585da628`. **Real Uniswap-deployed
reactors exist on Ethereum Sepolia** — `ExclusiveDutchOrderReactor` `0xD6c073F2A3b676B8f9002b276B618e0d8bA84Fad`
and `V2DutchOrderReactor` `0x0e22B6638161A89533940Db590E67A52474bEBcd`, both confirmed live by RPC probe and
bytecode fingerprint. Sepolia also carries the v4 PoolManager and Permit2, so the demo runs against **Uniswap's
own reactor, not one we deployed** — materially stronger in a pitch, and it costs nothing.

**Three findings that change the design, and one that kills a variant:**
- **The callback goes to `msg.sender`, not to an address named in the order.** The hook must *call*
  `executeWithCallback` itself; it cannot be passively selected as a fill target. My original framing
  ("reactor → hook") was wrong and is corrected above.
- **Exclusivity on mainnet is not ours to take.** V2/V3 orders require a valid cosignature (ecrecover, EOA
  only — no ERC-1271) and *"the Uniswap Interface and Uniswap API set the cosigner to Uniswap Labs"*; quoter
  status is permissioned. **We cannot make real mainnet user flow name us as exclusive filler.** The
  permissionless escape is `ExclusiveFillerValidation` via the swapper-signed `additionalValidationContract`,
  which works on every reactor — but the *swapper* must choose it, so it does not reach existing Uniswap flow.
- **There is no testnet order flow — zero `Fill` events on either Sepolia reactor in ~294,000 blocks (~6 weeks).**
  We would sign our own orders. **This is the candidate's honest ceiling: on a testnet we are both swapper and
  filler, i.e. entirely self-dealing.** Contrast #1, where the solver filling our order is a genuine third
  party. That asymmetry is the main reason this ranks below `Sluice`.
- **KILLED VARIANT — do not build on `PriorityOrderReactor`.** Uniswap's docs: *"Priority gas auctions are no
  longer a separate integration path. Fillers previously integrated against a Priority reactor should migrate
  to DutchV3."* That lane was just retired.

**Two things a judge will ask about.** (i) **License: UniswapX is GPL-3.0** (files tagged
`GPL-2.0-or-later`). If our hook imports their source it is a derivative work and must ship GPL. Avoidable by
declaring `IReactorCallback` and the structs ourselves — an ABI is not the copyrighted artifact. (ii)
**Naming collision:** the UniswapX repo now carries a `src/v4/` tree — "UniswapX **version 4**", with its own
`IPreExecutionHook` — deployed on Unichain Sepolia. Nothing to do with Uniswap v4 pool hooks. Pitch "a v4 hook
that plugs into UniswapX" and a judge who knows that repo hears the wrong thing. Get ahead of it.
**Reuse note:** `src/assay/PoolLedger.sol` already does the `exttload` ledger read and was untouched by the
Assay audit. The enforcement primitive is 30 lines we already own and have already proven.

**The attack.** Unlimited capital: **buy the exemption and use it for something worth more than the donation.**
A filler donates the floor, then uses fee-free access to run an unrelated arbitrage in the same unlock. Pricing
the donation at `max(foregone fee, surplus floor)` neutralises the profit — but note that if the donation is
always ≥ the fee, the exemption is worthless and nobody buys it; the mechanism only lives in the window where
Dutch surplus exceeds the fee. **That window is the whole product and I am not certain it is wide enough to
matter. This is the candidate's real weakness, and it is economic, not technical.** *Mitigable, unproven.*

**Sponsor-criteria check.** UniswapX is Uniswap's own product, so this is a pure Uniswap-Prize play with no
second track. Weaker on P1 (integrations nearly double odds — 27.5% vs 15.0%) than a Uniswap+sponsor pairing.

**Scores.** Original 4 — LP-owned filling is fresh; the enforced-atomic-donation primitive is the novel part.
Unique Execution 4 — the ledger-enforced donation is genuinely distinctive and we already own the machinery.
Impact 3 — gated by how often Dutch surplus exceeds the fee, which I cannot yet size. Functionality 3 —
infrastructure now verified, but with no testnet order flow we are both swapper and filler, which is
self-dealing and a judge will see it. Presentation 3 — the mechanism takes ninety seconds to explain, which is expensive in a five-minute
video. **Weighted ≈ 3.55.**

---

### #4 — `Blindfold` — probabilistic settlement where the randomness is provably not the proposer's

**Mechanism.** `beforeSwap` NoOps swaps above a per-address per-block cumulative size threshold into a queue
and commits on-chain to K candidate execution prices bracketing the current pool price. The hook calls
`VRFCoordinatorV2_5.requestRandomWords`; **the fill is executed inside `fulfillRandomWords` itself**, in the
same transaction that reveals the draw. Chainlink Automation's `performUpkeep` sweeps the queue for expired or
unfulfilled requests. A sandwicher must commit their front-run before knowing which of K prices the victim
fills at, turning the sandwich from an arbitrage into a negative-EV lottery.

**What the integration does.** Chainlink VRF v2.5 on Sepolia, coordinator
`0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B`, key hash
`0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae`, 3-block minimum confirmations, payable
in LINK or native ETH. Automation registry `0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad`. Both verified live.

**Delete-the-integration test: PASSES, and this is the cleanest argument of the four.** Delete VRF and you
need on-chain randomness. `blockhash` and `prevrandao` are **proposer-influencable — and the proposer is the
adversary in MEV.** A sandwich-defence built on proposer-chosen randomness is defeated by the proposer, i.e.
by exactly the party it defends against. The integration is not a feature; it is the security argument.

**FEASIBILITY. The most certainly-demoable of the four, and the only one with zero open verification items.**
Real coordinator, real testnet, real fulfilment, no permissioned counterparty, no off-chain relay, no watch-tower.

**The attack.** Best shot: **backrun the reveal.** If settlement were a separate transaction from
`fulfillRandomWords`, the fulfilment sits in the mempool with the price now public and a searcher backruns it.
*This is why settlement must happen inside the callback* — reveal and fill in one transaction reduces the
attack to ordinary top-of-block arbitrage. **Mitigated by construction, and this design detail is the whole
idea.**
Second: **selective non-participation.** If a searcher can predict *whether* they will be delayed, they simply
do not trade when delayed, or split. The threshold must be on cumulative per-address per-block volume, not per
swap. *Mitigable, imperfectly.*
Third, and honestly: **VRF costs LINK per request.** On a live pool that is prohibitive for small swaps, so
this only ever applies to large trades where MEV saved exceeds oracle cost. *Accepted, and it caps Impact.*
Fourth: 3-block minimum confirmations means a user waits ~36s. *Accepted UX cost.*

**Sponsor-criteria check.** Chainlink's stated ideas include *"trick the before swap hook to not execute the
swap, and instead initiate a new Chainlink Functions call, then in the callback function initiate the swap
again"* — **this is that pattern, with VRF substituted for Functions because the security argument needs
unpredictability rather than off-chain compute.** Two Chainlink products, both load-bearing. Combined with
Uniswap prompt example #2 ("time-weighted execution windows or probabilistic settlement hooks") this is the
Uniswap + one sponsor shape, which 23 prior projects converted into multi-track wins. **Chainlink has awarded
only 5 prizes ever (P8) — a thin track, but thin also means uncrowded.**

**The honest problem with this one.** Probabilistic settlement via VRF is **taught in the UHI curriculum**
("Async Swap Fulfillments … execute at a random point in time via VRF Oracles") and is official prompt example
#2. Gate-1 bars uncredited curriculum code, and more importantly the 30%-weighted Original Idea score punishes
building the thing the course taught. W1 says there are **zero implementations in 662** — but "taught, named in
the prompt, and never built" cuts both ways: it may be unbuilt because it is *obvious and unrewarding*, not
because it is hard. The only genuinely original claims here are the commit-to-K-prices structure and settling
inside the callback. **That is a thinner novelty margin than the other three and I will not pretend otherwise.**

**Scores.** Original 3 — the curriculum teaches the shape; only the K-price commitment and in-callback
settlement are ours. Unique Execution 4 — two integrations, both essential, cleanly argued. Impact 3 — per-swap
oracle cost confines it to large trades. Functionality 4 — the only candidate with no unverified dependency;
this will actually work on demo day. Presentation 4 — "the proposer is the adversary, so the proposer cannot
pick the number" is a sentence a non-technical judge understands immediately. **Weighted ≈ 3.50.**

---

## 2. MY PICK

**`Sluice` (#1).**

It is the only candidate that is simultaneously: a real integration with a counterparty that has a
permissionless on-chain surface; a direct hit on an official Uniswap prompt example; and an execution of the
organizers' own stated win condition — defense (toxic flow is routed off the LPs) **paired** with recapture
(the auction's surplus is donated back to those same LPs). The integration survives the delete test more
convincingly than any of the others, because the number it produces — competitive-auction surplus over our own
pool price — is one we cannot manufacture in-house at any price.

It is also the correct hedge on the two things I am least sure of. If the ComposableCoW-from-a-non-Safe answer
comes back "Safe only", `Sluice` costs a minimal Safe and survives; `Graze` survives too. If Sepolia solver
liveness comes back dead, `Sluice` degrades to "real contracts, our solver" — weaker, still honest, still
demonstrable. Neither open item is a single point of failure. Compare `Firstlook`, whose economic viability
rests on a window I cannot currently size.

**Take `Blindfold` (#4) as the named hedge, not as the submission.** It is the only one guaranteed to work on
demo day, and if verification kills the CoW path outright it becomes the pick by default — but its 3/5 on the
30%-weighted originality axis is a ceiling we should not accept while a better option is live.

**Do not run two.** CLAUDE.md §9: one submission. Every hour on a second product is an hour off the one that ships.

---

## 3. KILLED ON FEASIBILITY GROUNDS

| Idea | Why it died |
|---|---|
| **Any hook that "integrates Flashbots Protect"** | No contract exists. Off-chain RPC + off-chain MEV-Share node + builder-delivered refunds under an off-chain condition. Nothing for Solidity to call. **Impossible, not hard.** |
| **A hook that detects protected/private flow on-chain** | The only correlate is zero priority fee (`tx.gasprice == block.basefee`), which any searcher forges for free. Any claim to detect Protect flow is **false**. Killed outright — this is a claim that dies under one judge question. |
| **MEV-Blocker integration** | Same shape as Flashbots: an RPC. Off-chain refunds. No surface. |
| **Atlas / FastLane OFA** | Real contracts exist (`DAppControl`), but entry requires embedding their SDK in a **frontend** and routing through an off-chain Operations Relay + bundler. A hook cannot pull flow into Atlas. Also 0 prior UHI integrations — same wall, same reason. |
| **UniswapX exclusive-filler-for-LPs (mainnet form)** | Exclusivity is set by the swapper at signing through Uniswap's **permissioned** quoter/RFQ set. We cannot make real orders name us. Survives only in the restructured permissionless-competition form (#3), and only on a self-deployed testnet reactor. |
| **"Chainlink VRF hook on Unichain"** | **VRF is not deployed on Unichain or Unichain Sepolia.** This combination does not exist. If anyone proposes it, they have not checked. |
| **Chainlink Automation bolted onto `Sluice`** | A permissionless, gas-incentivised `settleExpired()` already does the job. Automation there is a call you could delete without changing the mechanism — **decorative, and I would kill it on review.** Named here so nobody adds it later to chase a second track. |

---

## 4. VERIFICATION-PENDING (do not build past these)

1. ~~**Can an arbitrary non-Safe contract own a `ComposableCoW` conditional order?**~~ **RESOLVED: YES.**
   `create()` sets `singleOrders[msg.sender][hash(params)] = true` with no Safe or type check. Cost is that we
   implement `isValidSignature` ourselves (~50 lines) instead of inheriting `ExtensibleFallbackHandler`.
2. ~~**`ComposableCoW` deployed address, Sepolia**~~ **RESOLVED:** `0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74`
   on chain 11155111 (same address on mainnet, Gnosis, Arbitrum, BNB, Linea, Ink, Plasma). Ready-made handlers
   also deployed on Sepolia: `TWAP` `0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5`, `StopLoss`, `GoodAfterTime`,
   `TradeAboveThreshold`. `HooksTrampoline` deliberately not pinned: per-solver instances, see §0.
3. **Is CoW's solver competition actually alive on Sepolia** — will a small order from an unknown contract get
   filled, or is the testnet a graveyard? This determines whether the headline demo is "a real batch filled our
   order" or "we ran a solver against real contracts." **Both are honest; only one is a 5.**
4. ~~**UniswapX reactor addresses on any testnet; is filling permissionless?**~~ **RESOLVED: YES to both.**
   Sepolia `ExclusiveDutchOrderReactor` `0xD6c073F2A3b676B8f9002b276B618e0d8bA84Fad`, `V2DutchOrderReactor`
   `0x0e22B6638161A89533940Db590E67A52474bEBcd`; no filler allowlist in `BaseReactor`. But **zero testnet order
   flow** and **mainnet exclusivity is cosigner-gated by Uniswap Labs** — see #3.
5. ~~**Brevis `BrevisApp` deployment on Sepolia**~~ — **RESOLVED, feasible.** `BrevisRequest` is deployed on
   Sepolia at `0xa082F86d9d1660C29cf3f962A31d7D20E367154F`; `BrevisApp` is an abstract contract you inherit,
   exposing `brevisCallback(requestId, appCircuitOutput)` → `handleProofResult`; Sepolia is supported as both
   source and destination chain; testnet prover endpoint `https://appsdkv3.brevis.network`. **Known footgun:**
   a Sherlock audit finding against `BrevisApp.sol` ("Ignoring Validation Results Will Enable Exploits Against
   BrevisApp Users") — if we take this pairing, `handleProofResult` must check the validation result, not just
   the callback. Do not inherit it blind.

**Only item 3 (CoW solver liveness on Sepolia) remains open.** It is the single fact separating "a real batch
auction filled our hook's order" from "we ran a solver against real contracts" — a 5 versus a 3 on the demo.
Nothing else blocks a decision.

---

## PROVENANCE

Fetched and read this session: `docs.cow.fi` (core contracts / ComposableCoW / signing schemes / HooksTrampoline /
CoW AMM for solvers), `docs.flashbots.net` (mev-refunds, mev-share overview), `developers.uniswap.org/contracts/v4/deployments`,
`docs.chain.link/vrf/v2-5/supported-networks`, Chainlink Automation network docs, `github.com/FastLane-Labs/atlas` (via search),
Brevis SDK contract-address docs (via search), CoW contracts deployment-addresses page (mintlify mirror),
`raw.githubusercontent.com/cowprotocol/composable-cow/main/networks.json` and `src/ComposableCoW.sol` (source read).
UniswapX surface (reactor addresses, `IReactorCallback`, `BaseReactor`, `ExclusivityLib`, cosigner gating, Permit2
ERC-1271, GPL licensing, testnet `Fill`-event liveness) verified by sub-agent against repo source + live RPC probes.
Prior in-repo research relied on, not re-fetched: `HACKATHON_CONTEXT.md` §5/§7, `WINNERS_LANDSCAPE.md` §3 W5 / §4 P1,P8, `CLAUDE.md` §5.
Failed / not attempted: none blocking; MEV-Share refund delivery mechanics are documented only in prose and the
absence of a contract address is itself the finding.

---

# EXECUTION — 2026-08-26

> Everything in this section was **run**, not read. Test file: `test/spike/CowNonSafeFork.t.sol`,
> 9 tests, all green, against the **real deployed CoW contracts on a Sepolia fork**
> (`forge test --match-path "test/spike/CowNonSafeFork.t.sol"`, `SEPOLIA_RPC_URL` set).
> Nothing is mocked. Interfaces are re-declared locally so the GPL composable-cow tree stays out of `src/`.

## TASK 1 — does `ComposableCoW` accept a non-Safe contract? **YES. Proven end to end.**

| # | Test | What it executes | Result |
|---|---|---|---|
| 0 | `test_0_realContractsArePresent` | code at both addresses; `CCOW.domainSeparator() == SETTLEMENT.domainSeparator()` = `0xdaee378b…` | ✅ |
| 1 | `test_1_plainContractCanCreateConditionalOrder` | plain contract calls `create()`; `singleOrders[hook][h]` flips false→true | ✅ **storage write lands** |
| 2 | `test_2_watchTowerCanDeriveOrderAndSignature` | `getTradeableOrderWithSignature()` on a non-Safe owner | ✅ 864-byte sig, **EIP-1271 Forwarder branch**, asserted *not* the `safeSignature(...)` branch |
| 3 | `test_3_…SignatureCheckAcceptsPlainContract` | our `isValidSignature` returns `0x1626ba7e` | ✅ — but see note, this one is near-circular |
| 6 | **`test_6_realSettlementAcceptsPlainContractOrder`** | **the real `GPv2Settlement.settle()`** with an `Eip1271` trade (`flags = 2<<5`), solver added via the allowlist manager | ✅ **hook received 1000e18 buyToken; sell side pulled to 0** |
| 6b | **`test_6b_mutation_…`** | same, with the hook returning `0xdeadbeef` instead of the magic value | ✅ reverts `"GPv2: invalid eip1271 signature"` — **proves test_6 is not vacuous** |
| 7 | `test_7_unauthorisedOrderIsRejectedByRealSettlement` | order never `create()`d, pushed through real `settle()` | ✅ rejected |
| 4 | `test_4_erc165ReturningFalseBricksTheWatchTower` | owner implements `supportsInterface` → `false` | ✅ reverts `InvalidFallbackHandler()` |
| 5 | `test_5_solverAllowlistIsGated` | `ALLOWLIST.manager()` | `0xA03be496e67Ec29bC62F01a428683D7F9c204930` |

`test_3` alone proves nothing — it calls our contract and checks our own return value. **`test_6b` is the
assertion that matters**: flipping the magic value turns the real deployed settlement red. Recorded because
CLAUDE.md §9 says a first-run green is a reason for suspicion, and the first version of this suite was green
on all six tests before `test_6`/`test_6b` existed.

### The exact interface our hook must implement

```solidity
// on the HOOK (order owner) — this is the whole non-Safe surface:
function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
//   decode signature as abi.decode(sig, (GPv2Order.Data, ComposableCoW.PayloadStruct))
//   assert ccow.singleOrders(address(this), ccow.hash(payload.params))
//   assert hash == GPv2Order.hash(order, cowDomainSeparator)
//   delegate to handler.verify(...); return 0x1626ba7e

// on a separate HANDLER contract (IConditionalOrderGenerator):
function getTradeableOrder(address owner, address sender, bytes32 ctx, bytes staticInput, bytes offchainInput)
    external view returns (GPv2Order.Data memory);
function verify(address,address,bytes32,bytes32,bytes32,bytes,bytes,GPv2Order.Data) external view;
function supportsInterface(bytes4) external view returns (bool); // MUST answer true for 0xb8296fc4
```

**Estimate: 8–12h** for both contracts with adversarial tests (`isValidSignature` 4–6h, handler 4–6h). The
surrounding Sluice machinery — escrow ledger, NoOp `beforeSwap`, `claim`/`settleExpired`, `donate()` split —
is a further **16–24h**. Call it **30–45h** for the integration end of the hook.

### FOUR FOOTGUNS, all discovered by execution. Any one of them silently kills the integration.

1. **`supportsInterface` returning `false` bricks discovery.** `getTradeableOrderWithSignature` does
   `try owner.supportsInterface(ISignatureVerifierMuxer) { if(!supported) revert InvalidFallbackHandler(); }
   catch { /* EIP-1271 Forwarder branch */ }`. A hook that implements ERC-165 and answers `false` **reverts**;
   one that does not implement it at all falls into the `catch` and works. **Our hook must not answer `false`
   to an unknown interfaceId — it must revert or not implement `supportsInterface`.** Asserted in `test_4`.
   Note this is the opposite of normal ERC-165 hygiene, so it is exactly the kind of thing that gets "fixed"
   into a bug later. Write it down in the contract.
2. **The watch-tower filters on HANDLER, not owner — `defaultAction: DROP`.** CoW's published Sepolia policy
   (`prod/filter-policy-11155111.json`) allowlists five handlers (TWAP `0x6cF1e9cA…`, StopLoss, etc.) and
   drops everything else; `"owners": {}` — **owner type is never consulted, which is why non-Safe works.**
   Corroborated on-chain: 257 `ConditionalOrderCreated` on Sepolia over ~2M blocks, 23 with custom handlers,
   **zero fills for any custom handler**; a TWAP-handler control got 12 fills, and 7/7 owners filling in the
   last 28 days used the TWAP handler. **A bespoke Sluice handler will not be relayed by CoW's hosted tower.**
3. **ERC-1271 orders get no balance/allowance waiver.** The waiver in `order_validation.rs` is `PreSign`-only.
   The hook must hold ≥1 atom of the sell token **and** have a `GPv2VaultRelayer` allowance **at placement
   time**, or the API rejects with `InsufficientBalance`/`InsufficientAllowance`.
4. **A revert in `isValidSignature` propagates and aborts the solver's entire batch** — `test_7` reverts with
   our own `NotAuthed()`, not with a caught "bad signature". Sluice's order validity depends on live v4 pool
   state, so we are a structurally high-revert-risk order. Solvers simulate first, so in practice this means
   **deprioritisation, not griefing** — but it is a reason to make `verify` as state-independent as possible.

### CORRECTION TO §0 OF THIS DOCUMENT

I wrote that the ComposableCoW loop "closes with **no off-chain action by us**." **That is now too strong and
I am withdrawing it.** It holds only if we use a **stock allowlisted handler**. With a bespoke handler we must
run our own watch-tower (`ghcr.io/cowprotocol/watch-tower`) — a real off-chain component we operate. The
choice is:
- **(a) stock TWAP handler** → fully hosted relay, zero off-chain ops, proven to fill on Sepolia — but the
  order shape is a TWAP, not Sluice's bespoke condition. **This is the demo path.**
- **(b) bespoke handler + our own watch-tower** → the mechanism we actually want, with an off-chain component
  in the trust story that must be disclosed in the video.

## TASK 2 — is CoW's solver competition alive on Sepolia? **ALIVE, BUT A MONOPOLY.**

- **4 settlements in the last 5,000 blocks** (~1 per 4h), **260 in 28 days** — measured via `eth_getLogs` on
  `Settlement(address)` `0x40338ce1…`.
- **All 260 by a single solver, `0xe40cbca4…`.** There is exactly one.
- ⚠️ **My first scan reported zero settlements over 2M blocks and was WRONG** — a broken `cast logs`
  invocation. It was caught only because I ran the same query against **mainnet as a control** and got an
  impossible zero there too. Recording the error because the control is the only reason it did not ship.

**What this means for Sluice, and it is not small.** An order we post can realistically be filled — the
plumbing is demonstrable end to end on Sepolia. But **Sluice's entire recapture mechanism is the surplus of a
competitive auction, and on Sepolia there is no competition.** The demo can prove the mechanism *works*; it
cannot prove the mechanism *pays*. Do not let the video imply otherwise. The economic claim has to be argued
from mainnet's solver set, explicitly labelled as not-demonstrated.

## TASK 3 — is `isSolver()` permissionless?

**Reading it is; joining it is not.** `isSolver(address)` is a public view any contract can call with no
gating. The list itself is written only by `addSolver`/`removeSolver` under `onlyManager`, manager =
`0xA03be496e67Ec29bC62F01a428683D7F9c204930` (a CoW DAO address) — becoming a solver means petitioning them.
Sluice only ever *reads* it, so this is a non-issue for the pick.

## VERDICT: **GO WITH CAVEATS** on Sluice.

The load-bearing claim survived execution: **a plain non-Safe contract really can author a CoW order that the
real `GPv2Settlement` accepts and settles**, mutation-tested. Sluice is not dead.

Three caveats now attach, none fatal, all disclosure items:
1. Discovery of a **bespoke** handler needs our own watch-tower. "Zero off-chain action" is withdrawn.
2. Sepolia has **one solver**, so surplus-recapture economics are not demonstrable on testnet.
3. Four silent-failure footguns above must be encoded in the contracts and in tests, not in a comment.
