#!/usr/bin/env python3
"""
SWITCHBACK reflexivity test.  2026-08-26.  Seeded, reproducible.
Run: python3 docs/research/data/switchback_reflexivity.py

THE QUESTION
------------
SWITCHBACK charges any swap that walks the pool tick BACK toward the block-open tick T0,
in proportion to the ticks retraced, capped by how far price was extended this block.
OpenZeppelin's AntiSandwichHook warns that deterring round trips makes the block-open
price stale.  Does SWITCHBACK's fee still separate extraction from honest flow when T0
is stale?

STRUCTURAL FACT ESTABLISHED BEFORE ANY SIMULATION (and the sim exists to falsify it):
staleness does not enter the fee formula.  The fee is a pure function of the intra-block
tick path relative to T0.  Staleness can only hurt through the FLOW it induces:
  H1 BUDGET INFLATION - a stale T0 means a top-of-block corrective arb extends the price
     d ticks away from T0 for FREE (extension is untaxed).  That extension authorises up
     to d ticks of taxable retracement on everything that follows in the opposite
     direction.  Honest ONE-WAY flow, not just two-sided flow, is exposed.
  H2 CORRECTOR DETERRENCE - the arb that corrects retail's price impact is, on-chain,
     indistinguishable from a sandwich back-run: both walk price toward T0.  Taxing it
     leaves the pool off-market at block close, which is next block's staleness.

ASSUMPTIONS - all load-bearing, all stated.
 A1 External market S is driftless GBM; per-block log return ~ N(-sb^2/2, sb^2), split
    into two intra-block jumps of sb/sqrt(2) so that intra-block reversals can occur.
 A2 Pool is constant-product with proportional fee f on the input.  Concentrated
    liquidity changes the depth constant, not the shape.  (Same assumption as
    haste_economics.py A2; inherited, not re-validated.)
 A3 Arbitrage is competitive and profit-maximising: the arb solves for the trade size
    that maximises profit AFTER both the LP fee and the SWITCHBACK fee.  A partially
    corrected pool is therefore an endogenous output, not an input.
 A4 Retail flow is uninformed, 50/50 directional, lognormal size, does not move S.
 A5 SWITCHBACK fee = gamma * (chargeable retraced ticks), in bps of the swap's y-side
    notional, capped at cap_bps.  1 tick = 1.0001x = ~1 bps.  gamma=1 means the trader
    surrenders the whole price improvement the retracement gave them.
 A6 The fee is ESCROWED, not added to reserves, so it does not itself move the price.
 A7 Chargeable retracement is budgeted per side: extension away from T0 on the up side
    credits Bup, movement back toward T0 on the up side debits it.  This is the
    "capped by how far price was extended" rule of IDEAS_MECHANISM 2.4c, implemented
    as a path integral with no per-swap threshold (2.4b).
 A8 A sandwich is front-run + victim + back-run inside ONE block.  Cross-block unwinds
    (2.4a) are known-uncatchable and are NOT simulated - they escape 100% by
    construction and that is already the stated headline limit.
 A9 12s blocks.  Annualised vols converted at sqrt(365*24*3600/12) blocks/year.
"""
import math, random

BPS = 1e-4
SEC_PER_BLOCK = 12.0
BLOCKS_PER_YEAR = 365 * 24 * 3600 / SEC_PER_BLOCK
LN_TICK = math.log(1.0001)
def sb(annual): return annual / math.sqrt(BLOCKS_PER_YEAR)
def sb_at(annual, spb): return annual / math.sqrt(365 * 24 * 3600 / spb)

VOLS = [("calm      ~40% ann", 0.40), ("normal    ~60% ann", 0.60),
        ("stressed ~120% ann", 1.20), ("longtail ~300% ann", 3.00)]

# ============================================================ SANITY GATE (inherited)
# Verbatim port of haste_economics.py's arb primitive + LVR gate.  If this stops
# reproducing sigma^2*V/8 the whole file is untrustworthy.  DO NOT DELETE.
def arb_step(x, y, S, f):
    k = x * y
    y_eff = math.sqrt(S * (1.0 - f) * k)
    if y_eff > y:
        dy = (y_eff - y) / (1.0 - f); x_new = k / y_eff; dx = x - x_new
        p = dx * S - dy
        return (x_new, y + dy, p, dy) if p > 0 else (x, y, 0.0, 0.0)
    x_eff = math.sqrt((1.0 - f) * k / S)
    if x_eff > x:
        dx = (x_eff - x) / (1.0 - f); y_new = k / x_eff; dy = y - y_new
        p = dy - dx * S
        return (x + dx, y_new, p, dy) if p > 0 else (x, y, 0.0, 0.0)
    return x, y, 0.0, 0.0

def lvr_gate(V0=2_000_000.0, paths=40, blocks=8000):
    ok = True
    rng = random.Random(20260826)
    print("=" * 100)
    print("PART 0 - SANITY GATE (inherited from haste_economics.py).  At fee=0 the competitive")
    print("  arb's profit per block must equal the textbook LVR rate sigma_b^2 * V / 8.")
    print("=" * 100)
    for name, ann in VOLS:
        s = sb(ann); tot = 0.0
        for _ in range(paths):
            x = V0 / 2; y = V0 / 2; S = 1.0; prof = 0.0
            for _ in range(blocks):
                S *= math.exp(rng.gauss(-0.5 * s * s, s))
                x, y, p, n = arb_step(x, y, S, 0.0)
                prof += p
            tot += prof
        sim = tot / (paths * blocks); theory = s * s * V0 / 8
        err = abs(sim - theory) / theory
        good = err < 0.06; ok &= good
        print(f"  {name}: theory=${theory:8.4f}/blk  simulated=${sim:8.4f}/blk  "
              f"err={err*100:5.1f}%  {'PASS' if good else 'FAIL'}")
    return ok

# ============================================================ POOL + SWITCHBACK METER
class Pool:
    __slots__ = ("x", "y", "f")
    def __init__(self, V0, f): self.x = V0 / 2.0; self.y = V0 / 2.0; self.f = f
    def k(self): return self.x * self.y
    def price(self): return self.y / self.x
    def tick(self): return math.log(self.y / self.x) / LN_TICK
    def copy(self):
        p = Pool.__new__(Pool); p.x = self.x; p.y = self.y; p.f = self.f; return p
    def swap_y_in(self, dy):          # pay dy of y, receive x.  price RISES.
        k = self.k(); xn = k / (self.y + dy * (1 - self.f))
        out = self.x - xn; self.x = xn; self.y += dy; return out
    def swap_x_in(self, dx):          # pay dx of x, receive y.  price FALLS.
        k = self.k(); yn = k / (self.x + dx * (1 - self.f))
        out = self.y - yn; self.x += dx; self.y = yn; return out

class Meter:
    """SWITCHBACK's state: T0, and the per-side unspent extension budget.

    The budget is a LIFO stack of (ticks, origin) so that a retracement can be
    ATTRIBUTED to whatever created the extension it is consuming.  LIFO is the
    physically correct order: a price walking back down consumes the most recent
    leg up first.  Origins: 'arb' (the corrective arbitrage the stale reference
    forces), 'hon' (ordinary retail), 'atk' (a sandwicher's own front-run).
    """
    __slots__ = ("T0", "up", "dn", "db_up", "db_dn", "uncapped")
    def __init__(self, T0, deadband=0.0, uncapped=False):
        self.T0 = T0; self.up = []; self.dn = []
        self.db_up = deadband; self.db_dn = deadband
        # mutation modes: '' = shipped rule, 'blind' = charge every tick moved regardless
        # of direction, 'identity' = closed form charged = max(0, |c0-T0| - |c1-T0|)
        self.uncapped = uncapped
    def copy(self):
        m = Meter.__new__(Meter)
        m.T0 = self.T0; m.up = [list(e) for e in self.up]; m.dn = [list(e) for e in self.dn]
        m.db_up = self.db_up; m.db_dn = self.db_dn; m.uncapped = self.uncapped
        return m
    def account(self, c0, c1, origin, commit=True):
        """Return (charged_ticks, {origin: ticks}) for a move c0->c1."""
        m = self if commit else self.copy()
        T0 = m.T0
        if m.uncapped == 'blind':                       # M2: direction-blind
            return abs(c1 - c0), {'hon': abs(c1 - c0)}
        if m.uncapped == 'identity':                    # M2': closed form, no watermarks
            d0 = c0 - T0; d1 = c1 - T0
            ch = max(0.0, abs(d0) - abs(d1)) if d0 * d1 >= 0 else abs(d0)
            return ch, ({'hon': ch} if ch > 0 else {})
        segs = [(c0, T0), (T0, c1)] if (c0 - T0) * (c1 - T0) < 0 else [(c0, c1)]
        charged = 0.0; attrib = {}
        for a, b in segs:
            if a == b: continue
            up = max(a - T0, b - T0) > 0
            stack = m.up if up else m.dn
            extending = (b > a) if up else (b < a)
            amt = abs(b - a)
            if extending:
                if up:
                    eat = min(amt, m.db_up); m.db_up -= eat
                else:
                    eat = min(amt, m.db_dn); m.db_dn -= eat
                if amt - eat > 0: stack.append([amt - eat, origin])
            else:
                need = amt
                while need > 1e-15 and stack:
                    e = stack[-1]
                    take = min(need, e[0])
                    e[0] -= take; need -= take; charged += take
                    attrib[e[1]] = attrib.get(e[1], 0.0) + take
                    if e[0] <= 1e-15: stack.pop()
        return charged, attrib

