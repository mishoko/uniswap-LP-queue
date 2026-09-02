"""
THE TWO-ENDED BOOK -- measured against the SHIPPED one-ended rule on the DEPLOYED configuration.

CONFIG (copied from report_shipping.py so the numbers are comparable to results-shipping.txt):
    book        $1,000,000, SEATS = 5, capital 5:4:3:2:1  (head $333,333 = 33.3%)
    band        symmetric +/-10% around P0 = 2000, minted once, never re-minted
    fee         0.30% (sim.FEE), pricing MARGINAL (the contract's Allocation curve)
    flow        retail 15/hr, Pareto notionals $100-$10,000, plus one closed-form arb per hour
    horizon     365 days, TERMINATED when the external price leaves the band
    paths       4 disjoint seed ranges x 30 = 120 per (regime, mode, phi) cell
    phi         0 and 8500 (the constant QueueDeployBase ships)

REGIMES.  The three the existing reports use, PLUS one this file adds:

    BENIGN    vol 0.25  drift  0.00
    NORMAL    vol 0.45  drift  0.00
    TOXIC     vol 0.80  drift +0.35
    TOXIC-DN  vol 0.80  drift -0.35     <-- ADDED HERE, AND IT IS A CONTROL, NOT A REGIME

WHY TOXIC-DN EXISTS.  Under BOOK rank 0 is claimed to be a monotone token0 ACCUMULATOR.  An
accumulator of the volatile asset is LONG DELTA relative to a pro-rata LP, so in the existing TOXIC
regime -- which carries drift +0.35 -- rank 0 would look good for a reason that has nothing to do
with queue position: it is simply holding the asset that went up.  TOXIC-DN is the same regime with
the drift mirrored.  THE ANSWER IS KNOWN IN ADVANCE (LAW 5, third corollary): if BOOK's rank-0
edge is a delta bet, it MUST change sign between TOXIC and TOXIC-DN.  If it is queue value, it must
not.  Reporting TOXIC alone would have been green-number-chasing.

LAW 5 LINES.  Every headline table below carries a "reads FAIL if" line naming the concrete thing
that would have to be true for the number to come out the other way.
"""
import sys, os, math, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim, book_sim
from book_sim import run2, identical
from sim import FEE

BOOK, RPH, P0, HALF, DAYS = 1_000_000.0, 15.0, 2000.0, 0.10, 365
WTS = (5, 4, 3, 2, 1)
SHIP = [BOOK*w/sum(WTS) for w in WTS]
NS = len(SHIP)
CAPSH = np.array(SHIP)/BOOK                       # c_i, the capital shares
REG = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00),
       ("TOXIC", 0.80, 0.35), ("TOXIC-DN", 0.80, -0.35))
RANGES = (range(0, 30), range(100, 130), range(200, 230), range(1000, 1030))
SEEDS = [s for r in RANGES for s in r]
PHIS = (0, 8500)
MODES = ("SHIPPED", "BOOK")
W = 100


# --------------------------------------------------------------------------------- one cell
def cell(a):
    mode, phi, vol, dr, seed = a
    K = dict(days=DAYS, retail_per_hr=RPH, half=HALF, P0=P0)
    bk, Pf, Pt = run2(SHIP, True, seed=seed, vol=vol, drift=dr, phi=phi, mode=mode, **K)
    fees, mko = bk.tie_out(Pt)                        # RAISES if the accumulators do not tie out
    d, h = bk.pnl(Pt)
    pb, Pfp, Ptp = run2([BOOK], False, seed=seed, vol=vol, drift=dr, phi=0, mode="SHIPPED", **K)
    dp, hp = pb.pnl(Ptp)
    conv0 = bk.a0 - bk.o0
    conv1 = bk.a1 - bk.o1
    tot_conv0 = float(conv0.sum())
    hpool = np.asarray(bk.hpool, float); hext = np.asarray(bk.hext, float)
    with np.errstate(divide='ignore', invalid='ignore'):
        buy_mkt = np.where(bk.b0q > 0, bk.b0n/np.maximum(bk.b0q, 1e-300), np.nan)
        buy_eff = np.where(bk.b0e > 0, bk.b0n/np.maximum(bk.b0e, 1e-300), np.nan)
        sel_mkt = np.where(bk.s0q > 0, bk.s0n/np.maximum(bk.s0q, 1e-300), np.nan)
        sel_eff = np.where(bk.s0q > 0, bk.s0e/np.maximum(bk.s0q, 1e-300), np.nan)
        net_px = np.where(conv0 > 1e-9, -conv1/np.where(conv0 > 1e-9, conv0, 1.0), np.nan)
        pbuy_eff = float(pb.b0n[0]/pb.b0e[0]) if pb.b0e[0] > 0 else np.nan
        pconv0 = float(pb.a0[0] - pb.o0[0])
        pnet_px = (-(pb.a1[0] - pb.o1[0])/pconv0) if pconv0 > 1e-9 else np.nan
    turn = ((bk.gv0 + bk.tk0)*Pt + (bk.gv1 + bk.tk1))/h        # gross volume / capital
    return dict(
        ret=d/h, lp=float(dp[0]/hp[0]), hrs=bk.hrs, Pt=Pt, Pf=Pf,
        sumd=float(d.sum()), sumh=float(h.sum()), lpd=float(dp[0]), lph=float(hp[0]),
        held=float(bk.held0*Pt + bk.held1),
        conv0=conv0, conv1=conv1, tot_conv0=tot_conv0, pconv0=pconv0,
        o0=bk.o0.copy(), a0=bk.a0.copy(), o1=bk.o1.copy(), a1=bk.a1.copy(),
        tk0=bk.tk0.copy(), tk1=bk.tk1.copy(), hits=bk.hits.copy(),
        turn=turn, fees=fees/h, mko=mko/h, prem=bk.prem_recv(Pt)/h,
        buy_mkt=buy_mkt, buy_eff=buy_eff, sel_mkt=sel_mkt, sel_eff=sel_eff, net_px=net_px,
        twap_ext=float(hext.mean()) if hext.size else np.nan,
        twap_pool=float(hpool.mean()) if hpool.size else np.nan,
        pbuy_eff=pbuy_eff, pnet_px=pnet_px,
        pa0=float(pb.a0[0]), pa1=float(pb.a1[0]), po0=float(pb.o0[0]), po1=float(pb.o1[0]),
        ptot0=float(pb.a0[0] - pb.o0[0]), pturn=float(((pb.gv0+pb.tk0)*Ptp+(pb.gv1+pb.tk1))[0]/hp[0]),
    )


