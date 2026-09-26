# 飞轮储能系统项目说明

本项目用 MATLAB/Simulink 模拟列车制动能量的吸收与再利用。系统将合成列车功率输入、直流母线、双向变流器和直流电机—飞轮连接起来，通过控制器协调储能、放能与转速恢复。

[英文说明](../README.md) · [模型与仿真报告](PROJECT_REPORT_CN.md) · [技术问答](TECHNICAL_FAQ_CN.md) · [验证范围](VALIDATION_SCOPE_CN.md)

## 系统怎样工作

- 列车用电时，从母线取电；列车制动回电时，向母线送回电能。
- 控制器结合列车功率、母线电压、飞轮转速及可释放的回收能量，给出储能或放能请求。
- 双向变流器调节电机电流。储能时电机使飞轮加速；放能时飞轮带动电机发电。
- 仿真记录电压、电流、转速、外部供电、各项损耗与储能变化，用于结果分析和能量核算。

![Simulink系统结构](../results/simulink/model_diagram.png)

## 核心文件

以下路径相对于 `integrated-system/`。

| 文件或目录 | 内容 |
| --- | --- |
| [`FYP_SimulinkSystem_v1.m`](../FYP_SimulinkSystem_v1.m) | 整机主程序，可构建模型、运行仿真并导出结果 |
| [`FYP_Flywheel_Integrated_20260921_182601.slx`](../FYP_Flywheel_Integrated_20260921_182601.slx) | 保存的Simulink模型，与配套主程序放在同一目录 |
| [`accepted_core/FYP_EnergyDispatch_v1.m`](../accepted_core/FYP_EnergyDispatch_v1.m) | 11个MATLAB测试场景的运行入口 |
| [`results/matlab/`](../results/matlab/) | MATLAB保存的原始数据、检查报告和源码快照 |
| [`results/simulink/`](../results/simulink/) | Simulink保存的原始数据、模型图、检查报告和源码快照 |
| [`analysis/`](../analysis/) | 对原始数据重新计算的指标与结果图 |
| [`verify_saved_results.py`](../verify_saved_results.py) | 核对文件完整性、能量账目、终态和两种运行方式的轨迹 |
| [`prepare_data.py`](../prepare_data.py) | 将压缩CSV还原，供MATLAB结果查看器读取 |
| [`FYP_ViewResults_v1.m`](../FYP_ViewResults_v1.m) | 在MATLAB中查看保存的结果 |
| [`lab_analysis.py`](../lab_analysis.py) | 分析符合规定边界和记录格式的实验数据；现有测试使用人工构造数据 |
| [`handoff/parameter_register.json`](../handoff/parameter_register.json) | 仿真参数及来源状态 |
| [`SOURCE_MANIFEST.json`](../SOURCE_MANIFEST.json) | 原始模型、源码和数据的哈希校验记录 |

`.m` 是MATLAB程序，`.slx` 是Simulink模型，`.csv` 是数据表，`.csv.gz` 是无损压缩的数据表，`.json` 是配置或检查记录。每次运行生成的 `ReviewBundle.zip` 是该次结果包，不是完整项目源码。

## 运行整机仿真

已有原生运行环境为 MATLAB R2024a 和 Simulink 24.1。下载仓库后，将 `integrated-system/` 设为MATLAB当前文件夹。

```matlab
FYP_SimulinkSystem_v1
```

程序构建新模型，运行20秒列车任务与70秒恢复过程，并在带时间戳的目录中保存模型、CSV、结果图及检查报告。模拟总时长为90秒，已有一次原生运行约需22分钟，实际耗时取决于电脑性能。

只构建模型而不运行：

```matlab
FYP_SimulinkSystem_v1('build')
```

也可以直接打开保存的 `.slx` 文件；它通过相邻的主程序调用计算功能。手动编辑模型时使用工作副本。

## 查看与复核结果

保存的原生MATLAB记录包含11个场景、322项检查；保存的原生Simulink综合参数偏差场景通过67项检查。两者共有9001个采样时刻和48个共享变量，逐项轨迹比较的最大差异约为各列原单位下的 `3.83e-9`。

两种运行方式共用核心物理计算，因此结果一致主要验证计算实现和接口衔接，不能代替独立的物理验证。

在 `integrated-system/` 中执行：

```bash
python -m pip install -r requirements.txt
python verify_saved_results.py
python -m unittest discover -s tests -v
```

上述命令复核保存的数据及分析工具，不会重新运行MATLAB仿真。若要在MATLAB查看保存的数据，先执行 `python prepare_data.py`，再运行 `FYP_ViewResults_v1`。

## 四组能量比较

| 测试条件 | 旁路外部供电 J | 飞轮调度外部供电 J | 降低比例 |
| --- | ---: | ---: | ---: |
| 标称参数 | 18646.37 | 18202.24 | 2.38% |
| 摩擦增大50% | 29976.19 | 29504.46 | 1.57% |
| 综合参数偏差 | 34770.77 | 34261.44 | 1.46% |
| 脉冲负载与综合偏差 | 35061.05 | 31731.59 | 9.50% |

每组都从相同初始状态出发，包含20秒任务和70秒恢复，并逐项检查最终飞轮、电感和电容储能。旁路组保留同一旋转飞轮，任务阶段不参与能量调度。

这些数值是给定仿真条件下的外部供电能量差。9.50%对应人为脉冲测试，不能推广为实车节能率，也不是往返效率。

![四组外部供电能量比较](../analysis/figures/energy_savings.png)

## 当前技术边界

当前模型使用暂定参数和合成列车输入，没有实测校准或硬件性能验证。实现基于直流电机与自定义PWM周期模型，不包含PMSM/FOC、PSIM或Simscape物理电路。

保存数据每0.01秒记录一次，可用于能量和慢动态分析，不能直接证明20 kHz开关纹波或亚毫秒电流响应。保护阈值属于仿真设定，不是实物额定值或安全认证。

仓库中的 [`research/rail-dispatch`](../../research/rail-dispatch/README_CN.md) 是采用聚合储能模型的独立调度研究，模型尺度、基准和比较协议与本整机仿真不同，结果不合并计算。
