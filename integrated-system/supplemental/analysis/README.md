# 固定控制器参数敏感性研究

先读 study_report.md。相同12对24次C++运行已在执行环境重置后重建，无新增科学工况。复用已有核心，不是原生MATLAB、硬件或独立物理验证。

结果：12/12对共同终态有效；945/948检查通过，保留3项严格1e-7 J子账本诊断越限，不能称为全通过。first_checks_876.json 明确是原检查子集的重建。

主要文件：study_summary.json、paired_summary.csv、case_metrics.csv、loss_decomposition.csv；figures/有三组PNG/SVG；公开仓库results/有24份指标JSON，完整交付包另含对应9001×48轨迹CSV.xz；diagnostics/有精度诊断；execution_provenance.json与study_manifest.json有哈希和环境记录。

在含accepted_core的工程目录运行：

```bash
python supplemental/analysis/run_study.py --project-root . --workers 4
```

已有完整轨迹时，只重建报告和图：

```bash
python supplemental/analysis/run_study.py --project-root . --analyze-only
```

要求g++ C++17、Python3、NumPy、Matplotlib；CSV.xz是无损压缩，可用7-Zip或Python lzma打开。默认先写完整结果再因3条失败返回非0；不应将这解释为没有结果或忽略后声称验收全通过。编译二进制不随交付提供。

母线极值是完整90s的50μs边界采样口径，不与旧20s任务段10ms记录极值混用。

## 公开仓库中的完整轨迹

公开仓库保留源码、指标、检查、图和执行记录；24个完整CSV.xz另随完整下载包及原始数据附件提供。运行默认命令可重建轨迹；--analyze-only需要先放入这些文件。study_manifest.json描述完整研究快照，公开仓库不是该完整快照。
