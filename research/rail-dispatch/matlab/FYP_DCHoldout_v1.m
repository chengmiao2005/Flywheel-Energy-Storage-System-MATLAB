function FYP_DCHoldout_v1(thresholdFolder,scheduleFolder)
% FROZEN CONDITIONAL SYNTHETIC TEST, N=100 scene draws; 1200 jobs.
% Requires FULL Threshold and Schedule output folders. No tuning or retries.
% Primary: scene-average over two SOCs of VR820/710 minus Schedule780/710,
% source energy including the same declared 194 s terminal continuation.
% Approximate t(99) interval applies only to the declared synthetic generator.
% Three fixed policies; one pure nominal plan; all inherited physics unchanged.
if nargin<1 || isempty(thresholdFolder),thresholdFolder=latestFolder('FYP_DCThreshold_v1_Output_*');end
if nargin<2 || isempty(scheduleFolder),scheduleFolder=latestFolder('FYP_DCSchedule_v1_Output_*');end
thresholdRequired={'ThresholdSettings.mat','ThresholdOriginalMetrics.csv','ThresholdSummary.csv', ...
 'ThresholdInputChecks.csv','ThresholdTraceChecks.csv','ThresholdPlanChecks.csv','ThresholdDefaultChecks.csv', ...
 'ThresholdLedgerChecks.csv','ThresholdStepChecks.csv','ThresholdPairedStepChecks.csv','ThresholdNamedStepChecks.csv', ...
 'ThresholdSelection.csv','ThresholdCandidates.csv','SourceSnapshot.m'};
scheduleRequired={'ScheduleSettings.mat','ScheduleOriginalMetrics.csv','ScheduleSummary.csv', ...
 'ScheduleBaselineChecks.csv','NominalScheduleChecks.csv','PlanInputChecks.csv','TrainChecks.csv', ...
 'StationChecks.csv','NodeChecks.csv','PolicyChecks.csv','ScheduleStepChecks.csv','SchedulePairedStepChecks.csv', ...
 'NominalPlan.mat','Case00_Input.mat','SourceSnapshot.m'};
requireFiles(thresholdFolder,thresholdRequired);requireFiles(scheduleFolder,scheduleRequired);
T=load(fullfile(thresholdFolder,'ThresholdSettings.mat'),'config');thresholdConfig=T.config;
Q=load(fullfile(scheduleFolder,'ScheduleSettings.mat'),'config');inherited=Q.config;
assert(isequaln(thresholdConfig.InheritedConfig,inherited),'Threshold and Schedule folders are from different frozen configurations.');
e=inherited.Electrical;f=inherited.Storage;tail=inherited.Tail;p=inherited.Train;route=inherited.Route;
scheduleO=readtable(fullfile(scheduleFolder,'ScheduleOriginalMetrics.csv'));
scheduleS=readtable(fullfile(scheduleFolder,'ScheduleSummary.csv'));
thresholdConfiguration(inherited,e,f,tail,inherited.Cases,scheduleO,scheduleS);
dts=[.00125 .000625];socs=[.55 .85];horizons=[5 10 15 20];trainDT=.0025;
ScheduleInputChecks=thresholdInputChecks(scheduleFolder,scheduleO,scheduleS,e,f,tail,inherited.Cases,dts,socs);
assert(all(ScheduleInputChecks.Pass),'Inherited Schedule checks failed before the holdout.');
nativeO=readtable(fullfile(thresholdFolder,'ThresholdOriginalMetrics.csv'));
nativeS=readtable(fullfile(thresholdFolder,'ThresholdSummary.csv'));
ThresholdInputChecks=holdoutThresholdChecks(thresholdFolder,nativeO,nativeS,e,f,tail);
assert(all(ThresholdInputChecks.Pass),'Inherited Threshold checks failed before the holdout.');
Q=load(fullfile(scheduleFolder,'NominalPlan.mat'),'plan','NominalNode');plan=Q.plan;
assert(isequal(plan.NominalMassFactors,[1 1])&&plan.NominalOffset_s==35&&plan.Train_dt_s==trainDT);
rebuilt=makeOpportunityModel(Q.NominalNode,e,f);
assert(isequal(plan.Edges_s,rebuilt.Edges_s)&&isequal(plan.Cumulative_kWh,rebuilt.Cumulative_kWh) ...
 &&plan.Finish_s==rebuilt.Finish_s&&plan.Band_kWh==rebuilt.Band_kWh);
% Freeze all policies before generating any test parameters.
Policies=table((1:3)',["VoltageReactiveSelected";"ScheduleSelected";"ScheduleAtReactiveSetting"], ...
 ["VoltageReactive";"SchedulePreview";"SchedulePreview"],[0;2;2],[820;780;820],[710;710;710], ...
 'VariableNames',{'PolicyID','Controller','InheritedController','CoreControllerID','ChargeThreshold_V','DischargeThreshold_V'});
N=100;seed=2026091701;
out=['FYP_DCHoldout_v1_Output_' datestr(now,'yyyymmdd_HHMMSS_FFF')];mkdir(out);mkdir(fullfile(out,'SceneInputs'));
config=struct('InheritedThresholdFolder',thresholdFolder,'InheritedScheduleFolder',scheduleFolder, ...
 'InheritedConfig',inherited,'Policies',Policies,'Electrical',e,'Storage',f,'Tail',tail, ...
 'Train',p,'Route',route,'Train_dt_s',trainDT,'DC_dt_s',dts,'SOC0',socs,'Horizons_s',horizons, ...
 'NScenes',N,'Seed',seed,'RandomStream','mt19937ar','UniformDrawShape',[N 3], ...
 'DrawColumns','MassFactorA, MassFactorB, ActualOffset_s; one rand(stream,100,3) call', ...
 'MassFactorRange',[.95 1.05],'ActualOffsetRange_s',[32.5 37.5], ...
 'Primary','Mean over scenes of within-scene mean over the two SOCs: VR820/710 minus Schedule780/710, original plus fixed tail', ...
 'Secondary','VR820/710 minus Schedule820/710; descriptive only', ...
 'Interval','Approximate two-sided 95 percent Student-t interval across 100 scene effects; conditional synthetic model', ...
 'FailureRule','No exclusions, replacements, retries or optional stopping; any required failure withholds aggregate primary interval', ...
 'Scope','Synthetic conditional test; no field validity, safety, 90 percent reliability, or global-optimum claim', ...
 'MATLABVersion',version);
