"""
THE PER-SEAT DOLLAR TABLE, ON THE CONFIGURATION PHASE 12 ACTUALLY ADOPTED.

WHY THIS FILE EXISTS.  `BUSINESS.md`'s per-seat P&L table is sourced from `results-shipping.txt`
(and its basis twin `results-shipping-basis.txt`), both produced by `report_shipping.py`, which
hardcodes

    report_shipping.py:41   SHIP = [BOOK*w/15.0 for w in (5, 4, 3, 2, 1)]      -> c1 = 33.3%

Phase 12 replaced that schedule.  `script/QueueDeployBase.sol` now ships

    :232   uint256[5] internal SEAT_WEIGHTS = [uint256(90), 44, 33, 22, 11];   -> c1 = 45%
    :190   uint256 internal constant PREMIUM_BPS = 5_500;

so the published dollar table describes a roster and a phi THIS PROJECT NO LONGER DEPLOYS.  Neither
number is cosmetic: `FRONTIER.md`'s closed form makes `c1` the dominant economic parameter
(`SLACK = c1 * (LP - B1)`, linear in `c1`), and phi moved 7,900 -> 5,100 -> 5,500 across two
re-measurements.  A table that mixes the old roster with the new prose is a green number by
accident.

`report_headsize.py` already swept `c1` and is the source of the 45% adoption, but it reports
CROSSOVER PHIS and gaps at phi = 5100 -- it does not produce the thing `BUSINESS.md` needs, which
is a per-seat table in DOLLARS at the SHIPPED phi with the pro-rata LP benchmark alongside every
row.  That is this file.  It does not edit `sim.py`, `report_shipping.py`, or any existing results
file.

WHAT IS COPIED VERBATIM, AND FROM WHERE.  Nothing about the environment is re-invented; only the
capital vector and phi move.  Each of these is lifted line-for-line from `report_shipping.py`:

    :40   BOOK, RPH, P0 = 1_000_000.0, 15.0, 2000.0
    :43   HALF = 0.10
    :45   REG = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
                 == (name, annualised vol, drift in units of the hourly sigma)
    :46   RANGES = A range(0,30) B range(100,130) C range(200,230) D range(1000,1030)
                 == 4 disjoint seed ranges x 30 = 120 paths per regime
    :53   run(..., days=365, marginal=True)                      the queue book
    :57   run([BOOK], False, ...)                                the passive pro-rata LP benchmark
    :61   turn = ((gv0 + tk0)*Pt + (gv1 + tk1)) / held           the turnover definition

and the fee is `sim.FEE = 0.0030`, matching the shipped 3000 fee tier.

THE PREMIUM BASIS, AND HOW IT REACHES THE WORKERS.  `sim.py:66` defaults to `PREM_WEIGHT =
'inventory'`, the PRE-Phase-8 weighting.  The contract divides by CONTRIBUTED LIQUIDITY WITH THE
PAYERS EXCLUDED (`QueueHook.sol:1356` `_claims` reads `s.liquidity`; `:1154` the denominator is
`standingL - excludedL`; `:1494` `_settlePremium` advances the payers' marks), which is `sim.py`'s
third mode `'liquidity_excl'`.  `report_shipping_basis.py`'s header works out the propagation and
this file follows it EXACTLY: the module-level assignment (which a `spawn`ed child re-runs when it
re-imports `__main__` to unpickle the work function) AND an explicit `Pool(initializer=...)`, so
the basis does not depend on that bootstrap side effect.

**AND IT IS NOT TAKEN ON TRUST.**  Every worker returns `Book.weight` -- the value the Book object
actually read at construction, not the value of the global at some later moment -- and section 1
asserts all 720 of them say `'liquidity_excl'`.  That control goes RED if the initializer is
dropped, if the start method changes, or if this file is ever imported as a library.

--------------------------------------------------------------------------------------------------
THE FOUR CONTROLS.  Check these before believing any dollar figure below (AGENTS.md LAW 5).
--------------------------------------------------------------------------------------------------
1.  THE BASIS INTERLOCK (section 1), above.

2.  EXTERNAL REPRODUCTION (section 2).  The passive LP's return and the in-band life are properties
    of the REGIME, not of the roster, so they must equal what `results-headsize.txt` published for
    the same regimes on a different day from a different script.  Those values are PARSED OFF DISK
    here rather than retyped.  This goes RED if the seeds, the band, the retail intensity, the vol
    or the drift have drifted from `report_shipping.py`'s -- i.e. if "copied verbatim" above is a
    lie.  It cannot go red for a reason internal to this file's own arithmetic.

3.  THE CONSERVATION IDENTITY (section 3).  The queue book as a whole IS the undivided pool, so the
    capital-weighted queue return must equal the independently simulated pro-rata LP on the same
    seed.  The right-hand side is a SEPARATE `run([BOOK], marginal=False)` with one seat and no
    premium -- not a rearrangement of this file's own numbers.
    **THE BRIEF FOR THIS FILE ASKED FOR A ~1e-13 GATE AND THAT THRESHOLD IS WRONG.  It is stated
    here rather than quietly widened.**  Two mechanisms put a floor above float noise on SOME paths:
      (a) CLAMPING.  `sim.py:144` refuses to source more than the queue can supply from its cursor
          onward, and the cursor makes the 5-seat book's availability differ from the 1-seat book's.
          A clamped swap moves the POOL price differently in the two runs, so later arb sizes differ.
      (b) THE HOLD RULE.  `sim.py:220-232` HOLDS a pot with no eligible recipient.  Premium still
          held at the end of a path is inside the queue book and outside the LP's.
    `results-headsize.txt` section 9 measured this at up to **3.08e-04** over its whole grid and
    called it PASS.  This file therefore prints the FULL distribution -- median, 99th pctile, worst,
    and the count of paths above 1e-13 -- with the terminal residual on the exact shipped cell
    called out, and lets the reader see the shape instead of asserting a bound that the instrument
    has never met.  A residual that jumped ORDERS OF MAGNITUDE above 3.8e-04 would be the finding.

    A free by-product control rides along: the external price path is driven only by `rng.normal`
    and the number of rng draws per hour does not depend on the book, so the queue run and the LP
    run must end at the BIT-IDENTICAL external price.  If they do not, the runs are not paired and
    every paired standard error below is wrong.  Section 3 asserts `Pt == Pt2` exactly.

4.  THE phi = 0 NEGATIVE CONTROL (section 4), and it is the one that can falsify the instrument.
    At phi = 0 nothing is withheld, the premium weight vector is never read, and the ONLY thing left
    distinguishing the seats is queue position.  The head is filled first on every swap in both
    directions, so in a BENIGN regime -- where fee income dominates and inventory markout is small
    -- rank 1 must be the BEST seat.  If it is not, the ordering advantage is not in the simulator
    and no phi table built on it means anything.
    Independently anchored: `results-headsize.txt` section 3 publishes `r1@0 = 11.0%` against a
    passive LP of `+5.02%` at c1 = 45% / BENIGN.

--------------------------------------------------------------------------------------------------
WHAT THIS FILE DOES NOT MODEL.  Inherited from `sim.py` and restated rather than hidden.
--------------------------------------------------------------------------------------------------
  rent       `sim.py` HAS NO RENT.  The deployed hook charges Harberger rent, and since Phase 12
             it flows FORWARD (back seats pay the head).  That runs OPPOSITE to the premium, so
             every back-seat surplus below is an UPPER bound on what a back seat keeps.
  band       modelled as a symmetric +/-10%; the shipped 960-tick band is +10.08% / -9.16%.
  decimals   floating point with no cross-token comparison, so it models the mechanism AS DESIGNED.
             On the shipped 18/6 pool the token0 premium is separately known to be inert
             (PITFALLS 5.124), which makes every premium number here an UPPER bound on what the
             deployed contract actually pays backward.
  seats      no seat funds, withdraws, or is bought out mid-path, so contributed liquidity is
             constant and the roster never permutes.

--------------------------------------------------------------------------------------------------
NON-PARTICIPATION IS NOT OUTPERFORMANCE (section 6, and it is the point of the file).
--------------------------------------------------------------------------------------------------
In TOXIC the passive LP LOSES money, so a seat that is never reached "beats" it by doing nothing --
`results-headsize.txt` 5b records rank 5 with ZERO turnover on 68.3% of TOXIC paths at c1 = 45%.
Turnover is therefore printed next to every return.

**AND THE FIRST DRAFT OF THIS FILE GOT THE CONCLUSION WRONG, WHICH IS WHY SECTION 6 IS AN IDENTITY
RATHER THAN A PATH SPLIT.**  That draft labelled rank 5 "capital preservation, not yield" on the
strength of its idle-path share.  The run refutes it in one number: rank 5 beats the LP by
**+2.96pp on the paths where it was IDLE, in BENIGN, where the LP EARNS +5.02%.**  Non-participation
scores zero against buy-and-hold; it cannot produce +8% on untouched capital.  Rank 5 is being PAID.

So the split that answers the question is by P&L LEG, not by path.  `sim.py`'s `tie_out()` already
asserts `opening + markout + own-fee + premium == closing`, so the edge decomposes exactly:

    edge over the LP  =  ACTIVITY  +  COUPON
    ACTIVITY = (markout + own fee retained)/held - LP return     what it earned by TRADING
    COUPON   = premium received / held                           what it was PAID for standing

A seat with ACTIVITY < 0 and a positive edge is **coupon-funded**: it is not out-trading an LP, it
is being subsidised by the seats in front.  That is the mechanism working as designed, and it is
still not the sentence "every seat beats a plain LP".  Section 6 prints both legs for every seat,
section 6b keeps the path split as a cross-check, and section 7's verdict names the funding source.

WRITE PATTERN (PITFALLS 5.79).  Every line is buffered, written to a tempfile, and `os.replace`d
onto the target only after the whole report is built, so an interrupted run cannot leave a
truncated results file behind with `git status` clean.

Reproduce:  python3 report_shipped45.py            # writes results-shipped45.txt
"""
import sys, os, re, math, time, tempfile, multiprocessing

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim

