%% FYP - Member 2 - Stage 3
% DC Servo Motor + Flywheel Open-Loop Electromechanical Model
%
% This script automatically creates and runs a Simulink model that couples
% a DC motor electrical model with the flywheel mechanical model.
%
% Electrical equation:
%   L*di/dt = Va - R*i - Ke*omega
%
% Electromagnetic torque:
%   Te = Kt*i
%
% Mechanical equation:
%   J_total*domega/dt = Te - B*omega - Tc*sign(omega)
%
% Flywheel stored energy:
%   E_f = 0.5*J_f*omega^2
%
% Test voltage profile:
%   0-5 s  : 48 V   -> motoring / flywheel charging
%   5-10 s : 12 V   -> back-EMF may exceed Va, current reverses,
%                       giving generator/braking behavior
%
% IMPORTANT:
% The numerical motor and flywheel values below are temporary test values.
% They are used only to verify the model structure and control direction.
% Later we will replace them with literature/hardware-based parameters.

clear; clc;

%% 1. Temporary test parameters

% DC motor
R  = 0.8;          % Armature resistance [ohm]
L  = 0.02;         % Armature inductance [H]
Ke = 0.05;         % Back-EMF constant [V/(rad/s)]
Kt = 0.05;         % Torque constant [N*m/A]
Jm = 0.01;         % Motor rotor inertia [kg*m^2]

% Flywheel
Jf = 0.50;         % Flywheel inertia [kg*m^2]
J_total = Jm + Jf; % Total rotating inertia [kg*m^2]

% Mechanical losses
B  = 1.0e-3;       % Viscous friction [N*m*s/rad]
Tc = 0.05;         % Coulomb friction [N*m]

% Initial speed
n0 = 3000;                 % [rpm]
omega0 = 2*pi*n0/60;       % [rad/s]

% Voltage test
V_high = 48;       % 0-5 s
V_low  = 12;       % 5-10 s
t_switch = 5;
Tstop = 10;

%% 2. Model name
mdl = 'FYP_Flywheel_Stage3_DCServo';

if bdIsLoaded(mdl)
    close_system(mdl,0);
end

if exist([mdl '.slx'],'file')
    delete([mdl '.slx']);
end

new_system(mdl);
open_system(mdl);

set_param(mdl,...
    'StopTime',num2str(Tstop),...
    'SolverType','Variable-step',...
    'Solver','ode45');

%% 3. Voltage command
% Step block goes from 48 V to 12 V at t = 5 s
add_block('simulink/Sources/Step',[mdl '/Armature_Voltage'],...
    'Position',[40 90 95 120],...
    'Time',num2str(t_switch),...
    'Before',num2str(V_high),...
    'After',num2str(V_low));

%% 4. Electrical dynamics
% Va - R*i - Ke*omega
add_block('simulink/Math Operations/Sum',[mdl '/Electrical_Sum'],...
    'Position',[160 75 195 135],...
    'Inputs','+--');

add_block('simulink/Math Operations/Gain',[mdl '/1_over_L'],...
    'Position',[235 85 300 125],...
    'Gain','1/L');

add_block('simulink/Continuous/Integrator',[mdl '/Armature_Current'],...
    'Position',[345 85 385 125],...
    'InitialCondition','0');

% R*i feedback
add_block('simulink/Math Operations/Gain',[mdl '/R_times_i'],...
    'Position',[220 190 290 230],...
    'Gain','R');

% Ke*omega feedback
add_block('simulink/Math Operations/Gain',[mdl '/Back_EMF'],...
    'Position',[220 250 290 290],...
    'Gain','Ke');

% Electromagnetic torque Kt*i
add_block('simulink/Math Operations/Gain',[mdl '/Torque_Kt_i'],...
    'Position',[445 85 520 125],...
    'Gain','Kt');

%% 5. Mechanical dynamics
% Loss torques: B*omega and Tc*sign(omega)
add_block('simulink/Math Operations/Gain',[mdl '/Viscous_Loss'],...
    'Position',[460 230 530 270],...
    'Gain','B');

add_block('simulink/Math Operations/Sign',[mdl '/Sign_omega'],...
    'Position',[450 300 490 330]);

add_block('simulink/Math Operations/Gain',[mdl '/Coulomb_Loss'],...
    'Position',[530 295 600 335],...
    'Gain','Tc');

% Te - B*omega - Tc*sign(omega)
add_block('simulink/Math Operations/Sum',[mdl '/Mechanical_Sum'],...
    'Position',[575 75 610 145],...
    'Inputs','+--');