save(fullfile(out,'HoldoutSettings.mat'),'config','-v7');
copyfile([mfilename('fullpath') '.m'],fullfile(out,'SourceSnapshot.m'));
copyfile(fullfile(scheduleFolder,'SourceSnapshot.m'),fullfile(out,'InheritedScheduleSource.m'));
copyfile(fullfile(thresholdFolder,'SourceSnapshot.m'),fullfile(out,'InheritedThresholdSource.m'));
save(fullfile(out,'FrozenNominalPlan.mat'),'plan','-v7');writetable(Policies,fullfile(out,'FrozenPolicies.csv'));
% Dedicated stream: no global RNG change and NO worker RNG.
stream=RandStream('mt19937ar','Seed',seed);uniforms=rand(stream,N,3);
Manifest=table((1:N)',uniforms(:,1),uniforms(:,2),uniforms(:,3), ...
 .95+.1*uniforms(:,1),.95+.1*uniforms(:,2),32.5+5*uniforms(:,3), ...
 'VariableNames',{'SceneID','UniformMassA','UniformMassB','UniformOffset','MassFactorA','MassFactorB','ActualOffset_s'});
save(fullfile(out,'HoldoutManifest.mat'),'Manifest','uniforms','seed','-v7');
writetable(Manifest,fullfile(out,'HoldoutManifest.csv'));
freezeFiles={'HoldoutSettings.mat','HoldoutManifest.mat','HoldoutManifest.csv','FrozenPolicies.csv', ...
 'FrozenNominalPlan.mat','SourceSnapshot.m','InheritedScheduleSource.m','InheritedThresholdSource.m'};
Hashes=hashFiles(out,freezeFiles);writetable(Hashes,fullfile(out,'PreOutcomeHashes.csv'));
assert(all(Hashes.HashSuccess),'Could not hash the frozen configuration/manifest/source before outcomes.');
writetable(ScheduleInputChecks,fullfile(out,'InheritedScheduleChecks.csv'));
writetable(ThresholdInputChecks,fullfile(out,'InheritedThresholdChecks.csv'));
fprintf('Policies, configuration, 100 scene draws and source hashes saved before outcomes.\n');
fprintf('Frozen synthetic test: no new draws, tuning, exclusions, or reruns within this stage.\n');
tailGrids=cell(2,1);for j=1:2,tailGrids{j}=tailGrid(tail.Duration_s,dts(j),e.ControlPeriod_s);end
% Known case0 is a regression fixture, not one of the 100 test scenes.
Q=load(fullfile(scheduleFolder,'Case00_Input.mat'),'N');nominalInput=Q.N;
fixture=table(0,1,1,35,'VariableNames',{'SceneID','MassFactorA','MassFactorB','ActualOffset_s'});
[fixtureO,fixtureS]=holdoutFixture(nominalInput,fixture,Policies,plan,e,f,tail,dts,socs,horizons,tailGrids);
FixtureChecks=holdoutFixtureChecks(fixtureO,fixtureS,nativeO,nativeS,Policies);
writetable(fixtureO,fullfile(out,'FixtureOriginalMetrics.csv'));writetable(fixtureS,fullfile(out,'FixtureSummary.csv'));
writetable(FixtureChecks,fullfile(out,'FixtureChecks.csv'));
assert(height(FixtureChecks)==12&&all(FixtureChecks.Pass),'Known-case regression failed: random test outcomes were not run.');
fprintf('Known-case regression passed: 12 / 12. Starting the frozen 100-scene test.\n');
originalTemplate=blankRecord(table2struct(fixtureO(1,:)));summaryTemplate=blankRecord(table2struct(fixtureS(1,:)));
parallelOK=false;
if license('test','Distrib_Computing_Toolbox')
 try
  pool=gcp('nocreate');if isempty(pool),pool=parpool('threads');end
  parallelOK=true;fprintf('Parallel scene workers: %d. Each scene builds one DC grid at a time.\n',pool.NumWorkers);
 catch ME,warning('FYP:SerialFallback','Using serial execution: %s',ME.message);
 end
end
results=cell(N,1);
if parallelOK
 parfor k=1:N
  results{k}=holdoutScene(Manifest(k,:),Policies,plan,p,route,trainDT,e,f,tail,dts,socs,horizons,tailGrids,out,originalTemplate,summaryTemplate);
 end
else
 for k=1:N
  results{k}=holdoutScene(Manifest(k,:),Policies,plan,p,route,trainDT,e,f,tail,dts,socs,horizons,tailGrids,out,originalTemplate,summaryTemplate);
 end
end
originalRows=cell(N*12,1);summaryRows=cell(N*12,1);inputRows=cell(N,1);
for k=1:N
 ix=(k-1)*12+(1:12);originalRows(ix)=results{k}.Original;summaryRows(ix)=results{k}.Summary;inputRows{k}=results{k}.InputCheck;
end
Original=struct2table(vertcat(originalRows{:}));Summary=struct2table(vertcat(summaryRows{:}));
InputChecks=struct2table(vertcat(inputRows{:}));
% Immutable raw inputs were saved by scene before that scene's controller runs.
% Hash them on the client, avoiding Java use in thread workers.
inputFiles=compose('SceneInputs/Scene%03d_Input.mat',Manifest.SceneID);
InputHashes=hashFiles(out,cellstr(inputFiles));
inputArchivePass=all(InputHashes.Exists)&&all(InputHashes.HashSuccess);
LedgerChecks=holdoutLedgers(Original,Summary,e,f,tail);
StepChecks=holdoutSteps(Original,Summary,Manifest,Policies,dts,socs,tail);
Paired=holdoutPairs(Summary,Manifest,Policies,dts,socs,tail,e);
PairedStepChecks=holdoutPairSteps(Paired,dts,tail.StepEnergyTol_kWh,e.BalanceTol_kWh);
SceneEffects=holdoutSceneEffects(Paired,Manifest,dts,socs);
gate=all(FixtureChecks.Pass)&&all(InputChecks.Pass)&&inputArchivePass&&all(Original.Success)&&all(Summary.Success) ...
 &&all(Summary.Comparable)&&all(LedgerChecks.Pass)&&all(StepChecks.Pass)&&all(Paired.Comparable)&&all(PairedStepChecks.StepTolerancePass) ...
 &&all(SceneEffects.Complete)&&height(SceneEffects)==N;
