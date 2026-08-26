# RWA / Permissioned Pools — ground truth

**Researched 2026-08-26.** Every factual claim below traces to a URL fetched or a file read in this
session. Anything not verified is marked **UNVERIFIED**; anything reasoned is marked **INFERRED**.

---

## PROVENANCE

### Fetched successfully
| URL | What it gave |
|---|---|
| `https://blog.uniswap.org/introducing-permissioned-pools-on-uniswap-v4` | Announcement, **dated 2026-07-23**, launch partners |
| `http://developers.uniswap.org/llms.mdx/docs/protocols/v4-hooks/permissioned-pools/overview` | Component list |
| `http://developers.uniswap.org/llms.mdx/docs/protocols/v4-hooks/permissioned-pools/architecture` | Contract names, `SWAP_ALLOWED`/`LIQUIDITY_ALLOWED` values, adapter design |
| `http://developers.uniswap.org/llms.mdx/docs/protocols/v4-hooks/permissioned-pools/deploy-a-permissioned-pool` | **Deployed hook addresses**, "Uniswap deploys and maintains" |
| `raw.githubusercontent.com/Uniswap/v4-periphery/main/src/hooks/permissionedPools/*` | **Actual Solidity**: `IAllowlistChecker`, `PermissionFlags`, `PermissionsAdapter`, `BaseAllowListChecker`, factory, router, posm |
| `api.github.com/repos/Uniswap/v4-periphery/git/trees/main?recursive=1` | Full file tree; 3 audit PDFs |
| `api.github.com/repos/Uniswap/v4-hooks-public/git/trees/HEAD?recursive=1` | **`src/permissioned-pools/PermissionedHooks.sol`** and **`src/alf/DualPoolHook.sol`** |
| `raw.githubusercontent.com/Uniswap/v4-hooks-public/main/src/permissioned-pools/PermissionedHooks.sol` | Canonical hook source + trust-model NatSpec |
| `raw.githubusercontent.com/Uniswap/v4-hooks-public/main/docs/technical/DualPoolHook.md` | DualPool design |
| `raw.githubusercontent.com/Uniswap/v4-hooks-public/main/README.md` | Official hook list + deployments |
| `api.github.com/repos/Uniswap/v4-hooks-public/commits?path=...` | Commit dates |
| `https://ethereum-rpc.publicnode.com` (`eth_getCode`) | **6,909 bytes live** at the mainnet hook address |
| `docs/research/data/hook_directory_662.json` (local) | Saturation counts |
| `https://raw.githubusercontent.com/Uniswap/hooklist/main/hooklist.json` | 594 registered hooks; DualPool live entry |
| `eth_getLogs` on hook + factory, w/ PoolManager positive control (`eth.drpc.org`, `ethereum-rpc.publicnode.com`) | **Zero events ⇒ zero adapters ever created** |
| `blog.uniswap.org/unlocking-defi-liquidity-for-buidl` | 2026-02-11 UniswapX/BUIDL — the conflation trap |
| `/llms.mdx/docs/trading/swapping-api/swapping-permissioned-pools` | Swap routing |
| `docs/research/HACKATHON_CONTEXT.md` (local) | RfH + sponsor asks |
| **`api.fxtwitter.com/UniswapBuilders/status/2092330129766625410`** | **THE POST + full article text — the only channel that defeats X's block** |
| `api.vxtwitter.com/...` same | Corroborated title/date/preview independently |

### Failed / blocked
| URL | Result |
|---|---|
| `https://x.com/UniswapBuilders/status/20923301297666254` | **HTTP 402** — and the ID was truncated (17 digits) |
| `https://r.jina.ai/...` same | Cloudflare "Just a moment" JS challenge |
| `https://xcancel.com/...` | **Service shut down** — cease-and-desist from X Corp, 2026-08-24 |
| `https://nitter.net/...`, `nitter.poast.org` | Offline / empty |
| `http://archive.today/newest/https://x.com/...` | **"No results"** — genuinely queried, no snapshot exists |
| `http://archive.org/wayback/available?url=x.com/...` | `{"archived_snapshots": {}}` — no snapshot |
| `https://web.archive.org/web/2026/...` | HTTP 429 rate-limited |
| `api.github.com/search/code` | 401, requires auth; `gh` CLI not installed |
| `https://sourcify.dev/server/files/any/1/0x499a...` | Not found |
| `.../permissioned-pools/swapping` and `/swapping-through-permissioned-pools` | HTTP 404 — guessed slugs, page not located |

---

## TASK 1 — the X post: **READ IN FULL** (corrected URL, 2nd pass)

`https://x.com/UniswapBuilders/status/2092330129766625410` — the original brief's ID was truncated
to 17 digits. **Retrieved via `api.fxtwitter.com` / `api.vxtwitter.com`**, which return the tweet as
JSON and bypass the 402/Cloudflare wall. WebFetch, r.jina.ai, nitter, xcancel, archive.today and
Wayback all still failed on the corrected URL too — **fxtwitter is the channel that works; record it.**

