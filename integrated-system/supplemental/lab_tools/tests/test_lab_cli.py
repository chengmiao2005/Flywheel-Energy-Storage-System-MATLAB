"""All numerical fixtures are SYNTHETIC. No real-data or MATLAB claims."""
from copy import deepcopy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
import fyp_lab_cli as cli

class OfflineLabTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core,_=cli.find_core()
        cls.energy_meta=json.loads((ROOT/"examples/SYNTHETIC_energy_metadata.json").read_text(encoding="utf-8"))
        cls.coast_meta=json.loads((ROOT/"examples/SYNTHETIC_coastdown_metadata.json").read_text(encoding="utf-8"))

    def energy(self):
        return cli.read_csv(ROOT/"examples/SYNTHETIC_energy.csv",["time_s","V_bus_V","I_fess_bus_A","n_rpm"])

    def coast(self):
        return cli.read_csv(ROOT/"examples/SYNTHETIC_coastdown.csv",["time_s","n_rpm","I_motor_A"])

    def test_analytic_energy_budget(self):
        _,_,report=cli.energy_analysis(self.core,self.energy(),.4,self.energy_meta)
        for key,expected in self.energy_meta["expected"].items():
            self.assertAlmostEqual(report[key],expected,places=9)
        self.assertNotIn("round_trip_efficiency",report)

    def test_power_zero_crossing_areas(self):
        imported,returned=self.core.split_energy([0,1,2],[2,-2,2])
        self.assertAlmostEqual(imported[-1],1)
        self.assertAlmostEqual(returned[-1],1)

    def test_irregular_timestamps_preserved(self):
        d=self.energy()
        d["time_s"]=np.array([0,1,2,3,10])
        d["V_bus_V"][:]=10
        d["I_fess_bus_A"][:]=1
        _,_,report=cli.energy_analysis(self.core,d,.4,self.energy_meta)
        self.assertAlmostEqual(report["imported_J"],100)
        self.assertTrue(report["quality"]["warnings"])

    def test_invalid_timestamps_and_nonfinite_csv_rejected(self):
        for rows in ("0,1000\n0,900\n1,800\n","0,1000\n1,nan\n2,800\n","0,1000\n2,900\n1,800\n"):
            with self.subTest(rows=rows),tempfile.TemporaryDirectory() as tmp:
                file=Path(tmp)/"invalid.csv"
                file.write_text("time_s,n_rpm\n"+rows)
                with self.assertRaises(ValueError):cli.read_csv(file,["time_s","n_rpm"])

    def test_voltage_and_speed_sign_rejected(self):
        for key in ("V_bus_V","n_rpm"):
            d=self.energy();d[key][1]=-1
            with self.subTest(key=key),self.assertRaises(ValueError):
                cli.energy_analysis(self.core,d,.4,self.energy_meta)

    def test_current_sign_declaration_required(self):
        meta=deepcopy(self.energy_meta);meta["current_sign"]="unknown"
        with self.assertRaises(ValueError):cli.energy_analysis(self.core,self.energy(),.4,meta)

    def test_independently_confirmed_inertia_required(self):
        meta=deepcopy(self.energy_meta);meta["inertia_confirmed_independently"]=False
        with self.assertRaises(ValueError):cli.energy_analysis(self.core,self.energy(),.4,meta)
        for inertia in (0,-1,float("nan")):
            with self.subTest(inertia=inertia),self.assertRaises(ValueError):
                cli.energy_analysis(self.core,self.energy(),inertia,self.energy_meta)

    def test_analytic_coastdown_recovers_known_friction(self):
        _,_,report=cli.coastdown_analysis(self.core,self.coast(),.5,self.coast_meta)
        self.assertAlmostEqual(report["fit"]["b_Nm_s_rad"],.006,places=7)
        self.assertAlmostEqual(report["fit"]["Tc_Nm"],.04,places=6)
        self.assertLess(report["speed_fit_rmse_rpm"],.001)

    def test_inertia_scaling_shows_identifiability_limit(self):
        _,_,a=cli.coastdown_analysis(self.core,self.coast(),.5,self.coast_meta)
        _,_,b=cli.coastdown_analysis(self.core,self.coast(),1.,self.coast_meta)
        for key in ("b_Nm_s_rad","Tc_Nm"):
            self.assertAlmostEqual(b["fit"][key],2*a["fit"][key],places=10)

    def test_missing_isolation_evidence_rejected(self):
        meta=deepcopy(self.coast_meta);meta["coastdown_conditions"]["isolation_evidence"]=""
        with self.assertRaises(ValueError):cli.coastdown_analysis(self.core,self.coast(),.5,meta)

    def test_branch_current_is_not_motor_current_evidence(self):
        d=self.coast();d["I_fess_bus_A"]=d.pop("I_motor_A")
        with self.assertRaises(ValueError):cli.coastdown_analysis(self.core,d,.5,self.coast_meta)

    def test_nonzero_motor_current_rejected(self):
        d=self.coast();d["I_motor_A"][30]=.5
        with self.assertRaises(ValueError):cli.coastdown_analysis(self.core,d,.5,self.coast_meta)

    def test_documented_open_circuit_speed_only_route(self):
        meta=deepcopy(self.coast_meta);c=meta["coastdown_conditions"]
        c.update(zero_torque_evidence_type="documented_open_circuit",open_circuit_no_closed_current_path=True,
            open_circuit_evidence="SYNTHETIC: analytically stipulated no current path")
        d=self.coast();del d["I_motor_A"]
        _,_,report=cli.coastdown_analysis(self.core,d,.5,meta)
        self.assertIn("not measured",report["zero_torque_evidence_interpretation"])
        c["open_circuit_no_closed_current_path"]=False
        with self.assertRaises(ValueError):cli.coastdown_analysis(self.core,d,.5,meta)

    def test_narrow_speed_span_rejected(self):
        d=self.coast();d["n_rpm"]=np.linspace(3000,2990,len(d["time_s"]))
        with self.assertRaises(ValueError):cli.coastdown_analysis(self.core,d,.5,self.coast_meta)

    def test_output_directory_cannot_overwrite_existing(self):
        from argparse import Namespace
        with tempfile.TemporaryDirectory() as tmp:
            target=Path(tmp)/"output";target.mkdir();marker=target/"keep.txt";marker.write_text("original")
            args=Namespace(command="energy",csv=str(ROOT/"examples/SYNTHETIC_energy.csv"),
                metadata=str(ROOT/"examples/SYNTHETIC_energy_metadata.json"),inertia=.4,project_root=None,output=str(target))
            with self.assertRaises(FileExistsError):cli.execute(args)
            self.assertEqual(marker.read_text(),"original")

    def test_cli_energy_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            completed=subprocess.run([sys.executable,str(ROOT/"fyp_lab_cli.py"),"energy",str(ROOT/"examples/SYNTHETIC_energy.csv"),
                "--inertia","0.4","--metadata",str(ROOT/"examples/SYNTHETIC_energy_metadata.json"),"--output",str(Path(tmp)/"out")],capture_output=True,text=True)
            self.assertEqual(completed.returncode,0,completed.stderr)
            report=json.loads((Path(tmp)/"out/summary.json").read_text(encoding="utf-8"))
            self.assertEqual(report["input_type"],"synthetic_test_data")
            self.assertEqual(report["imported_J"],20)
            self.assertEqual(len(report["input_sha256"]),64)

    def test_cli_coastdown_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            completed=subprocess.run([sys.executable,str(ROOT/"fyp_lab_cli.py"),"coastdown",str(ROOT/"examples/SYNTHETIC_coastdown.csv"),
                "--inertia","0.5","--metadata",str(ROOT/"examples/SYNTHETIC_coastdown_metadata.json"),"--output",str(Path(tmp)/"out")],capture_output=True,text=True)
            self.assertEqual(completed.returncode,0,completed.stderr)
            report=json.loads((Path(tmp)/"out/summary.json").read_text(encoding="utf-8"))
            self.assertEqual(report["input_type"],"synthetic_test_data")
            self.assertAlmostEqual(report["fit"]["b_Nm_s_rad"],.006,places=7)

    def test_cli_has_no_default_inertia(self):
        completed=subprocess.run([sys.executable,str(ROOT/"fyp_lab_cli.py"),"energy",str(ROOT/"examples/SYNTHETIC_energy.csv"),
            "--metadata",str(ROOT/"examples/SYNTHETIC_energy_metadata.json"),"--output","unused"],capture_output=True,text=True)
        self.assertNotEqual(completed.returncode,0)
        self.assertIn("--inertia",completed.stderr)

if __name__=="__main__":unittest.main()
