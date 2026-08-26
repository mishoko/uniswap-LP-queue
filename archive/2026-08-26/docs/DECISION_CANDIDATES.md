# UHI10 — the candidate shortlist, in business terms

*2026-08-26. Synthesis of three independent ideation passes (`IDEAS_MECHANISM.md`,
`IDEAS_INTEGRATION.md`, `IDEAS_LEDGER_FOLD.md`) against the measured research in
`HACKATHON_CONTEXT.md` / `WINNERS_LANDSCAPE.md`. Scores are against the real published rubric:
**30% Original Idea · 25% Unique Execution · 20% Impact · 15% Functionality · 10% Presentation.***

---

## 0. Read this first — the router question is SETTLED, by execution

*Spike run 2026-08-26, commit `55c2ae2`, `test/spike/RouterCompatibility.t.sol`, 13 tests, full suite
174 pass / 0 fail. Driven through two independent router paths, neither of them ours: the deployed
`UniswapV4Router04` hookmate artifact, and `V4Router` (the abstract UniversalRouter inherits), using
v4-periphery's own `Planner` to build a real `SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL`.*

**It reverts. Confirmed.** A NoOp'd swap through `V4Router` fails with `IV4Router.V4TooLittleReceived(1, 0)`
— asserted by exact selector *and* args — because `Hooks.afterSwap` subtracts the hook's
`beforeSwapDelta` from the caller's delta before the router ever sees it. Through the hookmate
artifact: `SlippageExceeded()`. A hookless control on the same rig succeeds, so it is the NoOp, not
the harness.

| Candidate | Verdict |
|---|---|
| **SWITCHBACK** | **ROUTER-CLEAN.** Settles on both routers with slippage on. |
| **HASTE** (deferred lane as specified) | **NEEDS-PERIPHERY, 14–20 h.** Not fatal; the accounting is proven. |
| **HASTE** (inventory-backed variant) | Router-clean **and a trap** — see below. |

**`minOut = 0` is not an escape hatch.** Measured: the user's input falls by exactly `amountIn`,
output unchanged, hook holds the full 6909 claim. The only way to reach the deferred lane through
standard routing is to zero out slippage protection on a swap handed to an unaudited hook. No
frontend will emit that, and none should.

**A second, unbudgeted problem the spike surfaced:** `sender` in `beforeSwap` is the **router**, not
the trader (asserted). `hookData` is forwarded verbatim by both routers, but *empty* hookData is the
default — which leaves the hook with no beneficiary, and crediting the router loses the funds.
Periphery scope: `place()` 4–5h · `fill()` crank 4–6h · order struct/maturity/refund 3–4h · tests
3–5h.

**There is one router-clean way to defer, and we should not take it.** If the hook leaves the curve
untouched and pays the trader immediately out of its own inventory, a swap with `minOut` at 98% of
notional passes with slippage fully on, and `slot0.sqrtPriceX96` is bit-identical before and after.
But that is no longer a queue — it is a market maker. The hook now needs inventory, a quoting rule
and a hedging policy, and it re-opens the free-option problem in a worse form, because the hook is
quoting a firm price to anybody. Paying output as a 6909 claim does not rescue it (the router's TAKE
calls `poolManager.take`).

**SWITCHBACK's one caveat, tested rather than assumed.** A fee taken via `afterSwapReturnDelta`
settles on both routers and is correctly taken out of the output, not charged on the input. But
quoting against a hookless twin and demanding that number **reverts** — the router's slippage check
sees the post-fee number, so **the retracement fee sits inside the user's slippage budget.** Fix is
half a day: cap the fee at a disclosed maximum and publish it as a view for quoters. Note it cuts
*with* the mechanism — a sandwicher's back-run reverting on slippage is a win; an honest trader's
reverting is a bug, and the cap is what separates them.

**Distrust-green earned its keep again, fourth time in this repo.** Mutation testing (M1: stop
NoOping → 8 of 13 red; M2: skim zero → all three red) **caught a bad test the agent had written
itself**: one assertion checked only `reason.length > 0` and passed under M1, because the mutant
reverted with `CurrencyNotSettled()` — a completely different failure. It was proving *something*
broke, not that slippage rejected the swap. Now pinned to the exact selector.

