function FYP_DCSchedule_v1(inputFolder)
% FROZEN 7-CASE SCHEDULE-ONLY FORECAST DIAGNOSTIC.
% Four policies: VoltageReactive, FixedReserve, SchedulePreview, PerfectPreview.
% SchedulePreview uses ONLY a nominal plan frozen before actual cases and
% the clock. Actual current power/voltage/SOC enter the common execution rule.
% PerfectPreview is a feasible heuristic, not an optimum bound, and need not
% outperform causal policies.
% The nominal plan is never corrected with actual mass, offset, future power
% or actual episode end. PerfectPreview explicitly receives actual future.
% This synthetic developmental grid is not held-out data or field validation.
% Controller, train/DC physics and the common test continuation are inherited.
if nargin<1 || isempty(inputFolder)
 D=dir('FYP_DCPreview_v1_Output_*');D=D([D.isdir]);
 assert(~isempty(D),'Place this file next to the previous Preview output folder, or supply its path.');
 [~,order]=sort({D.name});D=D(order);inputFolder=fullfile(D(end).folder,D(end).name);
end
A=load(fullfile(inputFolder,'PreviewSettings.mat'),'config');previous=A.config;
Native=readtable(fullfile(inputFolder,'PreviewOriginalMetrics.csv'));
e=previous.Electrical;f=previous.Storage;
assert(isfield(previous,'OriginalConfig')&&isfield(previous.OriginalConfig,'BaselineSettings'), ...
 'PreviewSettings must retain its original DC configuration and BaselineSettings.');
trainConfig=previous.OriginalConfig.BaselineSettings;
assert(isfield(trainConfig,'Train')&&isfield(trainConfig,'Route'),'Inherited train/route configuration is missing.');
p=trainConfig.Train;route=trainConfig.Route;validateConfiguration(Native,e,f,p,route);
dts=[.00125 .000625];soc0s=[.55 .85];horizons=[5 10 15 20];trainDT=.0025;
masses=[.95 1 1.05];names={'VoltageReactive','FixedReserve','SchedulePreview','PerfectPreview'};
Cases=array2table([0 1 1 35;1 .95 1.05 32.5;2 .95 1.05 37.5;3 1.05 .95 32.5; ...
 4 1.05 .95 37.5;5 1 1 32.5;6 1 1 37.5], ...
 'VariableNames',{'CaseID','MassFactorA','MassFactorB','ActualOffset_s'});
Cases.Role=["Nominal implementation check";repmat("Developmental mismatch",6,1)];
tail=previous.Tail;
assert(tail.Load_W==200e3&&tail.RestorePower_W==100e3&&tail.Duration_s==194);
assert(tail.StorageTargetTol_kWh==1e-8&&tail.FinalVoltageTol_V==1e-6 ...
 &&tail.StepEnergyTol_kWh==.005&&tail.StepVoltageTol_V==.1);
tol=struct('energy_kWh',1e-8,'power_W',1e-5,'state_kWh',1e-10);
out=['FYP_DCSchedule_v1_Output_' datestr(now,'yyyymmdd_HHMMSS_FFF')];mkdir(out);
config=struct('PreviousPreviewFolder',inputFolder,'PreviousConfig',previous, ...
 'Electrical',e,'Storage',f,'Train',p,'Route',route,'Train_dt_s',trainDT, ...
 'DC_dt_s',dts,'SOC0',soc0s,'Horizons_s',horizons,'Controllers',{names}, ...
 'Cases',Cases,'Tail',tail,'MATLABVersion',version, ...
 'Scope','Frozen developmental 7-case grid; fixed schedule; no statistical independence claim');
save(fullfile(out,'ScheduleSettings.mat'),'config');
writetable(Cases,fullfile(out,'CaseDefinitions.csv'));
copyfile([mfilename('fullpath') '.m'],fullfile(out,'SourceSnapshot.m'));

% Nominal plan is generated and SAVED before any actual mismatch profile.
fprintf('Generating nominal plan first: masses 1/1, offset 35 s.\n');
[NominalTrain,NominalTrainPlan,NominalStationChecks,nominalCheck]=checkedTrain(p,route,trainDT,1);
[NominalNode,nominalNodeCheck]=mergeNode(NominalTrain,NominalTrain,35,tol);
plan=makeOpportunityModel(NominalNode,e,f);
plan.NominalMassFactors=[1 1];plan.NominalOffset_s=35;plan.Train_dt_s=trainDT;
plan.InformationBoundary='Fixed nominal plan and clock only; no actual case arguments';
save(fullfile(out,'NominalPlan.mat'),'plan','NominalNode','NominalTrainPlan','NominalStationChecks');
planTimes=(0:ceil((plan.Finish_s+2*max(horizons))/e.ControlPeriod_s))'*e.ControlPeriod_s;
planSamples=planReserve(plan,planTimes,horizons);
writetable(array2table([planTimes planSamples],'VariableNames', ...
 {'Time_s','Plan5_kWh','Plan10_kWh','Plan15_kWh','Plan20_kWh'}),fullfile(out,'PlanReserveSamples.csv'));
fprintf('NominalPlan.mat saved; generating actual physical cases only now.\n');

trains=cell(3,1);trains{2}=NominalTrain;trainRows=cell(3,1);trainRows{2}=nominalCheck;
stops=cell(3,1);stops{2}=NominalStationChecks;
for k=[1 3]
 [trains{k},~,stops{k},trainRows{k}]=checkedTrain(p,route,trainDT,masses(k));
