# IDEAS_FROM_GROK — archaeology of the owner's prior Grok brainstorms

*Mined 2026-08-26. Sources are three local Grok session transcripts plus one X share link.
Triaged against `docs/DECISION_CANDIDATES.md`, `docs/research/WINNERS_LANDSCAPE.md` §2/§3, and
`CLAUDE.md` §5/§6. Prior-art counts are my own regexes over
`docs/research/data/hook_directory_662.json` (662 rows), re-run for this document.*

**Headline: 5 of 29 ideas survive triage as `NEW-WORTH-EVALUATING`, and three of those five are
components rather than submissions. The most valuable thing in these transcripts is not an idea —
it is §4, which contains one protocol fact that breaks SWITCHBACK's stated recapture leg and one
2026 paper that undermines how we plan to pitch it.**

---

## 0. PROVENANCE

| Source | Status | What it gave |
|---|---|---|
| `~/.grok/sessions/%2FUsers%2Fmishoko%2Fprojects%2FUHI10/01a01610-.../` | **READ.** `chat_history.jsonl`, 28 lines, 5 assistant turns. Schema: `{type: user\|assistant\|reasoning\|tool_result, content}`. | Hardcap-era round-2 panel. 2 ideas + the "four cells of fee assignment" taxonomy. Referred to as **Session A**. |
| `~/.grok/sessions/%2FUsers%2Fmishoko%2Fprojects%2FUHI10/01a00f63-.../` | **READ.** `chat_history.jsonl`, 299 lines → 205 KB of natural language across 17 user turns / 38 assistant turns. (`updates.jsonl` is the same content as streaming chunks + tool payloads; not used.) | The real brainstorm. 26 distinct ideas, six adversarial kill rounds, and the genesis of both Hardcap and Assay. Referred to as **Session B**, cited by chat-history line number, e.g. `B/L120`. |
| `~/.grok/sessions/%2Fprivate%2Ftmp%2Fab-SB_L0/01a00c26-.../` | **READ.** 9 lines. | **Contains no hook ideas.** It is a single-shot economic-security exercise on a toy `ShareBank` ERC-4626-style contract (first-depositor / donation share-inflation). Unrelated to UHI10. |
| `https://x.com/i/grok/share/14d5e0dee3194b06ad632fe561546d88` | **NOT READ. Contents not guessed.** | — |

### The X link — every route tried, all failed

| Route | Result |
|---|---|
| `WebFetch` on the URL | **HTTP 402 Payment Required** |
| `curl` w/ browser UA | HTTP 200, 287 KB — **JS shell only.** No `og:description`, no `<title>`, no conversation text in the payload. Verified by grepping the body for `uniswap\|hook\|sandwich\|mev`: the only hits are webpack bundle names (`ondemand.GrokHookContainer`). |
| `grok.x.com/share/<id>` | HTTP 200, byte-identical SPA shell |
| `r.jina.ai` proxy | **HTTP 403** — Cloudflare "Just a moment…" interstitial |
| `nitter.net` | HTTP 200 — **"nitter.net is offline"** |
| `xcancel.com` (nitter mirror) | HTTP 200, 321 bytes — empty |
| `archive.today/newest/…` | **HTTP 404** — no snapshot exists |
| Google cache | HTTP 404 (the endpoint is retired) |
| `api.allorigins.win` CORS proxy | connection failed (HTTP 000) |

**Whatever is in that conversation is not in this document.** If the owner can open it in a logged-in
browser, a copy-paste is worth more than another fetch attempt.

---

## 1. INVENTORY — every distinct idea found

29 rows. Ordered by session, then by where it appears.