[Primary,Secondary]=holdoutInference(SceneEffects,gate,N);
files={'HoldoutOriginalMetrics.csv',Original;'HoldoutSummary.csv',Summary; ...
 'HoldoutInputChecks.csv',InputChecks;'HoldoutInputHashes.csv',InputHashes;'HoldoutLedgerChecks.csv',LedgerChecks; ...
 'HoldoutStepChecks.csv',StepChecks;'HoldoutPaired.csv',Paired;'HoldoutPairedStepChecks.csv',PairedStepChecks; ...
 'HoldoutSceneEffects.csv',SceneEffects;'HoldoutPrimarySummary.csv',Primary;'HoldoutSecondarySummary.csv',Secondary};
for k=1:size(files,1),writetable(files{k,2},fullfile(out,files{k,1}));end
plotHoldout(SceneEffects,Primary,fullfile(out,'HoldoutChecks.png'));
reviewFiles=[{'HoldoutSettings.mat','HoldoutManifest.mat','HoldoutManifest.csv','FrozenPolicies.csv', ...
 'PreOutcomeHashes.csv','SourceSnapshot.m','InheritedScheduleSource.m','InheritedThresholdSource.m', ...
 'InheritedScheduleChecks.csv','InheritedThresholdChecks.csv','FixtureOriginalMetrics.csv','FixtureSummary.csv', ...
 'FixtureChecks.csv','HoldoutChecks.png'},files(:,1)'];
zipPath=fullfile(pwd,out,'HoldoutReview.zip');zip(zipPath,reviewFiles,out);
fprintf('\nFROZEN SYNTHETIC TEST FINISHED\n');
fprintf('Scene input failures: %d / 100; original execution failures: %d / 1200; terminal failures: %d / 1200.\n', ...
 sum(~InputChecks.Pass),sum(~Original.Success),sum(~Summary.Comparable));
fprintf('Ledger failures: %d / 1200; individual step failures: %d / 600; paired step failures: %d / 400.\n', ...
 sum(~LedgerChecks.Pass),sum(~StepChecks.Pass),sum(~PairedStepChecks.StepTolerancePass));
fprintf('Complete scenes: %d / 100. Primary inference gate: %d.\n',sum(SceneEffects.Complete),gate);
disp(Primary);disp(Secondary);
if ~gate,warning('FYP:InferenceWithheld','Required failure retained; no primary aggregate CI. Do not filter failed scenes or replace draws.');end
fprintf('Send HoldoutReview.zip and the final console summary.\nReview packet: %s\n',zipPath);
fprintf('The interval is approximate and conditional on this synthetic model/generator. It is not field or reliability validation.\n');
end

function folder=latestFolder(pattern)
D=dir(pattern);D=D([D.isdir]);assert(~isempty(D),'Missing full output folder matching %s.',pattern);
[~,ix]=sort({D.name});D=D(ix);folder=fullfile(D(end).folder,D(end).name);
end
function requireFiles(folder,names)
for k=1:numel(names),assert(isfile(fullfile(folder,names{k})),'Missing %s in %s. Use the full original output folder.',names{k},folder);end
end

function H=hashFiles(folder,names)
rows=cell(numel(names),1);
for k=1:numel(names)
 path=fullfile(folder,names{k});exists=isfile(path);digest="";bytes=NaN;success=false;message="";
 if exists
  try
   info=dir(path);bytes=info.bytes;digest=string(fileSHA256(path));success=true;
  catch ME,message=string(ME.message);
  end
 end
 rows{k}=struct('RelativePath',string(names{k}),'Exists',exists,'Bytes',bytes,'SHA256',digest,'HashSuccess',success,'HashError',message);
end
H=struct2table(vertcat(rows{:}));
end
function h=fileSHA256(path)
assert(usejava('jvm'),'Source/input hashing requires the JVM in desktop MATLAB.');
fid=fopen(path,'rb');assert(fid>=0,'Cannot read %s.',path);cleanup=onCleanup(@()fclose(fid));
md=java.security.MessageDigest.getInstance('SHA-256');
while ~feof(fid)
 bytes=fread(fid,1024*1024,'*uint8');if ~isempty(bytes),md.update(typecast(bytes,'int8'));end
end
h=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function r=blankRecord(r)
names=fieldnames(r);
for k=1:numel(names)
 x=r.(names{k});
 if islogical(x),r.(names{k})=false(size(x));
 elseif isnumeric(x),r.(names{k})=nan(size(x));
 elseif isstring(x),r.(names{k})="";
 elseif ischar(x),r.(names{k})='';
 else,error('FYP:UnexpectedRecordType','Unexpected metric type %s.',class(x));
 end
end
end

function r=holdoutMetadata(r,scene,policy,soc,dt,success,stage,identifier,message)
r.SceneID=scene.SceneID;r.Controller=string(policy.Controller);r.PolicyID=policy.PolicyID;
r.ChargeThreshold_V=policy.ChargeThreshold_V;r.DischargeThreshold_V=policy.DischargeThreshold_V;
r.SOC0=soc;r.dt_s=dt;r.MassFactorA=scene.MassFactorA;r.MassFactorB=scene.MassFactorB;r.ActualOffset_s=scene.ActualOffset_s;
r.Success=success;r.FailureStage=string(stage);r.FailureIdentifier=string(identifier);r.FailureMessage=string(message);
end

function [O,S]=holdoutFixture(N,scene,Policies,plan,e,f,tail,dts,socs,horizons,tailGrids)
orows=cell(12,1);srows=cell(12,1);n=0;
for d=1:2
 G=eventGrid(N,dts(d),e.ControlPeriod_s);t=(0:max(G.controlID)-1)'*e.ControlPeriod_s;
 q=planReserve(plan,t,horizons);F=struct('Schedule_kWh',q,'Preview_kWh',zeros(size(q)));
 for s=1:2
  for c=1:3
   policy=Policies(c,:);local=e;local.ChargeThreshold_V=policy.ChargeThreshold_V;local.DischargeThreshold_V=policy.DischargeThreshold_V;
   [r,~]=simulateSchedule(G,local,f,socs(s),policy.CoreControllerID,F,horizons,false);
   z=runTail(r,tailGrids{d},local,f,tail);n=n+1;
   orows{n}=holdoutMetadata(r,scene,policy,socs(s),dts(d),true,"","","");
   srows{n}=holdoutMetadata(z,scene,policy,socs(s),dts(d),true,"","","");
  end
 end
end
O=struct2table(vertcat(orows{:}));S=struct2table(vertcat(srows{:}));
end

function result=holdoutScene(scene,Policies,plan,p,route,trainDT,e,f,tail,dts,socs,horizons,tailGrids,out,rtemplate,ztemplate)
orows=cell(12,1);srows=cell(12,1);n=0;
for d=1:2
 for s=1:2
  for c=1:3
   n=n+1;orows{n}=holdoutMetadata(rtemplate,scene,Policies(c,:),socs(s),dts(d),false,"NotAttempted","","");
   srows{n}=holdoutMetadata(ztemplate,scene,Policies(c,:),socs(s),dts(d),false,"NotAttempted","","");
  end
 end
end
check=struct('SceneID',scene.SceneID,'InputSaved',false,'TrainChecksPass',false,'NodeCheckPass',false, ...
 'MaxStationError_m',NaN,'MaxStopSpeed_mps',NaN,'MaxTrainBalance_kWh',NaN,'MaxNodeAlignmentError_kWh',NaN, ...
 'RawNetTrain_kWh',NaN,'MaxGridAlignmentError_kWh',NaN,'MaxPlanSameClockDifference_kWh',NaN, ...
 'FailureIdentifier',"",'FailureMessage',"",'Pass',false);
try
 [A,PA,SA,CA]=checkedTrain(p,route,trainDT,scene.MassFactorA);
 [B,PB,SB,CB]=checkedTrain(p,route,trainDT,scene.MassFactorB);
 tol=struct('energy_kWh',1e-8,'power_W',1e-5,'state_kWh',1e-10);
 [N,NodeCheck]=mergeNode(A,B,scene.ActualOffset_s,tol);
 check.TrainChecksPass=CA.Pass&&CB.Pass;check.NodeCheckPass=NodeCheck.MaxAlignmentError_kWh<tol.energy_kWh;
 check.MaxStationError_m=max(CA.MaxStationError_m,CB.MaxStationError_m);check.MaxStopSpeed_mps=max(CA.MaxStopSpeed_mps,CB.MaxStopSpeed_mps);
 check.MaxTrainBalance_kWh=max(abs([CA.MaxAbsIntervalBalance_kWh,CB.MaxAbsIntervalBalance_kWh,CA.CumulativeBalance_kWh,CB.CumulativeBalance_kWh]));
 check.MaxNodeAlignmentError_kWh=NodeCheck.MaxAlignmentError_kWh;
 check.RawNetTrain_kWh=sum((N.GrossDemand_W-N.OfferedRegen_W).*N.Step_s)/3.6e6;
 % Exact merged input and train diagnostics are saved before controller outcomes.
 save(fullfile(out,'SceneInputs',sprintf('Scene%03d_Input.mat',scene.SceneID)), ...
  'N','scene','PA','PB','SA','SB','CA','CB','NodeCheck','-v7');
 check.InputSaved=true;clear A B;
catch ME
 check.FailureIdentifier=string(ME.identifier);check.FailureMessage=string(ME.message);
 for j=1:12
  orows{j}.FailureStage="InputGeneration";orows{j}.FailureIdentifier=string(ME.identifier);orows{j}.FailureMessage=string(ME.message);
  srows{j}.FailureStage="InputGeneration";srows{j}.FailureIdentifier=string(ME.identifier);srows{j}.FailureMessage=string(ME.message);
 end
 result=struct('Original',{orows},'Summary',{srows},'InputCheck',check);
 fprintf('Scene %d input failed; all 12 planned statuses retained.\n',scene.SceneID);return;
end
check.MaxGridAlignmentError_kWh=0;check.MaxPlanSameClockDifference_kWh=0;
for d=1:2
 try
  G=eventGrid(N,dts(d),e.ControlPeriod_s);
  t=(0:max(G.controlID)-1)'*e.ControlPeriod_s;
  % Only clock queries and the unchanged nominal plan enter this lookup.
  q=planReserve(plan,t,horizons);F=struct('Schedule_kWh',q,'Preview_kWh',zeros(size(q)));
  check.MaxGridAlignmentError_kWh=max(check.MaxGridAlignmentError_kWh,abs(sum(G.p.*G.h)/3.6e6-check.RawNetTrain_kWh));
  sampleT=t(1:max(1,floor(numel(t)/50)):end);same=planReserve(plan,sampleT,horizons);
  ids=round(sampleT/e.ControlPeriod_s)+1;dev=max(abs(same-q(ids,:)),[],'all');
  check.MaxPlanSameClockDifference_kWh=max(check.MaxPlanSameClockDifference_kWh,dev);
 catch ME
  check.FailureIdentifier=string(ME.identifier);check.FailureMessage=string(ME.message);
  for j=(d-1)*6+(1:6)
   orows{j}.FailureStage="InputGrid";orows{j}.FailureIdentifier=string(ME.identifier);orows{j}.FailureMessage=string(ME.message);
   srows{j}.FailureStage="InputGrid";srows{j}.FailureIdentifier=string(ME.identifier);srows{j}.FailureMessage=string(ME.message);
  end
  continue;
 end
 for s=1:2
  for c=1:3
   j=(d-1)*6+(s-1)*3+c;policy=Policies(c,:);local=e;
   local.ChargeThreshold_V=policy.ChargeThreshold_V;local.DischargeThreshold_V=policy.DischargeThreshold_V;
   try
    [r,~]=simulateSchedule(G,local,f,socs(s),policy.CoreControllerID,F,horizons,false);
    orows{j}=holdoutMetadata(r,scene,policy,socs(s),dts(d),true,"","","");
   catch ME
    orows{j}.FailureStage="OriginalSimulation";orows{j}.FailureIdentifier=string(ME.identifier);orows{j}.FailureMessage=string(ME.message);
    srows{j}.FailureStage="OriginalSimulation";srows{j}.FailureIdentifier=string(ME.identifier);srows{j}.FailureMessage=string(ME.message);continue;
   end
   try
    z=runTail(r,tailGrids{d},local,f,tail);
    srows{j}=holdoutMetadata(z,scene,policy,socs(s),dts(d),true,"","","");
   catch ME
    srows{j}.FailureStage="TerminalContinuation";srows{j}.FailureIdentifier=string(ME.identifier);srows{j}.FailureMessage=string(ME.message);
   end
  end
 end
 clear G F;
end
check.Pass=check.InputSaved&&check.TrainChecksPass&&check.NodeCheckPass&&strlength(check.FailureMessage)==0 ...
 &&check.MaxGridAlignmentError_kWh<e.BalanceTol_kWh&&check.MaxPlanSameClockDifference_kWh<=1e-12;
result=struct('Original',{orows},'Summary',{srows},'InputCheck',check);
fprintf('Scene %d / 100 finished; %d / 12 original jobs and %d / 12 tails executed.\n', ...
 scene.SceneID,sum(cellfun(@(x)x.Success,orows)),sum(cellfun(@(x)x.Success,srows)));
end

function C=holdoutThresholdChecks(folder,O,S,e,f,tail)
spec={'ThresholdInputChecks.csv','Pass',11;'ThresholdTraceChecks.csv','Pass',14; ...
 'ThresholdPlanChecks.csv','Pass',7;'ThresholdDefaultChecks.csv','Pass',56; ...
 'ThresholdLedgerChecks.csv','Pass',504;'ThresholdStepChecks.csv','Pass',252; ...
 'ThresholdPairedStepChecks.csv','StepTolerancePass',126;'ThresholdNamedStepChecks.csv','StepTolerancePass',56; ...
 'ThresholdSelection.csv','SelectionGatePass',2};
rows=cell(size(spec,1)+2,1);
for k=1:size(spec,1)
 T=readtable(fullfile(folder,spec{k,1}));flag=T.(spec{k,2});
 ok=height(T)==spec{k,3}&&all(isfinite(double(flag)))&&all(double(flag)==1);
 rows{k}=struct('Check',string(spec{k,1}),'Records',height(T),'ExpectedRecords',spec{k,3},'Pass',ok);
end
L=thresholdLedgers(O,S,e,f,tail);n=size(spec,1);
ok=height(O)==504&&height(S)==504&&all(L.Pass)&&all(S.ImplementationChecksPass==1);
for id=0:6
 for soc=[.55 .85]
  for dt=[.00125 .000625]
   for uc=[780 800 820]
    for ud=[690 710 730]
     for name=["VoltageReactive","SchedulePreview"]
      x=O.CaseID==id&O.SOC0==soc&O.dt_s==dt&O.ChargeThreshold_V==uc&O.DischargeThreshold_V==ud&string(O.Controller)==name;
      y=S.CaseID==id&S.SOC0==soc&S.dt_s==dt&S.ChargeThreshold_V==uc&S.DischargeThreshold_V==ud&string(S.Controller)==name;
      ok=ok&&sum(x)==1&&sum(y)==1;
     end
    end
   end
  end
 end
end
rows{n+1}=struct('Check',"Native threshold keys and independently recomputed ledgers",'Records',height(S),'ExpectedRecords',504,'Pass',ok);
T=readtable(fullfile(folder,'ThresholdSelection.csv'));ok=height(T)==2;
expected=[820 710;780 710];names=["VoltageReactive","SchedulePreview"];
for k=1:2
 a=T(string(T.Controller)==names(k),:);assert(height(a)==1);
 fine=S(S.dt_s==.000625&string(S.Controller)==names(k),:);
 IDs=unique(fine.CandidateID);v=zeros(numel(IDs),4);
 for j=1:numel(IDs)
  q=fine(fine.CandidateID==IDs(j),:);assert(height(q)==14);
  v(j,:)=[mean(q.CombinedSource_kWh),q.ChargeThreshold_V(1),q.DischargeThreshold_V(1),q.CandidateID(1)];
 end
 minimum=min(v(:,1));candidate=v(v(:,1)<=minimum+1e-8,:);
 rank=[abs(candidate(:,2)-800)+abs(candidate(:,3)-710),candidate(:,2:3)];
 [~,order]=sortrows(rank,[1 2 3]);winner=candidate(order(1),:);
 ok=ok&&a.SelectionGatePass==1&&a.SelectedChargeThreshold_V==expected(k,1)&&a.SelectedDischargeThreshold_V==expected(k,2) ...
  &&all(winner(2:3)==expected(k,:))&&winner(4)==a.SelectedCandidateID&&abs(winner(1)-a.SelectedMean_kWh)<1e-8;
end
rows{n+2}=struct('Check',"Recomputed global selections equal the predeclared frozen policies",'Records',2,'ExpectedRecords',2,'Pass',ok);
C=struct2table(vertcat(rows{:}));
end

function C=holdoutFixtureChecks(O,S,NO,NS,Policies)
of={'Source_kWh','SourceToBus_kWh','SourceResistanceLoss_kWh','Chopper_kWh','ChargeBus_kWh','DischargeBus_kWh', ...
 'ConversionLoss_kWh','NetTrain_kWh','InitialStored_kWh','FinalStored_kWh','MinStored_kWh','MaxStored_kWh', ...
 'InitialCapacitor_kWh','FinalCapacitor_kWh','WrapperExtraCommandProxy_kWh'};
tf={'OriginalSource_kWh','TailSource_kWh','TailSourceResistanceLoss_kWh','TailChopper_kWh','TailConversionLoss_kWh', ...
 'TailChargeBus_kWh','TailDischargeBus_kWh','FinalStored_kWh','FinalCapacitor_kWh','CombinedSource_kWh','CombinedDissipation_kWh'};
rows=cell(12,1);
for k=1:height(O)
 a=O(k,:);z=S(k,:);policy=Policies(Policies.PolicyID==a.PolicyID,:);
 x=NO.CaseID==0&NO.dt_s==a.dt_s&NO.SOC0==a.SOC0&NO.ChargeThreshold_V==policy.ChargeThreshold_V ...
  &NO.DischargeThreshold_V==policy.DischargeThreshold_V&string(NO.Controller)==policy.InheritedController;
 y=NS.CaseID==0&NS.dt_s==a.dt_s&NS.SOC0==a.SOC0&NS.ChargeThreshold_V==policy.ChargeThreshold_V ...
  &NS.DischargeThreshold_V==policy.DischargeThreshold_V&string(NS.Controller)==policy.InheritedController;
 b=NO(x,:);w=NS(y,:);assert(height(b)==1&&height(w)==1);
 de=max([abs(a{1,of}-b{1,of}),abs(z{1,tf}-w{1,tf})]);
 dv=max([abs(a{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}-b{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}), ...
  abs(z{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}}-w{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}})]);
 rows{k}=struct('PolicyID',a.PolicyID,'Controller',string(a.Controller),'SOC0',a.SOC0,'dt_s',a.dt_s, ...
  'MaxEnergyDifference_kWh',de,'MaxVoltageDifference_V',dv,'EnergyTolerance_kWh',1e-6,'VoltageTolerance_V',1e-5, ...
  'Pass',a.Success&&z.Success&&z.Comparable&&w.Comparable&&isfinite(de)&&isfinite(dv)&&de<=1e-6&&dv<=1e-5);
