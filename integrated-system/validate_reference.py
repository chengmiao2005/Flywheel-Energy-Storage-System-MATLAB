"""Check scheduling equivalence and static port wiring; not a Simulink run."""
from pathlib import Path
import json,re,subprocess,sys
import numpy as np

HERE=Path(__file__).resolve().parent
OUT=HERE/'scheduler_output'
if '--run' in sys.argv:
    subprocess.run([sys.executable,str(HERE/'build_scheduler_reference.py')],check=True)
    subprocess.run(['g++','-O3','-std=c++17','-ffp-contract=off',str(HERE/'reference_scheduler.cpp'),'-o',str(HERE/'reference_scheduler.bin')],check=True)
    subprocess.run([str(HERE/'reference_scheduler.bin'),str(OUT)],check=True)
d=np.genfromtxt(OUT/'scheduler_trace.csv',delimiter=',',names=True)
f=np.genfromtxt(HERE/'accepted_native_combined_fixture.csv',delimiter=',',names=True)
metrics=json.loads((OUT/'scheduler_metrics.json').read_text());tests=[]
def add(name,value,limit):
    tests.append(dict(name=name,value=float(value),limit=float(limit),passed=bool(np.isfinite(value) and value<=limit)))
add('complete_log',abs(len(d)-9001),0)
add('full_horizon_s',abs(d['t_s'][-1]-90),1e-9)
sample=d[np.rint(f['t_s']/.01).astype(int)]
for key in d.dtype.names:add('accepted_native.'+key,max(abs(sample[key]-f[key])),1e-9 if key=='t_s' else 1e-6)
store=.5*.65*d['omega_rad_s']**2+.5*.014*d['i_A']**2+.5*.08*d['Vdc_V']**2
loss=sum(d[key] for key in ['Wline_J','Wchopper_J','Wconverter_J','Wcopper_J','Wviscous_J','Wcoulomb_J'])
add('independent_energy_balance_J',max(abs(store-store[0]-d['Wsource_J']+d['Wload_J']+loss)),1e-4)
add('pure_repeated_outputs',metrics['max_purity_error'],0)
add('all_cycle_peak_current_excess_A',max(0,metrics['max_current_A']-20.1),0)
add('all_cycle_balance_J',metrics['max_balance_J'],1e-4)
add('all_cycle_midpoint_defect',metrics['midpoint_defect'],5e-13)

# Derive port widths and wiring directly from the shipped builder source.
blocks=(HERE/'blocks.mpart').read_text();entry=(HERE/'entry.mpart').read_text()
def dimensions(text):return [int(v) for v in re.findall(r'\d+',text)]
spec={kind:(dimensions(a),dimensions(b)) for kind,a,b in re.findall(r"case '(\w+)',inputs=([^;]+);outputs=([^;]+);",blocks)}
nodes={name:kind for name,kind in re.findall(r"put_block\(mdl,'([^']+)','([^']+)'",entry)}
sinks=re.findall(r"add_block\('simulink/Sinks/[^']+',\[mdl '/([^']+)'\]",entry)
edges=re.findall(r"wire\(mdl,'([^']+)','([^']+)'\)",entry)
incoming=set();graph={name:[] for name in nodes}
for src,dst in edges:
    a,ap=src.rsplit('/',1);b,bp=dst.rsplit('/',1);ap=int(ap);bp=int(bp)
    assert a in nodes and 1<=ap<=len(spec[nodes[a]][1])
    assert (b,bp) not in incoming;incoming.add((b,bp))
    if b in nodes:
        assert 1<=bp<=len(spec[nodes[b]][0])
        assert spec[nodes[a]][1][ap-1]==spec[nodes[b]][0][bp-1]
        if nodes[b]!='plant':graph[a].append(b)
    else:assert b in sinks and bp==1
for name,kind in nodes.items():
    assert all((name,j+1) in incoming for j in range(len(spec[kind][0])))
visiting=set();done=set()
def visit(name):
    assert name not in visiting,'Direct-feedthrough algebraic cycle'
    if name in done:return
    visiting.add(name)
    for target in graph[name]:visit(target)
    visiting.remove(name);done.add(name)
for name in nodes:visit(name)
add('static_port_wiring',0,0)
result={'execution':'Independent C++ scheduler emulation plus static wiring analysis; native Simulink execution PENDING',
 'passed':sum(t['passed'] for t in tests),'count':len(tests),'all_passed':all(t['passed'] for t in tests),'tests':tests,
 'ports':spec,'connections':edges,'physical_state_breaks_algebraic_loop':True,'native_simulink_verified':False}
(OUT/'validation.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['execution','passed','count','all_passed']},indent=2))
assert result['all_passed']
