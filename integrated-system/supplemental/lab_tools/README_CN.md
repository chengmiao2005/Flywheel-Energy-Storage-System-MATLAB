# 实测数据接入与滑行摩擦辨识

**已完成：离线工具、输入模板、解析合成样例和自动检查。未完成：真实设备参数确认、采集、实测结果与硬件验证。** 本目录不控制硬件，主仿真文件保持原样。

原工程已有 `lab_analysis.py` 和 `handoff/FYP_AnalyzeLabData_v1.m`。这里复用前者的能量积分与摩擦拟合算法，补上命令行入口、条件检查、可复现样例和数据质量摘要。只看已有仿真时不需要运行它。

## 1. 先试合成样例

在包含 `lab_analysis.py`、`requirements.txt` 的**项目工程根目录**打开终端。完整交付包中本目录位于 `supplemental/lab_tools/`。需要 Python 3.10 或更高版本。

```bash
python -m pip install -r requirements.txt
python supplemental/lab_tools/fyp_lab_cli.py energy supplemental/lab_tools/examples/SYNTHETIC_energy.csv --inertia 0.4 --metadata supplemental/lab_tools/examples/SYNTHETIC_energy_metadata.json --output LabDemo_energy --project-root .
python supplemental/lab_tools/fyp_lab_cli.py coastdown supplemental/lab_tools/examples/SYNTHETIC_coastdown.csv --inertia 0.5 --metadata supplemental/lab_tools/examples/SYNTHETIC_coastdown_metadata.json --output LabDemo_coastdown --project-root .
```

分别生成新的 `LabDemo_energy/` 和 `LabDemo_coastdown/`，含 `series.csv` 和 `summary.json`。已有输出目录会拒绝覆盖；重跑时换一个目录名。

**上面的 0.4、0.5 和所有示例 CSV 都是合成解析测试值，不是实测惯量，不能直接用作硬件参数。** 合成能量示例的解析结果为输入 20 J、回送 10 J、转子储能增加 5 J、能量余额 5 J。滑行示例的已知值为 `b=0.006 N·m·s/rad`、`Tc=0.04 N·m`；有限采样下拟合会有很小数值误差。

## 2. 接入真实能量测量

复制 `templates/energy_measurement.csv`、`energy_measurement_metadata.json` 后填入真实信息。

| 列名 | 含义 |
|---|---|
| `time_s` | 同步时间，秒，严格递增 |
| `V_bus_V` | 母线电压，伏，本工具要求大于 0 |
| `I_fess_bus_A` | 整个飞轮支路电流，安；母线流入飞轮支路为正，回送为负 |
| `n_rpm` | 飞轮转速，rpm，本工具只处理非负转向 |

必须使用整个储能支路电流，不能拿电机电流、整车电流或电源总电流替代。同步、校准和电流方向需要根据采集记录确认，代码不能替代确认。

`--inertia` 必须显式填写独立确认的**电机转子＋飞轮总惯量**，单位 kg·m²。没有默认值。不能从滑行曲线同时反推 J、b、Tc，也不能把仿真 J 当成实测 J。JSON 的 `inertia_source` 写测量/计算依据，确认后才将 `inertia_confirmed_independently` 改为 `true`。

真实运行命令沿用第一条，将 CSV、JSON、惯量和输出目录替换为真实值。模板中的空项和 `false` 是有意保留的；未填写时拒绝分析。

- `imported_J`：母线输入飞轮支路的能量。
- `returned_J`：飞轮支路回送母线的能量。
- `rotor_change_J`：末态转子动能减初态转子动能。
- `net_input_minus_rotor_change_J`：输入减回送，再减转子动能变化。

最后一项还含电容/电感等内部储能变化及测量误差，**不能直接称为全部损耗**。本入口始终不输出往返效率。能量采用实际时间戳，对采样的 `V×I` 分段线性积分，并在功率过零时分开计算；它不能恢复采样间的 PWM 纹波。

## 3. 接入真实滑行记录，拟合 b 和 Tc

复制 `templates/coastdown_measurement.csv`、`coastdown_metadata.json`。选择始终正转、速度有足够下降的独立滑行时段。至少要求 5% 转速跨度；这只是数值入口条件，并不保证实验足以准确辨识两个参数。

采用 `J·dω/dt = -b·ω - Tc`，J 为事先独立确认的常数。拟合非负的等效黏性摩擦系数 b 与恒定摩擦转矩 Tc。积分方程避免直接对转速差分，但仍受转速噪声和采样误差影响，不自动给置信区间。

**支路电流为零，不代表电机转矩为零。** 变换器内可能有续流通路。JSON 必须有无外加转矩、正转、电气隔离的真实记录，且满足一个证据入口：

| `zero_torque_evidence_type` | 需要提供的证据 |
|---|---|
| `measured_motor_current` | CSV 额外含独立测得的 `I_motor_A`；记录传感器零点/精度及 `motor_current_tolerance_A`；同时说明实际电气隔离状态 |
| `documented_open_circuit` | 有依据确认电机真正开路，包含变换器和二极管在内无闭合电流通路；填 `open_circuit_evidence` 并确认 `open_circuit_no_closed_current_path=true`；CSV 可只含时间和转速 |

第二种入口依据开路记录**假设零电磁转矩**，报告明确“本入口没有测量电机电流”，不会把假设生成的零向量写成实测值。第一种入口的电流容差也只能给残余电磁转矩设定范围，不能证明其严格为零。

若 J 也未知，一条滑行轨迹仅约束 `b/J`、`Tc/J`，无法唯一确定 J、b、Tc 三个参数。拟合后应用**另一段独立滑行**核验，记录温度、轴承状态和装配条件。拟合残差小不等于独立验证。

## 4. 检查与交付边界

拒绝缺列、非数值/NaN/Inf、重复/倒序时间、无效符号、缺少惯量依据、滑行条件不全、电机电流超限及转速范围不足。采样大缺口或不均匀会告警；保留原时间戳，不偷偷滤波、补点或修正零偏。

```bash
python supplemental/lab_tools/build_synthetic_examples.py
python supplemental/lab_tools/run_tests.py
```

`TEST_REPORT_CN.md`、`test_report.json` 只记录本工具的 Python 合成测试，**不增加既有 322 项 MATLAB / 67 项 Simulink 检查，也不代表新的原生运行或硬件验证**。

真正继续到实测结果，仍需：

1. 独立确认的总惯量及来源；设备允许工况和测试范围由实验室确认。
2. 同步原始 CSV、传感器/零点校准、采样率及通道对齐说明。
3. 支路测量边界和电流方向；滑行另需实际开路/独立电机电流证据及无外加转矩记录。
4. 测试编号、日期、温度/轴承状态，以及一段独立复核记录。

**尚无真实数据，这些条件保持待提供；现有工具和合成样例均不冒充实验成果。**
