# Flywheel Energy Storage Modeling and Control

MATLAB/Simulink models for a final-year project on urban rail transit braking energy recovery. The repository contains five motor–flywheel modeling stages, an integrated train-load/DC-link/converter simulation, and a separate synthetic rail DC-node dispatch study.

**Technologies:** MATLAB · Simulink · Dynamic Modeling · Feedback Control · Energy Storage

## Integrated system update — 21 September 2026

**[Integrated model, source and saved results](integrated-system/README.md)** · **[中文文件说明](integrated-system/docs/FILE_GUIDE_CN.md)** · **[Technical report](integrated-system/docs/THESIS_DRAFT_CN.md)**

The new integrated system connects synthetic railway demand, a DC link, a nonideal bidirectional converter and the DC motor–flywheel plant. Saved native MATLAB results cover **11 cases and 322 checks**; the native Simulink combined-parameter case passed **67 checks**. An independent reanalysis verifies the complete shared trace and energy accounts. Four paired scenarios show source-energy reductions of **1.46% to 9.50%**, including a common restoration phase and a spinning-bypass baseline. These are model results, not measured railway savings or round-trip efficiency.

The update includes the original runnable model, compressed native CSV evidence, verification scripts, laboratory-data analysis, a technical report and defense notes. Actual parameter identification and hardware validation remain outstanding. This integrated DC model does not implement PMSM/FOC or PSIM.

## Research study: schedule-informed rail storage dispatch

**[Research overview and results](research/rail-dispatch/README.md)** · **[Working manuscript](research/rail-dispatch/MANUSCRIPT.md)** · **[中文说明](research/rail-dispatch/README_CN.md)**

The study asks whether a frozen nominal-schedule rule saves additional source energy beyond a developed voltage-feedback controller using the same flywheel storage. It uses paired comparisons, explicit terminal restoration and energy-loss accounting. Across 100 independent synthetic scenarios, the mean increment is **0.0827 kWh (about 0.099%)**. The study also retains counterexamples and limits of the benefit.

The research directory includes a runnable Python check of saved MATLAB results, selected historical MATLAB sources for inspection, and an **unpublished, non-peer-reviewed working manuscript**. The DC-node study uses an aggregate storage model; it is separate from the motor-level Simulink stages below. Its public Python check does not rerun the simulations.

## Motor–flywheel project overview

The models progress from ideal flywheel dynamics to electromechanical coupling, cascaded control, and operating-mode supervision. Numerical values are provisional test parameters. The new integrated-system directory extends the original stages with a synthetic train load, DC link and bidirectional converter; actual parameter identification remains in progress.

## Simulation Stages

| Stage | Script | Purpose |
| --- | --- | --- |
| 1 | `FYP_Flywheel_Stage1_build.m` | Ideal flywheel: torque, speed, energy and mechanical power |
| 2 | `FYP_Flywheel_Stage2_build.m` | Viscous/Coulomb losses and speed protection |
| 3 | `FYP_Flywheel_Stage3_DCServo_build.m` | Open-loop DC motor electrical and flywheel mechanical coupling |
| 4 | `FYP_Flywheel_Stage4_v2_StableClosedLoop_build.m` | Cascaded proportional speed/current control, feedforward and limits |
| 5 | `FYP_Flywheel_Stage5_COMPLETE_v2.m` | Idle, charging, discharging and protection modes |

## Run

Requires MATLAB and Simulink. Set an extracted working copy of this repository as the MATLAB current folder, then run one stage, for example:

```matlab
FYP_Flywheel_Stage5_COMPLETE_v2
```

Each script builds its own model, simulates it and plots results. Scripts replace the matching `.slx` file in the current folder; use a working copy to preserve manually edited models. The supplied models accompany the original scripts; the scripts initialize the workspace parameters needed to reproduce them. MATLAB/Simulink execution has not been rechecked during this repository preparation.

## Core Relationships

- Flywheel energy: `E_f = 0.5 * J_f * omega^2`
- Mechanical dynamics: `J_total * d(omega)/dt = Kt*i - B*omega - Tc*sign(omega)`
- Armature dynamics: `L * di/dt = Va - R*i - Ke*omega`
- Mechanical power: `P = T * omega`

## Example Output

![Stage 5 simulation output supplied with the original project](results/stage5-results.png)

Original Stage 5 output supplied with the project, using temporary simulation parameters. It illustrates operating-mode behavior, rather than measured rail-system performance.

## Motor–flywheel engineering scope

This is an ongoing simulation study. The original Stage 4 uses proportional control with compensation. The integrated-system extension adds PI current control with anti-windup, a synthetic train/DC-bus load and a bidirectional converter model. Neither workstream establishes hardware performance, optimized physical design parameters or experimentally verified recovery efficiency.
