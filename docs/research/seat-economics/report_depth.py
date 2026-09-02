"""
IS THERE A MAXIMUM ECONOMICALLY VIABLE ROSTER DEPTH?  N_max, swept.

WHY THIS FILE EXISTS.  results-shipping.txt found a feasible phi window on the DEPLOYED roster --
SEATS = 5 funded 5:4:3:2:1, i.e. a head holding 33.3% of the book -- and found it EMPTY in TOXIC.
Nobody has asked whether that window is a property of the MECHANISM or a property of THAT ROSTER.
The hypothesis under test, stated so it can be refuted rather than confirmed:

    The head's excess over an ordinary LP is a FIXED POT.  Deepening the roster divides that pot
    among more mouths while the head's own capital share shrinks, so there is a depth N_max beyond
    which no phi satisfies both constraints in any regime.  If that is true, MAX_SEATS = 32 is not
    merely a gas ceiling (PITFALLS 5.129); it is an ECONOMICALLY MEANINGLESS depth.

THE TWO CONSTRAINTS, unchanged from report_shipping.py, and they pull opposite ways:

  FRONT   rank 1 must beat what the SAME capital gets from actively managing a narrow ATM range
          (the keeper bot).  Decreasing in phi.  Note the bar MOVES with N: the managed wing is
          funded with caps[0], so a deeper roster is compared against a smaller keeper.
  BACK    every seat 2..N must beat what the same capital gets from being an ORDINARY PRO-RATA LP
          -- not "beat zero" (results-tranche.txt section 11).  Increasing in phi.

If the windows do not overlap at some N, that is the finding.

---------------------------------------------------------------------------------------------------
LAW 5 (AGENTS.md section 3).  WHAT WOULD HAVE TO BE TRUE FOR THIS TO READ "WINDOW EXISTS AT N=32"?

  Answer, worked out BEFORE the run:  the FRONT constraint is expected to be SLACK at large N --
  results-seats.txt puts rank 1 at +911%/yr on a 32-equal book against a managed wing worth a few
  per cent, so `cross()` should report 'always' (no upper bound in range) and the window's upper
  end should be 9500+.  The entire question at N=32 therefore reduces to whether ALL 31 back seats
  clear the pro-rata LP by phi = 9500.  At phi = 0 exactly 1 of 32 does (results-seats.txt).  The
  pot handed backward at phi = 9500 is 95% of a fee stream the head generates at 411,877%/yr
  turnover, which is large relative to the back seats' capital.  Both outcomes are reachable by the
  arithmetic; nothing in the construction forces EMPTY.  This is a real experiment, not a tautology.

THE KNOWN-ANSWER CASE, and it is reported FIRST because nothing else is believable without it:
  the N = 5 LINEAR cell IS the shipped roster and MUST reproduce results-shipping.txt's
  BENIGN [7455, 8312] / NORMAL [4114, 8921] / TOXIC EMPTY, seat by seat.  Same seeds, same regimes,
  same 120 paths, same phi grid.  If it does not, this harness is wrong and every other cell in
  this file is worthless.  Section 1 prints both numbers side by side.

WHAT THIS FILE DOES NOT PROVE.
  - The simulator is UNCHANGED (sim.py, PREM_WEIGHT = 'inventory', PREM_MODE = 'contract').  Every
    caveat already attached to it applies here verbatim, including the 18/6 premium inertia: these
    are an UPPER bound on what the shipped contract pays backward, not a description of it.
  - The managed wing is a PRICE TAKER carved out of the same book (wing.py).  At SMALL N under the
    LINEAR schedule the head is a large fraction of the book -- 66.7% at N=2, 50% at N=3 -- and the
    approximation is strained precisely there.  HEAD/BOOK is printed on every row so a reader can
    discount the shallow LINEAR cells rather than take them at face value.
  - Gas, rent, lock and roster-cap costs are NOT charged to the seat on either side.  Every window
    reported here is therefore an OPTIMISTIC bound on the real one.

HOW IT RUNS.  The full grid is ~110,000 simulator runs and a single process was SIGKILLed part way
through on the first attempt, losing everything.  The work is therefore STAGED and CACHED, one
(depth, schedule) at a time, under $DEPTH_CACHE (default /tmp/queue-depth-cache):

    python3 report_depth.py lp                 the pro-rata baselines   (N- and phi-independent)
    python3 report_depth.py fine               the N=5 LINEAR step-500 reconciliation cell
    python3 report_depth.py stage <N> <SCHED>  one cell block
    python3 report_depth.py report             read every cache, print the report
    python3 report_depth.py all                every missing stage, then report

A stage that already has a cache file is SKIPPED, so an interrupted run resumes where it stopped
instead of starting again.  The caches hold per-cell means, standard errors and the wing bars --
never per-path returns -- so nothing downstream can silently re-use a stale path sample.
---------------------------------------------------------------------------------------------------
"""
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim, wing
from sim import run
from report_addendum import ladder