end
assert(height(O)==12);C=struct2table(vertcat(rows{:}));
end

function L=holdoutLedgers(O,S,e,f,tail)
assert(height(O)==1200&&height(S)==1200);rows=cell(height(O),1);
for k=1:height(O)
 a=O(k,:);b=S(k,:);
 assert(a.SceneID==b.SceneID&&a.PolicyID==b.PolicyID&&a.SOC0==b.SOC0&&a.dt_s==b.dt_s);
 original=a.Source_kWh-a.NetTrain_kWh-a.SourceResistanceLoss_kWh-a.Chopper_kWh-a.ConversionLoss_kWh ...
  -(a.FinalStored_kWh-a.InitialStored_kWh)-(a.FinalCapacitor_kWh-a.InitialCapacitor_kWh);
 combined=b.CombinedSource_kWh-a.NetTrain_kWh-b.TailLoad_kWh-b.CombinedDissipation_kWh ...
  -(b.FinalStored_kWh-a.InitialStored_kWh)-(b.FinalCapacitor_kWh-a.InitialCapacitor_kWh);
 storage=a.FinalStored_kWh-a.InitialStored_kWh-f.etaC*a.ChargeBus_kWh+a.DischargeBus_kWh/f.etaD;
 values=[original,combined,storage,b.CombinedSource_kWh-a.Source_kWh-b.TailSource_kWh, ...
  b.OriginalSource_kWh-a.Source_kWh,b.TargetStored_kWh-a.InitialStored_kWh,original-a.SystemResidual_kWh, ...
  combined-b.CombinedSystemResidual_kWh,storage-a.StorageResidual_kWh];
 pass=a.Success&&b.Success&&b.Comparable&&all(isfinite(values))&&all(abs(values)<e.BalanceTol_kWh) ...
  &&abs(b.FinalStored_kWh-b.TargetStored_kWh)<=tail.StorageTargetTol_kWh&&abs(b.FinalVoltage_V-tail.SteadyVoltage_V)<=tail.FinalVoltageTol_V;
 rows{k}=struct('SceneID',a.SceneID,'PolicyID',a.PolicyID,'SOC0',a.SOC0,'dt_s',a.dt_s, ...
  'OriginalSystemResidual_kWh',original,'CombinedSystemResidual_kWh',combined,'StorageResidual_kWh',storage, ...
  'MaxCheckedResidual_kWh',max(abs(values)),'Tolerance_kWh',e.BalanceTol_kWh,'Pass',pass);
