#!/usr/bin/env python3
"""
HASTE free-option / separating-premium economics.   2026-08-26.   Seeded, reproducible.
Run: python3 docs/research/data/haste_economics.py

ASSUMPTIONS - all load-bearing, all stated. If one is wrong the conclusion moves.
 A1 External price S is driftless GBM; per-block log return ~ N(-sb^2/2, sb^2).
    Driftless is the correct null: drift is information, and information is priced the same
    on both lanes, so drift alone cannot create a lane preference.
 A2 Pool is constant-product, proportional fee f on the input. Concentrated liquidity
    changes the depth constant, not the shape of any conclusion here.
 A3 Arbitrage is COMPETITIVE: every profitable arb is taken each block, to the point where
    the marginal post-fee price equals S. Part 5 relaxes exactly this.
 A4 Retail flow is uninformed and does not move S.
 A5 Retail's cost of waiting is LINEAR in the interim move: lam * sb * sqrt(E[T]).
    The mean-variance alternative, (gam/2)*sb^2*E[T], is also computed and is shown in
    Part 2b to be numerically negligible at block scale - which is itself a finding.
 A6 Deferred orders are IRREVOCABLE, carry NO minOut, and fill at the pool price at
    maturity. The minOut/refund variant is priced separately in Part 4.
 A7 Maturity T ~ Uniform{1..N}, drawn at placement, unknown to the placer.
 A8 12s blocks. Annualised vols converted at sqrt(365*24*3600/12) blocks/year.
"""
import math, random

BPS = 1e-4
SEC_PER_BLOCK = 12.0
BLOCKS_PER_YEAR = 365 * 24 * 3600 / SEC_PER_BLOCK
def sb(annual): return annual / math.sqrt(BLOCKS_PER_YEAR)

VOLS = [("calm      ~40% ann", 0.40), ("normal    ~60% ann", 0.60),
        ("stressed ~120% ann", 1.20), ("longtail ~300% ann", 3.00)]
FEES = [0.0001, 0.0005, 0.0030]

# ---------------------------------------------------------------- arb primitive
def arb_step(x, y, S, f):
    """Competitive arb against a v2 pool, fee f on input. Returns (x',y',profit,notional)."""
    k = x * y
    y_eff = math.sqrt(S * (1.0 - f) * k)
    if y_eff > y:                                   # pool underprices x: arb pays y, gets x
        dy = (y_eff - y) / (1.0 - f)
        x_new = k / y_eff
        dx = x - x_new
        p = dx * S - dy
        return (x_new, y + dy, p, dy) if p > 0 else (x, y, 0.0, 0.0)
    x_eff = math.sqrt((1.0 - f) * k / S)
    if x_eff > x:                                   # pool overprices x: arb pays x, gets y
        dx = (x_eff - x) / (1.0 - f)
        y_new = k / x_eff
        dy = y - y_new
        p = dy - dx * S
        return (x + dx, y_new, p, dy) if p > 0 else (x, y, 0.0, 0.0)
    return x, y, 0.0, 0.0

def run_paths(sigma_b, f, paths=40, blocks=8000, V0=2_000_000.0, arb_prob=1.0, rng=None):
    """Average over independent GBM paths so LVR (a drift term) is not swamped by path noise."""
    rng = rng or random.Random(20260826)
    tot = dict(profit=0.0, notl=0.0, trades=0, lvr=0.0, stale=0.0, n=0)
    for _ in range(paths):
        x = V0 / 2.0; y = V0 / 2.0; S = 1.0; x0, y0 = x, y
        prof = notl = 0.0; tr = 0; stale = 0.0
        for _ in range(blocks):
            S *= math.exp(rng.gauss(-0.5 * sigma_b**2, sigma_b))
            if arb_prob >= 1.0 or rng.random() < arb_prob:
                x, y, p, n = arb_step(x, y, S, f)
                if n > 0: prof += p; notl += n; tr += 1
            stale += abs(math.log((y / x) / S))       # |log| price divergence, the staleness cost
        tot['profit'] += prof; tot['notl'] += notl; tot['trades'] += tr
        tot['lvr'] += (x0 * S + y0) - (x * S + y)     # HODL - pool
        tot['stale'] += stale / blocks
        tot['n'] += 1
    n = tot['n']; B = blocks
    return dict(edge=(tot['profit'] / tot['notl'] if tot['notl'] else 0.0),
                arb_profit_blk=tot['profit'] / (n * B),
                notional_blk=tot['notl'] / (n * B),
                fee_rev_blk=tot['notl'] * f / (n * B),
                trade_rate=tot['trades'] / (n * B),
                lvr_blk=tot['lvr'] / (n * B),
                stale_bps=tot['stale'] / n / BPS)