- **Posted 2026-08-25 19:15:51 UTC** by `@UniswapBuilders` ("Uniswap Developers", 2,326 followers).
  **Owner's date recollection was exactly right.**
- The tweet body is only a link to an **X long-form article**, id `2092327952029802496`, titled
  **"How Permissioned Pools Work on Uniswap v4"**. Full text recovered from the article `content.blocks`.
- Engagement: **10,275 views, 139 likes, 21 RTs, 16 replies.** Modest — an explainer, ~a month after
  the 2026-07-23 launch. **It is not a new announcement and there is no new primitive in it.**

### What it actually says — and it is an *explainer of the July launch*, nothing more

It confirms, in Uniswap's own words, every item I had already verified from source:
- *"the permissioned asset never enters the pool… the pool trades against a virtual representation"*
- *"only the PoolManager is allowed to hold these virtual tokens"* (= the `assert` in `_update`)
- **"The two permissions are separate flags. A wallet cleared to swap isn't automatically cleared to
  LP."** — **the owner was right about `SWAP_ALLOWED` / `LIQUIDITY_ALLOWED`.**
- Pluggable checker, standard-agnostic: *"Securitize's DS Protocol, Tokeny's ERC3643, or a custom
  registry… The pool never needs to know how the list is built. It only needs the verdict."*
- `unwindPosition` force-close; non-transferable LP NFTs; issuer power bounded to their own asset.
- *"live on Ethereum mainnet and Sepolia today"*; Superstate, Securitize, Dowgo *"already building"*.

### ⚠ THE PARAGRAPH THAT MATTERS MOST TO US

Uniswap's stated *motivating problem* is *our* ERC-6909 finding, published by them:

> *"a pool doesn't move tokens the way wallets do. In Uniswap v4, all balances live in one central
> contract, the PoolManager. Ownership moves around inside it as **virtual ERC6909 balances**, and LP
> positions are NFTs. **None of that triggers the token's transfer checks**, so a permissioned token
> could pass through a wallet that was never approved, and the pool would have no way to know."*

Two consequences, both material:

1. **This is §5.16 stated by Uniswap Labs.** And note where they put the recipient check — not in the
   hook: *"The Permissions Adapter automatically converts them back… sending the physical, compliant
   tokens to the recipient; **only after verifying their compliance status**."* **The recipient
   binding lives at the adapter/token layer. The hook only gates the swapper.** Exactly as §5.16
   predicts, from the vendor's own explainer.
2. **⚠ This partially pre-empts our planned ERC-6909 laundering publication.** §8 records that "1 of
   662 projects has ever noticed it" and recommends publishing. **Uniswap Labs has now described the
   ERC-6909-bypasses-transfer-hooks mechanism in a public post read 10k times.** Our finding is still
   distinct — ours is *delta laundering between addresses inside one unlock to defeat measurement*,
   theirs is *6909 balances bypass a token's own transfer restrictions* — but **the novelty claim must
   be narrowed and this post cited, or a reviewer will call it known art.**

## TASK 2 — what actually exists

### Summary table

| Named thing | Status | Where |
|---|---|---|
| **Permissioned Pools** | **SHIPPED.** Announced 2026-07-23, code merged to `main`, deployed on mainnet + Sepolia, **3 audits** | `v4-periphery`, `v4-hooks-public` |
| **`IAllowlistChecker`** | **EXISTS**, exactly as named | `v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol` |
| **`SWAP_ALLOWED` / `LIQUIDITY_ALLOWED`** | **EXIST**, owner was right | `.../libraries/PermissionFlags.sol` |
| **"adapters"** | **EXISTS** — `PermissionsAdapter` | `.../PermissionsAdapter.sol` |
| **`PermissionedHooks`** (canonical hook) | **EXISTS + DEPLOYED**, but in a *different repo* than the rest | `v4-hooks-public/src/permissioned-pools/` |
| **DualPool** | **EXISTS** — but it is **not** what the owner described. See below. | `v4-hooks-public/src/alf/DualPoolHook.sol` |

### The real interface — verbatim from source, not paraphrase

```solidity
// v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol
interface IAllowlistChecker is IERC165 {
    /// @notice Returns the permission flags for `account` with respect to `tokenAddress`
    function checkAllowlist(address account, address tokenAddress) external view returns (PermissionFlag);
}
```

```solidity
// .../libraries/PermissionFlags.sol
type PermissionFlag is bytes2;   // with global |, &, == operators

library PermissionFlags {
    PermissionFlag constant NONE              = PermissionFlag.wrap(0x0000);
    PermissionFlag constant SWAP_ALLOWED      = PermissionFlag.wrap(0x0001);
    PermissionFlag constant LIQUIDITY_ALLOWED = PermissionFlag.wrap(0x0002);
    PermissionFlag constant ALL_ALLOWED       = PermissionFlag.wrap(0xFFFF);
}
```