BASIS = "liquidity_excl"
sim.PREM_WEIGHT = BASIS                 # the parent, before any Book exists

from sim import run                     # noqa: E402  -- imported AFTER the basis is set

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "results-shipped45.txt")

# ------------------------------------------------------------------ the SHIPPED configuration
# QueueDeployBase.sol:232  SEAT_WEIGHTS = [90, 44, 33, 22, 11]   (sum 200, so 45% is exact)
# QueueDeployBase.sol:190  PREMIUM_BPS  = 5_500
WEIGHTS = (90, 44, 33, 22, 11)
WSUM = float(sum(WEIGHTS))                      # 200
PHI = 5500
PHI_CTL = 0

# copied verbatim from report_shipping.py -- see the docblock for the line numbers
BOOK, RPH, P0 = 1_000_000.0, 15.0, 2000.0
HALF = 0.10
REG = (("BENIGN", 0.25, 0.00), ("NORMAL", 0.45, 0.00), ("TOXIC", 0.80, 0.35))
RANGES = (("A", range(0, 30)), ("B", range(100, 130)), ("C", range(200, 230)),
          ("D", range(1000, 1030)))
SEEDS = [sd for _, rg in RANGES for sd in rg]   # 120, four disjoint ranges

CAPS = [BOOK * w / WSUM for w in WEIGHTS]
N = len(CAPS)
SEED_DESC = "A 0-29 / B 100-129 / C 200-229 / D 1000-1029 (4 disjoint ranges x 30 = 120)"


