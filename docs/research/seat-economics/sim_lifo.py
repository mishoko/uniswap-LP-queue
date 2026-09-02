"""
LIFO UNWIND -- KILLED 2026-09-02, BEFORE ANY NUMBER WAS PUBLISHED.  THIS FILE IS A HEADSTONE.

The idea: QUEUE fills FRONT-FIRST and, on the credit side, rewinds the opposite cursor to the
start of the sweep (`QueueHook.sol:1294`, `:1299`), so a recovering swap restarts at rank 1 and the
head's inventory recycles on every reversal while the tail's does not (the "Ratchet",
premise-review/fairness.md A.2c).  The proposed fix was: fill forward, UNWIND BACKWARD -- drain the
just-acquired token from the deepest seat that acquired it, walking down toward rank 1.

IT IS DEAD, AND NONE OF THE FOUR REASONS NEEDS A SIMULATION.  Do not re-derive them.

1. "UNWIND" IS NOT OBSERVABLE TO THE CONTRACT.  In a two-sided position there is no in and out,
   only token0 and token1.  A seat taking token0 for token1 has ROTATED, not acquired.  Calling
   that a fill or an unwind needs a reference point -- the seat's opening inventory -- that the
   contract does not store and that drifts with every swap.  The two ways out are per-seat history
   on the hot path, or a global direction flag; and a direction flag is a FREE LANE.  A dust trade
   in direction A sets the label, the real trade in direction B lands on the rank you chose.  Two
   transactions, no capital, one block -- strictly cheaper than the +267 bps evacuation attack
   already measured, and it COMPOSES with it.

2. IT FREEZES THE HEAD OUT OF BOTH DIRECTIONS.  A deep sell drains token1 from ranks 1..k.  LIFO
   unwinds from k downward, and a typical reversal is smaller than the move that created the deep
   fill, so the buy stops short of rank 1 -- which keeps its token0.  The next sell then SKIPS
   rank 1, because rank 1 holds no token1, and lands on the deep seats that just unwound.  The
   head can neither sell nor exit: it becomes a frozen buy-and-hold of whatever it was last sold.

3. MARGINAL PRICING TAKES BACK WHAT LIFO GIVES.  `_fill` walks `sprev` from `s0` toward `s1`, so
   the FIRST slot is the WORST slot of the move.  LIFO would hand the tail exit priority and
   charge it the worst exit price in the same stroke.

4. THE CLOSURE RESULT, AND IT IS THE ONE THAT GENERALISES.  In a single pro-rata position the loss
   ordering and the cash ordering are THE SAME ORDERING, because getting out of token0 IS getting
   into token1.  There is exactly one queue and it necessarily governs both legs.  Seniority needs
   two INDEPENDENT orderings, and the moment you have two you have two things to sell -- you have
   doubled the auction, not built a tranche.  **A senior/junior tranche is IMPOSSIBLE in this
   mechanism, not merely unattractive.**

A NOTE ON THE CONSERVATION CHECK THAT WAS PROPOSED FOR IT, BECAUSE IT WILL BE PROPOSED AGAIN.
"total P&L under the new rule minus total P&L under FIFO ~ 0" CANNOT FAIL.  Availability depends on
the position's TOTAL inventory and never on how it is split, and the remainder line forces
sum(give) == amtIn in any visiting order.  `ROTATION.md`'s banner already recorded this: a
maximally corrupt allocator crediting 100% of every swap to the head scored +0.000000% on it too.
Keep it as a sanity trap for implementation bugs.  It is not a control and it is not evidence
about ordering.

WHAT REPLACED THIS WORK: `sim_exec.py` / `report_exec.py` / `results-exec.txt` -- a
characterisation of the SHIPPED FIFO rule, asking whether marginal pricing and front-first unwind
are a matched pair (worse price for more fills vs better price for fewer) or whether one side is
strictly worse.
"""
raise ImportError("sim_lifo is a headstone, not a module. See sim_exec.py.")
