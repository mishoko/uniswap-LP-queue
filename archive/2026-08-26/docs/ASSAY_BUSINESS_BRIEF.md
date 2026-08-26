# Assay — business brief

*Written for a decision, not for marketing. Version 2026-08-26. Technical ground truth is being
verified in parallel (`docs/research/ASSAY_GROUND_TRUTH.md`); §9 is preliminary until that lands.*

---

## 0. The one-paragraph version

A Uniswap v4 hook is a piece of code that runs on **every single swap and every liquidity movement**
in a pool, and it can take money out of that pool. Today, when a hook says "I only ever take 0.1% and
I never touch LP principal," there is nothing anywhere that checks. Assay makes that sentence into a
contract term: the author inherits one base contract, names a small set of promises, and stakes ETH
behind each one. From then on **the hook physically cannot complete a transaction that breaks a
promise** — the swap reverts — and anyone can read, in one call, what the hook is *allowed* to do,
what it *promises*, whether the promise *currently holds*, and *how much money* is behind each
individual promise.

---

## 1. Answering the question you actually asked

> *"In simple terms — is it a wrapper hook that some protocols would use to just prove to customers
> they are not malicious? Is that the main driver and use case?"*

**Half right, and the half that's wrong is the important half.**

Yes, it is a wrapper: you inherit `AssayBaseHook` instead of the standard `BaseHook`, and everything
else follows.

No, "prove you are not malicious" is **not** the driver, and pitching it that way is how this loses.
Intent is not provable, and a genuinely malicious author simply would not inherit the wrapper. If
that were the pitch, the honest reply is "so it only protects me from the people who were never going
to hurt me," and that reply is correct.

The actual driver is different and much stronger:

> **Assay does not try to prove the author is honest. It makes the damage bounded regardless of why
> the damage happened.**

The two exploits everyone in this ecosystem cites — Cork (a callback-authorization bug) and Bunni
(rebalancing math) — were not malicious authors. They were *defects in code written in good faith*.
No amount of "trust me" would have helped, and no audit caught them. What would have helped is a
ceiling that the code cannot exceed no matter what bug it contains.

So the business framing is:

| Weak framing (avoid) | Real framing (use) |
|---|---|
| "A badge that says this hook is safe." | "A ceiling on how much a hook can remove, enforced by Uniswap's own ledger, that holds even when the hook is broken." |
| "Proof the author isn't malicious." | "Proof of what the author *cannot do*, independent of the author." |
| "An audit substitute." | "The thing that keeps working after the audit missed something." |

### Why this is possible in Uniswap v4 and nowhere else

Two facts, both load-bearing, both verified in our repo:

1. **The PoolManager keeps a live running tab of what every account owes it, in transient storage,
   and that tab is publicly readable mid-transaction.** So halfway through a hook's own callback,
   from outside, anyone can read *exactly how much that hook has removed and not yet paid for*. The
   hook does not own that number and cannot misreport it. It is Uniswap's number, about the hook.
2. **A hook's permissions are encoded in its address**, and the PoolManager enforces them. So "can
   this hook move a swap's price/output?" is answerable from the 20-byte address alone — no calls, no
   bytecode, no trust, for any address, deployed or not, forever.

Point 1 is what makes an unfalsifiable spending limit possible. Point 2 is what makes a *free*,
universal risk report possible across every hook that will ever exist. Neither exists for an ordinary
ERC-20 or lending protocol.

---

## 2. The five parts, in plain terms

| Part | Plain-English role | Business analogy |
|---|---|---|
| `AssayHook` | Holds the list of promises and refuses to proceed if one is broken. | The covenant enforcement clause. |
| `AssayBaseHook` | The wrapper you actually inherit. Seals every money-moving callback so enforcement **cannot be forgotten or removed** by the developer using it. | Escrow: the check happens whether or not the counterparty remembers. |
| `AssayFlowMeter` | Optional add-on: a *per-block* ceiling, not just a per-transaction one. | A daily withdrawal limit on top of a per-transaction limit. |
| `HookBond` | Cash staked **per individual promise**. Anyone who proves one promise false takes a bounty out of *that promise's* tranche. | A performance bond with itemised sureties. |
| `AssayRegistry` | One read call returns: permissions, promises, whether they hold right now, money behind each. | The credit report / term sheet. |
| `AssayStack` | Lets several untrusted hooks share one pool, each inside a hard spending budget. | Sub-leasing a floor of your building to a stranger, with a metered account. |
| `AssaySuite` | A drop-in randomised attack campaign any hook repo can inherit to try to break its own promises before shipping. | The pre-audit stress test you hand your auditor. |