# ================================================================= PART 1
print("=" * 100)
print("PART 1 - the arbitrageur's edge, and the LVR it extracts.")
print("  SANITY GATE: at fee=0 the arb's profit per block must equal the textbook LVR rate")
print("  sigma_b^2 * V / 8. If this line does not match, nothing below is trustworthy.")
print("=" * 100)
for name, ann in VOLS:
    s = sb(ann)
    z = run_paths(s, 0.0)
    theory = s**2 * 2_000_000 / 8
    err = abs(z['arb_profit_blk'] - theory) / theory
    print(f"  {name}: sigma_b={s/BPS:6.2f}bps  theory=${theory:8.4f}/blk  "
          f"simulated=${z['arb_profit_blk']:8.4f}/blk  err={err*100:5.1f}%  "
          f"{'PASS' if err < 0.06 else 'FAIL'}")
print()
print(f"{'regime':20s}{'sb':>8s}{'fee':>7s}{'edge':>9s}{'edge/sb':>9s}{'trades/blk':>12s}"
      f"{'LVR/blk':>10s}{'feerev/blk':>12s}{'staleness':>11s}")
for name, ann in VOLS:
    s = sb(ann)
    for f in FEES:
        r = run_paths(s, f)
        print(f"{name:20s}{s/BPS:7.2f}b{f*1e4:6.0f}b{r['edge']/BPS:8.2f}b"
              f"{r['edge']/s:9.3f}{r['trade_rate']:12.3f}"
              f"{r['lvr_blk']:10.3f}{r['fee_rev_blk']:12.3f}{r['stale_bps']:10.2f}b")

# ================================================================= PART 2
print()
print("=" * 100)
print("PART 2 - THE SEPARATING BAND.  Need   retail's cost of waiting  <  premium  <  arb edge.")
print("=" * 100)
EDGE = {}
for name, ann in VOLS:
    EDGE[name] = run_paths(sb(ann), 0.0005)['edge']
K = sum(EDGE[n] / sb(a) for n, a in VOLS) / len(VOLS)
print(f"  Fitted: arb edge = {K:.3f} * sigma_block, essentially independent of the LP fee.")
print(f"  Retail cost      = lam * sigma_block * sqrt(E[T]),  E[T] = (N+1)/2.")
print(f"  => sigma CANCELS. Separation exists iff  lam*sqrt((N+1)/2) < {K:.3f},")
print(f"     i.e.  N_max = 2*({K:.3f}/lam)^2 - 1.   THE BOUNDARY IS RISK AVERSION, NOT VOLATILITY.")
print()
for lam in (0.05, 0.10, 0.15, 0.25, 0.35, 0.50):
    nmax = 2 * (K / lam) ** 2 - 1
    verdict = "comfortable" if nmax >= 20 else ("tight" if nmax >= 5 else "DEAD")
    print(f"    lam={lam:.2f} -> N_max = {nmax:8.1f} blocks  ({nmax*SEC_PER_BLOCK:8.1f}s on 12s blocks,"
          f" {nmax*0.2:7.1f}s on Unichain 200ms)   {verdict}")

print()
print("  PART 2b - mean-variance alternative, for completeness:")
for name, ann in VOLS:
    s = sb(ann); hi = EDGE[name]
    for gam in (1, 5, 50):
        nmax = 2 * hi / (gam * s**2)
        print(f"    {name} gam={gam:3d}: N_max = {nmax:14,.0f} blocks  "
              f"-> variance aversion is second-order in sigma at block scale and never binds")
    break

# ================================================================= PART 3
print()
print("=" * 100)
print("PART 3 - is an IRREVOCABLE, no-minOut deferred order an OPTION or a FORWARD?")
print("=" * 100)
rng = random.Random(7)
for name, ann in VOLS:
    s = sb(ann)
    for N in (10, 50, 300):
        tot = sq = 0.0; TR = 400_000
        for _ in range(TR):
            T = rng.randint(1, N)
            P = math.exp(rng.gauss(-0.5 * s**2 * T, s * math.sqrt(T)))
            tot += P; sq += P * P
        m = tot / TR; sd = math.sqrt(max(sq / TR - m * m, 0.0))
        print(f"  {name} N={N:4d}  E[P_T]-P_0 = {(m-1)/BPS:+8.4f} bps   sd = {sd/BPS:8.2f} bps")
print("  => payoff is LINEAR in P_T. Zero expected gain, zero gamma. It is a forward with")
print("     random delivery, NOT an option. A delta-neutral placer harvests nothing.")