end
L=struct2table(vertcat(rows{:}));
end

function C=holdoutSteps(O,S,Manifest,Policies,dts,socs,tail)
of={'Source_kWh','Chopper_kWh','SourceResistanceLoss_kWh','ConversionLoss_kWh','FinalStored_kWh','FinalCapacitor_kWh','ChargeBus_kWh','DischargeBus_kWh'};
tf={'CombinedSource_kWh','CombinedDissipation_kWh','TailSource_kWh','TailSourceResistanceLoss_kWh','TailChopper_kWh','TailConversionLoss_kWh','TailChargeBus_kWh','TailDischargeBus_kWh','FinalStored_kWh','FinalCapacitor_kWh'};
rows=cell(600,1);n=0;
for id=Manifest.SceneID'
 for soc=socs
  for policy=Policies.PolicyID'
   x=O.SceneID==id&O.SOC0==soc&O.PolicyID==policy;ia=x&O.dt_s==dts(1);ib=x&O.dt_s==dts(2);
   assert(sum(ia)==1&&sum(ib)==1);a=O(ia,:);b=O(ib,:);ta=S(ia,:);tb=S(ib,:);
   de=max([abs(a{1,of}-b{1,of}),abs(ta{1,tf}-tb{1,tf})]);
   dv=max([abs(a{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}-b{1,{'Vmin_V','Vmax_V','FinalVoltage_V'}}), ...
    abs(ta{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}}-tb{1,{'TailVmin_V','TailVmax_V','FinalVoltage_V'}})]);
   pass=a.Success&&b.Success&&ta.Success&&tb.Success&&ta.Comparable&&tb.Comparable ...
    &&isfinite(de)&&isfinite(dv)&&de<=tail.StepEnergyTol_kWh&&dv<=tail.StepVoltageTol_V;
   n=n+1;rows{n}=struct('SceneID',id,'PolicyID',policy,'SOC0',soc,'Coarse_dt_s',dts(1),'Fine_dt_s',dts(2), ...
    'MaxEnergyChange_kWh',de,'MaxVoltageChange_V',dv,'EnergyTolerance_kWh',tail.StepEnergyTol_kWh, ...
    'VoltageTolerance_V',tail.StepVoltageTol_V,'Pass',pass);
  end
 end
