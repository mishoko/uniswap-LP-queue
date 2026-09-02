"""
ADDENDUM to results-tranche.txt -- the four things that are BASIS-INDEPENDENT, plus the tau price.

Kept out of report_tranche.py deliberately: that file's output is a measurement of the mechanism
under INVENTORY weighting, the basis is about to change to CONTRIBUTED LIQUIDITY, and re-running it
now would produce a second set of numbers on a basis nobody wants. Everything here either does not
depend on the premium's weight at all (reach, fill spans, the wing controls) or is derived from
numbers already measured and already published in results-tranche.txt (the tau surface).

  A  REACH at the SHIPPED configuration -- SEATS = 5, funded 5:4:3:2:1, not "32 desks"
  B  FILL SPANS under the real funding distributions -- does rank become a tick span when the
     book is uneven? (Under 32 equal seats it does not: every rank spans ~100% of the band.)
  C  THE WING LADDER, built A PRIORI from the funding geometry rather than from hindsight, and
     built as a PAIR of positions because a rank occupies two slivers, not one contiguous range
  D  THE TAU SURFACE -- tau as the price of the product, jointly with phi
  E  L-WEIGHTING READINESS -- the unit checks that must pass before the re-run is launched

Nothing here re-runs the phi sweep.
"""
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim, wing
from sim import run, Book, FEE

BOOK, RPH, YR, P0 = 1_000_000.0, 15.0, 365*24.0, 2000.0
REG = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
HALFS = (0.10, 0.30)
RANGES = (("A", range(0, 30)), ("B", range(100, 130)), ("C", range(200, 230)), ("D", range(1000, 1030)))

SHAPES = (
    ("shipped 5 (5:4:3:2:1)", [BOOK*w/15.0 for w in (5, 4, 3, 2, 1)]),
    ("5 equal",               [BOOK/5]*5),
    ("32 equal",              [BOOK/32]*32),
    ("32 uneven (600k head)", [600_000.0] + [400_000.0/31]*31),
)
LADDER_SHAPES = (0, 2, 3)          # shipped-5, 32-equal, 32-uneven
PHI_LADDER = 8500


# ------------------------------------------------------------------ THE A-PRIORI WING LADDER
def ladder(bk, Pf, Pmark, caps):
    """For each rank, the plain-Uniswap position that OCCUPIES THE SAME PRICE SLICE.

    Built from the FUNDING GEOMETRY, not from where the rank was observed to fill -- a wing sized
    from the realised fills would be given hindsight the LP does not have, and would be a
    tautological witness (PITFALLS 5.34) wearing a wing costume.

    Rank k is reached once the cumulative OPENING inventory of ranks 1..k-1 has drained, which is a
    deterministic sqrt-price offset. That gives rank k TWO slices, one per direction -- so the
    matched substitute is a PAIR of positions, not one contiguous range, and the capital is split
    between them in proportion to the seat's own two-sided exposure. A Uniswap LP may freely hold
    two positions, so this is still a free substitute; it is simply not a single range.
    """
    L, n = bk.L, bk.n
    s0 = math.sqrt(bk.P0); sa, sb = math.sqrt(bk.pa), math.sqrt(bk.pb)
    c1 = np.concatenate([[0.0], np.cumsum(bk.o1)])      # cumulative token1 -- the DOWN direction
    c0 = np.concatenate([[0.0], np.cumsum(bk.o0)])      # cumulative token0 -- the UP direction
    out = []
    for k in range(n):
        cap = caps[k]
        vd = bk.o1[k]                                    # value of the down-side leg (numeraire)
        vu = bk.o0[k]*bk.P0
        wd = vd/(vd + vu) if (vd + vu) > 0 else 0.5
        # DOWN slice: price falls, token1 drains, s moves from s0 down
        d_hi = max(sa, min(s0, s0 - c1[k]/L)); d_lo = max(sa, min(s0, s0 - c1[k+1]/L))
        # UP slice: price rises, token0 drains, 1/s moves from 1/s0 down
        u_lo = max(s0, min(sb, 1.0/max(1e-30, 1.0/s0 - c0[k]/L)))
        u_hi = max(s0, min(sb, 1.0/max(1e-30, 1.0/s0 - c0[k+1]/L)))
        fees = mk = hold = 0.0
        for lo_, hi_, cw in ((d_lo, d_hi, wd*cap), (u_lo, u_hi, (1 - wd)*cap)):
            if hi_ - lo_ < 1e-9 or cw <= 0: continue
            w = wing.static_wing(bk, Pf, Pmark, cw, lo_*lo_, hi_*hi_, BOOK)
            fees += w['fees']; mk += w['markout']; hold += w['hold']
        out.append((fees + mk)/hold if hold > 0 else 0.0)
    return np.array(out)