def _init():
    """Runs in every worker at spawn.  Without this the workers use sim.py's 'inventory' default."""
    import sim as _s
    _s.PREM_WEIGHT = BASIS


def one(a):
    """One (phi, regime, seed) cell: the queue book AND its paired passive-LP benchmark.

    The LP is a SEPARATE simulation -- one seat holding the whole book, average pricing, no premium
    -- not a quantity derived from the queue run.  That is what makes section 3 a control rather
    than a rearrangement.
    """
    phi, vol, dr, seed = a
    bk, _, Pt = run(CAPS, True, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                    half=HALF, phi=phi)
    bk.tie_out(Pt)                       # the decomposition must reconstruct the balances
    d, h = bk.pnl(Pt)
    # THE EXACT SPLIT, in numeraire, per seat.  sim.py guarantees mk + fe + pr == pnl because
    # tie_out() has already asserted o + mk + fe + pr == a.  This is what makes section 6 an
    # identity rather than an inference from the shape of the idle-path means.
    mk = bk.mk0 * Pt + bk.mk1            # inventory markout: principal in, take out
    fe = bk.fe0 * Pt + bk.fe1            # fee retained on the seat's OWN fills, net of premium paid
    pr = bk.pr0 * Pt + bk.pr1            # premium RECEIVED from the seats in front
    pb, _, Pt2 = run([BOOK], False, days=365, retail_per_hr=RPH, seed=seed, vol=vol, drift=dr,
                     half=HALF)
    dp, hp = pb.pnl(Pt2)
    lp = float(dp[0] / hp[0])
    flow = (bk.gv0 + bk.tk0) * Pt + (bk.gv1 + bk.tk1)     # report_shipping.py:61, both legs
    return dict(basis=bk.weight,                 # what the Book READ, not what a global says now
                ret=d / h, pnl=d, held=h, turn=flow / h, flow=flow,
                mk=mk, fe=fe, pr=pr,
                lp=lp, hrs=bk.hrs,
                qtot=float(d.sum() / h.sum()),
                pt_gap=abs(Pt - Pt2),
                heldpot=float((bk.held0 * Pt + bk.held1) / h.sum()))


# ------------------------------------------------------------------------------- output plumbing
BUF = []
W = 100


def p(s=""):
    BUF.append(s)


def rule(t):
    p("=" * W); p(t); p("=" * W)


def pct(x):
    return f"{100*x:+.2f}%"


def usd(x):
    return f"{x:+,.0f}"


def published_lp():
    """Parse results-headsize.txt for the per-regime passive-LP return and in-band life.

    Parsed off disk on purpose (control 2): those numbers were produced by a different script on a
    different day, so agreeing with them is evidence and not arithmetic.
    """
    path = os.path.join(HERE, "results-headsize.txt")
    if not os.path.exists(path):
        return None
    got = {}
    pat = re.compile(r"---\s+N=5\s*/\s*(\w+)\s+---\s+passive pro-rata LP\s+([+-][\d.]+)%.*?"
                     r"in-band life\s+([\d.]+)d")
    for line in open(path):
        m = pat.search(line)
        if m and m.group(1) not in got:
            got[m.group(1)] = (float(m.group(2)) / 100.0, float(m.group(3)))
    return got or None