### `AssaySuite`, specifically (you asked)

It is **not** deployed on-chain and is not part of the product surface. It is a testing library:
you inherit it in your Foundry test file, write a `setUp` and two getter functions, and it runs
thousands of randomised swaps and liquidity operations trying to make your declared promises false.
It also asserts that the campaign *actually did something* — a run where every operation reverted
would otherwise "pass" all invariants while proving nothing. (That exact failure mode has already
happened once in this repo. See `CLAUDE.md` §5.7.)

Commercially it is the **on-ramp**: a developer adopts the test library for free, and the test
library's output is a spec that is one line away from being enforced on-chain and bonded.

---

## 3. How invariants actually work — and why they are addresses

You noticed the promises are "always addresses for some reason." Here is the reason, and it is a
feature rather than an implementation quirk.

**A promise is a deployed contract.** Its address *is* the identity of the promise, because the
address commits to both the logic and the numbers:

```
DeltaBudgetPredicate deployed with (PoolManager, USDC, 5_000e6)
        ↓
address 0x9a3f…c1        ← this address means, permanently and unchangeably:
                            "the hook's unpaid tab with the PoolManager,
                             in USDC, never exceeds 5,000 USDC"
```

The parameters (which token, what ceiling, which pool) are frozen into the contract at deployment as
immutables. Consequences that matter commercially:

- **You cannot silently renegotiate.** Raising your own spending limit from 5,000 to 50,000 means
  deploying a *different* contract at a *different* address. The address in the registry changes.
  Everyone watching sees it. Compare with a `setMaxSpend()` admin function, where the same change is
  a single transaction nobody notices.
- **The promise is reusable.** One `NoSwapDeltaPredicate` serves every hook in the world; it takes
  the hook as an argument. Common promises become shared public goods; specific ones (your budget,
  your floor) are cheap one-off deployments.
- **The bond attaches to the address.** "40 ETH staked on `0x9a3f…c1`" is unambiguous about *which*
  claim the money is behind.
- **A machine can compare two hooks.** Same predicate address = literally the same promise. No
  natural-language ambiguity.

The interface is deliberately tiny:

```solidity
interface IHookPredicate {
    function check(address hook) external view returns (bool);   // true = promise holds
    function describe() external view returns (string memory);   // human sentence, for the registry
}
```

### Three verdicts, not two

This is the part that took the most engineering and is the most defensible:

| Verdict | Meaning | During a swap | During an LP withdrawal |
|---|---|---|---|
| `HOLDS` | Promise is true right now | proceed | proceed |
| `VIOLATED` | Promise is false right now | **revert the transaction** | **revert** |
| `INCONCLUSIVE` | The promise could not be evaluated — it reverted, ran out of gas, tried to change state, returned garbage, or tried to re-enter | **revert the transaction** | **allow the withdrawal, emit a public alarm** |

`INCONCLUSIVE` exists because a promise-checker is untrusted code too. Without it, a hostile checker
could report "violated" to slash an honest hook for free, or a broken one could report "holds" and
make a dishonest hook unslashable. Every hostile behaviour we could construct — revert, out-of-gas,
attempted state mutation, reentrancy, a 128KB returndata bomb, malformed output — reads
`INCONCLUSIVE` and never `VIOLATED`.

The withdrawal carve-out is a deliberate, stated asymmetry: the promise list is immutable with no
recovery path, so a checker that permanently stopped answering would otherwise **trap every LP's
capital in the pool forever**. Doubt fails closed everywhere except on the way out.

### Where it runs

```
Swap arrives
   │
   ▼
PoolManager ──► hook.beforeSwap ──► [your logic] ──► CHECK ALL PROMISES ──► ok? continue : REVERT
   │
   ├─ price moves, tokens change hands
   ▼
PoolManager ──► hook.afterSwap  ──► [your logic] ──► CHECK ALL PROMISES ──► ok? continue : REVERT
```

