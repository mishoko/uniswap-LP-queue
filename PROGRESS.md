# PROGRESS.md — the project's memory

**Update this at the end of every working session. This file, `PLAN.md` and `AGENTS.md` are the
handoff. If those three do not tell the next person what to do, the handoff failed.**

Newest entry first. Never delete an entry — supersede it.

---

## Status board

| Phase | Name | Status | Proven? |
|---|---|---|---|
| 0 | Harness + reproduce the reference spike | **NOT STARTED** | — |
| 1 | Allocator core | NOT STARTED | — |
| 2 | Deposit / withdraw + redemption-dust fix | NOT STARTED | — |
| 3 | ERC-6909 rank token + transfer | NOT STARTED | — |
| 4 | Harberger rent variant | NOT STARTED | — |
| 5 | Gas + scale (O(1) prefix-sum redesign) | NOT STARTED | — |
| 6 | Adversarial + invariant campaign | NOT STARTED | — |
| 7 | Testnet deploy + demo + video | NOT STARTED | — |

*(Phase definitions, entry/exit criteria and acceptance tests are in `PLAN.md` §C and §D.)*

---

## Carried forward from the design phase — what is ALREADY PROVEN

These were established by executed experiments before the build started. **Do not re-derive them.**
Evidence lives in `archive/2026-08-26/`.

| Claim | Status | Evidence |
|---|---|---|
| Front-first allocation at the swap's realised average price is **exact to the wei in both tokens at a non-unit price (1:4)** | **PROVEN** | `archive/2026-08-26/test/spike/QueueAllocator.t.sol`, 9 tests; conservation measured on PoolManager's own ERC20 balances |
| The remainder-assignment line is load-bearing | **PROVEN** | Negative control: floor-only mutation survives swap 1 and dies at swap 2 |
| Pro-rata allocation and an off-by-one cursor both break it | **PROVEN** | Two further negative controls, both red, revert reasons asserted |
| Head-only swap gas is **flat at ~31,874** regardless of queue depth | **MEASURED** (with `vm.cool()`) | Spike §Q2 |
| A sweeping swap is O(entries) at **~6,753 gas/entry**; ~44 seats at a 300k budget | **MEASURED** | Spike §Q2 |
| A **~0.26 wei/swap** redemption residual exists; the last withdrawer eats it | **MEASURED** | Spike §Q1 |
| That residual is **NOT** fee-growth truncation | **FALSIFIED** by a zero-fee pool retaining 88% of the drift | Spike §Q1 |
| The residual is **unfarmable** — cost-to-damage off by ~20 orders of magnitude | **REASONED from measurement** | Spike §Q1 |
| No forgeable-proof toxicity signal exists for a v4 hook | **PROVEN** | `docs/research/IDEAS_CONSTRAINED.md` §1 |
| No static curve can improve adverse selection per unit of depth | **PROVEN** | `docs/research/IDEAS_CURVES.md` §0 |
| A v4 hook can never see or pay the trader | **PROVEN** | `CLAUDE.md` §5.16/§5.18 |

## Carried forward — what is OPEN

| Item | Why it matters | Where |
|---|---|---|
| **Redemption dust fix** | Until built, *"the queue's face value is redeemable"* must not be claimed | `PLAN.md` Phase 2 |
| **Rank-then-run hole** | Plain-token rank can be abandoned before a scheduled event; only the Harberger variant closes it | `PLAN.md` Phase 4 |
| **O(1) prefix-sum redesign** | Named but **unbuilt and unverified** — do not quote it as a property | `PLAN.md` Phase 5 |
| **Seat governance** | Rank must be bought or Harberger-held, **never granted by deposit order** (dust-griefing the head) | `BUSINESS.md` §8 |
| **Theme framing** | The honest bridge to "Sustainable Liquidity and MEV Protection" is the weakest part of the pitch | `BUSINESS.md` §10 |

---

## Session log

### 2026-08-26 — design phase closed, build not started
- QUEUE selected after an exhaustive candidate search. Honest score **4.33** on the published rubric.
- Alternatives assessed and rejected with evidence, all archived: a hook-safety/bonding platform
  (sound but unwinnable — the security lane is 0 for 9 across eight cohorts), permissioned pools
  (Uniswap shipped it, hit the same wall we did, zero on-chain adoption), a CPG static-analysis
  product (off-chain, fails the "must be a hook" gate), and four fee-mechanism designs that topped
  out at 3.95.
- **The structural lesson that produced QUEUE:** every earlier candidate was a *fee mechanism* —
  it answered "who pays and how much". Winners in this competition **mint a new tradeable object**.
  That reframe is what moved the ceiling.
- Repository archived to `archive/2026-08-26/`. Clean ground prepared.
- **Next action: `PLAN.md` Phase 0.** Reproduce the reference spike from
  `archive/2026-08-26/test/spike/QueueAllocator.t.sol` in the new `test/queue/` tree and confirm the
  three negative controls still go red. **Do not write new mechanism code until that is green — and
  do not trust it green until the controls are red.**
