function FYP_DCThreshold_v1(inputFolder)
% DEVELOPMENT-ONLY equal-budget voltage-threshold family comparison.
% Requires the FULL frozen Schedule output folder, including its exact MAT
% inputs and nominal plan. The small ScheduleReview ZIP is insufficient.
% 9 threshold pairs x 2 policies x 7 cases x 2 SOCs x 2 steps = 504 jobs.
% No new train cases, loss model, fitted predictor, or independent test bank.
% All seven simulation kernels and the pure plan lookup are inherited.
if nargin<1 || isempty(inputFolder)
 D=dir('FYP_DCSchedule_v1_Output_*');D=D([D.isdir]);
 assert(~isempty(D),'Place this file next to the FULL Schedule output folder, or pass its path.');
 [~,ix]=sort({D.name});D=D(ix);inputFolder=fullfile(D(end).folder,D(end).name);
end
required={'ScheduleSettings.mat','ScheduleOriginalMetrics.csv','ScheduleSummary.csv', ...
 'ScheduleBaselineChecks.csv','NominalScheduleChecks.csv','PlanInputChecks.csv', ...
 'TrainChecks.csv','StationChecks.csv','NodeChecks.csv','PolicyChecks.csv', ...
 'ScheduleStepChecks.csv','SchedulePairedStepChecks.csv','SourceSnapshot.m','NominalPlan.mat'};
for k=1:numel(required)
 assert(isfile(fullfile(inputFolder,required{k})),'Missing %s. Use the FULL Schedule output folder.',required{k});
end
for id=0:6
 assert(isfile(fullfile(inputFolder,sprintf('Case%02d_Input.mat',id))), ...
  'Missing Case%02d_Input.mat. Use the full original folder, not the review ZIP.',id);
end
A=load(fullfile(inputFolder,'ScheduleSettings.mat'),'config');previous=A.config;
e=previous.Electrical;f=previous.Storage;tail=previous.Tail;Cases=previous.Cases;
NO=readtable(fullfile(inputFolder,'ScheduleOriginalMetrics.csv'));
NS=readtable(fullfile(inputFolder,'ScheduleSummary.csv'));
thresholdConfiguration(previous,e,f,tail,Cases,NO,NS);
dts=[.00125 .000625];socs=[.55 .85];horizons=[5 10 15 20];
names={'VoltageReactive','SchedulePreview'};chargeGrid=[780 800 820];dischargeGrid=[690 710 730];
tieTolerance=1e-8;
[u,d]=ndgrid(chargeGrid,dischargeGrid);
Candidates=sortrows(table(u(:),d(:),'VariableNames',{'ChargeThreshold_V','DischargeThreshold_V'}), ...
 {'ChargeThreshold_V','DischargeThreshold_V'});
Candidates.CandidateID=(1:height(Candidates))';
Candidates.DefaultL1Distance_V=abs(Candidates.ChargeThreshold_V-800)+abs(Candidates.DischargeThreshold_V-710);
Candidates.MinChargeOverHardSOC_V=Candidates.ChargeThreshold_V-abs(e.SOCShift_V)/2;
Candidates.MaxDischargeOverHardSOC_V=Candidates.DischargeThreshold_V+abs(e.SOCShift_V)/2;
Candidates.MaxChargeOverHardSOC_V=Candidates.ChargeThreshold_V+abs(e.SOCShift_V)/2;
Candidates.ThresholdGap_V=Candidates.ChargeThreshold_V-Candidates.DischargeThreshold_V;
Candidates.StructuralDomainPass=Candidates.MinChargeOverHardSOC_V>e.Vsource ...
 &Candidates.MaxDischargeOverHardSOC_V<e.Vsource&Candidates.MaxChargeOverHardSOC_V<e.ChopperOn_V ...
 &Candidates.ThresholdGap_V>0;
assert(height(Candidates)==9&&all(Candidates.StructuralDomainPass));
defaultID=Candidates.CandidateID(Candidates.DefaultL1Distance_V==0);assert(isscalar(defaultID));
InputChecks=thresholdInputChecks(inputFolder,NO,NS,e,f,tail,Cases,dts,socs);
assert(all(InputChecks.Pass),'Inherited checks failed. No candidate sweep or selection performed.');
Q=load(fullfile(inputFolder,'NominalPlan.mat'),'plan','NominalNode');plan=Q.plan;
assert(isfield(Q,'NominalNode'),'NominalPlan.mat must include its authoritative nominal node trace.');
assert(isequal(plan.NominalMassFactors,[1 1])&&plan.NominalOffset_s==35&&plan.Train_dt_s==.0025);
rebuilt=makeOpportunityModel(Q.NominalNode,e,f);
assert(isequal(plan.Edges_s,rebuilt.Edges_s)&&isequal(plan.Cumulative_kWh,rebuilt.Cumulative_kWh) ...
 &&plan.Finish_s==rebuilt.Finish_s&&plan.Band_kWh==rebuilt.Band_kWh, ...
 'Saved nominal opportunity model does not reproduce from its unchanged nominal trace.');
out=['FYP_DCThreshold_v1_Output_' datestr(now,'yyyymmdd_HHMMSS_FFF')];mkdir(out);
config=struct('InheritedScheduleFolder',inputFolder,'InheritedConfig',previous, ...
 'Electrical',e,'Storage',f,'Tail',tail,'Cases',Cases,'Candidates',Candidates, ...
 'DefaultCandidateID',defaultID,'ChargeThresholdGrid_V',chargeGrid,'DischargeThresholdGrid_V',dischargeGrid, ...
 'SOC0',socs,'DC_dt_s',dts,'Horizons_s',horizons,'Controllers',{names}, ...
 'SelectionStep_s',dts(end),'TieTolerance_kWh',tieTolerance, ...
 'SelectionObjective','One global pair per family: equal-weight mean CombinedSource_kWh over 7 cases x 2 SOCs', ...
 'TieRule','Within 1e-8 kWh of minimum: nearest L1 to default, then lower charge, then lower discharge', ...
 'RankingDiagnostic','Gap versus twice largest observed mean step change is a heuristic, not an error bound', ...
 'DomainBasis','Synthetic structural threshold constraints, not empirical or safety operating limits', ...
 'Scope','Seven already-examined development cases; no holdout, CI, reliability or optimum claim', ...
 'MATLABVersion',version);