**The owner was correct on both flags, including that they are separate.** Note `PermissionFlag` is
a `bytes2` user-defined value type, not an enum — a checker returns a *bitmask*, so an account can
be cleared to provide liquidity but not to swap, or vice versa. `BaseAllowlistChecker` is an
`abstract` contract with one `virtual` function; issuers implement their own.

The flag test is an **exact-subset** test, not "any bit set":
```solidity
// PermissionsAdapter.sol:82
function isAllowed(address account, PermissionFlag permission) public view returns (bool) {
    return ((allowListChecker.checkAllowlist(account, address(PERMISSIONED_TOKEN))) & (permission)) == (permission);
}
```

### Who calls it, and when

`PermissionedHooks` (canonical, deployed) declares **exactly four** callbacks. This is provable from
the address alone with zero calls — per this repo's own §5 property:

```
mainnet 0x499a724Ab630549f14C995EC41a8E04fA3fd28c0  low14 = 0x28C0
sepolia 0x51247E2291d290d17C08813A175AC86465EdE8c0  low14 = 0x28C0
  -> BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP
```
Both addresses mine to the **same** low 14 bits, matching the four documented callbacks exactly.
`eth_getCode` on the mainnet address returns **6,909 bytes** — it is live, not vapour.

- `beforeInitialize` — refuses a pool unless at least one currency is a **factory-verified** adapter.
- `beforeSwap` — requires `SWAP_ALLOWED` **and** `adapter.swappingEnabled()`.
- `beforeAddLiquidity` — requires `LIQUIDITY_ALLOWED`.
- `afterSwap` — emits a `Swap` event mirroring `IV4Router.Swap` for indexers. **No delta returned.**

⚠ **The trust model is explicit and is the soft spot.** From `PermissionedHooks`' own NatSpec:

> `/// @dev Trusts wrapper-reported msgSender(); wrappers must be registered in adapter allowedWrappers.`

The hook receives the *router* as `sender` and calls `IMsgSender(sender).msgSender()` to learn the
real trader. **The router is trusted to report truthfully**, and that trust is bounded only by the
issuer's `allowedWrappers` whitelist. This is the same "we read the address we happened to be
holding" shape as this repo's audit finding A-1 and §5.12 — Uniswap resolved it by *whitelisting the
reporter* rather than by deriving the address trustlessly.

### The architecture — "if the token never enters PoolManager, what does the pool trade?"

Answered definitively from `PermissionsAdapter.sol`. **The adapter *is* the ERC-20 the pool trades.**

- `contract PermissionsAdapter is ERC20, Ownable2Step` — it holds the real restricted security in
  `PERMISSIONED_TOKEN` and is itself the "virtual" token. Name/symbol are derived: `"Uniswap v4 " +
  name`, `"v4" + symbol`.
- `wrapToPoolManager(uint256)` — callable **only by an `allowedWrapper`** — mints virtual tokens
  **directly to `POOL_MANAGER`**.
- The `_update` override enforces the load-bearing invariant:
  ```solidity
  assert(balanceOf(POOL_MANAGER) == totalSupply());
  ```
  **PoolManager is the only address that may ever hold the virtual token.** Any transfer *out* of
  PoolManager immediately `_unwrap`s — burn the virtual, `safeTransfer` the real token to the
  recipient. Any transfer not originating from PoolManager reverts `InvalidTransfer`.

So: the pool trades a 1:1 virtual ERC-20 that exists only inside PoolManager, and every `take()`
atomically converts it back to the restricted security — at which point the underlying token's own
transfer restrictions are the final backstop.

**Why they did this** (per the architecture doc): keeping the restricted token out of PoolManager
prevents (1) allowlist bypass via the shared PoolManager balance, and (2) **unauthorized ERC-6909
claim trading**. That is the *same* ERC-6909 hazard this repo documented in §8's delta-laundering
finding — Uniswap engineered around it at the token layer.

⚠ Note honestly: the ERC-6909 escape is **acknowledged, not fully eliminated.** From
`PermissionsAdapter.renounceOwnership()`'s own NatSpec: *"every failed unwind instead mints a freely
transferable ERC-6909 claim on this adapter to the exited LP."* Hence `renounceOwnership` is
disabled outright — the issuer's force-exit path must never become unreachable.

### ⚠ THIS INDEPENDENTLY CONFIRMS CLAUDE.md §5.16 — from primary source

§5.16 states that a v4 hook **cannot** bind an allowlist to the party that receives the tokens, and
names exactly three escapes: (1) *be the periphery* (kills aggregator routing), (2) an issuer
signature per trade, (3) *the token enforces it itself (ERC-3643/1400) — which makes the hook
redundant.*

**Uniswap Labs hit the same wall and took escapes (1) and (3) — both of them, together.** This is
the strongest available confirmation of §5.16: the protocol's own team, with three audits and a
dedicated router fork, could not make a hook-only allowlist work either.

