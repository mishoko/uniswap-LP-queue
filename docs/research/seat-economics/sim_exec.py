"""
QUEUE simulated as the CONTRACT behaves.

  token0 = ETH (volatile), token1 = USDC (numeraire), P = USDC per ETH  (v3 convention P=t1/t0)
  ONE band [0.9*P0, 1.1*P0] with liquidity L MINTED ONCE and held fixed, exactly as the hook does.
  Seats hold (a0,a1); the OUTGOING token is drained FRONT-FIRST from a cursor, as _allocate does.

The thing the naive model missed: seat 1 is EMPTIED and the cursor advances past it. It refills
only when the flow REVERSES, so its throughput is capped by its own capital per reversal.

P&L is mark-to-market against buy-and-hold of the same opening inventory.

---------------------------------------------------------------------------------------------------
THE PRIORITY PREMIUM (phi), ADDED 2026-09-02. Before this the simulator did not model phi AT ALL,
so every number in results-seats.txt was a phi = 0 measurement while the deploy script shipped
phi = 8500 citing a sweep in this directory that did not exist.

What the contract does (src/queue/QueueHook.sol, read line by line):

  _premiumOn(amtIn)   = amtIn * expectedFee/1e6 * phi/1e4.  amtIn is the position's GROSS receipt,
                        so amtIn*fee IS the LP fee by definition; the pot is phi of it.
  _allocate           = Allocation.init(amtIn - pot, amtOut).  THE PREMIUM COMES OFF THE TOP, and
                        Allocation.step splits the reduced whole with the SAME curve, so every
                        seat's credit is scaled by exactly (1 - phi*fee).  Equivalently: each seat
                        forfeits phi*fee*give of its own fill.  The two forms are identical and the
                        per-seat one is what `_fill` below implements.
  _accruePremium      = called AFTER the fill, never before.  A pot of the INCOMING token is
                        divided over the seats' holdings of the OUTGOING token (premGrowth0 is
                        token0 premium per unit of token1 STANDING; _claims weights owed0 by w1).
                        Because it runs after the fill, the seats this swap drained hold zero of
                        the outgoing token, carry zero weight, and collect none of the pot they
                        just generated -- i.e. it goes to the seats STILL STANDING BEHIND.
  the hold rule       = if the standing weight is too small the pot is HELD, not dropped, and
                        folded into the next accrual that has a recipient.

`PREM_MODE` below selects between the contract's aggregate form and the per-seat form; they agree
to well under a basis point (measured), and 'contract' is the default.

===================================================================================================
THE EXECUTION-PRICE FORK, 2026-09-02.  A COPY OF sim.py (md5 3b69d27a..).  sim.py IS NOT TOUCHED.

THE HYPOTHESIS UNDER TEST -- "the matched pair".  `_fill` walks `sprev` from `s0` toward `s1`, so
the seat filled FIRST is priced on the segment nearest the PRE-swap price and the seat filled LAST
on the segment nearest the POST-swap price.  In BOTH directions the first slot is the WORST slot:

    zfo (price FALLS): the seat GIVES token1 and RECEIVES token0 -- it is BUYING the volatile
        asset.  The first segment is the HIGHEST price, so the head buys dearest.
    !zfo (price RISES): the seat GIVES token0 and RECEIVES token1 -- it is SELLING.  The first
        segment is the LOWEST price, so the head sells cheapest.

So the claim is that front-first is not a pure privilege: the head pays the worst price of every
move and is compensated with fills and recycling inventory, while the tail is filled rarely but at
the best price of each move and then holds.  If that trade is symmetric, the Ratchet
(premise-review/fairness.md A.2c) is not a defect and the project should stop trying to fix it.
If one side is strictly worse, this says which and by how much.

WHAT IS ADDED, AND THE CLOSED FORM THAT MAKES IT CHEAP.  Under marginal pricing a seat's segment
runs [sprev, si] in sqrt-price and `give*(1-FEE)` is exactly the segment's net amount, so its
realised MARKET price (fee excluded) is exactly `sprev*si`.  It is computed here from the flows
rather than the closed form, because the REMAINDER LINE does not follow the closed form and the
remainder line is the load-bearing one (PITFALLS 2.14):

    gnet = give*(1-FEE)
    zfo : Px = take/gnet     (numeraire per volatile GIVEN UP -- the seat BUYS; LOWER is better)
    !zfo: Px = gnet/take     (numeraire per volatile RECEIVED  -- the seat SELLS; HIGHER is better)

and the benchmark is the SAME SWAP's own average, i.e. what ONE undivided pro-rata seat would have
realised on that trade:

    zfo : Pv = amt_out/(amt_in*(1-FEE))          !zfo: Pv = (amt_in*(1-FEE))/amt_out

    EDGE = (Pv - Px)/Pv  if zfo else (Px - Pv)/Pv        POSITIVE = better than pro-rata.

EDGE is signed the same way in both directions, is dimensionless, and sums to ~zero across the
seats of one fill by construction -- which is what makes it a real per-rank measurement and not a
restatement of the total.  `u` in [0,1] is where the seat landed inside the move (0 = executed at
the pre-swap price, 1 = at the post-swap price); it is reported because it is the geometry, while
EDGE is the money.

TWO WARNINGS ABOUT WHAT THIS FILE CANNOT DO.
  * `total P&L` differences between orderings CANNOT FAIL -- availability is order-invariant and
    the remainder line forces sum(give) == amtIn.  `ROTATION.md`'s banner already recorded a
    maximally corrupt allocator scoring +0.000000% on exactly that check.  Nothing here rests on
    an aggregate identity; every table is per (path, rank).
  * This simulator is pure float with no decimals and one pool.  It cannot see a token0/token1
    unit-mixing bug the way an 18/6 fixture can (LAW 1).  Read it as economics, not as a test of
    the contract's arithmetic.
===================================================================================================
"""
import numpy as np, math
FEE = 0.0030

