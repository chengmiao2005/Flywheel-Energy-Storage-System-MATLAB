%% FYP - Member 2 - Stage 4 v2
% Stable Cascaded Closed-Loop Control for DC Servo Motor + Flywheel
%
% This version fixes the integrator windup observed in the first Stage 4.
%
% Control structure:
%   Speed reference
%       -> speed error
%       -> proportional speed controller + friction compensation
%       -> current reference limit
%       -> current error
%       -> proportional current controller + voltage feedforward
%       -> armature voltage limit
%       -> DC motor + flywheel
%
% Why no PI here?
%   This is the "baseline stable closed-loop model".
%   It avoids PI integrator windup first and verifies charge/discharge control.
%   PI + anti-windup can be added later as an enhancement/comparison.
%
% Test sequence:
%   0-2 s   : 3000 rpm  (hold)
%   2-8 s   : 3050 rpm  (charging / acceleration)
%   8-14 s  : 2950 rpm  (discharging / regenerative braking)
%   14-18 s : 3000 rpm  (return)
%
% IMPORTANT:
% Numerical values are temporary test parameters, not final FYP values.

clear; clc;

%% 1. Plant parameters
R  = 0.8;          % Armature resistance [ohm]
L  = 0.02;         % Armature inductance [H]
Ke = 0.05;         % Back-EMF constant [V/(rad/s)]
Kt = 0.05;         % Torque constant [N*m/A]
Jm = 0.01;         % Motor rotor inertia [kg*m^2]

Jf = 0.50;         % Flywheel inertia [kg*m^2]
J_total = Jm + Jf;

B  = 1.0e-3;       % Viscous friction [N*m*s/rad]
Tc = 0.05;         % Coulomb friction [N*m]

n0 = 3000;
omega0 = 2*pi*n0/60;

%% 2. Controller parameters
Kp_speed = 2.0;    % [A/(rad/s)] speed-error -> dynamic current
Kp_current = 1.0;  % [V/A] current-error -> correction voltage

Imax = 18;         % [A] current limit
Vmax = 60;         % [V] voltage limit

Tstop = 18;

%% 3. Create model
mdl = 'FYP_Flywheel_Stage4_v2_StableClosedLoop';

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

%% 4. Speed reference profile in rpm
add_block('simulink/Sources/Constant',[mdl '/Base_3000rpm'],...
    'Position',[30 35 95 65],'Value','3000');

add_block('simulink/Sources/Step',[mdl '/Step_2s_plus50'],...
    'Position',[30 85 95 115],...
    'Time','2','Before','0','After','50');

add_block('simulink/Sources/Step',[mdl '/Step_8s_minus100'],...
    'Position',[30 135 95 165],...
    'Time','8','Before','0','After','-100');

add_block('simulink/Sources/Step',[mdl '/Step_14s_plus50'],...
    'Position',[30 185 95 215],...
    'Time','14','Before','0','After','50');

add_block('simulink/Math Operations/Sum',[mdl '/SpeedRef_rpm'],...
    'Position',[135 75 170 180],'Inputs','++++');

add_block('simulink/Math Operations/Gain',[mdl '/rpm_to_rad_s'],...
    'Position',[210 105 295 145],...
    'Gain','2*pi/60');

%% 5. Speed loop
add_block('simulink/Math Operations/Sum',[mdl '/Speed_Error'],...
    'Position',[340 95 375 155],...
    'Inputs','+-');

add_block('simulink/Math Operations/Gain',[mdl '/Speed_P'],...
    'Position',[420 105 485 145],...
    'Gain','Kp_speed');

% Friction torque = B*omega + Tc*sign(omega)
add_block('simulink/Math Operations/Gain',[mdl '/Viscous_Loss'],...
    'Position',[420 245 485 285],...
    'Gain','B');

add_block('simulink/Math Operations/Sign',[mdl '/Sign_omega'],...
    'Position',[415 310 455 340]);

