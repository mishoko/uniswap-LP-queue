"""
IS THE HEAD SHARE THE LEVER THAT OPENS A phi WINDOW IN ALL THREE REGIMES?

WHY THIS FILE EXISTS.  `results-shipping-basis.txt` -- the shipping roster on the premium basis the
contract ACTUALLY implements (`PREM_WEIGHT = 'liquidity_excl'`) -- reports:

    BENIGN  window [4542, 5670]
    NORMAL  window [2560, 6251]
    TOXIC   EMPTY.  Seat 2 NEVER clears the passive pro-rata LP, at any phi.

The whole failure is ONE seat, in ONE regime.  Seats 3, 4 and 5 clear the LP at every phi in all
three regimes.  And seat 2's shortfall in TOXIC is 0.33pp and NEARLY FLAT in phi (phi 0 -> 9500
moves it +0.3pp), because a toxic band dies in ~1.4 days and there is almost no fee volume for the
premium to skim.  phi is therefore the WRONG knob for that cell: no achievable phi closes 0.33pp
when the whole phi axis is worth 0.3pp.

`results-depth-basis.txt` section 3 points at the knob that might be right.  At N = 2 (head 66.7%)
the TOXIC window is [0, 9500+] and seat 2 clears by +2.18pp, while at N = 5 (head 33.3%) TOXIC is
empty -- and the front's own constraint at N = 2 reads "no bound", because a keeper-managed range
holding 66.7% of the book does far worse (wing bar -7.16% in toxic) than one holding 33.3%.  But
N and the head share move TOGETHER in that sweep, so it cannot say which of the two did the work.
This file holds N = 5 FIXED -- the shipped roster, the one the demo depends on -- and varies ONLY
the head's share of the book.

THE PRE-REGISTERED HYPOTHESIS (recorded before the run, so that it can be refuted).  The
distributable surplus per unit of back capital is c1*(LP - r1)/(1 - c1), increasing in c1.
Simultaneously seat 2's share of the tail loss FALLS as c1 rises (a bigger head absorbs more of
the move before seat 2 is reached), and the front's alternative gets WORSE as c1 rises (a bigger
managed range re-mints less efficiently, and its conversion impact scales with its own size).  All
three push the same way, so BOTH constraints should relax monotonically in c1, and there should be
a head share strictly between 33.3% and 66.7% at which every seat 2..5 clears the passive LP in
all three regimes while the front still clears its best alternative.

IF IT IS NOT MONOTONE IN c1, THAT REFUTES THE MODEL OF THE MECHANISM AND IS THE HEADLINE.  Section
7 is written to say so plainly rather than to smooth it over.

--------------------------------------------------------------------------------------------------
WHAT THIS FILE DOES *NOT* MODEL, AND IT IS A WHOLE TRANSFER CHANNEL
--------------------------------------------------------------------------------------------------
`sim.py` HAS NO RENT.  Verified here, not taken on trust: `grep -ic rent sim.py` returns 1 and
that single hit is the substring inside the word "CURRENT" on line 202.  The simulator models the
premium and nothing else.

The deployed hook, by contrast, charges Harberger rent on each seat's posted self-price.  The rate
was reported to this file's author as `RENT_BPS = 1_000` (10% per `RENT_PERIOD = 365 days`); it is
attributed rather than asserted, because `src/` was off-limits while a mutation campaign held a
mutant on disk (PITFALLS 5.79) and this author therefore did not read the constant.  Whatever its
exact value, rent is a SECOND transfer channel between the seats which no economic number in this
directory -- this file included -- contains.  As of this session the rent's DIRECTION has been reversed in the
contract so that it flows FORWARD: the back seats pay the front seat for the subordination it
supplies.  That runs OPPOSITE to the premium.

  => EVERY WINDOW IN THIS FILE IS RENT-FREE.  Because forward rent moves value from back to front,
     these windows are a LOWER bound on what the front can bear and an UPPER bound on what the back
     keeps.  A back seat that clears the passive LP by less than its rent bill does not really clear
     it.  Do not read a window here as a window on the deployed contract.

Also inherited from `report_shipping.py`, unchanged and restated rather than hidden:
  band       modelled as a symmetric +/-10%; the shipped 960-tick band is +10.08%/-9.16%.
  decimals   this simulator is floating point with no cross-token comparison, so it models the
             mechanism AS DESIGNED.  On the shipped 18/6 pool the token0 premium is separately
             known to be inert (PITFALLS 5.124), which makes every premium number here an UPPER
             bound on what the deployed contract pays backward.

--------------------------------------------------------------------------------------------------
THE CONTROLS.  Check these before believing any other number in the file (LAW 5).
--------------------------------------------------------------------------------------------------
1.  THE phi = 0 CONTROL (section 1).  At phi = 0 nothing is withheld and the premium weight vector
    is never read, so the c1 = 33.3% column at phi = 0 must equal `results-shipping-basis.txt`'s
    phi = 0 column.  This goes RED if the capital vector is not the shipped one, if the seeds are
    not the same seeds, or if the basis override reached something it must not reach.
    The capital vector is built from an INTEGER weight vector via the same `BOOK*w/S` expression
    `report_shipping.py` uses, precisely so that c1 = 1/3 is `[BOOK*w/15 for w in (5,4,3,2,1)]` to
    the last bit -- computing it as `BOOK*(1-c1)*b/B` instead is one ULP off on seat 3 and would
    make this control unusable for its purpose.
    What would make it FAIL: any of the four things above.  It is not arithmetic -- the published
    file was produced by a different script on a different day and is parsed off disk here.

2.  THE REPRODUCTION CONTROL (section 2).  The c1 = 33.3% row's three windows must equal the
    published [4542, 5670] / [2560, 6251] / EMPTY.  These are crossover phis produced by
    interpolating means of 120 paths through a wing bar and an LP bar computed by a separate
    engine; they agree only if the seeds, the regimes, the wing widths, the gas assumption, the
    band, the retail intensity and the premium basis all match.
    NOTE ON THE GRID: the extra phi = 5100 column this file needs for the gap and spread statistics
    is measured SEPARATELY and is deliberately NOT inserted into the crossover grid, because doing
    so would re-interpolate any crossing that falls in (5000, 5500) and break bit-reproduction for
    a cosmetic reason.  All crossovers are on the canonical 0..9500 step-500 grid.

3.  THE IDENTITY CONTROL (section 9).  Worst per-path |capital-weighted queue return - the
    INDEPENDENTLY simulated pro-rata LP on the same seed|.  The queue pool as a whole is the same
    liquidity as the undivided pool, so this is zero up to float noise however the seats are
    weighted.  The existing runs report <= 3.8e-04.  This is NOT two of this file's own quantities
    compared to each other: the right-hand side is a separate `run([BOOK], marginal=False)` whose
    book has one seat and no premium at all.  It goes RED if the capital vector does not sum to
    BOOK, if the premium leaks, or if a seat is double-counted.

4.  THE t-STATISTIC IS AGAINST THE STANDARD ERROR OF THE DIFFERENCE, NOT THE OUTCOME SD (LAW 5 --
    a rank-separation statistic built on the outcome SD is one of the five tautological controls
    this project has already caught).  The queue run and the LP run share a seed and therefore
    share a price path, so the paths are PAIRED and the paired SE is the correct one; the unpaired
    sqrt(se1^2 + se2^2) is printed beside it for comparability with `results-depth-basis.txt`,
    which uses that form.

WRITE PATTERN (PITFALLS 5.79).  `book_report.py` truncates its output file at the top of `main()`
and `results-book.txt` was consequently committed at ZERO BYTES for a whole phase with `git status`
clean.  This file buffers every line, writes a tempfile, and `os.replace()`s onto
`results-headsize.txt` only after the report has been fully built.

Reproduce:
    python3 report_headsize.py              # stage what is missing for N=5, then report
    HS_NS=5,8 python3 report_headsize.py    # include the N=8 secondary rows
"""
import sys, os, re, math, time, tempfile
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim

