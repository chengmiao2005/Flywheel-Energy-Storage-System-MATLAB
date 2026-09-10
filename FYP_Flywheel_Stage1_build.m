%% FYP - Member 2 - Stage 1
% Flywheel Energy Storage Mathematical Model
% This script automatically builds and runs a Simulink model:
% Torque input -> flywheel angular speed -> rpm / stored energy / mechanical power
%
% Default test:
%   0-5 s:  +5 N*m  (charging / acceleration)
%   5-10 s: -5 N*m  (discharging / deceleration)
%
% NOTE:
% J, n0 and torque values below are temporary debugging parameters only.
% Replace them later with literature- or hardware-based project parameters.

clear; clc;

%% 1. Temporary model parameters
J = 0.5;                   % Flywheel inertia [kg*m^2], temporary
n0 = 3000;                 % Initial speed [rpm], temporary
omega0 = 2*pi*n0/60;       % Initial angular speed [rad/s]
T_charge = 5;              % Charging torque [N*m], temporary
T_discharge = -5;          % Discharging torque [N*m], temporary
t_switch = 5;              % Switch from charge to discharge [s]
Tstop = 10;                % Simulation stop time [s]

%% 2. Model name
mdl = 'FYP_Flywheel_Stage1';

% Close an already opened copy
if bdIsLoaded(mdl)
    close_system(mdl, 0);
end

% Remove old model file to avoid accidental overwrite conflicts
if exist([mdl '.slx'], 'file')
    delete([mdl '.slx']);
end

%% 3. Create new Simulink model
new_system(mdl);
open_system(mdl);

set_param(mdl, ...
    'StopTime', num2str(Tstop), ...
    'SolverType', 'Variable-step', ...
    'Solver', 'ode45');

%% 4. Add blocks

% Torque profile: +5 N*m first, then -5 N*m
add_block('simulink/Sources/Step', [mdl '/Torque_Profile'], ...
    'Position', [50 115 100 145], ...
    'Time', num2str(t_switch), ...
    'Before', num2str(T_charge), ...
    'After', num2str(T_discharge));

% 1/J
add_block('simulink/Math Operations/Gain', [mdl '/1_over_J'], ...
    'Position', [150 110 220 150], ...
    'Gain', '1/J');

% Integrator: d(omega)/dt -> omega
add_block('simulink/Continuous/Integrator', [mdl '/Flywheel_Dynamics'], ...
    'Position', [275 110 315 150], ...
    'InitialCondition', 'omega0');

% rad/s -> rpm
add_block('simulink/Math Operations/Gain', [mdl '/rad_s_to_rpm'], ...
    'Position', [390 30 475 70], ...
    'Gain', '60/(2*pi)');

% omega^2
add_block('simulink/Math Operations/Product', [mdl '/omega_squared'], ...
    'Position', [390 105 430 145], ...
    'Inputs', '**');

% 0.5*J*omega^2
add_block('simulink/Math Operations/Gain', [mdl '/Stored_Energy'], ...
    'Position', [490 105 575 145], ...
    'Gain', '0.5*J');

% P = T*omega
add_block('simulink/Math Operations/Product', [mdl '/Mechanical_Power'], ...
    'Position', [390 190 430 230], ...
    'Inputs', '**');

% Scope
add_block('simulink/Sinks/Scope', [mdl '/Scope'], ...
    'Position', [690 75 735 205], ...
    'NumInputPorts', '4');

% To Workspace blocks
add_block('simulink/Sinks/To Workspace', [mdl '/omega_out'], ...
    'Position', [590 10 675 40], ...
    'VariableName', 'omega_out', ...
    'SaveFormat', 'Timeseries');

add_block('simulink/Sinks/To Workspace', [mdl '/rpm_out'], ...
    'Position', [590 50 675 80], ...
    'VariableName', 'rpm_out', ...
    'SaveFormat', 'Timeseries');

add_block('simulink/Sinks/To Workspace', [mdl '/energy_out'], ...
    'Position', [590 105 675 135], ...
    'VariableName', 'energy_out', ...
    'SaveFormat', 'Timeseries');

add_block('simulink/Sinks/To Workspace', [mdl '/power_out'], ...
    'Position', [590 190 675 220], ...
    'VariableName', 'power_out', ...
    'SaveFormat', 'Timeseries');

%% 5. Connect blocks

