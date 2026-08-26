# IDEAS_MECHANISM — five candidate hooks for UHI10, as mechanisms

> Author: Lead Exploit Developer / Economic Incentives Analyst / State Transition Expert.
> Date **2026-08-26**. Inputs: `HACKATHON_CONTEXT.md`, `WINNERS_LANDSCAPE.md`, `data/hook_directory_662.json`, `CLAUDE.md` §5.
> Every prior-art count below was re-run by me against the 662 rows (`/tmp/q.py` regexes quoted inline). I did not re-fetch anything from the web.

---

## 0. RANKING (best first)

| # | Name | One-line mechanism | Weighted rubric score |
|---|---|---|---|
| 1 | **HASTE** | Pool posts a price for *immediacy*; swaps that pay it execute now, swaps that don't go into an irrevocable queue that settles at a random future block; the immediacy premium is donated to in-range LPs. | **4.10** |
| 2 | **SWITCHBACK** | Hook stores the pool's tick at block open and the intra-block high/low water marks; any swap that walks the price *back* toward the open pays a fee proportional to the tick-distance it retraces, escrowed and donated next block to liquidity that was in range at the open. | **3.95** |
| 3 | **GREEN LANE** | Hook reads the *calling contract* (`sender`), classifies it against a per-pool table of private-orderflow settlement venues (CoW `GPv2Settlement`, UniswapX reactor, MEV-Blocker-bound routers), and charges public-mempool flow a surcharge that funds a discount for venue-arrived flow. | **3.55** |
| 4 | **LOCKSTEP** | Hook reads the caller's live flash-accounting deltas out of PoolManager's transient storage via `exttload` at `beforeSwap`/`beforeAddLiquidity`, and charges a same-lock composition fee to any swap that is atomic with a liquidity change or with another swap on the same pool. | **3.30** |
| 5 | **LADDER** | Every swap in a block settles at one of N pre-committed price rungs, the rung chosen by a beacon revealed after the block closes; the gap between the rung and the trader's marginal price accrues to LPs. | **2.85** |

**My bet: HASTE.** Reasoning at §6. **SWITCHBACK is the designated fallback** — it is strictly the more buildable of the two, it shares no dependencies with HASTE, and it can be dropped *inside* HASTE later as the pricing rule for the immediate lane. If the §1.6 experiment kills HASTE's queue, we lose ~2 days and ship SWITCHBACK.

**Killed during this work: two candidates. See §7.** W4 (LP governance over the MEV mechanism) and W3 (searcher bonding/slashing for priority access) both died on their own economics, not on prior art. Both are 0/662 *because they don't work*, which is a finding in itself and a warning about treating white space as opportunity.

---

## 1. HASTE — the pool sells immediacy

### 1.1 Mechanism
**State kept:** per-pool `immediacyPremiumBps` (a function of realized intra-block tick variance over a rolling window); a queue of irrevocable deferred orders as `(owner, currency, amount, zeroForOne, placedBlock, maturityBlock)`; the trader's escrowed input as ERC-6909 claim tokens held by the hook.
**Trigger:** every swap. `beforeSwap` charges the immediacy premium on top of the LP fee. Alternatively the trader never touches the pool directly — they place a deferred order through the hook's periphery contract, paying zero premium.
**Settlement path:** deferred orders mature at `placedBlock + U`, where `U` is drawn from a randomness source and is not known at placement time. Any keeper (or, gas-amortised, the next immediate swapper) may crank the queue; matured orders execute at the pool's *then-current* price, not at a quote fixed at placement. The immediacy premium collected from the fast lane is `donate()`d to in-range LPs.

**The framing that makes this a mechanism-design argument and not a feature list:** LVR is an option — the right to trade against a stale AMM price before it updates — and arbitrageurs currently exercise it **for free**. HASTE puts a posted price on that option and pays the premium to the people who are short it. The queue exists so that the flow that does *not* value the option has somewhere to go that isn't "pay the arb tax anyway".

### 1.2 Defense + recapture
Both, in one number, and they are not bolted together:
- **Defense.** A sandwich requires the victim's fill to be at a block/index the attacker can predict. A queue order matures at an unknown block and the trader themselves cannot say when. The attacker must pre-position in every candidate block and carry inventory across each — converting a risk-free sandwich into K directional bets, of which at most one lands adjacent.
- **Recapture.** The immediacy premium *is* the LVR toll, paid by exactly the flow that cannot wait (arbitrageurs, liquidators), and donated to in-range LPs.
This is the organizers' win-condition sentence answered literally: the shield (random settlement) and the redistribution (immediacy premium) are two prices on the same product.

It is also the only *incentive-compatible* answer I found to the organizers' open problem #3 ("dynamic fees can't distinguish good retail from bad toxic flow"). Every one of the 189 dynamic-fee hooks tries to **classify** flow. HASTE doesn't classify anything — it makes the flow **self-select** by pricing the one dimension where retail and toxic flow genuinely differ: urgency. A retail swap is indifferent to 30 seconds. A CEX-DEX arb is worthless 30 seconds late. That is a separating equilibrium, not a heuristic, and it cannot be spoofed by an attacker pretending to be retail — pretending costs them the arb.

### 1.3 v4 mechanics
- Permissions: `beforeSwap` + `beforeSwapReturnDelta` + `afterSwap`. Dynamic-fee pool (`LPFeeLibrary.DYNAMIC_FEE_FLAG`), premium applied via fee override in the immediate lane.
- Deferred lane is the taught **async-swap / NoOp** pattern: `beforeSwap` returns a `BeforeSwapDelta` that consumes the entire specified amount, the hook `settle()`s the input and mints itself ERC-6909 claims, and the swap does not touch the curve. Crank later via a periphery `fill(orderIds[])` that opens its own lock and swaps the escrowed claims.
- Realized-variance measurement: track `tick` at first-touch of each block, accumulate `|Δtick|` into an EWMA. No oracle, no keeper, no external dependency. (This is the W6 piece, done as *premium* scaling rather than *delay* scaling — see §1.5.)
- Randomness: **do not use Chainlink VRF.** VRF's callback is itself a transaction whose arrival a searcher can watch; and the sponsor dependency buys nothing. Use `blockhash(placedBlock + 1)` mixed with the order id — unknown at placement, cheap, and manipulable only by a proposer who controls that specific block. State the proposer caveat explicitly; do not claim VRF-grade randomness.
- **Illiquid pool / tiny swap:** the immediacy premium is a percentage, so a tiny immediate swap pays a tiny premium — fine, and deliberately no free tier (§1.4c). A deferred order on an illiquid pool is the real hazard: by maturity the price may have moved through the trader's tolerance. The order therefore carries `minOut`, and a matured order that cannot clear `minOut` is refunded, not filled. **A refund path is a cancellation path in disguise** — see §1.4b.

### 1.4 The attack
**(a) Watch the queue and blanket-front-run.** The queue is public on-chain state. A searcher reads a large pending order, knows it matures in one of blocks `[N, N+K]`, and front-runs in all K. Cost: K positions, K−1 of which must be unwound at a loss or held. **Mitigable, and quantifiable** — the defense is a ratio, not a wall: sandwich EV falls by roughly `1/K` while inventory risk rises with K. Publish the number; do not claim sandwiches are "impossible".
**(b) The free-option attack — the one that kills naive queues.** A deferred order that can be cancelled, or that fills at a price quoted at placement, is a free American option written by the LPs. Design answers, all mandatory: orders are **irrevocable**, they fill at the **price at maturity** not at placement, and the `minOut` refund path must be priced (a refund forfeits a fee) or it becomes a cancel button that a trader exercises exactly when the market moved against the pool. **If we cannot price the refund, HASTE is adversely selected and should not be built.**
**(c) The Hardcap-class hole: any exemption is the exploit.** Hardcap died because the first swap of the block was tax-exempt and because a dust liquidity add zeroed the claw for a block. The analogous holes here: a size threshold below which immediacy is free (→ split the sandwich into sub-threshold legs), a first-swap-of-block exemption (→ the front-run leg is always first), a per-address allowance (→ Sybil). **HASTE must have no free tier, no threshold, and no per-identity state whatsoever.** Every immediate swap pays `premium × size`, linearly, always. Three `test_noExemption_*` cases must be written *before* the fee curve.
**(d) Stale-price attack on the protected.** Set the premium too high and arbitrageurs stop correcting the pool; the pool's price goes stale; the retail we "protected" gets a worse fill than they would have on an unprotected pool, and LPs get picked off harder when the correction finally comes. **This is the real risk, and it is not an attack so much as a calibration failure.** It is why the premium must scale with realized variance rather than being a constant: when the pool is quiet the option is nearly worthless and the premium should approach zero.
**(e) Queue griefing.** Spam dust orders to bloat the crank's gas and delay real fills. Fix: per-order flat rent that a filler claims, so cranking dust is profitable and placing dust is not.
**(f) Proposer manipulation of `blockhash`.** A proposer who wants a specific order to mature in their block can regrind. Accepted, disclosed, mitigated only by mixing multiple future blockhashes. Do not oversell.
**(g) The default path is the expensive one.** Universal Router enforces `minAmountOut`; a hook that NoOps the swap returns zero output and the router reverts. **So the deferred lane is unreachable through the standard router**, and retail arriving normally pays the premium. Honest consequence: HASTE's protection is opt-in through a periphery contract, and unmodified aggregator flow only ever sees the toll. This is a genuine UX weakness and must be in the pitch, not buried.

### 1.5 Prior art
- `immediacy|speed.?bump|urgency|fast lane|express` over 662 → **1 match, unrelated** (MysticPool, an AI dynamic-fee dashboard).
- Nearest real neighbours: **AsyncSwapHook** (UHI7, *no prize*) — "randomized 24–84 second execution delay on large swaps"; **ISP** (UHI5, no prize) — randomized delayed execution + TWAP bounds; **SwapPilot** (UHI8, Reactive Prize) — NoOp queue executed at an *AI-predicted* optimal moment; **Jincubator IntentSwapHook** (UHI5) — delay so solvers can improve the fill.
- **How HASTE differs:** all four make delay *mandatory and free* — a rule imposed on flow above a size threshold. HASTE makes delay *optional and rebated*, and charges for its absence. None of the four collects a premium, none routes anything to LPs, none has a recapture leg at all. AsyncSwapHook's 1%-of-liquidity threshold is precisely the exemption hole in §1.4c.
- **Off-directory prior art I must name:** IEX's 350µs speed bump and Budish–Cramton–Shim frequent batch auctions are the intellectual ancestors. Neither *sells* immediacy — that is the new part, and I would say so on camera before a judge says it for me.
- Saturated-lane check: this touches lane 19 (commit-reveal/randomized delay, 6 submissions, **0 prizes**). That zero is a warning — the lane has been tried and judges never rewarded it. My read is that they were rewarding nothing because those hooks were shields with no recapture, which is exactly what the organizers' win-condition slide now says out loud. Betting on that read is the risk in this candidate.

### 1.6 Buildability — riskiest assumption and the experiment that kills it
**Riskiest assumption:** that an async NoOp order can be placed, escrowed as ERC-6909, and filled later through a second lock with correct flash accounting, *and* that the resulting UX is not fatally broken by §1.4g.
**Smallest experiment (≤1 day, before anything else is built):** one Foundry test — place a deferred order through a 40-line periphery contract; assert the hook holds the exact ERC-6909 claim; advance blocks; crank; assert the trader receives output and PoolManager's deltas net to zero. Then a second test that routes an ordinary swap through the real Universal Router against the same pool and asserts it still succeeds with the premium applied. If the first test cannot be made to settle, HASTE is dead and we ship SWITCHBACK.
Second experiment (day 2): the refund-path pricing from §1.4b, as an adversarial test where a trader places, waits for an adverse move, and forces the refund. If the trader is profitable in that test, the free-option attack is live.

### 1.7 Scores
| Category | Score | Justification (one sentence) |
|---|---|---|
| Original Idea (30%) | **4** | Selling immediacy and paying the premium to LPs is absent from all 662 rows and from the published AMM literature I can name, but the delay half is a lane that has been visited six times. |
| Unique Execution (25%) | **5** | Two-lane pool, async NoOp escrow in ERC-6909, variance-scaled premium and blockhash-timed settlement is an architecture nobody in this dataset has assembled. |
| Impact (20%) | **4** | It taxes CEX-DEX arb (the dominant LP leak) and defuses sandwiches with one mechanism, but §1.4g means the protected lane needs adoption we cannot force. |
| Functionality (15%) | **3** | Async settlement, a crank, a refund path and a randomness source are four independent ways to ship something half-finished. |
| Presentation (10%) | **4** | "The pool sells immediacy; patience is free and cannot be sandwiched" is one sentence, but the free-option and router caveats need airtime. |
| **Weighted** | **4.10** | |

---

## 2. SWITCHBACK — the second leg pays for the first

