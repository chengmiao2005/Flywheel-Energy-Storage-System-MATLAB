#!/usr/bin/env python3
"""Recalculate archived rail-dispatch results. No solver or new scenarios run.

Run: python verify_results.py
Save to a NEW file: python verify_results.py --output verification/local_run.json
"""
from pathlib import Path
import argparse
import gzip
import hashlib
import io
import itertools
import json
import platform

import numpy as np
import pandas as pd
import scipy
from scipy.stats import t as student_t

HERE = Path(__file__).resolve().parent
KEY = ["SceneID", "PolicyID", "SOC0", "dt_s"]
SCENES, POLICIES, SOCS, STEPS = range(1, 101), [1, 2, 3], [.55, .85], [.00125, .000625]
FILES = {
    "summary": "data/HoldoutSummary.csv.gz",
    "original": "data/HoldoutOriginalMetrics.csv.gz",
    "manifest": "data/HoldoutManifest.csv",
    "policies": "data/FrozenPolicies.csv",
    "expected_scene": "expected/HoldoutSceneEffects.csv",
    "expected_primary": "expected/HoldoutPrimarySummary.csv",
}
# Declared zero-rotor-loss model and original numerical comparison tolerances.
ETA = np.sqrt(.87)
CAPACITANCE_F, STORAGE_KWH = 1.5, 4.5
LEDGER_TOL, STORED_TOL, VOLTAGE_TOL = 1e-6, 1e-8, 1e-6
STEP_ENERGY_TOL, STEP_VOLTAGE_TOL = .005, .1
ARCHIVE_TOL, ZERO_TOL = 3e-11, 1e-6


def require(condition, message):
    """Explicit checks remain active even under python -O."""
    if not bool(condition):
        raise ValueError(message)


def maxabs(values):
    values = np.asarray(values, dtype=float)
    require(values.size > 0 and np.isfinite(values).all(), "Missing or nonfinite numeric values")
    return float(np.max(np.abs(values)))


def close(actual, expected, name, tolerance=ARCHIVE_TOL):
    a, b = np.asarray(actual, dtype=float), np.asarray(expected, dtype=float)
    require(a.shape == b.shape, name + ": shape mismatch")
    difference = maxabs(a - b)
    require(difference <= tolerance, f"{name}: difference {difference:g} exceeds {tolerance:g}")
    return difference


def load_inputs():
    manifest = json.loads((HERE / "data/SHA256_MANIFEST.json").read_text(encoding="utf8"))
    require(manifest["schema_version"] == 1, "Unsupported hash manifest")
    require(set(manifest["files"]) == set(FILES.values()), "Unexpected hash manifest members")
    frames = {}
    for name, relative in FILES.items():
        meta = manifest["files"][relative]
        stored = (HERE / relative).read_bytes()
        require(hashlib.sha256(stored).hexdigest() == meta["stored_sha256"], relative + ": stored hash mismatch")
        raw = gzip.decompress(stored) if relative.endswith(".gz") else stored
        require(len(raw) == meta["original_bytes"], relative + ": original length mismatch")
        require(hashlib.sha256(raw).hexdigest() == meta["uncompressed_sha256"], relative + ": original hash mismatch")
        frames[name] = pd.read_csv(io.BytesIO(raw))
    return frames


def key_frame(frame, name):
    expected = set(itertools.product(SCENES, POLICIES, SOCS, STEPS))
    require(len(frame) == 1200 and not frame.duplicated(KEY).any(), name + ": incomplete or duplicate records")
    require(set(frame.set_index(KEY).index) == expected, name + ": incorrect scene/policy/SOC/step keys")
    # Entirely empty CSV failure columns are parsed as numeric NaNs by pandas.
    # They are checked as empty strings below; every measured numeric field must be finite.
    measured = frame.drop(columns=["FailureStage", "FailureIdentifier", "FailureMessage"])
    require(np.isfinite(measured.select_dtypes(include="number").to_numpy()).all(), name + ": nonfinite fields")
    require(frame.Success.eq(1).all(), name + ": failed execution")
    for col in ["FailureStage", "FailureIdentifier", "FailureMessage"]:
        require(frame[col].fillna("").astype(str).str.strip().eq("").all(), name + ": populated failure fields")
    return frame.set_index(KEY).sort_index()


def paired(frame, column, test=2, step=.000625):
    values = frame.xs(step, level="dt_s")[column].unstack("PolicyID")
    return values[1] - values[test]