% Freeze this definition and the inherited plan BEFORE candidate outcomes.
save(fullfile(out,'ThresholdSettings.mat'),'config');save(fullfile(out,'FrozenNominalPlan.mat'),'plan');
copyfile([mfilename('fullpath') '.m'],fullfile(out,'SourceSnapshot.m'));
copyfile(fullfile(inputFolder,'SourceSnapshot.m'),fullfile(out,'InheritedScheduleSource.m'));
writetable(Candidates,fullfile(out,'ThresholdCandidates.csv'));writetable(Cases,fullfile(out,'CaseDefinitions.csv'));
writetable(InputChecks,fullfile(out,'ThresholdInputChecks.csv'));
planTimes=(0:ceil((plan.Finish_s+2*max(horizons))/e.ControlPeriod_s))'*e.ControlPeriod_s;
fixedSchedule=planReserve(plan,planTimes,horizons);
nc=height(Cases);nd=numel(dts);ns=numel(socs);np=numel(names);nt=height(Candidates);
grids=cell(nc,nd);signals=cell(nc,1);traceRows=cell(nc*nd,1);planRows=cell(nc,1);
for k=1:nc
 Q=load(fullfile(inputFolder,sprintf('Case%02d_Input.mat',Cases.CaseID(k))),'N');N=Q.N;
 assert(istable(N)&&height(N)>0&&all(ismember({'Time_s','Step_s','GrossDemand_W','OfferedRegen_W'},N.Properties.VariableNames)));
 assert(all(isfinite(N{:,{'Time_s','Step_s','GrossDemand_W','OfferedRegen_W'}}),'all'));
 assert(N.Time_s(1)==0&&all(N.Step_s>0)&&all(diff(N.Time_s)>0));
 assert(max(abs(N.Time_s(1:end-1)+N.Step_s(1:end-1)-N.Time_s(2:end)))<1e-8);
 assert(all(N.GrossDemand_W>=0)&&all(N.OfferedRegen_W>=0));
 rawEnergy=sum((N.GrossDemand_W-N.OfferedRegen_W).*N.Step_s)/3.6e6;
 counts=zeros(1,nd);
 for j=1:nd
  G=eventGrid(N,dts(j),e.ControlPeriod_s);grids{k,j}=G;counts(j)=max(G.controlID);
  native=NO(NO.CaseID==Cases.CaseID(k)&abs(NO.dt_s-dts(j))<1e-12,:);
  alignmentError=abs(sum(G.p.*G.h)/3.6e6-rawEnergy);nativeError=max(abs(native.NetTrain_kWh-rawEnergy));
  assert(height(native)==8&&alignmentError<=e.BalanceTol_kWh&&nativeError<e.BalanceTol_kWh);
  traceRows{(k-1)*nd+j}=struct('CaseID',Cases.CaseID(k),'dt_s',dts(j), ...
   'RawNetTrain_kWh',rawEnergy,'AlignmentError_kWh',alignmentError,'MaxNativeNetTrainDifference_kWh',nativeError, ...
   'Tolerance_kWh',e.BalanceTol_kWh,'Pass',alignmentError<=e.BalanceTol_kWh&&nativeError<e.BalanceTol_kWh);
 end
 assert(all(counts==counts(1))&&counts(1)<=numel(planTimes));
 t=(0:counts(1)-1)'*e.ControlPeriod_s;
 % Actual inputs determine only which clock ticks the simulation executes.
 % This pure forecast API has NO actual-case or actual-end argument.
 schedule=planReserve(plan,t,horizons);
 delta=max(abs(schedule-fixedSchedule(1:numel(t),:)),[],'all');
 signals{k}=struct('Schedule_kWh',schedule,'Preview_kWh',zeros(size(schedule)));
 planRows{k}=struct('CaseID',Cases.CaseID(k),'ControlTicks',counts(1),'PlanDuration_s',plan.Finish_s, ...
  'MaxSameClockPlanDeviation_kWh',delta,'Tolerance_kWh',1e-12,'Pass',delta<=1e-12);
end
TraceChecks=struct2table(vertcat(traceRows{:}));PlanChecks=struct2table(vertcat(planRows{:}));
assert(all(TraceChecks.Pass)&&all(PlanChecks.Pass));
writetable(TraceChecks,fullfile(out,'ThresholdTraceChecks.csv'));writetable(PlanChecks,fullfile(out,'ThresholdPlanChecks.csv'));
tailGrids=cell(nd,1);for j=1:nd,tailGrids{j}=tailGrid(tail.Duration_s,dts(j),e.ControlPeriod_s);end
parallelOK=false;
if license('test','Distrib_Computing_Toolbox')
 try
  pool=gcp('nocreate');if isempty(pool),pool=parpool('threads');end
  parallelOK=true;fprintf('Parallel independent jobs: %d workers.\n',pool.NumWorkers);
 catch ME,warning('FYP:SerialFallback','Using serial execution: %s',ME.message);
 end
end
jobs=nc*nd*ns*np*nt;assert(jobs==504);originalRows=cell(jobs,1);terminalRows=cell(jobs,1);
fprintf('DEVELOPMENT threshold sweep: %d jobs, 9 settings per family. No independent test.\n',jobs);
if parallelOK
 parfor job=1:jobs
  [originalRows{job},terminalRows{job}]=thresholdJob(job,Cases,Candidates,grids,signals,tailGrids,e,f,tail,dts,socs,names,horizons);
 end
else
 for job=1:jobs
  [originalRows{job},terminalRows{job}]=thresholdJob(job,Cases,Candidates,grids,signals,tailGrids,e,f,tail,dts,socs,names,horizons);
 end
end
Original=struct2table(vertcat(originalRows{:}));Summary=struct2table(vertcat(terminalRows{:}));
DefaultChecks=thresholdDefaults(Original,Summary,NO,NS,Cases,dts,socs,names,defaultID);
LedgerChecks=thresholdLedgers(Original,Summary,e,f,tail);
implementationPass=all(InputChecks.Pass)&&all(TraceChecks.Pass)&&all(PlanChecks.Pass)&&all(DefaultChecks.Pass)&&all(LedgerChecks.Pass);
Summary.ImplementationChecksPass=repmat(implementationPass,height(Summary),1);
Paired=thresholdMatched(Summary,Cases,dts,socs,Candidates,tail,e);
StepChecks=thresholdSteps(Original,Summary,Cases,dts,socs,Candidates,names,tail);
PairedStepChecks=thresholdPairSteps(Paired,dts,tail.StepEnergyTol_kWh,e.BalanceTol_kWh);
gate=implementationPass&&all(Summary.Comparable)&&all(StepChecks.Pass)&&all(Paired.Comparable)&&all(PairedStepChecks.StepTolerancePass);
[Curve,Selection]=thresholdSelection(Summary,Candidates,names,dts,tieTolerance,gate);
Named=Paired([],:);NamedSteps=PairedStepChecks([],:);
if gate
 Named=thresholdNamed(Summary,Selection,Cases,dts,socs,defaultID,tail,e);
 NamedSteps=thresholdPairSteps(Named,dts,tail.StepEnergyTol_kWh,e.BalanceTol_kWh);
 gate=gate&&all(Named.Comparable)&&all(NamedSteps.StepTolerancePass);
 if ~gate
  [Curve,Selection]=thresholdSelection(Summary,Candidates,names,dts,tieTolerance,false);
 end
end
Named.SelectionGatePass=repmat(gate,height(Named),1);
files={'ThresholdOriginalMetrics.csv',Original;'ThresholdSummary.csv',Summary; ...
 'ThresholdDefaultChecks.csv',DefaultChecks;'ThresholdLedgerChecks.csv',LedgerChecks; ...
 'ThresholdMatchedPairs.csv',Paired;'ThresholdStepChecks.csv',StepChecks; ...
 'ThresholdPairedStepChecks.csv',PairedStepChecks;'ThresholdDevelopmentCurve.csv',Curve; ...
 'ThresholdSelection.csv',Selection;'ThresholdNamedComparisons.csv',Named;'ThresholdNamedStepChecks.csv',NamedSteps};
