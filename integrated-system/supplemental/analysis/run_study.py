#!/usr/bin/env python3
"""Reproduce the same 12-pair study, restored after the execution workspace reset.
Run: python supplemental/analysis/run_study.py --project-root . --workers 4
Use --analyze-only to rebuild from CSV.xz. Strict failed checks return nonzero
after writing all reports and figures. No check thresholds are relaxed.
"""
from __future__ import annotations
import argparse, concurrent.futures, csv, datetime as dt, hashlib, json, lzma
import os, platform, shutil, subprocess, sys, time
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE=Path(__file__).resolve().parent
ROOT=next((p for p in HERE.parents if (p/"accepted_core/reference_dispatch.cpp").is_file()),HERE.parent)
RESULTS=HERE/"results"; FIGURES=HERE/"figures"; CHECKS=[]
SPECS=[
("nominal","标称","无","Nominal"),
("R_high","电枢电阻升高","R: 0.8 → 1.0 Ω","R +25%"),
("L_low","电枢电感降低","L: 0.020 → 0.014 H","L -30%"),
("J_high","转动惯量升高","J: 0.51 → 0.65 kg·m²","J +27.5%"),
("b_high","黏性摩擦升高","b: 0.001 → 0.0015 N·m·s/rad","b +50%"),
("Tc_high","恒定摩擦升高","Tc: 0.050 → 0.075 N·m","Tc +50%"),
("Vs_low","源电压降低","Vs: 60 → 57 V；该组初始母线电压同步","Vs -5%"),
("Rs_high","源电阻升高","Rs: 0.30 → 0.45 Ω","Rs +50%"),
("C_low","母线电容降低","C: 0.10 → 0.08 F","C -20%"),
("friction_high","摩擦组合","b=0.0015，Tc=0.075","Friction group"),
("device_high","器件组合","Ron=0.03 Ω，Rd=0.015 Ω，Vf=0.8 V，死区=2 μs","Device group"),
("combined","综合偏差","上述全部偏差同时施加","Combined")]
LOSS=["Wline_J","Wchopper_J","Wconverter_J","Wcopper_J","Wviscous_J","Wcoulomb_J"]
STORES=["Erot_J","Emag_J","Ecap_J"]
RESTORE_NOTE="Reconstructed after execution-workspace reset. The study design and thresholds match the original completed study; this is a rerun, not an additional scientific scenario."
def sha256(p):
    h=hashlib.sha256()
    with open(p,"rb") as f:
        for b in iter(lambda:f.read(1048576),b""):h.update(b)
    return h.hexdigest()
def write_json(p,o):p.write_text(json.dumps(o,indent=2,ensure_ascii=False,allow_nan=False)+"\n",encoding="utf-8")
def check(name,value,limit):
    v=float(value);CHECKS.append({"name":name,"value":v,"limit":limit,"passed":bool(np.isfinite(v) and v<=limit)})
def write_csv(p,rows):
    with p.open("w",newline="",encoding="utf-8-sig") as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)

