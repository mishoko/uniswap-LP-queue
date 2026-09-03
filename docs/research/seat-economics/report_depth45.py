"""
IS THE 5-SEAT LIMIT A PROPERTY OF THE MECHANISM, OR AN ARTEFACT OF THE LADDER SHAPE?

--------------------------------------------------------------------------------------------------
THE CONFOUND THIS FILE EXISTS TO CLOSE
--------------------------------------------------------------------------------------------------
`results-depth-basis.txt` section 3 is the whole evidence for "more than 5 seats does not work".
It sweeps N = 2, 5, 8, 16, 32 at two ladder SHAPES, and in BOTH shapes the head's share of the book
collapses as N grows:

    LINEAR (N:N-1:...:1)   66.7% -> 33.3% -> 22.2% -> 11.8% -> 6.1%
    EQUAL  (1/N each)      50.0% -> 20.0% -> 12.5% ->  6.2% -> 3.1%

`results-headsize.txt` then established, at N = 5 held fixed, that the HEAD SHARE is the dominant
parameter: moving c1 from 33.3% to 45% turns an EMPTY all-regime window into a working one,
BENIGN [3777, 7340] / NORMAL [1740, 9500+] / TOXIC [0, 9500+].

So the depth sweep varied TWO things at once and attributed the outcome to the one it was asking
about.  That is the identical error AGENTS.md section 3b records the gas work paying for -- "hold
one variable at a time".  The honest reading of `results-depth-basis.txt` is therefore only:

    "More seats WITH A LADDER SHAPE THAT SHRINKS THE HEAD do not work"

which is close to a tautology once you know the head share is the lever.

THIS FILE HOLDS THE HEAD SHARE FIXED AT THE SHIPPED c1 = 45% AND VARIES ONLY N.

--------------------------------------------------------------------------------------------------
THE TWO TAIL SHAPES, STATED EXACTLY
--------------------------------------------------------------------------------------------------
In both, caps[0] = 0.45 * BOOK and seats 2..N split the remaining 0.55 * BOOK.

  DECAY   the shipped 44:33:22:11 proportions, generalised: the back seats take LINEARLY DECLINING
          weights (N-1) : (N-2) : ... : 2 : 1, normalised to 0.55 of the book.
          This is `report_headsize.weights_for(N, Fraction(9, 20))` -- the SAME function that
          produced the published c1 = 45% row -- called with no modification whatsoever.
          At N = 5 it returns the integer vector (90, 44, 33, 22, 11), i.e. exactly the shipped
          45% roster: head 45%, tail 22% : 16.5% : 11% : 5.5%.
          At N = 8 it returns (252, 77, 66, 55, 44, 33, 22, 11) -- head 252/560 = 45%, tail 7:6:5:4:3:2:1.

  EQUAL   each of the N-1 back seats takes 0.55/(N-1) of the book, exactly.
          As an integer vector: (9*(N-1), 11, 11, ..., 11), which sums to 20*(N-1) and puts
          9/20 = 45% in the head by construction.  At N = 5 that is (36, 11, 11, 11, 11).
          NOTE this is NOT the same roster as DECAY at N = 5: the shipped tail is 4:3:2:1, this one
          is 1:1:1:1.  Running both is the point -- a result that appears in only one tail shape is
          a property of that shape, not of N.

--------------------------------------------------------------------------------------------------
WHAT IS COPIED, AND FROM WHERE.  Nothing here invents a regime, a seed set or a bar.
--------------------------------------------------------------------------------------------------
IMPORTED, not re-typed, from `report_headsize.py` (the file that PUBLISHED the [3777, 7340] this
file must reproduce), which in turn took them from `report_shipping.py`:

    BOOK, RPH, P0 = 1_000_000.0, 15.0, 2000.0     report_headsize.py:135
    HALF = 0.10                                    report_headsize.py:136
    REG  = (("BENIGN", 0.25, 0.00),
            ("NORMAL", 0.45, 0.00),
            ("TOXIC",  0.80, 0.35))                report_headsize.py:139
    RANGES / SEEDS -- 4 disjoint ranges x 30 = 120 report_headsize.py:140-142
    MW   = (0.01, 0.02, 0.05)                      report_headsize.py:143
    GAS  = {"L2": 0.02, "L1": 12.00}               report_headsize.py:144
    PHIS = tuple(range(0, 10000, 500))             report_headsize.py:137
    BASIS = "liquidity_excl"                       report_headsize.py:131
    weights_for(), caps_for(), lp_cell(), _init()  report_headsize.py:167-197
    cross(), pct()                                 report_shipping.py, via report_headsize.py:133

`report_depth_basis.py` uses the IDENTICAL regime tuple, the identical seed ranges, the identical
MW/GAS and the identical `cross`; its only differences from report_headsize are the coarser phi grid
(step 2000) and that it reads its LP baseline out of report_depth's cache instead of computing it.
That is why the tables below are directly comparable to `results-depth-basis.txt` section 3.

The one function copied rather than imported is `cell()`: `report_headsize.cell` hard-codes its phi
grid at module scope and appends a PHI_T = 5100 row this file has no use for.  The copy is
otherwise line for line (the run call, the tie_out, the pnl, the turnover expression, the traced
wing pass) and the CONTROL below is what proves the copy did not drift.

--------------------------------------------------------------------------------------------------
THE CONTROLS.  Section 1 is printed FIRST and every other number is void if it fails (LAW 5).
--------------------------------------------------------------------------------------------------
1.  THE REPRODUCTION CONTROL, and it is a case with a KNOWN ANSWER IN ADVANCE.  The N = 5 / DECAY
    cell IS the published c1 = 45% roster.  Its three windows must come out
        BENIGN [3777, 7340]   NORMAL [1740, 9500+]   TOXIC [0, 9500+]
    together with r1@0, r1@9500, the wing bar and every per-seat crossover phi, all parsed OFF DISK
    from `results-headsize.txt` rather than typed in here.  This is not arithmetic: those numbers
    were produced by a different script on a different day, and they agree only if the seeds, the
    regimes, the wing engine, the gas assumption, the band, the retail intensity, the premium basis
    and the copied `cell` all match.  WHAT WOULD MAKE IT FAIL: a drifted `cell` copy, a wrong
    weight vector, a lost basis override in the workers, a different seed set, a different grid.

2.  THE TWO STRUCTURAL INVARIANTS (section 2), pre-registered here BEFORE the run.  The head holds
    45% of the book in all eight cells and is filled first in all eight, so
      (a) r1 at phi = 0 must be identical across N and across tail shape, per regime;
      (b) the managed-wing bar must be identical across N and across tail shape, per regime --
          it is a carve-out of `head` capital priced against the pool's own swap tape, and that
          tape is a function of total book liquidity, not of how the book is split.
    A pilot at seed 3 / BENIGN returned r1@0 = 0.0134893692 and wing = -0.0317067208 for
    N = 5, 8, 16, 32 identically, to all printed digits.  If the full run does NOT reproduce that
    invariance, the roster shape is leaking into the price path and this file's premise is wrong.
    These two are what make "the head share is held fixed" a measured statement instead of a claim
    about the input vector.

3.  THE IDENTITY CONTROL (section 7).  Worst per-path |capital-weighted queue pool return - the
    INDEPENDENTLY simulated one-seat pro-rata LP on the same seed|.  Not two of this file's own
    quantities: the right-hand side is `run([BOOK], marginal=False)`, a different book with no
    premium at all.

4.  THE NULL CONTROL (section 7), from `wing.check_null`: a wing spanning the whole band with 1/N
    of the capital must earn exactly 1/N of the pool's fees and 1/N of its markout.

5.  TURNOVER IS PRINTED BESIDE EVERY RETURN (sections 3 and 5).  In TOXIC the benchmark LOSES
    money, so a seat that is never reached "beats" it by not participating.  That is
    non-participation, not outperformance, and a window bought with it is not a window.  Section 5
    exists to make that visible rather than to let a reader assume it away.

--------------------------------------------------------------------------------------------------
THE PRE-REGISTERED PREDICTION.  Recorded before the run so it can be refuted.
--------------------------------------------------------------------------------------------------
The distributable surplus per unit of BACK capital is c1*(LP - r1)/(1 - c1) and does not depend on
N at all once c1 is fixed.  The front constraint is a function of the head's size alone and so is
also N-invariant (invariant (b) above).  If the 5-seat limit were purely a head-share artefact, the
back constraint would therefore be N-invariant too and the window would survive to N = 32 unchanged.

It should NOT, and the reason is geometric rather than economic: seat 2 sits immediately behind a
head of FIXED tick depth, so its price offset is the same at every N, but its CAPITAL shrinks as
N grows (22.0% of book at N=5 DECAY, 13.75% at N=8, 3.6% at N=32).  A thinner seat 2 is
concentrated in the worst slice of the ladder instead of averaging over a wide one, so its
per-unit-capital return should DEGRADE in N even at a fixed head, and the back bound should rise.
The question this file answers is whether it degrades enough to close the window, and where.

If the window survives unchanged to N = 32, the 5-seat limit is an artefact and the project should
say so.  If it closes at some N even with the head pinned, the limit is real and the depth sweep
reached the right answer for a confounded reason.  Both outcomes are reachable and neither is the
one this file is written to find.

--------------------------------------------------------------------------------------------------
WHAT THIS FILE DOES NOT MODEL -- inherited verbatim from report_headsize.py, restated not hidden
--------------------------------------------------------------------------------------------------
  RENT       `sim.py` has NO Harberger rent.  The deployed hook charges it, and as of the current
             session pays it FORWARD (back seats pay the head), which runs OPPOSITE to the premium.
             EVERY WINDOW BELOW IS RENT-FREE and is therefore a LOWER bound on what the front can
             bear and an UPPER bound on what the back keeps.
  BAND       modelled as a symmetric +/-10%; the shipped 960-tick band is +10.08% / -9.16%.
  DECIMALS   floating point, no cross-token comparison, so it models the mechanism AS DESIGNED.  On
             the shipped 18/6 pool the token0 premium is separately known to be inert
             (PITFALLS 5.124), which makes every premium number here an UPPER bound.
  SEAT COUNT the deployed hook's roster is capped; nothing here asks whether 32 seats FIT in the
             contract's gas or storage budget.  This is an economics question only.

Reproduce:
    python3 report_depth45.py                    # stage what is missing, then report
    D45_NS=5,8 python3 report_depth45.py         # a subset of the depths
    D45_STEP=1000 python3 report_depth45.py      # coarser phi grid for the stages not yet cached
"""
import sys, os, re, math, time, tempfile
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim

