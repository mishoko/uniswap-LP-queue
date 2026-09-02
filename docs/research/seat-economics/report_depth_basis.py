"""
DOES N_max SURVIVE A CHANGE OF PREMIUM BASIS?  The same depth sweep on the weight the CONTRACT
ACTUALLY IMPLEMENTS.

WHY THIS FILE EXISTS, AND IT IS NOT A ROBUSTNESS CHECK -- IT IS A DIVERGENCE.

  sim.py ships `PREM_WEIGHT = 'inventory'`: the pot is divided over the seats' POST-FILL holdings
  of the OUTGOING token.  Every phi number this directory has published -- results-tranche.txt,
  results-shipping.txt, and therefore the shipped constant phi = 8500 and the window [7455, 8312]
  -- is on that basis.  sim.py's own comment calls liquidity weighting "the settled replacement".

  The contract settled it.  Read line by line, 2026-09-02:

      src/queue/QueueHook.sol:1150   _accruePremium(bool inIsZero, uint256 pot, uint256 excludedL)
      src/queue/QueueHook.sol:1154       uint256 w = standingL - excludedL;
      src/queue/QueueHook.sol:1494   _settlePremium(...)  builds excludedL as the summed
                                     `liquidity` of ranks [start .. min(next, n-1)] -- the seats
                                     this fill paid -- and calls _accruePremium with it.
      src/queue/QueueHook.sol:248    "WHY THE WEIGHT IS LIQUIDITY AND NOT INVENTORY"

  That is CONTRIBUTED LIQUIDITY WITH THE PAYERS EXCLUDED, which is sim.py's third mode,
  `'liquidity_excl'` -- carried in sim.py as "MY READING of the rule ... UNCONFIRMED against the
  Solidity".  It is confirmed above, at the three line numbers.

  So the depth sweep in results-depth.txt, and the shipping sweep it reconciles against, are BOTH
  measured on a premium basis the deployed contract no longer implements.  This file re-measures
  the depth question on the contract's basis so that the answer is not an artefact of the stale
  one.  It does NOT modify sim.py: `PREM_WEIGHT` is a knob sim.py provides for exactly this
  purpose ("Kept so the difference can be measured, not assumed"), and it is set per worker
  process, at import, before any Book is constructed.

WHAT CHANGES UNDER THE CONTRACT'S BASIS, PREDICTED BEFORE THE RUN (LAW 5 -- this must be able to
come out either way):
  - Under 'inventory', a seat the fill drained holds zero of the outgoing token and collects
    nothing; a deep, untouched seat holds its whole opening balance.  The weight is therefore
    ALREADY close to capital share among the untouched seats.
  - Under 'liquidity_excl' the exclusion is the SAME set (the ranks the fill touched) but the
    weight among the rest is exact capital share rather than a balance that a PARTIAL fill, or a
    fill in the OPPOSITE direction, has moved.  The two agree exactly when no seat is partially
    drained and no seat has been drained in the other direction; they diverge in proportion to how
    much of the book sits in a mixed state.
  - Direction of the effect on the BACK constraint is NOT obvious in advance.  If the deep tail is
    over-weighted under inventory (it holds a full balance while mid-book seats hold a partial
    one), the contract's basis moves money from the tail towards the mid-book, which HELPS the
    binding seat and could open a window at greater depth.  Either outcome is reachable.

CONTROL: the phi = 0 column must be IDENTICAL to results-depth.txt's, to floating point, because at
phi = 0 no premium is withheld and the weight is never used.  If it is not, the basis switch is
touching something it must not touch.  Section 1 asserts exactly that.
"""
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim
sim.PREM_WEIGHT = 'liquidity_excl'      # set BEFORE any Book exists, in every process
import wing
from sim import run
from report_addendum import ladder
from report_depth import (BOOK, RPH, P0, HALF, REG, RANGES, MW, GAS, SEEDS, SCHED,
                          caps_for, cross, pct, lp_cell)

from report_depth import (BOOK, RPH, P0, HALF, REG, RANGES, MW, GAS, SEEDS, SCHED, PHIS,
                          caps_for, cross, pct, lp_cell, _pool_run, _bars_row)