for k=1:size(files,1),writetable(files{k,2},fullfile(out,files{k,1}));end
plotThreshold(Curve,Selection,Named,names,dts(end),fullfile(out,'ThresholdDevelopmentChecks.png'));
reviewFiles=[{'ThresholdSettings.mat','SourceSnapshot.m','InheritedScheduleSource.m', ...
 'ThresholdCandidates.csv','CaseDefinitions.csv','ThresholdInputChecks.csv','ThresholdTraceChecks.csv', ...
 'ThresholdPlanChecks.csv','ThresholdDevelopmentChecks.png'},files(:,1)'];
zipPath=fullfile(pwd,out,'ThresholdReview.zip');zip(zipPath,reviewFiles,out);
fprintf('\nDEVELOPMENT THRESHOLD SWEEP FINISHED\n');
fprintf('Default failures: %d / 56; terminal failures: %d / 504; ledger failures: %d / 504.\n', ...
 sum(~DefaultChecks.Pass),sum(~Summary.Comparable),sum(~LedgerChecks.Pass));
fprintf('Individual step failures: %d / 252; matched paired step failures: %d / 126.\n', ...
 sum(~StepChecks.Pass),sum(~PairedStepChecks.StepTolerancePass));
fprintf('Named comparison step failures: %d / %d. Selection gate: %d.\n',sum(~NamedSteps.StepTolerancePass),height(NamedSteps),gate);
disp(Selection);
if gate
 types=unique(Named.Comparison,'stable');
 for k=1:numel(types)
  a=Named(Named.dt_s==dts(end)&Named.Comparison==types(k),:);
  fprintf('%s: mean Reference - Test = %.9f kWh across %d development case/SOC records.\n', ...
   char(types(k)),mean(a.CombinedSourceSaving_kWh),height(a));
 end
else
 warning('FYP:SelectionBlocked','A verification gate failed: no thresholds selected. Retain all diagnostic outputs.');
end
fprintf('Send ThresholdReview.zip and the final console summary.\nReview packet: %s\n',zipPath);
fprintf('Positive paired savings favor the Test policy. All negative effects retained.\n');
fprintf('These seven cases were all used for development. Grid winners are not optimal or held-out results.\n');
end

function [r,z]=thresholdJob(job,Cases,Candidates,grids,signals,tailGrids,e,f,tail,dts,socs,names,horizons)
nt=height(Candidates);np=numel(names);ns=numel(socs);nd=numel(dts);
k=floor((job-1)/(nd*ns*np*nt))+1;w=mod(job-1,nd*ns*np*nt);
d=floor(w/(ns*np*nt))+1;s=floor(mod(w,ns*np*nt)/(np*nt))+1;
c=floor(mod(w,np*nt)/nt)+1;j=mod(w,nt)+1;
local=e;local.ChargeThreshold_V=Candidates.ChargeThreshold_V(j);local.DischargeThreshold_V=Candidates.DischargeThreshold_V(j);
controllerIDs=[0 2];
[r,~]=simulateSchedule(grids{k,d},local,f,socs(s),controllerIDs(c),signals{k},horizons,false);
z=runTail(r,tailGrids{d},local,f,tail);
r.Controller=names{c};r.CandidateID=Candidates.CandidateID(j);r.ChargeThreshold_V=local.ChargeThreshold_V;
r.DischargeThreshold_V=local.DischargeThreshold_V;r.CaseID=Cases.CaseID(k);r.SOC0=socs(s);r.dt_s=dts(d);
z.Controller=names{c};z.CandidateID=Candidates.CandidateID(j);z.ChargeThreshold_V=local.ChargeThreshold_V;
z.DischargeThreshold_V=local.DischargeThreshold_V;z.CaseID=Cases.CaseID(k);z.SOC0=socs(s);z.dt_s=dts(d);
fprintf('Development case %d, %s, charge=%g, discharge=%g V, SOC0=%.2f, dt=%.6f complete.\n', ...
 r.CaseID,r.Controller,r.ChargeThreshold_V,r.DischargeThreshold_V,r.SOC0,r.dt_s);
end

function thresholdConfiguration(p,e,f,tail,Cases,O,S)
assert(isequal(p.DC_dt_s,[.00125 .000625])&&isequal(p.SOC0,[.55 .85])&&isequal(p.Horizons_s,[5 10 15 20]));
assert(isequal(Cases{:,{'CaseID','MassFactorA','MassFactorB','ActualOffset_s'}}, ...
 [0 1 1 35;1 .95 1.05 32.5;2 .95 1.05 37.5;3 1.05 .95 32.5;4 1.05 .95 37.5;5 1 1 32.5;6 1 1 37.5]));
assert(height(O)==112&&height(S)==112,'Expected frozen Schedule records.');
assert(e.Vsource==750&&e.Rsource==.02&&e.Cdc==1.5&&e.Vinitial==750&&e.ControlPeriod_s==.01);
assert(e.ChopperOn_V==900&&e.ChopperGain_WpV==250e3&&e.ChopperMax_W==4e6);
assert(e.DomainLow_V==450&&e.DomainHigh_V==1100&&e.ChargeThreshold_V==800&&e.DischargeThreshold_V==710);
assert(e.SOCShift_V==35&&e.ControlGain_WpV==90e3&&e.SOClow==.02&&e.SOChigh==.98&&e.SOCtaper==.05);
assert(e.BalanceTol_kWh==1e-6&&e.StateTol_kWh==1e-10&&e.RootEnergyTol_J==1e-7);
assert(f.capacity_kWh==4.5&&f.maxCharge_W==1e6&&f.maxDischarge_W==1e6&&abs(f.etaC-sqrt(.87))<1e-12&&abs(f.etaD-sqrt(.87))<1e-12);
assert(tail.Load_W==200e3&&tail.RestorePower_W==100e3&&tail.Duration_s==194);
assert(tail.StorageTargetTol_kWh==1e-8&&tail.FinalVoltageTol_V==1e-6&&tail.StepEnergyTol_kWh==.005&&tail.StepVoltageTol_V==.1);
end

function C=thresholdInputChecks(folder,O,S,e,f,tail,Cases,dts,socs)
spec={'ScheduleBaselineChecks.csv','Pass',12; 'NominalScheduleChecks.csv','Pass',4; ...
 'PlanInputChecks.csv','PlanSignalInvariant',7; 'TrainChecks.csv','Pass',3; ...
 'PolicyChecks.csv','Pass',9; 'ScheduleStepChecks.csv','Pass',56; ...
 'SchedulePairedStepChecks.csv','StepTolerancePass',84};
rows=cell(size(spec,1)+4,1);
for k=1:size(spec,1)
 T=readtable(fullfile(folder,spec{k,1}));flag=T.(spec{k,2});
 pass=height(T)==spec{k,3}&&all(isfinite(double(flag)))&&all(double(flag)==1);
 rows{k}=struct('Check',string(spec{k,1}),'Records',height(T),'ExpectedRecords',spec{k,3},'Pass',pass);
end
names=["VoltageReactive","FixedReserve","SchedulePreview","PerfectPreview"];
ok=true;
for id=Cases.CaseID'
 for dt=dts
  for soc=socs
   for name=names
    a=O(O.CaseID==id&abs(O.dt_s-dt)<1e-12&abs(O.SOC0-soc)<1e-12&string(O.Controller)==name,:);
    b=S(S.CaseID==id&abs(S.dt_s-dt)<1e-12&abs(S.SOC0-soc)<1e-12&string(S.Controller)==name,:);
    assert(height(a)==1&&height(b)==1,'Duplicated or missing native key.');
    original=a.Source_kWh-a.NetTrain_kWh-a.SourceResistanceLoss_kWh-a.Chopper_kWh-a.ConversionLoss_kWh ...
     -(a.FinalStored_kWh-a.InitialStored_kWh)-(a.FinalCapacitor_kWh-a.InitialCapacitor_kWh);
    combined=b.CombinedSource_kWh-a.NetTrain_kWh-b.TailLoad_kWh-b.CombinedDissipation_kWh ...
     -(b.FinalStored_kWh-a.InitialStored_kWh)-(b.FinalCapacitor_kWh-a.InitialCapacitor_kWh);
    values=[original,combined,b.CombinedSource_kWh-a.Source_kWh-b.TailSource_kWh, ...
     b.OriginalSource_kWh-a.Source_kWh,b.TargetStored_kWh-a.InitialStored_kWh];
    ok=ok&&all(isfinite(values))&&all(abs(values)<e.BalanceTol_kWh) ...
     &&b.Comparable==1&&b.ImplementationChecksPass==1 ...
     &&abs(b.FinalStored_kWh-b.TargetStored_kWh)<=tail.StorageTargetTol_kWh ...
     &&abs(b.FinalVoltage_V-tail.SteadyVoltage_V)<=tail.FinalVoltageTol_V ...
     &&abs(a.InitialStored_kWh-soc*f.capacity_kWh)<1e-10;
   end
  end
 end
end
n=size(spec,1);rows{n+1}=struct('Check',"Native keys, ledgers and terminal comparability",'Records',height(S),'ExpectedRecords',112,'Pass',ok);
T=readtable(fullfile(folder,'StationChecks.csv'));
ok=height(T)==9&&all(abs(T.StopPositionError_m)<1e-6)&&all(abs(T.StopSpeed_mps)<1e-8);
rows{n+2}=struct('Check',"Inherited station checks",'Records',height(T),'ExpectedRecords',9,'Pass',ok);
T=readtable(fullfile(folder,'NodeChecks.csv'));ok=height(T)==7&&all(T.MaxAlignmentError_kWh<1e-8);
rows{n+3}=struct('Check',"Inherited node checks",'Records',height(T),'ExpectedRecords',7,'Pass',ok);
rows{n+4}=struct('Check',"All prior terminal comparability flags",'Records',height(S),'ExpectedRecords',112,'Pass',all(S.Comparable==1));
C=struct2table(vertcat(rows{:}));
end

function C=thresholdDefaults(O,S,NO,NS,Cases,dts,socs,names,defaultID)
of={'Source_kWh','SourceToBus_kWh','SourceResistanceLoss_kWh','Chopper_kWh','ChargeBus_kWh','DischargeBus_kWh', ...
 'ConversionLoss_kWh','NetTrain_kWh','InitialStored_kWh','FinalStored_kWh','MinStored_kWh','MaxStored_kWh', ...
 'InitialCapacitor_kWh','FinalCapacitor_kWh','WrapperExtraCommandProxy_kWh'};
tf={'OriginalSource_kWh','TailSource_kWh','TailSourceResistanceLoss_kWh','TailChopper_kWh','TailConversionLoss_kWh', ...
 'TailChargeBus_kWh','TailDischargeBus_kWh','FinalStored_kWh','FinalCapacitor_kWh','CombinedSource_kWh','CombinedDissipation_kWh'};
rows=cell(56,1);n=0;
for id=Cases.CaseID'
 for dt=dts
  for soc=socs
   for c=1:numel(names)
    name=string(names{c});a=O(O.CaseID==id&O.dt_s==dt&O.SOC0==soc&O.CandidateID==defaultID&string(O.Controller)==name,:);
    z=S(S.CaseID==id&S.dt_s==dt&S.SOC0==soc&S.CandidateID==defaultID&string(S.Controller)==name,:);
    b=NO(NO.CaseID==id&NO.dt_s==dt&NO.SOC0==soc&string(NO.Controller)==name,:);
    w=NS(NS.CaseID==id&NS.dt_s==dt&NS.SOC0==soc&string(NS.Controller)==name,:);
    assert(height(a)==1&&height(z)==1&&height(b)==1&&height(w)==1);
    de=max([abs(a{1,of}-b{1,of}),abs(z{1,tf}-w{1,tf})]);
    dv=max([abs(a{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}-b{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}), ...
     abs(z{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}}-w{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}})]);
    n=n+1;rows{n}=struct('CaseID',id,'SOC0',soc,'dt_s',dt,'Controller',name,'CandidateID',defaultID, ...
     'MaxEnergyDifference_kWh',de,'MaxVoltageDifference_V',dv,'EnergyTolerance_kWh',1e-6,'VoltageTolerance_V',1e-5, ...
     'Pass',z.Comparable&&w.Comparable&&isfinite(de)&&isfinite(dv)&&de<=1e-6&&dv<=1e-5);
   end
  end
 end
