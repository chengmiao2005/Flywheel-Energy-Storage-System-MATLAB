# 不改原始数据的离线复核

在项目工程目录执行：

```bash
python -m pip install -r requirements.txt
python verification/run_verification.py
```

已安装 g++ 时，可重新编译并执行90秒C++调度参考：

```bash
python verification/run_verification.py --rerun-cpp
```

每次输出到新的 `verification/runs/时间戳/`，已有目录拒绝覆盖。先查看 `verification_summary.json`。脚本在临时副本执行原有核验，输入文件运行前后逐个SHA-256比对；原始模型、源码、数据和验收记录不改动。

入口支持完整包解压CSV/MAT，也支持公开包的gzip CSV。解压只发生在临时目录。只有可选 `results/simulink/simulink_results.mat` 缺失时，MAT/CSV对比记录为 `SKIPPED`、差异为 `null`；其余必需的CSV、模型、源码快照与原生检查不跳过，也不会生成替代MAT。

| 输出 | 用途 |
| --- | --- |
| `verification_summary.json` | 本次实际结果、执行范围与限制 |
| `environment.json`、`input_sha256.json` | 运行环境、实际输入文件哈希 |
| `input_layout.json` | 临时解压的CSV与MAT是否存在 |
| `01_saved_results.log` | 11工况轨迹、能量与终态复核 |
| `02_native_evidence.log` | 模型连接、配置、快照、CSV和可选MAT核对 |
| `03_scheduler.log` | C++调度与静态端口检查 |
| `04_lab_analysis_synthetic_tests.log` | 9项解析合成数据检查；不是硬件实验 |
| `extended_checks.json` | 成对参数、固定名义控制器与保护方向核对 |
| `verified_metrics.json`、`case_metrics.csv` | 本次从原生轨迹重新计算的指标 |
| `scheduler_validation.json` | 明确区分本次C++与既有原生运行 |
| `scheduler_validation_legacy.json` | 原工具输出；其中PENDING是历史文字 |

布局兼容性测试：

```bash
python verification/smoke_test_public_layout.py --output verification/runs/public_layout_check
```

该测试从完整包临时构造压缩CSV、无MAT布局，调用同一个真实入口，不声称已经下载核验实时GitHub版本。

本轮环境重置后，入口源码被重新生成并重新实际验证。重置前的临时日志没有假装恢复；实际证据目录和时间以本次生成的JSON为准。存档原生MATLAB/Simulink记录仍是2026年9月21日，离线复核不会产生新的原生运行。

多个入口共享物理核心，结果一致支持实现核对，不替代独立物理模型、硬件或真实线路验证。20A是参考限幅，2850rpm是主动放电方向阈值，100Hz日志不能证明20kHz完整纹波。

公开仓库保留运行摘要、检查和指标；重复的C++大轨迹仅随完整工程包保存，可由复核命令重新生成。