end
TrainChecks=struct2table(vertcat(trainRows{:}));StationChecks=vertcat(stops{:});
writetable(TrainChecks,fullfile(out,'TrainChecks.csv'));writetable(StationChecks,fullfile(out,'StationChecks.csv'));
nc=numel(names);ns=numel(soc0s);nd=numel(dts);ncase=height(Cases);
grids=cell(ncase,nd);signals=cell(ncase,1);nodeRows=cell(ncase,1);planRows=cell(ncase,1);
for k=1:ncase
 ia=find(abs(masses-Cases.MassFactorA(k))<1e-12,1);ib=find(abs(masses-Cases.MassFactorB(k))<1e-12,1);
 [N,nr]=mergeNode(trains{ia},trains{ib},Cases.ActualOffset_s(k),tol);
 nr.CaseID=Cases.CaseID(k);nodeRows{k}=nr;
 save(fullfile(out,sprintf('Case%02d_Input.mat',Cases.CaseID(k))),'N');
 finish=N.Time_s(end)+N.Step_s(end);
 t=(0:ceil(finish/e.ControlPeriod_s))'*e.ControlPeriod_s;t=t(t<finish);
 % ONLY t and the already-saved nominal plan enter this forecast.
 scheduled=planReserve(plan,t,horizons);
 truth=makeOpportunityModel(N,e,f);oracle=truthReserve(truth,t,horizons);
 signals{k}=struct('Time_s',t,'Schedule_kWh',scheduled,'Preview_kWh',oracle);
 for d=1:nd,grids{k,d}=eventGrid(N,dts(d),e.ControlPeriod_s);end
 % Every common clock query must equal the pre-case plan table. For this
 % declared grid all actual control ticks lie inside that fixed query range.
 assert(numel(t)<=numel(planTimes)&&max(abs(t-planTimes(1:numel(t))))<1e-12);
 deviation=max(abs(scheduled-planSamples(1:numel(t),:)),[],'all');
 r=struct('CaseID',Cases.CaseID(k),'ActualEpisodeDuration_s',finish,'PlanDuration_s',plan.Finish_s, ...
  'MaxPlanSignalDeviationAtSameClock_kWh',deviation,'InvarianceTolerance_kWh',1e-12, ...
  'PlanSignalInvariant',deviation<=1e-12,'MeanAbsOpportunityError_kWh',mean(abs(scheduled-oracle),'all'), ...
  'MaxAbsOpportunityError_kWh',max(abs(scheduled-oracle),[],'all'));
 planRows{k}=r;
 writetable(array2table([t oracle],'VariableNames',{'Time_s','Oracle5_kWh','Oracle10_kWh','Oracle15_kWh','Oracle20_kWh'}), ...
  fullfile(out,sprintf('Case%02d_OracleReserve.csv',Cases.CaseID(k))));
 fprintf('Prepared physical Case %d.\n',Cases.CaseID(k));
end
PlanChecks=struct2table(vertcat(planRows{:}));NodeChecks=struct2table(vertcat(nodeRows{:}));
assert(all(PlanChecks.PlanSignalInvariant),'Schedule signal depends on the actual case.');
writetable(PlanChecks,fullfile(out,'PlanInputChecks.csv'));writetable(NodeChecks,fullfile(out,'NodeChecks.csv'));
PolicyChecks=schedulePolicyChecks(e,f,horizons);writetable(PolicyChecks,fullfile(out,'PolicyChecks.csv'));
tailGrids=cell(nd,1);for d=1:nd,tailGrids{d}=tailGrid(tail.Duration_s,dts(d),e.ControlPeriod_s);end
parallelOK=false;
if license('test','Distrib_Computing_Toolbox')
 try
  pool=gcp('nocreate');if isempty(pool),pool=parpool('threads');end
  parallelOK=true;fprintf('Parallel independent jobs: %d workers.\n',pool.NumWorkers);
 catch ME
  warning('FYP:SerialFallback','Using serial execution: %s',ME.message);
 end
end
jobs=ncase*nd*ns*nc;originalRows=cell(jobs,1);terminalRows=cell(jobs,1);traces=cell(jobs,1);
if parallelOK
 parfor job=1:jobs
  [originalRows{job},terminalRows{job},traces{job}]=scheduleJob(job,Cases,grids,tailGrids,signals,e,f,tail,dts,soc0s,names,horizons);
 end
else
 for job=1:jobs
  [originalRows{job},terminalRows{job},traces{job}]=scheduleJob(job,Cases,grids,tailGrids,signals,e,f,tail,dts,soc0s,names,horizons);
 end
