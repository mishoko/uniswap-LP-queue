"""
TIDE parameter experiment -- is there a (c, tau_L) that confines JIT AND keeps honest LPs cheap?
Seeded, reproducible.  python3 tide_parameters.py

TIDE:  dA = |dL|/L, A decays with tau_L.  charge = c * A_pre * |dL|/L * V
       => cost as a FRACTION of the actor's own deposit is exactly  c * A_pre.
Variant B "burst": effective A = max(0, A - Aref), Aref a slow EMA (tau_ref = 7d).

LOAD-BEARING ASSUMPTION, STATED PLAINLY: no real v4 add/remove or swap-size distributions were
fetched. Everything below is SYNTHETIC, chosen to bracket a plausible ETH/USDC pool. Every number
is conditional on it. Two market regimes are run so the reader sees the sensitivity.

BUG FOUND AND FIXED IN v1 (kept here as the record): v1 fed the sniper the EVENT-AVERAGED A, which
is sampled AFTER the actor's own `A += m` and therefore ~24x the true ambient. That made TIDE look
like it deterred JIT at every c >= 0.02. It does not. Always use the PRE-action A.
"""
import math, random

SEED = 20260826
YR   = 365.0
P, DEC0, DEC1 = 3000.0, 18, 6          # non-1:1 price, non-equal decimals (CLAUDE.md 5.10)
V    = 2_000_000.0
FEE  = 0.0005
BIG_SWAP = 1_000_000.0
R_CAPITAL = 0.10
REGIMES = {  # name: (daily volume, sigma)
    'healthy': (4_000_000.0, 0.60),    # fee yield 36.5% APR, LVR 4.5% -> LPing profitable
    'toxic':   (  500_000.0, 1.00),    # fee yield  4.6% APR, LVR 12.5% -> LPing loses (the theme's pools)
}
ADD_FRAC_PER_DAY, MED_ADD_M, SIG_ADD_M = 0.10, 0.02, 1.0
MED_HOLD_DAYS, SIG_HOLD = 14.0, 1.2
TAU_REF = 7.0

# ---------------- CONTROL 1: units --------------------------------------------------------
def m_from_tokens(d_eth_wei, d_usdc_units, mixed=False):
    eth, usdc = d_eth_wei/10**DEC0, d_usdc_units/10**DEC1
    if mixed: usdc = d_usdc_units                       # deliberate decimal-scaling bug
    return (eth*P + usdc)/V
def unit_control():
    dep = 0.10*V
    e, u = int((dep/2)/P*10**DEC0), int((dep/2)*10**DEC1)
    e9, u9 = int((dep*0.9)/P*10**DEC0), int((dep*0.1)*10**DEC1)
    return (abs(m_from_tokens(e,u)-0.10)<1e-9,
            abs(m_from_tokens(e,u,mixed=True)-0.10)<1e-9,
            abs(m_from_tokens(e9,u9)-0.10)<1e-9)

# ---------------- ambient A + honest LP cost, event-driven --------------------------------
def sim(tau_L, variant="abs", days=600, seed=SEED):
    rng = random.Random(seed)
    lam = ADD_FRAC_PER_DAY/MED_ADD_M
    ev, tt, uid = [], 0.0, 0
    while tt < days:
        tt += rng.expovariate(lam); uid += 1
        m = min(MED_ADD_M*math.exp(rng.gauss(0,SIG_ADD_M)), 0.60)
        hold = MED_HOLD_DAYS*math.exp(rng.gauss(0,SIG_HOLD))
        ev.append((tt,'add',m,uid)); ev.append((tt+hold,'rm',m,uid))
    ev.sort(key=lambda e:(e[0], e[1]))
    A = Aref = last = 0.0
    warm = days*0.25
    entry, rts, pre_sum, pre_n, tw_sum, tw_t = {}, [], 0.0, 0, 0.0, 0.0
    for (t,k,m,u) in ev:
        dt = t-last; last = t
        if dt > 0:                                        # time-average of A over [last, t]
            tw_sum += A*tau_L*(1-math.exp(-dt/tau_L)); tw_t += dt
        A *= math.exp(-dt/tau_L)
        Aref += (A-Aref)*(1-math.exp(-dt/TAU_REF))
        eff = A if variant=="abs" else max(0.0, A-Aref)   # PRE-action, this is what is charged
        if t > warm: pre_sum += eff; pre_n += 1
        if k=='add': entry[u] = eff
        else:
            if u in entry and t > warm: rts.append(entry.pop(u)+eff)
            else: entry.pop(u, None)
        A += m
    return (pre_sum/max(pre_n,1),                          # E[A_pre]  <- the statistic that matters
            tw_sum/max(tw_t,1e-9),                         # time-average A
            sum(rts)/len(rts) if rts else float('nan'),    # honest round-trip cost / c
            len(rts))