end
assert(n==56);C=struct2table(vertcat(rows{:}));
end

function L=thresholdLedgers(O,S,e,f,tail)
assert(height(O)==504&&height(S)==504);rows=cell(height(O),1);
for k=1:height(O)
 a=O(k,:);b=S(k,:);
 assert(a.CaseID==b.CaseID&&a.CandidateID==b.CandidateID&&a.SOC0==b.SOC0&&a.dt_s==b.dt_s&&string(a.Controller)==string(b.Controller));
 original=a.Source_kWh-a.NetTrain_kWh-a.SourceResistanceLoss_kWh-a.Chopper_kWh-a.ConversionLoss_kWh ...
  -(a.FinalStored_kWh-a.InitialStored_kWh)-(a.FinalCapacitor_kWh-a.InitialCapacitor_kWh);
 combined=b.CombinedSource_kWh-a.NetTrain_kWh-b.TailLoad_kWh-b.CombinedDissipation_kWh ...
  -(b.FinalStored_kWh-a.InitialStored_kWh)-(b.FinalCapacitor_kWh-a.InitialCapacitor_kWh);
 storage=a.FinalStored_kWh-a.InitialStored_kWh-f.etaC*a.ChargeBus_kWh+a.DischargeBus_kWh/f.etaD;
 add=b.CombinedSource_kWh-a.Source_kWh-b.TailSource_kWh;
 values=[original,combined,storage,add,b.OriginalSource_kWh-a.Source_kWh,b.TargetStored_kWh-a.InitialStored_kWh, ...
  original-a.SystemResidual_kWh,combined-b.CombinedSystemResidual_kWh,storage-a.StorageResidual_kWh];
 pass=all(isfinite(values))&&all(abs(values)<e.BalanceTol_kWh)&&b.Comparable ...
  &&abs(b.FinalStored_kWh-b.TargetStored_kWh)<=tail.StorageTargetTol_kWh ...
  &&abs(b.FinalVoltage_V-tail.SteadyVoltage_V)<=tail.FinalVoltageTol_V;
 rows{k}=struct('CaseID',a.CaseID,'SOC0',a.SOC0,'dt_s',a.dt_s,'Controller',string(a.Controller), ...
  'CandidateID',a.CandidateID,'OriginalSystemResidual_kWh',original,'CombinedSystemResidual_kWh',combined, ...
  'StorageResidual_kWh',storage,'SourceAdditionResidual_kWh',add,'MaxCheckedResidual_kWh',max(abs(values)), ...
  'Tolerance_kWh',e.BalanceTol_kWh,'Pass',pass);
end
L=struct2table(vertcat(rows{:}));
end

function r=thresholdPair(a,b,label,tail,e)
assert(height(a)==1&&height(b)==1&&a.CaseID==b.CaseID&&a.SOC0==b.SOC0&&a.dt_s==b.dt_s);
valid=a.Comparable&&b.Comparable&&a.ImplementationChecksPass&&b.ImplementationChecksPass ...
 &&abs(a.TargetStored_kWh-b.TargetStored_kWh)<1e-10&&abs(a.TailLoad_kWh-b.TailLoad_kWh)<1e-8 ...
 &&abs(a.FinalStored_kWh-b.FinalStored_kWh)<=2*tail.StorageTargetTol_kWh ...
 &&abs(a.FinalVoltage_V-b.FinalVoltage_V)<=2*tail.FinalVoltageTol_V;
source=a.CombinedSource_kWh-b.CombinedSource_kWh;loss=a.CombinedDissipation_kWh-b.CombinedDissipation_kWh;
difference=source-loss;valid=valid&&all(isfinite([source,loss,difference]))&&abs(difference)<2*e.BalanceTol_kWh;
if ~valid,source=NaN;loss=NaN;end
r=struct('CaseID',a.CaseID,'SOC0',a.SOC0,'dt_s',a.dt_s,'Comparison',string(label), ...
 'ReferenceController',string(a.Controller),'TestController',string(b.Controller), ...
 'ReferenceCandidateID',a.CandidateID,'TestCandidateID',b.CandidateID, ...
 'ReferenceChargeThreshold_V',a.ChargeThreshold_V,'ReferenceDischargeThreshold_V',a.DischargeThreshold_V, ...
 'TestChargeThreshold_V',b.ChargeThreshold_V,'TestDischargeThreshold_V',b.DischargeThreshold_V, ...
 'OriginalSourceSaving_kWh',a.OriginalSource_kWh-b.OriginalSource_kWh, ...
 'TailSourceSaving_kWh',a.TailSource_kWh-b.TailSource_kWh,'CombinedSourceSaving_kWh',source, ...
 'CombinedDissipationSaving_kWh',loss,'SourceVsDissipationDifference_kWh',difference, ...
 'FinalStoredDifference_kWh',b.FinalStored_kWh-a.FinalStored_kWh, ...
 'FinalCapacitorDifference_kWh',b.FinalCapacitor_kWh-a.FinalCapacitor_kWh,'Comparable',valid);
