"""Offline laboratory-data entry point; never controls hardware.

Reuses existing lab_analysis.py. Example data are analytical SYNTHETIC TEST DATA,
not measurements or new native MATLAB/Simulink results.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import numpy as np

CURRENT_SIGN = "positive_bus_into_fess"

def find_core(project_root=None):
    if project_root is not None:
        candidates = [Path(project_root).resolve() / "lab_analysis.py"]
    else:
        candidates = []
        for ancestor in Path(__file__).resolve().parents:
            candidates.extend([ancestor / "lab_analysis.py", ancestor / "engineering" / "lab_analysis.py"])
    for file in candidates:
        if file.is_file():
            spec = importlib.util.spec_from_file_location("fyp_existing_lab_analysis", file)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module, file
    raise ValueError("Cannot find lab_analysis.py. Use --project-root PATH to the engineering root.")

def require_text(meta, key):
    value = meta.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Metadata requires nonempty {key}.")
    return value.strip()

def validate_metadata(meta, inertia):
    if not isinstance(meta, dict):
        raise ValueError("Metadata must be a JSON object.")
    if not isinstance(inertia, (float, int)) or not math.isfinite(inertia) or inertia <= 0:
        raise ValueError("Supply a finite positive independently confirmed total inertia in kg m^2.")
    if meta.get("input_type") not in ("real_measurement", "synthetic_test_data"):
        raise ValueError("input_type must be real_measurement or synthetic_test_data.")
    for key in ("test_id", "inertia_source", "sensor_models_and_calibration", "sampling_and_time_alignment"):
        require_text(meta, key)
    if meta.get("inertia_confirmed_independently") is not True:
        raise ValueError("Confirm independent total rotor-plus-flywheel inertia; do not copy simulation J.")
    return meta

def read_csv(file, required):
    with Path(file).open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        fields = reader.fieldnames or []
        if len(fields) != len(set(fields)):
            raise ValueError("CSV contains duplicate column names.")
        if any(name not in fields for name in required):
            raise ValueError("CSV requires: " + ",".join(required))
        rows = list(reader)
    if len(rows) < 3:
        raise ValueError("At least three samples are required.")
    values = {}
    for key in required:
        try:
            values[key] = np.asarray([float(row[key]) for row in rows], dtype=float)
        except (TypeError, ValueError, KeyError) as error:
            raise ValueError(f"Invalid numeric data in {key}.") from error
        if not np.isfinite(values[key]).all():
            raise ValueError(f"Nonfinite data in {key}.")
    if not np.all(np.diff(values["time_s"]) > 0):
        raise ValueError("time_s must increase strictly; duplicate/reversed timestamps are rejected.")
    return values

def quality(t):
    dt = np.diff(t)
    median = float(np.median(dt))
    gap = float(dt.max() / median)
    warnings = []
    if gap > 3:
        warnings.append("A sample gap exceeds 3 times the median interval; review missing samples.")
    if float(np.max(np.abs(dt - median)) / median) > 0.05:
        warnings.append("Sampling intervals vary by more than 5%; actual timestamps were retained.")
    return {"samples": len(t), "duration_s": float(t[-1] - t[0]), "dt_min_s": float(dt.min()),
            "dt_median_s": median, "dt_max_s": float(dt.max()), "max_gap_over_median": gap,
            "warnings": warnings,
            "limits": ["Numeric checks cannot prove sensor calibration, channel synchronization, or current polarity.",
                       "No automatic filtering, offset correction, resampling, or clock alignment is applied."]}

def energy_analysis(core, data, inertia, meta):
    validate_metadata(meta, inertia)
    if meta.get("current_sign") != CURRENT_SIGN:
        raise ValueError("Explicit current_sign=positive_bus_into_fess is required.")
    require_text(meta, "measurement_boundary")
    t, v, i, n = [data[key] for key in ("time_s", "V_bus_V", "I_fess_bus_A", "n_rpm")]
    # Never authorize a round-trip-efficiency claim through this entry point.
    _, old = core.analyze(t, v, i, n, inertia, {"input_type": meta["input_type"]})
    power = v * i
    win, wout = core.split_energy(t, power)
    rotor = 0.5 * inertia * (n * 2 * np.pi / 60) ** 2
    delta = rotor - rotor[0]
    net = win - wout
    signed = float(np.sum(0.5 * (power[:-1] + power[1:]) * np.diff(t)))
    error = abs(float(net[-1]) - signed)
    if error > 1e-9 * max(1, float(win[-1] + wout[-1])):
        raise ValueError("Signed energy integral identity failed.")
    report = {"analysis": "branch_energy", "input_type": meta["input_type"],
              "confirmed_total_inertia_kg_m2": inertia, "current_sign": CURRENT_SIGN,
              "quality": quality(t), "initial_rpm": float(n[0]), "final_rpm": float(n[-1]),
              "imported_J": old["energy_into_branch_J"], "returned_J": old["energy_out_of_branch_J"],
              "net_input_J": float(net[-1]), "rotor_change_J": float(delta[-1]),
              "net_input_minus_rotor_change_J": float(net[-1] - delta[-1]),
              "signed_integral_identity_error_J": error,
              "integration": "Sampled V*I, linearly interpolated in time and split at power zero crossings.",
              "interpretation": "The balance also contains internal electrical stored-energy changes and measurement error. It is not automatically total loss. No round-trip efficiency is reported.",
              "metadata": meta}
    header = ["time_s", "V_bus_V", "I_fess_bus_A", "n_rpm", "P_fess_bus_W", "E_import_J", "E_return_J",
              "E_rotor_J", "Delta_E_rotor_J", "Net_input_J", "Net_input_minus_rotor_change_J"]
    return np.column_stack([t, v, i, n, power, win, wout, rotor, delta, net, net-delta]), header, report

def coastdown_analysis(core, data, inertia, meta):
    validate_metadata(meta, inertia)
    c = meta.get("coastdown_conditions")
    if not isinstance(c, dict):
        raise ValueError("coastdown_conditions is required.")
    for key in ("positive_rotation_only", "no_external_torque", "motor_electrically_isolated"):
        if c.get(key) is not True:
            raise ValueError(f"Coast-down requires an explicit {key}=true declaration.")
    for key in ("isolation_evidence", "external_torque_evidence"):
        require_text(c, key)
    t, n = data["time_s"], data["n_rpm"]
    kind = c.get("zero_torque_evidence_type")
    if kind == "measured_motor_current":
        if "I_motor_A" not in data:
            raise ValueError("This evidence route requires independent I_motor_A, not I_fess_bus_A.")
        require_text(c, "motor_current_sensor_and_zero_check")
        tolerance, current = c.get("motor_current_tolerance_A"), data["I_motor_A"]
        evidence = "Independent measured motor current plus documented electrical isolation."
        if meta["input_type"] == "synthetic_test_data":
            evidence = "Synthetic current-channel fixture, not a measurement; exercises the measured_motor_current evidence route."
    elif kind == "documented_open_circuit":
        if c.get("open_circuit_no_closed_current_path") is not True:
            raise ValueError("Document that the motor has no closed current path, including converter/diode paths.")
        require_text(c, "open_circuit_evidence")
        # Adapter zeros are a documented torque assumption, never measured data.
        current, tolerance = np.zeros(len(t)), 0.0
        evidence = "Zero motor torque assumed from supplied open-circuit evidence; motor current was not measured by this route."
    else:
        raise ValueError("Choose measured_motor_current or documented_open_circuit; branch current alone is insufficient.")
    fit = core.identify_coastdown(t, n, inertia, current,
        dict(no_external_torque=True, motor_electrically_isolated=True, motor_current_tolerance_A=tolerance))
    b, tc = fit["b_Nm_s_rad"], fit["Tc_Nm"]
    elapsed, w = t-t[0], n*2*np.pi/60
    if b > 1e-15:
        fitted_w = w[0]*np.exp(-b*elapsed/inertia) + (tc/b)*np.expm1(-b*elapsed/inertia)
    else:
        fitted_w = w[0]-tc*elapsed/inertia
    fitted_n = fitted_w*60/(2*np.pi)
    q = quality(t)
    if np.any(np.diff(n)>0):
        q["warnings"].append("Speed increases occur within the supplied coast-down; review noise or applied torque.")
    if np.any(fitted_w<=0):
        q["warnings"].append("Fitted positive-rotation model reaches zero; restrict the fitted window before zero speed.")
    if b==0 or tc==0:
        q["warnings"].append("A friction parameter hit its nonnegative bound; the data may not identify both terms reliably.")
    report = {"analysis": "coastdown_friction", "input_type": meta["input_type"],
              "confirmed_total_inertia_kg_m2": inertia, "quality": q,
              "zero_torque_evidence_type": kind, "zero_torque_evidence_interpretation": evidence,
              "fit": fit, "speed_fit_rmse_rpm": float(np.sqrt(np.mean((n-fitted_n)**2))),
              "model": "J*domega/dt = -b*omega - Tc, positive speed only; fixed independently supplied J.",
              "identifiability": "A single coast-down identifies b/J and Tc/J, not J, b, and Tc independently. Reported b and Tc depend on supplied J.",
              "limitations": ["Conditions are user-supplied evidence and cannot be verified by this script.",
                              "A small fit residual is not independent validation or a confidence interval.",
                              "Use a separate coast-down for validation; temperature, bearing state, and drag can change fitted values.",
                              "A nonzero current tolerance bounds rather than proves zero electromagnetic torque."],
              "metadata": meta}
    return np.column_stack([t,n,fitted_n,n-fitted_n]), ["time_s","n_rpm","fit_n_rpm","residual_rpm"], report

def execute(args):
    core, source = find_core(args.project_root)
    file, meta_file = Path(args.csv), Path(args.metadata)
    meta = json.loads(meta_file.read_text(encoding="utf-8-sig"))
    validate_metadata(meta, args.inertia)
    required = ["time_s","V_bus_V","I_fess_bus_A","n_rpm"] if args.command=="energy" else ["time_s","n_rpm"]
    if args.command=="coastdown" and meta.get("coastdown_conditions",{}).get("zero_torque_evidence_type")=="measured_motor_current":
        required.append("I_motor_A")
    data = read_csv(file, required)
    function = energy_analysis if args.command=="energy" else coastdown_analysis
    series, header, report = function(core,data,args.inertia,meta)
    report["data_notice"] = ("SYNTHETIC TEST DATA: not an experiment or native MATLAB/Simulink result."
        if meta["input_type"]=="synthetic_test_data" else "User-supplied measurement data; metadata and hardware conditions are not independently verified by this tool.")
    report.update(input_file=file.name, input_sha256=hashlib.sha256(file.read_bytes()).hexdigest(),
                  metadata_sha256=hashlib.sha256(meta_file.read_bytes()).hexdigest(),
                  numerical_core_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  tool_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    target = Path(args.output)
    target.mkdir(parents=True,exist_ok=False)
    np.savetxt(target/"series.csv",series,delimiter=",",header=",".join(header),comments="")
    (target/"summary.json").write_text(json.dumps(report,ensure_ascii=False,indent=2,allow_nan=False)+"\n",encoding="utf-8")
    print(f"Saved {report['analysis']} ({report['input_type']}): {target}")

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command",choices=["energy","coastdown"])
    p.add_argument("csv")
    p.add_argument("--inertia",type=float,required=True,help="Independently confirmed TOTAL rotor+flywheel J (kg m^2); no default")
    p.add_argument("--metadata",required=True)
    p.add_argument("--output",required=True,help="New directory; existing directories are rejected")
    p.add_argument("--project-root",help="Directory containing existing lab_analysis.py")
    try:
        execute(p.parse_args())
    except (ValueError,OSError,KeyError,TypeError) as error:
        p.exit(2,f"Input/analysis error: {error}\n")

if __name__=="__main__":
    main()