def compile_and_run(workers):
    build=HERE/"build";build.mkdir(exist_ok=True);binary=build/"sensitivity_driver"
    cmd=["g++","-O3","-std=c++17","-I",str(ROOT/"accepted_core"),str(HERE/"sensitivity_driver.cpp"),"-o",str(binary)]
    r=subprocess.run(cmd,capture_output=True,text=True);(HERE/"build.log").write_text(r.stdout+r.stderr);r.check_returncode()
    def run_one(name):
        start=time.perf_counter();command=[str(binary),str(RESULTS),name]
        p=subprocess.run(command,capture_output=True,text=True)
        record={"case":name,"command":command,"exit_code":p.returncode,"wall_seconds":time.perf_counter()-start,"stdout":p.stdout.strip(),"stderr":p.stderr.strip()}
        if p.returncode:raise RuntimeError(record)
        source=RESULTS/(name+".csv");target=RESULTS/(name+".csv.xz");tmp=RESULTS/(name+".csv.xz.tmp")
        with source.open("rb") as f,lzma.open(tmp,"wb",preset=6) as z:shutil.copyfileobj(f,z)
        with lzma.open(tmp,"rb") as z:decoded=z.read()
        if hashlib.sha256(decoded).hexdigest()!=sha256(source):raise RuntimeError("XZ round-trip mismatch "+name)
        tmp.replace(target);record["trace_file"]="results/"+target.name;record["trace_sha256"]=sha256(target);source.unlink()
        print(record["stdout"],flush=True);return record
    names=[s[0]+"_"+m for s in SPECS for m in ["bypass","dispatch"]];start=time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:runs=list(pool.map(run_one,names))
    write_json(HERE/"execution_provenance.json",{
        "study_type":"Supplemental C++ computation sharing the accepted model; not MATLAB execution, hardware validation or independent physical validation",
        "reconstruction_note":RESTORE_NOTE,"recorded_utc":dt.datetime.now(dt.timezone.utc).isoformat(),"python_version":sys.version,
        "platform":platform.platform(),"compiler":subprocess.check_output(["g++","--version"],text=True).splitlines()[0],
        "numpy_version":np.__version__,"matplotlib_version":matplotlib.__version__,"workers":workers,
        "compile_command":cmd,"runs_wall_seconds":time.perf_counter()-start,
        "source_sha256":{os.path.relpath(p,ROOT):sha256(p) for p in [HERE/"sensitivity_driver.cpp",ROOT/"accepted_core/reference_dispatch.cpp",ROOT/"accepted_core/train_profile.hpp"]},
        "trace_format":"Lossless XZ-compressed CSV","runs":runs})

def load_case(name):
    with lzma.open(RESULTS/(name+".csv.xz"),"rt",encoding="utf-8") as f:a=np.genfromtxt(f,delimiter=",",names=True)
    m=json.loads((RESULTS/(name+"_metrics.json")).read_text())
    check(name+".finite_trace",int(not all(np.all(np.isfinite(a[x])) for x in a.dtype.names)),0)
    check(name+".trace_rows",abs(len(a)-9001),0)
    check(name+".trace_dt_s",np.max(np.abs(np.diff(a["t_s"])-.01)),1e-10)
    check(name+".horizon_s",abs(a["t_s"][-1]-90),1e-9)
    check(name+".task_s",abs(m["task_s"]-20),1e-9);check(name+".restore_s",abs(m["restore_s"]-70),1e-9)
    physical=.5*m["plant_J"]*a["omega_rad_s"]**2+.5*m["plant_L"]*a["i_A"]**2+.5*m["plant_C"]*a["Vdc_V"]**2
    residual=physical-physical[0]-a["Wsource_J"]+a["Wload_J"]+sum(a[x] for x in LOSS)
    check(name+".recomputed_balance_J",np.max(np.abs(residual)),1e-4)
    check(name+".computed_stores_J",np.max(np.abs(physical-sum(a[x] for x in STORES))),1e-8)
    for key,limit in [("max_balance_J",1e-4),("target_rpm_error",1e-5),("target_mean_current_error_A",1e-6),("final_second_store_drift_J",1e-4),
                      ("high_direction_error_A",1e-10),("low_direction_error_A",1e-10),("ledger_split_error_J",1e-7),("device_split_error_J",1e-7),("midpoint_defect",5e-13)]:
        check(name+"."+key,m[key],limit)
    check(name+".reference_above_20_A",max(0,m["max_reference_A"]-20),1e-10)
    check(name+".current_above_20_1_A",max(0,m["max_current_A"]-20.1),0)
    check(name+".bus_above_70_V",max(0,m["Vmax"]-70),1e-9)
    check(name+".source_reverse_J",max(0,-float(np.min(np.diff(a["Wsource_J"])))),1e-9)
    check(name+".converter_identity_J",np.max(np.abs(a["Wfess_J"]-a["Wterminal_J"]-a["Wconverter_J"])),1e-7)
    check(name+".motor_identity_J",np.max(np.abs(a["Wterminal_J"]-a["Wcopper_J"]-a["Wem_J"]-a["Emag_J"]+a["Emag_J"][0])),1e-7)
    check(name+".mean_current_target_A",abs(a["cycle_mean_i_A"][-1]-(m["plant_b"]*3000*2*np.pi/60+m["plant_Tc"])/.05),1e-6)
    check(name+".controller_R_nominal",abs(m["controller_R"]-.8),0)
    check(name+".controller_b_nominal",abs(m["controller_b"]-.001),0)
    check(name+".controller_deadtime_nominal",abs(m["controller_deadtime_s"]-1e-6),0)
    for key,val in [("controller_Kp",.02*2*np.pi*200),("controller_Ki",.82*2*np.pi*200),("speed_Kp",10.18),("speed_Ki",2.55)]:
        check(name+"."+key,abs(m[key]-val),1e-11)
    if name.endswith("_dispatch"):
        check(name+".credit_balance_J",np.max(np.abs(a["recovery_credit_J"]-a["credited_J"]+a["spent_J"]+a["leaked_J"])),1e-7)
        check(name+".spent_above_credited_J",max(0,float(np.max(a["spent_J"]-a["credited_J"]))),1e-3)
        before=(a["t_s"]<20)&(a["credited_J"]<1e-8)
        check(name+".initial_discharge_command_A",max(0,-float(np.min(a["iref_A"][before]))),1e-10)
        for x in ["recovery_credit_J","credited_J","spent_J","leaked_J"]:
            v=a[x][a["t_s"]>=20];check(name+"."+x+"_frozen_in_restore",np.max(np.abs(v-v[0])),1e-10)
    return a,m