**Disclosed:** `V4Router` was vendored to `test/spike/vendor/` because upstream pins
`pragma solidity 0.8.26` exactly while `src/` needs ≥0.8.28 for `transient`. Nine mechanical lines
differ (1 pragma, 8 import paths to identical files), zero logic; the reproduce command is in the
file header. A paraphrased router was considered and rejected — it would prove nothing about the
real one. `foundry.toml` untouched.

**STILL UNTESTED, do not treat as validated:** HASTE's free-option/refund economics (**the most
likely killer, and the correct next experiment**) · blockhash randomness quality · the actual
`UniversalRouter` Permit2 command wrapper (the spike drove the abstract it inherits) · SWITCHBACK's
real fee curve, JIT-refund attack and dust-poison cap (the 5% skim above is a router probe and proves
nothing about its economics) · multi-hop and exact-output · gas.

---

## 1. The shortlist

### HASTE — *sell immediacy instead of guessing who is toxic*

**What it is.** The pool posts a price for executing *right now*. Pay it and your swap goes through
immediately. Decline it and your order is placed irrevocably and settles at a random future block, for
free. The premium is paid to the LPs who were in range.

**Why it is interesting.** The organizers' own open problem #3 is *"dynamic fees alone can't
distinguish good retail flow from bad toxic flow."* Every existing answer is a **classifier** —
reputation scores, size thresholds, oracle deviation, ML models. A classifier is gameable by anyone
willing to look like what it rewards. HASTE never classifies anyone. It prices urgency, and
**pretending to be retail means actually being late, which destroys the arbitrage.** The attacker
sorts himself. That is a separating equilibrium, not a heuristic.

**Who uses it.** LPs on volatile pairs, who today hand arbitrageurs a free option every block.
Unhurried retail flow, which gets a better price than it can get anywhere today.

**Novelty.** Ancestors are IEX's speed bump and Budish–Cramton–Shim batch auctions. Neither *sells*
immediacy — that is the new part. Sits on measured white space W1 (probabilistic settlement: taught
in the UHI curriculum, named as official Uniswap prompt example #2, and **zero real implementations
in 662 prior submissions**) and W6 (volatility-scaled delay: zero).

**Pairs defense with recapture** — the organizers' stated win condition — natively: the queue is the
defense, the premium donated to in-range LPs is the recapture.

**Pros.** Best thematic fit of anything here. Genuinely original economics. Explains in one sentence.
**Cons.** The router problem above hits it hardest — the free lane is the one that breaks.
Needs three `test_noExemption_*` cases written *before* the fee curve, because a carve-out is exactly
what killed Hardcap (its first-swap-of-block exemption subsidised the top-of-block race).

**Rubric ≈ 4.10.**

---

### SWITCHBACK — *charge the round trip*

**What it is.** The hook records the price at block open and tracks the intra-block high-water marks.
Any swap that walks the price *back toward* where the block started pays a fee proportional to the
ticks retraced, capped by how far the price was extended. That fee is escrowed and donated next block
to the liquidity that was present at block open.

**Why it is interesting.** A sandwich is, by definition, a price extension followed by a retracement.
So is a self-liquidation, so is most JIT extraction. SWITCHBACK does not detect a sandwich, identify
an attacker, or classify anyone — **it charges the shape of the trade.** The back-run pays, and the
back-run is the leg that must exist for the attack to be profitable.

**Who uses it.** Any volatile pair. It needs no oracle, no keeper, no randomness, no async
settlement, and no custom periphery — it is a fee, so it routes normally.

**Novelty.** `round.?trip|reversal|backrun` returns **0 matches in 662**. Honest caveat that the agent
volunteered rather than hid: it is adjacent to published work — Umbra Research's sandwich-resistant
AMM and Sorella's Angstrom intra-block rule. a16z / Variant / Dragonfly judges will know that work.
Scored 3/5 on originality for that reason, not 4.

**Pros.** No external dependencies at all. Shares **zero code** with HASTE, so it is a free
same-day switch if the router spike kills HASTE.

**⚠ CORRECTION 2026-08-26 — the recapture leg is NOT implementable as written, and the stated
mitigation was wrong.**
1. **`poolManager.donate()` pays whoever is in range NOW.** There is no primitive that pays "the
   liquidity present at block open." The escrow-and-donate-next-block design does not do what the
   pitch says it does.
