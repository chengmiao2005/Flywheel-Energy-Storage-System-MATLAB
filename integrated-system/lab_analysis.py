"""Offline analysis of future synchronized measurements. No hardware control.

Power is linearly interpolated between samples. Sampled V*I is not a
switching-waveform reconstruction. All example fixtures in tests are synthetic.
"""
from pathlib import Path
import argparse, csv, hashlib, json
import numpy as np
from scipy.optimize import nnls

def checked_vectors(t, *values):
    a=[np.asarray(x,dtype=float) for x in (t,)+values]
    if a[0].ndim!=1 or len(a[0])<3 or any(x.shape!=a[0].shape for x in a):
        raise ValueError('At least three equally sized one-dimensional vectors are required.')
    if not all(np.isfinite(x).all() for x in a) or not np.all(np.diff(a[0])>0):
        raise ValueError('Samples must be finite, synchronized and strictly increasing in time.')
    return a

def split_energy(t,power):
    t,p=checked_vectors(t,power);dt=np.diff(t);a,b=p[:-1],p[1:]
    plus=np.zeros(len(dt));minus=np.zeros(len(dt))
    up=(a>=0)&(b>=0);down=(a<=0)&(b<=0);cross=~(up|down)
    plus[up]=.5*(a[up]+b[up])*dt[up]
    minus[down]=-.5*(a[down]+b[down])*dt[down]
    # Split crossing intervals into triangles at the interpolated zero.
    f=np.zeros(len(dt));f[cross]=abs(a[cross])/(abs(a[cross])+abs(b[cross]))
    first=.5*abs(a)*dt*f;second=.5*abs(b)*dt*(1-f)
    plus[cross]=np.where(a[cross]>0,first[cross],second[cross])
    minus[cross]=np.where(a[cross]<0,first[cross],second[cross])
    return np.r_[0,np.cumsum(plus)],np.r_[0,np.cumsum(minus)]

def analyze(t,v,current,rpm,inertia,meta):
    t,v,i,n=checked_vectors(t,v,current,rpm)
    if not np.isfinite(inertia) or inertia<=0:raise ValueError('Measured total inertia must be positive.')
    if np.any(v<=0) or np.any(n<0):raise ValueError('This analyzer assumes positive bus voltage and nonnegative rotation.')
    win,wout=split_energy(t,v*i);e=.5*inertia*(n*2*np.pi/60)**2
    dt=np.diff(t);reason=[];eta=None
    for key in ['complete_cycle','boundary_complete','calibration_confirmed']:
        if meta.get(key) is not True:reason.append(key+' is not confirmed')
    other=meta.get('other_stored_energy_change_J');tol=meta.get('terminal_energy_tolerance_J')
    drift=None
    if not isinstance(other,(int,float)) or not np.isfinite(other):reason.append('other internal stored-energy change is unknown')
    else:drift=float(e[-1]-e[0]+other)
    if not isinstance(tol,(int,float)) or not np.isfinite(tol) or tol<=0:reason.append('positive terminal-energy tolerance is missing')
    elif drift is not None and abs(drift)>tol:reason.append('terminal stored energy is not matched')
    current_tol=meta.get('endpoint_current_tolerance_A')
    if not isinstance(current_tol,(int,float)) or not np.isfinite(current_tol) or current_tol<0:
        reason.append('endpoint current tolerance is missing')
    elif max(abs(i[0]),abs(i[-1]))>current_tol:reason.append('endpoints are not at low branch current')
    if win[-1]<=0 or wout[-1]<=0:reason.append('both charging and discharging are required')
    elif wout[-1]>win[-1]:reason.append('apparent efficiency exceeds one; review boundary, terminal state and measurement uncertainty')
    if not reason:eta=float(wout[-1]/win[-1])
    out={'input_type':meta.get('input_type','unclassified measurement file'),
        'samples':len(t),'duration_s':float(t[-1]-t[0]),'median_interval_s':float(np.median(dt)),
        'max_interval_s':float(max(dt)),'max_gap_over_median':float(max(dt)/np.median(dt)),
        'energy_into_branch_J':float(win[-1]),'energy_out_of_branch_J':float(wout[-1]),
        'rotor_energy_change_J':float(e[-1]-e[0]),
        'net_input_minus_rotor_change_J':float(win[-1]-wout[-1]-e[-1]+e[0]),
        'terminal_total_energy_change_J':drift,'round_trip_efficiency':eta,'withheld_reasons':reason,
        'limitations':['No automatic correction of offsets or clock skew.','Remainder includes unmeasured electrical storage and measurement error; it is not automatically total loss.',
            'Matched endpoints alone do not validate a sensor or establish a confidence interval.','Linear sampled power cannot establish PWM ripple or sub-sample response.']}
    return np.column_stack([t,v*i,win,wout,e]),out

def identify_coastdown(t,rpm,inertia,motor_current,conditions):
    t,n,i=checked_vectors(t,rpm,motor_current)
    if conditions.get('no_external_torque') is not True or conditions.get('motor_electrically_isolated') is not True:
        raise ValueError('Coast-down requires documented isolation and absence of applied torque.')
    limit=conditions.get('motor_current_tolerance_A')
    if not isinstance(limit,(int,float)) or not np.isfinite(limit) or limit<0 or max(abs(i))>limit:
        raise ValueError('Motor current must be measured and within the stated zero-current tolerance.')
    if not np.isfinite(inertia) or inertia<=0 or np.any(n<=0):raise ValueError('Positive inertia and positive rotation are required.')
    w=n*2*np.pi/60;tt=t-t[0]
    if (w.max()-w.min())/w.max()<.05:raise ValueError('At least 5% speed span is required for this two-parameter fit.')
    area=np.r_[0,np.cumsum(.5*(w[1:]+w[:-1])*np.diff(t))]
    X=np.column_stack([area[1:],tt[1:]]);y=inertia*(w[0]-w[1:]);scale=np.linalg.norm(X,axis=0)
    cond=float(np.linalg.cond(X/scale))
    if not np.isfinite(cond) or cond>1000:raise ValueError('Poorly conditioned friction fit. Collect a wider speed range.')
    scaled,_=nnls(X/scale,y);b,Tc=scaled/scale
    res=y-X@np.array([b,Tc])
    return {'b_Nm_s_rad':float(b),'Tc_Nm':float(Tc),'normalized_design_condition':cond,
        'integral_residual_rmse_Nm_s':float(np.sqrt(np.mean(res**2))),
        'scope':'Positive-speed viscous+Coulomb fit conditional on supplied inertia. No statistical confidence interval. Validate on a separate coast-down.'}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('csv');ap.add_argument('--inertia',type=float,required=True)
    ap.add_argument('--metadata',required=True);ap.add_argument('--output',required=True);args=ap.parse_args()
    file=Path(args.csv);meta=json.loads(Path(args.metadata).read_text())
    with file.open(encoding='utf-8-sig',newline='') as f:
        rows=list(csv.DictReader(f))
    keys=['time_s','V_bus_V','I_fess_bus_A','n_rpm']
    vectors=[[float(r[k]) for r in rows] for k in keys]
    data,report=analyze(*vectors,args.inertia,meta)
    report['input_sha256']=hashlib.sha256(file.read_bytes()).hexdigest();report['metadata']=meta
    target=Path(args.output);target.mkdir(parents=True,exist_ok=False)
    np.savetxt(target/'energy_series.csv',data,delimiter=',',header='time_s,power_W,energy_in_J,energy_out_J,rotor_energy_J',comments='')
    (target/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
