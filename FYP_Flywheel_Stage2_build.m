%% FYP - Member 2 - Stage 2
% Flywheel model with mechanical loss + speed protection
%
% Builds and runs a Simulink model automatically.
%
% New features compared with Stage 1:
%   1) Viscous friction loss:  T_vis = B*omega
%   2) Coulomb friction loss:  T_c   = Tc*sign(omega)
%   3) Flywheel speed limits:  n_min <= n <= n_max
%
% Core dynamics:
%   J*domega/dt = T_cmd - T_loss
%   T_loss = B*omega + Tc*sign(omega)
%   E = 0.5*J*omega^2
%
% IMPORTANT:
% All numerical values below are temporary test values used to verify
% model logic. They are NOT final FYP design parameters.

clear; clc;

%% 1. Temporary test parameters
J = 0.5;                   % [kg*m^2] flywheel inertia
B = 1.0e-3;                % [N*m*s/rad] viscous friction coefficient
Tc = 0.05;                 % [N*m] Coulomb friction torque

n0 = 3000;                 % [rpm] initial speed
n_min = 2800;              % [rpm] temporary lower protection limit
n_max = 3400;              % [rpm] temporary upper protection limit

omega0 = 2*pi*n0/60;
omega_min = 2*pi*n_min/60;
omega_max = 2*pi*n_max/60;

T_charge = 8;              % [N*m] temporary charging torque
T_discharge = -8;          % [N*m] temporary discharging torque
t_switch = 4;              % [s] change from charge to discharge
Tstop = 12;                % [s]

%% 2. Model name
mdl = 'FYP_Flywheel_Stage2';

if bdIsLoaded(mdl)
    close_system(mdl, 0);
end

if exist([mdl '.slx'], 'file')
    delete([mdl '.slx']);
end

new_system(mdl);
open_system(mdl);

set_param(mdl, ...
    'StopTime', num2str(Tstop), ...
    'SolverType', 'Variable-step', ...
    'Solver', 'ode45');

%% 3. Input torque command
add_block('simulink/Sources/Step', [mdl '/Torque_Command'], ...
    'Position', [45 115 100 145], ...
    'Time', num2str(t_switch), ...
    'Before', num2str(T_charge), ...
    'After', num2str(T_discharge));

%% 4. Mechanical loss model

% Viscous loss B*omega
add_block('simulink/Math Operations/Gain', [mdl '/Viscous_Friction_B'], ...
    'Position', [210 235 285 275], ...
    'Gain', 'B');

% sign(omega)
add_block('simulink/Math Operations/Sign', [mdl '/Sign_omega'], ...
    'Position', [210 305 250 335]);

% Coulomb loss Tc*sign(omega)
add_block('simulink/Math Operations/Gain', [mdl '/Coulomb_Friction_Tc'], ...
    'Position', [290 300 370 340], ...
    'Gain', 'Tc');

% Total loss torque
add_block('simulink/Math Operations/Sum', [mdl '/Total_Loss_Torque'], ...
    'Position', [405 250 440 320], ...
    'Inputs', '++');

% Net torque: T_cmd - T_loss
add_block('simulink/Math Operations/Sum', [mdl '/Net_Torque'], ...
    'Position', [150 105 185 155], ...
    'Inputs', '+-');

%% 5. Flywheel dynamics

add_block('simulink/Math Operations/Gain', [mdl '/1_over_J'], ...
    'Position', [225 105 295 155], ...
    'Gain', '1/J');

% Saturated integrator for speed protection
add_block('simulink/Continuous/Integrator', [mdl '/Flywheel_Dynamics'], ...
    'Position', [350 105 395 155], ...
    'InitialCondition', 'omega0', ...
    'LimitOutput', 'on', ...
    'UpperSaturationLimit', 'omega_max', ...
    'LowerSaturationLimit', 'omega_min');

%% 6. Derived outputs