def do_swap(pool, meter, side, amt, gamma, cap_bps, origin="hon", commit=True):
    """side 'yin' (buy x, price up) or 'xin' (sell x, price down).
       Returns (out, fee_in_y, charged_ticks, attribution).  Fee is escrowed (A6)."""
    p = pool if commit else pool.copy()
    c0 = p.tick()
    out = p.swap_y_in(amt) if side == "yin" else p.swap_x_in(amt)
    c1 = p.tick()
    ch, attrib = meter.account(c0, c1, origin, commit=commit)
    fee_bps_raw = gamma * ch
    fee_bps = min(fee_bps_raw, cap_bps)
    scale = (fee_bps / fee_bps_raw) if fee_bps_raw > 0 else 0.0
    attrib = {k: v * scale for k, v in attrib.items()}
    notional_y = amt if side == "yin" else out
    return out, fee_bps * BPS * notional_y, ch, attrib

# ============================================================ ACTORS
def best_arb(pool, meter, S, gamma, cap_bps, grid=28):
    """Profit-maximising arb AFTER the LP fee and the SWITCHBACK fee (A3).
       Returns (side, amt, profit) or None."""
    P = pool.price()
    if abs(math.log(P / S)) < 1e-12: return None
    k = pool.k(); f = pool.f
    if P < S:
        y_eff = math.sqrt(S * (1 - f) * k)
        hi = max((y_eff - pool.y) / (1 - f), 0.0); side = "yin"
    else:
        x_eff = math.sqrt((1 - f) * k / S)
        hi = max((x_eff - pool.x) / (1 - f), 0.0); side = "xin"
    if hi <= 0: return None
    best = (None, 0.0, 0.0)
    for i in range(1, grid + 1):
        amt = hi * i / grid
        out, fee, _, _ = do_swap(pool, meter, side, amt, gamma, cap_bps, "arb", commit=False)
        prof = (out * S - amt - fee) if side == "yin" else (out - amt * S - fee)
        if prof > best[2]: best = (side, amt, prof)
    return None if best[0] is None else best

def best_sandwich(pool, meter, victim_side, victim_amt, gamma, cap_bps, grid=18):
    """Front-run + victim + back-run, all inside one block (A8).
       Returns (profit, front_amt)."""
    best = (-1e18, 0.0)
    for i in range(1, grid + 1):
        a = victim_amt * (i * 0.5)
        p = pool.copy(); m = meter.copy(); fees = 0.0
        if victim_side == "yin":
            got_x, fe, _, _ = do_swap(p, m, "yin", a, gamma, cap_bps, "atk"); fees += fe
            do_swap(p, m, "yin", victim_amt, gamma, cap_bps, "hon")
            back_y, fe2, _, _ = do_swap(p, m, "xin", got_x, gamma, cap_bps, "atk"); fees += fe2
            prof = back_y - a - fees
        else:
            got_y, fe, _, _ = do_swap(p, m, "xin", a, gamma, cap_bps, "atk"); fees += fe
            do_swap(p, m, "xin", victim_amt, gamma, cap_bps, "hon")
            back_x, fe2, _, _ = do_swap(p, m, "yin", got_y, gamma, cap_bps, "atk"); fees += fe2
            prof = (back_x - a) * p.price() - fees
        if prof > best[0]: best = (prof, a)
    return best

def best_sandwich_xb(pool, meter, T0, victim_side, victim_amt, gamma, cap_bps,
                     alpha, boundary, deadband=0.0, uncapped='', grid=18, delay=1):
    """Front-run + victim in block N, unwind at the TOP of block N+1 under the live reference
       policy.  The front-run size is optimised FOR THIS ROUTE - an attacker planning a
       cross-block unwind does not use the in-block optimum.  Returns (profit, front_amt)."""
    best = (-1e18, 0.0)
    bs = "xin" if victim_side == "yin" else "yin"
    for i in range(1, grid + 1):
        a = victim_amt * (i * 0.5)
        p = pool.copy(); m = meter.copy(); fees = 0.0
        got, fe, _, _ = do_swap(p, m, victim_side, a, gamma, cap_bps, "atk"); fees += fe
        do_swap(p, m, victim_side, victim_amt, gamma, cap_bps, "hon")
        tclose = p.tick()
        if boundary:
            T0n = tclose
        else:
            T0n = T0
            for _ in range(delay):        # the reference keeps decaying while the attacker waits
                T0n = T0n + alpha * (tclose - T0n)
        mN = Meter(T0n, deadband, uncapped)
        d = tclose - T0n
        if d > 1e-15:   mN.up.append([d, 'carry'])
        elif d < -1e-15: mN.dn.append([-d, 'carry'])
        back, fe2, _, _ = do_swap(p, mN, bs, got, gamma, cap_bps, "atk"); fees += fe2
        prof = (back - a - fees) if victim_side == "yin" else ((back - a) * p.price() - fees)
        if prof > best[0]: best = (prof, a)
    return best