### 2.1 Mechanism
**State kept:** `blockOpenTick` (the pool's tick *before* the first swap of the current block executes, lazily initialised), plus the running intra-block `maxTick`/`minTick`. Three slots, one warm SSTORE per block.
**Trigger:** any swap whose execution moves the tick *back toward* `blockOpenTick` from an intra-block extreme — a retracement.
**Settlement path:** that swap pays a fee proportional to the tick-distance it retraces, capped by the distance the price was extended in this block. The proceeds are escrowed as ERC-6909 and `donate()`d at the first swap of the *next* block, so the recipient set is liquidity that was in range at block open.

A sandwich is, definitionally, extension-then-retracement inside one block. SWITCHBACK charges the retracement. It never needs to know who the sandwicher is.

### 2.2 Defense + recapture
Both, and they are literally the same number: the fee that makes the back-run unprofitable is the fee that lands in LPs' pockets. There is no split to argue about and no auction to run. This is the tightest defense+recapture pairing of the five.
**Honest downgrade:** SWITCHBACK does **nothing** about CEX-DEX arbitrage / LVR, which is a one-way move with no retracement in the same block. It is a sandwich-and-JIT mechanism, not an LVR mechanism, and the theme mentions LVR by name. Score it down for that, and say it on camera.

### 2.3 v4 mechanics
- Permissions: `beforeSwap` + `afterSwap` + `afterSwapReturnDelta`, and `beforeAddLiquidity` only to timestamp positions for §2.4d. Dynamic-fee pool.
- `beforeSwap`: if `lastBlock != block.number`, snapshot `blockOpenTick = current tick` **before** the swap and reset the water marks. Compute the retracement the swap is about to cause from `sqrtPriceLimit`/amount, or measure it in `afterSwap` and skim with `afterSwapReturnDelta`. The latter is more precise; CLAUDE.md §5.4 applies — measure the *increase* in ledger debt, never a running absolute.
- No oracle, no keeper, no randomness, no off-chain component, no async path, no router incompatibility. It works through Universal Router unchanged.
- **Illiquid pool / tiny swap:** a 1-wei swap moves the tick 0 and pays 0 retracement fee — correct, and not an exemption, because the fee is a path integral over distance and a thousand 1-wei swaps that collectively retrace X pay the same as one swap that retraces X.

### 2.4 The attack
**(a) Split the back-run across blocks.** Front-run in block N, unwind in N+1. No retracement is observed. **Not fixable, and it is the honest headline limit** — but the mitigation is the economics, not the code: holding inventory across a block turns a risk-free atomic sandwich into a directional position exposed to ~12s of price risk plus competition from other searchers who can now back-run *you*. We convert riskless extraction into a trade. Say exactly that; do not claim sandwiches are stopped.
**(b) Split the back-run into many small swaps.** Defeated by construction *if and only if* the fee is a path integral over retraced ticks with no per-swap threshold. If anyone adds a "minimum retracement to charge" constant, this attack goes live. Test it.
**(c) Block-open poisoning (the Hardcap dust-add analogue).** Push the tick 1 tick at the start of a block for the price of gas, so every subsequent trade in the opposite direction is scored as a "retracement" and taxed. **Structurally defeated:** the taxable retracement is capped by the extension distance, so a 1-tick poison authorises exactly 1 tick of taxable retracement. This cap is the load-bearing invariant of the whole design and must be the first property test written.
**(d) JIT-refund — the vault-drain analogue, and the most dangerous one.** Attacker adds large in-range liquidity, self-sandwiches, pays the retracement fee, and receives it straight back as an in-range LP. Net cost = base fee on two legs + gas. **This is Hardcap's drainable vault reborn and it must be killed before anything else is built.** The mitigation is the next-block donation above: the escrow pays out at the first swap of block N+1, so a same-block JIT position collects nothing. Residual: the attacker enters in N−1 and exits in N+1, carrying ~2 blocks of LP inventory risk. Mitigable, not eliminated — state it. (Prior art for the mitigation family: **sentry**, UHI7, taxes short-lived LP positions on a decay curve; **ParityTax AMM**, UHI5/6, taxes JIT fee capture by inventory duration. Credit both.)
**(e) Cross-venue laundering.** Front-run on our pool, unwind on a different fee tier or a different DEX. Our pool sees only the extension. Partially covered by sharing the tick-path state across all pools that share the hook address; not covered against other DEXes. Real limit, state it.
**(f) False positives.** Genuine two-way retail flow inside one block pays the fee. The proceeds go to LPs rather than being burned, so it is a transfer, not a loss to the system — but it is still a worse fill for an innocent trader and should be disclosed.

### 2.5 Prior art
- `round.?trip|reversal|back.?run|backrun|same.?block.*opposite` over 662 → **0 matches.** The regex is broad and returns nothing.
- Nearest in-directory: **Nezlobin's directional fee** (curriculum, dozens of instances) prices *direction*; **EvenFlow** (UHI8, Uniswap Prize) prices *directional toxicity* and escrows/drips it to in-range LPs. EvenFlow is the closest and the escrow-and-drip pattern is genuinely its idea — I would credit it by name. The difference is the trigger: EvenFlow keys off sustained directional imbalance across time, SWITCHBACK keys off the pool's own price path turning back on itself *within one block*. Different state, different trigger, different attack surface. Not close enough to kill.
- **Off-directory prior art, and it is a real ding:** Umbra Research's "sandwich-resistant AMM" and Sorella's Angstrom enforce an intra-block rule that neutralises sandwiches (execute same-direction swaps at the block-open price). Judges drawn from a16z/Variant/Dragonfly will know it. SWITCHBACK differs by taxing the retracement on a continuous curve and routing it to LPs — defense **plus** recapture where Umbra's is defense only — but "you reinvented Angstrom's intra-block rule with a fee" is a live objection and it caps Originality at 3, not 4. I refuse to score it 4.

### 2.6 Buildability — riskiest assumption and the experiment
**Riskiest assumption:** that the extension-capped retracement fee is JIT-refund-proof (§2.4d) and poison-proof (§2.4c).
**Smallest experiment (≤half a day, first thing):** write the *attack* before the feature. Two Foundry tests: (1) `test_jitRefund_isUnprofitable` — attacker adds liquidity, sandwiches, removes, and we assert their net P&L is negative; (2) `test_dustPoison_authorisesOnlyDustTax` — 1-tick extension, then a large opposite swap, assert the fee charged is bounded by the 1-tick extension. If either fails against the simplest fee curve, redesign before building.
This candidate needs no spikes beyond that: no oracle, no keeper, no async, no randomness, no router changes. That is why it is the fallback.

### 2.7 Scores
| Category | Score | Justification |
|---|---|---|
| Original Idea (30%) | **3** | Zero hits in 662 for the mechanism, but Umbra/Sorella published the adjacent intra-block idea and a well-read judge will say so. |
| Unique Execution (25%) | **4** | Fee as a path integral over the pool's own intra-block tick path, with a next-block donation to defeat JIT refunds, is a construction nobody in the dataset has used. |
| Impact (20%) | **4** | Kills atomic sandwiching and JIT self-sandwiching on any pool with three storage slots and no dependencies — but does nothing for LVR. |
| Functionality (15%) | **5** | No oracle, no keeper, no async, no randomness; the demo is a literal sandwich whose P&L we show going negative. |
| Presentation (10%) | **5** | "The sandwich's second leg pays for the first" plus one price-path diagram is the whole pitch. |
| **Weighted** | **3.95** | |

---

## 3. GREEN LANE — price the flow by the door it came through

### 3.1 Mechanism
**State kept:** a small per-pool table mapping `sender` (the contract that called `PoolManager.swap`) to a lane, plus a rolling per-lane realized-toxicity meter (retracement rate, or realized adverse selection over N blocks).
**Trigger:** every swap, at `beforeSwap`, reading `sender`.
**Settlement path:** flow arriving from a recognised private-orderflow settlement contract (CoW `GPv2Settlement`, a UniswapX reactor, an MEV-Blocker-bound router) is charged a **discounted** LP fee; flow arriving from the open mempool pays a **surcharge**. The surcharge funds the discount and any surplus is donated to in-range LPs. Lanes are repriced automatically from the measured toxicity of the flow that actually arrived through them.

### 3.2 Defense + recapture
- **Defense:** indirect and honest about it — the hook does not itself protect anyone; it *pays traders to route through venues that already do*, and it makes the sandwichable public lane the expensive one.
- **Recapture:** direct — the public-lane surcharge is a toxicity toll to LPs.
This is the weakest defense leg of the five because the protection is outsourced. **Score it down for that.**

### 3.3 v4 mechanics
`beforeSwap` only, dynamic fee override. Nothing else. Trivially compatible with everything. Tiny swaps and illiquid pools are unaffected — it is a fee multiplier. This is the cheapest hook in this document by an order of magnitude.

### 3.4 The attack
**(a) Become a solver.** CoW solvers are permissioned but they are *sophisticated trading firms*, and a solver settling an arbitrage through `GPv2Settlement` collects the retail discount on toxic flow. **Not fatal but structural** — mitigated only by the per-lane toxicity meter repricing the lane after the fact, which means the attack works until the meter catches up. Say so.
**(b) The allowlist is a trust surface and a governance target.** Someone must decide which addresses are "good doors". A wrong or captured entry is a permanent free discount. There is no on-chain way to verify that a contract is a private-orderflow venue. **This is the candidate's real weakness** and it is the thing that will get asked in Q&A.
**(c) Wrapper laundering.** Deploy a thin contract that calls the venue's settlement path to inherit the discount. Mitigated by keying on the settlement contract itself (which enforces its own auth) rather than on any caller in the chain — but must be tested.
**(d) Hardcap-class check.** No thresholds, no exemptions, no first-swap rule — the fee is a per-lane multiplier applied to every swap. Clean on this axis.

### 3.5 Prior art
- `flashbots` → **0**. `cow protocol` → **0**. `mev-blocker` → **0**. `uniswapx` → **0**. `1inch` → 1 (unrelated). Confirmed independently; matches the WINNERS_LANDSCAPE W5 finding and Atrium's own claim.
- Nearest: **Glyph** (UHI8, cited by Atrium as a precedent, *not prized*) reprices known extractors by reputation, up to 33x, paying the premium to LPs. That is address-history-based. GREEN LANE is arrival-venue-based with zero history and zero oracle. Different signal, same payout shape. **Close enough to be uncomfortable but not close enough to kill.**
- Also nearest: **Structured Settlement Hook** (UHI9, no prize) routes "signed, policy-aware settlement capacity" through a normal pool — an allowlisted-settlement idea, though for issuers rather than for MEV.
- Saturated-lane check: touches lane 6 (KYC/permissioned pools, 72 built, off-theme) only superficially — those *gate* access, this *prices* it. Touches lane 1 (dynamic fee, 189 built) mechanically. That mechanical resemblance is the risk: a judge skimming will file it as "another dynamic fee hook".
- Atrium says a genuine integration here is "close to guaranteed differentiation". That is the entire case for this candidate, and it is an argument about *scoring*, not about the mechanism being good.

### 3.6 Buildability
**Riskiest assumption:** that we can demonstrate a real CoW/UniswapX settlement reaching a v4 pool in a Foundry fork test, with the correct `sender` observed by the hook. If we can only mock it, the differentiator evaporates and it becomes a dynamic-fee hook with a hardcoded address list.
**Smallest experiment (≤1 day):** mainnet fork test — replay a real historical CoW `settle()` that touched a Uniswap pool, assert `sender == GPv2Settlement`. If that observation doesn't hold cleanly, kill it.

### 3.7 Scores
| Category | Score | Justification |
|---|---|---|
| Original Idea (30%) | **3** | Zero of 662 integrate a real private-orderflow venue, but "fee tier by caller identity" is mechanically a dynamic fee and Glyph already did the reputation version. |
| Unique Execution (25%) | **4** | A real CoW/UniswapX fork integration is the single rarest thing in this dataset and Atrium says so themselves. |
| Impact (20%) | **4** | If it works it makes private orderflow pay for itself and directly implements official prompt #4. |
| Functionality (15%) | **5** | It is one `beforeSwap` fee override; the only hard part is the fork test. |
| Presentation (10%) | **3** | Hard to make a fee-table pitch feel like a mechanism, and the allowlist question will dominate Q&A. |
| **Weighted** | **3.55** | |

---

## 4. LOCKSTEP — charge composition, not size

### 4.1 Mechanism
**State kept:** essentially none on our side. The state we read is **PoolManager's own transient flash-accounting ledger**, at `keccak256(abi.encode(account, currency))`, readable from outside via `exttload` (`external view`) — CLAUDE.md §5, verified in-repo.
**Trigger:** `beforeSwap` and `beforeAddLiquidity`. If the caller already holds open deltas at the moment they reach us, this operation is a leg of a composed atomic sequence, not a standalone trade.
**Settlement path:** composed operations pay a composition fee scaled by how many currencies the caller has open; the fee goes to in-range LPs. A swap that is atomic with a liquidity add on the same pool by the same caller (JIT) pays the maximum.

### 4.2 Defense + recapture
Recapture is clean. Defense is narrow: it makes atomic multi-leg extraction and JIT-sandwiching expensive, and it makes same-lock self-sandwiching detectable **exactly, with no identity assumption at all** — which is a genuinely nice property that no reputation system can match.

### 4.3 v4 mechanics
`beforeSwap` + `beforeAddLiquidity`, dynamic fee. One `exttload` per currency. No oracle, no keeper, no async. Tiny swaps and illiquid pools are unaffected. The interesting v4-specific detail is that the measurement is taken from **PoolManager's ledger, not from the caller's self-report** — the caller cannot misreport it without actually settling.

### 4.4 The attack — and this is where it falls down
**(a) Order your legs so ours is first.** An arbitrageur controls their own route. Do our pool first, everything else after, and we observe zero open deltas. Costs the attacker nothing. **This is close to fatal on its own.**
**(b) The dominant toxic flow is invisible to this signal.** CEX-DEX arbitrage — the largest single source of LP loss — is a **single one-way leg**. There is no second on-chain leg to compose with. LOCKSTEP is structurally blind to it.
**(c) Multi-hop retail is a false positive.** A retail swap routed A→B→C through Universal Router arrives at our pool with an open delta in B and gets taxed as an arb. Common, and it taxes exactly the users we claim to protect. Fixable only by heuristics that (a) then defeats.
**Verdict: the mechanism is sound and unspoofable; the thesis it is attached to is not.** I am not going to dress this up. As a standalone submission it is a clever primitive with a weak claim.

### 4.5 Prior art
- `transient|exttload|flash.?account` over 662 → 2 matches, neither doing this (HookMind uses EIP-1153 for its own storage; ParaDex uses the unlock-callback path for perps).
- `jit|just.?in.?time` → 21 matches, but every one *provides* JIT liquidity; none *detects* it from the ledger. **sentry** (UHI7) and **ParityTax** (UHI5/6) tax short-lived LP positions by duration, which is the time-based cousin of this.
- Genuinely novel as a primitive. Zero close matches.

### 4.6 Buildability & recommendation
Trivially buildable — we have already proven the `exttload` read in this repo. **But I recommend not submitting it standalone.** Fold it into SWITCHBACK as the exact detector for same-lock self-sandwiching and JIT self-dealing (§2.4d), where its blindness to CEX-DEX arb doesn't matter because SWITCHBACK isn't claiming to catch that either. That is where this idea earns its keep.

### 4.7 Scores
| Category | Score | Justification |
|---|---|---|
| Original Idea (30%) | **4** | Reading PoolManager's transient ledger to price a swap by its atomic composition appears nowhere in 662 rows or anywhere else I know of. |
| Unique Execution (25%) | **4** | Unspoofable measurement taken from the protocol's own accounting rather than from the caller is a distinctive construction. |
| Impact (20%) | **2** | Blind to CEX-DEX arb, evadable by leg ordering, and it taxes multi-hop retail by mistake. |
| Functionality (15%) | **4** | Easy to build and we have already validated the underlying read. |
| Presentation (10%) | **3** | "We can see your other open positions" is a great line followed by an awkward "…unless you reorder your route". |
| **Weighted** | **3.30** | |

---

## 5. LADDER — probabilistic settlement across pre-committed price rungs

### 5.1 Mechanism
**State kept:** per block, N pre-committed price rungs derived from the block-open tick and the pool's realized variance, plus each swap's marginal execution price.
**Trigger:** every swap in a block is provisionally executed, then settled at whichever rung the post-block beacon selects.
**Settlement path:** the difference between the trader's marginal price and the selected rung accrues to in-range LPs (or is refunded to the trader when the rung is in their favour, funded from the same escrow).

This is Atrium's own brainstorm-deck suggestion (p.5), rendered as concretely as I can make it: "settle at one of several pre-committed prices via VRF, so searchers can't precompute the exact fill price."

### 5.2 Defense + recapture
Defense: a sandwicher cannot compute their back-run's fill in advance, so the sandwich becomes a lottery with a known-negative drift once the rung spread is wider than the sandwich margin. Recapture: the rung spread is the toll. Both legs present, honestly.

### 5.3 v4 mechanics
Requires **full async settlement for every swap** — you cannot settle at a rung chosen after the block closes while still inside the block. That means NoOp on everything, ERC-6909 escrow on everything, a crank, and the §1.4g Universal Router incompatibility applied to **100%** of flow rather than to an opt-in lane. It is HASTE's hardest engineering problem with none of HASTE's escape hatch.

### 5.4 The attack
**(a) Variance is a cost to the innocent.** Randomising the *price* is a zero-expected-value transfer that adds variance to every fill. Retail hates variance more than it hates a fee of equal expected cost; this is a worse product for the people it protects.
**(b) The sandwich is still positive-EV.** Sandwich profit is roughly linear in the victim's price impact, which is much larger than the rung spread on any pool where sandwiching is worth doing. Widening the rung spread until it dominates means charging every honest trader that spread. **The mechanism is a fee with extra steps, and the extra steps make it worse.**
**(c) Beacon manipulation.** Same proposer caveat as HASTE, but here it applies to *every swap in the pool* rather than to queue maturity.
**(d) Hardcap-class check.** If rungs are only applied above a size threshold, split the swap. No threshold is possible without breaking (b) further.

### 5.5 Prior art
- `vrf|probabilistic|random` over 662 → 12 matches, all lotteries/raffles/gamification plus AsyncSwapHook and ISP. W1 holds: nobody has built probabilistic *settlement*.
- **But the saturation count is the wrong number to look at.** This idea is printed in Atrium's own brainstorm deck, which every UHI10 team read. Historical white space is not this cohort's white space. I expect several UHI10 teams to submit exactly this, and originality scores are relative to the field the judges actually see. **Score Original Idea down accordingly** — this is the least defensible "0 in 662" in the document.

### 5.6 Buildability
**Riskiest assumption:** that anyone wants a random fill price. **Smallest experiment:** none technical — this is an economics question, and §5.4(b) already answers it. I would not spend a day on it.

### 5.7 Scores
| Category | Score | Justification |
|---|---|---|
| Original Idea (30%) | **2** | It is verbatim the organizers' own published suggestion, which means it is the most-copied idea in this cohort even though it is 0/662 historically. |
| Unique Execution (25%) | **3** | Universal async settlement is a distinctive build, but it is the same construction as HASTE with strictly more risk. |
| Impact (20%) | **2** | Adds variance to honest fills for a defense that arithmetic says is dominated by simply charging the same amount as a fee. |
| Functionality (15%) | **2** | Every swap goes through NoOp escrow and a crank, and nothing routes through Universal Router. |
| Presentation (10%) | **4** | "Your fill price is a dice roll the sandwicher can't precompute" demos beautifully, which is exactly why it is dangerous to trust. |
| **Weighted** | **2.85** | |

---

## 6. THE BET: HASTE

I would bet on **HASTE**, and the reason is narrower than "it scores highest".

The rubric puts 55% on originality plus execution distinctiveness and only 15% on functionality. The organizers published one sentence that reads like a scoring hint — pair defense with recapture — and separately published five open problems, of which #3 ("dynamic fees alone can't distinguish good retail flow from bad toxic flow") is unsolved after 189 attempts. **HASTE is the only candidate here that answers #3 without classifying anyone.** It prices urgency, and urgency is the one attribute where retail and toxic flow genuinely differ and where lying is expensive for the liar. Every other approach in this dataset — reputation, size thresholds, oracle deviation, AI scoring — is a classifier, and every classifier can be gamed by an attacker who is willing to look like the thing it rewards. A separating equilibrium cannot be, because looking like retail *means being late*, and being late destroys the arb. That is a real mechanism-design argument, it is defensible in front of a judge from Variant or Dragonfly, and it survives the "so what stops them pretending?" question that kills most of this field.

The framing I would put on the first slide: **LVR is an option that arbitrageurs currently exercise for free; HASTE sells it, and the queue is what makes not buying it a real choice.**

What could make me wrong, in order: (1) §1.4g — if unmodified router flow can't reach the protected lane, we have built a toll booth with a locked side door, and a judge will notice; (2) §1.4b — if the refund path can't be priced, the queue is adversely selected and we are writing free options against our own LPs; (3) the delay lane's 0-for-6 prize history is a fact, and my read that those failed for lack of a recapture leg is an inference, not evidence.

**Mitigation for all three: run the §1.6 experiments first, in that order, before writing a line of the fee curve.** If experiment 1 fails, switch to SWITCHBACK the same day — it shares no code and no dependency with HASTE, needs no oracle/keeper/randomness/async, and its demo (a real sandwich whose P&L we show going negative) is the single most convincing artifact available anywhere in this document.

---

## 7. KILLED DURING THIS WORK

Two of the four white spaces the brief pointed me at do not survive contact. Both are 0/662 **because they are bad, not because they are unexplored**, and I would rather say so now than let someone build one.

### 7.1 KILLED — W4, LP governance over the MEV mechanism (0 matches in 662)
The idea: LPs vote, per pool, on the MEV mechanism and the revenue split, weighted by liquidity.
**What killed it — three independent things, any one sufficient:**
1. **The vote is flash-loanable.** Liquidity-weighted voting on a pool whose governance controls a revenue stream is a governance-capture target where the prize directly funds the attack: add liquidity, vote, remove, in one lock. Time-weighting converts it from a flash-loan attack into a whale attack, which is not a fix.
2. **It is a platform, not a mechanism.** The brief's own constraint is one hook, one sharp mechanism, understood in eight minutes. "LPs configure the policy" has no mechanism at its centre — it is a parameter surface with a DAO bolted to it, and it scores badly on 30% Original Idea for exactly that reason.
3. **The sharp version is already built.** The only non-platform reading of W4 is per-position policy — each LP posts their own terms and swaps pay accordingly. That is **Intent LP** (UHI8, General Prize): "LPs register on-chain conditions (volume range, time window, slippage tolerance) so swaps violating their intent pay a penalty fee." Per the brief's rule, nearest match is close → kill.

### 7.2 KILLED — W3, searcher bonding and slashing for priority access (0 matches in 662)
The idea: searchers post a bond for fast-lane access; provable misbehaviour slashes the bond to LPs.
**What killed it: Sybil, and it is not patchable.** The only misbehaviour a hook can prove on-chain is the intra-block price path (that is SWITCHBACK's whole insight). To slash a *bond*, you must attribute that path to a bonded *identity*. A sandwicher runs the two legs from two addresses; neither address individually round-trips; no bond is slashable; the fast lane is now a free pass for exactly the actor it was built to deter. Any capital-rich attacker can buy as many identities as the mechanism requires, which inverts the mechanism — the more bonds you demand, the more the mechanism favours the well-capitalised searcher over the retail user.
**The salvageable half is already in SWITCHBACK:** charge the pattern, not the person. Identity-free enforcement is the only kind that survives an adversary with unlimited capital, which is precisely the adversary the brief tells me to assume.

### 7.3 Not killed, but demoted — LOCKSTEP (§4)
Sound, novel, unspoofable, and attached to a thesis that doesn't hold (§4.4). Ship it as a component of SWITCHBACK, not as a submission.

---

## 8. FLAG FOR THE ORCHESTRATOR — a contradiction in our own docs

`docs/research/HACKATHON_CONTEXT.md` §3 records the final submission deadline as **September 3, 2026, 11:59pm PST** (~8 days from today), sourced from the guidelines deck p.4. `CLAUDE.md` §3 states the **deadline was moved +2 months, owner-confirmed**. These cannot both be true, and the choice between HASTE and SWITCHBACK is sensitive to which one is: at 8 days, SWITCHBACK is the only responsible pick in this document; at ~10 weeks, HASTE is comfortably buildable and is the better bet. **Resolve this before committing to a candidate.**

---

# SPIKE 2026-08-26 — router compatibility of HASTE and SWITCHBACK

> Run before committing to a candidate, per the standing rule "validate the riskiest assumption BEFORE building on it".
> Test file: `test/spike/RouterCompatibility.t.sol` (13 tests, all green).
> Vendored dependency: `test/spike/vendor/V4Router_vendored.sol`.
> Command: `forge test --match-path "test/spike/RouterCompatibility.t.sol" -vv`. Full repo suite after the addition: **174 passed, 0 failed**.

## VERDICTS

| Candidate | Verdict |
|---|---|
| **SWITCHBACK** (retracement fee via `afterSwapReturnDelta`) | **ROUTER-CLEAN.** Settles through both routers with slippage protection on. One caveat, measured: the fee lands inside the user's slippage budget. |
| **HASTE, deferred lane, as specified** (NoOp → zero output) | **NEEDS-PERIPHERY. ~14–20 h.** Confirmed FATAL through standard routing with slippage protection on; reachable only with `minOut = 0`, which is not a real escape hatch. |
| **HASTE, deferred lane, inventory-backed variant** | **ROUTER-CLEAN** — and it is a materially different product. See Q4; this is the finding that could change the design. |

## What was actually executed

Two independent router paths, neither written by us:

1. **`UniswapV4Router04`** — the deployed bytecode artifact `hookmate` ships and that this repo's own `Deployers.sol` already uses.
2. **`V4Router`** — the abstract in `v4-periphery/src` that **UniversalRouter inherits** to dispatch its v4 actions, driven through a 20-line concrete subclass shaped exactly like v4-periphery's own `test/mocks/MockV4Router.sol`, and fed a real `SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL` action sequence built with v4-periphery's own `Planner`.

**Why V4Router is vendored, disclosed in full.** `v4-periphery/src/V4Router.sol` pins `pragma solidity 0.8.26` *exactly*; this repo pins solc 0.8.30 because `src/` uses the `transient` keyword (needs ≥0.8.28). The two cannot compile in one project. `test/spike/vendor/V4Router_vendored.sol` is upstream's file with **9 mechanical lines changed and zero lines of logic**: 1 pragma (`0.8.26` → `^0.8.26`) and 8 import paths (`"./x.sol"` → `"@uniswap/v4-periphery/src/x.sol"`, the identical files). Reproduce the diff with the command in that file's header. I considered paraphrasing the router instead and rejected it — a paraphrase would have proved nothing about the real one.

## Q1 — Does it actually revert? YES.

- `test_Q1_v4Router_revertsWithV4TooLittleReceived` — through **V4Router / UniversalRouter's path**, a NoOp'd swap with `amountOutMinimum = 1` reverts with **`IV4Router.V4TooLittleReceived(1, 0)`**, asserted by exact selector *and* exact args. It originates in `V4Router._swapExactInputSingle`, at the line `if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(...)`, where `amountOut` is the reciprocal leg of the `BalanceDelta` the PoolManager returned — which is **0**, because `Hooks.afterSwap` subtracts the hook's `beforeSwapDelta` from the caller's delta before the router ever sees it.
- `test_Q1_hookmateRouter_revertsOnNoOpWithSlippage` — through the deployed **`UniswapV4Router04`** artifact, the same swap reverts with selector **`0x8199f5f3` = `SlippageExceeded()`** (the router's own error, 4 bytes, no args). Captured from live returndata, not read from source.
- `test_Q1_control_vanillaPoolSucceedsThroughV4Router` — the byte-identical action sequence against a **hookless pool on the same harness succeeds**, so the revert is caused by the NoOp and not by the test rig.

**§1.4g in the ideas doc is confirmed by execution. It was a correct guess and it is now a fact.**

## Q2 — Does `amountOutMinimum = 0` rescue it? Yes, and no, it is not a real escape hatch.

`test_Q2_zeroMinOutPasses_userReceivesNothing` (V4Router) and `test_Q2_zeroMinOutPasses_onHookmateRouter` (deployed artifact) both settle cleanly. Measured outcome: the user's `currency0` balance falls by exactly `amountIn`, their `currency1` balance is **unchanged**, and the hook ends holding an ERC-6909 claim on the full input.

So the mechanism works — but the *only* way to reach it through standard routing is to **set slippage protection to zero on a swap you are handing to a hook you have not audited**. That is not a UX compromise, it is the removal of the single check that stands between a router user and an arbitrary-loss hook. No frontend or aggregator will emit it, and none should. **Treat `minOut = 0` as a proof that the accounting works, not as a shipping path.**

## Q3 — What the deferred lane actually requires

`test_Q3_senderIsTheRouterNotTheTrader` proves the second, unbudgeted problem: **`sender` in `beforeSwap` is the router**, asserted `== address(router)` and `!= address(trader)`. A deferred order placed through standard routing has no way to learn whose order it is. `hookData` *is* forwarded verbatim by both routers (asserted: the hook decodes the beneficiary the caller encoded), but `test_Q3_emptyHookDataLeavesNoBeneficiary` shows the default case — empty `hookData` — leaves the hook with nothing, and crediting the router would mean the funds are gone.

**Scope, honestly:** the deferred lane needs its own entry point the user calls directly. Not a router allowance, not a hookData convention.

| Piece | Hours |
|---|---|
| `HasteOrders` periphery: `place()` (pull via Permit2, open lock, drive the NoOp path, record owner) | 4–5 |
| `fill(orderIds[])` crank: burn 6909, swap at maturity price, pay out, filler rent | 4–6 |
| Order struct + maturity draw + irrevocability + `minOut` refund path | 3–4 |
| Tests: place/fill round-trip, adversarial refund (the free-option test from §1.4b), no-exemption cases | 3–5 |
| **Total** | **14–20 h** |

That is real but not fatal at the +2-month deadline; at an 8-day deadline it is most of the budget (see §8 — the deadline contradiction is still unresolved and still gates this choice).

## Q4 — A variant that IS router-clean, and it changes the design

`test_Q4_inventoryBackedFillIsRouterCleanWithRealSlippage` — **PASSES with `minOut` set to 98% of notional, slippage protection fully on.** The hook keeps the curve untouched (`beforeSwapDelta.specified = +amountIn`) but returns a **negative unspecified delta**, paying the trader immediately out of its own ERC-6909 inventory. The router sees a real, nonzero output and is satisfied. `test_Q4_inventoryFillLeavesThePoolPriceUntouched` asserts `slot0.sqrtPriceX96` is **bit-identical before and after**, proving the trade was absorbed entirely by the hook.

Variants I did *not* find a way to make work, and why: paying the output as an ERC-6909 claim does not help (the router's `TAKE`/`TAKE_ALL` calls `poolManager.take`, which moves real ERC20, and the slippage check reads the `BalanceDelta` regardless); a partial fill only passes if `minOut` was quoted for the partial size, which the caller cannot know in advance.

**So there is exactly one router-clean deferral, and its price is that HASTE stops being a queue and becomes a market maker.** The trader is filled instantly at the hook's quote; the timing risk moves from the trader's order onto the hook's balance sheet. That is a *bigger* product, not a smaller one: the hook needs inventory, a quoting rule, and a hedging policy, and it re-opens the free-option problem from §1.4b in a worse form — the hook is now quoting a firm price to anybody, which is precisely what an informed trader picks off. **I would not take this route.** It is recorded because the orchestrator asked whether one exists; it exists, and it is a trap.

## Q5 — SWITCHBACK: router-clean, confirmed, with one measured caveat

- `test_Q5_outputSkimIsRouterCleanWithinTolerance` / `..._onHookmateRouter` — a 5% skim taken via `afterSwapReturnDelta` settles on **both** routers. Asserted: the user is paid, the hook holds the fee as a 6909 claim, and the skim is exactly 5% of gross output (`skimmed == gross * 500 / 10_000` to 1e-4). The fee comes out of the user's output; it is **not** an extra charge on the input.
- `test_Q5_outputSkimRevertsAgainstAPreFeeQuote` — the caveat, and it was worth testing rather than assuming. Quote the swap on a hookless twin pool, then demand that same number from the fee-charging pool: it **reverts**. The router's slippage check sees the **post-fee** output. So a retracement fee is *inside* the user's slippage budget, exactly like a higher LP fee would be.

**Consequence for SWITCHBACK, and it is a design constraint, not a blocker:** the retracement fee must be bounded by something a quoter can anticipate, or swaps quoted before the fee was known will revert on legitimate flow. Two clean answers, both cheap: publish the fee as a view function quoters can call, and cap the retracement fee at a disclosed maximum. Note this cuts *with* the mechanism — a sandwicher's back-run reverting on slippage is a successful defense; an honest trader's swap reverting is a bug. The cap is what separates the two.

## Distrust-green check (standing order §9)

Green on the first run is a reason for suspicion, so both hooks were deliberately mutated and the suite re-run:
- **M1** — `NoOpEscrowHook` stops NoOping (`toBeforeSwapDelta(0,0)`): **8 of 13 tests went red.**
- **M2** — `OutputSkimHook` skims zero: the three Q5 tests went red, including `test_Q5_outputSkimRevertsAgainstAPreFeeQuote` with "next call did not revert as expected".

**The mutation caught a bad test of my own, which is the point of running it.** `test_Q1_hookmateRouter_revertsOnNoOpWithSlippage` originally asserted only `reason.length > 0` and **passed under M1** — because the mutant reverted with `CurrencyNotSettled()`, a completely different failure. It was proving that *something* went wrong, not that slippage rejected the swap. It now asserts the exact selector `0x8199f5f3` and 4-byte length, and re-running M1 against it produces a red with `0x5212cba1 != 0x8199f5f3`. This is the fourth time in this repo that distrusting a green result found something the suite could not.

## Bottom line for the decision

- **SWITCHBACK is ROUTER-CLEAN today.** No periphery, no new entry point, no adoption problem; it works through the routers users already use. Its one constraint (cap and publish the fee) is half a day.
- **HASTE's deferred lane is NEEDS-PERIPHERY at 14–20 h**, plus the §1.4g adoption weakness which is now measured rather than suspected: the protected lane is unreachable from any standard router, so the default path really is the expensive one. Not FATAL — the periphery works and the accounting is proven — but the cost is larger than the ideas doc assumed, and the free-option experiment (§1.4b) has **not** been run yet and is still capable of killing it.
- **The Q4 escape hatch exists and I recommend against it.** It buys router-cleanliness by turning the hook into an inventory-carrying market maker.

**My recommendation after the spike is unchanged in ranking but changed in confidence: if the deadline is genuinely +2 months, HASTE is still the better bet and the next step is the §1.4b free-option experiment. If the deadline is September 3, take SWITCHBACK today** — it is proven router-clean by execution, and the 14–20 h of periphery plus an unrun economics experiment is not a risk worth carrying into an eight-day window.

## UNTESTED — do not treat these as validated

- The **free-option / refund-path economics (§1.4b)**. Not attempted in this spike. Still the single most likely killer of HASTE.
- **Randomness quality** of `blockhash`-derived maturity, and proposer regrinding (§1.4f).
- **Real UniversalRouter** end-to-end. The `V4Router` abstract that UniversalRouter inherits was exercised directly; the `UniversalRouter` contract itself is a separate repo not vendored here and was **not** deployed. The Permit2 → `UNISWAP_V4_SWAP` command wrapper around `V4Router` is unexercised.
- **SWITCHBACK's actual fee curve, the JIT-refund attack (§2.4d), and the dust-poison cap (§2.4c).** This spike tested a flat 5% skim purely as a router-compatibility probe. The `OutputSkimHook` here is a stand-in and proves nothing about SWITCHBACK's economics.
- **Multi-hop routing** (`SWAP_EXACT_IN`, path-based) and **exact-output** swaps against either hook. Single-pool exact-in only.
- **Gas.** Nothing here is a like-for-like measurement and no number from this spike should be quoted (§9).

---

# ECONOMICS 2026-08-26 — HASTE's free-option and separating-premium test

> The experiment I named as HASTE's most likely killer (§1.4b). Model + Monte Carlo:
> `docs/research/data/haste_economics.py` (seeded, reproducible), output frozen at `docs/research/data/haste_economics.out`.
> Every assumption is listed in the script's docstring; the four that matter are restated below.

## VERDICT: **GO-WITH-CAVEATS.** The free option is real but it is not where the objection said it was, and it is fixable on-chain. Two *other* things nearly killed HASTE instead, and one of them is not in the ideas doc.

## The sanity gate, first

Any model of arbitrage that cannot reproduce the textbook LVR rate is worthless. At zero fee the simulated arb profit per block must equal `σ_b²·V/8`:

| Regime | σ_block | theory | simulated | error |
|---|---|---|---|---|
| calm ~40% ann | 2.47 bps | $0.0152/blk | $0.0152/blk | 0.2% |
| normal ~60% ann | 3.70 bps | $0.0342/blk | $0.0342/blk | 0.2% |
| stressed ~120% ann | 7.40 bps | $0.1370/blk | $0.1371/blk | 0.1% |
| long-tail ~300% ann | 18.51 bps | $0.8562/blk | $0.8620/blk | 0.7% |

Independently, the Part-4 Monte Carlo is cross-checked against the closed form `φ(z) − z·Φ(−z)` at every point and agrees to four decimals. **A sign error in that payoff (value rising with moneyness — impossible) was caught by adding that cross-check, not by inspection.** Both gates are in the script and print on every run.

## 1. The crossover, and it is not the one that was expected

Fitted over all four vol regimes and three fee tiers: **the arbitrageur's edge is `0.581 × σ_block` per unit notional** (range 0.576–0.614), and it is **essentially independent of the LP fee** — a higher fee makes arbs trade less often, not less profitably per unit.

Retail's cost of waiting `E[T] = (N+1)/2` blocks is `λ · σ_block · √E[T]`.

Separation needs `λ·σ_b·√E[T] < premium < 0.581·σ_b`. **σ_block cancels from both sides.**

> ### `N_max = 2·(0.581/λ)² − 1`
> **The viability boundary is retail's impatience, not volatility.** This directly contradicts the framing of the question, and it is the most useful thing the model produced.

| λ | N_max (blocks) | on 12s blocks | on Unichain 200ms | |
|---|---|---|---|---|
| 0.05 | 269 | 54 min | 54 s | comfortable |
| 0.10 | 66.6 | 13 min | 13 s | comfortable |
| 0.15 | 29.1 | 5.8 min | 5.8 s | comfortable |
| 0.25 | 9.8 | 2.0 min | 2.0 s | tight |
| 0.35 | 4.5 | 54 s | 0.9 s | **DEAD** |
| 0.50 | 1.7 | 20 s | 0.3 s | **DEAD** |

**The mean-variance parameterisation never binds** — `(γ/2)σ_b²E[T]` is second-order in σ, giving N_max in the thousands of blocks even at γ=50. That is a finding, not a modelling convenience: **at per-block volatility scales, variance aversion cannot be what makes a trader impatient.** Whatever λ represents, it is a behavioural/UX parameter, not a utility curvature — which means **λ is not something we can derive; it must be measured, and we have not measured it.** It is the single biggest unvalidated number in this analysis.

## 2. Does a separating premium exist? **Yes, and comfortably, for λ ≤ 0.15.**

At λ = 0.15 and N = 29 the band is `0.58·σ_b > premium > 0.55·σ_b`… no — concretely, on the normal ~60% regime (σ_b = 3.70 bps): the arb will pay up to **2.14 bps**, and retail at λ=0.15, N=10 charges itself **1.29 bps**. A premium anywhere in **(1.3, 2.1) bps** separates. That is a real band, not a knife edge. At λ=0.35 the band is empty at any N ≥ 5 and HASTE does not work.

**Where the premium actually comes from, and this is uncomfortable.** Part 4b: the arb's per-notional edge is fee-invariant, so **the premium is not paid out of the arbitrageur's pocket — it is paid by widening the no-arb band.** Staleness tracks total friction almost 1:1 (5 bps friction → 3.3 bps divergence; 100 bps → 51 bps). LPs still gain — LVR falls faster than arb revenue rises (normal regime, arb flow only: net +0.0075/blk at 5 bps friction → +0.0298/blk at 100 bps) — but the honest statement is that **the urgent trader's true cost of the immediate lane is premium + staleness ≈ 2× the premium**, and staleness is borne partly by everyone. §1.4d was a correct worry and it is now quantified.

## 3. Is the deferred order an option? **No — not unless we make it one.**

Part 3, 400k paths per cell: for an irrevocable order with no minOut filling at the maturity spot, `E[P_T] − P_0` is **±0.1 bps against standard deviations of 5.8–227 bps** — indistinguishable from zero at every vol and every N. **The payoff is linear in `P_T`. Zero expected gain, zero gamma. It is a forward with random delivery, not an option.**

This kills question #4 (the adversarial delta-neutral placer) directly: **a linear payoff has no gamma, so a delta-neutral placer harvests nothing.** They pay gas and receive exactly the hedge they already had. There is no structural subsidy. The AMM's own concavity makes it slightly *worse* than flat for the placer.

**#4 and #1 are the same problem, and the problem is convexity — which only the refund creates.**

## 4. The refund IS the free option, and it has an enforceable fix

Part 4, in units of `z = tol / (σ_b·√E[T])` — how many standard deviations out of the money the refund trigger sits. One table covers every vol regime because that ratio is the only thing that matters:

| z | free put / arb edge (N=10) | (N=50) | refund fires | verdict |
|---|---|---|---|---|
| 0.00 | **1.61×** | **3.46×** | 49.9% | FATAL — the option is worth more than the entire premium |
| 0.25 | 1.15× | 2.48× | 40.1% | FATAL |
| 0.50 | 0.80× | 1.72× | 30.9% | DANGEROUS |
| 1.00 | 0.34× | 0.72× | 15.9% | DANGEROUS |
| 1.50 | 0.12× | 0.25× | 6.6% | safe |
| 2.00 | 0.03× | 0.07× | 2.3% | safe |

A "fill me only if the price improved" order (z = 0) is worth **1.6–3.5× the arbitrageur's entire edge, for free.** That would be a straddle written by the LPs and it is strictly worse than the LVR it was built to stop — the objection was exactly right about the mechanism, just wrong about which feature causes it.

> **DESIGN RULE (enforceable on-chain, and cheap):** reject any deferred order whose `minOut` sits closer than **≈2 standard deviations of the interim move**, i.e. `tol ≥ 2·σ_b·√E[T]`. The hook already measures `σ_b` for the premium, so this costs one comparison. At z ≥ 2 the free put is worth <7% of the arb edge and fires <3% of the time.

Note what this rule *is*: **a volatility-scaled bound on how tight a deferred order's slippage protection may be** — which is W6 arriving as a derived result rather than a bolt-on feature. The delay window and the tolerance floor are the same parameter seen twice.

## 5. Cranking — and the hole that is not in the ideas doc

§1.4a assumed the attacker must guess the maturity block. **That is wrong if the filler chooses when to crank.** Any keeper who cranks a matured order *knows* the fill block, because it is their own transaction. A searcher-filler can bundle front-run → crank → back-run and sandwich the order they are settling, with certainty, for the price of gas. **The randomised maturity buys nothing against the filler.** This is a genuine hole, it is the closest thing here to Hardcap's shape, and I did not have it before running this pass.

The fix that works, and it is cheap: **fill matured orders at the block's OPENING price, not the instant spot.** Then a filler who front-runs their own crank does not move the fill price and has nothing to unwind against. This requires a block-open reference tick — **which is exactly the state SWITCHBACK already keeps.** The two candidates share machinery; that is worth knowing whichever way the decision goes.

Remaining crank issues, stated not solved: the filler must be paid a rent that exceeds gas, which implies a **minimum viable deferred order size ≈ gas/premium**. Below it, small retail cannot reach the free lane and pays the toll. **HASTE is regressive: it protects large retail and taxes small retail.** That belongs in the pitch, not in a footnote. An un-crankable dust order is a de facto cancellation and restores the option, so the minimum size is a correctness requirement, not a nicety.

## 6. The dominance check (Hardcap shape)

*Is placing ever strictly dominant for everyone?* Under A3 (competitive arb): no. Placing is weakly dominant for **risk-neutral non-urgent** flow — which is the mechanism working, since the premium is only supposed to come from urgent flow. Arbs cannot place because their edge is gone by maturity.

**Under A3 relaxed, it inverts.** Part 5, monopolist arb (arb_prob = 0.05, normal vol): the surviving edge rises from 2.14 bps to **11.66 bps** — the edge does not decay, because nobody is racing for it. A monopolist arb places into the free lane, pays nothing, and still collects. **On a pool with no arb competition HASTE collects nothing and defends nothing.** This is the same shape as Hardcap's first-swap exemption: a state in which the behaviour the mechanism exists to deter becomes the cheapest behaviour available.

**HASTE therefore has a scope condition that must be stated on camera: it works on competitively-arbitraged pairs and degrades to nothing on long-tail pairs with a single searcher.** The organizers' theme is volatile *major* pairs, which is the competitive case — but the mechanism cannot be sold as universal.

## 7. Straight answer

**GO-WITH-CAVEATS**, conditional on three things, in this order:

1. **λ ≤ 0.15.** Unmeasured, behavioural, and the whole mechanism rests on it. Cheapest validation available: measure the observed slippage tolerances and deadline settings on real v4 swaps — a trader who sets a 12-second deadline has revealed λ high; one who sets 30 minutes has revealed λ low. **Do this before writing the fee curve.**
2. **`minOut` floored at 2σ_b√E[T].** One comparison, dissolves the free-option objection.
3. **Fill at the block-open price.** Otherwise the filler sandwiches the order it settles, and the randomised maturity is decoration.

What did **not** kill it: the option objection as posed (payoff is linear — §3), and the delta-neutral placer (no gamma to harvest — §3). What nearly did: the filler-sandwich hole (§5, new) and the monopolist-arb inversion (§6, new). Both are now stated; neither is fatal on the target pair class.

**Ranking is unchanged. Confidence is up on the economics and down on the scope** — HASTE is not a universal MEV hook, it is a mechanism for competitively-arbitraged volatile pairs, and it should be pitched as exactly that. The deadline question (§8) still decides HASTE vs SWITCHBACK, and §5's finding that both need a block-open reference price makes the fallback cheaper than it looked.

## UNTESTED / MODELLED-BUT-NOT-SIMULATED — do not quote as validated

- **λ itself.** Not measured, not simulated, assumed. Everything in §1 and §2 is conditional on it.
- **The separating band under retail flow that moves the price.** A4 assumes retail is a price-taker; a large retail order is not.
- **The filler-sandwich fix.** §5's block-open-price settlement is reasoned, **not simulated and not implemented.** It is the next experiment if HASTE proceeds.
- **Multi-arb strategic behaviour.** Part 5 models arb competition as a Bernoulli arrival rate, not as a game. A real searcher chooses lanes strategically; that is a game-theoretic model I did not build.
- **Concentrated liquidity.** A2 is constant-product. Depth changes the constants; I assert but have not shown that it leaves the ratios intact.
- **Gas.** Not modelled anywhere. The minimum-order-size threshold in §5 is dimensional reasoning, not a measurement.

---

# REFLEXIVITY 2026-08-26 — does SWITCHBACK's fee still separate extraction from honest flow when the block-open reference is stale?

> The experiment named in `CANDIDATE_BRIEF.md` §1 con 6 as "the biggest risk, and it is new".
> Model + Monte Carlo: `docs/research/data/switchback_reflexivity.py` (seeded, reproducible),
> output frozen at `docs/research/data/switchback_reflexivity.out`.
> The LVR sanity gate from `haste_economics.py` is carried over verbatim and **PASSES** in all four
> vol regimes (σ²V/8 reproduced to 0.2–0.4%). Every assumption is in the script docstring.

## VERDICT: **GO-WITH-FIX** — but not for the reason the experiment was commissioned.

**The reflexivity hypothesis is FALSE, and the sign is backwards.** The OZ warning does not transfer.
**Two other things surfaced that are worse than the thing I was sent to test**, one of them fatal to
a headline claim in the brief and one of them a Hardcap-shaped exemption in a fix we had already
committed to. Neither is about staleness.

---

## 1. Why the OZ warning does not transfer — the structural answer, before any number

OpenZeppelin's `AntiSandwichHook` warns that deterring MEV degrades the block-open price. That
warning is about a mechanism that **prices swaps against the block-open state**. SWITCHBACK does not.

> **`T0` is the pool's OWN tick at block open. It is not a price estimate. It cannot be "stale"
> relative to the quantity the fee measures, because it IS that quantity's origin.**

The fee is a pure function of the intra-block tick path relative to `T0`. The market price `S` never
appears. So staleness can only act **through the flow it induces**, and there are exactly two channels:

| | Channel | Simulated result |
|---|---|---|
| **H1** | A stale `T0` means a top-of-block corrective arb, whose extension is **free**, and that free extension authorises taxing later opposite-direction flow. | **REAL, and it is 38% of the honest fee.** |
| **H2** | The arb that corrects *retail's* impact is a retracement, so it is taxed, so it under-corrects, so next block opens stale. | **REAL but converges** — see §3. |

And the corollary that kills the OZ analogy outright:

> **The top-of-block corrective arb is NEVER taxed. `T0` = the pool's price, so the first swap of a
> block moves *away* from `T0` by construction: it is an extension, and extensions pay zero.**
> SWITCHBACK cannot deter the arbitrage that anchors the reference, because that arbitrage is
> structurally exempt. OZ's hook can, because it caps the arb's fill at the block-open price.

**Confirmed by simulation, and the direction is the opposite of the fear.** Suppressing arbitrage
(normal vol, γ=1) *reduces* the honest false positive, because there is less free extension budget:

| arbs suppressed | block-open staleness | honest swaps charged | honest bps | sandwich escape |
|---|---|---|---|---|
| 0% | 11.6 ticks | 44.6% | 3.79 | 24.6% |
| 50% | 16.6 | 39.8% | 3.53 | 27.3% |
| 80% | 27.9 | 36.5% | 3.00 | 27.6% |
| 95% | 56.0 | 34.5% | 2.62 | 27.8% |

**More staleness, less tax on honest flow, essentially unchanged separation.** A 13× increase in
staleness moves the confusion matrix by less than a third, in the *helpful* direction.

---

## 2. The cheap answer (item 4 of the brief): the intra-block cap does bound the reference problem, but it is a TAUTOLOGY, not a mechanism

Two mutation results settle this, and one of them is a build finding.

- **M3 — the §2.4c dust-poison test, executed rather than reasoned.** A 0.25-tick poison followed by
  a $200k opposite swap that moves **199 ticks**: charged for **0.250 ticks ($4.95)**. The cap holds
  exactly. §2.4c is correct.
- **M2′ — but the per-side "extension budget" is an IDENTITY, not a constraint.** Replacing the whole
  watermark/budget machinery with the closed form
  ```
  d0 = tickBefore - T0 ;  d1 = tickAfter - T0
  charged = (d0*d1 >= 0) ? max(0, |d0| - |d1|) : |d0|
  ```
  reproduces **every number in this document bit-for-bit** (staleness 11.56t, honest 3.79 bps,
  escape 24.6%, all identical). The unspent up-side budget is always exactly `tick − T0`, because
  every up-move credits it and every down-move above `T0` debits it.

> **BUILD CONSEQUENCE: §2.1's intra-block high/low watermarks are DEAD WEIGHT. The mechanism needs
> ONE storage slot (`T0`), not three. And "the fee is capped by how far price was extended" — called
> in §2.4c "the load-bearing invariant of the whole design" — is a tautology: it is just what
> "distance walked back toward `T0`" means. It is not a separate defence and must not be pitched as one.**

**M2 (direction-blind control)** — charging every tick moved regardless of direction blows honest cost
from 3.79 to **21.48 bps** and charges **100%** of honest swaps. The extension/retracement direction
logic is what produces the separation, and it is load-bearing. The rig is not inert.

---

## 3. Does the loop converge, diverge, or tax everything? — **CONVERGES, and fast.**

Staleness, first decile vs last decile of a 4,000-block run (normal vol):

| γ | staleness 1st 10% | last 10% | ratio | arb correction shortfall | honest bps |
|---|---|---|---|---|---|
| 0 | 4.29 t | 4.30 t | 1.001 | 0.0% | 0.00 |
| 0.5 | 9.76 | 9.89 | 1.014 | 19.6% | 1.71 |
| 1 | 11.65 | 11.84 | 1.017 | 26.3% | 3.79 |
| 2 | 12.82 | 13.01 | 1.015 | 30.7% | 8.04 |
| 8 | 14.36 | 14.59 | 1.015 | 36.3% | 33.84 |

No divergence at any γ. Staleness **saturates at ~14 ticks even at γ=8** — a 16× fee slope buys only
a 3.3× increase in staleness — because the correction is merely *deferred to the top of the next
block, where it is free*. The corrective arb is **never killed outright (0.0% at every γ)**; it
under-corrects by 26–36%. This is a graded, self-limiting, bounded effect, not a runaway.

**And the staleness costs LPs almost nothing.** With sandwiches switched off entirely — so no
sandwich fee revenue to lose and no extraction to prevent, leaving staleness as the *only* moving
part — pool-vs-HODL per block goes **15.80 → 15.58 (−1.4%)** as γ goes 0 → 2 while staleness goes
4.3 → 12.4 ticks. **The OZ warning is quantitatively immaterial for LPs on this mechanism.**

⚠ **Do not read that as "LPs win".** In the same sandwich-free world at γ=1, SWITCHBACK collects
$13.07/block of which **$8.75 (67%) is billed to honest traders**. Most of the LP gain in a
low-extraction pool is a transfer from ordinary traders, not recaptured MEV. Say that on camera.

---

## 4. THE CONFUSION MATRIX

Calibration: $40M constant-product pool, 5 bps LP fee, 3 retail swaps/block, median retail notional
$5,000 ⇒ **median retail tick impact 5.0 ticks**, vs σ_block 2.5 / 3.7 / 7.4 / 18.5 ticks.
"honest bps" is volume-weighted, **on top of** the 5 bps pool fee. "sw escape" is the share of
*baseline-profitable* in-block sandwiches still profitable; "keeps" is the share of untaxed gross retained.

| γ | honest swaps charged | honest bps (Δ vs 5bps fee) | sandwich escape | sandwich keeps | staleness |
|---|---|---|---|---|---|
| 0.25 | 42.3% | 0.77 (+15%) | **81.4%** | 8.4% | 7.8 t |
| 0.50 | 43.8% | 1.71 (+34%) | 61.0% | 3.9% | 9.7 t |
| **1.00** | **44.6%** | **3.79 (+76%)** | **24.6%** | **1.6%** | 11.6 t |
| 2.00 | 44.9% | 8.04 (+161%) | 0.0% | 0.0% | 12.7 t |

Volatility regime is nearly irrelevant (calm→longtail moves honest bps 3.77→4.45 at γ=1) — the
no-arb band is set by the *fee*, not by σ, which is the same result `haste_economics.py` Part 4b found.

**Flow density is what actually moves the matrix**, and it moves it a lot:

| retail swaps/block | honest charged | honest bps | of which caused by the arb's extension | sandwich escape |
|---|---|---|---|---|
| 0.3 | 21.7% | 0.88 | 44% | 29.3% |
| 1.0 | 34.6% | 2.05 | 49% | 28.6% |
| 3.0 | 44.6% | 3.79 | 38% | 24.6% |
| 6.0 | 48.5% | 5.23 | 30% | 26.7% |

**Decomposition — how much of the false positive is the stale reference at all?** The LIFO
attribution says **38.0%** of the honest fee consumes extension created by the corrective arb (the
reference channel) and **62%** is intrinsic — ordinary two-sided honest flow inside one block, which
is §2.4f and has nothing to do with staleness. Control NC2 confirms the second number independently:
with a *perfect* reference and strictly alternating honest flow, 51.2% of swaps pay 2.36 bps, i.e.
62% of 3.79.

> ⚠ **CORRECTION, 2026-08-26 (later the same day), found by my own follow-up run.** An earlier draft
> of this paragraph quoted an oracle-reference counterfactual at 2.13 bps and concluded a perfect
> reference would *help*. **That row was defective**: it moved `T0` to the true market tick but left
> the extension budget empty at block open, so the standing displacement was not chargeable. With the
> budget seeded consistently the same row reads **4.39 bps, escape 21.3%, arb shortfall 67.5%** — a
> market-anchored reference is **worse**, because "retracement toward `T0`" then means "moving toward
> the market price", which is what price discovery *is*. The 38/62 split above is the number that
> stands. **Fourth defective result caught by distrusting a green run in this repo, and the first one
> that was mine.**

> ### 4.1 A HEADLINE CLAIM IN THE BRIEF IS FALSE AND MUST BE RETRACTED
> `CANDIDATE_BRIEF.md` §1: *"**Ordinary traders** — Unaffected. A one-way trade pays nothing extra.
> This is the key selling point: **the honest path is free**."* and *"an honest trader is untouched"*.
>
> **Not true.** Because a corrective arb extends the price at the top of nearly every block, roughly
> **half of all one-way honest flow arrives in the retracing direction and is charged.** At γ=1 that
> is 44.6% of honest swaps paying a mean 3.79 bps — a **76% increase in their all-in trading cost**.
> The honest path is free only for a one-way trade that happens to move price *further* in the
> direction the block already went. That is a coin flip, not a property.
>
> This is not fatal — the money goes to LPs, so it is a transfer, and the brief already discloses a
> weaker version of it at §2.4f — but the *selling point* is gone and the pitch must be rewritten.
> Do not put "the honest path is free" on a slide.

---

## 5. THE THING THAT IS ACTUALLY DANGEROUS: **the reset is the exemption** (found, not hypothesised)

Following §1's own logic: if the first swap of a block can never be a retracement, then **every
top-of-block swap is fee-exempt by construction.** That is the *same shape* as Hardcap's first-swap
exemption — a state in which the behaviour the mechanism exists to deter becomes the cheapest
behaviour available. Hardcap died of exactly this.

**The strategy:** front-run + victim in block N (the front-run is an extension — free), then unwind
at the **top of block N+1**, where `T0` has re-set to the displaced price so the unwind is an
extension too — free. Total SWITCHBACK fee: **asserted 0.00 across every trial in the run.**

| | in-block sandwich (γ=1) | cross-block unwind |
|---|---|---|
| still profitable | 27.9% of attackable victims | **82.6%** |
| keeps, of untaxed gross | **1.7%** | **90.6%** |

(30 bps pool: in-block 0.0% / keeps 0.0%; cross-block 95.7% / keeps 95.7%.)

The attacker's only remaining cost is winning the first slot of block N+1. **Break-even win
probability q\* = 1.9%** (5 bps pool) and **0.0–0.3%** (30 bps pool). Winning ~1 in 50 races makes the
cross-block route strictly better than paying SWITCHBACK.

> **This refutes §2.4a's mitigation argument, which is the load-bearing sentence of that section:**
> *"holding inventory across a block turns a risk-free atomic sandwich into a directional position
> exposed to ~12s of price risk."* **It is not 12 seconds of exposure — it is one block boundary,
> and only if the searcher loses a race they are already running.** On Unichain, the target chain,
> that boundary is **200 ms**. The mitigation is backwards on the chain we are aiming at.

**Honest counter-argument, stated because it is real and I did not model it:** the first slot of
block N+1 is contested by the top-of-block arb, whose willingness to pay for it is roughly the same
displacement value. In a competitive priority-fee auction the attacker's surplus is partly bid away
— **to the sequencer, not to the LPs.** So the true statement is not "the attacker gets everything";
it is **"SWITCHBACK collects nothing on this route and the value goes to the block producer."**
Sizing that auction is **MODELLED-BUT-NOT-SIMULATED** and is the next experiment if SWITCHBACK proceeds.

This is a category limit of every block-scoped defence (OZ's and Angstrom's mainnet batch included),
not a SWITCHBACK-specific defect. But it caps Impact honestly at **atomic in-block round trips only**,
and §2.7 scores Impact 4 on the strength of the refuted mitigation. **Impact should be 2–3.**

---

## 6. FIXES, each with the Hardcap-shape check

### FIX A — a published fee cap. **HARDCAP-SHAPED. DO NOT SHIP IT.**

`SPIKE Q5` concluded we need *"a published cap plus a quote view — half a day"*, because the fee sits
inside the router's slippage budget. **The cap is the exemption.** A ceiling on the fee is a ceiling
on the *attacker's* cost; once it binds every further retraced tick is free, so the optimal sandwich
grows until the cap binds:

| cap | honest bps | sandwich escape | **sandwich keeps of gross** |
|---|---|---|---|
| none | 3.79 | 24.6% | **1.6%** |
| 20 bps | 3.44 | 24.0% | **43.0%** |
| 10 bps | 2.60 | 28.5% | **61.3%** |
| 5 bps | 1.65 | 49.2% | **76.4%** |
| 2 bps | 0.75 | 74.8% | **89.1%** |

A 20 bps cap costs honest flow almost nothing (3.79 → 3.44) and hands the attacker **27× more
profit** (1.6% → 43.0%). That is Hardcap's economic inversion exactly: the carve-out is invisible in
the aggregate and enormous for the party it exempts. **A cap exempts the large sandwiches — which is
where all the money is.**

**Correction to SPIKE Q5:** of its two recommendations, **only the quote view is safe.** But note the
residual, and it is unsolved: the fee depends on the intra-block path at execution time, which no
off-chain quoter can know. The only *a-priori* bound that is not steerable is **γ ≤ 1**, whose
economic meaning is "a retracing swap can never obtain a better price than the block-open price" —
a bound a quoter *can* express. **And that is OpenZeppelin's `AntiSandwichHook` rule.** See §7.

### FIX B — a deadband (first D ticks of extension per block create no budget). **Not Hardcap-shaped, but not a fix either.**

| D | honest charged | honest bps | sandwich escape | sandwich keeps |
|---|---|---|---|---|
| 0 | 44.6% | 3.79 | 24.6% | 1.6% |
| 5 | 31.3% | 2.67 | 28.2% | 1.7% |
| 10 | 21.8% | 1.88 | 32.4% | 1.8% |
| 20 | 10.9% | 0.91 | 73.3% | 2.2% |

**The Hardcap check passes, and the reason is worth keeping:** a deadband exempts *small* extensions,
i.e. the **cheap** attacks, and "keeps of gross" stays at 1.6–2.2% throughout. A cap exempts *large*
retracements, i.e. the **expensive** attacks. **Exempt the tail that isn't worth anything, never the
tail that is.** That is the generalisable form of the Hardcap lesson and it should be written into
CLAUDE.md §9.
But it is not a fix: D just re-parameterises the same ROC curve that γ already traverses. D=10
(1.88 bps honest, 32.4% escape) is roughly γ=0.5 (1.71 bps, 61% escape) — modestly better, not
different in kind. **Worth taking; do not sell it as a solution.**

### FIX C — "charge only when extension and retracement fall in the same block". **Already the design.** `T0` and the budget reset every block; the fee contains no cross-block state at all. Nothing to change — and §5 is the price we pay for it.

### FIX D — EMA/TWAP reference. **Argued dead, NOT SIMULATED.** An EMA is by construction *more* lagged than the pool's own current price, so it makes the reference staler, not fresher; and it introduces cross-block state, which reopens §2.4c poisoning at a horizon the extension identity no longer bounds. Since §1–§3 show reference staleness was never the problem, this fix targets a non-issue at real cost.

---

## 7. A NEW ORIGINALITY PROBLEM, surfaced by §6

§2.5 already caps Originality at 3 because Umbra/Sorella published the adjacent intra-block idea.
The economics make that worse, not better: **the fee slope that actually works is γ ≈ 0.5–1, and at
γ=1 the retracing swap's effective price is exactly the block-open price — which is OpenZeppelin's
shipped `AntiSandwichHook` rule.** At γ=1 SWITCHBACK is OZ's rule, two-sided, with the surplus
escrowed to LPs instead of left in the pool. That is a real difference but a narrow one, and it
collides with the owner's criterion 5 delete test ("anything a developer already gets free from OZ
today is not a submission"). **The defensible ground is γ<1 — a *continuous* price on the round trip
rather than a hard floor — and at γ=0.5 that costs honest flow 1.71 bps and leaves sandwiches
holding 3.9% of gross, which is still economically dead.** Pitch γ=0.5, not γ=1, and be ready for
"why is this not the OZ hook with extra steps".

---

## 8. STRAIGHT ANSWER

**GO-WITH-FIX**, with the fixes being mostly *retractions*, and with one named condition that is
capable of turning this DEAD on a measurement we have not made.

**The question I was sent to answer is answered and it is good news: reflexivity is not a problem.**
The loop converges (ratio 1.00–1.02 at every γ), the staleness saturates at ~14 ticks, it costs LPs
1.4%, and more staleness makes the confusion matrix *better*, not worse. `CANDIDATE_BRIEF.md` §1
con 6 — *"the biggest risk, and it is new"* — can be closed.

**What must change before this is pitched:**
1. **Retract "the honest path is free" / "ordinary traders unaffected."** 44.6% of honest swaps pay,
   +76% on their trading cost at γ=1, +34% at γ=0.5. (§4.1)
2. **Do not ship a published fee cap.** It is Hardcap-shaped and hands large sandwiches 43–89% of
   their gross back. Ship the quote view alone and accept γ ≤ 1 as the only safe a-priori bound. (§6A)
3. **Retract §2.4a's "~12s of price risk" mitigation.** The cross-block unwind keeps 90.6% of gross
   and needs to win 1 first-slot race in 50. Re-score Impact from 4 to 2–3. (§5)
4. **Delete the watermarks.** One storage slot; the "extension cap" is a tautology, not a defence. (§2)
5. **Target γ ≈ 0.5**, not 1, or the mechanism is OZ's shipped hook restated. (§7)

**THE CONDITION.** §5 is the one that can still kill this, and it is not resolved by anything here:
if the top-of-block slot at N+1 turns out to be cheap on Unichain's 200 ms boundary, SWITCHBACK
defends only the atomic sandwich, which the Gogol et al. research the brief already cites says is
rare on private-mempool rollups. **Measure the cost of a top-of-block slot on Unichain before
committing four weeks.** That is a day of work and it is now ahead of the fee curve, ahead of the
JIT-refund fix, and ahead of the dust-poison test (which §2 has already settled).

## UNTESTED / MODELLED-BUT-NOT-SIMULATED — do not quote as validated

- **The price of the first slot of block N+1.** §5's q\* assumes losing the race yields the attacker
  zero; in reality they retain a residual, so the true q\* is *lower*, not higher. The auction cost
  itself is unmodelled and is the single number that decides §5.
- **Unichain's 200 ms block boundary.** Asserted from the chain's parameters; nothing here was run
  against Unichain data.
- **Concentrated liquidity.** A2 is constant-product, inherited from `haste_economics.py`. Depth
  changes the constants; the ratios are asserted, not shown.
- **Flow calibration.** 3 retail swaps/block at a 5-tick median impact is a stipulation, not a
  measurement. §4's flow-density table is the sensitivity; the FP rate ranges 21.7%–48.5% across it.
  **This is the most load-bearing unmeasured input in the document.**
- **The JIT-refund attack (§2.4d)** and the next-block donation that is supposed to defeat it. Not
  touched here — the fee's *destination* is not modelled at all, only its size.
- **Gas.** Not modelled. The one-slot finding in §2 is a state-count argument, not a measurement.

---

# REFERENCE-CARRY 2026-08-26 — can `T0` cross a block boundary without a new exemption?

> Follow-on to REFLEXIVITY §5 (the cross-block unwind). Same script, same seed:
> `docs/research/data/switchback_reflexivity.py`, PARTS 10–14. LVR gate still PASSES.
> **NEGATIVE CONTROL: α=1, reset_every=1 reproduces every number in the REFLEXIVITY section
> bit-for-bit — asserted in-script, and the run halts if it does not.**

## VERDICT: **FIXABLE.** One EMA parameter closes the cross-block route for ~nothing. The multi-block-window variant is dead.

---

## 1. The mechanism of the fix, before the numbers

The hole exists because `T0` re-sets to the pool's **own displaced tick**, so the unwind leg at the
top of block N+1 starts *at* `T0` and every move from there is an extension. Replace the reset with

```
T0_new = T0_old + α · (tick_at_block_open − T0_old)
```

and the unwind at N+1 starts a distance `(1−α)·displacement` **above** `T0`, so walking it back is a
retracement and is charged. α=1 is the shipped hook. The extension budget is seeded at block open
with the standing displacement `|tick − T0|`, which is what keeps the M2′ identity (§2 of REFLEXIVITY)
true under a carried reference — and which is exactly 0 at α=1, hence the exact control.

**It is still one storage slot.**

---

## 2. THE ANSWER: α ≈ 0.5 (per 12s half-life) closes it, and costs essentially nothing

γ=1, normal vol, 5 bps pool, 3 retail swaps/block. "IN" = in-block sandwich, "XB" = the cross-block
unwind, with the front-run **re-optimised for the route the attacker intends to run** (an earlier
draft sized it for the in-block route and understated XB by 17×).

| policy | ref lag | honest charged | honest bps | arb shortfall | IN keeps | **XB keeps** |
|---|---|---|---|---|---|---|
| **α=1.00 (shipped)** | 0.00 t | 44.6% | **3.79** | 26.3% | 1.6% | **87.3%** |
| α=0.75 | 3.80 t | 49.4% | 3.50 | 40.7% | 1.6% | 3.2% |
| **α=0.50** | 7.34 t | 49.0% | **3.63** | 48.5% | 1.6% | **1.6%** |
| α=0.25 | 11.41 t | 49.2% | 4.14 | 53.7% | 1.6% | 1.6% |
| α=0.10 | 15.20 t | 49.2% | 4.64 | 56.8% | 1.3% | 1.3% |
| α=0.00 (fixed anchor) | 129.66 t | 49.7% | **10.05** | 46.8% | 1.8% | 1.8% |

> **At α ≤ 0.5 the XB column equals the IN column exactly. The cross-block route confers zero
> advantage — it is not merely taxed, it is made pointless.** And it costs honest flow **nothing**:
> 3.63 bps at α=0.5 versus 3.79 at α=1. Slightly *cheaper*, because the carried reference sits closer
> to where price actually is than a reference the top-of-block arb has just walked away from.

α=0 (a fixed anchor, i.e. "never reset") is not the answer: 10.05 bps and a 130-tick lag.
**The parameter has an interior optimum, which is the useful finding — "carry it further" is wrong.**

### 2.1 Block time is not a free parameter — and the tick numbers survive it

The EMA decays per **block**. On Unichain's 200 ms blocks, α=0.5 is a 200 ms half-life, i.e. 60×
weaker in wall-clock terms. **α must be specified as a wall-clock half-life.** For a 12s half-life:
**α = 0.5000 on Ethereum, α = 0.0115 on Unichain.**

The steady-state lag is *invariant* to block time under that rule, so every tick figure above carries
over unchanged: `lag_sd ≈ σ_block/√(2α)`, with `σ_block ∝ 1/√B` and `α ∝ 1/B`, so `lag_sd ∝ constant`.
**This is analytic, not simulated** — the rig runs 12s blocks throughout.

---

## 3. WHAT NEW EXEMPTION DOES IT CREATE? — four checked, none fatal, one real residual

### 3.1 Trend taxation — **REAL, but BOUNDED, and the fear does not materialise**

A lagging reference means the pool sits persistently on one side of `T0` in a trend, so counter-trend
honest flow is charged against the standing lag.

| drift | α=1 | α=0.5 | α=0.25 | α=0.10 | α=0 |
|---|---|---|---|---|---|
| 0 t/blk | 3.79 b | 3.63 | 4.14 | 4.64 | 10.05 |
| 2 t/blk | 3.16 | 3.24 | 3.90 | 5.51 | 9.65 |
| 5 t/blk | 2.57 | **3.16** | 4.50 | 6.52 | 7.40 |

**At α=0.5, a 5 tick/block trend costs honest flow +0.6 bps over the shipped hook.** The brief's
worry — "a fix that closes a 1.9% attack by taxing trend-following retail 40 bps is not a fix" — does
not happen, and the reason is structural, not lucky:

> **The charge on any swap is `min(its own tick impact, the standing displacement)`** — that is the
> same M2′ identity. A swap can only be charged for distance it actually walks. With a 5-tick median
> retail impact, retail can never pay more than ~5 bps at γ=1 **no matter how stale `T0` is**. The
> lag column reaching 10,120 ticks at α=0 and honest cost still only 7.40 bps is that cap being
> visible. **Reference staleness cannot produce an unbounded bill. This should have been obvious from
> §2 of REFLEXIVITY and was not — it is the strongest single property the mechanism has.**

The exposed party is not retail but **large** swaps, whose own impact is big enough that the lag never
binds. Volume-weighted numbers above already include that tail.

### 3.2 Reference steering (the §2.4c dust-poison aimed at `T0`) — **~5× underwater at α=0.5**

Biasing `T0` by Δ ticks requires holding the tick `Δ/α` away when the reference is sampled, then
unwinding — and under α<1 that unwind is itself charged. Measured cost of a **+5 tick** bias:

| α | push required | LP fees | SWITCHBACK on the unwind | total |
|---|---|---|---|---|
| 1.00 | 5 t | $5 | $0 | **$5** |
| 0.50 | 10 t | $10 | $5 | **$15** |
| 0.25 | 20 t | $20 | $30 | **$50** |
| 0.10 | 50 t | $50 | $225 | **$275** |
| 0.02 | 250 t | $248 | $6,159 | **$6,407** |

Against that, measured from the α-sweep: `d(honest bps)/d(ref lag) = 0.125 bps/tick`, honest notional
$24,731/block, so a 1-tick bias earns **$0.31/block**; a 5-tick bias decaying at α=0.5 is ~10
tick-blocks ⇒ **$3.09 total**, versus a $15 cost, and the steerer receives only their **LP share** of
even that. **≈5× underwater.** REASONED FROM MEASURED OUTPUTS, NOT SIMULATED — no steering agent was
run, and this rig does not model the fee's destination (§2.4d) anywhere.

Note the cost scales as 1/α, so **steering resistance and cross-block closure both want small α while
trend cost wants large α.** α=0.5 is comfortably inside all three.

### 3.3 "Just wait" — **THE REAL RESIDUAL, and it is §2.4a made true**

Under an EMA the reference catches up geometrically, so holding k blocks leaves only `(1−α)^k` of the
charge. Share of untaxed gross retained (**attacker-favourable upper bound: this probe assumes nobody
trades during the wait, so the displacement is still standing when they unwind**):

| α | k=1 | k=2 | k=3 | k=5 | k=10 | in-block |
|---|---|---|---|---|---|---|
| 1.00 | 90.7% | 91.7% | 92.4% | 87.8% | 91.4% | 1.9% |
| 0.75 | 3.2% | 25.7% | 73.4% | 88.7% | 84.3% | 1.3% |
| **0.50** | **1.5%** | **5.4%** | **9.8%** | 52.9% | 91.2% | 1.8% |
| 0.25 | 1.7% | 1.4% | 1.5% | 3.2% | 28.6% | 1.7% |

At α=0.5 the attacker needs to hold **~3–5 half-lives (~36–60 s of wall clock)** before the route pays.
And they cannot: **the top-of-block corrective arb at N+1 takes the displacement they are sitting on.**

> **This is exactly §2.4a's mitigation — "holding inventory across a block turns a risk-free atomic
> sandwich into a directional position" — which REFLEXIVITY §5 refuted at α=1 because the wait was one
> 200 ms block boundary. At α=0.5 with a wall-clock half-life the wait is ~30–60 seconds and is
> contested by every arb bot on the pair. The fix does not eliminate the route; it restores the
> economic argument the doc had already claimed and could not previously support.** Say it that way.

### 3.4 Impaired price correction — **a cost, not an exemption: 7.2% of LP P&L**

α<1 means the corrective arb is more often a retracement, so it is taxed and under-corrects: shortfall
27.2% → 48.5%. Isolated with sandwiches switched off entirely (so there is no extraction to prevent
and no sandwich fee revenue to lose), pool-vs-HODL per block:

| α | ref lag | arb shortfall | pool vs HODL | SWITCHBACK rev | LP total |
|---|---|---|---|---|---|
| 1.00 | 0.00 t | 27.2% | **15.59** | 13.07 | 28.65 |
| 0.75 | 3.67 t | 41.3% | 14.91 | 16.19 | 31.10 |
| **0.50** | 7.05 t | 48.5% | **14.47 (−7.2%)** | 17.36 | 31.82 |
| 0.25 | 10.91 t | 54.5% | 14.20 (−8.9%) | 19.04 | 33.24 |

**−7.2% of LP P&L is the price of the fix**, and it is a genuine cost, not a transfer we can wave at.
It is more than the 1.4% that block-reset staleness cost (REFLEXIVITY §3) and it must be disclosed.
It is not an *exemption* — no attacker can steer into it.

---

## 4. VARIANT 2 — the multi-block extension budget: **DEAD, and strictly dominated**

Carrying unspent extension for N blocks is the *same object* as holding `T0` for N blocks (M2′ proved
the budget **is** the displacement from `T0`), so it was tested as "reset every N blocks".

| N | honest bps | **XB keeps at a boundary** | × 1/N frequency | in-block keeps | better route |
|---|---|---|---|---|---|
| 1 | 3.79 | 87.3% | 87.3% | 1.6% | CROSS-BLOCK |
| 2 | 4.43 | 82.0% | 41.0% | 1.4% | CROSS-BLOCK |
| 5 | 5.25 | 81.0% | 16.2% | 1.5% | CROSS-BLOCK |
| 10 | 5.55 | 78.1% | 7.8% | 1.4% | CROSS-BLOCK |
| 30 | 6.16 | 69.6% | 2.3% | 1.0% | CROSS-BLOCK |
| 60 | 6.82 | 69.3% | 1.15% | 1.1% | CROSS-BLOCK |

> **A window never closes the route; it only rations it — and it hands the attacker a *scheduled*
> exemption.** `block.number % N` is public, so the reset boundary is not raced, it is diarised: the
> attacker picks a victim in the last block of a window and unwinds at the first block of the next,
> keeping 69–87% of gross every time. The cross-block route stays strictly better than the in-block
> route out to **N ≈ 60 blocks (12 minutes)** — by which point honest flow is paying 6.82 bps (+80%).
>
> **This is the Hardcap shape in its purest form yet: a periodic, publicly-scheduled amnesty.** It is
> worse than the α=1 hole it was meant to fix, because it is *predictable*. Kill it and do not revisit it.

---

## 5. Option 4 — is "atomic in-block only" a product? **No, and the reason is a logic error in the question**

We do not need this answer any more, but it was asked and it generalises.

**The historical atomic share is the wrong number.** A defence whose bypass costs ~nothing does not
get bypassed by *some* extraction — it gets bypassed by *all* of it, because the searchers running
this are already running priority-fee auctions. At α=1 the bypass break-even was **q\*=1.9%**
(REFLEXIVITY §5). So whatever fraction of extraction is atomic *today* is an **upper bound that decays
toward zero on adoption**. Measuring it would tell us what we prevented in the first week, not the
tenth. **A mechanism that redistributes rather than eliminates the attack has to be priced on the
post-adoption equilibrium, and that equilibrium is "everybody uses the free lane".**

The one thing that could rescue option 4 is the unmeasured top-of-block auction cost (REFLEXIVITY §5's
open item). **That is still unmeasured, and the fix in §2 makes it moot — which is the better outcome,
because it removes a load-bearing dependency on a number nobody on this team has.**

Corroborating, from evidence the brief already holds: Gogol et al. (Jan 2026) find sandwiches rare and
>95% of sandwich-shaped patterns false positives on private-mempool rollups; §2.2 already concedes
CEX-DEX/LVR is one-way and untouchable. **The atomic-only slice was thin before the migration argument
and negligible after it.** Do not pitch it.

---

## 6. STRAIGHT ANSWER

**FIXABLE.** Ship the EMA reference at **a 12-second half-life** (α=0.5 on 12s blocks, **α=0.0115 on
Unichain — the parameter must be wall-clock, not per-block**).

| | shipped (α=1) | fixed (α=0.5) |
|---|---|---|
| cross-block unwind keeps | **87.3%** | **1.6%** (= in-block; no advantage at all) |
| in-block sandwich keeps | 1.6% | 1.6% |
| honest flow | 44.6% charged, 3.79 bps | 49.0% charged, **3.63 bps** |
| honest flow, 5 t/blk trend | 2.57 bps | 3.16 bps |
| LP P&L (staleness only) | baseline | **−7.2%** |
| reference steering | $5 per +5 t | $15, ≈5× underwater |
| escape by waiting | 1 block boundary (200 ms on Unichain) | ~3–5 half-lives, contested by the arb |

**What this changes in the pitch:** REFLEXIVITY §5's demand to *"measure the cost of a top-of-block
slot on Unichain before committing four weeks"* is **withdrawn** — the fix removes the dependency.
§2.4a's inventory-risk mitigation can be reinstated, but **only with the EMA and only stated in
wall-clock**. Impact can go back up from 2–3 toward 3–4.

**What does NOT change:** every retraction in REFLEXIVITY §8 stands. "The honest path is free" is
still false (it is *more* false at α=0.5: 49.0% of honest swaps charged). The published fee cap is
still Hardcap-shaped. The watermarks are still dead weight. γ≈0.5 is still the right slope, and the
OZ-convergence problem at γ=1 (§7) is untouched by any of this.

**One new cost to disclose on camera:** the fix taxes the price-correcting arb harder, and that costs
LPs **7.2%** of their P&L. It buys closing a route worth 87% of gross to an attacker. That is a good
trade and it should be presented as a trade, not as a free lunch.

## UNTESTED / MODELLED-BUT-NOT-SIMULATED

- **The wall-clock invariance argument (§2.1).** Analytic. The rig runs 12s blocks only; **nothing here
  was simulated at 200 ms.** This is now the load-bearing unsimulated claim of the fix — if the lag is
  *not* invariant, α on Unichain is not 0.0115 and §2's table does not transfer. **Re-run the α sweep
  at Unichain block parameters before building.** Cheap: one constant.
- **Reference steering (§3.2).** Cost measured, revenue inferred from the α-sweep derivative, LP
  capture not modelled at all. §2.4d (JIT refund) is still untouched by any run in this document.
- **§3.3's "just wait" table is an attacker-favourable upper bound** — no flow at all during the wait.
  The claim that the corrective arb takes the displacement is reasoned, not simulated.
- **Flow calibration** (3 swaps/block, 5-tick median impact) is still the most load-bearing unmeasured
  input, unchanged from REFLEXIVITY.
- **Concentrated liquidity, gas, and the fee's destination** — none of these are modelled anywhere in
  this rig, at any point.

---

# BLOCK-TIME 2026-08-26 — the α sweep re-run at Unichain parameters

> Test of the one analytic, unsimulated claim in REFERENCE-CARRY §2.1. Script PART 15, same seed.
> **NEGATIVE CONTROL (15a): the 12s configuration built by the rescaling harness reproduces PART 10's
> α=0.5 row exactly** — ref lag 7.34t, honest 3.63 bps, XB keeps 1.6%, asserted in-script, run halts
> otherwise. So the harness is not silently a different model.

## VERDICT: **the invariance claim is WRONG — and it fails in the favourable direction. α = 0.0115 STANDS, and the fix is CHEAPER on Unichain than at 12s.**

## 1. How the rescaling was done — the judgement call, surfaced not buried

| quantity | rule | why |
|---|---|---|
| σ_block | `annual/√(sec_per_year/spb)` | falls as 1/√B. 3.701 t → **0.478 t** (ratio 7.75 = √60 ✓) |
| swaps/block | `3.0 · spb/12` ⇒ **0.05/block at 200ms** | order flow is a wall-clock rate |
| drift/block | `μ · spb/12` | same |
| blocks run | `4000 · 12/spb` | same wall-clock span |
| α | `1 − 0.5^(spb/12)` ⇒ **0.011486** | 12-second wall-clock half-life |
| **trade size** | **held constant PER SWAP (5-tick impact)** | **THE JUDGEMENT CALL.** A $5,000 trade is a $5,000 trade whatever the block time. Holding *impact per block* constant instead would make every Unichain swap 60× larger, which is not a market. **If this choice is wrong, §2's transfer is wrong.** It is the one input here that is a modelling decision rather than a consequence. |

## 2. Invariance: **NO. The lag falls to 0.49×, and my analytic argument was wrong.**

| block time | α (12s half-life) | ref lag measured | vs 12s |
|---|---|---|---|
| 12 s | 0.500000 | **7.34 t** | 1.00× |
| 2 s | 0.109101 | 5.42 t | 0.74× |
| **200 ms** | **0.011486** | **3.59 t** | **0.49×** |

**The error, stated plainly:** REFERENCE-CARRY §2.1 used `lag ≈ σ_b/√(2α)` on *both* sides. The exact
discrete-time result is `σ_b/√(α(2−α))`, which reduces to `σ_b/√(2α)` — and is therefore invariant —
**only as α→0**. At α=0.5 the discrete correction is large. The exact formula predicts 0.74×, and the
measurement gives 0.49×; the remaining gap is flow-induced displacement, which at 12s has 3 swaps per
block to generate it and at 200ms has 0.05.

15e prints prediction against measurement at every half-life. At 200ms they track well (3.16 t
predicted / 3.59 t measured at a 12s half-life); at 12s blocks the formula is poor (4.27 t / 7.34 t)
because flow, not volatility, dominates the lag there. **Do not quote the closed form at coarse block
times.**

**A smaller lag is the good direction:** less standing displacement ⇒ less honest flow charged.

## 3. The 200 ms confusion matrix — **XB still collapses to the in-block value**

| config | honest charged | honest bps | IN keeps | **XB keeps** |
|---|---|---|---|---|
| 12s, α=1 (shipped) | 44.6% | 3.79 | 1.6% | **87.3%** |
| 12s, α=12s half-life | 49.0% | 3.63 | 1.6% | **1.6%** |
| **200ms, α=1 (shipped)** | 5.8% | 0.14 | 1.7% | **99.4%** |
| **200ms, α=12s half-life** | 48.5% | **1.51** | 1.5% | **1.5%** |

**The fix works on the target chain and costs less than half what it costs at 12s** (1.51 vs 3.63 bps
— 30% of a 5 bps pool fee rather than 73%).

> ### 3.1 TWO THINGS THAT ONLY BECOME VISIBLE AT 200 ms, and both matter for the pitch
>
> **(a) The shipped hook is very nearly INERT on Unichain.** At α=1 and 200 ms it charges 5.8% of
> swaps a volume-weighted **0.14 bps** and lets **99.4%** of extraction out the cross-block door —
> worse than the 87.3% at 12s. With 0.05 swaps per block, a block almost never contains two swaps, so
> there is almost no intra-block price path to charge. **SWITCHBACK as specified in §2.1 barely
> functions on the chain we are targeting.**
>
> **(b) With the fix, 96.6% of the honest fee is attributed to the CARRIED reference**, versus 30.8%
> at 12s. **On 200 ms blocks SWITCHBACK is no longer an intra-block-path mechanism at all — it is
> almost entirely a carried-reference mechanism.** The pitch sentence *"the pool's own price path
> turning back on itself within one block"* (§2.5, the sentence that distinguishes it from EvenFlow)
> **is close to vacuous at 200 ms.** The honest description on Unichain is *"a decaying reference
> price, and you pay for walking back toward it."* That is a different sentence, and a judge who
> checks Unichain's block time can ask for it. **Rewrite the pitch or pitch a 12s chain.**

## 4. The "just wait" table at 200 ms — **wall-clock identical, qualitatively STRONGER**

Share of untaxed gross retained (attacker-favourable upper bound, as before; separate 1,200-trial
sample, so the 12s row differs from REFERENCE-CARRY §3.3 by sampling noise):

| 12 s blocks, α=0.5 | k=1 | k=2 | k=3 | k=5 | k=10 | in-block |
|---|---|---|---|---|---|---|
| | 1.4% | 2.8% | 9.0% | **44.8%** (60 s) | 84.8% | 1.4% |

| 200 ms blocks, α=0.011486 | k=1 | k=30 | k=60 | k=120 | k=180 | k=300 | in-block |
|---|---|---|---|---|---|---|---|
| | 1.8% | 1.8% | 1.8% | 3.6% | 11.0% | **51.2%** (60 s) | 1.8% |

**Nothing changes qualitatively, and what does change favours us.** The half-life is the hold time by
construction, so the wall clock is identical — 60 s to halve the charge on either chain. But at 200 ms
the attacker must survive **300 blocks of other people's flow and 300 top-of-block corrective-arb
opportunities** to get there, instead of 5. The position they are holding is precisely the
displacement the arb wants. **§2.4a's inventory-risk argument is stronger on Unichain, not weaker.**

## 5. What α actually works at 200 ms — **the half-life is a dial, not a threshold**

| wall-clock half-life | α | ref lag | honest charged | honest bps | IN keeps | XB keeps |
|---|---|---|---|---|---|---|
| 1 s | 0.129449 | 1.15 t | 37.3% | **0.48** | 1.6% | **1.6%** |
| 4 s | 0.034064 | 2.40 t | 47.0% | 1.00 | 1.6% | **1.6%** |
| **12 s** | **0.011486** | 3.59 t | 48.5% | **1.51** | 1.5% | **1.5%** |
| 60 s | 0.002308 | 6.32 t | 49.4% | 2.57 | 1.4% | **1.4%** |
| 300 s | 0.000462 | 12.80 t | 50.0% | 4.32 | 1.2% | **1.2%** |

**XB collapses to the IN value at every half-life tested, from 1 second to 5 minutes.** There is no
threshold to get right and no cliff to fall off — the half-life buys inventory-hold time at a linear
price in honest bps. **12 s remains the recommendation** (1.51 bps, 60 s to halve the charge); 4 s is
available at 1.00 bps if honest cost is the binding constraint.

## 6. Robustness: gas is not modelled anywhere, so arb thinness was stressed instead

At 200 ms the per-block market move is 0.48 ticks, so a corrective arb every block may not clear gas.
Pricing arbs out changes nothing that matters:

| 200 ms, arbs priced out | ref lag | honest bps | XB keeps |
|---|---|---|---|
| 0% | 3.59 t | 1.51 | 1.5% |
| 50% | 4.01 t | 1.62 | 1.5% |
| 90% | 6.27 t | 2.29 | 1.4% |
| 98% | 10.93 t | 3.55 | 1.3% |

**The fix does not depend on a dense arb population.** Honest cost rises to the 12s level when 98% of
arbs are priced out, which is the worst realistic case.

## 7. STRAIGHT ANSWER

**α = 0.0115 (a 12-second wall-clock half-life) STANDS on Unichain.** The invariance argument that
justified it was wrong; the conclusion it supported is right for a different reason, and the numbers
are better than the argument predicted. **Nothing in REFERENCE-CARRY §6's recommendation table changes
except in our favour.**

**Two new things to carry into the pitch, both from §3.1:**
1. **State the half-life in seconds and derive α from the chain's block time.** A per-block α is a
   60× error on Unichain, in the direction of no protection at all.
2. **The intra-block-path framing does not survive 200 ms blocks.** On Unichain this is a
   carried-reference mechanism, not a path-integral-over-one-block mechanism, and the §2.5
   differentiation from EvenFlow has to be re-argued on that basis. **This is the most significant
   presentational consequence found in any of the three sections.**

## UNTESTED / STILL MODELLED-BUT-NOT-SIMULATED

- **The per-swap trade-size rescaling (§1).** The one judgement call. Everything in §3–§6 is
  conditional on it and no market data was used to justify it.
- **Gas**, still, anywhere. §6 stresses arb *thinness* as a proxy and that is not the same thing.
- **Unichain's actual flow density.** 0.05 swaps/block is 3/block at 12s rescaled, not a measurement.
  §3.1(a)'s "the shipped hook is nearly inert on Unichain" is only as good as that number, and it is
  the cheapest remaining thing to measure — one subgraph query against a live Unichain v4 pool.
- **§4's wait table is still an attacker-favourable upper bound** (no flow during the wait).
- **Concentrated liquidity, the fee's destination, and §2.4d (JIT refund)** — untouched by every run
  in all three sections.
