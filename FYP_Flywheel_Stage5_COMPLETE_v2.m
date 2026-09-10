%% FYP - Member 2 - Stage 5 COMPLETE
% Automatic Idle / Charging / Discharging / Protection
% One-click script: builds Simulink model + runs simulation + plots results
%
% Mode coding:
%   0  = Idle
%   1  = Charging
%  -1  = Discharging
%   2  = Protection
%
% Test schedule:
%   0-2 s    Idle
%   2-6 s    Charging
%   6-8 s    Idle
%   8-12 s   Discharging
%   12-14 s  Idle
%   14-16 s  Protection (fault injected)
%   16-18 s  Charging
%
% IMPORTANT:
% The numerical parameters below are temporary simulation parameters.
% They are not yet the final FYP design parameters.

clear; clc; close all;

%% 1. Plant parameters
R  = 0.8;          % Armature resistance [ohm]
L  = 0.02;         % Armature inductance [H]
Ke = 0.05;         % Back-EMF constant [V/(rad/s)]
Kt = 0.05;         % Torque constant [N*m/A]
Jm = 0.01;         % Motor rotor inertia [kg*m^2]

Jf = 0.50;         % Flywheel inertia [kg*m^2]
J_total = Jm + Jf;

B  = 1.0e-3;       % Viscous friction [N*m*s/rad]
Tc = 0.05;         % Coulomb friction torque [N*m]

n0 = 3000;                         % Initial speed [rpm]
omega0 = 2*pi*n0/60;               % [rad/s]

% Temporary protection limits
n_min = 2850;
n_max = 3150;
omega_min = 2*pi*n_min/60;
omega_max = 2*pi*n_max/60;

%% 2. Controller parameters
I_charge = 15;       % Charge current command [A]
I_discharge = 15;    % Discharge current magnitude [A]
Imax = 20;           % Current command hard limit [A]
Vmax = 60;           % Armature voltage hard limit [V]
Kp_current = 1.0;    % Current-loop P gain [V/A]

Tstop = 18;

%% 3. Create a fresh Simulink model
mdl = 'FYP_Flywheel_Stage5_MODEL_v2';

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

%% 4. Demand profile
% Demand meaning:
%   +1 = charge request
%    0 = idle request
%   -1 = discharge request
%
% 0-2  : 0
% 2-6  : +1
% 6-8  : 0
% 8-12 : -1
% 12-14: 0
% 14-18: +1 (but fault overrides during 14-16)

add_block('simulink/Sources/Constant',[mdl '/Demand_Base'],...
    'Position',[30 40 90 70],'Value','0');

add_block('simulink/Sources/Step',[mdl '/Demand_2s_plus1'],...
    'Position',[30 90 90 120],...
    'Time','2','Before','0','After','1');

add_block('simulink/Sources/Step',[mdl '/Demand_6s_minus1'],...
    'Position',[30 140 90 170],...
    'Time','6','Before','0','After','-1');

add_block('simulink/Sources/Step',[mdl '/Demand_8s_minus1'],...
    'Position',[30 190 90 220],...
    'Time','8','Before','0','After','-1');

add_block('simulink/Sources/Step',[mdl '/Demand_12s_plus1'],...
    'Position',[30 240 90 270],...
    'Time','12','Before','0','After','1');

add_block('simulink/Sources/Step',[mdl '/Demand_14s_plus1'],...
    'Position',[30 290 90 320],...
    'Time','14','Before','0','After','1');

add_block('simulink/Math Operations/Sum',[mdl '/Demand'],...
    'Position',[135 105 170 255],...
    'Inputs','++++++');

%% 5. Injected fault pulse: 14-16 s
add_block('simulink/Sources/Step',[mdl '/Fault_ON_14s'],...
    'Position',[30 365 90 395],...
    'Time','14','Before','0','After','1');

add_block('simulink/Sources/Step',[mdl '/Fault_OFF_16s'],...
    'Position',[30 415 90 445],...
    'Time','16','Before','0','After','-1');