% rad/s -> rpm
add_block('simulink/Math Operations/Gain', [mdl '/rad_s_to_rpm'], ...
    'Position', [480 35 565 75], ...
    'Gain', '60/(2*pi)');

% omega^2
add_block('simulink/Math Operations/Product', [mdl '/omega_squared'], ...
    'Position', [480 110 520 150], ...
    'Inputs', '**');

% Stored energy
add_block('simulink/Math Operations/Gain', [mdl '/Stored_Energy'], ...
    'Position', [575 105 660 150], ...
    'Gain', '0.5*J');

% Command mechanical power Pcmd = Tcmd*omega
add_block('simulink/Math Operations/Product', [mdl '/Command_Power'], ...
    'Position', [480 185 520 225], ...
    'Inputs', '**');

% Mechanical loss power Ploss = Tloss*omega
add_block('simulink/Math Operations/Product', [mdl '/Loss_Power'], ...
    'Position', [480 300 520 340], ...
    'Inputs', '**');

%% 7. Scope and workspace outputs

add_block('simulink/Sinks/Scope', [mdl '/Scope'], ...
    'Position', [800 65 845 245], ...
    'NumInputPorts', '5');

vars = {
    'omega_out',  [690 20 780 50],   'omega_out';
    'rpm_out',    [690 65 780 95],   'rpm_out';
    'energy_out', [690 110 780 140], 'energy_out';
    'pcmd_out',   [690 180 780 210], 'pcmd_out';
    'ploss_out',  [690 300 780 330], 'ploss_out'
    };

for k = 1:size(vars,1)
    add_block('simulink/Sinks/To Workspace', [mdl '/' vars{k,1}], ...
        'Position', vars{k,2}, ...
        'VariableName', vars{k,3}, ...
        'SaveFormat', 'Timeseries');
end

%% 8. Connect model

% Torque command -> net torque (+)
add_line(mdl, 'Torque_Command/1', 'Net_Torque/1', 'autorouting', 'on');

% Net torque -> acceleration -> saturated integrator
add_line(mdl, 'Net_Torque/1', '1_over_J/1', 'autorouting', 'on');
add_line(mdl, '1_over_J/1', 'Flywheel_Dynamics/1', 'autorouting', 'on');

% omega -> friction model
add_line(mdl, 'Flywheel_Dynamics/1', 'Viscous_Friction_B/1', 'autorouting', 'on');
add_line(mdl, 'Flywheel_Dynamics/1', 'Sign_omega/1', 'autorouting', 'on');
add_line(mdl, 'Viscous_Friction_B/1', 'Total_Loss_Torque/1', 'autorouting', 'on');
add_line(mdl, 'Sign_omega/1', 'Coulomb_Friction_Tc/1', 'autorouting', 'on');
add_line(mdl, 'Coulomb_Friction_Tc/1', 'Total_Loss_Torque/2', 'autorouting', 'on');

% loss torque -> net torque (-)
add_line(mdl, 'Total_Loss_Torque/1', 'Net_Torque/2', 'autorouting', 'on');

% omega -> rpm
add_line(mdl, 'Flywheel_Dynamics/1', 'rad_s_to_rpm/1', 'autorouting', 'on');

% omega -> stored energy
add_line(mdl, 'Flywheel_Dynamics/1', 'omega_squared/1', 'autorouting', 'on');
add_line(mdl, 'Flywheel_Dynamics/1', 'omega_squared/2', 'autorouting', 'on');
add_line(mdl, 'omega_squared/1', 'Stored_Energy/1', 'autorouting', 'on');

% Command power = Tcmd * omega
add_line(mdl, 'Torque_Command/1', 'Command_Power/1', 'autorouting', 'on');
add_line(mdl, 'Flywheel_Dynamics/1', 'Command_Power/2', 'autorouting', 'on');

% Loss power = Tloss * omega
add_line(mdl, 'Total_Loss_Torque/1', 'Loss_Power/1', 'autorouting', 'on');
add_line(mdl, 'Flywheel_Dynamics/1', 'Loss_Power/2', 'autorouting', 'on');

