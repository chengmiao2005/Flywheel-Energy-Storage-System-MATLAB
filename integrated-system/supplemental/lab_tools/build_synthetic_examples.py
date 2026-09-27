"""Regenerate analytical SYNTHETIC TEST DATA; never represents an experiment."""
import json
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parent

def write_json(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def common(test_id):
    return dict(input_type="synthetic_test_data",test_id=test_id,inertia_confirmed_independently=True,
        inertia_source="合成解析测试的已知常数；不是实测惯量，也不是从仿真工程继承的硬件参数。",
        sensor_models_and_calibration="无传感器；全部由解析公式生成的合成测试数据。",
        sampling_and_time_alignment="同一解析时间轴；不含实测采集。")

def main():
    out=ROOT/"examples"
    out.mkdir(exist_ok=True)
    t=np.arange(5,dtype=float)
    power=np.array([0,20,0,-10,0],dtype=float)
    signed=np.r_[0,np.cumsum(.5*(power[:-1]+power[1:])*np.diff(t))]
    J=.4
    rotor=1000+signed-1.25*t
    rpm=np.sqrt(2*rotor/J)*60/(2*np.pi)
    np.savetxt(out/"SYNTHETIC_energy.csv",np.column_stack([t,np.full(5,10),power/10,rpm]),
        delimiter=",",header="time_s,V_bus_V,I_fess_bus_A,n_rpm",comments="")
    meta=common("SYNTHETIC_energy_analytic")
    meta.update(current_sign="positive_bus_into_fess",measurement_boundary="合成的整支路边界，输入正、回送负。",
        synthetic_total_inertia_kg_m2=J,
        expected=dict(imported_J=20,returned_J=10,net_input_J=10,rotor_change_J=5,net_input_minus_rotor_change_J=5),
        generating_equation="V=10; sampled P=[0,20,0,-10,0]; E_rotor=1000+integral(P)-1.25*t; J=0.4")
    write_json(out/"SYNTHETIC_energy_metadata.json",meta)
    t=np.linspace(0,100,1001)
    J,b,tc,w0=.5,.006,.04,300
    w=(w0+tc/b)*np.exp(-b*t/J)-tc/b
    np.savetxt(out/"SYNTHETIC_coastdown.csv",np.column_stack([t,w*60/(2*np.pi),np.zeros(len(t))]),
        delimiter=",",header="time_s,n_rpm,I_motor_A",comments="")
    meta=common("SYNTHETIC_coastdown_analytic")
    meta.update(synthetic_total_inertia_kg_m2=J,expected=dict(b_Nm_s_rad=b,Tc_Nm=tc),
        generating_equation="omega=(300+Tc/b)*exp(-b*t/J)-Tc/b; J=0.5,b=0.006,Tc=0.04",
        coastdown_conditions=dict(positive_rotation_only=True,no_external_torque=True,motor_electrically_isolated=True,
            isolation_evidence="合成测试的解析设定，非真实实验确认。",external_torque_evidence="合成测试设定无外加转矩。",
            zero_torque_evidence_type="measured_motor_current",
            motor_current_sensor_and_zero_check="仅为软件入口测试生成的全零电机电流；无实测传感器。",
            motor_current_tolerance_A=.001))
    write_json(out/"SYNTHETIC_coastdown_metadata.json",meta)
    print("Created explicitly labeled analytical SYNTHETIC TEST DATA in examples/.")

if __name__=="__main__":
    main()