end
Original=struct2table(vertcat(originalRows{:}));Terminal=struct2table(vertcat(terminalRows{:}));
BaselineChecks=nominalRegression(Original,Native);NominalChecks=nominalEquivalence(Original,Terminal);
implementationPass=all(BaselineChecks.Pass)&&all(NominalChecks.Pass)&&all(PlanChecks.PlanSignalInvariant);
Terminal.ImplementationChecksPass=repmat(implementationPass,height(Terminal),1);
Summary=Terminal;Summary.OriginalVmin_V=Original.Vmin_V;Summary.OriginalVmax_V=Original.Vmax_V;
Summary.WrapperOverrideTicks=Original.WrapperOverrideTicks;
Summary.WrapperOverrideRequestDuration_s=Original.WrapperOverrideRequestDuration_s;
Summary.WrapperExtraCommandProxy_kWh=Original.WrapperExtraCommandProxy_kWh;
Paired=casePairs(Summary,names,dts,soc0s,Cases,tail);
StepChecks=caseStepChecks(Original,Terminal,names,dts,soc0s,Cases,tail);
PairedStepChecks=casePairedSteps(Paired,dts,tail.StepEnergyTol_kWh,e.BalanceTol_kWh);
writetable(Original,fullfile(out,'ScheduleOriginalMetrics.csv'));
writetable(Terminal,fullfile(out,'ScheduleTerminalMetrics.csv'));
writetable(Summary,fullfile(out,'ScheduleSummary.csv'));
writetable(Paired,fullfile(out,'SchedulePaired.csv'));
writetable(StepChecks,fullfile(out,'ScheduleStepChecks.csv'));
writetable(PairedStepChecks,fullfile(out,'SchedulePairedStepChecks.csv'));
writetable(BaselineChecks,fullfile(out,'ScheduleBaselineChecks.csv'));
writetable(NominalChecks,fullfile(out,'NominalScheduleChecks.csv'));
representative=traces(ns*nc+(1:nc));save(fullfile(out,'ScheduleRepresentative.mat'),'representative');
plotSchedule(Paired,names,Cases,dts(end),fullfile(out,'ScheduleChecks.png'));
reviewFiles={'ScheduleOriginalMetrics.csv','ScheduleTerminalMetrics.csv','ScheduleSummary.csv', ...
 'SchedulePaired.csv','ScheduleStepChecks.csv','SchedulePairedStepChecks.csv', ...
 'ScheduleBaselineChecks.csv','NominalScheduleChecks.csv','PlanInputChecks.csv', ...
 'TrainChecks.csv','StationChecks.csv','NodeChecks.csv','PolicyChecks.csv','CaseDefinitions.csv', ...
 'ScheduleChecks.png','ScheduleSettings.mat','SourceSnapshot.m'};
zipPath=fullfile(pwd,out,'ScheduleReview.zip');
zip(zipPath,reviewFiles,out); % Relative entries under out; no raw traces or giant signals included.

fprintf('\nFrozen schedule test: %d jobs; %d within-case pairs.\n',jobs,height(Paired));
fprintf('Native nominal regression failures: %d / %d; nominal schedule/oracle failures: %d / %d.\n', ...
 sum(~BaselineChecks.Pass),height(BaselineChecks),sum(~NominalChecks.Pass),height(NominalChecks));
fprintf('Terminal failures: %d / %d; individual step failures: %d / %d; paired step failures: %d / %d.\n', ...
 sum(~Terminal.Comparable),height(Terminal),sum(~StepChecks.Pass),height(StepChecks), ...
 sum(~PairedStepChecks.StepTolerancePass),height(PairedStepChecks));
disp(Paired(Paired.dt_s==dts(end)&string(Paired.ReferenceController)=="VoltageReactive" ...
 &string(Paired.TestController)=="SchedulePreview",{'CaseID','SOC0','CombinedSourceSaving_kWh','Comparable'}));
fprintf('Outputs: %s\n',out);
fprintf('Send ScheduleReview.zip and the final console summary.\n');
fprintf('Review packet: %s\n',zipPath);
fprintf('Negative effects are retained. This is a developmental grid, not a reliability or field study.\n');
if ~implementationPass,warning('FYP:ImplementationGate','Implementation checks failed; paired energy results are NaN.');end
end

function [r,z,T]=scheduleJob(job,Cases,grids,tailGrids,signals,e,f,tail,dts,socs,names,horizons)
nc=numel(names);ns=numel(socs);nd=numel(dts);
k=floor((job-1)/(nd*ns*nc))+1;within=mod(job-1,nd*ns*nc);
d=floor(within/(ns*nc))+1;s=floor(mod(within,ns*nc)/nc)+1;c=mod(within,nc);
keep=k==1&&d==nd&&s==1;
[r,T]=simulateSchedule(grids{k,d},e,f,socs(s),c,signals{k},horizons,keep);
z=runTail(r,tailGrids{d},e,f,tail);
r.Controller=names{c+1};r.SOC0=socs(s);r.dt_s=dts(d);r.CaseID=Cases.CaseID(k);
r.MassFactorA=Cases.MassFactorA(k);r.MassFactorB=Cases.MassFactorB(k);r.ActualOffset_s=Cases.ActualOffset_s(k);
z.Controller=names{c+1};z.SOC0=socs(s);z.dt_s=dts(d);z.CaseID=Cases.CaseID(k);
z.MassFactorA=Cases.MassFactorA(k);z.MassFactorB=Cases.MassFactorB(k);z.ActualOffset_s=Cases.ActualOffset_s(k);
fprintf('Case %d: %s, SOC0=%.2f, dt=%.6f complete.\n',Cases.CaseID(k),names{c+1},socs(s),dts(d));
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

function reserve=truthReserve(truth,t,horizons)
% Privileged ACTUAL-future input, permitted only for the oracle diagnostic.
I=@(q)interp1(truth.Edges_s,truth.Cumulative_kWh,min(max(q,0),truth.Finish_s),'linear');
reserve=min(truth.Band_kWh,max(I(t+horizons)-I(t),0));
end

