"""
THE SHIPPING phi -- measured on the configuration that is ACTUALLY DEPLOYED, not on a proxy.

WHY THIS FILE EXISTS. Every phi crossover published so far (6599 / 7294 / 4875 / 5563 / 637 / 3361)
was measured on a 32-EQUAL book, i.e. a head of $31,250. The deploy ships `SEATS = 5` funded
5:4:3:2:1, i.e. a head of $333,333 -- more than ten times larger. Head size has already been
measured as the DOMINANT economic parameter on this project (a $600k head turns rank 1 from
-67.89% into +26.98% at an unchanged phi), so reading a shipping constant off the 32-equal grid
would repeat the exact error this whole session has been correcting.

  band       BAND_HALF_WIDTH = 960 ticks ~ +10.08% / -9.16%.  Modelled as a SYMMETRIC +/-10%:
             this simulator's band is symmetric, and the 0.9pp asymmetry is not represented.
             It biases nothing in phi's direction; it is stated rather than hidden.
  roster     SEATS = 5, capital weights 5:4:3:2:1 on a $1,000,000 book
  fee        3000 (0.30%), matching FEE in sim.py
  decimals   18/6 -- IRRELEVANT HERE. This simulator is floating point and has no cross-unit
             comparison anywhere, so it models the mechanism as DESIGNED. On the shipped 18/6 pool
             the token0 premium is separately known to be inert; that makes these numbers an UPPER
             bound on what the deployed contract pays backward, not a description of it.

THE TWO CONSTRAINTS, AND THEY PULL OPPOSITE WAYS.

  FRONT   rank 1 must beat what the same capital gets from actively managing a narrow ATM range.
          That is the product. It is decreasing in phi.
  BACK    seats 2-5 must beat what the same capital gets from being an ordinary pro-rata LP --
          NOT "beat zero". Section 11 of results-tranche.txt measured the pro-rata LP as having
          equal-or-lower downside deviation than a back seat at equal return, so "positive" is not
          the bar; "better than simply LPing" is. It is increasing in phi.

If those two windows do not overlap there is no shipping constant, and that is a finding rather
than a failure to find one.
"""
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim, wing
from sim import run
from report_addendum import ladder

BOOK, RPH, P0 = 1_000_000.0, 15.0, 2000.0
SHIP = [BOOK*w/15.0 for w in (5, 4, 3, 2, 1)]
HEAD = SHIP[0]
HALF = 0.10
PHIS = tuple(range(0, 10000, 500))
REG = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
RANGES = (("A", range(0, 30)), ("B", range(100, 130)), ("C", range(200, 230)), ("D", range(1000, 1030)))
MW = (0.01, 0.02, 0.05)
GAS = {"L2": 0.02, "L1": 12.00}


def seats(a):
    phi, vol, dr, seed = a
    bk, _, Pt = run(SHIP, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                    half=HALF, phi=phi)
    bk.tie_out(Pt)
    d, h = bk.pnl(Pt)
    pb, _, Pt2 = run([BOOK], False, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                     half=HALF)
    dp, hp = pb.pnl(Pt2)
    return dict(ret=d/h, lp=float(dp[0]/hp[0]), hrs=bk.hrs,
                turn=((bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1))/h)


def wings(a):
    """phi-independent: the wing lives in a different pool. Traced once per (regime, seed)."""
    vol, dr, seed = a
    bk, Pf, Pt = run(SHIP, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                     half=HALF, phi=0, trace=True)
    ef, em, _ = wing.check_null(bk, Pf, Pt, BOOK, 5)
    out = dict(null_fee=ef, null_mk=em, static=float(ladder(bk, Pf, Pt, SHIP)[0]))
    for w_ in MW:
        m = wing.managed_wing(bk, Pf, Pt, HEAD, w_, BOOK, 0.0)
        for gn, g in GAS.items():
            out[f"mw_{w_}_{gn}"] = m['ret'] - m['remints']*g/m['hold']
        out[f"cost_{w_}"] = (m['remints'], m['fees']/m['hold'], m['markout']/m['hold'],
                             m['conv_fee']/m['hold'], m['conv_imp']/m['hold'])
    return out