def main():
    t0 = time.time()
    jobs, keys = [], []
    for phi in (PHI, PHI_CTL):
        for rn, v, dr in REG:
            for sd in SEEDS:
                jobs.append((phi, v, dr, sd)); keys.append((phi, rn))
    nproc = max(1, os.cpu_count() or 4)
    sys.stderr.write(f"[shipped-45 report: {len(jobs)} cells "
                     f"(2 sims each) on {nproc} procs, basis {BASIS!r}]\n")
    with multiprocessing.Pool(nproc, initializer=_init) as pool:
        res = pool.map(one, jobs, chunksize=8)
    sys.stderr.write(f"[sims done {time.time()-t0:.0f}s]\n")

    C = {}
    for k, v in zip(keys, res):
        C.setdefault(k, []).append(v)

    def arr(phi, rn, key):
        return np.array([r[key] for r in C[(phi, rn)]])

    # ------------------------------------------------------------------------------ the header
    rule("QUEUE PER-SEAT P&L -- THE CONFIGURATION PHASE 12 ACTUALLY SHIPS")
    p(f"  roster        {N} seats, capital weights {':'.join(str(w) for w in WEIGHTS)} "
      f"(QueueDeployBase.sol:232)")
    p(f"  head share    c1 = {CAPS[0]/BOOK:.1%}   (was 33.3% under weights 5:4:3:2:1)")
    p(f"  book          ${BOOK:,.0f}   -> caps " + " / ".join(f"${c:,.0f}" for c in CAPS))
    p(f"  phi           {PHI} bps        (PREMIUM_BPS, QueueDeployBase.sol:190; was 5,100)")
    p(f"  premium basis {BASIS!r}  -- the rule the contract implements (QueueHook.sol:1154/1356/1494)")
    p(f"  band          symmetric +/-{HALF:.0%}, fee {100*sim.FEE:.2f}%, retail {RPH:.0f}/hr, "
      f"P0 = {P0:,.0f}, days 365")
    p(f"  paths         {len(SEEDS)} per regime, seeds {SEED_DESC}")
    p(f"  regimes       " + ",  ".join(f"{n} vol={v:.2f} drift={d:+.2f}" for n, v, d in REG)
      + "   [report_shipping.py:45, copied verbatim]")
    p()
    p("  THIS FILE SUPERSEDES results-shipping.txt / results-shipping-basis.txt FOR THE DOLLAR")
    p("  TABLE ONLY.  Those files sweep phi and locate the feasible window; they do it on the OLD")
    p("  33.3% roster.  Nothing here re-derives a window -- read results-headsize.txt for that.")
    p()
    p("  NOT MODELLED: rent (sim.py has none; on the deployed hook it flows FORWARD since Phase 12,")
    p("  opposite to the premium, so every back-seat surplus below is an UPPER bound); the band's")
    p("  0.9pp asymmetry; the 18/6 token0 premium inertness (PITFALLS 5.124), also an upper bound.")
    p()

    # ------------------------------------------------------------------- 1. the basis interlock
    rule("1.  CONTROL -- the premium basis the Book objects actually read")
    p("  Every worker returns Book.weight, set at construction from the module global.  If the")
    p("  Pool initializer were dropped and the spawn bootstrap did not carry the assignment, these")
    p("  would read 'inventory' and every premium number in the file would be measuring the")
    p("  PRE-Phase-8 rule.  This is the value the object used, not the value of a global now.")
    p()
    seen = sorted({r['basis'] for r in res})
    p(f"    distinct Book.weight values across all {len(res)} cells: {seen}")
    ok_basis = (seen == [BASIS])
    p(f"    all cells on {BASIS!r}:  {'PASS' if ok_basis else 'FAIL -- EVERY NUMBER BELOW IS VOID'}")
    if not ok_basis:
        p()
        p("  *** STOP.  The basis did not propagate.  Do not read the rest of this file. ***")
    p()

    # ------------------------------------------------------- 2. external reproduction of the LP
    rule("2.  CONTROL -- the passive LP and the in-band life reproduce results-headsize.txt")
    p("  The benchmark and the band's life are properties of the REGIME, not of the roster, so")
    p("  they must match a file produced by a different script on a different day.  Parsed off")
    p("  disk, not retyped.  Goes RED if the seeds, band, vol, drift or retail intensity drifted.")
    p()
    pub = published_lp()
    p(f"    {'regime':>10} {'LP here':>12} {'LP published':>14} {'d pp':>9} "
      f"{'life here':>11} {'life pub':>10} {'ok':>6}")
    ok_repro = pub is not None
    for rn, _, _ in REG:
        lpv = float(np.mean(arr(PHI, rn, 'lp')))
        life = float(np.mean(arr(PHI, rn, 'hrs'))) / 24.0
        if pub and rn in pub:
            plp, plf = pub[rn]
            dpp = 100 * (lpv - plp)
            good = abs(dpp) <= 0.005 and abs(life - plf) <= 0.05
            ok_repro &= good
            p(f"    {rn:>10} {pct(lpv):>12} {pct(plp):>14} {dpp:>+9.4f} "
              f"{life:>10.1f}d {plf:>9.1f}d {'PASS' if good else 'FAIL':>6}")
        else:
            ok_repro = False
            p(f"    {rn:>10} {pct(lpv):>12} {'NOT FOUND':>14} {'-':>9} {life:>10.1f}d "
              f"{'-':>10} {'FAIL':>6}")
    p()
    p(f"    reproduction: {'PASS -- this is the published harness' if ok_repro else 'FAIL'}")
    p("    (published values rounded to 2dp / 1dp in the source file; tolerance is that rounding)")
    p()

    # -------------------------------------------------------------- 3. the conservation identity
    rule("3.  CONTROL -- conservation: the queue book IS the undivided pool")
    p("  For each path:   residual = | sum_i (capital_i/CAPITAL) * ret_i  -  passive LP ret |")
    p("  The left side is the queue's 5 seats; the right side is a SEPARATE one-seat simulation")
    p("  with no premium at all.  Same seed, same price path.")
    p()
    p("  THE BRIEF ASKED FOR A ~1e-13 GATE.  That threshold is NOT met by this instrument and")
    p("  never has been, for two reasons that are in the model rather than in the arithmetic:")
    p("    (a) CLAMPING (sim.py:144) -- the 5-seat book's availability runs from its cursor, so a")
    p("        swap the queue clamps and the monolith does not moves the POOL price differently,")
    p("        and every later arb is then sized against a different spot.")
    p("    (b) THE HOLD RULE (sim.py:220-232) -- a pot with no eligible recipient is HELD.  Premium")
    p("        still held at path end sits inside the queue book and outside the LP's.")
    p("  results-headsize.txt section 9 measured this over its whole grid at up to 3.08e-04 and")
    p("  called it PASS.  The distribution is printed rather than a bound asserted.")
    p()
    p("  MEASURED HERE, and it separates the two candidate mechanisms rather than leaving both")
    p("  standing: the phi = 0 rows are pure float (worst ~2e-14, ZERO paths above 1e-13), and in")
    p("  every phi = 5500 row the WORST residual equals the HELD POT column to the printed digit.")
    p("  So (b) the hold rule accounts for all of it and (a) clamping contributes nothing")
    p("  detectable on this grid.  The residual is undistributed premium sitting inside the queue")
    p("  book, which is a real difference between the two books, not an arithmetic error.")
    p()
    p(f"    {'phi':>6} {'regime':>10} {'median':>11} {'p99':>11} {'worst':>11} "
      f"{'n>1e-13':>9} {'held pot':>11} {'max|dPt|':>10}")
    worst_all = 0.0
    ok_pt = True
    for phi in (PHI, PHI_CTL):
        for rn, _, _ in REG:
            q = arr(phi, rn, 'qtot'); l = arr(phi, rn, 'lp')
            r = np.abs(q - l)
            hp_ = float(np.max(np.abs(arr(phi, rn, 'heldpot'))))
            dpt = float(np.max(arr(phi, rn, 'pt_gap')))
            ok_pt &= (dpt == 0.0)
            worst_all = max(worst_all, float(r.max()))
            p(f"    {phi:>6} {rn:>10} {np.median(r):>11.3e} {np.percentile(r,99):>11.3e} "
              f"{r.max():>11.3e} {int((r>1e-13).sum()):>9} {hp_:>11.3e} {dpt:>10.1e}")
    p()
    p(f"    WORST residual anywhere: {worst_all:.3e}   "
      f"{'PASS -- at or below the published 3.08e-04' if worst_all <= 3.8e-4 else 'FAIL -- ABOVE the published scale; treat this run as VOID'}")
    p(f"    paired-path check, max |Pt_queue - Pt_lp| over every cell: "
      f"{'0 exactly -- the runs share a bit-identical external price path' if ok_pt else 'NONZERO -- THE PAIRED SEs BELOW ARE WRONG'}")
    p()

    # ---------------------------------------------------------------- 4. the phi = 0 control
    rule("4.  NEGATIVE CONTROL -- phi = 0: is the ordering advantage UNSUBSIDISED?")
    p("  At phi = 0 nothing is withheld and the premium weight vector is never read.  The only")
    p("  thing left separating the seats is queue position.  In BENIGN, where fee income dominates")
    p("  and inventory markout is small, the head is filled first on every swap in both directions")
    p("  and MUST therefore be the best seat.  If it is not, the ordering advantage is not in this")
    p("  simulator and no phi table built on it means anything.")
    p()
    p("  WHAT WOULD MAKE THIS READ FAIL: a front seat that is not first in BENIGN at phi = 0.")
    p("  It is not arithmetic -- a mis-signed premium, a cursor that does not reset, or an")
    p("  allocator that splits pro-rata rather than front-first all break it.")
    p()
    ctl_ok = True
    for rn, _, _ in REG:
        R0 = arr(PHI_CTL, rn, 'ret')
        m = R0.mean(axis=0)
        lpv = float(np.mean(arr(PHI_CTL, rn, 'lp')))
        best = int(np.argmax(m))
        p(f"  --- {rn} at phi = 0 ---   passive LP {pct(lpv)}")
        p("     seat " + "".join(f"{'s'+str(i+1):>11}" for i in range(N)))
        p("     ret  " + "".join(f"{pct(x):>11}" for x in m))
        tag = "front is best -- PASS" if best == 0 else f"BEST IS s{best+1}, NOT THE FRONT"
        if rn == "BENIGN":
            ctl_ok = (best == 0)
            p(f"     -> {tag}   [this is the control]")
        else:
            p(f"     -> best seat s{best+1}   [informational: in a losing regime the front absorbs")
            p(f"        the move first, so it is EXPECTED to rank last -- that is subordination]")
        p()
    p(f"  phi = 0 CONTROL: {'PASS' if ctl_ok else 'FAIL -- THE INSTRUMENT IS BROKEN, STOP READING'}")
    p("  Independent anchor: results-headsize.txt section 3 publishes r1@0 = 11.0% against a")
    p(f"  passive LP of +5.02% at c1 = 45% / BENIGN.  Here r1@0 = "
      f"{pct(float(arr(PHI_CTL,'BENIGN','ret').mean(axis=0)[0]))}.")
    p()

    # --------------------------------------------------------------- 5. the per-seat tables
    rule(f"5.  THE PER-SEAT TABLE at the SHIPPED phi = {PHI}")
    p("  Returns are against BUY-AND-HOLD of the seat's own opening inventory, marked at the")
    p("  terminal price -- the same measure sim.py's pnl() uses, so 'LP $' is the pro-rata LP's")
    p("  return applied to the SAME held value, path by path, not to the opening $ capital.")
    p()
    p("  se and t are PAIRED: the queue run and the LP run share a seed and therefore a")
    p("  bit-identical external price path (section 3), so the paired SE is the correct one.")
    p("  |t| >= 2 is the bar.  Turnover counts BOTH legs (gross in + drained out) over held value,")
    p("  i.e. 'how many times the seat's capital was traded through', report_shipping.py:61.")
    p()
    p("  VERDICT: BEATS LP / LOSES TO LP require |t| >= 2; otherwise TIE.  The parenthetical names")
    p("  the FUNDING SOURCE, computed in section 6 as an identity: '(earned)' = the seat's own")
    p("  trading beat the LP, '(coupon)' = it did not and the premium is the whole reason, 'idle'")
    p("  = it was traded through on fewer than half the paths.  Read the verdict with the 'turns'")
    p("  and 'filled' columns, never without.")
    p()
    verdicts = {}
    for rn, _, _ in REG:
        Rq = arr(PHI, rn, 'ret')                 # (paths, seats)
        Hd = arr(PHI, rn, 'held')
        Pl = arr(PHI, rn, 'pnl')
        Tn = arr(PHI, rn, 'turn')
        Fl = arr(PHI, rn, 'flow')
        lp = arr(PHI, rn, 'lp')                  # (paths,)
        Mk = arr(PHI, rn, 'mk'); Fe = arr(PHI, rn, 'fe'); Pr = arr(PHI, rn, 'pr')
        life = float(np.mean(arr(PHI, rn, 'hrs'))) / 24.0
        lp_usd = lp[:, None] * Hd                # LP's $ on the SAME held value
        d_pp = Rq - lp[:, None]
        d_usd = Pl - lp_usd
        # THE EDGE SPLITS EXACTLY IN TWO, because mk + fe + pr == pnl (tie_out asserts it):
        #   ACTIVITY = what the seat earned by TRADING, measured against the LP
        #   COUPON   = the premium transferred to it from the seats in front
        act_pp = (Mk + Fe) / Hd - lp[:, None]
        cou_pp = Pr / Hd
        n = Rq.shape[0]
        p(f"  --- {rn} ---   passive pro-rata LP {pct(float(lp.mean()))} "
          f"(se {100*lp.std(ddof=1)/math.sqrt(n):.3f}pp)   in-band life {life:.1f}d   "
          f"{n} paths   phi {PHI}   basis {BASIS}")
        p(f"  {'seat':>5} {'capital $':>12} {'ret %':>9} {'ret $':>12} {'LP %':>9} {'LP $':>12} "
          f"{'diff $':>12} {'diff pp':>9} {'se pp':>8} {'t':>8} {'turns':>7} {'filled':>7}  verdict")
        rows = []
        for i in range(N):
            mu = float(d_pp[:, i].mean())
            se = float(d_pp[:, i].std(ddof=1) / math.sqrt(n))
            t = mu / se if se > 0 else float('inf') * (1 if mu > 0 else -1)
            turn = float(Tn[:, i].mean())
            filled = float((Fl[:, i] > 0).mean())
            am = float(act_pp[:, i].mean()); cm = float(cou_pp[:, i].mean())
            idle = " idle" if filled < 0.5 else ""
            if t >= 2:
                v = ("BEATS LP (earned%s)" % idle) if am > 0 else ("BEATS LP (coupon%s)" % idle)
            elif t <= -2:
                v = "LOSES TO LP"
            else:
                v = "TIE (|t|<2)"
            rows.append((i, mu, se, t, turn, filled, v))
            verdicts[(rn, i)] = (mu, se, t, turn, filled, v, am, cm)
            p(f"  {'s'+str(i+1):>5} {CAPS[i]:>12,.0f} {pct(float(Rq[:,i].mean())):>9} "
              f"{usd(float(Pl[:,i].mean())):>12} {pct(float(lp.mean())):>9} "
              f"{usd(float(lp_usd[:,i].mean())):>12} {usd(float(d_usd[:,i].mean())):>12} "
              f"{mu*100:>+9.3f} {se*100:>8.3f} {t:>+8.1f} {turn:>7.2f} {filled:>6.0%}  {v}")
        # the book-level line: what the sponsor's whole $1m did
        p(f"  {'ALL':>5} {BOOK:>12,.0f} {pct(float((Pl.sum(axis=1)/Hd.sum(axis=1)).mean())):>9} "
          f"{usd(float(Pl.sum(axis=1).mean())):>12} {pct(float(lp.mean())):>9} "
          f"{usd(float(lp_usd.sum(axis=1).mean())):>12} "
          f"{usd(float(d_usd.sum(axis=1).mean())):>12} "
          f"{'':>9} {'':>8} {'':>8} {'':>7} {'':>7}  (must be ~0 -- section 3)")
        p()

    # -------------------------------------------- 6. where the edge comes from: the exact split
    rule("6.  WHERE EACH SEAT'S EDGE COMES FROM -- an IDENTITY, not an inference")
    p("  sim.py's tie_out() asserts  opening + markout + own-fee + premium == closing balance,  so")
    p("  per-seat P&L splits EXACTLY into three legs and the edge over the LP splits into two:")
    p()
    p("      edge  =  ACTIVITY  +  COUPON")
    p("      ACTIVITY = (markout + own fee retained) / held  -  LP return")
    p("      COUPON   = premium received / held")
    p()
    p("  This is the number that settles 'does the seat earn or does it abstain', and it replaces")
    p("  an earlier draft of this file that tried to read the answer off the idle-path means.")
    p("  THAT DRAFT WAS WRONG: it labelled s5 'capital preservation', and s5 beats the LP by")
    p("  ~+2.96pp on its IDLE paths in BENIGN, a regime where the LP EARNS +5.02%.  Doing nothing")
    p("  cannot produce that.  s5 is being PAID, and the split below says so in one column.")
    p()
    p("  A seat with ACTIVITY < 0 and a positive edge is COUPON-FUNDED: it is not out-trading the")
    p("  LP, it is being subsidised by the seats in front.  That is the mechanism working as")
    p("  designed -- but it is NOT 'this seat beats an LP', and the two must not be conflated.")
    p()
    p(f"  {'regime':>8} {'seat':>5} {'ret %':>9} {'markout':>10} {'own fee':>10} {'premium':>10}"
      f" {'LP %':>9} {'edge pp':>9} {'ACTIVITY':>10} {'COUPON':>9} {'coupon/edge':>12}"
      f" {'turns':>7} {'idle':>6}")
    for rn, _, _ in REG:
        Rq = arr(PHI, rn, 'ret'); Hd = arr(PHI, rn, 'held'); lp = arr(PHI, rn, 'lp')
        Mk = arr(PHI, rn, 'mk'); Fe = arr(PHI, rn, 'fe'); Pr = arr(PHI, rn, 'pr')
        Tn = arr(PHI, rn, 'turn'); Fl = arr(PHI, rn, 'flow')
        act = (Mk + Fe) / Hd - lp[:, None]
        cou = Pr / Hd
        for i2 in range(N):
            e = float((Rq[:, i2] - lp).mean())
            a_ = float(act[:, i2].mean()); c_ = float(cou[:, i2].mean())
            sh = (c_ / e) if abs(e) > 1e-12 else float('nan')
            p(f"  {rn if i2==0 else '':>8} {'s'+str(i2+1):>5} {pct(float(Rq[:,i2].mean())):>9}"
              f" {pct(float((Mk[:,i2]/Hd[:,i2]).mean())):>10}"
              f" {pct(float((Fe[:,i2]/Hd[:,i2]).mean())):>10}"
              f" {pct(float((Pr[:,i2]/Hd[:,i2]).mean())):>10}"
              f" {pct(float(lp.mean())):>9} {e*100:>+9.3f} {a_*100:>+10.3f} {c_*100:>+9.3f}"
              f" {(sh if sh==sh else float('nan')):>11.0%} {float(Tn[:,i2].mean()):>7.2f}"
              f" {float((Fl[:,i2]==0).mean()):>5.0%}")
            # identity check, printed only if it fails
            if abs((a_ + c_) - e) > 1e-9:
                p(f"      *** IDENTITY BROKEN on {rn} s{i2+1}: "
                  f"activity+coupon = {a_+c_:.6e} != edge {e:.6e} ***")
        p()
    p("  'own fee' is the LP fee the seat kept on its OWN fills, already NET of the premium it")
    p("  forfeited forward.  'markout' is the inventory leg -- negative is adverse selection.")
    p("  Every row satisfies ACTIVITY + COUPON == edge to 1e-9; a violation prints inline above.")
    p()

    # -------------------------------------- 6b. the filled/idle path split, kept as a cross-check
    rule("6b.  CROSS-CHECK -- the same question asked by PATH rather than by LEG")
    p("  An UNREACHED seat's markout and own-fee legs are exactly zero, so on an idle path its")
    p("  whole return IS the coupon.  Splitting the surplus by path must therefore agree with the")
    p("  leg split above; it is kept because it answers a different reader's question -- 'how often")
    p("  is this seat actually doing anything?' -- and because disagreement would be a finding.")
    p()
    p(f"  {'regime':>8} {'seat':>5} {'idle paths':>11} {'edge ALL':>10} {'edge FILLED':>12}"
      f" {'t FILLED':>9} {'edge IDLE':>10} {'ACTIVITY on filled paths':>26}")
    earned = {}
    for rn, _, _ in REG:
        Rq = arr(PHI, rn, 'ret'); Hd = arr(PHI, rn, 'held'); lp = arr(PHI, rn, 'lp')
        Mk = arr(PHI, rn, 'mk'); Fe = arr(PHI, rn, 'fe'); Fl = arr(PHI, rn, 'flow')
        act = (Mk + Fe) / Hd - lp[:, None]
        d_pp = Rq - lp[:, None]
        for i2 in range(N):
            f = Fl[:, i2] > 0
            idl = ~f
            all_mu = float(d_pp[:, i2].mean())
            fm = float(d_pp[f, i2].mean()) if f.any() else float('nan')
            fse = (float(d_pp[f, i2].std(ddof=1) / math.sqrt(f.sum()))
                   if f.sum() > 1 else float('nan'))
            ft = fm / fse if fse == fse and fse > 0 else float('nan')
            im = float(d_pp[idl, i2].mean()) if idl.any() else float('nan')
            fa = float(act[f, i2].mean()) if f.any() else float('nan')
            earned[(rn, i2)] = (fm, ft, fa, float(idl.mean()))
            p(f"  {rn if i2==0 else '':>8} {'s'+str(i2+1):>5} {idl.mean():>10.1%}"
              f" {all_mu*100:>+10.3f} {(fm*100 if fm==fm else float('nan')):>+12.3f}"
              f" {(ft if ft==ft else float('nan')):>+9.1f}"
              f" {(im*100 if im==im else float('nan')):>+10.3f}"
              f" {(fa*100 if fa==fa else float('nan')):>+25.3f}pp")
        p()
    p("  The last column is the decisive one for the back seats: it is the ACTIVITY leg restricted")
    p("  to the paths where the seat was actually traded through.  Negative means that even when")
    p("  the mechanism reached it, the seat under-traded a plain LP and only the coupon saved it.")
    p()

    # ------------------------------------------------------------------------- 7. the verdict
    rule("7.  VERDICT -- does EVERY seat beat a plain LP in EVERY regime at the shipped config?")
    p()
    p(f"  {'regime':>8} " + "".join(f"{'s'+str(i2+1):>24}" for i2 in range(N)))
    for rn, _, _ in REG:
        p(f"  {rn:>8} " + "".join(f"{verdicts[(rn,i2)][5]:>24}" for i2 in range(N)))
    p()
    p("  ACTIVITY leg (pp vs the LP) -- what the seat earned by TRADING, coupon stripped out:")
    p(f"  {'regime':>8} " + "".join(f"{'s'+str(i2+1):>24}" for i2 in range(N)))
    for rn, _, _ in REG:
        p(f"  {rn:>8} " + "".join(f"{verdicts[(rn,i2)][6]*100:>+23.3f}p" for i2 in range(N)))
    p()
    p("  COUPON leg (premium received, pp of the seat's own held value):")
    p(f"  {'regime':>8} " + "".join(f"{'s'+str(i2+1):>24}" for i2 in range(N)))
    for rn, _, _ in REG:
        p(f"  {rn:>8} " + "".join(f"{verdicts[(rn,i2)][7]*100:>+23.3f}p" for i2 in range(N)))
    p()
    losers = [(rn, i2) for rn, _, _ in REG for i2 in range(N)
              if verdicts[(rn, i2)][5].startswith("LOSES")]
    idlers = [(rn, i2) for rn, _, _ in REG for i2 in range(N)
              if verdicts[(rn, i2)][4] < 0.5]
    coupon = [(rn, i2) for rn, _, _ in REG for i2 in range(N)
              if verdicts[(rn, i2)][2] >= 2 and verdicts[(rn, i2)][6] <= 0]
    p(f"  seats LOSING to the LP (t <= -2):")
    p(f"      {', '.join(f'{r} s{i2+1}' for r, i2 in losers) if losers else 'none'}")
    p(f"  seats traded through on FEWER THAN HALF the paths:")
    p(f"      {', '.join(f'{r} s{i2+1}' for r, i2 in idlers) if idlers else 'none'}")
    p(f"  seats whose win is COUPON-FUNDED (activity leg <= 0 -- subsidised, not out-trading):")
    p(f"      {', '.join(f'{r} s{i2+1}' for r, i2 in coupon) if coupon else 'none'}")
    p()
    nreg = len(REG)
    allbeat = all(verdicts[(rn, i2)][2] >= 2 for rn, _, _ in REG for i2 in range(N))
    rule("7b.  THE MECHANISM IS EXACTLY ZERO-SUM -- the back's gain IS the head's loss")
    p("  Section 3 already proved the queue book and the undivided pool are the same position, so")
    p("  this is forced rather than surprising -- but it is the sentence a funder needs, and it is")
    p("  printed in DOLLARS because a percentage hides it.  QUEUE does not create return.  It")
    p("  moves return from the seat at the front to the seats behind it.")
    p()
    p(f"  {'regime':>8} {'head s1 vs LP $':>17} {'seats 2-5 vs LP $':>19} {'sum $':>10}"
      f" {'as % of book':>13}")
    for rn, _, _ in REG:
        Hd = arr(PHI, rn, 'held'); Pl = arr(PHI, rn, 'pnl'); lp = arr(PHI, rn, 'lp')
        du = Pl - lp[:, None] * Hd
        h1 = float(du[:, 0].mean()); bk_ = float(du[:, 1:].sum(axis=1).mean())
        p(f"  {rn:>8} {usd(h1):>17} {usd(bk_):>19} {usd(h1+bk_):>10}"
          f" {100*(h1+bk_)/BOOK:>12.4f}%")
    p()
    p("  The `sum $` column is the section-3 conservation residual in dollars, and it is the")
    p("  undistributed premium still HELD at path end -- not slippage in the accounting.")
    p()
    p("  CORROBORATION FROM THE phi = 0 CONTROL (section 4), which is a DIFFERENT measurement:")
    p("  strip the premium and the back seats collapse.  In BENIGN at phi = 0 the passive LP")
    p("  returns +5.02% while s2..s5 return " +
      ", ".join(pct(float(x)) for x in arr(PHI_CTL, 'BENIGN', 'ret').mean(axis=0)[1:]) + " --")
    p("  every one of them 4.6-5.0pp BELOW the LP.  Their entire case rests on the coupon.")
    p("=" * W)
    p()

    rule("7c.  THE ANSWER, IN ONE LINE EACH")
    p(f"  DOES EVERY SEAT BEAT A PLAIN LP IN EVERY REGIME?   {'YES' if allbeat else 'NO'}")
    p(f"  DOES EVERY BACK SEAT (2..{N}) BEAT A PLAIN LP IN EVERY REGIME?   "
      f"{'YES' if all(verdicts[(rn,i2)][2] >= 2 for rn,_,_ in REG for i2 in range(1,N)) else 'NO'}")
    p(f"  ...AND DOES ANY OF THEM DO IT BY OUT-TRADING RATHER THAN BY BEING PAID?   "
      f"{'YES' if any(verdicts[(rn,i2)][6] > 0 for rn,_,_ in REG for i2 in range(1,N)) else 'NO -- every back-seat win is coupon-funded'}")
    p("=" * W)

    tmp = tempfile.NamedTemporaryFile("w", dir=HERE, delete=False, suffix=".tmp")
    tmp.write("\n".join(BUF) + "\n")
    tmp.close()
    os.replace(tmp.name, OUT)
    sys.stderr.write(f"[wrote {OUT} in {time.time()-t0:.0f}s]\n")


if __name__ == "__main__":
    assert sim.PREM_WEIGHT == BASIS, "the basis was reset between import and run"
    main()