- **Escape (1), be the periphery.** `PermissionedHooks` cannot trust `sender`, so it calls
  `IMsgSender(sender).msgSender()` and the adapter gates *which routers may say it* via
  `allowedWrappers`. Its own NatSpec concedes the residual trust: *"Trusts wrapper-reported
  `msgSender()`."* They shipped a **forked router** (`PermissionedV4Router`) and a **forked position
  manager** to make this hold. **This does kill open aggregator routing** — only whitelisted wrappers
  can move the asset, exactly as §5.16 predicts.
- **Escape (3), the token enforces it.** The final backstop is not the hook at all. `_update` forces
  every exit from PoolManager through `_unwrap` → `safeTransfer` of the *real* permissioned token,
  and that token's own transfer restrictions decide whether the recipient may receive it.

So the honest framing of Uniswap's own product: **the hook is not the compliance boundary.** The
hook is a UX-and-indexing convenience that fails bad swaps early and emits a `Swap` event; the actual
enforcement lives in the adapter's transfer invariant plus the underlying restricted token. That is
precisely §5.16's conclusion — *"which makes the hook redundant"* — reached independently by Uniswap.

**Consequence for us, and it is a sharp one:** §5.16 says the hook-based compliance-gate lane fails
the delete test. My reading of the shipped code says the same, and adds that **Uniswap has already
built the non-hook parts that are actually load-bearing.** Any submission of ours in this lane would
be re-shipping the redundant half. **The §5.16 write-up is strengthened, not threatened, by this
research, and the "Publish this" instruction now has a primary-source exhibit: Uniswap's own
permissioned pools take two of the three escapes because the hook alone cannot do it.**

### Supporting contracts

| Contract | Role |
|---|---|
| `PermissionsAdapterFactory` | Deploys adapters; `verifyPermissionsAdapter()` proves the adapter holds a real balance of the token (issuer seeds ≥1 wei, which itself proves the issuer allowlisted the adapter). **Factory verification ≠ the ERC-165 check** — ERC-165 only proves a checker implements the interface. |
| `PermissionedPositionManager` | Extends `PositionManager`; positions are **non-transferable NFTs**; adds `unwindPosition()` so the issuer can force-exit an LP. |
| `PermissionedV4Router` | Universal Router ≥ 2.2.0. Wraps/unwraps around the swap. |
| `BaseAllowlistChecker` | 13-line abstract base; issuers write their own checker. |

### ⚠ THE FINDING THAT MATTERS MOST FOR OUR SEVEN IDEAS

**A v4 pool has exactly one hook slot, and on a permissioned pool that slot is occupied by Uniswap's
canonical `PermissionedHooks`.** You cannot add a second hook to a pool.

But it is **not hard-locked**. The adapter carries `mapping(IHooks hook => bool) public allowedHooks`,
and it is enforced in two places (verified by grep across the whole module):

```
PermissionedV4Router.sol:41        if (!IPermissionsAdapter(...).allowedHooks(hooks)) revert HookNotAllowed();
PermissionedPositionManager.sol:210 return IPermissionsAdapter(...).allowedHooks(hooks);
```

So the real constraint is:

> **A custom hook CAN serve a permissioned pool — but only if the token's issuer explicitly calls
> `updateAllowedHook(ourHook, true)`. And there is no base contract to inherit: `PermissionedHooks`
> is a concrete `contract`, not `abstract`, and lives in a different repo. Any custom hook must
> re-implement the entire allowlist enforcement itself, correctly, or it silently becomes the
> compliance hole.**

Two consequences, and they point opposite ways:

1. **Demo is feasible.** In a hackathon we deploy our own adapter, so we are the "issuer" and can
   whitelist our own hook. Nothing blocks a working demo.
2. **Production adoption is gated on a business relationship**, not on code quality. Adoption
   requires Superstate/Securitize/Dowgo to whitelist us. That maps directly onto the owner's
   "adoption" scoring axis and it scores **badly** — worse than any hook that anyone can just deploy.

**INFERRED but high-confidence:** the genuine unoccupied gap here is an *`abstract BasePermissionedHook`*
that composes allowlist enforcement with custom logic — the OZ-style base contract that does not
exist. That is a **library**, and this repo has already established (§8, 2026-08-26) that
library/infrastructure submissions do not win this hackathon: 0 for 9 on hook-safety infrastructure.
It fails the same test.

### DualPool — the owner is **half right**, and the half that is wrong matters

**`DualPoolHook` is REAL.** `Uniswap/v4-hooks-public/src/alf/DualPoolHook.sol`, ported from
`v4-hooks-internal` on **2026-07-18/21**, audited by OpenZeppelin
(`docs/audit/openzeppelin-dualpool.pdf`). It has ~12 test files including `DualPoolInvariant.t.sol`.

**But it is not "Uniswap shipped idle yield [for LPs]".** From its own technical doc:

> *"`DualPoolHook` is the ALF reference strategy for a **market maker** that wants Uniswap v4
> execution while keeping idle inventory productive between swaps."*

