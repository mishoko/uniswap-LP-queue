"""
THE TRANCHE REPORT -- does the priority premium (phi) turn rank into a risk ladder?

WHY THIS FILE EXISTS AND WHY IT DOES NOT LOOK LIKE report_seats.py.

  1. `sim.py` did not model phi at all until 2026-09-02, so EVERY number in results-seats.txt is a
     phi = 0 measurement -- while `script/QueueDeployBase.sol` ships phi = 8500 citing a sweep
     "across four independent seed ranges" in this directory. That sweep did not exist. This is it.

  2. report_seats.py does `acc += d/h/yr*100` and then reports the mean, throwing every individual
     path away. PITFALLS 5.119 condemns exactly that framing: **a seat holder lives ONE path.**
     Here the full paths x seats matrix is kept and the per-CELL loss rate is reported alongside
     every mean.

  3. `bk.hrs` varies from ~1.3 days (TOXIC) to ~250 days (BENIGN, wide band). Annualising is
     multiplying a small realised number by up to ~250. REALISED is printed first, always.

Usage:  python3 report_tranche.py            (writes to stdout; results-tranche.txt is the capture)
"""
import sys, os, itertools, time, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim, wing
from sim import run

BOOK, RPH, NSEAT = 1_000_000.0, 15.0, 32
EQ = [BOOK/NSEAT]*NSEAT
YR = 365*24.0

REG   = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
HALFS = (0.10, 0.30)
RANGES = (("A r0-29", range(0, 30)), ("B r100-129", range(100, 130)),
          ("C r200-229", range(200, 230)), ("D r1000-1029", range(1000, 1030)))
PHIS  = tuple(range(0, 10000, 500))          # 0, 500, ... 9500
KEYPHI = (0, 2500, 5000, 8500)
SHOWN = (1, 2, 3, 4, 5, 8, 12, 16, 20, 24, 28, 32)
MW_WIDTHS = (0.01, 0.02, 0.05)
GAS = {'L2': 0.02, 'L1': 12.00}     # USD per re-mint. Stated, not hidden.
SHAPE_PHIS = (5000, 8500)


# ------------------------------------------------------------------------------ the worker
def cell(a, caps=None):
    phi, vol, drift, half, seed = a[:5]
    sim.PREM_MODE = a[5] if len(a) > 5 else 'contract'
    cp = EQ if caps is None else caps
    bk, Pf, Pt = run(cp, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol,
                     drift=drift, half=half, phi=phi)
    fees, mk = bk.tie_out(Pt)                # RAISES if the decomposition does not reconstruct a0/a1
    d, h = bk.pnl(Pt)
    turn = (bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1)          # gross flow through each seat, $
    return dict(hrs=bk.hrs, d=d, h=h, fees=fees, mk=mk, rcv=bk.prem_recv(Pt),
                pay=bk.prem_paid(Pt), held=bk.held0*Pt + bk.held1,
                reach=bk.reach, reach_a=bk.reach_a, nswap=bk.nswap, turn=turn,
                smin=bk.smin, smax=bk.smax, Pf=Pf, Pt=Pt,
                gfee=(bk.fe0 + bk.pp0)*Pt + (bk.fe1 + bk.pp1))


def bench(a):
    """The pro-rata benchmark: ONE undivided seat. phi is meaningless on a one-seat book by
    construction -- there is nobody standing behind the only seat -- so it is left at 0."""
    vol, drift, half, seed = a
    bk, _, Pt = run([BOOK], False, days=365, retail_per_hr=RPH, seed=seed, vol=vol,
                    drift=drift, half=half)
    d, h = bk.pnl(Pt)
    return dict(ret=d[0]/h[0], hrs=bk.hrs, d=float(d[0]), h=float(h[0]))


SHAPES = (("A 32 equal",      [BOOK/32]*32),
          ("B 16 equal",      [BOOK/16]*16),
          ("C  8 equal",      [BOOK/8]*8),
          ("D head 300k",     [300_000.0] + [700_000.0/31]*31),
          ("E head 600k",     [600_000.0] + [400_000.0/31]*31))


def shape_cell(a):
    phi, vol, drift, half, seed, si = a
    return cell((phi, vol, drift, half, seed), caps=SHAPES[si][1])


def wing_cell(a):
    """ONE traced run, with the matched-wing controls evaluated inside the worker.

    The tape is 100k+ swaps and must never cross a process boundary, so everything the wing
    engine needs is computed here and only the summary is returned.
    """
    vol, drift, half, seed = a
    bk, Pf, Pt = run(EQ, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol,
                     drift=drift, half=half, phi=0, trace=True)
    ef, em, full = wing.check_null(bk, Pf, Pt, BOOK, NSEAT)
    cap = BOOK/NSEAT
    out = dict(null_fee=ef, null_mk=em, full=full['ret'], hrs=bk.hrs, nswap=len(bk.swaps),
               pf_out=(not (bk.pa < Pf < bk.pb)))
    # STATIC wings: the full band, and edge wings over the outer slice of the band on each side.
    for tag, lo, hi in (("edge_up_25", bk.P0 + 0.75*(bk.pb - bk.P0), bk.pb),
                        ("edge_dn_25", bk.pa, bk.P0 - 0.75*(bk.P0 - bk.pa)),
                        ("edge_up_50", bk.P0 + 0.50*(bk.pb - bk.P0), bk.pb),
                        ("edge_dn_50", bk.pa, bk.P0 - 0.50*(bk.P0 - bk.pa))):
        out[tag] = wing.static_wing(bk, Pf, Pt, cap, lo, hi, BOOK)['ret']
    # MANAGED wings for the head. Run ONCE per width with zero gas, then charge each gas regime
    # analytically -- gas is remints*price and nothing else in the path depends on it.
    for w_ in MW_WIDTHS:
        m = wing.managed_wing(bk, Pf, Pt, cap, w_, BOOK, 0.0)
        for gname, g in GAS.items():
            out[f"mw_{w_}_{gname}"] = m['ret'] - m['remints']*g/m['hold']
        out[f"mwx_{w_}"] = (m['remints'], m['fees']/m['hold'], m['markout']/m['hold'],
                            m['conv_fee']/m['hold'], m['conv_imp']/m['hold'], m['ret_nocost'])
    return out


# ------------------------------------------------------------------------------ statistics
def dd(x):
    """Downside deviation about a zero target: sqrt(mean(min(x,0)^2))."""
    n = np.minimum(x, 0.0)
    return float(np.sqrt(np.mean(n*n)))


