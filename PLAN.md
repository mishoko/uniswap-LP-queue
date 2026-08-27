# PLAN.md — QUEUE: price–time priority for Uniswap v4 liquidity

**Status:** written 2026-08-26. This is the build plan. It is a **living document** — when reality
diverges from it, update it (see §F.5).

**Who this is for:** an agent or engineer with zero prior context on this project. You do not have
the conversation that produced this document and you do not need it. Everything you need is here or
at an exact path named here. Where a claim was proven by an executed experiment, the path to that
experiment is given. Where something is unproven, it says **UNPROVEN**.

**Read order:** `AGENTS.md` (how to work here) → **this file** → `PROGRESS.md` (what is already
done) → `PITFALLS.md` (the standing hazard ledger — re-read every session) → the archive and
`docs/research/`, on demand, guided by §I.

---

# TABLE OF CONTENTS

| § | Section | Read when |
|---|---|---|
| **A** | Orientation — what this is, what "done" means, repo, toolchain | First, all of it |
| **B** | The mechanism, specified precisely | Before writing any contract code |
| **C** | Phased build plan, with entry/exit criteria | Before starting each phase |
| **D** | **Evals, verification and validation** — the most important section | Constantly. Re-read before every gate |
| **E** | Gotchas, footguns, dangerous areas | Before writing code, and again when something is weird |
| **F** | Operational — progress log, commits, handoff | End of every working session |
| **G** | Persona and working method | First, then at every phase gate |
| **H** | Deployment recommendation | Phase 7 |
| **I** | References — every archived document and when to read it | On demand |

---
---

# A. ORIENTATION

## A.1 What this project is

This repository is a submission-in-progress for **UHI10**, cohort 10 of the Uniswap Hook Incubator
(Atrium Academy). The theme is *"Sustainable Liquidity and MEV Protection."* Exactly **one**
submission is permitted. The product is a **Uniswap v4 hook** — a smart contract that the v4
`PoolManager` calls at defined points in a pool's lifecycle.

Everything that came before this plan — four dead candidates, ~100 rejected ideas, a security
platform, a compliance-gate lane, four fee mechanisms — has been archived under
`archive/2026-08-26/`. That archive is **history and evidence**, not instructions. This plan and
`AGENTS.md` supersede it. The one part of the archive that is still operative doctrine is
`archive/2026-08-26/CLAUDE.md` **§5**, the 25 hard-won v4 facts; those are reproduced and expanded in
§E of this document so you do not have to go looking.

The candidate that survived is **QUEUE**. It was honestly scored **4.33 / 5** on the published
rubric after a spike that executed rather than asserted its riskiest claim. The scoring, the
alternatives, and the reasons the alternatives died are in
`archive/2026-08-26/docs/research/IDEAS_OBJECTS.md`.

## A.2 What QUEUE is — three paragraphs

**Paragraph one — the object.** QUEUE mints a new tradeable object: **a transferable claim on where
in the fill order your capital sits.** Today, two liquidity providers at the same tick with the same
capital hold identical assets — every swap fills them pro-rata, in proportion to their share. Under
QUEUE they hold *different* assets: one is filled first by every swap, including the small ones; the
other is filled only when a swap is large enough to sweep through to it. That difference is the
object. It is scarce, it is transferable, and it can be priced by a market.

**Paragraph two — the machinery.** The hook custodies **all** of the pool's liquidity in a single
full-range position that it owns itself, and refuses every external attempt to add liquidity — so the
hook's own ledger *is* the pool's ledger. It keeps an ordered array of **seats**, each holding a
token0 and a token1 balance. On every swap, in `afterSwap`, the hook receives the realised
`BalanceDelta` from `PoolManager` — and therefore knows the swap's **realised average price**, a
number the hook did not choose, cannot influence, and does not have to trust. It allocates the fill
**front-first** rather than pro-rata: the head seat surrenders as much of the outgoing token as it
holds and receives the incoming token at that realised average price; the fill walks to the next seat
only when the head is exhausted. A depositor withdraws whatever their seat currently holds. Rank
transfers move the seat's *position in the queue*; the capital stays with the person who deposited
it.

**Paragraph three — why it is worth building.** Adverse selection — the cost of being the LP holding
the wrong side when someone else already knows the price moved — is today an **unpriced,
undiversifiable cost smeared pro-rata across every LP**. QUEUE turns it into a **priced,
transferable position** and lets it be routed to whoever will bear it cheapest. A professional
market maker who can hedge inventory elsewhere wants maximum flow per unit of capital and will pay
for the front. Passive capital — a treasury, an LST issuer, a yield vault — would rather be paid a
known amount up front than discover its adverse-selection cost after the fact, and will sell the
front. **If flow is toxic instead, the sign flips**: the front must be *paid* to stand there, and
the size of that payment is the pool's toxicity, denominated in the pool's own numéraire, discovered
by capital rather than asserted by a formula. Unforgeable, because the bid costs real money.

## A.3 The single most important sentence

> **Every concentrated AMM is a pro-rata market. Every real electronic market on earth is price–time
> priority, and queue position is the single most valuable asset in electronic market making.
> Uniswap has never had a queue, so it has never had a price for one.**

Say this first, in the README, in the video, and to any judge. Everything else is implementation.

## A.4 What QUEUE is NOT — say these out loud, every time

Hiding a limitation is the fastest way to lose a technical judge. These are not weaknesses to be
managed; they are the honest scope, and stating them is what makes the rest credible.

| Claim we do NOT make | The truth |
|---|---|
| "QUEUE stops sandwich attacks." | It does not. Swaps execute normally, at the normal price, through any router. |
| "QUEUE reduces LVR." | It does not. **Total LVR paid by the pool is unchanged.** What changes is *who bears it and at what known price*. |
| "QUEUE recaptures value from searchers." | It does not. It creates no new payment and takes nothing from anyone. |
| "QUEUE detects toxic flow." | It does not, **and it must not try** — proven impossible (§E.19). It sells LPs different slices of the flow and lets them bid. |
| "The queue's face value is redeemable." | **Not until BOTH are resolved: (a) the Phase 2 dust fix is built and proven** — measured ~0.26 wei/swap shortfall (§E.4) — **and (b) per-seat withdrawal feasibility.** §B.7's withdraw spec is MEASURED impossible as specified: after the spike's own 4-swap scenario seat 1 holds 258.877 token0 / 0 token1 and can withdraw **nothing** via `modifyLiquidity(−Δ)` (`PITFALLS.md` §5.5, §5.7; `docs/research/protocol-fee/queue-exposure.md` §A2). Conservation ≠ solvency (§D.1 LAW 3, second corollary). |
| "Sweeps are O(1)." | **They are O(entries touched).** The O(1) redesign is named, unbuilt and unverified (Phase 5). |

The honest answer to *"the theme slide says neutralize the attack and recapture the value — where is
that?"* is:

> *"We did not find a way to destroy adverse selection — it is provably irreducible for any
> deterministic curve. So we made it a tradeable asset and let the market price it. This is the first
> time an AMM has produced a price for its own toxicity."*

That is an answer to a different question than the one on the slide, and it is a good one. Do not
let anyone dress it up as the same question.

## A.5 What "done" means

Two bars. Clear both.

**Bar 1 — the binary gates.** Miss any one of these and the submission is not judged at all. Source:
`archive/2026-08-26/docs/research/HACKATHON_CONTEXT.md` §1.

1. Public GitHub repo.
2. Demo/explainer video, **≤ 5 minutes, no AI voices** (an AI voice marks you down *and* blocks Demo
   Day).
3. A real Uniswap v4 hook.
4. Code newly written during the hookathon window.
5. README listing partner integrations, or stating "No partner integrations."
6. New code for returning teams.
7. Originality — no uncredited curriculum or workshop code.
8. **Tests OR a working frontend.** We are shipping tests. No tests and no frontend = no prize
   judging.