end
assert(n==600);C=struct2table(vertcat(rows{:}));
end

function P=holdoutPairs(S,Manifest,Policies,dts,socs,tail,e)
rows=cell(800,1);n=0;labels=["PrimarySelectedFamilies","SecondaryMatchedReactiveSetting"];
for id=Manifest.SceneID'
 for dt=dts
  for soc=socs
   x=S.SceneID==id&S.dt_s==dt&S.SOC0==soc;a=S(x&S.PolicyID==1,:);assert(height(a)==1);
   for j=1:2
    b=S(x&S.PolicyID==j+1,:);assert(height(b)==1);
    valid=a.Success&&b.Success&&a.Comparable&&b.Comparable ...
     &&abs(a.TargetStored_kWh-b.TargetStored_kWh)<1e-10&&abs(a.TailLoad_kWh-b.TailLoad_kWh)<1e-8 ...
     &&abs(a.FinalStored_kWh-b.FinalStored_kWh)<=2*tail.StorageTargetTol_kWh&&abs(a.FinalVoltage_V-b.FinalVoltage_V)<=2*tail.FinalVoltageTol_V;
    source=a.CombinedSource_kWh-b.CombinedSource_kWh;loss=a.CombinedDissipation_kWh-b.CombinedDissipation_kWh;res=source-loss;
    valid=valid&&all(isfinite([source,loss,res]))&&abs(res)<2*e.BalanceTol_kWh;
    if ~valid,source=NaN;loss=NaN;end
    n=n+1;rows{n}=struct('SceneID',id,'SOC0',soc,'dt_s',dt,'Comparison',labels(j), ...
     'ReferencePolicyID',1,'TestPolicyID',j+1,'OriginalSourceSaving_kWh',a.OriginalSource_kWh-b.OriginalSource_kWh, ...
     'TailSourceSaving_kWh',a.TailSource_kWh-b.TailSource_kWh,'CombinedSourceSaving_kWh',source, ...
     'CombinedDissipationSaving_kWh',loss,'SourceVsDissipationDifference_kWh',res, ...
     'FinalStoredDifference_kWh',b.FinalStored_kWh-a.FinalStored_kWh, ...
     'FinalCapacitorDifference_kWh',b.FinalCapacitor_kWh-a.FinalCapacitor_kWh,'Comparable',valid);
   end
  end
 end
