# WINNERS_LANDSCAPE — what has already been built and what won

> Research date **2026-08-26**. Underlying dataset: the live Atrium Hook Directory, **662 submissions across UHI1–UHI10**, of which **148 carry at least one prize**.

---

## PROVENANCE

### Successfully fetched
| Source | Method | What it gave |
|---|---|---|
| `https://atriumacademy.notion.site/hook-directory` — aka `https://projects.atrium.academy/UHI-Hook-Directory-ac153130871b49a2b1274906580e7869`, aka `hooks.atrium.academy` | WebFetch returned only "Notion" (SPA). Retrieved via Notion public API `POST /api/v3/queryCollection`, collection `fd147a64-8e39-4910-b5f3-f6ed78a1c5bc`, space `3118cd40-1c65-4df1-afa4-02528d8d0ffd`, view "All Hooks" `d68ce62e-...`. | **662 rows**, fields: Name, Cohort, Prize, Tags, Integrations, Description, Submission Type. Saved verbatim to `docs/research/data/hook_directory_662.json`. |
| `https://drive.google.com/file/d/1Q1-rIQdD6DxhmSriarAwf_hofMvg7TM-/view` (UHI10 Theme Brainstorming Slides, 8pp) | `curl` on `uc?export=download` + `pypdf` | Atrium's own precedent / white-space / saturation analysis. |
| `https://drive.google.com/file/d/1d6Hl-x3euWebEsir5uWLPDC6MbL2fi_x/view` (Hookathon Guidelines, 10pp) | same | Rubric + named "high-scoring examples". |
| `https://github.com/fewwwww/awesome-uniswap-hooks` | WebFetch | ~150 hook ideas across production projects, ETHGlobal/Hookathon events 2023–2024. Independent of the Atrium directory. |
| `https://blog.atrium.academy/uniswap-hook-incubator-2025-wrapped` | WebFetch | Category-share percentages + named prize winners for UHI4–UHI7 + alumni outcomes. |
| `https://atriumacademy.notion.site/atrium-academy-request-for-hooks` | Notion API `loadPageChunk`, pageId `20f5f044-4abe-8058-8371-e59b27a3e714` | Sponsor tracks; EigenLayer/Brevis explicit "already built, won't win" notes. |
| Web search (UHI winners) | WebSearch | Confirms CrossHedge won the Uniswap Foundation track at UHI9; a UGM student won 2 UHI9 tracks (IL & Yield Systems + Reactive Network); UHI9-era prize pool reported as ~$25,000; judges drawn from a16z, Variant, Dragonfly, USV, and Ken Ng (Uniswap Foundation co-founder). |

### Could NOT access — contents NOT guessed
| Source | Attempt | Result |
|---|---|---|
| `blog.blockmagnates.com/how-i-won-the-uniswap-foundation-prize-track-at-uhi9-...` | WebFetch | **403**. This is the best available first-hand "why it won" account and it is unread. |
| `x.com/AtriumAcademy/status/2047359898237952183` (UHI10 theme thread) | WebFetch | **402**. Only the search-result title snippet is known. |
| `luma.com/0p6uabf2` (Demo Day) | not fetched | event page, no winner list expected |
| Per-project GitHub repos / demo videos | not fetched (662 of them) | out of scope for this pass |
| Judges' written scorecards, per-project scores, rank order within prize tracks | searched | **never published**. The directory has a boolean-ish "Prize" field only — no 1st/2nd/3rd, no score. |

### Known limits of this dataset — read before trusting any number below
1. The **Prize** field is multi-select of *track names* (Uniswap Prize, EigenLayer Prize, …). There is **no ranking and no score**. "Won" here means "received at least one track prize."
2. Saturation counts below are **keyword matches over Name + Description + Tags + Integrations**. They are indicative, not a semantic classification. Categories overlap heavily; a single hook can appear in six lanes. Do not sum them.
3. The Tags vocabulary is submitter-authored and polluted (several "tags" are entire paragraphs). Treat tag-based counts as noisy.
4. Directory currently holds only **1 row tagged UHI10** (`Strata`) plus 1 untagged (`uniguard.exchange`) — UHI10 submissions are not in yet. **We cannot see our competition.**

