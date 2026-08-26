# INCUMBENTS — the live competition in SWITCHBACK's lane

*Research date 2026-08-26. Commissioned after `IDEAS_FROM_GROK.md` surfaced two deployed
competitors that none of our earlier research had noticed. **Every mechanism claim below is from a
primary source — contract source, protocol docs, or an on-chain `eth_getCode` / `eth_getLogs` call
run for this document.** Blog paraphrases are marked as such. Anything I could not reach a primary
source for is marked `UNVERIFIED` and is not used in the verdict.*

---

## 0. PROVENANCE

### Primary sources actually read

| Source | Method | Gave |
|---|---|---|
| `OpenZeppelin/uniswap-hooks@master/src/general/AntiSandwichHook.sol` | `curl` raw, 9,573 bytes | The one-direction limit and the permission set, **from the source, not a blog** |
| …`/LiquidityPenaltyHook.sol` | `curl` raw, 14,397 bytes | The secondary-account `donate` bypass, verbatim from the NatSpec |
| `docs.angstrom.xyz/l2/intro` | WebFetch | Angstrom L2's exact tax formula and settlement path |
| `docs.angstrom.xyz/` (overview) | WebFetch | The L1 / L2 split — two different mechanisms under one name |
| `docs.angstrom.xyz/contracts/deployments` | WebFetch | Verbatim addresses for mainnet, Sepolia, Base |
| `docs.kyberswap.com/user-guide/kyberswap-fairflow/solution-fairflow` | WebFetch | EG definition, exclusive-taker requirement, 70/30 split |
| `blog.kyberswap.com/introducing-fairflow/` | WebFetch | The signed-fair-price flow, on-chain check, off-chain weekly distribution |
| `umbraresearch.xyz/writings/sandwich-resistant-amm` | WebFetch | The sr-AMM rule and its self-declared limitations |
| **Ethereum mainnet, Base, Unichain** | `eth_getCode` / `eth_getLogs` over public RPCs, **each with a negative control** | Which of these things is actually deployed and actually being used |

### On-chain measurements (run 2026-08-26; Base head 50,473,113 · Ethereum head 25,838,416)

| Check | Result |
|---|---|
| Angstrom L1 Hook `0x0000000aa232009084Bd71A5797d089AA4Edfad4` on Ethereum | **23,569 bytes of code.** 433 logs in the last 5,000 blocks (~17 h). |
| Angstrom L2 Hook ETH/USDC `0xCD256a2f4574CB6acA4837313ad225d2fe1De5Cf` on Base | **23,240 bytes.** 144 logs in the last 5,000 blocks (~2.8 h). |
| Angstrom L2 Hook ETH/cbBTC `0x7Fa49D29481b6D168505Ccde26635e204c09e5CF` on Base | **23,240 bytes.** 26 logs in the same window. |
| Angstrom L2 Factory `0x0000000000fd3b85c30F942E8D878E858E69cD05` on Base | **9,174 bytes.** 0 pool-creation logs in the last 9,000 blocks (no *new* pools lately). |
| ⚠ **All three published Angstrom addresses on Unichain** | **0 bytes. No code at any of them.** |
| **Negative control 1** — Angstrom *L1* hook address queried on *Base* | 0 logs, as it must be |
| **Negative control 2** — Angstrom *Sepolia* hook address queried on *Ethereum mainnet* | 0 logs, as it must be |

Both controls returning zero is why the 433 / 144 / 26 counts are activity and not an artefact of a
badly-formed query. **I ran the controls because a log query that silently returns everything or
nothing is exactly the failure that has bitten this repo before.**

### ⚠ Correction to my own previous report

I told the lead that Angstrom is *"live on Unichain AND Base."* **That was wrong, and I sourced it
from a Grok transcript rather than from the chain.** The docs prose does say "deployed on Base and
Unichain," but the deployments page lists **Base only**, and all three published addresses hold
**zero code on Unichain**. See §5 for what this does and does not license us to say.

### Could NOT verify — not used in the verdict