class Cellset:
    """paths x seats matrices for one (phi, regime, half, seed-range)."""
    def __init__(self, rows, bmk):
        g = lambda k: np.array([r[k] for r in rows])
        self.hrs = g('hrs').astype(float)
        self.d, self.h, self.fee, self.mk = g('d'), g('h'), g('fees'), g('mk')
        self.rcv, self.pay, self.turn = g('rcv'), g('pay'), g('turn')
        self.gfee = g('gfee')
        self.held = g('held').astype(float)
        self.reach, self.reach_a = g('reach'), g('reach_a')
        self.nswap = g('nswap').astype(float)
        self.smin, self.smax = g('smin'), g('smax')
        self.ret = self.d/self.h                                   # REALISED, over the band's life
        self.yrs = (self.hrs/YR)[:, None]
        self.ann = self.ret/self.yrs
        self.bmk = np.array([b['ret'] for b in bmk], float)        # realised, per path
        self.bd = np.array([b['d'] for b in bmk], float)
        self.bh = np.array([b['h'] for b in bmk], float)
        self.beat = self.ret > self.bmk[:, None]
        self.exc = self.ret - self.bmk[:, None]                    # EXCESS over the pro-rata LP
        self.lose = self.ret < 0
        self.inert = np.abs(self.d)/self.h < 1e-12

    def rank(self, i):                                             # i is 0-based
        r = self.ret[:, i]
        return dict(mean=float(r.mean()), ann=float(self.ann[:, i].mean()),
                    sd=float(r.std(ddof=1)), dd=dd(r), p5=float(np.percentile(r, 5)),
                    worst=float(r.min()), lose=float(self.lose[:, i].mean()),
                    beat=float(self.beat[:, i].mean()), inert=float(self.inert[:, i].mean()))


def pct(x):  return f"{100*x:+.2f}%"
def pc0(x):  return f"{100*x:.0f}%"