The check is placed at the **end** of each money-moving callback, by the wrapper, not by the
developer. The developer writes `_assayAfterSwap` instead of `_afterSwap`; the sealed `_afterSwap`
calls their code and then runs the check. **A developer using Assay cannot remove or forget the
check** — the base contract does not mark those functions `virtual`, so the compiler refuses any
attempt to override them. Our test `test_enforcementSurvivesAnIntegratorWhoNeverCallsIt` deploys a
hook that declares a spec, drains on every swap, and never calls the check anywhere. It cannot
complete a single swap.

### Cost

| | gas per swap |
|---|---|
| Wrapper machinery, zero promises | 192 |
| + one balance-floor promise | 3,497 |
| + one ledger-budget promise | 4,509 |
| + per-block flow metering | 5,766 |

For context, a plain v4 swap is roughly 100–150k gas. One enforced promise is in the low single-digit
percent. This is not the reason anyone would decline.

---

## 4. What kinds of promise can and cannot exist

**The hard boundary:** a promise must be answerable by **one read-only call, from public state,
right now**. No history, no privileged inputs, no "who called this."

**Expressible.** Four families:

| Family | Cost | Example | Shipped |
|---|---|---|---|
| **Address-derived** (zero calls) | free | "this hook cannot alter a swap's output" · "this hook's permissions are exactly this set" | ✅ `NoSwapDeltaPredicate`, `PermissionMatchPredicate` |
| **Code identity** | ~1 opcode | "the code has not been swapped since bonding" | ✅ `CodehashPredicate` |
| **Uniswap's own ledger** | 1 call to PoolManager | "unpaid tab ≤ 5,000 USDC" · "spot price stays inside this band" | ✅ `DeltaBudgetPredicate`, `TickBandPredicate` |
| **Token / hook state** | 1–2 calls | "hook's USDC balance never drops below X" · "hook holds at least what it says it owes" | ✅ `BalanceFloorPredicate`, `SolvencyPredicate` |

**Not expressible, ever — and we say so out loud:**

