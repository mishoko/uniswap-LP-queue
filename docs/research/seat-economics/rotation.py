"""
ROTATION: does giving every seat a scheduled turn at the head make every seat profitable?

Same mechanism as `sim.py` — one constant-liquidity band, front-first drain from a cursor,
marginal (segment) pricing — with ONE addition: RANK IS SEPARATED FROM OWNERSHIP. `ord[r]` is the
owner sitting at rank r, exactly as the contract's packed `order` word works, and every `EPOCH`
hours the ranks rotate by one position. Balances stay with the owner; only the place in line moves.

Round-robin, not random. Randomness on-chain means a block hash, a block hash means the builder
chooses, and a head slot worth 900%/yr is worth grinding for. Round-robin is deterministic,
unmanipulable, needs no oracle, and over one full cycle every owner has occupied every rank exactly
once. That last property is the whole point.
"""
import numpy as np, math
FEE = 0.0030

class Book:
    def __init__(self, caps, P0, marginal=True, half=0.10):
        caps = np.asarray(caps, float)
        self.n, self.marginal = len(caps), marginal
        self.pa, self.pb = P0*(1-half), P0*(1+half)
        s0, sa, sb = math.sqrt(P0), math.sqrt(self.pa), math.sqrt(self.pb)
        unit0, unit1 = (1/s0 - 1/sb), (s0 - sa)
        self.L = caps.sum()/(unit0*P0 + unit1)
        w = caps/caps.sum()
        self.a0 = self.L*unit0*w            # ETH  per OWNER
        self.a1 = self.L*unit1*w            # USDC per OWNER
        self.o0, self.o1 = self.a0.copy(), self.a1.copy()
        self.ord = np.arange(self.n)        # ord[rank] = owner
        self.c0 = self.c1 = 0               # cursors are RANKS
        self.vol = 0.0
        self.headEpochs = np.zeros(self.n)  # audit: how often each owner was head

    def rotate(self):
        """Shift every owner back one place; the head goes to the tail. Cursors are ranks, so a
           reordering invalidates them and they reset to the front."""
        self.ord = np.roll(self.ord, -1)
        self.c0 = self.c1 = 0

    def swap(self, P, gross_in, zfo):
        L, s0, net = self.L, math.sqrt(P), gross_in*(1-FEE)
        if net <= 0: return P
        bal = self.a1 if zfo else self.a0
        cur = self.c1 if zfo else self.c0
        avail = sum(bal[self.ord[r]] for r in range(cur, self.n))
        if zfo:
            s1  = s0/(1 + net*s0/L); out = L*(s0 - s1)
        else:
            s1  = s0 + net/L;        out = L*(1/s0 - 1/s1)
        if out <= 0 or not math.isfinite(s1) or s1 <= 0: return P
        if out > avail:
            if avail <= 1e-12: return P
            out = avail
            if zfo:
                s1 = s0 - out/L
                if s1 <= 0: return P
                net = L*(1/s1 - 1/s0)
            else:
                if 1/s0 - out/L <= 0: return P
                s1 = 1/(1/s0 - out/L); net = L*(s1 - s0)
            gross_in = net/(1-FEE)
        self._fill(gross_in, out, zfo, s0)
        self.vol += gross_in*(P if zfo else 1.0)
        return s1*s1

    def _fill(self, amt_in, amt_out, zfo, s0):
        L = self.L
        bal   = self.a1 if zfo else self.a0
        other = self.a0 if zfo else self.a1
        cur   = self.c1 if zfo else self.c0
        rem, assigned, cum, sprev, nxt = amt_out, 0.0, 0.0, s0, cur
        for r in range(cur, self.n):
            if rem <= 1e-15: break
            o = self.ord[r]
            if bal[o] <= 1e-15: continue
            take = min(bal[o], rem); rem -= take; cum += take
            if rem <= 1e-15:
                give = amt_in - assigned                       # the remainder line
            else:
                si  = (s0 - cum/L) if zfo else 1.0/(1.0/s0 - cum/L)
                seg = (L*(1/si - 1/sprev)) if zfo else (L*(si - sprev))
                give = seg/(1-FEE); sprev = si
            assigned += give; bal[o] -= take; other[o] += give
            nxt = r+1 if bal[o] <= 1e-15 else r
        if zfo: self.c1, self.c0 = nxt, min(self.c0, cur)
        else:   self.c0, self.c1 = nxt, min(self.c1, cur)

    def pnl(self, Pt):
        held = self.o0*Pt + self.o1
        return (self.a0*Pt + self.a1) - held, held


def run(caps, days=365, seed=11, vol=0.45, retail_per_hr=15.0, P0=2000.0, half=0.10,
        drift=0.0, epoch_hours=0):
    """epoch_hours = 0 -> STATIC ranks (what ships today). >0 -> rotate every that many hours."""
    rng = np.random.default_rng(seed)
    P = Pt = P0
    bk = Book(caps, P0, True, half)
    sd = vol/math.sqrt(365*24)
    exited = False; hrs = 0
    for h in range(days*24):
        hrs = h+1
        if epoch_hours and h and h % epoch_hours == 0:
            bk.rotate()
        bk.headEpochs[bk.ord[0]] += 1
        Pt *= math.exp(rng.normal(0, sd) + drift*sd)
        if not (P0*(1-half) < Pt < P0*(1+half)):
            exited = True; break
        Pt = min(max(Pt, P0*(1-half)*1.0005), P0*(1+half)*0.9995)
        for _ in range(rng.poisson(retail_per_hr)):
            u = rng.random()
            S = (100.0**-0.6 + u*(10_000.0**-0.6 - 100.0**-0.6))**(-1/0.6)
            zfo = rng.random() < 0.5
            P = bk.swap(P, S/P if zfo else S, zfo)
        if   P > Pt*(1+FEE): zfo, tgt = True,  Pt*(1+FEE)
        elif P < Pt*(1-FEE): zfo, tgt = False, Pt*(1-FEE)
        else: zfo = None
        if zfo is not None:
            s0, st = math.sqrt(P), math.sqrt(tgt)
            net = bk.L*(1/st - 1/s0) if zfo else bk.L*(st - s0)
            if net > 0: P = bk.swap(P, net/(1-FEE), zfo)
    bk.hrs, bk.exited = hrs, exited
    return bk, P, Pt
