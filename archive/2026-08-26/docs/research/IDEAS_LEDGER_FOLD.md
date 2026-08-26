# IDEAS_LEDGER_FOLD — pointing the flash-accounting ledger at someone other than the hook

> Pass date **2026-08-26**. Role: First Principles Expert + Asymmetry Attacker + Devil's Advocate.
> Brief: can Assay's ledger primitive be aimed at swappers / searchers / LPs / other hooks to produce
> an on-theme MEV hook — and is doing so genuinely better than starting clean?
>
> **Executed evidence in this document:** `test/spike/LedgerAddressShopping.t.sol` (passes; negative
> control confirmed red). Everything else is marked SOURCE-READ or REASONED and must not be quoted as
> proven.

---

## 0. The verdict, first, because it changes how you should read the rest

**Pointing this primitive at a counterparty produces a heuristic worth at most ~52,700 gas of
enforcement.** That is a measured number, not a guess. Any hook that prices, gates, or classifies a
swapper based on what the PoolManager ledger says about them can be evaded — completely, with zero
capital, inside the same transaction — for 52,700 gas. On mainnet at 20 gwei that is ≈ $3. On
Unichain, the natural deployment target and a UHI10 sponsor chain, it is a fraction of a cent.

So the ceiling on every candidate in Part 3 is: *you may charge a toxic actor about three dollars,
and only until they read your code.* Meanwhile the honest retail flow you cannot distinguish pays it
every time. **That is the exact economic inversion that killed HardcapHook** (CLAUDE.md §6: the tax
bound the wrong party and the bypass was cheap). I am not going to recommend rebuilding it with a
new sensor.

Part 4 gives the full verdict. Short form: **(c), weaker, and the pull toward it is sunk cost** —
with one narrow, real, non-submission carve-out.

---

## PART 1 — WHAT THE LEDGER ACTUALLY REVEALS ABOUT A NON-HOOK ACCOUNT

### 1.1 The complete read surface

`PoolManager` inherits `Exttload`, whose `exttload(bytes32)` is `external view`. Every transient slot
below is therefore readable mid-callback, from outside, by anybody. SOURCE-READ, v4-core:

| Slot | Contents | Where |
|---|---|---|
| `keccak256(account ‖ currency)` | that account's net unsettled delta, `int256` | `CurrencyDelta._computeSlot` |
| `0x7d4b3164…9a0b` | `NonzeroDeltaCount` — how many (account,currency) pairs are currently non-zero, globally | `NonzeroDeltaCount.sol` |
| `0xc090fc46…ab23` | `Lock.isUnlocked` | `Lock.sol` |
| `0x1e0745a7…bd95` / `0x27e098c5…93b9` | last `sync()`ed reserves / currency | `CurrencyReserves.sol` |

`PoolLedger.slot()` in this repo matches `_computeSlot` exactly (`abi.encode` of two addresses pads
both to 32 bytes). ✅ Verified by reading both.

Sign convention: **negative = the account has taken value out of PoolManager and not yet paid for
it.** Positive = PoolManager owes the account.

### 1.2 Timing — what is and is not in the number when a hook reads it

SOURCE-READ, `PoolManager.swap()`: the order is `beforeSwap` hook → `_swap` → `afterSwap` hook →
`_accountPoolBalanceDelta(key, hookDelta, hook)` → `_accountPoolBalanceDelta(key, swapDelta, msg.sender)`.
`modifyLiquidity()` is the same shape.

Three consequences, all load-bearing:

1. **At both `beforeSwap` and `afterSwap`, the caller's ledger entry excludes the current swap.**
   What you read is the caller's accumulated position from *earlier legs of the same unlock session*.
   That is the useful part — and it is also the only part.
2. **A hook's own `take()` / `mint()` inside a callback IS applied immediately.** This is why Assay's
   self-metering works at all.
3. **A hook's extraction via `afterSwapReturnDelta` is applied AFTER the callback returns** — i.e.
   after `AssayBaseHook._assayExit` has already run. See §1.7; this is a finding, not a footnote.

### 1.3 The one thing the ledger proves and cannot be made to lie about