function [T,P,S,r]=checkedTrain(p,route,dt,massFactor)
p.mass=p.mass*massFactor;[T,P,S]=simulateFixedRoute(p,route,dt);r=summarizeV2(T,p);
r.MassFactor=massFactor;r.Train_dt_s=dt;r.MaxStationError_m=max(abs(S.StopPositionError_m));
r.MaxStopSpeed_mps=max(abs(S.StopSpeed_mps));
r.Pass=r.MaxStationError_m<1e-6&&r.MaxStopSpeed_mps<1e-8 ...
 &&abs(r.Distance_m-sum(route(:,1)))<1e-6&&r.MaxBusLimitExcess_W<=1e-5 ...
 &&r.MaxAbsIntervalBalance_kWh<1e-8&&abs(r.CumulativeBalance_kWh)<1e-8 ...
 &&r.MinSpeed_mps>=-1e-10&&r.MaxSpeedCommandExcess_mps<=1e-8&&r.MaxKinematicResidual_m<1e-8;
assert(r.Pass,'Inherited train model checks failed for mass factor %.2f.',massFactor);
S.MassFactor=repmat(massFactor,height(S),1);S.Train_dt_s=repmat(dt,height(S),1);
end

function validateConfiguration(O,e,f,p,route)
assert(height(O)==24,'Expected the frozen four-controller Preview metrics (24 records).');
assert(e.Vsource==750&&e.Rsource==.02&&e.Cdc==1.5&&e.Vinitial==750&&e.ControlPeriod_s==.01);
assert(e.ChopperOn_V==900&&e.ChopperGain_WpV==250e3&&e.ChopperMax_W==4e6);
assert(e.DomainLow_V==450&&e.DomainHigh_V==1100&&e.ChargeThreshold_V==800&&e.DischargeThreshold_V==710);
assert(e.SOCShift_V==35&&e.ControlGain_WpV==90e3&&e.SOClow==.02&&e.SOChigh==.98&&e.SOCtaper==.05);
assert(e.BalanceTol_kWh==1e-6&&e.StateTol_kWh==1e-10&&e.RootEnergyTol_J==1e-7);
assert(f.capacity_kWh==4.5&&f.maxCharge_W==1e6&&f.maxDischarge_W==1e6 ...
 &&abs(f.etaC-sqrt(.87))<1e-12&&abs(f.etaD-sqrt(.87))<1e-12);
assert(p.mass==203000&&p.g==9.81&&p.resA==1.2414&&p.resB==.0144&&p.resC==.000221 ...
 &&p.etaT==.9&&p.etaR==.9&&p.Paux==200e3&&p.PbusMax==3e6&&abs(p.vRegenMin-5/3.6)<1e-12);
assert(isequal(route,[850 70 1 1 18;1000 80 1 1 20;900 75 .9 1 22]));
required={'Source_kWh','NetTrain_kWh','SourceResistanceLoss_kWh','Chopper_kWh','ConversionLoss_kWh', ...
 'FinalStored_kWh','InitialStored_kWh','FinalCapacitor_kWh','InitialCapacitor_kWh','SystemResidual_kWh'};
assert(all(ismember(required,O.Properties.VariableNames))&&all(isfinite(O{:,required}),'all'));
r=O.Source_kWh-O.NetTrain_kWh-O.SourceResistanceLoss_kWh-O.Chopper_kWh-O.ConversionLoss_kWh ...
 -(O.FinalStored_kWh-O.InitialStored_kWh)-(O.FinalCapacitor_kWh-O.InitialCapacitor_kWh);
assert(max(abs(r))<e.BalanceTol_kWh&&max(abs(r-O.SystemResidual_kWh))<e.BalanceTol_kWh);
for dt=[.0025 .00125 .000625]
 for soc=[.55 .85]
  for name=["VoltageReactive","FixedReserve","HistoryReserve","PerfectPreview"]
   assert(sum(abs(O.dt_s-dt)<1e-12&abs(O.SOC0-soc)<1e-12&string(O.Controller)==name)==1);
  end
 end
end
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


function [N,R]=mergeNode(A,B,offset,tol)
ea=[A.Time_s;A.Time_s(end)+A.Step_s(end)];
eb=[B.Time_s;B.Time_s(end)+B.Step_s(end)]+offset;
e=unique([ea;eb]);h=diff(e);t=e(1:end-1);assert(all(h>0));
% Use interval LEFT edges, with final endpoint explicitly excluded. This
% avoids midpoint rounding into the next bin for nearly coincident edges.
a=lookupIntervals(t,ea,A.BusPower_W);b=lookupIntervals(t,eb,B.BusPower_W);
d=max(a,0)+max(b,0);r=max(-a,0)+max(-b,0);x=min(d,r);
N=table(t,h,a,b,d,r,x,'VariableNames',{'Time_s','Step_s','TrainA_W', ...
 'TrainB_W','GrossDemand_W','OfferedRegen_W','DirectExchange_W'});
energy=@(v)sum(v.*h)/3.6e6;
errors=[energy(max(a,0))-sum(max(A.BusPower_W,0).*A.Step_s)/3.6e6, ...
 energy(max(-a,0))-sum(max(-A.BusPower_W,0).*A.Step_s)/3.6e6, ...
 energy(max(b,0))-sum(max(B.BusPower_W,0).*B.Step_s)/3.6e6, ...
 energy(max(-b,0))-sum(max(-B.BusPower_W,0).*B.Step_s)/3.6e6];
R=struct('GrossDemand_kWh',energy(d),'OfferedRegen_kWh',energy(r), ...
 'DirectExchange_kWh',energy(x),'MaxAlignmentError_kWh',max(abs(errors)));
assert(R.MaxAlignmentError_kWh<tol.energy_kWh,'Time alignment changed train energy.');
end
function p=lookupIntervals(t,edges,values)
idx=discretize(t,edges);valid=~isnan(idx)&t>=edges(1)&t<edges(end);
p=zeros(size(t));p(valid)=values(idx(valid));
end

