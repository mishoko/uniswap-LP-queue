"""
THE TWO-ENDED BOOK -- an ordering fork of sim.py.  sim.py IS NOT TOUCHED.

WHAT SHIPS (mode 'SHIPPED').  One rank ordering, read from ONE end in BOTH directions:
    zeroForOne  (token1 out) drains rank 0 upward from cursor c1
    oneForZero  (token0 out) drains rank 0 upward from cursor c0
So a front seat is drained one way and refilled the other.  It churns.

WHAT IS UNDER TEST (mode 'BOOK').  One rank ordering, read from BOTH ends:
    zeroForOne  (token1 out) drains rank 0   upward   from cursor c1   [unchanged]
    oneForZero  (token0 out) drains rank n-1 downward from cursor d0   [REVERSED]
Claim: rank 0 gives up token1 first and token0 LAST, so it is a monotone token0 accumulator --
a priority limit BUY.  rank n-1 is the mirror.  The middle fills last in both directions.

SHIPPED is the degenerate case of BOOK where both ends are end 0.

---------------------------------------------------------------------------------------------------
WHY THIS IS A COPY AND NOT A SUBCLASS PATCH.  `Book.swap` and `Book._fill` in sim.py each hardcode
the walk direction in a place that cannot be reached by overriding anything smaller than the whole
method (`avail = self.a0[self.c0:].sum()` inside swap; `for i in range(cur, self.n)` inside _fill).
`sim.run` hardcodes `Book(...)` and has no hook for a subclass.  So THREE things are copied:
`swap`, `_fill` and `run`.  Everything else is inherited from sim.Book unchanged -- __init__,
_accrue, pnl, tie_out, prem_recv, prem_paid.

THE GUARD ON THAT COPY.  A copy silently rots when the original changes.  `_check_source()` below
md5s the three originals and raises if any has moved.  It is called at import.

THE CONTROL THAT MAKES THE COPY BELIEVABLE (book_report.py, control 0).  In mode 'SHIPPED' this
class must reproduce sim.Book BIT-FOR-BIT -- every balance, every accumulator, every cursor, on
real paths.  That control reads FAIL if I mistranscribed a single line of the two copied methods,
which is precisely the failure mode a rewrite has.  It is not arithmetic in a costume: it compares
two independently-executed implementations, one of which I did not write.

WHAT IS ADDED beyond sim.Book (all additive; none of it changes a balance):
    hits[i]                 fills touching seat i
    b0n[i] / b0q[i]         token0 ACQUISITION: numeraire paid / token0 received (market, ex-fee)
    b0e[i]                  token0 received INCLUDING the fee it retains, net of premium forfeited
    s0n[i] / s0q[i]         token0 DISPOSAL: numeraire received (ex-fee) / token0 given up
    s0e[i]                  numeraire received INCLUDING retained fee, net of premium forfeited
    (tk0[i] is inherited and is already the exact non-monotonicity measure: a0 falls ONLY by tk0.)
"""
import sys, os, math, inspect, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import sim
from sim import FEE

# md5 of the three sim.py sources this file transcribes. If any moves, the copy is stale.
_SRC = {
    'swap':  '0792d2a728b0c110c5ed85c39887d431',
    '_fill': '88f57185e759747375a55b1a2ec72e49',
    'run':   'ad6d9b8c4c31b119b72d62812d0a1520',
}


def _check_source():
    got = {}
    for f in ('swap', '_fill'):
        got[f] = hashlib.md5(inspect.getsource(getattr(sim.Book, f)).encode()).hexdigest()
    got['run'] = hashlib.md5(inspect.getsource(sim.run).encode()).hexdigest()
    bad = [f"{k}: expected {v}, got {got[k]}" for k, v in _SRC.items() if got[k] != v]
    if bad:
        raise RuntimeError("book_sim.py transcribes sim.py and sim.py has CHANGED:\n  "
                           + "\n  ".join(bad) + "\nRe-transcribe before trusting any number.")


_check_source()