add_block('simulink/Math Operations/Gain',[mdl '/1_over_Jtotal'],...
    'Position',[655 85 735 125],...
    'Gain','1/J_total');

add_block('simulink/Continuous/Integrator',[mdl '/Flywheel_Speed'],...
    'Position',[780 85 820 125],...
    'InitialCondition','omega0');

%% 6. Derived quantities

% omega -> rpm
add_block('simulink/Math Operations/Gain',[mdl '/rad_s_to_rpm'],...
    'Position',[875 35 960 75],...
    'Gain','60/(2*pi)');

% omega^2
add_block('simulink/Math Operations/Product',[mdl '/omega_squared'],...
    'Position',[875 105 915 145],...
    'Inputs','**');

% flywheel energy only: 0.5*Jf*omega^2
add_block('simulink/Math Operations/Gain',[mdl '/Flywheel_Energy'],...
    'Position',[960 105 1045 145],...
    'Gain','0.5*Jf');

% Electrical power = Va*i
add_block('simulink/Math Operations/Product',[mdl '/Electrical_Power'],...
    'Position',[875 180 915 220],...
    'Inputs','**');

% Mechanical power = Te*omega
add_block('simulink/Math Operations/Product',[mdl '/Mechanical_Power'],...
    'Position',[875 250 915 290],...
    'Inputs','**');

%% 7. Workspace outputs
out_defs = {
    'voltage_out', [1090 10 1180 40],   'voltage_out';
    'current_out', [1090 50 1180 80],   'current_out';
    'rpm_out',     [1090 90 1180 120],  'rpm_out';
    'energy_out',  [1090 130 1180 160], 'energy_out';
    'pelec_out',   [1090 180 1180 210], 'pelec_out';
    'pmech_out',   [1090 250 1180 280], 'pmech_out'
    };

for k=1:size(out_defs,1)
    add_block('simulink/Sinks/To Workspace',[mdl '/' out_defs{k,1}],...
        'Position',out_defs{k,2},...
        'VariableName',out_defs{k,3},...
        'SaveFormat','Timeseries');
end

% Scope
add_block('simulink/Sinks/Scope',[mdl '/Scope'],...
    'Position',[1220 60 1265 260],...
    'NumInputPorts','5');

%% 8. Connect electrical loop
add_line(mdl,'Armature_Voltage/1','Electrical_Sum/1','autorouting','on');
add_line(mdl,'Electrical_Sum/1','1_over_L/1','autorouting','on');
add_line(mdl,'1_over_L/1','Armature_Current/1','autorouting','on');

% current feedback
add_line(mdl,'Armature_Current/1','R_times_i/1','autorouting','on');
add_line(mdl,'R_times_i/1','Electrical_Sum/2','autorouting','on');

% current -> torque
add_line(mdl,'Armature_Current/1','Torque_Kt_i/1','autorouting','on');

%% 9. Connect mechanical loop
add_line(mdl,'Torque_Kt_i/1','Mechanical_Sum/1','autorouting','on');
add_line(mdl,'Mechanical_Sum/1','1_over_Jtotal/1','autorouting','on');
add_line(mdl,'1_over_Jtotal/1','Flywheel_Speed/1','autorouting','on');

% omega -> back emf
add_line(mdl,'Flywheel_Speed/1','Back_EMF/1','autorouting','on');
add_line(mdl,'Back_EMF/1','Electrical_Sum/3','autorouting','on');

% omega -> viscous loss
add_line(mdl,'Flywheel_Speed/1','Viscous_Loss/1','autorouting','on');
add_line(mdl,'Viscous_Loss/1','Mechanical_Sum/2','autorouting','on');

% omega -> coulomb loss
add_line(mdl,'Flywheel_Speed/1','Sign_omega/1','autorouting','on');
add_line(mdl,'Sign_omega/1','Coulomb_Loss/1','autorouting','on');
add_line(mdl,'Coulomb_Loss/1','Mechanical_Sum/3','autorouting','on');

%% 10. Derived signals

% rpm
add_line(mdl,'Flywheel_Speed/1','rad_s_to_rpm/1','autorouting','on');

% energy
add_line(mdl,'Flywheel_Speed/1','omega_squared/1','autorouting','on');
add_line(mdl,'Flywheel_Speed/1','omega_squared/2','autorouting','on');
add_line(mdl,'omega_squared/1','Flywheel_Energy/1','autorouting','on');

% electrical power = V*i
add_line(mdl,'Armature_Voltage/1','Electrical_Power/1','autorouting','on');
add_line(mdl,'Armature_Current/1','Electrical_Power/2','autorouting','on');

