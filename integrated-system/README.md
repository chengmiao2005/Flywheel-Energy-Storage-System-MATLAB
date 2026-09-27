# 飞轮储能整机仿真

Flywheel Energy Storage System — MATLAB / Simulink

本工程把合成列车负载、动态直流母线、双向变流支路、直流电机与飞轮、闭环控制接成一套仿真。核心是配套的 `.m` 与 `.slx` 文件；模型采用自定义 Level-2 MATLAB S-function 和 PWM 周期内事件映射。

**[技术报告](docs/PROJECT_REPORT_CN.md)** · **[项目讲解与答辩问答](docs/TECHNICAL_FAQ_CN.md)** · **[验证范围](docs/VALIDATION_SCOPE_CN.md)** · **[文件说明](docs/FILE_GUIDE_CN.md)**

## 先看哪几个文件

| 文件 | 用途 |
| --- | --- |
| `FYP_Flywheel_Integrated_20260921_182601.slx` | 查看 Simulink 模块、连接及已有模型 |
| `FYP_SimulinkSystem_v1.m` | 飞轮、母线、电机、变流器、控制器的计算与仿真入口 |
| `FYP_ViewResults_v1.m` | 直接读取已有结果并显示曲线 |
| `results/matlab/`、`results/simulink/` | 原生结果、源码快照、配置和检查记录 |

`.slx` 与主 `.m` 配套使用。查看模型或已有曲线时，无需重新执行完整仿真。

## 在 MATLAB 中运行

已验证的原生环境为 MATLAB R2024a、Simulink 24.1。将本工程设为 MATLAB 当前文件夹：

```matlab
FYP_SimulinkSystem_v1('build') % 只构建新模型
FYP_SimulinkSystem_v1          % 构建并运行 90 s 综合偏差工况
FYP_ViewResults_v1             % 查看已保存结果
```

完整运行创建新的时间戳目录、轨迹、检查记录及 `ReviewBundle.zip`。既有一次原生运行耗时约二十多分钟，具体取决于电脑。11 工况的 MATLAB 入口为 `accepted_core/FYP_EnergyDispatch_v1.m`，进入该目录后运行。

完整包中的 CSV 已解压，并保留 MAT、FIG 等原生结果。公开 GitHub 版本可能使用无损压缩 CSV、省略冗余格式；若该版本包含 `prepare_data.py`，运行它可为 MATLAB 查看器恢复 CSV。

## 不运行 MATLAB 也能复核

在工程目录执行：

```bash
python -m pip install -r requirements.txt
python verification/run_verification.py
```

该入口在临时副本中调用既有核验，重新计算能量账本、终态比较、模型结构和检查记录，原始输入不变。每次生成 `verification/runs/时间戳/`，先看其中的 `verification_summary.json`。已安装 `g++` 时，可重新执行 90 s C++ 调度参考：

```bash
python verification/run_verification.py --rerun-cpp
```

[复核说明](verification/README_CN.md) · [本次完整包复核](verification/runs/recovered_full_20260927/verification_summary.json)

入口兼容压缩 CSV；解压只发生在临时目录。公开包若省略可选 MAT，摘要明确跳过 MAT/CSV 对比，其余核心核验仍执行，不生成替代 MAT 冒充证据。

| 证据 | 结果 | 含义 |
| --- | --- | --- |
| 保存的原生 MATLAB | 11 工况，322/322 | 保存记录中的数值与限值重新核对 |
| 保存的原生 Simulink | 1 个 90 s 工况，67/67 | 原生执行、模型结构及保存数据 |
| 两入口轨迹比较 | 9001 行、48 个共同列 | 最大差异约 3.83×10⁻⁹，各列采用自身单位 |
| Python 能量复核 | 11 工况通过 | 最大总能量残差约 9.66×10⁻⁶ J |
| C++ 调度参考 | 56/56 | C++ 执行，不能称为新的 MATLAB/Simulink 运行 |
| 比较与保护补充核对 | 213/213 | 成对参数、固定控制器和保护方向等 |
| 原实验分析工具合成测试 | 9/9 | 解析数值夹具，不是硬件实验 |

原生记录创建于2026-09-21。本轮环境重置后重新执行了离线核验，实际时间与环境见新的JSON；重置前丢失的临时日志没有被伪造重建。多个入口共享物理核心，一致性支持实现核对，不替代独立实物验证。

## 结果怎样理解

四组配对试验包括相同的20 s任务和70 s恢复，并分别核对终端转子、电感、电容储能。

| 工况 | 旁路源能量 J | 调度源能量 J | 减少比例 |
| --- | ---: | ---: | ---: |
| 标称 | 18646.37 | 18202.24 | 2.38% |
| 摩擦增加50% | 29976.19 | 29504.46 | 1.57% |
| 综合偏差 | 34770.77 | 34261.44 | 1.46% |
| 人工脉冲与综合偏差 | 35061.05 | 31731.59 | 9.50% |

这些是给定场景下90 s的源侧能量差。综合偏差减少509.33 J，其中任务段58.76 J、恢复段450.57 J。旁路仍保留旋转飞轮及其摩擦；结果不是实车普遍节能率、往返效率或完全拆除飞轮后的比较。

## 补充计算与实测分析

- [参数敏感性计算](supplemental/analysis/run_study.py)：固定名义控制器，拆分参数偏差，执行成对 C++ 数值试验。结果须连同 `study_summary.json`、`checks.json` 与执行记录阅读，不计入原生 MATLAB 的322项检查。
- [实测数据分析工具](supplemental/lab_tools/)：供实际数据接入、参数辨识和模型对比使用。示例及自测记录是合成数据，不能当成已经完成的实验。

```bash
python supplemental/analysis/run_study.py --project-root . --workers 4
```

补充研究执行12组配对、24次C++仿真，共同终态均通过；总体检查为 **945/948**。3项严格子账本恒等式略超原1e-7 J限值，失败记录与诊断保留，脚本完成输出后返回非零状态。不能写成全部验收通过；详细解释见研究报告与 `checks.json`。

## 验证与版本边界

物理参数暂定，列车输入为合成轨迹。20 A是参考电流限幅；2850 rpm是禁止继续主动放电的方向阈值，摩擦仍可使转速下降。20 kHz是计算及电流控制频率，100 Hz是常规日志采样率；这些日志不能证明完整开关纹波或亚毫秒阶跃性能。

原始 `scheduler_output/validation.json` 中 `PENDING` 是参考工具保留的历史文字，不否定 `results/simulink/` 中已经存在的67/67原生运行。新复核输出区分既有原生证据和本次C++执行。

`release_manifest.json` 是历史发布快照，可能不覆盖新增文件或更新后的说明。`SOURCE_MANIFEST.json` 校验保留的核心验收输入；每次复核另存 `input_sha256.json`。历史清单不能代替最终交付包的完整文件清单。

当前没有实测硬件验证、真实线路验证、PMSM/FOC或PSIM实现，也未验证嵌入式代码生成。详细范围见[验证范围](docs/VALIDATION_SCOPE_CN.md)。