2. **The JIT-refund drain is live, and our claim that it is "mitigated by the next-block donation"
   is FALSE** — the JIT position is in range next block too, so it collects the donation it caused.
   OpenZeppelin's `LiquidityPenaltyHook` **documents this bypass in its own NatSpec**: an attacker
   adds dust from a second account at an empty tick, pushes price there, and the penalty donation
   lands on himself. OZ shipped it calling the attack "rarely profitable" — **on the thin volatile
   pairs SWITCHBACK targets, it is cheap.** This is the Hardcap vault-drain reborn, and it was papered
   over here exactly the way Hardcap's weaknesses were.
   **Fix = aged-LP escrow (N-3) + JIT activation delay via `bornBlock`, key MUST include `salt`
   (N-4). Week one, proven in tests, not asserted in a README.**
3. **Do not lead the pitch with "sandwich."** Gogol et al. (arXiv 2601.19570, Jan 2026) find that on
   private-mempool rollups sandwiches are rare, mostly unprofitable, and **>95% of sandwich-shaped
   triples are false positives.** Our designated demo was "run a real sandwich, show P&L go
   negative" — on Unichain a judge who has read that paper hears *"a lock for a door already
   removed."* It does **not** kill the hook: JIT is one atomic unlock and is chain-independent, and
   self-liquidation/retracement is untouched. **Lead with the SHAPE — extension-then-retracement —
   not with the word sandwich.**
4. **A failed sandwich has nothing to donate.** SWITCHBACK survives this because its fee is *charged*,
   not *withheld* — but say so explicitly rather than letting a judge find it.
5. **`PoolManager` keys POSITIONS by the unlock's `msg.sender`** — usually the router. Same root cause
   as audit A-1 and hard-won fact §5.5. **Settle this before writing any aged-LP logic.**

**Cons.** Lower originality ceiling, and the incumbent is stronger than we recorded: **Angstrom is
not merely adjacent published work — it is a LIVE v4 hook deployed on Unichain AND Base** doing
app-level MEV internalisation. It belongs in the comparison table. The honest distinction still
holds: **Angstrom taxes the gas tip; SWITCHBACK charges the price path.**

**Sharper originality claim than "0/662".** The prior brainstorm's own taxonomy says fee assignment
has four cells — age, bond, auction, protocol-owned liquidity — plus leftover-vs-top-of-block, and
concluded *"there is no fifth object."* **SWITCHBACK is a fifth: it assigns by intra-block price-path
shape.** That framing survives a judge who knows all five incumbents; a raw grep count does not.

**Rubric ≈ 3.95. This is the designated fallback and the safe pick.**

---

### SLUICE — *route the toxic flow to an auction and give the LPs the proceeds*

**What it is.** When the hook judges a swap toxic, it does not execute it against the pool. It
escrows the input and opens a **real CoW Protocol conditional order**, limit-priced at the pool price
minus a fee. CoW's solver competition fills it. The **surplus the solvers compete away** is donated
to the in-range LPs the flow was diverted from. Anything unfilled falls back into the pool when the
order expires.

**Why it is interesting — and this is the finding of the day.** Official Uniswap prompt example #4 is
*verbatim* "hybrid routing between private orderflow systems (CoW, Flashbots Protect) and Uniswap."
Across nine cohorts and 662 submissions: `flashbots` → 0, `cow protocol` → 0, `uniswapx` → 0. **Thirty-two
projects built CoW-*style* matching from scratch; not one connected to the real thing.** Atrium says
a genuine integration here is *"close to guaranteed differentiation."*

The lane is empty because of a **misreading**. Everyone assumes CoW's `ComposableCoW` is Safe-wallet
only. It is not — the agent read the source: `create()` is `singleOrders[msg.sender][hash] = true`,
with **no Safe check and no type check.** Any contract can place a conditional order. A permissionless
watch-tower already reads the `ConditionalOrderCreated` event, calls our `getTradeableOrder()`, and
posts to the orderbook — **the loop closes with zero off-chain infrastructure from us.** Addresses
RPC-confirmed on Sepolia.

**Who uses it.** LPs who are currently the exit liquidity for toxic flow. The swapper still gets
filled, often at a better price, because solvers compete.