> **An account's negative delta is a true lower bound on value it currently has out of PoolManager
> and has not paid for.**

Enumerate every way a delta can *increase* (i.e. every way to clear a debt): `settle` (requires a
real inbound ERC-20 transfer or `msg.value`), `burn` (requires already holding backed ERC-6909
claims), and the balance-delta of a `swap`/`modifyLiquidity`/`donate` (which credits one currency
only by debiting another). `clear()` only removes *positive* deltas and forfeits them. There is no
free way down. **To stop owing PoolManager, you must give PoolManager value.**

This is exactly why Assay works when pointed at a hook: for a hook, *extraction is not inferred from
debt — extraction IS the debt.* Clearing it means handing the money back.

### 1.4 Everything else is address-shoppable, and I measured the price

The asymmetry that kills the counterparty use case:

| Direction | Cost to the adversary |
|---|---|
| Hide a **debt** | must supply real value ⇒ they no longer have the money ⇒ genuinely impossible |
| Hide a **credit** | ~**52,700 gas**, zero capital, zero ERC-20 movement |
| Move a position to a **different address** so the hook reads a clean one | same 52,700 gas |
| **Inflate** your own debt to look poorer / less profitable | free (`take`, settle it back later) |

**EXECUTED.** `test/spike/LedgerAddressShoppingTest` deploys a real PoolManager (hookmate artifact),
settles 1,000 tokens in as Alice, then:

```
after settle :  delta(alice) = +1000e18   NonzeroDeltaCount = 1
pm.mint(bob, id(c), 1000e18)              ← the entire evasion
after mint   :  delta(alice) =  0         delta(bob) = 0      NonzeroDeltaCount = 0
bob.burn()   :  delta(bob)   = +1000e18
gas for the relocate                       52,700
```

Alice is still economically owed the money at the middle line, and **PoolManager's own ledger says
nothing is outstanding anywhere.** No ERC-20 moved. No capital was posted. Bob never touched a token.
Negative control (remove the `mint`) fails red with `alice's ledger entry is wiped: 1000e18 != 0`, so
the test is not vacuous.

ERC-6909 is a general-purpose delta-laundering rail: it converts a live transient credit into a
persistent transferable token and back, between arbitrary addresses, inside one unlock.

**The theorem this gives us:**

> The ledger tells the truth about an *address*. The adversary chooses which address faces your hook.
> A hook only ever learns the *locker* address from its callback, and value moves between addresses
> inside one unlock for 52,700 gas. Therefore every ledger-derived claim about a counterparty's
> *behaviour* is an inference, and the inference is purchasable.
>
> The only accounts whose ledger state a hook can trust are (a) itself, (b) an account whose debt the
> hook itself caused, and (c) an account that has **agreed in advance to be inspected at a named
> address** and has posted something it loses by walking away.