def se(x):
    x = np.asarray(x, float); x = x[np.isfinite(x)]
    return float(np.std(x, ddof=1)/math.sqrt(len(x))) if len(x) > 1 else float('nan')


def mu(x):
    x = np.asarray(x, float); x = x[np.isfinite(x)]
    return float(np.mean(x)) if len(x) else float('nan')


def col(v, w=9, p=2, pc=False):
    if not np.isfinite(v): return " "*(w-3) + "n/a"
    return f"{(100*v if pc else v):>{w}.{p}f}"


def main():
    out = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "results-book.txt"), "w")
    def P(*a):
        s = " ".join(str(x) for x in a)
        print(s); out.write(s + "\n")
    def rule(t): P("="*W); P(t); P("="*W)

    # =========================================================== CONTROLS, BEFORE ANY HEADLINE
    rule("0.  INTEGRITY -- nothing below section 2 is believable until every one of these passes")
    P()
    P("  0a  TRANSCRIPTION.  book_sim.py copies sim.Book.swap, sim.Book._fill and sim.run because")
    P("      each hardcodes the walk direction where no override can reach.  In mode SHIPPED the")
    P("      copy must reproduce sim.Book BIT-FOR-BIT on real paths: every balance, accumulator,")
    P("      cursor, reach histogram and the final price.")
    P("      reads FAIL if: I mistranscribed one line of ~90 copied lines.  Mutation-tested:")
    P("      6 single-line mutations of the copy were run against sim.py; see 0d.")
    K = dict(days=DAYS, retail_per_hr=RPH, half=HALF, P0=P0)
    bad0 = n0 = 0
    for sd in (0, 1, 7, 101, 1003, 55):
        for rn, v, dr in REG:
            for phi in PHIS:
                n0 += 1
                a, Pa, _ = sim.run(SHIP, True, seed=sd, vol=v, drift=dr, phi=phi, **K)
                b, Pb, _ = run2(SHIP, True, seed=sd, vol=v, drift=dr, phi=phi, mode="SHIPPED", **K)
                if identical(a, b) or Pa != Pb: bad0 += 1
    P(f"      RESULT: {n0 - bad0}/{n0} cells bit-identical to sim.Book   "
      f"{'PASS' if bad0 == 0 else 'FAIL'}")
    P()
    P("  0b  THE TWO-ENDED CURSOR.  d0 (highest rank that may hold token0) is new code and it is")
    P("      the only new state.  Control: run BOOK with the cursors IGNORED -- walk the whole")
    P("      array from the correct end every time.  The `continue` guard already skips empty")
    P("      seats, so a correct cursor is a pure optimisation and the two must agree exactly.")
    P("      reads FAIL if: d0 or c1 ever excludes a seat that still holds the outgoing token.")
    P("      IT DID FAIL, 48/48 cells, before the repair now in book_sim.Book2._accrue -- see 0c.")
    bad0b = n0b = 0
    IG = ('head_excl', 'all_excl', 'over_excl', 'c0', 'c1', 'd0')
    for sd in SEEDS[:24]:
        for rn, v, dr in REG:
            for phi in PHIS:
                n0b += 1
                c, Pc, _ = run2(SHIP, True, seed=sd, vol=v, drift=dr, phi=phi, mode="BOOK", **K)
                d, Pd, _ = run2(SHIP, True, seed=sd, vol=v, drift=dr, phi=phi, mode="BOOK",
                                nocursor=True, **K)
                if [x for x in identical(c, d) if x[0] not in IG] or Pc != Pd: bad0b += 1
    P(f"      RESULT: {n0b - bad0b}/{n0b} cells identical with and without cursors   "
      f"{'PASS' if bad0b == 0 else 'FAIL'}")
    P()
    P("  0c  THE FINDING 0b PRODUCED, and it is specific to the two-ended book.")
    P("      `_accruePremium` is a SECOND WRITER of seat inventory and it touches no cursor.  Under")
    P("      the SHIPPED one-ended rule that is harmless BY CONSTRUCTION: a zeroForOne fill sets")
    P("      c0 = min(c0, old c1), and every seat below the old c1 holds zero token1, so it is")
    P("      weighted zero in the token0 accrual and can never be credited outside [c0, n).")
    P("      Under BOOK it is NOT harmless: d0 walks DOWN, so a seat ABOVE d0 can hold token1,")
    P("      collect token0 premium, and then sit outside [0, d0] permanently -- inventory the walk")
    P("      cannot reach and `avail` cannot see.  Measured before the repair: the price path")
    P("      diverged and seat balances moved by up to ~0.5% of the $1,000,000 book at phi=8500,")
    P("      while phi=0 was clean (no premium, no second writer).")
    P("      IF THE TWO-ENDED BOOK IS EVER BUILT IN SOLIDITY THIS IS A LIVE BUG CLASS, not a")
    P("      simulator artefact: the same two writers exist in the hook.")
    P()
    P("  0d  MUTATION TEST OF THE 0a CONTROL ITSELF (LAW 5: what would have to be true to FAIL?).")
    P("      Six single-line mutations of the copied code, each run against unmutated sim.py,")
    P("      12 cells each:")
    P("        M1  mk_in leg drops the (1-FEE)            caught 12/12   RED")
    P("        M4  remainder line -> average pricing      caught 12/12   RED")
    P("        M5  premium not taken off the top          caught  6/12   RED (6 are phi=0 cells)")
    P("        M2  walk starts at 0 instead of the cursor caught  0/12   SURVIVED")
    P("        M3  cursor never advances                  caught  0/12   SURVIVED")
    P("        M6  avail ignores the cursor               caught  0/12   SURVIVED")
    P("      The three survivors are ONE finding, and it is a true property rather than a gap:")
    P("      because the walk skips empty seats with `continue`, THE SHIPPED CURSOR IS A PURE GAS")
    P("      OPTIMISATION AND CARRIES NO ECONOMICS.  Deleting it changes no number.  That is also")
    P("      why 0b had to be built separately -- 0a structurally cannot test a cursor.")
    P()

    # ------------------------------------------------------------------------------ the grid
    from multiprocessing import Pool
    jobs, keys = [], []
    for mode in MODES:
        for phi in PHIS:
            for rn, v, dr in REG:
                for sd in SEEDS:
                    jobs.append((mode, phi, v, dr, sd)); keys.append((mode, phi, rn))
    t0 = time.time()
    sys.stderr.write(f"[{len(jobs)} runs on {os.cpu_count()} procs]\n")
    with Pool(max(1, os.cpu_count() or 4)) as pool:
        res = pool.map(cell, jobs, chunksize=8)
    sys.stderr.write(f"[done {time.time()-t0:.0f}s]\n")
    C = {}
    for k, v in zip(keys, res): C.setdefault(k, []).append(v)
    g = lambda m, p, r, f: np.array([x[f] for x in C[(m, p, r)]], float)

    # ------------------------------------------------------------- 1. identity + known answer
    rule("1.  THE IDENTITY AND THE KNOWN-ANSWER CASE")
    P()
    P("  1a  sum_i c_i r_i == LP.  Total P&L is fixed by (capital, range, flow); any pure")
    P("      re-partition is zero-sum.  If BOOK breaks this the BOOK sim is manufacturing money")
    P("      and every other number in this file is void.")
    P("      reads FAIL if: the reversed walk drops, double-counts or strands a fill.  It DID read")
    P("      FAIL at ~5e-3 before the 0c repair.")
    P()
    P("      RAW reads FAIL at 7.482e-06 in ONE of the 16 cells, and the cause is named rather")
    P("      than tolerated.  It is IDENTICAL under SHIPPED and under BOOK, and control 0a proves")
    P("      SHIPPED is bit-identical to sim.Book, so it is a PRE-EXISTING PROPERTY OF sim.py and")
    P("      not a defect in the two-ended book.  It is the HELD PREMIUM: _accrue withholds a pot")
    P("      whose weight is zero and folds it into the next accrual that has a recipient, and if")
    P("      the band's life ends with the pot still held that money was taken from the seats and")
    P("      given to nobody.  Isolated on the worst path (seed 116, TOXIC-DN, phi=8500):")
    P("          held0 = 3.9656e-03 token0, held1 = 0, mark 1794.57  ->  $7.116538")
    P("          identity gap                                        ->  $7.116538")
    P("          ratio held/gap = 1.000000 EXACTLY on a $951,150 book")
    P("      So the HELD-CORRECTED column below is the real identity, and it is exact.  The leak")
    P("      is 0.075 bps of return here, but the CLASS is worth naming: in TOXIC-DN the price")
    P("      falls, the position goes all-token0, every seat's token1 standing goes to zero, and")
    P("      the token0 pot has no one to pay.  A hold rule with no terminal sweep strands it.")
    P()
    P(f"  {'mode':>9} {'phi':>6} {'regime':>10} {'RAW max |Sc_i r_i - LP|':>25}"
      f" {'HELD-CORRECTED':>16} {'max |Pf - Pf(SHIP)|':>21}")
    worst_id = 0.0
    base_pf = {(p, r): g("SHIPPED", p, r, 'Pf') for p in PHIS for rn, _, _ in REG for r in [rn]}
    for m in MODES:
        for p in PHIS:
            for rn, _, _ in REG:
                v = C[(m, p, rn)]
                idr = np.array([abs(x['sumd']/x['sumh'] - x['lpd']/x['lph']) for x in v])
                idc = np.array([abs((x['sumd'] + x['held'])/x['sumh'] - x['lpd']/x['lph'])
                                for x in v])
                pfd = np.abs(g(m, p, rn, 'Pf') - base_pf[(p, rn)])
                worst_id = max(worst_id, float(idc.max()))
                P(f"  {m:>9} {p:>6} {rn:>10} {idr.max():>25.3e} {idc.max():>16.3e}"
                  f" {pfd.max():>21.3e}")
    P()
    P(f"      worst HELD-CORRECTED residual over all 16 cells x 120 paths: {worst_id:.3e}   "
      f"{'PASS (< 1e-13)' if worst_id < 1e-13 else 'FAIL'}")
    P("      The price path is bit-identical between modes, as it must be: availability is")
    P("      order-invariant, so the ordering rule cannot move the pool.")
    P()
    P("  1b  KNOWN-ANSWER, N = 1.  With one seat there is no second end, so BOOK and SHIPPED must")
    P("      be identical to each other AND the seat must be the pro-rata LP exactly.")
    P("      reads FAIL if: the reversed walk is off by one, or d0 is initialised wrong.")
    w1 = 0.0
    for sd in SEEDS[:20]:
        for rn, v_, dr in REG:
            for phi in PHIS:
                x, Px, Ptx = run2([BOOK], True, seed=sd, vol=v_, drift=dr, phi=phi,
                                  mode="SHIPPED", **K)
                y, Py, _ = run2([BOOK], True, seed=sd, vol=v_, drift=dr, phi=phi,
                                mode="BOOK", **K)
                z, Pz, Ptz = run2([BOOK], False, seed=sd, vol=v_, drift=dr, phi=0,
                                  mode="SHIPPED", **K)
                dxy = identical(x, y)
                dx, hx = x.pnl(Ptx); dz, hz = z.pnl(Ptz)
                w1 = max(w1, max([q[1] for q in dxy], default=0.0),
                         abs(float(dx[0]/hx[0] - dz[0]/hz[0])), abs(Px - Py), abs(Px - Pz))
    P(f"      RESULT: worst deviation across 160 (seed, regime, phi) cells: {w1:.3e}   "
      f"{'PASS' if w1 == 0.0 else ('PASS (float)' if w1 < 1e-13 else 'FAIL')}")
    P()
    P("  1c  tie_out() raised on nothing.  It is called on EVERY one of the "
      f"{len(jobs)} grid runs and")
    P("      raises unless o + markout + fees + premium reconstructs both balances and every wei")
    P("      withheld was either distributed or is still HELD.  The grid completed, so it never")
    P("      raised.")
    P()

    # ---------------------------------------------------------------------- 2. net conversion
    rule("2.  NET CONVERSION -- the load-bearing number")
    P()
    P("  conv/cap  = (a0_i - o0_i) * Pt / capital_i.  The seat's NET change in token0 holdings")
    P("              over the path, valued at the mark, as a fraction of the capital it put in.")
    P("  vs prorata= that same quantity divided by the POOL's net conversion per unit of capital,")
    P("              which is exactly what a pro-rata LP of the same size gets.  1.00 = the")
    P("              ordering rule delivered NOTHING.")
    P("  drain     = tk0_i / (token0 ever received).  a0 falls ONLY via tk0, so drain == 0 is")
    P("              EXACTLY the monotone-accumulator claim.  MONO% = share of the 120 paths on")
    P("              which the seat's token0 never once decreased.")
    P()
    P("  A NOTE ON THE RATIO, AND IT IS THE SAME TRAP AS SECTION 5.  conv/cap divided by the")
    P("  pool's own conv/cap is the natural statistic and it is UNUSABLE in BENIGN and NORMAL:")
    P("  those regimes are driftless, the pool's net conversion passes through zero, and a ratio")
    P("  whose denominator crosses zero is noise.  The headline is therefore the EXCESS -- a")
    P("  difference, always defined.  The ratio is printed only on the paths where the pool")
    P("  converted at least 10% of capital, with N stated.")
    P()
    P("  reads FAIL if: the reversed walk fails to concentrate conversion at the ends -- the")
    P("  'EXCESS' column then sits at 0.0000 for every rank and the mechanism is a no-op.  The")
    P("  numerator is per-rank and ordering-dependent; the denominator is the pool total, which is")
    P("  fixed by the price path and is bit-identical between modes (section 1a).  They are not")
    P("  the same quantity.")
    P()
    for phi in PHIS:
        for rn, _, _ in REG:
            P(f"  --- {rn}  phi={phi} ---")
            P(f"   {'':>10} " + "".join(f"{'rank '+str(i):>10}" for i in range(NS)))
            for m in MODES:
                v = C[(m, phi, rn)]
                cpi = CAPSH*BOOK
                cc = np.array([x['conv0']*x['Pt'] for x in v])/cpi
                tot = np.array([x['tot_conv0']*x['Pt'] for x in v])[:, None]/BOOK
                exc = cc - tot                       # WELL-CONDITIONED: a difference, not a ratio
                msk = np.abs(tot) >= 0.10
                with np.errstate(divide='ignore', invalid='ignore'):
                    rat = np.where(msk, cc/np.where(msk, tot, 1.0), np.nan)
                nrat = int(msk[:, 0].sum())
                tk = np.array([x['tk0'] for x in v])
                recv = np.array([x['a0'] - x['o0'] + x['tk0'] for x in v])
                with np.errstate(divide='ignore', invalid='ignore'):
                    dr_ = np.where(recv > 1e-12, tk/np.maximum(recv, 1e-300), 0.0)
                mono = (tk <= 1e-12).mean(axis=0)
                P(f"   {m:>10} " + "".join(col(mu(cc[:, i]), 10, 4) for i in range(NS))
                  + "   conv/cap")
                P(f"   {'':>10} " + "".join(col(mu(exc[:, i]), 10, 4) for i in range(NS))
                  + "   EXCESS over prorata  (0.0000 = the rule delivered nothing)")
                P(f"   {'':>10} " + "".join(col(mu(rat[:, i]), 10, 3) for i in range(NS))
                  + f"   ratio vs prorata, on the {nrat}/120 paths with |pool conv| >= 10% of cap")
                P(f"   {'':>10} " + "".join(col(mu(dr_[:, i]), 10, 3) for i in range(NS))
                  + "   drain")
                P(f"   {'':>10} " + "".join(col(mono[i], 10, 1, True) for i in range(NS))
                  + "   MONO% of paths")
            P()

    # ------------------------------------------------------------------------- 3. completion
    rule("3.  COMPLETION -- how far the head actually gets converted")
    P()
    P("  The head does NOT start at 100% token1: all five seats open with the band's own mix,")
    P("  which at P0 = 2000 over [1800, 2200] is 47.6% of value in token0.  So the honest")
    P("  statistic is the SHARE OF THE SEAT'S VALUE HELD IN TOKEN0 AT PATH END, distribution over")
    P("  the 120 paths, against the pro-rata LP whose share is pinned by the terminal price.")
    P()
    P("  reads FAIL if: BOOK leaves rank 0's terminal token0 share indistinguishable from the")
    P("  pro-rata LP's.  The LP column is computed from a SEPARATE n=1 run, not from the book.")
    P()
    for phi in (0,):
        for rn, _, _ in REG:
            P(f"  --- {rn}  phi={phi} ---   token0 share of seat value at path end")
            P(f"   {'':>22} {'p10':>9} {'p25':>9} {'median':>9} {'p75':>9} {'p90':>9} {'mean':>9} {'SE':>9}")
            for m in MODES:
                v = C[(m, phi, rn)]
                for i in (0, NS-1):
                    f0 = np.array([x['a0'][i]*x['Pt']/(x['a0'][i]*x['Pt'] + x['a1'][i]) for x in v])
                    q = np.percentile(f0, [10, 25, 50, 75, 90])
                    P(f"   {m+' rank '+str(i):>22} " + "".join(col(z_, 9, 3) for z_ in q)
                      + col(mu(f0), 9, 3) + col(se(f0), 9, 4))
            v = C[("SHIPPED", phi, rn)]
            f0 = np.array([x['pa0']*x['Pt']/(x['pa0']*x['Pt'] + x['pa1']) for x in v])
            q = np.percentile(f0, [10, 25, 50, 75, 90])
            P(f"   {'pro-rata LP':>22} " + "".join(col(z_, 9, 3) for z_ in q)
              + col(mu(f0), 9, 3) + col(se(f0), 9, 4))
            P()

    # -------------------------------------------------------------------------- 4. turnover
    rule("4.  TURNOVER BY RANK -- is the claimed U-shape there?")
    P()
    P("  turn = gross volume through the seat (both tokens, both legs, marked at Pt) / capital.")
    P("  The claim under test is a U: high at rank 0 and rank 4, LOW in the middle.")
    P("  reads FAIL if: BOOK's middle ranks turn over as much as SHIPPED's, i.e. reading the book")
    P("  from two ends does not idle the centre.  Turnover is measured from gv/tk, which are")
    P("  written in the fill loop and are independent of the conversion and P&L columns.")
    P()
    for phi in PHIS:
        for rn, _, _ in REG:
            P(f"  --- {rn}  phi={phi} ---")
            P(f"   {'':>10} " + "".join(f"{'rank '+str(i):>10}" for i in range(NS))
              + f"{'  U-ratio':>12}")
            for m in MODES:
                t = np.array([x['turn'] for x in C[(m, phi, rn)]])
                mn = [mu(t[:, i]) for i in range(NS)]
                ends = 0.5*(mn[0] + mn[NS-1]); mid = float(np.mean(mn[1:NS-1]))
                P(f"   {m:>10} " + "".join(col(x_, 10, 2) for x_ in mn)
                  + f"{(ends/mid if mid > 0 else float('nan')):>12.2f}")
                P(f"   {'  +/- SE':>10} " + "".join(col(se(t[:, i]), 10, 2) for i in range(NS)))
            h = np.array([x['hits'] for x in C[("BOOK", phi, rn)]], float)
            P(f"   {'BOOK fills':>10} " + "".join(col(mu(h[:, i]), 10, 0) for i in range(NS)))
            h = np.array([x['hits'] for x in C[("SHIPPED", phi, rn)]], float)
            P(f"   {'SHIP fills':>10} " + "".join(col(mu(h[:, i]), 10, 0) for i in range(NS)))
            hb = np.array([x['hits'] for x in C[("BOOK", phi, rn)]], float).sum(axis=1)
            hs = h.sum(axis=1)
            P(f"   {'per swap':>10}   TOTAL seat-fills per path: SHIPPED {mu(hs):.0f}, "
              f"BOOK {mu(hb):.0f} ({mu(hb)/max(1e-9, mu(hs)):.2f}x) -- a HYPOTHESIS THAT DIED:")
            P(f"   {'':>10}   BOOK spreads the same work over more ranks, it does not do more of")
            P(f"   {'':>10}   it, so there is NO aggregate gas penalty.  Reported because it was")
            P(f"   {'':>10}   the obvious objection and the number does not support it.")
            P()

    # ------------------------------------------------------------------ 5. execution quality
    rule("5.  EXECUTION QUALITY -- the number that decides the product")
    P()
    P("  A DISCARDED METRIC, RECORDED BECAUSE IT IS THE EXACT LAW 5 SHAPE.  The first draft of this")
    P("  section reported a NET price, -(a1_i - o1_i)/(a0_i - o0_i): the price of rank 0's net")
    P("  position change.  It is economically the right question and it is numerically worthless.")
    P("  Net conversion is a DIFFERENCE of two large numbers and goes through zero on any path that")
    P("  round-trips, so the denominator is dust and the ratio explodes.  Measured: it printed a")
    P("  mean net price of 8.48 against a TWAP of 1994.13, and 'rank 0 beats a taker by 9715 bps")
    P("  (SE 6318)'.  A 97% edge is not a finding, it is a divide-by-almost-zero, and the SE being")
    P("  two thirds of the mean is the tell.  It is reported below ONLY on the paths where the net")
    P("  conversion is at least 25% of the seat's opening token0, with N stated.")
    P()
    P("  THE WELL-CONDITIONED FORM.  Buy and sell legs separately.  Both denominators are GROSS")
    P("  quantities traded, which are large whenever the seat trades at all:")
    P("    buy  VWAP = numeraire paid / token0 received, INCLUDING the fee the seat retains and")
    P("                net of premium forfeited.  LOWER is better.")
    P("    sell VWAP = numeraire received (same basis) / token0 given up.  HIGHER is better.")
    P("    spread    = sell VWAP - buy VWAP, in bps of TWAP.  This is the market-maker's actual")
    P("                round-trip edge and it is what front-first pricing is supposed to buy.")
    P("    TWAP      = hourly mean of the EXTERNAL price over the band's life -- built from the")
    P("                price process, never from a fill, so it cannot move with the ordering rule.")
    P("    vs taker  = against a taker doing the same side clip-by-clip and paying FEE:")
    P("                buy  leg: 1e4*(TWAP*(1+FEE) - buyVWAP)/TWAP   POSITIVE = seat better")
    P("                sell leg: 1e4*(sellVWAP - TWAP*(1-FEE))/TWAP  POSITIVE = seat better")
    P()
    P("  reads FAIL if: front-first pricing hands rank 0 the stale end of every move.  It can and")
    P("  does read negative -- results-exec.txt already measured the head's per-fill edge at -5 to")
    P("  -27 bps under the shipped rule.")
    P()
    for phi in PHIS:
        P(f"  ===== phi = {phi} =====")
        P(f"   {'regime':>10} {'mode/who':>14} {'buyVWAP':>10} {'sellVWAP':>10} {'TWAP':>10}"
          f" {'spread bps':>11} {'SE':>7} {'buy vs tkr':>11} {'SE':>7} {'sell vs tkr':>12} {'SE':>7}")
        for rn, _, _ in REG:
            rows = [("SHIPPED", 'r0', 0), ("BOOK", 'r0', 0),
                    ("SHIPPED", f'r{NS-1}', NS-1), ("BOOK", f'r{NS-1}', NS-1)]
            for m, lbl, i in rows:
                v = C[(m, phi, rn)]
                be = np.array([x['buy_eff'][i] for x in v])
                se_ = np.array([x['sel_eff'][i] for x in v])
                tw = np.array([x['twap_ext'] for x in v])
                sp = 1e4*(se_ - be)/tw
                bt = 1e4*(tw*(1 + FEE) - be)/tw
                st = 1e4*(se_ - tw*(1 - FEE))/tw
                P(f"   {rn:>10} {m+' '+lbl:>14} {col(mu(be),10,2)} {col(mu(se_),10,2)}"
                  f" {col(mu(tw),10,2)} {col(mu(sp),11,1)} {col(se(sp),7,1)}"
                  f" {col(mu(bt),11,1)} {col(se(bt),7,1)} {col(mu(st),12,1)} {col(se(st),7,1)}")
            v = C[("BOOK", phi, rn)]
            be = np.array([x['pbuy_eff'] for x in v]); tw = np.array([x['twap_ext'] for x in v])
            bt = 1e4*(tw*(1 + FEE) - be)/tw
            P(f"   {'':>10} {'pro-rata LP':>14} {col(mu(be),10,2)} {'':>10}"
              f" {col(mu(tw),10,2)} {'':>11} {'':>7} {col(mu(bt),11,1)} {col(se(bt),7,1)}")
            P()
    P("  5b.  THE NET-CONVERSION PRICE, on the paths where the net change is MATERIAL only.")
    P("       Filter: |a0_i - o0_i| >= 25% of o0_i.  price = -(a1_i - o1_i)/(a0_i - o0_i), which is")
    P("       signed correctly for a net buyer AND a net seller.  N is stated because the filter")
    P("       is doing real work -- and where N is small the row is not evidence.")
    P()
    P(f"   {'regime':>10} {'phi':>6} {'mode':>9} {'N/120':>7} {'net side':>9} {'net px':>10}"
      f" {'TWAP':>10} {'vs TWAP bps':>12} {'SE':>8}")
    for phi in PHIS:
        for rn, _, _ in REG:
            for m in MODES:
                v = C[(m, phi, rn)]
                d0_ = np.array([x['conv0'][0] for x in v]); o0_ = np.array([x['o0'][0] for x in v])
                d1_ = np.array([x['conv1'][0] for x in v]); tw = np.array([x['twap_ext'] for x in v])
                msk = np.abs(d0_) >= 0.25*o0_
                if msk.sum() < 3:
                    P(f"   {rn:>10} {phi:>6} {m:>9} {int(msk.sum()):>7} "
                      f"{'--':>9} {'n/a':>10} {col(mu(tw),10,2)} {'n/a':>12} {'n/a':>8}")
                    continue
                px = -d1_[msk]/d0_[msk]
                side = 'BUY' if float(np.mean(np.sign(d0_[msk]))) > 0 else 'SELL'
                sgn = 1.0 if side == 'BUY' else -1.0
                rel = sgn*1e4*(tw[msk] - px)/tw[msk]
                P(f"   {rn:>10} {phi:>6} {m:>9} {int(msk.sum()):>7} {side:>9} {col(mu(px),10,2)}"
                  f" {col(mu(tw[msk]),10,2)} {col(mu(rel),12,1)} {col(se(rel),8,1)}")
        P()
    P("  THE MIRROR CONTROL.  A monotone token0 accumulator is LONG DELTA against a pro-rata LP,")
    P("  so if BOOK's rank-0 advantage is a direction bet it MUST change sign when the drift is")
    P("  mirrored between TOXIC (+0.35) and TOXIC-DN (-0.35).  If it is queue value, it must not.")
    P("  Differences are taken PATH BY PATH, so the path noise cancels and the SE is the SE of the")
    P("  paired difference.")
    P()
    P(f"   {'regime':>10} {'phi':>6} {'r0 SHIPPED':>12} {'r0 BOOK':>12} {'BOOK-SHIP':>12}"
      f" {'SE(paired)':>12} {'t':>8}")
    for phi in PHIS:
        for rn, _, _ in REG:
            a = np.array([x['ret'][0] for x in C[("SHIPPED", phi, rn)]])
            b = np.array([x['ret'][0] for x in C[("BOOK", phi, rn)]])
            d = b - a
            t = mu(d)/se(d) if se(d) > 0 else float('nan')
            P(f"   {rn:>10} {phi:>6} {col(mu(a),12,3,True)} {col(mu(b),12,3,True)}"
              f" {col(mu(d),12,3,True)} {col(se(d),12,3,True)} {col(t,8,2)}")
    P()

    # --------------------------------------------------------------- 6. the middle's product
    rule("6.  THE MIDDLE'S PRODUCT -- and who pays for it")
    P()
    P("  Per-rank decomposition from tie_out(): total = fees(incl. premium received) + markout,")
    P("  all as a fraction of the seat's own opening capital.  Differences are PAIRED (same seed,")
    P("  same price path), so the SE is the SE of the paired difference, not of the level.")
    P("  reads FAIL if: BOOK moves nothing per rank.  The identity in 1a pins the CAPITAL-WEIGHTED")
    P("  total to zero change, so a non-zero per-rank column has to be matched by an opposite one")
    P("  elsewhere -- that cross-check is printed as 'sum c_i*d' and must read ~0.")
    P()
    for phi in PHIS:
        for rn, _, _ in REG:
            P(f"  --- {rn}  phi={phi} ---")
            P(f"   {'':>16} " + "".join(f"{'rank '+str(i):>11}" for i in range(NS))
              + f"{'  sum c_i*d':>12}")
            for f_, lbl in (('ret', 'total ret'), ('fees', 'fees+prem'), ('mko', 'markout'),
                            ('prem', 'premium recv')):
                a = np.array([x[f_] for x in C[("SHIPPED", phi, rn)]])
                b = np.array([x[f_] for x in C[("BOOK", phi, rn)]])
                P(f"   {lbl+' SHIP':>16} " + "".join(col(mu(a[:, i]), 11, 3, True) for i in range(NS)))
                P(f"   {lbl+' BOOK':>16} " + "".join(col(mu(b[:, i]), 11, 3, True) for i in range(NS)))
                d = b - a
                chk = float(np.mean(d @ CAPSH))
                P(f"   {'  delta':>16} " + "".join(col(mu(d[:, i]), 11, 3, True) for i in range(NS))
                  + f"{100*chk:>12.4f}")
                P(f"   {'  SE(paired)':>16} " + "".join(col(se(d[:, i]), 11, 3, True) for i in range(NS)))
            lpv = mu(np.array([x['lp'] for x in C[("SHIPPED", phi, rn)]]))
            P(f"   {'pro-rata LP':>16} {100*lpv:>11.3f}   (the bar every rank must clear)")
            P()

    rule("6b.  THE BACK-OF-BOOK CONSTRAINT -- the one report_shipping.py picks phi to satisfy")
    P()
    P("  results-shipping.txt section 2: the bar for seats 2-5 is the ORDINARY PRO-RATA LP, not")
    P("  zero.  A back seat that merely returns something positive has not earned its rent, lock")
    P("  or gas.  phi = 8500 ships BECAUSE it is the constant that lifts the back over that bar.")
    P("  Below: each rank's mean return MINUS the pro-rata LP on the same path, and the share of")
    P("  the 480 individual (path, rank) cells in ranks 1-4 that clear it.")
    P("  reads FAIL if: BOOK leaves the back where SHIPPED leaves it.  The bar comes from a")
    P("  SEPARATE n=1 run on the same seed, never from the book's own numbers.")
    P()
    P(f"   {'regime':>10} {'phi':>6} {'mode':>9} "
      + "".join(f"{'r'+str(i)+'-LP pp':>11}" for i in range(NS))
      + f" {'ranks1-4 clear LP':>19}")
    for phi in PHIS:
        for rn, _, _ in REG:
            for m in MODES:
                v = C[(m, phi, rn)]
                r = np.array([x['ret'] for x in v]); lp = np.array([x['lp'] for x in v])[:, None]
                d = r - lp
                fr = float((d[:, 1:] > 0).mean())
                P(f"   {rn:>10} {phi:>6} {m:>9} "
                  + "".join(col(mu(d[:, i]), 11, 2, True) for i in range(NS))
                  + f" {100*fr:>18.1f}%")
            P()
    P()

    # ---------------------------------------------------------------------------- 7. verdict
    rule("7.  VERDICT")
    P()
    P("  DOES THE TWO-ENDED BOOK DELIVER A MONOTONE PRIORITY LIMIT ORDER THAT BEATS A TAKER?")
    P()
    P("                                    NO.  Not in any regime, and not for either reason.")
    P()
    P("  1. IT IS NOT MONOTONE.  Rank 0's token0 never decreases on 27.5% of BENIGN paths, 28.3%")
    P("     of NORMAL, 0.0% of TOXIC and 96.7% of TOXIC-DN.  Read that row again: monotonicity is")
    P("     pinned by the DRIFT, not by the ordering rule.  Rank 0 is a monotone accumulator")
    P("     exactly when the price falls -- i.e. exactly when accumulating is the losing side --")
    P("     and never when it rises.  A limit buy you cannot stop working when the market runs")
    P("     away from you is not a limit buy, it is adverse selection with extra steps.")
    P()
    P("  2. IT LOSES ON PRICE.  Rank 0's buy VWAP goes from 1984.07 (SHIPPED) to 2048.40 (BOOK)")
    P("     against a TWAP of 1989.66 -- NORMAL, phi=0.  Against a taker buying the same clip by")
    P("     clip and paying the 0.30% fee, BOOK's rank 0 is -269 bps (NORMAL), -319 bps (BENIGN)")
    P("     and -342 bps (TOXIC-DN).  A mandated buyer under BOOK is WORSE OFF THAN A TAKER, by")
    P("     roughly three tenths of a percent to a third of a percent, in every driftless or")
    P("     falling regime.  It is +95 bps in TOXIC only, and section 5's mirror control shows")
    P("     that sign is the drift talking.")
    P()
    P("  3. THE U-SHAPE IS NOT THERE -- IT IS INVERTED.  Claimed: high turnover at both ends, low")
    P("     in the middle.  Measured (BENIGN, phi=0, turnover/capital): SHIPPED 149.7 / 2.7 / 1.5")
    P("     / 0.9 / 0.1, a clean monotone decline.  BOOK 36.1 / 90.3 / 55.7 / 26.3 / 4.2 -- a HUMP")
    P("     with its peak at rank 1.  Reading the book from both ends does not idle the centre, it")
    P("     makes the centre the only place BOTH directions can be served, so the centre churns.")
    P("     End/middle turnover ratio: 44.79 under SHIPPED, 0.35 under BOOK.")
    P()
    P("  4. THE MIDDLE'S MARKOUT GETS WORSE, NOT BETTER.  NORMAL, phi=8500: rank 1 markout goes")
    P("     -0.96% -> -4.40%, rank 2 -0.51% -> -3.16%.  That follows directly from (3): markout")
    P("     is what turnover buys you.")
    P()
    P("  5. WHO PAYS.  The identity holds to 0.0000, so rank 0's gain is somebody's loss and")
    P("     section 6 names them.  NORMAL, phi=8500: rank 0 +4.25pp, rank 1 -3.09pp, rank 2")
    P("     -2.45pp, rank 3 -0.81pp, rank 4 +0.06pp.  THE MIDDLE PAYS THE HEAD.  That is the exact")
    P("     opposite of the proposal's stated intent, which was to pay the middle from both ends.")
    P()
    P("  6. IT BREAKS THE CONSTRAINT phi = 8500 EXISTS TO SATISFY.  Share of (path, rank) cells in")
    P("     ranks 1-4 clearing the pro-rata LP, at the shipped phi: BENIGN 80.0% -> 37.5%, NORMAL")
    P("     86.5% -> 37.9%, TOXIC 75.8% -> 0.0%.  There is no phi that repairs this, because the")
    P("     premium is what was lifting the back over the bar and BOOK reroutes the premium TO THE")
    P("     HEAD: rank 0 ends up holding the token0 that the token1-direction premium is weighted")
    P("     by, so it collects the coupon it is supposed to be paying.  NORMAL phi=8500, premium")
    P("     received: rank 0 2.344% -> 2.922%, ranks 1-3 all DOWN.")
    P()
    P("  7. NO GAS SAVING EITHER.  Total seat-fills per path are within 1% between the two rules;")
    P("     BOOK redistributes the work, it does not reduce it.")
    P()
    P("  WHAT ACTUALLY KILLED IT, IN ONE SENTENCE.  Rank 0 already drains FIRST in the")
    P("  zeroForOne direction under the shipped rule, so reversing the OTHER direction changes")
    P("  nothing about how rank 0 BUYS -- it only stops rank 0 SELLING.  The whole economic effect")
    P("  is therefore 'the head holds its token0 longer', which is a LONG-DELTA TILT and not a")
    P("  queue-position product: it pays +4.49pp in TOXIC (drift +0.35) and -1.28pp in TOXIC-DN")
    P("  (drift -0.35), at phi=0, on 120 paths each, t = +61.96 and -20.10.  A mechanism whose")
    P("  sign is set by the drift is a directional bet wearing a market-structure costume, and it")
    P("  is sold to a seat holder who cannot choose the drift.")
    P()
    P("  ONE THING THE BOOK DOES DO, STATED SO IT IS NOT LOST.  Rank 0's round-trip spread widens")
    P("  from 41.1 to 179.2 bps (NORMAL, phi=0) because its inventory now cycles at the top of the")
    P("  band.  It is real and it is not enough: turnover falls 60.7 -> 12.3, so fee income falls")
    P("  9.11% -> 1.84% of capital while markout only improves -6.92% -> -2.11%.  The head pays")
    P("  7.27pp of fees to save 4.82pp of markout.  That is the trade, and it is a bad one.")
    P()
    rule("7b.  THE HEADLINE NUMBERS")
    P()
    for phi in PHIS:
        P(f"  phi = {phi}:")
        for rn, _, _ in REG:
            a = np.array([x['ret'][0] for x in C[("SHIPPED", phi, rn)]])
            b = np.array([x['ret'][0] for x in C[("BOOK", phi, rn)]])
            d = b - a; t = mu(d)/se(d) if se(d) > 0 else float('nan')
            v = C[("BOOK", phi, rn)]
            tk = np.array([x['tk0'] for x in v]); mono = float((tk[:, 0] <= 1e-12).mean())
            be = np.array([x['buy_eff'][0] for x in v])
            sl = np.array([x['sel_eff'][0] for x in v])
            tw = np.array([x['twap_ext'] for x in v])
            e = 1e4*(tw*(1 + FEE) - be)/tw
            sp = 1e4*(sl - be)/tw
            P(f"    {rn:>10}  r0 delta {100*mu(d):+7.3f}pp (SE {100*se(d):.3f}, t={t:+.2f})   "
              f"r0 monotone {100*mono:5.1f}% of paths   "
              f"r0 buy vs taker {mu(e):+7.1f} bps (SE {se(e):.1f})   "
              f"r0 round-trip spread {mu(sp):+7.1f} bps (SE {se(sp):.1f})")
        P()
    P("="*W)
    out.close()


if __name__ == "__main__":
    main()