**The delete test — the one that matters for any "integration".** If you deleted the integration,
would the mechanism still work? **No.** The whole value transferred to LPs *is* the solver-competition
surplus, and that number cannot be manufactured in-house. This is a load-bearing integration, not a
decorative call.

**Pros.** Real integration (worth 27.5% vs 15.0% prize rate across the dataset). Prompt example #4
verbatim. Defense and recapture genuinely paired. Both open risks degrade it rather than kill it.
**Cons.** CoW is **not a sponsor** — this buys Unique Execution (25%), not a second prize track.
Hit by the router problem. Heaviest integration risk of the shortlist.

**Rubric ≈ 4.40 as ideated — but see the execution result below, which I score down to ≈4.05.**

#### SLUICE — EXECUTION RESULT, 2026-08-26 (`test/spike/CowNonSafeFork.t.sol`, 9 tests green on a Sepolia fork, nothing mocked)

**VERDICT: GO WITH CAVEATS. The load-bearing claim survived execution *and* mutation.**

- `create()` from a plain non-Safe contract: **storage write lands.** `getTradeableOrderWithSignature()`
  returns an 864-byte signature and takes the **EIP-1271 Forwarder branch** — asserted it is *not* the
  Safe branch.
- **The one that matters: a real `GPv2Settlement.settle()` was executed.** Eip1271 trade, solver added
  via the allowlist manager. The hook received 1000e18 buyToken. Not a source read, not a mock.
- **Mutation-tested:** hook returns `0xdeadbeef` instead of the magic value ⇒ real settlement reverts
  `"GPv2: invalid eip1271 signature"`. The agent's earlier passing test (hook returns magic → assert
  magic) was **circular and proved nothing**; the suite was green 6/6 before the settle test existed.

**Interface we must implement:** `isValidSignature(bytes32,bytes)` on the hook — decode
`(GPv2Order.Data, Payload)`, assert `ccow.singleOrders(self, ccow.hash(params))`, assert the digest
matches, delegate to a handler, return `0x1626ba7e`. Plus a handler exposing
`getTradeableOrder`/`verify`/`supportsInterface`. **8–12h for both with adversarial tests; 30–45h
including Sluice's escrow / NoOp / claim / donate machinery.**

**Four footguns, each a silent kill, all found by running it:**
1. **`supportsInterface` returning `false` bricks discovery** (`InvalidFallbackHandler()`). *Not
   implementing it at all* works. This is the **opposite of normal ERC-165 hygiene**, so someone will
   "fix" it into a bug later unless it is written into the contract and pinned by a test.
2. **The watch-tower filters on HANDLER with `defaultAction: DROP`.** Five allowlisted handlers on
   Sepolia, `"owners": {}` — which is exactly why non-Safe works. Corroborated on-chain: 23
   custom-handler orders over ~2M blocks, **zero fills**; the TWAP control got 12; 7/7 recent fillers
   used TWAP.
3. **ERC-1271 gets no balance/allowance waiver** (that is PreSign-only) — the hook must hold the sell
   token *and* have a VaultRelayer allowance at placement time.
4. **A revert in `isValidSignature` aborts the solver's whole batch.** Sluice's validity depends on
   live pool state ⇒ structurally high revert risk ⇒ solver deprioritisation.

**CLAIM WITHDRAWN.** This morning's "the loop closes with zero off-chain action by us" was **too
strong**. True only with a *stock allowlisted* handler. A bespoke Sluice handler requires us to run
our own watch-tower — a real off-chain component that must be disclosed in the trust story. The
choice is (a) stock TWAP handler + hosted relay, zero ops, **proven to fill** — the demo path; or
(b) bespoke handler + our own watch-tower — the mechanism we actually want, with an off-chain box in
the diagram.

**Sepolia is alive but a MONOPOLY.** ~4 settlements per 5,000 blocks (~1 per 4h), 260 in 28 days,
**all by a single solver.** An order we post can realistically fill. But **Sluice's entire recapture
mechanism is competitive-auction surplus, and there is no competition on Sepolia.** The demo can
prove the mechanism *works*; it cannot prove it *pays*. That economic claim must be argued from
mainnet and **labelled not-demonstrated.**

*(The agent's first liveness scan reported zero settlements and was wrong — a broken `cast logs`
call. It caught this only by running the identical query against mainnet as a control and getting an
impossible zero there too. It flagged the error rather than burying it.)*