add_block('simulink/Math Operations/Gain',[mdl '/Coulomb_Loss'],...
    'Position',[495 305 565 345],...
    'Gain','Tc');

add_block('simulink/Math Operations/Sum',[mdl '/Total_Loss_Torque'],...
    'Position',[605 255 640 330],...
    'Inputs','++');

% Convert loss torque to compensation current
add_block('simulink/Math Operations/Gain',[mdl '/Loss_Torque_to_Current'],...
    'Position',[675 270 760 310],...
    'Gain','1/Kt');

% dynamic current + loss compensation
add_block('simulink/Math Operations/Sum',[mdl '/CurrentRef_Unlimited'],...
    'Position',[535 95 570 155],...
    'Inputs','++');

add_block('simulink/Discontinuities/Saturation',[mdl '/Current_Reference_Limit'],...
    'Position',[615 100 690 150],...
    'UpperLimit','Imax',...
    'LowerLimit','-Imax');

%% 6. Current loop
add_block('simulink/Math Operations/Sum',[mdl '/Current_Error'],...
    'Position',[745 95 780 155],...
    'Inputs','+-');

add_block('simulink/Math Operations/Gain',[mdl '/Current_P'],...
    'Position',[825 105 890 145],...
    'Gain','Kp_current');

% Feedforward voltage: R*i_ref + Ke*omega
add_block('simulink/Math Operations/Gain',[mdl '/R_times_iref'],...
    'Position',[820 205 890 245],...
    'Gain','R');

add_block('simulink/Math Operations/Gain',[mdl '/BackEMF_Feedforward'],...
    'Position',[820 260 905 300],...
    'Gain','Ke');

add_block('simulink/Math Operations/Sum',[mdl '/Voltage_Feedforward'],...
    'Position',[940 215 975 285],...
    'Inputs','++');

add_block('simulink/Math Operations/Sum',[mdl '/Voltage_Command_Unlimited'],...
    'Position',[940 95 975 155],...
    'Inputs','++');

add_block('simulink/Discontinuities/Saturation',[mdl '/Voltage_Limit'],...
    'Position',[1020 100 1095 150],...
    'UpperLimit','Vmax',...
    'LowerLimit','-Vmax');

%% 7. DC motor electrical dynamics
add_block('simulink/Math Operations/Sum',[mdl '/Electrical_Sum'],...
    'Position',[1140 85 1175 155],...
    'Inputs','+--');

add_block('simulink/Math Operations/Gain',[mdl '/1_over_L'],...
    'Position',[1220 100 1285 140],...
    'Gain','1/L');

add_block('simulink/Continuous/Integrator',[mdl '/Armature_Current'],...
    'Position',[1330 100 1370 140],...
    'InitialCondition','0');

add_block('simulink/Math Operations/Gain',[mdl '/R_times_i'],...
    'Position',[1215 205 1285 245],...
    'Gain','R');

add_block('simulink/Math Operations/Gain',[mdl '/Back_EMF'],...
    'Position',[1215 260 1285 300],...
    'Gain','Ke');

add_block('simulink/Math Operations/Gain',[mdl '/Torque_Kt_i'],...
    'Position',[1420 100 1495 140],...
    'Gain','Kt');

%% 8. Flywheel mechanical dynamics
add_block('simulink/Math Operations/Sum',[mdl '/Mechanical_Sum'],...
    'Position',[1545 85 1580 155],...
    'Inputs','+-');

add_block('simulink/Math Operations/Gain',[mdl '/1_over_Jtotal'],...
    'Position',[1625 100 1705 140],...
    'Gain','1/J_total');

add_block('simulink/Continuous/Integrator',[mdl '/Flywheel_Speed'],...
    'Position',[1750 100 1790 140],...
    'InitialCondition','omega0');

%% 9. Derived outputs
add_block('simulink/Math Operations/Gain',[mdl '/rad_s_to_rpm'],...
    'Position',[1840 40 1925 80],...
    'Gain','60/(2*pi)');