NS = tuple(int(x) for x in os.environ.get("BASIS_NS", "2,5,8,16,32").split(","))
CACHE = os.environ.get("BASIS_CACHE", "/tmp/queue-depth-basis")
INV_CACHE = os.environ.get("DEPTH_CACHE", "/tmp/qd120")     # the inventory-basis caches
BASIS = 'liquidity_excl'


def _init():
    sim.PREM_WEIGHT = BASIS


def cell(a):
    n, sch, vol, dr, seed, lp = a
    sim.PREM_WEIGHT = BASIS                       # belt and braces: also set inside the worker
    caps = caps_for(n, sch); head = caps[0]
    R = np.zeros((len(PHIS), n)); TURN = np.zeros((len(PHIS), n)); pool = np.zeros(len(PHIS))
    for j, phi in enumerate(PHIS):
        bk, _, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                        half=HALF, phi=phi)
        assert bk.weight == BASIS, "the basis switch did not reach this worker"
        bk.tie_out(Pt)
        d, h = bk.pnl(Pt)
        R[j] = d/h; TURN[j] = ((bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1))/h
        pool[j] = abs(float(d.sum()/h.sum()) - lp)
    bk, Pf, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                     half=HALF, phi=0, trace=True)
    out = dict(ret=R, turn=TURN, pool=pool, hrs=bk.hrs, null_fee=0.0, null_mk=0.0,
               static=float(ladder(bk, Pf, Pt, caps)[0]))
    for w_ in MW:
        m = wing.managed_wing(bk, Pf, Pt, head, w_, BOOK, 0.0)
        for gn, g in GAS.items():
            out[f"mw_{w_}_{gn}"] = m['ret'] - m['remints']*g/m['hold']
    return out


def _idx(a):
    i, j = a; return i, cell(j)


def _cp(nm): return os.path.join(CACHE, nm + ".npz")


def stage(n, sch, nproc):
    nm = f"n{n}_{sch}"
    if os.path.exists(_cp(nm)): return
    LP = np.load(os.path.join(INV_CACHE, "lp.npz"))
    jobs, keys = [], []
    for rn, v, dr in REG:
        for j, sd in enumerate(SEEDS):
            jobs.append((n, sch, v, dr, sd, float(LP[rn][j]))); keys.append(rn)
    from multiprocessing import Pool
    t = time.time(); out = [None]*len(jobs)
    with Pool(nproc, initializer=_init) as p:
        for i, r in p.imap_unordered(_idx, list(enumerate(jobs)), chunksize=2):
            out[i] = r
    d = {}
    for rn, _, _ in REG:
        v = [r for r, k in zip(out, keys) if k == rn]
        A = np.stack([r['ret'] for r in v])
        d[f"{rn}_ret"] = A.mean(axis=0)
        d[f"{rn}_se"] = A.std(axis=0, ddof=1)/math.sqrt(A.shape[0])
        d[f"{rn}_turn"] = np.stack([r['turn'] for r in v]).mean(axis=0)
        d[f"{rn}_poolerr"] = np.stack([r['pool'] for r in v]).max(axis=0)
        d[f"{rn}_bars"] = _bars_row(v)
    np.savez(_cp(nm), **d)
    sys.stderr.write(f"[basis {nm}: {len(jobs)*(len(PHIS)+1)} runs, {time.time()-t:.0f}s]\n")