def verify():
    f = load_inputs()
    s, o = key_frame(f["summary"], "Summary"), key_frame(f["original"], "Original")
    require(s.index.equals(o.index), "Original/summary key alignment differs")
    require(s.Comparable.eq(1).all(), "Noncomparable terminal condition")
    policies = f["policies"].set_index("PolicyID").sort_index()
    require(list(policies.index) == POLICIES, "Incorrect policy IDs")
    close(policies[["ChargeThreshold_V", "DischargeThreshold_V"]], [[820, 710], [780, 710], [820, 710]], "Frozen thresholds", 0)
    for pid in POLICIES:
        p = policies.loc[pid]
        for frame in [s, o]:
            part = frame.xs(pid, level="PolicyID")
            require(part.Controller.eq(p.Controller).all(), "Controller label differs from frozen policy")
            require(part.ChargeThreshold_V.eq(p.ChargeThreshold_V).all() and part.DischargeThreshold_V.eq(p.DischargeThreshold_V).all(), "Changed thresholds")

    m = f["manifest"].set_index("SceneID").sort_index()
    require(len(m) == 100 and not m.index.duplicated().any() and list(m.index) == list(SCENES), "Scene manifest keys differ")
    uniform = np.random.RandomState(2026091701).random_sample(300).reshape((100, 3), order="F")
    close(m[["UniformMassA", "UniformMassB", "UniformOffset"]], uniform, "Archived MT19937 draws", 2e-14)
    parameters = np.column_stack([.95 + .1 * uniform[:, 0], .95 + .1 * uniform[:, 1], 32.5 + 5 * uniform[:, 2]])
    fields = ["MassFactorA", "MassFactorB", "ActualOffset_s"]
    close(m[fields], parameters, "Manifest transforms")
    for frame in [s, o]:
        expected = m.loc[frame.index.get_level_values("SceneID"), fields].to_numpy()
        close(frame[fields], expected, "Row parameters")

    close(s.OriginalSource_kWh, o.Source_kWh, "Original source copy")
    close(s.OriginalTerminalStored_kWh, o.FinalStored_kWh, "Original storage copy")
    close(s.CombinedSource_kWh, s.OriginalSource_kWh + s.TailSource_kWh, "Source period sum")
    close(o.InitialStored_kWh, o.index.get_level_values("SOC0").to_numpy() * STORAGE_KWH, "Initial energy")
    close(s.TargetStored_kWh, o.InitialStored_kWh, "Common storage target")
    close(s.FinalStored_kWh, s.TargetStored_kWh, "Restored stored energy", STORED_TOL)
    terminal_v = (750 + np.sqrt(750**2 - 4 * .02 * 200000)) / 2
    close(s.FinalVoltage_V, np.full(len(s), terminal_v), "Restored voltage", VOLTAGE_TOL)
    require(s.RestorationEnd_s.between(0, 174).all(), "Restoration misses common deadline")
    close(s.TailLoad_kWh, np.full(len(s), 200000 * 194 / 3.6e6), "Common continuation load")
    close(o.ConversionLoss_kWh, (1 - ETA) * o.ChargeBus_kWh + (1 / ETA - 1) * o.DischargeBus_kWh, "Original conversion")
    close(s.TailConversionLoss_kWh, (1 - ETA) * s.TailChargeBus_kWh + (1 / ETA - 1) * s.TailDischargeBus_kWh, "Continuation conversion")
    close(o.FinalCapacitor_kWh, .5 * CAPACITANCE_F * o.FinalVoltage_V**2 / 3.6e6, "Original capacitor")
    close(s.FinalCapacitor_kWh, .5 * CAPACITANCE_F * s.FinalVoltage_V**2 / 3.6e6, "Final capacitor")
    complete_chopper = o.Chopper_kWh + s.TailChopper_kWh
    complete_resistance = o.SourceResistanceLoss_kWh + s.TailSourceResistanceLoss_kWh
    complete_conversion = o.ConversionLoss_kWh + s.TailConversionLoss_kWh
    complete_loss = complete_chopper + complete_resistance + complete_conversion
    close(s.CombinedDissipation_kWh, complete_loss, "Complete dissipation sum")
    residuals = {
        "OriginalSourceSplit_kWh": o.Source_kWh - o.SourceToBus_kWh - o.SourceResistanceLoss_kWh,
        "OriginalStorage_kWh": o.FinalStored_kWh - o.InitialStored_kWh - ETA * o.ChargeBus_kWh + o.DischargeBus_kWh / ETA,
        "OriginalBus_kWh": o.SourceToBus_kWh - o.NetTrain_kWh - o.Chopper_kWh - o.ChargeBus_kWh + o.DischargeBus_kWh - (o.FinalCapacitor_kWh - o.InitialCapacitor_kWh),
        "TailSourceSplit_kWh": s.TailSource_kWh - s.TailSourceToBus_kWh - s.TailSourceResistanceLoss_kWh,
        "TailStorage_kWh": s.FinalStored_kWh - o.FinalStored_kWh - ETA * s.TailChargeBus_kWh + s.TailDischargeBus_kWh / ETA,
        "CompleteSystem_kWh": s.CombinedSource_kWh - o.NetTrain_kWh - s.TailLoad_kWh - complete_loss - (s.FinalStored_kWh - o.InitialStored_kWh) - (s.FinalCapacitor_kWh - o.InitialCapacitor_kWh),
    }
    maxima = {name: maxabs(value) for name, value in residuals.items()}
    require(max(maxima.values()) < LEDGER_TOL, "Reconstructed energy balance exceeds tolerance")
    close(residuals["CompleteSystem_kWh"], s.CombinedSystemResidual_kWh, "Archived complete ledger residual")

    fine = paired(s, "CombinedSource_kWh")
    coarse = paired(s, "CombinedSource_kWh", step=.00125)
    require(len(fine) == len(coarse) == 200 and fine.groupby(level="SceneID").size().eq(2).all(), "Incomplete SOC pairs")
    scene, scene_coarse = fine.groupby(level="SceneID").mean(), coarse.groupby(level="SceneID").mean()
    n, mean, sd = len(scene), float(scene.mean()), float(scene.std(ddof=1))
    se, critical = sd / np.sqrt(n), float(student_t.ppf(.975, n - 1))
    reference = s.xs(.000625, level="dt_s").xs(1, level="PolicyID").CombinedSource_kWh.mean()
    testmean = s.xs(.000625, level="dt_s").xs(2, level="PolicyID").CombinedSource_kWh.mean()
    require(reference > 0, "Nonpositive percentage denominator")
    primary = {
        "InferentialN": n, "MeanSaving_kWh": mean, "SceneSD_kWh": sd,
        "SceneSE_kWh": float(se), "DegreesOfFreedom": n - 1, "T975Critical": critical,
        "Approx95Lower_kWh": float(mean - critical * se), "Approx95Upper_kWh": float(mean + critical * se),
        "CoarseMeanSaving_kWh": float(scene_coarse.mean()),
        "FineMinusCoarseMean_kWh": float(mean - scene_coarse.mean()),
        "MaxAbsSceneMeanStepChange_kWh": maxabs(scene - scene_coarse),
        "MaxAbsSOCSpecificStepChange_kWh": maxabs(fine - coarse),
        "MinSceneSaving_kWh": float(scene.min()), "MaxSceneSaving_kWh": float(scene.max()),
        "NegativeSceneCount": int((scene < -ZERO_TOL).sum()),
        "NearZeroSceneCount": int((scene.abs() <= ZERO_TOL).sum()),
        "PositiveSceneCount": int((scene > ZERO_TOL).sum()),
    }
    expected_scene = f["expected_scene"].set_index("SceneID").sort_index()
    require(len(expected_scene) == n and expected_scene.index.equals(scene.index), "Expected scene keys differ")
    require(expected_scene.Complete.eq(1).all(), "Archived scene incomplete")
    close(scene, expected_scene.PrimaryFineMeanSOCSaving_kWh, "Archived fine scene effects")
    close(scene_coarse, expected_scene.PrimaryCoarseMeanSOCSaving_kWh, "Archived coarse scene effects")
    require(len(f["expected_primary"]) == 1, "Expected primary summary cardinality differs")
    expected = f["expected_primary"].iloc[0]
    require(expected.InferenceGatePass == 1 and expected.PlannedScenes == n and expected.CompleteScenes == n, "Archived inference gate differs")
    archive_difference = max(close(value, expected[name], "Archived " + name) for name, value in primary.items())
    primary.update({"MeanReferenceSource_kWh": float(reference), "MeanScheduleSource_kWh": float(testmean),
                    "RatioOfMeanSavingToMeanReference_percent": float(100 * mean / reference)})
    steps = {}
    for label, frame, energy_cols, voltage_cols in [
        ("Original", o, ["Source_kWh", "Chopper_kWh", "SourceResistanceLoss_kWh", "ConversionLoss_kWh", "FinalStored_kWh", "FinalCapacitor_kWh", "ChargeBus_kWh", "DischargeBus_kWh"], ["Vmin_V", "Vmax_V", "FinalVoltage_V"]),
        ("Complete", s, ["CombinedSource_kWh", "CombinedDissipation_kWh", "TailSource_kWh", "TailSourceResistanceLoss_kWh", "TailChopper_kWh", "TailConversionLoss_kWh", "TailChargeBus_kWh", "TailDischargeBus_kWh", "FinalStored_kWh", "FinalCapacitor_kWh"], ["TailVmin_V", "TailVmax_V", "FinalVoltage_V"]),
    ]:
        delta = frame.xs(.000625, level="dt_s")[energy_cols + voltage_cols] - frame.xs(.00125, level="dt_s")[energy_cols + voltage_cols]
        steps[label + "MaxEnergyChange_kWh"] = maxabs(delta[energy_cols])
        steps[label + "MaxVoltageChange_V"] = maxabs(delta[voltage_cols])
        require(steps[label + "MaxEnergyChange_kWh"] <= STEP_ENERGY_TOL and steps[label + "MaxVoltageChange_V"] <= STEP_VOLTAGE_TOL, "Individual step check failed")
    require(maxabs(fine - coarse) <= STEP_ENERGY_TOL, "Primary paired step check failed")
    steps["PrimaryResolvedSignChanges"] = int(((fine.abs() > ZERO_TOL) & (coarse.abs() > ZERO_TOL) & (np.sign(fine) != np.sign(coarse))).sum())
    components = s.assign(CompleteChopper=complete_chopper, CompleteResistance=complete_resistance, CompleteConversion=complete_conversion)
    decomposition = {name: float(paired(components, col).mean()) for name, col in {
        "OriginalSourceSaving_kWh": "OriginalSource_kWh", "ContinuationSourceSaving_kWh": "TailSource_kWh",
        "ChopperSaving_kWh": "CompleteChopper", "SourceResistanceSaving_kWh": "CompleteResistance",
        "ConversionSaving_kWh": "CompleteConversion"}.items()}
    close(decomposition["OriginalSourceSaving_kWh"] + decomposition["ContinuationSourceSaving_kWh"], mean, "Period saving reconciliation")
    close(sum(decomposition[k] for k in ["ChopperSaving_kWh", "SourceResistanceSaving_kWh", "ConversionSaving_kWh"]), mean, "Loss saving reconciliation", 2 * LEDGER_TOL)
    gross = decomposition["ChopperSaving_kWh"] + decomposition["SourceResistanceSaving_kWh"]
    require(gross > 0, "Nonpositive conversion-offset denominator")
    decomposition["ConversionOffset_percent"] = -100 * decomposition["ConversionSaving_kWh"] / gross
    secondary = paired(s, "CombinedSource_kWh", test=3).groupby(level="SceneID").mean()
    close(secondary, expected_scene.SecondaryFineMeanSOCSaving_kWh, "Archived secondary effects")
    return {
        "Pass": True, "Scope": "Archived summary-record recalculation only",
        "InputFilesHashVerified": len(FILES), "OriginalRecords": len(o), "CompleteRecords": len(s),
        "PairedSOCConditionsAtFineStep": len(fine), "Primary": primary,
        "PrimaryEnergyDecomposition": decomposition, "MaximumRecomputedBalanceResiduals": maxima,
        "StepDiagnostics": steps, "MaximumPrimaryDifferenceFromArchivedSummary": archive_difference,
        "SecondaryMatchedThresholdMean_kWh": float(secondary.mean()),
        "TestedEnvironment": {"Python": platform.python_version(), "Platform": platform.system(),
                              "NumPy": np.__version__, "pandas": pd.__version__, "SciPy": scipy.__version__},
        "MATLABExecuted": False, "CppExecuted": False, "NewScenarios": 0,
        "Limitations": [
            "The approximate mean interval is conditional on the frozen synthetic generator, nominal efficiency, zero rotor loss and declared 194 s continuation.",
            "Two SOCs and two integration steps are repetitions, not additional independent scenes.",
            "This script does not rerun the train or DC model, decode scene MAT files, or audit saved C++ reference outputs.",
            "Later seven-case diagnostics and field or hardware performance are outside this package.",
            "Step comparisons are numerical diagnostics, not rigorous error bounds. Hashes do not prove external preregistration."
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional NEW JSON file; existing files are never overwritten.")
    args = parser.parse_args()
    if args.output is not None:
        require(not args.output.exists(), "Output file already exists; choose a new filename")
        require(args.output.parent.is_dir(), "Output parent directory does not exist")
    report = verify()
    text = json.dumps(report, indent=2, allow_nan=False) + "\n"
    if args.output is not None:
        with args.output.open("x", encoding="utf8") as stream:
            stream.write(text)
    print(text, end="")


if __name__ == "__main__":
    main()
