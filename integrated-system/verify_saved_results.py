"""Recompute all saved-run energy accounts. This does not execute MATLAB."""
from pathlib import Path
import csv, gzip, hashlib, json
import numpy as np

ROOT = Path(__file__).resolve().parent

def read(name):
    p = ROOT / name
    if not p.exists(): p = p.with_suffix(p.suffix + '.gz')
    return np.genfromtxt(p, delimiter=',', names=True, encoding='utf-8-sig')

def main():
    manifest = json.loads((ROOT / 'SOURCE_MANIFEST.json').read_text())
    for f in manifest['files']:
        data = (ROOT / f['path']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == f['sha256'], f['path']
        original = gzip.decompress(data) if f['path'].endswith('.gz') else data
        assert hashlib.sha256(original).hexdigest() == f['original_sha256'], f['path']
    with (ROOT / 'results/matlab/summary.csv').open() as f:
        summaries = list(csv.DictReader(f))
    outputs, traces = [], {}
    for row in summaries:
        name = row['case_name']; d = read('results/matlab/' + name + '.csv')
        traces[name] = d
        assert all(np.isfinite(d[k]).all() for k in d.dtype.names), name
        t = d['t_s']; assert np.all(np.diff(t) > 0) and abs(t[0]) < 1e-12
        assert abs(t[-1] - float(row['task_s']) - float(row['restore_s'])) < 1e-8
        assert np.max(abs(np.diff(t) - .01)) < 1e-9
        J, L, C = (float(row['plant_' + k]) for k in ['J','L','C'])
        stored = .5 * (J*d['omega_rad_s']**2 + L*d['i_A']**2 + C*d['Vdc_V']**2)
        losses = sum(d[k] for k in ['Wline_J','Wchopper_J','Wconverter_J','Wcopper_J','Wviscous_J','Wcoulomb_J'])
        residual = stored-stored[0]-d['Wsource_J']+d['Wload_J']+losses
        identities = {
            'energy_balance_J': float(np.max(abs(residual))),
            'converter_balance_J': float(np.max(abs(d['Wfess_J']-d['Wterminal_J']-d['Wconverter_J']))),
            'motor_balance_J': float(np.max(abs(d['Wterminal_J']-d['Wcopper_J']-d['Wem_J']-d['Emag_J']+d['Emag_J'][0]))),
            'credit_balance_J': float(np.max(abs(d['recovery_credit_J']-d['credited_J']+d['spent_J']+d['leaked_J']))),
        }
        assert identities['energy_balance_J'] < 1e-4, (name, identities)
        assert max(v for k,v in identities.items() if k != 'energy_balance_J') < 1e-7
        assert abs(d['Wsource_J'][-1]-float(row['total_source_J'])) < 1e-6
        assert np.max(abs(stored-(d['Erot_J']+d['Emag_J']+d['Ecap_J']))) < 1e-7
        task_end = np.flatnonzero(abs(t-float(row['task_s'])) < 1e-9)[0]
        task = slice(0, task_end); v=d['Vdc_V'][task]; vs=float(row['plant_Vs'])
        # These are 100 Hz sample-based measures, not PWM ripple/step-response tests.
        vrms=float(np.sqrt(np.mean((v-vs)**2)))
        error=d['cycle_mean_i_A'][task]-d['iref_A'][task]
        irmse=float(np.sqrt(np.mean(error**2)))
        settle=None
        if float(row['restore_s'])>0:
            post=np.arange(task_end,len(t)); outside=post[abs(d['rpm'][post]-3000)>30]
            index=task_end if len(outside)==0 else int(outside[-1])+1
            if index<len(t): settle=float(t[index]-float(row['task_s']))
        outputs.append({'case':name,'rows':len(d),**identities,
            'task_voltage_min_V':float(v.min()),'task_voltage_max_V':float(v.max()),
            'task_voltage_rms_deviation_from_source_V':vrms,
            'task_cycle_mean_current_tracking_rmse_A':irmse,
            'restoration_within_1_percent_s':settle,
            'task_source_J':float(d['Wsource_J'][task_end]),
            'restore_source_J':float(d['Wsource_J'][-1]-d['Wsource_J'][task_end]),
            'source_total_J':float(d['Wsource_J'][-1]),
            'task_charge_J':float(d['Wcharge_J'][task_end]),'task_return_J':float(d['Wreturn_J'][task_end]),
            'task_net_regeneration_J':float(d['Wregen_J'][task_end]),
            'task_chopper_J':float(d['Wchopper_J'][task_end]),
            'all_cycle_min_rpm':float(row['nmin']),'all_cycle_peak_current_A':float(row['max_current_A']),
            'final_rpm':float(d['rpm'][-1])})
    native=read('results/simulink/simulink_trace.csv'); matlab=traces['06_combined_dispatch']
    diffs={k:float(np.max(abs(native[k]-matlab[k]))) for k in matlab.dtype.names}
    assert len(native)==9001 and len(diffs)==48 and max(diffs.values())<1e-6
    pairs=[]
    for base,active,label in [('01_nominal_bypass','02_nominal_dispatch','nominal'),
        ('03_friction_bypass','04_friction_dispatch','friction_high'),
        ('05_combined_bypass','06_combined_dispatch','combined_corner'),
        ('07_pulse_bypass','08_pulse_dispatch','pulse_combined')]:
        b,a=traces[base],traces[active]
        assert np.array_equal(b['t_s'],a['t_s']) and np.max(abs(b['Pload_W']-a['Pload_W']))<1e-9
        for k in ['i_A','omega_rad_s','Vdc_V']:
            assert abs(b[k][0]-a[k][0])<1e-10
        gaps={k:float(abs(b[k][-1]-a[k][-1])) for k in ['Erot_J','Emag_J','Ecap_J']}
        assert max(gaps.values())<1e-4
        delta=float(b['Wsource_J'][-1]-a['Wsource_J'][-1])
        end=2000; task=float(b['Wsource_J'][end]-a['Wsource_J'][end])
        pairs.append({'case':label,'baseline':base,'active':active,'baseline_source_J':float(b['Wsource_J'][-1]),
            'dispatch_source_J':float(a['Wsource_J'][-1]),'source_reduction_J':delta,
            'source_reduction_percent':100*delta/float(b['Wsource_J'][-1]),
            'task_source_reduction_J':task,'restoration_source_reduction_J':delta-task,
            'terminal_component_gaps_J':gaps})
    for name,count in [('matlab',322),('simulink',67)]:
        log=json.loads((ROOT/f'results/{name}/tests_summary.json').read_text())
        assert log['all_passed'] and log['passed']==log['count']==count
        assert all(x['passed'] for x in log['tests'])
    # Source snapshots must be the exact files that generated the native evidence.
    for x,y in [('FYP_SimulinkSystem_v1.m','results/simulink/SourceSnapshot.m'),
                ('accepted_core/FYP_EnergyDispatch_v1.m','results/matlab/SourceSnapshot.m')]:
        assert (ROOT/x).read_bytes()==(ROOT/y).read_bytes()
    report={'status':'PASS','execution':'Python reanalysis of saved native runs; no new MATLAB/Simulink execution',
        'case_count':len(outputs),'manifest_files_verified':len(manifest['files']),
        'native_checks':{'MATLAB':322,'Simulink':67},'native_trace_rows':len(native),
        'common_columns':len(diffs),'max_native_entry_difference':max(diffs.values()),
        'maximum_all_case_energy_residual_J':max(x['energy_balance_J'] for x in outputs),
        'metric_resolution_s':.01,'restoration_band_rpm':[2970,3030],
        'restoration_definition':'Earliest logged time after 20 s remaining in the band for every later logged point through 90 s. Not a current-loop step settling time.',
        'voltage_definition':'RMS departure from the configured source voltage on uniformly spaced 100 Hz samples with 0 <= t < 20 s. The restoration transition at 20 s is excluded. No acceptance limit assumed.',
        'cases':outputs,'pairs':pairs,'hardware_validation':False}
    out=ROOT/'analysis';out.mkdir(exist_ok=True)
    (out/'verified_metrics.json').write_text(json.dumps(report,indent=2)+'\n')
    with (out/'case_metrics.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(outputs[0]),lineterminator='\n');w.writeheader();w.writerows(outputs)
    print(json.dumps({k:report[k] for k in ['status','case_count','manifest_files_verified','maximum_all_case_energy_residual_J']}))
    return report

if __name__=='__main__':main()