function [T,Plan,Stops]=simulateFixedRoute(p,route,dt)
K=size(route,1);cy=zeros(K,5);pr=zeros(K,7);
for k=1:K
 D=route(k,1);ceiling=route(k,2);acc=route(k,3);dec=route(k,4);dwell=route(k,5);
 pp=p;pp.cycles=[ceiling acc 0 dec 0];
 test=simulateTrainV2(pp,dt);minimalDistance=test.DistanceEnd_m(end);peak=ceiling;
 if minimalDistance>D
  % Choose reachable peak using the same power-limited dynamics and midpoint
  % distance integration as the final trace. No coordinate snapping at stops.
  lo=0;hi=ceiling;
  for j=1:40
   mid=(lo+hi)/2;pp.cycles=[mid acc 0 dec 0];test=simulateTrainV2(pp,dt);
   if test.DistanceEnd_m(end)>D,hi=mid;else,lo=mid;end
  end
  peak=lo;assert(peak>1e-6,'Route too short for this discrete model.');
  pp.cycles=[peak acc 0 dec 0];test=simulateTrainV2(pp,dt);
  minimalDistance=test.DistanceEnd_m(end);
 end
 cruiseDistance=D-minimalDistance;
 assert(cruiseDistance>=-1e-7,'Negative cruise distance from route planner.');
 cruiseDistance=max(cruiseDistance,0);
 cruiseTime=cruiseDistance/(peak/3.6);
 cy(k,:)=[peak acc cruiseTime dec dwell];
 pr(k,:)=[k D ceiling peak minimalDistance cruiseDistance cruiseTime];
end
p.cycles=cy;T=simulateTrainV2(p,dt);
Plan=array2table(pr,'VariableNames',{'Segment','Distance_m','SpeedCeiling_kmh', ...
 'PeakSpeed_kmh','AccelBrakeDistance_m','CruiseDistance_m','CruiseTime_s'});
sr=zeros(K,7);
for k=1:K
 G=T(T.Cycle==k,:);beforeDwell=G(G.Phase~=4,:);last=beforeDwell(end,:);
 expected=sum(route(1:k,1));
 sr(k,:)=[k expected last.DistanceEnd_m last.DistanceEnd_m-expected last.SpeedEnd_mps ...
   last.Time_s+last.Step_s G.Time_s(end)+G.Step_s(end)];
end
Stops=array2table(sr,'VariableNames',{'Segment','ExpectedStop_m','ActualStop_m', ...
 'StopPositionError_m','StopSpeed_mps','ArrivalTime_s','DepartureTime_s'});
end

function T=simulateTrainV2(p,dt)
% Every row is an interval, not a point sample. Final partial intervals retain h.
A=zeros(200000,21); n=0;t=0;x=0;v=0;
for cycle=1:size(p.cycles,1)
 target=p.cycles(cycle,1)/3.6; acc=p.cycles(cycle,2); dec=p.cycles(cycle,4);
 for phase=1:4
  rem=0;
  if phase==2, rem=p.cycles(cycle,3); elseif phase==4, rem=p.cycles(cycle,5); end
  phaseStart=t;
  while true
   if phase==1 && v>=target-1e-10, break; end
   if phase==3 && v<=1e-10, break; end
   if (phase==2 || phase==4) && rem<=1e-10, break; end
   assert(t-phaseStart<1000,'Phase cannot complete under available power.');
   h=dt; if phase==2 || phase==4, h=min(h,rem); end
   if phase==1
    vn=min(v+acc*h,target);
    mechLimit=p.etaT*(p.PbusMax-p.Paux);
    if tractionNeed(v,vn,h,p)>mechLimit
     % Solve next speed using midpoint mechanical power, so limited power
     % actually limits acceleration instead of just clipping a recorded load.
     lo=max(0,v-resistance(v,p)*h/p.mass); hi=vn;
     assert(tractionNeed(v,lo,h,p)<=mechLimit,'Traction solve not bracketed.');
     for z=1:50
      mid=(lo+hi)/2;
      if tractionNeed(v,mid,h,p)>mechLimit, hi=mid; else, lo=mid; end
     end
     vn=lo;
    end
   elseif phase==2
    vn=v;
   elseif phase==3
    h=min(h,v/dec); vn=max(v-dec*h,0);
   else
    vn=0;
   end
   vm=(v+vn)/2; R=resistance(vm,p);
   force=p.mass*(vn-v)/h+R;
   pt=max(force*vm,0); pb=max(-force*vm,0);
   assert(pt<=p.etaT*(p.PbusMax-p.Paux)+1e-5,'Cruise/traction requirement exceeds limit.');
   pe=0;
   if vm>=p.vRegenMin, pe=min(pb,(p.PbusMax+p.Paux)/p.etaR); end
   pm=pb-pe;
   bus=pt/p.etaT-p.etaR*pe+p.Paux;
   conv=pt*(1/p.etaT-1)+pe*(1-p.etaR);
   dKE=.5*p.mass*(vn^2-v^2);
   residual=bus*h-(dKE+(R*vm+pm+p.Paux+conv)*h);
   xn=x+vm*h; n=n+1; assert(n<=size(A,1),'Increase trace capacity explicitly.');
   A(n,:)=[t,h,cycle,phase,target,v,vn,x,xn,pt,pe,pm,R*vm,p.Paux,conv,bus,dKE,residual, ...
     (vn-v)/h,max(tractionNeed(v,min(v+acc*h,target),h,p)-p.etaT*(p.PbusMax-p.Paux),0)*(phase==1), ...
     abs((xn-x)-vm*h)];
   t=t+h;x=xn;v=vn;
   if phase==2 || phase==4, rem=rem-h; end
  end
 end
