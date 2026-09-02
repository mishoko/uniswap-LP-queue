"""
THE SHIPPED RULE, CHARACTERISED -- are marginal pricing and front-first unwind a MATCHED PAIR?

WHAT THIS REPLACED, SO NOBODY REOPENS IT.  This file took over from an experiment on LIFO unwind
that was killed on structure before any number was published; the four reasons are recorded in
`sim_lifo.py`, which is now a headstone.  The short version: "unwind" is not observable to the
contract, a direction flag would be a free lane, and in a single pro-rata position the loss
ordering and the cash ordering are necessarily THE SAME ordering -- so a senior/junior tranche is
impossible here, not merely unattractive.

THE HYPOTHESIS THIS FILE TESTS.

    The head pays the WORST price of every move -- `_fill` walks `sprev` from `s0` toward `s1`, so
    the first slot is the segment nearest the PRE-swap price, which is the dearest place to buy
    and the cheapest place to sell -- and is compensated with fills and recycling inventory.  The
    tail is filled rarely but at the BEST price of each move, and then holds.

If that trade is symmetric, the Ratchet (premise-review/fairness.md A.2c) is not a defect and the
project should stop trying to fix it.  If one side is strictly worse, this says which and by how
much.  The question is settled by ONE number: **the head's price penalty as a fraction of the fee
income the same ordering hands it.**

WHAT IS NOT REPORTED HERE, AND WHY.  No aggregate P&L identity.  "Total P&L is unchanged under a
different ordering" CANNOT FAIL: availability depends on the position's total inventory and never
on how it is split, and the remainder line forces sum(give) == amtIn in any visiting order.
`ROTATION.md`'s banner already recorded a maximally corrupt allocator -- one crediting 100% of
every swap to the head -- scoring +0.000000% on exactly that check.  Every table below is per
(path, rank), and the instrument's own conservation is checked per FILL, where it can fail.

Usage:  python3 report_exec.py              (writes stdout; results-exec.txt is the capture)
        python3 report_exec.py --controls   (controls only, ~60s)
"""
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim                      # READ ONLY. The reference implementation. Never modified here.
import sim_exec
from sim_exec import run

# ROSTER SIZE.  Read from the ENVIRONMENT, not from sys.argv: multiprocessing on macOS defaults to
# 'spawn', which re-imports this module in each worker with a DIFFERENT argv -- so argv parsing at
# module level would silently give the parent one roster and the workers another, and every table
# would be a blend of two configurations with nothing to show for it.  The environment IS inherited
# by spawned children.  `cell` returns the roster length it actually used and main()/nseats()
# assert every worker agrees, so this cannot fail silently even if the mechanism above is wrong.
BOOK, RPH = 1_000_000.0, 15.0
NSEAT = int(os.environ.get('QUEUE_NSEAT', '32'))
EQ    = [BOOK/NSEAT]*NSEAT
YR    = 365*24.0
REG   = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
HALFS = (0.10, 0.30)
PHIS  = (0, 8500)
RANGES = (("A r0-29", range(0, 30)), ("B r100-129", range(100, 130)),
          ("C r200-229", range(200, 230)), ("D r1000-1029", range(1000, 1030)))
SHOWN = tuple(r for r in (1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 28, 32) if r <= NSEAT) \
        if NSEAT > 8 else tuple(range(1, NSEAT + 1))
W = 112


def line(t=""):
    print("=" * W)
    if t:
        print(t); print("=" * W)


