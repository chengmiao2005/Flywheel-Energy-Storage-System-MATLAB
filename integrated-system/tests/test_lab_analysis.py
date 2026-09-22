"""Analytical synthetic fixtures only. These are not experimental results."""
import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import numpy as np
from lab_analysis import split_energy,analyze,identify_coastdown

class LabAnalysisTests(unittest.TestCase):
    def test_crossing_triangles(self):
        win,wout=split_energy([0,1,2],[2,-2,2]);self.assertAlmostEqual(win[-1],1);self.assertAlmostEqual(wout[-1],1)
    def test_irregular_intervals(self):
        win,wout=split_energy([0,1,3],[2,2,2]);self.assertAlmostEqual(win[-1],6);self.assertEqual(wout[-1],0)
    def test_negative_direction(self):
        win,wout=split_energy([0,1,2],[-4,0,0]);self.assertEqual(win[-1],0);self.assertAlmostEqual(wout[-1],2)
    def test_duplicate_time_rejected(self):
        with self.assertRaises(ValueError):split_energy([0,0,1],[1,2,3])
    def test_nan_rejected(self):
        with self.assertRaises(ValueError):split_energy([0,1,2],[1,float('nan'),3])
    def metadata(self):
        return dict(complete_cycle=True,boundary_complete=True,calibration_confirmed=True,
                    other_stored_energy_change_J=0,terminal_energy_tolerance_J=.1,endpoint_current_tolerance_A=.01,input_type='synthetic unit fixture')
    def test_efficiency_gate_and_energy(self):
        t=np.arange(5);v=np.ones(5)*10;i=[0,2,0,-1,0];n=np.ones(5)*1000
        _,s=analyze(t,v,i,n,.1,{});self.assertIsNone(s['round_trip_efficiency'])
        _,s=analyze(t,v,i,n,.1,self.metadata());self.assertAlmostEqual(s['round_trip_efficiency'],.5)
    def test_unmatched_state_withholds_efficiency(self):
        _,s=analyze(np.arange(5),np.ones(5)*10,[0,2,0,-1,0],[1000,1100,1200,1100,1050],.1,self.metadata())
        self.assertIsNone(s['round_trip_efficiency']);self.assertIn('terminal stored energy is not matched',s['withheld_reasons'])
    def test_coastdown_analytical_recovery(self):
        t=np.linspace(0,100,2001);J=.5;b=.006;Tc=.04
        w=(300+Tc/b)*np.exp(-b*t/J)-Tc/b
        c=dict(no_external_torque=True,motor_electrically_isolated=True,motor_current_tolerance_A=.001)
        r=identify_coastdown(t,w*60/(2*np.pi),J,np.zeros(len(t)),c)
        self.assertAlmostEqual(r['b_Nm_s_rad'],b,places=7);self.assertAlmostEqual(r['Tc_Nm'],Tc,places=6)
    def test_coastdown_requires_current_evidence(self):
        with self.assertRaises(ValueError):identify_coastdown([0,1,2],[1000,900,800],.5,[0,0,0],{})

if __name__=='__main__':unittest.main()