end
T=array2table(A(1:n,:),'VariableNames',{'Time_s','Step_s','Cycle','Phase', ...
 'TargetSpeed_mps','SpeedStart_mps','SpeedEnd_mps','DistanceStart_m','DistanceEnd_m', ...
 'TractionWheel_W','ElectricalBrakeWheel_W','MechanicalBrake_W','Resistance_W', ...
 'Auxiliary_W','ConversionLoss_W','BusPower_W','KineticChange_J','BalanceResidual_J', ...
 'Acceleration_mps2','RequestedPowerExcess_W','KinematicResidual_m'});
end
function R=resistance(v,p)
u=v*3.6; R=(p.resA+p.resB*u+p.resC*u^2)*p.mass*p.g/1000;
end
function P=tractionNeed(v,vn,h,p)
vm=(v+vn)/2;P=(p.mass*(vn-v)/h+resistance(vm,p))*vm;
end
function s=summarizeV2(T,p)
energy=@(v)sum(v.*T.Step_s)/3.6e6;
s=struct('Duration_s',sum(T.Step_s),'Distance_m',T.DistanceEnd_m(end), ...
 'NetBusEnergy_kWh',energy(T.BusPower_W),'Import_kWh',energy(max(T.BusPower_W,0)), ...
 'RegenExport_kWh',energy(max(-T.BusPower_W,0)), ...
 'MechanicalBrake_kWh',energy(T.MechanicalBrake_W),'Auxiliary_kWh',energy(T.Auxiliary_W), ...
 'ConversionLoss_kWh',energy(T.ConversionLoss_W),'Resistance_kWh',energy(T.Resistance_W), ...
 'MaxAbsIntervalBalance_kWh',max(abs(T.BalanceResidual_J))/3.6e6, ...
 'CumulativeBalance_kWh',sum(T.BalanceResidual_J)/3.6e6, ...
 'MaxBusLimitExcess_W',max(max(abs(T.BusPower_W)-p.PbusMax,0)), ...
 'MinSpeed_mps',min(T.SpeedEnd_mps),'MaxSpeedCommandExcess_mps',max(T.SpeedEnd_mps-T.TargetSpeed_mps), ...
 'MaxKinematicResidual_m',max(T.KinematicResidual_m), ...
 'PowerLimitedTime_s',sum(T.Step_s(T.RequestedPowerExcess_W>1e-5)));
end

function U=schedulePolicyChecks(e,f,horizons)
cap=f.capacity_kWh;band=(e.SOChigh-e.SOClow)*cap;full=repmat(band,size(horizons));zero=zeros(size(horizons));
err=zeros(9,1);
[a,~]=scheduleCommand(0,750,.55*cap,1e6,e,f,horizons,zero,zero);
[b,~]=scheduleCommand(2,750,.55*cap,1e6,e,f,horizons,zero,zero);err(1)=abs(a-b);
[a,~]=scheduleCommand(0,850,.55*cap,-1e6,e,f,horizons,zero,zero);
[b,~]=scheduleCommand(2,850,.55*cap,-1e6,e,f,horizons,full,full);err(2)=abs(a-b);
[a,~]=scheduleCommand(0,850,.55*cap,1e6,e,f,horizons,zero,zero);
[b,~]=scheduleCommand(2,850,.55*cap,1e6,e,f,horizons,full,full);err(3)=abs(a-b);
[a,~]=scheduleCommand(2,750,.55*cap,1e6,e,f,horizons,full,full);
want=-min([f.etaD*3.6e6*(.55-e.SOClow)*cap/min(horizons),f.maxDischarge_W,1e6]);err(4)=abs(a-want);
soc=e.SOClow+.5*e.SOCtaper;[a,~]=scheduleCommand(2,750,soc*cap,1e6,e,f,horizons,full,full);
want=-.5*min([f.etaD*3.6e6*(soc-e.SOClow)*cap/min(horizons),f.maxDischarge_W,1e6]);err(5)=abs(a-want);
[a,~]=scheduleCommand(2,750,e.SOClow*cap,1e6,e,f,horizons,full,full);err(6)=abs(a);
unit=f.etaC*1e6/3.6e6;
plan=struct('Edges_s',[0;2;5;6],'Cumulative_kWh',[0;0;3*unit;3*unit],'Finish_s',6,'Band_kWh',band);
q=planReserve(plan,[0;4;5;7],horizons);
err(7)=max(abs(q(1,:)-3*unit));err(8)=max(abs(q(2,:)-unit));err(9)=max(abs(q(3:4,:)),[],'all');
names=["Zero reserve leaves VR unchanged";"No wrapper override at regenerative sample"; ...
 "VR charge priority";"Internal kWh to bus W";"Single SOC taper";"Low SOC command zero"; ...
 "Plan future integral";"Plan remaining integral";"Zero planned regen outside plan"];
limits=[repmat(1e-7,6,1);repmat(1e-10,3,1)];units=[repmat("W",6,1);repmat("kWh",3,1)];
Pass=err<limits;U=table(names,err,limits,units,Pass,'VariableNames',{'Check','AbsoluteError','Tolerance','Unit','Pass'});
assert(all(Pass),'Schedule policy analytical fixture failed.');
end

