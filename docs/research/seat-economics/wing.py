"""
THE MATCHED-WING CONTROL -- is a QUEUE seat replicable with plain Uniswap liquidity?

THE QUESTION. The case against this product is that a rank is a lossy re-encoding of tick choice:
whatever a seat gets, some plain concentrated-liquidity position gets for free, permissionlessly,
cancellable any block, with no roster cap, no rent, no lock and no +133% gas. This module builds
that position and measures it on the same seeds, the same flow and the same marking.

TWO COMPARATORS, BECAUSE ONE DOES NOT FIT ALL 32 RANKS.

  STATIC wing   -- a plain position over a fixed tick span, minted once and left. The right
                   comparator for a DEEP seat, which is reached only near the band edge and then
                   held (the cursor pull-back refills from the head, so the tail does not recycle).

  MANAGED wing  -- a narrow at-the-money position RE-MINTED at spot whenever price leaves it. The
                   right comparator for the HEAD, because rank 0 is not a fixed tick span: all 32
                   seats share one `[tickLower, tickUpper]` and rank changes only the ORDER of fill
                   within it, so rank 0 is a narrow window that re-centres itself on every swap, in
                   both directions, at zero cost. A static wing cannot do that; a keeper can, and
                   the keeper is charged here for gas, for the conversion of its one-sided
                   inventory, and for that conversion's price impact.

THE MODELLING CHOICE, STATED RATHER THAN BURIED. The wing is a PRICE TAKER: it is priced against
the swap tape the QUEUE pool actually produced, as a carve-out of the same total capital (the
ambient band holds `BOOK - cap`, the wing holds `cap`). It therefore does not feed its own depth
back into the price path. That is an approximation and it is the only one in here. It is exact in
the limit of a small wing, and its direction is not obviously favourable to either side: more depth
in the wing's range serves more volume but dampens the moves the wing profits from.

THE NULL CONTROL, AND NOTHING HERE IS BELIEVABLE WITHOUT IT (`check_null`). A wing that spans the
WHOLE band with 1/32 of the capital is, by construction, exactly 1/32 of the undivided pool. Its
fees must equal 1/32 of the pool's fees and its markout 1/32 of the pool's markout, to floating
point. If that fails the engine is wrong and every number it produces is worthless.
"""
import math
import numpy as np
from sim import FEE


# ------------------------------------------------------------------ concentrated-liquidity algebra
def cl_amounts(L, pa, pb, P):
    """Token amounts held by liquidity L over [pa, pb] at price P."""
    s, sa, sb = math.sqrt(P), math.sqrt(pa), math.sqrt(pb)
    if s <= sa:  return L*(1/sa - 1/sb), 0.0
    if s >= sb:  return 0.0, L*(sb - sa)
    return L*(1/s - 1/sb), L*(s - sa)


def cl_liquidity(cap, pa, pb, P):
    """Liquidity whose value at P equals `cap`."""
    x, y = cl_amounts(1.0, pa, pb, P)
    v = x*P + y
    if v <= 0: raise ValueError("degenerate range")
    return cap/v


def _overlap(s0, s1, sa, sb):
    lo, hi = (s1, s0) if s1 < s0 else (s0, s1)
    return max(lo, sa), min(hi, sb)


# ------------------------------------------------------------------------------ the static wing
def static_wing(bk, Pfinal, Pmark, cap, pa_w, pb_w, book):
    """A plain position over [pa_w, pb_w], funded with `cap`, minted once and left alone.

    Fees come from the pool's own binned flow (`bnet0`/`bnet1`, exact to the bin width), the
    inventory from the closed-form CL amounts. Everything is marked at `Pmark`, the same way
    `Book.pnl` marks a seat.
    """
    Lw = cl_liquidity(cap, pa_w, pb_w, bk.P0)
    Lbase = bk.L*(book - cap)/book                     # the rest of the SAME capital, over the band
    share = Lw/(Lbase + Lw)
    sa, sb = math.sqrt(pa_w), math.sqrt(pb_w)
    lo = np.clip(bk.elo, sa, sb); hi = np.clip(bk.ehi, sa, sb)
    frac = np.where(bk.ehi > bk.elo, (hi - lo)/(bk.ehi - bk.elo), 0.0)   # bin overlap fraction
    f0 = float((bk.bnet0*frac).sum())*share*FEE/(1 - FEE)
    f1 = float((bk.bnet1*frac).sum())*share*FEE/(1 - FEE)

    x0, y0 = cl_amounts(Lw, pa_w, pb_w, bk.P0)
    xf, yf = cl_amounts(Lw, pa_w, pb_w, Pfinal)
    markout = (xf*Pmark + yf) - (x0*Pmark + y0)
    fees = f0*Pmark + f1
    hold = x0*Pmark + y0
    return dict(fees=fees, markout=markout, hold=hold, L=Lw, share=share,
                ret=(fees + markout)/hold if hold > 0 else 0.0)