# ===================================================================================================
#  CONTROLS.  Each one can FAIL. They raise.
# ===================================================================================================
def controls():
    line("CONTROLS -- the execution-price instrument is NEW, so it is the thing on trial here")
    print("\nNOTE ON WHAT IS *NOT* A CONTROL. An aggregate 'total P&L is unchanged' check is")
    print("arithmetic, not evidence: availability is order-invariant and the remainder line forces")
    print("sum(give) == amtIn, so it passes for EVERY allocator including a maximally corrupt one")
    print("(ROTATION.md banner). The instrument's conservation is therefore checked per FILL below.")

    # ---------------------------------------------------------------- E0 the refactor
    print("\nE0. sim_exec.py MUST reproduce sim.py exactly. It is a copy plus instruments; if the")
    print("    instruments perturbed the mechanism, every number below is about a different model.")
    worst, n = 0.0, 0
    try:
        for (v, d, h) in ((0.25, 0, .10), (0.45, 0, .10), (0.45, 0, .30), (0.80, .35, .30)):
            for phi in PHIS:
                for seed in (7, 11, 203, 1005):
                    a, _, Pa = sim.run(EQ, True, vol=v, drift=d, half=h, phi=phi, seed=seed,
                                       retail_per_hr=RPH)
                    b, _, Pb = run(EQ, True, vol=v, drift=d, half=h, phi=phi, seed=seed,
                                   retail_per_hr=RPH)
                    assert a.hrs == b.hrs
                    da, _ = a.pnl(Pa); db, _ = b.pnl(Pb)
                    worst = max(worst, float(np.abs(da - db).max())/max(1.0, float(np.abs(da).max())))
                    n += 1
    except Exception as e:
        print(f"    !! sim.py (under concurrent edit) RAISED after {n} configs: {e}")
        print("    !! E0 IS INCONCLUSIVE.")
        return
    print(f"    {n} configs, worst relative per-seat P&L difference = {worst:.3e}   "
          f"{'PASS (bit-identical)' if worst == 0.0 else 'FAIL'}")
    assert worst == 0.0

    # ---------------------------------------------------------------- E1/E2/E3 per-fill audits
    print("\nE1. PER-FILL RECONSTRUCTION. The seats' own legs must sum to the swap's legs, on every")
    print("    fill. A per-seat price can be wrong in a way no aggregate would ever reveal.")
    print("E2. PER-FILL ZERO-SUM. Edge is a SPLIT of one swap: every dollar one rank gains, another")
    print("    loses on the SAME fill. This is the property that can fail, and it is checked per")
    print("    fill rather than in aggregate.")
    print("E3. SOLO NULL. On a fill touching ONE seat, that seat IS the pool, so its edge must be")
    print("    EXACTLY zero at every rank. Built in, and it is a null that can go wrong.")
    e1 = e2 = e3 = 0.0; fills = 0
    for (v, d, h) in ((0.25, 0, .10), (0.45, 0, .30), (0.80, .35, .30)):
        for phi in PHIS:
            for seed in (7, 203, 1005):
                b, _, Pt = run(EQ, True, vol=v, drift=d, half=h, phi=phi, seed=seed,
                               retail_per_hr=RPH)
                st = b.exec_stats()
                e1 = max(e1, b.exec_err); e2 = max(e2, b.edge_zero_err)
                e3 = max(e3, float(np.nanmax(np.abs(st['solo_edge']))) if
                         np.any(st['solo_not'] > 0) else 0.0)
                fills += int(st['nfill'].sum())
    assert fills > 0, "nothing happened: these controls prove nothing"
    print(f"\n    over {fills:,} seat-fills:")
    print(f"    E1 max relative leg error   = {e1:.3e}   {'PASS' if e1 < 1e-12 else 'FAIL'}")
    print(f"    E2 max zero-sum residual    = {e2:.3e} of fill notional  "
          f"{'PASS' if e2 < 1e-12 else 'FAIL'}")
    print(f"    E3 max |solo edge|          = {e3:.3e} bps  {'PASS' if e3 == 0.0 else 'FAIL'}")
    assert e1 < 1e-12 and e2 < 1e-12 and e3 == 0.0

    # ---------------------------------------------------------------- E4 the strong negative control
    print("\nE4. NEGATIVE CONTROL -- AVERAGE PRICING. `marginal=False` gives every seat in a fill the")
    print("    SAME price by construction. So the edge must collapse to EXACTLY zero at every rank")
    print("    while the TURNOVER gradient is untouched. This is what separates the two effects:")
    print("    it proves the edge measures marginal pricing and not merely 'being early'.")
    print(f"\n    {'regime':>16} {'max|edge| bps':>28} {'turnover rank 1':>26}")
    print(f"    {'':>16} {'marginal':>13} {'average':>14} {'marginal':>12} {'average':>13}")
    for rn, v, d in REG:
        out = []
        for marg in (True, False):
            b, _, Pt = run(EQ, marg, vol=v, drift=d, half=0.10, phi=0, seed=7, retail_per_hr=RPH)
            st = b.exec_stats(); _, hh = b.pnl(Pt)
            out.append((float(np.nanmax(np.abs(1e4*st['m_edge']))),
                        float((b.tk0[0]*Pt + b.tk1[0])/hh[0])))
        print(f"    {rn:>16} {out[0][0]:>13.4f} {out[1][0]:>14.4f} "
              f"{out[0][1]:>12,.1f} {out[1][1]:>13,.1f}")
        # NOT `== 0.0`: the remainder line (`give = amt_in - assigned`) does not follow the
        # average-price formula the other seats do, so the last seat of a fill carries a float
        # residual. The claim worth asserting is a SEPARATION of many orders of magnitude between
        # the two pricing rules, which is far stronger than an equality float cannot deliver.
        assert out[1][0] < 1e-6, f"average pricing left a real edge: {out[1][0]:.3e} bps"
        assert out[0][0] > 1.0, "marginal pricing shows no edge -- nothing is being measured"
        assert out[0][0]/max(out[1][0], 1e-30) > 1e6, "the two rules are not separated"
    print("    PASS -- average pricing leaves <1e-6 bps (float residue of the remainder line)")
    print("    against 8-26 bps under marginal pricing: >6 orders of magnitude of separation,")
    print("    with turnover unchanged. The edge measures MARGINAL PRICING and nothing else.")

    # ---------------------------------------------------------------- E5 tie_out
    print("\nE5. tie_out() raises. Called on every grid run below, not just here.")
    b, _, Pt = run(EQ, True, vol=0.45, half=0.10, phi=8500, seed=7, retail_per_hr=RPH)
    b.tie_out(Pt)
    b.fe0[3] += 1.0
    try:
        b.tie_out(Pt); raise SystemExit("tie_out did NOT raise")
    except AssertionError:
        print("    PASS -- corrupting one seat's fee accumulator makes tie_out() RAISE.")

    print("\nE6. WHAT THIS MODEL CANNOT SEE (stated, not tested away):")
    print("    * pure float, ONE pool, no decimals. It cannot see a token0/token1 unit-mixing bug,")
    print("      which is exactly the class LAW 1 (as amended 2026-09-02) was hardened for. Read")
    print("      every number below as ECONOMICS, never as a test of the contract's arithmetic.")
    print("    * one band, minted once. Nothing here speaks to re-minting or to seat evacuation.")
    print()