% mechanical power = Te*omega
add_line(mdl,'Torque_Kt_i/1','Mechanical_Power/1','autorouting','on');
add_line(mdl,'Flywheel_Speed/1','Mechanical_Power/2','autorouting','on');

%% 11. Output lines
add_line(mdl,'Armature_Voltage/1','voltage_out/1','autorouting','on');
add_line(mdl,'Armature_Current/1','current_out/1','autorouting','on');
add_line(mdl,'rad_s_to_rpm/1','rpm_out/1','autorouting','on');
add_line(mdl,'Flywheel_Energy/1','energy_out/1','autorouting','on');
add_line(mdl,'Electrical_Power/1','pelec_out/1','autorouting','on');
add_line(mdl,'Mechanical_Power/1','pmech_out/1','autorouting','on');

% Scope: voltage, current, rpm, electrical power, energy
add_line(mdl,'Armature_Voltage/1','Scope/1','autorouting','on');
add_line(mdl,'Armature_Current/1','Scope/2','autorouting','on');
add_line(mdl,'rad_s_to_rpm/1','Scope/3','autorouting','on');
add_line(mdl,'Electrical_Power/1','Scope/4','autorouting','on');
add_line(mdl,'Flywheel_Energy/1','Scope/5','autorouting','on');

%% 12. Annotations
Simulink.Annotation(mdl,...
    'FYP Member 2 - Stage 3: DC Servo Motor + Flywheel');

Simulink.Annotation(mdl,...
    sprintf(['Electrical: L*di/dt = Va - R*i - Ke*omega\n' ...
             'Torque: Te = Kt*i\n' ...
             'Mechanical: J*domega/dt = Te - B*omega - Tc*sign(omega)\n' ...
             'Flywheel energy: E = 0.5*Jf*omega^2\n\n' ...
             'Test: 0-5 s = %g V, 5-10 s = %g V'],V_high,V_low));

%% 13. Save and simulate
save_system(mdl);

simOut = sim(mdl,'ReturnWorkspaceOutputs','on');

v_ts      = simOut.get('voltage_out');
i_ts      = simOut.get('current_out');
rpm_ts    = simOut.get('rpm_out');
energy_ts = simOut.get('energy_out');
pelec_ts  = simOut.get('pelec_out');
pmech_ts  = simOut.get('pmech_out');

%% 14. Plot results
figure('Name','Flywheel Stage 3 - DC Servo Results');

tiledlayout(3,2);

nexttile;
plot(v_ts.Time,v_ts.Data,'LineWidth',1.2);
grid on;
xlabel('Time (s)');
ylabel('V_a (V)');
title('Armature Voltage');

nexttile;
plot(i_ts.Time,i_ts.Data,'LineWidth',1.2);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('Current (A)');
title('Armature Current');

nexttile;
plot(rpm_ts.Time,rpm_ts.Data,'LineWidth',1.2);
grid on;
xlabel('Time (s)');
ylabel('Speed (rpm)');
title('Flywheel Speed');

nexttile;
plot(energy_ts.Time,energy_ts.Data/1000,'LineWidth',1.2);
grid on;
xlabel('Time (s)');
ylabel('Energy (kJ)');
title('Flywheel Stored Energy');

nexttile;
plot(pelec_ts.Time,pelec_ts.Data/1000,'LineWidth',1.2);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('P_e (kW)');
title('Electrical Power');

nexttile;
plot(pmech_ts.Time,pmech_ts.Data/1000,'LineWidth',1.2);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('P_m (kW)');
title('Mechanical Power');

%% 15. Console summary
fprintf('\n===== FYP Stage 3 check =====\n');
fprintf('Initial speed               = %.1f rpm\n', n0);
fprintf('Initial back-EMF            = %.2f V\n', Ke*omega0);
fprintf('Voltage, 0-5 s              = %.1f V\n', V_high);
fprintf('Voltage, 5-10 s             = %.1f V\n', V_low);
fprintf('Maximum speed               = %.2f rpm\n', max(rpm_ts.Data));
fprintf('Minimum speed               = %.2f rpm\n', min(rpm_ts.Data));
fprintf('Maximum armature current    = %.2f A\n', max(i_ts.Data));
fprintf('Minimum armature current    = %.2f A\n', min(i_ts.Data));
fprintf('Final flywheel energy       = %.3f kJ\n', energy_ts.Data(end)/1000);
fprintf('================================\n');

disp('Model saved as FYP_Flywheel_Stage3_DCServo.slx');
disp('Interpretation: positive current -> motoring/charging; negative current -> generator/braking tendency.');
disp('Next stage after verification: add closed-loop current/speed control and automatic charge/discharge mode switching.');
