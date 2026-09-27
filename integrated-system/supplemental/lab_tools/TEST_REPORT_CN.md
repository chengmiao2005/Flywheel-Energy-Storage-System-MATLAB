# 离线分析工具测试记录

全部数值样例为**合成测试数据**。本记录不代表实测验证，也不增加原生 MATLAB/Simulink 的通过项数。

执行：2026-09-27T07:57:58.195067+00:00

结果：18 项测试；失败 0 项；错误 0 项。

| 检查 | 状态 |
|---|---|
| `test_analytic_coastdown_recovers_known_friction` | passed |
| `test_analytic_energy_budget` | passed |
| `test_branch_current_is_not_motor_current_evidence` | passed |
| `test_cli_coastdown_end_to_end` | passed |
| `test_cli_energy_end_to_end` | passed |
| `test_cli_has_no_default_inertia` | passed |
| `test_current_sign_declaration_required` | passed |
| `test_documented_open_circuit_speed_only_route` | passed |
| `test_independently_confirmed_inertia_required` | passed |
| `test_inertia_scaling_shows_identifiability_limit` | passed |
| `test_invalid_timestamps_and_nonfinite_csv_rejected` | passed |
| `test_irregular_timestamps_preserved` | passed |
| `test_missing_isolation_evidence_rejected` | passed |
| `test_narrow_speed_span_rejected` | passed |
| `test_nonzero_motor_current_rejected` | passed |
| `test_output_directory_cannot_overwrite_existing` | passed |
| `test_power_zero_crossing_areas` | passed |
| `test_voltage_and_speed_sign_rejected` | passed |

环境版本及完整列表见 `test_report.json`。包含解析能量、摩擦参数恢复、惯量缩放、无效数据与条件拒绝、CLI及输出保护。