# ------------------------------------------------------------------------------- the managed wing
def managed_wing(bk, Pfinal, Pmark, cap, w, book, gas_usd):
    """A narrow ATM range of log half-width `w`, RE-MINTED at spot whenever price leaves it.

    Every cost is itemised and none is folded into another:
      gas       -- `gas_usd` per re-mint; the caller's assumption, stated in the report
      conv_fee  -- the POOL FEE paid converting the one-sided inventory back to the ATM mix
      conv_imp  -- that conversion swap's own PRICE IMPACT against the ambient band

    The conversion terms are the ones the seat does not pay at all, and they are load-bearing:
    a range the price has left holds exactly ONE token, and re-minting at spot needs both. That is
    the problem `recenter()` could not solve inside the hook, and it does not go away for a human
    LP -- it becomes a swap.

    Impact model: a numeraire notional N against ambient liquidity Lbase displaces sqrt-price by
    |ds| = N/Lbase in BOTH directions (they coincide to first order), so the average execution
    price is off mid by ds/s and the cost is N*N/(Lbase*s). Derived, not guessed.
    """
    Lbase = bk.L*(book - cap)/book
    pa_w, pb_w = bk.P0*math.exp(-w), bk.P0*math.exp(w)
    Lw = cl_liquidity(cap, pa_w, pb_w, bk.P0)
    x0, y0 = cl_amounts(Lw, pa_w, pb_w, bk.P0)          # buy-and-hold benchmark, fixed at open

    f0 = f1 = 0.0
    remints = 0
    conv_fee = conv_imp = 0.0

    for s0, s1, zfo, net in bk.swaps:
        sa, sb = math.sqrt(pa_w), math.sqrt(pb_w)
        lo, hi = _overlap(s0, s1, sa, sb)
        if hi > lo:
            share = Lw/(Lbase + Lw)
            seg = bk.L*(1.0/lo - 1.0/hi) if zfo else bk.L*(hi - lo)
            got = seg*share
            if zfo: f0 += got*FEE/(1 - FEE)
            else:   f1 += got*FEE/(1 - FEE)
        P = s1*s1
        if P <= pa_w or P >= pb_w:
            # OUT OF RANGE: one-sided, earning nothing until re-minted at spot.
            remints += 1
            x, y = cl_amounts(Lw, pa_w, pb_w, P)
            val = x*P + y
            npa, npb = P*math.exp(-w), P*math.exp(w)
            nL = cl_liquidity(val, npa, npb, P)
            tx, ty = cl_amounts(nL, npa, npb, P)
            notional = 0.5*(abs(tx - x)*P + abs(ty - y))     # the conversion trade, in numeraire
            conv_fee += notional*FEE
            conv_imp += notional*notional/(Lbase*math.sqrt(P)) if Lbase > 0 else 0.0
            pa_w, pb_w, Lw = npa, npb, nL

    xf, yf = cl_amounts(Lw, pa_w, pb_w, Pfinal)
    gas = remints*gas_usd
    fees = f0*Pmark + f1
    markout = (xf*Pmark + yf) - (x0*Pmark + y0)
    hold = x0*Pmark + y0
    costs = gas + conv_fee + conv_imp
    return dict(fees=fees, markout=markout, hold=hold, remints=remints,
                gas=gas, conv_fee=conv_fee, conv_imp=conv_imp, costs=costs,
                ret=(fees + markout - costs)/hold if hold > 0 else 0.0,
                ret_nocost=(fees + markout)/hold if hold > 0 else 0.0)


# ------------------------------------------------------------------------------- THE NULL CONTROL
def check_null(bk, Pfinal, Pmark, book, nseat, tol=1e-9):
    """A full-band wing of 1/nseat of the capital IS 1/nseat of the undivided pool.

    Returns (rel_fee_err, rel_markout_err). Both must be ~0 or the engine is wrong.
    """
    cap = book/nseat
    wgt = static_wing(bk, Pfinal, Pmark, cap, bk.pa, bk.pb, book)
    pool_fee = (bk.fe0.sum() + bk.pp0.sum())*Pmark + (bk.fe1.sum() + bk.pp1.sum())
    pool_mk = bk.mk0.sum()*Pmark + bk.mk1.sum()
    ef = abs(wgt['fees'] - pool_fee/nseat)/max(abs(pool_fee/nseat), 1e-12)
    em = abs(wgt['markout'] - pool_mk/nseat)/max(abs(pool_mk/nseat), 1e-12)
    return ef, em, wgt