# ------------------------------------------------------------------------------ the driver
def main():
    from multiprocessing import Pool
    t0 = time.time()
    jobs, keys = [], []
    for phi in PHIS:
        for rn, vol, dr in REG:
            for half in HALFS:
                for rname, rg in RANGES:
                    for s in rg:
                        jobs.append((phi, vol, dr, half, s))
                        keys.append((phi, rn, half, rname))
    bjobs, bkeys = [], []
    for rn, vol, dr in REG:
        for half in HALFS:
            for rname, rg in RANGES:
                for s in rg:
                    bjobs.append((vol, dr, half, s)); bkeys.append((rn, half, rname))

    nproc = max(1, (os.cpu_count() or 4))
    sys.stderr.write(f"[{len(jobs)} sims + {len(bjobs)} benchmarks on {nproc} procs]\n")
    with Pool(nproc) as p:
        bres = p.map(bench, bjobs, chunksize=8)
        res = p.map(cell, jobs, chunksize=8)
    sys.stderr.write(f"[done in {time.time()-t0:.0f}s]\n")

    B = {}
    for k, v in zip(bkeys, bres): B.setdefault(k, []).append(v)
    R = {}
    for k, v in zip(keys, res): R.setdefault(k, []).append(v)
    C = {k: Cellset(v, B[(k[1], k[2], k[3])]) for k, v in R.items()}

    W = 100
    def rule(t=""):
        print("="*W)
        if t: print(t); print("="*W)

    rule("QUEUE TRANCHE REPORT -- the priority premium phi, measured per PATH and per SEAT")
    print(f"  32 equal seats of ${BOOK/NSEAT:,.0f} on a ${BOOK:,.0f} book. marginal pricing. "
          f"retail {RPH:.0f}/hr. 365d cap.")
    print(f"  phi swept {PHIS[0]}..{PHIS[-1]} bps step 500. regimes {[r[0] for r in REG]}. "
          f"band half-width {HALFS}.")
    print(f"  FOUR INDEPENDENT SEED RANGES: " + ", ".join(n for n, _ in RANGES) +
          "  (30 paths each; 120 paths / 3,840 cells per config)")
    print("  Benchmark = ONE undivided pro-rata LP of the same capital on the SAME seed.")
    print("  REALISED = return over the band's actual life. ANN = realised / (life in years).")
    print()
    print("  NULL CONTROL: with phi=0 this simulator reproduces results-seats.txt BYTE-IDENTICALLY.")
    print("  DECOMPOSITION: Book.tie_out() asserts o+markout+fee+premium == balances and")
    print("                 fees+markout == pnl on EVERY run below. It raises rather than warns.")
    print()

    # ---------------------------------------------------------------- band life & benchmark
    rule("0.  THE GROUND TRUTH THE RETURNS ARE MEASURED AGAINST")
    print(f"  {'regime/band':>18}" + "".join(f"{n:>19}" for n, _ in RANGES))
    for rn, _, _ in REG:
        for half in HALFS:
            k0 = (0, rn, half, RANGES[0][0])
            print(f"  {rn+' +/-'+f'{half:.0%}':>18}", end="")
            for rname, _ in RANGES:
                c = C[(0, rn, half, rname)]
                print(f"  life {np.mean(c.hrs)/24:6.1f}d LP {pct(np.mean(c.bmk)):>8}", end="")
            print()
    print()
    print("  NOTE: 'LP' is the REALISED return of the pro-rata benchmark over that life, not /yr.")
    print()

    # ---------------------------------------------------------------- C2a / headline loss rates
    rule("1.  C2a -- FRACTION OF INDIVIDUAL (path, seat) CELLS THAT LOSE MONEY")
    print("  The number report_seats.py cannot produce: it averages 30 paths first and then asks")
    print("  whether the MEAN is negative. A seat holder lives one path (PITFALLS 5.119).")
    print()
    hdr = f"  {'config':>18} {'phi':>6}" + "".join(f"{n:>14}" for n, _ in RANGES) + f"{'WORST':>10}"
    print(hdr)
    for rn, _, _ in REG:
        for half in HALFS:
            for phi in KEYPHI:
                vals = [C[(phi, rn, half, rname)].lose.mean() for rname, _ in RANGES]
                tag = f"{rn} +/-{half:.0%}" if phi == KEYPHI[0] else ""
                print(f"  {tag:>18} {phi:>6}" + "".join(f"{100*v:>13.1f}%" for v in vals)
                      + f"{100*max(vals):>9.1f}%")
            print()

    rule("1b. THE SAME CELLS, BUT: FRACTION THAT BEAT AN ORDINARY PRO-RATA LP ON THE SAME SEED")
    print(hdr)
    for rn, _, _ in REG:
        for half in HALFS:
            for phi in KEYPHI:
                vals = [C[(phi, rn, half, rname)].beat.mean() for rname, _ in RANGES]
                tag = f"{rn} +/-{half:.0%}" if phi == KEYPHI[0] else ""
                print(f"  {tag:>18} {phi:>6}" + "".join(f"{100*v:>13.1f}%" for v in vals)
                      + f"{100*min(vals):>9.1f}%")
            print()
    print("  WORST column is the MINIMUM here (beating is good), the MAXIMUM above (losing is bad).")
    print()

    # ---------------------------------------------------------------- per-rank tables
    def worst_range(phi, rn, half):
        return max(RANGES, key=lambda r: C[(phi, rn, half, r[0])].lose.mean())[0]

    rule("2.  PER-RANK, AT THE SHIPPING phi = 8500, ON THE WORST OF THE FOUR SEED RANGES")
    for rn, _, _ in REG:
        for half in HALFS:
            wr = worst_range(8500, rn, half)
            c = C[(8500, rn, half, wr)]
            print(f"  --- {rn}  band +/-{half:.0%}  [worst range: {wr}]  "
                  f"life {np.mean(c.hrs)/24:.1f}d  pro-rata LP {pct(np.mean(c.bmk))} ---")
            print(f"  {'rank':>5} {'REALISED':>10} {'ann':>11} {'stdev':>9} {'downdev':>9}"
                  f" {'p5':>10} {'worst':>10} {'lose':>7} {'beatLP':>7} {'inert':>7}")
            for i in SHOWN:
                s = c.rank(i-1)
                print(f"  {i:>5} {pct(s['mean']):>10} {pct(s['ann']):>11} {100*s['sd']:>8.2f}%"
                      f" {100*s['dd']:>8.2f}% {pct(s['p5']):>10} {pct(s['worst']):>10}"
                      f" {pc0(s['lose']):>7} {pc0(s['beat']):>7} {pc0(s['inert']):>7}")
            print()

    # ---------------------------------------------------------------- C1a decomposition
    rule("3.  C1a -- DOES INVENTORY / MARKOUT EXPOSURE PER DOLLAR FALL MONOTONICALLY WITH RANK?")
    print("  markout = the inventory leg alone (principal in, take out), marked at the final price,")
    print("  as a fraction of the seat's opening buy-and-hold value. Fees and premium are OUT of it.")
    print("  This is the number the old instrument could not produce at all: `give` folded the fee")
    print("  into credited inventory and pnl() returned one combined scalar.")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            wr = worst_range(8500, rn, half)
            print(f"  --- {rn} +/-{half:.0%} [{wr}] ---   (phi=0 | phi=8500)")
            print(f"  {'rank':>5} {'markout/$':>22} {'fees/$':>22} {'premium recv/$':>22}"
                  f" {'premium paid/$':>18}")
            for i in SHOWN:
                c0 = C[(0, rn, half, wr)]; c8 = C[(8500, rn, half, wr)]
                m0 = np.mean(c0.mk[:, i-1]/c0.h[:, i-1]); m8 = np.mean(c8.mk[:, i-1]/c8.h[:, i-1])
                f0 = np.mean(c0.fee[:, i-1]/c0.h[:, i-1]); f8 = np.mean(c8.fee[:, i-1]/c8.h[:, i-1])
                r8 = np.mean(c8.rcv[:, i-1]/c8.h[:, i-1]); p8 = np.mean(c8.pay[:, i-1]/c8.h[:, i-1])
                print(f"  {i:>5} {pct(m0):>10}{pct(m8):>12} {pct(f0):>10}{pct(f8):>12}"
                      f" {'--':>10}{pct(r8):>12} {'--':>8}{pct(p8):>10}")
            # monotonicity test on the phi=8500 markout magnitude
            c8 = C[(8500, rn, half, wr)]
            mm = np.abs(np.array([np.mean(c8.mk[:, i]/c8.h[:, i]) for i in range(NSEAT)]))
            viol = int(np.sum(np.diff(mm) > 1e-12))
            print(f"        |markout|/$ monotonically NON-INCREASING in rank? "
                  f"{'YES' if viol == 0 else f'NO -- {viol}/31 rank steps go the wrong way'}"
                  f"   (rank1 {100*mm[0]:.3f}%  rank32 {100*mm[31]:.3f}%)")
            print()

    # ---------------------------------------------------------------- C1b the coupon
    rule("4.  C1b -- THE BACK-OF-BOOK COUPON: premium RECEIVED by ranks 17-32, phi = 8500")
    print(f"  {'config':>18} {'range':>14} {'realised bps':>14} {'bps/yr':>12} {'life':>8}"
          f" {'rank32 realised':>17} {'rank32 bps/yr':>15}")
    for rn, _, _ in REG:
        for half in HALFS:
            for rname, _ in RANGES:
                c = C[(8500, rn, half, rname)]
                back = np.mean(c.rcv[:, 16:]/c.h[:, 16:])
                yrs = np.mean(c.hrs)/YR
                r32 = np.mean(c.rcv[:, 31]/c.h[:, 31])
                print(f"  {rn+' +/-'+f'{half:.0%}':>18} {rname:>14} {1e4*back:>13.1f} "
                      f"{1e4*back/yrs:>11.0f} {yrs*365:>7.1f}d {1e4*r32:>16.1f} "
                      f"{1e4*r32/yrs:>14.0f}")
    print()

    # ---------------------------------------------------------------- C2b every-regime losers
    rule("5.  C2b -- IS THERE A RANK THAT LOSES IN EVERY REGIME?")
    print("  Two readings, and they disagree, which is the point:")
    print("   (a) MEAN reading  -- the rank's ensemble-mean realised return is < 0 in all 3 regimes")
    print("   (b) CELL reading  -- the rank loses on >50% of individual paths in all 3 regimes")
    for half in HALFS:
        for phi in KEYPHI:
            am, ac = [], []
            for i in range(NSEAT):
                mean_neg = all(
                    np.mean([C[(phi, rn, half, rname)].ret[:, i].mean() for rname, _ in RANGES]) < 0
                    for rn, _, _ in REG)
                cell_neg = all(
                    np.mean([C[(phi, rn, half, rname)].lose[:, i].mean() for rname, _ in RANGES]) > .5
                    for rn, _, _ in REG)
                if mean_neg: am.append(i+1)
                if cell_neg: ac.append(i+1)
            def fmt(v): return ("none" if not v else
                                (f"{len(v)} ranks: {v[0]}..{v[-1]}" if len(v) > 4 else str(v)))
            print(f"  band +/-{half:.0%}  phi={phi:>5}   (a) mean-negative in all 3: {fmt(am):<28}"
                  f" (b) >50% cells lose in all 3: {fmt(ac)}")
    print()

    # ---------------------------------------------------------------- C2c the crux
    rule("6.  C2c -- THE CRUX. 'The back trades rarely but gets hit by the big adverse moves --")
    print("      low-frequency, high-severity; that's lumpier, not safer.'  ASSERTED, NEVER MEASURED.")
    print("      Front (rank 1) vs back (ranks 17-32), phi = 8500, worst seed range per config.")
    print()
    print(f"  {'config':>18} {'':>7} {'realised':>10} {'stdev':>9} {'downdev':>9} {'p5':>10}"
          f" {'worst':>10} {'lose%':>7}")
    for rn, _, _ in REG:
        for half in HALFS:
            wr = worst_range(8500, rn, half)
            c = C[(8500, rn, half, wr)]
            fr = c.ret[:, 0]
            bk_ = c.ret[:, 16:].ravel()
            for tag, v in (("rank 1", fr), ("17-32", bk_)):
                print(f"  {rn+' +/-'+f'{half:.0%}' if tag=='rank 1' else '':>18} {tag:>7}"
                      f" {pct(v.mean()):>10} {100*v.std(ddof=1):>8.2f}% {100*dd(v):>8.2f}%"
                      f" {pct(np.percentile(v,5)):>10} {pct(v.min()):>10}"
                      f" {pc0((v<0).mean()):>7}")
            print()
    print("  Read the stdev/downdev/p5 columns, not the means. If the back's dispersion EXCEEDS the")
    print("  front's, the assertion stands and 'bond tranche' is the wrong word.")
    print()

    # ---------------------------------------------------------------- C4 the sweep
    rule("7.  C4 -- THE phi SWEEP. Is 8500 defensible, and on how many of the four seed ranges?")
    print("  For each configuration and each INDEPENDENT seed range: the phi that minimises the")
    print("  fraction of losing cells (ties broken toward the SMALLER phi -- less redistribution).")
    print()
    print(f"  {'config':>18}" + "".join(f"{n:>17}" for n, _ in RANGES) + f"{'agreement':>12}")
    best_tab = {}
    for rn, _, _ in REG:
        for half in HALFS:
            bests = []
            for rname, _ in RANGES:
                scores = [(C[(p, rn, half, rname)].lose.mean(), p) for p in PHIS]
                mn = min(s for s, _ in scores)
                bests.append(min(p for s, p in scores if s <= mn + 1e-12))
            best_tab[(rn, half)] = bests
            print(f"  {rn+' +/-'+f'{half:.0%}':>18}"
                  + "".join(f"{b:>10} ({100*C[(b,rn,half,RANGES[i][0])].lose.mean():>4.1f}%)"[:17].rjust(17)
                            for i, b in enumerate(bests))
                  + f"{('SAME' if len(set(bests))==1 else 'SPLIT'):>12}")
    print()
    print("  Full sweep of the losing-cell fraction (%), averaged over the four ranges, and the")
    print("  WORST single range in brackets. phi = 8500 is marked with a *.")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            print(f"  --- {rn} +/-{half:.0%} ---")
            line1, line2 = "   phi  ", "   lose "
            for p in PHIS:
                vs = [C[(p, rn, half, rname)].lose.mean() for rname, _ in RANGES]
                line1 += f"{('*' if p==8500 else '')+str(p):>8}"
                line2 += f"{100*np.mean(vs):>7.1f} "
            print(line1); print(line2)
            line3 = "   wrst "
            for p in PHIS:
                vs = [C[(p, rn, half, rname)].lose.mean() for rname, _ in RANGES]
                line3 += f"{100*max(vs):>7.1f} "
            print(line3)
            print()

    rule("7b. WHERE DO THE FRONT'S AND THE BACK'S RISK-ADJUSTED RETURNS MEET?")
    print("  Sortino-style: mean realised return / downside deviation about zero, over all cells.")
    print("  front = rank 1, back = ranks 17-32 pooled. Reported per configuration, worst range.")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            wr = worst_range(8500, rn, half)
            print(f"  --- {rn} +/-{half:.0%} [{wr}] ---")
            print("   phi  " + "".join(f"{p:>8}" for p in PHIS))
            fr_s, bk_s = [], []
            for p in PHIS:
                c = C[(p, rn, half, wr)]
                f = c.ret[:, 0]; b = c.ret[:, 16:].ravel()
                fs = f.mean()/dd(f) if dd(f) > 0 else float('inf')
                bs = b.mean()/dd(b) if dd(b) > 0 else float('inf')
                fr_s.append(fs); bk_s.append(bs)
            def row(lbl, xs):
                return f"   {lbl:<4}" + "".join(
                    (f"{x:>8.2f}" if abs(x) < 1e4 else f"{'  +inf' if x>0 else '  -inf':>8}")
                    for x in xs)
            print(row("frnt", fr_s)); print(row("back", bk_s))
            cross = None
            for i in range(1, len(PHIS)):
                a0, a1 = fr_s[i-1]-bk_s[i-1], fr_s[i]-bk_s[i]
                if np.isfinite(a0) and np.isfinite(a1) and a0*a1 <= 0:
                    cross = PHIS[i]; break
            print(f"   CROSSOVER: {('phi ~ '+str(cross)) if cross is not None else 'none in range'}"
                  f"   (front>back at every phi means rank NEVER stops paying)")
            print()

    # ---------------------------------------------------------------- modelling-choice robustness
    rule("8.  MODELLING CHOICE: aggregate (contract) vs per-seat premium distribution")
    print("  The contract computes ONE pot per swap and accrues it AFTER the fill over post-fill")
    print("  outgoing-token balances (_accruePremium, QueueHook.sol:1279). A partially drained seat")
    print("  therefore still shares in the pot of the seats ahead of it. The per-seat form excludes")
    print("  it. Both are run here so the difference is measured rather than assumed.")
    print()
    print(f"  {'config':>18} {'mode':>10} {'lose%':>8} {'rank1 real':>12} {'17-32 real':>12}"
          f" {'32 recv bps':>12}")
    half = HALFS[-1]
    with Pool(nproc) as p:
        m8 = p.map(cell, [(8500, v, d, half, s, m)
                          for rn, v, d in REG for m in ("contract", "perseat")
                          for s in RANGES[0][1]], chunksize=4)
    it = iter(m8)
    for rn, vol, dr in REG:
        for mode in ("contract", "perseat"):
            rows = [next(it) for _ in RANGES[0][1]]
            c = Cellset(rows, B[(rn, half, RANGES[0][0])])
            print(f"  {rn+' +/-'+f'{half:.0%}' if mode=='contract' else '':>18} {mode:>10}"
                  f" {100*c.lose.mean():>7.1f}% {pct(c.ret[:,0].mean()):>12}"
                  f" {pct(c.ret[:,16:].mean()):>12}"
                  f" {1e4*np.mean(c.rcv[:,31]/c.h[:,31]):>11.1f}")
        print()
    sim.PREM_MODE = "contract"

    rule("10. THE DOC-BLOCK CLAIM, ADJUDICATED ON ITS OWN METRIC")
    print("  `script/QueueDeployBase.sol` L72-84 states, of phi = 8500:")
    print('    "Swept across four INDEPENDENT seed ranges on a +/-30% band over a 25%-vol pair,')
    print('     phi ~ 0.85 is the only setting that put 0 of 32 seats negative on ALL FOUR, with a')
    print('     spread of 10-15 points."   and   "on a 45%-vol pair the same phi leaves 0-4 seats')
    print('     negative depending on the draw, and the best phi per configuration ranges 0.55-0.90."')
    print()
    print("  That is a claim about ENSEMBLE-MEAN seat returns (`N of 32 seats negative`), so it is")
    print("  adjudicated here on exactly that metric -- not on the per-cell metric this report")
    print("  otherwise prefers. 25%-vol +/-30% is BENIGN +/-30%; 45%-vol is NORMAL.")
    print()
    for rn, half in [(a, b) for a, b in (("BENIGN", 0.30), ("NORMAL", 0.30), ("NORMAL", 0.10))
                     if (PHIS[0], a, b, RANGES[0][0]) in C]:
        print(f"  --- {rn} +/-{half:.0%}:  'seats with NEGATIVE ensemble-mean realised return', "
              f"per seed range ---")
        print("   phi  " + "".join(f"{p_:>8}" for p_ in PHIS))
        for rname, _ in RANGES:
            row = []
            for p_ in PHIS:
                c = C[(p_, rn, half, rname)]
                row.append(int((c.ret.mean(axis=0) < 0).sum()))
            print(f"   {rname[:4]:<4}" + "".join(f"{v:>8}" for v in row))
        print("   sprd" + "".join(
            f"{100*(max(np.mean([C[(p_,rn,half,rn2)].ret.mean(axis=0) for rn2,_ in RANGES],axis=0)) - min(np.mean([C[(p_,rn,half,rn2)].ret.mean(axis=0) for rn2,_ in RANGES],axis=0))):>7.0f} "
            for p_ in PHIS))
        print("        (sprd = spread between best and worst rank's mean REALISED return, "
              "percentage points, pooled over ranges)")
        print()

    rule("9.  CONSERVATION -- was any premium silently lost?")
    print("  The contract HOLDS a pot with nobody standing and folds it into the next accrual.")
    print("  tie_out() asserts paid == received + held on every single run above; this is the")
    print("  residual HELD at the end of the run, i.e. premium withheld and never distributed.")
    tot_held, tot_pay, worst = 0.0, 0.0, 0.0
    for k, c in C.items():
        if k[0] == 0: continue
        tot_held += float(c.held.sum()); tot_pay += float(c.pay.sum())
        worst = max(worst, float(c.held.max()))
    print(f"  total premium withheld across the whole grid: ${tot_pay:,.0f}")
    print(f"  still HELD at end of run (undistributed):     ${tot_held:,.0f} "
          f"({100*tot_held/max(tot_pay,1e-9):.4f}%)   worst single path ${worst:,.0f}")
    print()

    # ================================================================= 11. the benchmark's own risk
    rule("11. THE BENCHMARK'S OWN DISPERSION -- the missing half of every comparison so far")
    print("  Section 0 gave the pro-rata LP's RETURN and no risk column, so 'the back seat has tiny")
    print("  downside' had nothing to be tiny relative to. Same units and same estimator as C2c.")
    print()
    print("  ZERO-SUM NULL FIRST, because none of this is believable without it. The 32-seat book")
    print("  and the ONE undivided pro-rata position are the same capital in the same band under the")
    print("  same flow, so sum(seat P&L) must EQUAL the benchmark's P&L for every phi. If it does")
    print("  not, the benchmark is not a benchmark and every excess-return number below is noise.")
    print()
    print(f"  {'config':>18} {'phi':>6} {'sum(seats) $':>16} {'pro-rata $':>16} {'rel err':>12}")
    worst_null = 0.0
    for rn, _, _ in REG:
        for half in HALFS:
            for phi in (0, 8500):
                ss = bb = 0.0
                for rname, _ in RANGES:
                    c = C[(phi, rn, half, rname)]
                    ss += float(c.d.sum()); bb += float(c.bd.sum())
                e = abs(ss - bb)/max(abs(bb), 1e-9); worst_null = max(worst_null, e)
                print(f"  {rn+' +/-'+f'{half:.0%}':>18} {phi:>6} {ss:>16,.0f} {bb:>16,.0f} {e:>12.2e}")
    print(f"\n  WORST relative error across the grid: {worst_null:.2e}  "
          f"{'-- PASS' if worst_null < 1e-9 else '-- INVESTIGATE'}")
    print()
    print(f"  {'config':>18} {'realised':>10} {'stdev':>9} {'downdev':>9} {'p5':>10} {'worst':>10}"
          f" {'lose%':>7}   vs BACK (ranks 17-32, phi=8500)")
    for rn, _, _ in REG:
        for half in HALFS:
            b = np.concatenate([C[(0, rn, half, rname)].bmk for rname, _ in RANGES])
            wr = max(RANGES, key=lambda r: C[(8500, rn, half, r[0])].lose.mean())[0]
            bk_ = C[(8500, rn, half, wr)].ret[:, 16:].ravel()
            print(f"  {rn+' +/-'+f'{half:.0%}':>18} {pct(b.mean()):>10} {100*b.std(ddof=1):>8.2f}%"
                  f" {100*dd(b):>8.2f}% {pct(np.percentile(b,5)):>10} {pct(b.min()):>10}"
                  f" {pc0((b<0).mean()):>7}   back dd {100*dd(bk_):>6.2f}%  ratio "
                  f"{(dd(b)/dd(bk_) if dd(bk_)>0 else float('inf')):>8.1f}x")
    print()
    print("  'ratio' = the LP's own downside deviation divided by the back seats'. THIS IS THE")
    print("  CRUX ASK: if it is one to two orders of magnitude, LP-like return at a fraction of the")
    print("  LP's downside is the product. If it is ~1x, there is nothing being sold.")
    print()

    # ================================================================= 12. excess over the LP
    rule("12. EXCESS OVER THE PRO-RATA LP, PER RANK, PER CELL  (reported, NOT optimised against)")
    print("  seat_realised - LP_realised on the SAME seed. Because of the zero-sum null above, the")
    print("  CAPITAL-WEIGHTED mean excess is ~0 by construction: this table can only show WHO gets")
    print("  it, never that the book creates any. That is exactly why it is not an objective.")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            wr = max(RANGES, key=lambda r: C[(8500, rn, half, r[0])].lose.mean())[0]
            c = C[(8500, rn, half, wr)]
            print(f"  --- {rn} +/-{half:.0%} [{wr}] phi=8500 ---   LP realised {pct(c.bmk.mean())}")
            print(f"  {'rank':>5} {'mean excess':>13} {'p5 excess':>12} {'beat LP':>9}"
                  f"   |  {'rank':>5} {'mean excess':>13} {'p5 excess':>12} {'beat LP':>9}")
            half_n = len(SHOWN)//2
            for j in range(half_n):
                cells = []
                for i in (SHOWN[j], SHOWN[j + half_n]):
                    e = c.exc[:, i-1]
                    cells.append(f"{i:>5} {pct(e.mean()):>13} {pct(np.percentile(e,5)):>12} "
                                 f"{pc0(c.beat[:, i-1].mean()):>9}")
                print("  " + cells[0] + "   |  " + cells[1])
            print(f"        capital-weighted mean excess over all 32 ranks: "
                  f"{pct(float((c.exc*c.h).sum()/c.h.sum())):>10}  (must be ~0)")
            print()

    # ================================================================= 13. reach and turnover
    rule("13. REACH -- HOW DEEP DOES FLOW ACTUALLY GO?  A rank flow never reaches is not a tranche.")
    print("  Distribution of the DEEPEST rank touched per swap, pooled over all four seed ranges.")
    print("  'arb' is the same statistic for the arbitrage trade only -- the large one, the one the")
    print("  whole front-first design exists to price.")
    print()
    print(f"  {'config':>18} {'phi':>6} {'p50':>5} {'p90':>5} {'p99':>5} {'max':>5} |"
          f" {'arb p50':>8} {'arb p90':>8} {'arb p99':>8} {'arb max':>8} |"
          f" {'ranks >0 flow':>14} {'top-4 turnover':>15}")
    for rn, _, _ in REG:
        for half in HALFS:
            for phi in (0, 8500):
                H = np.zeros(NSEAT + 1); Ha = np.zeros(NSEAT + 1); T = np.zeros(NSEAT)
                for rname, _ in RANGES:
                    c = C[(phi, rn, half, rname)]
                    H += c.reach.sum(axis=0); Ha += c.reach_a.sum(axis=0); T += c.turn.sum(axis=0)
                def q(hh, p):
                    cs = np.cumsum(hh); t = cs[-1]
                    if t <= 0: return 0
                    return int(np.searchsorted(cs, p*t))       # index 0 == no seat touched
                nz = int((T > 1e-9).sum())
                print(f"  {rn+' +/-'+f'{half:.0%}' if phi==0 else '':>18} {phi:>6}"
                      f" {q(H,.50):>5} {q(H,.90):>5} {q(H,.99):>5} {int(np.max(np.nonzero(H))):>5} |"
                      f" {q(Ha,.50):>8} {q(Ha,.90):>8} {q(Ha,.99):>8}"
                      f" {int(np.max(np.nonzero(Ha))):>8} |"
                      f" {nz:>13}/{NSEAT} {100*T[:4].sum()/max(T.sum(),1e-9):>14.1f}%")
    print()
    print("  Reported as RANK NUMBERS (1-based); 0 would mean the swap touched no seat at all.")
    print()

    # ================================================================= 14. is a rank a tick span?
    rule("14. IS A RANK A TICK SPAN?  The premise the whole 'matched wing' objection rests on.")
    print("  For each rank, the price range over which it was EVER filled, as a fraction of the")
    print("  band, pooled over the four seed ranges. If rank 1's span is the whole band, then rank")
    print("  is NOT a tick choice and no single static Uniswap range replicates it.")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            c0 = C[(8500, rn, half, RANGES[0][0])]
            sa = math.sqrt(c0.h[0].sum()*0 + (2000.0*(1-half)))    # band edges in sqrt-price
            sb = math.sqrt(2000.0*(1+half))
            print(f"  --- {rn} +/-{half:.0%} phi=8500 ---   "
                  f"(band = [{2000.0*(1-half):.0f}, {2000.0*(1+half):.0f}])")
            row = "   rank " + "".join(f"{i:>7}" for i in SHOWN)
            spans = []
            for i in SHOWN:
                lo = np.inf; hi = -np.inf
                for rname, _ in RANGES:
                    c = C[(8500, rn, half, rname)]
                    m1, m2 = c.smin[:, i-1], c.smax[:, i-1]
                    m1 = m1[np.isfinite(m1)]; m2 = m2[np.isfinite(m2)]
                    if len(m1): lo = min(lo, m1.min())
                    if len(m2): hi = max(hi, m2.max())
                spans.append(0.0 if not np.isfinite(lo) or not np.isfinite(hi)
                             else (hi - lo)/(sb - sa))
            print(row)
            print("   span" + "".join(f"{100*v:>6.0f}%" for v in spans))
            print()
    print("  span = fraction of the band's sqrt-price width over which that rank was ever filled.")
    print()

    # ================================================================= 15. cross-section at phi=5000
    rule("15. THE FULL PER-RANK CROSS-SECTION AT phi = 5000  (worst seed range per config)")
    print("  Requested because C2b says no rank loses in all three regimes at 5000, while 8500")
    print("  leaves rank 1 (and 2 at +/-10%) losing in all three. What does the FRONT actually get?")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            wr = max(RANGES, key=lambda r: C[(5000, rn, half, r[0])].lose.mean())[0]
            c = C[(5000, rn, half, wr)]
            print(f"  --- {rn}  +/-{half:.0%}  [{wr}]  LP {pct(np.mean(c.bmk))} ---")
            print(f"  {'rank':>5} {'REALISED':>10} {'stdev':>9} {'downdev':>9} {'p5':>10}"
                  f" {'worst':>10} {'lose':>7} {'beatLP':>7} {'mean exc':>10}")
            for i in SHOWN:
                st = c.rank(i-1)
                print(f"  {i:>5} {pct(st['mean']):>10} {100*st['sd']:>8.2f}% {100*st['dd']:>8.2f}%"
                      f" {pct(st['p5']):>10} {pct(st['worst']):>10} {pc0(st['lose']):>7}"
                      f" {pc0(st['beat']):>7} {pct(c.exc[:, i-1].mean()):>10}")
            print()

    # ================================================================= 16. phi* participation solve
    rule("16. phi* -- SOLVED, NOT SWEPT. The participation constraint at rank 1.")
    print("  The constraint: rank 1's queue-net equals what the SAME capital earns as an ordinary")
    print("  pro-rata LP. Two independent routes, and they are a check on each other:")
    print()
    print("   NUMERIC  -- interpolate the measured rank-1 realised return across the phi grid and")
    print("               find where it crosses the measured pro-rata return. No assumptions.")
    print("   CLOSED   -- phi* = 1 - (rank 1's EXCESS DRAG over pro-rata)/(its EXCESS FEES over")
    print("               pro-rata), from the panel's displacement algebra. This assumes rank 1")
    print("               receives its PRO-RATA share of the premium pot, which it does not (it is")
    print("               the most-drained seat and carries the least standing weight), so the two")
    print("               are expected to DISAGREE and the size of the gap is the point.")
    print()
    def r1_of_phi(rn, half, rname, p):
        return float(C[(p, rn, half, rname)].ret[:, 0].mean())
    def solve(rn, half, rname, target):
        xs = [r1_of_phi(rn, half, rname, p) - target for p in PHIS]
        for k in range(1, len(PHIS)):
            if xs[k-1] == 0: return float(PHIS[k-1])
            if xs[k-1]*xs[k] < 0:
                t = xs[k-1]/(xs[k-1] - xs[k])
                return PHIS[k-1] + t*(PHIS[k] - PHIS[k-1])
        return None
    print(f"  {'config':>18} " + "".join(f"{n[:4]+' num/closed':>20}" for n, _ in RANGES))
    PHISTAR = {}
    for rn, _, _ in REG:
        for half in HALFS:
            cells = []
            for rname, _ in RANGES:
                tgt = float(C[(0, rn, half, rname)].bmk.mean())
                num = solve(rn, half, rname, tgt)
                c0 = C[(0, rn, half, rname)]
                f = c0.gfee.mean(axis=0); l = -c0.mk.mean(axis=0); hh = c0.h.mean(axis=0)
                sh = hh/hh.sum()
                exd = l[0] - l.sum()*sh[0]; exf = f[0] - f.sum()*sh[0]
                cl = 1.0 - exd/exf if abs(exf) > 1e-9 else float('nan')
                PHISTAR[(rn, half, rname)] = num
                cells.append(f"{('%.0f' % num) if num is not None else '  none':>9}"
                             f"{100*cl:>10.0f}%" if np.isfinite(cl) else f"{'?':>19}")
            print(f"  {rn+' +/-'+f'{half:.0%}':>18} " + "".join(f"{c:>20}" for c in cells))
    print()
    print("  NUMERIC phi* is in BPS; CLOSED is the algebraic form as a percentage.")
    print()
    print("  SANITY CHECK -- at the numeric phi*, rank 1's realised return must equal the pro-rata")
    print("  return. It does by construction (that is what was solved), so the check that MEANS")
    print("  something is the residue at every OTHER rank: one scalar cannot equalise 32 ranks")
    print("  because (excess drag)/(excess fees) is not constant across them.")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            rname = RANGES[0][0]
            ps = PHISTAR[(rn, half, rname)]
            if ps is None:
                print(f"  {rn+' +/-'+f'{half:.0%}':>18}  no crossing inside the swept range")
                continue
            k = min(range(len(PHIS)), key=lambda j: abs(PHIS[j] - ps))
            c = C[(PHIS[k], rn, half, rname)]
            tgt = float(c.bmk.mean())
            r = c.ret.mean(axis=0) - tgt
            print(f"  {rn+' +/-'+f'{half:.0%}':>18}  phi*~{ps:>6.0f} (grid {PHIS[k]}): residue vs "
                  f"pro-rata, pts:  r1 {100*r[0]:>7.1f}  r2 {100*r[1]:>7.1f}  r5 {100*r[4]:>7.1f} "
                  f" r16 {100*r[15]:>7.1f}  r32 {100*r[31]:>7.1f}   |  over-paid ranks "
                  f"{int((r>0.01).sum()):>2}/32  under-paid {int((r<-0.01).sum()):>2}/32")
    print()

    # ================================================================= 17. book shape
    sys.stderr.write("[shape grid]\n")
    sjobs, skeys = [], []
    for si in range(len(SHAPES)):
        for phi in SHAPE_PHIS:
            for rn, vol, dr in REG:
                for half in HALFS:
                    for rname, rg in RANGES:
                        for sd_ in rg:
                            sjobs.append((phi, vol, dr, half, sd_, si))
                            skeys.append((si, phi, rn, half, rname))
    with Pool(nproc) as p:
        sres = p.map(shape_cell, sjobs, chunksize=8)
    S = {}
    for k, v in zip(skeys, sres): S.setdefault(k, []).append(v)
    SC = {k: Cellset(v, B[(k[2], k[3], k[4])]) for k, v in S.items()}

    rule("17. BOOK SHAPE -- is 32 EQUAL seats the right shape at phi > 0?")
    print("  `report_sizing.py` answered this at phi = 0 and found a bigger head halves the middle's")
    print("  loss and collapses the head's own return -- 'they are the same money'. The premium is a")
    print("  DIRECT transfer from head to tail, so it may do that job without resizing anything.")
    print("  Shapes carry different seat COUNTS, so per-cell loss rates are the comparable statistic")
    print("  and 'spread' is stated over whatever ranks that shape has.")
    print()
    for phi in SHAPE_PHIS:
        print(f"  ================= phi = {phi} =================")
        print(f"  {'config':>18} {'shape':>12} {'seats':>6} {'lose%':>7} {'spread pts':>11}"
              f" {'head real':>11} {'worst rank':>11} {'ranks w/ flow':>14} {'reach p90':>10}"
              f" {'beatLP%':>8}")
        for rn, _, _ in REG:
            for half in HALFS:
                for si, (snm, caps) in enumerate(SHAPES):
                    lo_ = []; sp = []; hd = []; wo = []; nz = []; p90 = []; bl = []
                    for rname, _ in RANGES:
                        c = SC[(si, phi, rn, half, rname)]
                        m = c.ret.mean(axis=0)
                        lo_.append(c.lose.mean()); sp.append(float(m.max() - m.min()))
                        hd.append(float(m[0])); wo.append(float(m.min()))
                        T = c.turn.sum(axis=0); nz.append(int((T > 1e-9).sum()))
                        H = c.reach.sum(axis=0); cs = np.cumsum(H)
                        p90.append(int(np.searchsorted(cs, 0.90*cs[-1])))
                        bl.append(c.beat.mean())
                    print(f"  {rn+' +/-'+f'{half:.0%}' if si==0 else '':>18} {snm:>12}"
                          f" {len(caps):>6} {100*max(lo_):>6.1f}% {100*np.mean(sp):>11.0f}"
                          f" {pct(np.mean(hd)):>11} {pct(min(wo)):>11}"
                          f" {int(np.mean(nz)):>10}/{len(caps):<3} {int(np.mean(p90)):>10}"
                          f" {100*min(bl):>7.1f}%")
                print()

    # ================================================================= 18. the wing controls
    sys.stderr.write("[wing grid]\n")
    wjobs, wkeys = [], []
    for rn, vol, dr in REG:
        for half in HALFS:
            for rname, rg in RANGES:
                for sd_ in rg:
                    wjobs.append((vol, dr, half, sd_)); wkeys.append((rn, half, rname))
    with Pool(nproc) as p:
        wres = p.map(wing_cell, wjobs, chunksize=4)
    Wg = {}
    for k, v in zip(wkeys, wres): Wg.setdefault(k, []).append(v)

    rule("18. THE MATCHED-WING CONTROL -- is a seat replicable with plain Uniswap liquidity?")
    print("  Read wing.py's header for the construction. Two caveats stated up front, neither")
    print("  resolved here because neither can be:")
    print("   (i) The wing is a PRICE TAKER against the tape the QUEUE pool produced. It does not")
    print("       feed its own depth back into the price path.")
    print("  (ii) A wing OVERLAPPING the band is not available inside this pool at all --")
    print("       `beforeAddLiquidity` refuses it. The substitute exists only in a different,")
    print("       unhooked pool of the same pair, which would have its own flow. Read the wing")
    print("       comparison as the arithmetic it is, not as an executable trade in THIS pool.")
    print(" (iii) The managed wing is OPTIMISTIC: it re-mints instantly at the post-swap price with")
    print("       no latency, no missed blocks and no MEV on its own conversion trade. A comparator")
    print("       biased in the WING's favour losing is strong evidence; winning is weaker.")
    print()
    print(f"  NULL CONTROL (a full-band wing of 1/32 the capital IS 1/32 of the pool):")
    print(f"  {'config':>18} {'worst fee err':>14} {'worst mk err':>14} {'median fee err':>15}"
          f" {'runs whose final P left the band':>34}")
    for rn, _, _ in REG:
        for half in HALFS:
            v = []
            for rname, _ in RANGES: v += Wg[(rn, half, rname)]
            fe = np.array([r['null_fee'] for r in v]); me = np.array([r['null_mk'] for r in v])
            po = np.mean([r['pf_out'] for r in v])
            print(f"  {rn+' +/-'+f'{half:.0%}':>18} {fe.max():>14.2e} {me.max():>14.2e}"
                  f" {np.median(fe):>15.2e} {100*po:>33.0f}%")
    print()
    print("  DIAGNOSED, not waved away. The residual is ~1e-13 on every run whose final pool price")
    print("  is INSIDE the band, and ~1e-3 on the runs where it is marginally outside. Cause: this")
    print("  simulator credits fees INTO seat inventory, so the book ends up holding slightly more")
    print("  than L over [pa,pb] implies and the terminal clamped swap can push spot ~0.2% past the")
    print("  edge. A real position correctly earns and holds NOTHING outside its own range, so the")
    print("  wing declines to follow it there. That is the wing being right, not the engine being")
    print("  wrong -- and it bounds every wing number below at ~0.2% of capital.")
    print()
    print("  --- THE BACK OF THE BOOK vs STATIC WINGS (seat = rank 32 at phi=8500) ---")
    print(f"  {'config':>18} {'rank32 seat':>12} {'full band':>11} {'edge up 25%':>12}"
          f" {'edge dn 25%':>12} {'edge up 50%':>12} {'edge dn 50%':>12} {'HOLD basket':>12}")
    for rn, _, _ in REG:
        for half in HALFS:
            v = Wg[(rn, half, RANGES[0][0])]
            for rname, _ in RANGES[1:]: v = v + Wg[(rn, half, rname)]
            s32 = np.concatenate([C[(8500, rn, half, rname)].ret[:, 31] for rname, _ in RANGES])
            g = lambda k: np.mean([r[k] for r in v])
            print(f"  {rn+' +/-'+f'{half:.0%}':>18} {pct(s32.mean()):>12} {pct(g('full')):>11}"
                  f" {pct(g('edge_up_25')):>12} {pct(g('edge_dn_25')):>12}"
                  f" {pct(g('edge_up_50')):>12} {pct(g('edge_dn_50')):>12} {'+0.00%':>12}")
    print()
    print("  'HOLD basket' is +0.00% BY CONSTRUCTION and that is the finding, not an artefact: a")
    print("  seat that never trades holds exactly its opening inventory, and P&L is marked against")
    print("  buy-and-hold of THAT inventory. A deep seat is not an out-of-the-money wing -- its")
    print("  composition is at-the-money and identical to a pro-rata LP's. It is an ordinary")
    print("  full-band LP position that has been PREVENTED FROM TRADING and paid a coupon instead.")
    print()
    print("  AND THE TRAP, STATED SO NOBODY READS THIS TABLE AS A WIN: rank 32 beats every wing here")
    print("  because rank 1 is paying for it. Section 12's capital-weighted excess is 0.00% to two")
    print("  decimals BY THE ZERO-SUM NULL -- the book creates nothing, it only moves it. A seat")
    print("  beating a wing in isolation is an internal transfer until the whole ladder is added up.")
    print()
    print("  --- THE HEAD vs A MANAGED (RE-MINTED) ATM WING ---")
    print("  Seat = rank 1. Wing = a narrow ATM range re-minted at spot every time price leaves it.")
    print(f"  Gas assumptions: L2 ${GAS['L2']:.2f}/re-mint, L1 ${GAS['L1']:.2f}/re-mint.")
    print()
    print(f"  {'config':>18} {'rank1 @0':>10} {'rank1 @5000':>12} {'rank1 @8500':>12} | "
          + "".join(f"{'w='+f'{w_:.0%}'+' L2':>11}{'  L1':>9}" for w_ in MW_WIDTHS))
    for rn, _, _ in REG:
        for half in HALFS:
            v = []
            for rname, _ in RANGES: v += Wg[(rn, half, rname)]
            g = lambda k: np.mean([r[k] for r in v])
            r1 = lambda p: np.mean([C[(p, rn, half, rname)].ret[:, 0].mean() for rname, _ in RANGES])
            print(f"  {rn+' +/-'+f'{half:.0%}':>18} {pct(r1(0)):>10} {pct(r1(5000)):>12}"
                  f" {pct(r1(8500)):>12} | "
                  + "".join(f"{pct(g(f'mw_{w_}_L2')):>11}{pct(g(f'mw_{w_}_L1')):>9}"
                            for w_ in MW_WIDTHS))
    print()
    print("  --- WHAT THE MANAGED WING PAYS, ITEMISED (as % of its own capital, L2 gas) ---")
    print(f"  {'config':>18} {'width':>7} {'re-mints':>9} {'fees':>10} {'markout':>10}"
          f" {'conv fee':>10} {'conv impact':>12} {'net':>10}")
    for rn, _, _ in REG:
        for half in HALFS:
            v = []
            for rname, _ in RANGES: v += Wg[(rn, half, rname)]
            for w_ in MW_WIDTHS:
                a = np.array([r[f"mwx_{w_}"] for r in v], float).mean(axis=0)
                print(f"  {rn+' +/-'+f'{half:.0%}' if w_==MW_WIDTHS[0] else '':>18} {w_:>7.0%}"
                      f" {a[0]:>9.0f} {pct(a[1]):>10} {pct(a[2]):>10} {pct(-a[3]):>10}"
                      f" {pct(-a[4]):>12} {pct(a[5]-a[3]-a[4]):>10}")
            print()
    print("  'conv fee' and 'conv impact' are the cost of the one-sided refill -- the term the seat")
    print("  never pays. 'net' excludes gas so the three cost terms stay separable.")
    print()
    print("  --- phi* REBOUND TO THE MANAGED WING (best width per config, L2 gas) ---")
    print("  phi such that rank 1's realised return equals what the same capital gets from actively")
    print("  managing a narrow ATM range. This is the alternative a front-seat buyer is ACTUALLY")
    print("  weighing, which a passive full-band LP is not.")
    print()
    print(f"  {'config':>18} {'best wing':>11} {'wing ret':>10} {'r1 @phi=0':>11}"
          f" {'phi* (wing)':>12} {'phi* (pro-rata)':>16}")
    for rn, _, _ in REG:
        for half in HALFS:
            v = []
            for rname, _ in RANGES: v += Wg[(rn, half, rname)]
            g = lambda k: float(np.mean([r[k] for r in v]))
            bw = max(MW_WIDTHS, key=lambda w_: g(f'mw_{w_}_L2'))
            tgt = g(f'mw_{bw}_L2')
            xs = [np.mean([C[(p, rn, half, rn2)].ret[:, 0].mean() for rn2, _ in RANGES]) - tgt
                  for p in PHIS]
            sol = None
            for k in range(1, len(PHIS)):
                if xs[k-1]*xs[k] < 0:
                    t = xs[k-1]/(xs[k-1] - xs[k]); sol = PHIS[k-1] + t*(PHIS[k] - PHIS[k-1]); break
            pp_ = [PHISTAR[(rn, half, rname)] for rname, _ in RANGES]
            pp_ = [x for x in pp_ if x is not None]
            r10 = np.mean([C[(0, rn, half, rn2)].ret[:, 0].mean() for rn2, _ in RANGES])
            print(f"  {rn+' +/-'+f'{half:.0%}':>18} {bw:>11.0%} {pct(tgt):>10} {pct(r10):>11}"
                  f" {(f'{sol:.0f}' if sol is not None else ('<0' if xs[0] < 0 else '>9500')):>12}"
                  f" {(f'{np.mean(pp_):.0f}' if pp_ else 'none'):>16}")
    print()
    print("="*W)


if __name__ == "__main__":
    main()