`GPv2AllowListAuthentication.isSolver()` is permissionlessly readable; the list is `onlyManager`
(CoW DAO). Sluice only reads it. Non-issue.

**Why I score it down from 4.40 to ≈4.05:** demonstrability is the axis Assay died on, and two of
these caveats hit it directly — the recapture half of the pitch cannot be shown working on a testnet
with one solver, and the version of the mechanism we actually want puts an off-chain watch-tower we
operate into the trust story. Neither is fatal. Both must be said out loud in the video before a
judge finds them.

*Non-decorative sponsor upgrade available:* **Brevis** ZK-proving per-address realised markout over
history. That is the genuinely hard part of Sluice — the toxicity judgement — and it is the one thing
a hook cannot compute on-chain. Feasibility confirmed (`BrevisRequest` on Sepolia). Known footgun:
a Sherlock finding requires `BrevisApp.handleProofResult` to check the validation result; do not
inherit blind.

---

### GRAZE — *CoW-AMM's LVR auction, ported to concentrated liquidity*

**What it is.** CoW AMM auctions the right to rebalance the pool, so the value arbitrageurs normally
take goes to LPs instead. CoW AMM is constant-product only. Graze ports that mechanism to Uniswap v4
**concentrated** liquidity, and adds a punitive directional fee while an order is live.

**Pros.** Highest ceiling of anything considered. Genuinely never done. Routes normally.
**Cons.** Heaviest build by a distance. And **LVR is explicitly on Atrium's AVOID list** — 55 prior
submissions — so you spend the first 45 seconds of a 5-minute video digging out of a category the
organizers told you was over-built. That is a bad trade for a 10%-weighted presentation score.

**Rubric ≈ 4.15.**

---

### BLINDFOLD — *probabilistic settlement, done properly*

**What it is.** Chainlink VRF v2.5 plus Automation. The fill is executed *inside* `fulfillRandomWords`,
so the reveal and the fill are the same transaction and there is no window to react in.

**Pros.** Cleanest delete-test of the four integration candidates — proposer-influencable randomness
is defeated by using a real VRF, and that is not something you can fake. Chainlink **is** a sponsor.
**Cons.** It is **taught in the UHI curriculum**, which caps it at 3/5 on the 30%-weighted originality
axis. Hit by the router problem.

**Rubric ≈ 3.50.**

---

## 2. What was killed, and why the reasoning transfers

| Killed | Why |
|---|---|
| **Flashbots Protect / MEV-Blocker integration** | **Impossible as a hook — a category error, not a difficulty.** No contract exists anywhere in the stack. MEV-Share is an off-chain node; refunds are builder-paid under an off-chain condition. The docs contain no address because there is none. **Corollary to enforce: a hook cannot detect protected flow.** The only on-chain correlate (`tx.gasprice == block.basefee`) is forgeable for free. If "Flashbots integration" appears in our README it is a false claim. |
| **LP governance over the MEV mechanism** (0/662) | Liquidity-weighted voting on a pool that controls a revenue stream is flash-loanable — **the prize funds the attack.** And it is a parameter surface with a DAO bolted on, not a mechanism: fatal against 30% originality. Nearest prior art (Intent LP, UHI8) is close enough to kill it anyway. |
| **Searcher bonding / slashing for priority access** (0/662) | Sybil, unpatchable. The only provable misbehaviour is the intra-block price path; a sandwicher runs the two legs from two addresses, so nothing is attributable. The fast lane becomes a free pass for the actor it was built to deter, and bigger bonds *invert* the mechanism in favour of the capitalised searcher. |
| **Folding Assay's ledger primitive into an on-theme hook** | See §3. |
| Atlas / FastLane · UniswapX mainnet exclusive-filler · `PriorityOrderReactor` · Chainlink Automation on Sluice | Entry is a frontend/off-chain relay · cosigner is permissioned · Uniswap retired the path · decorative (a permissionless incentivised `settleExpired()` does the same job). |

---

## 3. Assay's disposition

**Not the submission.** Two independent passes converged: the audit scored it theme fit 2/5,
demonstrability 2/5, adoption 2/5, with three README headline claims falsified; and the fold analysis
returned *"(c) weaker, and the pull toward it is sunk cost."*