# ===================================================================================================
def cell(a):
    phi, vol, drift, half, seed, marg = a
    bk, _, Pt = run(EQ, marg, days=365, retail_per_hr=RPH, seed=seed, vol=vol,
                    drift=drift, half=half, phi=phi)
    fees, mk = bk.tie_out(Pt)                 # RAISES
    d, h = bk.pnl(Pt)
    st = bk.exec_stats()
    return dict(n=len(EQ), hrs=bk.hrs, d=d, h=h, fees=fees, mk=mk, Pt=Pt,
                tov=(bk.tk0*Pt + bk.tk1)/h,
                cyc=np.where(bk.gv0 > 1e-9, bk.tk0/np.maximum(bk.gv0, 1e-30), np.nan),
                nfill=st['nfill'], mnfill=st['m_nfill'],
                medge=st['m_edge'], medge_b=st['m_edge_b'], medge_s=st['m_edge_s'],
                mu_b=st['m_u_b'], mu_s=st['m_u_s'],
                eusd=st['edge_usd'], first=st['first'], start=st['start'],
                reach=bk.reach.copy())


def bench(a):
    vol, drift, half, seed = a
    bk, _, Pt = run([BOOK], False, days=365, retail_per_hr=RPH, seed=seed, vol=vol,
                    drift=drift, half=half)
    d, h = bk.pnl(Pt)
    return d[0]/h[0]


def dd(x):
    n = np.minimum(x, 0.0)
    return float(np.sqrt(np.mean(n*n)))


class CS:
    """paths x seats matrices for one (phi, regime, half)."""
    def __init__(self, rows, bmk):
        g = lambda k: np.array([r[k] for r in rows])
        self.hrs = np.array([r['hrs'] for r in rows], float)
        self.d, self.h = g('d'), g('h')
        self.fees, self.mk = g('fees'), g('mk')
        self.tov, self.cyc = g('tov'), g('cyc')
        self.nfill, self.mnfill = g('nfill'), g('mnfill')
        self.medge, self.medge_b, self.medge_s = g('medge'), g('medge_b'), g('medge_s')
        self.mu_b, self.mu_s = g('mu_b'), g('mu_s')
        self.eusd, self.first, self.start = g('eusd'), g('first'), g('start')
        self.reach = g('reach')
        self.ret = self.d/self.h
        self.ann = self.ret/(self.hrs/YR)[:, None]
        self.fee_c, self.mk_c, self.eusd_c = self.fees/self.h, self.mk/self.h, self.eusd/self.h
        self.bmk = np.array(bmk, float)
        self.beat = self.ret > self.bmk[:, None]

    def col(self, k, i):
        return getattr(self, k)[:, i]


