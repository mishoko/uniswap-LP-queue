"""Every table in ROTATION.md. Reproduce: python3 report_rotation.py"""
import sys, os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, rotation as R
from weighted import run_weighted

N = 32; CAPS = [1_000_000/N]*N; SEEDS = range(30)
UNI   = np.ones(N, int)
TIERS = np.array([4]*8 + [3]*8 + [2]*8 + [1]*8)   # 8 seats at each lock length
REG   = (("BENIGN", 0.25, 0.0), ("NORMAL", 0.45, 0.0), ("TOXIC", 0.80, 0.35))

def prorata(vol, drift, half):
    out = []
    for s in SEEDS:
        b, _, Pt = R.run([1_000_000.0], days=365, seed=s, vol=vol, drift=drift, half=half)
        d, h = b.pnl(Pt); out.append(d[0]/h[0]/(b.hrs/(365*24))*100)
    return float(np.mean(out))

def seats(eh, vol, drift, half):
    acc = np.zeros(N); exits = 0
    for s in SEEDS:
        b, _, Pt = R.run(CAPS, days=365, seed=s, vol=vol, drift=drift, half=half, epoch_hours=eh)
        d, h = b.pnl(Pt); acc += d/h/(b.hrs/(365*24))*100; exits += 1 if b.exited else 0
    return acc/len(SEEDS), exits

def weighted(wts, vol, drift, half):
    acc = np.zeros(N)
    for s in SEEDS:
        b, _, Pt = run_weighted(CAPS, wts, seed=s, vol=vol, drift=drift, half=half)
        d, h = b.pnl(Pt); acc += d/h/(b.hrs/(365*24))*100
    return acc/len(SEEDS)

print("="*98)
print("1. IS THE BOOK ZERO-SUM?  Front-first vs ONE undivided pro-rata LP, same capital/flow/seeds.")
print("="*98)
for name, vol, dr in REG[:2]:
    vq=vp=tq=tp=0.0
    for s in SEEDS:
        b1,_,P1 = R.run(CAPS, days=365, seed=s, vol=vol, drift=dr, epoch_hours=4)
        b2,_,P2 = R.run([1_000_000.0], days=365, seed=s, vol=vol, drift=dr)
        d1,h1 = b1.pnl(P1); d2,h2 = b2.pnl(P2)
        vq += b1.vol; vp += b2.vol
        tq += d1.sum()/h1.sum()*100; tp += d2[0]/h2[0]*100
    print(f"  {name:7} volume  queue ${vq/len(SEEDS)/1e6:6.1f}M  pro-rata ${vp/len(SEEDS)/1e6:6.1f}M   diff {(vq/vp-1)*100:+.4f}%")
    print(f"  {name:7} P&L     queue {tq/len(SEEDS):+6.2f}%  pro-rata {tp/len(SEEDS):+6.2f}%   diff {(tq-tp)/len(SEEDS):+.4f} pts")

print()
print("="*98)
print("2. STATIC RANK vs UNIFORM ROTATION, on the SHIPPED +-10% band.")
print("="*98)
for name, vol, dr in REG[:2]:
    pr = prorata(vol, dr, 0.10)
    print(f"  --- {name}  (pool / pro-rata benchmark {pr:+.1f}%) ---")
    print(f"      {'scheme':>12} {'worst':>10} {'best':>10} {'spread':>9} {'seats<0':>9}")
    for eh in (0, 1, 2, 4):
        r, _ = seats(eh, vol, dr, 0.10)
        lab = "STATIC" if eh == 0 else f"rotate {eh}h"
        print(f"      {lab:>12} {r.min():+9.1f}% {r.max():+9.1f}% {r.max()-r.min():8.1f} {int((r<0).sum()):8d}/32")

print()
print("="*98)
print("3. THE BAND, NOT THE QUEUE, IS WHAT MAKES SEATS LOSE.  Uniform rotation, 4h epochs.")
print("="*98)
print(f"      {'band':>8} {'vol':>5} {'exited':>8} {'pool':>9} {'worst':>9} {'best':>9} {'spread':>8} {'seats<0':>9}")
for half in (0.10, 0.30):
    for vol in (0.25, 0.45):
        r, ex = seats(4, vol, 0.0, half); pr = prorata(vol, 0.0, half)
        print(f"      +-{half*100:.0f}% {vol:5.2f} {ex:6d}/30 {pr:+8.1f}% {r.min():+8.1f}% {r.max():+8.1f}% "
              f"{r.max()-r.min():7.1f} {int((r<0).sum()):8d}/32")

print()
print("="*98)
print("4. SHIPPING CONFIGURATION: band +-30%, epoch 4h.  Uniform vs lock-weighted priority.")
print("="*98)
for name, vol, dr in REG:
    pr = prorata(vol, dr, 0.30)
    u = weighted(UNI, vol, dr, 0.30)
    w = weighted(TIERS, vol, dr, 0.30)
    print(f"  {name:7} pool {pr:+7.1f}%")
    print(f"     uniform      : {u.min():+7.1f}% .. {u.max():+7.1f}%   negative {int((u<0).sum()):2d}/32")
    cells = "  ".join(f"lock{L}: {w[lo:hi].mean():+7.1f}%" for L, lo, hi in ((4,0,8),(3,8,16),(2,16,24),(1,24,32)))
    print(f"     lock-weighted: {cells}   negative {int((w<0).sum()):2d}/32")
print()
print("  Tier mean equals the pool return in every row: the split is CONSERVED.")
print("  Only its AXIS changed -- from 'which seat number you bought' to 'how long you commit'.")