def diagnostics(data):
    records=[]
    for scenario,kind in [("R_high","motor"),("L_low","converter"),("Tc_high","converter")]:
        a=data[scenario][1]
        terms=[a["Wterminal_J"],-a["Wcopper_J"],-a["Wem_J"],-a["Emag_J"],np.full(len(a),a["Emag_J"][0])] if kind=="motor" else [a["Wfess_J"],-a["Wterminal_J"],-a["Wconverter_J"]]
        r=sum(np.asarray(x,dtype=np.longdouble) for x in terms);scale=sum(np.abs(np.asarray(x,dtype=np.longdouble)) for x in terms);k=int(np.argmax(np.abs(r)))
        samples=[]
        for t in [0,20,40,60,80,90]:
            n=int(np.flatnonzero(np.isclose(a["t_s"],t,atol=1e-12,rtol=0))[0])
            samples.append({"t_s":t,"signed_residual_J":float(r[n]),"sum_abs_ledger_terms_J":float(scale[n]),"integration_steps":int(round(t/.00005))})
        records.append({"case":scenario+"_dispatch","identity":kind,"max_abs_residual_extended_precision_J":float(abs(r[k])),"max_at_s":float(a["t_s"][k]),
                        "sum_abs_ledger_terms_at_max_J":float(scale[k]),"relative_to_sum_abs_terms":float(abs(r[k])/scale[k]),"samples":samples})
    d={"method":"Extended-precision numpy.longdouble subtraction of stored double-precision ledgers.","longdouble_precision_digits":int(np.finfo(np.longdouble).precision),
       "interpretation":"Residuals persist under higher-precision subtraction; stored traces do not prove all upstream ledger disagreement is floating-point roundoff. Original 1e-7 J checks remain failed; no threshold changed.",
       "reconstruction_note":RESTORE_NOTE,"records":records}
    (HERE/"diagnostics").mkdir(exist_ok=True);write_json(HERE/"diagnostics/identity_residual_diagnostics.json",d);return d