# ---------------- sniper: max over (m, T) of excess over a same-capital resident ------------
T_GRID = [1/7200,1/1440,1/144,1/24,0.25,1.0,2.0,5.0,10.0,30.0]
def sniper(c, tau_L, A_amb, regime, variant="abs", Aref_lvl=0.0):
    dvol, sigma = REGIMES[regime]
    carry = (sigma*sigma/8.0 + R_CAPITAL)/YR - FEE*dvol/V      # net $/day cost of holding, per $
    best = (-1e18, 0.0, 0.0)
    m = 0.0005
    while m <= 1.5:
        pos, share = m*V, m/(1+m)
        rev = FEE*BIG_SWAP*share
        for T in T_GRID:
            a_in  = A_amb
            a_out = A_amb + m*math.exp(-T/tau_L)
            if variant != "abs": a_in, a_out = max(0.0,a_in-Aref_lvl), max(0.0,a_out-Aref_lvl)
            charge = c*(a_in*m + a_out*(m/(1+m)))*V
            exc = rev - charge - max(0.0,carry)*pos*T
            if exc > best[0]: best = (exc, m, T)
        m *= 1.06
    exc, m, T = best
    return exc, m, T, max(exc,0.0)/(FEE*BIG_SWAP)

def negative_control():
    e,m,T,s = sniper(0.0, 1/144, 0.0, 'healthy')
    return m, s, T

def run_test(tau_L, c, variant="abs"):
    """Mass-exit / bank run: what does the LAST LP out pay when X% of the pool leaves in tau_L?"""
    out = []
    for frac in [0.10, 0.25, 0.50, 0.90]:
        A = frac                                  # total variation of that exodus, within tau_L
        out.append((frac, c*A*100))               # exit cost as % of the leaver's own deposit
    return out