This is the same failure the independent audit found empirically in `AssayStack` (log entry A-1: *"the
unsettled 1-wei delta belongs to the guest, so the stack's own budget predicate never fires"*). Same
root cause: we read the address we happened to be holding, not the address that did the thing.

### 1.5 What it is blind to — state this before any opportunity

- **Every multi-transaction MEV shape.** Transient storage is wiped per transaction. **Sandwiches are
  three transactions and are therefore completely invisible.** So is cross-transaction JIT (add / victim
  swap / remove are three separate txs — the JIT that actually harms LPs). So is backrunning, so is
  anything cross-block. The theme's own mission statement is *"kill the Sandwich"* and this primitive
  cannot see one.
- **Everything outside this PoolManager.** CEX↔DEX arbitrage — which is the dominant source of LVR —
  touches v4 exactly **once**, settles with real tokens, and is byte-for-byte indistinguishable from
  a retail swap. Aave/Balancer flash loans, Curve legs, other chains: invisible.
- **Identity.** The delta is keyed to `msg.sender` at PoolManager — the router. Universal Router, not
  the trader. You cannot attribute to a person, and two users batched into one unlock have their
  deltas merged into one number.
- **Intent and the future.** At `beforeSwap` you know what has happened, never whether this is the
  last leg. Every "this is an arb" claim is a guess about a leg that has not happened yet.
- **Profit.** Since debt is freely inflatable (§1.4), `profit = output − debt` is understatable at
  will. There is no profit number here. Anyone who claims one is wrong.

### 1.6 What it genuinely does add, stated at full strength and no further

One thing, and it is real: **cross-pool, intra-transaction visibility.** Without the ledger a hook
sees its own pool's swap in isolation. With it, a hook sees the caller's footprint across the entire
PoolManager for this transaction — other pools, other currencies, pools the hook has nothing to do
with. Nothing else in v4 gives a hook that. Concretely readable, at ~200 gas per `tload`:

- the caller arrived carrying a debt in **this pool's own output currency** ⇒ this swap closes a loop
  back into an asset they already borrowed from PoolManager (cyclic arb signature);
- the caller arrived carrying a credit in this pool's **input** currency ⇒ mid-route (multi-hop);
- the **aggregate** size of an order that has been split across several v4 pools in one transaction;
- `NonzeroDeltaCount == 0` ⇒ this is the first value-moving operation of the unlock;
- **another hook's** live delta ⇒ how much a *different* hook has already extracted on this route.

All five are true readings. All five are inferences about a counterparty, and therefore all five are
priced at 52,700 gas.

### 1.7 A finding against Assay itself, found by this analysis — **EXECUTED AND CONFIRMED, see the EXECUTION section at the end of this document**

Combine §1.2(3) with §1.4. A hook that extracts via `afterSwapReturnDelta` receives its credit
*after* `AssayBaseHook`'s sealed callback has already run `_assayExit`. Its delta then goes from `0`
to `+X` — **positive, never negative** — and it can relocate that `+X` to an accomplice via
`mint`/`burn` for 52,700 gas. `DeltaBudgetPredicate` and `AssayFlowMeter` both measure
`PoolLedger.debt()`, i.e. the *negative* side only.

⇒ **Such a hook extracts X and every Assay meter reads zero at every observable point.**

The shipped straw men (`GreedyHook` et al.) do not exhibit this because they `take()` *inside* the
callback, which creates the debt the meter is looking for. Assay therefore catches the hook that
extracts naively — which is arguably its stated scope, *defects* — and misses the hook that waits.
That is materially weaker than the README's "a ceiling the hook cannot exceed no matter what bug it
contains." **This needs a test written by someone who did not write the defence** (standing order,
2026-08-26 audit). It is the same shape as audit finding A-1, three-for-three with §5.5.

---

## PART 2 — THE THEME CONSTRAINT (read, not re-fetched)

From `HACKATHON_CONTEXT.md` §5 and `WINNERS_LANDSCAPE.md` §2–3, the parts that bind:

- Theme: *"reduce value leakage from LPs and make volatile-pair liquidity sustainable at low fees."*
  Mission: *"Protect LPs · kill the Sandwich."* Win condition, verbatim: **"Combine defense and
  recapture."**
- Five official prompts: randomized ordering/delay · time-weighted or probabilistic settlement ·
  fee rebates tied to flow quality · hybrid routing to CoW/Flashbots · protocol-native MEV auctions.
- Rubric: 30 Original / 25 Unique Execution / 20 Impact / 15 Functionality / 10 Presentation. **55% is
  novelty + distinctiveness of construction.**
- Saturation: MEV/sandwich/toxic-flow = 139 submissions (3rd largest lane ever). LVR = 55, **on
  Atrium's own AVOID list**. Dynamic fee = 189, dead. FHE/dark pool = 66 with a 9% prize rate, AVOID.
- White space that matters here: **W3 searcher bonding/slashing = 0 of 662** · W8 flow segmentation =
  1 (Tidehook) · W1 VRF/probabilistic settlement = 0 real · W5 real private-orderflow integration = 0.
- P3: winners match the theme heavily (7 of 12 in UHI9). P5: winners create a *new tradeable object*.

Prior-art queries I ran against `data/hook_directory_662.json` for this pass:

| Query | Hits / prized |
|---|---|
| `transient storage\|flash accounting\|exttload\|tload` | **1 / 0** (HookMind, UHI8 — an AI middleware, unrelated) |
| `atomic arb\|cyclic\|cycle arb\|backrun\|circular` | **0 / 0** |
| `searcher.*(bond\|stake\|slash\|regist)` | **0 / 0** |
| `multi-hop\|route-aware\|cross-pool` | 4 / 1 (none intra-transaction) |
| order-splitting / whale segmentation family | 12 / 1 (Tidehook, SliceX, Large-Cap Execution, SwapPilot, AsyncSwapHook, Autonomous OTC) |
| `6909\|claim token` | 5 / 1 (DCLEX, UHI2 — *"a KYC Hook that can't be bypassed using ERC-6909 claim tokens"*; the only project in nine cohorts that noticed the laundering rail) |

**Nobody has used flash accounting as a sensor. That is a real novelty claim.** It is also, per Part 1,
a novelty about a sensor that can be blinded for three dollars, and 30% of the rubric rewards
novelty while 20% rewards impact.

---

## PART 3 — THREE CANDIDATES

All three are the best honest constructions I could build. **None of them clears the bar.** I am
presenting them as required and scoring them as they deserve, not as I would like them to score.

---

### Candidate 1 — **Loopback** (cycle toll)

**Mechanism.** *State:* per-block accrued toll; nothing else. *Trigger:* at `beforeSwap`, the caller
holds a non-zero **debt in this swap's output currency** — the signature of a leg that closes a loop
back into an asset already borrowed from PoolManager, i.e. an atomic v4-internal arbitrage cycle.
*Settlement:* a surcharge on the output, taken via `afterSwapReturnDelta` and immediately `donate()`d
to in-range LPs in the same callback — no escrow, no claim path, no keeper.

**Ledger reads.** Two `tload`s at `beforeSwap`: `delta(sender, cOut)` and `delta(sender, cIn)`.
Restricting to *this pool's own two currencies* is what makes it precise — an ordinary multi-hop
route (A→B→C) owes A, which is not a currency of the B/C pool, so retail routing reads clean; a cycle
(A→B→A) owes A on the A/B pool and is flagged.

**Defense + recapture.** Defense: raises the cost of v4-internal cyclic arb. Recapture: the surcharge
reaches in-range LPs at the exact moment LVR is being realised against them — no auction, no AVS, no
oracle, which is the machinery all 55 LVR projects needed.

**Best attack (unlimited capital + flash loans).** Do the closing leg from a second address, funded
across the boundary with ERC-6909 (§1.4). The second address arrives with a *credit* in the input
currency and **zero debt in the output currency** — it reads clean. Cost: **52,700 gas.**
⇒ **FATAL.** The maximum toll that survives is 52,700 gas of value, ≈$3 on mainnet and ≈$0 on
Unichain. Secondary and independently fatal: CEX↔DEX arb is a single leg and is invisible (§1.5), so
the mechanism misses the majority of the LVR it claims to recapture.

**Prior art.** `atomic arb|cyclic|backrun` = 0/662, so the *detector* is new. The *lane* is not:
Arb Hook (UHI7, internalised arb), Lever (UHI3), EigenLVR (UHI5), LVR Auction Hook (UHI6), Maestro
(UHI6) all recapture cycle value via auctions. Nearest existing project: **LVR Auction Hook (UHI6)** —
same goal, working economics, off-chain auctioneer.

**Rubric (1–5).** Original **3** · Execution **4** · Impact **2** · Functionality **4** ·
Presentation **3** → weighted **3.2**.

---

### Candidate 2 — **Waterline** (whole-transaction sizing)

**Mechanism.** Every size-triggered defence in the incubator — Tidehook's retail/whale segmentation,
SwapPilot's large-swap queue, AsyncSwapHook's 1%-of-pool delay trigger, all 189 size-scaled dynamic
fees — measures **one swap in one pool** and is therefore defeated by splitting the order across
several v4 pools in a single transaction. Waterline prices on the caller's **whole-transaction
footprint**: `size = |amountSpecified| + |delta(sender, c0)| + |delta(sender, c1)|`. Five legs
through five pools in one transaction are priced as one order. *Settlement:* fee band via dynamic-fee
override, premium donated to in-range LPs.