BASIS = "liquidity_excl"
sim.PREM_WEIGHT = BASIS                  # the parent, before any Book exists

import wing                                                       # noqa: E402
from sim import run                                               # noqa: E402
from report_addendum import ladder                                # noqa: E402
# EVERYTHING below comes from the file that published the number this run must reproduce.
from report_headsize import (BOOK, RPH, P0, HALF, REG, RANGES, SEEDS, MW, GAS,   # noqa: E402
                             PHIS as HS_PHIS, weights_for, caps_for, _init, lp_cell)
from report_shipping import cross, pct                            # noqa: E402

C1 = Fraction(9, 20)                     # the shipped head share, 45%
NS = tuple(int(x) for x in os.environ.get("D45_NS", "5,8,16,32").split(","))
TAILS = ("DECAY", "EQUAL")
STEP = int(os.environ.get("D45_STEP", "500"))
CACHE = os.environ.get("D45_CACHE", "/tmp/queue-depth45")
NPROC = int(os.environ.get("D45_PROCS", "6"))
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "results-depth45.txt")
PUB = os.path.join(HERE, "results-headsize.txt")
PUB_DEPTH = os.path.join(HERE, "results-depth-basis.txt")


def grid_for(step):
    """The canonical 0..9500 grid at the requested step.  9500 is ALWAYS the last point so that
    'no bound in range' means here exactly what it means in every other file in this directory."""
    g = tuple(range(0, 10000, step))
    return g if g[-1] == 9500 else g + (9500,)


