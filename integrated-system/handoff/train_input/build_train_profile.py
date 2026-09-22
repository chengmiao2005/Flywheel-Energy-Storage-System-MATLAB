"""Reconstruct inherited synthetic nominal trains, then energy-preserving bins.

Run beside inherited_train_config.json. No MATLAB execution is claimed.
The saved nominal MATLAB aggregates are independent regression anchors.
"""
from pathlib import Path
import json
import numpy as np

HERE = Path(__file__).resolve().parent


def train(c, cycles):
    p = c['Train']; dt = c['train_dt_s']
    def resistance(v):
        u = v * 3.6
        return (p['resA'] + p['resB']*u + p['resC']*u*u)*p['mass']*p['g']/1000
    def need(v, vn, h):
        vm = (v+vn)/2
        return (p['mass']*(vn-v)/h + resistance(vm))*vm
    mech_limit = p['etaT']*(p['PbusMax']-p['Paux'])
    t = x = v = 0.; rows = []
    for peak, acc, cruise, dec, dwell in cycles:
        target = peak/3.6
        for phase in range(1, 5):
            remaining = cruise if phase == 2 else dwell if phase == 4 else 0.
            phase_start = t
            while True:
                if phase == 1 and v >= target-1e-10: break
                if phase == 3 and v <= 1e-10: break
                if phase in (2, 4) and remaining <= 1e-10: break
                assert t-phase_start < 1000
                h = min(dt, remaining) if phase in (2,4) else dt
                if phase == 1:
                    vn = min(v+acc*h, target)
                    if need(v, vn, h) > mech_limit:
                        lo = max(0., v-resistance(v)*h/p['mass']); hi = vn
                        assert need(v, lo, h) <= mech_limit
                        for _ in range(50):
                            mid = (lo+hi)/2
                            if need(v, mid, h) > mech_limit: hi = mid
                            else: lo = mid
                        vn = lo
                elif phase == 2: vn = v
                elif phase == 3:
                    h = min(h, v/dec); vn = max(v-dec*h, 0.)
                else: vn = 0.
                vm = (v+vn)/2; resist = resistance(vm)
                force = p['mass']*(vn-v)/h + resist
                traction = max(force*vm,0.); braking = max(-force*vm,0.)
                assert traction <= mech_limit+1e-5
                electrical = min(braking,(p['PbusMax']+p['Paux'])/p['etaR']) if vm >= p['vRegenMin'] else 0.
                power = traction/p['etaT']-p['etaR']*electrical+p['Paux']
                xn = x+vm*h
                rows.append((t,h,power,xn,vn))
                t += h; x = xn; v = vn
                if phase in (2,4): remaining -= h
    return np.asarray(rows)


def build(bin_s=None, write=True):
    c = json.loads((HERE/'inherited_train_config.json').read_text())
    cycles = []
    for distance, ceiling, acc, dec, dwell in c['Route']:
        peak = ceiling
        a = train(c,[(peak,acc,0.,dec,0.)])
        if a[-1,3] > distance:
            lo = 0.; hi = ceiling
            for _ in range(40):
                mid = (lo+hi)/2
                if train(c,[(mid,acc,0.,dec,0.)])[-1,3] > distance: hi = mid
                else: lo = mid
            peak = lo; a = train(c,[(peak,acc,0.,dec,0.)])
        cruise_distance = distance-a[-1,3]
        assert cruise_distance >= -1e-7
        cycles.append((peak,acc,max(cruise_distance,0)/(peak/3.6),dec,dwell))
    a = train(c,cycles); finish = a[-1,0]+a[-1,1]
    edges_a = np.r_[a[:,0],finish]
    edges = np.unique(np.r_[edges_a,edges_a+c['offset_s']])
    t = edges[:-1]; h = np.diff(edges)
    def lookup(q,shift):
        shifted_edges = edges_a+shift
        ix = np.searchsorted(shifted_edges,q,side='right')-1
        valid = (q>=shifted_edges[0])&(q<shifted_edges[-1])
        v = np.zeros_like(q); v[valid] = a[ix[valid],2]
        return v
    pa = lookup(t,0.); pb = lookup(t,c['offset_s'])
    demand = np.maximum(pa,0)+np.maximum(pb,0)
    regen = np.maximum(-pa,0)+np.maximum(-pb,0)
    net = demand-regen
    actual = dict(duration_s=float(edges[-1]),
        gross_demand_kWh=float(demand@h/3.6e6),
        offered_regen_kWh=float(regen@h/3.6e6),
        direct_exchange_kWh=float(np.minimum(demand,regen)@h/3.6e6))
    differences = {k:abs(v-c['expected_'+k]) for k,v in actual.items()}
    assert differences['duration_s'] < 1e-7, differences
    assert max(v for k,v in differences.items() if k!='duration_s') < 1e-6, differences
    # Retain every sign change. Binning cannot cancel demand with regen.
    sign_edges = t[1:][np.sign(net[1:]) != np.sign(net[:-1])]
    width = c['rail_bin_s'] if bin_s is None else bin_s
    be = np.unique(np.r_[np.arange(0,edges[-1],width), sign_edges, edges[-1]])
    # Exact cumulative integral of the inherited piecewise-constant trace.
    cumulative = np.r_[0.,np.cumsum(net*h)]
    integral = np.interp(be,edges,cumulative)
    averaged = np.diff(integral)/np.diff(be)
    alpha = c['power_ratio']; beta = c['time_ratio']
    profile = np.c_[be[:-1]*beta,np.diff(be)*beta,averaged*alpha,be[:-1],averaged]
    coarse_net = float(averaged@np.diff(be))
    pos_error = abs(np.maximum(averaged,0)@np.diff(be)-np.maximum(net,0)@h)
    neg_error = abs(np.maximum(-averaged,0)@np.diff(be)-np.maximum(-net,0)@h)
    assert max(pos_error,neg_error,abs(coarse_net-net@h))<1e-3
    meta = dict(scope=c['scope'], source_sha256=c['source_sha256'],
        original_rows=len(t),replay_rows=len(profile),rail_bin_s=width,
        alpha_power=alpha,beta_time=beta,energy_ratio=alpha*beta,
        actual=actual,archive_differences=differences,
        positive_energy_resample_error_J=float(pos_error),
        negative_energy_resample_error_J=float(neg_error),
        lab_duration_s=float(be[-1]*beta),lab_peak_demand_W=float(max(averaged)*alpha),
        lab_peak_regen_W=float(-min(averaged)*alpha),
        lab_demand_J=float(np.maximum(averaged,0)@np.diff(be)*alpha*beta),
        lab_regen_J=float(np.maximum(-averaged,0)@np.diff(be)*alpha*beta))
    if write:
        np.savetxt(HERE/'train_replay.csv',profile,delimiter=',',fmt='%.17g',comments='',
                   header='t_start_s,duration_s,p_load_W,rail_t_start_s,rail_net_W')
        (HERE/'train_profile_provenance.json').write_text(json.dumps(meta,indent=2)+'\n')
    return profile, meta


if __name__ == '__main__':
    _, meta = build()
    print(json.dumps(meta,indent=2))
