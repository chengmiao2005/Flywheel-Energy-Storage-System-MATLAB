"""Assemble a single-file Simulink builder / Level-2 block implementation."""
from pathlib import Path
import hashlib,json
import numpy as np
HERE=Path(__file__).resolve().parent
base=(HERE/'accepted_core/FYP_EnergyDispatch_v1.m').read_text()
def between(a,b):return base[base.index(a):base.index(b)]
parameters=between('function p=actual_parameters(','function q=energy(')
utilities=between('function q=energy(','function [phases,g]=gate_schedule(')
# Keep the cycle-map physical core byte for byte. Full-PWM RK4 was validated
# earlier, but is unused in this discrete integration layer.
plant=between('function [phases,g]=gate_schedule(','function dy=pwm_rhs(')
row=between('function row=make_row(','function [data,s]=simulate_case(')
helpers=between('function checks=add(','function checks=check_results(')
source=(HERE/'entry.mpart').read_text()+'\n'+(HERE/'blocks.mpart').read_text()+'\n'+parameters+utilities+plant+row+helpers+(HERE/'checks_plots.mpart').read_text()
for name,file in [('embedded_train_profile','accepted_core/train_replay.csv'),('native_simulink_fixture','accepted_native_combined_fixture.csv')]:
    data=np.loadtxt(HERE/file,delimiter=',',skiprows=1)
    source+='\nfunction data='+name+'()\ndata=[\n'
    source+=''.join(' '.join(format(v,'.17g') for v in row)+';\n' for row in data)+'];\nend\n'
reference=np.loadtxt(HERE/'accepted_native_combined_fixture.csv',delimiter=',',skiprows=1)
source+='\nfunction value=native_reference_source()\nvalue='+format(reference[-1,4],'.17g')+';\nend\n'
assert source.count(plant)==1
(HERE/'FYP_SimulinkSystem_v1.m').write_text(source)
manifest={'accepted_matlab_sha256':hashlib.sha256(base.encode()).hexdigest(),
 'physical_cycle_map_sha256':hashlib.sha256(plant.encode()).hexdigest(),'physical_cycle_map_verbatim_preserved':True,
 'outer_supervisor_verbatim_preserved':utilities[utilities.index('function u=outer_control('):] in source,
 'controller_sees_actual_plant_parameters':False,
 'execution':'Simulink unavailable locally; native builder execution and wiring validation pending'}
acceptance_path=HERE/'accepted_native_simulink_audit.json'
if acceptance_path.exists():
    acceptance=json.loads(acceptance_path.read_text())
    if acceptance.get('source_sha256')==hashlib.sha256(source.encode()).hexdigest() and acceptance.get('accepted'):
        manifest['execution']='User native MATLAB/Simulink R2024a run accepted; local environment has no MATLAB/Simulink'
        manifest['native_acceptance']={'passed':acceptance['native_checks']['passed'],
            'count':acceptance['native_checks']['count'],'source_sha256':acceptance['source_sha256']}
(HERE/'build_provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Standalone builder:',len(source.encode()),'bytes')