def analyze():
    pairs=[];cases=[];contributions=[];data={}
    for scenario,label,delta,plot_label in SPECS:
        a,ma=load_case(scenario+"_bypass");b,mb=load_case(scenario+"_dispatch");data[scenario]=(a,b);cases += [ma,mb]
        ta=int(np.flatnonzero(np.isclose(a["t_s"],20,atol=1e-12,rtol=0))[0]);tb=int(np.flatnonzero(np.isclose(b["t_s"],20,atol=1e-12,rtol=0))[0])
        mismatch=sum(abs(float(a[x][-1]-b[x][-1])) for x in STORES);initial_gap=sum(abs(float(a[x][0]-b[x][0])) for x in STORES)
        store_delta=sum(float(a[x][-1]-b[x][-1]) for x in STORES);saving=ma["total_source_J"]-mb["total_source_J"]
        loss_saving=sum(float(a[x][-1]-b[x][-1]) for x in LOSS);load_gap=float(a["Wload_J"][-1]-b["Wload_J"][-1])
        valid=(mismatch<1e-4 and max(ma["final_second_store_drift_J"],mb["final_second_store_drift_J"])<1e-4 and abs(load_gap)<1e-6
               and max(ma["max_balance_J"],mb["max_balance_J"])<1e-4 and max(ma["target_rpm_error"],mb["target_rpm_error"])<1e-5
               and max(ma["target_mean_current_error_A"],mb["target_mean_current_error_A"])<1e-6)
        check(scenario+".same_initial_store_J",initial_gap,1e-10)
        check(scenario+".same_timestamps_s",np.max(np.abs(a["t_s"]-b["t_s"])),1e-12)
        check(scenario+".same_load_samples_W",np.max(np.abs(a["Pload_W"]-b["Pload_W"])),1e-12)
        check(scenario+".same_final_store_J",mismatch,1e-4);check(scenario+".same_load_J",abs(load_gap),1e-6)
        check(scenario+".pair_energy_identity_J",abs(saving-loss_saving-store_delta-load_gap),2e-4);check(scenario+".common_terminal_invalid",int(not valid),0)
        rec={"scenario":scenario,"label_zh":label,"change":delta,"valid_common_terminal":valid,
             "bypass_total_source_J":ma["total_source_J"],"dispatch_total_source_J":mb["total_source_J"],"source_reduction_J":saving,
             "source_reduction_percent":100*saving/ma["total_source_J"] if valid else None,
             "task_source_reduction_J":ma["task_source_J"]-mb["task_source_J"],"restore_source_reduction_J":ma["restore_source_J"]-mb["restore_source_J"],
             "bypass_task_source_J":ma["task_source_J"],"dispatch_task_source_J":mb["task_source_J"],"bypass_restore_source_J":ma["restore_source_J"],"dispatch_restore_source_J":mb["restore_source_J"],
             "final_store_mismatch_J":mismatch,"pair_energy_identity_error_J":abs(saving-loss_saving-store_delta-load_gap),
             "max_balance_J":max(ma["max_balance_J"],mb["max_balance_J"]),"max_final_second_store_drift_J":max(ma["final_second_store_drift_J"],mb["final_second_store_drift_J"]),
             "bypass_peak_bus_V":ma["Vmax"],"dispatch_peak_bus_V":mb["Vmax"],"bypass_min_bus_V":ma["Vmin"],"dispatch_min_bus_V":mb["Vmin"],
             "dispatch_peak_current_A":mb["max_current_A"],"dispatch_final_rpm":mb["final_rpm"],"bypass_final_rpm":ma["final_rpm"]}
        for x in LOSS:
            rec[x.replace("W","reduction_",1)]=float(a[x][-1]-b[x][-1])
            contributions.append({"scenario":scenario,"component":x,"bypass_task_J":float(a[x][ta]),"dispatch_task_J":float(b[x][tb]),
                                  "bypass_restore_J":float(a[x][-1]-a[x][ta]),"dispatch_restore_J":float(b[x][-1]-b[x][tb]),"total_loss_reduction_J":float(a[x][-1]-b[x][-1])})
        pairs.append(rec)
    with (ROOT/"results/matlab/summary.csv").open(encoding="utf-8-sig") as f:native={r["case_name"]:r for r in csv.DictReader(f)}
    native_map={"nominal_bypass":"01_nominal_bypass","nominal_dispatch":"02_nominal_dispatch","friction_high_bypass":"03_friction_bypass",
                "friction_high_dispatch":"04_friction_dispatch","combined_bypass":"05_combined_bypass","combined_dispatch":"06_combined_dispatch"}
    anchors=[]
    for m in cases:
        if m["case_name"] not in native_map:continue
        n=native[native_map[m["case_name"]]]
        diffs={x:abs(m[x]-float(n[x])) for x in ["total_source_J","task_source_J","restore_source_J","total_losses_J","final_rpm","final_V"]}
        for x,d in diffs.items():check(m["case_name"]+".native_anchor_"+x,d,1e-5)
        anchors.append({"cpp_case":m["case_name"],"native_case":n["case_name"],"absolute_differences":diffs})
    nominal=pairs[0]["source_reduction_percent"]
    for p in pairs:p["change_from_nominal_percentage_points"]=p["source_reduction_percent"]-nominal if p["valid_common_terminal"] else None
    write_csv(HERE/"paired_summary.csv",pairs);write_csv(HERE/"case_metrics.csv",cases);write_csv(HERE/"loss_decomposition.csv",contributions)
    write_json(HERE/"checks.json",{"reconstruction_note":RESTORE_NOTE,"passed":sum(x["passed"] for x in CHECKS),"total":len(CHECKS),"checks":CHECKS})
    extra_suffixes=(".trace_rows",".trace_dt_s",".same_timestamps_s",".same_load_samples_W")
    first=[x for x in CHECKS if not x["name"].endswith(extra_suffixes)]
    write_json(HERE/"diagnostics/first_checks_876.json",{"status":"RECONSTRUCTED, not the original lost file","reconstruction_note":"Rerun of original 876-check subset after workspace reset. Excludes 72 completeness and pointwise-pair checks added later.","passed":sum(x["passed"] for x in first),"total":len(first),"checks":first})
    diag=diagnostics(data)
    summary={"scope":"12 scenario pairs (24 runs), 20 s train task + 70 s restoration, fixed nominal controller, shared C++ model core",
        "reconstruction_note":RESTORE_NOTE,"is_native_matlab_execution":False,"is_hardware_validation":False,"is_independent_model_validation":False,
        "checks_passed":sum(x["passed"] for x in CHECKS),"checks_total":len(CHECKS),"all_checks_passed":all(x["passed"] for x in CHECKS),
        "all_pairs_common_terminal":all(p["valid_common_terminal"] for p in pairs),"failed_checks":[x for x in CHECKS if not x["passed"]],
        "native_anchor_comparisons":anchors,"identity_diagnostics":diag,"pairs":pairs,
        "metric_definitions":{"bus_extrema":"Complete 0–90 s horizon including restoration, observed at every 50 microsecond update boundary; not 0–20 s task-only or 10 ms plotting samples.",
            "current_peak":"Maximum magnitude tracked by electrical subintervals over 0–90 s.","source_reduction_percent":"100*(bypass source energy - dispatch source energy)/bypass source energy over full 90 s after common-terminal checks."},
        "boundaries":["One-sided finite perturbations, not global robustness proof.","Provisional physical parameters and synthetic rail input.",
            "Baseline flywheel keeps spinning with friction and is restored; a removed/stopped flywheel is different.","90 s source savings are not recovery efficiency or full-scale rail savings.",
            "Vs also changes initial bus operating point within each pair.","Actual deadtime enters pulse feasibility; controller gains/feedforward/credit parameters remain nominal."]}
    write_json(HERE/"study_summary.json",summary)
    first_summary=dict(summary)
    first_summary.update({"status":"RECONSTRUCTED original 876-check subset, not the lost original file", "checks_passed":sum(x["passed"] for x in first), "checks_total":len(first)})
    write_json(HERE/"diagnostics/first_study_summary.json",first_summary)
    plot_results(pairs,data);report(summary,pairs)
    print(f"Checks: {summary['checks_passed']}/{summary['checks_total']}; common-terminal pairs: {sum(p['valid_common_terminal'] for p in pairs)}/12",flush=True)
    if not summary["all_checks_passed"]:raise RuntimeError("Study checks failed: "+", ".join(x["name"] for x in summary["failed_checks"]))

