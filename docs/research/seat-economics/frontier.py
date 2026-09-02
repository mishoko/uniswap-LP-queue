"""THE FRONTIER, DERIVED ANALYTICALLY THEN CHECKED NUMERICALLY.

Let c_i = seat i's capital share, r_i = its return at phi=0, LP = pro-rata LP return,
B1 = rank 1's OWN bar (its best outside alternative).  The identity Sum c_i r_i == LP holds.

  available to take from seat 1   =  c_1 (r_1 - B1)
  needed to lift seats 2..N to LP =  Sum_{i>=2} c_i (LP - r_i)
                                  =  LP(1-c_1) - (LP - c_1 r_1)          [by the identity]
                                  =  c_1 (r_1 - LP)

  SLACK = c_1 (r_1 - B1) - c_1 (r_1 - LP) = c_1 (LP - B1)

r_1 CANCELS.  The entire surplus the mechanism can deliver is
      seat 1's capital share  x  (how much worse seat 1's alternative is than a passive LP).
No ordering rule, no phi, no roster depth can change it.  Check it numerically:"""
import sys, numpy as np
sys.path.insert(0, "/Users/mishoko/projects/UHI10/docs/research/seat-economics")
from sim import run

BOOK, RPH, HALF = 1_000_000.0, 15.0, 0.10
W = (5,4,3,2,1); SHIP=[BOOK*w/15.0 for w in W]; C=np.array(W,float)/sum(W)
SEEDS = list(range(0,30))+list(range(100,130))+list(range(200,230))+list(range(1000,1030))

for name, vol, dr in (("BENIGN",0.25,0.0),("NORMAL",0.45,0.0),("TOXIC",0.80,0.35)):
    R=[];L=[]
    for s in SEEDS:
        bk,_,Pt = run(SHIP,True,days=365,retail_per_hr=RPH,seed=s,vol=vol,drift=dr,half=HALF,phi=0)
        bk.tie_out(Pt); d,h = bk.pnl(Pt); R.append(d/h)
        pb,_,P2 = run([BOOK],False,days=365,retail_per_hr=RPH,seed=s,vol=vol,drift=dr,half=HALF)
        dp,hp = pb.pnl(P2); L.append(float(dp[0]/hp[0]))
    R=np.array(R); LP=float(np.mean(L)); r=R.mean(axis=0)
    need  = float(np.sum(C[1:]*(LP-r[1:])))          # computed the LONG way
    need2 = float(C[0]*(r[0]-LP))                    # the closed form
    print(f"\n{name}:  LP {LP*100:+.3f}%   r1 {r[0]*100:+.3f}%   back {[f'{x*100:+.2f}' for x in r[1:]]}")
    print(f"   needed to lift ALL back seats to LP:  long form {need*100:+.4f} pp   closed form {need2*100:+.4f} pp"
          f"   (agree to {abs(need-need2):.1e})")
    for lbl, B1 in (("keeper w=10% (its BEST)", None), ("passive LP itself", LP)):
        pass
    print(f"   SLACK = c1 x (LP - B1),  c1 = {C[0]:.4f}")
    for lbl, B1 in (("B1 = passive LP", LP), ("B1 = LP - 0.57pp (measured w=10% gap, BENIGN)", LP-0.0057)):
        sl = C[0]*(LP-B1)
        print(f"      {lbl:<46} slack {sl*100:+.4f} pp of book"
              f"   -> back can all sit at LP {sl/(1-C[0])*100:+.4f} pp")