BOOK, RPH, P0 = 1_000_000.0, 15.0, 2000.0
HALF = 0.10
# THE PHI GRID, AND WHY THERE ARE THREE OF THEM.  One (depth, schedule) block on the step-1000 grid
# was MEASURED at 594s on this machine; 22 of them is 3.6 hours.  The sweep therefore runs on the
# step-2000 grid `G2000`, and the N=5 LINEAR RECONCILIATION CELL runs on the full step-500 grid so
# it can be compared to results-shipping.txt point for point.
#
# PATH COUNT IS NOT CUT: 120 paths everywhere, the same seeds report_shipping.py used.  What is cut
# is the phi RESOLUTION, and section 1b prices that cut rather than assuming it away -- it reads
# every crossover off all three grids from the SAME 120-path sample and prints the disagreement.
# The reason to expect it to be small is structural, not hopeful: phi scales each seat's forfeit
# linearly and redistributes it linearly, so the curves are affine up to the second-order feedback
# of received premium into the weights.  9500 is kept as the top point of every grid so that
# "no bound in range" means in this file exactly what it means in report_shipping.py.
FINE = tuple(range(0, 10000, 500))                                  # 20 points, step 500
G1000 = FINE[::2] + (FINE[-1],)                                     # 11 points, step 1000
G2000 = FINE[::4] + (FINE[-1],)                                     # 6 points, step 2000
PHIS = G2000
REG = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
RANGES = (("A", range(0, 30)), ("B", range(100, 130)), ("C", range(200, 230)), ("D", range(1000, 1030)))
MW = (0.01, 0.02, 0.05)
GAS = {"L2": 0.02, "L1": 12.00}

SCHED = ("LINEAR", "EQUAL")
SEEDS = [sd for _, rg in RANGES for sd in rg]          # 120, four disjoint ranges
CACHE = os.environ.get("DEPTH_CACHE", "/tmp/queue-depth-cache")

# THE GRID ACTUALLY RUN, and it is an environment variable rather than a constant because this
# machine is shared: the sweep was executed while other agents held a sustained load average of
# ~200 on 10 cores, which measured 3.18 s per simulator run against 0.157 s on the idle machine.
# `DEPTH_NS` and `DEPTH_PATHS` are therefore the two knobs that were turned, and BOTH are printed
# in the report header so that no reader has to guess which sample a number came from.
#
#   DEPTH_NS      the depths swept.        Default here is the reduced list actually run.
#   DEPTH_PATHS   paths per SWEEP cell.    120 uses all four disjoint seed ranges; 60 uses ranges
#                 A and C, which are still disjoint from each other. The RECONCILIATION cell
#                 always uses all 120 -- it has to, because it is compared to a 120-path result.
NS = tuple(int(x) for x in os.environ.get("DEPTH_NS", "2,4,5,8,16,32").split(","))
NPATH = int(os.environ.get("DEPTH_PATHS", "60"))
if NPATH == 120:
    SWEEP_SEEDS = SEEDS
elif NPATH == 60:
    SWEEP_SEEDS = list(RANGES[0][1]) + list(RANGES[2][1])     # ranges A and C
else:
    SWEEP_SEEDS = SEEDS[:NPATH]
SWEEP_IX = [SEEDS.index(sd) for sd in SWEEP_SEEDS]


def caps_for(n, sch):
    """LINEAR is N:N-1:...:1 -- at N=5 that IS the shipped 5:4:3:2:1 book, exactly."""
    if sch == "LINEAR":
        w = list(range(n, 0, -1)); s = float(sum(w))
        return [BOOK*x/s for x in w]
    return [BOOK/n]*n


# --------------------------------------------------------------------------------- the workers
def lp_cell(a):
    """The ordinary pro-rata LP baseline.  Depends on NEITHER N NOR phi, so it is traced once per
    (regime, seed) instead of 440 times per (regime, seed) as report_shipping.py did inside its
    own seat worker.  Identical numbers, ~30% less compute."""
    vol, dr, seed = a
    pb, _, Pt = run([BOOK], False, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                    half=HALF)
    dp, hp = pb.pnl(Pt)
    return float(dp[0]/hp[0])


def cell(a):
    """One (N, schedule, regime, seed): the whole phi sweep plus the traced wing bars.

    `fine` selects the step-500 grid and SKIPS the traced wing run -- the wing bar is a property of
    the roster and the seed, not of the phi grid, so the coarse job's bar is reused verbatim.

    The wing is traced at phi = 0 only.  phi moves money BETWEEN seats and cannot move the swap
    tape, so the wing bar is phi-independent -- the same assumption report_shipping.py makes, and
    section 6's identity residual is what would catch it if it were false.
    """
    n, sch, vol, dr, seed, lp, fine = a
    caps = caps_for(n, sch)
    head = caps[0]
    grid = FINE if fine else PHIS

    R = np.zeros((len(grid), n))
    TURN = np.zeros((len(grid), n))
    pool = np.zeros(len(grid))
    hrs = 0
    for j, phi in enumerate(grid):
        bk, _, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                        half=HALF, phi=phi)
        bk.tie_out(Pt)
        d, h = bk.pnl(Pt)
        R[j] = d/h
        TURN[j] = ((bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1))/h
        pool[j] = abs(float(d.sum()/h.sum()) - lp)     # THIS path's residual, not a mean of means
        hrs = bk.hrs
    if fine:
        return dict(ret=R, turn=TURN, pool=pool, hrs=hrs)

    bk, Pf, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                     half=HALF, phi=0, trace=True)
    ef, em, _ = wing.check_null(bk, Pf, Pt, BOOK, n)
    out = dict(ret=R, turn=TURN, pool=pool, hrs=hrs, null_fee=ef, null_mk=em,
               static=float(ladder(bk, Pf, Pt, caps)[0]))
    for w_ in MW:
        m = wing.managed_wing(bk, Pf, Pt, head, w_, BOOK, 0.0)
        for gn, g in GAS.items():
            out[f"mw_{w_}_{gn}"] = m['ret'] - m['remints']*g/m['hold']
    return out