# ============================================================ THE SIMULATION
def simulate(ann_vol, gamma, cap_bps=1e9, deadband=0.0, f=0.0005, V0=40_000_000.0,
             blocks=4000, retail_per_block=3.0, retail_med=5_000.0, retail_sd=1.0,
             sandwich_prob=0.35, arb_on=True, arb_suppress=0.0, market_moves=True,
             seed=20260826, two_sided_only=False, one_way_only=False,
             oracle_reference=False, uncapped='', alpha=1.0, reset_every=1,
             mu_ticks=0.0, spb=12.0):
    rng = random.Random(seed)
    s = sb_at(ann_vol, spb) if market_moves else 0.0
    pool = Pool(V0, f); S = pool.price()
    st = dict(hon_n=0, hon_chg_n=0, hon_bps_sum=0.0, hon_notional=0.0, hon_fee_y=0.0,
              hon_from_arb=0.0, hon_from_hon=0.0, hon_from_atk=0.0,
              arb_opp=0, arb_deterred=0, arb_partial=0.0,
              sw_att=0, sw_n=0, sw_escape=0, sw_gross=0.0, sw_netpos=0.0,
              stale_open=0.0, stale_close=0.0, feerev=0.0, swb_rev=0.0, hist=[],
              hon_from_carry=0.0, ref_lag=0.0, sw_xb_ok=0, sw_xb_prof=0.0, sw_xb_fee=0.0)
    x0, y0 = pool.x, pool.y

    def run_arb(meter):
        """Execute the profit-maximising arb; also measure what it WOULD have done with
           no SWITCHBACK fee, so 'deterred' means deterred BY US, not 'no opportunity'."""
        shadow = best_arb(pool, meter, S, 0.0, 1e9)
        if shadow is None:
            return
        st['arb_opp'] += 1
        r = best_arb(pool, meter, S, gamma, cap_bps)
        if r is None:
            st['arb_deterred'] += 1; st['arb_partial'] += 1.0; return
        side, amt, prof = r
        st['arb_partial'] += max(0.0, 1.0 - amt / shadow[1]) if shadow[1] > 0 else 0.0
        out, fee, _, _ = do_swap(pool, meter, side, amt, gamma, cap_bps, "arb")
        st['swb_rev'] += fee
        st['feerev'] += (amt if side == "yin" else out) * f

    def book_honest(amt_y, fee, attrib):
        st['hon_n'] += 1; st['hon_notional'] += amt_y; st['hon_fee_y'] += fee
        b = fee / (amt_y * BPS) if amt_y else 0.0
        st['hon_bps_sum'] += b
        if b > 0.1: st['hon_chg_n'] += 1
        tot = sum(attrib.values())
        if tot > 0:
            for k_, v in attrib.items():
                st['hon_from_' + k_] = st.get('hon_from_' + k_, 0.0) + b * v / tot

    T0_prev = None
    for _blk in range(blocks):
        # ---- REFERENCE POLICY.  alpha=1 and reset_every=1 is the shipped behaviour and MUST
        #      reproduce the pre-existing numbers exactly (negative control).
        if T0_prev is None:
            T0 = pool.tick()
        elif reset_every > 1:
            T0 = pool.tick() if (_blk % reset_every == 0) else T0_prev
        else:
            T0 = T0_prev + alpha * (pool.tick() - T0_prev)
        st['ref_lag'] += abs(pool.tick() - T0)
        st['stale_open'] += abs(pool.tick() - math.log(S) / LN_TICK)
        if oracle_reference:
            # DIAGNOSTIC ONLY - not implementable on-chain.  Replaces the block-open tick
            # with the true market tick, i.e. a reference that is fresh by construction.
            T0 = math.log(S) / LN_TICK
        meter = Meter(T0, deadband, uncapped)
        # Seed the budget with the displacement already standing at block open, so that the
        # M2' identity (budget == |tick - T0|) still holds under a carried reference.
        # At alpha=1 this seed is exactly 0, hence the control is exact.
        _d = pool.tick() - T0
        if _d > 1e-15:   meter.up.append([_d, 'carry'])
        elif _d < -1e-15: meter.dn.append([-_d, 'carry'])
        if market_moves: S *= math.exp(0.5*mu_ticks*LN_TICK + rng.gauss(-0.25*s*s, s/math.sqrt(2)))
        if arb_on and rng.random() >= arb_suppress: run_arb(meter)

        n_ret = 0; u = rng.random(); cum = math.exp(-retail_per_block); pk = cum
        while u > cum and n_ret < 30:
            n_ret += 1; pk *= retail_per_block / n_ret; cum += pk
        victim_idx = rng.randrange(n_ret) if (n_ret and rng.random() < sandwich_prob) else -1

        for i in range(n_ret):
            amt_y = retail_med * math.exp(rng.gauss(0, retail_sd))
            if one_way_only:   side = "yin"
            elif two_sided_only: side = "yin" if (i % 2 == 0) else "xin"
            else:              side = "yin" if rng.random() < 0.5 else "xin"
            amt = amt_y if side == "yin" else amt_y / pool.price()

            if i == victim_idx:
                gross, _ = best_sandwich(pool, meter, side, amt, 0.0, 1e9)
                st['sw_att'] += 1
                if gross <= 0:
                    victim_idx = -1
                else:
                    st['sw_n'] += 1; st['sw_gross'] += gross
                    prof, front = best_sandwich(pool, meter, side, amt, gamma, cap_bps)
                    # --- counterfactual: unwind at the TOP of the next block, under the live
                    #     reference policy, with the front-run sized FOR that route.
                    pr_xb, _fxb = best_sandwich_xb(
                        pool, meter, T0, side, amt, gamma, cap_bps, alpha,
                        boundary=(reset_every > 1), deadband=deadband, uncapped=uncapped)
                    if pr_xb > 0: st['sw_xb_ok'] += 1; st['sw_xb_prof'] += pr_xb
                    if prof > 0:
                        st['sw_escape'] += 1; st['sw_netpos'] += prof
                        fs = "yin" if side == "yin" else "xin"
                        got, fe, _, _ = do_swap(pool, meter, fs, front, gamma, cap_bps, "atk")
                        st['swb_rev'] += fe
                        out, fe_v, _, at_v = do_swap(pool, meter, side, amt, gamma, cap_bps, "hon")
                        st['swb_rev'] += fe_v; book_honest(amt_y, fe_v, at_v)
                        bs = "xin" if side == "yin" else "yin"
                        _, fe2, _, _ = do_swap(pool, meter, bs, got, gamma, cap_bps, "atk")
                        st['swb_rev'] += fe2
                        st['feerev'] += 3 * amt_y * f
                        continue
                    # deterred: attacker stands down, victim trades unmolested
            out, fee, ch, at = do_swap(pool, meter, side, amt, gamma, cap_bps, "hon")
            st['swb_rev'] += fee; st['feerev'] += amt_y * f
            book_honest(amt_y, fee, at)

        if market_moves: S *= math.exp(0.5*mu_ticks*LN_TICK + rng.gauss(-0.25*s*s, s/math.sqrt(2)))
        if arb_on and rng.random() >= arb_suppress: run_arb(meter)
        T0_prev = T0
        d = abs(pool.tick() - math.log(S) / LN_TICK)
        st['stale_close'] += d; st['hist'].append(d)

    lvr = (x0 * S + y0) - (pool.x * S + pool.y)
    n = max(st['hon_n'], 1); dec = max(blocks // 10, 1)
    return dict(
        stale_open=st['stale_open'] / blocks, stale_close=st['stale_close'] / blocks,
        hon_charged_pct=100.0 * st['hon_chg_n'] / n,
        hon_mean_bps=st['hon_bps_sum'] / n,
        hon_vw_bps=(st['hon_fee_y'] / st['hon_notional'] / BPS) if st['hon_notional'] else 0.0,
        hon_from_arb=st['hon_from_arb'] / n, hon_from_hon=st['hon_from_hon'] / n,
        hon_from_atk=st['hon_from_atk'] / n,
        arb_caused_pct=(100.0 * st['hon_from_arb'] /
                        max(st['hon_from_arb'] + st['hon_from_hon'] + st['hon_from_atk']
                            + st['hon_from_carry'], 1e-12)),
        carry_caused_pct=(100.0 * st['hon_from_carry'] /
                          max(st['hon_from_arb'] + st['hon_from_hon'] + st['hon_from_atk']
                              + st['hon_from_carry'], 1e-12)),
        ref_lag=st['ref_lag'] / blocks,
        xb_escape_pct=(100.0 * st['sw_xb_ok'] / st['sw_n']) if st['sw_n'] else float('nan'),
        xb_keep_pct=(100.0 * st['sw_xb_prof'] / st['sw_gross']) if st['sw_gross'] > 0 else 0.0,
        xb_fee_blk=st['sw_xb_fee'] / blocks,
        sw_escape_pct=(100.0 * st['sw_escape'] / st['sw_n']) if st['sw_n'] else float('nan'),
        sw_profit_kept=(100.0 * st['sw_netpos'] / st['sw_gross']) if st['sw_gross'] > 0 else 0.0,
        sw_n=st['sw_n'], sw_att=st['sw_att'],
        attackable_pct=(100.0 * st['sw_n'] / st['sw_att']) if st['sw_att'] else 0.0,
        arb_deterred_pct=(100.0 * st['arb_deterred'] / st['arb_opp']) if st['arb_opp'] else 0.0,
        arb_shortfall_pct=(100.0 * st['arb_partial'] / st['arb_opp']) if st['arb_opp'] else 0.0,
        swb_rev_blk=st['swb_rev'] / blocks, lvr_blk=lvr / blocks,
        feerev_blk=st['feerev'] / blocks,
        stale_first=sum(st['hist'][:dec]) / dec, stale_last=sum(st['hist'][-dec:]) / dec,
        hon_n=st['hon_n'],
    )

# ============================================================ DRIVER
COLS = (f"{'scenario':32s}{'staleT0':>9s}{'hon chg':>9s}{'hon bps':>9s}"
        f"{'arb-cau':>9s}{'sw esc':>8s}{'sw keep':>9s}"
        f"{'arb kill':>9s}{'arb short':>10s}{'fee$/blk':>10s}")

def row(tag, r):
    print(f"{tag:32s}{r['stale_open']:8.2f}t{r['hon_charged_pct']:8.1f}%{r['hon_vw_bps']:8.2f}b"
          f"{r['arb_caused_pct']:8.1f}%{r['sw_escape_pct']:7.1f}%"
          f"{r['sw_profit_kept']:8.1f}%{r['arb_deterred_pct']:8.1f}%"
          f"{r['arb_shortfall_pct']:9.1f}%{r['swb_rev_blk']:10.2f}")

RCOLS = (f"{'policy':26s}{'ref lag':>9s}{'hon chg':>9s}{'hon bps':>9s}{'carry-c':>9s}"
         f"{'arb shrt':>10s}{'IN esc':>8s}{'IN keep':>9s}{'XB esc':>8s}{'XB keep':>9s}")

def rrow(tag, r):
    print(f"{tag:26s}{r['ref_lag']:8.2f}t{r['hon_charged_pct']:8.1f}%{r['hon_vw_bps']:8.2f}b"
          f"{r['carry_caused_pct']:8.1f}%{r['arb_shortfall_pct']:9.1f}%"
          f"{r['sw_escape_pct']:7.1f}%{r['sw_profit_kept']:8.1f}%"
          f"{r['xb_escape_pct']:7.1f}%{r['xb_keep_pct']:8.1f}%")

def hdr(t):
    print(); print("=" * 118); print(t); print("=" * 118)

if __name__ == "__main__":
    if not lvr_gate():
        print("\n*** SANITY GATE FAILED - nothing below is trustworthy. STOP. ***")
        raise SystemExit(1)

    BASE = dict(f=0.0005, V0=40_000_000.0, blocks=4000, retail_per_block=3.0,
                retail_med=5_000.0, retail_sd=1.0, sandwich_prob=0.35)
    imp = 2 * 5_000 / 20_000_000 / BPS
    print(f"\n  Flow calibration: median retail notional $5,000 in a $40M constant-product pool")
    print(f"  => median tick impact {imp:.1f} ticks.  LP fee 5 bps.  3 retail swaps/block.")
    for nm, a in VOLS:
        print(f"    {nm}: sigma_block = {sb(a)/BPS:5.2f} ticks  "
              f"(retail impact / block vol = {imp/(sb(a)/BPS):5.2f}x)")
    print("  Column key: 'hon bps' = volume-weighted SWITCHBACK bps paid by honest flow;")
    print("  'arb-cau' = share of that fee whose retracement consumed extension created by the")
    print("  corrective ARB rather than by other flow (LIFO attribution).  This is the H1 channel.")
    print("  'sw esc' = % of baseline-profitable in-block sandwiches still profitable;")
    print("  'arb kill' = % of profitable corrective arbs we deter outright; 'arb short' = mean")
    print("  fraction of the full correction left undone.")

    # ---------------------------------------------------------------- PART 1
    hdr("PART 1 - MANDATORY NEGATIVE CONTROLS.  If these misbehave the RIG is wrong, not SWITCHBACK.")
    fails = []
    B0 = {k: v for k, v in BASE.items() if k != 'sandwich_prob'}

    nc1 = simulate(0.60, 1.0, arb_on=False, market_moves=False, one_way_only=True,
                   sandwich_prob=0.0, **B0)
    ok = nc1['hon_charged_pct'] == 0.0; fails += [] if ok else ["NC1"]
    print(f"  NC1  no staleness, ONE-WAY honest flow  -> charged {nc1['hon_charged_pct']:.2f}% , "
          f"{nc1['hon_vw_bps']:.4f} bps   {'PASS (must be exactly 0)' if ok else 'FAIL'}")

    nc2 = simulate(0.60, 1.0, arb_on=False, market_moves=False, two_sided_only=True,
                   sandwich_prob=0.0, **B0)
    ok = nc2['hon_charged_pct'] > 20.0; fails += [] if ok else ["NC2 meter never fires"]
    print(f"  NC2  no staleness, ALTERNATING honest flow -> charged {nc2['hon_charged_pct']:.2f}% , "
          f"{nc2['hon_vw_bps']:.2f} bps   {'PASS (meter can fire)' if ok else 'FAIL'}")
    print(f"       This is 2.4f and it is NOT a staleness effect: intra-block two-sided honest")
    print(f"       flow pays even with a perfect reference.")

    nc3 = simulate(0.60, 0.0, **BASE)
    ok = nc3['hon_charged_pct'] == 0.0 and nc3['sw_escape_pct'] > 99.0
    fails += [] if ok else ["NC3"]
    print(f"  NC3  fee OFF (gamma=0), full flow -> charged {nc3['hon_charged_pct']:.2f}% , "
          f"sandwich escape {nc3['sw_escape_pct']:.1f}% , {nc3['attackable_pct']:.0f}% of victims "
          f"attackable   {'PASS' if ok else 'FAIL'}")

    nc4 = simulate(0.60, 0.0, market_moves=False, arb_on=True, **BASE)
    ok = nc4['stale_open'] < 6.0; fails += [] if ok else ["NC4 arb does not correct"]
    print(f"  NC4  STALENESS FLOOR: market frozen, arb ON, fee OFF -> block-open staleness "
          f"{nc4['stale_open']:.2f} ticks")
    print(f"       {'PASS (pool sits inside the no-arb band, so the rig CAN keep a fresh reference)' if ok else 'FAIL'}")

    nc5 = simulate(0.60, 1.0, market_moves=False, arb_on=True, **BASE)
    print(f"  NC5  SAME WORLD, FEE ON (gamma=1) -> staleness {nc5['stale_open']:.2f} ticks "
          f"({nc5['stale_open']/max(nc4['stale_open'],1e-9):.2f}x the floor), "
          f"arb killed {nc5['arb_deterred_pct']:.1f}% , correction shortfall "
          f"{nc5['arb_shortfall_pct']:.1f}%")
    print(f"       NOT a control - this is the OZ warning reproduced with ZERO exogenous")
    print(f"       volatility.  The staleness above the floor is caused BY SWITCHBACK.")

    if fails:
        print(f"\n*** CONTROLS FAILED: {fails}.  STOP. ***"); raise SystemExit(1)
    print("\n  ALL CONTROLS PASS.")

    # ---------------------------------------------------------------- PART 2
    hdr("PART 2 - THE CHEAP ANSWER FIRST.  Does the intra-block extension cap already bound it?\n"
        "  Staleness cannot enter the fee formula directly - the fee is a pure function of the\n"
        "  intra-block path relative to T0, and T0 IS the pool's own price at block open, so it\n"
        "  is never stale relative to the thing the fee measures.  Staleness can only act by\n"
        "  changing FLOW.  These three worlds isolate that.")
    print(COLS)
    w1 = simulate(0.60, 1.0, arb_on=False, market_moves=False, **BASE)
    w2 = simulate(0.60, 1.0, arb_on=False, market_moves=True, **BASE)
    w3 = simulate(0.60, 1.0, arb_on=True,  market_moves=True, **BASE)
    row("(a) frozen mkt, no arb", w1)
    row("(b) mkt moves, NO arb (max stale)", w2)
    w4 = simulate(0.60, 1.0, arb_on=True, market_moves=True, oracle_reference=True, **BASE)
    row("(c) mkt moves, arb ON (realistic)", w3)
    row("(d) as (c) + PERFECT reference*", w4)
    print("  * (d) replaces T0 with the true market tick.  Not implementable on-chain.  NOTE: an")
    print("    earlier draft of this row left the extension budget empty at block open while")
    print("    moving T0, so the standing displacement was not chargeable, and it reported that a")
    print("    perfect reference HELPED.  With the budget seeded consistently it does the")
    print("    opposite: anchoring to the true market taxes price discovery itself (arb shortfall")
    print("    jumps to ~68%).  The intrinsic-vs-reference split is the 'arb-cau' column and NC2,")
    print("    not this row.")
    print("  (a)->(b): pure staleness with no corrective arb.  If SWITCHBACK were reference-")
    print("            sensitive in the OZ sense, honest cost would explode here.")
    print("  (b)->(c): adds the corrective arb, whose FREE extension is hypothesis H1.")

    # ---------------------------------------------------------------- PART 3
    hdr("PART 3 - FLOW DENSITY.  How much of the false positive is the stale reference and how\n"
        "  much is just two-sided honest flow inside one block (2.4f)?  gamma=1, normal vol.")
    print(COLS)
    for lam in (0.3, 1.0, 2.0, 3.0, 6.0):
        r = simulate(0.60, 1.0, **{**BASE, 'retail_per_block': lam})
        row(f"{lam:.1f} retail swaps/block", r)

    # ---------------------------------------------------------------- PART 4
    hdr("PART 4 - THE CONFUSION MATRIX.  Volatility regime x fee slope gamma.")
    print(COLS)
    for nm, ann in VOLS:
        for g in (0.25, 0.5, 1.0, 2.0):
            row(f"{nm} g={g:.2f}", simulate(ann, g, **BASE))

    # ---------------------------------------------------------------- PART 5
    hdr("PART 5 - EXOGENOUS STALENESS STRESS.  Suppress a fraction of ALL corrective arbs\n"
        "  (thin pool / single searcher / any other cause) and re-measure.  gamma=1.")
    print(COLS)
    for ann, nm in ((0.60, "normal"), (1.20, "stressed")):
        for sup in (0.0, 0.50, 0.80, 0.95):
            row(f"{nm}, {sup*100:.0f}% of arbs suppressed",
                simulate(ann, 1.0, arb_suppress=sup, **BASE))

    # ---------------------------------------------------------------- PART 6
    hdr("PART 6 - DOES THE LOOP CONVERGE OR DIVERGE?  Staleness in the first vs last decile of a\n"
        "  4000-block run as gamma rises.  Divergence = ratio growing with gamma and >> 1.")
    print(f"{'gamma':>7s}{'stale 1st':>11s}{'stale last':>12s}{'ratio':>8s}{'arb short':>11s}"
          f"{'honest bps':>12s}{'poolvsHODL':>12s}{'SWB rev':>10s}{'LP total':>10s}")
    for g in (0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0):
        r = simulate(0.60, g, **BASE)
        pool_vs_hodl = -r['lvr_blk']            # includes ALL LP fees retained in reserves
        print(f"{g:7.2f}{r['stale_first']:10.2f}t{r['stale_last']:11.2f}t"
              f"{r['stale_last']/max(r['stale_first'],1e-9):8.3f}"
              f"{r['arb_shortfall_pct']:10.1f}%{r['hon_vw_bps']:11.2f}b"
              f"{pool_vs_hodl:12.2f}{r['swb_rev_blk']:10.2f}"
              f"{pool_vs_hodl + r['swb_rev_blk']:10.2f}")
    print("  'poolvsHODL' already CONTAINS all retained LP fees, so it must not be added to a")
    print("  separate fee column (an earlier draft of this table did exactly that and was wrong).")
    print("  It falls as gamma rises for TWO reasons that must be separated: (1) deterred")
    print("  sandwiches stop paying 3 legs of LP fee - that is the mechanism working, and (2) the")
    print("  staleness we cause.  PART 6b removes reason (1) entirely.")

    print()
    print("  PART 6b - PURE STALENESS COST TO LPs.  sandwich_prob = 0, so there is no sandwich")
    print("  fee revenue to lose and no extraction to prevent.  Any movement here is staleness.")
    print(f"{'gamma':>7s}{'staleness':>12s}{'arb short':>11s}{'poolvsHODL':>12s}"
          f"{'SWB rev':>10s}{'LP total':>10s}{'honest bill/blk':>18s}")
    NOSW = {**BASE, 'sandwich_prob': 0.0}
    base_ph = None
    for g in (0.0, 0.25, 0.5, 1.0, 2.0):
        r = simulate(0.60, g, **NOSW)
        ph = -r['lvr_blk']
        if base_ph is None: base_ph = ph
        bill = r['hon_vw_bps'] * BPS * (3.0 * 5_000 * math.exp(0.5))   # E[notional]/block
        print(f"{g:7.2f}{r['stale_open']:11.2f}t{r['arb_shortfall_pct']:10.1f}%"
              f"{ph:12.2f}{r['swb_rev_blk']:10.2f}{ph + r['swb_rev_blk']:10.2f}{bill:18.2f}")
    print("  Read the 'poolvsHODL' column against its gamma=0 row: that difference IS the")
    print("  staleness cost, in dollars per block, with everything else held fixed.")

    # ---------------------------------------------------------------- PART 7
    hdr("PART 7 - CANDIDATE FIXES, each with the HARDCAP-SHAPE CHECK:\n"
        "  does the fix create an exemption an attacker can steer into?")
    print("  FIX A - cap the fee at a published maximum (needed anyway for quoting, SPIKE Q5).")
    print(COLS)
    for cap in (1e9, 20.0, 10.0, 5.0, 2.0):
        row(f"gamma=1, cap={0 if cap>1e8 else cap:.0f} bps",
            simulate(0.60, 1.0, cap_bps=cap, **BASE))
    print("  HARDCAP CHECK: a cap is a ceiling on the ATTACKER's cost too.  Once it binds, every")
    print("  further retraced tick is free, so the attacker's optimal sandwich grows to the point")
    print("  where the cap binds.  Read 'sw esc' and 'sw keep' as the cap tightens.")

    print()
    print("  FIX B - deadband: the first D ticks of extension each block create NO budget.")
    print("  Intent: the corrective arb's extension stops authorising a tax on honest flow.")
    print(COLS)
    for D in (0.0, 2.0, 5.0, 10.0, 20.0):
        row(f"gamma=1, deadband={D:.0f} ticks",
            simulate(0.60, 1.0, deadband=D, **BASE))
    print("  HARDCAP CHECK: the attacker sizes the FRONT-RUN to fit inside D, so the back-run")
    print("  retraces budget that was never credited.  Read 'sw esc'.")

    print()
    print("  FIX C - 'charge only when extension and retracement fall in the same block'.")
    print("  ALREADY THE DESIGN.  T0 and both budgets reset every block; the fee contains no")
    print("  cross-block state whatsoever.  There is nothing to change - see PART 2.")

    print()
    print("  FIX D - EMA / TWAP reference instead of the raw block-open tick.")
    print("  NOT SIMULATED, and argued dead rather than tested: an EMA is by construction MORE")
    print("  lagged than the pool's own current price, so it makes the reference staler, not")
    print("  fresher; and it introduces cross-block state, which reopens 2.4c poisoning at a")
    print("  horizon the extension cap no longer bounds.")

    # ---------------------------------------------------------------- PART 8
    hdr("PART 8 - THE RESET IS THE EXEMPTION.  Found by following PART 2, not hypothesised.\n"
        "  T0 is re-set to the pool's OWN price at every block open.  Therefore the first swap of\n"
        "  a block can never be a retracement: there is nothing behind it to retrace.  Every\n"
        "  top-of-block swap is fee-exempt BY CONSTRUCTION.  That is the same shape as Hardcap's\n"
        "  first-swap exemption.  So: front-run + victim in block N (front-run is an extension,\n"
        "  free), unwind at the TOP of block N+1 (extension from the new T0, free).\n"
        "  Cost = 2 LP fees + losing the race for the first slot.  SWITCHBACK fee = 0.")
    rngp = random.Random(4242)
    for ann in (0.60, 1.20):
        sB = sb(ann)
        for lp_f in (0.0005, 0.0030):
            pool = Pool(40_000_000.0, lp_f)
            n_ok1 = n_ok2 = 0; g1 = g2 = 0.0; gross_sum = 0.0; fee_on_unwind = 0.0; n_att = 0
            TR = 4000
            for _ in range(TR):
                p0 = pool.copy()
                T0 = p0.tick(); m0 = Meter(T0)
                # some prior flow so T0 is not always == current price
                for _ in range(rngp.randrange(0, 3)):
                    a = 5_000 * math.exp(rngp.gauss(0, 1.0))
                    sd = "yin" if rngp.random() < 0.5 else "xin"
                    do_swap(p0, m0, sd, a if sd == "yin" else a / p0.price(), 1.0, 1e9, "hon")
                vamt_y = 5_000 * math.exp(rngp.gauss(0, 1.0))
                vside = "yin" if rngp.random() < 0.5 else "xin"
                vamt = vamt_y if vside == "yin" else vamt_y / p0.price()
                gross, front = best_sandwich(p0, m0, vside, vamt, 0.0, 1e9)
                if gross <= 0: continue
                n_att += 1; gross_sum += gross
                # S1 - in-block sandwich, pays SWITCHBACK
                pr1, _ = best_sandwich(p0, m0, vside, vamt, 1.0, 1e9)
                if pr1 > 0: n_ok1 += 1; g1 += pr1
                # S2 - front-run + victim in block N, unwind at the TOP of block N+1
                pB = p0.copy(); mB = m0.copy(); fees = 0.0
                if vside == "yin":
                    got, fe, _, _ = do_swap(pB, mB, "yin", front, 1.0, 1e9, "atk"); fees += fe
                    do_swap(pB, mB, "yin", vamt, 1.0, 1e9, "hon")
                else:
                    got, fe, _, _ = do_swap(pB, mB, "xin", front, 1.0, 1e9, "atk"); fees += fe
                    do_swap(pB, mB, "xin", vamt, 1.0, 1e9, "hon")
                # ---- new block: T0 resets to the pool's own (displaced) price
                mN = Meter(pB.tick())
                if vside == "yin":
                    back, fe2, ch2, _ = do_swap(pB, mN, "xin", got, 1.0, 1e9, "atk")
                    pr2 = back - front - fees - fe2
                else:
                    back, fe2, ch2, _ = do_swap(pB, mN, "yin", got, 1.0, 1e9, "atk")
                    pr2 = (back - front) * pB.price() - fees - fe2
                fee_on_unwind += fe2
                if pr2 > 0: n_ok2 += 1; g2 += pr2
            lab = f"vol {ann*100:.0f}% ann, LP fee {lp_f*1e4:.0f}bps"
            print(f"  {lab:32s} ({n_att:4d} attackable victims)  in-block: "
                  f"{100.0*n_ok1/max(n_att,1):5.1f}% still profitable, keeps "
                  f"{100.0*g1/max(gross_sum,1e-9):5.1f}% of gross  |  cross-block: "
                  f"{100.0*n_ok2/max(n_att,1):5.1f}% profitable, keeps "
                  f"{100.0*g2/max(gross_sum,1e-9):5.1f}%")
            assert fee_on_unwind == 0.0, "CONTROL FAILED: the top-of-block unwind was charged"
    print("  CONTROL: total SWITCHBACK fee charged on every top-of-block unwind above = 0.00 "
          "(asserted).")
    print()
    print("  The attacker's only remaining cost is the race for the first slot of block N+1.")
    print("  If they lose it, the top-of-block arb takes the displacement instead.  Break-even")
    print("  win probability q* solves  q * (cross-block profit) = (in-block profit):")
    print(f"{'vol':>10s}{'LP fee':>9s}{'q* (must WIN this often)':>28s}")
    rngq = random.Random(99)
    for ann in (0.60, 1.20):
        for lp_f in (0.0005, 0.0030):
            pool = Pool(40_000_000.0, lp_f)
            A = B = 0.0
            for _ in range(3000):
                p0 = pool.copy(); T0 = p0.tick(); m0 = Meter(T0)
                for _ in range(rngq.randrange(0, 3)):
                    a = 5_000 * math.exp(rngq.gauss(0, 1.0))
                    sd = "yin" if rngq.random() < 0.5 else "xin"
                    do_swap(p0, m0, sd, a if sd == "yin" else a / p0.price(), 1.0, 1e9, "hon")
                vamt_y = 5_000 * math.exp(rngq.gauss(0, 1.0))
                vside = "yin" if rngq.random() < 0.5 else "xin"
                vamt = vamt_y if vside == "yin" else vamt_y / p0.price()
                gross, front = best_sandwich(p0, m0, vside, vamt, 0.0, 1e9)
                if gross <= 0: continue
                pr1, _ = best_sandwich(p0, m0, vside, vamt, 1.0, 1e9)
                pB = p0.copy(); mB = m0.copy(); fees = 0.0
                fs = vside; bs = "xin" if vside == "yin" else "yin"
                got, fe, _, _ = do_swap(pB, mB, fs, front, 1.0, 1e9, "atk"); fees += fe
                do_swap(pB, mB, vside, vamt, 1.0, 1e9, "hon")
                mN = Meter(pB.tick())
                back, fe2, _, _ = do_swap(pB, mN, bs, got, 1.0, 1e9, "atk")
                pr2 = (back - front - fees - fe2) if vside == "yin" \
                      else ((back - front) * pB.price() - fees - fe2)
                A += max(pr1, 0.0); B += max(pr2, 0.0)
            q = (A / B) if B > 0 else float('nan')
            print(f"{ann*100:9.0f}%{lp_f*1e4:8.0f}b{q:27.3f}")
    print("  q* is the fraction of first slots the attacker must win for the cross-block route to")
    print("  beat the in-block route.  A LOW q* means the exemption is cheap to reach.")
    print("  On a 200ms single-sequencer chain (Unichain, the target) the boundary is 200ms and")
    print("  the first slot is bought with priority fee - MODELLED, NOT MEASURED.")

    # ---------------------------------------------------------------- PART 9
    hdr("PART 9 - MUTATION CHECKS (standing order 9: distrust green).")
    print(COLS)
    b9 = simulate(0.60, 1.0, **BASE)
    m2 = simulate(0.60, 1.0, uncapped='blind', **BASE)
    m2p = simulate(0.60, 1.0, uncapped='identity', **BASE)
    row("baseline gamma=1 (shipped rule)", b9)
    row("M2  direction-blind (charge all)", m2)
    row("M2' closed form, NO watermarks", m2p)
    print()
    print("  M2 must diverge wildly - it proves the extension/retracement DIRECTION logic is")
    print("  what produces the separation, and is not decoration.")
    ok = m2['hon_vw_bps'] > 2 * b9['hon_vw_bps']
    print(f"    {'PASS' if ok else 'FAIL - the direction logic is inert and every number above is fiction'}")
    print()
    print("  M2' must be IDENTICAL to the baseline.  If it is, then the per-side extension")
    print("  budget is an IDENTITY, not a constraint: on the up side the unspent budget always")
    print("  equals (tick - T0) exactly, because every up-move credits it and every down-move")
    print("  above T0 debits it.  Consequence for the build, if it holds:")
    print("      d0 = tick_before - T0 ; d1 = tick_after - T0")
    print("      charged = (d0*d1 >= 0) ? max(0, |d0| - |d1|) : |d0|")
    print("  ONE storage slot (T0).  The intra-block high/low WATERMARKS OF 2.1 ARE REDUNDANT,")
    print("  and '2.4c: capped by the extension' is a tautology, not a separate defence.")
    same = (abs(m2p['hon_vw_bps'] - b9['hon_vw_bps']) < 1e-9 and
            abs(m2p['sw_escape_pct'] - b9['sw_escape_pct']) < 1e-9 and
            abs(m2p['stale_open'] - b9['stale_open']) < 1e-9)
    print(f"    {'PASS - identical, so the identity holds and the watermarks are dead weight.' if same else 'FAIL - not identical; the budget really does bind somewhere. Investigate.'}")

    print()
    print("  M3 - the 2.4c dust-poison test, run directly rather than inferred:")
    pp = Pool(40_000_000.0, 0.0005); mm = Meter(pp.tick())
    do_swap(pp, mm, "yin", 250.0, 1.0, 1e9, "atk")
    ext = pp.tick() - mm.T0
    before = pp.tick()
    _, fee, ch, _ = do_swap(pp, mm, "xin", 200_000.0 / pp.price(), 1.0, 1e9, "hon")
    print(f"    poison extension {ext:.3f} ticks ; the $200k opposite swap moves "
          f"{abs(pp.tick()-before):.1f} ticks and is charged for {ch:.3f} of them (${fee:.2f}).")
    print(f"    {'PASS - poisoning authorises only its own extension.' if ch <= ext + 1e-9 else 'FAIL'}")

    # ---------------------------------------------------------------- PART 10
    hdr("PART 10 - REFERENCE CARRY.  Can T0 survive a block boundary without a new exemption?\n"
        "  EMA policy: T0_new = T0_old + alpha*(tick_at_block_open - T0_old).\n"
        "  alpha=1 is the shipped hook (T0 resets fully); alpha=0 is a fixed anchor that never\n"
        "  moves.  The budget is seeded with the standing displacement at block open so the M2'\n"
        "  identity still holds; at alpha=1 that seed is exactly 0, which is why the alpha=1 row\n"
        "  reproduces every earlier number bit-for-bit (NEGATIVE CONTROL).\n"
        "  'IN' = in-block sandwich, 'XB' = the PART 8 cross-block unwind, re-scored per policy.")
    print(RCOLS)
    ctrl = None
    for a in (1.0, 0.75, 0.5, 0.25, 0.10, 0.02, 0.0):
        r = simulate(0.60, 1.0, alpha=a, **BASE)
        if a == 1.0: ctrl = r
        rrow(f"EMA alpha={a:.2f}", r)
    base_ref = simulate(0.60, 1.0, **BASE)
    same = (abs(ctrl['hon_vw_bps'] - base_ref['hon_vw_bps']) < 1e-12 and
            abs(ctrl['sw_escape_pct'] - base_ref['sw_escape_pct']) < 1e-12)
    print(f"  NEGATIVE CONTROL (alpha=1 == shipped behaviour): "
          f"{'PASS - exact' if same else 'FAIL - rig is wrong, stop'}")
    if not same: raise SystemExit(1)

    print()
    print("  PART 10b - THE NEW EXEMPTION'S MIRROR: a TRENDING market.  A reference that does not")
    print("  reset lags a trend, so the pool sits persistently on one side of T0 and ALL")
    print("  counter-trend honest flow is charged against that standing lag.")
    print(f"{'policy':26s}{'drift':>8s}{'ref lag':>10s}{'hon chg':>9s}{'hon bps':>9s}"
          f"{'XB keep':>9s}")
    for mu in (0.0, 2.0, 5.0):
        for a in (1.0, 0.5, 0.25, 0.10, 0.0):
            r = simulate(0.60, 1.0, alpha=a, mu_ticks=mu, **BASE)
            print(f"{'EMA alpha=%.2f' % a:26s}{mu:6.1f}t/b{r['ref_lag']:9.2f}t"
                  f"{r['hon_charged_pct']:8.1f}%{r['hon_vw_bps']:8.2f}b{r['xb_keep_pct']:8.1f}%")

    # ---------------------------------------------------------------- PART 11
    hdr("PART 11 - MULTI-BLOCK WINDOW.  T0 held fixed for N blocks, then reset.  Equivalent to\n"
        "  carrying the unspent extension budget across N blocks (PART 9 M2' proved the budget\n"
        "  IS the displacement from T0, so 'carry the budget' and 'carry T0' are the same thing).")
    print(RCOLS)
    for N in (1, 2, 5, 10, 30, 60):
        rrow(f"reset every {N} blocks", simulate(0.60, 1.0, reset_every=N, **BASE))
    print("  The XB columns above assume the attacker lands on a RESET BOUNDARY, which is what a")
    print("  rational attacker does: block.number % N is public, so the boundary is scheduled, not")
    print("  raced.  The attacker gives up nothing but frequency - roughly 1 opportunity in N.")
    print(f"{'N':>5s}{'XB keep (at a boundary)':>26s}{'x 1/N frequency':>18s}"
          f"{'in-block keep':>15s}{'better route':>15s}")
    for N in (1, 2, 5, 10, 30, 60):
        r = simulate(0.60, 1.0, reset_every=N, **BASE)
        ev = r['xb_keep_pct'] / N
        print(f"{N:5d}{r['xb_keep_pct']:25.1f}%{ev:17.2f}%{r['sw_profit_kept']:14.1f}%"
              f"{('CROSS-BLOCK' if ev > r['sw_profit_kept'] else 'in-block'):>15s}")

    # ---------------------------------------------------------------- PART 12
    hdr("PART 12 - CAN THE ATTACKER STEER THE REFERENCE?  The 2.4c dust-poison attack aimed at\n"
        "  T0 instead of at the budget.  Under an EMA, biasing T0 by DELTA ticks requires holding\n"
        "  the tick DELTA/alpha ticks away at the moment the reference is sampled.")
    print(f"{'alpha':>7s}{'push for +5t bias':>20s}{'LP fees on the push':>22s}"
          f"{'+ SWITCHBACK on the unwind':>29s}{'total':>12s}")
    poolz = Pool(40_000_000.0, 0.0005)
    for a in (1.0, 0.5, 0.25, 0.10, 0.02):
        push_ticks = 5.0 / a
        pz = poolz.copy(); mz = Meter(pz.tick()); T0z = mz.T0
        target = pz.tick() + push_ticks
        lo, hi = 0.0, 30_000_000.0
        for _ in range(70):
            mid = (lo + hi) / 2
            q = pz.copy(); q.swap_y_in(mid)
            if q.tick() < target: lo = mid
            else: hi = mid
        dy = (lo + hi) / 2
        q = pz.copy(); gx, fe1, _, _ = do_swap(q, mz, "yin", dy, 1.0, 1e9, "atk")
        tclose = q.tick(); T0n = T0z + a * (tclose - T0z)
        mN = Meter(T0n); d = tclose - T0n
        if d > 1e-15: mN.up.append([d, 'carry'])
        back, fe2, _, _ = do_swap(q, mN, "xin", gx, 1.0, 1e9, "atk")
        lpfee = dy - back + fe1 - fe2 if False else (dy - back - fe2)
        print(f"{a:7.2f}{push_ticks:19.1f}t{max(dy-back,0.0):21,.0f}${fe1+fe2:28,.0f}$"
              f"{max(dy-back,0.0)+fe1+fe2:11,.0f}$")
    print("  The steerer pushes at block close and unwinds at the top of the next block - i.e.")
    print("  they use the same exemption we are trying to close.  Under alpha<1 that unwind is")
    print("  itself charged, which is what makes steering expensive.  But note the cost scales")
    print("  with 1/alpha, so a SMALL alpha makes steering expensive - and a")
    print("  small alpha is exactly what PART 10b shows is unusable in a trend.  The two")
    print("  requirements are opposed: alpha must be small to resist steering and to close the")
    print("  cross-block route, and large to avoid taxing trend-following flow.")
    print("  NOT SIMULATED: the steerer only PROFITS if they also capture the resulting fee as an")
    print("  in-range LP (2.4d).  This rig does not model the fee's destination at all.")

    # ---------------------------------------------------------------- PART 13
    hdr("PART 13 - WHAT DOES alpha<1 COST?  A carried reference taxes more of the corrective arb\n"
        "  (shortfall 26% -> 48% at alpha=0.5), so price discovery is more impaired.  PART 6b's\n"
        "  method: sandwiches OFF, so there is no extraction to prevent and no sandwich fee\n"
        "  revenue to lose.  Any movement is the reference policy alone.")
    NOSW = {**BASE, 'sandwich_prob': 0.0}
    print(f"{'policy':22s}{'ref lag':>10s}{'staleness':>12s}{'arb shrt':>10s}"
          f"{'poolvsHODL':>12s}{'SWB rev':>10s}{'LP total':>10s}{'honest bill/blk':>18s}")
    for a in (1.0, 0.75, 0.5, 0.25, 0.10):
        r = simulate(0.60, 1.0, alpha=a, **NOSW)
        ph = -r['lvr_blk']
        bill = r['hon_vw_bps'] * BPS * (3.0 * 5_000 * math.exp(0.5))
        print(f"{'EMA alpha=%.2f' % a:22s}{r['ref_lag']:9.2f}t{r['stale_open']:11.2f}t"
              f"{r['arb_shortfall_pct']:9.1f}%{ph:12.2f}{r['swb_rev_blk']:10.2f}"
              f"{ph + r['swb_rev_blk']:10.2f}{bill:18.2f}")
    print("  Compare 'poolvsHODL' across rows: that is the LP cost of the impaired price")
    print("  correction, with everything else held fixed.")
    print()
    print("  Steering economics at alpha=0.5, from the measured outputs above rather than assumed:")
    print("  PART 10 gives d(honest bps)/d(ref lag) = (4.14-3.63)/(11.41-7.34) = 0.125 bps/tick.")
    hon_notional = 3.0 * 5_000 * math.exp(0.5)
    rev_per_tick_block = 0.125 * BPS * hon_notional
    print(f"  Honest notional/block = ${hon_notional:,.0f}, so a 1-tick bias earns LPs "
          f"${rev_per_tick_block:.2f}/block.")
    print(f"  A 5-tick bias under alpha=0.5 decays as 5,2.5,1.25,... = 10 tick-blocks total")
    print(f"  => total extra fee ${10*rev_per_tick_block:.2f}, against a measured steering cost of")
    print(f"  $15 (PART 12).  The steerer also receives only their LP SHARE of that fee.")
    print(f"  => steering is about {15/(10*rev_per_tick_block):.0f}x underwater at alpha=0.5.")
    print("  REASONED FROM MEASURED OUTPUTS, NOT DIRECTLY SIMULATED: no steering agent was run,")
    print("  and the fee's destination (2.4d) is not modelled anywhere in this rig.")

    # ---------------------------------------------------------------- PART 14
    hdr("PART 14 - THE OBVIOUS NEXT ATTACK: just WAIT.  Under an EMA the reference catches up\n"
        "  geometrically, so an attacker who holds the position k blocks faces only (1-alpha)^k\n"
        "  of the charge.  Does alpha=0.5 survive that?\n"
        "  ATTACKER-FAVOURABLE BY CONSTRUCTION: this probe assumes NOBODY trades in the waiting\n"
        "  blocks, so the displacement the attacker is sitting on is still there when they")
    print("  unwind.  In reality the top-of-block corrective arb takes it at N+1.  Read these as")
    print("  an UPPER BOUND on the attacker.")
    print(f"{'alpha':>7s}{'k=1':>10s}{'k=2':>10s}{'k=3':>10s}{'k=5':>10s}{'k=10':>10s}"
          f"{'in-block':>11s}")
    rngw = random.Random(31337)
    for a in (1.0, 0.75, 0.5, 0.25):
        keeps = []
        for k in (1, 2, 3, 5, 10):
            gs = 0.0; tot = 0.0; inb = 0.0
            for _ in range(1500):
                pz = Pool(40_000_000.0, 0.0005); T0z = pz.tick(); mz = Meter(T0z)
                for _ in range(rngw.randrange(0, 3)):
                    amt = 5_000 * math.exp(rngw.gauss(0, 1.0))
                    sd = "yin" if rngw.random() < 0.5 else "xin"
                    do_swap(pz, mz, sd, amt if sd == "yin" else amt / pz.price(), 1.0, 1e9, "hon")
                vy = 5_000 * math.exp(rngw.gauss(0, 1.0))
                vs = "yin" if rngw.random() < 0.5 else "xin"
                va = vy if vs == "yin" else vy / pz.price()
                g, _ = best_sandwich(pz, mz, vs, va, 0.0, 1e9)
                if g <= 0: continue
                gs += g
                pr, _ = best_sandwich_xb(pz, mz, T0z, vs, va, 1.0, 1e9, a, False, delay=k)
                tot += max(pr, 0.0)
                p1, _ = best_sandwich(pz, mz, vs, va, 1.0, 1e9)
                inb += max(p1, 0.0)
            keeps.append(100.0 * tot / max(gs, 1e-9))
        print(f"{a:7.2f}" + "".join(f"{v:9.1f}%" for v in keeps) +
              f"{100.0*inb/max(gs,1e-9):10.1f}%")
    print("  Waiting DOES erode the fix - but the attacker cannot actually wait, because the")
    print("  top-of-block corrective arb at N+1 takes the displacement they are holding.  That is")
    print("  the 2.4a inventory-risk argument, and unlike at alpha=1 it is now TRUE: the wait is")
    print("  measured in EMA half-lives, not in one block boundary.")
    print()
    print("  BLOCK TIME IS NOT A FREE PARAMETER.  The EMA decays per BLOCK, so alpha must be set")
    print("  in WALL-CLOCK terms or Unichain's 200ms blocks shrink the protection 60x.")
    print("  For a fixed wall-clock half-life the steady-state lag is INVARIANT to block time:")
    print("    lag_sd ~ sigma_block / sqrt(2*alpha) ; sigma_block ~ 1/sqrt(B) ; alpha ~ 1/B")
    print("    => lag_sd ~ constant.  Every tick number in PART 10 therefore carries over.")
    for B, nm in ((1.0, "Ethereum 12s"), (60.0, "Unichain 200ms")):
        print(f"    {nm:16s} alpha for a 12s half-life = {1 - 0.5**(1/B):.4f}")

    # ---------------------------------------------------------------- PART 15
    hdr("PART 15 - BLOCK TIME.  Everything above ran 12s blocks.  Unichain is 200ms.  The\n"
        "  wall-clock-invariance argument in the REFERENCE-CARRY section is ANALYTIC; this is the\n"
        "  test of it.\n"
        "  RESCALING, stated because it is a judgement call and it drives the answer:\n"
        "    sigma_block  -> annual/sqrt(seconds_per_year/spb)          [falls as 1/sqrt(B)]\n"
        "    swaps/block  -> 3.0 * spb/12                               [flow is a WALL-CLOCK rate]\n"
        "    drift/block  -> mu * spb/12                                [same reason]\n"
        "    blocks run   -> 4000 * 12/spb                              [same wall-clock span]\n"
        "    alpha        -> 1 - 0.5^(spb/12)                           [12s wall-clock half-life]\n"
        "    TRADE SIZE   -> HELD CONSTANT PER SWAP.  This is the judgement call.  A $5,000 trade\n"
        "      is a $5,000 trade whatever the block time, so RETAIL TICK IMPACT IS CONSTANT PER\n"
        "      SWAP (5 ticks), NOT per block.  The alternative - holding impact constant per\n"
        "      block - would make every Unichain swap 60x larger, which is not a market.\n"
        "      If that choice is wrong, section 2's transfer is wrong; it is the one input here\n"
        "      that is a modelling decision rather than a consequence.")

    def cfg(spb, alpha=None, mu=0.0, **kw):
        h = spb / 12.0
        a = alpha if alpha is not None else (1 - 0.5 ** h)
        base = dict(f=0.0005, V0=40_000_000.0, blocks=int(4000 / h),
                    retail_per_block=3.0 * h, retail_med=5_000.0, retail_sd=1.0,
                    sandwich_prob=0.35, spb=spb, alpha=a, mu_ticks=mu * h)
        base.update(kw)
        return base

    print(f"\n  sigma_block: 12s = {sb_at(0.60,12.0)/BPS:6.3f} ticks , "
          f"200ms = {sb_at(0.60,0.2)/BPS:6.3f} ticks  (ratio {sb_at(0.60,12.0)/sb_at(0.60,0.2):.2f}"
          f" ~ sqrt(60)={math.sqrt(60):.2f})")
    print(f"  alpha for a 12s half-life: 12s -> {1-0.5**1:.4f} , 200ms -> {1-0.5**(0.2/12):.6f}")

    print()
    print("  15a - NEGATIVE CONTROL: the 12s configuration must reproduce the existing numbers.")
    print(RCOLS)
    c12 = simulate(0.60, 1.0, **cfg(12.0))
    ref = simulate(0.60, 1.0, alpha=0.5, **BASE)
    rrow("12s, alpha=0.50 (via cfg)", c12)
    rrow("12s, alpha=0.50 (PART 10)", ref)
    okc = (abs(c12['hon_vw_bps'] - ref['hon_vw_bps']) < 1e-12 and
           abs(c12['xb_keep_pct'] - ref['xb_keep_pct']) < 1e-12)
    print(f"  {'PASS - exact' if okc else 'FAIL - rescaling harness disagrees with PART 10, stop'}")
    if not okc: raise SystemExit(1)

    print()
    print("  15b - THE INVARIANCE TEST and the 200ms confusion matrix.")
    print(RCOLS)
    rows = []
    for spb, nm in ((12.0, "12s   "), (2.0, "2s    "), (0.2, "200ms ")):
        r1 = simulate(0.60, 1.0, **cfg(spb, alpha=1.0))
        rH = simulate(0.60, 1.0, **cfg(spb))
        rrow(f"{nm} alpha=1 (shipped)", r1)
        rrow(f"{nm} alpha=12s halflife", rH)
        rows.append((nm, r1, rH))
    print()
    print(f"  {'chain':10s}{'alpha':>12s}{'ref lag (ticks)':>18s}{'invariant?':>14s}")
    base_lag = rows[0][2]['ref_lag']
    for nm, r1, rH in rows:
        h = None
        print(f"  {nm:10s}{(1-0.5**( (12.0 if nm.startswith('12') else (2.0 if nm.startswith('2s') else 0.2))/12.0)):12.6f}"
              f"{rH['ref_lag']:18.2f}{rH['ref_lag']/base_lag:13.2f}x")

    print()
    print("  15c - THE 'JUST WAIT' TABLE AT 200ms.  k is in BLOCKS; 60 blocks = 12s of wall clock.")
    rngb = random.Random(20260826)
    for spb, ks in ((12.0, (1, 2, 3, 5, 10)), (0.2, (1, 30, 60, 120, 180, 300))):
        h = spb / 12.0
        a = 1 - 0.5 ** h
        print(f"    {'12s blocks' if spb==12 else '200ms blocks'}  alpha={a:.6f}   "
              f"(k in blocks; wall clock = k*{spb}s)")
        print("      " + "".join(f"{'k=%d' % k:>12s}" for k in ks) + f"{'in-block':>12s}")
        gs = 0.0; tot = {k: 0.0 for k in ks}; inb = 0.0
        for _ in range(1200):
            pz = Pool(40_000_000.0, 0.0005); T0z = pz.tick(); mz = Meter(T0z)
            for _ in range(rngb.randrange(0, 3)):
                amt = 5_000 * math.exp(rngb.gauss(0, 1.0))
                sd = "yin" if rngb.random() < 0.5 else "xin"
                do_swap(pz, mz, sd, amt if sd == "yin" else amt / pz.price(), 1.0, 1e9, "hon")
            vy = 5_000 * math.exp(rngb.gauss(0, 1.0))
            vs = "yin" if rngb.random() < 0.5 else "xin"
            va = vy if vs == "yin" else vy / pz.price()
            g, _ = best_sandwich(pz, mz, vs, va, 0.0, 1e9)
            if g <= 0: continue
            gs += g
            p1, _ = best_sandwich(pz, mz, vs, va, 1.0, 1e9); inb += max(p1, 0.0)
            for k in ks:
                pr, _ = best_sandwich_xb(pz, mz, T0z, vs, va, 1.0, 1e9, a, False, delay=k)
                tot[k] += max(pr, 0.0)
        print("      " + "".join(f"{100.0*tot[k]/max(gs,1e-9):11.1f}%" for k in ks) +
              f"{100.0*inb/max(gs,1e-9):11.1f}%")
    print("      wall clock to reach the same (1-alpha)^k is IDENTICAL by construction; what")
    print("      changes is that the attacker must survive 60x more blocks of other people's flow")
    print("      and 60x more top-of-block arb opportunities to get there.")

    print()
    print("  15d - GAS IS NOT MODELLED ANYWHERE.  At 200ms the per-block price move is "
          f"{sb_at(0.60,0.2)/BPS:.2f} ticks,")
    print("  so a corrective arb every block may not clear gas.  Emulate a thinner arb population:")
    print(RCOLS)
    for sup in (0.0, 0.5, 0.9, 0.98):
        rrow(f"200ms, {sup*100:.0f}% arbs priced out",
             simulate(0.60, 1.0, arb_suppress=sup, **cfg(0.2)))

    print()
    print("  15e - WHAT ALPHA ACTUALLY WORKS AT 200ms?  Sweeping the WALL-CLOCK half-life.")
    print("  The exact discrete-time lag is sigma_b / sqrt(alpha*(2-alpha)), which is invariant")
    print("  only in the alpha->0 limit; at alpha=0.5 the discrete correction is large.  Analytic")
    print("  prediction alongside the measurement, so the gap is visible:")
    print(f"{'half-life':>12s}{'alpha':>12s}{'lag predicted':>16s}{'lag measured':>15s}"
          f"{'hon chg':>9s}{'hon bps':>9s}{'IN keep':>9s}{'XB keep':>9s}{'wait to 50%':>13s}")
    sig200 = sb_at(0.60, 0.2)
    for hl in (1.0, 4.0, 12.0, 60.0, 300.0):
        a = 1 - 0.5 ** (0.2 / hl)
        pred = sig200 / math.sqrt(a * (2 - a)) / BPS
        r = simulate(0.60, 1.0, **cfg(0.2, alpha=a))
        print(f"{hl:11.0f}s{a:12.6f}{pred:15.2f}t{r['ref_lag']:14.2f}t"
              f"{r['hon_charged_pct']:8.1f}%{r['hon_vw_bps']:8.2f}b{r['sw_profit_kept']:8.1f}%"
              f"{r['xb_keep_pct']:8.1f}%{hl:12.0f}s")
    print("  The last column is the wall-clock the attacker must hold to halve the charge, which")
    print("  IS the half-life by construction.  Choosing it is choosing how long a cross-block")
    print("  unwinder must carry inventory while every arb bot on the pair can take it from them.")
    print()
    print("  For reference, the same sweep at 12s blocks:")
    print(f"{'half-life':>12s}{'alpha':>12s}{'lag predicted':>16s}{'lag measured':>15s}"
          f"{'hon chg':>9s}{'hon bps':>9s}{'IN keep':>9s}{'XB keep':>9s}")
    sig12 = sb_at(0.60, 12.0)
    for hl in (12.0, 60.0, 300.0):
        a = 1 - 0.5 ** (12.0 / hl)
        pred = sig12 / math.sqrt(a * (2 - a)) / BPS
        r = simulate(0.60, 1.0, **cfg(12.0, alpha=a))
        print(f"{hl:11.0f}s{a:12.6f}{pred:15.2f}t{r['ref_lag']:14.2f}t"
              f"{r['hon_charged_pct']:8.1f}%{r['hon_vw_bps']:8.2f}b{r['sw_profit_kept']:8.1f}%"
              f"{r['xb_keep_pct']:8.1f}%")