add_block('simulink/Math Operations/Sum',[mdl '/Fault_Signal'],...
    'Position',[135 375 170 435],...
    'Inputs','++');

%% 6. Charge / discharge request detection
add_block('simulink/Sources/Constant',[mdl '/Zero_charge'],...
    'Position',[215 95 255 125],'Value','0');

add_block('simulink/Sources/Constant',[mdl '/Zero_discharge'],...
    'Position',[215 165 255 195],'Value','0');

add_block('simulink/Logic and Bit Operations/Relational Operator',...
    [mdl '/Charge_Request'],...
    'Position',[300 90 350 130],...
    'Operator','>');

add_block('simulink/Logic and Bit Operations/Relational Operator',...
    [mdl '/Discharge_Request'],...
    'Position',[300 160 350 200],...
    'Operator','<');

%% 7. Protection detection
add_block('simulink/Sources/Constant',[mdl '/Fault_Threshold'],...
    'Position',[215 375 255 405],'Value','0.5');

add_block('simulink/Logic and Bit Operations/Relational Operator',...
    [mdl '/Fault_Active'],...
    'Position',[300 370 350 410],...
    'Operator','>');

add_block('simulink/Sources/Constant',[mdl '/Omega_Max'],...
    'Position',[420 325 485 355],...
    'Value','omega_max');

add_block('simulink/Logic and Bit Operations/Relational Operator',...
    [mdl '/Overspeed'],...
    'Position',[525 320 575 360],...
    'Operator','>=');

add_block('simulink/Sources/Constant',[mdl '/Omega_Min'],...
    'Position',[420 435 485 465],...
    'Value','omega_min');

add_block('simulink/Logic and Bit Operations/Relational Operator',...
    [mdl '/Underspeed'],...
    'Position',[525 430 575 470],...
    'Operator','<=');

add_block('simulink/Logic and Bit Operations/Logical Operator',...
    [mdl '/Protection_OR'],...
    'Position',[625 350 680 440],...
    'Operator','OR',...
    'Inputs','3');

add_block('simulink/Logic and Bit Operations/Logical Operator',...
    [mdl '/No_Protection'],...
    'Position',[730 375 780 415],...
    'Operator','NOT',...
    'Inputs','1');

%% 8. Allowed modes and current commands
add_block('simulink/Logic and Bit Operations/Logical Operator',...
    [mdl '/Charge_Allowed'],...
    'Position',[835 95 890 145],...
    'Operator','AND',...
    'Inputs','2');

add_block('simulink/Logic and Bit Operations/Logical Operator',...
    [mdl '/Discharge_Allowed'],...
    'Position',[835 175 890 225],...
    'Operator','AND',...
    'Inputs','2');

% IMPORTANT: force logical mode signals to DOUBLE before numerical gains.
% This avoids fixed-point inheritance such as sfix8_En3 in MATLAB/Simulink R2024a.
add_block('simulink/Signal Attributes/Data Type Conversion',...
    [mdl '/Charge_Allowed_Double'],...
    'Position',[905 105 955 135],...
    'OutDataTypeStr','double');

add_block('simulink/Signal Attributes/Data Type Conversion',...
    [mdl '/Discharge_Allowed_Double'],...
    'Position',[905 185 955 215],...
    'OutDataTypeStr','double');

add_block('simulink/Signal Attributes/Data Type Conversion',...
    [mdl '/Protection_Double'],...
    'Position',[750 300 800 330],...
    'OutDataTypeStr','double');

add_block('simulink/Math Operations/Gain',[mdl '/Charge_Current'],...
    'Position',[985 100 1060 140],...
    'Gain','I_charge');

add_block('simulink/Math Operations/Gain',[mdl '/Discharge_Current'],...
    'Position',[985 180 1060 220],...
    'Gain','-I_discharge');

add_block('simulink/Math Operations/Sum',[mdl '/Current_Reference'],...
    'Position',[1110 120 1145 200],...
    'Inputs','++');