def cross(xs, ys, target):
    """First phi at which y crosses `target`, linearly interpolated.

    Returns (value, status). status is 'cross', 'always' (already on the good side at phi=0 and
    never leaves it) or 'never'. Collapsing 'always' and 'never' into a single None is how a table
    ends up saying "all phi" about a seat that in fact never qualifies -- caught in the smoke run.
    """
    for k in range(1, len(xs)):
        a, b = ys[k-1] - target, ys[k] - target
        if a == 0: return float(xs[k-1]), 'cross'
        if a*b < 0:
            return xs[k-1] + (xs[k] - xs[k-1])*a/(a - b), 'cross'
    return (float(xs[0]), 'always') if ys[0] > target else (None, 'never')


def pct(x): return f"{100*x:+.2f}%"


def main():
    from multiprocessing import Pool
    nproc = max(1, os.cpu_count() or 4)
    t0 = time.time()
    jobs, keys = [], []
    for phi in PHIS:
        for rn, v, dr in REG:
            for rname, rg in RANGES:
                for sd in rg:
                    jobs.append((phi, v, dr, sd)); keys.append((phi, rn, rname))
    wj, wk = [], []
    for rn, v, dr in REG:
        for rname, rg in RANGES:
            for sd in rg:
                wj.append((v, dr, sd)); wk.append((rn, rname))
    sys.stderr.write(f"[{len(jobs)} seat runs + {len(wj)} traced wing runs on {nproc} procs]\n")
    with Pool(nproc) as p:
        wres = p.map(wings, wj, chunksize=4)
        sres = p.map(seats, jobs, chunksize=16)
    sys.stderr.write(f"[done {time.time()-t0:.0f}s]\n")

    S, Wg = {}, {}
    for k, v in zip(keys, sres): S.setdefault(k, []).append(v)
    for k, v in zip(wk, wres): Wg.setdefault(k, []).append(v)
    R = {k: np.array([r['ret'] for r in v]) for k, v in S.items()}
    LP = {k: np.array([r['lp'] for r in v]) for k, v in S.items()}
    HR = {k: np.array([r['hrs'] for r in v], float) for k, v in S.items()}

    W = 100
    def rule(t): print("="*W); print(t); print("="*W)

    rule("THE SHIPPING phi -- measured on the DEPLOYED configuration")
    print(f"  SEATS = 5, capital 5:4:3:2:1 on a ${BOOK:,.0f} book "
          f"(head ${HEAD:,.0f} = {HEAD/BOOK:.1%}), band +/-{HALF:.0%}, fee 0.30%,")
    print(f"  retail {RPH:.0f}/hr, 4 disjoint seed ranges x 30 paths = 120 paths per cell, "
          f"phi swept {PHIS[0]}-{PHIS[-1]} step 500.")
    print()
    print("  NOTE: every previously published crossover (6599 / 4875 / ...) used a $31,250 head.")
    print("  This file uses the shipped $333,333 head. Head size is the dominant economic")
    print("  parameter on this project, so the two are NOT interchangeable.")
    print()
    mxf = max(max(r['null_fee'] for r in v) for v in Wg.values())
    mxm = max(max(r['null_mk'] for r in v) for v in Wg.values())
    print(f"  wing null (full-band wing of 1/5 the capital == 1/5 of the pool): "
          f"worst fee {mxf:.2e}, markout {mxm:.2e}")
    print()

    # ------------------------------------------------------------------ the two constraints
    rule("1.  THE FRONT -- rank 1 against the alternatives, as phi rises")
    for rn, _, _ in REG:
        vv = []
        for rname, _ in RANGES: vv += Wg[(rn, rname)]
        g = lambda k: float(np.mean([r[k] for r in vv]))
        bw = max(MW, key=lambda w_: g(f"mw_{w_}_L2"))
        mwv, stv = g(f"mw_{bw}_L2"), g("static")
        life = float(np.mean(np.concatenate([HR[(0, rn, rname)] for rname, _ in RANGES])))/24
        lpv = float(np.mean(np.concatenate([LP[(0, rn, rname)] for rname, _ in RANGES])))
        r1 = [float(np.mean(np.concatenate([R[(p_, rn, rname)][:, 0] for rname, _ in RANGES])))
              for p_ in PHIS]
        print(f"  --- {rn}  life {life:.1f}d  ---   pro-rata LP {pct(lpv)}   "
              f"managed wing (w={bw:.0%}, L2) {pct(mwv)}   static ladder wing {pct(stv)}")
        print("   phi " + "".join(f"{p_:>8}" for p_ in PHIS))
        print("   r1  " + "".join(f"{100*x:>8.1f}" for x in r1))
        for nm, tgt in (("managed wing", mwv), ("static wing", stv), ("pro-rata LP", lpv)):
            c, st_ = cross(PHIS, r1, tgt)
            lbl = (f"{c:.0f}" if st_ == 'cross'
                   else ("never in range (still above at phi=9500)" if st_ == 'always'
                         else "already below at phi=0"))
            print(f"        rank 1 falls below the {nm:14} at phi = {lbl}")
        print()

    rule("2.  THE BACK -- seats 2-5 against an ORDINARY PRO-RATA LP, as phi rises")
    print("  The bar is the LP, not zero. results-tranche.txt section 11 measured the pro-rata LP")
    print("  with equal-or-lower downside deviation than a back seat at equal return, so a back")
    print("  seat that merely returns something positive has not earned its rent, lock or gas.")
    print()
    for rn, _, _ in REG:
        lpv = float(np.mean(np.concatenate([LP[(0, rn, rname)] for rname, _ in RANGES])))
        print(f"  --- {rn} ---   pro-rata LP {pct(lpv)}")
        print("   phi  " + "".join(f"{p_:>8}" for p_ in PHIS))
        firsts = {}
        for i in (1, 2, 3, 4):
            rr = [float(np.mean(np.concatenate([R[(p_, rn, rname)][:, i] for rname, _ in RANGES])))
                  for p_ in PHIS]
            print(f"   s{i+1}  " + "".join(f"{100*x:>8.1f}" for x in rr))
            firsts[i+1] = cross(PHIS, rr, lpv)
        lab = {'cross': lambda v: f"{v:.0f}", 'always': lambda v: "all phi",
               'never': lambda v: "NEVER"}
        print("        first phi at which each seat beats the LP -> "
              + "  ".join(f"s{k}: {lab[st_](v)}" for k, (v, st_) in firsts.items()))
        if any(st_ == 'never' for _, st_ in firsts.values()):
            bad = [f"s{k}" for k, (_, st_) in firsts.items() if st_ == 'never']
            print(f"        ALL of seats 2-5 beat the LP: NOT AT ANY phi -- {', '.join(bad)} "
                  f"never does")
        else:
            print(f"        ALL of seats 2-5 beat the LP from phi = "
                  f"{max(v for v, _ in firsts.values()):.0f}")
        # per-cell, not just the mean
        for p_ in (0, 5000, 8500):
            fr = float(np.mean(np.concatenate(
                [(R[(p_, rn, rname)][:, 1:] > LP[(p_, rn, rname)][:, None]) for rname, _ in RANGES])))
            print(f"        phi={p_:<5} fraction of individual (path, seat) cells in 2-5 that "
                  f"beat the LP: {100*fr:.1f}%")
        print()

    rule("3.  THE FEASIBLE WINDOW -- where both constraints hold at once")
    print(f"  {'regime':>10} {'front needs phi <=':>20} {'back needs phi >=':>34} {'window':>22}")
    win = {}
    for rn, _, _ in REG:
        vv = []
        for rname, _ in RANGES: vv += Wg[(rn, rname)]
        g = lambda k: float(np.mean([r[k] for r in vv]))
        bw = max(MW, key=lambda w_: g(f"mw_{w_}_L2"))
        mwv = g(f"mw_{bw}_L2")
        lpv = float(np.mean(np.concatenate([LP[(0, rn, rname)] for rname, _ in RANGES])))
        r1 = [float(np.mean(np.concatenate([R[(p_, rn, rname)][:, 0] for rname, _ in RANGES])))
              for p_ in PHIS]
        hi, hst = cross(PHIS, r1, mwv)
        lows = []
        for i in (1, 2, 3, 4):
            rr = [float(np.mean(np.concatenate([R[(p_, rn, rname)][:, i] for rname, _ in RANGES])))
                  for p_ in PHIS]
            lows.append(cross(PHIS, rr, lpv))
        if any(st_ == 'never' for _, st_ in lows):
            lo, lo_s = None, "NEVER (a seat never clears the LP)"
        else:
            lo = max(v for v, _ in lows); lo_s = f"{lo:.0f}"
        hi_s = (f"{hi:.0f}" if hst == 'cross'
                else ("no bound in range" if hst == 'always' else "already below at phi=0"))
        if lo is None:
            w_s = "EMPTY"
        elif hst == 'always':
            w_s = f"[{lo:.0f}, 9500+]"
        elif hst == 'never':
            w_s = "EMPTY"
        else:
            w_s = f"[{lo:.0f}, {hi:.0f}]" if lo <= hi else "EMPTY (constraints cross)"
        win[rn] = (lo, hi)
        print(f"  {rn:>10} {hi_s:>20} {lo_s:>34} {w_s:>22}")
    print()

    rule("4.  ITEMISED COST OF THE HEAD'S REAL COMPETITOR, at the SHIPPED head size")
    print(f"  A managed ATM range holding ${HEAD:,.0f}, re-minted at spot. % of its own capital,")
    print("  realised over the band's life. Gas reported separately, never folded in.")
    print()
    print(f"  {'regime':>10} {'width':>7} {'re-mints':>9} {'fees':>10} {'markout':>10}"
          f" {'conv fee':>10} {'conv impact':>12} {'net ex-gas':>11} {'L2':>10} {'L1':>10}")
    for rn, _, _ in REG:
        vv = []
        for rname, _ in RANGES: vv += Wg[(rn, rname)]
        for j, w_ in enumerate(MW):
            a = np.array([r[f"cost_{w_}"] for r in vv], float).mean(axis=0)
            net = a[1] + a[2] - a[3] - a[4]
            print(f"  {rn if j == 0 else '':>10} {w_:>7.0%} {a[0]:>9.0f} {pct(a[1]):>10}"
                  f" {pct(a[2]):>10} {pct(-a[3]):>10} {pct(-a[4]):>12} {pct(net):>11}"
                  f" {pct(np.mean([r[f'mw_{w_}_L2'] for r in vv])):>10}"
                  f" {pct(np.mean([r[f'mw_{w_}_L1'] for r in vv])):>10}")
        print()

    rule("5.  REGIME WEIGHTING -- should TOXIC drive the choice?")
    print("  Excluding TOXIC entirely picks a constant that is optimal only in good states, which")
    print("  is the error this project calls green-number-chasing. Weighting it by the CALENDAR it")
    print("  actually occupies is the honest middle: a band that dies in a day contributes a day.")
    print()
    print(f"  {'regime':>10} {'mean life':>11} {'calendar share if equally likely':>34}")
    tot = 0.0
    lives = {}
    for rn, _, _ in REG:
        lf = float(np.mean(np.concatenate([HR[(0, rn, rname)] for rname, _ in RANGES])))/24
        lives[rn] = lf; tot += lf
    for rn, _, _ in REG:
        print(f"  {rn:>10} {lives[rn]:>10.1f}d {lives[rn]/tot:>33.1%}")
    print()
    print("  A TOXIC band is ~1-2% of the calendar even if a toxic regime is as LIKELY as a benign")
    print("  one, because it dies almost immediately. Its crossover therefore should not set the")
    print("  constant -- but it should not be deleted from the average either.")
    print("="*W)


if __name__ == "__main__":
    main()
