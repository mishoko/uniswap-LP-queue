import numpy as np, math, rotation as R
def run_weighted(caps, weights, days=365, seed=11, vol=0.25, retail_per_hr=15.0,
                 P0=2000.0, half=0.10, epoch_hours=4, drift=0.0):
    rng = np.random.default_rng(seed); n=len(caps); w=np.asarray(weights,float)
    slots = np.concatenate([[i]*int(round(v)) for i,v in enumerate(w)])
    P = Pt = P0; bk = R.Book(caps, P0, True, half)
    sd = vol/math.sqrt(365*24); hrs=0
    for h in range(days*24):
        hrs=h+1; ep=h//epoch_hours
        seq=[slots[(ep+k)%len(slots)] for k in range(len(slots))]
        seen,order=set(),[]
        for o in seq:
            if o not in seen: seen.add(o); order.append(o)
        bk.ord=np.array(order); bk.c0=bk.c1=0
        Pt *= math.exp(rng.normal(0,sd)+drift*sd)
        if not (P0*(1-half) < Pt < P0*(1+half)): break
        Pt=min(max(Pt,P0*(1-half)*1.0005),P0*(1+half)*0.9995)
        for _ in range(rng.poisson(retail_per_hr)):
            u=rng.random(); S=(100.0**-0.6+u*(10_000.0**-0.6-100.0**-0.6))**(-1/0.6)
            zfo=rng.random()<0.5; P=bk.swap(P, S/P if zfo else S, zfo)
        if   P > Pt*(1+R.FEE): zfo,tgt=True, Pt*(1+R.FEE)
        elif P < Pt*(1-R.FEE): zfo,tgt=False,Pt*(1-R.FEE)
        else: zfo=None
        if zfo is not None:
            s0,st=math.sqrt(P),math.sqrt(tgt)
            net=bk.L*(1/st-1/s0) if zfo else bk.L*(st-s0)
            if net>0: P=bk.swap(P, net/(1-R.FEE), zfo)
    bk.hrs=hrs; return bk,P,Pt
