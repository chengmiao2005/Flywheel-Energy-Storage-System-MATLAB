# Historical MATLAB sources for inspection

These are byte-preserved source files from the archived simulation work. Their SHA-256 hashes and original locations within the historical verification packet are in [SOURCE_MANIFEST.json](SOURCE_MANIFEST.json).

| File | Role |
| --- | --- |
| `FYP_DCSchedule_v1.m` | Frozen schedule and causal-policy comparisons, DC-node execution and terminal evaluation |
| `FYP_DCThreshold_v1.m` | Equal-budget development search for voltage thresholds |
| `FYP_DCHoldout_v1.m` | Frozen-policy 100-scenario synthetic evaluation and primary statistics |

**These files are not a self-contained MATLAB rerun package.** In particular, the holdout entry requires the full upstream Threshold and Schedule output directories: settings MAT files, saved checks and baseline metrics, source snapshots and a nominal plan. Those dependencies are not all bundled here. The original function headers and file checks specify the requirements. No full MATLAB execution was performed when preparing this public subset.

For a runnable check of the public metric tables, use [../verify_results.py](../verify_results.py). That Python script recomputes saved-result statistics and energy accounts; it does not replace the original simulation.

Model, experiment and code development received substantial ChatGPT/Codex assistance, as disclosed in the [research overview](../README.md).