The governing reason is economic, not sentimental. **The ledger measures debt.** For a *hook*,
extraction *is* debt — the measurement and the thing measured are the same object, which is exactly
why Assay works. Toxicity is not debt. Pointing the same instrument at a swapper converts a proof into
an inference, and that inference costs **52,700 gas to evade** — about $3 on mainnet, a fraction of a
cent on Unichain. That is Hardcap's economic inversion rebuilt with a new sensor: the whale evades,
and the honest retail flow you cannot distinguish pays every time.

And structurally: **a sandwich is three transactions; transient storage does not survive one.** The
theme's headline is "kill the Sandwich." Every ledger-based candidate answers that question with "no."

**Where the residual value goes — two places, neither of them the submission:**

1. **As a component, aimed only at a party that agreed to be inspected** — an auction winner, a
   registered solver, a designated backrunner. Then the meter is sound, because that party nominated
   its own address and posted something it loses by walking. It becomes an oracle-free,
   in-transaction, non-self-reported meter on a privileged actor — **replacing the AVS that every LVR
   project in the directory needed.** Note this fits Sluice and Graze directly: both have exactly such
   a privileged party.
2. **As a separate published artifact**: the permission census — sweep every hook address that ever
   initialised a v4 pool, decode permissions from the address alone with zero calls, publish
   *"N deployed hooks, X able to move a swap delta, zero declaring a spec, zero bonded."* One day's
   work, true regardless of what we submit, and it does **not** consume the one submission.

Publish the ERC-6909 delta-laundering finding either way. One project in 662 has ever noticed it, and
after this cohort somebody will build a "toxic flow detector from flash accounting" with a hole they
do not know about.

---

## 4. Operational facts worth more than they look

- **Ethereum Sepolia is the only chain carrying v4 + CoW + Chainlink simultaneously.** That decides
  the deployment target for anything integration-based.
- **Chainlink VRF is not deployed on Unichain at all.** "A VRF hook on Unichain" does not exist.
- **Naming trap:** the UniswapX repo now has a `src/v4/` tree — "UniswapX *version 4*", with its own
  `IPreExecutionHook`, on Unichain Sepolia. Nothing to do with v4 pool hooks. Pitch "a v4 hook for
  UniswapX" and any judge who knows that repo hears the wrong product.
- **The Uniswap Prize is not theme-gated.** In UHI9's IL & Yield cohort it went to Orbital, an
  N-dimensional stableswap curve with no IL or yield mechanism. Off-theme work can take the biggest
  prize — but Orbital won on being a genuinely new AMM curve, not on being good infrastructure.

---

## 4b. HASTE — ECONOMICS RESULT, 2026-08-26 (commit `18e6054`, seeded Monte Carlo + closed form)

**VERDICT: GO-WITH-CAVEATS.** The free option is real but not where the objection put it, and it is
closed by one comparison. Two *other* findings nearly killed HASTE instead, both new.

*Sanity gates, which are why the rest is readable:* the arbitrage model reproduces the textbook LVR
rate σ²V/8 to **0.1–0.7%** across four volatility regimes, and the Monte Carlo is cross-checked
against the closed form φ(z)−z·Φ(−z) at every point. **That second gate caught a sign error** that had
the put's value rising with moneyness. Both gates print on every run.

**The crossover is not volatility — it is retail impatience.** Fitted across all vols and fee tiers,
the arb edge is **0.581·σ_block** and essentially fee-invariant; retail's cost of waiting is
λ·σ_block·√E[T]. **σ cancels from both sides:**

> **N_max = 2·(0.581/λ)² − 1**

λ=0.10 → 67 blocks · λ=0.15 → 29 · λ=0.25 → 10 (tight) · **λ=0.35 → 4.5 DEAD** · λ=0.50 → 1.7 DEAD.

A separating premium exists comfortably for **λ ≤ 0.15**: at ~60% vol the arb pays up to 2.14 bps
while retail at λ=0.15/N=10 charges itself 1.29 bps — a real (1.3, 2.1) bps band, not a knife edge.
Empty at λ ≥ 0.35. **λ is unmeasured and is now the single biggest open number in the project.**
Mean-variance never binds at block scale, so λ is behavioural, not utility curvature — it cannot be
derived, only measured.