class Book2(sim.Book):
    def __init__(self, caps, P0, marginal, half=0.10, phi=0, trace=False, mode='SHIPPED'):
        super().__init__(caps, P0, marginal, half, phi, trace)
        assert mode in ('SHIPPED', 'BOOK')
        self.mode = mode
        # NOCURSOR: ignore the cursors entirely and walk the WHOLE array from the correct end.
        # Economically it must be identical -- the walk already skips empty seats with `continue`
        # -- so it is the control that says whether a cursor ever excludes a seat that still holds
        # the outgoing token.  See book_report.py control 0b.
        self.nocursor = False
        # DOWNWARD cursor for token0, used only in BOOK mode: the HIGHEST rank that may still hold
        # token0.  Mirrors c0's meaning (lowest rank that may still hold token0) about the middle.
        self.d0 = self.n - 1
        z = lambda: np.zeros(self.n)
        self.hits = np.zeros(self.n, np.int64)
        self.b0n, self.b0q, self.b0e = z(), z(), z()
        self.s0n, self.s0q, self.s0e = z(), z(), z()

    # -------------------------------------------------------------- NOT a copy: the BOOK repair
    def _accrue(self, zfo, pot):
        """sim.Book._accrue, then REPAIR THE TWO-ENDED CURSORS.

        A FINDING, and it is specific to the two-ended book.  `_accrue` credits the INCOMING token
        to every seat holding the OUTGOING one -- it does not touch a cursor.  Under the SHIPPED
        one-ended rule that is harmless by construction: a zeroForOne fill has just set
        `c0 = min(c0, cur)` with `cur` the old `c1`, and every seat below the old `c1` holds zero
        token1, so it receives zero token0 premium.  No seat below `c0` can ever be credited.
        Verified, not assumed: SHIPPED with cursors == SHIPPED ignoring cursors, bit-for-bit, at
        phi = 0 AND phi = 8500, on 6 seeds x 4 regimes.

        Under BOOK it is NOT harmless.  `d0` walks DOWN, so a seat ABOVE `d0` can be holding token1,
        collect token0 premium, and sit outside `[0, d0]` forever -- inventory the walk can never
        reach and `avail` can never see.  Measured before this repair: the price path diverged and
        seat balances moved by up to ~0.5% of a $1,000,000 book.  So the repair is required, and
        the hazard is worth recording: A TWO-ENDED CURSOR CANNOT BE MAINTAINED FROM THE FILL ALONE,
        because the premium is a second writer of the same inventory.
        """
        super()._accrue(zfo, pot)
        if self.mode != 'BOOK':
            return
        if zfo:                                     # token0 was credited
            nz = np.nonzero(self.a0 > 1e-15)[0]
            if nz.size: self.d0 = max(self.d0, int(nz[-1]))
        else:                                       # token1 was credited
            nz = np.nonzero(self.a1 > 1e-15)[0]
            if nz.size: self.c1 = min(self.c1, int(nz[0]))

    # ------------------------------------------------------------------ COPY of sim.Book.swap
    # Transcribed verbatim except the two lines marked BOOK, which read `avail` from the correct
    # end of the array.  Guarded by _check_source().
    def swap(self, P, gross_in, zfo):
        """zfo: token0(ETH) in, token1(USDC) out, price FALLS.  else: USDC in, ETH out, P rises."""
        L, s0, net = self.L, math.sqrt(P), gross_in*(1-FEE)
        if net <= 0: return P
        if zfo:
            s1  = s0/(1 + net*s0/L)                       # 1/s1 = 1/s0 + net/L
            out = L*(s0 - s1)                             # USDC out
            avail = self.a1.sum() if self.nocursor else self.a1[self.c1:].sum()
        else:
            s1  = s0 + net/L
            out = L*(1/s0 - 1/s1)                         # ETH out
            if self.nocursor:
                avail = self.a0.sum()
            elif self.mode == 'BOOK':                                                 # BOOK
                avail = self.a0[:self.d0 + 1].sum() if self.d0 >= 0 else 0.0          # BOOK
            else:
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
        if self.trace:
            a, b = (s1, s0) if zfo else (s0, s1)
            i0 = max(0, int(np.searchsorted(self.edges, a, 'right')) - 1)
            i1 = min(self.NB, int(np.searchsorted(self.edges, b, 'left')))
            if i1 > i0:
                lo = np.clip(self.elo[i0:i1], a, b); hi = np.clip(self.ehi[i0:i1], a, b)
                if zfo:
                    self.bnet0[i0:i1] += np.where(hi > lo, self.L*(1.0/np.maximum(lo, 1e-300)
                                                                   - 1.0/np.maximum(hi, 1e-300)), 0.0)
                else:
                    self.bnet1[i0:i1] += self.L*(hi - lo)
            self.swaps.append((s0, s1, zfo, net))
        self._fill(gross_in, out, zfo, s0, s1)
        v = gross_in*(P if zfo else 1.0)
        self.vol += v
        if self.tag=='r': self.vr += v
        else: self.va += v
        return s1*s1

    # ------------------------------------------------------------------ COPY of sim.Book._fill
    # Transcribed verbatim except: the walk direction / cursor block (marked BOOK), and the
    # additive execution-price accumulators (marked EXEC).  Guarded by _check_source().
    def _fill(self, amt_in, amt_out, zfo, s0, s1):
        L = self.L
        bal   = self.a1 if zfo else self.a0               # drained
        other = self.a0 if zfo else self.a1               # credited
        down  = (self.mode == 'BOOK') and (not zfo)                                   # BOOK
        if down:                                                                      # BOOK
            cur = self.n - 1 if self.nocursor else self.d0                             # BOOK
            walk = range(cur, -1, -1)                                                 # BOOK
        else:                                                                         # BOOK
            cur = 0 if self.nocursor else (self.c1 if zfo else self.c0)
            walk = range(cur, self.n)
        mk_in  = self.mk0 if zfo else self.mk1            # principal lands in the incoming token
        mk_out = self.mk1 if zfo else self.mk0            # take leaves in the outgoing token
        fe_in  = self.fe0 if zfo else self.fe1
        pp_in  = self.pp0 if zfo else self.pp1
        gv_in  = self.gv0 if zfo else self.gv1
        tk_out = self.tk1 if zfo else self.tk0
        deepest = -1
        rem, assigned, cum, sprev, nxt = amt_out, 0.0, 0.0, s0, cur
        swap_pot = 0.0
        for i in walk:                                                                # BOOK
            if rem <= 1e-15: break
            if bal[i] <= 1e-15: continue
            take = min(bal[i], rem); rem -= take; cum += take
            _sp0 = sprev                       # THIS seat's own price segment: [_sp0, _sp1]
            if rem <= 1e-15:
                give = amt_in - assigned                              # THE remainder line
                _sp1 = s1
            elif self.marginal:
                si  = (s0 - cum/L) if zfo else 1.0/(1.0/s0 - cum/L)
                seg = (L*(1/si - 1/sprev)) if zfo else (L*(si - sprev))
                give = seg/(1-FEE); sprev = si
                _sp1 = si
            else:
                give = amt_in*take/amt_out                            # today's AVERAGE price
                _sp0, _sp1 = s0, s1
            pot = self.phi*FEE*give
            assigned += give; bal[i] -= take; other[i] += give - pot
            mk_in[i]  += give*(1-FEE)
            fe_in[i]  += give*FEE - pot
            mk_out[i] -= take
            pp_in[i]  += pot
            gv_in[i]  += give
            tk_out[i] += take
            deepest = i
            # ---- EXEC: additive only.  zfo => this seat BUYS token0 with `take` numeraire.
            self.hits[i] += 1                                                         # EXEC
            gnet = give*(1-FEE)                                                       # EXEC
            if zfo:                                                                   # EXEC
                self.b0n[i] += take; self.b0q[i] += gnet; self.b0e[i] += give - pot    # EXEC
            else:                                                                     # EXEC
                self.s0n[i] += gnet; self.s0q[i] += take; self.s0e[i] += give - pot    # EXEC
            if _sp1 < self.smin[i]: self.smin[i] = _sp1
            if _sp1 > self.smax[i]: self.smax[i] = _sp1
            if _sp0 < self.smin[i]: self.smin[i] = _sp0
            if _sp0 > self.smax[i]: self.smax[i] = _sp0
            if self.phi > 0 and sim.PREM_MODE == 'perseat' and pot > 0:
                # NOTE: under BOOK+!zfo "strictly later" means strictly LOWER rank.  Only reachable
                # if PREM_MODE is switched off its default; the default 'contract' path is used.
                w = bal[i+1:] if not down else bal[:i]
                tw = w.sum()
                if tw <= 1e-15:
                    if zfo: self.held0 += pot
                    else:   self.held1 += pot
                else:
                    share = pot*w/tw
                    if down:
                        (self.pr0 if zfo else self.pr1)[:i] += share
                        other[:i] += share
                    else:
                        (self.pr0 if zfo else self.pr1)[i+1:] += share
                        other[i+1:] += share
            swap_pot += pot
            nxt = (i-1 if down else i+1) if bal[i] <= 1e-15 else i                     # BOOK
        # ---- cursors.  A cursor may only ever be too WIDE, never too narrow.
        if self.mode == 'BOOK':                                                        # BOOK
            if zfo:                                                                    # BOOK
                # drained token1 upward; credited token0 to ranks [cur, deepest].
                self.c1 = nxt                                                          # BOOK
                self.d0 = max(self.d0, deepest, cur)                                   # BOOK
            else:                                                                      # BOOK
                # drained token0 downward; credited token1 to ranks [deepest, cur].
                self.d0 = nxt                                                          # BOOK
                self.c1 = min(self.c1, cur if deepest < 0 else deepest)                # BOOK
        elif zfo: self.c1, self.c0 = nxt, min(self.c0, cur)
        else:     self.c0, self.c1 = nxt, min(self.c1, cur)
        if zfo: self.potted0 += swap_pot
        else:   self.potted1 += swap_pot
        self.nswap += 1
        self.reach[deepest + 1] += 1                  # index 0 == "no seat touched at all"
        if self.tag == 'a': self.reach_a[deepest + 1] += 1
        self._ex0, self._ex1 = cur, min(nxt, self.n - 1)      # the excluded rank interval
        if cur == 0: self.head_excl += 1
        if nxt > deepest and deepest >= 0: self.over_excl += 1   # an UNTOUCHED seat is excluded
        if cur == 0 and nxt >= self.n - 1: self.all_excl += 1
        # AFTER the fill, never before: the drained seats now carry zero weight.
        if self.phi > 0 and sim.PREM_MODE == 'contract':
            self._accrue(zfo, swap_pot)


