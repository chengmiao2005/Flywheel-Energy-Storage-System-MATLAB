"""Run offline tool checks and save a clearly scoped SYNTHETIC test report."""
import datetime,json,platform,sys,unittest
from pathlib import Path
import numpy,scipy
ROOT=Path(__file__).resolve().parent

class RecordedResult(unittest.TextTestResult):
    def __init__(self,*a,**k):
        super().__init__(*a,**k);self.records=[]
    def addSuccess(self,test):
        super().addSuccess(test);self.records.append({"test":test.id(),"status":"passed"})
    def addError(self,test,err):
        super().addError(test,err);self.records.append({"test":test.id(),"status":"error"})
    def addFailure(self,test,err):
        super().addFailure(test,err);self.records.append({"test":test.id(),"status":"failed"})

def main():
    suite=unittest.defaultTestLoader.discover(str(ROOT/"tests"),pattern="test_*.py")
    result=unittest.TextTestRunner(verbosity=2,resultclass=RecordedResult).run(suite)
    report={"scope":"Python offline laboratory tools only; all numerical fixtures are SYNTHETIC TEST DATA.",
        "does_not_establish":["Any new native MATLAB/Simulink execution","Any real experimental validation","Correct hardware parameters or sensor calibration","Measured round-trip efficiency"],
        "timestamp_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "environment":{"python":platform.python_version(),"numpy":numpy.__version__,"scipy":scipy.__version__},
        "tests_run":result.testsRun,"failures":len(result.failures),"errors":len(result.errors),
        "successful":result.wasSuccessful(),"tests":result.records}
    (ROOT/"test_report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    text=("# 离线分析工具测试记录\n\n全部数值样例为**合成测试数据**。本记录不代表实测验证，也不增加原生 MATLAB/Simulink 的通过项数。\n\n"
        f"执行：{report['timestamp_utc']}\n\n结果：{result.testsRun} 项测试；失败 {len(result.failures)} 项；错误 {len(result.errors)} 项。\n\n| 检查 | 状态 |\n|---|---|\n")
    text+="".join(f"| `{i['test'].split('.')[-1]}` | {i['status']} |\n" for i in result.records)
    text+="\n环境版本及完整列表见 `test_report.json`。包含解析能量、摩擦参数恢复、惯量缩放、无效数据与条件拒绝、CLI及输出保护。\n"
    (ROOT/"TEST_REPORT_CN.md").write_text(text,encoding="utf-8")
    return 0 if result.wasSuccessful() else 1
if __name__=="__main__":sys.exit(main())