% Workspace output lines
add_line(mdl, 'Flywheel_Dynamics/1', 'omega_out/1', 'autorouting', 'on');
add_line(mdl, 'rad_s_to_rpm/1', 'rpm_out/1', 'autorouting', 'on');
add_line(mdl, 'Stored_Energy/1', 'energy_out/1', 'autorouting', 'on');
add_line(mdl, 'Command_Power/1', 'pcmd_out/1', 'autorouting', 'on');
add_line(mdl, 'Loss_Power/1', 'ploss_out/1', 'autorouting', 'on');

% Scope
add_line(mdl, 'Flywheel_Dynamics/1', 'Scope/1', 'autorouting', 'on');
add_line(mdl, 'rad_s_to_rpm/1', 'Scope/2', 'autorouting', 'on');
add_line(mdl, 'Stored_Energy/1', 'Scope/3', 'autorouting', 'on');
add_line(mdl, 'Command_Power/1', 'Scope/4', 'autorouting', 'on');
add_line(mdl, 'Loss_Power/1', 'Scope/5', 'autorouting', 'on');

%% 9. Annotations

Simulink.Annotation(mdl, ...
    'FYP Member 2 - Stage 2: Mechanical Loss + Speed Protection');

Simulink.Annotation(mdl, ...
    sprintf(['Dynamics:\n' ...
             'J*domega/dt = Tcmd - Tloss\n' ...
             'Tloss = B*omega + Tc*sign(omega)\n' ...
             'E = 0.5*J*omega^2\n\n' ...
             'Protection:\n' ...
             'n_min = %g rpm\n' ...
             'n_max = %g rpm'], n_min, n_max));

%% 10. Save and run

save_system(mdl);

simOut = sim(mdl, 'ReturnWorkspaceOutputs', 'on');

omega_ts  = simOut.get('omega_out');
rpm_ts    = simOut.get('rpm_out');
energy_ts = simOut.get('energy_out');
pcmd_ts   = simOut.get('pcmd_out');
ploss_ts  = simOut.get('ploss_out');

%% 11. Plot results

figure('Name','Flywheel Stage 2 Results');

tiledlayout(3,1);

nexttile;
plot(rpm_ts.Time, rpm_ts.Data, 'LineWidth', 1.2);
grid on;
hold on;
yline(n_max, '--', 'n_{max}');
yline(n_min, '--', 'n_{min}');
xlabel('Time (s)');
ylabel('Speed (rpm)');
title('Flywheel Speed with Protection');

nexttile;
plot(energy_ts.Time, energy_ts.Data/1000, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('Energy (kJ)');
title('Stored Energy');

nexttile;
plot(pcmd_ts.Time, pcmd_ts.Data/1000, 'LineWidth', 1.2);
hold on;
plot(ploss_ts.Time, ploss_ts.Data/1000, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('Power (kW)');
legend('Command Mechanical Power','Mechanical Loss Power','Location','best');
title('Power and Mechanical Loss');

%% 12. Console verification

fprintf('\n===== FYP Stage 2 check =====\n');
fprintf('Initial speed            = %.1f rpm\n', n0);
fprintf('Lower protection limit   = %.1f rpm\n', n_min);
fprintf('Upper protection limit   = %.1f rpm\n', n_max);
fprintf('Viscous coefficient B    = %.4g N*m*s/rad\n', B);
fprintf('Coulomb friction Tc      = %.4g N*m\n', Tc);
fprintf('Maximum simulated speed  = %.2f rpm\n', max(rpm_ts.Data));
fprintf('Minimum simulated speed  = %.2f rpm\n', min(rpm_ts.Data));
fprintf('=============================\n');

disp('Model created and saved as FYP_Flywheel_Stage2.slx');
disp('Expected result: speed rises to n_max, is clamped, then falls to n_min and is clamped.');