def savefig(fig,stem):
    fig.savefig(FIGURES/(stem+".png"),dpi=180,bbox_inches="tight");fig.savefig(FIGURES/(stem+".svg"),bbox_inches="tight");plt.close(fig)
def plot_results(pairs,data):
    plt.rcParams.update({"font.size":10,"axes.spines.top":False,"axes.spines.right":False})
    labels=[s[3] for s in SPECS];y=np.arange(len(pairs));values=[p["source_reduction_percent"] for p in pairs]
    fig,ax=plt.subplots(figsize=(9,6.5));ax.barh(y,values,color=["#3a667b"]+["#227f86"]*8+["#ae7845"]*3)
    ax.axvline(values[0],color="#56616e",ls="--",lw=1)
    for i,v in enumerate(values):ax.text(v+.025,i,f"{v:.3f}%",va="center",fontsize=9)
    ax.set_yticks(y,labels);ax.invert_yaxis();ax.set_xlabel("90 s source-energy reduction (%)");ax.set_xlim(0,max(values)*1.22);ax.grid(axis="x",alpha=.2);ax.set_axisbelow(True)
    ax.set_title("Fixed-controller sensitivity: matched terminal stored energy",loc="left",pad=16)
    fig.text(.13,.01,"Supplemental C++ shared-core computation | Synthetic 20 s train task + 70 s restoration",fontsize=8,color="#59636d")
    fig.tight_layout(rect=(0,.035,1,1));savefig(fig,"01_sensitivity_savings")
    fig,axes=plt.subplots(1,2,figsize=(12,6.5));a=np.array([p["task_source_reduction_J"] for p in pairs]);b=np.array([p["restore_source_reduction_J"] for p in pairs])
    axes[0].barh(y,a,color="#227f86",label="Task (0–20 s)");axes[0].barh(y,b,left=a,color="#83b4ab",label="Restoration (20–90 s)")
    axes[0].set_yticks(y,labels);axes[0].invert_yaxis();axes[0].set_xlabel("Source energy saved (J)");axes[0].legend(loc="upper center",bbox_to_anchor=(.5,-.12),ncols=2,fontsize=8,frameon=False)
    axes[0].set_title("Where the 90 s source reduction occurs",loc="left")
    pos=np.zeros(len(pairs));neg=pos.copy()
    for key,label,color in zip(["reduction_line_J","reduction_chopper_J","reduction_converter_J","reduction_copper_J","reduction_viscous_J","reduction_coulomb_J"],
                                ["Source line","Brake chopper","Converter","Motor copper","Viscous","Coulomb"],["#285a82","#3d8e91","#7cb7a3","#c49b58","#b36459","#785a79"]):
        v=np.array([p[key] for p in pairs]);axes[1].barh(y,v,left=np.where(v>=0,pos,neg),color=color,label=label);pos+=np.maximum(v,0);neg+=np.minimum(v,0)
    axes[1].set_yticks(y,labels);axes[1].invert_yaxis();axes[1].axvline(0,color="#777",lw=.8);axes[1].set_xlabel("Loss reduction: bypass − dispatch (J)")
    axes[1].set_title("Positive = less loss; negative = more loss",loc="left");axes[1].legend(ncols=3,fontsize=8,loc="upper center",bbox_to_anchor=(.5,-.12),frameon=False)
    for ax in axes:ax.grid(axis="x",alpha=.18);ax.set_axisbelow(True)
    fig.suptitle("Task and restoration energy accounting",fontsize=13,x=.055,ha="left");fig.tight_layout(rect=(0,.075,1,.98));savefig(fig,"02_source_and_loss_decomposition")
    fig,axes=plt.subplots(2,2,figsize=(11,7),sharex="col")
    for col,scenario in enumerate(["nominal","combined"]):
        for a,label,color in zip(data[scenario],["Spinning bypass","Dispatch"],["#9299a3","#227f86"]):
            axes[0,col].plot(a["t_s"],a["rpm"],label=label,color=color,lw=1.1);axes[1,col].plot(a["t_s"],a["Wsource_J"]/1000,label=label,color=color,lw=1.1)
        axes[0,col].set_title(scenario.capitalize());axes[0,col].set_ylabel("Flywheel speed (rpm)");axes[1,col].set_ylabel("Cumulative source energy (kJ)");axes[1,col].set_xlabel("Time (s)")
        for row in range(2):axes[row,col].axvline(20,color="#ae7845",ls="--",lw=1);axes[row,col].grid(alpha=.15)
        axes[0,col].legend(fontsize=9)
    fig.suptitle("Both runs include restoration to the same terminal operating state",fontsize=13);fig.tight_layout();savefig(fig,"03_restoration_and_source_energy")

