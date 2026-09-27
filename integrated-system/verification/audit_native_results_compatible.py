"""Audit full/public native evidence; skip only optional absent MAT comparison.
Adapted from the original audit_native_results.py without changing its other checks.
Never executes Simulink and never fabricates a substitute MAT file.
"""
from pathlib import Path
import hashlib
import json
import re
import zipfile
import xml.etree.ElementTree as ET
import numpy as np
from scipy.io import loadmat

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_csv(path):
    return np.genfromtxt(path, delimiter=',', names=True, encoding='utf-8-sig', dtype=None)


def main():
    native = ROOT / 'results/simulink'
    prior = ROOT / 'results/matlab'
    a = read_csv(native / 'simulink_trace.csv')
    b = read_csv(prior / '06_combined_dispatch.csv')
    report = json.loads((native / 'tests_summary.json').read_text())
    previous = json.loads((prior / 'tests_summary.json').read_text())
    assert report['simulink_executed'] and report['all_passed']
    assert report['passed'] == report['count'] == 67
    assert all(x['passed'] and x['value'] <= x['limit'] for x in report['tests'])
    assert previous['all_passed'] and previous['passed'] == previous['count'] == 322
    assert sha(native / 'SourceSnapshot.m') == sha(ROOT / 'FYP_SimulinkSystem_v1.m')
    assert sha(prior / 'SourceSnapshot.m') == sha(ROOT / 'accepted_core/FYP_EnergyDispatch_v1.m')
    assert len(a) == len(b) == 9001 and len(a.dtype.names) == 51 and len(b.dtype.names) == 48
    assert np.max(abs(a['t_s'] - np.arange(9001) * .01)) < 1e-9
    assert all(np.isfinite(a[n]).all() for n in a.dtype.names)
    errors = {n: float(np.max(abs(a[n] - b[n]))) for n in b.dtype.names}
    assert all(e <= (1e-9 if n == 't_s' else 1e-6) for n, e in errors.items())
    p = json.loads((native / 'model_configuration.json').read_text())['plant']
    stored = .5 * p['J'] * a['omega_rad_s']**2 + .5 * p['L'] * a['i_A']**2 + .5 * p['C'] * a['Vdc_V']**2
    losses = sum(a[n] for n in ['Wline_J', 'Wchopper_J', 'Wconverter_J', 'Wcopper_J', 'Wviscous_J', 'Wcoulomb_J'])
    residual = stored - stored[0] - a['Wsource_J'] + a['Wload_J'] + losses
    identities = {
        'total_balance_J': float(max(abs(residual))),
        'converter_balance_J': float(max(abs(a['Wfess_J'] - a['Wterminal_J'] - a['Wconverter_J']))),
        'motor_balance_J': float(max(abs(a['Wterminal_J'] - a['Wcopper_J'] - a['Wem_J'] - a['Emag_J'] + a['Emag_J'][0]))),
        'credit_bookkeeping_J': float(max(abs(a['recovery_credit_J'] - a['credited_J'] + a['spent_J'] + a['leaked_J']))),
    }
    assert identities['total_balance_J'] < 1e-4
    assert all(v < 1e-7 for k, v in identities.items() if k != 'total_balance_J')
    assert max(a['max_current_A']) < 20.1 and max(a['max_balance_J']) < 1e-4
    assert max(a['midpoint_defect']) <= 5e-13
    mat_path = native / 'simulink_results.mat'
    mat_error = None
    mat_comparison = {'status': 'SKIPPED', 'reason': 'Optional MAT omitted from this distribution; no MAT/CSV claim is made', 'max_difference': None}
    if mat_path.is_file():
        mat = loadmat(mat_path)
        mat_error = float(np.max(abs(np.column_stack([a[n] for n in a.dtype.names]) - mat['data'])))
        assert mat_error < 1e-8
        mat_comparison = {'status': 'PASS', 'reason': 'Saved MAT and CSV compared directly', 'max_difference': mat_error}
    model = ROOT / report['model']
    model = model.with_suffix('.slx')
    with zipfile.ZipFile(model) as archive:
        assert archive.testzip() is None
        system = ET.fromstring(archive.read('simulink/systems/system_root.xml'))
        names = {b.attrib['SID']: b.attrib['Name'] for b in system.findall('Block')}
        def endpoint(text):
            sid, port = text.split('#')
            return names[sid] + '/' + port.split(':')[1]
        actual = []
        for line in system.findall('Line'):
            src = line.find("P[@Name='Src']").text
            actual.extend((endpoint(src), endpoint(x.text)) for x in line.findall(".//P[@Name='Dst']"))
        expected = re.findall(r"wire\(mdl,'([^']+)','([^']+)'\)", (ROOT / 'entry.mpart').read_text())
        assert sorted(actual) == sorted(expected) and len(actual) == 14
        solver = {x.attrib['Name']: x.text for x in ET.fromstring(archive.read('simulink/configSet0.xml')).iter('P')
                  if x.attrib.get('Name') in ['SolverName', 'FixedStep', 'StartTime', 'StopTime']}
        assert solver['SolverName'] == 'FixedStepDiscrete'
        assert abs(float(solver['FixedStep']) - 1 / 20000) < 1e-15
        assert float(solver['StartTime']) == 0 and float(solver['StopTime']) == 90
        assert archive.read('simulink/modelWorkspace.mxarray')
    comparisons = read_csv(prior / 'comparisons.csv')
    pairs = []
    for i, (left, right) in enumerate([
        ('01_nominal_bypass', '02_nominal_dispatch'), ('03_friction_bypass', '04_friction_dispatch'),
        ('05_combined_bypass', '06_combined_dispatch'), ('07_pulse_bypass', '08_pulse_dispatch'),
    ]):
        u, v = read_csv(prior / (left + '.csv')), read_csv(prior / (right + '.csv'))
        delta = float(u['Wsource_J'][-1] - v['Wsource_J'][-1])
        pct = 100 * delta / float(u['Wsource_J'][-1])
        gap = abs(sum(float(u[k][-1] - v[k][-1]) for k in ['Erot_J', 'Emag_J', 'Ecap_J']))
        assert comparisons[i]['valid_common_terminal'] == 1 and gap < 1e-4
        assert abs(delta - comparisons[i]['matched_source_reduction_J']) < 1e-7
        assert abs(pct - comparisons[i]['matched_reduction_percent']) < 1e-8
        pairs.append({'pair': str(comparisons[i]['pair']), 'reduction_J': delta, 'reduction_percent': pct,
                      'final_stored_energy_difference_J': gap})
    audit = {
        'accepted': True, 'execution': 'Independent audit of user native MATLAB/Simulink R2024a results; no local Simulink execution',
        'native_created': report['created'], 'native_elapsed_s': report['elapsed_s'],
        'source_sha256': sha(native / 'SourceSnapshot.m'), 'slx_sha256': sha(model),
        'native_checks': {'passed': 67, 'count': 67}, 'preceding_matlab_checks': {'passed': 322, 'count': 322},
        'full_trace': {'rows': 9001, 'common_columns': 48, 'max_error_per_column': errors, 'within_tolerance': True},
        'energy_identities': identities, 'MAT_CSV_max_difference': mat_error, 'MAT_CSV_comparison': mat_comparison,
        'slx_wires_verified': 14, 'slx_solver': solver, 'model_workspace_present': True,
        'peak_current_A': float(max(a['max_current_A'])), 'logged_min_rpm': float(min(a['rpm'])),
        'final_rpm': float(a['rpm'][-1]), 'matched_terminal_pairs': pairs,
        'scope': 'Custom PWM cycle map; provisional DC motor and synthetic train load; no hardware/real-rail validation',
    }
    (ROOT / 'accepted_native_simulink_audit.json').write_text(json.dumps(audit, indent=2) + '\n')
    print(json.dumps({'accepted': True, 'rows': 9001, 'columns': 48, 'max_difference': max(errors.values()),
                      'energy_balance_J': identities['total_balance_J'], 'MAT_CSV_comparison': mat_comparison}))


if __name__ == '__main__':
    main()