# 'contract' : ONE pot per swap, distributed after the fill over post-fill outgoing-token balances.
#              This is _accruePremium verbatim.
# 'perseat'  : each seat's own pot distributed over strictly-later seats' pre-fill balances.
#              Differs only in whether a PARTIALLY drained seat shares in the pot of the seats
#              ahead of it in the same swap.  Kept so the difference can be measured, not assumed.
PREM_MODE = 'contract'

class Book:
    def __init__(self, caps, P0, marginal, half=0.10, phi=0, trace=False):
        caps = np.asarray(caps, float)
        self.n, self.marginal = len(caps), marginal
        self.phi = phi/10000.0
        self.P0 = P0
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
        # ---- decomposition accumulators, in TOKEN units, per seat -------------------------------
        # invariant asserted by tie_out(): a0 == o0 + mk0 + fe0 + pr0  (and the same for token1)
        z = lambda: np.zeros(self.n)
        self.mk0, self.mk1 = z(), z()      # inventory / markout legs (principal in, take out)
        self.fe0, self.fe1 = z(), z()      # fee RETAINED on own fills (net of premium forfeited)
        self.pr0, self.pr1 = z(), z()      # premium RECEIVED from seats ahead
        self.pp0, self.pp1 = z(), z()      # premium PAID away (informational; already out of fe)
        self.held0 = self.held1 = 0.0      # pot with nobody standing: HELD, exactly as the contract
        self.potted0 = self.potted1 = 0.0  # every wei ever withheld, for the conservation check
        # ---- REACH and TURNOVER. A rank the flow never reaches is not a tranche, it is unfunded
        # capital, so the depth actually touched has to be measured rather than assumed.
        self.reach = np.zeros(self.n + 1, np.int64)   # histogram of DEEPEST rank touched per swap
        self.reach_a = np.zeros(self.n + 1, np.int64) # the same, arbitrage swaps only
        self.nswap = 0
        self.gv0, self.gv1 = z(), z()      # GROSS incoming credited per seat, by token
        self.tk0, self.tk1 = z(), z()      # outgoing token DRAINED per seat, by token
        # THE SPAN A RANK IS ACTUALLY FILLED OVER, measured rather than assumed. The case against
        # this product is that rank k IS a tick span; this is the number that settles it.
        self.smin = np.full(self.n, np.inf)     # lowest sqrt-price at which this seat was filled
        self.smax = np.full(self.n, -np.inf)    # highest
        # ---- EXECUTION-PRICE INSTRUMENTS (the execution-price fork). Split by DIRECTION, because
        # "entry price" and "exit price" are different questions and averaging them cancels the
        # very asymmetry under test. b = the seat BUYS the volatile asset (zfo). s = it SELLS.
        self.nfb, self.nfs   = z(), z()    # fill COUNT
        self.ntb, self.nts   = z(), z()    # NOTIONAL of those fills, in numeraire
        self.edb, self.eds   = z(), z()    # sum(edge * notional)  -> NUMERAIRE of edge vs pro-rata
        self.uwb, self.uws   = z(), z()    # sum(u * notional)     -> where in the move it landed
        self.pxb, self.pxs   = z(), z()    # sum(Px * notional)    -> notional-weighted exec price
        self.pvb, self.pvs   = z(), z()    # sum(Pv * notional)    -> the same for the benchmark
        # SOLO vs MULTI.  On a fill that touches ONE seat, that seat IS the pool and its execution
        # price IS the swap average: edge is exactly 0 by construction, for every rank.  Those
        # fills therefore DILUTE the head's mean edge toward zero without saying anything about
        # ordering.  The mechanism under test only operates when a fill touches 2+ seats, so the
        # multi-seat subset is reported separately -- and the solo subset is reported too, as a
        # built-in null: it MUST come out at 0.000 bps for every rank or the instrument is wrong.
        self.mnb, self.mns   = z(), z()    # fill count,  MULTI-seat fills only
        self.mtb, self.mts   = z(), z()    # notional,    MULTI-seat fills only
        self.mdb, self.mds   = z(), z()    # sum(edge*notional), MULTI-seat fills only
        self.mub, self.mus   = z(), z()    # sum(u*notional),    MULTI-seat fills only
        self.sdb, self.sds   = z(), z()    # sum(edge*notional), SOLO fills only (the null)
        self.stb, self.sts   = z(), z()    # notional,           SOLO fills only
        self.first_ct = z()                # times this seat was the FIRST seat of a fill
        self.start_ct = z()                # times a fill STARTED at this rank (the cursor value)
        # per-fill audit of the new instrument: sum of seat legs must reconstruct the swap's legs
        self.exec_err = 0.0
        self.edge_zero_err = 0.0
        # ---- optional heavy trace, for the matched-wing engine only (see wing.py). OFF by default
        # because it costs ~2x runtime and the main grid does not need it.
        self.trace = trace
        if trace:
            self.NB = 1024
            self.edges = np.linspace(math.sqrt(self.pa), math.sqrt(self.pb), self.NB + 1)
            self.elo, self.ehi = self.edges[:-1], self.edges[1:]
            self.bnet0 = np.zeros(self.NB)   # NET token0 input the pool absorbed in each sqrt-P bin
            self.bnet1 = np.zeros(self.NB)   # NET token1 input the pool absorbed in each sqrt-P bin
            self.path = []                   # (hour, pool price P, external price Pt)
            # THE SWAP TAPE. Every swap as (s0, s1, zfo, net_in). The matched-wing engine replays
            # it as a PRICE TAKER, which is the only way to compare a seat against a plain LP
            # position without inventing a second price process.
            self.swaps = []

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
        if self.trace:
            a, b = (s1, s0) if zfo else (s0, s1)
            lo = np.clip(self.elo, a, b); hi = np.clip(self.ehi, a, b)
            if zfo: self.bnet0 += np.where(hi > lo, self.L*(1.0/np.maximum(lo, 1e-300) - 1.0/np.maximum(hi, 1e-300)), 0.0)
            else:   self.bnet1 += self.L*(hi - lo)
            self.swaps.append((s0, s1, zfo, net))
        self._fill(gross_in, out, zfo, s0, s1)
        v = gross_in*(P if zfo else 1.0)
        self.vol += v
        if self.tag=='r': self.vr += v
        else: self.va += v
        return s1*s1

    # ------------------------------------------------------------------ the premium distribution
    def _accrue(self, zfo, pot):
        """`pot` of the INCOMING token, divided over holdings of the OUTGOING token.

        Mirrors _accruePremium: pot0 is weighted by token1 standing and vice versa, and a pot with
        nobody standing is HELD and folded into the next accrual that has a recipient.

        DELIBERATE DEVIATION, AND IT IS ALSO A FINDING.  The contract's guard is `w < total`, not
        `w == 0` -- a wei-scale bound that keeps `mulDiv(total, 2^64, w)` inside 128 bits.  It
        compares a pot denominated in the INCOMING token against a weight denominated in the
        OUTGOING one, in RAW units.  On a symmetric-decimals pool that is nearly the same thing as
        `w == 0`.  On the 18/6 pool the deploy script actually ships it is not:

            demo roster, `_fundSeat(..., 100e18, 400e6)` -> standing1 ~ 3.2e9 (6-dec units)
            a 1-token0 swap  -> pot = 1e18 * 0.003 * 0.85 = 2.55e15  >>  standing1
            => `w < total` fires, the pot is HELD, and `total` only grows from there.

        i.e. on an 18/6 pool the whole premium in the 18-decimal direction looks like it can never
        be distributed at all.  `Premium.t.sol` cannot see this: its `setUp` sets dec0 = dec1 = 18,
        which is LAW 1 inside the one suite that tests the premium.  Flagged as ANALYSIS -- read
        from the source, NOT executed against the contract.  This simulator therefore models the
        ECONOMIC intent (`w == 0` means nobody to pay), which is the generous reading; if the
        18/6 reading is right, every phi number in results-tranche.txt is an UPPER bound on what
        the shipped pool would actually pay backward.
        """
        if pot <= 0 and (self.held0 if zfo else self.held1) <= 0: return
        wts = self.a1 if zfo else self.a0                 # OUTGOING token = the weight
        tot = wts.sum()
        if zfo:
            total = pot + self.held0
            if tot <= 1e-15:
                self.held0 = total; return
            self.held0 = 0.0
            share = total*wts/tot
            self.pr0 += share; self.a0 += share
        else:
            total = pot + self.held1
            if tot <= 1e-15:
                self.held1 = total; return
            self.held1 = 0.0
            share = total*wts/tot
            self.pr1 += share; self.a1 += share

    def _fill(self, amt_in, amt_out, zfo, s0, s1):
        L = self.L
        bal   = self.a1 if zfo else self.a0               # drained
        other = self.a0 if zfo else self.a1               # credited
        cur   = self.c1 if zfo else self.c0
        mk_in  = self.mk0 if zfo else self.mk1            # principal lands in the incoming token
        mk_out = self.mk1 if zfo else self.mk0            # take leaves in the outgoing token
        fe_in  = self.fe0 if zfo else self.fe1
        pp_in  = self.pp0 if zfo else self.pp1
        gv_in  = self.gv0 if zfo else self.gv1
        tk_out = self.tk1 if zfo else self.tk0
        deepest = -1
        rem, assigned, cum, sprev, nxt = amt_out, 0.0, 0.0, s0, cur
        swap_pot = 0.0
        # ---- execution-price locals -------------------------------------------------------------
        nf  = self.nfb if zfo else self.nfs
        nt  = self.ntb if zfo else self.nts
        ed  = self.edb if zfo else self.eds
        uw  = self.uwb if zfo else self.uws
        pxa = self.pxb if zfo else self.pxs
        pva = self.pvb if zfo else self.pvs
        _ain = amt_in*(1-FEE)
        Pv = (amt_out/_ain) if zfo else (_ain/amt_out)     # the swap's OWN average -- pro-rata
        P_pre, P_post = s0*s0, s1*s1
        _dP = P_post - P_pre
        _sum_num, _sum_den, _first = 0.0, 0.0, -1
        _recs = []                          # (rank, edge, notional, u) buffered for the solo/multi split
        # THE ZERO-SUM AUDIT: edge is a SPLIT, it creates nothing.  The residual is scaled by the
        # fill's NOTIONAL, not by sum|edge|.  That matters: under AVERAGE pricing every edge is
        # float dust, so |sum(e)|/sum|e| is a ratio of two dust quantities and reads a meaningless
        # 1.0 -- it looked like a catastrophic failure and was nothing.  Scaled by notional the
        # metric stays meaningful whether the edge is real or identically zero.
        _edge_sum = _edge_abs = 0.0
        for i in range(cur, self.n):
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
            # THE PREMIUM COMES OFF THE TOP. `give` is gross, its fee component is give*FEE, and
            # phi of that is forfeited to the seats still standing behind. Withholding it per seat
            # is algebraically identical to Allocation.init(amtIn - pot, amtOut): both scale every
            # credit by (1 - phi*FEE).
            pot = self.phi*FEE*give
            assigned += give; bal[i] -= take; other[i] += give - pot
            mk_in[i]  += give*(1-FEE)
            fe_in[i]  += give*FEE - pot
            mk_out[i] -= take
            pp_in[i]  += pot
            gv_in[i]  += give
            tk_out[i] += take
            deepest = i
            # ---- EXECUTION PRICE, from the flows (so the remainder line is covered too) --------
            _gnet = give*(1-FEE)
            if _gnet > 0.0 and take > 0.0:
                # WEIGHT BY THE VOLATILE LEG VALUED AT Pv, NOT BY THE NUMERAIRE LEG.  The
                # counterfactual is "the same seat, the same volatile quantity, at the swap's own
                # average price", so the dollar edge is volleg*(Pv - Px) for a buyer and
                # volleg*(Px - Pv) for a seller.  With that weight the edge is EXACTLY ZERO-SUM
                # across the seats of one fill -- sum = Pv*sum(volleg) - sum(numleg) = 0 -- which
                # is a per-FILL property that can fail, unlike any aggregate identity.  Weighting
                # by the numeraire leg instead loses that and biases the dollar figure by ~Px/Pv.
                if zfo:                                   # gives numeraire, BUYS volatile
                    volleg = _gnet; Px = take/_gnet; edge = (Pv - Px)/Pv
                else:                                     # gives volatile, SELLS it for numeraire
                    volleg = take;  Px = _gnet/take; edge = (Px - Pv)/Pv
                notional = Pv*volleg
                nf[i]  += 1.0
                nt[i]  += notional
                ed[i]  += edge*notional
                pxa[i] += Px*notional
                pva[i] += Pv*notional
                _u = ((Px - P_pre)/_dP) if _dP != 0.0 else 0.5
                uw[i]  += _u*notional
                _recs.append((i, edge, notional, _u))
                _edge_sum += edge*notional
                _edge_abs += notional
                _sum_num += (_gnet if zfo else take)      # volatile leg of this seat
                _sum_den += (take if zfo else _gnet)      # numeraire leg of this seat
                if _first < 0:
                    _first = i; self.first_ct[i] += 1.0
            if _sp1 < self.smin[i]: self.smin[i] = _sp1
            if _sp1 > self.smax[i]: self.smax[i] = _sp1
            if _sp0 < self.smin[i]: self.smin[i] = _sp0
            if _sp0 > self.smax[i]: self.smax[i] = _sp0
            if self.phi > 0 and PREM_MODE == 'perseat' and pot > 0:
                w = bal[i+1:]
                tw = w.sum()
                if tw <= 1e-15:
                    if zfo: self.held0 += pot
                    else:   self.held1 += pot
                else:
                    share = pot*w/tw
                    (self.pr0 if zfo else self.pr1)[i+1:] += share
                    other[i+1:] += share
            swap_pot += pot
            nxt = i+1 if bal[i] <= 1e-15 else i
        if zfo: self.c1, self.c0 = nxt, min(self.c0, cur)
        else:   self.c0, self.c1 = nxt, min(self.c1, cur)
        if zfo: self.potted0 += swap_pot
        else:   self.potted1 += swap_pot
        # ---- THE ZERO-SUM AUDIT.  Every dollar of edge one rank gains, another rank loses on the
        # SAME fill.  If this ever drifts, the per-rank edge numbers are inventing money and every
        # conclusion drawn from them is void.  Checked on every multi-seat fill, not in aggregate.
        if _edge_abs > 0.0:
            self.edge_zero_err = max(self.edge_zero_err, abs(_edge_sum)/_edge_abs)
        # ---- commit the solo/multi split now that the fill's width is known --------------------
        if _recs:
            if len(_recs) > 1:
                mn = self.mnb if zfo else self.mns; mt = self.mtb if zfo else self.mts
                md = self.mdb if zfo else self.mds; mu = self.mub if zfo else self.mus
                for (i, e, nn, uu) in _recs:
                    mn[i] += 1.0; mt[i] += nn; md[i] += e*nn; mu[i] += uu*nn
            else:
                sd = self.sdb if zfo else self.sds; st = self.stb if zfo else self.sts
                (i, e, nn, uu) = _recs[0]
                sd[i] += e*nn; st[i] += nn
        self.nswap += 1
        if deepest >= 0:
            self.start_ct[cur] += 1.0
            # AUDIT the new instrument every fill: the seats' own legs must reconstruct the swap's.
            # Without this, a per-seat price can be wrong in a way no aggregate would ever show.
            _vol_leg = _ain if zfo else amt_out
            _num_leg = amt_out if zfo else _ain
            if _vol_leg > 0 and _num_leg > 0:
                self.exec_err = max(self.exec_err,
                                    abs(_sum_num - _vol_leg)/_vol_leg,
                                    abs(_sum_den - _num_leg)/_num_leg)
        self.reach[deepest + 1] += 1                  # index 0 == "no seat touched at all"
        if self.tag == 'a': self.reach_a[deepest + 1] += 1
        # AFTER the fill, never before: the drained seats now carry zero weight.
        if self.phi > 0 and PREM_MODE == 'contract':
            self._accrue(zfo, swap_pot)

    def pnl(self, Pt):
        held = self.o0*Pt + self.o1
        return (self.a0*Pt + self.a1) - held, held

    # ------------------------------------------------------------------------- the decomposition
    def tie_out(self, Pt, tol=1e-6):
        """Assert the per-seat flow accumulators reproduce the balances, then split P&L in two.

        Returns (fees, markout) in NUMERAIRE, per seat, with fees + markout == pnl()[0] exactly.
        Raises if the accumulators do not reconstruct a0/a1 -- a decomposition that does not tie
        out is worthless and every conclusion drawn from it is worthless too.
        """
        r0 = self.o0 + self.mk0 + self.fe0 + self.pr0
        r1 = self.o1 + self.mk1 + self.fe1 + self.pr1
        s0 = float(np.max(np.abs(r0 - self.a0))/max(1e-30, np.max(np.abs(self.a0)) or 1.0))
        s1 = float(np.max(np.abs(r1 - self.a1))/max(1e-30, np.max(np.abs(self.a1)) or 1.0))
        assert s0 < tol and s1 < tol, f"decomposition does not tie out: rel err {s0:.3e} / {s1:.3e}"
        # every wei withheld was either distributed or is still HELD
        p_recv = float(self.pr0.sum()); p_pay = float(self.pp0.sum())
        e0 = abs(p_pay - p_recv - self.held0)/max(1e-30, p_pay or 1.0)
        p_recv1 = float(self.pr1.sum()); p_pay1 = float(self.pp1.sum())
        e1 = abs(p_pay1 - p_recv1 - self.held1)/max(1e-30, p_pay1 or 1.0)
        assert e0 < tol and e1 < tol, f"premium leaked: {e0:.3e} / {e1:.3e}"
        fees    = (self.fe0 + self.pr0)*Pt + (self.fe1 + self.pr1)
        markout = self.mk0*Pt + self.mk1
        d, _ = self.pnl(Pt)
        scale = max(1.0, float(np.max(np.abs(d))))
        assert float(np.max(np.abs(fees + markout - d)))/scale < tol, "fees+markout != pnl"
        return fees, markout

    def exec_stats(self):
        """Per-rank execution quality. Returns a dict of length-n arrays.

        Every 'mean' here is NOTIONAL-WEIGHTED, not fill-weighted: a rank whose fills are one big
        one and ninety dust ones must not have the dust dominate its average price.
        """
        w = lambda a, n: np.where(n > 0, a/np.maximum(n, 1e-300), np.nan)
        return dict(
            nfill_b=self.nfb, nfill_s=self.nfs, nfill=self.nfb + self.nfs,
            not_b=self.ntb, not_s=self.nts, notional=self.ntb + self.nts,
            edge_b=w(self.edb, self.ntb), edge_s=w(self.eds, self.nts),
            edge=w(self.edb + self.eds, self.ntb + self.nts),
            edge_usd_b=self.edb, edge_usd_s=self.eds, edge_usd=self.edb + self.eds,
            u_b=w(self.uwb, self.ntb), u_s=w(self.uws, self.nts),
            px_b=w(self.pxb, self.ntb), px_s=w(self.pxs, self.nts),
            pv_b=w(self.pvb, self.ntb), pv_s=w(self.pvs, self.nts),
            first=self.first_ct, start=self.start_ct,
            m_nfill_b=self.mnb, m_nfill_s=self.mns, m_nfill=self.mnb + self.mns,
            m_not=self.mtb + self.mts,
            m_edge_b=w(self.mdb, self.mtb), m_edge_s=w(self.mds, self.mts),
            m_edge=w(self.mdb + self.mds, self.mtb + self.mts),
            m_edge_usd=self.mdb + self.mds,
            m_u_b=w(self.mub, self.mtb), m_u_s=w(self.mus, self.mts),
            # THE NULL: solo fills must show EXACTLY zero edge at every rank.
            solo_edge=w(self.sdb + self.sds, self.stb + self.sts),
            solo_not=self.stb + self.sts)

    def prem_recv(self, Pt):
        return self.pr0*Pt + self.pr1

    def prem_paid(self, Pt):
        return self.pp0*Pt + self.pp1

ARB_SLICE = 2000.0
def run(caps, marginal, days=365, seed=11, vol=0.45, retail_per_hr=3.0, P0=2000.0, half=0.10,
        drift=0.0, phi=0, trace=False):
    rng = np.random.default_rng(seed)
    P = Pt = P0
    bk = Book(caps, P0, marginal, half, phi, trace)
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
        if trace: bk.path.append((hrs, P, Pt))
    bk.hrs, bk.exited = hrs, exited
    return bk, P, Pt