It is a **market-maker** strategy hook in Uniswap's "ALF" (Active Liquidity Framework) family:
JIT liquidity (positions exist **only during a swap**; ordinary pool liquidity is **zero between
swaps**), multi-range distribution, and **ERC-4626 rehypothecation** of idle balances. Routers must
discover capacity through `IALFHook` views, not through PoolManager liquidity.

**It IS live on Ethereum mainnet.** Found in Uniswap's own hook registry (`Uniswap/hooklist`,
pushed 2026-08-25) and confirmed on-chain:

```
DualPoolHook  0x00000078bd49d5279a99b5f4011a5c61ee8caac0  (ethereum, verifiedSource: true)
eth_getCode -> 23,999 bytes
low14 = 0x2AC0 -> BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP
```
Registry description confirms the design: *"JIT hook that deploys concentrated LP positions across
multiple owner-configured tick-range buckets immediately before each swap and removes them
afterward. Integrates ERC4626 vaults for idle-capital rehypothecation between swaps."*

Honest status qualifiers that still stand:
- **NOT listed in the repo README's hook list** (which names only WETHHook, WstETHHook, WstETHRoutingHook).
- **No deployment address in the README's Deployments section** (WETH/WstETH have them) — it is
  registered in `hooklist` but not yet documented as an official release.
- Two siblings were **withdrawn** on 2026-07-27 (`chore(alf): withdraw DualPoolStableHook and DualPoolIncentivizedHook`).
- **TVL is negligible: ~$411 total across four dust instances**, against Spark's $150M sitting in
  plain v4. Deployed and audited, but effectively unused.