end

function P=thresholdMatched(S,Cases,dts,socs,Candidates,tail,e)
rows=cell(252,1);n=0;
for id=Cases.CaseID'
 for dt=dts
  for soc=socs
   for theta=Candidates.CandidateID'
    x=S.CaseID==id&S.dt_s==dt&S.SOC0==soc&S.CandidateID==theta;
    a=S(x&string(S.Controller)=="VoltageReactive",:);b=S(x&string(S.Controller)=="SchedulePreview",:);
    n=n+1;rows{n}=thresholdPair(a,b,"MatchedThresholds",tail,e);
   end
  end
 end
end
assert(n==252);P=struct2table(vertcat(rows{:}));
end

function P=thresholdNamed(S,Selection,Cases,dts,socs,defaultID,tail,e)
assert(all(Selection.SelectionGatePass));
vrID=Selection.SelectedCandidateID(Selection.Controller=="VoltageReactive");
spID=Selection.SelectedCandidateID(Selection.Controller=="SchedulePreview");
refIDs=[defaultID vrID vrID vrID];testIDs=[defaultID defaultID vrID spID];
labels=["DefaultMatched","FrozenScheduleVsSelectedVR","MatchedAtSelectedVR","SeparatelySelectedFamilies"];
rows=cell(112,1);n=0;
for id=Cases.CaseID'
 for dt=dts
  for soc=socs
   for j=1:numel(labels)
    x=S.CaseID==id&S.dt_s==dt&S.SOC0==soc;
    a=S(x&S.CandidateID==refIDs(j)&string(S.Controller)=="VoltageReactive",:);
    b=S(x&S.CandidateID==testIDs(j)&string(S.Controller)=="SchedulePreview",:);
    n=n+1;rows{n}=thresholdPair(a,b,labels(j),tail,e);
   end
  end
 end
end
assert(n==112);P=struct2table(vertcat(rows{:}));
end

function C=thresholdSteps(O,S,Cases,dts,socs,Candidates,names,tail)
of={'Source_kWh','Chopper_kWh','SourceResistanceLoss_kWh','ConversionLoss_kWh','FinalStored_kWh','FinalCapacitor_kWh','ChargeBus_kWh','DischargeBus_kWh'};
tf={'CombinedSource_kWh','CombinedDissipation_kWh','TailSource_kWh','TailSourceResistanceLoss_kWh','TailChopper_kWh','TailConversionLoss_kWh','TailChargeBus_kWh','TailDischargeBus_kWh','FinalStored_kWh','FinalCapacitor_kWh'};
rows=cell(252,1);n=0;
for id=Cases.CaseID'
 for soc=socs
  for theta=Candidates.CandidateID'
   for j=1:numel(names)
    x=O.CaseID==id&O.SOC0==soc&O.CandidateID==theta&string(O.Controller)==string(names{j});
    ia=x&O.dt_s==dts(1);ib=x&O.dt_s==dts(2);assert(sum(ia)==1&&sum(ib)==1);
    a=O(ia,:);b=O(ib,:);ta=S(ia,:);tb=S(ib,:);
    de=max([abs(a{1,of}-b{1,of}),abs(ta{1,tf}-tb{1,tf})]);
    dv=max([abs(a{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}-b{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}), ...
     abs(ta{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}}-tb{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}})]);
    n=n+1;rows{n}=struct('CaseID',id,'SOC0',soc,'Controller',string(names{j}),'CandidateID',theta, ...
     'Coarse_dt_s',dts(1),'Fine_dt_s',dts(2),'MaxEnergyChange_kWh',de,'MaxVoltageChange_V',dv, ...
     'EnergyTolerance_kWh',tail.StepEnergyTol_kWh,'VoltageTolerance_V',tail.StepVoltageTol_V, ...
     'Pass',ta.Comparable&&tb.Comparable&&isfinite(de)&&isfinite(dv)&&de<=tail.StepEnergyTol_kWh&&dv<=tail.StepVoltageTol_V);
   end
  end
 end
end
assert(n==252);C=struct2table(vertcat(rows{:}));
end

function C=thresholdPairSteps(P,dts,tolerance,zeroTolerance)
A=P(P.dt_s==dts(1),:);rows=cell(height(A),1);
for k=1:height(A)
 a=A(k,:);b=P(P.dt_s==dts(2)&P.CaseID==a.CaseID&P.SOC0==a.SOC0 ...
  &P.ReferenceCandidateID==a.ReferenceCandidateID&P.TestCandidateID==a.TestCandidateID ...
  &P.Comparison==a.Comparison,:);assert(height(b)==1);
 coarse=a.CombinedSourceSaving_kWh;fine=b.CombinedSourceSaving_kWh;valid=a.Comparable&&b.Comparable;
 resolved=valid&&abs(coarse)>zeroTolerance&&abs(fine)>zeroTolerance;
 rows{k}=struct('CaseID',a.CaseID,'SOC0',a.SOC0,'Comparison',a.Comparison, ...
  'ReferenceCandidateID',a.ReferenceCandidateID,'TestCandidateID',a.TestCandidateID, ...
  'Coarse_dt_s',dts(1),'Fine_dt_s',dts(2),'CoarseCombinedSourceSaving_kWh',coarse, ...
  'FineCombinedSourceSaving_kWh',fine,'AbsChange_CombinedSaving_kWh',abs(coarse-fine), ...
  'EnergyTolerance_kWh',tolerance,'SignZeroTolerance_kWh',zeroTolerance,'BothSignsResolved',resolved, ...
  'SameResolvedSign',resolved&&sign(coarse)==sign(fine),'Comparable',valid, ...
  'StepTolerancePass',valid&&isfinite(coarse)&&isfinite(fine)&&abs(coarse-fine)<=tolerance);
end
C=struct2table(vertcat(rows{:}));
end

function index=thresholdWinner(C,tolerance)
assert(all(isfinite(C.MeanCombinedSource_kWh)));
low=min(C.MeanCombinedSource_kWh);eligible=C(C.MeanCombinedSource_kWh<=low+tolerance,:);
eligible=sortrows(eligible,{'DefaultL1Distance_V','ChargeThreshold_V','DischargeThreshold_V'});
index=find(C.CandidateID==eligible.CandidateID(1));assert(isscalar(index));
end

function [Curve,Selection]=thresholdSelection(S,Candidates,names,dts,tolerance,gate)
rows=cell(36,1);n=0;
for c=1:numel(names)
 for d=1:numel(dts)
  for j=1:height(Candidates)
   T=S(S.dt_s==dts(d)&S.CandidateID==Candidates.CandidateID(j)&string(S.Controller)==string(names{c}),:);
   assert(height(T)==14);
   n=n+1;rows{n}=struct('Controller',string(names{c}),'dt_s',dts(d),'CandidateID',Candidates.CandidateID(j), ...
    'ChargeThreshold_V',Candidates.ChargeThreshold_V(j),'DischargeThreshold_V',Candidates.DischargeThreshold_V(j), ...
    'DefaultL1Distance_V',Candidates.DefaultL1Distance_V(j),'CaseSOCRecords',height(T), ...
    'MeanCombinedSource_kWh',mean(T.CombinedSource_kWh),'AllTerminalComparable',all(T.Comparable), ...
    'StrictValueRank',NaN,'SelectionGatePass',gate,'SelectedAtFinest',false);
  end
 end