if __name__ == "__main__":
    ok, bad, inv = unit_control()
    print("="*100)
    print("CONTROL 1 -- units, P=3000 (non-1:1), decimals 18/6 (non-equal)")
    print(f"   token->m == value->m .............. {ok}    (must be True)")
    print(f"   unit-MIXED variant also matches ... {bad}   (must be False, else the control is vacuous)")
    print(f"   90/10 deposit gives the same m .... {inv}    (must be True)")
    m0,s0,T0 = negative_control()
    print("CONTROL 2 -- NEGATIVE CONTROL: c = 0 must reproduce today's JIT")
    print(f"   optimal m = {m0*100:.0f}% of pool (grid cap 150%), captures {s0*100:.0f}% of the fee, T = {T0*1440:.2f} min")
    print(f"   {'PASS' if m0 > 1.3 and s0 > 0.5 else 'FAIL -- the model is wrong, not TIDE'}")
    print("="*100)
    for variant, title in [("abs","VARIANT A -- absolute accumulator (the spec as written)"),
                           ("burst","VARIANT B -- burst above a slow reference (tau_ref = 7 d)")]:
        print(f"\n{title}\n")
        for regime in REGIMES:
            print(f"  regime = {regime}   (fee yield {FEE*REGIMES[regime][0]/V*YR*100:.1f}% APR, "
                  f"LVR {REGIMES[regime][1]**2/8*100:.1f}% APR)")
            print(f"  {'tau_L':>7} {'c':>8} {'E[A_pre]':>9} {'honest bps':>11} {'JIT m*':>8} {'JIT T*':>10} {'capture':>9}")
            print("  " + "-"*68)
            for tau_L,lbl in [(1/144,'10 min'),(1/24,'1 h'),(0.25,'6 h'),(1.0,'1 d'),(3.0,'3 d')]:
                Apre, Atw, rt, n = sim(tau_L, variant)
                for c in [0.02, 0.2, 2.0, 20.0]:
                    e,m,T,s = sniper(c, tau_L, Apre, regime, variant, Aref_lvl=0.0)
                    Ts = f"{T*1440:.0f} min" if T < 1 else f"{T:.0f} d"
                    print(f"  {lbl:>7} {c:>8} {Apre:>9.5f} {c*rt*10000:>11.2f} {m*100:>7.1f}% {Ts:>10} {s*100:>8.1f}%")
            print()
    print("BANK-RUN / EXIT-TRAP TEST (Variant A) -- exit cost as % of the leaver's own deposit")
    print(f"  {'exodus in tau_L':>16} " + " ".join(f"{'c='+str(c):>10}" for c in [0.02,0.2,2.0,20.0]))
    for frac in [0.10,0.25,0.50,0.90]:
        print(f"  {int(frac*100):>15}% " + " ".join(f"{c*frac*100:>9.2f}%" for c in [0.02,0.2,2.0,20.0]))

# ============================ THE FRONTIER ====================================================
def frontier():
    """For each Q/V, find the MINIMUM honest round-trip cost (bps) achieving a given JIT capture,
       searching (c, tau_L) jointly. Also reports which of the two channels binds."""
    print("\n" + "="*100)
    print("THE FRONTIER -- minimum honest LP round-trip cost (bps) for a given JIT confinement")
    print("  searched jointly over c in [1e-4, 50] (log grid, 120 pts) x tau_L in {10min,1h,6h,1d,3d}")
    print("="*100)
    global BIG_SWAP
    taus = [(1/144,'10min'),(1/24,'1h'),(0.25,'6h'),(1.0,'1d'),(3.0,'3d')]
    cache = {t:sim(t,"abs") for t,_ in taus}
    for regime in REGIMES:
        print(f"\n  regime = {regime}")
        print(f"  {'Q_big/V':>8} {'closed form':>12} | {'capture=0':>10} {'best(c,tau)':>16} | "
              f"{'capture<=10%':>13} {'best(c,tau)':>16}")
        print("  " + "-"*88)
        for qv in [0.05, 0.10, 0.25, 0.50, 1.00, 2.00]:
            BIG_SWAP = qv*V
            row = {}
            for target in [0.0, 0.10]:
                best = (1e18, None, None)
                for tau_L, lbl in taus:
                    Apre, Atw, rt, n = cache[tau_L]
                    cc = 1e-4
                    while cc <= 50:
                        e,m,T,s = sniper(cc, tau_L, Apre, regime)
                        if s <= target + 1e-12:
                            bps = cc*rt*10000
                            if bps < best[0]: best = (bps, cc, lbl)
                        cc *= 1.12
                row[target] = best
            cf = FEE*BIG_SWAP/V*10000     # closed form: honest_bps >= f*Q/V
            a, b = row[0.0], row[0.10]
            print(f"  {qv:>8.2f} {cf:>11.2f}b | {a[0]:>9.2f}b {f'c={a[1]:.3g},{a[2]}':>16} | "
                  f"{b[0]:>12.2f}b {f'c={b[1]:.3g},{b[2]}':>16}")
    BIG_SWAP = 1_000_000.0