end
assert(n==800&&height(Policies)==3);P=struct2table(vertcat(rows{:}));
end

function C=holdoutPairSteps(P,dts,tolerance,zeroTolerance)
A=P(P.dt_s==dts(1),:);rows=cell(height(A),1);
for k=1:height(A)
 a=A(k,:);b=P(P.dt_s==dts(2)&P.SceneID==a.SceneID&P.SOC0==a.SOC0&P.Comparison==a.Comparison,:);assert(height(b)==1);
 coarse=a.CombinedSourceSaving_kWh;fine=b.CombinedSourceSaving_kWh;valid=a.Comparable&&b.Comparable;
 resolved=valid&&abs(coarse)>zeroTolerance&&abs(fine)>zeroTolerance;
 rows{k}=struct('SceneID',a.SceneID,'SOC0',a.SOC0,'Comparison',a.Comparison,'Coarse_dt_s',dts(1),'Fine_dt_s',dts(2), ...
  'CoarseCombinedSourceSaving_kWh',coarse,'FineCombinedSourceSaving_kWh',fine,'AbsChange_CombinedSaving_kWh',abs(coarse-fine), ...
  'EnergyTolerance_kWh',tolerance,'SignZeroTolerance_kWh',zeroTolerance,'BothSignsResolved',resolved, ...
  'SameResolvedSign',resolved&&sign(coarse)==sign(fine),'Comparable',valid, ...
  'StepTolerancePass',valid&&isfinite(coarse)&&isfinite(fine)&&abs(coarse-fine)<=tolerance);
end
assert(height(A)==400);C=struct2table(vertcat(rows{:}));
end

