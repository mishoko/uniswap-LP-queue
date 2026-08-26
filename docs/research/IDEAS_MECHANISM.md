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
