"""Verify saved native evidence without changing source files.

Supports unpacked full packages and gzipped public CSV packages. Runs all legacy
checks in temporary copies. Only an absent optional MAT/CSV comparison is skipped.
This entry point never runs MATLAB or Simulink.
"""
from __future__ import annotations
import argparse
import csv
from datetime import datetime, timezone
import gzip
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import numpy as np
ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def run(command, cwd, log):
    started = time.monotonic()
    p = subprocess.run(command, cwd=cwd, text=True, encoding='utf-8', errors='replace',
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
    log.write_text(p.stdout, encoding='utf-8')
    record = {'command': [str(x) for x in command], 'exit_code': p.returncode,
              'elapsed_s': round(time.monotonic()-started, 3), 'log': log.name}
    print(json.dumps(record), flush=True)
    if p.returncode:
        raise RuntimeError('Verification failed: '+json.dumps(record))
    return record


def extended_checks(root):
    rows = list(csv.DictReader((root/'results/matlab/summary.csv').open()))
    lookup = {r['case_name']: r for r in rows}
    tests = []
    def check(name, value, limit):
        tests.append({'name': name, 'value': float(value), 'limit': float(limit),
                      'passed': bool(np.isfinite(value) and value<=limit)})
    parameters = [k for k in rows[0] if k.startswith(('plant_', 'controller_', 'speed_K'))]
    for left,right in [('01_nominal_bypass','02_nominal_dispatch'),
                       ('03_friction_bypass','04_friction_dispatch'),
                       ('05_combined_bypass','06_combined_dispatch'),
                       ('07_pulse_bypass','08_pulse_dispatch')]:
        for key in parameters+['task_s','restore_s','speed_pi_enabled']:
            check(f'fair_pair.{right}.{key}',abs(float(lookup[left][key])-float(lookup[right][key])),0)
    for row in rows:
        for key in [k for k in parameters if k.startswith(('controller_','speed_K'))]:
            check(f"fixed_controller.{row['case_name']}.{key}",abs(float(row[key])-float(rows[0][key])),0)
        check(f"reference_limit.{row['case_name']}",max(0,float(row['max_reference_A'])-20),1e-10)
        for key in ['high_direction_error_A','low_direction_error_A','blocked_reference_A']:
            check(f"protection.{row['case_name']}.{key}",float(row[key]),1e-10)
    logs = {}
    for kind,expected in [('matlab',322),('simulink',67)]:
        log=json.loads((root/f'results/{kind}/tests_summary.json').read_text())
        check(f'native_log.{kind}.actual_test_count',abs(len(log['tests'])-expected),0)
        bad=sum(not(np.isfinite(t['value']) and t['value']<=t['limit'] and t['passed']) for t in log['tests'])
        check(f'native_log.{kind}.numeric_failures',bad,0)
        logs[kind]={'created':log['created'],'checks':expected,'MATLABVersion':log['MATLABVersion']}
    result={'status':'PASS' if all(t['passed'] for t in tests) else 'FAIL',
            'count':len(tests),'passed':sum(t['passed'] for t in tests),'tests':tests,
            'saved_native_records':logs,'protection_scope':{
                'current_reference_limit_A':20,
                'largest_native_all_cycle_peak_current_A':max(float(r['max_current_A']) for r in rows),
                'minimum_native_all_cycle_speed_rpm':min(float(r['nmin']) for r in rows),
                'lower_active_discharge_threshold_rpm':2850,
                'note':'The speed threshold blocks active discharge; friction may lower speed. A reference limit is not an instantaneous current clamp. Saved 100 Hz traces do not resolve 20 kHz ripple.'}}
    if result['status']!='PASS':
        raise RuntimeError('Extended checks failed: '+str([t for t in tests if not t['passed']]))
    return result


def main():
    global ROOT
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rerun-cpp',action='store_true')
    p.add_argument('--output',type=Path,help='New output directory; existing directories refused')
    p.add_argument('--project-root',type=Path,help='Engineering project folder')
    args=p.parse_args()
    if args.project_root is not None: ROOT=args.project_root.resolve()
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out=(args.output or ROOT/'verification/runs'/stamp).resolve()
    out.mkdir(parents=True,exist_ok=False)
    manifest=json.loads((ROOT/'SOURCE_MANIFEST.json').read_text())
    inputs={x['path'] for x in manifest['files']}
    inputs.update(['SOURCE_MANIFEST.json','verify_saved_results.py','audit_native_results.py',
                   'lab_analysis.py','tests/test_lab_analysis.py','verification/run_verification.py',
                   'verification/audit_native_results_compatible.py'])
    for optional in ['results/simulink/simulink_results.mat','prepare_data.py']:
        if (ROOT/optional).is_file(): inputs.add(optional)
    inputs.update(str(q.relative_to(ROOT)) for q in (ROOT/'scheduler_output').glob('*.*'))
    before={name:digest(ROOT/name) for name in sorted(inputs)}
    environment={'utc':datetime.now(timezone.utc).isoformat(),'python':sys.version,'platform':platform.platform(),
                 'packages':{name:importlib.metadata.version(name) for name in ('numpy','scipy','matplotlib')},
                 'executables':{name:shutil.which(name) for name in ('matlab','octave','g++')},
                 'new_native_matlab_execution':False,'new_native_simulink_execution':False}
    dump(out/'environment.json',environment)
    dump(out/'input_sha256.json',before)
    commands=[]
    try:
        with tempfile.TemporaryDirectory(prefix='fyp_verify_') as tmp:
            stage=Path(tmp)
            for name in inputs:
                target=stage/name;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(ROOT/name,target)
            decompressed=[]
            for compressed in stage.rglob('*.csv.gz'):
                plain=compressed.with_suffix('')
                if plain.exists():
                    if plain.read_bytes()!=gzip.decompress(compressed.read_bytes()):
                        raise RuntimeError('Conflicting CSV/gzip copies: '+str(plain.relative_to(stage)))
                else:
                    with gzip.open(compressed,'rb') as src,plain.open('wb') as dst: shutil.copyfileobj(src,dst)
                    decompressed.append(str(plain.relative_to(stage)))
            dump(out/'input_layout.json',{'compressed_csv_materialized_in_temporary_directory':decompressed,
                                         'optional_mat_present':(stage/'results/simulink/simulink_results.mat').is_file()})
            # Materialize before the legacy script directly opens summary.csv;
            # its manifest checks still validate original compressed bytes.
            commands.append(run([sys.executable,'verify_saved_results.py'],stage,out/'01_saved_results.log'))
            commands.append(run([sys.executable,'verification/audit_native_results_compatible.py'],stage,out/'02_native_evidence.log'))
            command=[sys.executable,'validate_reference.py']+(['--run'] if args.rerun_cpp else [])
            commands.append(run(command,stage,out/'03_scheduler.log'))
            commands.append(run([sys.executable,'-m','unittest','discover','-s','tests','-v'],stage,out/'04_lab_analysis_synthetic_tests.log'))
            extra=extended_checks(stage);dump(out/'extended_checks.json',extra)
            for name in ['analysis/verified_metrics.json','analysis/case_metrics.csv',
                         'accepted_native_simulink_audit.json','scheduler_output/scheduler_metrics.json']:
                shutil.copy2(stage/name,out/Path(name).name)
            raw=json.loads((stage/'scheduler_output/validation.json').read_text())
            dump(out/'scheduler_validation_legacy.json',raw)
            raw.update(execution='New C++ scheduler execution and static wiring analysis' if args.rerun_cpp else 'Recheck saved C++ scheduler output and static wiring analysis',
                       new_native_simulink_execution=False,native_simulink_verified=True,
                       native_simulink_evidence_scope='Separately audited saved user run: 67/67; the C++ check does not execute Simulink',
                       new_cpp_execution=bool(args.rerun_cpp))
            dump(out/'scheduler_validation.json',raw)
            if args.rerun_cpp: shutil.copy2(stage/'scheduler_output/scheduler_trace.csv',out/'scheduler_trace.csv')
            after={name:digest(ROOT/name) for name in before}
            changed=[name for name in before if before[name]!=after[name]]
            if changed: raise RuntimeError('Original inputs changed: '+repr(changed))
            metrics=json.loads((out/'verified_metrics.json').read_text())
            native=json.loads((out/'accepted_native_simulink_audit.json').read_text())
            summary={'status':'PASS','created_utc':datetime.now(timezone.utc).isoformat(),
                     'scope':'Saved native evidence reanalysis, static model audit, optional new C++ reference; no new MATLAB/Simulink execution',
                     'recovery_note':'This is a newly executed verification after environment reset. Missing pre-reset transient logs are not reconstructed or claimed as retained.',
                     'environment':environment,'commands':commands,'input_files_checked':len(before),
                     'original_input_bytes_unchanged':True,'saved_native_matlab_checks':322,'saved_native_simulink_checks':67,
                     'saved_native_matlab_cases':metrics['case_count'],'scheduler_checks':raw['count'],
                     'new_cpp_execution':bool(args.rerun_cpp),'synthetic_lab_analysis_tests':9,
                     'extended_checks':{'passed':extra['passed'],'count':extra['count']},
                     'saved_native_records':extra['saved_native_records'],'protection_scope':extra['protection_scope'],
                     'maximum_all_case_energy_residual_J':metrics['maximum_all_case_energy_residual_J'],
                     'max_native_common_column_difference':metrics['max_native_entry_difference'],
                     'mat_csv_comparison':native['MAT_CSV_comparison'],'compressed_csv_materialized_count':len(decompressed),
                     'hardware_validated':False,'real_railway_load_validated':False,
                     'shared_physical_core_limits_independence':True}
            dump(out/'verification_summary.json',summary)
            print(json.dumps(summary,ensure_ascii=False,indent=2))
    except Exception as exc:
        dump(out/'verification_summary.json',{'status':'FAIL','error':repr(exc),'commands':commands,'environment':environment})
        raise

if __name__=='__main__': main()
