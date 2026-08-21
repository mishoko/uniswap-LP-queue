# docs — read in this order

**Start here. Most of this directory is superseded and will actively mislead you if read cold.**

| Read | File | Why |
|---|---|---|
| **1st** | [`NEXT_SESSION_ASSAY.md`](./NEXT_SESSION_ASSAY.md) | **The only current plan.** Thesis, state, what to build next, what is honestly open. |
| 2nd | [`../README.md`](../README.md) | What Assay is and what it deliberately does not claim. |
| 3rd | [`SPIKE-predicate-sandbox.md`](./SPIKE-predicate-sandbox.md) | Every v4 fact and measurement already established. Do not re-derive any of it. |
| reference | [`SPIKE-sender-and-afterSwapReturnDelta.md`](./SPIKE-sender-and-afterSwapReturnDelta.md) | Still accurate: callback `sender` semantics, `afterSwapReturnDelta` signs. |

## Superseded — kept for provenance, not for instruction

These describe **Hardcap framed as MEV recapture**, a product framing that was reviewed and
withdrawn on 2026-08-21. They still contain accurate v4 mechanics, so they are kept; but every
"win goal", "judging product" and "do not build X" instruction in them is void.

- `Hardcap Fail-Closed MEV Cap Hook - Implementation Plan.md`
- `NEXT_IMPLEMENTER.md`
- `IMPLEMENTER_BRIEF.md`
- `VIDEO_SCRIPT.md`

**Why the framing was withdrawn** (short version — the long one is in `NEXT_SESSION_ASSAY.md` §1):
the block's first swap was exempt from the claw, which *subsidises* the top-of-block race it claimed
to fight; a dust in-range liquidity add zeroed the claw for an entire block, permanently, for the
price of gas; and the vault paid late depositors out of surplus accrued before they arrived. The
first two were recorded in the plan as "accepted weaknesses" and the third was enshrined as a
passing test named `..._capturesRemainder`.

`HardcapHook` itself survives as Assay's **reference hook** — its sealed callback envelope is good
work and is reused. Only the marketing was withdrawn.