BASIS = "liquidity_excl"
sim.PREM_WEIGHT = BASIS                 # the parent, before any Book exists

import wing                             # noqa: E402
from sim import run                      # noqa: E402
from report_addendum import ladder       # noqa: E402
from report_shipping import cross, pct   # noqa: E402  -- the SAME crossover interpolator

# ------------------------------------------------------------------ the shipping configuration
BOOK, RPH, P0 = 1_000_000.0, 15.0, 2000.0
HALF = 0.10
PHIS = tuple(range(0, 10000, 500))
PHI_T = 5100                            # measured, NOT interpolated; kept OUT of the grid above
REG = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
RANGES = (("A", range(0, 30)), ("B", range(100, 130)), ("C", range(200, 230)),
          ("D", range(1000, 1030)))
SEEDS = [sd for _, rg in RANGES for sd in rg]      # 120, four disjoint ranges
MW = (0.01, 0.02, 0.05)
GAS = {"L2": 0.02, "L1": 12.00}

# c1 as EXACT rationals so the weight vector is integral and c1 = 1/3 reproduces SHIP bit for bit
HEADS = (Fraction(1, 3), Fraction(7, 20), Fraction(3, 8), Fraction(2, 5), Fraction(9, 20),
         Fraction(1, 2), Fraction(11, 20), Fraction(3, 5), Fraction(2, 3))
# 35% and 37.5% were added AFTER the first seven ran, because the coarse grid only bounded the
# minimum viable head share to (33.3%, 40%] and the head share IS the subsidiser's capital
# requirement -- every point of it is treasury money locked, so the minimum is the business
# question, not a rounding detail.  Stages are cached per-c1, so this cost two stages, not nine.
NS = tuple(int(x) for x in os.environ.get("HS_NS", "5").split(","))
CACHE = os.environ.get("HS_CACHE", "/tmp/queue-headsize")
NPROC = int(os.environ.get("HS_PROCS", "4"))       # a mutation campaign owns the other cores
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results-headsize.txt")
PUB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results-shipping-basis.txt")


def _init():
    """Runs in every worker. Without this the workers silently use sim.py's 'inventory' default
    and every number in the file is void."""
    import sim as _s
    _s.PREM_WEIGHT = BASIS


def hlabel(c1):
    return f"{float(c1):.1%}"