add_block('simulink/Discontinuities/Saturation',[mdl '/Current_Reference_Limit'],...
    'Position',[1190 135 1265 185],...
    'UpperLimit','Imax',...
    'LowerLimit','-Imax');

%% 9. Numeric mode signal for plotting
% mode = 2*Protection + ChargeAllowed - DischargeAllowed
add_block('simulink/Math Operations/Gain',[mdl '/Protection_Mode_2'],...
    'Position',[835 300 910 340],...
    'Gain','2');

add_block('simulink/Math Operations/Gain',[mdl '/Charge_Mode_1'],...
    'Position',[985 250 1060 290],...
    'Gain','1');

add_block('simulink/Math Operations/Gain',[mdl '/Discharge_Mode_minus1'],...
    'Position',[985 325 1075 365],...
    'Gain','-1');

add_block('simulink/Math Operations/Sum',[mdl '/Mode'],...
    'Position',[1120 260 1155 360],...
    'Inputs','+++');

%% 10. Current controller + feedforward
add_block('simulink/Math Operations/Sum',[mdl '/Current_Error'],...
    'Position',[1310 125 1345 195],...
    'Inputs','+-');

add_block('simulink/Math Operations/Gain',[mdl '/Current_P'],...
    'Position',[1390 140 1455 180],...
    'Gain','Kp_current');

add_block('simulink/Math Operations/Gain',[mdl '/R_times_iref'],...
    'Position',[1385 230 1455 270],...
    'Gain','R');

add_block('simulink/Math Operations/Gain',[mdl '/BackEMF_FF'],...
    'Position',[1385 285 1460 325],...
    'Gain','Ke');

add_block('simulink/Math Operations/Sum',[mdl '/Voltage_FF'],...
    'Position',[1500 235 1535 315],...
    'Inputs','++');

add_block('simulink/Math Operations/Sum',[mdl '/Voltage_Command'],...
    'Position',[1500 130 1535 195],...
    'Inputs','++');

add_block('simulink/Discontinuities/Saturation',[mdl '/Voltage_Limit'],...
    'Position',[1580 140 1655 190],...
    'UpperLimit','Vmax',...
    'LowerLimit','-Vmax');

%% 11. DC motor electrical model
% L*di/dt = Va - R*i - Ke*omega
add_block('simulink/Math Operations/Sum',[mdl '/Electrical_Sum'],...
    'Position',[1700 125 1735 195],...
    'Inputs','+--');

add_block('simulink/Math Operations/Gain',[mdl '/1_over_L'],...
    'Position',[1780 140 1845 180],...
    'Gain','1/L');

add_block('simulink/Continuous/Integrator',[mdl '/Armature_Current'],...
    'Position',[1890 140 1930 180],...
    'InitialCondition','0');

add_block('simulink/Math Operations/Gain',[mdl '/R_times_i'],...
    'Position',[1775 240 1845 280],...
    'Gain','R');

add_block('simulink/Math Operations/Gain',[mdl '/Back_EMF'],...
    'Position',[1775 295 1845 335],...
    'Gain','Ke');

add_block('simulink/Math Operations/Gain',[mdl '/Torque_Kt_i'],...
    'Position',[1980 140 2055 180],...
    'Gain','Kt');

%% 12. Flywheel mechanical model
% J*domega/dt = Te - B*omega - Tc*sign(omega)
add_block('simulink/Math Operations/Gain',[mdl '/Viscous_Loss'],...
    'Position',[1980 245 2050 285],...
    'Gain','B');

add_block('simulink/Math Operations/Sign',[mdl '/Sign_omega'],...
    'Position',[1925 310 1965 340]);

add_block('simulink/Math Operations/Gain',[mdl '/Coulomb_Loss'],...
    'Position',[2055 305 2125 345],...
    'Gain','Tc');

add_block('simulink/Math Operations/Sum',[mdl '/Total_Loss_Torque'],...
    'Position',[2165 250 2200 335],...
    'Inputs','++');