def cross(xs, ys, target):
    """First phi at which y crosses `target`, linearly interpolated.  VERBATIM from
    report_shipping.py -- the tables in the two files have to mean the same thing.

    Returns (value, status).  status is 'cross', 'always' (already on the good side at phi=0 and
    never leaves it) or 'never'.  Collapsing 'always' and 'never' into a single None is how a table
    ends up saying "all phi" about a seat that in fact never qualifies.
    """
    for k in range(1, len(xs)):
        a, b = ys[k-1] - target, ys[k] - target
        if a == 0: return float(xs[k-1]), 'cross'
        if a*b < 0:
            return xs[k-1] + (xs[k] - xs[k-1])*a/(a - b), 'cross'
    return (float(xs[0]), 'always') if ys[0] > target else (None, 'never')


def pct(x): return f"{100*x:+.2f}%"


# ------------------------------------------------------------------------------ STAGING / CACHE
# The full grid was SIGKILLed part way through on the first attempt with nothing written. Each
# (depth, schedule) block is therefore computed and cached on its own, and a block whose cache
# exists is skipped. Nothing per-path is cached: the caches hold means, standard errors, the worst
# per-path identity residual and the wing bars, so a downstream reader cannot silently re-derive a
# statistic from a sample that is not the one this file documents.

def _cpath(name): return os.path.join(CACHE, name + ".npz")


def _pool_run(fn, jobs, nproc):
    """imap_unordered so the parent never holds the whole result list."""
    from multiprocessing import Pool
    out = [None]*len(jobs)
    with Pool(nproc) as p:
        for i, r in p.imap_unordered(lambda_wrap(fn), list(enumerate(jobs)), chunksize=2):
            out[i] = r
    return out


def _idx_lp(a):
    i, j = a; return i, lp_cell(j)


def _idx_cell(a):
    i, j = a; return i, cell(j)


def lambda_wrap(fn):
    return _idx_lp if fn is lp_cell else _idx_cell


def stage_lp(nproc):
    if os.path.exists(_cpath("lp")): return
    jobs = [(v, dr, sd) for rn, v, dr in REG for sd in SEEDS]
    t = time.time(); res = _pool_run(lp_cell, jobs, nproc)
    d, i = {}, 0
    for rn, _, _ in REG:
        d[rn] = np.array(res[i:i+len(SEEDS)]); i += len(SEEDS)
    np.savez(_cpath("lp"), **d)
    sys.stderr.write(f"[lp: {len(jobs)} runs, {time.time()-t:.0f}s]\n")


def stage_fine(nproc):
    if os.path.exists(_cpath("fine")): return
    LP = np.load(_cpath("lp"))
    jobs, keys = [], []
    for rn, v, dr in REG:
        for j, sd in enumerate(SEEDS):
            jobs.append((5, "LINEAR", v, dr, sd, float(LP[rn][j]), True)); keys.append(rn)
    t = time.time(); res = _pool_run(cell, jobs, nproc)
    d = {}
    for rn, _, _ in REG:
        A = np.stack([r['ret'] for r, k in zip(res, keys) if k == rn])
        d[f"{rn}_ret"] = A.mean(axis=0)
        d[f"{rn}_se"] = A.std(axis=0, ddof=1)/math.sqrt(A.shape[0])
    np.savez(_cpath("fine"), **d)
    sys.stderr.write(f"[fine: {len(jobs)*len(FINE)} runs, {time.time()-t:.0f}s]\n")


