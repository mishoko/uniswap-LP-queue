"""SEAT COUNT AT A FIXED HEAD SHARE -- the un-confounded depth sweep (PITFALLS 5.189).

`results-depth-basis.txt` section 3 concludes that 16 and 32 seats have no feasible phi.  Its sweep
moves the seat count AND the head share together -- the head runs 66.7% -> 6.1% across it -- and
`results-headsize.txt` then establishes head share as the DOMINANT parameter.  So the published
result cannot separate "too many seats" from "too small a head".  This file holds c1 = 45% FIXED,
which is the shipped head, and varies ONLY N.

The instrument is deliberately the LOWER BOUND ONLY: the first phi at which every back seat beats a
passive pro-rata LP.  That is enough to settle feasibility, because if no phi clears the back at
all, the window is empty whatever the front's ceiling turns out to be.  A non-empty lower bound
would then need the wing bar before anything is claimed.

CONTROL, and it must be read before any other row: the N=5 row is a KNOWN ANSWER.  It has to
reproduce results-headsize.txt's BENIGN back bound of 3777 at c1 = 45%.
"""
import sys, os, time
sys.path.insert(0, '/Users/mishoko/projects/UHI10/docs/research/seat-economics')
import numpy as np, sim
BASIS = 'liquidity_excl'
sim.PREM_WEIGHT = BASIS
from sim import run
from report_depth import BOOK, RPH, HALF, REG, SEEDS, PHIS, cross, lp_cell

C1    = 0.45
NS    = tuple(int(x) for x in os.environ.get("NS", "5,8,16,32").split(","))
NSEED = int(os.environ.get("NSEED", "40"))
SD    = SEEDS[:NSEED]

def _init():
    import sim as _s; _s.PREM_WEIGHT = BASIS

SHAPE = os.environ.get("SHAPE", "decay")

def caps_flat(n):
    """c1 = 45% of the book. The other 55% is split over the remaining n-1 seats, either EQUALLY
    or on a LINEARLY DECLINING ladder (n-1, n-2, ... 1) normalised to 55%.

    The decaying shape is the one that REPRODUCES THE PUBLISHED CONTROL: at n = 5 it gives
    weights 90 : 44 : 33 : 22 : 11, which is exactly the shipped roster and exactly the row
    results-headsize.txt reports at c1 = 45%. Both shapes are run so that no conclusion rests on
    one arbitrary choice of ladder."""
    back = (1.0-C1)*BOOK
    if SHAPE == "equal":
        w = [1.0]*(n-1)
    else:
        w = [float(n-1-i) for i in range(n-1)]   # n-1, n-2, ... 1
    tot = sum(w)
    return [C1*BOOK] + [back*x/tot for x in w]

def cell(a):
    n, vol, dr, seed = a
    import sim as _s; _s.PREM_WEIGHT = BASIS
    caps = caps_flat(n)
    R = np.zeros((len(PHIS), n)); T = np.zeros((len(PHIS), n))
    for j, phi in enumerate(PHIS):
        bk, _, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                        half=HALF, phi=phi)
        assert bk.weight == BASIS, "the basis switch did not reach this worker"
        bk.tie_out(Pt)
        d, h = bk.pnl(Pt)
        R[j] = d/h
        T[j] = ((bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1))/h
    return R, T

def main():
    from multiprocessing import Pool
    nproc = max(1, (os.cpu_count() or 4) - 1)
    print("="*100)
    print("THE DEPTH SWEEP WITH THE HEAD SHARE HELD FIXED  (PITFALLS 5.189)")
    print("="*100)
    print(f"  c1 = {C1:.0%} FIXED at every N; the other 55% split EQUALLY over the remaining seats.")
    print(f"  book ${BOOK:,.0f} - band +/-{HALF:.0%} - retail {RPH}/hr - premium basis {BASIS!r}")
    print(f"  {NSEED} paths per cell - phi grid {PHIS} - back-ladder shape {SHAPE!r}")
    print("  Regimes copied verbatim from report_depth.REG:", REG)
    print()
    print("  READ THE CONTROL FIRST. The N=5 BENIGN back bound must reproduce 3777 from")
    print("  results-headsize.txt at c1 = 45%. If it does not, this harness is not that harness")
    print("  and every other number below is void.")
    print()
    with Pool(nproc, initializer=_init) as p:
        LP = {}
        for rn, v, dr in REG:
            LP[rn] = np.array(p.map(lp_cell, [(v, dr, s) for s in SD]))
        for rn, v, dr in REG:
            lpm = float(LP[rn].mean())
            print("="*100)
            print(f"  --- {rn} ---   passive pro-rata LP {lpm:+.2%}   ({NSEED} paths)")
            print(f"  {'N':>4} {'head':>7} {'seats>=LP@best':>15} {'back bound':>12} {'worst seat':>11} "
                  f"{'its gap pp':>11} {'turnover':>9} {'r1@best':>9} {'r1@9500':>9} {'VERDICT':>22}")
            for n in NS:
                res = p.map(cell, [(n, v, dr, s) for s in SD])
                R = np.stack([r for r, _ in res])       # (seed, phi, seat)
                T = np.stack([t for _, t in res])
                firsts, status = [], []
                for i in range(1, n):                    # every BACK seat
                    ys = [float(R[:, j, i].mean()) for j in range(len(PHIS))]
                    c, st = cross(PHIS, ys, lpm)
                    firsts.append(c); status.append(st)
                never = [i+1 for i, st in enumerate(status) if st == 'never']
                # the best phi on the grid = the one clearing the most back seats
                clears = [sum(1 for i in range(1, n) if float(R[:, j, i].mean()) > lpm)
                          for j in range(len(PHIS))]
                jbest = int(np.argmax(clears))
                gaps = [(float(R[:, jbest, i].mean()) - lpm, i) for i in range(1, n)]
                worstgap, wi = min(gaps)
                if never:
                    bound, verdict = "NEVER", f"EMPTY ({len(never)} seats)"
                else:
                    bound = f"{max(firsts):.0f}"; verdict = "back clears"
                r1b = float(R[:, jbest, 0].mean()); r1e = float(R[:, -1, 0].mean())
                print(f"  {n:>4} {C1:>6.1%} {clears[jbest]:>8}/{n-1:<6} {bound:>12} {'s'+str(wi+1):>11} "
                      f"{worstgap*100:>+11.3f} {float(T[:, jbest, wi].mean()):>9.2f} "
                      f"{r1b:>+9.2%} {r1e:>+9.2%} {verdict:>22}")
            print()

if __name__ == "__main__":
    t = time.time(); main(); print(f"  [{time.time()-t:.0f}s]")