add_block('simulink/Math Operations/Product',[mdl '/omega_squared'],...
    'Position',[1840 110 1880 150],...
    'Inputs','**');

add_block('simulink/Math Operations/Gain',[mdl '/Flywheel_Energy'],...
    'Position',[1925 110 2010 150],...
    'Gain','0.5*Jf');

add_block('simulink/Math Operations/Product',[mdl '/Electrical_Power'],...
    'Position',[1840 190 1880 230],...
    'Inputs','**');

add_block('simulink/Math Operations/Product',[mdl '/Mechanical_Power'],...
    'Position',[1840 260 1880 300],...
    'Inputs','**');

%% 10. Connections: reference
add_line(mdl,'Base_3000rpm/1','SpeedRef_rpm/1','autorouting','on');
add_line(mdl,'Step_2s_plus50/1','SpeedRef_rpm/2','autorouting','on');
add_line(mdl,'Step_8s_minus100/1','SpeedRef_rpm/3','autorouting','on');
add_line(mdl,'Step_14s_plus50/1','SpeedRef_rpm/4','autorouting','on');
add_line(mdl,'SpeedRef_rpm/1','rpm_to_rad_s/1','autorouting','on');

%% 11. Connections: speed loop
add_line(mdl,'rpm_to_rad_s/1','Speed_Error/1','autorouting','on');
add_line(mdl,'Speed_Error/1','Speed_P/1','autorouting','on');
add_line(mdl,'Speed_P/1','CurrentRef_Unlimited/1','autorouting','on');

add_line(mdl,'Loss_Torque_to_Current/1','CurrentRef_Unlimited/2','autorouting','on');
add_line(mdl,'CurrentRef_Unlimited/1','Current_Reference_Limit/1','autorouting','on');

%% 12. Connections: current loop
add_line(mdl,'Current_Reference_Limit/1','Current_Error/1','autorouting','on');
add_line(mdl,'Current_Error/1','Current_P/1','autorouting','on');

add_line(mdl,'Current_Reference_Limit/1','R_times_iref/1','autorouting','on');
add_line(mdl,'R_times_iref/1','Voltage_Feedforward/1','autorouting','on');
add_line(mdl,'BackEMF_Feedforward/1','Voltage_Feedforward/2','autorouting','on');

add_line(mdl,'Current_P/1','Voltage_Command_Unlimited/1','autorouting','on');
add_line(mdl,'Voltage_Feedforward/1','Voltage_Command_Unlimited/2','autorouting','on');
add_line(mdl,'Voltage_Command_Unlimited/1','Voltage_Limit/1','autorouting','on');

%% 13. Connections: electrical plant
add_line(mdl,'Voltage_Limit/1','Electrical_Sum/1','autorouting','on');
add_line(mdl,'Electrical_Sum/1','1_over_L/1','autorouting','on');
add_line(mdl,'1_over_L/1','Armature_Current/1','autorouting','on');

add_line(mdl,'Armature_Current/1','Current_Error/2','autorouting','on');
add_line(mdl,'Armature_Current/1','R_times_i/1','autorouting','on');
add_line(mdl,'R_times_i/1','Electrical_Sum/2','autorouting','on');

add_line(mdl,'Armature_Current/1','Torque_Kt_i/1','autorouting','on');

%% 14. Connections: mechanical plant
add_line(mdl,'Torque_Kt_i/1','Mechanical_Sum/1','autorouting','on');
add_line(mdl,'Total_Loss_Torque/1','Mechanical_Sum/2','autorouting','on');
add_line(mdl,'Mechanical_Sum/1','1_over_Jtotal/1','autorouting','on');
add_line(mdl,'1_over_Jtotal/1','Flywheel_Speed/1','autorouting','on');

% speed feedback
add_line(mdl,'Flywheel_Speed/1','Speed_Error/2','autorouting','on');