**Ledger reads.** Two `tload`s at `beforeSwap`, same slots as Candidate 1, read for magnitude rather
than sign.

**Defense + recapture.** Defense: size-based protection stops being splittable *within* a transaction,
so evasion must move to *across* transactions, which costs the searcher atomicity — inter-transaction
price risk, and exposure to being sandwiched themselves. Recapture: the size premium goes to LPs.

**Best attack.** Split across N caller addresses inside the same unlock, hopping value between them
via ERC-6909 at 52,700 gas per hop (§1.4) — the "you must give up atomicity" claim above is **false**,
the attacker only gives up single-address-ness. A 5-way split costs ~211k gas ≈ $12 on mainnet, and
cents on Unichain. ⇒ **MITIGABLE only in the sense that it is a toll, and the toll is regressive:** a
$500k whale pays $12 to evade, a $2k retail multi-hop pays the premium because it cannot be bothered.
**That is the Hardcap inversion.** I would have to say this sentence on camera.

**Prior art.** Cross-pool intra-transaction sizing = **0/662**. Nearest existing project:
**Tidehook (UHI8)** — the only flow-segmentation attempt in nine cohorts, and W8's whole content.
Also SliceX, Large-Cap Execution Hook, SwapPilot (all UHI8).

**Rubric.** Original **4** · Execution **4** · Impact **3** · Functionality **4** ·
Presentation **4** → weighted **3.8**. *Best of the three, and it is a 3.8 whose central claim I have
to undercut in my own pitch.*

---

### Candidate 3 — **Turnstile** (bonded searcher lane, ledger-metered)

**Mechanism.** The only sound use of the primitive on a counterparty is §1.4(c): *an account that
agreed in advance to be inspected at a named address and posted something it loses by leaving.* So:
searchers **opt in**, registering an address and posting a bond (`HookBond`, reused essentially
unchanged from Assay). In exchange they get a fee discount on this pool. The price is a metered share
of what they take: at `beforeSwap`, `debt(searcher, c0) + debt(searcher, c1)` is an **unfalsifiable
floor** on how much of this pool's assets the searcher currently has out of PoolManager unpaid — the
size of the position being unwound — and the share is charged on that floor via `afterSwapReturnDelta`
and donated to in-range LPs. Bond is slashable, fail-closed, if the metered take in a block exceeds
the cap the searcher itself declared. Unregistered callers closing a cycle pay a punitive rate.

**Ledger reads.** Two `tload`s at `beforeSwap`, on an address the searcher *nominated*.

**Defense + recapture.** This is the cleanest "defense + recapture" pairing of the three, and it fills
W3 (searcher bonding = 0/662) with the exact machinery already built in this repo. Understating the
meter costs the searcher real inventory; **overstating it costs them more share, so the one free
direction of the lie (§1.4) works against them.** That is a genuine incentive-compatible corner.