def channel_test():
    """Which channel binds? Ambient (2cA, hits honest too) or self-term (c*m^2, honest escapes)?"""
    print("\n" + "="*100)
    print("WHICH CHANNEL DETERS? -- sniper's optimal WAIT T*, and whether waiting is free")
    print("="*100)
    for regime in REGIMES:
        dvol, sigma = REGIMES[regime]
        carry = (sigma*sigma/8.0 + R_CAPITAL)/YR - FEE*dvol/V
        print(f"  {regime:>8}: net carry while waiting = {carry*10000:+.3f} bps/day of position  "
              f"-> waiting is {'FREE (sniper earns while waiting)' if carry<=0 else 'COSTLY'}")
    print("\n  => in a HEALTHY pool the sniper waits ~3*tau_L for free, the c*m^2 self-term decays to")
    print("     e^-3 = 5% of itself, and ONLY the ambient channel 2*c*A can deter. The ambient channel")
    print("     charges honest LPs at the SAME rate it charges the sniper.")

if __name__ == "__main__":
    frontier(); channel_test()

def frontier_B():
    """Same frontier for Variant B (burst above slow ref) -- does decoupling beat f*Q/V?"""
    global BIG_SWAP
    taus=[(1/144,'10min'),(1/24,'1h'),(0.25,'6h'),(1.0,'1d'),(3.0,'3d'),(10.0,'10d')]
    cA={t:sim(t,"abs") for t,_ in taus}; cB={t:sim(t,"burst") for t,_ in taus}
    print("\n"+"="*100); print("VARIANT A vs VARIANT B frontier -- min honest bps for capture = 0")
    print("="*100)
    for regime in REGIMES:
        print(f"\n  regime = {regime}")
        print(f"  {'Q/V':>6} {'f*Q/V':>8} {'A: honest':>10} {'A: (c,tau)':>17} {'B: honest':>10} {'B: (c,tau)':>17}")
        print("  "+"-"*76)
        for qv in [0.10,0.25,0.50,1.00,2.00]:
            BIG_SWAP=qv*V; res={}
            for var,cache in [("abs",cA),("burst",cB)]:
                best=(1e18,None,None)
                for tau_L,lbl in taus:
                    Apre,_,rt,_=cache[tau_L]; cc=1e-4
                    while cc<=50:
                        e,m,T,s=sniper(cc,tau_L,Apre,regime,var)
                        if s<=1e-12 and cc*rt*10000<best[0]: best=(cc*rt*10000,cc,lbl)
                        cc*=1.12
                res[var]=best
            a,b=res["abs"],res["burst"]
            print(f"  {qv:>6.2f} {FEE*BIG_SWAP/V*1e4:>7.2f}b {a[0]:>9.2f}b {f'c={a[1]:.3g},{a[2]}':>17} "
                  f"{b[0]:>9.2f}b {f'c={b[1]:.3g},{b[2]}':>17}")
    BIG_SWAP=1_000_000.0

def cap_test():
    """Does capping A at A_max bound the bank-run cost WITHOUT losing deterrence?"""
    print("\n"+"="*100); print("EXIT-TRAP FIX -- cap A at A_max. Deterrence uses AMBIENT A (~0.002-0.08),")
    print("so a cap far above ambient costs nothing and bounds the run cost. (CLAUDE.md 5.3)")
    print("="*100)
    Apre,_,rt,_=sim(1/144,"abs")
    c=0.126   # the capture=0 optimum at Q/V=1.0, tau=10min, healthy
    print(f"  ambient A_pre = {Apre:.5f}   c = {c}   honest round trip = {c*rt*1e4:.2f} bps")
    print(f"  {'A_max':>8} {'x ambient':>10} {'deterrence kept':>16} {'worst-case exit cost':>21}")
    print("  "+"-"*58)
    for amax in [0.01,0.05,0.25,1.0,None]:
        eff=min(Apre,amax) if amax else Apre
        e,m,T,s=sniper(c,1/144,eff,'healthy')
        cost = f"{c*amax*100:.2f}% of deposit" if amax else "UNBOUNDED"
        print(f"  {str(amax):>8} {(amax/Apre if amax else float('inf')):>9.0f}x {('YES' if s<=1e-12 else f'NO ({s*100:.0f}%)'):>16} {cost:>21}")

if __name__ == "__main__":
    frontier_B(); cap_test()