add_block('simulink/Math Operations/Sum',[mdl '/Mechanical_Sum'],...
    'Position',[2110 125 2145 195],...
    'Inputs','+-');

add_block('simulink/Math Operations/Gain',[mdl '/1_over_Jtotal'],...
    'Position',[2190 140 2270 180],...
    'Gain','1/J_total');

add_block('simulink/Continuous/Integrator',[mdl '/Flywheel_Speed'],...
    'Position',[2315 140 2355 180],...
    'InitialCondition','omega0');

%% 13. Derived outputs
add_block('simulink/Math Operations/Gain',[mdl '/rad_s_to_rpm'],...
    'Position',[2405 70 2490 110],...
    'Gain','60/(2*pi)');

add_block('simulink/Math Operations/Product',[mdl '/omega_squared'],...
    'Position',[2405 145 2445 185],...
    'Inputs','**');

add_block('simulink/Math Operations/Gain',[mdl '/Flywheel_Energy'],...
    'Position',[2490 145 2575 185],...
    'Gain','0.5*Jf');

add_block('simulink/Math Operations/Product',[mdl '/Electrical_Power'],...
    'Position',[2405 220 2445 260],...
    'Inputs','**');

%% 14. Connect demand profile
src = {'Demand_Base','Demand_2s_plus1','Demand_6s_minus1',...
       'Demand_8s_minus1','Demand_12s_plus1','Demand_14s_plus1'};

for k = 1:6
    add_line(mdl,[src{k} '/1'],['Demand/' num2str(k)],'autorouting','on');
end

%% 15. Connect fault profile
add_line(mdl,'Fault_ON_14s/1','Fault_Signal/1','autorouting','on');
add_line(mdl,'Fault_OFF_16s/1','Fault_Signal/2','autorouting','on');

%% 16. Connect request logic
add_line(mdl,'Demand/1','Charge_Request/1','autorouting','on');
add_line(mdl,'Zero_charge/1','Charge_Request/2','autorouting','on');

add_line(mdl,'Demand/1','Discharge_Request/1','autorouting','on');
add_line(mdl,'Zero_discharge/1','Discharge_Request/2','autorouting','on');

add_line(mdl,'Fault_Signal/1','Fault_Active/1','autorouting','on');
add_line(mdl,'Fault_Threshold/1','Fault_Active/2','autorouting','on');

%% 17. Connect protection logic
% speed signals connect later after Flywheel_Speed exists
add_line(mdl,'Flywheel_Speed/1','Overspeed/1','autorouting','on');
add_line(mdl,'Omega_Max/1','Overspeed/2','autorouting','on');

add_line(mdl,'Flywheel_Speed/1','Underspeed/1','autorouting','on');
add_line(mdl,'Omega_Min/1','Underspeed/2','autorouting','on');

add_line(mdl,'Fault_Active/1','Protection_OR/1','autorouting','on');
add_line(mdl,'Overspeed/1','Protection_OR/2','autorouting','on');
add_line(mdl,'Underspeed/1','Protection_OR/3','autorouting','on');

add_line(mdl,'Protection_OR/1','No_Protection/1','autorouting','on');

%% 18. Connect allowed modes
add_line(mdl,'Charge_Request/1','Charge_Allowed/1','autorouting','on');
add_line(mdl,'No_Protection/1','Charge_Allowed/2','autorouting','on');

add_line(mdl,'Discharge_Request/1','Discharge_Allowed/1','autorouting','on');
add_line(mdl,'No_Protection/1','Discharge_Allowed/2','autorouting','on');

add_line(mdl,'Charge_Allowed/1','Charge_Allowed_Double/1','autorouting','on');
add_line(mdl,'Discharge_Allowed/1','Discharge_Allowed_Double/1','autorouting','on');
add_line(mdl,'Charge_Allowed_Double/1','Charge_Current/1','autorouting','on');
add_line(mdl,'Discharge_Allowed_Double/1','Discharge_Current/1','autorouting','on');