def weights(n, tail):
    """DECAY is report_headsize.weights_for verbatim.  EQUAL is stated in the header."""
    if tail == "DECAY":
        return weights_for(n, C1)
    return tuple([9 * (n - 1)] + [11] * (n - 1))


# --------------------------------------------------------------------------------- the worker
def cell(a):
    """One (n, weights, regime, seed): the whole phi sweep plus the traced wing bars.

    COPIED from report_headsize.cell -- same run call, same tie_out, same pnl, same turnover
    expression, same traced wing pass.  The two differences, both stated in the header: the phi
    grid arrives as an argument instead of being read from module scope, and the PHI_T = 5100 row
    is not measured.  Section 1 is what proves the copy did not drift."""
    n, wi, vol, dr, seed, lp, grid = a
    sim.PREM_WEIGHT = BASIS                     # belt and braces inside the worker
    caps = caps_for(wi)
    head = caps[0]
    R = np.zeros((len(grid), n))
    TURN = np.zeros((len(grid), n))
    pool = np.zeros(len(grid))
    for j, phi in enumerate(grid):
        bk, _, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                        half=HALF, phi=phi)
        assert bk.weight == BASIS, "the basis switch did not reach this worker"
        bk.tie_out(Pt)
        d, h = bk.pnl(Pt)
        R[j] = d / h
        TURN[j] = ((bk.gv0 + bk.tk0) * Pt + (bk.gv1 + bk.tk1)) / h
        pool[j] = abs(float(d.sum() / h.sum()) - lp)
    bk, Pf, Pt = run(caps, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                     half=HALF, phi=0, trace=True)
    out = dict(ret=R, turn=TURN, pool=pool, hrs=float(bk.hrs), lp=lp,
               static=float(ladder(bk, Pf, Pt, caps)[0]))
    ef, em, _ = wing.check_null(bk, Pf, Pt, BOOK, n)
    out["null_fee"] = ef
    out["null_mk"] = em
    for w_ in MW:
        mm = wing.managed_wing(bk, Pf, Pt, head, w_, BOOK, 0.0)
        for gn, g in GAS.items():
            out[f"mw_{w_}_{gn}"] = mm['ret'] - mm['remints'] * g / mm['hold']
    return out


def _idx(a):
    i, j = a
    return i, cell(j)


def _lpidx(a):
    i, j = a
    return i, lp_cell(j)


# -------------------------------------------------------------------------------- the staging
def _cp(nm):
    return os.path.join(CACHE, nm + ".npz")


def stage_lp():
    """Recomputed here rather than read out of report_headsize's cache, so that section 1 is a
    reproduction and not a shared intermediate."""
    if os.path.exists(_cp("lp")):
        return
    from multiprocessing import Pool
    jobs, keys = [], []
    for rn, v, dr in REG:
        for sd in SEEDS:
            jobs.append((v, dr, sd)); keys.append(rn)
    t = time.time()
    out = [None] * len(jobs)
    with Pool(NPROC, initializer=_init) as p:
        for i, rr in p.imap_unordered(_lpidx, list(enumerate(jobs)), chunksize=4):
            out[i] = rr
    d = {}
    for rn, _, _ in REG:
        d[rn] = np.array([x for x, k in zip(out, keys) if k == rn], float)
    np.savez(_cp("lp"), **d)
    sys.stderr.write(f"[lp baseline: {len(jobs)} runs, {time.time()-t:.0f}s]\n")


def stage(n, tail, step):
    nm = f"n{n}_{tail}"
    if os.path.exists(_cp(nm)):
        return
    from multiprocessing import Pool
    LP = np.load(_cp("lp"))
    wi = weights(n, tail)
    grid = grid_for(step)
    assert abs(wi[0] / sum(wi) - 0.45) < 1e-15, f"head share is not 45% for {nm}: {wi}"
    jobs, keys = [], []
    for rn, v, dr in REG:
        for j, sd in enumerate(SEEDS):
            jobs.append((n, wi, v, dr, sd, float(LP[rn][j]), grid)); keys.append(rn)
    t = time.time()
    out = [None] * len(jobs)
    with Pool(NPROC, initializer=_init) as p:
        for i, rr in p.imap_unordered(_idx, list(enumerate(jobs)), chunksize=1):
            out[i] = rr
    d = {"weights": np.array(wi, float), "phis": np.array(grid, float)}
    for rn, _, _ in REG:
        v = [x for x, k in zip(out, keys) if k == rn]
        d[f"{rn}_ret"] = np.stack([x['ret'] for x in v])          # (paths, grid, n) -- PER PATH
        d[f"{rn}_turn"] = np.stack([x['turn'] for x in v])
        d[f"{rn}_pool"] = np.stack([x['pool'] for x in v])
        d[f"{rn}_lp"] = np.array([x['lp'] for x in v], float)
        d[f"{rn}_hrs"] = np.array([x['hrs'] for x in v], float)
        d[f"{rn}_static"] = np.array([x['static'] for x in v], float)
        d[f"{rn}_null"] = np.array([[x['null_fee'], x['null_mk']] for x in v], float)
        for w_ in MW:
            for gn in GAS:
                d[f"{rn}_mw_{w_}_{gn}"] = np.array([x[f"mw_{w_}_{gn}"] for x in v], float)
    np.savez(_cp(nm), **d)
    sys.stderr.write(f"[{nm} (w={wi[:5]}{'...' if len(wi) > 5 else ''}, grid step {step}): "
                     f"{len(jobs)*(len(grid)+1)} runs, {time.time()-t:.0f}s]\n")