- "This swap was priced unfairly." *(comparative/counterfactual, not present state)*
- "The hook stole from a user in block N." *(history)*
- "Fees are distributed fairly among LPs." *(fairness is not a present-state property — this is
  exactly why Hardcap's fairness claim was withdrawn rather than patched)*
- "The hook has not been upgraded behind a proxy." *(a contract cannot read another contract's
  storage; the implementation slot is off-chain-only)*
- "The author has no back door." *(unprovable in general)*

Being explicit about this list is a competitive asset, not a weakness. Every "hook safety score"
product that will show up in this space will quietly claim some of the above.

### Promises we do not yet ship but could — ranked by how legible they are to a non-engineer

| Promise | Business meaning | Feasible? |
|---|---|---|
| **"This hook has no admin."** `owner() == address(0)` | The single most-asked question about any DeFi contract, answered in one call and bonded. | Easy. Self-reported, so pair with a codehash pin. |
| **"This hook's fee never exceeds X."** read the pool's live fee from the PoolManager | Directly caps the user-visible cost. Very legible. | Easy — PoolManager state is publicly readable. |
| **"This hook holds no ERC-6909 claim balance beyond X."** | v4-native version of the balance floor; catches value parked as PoolManager credit rather than as tokens. | Easy, and closes a real gap in the current set. |
| **"Price stays within X% of an external oracle."** | Circuit breaker against oracle-driven or manipulation-driven drains. | Easy, adds an oracle dependency. |
| **"This hook serves only the declared pool."** | Blast radius containment. | Only if the hook exposes it (self-reported). |
| **"Reserves stay within a declared ratio band."** | Solvency for hooks that hold two-sided inventory. | Easy. |
| **Per-block ceilings**: LP outflow, price deviation, cumulative fees | Repetition is how per-transaction limits are defeated. Needs an accumulator mixin like the existing flow meter, not a plain predicate. | Medium — the pattern already exists and works. |

**How a promise gets bound to a project:** the author deploys the promise contract with their numbers
in the constructor, then passes its address into their hook's constructor. That list is immutable for
the life of the hook. There is no admin function to change it. Changing the spec means deploying a
new hook — which, for a pool users have money in, is a public and expensive act. That is the point.

---

## 5. Three worked examples

### Example A — a yield-bearing hook that needs LPs to show up

*A four-person team ships an auto-compounding fee hook. Their problem is not code; it is that no
serious LP will put $10M behind four strangers and an unaudited contract.*

```
BEFORE
  Team ──"we're safe, here's our README"──► LP
  LP: no. (or: waits 9 months for an audit + track record)

AFTER
  1. Team inherits AssayBaseHook instead of BaseHook.            (a one-line change)
  2. Team deploys two promises:
        P1 = DeltaBudget(PoolManager, USDC, 2_000e6)   "we never owe the pool >2,000 USDC mid-tx"
        P2 = NoAdmin()                                 "owner is address(0)"
  3. Team stakes:  30 ETH on P1,  5 ETH on P2.
  4. LP reads AssayRegistry.report(hook):

       ┌──────────────────────────────────────────────────────────┐
       │ hook 0x71c…                                              │
       │ permitted to:  beforeSwap, afterSwap  (CANNOT move delta)│
       │ declares:      2 promises, both HOLD right now           │
       │   • 30 ETH  "unpaid tab ≤ 2,000 USDC"                    │
       │   •  5 ETH  "owner is address(0)"                        │
       │ per-block ceiling:  10,000 USDC                          │
       └──────────────────────────────────────────────────────────┘

  Six weeks later a bug ships in v1.2 that would have drained the pool.
  The drain is not detected. It is REFUSED — every attempt reverts at the ledger check.
  The team finds out because their hook stopped working, not because their LPs lost money.
```

The value to the team is **distribution**: they can be underwritten before they have a track record.
The value to the LP is a **worst case they can size**, not a promise they have to believe.

### Example B — a DAO treasury allocating across hooks

*A treasury manager has 300 v4 hooks to choose between and no capacity to read 300 codebases.*

```
   for each of 300 hook addresses:
        AssayRegistry.reportMany(...)     ← one call, no per-hook integration

   Filter, mechanically:
     ├─ can move a swap delta AND declares nothing AND unbonded  →  reject outright
     ├─ declares a spec, bonded < 1 ETH                          →  "signal without substance"
     ├─ declares a spec, bonded > 20 ETH on the budget claim     →  shortlist
     └─ any promise currently reading VIOLATED / INCONCLUSIVE    →  alarm, exit position
```

Note what the registry deliberately does **not** publish: a grade. It publishes a *price* — money
staked, per claim. A grade invites you to outsource the judgement; a price makes you do it. That is a
defensible product decision and it is also the honest one, because we cannot actually grade risk.

### Example C — two teams, one pool (`AssayStack`)

*Uniswap v4 allows exactly one hook address per pool. A pool that picked a limit-order hook cannot
also have a fee-rebate hook. Historically, "composing" meant trusting a second codebase with the full
authority of the first.*

```
                       ┌─────────── AssayStack (the only address the PoolManager knows) ──────────┐
   swap ──► PoolManager│  budget: guest A ≤ 40%, guest B ≤ 30%, guest C ≤ 20%; stack ≤ 60% total  │
                       │                                                                          │
                       │   guest A ──► "I'd like 1000"   ──► granted 400   (clamped)              │
                       │   guest B ──► reverts           ──► SKIPPED, logged, pool unaffected     │
                       │   guest C ──► asks for uint.max ──► granted 200   (clamped, to the wei)  │
                       └──────────────────────────────────────────────────────────────────────────┘
                                    ▲
   A guest NEVER touches the PoolManager. It returns a NUMBER, which is clamped — it does not
   perform an ACTION, which would have to be trusted.
```

Fail-**open** for the guest (one broken guest must not brick a pool holding other people's money),
fail-**closed** for the pool. Immutable guest list, no admin — nobody can insert a guest into a live
pool. `test_fourGuestsOneHostileAndThePoolStillWorks` runs exactly this, including a guest that burns
all its gas and one that returns 128KB of junk.

Commercially this is arguably the most *interesting* piece and the least developed: it turns "one
hook per pool" from a hard constraint into a hosting market.

---

## 6. Lifecycle, end to end

```
  DEPLOY
    deploy promises (numbers frozen in) ──► deploy hook with the promise list (immutable)
                                              │
                                              ├─ if any promise is already false, the hook is
                                              │  bricked on arrival: it cannot serve one callback.
                                              ▼
  BOND
    author stakes ETH per promise ──► HookBond checks every promise HOLDS before accepting
                                        │
  RUN                                   ▼
    every swap ──► promises checked inside the callback ──► violation is UNEXECUTABLE
                                        │
  WATCH                                 ▼
    anyone reads AssayRegistry.report(hook) — permissions, promises, live verdicts, money per claim
                                        │
  CHALLENGE                             ▼
    someone proves promise #2 false ──► commit (hidden) ──► wait ──► reveal ──► bounty from
                                        tranche #2 only; tranches #1 and #3 remain fully backed
                                        │
  EXIT                                  ▼
    author requests exit ──► timelock ──► withdrawal is REFUSED if the spec no longer holds
```

The commit-reveal step exists so a searcher watching the mempool cannot copy a challenger's work and
front-run the payout. It reduces that theft; it does not eliminate it (a searcher pre-committing
across every possible pair can still race), and we assert that limitation in a test named after it.

---

## 7. Who actually pays for this

| Buyer | Their pain | What they buy | Willingness to pay |
|---|---|---|---|
| **Hook author / protocol** | Cannot attract LPs without a track record; audits cost $50–150k and take months | Underwritability before reputation | High — this is a go-to-market cost, not a security cost |
| **LP / vault curator / DAO treasury** | 300 hooks, no way to filter | A mechanical filter and a sized worst case | High, but they expect it free |
| **Router / frontend / aggregator** | Routing users through a hook that steals is *their* headline | A policy that is machine-enforceable | Medium — they'd consume the registry, not pay for it |
| **Underwriter / cover protocol** | Cannot price hook risk at all today | A bounded, machine-readable exposure | High, small market today |
| **Uniswap Foundation** | Hook proliferation is v4's biggest adoption risk and its biggest headline risk | Ecosystem-wide public good | Grant-shaped, not revenue-shaped |

**Honest read on the business model:** the registry and the predicate library are public goods with
no natural revenue. The monetisable surfaces are (a) the bond as a marketplace — take a fee on staked
capital or on slashes, and (b) `AssayStack` as hosting infrastructure — a pool operator renting
budgeted slots to guest hooks. Neither is proven. This is grant-and-standard shaped, not
product-shaped, and pretending otherwise in a pitch would be caught immediately.

---

## 8. How good is it now, and how good could it be

### Now — the engineering is strong, the evidence is thin

**Genuinely strong:**
- The core insight (read Uniswap's own transient ledger, mid-callback, from outside) is real,
  verified, and as far as we know unused by anyone else.
- Enforcement that a developer cannot forget or remove is a real property, not a claim.
- The three-verdict sandbox is properly hardened against hostile promise-checkers.
- Bond tranching per claim, with per-claim disclosure, is a better design than a single "bonded:
  yes/no" bit and is a direct answer to the obvious "pad the spec with cheap promises" attack.
- The project refutes its own marketing in public: our reference hook takes a fee via a swap delta,
  so the permission predicate **refuses to let its own author bond a claim to the contrary**,
  whatever the README says. Zero external calls establish that. It is the strongest demo we have.

**Genuinely thin — and these are credibility gaps, not code gaps:**
1. **Nothing is deployed anywhere.** No testnet address. "It exists on chain" is cheap and
   disproportionately convincing.
2. **Every demo attacks a straw man we wrote ourselves.** `LeakyHook`, `GreedyHook`, `DrippingHook`.
   A skeptic dismisses all of it in one sentence. Wrapping one *real third-party* hook and showing
   the diff converts "a base contract you could inherit" into "a base contract that demonstrably
   wraps someone else's real code."
3. **The single strongest available artifact does not exist**: sweep every hook address that has ever
   initialised a v4 pool, decode its permissions from the address with zero calls, and publish the
   table. The headline writes itself — *"N deployed hooks, X of them able to move a swap delta, zero
   declaring a spec, zero bonded."* That sentence is the entire argument for the project, it is
   measured rather than asserted, and it is about a day's work.
4. **We do not dogfood.** The attack campaign runs against one demo hook, not against our own
   contracts.
5. The bond has no victim-compensation path — slashed capital is locked forever. Deliberate (it must
   leave the author's reach) but it must never be described as insurance.

### Could be — the ceiling

If items 1–3 above were done, the pitch becomes: *"Here is a measured census of every live v4 hook
and what each is permitted to do; here is a real third-party hook wrapped so that its worst case is
bounded by Uniswap's own ledger; here it is deployed; here is money staked on each individual
promise."* That is a category-defining piece of ecosystem infrastructure and a plausible Uniswap
Foundation grant. The ceiling is high.

### How secure is it, really

Preliminary — the independent audit is in flight. Known and accepted:

- A bond smaller than the value a hook controls **does not deter a rational attacker.** Unfixable. It
  is a costly signal plus challenger funding, never insurance. One plain sentence, every time.
- A spec can be **padded with cheap promises**. Per-claim disclosure is the mitigation. Disclosure,
  not prevention.
- Fail-closed means **a badly written promise can brick a pool's trading**. Stated trade-off; LP
  exits are the deliberate exception.
- **Only opted-in hooks are bound.** The guarantee is against *defects*, not against malice.
- **Proxy upgrades are invisible on-chain.**
- **Challenge front-running is reduced, not eliminated.**

---

## 9. The verdict I owe you — and it is not the one the README wants

I will not soften this.

**As engineering: 4.5/5.** Genuinely novel primitive, unusually honest, well-hardened, cheap.

**As a UHI10 submission under the theme "Sustainable Liquidity and MEV Protection": 2.5/5, and the
gap is the theme, not the quality.**

- Assay contains **no MEV content whatsoever.** Not sandwich protection, not LVR, not order flow, not
  auctions, not JIT. Zero.
- Its connection to "sustainable liquidity" is real but **second-order**: LPs supply more liquidity to
  hooks whose worst case they can size. That is a true sentence and a genuinely good argument — but
  it is an argument you have to *make*, whereas a judge scoring against a theme is *matching*. A
  submission that needs a paragraph to establish theme fit is losing to one that needs a title.
- Its natural home is a *security / infrastructure / tooling* track, or a Uniswap Foundation grant.
  If UHI10 has such a track, this changes materially. **Confirming whether it does is the single
  highest-value unknown right now** and is being researched.

**Second concern — it is not one hook, it is a platform.** Seven contracts, a testing library, a
registry, and a bond market. Hackathon judges reward one sharp mechanism they can understand in
eight minutes. Assay currently requires understanding a thesis. The one-hook version of Assay ("a
hook whose spending limit is enforced by Uniswap's own ledger, staked with 30 ETH, here it is live on
testnet") would score *better* than the platform, because it fits in a sentence.

**What I recommend, concretely:**

1. **Do not kill Assay.** The ledger insight is the best asset this repo has produced and it survives
   any pivot — it can be a component of a different hook rather than the whole product.
2. **Do not submit it as-is** unless the research comes back showing a security/tooling track, or
   showing that the "MEV Protection" framing is broad enough to include "protection from the hook
   itself." Both are plausible; neither is verified yet.
3. **Run the ideation phase properly** against the theme, with the panel and frontier models. If
   nothing beats Assay on theme fit *and* novelty, ship Assay — narrowed to one hook, deployed, with
   the census table. If something does, Assay's ledger primitive gets folded into it.
4. **Either way, build the census table this week.** It costs a day, it is true regardless of which
   hook we submit, and it is the most persuasive single artifact available to us in any framing.

---

## 10. Glossary for non-engineers

| Term | Means |
|---|---|
| **Hook** | Code that Uniswap v4 calls on every swap / liquidity change in a pool. Powerful; can take money. |
| **PoolManager** | Uniswap v4's central contract. Holds all the money for all pools. |
| **Callback** | A moment when the PoolManager hands control to the hook (before a swap, after a swap, …). |
| **Delta / the ledger** | Uniswap's running tab of what each party owes it inside a single transaction. |
| **Predicate** | One deployed promise, with its numbers frozen in. Identified by its address. |
| **Fail-closed** | When in doubt, refuse. The transaction reverts; nobody loses money, but nothing happens. |
| **Bond / tranche / slash** | Staked money; the slice of it behind one specific promise; taking a bounty from that slice by proving the promise false. |
| **Straw man** | A fake attacker we wrote ourselves to demo against. Convinces nobody outside the room. |