# ================================================================= PART 4
print()
print("=" * 100)
print("PART 4 - value of a FREE minOut refund. THIS is the actual option.")
print("  Value above an unconditional fill = E[(K - P_T)+], a free PUT struck at the tolerance.")
print("  The ONLY thing that matters is z = tol / (sigma_b * sqrt(E[T])) - how many standard")
print("  deviations out of the money the refund trigger sits. Value below is in units of the")
print("  interim move sigma_b*sqrt(E[T]), so one table covers every vol regime.")
print("=" * 100)
rng = random.Random(11)
def _phi(t): return math.exp(-0.5*t*t)/math.sqrt(2*math.pi)
def _Phi(t): return 0.5*(1.0+math.erf(t/math.sqrt(2.0)))
print(f"{'z (tol in sd)':>14s}{'put/sd MC':>11s}{'closed form':>12s}{'@N=10':>9s}"
      f"{'@N=50':>9s}{'refund rate':>13s}   verdict")
for z in (0.0, 0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0):
    tot = 0.0; hits = 0; TR = 400_000
    for _ in range(TR):
        u = rng.gauss(0.0, 1.0)
        # P = 1 + sd*u ; K = 1 - z*sd ; (K-P)/sd = -z - u.  Closed form: phi(z) - z*Phi(-z).
        v = -z - u
        if v > 0: tot += v; hits += 1
    put_over_sd = tot / TR
    # arb edge = 0.581*sb ; sd = sb*sqrt(E[T]) ; ratio = put_over_sd*sqrt(E[T])/0.581
    r10 = put_over_sd * math.sqrt(5.5) / K
    r50 = put_over_sd * math.sqrt(25.5) / K
    verd = "FATAL - free option dwarfs the premium" if r10 > 1.0 else \
           ("DANGEROUS" if r10 > 0.25 else "safe - refund is deep OTM")
    cf = _phi(z) - z*_Phi(-z)
    flag = "" if abs(cf-put_over_sd) < 0.005 else "  <-- MC/closed-form MISMATCH"
    print(f"{z:14.2f}{put_over_sd:11.4f}{cf:12.4f}{r10:8.2f}x{r50:8.2f}x"
          f"{hits/TR*100:12.1f}%   {verd}{flag}")
print()
print("  => DESIGN RULE, and it is enforceable on-chain because the hook already measures")
print("     sigma_b for the premium: REJECT any deferred order whose minOut sits closer than")
print("     ~2 sd of the interim move. At z>=2 the free put is worth <7% of the arb edge and")
print("     the refund fires <3% of the time. At z=0 (fill-only-if-improved) it is worth more")
print("     than the entire arb edge and HASTE is a straddle written by the LPs.")

# ================================================================= PART 4b
print()
print("=" * 100)
print("PART 4b - does the premium actually help LPs, or does it just buy price staleness?")
print("  LP net vs ARB FLOW ONLY = fee+premium revenue - LVR. Retail revenue is excluded")
print("  because retail's response to the premium is the thing under test elsewhere.")
print("=" * 100)
print(f"{'regime':20s}{'total friction':>15s}{'arb rev/blk':>13s}{'LVR/blk':>10s}"
      f"{'LP net/blk':>12s}{'staleness':>11s}")
for name, ann in [VOLS[1], VOLS[2]]:
    s = sb(ann)
    for f in (0.0005, 0.0010, 0.0020, 0.0050, 0.0100):
        r = run_paths(s, f)
        net = r['fee_rev_blk'] - r['lvr_blk']
        print(f"{name:20s}{f*1e4:14.0f}b{r['fee_rev_blk']:13.4f}{r['lvr_blk']:10.4f}"
              f"{net:12.4f}{r['stale_bps']:10.2f}b")
print("  => staleness tracks the friction almost 1:1. The premium is NOT paid out of the")
print("     arb's per-notional edge (which is fee-invariant, Part 1); it is paid by widening")
print("     the no-arb band. LPs still gain, because LVR falls faster than arb revenue, but")
print("     the immediate lane's true cost to an urgent trader is premium + staleness ~ 2x premium.")

# ================================================================= PART 5
print()
print("=" * 100)
print("PART 5 - A3 RELAXED. If arbitrage is NOT competitive (one bot, no race), is the arb")
print("         still forced to pay for immediacy, or can it defer for free?")
print("=" * 100)
print(f"{'regime':20s}{'arb_prob':>10s}{'edge':>9s}{'staleness':>11s}{'note':>44s}")
for name, ann in [VOLS[1], VOLS[3]]:
    s = sb(ann)
    for p in (1.0, 0.5, 0.2, 0.05):
        r = run_paths(s, 0.0005, arb_prob=p)
        note = "competitive: edge decays, must pay to be first" if p == 1.0 else \
               ("edge survives waiting -> deferral is free" if p <= 0.2 else "marginal")
        print(f"{name:20s}{p:10.2f}{r['edge']/BPS:8.2f}b{r['stale_bps']:10.2f}b{note:>44s}")