add_line(mdl,'Charge_Current/1','Current_Reference/1','autorouting','on');
add_line(mdl,'Discharge_Current/1','Current_Reference/2','autorouting','on');
add_line(mdl,'Current_Reference/1','Current_Reference_Limit/1','autorouting','on');

%% 19. Connect mode signal
add_line(mdl,'Protection_OR/1','Protection_Double/1','autorouting','on');
add_line(mdl,'Protection_Double/1','Protection_Mode_2/1','autorouting','on');
add_line(mdl,'Charge_Allowed_Double/1','Charge_Mode_1/1','autorouting','on');
add_line(mdl,'Discharge_Allowed_Double/1','Discharge_Mode_minus1/1','autorouting','on');

add_line(mdl,'Protection_Mode_2/1','Mode/1','autorouting','on');
add_line(mdl,'Charge_Mode_1/1','Mode/2','autorouting','on');
add_line(mdl,'Discharge_Mode_minus1/1','Mode/3','autorouting','on');

%% 20. Connect current controller
add_line(mdl,'Current_Reference_Limit/1','Current_Error/1','autorouting','on');
add_line(mdl,'Armature_Current/1','Current_Error/2','autorouting','on');

add_line(mdl,'Current_Error/1','Current_P/1','autorouting','on');

add_line(mdl,'Current_Reference_Limit/1','R_times_iref/1','autorouting','on');
add_line(mdl,'R_times_iref/1','Voltage_FF/1','autorouting','on');

add_line(mdl,'Flywheel_Speed/1','BackEMF_FF/1','autorouting','on');
add_line(mdl,'BackEMF_FF/1','Voltage_FF/2','autorouting','on');

add_line(mdl,'Current_P/1','Voltage_Command/1','autorouting','on');
add_line(mdl,'Voltage_FF/1','Voltage_Command/2','autorouting','on');
add_line(mdl,'Voltage_Command/1','Voltage_Limit/1','autorouting','on');

%% 21. Connect electrical plant
add_line(mdl,'Voltage_Limit/1','Electrical_Sum/1','autorouting','on');
add_line(mdl,'Electrical_Sum/1','1_over_L/1','autorouting','on');
add_line(mdl,'1_over_L/1','Armature_Current/1','autorouting','on');

add_line(mdl,'Armature_Current/1','R_times_i/1','autorouting','on');
add_line(mdl,'R_times_i/1','Electrical_Sum/2','autorouting','on');

add_line(mdl,'Flywheel_Speed/1','Back_EMF/1','autorouting','on');
add_line(mdl,'Back_EMF/1','Electrical_Sum/3','autorouting','on');

add_line(mdl,'Armature_Current/1','Torque_Kt_i/1','autorouting','on');

%% 22. Connect mechanical plant
add_line(mdl,'Torque_Kt_i/1','Mechanical_Sum/1','autorouting','on');

add_line(mdl,'Flywheel_Speed/1','Viscous_Loss/1','autorouting','on');
add_line(mdl,'Flywheel_Speed/1','Sign_omega/1','autorouting','on');

add_line(mdl,'Viscous_Loss/1','Total_Loss_Torque/1','autorouting','on');
add_line(mdl,'Sign_omega/1','Coulomb_Loss/1','autorouting','on');
add_line(mdl,'Coulomb_Loss/1','Total_Loss_Torque/2','autorouting','on');

add_line(mdl,'Total_Loss_Torque/1','Mechanical_Sum/2','autorouting','on');
add_line(mdl,'Mechanical_Sum/1','1_over_Jtotal/1','autorouting','on');
add_line(mdl,'1_over_Jtotal/1','Flywheel_Speed/1','autorouting','on');

%% 23. Derived signal connections
add_line(mdl,'Flywheel_Speed/1','rad_s_to_rpm/1','autorouting','on');

add_line(mdl,'Flywheel_Speed/1','omega_squared/1','autorouting','on');
add_line(mdl,'Flywheel_Speed/1','omega_squared/2','autorouting','on');
add_line(mdl,'omega_squared/1','Flywheel_Energy/1','autorouting','on');

