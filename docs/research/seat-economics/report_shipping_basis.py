"""
THE SHIPPING SWEEP, RE-RUN ON THE PREMIUM BASIS THE CONTRACT ACTUALLY IMPLEMENTS.

WHY THIS FILE EXISTS.  PITFALLS 5.178.  `sim.py:66` ships `PREM_WEIGHT = 'inventory'` -- the pot
divided over the seats' POST-FILL holdings of the outgoing token.  The deployed hook divides by
CONTRIBUTED LIQUIDITY WITH THE PAYERS EXCLUDED:

    src/queue/QueueHook.sol:1356   _claims:          uint256 wl = s.liquidity;   (one weight, BOTH directions)
    src/queue/QueueHook.sol:1154   _accruePremium:   uint256 w = standingL - excludedL;
    src/queue/QueueHook.sol:1494   _settlePremium:   builds excludedL as the summed `liquidity` of
                                   the ranks this fill paid, and advances their marks so they do
                                   not claim this pot.

That is `sim.py`'s third mode, `'liquidity_excl'`.  The contract replaced `'inventory'` in PHASE 8
(commit 2d2a26f).  `report_shipping.py` never overrides the default, so `results-shipping.txt` --
and therefore the feasible window [7455, 8312] and the shipped `PREMIUM_BPS = 7_900` derived as its
midpoint (`script/QueueDeployBase.sol:120-136`) -- are measured on a rule the contract has not
implemented for two phases.

`report_depth_basis.py` already does exactly this for the DEPTH question and states the same
divergence in its own header.  It answers "does N_max survive?".  It does NOT answer the question
the product is sold on, which is the SHIPPING roster's: does the back still beat the passive LP,
and does a feasible phi window still exist, on the contract's real weighting?  That is this file.

HOW, AND WHY IT DOES NOT EDIT `report_shipping.py`.  `PREM_WEIGHT` is a knob `sim.py` provides for
exactly this purpose ("Kept so the difference can be measured, not assumed").  The original script
is imported UNCHANGED and its `main()` called, so the two runs differ in the weight vector and in
nothing else -- the same discipline `report_depth_basis.py` uses.  `report_shipping.main()` builds
its own `multiprocessing.Pool` with no initializer, so the obvious worry is that a global set only
in the parent never reaches the workers -- on this machine the start method IS `spawn`
(Python 3.14.4, `get_start_method() == 'spawn'`), which does not inherit parent memory.

**THAT WORRY WAS TESTED RATHER THAN ASSUMED, AND IT IS WRONG -- recorded because the first draft of
this header asserted it confidently.**  Under `spawn` the child re-imports the `__main__` module in
order to unpickle the work function, and `__main__` here is THIS file, whose module-level
`sim.PREM_WEIGHT = BASIS` therefore runs again inside every worker.  Measured directly: workers
report `'liquidity_excl'` both with and without an initializer.

The initializer is kept anyway, as belt and braces, because that propagation is a side effect of
how `spawn` bootstraps `__main__` rather than a guarantee -- it would silently stop holding if this
file were ever imported as a library rather than run as `__main__`, or if the start method changed
to `forkserver` with a different bootstrap.  The explicit initializer makes the basis independent of
all of that.  It costs nothing and it removes the one way this file could quietly measure the
inventory basis while claiming otherwise.

THE CONTROL, AND IT MUST BE CHECKED BEFORE ANY OTHER NUMBER IS BELIEVED (LAW 5).  At phi = 0 no
premium is withheld, so the weight vector is never read and **the phi = 0 column of this run must
equal `results-shipping.txt`'s phi = 0 column exactly.**  If it does not, the basis switch is
touching something it must not touch and every other number here is void.  Diff them:

    diff <(grep -A3 'phi ' results-shipping.txt) <(grep -A3 'phi ' results-shipping-basis.txt)

WHAT COULD COME OUT EITHER WAY, PREDICTED BEFORE THE RUN.  Under `'inventory'` a seat the fill
drained holds zero of the outgoing token and collects nothing, while an untouched deep seat holds
its whole opening balance -- so among the untouched seats the weight is already close to capital
share.  Under `'liquidity_excl'` the excluded SET is the same (the ranks the fill touched) but the
weight among the rest is exact capital share rather than a balance that a partial fill, or a fill
in the opposite direction, has moved.  The two agree exactly when no seat is partially drained and
no seat has been drained in the other direction, and diverge in proportion to how much of the book
sits in a mixed state.  On a 5-seat book with a 1/3 head that mixed fraction is LARGE, so a
material divergence is expected here even though the depth sweep may show little.

Direction is NOT obvious in advance and this file must be able to refute the product:
  - if the back's crossover phi RISES above the front's ceiling, the window CLOSES and there is no
    shipping constant -- the same outcome `QueueDeployBase`'s docblock already records as reachable
    ("both windows are empty and no shipping constant exists");
  - if it FALLS, the window widens and 7,900 was conservative.

Reproduce:  python3 report_shipping_basis.py > results-shipping-basis.txt
"""
import sys, os, multiprocessing

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim

BASIS = "liquidity_excl"
sim.PREM_WEIGHT = BASIS  # the parent, before any Book exists


def _init():
    """Runs in every worker at spawn. Without this the workers use sim.py's default."""
    import sim as _s
    _s.PREM_WEIGHT = BASIS


_RealPool = multiprocessing.Pool


def _PoolWithInit(processes=None, *a, **kw):
    kw.setdefault("initializer", _init)
    return _RealPool(processes, *a, **kw)


multiprocessing.Pool = _PoolWithInit

import report_shipping  # noqa: E402  -- imported AFTER the basis is set

if __name__ == "__main__":
    sys.stderr.write(f"[shipping sweep on PREM_WEIGHT = {BASIS!r} -- the contract's basis]\n")
    # Belt and braces: assert the knob is what we think it is, in the parent, before any work.
    assert sim.PREM_WEIGHT == BASIS, "the basis was reset between import and run"
    report_shipping.main()
