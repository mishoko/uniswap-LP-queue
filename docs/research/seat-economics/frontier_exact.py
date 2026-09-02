"""Does the closed form hold when some back seat is ALREADY above the LP bar?
   Lifting every back seat to >= LP costs  sum_i>=2 c_i * max(0, LP - r_i),
   which is >= sum_i>=2 c_i (LP - r_i) = c_1 (r_1 - LP).  The closed form is therefore
   EXACT only while EVERY back seat sits below LP, and OPTIMISTIC otherwise."""
import sys, numpy as np
sys.path.insert(0,"/Users/mishoko/projects/UHI10/docs/research/seat-economics")
from sim import run
BOOK,RPH,HALF=1_000_000.0,15.0,0.10
W=(5,4,3,2,1); SHIP=[BOOK*w/15.0 for w in W]; C=np.array(W,float)/sum(W)
SEEDS=list(range(0,30))+list(range(100,130))+list(range(200,230))+list(range(1000,1030))
B1={"BENIGN":0.0445,"NORMAL":0.0000,"TOXIC":-0.0218}   # best keeper (w=10%, own-conv) from audit
for name,vol,dr in (("BENIGN",0.25,0.0),("NORMAL",0.45,0.0),("TOXIC",0.80,0.35)):
    R=[];L=[]
    for s in SEEDS:
        bk,_,Pt=run(SHIP,True,days=365,retail_per_hr=RPH,seed=s,vol=vol,drift=dr,half=HALF,phi=0)
        bk.tie_out(Pt); d,h=bk.pnl(Pt); R.append(d/h)
        pb,_,P2=run([BOOK],False,days=365,retail_per_hr=RPH,seed=s,vol=vol,drift=dr,half=HALF)
        dp,hp=pb.pnl(P2); L.append(float(dp[0]/hp[0]))
    R=np.array(R); LP=float(np.mean(L)); r=R.mean(axis=0)
    naive = float(C[0]*(r[0]-LP))                              # closed form
    exact = float(np.sum(C[1:]*np.maximum(0.0, LP-r[1:])))     # what it ACTUALLY costs
    avail = float(C[0]*(r[0]-B1[name]))
    above = [i+2 for i,x in enumerate(r[1:]) if x > LP]
    print(f"\n{name}: LP {LP*100:+.3f}%  r1 {r[0]*100:+.3f}%  B1 {B1[name]*100:+.2f}%")
    print(f"   back seats ALREADY above LP: {above if above else 'none'}")
    print(f"   needed, closed form  c1(r1-LP)      = {naive*100:+.4f} pp")
    print(f"   needed, EXACT  sum c_i max(0,LP-r_i)= {exact*100:+.4f} pp   {'(SAME)' if abs(exact-naive)<1e-9 else '*** DIFFERS ***'}")
    print(f"   available      c1(r1-B1)            = {avail*100:+.4f} pp")
    print(f"   TRUE SLACK = available - EXACT      = {(avail-exact)*100:+.4f} pp of book"
          f"    -> {'WINDOW EXISTS' if avail-exact>0 else 'EMPTY'}")