def main():
    nproc = int(os.environ.get("DEPTH_PROCS", max(1, (os.cpu_count() or 4) - 2)))
    os.makedirs(CACHE, exist_ok=True)
    args = sys.argv[1:]
    if args and args[0] == "stage":
        return stage(int(args[1]), args[2], nproc)
    if args and args[0] == "all":
        for n in NS:
            for sch in SCHED:
                stage(n, sch, nproc)
    miss = [f"n{n}_{sch}" for n in NS for sch in SCHED if not os.path.exists(_cp(f"n{n}_{sch}"))]
    if miss: sys.exit("REFUSING TO REPORT -- no cache for: " + ", ".join(miss))

    LP = np.load(os.path.join(INV_CACHE, "lp.npz"))
    LPm = {rn: float(LP[rn].mean()) for rn, _, _ in REG}
    LPse = {rn: float(LP[rn].std(ddof=1)/math.sqrt(len(LP[rn]))) for rn, _, _ in REG}
    RET, SE, TURN, POOL, WB, HRS = {}, {}, {}, {}, {}, {}
    IRET = {}
    for n in NS:
        for sch in SCHED:
            z = np.load(_cp(f"n{n}_{sch}"))
            zi = np.load(os.path.join(INV_CACHE, f"n{n}_{sch}.npz"))
            for rn, _, _ in REG:
                k = (n, sch, rn)
                RET[k] = z[f"{rn}_ret"]; SE[k] = z[f"{rn}_se"]; TURN[k] = z[f"{rn}_turn"]
                POOL[k] = z[f"{rn}_poolerr"]
                b = z[f"{rn}_bars"]
                WB[k] = dict(bw=MW[int(b[0])], mw=float(b[1]), static=float(b[3]))
                HRS[k] = float(b[6])
                IRET[k] = zi[f"{rn}_ret"]

    def window(n, sch, rn):
        k = (n, sch, rn)
        hi, hst = cross(PHIS, RET[k][:, 0], WB[k]['mw'])
        lows = [(i, ) + cross(PHIS, RET[k][:, i], LPm[rn]) for i in range(1, n)]
        if any(st == 'never' for _, _, st in lows): return None, hi, hst, lows, "EMPTY"
        lo = max(v for _, v, _ in lows)
        if hst == 'never':  return lo, hi, hst, lows, "EMPTY"
        if hst == 'always': return lo, hi, hst, lows, f"[{lo:.0f}, 9500+]"
        return lo, hi, hst, lows, (f"[{lo:.0f}, {hi:.0f}]" if lo <= hi else "EMPTY (cross)")

    W = 100
    def rule(t): print("="*W); print(t); print("="*W)

    rule("THE DEPTH SWEEP ON THE PREMIUM BASIS THE CONTRACT ACTUALLY IMPLEMENTS")
    print("  PREM_WEIGHT = 'liquidity_excl' -- contributed liquidity, the ranks this fill paid")
    print("  excluded, pot HELD when every seat is excluded. Confirmed against QueueHook.sol at")
    print("  lines 1150 / 1154 / 1494. results-depth.txt and results-shipping.txt are both on")
    print("  PREM_WEIGHT = 'inventory', which the contract replaced in Phase 8.")
    print()
    print(f"  N in {NS}, schedules {SCHED}, {len(SEEDS)} paths, phi grid {PHIS}.")
    print(f"  Same seeds, same regimes, same wing engine, same pro-rata baselines as")
    print(f"  results-depth.txt -- the ONLY difference is the premium's weight vector.")
    print()

    rule("1.  THE phi = 0 CONTROL -- the basis switch must be INVISIBLE where no premium is paid")
    print("  At phi = 0 nothing is withheld and the weight vector is never read, so every seat's")
    print("  mean return must be BIT-IDENTICAL to the inventory-basis run. This is the control")
    print("  that goes RED if setting PREM_WEIGHT reached something it must not reach, or if the")
    print("  two runs are not actually on the same seeds.")
    print()
    print(f"  {'sched':>7} {'regime':>7} {'N':>4} {'max |basis - inventory| over all seats':>42}")
    worst0 = 0.0
    for sch in SCHED:
        for rn, _, _ in REG:
            for n in NS:
                k = (n, sch, rn)
                e = float(np.max(np.abs(RET[k][0] - IRET[k][0])))
                worst0 = max(worst0, e)
                print(f"  {sch:>7} {rn:>7} {n:>4} {e:>42.3e}")
            print()
    print(f"  WORST phi=0 disagreement anywhere: {worst0:.3e}   "
          f"{'PASS' if worst0 < 1e-12 else 'FAIL -- THE TWO RUNS ARE NOT COMPARABLE'}")
    print()

    rule("2.  HOW MUCH THE BASIS MOVES A SEAT, at phi = 9500")
    print("  If this were small the whole question would be moot. It is not.")
    print(f"  {'sched':>7} {'regime':>7} {'N':>4} {'r1 inv':>9} {'r1 basis':>9} {'delta':>9}"
          f" {'s2 inv':>9} {'s2 basis':>9} {'delta':>9} {'tail inv':>9} {'tail basis':>11}")
    for sch in SCHED:
        for rn, _, _ in REG:
            for n in NS:
                k = (n, sch, rn); a_ = IRET[k][-1]; b_ = RET[k][-1]
                print(f"  {sch:>7} {rn:>7} {n:>4} {pct(a_[0]):>9} {pct(b_[0]):>9}"
                      f" {100*(b_[0]-a_[0]):>+8.2f}p {pct(a_[1]):>9} {pct(b_[1]):>9}"
                      f" {100*(b_[1]-a_[1]):>+8.2f}p {pct(a_[-1]):>9} {pct(b_[-1]):>11}")
            print()

    rule("3.  THE WINDOW AT EVERY DEPTH, on the contract's basis")
    for sch in SCHED:
        for rn, _, _ in REG:
            print(f"  --- {sch} / {rn} ---   pro-rata LP {pct(LPm[rn])} (se {100*LPse[rn]:.3f}pp)"
                  f"   in-band life {HRS[(NS[0], sch, rn)]:.1f}d")
            print(f"  {'N':>4} {'head/book':>10} {'r1@phi=0':>10} {'r1@9500':>10} {'wing bar':>9}"
                  f" {'front<=':>10} {'back>=':>10} {'window':>16} {'binding':>9}"
                  f" {'gap@9500':>10} {'t':>7}")
            for n in NS:
                k = (n, sch, rn); caps = caps_for(n, sch)
                lo, hi, hst, lows, wstr = window(n, sch, rn)
                hi_s = (f"{hi:.0f}" if hst == 'cross'
                        else ("no bound" if hst == 'always' else "below@0"))
                if any(st == 'never' for _, _, st in lows):
                    bad = [f"s{i+1}" for i, _, st in lows if st == 'never']
                    lo_s = "NEVER"; bind = bad[0] + (f"+{len(bad)-1}" if len(bad) > 1 else "")
                    bi = min((i for i, _, st in lows if st == 'never'),
                             key=lambda i: RET[k][-1, i])
                else:
                    lo_s = f"{lo:.0f}"; bi = max(lows, key=lambda t: t[1])[0]; bind = f"s{bi+1}"
                gap = RET[k][-1, bi] - LPm[rn]
                sd_ = math.sqrt(SE[k][-1, bi]**2 + LPse[rn]**2)
                print(f"  {n:>4} {caps[0]/BOOK:>10.1%} {100*RET[k][0, 0]:>9.1f}%"
                      f" {100*RET[k][-1, 0]:>9.1f}% {pct(WB[k]['mw']):>9} {hi_s:>10} {lo_s:>10}"
                      f" {wstr:>16} {bind:>9} {100*gap:>+9.2f}pp {gap/sd_:>+7.1f}")
            print()

    rule("4.  N_max ON THE CONTRACT'S BASIS, beside N_max on the inventory basis")
    print(f"  {'schedule':>10} {'regime':>8} {'N with a window (contract basis)':>40} {'N_max':>8}")
    for sch in SCHED:
        for rn, _, _ in REG:
            good = [n for n in NS if not window(n, sch, rn)[4].startswith("EMPTY")]
            print(f"  {sch:>10} {rn:>8} {(', '.join(map(str, good)) or 'none'):>40} "
                  f"{(str(max(good)) if good else 'NONE'):>8}")
    print()

    rule("5.  THE DEEP TAIL AT phi = 9500, on the contract's basis")
    print(f"  {'sched':>7} {'regime':>7} {'N':>4} {'best seat':>10} {'its return':>11}"
          f" {'its turnover':>13} {'r1 return':>10} {'tail ret':>9} {'tail turn':>10}")
    for sch in SCHED:
        for rn, _, _ in REG:
            for n in NS:
                k = (n, sch, rn); r = RET[k][-1]; t = TURN[k][-1]; b = int(np.argmax(r))
                print(f"  {sch:>7} {rn:>7} {n:>4} {('s'+str(b+1)):>10} {pct(r[b]):>11}"
                      f" {t[b]:>12.0f}x {pct(r[0]):>10} {pct(r[-1]):>9} {t[-1]:>9.0f}x")
            print()

    rule("6.  THE IDENTITY, on the contract's basis")
    print("  Worst per-path |queue pool return - independently simulated pro-rata LP|, over phi.")
    w6 = max(float(POOL[(n, sch, rn)].max()) for n in NS for sch in SCHED for rn, _, _ in REG)
    print(f"  worst residual anywhere: {w6:.3e}")
    print("="*W)


if __name__ == "__main__":
    main()
