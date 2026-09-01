# `recenter()` v2 — UNIT-GREEN, CAMPAIGN-RED. DO NOT SHIP AS-IS.

**Status 2026-09-01: not in `src/`.** The implementation (`recenter.sol.txt`) and its eight tests
(`tests.sol.txt`) are preserved verbatim. They compile and the eight tests pass. **The invariant
campaign fails against them and the defect was not located.**

## Why it exists

The first `recenter()` was deleted after the panel broke it three ways (PITFALLS 5.93). This rebuild
fixes all three, and the fixes are believed correct:

| old defect | v2 fix | test |
|---|---|---|
| Guard read `getLiquidity()` — active L **at spot** — while the destination is a **range**, so a narrow wing inside the new band was invisible and got swallowed (N5) | Destination emptiness is a **range** property: liquidity active at the near edge (`getLiquidity() ± liquidityNet(edge)`) must be zero, **and** the band is truncated at the first initialised tick inside it via a bitmap walk | `test_recenter_truncatesAtANarrowWingInsideTheDestination`, `test_recenter_straddlingWingIsRefusedByName` |
| Centred the band on spot → in range → needs both tokens → `min` of the legs → reminted ~nothing | Mints **one-sided, one spacing clear of spot**, in the direction of the inventory held. `sqrtP` is outside the band, so `_liquidityForAmounts` takes the single-token branch and deploys in full | `test_recenter_remintsThePositionAtFullSize`, `test_recenter_bandSitsBesideSpotNotAroundIt` |
| Over-broad: any wing covering spot blocked it forever for one wei | A wing **ending at** the near edge is disjoint and correctly allowed (that is what the `liquidityNet` term is for) | `test_recenter_aWingEndingAtTheEdgeDoesNotBlockIt` |
| Attacker chose the resting tick, making the above deterministic (F8) | Price must be a **full half-width** beyond the band, and after a move it is one spacing outside the new one, so it cannot be ratcheted | `test_recenter_inRangeAndJustOutsideAreBothRefused`, `test_recenter_cannotBeRatcheted` |

It also restores the property the deletion bought: `test_recenter_theNoOverlapInvariantSurvivesTheMove`
asserts an outside LP still cannot mint inside the band **after** it has moved — so
`_beforeAddLiquidity` guards arrivals and `recenter` guards the band's own arrival, which is the
asymmetry the first version had.

## Why it does not ship

**The invariant campaign fails, and the cause is unlocated.** Evidence, in the order it was gathered:

1. `swap` + `recenter` alone → **GREEN**.
2. `swap` + `recenter` + `sweepFloat` → **RED**. `swap` + `recenter` + `addToSeat` → **RED**.
   `swap` + `recenter` + `withdraw` → green. Both red cases are the paths that **deploy float into
   the position**.
3. Every action **except** `recenter` → **GREEN**. So it is recenter, not a pre-existing defect.
4. First symptom was `I2: the position is OVER-backed`, which `_solvent` asserted as *exact*
   equality. That assertion was an **asymmetry, not a stronger claim** — it held only because before
   a band move every path rounded one way (v4 rounds for the pool, so the hook could only end short).
   A burn/re-mint cycle rounds both ways. Measured excess: **393 wei against an `owed` of 4.0e21**
   (1e-19 relative), well inside the existing residual bound `K = 100_000`.
5. Making `_solvent` symmetric let the campaign explore past that abort, and it then found **large**
   divergences — `I2b` shortfalls of ~9.1e20 on an inflow of 9.1e21 (**10%**), excesses of ~9e18,
   and `I1` ledger-vs-ghost gaps of ~60,631 wei. **These are not rounding.** There is a real
   accounting defect in the interaction between a moved band and the deploy-into-position paths.

## The lead to start from

After a v2 recenter the band sits **beside** spot and never contains it, so the pool has **zero active
liquidity at the current tick**. That is a state the rest of the contract has never operated in:
before this, the hook's band was where all the liquidity was, so any price move *was* a swap through
the band and `_allocate` kept the ledger in step with the position's composition. Now the price can
move through empty space with no fill at all, and `addToSeat` / `sweepFloatIntoPosition` deploy into
an **out-of-range** band, which can only absorb one of the two tokens.

Suspect, in order:
1. **Per-token INVARIANT F versus a position whose composition changes without `_allocate` running.**
   The ledger's `a0`/`a1` split only moves when the allocator runs; an out-of-range band's
   composition is fixed at one token. Check whether a sequence of recenters can leave the ledger
   owing token X while the position holds only token Y, beyond what float covers.
2. `_liquidityToCover` / `_payOut` against an out-of-range band — releasing token1 from a position
   that holds only token0 is impossible, and the dust clamp turns that into a shortfall.
3. `_queueShare` when `poolManager.getLiquidity() == 0` at spot but the hook's `liquidity != 0`
   (band beside spot). ClipMath flagged the `liquidity == 0` bail at `_bandStep` as an unreached
   edge; the beside-spot geometry may reach it.

**Method that worked and should be repeated:** bisect the handler's selector set. Two-action and
three-action campaigns localise the interaction in one 40-second run each.

## Do not repeat these mistakes

- **`forge test` is interlocked against a live `mutate.py`, but EDITS TO `src/` ARE NOT.** A
  background campaign's `finally` restore silently reverted ~200 lines of this work mid-session, and
  the only symptom was `function recenter` no longer existing. See PITFALLS.
- Eight passing unit tests were **not** evidence. The campaign was.