function B=nominalRegression(M,O)
energy=O.Properties.VariableNames(endsWith(O.Properties.VariableNames,'_kWh'));
voltage=O.Properties.VariableNames(endsWith(O.Properties.VariableNames,'_V'));
assert(all(ismember([energy,voltage],M.Properties.VariableNames)));
rows=cell(12,1);n=0;
for dt=[.00125 .000625]
 for soc=[.55 .85]
  for name=["VoltageReactive","FixedReserve","PerfectPreview"]
   a=M(M.CaseID==0&abs(M.dt_s-dt)<1e-12&abs(M.SOC0-soc)<1e-12&string(M.Controller)==name,:);
   b=O(abs(O.dt_s-dt)<1e-12&abs(O.SOC0-soc)<1e-12&string(O.Controller)==name,:);
   assert(height(a)==1&&height(b)==1);
   [ee,ie]=max(abs(a{1,energy}-b{1,energy}));[vv,iv]=max(abs(a{1,voltage}-b{1,voltage}));
   r=struct('Controller',name,'dt_s',dt,'SOC0',soc,'MaxEnergyDifference_kWh',ee, ...
    'WorstEnergyField',energy{ie},'MaxVoltageDifference_V',vv,'WorstVoltageField',voltage{iv}, ...
    'EnergyTolerance_kWh',1e-6,'VoltageTolerance_V',1e-5,'Pass',ee<=1e-6&&vv<=1e-5);
   n=n+1;rows{n}=r;
  end
 end
end
B=struct2table(vertcat(rows{:}));
end

function B=nominalEquivalence(O,T)
energy=O.Properties.VariableNames(endsWith(O.Properties.VariableNames,'_kWh'));
voltage=O.Properties.VariableNames(endsWith(O.Properties.VariableNames,'_V'));
rows=cell(4,1);n=0;
for dt=[.00125 .000625]
 for soc=[.55 .85]
  ia=O.CaseID==0&abs(O.dt_s-dt)<1e-12&abs(O.SOC0-soc)<1e-12&string(O.Controller)=="SchedulePreview";
  ib=O.CaseID==0&abs(O.dt_s-dt)<1e-12&abs(O.SOC0-soc)<1e-12&string(O.Controller)=="PerfectPreview";
  assert(sum(ia)==1&&sum(ib)==1);a=O(ia,:);b=O(ib,:);ta=T(ia,:);tb=T(ib,:);
  ee=max([abs(a{1,energy}-b{1,energy}),abs(ta.CombinedSource_kWh-tb.CombinedSource_kWh)]);
  vv=max(abs(a{1,voltage}-b{1,voltage}));
  r=struct('dt_s',dt,'SOC0',soc,'MaxEnergyDifference_kWh',ee,'MaxVoltageDifference_V',vv, ...
   'EnergyTolerance_kWh',1e-6,'VoltageTolerance_V',1e-5,'Pass', ...
   ee<=1e-6&&vv<=1e-5&&ta.Comparable&&tb.Comparable);
  n=n+1;rows{n}=r;
 end
end
B=struct2table(vertcat(rows{:}));
end

function P=casePairs(M,names,dts,socs,Cases,tail)
pairs=nchoosek(1:numel(names),2);rows=cell(168,1);n=0;
for id=Cases.CaseID'
 for dt=dts
  for soc=socs
   for j=1:size(pairs,1)
    a=M(M.CaseID==id&abs(M.dt_s-dt)<1e-12&abs(M.SOC0-soc)<1e-12&string(M.Controller)==names{pairs(j,1)},:);
    b=M(M.CaseID==id&abs(M.dt_s-dt)<1e-12&abs(M.SOC0-soc)<1e-12&string(M.Controller)==names{pairs(j,2)},:);
    assert(height(a)==1&&height(b)==1);
    assert(abs(a.TargetStored_kWh-b.TargetStored_kWh)<1e-12&&abs(a.TailLoad_kWh-b.TailLoad_kWh)<1e-8);
    valid=a.Comparable&&b.Comparable&&a.ImplementationChecksPass&&b.ImplementationChecksPass ...
     &&abs(a.FinalStored_kWh-b.FinalStored_kWh)<=2*tail.StorageTargetTol_kWh ...
     &&abs(a.FinalVoltage_V-b.FinalVoltage_V)<=2*tail.FinalVoltageTol_V;
    r=struct('CaseID',id,'dt_s',dt,'SOC0',soc,'ReferenceController',names{pairs(j,1)}, ...
     'TestController',names{pairs(j,2)},'Comparable',valid, ...
     'OriginalSourceSaving_kWh',a.OriginalSource_kWh-b.OriginalSource_kWh,'TailSourceSaving_kWh',NaN, ...
     'CombinedSourceSaving_kWh',NaN,'CombinedDissipationSaving_kWh',NaN, ...
     'SourceVsDissipationDifference_kWh',NaN, ...
     'FinalStoredDifference_kWh',b.FinalStored_kWh-a.FinalStored_kWh, ...
     'FinalCapacitorDifference_kWh',b.FinalCapacitor_kWh-a.FinalCapacitor_kWh);
    if valid
     r.TailSourceSaving_kWh=a.TailSource_kWh-b.TailSource_kWh;
     r.CombinedSourceSaving_kWh=a.CombinedSource_kWh-b.CombinedSource_kWh;
     r.CombinedDissipationSaving_kWh=a.CombinedDissipation_kWh-b.CombinedDissipation_kWh;
     r.SourceVsDissipationDifference_kWh=r.CombinedSourceSaving_kWh-r.CombinedDissipationSaving_kWh;
    end
    n=n+1;rows{n}=r;
   end
  end
 end