def cellA(a):
    """Untraced: reach and turnover only."""
    vol, drift, half, seed, si, phi = a
    caps = SHAPES[si][1]
    bk, _, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=drift,
                    half=half, phi=phi)
    bk.tie_out(Pt)
    d, h = bk.pnl(Pt)
    return dict(reach=bk.reach, reach_a=bk.reach_a, turn=(bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1),
                smin=bk.smin, smax=bk.smax, ret=d/h, hrs=bk.hrs, n=len(caps))


def cellB(a):
    """Traced: the wing ladder alongside the seats, same run, paired by construction."""
    vol, drift, half, seed, si, phi = a
    caps = SHAPES[si][1]
    bk, Pf, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=drift,
                     half=half, phi=phi, trace=True)
    bk.tie_out(Pt)
    d, h = bk.pnl(Pt)
    ef, em, _ = wing.check_null(bk, Pf, Pt, BOOK, len(caps))
    return dict(seat=d/h, wing=ladder(bk, Pf, Pt, caps), null_fee=ef, null_mk=em,
                full=wing.static_wing(bk, Pf, Pt, BOOK/len(caps), bk.pa, bk.pb, BOOK)['ret'],
                pool=float(d.sum()/h.sum()), n=len(caps))


# --------------------------------------------------------------------- parse the published report
def parse_tranche(path):
    """Read the ALREADY-MEASURED numbers out of results-tranche.txt rather than re-running them.

    Transcribing by hand would be a second copy of a number, which on this project has been wrong
    four times. Parsed and echoed back so a reader can diff it against the source file.
    """
    txt = open(path).read()
    out = {}
    blk = txt[txt.index("--- THE HEAD vs A MANAGED"):txt.index("--- WHAT THE MANAGED WING PAYS")]
    for line in blk.splitlines():
        for rn, _, _ in REG:
            for half in HALFS:
                tag = f"{rn} +/-{half:.0%}"
                if line.strip().startswith(tag):
                    nums = [float(x.rstrip('%'))/100 for x in line.replace('|', ' ').split()[2:]]
                    out[('r1', rn, half)] = nums[0:3]                      # phi = 0, 5000, 8500
                    out[('mw', rn, half)] = max(nums[3::2])                # best width, L2 gas
    blk = txt[txt.index("  'ratio' = the LP's own")-2200:txt.index("  'ratio' = the LP's own")]
    for line in blk.splitlines():
        for rn, _, _ in REG:
            for half in HALFS:
                tag = f"{rn} +/-{half:.0%}"
                if line.strip().startswith(tag) and 'back dd' in line:
                    out[('lp', rn, half)] = float(line.split()[2].rstrip('%'))/100
                    out[('lpdd', rn, half)] = float(line.split()[4].rstrip('%'))/100
    blk = txt[txt.index("0.  THE GROUND TRUTH"):txt.index("1.  C2a")]
    for line in blk.splitlines():
        for rn, _, _ in REG:
            for half in HALFS:
                tag = f"{rn} +/-{half:.0%}"
                if line.strip().startswith(tag):
                    lives = [float(t.rstrip('d')) for t in line.split() if t.endswith('d')]
                    out[('life', rn, half)] = float(np.mean(lives))
    return out


def pct(x): return f"{100*x:+.2f}%"