add_line(mdl,'Voltage_Limit/1','Electrical_Power/1','autorouting','on');
add_line(mdl,'Armature_Current/1','Electrical_Power/2','autorouting','on');

%% 24. Workspace outputs
outs = {
    'demand_out',  [2570 20 2660 50],   'demand_out';
    'fault_out',   [2570 60 2660 90],   'fault_out';
    'mode_out',    [2570 100 2660 130], 'mode_out';
    'iref_out',    [2570 140 2660 170], 'iref_out';
    'current_out', [2570 180 2660 210], 'current_out';
    'rpm_out',     [2570 220 2660 250], 'rpm_out';
    'energy_out',  [2570 260 2660 290], 'energy_out';
    'power_out',   [2570 300 2660 330], 'power_out'
    };

for k = 1:size(outs,1)
    add_block('simulink/Sinks/To Workspace',[mdl '/' outs{k,1}],...
        'Position',outs{k,2},...
        'VariableName',outs{k,3},...
        'SaveFormat','Timeseries');
end

add_line(mdl,'Demand/1','demand_out/1','autorouting','on');
add_line(mdl,'Fault_Signal/1','fault_out/1','autorouting','on');
add_line(mdl,'Mode/1','mode_out/1','autorouting','on');
add_line(mdl,'Current_Reference_Limit/1','iref_out/1','autorouting','on');
add_line(mdl,'Armature_Current/1','current_out/1','autorouting','on');
add_line(mdl,'rad_s_to_rpm/1','rpm_out/1','autorouting','on');
add_line(mdl,'Flywheel_Energy/1','energy_out/1','autorouting','on');
add_line(mdl,'Electrical_Power/1','power_out/1','autorouting','on');

%% 25. Scope
add_block('simulink/Sinks/Scope',[mdl '/Scope'],...
    'Position',[2700 80 2745 330],...
    'NumInputPorts','7');

add_line(mdl,'Mode/1','Scope/1','autorouting','on');
add_line(mdl,'Current_Reference_Limit/1','Scope/2','autorouting','on');
add_line(mdl,'Armature_Current/1','Scope/3','autorouting','on');
add_line(mdl,'rad_s_to_rpm/1','Scope/4','autorouting','on');
add_line(mdl,'Flywheel_Energy/1','Scope/5','autorouting','on');
add_line(mdl,'Electrical_Power/1','Scope/6','autorouting','on');
add_line(mdl,'Fault_Signal/1','Scope/7','autorouting','on');

%% 26. Model annotations
Simulink.Annotation(mdl,...
    'FYP Member 2 - Stage 5 v2: Automatic Mode Control (Double-safe)');

Simulink.Annotation(mdl,...
    sprintf(['Mode: Idle=0, Charge=1, Discharge=-1, Protection=2\n'...
             'Speed protection: %g to %g rpm\n'...
             'Current command: +%g A charge / -%g A discharge\n'...
             'Injected fault: 14 to 16 s'],...
             n_min,n_max,I_charge,I_discharge));

%% 27. Save model automatically
save_system(mdl);

%% 28. Compile/run simulation automatically
% The logical control signals have been explicitly converted to double,
% so Saturation limits +/-20 A remain valid in R2024a.
set_param(mdl,'SimulationCommand','update');
simOut = sim(mdl,'ReturnWorkspaceOutputs','on');

demand_ts = simOut.get('demand_out');
fault_ts  = simOut.get('fault_out');
mode_ts   = simOut.get('mode_out');
iref_ts   = simOut.get('iref_out');
i_ts      = simOut.get('current_out');
rpm_ts    = simOut.get('rpm_out');
energy_ts = simOut.get('energy_out');
power_ts  = simOut.get('power_out');

%% 29. Plot all results automatically
fig = figure(...
    'Name','Flywheel Stage 5 - Automatic Mode Control',...
    'NumberTitle','off',...
    'Visible','on');

