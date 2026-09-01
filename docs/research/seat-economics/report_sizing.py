import sys, os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import *
import numpy as np
BOOK, RPH, SEEDS = 1_000_000.0, 15.0, range(60)

def sweep(caps, vol, drift, marginal=True):
    caps=list(caps); acc=np.zeros(len(caps)); pra=[]
    for sd in SEEDS:
        bk,P,Pt = run(caps, marginal, days=365, retail_per_hr=RPH, seed=sd, vol=vol, drift=drift)
        d,h = bk.pnl(Pt); acc += d/h/(bk.hrs/(365*24))*100
        pb,_,Pt2 = run([sum(caps)], False, days=365, retail_per_hr=RPH, seed=sd, vol=vol, drift=drift)
        dp,hp = pb.pnl(Pt2); pra.append(dp[0]/hp[0]/(pb.hrs/(365*24))*100)
    return acc/len(SEEDS), float(np.mean(pra))

EQ   = [BOOK/32]*32                                    # what ships: equal seats
BIG  = [300_000.0] + [700_000.0/31]*31                 # head sized to swallow routine arbitrage
HUGE = [600_000.0] + [400_000.0/31]*31                 # head sized to swallow nearly all of it

print("="*94)
print("DOES SIZING THE HEAD REMOVE THE MIDDLE-OF-BOOK TRAP?  marginal pricing, 60 paths")
print("="*94)
for nm, vol, dr in (("BENIGN", 0.25, 0.0), ("NORMAL", 0.45, 0.0), ("TOXIC", 0.80, 0.35)):
    print(f"\n  ---- {nm} ----")
    for cname, caps in (("32 equal ($31k each)", EQ), ("head $300k + 31x$22.6k", BIG), ("head $600k + 31x$12.9k", HUGE)):
        r, pr = sweep(caps, vol, dr)
        mid = r[1:21]      # the seats the trap lives in
        print(f"  {cname:24} pro-rata {pr:+8.1f}% | head {r[0]:+9.1f}% | "
              f"worst of seats 2-21 {mid.min():+9.1f}% | seats>=pro-rata {int((r>pr).sum()):>2}/32")