---

## 1. PRIZE-WINNING PROJECTS

148 prized submissions. Full records are in `data/hook_directory_662.json` (filter `prize != ""`). Below: **the theme-relevant subset (MEV / ordering / LVR / flow-quality / CoW)** across all cohorts, plus complete UHI9 and UHI8 lists since those are the most recent signal.

**"Why it won" is NOT published by Atrium for any project.** The column below is left as `— not stated` wherever there is no source. Anything else would be invention.

### 1a. Theme-relevant winners (MEV protection / LVR recapture / order-flow quality)
| Project | Cohort | One-line pitch (from directory) | Category | Why it won | Link |
|---|---|---|---|---|---|
| MEV Auction Hook | UHI1 | "Reduce MEV spreads and impermanent loss natively through swaps" | MEV auction | — not stated | Hook Directory |
| Sandwich Protector Hook | UHI2 | "Hook which isn't visible for regular traders but prevents sandwichers from profiting out of swappers. Composable with aggregation protocols" | Sandwich defense | — not stated | Hook Directory |
| UniCow | UHI2 | "An actively validated service to enable Coincidence of Wants matching on any Uniswap v4 pool through v4 Hooks" | CoW / AVS | — not stated | Hook Directory |
| Milady Pool | UHI2 | "A private platform where users trade crypto without disclosing intentions to a wider market" | Dark pool | — not stated | Hook Directory |
| LVR & IL Hedge Hook | UHI2 | "Dynamic Fees + Delta-Gamma Neutrality … bring DeFi to a close Risk Neutral State" | LVR + hedging | — not stated | Hook Directory |
| RaffleSwap | UHI2 | Premium per swap into a jackpot; "aim to reduce chances of toxic o[rderflow]" | Flow quality / gamified | — not stated | Hook Directory |
| UniCowV2 | UHI3 | "Decentralized CoW swaps on Uniswap v4 enabled by EigenLayer with Inter-Pool matching" | CoW / AVS | — not stated | Hook Directory |
| Lever | UHI3 | "LVR for each block is auctioned and gains from LVR are distributed to LPs" | LVR auction | — not stated | Hook Directory |
| Auction Managed AMM & Active Range Incentives | UHI3 | am-AMM + active-range incentives in any currency | am-AMM | — not stated | Hook Directory |
| Detoxer: MEV protection hook suite | UHI4 | "MEV protection hook suite" | MEV suite | — not stated | Hook Directory |
| Priority is all you need | UHI4 | "Increases the fees of a pool when the priority fees are high" + indexing tools | Priority-fee-aware fee | — not stated | Hook Directory |
| EigenLVR | UHI5 | "Addresses LVR by redirecting MEV lost to arbitrage back to LPs through sealed-bid auctions secured by EigenLayer AVS operators" | LVR auction | — not stated | Hook Directory |
| FrontrunThis | UHI5 | "Encrypted trade matching off-chain and secure on-chain settlement, protecting users from MEV like frontrunning" (EigenLayer + EigenDA) | Encrypted matching | — not stated (won **both** Uniswap + EigenLayer) | Hook Directory |
| Debt Hook | UHI5 | "MEV-protected liquidations of collateralized debt positions" | MEV-safe liquidations | — not stated | Hook Directory |
| LP Hub | UHI5 | "Evidence based metrics (VPIN, Illiq, Inventory Exposure) from TradFi to empower LPs with highly effective dynamic fees" | Toxicity-aware fee | — not stated. Became a company (Hook Product Accelerator). | Hook Directory |
| LVR Auction Hook | UHI6 | "Auction first-in-block trading rights and redistribute arbitrage profits directly to liquidity providers" (EigenLayer AVS) | LVR auction | — not stated. **Cited by Atrium as a UHI6 precedent** (brainstorm p.4) | Hook Directory |
| Maestro | UHI6 | "An auction-managed AMM (am-AMM) hook that recaptures the value LPs normally lose to LVR and pays it back as per-block rent" | am-AMM rent | — not stated | Hook Directory |
| SwapbookV2 | UHI6 | "MEV-driven decentralized orderbook system with AMM and hook integration" | Orderbook | — not stated | Hook Directory |
| AlphaEngineHook | UHI6 | Privacy-preserving swaps + automated strategy execution via FHE + EigenLayer AVS | FHE + AVS | — not stated (won Fhenix **and** EigenLayer) | Hook Directory |
| EIGEN SHIELD FS HOOK | UHI7 | "Uniswap V4 hook plus EigenLayer AVS watchtower network that protects swaps from sandwich attacks and toxic MEV in real time. Restaker-operated nodes analyze the mempool inside EigenCompute TEEs" | Sandwich detection | — not stated | Hook Directory |
| EIGEN DARK HOOK | UHI7 | "Confidential liquidity vault and dark-pool style trading venue … EigenCompute TEEs to execute institutional-sized block trades privately" | Dark pool / TEE | — not stated | Hook Directory |
| EigenMatch CoW Hook | UHI7 | "Internally matching opposing trade intents before routing unmatched residuals to the Uniswap pool" | CoW | — not stated | Hook Directory |
| VeiledBatch | UHI7 | "Confidential intent-based batch auctions … fully encrypted intents (size, direction, max slippage) which remain hidden from the public mempool" | Batch auction + FHE | — not stated. **The only batch-clearing winner in the dataset.** | Hook Directory |
| Arb Hook | UHI7 | "Executes arbitrage during swaps, without off chain bots, latency, and mempool competition" | Internalized arb | — not stated | Hook Directory |
| EvenFlow | UHI8 | "Turns an oracle-free directional-toxicity fee into a yield-smoothing system: escrows the toxicity premium during adverse flow and drips it back to in-range LPs once the market goes quiet" | Toxicity fee + rebate | — not stated. **Closest existing analogue to "fee-rebate tied to flow quality".** | Hook Directory |
| Intent LP | UHI8 | "LPs register on-chain conditions (volume range, time window, slippage tolerance) so swaps violating their intent pay a penalty fee" | LP-set flow policy | — not stated | Hook Directory |
| SwapPilot | UHI8 | "Intercepts large swaps, queues them via the NoOp pattern, and executes at the AI-predicted optimal moment, minimizing slippage, price impact, and MEV exposure" | Delay / async | — not stated | Hook Directory |
| VolVantage | UHI8 | "Risk-Adjusted Dynamic Incentive Hook … protects LPs from toxic volatility and 'stress' events" | Dynamic incentive | — not stated. **Named a "high-scoring example" in the guidelines deck.** | Hook Directory |
| Devia | UHI9 | "Deviation-aware hook that dynamically increases swap fees under oracle uncertainty … reducing LP losses from toxic arbitrage flow" | Toxicity fee | — not stated | Hook Directory |
| EigenAuction | UHI9 | "Arbitrage auction mechanism based on EigenLayer AVS which reduce LVR for liquidity providers" | LVR auction | — not stated | Hook Directory |
| HyFi | UHI9 | "A platform for propAMMs that makes them possible on EVM for the first time. PropAMMs offer better pricing, eliminate toxic flow, lower fees, and less slippage" | propAMM | — not stated | Hook Directory |
| CrossHedge — CoW for LP risk | UHI9 | "Hedges impermanent loss by matching LPs with opposing risk peer-to-peer across chains, with an ERC-4626 vault as the always-available counterparty" | CoW for risk | Won the **Uniswap Foundation prize track** (confirmed via search result title; the author's write-up is 403 and unread) | Hook Directory |
| Glyph | UHI8 | Cross-pool reputation registry that "reprices known extractors up to 33x, paying the premium to LPs" *(per brainstorm p.4; the directory row for Glyph shows no prize)* | Reputation / fee rebate | **Cited by Atrium as a UHI8 precedent** — but ⚠ **not marked as a prize winner in the directory** | brainstorm p.4 |
| Tidehook | UHI8 | "Dual-market router that segments retail from whale trades, shielding LPs from toxic flow" | Flow segmentation | **Cited by Atrium as a UHI8 precedent**; prize status not confirmed in directory | brainstorm p.4 |
| AsyncSwapHook | UHI7 | "Randomized 24–84 second execution delay on large swaps, breaking sandwich-bot timing" | Ordering / delay | **Cited by Atrium as a UHI7 precedent**; no prize recorded in directory | brainstorm p.4 |
| CoWSwap | UHI2 | "Matches coincidence-of-wants orders off-chain, falling back to the AMM when no match is found" | CoW | **Cited by Atrium as a UHI2 precedent**; no prize recorded in directory | brainstorm p.4 |

> ⚠ Note the divergence: **four of the five projects Atrium picked as "precedents" for this cohort are not prize winners.** Atrium's brainstorm deck selects on *mechanism relevance*, not on *who won*. Don't conflate the two lists.

### 1b. Complete UHI9 winners (most recent cohort, IL & Yield theme — 12 of 68 = 17.6%)
BackStop (Uniswap) · CrossHedge — CoW for LP risk (Uniswap) · Devia (General) · EigenAuction (General) · HyFi (General) · ILAwareLimitOrderHook (Uniswap) · Indemnify (General) · Mochi Yield (General) · Orbital (Uniswap) · Schizō (General) · TokenLaunchHook Studio (General) · Unistrata (Reactive Network).
Notable: **7 of 12 are IL/yield-structuring** (insurance marketplace, PT/YT split, tranching, IL-bearing tokens). The theme dominated the winner set. Expect the same for UHI10 → MEV-protection mechanisms should dominate.

### 1c. Complete UHI8 winners (23 of 158 = 14.6%, "Specialized Markets" theme)
1Tx · Autonomous Liquidity Optimization Hook · Bundl · DobDex · EvenFlow · FoodySwap · Intent LP · MEGA QUANT · MaybeSwap · ParaDex · Paradox Fi · PerpHinge · Proven Protocol · Satisfy · StableStream · SwapPilot · UniBrain — Autonomous AI Strategy Hook · VFA Hook · Veritas Protocol (IP-Fi) · Veritas (Provenance-Aware IL Protection) · VolVantage · Voltaire · lambda.

### 1d. Selected earlier winners by category (from `blog.atrium.academy/uniswap-hook-incubator-2025-wrapped`, with that post's own category shares)
- **LP Optimization & Dynamic Fees — 57% of submissions:** AdaptiveSwap (UHI4, EigenLayer), Advanced Liquidity Manager Hook (UHI4, Flaunch), Prisma (UHI6, Uniswap)
- **Incentives & Yield — 37%:** DexProfitWars (UHI4, Uniswap), YOLO Protocol (UHI5, Across+Circle+Ink+Uniswap — **4 tracks**), Bonded Hooks (UHI6, Uniswap)
- **Cross-Chain & Routing — 30%:** Liquidity Oracle (UHI4, EigenLayer), RampHook (UHI5, Across), OpSwap (UHI6, Uniswap)
- **MEV & Execution — 29%:** Detoxer (UHI4, Uniswap), FrontrunThis (UHI5, EigenLayer+Uniswap), LVR Auction Hook (UHI6, EigenLayer)
- **Security & Compliance — 19%:** PumpUp (UHI4, Arbitrum+EigenLayer), kvhook (UHI5, Ink), AlphaEngineHook (UHI6, EigenLayer+Fhenix)
> Same post: 1,375 applications / 50+ countries; 260 graduates (cohorts 4–7); 241+ hooks shipped; 313,533+ pools using alumni hooks; $697,354,633+ alumni volume. Alumni companies: LP Hub (UHI5), Harbor/Lighthouse (UHI4, "$1.5M pre-seed"), Numo (UHI1), Flaunch (UHI1, "$100 million in trading volume", "$6 million TVL"), Fiet Protocol (UHI3), Levery (UHI1).

---

## 2. SATURATED LANES — be blunt

Keyword matches over Name + Description + Tags + Integrations across all 662 submissions. `prized` = how many of those matches carry ≥1 prize. **Categories overlap; do not sum.**

| Rank | Lane | Submissions | Prized | Verdict |
|---:|---|---:|---:|---|
| 1 | **Dynamic fee** (volatility/vol-scaled/adaptive/directional) | **189** (29% of everything) | 42 | **Dead lane.** This is a curriculum exercise. Nezlobin directional fee alone appears repeatedly. Do not submit "a dynamic fee hook." |
| 2 | Cross-chain (CCIP/CCTP/Across/bridge/Reactive) | 142 | 27 | Extremely crowded; 130 rows mention Reactive Network. Cross-chain is table stakes, not a differentiator. |
| 3 | **MEV / sandwich / frontrun / toxic flow (all forms)** | **139** | 30 | **This is literally the UHI10 theme, and it is the 3rd most-built lane in history.** Peak was UHI6 (30) / UHI7 (28) / UHI8 (26). |
| 4 | Oracle / TWAP hooks | 108 | 25 | Saturated. Median oracle, geomean oracle, truncated oracle, volatility oracle all exist. |
| 5 | Impermanent loss / hedging / delta-neutral | 81 | 20 | Last cohort's theme; 7 of 12 UHI9 winners live here. Freshly exhausted. |
| 6 | KYC / compliance / permissioned pools | 72 | 16 | Old, well-covered, not on-theme. |
| 7 | **FHE / dark pools / encrypted orders** | **66** (43 FHE + dark-pool overlap) | 6 | Concentrated in UHI6 (30) + UHI7 (31) when Fhenix was a headline sponsor. **6/66 prize rate — the worst conversion of any large lane.** Atrium explicitly lists this under "AVOID". |
| 8 | **LVR / loss-versus-rebalancing** | **55** | 16 | Peak **UHI9 = 20 submissions**, UHI8 = 14. Atrium's "53 LVR-auction submissions — 19 in UHI9 alone" reproduces almost exactly. **AVOID list.** |
| 9 | Perps / derivatives / options | 53 | 17 | Crowded but decent conversion; off-theme for UHI10. |
| 10 | Auto-rebalancing LP | 40 | 8 | Curriculum-adjacent (JiT Rebalancing is taught). |
| 11 | Rehypothecation / idle capital → Aave/Morpho/ERC-4626 | 38 | 10 | Taught concept; ~40 versions exist. |
| 12 | Launchpad / anti-snipe / token launch | 37 | 13 | Crowded, off-theme. |
| 13 | CoW / coincidence of wants | 32 | 9 | Taught in the curriculum. UniCow, UniCowV2, EigenMatch, CoWSwap, IntentPool, Crow, CrossHedge, Invariant, Strata all exist. |
| 14 | Trader reputation / risk scoring | 31 | 7 | Glyph, Maiat, Invariant, Strata, DeLi, ChainSniper. Growing fast. |
| 15 | Loyalty / volume fee discount | 24 | **2** | Terrible conversion. Brevis explicitly rules the ZK version "not eligible as it has already been built". |
| 16 | MEV auction / recapture specifically | 18 | 8 | Best conversion rate in the MEV family (44%), but Atrium flags it as over-built. |
| 17 | Sandwich protection specifically | 13 | 4 | Smaller than you'd expect. See White Space. |
| 18 | TWAMM | 10 | **0** | **Ten submissions, zero prizes.** Do not build a TWAMM. |
| 19 | Commit-reveal / randomized delay ordering (narrow match) | 6 | **0** | Narrow keyword match gives 6; broadening to include async/batch gives **17**, matching Atrium's "18 submissions across 9 cohorts". **Zero prizes on the narrow set.** |
| 20 | Batch auction / batch clearing | 1 | 1 | VeiledBatch (UHI7, Fhenix Prize). Effectively unexplored inside UHI. |

### Fact-check of Atrium's own saturation claims (brainstorm p.6–7) against the raw 662 rows
| Atrium's claim | My independent count | Verdict |
|---|---|---|
| "73 FHE/dark-pool submissions" | 66 with my regex (`fhe|fhenix|homomorphic|dark pool|encrypted order|cofhe`) | **Substantially confirmed** — gap is keyword breadth, not a false claim |
| "53 LVR-auction submissions — 19 in UHI9 alone" | 55 LVR-matching; **20 in UHI9** | **Confirmed** |
| "18 submissions across 9 cohorts use randomized delay or commit-reveal" | 17 on the broad pattern (`commit-reveal\|randomi[sz]\|delay\|async\|vrf\|batch`) | **Confirmed** |
| "51 submissions target cross-chain LVR, almost all via Reactive Network" | 130 rows mention Reactive; 142 cross-chain; 55 LVR — intersection plausible but I did not isolate it exactly | **Plausible, not independently verified** — marked INFERRED |
| "None of 660 past submissions integrate Flashbots, CoW Protocol, Aegis, Skip, Anoma, or Osmosis" | `flashbots` → **0**. `cow protocol` → **0**. `skip protocol` → 0. `anoma` → 0. `mev-blocker`/`mevblocker` → 0. `suave` → 0. `uniswapx` → 0. `0x protocol` → 0. `api3` → 0. `chronicle` → 0. `osmosis` → **1** (`hookeeper`, UHI9). `aegis` → 4, but all are projects *named* AegisHook/Aegis, not integrations of a protocol called Aegis. `cowswap` → 1, but that is the UHI2 project *named* CoWSwap, not an integration of CoW Protocol. | **CONFIRMED, and this is the single most actionable fact in the whole research pass.** Also of note: `1inch` → 1, `pyth` → 6. |
| "Only one team has routed retail and whale flow differently" (Tidehook) | Consistent with my data — no other flow-segmentation match surfaced | Confirmed as far as keyword search reaches |

---

## 3. WHITE SPACE

These are **observations from the data**, not aspirations. Each is a query I ran against all 662 rows; the counts are what came back.

**W1 — VRF / probabilistic settlement: 1 match in 662, and it isn't this.**
Query `vrf|probabilistic settle|randomness beacon` returns exactly one row: `RaffleHook` (UHI5) — a lottery, not a settlement mechanism. Meanwhile "Async Swap Fulfillments … pick an unfulfilled swap and execute it [at a random time] through VRF Oracles" is **taught in the UHI curriculum** and appears as official prompt example #2 ("probabilistic settlement hooks"). A mechanism that is taught, requested by name, and has zero implementations in nine cohorts is the clearest gap in the dataset. Atrium independently reached the same conclusion (brainstorm p.5, "Probabilistic Settlement Hook: settle at one of several pre-committed prices via VRF, so searchers can't precompute the exact fill price").

**W2 — Builder attestations / proposer commitments: 0 matches in 662.**
Query `builder attest|block builder|proposer commit|preconf` → **zero**. Nobody has touched block-builder-aware or preconfirmation-aware hook logic, despite Unichain being a sponsor with a fast-block (Flashblocks, 200ms) architecture that only one project (PerpHinge, UHI8) even references.

**W3 — Searcher bonding / slashing for priority access: 0 matches in 662.**
Query `searcher bond|bond.*(priority|slash)|slash.*searcher` → **zero**. Note the contrast: 22 EigenLayer prizes exist and slashing language appears in AVS descriptions, but nobody has applied bonding-and-slashing *to searchers* as the MEV-defense primitive.

**W4 — LP governance over the MEV mechanism itself: ~0 matches.**
Query `lp.*(vote|govern)|per-pool govern|govern.*auction` → 1 weak match (`Safu Hook`, UHI4). Fifty-five LVR/auction projects exist and **not one lets LPs choose the auction mechanism or the revenue split for their own pool.** Every one hardcodes the designer's split.

**W5 — Real integration with an actual private-orderflow venue: 0 matches.**
Official prompt example #4 is literally "Hybrid routing between private orderflow systems (CoW, Flashbots Protect) and Uniswap." Flashbots: 0. CoW Protocol: 0. MEV-Blocker: 0. Thirty-two projects implement *CoW-style* matching from scratch; **zero connect to the real thing.** Atrium says a genuine integration here is "close to guaranteed differentiation" — and the data supports that claim.

**W6 — Volatility-scaled delay length: effectively 0.**
All delay/async hooks found use fixed windows (AsyncSwapHook: fixed 24–84s). Nobody ties delay duration to realized volatility, despite 189 dynamic-fee hooks proving the volatility-measurement machinery is well understood in this cohort's toolchain.

**W7 — Batch clearing as a clean auditable hook: 1 in 662.**
VeiledBatch (UHI7) is the only batch-auction winner, and it is entangled with FHE. Angstrom-style batch clearing as a standalone, auditable, non-FHE hook does not exist in the incubator.

**W8 — Flow segmentation (retail vs. toxic): 1 in 662.**
Tidehook (UHI8) alone. Open problem #3 as stated by the organizers — "Dynamic fees alone can't distinguish 'good' retail flow from 'bad' toxic flow" — has essentially one prior attempt, against 189 dynamic-fee hooks that all fail at exactly this.

**Honest counterweight:** white space in this dataset also correlates with *difficulty* and with *not being demoable in three weeks*. W2 (builder attestations) has zero entries partly because there is no clean on-chain source of builder attestations to read on a testnet. Treat "nobody built it" as a hypothesis about difficulty as much as about opportunity. W1, W4, W6 and W8 look tractable in three weeks; W2 and W5 carry real integration risk.

---

## 4. PATTERNS IN WINNERS

Derived from the 662/148 dataset. Each has its supporting number.

**P1 — Partner integrations nearly double your odds. This is the strongest measurable signal in the data.**
- ≥1 declared integration: **107/389 prized = 27.5%**
- Zero integrations: **41/273 prized = 15.0%**
- 2 integrations: 35/119 = 29.4% · 3 integrations: 4/5 = 80.0% (n too small to trust)
Partly mechanical — sponsor tracks only award integrators. But even the Uniswap Prize (77 of 148 awards) skews to integrated projects. Multi-track winners are common: YOLO Protocol took 4 tracks (Across+Circle+Ink+Uniswap), ParaDex took 2, FrontrunThis took 2, LaunchGuard took 2, AlphaEngineHook took 2.

**P2 — The prize rate is collapsing as cohorts grow. Assume ~15%.**
UHI1 33.3% → UHI3 32.3% → UHI5 31.7% → UHI6 22.8% → UHI7 17.3% → **UHI8 14.6%** → UHI9 17.6%. UHI8 had 158 submissions. Plan for a field of 100–160 and a ~1-in-7 chance at any prize.

**P3 — Winners match the cohort theme, heavily.**
7 of 12 UHI9 winners were IL/yield-structuring in the IL/yield cohort. UHI8 winners are dense with specialized-market plays (ParaDex perps, StableStream stablecoin manager, DobDex RWA, Proven Protocol launches). **Off-theme submissions win the General Prize occasionally, not the Uniswap Prize.**

**P4 — Winning descriptions state a *mechanism*, not a benefit.**
Compare a winner — EvenFlow: "escrows the toxicity premium during adverse flow and drips it back to in-range LPs once the market goes quiet" — against a non-winner's typical "protects LPs from MEV." Winners name the state they keep, the trigger, and the settlement path. Given the rubric (30% Original Idea + 25% Unique Execution), the *description itself* is doing scoring work. Directory descriptions are visible to judges.

**P5 — "Novel primitive on top of a hook" beats "hook that improves a metric."**
UHI9's General Prize set: PT/YT splitting (Mochi Yield), senior/junior tranching (Unistrata), fee-token vs IL-token split (Schizō), propAMMs on EVM (HyFi), IL insurance marketplace (BackStop), on-chain IL insurance (Indemnify). Every one creates a *new tradeable object*. Very few winners are "the same pool, tuned better."

**P6 — Deployment is not what wins; tests/frontend are the gate.**
Guidelines p.8 explicitly: "Testnet deployment isn't mandatory." No correlation between mainnet/testnet deployment and prizes is observable in the directory (the field doesn't exist). Gate 1 asks for tests **or** a frontend, nothing more.

**P7 — Demo quality is real but small, and is scored separately from winning.**
Presentation Pitch is 10% of the rubric. The guidelines deck's own "HIGH-SCORING EXAMPLES" list includes **ShadowBook Hook, which won no prize**, and two entries (`Hookupasar`, `Addressing Gas Volatility in DeFi`) that don't appear in the directory under those names. A great video is necessary-ish (AI voices block you from Demo Day outright) but does not carry a weak mechanism.

**P8 — Sponsor concentration: the Uniswap Prize dominates.**
148 prized projects hold **171 total awards** (23 projects won more than one track). Uniswap Prize appears **77 times — 45% of all awards, and 52% of prized projects hold one.** Then EigenLayer 22, Brevis 14, Reactive Network 10, General 10, Fhenix 6, Flaunch 6, Arbitrum 6, Chainlink 5, Unichain 5, Circle 4, Across 4, Ink 2. If you optimize for one track, the Uniswap Prize is by far the largest pool — and it is the one most tightly coupled to the cohort theme.

**P9 — THIN EVIDENCE on causation.** Atrium publishes *that* a project won and *which track*, never *why*, never a score, never a rank. Every "why" above is either an organizer quote (rare) or an inference from the winner/non-winner distribution. The one first-hand winner account located (CrossHedge author, UHI9) returned HTTP 403 and is unread. **Anyone extending this research should try to reach that post through another route — it is the highest-value unread source.**

---

# FOLLOW-UP — 2026-08-26 (CrossHedge "why I won" recovery attempt)

## F1. The only first-hand winner account: **PARTIALLY RECOVERED — article itself still UNREAD**

**Every direct route failed.** Documented so nobody repeats them:

| Route | Result |
|---|---|
| `blog.blockmagnates.com/...` via WebFetch | 403 |
| `coinsbench.com/...` (mirror found via search) via WebFetch | 403 |
| `coinsbench.com/...` via curl w/ browser UA | 403 — **Cloudflare block page: "You are unable to access medium.com"** (both publications are Medium-hosted) |
| `medium.com/blockmagnates/...` | 403 |
| `r.jina.ai` proxy | 401 — "blocked from performing anonymous queries due to bad network reputation" |
| `archive.org` Wayback availability API | **no snapshot exists** (`archived_snapshots: {}`) |
| `archive.ph/newest/...` | 429 rate-limited, no snapshot returned |
| `freedium.cfd` | connection failed (HTTP 000) |

**What was recovered — via search-engine snippets ONLY, not by reading the article.** Flagged as such because it is a search engine's paraphrase, not quotable source text:
- Author: **Jay Makwana**. Project: **CrossHedge**, won the **Uniswap Foundation prize track at UHI9**.
- Stated framing: the author had "spent years… thinking about how liquidity providers lose money to volatility" and on entering UHI9 decided to build something that "treats that leak as a cash flow to capture."
- Core insight as described: CoW Protocol's idea is that opposing *trades* already exist in order flow and can be matched peer-to-peer before touching the AMM. **CrossHedge applies the same idea one layer up the stack** — opposing *LP risk* already exists, but sits on different chains, blind to each other. An ERC-4626 vault is the always-available counterparty.
- The write-up is described as covering "the actual mechanism, Uniswap v4 hook internals, the cross-chain matching engine, and design decisions that made the project work **beyond just a demo**."

**What generalizes — marked INFERRED, since the author's actual words on judging were never read:** the recovered framing is a *transplanted-primitive* pattern — take a mechanism proven at one layer (CoW matching of swaps) and apply it at an adjacent layer (matching of LP risk). That maps directly onto the 30% "Original Idea" weight without requiring an unprecedented invention. This is consistent with pattern **P5** above (winners create a new tradeable object / new primitive), derived independently from the 148-winner set.

**Still UNKNOWN and likely unknowable from public sources:** anything the author said about what judges actually responded to, the judging process, or scoring. **No source in this entire research pass states why any specific project won.** Treat P1–P8 as correlations over 662 rows, not as causes.

## F2. Track structure (see HACKATHON_CONTEXT.md → FOLLOW-UP F2 for the full answer)
No security / tooling / infrastructure / DX track exists in any source. An off-theme project's open shots are **General Prize**, **Unichain ("best innovation of any kind")**, any **sponsor track you genuinely integrate**, and — on the evidence — the **Uniswap Prize**, which is *not* strictly theme-gated: in UHI9's IL & Yield cohort it went to **Orbital**, an N-dimensional stableswap curve with no IL/yield mechanism.
