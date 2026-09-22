"""Render the accepted native data without another model run."""
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

root = Path(__file__).resolve().parent / 'results'
def read(path):
    return np.genfromtxt(path, delimiter=',', names=True, encoding='utf-8-sig', dtype=None)
d = read(root / 'simulink/simulink_trace.csv')
b = read(root / 'matlab/05_combined_bypass.csv')
c = read(root / 'matlab/comparisons.csv')
plt.rcParams.update({'font.size': 10, 'axes.spines.top': False, 'axes.spines.right': False,
                     'svg.fonttype': 'none', 'axes.titleweight': 'bold'})
fig, grid = plt.subplots(3, 2, figsize=(12.8, 9.5), layout='constrained')
blue, orange = '#1265a8', '#cb6c18'
axes = grid.ravel()
t = d['t_s']; task = t < 20
axes[0].plot(t, d['rpm'], color=blue, lw=1.6)
axes[0].axhline(2850, color='#a2aab5', lw=1, ls=':')
axes[0].axvline(20, color='#a2aab5', lw=1, ls=':')
axes[0].set(title='A  Task and speed restoration', ylabel='Speed / rpm', xlim=(0, 90))
axes[1].plot(t, b['Wsource_J']-d['Wsource_J'], color=blue, lw=1.6)
axes[1].axvline(20, color='#a2aab5', lw=1, ls=':')
axes[1].set(title='B  Spinning bypass minus active flywheel', ylabel='Source energy difference / J', xlim=(0, 90))
axes[2].plot(t[task], b['Vdc_V'][task], color=orange, lw=1.2, ls='--', label='Spinning bypass')
axes[2].plot(t[task], d['Vdc_V'][task], color=blue, lw=1.2, label='Active flywheel')
axes[2].set(title='C  Train task: DC bus voltage', ylabel='DC bus / V', xlim=(0, 20))
axes[2].legend(frameon=False, fontsize=9, loc='upper left')
axes[3].plot(t[task], d['cycle_mean_i_A'][task], color=blue, lw=1.7, label='PWM-cycle mean')
axes[3].plot(t[task], d['iref_A'][task], color=orange, lw=1, ls='--', label='Reference')
axes[3].set(title='D  Train task: current tracking', ylabel='Current / A', xlim=(0, 20))
axes[3].legend(frameon=False, fontsize=9, loc='upper left')
axes[4].plot(t, 1e6*d['residual_J'], color=blue, lw=1.6)
axes[4].set(title='E  Complete physical energy balance', ylabel='Balance residual / µJ', xlim=(0, 90))
bars = axes[5].bar(['Nominal', 'Friction +50%', 'Combined', 'Pulse'], c['matched_reduction_percent'], color=blue, width=.58)
axes[5].bar_label(bars, fmt='%.2f%%', padding=5)
axes[5].set(title='F  Matched terminal states, including restoration', ylabel='Source energy reduction / %', ylim=(0, 11))
for ax in axes:
    ax.grid(alpha=.18, axis='y'); ax.set_axisbelow(True)
for ax in axes[:5]:
    ax.set_xlabel('Time / s')
fig.suptitle('Accepted flywheel energy storage results', fontsize=18, weight='bold')
fig.supxlabel('Native MATLAB / Simulink R2024a · provisional DC motor · synthetic train input\nA–E: combined plant mismatch. F: four separate paired cases. These are model results, not real-rail savings.', fontsize=9)
fig.savefig(root / 'accepted_results_overview.png', dpi=160)
fig.savefig(root / 'accepted_results_overview.svg')
plt.close(fig)
print('Rendered accepted results overview.')