% loss model
add_line(mdl,'Flywheel_Speed/1','Viscous_Loss/1','autorouting','on');
add_line(mdl,'Flywheel_Speed/1','Sign_omega/1','autorouting','on');
add_line(mdl,'Viscous_Loss/1','Total_Loss_Torque/1','autorouting','on');
add_line(mdl,'Sign_omega/1','Coulomb_Loss/1','autorouting','on');
add_line(mdl,'Coulomb_Loss/1','Total_Loss_Torque/2','autorouting','on');
add_line(mdl,'Total_Loss_Torque/1','Loss_Torque_to_Current/1','autorouting','on');

% electrical feedback
add_line(mdl,'Flywheel_Speed/1','Back_EMF/1','autorouting','on');
add_line(mdl,'Back_EMF/1','Electrical_Sum/3','autorouting','on');

% feedforward back EMF
add_line(mdl,'Flywheel_Speed/1','BackEMF_Feedforward/1','autorouting','on');

%% 15. Derived signals
add_line(mdl,'Flywheel_Speed/1','rad_s_to_rpm/1','autorouting','on');

add_line(mdl,'Flywheel_Speed/1','omega_squared/1','autorouting','on');
add_line(mdl,'Flywheel_Speed/1','omega_squared/2','autorouting','on');
add_line(mdl,'omega_squared/1','Flywheel_Energy/1','autorouting','on');

add_line(mdl,'Voltage_Limit/1','Electrical_Power/1','autorouting','on');
add_line(mdl,'Armature_Current/1','Electrical_Power/2','autorouting','on');

add_line(mdl,'Torque_Kt_i/1','Mechanical_Power/1','autorouting','on');
add_line(mdl,'Flywheel_Speed/1','Mechanical_Power/2','autorouting','on');

%% 16. Workspace outputs
outs = {
    'speedref_out', [2050 20 2140 50],  'speedref_out';
    'rpm_out',      [2050 60 2140 90],  'rpm_out';
    'iref_out',     [2050 100 2140 130],'iref_out';
    'current_out',  [2050 140 2140 170],'current_out';
    'voltage_out',  [2050 180 2140 210],'voltage_out';
    'energy_out',   [2050 220 2140 250],'energy_out';
    'pelec_out',    [2050 260 2140 290],'pelec_out';
    'pmech_out',    [2050 300 2140 330],'pmech_out'
    };

for k=1:size(outs,1)
    add_block('simulink/Sinks/To Workspace',[mdl '/' outs{k,1}],...
        'Position',outs{k,2},...
        'VariableName',outs{k,3},...
        'SaveFormat','Timeseries');
end

add_line(mdl,'SpeedRef_rpm/1','speedref_out/1','autorouting','on');
add_line(mdl,'rad_s_to_rpm/1','rpm_out/1','autorouting','on');
add_line(mdl,'Current_Reference_Limit/1','iref_out/1','autorouting','on');
add_line(mdl,'Armature_Current/1','current_out/1','autorouting','on');
add_line(mdl,'Voltage_Limit/1','voltage_out/1','autorouting','on');
add_line(mdl,'Flywheel_Energy/1','energy_out/1','autorouting','on');
add_line(mdl,'Electrical_Power/1','pelec_out/1','autorouting','on');
add_line(mdl,'Mechanical_Power/1','pmech_out/1','autorouting','on');

%% 17. Scope
add_block('simulink/Sinks/Scope',[mdl '/Scope'],...
    'Position',[2180 75 2225 300],...
    'NumInputPorts','7');

add_line(mdl,'SpeedRef_rpm/1','Scope/1','autorouting','on');
add_line(mdl,'rad_s_to_rpm/1','Scope/2','autorouting','on');
add_line(mdl,'Current_Reference_Limit/1','Scope/3','autorouting','on');
add_line(mdl,'Armature_Current/1','Scope/4','autorouting','on');
add_line(mdl,'Voltage_Limit/1','Scope/5','autorouting','on');
add_line(mdl,'Flywheel_Energy/1','Scope/6','autorouting','on');
add_line(mdl,'Electrical_Power/1','Scope/7','autorouting','on');