def report(s,pairs):
    table="\n".join(f"| {p['label_zh']} | {p['source_reduction_percent']:.4f}% | {p['source_reduction_J']:.3f} | {p['task_source_reduction_J']:.3f} | {p['restore_source_reduction_J']:.3f} | {p['change_from_nominal_percentage_points']:+.4f} |" for p in pairs)
    pars="\n".join(f"| {x[1]} | {x[2]} |" for x in SPECS)
    mxbal=max(p["max_balance_J"] for p in pairs);mxstore=max(p["final_store_mismatch_J"] for p in pairs);mxdrift=max(p["max_final_second_store_drift_J"] for p in pairs)
    anchor=max(max(x["absolute_differences"].values()) for x in s["native_anchor_comparisons"])
    text=f"""# 飞轮储能系统：固定控制器参数敏感性补充研究

本补充研究实际执行 12 组成对工况、24 次 C++ 数值仿真，比较同一列车输入下的旋转旁路与储能调度。每组统一 20 s 任务与 70 s 恢复。12 对共同终态全部有效，严格检查为 {s['checks_passed']}/{s['checks_total']}，保留 3 条子账本诊断越限。

此次采用已有 accepted_core/reference_dispatch.cpp 中的方程和数值核心，不是新一次原生 MATLAB/Simulink 运行，不是硬件实验，也不是独立物理模型验证。已验收的原工程核心未修改。

**重建说明：**执行环境重置后，原研究输出丢失，本目录依据保留的研究设计与代码上下文重新运行相同 24 个工况恢复。没有新增科学工况。诊断目录内首次 876 项检查是对原检查子集的重建，已标明“重建”，不冒充丢失的原文件。

## 设置和比较协议

- 任务 0–20 s、无列车负载的恢复 20–90 s；计算更新周期 50 μs，轨迹记录周期 10 ms，每份轨迹 9001 个样本。
- 使用原 train_profile.hpp 的合成列车功率序列；每对初值、时间戳和负载逐点一致。
- 初始转速 3000 rpm、电流 0 A；母线初值等于该组源电压。Vs 组同时改变源侧初始工作点。
- 电流 PI、速度 PI、前馈和信用账本参数固定标称，未逐工况重整定；实际死区用于门极可实现性约束。
- 旁路飞轮仍旋转、承受摩擦，恢复阶段也必须补回储能；不能将它等同于拆除飞轮或静止飞轮基准。
- 共同终态要求转子、电感、电容末态储能差绝对值总和 <1e-4 J、末秒漂移 <1e-4 J，并核对负载、转速、平均电流和整体能量闭合。

| 工况 | 相对标称变化 |
|---|---|
{pars}

前八个偏差是单因素或源侧工作点扰动，后三个是组合工况，端点来自已有摩擦和综合偏差设置。这是离散单方向对照，不是连续灵敏度扫描或全局鲁棒性证明。

## 结果

节能率为（90 s 旁路源能量－90 s 调度源能量）/90 s 旁路源能量，包含恢复补能，不能称为制动回收效率。“恢复降低量”也是旁路减调度。不同参数会改变旁路能耗这个分母，所以百分比变化不代表回收能量同比例变化。

| 工况 | 90 s 源能量降低 | 降低量 J | 任务降低 J | 恢复降低 J | 相对标称百分点 |
|---|---:|---:|---:|---:|---:|
{table}

单因素／工作点样本中全程降低率为 1.6306%–2.5444%；综合偏差为 1.4648%。这些结论只适用于当前模型、输入和参数点。

![敏感性](figures/01_sensitivity_savings.png)

paired_summary.csv 的母线极值统计完整 0–90 s，在每个 50 μs 更新边界观察；不能与旧报告 0–20 s 任务段、10 ms 绘图采样极值混用。综合工况全程最低约 50.528 V，包含恢复阶段补能电流；任务段约 54.35 V 是另一统计口径。

## 任务、恢复与损耗分解

loss_decomposition.csv 保留源线路、制动电阻、变换器、电机铜耗、黏性摩擦、恒定摩擦六项损耗的任务／恢复数据。正降低量表示调度减少损耗，负值表示增加。各项损耗差加末态储能差和负载差等于源能量差。

![分段能量和损耗](figures/02_source_and_loss_decomposition.png)

当前旋转旁路基准在任务段因摩擦降速，恢复时必须补能；调度吸收制动能量改变了补能需求。报告完整 90 s 能把这些效果计入，不能只用任务段源能量差评价收益。

![恢复与累计源能量](figures/03_restoration_and_source_energy.png)

## 核验与未通过项

- 检查通过 {s['checks_passed']}/{s['checks_total']}；12/12 对共同终态有效。
- 最大全程能量闭合残差 {mxbal:.9g} J，限值 1e-4 J。
- 最大末态储能不一致 {mxstore:.9g} J，限值 1e-4 J。
- 最大末秒储能漂移 {mxdrift:.9g} J，限值 1e-4 J。
- 与已有原生 MATLAB 标称、摩擦、综合偏差共 6 个工况对照，源能量、损耗、末态转速/电压等字段最大绝对差 {anchor:.9g}（各自原单位）；仅表示共享模型数值复现一致性，不增加独立物理证据。

**3 条严格辅助账本诊断仍未通过，不称为“全部验收通过”。** R_high_dispatch 电机恒等式峰值约 1.0556e-7 J（83.07 s）；L_low_dispatch 与 Tc_high_dispatch 变换器恒等式峰值分别约 1.0141e-7 与 1.0790e-7 J（90 s），原限值均 1e-7 J，没有为通过而改容差。对应账本绝对量之和约 3.26–3.54 万 J，相对残差约 3.1e-12。

扩展精度重新相减后残差仍存在；轨迹没有保存每个内部增量，不能证明全部由浮点累计产生。diagnostics/identity_residual_diagnostics.json 保存 0、20、40、60、80、90 s 残差及尺度。重建的 first_checks_876.json 保留原子集定义；最终额外 72 项是轨迹长度、步长及逐点输入一致性核验。

## 复现

最终位置为工程 supplemental/analysis/。在含 accepted_core/ 的工程目录执行：

    python supplemental/analysis/run_study.py --project-root . --workers 4

仅从附带完整 CSV.xz 轨迹重建报告与图：

    python supplemental/analysis/run_study.py --project-root . --analyze-only

需要 g++ C++17、Python 3、NumPy、Matplotlib；XZ 使用 Python 标准库 lzma 无损读取。执行命令、软件版本、源文件与轨迹哈希在 execution_provenance.json，编译输出在 build.log。复用文件的原 main 重命名后可能出现缺显式 return 警告；该函数不被调用，研究入口有明确返回值。

脚本先写完全部数据、报告、图，再因未通过检查返回非零退出码；这表示严格检查未全通过，不表示没有生成结果。analyze-only 同样保留该行为。原生可执行二进制不随交付附带。

实测参数、独立物理模型和硬件测试尚未由本补充研究替代。报告参数点内的结果时，应同时保留合成输入、旋转旁路、共享核心和严格账本精度边界。
"""
    (HERE/"study_report.md").write_text(text,encoding="utf-8")
    (HERE/"README.md").write_text("""# 固定控制器参数敏感性研究

先读 study_report.md。相同12对24次C++运行已在执行环境重置后重建，无新增科学工况。复用已有核心，不是原生MATLAB、硬件或独立物理验证。

结果：12/12对共同终态有效；945/948检查通过，保留3项严格1e-7 J子账本诊断越限，不能称为全通过。first_checks_876.json 明确是原检查子集的重建。

主要文件：study_summary.json、paired_summary.csv、case_metrics.csv、loss_decomposition.csv；figures/有三组PNG/SVG；results/有24份完整9001×48轨迹CSV.xz和指标JSON；diagnostics/有精度诊断；execution_provenance.json与study_manifest.json有哈希和环境记录。

最终位置 supplemental/analysis/，在含accepted_core的工程目录运行：
    python supplemental/analysis/run_study.py --project-root . --workers 4
只重建报告和图：
    python supplemental/analysis/run_study.py --project-root . --analyze-only

要求g++ C++17、Python3、NumPy、Matplotlib；CSV.xz是无损压缩，可用7-Zip或Python lzma打开。默认先写完整结果再因3条失败返回非0；不应将这解释为没有结果或忽略后声称验收全通过。编译二进制不随交付提供。

母线极值是完整90s的50μs边界采样口径，不与旧20s任务段10ms记录极值混用。
""",encoding="utf-8")

def main():
    global ROOT
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--workers",type=int,default=4)
    parser.add_argument("--project-root",type=Path);parser.add_argument("--analyze-only",action="store_true");args=parser.parse_args()
    if args.project_root is not None:ROOT=args.project_root.resolve()
    if not (ROOT/"accepted_core/reference_dispatch.cpp").is_file():parser.error("Cannot locate accepted_core; use --project-root")
    if args.workers<1:parser.error("workers must be positive")
    for p in [RESULTS,FIGURES,HERE/"diagnostics"]:p.mkdir(exist_ok=True)
    if not args.analyze_only:compile_and_run(args.workers)
    analyze()
if __name__=="__main__":main()