def main():
    from multiprocessing import Pool
    nproc = max(1, os.cpu_count() or 4)
    W = 100
    def rule(t):
        print("="*W); print(t); print("="*W)

    rule("ADDENDUM -- basis-independent controls, plus tau. Companion to results-tranche.txt.")
    print("  Nothing here re-runs the phi sweep. Sections A-C do not depend on the premium's weight")
    print("  at all; section D is derived from numbers already published in results-tranche.txt;")
    print("  section E is the readiness gate for the L-weighting re-run.")
    print()

    # ------------------------------------------------------------------ A / B
    t0 = time.time()
    jobs, keys = [], []
    for si in range(len(SHAPES)):
        for rn, vol, dr in REG:
            for half in HALFS:
                for rname, rg in RANGES:
                    for sd in rg:
                        jobs.append((vol, dr, half, sd, si, PHI_LADDER))
                        keys.append((si, rn, half))
    sys.stderr.write(f"[A/B: {len(jobs)} untraced runs]\n")
    with Pool(nproc) as p: res = p.map(cellA, jobs, chunksize=8)
    A = {}
    for k, v in zip(keys, res): A.setdefault(k, []).append(v)
    sys.stderr.write(f"[A/B done {time.time()-t0:.0f}s]\n")

    rule("A.  REACH AT THE SHIPPED CONFIGURATION -- the deploy ships SEATS = 5, funded 5:4:3:2:1")
    print("  `QueueDeployBase.sol:100` sets SEATS = 5 and `DeployQueue.s.sol:101` funds them with")
    print("  `mul = SEATS - i`, i.e. capital weights 5:4:3:2:1 and a head that is 33.3% of the book.")
    print("  The documentation's '32 desks' is not what runs. Deepest rank touched per swap:")
    print()
    print(f"  {'config':>16} {'shape':>24} {'p50':>5} {'p90':>5} {'p99':>5} {'max':>5} |"
          f" {'arb p50':>8} {'arb p90':>8} {'arb p99':>8} | {'top-2 turnover':>15}"
          f" {'ranks w/ flow':>14}")
    for rn, _, _ in REG:
        for half in HALFS:
            for si, (snm, caps) in enumerate(SHAPES):
                v = A[(si, rn, half)]
                H = sum(r['reach'] for r in v).astype(float)
                Ha = sum(r['reach_a'] for r in v).astype(float)
                T = sum(r['turn'] for r in v)
                def q(hh, pq):
                    cs = np.cumsum(hh)
                    return 0 if cs[-1] <= 0 else int(np.searchsorted(cs, pq*cs[-1]))
                print(f"  {rn+' +/-'+f'{half:.0%}' if si == 0 else '':>16} {snm:>24}"
                      f" {q(H,.50):>5} {q(H,.90):>5} {q(H,.99):>5} {int(np.max(np.nonzero(H))):>5} |"
                      f" {q(Ha,.50):>8} {q(Ha,.90):>8} {q(Ha,.99):>8} |"
                      f" {100*T[:2].sum()/max(T.sum(),1e-9):>14.1f}%"
                      f" {int((T > 1e-9).sum()):>10}/{len(caps):<3}")
            print()

    rule("B.  FILL SPANS UNDER THE REAL FUNDING DISTRIBUTIONS -- does rank become a tick span?")
    print("  The claim to test: under uneven funding the cumulative funded fraction jumps from ~0.6")
    print("  at rank 1 to ~1.0 across the rest, so ranks 2..N collapse onto approximately ONE price")
    print("  region, which is exactly where a free static wing is the exact substitute.")
    print("  Measured: fraction of the band's sqrt-price width each rank was EVER filled over.")
    print()
    for rn, _, _ in REG:
        for half in HALFS:
            sa, sb = math.sqrt(P0*(1-half)), math.sqrt(P0*(1+half))
            for si, (snm, caps) in enumerate(SHAPES):
                v = A[(si, rn, half)]
                n = len(caps)
                show = range(n) if n <= 5 else (0, 1, 2, 3, 4, 7, 15, 23, 31)
                sp = []
                for i in show:
                    lo = min((r['smin'][i] for r in v if np.isfinite(r['smin'][i])), default=np.inf)
                    hi = max((r['smax'][i] for r in v if np.isfinite(r['smax'][i])), default=-np.inf)
                    sp.append(0.0 if not np.isfinite(lo) else (hi - lo)/(sb - sa))
                print(f"  {rn+' +/-'+f'{half:.0%}' if si == 0 else '':>16} {snm:>24}  "
                      + " ".join(f"r{i+1}:{100*x:.0f}%" for i, x in zip(show, sp)))
            print()

    # ------------------------------------------------------------------ C
    t0 = time.time()
    jobs, keys = [], []
    for si in LADDER_SHAPES:
        for rn, vol, dr in REG:
            for half in HALFS:
                for rname, rg in RANGES:
                    for sd in rg:
                        jobs.append((vol, dr, half, sd, si, PHI_LADDER))
                        keys.append((si, rn, half))
    sys.stderr.write(f"[C: {len(jobs)} traced runs]\n")
    with Pool(nproc) as p: res = p.map(cellB, jobs, chunksize=4)
    Cc = {}
    for k, v in zip(keys, res): Cc.setdefault(k, []).append(v)
    sys.stderr.write(f"[C done {time.time()-t0:.0f}s]\n")

    rule(f"C.  THE WING LADDER, A PRIORI, PER RANK  (phi = {PHI_LADDER})")
    print("  Each rank's substitute is TWO plain positions -- one per direction -- over the price")
    print("  slices the funding geometry says that rank occupies, funded with the same capital and")
    print("  split in proportion to the seat's own two-sided exposure. Sized from FUNDING, never")
    print("  from observed fills: a wing sized from hindsight is a tautological witness.")
    print()
    print("  A TIE IS A LOSS. The wing is free, cancellable in any block, uncapped, needs no")
    print("  roster seat and lets the holder choose their own ticks. Matching it while charging")
    print("  rent and adding contract risk is losing, so 'seat > wing' is reported STRICTLY.")
    print()
    print("  NOTE ON THE NULL: these per-rank wings do NOT tile the band (they are sized to")
    print("  slices that overlap at the head and leave gaps), so there is no built-in zero-sum")
    print("  identity for the LADDER. The identity that IS enforced is the one that has one:")
    print("  sum(seats) == the pro-rata position, checked at 1e-15 in results-tranche.txt section 11,")
    print("  and the full-band wing null, re-checked here.")
    print()
    mxf = max(max(r['null_fee'] for r in v) for v in Cc.values())
    mxm = max(max(r['null_mk'] for r in v) for v in Cc.values())
    print(f"  full-band wing null over {sum(len(v) for v in Cc.values())} runs: "
          f"worst fee {mxf:.2e}, worst markout {mxm:.2e}")
    print()
    for si in LADDER_SHAPES:
        snm, caps = SHAPES[si]
        n = len(caps)
        show = list(range(n)) if n <= 5 else [0, 1, 2, 3, 4, 7, 15, 23, 31]
        print(f"  ---------------- {snm} ----------------")
        print(f"  {'config':>16} {'rank':>5} {'capital':>10} {'seat':>10} {'wing':>10}"
              f" {'seat-wing':>11} {'seat>wing':>10} {'p5 of diff':>11}")
        for rn, _, _ in REG:
            for half in HALFS:
                v = Cc[(si, rn, half)]
                S = np.array([r['seat'] for r in v]); Wv = np.array([r['wing'] for r in v])
                for j, i in enumerate(show):
                    dfr = S[:, i] - Wv[:, i]
                    print(f"  {rn+' +/-'+f'{half:.0%}' if j == 0 else '':>16} {i+1:>5}"
                          f" {caps[i]:>10,.0f} {pct(S[:, i].mean()):>10} {pct(Wv[:, i].mean()):>10}"
                          f" {pct(dfr.mean()):>11} {100*(dfr > 0).mean():>9.0f}%"
                          f" {pct(np.percentile(dfr, 5)):>11}")
                wins = sum(1 for i in range(n)
                           if (S[:, i] - Wv[:, i]).mean() > 0)
                print(f"  {'':>16} {'ALL':>5} {'':>10} {'':>10} {'':>10} {'':>11}"
                      f" {wins:>6}/{n} ranks beat their own wing on the mean")
                print()

    # ------------------------------------------------------------------ D
    M = parse_tranche(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "results-tranche.txt"))
    rule("D.  THE TAU SURFACE -- tau as the PRICE OF THE PRODUCT, jointly with phi")
    print("  Inputs are PARSED from results-tranche.txt, not re-run and not re-typed. Echoed here")
    print("  so they can be diffed against the source file:")
    print()
    print(f"  {'config':>16} {'life':>7} {'LP':>10} {'best managed wing':>19}"
          f" {'rank1 @phi=0':>13} {'@5000':>10} {'@8500':>10}")
    for rn, _, _ in REG:
        for half in HALFS:
            r1 = M[('r1', rn, half)]
            print(f"  {rn+' +/-'+f'{half:.0%}':>16} {M[('life',rn,half)]:>6.1f}d"
                  f" {pct(M[('lp',rn,half)]):>10} {pct(M[('mw',rn,half)]):>19}"
                  f" {pct(r1[0]):>13} {pct(r1[1]):>10} {pct(r1[2]):>10}")
    print()
    print("  THE ARITHMETIC, AND WHICH PARTS ASSUME ANYTHING.")
    print()
    print("   A(phi) = rank1 realised  -  max(pro-rata LP, best managed wing)   [ALL MEASURED]")
    print("            the front's advantage per dollar over the best thing it could do instead.")
    print()
    print("   Participation, no assumption:  a holder pays rent tau*P over the life and will not")
    print("   pay more than the advantage is worth, so")
    print("        P_max = A(phi) * C * (1yr/life) / tau        and")
    print("        rent collected over the life = tau * P * (life/1yr)  <=  A(phi) * C.")
    print()
    print("   ****  THE RENT THE BOOK CAN COLLECT IS BOUNDED BY A(phi) AND IS INDEPENDENT OF tau.")
    print("         tau sets the PRICE LEVEL of a seat, not the REVENUE. Raising tau lowers the")
    print("         self-price by exactly the same factor.  ****")
    print()
    print("   Only the SPLIT of that bound between holder and book depends on an assumption. With")
    print("   the Harberger equilibrium the project's README already flags as unestablished,")
    print("   P* = A/(tau+k), the book gets A * tau/(tau+k) -- a fraction, never more than A.")
    print()
    print(f"  {'config':>16} {'phi':>6} {'A(phi) realised':>16} {'binding outside option':>23}"
          f" {'rent bound $ (life)':>20} {'$/yr':>14} {'tail coupon realised':>21} {'/yr':>10}")
    for rn, _, _ in REG:
        for half in HALFS:
            life = M[('life', rn, half)]
            outv = max(M[('lp', rn, half)], M[('mw', rn, half)])
            which = 'managed wing' if M[('mw', rn, half)] > M[('lp', rn, half)] else 'pro-rata LP'
            for j, phi in enumerate((0, 5000, 8500)):
                Aq = M[('r1', rn, half)][j] - outv
                C = BOOK*5.0/15.0                      # shipped head = 5/15 of the book
                real = Aq*C                            # over the band's LIFE, tau-independent
                ann = real*365.0/life                  # the SAME number annualised -- x{365/life}
                cr, ca = real/(BOOK - C), ann/(BOOK - C)
                print(f"  {rn+' +/-'+f'{half:.0%}' if j == 0 else '':>16} {phi:>6}"
                      f" {pct(Aq):>16} {which if j == 0 else '':>23}"
                      f" {real:>20,.0f} {ann:>14,.0f}"
                      f" {(pct(cr) if real > 0 else 'NONE -- A<=0'):>21}"
                      f" {(pct(ca) if real > 0 else '--'):>10}")
            print()
    print("  'rent bound' uses the SHIPPED head (5/15 of a $1M book = $333,333). REALISED first, then")
    print("  the same number annualised -- the annualiser is 365/life and reaches 94x in TOXIC, which")
    print("  is exactly the distortion this report refuses to print on its own. 'tail coupon' spreads")
    print("  it over the remaining $666,667. All four columns are CEILINGS at any tau, not forecasts.")
    print()
    print(f"  {'':>16} With the ASSUMED equilibrium P* = A/(tau+k), the book's share of that ceiling:")
    print(f"  {'tau':>16} " + "".join(f"{'k='+f'{k:.0%}':>12}" for k in (0.10, 0.20, 0.40)))
    for tau in (0.05, 0.10, 0.25, 0.50, 1.00):
        print(f"  {tau:>15.0%} " + "".join(f"{tau/(tau+k):>11.0%} " for k in (0.10, 0.20, 0.40)))
    print()
    print("  Read the table above as: at tau = 10% and k = 20% the book captures 33% of A(phi), and")
    print("  the holder keeps 67%. NOTHING in it can lift revenue above A(phi).")
    print()

    # ------------------------------------------------------------------ E
    rule("E.  L-WEIGHTING READINESS -- the gate before the re-run is launched")
    print("  sim.PREM_WEIGHT = 'liquidity' is implemented and unit-checked. It is NOT the default")
    print("  and no grid has been run on it. Checks, all executed:")
    print()
    for n in (5, 32):
        EQ = [BOOK/n]*n
        r = {}
        for wn in ('inventory', 'liquidity'):
            sim.PREM_WEIGHT = wn
            bk = Book(EQ, P0, True, 0.10, 8500)
            s0 = math.sqrt(P0); s1 = s0 - bk.a1[0]/bk.L
            bk.swap(P0, bk.L*(1/s1 - 1/s0)/(1 - FEE), True)
            r[wn] = (bk.pr0.copy(), bk.pp0.sum())
        pot = r['inventory'][1]
        eff = 8500*(1 - r['liquidity'][0][0]/pot)
        print(f"   n={n:<3} one swap draining the head exactly:")
        print(f"        inventory  head {r['inventory'][0][0]:.3e} (expect 0)   "
              f"others {r['inventory'][0][1]:.10f} (expect pot/{n-1} = {pot/(n-1):.10f})")
        print(f"        liquidity  head {r['liquidity'][0][0]:.10f} (expect pot/{n} = "
              f"{pot/n:.10f})")
        print(f"        EFFECTIVE phi at the head = {eff:.1f}   expected {8500*(1-1/n):.0f}   "
              f"{'MATCH' if abs(eff - 8500*(1-1/n)) < 0.5 else '*** MISMATCH ***'}")
    sim.PREM_WEIGHT = 'inventory'
    print()
    print("   LAW 2 negative control (the mutant that pays the pot to the HEAD) under both weights:")
    orig = Book._accrue
    def wrong(self, zfo, pot):
        if zfo: self.pr0[0] += pot; self.a0[0] += pot
        else:   self.pr1[0] += pot; self.a1[0] += pot
    EQ = [BOOK/32]*32
    for wn in ('inventory', 'liquidity'):
        sim.PREM_WEIGHT = wn
        bk, _, Pt = run(EQ, True, days=365, retail_per_hr=RPH, seed=7, vol=0.25, half=0.30, phi=8500)
        bk.tie_out(Pt); d, h = bk.pnl(Pt)
        Book._accrue = wrong
        bk2, _, Pt2 = run(EQ, True, days=365, retail_per_hr=RPH, seed=7, vol=0.25, half=0.30, phi=8500)
        Book._accrue = orig
        d2, h2 = bk2.pnl(Pt2)
        det = int((d2 < 0).sum()) != int((d < 0).sum())
        print(f"        {wn:10} correct {int((d<0).sum()):>2}/32 losing, rank32 {pct(d[31]/h[31]):>10}"
              f"   mutant {int((d2<0).sum()):>2}/32, rank32 {pct(d2[31]/h2[31]):>10}"
              f"   -> {'DETECTED' if det else '*** NOT DETECTED ***'}")
    sim.PREM_WEIGHT = 'inventory'
    print()
    print("   WEIGHT DRIFT AT ACCRUAL TIME -- the corrected instant. A drained seat is at maximum")
    print("   divergence from proportionality one line after being drained, so measuring at path")
    print("   end measures the wrong moment. drift = max_i |a_i/L_i - mean| / mean, per accrual:")
    print()
    print(f"  {'config':>16} {'shape':>24} {'accruals':>10} {'median':>9} {'p90':>9} {'min':>9}"
          f" {'frac > 0.5':>11}")
    for rn, vol, dr in REG:
        for half in HALFS:
            for si in (0, 2):
                snm, caps = SHAPES[si]
                ds = []
                for sd in range(6):
                    bk, _, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=sd, vol=vol,
                                    drift=dr, half=half, phi=8500)
                    bk.tie_out(Pt); ds.append(np.array(bk.drift))
                d = np.concatenate(ds)
                print(f"  {rn+' +/-'+f'{half:.0%}' if si == 0 else '':>16} {snm:>24} {len(d):>10,}"
                      f" {np.median(d):>9.3f} {np.percentile(d,90):>9.3f} {d.min():>9.5f}"
                      f" {100*np.mean(d>0.5):>10.1f}%")
            print()
    print("="*W)


if __name__ == "__main__":
    main()
