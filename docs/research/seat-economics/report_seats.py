import sys, os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import *
import numpy as np

BOOK, RPH, SEEDS = 1_000_000.0, 15.0, range(60)
EQ  = [BOOK/32]*32

def sweep(vol, drift, marginal, caps=EQ):
    acc = np.zeros(len(caps)); pra=[]; lives=[]
    for sd in SEEDS:
        bk,P,Pt = run(caps, marginal, days=365, retail_per_hr=RPH, seed=sd, vol=vol, drift=drift)
        d,h = bk.pnl(Pt); yr = bk.hrs/(365*24)
        acc += d/h/yr*100
        pb,_,Pt2 = run([sum(caps)], False, days=365, retail_per_hr=RPH, seed=sd, vol=vol, drift=drift)
        dp,hp = pb.pnl(Pt2); pra.append(dp[0]/hp[0]/(pb.hrs/(365*24))*100); lives.append(yr*365)
    return acc/len(SEEDS), float(np.mean(pra)), float(np.mean(lives))

REG = (("BENIGN", 0.25, 0.0), ("NORMAL", 0.45, 0.0), ("TOXIC", 0.80, 0.35))
print("="*100)
print("PER-SEAT RETURN, %/yr WHILE IN BAND.  32 equal seats of $31,250 on a $1M book, 60 price paths.")
print("="*100)
res = {}
for name, vol, dr in REG:
    for m in (False, True):
        r, pr, life = sweep(vol, dr, m)
        res[(name,m)] = (r, pr, life)

hdr = f"  {'':22}" + "".join(f"{n:>16}" for n,_,_ in REG)
print(hdr)
print(f"  {'in-band life (days)':22}" + "".join(f"{res[(n,True)][2]:>16.1f}" for n,_,_ in REG))
print(f"  {'ordinary pro-rata LP':22}" + "".join(f"{res[(n,True)][1]:>+15.1f}%" for n,_,_ in REG))
print()
for label, m in (("AVERAGE pricing (old)", False), ("MARGINAL pricing (new)", True)):
    print(f"  --- {label} ---")
    for i,tag in ((0,"seat 1  (head)"),(4,"seat 5"),(9,"seat 10"),(14,"seat 15"),(19,"seat 20"),(31,"seat 32 (tail)")):
        print(f"  {tag:22}" + "".join(f"{res[(n,m)][0][i]:>+15.1f}%" for n,_,_ in REG))
    beat = [int((res[(n,m)][0] > res[(n,m)][1]).sum()) for n,_,_ in REG]
    print(f"  {'seats beating pro-rata':22}" + "".join(f"{b:>15}/32" for b in beat))
    print(f"  {'HEAD beats pro-rata?':22}" + "".join(
        f"{('YES' if res[(n,m)][0][0] > res[(n,m)][1] else 'no'):>16}" for n,_,_ in REG))
    print()

print("="*100)
print("THE TAIL'S ACTUAL INCOME IS RENT, NOT FLOW. What Harberger can move backward, by tau.")
print("="*100)
r, pr, _ = res[("NORMAL", True)]
A = (r[0] - pr)/100 * (BOOK/32)          # the head's advantage over simply LPing, $/yr
print(f"  head's advantage over an ordinary LP position (NORMAL, marginal): ${A:,.0f}/yr")
print(f"  tail capital (seats 2..32): ${BOOK*31/32:,.0f}")
print()
print(f"  {'tau':>6} {'theta=tau/(tau+k)':>20} {'self-price A/(tau+k)':>22} {'rent $/yr':>12} {'tail coupon':>12}")
for tau in (0.10, 0.25, 0.50, 1.00):
    k = 0.20
    P = A/(tau+k); rent = tau*P
    print(f"  {tau:>5.0%} {tau/(tau+k):>19.0%} {P:>22,.0f} {rent:>12,.0f} {rent/(BOOK*31/32):>11.1%}")
print()
print("  k = 20%/yr discount rate. tau is a CONSTRUCTOR ARGUMENT; the deploy script ships 10%.")
