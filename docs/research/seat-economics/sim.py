"""
QUEUE simulated as the CONTRACT behaves.

  token0 = ETH (volatile), token1 = USDC (numeraire), P = USDC per ETH  (v3 convention P=t1/t0)
  ONE band [0.9*P0, 1.1*P0] with liquidity L MINTED ONCE and held fixed, exactly as the hook does.
  Seats hold (a0,a1); the OUTGOING token is drained FRONT-FIRST from a cursor, as _allocate does.

The thing the naive model missed: seat 1 is EMPTIED and the cursor advances past it. It refills
only when the flow REVERSES, so its throughput is capped by its own capital per reversal.

P&L is mark-to-market against buy-and-hold of the same opening inventory.
"""
import numpy as np, math
FEE = 0.0030

class Book:
    def __init__(self, caps, P0, marginal, half=0.10):
        caps = np.asarray(caps, float)
        self.n, self.marginal = len(caps), marginal
        self.pa, self.pb = P0*(1-half), P0*(1+half)
        s0, sa, sb = math.sqrt(P0), math.sqrt(self.pa), math.sqrt(self.pb)
        # mint L once so the position's value at P0 equals the capital supplied
        unit0, unit1 = (1/s0 - 1/sb), (s0 - sa)          # per unit of L
        self.L = caps.sum()/(unit0*P0 + unit1)
        w = caps/caps.sum()
        self.a0 = self.L*unit0*w                          # ETH per seat
        self.a1 = self.L*unit1*w                          # USDC per seat
        self.o0, self.o1 = self.a0.copy(), self.a1.copy()
        self.c0 = self.c1 = 0
        self.vol = 0.0; self.vr = 0.0; self.va = 0.0; self.tag = 'r'

    def swap(self, P, gross_in, zfo):
        """zfo: token0(ETH) in, token1(USDC) out, price FALLS.  else: USDC in, ETH out, P rises."""
        L, s0, net = self.L, math.sqrt(P), gross_in*(1-FEE)
        if net <= 0: return P
        if zfo:
            s1  = s0/(1 + net*s0/L)                       # 1/s1 = 1/s0 + net/L
            out = L*(s0 - s1)                             # USDC out
            avail = self.a1[self.c1:].sum()
        else:
            s1  = s0 + net/L
            out = L*(1/s0 - 1/s1)                         # ETH out
            avail = self.a0[self.c0:].sum()
        if out <= 0 or not math.isfinite(s1) or s1 <= 0: return P
        if out > avail:                                   # queue cannot source it -> clamp
            if avail <= 1e-12: return P
            out = avail
            if zfo:
                s1 = s0 - out/L
                if s1 <= 0: return P
                net = L*(1/s1 - 1/s0)
            else:
                if 1/s0 - out/L <= 0: return P
                s1  = 1/(1/s0 - out/L); net = L*(s1 - s0)
            gross_in = net/(1-FEE)
        self._fill(gross_in, out, zfo, s0, s1)
        v = gross_in*(P if zfo else 1.0)
        self.vol += v
        if self.tag=='r': self.vr += v
        else: self.va += v
        return s1*s1

    def _fill(self, amt_in, amt_out, zfo, s0, s1):
        L = self.L
        bal   = self.a1 if zfo else self.a0               # drained
        other = self.a0 if zfo else self.a1               # credited
        cur   = self.c1 if zfo else self.c0
        rem, assigned, cum, sprev, nxt = amt_out, 0.0, 0.0, s0, cur
        for i in range(cur, self.n):
            if rem <= 1e-15: break
            if bal[i] <= 1e-15: continue
            take = min(bal[i], rem); rem -= take; cum += take
            if rem <= 1e-15:
                give = amt_in - assigned                              # THE remainder line
            elif self.marginal:
                si  = (s0 - cum/L) if zfo else 1.0/(1.0/s0 - cum/L)
                seg = (L*(1/si - 1/sprev)) if zfo else (L*(si - sprev))
                give = seg/(1-FEE); sprev = si
            else:
                give = amt_in*take/amt_out                            # today's AVERAGE price
            assigned += give; bal[i] -= take; other[i] += give
            nxt = i+1 if bal[i] <= 1e-15 else i
        if zfo: self.c1, self.c0 = nxt, min(self.c0, cur)
        else:   self.c0, self.c1 = nxt, min(self.c1, cur)

    def pnl(self, Pt):
        held = self.o0*Pt + self.o1
        return (self.a0*Pt + self.a1) - held, held

ARB_SLICE = 2000.0
def run(caps, marginal, days=365, seed=11, vol=0.45, retail_per_hr=3.0, P0=2000.0, half=0.10, drift=0.0):
    rng = np.random.default_rng(seed)
    P = Pt = P0
    bk = Book(caps, P0, marginal, half)
    sd = vol/math.sqrt(365*24)
    exited = False; hrs = 0
    for _h in range(days*24):
        hrs = _h+1
        Pt *= math.exp(rng.normal(0, sd) + drift*sd)
        if not (P0*(1-half) < Pt < P0*(1+half)):
            # the price has left the fixed band: the position is one-sided and stops earning.
            # THIS IS THE INSTRUMENT'S TERM ENDING, and it must be in the measurement, not
            # assumed away -- BUSINESS.md's own "~16 days of in-band life" depends on it.
            exited = True; break
        Pt = min(max(Pt, P0*(1-half)*1.0005), P0*(1+half)*0.9995)
        for _ in range(rng.poisson(retail_per_hr)):
            u = rng.random()
            S = (100.0**-0.6 + u*(10_000.0**-0.6 - 100.0**-0.6))**(-1/0.6)   # $ notional
            zfo = rng.random() < 0.5
            bk.tag='r'
            P = bk.swap(P, S/P if zfo else S, zfo)                  # input token = ETH or USDC
        # ONE arbitrage trade, sized in closed form to push spot back to the no-arb edge.
        # Slicing it would erase the very thing under test: a large trade's price impact is what
        # separates the front of the book from the back.
        if   P > Pt*(1+FEE): zfo, tgt = True,  Pt*(1+FEE)
        elif P < Pt*(1-FEE): zfo, tgt = False, Pt*(1-FEE)
        else: zfo = None
        if zfo is not None:
            s0, st = math.sqrt(P), math.sqrt(tgt)
            net = bk.L*(1/st - 1/s0) if zfo else bk.L*(st - s0)
            if net > 0:
                bk.tag='a'
                P = bk.swap(P, net/(1-FEE), zfo)
    bk.hrs, bk.exited = hrs, exited
    return bk, P, Pt