end
assert(n==36);Curve=struct2table(vertcat(rows{:}));selectionRows=cell(numel(names),1);
for c=1:numel(names)
 name=string(names{c});coarse=Curve(Curve.Controller==name&Curve.dt_s==dts(1),:);
 fine=Curve(Curve.Controller==name&Curve.dt_s==dts(2),:);
 coarse=sortrows(coarse,'CandidateID');fine=sortrows(fine,'CandidateID');
 finite=all(isfinite([coarse.MeanCombinedSource_kWh;fine.MeanCombinedSource_kWh]));
 fineID=NaN;coarseID=NaN;lowest=NaN;selected=NaN;chosenMean=NaN;uc=NaN;ud=NaN;
 meanChange=NaN;gap=NaN;stable=false;heuristic=false;maxRankChange=NaN;selectedMeanStepChange=NaN;
 if finite
  i=thresholdWinner(fine,tolerance);j=thresholdWinner(coarse,tolerance);
  fineID=fine.CandidateID(i);coarseID=coarse.CandidateID(j);lowest=min(fine.MeanCombinedSource_kWh);
  fineRanks=zeros(height(fine),1);coarseRanks=zeros(height(coarse),1);
  [~,fi]=sort(fine.MeanCombinedSource_kWh);[~,ci]=sort(coarse.MeanCombinedSource_kWh);
  fineRanks(fi)=(1:height(fine))';coarseRanks(ci)=(1:height(coarse))';
  Curve.StrictValueRank(Curve.Controller==name&Curve.dt_s==dts(2))=fineRanks;
  Curve.StrictValueRank(Curve.Controller==name&Curve.dt_s==dts(1))=coarseRanks;
  maxRankChange=max(abs(fineRanks-coarseRanks));stable=fineID==coarseID;
  meanChange=max(abs(coarse.MeanCombinedSource_kWh-fine.MeanCombinedSource_kWh));
  ordered=sort(fine.MeanCombinedSource_kWh);gap=ordered(2)-ordered(1);
  heuristic=gap>2*meanChange;selectedMeanStepChange=abs(fine.MeanCombinedSource_kWh(i)-coarse.MeanCombinedSource_kWh(i));
  if gate
   selected=fineID;chosenMean=fine.MeanCombinedSource_kWh(i);uc=fine.ChargeThreshold_V(i);ud=fine.DischargeThreshold_V(i);
   Curve.SelectedAtFinest(Curve.Controller==name&Curve.dt_s==dts(2)&Curve.CandidateID==selected)=true;
  end
 end
 selectionRows{c}=struct('Controller',name,'SelectionGatePass',gate, ...
  'SelectedCandidateID',selected,'SelectedChargeThreshold_V',uc,'SelectedDischargeThreshold_V',ud, ...
  'LowestCandidateMean_kWh',lowest,'SelectedMean_kWh',chosenMean,'TieTolerance_kWh',tolerance, ...
  'DiagnosticFineWinnerID',fineID,'DiagnosticCoarseWinnerID',coarseID,'SameStepWinner',stable, ...
  'MaxCandidateRankChange',maxRankChange,'FinestBestToSecondGap_kWh',gap, ...
  'MaxAbsCandidateMeanStepChange_kWh',meanChange,'FineWinnerMeanStepChange_kWh',selectedMeanStepChange, ...
  'GapExceedsTwiceObservedChange_Heuristic',heuristic, ...
  'DiagnosticScope',"Two-step ranking diagnostic only; not a rigorous error bound");
end
Selection=struct2table(vertcat(selectionRows{:}));
end

function plotThreshold(C,S,N,names,dt,path)
fig=figure('Color','w','Position',[60 60 1500 800]);tiledlayout(2,2);
for c=1:numel(names)
 nexttile;T=sortrows(C(C.Controller==string(names{c})&C.dt_s==dt,:),'CandidateID');
 plot(T.CandidateID,T.MeanCombinedSource_kWh,'o-','LineWidth',1.3);hold on;grid on;
 A=S(S.Controller==string(names{c}),:);
 if A.SelectionGatePass
  plot(A.SelectedCandidateID,A.SelectedMean_kWh,'kp','MarkerFaceColor','y','MarkerSize',12);
 end
 xticks(T.CandidateID);labels=compose('%g/%g',T.ChargeThreshold_V,T.DischargeThreshold_V);xticklabels(labels);xtickangle(35);
 xlabel('Charge / discharge base threshold (V)');ylabel('Mean episode + tail source energy (kWh)');
 title(string(names{c})+": nine development candidates",'Interpreter','none');
end
for s=1:2
 socs=[.55 .85];nexttile;hold on;grid on;
 if all(S.SelectionGatePass)
  labels=unique(N.Comparison,'stable');
  for j=1:numel(labels)
   A=sortrows(N(N.dt_s==dt&N.SOC0==socs(s)&N.Comparison==labels(j),:),'CaseID');
   plot(A.CaseID,A.CombinedSourceSaving_kWh,'o-','DisplayName',char(labels(j)));
  end
  legend('Interpreter','none','Location','best','FontSize',8);
 else
  text(.05,.5,'Verification gate failed; no selected comparison','Units','normalized');
 end
 yline(0,':','HandleVisibility','off');xlabel('Development case ID');ylabel('Reference - Test source energy (kWh)');
 title(sprintf('SOC0=%.2f; positive favors SchedulePreview',socs(s)));
end
sgtitle('Development-only threshold comparison: selected families are not independently tested');
exportgraphics(fig,path,'Resolution',200);
end

function model=makeOpportunityModel(N,e,f)
finish=N.Time_s(end)+N.Step_s(end);edges=[N.Time_s;finish];assert(all(diff(edges)>0));
p=N.GrossDemand_W-N.OfferedRegen_W;g=min(max(-p,0),f.maxCharge_W);
model=struct('Edges_s',edges,'Cumulative_kWh',[0;cumsum(g.*diff(edges))*f.etaC/3.6e6], ...
 'Finish_s',finish,'Band_kWh',(e.SOChigh-e.SOClow)*f.capacity_kWh);
end

function reserve=planReserve(plan,t,horizons)
% Pure schedule lookup: this interface receives NO actual case or actual end.
% Constant cumulative extension implements ZERO planned regen outside plan.
I=@(q)interp1(plan.Edges_s,plan.Cumulative_kWh,min(max(q,0),plan.Finish_s),'linear');
reserve=min(plan.Band_kWh,max(I(t+horizons)-I(t),0));
end

function [cmd,extra]=scheduleCommand(controller,V,E,p,e,f,horizons,scheduled,preview)
soc=E/f.capacity_kWh;rawVR=0;
uc=e.ChargeThreshold_V+e.SOCShift_V*(soc-.5);
ud=e.DischargeThreshold_V+e.SOCShift_V*(soc-.5);
if V>uc,rawVR=min(e.ControlGain_WpV*(V-uc),f.maxCharge_W);
elseif V<ud,rawVR=-min(e.ControlGain_WpV*(ud-V),f.maxDischarge_W);end
raw=rawVR;
if controller>0 && p>0 && rawVR<=0
 band=(e.SOChigh-e.SOClow)*f.capacity_kWh;
 if controller==1,opportunity=repmat(band,size(horizons));
 elseif controller==2,opportunity=scheduled;
 elseif controller==3,opportunity=preview;
 else,error('Unknown frozen policy.');end
 opportunity=min(max(opportunity,0),band);
 available=max(e.SOChigh*f.capacity_kWh-E,0);
 deficit=max(opportunity-available,0);
 need=max(f.etaD*3.6e6*deficit./horizons);
 pre=min([need,f.maxDischarge_W,max(p,0)]);
 raw=min(rawVR,-pre);
end
% Taper the final raw command exactly ONCE. Charge priority guarantees that
% rawVR and raw do not have opposite nonzero signs.
if raw>=0,a=min(max((e.SOChigh-soc)/e.SOCtaper,0),1);
else,a=min(max((soc-e.SOClow)/e.SOCtaper,0),1);end
cmd=raw*a;
if rawVR>=0,ab=min(max((e.SOChigh-soc)/e.SOCtaper,0),1);
else,ab=min(max((soc-e.SOClow)/e.SOCtaper,0),1);end
extra=max(rawVR*ab-cmd,0); % Command difference at the same sampled state, NOT a counterfactual trajectory.
end