ARB_SLICE = sim.ARB_SLICE


# ---------------------------------------------------------------------- COPY of sim.run
# Transcribed verbatim except: it builds Book2 with a `mode`, and it samples the HOURLY price pair
# so a TWAP benchmark exists without paying for the heavy `trace`.  Guarded by _check_source().
def run2(caps, marginal, days=365, seed=11, vol=0.45, retail_per_hr=3.0, P0=2000.0, half=0.10,
         drift=0.0, phi=0, trace=False, mode='SHIPPED', nocursor=False):
    rng = np.random.default_rng(seed)
    P = Pt = P0
    bk = Book2(caps, P0, marginal, half, phi, trace, mode)
    bk.nocursor = nocursor
    bk.hpool, bk.hext = [], []          # hourly price samples, for the TWAP benchmark
    sd = vol/math.sqrt(365*24)
    exited = False; hrs = 0
    for _h in range(days*24):
        hrs = _h+1
        Pt *= math.exp(rng.normal(0, sd) + drift*sd)
        if not (P0*(1-half) < Pt < P0*(1+half)):
            exited = True; break
        Pt = min(max(Pt, P0*(1-half)*1.0005), P0*(1+half)*0.9995)
        for _ in range(rng.poisson(retail_per_hr)):
            u = rng.random()
            S = (100.0**-0.6 + u*(10_000.0**-0.6 - 100.0**-0.6))**(-1/0.6)   # $ notional
            zfo = rng.random() < 0.5
            bk.tag='r'
            P = bk.swap(P, S/P if zfo else S, zfo)                  # input token = ETH or USDC
        if   P > Pt*(1+FEE): zfo, tgt = True,  Pt*(1+FEE)
        elif P < Pt*(1-FEE): zfo, tgt = False, Pt*(1-FEE)
        else: zfo = None
        if zfo is not None:
            s0, st = math.sqrt(P), math.sqrt(tgt)
            net = bk.L*(1/st - 1/s0) if zfo else bk.L*(st - s0)
            if net > 0:
                bk.tag='a'
                P = bk.swap(P, net/(1-FEE), zfo)
        bk.hpool.append(P); bk.hext.append(Pt)
        if trace: bk.path.append((hrs, P, Pt))
    bk.hrs, bk.exited = hrs, exited
    return bk, P, Pt


# ------------------------------------------------------------------------------- CONTROL 0
def identical(a, b, fields=None):
    """Bit-for-bit comparison of two Book states.  Returns list of (field, max abs diff)."""
    if fields is None:
        fields = ('a0', 'a1', 'o0', 'o1', 'mk0', 'mk1', 'fe0', 'fe1', 'pr0', 'pr1',
                  'pp0', 'pp1', 'gv0', 'gv1', 'tk0', 'tk1', 'reach', 'reach_a', 'smin', 'smax')
        scal = ('c0', 'c1', 'L', 'nswap', 'vol', 'vr', 'va', 'held0', 'held1',
                'potted0', 'potted1', 'head_excl', 'all_excl', 'over_excl')
    out = []
    for f in fields:
        x, y = np.asarray(getattr(a, f), float), np.asarray(getattr(b, f), float)
        x = np.where(np.isfinite(x), x, 0.0); y = np.where(np.isfinite(y), y, 0.0)
        d = float(np.max(np.abs(x - y))) if x.size else 0.0
        if d != 0.0: out.append((f, d))
    for f in scal:
        d = abs(float(getattr(a, f)) - float(getattr(b, f)))
        if d != 0.0: out.append((f, d))
    return out