⚠ **Rehypothecation is not novel and is not Uniswap-exclusive** — OpenZeppelin's `uniswap-hooks`
library already ships a `ReHypothecation` hook (recorded in this repo's §8). "Idle LP capital into
a vault" also already appears in the hook directory (e.g. UHI8 `ForgeX: Vult`). **Do not build on
the premise that this is fresh ground.**

### ⚠ CORRECTION TO A RECORDED HARD-WON FACT (§5.14)

§5.14 says *"Never cite 'Uniswap uses invariant testing'… v4-periphery has one invariant test, on a
hookless pool."* That was researched before `v4-hooks-public` was examined. **`v4-hooks-public`
contains `test/alf/DualPoolInvariant.t.sol` with a `DualPoolHandler`, plus `AlfAuditRegression.t.sol`.**
Uniswap Labs *does* run stateful invariant campaigns **on its own hooks**.

This does **not** revive the security route — the invariants are still *off-chain, pre-deployment
Foundry tests*, exactly the form §8's SECURITY_LANDSCAPE concluded Uniswap prefers, and the
conclusion there is strengthened, not weakened. But the specific sentence "Uniswap ships almost no
invariant testing" is now **too strong and should be narrowed** to "…in v4-core and v4-periphery".

---

## TASK 4 — saturation

Measured against `docs/research/data/hook_directory_662.json` (662 projects, UHI1–UHI9 + 1 UHI10).
The prior figure in our notes was "72 submissions, 16 prized". Re-measured with two **separate**
tight patterns, because the interesting question is whether RWA is distinct from generic KYC:

| Lane | Submissions | Prized | Hit rate |
|---|---|---|---|
| Compliance / KYC / allowlist / identity gating | **68** | 14 | 21% |
| RWA / tokenized securities specifically | **60** | 8 | 13% |
| **Both** (compliance-gated RWA — the permissioned-pools shape) | **26** | **1** | **3.8%** |
| **Union** | **102** | 21 | 21% |

**Baseline, measured not assumed: 148 of 662 projects carry some prize = 22.4%.** So the union lane
(21%) performs at *exactly the base rate* — being in this lane has historically conferred no
advantage whatsoever. And the specific intersection that "permissioned pools" occupies performs at
**3.8%, roughly six times worse than base.**

**The single most decisive number in this report: of the 26 projects that are compliance-gated RWA
— the exact shape of a permissioned pool — exactly ONE was prized.** That one is UHI8's *Veritas
Protocol: The IP-Fi Settlement Layer* (Reactive Network + Uniswap prizes), and it won as **on-chain
IP monetization infrastructure**, not for compliance gating.

I eyeballed all 26 by hand to confirm the pattern is not vacuous; they are genuinely the right
shape — `RWAComplyHook`, `The Citadel Hook`, `Vaultex`, `RWAMarket Hook`, `Rayls Compliance &
Privacy`, `Zama Compliance hook`, `ZK Proof-of-Compliance Hook`, `Regulated DEX Hook`,
`Tick Range and Allowlist hooks`, `DCLEX Hook`. **Twenty-five of those twenty-six won nothing.**

*(Method note: a nonsense-pattern negative control returned 0 hits, and the base rate was measured
rather than assumed. An earlier draft of this file misattributed the single prized entry to UHI2's
`Uniq`; the hand-check caught it. `Uniq` is RWA-tagged but not compliance-gated, so it is in the
union, not the intersection.)*

Prized projects across the union, with what they actually won for:

| Cohort | Project | Prize | Won for |
|---|---|---|---|
| UHI1 | Vortex Protocol | Uniswap | — |
| UHI2 | Uniq (RWA + dynamic fees) | Chainlink, Brevis | **dynamic fees**, not compliance |
| UHI2 | KYC Hook | Brevis | ZK/proof integration |
| UHI2 | Reputation Hook – MetaPools | Chainlink, Brevis | oracle/proof integration |
| UHI2 | Multihook | Uniswap | hook composition |
| UHI3 | RwAsync swap | EigenLayer | **AVS integration** |
| UHI3 | UniGuard | EigenLayer | **AVS integration** (already noted in §8) |
| UHI5 | OriginateX + Passthru | Uniswap | mortgage origination/MBS |
| UHI5 | YOLO Protocol | Uniswap, Circle, Ink, Across | CDP/synthetics engine |
| UHI5 | kvhook | Ink | — |
| UHI5 | TermStructure AMM | Uniswap, Circle | **new curve / term structure** |
| UHI6 | Confidential IL Insurance | Uniswap | confidentiality |
| UHI7 | modl | Uniswap | — |
| UHI7 | Bastion | EigenLayer | **AVS**, depeg protection |
| UHI8 | Veritas Protocol (IP-Fi) | Reactive, Uniswap | IP monetization |
| UHI8 | Voltaire | Uniswap | — |
| UHI8 | Veritas (provenance IL) | Reactive, Uniswap | IL protection |
| UHI8 | DobDex | Unichain | RWA exit liquidity |
| UHI8 | 1Tx | Uniswap | yield abstraction |
| UHI8 | Satisfy | Unichain | — |
| UHI9 | TokenLaunchHook Studio | General | — |

**The pattern is the same one §8 already found for security:** nothing in this directory ever won
*for the compliance gating itself*. Projects won for an adjacent mechanism — a curve, a fee model, an
AVS, a proof system — that happened to sit in an RWA-shaped wrapper.

**Cohort distribution of the union:** UHI8 = **32** of 102, three times any other cohort
(UHI2 11, UHI6 11, UHI7 11, UHI3 10, UHI5 9, UHI9 9, UHI4 7, UHI1 2). UHI8 evidently ran a
"specialized markets" theme — several project names literally end in *"for Specialized Markets"*.
**The lane has already been an explicit hackathon theme once, and it produced 32 entries.**

Then note the fall-off: **UHI9 dropped back to 9.** Interest declined after the themed cohort.

### Are any permissioned pools actually LIVE? **No evidence found.**

`Uniswap/hooklist` (594 registered hooks, Uniswap's own registry, pushed 2026-08-25) does **not**
contain the canonical `PermissionedHooks` address `0x499a…28c0` — zero matches. So the hook is
deployed (6,909 bytes on mainnet) but is **not registered in Uniswap's own hook directory**, and I
found **no live permissioned pool, no issuer deployment, and no TVL**. Nor does the registry mention
Superstate, Securitize, or Dowgo (0 matches each).

**INFERRED:** permissioned pools are shipped-and-deployed but not yet meaningfully *used*. Treat any
claim of live institutional volume as **UNVERIFIED**.

One relevant third-party datapoint: `V4PermissionedSwaps` on BNB
(`0x38358b924cb329dc428650f91309dfbddf974080`) — *"restricts swaps to an owner-managed allowlist of
approved sender addresses"*. The naive allowlist hook already exists in the wild, independently of
Uniswap's standard.

### Has anyone in the hackathon used the new primitive? **No.**

Grep of all 662 project records:
```
'permissions adapter'  : 0        'superstate' : 0
'permissionsadapter'   : 0        'securitize' : 0
'virtual token'        : 0        'dowgo'      : 0
'permissioned pool'    : 1  (UHI5 LiquiDAO)   'ondo' : 0     'buidl' : 0
'6909'                 : 3  (UHI8 Argos LTS, UHI8 EvenFlow, UHI2 DCLEX Hook)
```
**Expected and not meaningful as white space** — the directory predates the 2026-07-23 launch. It
tells us only that the count is genuinely zero-from-a-standing-start, not that the idea is unexplored.

Worth one line: **UHI2's `DCLEX Hook` is described as *"A KYC Hook that can't be bypassed by using
ERC-6909 claim tokens"*** — a hackathon project identified the exact ERC-6909 bypass in 2024 that
Uniswap's 2026 adapter architecture is built to prevent. The hazard was known in the lane years ago.

---

## TASK 3 — ecosystem and sponsor demand

### Sponsor demand is REAL, and this is the strongest argument FOR the lane

Source: `docs/research/HACKATHON_CONTEXT.md` (our own prior primary-source pass on the Atrium
Request for Hooks). **I was wrong to treat this lane as purely off-theme; the RfH names it.**

- **The Atrium Request for Hooks list includes "Permissioned Pool Hook" outright** — it is a
  called-for hook type, not something we would be inventing against the grain.
- **Ink (sponsor) explicitly asks for "Permissioned Pools via Kraken Verify."** This is the single
  most concrete demand signal found anywhere in this research: a named sponsor, a named prize track,
  asking for exactly this category.
- **Circle (sponsor)** ships a **Compliance Engine** and asks for **"compliance-aware swap limits."**
  Circle is also RWA-adjacent via USYC. **UNVERIFIED:** the USYC/Hashnote acquisition detail — I did
  not confirm it in this pass.
- **Reactive Network (sponsor)** lists "permissioned pools" among its suggested pairings.
- **UHI8's theme was "Specialized Markets," with "Hook Templates (RWA/stable/long-tail)"** named
  explicitly — which independently explains the 32-entry UHI8 spike measured in Task 4.

**How to weigh this honestly.** It cuts against a flat "crowded lane, don't go" verdict — there are
three sponsor tracks whose stated asks this would satisfy. But it does **not** rehabilitate the lane
for the *main* prize, and it is consistent with the Task 4 pattern rather than contradicting it:
projects in this lane won **sponsor** prizes (Brevis, Chainlink, EigenLayer, Ink) for the *integration*
they carried, essentially never for the gating itself. Note also that Ink's ask is *"via Kraken
Verify"* — an **identity/attestation provider**, which is a different axis from Uniswap's new adapter
standard and would not be satisfied by adopting `PermissionsAdapter`.

### Counterparties — **ZERO ADOPTION, PROVEN ON-CHAIN**

Launch partners named in Uniswap's own announcement: **Superstate, Securitize, Dowgo.** Ondo /
BlackRock BUIDL / Franklin Templeton BENJI are RWA-adjacent but **are NOT named by Uniswap** — do
not claim they are.

**THE DECISIVE FACT, and it is on-chain rather than documentary.** Published addresses (they exist,
inside the *deploy guide*, not a deployments page — Ethereum + Sepolia only, no Base, no Unichain):

```
PermissionedHooks         0x499a724Ab630549f14C995EC41a8E04fA3fd28c0   (deployed ~2026-08-11)
PermissionsAdapterFactory 0x7DA911490Ca4663E572eA9C8154f3CdEbCE16452
```
Both carry real bytecode. **`eth_getLogs` over both contracts' entire lifetime returns ZERO events**
— with a **positive control** (v4 PoolManager, 5,437 logs in a 256-block window) proving the method
works and the zero is genuine, not a broken query.

> **Zero factory logs ⇒ zero `PermissionsAdapter`s have ever been created ⇒ no permissioned pool can
> exist on mainnet.** The standard is shipped, audited, deployed — and **completely unused ~34 days
> after announcement.** Note also the hook was deployed **2026-08-11, 19 days *after* the blog post.**

| Party | First-party v4 announcement | Live | Named by Uniswap |
|---|---|---|---|
| Superstate | X post only (2026-07-23); newsroom JS-rendered — **UNVERIFIED**, not proven absent | No | Yes — "early design partner" |
| Securitize | Only for the 2026-02-11 UniswapX/BUIDL deal, **not v4** | No | Yes — DS Protocol |
| Dowgo | None found | No — **blocked on regulator** | Yes — ERC-3643, **future-tense** |
| Ondo | **None** (only 2021–22 Fei/FRAX) | No | **No** |
| BlackRock BUIDL | None for v4 | No | **No** |
| Franklin Templeton | **None** | No | **No** |

**⚠ CONFLATION TRAP — do not fall into it, and challenge anyone who does.** There *is* a real
Uniswap×BUIDL announcement: `blog.uniswap.org/unlocking-defi-liquidity-for-buidl`, **2026-02-11** —
five months *before* permissioned pools. It is **UniswapX: off-chain RFQ/intents with whitelisted
subscribers** (Flowdesk, Tokka Labs, Wintermute). **No pool, no hook, no v4 contract.** Citing BUIDL
as evidence of v4 permissioned-pool traction is **wrong product, wrong rail, wrong date.** Uniswap's
own v4 post never mentions BUIDL, BlackRock, or Ondo.

**Residual caveat, stated plainly:** the absence of first-party posts for Superstate / Securitize-v4 /
Dowgo / Franklin rests on site-restricted search plus JS-blocked page bodies. **The on-chain
conclusion does not depend on it.**

**Corollary for DualPool:** it is live but holds **~$411 total across four dust instances**, while
Spark's $150M sits in plain v4. Announced, audited, deployed — and effectively unused too.

**No RWA/tokenized-securities issuer is a UHI10 sponsor.** The verified 13-value prize list is
Uniswap · General · Unichain · EigenLayer · Brevis · Reactive Network · Fhenix · Flaunch · Arbitrum ·
Chainlink · Circle · Across · Ink. Circle is the only RWA-adjacent entry.

---

## HONEST READ

**Is "permissioned pools" newly interesting because Uniswap shipped a primitive, or an old crowded
lane wearing a new name?**

**Predominantly the second, with one narrow genuine opening.**

Arguments that it is genuinely new:
- The primitive is **real, shipped, deployed, and 3× audited** (Cantina + two OpenZeppelin reports).
  This is not a proposal. It landed 2026-07-23 and Uniswap Labs maintains it.
- **Zero of 662 prior projects used it**, because it did not exist.
- It is strategically prominent for Uniswap — real launch partners, a real institutional push.
- **Sponsor demand is real and named** (Task 3): the RfH lists "Permissioned Pool Hook", **Ink asks
  for permissioned pools outright**, Circle asks for compliance-aware swap limits. This is a genuine
  correction to my first-pass framing and I flag it as the strongest pro-lane argument.

Arguments that it is a crowded lane rebranded — and I judge these to dominate:
- **102 prior submissions in the union lane, prized at 21% against a 22.4% base rate — i.e. zero
  historical edge. 26 sit in the exact compliance-gated-RWA shape, and exactly one of those 26 was
  prized (3.8%, ~6× worse than base), for IP monetization rather than for compliance.**
- UHI8 already ran this as a theme and drew 32 entries; UHI9 fell back to 9.
- **The hook slot is already occupied by Uniswap Labs' own canonical, audited, deployed hook.**
  This is §5.13 again, in the sharpest possible form — and it is *worse* than "0 matches means the
  road was deliberately not built". Here **Uniswap built the road, paved it, audited it three times,
  and is driving on it.** A judge's one-liner writes itself: *"Uniswap Labs already deployed and
  maintains `PermissionedHooks` at `0x499a…28c0`. What is yours for?"*
- Replacing that hook means **re-implementing compliance enforcement yourself** and persuading an
  issuer to whitelist you — strictly worse on adoption than a hook anyone can deploy, and it puts us
  in the position of shipping an *unaudited* substitute for an audited compliance control.
- The theme is **"Sustainable Liquidity and MEV Protection."** Permissioned pools are neither. This
  would be an off-theme bet whose off-theme category is **infrastructure/compliance** — and §8
  already established that off-theme *new math* has won (Orbital) while off-theme *infrastructure*
  has not.

**Where the one real opening is.** Not in the gating. In what a permissioned pool *does not yet
have*: these pools have a **known, allowlisted, non-anonymous participant set**, which is precisely
the "party that agreed in advance to be inspected" of §8's **case (c) of the ledger theorem**. Every
MEV/toxic-flow mechanism this repo has evaluated died on *"the adversary chooses which address faces
your hook"* — address-shopping for 52,700 gas. **On a permissioned pool, address-shopping requires
the issuer to allowlist the new address.** That is the first environment we have found where
identity is enforced by someone other than us, for free.

**But be brutal about the cost of that opening:** it is only reachable by *replacing* Uniswap's
audited hook with our own, it inherits the issuer-whitelist adoption gate, and any demo runs against
an adapter we deployed ourselves — i.e. **straw men we wrote**, which is the exact failure mode
§9's standing order forbids. Superstate/Securitize will not whitelist a hackathon hook in eight weeks.

**Bottom line — do not build the gating.**

**The single hardest fact in this report: `eth_getLogs` on `PermissionsAdapterFactory` returns zero
events for its entire lifetime, with a positive control. Not one adapter has ever been created. No
permissioned pool exists on mainnet, 34 days after launch.** Whatever else is arguable, "Uniswap is
actively promoting this and there is momentum to ride" is not supported by the chain.

The decisive *design* argument is **§5.16 plus the shipped code**. A hook cannot bind an
allowlist to the recipient, Uniswap hit that same wall, and they escaped it by *forking the router*
and *leaning on the token's own transfer restrictions* — **neither of which is a hook.** Their own
hook is a fail-fast-and-emit-events convenience. Anything we build in this lane re-ships the
redundant half, against an audited, deployed incumbent at a known address, and its adoption is gated
on an issuer whitelisting us. It fails the delete test for the same reason all 26 predecessors did.

The sponsor demand (Ink, Circle, Reactive) is real and is the honest counterweight — but it points at
a **sponsor** prize, historically won for the *integration carried* rather than the gating, and Ink's
ask is specifically "via Kraken Verify," an attestation provider, not Uniswap's adapter standard.
That is a reason to keep an integration in our back pocket, not a reason to switch lanes.

**What survives is one sentence, and it is worth keeping:** a permissioned pool is the first
environment we have found where **identity is enforced by someone other than us, for free** — the
"party that agreed in advance to be inspected" of §8's ledger theorem, case (c). Address-shopping,
which killed every ledger-based MEV mechanism we evaluated at a cost of 52,700 gas, **requires issuer
approval here.** That is a paragraph supporting a mechanism, not a submission.

**Recommendation: do not switch.** §3's bar is "materially better on theme fit + novelty." This is
worse on theme fit, no better on novelty, and materially worse on adoption and demonstrability than
the standing SWITCHBACK recommendation. **The seven hook ideas that depend on this primitive should
be re-examined against §5.16 first — my expectation is that most of them are the redundant half.**