function C=holdoutSceneEffects(P,Manifest,dts,socs)
rows=cell(height(Manifest),1);
for k=1:height(Manifest)
 id=Manifest.SceneID(k);x=P.SceneID==id;
 pf=P(x&P.dt_s==dts(2)&P.Comparison=="PrimarySelectedFamilies",:);pc=P(x&P.dt_s==dts(1)&P.Comparison=="PrimarySelectedFamilies",:);
 sf=P(x&P.dt_s==dts(2)&P.Comparison=="SecondaryMatchedReactiveSetting",:);sc=P(x&P.dt_s==dts(1)&P.Comparison=="SecondaryMatchedReactiveSetting",:);
 pf=sortrows(pf,'SOC0');pc=sortrows(pc,'SOC0');sf=sortrows(sf,'SOC0');sc=sortrows(sc,'SOC0');
 assert(height(pf)==2&&height(pc)==2&&height(sf)==2&&height(sc)==2&&isequal(pf.SOC0,socs'));
 complete=all(pf.Comparable)&&all(pc.Comparable)&&all(sf.Comparable)&&all(sc.Comparable);
 values=[pf.CombinedSourceSaving_kWh;pc.CombinedSourceSaving_kWh;sf.CombinedSourceSaving_kWh;sc.CombinedSourceSaving_kWh];
 complete=complete&&all(isfinite(values));
 primary=mean(pf.CombinedSourceSaving_kWh);coarse=mean(pc.CombinedSourceSaving_kWh);secondary=mean(sf.CombinedSourceSaving_kWh);
 maxChange=max(abs(pf.CombinedSourceSaving_kWh-pc.CombinedSourceSaving_kWh));
 rows{k}=struct('SceneID',id,'MassFactorA',Manifest.MassFactorA(k),'MassFactorB',Manifest.MassFactorB(k), ...
  'ActualOffset_s',Manifest.ActualOffset_s(k),'PrimaryFineMeanSOCSaving_kWh',primary,'PrimaryCoarseMeanSOCSaving_kWh',coarse, ...
  'PrimarySceneMeanStepChange_kWh',primary-coarse,'MaxPrimarySOCStepChange_kWh',maxChange, ...
  'SecondaryFineMeanSOCSaving_kWh',secondary,'SecondaryCoarseMeanSOCSaving_kWh',mean(sc.CombinedSourceSaving_kWh),'Complete',complete);
end
C=struct2table(vertcat(rows{:}));
end

function [Primary,Secondary]=holdoutInference(C,gate,N)
assert(N==100&&height(C)==100);df=N-1;critical=sqrt(df*(1/betaincinv(.05,df/2,.5)-1));
assert(abs(critical-1.9842169515864165)<1e-10,'Student-t critical value did not reproduce.');
mu=NaN;sd=NaN;se=NaN;low=NaN;high=NaN;coarse=NaN;drift=NaN;maxDrift=NaN;maxSOCDrift=NaN;
minimum=NaN;maximum=NaN;negative=NaN;zero=NaN;positive=NaN;secondary=NaN;secondaryMin=NaN;secondaryMax=NaN;
if gate
 x=C.PrimaryFineMeanSOCSaving_kWh;assert(all(isfinite(x))&&all(C.Complete));
 mu=mean(x);sd=std(x,0);se=sd/sqrt(N);low=mu-critical*se;high=mu+critical*se;
 coarse=mean(C.PrimaryCoarseMeanSOCSaving_kWh);drift=mu-coarse;
 maxDrift=max(abs(C.PrimarySceneMeanStepChange_kWh));maxSOCDrift=max(C.MaxPrimarySOCStepChange_kWh);
 minimum=min(x);maximum=max(x);negative=sum(x< -1e-6);zero=sum(abs(x)<=1e-6);positive=sum(x>1e-6);
 secondary=mean(C.SecondaryFineMeanSOCSaving_kWh);secondaryMin=min(C.SecondaryFineMeanSOCSaving_kWh);secondaryMax=max(C.SecondaryFineMeanSOCSaving_kWh);
end
Primary=table(gate,N,sum(C.Complete),double(gate)*N,mu,sd,se,df,critical,low,high,coarse,drift,maxDrift,maxSOCDrift,minimum,maximum,negative,zero,positive, ...
 'VariableNames',{'InferenceGatePass','PlannedScenes','CompleteScenes','InferentialN','MeanSaving_kWh','SceneSD_kWh','SceneSE_kWh', ...
 'DegreesOfFreedom','T975Critical','Approx95Lower_kWh','Approx95Upper_kWh','CoarseMeanSaving_kWh','FineMinusCoarseMean_kWh', ...
 'MaxAbsSceneMeanStepChange_kWh','MaxAbsSOCSpecificStepChange_kWh','MinSceneSaving_kWh','MaxSceneSaving_kWh', ...
 'NegativeSceneCount','NearZeroSceneCount','PositiveSceneCount'});
Primary.CountZeroTolerance_kWh=1e-6;
Primary.Scope="Conditional synthetic generator; approximate mean interval; no field or reliability inference";
Secondary=table(gate,N,secondary,secondaryMin,secondaryMax, ...
 'VariableNames',{'DescriptiveGatePass','PlannedScenes','MeanSaving_kWh','MinSceneSaving_kWh','MaxSceneSaving_kWh'});
Secondary.Scope="Secondary matched-threshold contrast; descriptive only, no inferential interval";
end

function plotHoldout(C,P,path)
fig=figure('Color','w','Position',[80 80 1250 520]);tiledlayout(1,2);
nexttile;hold on;grid on;
plot(C.SceneID,C.PrimaryFineMeanSOCSaving_kWh,'o','DisplayName','Primary selected-family contrast');
plot(C.SceneID,C.SecondaryFineMeanSOCSaving_kWh,'.','DisplayName','Secondary matched thresholds');
yline(0,':','HandleVisibility','off');xlabel('Frozen synthetic scene ID');ylabel('Mean over two SOCs: VR - Schedule (kWh)');
title('All 100 planned scenes; failed entries retained as missing');legend('Location','best');
nexttile;hold on;grid on;
if P.InferenceGatePass
 errorbar(1,P.MeanSaving_kWh,P.MeanSaving_kWh-P.Approx95Lower_kWh,P.Approx95Upper_kWh-P.MeanSaving_kWh, ...
  'o','LineWidth',1.5,'DisplayName','Mean and approximate 95% t interval');
 plot(1.2,P.CoarseMeanSaving_kWh,'x','MarkerSize',10,'DisplayName','Coarser-step mean');
 legend('Location','best');
else
 text(.1,.5,'Required check failed: aggregate interval withheld','Units','normalized');
end
yline(0,':','HandleVisibility','off');xlim([.5 1.5]);xticks([]);ylabel('Primary mean source-energy saving (kWh)');
title('N=100 scene effects; conditional on the synthetic generator');
sgtitle('Frozen synthetic test: no tuning, exclusions, replacements, or reliability guarantee');
exportgraphics(fig,path,'Resolution',200);
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