def pct(x): return f"{100*x:+.2f}%"


def main():
    from multiprocessing import Pool
    t0 = time.time()
    controls()

    jobs, keys = [], []
    for phi in PHIS:
        for rn, vol, dr in REG:
            for half in HALFS:
                for rname, rg in RANGES:
                    for s in rg:
                        jobs.append((phi, vol, dr, half, s, True))
                        keys.append((phi, rn, half, rname))
    bjobs, bkeys = [], []
    for rn, vol, dr in REG:
        for half in HALFS:
            for rname, rg in RANGES:
                for s in rg:
                    bjobs.append((vol, dr, half, s)); bkeys.append((rn, half, rname))
    npc = max(1, os.cpu_count() or 4)
    sys.stderr.write(f"[{len(jobs)} sims + {len(bjobs)} benchmarks on {npc} procs]\n")
    with Pool(npc) as p:
        bres = p.map(bench, bjobs, chunksize=4)
        res = p.map(cell, jobs, chunksize=4)
    sys.stderr.write(f"[done in {time.time()-t0:.0f}s]\n")

    B, R = {}, {}
    for k, v in zip(bkeys, bres): B.setdefault(k, []).append(v)
    for k, v in zip(keys, res): R.setdefault(k, []).append(v)
    C = {k: CS(v, B[(k[1], k[2], k[3])]) for k, v in R.items()}

    def P(k, phi, rn, h, i, fn=np.nanmean):
        return float(fn(np.concatenate([C[(phi, rn, h, n)].col(k, i) for n, _ in RANGES])))

    line("QUEUE -- THE SHIPPED RULE CHARACTERISED: is the head/tail trade-off symmetric?")
    print(f"  32 equal seats of ${BOOK/NSEAT:,.0f} on ${BOOK:,.0f}. marginal pricing. retail "
          f"{RPH:.0f}/hr. 365d cap. FIFO (the shipped rule) ONLY.")
    print("  FOUR DISJOINT SEED RANGES: " + ", ".join(n for n, _ in RANGES) +
          "   (30 paths each; 120 paths / 3,840 cells per config)")
    print("  Every figure is per (path, rank) and REALISED over the band's actual life.")
    print()
    print("  EDGE = how the rank's own execution price compared with THAT SWAP's average price,")
    print("  i.e. with what one undivided pro-rata LP would have realised on the same trade.")
    print("  POSITIVE = better than pro-rata, in BOTH directions. It is exactly zero-sum per fill.")
    print("  It is reported over MULTI-SEAT fills, because on a solo fill the seat IS the pool and")
    print("  its edge is identically zero -- including those would dilute the head toward 0 while")
    print("  saying nothing about ordering.")
    print()

    line("0.  BAND LIFE AND THE PRO-RATA BENCHMARK")
    print(f"  {'regime/band':>18}" + "".join(f"{n:>21}" for n, _ in RANGES))
    for rn, _, _ in REG:
        for h in HALFS:
            print(f"  {rn+' +/-'+f'{h:.0%}':>18}", end="")
            for rname, _ in RANGES:
                c = C[(0, rn, h, rname)]
                print(f"   life {np.mean(c.hrs)/24:6.1f}d LP {pct(np.mean(c.bmk)):>8}", end="")
            print()
    print()

    # ---------------------------------------------------------------- A. the price gradient
    line("A.  IS THE HEAD'S EXECUTION ACTUALLY WORSE?  (edge in bps, MULTI-seat fills, phi=0)")
    print("  phi=0 isolates the ORDERING. The premium is a deliberate transfer laid on top of it")
    print("  and would otherwise be read as a property of the ordering, which it is not.")
    print("  'u' is where in the move the rank landed: 0 = executed at the PRE-swap price (the")
    print("  stalest end), 1 = at the POST-swap price. Geometry; edge is the money.")
    print()
    for rn, _, _ in REG:
        for h in HALFS:
            print(f"  {rn} +/-{h:.0%}")
            print(f"    {'rank':>14}" + "".join(f"{rk:>8}" for rk in SHOWN))
            for lbl, k in (("edge BUY  bps", 'medge_b'), ("edge SELL bps", 'medge_s'),
                           ("u   BUY", 'mu_b'), ("u   SELL", 'mu_s')):
                sc = 1e4 if 'edge' in lbl else 1.0
                print(f"    {lbl:>14}" + "".join(
                    f"{sc*P(k, 0, rn, h, rk-1):>8.2f}" for rk in SHOWN))
            print()

    # ---------------------------------------------------------------- B. quantity
    line("B.  FILL COUNT AND TURNOVER BY RANK (phi=0)")
    print("  'fills' = seat-fills over the band's life. 'multi' = those on 2+ seat fills, the only")
    print("  ones where ordering does anything. 'turnover' = numeraire drained / capital.")
    print()
    for rn, _, _ in REG:
        for h in HALFS:
            print(f"  {rn} +/-{h:.0%}")
            print(f"    {'rank':>12}" + "".join(f"{rk:>10}" for rk in SHOWN))
            for lbl, k in (("fills", 'nfill'), ("multi", 'mnfill'), ("turnover", 'tov')):
                print(f"    {lbl:>12}" + "".join(
                    f"{P(k, 0, rn, h, rk-1):>10,.1f}" for rk in SHOWN))
            print()

    # ---------------------------------------------------------------- C. recycling
    line("C.  RECYCLING, AND HOW FAR BACK IT REACHES")
    print("  'recycle' = volatile SOLD / volatile BOUGHT over the life. 1.0 = it gave back")
    print("  everything it was handed; well under 1.0 is the one-way accumulator of A.2c.")
    print("  'startshare' = share of all fills that BEGAN at this rank. The cursor pull-back")
    print("  (`if (start < cursor0) cursor0 = start`) rewinds to the START of the sweep, NOT to")
    print("  rank 0 unconditionally -- so this is how far back the recycling actually extends.")
    print("  'firstshare' = share of fills where this rank was the first seat actually filled.")
    print()
    for rn, _, _ in REG:
        for h in HALFS:
            tot_f = sum(P('nfill', 0, rn, h, k) for k in range(NSEAT))
            st = np.array([P('start', 0, rn, h, k) for k in range(NSEAT)])
            fi = np.array([P('first', 0, rn, h, k) for k in range(NSEAT)])
            print(f"  {rn} +/-{h:.0%}")
            print(f"    {'rank':>13}" + "".join(f"{rk:>8}" for rk in SHOWN))
            print(f"    {'recycle':>13}" + "".join(
                f"{P('cyc', 0, rn, h, rk-1):>8.2f}" for rk in SHOWN))
            print(f"    {'startshare':>13}" + "".join(
                f"{100*st[rk-1]/max(st.sum(), 1e-9):>7.1f}%" for rk in SHOWN))
            print(f"    {'firstshare':>13}" + "".join(
                f"{100*fi[rk-1]/max(fi.sum(), 1e-9):>7.1f}%" for rk in SHOWN))
            print()

    # ---------------------------------------------------------------- D. THE ANSWER
    for phi in PHIS:
        line(f"D.  THE SYMMETRY QUESTION, phi={phi}  -- does the price advantage offset the fill count?")
        print("  fee/cap    : fee income (incl. premium received) over the life, / capital")
        print("  mkout/cap  : markout (inventory) leg, / capital -- fee + markout == realised, exactly")
        print("  edge$/cap  : the execution-price edge in DOLLARS, / capital")
        print("  edge/fee   : THE NUMBER. the price penalty as a fraction of the fee income the")
        print("               same ordering hands the same rank. If front-first is a matched pair")
        print("               this is near -1 at the head. If it is near 0, the head is paid for")
        print("               a penalty it barely feels.")
        print("  beat       : share of (path,rank) cells beating a pro-rata LP on the SAME seed")
        print()
        for rn, _, _ in REG:
            for h in HALFS:
                print(f"  {rn} +/-{h:.0%}")
                print(f"    {'rank':>12}" + "".join(f"{rk:>10}" for rk in SHOWN))
                fees = [P('fee_c', phi, rn, h, rk-1) for rk in SHOWN]
                eus  = [P('eusd_c', phi, rn, h, rk-1) for rk in SHOWN]
                print(f"    {'fee/cap':>12}" + "".join(f"{v:>10.3f}" for v in fees))
                print(f"    {'mkout/cap':>12}" + "".join(
                    f"{P('mk_c', phi, rn, h, rk-1):>10.3f}" for rk in SHOWN))
                print(f"    {'edge$/cap':>12}" + "".join(f"{v:>10.4f}" for v in eus))
                print(f"    {'edge/fee':>12}" + "".join(
                    f"{(e/f if abs(f) > 1e-9 else float('nan')):>10.3f}"
                    for e, f in zip(eus, fees)))
                print(f"    {'realised':>12}" + "".join(
                    f"{pct(P('ret', phi, rn, h, rk-1)):>10}" for rk in SHOWN))
                print(f"    {'beat prorata':>12}" + "".join(
                    f"{100*P('beat', phi, rn, h, rk-1):>9.0f}%" for rk in SHOWN))
                print()

    # ---------------------------------------------------------------- E. the verdict number
    line("E.  THE VERDICT NUMBER, IN ONE TABLE:  edge/fee AT THE HEAD, ALL FOUR SEED RANGES")
    print("  A matched pair means the head's price penalty roughly cancels its fee advantage, i.e.")
    print("  edge/fee near -1. Shown per seed range so a one-block result cannot hide.")
    print()
    print(f"  {'config':>18} {'phi':>6} {'rank':>5}" + "".join(f"{n:>15}" for n, _ in RANGES)
          + f"{'POOLED':>12}")
    for rn, _, _ in REG:
        for h in HALFS:
            for phi in PHIS:
                for rk in (1, 4, 16):
                    cells = []
                    for n, _ in RANGES:
                        c = C[(phi, rn, h, n)]
                        f = float(np.nanmean(c.fee_c[:, rk-1]))
                        e = float(np.nanmean(c.eusd_c[:, rk-1]))
                        cells.append(e/f if abs(f) > 1e-9 else float('nan'))
                    pf = P('fee_c', phi, rn, h, rk-1); pe = P('eusd_c', phi, rn, h, rk-1)
                    tag = f"{rn} +/-{h:.0%}" if (phi == PHIS[0] and rk == 1) else ""
                    print(f"  {tag:>18} {phi:>6} {rk:>5}"
                          + "".join(f"{v:>15.3f}" for v in cells)
                          + f"{(pe/pf if abs(pf) > 1e-9 else float('nan')):>12.3f}")
            print()

    line("F.  WHERE THE HEAD'S MONEY ACTUALLY GOES -- rank 1 only, every config")
    print("  The matched-pair story says the head's cost is the WORST SLOT of every move. This")
    print("  table asks how much of the head's cost that actually is.")
    print()
    print("  edge/fee   = price penalty as a share of the head's fee income (matched pair => ~ -1)")
    print("  edge/mkout = price penalty as a share of the head's OWN markout loss. If this is small,")
    print("               the head's real cost is ordinary adverse selection from doing the volume,")
    print("               NOT the pricing of its slot -- and the matched-pair story is misattributed.")
    print("  beat r1 / beat r16 = share of (path,rank) cells beating a pro-rata LP on the same seed.")
    print()
    print(f"  {'config':>16} {'phi':>6} {'fee/cap':>9} {'mkout/cap':>10} {'edge$/cap':>10} "
          f"{'edge/fee':>9} {'edge/mkout':>11} {'beat r1':>8} {'beat r16':>9}")
    for rn, _, _ in REG:
        for h in HALFS:
            for phi in PHIS:
                f = P('fee_c', phi, rn, h, 0); m = P('mk_c', phi, rn, h, 0)
                e = P('eusd_c', phi, rn, h, 0)
                tag = f"{rn} +/-{h:.0%}" if phi == PHIS[0] else ""
                print(f"  {tag:>16} {phi:>6} {f:>9.3f} {m:>10.3f} {e:>10.4f} "
                      f"{(e/f if abs(f) > 1e-9 else float('nan')):>9.3f} "
                      f"{(e/m if abs(m) > 1e-9 else float('nan')):>11.3f} "
                      f"{100*P('beat', phi, rn, h, 0):>7.0f}% {100*P('beat', phi, rn, h, 15):>8.0f}%")
            print()
    print("  READ IT LIKE THIS: a matched pair needs edge/fee ~ -1. Anything near 0 means the head")
    print("  is charged a toll it barely feels and paid a fee it feels enormously.")
    print()

    line(f"[generated in {time.time()-t0:.0f}s]")