function G=eventGrid(N,dt,tc)
finish=N.Time_s(end)+N.Step_s(end);
inputEdges=[N.Time_s;finish];controlEdges=(0:ceil(finish/tc)+1)'*tc;
e=unique([inputEdges;(0:floor(finish/dt))'*dt;controlEdges(controlEdges<finish);finish]);
t=e(1:end-1);h=diff(e);assert(all(h>0));
idx=discretize(t,inputEdges);ci=discretize(t,controlEdges);
assert(all(isfinite(idx)) && all(isfinite(ci)));
power=N.GrossDemand_W-N.OfferedRegen_W;
G=struct('t',t,'h',h,'p',power(idx),'controlID',ci);
assert(abs(sum(G.p.*h)-sum(power.*N.Step_s))/3.6e6<1e-8,'Input energy changed during alignment.');
end

function [r,T]=simulateSchedule(G,e,f,soc0,controller,F,horizons,keep)
E0=f.capacity_kWh*soc0;E=E0;V=e.Vinitial;controlID=0;cmd=0;
extra=0;overrideTicks=0;overrideDuration=0;extraCommandProxy=0;
% Accounts are Joules: source,bus,line,chopper,charge,discharge,loss,train.
q=zeros(1,8);rootAbs=0;roundoffAbs=0;Vmin=V;Vmax=V;Emin=E;Emax=E;
chargeSource=0;chargeDemand=0;dischargeRegen=0;capRejected=0;emptyRejected=0;maxIter=0;
if keep,log=zeros(numel(G.h)+1,7);log(1,:)=[0 V E 0 0 0 0];else,log=[];end
for k=1:numel(G.h)
 if G.controlID(k)~=controlID
  controlID=G.controlID(k);
  [cmd,extra]=scheduleCommand(controller,V,E,G.p(k),e,f,horizons,F.Schedule_kWh(controlID,:),F.Preview_kWh(controlID,:));
  overrideTicks=overrideTicks+double(extra>1e-8);
 end
 remain=G.h(k);baseh=remain;pfIntegral=0;chIntegral=0;srcIntegral=0;
 overrideDuration=overrideDuration+baseh*double(extra>1e-8);
 extraCommandProxy=extraCommandProxy+extra*baseh/3.6e6;
 while remain>0
  h=remain;pf=cmd;
  % Exact storage-boundary event timing; no power smearing over a whole step.
  if pf>0
   if f.capacity_kWh-E<=e.StateTol_kWh,pf=0;
   else,h=min(h,(f.capacity_kWh-E)*3.6e6/(f.etaC*pf));end
  elseif pf<0
   if E<=e.StateTol_kWh,pf=0;
   else,h=min(h,E*f.etaD*3.6e6/(-pf));end
  end
  assert(h>0,'Nonpositive storage event interval.');
  [vn,ig,ch,res,it,ok]=advanceVoltage(V,G.p(k)+pf,h,e);
  assert(ok,'DC solve left diagnostic domain or failed at t=%.9f. No voltage clamp applied.',G.t(k)+baseh-remain);
  vm=(V+vn)/2;src=e.Vsource*ig;bus=vm*ig;line=e.Rsource*ig^2;
  pc=max(pf,0);pd=max(-pf,0);loss=(1-f.etaC)*pc+(1/f.etaD-1)*pd;
  trial=E+(f.etaC*pc-pd/f.etaD)*h/3.6e6;
  assert(trial>=-e.StateTol_kWh && trial<=f.capacity_kWh+e.StateTol_kWh);
  en=min(max(trial,0),f.capacity_kWh);roundoffAbs=roundoffAbs+abs(en-trial);
  q=q+h*[src,bus,line,ch,pc,pd,loss,G.p(k)];rootAbs=rootAbs+abs(res);maxIter=max(maxIter,it);
  chargeSource=chargeSource+h*pc*(ig>1e-9);chargeDemand=chargeDemand+h*pc*(G.p(k)>0);
  dischargeRegen=dischargeRegen+h*pd*(G.p(k)<0);
  capRejected=capRejected+h*max(cmd-pf,0)*(cmd>0);
  emptyRejected=emptyRejected+h*max(pf-cmd,0)*(cmd<0);
  pfIntegral=pfIntegral+h*pf;chIntegral=chIntegral+h*ch;srcIntegral=srcIntegral+h*src;
  E=en;V=vn;Emin=min(Emin,E);Emax=max(Emax,E);Vmin=min(Vmin,V);Vmax=max(Vmax,V);
  remain=remain-h;
 end
 if keep,log(k+1,:)=[G.t(k)+baseh,V,E,pfIntegral/baseh,chIntegral/baseh,srcIntegral/baseh,G.p(k)];end
end
q=q/3.6e6;cap0=.5*e.Cdc*e.Vinitial^2/3.6e6;cap1=.5*e.Cdc*V^2/3.6e6;
r=struct('Source_kWh',q(1),'SourceToBus_kWh',q(2),'SourceResistanceLoss_kWh',q(3), ...
 'Chopper_kWh',q(4),'ChargeBus_kWh',q(5),'DischargeBus_kWh',q(6), ...
 'ConversionLoss_kWh',q(7),'NetTrain_kWh',q(8),'InitialStored_kWh',E0, ...
 'FinalStored_kWh',E,'MinStored_kWh',Emin,'MaxStored_kWh',Emax, ...
 'InitialCapacitor_kWh',cap0,'FinalCapacitor_kWh',cap1,'DeltaCapacitor_kWh',cap1-cap0, ...
 'Vmin_V',Vmin,'Vmax_V',Vmax,'FinalVoltage_V',V,'RootResidualAbs_kWh',rootAbs/3.6e6, ...
 'StateRoundoffAbs_kWh',roundoffAbs,'MaxRootIterations',maxIter, ...
 'ChargeWhileSourceOn_kWh',chargeSource/3.6e6,'ChargeDuringNetDemand_kWh',chargeDemand/3.6e6, ...
 'DischargeDuringNetRegen_kWh',dischargeRegen/3.6e6, ...
 'CapacityRejectedCommand_kWh',capRejected/3.6e6,'EmptyRejectedCommand_kWh',emptyRejected/3.6e6);
r.WrapperOverrideTicks=overrideTicks;
r.WrapperOverrideRequestDuration_s=overrideDuration;
r.WrapperExtraCommandProxy_kWh=extraCommandProxy;
r.SourceSplitResidual_kWh=q(1)-q(2)-q(3);
r.StorageResidual_kWh=E-E0-f.etaC*q(5)+q(6)/f.etaD;
r.BusResidual_kWh=q(2)-q(8)-q(4)-q(5)+q(6)-(cap1-cap0);
r.SystemResidual_kWh=q(1)-q(8)-q(4)-q(3)-q(7)-(E-E0)-(cap1-cap0);
assert(max(abs([r.SourceSplitResidual_kWh,r.StorageResidual_kWh,r.BusResidual_kWh, ...
 r.SystemResidual_kWh,r.RootResidualAbs_kWh,r.StateRoundoffAbs_kWh]))<e.BalanceTol_kWh, ...
 'Electrical/storage energy bookkeeping failed.');
if keep,T=array2table(log,'VariableNames',{'Time_s','Voltage_V','Stored_kWh', ...
 'PreviousIntervalFESS_W','PreviousIntervalChopper_W','PreviousIntervalSource_W','PreviousIntervalTrain_W'});
else,T=table;end
end

function G=tailGrid(finish,dt,tc)
controlEdges=(0:ceil(finish/tc)+1)'*tc;
edges=unique([(0:floor(finish/dt))'*dt;controlEdges(controlEdges<finish);finish]);
t=edges(1:end-1);h=diff(edges);ci=discretize(t,controlEdges);
assert(all(h>0)&all(isfinite(ci)) && abs(sum(h)-finish)<1e-8);
G=struct('t',t,'h',h,'controlID',ci);
end

function r=runTail(b,G,e,f,tail)
Estart=b.FinalStored_kWh;Vstart=b.FinalVoltage_V;target=b.InitialStored_kWh;
assert(Estart>=-e.StateTol_kWh && Estart<=f.capacity_kWh+e.StateTol_kWh);
E=Estart;V=Vstart;cmd=0;controlID=0;
q=zeros(1,8);rootAbs=0;roundoffAbs=0;maxIter=0;restoreEnd=NaN;
if abs(E-target)<=e.StateTol_kWh,restoreEnd=0;end
Vmin=V;Vmax=V;
for k=1:numel(G.h)
 if G.controlID(k)~=controlID
  controlID=G.controlID(k);
  if target-E>e.StateTol_kWh,cmd=tail.RestorePower_W;
  elseif E-target>e.StateTol_kWh,cmd=-tail.RestorePower_W;
  else,cmd=0;end
 end
 remain=G.h(k);baseh=remain;
 while remain>0
  h=remain;pf=cmd;
  if pf>0
   if target-E<=e.StateTol_kWh,pf=0;
   else,h=min(h,(target-E)*3.6e6/(f.etaC*pf));end
  elseif pf<0
   if E-target<=e.StateTol_kWh,pf=0;
   else,h=min(h,(E-target)*f.etaD*3.6e6/(-pf));end
  end
  assert(h>0,'Nonpositive target-event interval.');
  [vn,ig,ch,res,it,ok]=advanceVoltage(V,tail.Load_W+pf,h,e);
  assert(ok,'Tail DC solver failed or left the diagnostic voltage domain.');
  vm=(V+vn)/2;pc=max(pf,0);pd=max(-pf,0);
  loss=(1-f.etaC)*pc+(1/f.etaD-1)*pd;
  trial=E+(f.etaC*pc-pd/f.etaD)*h/3.6e6;
  assert(trial>=-e.StateTol_kWh && trial<=f.capacity_kWh+e.StateTol_kWh);
  en=trial;
  if pf~=0 && abs(trial-target)<=e.StateTol_kWh
   en=target;roundoffAbs=roundoffAbs+abs(en-trial);
   if isnan(restoreEnd),restoreEnd=G.t(k)+baseh-remain+h;end
  end
  q=q+h*[e.Vsource*ig,vm*ig,e.Rsource*ig^2,ch,pc,pd,loss,tail.Load_W];
  rootAbs=rootAbs+abs(res);maxIter=max(maxIter,it);
  E=en;V=vn;Vmin=min(Vmin,V);Vmax=max(Vmax,V);remain=remain-h;
 end
end
q=q/3.6e6;cap0=.5*e.Cdc*Vstart^2/3.6e6;cap1=.5*e.Cdc*V^2/3.6e6;
r=struct('OriginalSource_kWh',b.Source_kWh,'OriginalDissipation_kWh', ...
 b.SourceResistanceLoss_kWh+b.Chopper_kWh+b.ConversionLoss_kWh, ...
 'OriginalTerminalStored_kWh',Estart,'OriginalTerminalVoltage_V',Vstart, ...
 'TargetStored_kWh',target,'TailSource_kWh',q(1),'TailSourceToBus_kWh',q(2), ...
 'TailSourceResistanceLoss_kWh',q(3),'TailChopper_kWh',q(4), ...
 'TailChargeBus_kWh',q(5),'TailDischargeBus_kWh',q(6),'TailConversionLoss_kWh',q(7), ...
 'TailLoad_kWh',q(8),'TailStoredChange_kWh',E-Estart,'TailCapacitorChange_kWh',cap1-cap0, ...
 'FinalStored_kWh',E,'FinalVoltage_V',V,'FinalCapacitor_kWh',cap1, ...
 'TailVmin_V',Vmin,'TailVmax_V',Vmax,'RestorationEnd_s',restoreEnd, ...
 'TailRootResidualAbs_kWh',rootAbs/3.6e6,'TailRoundoffAbs_kWh',roundoffAbs, ...
 'MaxRootIterations',maxIter);
r.TailSourceSplitResidual_kWh=q(1)-q(2)-q(3);
r.TailStorageResidual_kWh=E-Estart-f.etaC*q(5)+q(6)/f.etaD;
r.TailBusResidual_kWh=q(2)-q(8)-q(4)-q(5)+q(6)-(cap1-cap0);
r.TailSystemResidual_kWh=q(1)-q(8)-q(3)-q(4)-q(7)-(E-Estart)-(cap1-cap0);
r.RestoreChargeError_kWh=q(5)-max(target-Estart,0)/f.etaC;
r.RestoreDischargeError_kWh=q(6)-f.etaD*max(Estart-target,0);
r.CombinedSource_kWh=b.Source_kWh+q(1);
r.CombinedDissipation_kWh=r.OriginalDissipation_kWh+q(3)+q(4)+q(7);
r.CombinedSystemResidual_kWh=r.CombinedSource_kWh-b.NetTrain_kWh-q(8) ...
 -r.CombinedDissipation_kWh-(E-b.InitialStored_kWh)-(cap1-b.InitialCapacitor_kWh);
r.FinalStorageError_kWh=E-target;r.FinalVoltageError_V=V-tail.SteadyVoltage_V;
residuals=[r.TailSourceSplitResidual_kWh,r.TailStorageResidual_kWh, ...
 r.TailBusResidual_kWh,r.TailSystemResidual_kWh,r.CombinedSystemResidual_kWh, ...
 r.TailRootResidualAbs_kWh,r.TailRoundoffAbs_kWh];
r.Comparable=abs(r.FinalStorageError_kWh)<=tail.StorageTargetTol_kWh ...
 && abs(r.FinalVoltageError_V)<=tail.FinalVoltageTol_V ...
 && all(abs(residuals)<e.BalanceTol_kWh) ...
 && abs(r.RestoreChargeError_kWh)<tail.StorageTargetTol_kWh ...
 && abs(r.RestoreDischargeError_kWh)<tail.StorageTargetTol_kWh ...
 && isfinite(restoreEnd) && restoreEnd<=tail.Duration_s-20+1e-8;
end

function [v1,ig,ch,res,it,ok]=advanceVoltage(v0,load_W,h,e)
% Discrete-gradient capacitor energy balance. Midpoint source/chopper powers
% use exactly the same voltage as the energy ledger. No voltage hard clamp.
lo=e.DomainLow_V;hi=e.DomainHigh_V;
fl=rootResidual(lo,v0,load_W,h,e);fh=rootResidual(hi,v0,load_W,h,e);
v1=NaN;ig=NaN;ch=NaN;res=NaN;it=0;ok=false;
if fl>0 || fh<0,return;end
x=v0;
for it=1:40
 [fx,df,ix,cx]=rootResidual(x,v0,load_W,h,e);
 if abs(fx)<=e.RootEnergyTol_J
  v1=x;ig=ix;ch=cx;res=fx;ok=true;return;
 end
 if fx>0,hi=x;else,lo=x;end
 candidate=x-fx/df;
 if ~isfinite(candidate)||candidate<=lo||candidate>=hi,candidate=(lo+hi)/2;end
 x=candidate;
end
end

function [r,dr,ig,ch]=rootResidual(v1,v0,load_W,h,e)
vm=(v0+v1)/2;ig=max((e.Vsource-vm)/e.Rsource,0);
excess=max(vm-e.ChopperOn_V,0);ch=min(e.ChopperGain_WpV*excess,e.ChopperMax_W);
ds=0;if vm<e.Vsource,ds=(e.Vsource-2*vm)/e.Rsource;end
dc=0;if vm>e.ChopperOn_V && e.ChopperGain_WpV*excess<e.ChopperMax_W,dc=e.ChopperGain_WpV;end
r=.5*e.Cdc*(v1-v0)*(v1+v0)-h*(vm*ig-load_W-ch);
dr=e.Cdc*v1-h*(ds-dc)/2;
end