| Claim | Status |
|---|---|
| FairFlow "$320k returned to LPs", "~2,100 LPs" | **UNVERIFIED.** These came from the Grok transcript. No primary or secondary source states either number. Do not repeat them. |
| FairFlow's hook contract source / callback set | **UNVERIFIED.** I found no public repo or verified address. Everything in §1 is from Kyber's own docs describing their behaviour, not from bytecode. |
| Angstrom L2's "compensation price solver" internals | **UNVERIFIED.** Named in the docs, not read. |
| USD notional through the Angstrom L2 Base pools | **UNVERIFIED.** I measured event counts, not value. 144 events in 2.8 h is "in use," not "carrying size." |
| Any Angstrom Unichain deployment at an unpublished address | **Cannot rule out.** I checked the three published addresses only. |

---

## 1. KYBERSWAP FAIRFLOW

**It is a Uniswap v4 hook** — confirmed by the Uniswap Foundation's own Hook Design Lab writeup and
by Kyber's docs, which describe a "FF hook" and "FF pools."

### Mechanism, precisely

*State:* pool positions as normal; **LP participation is tracked off-chain**, not in a farming
contract. *Trigger:* a route executed by the KyberSwap Aggregator. *Reference:* **a backend
signature.** Kyber's own words — the aggregator computes the difference between "the best route
including FF pools" and "the best alternative route excluding FF pools," and then *"the FF backend
computes a fair price and generates a signature for it."* *On-chain check:* *"When the transaction
reaches the blockchain, the hook checks the signed fair price against the actual on-chain output of
the FF pools."* *Capture:* *"If the actual result from the FF pools is better than or equal to the
signed fair price: the pools deliver the fair price result to the taker. The pools absorb the
difference internally (the EG)."* *Assignment to LPs:* **not on-chain.** *"FairFlow tracks LP
participation off-chain and distributes EG Sharing to LP token holders"* — weekly, in the two pair
tokens, **70 % LP / 30 % Kyber**.

### The exclusive-router dependency — and whether it is a real opening for us

Kyber, verbatim: *"The KyberSwap Aggregator is the only taker for FairFlow pools, blocking external
arbitrageurs from fully extracting value."*

**Answer to the lead's question: they could not switch it off tomorrow, because the exclusivity IS
the mechanism.** EG exists only because no external arbitrageur is allowed to compete the gap away
first. Open an FF pool to all routers and an external arb takes the gap before the signed-price path
executes, so EG → 0 and the 70 % LP share is a share of nothing. It is a structural moat and a
structural cage at the same time. **"Permissionless, so aggregators can actually route to it" is
therefore a genuine differentiator and not a feature they can copy** — but be precise about what it
buys: it buys *routability*, not *more recapture*. FairFlow's per-pool recapture is probably higher
than an open pool's can ever be. Our honest claim is "open access with a rule," not "we recapture
more than Kyber."

### What FairFlow does not catch

1. **Anything in an open pool** — its "MEV protection" is *exclusion*, not a rule. There is no
   sandwich in an FF pool because there is no public access to an FF pool. That mechanism does not
   generalise to the 99.9 % of v4 pools anyone can trade.
2. **The intra-block price path.** Nothing in FairFlow examines ordering, extension or retracement.
   It compares one number (realised output) against one number (a signed fair price).
3. **JIT liquidity.** LP shares are tracked off-chain and paid weekly; nothing in the described
   design distinguishes a position that existed for one block from one that existed for a month.
4. **Self-custody of the reference.** The fair price is produced by Kyber's backend and consumed as
   a signature. If the signer is wrong, stale, or coerced, the pool absorbs the wrong amount. This
   is a trusted-oracle dependency wearing different clothes.

### Scale (verified)