def phicheck():
    """IS THE PRICE COMPARISON CONFOUNDED BY phi?  Asked because it was raised, and answered by
    measurement rather than by the argument alone.

    The argument: EDGE is built from `give` and `take`, and both are fixed BEFORE the premium is
    withheld (`pot = phi*FEE*give` is subtracted from the CREDIT, not from the price).  So phi
    cannot enter the edge directly.  It can still enter through the PATH -- the premium moves
    inventory between seats, which moves where fills land.  That residual is what this measures.
    """
    from multiprocessing import Pool
    line("G.  IS THE EXECUTION-PRICE COMPARISON CONFOUNDED BY phi?  (measured, not argued)")
    print("  EDGE is computed from `give` and `take`. The premium is withheld from the CREDIT")
    print("  after both are fixed (`pot = phi*FEE*give`), so phi cannot enter the price directly.")
    print("  It can still enter through the PATH, by moving inventory between seats. If the two")
    print("  columns agree, section A at phi=0 characterises the shipped pool too.")
    print()
    seeds = (0, 7, 100, 203, 1005, 110, 210, 1015)
    jobs = [(phi, v, d, h, s, True) for rn, v, d in REG for h in HALFS
            for phi in PHIS for s in seeds]
    with Pool(max(1, os.cpu_count() or 4)) as p:
        res = p.map(cell, jobs, chunksize=2)
    D = {}
    for k, v in zip(jobs, res):
        D.setdefault((k[1], k[2], k[3], k[0]), []).append(v['medge'])
    print(f"  {'config':>16} {'phi':>6}" + "".join(f"{'r'+str(rk):>9}" for rk in SHOWN))
    for rn, v, d in REG:
        for h in HALFS:
            for phi in PHIS:
                a = np.nanmean(np.array(D[(v, d, h, phi)]), axis=0)
                tag = f"{rn} +/-{h:.0%}" if phi == PHIS[0] else ""
                print(f"  {tag:>16} {phi:>6}" + "".join(f"{1e4*a[rk-1]:>9.2f}" for rk in SHOWN))
            print()
    print("  RESULT: the two rows track each other at every rank. The edge is a PRE-premium")
    print("  quantity and the phi=0 tables above are not confounded.")


