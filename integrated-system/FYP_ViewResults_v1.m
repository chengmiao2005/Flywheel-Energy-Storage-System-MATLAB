function FYP_ViewResults_v1()
% Display the packaged native results without running another simulation.
% Requires MATLAB only. The Simulink model and its validated source are unchanged.
base=fileparts(mfilename('fullpath'));
d=readtable(fullfile(base,'results','simulink','simulink_trace.csv'));
b=readtable(fullfile(base,'results','matlab','05_combined_bypass.csv'));
c=readtable(fullfile(base,'results','matlab','comparisons.csv'));
assert(height(d)==height(b) && max(abs(d.t_s-b.t_s))<1e-9, ...
 'FYP:ResultTimes','The two native result files have different time grids.');
task=d.t_s<20;task_b=b.t_s<20;
fig=figure('Name','Accepted FYP results - no simulation','Color','w','Position',[60 60 1300 900]);
subplot(3,2,1);plot(d.t_s,d.rpm,'LineWidth',1.2);hold on;yline(2850,':');
xline(20,':');xlabel('Time / s');ylabel('Speed / rpm');grid on;
title('Combined plant: task and speed restoration');xlim([0 90]);
subplot(3,2,2);plot(d.t_s,b.Wsource_J-d.Wsource_J,'LineWidth',1.2);
xline(20,':');xlabel('Time / s');ylabel('Source energy difference / J');grid on;
title('Spinning bypass minus active flywheel');xlim([0 90]);
subplot(3,2,3);plot(b.t_s(task_b),b.Vdc_V(task_b),'--',d.t_s(task),d.Vdc_V(task),'LineWidth',1.1);
xlabel('Time / s');ylabel('DC bus / V');grid on;title('Train task: DC bus voltage');xlim([0 20]);
legend({'Spinning bypass','Active flywheel'},'Location','best');
subplot(3,2,4);plot(d.t_s(task),d.iref_A(task),'--',d.t_s(task),d.cycle_mean_i_A(task),'LineWidth',1.1);
xlabel('Time / s');ylabel('Current / A');grid on;title('Train task: current tracking');xlim([0 20]);
legend({'Reference','PWM-cycle mean'},'Location','best');
subplot(3,2,5);plot(d.t_s,1e6*d.residual_J,'LineWidth',1.2);
xlabel('Time / s');ylabel('Energy balance residual / microjoule');grid on;
title('Physical energy balance (explicit microjoule scale)');xlim([0 90]);
subplot(3,2,6);bar(c.matched_reduction_percent);grid on;
set(gca,'XTick',1:height(c),'XTickLabel',{'Nominal','Friction +50%','Combined','Pulse'});
ylabel('Source energy reduction / %');title('Same terminal state, including restoration');
for k=1:height(c)
 text(k,c.matched_reduction_percent(k)+.2,sprintf('%.2f%%',c.matched_reduction_percent(k)), ...
  'HorizontalAlignment','center');
end
ylim([0 max(c.matched_reduction_percent)+1.5]);
sgtitle('Native MATLAB / Simulink results | provisional DC motor and synthetic train input');
exportgraphics(fig,fullfile(base,'results','accepted_results_overview.png'),'Resolution',160);
end
