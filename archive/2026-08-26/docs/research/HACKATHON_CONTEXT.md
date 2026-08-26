# HACKATHON_CONTEXT — UHI10 Hookathon (Sustainable Liquidity & MEV Protection)

> Research date: **2026-08-26**. Submission deadline is **2026-09-03 23:59 PST** — ~8 days out at time of writing.

---

## PROVENANCE

### Successfully fetched (primary)
| # | Source | How | Notes |
|---|---|---|---|
| 1 | `https://drive.google.com/file/d/1d6Hl-x3euWebEsir5uWLPDC6MbL2fi_x/view` → **UHI_Hookathon_Guidelines_Slides.pdf** (10pp) | WebFetch FAILED (auth wall). Retrieved via `curl "https://drive.google.com/uc?export=download&id=..."`, text extracted with `pypdf`. | Full text obtained. Local copy: `docs/research/data/uhi_hookathon_guidelines.pdf` |
| 2 | `https://drive.google.com/file/d/1Q1-rIQdD6DxhmSriarAwf_hofMvg7TM-/view` → **UHI10 Hookathon Theme Brainstorming Slides.pdf** (8pp) | Same method. | Full text obtained. Local copy: `docs/research/data/uhi10_theme_brainstorm.pdf` |
| 3 | `https://atriumacademy.notion.site/atrium-academy-request-for-hooks` | WebFetch returned only the string "Notion" (JS SPA). Retrieved via Notion public API `POST /api/v3/loadPageChunk`, pageId `20f5f044-4abe-8058-8371-e59b27a3e714`, 3 chunks, 268 blocks incl. 16 tables / 126 table rows. | Full page reconstructed. |
| 4 | `https://atriumacademy.notion.site/hook-directory` (= `https://projects.atrium.academy/UHI-Hook-Directory-ac153130871b49a2b1274906580e7869`, = `hooks.atrium.academy`) | Same SPA problem. Retrieved via `POST /api/v3/queryCollection`, collection `fd147a64-8e39-4910-b5f3-f6ed78a1c5bc`. | **662 rows** with Name/Cohort/Prize/Tags/Integrations/Description. Local copy: `docs/research/data/hook_directory_662.json` |
| 5 | `https://github.com/fewwwww/awesome-uniswap-hooks` | WebFetch, worked. | ~150 named hook ideas/projects. |
| 6 | `https://blog.atrium.academy/uniswap-hook-incubator-2025-wrapped` | WebFetch, worked. | 2025 aggregate stats + category breakdown. |
| 7 | `https://atrium.academy/sponsors` | WebFetch, worked but **thin** — no UHI10-specific sponsor list or prize amounts published there. |