%% 18. Annotations
Simulink.Annotation(mdl,...
    'FYP Member 2 - Stage 4 v2: Stable Cascaded Closed-Loop Control');

Simulink.Annotation(mdl,...
    sprintf(['Speed loop: P + friction feedforward -> current reference\n'...
             'Current loop: P + R*i_ref + Ke*omega feedforward -> voltage\n\n'...
             'Reference: 3000 -> 3050 -> 2950 -> 3000 rpm\n'...
             'Current limit: +/- %g A, Voltage limit: +/- %g V'],Imax,Vmax));

%% 19. Save and run
save_system(mdl);

simOut = sim(mdl,'ReturnWorkspaceOutputs','on');

ref_ts    = simOut.get('speedref_out');
rpm_ts    = simOut.get('rpm_out');
iref_ts   = simOut.get('iref_out');
i_ts      = simOut.get('current_out');
v_ts      = simOut.get('voltage_out');
energy_ts = simOut.get('energy_out');
pelec_ts  = simOut.get('pelec_out');
pmech_ts  = simOut.get('pmech_out');

%% 20. Plot results
figure('Name','Flywheel Stage 4 v2 - Stable Closed Loop Results');

tiledlayout(4,2);

nexttile;
plot(ref_ts.Time,ref_ts.Data,'--','LineWidth',1.2);
hold on;
plot(rpm_ts.Time,rpm_ts.Data,'LineWidth',1.2);
grid on;
xlabel('Time (s)');
ylabel('Speed (rpm)');
legend('Reference','Actual','Location','best');
title('Speed Tracking');

nexttile;
plot(iref_ts.Time,iref_ts.Data,'--','LineWidth',1.2);
hold on;
plot(i_ts.Time,i_ts.Data,'LineWidth',1.2);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('Current (A)');
legend('i_{ref}','i_a','Location','best');
title('Current Tracking');

nexttile;
plot(v_ts.Time,v_ts.Data,'LineWidth',1.2);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('Voltage (V)');
title('Armature Voltage Command');

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
title('Electrical Terminal Power');

nexttile;
plot(pmech_ts.Time,pmech_ts.Data/1000,'LineWidth',1.2);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('P_m (kW)');
title('Electromagnetic Mechanical Power');

nexttile;
plot(ref_ts.Time,ref_ts.Data-rpm_ts.Data,'LineWidth',1.2);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('Error (rpm)');
title('Speed Tracking Error');

nexttile;
plot(rpm_ts.Time,0.5*Jf*(rpm_ts.Data*2*pi/60).^2/1000,'LineWidth',1.2);
grid on;
xlabel('Time (s)');
ylabel('Energy (kJ)');
title('Energy-Speed Consistency Check');

%% 21. Console summary
fprintf('\n===== FYP Stage 4 v2 Check =====\n');
fprintf('Maximum speed          = %.2f rpm\n',max(rpm_ts.Data));
fprintf('Minimum speed          = %.2f rpm\n',min(rpm_ts.Data));
fprintf('Maximum current        = %.2f A\n',max(i_ts.Data));
fprintf('Minimum current        = %.2f A\n',min(i_ts.Data));
fprintf('Minimum electrical P   = %.3f kW\n',min(pelec_ts.Data)/1000);
fprintf('Maximum electrical P   = %.3f kW\n',max(pelec_ts.Data)/1000);
fprintf('Final speed            = %.2f rpm\n',rpm_ts.Data(end));
fprintf('Final reference        = %.2f rpm\n',ref_ts.Data(end));
fprintf('===================================\n');

disp('Model saved as FYP_Flywheel_Stage4_v2_StableClosedLoop.slx');
disp('Expected key result: after 8 s, current should become negative and stored energy should decrease.');
disp('If this works, the next step is automatic Idle / Charging / Discharging / Protection logic.');