end
assert(n==168);P=struct2table(vertcat(rows{:}));
end

function S=caseStepChecks(O,T,names,dts,socs,Cases,tail)
of={'Source_kWh','Chopper_kWh','SourceResistanceLoss_kWh','ConversionLoss_kWh', ...
 'FinalStored_kWh','FinalCapacitor_kWh','ChargeBus_kWh','DischargeBus_kWh'};
tf={'CombinedSource_kWh','CombinedDissipation_kWh','TailSource_kWh','TailSourceResistanceLoss_kWh', ...
 'TailChopper_kWh','TailConversionLoss_kWh','TailChargeBus_kWh','TailDischargeBus_kWh','FinalStored_kWh','FinalCapacitor_kWh'};
rows=cell(56,1);n=0;
for id=Cases.CaseID'
 for soc=socs
  for name=string(names)
   ia=O.CaseID==id&abs(O.dt_s-dts(1))<1e-12&abs(O.SOC0-soc)<1e-12&string(O.Controller)==name;
   ib=O.CaseID==id&abs(O.dt_s-dts(2))<1e-12&abs(O.SOC0-soc)<1e-12&string(O.Controller)==name;
   assert(sum(ia)==1&&sum(ib)==1);a=O(ia,:);b=O(ib,:);ta=T(ia,:);tb=T(ib,:);
   de=max([abs(a{1,of}-b{1,of}),abs(ta{1,tf}-tb{1,tf})]);
   dv=max([abs(a{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}-b{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}), ...
    abs(ta{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}}-tb{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}})]);
   r=struct('CaseID',id,'Controller',name,'SOC0',soc,'Coarse_dt_s',dts(1),'Fine_dt_s',dts(2), ...
    'MaxEnergyChange_kWh',de,'MaxVoltageChange_V',dv,'EnergyTolerance_kWh',tail.StepEnergyTol_kWh, ...
    'VoltageTolerance_V',tail.StepVoltageTol_V,'Pass', ...
    de<=tail.StepEnergyTol_kWh&&dv<=tail.StepVoltageTol_V&&ta.Comparable&&tb.Comparable ...
    &&ta.ImplementationChecksPass&&tb.ImplementationChecksPass);
   n=n+1;rows{n}=r;
  end
 end
end
assert(n==56);S=struct2table(vertcat(rows{:}));
end

function S=casePairedSteps(P,dts,energyTolerance,zeroTolerance)
A=P(abs(P.dt_s-dts(1))<1e-12,:);rows=cell(height(A),1);
for k=1:height(A)
 a=A(k,:);b=P(P.CaseID==a.CaseID&abs(P.dt_s-dts(2))<1e-12&abs(P.SOC0-a.SOC0)<1e-12 ...
  &string(P.ReferenceController)==string(a.ReferenceController)&string(P.TestController)==string(a.TestController),:);
 assert(height(b)==1);valid=a.Comparable&&b.Comparable;
 coarse=a.CombinedSourceSaving_kWh;fine=b.CombinedSourceSaving_kWh;de=abs(coarse-fine);
 resolved=valid&&abs(coarse)>zeroTolerance&&abs(fine)>zeroTolerance;
 r=struct('CaseID',a.CaseID,'SOC0',a.SOC0,'ReferenceController',string(a.ReferenceController), ...
  'TestController',string(a.TestController),'Coarse_dt_s',dts(1),'Fine_dt_s',dts(2), ...
  'CoarseCombinedSourceSaving_kWh',coarse,'FineCombinedSourceSaving_kWh',fine, ...
  'AbsChange_CombinedSaving_kWh',de,'EnergyTolerance_kWh',energyTolerance, ...
  'SignZeroTolerance_kWh',zeroTolerance,'BothSignsResolved',resolved, ...
  'SameResolvedSign',resolved&&sign(coarse)==sign(fine),'Comparable',valid, ...
  'StepTolerancePass',valid&&de<=energyTolerance);
 rows{k}=r;
end
assert(height(A)==84);S=struct2table(vertcat(rows{:}));
end

function plotSchedule(P,names,Cases,dt,path)
fig=figure('Color','w','Position',[80 80 1350 550]);tiledlayout(1,2);socs=[.55 .85];
for s=1:2
 nexttile;hold on;
 for c=2:numel(names)
  y=NaN(height(Cases),1);
  for k=1:height(Cases)
   x=P(P.CaseID==Cases.CaseID(k)&P.dt_s==dt&P.SOC0==socs(s) ...
    &string(P.ReferenceController)=="VoltageReactive"&string(P.TestController)==names{c},:);
   assert(height(x)==1);if x.Comparable,y(k)=x.CombinedSourceSaving_kWh;end
  end
  plot(Cases.CaseID+(c-3)*.10,y,'o','LineStyle','none','LineWidth',1.2,'DisplayName',names{c});
 end
 yline(0,':','HandleVisibility','off');grid on;xticks(Cases.CaseID);xlim([min(Cases.CaseID)-.5,max(Cases.CaseID)+.5]);
 xlabel('Frozen case ID (0 = nominal)');ylabel('VR minus policy total source energy (kWh)');
 title(sprintf('SOC0 = %.2f; positive = less source energy',socs(s)));
 legend('Interpreter','none','Location','best');
end
sgtitle('Fixed-plan diagnostic: signed within-case effects including common test continuation');
exportgraphics(fig,path,'Resolution',200);
end
