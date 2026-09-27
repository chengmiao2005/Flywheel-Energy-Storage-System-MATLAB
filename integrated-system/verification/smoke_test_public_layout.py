"""Run the real verifier on a temporary compressed-CSV/no-MAT layout.
This fixture is simulated from the complete package, not fetched from GitHub.
"""
from __future__ import annotations
import argparse,gzip,hashlib,json
from pathlib import Path
import subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
def sha(data):return hashlib.sha256(data).hexdigest()
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();output=args.output.resolve()
    if output.exists():parser.error('Output directory already exists')
    manifest=json.loads((ROOT/'SOURCE_MANIFEST.json').read_text())
    with tempfile.TemporaryDirectory(prefix='fyp_public_layout_') as tmp:
        fixture=Path(tmp);rewritten=[]
        def materialize(name):
            data=(ROOT/name).read_bytes();target_name=name
            if name.endswith('.csv'):
                target_name+='.gz';data=gzip.compress(data,mtime=0)
            target=fixture/target_name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
            return target_name,data
        for record in manifest['files']:
            if record['path'].endswith(('.mat','.fig')):continue
            name,data=materialize(record['path']);entry=dict(record)
            entry.update(path=name,sha256=sha(data),size_bytes=len(data));rewritten.append(entry)
        manifest['files']=rewritten
        manifest['layout_smoke_fixture']='Simulated compressed-CSV/no-MAT public layout; not downloaded from GitHub'
        (fixture/'SOURCE_MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
        extras=['verify_saved_results.py','audit_native_results.py','lab_analysis.py','tests/test_lab_analysis.py',
                'verification/run_verification.py','verification/audit_native_results_compatible.py']
        if (ROOT/'prepare_data.py').is_file():extras.append('prepare_data.py')
        extras.extend(str(p.relative_to(ROOT)) for p in (ROOT/'scheduler_output').glob('*.*'))
        for name in extras:materialize(name)
        command=[sys.executable,str(ROOT/'verification/run_verification.py'),'--project-root',str(fixture),'--output',str(output)]
        subprocess.run(command,check=True)
        result=json.loads((output/'verification_summary.json').read_text())
        assert result['status']=='PASS'
        assert result['mat_csv_comparison']['status']=='SKIPPED'
        assert result['mat_csv_comparison']['max_difference'] is None
        assert result['compressed_csv_materialized_count']>0 and result['original_input_bytes_unchanged']
        audit=json.loads((output/'accepted_native_simulink_audit.json').read_text())
        assert audit['MAT_CSV_max_difference'] is None
        assert audit['slx_wires_verified']==14 and audit['full_trace']['within_tolerance']
        report={'status':'PASS','scope':manifest['layout_smoke_fixture'],
                'mat_not_created_or_supplied':not (fixture/'results/simulink/simulink_results.mat').exists(),
                'mat_csv_comparison':result['mat_csv_comparison'],
                'compressed_csv_materialized_count':result['compressed_csv_materialized_count'],
                'all_other_native_audit_checks_executed':True,
                'new_native_matlab_execution':False,'new_native_simulink_execution':False}
        (output/'layout_smoke_result.json').write_text(json.dumps(report,indent=2)+'\n')
        (output/'simulated_public_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(json.dumps(report,indent=2))
if __name__=='__main__':main()
