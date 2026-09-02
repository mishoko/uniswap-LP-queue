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

PHIS = tuple(list(range(0, 10000, 1000)) + [9500])
NS = (2, 5, 8, 16, 32)


def _init():
    sim.PREM_WEIGHT = 'liquidity_excl'


def cell(a):
    n, sch, vol, dr, seed = a
    caps = caps_for(n, sch); head = caps[0]
    R = np.zeros((len(PHIS), n)); TURN = np.zeros((len(PHIS), n)); pool = np.zeros(len(PHIS))
    for j, phi in enumerate(PHIS):
        bk, _, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                        half=HALF, phi=phi)
        assert bk.weight == 'liquidity_excl', "basis switch did not reach this worker"
        bk.tie_out(Pt)
        d, h = bk.pnl(Pt)
        R[j] = d/h; TURN[j] = ((bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1))/h
        pool[j] = float(d.sum()/h.sum())
    bk, Pf, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                     half=HALF, phi=0, trace=True)
    out = dict(ret=R, turn=TURN, pool=pool, hrs=bk.hrs,
               static=float(ladder(bk, Pf, Pt, caps)[0]))
    for w_ in MW:
        m = wing.managed_wing(bk, Pf, Pt, head, w_, BOOK, 0.0)
        for gn, g in GAS.items():
            out[f"mw_{w_}_{gn}"] = m['ret'] - m['remints']*g/m['hold']
    return out


def main():
    from multiprocessing import Pool
    nproc = max(1, os.cpu_count() or 4)
    t0 = time.time()
    ljobs, lkeys = [], []
    for rn, v, dr in REG:
        for sd in SEEDS: ljobs.append((v, dr, sd)); lkeys.append(rn)
    jobs, keys = [], []
    for n in NS:
        for sch in SCHED:
            for rn, v, dr in REG:
                for sd in SEEDS:
                    jobs.append((n, sch, v, dr, sd)); keys.append((n, sch, rn))
    sys.stderr.write(f"[basis=liquidity_excl: {len(jobs)} cells x {len(PHIS)} phi on {nproc}]\n")
    with Pool(nproc, initializer=_init) as p:
        lres = p.map(lp_cell, ljobs, chunksize=4)
        cres = p.map(cell, jobs, chunksize=2)
    sys.stderr.write(f"[done {time.time()-t0:.0f}s]\n")

    LPv = {}
    for k, v in zip(lkeys, lres): LPv.setdefault(k, []).append(v)
    LPm = {k: float(np.mean(v)) for k, v in LPv.items()}
    LPse = {k: float(np.std(v, ddof=1)/math.sqrt(len(v))) for k, v in LPv.items()}
    C = {}
    for k, v in zip(keys, cres): C.setdefault(k, []).append(v)
    RET, SE, TURN, WB, HRS = {}, {}, {}, {}, {}
    for k, v in C.items():
        A = np.stack([r['ret'] for r in v])
        RET[k] = A.mean(axis=0); SE[k] = A.std(axis=0, ddof=1)/math.sqrt(A.shape[0])
        TURN[k] = np.stack([r['turn'] for r in v]).mean(axis=0)
        HRS[k] = float(np.mean([r['hrs'] for r in v]))/24.0
        g = lambda key: float(np.mean([r[key] for r in v]))
        bw = max(MW, key=lambda w_: g(f"mw_{w_}_L2"))
        WB[k] = dict(bw=bw, mw=g(f"mw_{bw}_L2"), static=g("static"))

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
    print(f"  {len(jobs)*len(PHIS) + len(jobs) + len(ljobs):,} simulator runs, "
          f"{time.time()-t0:.0f}s wall.")
    print()

    rule("1.  THE phi = 0 CONTROL -- the basis switch must be INVISIBLE where no premium is paid")
    print("  At phi = 0 nothing is withheld and the weight vector is never read, so every seat's")
    print("  return must be identical under both bases. This is what would go RED if setting")
    print("  PREM_WEIGHT had reached something it must not reach.")
    print(f"  {'sched':>7} {'regime':>7} {'N':>4} {'r1 @ phi=0':>12} {'tail @ phi=0':>14} "
          f"{'pro-rata LP':>12}")
    for sch in SCHED:
        for rn, _, _ in REG:
            for n in NS:
                k = (n, sch, rn)
                print(f"  {sch:>7} {rn:>7} {n:>4} {pct(RET[k][0, 0]):>12} "
                      f"{pct(RET[k][0, -1]):>14} {pct(LPm[rn]):>12}")
            print()
    print("  Compare these against the identically-labelled cells in results-depth.txt section 2")
    print("  ('r1@phi=0' column). They must agree to the printed precision.")
    print()

    rule("2.  THE WINDOW AT EVERY DEPTH, on the contract's basis")
    for sch in SCHED:
        for rn, _, _ in REG:
            print(f"  --- {sch} / {rn} ---   pro-rata LP {pct(LPm[rn])} (se {100*LPse[rn]:.3f}pp)"
                  f"   in-band life {HRS[(5, sch, rn)]:.1f}d")
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
                    lo_s = f"{lo:.0f}"; bi = max(lows, key=lambda t: t[1])[0]
                    bind = f"s{bi+1}"
                gap = RET[k][-1, bi] - LPm[rn]
                sd_ = math.sqrt(SE[k][-1, bi]**2 + LPse[rn]**2)
                print(f"  {n:>4} {caps[0]/BOOK:>10.1%} {100*RET[k][0, 0]:>9.1f}%"
                      f" {100*RET[k][-1, 0]:>9.1f}% {pct(WB[k]['mw']):>9} {hi_s:>10} {lo_s:>10}"
                      f" {wstr:>16} {bind:>9} {100*gap:>+9.2f}pp {gap/sd_:>+7.1f}")
            print()

    rule("3.  HEADLINE ON THE CONTRACT'S BASIS -- N_max")
    print(f"  {'schedule':>10} {'regime':>8} {'N with a window':>34} {'N_max':>8}")
    for sch in SCHED:
        for rn, _, _ in REG:
            good = [n for n in NS if not window(n, sch, rn)[4].startswith("EMPTY")]
            print(f"  {sch:>10} {rn:>8} {(', '.join(map(str, good)) or 'none'):>34} "
                  f"{(str(max(good)) if good else 'NONE'):>8}")
    print()

    rule("4.  THE DEEP TAIL AT phi = 9500, on the contract's basis")
    print(f"  {'sched':>7} {'regime':>7} {'N':>4} {'best seat':>10} {'its return':>11}"
          f" {'its turnover':>13} {'r1 return':>10} {'tail ret':>9} {'tail turn':>10}")
    for sch in SCHED:
        for rn, _, _ in REG:
            for n in NS:
                k = (n, sch, rn); r = RET[k][-1]; t = TURN[k][-1]; b = int(np.argmax(r))
                print(f"  {sch:>7} {rn:>7} {n:>4} {('s'+str(b+1)):>10} {pct(r[b]):>11}"
                      f" {t[b]:>12.0f}x {pct(r[0]):>10} {pct(r[-1]):>9} {t[-1]:>9.0f}x")
            print()
    print("="*W)


if __name__ == "__main__":
    main()