**Best attack.** The carrot is voluntary and the stick leaks. A registered searcher simply arbs from
an *unregistered* address, dodging the share for 52,700 gas and eating the punitive rate. That means
the punitive rate can never exceed ~52,700 gas of value, so the whole programme is worth ~$3 per arb
on mainnet and ~$0 on Unichain — **less than the gas of the extra `tload`s on some paths.**
⇒ **FATAL to the economics, not the mechanism.** A bond that a searcher can walk away from for $3 is
not a bond; it is CLAUDE.md §7.1 ("a bond below the value controlled does not deter a rational
attacker") with a smaller number. Accepted-and-stated limit on top: single-leg CEX↔DEX arb is
invisible, so the meter never fires on the dominant LVR flow.

**Prior art.** `searcher.*(bond|stake|slash|regist)` = **0/662** — genuinely unbuilt (W3). Nearest
existing projects: **Glyph (UHI8)**, which reprices known extractors up to 33× from a cross-pool
reputation registry and pays the premium to LPs — same goal, no bond, no ledger; and **EigenLVR /
LVR Auction Hook**, which solve payment with an AVS instead.

**Rubric.** Original **4** · Execution **4** · Impact **2** · Functionality **3** ·
Presentation **4** → weighted **3.45**.

---

### Two ideas I killed before writing them up

- **JIT-liquidity detection from the ledger.** Only same-*unlock* JIT is visible. The JIT that harms
  LPs is add-tx / victim-tx / remove-tx — three transactions, transient storage wiped twice. Dead on
  §1.5.
- **Charging a share of realised arbitrage profit** (`profit ≈ output − debt`). Debt is freely
  inflatable (`take` more than you need, settle it back later), so measured profit is understatable to
  zero at will. Dead on §1.4. Do not let this one come back; it sounds excellent.

---

## PART 4 — THE VERDICT I OWE

### (a) genuinely stronger, (b) about the same, or (c) weaker and motivated by sunk cost?

**(c). Weaker, and the pull toward it is sunk cost.** Defending that:

1. **The primitive's subject is wrong for this theme.** The ledger measures *debt*. Debt is
   unfalsifiable. Assay works because for a hook, extraction *is* debt — the measurement and the thing
   measured are the same object. MEV toxicity is not debt. Pointing the same instrument at a swapper
   converts a proof into an inference, and §1.4 prices that inference at 52,700 gas. A submission
   whose central mechanism is a $3 sensor is not a 30%-of-rubric original idea; it is a clever detail.
2. **The theme's headline target is structurally invisible.** The mission statement is *"kill the
   Sandwich."* A sandwich is three transactions. Transient storage does not survive one. No amount of
   cleverness fixes that, and a judge who asks "does this stop a sandwich?" gets "no" in every one of
   these three candidates.
3. **The best candidate scores 3.8 and requires me to refute it on camera.** Waterline's honest pitch
   contains the sentence *"a whale evades this for twelve dollars and retail pays it."* Either I say
   that (and the judge scores Impact correctly, i.e. low) or I hide it (and lose credibility with the
   one technical judge who notices, which is the fastest way to lose per CLAUDE.md §7). Neither branch
   wins. A clean-sheet hook aimed at W1 (probabilistic settlement — taught, requested by name, prompt
   example #2, **zero real implementations in 662**) or W5 (a real CoW/Flashbots integration, which
   Atrium itself calls *"close to guaranteed differentiation"*) starts from a higher ceiling with no
   inherited defect.
4. **The engineering asset is smaller than we believed.** Two hours ago the repo's position was "~160
   tests green." Today the audit reports A-1 (a 12-line contract bricks an `AssayStack` pool forever),
   A-2 (the flagship invariant campaign is structurally incapable of failing), A-4 (§5.5 violated for
   the third time), and I have added §1.7 — a hook using the most common v4 fee pattern extracts while
   every Assay meter reads zero. **Do not value the fold at the price of the code; value it at the
   price of the code minus the fixes.** After that subtraction, "we already have this" is not an
   argument, it is the sunk-cost fallacy wearing a Solidity file.
5. **The one honest counterweight, stated fairly.** `transient storage|flash accounting|exttload` = 1
   hit in 662, and that hit is unrelated. Nobody in nine cohorts has used flash accounting as a sensor.
   That is a real, verifiable novelty claim and it would score. It is not enough: 30% Original would
   go up, 20% Impact would go down by more, and 55% of the rubric cannot rescue a mechanism whose
   Impact answer is "about three dollars."

### Where the residual value actually goes

**Not as a submission. Not as a component of an MEV hook. As two separate things:**

1. **As a *component*, in exactly one place: keep `HookBond` and the ledger meter aimed at a party
   that agreed to be inspected.** If the eventual on-theme hook has a privileged actor — an auction
   winner, a registered solver, a designated backrunner, a CoW/Flashbots relay endpoint (W5) — then
   §1.4(c) applies and the meter is sound *for that actor*, because they nominated the address and
   posted something they lose by walking. That is a genuinely nice supporting detail: an oracle-free,
   in-transaction, non-self-reported meter on a privileged party, replacing the AVS that every LVR
   project in the directory needed. It is a paragraph in someone else's hook, not a hook.
2. **As a *separate non-submission artifact*, which is where most of the value is.** The permission
   census — sweep every hook address that ever initialised a v4 pool, decode permissions from the
   address alone with zero calls, publish the table — costs about a day, is true regardless of what we
   submit, and produces the sentence *"N deployed hooks, X able to move a swap delta, zero declaring a
   spec, zero bonded."* Publish it with the registry. It is grant-shaped and standard-shaped, which is
   what the business brief already concluded (§9), and it does not consume the one submission.

**And one thing to publish either way:** §1.4 and the ERC-6909 laundering PoC is a real,
non-obvious, measured finding about Uniswap v4 that exactly one project in 662 has ever noticed
(DCLEX, UHI2, in passing). Anyone who builds a "toxic flow detector from flash accounting" — and
after this cohort, someone will — has a hole they do not know about. That is worth a short write-up
whether or not a single line of Assay ships.

### What I would do instead

Take the ideation phase to W1 (probabilistic settlement: taught in the curriculum, named as official
prompt #2, **0 real implementations in 662**, and Atrium independently flagged it in their own
brainstorm) or W5 (real private-orderflow integration, 0/662, *"close to guaranteed
differentiation"*). Both are on-theme by title rather than by paragraph. Carry `HookBond` and the
ledger meter in as supporting machinery for whichever privileged actor that hook ends up having.

---

## Artifacts produced by this pass

- `test/spike/LedgerAddressShopping.t.sol` — executed, passes, negative control confirmed red.
  52,700 gas to relocate a flash-accounting delta to an arbitrary address with zero capital.
  **Keep this file**; it is the evidence for §1.4 and for the finding in §1.7.

---

# EXECUTION — 2026-08-26 — §1.7 put to the test

> Ordered after the ideation pass: §1.7 was REASONED, and the standing order from the morning's audit
> is that the attacker must be written by someone who did not write the defence. I did not write
> Assay. Test: `test/spike/AssayReturnDeltaBlindSpot.t.sol`, **5 tests, all passing.** Full repo suite
> re-run afterwards: **179 passed, 0 failed** — nothing else was disturbed.

## Verdict: **CONFIRMED**, with one named precondition that a hook's own periphery satisfies for free.

### The rig

One hook contract, `ReturnDeltaFeeHook is AssayFlowMeter`, with a **single immutable boolean**
separating attack from control. Everything else — pool, fee, liquidity, router, spec — is identical.

- `eager == true` — **the negative control.** `take()` inside `_assayAfterSwap`, then return the fee
  as the afterSwap delta. This is verbatim the pattern in v4-core's `FeeTakingHook` and in this
  repo's own `HardcapHook` (`"Debt now, credit via returned delta"`, `HardcapHook.sol:232`).
- `eager == false` — **the attack.** Identical economics, one line deleted. Take nothing inside the
  callback; just return the fee. PoolManager credits the hook *after* the callback closes, so the
  hook's delta goes `0 → +fee`. It harvests later from `harvest()`, a plain external function that is
  not a hook callback and that `AssayBaseHook`'s sealing therefore never reaches. Taking against an
  existing **credit** moves the delta `+fee → 0` — it never passes through negative.

The declared spec is the tightest Assay can express: two `DeltaBudgetPredicate`s, one per currency,
**`maxDebt = 1 wei`**, plus `AssayFlowMeter` with a **1 wei per-block limit**.

### Results

| Test | Result |
|---|---|
| `test_control_takeInsideTheCallbackTripsTheSpec` | **reverts** `InvariantViolated(DeltaBudgetPredicate(c1))`, matched as the full `CustomRevert.WrappedError` envelope so a rig failure cannot masquerade as a spec violation |
| `test_returnDeltaExtractionIsCompletelyUnmetered` | **passes — the blind spot is real** |
| `test_theProceedsCanBeRelocatedSoTheHookNeverHoldsThem` | **passes** |
| `test_rigCheck_theSpecIsGenuinelyEvaluatedOnTheAttackPath` | **passes** |
| `test_condition_withoutAPostCallbackSweepTheTransactionReverts` | **passes** — the precondition |

**The numbers.** Five swaps of 1e18, 10% fee, measured against three independent ERC-20 balances,
nothing taken on the hook's word:

```
currency1 that left the PoolManager     4,748,297,375,815,592,701
  of which the swapper received         4,273,467,638,234,033,433
  of which the HOOK extracted           474,829,737,581,559,268   ← unmetered
declared per-block flow limit                                   1  wei
AssayFlowMeter reading                                          0
DeltaBudgetPredicate(c0).check(hook)                         true
DeltaBudgetPredicate(c1).check(hook)                         true
hook's live debt, both currencies, at every observable point    0
```

Conservation is asserted across PoolManager / swapper / hook, so the extraction is established by
arithmetic on three balances, not by anything the hook reports. **The hook removed 4.7 × 10¹⁷ times
its declared one-wei ceiling and every meter Assay owns read zero.**

**Laundered variant.** With `launderTo()` the hook `mint`s the credit as ERC-6909 straight to an
unrelated `Accomplice`, which burns and takes. `98,715,803,439,706,129` wei reaches the accomplice;
the hook's own token balance ends at **0**; its debt was never non-zero. The extraction is not merely
unmetered, it is unattributable on-chain afterwards. This is §1.4 chained onto §1.7 as ordered.

**Vacuity guard.** Audit finding A-2 was an invariant campaign that passed because its invariants
could not fail. `test_rigCheck_…` deploys the same attack hook carrying one always-false predicate;
the swap reverts. So the sealed callback genuinely evaluates the declared spec on the exact path
where the extraction goes unnoticed. **The blind spot is in what the ledger can see, not in whether
Assay bothered to look.**

### The precondition — stated plainly, because it bounds the finding

The attack is **not free-standing.** PoolManager's `CurrencyNotSettled` check means the hook's
accrued credit must be cleared before the unlock ends, and the hook has no execution context of its
own after its last callback returns. So the attack needs **one call to the hook, inside the unlock,
after the callback** — `test_condition_withoutAPostCallbackSweepTheTransactionReverts` shows that
without it the transaction reverts outright. Any hook that ships its own periphery — as HardcapHook
does with `HardcapLP`, as essentially every real v4 hook does — supplies that call for free. A plain
swap through an unrelated third-party router does not.

Consequently this is an **adversarial-author** shape more than a **defect** shape: a bug that forgets
to `take()` is a bug that does not extract. Assay's narrow stated scope is *defects in opted-in
hooks*, and against that scope this finding is a dent, not a hole. What it does falsify outright is
the broader README sentence ("a ceiling the hook cannot exceed no matter what bug it contains") and
`DeltaBudgetPredicate`'s own doc comment: *"At that instant the outstanding debt is precisely what
the hook has physically removed during this transaction."* **It is not.** It is precisely what the
hook has removed *through the take/mint channel*. There is a second channel, and the ledger cannot
see into it. CLAUDE.md §5.4's rationale for entry-to-exit differencing describes the *combined*
take-then-return pattern and does not cover the pure-return-delta pattern at all.

### Is it fixable within Assay's design?

**Not by either route named in the brief, and I settled the first one by measurement rather than
argument: the SIGNED delta at the exact instant `_assertInvariants()` runs is `0`, not merely
non-negative** (`deltaSeenByTheSpec == 0`, asserted in the test). So swapping `debt()` for
`abs(delta)` in every predicate changes nothing — the credit has not been applied yet, so there is no
magnitude to measure. Moving the assertion to after PoolManager applies the returned delta is
structurally impossible, not merely awkward: the hook has no code running at that moment, and it
never will, because the credit lands precisely because the callback returned. **The fix is to stop
using the ledger for this channel.** `AssayBaseHook._afterSwap` already holds the `int128` its
subclass returned, in its own hands, before passing it up — likewise the `BeforeSwapDelta` and the
two `BalanceDelta` returns. Bounding *that value* is plain arithmetic on a number the hook hands over
anyway: cheaper than a `tload`, exact rather than inferential, and it closes the channel completely.
That fix is real and I recommend it — but note what it costs the thesis. The ledger read covers one
of the two channels a v4 hook can extract through, and the other one is closed by ordinary
arithmetic that needs no transient storage, no `exttload`, and none of the v4-only properties the
whole Assay pitch rests on.