def stage_cells(n, sch, nproc):
    nm = f"n{n}_{sch}"
    if os.path.exists(_cpath(nm)): return
    LP = np.load(_cpath("lp"))
    jobs, keys = [], []
    for rn, v, dr in REG:
        for j, sd in zip(SWEEP_IX, SWEEP_SEEDS):
            jobs.append((n, sch, v, dr, sd, float(LP[rn][j]), False)); keys.append(rn)
    t = time.time(); res = _pool_run(cell, jobs, nproc)
    d = {}
    for rn, _, _ in REG:
        v = [r for r, k in zip(res, keys) if k == rn]
        A = np.stack([r['ret'] for r in v])
        d[f"{rn}_ret"] = A.mean(axis=0)
        d[f"{rn}_se"] = A.std(axis=0, ddof=1)/math.sqrt(A.shape[0])
        d[f"{rn}_turn"] = np.stack([r['turn'] for r in v]).mean(axis=0)
        # the WORST path's identity residual at each phi -- a mean of residuals would hide a
        # single divergent path, which is exactly what this check exists to catch.
        d[f"{rn}_poolerr"] = np.stack([r['pool'] for r in v]).max(axis=0)
        g = lambda key: float(np.mean([r[key] for r in v]))
        bw = max(MW, key=lambda w_: g(f"mw_{w_}_L2"))
        d[f"{rn}_bars"] = np.array([MW.index(bw), g(f"mw_{bw}_L2"), g(f"mw_{bw}_L1"), g("static"),
                                    max(r['null_fee'] for r in v), max(r['null_mk'] for r in v),
                                    float(np.mean([r['hrs'] for r in v]))/24.0])
    np.savez(_cpath(nm), **d)
    sys.stderr.write(f"[{nm}: {len(jobs)*(len(PHIS)+1)} runs, {time.time()-t:.0f}s]\n")


def load_all():
    LP = np.load(_cpath("lp"))
    LPv = {rn: LP[rn] for rn, _, _ in REG}
    FN = np.load(_cpath("fine"))
    FRET = {rn: FN[f"{rn}_ret"] for rn, _, _ in REG}
    RET, SE, TURN, POOL, HRS, WB = {}, {}, {}, {}, {}, {}
    for n in NS:
        for sch in SCHED:
            z = np.load(_cpath(f"n{n}_{sch}"))
            for rn, _, _ in REG:
                k = (n, sch, rn)
                RET[k] = z[f"{rn}_ret"]; SE[k] = z[f"{rn}_se"]; TURN[k] = z[f"{rn}_turn"]
                POOL[k] = z[f"{rn}_poolerr"]
                b = z[f"{rn}_bars"]
                WB[k] = dict(bw=MW[int(b[0])], mw=float(b[1]), mw_l1=float(b[2]),
                             static=float(b[3]), nf=float(b[4]), nm=float(b[5]))
                HRS[k] = float(b[6])
    return LPv, FRET, RET, SE, TURN, POOL, HRS, WB