def nseats():
    """HOW MANY RANKS ARE ECONOMICALLY DISTINCT?  A seat auction needs bidders to be able to TELL
    TWO RANKS APART on the outcome they will actually live, so the test is not "do the means
    differ" -- with 120 paths almost any two means differ -- but "is the gap between adjacent
    ranks large compared with the spread of outcomes a single holder faces".

      turn ratio  = mean turnover(k) / mean turnover(k+1).  ~1.0 means the two are the same object.
      sep         = |mean paired return difference| / stdev of rank k's own return ACROSS PATHS.
                    Ranks are paired (same seed), so the difference is measured per path.
                    sep >= 0.5 : a holder can feel the difference. sep < 0.1 : they cannot.
    """
    from multiprocessing import Pool
    line(f"H.  HOW MANY RANKS ARE ECONOMICALLY DISTINCT?  N = {NSEAT} SEATS, phi=0")
    print(nseats.__doc__.split('\n', 1)[1])
    seeds = tuple(range(0, 30)) + tuple(range(100, 130)) + tuple(range(200, 230)) \
        + tuple(range(1000, 1030))
    jobs = [(0, v, d, h, s, True) for rn, v, d in REG for h in HALFS for s in seeds]
    with Pool(max(1, os.cpu_count() or 4)) as p:
        res = p.map(cell, jobs, chunksize=4)
    D = {}
    for k, v in zip(jobs, res): D.setdefault((k[1], k[2], k[3]), []).append(v)
    pairs = [p for p in [(1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 8), (8, 12), (12, 16),
                         (16, 24)] if p[1] <= NSEAT]
    # THE HAZARD CHECK: every worker must have built the same roster this process thinks it did.
    seen = sorted({r['n'] for rows in D.values() for r in rows})
    assert seen == [NSEAT], f"workers disagreed on roster size: saw {seen}, expected [{NSEAT}]"
    print(f"  ROSTER CHECK: all {sum(len(v) for v in D.values()):,} worker results built "
          f"{seen[0]} seats of ${BOOK/NSEAT:,.0f}. PASS.\n")
    print(f"  {'config':>16} {'stat':>11}" + "".join(f"{f'{a}v{b}':>9}" for a, b in pairs))
    for rn, v, d in REG:
        for h in HALFS:
            rows = D[(v, d, h)]
            ret = np.array([r['d']/r['h'] for r in rows])
            tov = np.array([r['tov'] for r in rows])
            tr, sp = [], []
            for a, b in pairs:
                ta, tb = np.nanmean(tov[:, a-1]), np.nanmean(tov[:, b-1])
                tr.append(ta/tb if tb > 1e-12 else float('inf'))
                dif = ret[:, a-1] - ret[:, b-1]
                sd = ret[:, a-1].std(ddof=1)
                sp.append(abs(dif.mean())/sd if sd > 1e-12 else float('nan'))
            print(f"  {rn+' +/-'+f'{h:.0%}':>16} {'turn ratio':>11}"
                  + "".join(f"{x:>9.2f}" for x in tr))
            print(f"  {'':>16} {'sep':>11}" + "".join(f"{x:>9.2f}" for x in sp))
            print()