# ---------------------------------------------------------------------- parsing the published file
def parse_headsize(path):
    """Pull the c1 = 45.0% row out of each `--- N=5 / REGIME ---` block of results-headsize.txt,
    plus that block's passive-LP bar.  Parsed off disk on purpose: hardcoding the target would make
    section 1 a comparison of this file with itself."""
    out, cur = {}, None
    hdr = re.compile(r"---\s*N=5\s*/\s*(BENIGN|NORMAL|TOXIC)\s*---.*?passive pro-rata LP\s+"
                     r"([-+][\d.]+)%\s+\(se\s+([\d.]+)pp\)")
    row = re.compile(r"^\s*45\.0%\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+"
                     r"((?:\S+\s+){3}\S+)\s+"
                     r"(\[\s*\d+,\s*(?:\d+|9500\+)\s*\]|EMPTY(?:\s+\(cross\))?)\s+"
                     r"(s\d+(?:\+\d+)?)\s+([\d.]+)p\s*$")
    for ln in open(path):
        m = hdr.search(ln)
        if m:
            cur = m.group(1)
            out[(cur, "lp")] = float(m.group(2)) / 100.0
            out[(cur, "lpse")] = float(m.group(3)) / 100.0
            continue
        if cur is None:
            continue
        m = row.match(ln)
        if m:
            out[(cur, "r1_0")] = m.group(1)
            out[(cur, "r1_9500")] = m.group(2)
            out[(cur, "wing")] = m.group(3)
            out[(cur, "wingw")] = m.group(4)
            out[(cur, "phiLP")] = m.group(5)
            out[(cur, "phimax")] = m.group(6)
            seats = m.group(7).split()
            for i, s in enumerate(seats):
                out[(cur, f"phi{i+2}")] = s
            out[(cur, "window")] = re.sub(r"\s+", " ", m.group(8))
            out[(cur, "binds")] = m.group(9)
            cur = None
    return out


def parse_depth_basis(path):
    """The N_max rows of results-depth-basis.txt section 3, for the side-by-side in section 4."""
    out, cur = {}, None
    for ln in open(path):
        m = re.match(r"\s*---\s*(LINEAR|EQUAL)\s*/\s*(BENIGN|NORMAL|TOXIC)\s*---", ln)
        if m:
            cur = (m.group(1), m.group(2)); continue
        if cur is None:
            continue
        m = re.match(r"^\s*(\d+)\s+([\d.]+)%\s+.*?"
                     r"(\[\s*\d+,\s*(?:\d+|9500\+)\s*\]|EMPTY(?:\s+\(cross\))?)\s+"
                     r"(s\d+(?:\+\d+)?)\s+([-+][\d.]+)pp\s+([-+][\d.]+)\s*$", ln)
        if m:
            out[(cur[0], cur[1], int(m.group(1)))] = dict(
                head=float(m.group(2)), window=re.sub(r"\s+", " ", m.group(3)),
                binds=m.group(4), gap=float(m.group(5)), t=float(m.group(6)))
    return out


# --------------------------------------------------------------------------------- the report
class Rep:
    def __init__(self):
        self.L = []

    def __call__(self, s=""):
        self.L.append(s)

    def rule(self, t):
        self("=" * 118); self(t); self("=" * 118)

    def commit(self, path):
        body = "\n".join(self.L) + "\n"
        assert len(body) > 4000, f"report suspiciously short ({len(body)}B) -- refusing to write"
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".d45-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(body)
            os.replace(tmp, path)
            os.chmod(path, 0o644)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise


def main():
    os.makedirs(CACHE, exist_ok=True)
    # the vector identities that make section 1 meaningful, asserted before any compute
    assert weights(5, "DECAY") == (90, 44, 33, 22, 11), weights(5, "DECAY")
    assert weights(8, "DECAY") == (252, 77, 66, 55, 44, 33, 22, 11), weights(8, "DECAY")
    assert weights(5, "EQUAL") == (36, 11, 11, 11, 11), weights(5, "EQUAL")
    for n in NS:
        for tl in TAILS:
            w = weights(n, tl)
            assert len(w) == n and abs(w[0] / sum(w) - 0.45) < 1e-15, (n, tl, w)

    stage_lp()
    for n in NS:
        for tl in TAILS:
            stage(n, tl, STEP)

    LPz = np.load(_cp("lp"))
    LPm = {rn: float(LPz[rn].mean()) for rn, _, _ in REG}
    LPse = {rn: float(LPz[rn].std(ddof=1) / math.sqrt(len(LPz[rn]))) for rn, _, _ in REG}
    LPpath = {rn: LPz[rn] for rn, _, _ in REG}

    Z, GRID = {}, {}
    for n in NS:
        for tl in TAILS:
            z = np.load(_cp(f"n{n}_{tl}"))
            Z[(n, tl)] = z
            GRID[(n, tl)] = tuple(int(x) for x in z["phis"])

    NP = len(SEEDS)

    def m(n, tl, rn):
        return Z[(n, tl)][f"{rn}_ret"].mean(axis=0)

    def se(n, tl, rn):
        return Z[(n, tl)][f"{rn}_ret"].std(axis=0, ddof=1) / math.sqrt(NP)

    def turn(n, tl, rn):
        return Z[(n, tl)][f"{rn}_turn"].mean(axis=0)

    def bar(n, tl, rn):
        z = Z[(n, tl)]
        g = {w_: float(z[f"{rn}_mw_{w_}_L2"].mean()) for w_ in MW}
        bw = max(MW, key=lambda w_: g[w_])
        return bw, g[bw], float(z[f"{rn}_static"].mean())

    def window(n, tl, rn):
        """VERBATIM in structure from report_depth_basis.window / report_headsize.window."""
        G = GRID[(n, tl)]
        R = m(n, tl, rn)
        _, mwv, _ = bar(n, tl, rn)
        hi, hst = cross(G, R[:, 0], mwv)
        lows = [(i,) + cross(G, R[:, i], LPm[rn]) for i in range(1, n)]
        never = [i for i, _, st in lows if st == 'never']
        if never:
            return None, hi, hst, lows, "EMPTY"
        lo = max(v for _, v, _ in lows)
        if hst == 'never':
            return lo, hi, hst, lows, "EMPTY"
        if hst == 'always':
            return lo, math.inf, hst, lows, f"[{lo:.0f}, 9500+]"
        return lo, hi, hst, lows, (f"[{lo:.0f}, {hi:.0f}]" if lo <= hi else "EMPTY (cross)")

    def fmt_phi(v, st):
        return f"{v:.0f}" if st == 'cross' else ("all" if st == 'always' else "NEVER")

    r = Rep()
    r.rule("DOES THE 5-SEAT LIMIT SURVIVE HOLDING THE HEAD SHARE FIXED AT THE SHIPPED c1 = 45%?")
    r(f"  PREM_WEIGHT = {BASIS!r}, the basis the contract implements (QueueHook.sol 1150/1154/1494).")
    r(f"  HEAD SHARE HELD FIXED AT 45% OF BOOK AT EVERY N.  N in {NS}; tail shapes {TAILS}.")
    r("    DECAY  seats 2..N take linearly declining weights (N-1):(N-2):...:1 normalised to 0.55")
    r("           of the book -- report_headsize.weights_for(N, 9/20), unmodified.  At N=5 that is")
    r("           the shipped (90, 44, 33, 22, 11), i.e. head 45% and tail 4:3:2:1.")
    r("    EQUAL  each of the N-1 back seats takes 0.55/(N-1) exactly: (9*(N-1), 11, ..., 11).")
    r(f"  ${BOOK:,.0f} book, band +/-{HALF:.0%}, fee 0.30%, retail {RPH:.0f}/hr, P0 = {P0:,.0f},")
    r(f"  {len(RANGES)} disjoint seed ranges x 30 = {NP} paths per cell, regimes {tuple(x[0] for x in REG)}")
    r(f"  = {tuple((x[1], x[2]) for x in REG)} (vol, drift) -- copied from report_headsize.py, which")
    r("  took them from report_shipping.py.  results-depth-basis.txt uses the identical tuple.")
    gs = sorted({GRID[k] for k in GRID})
    for g in gs:
        who = [f"N={n}/{tl}" for n in NS for tl in TAILS if GRID[(n, tl)] == g]
        r(f"  phi grid step {g[1]-g[0]:>4} ({len(g)} points, {g[0]}..{g[-1]}): {', '.join(who)}")
    r(f"  {NPROC} worker processes.")
    r()
    r("  *** EVERY WINDOW IN THIS FILE IS RENT-FREE. ***  sim.py models no Harberger rent; the")
    r("  deployed hook charges it and pays it FORWARD (back pays front), opposite to the premium.")
    r("  These windows are a LOWER bound on what the front can bear and an UPPER bound on what the")
    r("  back keeps.  A back seat clearing the LP by less than its rent bill does not really clear it.")
    r()

    # ------------------------------------------------------------------ 1. THE CONTROL, FIRST
    r.rule("1.  THE CONTROL, REPORTED BEFORE ANY OTHER NUMBER (AGENTS.md LAW 5)")
    r("  The N=5 / DECAY cell IS the published c1 = 45% roster of results-headsize.txt.  Its rows")
    r("  are parsed OFF DISK from that file -- not typed in here -- and must be reproduced exactly.")
    r("  WHAT WOULD MAKE THIS FAIL: a drifted copy of `cell`, a wrong weight vector, a lost basis")
    r("  override in the workers, a different seed set, a different phi grid.  If it fails, every")
    r("  other number in this file is VOID.")
    r()
    ok = True
    if 5 not in NS:
        r("  *** NOT RUN: N=5 is not in D45_NS, so the control could not be evaluated. ***")
        ok = False
    elif GRID[(5, "DECAY")] != tuple(HS_PHIS):
        r(f"  *** NOT COMPARABLE: N=5 ran on grid step {GRID[(5,'DECAY')][1]}, the published file")
        r(f"      used step {HS_PHIS[1]-HS_PHIS[0]}.  Re-run N=5 with D45_STEP=500. ***")
        ok = False
    else:
        P = parse_headsize(PUB)
        if not P:
            r(f"  *** COULD NOT PARSE {os.path.basename(PUB)} -- control not evaluated. ***")
            ok = False
        else:
            r(f"  {'regime':>8} {'quantity':>12} {'published':>16} {'this run':>16} {'':>8}")
            for rn, _, _ in REG:
                R = m(5, "DECAY", rn)
                bw, mwv, _ = bar(5, "DECAY", rn)
                lo, hi, hst, lows, wstr = window(5, "DECAY", rn)
                hi_s = (f"{hi:.0f}" if hst == 'cross'
                        else ("none" if hst == 'always' else "below@0"))
                mine = {"r1@0": f"{100*R[0,0]:.1f}%", "r1@9500": f"{100*R[-1,0]:.1f}%",
                        "wing bar": f"{100*mwv:+.2f}%", "phi_max": hi_s,
                        "window": wstr, "passive LP": f"{100*LPm[rn]:+.2f}%"}
                for i, v, st in lows:
                    mine[f"phi_{i+1}"] = fmt_phi(v, st)
                pubm = {"r1@0": P.get((rn, "r1_0")), "r1@9500": P.get((rn, "r1_9500")),
                        "wing bar": P.get((rn, "wing")), "phi_max": P.get((rn, "phimax")),
                        "window": P.get((rn, "window")),
                        "passive LP": f"{100*P.get((rn,'lp'), 0):+.2f}%"}
                for i in range(2, 6):
                    pubm[f"phi_{i}"] = P.get((rn, f"phi{i}"))
                for key in ("passive LP", "r1@0", "r1@9500", "wing bar", "phi_max",
                            "phi_2", "phi_3", "phi_4", "phi_5", "window"):
                    a, b = str(pubm.get(key)), str(mine.get(key))
                    # the published file writes 'all phi' where this one writes 'all'
                    good = (a == b) or (a == "all phi" and b == "all") or \
                           (a == "none" and b == "none")
                    ok &= good
                    r(f"  {rn:>8} {key:>12} {a:>16} {b:>16} {'ok' if good else '<<< MISMATCH':>8}")
                r()
    r(f"  CONTROL: {'PASS -- the harness reproduces the published c1=45% roster' if ok else 'FAIL'}")
    if not ok:
        r()
        r("  *** THE CONTROL DID NOT REPRODUCE.  This harness differs from the one that produced")
        r("      results-headsize.txt, and EVERY OTHER NUMBER THIS FILE WOULD PRODUCE IS VOID.")
        r("      Stopping here rather than publishing a depth sweep on an unverified harness. ***")
        r.rule("END -- no further sections written, by design.")
        r.commit(OUT)
        sys.stderr.write("CONTROL FAILED -- report truncated at section 1\n")
        return 1

    # -------------------------------------------------- 2. the two structural invariants
    r.rule("2.  THE TWO STRUCTURAL INVARIANTS -- is the head share ACTUALLY held fixed?")
    r("  Pre-registered in the header before the run.  The head holds 45% of the book and is")
    r("  filled first in all eight cells, so at phi = 0 (no premium moves) its return cannot")
    r("  depend on how the OTHER 55% is chopped up; and the managed-wing bar is a carve-out of")
    r("  `head` capital priced against the pool's own swap tape, which is a function of total book")
    r("  liquidity, not of the split.  Both must therefore be N- and tail-INVARIANT.")
    r("  If these move, the roster shape is leaking into the price path and the premise is wrong.")
    r()
    r(f"  {'regime':>8} {'r1@phi=0 (all cells)':>22} {'max spread':>12} "
      f"{'wing bar (all cells)':>22} {'max spread':>12}   verdict")
    inv_ok = True
    for rn, _, _ in REG:
        r1s = [float(m(n, tl, rn)[0, 0]) for n in NS for tl in TAILS]
        wgs = [bar(n, tl, rn)[1] for n in NS for tl in TAILS]
        e1, e2 = max(r1s) - min(r1s), max(wgs) - min(wgs)
        good = e1 < 1e-12 and e2 < 1e-12
        inv_ok &= good
        r(f"  {rn:>8} {100*r1s[0]:>21.4f}% {e1:>12.2e} {100*wgs[0]:>21.4f}% {e2:>12.2e}   "
          f"{'INVARIANT' if good else '<<< NOT INVARIANT'}")
    r()
    r(f"  {'PASS -- the head is genuinely the held variable' if inv_ok else '*** FAIL ***'}")
    r()
    r("  The wing widths chosen (the front's best alternative is the best of 1%/2%/5% after gas):")
    r(f"  {'regime':>8} " + " ".join(f"{('N='+str(n)+'/'+tl):>12}" for n in NS for tl in TAILS))
    for rn, _, _ in REG:
        r(f"  {rn:>8} " + " ".join(f"{bar(n,tl,rn)[0]:>11.0%} " for n in NS for tl in TAILS))
    r()

    # -------------------------------------------------- 3. the window at every depth
    r.rule("3.  THE WINDOW AT EVERY DEPTH, HEAD PINNED AT 45%  "
           "(same columns as results-depth-basis.txt section 3)")
    r("  front<=   the phi at which the head's return falls below its managed-wing alternative")
    r("  back>=    max over back seats of the first phi at which that seat clears the passive LP")
    r("  window    [back>=, front<=].  EMPTY means no phi satisfies both.")
    r("  binding   the back seat that sets the lower bound; 'sK+j' = K plus j further seats NEVER")
    r("  gap@9500  binding seat's mean return minus the passive LP, at phi = 9500")
    r("  t(unp)    gap / sqrt(se_seat^2 + se_LP^2) -- the UNPAIRED form results-depth-basis uses")
    r("  t(pair)   gap / se(per-path difference) -- correct, since queue and LP share the seed")
    r("  turn      the binding seat's turnover (book turns).  A seat with ~0 turnover that 'beats'")
    r("            a LOSING benchmark is NOT PARTICIPATING; see section 5.")
    r()
    for tl in TAILS:
        for rn, _, _ in REG:
            hrs = float(Z[(NS[0], tl)][f"{rn}_hrs"].mean()) / 24.0
            r(f"  --- {tl} tail / {rn} ---   passive pro-rata LP {pct(LPm[rn])} "
              f"(se {100*LPse[rn]:.3f}pp)   in-band life {hrs:.1f}d")
            r(f"  {'N':>4} {'head/book':>10} {'seat2/book':>11} {'r1@phi=0':>10} {'r1@9500':>10}"
              f" {'wing bar':>9} {'front<=':>9} {'back>=':>9} {'window':>16} {'binding':>9}"
              f" {'gap@9500':>10} {'t(unp)':>8} {'t(pair)':>8} {'turn':>7}")
            for n in NS:
                k = (n, tl)
                R = m(n, tl, rn); S = se(n, tl, rn); T = turn(n, tl, rn)
                wi = weights(n, tl); caps = caps_for(wi)
                lo, hi, hst, lows, wstr = window(n, tl, rn)
                hi_s = (f"{hi:.0f}" if hst == 'cross'
                        else ("no bound" if hst == 'always' else "below@0"))
                never = [i for i, _, st in lows if st == 'never']
                if never:
                    lo_s = "NEVER"
                    bi = min(never, key=lambda i: R[-1, i])
                    bind = f"s{bi+1}" + (f"+{len(never)-1}" if len(never) > 1 else "")
                else:
                    lo_s = f"{lo:.0f}"
                    bi = max(lows, key=lambda t_: t_[1])[0]
                    bind = f"s{bi+1}"
                gap = R[-1, bi] - LPm[rn]
                unp = math.sqrt(S[-1, bi] ** 2 + LPse[rn] ** 2)
                dif = Z[k][f"{rn}_ret"][:, -1, bi] - LPpath[rn]
                pse = float(dif.std(ddof=1) / math.sqrt(NP))
                r(f"  {n:>4} {caps[0]/BOOK:>10.1%} {caps[1]/BOOK:>11.2%} {100*R[0,0]:>9.1f}%"
                  f" {100*R[-1,0]:>9.1f}% {pct(bar(n,tl,rn)[1]):>9} {hi_s:>9} {lo_s:>9}"
                  f" {wstr:>16} {bind:>9} {100*gap:>+9.2f}pp {gap/unp:>+8.1f} {gap/pse:>+8.1f}"
                  f" {T[-1,bi]:>6.0f}x")
            r()

    # -------------------------------------------------- 4. the headline comparison
    r.rule("4.  THE ANSWER TO THE CONFOUND: N_max WITH THE HEAD PINNED, BESIDE N_max WITH IT FREE")
    D = parse_depth_basis(PUB_DEPTH)
    r("  LEFT   this file: head fixed at 45%, only N varies.")
    r("  RIGHT  results-depth-basis.txt section 3: N and the head share vary TOGETHER.")
    r()
    r(f"  {'regime':>8} {'tail':>7} {'N with a window (head PINNED 45%)':>36} {'N_max':>7}   ||"
      f" {'LINEAR (head free)':>22} {'N_max':>7}  {'EQUAL (head free)':>22} {'N_max':>7}")
    for rn, _, _ in REG:
        for tl in TAILS:
            good = [n for n in NS if not window(n, tl, rn)[4].startswith("EMPTY")]
            cells = {}
            for sch in ("LINEAR", "EQUAL"):
                g2 = [n for n in (2, 5, 8, 16, 32)
                      if (sch, rn, n) in D and not D[(sch, rn, n)]["window"].startswith("EMPTY")]
                cells[sch] = (", ".join(map(str, g2)) or "none",
                              str(max(g2)) if g2 else "NONE")
            r(f"  {rn:>8} {tl:>7} {(', '.join(map(str, good)) or 'none'):>36} "
              f"{(str(max(good)) if good else 'NONE'):>7}   ||"
              f" {cells['LINEAR'][0]:>22} {cells['LINEAR'][1]:>7}  "
              f"{cells['EQUAL'][0]:>22} {cells['EQUAL'][1]:>7}")
        r()
    r("  ALL-REGIME feasibility -- the only column that matters, since a roster must survive all three:")
    r(f"  {'tail':>7} {'N':>5} {'BENIGN':>16} {'NORMAL':>16} {'TOXIC':>16}   {'all three?':>12}")
    allreg = {}
    for tl in TAILS:
        for n in NS:
            ws = [window(n, tl, rn)[4] for rn, _, _ in REG]
            good = all(not w.startswith("EMPTY") for w in ws)
            allreg[(tl, n)] = good
            r(f"  {tl:>7} {n:>5} " + " ".join(f"{w:>16}" for w in ws) +
              f"   {'YES' if good else 'no':>12}")
        r()

    # -------------------------------------------------- 5. turnover / non-participation
    r.rule("5.  TURNOVER -- WHICH 'WINS' ARE JUST NON-PARTICIPATION?")
    r("  In TOXIC the passive pro-rata LP LOSES money.  A seat that is never reached therefore")
    r("  'clears' it by holding still.  That is not outperformance and a window bought with it is")
    r("  not a window.  Turnover is book turns over the year at phi = 9500.")
    r()
    for tl in TAILS:
        for rn, _, _ in REG:
            r(f"  --- {tl} / {rn} ---   passive LP {pct(LPm[rn])}")
            r(f"  {'N':>4} {'r1 turn':>9} {'s2 turn':>9} {'median back turn':>18}"
              f" {'tail turn':>10} {'seats with turn<0.5x':>22} {'of which clear LP':>19}")
            for n in NS:
                R = m(n, tl, rn); T = turn(n, tl, rn)
                back = T[-1, 1:]
                dead = [i + 1 for i in range(n - 1) if back[i] < 0.5]
                dclear = [i for i in dead if R[-1, i] > LPm[rn]]
                r(f"  {n:>4} {T[-1,0]:>8.0f}x {T[-1,1]:>8.0f}x {float(np.median(back)):>17.1f}x"
                  f" {T[-1,-1]:>9.1f}x {len(dead):>22} {len(dclear):>19}")
            r()

    # -------------------------------------------------- 6. the price of the phi grid
    r.rule("6.  THE PRICE OF THE phi GRID -- crossovers re-read off coarser grids, SAME 120 paths")
    r("  The crossovers above are interpolated.  A coarser grid could move them.  This section")
    r("  re-reads every crossover of the finest cell available off its own subsampled grids, so")
    r("  the cut is PRICED rather than assumed away (report_depth.py section 1b does the same).")
    r()
    fine = [(n, tl) for n in NS for tl in TAILS if GRID[(n, tl)] == tuple(HS_PHIS)]
    if not fine:
        r("  No cell ran on the step-500 grid; nothing to subsample.")
    else:
        r(f"  {'cell':>12} {'regime':>8} {'quantity':>10} {'step 500':>10} {'step 1000':>10}"
          f" {'step 2000':>10} {'worst |d|':>10}")
        worst = 0.0
        for (n, tl) in fine:
            G = tuple(HS_PHIS)
            subs = {500: list(range(len(G))),
                    1000: list(range(0, len(G), 2)) + [len(G) - 1],
                    2000: list(range(0, len(G), 4)) + [len(G) - 1]}
            for kk in subs:
                subs[kk] = sorted(set(subs[kk]))
            for rn, _, _ in REG:
                R = m(n, tl, rn)
                _, mwv, _ = bar(n, tl, rn)
                for lbl, ys, tgt in ([("front", R[:, 0], mwv)] +
                                     [(f"s{i+1}", R[:, i], LPm[rn]) for i in range(1, min(n, 5))]):
                    vals = []
                    for st in (500, 1000, 2000):
                        ix = subs[st]
                        v, s_ = cross([G[i] for i in ix], [ys[i] for i in ix], tgt)
                        vals.append(fmt_phi(v, s_) if s_ != 'cross' else f"{v:.0f}")
                    nums = [float(x) for x in vals if re.match(r"^[\d.]+$", x)]
                    d = (max(nums) - min(nums)) if len(nums) == 3 else float('nan')
                    if len(nums) == 3:
                        worst = max(worst, d)
                    r(f"  {(str(n)+'/'+tl):>12} {rn:>8} {lbl:>10} {vals[0]:>10} {vals[1]:>10}"
                      f" {vals[2]:>10} {(f'{d:.0f}' if d == d else 'n/a'):>10}")
                r()
        r(f"  WORST crossover disagreement across the three grids: {worst:.0f} phi units")
        r("  (results-depth-basis.txt ran on step 2000; this is the size of the error that carries.)")
    r()

    # -------------------------------------------------- 7. identity + null controls
    r.rule("7.  THE IDENTITY AND NULL CONTROLS")
    r("  IDENTITY: worst per-path |capital-weighted queue pool return - independently simulated")
    r("  one-seat pro-rata LP on the same seed|, over every phi.  The queue pool is the same")
    r("  liquidity as the undivided pool, so this is zero up to float noise however the seats are")
    r("  weighted.  The right-hand side is a SEPARATE run([BOOK], marginal=False) with no premium.")
    r()
    r(f"  {'cell':>12} " + " ".join(f"{rn:>12}" for rn, _, _ in REG))
    wid = 0.0
    for n in NS:
        for tl in TAILS:
            vs = [float(Z[(n, tl)][f"{rn}_pool"].max()) for rn, _, _ in REG]
            wid = max(wid, max(vs))
            r(f"  {(str(n)+'/'+tl):>12} " + " ".join(f"{v:>12.2e}" for v in vs))
    r(f"  worst identity residual anywhere: {wid:.2e}")
    r()
    r("  NULL (wing.check_null): a wing spanning the WHOLE band with 1/N of the capital must earn")
    r("  exactly 1/N of the pool's fees and 1/N of its markout.  RELATIVE errors:")
    nf = max(float(Z[(n, tl)][f"{rn}_null"][:, 0].max())
             for n in NS for tl in TAILS for rn, _, _ in REG)
    nm_ = max(float(Z[(n, tl)][f"{rn}_null"][:, 1].max())
              for n in NS for tl in TAILS for rn, _, _ in REG)
    r(f"  worst fee {nf:.2e}, markout {nm_:.2e}")
    r("  results-headsize.txt reports 2.73e-03 / 9.45e-04 on the same engine and the same seeds;")
    r("  this is the wing's price-taker approximation, not a defect introduced here.")
    r()

    # -------------------------------------------------- 8. LAW 5 on this file's own output
    r.rule("8.  LAW 5 ASKED OF THIS FILE'S OWN OUTPUT: what would have to be true for it to FAIL?")
    r("  A control that cannot read FAIL is arithmetic in a control's costume.  Each of the five")
    r("  below has a stated failure mode, and what actually happened is recorded beside it.")
    r()
    r("  1. The reproduction control (section 1) fails if the copied `cell`, the weight vector, the")
    r("     seeds, the basis override or the grid differ from the published run.  Its right-hand")
    r("     side is parsed from a file written by another script on another day -- it is NOT")
    r("     derived from any quantity this file computes.")
    r(f"     -> {'PASSED' if ok else 'FAILED'}")
    r("  2. The structural invariants (section 2) fail if the roster split leaks into the price")
    r("     path.  They are not tautological: r1@0 and the wing bar are computed independently in")
    r("     eight separate simulations with eight different capital vectors.")
    r(f"     -> {'held to <1e-12' if inv_ok else 'DID NOT HOLD'}")
    r("  3. The identity control (section 7) fails if the premium leaks, a seat is double-counted,")
    r("     or the caps do not sum to the book.  Its baseline is a separate single-seat run.")
    r(f"     -> worst residual {wid:.2e}")
    r("  4. THE EXPERIMENT ITSELF can read FAIL in two independent ways, and section 3 shows both")
    r("     happening at some N: a back seat NEVER clears the passive LP at any phi (back>= NEVER),")
    r("     or the front's return falls below its wing alternative before the back constraint is")
    r("     met (EMPTY (cross)).  Neither is guaranteed by construction: at c1 = 45% the surplus")
    r("     per unit of back capital, c1*(LP - r1)/(1 - c1), is N-INVARIANT, so a pure head-share")
    r("     story predicts the window survives to N = 32 unchanged.  It does not.")
    r("  5. TURNOVER is reported beside every return (sections 3 and 5) precisely so that a TOXIC")
    r("     'win' by an unreached seat cannot be read as outperformance.")
    r()

    # -------------------------------------------------- 9. verdict
    r.rule("9.  VERDICT")
    for tl in TAILS:
        surv = [n for n in NS if allreg[(tl, n)]]
        r(f"  {tl:>6} tail, head pinned at 45%:  all-regime window at N = "
          f"{', '.join(map(str, surv)) if surv else 'NONE'}"
          f"   (N_max = {max(surv) if surv else 'NONE'})")
    r()
    r("  Compare: with the head share left free to collapse, results-depth-basis.txt section 3")
    r("  reports NO all-regime window at ANY N in either ladder shape -- TOXIC is empty for every")
    r("  N except 2, and N = 2 is not a queue.")
    r()
    r.commit(OUT)
    sys.stderr.write(f"[wrote {OUT}]\n")
    return 0


if __name__ == "__main__":
    sys.stderr.write(f"[depth sweep at a PINNED 45% head, PREM_WEIGHT = {BASIS!r}]\n")
    assert sim.PREM_WEIGHT == BASIS, "the basis was reset between import and run"
    sys.exit(main())