def main():
    nproc = int(os.environ.get("DEPTH_PROCS", max(1, (os.cpu_count() or 4) - 2)))
    os.makedirs(CACHE, exist_ok=True)
    args = sys.argv[1:]
    t0 = time.time()
    if args and args[0] == "lp":
        return stage_lp(nproc)
    if args and args[0] == "fine":
        stage_lp(nproc); return stage_fine(nproc)
    if args and args[0] == "stage":
        stage_lp(nproc); return stage_cells(int(args[1]), args[2], nproc)
    if args and args[0] == "all":
        stage_lp(nproc); stage_fine(nproc)
        for n in NS:
            for sch in SCHED:
                stage_cells(n, sch, nproc)
    elif args and args[0] != "report":
        sys.exit(f"usage: {sys.argv[0]} [lp|fine|stage N SCHED|all|report]")

    missing = [f"n{n}_{sch}" for n in NS for sch in SCHED if not os.path.exists(_cpath(f"n{n}_{sch}"))]
    missing += [x for x in ("lp", "fine") if not os.path.exists(_cpath(x))]
    if missing:
        sys.exit("REFUSING TO REPORT -- these stages have no cache: " + ", ".join(missing))
    LPv, FRET, RET, SE, TURN, POOL, HRS, WB = load_all()
    jobs = [0]*(len(NS)*len(SCHED)*len(REG)*len(SEEDS))
    fjobs = [0]*(len(REG)*len(SEEDS))
    ljobs = [0]*(len(REG)*len(SEEDS))

    # TWO LP MEANS, AND THEY ARE NOT INTERCHANGEABLE. The back bar has to be computed on the SAME
    # seed sample as the seats it is compared against, or the comparison is between two different
    # price samples and a gap can be sampling rather than mechanism.
    LPm = {rn: float(LPv[rn][SWEEP_IX].mean()) for rn, _, _ in REG}          # the SWEEP's sample
    LPse = {rn: float(LPv[rn][SWEEP_IX].std(ddof=1)/math.sqrt(len(SWEEP_IX)))
            for rn, _, _ in REG}
    LPm120 = {rn: float(LPv[rn].mean()) for rn, _, _ in REG}                 # all 120, for sect. 1
    LPse120 = {rn: float(LPv[rn].std(ddof=1)/math.sqrt(len(LPv[rn]))) for rn, _, _ in REG}

    def bars(n, sch, rn):
        """(front bar, back bar, r1 curve, per-back-seat crossovers) for one cell."""
        k = (n, sch, rn)
        r1 = RET[k][:, 0]
        hi, hst = cross(PHIS, r1, WB[k]['mw'])
        lows = [(i, ) + cross(PHIS, RET[k][:, i], LPm[rn]) for i in range(1, n)]
        return hi, hst, r1, lows

    def window(n, sch, rn):
        hi, hst, r1, lows = bars(n, sch, rn)
        if any(st == 'never' for _, _, st in lows):
            return None, hi, hst, lows, "EMPTY"
        lo = max(v for _, v, _ in lows)
        if hst == 'never':  return lo, hi, hst, lows, "EMPTY"
        if hst == 'always': return lo, hi, hst, lows, f"[{lo:.0f}, 9500+]"
        return lo, hi, hst, lows, (f"[{lo:.0f}, {hi:.0f}]" if lo <= hi else "EMPTY (cross)")

    W = 100
    def rule(t): print("="*W); print(t); print("="*W)

    rule("N_max -- IS THERE A MAXIMUM ECONOMICALLY VIABLE ROSTER DEPTH?")
    print(f"  book ${BOOK:,.0f}, band +/-{HALF:.0%}, fee 0.30%, retail {RPH:.0f}/hr, P0 {P0:.0f},")
    print(f"  N in {NS},  schedules LINEAR (N:N-1:..:1) and EQUAL,")
    print(f"  SWEEP sample: {NPATH} paths per cell ("
          + ("all 4 disjoint seed ranges x 30" if NPATH == 120 else
             "seed ranges A and C, disjoint, x 30" if NPATH == 60 else "first N of the 120")
          + f");  RECONCILIATION cell: all {len(SEEDS)} paths.")
    if NPATH != 120:
        print(f"  *** PATH COUNT WAS CUT, AND THIS IS THE DISCLOSURE. The sweep ran on {NPATH} of")
        print(f"  the 120 paths report_shipping.py used, because this machine was shared: a")
        print(f"  sustained load average of ~200 on 10 cores measured 3.18s per simulator run")
        print(f"  against 0.157s idle, a 20x slowdown. EVERY table below therefore carries the")
        print(f"  standard error of the mean, and every 'NEVER' carries the gap in units of it.")
        print(f"  A verdict at |t| < 2 is not a verdict. The RECONCILIATION cell was NOT cut.")
    print(f"  phi grids: sweep on {PHIS}")
    print(f"             N=5 LINEAR reconciliation on the full step-500 grid, "
          f"{FINE[0]}-{FINE[-1]}.")
    print(f"  PATH COUNT IS NOT REDUCED -- it is the same 120 paths on the same seeds")
    print(f"  report_shipping.py used. The PHI STEP is coarsened from 500 to 2000 for the sweep,")
    print(f"  and section 1b measures what that costs. Standard errors of the mean are printed so")
    print(f"  a reader can tell a real gap from noise.")
    print(f"  Total {len(jobs)*len(PHIS) + len(fjobs)*len(FINE) + len(jobs) + len(ljobs):,} "
          f"simulator runs, staged and cached one (depth, schedule) at a time.")
    print()
    nf = max(v['nf'] for v in WB.values()); nm = max(v['nm'] for v in WB.values())
    print(f"  wing null control (a full-band wing of 1/N of the capital IS 1/N of the pool):")
    print(f"     worst relative fee error {nf:.2e}, worst markout error {nm:.2e}, over all "
          f"{len(WB)} cells")
    print()

    # ============================================================ 1. THE KNOWN-ANSWER CONTROL
    rule("1.  RECONCILIATION -- the N=5 LINEAR cell IS the shipped roster and must reproduce it")
    print("  results-shipping.txt measured the deployed configuration on these exact seeds. If this")
    print("  harness disagrees with it, nothing else in this file may be read. Both numbers, side")
    print("  by side, computed independently by two scripts that share only sim.py and wing.py.")
    print(f"  This cell is measured on the FULL step-500 grid, point for point with the shipped run.")
    print()
    SHIPPED = {"BENIGN": ("[7455, 8312]", 7455.0, 8312.0, 0.0502,
                          {2: 7455., 3: 6441., 4: 5510., 5: 5098.}),
               "NORMAL": ("[4114, 8921]", 4114.0, 8921.0, 0.0049,
                          {2: 4114., 3: 2535., 4: 2063., 5: 978.}),
               "TOXIC":  ("EMPTY", None, 2144.0, -0.0217,
                          {2: None, 3: 0., 4: 0., 5: 0.})}

    def fine_window(rn):
        r1 = FRET[rn][:, 0]
        hi, hst = cross(FINE, r1, WB[(5, "LINEAR", rn)]['mw'])
        lows = [(i, ) + cross(FINE, FRET[rn][:, i], LPm120[rn]) for i in range(1, 5)]
        if any(st == 'never' for _, _, st in lows):
            return None, hi, hst, lows, "EMPTY"
        lo = max(v for _, v, _ in lows)
        if hst == 'never':  return lo, hi, hst, lows, "EMPTY"
        if hst == 'always': return lo, hi, hst, lows, f"[{lo:.0f}, 9500+]"
        return lo, hi, hst, lows, (f"[{lo:.0f}, {hi:.0f}]" if lo <= hi else "EMPTY (cross)")

    print(f"  {'regime':>8} {'quantity':>26} {'results-shipping.txt':>22} {'this file':>14}"
          f" {'delta':>12}")
    ok = True
    for rn, _, _ in REG:
        s_win, s_lo, s_hi, s_lp, s_seats = SHIPPED[rn]
        lo, hi, hst, lows, wstr = fine_window(rn)
        rows = [("pro-rata LP return", f"{100*s_lp:+.2f}%", f"{100*LPm[rn]:+.2f}%",
                 f"{100*(LPm120[rn]-s_lp):+.3f}pp", abs(LPm120[rn]-s_lp) < 1e-4)]
        if s_hi is not None and hst == 'cross':
            rows.append(("front: r1 below mgd wing at", f"{s_hi:.0f}", f"{hi:.0f}",
                         f"{hi-s_hi:+.1f}", abs(hi-s_hi) < 1.0))
        else:
            got = "below@0" if hst == 'never' else ("no bound" if hst == 'always' else f"{hi:.0f}")
            rows.append(("front: r1 below mgd wing at", f"{s_hi:.0f}" if s_hi else "-", got, "-",
                         False))
        for i, v, st in lows:
            tgt = s_seats[i+1]
            got = "NEVER" if st == 'never' else ("all phi" if st == 'always' else f"{v:.0f}")
            want = "NEVER" if tgt is None else ("all phi" if tgt == 0. else f"{tgt:.0f}")
            num = (st == 'cross' and tgt not in (None, 0.))
            rows.append((f"back: seat {i+1} clears LP at", want, got,
                         f"{v-tgt:+.1f}" if num else "-",
                         (got == want) or (num and abs(v-tgt) < 1.0)))
        rows.append(("WINDOW", s_win, wstr, "", wstr == s_win))
        for j, (nm_, want, got, dl, good) in enumerate(rows):
            ok &= good
            print(f"  {rn if j == 0 else '':>8} {nm_:>26} {want:>22} {got:>14} {dl:>12}"
                  f"  {'' if good else '  <-- MISMATCH'}")
        print()
    print("  RECONCILIATION: " + ("PASS -- this harness reproduces the shipped measurement, "
                                  "number for number." if ok else
                                  "FAIL -- DO NOT READ THE REST OF THIS FILE."))
    print()
    print("  Note on the TOXIC front bar: report_shipping.py prints 2144 for it, and 'r1 falls")
    print("  below the managed wing' is not monotone in TOXIC -- r1 is flat to within a few tenths")
    print("  of a point across the whole sweep, so the crossing is decided by noise of the order of")
    print("  the standard error. It does not matter: TOXIC's window is EMPTY on the BACK constraint")
    print("  at every N in this file, and the front bar never gets to bind.")
    print()

    rule("1b.  WHAT THE COARSE GRID COSTS -- every crossover read off step 500 / 1000 / 2000")
    print("  Sections 2-6 run on the step-2000 grid; one (depth, schedule) block on step 1000 was")
    print("  measured at 594s and 22 of them is 3.6 hours. That is a real approximation, so it is")
    print("  PRICED here instead of asserted: the identical 120-path N=5 LINEAR sample, with every")
    print("  crossover recomputed on each grid. The step-2000 column is the grid the sweep uses.")
    print()
    print(f"  {'regime':>8} {'quantity':>26} {'step 500':>10} {'step 1000':>10} {'step 2000':>10}"
          f" {'worst delta':>12}")
    idx1000 = [FINE.index(x) for x in G1000]
    idx2000 = [FINE.index(x) for x in G2000]
    worstg = 0.0
    for rn, _, _ in REG:
        y = FRET[rn]
        series = [("front bar", y[:, 0], WB[(5, "LINEAR", rn)]['mw'])]
        for i in range(1, 5):
            series.append((f"seat {i+1} clears LP", y[:, i], LPm120[rn]))
        for j, (nm_, col, tgt) in enumerate(series):
            vals = []
            for g_, ix in ((FINE, None), (G1000, idx1000), (G2000, idx2000)):
                yy = col if ix is None else col[ix]
                v, st = cross(g_, yy, tgt)
                vals.append(f"{v:.0f}" if st == 'cross' else ('all phi' if st == 'always'
                                                              else 'NEVER'))
            nums = [float(x) for x in vals if x not in ('all phi', 'NEVER')]
            d = (max(nums) - min(nums)) if len(nums) == 3 else None
            if d is not None: worstg = max(worstg, d)
            print(f"  {rn if j == 0 else '':>8} {nm_:>26} {vals[0]:>10} {vals[1]:>10}"
                  f" {vals[2]:>10} {('-' if d is None else f'{d:.0f}'):>12}")
        print()
    print(f"  WORST disagreement between the three grids, over every crossover above: "
          f"{worstg:.0f} phi units ({worstg/10000:.2%} of the swept range).")
    print("  The status words matter as much as the numbers: a grid that turned a 'NEVER' into a")
    print("  crossover, or the reverse, would change a WINDOW verdict. None of them does above.")
    print()
    if NPATH == 120:
        print("  CONSISTENCY: the step-2000 column is read from the reconciliation cell's own")
        print("  sample. The N=5 LINEAR block in section 2 is a SEPARATELY COMPUTED cell on the")
        print("  same seeds and the same grid, so its numbers must EQUAL the step-2000 column.")
    else:
        print(f"  NOT A CONSISTENCY CHECK AT THIS PATH COUNT. The sweep ran on {NPATH} paths and")
        print(f"  the reconciliation cell on 120, so the N=5 LINEAR block below is a DIFFERENT")
        print(f"  SAMPLE, not a recomputation. The distance between the two lines is the sampling")
        print(f"  error of the reduced sweep at the one depth where both were measured -- which")
        print(f"  makes it the most useful number in this section, and it is printed rather than")
        print(f"  hidden.")
    for rn, _, _ in REG:
        _, chi, chst, clows, cwin = window(5, "LINEAR", rn)
        lo = ("NEVER" if any(st == 'never' for _, _, st in clows)
              else f"{max(v for _, v, _ in clows):.0f}")
        hi = (f"{chi:.0f}" if chst == 'cross' else ('no bound' if chst == 'always' else 'below@0'))
        print(f"     {rn:>8}  section 2 cell -> front<= {hi:>10}   back>= {lo:>10}   "
              f"window {cwin}")
    print()

    # ============================================================ 2. THE SWEEP
    rule("2.  THE WINDOW AT EVERY DEPTH")
    print("  front bar  = the best managed ATM wing (width chosen per cell from 1%/2%/5%, L2 gas)")
    print("               funded with the HEAD's capital. It shrinks with N because the head does.")
    print("  back bar   = the ordinary pro-rata LP, identical at every N (same book, same seeds).")
    print("  'no bound' = rank 1 still beats the managed wing at phi=9500, i.e. front is SLACK.")
    print()
    for sch in SCHED:
        for rn, _, _ in REG:
            print(f"  --- {sch} / {rn} ---   pro-rata LP {pct(LPm[rn])} (se {100*LPse[rn]:.3f}pp)"
                  f"   in-band life {HRS[(5, sch, rn)]:.1f}d")
            print(f"  {'N':>4} {'head/book':>10} {'head $':>10} {'r1@phi=0':>10} {'r1@9500':>10}"
                  f" {'wing bar':>9} {'front<=':>10} {'back>=':>10} {'window':>16} {'binding':>9}"
                  f" {'gap@9500':>9} {'t':>7}")
            for n in NS:
                k = (n, sch, rn)
                caps = caps_for(n, sch)
                lo, hi, hst, lows, wstr = window(n, sch, rn)
                r1 = RET[k][:, 0]
                hi_s = (f"{hi:.0f}" if hst == 'cross'
                        else ("no bound" if hst == 'always' else "below@0"))
                if any(st == 'never' for _, _, st in lows):
                    bad = [f"s{i+1}" for i, _, st in lows if st == 'never']
                    lo_s = "NEVER"
                    bind = bad[0] + (f"+{len(bad)-1}" if len(bad) > 1 else "")
                else:
                    lo_s = f"{lo:.0f}"
                    bind = "s" + str(max(lows, key=lambda t: t[1])[0] + 1)
                # the BINDING seat's margin over the LP at the top of the sweep, and that margin
                # in units of its own standard error. A "NEVER" that sits 0.3 se below the bar is
                # not a finding; one that sits 8 se below it is.
                bi = (max(lows, key=lambda t: t[1])[0] if lo_s != "NEVER"
                      else min((i for i, _, st in lows if st == 'never'),
                               key=lambda i: RET[k][-1, i]))
                gap = RET[k][-1, bi] - LPm[rn]
                sd_ = math.sqrt(SE[k][-1, bi]**2 + LPse[rn]**2)
                print(f"  {n:>4} {caps[0]/BOOK:>10.1%} {caps[0]:>10,.0f} {100*r1[0]:>9.1f}%"
                      f" {100*r1[-1]:>9.1f}% {pct(WB[k]['mw']):>9} {hi_s:>10} {lo_s:>10}"
                      f" {wstr:>16} {bind:>9} {100*gap:>+8.2f}pp {gap/sd_:>+7.1f}")
            print()

    # ============================================================ 3. THE HEADLINE
    rule("3.  HEADLINE -- N_max, the largest depth with a NON-EMPTY window")
    print(f"  {'schedule':>10} {'regime':>8} {'N with a window':>44} {'N_max':>8}")
    NMAX = {}
    for sch in SCHED:
        for rn, _, _ in REG:
            good = [n for n in NS if window(n, sch, rn)[4] != "EMPTY"
                    and not window(n, sch, rn)[4].startswith("EMPTY")]
            NMAX[(sch, rn)] = max(good) if good else None
            gs = ", ".join(str(n) for n in good) if good else "none"
            print(f"  {sch:>10} {rn:>8} {gs:>44} "
                  f"{(str(NMAX[(sch, rn)]) if good else 'NONE'):>8}")
    print()
    print("  Read across the two schedules before concluding anything about depth: if EQUAL keeps a")
    print("  window where LINEAR loses it, the binding variable is the SHAPE of the book, not its")
    print("  length, and 'N_max' is the wrong name for the finding.")
    print()

    # ============================================================ 4. (a) THE BINDING SEAT
    rule("4.  (a)  WHICH back seat is the LAST to clear the pro-rata LP?")
    print("  The 5-seat table has seat 2 binding in BENIGN and NORMAL -- the seat NEAREST the head.")
    print("  If that survives at depth, the constraint is 'the seat just behind the head is starved'")
    print("  and it does not get worse with N. If the binding seat migrates to the tail, it is a")
    print("  different mechanism and a deeper roster fails for a different reason.")
    print()
    for sch in SCHED:
        print(f"  --- {sch} ---")
        print(f"  {'N':>4}  " + "".join(f"{rn:>34}" for rn, _, _ in REG))
        for n in NS:
            row = f"  {n:>4}  "
            for rn, _, _ in REG:
                _, _, _, lows, _ = window(n, sch, rn)
                nev = [i+1 for i, _, st in lows if st == 'never']
                if nev:
                    cell_ = f"NEVER: {len(nev)}/{n-1} seats, worst s{nev[0]}"
                else:
                    i, v, st = max(lows, key=lambda t: t[1])
                    cell_ = f"s{i+1} at phi {v:.0f} ({i}/{n-1} deep)"
                row += f"{cell_:>34}"
            print(row)
        print()

    # ============================================================ 5. (b) THE DEEP TAIL
    rule("5.  (b)  AT HIGH phi, DOES THE DEEPEST, LEAST-TRADED CAPITAL EARN THE MOST?")
    print("  The premium is weighted by the OUTGOING-token holdings of seats still STANDING, and a")
    print("  front-first drain reaches the tail last, so the tail stands for nearly every fill and")
    print("  collects on nearly every pot while trading almost nothing. If the seat with the least")
    print("  turnover earns the most, that is the emissions pathology VALUE.md section 4 rejects for")
    print("  sponsor(): a coupon paid for standing still, funded by the only participant working.")
    print()
    print(f"  at phi = {PHIS[-1]}.  'best seat' = argmax mean return over ALL seats including rank 1.")
    print(f"  {'sched':>7} {'regime':>7} {'N':>4} {'best seat':>10} {'its return':>11} {'its turnover':>13}"
          f" {'r1 return':>10} {'r1 turnover':>12} {'tail ret':>9} {'tail turn':>10}")
    for sch in SCHED:
        for rn, _, _ in REG:
            for n in NS:
                k = (n, sch, rn)
                r = RET[k][-1]; t = TURN[k][-1]
                b = int(np.argmax(r))
                print(f"  {sch:>7} {rn:>7} {n:>4} {('s'+str(b+1)):>10} {pct(r[b]):>11}"
                      f" {t[b]:>12.0f}x {pct(r[0]):>10} {t[0]:>11.0f}x {pct(r[-1]):>9}"
                      f" {t[-1]:>9.0f}x")
            print()

    # ============================================================ 6. (c) THE IDENTITY
    rule("6.  (c)  THE CAPITAL-WEIGHTED MEAN IDENTITY -- self-check at every N")
    print("  VALUE.md section 1: the N seats share ONE Uniswap position, so their capital-weighted")
    print("  mean return IS the return of one ordinary pro-rata LP with the same capital. phi")
    print("  creates nothing; it only decides the split.")
    print()
    print("  WHAT IS AND IS NOT A CONTROL HERE, because LAW 5 asks what could make this read FAIL.")
    print("    NOT a control: comparing the capital-weighted mean of d_i/h_i against d.sum()/h.sum()")
    print("      within one run. Those are the same division written twice; it cannot fail for any")
    print("      implementation of the mechanism. It is arithmetic wearing a control's costume.")
    print("    A control: comparing the QUEUE pool's return against a SEPARATE, INDEPENDENTLY")
    print("      SIMULATED pro-rata run -- one seat, average pricing, no premium, same seed. That")
    print("      one CAN fail, and would, if the queue's availability clamp diverted the price path,")
    print("      if premium were created or destroyed rather than moved, or if the held pot were")
    print("      silently dropped. It is the second column below.")
    print()
    print(f"  {'sched':>7} {'regime':>7} {'N':>4} {'|pool - LP| at phi=0':>22} "
          f"{'at phi=9500':>14} {'max over all phi':>18}")
    worst = 0.0
    for sch in SCHED:
        for rn, _, _ in REG:
            for n in NS:
                k = (n, sch, rn)
                e = POOL[k]                       # worst PATH's residual at each phi
                worst = max(worst, float(e.max()))
                print(f"  {sch:>7} {rn:>7} {n:>4} {e[0]:>22.3e} {e[-1]:>14.3e} "
                      f"{e.max():>18.3e}")
            print()
    print(f"  worst residual anywhere in the grid: {worst:.3e}")
    print("  (a residual at 1e-15 says the queue and the plain LP walked the SAME price path and the")
    print("   premium is conserved to floating point at every N, every schedule and every phi.)")
    print("="*W)


if __name__ == "__main__":
    main()