**The option is not where the objection put it.** An irrevocable, no-minOut order filling at maturity
spot has E[P_T]−P_0 of ±0.1 bps against a standard deviation of 5.8–227 bps: **the payoff is linear.**
It is a forward with random delivery, not an option — so the delta-neutral adversarial placer harvests
nothing, because **a linear payoff has no gamma.** That objection is dead.

**The refund is the option, and it is large.** At an at-the-money trigger it is worth **1.6–3.5× the
arb's entire edge, free** — a straddle written by the LPs, exactly as feared, caused by a different
feature. **Fix: floor minOut at 2σ_b√E[T]** (z≥2 ⇒ worth <7% of arb edge, fires <3% of the time). One
comparison, using the σ the hook already measures.

**NEW HOLE — and it is the Hardcap shape.** The ideation assumed an attacker must guess the maturity
block. Wrong: **the filler knows the fill block, because it is their own transaction.** A
searcher-filler bundles front-run → crank → back-run and sandwiches the order it settles, with
certainty, for gas. Randomised maturity buys nothing against them. **Fix: settle matured orders at the
block-OPEN price**, so front-running your own crank cannot move the fill.

**NEW SCOPE LIMIT.** Relax the assumption of competitive arbitrage: at a 5% arb arrival rate the
surviving edge rises 2.14 → **11.66 bps** — the edge stops decaying, so a monopolist arb defers for
free and pays nothing. **On a pool with no arbitrage competition HASTE collects nothing and defends
nothing.** Same shape as Hardcap's first-swap exemption. HASTE is a mechanism for *competitively
arbitraged* volatile pairs and must be pitched as exactly that.

**Two disclosures for the pitch:** the premium is *not* paid out of the arb's pocket — it is paid by
widening the no-arb band, so staleness tracks friction ~1:1 and an urgent trader's true cost is
premium + staleness ≈ **2× premium** (LPs still gain: LVR falls faster than revenue rises). And the
filler must be paid more than gas, implying a minimum deferred order size ≈ gas/premium — **HASTE is
regressive: it protects large retail and taxes small retail.**

**UNTESTED:** λ itself · the block-open settlement fix (reasoned, not simulated or implemented) ·
retail as a price-mover · multi-arb as a game rather than a Bernoulli arrival rate · concentrated
liquidity (the model is v2) · gas.

---

## 4c. THE SYNTHESIS NOBODY COMMISSIONED — the two candidates share a substrate

HASTE's fix for the searcher-filler hole is **settle at the block-open price**. That requires a
block-open reference tick maintained across the block.

**That is precisely the state SWITCHBACK already keeps** — its whole mechanism is "price at block
open, plus intra-block watermarks, charge the retracement."

This reframes the decision. SWITCHBACK is not merely the safe fallback; **it is the substrate HASTE
needs anyway.** Build order resolves what looked like an either/or:

```
  LAYER 1   block-open tick + intra-block watermarks        ← SWITCHBACK's core state
              │
              ├─► retracement fee, escrowed, donated next block   = SWITCHBACK, shippable alone
              │
              └─► block-open settlement price for matured orders  = HASTE's anti-filler fix
                        │
                        └─► immediacy premium + deferred queue    = HASTE, needs periphery + λ
```

Ship Layer 1 + SWITCHBACK first: it is proven router-clean, has no external dependency, and is a
complete submission on its own. HASTE then becomes an *extension* of a working hook rather than a
parallel bet — and if λ measures badly, the extension is abandoned at no cost to what already ships.

## 5. Recommendation

**Conditional on the deadline, which is unresolved and must be settled from the owner's email.**

**If the deadline is 2026-09-03 (~8 days):** build **SWITCHBACK**. It is the only candidate with no
external dependency, no router problem, no oracle, no keeper, and a demo that fits in one screen —
a real sandwich with its P&L going negative. Ship it with tests and a human-voiced video. Do not
attempt an integration in eight days.

**If the deadline is genuinely ~10 weeks:** build **SLUICE**, with SWITCHBACK's retracement fee as
the in-pool defense for flow it does not divert. That combination is the organizers' win condition
stated literally — ordering protection *and* auction recapture — it lands the highest score anyone
produced, and it occupies the one lane the organizers themselves called "close to guaranteed
differentiation" and that nobody has entered in nine cohorts.

**Either way, this week:** run the router spike (in flight), and build the permission census, which
is true under every branch.

**Do not** submit Assay. **Do** publish it.