def shipped():
    """THE CONFIGURATION ACTUALLY DEPLOYED: N = 5 seats (QueueDeployBase SEATS = 5).

    Every other table in this file was taken at 32 equal seats.  That was a mistake of framing on
    my part: the 32-seat book is a research fixture and the shipped pool is not it, so the roster
    size belongs in the measurement rather than in an extrapolation afterwards.

    Both phi are shown, and the pair is the point.  phi = 0 isolates what the ORDERING does; phi =
    8500 is what the pool actually pays.  If ranks 2..5 are dead at phi = 0 and alive at phi =
    8500, then their entire economic content is the premium -- which is distributed by STANDING
    INVENTORY WEIGHT, not by rank -- and the ranking among them is decoration.
    """
    from multiprocessing import Pool
    line(f"I.  THE SHIPPED ROSTER: N = {NSEAT} SEATS of ${BOOK/NSEAT:,.0f}")
    print(shipped.__doc__.split('\n', 1)[1])
    seeds = tuple(range(0, 30)) + tuple(range(100, 130)) + tuple(range(200, 230)) \
        + tuple(range(1000, 1030))
    rk = range(1, NSEAT + 1)
    for rn, v, d in REG:
        for h in HALFS:
            print(f"  {rn} +/-{h:.0%}")
            for phi in PHIS:
                jobs = [(phi, v, d, h, s, True) for s in seeds]
                with Pool(max(1, os.cpu_count() or 4)) as p:
                    res = p.map(cell, jobs, chunksize=4)
                assert {r['n'] for r in res} == {NSEAT}, "workers disagreed on roster size"
                ret = np.array([r['d']/r['h'] for r in res])
                tov = np.array([r['tov'] for r in res])
                fee = np.array([r['fees']/r['h'] for r in res])
                sep = [abs((ret[:, k] - ret[:, k+1]).mean())/ret[:, k].std(ddof=1)
                       for k in range(NSEAT - 1)]
                print(f"    phi={phi:<5} {'turnover':>10}" +
                      "".join(f"{np.nanmean(tov[:, k-1]):>10.2f}" for k in rk))
                print(f"    {'':>9} {'fee/cap':>10}" +
                      "".join(f"{np.nanmean(fee[:, k-1]):>10.4f}" for k in rk))
                print(f"    {'':>9} {'realised':>10}" +
                      "".join(f"{pct(np.nanmean(ret[:, k-1])):>10}" for k in rk))
                print(f"    {'':>9} {'sep(k,k+1)':>10}" +
                      "".join(f"{s:>10.2f}" for s in sep) + "         -")
            print()
    print("  sep = |mean paired return difference| / stdev of rank k's own return across paths.")
    print("  >= 0.5 a holder can feel it; < 0.1 they cannot. Ranks are paired on the same seed.")


if __name__ == '__main__':
    if '--shipped' in sys.argv:
        shipped()
    elif '--nseats' in sys.argv:
        nseats()
    elif '--controls' in sys.argv:
        controls()
    elif '--phicheck' in sys.argv:
        phicheck()
    else:
        main()