### Could NOT access (tried, failed — contents NOT guessed)
| Source | What was tried | Result |
|---|---|---|
| `https://x.com/AtriumAcademy/status/2047359898237952183` (UHI10 theme/curriculum thread) | WebFetch | HTTP 402. Only the search-snippet title is known; body not read. |
| `https://blog.blockmagnates.com/how-i-won-the-uniswap-foundation-prize-track-at-uhi9-...` (CrossHedge author's "why I won" post) | WebFetch | HTTP 403. **This is the single best missing source for "why winners won".** |
| `https://atriumacademy.typeform.com/to/uySbksmY` (idea intake form) | not fetched | form, no content |
| Sponsor Hooks page w/ "individual partner criteria" (referenced on guidelines p.7) | no URL published in the deck | not located |
| Judging rubric beyond the deck's 5 weights | searched | no more granular rubric published |
| Discord `#hook-ideas`, `#form-a-team`, `#dev-support` | private | inaccessible |

---

## 1. HARD REQUIREMENTS — GATE 1 (BINARY, PASS/FAIL)

> Source: UHI_Hookathon_Guidelines_Slides.pdf, p.5 — header reads *"BINARY QUALIFICATIONS · PASS/FAIL · MISS ONE = NOT JUDGED"* / *"Miss any of these seven, and it isn't judged."*

The slide is titled "seven" but **lists eight bullets**. Both facts are recorded verbatim; the discrepancy is the organizer's, not an inference.

| # | Gate | Exact wording |
|---|---|---|
| 1 | Public GitHub Repo | "Repo must be public (private repos need pre-clearance)." |
| 2 | Demo/Explainer Video | "≤5 min, no AI voices — or it isn't reviewed." |
| 3 | Valid Hook | "A real Uniswap v4 hook, or a direct interface to one." |
| 4 | Written & Workable Code | "Some code must be newly written during the Hookathon." |
| 5 | README with Partner Integrations | "List them, or state 'No partner integrations.'" |
| 6 | New Code for Returning Teams | "Previously judged code doesn't count again." |
| 7 | Originality | "No copied code from workshops, curriculum, or past projects, unless credited." |
| 8 | Tests OR a Functioning Frontend | "A front-end is not required — but skip making one and you need enough test cases for judges to verify functionality. **No tests and no front-end means no prize judging.**" |

## 2. SCORED EVALUATION — GATE 2

> Source: guidelines p.6. "Scored 0–5 per category (0 = Poor/Not at all, 5 = Exceptional), then weighted into a final score."

| Weight | Criterion | Organizer's definition |
|---|---|---|
| **30%** | Original Idea | "Novelty of the concept itself — is the idea new to Uniswap or DeFi?" |
| **25%** | Unique Execution | "Distinctiveness of how it's built: architecture, integrations, UX." |
| **20%** | Impact | "Potential value to users, the Uniswap ecosystem, or DeFi." |
| **15%** | Functionality | "How well the hook works as outlined; robustness and completeness." |
| **10%** | Presentation Pitch | "Clarity and quality of the video explanation/demo." |

**Read this honestly:** 55% of the score is *novelty + distinctiveness of construction*. Only 15% is "does it work well". A polished, robust, unoriginal hook caps out around a mediocre score. Conversely a novel mechanism with thin implementation still scores. This rubric explicitly rewards mechanism design over engineering polish.

## 3. DATES & LOGISTICS

| Item | Value | Source |
|---|---|---|
| Hookathon window | **August 17 – September 3, 2026** | brainstorm p.1 |
| Project Idea intake | by **August 17** | guidelines p.3 |
| Progress Update 1 | by **August 24** | guidelines p.4 |
| Progress Update 2 | by **August 31** | guidelines p.4 |
| **FINAL SUBMISSION** | **September 3, 11:59pm PST** | guidelines p.4 (caps in original) |
| Demo Day | **September 11, 2026** | brainstorm p.1, p.8 |
| Team size | Up to 4 devs; solo allowed ("solo devs, duos, and full teams have all won before") | guidelines p.1–2 |
| Submissions per team | "one hook project per developer/team for Final Submission" | guidelines p.2 |
| Project ID format | `HK-UHI10-####` (from submission email) | guidelines p.4 |
| Post-submission edits | email `team@atrium.academy` | guidelines p.4 |
| Result | project appears at `hooks.atrium.academy` | guidelines p.4 |

**PRIZE POOL — the deck contradicts itself.** p.1 says "PRIZE POOL $15,000". p.7's section header says "SUBMISSION + **$20,000** IN PRIZES" while the same page's body says "PRIZE POOL **$15,000+** … Sponsored by Uniswap Foundation and Atrium Academy. Split across multiple winning projects". Treat **$15,000+** as the stated figure and $20,000 as an unexplained header. Historical context: "400+ developers have shipped 660+ hooks and won $130,000+ in prizes" across the first nine cohorts (p.2); `atrium.academy/sponsors` cites "$235,000 in developer prizes" / "$260K+ in prizes awarded" all-time (larger figures, different scope — not reconciled).

## 4. SUBMISSION CHECKLIST + GOTCHAS

Checklist (p.7): (1) GitHub repo link, (2) demo video link, (3) **either** test cases **or** a working frontend judges can interact with.

Gotchas (p.8), verbatim-ish:
1. Submission Type — select "Uniswap Hook Incubator (UHI)."
2. Cohort field — current devs list their **current** cohort; alumni list the cohort they graduated from (never the cohort the hookathon is for).
3. Partner integrations — "only select partners you actually built for. Future or planned integrations don't count."
4. Links — demo video ≤5 min, no AI voices, public repo(s) "pointing at the right branch."
5. **"Testnet deployment isn't mandatory"** — unit tests OR a basic frontend suffices.

Video rules (p.9). Cover: the problem you're solving; how your hook works; how it compares to existing solutions. Do not: exceed 5 minutes ("judges stop watching after that"); use AI voices ("marks down your score **and blocks you from Demo Day**").

**Named "HIGH-SCORING EXAMPLES" (p.9):** Hookupasar · modl · Addressing Gas Volatility in DeFi · ShadowBook Hook · VolVantage · MaybeSwap · ParaDex.
Cross-checked against the 662-row directory:
- `modl` (UHI7) — Uniswap Prize; `VolVantage` (UHI8) — Uniswap Prize; `MaybeSwap` (UHI8) — General Prize; `ParaDex` (UHI8) — Unichain + Uniswap Prize.
- **`ShadowBook Hook` (UHI7) won NO prize.** `Hookupasar` and `Addressing Gas Volatility in DeFi` are **not in the directory under those names**.
- ⇒ This list is "good demo videos", *not* "winners". Presentation is only 10% of the score, and a great video does not carry a project.

## 5. THEME — "SUSTAINABLE LIQUIDITY AND MEV PROTECTION" IN THE ORGANIZERS' WORDS

**From the Request for Hooks page (Uniswap team's framing):**
> "🏁 UHI10 Hookathon: Sustainable Liquidity & MEV Protection — The goal here is to reduce value leakage from LPs and make volatile-pair liquidity sustainable at low fees — pushing hook innovation toward fair, MEV-protected execution that lets LPs compete on any asset pair."

**From the brainstorm deck (Atrium's framing), p.2:**
> "Turn Uniswap into a fair-flow AMM layer for volatile pairs. UHI10 is about hooks that protect LP's from MEV and sandwich attacks while making volatile-pair liquidity sustainable at low fees. **Neutralize the attack. Recapture the value. Beat Aerodrome on the pairs that matter most.**"

**The five open problems (brainstorm p.2, verbatim):**
1. LPs lose value to sandwich attacks and toxic order flow, especially on volatile pairs.
2. Arbitrageurs extract loss-versus-rebalancing (LVR) value that never reaches LPs.
3. Dynamic fees alone can't distinguish "good" retail flow from "bad" toxic flow.
4. Public mempools and predictable ordering make transactions easy to front-run.
5. Private orderflow systems (CoW, Flashbots Protect) sit off to the side of Uniswap.

**Mission statement (p.8):** "Protect LPs · kill the Sandwich 🔪🥪"

### Official prompt examples "direct from Uniswap" (brainstorm p.3 / RfH table — identical five)
1. Hooks that randomize swap ordering or delay callbacks to neutralize sandwiching
2. Time-weighted execution windows or probabilistic settlement hooks
3. Fee-rebate systems tied to order flow quality
4. Hybrid routing between private orderflow systems (CoW, Flashbots Protect) and Uniswap
5. Protocol-native MEV auction hooks where LPs recapture a share of extracted value

### The stated WIN CONDITION (brainstorm p.7, verbatim)
> **"Combine defense and recapture.** Ordering protection alone is a shield. Auction-based recapture alone is a redistribution. **Pair them for the strongest pitch.**"

Plus, same page:
> **AVOID:** "FHE dark pools & LVR auctions are over-built. 73 FHE/dark-pool submissions and 53 LVR-auction submissions — 19 in UHI9 alone. Need a sharp mechanism or sponsor differentiator."
> **AIM FOR:** "Real partner integrations. None of 660 past submissions integrate Flashbots, CoW Protocol, Aegis, Skip, Anoma, or Osmosis. A genuine integration is close to guaranteed differentiation."

*(Verification of these three claims against the raw 662-row data is in `WINNERS_LANDSCAPE.md` → "Fact-check". Short version: the Flashbots/CoW/Skip/Anoma claim holds; the FHE and delay-hook counts do not reproduce exactly with keyword search.)*

---

## 6. ATRIUM'S "REQUEST FOR HOOKS" — FULL LIST

> Source: `atriumacademy.notion.site/atrium-academy-request-for-hooks`, reconstructed via Notion API. Framing quote:
> "A Request For Hook (RfH) is a community-submitted idea or ecosystem need for a Uniswap v4 hook — a feature, mechanism, or experiment someone wants to see built… This is a non-exhaustive list as there are infinite range of hooks that can be built on v4."

### 6a. Hook ideas taught in the UHI curriculum (⚠ these are the *least* original things you can submit — Gate-1 originality rule explicitly bars uncredited curriculum code)
| Hook | Description (condensed from source) |
|---|---|
| Gas Price Fees | Dynamically modifies LP fees against moving-average on-chain gas price; lower fees in high gas, higher in low gas. |
| JiT Rebalancing Hook | LPs send tokens to the hook, not PoolManager. Full-range by default; on a "large" swap, concentrates all managed liquidity ±1 tick around current tick, then rebalances back to full range after. |
| Nezlobin's Directional Fee | Asymmetrically raises/lowers fee in **one direction** to deter arbitrage-driven toxic flow and mitigate IL. |
| CSMM Custom Curves | Constant-sum invariant as a NoOp hook. |
| LAMMBert | Custom curve following the Lambert W function (NoOp). |
| Async Swap Fulfillments | Accept input tokens, NoOp the swap, later execute at a "random" point in time via VRF oracle — explicitly framed as sandwich deterrence. |
| Coincidence of Wants (CoW) | NoOps the swap, holds orders unfilled for a threshold number of blocks hoping for a CoW; falls back to AMM. |

### 6b. Uniswap Ecosystem Requests — updated February 2026 (the freshest signal on the page)
| Request | Description |
|---|---|
| Perp DEXs built with hooks (Unichain) | Perpetual DEX designs using hooks: margin management, liquidations, incentive mechanisms. |
| JIT liquidity / issuance hooks for new assets | JIT liquidity or issuance for newly launched / illiquid assets; better price discovery, less initial slippage. |
| Stable-focused hooks | Stablecoin liquidity management, incentive design, stability mechanisms. |
| Smart borrow & leveraged liquidity hooks | Borrow against LP positions to deepen effective liquidity on the same base capital. Directions given: borrowing against LP positions and reinvesting into the same pool; dynamic LTVs / adaptive rates / risk-aware borrowing; flash-loan leverage applied only to the active tick. |
| LST-optimized hooks | Rebasing behavior, yield distribution, pricing adjustments for stETH-likes. |
| Liquidity locking & token launch hooks | Lock liquidity or condition unlocks on time, volume, or market behavior. |
| NFT strategy token hooks (Tokenworks-inspired) | Fees used as protocol revenue to accumulate NFTs; "suitable for experimental or solo builders". |
| External revenue–driven liquidity incentives (Liquity v2 / BOLD-inspired) | Use external/protocol revenue streams to incentivize liquidity. |

### 6c. Uniswap Ecosystem Requests — updated April 2025 (older, heavily mined)
Dynamic Fee Hook · Rehypothecation Hook · Custom Curve Hook · Asynchronous Swap Hook · **MEV-Mitigating Hooks** ("template strategies to prevent … front and backrunning, sandwiches, JIT") · Reward Aggregator · Liquidations Hook · Auto-Position Rebalancing · Oracle Hooks · Permissioned Pool Hook · Auto-Hedging Hook · TWAMM Hook · LRT Liquidity Hook (Sanctum analogue) · **Internalized MEV** ("LPs earn MEV profits. E.g. through offchain/onchain ahead of time bidding for top-of-block transaction rights") · Oracleless Lending Protocol · Tornado Cash on Hooks · Hook Safety as a Service · Gasless Swaps · Keeper Activity Hook · UniBrain Hook · Value Accrual Designs · Auction-Managed AMM.

### 6d. 2026 Hookathon theme tables (all three cohorts, for context on what "on-theme" means)
**UHI8 — Specialized Markets:** Hook Templates (RWA/stable/long-tail) · Chain-Localized Routing · Large-Cap Execution (block-based execution / segmented order flow) · Dynamic Stablecoin Managers · Non-Fungible LP Positions.
**UHI9 — Impermanent Loss & Yield Systems:** IL Insurance Hooks · YieldBasis/Pendle-style Fixed Income · Delta-Neutral Hooks · Fee-Smoothing Hooks · Cross-Pool Hedging Routers.
**UHI10 — Sustainable Liquidity & MEV Protection:** Sandwich-Neutralizing Hooks · Time-Weighted Execution Hooks · Fee-Rebate Systems (tied to order-flow quality) · Hybrid Routing Hooks (CoW/Flashbots ↔ Uniswap) · MEV Auction Hooks (LPs recapture extracted value on-chain).

### 6e. Community ideas (attributed)
- **giveTargeted Liquidity** — differentiated fee based on token ownership / loyalty-based fees; could pair with spindl.xyz *(Ani Pai, Dragonfly)*
- **Lending hooks** — borrow liquidity in AMM positions to give traders perp-like exposure *(Derek Walkush, Variant)*
- **Automated liquidity provisioning** — auto-rebalance concentrated liquidity for max yield *(Derek Walkush, Variant)*

---

## 7. SPONSOR TRACKS & THEIR STATED CRITERIA

Sponsors with an ideas section on the RfH page and a corresponding **Prize** value in the hook directory schema: **Reactive Network, Across, Ink, Circle, EigenLayer, Fhenix, Flaunch, Arbitrum (Stylus), Unichain, Chainlink, Brevis** — plus **Uniswap Prize** and **General Prize**. (13 prize values total in the live directory schema; this is the authoritative list, since `atrium.academy/sponsors` publishes no UHI10-specific roster.)

Sponsor-specific requirements worth flagging:

- **EigenLayer** — pick *AVS Builder* (implement an AVS) or *AVS Consumer App* (use an existing mainnet AVS). Requires: "Describe your EigenLayer integration architecture in sufficient detail in your Readme.md or presentation"; "Be sure to include a clear reference to your EigenLayer AVS or AVS integration code." Explicitly warns: "Review prior hook contributions … such as coincidence of wants, price and volatility Oracles, dark pools. **Choosing something new and novel that has not been implemented before will give you the best chance to win prizes.**" Their listed ideas (CoW to cut taker fees, dynamic vol fees, LST position adjustment, dark pools, **LVR first-in-block auction paying LPs instead of validators**, shared cross-chain state) are all heavily built already.
- **Fhenix** — **hard gate:** "Valid submissions must use operations from the Fhenix FHE library in your smart contracts. (E.g. FHE.add() sub()...)". Templates: `marronjo/fhe-hook-template`, `marronjo/iceberg-cofhe`, `marronjo/fhe-market-order`, `FhenixProtocol/cofhe-mock-contracts`, `FhenixProtocol/cofhe-scaffold-eth`. Ideas: FHE Limit Order, FHE Market Order, FHE TWAMM, Encrypted Dutch Auction, Private Portfolio Rebalancing.
- **Reactive Network** — no specific requests. "They are excited to provide the infrastructure." RSCs watch events on chain A and fire callbacks on chain B (or A). Requires deploying two extra contracts (one on Reactive, one on destination). Suggested pairings: liquidations, async swaps, oracles, permissioned pools, NFT/proof-of-ownership, arbitrage, liquidity optimization, TWAMM, oracleless lending, hook-safety-as-a-service, UniBrain.
- **Unichain** — "the Unichain prize track will reward the **best innovation of any kind**" (i.e. effectively an open track). Specific asks: Derivatives/Perps ("significant trading activity on Unichain with limited ability to hedge on-chain, making short positions especially valuable for active LPs"); Tokenized Strategies / Yield-Bearing Tokens.
- **Across** — expects you to *extend your existing UHI codebase* with cross-chain features. 8 tabulated ideas incl. Crosschain Gas Price Optimization, Crosschain Arbitrage, **Crosschain CoW**, Crosschain Rehypothecation, Crosschain Custom Curve, Crosschain Reward Aggregator, **Crosschain Shared State (AVS-enabled)**, **Crosschain CoW to Reduce Taker Flow (AVS-enabled)**.
- **Circle** — CCTP v2, Circle Paymaster (gas in USDC), Circle Wallets, Compliance Engine. Ideas: auto-replenishing cross-chain USDC pools, pay-per-swap gas in USDC, streaming USDC LP rewards, real-time FX (USDC↔EURC) swaps, compliance-aware swap limits.
- **Ink** — Permissioned Pools via Kraken Verify, No Idle Funds, Degen Pools, Derivatives, Gamified Pools, **CEX/DEX Merge** (merging CEX and DEX books for arbitrage / aggregation / minimal slippage).
- **Arbitrum Stylus** — either unlock non-EVM-feasible compute in Rust, or rewrite Solidity hooks in Stylus **with detailed gas benchmarking comparisons**. Categories: Pricing & Profit, Risk Management & Security (ML volatility model in Stylus; median price oracle), Liquidity & Yield Optimization (TWAMM), UX (limit orders), Social & Gamified (loyalty tier fees).
- **Chainlink** — Data Feeds / Functions / Automation / CCIP / VRF-adjacent. Ideas: dynamic fees from external data, cross-chain pool creation via CCIP, cross-chain token transfers post-swap, auto add/remove liquidity on thresholds, order execution on real-world events, on-chain insurance triggers. Notes an async pattern: "trick the before swap hook to not execute the swap, and instead initiate a new Chainlink Functions call, then in the callback function initiate the swap again."
- **Brevis** — ZK proofs over historical on-chain data. **Explicitly disqualifies one idea:** trading-volume-based fee discount is "not eligible as it has already been built". Remaining: LVR compensation from market-volatility indexes, retrospective mining rewards weighted by fee actually generated per LP position, token-holding-based fee discount, on-chain OG status, user acquisition via on-chain profiling.
- **Flaunch** — Token Fee Claimer, Migration Adapter, Liquidity Funding Staker, Discovery Launchpad Migrator.

---

## 8. WHAT THIS MEANS FOR SCOPING (short, and marked)

**INFERRED** (my reading of the above, not organizer statements):
- The rubric (30% originality + 25% execution distinctiveness) plus the organizers' own "AVOID: over-built" slide means *mechanism novelty is the binding constraint*, not code quality. A well-tested dynamic-fee or LVR-auction hook is a mid-table submission by construction.
- Gate 1 is cheap to satisfy and catastrophic to miss. Public repo + ≤5min human-voiced video + README partner-integration line + tests. Testnet deploy is explicitly optional; **do not** spend the last days on deployment at the cost of tests.
- The "win condition" slide (defense + recapture paired) is the closest thing to an explicit scoring hint the organizers published. Take it literally.
- The strongest *differentiator* available per the organizers' own data is a real integration with a party nobody has integrated (Flashbots, CoW Protocol, Skip, Anoma, Osmosis) — but note that none of those are on the sponsor prize list, so it buys rubric points (Unique Execution), not a sponsor prize.

---

# FOLLOW-UP — 2026-08-26 (deadline verification & track structure)

## F1. Is the UHI10 deadline still 2026-09-03? → **NO EVIDENCE OF EXTENSION**

Not "confirmed unchanged" — **no extension announcement was found anywhere I could reach**, and one blind spot remains (below).

**Evidence that the original dates still stand:**
| Evidence | Detail |
|---|---|
| Both UHI10-specific PDFs | "HOOKATHON August 17 - September 3 / DEMO DAY September 11th" (brainstorm p.1, p.8); "DEADLINE ON SEPTEMBER 3RD BY 11:59pm PST" (guidelines p.4) |
| RfH Notion page `last_edited_time` | **2026-08-04 14:23 UTC** — edited 13 days before the hookathon opened; UHI10 theme section intact, no date revision |
| Hook Directory row activity | `Strata` (cohort UHI10) **created 2026-08-19 00:34 UTC** — submissions landing during the stated window |
| Independent web search | Returns "Hookathon runs Monday August 17 to Thursday September 3, 2026, Demo Day Friday September 11, 2026" |
| **`atrium.academy/uniswap` (fetched today)** | Now recruiting the **next** cohort: *"Deadline to apply: 21 September 2026"*, orientation *"October 1, 2026"*, start *"October 2026"*. A UHI10 running into November would overlap the following cohort. |

**Where I looked and found nothing about an extension:** `atrium.academy/uniswap`, `atrium.academy/sponsors`, `blog.atrium.academy` (index scrape returned no post text), `luma.com/0p6uabf2` (renders as "Past Event", no dates exposed), Notion RfH + Hook Directory `last_edited_time` on page/collection/row records, archive.org, and four targeted searches for extension / postponed / rescheduled / "November 2026".

**BLIND SPOT — state this plainly:** `x.com/AtriumAcademy` could not be read directly (HTTP 402 on the status URL; `r.jina.ai` proxy returned 401 "bad network reputation"). Discord `#announcements` is private. **An extension announced only on X or in Discord within the last ~3 weeks would be invisible to this research.** I am not inferring an extension from silence, and I am not certifying the Sept 3 date from silence either.

⚠ Note for the owner: **Progress Update 2 is due 2026-08-31** per guidelines p.4. If a Project ID (`HK-UHI10-####`) was issued, Atrium emails the update forms — **that inbox is the authoritative check on any date change and takes thirty seconds.** Do that before trusting either date. Also note "early November" is almost exactly Sept 3 + 2 months, which is consistent with the owner's recollection but is not itself evidence.

## F2. Track structure — is there a security / tooling / infrastructure / DX track? → **NO SUCH TRACK FOUND**

The live directory schema's **Prize** field has exactly 13 values: Uniswap · General · Unichain · EigenLayer · Brevis · Reactive Network · Fhenix · Flaunch · Arbitrum · Chainlink · Circle · Across · Ink. Twelve are sponsor-named; the thirteenth is "General Prize". **None is a security, tooling, infrastructure, audit, or developer-experience track**, and no sponsor section on the RfH page describes one.

**An off-theme security/tooling project therefore has these shots:**
1. **General Prize** — 10 awards historically; the only track with no sponsor and no theme in its name.
2. **Unichain Prize** — *"the Unichain prize track will reward the best innovation of any kind from builders in the Hookathon"* (RfH, verbatim). Effectively an open track. 5 awards historically.
3. **Uniswap Prize — and this is not strictly theme-gated.** 77 of 171 historical awards. Evidence it isn't theme-locked: in UHI9 (IL & Yield theme) the Uniswap Prize went to **Orbital**, an N-dimensional-sphere stableswap curve — an AMM-design project, not IL/yield. So off-theme work *can* take the Uniswap Prize.
4. Any sponsor track whose tech you genuinely integrate (Reactive, EigenLayer, Chainlink, etc. — the sponsor cares about its own integration criteria, not the cohort theme).

**UNKNOWN:** whether the UHI10 sponsor roster equals the historical 13. `atrium.academy/sponsors` publishes no UHI10 roster or per-track amounts, and the "Sponsor Hooks page" referenced on guidelines p.7 was never located. `atrium.academy/uniswap` states only: *"We've awarded over $260k in developer grants, with every cohort receiving at least $15k. Uniswap Foundation is the title sponsor for the hookathon prize pool. Organizations like Chainlink, Arbitrum, Eigenlayer, and Circle have also sponsored…"* — "$15k per cohort" corroborates the guidelines' $15,000 figure over the stray $20,000 header.