% Main dynamics
add_line(mdl, 'Torque_Profile/1', '1_over_J/1', 'autorouting', 'on');
add_line(mdl, '1_over_J/1', 'Flywheel_Dynamics/1', 'autorouting', 'on');

% omega -> rpm
add_line(mdl, 'Flywheel_Dynamics/1', 'rad_s_to_rpm/1', 'autorouting', 'on');

% omega -> omega^2 (connect to both Product inputs)
add_line(mdl, 'Flywheel_Dynamics/1', 'omega_squared/1', 'autorouting', 'on');
add_line(mdl, 'Flywheel_Dynamics/1', 'omega_squared/2', 'autorouting', 'on');
add_line(mdl, 'omega_squared/1', 'Stored_Energy/1', 'autorouting', 'on');

% P = T * omega
add_line(mdl, 'Torque_Profile/1', 'Mechanical_Power/1', 'autorouting', 'on');
add_line(mdl, 'Flywheel_Dynamics/1', 'Mechanical_Power/2', 'autorouting', 'on');

% Workspace outputs
add_line(mdl, 'Flywheel_Dynamics/1', 'omega_out/1', 'autorouting', 'on');
add_line(mdl, 'rad_s_to_rpm/1', 'rpm_out/1', 'autorouting', 'on');
add_line(mdl, 'Stored_Energy/1', 'energy_out/1', 'autorouting', 'on');
add_line(mdl, 'Mechanical_Power/1', 'power_out/1', 'autorouting', 'on');

% Scope inputs:
% 1 angular speed, 2 rpm, 3 stored energy, 4 mechanical power
add_line(mdl, 'Flywheel_Dynamics/1', 'Scope/1', 'autorouting', 'on');
add_line(mdl, 'rad_s_to_rpm/1', 'Scope/2', 'autorouting', 'on');
add_line(mdl, 'Stored_Energy/1', 'Scope/3', 'autorouting', 'on');
add_line(mdl, 'Mechanical_Power/1', 'Scope/4', 'autorouting', 'on');

%% 6. Add model annotations
Simulink.Annotation(mdl, ...
    'FYP Member 2 - Stage 1: Flywheel Mathematical Model');

Simulink.Annotation(mdl, ...
    sprintf(['Core equations:\n' ...
             'J*domega/dt = Te\n' ...
             'E = 0.5*J*omega^2\n' ...
             'P = Te*omega\n' ...
             'n = omega*60/(2*pi)']));

%% 7. Save model
save_system(mdl);

%% 8. Run simulation
simOut = sim(mdl, 'ReturnWorkspaceOutputs', 'on');

omega_ts  = simOut.get('omega_out');
rpm_ts    = simOut.get('rpm_out');
energy_ts = simOut.get('energy_out');
power_ts  = simOut.get('power_out');

%% 9. Plot results
figure('Name','Flywheel Stage 1 Results');

tiledlayout(2,2);

nexttile;
plot(omega_ts.Time, omega_ts.Data, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('\omega (rad/s)');
title('Flywheel Angular Speed');

nexttile;
plot(rpm_ts.Time, rpm_ts.Data, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('Speed (rpm)');
title('Flywheel Speed');

nexttile;
plot(energy_ts.Time, energy_ts.Data/1000, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('Energy (kJ)');
title('Stored Energy');

nexttile;
plot(power_ts.Time, power_ts.Data/1000, 'LineWidth', 1.2);
grid on;
xlabel('Time (s)');
ylabel('Power (kW)');
title('Mechanical Power');

%% 10. Print simple verification values
omega_peak_theory = omega0 + (T_charge/J)*t_switch;
rpm_peak_theory = omega_peak_theory*60/(2*pi);
E0_theory = 0.5*J*omega0^2;
Epeak_theory = 0.5*J*omega_peak_theory^2;

fprintf('\n===== Stage 1 theoretical check =====\n');
fprintf('Initial speed      = %.2f rpm\n', n0);
fprintf('Peak speed at 5 s  = %.2f rpm\n', rpm_peak_theory);
fprintf('Initial energy      = %.3f kJ\n', E0_theory/1000);
fprintf('Peak energy at 5 s  = %.3f kJ\n', Epeak_theory/1000);
fprintf('Energy increase     = %.3f kJ\n', (Epeak_theory-E0_theory)/1000);
fprintf('====================================\n');

disp('Model created and saved as FYP_Flywheel_Stage1.slx');
disp('Next step: add mechanical loss and speed limits after Stage 1 is verified.');