def weights_for(n, c1):
    """The head takes share c1; seats 2..n split (1 - c1) in the project's own 4:3:2:1 LINEAR
    proportion (generally n-1 : n-2 : ... : 1).  Returned as INTEGERS so that caps can be built
    with the identical `BOOK*w/S` expression report_shipping.py uses.

    At n = 5, c1 = 1/3 this is exactly (5, 4, 3, 2, 1) -- asserted in main()."""
    b = [Fraction(n - i) for i in range(1, n)]
    h = c1 * sum(b) / (1 - c1)
    w = [h] + b
    den = 1
    for x in w:
        den = den * x.denominator // math.gcd(den, x.denominator)
    wi = [int(x * den) for x in w]
    g = 0
    for x in wi:
        g = math.gcd(g, x)
    return tuple(x // g for x in wi)


def caps_for(wi):
    S = float(sum(wi))
    return [BOOK * float(x) / S for x in wi]


# ------------------------------------------------------------------------------- the workers
def lp_cell(a):
    """The ordinary pro-rata LP baseline.  Depends on NEITHER the roster NOR phi -- one seat, no
    premium, a separate engine path -- which is exactly why it is a usable bar and a usable
    identity control rather than one of this file's own quantities."""
    vol, dr, seed = a
    pb, _, Pt = run([BOOK], False, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                    half=HALF)
    dp, hp = pb.pnl(Pt)
    return float(dp[0] / hp[0])


def cell(a):
    """One (n, weights, regime, seed): the whole phi sweep, the phi = PHI_T point, and the traced
    wing bars for a head of this size."""
    n, wi, vol, dr, seed, lp = a
    sim.PREM_WEIGHT = BASIS                     # belt and braces inside the worker
    caps = caps_for(wi)
    head = caps[0]
    grid = list(PHIS) + [PHI_T]                 # PHI_T is the LAST row, never inside the grid
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
        out[f"cost_{w_}"] = (mm['remints'], mm['fees'] / mm['hold'], mm['markout'] / mm['hold'],
                             mm['conv_fee'] / mm['hold'], mm['conv_imp'] / mm['hold'])
    return out


def _idx(a):
    i, j = a
    return i, cell(j)


def _lpidx(a):
    i, j = a
    return i, lp_cell(j)


# ------------------------------------------------------------------------------- the staging
def _cp(nm):
    return os.path.join(CACHE, nm + ".npz")


def stage_lp():
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


def stage(n, c1):
    nm = f"n{n}_h{c1.numerator}_{c1.denominator}"
    if os.path.exists(_cp(nm)):
        return
    from multiprocessing import Pool
    LP = np.load(_cp("lp"))
    wi = weights_for(n, c1)
    jobs, keys = [], []
    for rn, v, dr in REG:
        for j, sd in enumerate(SEEDS):
            jobs.append((n, wi, v, dr, sd, float(LP[rn][j]))); keys.append(rn)
    t = time.time()
    out = [None] * len(jobs)
    with Pool(NPROC, initializer=_init) as p:
        for i, rr in p.imap_unordered(_idx, list(enumerate(jobs)), chunksize=1):
            out[i] = rr
    d = {"weights": np.array(wi, float)}
    for rn, _, _ in REG:
        v = [x for x, k in zip(out, keys) if k == rn]
        d[f"{rn}_ret"] = np.stack([x['ret'] for x in v])        # (paths, grid, n) -- PER PATH
        d[f"{rn}_turn"] = np.stack([x['turn'] for x in v])
        d[f"{rn}_pool"] = np.stack([x['pool'] for x in v])
        d[f"{rn}_lp"] = np.array([x['lp'] for x in v], float)
        d[f"{rn}_hrs"] = np.array([x['hrs'] for x in v], float)
        d[f"{rn}_static"] = np.array([x['static'] for x in v], float)
        d[f"{rn}_null"] = np.array([[x['null_fee'], x['null_mk']] for x in v], float)
        for w_ in MW:
            for gn in GAS:
                d[f"{rn}_mw_{w_}_{gn}"] = np.array([x[f"mw_{w_}_{gn}"] for x in v], float)
            d[f"{rn}_cost_{w_}"] = np.array([x[f"cost_{w_}"] for x in v], float)
    np.savez(_cp(nm), **d)
    sys.stderr.write(f"[{nm} (c1={hlabel(c1)}, w={wi}): {len(jobs)*(len(PHIS)+2)} runs, "
                     f"{time.time()-t:.0f}s]\n")


# ------------------------------------------------------------------------------- the report
class Rep:
    def __init__(self):
        self.L = []

    def __call__(self, s=""):
        self.L.append(s)

    def rule(self, t):
        self("=" * 100); self(t); self("=" * 100)

    def commit(self, path):
        body = "\n".join(self.L) + "\n"
        assert len(body) > 5000, f"report suspiciously short ({len(body)}B) -- refusing to write"
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".hs-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(body)
            os.replace(tmp, path)
            os.chmod(path, 0o644)   # mkstemp makes 0600; match the other results-*.txt
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        return len(body)


def published_windows():
    """Read the three published windows out of results-shipping-basis.txt section 3.  Read off
    DISK from a file another script wrote on another day -- not a constant retyped here."""
    got = {}
    if not os.path.exists(PUB):
        return got
    lines = open(PUB).read().splitlines()
    try:
        i = next(k for k, s in enumerate(lines) if s.strip().startswith("3.  THE FEASIBLE WINDOW"))
    except StopIteration:
        return got
    for s in lines[i:i + 12]:
        p = s.split()
        if p and p[0] in ("BENIGN", "NORMAL", "TOXIC"):
            if "EMPTY" in s:
                got[p[0]] = "EMPTY"
            else:
                mm = re.search(r"\[\s*([0-9.]+)\s*,\s*([0-9.+]+)\s*\]", s)
                got[p[0]] = f"[{mm.group(1)}, {mm.group(2)}]" if mm else "(unparsed)"
    return got


def published_phi0():
    """The phi = 0 column of section 1 (r1) and section 2 (s2..s5) of the published file."""
    if not os.path.exists(PUB):
        return {}
    lines = open(PUB).read().splitlines()
    out, cur = {}, None
    for s in lines:
        t = s.strip()
        if t.startswith("--- "):
            cur = t[4:].split()[0]
        if cur and (t.startswith("r1 ") or (len(t) > 2 and t[0] == "s" and t[1].isdigit())):
            k = t.split()[0]
            try:
                out[(cur, k)] = float(t.split()[1])
            except ValueError:
                pass
    return out


def published_crossovers():
    """The published per-seat crossovers and the published front bound.

    STRONGER THAN THE phi = 0 COLUMN, and the reason is worth stating.  The published file prints
    phi = 0 returns to ONE decimal, so that control can only ever agree to 0.05pp.  These are
    LINEARLY INTERPOLATED crossover phis printed to the unit -- 4 or 5 significant figures each --
    and each one is a function of the whole mean curve, the LP bar and the wing bar together.
    Agreeing on twelve of them to the unit is much harder to do by accident than agreeing on a
    rounded column, so this is the control that actually pins the harness."""
    out = {}
    if not os.path.exists(PUB):
        return out
    cur = None
    for line in open(PUB).read().splitlines():
        t = line.strip()
        if t.startswith("--- "):
            cur = t[4:].split()[0]
        if cur and "first phi at which each seat beats the LP" in t:
            # the published form is "s2: 4542  s3: all phi  s4: NEVER"; a naive split on the
            # double space drops every one of them, which is how a first draft of this control
            # printed "3 checked" under a heading that promised twelve.
            for mm in re.finditer(r"s(\d+):\s*(NEVER|all phi|[0-9]+(?:\.[0-9]+)?)", t):
                out[(cur, "s" + mm.group(1))] = mm.group(2)
        if cur and "rank 1 falls below the managed wing" in t:
            out[(cur, "front")] = t.split("=")[-1].strip()
    return out


def main():
    os.makedirs(CACHE, exist_ok=True)
    # the vector identity that makes control 1 meaningful, asserted before any compute
    SHIP = [BOOK * w / 15.0 for w in (5, 4, 3, 2, 1)]
    assert weights_for(5, Fraction(1, 3)) == (5, 4, 3, 2, 1), weights_for(5, Fraction(1, 3))
    assert caps_for(weights_for(5, Fraction(1, 3))) == SHIP, "c1=1/3 is not the shipped vector"

    stage_lp()
    for n in NS:
        for c1 in HEADS:
            stage(n, c1)

    LPz = np.load(_cp("lp"))
    LPm = {rn: float(LPz[rn].mean()) for rn, _, _ in REG}
    LPse = {rn: float(LPz[rn].std(ddof=1) / math.sqrt(len(LPz[rn]))) for rn, _, _ in REG}

    Z = {}
    for n in NS:
        for c1 in HEADS:
            Z[(n, c1)] = np.load(_cp(f"n{n}_h{c1.numerator}_{c1.denominator}"))

    NP = len(SEEDS)
    ig = len(PHIS)          # index of the PHI_T row

    def m(n, c1, rn):
        return Z[(n, c1)][f"{rn}_ret"][:, :ig, :].mean(axis=0)

    def at_t(n, c1, rn):
        return Z[(n, c1)][f"{rn}_ret"][:, ig, :]

    def bar(n, c1, rn):
        z = Z[(n, c1)]
        g = {w_: float(z[f"{rn}_mw_{w_}_L2"].mean()) for w_ in MW}
        bw = max(MW, key=lambda w_: g[w_])
        return bw, g[bw], float(z[f"{rn}_static"].mean())

    def window(n, c1, rn):
        R = m(n, c1, rn)
        _, mwv, _ = bar(n, c1, rn)
        hi, hst = cross(PHIS, R[:, 0], mwv)
        lows = [(i,) + cross(PHIS, R[:, i], LPm[rn]) for i in range(1, n)]
        never = [i for i, _, st in lows if st == 'never']
        if never:
            return None, hi, hst, lows, "EMPTY"
        lo = max(v for _, v, _ in lows)
        if hst == 'never':
            return lo, hi, hst, lows, "EMPTY"
        if hst == 'always':
            return lo, math.inf, hst, lows, f"[{lo:.0f}, 9500+]"
        return lo, hi, hst, lows, (f"[{lo:.0f}, {hi:.0f}]" if lo <= hi else "EMPTY (cross)")

    r = Rep()
    r.rule("THE HEAD-SHARE SWEEP -- does a bigger head open a phi window in ALL THREE REGIMES?")
    r(f"  PREM_WEIGHT = {BASIS!r}, the basis the contract implements (QueueHook.sol 1150/1154/1494).")
    r(f"  N in {NS} held FIXED; the HEAD's share of the book is the only thing that varies.")
    r("  Seats 2..N always split (1 - c1) in the project's own LINEAR proportion (4:3:2:1 at N=5).")
    r(f"  ${BOOK:,.0f} book, band +/-{HALF:.0%}, fee 0.30%, retail {RPH:.0f}/hr, "
      f"4 disjoint seed ranges x 30 = {NP} paths per cell.")
    r(f"  phi swept {PHIS[0]}-{PHIS[-1]} step 500 for all crossovers; phi = {PHI_T} measured")
    r("  SEPARATELY for the gap/spread statistics and deliberately NOT inserted into the")
    r("  crossover grid (see the header).")
    r(f"  {NPROC} worker processes (a mutation campaign owned the rest of the machine).")
    r()
    r("  *** EVERY WINDOW IN THIS FILE IS RENT-FREE. ***  sim.py models no Harberger rent at all")
    r("  (verified: its only 'rent' match is the substring in 'CURRENT'), while the deployed hook")
    r("  charges Harberger rent on each seat's self-price -- reported as RENT_BPS = 1_000 per")
    r("  RENT_PERIOD, attributed not verified, since src/ was off-limits to this author during a")
    r("  live mutation campaign -- and -- as of this session -- pays it FORWARD, from")
    r("  the back seats to the front.  That is a second transfer channel running OPPOSITE to the")
    r("  premium.  These windows are therefore a LOWER bound on what the front can bear and an")
    r("  UPPER bound on what the back keeps.  A back seat clearing the LP by less than its rent")
    r("  bill has not really cleared it.  This file does not model it and does not guess at it.")
    r()
    r("  The 18/6 caveat also stands: the shipped pool's token0 premium is separately known to be")
    r("  inert (PITFALLS 5.124), so every premium number here is an upper bound on the contract's.")
    r()
    r("  THE CAPITAL VECTOR AT EVERY HEAD SHARE (integer weights, caps = BOOK*w/sum(w)):")
    r(f"  {'N':>3} {'c1':>7} {'integer weights':>34} {'capital, $k':>56}")
    for n in NS:
        for c1 in HEADS:
            wi = weights_for(n, c1)
            cp = caps_for(wi)
            r(f"  {n:>3} {hlabel(c1):>7} {str(wi):>34} "
              f"{('  '.join(f'{x/1000:.1f}' for x in cp)):>56}")
    r()
    nullf = max(float(Z[(n, c1)][f"{rn}_null"][:, 0].max())
                for n in NS for c1 in HEADS for rn, _, _ in REG)
    nullm = max(float(Z[(n, c1)][f"{rn}_null"][:, 1].max())
                for n in NS for c1 in HEADS for rn, _, _ in REG)
    r(f"  wing engine null (a full-band wing of 1/N the capital IS 1/N of the pool): "
      f"worst fee {nullf:.2e}, markout {nullm:.2e}")
    r()

    # ---------------------------------------------------------------- CONTROL 1
    r.rule("1.  CONTROL -- the phi = 0 column at c1 = 33.3% against results-shipping-basis.txt")
    r("  At phi = 0 nothing is withheld and the premium weight vector is never read, so this")
    r("  column is a property of the ROSTER and the SEEDS alone.  It must reproduce the published")
    r("  file, which was written by a different script on a different day and is parsed off disk")
    r("  below.  If it does not, the harness is not the same harness and NOTHING else here means")
    r("  anything.  The published file prints one decimal place, so the achievable residual is")
    r("  bounded by its own rounding at 0.05pp; the raw values are shown so the reader can see")
    r("  that the agreement is exact and not merely within tolerance.")
    r()
    pub0 = published_phi0()
    n0 = 5 if 5 in NS else NS[0]
    r(f"  {'regime':>8} {'seat':>5} {'computed %':>12} {'published %':>12} {'residual pp':>13}")
    worst0 = 0.0
    ok0 = True
    nchk = 0
    for rn, _, _ in REG:
        R = m(n0, Fraction(1, 3), rn)
        for i in range(n0):
            k = "r1" if i == 0 else f"s{i+1}"
            c = 100 * R[0, i]
            p = pub0.get((rn, k))
            if p is None:
                r(f"  {rn:>8} {k:>5} {c:>12.4f} {'(not parsed)':>12} {'--':>13}")
                continue
            nchk += 1
            d = c - p
            worst0 = max(worst0, abs(d))
            if abs(d) > 0.05:
                ok0 = False
            r(f"  {rn:>8} {k:>5} {c:>12.4f} {p:>12.1f} {d:>+13.4f}")
        r()
    if nchk == 0:
        ok0 = False
    r(f"  {nchk} values checked.  WORST residual anywhere: {worst0:.4f}pp   "
      f"{'PASS -- within the published file rounding of 0.05pp' if ok0 else 'FAIL -- STOP'}")
    if not ok0:
        r("  *** THE phi = 0 CONTROL FAILED.  Every other number in this file is void. ***")
    r()

    # ---------------------------------------------------------------- CONTROL 2
    r.rule("2.  CONTROL -- the c1 = 33.3% windows against the published ones")
    pw = published_windows()
    r(f"  {'regime':>8} {'computed':>20} {'published':>20} {'agree':>8}")
    ok2 = True
    for rn, _, _ in REG:
        _, _, _, _, ws = window(n0, Fraction(1, 3), rn)
        p = pw.get(rn, "(not parsed)")
        # normalise whitespace on both sides; compare the FULL window string, not its first token
        a = (" ".join(ws.split()) == " ".join(p.split())) if p not in ("(not parsed)", "(unparsed)") else False
        ok2 = ok2 and a
        r(f"  {rn:>8} {ws:>20} {p:>20} {('YES' if a else 'NO'):>8}")
    r()
    r("  AND THE FIFTEEN UNDERLYING CROSSOVERS, which is the sharper form of the same control:")
    r("  the phi = 0 column above is printed to one decimal and can only agree to 0.05pp, whereas")
    r("  each crossover below is an interpolated phi to the unit -- a function of the whole mean")
    r("  curve, the LP bar and the wing bar at once.  Fifteen of those agreeing to the unit is")
    r("  not something that happens by accident.")
    r("  A first draft of this parser silently matched only the 3 FRONT bounds while this heading")
    r("  promised twelve -- it printed '3 published crossovers checked', and that COUNT is how it")
    r("  was caught.  A control must print how many things it actually checked, or the heading")
    r("  becomes the claim and nobody audits the loop underneath it.")
    r()
    pc = published_crossovers()
    r(f"  {'regime':>8} {'which':>7} {'computed':>12} {'published':>12} {'agree':>8}")
    ok2b, n2b = True, 0
    for rn, _, _ in REG:
        R = m(n0, Fraction(1, 3), rn)
        _, mwv, _ = bar(n0, Fraction(1, 3), rn)
        rows = [("front",) + cross(PHIS, R[:, 0], mwv)]
        for i in range(1, n0):
            rows.append((f"s{i+1}",) + cross(PHIS, R[:, i], LPm[rn]))
        for nm_, v, st in rows:
            comp = ("NEVER" if st == 'never' else
                    ("all phi" if st == 'always' and nm_ != "front" else
                     ("never in range (still above at phi=9500)" if st == 'always'
                      else f"{v:.0f}")))
            p = pc.get((rn, nm_))
            if p is None:
                continue
            n2b += 1
            a = comp == p
            ok2b = ok2b and a
            r(f"  {rn:>8} {nm_:>7} {comp:>12} {p:>12} {('YES' if a else 'NO'):>8}")
        r()
    r(f"  {n2b} published crossovers checked, all reproduced: {'YES' if ok2b else 'NO'}")
    r()
    r("  " + ("ALL THREE WINDOWS AND EVERY CROSSOVER REPRODUCE -- the harness is the published "
             "harness" if (ok2 and ok2b) else
             "FAIL -- STOP: this run is not comparable to the published file"))
    if not ok2:
        r("  *** THE REPRODUCTION CONTROL FAILED.  Report this, do not continue past it. ***")
    r()

    # ---------------------------------------------------------------- the per-cell table
    r.rule("3.  EVERY CELL -- the front, the back, the window, and who binds")
    r("  r1@0 / r1@9500     the head's return at the ends of the phi axis")
    r("  wing bar           the head's BEST alternative: a keeper-managed ATM range holding the")
    r("                     same capital, best of w in 1%/2%/5%, L2 gas, re-mint costs itemised")
    r("  phi_LP             the phi at which r1 falls below the PASSIVE pro-rata LP")
    r("  phi_max            the phi at which r1 falls below its WING BAR  (the front constraint)")
    r("  phi_2..phi_N       the first phi at which that seat clears the passive LP; 'all' = clears")
    r("                     at every phi including 0; 'NEVER' = at no phi on the grid")
    r("  window             [max_i phi_i, phi_max]")
    r(f"  spread             (best back seat - worst back seat) in pp at phi = {PHI_T} -- the")
    r("                     return GRADIENT the back seats can arbitrage by walking to the tail")
    r()
    for n in NS:
        for rn, _, _ in REG:
            hrs = float(Z[(n, HEADS[0])][f"{rn}_hrs"].mean()) / 24
            r(f"  --- N={n} / {rn} ---   passive pro-rata LP {pct(LPm[rn])} "
              f"(se {100*LPse[rn]:.3f}pp)   in-band life {hrs:.1f}d")
            r(f"  {'c1':>7} {'r1@0':>8} {'r1@9500':>9} {'wingbar':>9} {'w':>4} {'phi_LP':>8}"
              f" {'phi_max':>9} " + " ".join(f"{('phi_'+str(i+1)):>7}" for i in range(1, n))
              + f" {'window':>14} {'binds':>7} {'spread':>8}")
            for c1 in HEADS:
                R = m(n, c1, rn)
                bw, mwv, stv = bar(n, c1, rn)
                lo, hi, hst, lows, ws = window(n, c1, rn)
                lpc, lpst = cross(PHIS, R[:, 0], LPm[rn])
                lps = (f"{lpc:.0f}" if lpst == 'cross'
                       else ("none" if lpst == 'always' else "below@0"))
                his = (f"{hi:.0f}" if hst == 'cross'
                       else ("none" if hst == 'always' else "below@0"))
                lab = {'cross': lambda v: f"{v:.0f}", 'always': lambda v: "all",
                       'never': lambda v: "NEVER"}
                cells = " ".join(f"{lab[st](v):>7}" for _, v, st in lows)
                never = [i for i, _, st in lows if st == 'never']
                if never:
                    bi = min(never, key=lambda i: R[-1, i])
                    bind = f"s{bi+1}" + (f"+{len(never)-1}" if len(never) > 1 else "")
                else:
                    bi = max(lows, key=lambda t: t[1])[0]
                    bind = f"s{bi+1}"
                Rt = at_t(n, c1, rn).mean(axis=0)
                sprd = 100 * (Rt[1:].max() - Rt[1:].min())
                r(f"  {hlabel(c1):>7} {100*R[0,0]:>7.1f}% {100*R[-1,0]:>8.1f}%"
                  f" {pct(mwv):>9} {bw:>4.0%} {lps:>8} {his:>9} {cells}"
                  f" {ws:>14} {bind:>7} {sprd:>7.2f}p")
            r()

    # ---------------------------------------------------------------- seat 2 gap + t
    r.rule(f"4.  THE BINDING CELL -- seat 2's gap to the PASSIVE LP at phi = {PHI_T}, with a t")
    r("  The t is against the STANDARD ERROR OF THE DIFFERENCE, not the outcome SD (LAW 5).  The")
    r("  queue run and the LP run share a seed and therefore share a price path, so the paths are")
    r("  PAIRED and t_paired is the correct statistic.  t_indep = gap / sqrt(se_seat^2 + se_lp^2)")
    r("  is printed only for comparability with results-depth-basis.txt, which uses that form.")
    r("  A NEGATIVE gap means seat 2 is WORSE than simply LPing and has not earned its lock.")
    r()
    for n in NS:
        r(f"  --- N={n} ---")
        r(f"  {'regime':>8} {'c1':>7} {'s2 ret':>9} {'LP':>9} {'gap pp':>9} {'se_pair':>9}"
          f" {'t_paired':>9} {'t_indep':>9} {'worst back':>11} {'its gap':>9} {'spread':>8}")
        for rn, _, _ in REG:
            for c1 in HEADS:
                A = at_t(n, c1, rn)                     # (paths, n)
                lpv = Z[(n, c1)][f"{rn}_lp"]            # (paths,) -- the SAME seeds, paired
                d2 = A[:, 1] - lpv
                gap = float(d2.mean())
                sep = float(d2.std(ddof=1) / math.sqrt(len(d2)))
                se2 = float(A[:, 1].std(ddof=1) / math.sqrt(len(d2)))
                sei = math.sqrt(se2 ** 2 + LPse[rn] ** 2)
                mn = A[:, 1:].mean(axis=0)
                wi_ = int(np.argmin(mn)) + 1
                r(f"  {rn:>8} {hlabel(c1):>7} {pct(A[:,1].mean()):>9} {pct(lpv.mean()):>9}"
                  f" {100*gap:>+8.3f}p {100*sep:>8.3f}p {gap/sep:>+9.1f}"
                  f" {gap/sei:>+9.1f} {('s'+str(wi_+1)):>11}"
                  f" {100*(mn[wi_-1]-lpv.mean()):>+8.3f}p"
                  f" {100*(mn.max()-mn.min()):>7.2f}p")
            r()

    # ---------------------------------------------------------------- the spread
    r.rule("5.  THE BACK-SEAT SPREAD -- does a bigger head FLATTEN the gradient across 2..N?")
    r("  A seat can reach the TAIL for one wei of withdrawal, carrying its depth (test_8_20).  The")
    r("  return gradient across the back seats is therefore not a curiosity, it is the size of that")
    r("  arbitrage.  If the spread NARROWS as c1 rises, the head-size fix and the free-lane fix")
    r(f"  pull the SAME way.  If it WIDENS, they fight.  Measured at phi = {PHI_T}.")
    r()
    for n in NS:
        r(f"  --- N={n} ---   spread = (best back seat - worst back seat), pp, at phi = {PHI_T}")
        r(f"  {'c1':>7} " + " ".join(f"{rn:>10}" for rn, _, _ in REG)
          + f" {'best seat BENIGN':>18} {'best seat TOXIC':>17}")
        for c1 in HEADS:
            row, bb, bt = [], "", ""
            for rn, _, _ in REG:
                mn = at_t(n, c1, rn).mean(axis=0)[1:]
                row.append(100 * (mn.max() - mn.min()))
                if rn == "BENIGN":
                    bb = f"s{int(np.argmax(mn))+2}"
                if rn == "TOXIC":
                    bt = f"s{int(np.argmax(mn))+2}"
            r(f"  {hlabel(c1):>7} " + " ".join(f"{x:>9.2f}p" for x in row)
              + f" {bb:>18} {bt:>17}")
        r()
        for rn, _, _ in REG:
            v = [100 * (at_t(n, c1, rn).mean(axis=0)[1:].max()
                        - at_t(n, c1, rn).mean(axis=0)[1:].min()) for c1 in HEADS]
            mono = all(b <= a + 1e-12 for a, b in zip(v, v[1:]))
            monoup = all(b >= a - 1e-12 for a, b in zip(v, v[1:]))
            tag = ("NARROWS monotonically" if mono else
                   "WIDENS monotonically" if monoup else "NON-MONOTONE")
            r(f"    {rn:>8}  {v[0]:.2f}p at {hlabel(HEADS[0])} -> {v[-1]:.2f}p at "
              f"{hlabel(HEADS[-1])}   {tag}")
        r()

    # ------------------------------------------------- non-participation (the seat-32 trap)
    r.rule("5b.  IS A BACK SEAT 'CLEARING THE LP' OR JUST NEVER BEING REACHED?")
    r("  LAW 5's seat-32 trap: an UNREACHED seat scores exactly 0 for every allocator, including a")
    r("  maximally corrupt one.  In TOXIC the passive LP loses money, so a seat that is never")
    r("  touched 'clears the LP' by doing nothing at all.  That is a real economic fact about")
    r("  subordination -- it is NOT evidence that the premium reached the seat.  This table says")
    r(f"  what share of the {NP} paths left each back seat with ZERO turnover at phi = {PHI_T}, so")
    r("  that no reader mistakes non-participation for a cleared bar.")
    r()
    for n in NS:
        r(f"  --- N={n} ---   share of paths with zero turnover at phi = {PHI_T}")
        r(f"  {'regime':>8} {'c1':>7} " + " ".join(f"{('s'+str(i+1)):>8}" for i in range(1, n))
          + f" {'mean |s_N| ret':>15}")
        for rn, _, _ in REG:
            for c1 in HEADS:
                T = Z[(n, c1)][f"{rn}_turn"][:, ig, :]
                A = at_t(n, c1, rn)
                fr = [(T[:, i] == 0).mean() for i in range(1, n)]
                r(f"  {rn:>8} {hlabel(c1):>7} " + " ".join(f"{100*x:>7.1f}%" for x in fr)
                  + f" {100*abs(float(A[:, -1].mean())):>14.4f}%")
            r()

    # ---------------------------------------------------------------- headline
    r.rule("6.  THE HEADLINE -- the window INTERSECTED across all three regimes")
    r("  A single shipped constant has to work in every regime it will meet, so the honest object")
    r("  is the INTERSECTION, not the per-regime window.  [max over regimes of the back bound,")
    r("  min over regimes of the front bound].")
    r()
    best = {}
    for n in NS:
        r(f"  --- N={n} ---")
        r(f"  {'c1':>7} " + " ".join(f"{rn+' win':>16}" for rn, _, _ in REG)
          + f" {'INTERSECTION':>18} {'width':>8} {'binds':>22}")
        for c1 in HEADS:
            ws, los, his, binds = [], [], [], []
            empty = False
            for rn, _, _ in REG:
                lo, hi, hst, lows, s = window(n, c1, rn)
                ws.append(s)
                if s.startswith("EMPTY"):
                    empty = True
                    never = [i for i, _, st in lows if st == 'never']
                    if never:
                        binds.append(f"{rn[:3]}:s{min(never)+1}")
                    else:
                        binds.append(f"{rn[:3]}:front")
                else:
                    los.append(lo); his.append(hi)
            if empty:
                istr, wid = "EMPTY", ""
            else:
                L, H = max(los), min(his)
                if L <= H:
                    istr = f"[{L:.0f}, {'9500+' if H == math.inf else f'{H:.0f}'}]"
                    wid = f"{(9500 - L) if H == math.inf else (H - L):.0f}"
                    best.setdefault(n, (c1, L, H))
                else:
                    istr, wid = "EMPTY (cross)", ""
                    binds.append("front<back")
            r(f"  {hlabel(c1):>7} " + " ".join(f"{x:>16}" for x in ws)
              + f" {istr:>18} {wid:>8} {(','.join(binds)):>22}")
        r()
        if n in best:
            c1, L, H = best[n]
            phi = L + (min(H, 9500.0) - L) / 2
            r(f"  SMALLEST HEAD SHARE WITH A NON-EMPTY INTERSECTION AT N={n}: c1 = {hlabel(c1)}")
            r(f"  intersected window [{L:.0f}, {'9500+' if H == math.inf else f'{H:.0f}'}], "
              f"midpoint phi = {phi:.0f}")
        else:
            r(f"  NO HEAD SHARE ON THIS GRID GIVES A NON-EMPTY INTERSECTION AT N={n}.")
            r("  That is the answer, not a failure to find one.  Section 4 says which seat binds")
            r("  in which regime and by how much.")
        r()

    # ------------------------------------------- the margin, not just the point estimate
    r.rule("6b.  DOES THE BINDING SEAT CLEAR WITH A MARGIN, OR ONLY ON THE POINT ESTIMATE?")
    r("  Section 6 finds the smallest c1 whose intersected window is non-empty.  That is a")
    r("  statement about where a MEAN CURVE crosses a bar, and a crossing is only as trustworthy")
    r("  as the standard error of the quantity that crosses.  Reporting the first c1 whose point")
    r("  estimate crosses zero, and shipping it, is precisely the green-number-chasing AGENTS.md")
    r("  section 2 calls the first sin.")
    r()
    r("  So: at each c1's own intersected-window MIDPOINT, the WORST back seat's gap to the")
    r("  passive LP in the WORST regime, with the PAIRED standard error of that difference.")
    r("  t is computed per path (queue and LP share a seed, hence a price path).")
    r()
    for n in NS:
        r(f"  --- N={n} ---")
        r(f"  {'c1':>7} {'window':>16} {'phi used':>9} {'regime':>8} {'seat':>5}"
          f" {'gap pp':>9} {'se_pair':>9} {'t_paired':>9} {'verdict':>26}")
        for c1 in HEADS:
            los, his, empty = [], [], False
            for rn, _, _ in REG:
                lo, hi, hst, lows, sw = window(n, c1, rn)
                if sw.startswith("EMPTY"):
                    empty = True
                else:
                    los.append(lo); his.append(hi)
            if empty:
                r(f"  {hlabel(c1):>7} {'EMPTY':>16} {'--':>9} {'--':>8} {'--':>5}"
                  f" {'--':>9} {'--':>9} {'--':>9} {'no window to test':>26}")
                continue
            L, H = max(los), min(his)
            phi = L + (min(H, 9500.0) - L) / 2
            k = min(range(len(PHIS)), key=lambda j: abs(PHIS[j] - phi))
            worst = None
            for rn, _, _ in REG:
                lpv = Z[(n, c1)][f"{rn}_lp"]
                A = Z[(n, c1)][f"{rn}_ret"][:, k, :]
                for i in range(1, n):
                    d = A[:, i] - lpv
                    g = float(d.mean()); sp = float(d.std(ddof=1) / math.sqrt(len(d)))
                    t = g / sp if sp > 0 else float('inf')
                    if worst is None or t < worst[0]:
                        worst = (t, rn, i + 1, g, sp)
            t, rn, si, g, sp = worst
            vd = ("CLEARS, t > 5" if t > 5 else
                  "clears, t > 2" if t > 2 else
                  "POINT ESTIMATE ONLY" if t > 0 else "DOES NOT CLEAR")
            r(f"  {hlabel(c1):>7} {f'[{L:.0f}, {chr(57)+chr(53)+chr(48)+chr(48)+chr(43)}]' if H == math.inf else f'[{L:.0f}, {H:.0f}]':>16}"
              f" {PHIS[k]:>9} {rn:>8} {('s'+str(si)):>5} {100*g:>+8.3f}p {100*sp:>8.3f}p"
              f" {t:>+9.1f} {vd:>26}")
        r()
        r("  READ THIS BEFORE QUOTING SECTION 6's MINIMUM.  A window whose binding seat clears by")
        r("  less than its own standard error is a window on a coin flip.  The smallest DEFENSIBLE")
        r("  head share is the smallest one in this table whose verdict is not 'POINT ESTIMATE")
        r("  ONLY' -- not the smallest one in section 6.")
        r()

    # ---------------------------------------------------------------- monotonicity
    r.rule("7.  IS IT MONOTONE IN c1?  The hypothesis stands or falls here")
    r("  The pre-registered claim was that BOTH constraints relax monotonically in c1: the back")
    r("  bound (max_i phi_i) should FALL and the front bound (phi_max) should RISE.  A break in")
    r("  either is a refutation of the model of the mechanism and is reported as such.")
    r("  Ordering for the check: NEVER counts as +inf on the back bound; 'no bound' counts as")
    r("  +inf on the front bound and 'below@0' as -inf.")
    r()
    for n in NS:
        for rn, _, _ in REG:
            r(f"  --- N={n} / {rn} ---")
            r(f"  {'c1':>7} {'back bound':>12} {'front bound':>12} {'wing bar':>10}"
              f" {'r1@'+str(PHI_T):>11} {'s2 gap pp':>11}")
            bb, fb = [], []
            for c1 in HEADS:
                R = m(n, c1, rn)
                _, mwv, _ = bar(n, c1, rn)
                lo, hi, hst, lows, s = window(n, c1, rn)
                never = [i for i, _, st in lows if st == 'never']
                bs = "NEVER" if never else f"{max(v for _, v, _ in lows):.0f}"
                fs = (f"{hi:.0f}" if hst == 'cross'
                      else ("no bound" if hst == 'always' else "below@0"))
                bb.append(math.inf if never else max(v for _, v, _ in lows))
                fb.append(math.inf if hst == 'always' else (-math.inf if hst == 'never' else hi))
                A = at_t(n, c1, rn)
                g = 100 * float((A[:, 1] - Z[(n, c1)][f"{rn}_lp"]).mean())
                r(f"  {hlabel(c1):>7} {bs:>12} {fs:>12} {pct(mwv):>10}"
                  f" {100*A[:,0].mean():>10.1f}% {g:>+10.3f}p")
            dn = all(b <= a + 1e-9 for a, b in zip(bb, bb[1:]))
            up = all(b >= a - 1e-9 for a, b in zip(fb, fb[1:]))
            r(f"    back bound monotonically NON-INCREASING in c1 (predicted): "
              f"{'YES' if dn else 'NO -- HYPOTHESIS REFUTED HERE'}")
            r(f"    front bound monotonically NON-DECREASING in c1 (predicted): "
              f"{'YES' if up else 'NO -- HYPOTHESIS REFUTED HERE'}")
            if not dn:
                bad = [f"{hlabel(HEADS[k])}->{hlabel(HEADS[k+1])}"
                       for k in range(len(bb) - 1) if bb[k + 1] > bb[k] + 1e-9]
                r(f"    back bound RISES across: {', '.join(bad)}")
            if not up:
                bad = [f"{hlabel(HEADS[k])}->{hlabel(HEADS[k+1])}"
                       for k in range(len(fb) - 1) if fb[k + 1] < fb[k] - 1e-9]
                r(f"    front bound FALLS across: {', '.join(bad)}")
            r()

    # ---------------------------------------------------------------- what the front gives up
    r.rule("8.  WHAT THE FRONT GIVES UP at the recommended (c1, phi)")
    if best:
        for n in NS:
            if n not in best:
                continue
            c1, L, H = best[n]
            phi = L + (min(H, 9500.0) - L) / 2
            k = min(range(len(PHIS)), key=lambda j: abs(PHIS[j] - phi))
            r(f"  --- N={n}, c1 = {hlabel(c1)}, recommended phi ~ {phi:.0f} "
              f"(nearest measured grid point {PHIS[k]}) ---")
            r(f"  {'regime':>8} {'r1':>9} {'passive LP':>11} {'vs LP':>9} {'wing bar':>10}"
              f" {'vs wing':>9} {'best back':>10} {'worst back':>11}")
            for rn, _, _ in REG:
                R = m(n, c1, rn)
                _, mwv, _ = bar(n, c1, rn)
                mn = R[k, 1:]
                r(f"  {rn:>8} {pct(R[k,0]):>9} {pct(LPm[rn]):>11}"
                  f" {100*(R[k,0]-LPm[rn]):>+8.2f}p {pct(mwv):>10}"
                  f" {100*(R[k,0]-mwv):>+8.2f}p {pct(mn.max()):>10} {pct(mn.min()):>11}")
            r()
            r("  The front is SUPPOSED to be worse than the passive LP here -- that is the whole")
            r("  transfer.  The bar it has to clear is the WING, which is what its capital would")
            r("  actually do if it left.  A positive 'vs wing' is the product; a positive 'vs LP'")
            r("  would mean the head is not paying for its priority at all.")
            r()
    else:
        r("  There is no recommended (c1, phi): section 6 found no non-empty intersection.")
        r()

    # ------------------------------------------- the closed form (NOT an independent check)
    r.rule("8b.  THE CLOSED FORM -- why the head share is the lever, algebraically")
    r("  PITFALLS 5.178 records the one quantity immune to the premium-basis question:")
    r()
    r("      the back's excess per unit of back capital  =  c1 * (LP - r1) / (1 - c1)")
    r()
    r("  It follows from sum_i c_i r_i = LP -- the premium is a transfer INSIDE the book, so it")
    r("  cannot change the pool's total -- and therefore holds under ANY weighting.")
    r()
    r("  READ THIS AS ALGEBRA, NOT AS EVIDENCE.  It is a rearrangement of the SAME identity that")
    r("  section 9 checks, so the agreement below is guaranteed by section 9 passing and could not")
    r("  read FAIL for any reason section 9 would not already have caught.  LAW 5: a control whose")
    r("  baseline is derived from the same quantity as its numerator is not a control.  It is")
    r("  printed because it EXPLAINS the mechanism -- the factor c1/(1 - c1) goes from 0.50 at")
    r("  c1 = 33.3% to 2.00 at c1 = 66.7%, a 4x amplification of whatever the head gives up --")
    r("  and not because it corroborates anything.")
    r()
    for n in NS:
        r(f"  --- N={n} ---   at phi = {PHI_T}")
        r(f"  {'regime':>8} {'c1':>7} {'c1/(1-c1)':>10} {'LP - r1':>9} {'predicted':>10}"
          f" {'actual back':>12} {'resid pp':>10}")
        for rn, _, _ in REG:
            for c1 in HEADS:
                A = at_t(n, c1, rn)
                cp = caps_for(weights_for(n, c1))
                c1f = cp[0] / BOOK
                r1 = float(A[:, 0].mean())
                bw_ = sum(cp[1:])
                actual = float((A[:, 1:] * np.array(cp[1:])).sum(axis=1).mean()) / bw_
                pred = c1f * (LPm[rn] - r1) / (1 - c1f) + LPm[rn]
                r(f"  {rn:>8} {hlabel(c1):>7} {c1f/(1-c1f):>10.2f} "
                  f"{100*(LPm[rn]-r1):>+8.2f}p {pct(pred):>10} {pct(actual):>12}"
                  f" {100*(actual-pred):>+9.4f}p")
            r()

    # ---------------------------------------------------------------- identity
    r.rule("9.  CONTROL -- the identity")
    r("  Worst per-path |capital-weighted queue return - the INDEPENDENTLY simulated pro-rata LP")
    r("  on the same seed|, over every phi, every c1, every regime.  The queue pool as a whole IS")
    r("  the undivided pool, so this is zero up to float noise however the seats are weighted.")
    r("  Existing runs report <= 3.8e-04.")
    r()
    r(f"  {'N':>3} {'c1':>7} " + " ".join(f"{rn:>12}" for rn, _, _ in REG))
    w9 = 0.0
    for n in NS:
        for c1 in HEADS:
            row = []
            for rn, _, _ in REG:
                e = float(Z[(n, c1)][f"{rn}_pool"].max())
                w9 = max(w9, e); row.append(e)
            r(f"  {n:>3} {hlabel(c1):>7} " + " ".join(f"{x:>12.2e}" for x in row))
    r()
    r(f"  WORST residual anywhere: {w9:.3e}   "
      f"{'PASS' if w9 < 1e-3 else 'FAIL -- the capital vector or the baseline is wrong'}")
    r()
    r.rule("10.  THE HEAD'S COMPETITOR, itemised, at every head size (BENIGN / TOXIC)")
    r("  A keeper-managed ATM range holding c1 of the book, re-minted at spot.  % of its OWN")
    r("  capital.  This is why the front bound moves with c1: conv impact scales with the range's")
    r("  own size against the ambient liquidity that is LEFT (Lbase = L*(book-cap)/book).")
    r()
    for n in NS:
        for rn in ("BENIGN", "TOXIC"):
            r(f"  --- N={n} / {rn} ---")
            r(f"  {'c1':>7} {'width':>7} {'re-mints':>9} {'fees':>10} {'markout':>10}"
              f" {'conv fee':>10} {'conv impact':>12} {'net ex-gas':>11} {'L2':>10}")
            for c1 in HEADS:
                z = Z[(n, c1)]
                for j, w_ in enumerate(MW):
                    a = z[f"{rn}_cost_{w_}"].mean(axis=0)
                    net = a[1] + a[2] - a[3] - a[4]
                    r(f"  {(hlabel(c1) if j == 0 else ''):>7} {w_:>7.0%} {a[0]:>9.0f}"
                      f" {pct(a[1]):>10} {pct(a[2]):>10} {pct(-a[3]):>10} {pct(-a[4]):>12}"
                      f" {pct(net):>11} {pct(float(z[f'{rn}_mw_{w_}_L2'].mean())):>10}")
            r()
    r("=" * 100)

    nb = r.commit(OUT)
    sys.stderr.write(f"[wrote {OUT} ({nb} bytes)]\n")
    assert os.path.getsize(OUT) > 0, "output file is EMPTY -- PITFALLS 5.79"


if __name__ == "__main__":
    sys.stderr.write(f"[head-size sweep on PREM_WEIGHT = {BASIS!r}]\n")
    assert sim.PREM_WEIGHT == BASIS, "the basis was reset between import and run"
    main()
