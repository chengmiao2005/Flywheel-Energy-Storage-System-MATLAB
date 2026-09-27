# 工程文件说明

学习仿真先看前两个文件，看曲线用第三个。其余文件用于结果复核和技术说明。

| 文件或目录 | 干什么用的 |
| --- | --- |
| `FYP_Flywheel_Integrated_….slx` | Simulink 模型：模块和连线 |
| `FYP_SimulinkSystem_v1.m` | 主程序：飞轮、母线、电机、变流器、控制器及仿真 |
| `FYP_ViewResults_v1.m` | 读取已有结果、显示曲线 |
| `results/` | 原生数据、图、配置、源码快照和检查记录 |
| `accepted_core/` | 原11工况MATLAB程序、C++参考与列车输入 |
| `verification/` | 隔离复核入口及新核验日志，不改原始结果 |
| `supplemental/analysis/` | 新参数敏感性计算、配对结果和图表 |
| `supplemental/lab_tools/` | 实测数据接入及分析工具，自测示例是合成数据 |
| `docs/PROJECT_REPORT_CN.md` | 技术报告 |
| `docs/TECHNICAL_FAQ_CN.md` | 文件讲解和答辩问题 |
| `docs/VALIDATION_SCOPE_CN.md` | 已有证据能证明什么、不能证明什么 |
| `handoff/` | 原有说明和参数资料，部分为较早交接版本 |
| `scheduler_output/` | 保存的C++调度参考结果 |
| `analysis/` | 原生结果派生指标与图表 |
| `.mpart`、`build_*.py` | 组装主程序和参考程序的辅助源码 |
| `.cpp`、`.hpp` | C++参考计算和输入数据 |
| `SOURCE_MANIFEST.json` | 核心验收输入文件哈希 |
| `release_manifest.json` | 历史发布清单，不代表全部新文件 |

- 学习实现：配套打开 `.slx` 和 `FYP_SimulinkSystem_v1.m`。
- 查看图表：在MATLAB运行 `FYP_ViewResults_v1`。
- 重跑整机：在MATLAB运行 `FYP_SimulinkSystem_v1`。
- 核对保存结果：在工程目录执行 `python verification/run_verification.py`。
- 新运行C++参考：上一条命令加 `--rerun-cpp`，需要g++。

完整包已包含解压CSV。核心 `.m`、`.slx`、输入和原生结果应配套保留；辅助核验通过不能等同于新的原生MATLAB运行或硬件实验完成。