Launched **5 Aug 2025**. **Over $3.2 B swap volume across 22 pools on Ethereum, Base, Arbitrum,
Monad and BNB Chain** in its first year *(cryptobriefing, corroborating the UF blog's earlier
"15 pools / $1.4 B" snapshot — both secondary, but consistent and dated)*. One published pool-level
figure: a Base ETH/cbBTC 0.05 % FF pool showed *"an APR of nearly 21 %"* over a 189-hour experiment
*(Kyber's own blog — a vendor number on a single pool over eight days; treat accordingly)*.

---

## 2. ANGSTROM (SORELLA LABS) — **it is two different mechanisms, and only one is a pure hook**

This is the most important structural finding in this document. "Angstrom" names two products with
**different mechanisms on different chains**, and conflating them is how we would get caught.

### 2a. Angstrom L1 — Ethereum mainnet

*Docs, verbatim:* an **off-chain validator network** executes the auction and enforces sequencing,
because of "high gas costs and builder censorship risks." Two components: a **batch auction** in
which *"all trades in a block clear at a uniform price"* (this is what neutralises sandwiches), and
an **off-chain arbitrage auction** run *"every block"* to internalise the top-of-block MEV.

**Live:** hook `0x0000000aa232009084Bd71A5797d089AA4Edfad4`, **23,569 bytes on Ethereum mainnet**,
**433 logs in the last ~17 hours**, negative control 0. This is a real, used, mainnet system.

**Not a pure hook.** It cannot run without the off-chain validator set. That is its residual and it
is a large one: adoption, staking, liveness and neutrality of a permissioned-ish network.

⚠ **This is direct prior art for the "uniform block clearing" idea** (`IDEAS_FROM_GROK.md` N-1), from
a serious, funded team, deployed on mainnet. That idea should now be considered closed.

### 2b. Angstrom L2 — Base (and, per docs only, Unichain)

*Docs, verbatim:* *"Angstrom runs **all** of its logic inside a Uniswap v4 hook, so the MEV auction,
LP payouts, and pool controls execute on-chain."* The hook *"reads each swap's priority fee, computes
a deterministic MEV tax in `beforeSwap`, and settles it during `settle` while `afterSwap` routes the
proceeds back to LPs."* The tax multiplies *"the transaction priority fee above a floor
`(tx.gasprice - block.basefee) - priorityFeeTaxFloor` by a fixed amount of virtual gas."* The hook
*"mints the LP share of the tax into the pool and distributes it across crossed ticks using the
compensation price solver."*

**Live on Base:** two hooks (ETH/USDC, ETH/cbBTC) at 23,240 bytes each, 144 and 26 logs in the last
~2.8 hours, negative control 0. Factory present. Pool creation is quiet.
**Unichain: 0 bytes at all three published addresses.**

### ✅ Our differentiation sentence — VERIFIED, not paraphrased

The lead asked me to check whether "Angstrom taxes the gas tip, SWITCHBACK charges the price path"
survives contact with the implementation. **Against Angstrom L2 it does, and it is now quotable from
their own documentation.** The taxed quantity is literally `(tx.gasprice - block.basefee)` above a
floor — the searcher's *bid for ordering*. Nothing in the L2 design reads `slot0`, a tick, a
watermark, or any price at all.

**But the sentence is only true of L2.** Against **Angstrom L1** the correct sentence is different
and must be said instead: *Angstrom L1 removes the intra-block price path by clearing the whole
block at one price, using an off-chain validator network to do it. SWITCHBACK leaves the path intact
and charges it, entirely on-chain.* If we say "Angstrom taxes the gas tip" without qualification and
a judge knows the mainnet product, we look like we read one page.

### What Angstrom concedes

- **L2: priority-fee taxation only works where priority fee is the ordering signal.** A searcher who
  obtains ordering some other way — a private arrangement with the sequencer, a chain that does not
  order by tip — pays nothing. The tax is on the *bid*, and the bid is only visible when the auction
  is public.
- **L2 taxes urgency, not extraction.** An honest trader who genuinely needs to be early pays the
  same tax as a sandwicher. There is no attempt to separate them; the design's answer is that the
  proceeds go to LPs either way.
- **L1 concedes decentralisation:** an off-chain validator network is a trust and liveness
  dependency, and it is the reason the same team built a different mechanism for L2.
- **Neither touches JIT liquidity.** Nothing in either design conditions on position age.

---

## 3. UMBRA RESEARCH sr-AMM — **a paper, but shipped by others**

**The writeup itself is a design piece with no implementation, deployment or code release.** That
was the lead's question and the answer is: paper.

**But the distinction does not help us as much as hoped, because two independent implementations
exist and one of them is OpenZeppelin's.**

- `github.com/cairoeth/sandwich-resistant-hook` — an explicit v4 implementation of the Umbra design.
- **`OpenZeppelin/uniswap-hooks` → `AntiSandwichHook.sol`** — in the library judges will compare us
  to. I read the source.

*Rule:* *"No swaps get filled at a price better than the price at the beginning of the slot window."*
Buys move the offer along `xy=k` while the bid stays fixed; sells eat the accumulated bid liquidity.
State resets to equivalent `xy=k` at each window start.

*Umbra's own named limitations:* **slot-boundary attacks** (a leader controlling consecutive windows
front-runs at the end of one and back-runs at the start of the next), **JIT liquidity** ("with atomic
liquidity provisioning, an attacker can still sandwich high-slippage trades"), and it mitigates only
atomic same-window sandwiches.

*What the shipped OZ version additionally concedes,* verbatim from `AntiSandwichHook.sol`:

> `NOTE: The Anti-sandwich mechanism only protects swaps in the zeroForOne swap direction.`
> `Swaps in the !zeroForOne direction are not protected by this hook design.`

and its permission set confirms it: `beforeAddLiquidity: false`, `afterRemoveLiquidity: false` — **JIT
is out of scope in code, not just in prose.** `_handleCollectedFees` is left to the inheritor, which
is how integrators reintroduce the `donate` hole.

### ⚠⚠ THE FINDING THAT MATTERS MOST — OZ's third warning is aimed at SWITCHBACK's foundation

Also verbatim from `AntiSandwichHook.sol`:

> `WARNING: Since this hook makes MEV not profitable, there's not as much arbitrage in`
> `the pool, making prices at beginning of the block not necessarily close to market price.`

**SWITCHBACK's entire mechanism is anchored to the block-open price.** OpenZeppelin is reporting,
from the shipped implementation of the closest analogue, that *succeeding* at deterring the round
trip **degrades the arbitrage that keeps the block-open reference near market** — the mechanism eats
its own reference. Our fee is *proportional to ticks retraced from a reference that this warning says
will drift.* On a stale reference, ordinary two-sided flow reads as a large retracement and gets
charged, and a genuine repricing after real news reads as extension-then-retracement and gets
charged. **That is Hardcap's economic inversion arriving through the reference rather than through an
exemption**, and it is not in our risk list.

It is not automatically fatal — SWITCHBACK charges rather than refuses, so *some* arbitrage remains
profitable and the loop may find a fixed point rather than running away. **But that is a hypothesis,
and it is now the most important untested thing about the candidate, ahead of the fee curve.**

A fourth warning is a smaller but real echo: OZ's `_beforeSwap` *"iterates over all ticks between
last tick and current tick,"* risking `MemoryOOG` on small tick spacing during large moves.
SWITCHBACK's watermark tracking is the same shape of computation and inherits the same hazard.

---

## 4. THE COMPARISON TABLE

| | **FairFlow** (Kyber) | **Angstrom L1** (Sorella) | **Angstrom L2** (Sorella) | **Umbra sr-AMM** / OZ `AntiSandwichHook` | **SWITCHBACK** (ours) |
|---|---|---|---|---|---|
| **Is it a v4 hook?** | Yes | Hook **+ off-chain validator network** | Yes — all logic on-chain | Yes (OZ / cairoeth implement the paper) | Yes |
| **Mechanism** | Exclusive taker; hook checks a **backend-signed fair price** against realised output; pool absorbs the difference | **Batch auction: every trade in a block clears at one uniform price**, plus an off-chain per-block arb auction | Deterministic **MEV tax on the priority fee above a floor**, computed in `beforeSwap` | **Price floor**: no fill better than the block-open price, applied asymmetrically to bid and offer | **Fee proportional to ticks retraced** toward the block-open price, capped by the extension |
| **What it charges** | The gap between realised output and a signed reference | The right to top-of-block arbitrage (auctioned off-chain) | `(tx.gasprice − block.basefee) − floor`, × virtual gas | **Nothing.** It refuses the fill; no cashflow is created | The distance the price is walked back |
| **Who it pays** | LPs — **off-chain, weekly, 70/30 with Kyber** | Participants / LPs (split not stated in the overview) | LPs — **minted into the pool across crossed ticks**, on-chain | Nobody. `_handleCollectedFees` is left to the integrator | Block-open liquidity — **requires a hook-owned escrow; `donate()` cannot do this** |
| **What it misses** | Everything outside its own permissioned pools; the price path; JIT; and it trusts a centralised signer | Decentralisation — needs an off-chain validator set | Any ordering not bought with a priority fee; and it taxes honest urgency identically | **One swap direction only**; JIT explicitly out of scope; **and it degrades its own block-open reference (OZ's own warning)** | Honest two-sided flow and genuine repricing, **if** the extension cap does not separate them — untested |
| **Live?** | **Yes.** $3.2 B / 22 pools / 5 chains since 5 Aug 2025 | **Yes.** 23,569 bytes on Ethereum, 433 logs/5,000 blocks | **Yes on Base** (2 pools, 23,240 bytes, 144 + 26 logs/5,000 blocks). **Not at any published address on Unichain — 0 bytes** | Library code, widely available; OZ ships it | No |

---

## 5. VERDICT — is SWITCHBACK still defensible?

**Yes, but on a narrower claim than the one currently written, and the research turned up a threat to
the mechanism itself that outranks the pitch problem.**

### The claim that survives, worded so a judge who knows all four cannot shrug

> Every shipped incumbent handles the intra-block price path by **removing it, flooring it, ignoring
> it, or closing the pool**. Angstrom L1 removes it — one uniform clearing price per block, using an
> off-chain validator network to enforce sequencing. Umbra / OpenZeppelin / cairoeth floor it — no
> fill better than block open, in one direction, creating no cashflow. Angstrom L2 ignores it and
> prices the *bid for ordering* instead — `tx.gasprice − block.basefee`, a quantity that has nothing
> to do with price. FairFlow closes the pool — its recapture exists only because one router is the
> only permitted taker. **None of them price the path.** SWITCHBACK charges a fee proportional to the
> distance the price is walked back, entirely on-chain, with no validator network, no signed
> reference, no permissioned taker, and no dependence on priority-fee ordering.

That sentence is verifiable against four primary sources and is materially stronger than
"`round.?trip` returns 0 matches in 662," which only ever spoke about UHI submissions and says
nothing about the ecosystem. **The fifth-object framing survives contact with the incumbents:** none
of age, bond, auction, protocol-owned liquidity, or leftover-versus-top-of-block describes a fee
assigned by path shape.

### It is not a taxonomy we drew for our own convenience — but it is thinner than it looks

Two honest deductions a judge is entitled to make:

1. **"That's AntiSandwich with a fee."** The gap between "refuse a fill better than block open" and
   "charge for walking back toward block open" is a real mechanism difference — one creates a
   cashflow and does not kill the arbitrage, the other does neither — but it is one step, not a leap.
   It is worth roughly the 3/5 originality we already assigned it. **Do not upgrade that score on the
   strength of this document.**
2. **The recapture leg is still not implementable as written.** OZ's `LiquidityPenaltyHook` NatSpec,
   verbatim: attackers *"bypass JIT protection by using a secondary account to add minimal liquidity
   at a target tick with no other liquidity, then moving the price there after a JIT attack… penalty
   fees [are] redirected to the attacker's secondary account."* They call it *"rarely profitable in
   practice, due to the cost associated with moving the price to the target tick"* — and on the thin
   volatile pairs this cohort is about, that cost is small. This is now confirmed from the contract,
   not from a blog.

### The thing that actually worries me, and it is new

**OZ's stale-reference warning (§3) is a live threat to SWITCHBACK's foundation, not to its pitch.**
A mechanism whose fee is measured *from* the block-open price, and whose success *degrades* the
arbitrage that keeps that price honest, has a feedback loop in it that nobody on this project has
looked at. It should be the next experiment — ahead of the fee curve, ahead of the dust-poison cap.
The question is small and answerable: **does the fee curve still separate extraction from honest
two-sided flow when the block-open tick is stale by a realistic amount?** If it does not, SWITCHBACK
has Hardcap's disease and we should find that out now.

### What I would tell the owner in one line

SWITCHBACK is not a rename of anything that ships today — that much is now verified against four
primary sources and the chain. But its originality is one honest step from OpenZeppelin's library,
its recapture leg needs rebuilding before it works at all, and the closest shipped analogue carries a
warning in its own source code that points straight at SWITCHBACK's reference price.