tiledlayout(4,2,'Padding','compact','TileSpacing','compact');

nexttile;
stairs(demand_ts.Time,demand_ts.Data,'LineWidth',1.3);
hold on;
stairs(fault_ts.Time,fault_ts.Data,'LineWidth',1.3);
grid on;
xlabel('Time (s)');
ylabel('Logic Input');
legend('Demand','Fault','Location','best');
title('System Inputs');

nexttile;
stairs(mode_ts.Time,mode_ts.Data,'LineWidth',1.4);
grid on;
ylim([-1.5 2.5]);
yticks([-1 0 1 2]);
yticklabels({'Discharge','Idle','Charge','Protection'});
xlabel('Time (s)');
ylabel('Mode');
title('Automatic Operating Mode');

nexttile;
plot(iref_ts.Time,iref_ts.Data,'--','LineWidth',1.3);
hold on;
plot(i_ts.Time,i_ts.Data,'LineWidth',1.3);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('Current (A)');
legend('i_{ref}','i_a','Location','best');
title('Current Command and Response');

nexttile;
plot(rpm_ts.Time,rpm_ts.Data,'LineWidth',1.3);
hold on;
yline(n_max,'--','n_{max}');
yline(n_min,'--','n_{min}');
grid on;
xlabel('Time (s)');
ylabel('Speed (rpm)');
title('Flywheel Speed');

nexttile;
plot(energy_ts.Time,energy_ts.Data/1000,'LineWidth',1.3);
grid on;
xlabel('Time (s)');
ylabel('Energy (kJ)');
title('Flywheel Stored Energy');

nexttile;
plot(power_ts.Time,power_ts.Data/1000,'LineWidth',1.3);
yline(0,'--');
grid on;
xlabel('Time (s)');
ylabel('Electrical Power (kW)');
title('Electrical Terminal Power');

nexttile;
plot(rpm_ts.Time,...
    0.5*Jf*(rpm_ts.Data*2*pi/60).^2/1000,...
    'LineWidth',1.3);
grid on;
xlabel('Time (s)');
ylabel('Energy (kJ)');
title('Energy-Speed Consistency');

nexttile;
stairs(fault_ts.Time,fault_ts.Data,'LineWidth',1.3);
grid on;
xlabel('Time (s)');
ylabel('Fault');
title('Injected Protection Event');

sgtitle('Stage 5: Idle / Charging / Discharging / Protection');

drawnow;

%% 30. Save result image automatically
try
    exportgraphics(fig,'FYP_Flywheel_Stage5_v2_results.png',...
        'Resolution',200);
catch
    saveas(fig,'FYP_Flywheel_Stage5_v2_results.png');
end

%% 31. Console summary
fprintf('\n========== FYP STAGE 5 COMPLETE ==========\n');
fprintf('Expected mode sequence:\n');
fprintf('Idle -> Charge -> Idle -> Discharge -> Idle -> Protection -> Charge\n\n');

fprintf('Mode coding:\n');
fprintf('  Idle       =  0\n');
fprintf('  Charging   =  1\n');
fprintf('  Discharge  = -1\n');
fprintf('  Protection =  2\n\n');

fprintf('Max speed           = %.2f rpm\n',max(rpm_ts.Data));
fprintf('Min speed           = %.2f rpm\n',min(rpm_ts.Data));
fprintf('Max armature current= %.2f A\n',max(i_ts.Data));
fprintf('Min armature current= %.2f A\n',min(i_ts.Data));
fprintf('Max electrical power= %.3f kW\n',max(power_ts.Data)/1000);
fprintf('Min electrical power= %.3f kW\n',min(power_ts.Data)/1000);

fprintf('\nFiles automatically created:\n');
fprintf('  %s.slx\n',mdl);
fprintf('  FYP_Flywheel_Stage5_v2_results.png\n');
fprintf('==========================================\n');

disp('Stage 5 build, simulation and plotting completed.');