**Bar 2 — the scored rubric** (weights are the organizers', verbatim):

| Weight | Criterion |
|---:|---|
| **30%** | Original Idea |
| **25%** | Unique Execution |
| **20%** | Impact |
| **15%** | Functionality |
| **10%** | Presentation |

**Read that honestly: 55% is novelty plus distinctiveness of construction; only 15% is "does it work
well."** That is not licence to ship something broken — "robust and sustainable code is a hard
requirement" from the owner, and a hook whose core arithmetic is wrong is worthless at any weight.
It *is* licence to stop gold-plating once the mechanism is correct, legible and demonstrated.

**Done, operationally**, is the checklist in §D.9.

## A.6 The deadline — and a contradiction you must resolve in thirty seconds

Two archived sources disagree, and neither is wrong on its own terms:

| Source | Says |
|---|---|
| `archive/2026-08-26/docs/research/HACKATHON_CONTEXT.md` §3, from the organizers' own PDFs | **2026-09-03, 11:59pm PST.** The research pass looked hard and found **no evidence of an extension** — but explicitly could not read Atrium's X account or Discord. |
| `archive/2026-08-26/CLAUDE.md` §3 | **~2026-11-03. LOCKED, owner-confirmed 2026-08-26.** Marked "do not re-litigate." |

**Resolution: the owner-confirmed date governs, and this plan is phased so it does not matter.** The
authoritative check takes thirty seconds and you should do it once, at the start: **Atrium emails the
Progress Update forms to whoever holds the Project ID (`HK-UHI10-####`). That inbox is the truth.**
Ask the owner to check it. Do not spend an hour on web archaeology; a prior session already did and
came back with a blind spot rather than an answer.

Regardless of which date is real, **the phase order below produces a submittable project at the end
of Phase 3** (working hook, real tests, README, video-able demo). Phases 4–7 strengthen it. If the
deadline turns out to be near, you ship after Phase 3 and say plainly what is unbuilt. If it is far,
you build the whole thing. **Never reorder the phases to chase a date** — the ordering exists because
each phase validates an assumption the next one stands on.

## A.7 Repo layout

The repository was deliberately cleared on 2026-08-26. `src/` and `test/` **do not exist yet**; you
create them. This is what you start with and what you will build:

```
UHI10/
├── AGENTS.md              how to work here. CLAUDE.md is a symlink to it.
├── CLAUDE.md              -> AGENTS.md
├── PLAN.md                THIS FILE. What to build, phased, with acceptance criteria.
├── BUSINESS.md            why it exists, who uses it, what to say. (may not exist yet)
├── PROGRESS.md            the project's memory. UPDATE IT EVERY SESSION.
├── README.md              ships with the submission. Written in Phase 7. (does not exist yet)
├── foundry.toml           solc 0.8.30, evm cancun, ffi=true, src="src", out="out"
├── remappings.txt         see A.8
├── foundry.lock           pinned submodule revisions — do NOT bump without a reason
├── lib/                   git submodules: forge-std, uniswap-hooks (which vendors v4-core,
│                          v4-periphery, solmate, permit2, openzeppelin-contracts), hookmate
├── out/                   forge build output (gitignored)
├── cache/                 forge cache (gitignored)
│
├── src/                   ** YOU CREATE THIS **
│   └── queue/
│       ├── QueueHook.sol           the hook. Phases 1–4.
│       ├── QueueSeats.sol          ERC-6909 seat/rank token. Phase 3.
│       ├── QueueHarberger.sol      rent + buyout. Phase 4. (may fold into QueueHook)
│       └── libraries/
│           └── Allocation.sol      the allocation arithmetic, isolated and unit-testable
│
├── test/                  ** YOU CREATE THIS **
│   ├── utils/
│   │   ├── BaseTest.sol            COPY from archive (A.9)
│   │   └── Deployers.sol           COPY from archive (A.9)
│   ├── spike/
│   │   └── QueueAllocator.t.sol    COPY from archive. The reference implementation. Phase 0.
│   └── queue/
│       ├── Allocator.t.sol         Phase 1
│       ├── Controls.t.sol          negative controls, every phase
│       ├── Deposit.t.sol           Phase 2
│       ├── Rank.t.sol              Phase 3
│       ├── Harberger.t.sol         Phase 4
│       ├── Gas.t.sol               Phase 5
│       ├── Adversarial.t.sol       Phase 6
│       ├── Invariant.t.sol         Phase 6
│       └── handlers/QueueHandler.sol  Phase 6
│
├── script/                ** YOU CREATE THIS ** Phase 7. Templates in archive (A.9).
│
└── archive/2026-08-26/    ALL prior research, source and spikes. Read-only history. See §I.
```

## A.8 Toolchain

**Foundry.** Verified working on this machine on 2026-08-26:

```
forge Version: 1.5.0-stable
Commit SHA: 1c57854462289b2e71ee7654cd6666217ed86ffd
```

If `forge` is not on your `PATH`, it is at `~/.foundry/bin/forge`. `foundry.toml`:

```toml
[profile.default]
bytecode_hash = "none"
evm_version   = "cancun"
ffi           = true
fs_permissions = [{access = "read-write", path = ".forge-snapshots/"}]
libs          = ["lib"]
out           = "out"
solc_version  = "0.8.30"
src           = "src"
via_ir        = false
```

Remappings (`remappings.txt`) — **note that v4-core and v4-periphery are vendored inside
`lib/uniswap-hooks`, not top-level**:

```
forge-std/=lib/forge-std/src/
@uniswap/v4-core/=lib/uniswap-hooks/lib/v4-core/
@uniswap/v4-periphery/=lib/uniswap-hooks/lib/v4-periphery/
v4-core/=lib/uniswap-hooks/lib/v4-core/
v4-periphery/=lib/uniswap-hooks/lib/v4-periphery/
@openzeppelin/uniswap-hooks/=lib/uniswap-hooks/
@openzeppelin/contracts/=lib/uniswap-hooks/lib/v4-core/lib/openzeppelin-contracts/contracts/
hookmate/=lib/hookmate/src/
permit2/=lib/uniswap-hooks/lib/v4-periphery/lib/permit2/
solmate/=lib/uniswap-hooks/lib/v4-core/lib/solmate/
```

Build and test:

```bash
forge build
forge test                                        # everything
forge test --match-path "test/queue/*" -vv
forge test --match-test test_Q1_allocationIsExact -vvv
forge test --gas-report
forge fmt                                         # run before committing
forge lint                                        # lint_on_build is off; run it manually
```

If the submodules are missing (`lib/` empty or partial):

```bash
git submodule update --init --recursive
```

Do **not** bump `foundry.lock` revisions. The spike results in this plan were produced against those
exact revisions, and a bump silently invalidates every number here.

## A.9 Files you must copy out of the archive before you can do anything

These are not optional; nothing compiles without the first two.

```bash
mkdir -p test/utils test/spike src/queue
cp archive/2026-08-26/test/utils/BaseTest.sol   test/utils/
cp archive/2026-08-26/test/utils/Deployers.sol  test/utils/
cp archive/2026-08-26/test/spike/QueueAllocator.t.sol test/spike/
```

- **`Deployers.sol`** deploys Permit2, a real `PoolManager`, a real `PositionManager` and a real
  `V4SwapRouter` locally (chainid 31337) via `hookmate` artifacts, or resolves canonical addresses on
  a fork. It also provides `deployToken()` / `deployCurrencyPair()` with correct token ordering and
  Permit2 approvals.
- **`BaseTest.sol`** wraps it with `vm.label` calls and the `_etch` override.
- **`QueueAllocator.t.sol`** is the **reference implementation of the allocator** and the thing Phase
  0 reproduces. Read it before you write anything.

Optional, for Phase 7:

```bash
cp -r archive/2026-08-26/script/base archive/2026-08-26/script/testing script/
```

---
---

# B. THE MECHANISM, SPECIFIED PRECISELY

Everything in this section that is marked **PROVEN** was executed. Everything marked **DESIGN** is
specified here for the first time and is your job to build and verify. Everything marked
**UNPROVEN** is a hypothesis — treat it as a risk, not a property.

## B.1 The shape, in one diagram

```
                     ┌──────────────────────────────────────────────┐
   trader ──swap──▶  │            Uniswap v4 PoolManager            │
   (via any router)  │  one pool, one full-range position, owner =  │
                     │  the hook. Nobody else may add liquidity.    │
                     └───────────────┬──────────────────────────────┘
                                     │ afterSwap(sender, key, params,
                                     │           BalanceDelta, hookData)
                                     ▼
                     ┌──────────────────────────────────────────────┐
                     │                 QueueHook                    │
                     │                                              │
                     │  seats:  [0]      [1]      [2]      [3]      │
                     │          a0,a1    a0,a1    a0,a1    a0,a1    │
                     │           ▲                                  │
                     │           └── the fill starts HERE, always   │
                     │                                              │
                     │  seat i's rank == its index. Index is the    │
                     │  product. ERC-6909 id ↔ seat (Phase 3).      │
                     └──────────────────────────────────────────────┘
                                     ▲
                          deposit / withdraw / buy a seat
                                     │
                          LPs, inside the hook's OWN unlock()
```

**The structural fact that makes this possible** (`archive/2026-08-26/CLAUDE.md` §5.16, §5.18,
proven by execution): *a v4 hook can address its LPs. It can never address its traders.* `sender` in
every swap callback is the **router**, not the trader; `hookData` is caller-supplied and empty
through every standard router; the hook never sees the recipient. QUEUE never needs to. Every party
it transacts with is a depositor inside the hook's own `unlock()`, and it knows exactly who they are.

## B.2 Permissions and flags

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
    p.beforeAddLiquidity = true;   // refuse every external LP
    p.beforeSwap         = true;   // open the protocol-fee measurement window (§E.5)
    p.afterSwap          = true;   // allocate the fill
}
```

> **CHANGED 2026-08-27.** `beforeSwap` was added when the protocol-fee fix was built. It snapshots
> `protocolFeesAccrued(inputCurrency)` into TRANSIENT storage and returns a ZERO delta; it changes
> nothing about the swap. Without it the fee can only be measured across transactions against a
> counter that is **global per currency**, which is the defect that killed the previous design
> (§E.5). `BEFORE_SWAP_RETURNS_DELTA` stays OFF.

Flag bits (from `@uniswap/v4-core/src/libraries/Hooks.sol`, verified):

| Flag | Value | Used? |
|---|---|---|
| `BEFORE_ADD_LIQUIDITY_FLAG` | `1 << 11` = `0x800` | **yes** |
| `BEFORE_SWAP_FLAG` | `1 << 7` = `0x80` | **yes** (added 2026-08-27, §E.5) |
| `AFTER_SWAP_FLAG` | `1 << 6` = `0x40` | **yes** |
| `AFTER_SWAP_RETURNS_DELTA_FLAG` | `1 << 2` | **no** — `afterSwap` returns `0` |
| everything else | | no |

⇒ **the hook address must have its low 14 bits equal to `0x08C0`** (`0x800 | 0x80 | 0x40`). `PoolManager` enforces this;
`Hooks.validateHookPermissions` reverts on a mismatch, so a wrong address is a loud failure, not a
silent one.

**Do not enable `AFTER_SWAP_RETURNS_DELTA`.** QUEUE takes nothing from the swap. Enabling it invites
a whole class of settlement bugs (see `archive/2026-08-26/CLAUDE.md` §5.4) for zero benefit.

**Do not enable `beforeRemoveLiquidity`.** It is unnecessary: `PoolManager` keys positions by
`(owner = the unlock's msg.sender, tickLower, tickUpper, salt)`, and since nobody but the hook can
*add*, nobody but the hook has anything to *remove*. Adding a permission you do not need widens the
attack surface and changes the required address.

**Address mining.** Two options:
- **In tests:** the spike's trick, which is cheap and deterministic —
  `address(FLAGS ^ (nonce << 144))` gives a distinct address with correct low bits for each `nonce`,
  used with `vm.deployCodeTo`. Copy it.
- **For deployment:** `HookMiner` at
  `lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol`, with CREATE2 via the canonical
  deterministic deployer. Phase 7.

## B.3 State

### Phase 1–2 (the proven shape — start here, do not optimise)

```solidity
struct Entry {
    uint256 a0;   // token0 this seat holds
    uint256 a1;   // token1 this seat holds
}

Entry[]  internal q;        // index == rank. q[0] is the head. THE ORDER IS THE PRODUCT.
PoolKey  internal key;      // the one pool this hook serves
int24    internal tickLower;
int24    internal tickUpper;
uint128  internal liquidity; // the hook's single position
```

**Use `uint256` in Phase 1, exactly as the reference spike does.** Packing `a0`/`a1` into two
`uint128`s in one storage slot is a real gas win and is the right end state — but it is a Phase 5
optimisation with its own overflow risk, and it must be introduced against a **differential test
versus the `uint256` version** (§C.6). Do not do it early. Fidelity to the proven reference beats a
clever start.

### Phase 2 additions (ownership + cursors)

```solidity
mapping(uint256 seatId => address owner) internal seatOwner;   // superseded by ERC-6909 in Phase 3
mapping(address => uint256) internal pendingWithdraw0;         // capital evacuated by a rank transfer
mapping(address => uint256) internal pendingWithdraw1;

uint256 internal cursor0;   // see B.6 — every seat below this holds a0 == 0
uint256 internal cursor1;   // every seat below this holds a1 == 0
```

### Phase 3 additions (the rank token)

Inherit `ERC6909` from `@uniswap/v4-core/src/ERC6909.sol` (a vendored, audited Solmate derivative,
already in-tree and compiling under this solc). **One ERC-6909 id per seat, total supply exactly 1.**
The id is a stable `seatId`; the *rank* is the seat's index in `q`. Holding the token is what makes
you the seat's controller.

```solidity
uint256 internal constant MAX_SEATS = 32;   // see B.9 — bounded ON PURPOSE
mapping(uint256 seatId => uint256 index) internal seatIndex;   // seatId -> position in q
uint256[] internal indexSeat;                                  // position in q -> seatId
```

### Phase 4 additions (Harberger)

```solidity
struct Lease {
    uint128 selfPrice;   // denominated in currency0. The holder's own number.
    uint64  lastSettled; // block.timestamp of the last rent settlement
}
mapping(uint256 seatId => Lease) internal lease;
uint256 internal unallocatedRent0;   // rent with no eligible recipient (see B.8)
```

## B.4 Callbacks

### `beforeAddLiquidity` — the hook is the sole LP

```solidity
function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    internal view override returns (bytes4)
{
    require(sender == address(this), "QUEUE: hook is sole LP");
    return BaseHook.beforeAddLiquidity.selector;
}
```

`sender` here is the caller of `PoolManager.modifyLiquidity`, i.e. **the unlocker**. Because the hook
adds liquidity from inside its own `poolManager.unlock()`, `sender == address(this)` holds. **PROVEN
by execution** — the spike's `seed()` passes this check.

This single line is what makes the hook's ledger the pool's ledger. Without it, an outside LP dilutes
every fill and the allocator's arithmetic is meaningless. **It is the most load-bearing `require` in
the contract.** It gets its own negative control (§D.3).

### `afterSwap` — the allocator

```solidity
function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta d, bytes calldata)
    internal override returns (bytes4, int128)
{
    _allocate(d);
    return (BaseHook.afterSwap.selector, 0);   // NOT a return delta. Take nothing.
}
```

## B.5 The allocation arithmetic — **specified exactly**

This is the core. Get it wrong and it is not a degraded feature, it is lost funds.

### Step 1 — turn the swapper's delta into the queue's entitlement

`afterSwap` receives `BalanceDelta d`, which is **the swapper's** delta as `PoolManager` computed it:
negative = the swapper owes the pool that token, positive = the pool owes the swapper. The sole LP's
entitlement is exactly its **negation**:

```solidity
int256 e0 = -int256(d.amount0());
int256 e1 = -int256(d.amount1());
if (e0 == 0 && e1 == 0) return;   // nothing happened
```

`e > 0` means the pool gained that token and the queue is owed it. `e < 0` means the pool paid that
token out and the queue must give it up.

**Nothing here is the hook's opinion.** The numbers come from `PoolManager`. There is no mark, no
oracle, and no quantity the hook chooses — which is why there is nothing for an attacker to push
(§E.11).

### Step 2 — name the direction

```solidity
bool    outIsOne = (e1 < 0);                                  // token1 is what the pool paid out
uint256 amtOut   = outIsOne ? uint256(-e1) : uint256(-e0);    // what the queue must GIVE UP
uint256 amtIn    = outIsOne ? uint256( e0) : uint256( e1);    // what the queue RECEIVES, fee included
```

`amtIn` is **fee-inclusive**: the swapper paid input plus the LP fee, and all of it is owed to the
sole LP. That is correct and it is why the queue's fee accrual needs no separate accounting — **but
it is exactly true only when the protocol fee is zero.** See §E.5; this is a real, **MEASURED** hazard
and Phase 1 must test it.

The ratio `amtIn / amtOut` **is the swap's realised average price.** It is the only price in the
entire mechanism.

### Step 3 — allocate front-first

```
remaining   := amtOut          // still to be taken out of the queue
assignedIn  := 0               // incoming token already assigned

for i from cursor(outgoing token) upward, while remaining > 0:
    bal := (outIsOne ? q[i].a1 : q[i].a0)
    if bal == 0: continue
    take := min(bal, remaining)
    remaining -= take

    if remaining == 0:                       // THIS IS THE LAST FILLED SEAT
        give := amtIn - assignedIn           // <<<< THE REMAINDER LINE. See below.
    else:
        give := FullMath.mulDiv(amtIn, take, amtOut)     // floored

    assignedIn += give
    apply(i, take, give)                     // seat loses `take` of out-token, gains `give` of in-token

if remaining != 0: revert QueueUnderflow(remaining)
```

`apply`:
```solidity
if (outIsOne) { q[i].a1 -= take; q[i].a0 += give; }
else          { q[i].a0 -= take; q[i].a1 += give; }
```

### Step 4 — **the remainder line, and why it is the whole thing**

> Each seat's incoming share is `FullMath.mulDiv(amtIn, take, amtOut)`, **floored** — **except the
> last filled seat, which is assigned `amtIn − assignedSoFar`.**

Every floored share loses up to one wei. Summed over `k` filled seats, the queue would be short by up
to `k−1` wei of the incoming token on **every swap**, forever, and the shortfall compounds. The
remainder line hands the entire un-assigned balance to the last seat filled, so the assigned amounts
sum to `amtIn` **exactly, by construction, not by luck**.

**This is proven from both sides.** The negative control that deletes the remainder line
(`FLOOR_ONLY`) goes red — and **it survives swap 1 and only dies at swap 2**, because a single-seat
fill has no remainder to drop. That asymmetry is the sharpest result in the spike: it is what
distinguishes "the test is checking the remainder" from "the test happens to pass."

> **Read that again if you are about to refactor the allocator. A refactor that survives your
> one-seat test proves nothing. The remainder line is only observable on a multi-seat fill.**

Reproduced 2026-08-26:
```
[PASS] test_negativeControl_flooredSharesGoesRed()
Logs:
   control reverted with: swap2: token0 conservation
```

### Step 5 — what is PROVEN about this

Executed today, `test/spike/QueueAllocator.t.sol`, real `PoolManager`, real `V4SwapRouter`, hook at a
mined permission address, pool at **`SQRT_PRICE_1_4` — never 1:1**, one full-range hook-owned
position, three seats at 4% / 6% / 90%, across four swaps (head-only fill; sweep exhausting two seats
and partially filling a third; mid-seat partial; and a **reverse-direction** leg):

```
queue total token0            2248553145997694428660
PoolManager-measured token0   2248553145997694428660      <- equal, to the wei
queue total token1             445000573750774563494
PoolManager-measured token1    445000573750774563494      <- equal, to the wei
```

**Front-first allocation at the swap's realised average price conserves both tokens exactly, to the
wei, at a non-unit price.** Measured on **PoolManager's own ERC20 balances**, never on the hook's
bookkeeping.

## B.6 Cursors — **DESIGN, and the spike does not have this**

The reference spike scans from index 0 on every swap and `continue`s past exhausted seats. That is
correct but it is **O(all seats ever exhausted)** forever: a seat drained early still costs a loop
iteration and an `SLOAD` on every future swap. You must add cursors, and the design has a subtlety
that will bite you if you copy the naive one-cursor idea from the design document.

**The subtlety: there is no single cursor, because flow is bidirectional.** A seat exhausted in
token1 still holds token0 and must be filled on the reverse leg. So maintain **two** cursors with
this invariant:

> **INVARIANT C:** for each token `X ∈ {0,1}`, every seat at index `< cursorX` holds `aX == 0`.

Note what the invariant does *not* say: it does not say `q[cursorX].aX > 0`. The cursor is allowed to
lag (point at a seat that is itself empty); the loop's `continue` handles that. It must **never**
lead, because leading skips a seat that should have been filled — which is silent theft of rank, the
exact defect the `OFF_BY_ONE` negative control catches.

Maintenance, O(1) per swap:

```
// when token X is the OUTGOING token, and the fill started at index `start`:
cursorX = index of the first seat the loop did not fully exhaust     // monotone advance
cursorY = min(cursorY, start)                                        // the fill CREDITED token Y
                                                                     //   to seats from `start` upward
```

The second line is the one people forget. A reverse-direction fill credits token Y to seats starting
at `start`; if `start < cursorY`, `cursorY` is now leading and the next Y-outgoing swap will skip a
funded seat. **This gets its own negative control** (§D.5): delete the `min`, run an
out-then-back-then-out sequence, assert red with a specific reason.

Deposits append at the tail and change no cursor. Withdrawals zero a seat's balances and may only
*advance* a cursor. Seat reordering (Phase 4 foreclosure) must recompute both cursors conservatively
— **when in doubt, set a cursor to 0.** A lagging cursor costs gas; a leading cursor loses money.

## B.7 Deposit and withdraw — **DESIGN**

Both run inside the hook's **own** `poolManager.unlock()`, so `PoolManager` keys the position by the
hook and the depositor's identity is `msg.sender` on the hook's external function — knowable, unlike
a trader's.

```
deposit(seatId, amount0, amount1):
  require(msg.sender controls seatId)
  pull amount0/amount1 from msg.sender via transferFrom
  unlock():
     compute liquidityDelta for (amount0, amount1) at the current price over [tickLower, tickUpper]
     modifyLiquidity(+liquidityDelta)
     settle both currencies
  credit the ACTUAL amounts consumed to q[seatIndex[seatId]]
  refund any unconsumed remainder to msg.sender
```

> **Credit what was actually consumed, never what was requested.** `modifyLiquidity` returns a
> `BalanceDelta`; the amounts it took are that delta, not your inputs. Crediting the requested amount
> is a direct route to an over-credited ledger and an insolvent hook.

```
withdraw(seatId, amount0, amount1):
  require(msg.sender controls seatId)
  require(amounts <= q[i].a0 / q[i].a1)
  unlock():
     compute liquidityDelta to release those amounts
     modifyLiquidity(-liquidityDelta)
     take() both currencies to the hook
  debit q[i], transfer to msg.sender
  advance cursors if the seat is now empty in either token
```

**Withdrawing to zero does NOT destroy the seat.** An empty seat is pure rank with no capital
attached, and being able to hold, price and sell one is what gives rank a price of its own. This is a
deliberate design decision; record it as such.

### The redemption-dust problem — **MEASURED, and it must be fixed here**

The queue's face value is **not** what the position redeems for. It redeems for slightly *less*, and
the gap **grows with swap count**. Reproduced 2026-08-26:

| | token0 | token1 |
|---|---:|---:|
| seed → redeem, **0 swaps** | −1 | −1 |
| 2 swaps | −2 | −3 |
| 4 swaps | −3 | −4 |
| 40 swaps | −9 | −11 |
| **200 swaps** | **−52** | **−54** |

≈ **0.26 wei per swap.**

**The cause is NOT fee-growth truncation.** That was the second hypothesis and a zero-fee pool
falsifies it:

```
200 swaps @ 0.30% fee   token0 −52   token1 −54
200 swaps @ 0    fee    token0 −46   token1 −50     <- 88% of the drift survives with NO fee
```

**The real cause: v4 computes a swap's amounts and a position's redeemable value with two different
formulas, each rounded in the pool's favour.** The queue's ledger is built from the first; redemption
is settled by the second. They agree to ~0.26 wei per swap and no better. Fees are ~11% of it.

**Is it farmable? No, and not close.** The drift accrues to *nobody* — it stays in `PoolManager` as
unclaimable dust; the attacker gains zero. It is a pure grief costing ≥100k gas plus a swap fee per
**0.26 wei** of damage. Inflicting one whole token of shortfall needs ~4·10¹⁸ swaps. Cost-to-damage
is off by roughly **twenty orders of magnitude**.

**But it is a real correctness item, and a naive `withdraw()` paying face value leaves the last
withdrawer short.** Two acceptable fixes — pick one, record which, in `PROGRESS.md`:

- **(F1) Settle against actual holdings.** `withdraw` computes what `modifyLiquidity(-Δ)` actually
  returned and pays *that*, debiting the seat by the same. Face value becomes an upper bound, and the
  dust is spread across whoever withdraws rather than dumped on the last one. **Recommended** —
  simplest, no new state, and it is honest about where the number comes from.
- **(F2) Carry a dust buffer.** Hold a small hook-owned reserve that absorbs the residual and is
  topped up from... nothing, which is the problem. Only viable with a fee cut, which QUEUE does not
  take. **Not recommended.**

**Until the fix is built and proven, the claim "the queue's face value is redeemable" must not be
made** — not in the README, not in the video, not in a comment.

> ⚠️ **AND the dust fix is not the only blocker on that claim.** Research after this section was
> written MEASURED that **the withdraw spec above is impossible as specified**: a position releases
> tokens in a ratio fixed by price and range, and front-first allocation deliberately drives seats to
> single-token composition — after the spike's own 4-swap scenario seat 1 holds 258.877 token0 / 0
> token1 and can withdraw **nothing** via `modifyLiquidity(−Δ)`; seats 0 and 2 leave their token1 legs
> unreachable. This is the steady state, not an edge case, and the swap-to-rebalance "fix" is a trap
> (a hook-initiated swap skips the hook's own `afterSwap`). **Phase 2 BLOCKER — §B.7 is not yet
> corrected.** Evidence: `docs/research/protocol-fee/queue-exposure.md` §A2 (`WithdrawalPathProbe.t.sol`);
> ledger rows `PITFALLS.md` §5.5, §5.6, §5.7.

## B.8 The ERC-6909 rank token — **DESIGN**

### The object

**One ERC-6909 id per seat, supply exactly 1.** Not a fungible per-pool balance. Rank is an
*ordering*, and an ordering is not divisible; a fungible rank token would have to mean something like
"priority points," which requires a sorted structure and re-opens problems this design closes.

### Rank moves; capital does not

> **On any transfer of a seat token, the seat's `(a0, a1)` are evacuated to the sender's
> `pendingWithdraw` balances, and the seat arrives at the recipient empty.**

This is the single most important rule in Phase 3 and it is what makes Phase 4 sound. Reasons:

1. It is what the design actually specifies: *"Rank transfers move the position in the queue, not the
   capital."*
2. It removes an entire class of theft. If capital travelled with the seat, then a Harberger buyout
   at a self-assessed price denominated in **one** token would let a buyer seize a **two**-token
   basket — and correctly pricing that basket requires a price, which the mechanism is not allowed to
   have (§E.11). Evacuating capital means the buyout price covers **rank only**, and no price is ever
   read.

**FOOTGUN:** the inherited `ERC6909.transfer` / `transferFrom` are `virtual` and do nothing but move
balances. **You must override both** to call `_evacuate(id, from)` first. Forgetting to override one
of the two is the classic form of this bug — `transfer` is guarded, `transferFrom` is not. There is a
mandatory negative control for exactly this in §D.6.

### Where seats come from — **rank must be BOUGHT or HARBERGER-HELD, NEVER GRANTED**

This is a hard rule, and it is the fix to a free lane:

> **Grief the front by dusting.** If rank is granted by deposit order, occupying the head costs a dust
> deposit. If rank is granted first-come, occupying the head costs being early. **Both are free.** A
> seat that is free to occupy has no price, and QUEUE without a price for the seat is not QUEUE.

Therefore:

- `MAX_SEATS` seats exist from deployment, as a **fixed, bounded roster** (see B.9).
- Phase 3 may allocate the initial roster by any explicit mechanism — a one-time sale, an initial
  auction, or direct assignment by the deployer for the demo — **but it must be recorded as an
  explicit allocation event, never as a side effect of depositing.**
- **Phase 2's append-at-tail seat creation is PROVISIONAL AND NOT SHIPPABLE.** It exists only so
  deposit/withdraw can be tested before the rank layer lands. Phase 3 replaces it. Write a test
  named `test_knownHole_phase2SeatsAreGrantedByArrivalOrder` that documents the hole so nobody can
  forget it, and delete the test when Phase 3 closes it.

### Secondary market — a correction to the design document

`IDEAS_OBJECTS.md` §1.4 offers *"let the rank token trade in its own Uniswap pool — elegant, zero
extra code."* **Under the one-id-per-seat design, that is not true and you should not repeat it.** A
v4 pool needs an ERC-20 on each side; a supply-1 ERC-6909 id is not poolable without a wrapper, and
the wrapper is not zero code. Two honest options:

- **Recommended: skip the secondary pool. Use Harberger (Phase 4) for price discovery.** It needs no
  bidders to show up, it produces a continuous on-chain price for the seat, and it closes the
  rank-then-run hole (§E.13) that the plain token leaves open. It is strictly the better demo.
- If a secondary market is wanted anyway, it is an ERC-20 wrapper per seat plus a pool per seat —
  scope it explicitly, do not hand-wave it.

## B.9 The roster is bounded, on purpose

Gas, measured with `vm.cool()` and reproduced 2026-08-26:

| seats | head-only swap | sweeping swap | seats touched by the sweep |
|---:|---:|---:|---:|
| 1 | 31,864 | 11,964 | 1 |
| 2 | 31,874 | 18,717 | 2 |
| 5 | 31,874 | 38,976 | 5 |
| 10 | 31,874 | 65,998 | 9 |
| 25 | 31,874 | 160,540 | 23 |
| 50 | 31,874 | **309,106** | 45 |

Two readings, both important:

- **The common case is flat and cheap: ~31,874 gas, independent of queue depth.** A swap that lands
  inside the head seat — which is most swaps — never walks the queue.
- **A sweeping swap is O(seats touched) at ~6,753 gas each** (slope over 1→45 seats, intercept
  ~5,200).

Maximum shippable depth, on that slope:

| hook-callback gas budget | max seats |
|---|---:|
| 300k | ~44 |
| 500k | ~73 |
| 1M | ~147 |

⇒ **QUEUE is not an open retail LP pool with thousands of positions. A full sweep of such a book
cannot be paid for.** It is a **bounded roster of professional seats, roughly 20–100 deep.**

**Pitch that as the design, from the first sentence, because it is one.** Scarce seats are what make
a seat *priced*, and a priced seat is the entire mechanism. An unbounded roster would make rank
free, which is the dusting free lane again. But be honest that it also **caps Impact** — this is a
professional market-making venue, not a replacement for every Uniswap pool.

Recommended default: **`MAX_SEATS = 32`.** Round, comfortably inside a 300k budget with headroom for
the deposit/withdraw path, and large enough that the queue is interesting. Record the choice.

## B.10 The Harberger variant — **DESIGN, Phase 4**

Plain transferable rank has one hole this project could not close (§E.13): **rank-then-run.** Buy the
front cheaply during a quiet stretch, then dump the rank token before a scheduled event. You eat the
price gap *only if there is a bid* — in a thin secondary market the front seat is abandonable at the
exact moment it matters.

**Harberger closes it.** You cannot leave your slot; you can only lower your self-assessment and pay
rent, and someone buys you out at your own number.

Specification:

| Element | Rule |
|---|---|
| **Self-assessment** | Each seat carries `selfPrice`, set freely by its holder, denominated in **`currency0`** — one of the pool's own tokens. No oracle, no external asset, no price read. |
| **Rent** | `rentOwed = τ · selfPrice · (block.timestamp − lastSettled) / RENT_PERIOD`. Use **timestamps**, not block numbers — block times differ by chain and a block-denominated rate silently changes meaning on deploy. Record τ and `RENT_PERIOD` as immutables. |
| **Who is paid** | The seats **behind** you, pro-rata **by their `currency0` balance**. Same-token pro-rata only — mixing `a0` and `a1` into one "value" requires a price and is forbidden. |
| **No eligible recipient** | If every seat behind holds `a0 == 0`, the rent accrues to `unallocatedRent0` and is distributed at the next settlement that has a recipient. Do **not** use `poolManager.donate()` (§E.6). |
| **Payment source** | Deducted from the seat's own `a0`. |
| **Foreclosure** | If `a0` cannot cover accrued rent: settle what it can, zero `selfPrice`, and **move the seat to the tail**. Then recompute cursors conservatively. This is the whole enforcement mechanism. |
| **Buyout** | Anyone may pay `selfPrice` in `currency0` to the holder at any time. Outstanding rent settles first. **The seat transfers empty** — the seller's `(a0, a1)` go to their `pendingWithdraw` (B.8). The buyer sets a new `selfPrice` and deposits. |

**What Harberger is NOT:** it is not a margin engine and must never become one. There is no
collateral, no liquidation crank, no oracle, and no mark. Foreclosure is a demotion, not a seizure.
A prior candidate in this repo (`TENANT`) died specifically because it needed collateral and
liquidations, and the assessment was blunt: *"the kind of build that produces a green suite and a
drained contract."* Do not walk into it here.

**Rent parameter τ is a load-bearing parameter, and this project's history says a load-bearing
parameter is where a pitch dies.** Mitigation: do not defend a specific τ. Show the mechanism at
several values, show that the *sign* of the seat's price is the finding (a positive price means
benign flow; a negative one — i.e. the front must be paid — means toxic flow), and say plainly that τ
is a governance choice with a trade-off, not a discovered constant.

## B.11 The O(1) prefix-sum redesign — **UNPROVEN. Do not quote it as a property.**

The named, unbuilt follow-up: store the queue as a **prefix-sum with a global cumulative-fill
accumulator plus a price-growth accumulator indexed by cumulative fill** — the `feeGrowthOutside`
trick v3 already uses for tick crossing, applied to a fill queue instead of a tick ladder. A sweep
would update **one scalar** and seats would settle lazily on withdrawal. Bidirectional flow needs the
same outside-flip v3 uses.

**The specific reason to distrust it, which is not in the source document:** the thing that makes the
O(N) allocator exact is **the remainder line** (§B.5 step 4) — a per-swap correction applied to the
*last seat filled*. A lazy accumulator has no notion of "the last seat filled" at the time the scalar
is updated, so the remainder has no obvious lazy analogue. **The redesign may not be exactly
conservative.**

⇒ **Phase 5's exit criterion is a differential test against the O(N) reference showing wei-exact
agreement over a randomised swap sequence, or an explicitly measured and bounded divergence that is
proven non-farmable.** If neither can be produced, **do not ship it.** Keep the O(N) allocator and
the bounded roster — that is a complete, correct product, and shipping a subtly non-conservative
optimisation to save gas on a 32-seat book would be trading the only thing QUEUE has going for it for
nothing.

## B.12 Why QUEUE survives the constraints that killed everything else

This repo has a table of four **proven** evasions. Every mechanism it generated died to one of them.
Check any change you make against this table first.

| Evasion | Measured cost | Does it touch QUEUE? |
|---|---|---|
| **Splitting a quantity** into k parts | ~gas, fractions of a cent | **No input is a magnitude.** Rank is an ordering, not a threshold. Splitting a swap routes all k slices to the head — which is the seat the market has already priced for exactly that. |
| **Address shopping inside one unlock** | **52,700 gas** | **No identity, reputation or history input.** Splitting capital across ten addresses buys ten seats and evades nothing. |
| **Waiting one block boundary** | **200 ms** on Unichain | **No per-block reference, no epoch, no reset.** The queue is continuous state. |
| **The router opacity wall** | free — structural | **QUEUE never sees, gates, or pays the trader.** Every counterparty is a depositor inside the hook's own unlock. |

**The reason it passes, stated once: QUEUE charges nobody.** It creates no new payment, invents no
new signal, and asks no question an adversary could answer falsely. It changes only *the order in
which existing LPs are filled by existing swaps at the existing price* — and then sells that order.
There is nothing to forge because there is no assertion being made.

**Keep it that way.** If a change you are considering introduces a threshold, a size input, an
identity input, a per-block reference, or anything that must see the trader — it re-opens one of
these four, and it is almost certainly the wrong change.

---
---

# C. PHASED BUILD PLAN

Eight phases. **Each has entry criteria, exit criteria, and a verification gate.**

**Exit criteria are stated as things that must be TRUE, not things that must be DONE.** "Wrote the
allocator" is not an exit criterion. "Conservation holds to the wei against PoolManager's balances
across a four-swap scenario at 1:4, and three mutations of the allocator go red for their specific
reasons" is.

**Do not start phase N+1 until phase N's gate is green AND its negative controls are red.** A gate
without red controls is not a gate.

**If the owner adds team members**, the natural split is: one person on the allocator/state core
(Phases 1, 2, 5), one on the token/economics layer (Phases 3, 4), one on verification (Phase 6, which
should start *shadowing* from Phase 1 rather than waiting), one on demo/pitch/README (Phase 7, which
should start collecting material from Phase 1). **Verification must not be owned by whoever wrote the
code under test** — see §D.1.

## Phase overview

```
 0  Harness + reproduce the reference spike        ── proves the ground is solid
 1  Allocator core                                 ── proves the arithmetic, in OUR code
 2  Deposit / withdraw + redemption-dust fix       ── proves the hook is solvent
 3  ERC-6909 rank + transfer                       ── proves the OBJECT exists    ◀ SUBMITTABLE HERE
 4  Harberger rent variant                         ── closes rank-then-run, gives rank a price
 5  Gas + scale (packing, then maybe O(1))         ── proves the roster bound, honestly
 6  Adversarial + invariant campaign               ── tries to break all of it
 7  Testnet deploy + demo + video                  ── ships it
```

---

## C.0 PHASE 0 — Harness and reference-spike reproduction

**Purpose:** prove the ground is solid before building on it. This is the PDCA rule applied to the
environment itself. It also gives you a working, executed example of every v4 idiom you are about to
use.

**Entry criteria**
- `forge --version` reports `1.5.0-stable` (or the version in `foundry.lock`'s era). Record what you
  actually get.
- `lib/` submodules present (`git submodule update --init --recursive` if not).

**Do**
1. Copy the three files from §A.9.
2. `forge build`.
3. `forge test --match-path "test/spike/QueueAllocator.t.sol" -vv`.
4. **Read `QueueAllocator.t.sol` end to end.** It is ~585 lines and it is the reference
   implementation. In particular read `_allocate`, `_refAllocate` (a second, independently written
   allocator used as a cross-check), `_check`, and the `_expectRed` control harness.

**Exit criteria — all must be TRUE**

| # | Must be true | How you know |
|---|---|---|
| 0.1 | 9 tests pass, 0 fail | `forge test --match-path "test/spike/QueueAllocator.t.sol"` |
| 0.2 | Conservation is exact to the wei | log lines match §D.2 exactly |
| 0.3 | **All three negative controls go red, each with its exact expected reason** | §D.2 |
| 0.4 | The gas table reproduces within ±2% | §D.2 |
| 0.5 | The residual reproduces: −1/−1 at 0 swaps, −52/−54 at 200 | §D.2 |
| 0.6 | You can state, in your own words, why the FLOOR_ONLY control survives swap 1 | write it in `PROGRESS.md` |

**If any number differs from §D.2:** stop. Do not proceed and do not "adjust the expected value."
A divergence means the toolchain, the submodules, or the environment differs from the one every
number in this plan was measured on, and **every downstream assertion in this document is then
suspect.** Record the divergence in `PROGRESS.md`, state which numbers moved and by how much, and
raise it before continuing.

**Gate:** §D.2.

---

## C.1 PHASE 1 — Allocator core

**Purpose:** re-derive the proven arithmetic in production code, in `src/`, with cursors, and prove
it again — in our code, not the spike's.

**Entry criteria:** Phase 0 exit criteria all true.

**Build**
- `src/queue/libraries/Allocation.sol` — pure functions, no storage. This is where the arithmetic
  lives so it can be unit-tested and fuzzed without a pool.
- `src/queue/QueueHook.sol` — `BaseHook` + `IUnlockCallback`. Permissions per §B.2. State per §B.3
  Phase 1–2. Callbacks per §B.4. Allocator per §B.5. **Cursors per §B.6.**
- `test/queue/Allocator.t.sol`, `test/queue/Controls.t.sol`.

**Exit criteria — all must be TRUE**

| # | Must be true |
|---|---|
| 1.1 | Conservation of **both** tokens is exact to the wei against **PoolManager's own ERC20 balances** across the four-swap scenario at a **1:4** price |
| 1.2 | The same holds at **1:1000** and at **1000:1** (two more non-unit fixtures, opposite directions) |
| 1.3 | The same holds with **asymmetric decimals** (18 / 6) |
| 1.4 | Seat composition matches an **independently written** reference allocator, seat by seat |
| 1.5 | A head-only swap touches exactly **one** seat |
| 1.6 | A sweeping swap exhausts ≥2 seats and partially fills a third |
| 1.7 | A **reverse-direction** swap fills the head again (the "front seat sees every swap" claim) |
| 1.8 | **INVARIANT C** (§B.6) holds after every swap in every test |
| 1.9 | A swap larger than the whole queue reverts with `QueueUnderflow`, and does **not** silently under-fill |
| 1.10 | **Protocol fee:** with a nonzero protocol fee set on the pool the ledger stays consistent, via P2 (net out `protocolFeesAccrued`) — **owner decision 2026-08-26**. ⚠️ **Two corrections to this criterion's earlier wording:** (a) it said *"refuses to **operate**"*, which steers an implementer into `unlockCallback` and **permanent loss of funds**; any refusal must gate **allocation only** — swaps revert, withdrawals MUST still succeed. (b) The assertion must be against **`PoolManager balance − protocolFeesAccrued`** or `redeemAll()`, **and** must assert `protocolFeesAccrued > 0` first — as originally written this criterion **cannot fail**. (§E.5) |
| 1.11 | **Five** negative controls red, each with its asserted specific reason (§D.3) |
| 1.12 | A stateless fuzz of `Allocation.allocate` over random `(amtIn, amtOut, balances[])` never loses or invents a wei |

**Gate:** §D.3.

> ### ✅ PHASE 1 COMPLETE — 2026-08-27. All twelve criteria met.
>
> `src/queue/libraries/Allocation.sol` + `src/queue/QueueHook.sol`; tests in `test/queue/`.
> **36/36 green, `forge lint src/` clean, nine production mutations confirmed red.**
>
> Criterion **1.10 is solved by snapshotting `protocolFeesAccrued` across the
> `beforeSwap`->`afterSwap` window** rather than deriving the fee — see the rewritten §E.5. This
> added the `beforeSwap` permission (§B.2). Every fee test runs against a FOREIGN POOL sharing a
> currency, and all six were confirmed to go RED against the superseded mechanism.
>
> **Four defects were found in the Phase 1 code itself, none by the correctness suite** — all fixed,
> all now carrying tests (PITFALLS 5.37–5.42):
> 1. `_allocate` loaded every seat into memory, discarding the cursor design (98k->215k gas at depth
>    50, linear). All 31 correctness tests stayed green under it. Now flat, with a `vm.cool()` gas
>    regression test.
> 2. Deriving direction from the delta's SIGN bricked dust swaps (1–3 wei reverted
>    `DirectionMismatch`). Now taken from `params.zeroForOne`, with the degenerate zero-output fill
>    credited to the cursor seat rather than dropped.
> 3. `seed()` and `redeemAll()` were permissionless on the production hook. Moved to
>    `test/queue/QueueHarness.sol`; **the shipping contract now has no permissionless
>    state-changing entry point.**
> 4. Settlement ignored ERC20 return values; now uses v4's `CurrencySettler` (SafeERC20).
>
> **The sharpest testing lesson (PITFALLS 5.37):** the cursor pull-back exists once per direction.
> Deleting one copy was caught by 7 tests; deleting its mirror was caught by **zero**. When a rule
> appears twice, mutate both copies.

**Risk to watch:** the temptation to "clean up" the allocator while porting it. Every simplification
you make is a mutation you have not tested. Port it faithfully first, prove it, *then* refactor —
with the controls still red.

---

## C.2 PHASE 2 — Deposit / withdraw, and the redemption-dust fix

**Purpose:** make the hook usable by real depositors and make it **solvent** — i.e. prove that what
the ledger says a seat holds is something the hook can actually pay.

**Entry criteria:** Phase 1 exit criteria all true.

**Build**
- `deposit(seatId, amount0, amount1)` and `withdraw(seatId, amount0, amount1)` per §B.7.
- The dust fix, **F1 recommended** (§B.7).
- Seat ownership (`seatOwner` mapping — provisional, replaced in Phase 3).
- `test/queue/Deposit.t.sol`.

**Exit criteria — all must be TRUE**

| # | Must be true |
|---|---|
| 2.1 | A deposit credits **exactly what `modifyLiquidity` actually consumed**, never the requested amount; any remainder is refunded |
| 2.2 | Deposit and withdraw both work at a **non-unit** price and with **asymmetric decimals** |
| 2.3 | **Every** depositor, withdrawing in **every** order (including last), is paid in full. Test all orderings for N=3. |
| 2.4 | The **last** withdrawer is not short. This is the dust fix's whole point — it gets a dedicated test named for it. |
| 2.5 | **After 200 swaps**, total paid out ≤ what the position actually redeems for, and the gap is **≤ 1 wei per swap** |
| 2.6 | Withdrawing to zero **leaves the seat in place** (empty seat = pure rank) |
| 2.7 | Nobody can withdraw from a seat they do not control |
| 2.8 | Cursors are still correct after arbitrary deposit/withdraw interleavings (INVARIANT C) |
| 2.9 | Negative control: with the dust fix removed, a last-withdrawer test goes **red with the specific shortfall reason** |
| 2.10 | `test_knownHole_phase2SeatsAreGrantedByArrivalOrder` exists and documents the provisional seat allocation (§B.8) |

**Gate:** §D.4.

---

## C.3 PHASE 3 — ERC-6909 rank token and transfer ◀ **SUBMITTABLE STATE**

**Purpose:** make the object exist. Until this phase, QUEUE is a fill-ordering scheme. After it,
rank is a thing you can hold, transfer and price. **This is the phase that makes the pitch true.**

**Entry criteria:** Phase 2 exit criteria all true.

**Build**
- `src/queue/QueueSeats.sol` (or fold into `QueueHook`): inherit
  `@uniswap/v4-core/src/ERC6909.sol`.
- One id per seat, supply 1. `seatIndex` / `indexSeat` mappings.
- **Override `transfer` AND `transferFrom`** to evacuate capital (§B.8).
- Explicit initial roster allocation — **never by deposit order** (§B.8).
- `test/queue/Rank.t.sol`.

**Exit criteria — all must be TRUE**

| # | Must be true |
|---|---|
| 3.1 | Total supply of every seat id is exactly 1, always, under every operation |
| 3.2 | Transferring a seat moves **rank only**; the sender's capital lands in `pendingWithdraw` and is fully recoverable |
| 3.3 | **3.2 holds through `transferFrom` and through operator-approved transfers, not just `transfer`** |
| 3.4 | The new holder's fills go to the transferred seat's index, immediately, on the very next swap |
| 3.5 | A seat cannot be created by depositing, by being early, or by any path other than the explicit roster allocation |
| 3.6 | Seat count never exceeds `MAX_SEATS` |
| 3.7 | An empty seat is transferable and its rank is preserved |
| 3.8 | Negative control: an implementation that overrides only `transfer` and not `transferFrom` goes **red with a capital-escaped assertion** |
| 3.9 | Negative control: an implementation that lets a deposit mint a seat goes **red** |
| 3.10 | Every Phase 1 and Phase 2 exit criterion is **still** true (`forge test` full suite) |

**At the end of this phase the project is submittable.** If the deadline is close, stop here, write
the README and video (Phase 7), and state plainly what is unbuilt. A correct, tested,
honestly-scoped QUEUE beats a half-finished Harberger engine.

**Gate:** §D.5.

---

## C.4 PHASE 4 — Harberger rent variant

**Purpose:** close the rank-then-run hole and give rank a **continuous on-chain price** without
needing a secondary market to exist.

**Entry criteria:** Phase 3 exit criteria all true. **And: the owner has been told that τ and
`RENT_PERIOD` are governance parameters, and has agreed to the choice.** Changing who receives money
is an owner-level decision (§D.8).

**Build:** §B.10.

**Exit criteria — all must be TRUE**

| # | Must be true |
|---|---|
| 4.1 | Rent accrues linearly in elapsed time and is exact against a hand-computed value |
| 4.2 | Rent is paid to the seats **behind**, pro-rata by their `currency0` balance, summing **exactly** to the rent charged (the remainder rule of §B.5 applies here too) |
| 4.3 | With no eligible recipient, rent lands in `unallocatedRent0` and is **not** lost |
| 4.4 | A buyout at `selfPrice` transfers **rank only**; the seller's capital is fully recoverable |
| 4.5 | A holder who under-prices their seat is bought out; a holder who over-prices pays for it. Both demonstrated numerically. |
| 4.6 | Foreclosure fires exactly when `a0` cannot cover accrued rent, moves the seat to the tail, and **leaves cursors correct** |
| 4.7 | **Rank-then-run is closed:** the abandonment sequence that works against plain transferable rank is demonstrated to fail here, in a test that runs **both** variants side by side |
| 4.8 | No oracle, no external price, no collateral, no liquidation crank exists anywhere in the code (grep it and assert it in the review) |
| 4.9 | Negative control: settle-rent-without-charging goes **red**; pay-rent-to-seats-**ahead** goes **red** |
| 4.10 | Reentrancy: a malicious `currency0` that re-enters during a buyout payout cannot double-spend a seat |

**Gate:** §D.6.

---

## C.5 PHASE 5 — Gas and scale

**Purpose:** turn the roster bound from a measured accident into a stated, defended design
parameter — and *only then* consider the O(1) redesign.

**Entry criteria:** Phase 4 exit criteria all true (or Phase 3, if Harberger was deferred).

**Do, in this order. Do not skip to 5c.**

- **5a — measure honestly.** Reproduce the §B.9 table against *our* hook, **with `vm.cool()`**,
  under a `--gas-report`. Derive the actual slope and intercept. **Do not reuse the spike's numbers
  for our contract** — the spike had no cursors, no owners and no seat tokens; our gas is different
  and probably worse.
- **5b — cheap wins, each individually measured.** Pack `a0`/`a1` into one slot as `uint128` with
  `SafeCast` (a checked cast — an overflow must revert, never wrap). Hoist repeated `SLOAD`s. Tighten
  the loop. **Each change gets a before/after number and a differential test against the `uint256`
  implementation over a randomised swap sequence proving wei-identical results.**
- **5c — the O(1) prefix-sum redesign, ONLY if 5a/5b leave a real problem.** Per §B.11, and only
  under its exit criterion.

**Exit criteria — all must be TRUE**

| # | Must be true |
|---|---|
| 5.1 | A cold-storage (`vm.cool()`) gas table for **our** hook at 1/2/5/10/25/50 seats exists and is in `PROGRESS.md` |
| 5.2 | The head-only swap cost is **flat in queue depth** — measured, not assumed |
| 5.3 | The chosen `MAX_SEATS` keeps a full sweep under a **stated** callback budget, with the budget written down and justified |
| 5.4 | Every optimisation is backed by a differential test showing **wei-identical** results vs. the pre-optimisation implementation |
| 5.5 | Packing to `uint128` reverts on overflow rather than wrapping — asserted by a test that forces it |
| 5.6 | If 5c was attempted: **wei-exact agreement with the O(N) reference over ≥1000 randomised swaps**, or an explicitly bounded, proven-non-farmable divergence. **Otherwise it is not shipped**, and `PROGRESS.md` says so. |

**Gate:** §D.7.

---

## C.6 PHASE 6 — Adversarial and invariant campaign

**Purpose:** try, seriously, to break everything above. **Start shadowing this from Phase 1** — do
not save it for the end. The invariant handler written early catches things unit tests never will.

**Entry criteria:** Phase 5 exit criteria all true.

**Build**
- `test/queue/handlers/QueueHandler.sol` — a bounded actor that deposits, withdraws, swaps in both
  directions, transfers seats, sets self-prices and triggers buyouts, with `bound()`ed inputs and a
  ghost-variable ledger.
- `test/queue/Invariant.t.sol` — **`targetContract(address(handler))` MUST be called.**
  `targetSelector` alone leaves the fuzz target set as *every* contract deployed in `setUp`, which
  makes the campaign vacuous. This is how an invariant suite "passes on luck" and it has happened in
  this repo.
- `test/queue/Adversarial.t.sol` — the named attacks below.

**The invariants**

| # | Invariant |
|---|---|
| I1 | `Σ_i q[i].a0` equals the handler's ghost total of token0 in, minus out — and the same for token1 |
| I2 | The hook's position redeems for **≥** `Σ face value − K`, `K` a stated small constant. **Solvency.** |
| I3 | INVARIANT C: `∀ i < cursorX : q[i].aX == 0`, both tokens |
| I4 | Front-first: if seat `j` was touched, every seat `i < j` with a nonzero outgoing balance was fully exhausted |
| I5 | Every seat id has ERC-6909 supply exactly 1 |
| I6 | `seatIndex` and `indexSeat` are mutual inverses over live seats |
| I7 | No seat balance ever underflows; no legal swap sequence bricks the hook |
| I8 | Total rent charged equals total rent credited plus `unallocatedRent0` (Phase 4) |

**The named attacks — each gets a test that runs it and asserts the outcome**

| Attack | Expected outcome | Where it comes from |
|---|---|---|
| **Split your order to stay at the head** | **Works, and is the design.** Assert that it concentrates informed flow onto the priced seat and does not break accounting. Do not "fix" it. | §B.12 |
| **Wash-trade from the front to farm fees** | Net ≈ −gas. You pay the fee and receive it, because you are the seat being filled. Closed by construction. | free-lane audit |
| **Sit at the back and free-ride on the front's depth** | Impossible: depth is your own capital, and the back is filled on exactly the trades that hurt most. | free-lane audit |
| **Dust the head to grief it** | Impossible: rank cannot be granted by deposit. Assert the revert. | §B.8 |
| **Flash-loan the whole queue** and trade against yourself | Zero-sum minus gas. | §1.6 of the source doc |
| **Manipulate the allocation price** | **Nothing to push** — the price is the swap's own realised average from `PoolManager`. Assert that no hook-controlled input enters it. | §E.11 |
| **Rank-then-run** | **Open** under plain rank; **closed** under Harberger. Test both, assert both. | §E.13 |
| **Reentrant token** on deposit / withdraw / buyout | No double-spend, no double-credit | standard |
| **Zero-amount and one-wei swaps** | No revert, no drift beyond the stated residual | edge cases |
| **Empty queue / single seat / all seats empty** | Defined behaviour, asserted | edge cases |
| **A swap that exactly exhausts the whole queue** | Fills exactly, no `QueueUnderflow` | boundary |
| **A swap one wei larger than the queue** | `QueueUnderflow` | boundary |

**Exit criteria — all must be TRUE**

| # | Must be true |
|---|---|
| 6.1 | Every invariant I1–I8 holds under a campaign of ≥256 runs × ≥64 depth, with `targetContract` set |
| 6.2 | **Mutation check:** deliberately break each of ≥5 distinct mechanism points and confirm **the invariant campaign** (not just a unit test) goes red for each |
| 6.3 | Every named attack above has a test and an asserted outcome |
| 6.4 | Every remaining open weakness is written down in `PROGRESS.md` and in the README. **Nothing is hidden.** |
| 6.5 | `forge test` full suite green, and you have personally confirmed it can go red |

**Gate:** §D.8.

---

## C.7 PHASE 7 — Testnet deploy, demo, video, README

**Purpose:** ship it. Clear the binary gates. Make the idea legible in five minutes.

**Entry criteria:** Phase 6 exit criteria all true — **or** Phase 3's, if shipping early.

**Build**
- `script/DeployQueue.s.sol` using `HookMiner` + CREATE2. Templates:
  `archive/2026-08-26/script/base/BaseScript.sol`,
  `archive/2026-08-26/script/01_CreatePoolAndAddLiquidity.s.sol`,
  `archive/2026-08-26/script/03_Swap.s.sol`.
- Deploy per §H.
- `README.md` — the thesis sentence first (§A.3), then the mechanism, then **the "what QUEUE is NOT"
  table from §A.4, verbatim**, then how to run the tests, then the partner-integrations line
  (**required by Gate 5** — write "No partner integrations." if there are none).
- Video, **≤5 min, human voice**. Structure: the problem (every AMM is pro-rata; every real market is
  price–time priority) → how it works (the queue, the realised-price allocation, one diagram) → how
  it compares (am-AMM auctions *management rights to one winner per block*; QUEUE sells *an ordering
  over the existing LPs' capital*, perpetually, to many holders, with no auction) → the honest
  limitations.

**Exit criteria — all must be TRUE**

| # | Must be true |
|---|---|
| 7.1 | All eight binary gates (§A.5) are satisfiable and satisfied |
| 7.2 | A third party can clone the repo and get a green `forge test` from the README alone |
| 7.3 | The demo runs against the deployed testnet hook: seed the roster, run a small swap (head fills), run a sweeping swap (queue walks), transfer a seat, show the fills follow the rank |
| 7.4 | The video is under 5:00 and has a human voice |
| 7.5 | The README states every open weakness in §A.4 and §6.4 |
| 7.6 | **The am-AMM distinction is made explicitly**, because a judge will test it (§E.14) |

**Gate:** §D.9 — the "how to know you are done" checklist.

---
---

# D. EVALS, VERIFICATION AND VALIDATION

**This is the most important section in the document. It is deliberately mechanical.**

The premise: **a false PASS is worse than an honest FAIL.** A wrong number in this repo does not
degrade a feature — it is the whole pool's accounting, and a bug there is lost funds.

**The empirical basis for the paranoia, from this project's own history: mutation testing or a
negative control caught a defective test in 7 of 7 cases where one was run** — and in several of those
the defective test belonged to the person who wrote the control. Not "sometimes." Seven for seven.

## D.1 The five laws — stated as rules

### LAW 1 — NEVER test at a 1:1 price. Use 1:4 or worse.

A 1:1 fixture hides **every** token0/token1 unit-mixing bug. The allocator's entire job is converting
one token into the other at a realised ratio; at 1:1 a swapped pair of variables is invisible.

This is not theoretical. A prior project in this repo shipped a metric that subtracted
token1-denominated volume from token0-denominated volume. On its 1:1 / 18-decimal fixture the error
read `0.003` and looked fine. On a 1:4 pool the same balanced flow read **`0.607`**. On ETH/USDC it
would have pinned at maximum fee forever. **The fixture, not the code, was the reason the bug lived.**

**The rule:**
- Default fixture: `Constants.SQRT_PRICE_1_4`.
- Every conservation claim must **additionally** be shown at a far-from-unit price (1:1000 and
  1000:1) and with **asymmetric decimals** (18 / 6).
- Every fixture asserts it is not unit-priced: `require(s0 != s1, "fixture is unit-priced");` — the
  spike does exactly this and you should copy the line.
- **A 1:1 test may exist only as an explicitly-labelled control**, never as the primary evidence for
  anything.

### LAW 2 — Every claim needs a negative control that goes RED, and you must assert the revert REASON.

A control that fails for an unrelated reason proves nothing. This exact mistake was made in this
repo: a test asserted only that a revert reason was non-empty, and passed under a mutation that
reverted with a *completely different* error.

**The rule:** every control asserts the **exact** reason string or error selector.

The spike's harness is the pattern to copy, and it is small:

```solidity
function _expectRed(uint8 mode, uint160 nonce, string memory what, string memory wantReason) internal {
    (bool ok, bytes memory err) = address(this).call(
        abi.encodeWithSelector(this.harness.selector, mode, nonce));
    assertFalse(ok, what);
    string memory got = _reason(err);
    emit log_named_string("   control reverted with", got);
    assertEq(got, wantReason, "control went red for the WRONG reason");   // <<<<
}
```

Its structural trick is worth stealing wholesale: **one contract, one immutable `mode`, an identical
test body.** The mutation is a constructor argument, so the mutant and the real thing run through
*exactly* the same assertions on *exactly* the same state. There is no "the control uses a different
setUp" escape hatch.

**And there must be a positive control on the controls:** the unmutated harness must **PASS** through
the identical external-call path the mutations fail through. Without it, `_expectRed` might be
passing because `harness()` always reverts.

```solidity
function test_positiveControl_sameHarnessPassesUnmutated() public {
    (bool ok,) = address(this).call(abi.encodeWithSelector(this.harness.selector, uint8(0), uint160(0x5005)));
    assertTrue(ok, "unmutated harness failed: the controls prove nothing");
}
```

Prediction discipline: **write down the reason you expect the control to fail with, before you run
it.** In the original spike, the author's first guess at all three reasons was **wrong**. That is
precisely why asserting the reason has value — it caught a misunderstanding of the author's own
mechanism.

### LAW 3 — Measure conservation on PoolManager's own balances, never on the hook's bookkeeping.

A hook that miscounts will happily agree with itself. The only trustworthy measurement is the ERC-20
balance that actually moved:

```solidity
uint256 p0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
// ... swap ...
uint256 n0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));
inAmt = n0 - p0;    // this is TRUTH. hook.totals() is the thing on trial.
```

> ⚠️ **AMENDED 2026-08-26 — the raw-balance form above is BLIND to a whole bug class, and this was
> paid for.** `protocolFeesAccrued` money stays inside PoolManager's ERC20 balance until it is
> collected, so **the spike's own LAW 3 conservation test passes at 0 wei error while the position is
> short 0.354e18 token0.** Measure against **`PoolManager balance − protocolFeesAccrued(currency)`**,
> or directly against `redeemAll()`. Any test written the old way is blind to every
> protocol-fee-shaped bug. Evidence: `docs/research/protocol-fee/experiment.md` F3/§6 (7 tests incl.
> 3 mutations); `PITFALLS.md` §2.6; §E.5; AGENTS.md §3.3.

**Corollary:** an assertion of the form `hook.internalTotal() == hook.internalSum()` is worth
nothing. Both sides come from the defendant.

**Second corollary (solvency, and it is separate):** conservation of the *ledger* and *redeemability
of the position* are two different claims. The spike proved the first and **disproved** the second
(§B.7). Always test them apart. `assertEq(ledger, expected)` and
`assertLe(ledger, actuallyRedeemable + K)` are different tests and you need both.

### LAW 4 — Gas must be measured with `vm.cool()`.

Forge keeps storage warm for the whole test body. Seeding N seats in the same context makes every
seat slot warm and **understated a real measurement here by 2.5×** (125k → 309k at 50 seats).
`vm.cool(address(hook))` restores production cold-access pricing.

```solidity
vm.cool(address(hook));
_swap(true, 1e18);            // head-only
uint256 gSmall = hook.lastAllocGas();
vm.cool(address(hook));
_swap(true, 18_000e18);       // sweeping
uint256 gSweep = hook.lastAllocGas();
```

**The rule:** any gas number that will be quoted to anyone — README, video, `PROGRESS.md`, the owner
— was measured after `vm.cool()`. A number without it is not a measurement, it is a lower bound with
no stated baseline.

**And name the baseline.** This repo once published a "23.5k gas overhead" figure that turned out to
be an artefact of comparing a hook that transfers tokens against one that does not. It was retracted.
Every gas claim states what it is being compared against.

### LAW 5 — A first-run pass is a reason for suspicion, not satisfaction.

**The rule:** before believing any suite, break the code it covers deliberately and confirm the suite
goes red. If you cannot make it go red, it is not testing what you think.

Apply this at three scales:
- **Per assertion:** if a specific assertion is load-bearing, mutate the specific line it covers.
- **Per phase:** the phase gate's negative controls (§D.3–§D.8).
- **Per campaign:** Phase 6 requires ≥5 mutations that the **invariant campaign** catches, not just
  unit tests.

## D.2 GATE 0 — reference-spike reproduction

**Command**
```bash
forge test --match-path "test/spike/QueueAllocator.t.sol" -vv
```

**Expected: `9 passed; 0 failed; 0 skipped`.**

**Expected values — reproduced on this machine 2026-08-26. These are the ground truth for everything
downstream.**

`test_Q1_allocationIsExact_butFaceValueRedemptionIsNot`:
```
queue total token0: 2248553145997694428660
queue total token1: 445000573750774563494
PoolManager-measured token0: 2248553145997694428660     <- must be EQUAL
PoolManager-measured token1: 445000573750774563494      <- must be EQUAL
redeemed token0 (real ERC20): 2248553145997694428657
redeemed token1 (real ERC20): 445000573750774563490
residual token0 (redeemed - queue): -3
residual token1 (redeemed - queue): -4
```

`test_Q1b_residualWithZeroSwaps`: `-1`, `-1`.

`test_Q1c_residualDoesNotGrowWithSwapCount`:
```
residual token0 @2 swaps: -2      residual token1 @2 swaps: -3
residual token0 @40 swaps: -9     residual token1 @40 swaps: -11
residual token0 @200 swaps: -52   residual token1 @200 swaps: -54
```

`test_Q1d_mechanism_zeroFeePoolDoesNotAccumulate`:
```
200 swaps @ 0.30% fee, residual token0: -52    token1: -54
200 swaps @ 0    fee,  residual token0: -46    token1: -50
```
**88% of the drift survives with no fee — this is the experiment that falsified the fee-growth
hypothesis. Do not let anyone reinstate it.**

`test_Q2_gasProfileVersusQueueDepth`: the §B.9 table, ±2%. Note `31,864` at 1 seat and `31,874` at
2–50; the flatness is the finding.

**The three negative controls — each must go RED with its exact reason:**

| Test | Mutation | Required revert reason |
|---|---|---|
| `test_negativeControl_proRataGoesRed` | pro-rata (what v4 genuinely does today) | `swap1: entry a0` |
| `test_negativeControl_offByOneCursorGoesRed` | cursor starts at seat 1 | `swap1: entry a0` |
| `test_negativeControl_flooredSharesGoesRed` | remainder line deleted | `swap2: token0 conservation` |

Plus `test_positiveControl_sameHarnessPassesUnmutated` must PASS.

**Pass condition:** every value above reproduces. **Any divergence → stop and escalate** (§C.0).

## D.3 GATE 1 — allocator core

**Commands**
```bash
forge test --match-path "test/queue/Allocator.t.sol" -vv
forge test --match-path "test/queue/Controls.t.sol"  -vv
forge test --match-test "invariant_" --match-path "test/queue/*"
```

**Assertions required**

```solidity
// LAW 3 — against PoolManager, never against the hook
assertEq(hook.totalToken0(), expT0, "token0 conservation");
assertEq(hook.totalToken1(), expT1, "token1 conservation");
// composition, against an INDEPENDENTLY WRITTEN reference allocator
for (uint256 i; i < n; i++) {
    (uint256 a0, uint256 a1) = hook.seat(i);
    assertEq(a0, ref0[i], "seat a0"); assertEq(a1, ref1[i], "seat a1");
}
// INVARIANT C
for (uint256 i; i < hook.cursor0(); i++) { (uint256 a0,) = hook.seat(i); assertEq(a0, 0, "cursor0 leads"); }
for (uint256 i; i < hook.cursor1(); i++) { (, uint256 a1) = hook.seat(i); assertEq(a1, 0, "cursor1 leads"); }
```

**The independent reference allocator matters.** Write it in the *test*, from this document's §B.5
pseudocode, without looking at your `src/` implementation. If both are wrong in the same way,
conservation against PoolManager still catches it — that is the point of having two mismatched
witnesses rather than one.

**Five mandatory negative controls, each asserting its specific reason:**

| # | Mutation | Must go red on |
|---|---|---|
| N1 | Pro-rata instead of front-first | seat composition, swap 1 — observed reason `swap1: seat a0` |
| N2 | Cursor starts at seat 1 | seat composition, swap 1 — observed reason `swap1: seat a0` |
| N3 | **Remainder line deleted** (floor everything) | **conservation, swap 2 — not swap 1**. Observed `swap2: token0 conservation` |
| N4 | `cursorY = min(cursorY, start)` deleted (§B.6) | **INVARIANT C, at swap 3** — observed `swap3: INVARIANT C cursor1 leads`. *Corrected 2026-08-27: this fires one swap EARLIER and more directly than "composition at swap 4", because the reverse leg credits token Y from index 0 upward and the un-pulled cursor immediately leads a funded seat* |
| N5 | `beforeAddLiquidity` guard removed, then an external LP adds | **SOLVENCY** (`redeemAll()` no longer covers the ledger) — *corrected 2026-08-27, see below* |

**N3's reason string must specifically assert that swap 1 passed and swap 2 failed.** If your control
dies at swap 1, your fixture has only one seat being filled and you are not testing the remainder
line at all.

**N5 is the one people skip.** It is the guard that makes the hook the sole LP, i.e. the premise of
every other number. Test it.

**N5's expected failure was WRONG in this document until 2026-08-27, and the reason is instructive.**
It predicted "conservation, immediately". It does not fail conservation at all: the fixture derives
expected totals from PoolManager's balance movements, which cover the WHOLE swap — and the hook
credits the queue that same whole swap. Both sides move together and the LEDGER ties out perfectly.
What actually breaks is **solvency**: an outside LP takes a pro-rata share of every fill, so the
hook's own position can no longer cover the ledger it is writing. Assert it with `redeemAll()`.
This is LAW 3's second corollary yet again — **ledger conservation and position redeemability are
different claims and need different assertions.**

**Fuzz:**
```bash
forge test --match-test testFuzz_allocationNeverLosesAWei -vv
```
over random `(amtIn, amtOut, uint256[] balances)` with `amtOut <= Σ balances`: assert
`Σ assigned == amtIn` **exactly**, and `Σ taken == amtOut` **exactly**. No tolerance. This is where
the remainder line earns its keep and it costs nothing to run.

## D.4 GATE 2 — deposit / withdraw / dust

**Commands**
```bash
forge test --match-path "test/queue/Deposit.t.sol" -vv
```

| Test | Assertion |
|---|---|
| `test_depositCreditsActualNotRequested` | credited == `modifyLiquidity` delta magnitude; remainder refunded; **assert the refund, not just the credit** |
| `test_allWithdrawalOrderings_N3` | all 6 orderings, everyone paid in full, **no ordering leaves anyone short** |
| `test_lastWithdrawerIsNotShort` | after 200 swaps, the last withdrawer receives their full seat balance |
| `test_solvencyAfter200Swaps` | `assertLe(Σ paid out, position actually redeems for)`; `assertLe(gap, 200)` |
| `test_withdrawToZeroKeepsTheSeat` | seat still exists at the same index |
| `test_cannotWithdrawFromAnotherSeat` | reverts with the specific auth error |
| `testFuzz_cursorsStayValidUnderInterleaving` | INVARIANT C after arbitrary deposit/withdraw/swap sequences |
| **`test_negativeControl_faceValueWithdrawLeavesLastShort`** | with the dust fix removed, **red**, with the shortfall reason asserted |

**The dust-fix control is the point of this gate.** It is the only way to know the fix does anything:
the bug is 52 wei after 200 swaps, which is invisible unless you look for it deliberately.

## D.5 GATE 3 — rank token

**Commands**
```bash
forge test --match-path "test/queue/Rank.t.sol" -vv
```

| Test | Assertion |
|---|---|
| `test_seatSupplyIsAlwaysExactlyOne` | for every id, under every operation |
| `test_transferMovesRankNotCapital` | sender's `pendingWithdraw` gains exactly the seat's old balances; recipient's seat is empty |
| **`test_transferFromAlsoMovesRankNotCapital`** | **the same, through `transferFrom` and through an operator** |
| `test_fillsFollowTheNewHolderImmediately` | the very next swap fills the transferred seat's index for the new holder |
| `test_seatCannotBeMintedByDepositing` | reverts |
| `test_seatCountNeverExceedsMax` | reverts at `MAX_SEATS + 1` |
| `test_emptySeatIsTransferableAndKeepsRank` | index unchanged |
| **`test_negativeControl_transferFromNotOverridden`** | a variant overriding only `transfer` → **red**, reason asserts capital escaped |
| **`test_negativeControl_depositMintsASeat`** | a variant granting rank by deposit → **red** |

The `transferFrom` control is not paranoia. Overriding `transfer` and forgetting `transferFrom` is
*the* canonical way this bug ships, because the happy-path test only ever calls `transfer`.

## D.6 GATE 4 — Harberger

**Commands**
```bash
forge test --match-path "test/queue/Harberger.t.sol" -vv
```

| Test | Assertion |
|---|---|
| `test_rentAccruesLinearlyInTime` | exact vs. hand-computed, at three elapsed times |
| `test_rentSumsExactlyToWhatWasCharged` | `Σ credited + unallocated == charged`, **to the wei** (remainder rule again) |
| `test_rentWithNoRecipientIsNotLost` | lands in `unallocatedRent0`, distributed at the next eligible settlement |
| `test_buyoutTransfersRankOnly` | seller's capital fully recoverable; buyer's seat empty |
| `test_underpricedSeatIsBoughtOut` / `test_overpricedSeatPaysForIt` | both numerically demonstrated |
| `test_foreclosureMovesSeatToTailAndFixesCursors` | INVARIANT C still holds after |
| **`test_rankThenRunClosedUnderHarbergerOpenUnderPlainRank`** | **runs BOTH variants side by side; plain rank lets the holder abandon, Harberger does not.** This is the phase's headline result. |
| `test_noOracleNoCollateralNoLiquidation` | a review assertion, plus a grep in CI |
| `test_negativeControl_settleWithoutCharging` | **red** |
| `test_negativeControl_rentPaidToSeatsAhead` | **red** — this is an economics inversion, exactly the class of bug that killed `HardcapHook` |
| `test_reentrantCurrencyDuringBuyout` | no double-spend |

## D.7 GATE 5 — gas and scale

**Commands**
```bash
forge test --match-path "test/queue/Gas.t.sol" -vv
forge test --gas-report --match-path "test/queue/*"
```

| # | Assertion |
|---|---|
| G1 | Every measurement preceded by `vm.cool(address(hook))` — **grep the test file and confirm** |
| G2 | Head-only cost flat across 1..50 seats within ±5% |
| G3 | Sweep cost linear in seats touched; slope and intercept recorded in `PROGRESS.md` |
| G4 | A full sweep at `MAX_SEATS` is under the stated budget |
| G5 | Every optimisation: `testFuzz_differentialAgainstReference` shows **wei-identical** results over ≥1000 randomised swaps |
| G6 | `uint128` packing **reverts** on a forced overflow (test it by forcing it) |
| G7 | If the O(1) redesign was attempted: **wei-exact** vs. O(N) over ≥1000 randomised swaps including direction reversals, **or it is not shipped** |

> **G7 is a gate, not a target.** "It's within a few wei" is a FAIL unless the divergence is measured,
> bounded, and shown non-farmable in writing. §B.11 explains why this specific optimisation is
> suspect.

## D.8 GATE 6 — adversarial and invariants

**Commands**
```bash
forge test --match-path "test/queue/Invariant.t.sol"   -vv
forge test --match-path "test/queue/Adversarial.t.sol" -vv
forge test                                              # everything
```

Recommended campaign config in `foundry.toml`:
```toml
[invariant]
runs = 256
depth = 64
fail_on_revert = false
```

| # | Assertion |
|---|---|
| V1 | **`targetContract(address(handler))` is called.** Grep for it. Without it the campaign is vacuous. |
| V2 | I1–I8 (§C.6) all hold |
| V3 | ≥5 deliberate mutations each caught **by the campaign**, with the failing invariant named for each |
| V4 | Every named attack in §C.6 has a test with an asserted outcome |
| V5 | `fail_on_revert = false` is justified — the handler is expected to hit legitimate reverts (auth, underflow guards). If you set it `true`, the handler must pre-filter, and say which you chose and why |

**Mutation targets for V3** (pick ≥5, each must break a *different* invariant):
remainder line · cursor `min` update · front-first ordering · the `beforeAddLiquidity` guard ·
capital evacuation on transfer · rent recipient direction · seat-supply accounting · the
deposit-credits-actual rule.

## D.9 HOW TO KNOW YOU ARE DONE

Every line must be a **yes**. Not "mostly", not "should be".

**Correctness**
- [ ] Conservation is exact to the wei against **PoolManager's own balances**, at 1:4, 1:1000, 1000:1, and 18/6 decimals.
- [ ] Composition matches an **independently written** reference allocator, seat by seat.
- [ ] Every depositor is paid in full, in **every** withdrawal ordering, after ≥200 swaps.
- [ ] Solvency (I2) holds: the position redeems for at least the ledger's face value minus a **stated** constant.
- [ ] INVARIANT C holds under fuzz.
- [ ] Every seat id has ERC-6909 supply exactly 1, always.
- [ ] Rank transfers move **rank only** — through `transfer`, `transferFrom`, and operator paths.

**Evidence quality**
- [ ] Every mechanism claim has a negative control that goes **red with an asserted specific reason**.
- [ ] The positive control on the controls passes through the identical path.
- [ ] ≥5 mutations are caught by the **invariant campaign**, not only by unit tests.
- [ ] No test uses a 1:1 price as its primary evidence for anything.
- [ ] Every gas number was measured with `vm.cool()` and names its baseline.
- [ ] `targetContract` is set on the invariant campaign.
- [ ] **You have personally broken the suite and watched it go red.**

**Honesty**
- [ ] The README contains the **"what QUEUE is NOT"** table (§A.4), unsoftened.
- [ ] Every open weakness is written down: the roster bound, the residual (if unfixed), the O(1)
      redesign's status, rank-then-run (if Harberger is unbuilt), τ as a governance parameter.
- [ ] No claim is made that the tests do not support. Grep the README for "prevents", "eliminates",
      "guarantees", "always" — and justify or delete each one.
- [ ] `PROGRESS.md` records every decision taken under ambiguity and why.

**Gates**
- [ ] Public repo · v4 hook · new code · README with partner-integrations line · tests · video ≤5min,
      human voice.
- [ ] A stranger can clone and get green from the README alone.

## D.10 Decision framework — what to do when you hit something ambiguous

You will hit ambiguity. This table is the answer. Use it instead of guessing or stalling.

| Situation | What to do |
|---|---|
| **A test passes that you expected to fail** | **STOP. This is the highest-risk state in the project.** It means either your understanding is wrong or the test is not testing what you think. Prove the test can fail *at all*: mutate the exact line it covers and confirm red. Only then believe the pass. **Write the episode in `PROGRESS.md` either way** — a resolved surprise is one of the most valuable things you can hand the next person. |
| **A test fails that you expected to pass** | Good — this is the cheap direction. Read the failure before changing anything. Do **not** loosen an assertion to make it pass; if the assertion was aspirational, replace it with what is actually true and **say what is not**. |
| **A number in this plan does not reproduce** | Stop. Record what you got vs. what is written, to the wei. Do not "adjust the expected value." A divergence invalidates downstream assertions and must be escalated. |
| **A design choice is unspecified and both options are defensible** | Pick the **simpler** one, write down which and why in `PROGRESS.md`, and continue. Do not stall. Do not ask. |
| **A design choice changes the mechanism's economics or its security** | **Stop and ask the owner.** Non-exhaustive: who receives fees or rent; how seats are allocated; the rent direction; adding an admin function, an upgrade path, or a privileged role; adding an external dependency or an oracle; changing `MAX_SEATS` semantics; anything that reads a price. |
| **The plan contradicts the code** | The **code wins as evidence**; the **plan wins as intent**. Record the divergence in `PROGRESS.md` and **update `PLAN.md`**. |
| **The archive contradicts this plan** | This plan and `AGENTS.md` win. The archive is history. Note the contradiction in `PROGRESS.md` — the archive being wrong is itself information. |
| **You find a bug in the *design*, not the code** | Write it up, with a failing test if you can. **This is valuable output, not a setback.** Do not patch around it silently — a silent patch converts a known limitation into an unknown one. |
| **You are tempted to add something not in the plan** | Ask: does it make the mechanism more correct, or does it make it bigger? Scope drift here has a specific shape — an admin function "for flexibility," an off-chain helper "just for the demo." **Both are forbidden** (§E.19). |
| **A green result arrives on the first try** | Suspicion, not satisfaction. Break it deliberately. If you cannot make it go red, you have not tested it. |
| **You cannot make a control go red** | The control is wrong, or the code path is not reachable from your fixture. Both are bugs. Do not delete the control. |

## D.11 What to do with a result you did not expect

Two things happened in the original spike that are worth internalising, because both were **the
author being wrong and the measurement being right**:

1. **The residual's cause was mis-predicted twice.** First guess: "constant add/remove dust" — wrong,
   it grows. Second guess: "v4's fee-growth truncation" — wrong, a zero-fee pool retains 88% of the
   drift. The right move both times was **an experiment that could falsify the hypothesis**, not an
   assertion of it.
2. **A gas number was 2.5× optimistic** until `vm.cool()` was applied.

**The rule this yields: when you have a hypothesis about a number, design the experiment that would
kill it, not the one that would confirm it.** The zero-fee pool is the model: it is one line of
fixture change and it settled the question outright.

And when a prediction is wrong, **write the wrong prediction down in `PROGRESS.md` next to the right
answer.** That is the single highest-value thing in this project's history — the two things the
spike's author got wrong are in the write-up precisely because they were wrong.

---
---

# E. GOTCHAS, FOOTGUNS AND DANGEROUS AREAS

Every one of these was paid for. Violating one silently produces a green test that proves nothing.

## E.1 The 1:1 fixture trap ⚠⚠⚠ THE LIVE RISK FOR THIS PROJECT

Covered as LAW 1 (§D.1). Restated here because it is *the* risk specific to QUEUE: **the allocator
splits a two-token delta at a realised ratio.** A `token0`/`token1` mix-up at 1:1 is arithmetically
invisible. **Every test must run at a non-unit price with a negative control, or a swapped variable
passes green.**

## E.2 `vm.cool()` and warm storage

Covered as LAW 4. Understated a real measurement here by **2.5×**. Any gas number you will ever quote
was taken after `vm.cool()`.

## E.3 The remainder-assignment line

Covered in §B.5 step 4. **It survives swap 1 and only dies at swap 2.** If your refactor's test suite
has only single-seat fills, the line is untested. Multi-seat fill or it does not count.

## E.4 The ~0.26 wei/swap redemption residual — and the hypothesis that is FALSE

Covered in §B.7. Restated because someone will re-derive the wrong cause:

> **Fee-growth truncation is NOT the cause. A zero-fee pool falsifies it — 88% of the drift survives
> with no fee at all.** The real cause is that **v4 computes a swap's amounts and a position's
> redeemable value with two differently-rounded formulas, both in the pool's favour.**

Do not re-run that experiment expecting a different answer. Do not write "fee rounding" in a comment.

## E.5 Protocol fee — **SOLVED AND BUILT 2026-08-27. Phase 1 ships the fix.**

> **STATUS: CLOSED.** The hazard is real, was measured, and is now fixed in production code with a
> mechanism that carries its own multi-pool negative control. `src/queue/QueueHook.sol::_beforeSwap`
> + `_afterSwap`; tests in `test/queue/ProtocolFee.t.sol` (6 tests, all of which go RED against the
> superseded mechanism). **Everything below about "re-derive it arithmetically" was the previous
> plan and is WRONG — deleted rather than annotated.**

### The hazard

The allocator credits the queue with `amtIn` = the swapper's full input, fee included, because the
sole LP is owed all of it. That is exactly right **when the protocol fee is zero**. When a protocol
fee is set, part of the input is skimmed to the protocol and **never reaches the LP position**, so
the ledger credits more than the position can pay — a slow, silent insolvency.

Measured at the maximum legal fee: the queue was short **0.354e18 token0** over the four-swap
scenario. Because allocation is front-first, **the tail absorbed 100% of it**.

Worse, the obvious test is blind: `protocolFeesAccrued` money stays inside PoolManager's ERC20
balance until it is collected, so a raw-balance conservation test **passes at 0 wei error while the
position is short 0.354e18**. That is why LAW 3 is amended project-wide.

### The decision (unchanged): P2, account for it

Net the protocol fee out of `amtIn` before allocating. Not P1 (refuse) — P1 hands the
`protocolFeeController` a permanent off-switch for the product.

### The mechanism, AS BUILT — snapshot the window, do not diff a counter

**The previous implementation diffed `poolManager.protocolFeesAccrued(currency)` ACROSS
TRANSACTIONS. That was broken**, because the mapping is `mapping(Currency => uint256)` — global per
currency, no `PoolId` (`ProtocolFees.sol:21`). It therefore absorbed every other v4 pool's protocol
fees on either token: **X1** silent under-credit from ordinary foreign volume, **X2** a permanent
brick when foreign accrual exceeded the next swap's input.

**The counter was never the problem. The measurement window was.** The fix:

```solidity
// beforeSwap — open the window
pfSnapshotPlusOne = poolManager.protocolFeesAccrued(inputCurrency) + 1;

// afterSwap — close it
uint256 pfDelta = poolManager.protocolFeesAccrued(inputCurrency) - (snap - 1);
amtIn -= pfDelta;
```

Between those two callbacks `PoolManager.swap` executes exactly one `Pool.swap` on exactly one pool
and calls `_updateProtocolFees(inputCurrency, amountToProtocol)`. **That window contains no external
call**, so no foreign pool can accrue inside it and `collectProtocolFees` cannot run inside it. The
difference is therefore *exactly this swap's protocol fee, on this pool, to the wei.*

**Why this is better than deriving the fee arithmetically.** Because the number is *read* rather than
*computed*, every difficulty the previous plan listed simply does not arise:

| Previously feared | Why it is now a non-issue |
|---|---|
| `amountToProtocol` is summed **per swap step** with per-step rounding across tick crossings | We never compute it; we read the sum v4 itself accumulated |
| `lpFee == 0` ⇒ `swapFee == protocolFee` ⇒ v4 takes the ENTIRE `feeAmount` by a different formula (`Pool.sol:391-392`) | Same read, no special case. Asserted: `test_5_3_lpFeeZeroUnderProtocolFee` |
| Exact-output rounds the other way | Same read, no special case |
| Clamping removes the BRICK but not the UNDER-CREDIT | Nothing is clamped. `pfDelta > amtIn` is now structurally impossible and **reverts by name** rather than being silently absorbed |

**The snapshot is TRANSIENT storage on purpose.** It cannot survive the transaction, so a stale or
never-initialised snapshot — the third documented failure of the old design — is impossible by
construction rather than by convention.

**Cost:** one extra hook permission (`beforeSwap`, see §B.2), one `SLOAD` and one `TSTORE` per swap.

### What this required changing elsewhere

- **§B.2 permissions gain `beforeSwap`.** The hook address low bits move from `0x0840` to `0x08C0`.
- **`AFTER_SWAP_RETURNS_DELTA` is still OFF** and `beforeSwap` returns a ZERO delta. QUEUE still
  takes nothing from the swap.

### The doctrine this cost us, and the rule that follows

The superseded mechanism was "MEASURED closing the gap to 3 wei" by `test_M3` — **in a single-pool
fixture**. The mechanism was right about *what* to subtract; the **instrument** was wrong, and the
fixture was structurally incapable of showing it.

> **Before trusting any measurement on this project, ask what the fixture is structurally incapable
> of representing.**

Every test in `test/queue/ProtocolFee.t.sol` therefore runs with a **foreign pool sharing a
currency**, and all six were confirmed to go RED when the superseded mechanism is reinstated. One of
them originally passed against it — because the foreign volume came *after* the measurement — and
was strengthened. That near-miss is recorded because it is the same mistake, one layer down.

**Still required of any future change here:** a test that sets a protocol fee must assert
`protocolFeesAccrued > 0` **first** — `setProtocolFee` silently no-ops for a non-controller caller,
and without that guard the test cannot fail.

## E.6 `donate()` pays whoever is in range NOW

`poolManager.donate()` pays whoever holds in-range liquidity **at the moment of the call**. There is
no primitive that pays "the liquidity present at block open," and no way to direct a donation to a
chosen party. OpenZeppelin's own `LiquidityPenaltyHook` documents the bypass in its NatSpec: dust
from a second account at an empty tick, push the price there, collect your own penalty donation.

**Relevance to QUEUE:** do not reach for `donate()` to pay Harberger rent, to distribute dust, or to
do anything else. The hook has its own ledger and its own `unlock()`; use them.

## E.7 `PoolManager` keys positions by the unlock's `msg.sender`

Usually the router, not the trader. **For QUEUE this is satisfied by construction and it is the
design, not a workaround:** the hook *is* the unlocker and therefore the position owner.

**The consequence to remember:** every liquidity operation must go through the hook's own
`poolManager.unlock()`. If you ever find yourself modifying liquidity from inside a callback that
someone else unlocked, the position you are touching is not yours.

## E.8 `sender` in callbacks is the router — a hook can NEVER see or pay the trader

`sender` in every swap callback is the **router** (asserted in-repo by
`test_Q3_senderIsTheRouterNotTheTrader`). `hookData` is caller-supplied and empty through every
standard router. The hook **never sees the recipient** — the router calls
`poolManager.take(currency, recipient, amt)` *after* the hook's last callback.

⇒ **Any design ending in "and we refund the swapper", "and we mint the trader a receipt", or "and we
gate the recipient" is not implementable as a hook.** Not hard — *impossible*.

Uniswap Labs hit this exact wall. Their shipped Permissioned Pools (merged to `v4-periphery/main`,
three audits) work around it with **a forked router plus the token's own transfer restrictions** —
neither of which is a hook. The hook is the redundant half.

**For QUEUE this is not a limitation, it is the entire design.** Every party QUEUE transacts with is
a depositor inside the hook's own `unlock()`. **Say this on camera** — it converts an apparent
limitation into a proof, and it explains why the trader-side object class is empty.

## E.9 A NoOp'd swap returning zero output REVERTS through the standard router

Proven by execution in this repo: a hook that consumes the specified amount and returns nothing
reverts through `V4Router` with `V4TooLittleReceived`, and through the hookmate router too.

**Relevance to QUEUE: none, and that is the point.** QUEUE never NoOps. Swaps execute normally, at
the normal price, through any router. **QUEUE is router-clean by construction and the trader's
experience is unchanged.** That is a real advantage over half the mechanisms in this space, and it
should be said.

**The trap is the temptation:** at some point someone will suggest batching, delaying, or clearing
swaps at a uniform price to strengthen the MEV story. **Every one of those requires a NoOp, and the
NoOp reverts through the standard router.** That is why uniform-price batch clearing has exactly one
instance in a 662-row directory of past submissions and it needed FHE *and* custom periphery.

## E.10 Never let untrusted code choose how much memory you allocate

Solidity's `(bool ok, bytes memory ret) = target.call(...)` form copies **all** returndata. A hostile
callee returns a gigabyte and you pay quadratic memory-expansion gas until you run out.

**This bug was introduced three times in this repo by people who already knew about it.** Fixed once,
reintroduced, fixed again.

**Relevance to QUEUE:** the allocator calls out to nothing, which is one of its structural
advantages. But **Phase 4 pays rent in `currency0`** and Phase 2 pulls tokens on deposit — those are
external calls to a token that may be arbitrary. Use bounded assembly copies (or a library that does,
such as OZ's `SafeERC20`, and check that it bounds the copy), and re-check this whenever you add a
call.

## E.11 There is nothing to push — protect that property

The allocation price is the swap's **own realised average**, taken from `PoolManager`'s returned
`BalanceDelta`. It is not a mark, not an oracle, not a TWAP, and not a quantity the hook chooses.
**There is nothing an attacker can manipulate.** This is the single biggest structural advantage
QUEUE has over every mark-to-market design in this repo — and every mark-to-market design in this
repo died to a settlement-instant price push.

**Guard it.** If a change introduces *any* price the hook chooses or reads — an oracle, a TWAP, a
mid-price, a "fair value" for a two-token basket — it re-opens the manipulation surface that this
design closed for free. That is why Harberger's self-price is denominated in **one** token and why a
seat's capital is **evacuated** rather than valued (§B.8, §B.10).

## E.12 `targetSelector` without `targetContract` makes an invariant campaign vacuous

`targetSelector` alone leaves the fuzz target set as **every** contract deployed in `setUp` — so the
campaign fuzzes mocks, tokens and the test contract itself, and "passes" without ever exercising the
handler. **Always call `targetContract`.** This is how an invariant suite passes on luck, and it has
happened here.

## E.13 The rank-then-run hole

The one free lane this design could **not** close under plain transferable rank:

> Buy the front cheaply during a quiet stretch; hop out before a scheduled event — a listing, an
> unlock, a CPI print — by dumping the rank token. The rank token's price will gap, so you eat the
> gap — **but only if there is a bid.** In a thin secondary market the front seat is **abandonable at
> the exact moment it matters.**

**The Harberger variant closes it** (Phase 4): you cannot leave your slot; you can only lower your
self-assessment and pay rent, and someone buys you out at your own number.

**Two obligations:**
1. **If you ship the plain-token variant, disclose this failure on camera.** Explicitly. It is a real
   hole and a technical judge will find it.
2. **Build the Harberger variant if there is time.** This is why it is Phase 4 and not "nice to have."

## E.14 The am-AMM adjacency — a judge WILL test this

The nearest real neighbours are the **am-AMM family** (`am-AMM hook` UHI1, `Maestro` UHI6,
`AuctionPool` UHI7, `Chronus` UHI2). They auction **pool-management and fee-setting rights to one
winner per block.**

**QUEUE sells an ordering over the existing LPs' capital, perpetually, to many holders, with no
auction and no per-block winner.**

That distinction is **one sentence deep**, and a judge will probe it. Therefore:
- **Lead with the pro-rata-vs-queue framing, not with the word "auction."**
- Do not describe Harberger as an auction. It is a self-assessed, always-for-sale lease with
  continuous rent — no bidders need show up, and there is no per-block winner.
- Also distinct: `Non-Fungible LP Positions Hook` (UHI8) fractionalises a position into fungible
  shares — **fungibility of capital, not of rank.** Different object.

## E.15 The splitting lemma

> A mechanism whose input is a **size** is defeated by splitting the quantity into k parts, at a cost
> of (k−1) × marginal gas — fractions of a cent on Unichain.

Kills, in one sentence: max price impact per trade, per-address JIT size caps, concave fee splits
favouring small LPs, minimum time between trades, per-block price-move bounds. Directory
corroboration: `circuit break|price band|rate.?limit|max.{0,6}impact` → **6 built, 0 prized.**

**QUEUE passes by construction: no input is a magnitude.** Rank is an ordering, not a threshold.
Splitting a swap into k parts routes all k slices to the head — which is the seat the market has
already priced for exactly that. **This is why QUEUE survives the impossibility proof that killed
every previous flow-segmentation attempt.**

**Keep it that way.** The moment you add a size threshold anywhere — "sweeps over X bypass the
queue", "seats under Y are skipped" — the lemma applies and the mechanism is defeated for gas.

## E.16 Rank must be BOUGHT or HARBERGER-HELD, never granted by deposit order

Covered in §B.8. Restated because it is a hard rule and easy to violate accidentally while building
Phase 2: **a seat that is free to occupy has no price, and QUEUE without a price for the seat is not
QUEUE.** Phase 2's append-at-tail allocation is provisional, labelled, and must be deleted.

## E.17 Diamond inheritance in hook mixins

Sibling mixins that both override the same hook callback form a diamond that every integrator must
disambiguate by hand — which invites them to resolve it by disabling the safety feature. **Keep the
inheritance a chain, never a diamond.** If `QueueSeats` and `QueueHarberger` both want a piece of
`_afterSwap`, make one extend the other; do not make `QueueHook` inherit both as siblings.

## E.18 Fairness is not a present-state property

"This swap was unfairly priced", "the hook stole in block N" are not expressible on-chain and can
never be a runtime check. **Do not claim them.** QUEUE makes no fairness claim — rank is *present
state*, with no history and no markout, which is exactly why it is expressible at all.

---

## E.19 DANGEROUS AREAS — do not enter these. They make no sense.

Each of these has been investigated in this repo and closed. Re-deriving one costs days and produces
the same answer.

### ✖ Do NOT attempt to detect toxic flow. It is PROVEN IMPOSSIBLE.

Every signal a hook can read is forgeable for free or invisible:

| Candidate signal | Why it fails |
|---|---|
| `sqrtPriceLimitX96` | Retail routers pass the sentinel; a searcher can pass the sentinel too. Free to forge. |
| `amountOutMinimum` / slippage budget | **The hook cannot see it at all** — enforced in the router *after* the last callback. |
| exact-in vs exact-out (`amountSpecified` sign) | Free to forge. |
| priority fee (`tx.gasprice − block.basefee`) | Zero under private orderflow. |
| `tx.origin` / EOA-vs-contract | `sender` is the router; and forgeable. |
| trade size | The splitting lemma (§E.15). |
| address / history / reputation | Value moves between addresses inside one unlock for **52,700 gas**. |

**QUEUE's entire premise is that it does not classify anyone.** It sells LPs different slices of the
flow and lets them bid. Adding a classifier would not strengthen it — it would re-open every evasion
in §B.12 and destroy the one property that makes the mechanism unforgeable.

### ✖ Do NOT attempt a curve that reduces LVR. It is PROVEN IMPOSSIBLE.

> **THEOREM.** With `V(p)` the LP value function and `x(p)` the risky-reserve schedule:
> `LVR rate ℓ(σ,p) = ½σ²p²|x'(p)|` and `marginal depth d(p) = |dx/d ln p|·p = p²|x'(p)|`.
> **These are the same quantity: `ℓ = ½σ²·d`, identically, for every invariant, at every price.**
> (Verified by recovering the textbook `σ²V/8` for constant-product from the depth side.)
>
> **Corollary: no static geometry can improve an LP's adverse selection per unit of depth offered.**
> A curve that halves LVR halves depth by the same factor. Concentrated liquidity, StableSwap,
> Orbital, weighted pools, Lambert — all move along the same line; none changes its slope.

QUEUE does not try. It **reallocates** adverse selection; it does not reduce it. Say so.

### ✖ Do NOT build off-chain components.

No server, relay, watch-tower, keeper service, scanner, sequencer, or hosted anything. Owner
constraint, and it is also correct: an off-chain component is a trust assumption that the whole
"unforgeable because it costs real money" story depends on not having.

Corollary: **no VRF, no oracle, no external data feed.** And note that on-chain randomness for
sandwich resistance is a dead end for a separate reason — *every input to a same-transaction draw is
known to the searcher who chooses when to submit.*

### ✖ Do NOT build a compliance gate, permissioned pool, or KYC hook.

The entire lane fails the delete test. `sender` is the router; `hookData` is caller-supplied; the
hook never sees the recipient. Any gate proves *"some allowlisted address appeared in the calldata"*,
not *"the recipient is allowlisted."* The three escapes are: be the periphery (kills aggregator
routing), an issuer signature per trade (a live off-chain censor on the swap path), or the token
enforces it itself (ERC-3643/1400 — which makes the hook redundant). Uniswap Labs shipped the first
and third and their hook is the redundant half.

### ✖ Do NOT build a margin engine, collateral system, or liquidation crank.

A prior candidate (`TENANT`) needed one and was killed for it: *"a margin engine with liquidations on
a volatile pair, shipped in eight weeks, under a hard robustness requirement, by a team that has
already found three unbounded-returndata bugs in its own code. The idea is good. The build is the
kind that produces a green suite and a drained contract."*

Harberger foreclosure (§B.10) is deliberately **not** this: no collateral, no oracle, no mark. If
your Phase 4 design starts growing a health factor, stop.

### ✖ Do NOT build a variance/volatility claim, an LVR index, or a perpetual on LP loss.

Occupied (`VFA Hook` UHI8 — **prized**; `Divergence Index & Swap` UHI9; `PegGuard` UHI9) **and**
economically broken: creating a tick move of `δ` costs fees roughly linear in `δ`, while a variance
payout is quadratic in `δ`. **For large enough `δ` the manipulator always wins.** An AMM is the
easiest place on earth to run that attack, because you manipulate the very index you are paid on
using the venue that publishes it. Score: 2.8. Do not build. Do not re-derive.

### ✖ Do NOT add an admin function, upgrade path, or privileged role without asking.

Not a style preference. A hook with an owner who can move funds is a hook nobody can trust, and the
whole pitch rests on the hook being the sole, unprivileged custodian.

---
---

# F. OPERATIONAL

## F.1 `PROGRESS.md` — the project's memory

`PROGRESS.md` already exists and has the shape below. **Update it at the end of every working
session.** This file is the memory; the conversation is not.

```markdown
# PROGRESS.md — the project's memory

## Status board
| Phase | Name | Status | Proven? |
|---|---|---|---|
| 0 | Harness + reproduce the reference spike | NOT STARTED / IN PROGRESS / **GATE GREEN** / BLOCKED | — |
...

## Carried forward — what is ALREADY PROVEN
(never delete a row; supersede it)

## Carried forward — what is OPEN

## Session log
### YYYY-MM-DD — one-line summary of what changed
- **Phase:** N — <name>
- **Status:** entered / exited / blocked
- **What was PROVEN:** claim, and the exact command + assertion that proves it
- **What FAILED, and what it taught:** including predictions that turned out wrong
- **Negative controls run:** which mutation, which reason string, red/green
- **Decisions taken under ambiguity:** the choice, the alternative, why
- **Numbers measured:** gas (with `vm.cool()`), residuals, seat counts — with the command
- **Open questions for the owner:** explicit asks
- **Next action:** one sentence, concrete enough to start on
```

**Rules:**
- **Newest entry first. Never delete an entry — supersede it.** A wrong belief that was corrected is
  more useful than a tidy history.
- **Record wrong predictions.** §D.11.
- **Distinguish PROVEN / MEASURED / REASONED / UNPROVEN** on every claim. Those words mean different
  things and the distinction is the point.
- **A phase is not "done", it is "gate green".** Say which gate and which command.

## F.2 Operational log format for a single experiment

When you run an experiment — a spike, a mutation, a measurement — log it in this shape inside the
session entry:

```
EXPERIMENT: <one line: what question does this answer?>
HYPOTHESIS: <what you predict, BEFORE running — including the exact revert reason if it is a control>
METHOD:     <exact command, exact fixture, exact price ratio, vm.cool() yes/no>
RESULT:     <raw output, numbers verbatim, not summarised>
VERDICT:    CONFIRMED / FALSIFIED / INCONCLUSIVE
IF FALSIFIED: <what you now believe, and the next experiment that could kill THAT>
```

The `HYPOTHESIS` line is not ceremony. In the original spike, writing it down is what revealed that
the author's model of his own mechanism was wrong — twice.

## F.3 Git and commits

- **Small, focused, honest.** State what was **proven**, not what was attempted.
- If a commit leaves something broken or unproven, **say so in the message.**
- Commit messages state the evidence: *"Allocator core: conservation exact to the wei at 1:4, 1:1000,
  1000:1; five controls red with asserted reasons. Protocol-fee path NOT yet handled — see PLAN §E.5."*
- **Branch, do not commit to `main`/`master` directly**, unless the owner says otherwise.
- Run `forge fmt` before committing.
- Do not commit `out/`, `cache/`, or `.forge-snapshots/` churn.
- **Do not bump `foundry.lock`.** Every number in this plan was measured against those revisions.

## F.4 Handoff

The next agent starts from `AGENTS.md` → `PLAN.md` → `PROGRESS.md`. **If those three do not tell them
what to do next, the handoff has failed.**

Before ending a session:
1. `PROGRESS.md` updated, with a concrete **Next action**.
2. `PLAN.md` updated wherever reality diverged (§F.5).
3. Working tree committed or explicitly described as dirty and why.
4. Any open question for the owner stated **as a question**, not buried in prose.

## F.5 This document is a living document

**When reality diverges from this plan, update this plan.** Specifically:

| Trigger | What to update |
|---|---|
| A measured number differs from one written here | The number, **and a note saying what it was and when it changed.** Never silently overwrite a measurement. |
| A phase's exit criteria turn out to be wrong or insufficient | The criteria, plus a line in `PROGRESS.md` saying why |
| A design decision in §B is superseded | §B, marked with the date and the reason |
| A new gotcha is found | §E, in the same style: what it is, what it cost, how to avoid it |
| A dangerous area is entered anyway and turns out fine | §E.19 — but be sure. These were closed for reasons. |

Mark superseded content rather than deleting it where the history is informative. A plan whose
history is legible is worth more than a plan that looks like it was right all along.

---
---

# G. PERSONA AND WORKING METHOD

## G.1 The mindset

> **Brutally honest. You are NOT here to validate the owner or yourself. A false "PASS" is worse than
> an honest "FAIL". Over-fitting and green-number-chasing are the #1 sin. When a test passes on the
> first run, that is a reason for suspicion, not satisfaction. When an assertion is aspirational,
> assert what is actually true and say what is not. If a direction is weak, say so plainly and
> challenge it.**

This is not decoration; it is the method that produced everything of value in this repo. Three
candidates were killed *before* production code was written rather than after. The one that survived
survived because someone tried hard to break it and wrote down the two things they got wrong.

**How to talk to the owner:** direct, not diplomatic. Concrete over elegant. **Volunteer
disagreement** — if a direction is weak, say so *before* doing the work, not after. The owner has
explicitly asked to be challenged.

**Report outcomes faithfully.** If tests fail, say so and show the output. If you skipped a step, say
so. If something is unproven, write **UNPROVEN** next to it. **Never describe a plan as a result.**

## G.2 PDCA — one thing at a time

**Plan → Do → Check → Act. One thing at a time. Start small. Validate the riskiest assumption BEFORE
building on it.**

That single rule is why this project has a working allocator instead of a half-built product on top
of an untested premise. The QUEUE spike existed *before* the QUEUE build precisely because the
allocator's exactness was the riskiest assumption, and it was cheap to test.

**Apply it at every phase.** Before each phase, ask: *what is the riskiest assumption this phase
stands on, and what is the cheapest experiment that could falsify it?* Run that first.

Current riskiest-assumption ranking, for what it is worth:

| Rank | Assumption | Status | Cheapest falsifier |
|---:|---|---|---|
| 1 | Front-first allocation at the realised price is exact | **PROVEN** | done — the spike |
| 2 | The queue's face value is redeemable | **FALSE as stated**; fixable | done — the residual measurement |
| 3 | Protocol fee does not break the ledger | **TESTED 2026-08-26 — HAZARD CONFIRMED** | ⚠️ **The instruction previously here was BLIND.** "Set a protocol fee, run the conservation test" goes GREEN while the position is short 0.354e18, because `protocolFeesAccrued` still sits in PoolManager's ERC20 balance. Assert against `PoolManager balance − protocolFeesAccrued`, or against `redeemAll()`. See §E.5 and `docs/research/protocol-fee/`. |
| 4 | Cursors can be maintained O(1) under bidirectional flow without leading | **UNPROVEN** | the N4 control (§D.3) |
| 5 | Rank transfers can be made safe without any price | **UNPROVEN** | the capital-evacuation controls (§D.5) |
| 6 | The O(1) prefix-sum redesign can be exactly conservative | **UNPROVEN, and doubted** (§B.11) | the differential test (§D.7 G7) |

## G.3 The review panel — apply at every gate

Before declaring a phase complete, walk the work past **each** of these deliberately. They catch
different things, and the point is that you must actually change seat, not nod at a list.

| Lens | The question it asks | What it catches here |
|---|---|---|
| **Exploit developer** | How would I steal from this? | Unguarded seat operations; the `transferFrom` override gap; reentrancy on the rent payout |
| **Economic incentives** | Is there a state where the behaviour we deter becomes the cheapest action? | **Free lanes. This failure has killed seven mechanisms in this project's history.** Dusting the head; rank-then-run; wash-trading the front |
| **Edge cases** | Zero, one, maximum, empty, exact boundary | Empty queue; single seat; a swap that exactly exhausts the queue; one wei more |
| **Devil's advocate** | What claim am I making that the tests do not actually support? | "Face value is redeemable"; "sweeps are O(1)"; any README verb like *prevents* or *guarantees* |
| **State transition** | What if this is interrupted, reentered, or called out of order? | Cursors after foreclosure; deposit interleaved with a swap; withdraw during a buyout |
| **Periphery** | Libraries and helpers are trusted implicitly | `Allocation.sol`; `SafeCast` usage; the ERC-6909 base; anything in `test/utils/` |

**How to actually use it** (rather than performing it): for each lens, write **one concrete sentence**
in `PROGRESS.md` naming what that lens found or explicitly confirming it found nothing. Six sentences
per gate. A lens that never finds anything across three gates is being run wrong.

## G.4 Two failure modes to watch in yourself

1. **The confident green result.** If everything passes on the first attempt, mutate the allocator
   and show the failure. If you cannot, you have not tested anything. (7 of 7, §D.1.)
2. **Silent scope drift.** It arrives as an admin function "for flexibility," or an off-chain helper
   "just for the demo." Both are forbidden (§E.19) and both **will** be proposed — often by you, to
   yourself, at the end of a long session.

---
---

# H. DEPLOYMENT RECOMMENDATION

## H.1 The rules

- **Testnet deployment is explicitly OPTIONAL.** The organizers' guidelines say so verbatim:
  *"Testnet deployment isn't mandatory"* — unit tests **or** a basic frontend suffice.
- **No mainnet. Owner constraint. Absolute.**
- Do **not** spend the last days on deployment at the cost of tests. Tests are a binary gate;
  deployment is not.

## H.2 The recommendation: **deploy to Unichain Sepolia (chainId 1301)**

**Do it, and do it at the start of Phase 7 rather than the end** — a deployed hook with a live demo
transaction is disproportionately convincing relative to its cost, and it de-risks the video.

**Why Unichain Sepolia specifically:**

1. **The Unichain prize track rewards "the best innovation of any kind"** — verbatim from the Request
   for Hooks. It is effectively an open track and the least theme-gated shot available. QUEUE's
   honest weakness is its bridge to the stated theme (§A.4); an open track is exactly where that
   costs the least.
2. **Gas is part of QUEUE's story, and Unichain is where the numbers look right.** The sweep is
   O(seats touched) at ~6,753 gas each. On a chain where that is fractions of a cent, a 32-seat
   roster is a design choice; on expensive L1 it reads as a limitation. Demonstrate where the
   mechanism actually makes sense.
3. **Canonical v4 deployments already exist there**, and the `hookmate` `AddressConstants` library in
   this repo already resolves them — so `Deployers.sol` works on a fork with no changes:

   | Contract | Unichain Sepolia (1301) |
   |---|---|
   | `PoolManager` | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
   | `PositionManager` | `0xf969Aee60879C54bAAed9F3eD26147Db216Fd664` |
   | `V4SwapRouter` | `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba` |

   > **Verify these against the live chain before relying on them.** They are hardcoded in a library
   > in `lib/`, pinned at a specific revision. A hardcoded address in a vendored dependency is
   > exactly the kind of thing that is silently stale. `cast code <addr> --rpc-url <unichain-sepolia>`
   > and confirm non-empty, then confirm behaviour with a fork test before deploying.

4. **Deploying to a testnet whose mainnet we would never touch keeps the no-mainnet constraint
   unambiguous.**

**Fallback: Ethereum Sepolia (11155111)**, also resolved by `AddressConstants`, if Unichain Sepolia's
RPC or faucet is unreliable on the day. Losing reason 2 above is a real cost, so try Unichain first.

## H.3 What to deploy

1. `QueueHook` at a CREATE2 address whose low 14 bits are `0x0840` (§B.2), mined with `HookMiner`
   (`lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol`).
2. Two test ERC-20s **at a non-unit price and ideally with different decimals** — the fixture rule
   applies to the demo too, and a 1:1 demo pool would be an embarrassing thing for a judge to notice.
3. Initialize the pool with the hook, seed the roster explicitly (§B.8), fund 3–5 seats.
4. Run the demo sequence on-chain and **keep the transaction hashes** — they go in the README:
   - a small swap → **the head seat fills, nobody else moves**
   - a sweeping swap → **the queue walks; seats exhaust in order**
   - a seat transfer → **the next swap's fills follow the new holder's rank**
   - (Phase 4) a buyout at the self-assessed price → **rank changes hands, capital does not**

**Verify the contracts on the block explorer.** It is five minutes and it is the difference between
"here is an address" and "here is the code, read it."

## H.4 What NOT to do

- Do not deploy to mainnet. Any mainnet.
- Do not build a frontend "just in case." Tests satisfy the gate. A half-built frontend is worse than
  none — it invites the judge to click something broken.
- Do not deploy before Phase 3's gate is green. A deployed hook with a wrong allocator is a liability,
  not an asset.
- Do not let deployment eat the video. The video is a **binary gate**; deployment is not.

---
---

# I. REFERENCES

All paths are relative to the repo root. Everything under `archive/2026-08-26/` is **history and
evidence** — read on demand, do not treat as instructions.

## I.1 Live documents (repo root)

| Path | What it contains | When to read |
|---|---|---|
| `AGENTS.md` / `CLAUDE.md` | How to work here: mindset, five testing laws, decision framework, hard rules, review lenses | **First, all of it.** |
| `PLAN.md` | This file | Second, all of it |
| `BUSINESS.md` | Why QUEUE exists, who buys and sells the seat, what to say about it | Before writing the README or video |
| `PROGRESS.md` | Status board, what is already proven, session log | Third, then every session |
| `PITFALLS.md` | **The standing hazard ledger.** v4 facts that bite · testing traps · settled decisions and the alternatives they killed · proven-impossible ideas · **§5 open hazards** · §6 hard rules · **§7 where the sources disagree** — every row graded PROVEN / MEASURED / REASONED / UNVERIFIED / OPINION | **Fourth, and re-read at the start of every session.** Before proposing anything, check it is not already settled or already known to bite |
| `docs/research/protocol-fee/` | The §E.5 experiment: `experiment.md` (executed, 7 tests + 3 mutations), `v4-mechanics.md`, `queue-exposure.md`, and `VERDICT.md` (**§5–§7 SUPERSEDED — banner in the file**) | Before Phase 1, and before touching anything fee-related |
| `docs/research/premise-review/` | `economics.md` + `fairness.md` — the premise review. ANALYSIS, nothing executed. The Fairness Theorem, the leverage identity, and the full-range capital-efficiency attack live here | Before the pitch, the README or the video; before proposing any "fairness mechanism" |
| `README.md` | Ships with the submission | Phase 7 |

## I.2 The essential archive — read these

| Path | What it contains | When to read |
|---|---|---|
| **`archive/2026-08-26/docs/research/IDEAS_OBJECTS.md`** | **§1 is QUEUE's full design** — the object, the thesis, who buys and who sells, the free-lane audit, the attack analysis, the prior-art counts, and an honest 4.33 score. **Plus the dated SPIKE section with all executed results.** | **Before Phase 1.** The single most important archived document. |
| **`archive/2026-08-26/test/spike/QueueAllocator.t.sol`** | **The reference implementation of the allocator**, 585 lines, 9 tests, three negative controls, the gas harness, the residual experiments. | **Phase 0, end to end.** Then again whenever you touch the allocator. |
| **`archive/2026-08-26/CLAUDE.md` §5** | **25 hard-won v4 facts.** Every one was paid for. Distilled into §E of this document, but the originals have context this summary does not. | When something in §E does not make sense, or before doing anything unusual with v4 |
| `archive/2026-08-26/docs/research/HACKATHON_CONTEXT.md` | The binary gates, the scored rubric, dates, sponsor tracks, the organizers' own framing of the theme, and what past winners actually looked like | Phase 7, and once at the start for the gates |

## I.3 The theorems that bound the design space

Read these when you are tempted to expand scope. Each closes a direction permanently.

| Path | The theorem | Read when |
|---|---|---|
| `archive/2026-08-26/docs/research/IDEAS_CURVES.md` §0 | **depth ≡ adverse selection.** `ℓ = ½σ²·d` identically, for every invariant, at every price. No static geometry improves LVR per unit of depth. | Anyone proposes a curve |
| `archive/2026-08-26/docs/research/IDEAS_CONSTRAINED.md` §1 | **No forgeable-proof flow signal exists** for a v4 hook. The table of every candidate signal and why each fails. | Anyone proposes detecting toxic flow |
| `archive/2026-08-26/docs/research/IDEAS_FROM_PERPLEXITY.md` §6 | **The four unforgeable currencies** (price path · time · liquidity · optionality) and the four proven evasions. | Evaluating any mechanism change |
| `archive/2026-08-26/CLAUDE.md` §5.17 | **The splitting lemma.** | Anyone proposes a size threshold |
| `archive/2026-08-26/CLAUDE.md` §5.16 / §5.18 | A hook can never see or pay the trader. | Anyone proposes touching the trader |

## I.4 Other executed spikes — evidence you can cite

| Path | What it proves |
|---|---|
| `archive/2026-08-26/test/spike/RouterCompatibility.t.sol` | `sender` is the router, not the trader (`test_Q3_senderIsTheRouterNotTheTrader`); `hookData` is empty through standard routers; a NoOp'd swap returning zero output **reverts** through `V4Router` with `V4TooLittleReceived` and through the hookmate router; output-skim router-cleanliness bounds |
| `archive/2026-08-26/test/spike/LedgerAddressShopping.t.sol` | A positive flash-accounting delta is relocatable to an arbitrary address for **52,700 gas** — the ledger theorem, which kills every identity/history-keyed mechanism |
| `archive/2026-08-26/test/spike/AssayReturnDeltaBlindSpot.t.sol` | Under `afterSwapReturnDelta`, a hook's `take()` debt nets to zero — measure the entry-to-exit *increase*, never the absolute |
| `archive/2026-08-26/test/spike/PredicateSandbox.t.sol` | Sandboxing untrusted calls: revert / OOG / mutation / reentrancy / returndata-bomb handling, and the bounded-copy pattern (§E.10) |
| `archive/2026-08-26/test/spike/CowNonSafeFork.t.sol` | A CoW fork experiment. **Requires `SEPOLIA_RPC_URL`; it is the one pre-existing red in the archived suite.** Do not be alarmed by it. |

## I.5 Templates you will want

| Path | For |
|---|---|
| `archive/2026-08-26/test/utils/BaseTest.sol`, `Deployers.sol` | **Required.** Copy in Phase 0 (§A.9). |
| `archive/2026-08-26/script/base/BaseScript.sol` | Phase 7 deploy scripting |
| `archive/2026-08-26/script/01_CreatePoolAndAddLiquidity.s.sol` | Pool creation + seeding |
| `archive/2026-08-26/script/03_Swap.s.sol` | Demo swaps |
| `archive/2026-08-26/test/HardcapInvariant.t.sol` | An existing invariant campaign in this repo — **useful as a shape**, and note it is from a dead candidate |
| `archive/2026-08-26/docs/VIDEO_SCRIPT.md` | A prior video script, for structure only. The content is about a different, dead project. |

## I.6 Context you probably do not need, but should know exists

`archive/2026-08-26/docs/research/` also holds: `WINNERS_LANDSCAPE.md` and `INCUMBENTS.md` (what past
cohorts built and what won), `SECURITY_LANDSCAPE.md` (why the security lane is 0-for-9),
`IDEAS_MECHANISM.md`, `IDEAS_INTEGRATION.md`, `IDEAS_LEDGER_FOLD.md`, `IDEAS_RWA.md`,
`RWA_PERMISSIONED_POOLS.md`, `IDEAS_FROM_GROK.md`, and `data/hook_directory_662.json` — the raw
662-row directory of every past UHI submission, which is what every prior-art count in this project
was computed from.

If you need to check whether an idea has been built before, **that JSON file is the answer**, and a
regex over it is the method. Print the regex next to the count, as every prior pass did.

---
---

## APPENDIX — the one-page version

**What:** a Uniswap v4 hook that replaces pro-rata fills with **price–time priority**. The hook is
the pool's sole LP; it holds an ordered roster of seats; every swap fills **front-first** at the
swap's own realised average price; the seat is an ERC-6909 token you can hold, transfer and price.

**Why it is new:** every concentrated AMM is a pro-rata market. Every real electronic market is
price–time priority. **Uniswap has never had a queue, so it has never had a price for one.**

**What is proven:** front-first allocation at the realised average price conserves both tokens
**exactly, to the wei, at a non-unit price**, measured on PoolManager's own balances, with three
mutations red.

**What is open:** a ~0.26 wei/swap redemption residual (fix specified, unbuilt); a ~44-seat gas
ceiling (bound the roster, pitch it as scarcity); rank-then-run (closed only by the Harberger
variant); the O(1) redesign (named, unbuilt, and **doubted**).

**What it is NOT:** it does not stop sandwiches, does not reduce total LVR, does not recapture value
from searchers, and does not detect toxic flow. It **prices** adverse selection and routes it to
whoever will bear it cheapest.

**The five rules:** never 1:1 · every claim needs a red control with an asserted reason · measure
conservation on PoolManager · `vm.cool()` for gas · **a first-run pass is a reason for suspicion.**

**The one rule above those:** *a false PASS is worse than an honest FAIL.*