| # | Idea (one line) | Source |
|---|---|---|
| A1 | **Unaged fee forfeiture** — seize the JIT's own `feeDelta` into an aged-LP vault, no extra fee on swappers, same-block exit still allowed | A/L27 |
| A2 | **`lpFee = 0` + aged vault** — turn the native fee switch off and route everything through the hook-owned aged vault instead | A/L27 |
| B1 | **Uniform block-clearing ("FairClear")** — custody swaps via `beforeSwapReturnDelta`, clear the whole block's batch at ONE price, auction or donate the residual | B/L92 #1 |
| B2 | **sr-AMM hole-close** — Umbra/OZ start-of-block rule + liquidity added this block cannot service this block's swaps + explicit surplus stream + published `sandwichPnL ≤ 0` invariant | B/L92 #2 |
| B2b | **JIT activation delay alone** (`bornBlock` reservation: ticks minted in block N are reserved to the triggering swap, unusable by any other swap in N) | B/L92 #2, B/L120 N4 |
| B3 | **Real CoW / UniswapX / Flashbots-Protect fallback routing hook** — swap is an intent, try private match first, fall back to the curve | B/L92 #3 |
| B4 | **Vol-scaled async window + retail fast path** — small swaps instant, large/high-vol swaps into a delay window whose length grows with realized volatility | B/L92 #4 |
| B5 | **Slashable sandwich invariant / bonded arb rights** — searchers post a bond for last-look on residual arb; on-chain same-block sandwich PnL is the slash condition | B/L92 #5 |
| B6 | **Pool-as-orderflow-auction** — searchers bid up front for the right to back-run your swap; winning bid split ~50 % swapper / 40 % LPs / 10 % hook (MEV-Share, but the AMM is the auction house) | B/L92 B1, expanded B/L120, B/L142 |
| B7 | **Hook internalizes the CEX–DEX arb** — if `\|poolPrice − oracle\| > fee + gas`, the hook fills the user at no-worse-than-AMM and takes the other side itself, keeping the gap for LPs | B/L92 B2 |
| B8 | **Diamond β-vault / per-block conversion vs futures** — the top-of-block arb executes only `(1−β)·T`; the rest of the inventory move is vaulted and dripped back to LPs | B/L92 B3, B/L120 |
| B9 | **Composable sandwich-unprofitability policy hook** — a hook that wraps another hook/pool and reverts the unlock (or slashes a bond) if a published invariant breaks; modes REVERT / SLASH / LOG | B/L92 B4, B/L120 |
| B10 | **Homeostatic pool** — on-chain PID controller on a health vector (inventory skew, LVR proxy, depth); unhealthy ⇒ raise fee **and** pull JIT from an ERC-4626 sidecar; healthy ⇒ reverse | B/L92 B5, B/L120 |
| B11 | **Session AMM / NYSE opening cross for tokenized stocks on Robinhood Chain** — curve frozen or oracle-banded outside NYSE hours; 09:30 opening cross clears the overnight pile at the official open; gap donated to LPs | B/L120 N1, revisited B/L142 |
| B12 | **Public Equilibrium Skim ("FairFlow without the wall")** — permissionless pool; hook compares realized output to a reference (start-of-block or oracle), takes the excess, 85 % LPs / 15 % hook, with an anti-sandwich lock so the skim is not itself front-runnable | B/L120 N2 |
| B13 | **"I'm Feeling Lucky" rebate rail** — daily `prevrandao`/VRF lottery whose pot is funded **only** from recaptured leftover; tickets issued only to flow that passes a non-toxicity filter; LPs keep a 50 % floor | B/L120 N3 |
| B14 | **Sandwich-safe DualPool for volatile pairs** — Labs/Spark rehypothecation ported off stables, with `bornAt`-tagged ticks reserved to the triggering swap | B/L120 N4, B/L162 |
| B15 | **Launch opening cross** — the first K blocks of a newly initialized pool are one batch at a uniform price; leftover goes into the (already locked) LP position | B/L120 N5 |
| B16 | **The hook performs the back-run itself** — no searchers; the hook is the bot, splits the captured gap ~50/40/10 swapper/LP/hook | B/L142 A |
| B17 | **Same-block on-chain netting** — buys and sells in the same block cancel at mid; only the net touches the curve; no solvers | B/L142 B |
| B18 | **Fill warranty** — if your fill is worse than the start-of-block price, a pot pays you the difference; pot funded from recaptured leftover | B/L142 C |
| B19 | **FlashClear** — treat each 200 ms Unichain Flashblock as the AMM's unit of time; no price path inside a slice; slice leftover to LPs | B/L162 |
| B20 | **Flash-skim** (FlashClear after six adversarial rounds) — per-Flashblock snapshot via the on-chain `FlashblockNumber` contract + JIT lock + real skim vs reference + same-sender cross-slice cooldown | B/L191 |
| B21 | **am-AMM, shipped complete** — auction the *fee-setting manager seat* (explicitly **not** first-in-block rights); bid goes to LPs up front; manager keeps fees low because they want flow | B/L162, B/L233 |
| B22 | **Passive Fee Vault** — never call `poolManager.donate()`; seized fees/penalties go to a hook-owned escrow claimable only by positions whose `lastAddBlock` is already aged | B/L201 |
| B23 | **Split-lane netting** — retail instant lane (aggregator-quotable) + whale lane that nets opposite whales at mid, with a **mandatory** TWAMM-style "next pool action settles you" fallback so a lonely whale waits at most one interaction | B/L201 |
| B24 | **"Protect means you go first next block"** — opt-in `hookData.protect`; the ticket is settled as the FIRST pool action of the next block (Uniswap's own TWAMM no-front-run guarantee) + JIT lock on that settle | B/L233 |
| B25 | **Bonded invariants** — the hook posts bail; fail-closed I1–I6 (only PoolManager may call, take ≤ published cap, no foreign unlock, `hookData` ignored, same-block add→remove reverts, not upgradeable); slash to LPs | B/L246 |
| B26 | **Published immutable extraction cap** — `MAX_TAKE_BPS` fixed in the constructor, the only legal payee is the LP vault, no owner drain, over-cap ⇒ revert the unlock | B/L246, B/L249 |
| C1 | *(none)* — Session C contains no hook ideas | C |

---

## 2. TRIAGE

**Counts: `ALREADY-SHORTLISTED` 3 · `ALREADY-KILLED` 6 · `SATURATED` 11 · `NEW-BUT-BAD` 4 ·
`NEW-WORTH-EVALUATING` 5.**

### ALREADY-SHORTLISTED (3)

| # | Maps to | Note |
|---|---|---|
| B3 | **SLUICE** | Identical in intent. The Grok session flagged the same riskiest assumption we later settled by execution ("does the partner stack actually exist on the demo chain — do not mock it"). It never got as far as reading `ComposableCoW`'s source; we did. |
| B4 | **HASTE** (and white space W6) | Same object: sell/impose delay, keep a retail fast path, scale the window with volatility. Grok never derived the separating condition; our `N_max = 2·(0.581/λ)² − 1` is strictly ahead. |
| B24 | **HASTE**'s deferred lane + the block-open settlement fix | "Settle as the first pool action of the next block" is a *stronger* version of our anti-filler fix, and it is grounded in Uniswap's own TWAMM claim ("she cannot be front-run because her order happens before any other pool swaps settle"). See §4.11 — this is a citation worth stealing. |

### ALREADY-KILLED (6)

| # | Kill reason (ours) |
|---|---|
| B5 | **Searcher bonding for priority access** — `DECISION_CANDIDATES` §2: Sybil, unpatchable. A sandwicher runs the two legs from two addresses, so nothing is attributable; bigger bonds invert the mechanism in favour of the capitalised searcher. |
| B8 | **Diamond / generic LVR auction** — LVR is on Atrium's explicit AVOID list (55 prior submissions, 20 in UHI9). Same reason GRAZE scores 4.15 and is still not the pick. |
| B9 | **This is Assay's ancestor** — a composable policy hook that reverts the unlock on a published invariant. Built, ~180 tests, then *not submitted*: theme fit 2/5, demonstrability 2/5, and §1.7's blind spot (return-delta extraction is invisible to the ledger). |
| B16 | **The inventory-backed variant** — `DECISION_CANDIDATES` §0, proven by the router spike: a hook that pays the trader out of its own inventory "is no longer a queue — it is a market maker. The hook now needs inventory, a quoting rule and a hedging policy, and it re-opens the free-option problem in a worse form." |
| B25 | **Assay** — implemented, then killed as the submission. Its novelty (the `exttload` ledger read) covers one of two extraction channels; the other closes with ordinary arithmetic needing none of the v4-only properties the pitch rests on. |
| B26 | **Hardcap** — DEAD. Economically inverted (the first swap of the block was tax-exempt, *subsidising* the top-of-block race), freely bypassable, vault drainable by a one-block JIT position. |

### SATURATED (11)

| # | Lane, count from the 662 table (or my re-run) |
|---|---|
| A1, A2 | **Dynamic fee / fee-redirect: 189 (29 % of everything), 42 prized.** Both are the OZ `LiquidityPenaltyHook` cell with the fee switch flipped. Session A's own verdict: originality 3.5, "negative EV on rank." |
| B2 | **Sandwich protection specifically: 13, 4 prized** — and the base rule is shipped by OpenZeppelin, Umbra and cairoeth. A judge who knows OZ calls it a fork. *(Its JIT-lock half is separately promoted below as B2b.)* |
| B7 | **Internalized arb: 3 matches, 2 prized** — small n, but one is `Arb Hook` (UHI7), which **won the Uniswap Prize** for exactly this ("executes arbitrage during swaps, without off chain bots"). `SmartHook` (UHI5) took the Across Prize for the cross-chain version. |
| B10 | **Dynamic fee: 189.** A PID controller on a health vector is a dynamic fee with more Greek letters. Grok's own note: "dies on parameter choice." |
| B13 | **Loyalty / gamified: 24, 2 prized — the worst conversion of any large lane.** DexProfitWars, Catapoolt, uPEG, Slonks. Grok reached the same conclusion unprompted and demoted it to a UX layer. |
| B14 | **Rehypothecation → Aave/Morpho/ERC-4626: 38, 10 prized.** Plus the session's own kill: DualPool **already blocks external add/remove**, so bolting a JIT lock onto it is redundant. |
| B15 | **Launchpad / anti-snipe: 37, 13 prized** — and off-theme for MEV protection. |
| B17 | **CoW / netting: 33, 9 prized.** `IntentPool` (UHI8) already ships the whole thing: "batches trader intents, matches them P2P (Coincidence of Wants), and distributes surplus 50/30/20 between traders, LPs (via `donate()`), and protocol." |
| B21 | **am-AMM: 17 matches, 3 prized**, incl. `Auction Managed AMM` (UHI3, prized) and `Maestro` (UHI6, prized). Sits inside the **LVR-auction AVOID list (55)**. Grok's own caveat is right — you must disclaim "first-in-block" in sentence one — but that is a pitch tax you pay for a crowded lane. |
| B23 | **Flow segmentation: 3** (`Tidehook`, `Large-Cap Execution Hook`, `Stablecoin Peg Guardian`) **× netting: 33.** `Tidehook` already routes whales to Dutch auctions while keeping retail instant; `Large-Cap Execution Hook` already slices whales with on-chain cadence constraints. The composition is the union of two existing UHI8 projects. |

### NEW-BUT-BAD (4)

| # | Not covered by our docs, and here is why it still fails |
|---|---|
| B11 | **Session AMM on Robinhood stock tokens.** It fights the chain's entire sales pitch (24/7 stock exposure), tokenized stocks are ~10 % of that chain's DEX volume against memes, and no one has ever measured that weekend LPs actually lose more to pick-off than they earn in fees — Grok scored it 4.8, then retracted to 3.2 for exactly that reason. |
| B12 | **Public equilibrium skim.** With a *start-of-block* reference the "excess" you would skim is precisely the amount the sr-AMM rule already refuses to hand over — you cannot skim value that never left the pool (see §4.9). Making it real requires an *oracle* reference, which reintroduces the oracle dependency SWITCHBACK's whole case is built on avoiding, and puts you in the FairFlow / Detoxer / Marfinetz-2026 family. |
| B18 | **Fill warranty.** "Worse than start-of-block price" is true of roughly every second swap in a block, not of victims — the pot pays ordinary price impact and drains without deterring anything. |
| B19 | **FlashClear as pitched** ("Flashblock-native sandwich killer on Unichain"). Killed by its own author across six rounds: the headline problem is largely gone on that chain (§4.5), Flashtestations are not production-ready, Base has Flashblocks too so the exclusivity claim is false, and the `donate` leg was double-counting. *Its surviving kernel is promoted below as B20.* |

### NEW-WORTH-EVALUATING (5)

`B1` · `B6` · `B22` · `B2b` · `B20`. Worked up in §3.

**Three of the five are components, not submissions.** B22 and B2b are fixes that belong inside
SWITCHBACK; B20 is a granularity modifier. Only B1 and B6 are candidate hooks in their own right,
and I would not put either above SWITCHBACK today. That is the honest shape of this pass.

---

## 3. WORKUPS

### N-1 · B1 — Uniform block-clearing at one price

**Mechanism.** *State:* a per-block queue of custodied swap intents (input escrowed via
`beforeSwapReturnDelta` NoOp), plus the block's clearing price once computed. *Trigger:* the last
swap of the block, or the first pool action of block N+1. *Settlement:* every queued intent fills at
the single clearing price; the residual between that price and the curve is the arb leftover, taken
by the hook and paid to LPs. Buy/sell intents in the same batch net before the residual is computed.

**Best attack, unlimited capital + flash loans.** *Fill-price manipulation by batch stuffing.* The
clearing price is a function of the batch's own composition, so an attacker with free capital submits
a large intent in the direction he wants the cross to print, moves the clearing price, and then
extracts on the *other* venue (or on the next block's residual auction) — while his own leg
cross-nets at the price he set. Uniform-price batches are only sandwich-proof against an attacker who
cannot influence the clearing price; a flash-loan attacker can. The standard defence is a
volume-weighted cross plus a per-batch size cap as a fraction of depth — both of which are exactly
the "dust-poison cap" parameter SWITCHBACK also has untested. Secondary attack: **refuse to be in the
batch.** If the fast path exists for retail, the whale routes through the fast path.

**Prior art check (my regex over 662).**
- `uniform|single clearing|one price|clearing price` → **0 / 662.**
- `\bbatch\b` → **4 / 662, 1 prized:** `VeiledBatch` (UHI7, Fhenix Prize — entangled with FHE),
  `Async Swap` (UHI4, no prize — *"a new batch-auction style MEV-resilient mechanism… imposing a
  transaction ordering rule so that transactions in different directions are matched as much as
  possible"*, an explicit expansion of ACM 10.1145/3564246.3585233), `ZeanHook` (UHI5, no prize —
  batch execution + commit-reveal + AVS), `Debt Hook` (UHI5, unrelated sense of "batch").
- `IntentPool` (UHI8) is the nearest live analogue and is not caught by the batch regex.

⚠ **This corrects our own W7.** `WINNERS_LANDSCAPE` §3 W7 says batch clearing is "1 in 662" and
"effectively unexplored inside the incubator." The true count is **4 real attempts across UHI4–UHI8**,
of which 1 is prized. The *conclusion* (thin lane, poor conversion, no clean non-FHE instance) still
holds; the number in the doc is wrong and should be fixed.

**Composes with our shortlist?** **No — it collides with the router spike.** Uniform clearing requires
custody via `beforeSwapReturnDelta`, and commit `55c2ae2` proved by execution that a NoOp'd swap
through `V4Router` reverts with `IV4Router.V4TooLittleReceived(1, 0)` and through the hookmate router
with `SlippageExceeded()`, because `Hooks.afterSwap` subtracts the hook's `beforeSwapDelta` from the
caller's delta before the router sees it. B1 therefore inherits **HASTE's entire periphery problem
(14–20 h) without HASTE's economics**, and `minOut = 0` is not an escape hatch. It shares nothing
with SWITCHBACK. **Verdict: real white space, real originality, but the one candidate on this list
that our own spike already priced — do not open it as a third lane.**

---

### N-2 · B6 — Per-swap back-run rights auction with a swapper rebate

**Mechanism.** *State:* an open intent (custodied input, `minOut`, deadline) and a live bid book keyed
to it. *Trigger:* the swap opts in via `hookData`; the hook emits `Intent(id, size, direction)` and
accepts bids for the exclusive right to back-run it inside the same unlock. *Settlement:* highest bid
is `take`n from the winner, the user's swap executes at the curve price, the winner is permitted its
back-run in the same unlock, and the bid is split (Grok's numbers: 50 % swapper rebate / 40 % LP
donate / 10 % hook). No bid ⇒ the swap executes exactly as vanilla.

**Best attack, unlimited capital + flash loans.** *Collusive under-bidding, and it is structural.* The
back-run right is worth `X` to exactly one winner, so the auction is a single-item auction with a
handful of repeat bidders who see each other's bids on-chain every block — the textbook conditions
for a bidding ring. With free capital the marginal searcher bids `ε`, wins the right, and keeps
`X − ε`; the user's "rebate" is a rounding error while the mechanism's *presence* legitimises the
extraction. Worse: **the hook cannot verify that the winner's back-run is the only extraction.** A
flash-loaned bidder can bid `ε`, take the exclusive right, and *also* run the front-run leg from a
second address — the same two-address Sybil that killed B5, applied to the auction instead of the
bond. And the whole thing needs bidders to exist at all, which is why Grok's own kill gate #4 ("needs
searchers, or 'bots will come'") fires on it.

**Prior art check (my regex over 662).**
- `back.?run` → **0 / 662.** Not one submission in nine cohorts uses the word.
- `rebate|refund` → **5 / 662, 2 prized** — and **none of the five rebates the swapper for MEV**:
  `SafeSwap` (UHI9, "LVR rebate for **LPs**"), `Gated Trade Rebate Hook` (UHI7, *gated*, recovers
  price-impact value), `ILAwareLimitOrderHook` (UHI9, Uniswap Prize, unrelated), `Conflux`, and a
  Circle paymaster.
- `mev auction|sealed-?bid|bid.*(right\|priority)` → **22 / 662, 8 prized** — matching the 18 in our
  own table. **The closest thing to B6 is `MEVengers` (UHI8, no prize):** *"detect, lock, and auction
  off predatory MEV opportunities, redistributing value to LPs **and victims**."* So the *idea* has
  been filed; the pure-hook, no-AVS, no-Reactive-Network version has not.

**Composes with our shortlist?** **Weakly, and in a way that hurts.** SWITCHBACK's thesis is that you
should *charge the shape of the trade* and never have to identify anyone; B6 is the opposite bet —
you legitimise the back-runner and sell them a licence. Running both in one hook would mean charging
a retracement fee to the very party you just sold the retracement right to. **Verdict: 0/662 on
`back.?run` is the most striking empty cell I found, and the swapper-rebate framing is genuinely
unfiled — but the mechanism needs a competitive searcher population we cannot demonstrate, and the
two-address Sybil that killed B5 kills it too. I would not add it to the shortlist. I am recording it
because the empty cell is worth knowing.**

---

### N-3 · B22 — Aged-LP escrow instead of `poolManager.donate()`  ← **read this one**

**Mechanism.** *State:* per-position `lastAddBlock`, keyed on the full `positionKey` including `salt`;
plus a hook-owned token balance ("the box"). *Trigger:* any time the hook seizes value (a
retracement fee, a JIT penalty, a skim). *Settlement:* the seized amount is credited to the hook's own
balance, **never** passed to `poolManager.donate()`. A `claim()` pays pro-rata to positions whose
`lastAddBlock + OFFSET <= block.number`.

**Why this is the most important row in this document.** `poolManager.donate()` pays **whoever is in
range right now** — not historical LPs, not "the liquidity that was present at block open." That is a
protocol fact, not a design preference. **`DECISION_CANDIDATES` describes SWITCHBACK's recapture leg
as "escrowed and donated next block to the liquidity that was present at block open."** With
`donate()` that sentence is not implementable, and worse, it is *exploitable* — see §4.2.

**Best attack, unlimited capital + flash loans.** Against the escrow version: **top-up griefing and
the honest-LP false positive.** Any local `lastAddBlock` rule punishes a three-month LP who adds
$50 k today — OZ documents this collateral damage in their own natspec. Against a naive escrow, an
attacker adds dust to *every* competing position's tick range… no, he cannot; positions are per-owner.
The real attack is **wait-and-claim**: an attacker who is willing to hold a position for `OFFSET`
blocks becomes eligible, so `OFFSET` must exceed the horizon over which holding inventory is costly
for him — which is an economic parameter, unmeasured, and exactly the class of parameter that killed
Hardcap. **State it as a parameter, do not claim it as a proof.**

**Prior art check.** `aged lp|historical lp|only.*lps.*present` → 3 weak matches, all leveraged-LP
products (`ybAMM`, `YieldStream`, `BoostLP`), none relevant. **The pattern "seize and escrow rather
than `donate`" appears nowhere in 662.** OpenZeppelin, who ship the reference implementation, use
`donate()` and document the resulting hole rather than fixing it.

**Composes with our shortlist?** **Yes — SWITCHBACK requires it.** This is not an alternative
candidate; it is a correction to a candidate we have already chosen. It is also the mechanically
correct answer to the "JIT-refund drain" that `DECISION_CANDIDATES` lists as SWITCHBACK's open
weakness and says is "only *mitigated* by the next-block donation." **That mitigation does not work if
the payout is a `donate()`** — the next-block JIT is in range next block too.

---

### N-4 · B2b — JIT activation delay (`bornBlock` reservation)

**Mechanism.** *State:* `bornBlock` per position (again, `positionKey` **including `salt`**).
*Trigger:* `beforeAddLiquidity` stamps it; `beforeSwap` consults it. *Settlement:* liquidity minted in
block N may service **only** the swap that triggered its own mint (the DualPool pattern) — no other
swap in block N may draw on it. Equivalent stricter form: `beforeRemoveLiquidity` reverts if
`bornBlock == block.number`.

**Best attack, unlimited capital + flash loans.** **Salt shopping and address shopping** — the exact
family as `CLAUDE.md` §5.9 / the Ledger Theorem. If the key omits `salt`, one address mints under N
salts and the lock is fiction. If the key is right, the attacker instead uses N *addresses*, which
costs him nothing but does force him to hold real inventory across a block boundary — and that is the
point: the lock converts a free atomic bundle into a position with overnight risk. Second attack:
**mint one block early.** A JIT who is willing to be in range for block N−1 as well pays one block of
LVR exposure for the privilege; on a fast L2 that is cheap. So this is a cost imposition, **not a
prohibition**, and must be pitched as one.

**Prior art check.** `jit.*(lock|delay|activation|cooldown)|born block|same-?block (mint|add).*(burn|remove)`
→ **1 / 662, 0 prized**, and that one (`JIT Liquidity & Issuance Hook`, UHI8) is a JIT *provider* for
launches, the opposite object. The lock form is effectively unfiled inside UHI. Outside UHI it is
well known (Uniswap's own 2022 JIT writeup; OZ `LiquidityPenaltyHook` is the soft-penalty version),
so it is **not** an originality play — it is a correctness requirement.

**Composes with our shortlist?** **Yes, with SWITCHBACK, and it is the other half of N-3.** N-3 stops
the JIT from *receiving* the recaptured fee; N-4 stops the JIT from *earning the native fee* around
the retracement in the first place. Grok's own kill gate is worth adopting verbatim: *"if the lonely-
whale / honest-LP case is not in the first test, stop."*

---

### N-5 · B20 — Flashblock-clocked window via the on-chain `FlashblockNumber` contract

**Mechanism.** *State:* the last-seen `getFlashblockNumber()` and the price snapshot taken at its
change. *Trigger:* every callback compares the current flashblock id to the stored one. *Settlement:*
the "block open" reference that SWITCHBACK's whole mechanism turns on is re-based from ~1–2 s
(`block.number` on an L2) to ~200 ms.

**Best attack, unlimited capital + flash loans.** **Boundary shopping, and it gets *worse* with
granularity.** Buy at the end of slice N, sell at the start of slice N+1: the retracement is measured
against a fresh watermark and reads as zero. A 200 ms clock gives an attacker **5–10× more boundaries
per second** to straddle. Second attack, and this one is free: **stall the clock.** The counter is
incremented by allowlisted builders; if increments stop, several real blocks share one id and the
"200 ms market" silently becomes a 2 s market with no error. An attacker cannot cause the stall, but
he can *detect* it and trade into it. Third: the contract is **UUPS-upgradeable**, so the trust
assumption is Flashbots plus an admin key, not arithmetic.

**Prior art check.** `flashblock|flash-?block|200\s?ms` → **1 / 662**, and it is a false positive
(`PerpHinge`, UHI8, a perps hook that happens to mention Unichain). **No hook in nine cohorts uses the
Flashblock clock.** `unichain` appears in 173 rows, so the chain is not novel; the clock is.

**Composes with our shortlist?** **Yes — it is a one-line modifier on SWITCHBACK, not a project.**
SWITCHBACK already keeps a block-open tick and intra-block watermarks; swapping `block.number` for
`getFlashblockNumber()` is a small change that buys a real "we integrate Flashbots' stack" line in
the README (Gate-1 partner-integration box, and P1 in `WINNERS_LANDSCAPE`: ≥1 integration is 27.5 %
prized vs 15.0 %). **But it must be optional and it must fail safe to `block.number`,** because of the
stall. And it *increases* the boundary-straddle attack surface, so it should not ship before
SWITCHBACK's cross-boundary case is tested at 1-block granularity. **Verdict: worth a half-day spike
after SWITCHBACK's core is green; never before.**

---

## 4. CROSS-CUTTING — constraints and facts not in `CLAUDE.md` §5

**These are worth more than the ideas.** Contradictions are marked ⚠ and are not smoothed over.

### 4.1 `poolManager.donate()` pays whoever is in range NOW — never historical LPs
A protocol fact, stated flatly at `B/L201` and used as a kill gate for the rest of that session. There
is no v4 primitive that pays "the liquidity that was present at block open." A hook that wants to pay
a historical cohort must hold the tokens itself and expose a `claim()`. **Candidate for `CLAUDE.md`
§5 as a numbered hard-won fact.**

### 4.2 ⚠ CONTRADICTION — SWITCHBACK's recapture leg, as written, is not implementable *and* is exploitable
`DECISION_CANDIDATES` §1: *"That fee is escrowed and donated next block to the liquidity that was
present at block open."* By §4.1 the second half cannot be done with `donate()`. And OpenZeppelin's
`LiquidityPenaltyHook` **documents the exact bypass in its own natspec**: an attacker adds minimal
liquidity from a secondary account at a tick where nobody else is, pushes the price into that tick,
and the penalty `donate()` is redirected to himself. OZ shipped it anyway, calling it *"rarely
profitable in practice."* **On a thin volatile pair — this cohort's theme — pushing price into an
empty tick is cheap, and "rarely" becomes routine.** This *is* the "JIT-refund drain … the Hardcap
vault-drain reborn" our own doc names as SWITCHBACK's open weakness, except our doc says it is
"mitigated by the next-block donation." It is not: the attacker is in range next block too. **Fix is
N-3 (hook-owned escrow + aged claim), and it must be in the first week's tests, not the README.**

### 4.3 OZ `AntiSandwichHook` v1.2.0 protects exactly ONE swap direction
Their own documentation: *"only protects swaps in the `zeroForOne` [false] direction. The other
direction is not protected."* It also has **no** `beforeAddLiquidity` / `afterRemoveLiquidity` — JIT is
out of scope by design — and leaves `_handleCollectedFees` `virtual` for the integrator, which is how
integrators end up re-creating the `donate` hole. Two-sided protection is a different AMM, not a
patch. Anyone claiming "we did what OZ does, both ways" is overclaiming.

### 4.4 One hook address per pool — the two OZ hooks cannot be composed at the PoolManager
`v4-template` and OZ's library both assume *inherit `BaseHook`, attach that one contract*. Nobody
stacks hooks. Consequence: any project offering both sandwich resistance and JIT resistance must
**merge** the two, and merging is work, not novelty.

### 4.5 ⚠ CONTRADICTION — Gogol et al. (Jan 2026): sandwiches are rare and usually unprofitable on private-mempool rollups
*"How to Serve Your Sandwich?"*, arXiv **2601.19570**: on rollups with private mempools, sandwiches are
rare, mostly unprofitable, median bot PnL negative, and **>95 % of "sandwich-shaped" transaction
triples are false positives.** This is the single fact in these transcripts most dangerous to our
current plan. SWITCHBACK's designated demo is *"run a real sandwich, show the attacker's P&L go
negative"* — and Unichain, Uniswap's own chain and the natural deploy target, has an encrypted mempool
plus TEE priority ordering. **A judge who has read this paper hears "a lock for a door the building
already removed."**
Three things survive the paper and should carry the pitch instead:
(a) **JIT is not a mempool race** — it is mint→swap→burn inside one `unlock`, and it works identically
on every chain, private mempool or not;
(b) **self-liquidation and CEX–DEX retracement** are not sandwiches and are untouched by the paper;
(c) Ethereum L1 and any public-mempool chain still have the classic problem.
**Do not lead with "kill the sandwich on Unichain." Lead with the shape (extension-then-retracement),
which covers all three.** This does not kill SWITCHBACK; it re-words it.

### 4.6 The Flashblock clock is readable on-chain — and our W2 is out of date
`github.com/uniswap/flashblocks_number_contract` exposes `getFlashblockNumber()`. Uniswap built it;
Unichain.org lists Flashblocks as **live**; **UniswapX already uses this clock for order decay.**
Caveats, all load-bearing: incremented only by **allowlisted builders**, so it can **freeze** (several
real blocks sharing one id, silently); the contract is **UUPS-upgradeable**; and **Base has Flashblocks
too**, so "Unichain-only 200 ms" is false. ⚠ **This contradicts `WINNERS_LANDSCAPE` §3 W2**, which says
builder-attestation ideas have zero entries "partly because there is no clean on-chain source of
builder attestations to read on a testnet." There is one, and it is Uniswap's own contract. W2's
count (0/662) is right; its stated *reason* is now wrong.

### 4.7 Flashtestations are NOT production-ready — do not build on them
Flashbots' own forum post (Oct 2025, *"Beyond Flashtestations"*): *"Flashtestation is not yet
production-ready."* Unichain.org lists it as "coming soon." **Any submission that ticks "verifiable
block building" as an integration is claiming something that does not exist yet.**

### 4.8 Angstrom L2 is a LIVE competing v4 hook on both Unichain and Base
`docs.angstrom.xyz/l2` — deployed, taxes priority fees, pays LPs. ⚠ **Stronger than our doc admits.**
`DECISION_CANDIDATES` calls Angstrom "published work a16z / Variant / Dragonfly judges will know."
It is not merely published — **it is already running as a hook on the chains we would deploy to,
doing app-level MEV internalisation.** SWITCHBACK's comparison table must include it, and the honest
distinction is real and defensible: Angstrom taxes the **gas tip**; SWITCHBACK charges the **price
path**. That difference should be stated, not discovered by a judge.

### 4.9 A failed sandwich has nothing to donate — "recapture" must name a real cashflow
If the sr-AMM rule made the back-run lose, the inventory never left the pool; announcing a `donate` of
that amount is *"taking cash out of the till, putting it back, and calling it revenue."* Only a skim
against a genuine reference is a second cashflow. **Relevant to SWITCHBACK's wording:** its
retracement fee *is* a real cashflow (it is charged, not merely withheld) — so the claim survives —
but the distinction must be made explicitly or a formal-methods judge will assume the sloppy version.

### 4.10 Kyber FairFlow is the production incumbent for LVR recapture, and it is absent from all our research
Exclusive-router pool; skims the gap versus a signed fair price; **70 % LPs / 30 % Kyber**; roughly
**$3.3 B volume, $320 k returned to LPs, ~2,100 LPs** in its first year. Not mentioned once in
`WINNERS_LANDSCAPE`, `HACKATHON_CONTEXT` or `DECISION_CANDIDATES`. Any recapture pitch will be measured
against it by anyone who follows the space. Its structural weakness is the opening: **only Kyber's
router can hit the pool**, so 1inch, the Uniswap router and native UIs cannot route into it.
"Permissionless, so aggregators can actually route to it" is a real differentiator — and it also
means the routing-rebate program (Brevis / UF, up to 85 % of gas) becomes reachable.

### 4.11 Uniswap's own TWAMM claim is the citation for "first-in-block cannot be front-run"
`blog.uniswap.org/v4-twamm-hook`: *"She cannot be front-run because her order happens before any other
pool swaps can settle."* **This is a better foundation for HASTE's anti-filler fix than our own
reasoning**, and it is Uniswap's own words about Uniswap's own hook. Note the limit the session also
identified: first-in-block does **not** stop a JIT bundled into the same unlock, so a
settle-first-next-block design still needs the `bornBlock` check from N-4.

### 4.12 PoolManager keys positions by the unlock's `msg.sender` — usually the router
Flagged at `B/L284` as an unresolved spike that must be settled *before* writing any JIT or aged-LP
logic: *"PoolManager keys positions by unlock `msg.sender` (usually the router). Wrong `sender` → the
lock is fiction."* This extends our existing finding (`DECISION_CANDIDATES` §0: `sender` in
`beforeSwap` is the router, not the trader) from **swaps to positions**, and it is the same root cause
as audit finding A-1 and §5.5: *we read the address we happened to be holding, not the address that
did the thing.* Also from the same turn, both cheap and both fatal if missed: **`positionKey` must
include `salt`** (else one address mints under N salts and any per-position lock is fiction), and
**top-ups reset the clock**, which locks out honest LPs — OZ documents that collateral damage and we
would inherit it.

### 4.13 The fee-assignment taxonomy — useful for positioning, and SWITCHBACK is outside it
Session A's compressed claim: fee assignment has four cells — **age** (`LiquidityPenaltyHook`),
**bond** (prepaid penalty), **auction** (am-AMM), **protocol-owned liquidity** (DualPool) — and
"leftover versus top-of-block" is FairFlow / AntiSandwich. Its conclusion was *"there is no fifth
object."* **SWITCHBACK is a fifth object**: it assigns fees by the *shape of the intra-block price
path*, which is none of those five cells. That is a sharper way to state its originality than "round
trip returns 0 matches," and it survives a judge who knows all five incumbents.

### 4.14 Method note that matches ours
The session's own kill gates are close to our standing orders and one is worth adopting verbatim:
**"if the embarrassing case is not in the first test, the idea is slop."** For SWITCHBACK that case is
the honest LP who tops up and is locked out of the escrow; for HASTE it is the lonely deferred order
that nobody fills. Both belong in week one, before the fee curve.

---

## 5. WHAT I WOULD ACTUALLY DO WITH THIS

1. **Fix SWITCHBACK's recapture leg before anything else.** N-3 + N-4. The current wording is not
   implementable with `donate()` and the shipped OZ analogue has a published bypass that is cheap on
   exactly the pairs we target. This is a correctness fix, not an enhancement.
2. **Re-word the SWITCHBACK pitch away from "sandwich" and toward "extension-then-retracement."**
   Gogol 2026 will be in a judge's head; JIT and self-liquidation are chain-independent and cover the
   same demo.
3. **Add Angstrom and Kyber FairFlow to the comparison table**, with the honest distinctions
   (price path vs gas tip; permissionless vs exclusive router).
4. **Correct two numbers in our own research:** W7's batch count (1 → 4) and W2's stated reason
   (a clean on-chain builder-fed clock does exist).
5. **Do not open B1 or B6 as new lanes.** B1 collides with the router spike we already paid for;
   B6 needs a searcher population we cannot demonstrate and inherits B5's two-address Sybil.
6. **Get the X link out of a logged-in browser.** It is the only source in this pass I could not read.
