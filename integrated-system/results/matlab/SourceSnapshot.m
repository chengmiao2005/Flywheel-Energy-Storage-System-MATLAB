function output_dir=FYP_EnergyDispatch_v1()
% FYP_ENERGYDISPATCH_V1  Causal recovery credit and loss-aware discharge.
% Run this standalone file in MATLAB R2024a; no external data/toolbox needed.
% The preceding fixed-controller version passed 340/340 in native R2024a.
% Its physical PWM/diode/event/midpoint routines and speed PI are preserved.
%
% New dispatch uses measured initial bus voltage, speed and cycle-mean current.
% Charge only under regenerative load; discharge only under traction demand.
% Limit generating current to 0.25*EMF/Rnom and available recovered-work credit.
% Credit starts at ZERO, earns 90% of measured positive electromagnetic work
% during commanded regeneration, pays ALL negative electromagnetic work, and
% decays at 0.02/s. A 5 J reserve and 0.2 s taper accommodate current transients.
% Credit is controller memory, NOT another physical energy store. Its small
% negative startup debt is retained; no physical current/speed/energy clipping.
% Nominal electrical estimates and speed/current PI gains remain fixed.
% Actual perturbed parameters are used by the plant and validation only.
%
% Four pairs: 20 s task + 70 s recovery, with identical final physical stores.
% Three short diagnostics: no braking, high supply, and credit depletion.
% Historical legacy comparison uses the accepted native R2024a results.
% Provisional DC motor/devices, synthetic loads, ideal noiseless measurements.
% These selected cases are not hardware validation or universal savings proof.
% Spinning bypass baseline; the recovery-phase savings are included explicitly.
% Speed thresholds block direction; friction may still lower idle rotor speed.
% Motor power relations: https://www.mathworks.com/help/sps/ref/dcmotor.html

clock_start=tic;base=fileparts(mfilename('fullpath'));if isempty(base),base=pwd;end
stem=['EnergyDispatch_' datestr(now,'yyyymmdd_HHMMSS')];output_dir=fullfile(base,stem);suffix=0;
while exist(output_dir,'dir'),suffix=suffix+1;output_dir=fullfile(base,[stem '_' num2str(suffix)]);end
mkdir(output_dir);controller=parameters();cases=scenarios();R=cell(numel(cases),1);rows=cell(numel(cases),1);
fprintf('\nFYP recovery-credit / loss-aware dispatch\n11 cases; four common-terminal pairs.\nOutput: %s\n',output_dir);
for k=1:numel(cases)
 p=actual_parameters(cases(k).variant);[data,s]=simulate_case(cases(k),p);rows{k}=s;
 R{k}=struct('data',data,'summary',s,'case_definition',cases(k),'plant_parameters',p);
 writetable(array2table(data,'VariableNames',column_names()),fullfile(output_dir,[cases(k).name '.csv']));
 fprintf('%d/%d %s: final %.6f rpm, balance %.3g J, elapsed %.1f s\n', ...
  k,numel(cases),s.case_name,s.final_rpm,s.max_balance_J,toc(clock_start));
end
indices=[1 2;3 4;5 6;7 8];labels={'nominal','friction_high','combined_corner','pulse_combined'};pair_rows=cell(4,1);
for k=1:4,pair_rows{k}=compare_pair(R{indices(k,1)},R{indices(k,2)},labels{k});end
pairs=vertcat(pair_rows{:});checks=check_results(R,pairs,controller);legacy=native_legacy_totals();
comparison=table(labels(1:3)',legacy(:,3),[pairs(1:3).matched_source_reduction_J]', ...
 legacy(:,2)-[R{2}.summary.total_source_J;R{4}.summary.total_source_J;R{6}.summary.total_source_J], ...
 'VariableNames',{'pair','accepted_native_legacy_saving_J','new_saving_J','source_reduction_vs_legacy_J'});
report=struct('execution','Native MATLAB energy-dispatch run','build','2026-09-21 energy dispatch v1', ...
 'MATLABVersion',version,'created',datestr(now,31),'controller',controller, ...
 'passed',sum([checks.passed]),'count',numel(checks),'all_passed',all([checks.passed]), ...
 'tests',checks,'comparisons',pairs,'legacy_comparison',table2struct(comparison), ...
 'summaries',vertcat(rows{:}),'elapsed_s',toc(clock_start));
report.caveats={'All controller parameters fixed; supply reference is the initial measured bus voltage'; ...
 'Credit is conservative estimated work, not actual physical stored energy'; ...
 'Common-terminal savings include 70 s restoration and a spinning bypass baseline'; ...
 'Selected provisional parameters and synthetic loads; noiseless measurements; no hardware validation'};
writetable(struct2table(vertcat(rows{:})),fullfile(output_dir,'summary.csv'));
writetable(struct2table(pairs),fullfile(output_dir,'comparisons.csv'));
writetable(comparison,fullfile(output_dir,'legacy_comparison.csv'));
write_json(fullfile(output_dir,'tests_summary.json'),report);
save(fullfile(output_dir,'complete_results.mat'),'controller','cases','R','report');
make_plots(R,pairs,legacy,output_dir);
copyfile([mfilename('fullpath') '.m'],fullfile(output_dir,'SourceSnapshot.m'));
files=dir(output_dir);files=files(~[files.isdir]);zip(fullfile(output_dir,'ReviewBundle.zip'),{files.name},output_dir);
fprintf('\nChecks passed: %d / %d\nSend this file for review:\n%s\n', ...
 report.passed,report.count,fullfile(output_dir,'ReviewBundle.zip'));
if ~report.all_passed,error('FYP:CheckFailed','Inspect tests_summary.json; send ReviewBundle.zip.');end
end

function cases=scenarios()
rail=embedded_train_profile();pulse=[0 2 0;2 2 300;4 4 -400;8 2 0;10 4 250;14 4 -250;18 2 250];
traction=rail;traction(:,3)=max(traction(:,3),0);depleted=[0 1 0;1 1 -120;2 18 300];
names={'01_nominal_bypass','02_nominal_dispatch','03_friction_bypass','04_friction_dispatch', ...
 '05_combined_bypass','06_combined_dispatch','07_pulse_bypass','08_pulse_dispatch', ...
 '09_no_regeneration','10_high_source','11_credit_depletion'};
variants=[0 0 1 1 2 2 2 2 2 8 2];
for k=1:numel(names)
 p=actual_parameters(variants(k));on=~ismember(k,[1 3 5 7]);restore=70;profile=rail;
 if ismember(k,[7 8]),profile=pulse;end
 if k>=9,restore=0;end
 if k==9,profile=traction;elseif k==11,profile=depleted;end
 cases(k)=struct('name',names{k},'profile',profile,'on',on,'block',false,'stiff',false, ...
  'fixture',false,'pwm',false,'task',20,'restore',restore,'n0',3000,'V0',p.Vs, ...
  'substeps',1,'speed_pi',true,'variant',variants(k)); %#ok<AGROW>
end
end

function p=actual_parameters(variant)
p=parameters();
switch variant
 case 1,p.b=.0015;p.Tc=.075;
 case 2
  p.R=1;p.L=.014;p.J=.65;p.b=.0015;p.Tc=.075;p.Ron=.03;p.Rd=.015;p.Vf=.8;
  p.td=2e-6;p.Vs=57;p.Rs=.45;p.C=.08;
 case 3,p.R=1;
 case 4,p.L=.014;
 case 5,p.L=.026;
 case 6,p.J=.65;
 case 7,p.Vs=57;p.Rs=.45;p.C=.08;
 case 8,p.Vs=63;p.Rs=.2;p.C=.12;
 case 9,p.td=2e-6;
end
end

function p=parameters()
p=struct('R',.8,'L',.02,'Ke',.05,'Kt',.05,'J',.51,'b',.001,'Tc',.05,'Ron',.02,'Rd',.01,'Vf',.7, ...
 'td',1e-6,'ton',50e-9,'toff',50e-9,'Ceq',600e-12,'Qg',30e-9,'Vg',10,'blend',.5, ...
 'Vs',60,'Rs',.3,'C',.1,'fsw',20000,'outer',.01,'Imax',20,'nmin',2850,'nmax',3150, ...
 'soft',20,'hyst',5,'Vcharge',61,'Vdischarge',59.5,'Kg',80,'chop_on',68,'chop_band',2,'Rchop',6, ...
 'Kp',.02*2*pi*200,'Ki',.82*2*pi*200,'restore_gain',4,'restore_rpm',3000);
p.credit_decay=.02;p.credit_margin=.9;p.credit_reserve=5;p.credit_time=.2;p.loss_fraction=.25;
p.speed_Kp=(2*.5*p.J-p.b)/p.Kt;p.speed_Ki=.25*p.J/p.Kt;
assert(p.Ke==p.Kt && p.R>0 && p.L>0 && p.J>0 && p.C>0 && 2.2*p.td*p.fsw<.5);
end
function q=energy(y,p)
q=.5*p.J*y(2)^2+.5*p.L*y(1)^2+.5*p.C*y(3)^2;
end
function q=losses(y)
q=y(5)+sum(y(7:11));
end
function q=balance(y,p,E0)
q=energy(y,p)-E0-y(4)+y(6)+losses(y);
end
function ref=fixture_reference(t)
if t<.02-1e-11,ref=0;elseif t<.08-1e-11,ref=15;elseif t<.14-1e-11,ref=-8;elseif t<.18-1e-11,ref=0;else,ref=10;end
end
function u=outer_control(y,load,t,p,c,u,restoring)
% u = [current reference, requested/estimated power, high/low limits, gate block].
n=y(2)*60/(2*pi);if n>=p.nmax,u(4)=1;elseif n<=p.nmax-p.hyst,u(4)=0;end
if n<=p.nmin,u(5)=1;elseif n>=p.nmin+p.hyst,u(5)=0;end
u(6)=double(c.block && t>=5 && t<6);u(1:3)=0;emf=p.Ke*y(2);Rt=p.R+p.Ron;raw_speed=0;speed_error=p.restore_rpm*2*pi/60-y(2);
if restoring
 gain=p.restore_gain;integral=0;if c.speed_pi,gain=p.speed_Kp;integral=u(7);end
 raw_speed=(p.b*y(2)+p.Tc)/p.Kt+gain*speed_error+integral;
 u(1)=max(-p.Imax,min(p.Imax,raw_speed));
elseif c.on && ~u(6)
 charge_threshold=min(67,max(64,u(12)+1));discharge_threshold=u(12)-.5;
 if load<0 && y(3)>charge_threshold,u(2)=min(-load,p.Kg*(y(3)-charge_threshold));
 elseif load>0 && y(3)<discharge_threshold,u(2)=-min(load,p.Kg*(discharge_threshold-y(3)));end
 target=max(-.98*emf^2/(4*Rt),min(u(2),Rt*p.Imax^2+emf*p.Imax));
 u(1)=2*target/(emf+sqrt(max(0,emf^2+4*Rt*target)));
 if u(1)<0,u(1)=-min([-u(1) p.loss_fraction*emf/Rt max(0,u(8)-p.credit_reserve)/(emf*p.credit_time)]);end
end
if u(1)>0,u(1)=u(1)*max(0,min(1,(p.nmax-n)/p.soft))*double(~u(4));
elseif u(1)<0,u(1)=u(1)*max(0,min(1,(n-p.nmin)/p.soft))*double(~u(5));end
if restoring && c.speed_pi
 if abs(raw_speed-u(1))<1e-10 || (raw_speed>u(1) && speed_error<0) || (raw_speed<u(1) && speed_error>0)
  u(7)=u(7)+p.outer*p.speed_Ki*speed_error;
 end
end
u(3)=(emf+Rt*u(1))*u(1);if restoring,u(2)=u(3);end
end

function [phases,g]=gate_schedule(start,finish,d,enabled,g,p)
% g=[gate, desired, pending turn-on time, last turn-off time].
if ~enabled,cmd=[start -1];elseif d==0 || d==1,cmd=[start d];
else,cmd=[start 0;start+(1-d)*(finish-start)/2 1;start+(1+d)*(finish-start)/2 0];end
phases=zeros(8,5);count=0;now_t=start;j=1;
while now_t<finish-1e-15
 off=-1;on=-1;
 while j<=size(cmd,1) && cmd(j,1)<=now_t+1e-15
  target=cmd(j,2);j=j+1;
  if target~=g(2)
   if g(1)>=0,off=g(1);g(1)=-1;g(4)=now_t;end
   g(2)=target;if target<0,g(3)=inf;else,g(3)=max(now_t,g(4)+p.td);end
  end
 end
 if g(3)<=now_t+1e-15,on=g(2);g(1)=g(2);g(3)=inf;end
 next_command=inf;if j<=size(cmd,1),next_command=cmd(j,1);end
 next=min([finish g(3) next_command]);assert(next>now_t,'Nonpositive gate segment.');
 count=count+1;phases(count,:)=[now_t next g(1) off on];now_t=next;
end
phases=phases(1:count,:);
end
function q=current_moments(i,h,offset,rd,w,p)
% Constant-bus/speed affine electrical solution; stable phi-function series.
a=(p.R+rd)/p.L;s=(offset-p.Ke*w)/p.L-a*i;z=a*h;
assert(z<=.01,'Electrical moment series outside bounded domain.');
f1=1+z*(-.5+z*(1/6+z*(-1/24+z*(1/120+z*(-1/720+z/5040)))));
f2=.5+z*(-1/6+z*(1/24+z*(-1/120+z*(1/720+z*(-1/5040+z/40320)))));
f3=1/3+z*(-.25+z*(7/60+z*(-1/24+z*(31/2520+z*(-1/320+z*127/181440)))));
q=[i+s*h*f1;i*h+s*h*h*f2;i*i*h+2*i*s*h*h*f2+s*s*h*h*h*f3];
end
function h=zero_time(i,offset,rd,w,p)
a=(p.R+rd)/p.L;eq=(offset-p.Ke*w)/(p.R+rd);h=-log1p(-i/(i-eq))/a;
end
function e=event_heat(i,w,v,on,device,p)
tr=0;oss=0;drive=0;
if on
 if i>0,pole=-p.Vf-p.Rd*i;elseif i<0,pole=v+p.Vf-p.Rd*i;else,pole=p.Ke*w;end
 if device==1,blocking=max(0,v-pole);else,blocking=max(0,pole);end
 tr=.5*blocking*abs(i)*p.ton;oss=.5*p.Ceq*blocking^2;drive=p.Qg*p.Vg;
elseif (device==1 && i>0)||(device==0 && i<0)
 tr=.5*v*abs(i)*p.toff;
end
e=[tr;oss;drive];
end
function m=map_event(m,on,device,w,v,p)
e=event_heat(m(1),w,v,on,device,p);m(9:11)=m(9:11)+e;m(12)=m(12)+sum(e);
end
function m=electrical_piece(m,h,gate,w,v,p)
% m=[i,Q,Q2,Wport,Wterminal,Wem,Wchannel,Wdiode,Wtransition,Woss,Wgate,Win,Wout,maxi,zeros].
assert(p.Ke*w>0 && p.Ke*w<v,'Floating mode outside EMF domain.');
if gate>=0,mode=gate;elseif m(1)>0,mode=2;elseif m(1)<0,mode=3;else,mode=4;end
if mode==4,return;end
if mode==0,offset=0;elseif mode==1,offset=v;elseif mode==2,offset=-p.Vf;else,offset=v+p.Vf;end
if mode<=1,rd=p.Ron;else,rd=p.Rd;end
i0=m(1);q=current_moments(i0,h,offset,rd,w,p);
if mode>=2 && i0*q(1)<=0
 h=zero_time(i0,offset,rd,w,p);q=current_moments(i0,h,offset,rd,w,p);q(1)=0;m(15)=m(15)+1;
end
m(1)=q(1);m(2)=m(2)+q(2);m(3)=m(3)+q(3);m(14)=max([m(14) abs(i0) abs(m(1))]);
m(5)=m(5)+offset*q(2)-rd*q(3);m(6)=m(6)+p.Ke*w*q(2);
if mode<=1,m(7)=m(7)+p.Ron*q(3);
else,sgn=-1;if mode==2,sgn=1;end;m(8)=m(8)+sgn*p.Vf*q(2)+p.Rd*q(3);end
if mode==1 || mode==3
 m(4)=m(4)+v*q(2);
 if i0*q(1)<0
  hz=zero_time(i0,offset,rd,w,p);first=current_moments(i0,hz,offset,rd,w,p);second=q(2)-first(2);
  m(12)=m(12)+v*(max(first(2),0)+max(second,0));m(13)=m(13)+v*(max(-first(2),0)+max(-second,0));
 else
  m(12)=m(12)+v*max(q(2),0);m(13)=m(13)+v*max(-q(2),0);
 end
end
end
function m=electrical_map(i,w,v,phases,a,b,p)
m=zeros(15,1);m(1)=i;m(14)=abs(i);
for j=1:size(phases,1)
 ph=phases(j,:);left=max(a,ph(1));right=min(b,ph(2));if right<=left,continue;end
 if ph(1)>=a && ph(1)<b
  if ph(4)>=0,m=map_event(m,false,ph(4),w,v,p);end
  if ph(5)>=0,m=map_event(m,true,ph(5),w,v,p);end
 end
 m=electrical_piece(m,right-left,ph(3),w,v,p);
end
end
function [power,idx]=load_at(profile,t,idx)
while idx<size(profile,1) && profile(idx+1,1)<=t+1e-11,idx=idx+1;end
power=profile(idx,3);
end
function [q,idx]=load_integrals(c,a,b,restoring,idx)
q=zeros(3,1);if restoring || c.stiff,return;end
while a<b-1e-15
 [power,idx]=load_at(c.profile,a,idx);right=b;
 if idx<size(c.profile,1),right=min(right,c.profile(idx+1,1));end
 assert(right>a,'Load edge error.');q=q+(right-a)*[power;max(power,0);max(-power,0)];a=right;
end
end
function [y,s]=midpoint_step(y,a,b,ph,load,p,stiff,s)
h=b-a;w0=y(2);v0=y(3);wg=w0;vg=v0;converged=false;
for it=1:10
 wm=(w0+wg)/2;vm=(v0+vg)/2;m=electrical_map(y(1),wm,vm,ph,a,b,p);
 fess=m(4)+sum(m(9:11));
 if stiff,is=0;chop=0;
 else,is=max((p.Vs-vm)/p.Rs,0);chop=max(0,min(1,(vm-p.chop_on)/p.chop_band))*vm^2/p.Rchop;end
 wn=(w0*(1-p.b*h/(2*p.J))+(p.Kt*m(2)-p.Tc*h)/p.J)/(1+p.b*h/(2*p.J));
 if stiff,vn=v0;else,vn=v0+(vm*is*h-load(1)-fess-chop*h)/(p.C*vm);end
 defect=max(abs(wn-wg),abs(vn-vg));wg=wn;vg=vn;
 if defect<=5e-13,converged=true;break;end
end
assert(converged && vn>40 && vn<85 && wn>0,'Midpoint solve/domain failure.');
event=sum(m(9:11));fess=m(4)+event;
if stiff,source=fess;line=0;else,source=p.Vs*is*h;line=p.Rs*is^2*h;end
inc=[0;0;0;source;line;load(1);chop*h;m(7)+m(8)+event;p.R*m(3); ...
 p.b*wm^2*h;p.Tc*wm*h;fess;m(12);m(13);load(2);load(3);m(2);m(7);m(8);m(9:11);m(5);m(6)];
y=y+inc;y(1:3)=[m(1);wn;vn];
s.zero_events=s.zero_events+m(15);s.max_current_A=max(s.max_current_A,m(14));
s.max_midpoint_iterations=max(s.max_midpoint_iterations,it);s.midpoint_defect=max(s.midpoint_defect,defect);
end

function dy=pwm_rhs(y,mode,load,p,stiff)
i=y(1);w=y(2);v=y(3);port=0;ch=0;diode=0;
switch mode
 case 0,va=-p.Ron*i;ch=p.Ron*i^2;
 case 1,va=v-p.Ron*i;port=v*i;ch=p.Ron*i^2;
 case 2,va=-p.Vf-p.Rd*i;diode=p.Vf*i+p.Rd*i^2;
 case 3,va=v+p.Vf-p.Rd*i;port=v*i;diode=-p.Vf*i+p.Rd*i^2;
 otherwise,va=p.Ke*w;
end
if stiff,source=port;line=0;chop=0;dv=0;
else
 is=max((p.Vs-v)/p.Rs,0);source=p.Vs*is;line=p.Rs*is^2;
 chop=max(0,min(1,(v-p.chop_on)/p.chop_band))*v^2/p.Rchop;dv=(v*is-load-port-chop)/(p.C*v);
end
if mode==4,di=0;else,di=(va-p.R*i-p.Ke*w)/p.L;end
dy=[di;(p.Kt*i-p.b*w-p.Tc)/p.J;dv;source;line;load;chop;ch+diode; ...
 p.R*i^2;p.b*w^2;p.Tc*w;port;max(port,0);max(-port,0);max(load,0);max(-load,0);i;ch;diode;0;0;0;va*i;p.Ke*w*i];
end
function z=rk4(y,h,mode,load,p,stiff)
a=pwm_rhs(y,mode,load,p,stiff);b=pwm_rhs(y+h*a/2,mode,load,p,stiff);
c=pwm_rhs(y+h*b/2,mode,load,p,stiff);d=pwm_rhs(y+h*c,mode,load,p,stiff);z=y+h*(a+2*b+2*c+d)/6;
end
function y=pwm_event(y,on,device,p,stiff)
e=event_heat(y(1),y(2),y(3),on,device,p);total=sum(e);
if stiff,y(4)=y(4)+total;else,y(3)=sqrt(y(3)^2-2*total/p.C);end
y(8)=y(8)+total;y(12)=y(12)+total;y(13)=y(13)+total;y(20:22)=y(20:22)+e;
end
function [y,idx,s]=pwm_period(y,phases,p,c,idx,s)
for j=1:size(phases,1)
 ph=phases(j,:);if ph(4)>=0,y=pwm_event(y,false,ph(4),p,c.stiff);end
 if ph(5)>=0,y=pwm_event(y,true,ph(5),p,c.stiff);end
 now_t=ph(1);
 while now_t<ph(2)-1e-15
  if c.stiff,load=0;else,[load,idx]=load_at(c.profile,now_t,idx);end
  finish=min(ph(2),now_t+1/p.fsw/16);
  if ~c.stiff && idx<size(c.profile,1),finish=min(finish,c.profile(idx+1,1));end
  h=finish-now_t;
  if ph(3)>=0,mode=ph(3);elseif y(1)>0,mode=2;elseif y(1)<0,mode=3;else,mode=4;end
  z=rk4(y,h,mode,load,p,c.stiff);
  if mode>=2 && mode<=3 && y(1)*z(1)<=0
   lo=0;hi=h;
   for n=1:42
    mid=(lo+hi)/2;v=rk4(y,mid,mode,load,p,c.stiff);if y(1)*v(1)>0,lo=mid;else,hi=mid;end
   end
   root=(lo+hi)/2;z=rk4(y,root,mode,load,p,c.stiff);z(1)=0;z=rk4(z,h-root,4,load,p,c.stiff);s.zero_events=s.zero_events+1;
  end
  y=z;s.max_current_A=max(s.max_current_A,abs(y(1)));now_t=finish;
 end
end
end

function s=observe(y,u,p,E0,s)
s.max_balance_J=max(s.max_balance_J,abs(balance(y,p,E0)));s.max_reference_A=max(s.max_reference_A,abs(u(1)));
s.Vmin=min(s.Vmin,y(3));s.Vmax=max(s.Vmax,y(3));s.nmin=min(s.nmin,y(2)*60/(2*pi));s.nmax=max(s.nmax,y(2)*60/(2*pi));
if u(4),s.high_direction_error_A=max(s.high_direction_error_A,max(u(1),0));end
if u(5),s.low_direction_error_A=max(s.low_direction_error_A,max(-u(1),0));end
if u(6),s.blocked_reference_A=max(s.blocked_reference_A,abs(u(1)));end
s.ledger_split_error_J=max(s.ledger_split_error_J,abs(y(12)-y(13)+y(14)));
s.device_split_error_J=max(s.device_split_error_J,abs(y(8)-sum(y(18:22))));
end
function row=make_row(t,y,load,u,duty,xi,imeas,p,E0,restore,connected)
row=[t y' load u(1:6) duty xi imeas y(2)*60/(2*pi) .5*p.J*y(2)^2 .5*p.L*y(1)^2 .5*p.C*y(3)^2 balance(y,p,E0) double(restore) double(connected) u(7) u(8:12)];
end
function [data,s]=simulate_case(c,p)
controller=parameters(); % Fixed NOMINAL parameters; no access to actual parameter changes.
Ts=1/p.fsw;finish=c.task+c.restore;cycles=round(finish/Ts);task_ticks=round(c.task/Ts);outer_ticks=round(p.outer/Ts);
assert(abs(cycles*Ts-finish)<1e-9);log_ticks=outer_ticks;if c.fixture,log_ticks=1;end
y=zeros(24,1);y(2)=c.n0*2*pi/60;y(3)=c.V0;E0=energy(y,p);task_y=y;settle_y=y;
g=[-1 -1 inf 0];if c.on && ~c.block,g=[0 0 inf 0];end
u=[0 0 0 double(c.n0>=p.nmax) double(c.n0<=p.nmin) 0 0 0 0 0 0 y(3)];xi=0;imeas=0;d=0;idx=1;count=0;
data=zeros(ceil(cycles/log_ticks)+2,numel(column_names()));
s=struct('case_name',c.name,'task_s',c.task,'restore_s',c.restore,'max_balance_J',0, ...
 'max_current_A',0,'max_reference_A',0,'Vmin',c.V0,'Vmax',c.V0,'nmin',c.n0,'nmax',c.n0, ...
 'high_direction_error_A',0,'low_direction_error_A',0,'blocked_reference_A',0, ...
 'block_entry_i_A',0,'block_end_i_A',0,'zero_events',0,'max_midpoint_iterations',0, ...
 'midpoint_defect',0,'ledger_split_error_J',0,'device_split_error_J',0);
for k=0:cycles-1
 t=k*Ts;restoring=k>=task_ticks;connected=c.on||restoring;
 if k==task_ticks,task_y=y;end
 if k==cycles-round(1/Ts),settle_y=y;end
 if restoring || c.stiff,load=0;else,[load,idx]=load_at(c.profile,t,idx);end
 if c.fixture,u(1)=fixture_reference(t);u(3)=(p.Ke*y(2)+(p.R+p.Ron)*u(1))*u(1);
 elseif mod(k,outer_ticks)==0,u=outer_control(y,load,t,controller,c,u,restoring);end
 if c.block && k==round(5/Ts),s.block_entry_i_A=y(1);end
 if c.block && k==round(6/Ts),s.block_end_i_A=y(1);end
 enabled=connected && ~u(6);
 if enabled
  err=u(1)-imeas;delta=controller.td/Ts;
  raw=controller.Ke*y(2)+(controller.R+controller.Ron)*u(1)+controller.Kp*err+xi+ ...
   delta*(y(3)+2*controller.Vf)*max(-1,min(1,imeas/controller.blend))+2*delta*(controller.Rd-controller.Ron)*imeas;
  d=max(0,min(1,raw/y(3)));
  if (raw>=0 && raw<=y(3))||(raw>y(3) && err<0)||(raw<0 && err>0),xi=xi+Ts*controller.Ki*err;end
  minimum=2.2*p.td/Ts;if d>0 && d<minimum,d=0;elseif d>1-minimum && d<1,d=1;end
 else,d=0;end
 s=observe(y,u,p,E0,s);
 if mod(k,log_ticks)==0,count=count+1;data(count,:)=make_row(t,y,load,u,d,xi,imeas,p,E0,restoring,connected);end
 [phases,g]=gate_schedule(t,(k+1)*Ts,d,enabled,g,p);q0=y(17);w_before=y(2);
 if c.pwm,[y,idx,s]=pwm_period(y,phases,p,c,idx,s);
 else
  for sub=0:c.substeps-1
   a=t+sub*Ts/c.substeps;b=t+(sub+1)*Ts/c.substeps;
   [q,idx]=load_integrals(c,a,b,restoring,idx);[y,s]=midpoint_step(y,a,b,phases,q,p,c.stiff,s);
  end
 end
 imeas=(y(17)-q0)/Ts;
 if ~restoring && c.on
  work=controller.Ke*.5*(w_before+y(2))*imeas*Ts;gain=0;
  if load<0 && u(1)>0,gain=controller.credit_margin*max(work,0);end
  used=max(-work,0);leak=controller.credit_decay*max(u(8),0)*Ts;
  u(8)=u(8)+gain-used-leak;u(9)=u(9)+gain;u(10)=u(10)+used;u(11)=u(11)+leak;
 end
 s=observe(y,u,p,E0,s);
end
if c.restore==0,task_y=y;end
count=count+1;data(count,:)=make_row(finish,y,load,u,d,xi,imeas,p,E0,restoring,connected);data=data(1:count,:);
assert(all(isfinite(data(:))),'Nonfinite plant/controller state.');
target_i=(p.b*p.restore_rpm*2*pi/60+p.Tc)/p.Kt;
s.task_source_J=task_y(4);s.restore_source_J=y(4)-task_y(4);s.total_source_J=y(4);s.total_losses_J=losses(y);
s.task_chopper_J=task_y(7);s.task_charge_J=task_y(13);s.task_return_J=task_y(14);s.load_J=y(6);
s.channel_J=y(18);s.diode_J=y(19);s.transition_J=y(20);s.oss_J=y(21);s.gate_J=y(22);
s.final_rpm=y(2)*60/(2*pi);s.final_i_A=y(1);s.final_V=y(3);
s.target_rpm_error=abs(s.final_rpm-p.restore_rpm);s.target_mean_current_error_A=abs(imeas-target_i);
s.final_second_store_drift_J=abs(.5*p.J*(y(2)^2-settle_y(2)^2))+ ...
 abs(.5*p.L*(y(1)^2-settle_y(1)^2))+abs(.5*p.C*(y(3)^2-settle_y(3)^2));
s.plant_R=p.R;s.plant_L=p.L;s.plant_J=p.J;s.plant_b=p.b;s.plant_Tc=p.Tc;
s.plant_Ron=p.Ron;s.plant_Rd=p.Rd;s.plant_Vf=p.Vf;s.plant_Vs=p.Vs;s.plant_Rs=p.Rs;s.plant_C=p.C;s.plant_deadtime_s=p.td;
s.controller_R=controller.R;s.controller_b=controller.b;s.controller_deadtime_s=controller.td;
s.controller_Kp=controller.Kp;s.controller_Ki=controller.Ki;s.speed_Kp=controller.speed_Kp;s.speed_Ki=controller.speed_Ki;
s.speed_pi_enabled=c.speed_pi;s.speed_integrator_A=u(7);
s.recovery_credit_J=u(8);s.credited_J=u(9);s.spent_J=u(10);s.leaked_J=u(11);s.initial_bus_V=u(12);
s.credit_decay_per_s=controller.credit_decay;s.credit_margin=controller.credit_margin;
s.credit_reserve_J=controller.credit_reserve;s.credit_time_s=controller.credit_time;s.loss_fraction=controller.loss_fraction;
end

function z=compare_pair(a,b,label)
da=a.data;db=b.data;sa=a.summary;sb=b.summary;
mismatch=sum(abs(da(end,37:39)-db(end,37:39)));drift=max(sa.final_second_store_drift_J,sb.final_second_store_drift_J);
duration=abs(da(end,1)-db(end,1));loadgap=sa.load_J-sb.load_J;saving=sa.total_source_J-sb.total_source_J;
store_delta=sum(da(end,37:39)-db(end,37:39));identity=abs(saving-(sa.total_losses_J-sb.total_losses_J)-store_delta-loadgap);
valid=mismatch<1e-4 && drift<1e-4 && duration<1e-9 && abs(loadgap)<1e-6 && ...
 max(sa.max_balance_J,sb.max_balance_J)<1e-4 && max(sa.target_rpm_error,sb.target_rpm_error)<1e-5 && ...
 max(sa.target_mean_current_error_A,sb.target_mean_current_error_A)<1e-6;
if valid,matched=saving;percent=100*saving/sa.total_source_J;else,matched=NaN;percent=NaN;end
z=struct('pair',label,'valid_common_terminal',valid,'task_raw_source_difference_J',sa.task_source_J-sb.task_source_J, ...
 'restore_extra_source_coupled_J',sb.restore_source_J-sa.restore_source_J,'matched_source_reduction_J',matched, ...
 'matched_reduction_percent',percent,'bypass_total_source_J',sa.total_source_J,'coupled_total_source_J',sb.total_source_J, ...
 'final_store_mismatch_J',mismatch,'paired_energy_identity_error_J',identity);
end

function checks=add(checks,name,value,limit)
assert(isscalar(value) && isscalar(limit));checks(end+1)=struct('name',name,'value',value,'limit',limit,'passed',isfinite(value)&&value<=limit);
end
function names=column_names()
names={'t_s','i_A','omega_rad_s','Vdc_V','Wsource_J','Wline_J','Wload_J','Wchopper_J','Wconverter_J', ...
 'Wcopper_J','Wviscous_J','Wcoulomb_J','Wfess_J','Wcharge_J','Wreturn_J','Wtraction_J','Wregen_J','Qcurrent_As', ...
 'Wchannel_J','Wdiode_J','Wtransition_J','Woss_J','Wgate_J','Wterminal_J','Wem_J','Pload_W','iref_A','Preq_W', ...
 'Ptarget_W','high_block','low_block','gate_blocked','duty','integrator_V','cycle_mean_i_A','rpm', ...
 'Erot_J','Emag_J','Ecap_J','residual_J','restore_active','connected','speed_integrator_A','recovery_credit_J','credited_J','spent_J','leaked_J','initial_bus_V'};
end
function write_json(path,value)
fid=fopen(path,'w','n','UTF-8');assert(fid>=0,'Cannot create JSON.');cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
function checks=check_results(R,pairs,controller)
checks=struct('name',{},'value',{},'limit',{},'passed',{});
for k=1:numel(R)
 d=R{k}.data;s=R{k}.summary;n=s.case_name;p=R{k}.plant_parameters;c=R{k}.case_definition;
 fields={'max_balance_J','high_direction_error_A','low_direction_error_A', ...
  'ledger_split_error_J','device_split_error_J','midpoint_defect'};limits=[1e-4 1e-10 1e-10 1e-7 1e-7 5e-13];
 for j=1:numel(fields),checks=add(checks,[n '.' fields{j}],s.(fields{j}),limits(j));end
 checks=add(checks,[n '.current_reference_excess_A'],max(0,s.max_reference_A-20),1e-10);
 checks=add(checks,[n '.current_peak_excess_A'],max(0,s.max_current_A-20.1),0);
 checks=add(checks,[n '.chopper_voltage_excess_V'],max(0,s.Vmax-70),1e-9);
 checks=add(checks,[n '.finite_data'],double(~all(isfinite(d(:)))),0);
 checks=add(checks,[n '.complete_horizon_s'],abs(d(end,1)-c.task-c.restore),1e-9);
 stores=.5*p.J*d(:,3).^2+.5*p.L*d(:,2).^2+.5*p.C*d(:,4).^2;
 loss=d(:,6)+sum(d(:,8:12),2);
 checks=add(checks,[n '.independent_energy_balance_J'],max(abs(stores-stores(1)-d(:,5)+d(:,7)+loss)),1e-4);
 checks=add(checks,[n '.converter_energy_identity_J'],max(abs(d(:,13)-d(:,24)-d(:,9))),1e-7);
 checks=add(checks,[n '.motor_energy_identity_J'],max(abs(d(:,24)-d(:,10)-d(:,25)-(d(:,38)-d(1,38)))),1e-7);
 checks=add(checks,[n '.nonreversible_source_energy'],max(0,-min(diff(d(:,5)))),1e-9);
 checks=add(checks,[n '.input_energy_J'],abs(s.load_J-sum(c.profile(:,2).*c.profile(:,3))),1e-6);
 checks=add(checks,[n '.initial_bus_measurement_V'],max(abs(d(:,48)-d(1,4))),1e-12);
 if s.restore_s>0
  fields={'target_rpm_error','target_mean_current_error_A','final_second_store_drift_J'};limits=[1e-5 1e-6 1e-4];
  for j=1:numel(fields),checks=add(checks,[n '.' fields{j}],s.(fields{j}),limits(j));end
  correction=((p.b-controller.b)*3000*2*pi/60+(p.Tc-controller.Tc))/controller.Kt;
  checks=add(checks,[n '.speed_integral_learns_friction_A'],abs(s.speed_integrator_A-correction),1e-5);
 end
 if c.on
  checks=add(checks,[n '.credit_ledger_J'],max(abs(d(:,44)-d(:,45)+d(:,46)+d(:,47))),1e-7);
  checks=add(checks,[n '.withdrawal_above_earned_credit_J'],max(0,max(d(:,46)-d(:,45))),1e-3);
  checks=add(checks,[n '.credit_above_regeneration_J'],max(0,max(d(:,45)-controller.credit_margin*d(:,17))),1e-7);
  task=d(:,1)<c.task-1e-9;before=task & d(:,45)<1e-8;
  checks=add(checks,[n '.no_initial_energy_discharge_command_A'],max([0;-d(before,27)]),1e-10);
  depleted=task & d(:,44)<=controller.credit_reserve;
  checks=add(checks,[n '.no_empty_credit_discharge_command_A'],max([0;-d(depleted,27)]),1e-10);
  generating=task & d(:,27)<-1e-8;
  actual_fraction=(p.R+p.Ron)*(-d(generating,27))./(p.Ke*d(generating,3));
  checks=add(checks,[n '.actual_resistive_fraction_excess'],max([0;actual_fraction-.35]),1e-10);
  if s.restore_s>0
   frozen=d(d(:,1)>=c.task,44:47);
   checks=add(checks,[n '.restoration_does_not_earn_credit_J'],max(max(abs(frozen-frozen(1,:)))),1e-10);
  end
 end
end
indices=[1 2;3 4;5 6;7 8];
for k=1:4
 a=R{indices(k,1)};b=R{indices(k,2)};z=pairs(k);n=z.pair;
 checks=add(checks,[n '.same_horizon_s'],abs(a.data(end,1)-b.data(end,1)),1e-9);
 checks=add(checks,[n '.same_load_J'],abs(a.summary.load_J-b.summary.load_J),1e-6);
 checks=add(checks,[n '.terminal_store_J'],z.final_store_mismatch_J,1e-4);
 checks=add(checks,[n '.energy_identity_J'],z.paired_energy_identity_error_J,2e-4);
 checks=add(checks,[n '.valid_common_terminal'],double(~z.valid_common_terminal),0);
 checks=add(checks,[n '.positive_matched_saving'],double(z.matched_source_reduction_J<=0),0);
end
fixture=native_baseline_fixture();fields={'i_A','rpm','Vdc_V','Wsource_J','Erot_J','Emag_J','Ecap_J','speed_integrator_A'};
columns=[2 36 4 5 37 38 39 43];
for k=[1 3 5]
 f=fixture(fixture(:,1)==k,:);d=R{k}.data(round(f(:,2)/.01)+1,:);
 for j=1:numel(fields)
  checks=add(checks,[R{k}.summary.case_name '.accepted_native_' fields{j}],max(abs(d(:,columns(j))-f(:,j+2))),1e-6);
 end
end
legacy=native_legacy_totals();
for k=1:3
 checks=add(checks,[pairs(k).pair '.improved_over_accepted_legacy'], ...
  double(R{2*k}.summary.total_source_J>=legacy(k,2)),0);
end
d=R{9}.data;s=R{9}.summary;
checks=add(checks,'no_braking.no_fess_command_A',max(abs(d(:,27))),1e-10);
checks=add(checks,'no_braking.no_credit_earned_J',s.credited_J,1e-12);
% Zero average torque still has real intraperiod PWM ripple (audited above).
checks=add(checks,'no_braking.cycle_mean_current_A',max(abs(d(:,35))),1e-3);
d=R{11}.data;cutoff=d(:,1)>=4 & d(:,26)>0 & d(:,44)<=controller.credit_reserve;
checks=add(checks,'depletion.recovery_and_discharge_exercised',double(max(d(:,45))<20 || max(d(:,46))<20),0);
checks=add(checks,'depletion.cutoff_exercised',double(~any(cutoff)),0);
checks=add(checks,'depletion.stops_current_after_cutoff_A',max([0;abs(d(cutoff,35))]),1e-3);
end

function make_plots(R,pairs,legacy,out)
fig=figure('Name','Energy dispatch comparisons','Color','w','Position',[60 60 1300 850]);
subplot(2,2,1);bar([legacy(:,3) [pairs(1:3).matched_source_reduction_J]']);
xticks(1:3);xticklabels({'Nominal','Friction +50%','Combined'});ylabel('J');grid on;
title('Matched-terminal source saving');legend({'Accepted legacy','Recovery credit'},'Location','best');
subplot(2,2,2);bar([pairs.matched_reduction_percent]);xticks(1:4);
xticklabels({'Nominal','Friction','Combined','Pulse combined'});ylabel('%');grid on;title('Source reduction: full 90 s horizon');
a=R{5}.data;b=R{6}.data;m=a(:,1)<=20;
subplot(2,2,3);plot(a(m,1),a(m,4),b(m,1),b(m,4));xlabel('Task time / s');ylabel('V');grid on;
title('Combined corner: DC bus');legend({'Bypass','Recovery credit'},'Location','best');
subplot(2,2,4);plot(a(:,1),a(:,5)-b(:,5));xline(20,':');xlabel('Time / s');ylabel('J');grid on;
title('Combined corner: source difference including recovery');
sgtitle('Provisional model | matched physical terminal stores | MATLAB');save_figure(fig,out,'dispatch_comparison');
fig=figure('Name','Recovered-work credit','Color','w','Position',[80 80 1250 820]);
d=R{6}.data;m=d(:,1)<20;
subplot(2,2,1);plot(d(m,1),d(m,44:46));xlabel('Task time / s');ylabel('J');grid on;
title('Combined corner: controller credit');legend({'Available credit','Credited work','Spent work'},'Location','best');
subplot(2,2,2);plot(d(m,1),d(m,27),d(m,1),d(m,35));xlabel('Task time / s');ylabel('A');grid on;
title('Combined corner: current');legend({'Reference','Cycle mean'},'Location','best');
d=R{11}.data;
subplot(2,2,3);plot(d(:,1),d(:,44));yline(5,':');xlabel('Task time / s');ylabel('J');grid on;
title('Short braking then long traction: credit depletion');
subplot(2,2,4);plot(d(:,1),d(:,27),d(:,1),d(:,35));xlabel('Task time / s');ylabel('A');grid on;
title('Discharge stops when credit reaches reserve');legend({'Reference','Cycle mean'},'Location','best');
sgtitle('Credit is controller memory; physical energy is audited separately');save_figure(fig,out,'recovery_credit');
end
function save_figure(fig,out,name)
savefig(fig,fullfile(out,[name '.fig']));exportgraphics(fig,fullfile(out,[name '.png']),'Resolution',150);
end

function data=embedded_train_profile()
data=[
0 0.034267200130838324 25.708535718338378 0 257085.35718338378;
0.034267200130838324 0.034267200130838324 37.129668369819576 0.5 371296.68369819573;
0.068534400261676648 0.034267200130838324 48.55724931146959 1 485572.49311469588;
0.10280160039251497 0.034267200130838324 59.99175385780044 1.5 599917.53857800434;
0.1370688005233533 0.034267200130838324 71.433657323324539 2 714336.57323324541;
0.17133600065419163 0.034267200130838324 82.883435022554877 2.5 828834.35022554873;
0.20560320078502994 0.034267200130838324 94.341562270002953 3 943415.62270002952;
0.23987040091586825 0.034267200130838324 105.80851438018168 3.5 1058085.1438018167;
0.27413760104670659 0.034267200130838324 117.28476666762066 4 1172847.6666762065;
0.30840480117754493 0.034267200130838324 128.77079444680083 4.5 1287707.9444680084;
0.34267200130838327 0.034267200130838324 140.26707303224671 5 1402670.7303224672;
0.37693920143922155 0.034267200130838324 151.77407773847432 5.5 1517740.7773847431;
0.41120640157005989 0.034267200130838324 163.29228387999478 6 1632922.8387999479;
0.44547360170089823 0.034267200130838324 174.82216677131896 6.5 1748221.6677131895;
0.47974080183173651 0.034267200130838324 186.36420172696134 7 1863642.0172696132;
0.5140080019625749 0.034267200130838324 197.91886406143308 7.5 1979188.6406143308;
0.54827520209341318 0.034267200130838324 209.48662908918189 8 2094866.2908918187;
0.58254240222425147 0.034267200130838324 221.0679721248448 8.5 2210679.7212484479;
0.61680960235508986 0.034267200130838324 232.6633684828777 9 2326633.6848287769;
0.65107680248592814 0.034267200130838324 244.27329347779045 9.5 2442732.9347779043;
0.68534400261676653 0.034267200130838324 255.89822242409178 10 2558982.2242409177;
0.71961120274760482 0.034267200130838324 267.53863063630166 10.5 2675386.3063630164;
0.7538784028784431 0.034267200130838324 279.19499342892544 11 2791949.9342892542;
0.78814560300928149 0.034267200130838324 290.86778611648157 11.5 2908677.8611648157;
0.82241280314011977 0.034267200130838324 299.53703526431696 12 2995370.3526431695;
0.85668000327095806 0.034267200130838324 299.99999999989421 12.5 2999999.999998942;
0.89094720340179645 0.034267200130838324 299.99999999988972 13 2999999.9999988973;
0.92521440353263473 0.034267200130838324 299.99999999987858 13.5 2999999.9999987856;
0.95948160366347301 0.034267200130838324 299.99999999988603 14 2999999.9999988601;
0.99374880379431141 0.034267200130838324 299.9999999998808 14.5 2999999.9999988079;
1.0280160039251498 0.034267200130838324 299.99999999986665 15 2999999.9999986663;
1.062283204055988 0.034267200130838324 299.99999999986738 15.5 2999999.9999986738;
1.0965504041868264 0.034267200130838324 299.99999999988529 16 2999999.9999988526;
1.1308176043176648 0.034267200130838324 299.999999999772 16.5 2999999.9999977201;
1.1650848044485029 0.034267200130838324 299.99999999973181 17 2999999.9999973178;
1.1993520045793413 0.034267200130838324 299.99999999969754 17.5 2999999.9999969751;
1.2336192047101797 0.034267200130838324 299.99999999971988 18 2999999.9999971986;
1.2678864048410179 0.034267200130838324 299.99999999969452 18.5 2999999.9999969453;
1.3021536049718563 0.034267200130838324 299.99999999971391 19 2999999.999997139;
1.3364208051026947 0.034267200130838324 299.99999999969009 19.5 2999999.9999969006;
1.3706880052335331 0.034267200130838324 299.99999999969606 20 2999999.9999969602;
1.4049552053643712 0.034267200130838324 299.99999999970942 20.5 2999999.9999970943;
1.4392224054952096 0.034267200130838324 299.99999999969901 21 2999999.99999699;
1.473489605626048 0.034267200130838324 185.32048013354094 21.5 1853204.8013354093;
1.5077568057568862 0.034267200130838324 34.337128186208012 22 343371.2818620801;
1.5420240058877246 0.034267200130838324 34.337128186208012 22.5 343371.2818620801;
1.576291206018563 0.034267200130838324 34.337128186208012 23 343371.2818620801;
1.6105584061494012 0.034267200130838324 34.337128186208012 23.5 343371.2818620801;
1.6448256062802395 0.034267200130838324 34.337128186209505 24 343371.281862095;
1.6790928064110779 0.034267200130838324 34.337128186208012 24.5 343371.2818620801;
1.7133600065419161 0.034267200130838324 34.337128186208012 25 343371.2818620801;
1.7476272066727545 0.034267200130838324 34.337128186208012 25.5 343371.2818620801;
1.7818944068035929 0.034267200130838324 34.337128186208012 26 343371.2818620801;
1.8161616069344311 0.034267200130838324 34.337128186209505 26.5 343371.281862095;
1.8504288070652695 0.034267200130838324 34.337128186208012 27 343371.2818620801;
1.8846960071961079 0.034267200130838324 34.337128186208012 27.5 343371.2818620801;
1.918963207326946 0.034267200130838324 34.337128186208012 28 343371.2818620801;
1.9532304074577844 0.034267200130838324 34.337128186208012 28.5 343371.2818620801;
1.9874976075886228 0.034267200130838324 34.337128186209505 29 343371.281862095;
2.0217648077194612 0.034267200130838324 34.337128186208012 29.5 343371.2818620801;
2.0560320078502996 0.034267200130838324 34.337128186208012 30 343371.2818620801;
2.0902992079811376 0.034267200130838324 34.337128186208012 30.5 343371.2818620801;
2.1245664081119759 0.034267200130838324 34.337128186209505 31 343371.281862095;
2.1588336082428143 0.034267200130838324 34.337128186208012 31.5 343371.2818620801;
2.1931008083736527 0.034267200130838324 34.337128186257182 32 343371.28186257184;
2.2273680085044911 0.034267200130838324 34.337128186257182 32.5 343371.28186257184;
2.2616352086353295 0.034267200130838324 34.337128186257182 33 343371.28186257184;
2.2959024087661679 0.034267200130838324 34.337128186257182 33.5 343371.28186257184;
2.3301696088970059 0.034267200130838324 34.337128186257182 34 343371.28186257184;
2.3644368090278443 0.034267200130838324 34.337128186255697 34.5 343371.28186255693;
2.3987040091586826 0.034267200130838324 60.04566390445531 35 600456.63904455304;
2.432971209289521 0.034267200130838324 71.466796555934849 35.5 714667.96555934846;
2.4672384094203594 0.034267200130838324 82.894377497570218 36 828943.77497570217;
2.5015056095511978 0.034267200130838324 94.328882043920458 36.5 943288.82043920457;
2.5357728096820358 0.034267200130838324 105.7707855094403 37 1057707.855094403;
2.5700400098128742 0.034267200130838324 117.22056320866049 37.5 1172205.6320866048;
2.6043072099437126 0.034267200130838324 128.6786904561028 38 1286786.9045610279;
2.638574410074551 0.034267200130838324 140.1456425662771 38.5 1401456.4256627709;
2.6728416102053894 0.034267200130838324 151.62189485374839 39 1516218.9485374838;
2.7071088103362277 0.034267200130838324 163.1079226329133 39.5 1631079.2263291329;
2.7413760104670661 0.034267200130838324 174.60420121835918 40 1746042.0121835917;
2.7756432105979041 0.034267200130838324 186.11120592460037 40.5 1861112.0592460036;
2.8099104107287425 0.034267200130838324 197.62941206610353 41 1976294.1206610352;
2.8441776108595809 0.034267200130838324 209.15929495742321 41.5 2091592.9495742321;
2.8784448109904193 0.034267200130838324 220.70132991307528 42 2207013.2991307527;
2.9127120111212577 0.034267200130838324 232.25599224754723 42.5 2322559.9224754721;
2.9469792112520961 0.034267200130838324 243.8237572753072 43 2438237.5727530718;
2.981246411382934 0.034267200130838324 255.4051003109515 43.5 2554051.0031095147;
3.0155136115137724 0.00034773508167239563 261.25965992233762 44 2612596.5992233763;
3.0158613465954449 0.033919465049165931 -67.277777689907666 44.00507387648166 -672777.77689907665;
3.0497808116446108 0.034267200130838324 -55.726706522211437 44.5 -557267.06522211432;
3.0840480117754492 0.034267200130838324 -43.865183961041275 45 -438651.83961041272;
3.1183152119062876 0.034267200130838324 -26.135719761697949 45.5 -261357.19761697948;
3.152582412037126 0.027071088103353725 -7.9841362466131907 46 -79841.362466131905;
3.1796535001404793 0.007196112027484599 2.1678438620740241 46.394999999999875 21678.438620740242;
3.1868496121679639 0.034267200130838324 14.465598209652306 46.5 144655.98209652305;
3.2211168122988023 0.034267200130838324 31.79737769919187 47 317973.77699191868;
3.2553840124296407 0.034267200130838324 40.939992167718714 47.5 409399.92167718709;
3.2896512125604791 0.034267200130838324 49.636376286801699 48 496363.76286801696;
3.3239184126913175 0.034267200130838324 58.34910978743136 48.5 583491.09787431359;
3.3581856128221559 0.034267200130838324 67.077807664859293 49 670778.07664859295;
3.3924528129529943 0.034267200130838324 75.822084914359451 49.5 758220.8491435945;
3.4267200130838322 0.034267200130838324 84.581556531092531 50 845815.56531092525;
3.4609872132146706 0.034267200130838324 93.35583751041294 50.5 933558.37510412931;
3.495254413345509 0.034267200130838324 102.14454284751118 51 1021445.4284751117;
3.5295216134763474 0.034267200130838324 110.94728753757775 51.5 1109472.8753757775;
3.5637888136071858 0.034267200130838324 119.76368657594324 52 1197636.8657594323;
3.5980560137380242 0.034267200130838324 128.59335495783091 52.5 1285933.5495783091;
3.6323232138688621 0.034267200130838324 137.43590767854155 53 1374359.0767854154;
3.6665904139997005 0.034267200130838324 146.29095973320008 53.5 1462909.5973320007;
3.7008576141305389 0.034267200130838324 155.15812611716689 54 1551581.2611716688;
3.7351248142613773 0.034267200130838324 164.03702182561159 54.5 1640370.2182561159;
3.7693920143922157 0.034267200130838324 172.92726185382307 55 1729272.6185382307;
3.8036592145230541 0.034267200130838324 181.82846119699181 55.5 1818284.611969918;
3.8379264146538921 0.034267200130838324 190.74023485037387 56 1907402.3485037386;
3.8721936147847305 0.019532304074709093 196.96305891573883 56.5 1969630.5891573883;
3.8917259188594397 0.014734896056129232 -63.456431720614113 56.785000000001915 -634564.31720614107;
3.9064608149155688 0.034267200130838324 -57.068906744655969 57 -570689.06744655967;
3.9407280150464072 0.034267200130838324 -48.1277201890409 57.5 -481277.20189040899;
3.9749952151772456 0.034267200130838324 -39.177499342256787 58 -391774.99342256784;
4.0092624153080836 0.034267200130838324 -30.218629208967091 58.5 -302186.2920896709;
4.0435296154389224 0.034267200130838324 -21.251494794008138 59 -212514.94794008136;
4.0777968155697604 0.034267200130838324 -12.276481102049351 59.5 -122764.81102049351;
4.1120640157005992 0.029646191192515207 -3.8999351526320463 60 -38999.351526320461;
4.141710206893114 0.0046210089383231148 0.59359037541403303 60.432573876466719 5935.9037541403295;
4.1463312158314372 0.034267200130838324 5.6956440936326986 60.5 56956.440936326981;
4.1805984159622751 0.034267200130838324 14.691985587882996 61 146919.85587882996;
4.2148656160931139 0.034267200130838324 23.694666340056063 61.5 236946.66340056062;
4.2491328162239519 0.034267200130838324 51.261594161391258 62 512615.94161391258;
4.2834000163547907 0.034267200130838324 54.337128186103705 62.5 543371.28186103702;
4.3176672164856287 0.034267200130838324 54.337128186124566 63 543371.28186124563;
4.3519344166164675 0.034267200130838324 54.337128186106682 63.5 543371.28186106682;
4.3862016167473055 0.034267200130838324 54.337128186139466 64 543371.28186139464;
4.4204688168781434 0.034267200130838324 54.337128186130528 64.5 543371.28186130524;
4.4547360170089823 0.034267200130838324 54.337128186121589 65 543371.28186121583;
4.4890032171398202 0.034267200130838324 54.33712818608582 65.5 543371.2818608582;
4.523270417270659 0.034267200130838324 54.337128186109666 66 543371.28186109662;
4.557537617401497 0.034267200130838324 54.337128186109666 66.5 543371.28186109662;
4.5918048175323358 0.034267200130838324 54.337128186273574 67 543371.28186273575;
4.6260720176631738 0.034267200130838324 54.337128186276558 67.5 543371.28186276555;
4.6603392177940117 0.034267200130838324 54.337128186276558 68 543371.28186276555;
4.6946064179248506 0.034267200130838324 54.337128186273574 68.5 543371.28186273575;
4.7288736180556885 0.034267200130838324 54.337128186276558 69 543371.28186276555;
4.7631408181865273 0.034267200130838324 54.337128186273574 69.5 543371.28186273575;
4.7974080183173653 0.034267200130838324 54.337128186276558 70 543371.28186276555;
4.8316752184482032 0.034267200130838324 54.337128186276558 70.5 543371.28186276555;
4.8659424185790421 0.034267200130838324 54.337128186273574 71 543371.28186273575;
4.90020961870988 0.034267200130838324 54.337128186276558 71.5 543371.28186276555;
4.9344768188407189 0.034267200130838324 54.337128186273574 72 543371.28186273575;
4.9687440189715568 0.034267200130838324 54.337128186276558 72.5 543371.28186276555;
5.0030112191023957 0.034267200130838324 54.337128186273574 73 543371.28186273575;
5.0372784192332336 0.034267200130838324 54.337128186276558 73.5 543371.28186276555;
5.0715456193640716 0.034267200130838324 54.337128186276558 74 543371.28186276555;
5.1058128194949104 0.034267200130838324 54.337128186273574 74.5 543371.28186273575;
5.1400800196257483 0.034267200130838324 54.337128186276558 75 543371.28186276555;
5.1743472197565872 0.034267200130838324 54.337128186273574 75.5 543371.28186273575;
5.2086144198874251 0.034267200130838324 54.337128186276558 76 543371.28186276555;
5.242881620018264 0.034267200130838324 54.337128186276558 76.5 543371.28186276555;
5.2771488201491019 0.034267200130838324 54.337128186273574 77 543371.28186273575;
5.3114160202799399 0.034267200130838324 54.337128186276558 77.5 543371.28186276555;
5.3456832204107787 0.034267200130838324 54.337128186273574 78 543371.28186273575;
5.3799504205416167 0.034267200130838324 54.337128186276558 78.5 543371.28186276555;
5.4142176206724555 0.00034773508167239563 54.337128186273368 79 543371.28186273365;
5.414565355754128 0.033919465049165931 -280.00000000025432 79.00507387648166 -2800000.000002543;
5.4484848208032934 0.034267200130838324 -280.00000000025631 79.5 -2800000.000002563;
5.4827520209341323 0.034267200130838324 -279.76340638533236 80 -2797634.0638533235;
5.5170192210649702 0.034267200130838324 -273.67435039800409 80.5 -2736743.5039800406;
5.5512864211958082 0.034267200130838324 -264.98901008889976 81 -2649890.1008889973;
5.585553621326647 0.034267200130838324 -249.54081526912751 81.5 -2495408.1526912749;
5.619820821457485 0.034267200130838324 -229.45652280604543 82 -2294565.2280604541;
5.6540880215883238 0.034267200130838324 -209.34861467222572 82.5 -2093486.1467222571;
5.6883552217191617 0.034267200130838324 -189.2170005582571 83 -1892170.005582571;
5.7226224218499997 0.034267200130838324 -169.06159015417398 83.5 -1690615.9015417397;
5.7568896219808385 0.034267200130838324 -148.88229315024614 84 -1488822.9315024614;
5.7911568221116765 0.034267200130838324 -128.67901923668086 84.5 -1286790.1923668087;
5.8254240222425153 0.034267200130838324 -108.45167810376586 85 -1084516.7810376585;
5.8596912223733533 0.034267200130838324 -88.200179441660651 85.5 -882001.79441660643;
5.8939584225041921 0.034267200130838324 -67.924432940736423 86 -679244.32940736413;
5.9282256226350301 0.034267200130838324 -47.624348291113975 86.5 -476243.48291113973;
5.962492822765868 0.034267200130838324 -27.299835183152556 87 -272998.35183152556;
5.9967600228967068 0.028789511189712517 -8.5784285318970266 87.5 -85784.285318970258;
6.0255495340864194 0.0054776889411258063 1.6036318079011038 87.920073876473552 16036.318079011038;
6.0310272230275448 0.034267200130838324 13.422837647107244 88 134228.37647107244;
6.0652944231583836 0.034267200130838324 33.821177988871931 88.5 338211.77988871932;
6.0995616232892216 0.034267200130838324 54.244308028075103 89 542443.08028075099;
6.1338288234200604 0.034267200130838324 74.692318074396255 89.5 746923.18074396253;
6.1680960235508984 0.034267200130838324 95.165298437705644 90 951652.98437705636;
6.2023632236817363 0.034267200130838324 115.66333942769468 90.5 1156633.3942769468;
6.2366304238125752 0.034267200130838324 136.18653135417404 91 1361865.3135417402;
6.2708976239434131 0.034267200130838324 156.73496452689469 91.5 1567349.6452689469;
6.3051648240742519 0.034267200130838324 177.30872925558984 92 1773087.2925558984;
6.3394320242050899 0.034267200130838324 197.90791585007608 92.5 1979079.1585007608;
6.3736992243359278 0.034267200130838324 218.53261461998821 93 2185326.146199882;
6.4079664244667667 0.034267200130838324 235.25386421615184 93.5 2352538.6421615183;
6.4422336245976046 0.034267200130838324 244.41137701982262 94 2444113.770198226;
6.4765008247284435 0.034267200130838324 253.38639071172477 94.5 2533863.9071172476;
6.5107680248592814 0.034267200130838324 262.36889867587388 95 2623688.9867587388;
6.5450352249901202 0.034267200130838324 271.35851590741277 95.5 2713585.1590741277;
6.5793024251209582 0.034267200130838324 280.35485740162733 96 2803548.574016273;
6.6135696252517961 0.034267200130838324 289.35753815380338 96.5 2893575.3815380335;
6.647836825382635 0.034267200130838324 316.9244659753889 97 3169244.6597538888;
6.6821040255134729 0.034267200130838324 320.00000000009538 97.5 3200000.0000009537;
6.7163712256443118 0.034267200130838324 319.99999999974671 98 3199999.9999974668;
6.7506384257751497 0.034267200130838324 319.99999999974369 98.5 3199999.999997437;
6.7849056259059886 0.034267200130838324 319.99999999973477 99 3199999.9999973476;
6.8191728260368265 0.034267200130838324 319.99999999974369 99.5 3199999.999997437;
6.8534400261676645 0.034267200130838324 319.99999999974671 100 3199999.9999974668;
6.8877072262985033 0.034267200130838324 319.99999999977354 100.5 3199999.999997735;
6.9219744264293412 0.034267200130838324 319.9999999997288 101 3199999.999997288;
6.9562416265601801 0.034267200130838324 319.99999999974074 101.5 3199999.9999974072;
6.990508826691018 0.034267200130838324 319.99999999971988 102 3199999.9999971986;
7.024776026821856 0.034267200130838324 319.9999999997288 102.5 3199999.999997288;
7.0590432269526948 0.034267200130838324 319.99999999973778 103 3199999.9999973774;
7.0933104270835328 0.034267200130838324 319.99999999975267 103.5 3199999.9999975264;
7.1275776272143716 0.034267200130838324 319.99999999974966 104 3199999.9999974966;
7.1618448273452096 0.034267200130838324 319.99999999971692 104.5 3199999.9999971688;
7.1961120274760484 0.034267200130838324 319.99999999973477 105 3199999.9999973476;
7.2303792276068863 0.034267200130838324 319.99999999970498 105.5 3199999.9999970496;
7.2646464277377243 0.034267200130838324 319.99999999969901 106 3199999.99999699;
7.2989136278685631 0.034267200130838324 319.99999999971391 106.5 3199999.999997139;
7.3331808279994011 0.034267200130838324 319.99999999971391 107 3199999.999997139;
7.3674480281302399 0.034267200130838324 319.99999999965729 107.5 3199999.9999965727;
7.4017152282610779 0.034267200130838324 156.82744996718168 108 1568274.4996718168;
7.4359824283919167 0.034267200130838324 58.723375688844925 108.5 587233.75688844919;
7.4702496285227546 0.034267200130838324 58.723375688844925 109 587233.75688844919;
7.5045168286535926 0.034267200130838324 58.723375688844925 109.5 587233.75688844919;
7.5387840287844314 0.034267200130838324 58.723375688844925 110 587233.75688844919;
7.5730512289152694 0.034267200130838324 58.723375688844925 110.5 587233.75688844919;
7.6073184290461082 0.034267200130838324 58.723375688841941 111 587233.75688841939;
7.6415856291769462 0.034267200130838324 58.723375688844925 111.5 587233.75688844919;
7.6758528293077841 0.034267200130838324 58.723375688844925 112 587233.75688844919;
7.710120029438623 0.034267200130838324 58.723375688844925 112.5 587233.75688844919;
7.7443872295694609 0.034267200130838324 58.723375688844925 113 587233.75688844919;
7.7786544297002997 0.034267200130838324 58.723375688844925 113.5 587233.75688844919;
7.8129216298311377 0.034267200130838324 58.723375688844925 114 587233.75688844919;
7.8471888299619765 0.034267200130838324 58.723375688844925 114.5 587233.75688844919;
7.8814560300928145 0.034267200130838324 58.723375688844925 115 587233.75688844919;
7.9157232302236524 0.034267200130838324 58.723375688844925 115.5 587233.75688844919;
7.9499904303544913 0.034267200130838324 58.781579452645779 116 587815.79452645779;
7.9842576304853292 0.034267200130838324 65.584748326596625 116.5 655847.48326596618;
8.0185248306161672 0.034267200130838324 77.006510447937259 117 770065.1044793725;
8.0527920307470069 0.034267200130838324 88.434768848830473 117.5 884347.68848830462;
8.0870592308778448 0.034267200130838324 99.869998843732475 118 998699.98843732476;
8.1213264310086828 0.034267200130838324 111.31267574715615 118.5 1113126.7574715614;
8.1555936311395207 0.034267200130838324 122.76327487368883 119 1227632.7487368882;
8.1898608312703587 0.034267200130838324 134.22227153773903 119.5 1342222.7153773904;
8.2241280314011984 0.034267200130838324 145.69014105389417 120 1456901.4105389416;
8.2583952315320364 0.034267200130838324 157.16735873665513 120.5 1571673.5873665512;
8.2926624316628743 0.034267200130838324 168.65439990051092 121 1686543.9990051091;
8.3269296317937123 0.034267200130838324 180.15173985996546 121.5 1801517.3985996544;
8.3611968319245502 0.034267200130838324 191.65985392956733 122 1916598.5392956734;
8.3954640320553899 0.034267200130838324 203.17921742379667 122.5 2031792.1742379665;
8.4297312321862279 0.034267200130838324 214.71030565721395 123 2147103.0565721393;
8.4639984323170658 0.034267200130838324 226.25359394426346 123.5 2262535.9394426346;
8.4982656324479038 0.034267200130838324 237.80955759950282 124 2378095.575995028;
8.5325328325787435 0.034267200130838324 249.37867193738222 124.5 2493786.7193738222;
8.5668000327095815 0.034267200130838324 260.96141227250695 125 2609614.1227250695;
8.6010672328404194 0.034267200130838324 272.55825391929153 125.5 2725582.539192915;
8.6353344329712574 0.034267200130838324 284.16967219238876 126 2841696.7219238877;
8.6696016331020953 0.034267200130838324 295.79614240621925 126.5 2957961.4240621924;
8.703868833232935 0.0085463434410577195 303.06639600700811 127 3030663.9600700811;
8.7124151766739928 0.025720856689780604 -29.83262383465275 127.12470151352352 -298326.23834652751;
8.738136033363773 0.034267200130838324 -19.627235774767399 127.5 -196272.35774767399;
8.7724032334946109 0.034267200130838324 -7.9527578515887267 128 -79527.57851588726;
8.8066704336254489 0.034267200130838324 -0.19037838874459267 128.5 -1903.7838874459267;
8.8409376337562868 0.034267200130838324 0 129 0;
8.8752048338871266 0.034267200130838324 0 129.5 0;
8.9094720340179645 0.034267200130838324 0 130 0;
8.9437392341488025 0.034267200130838324 0 130.5 0;
8.9780064342796404 0.019169175481358613 0 131 0;
8.9971756097609994 0.015098024649479713 1.8882434198085074 131.27970151351974 18882.434198085073;
9.0122736344104784 0.034267200130838324 8.0943670667171475 131.5 80943.670667171478;
9.0465408345413181 0.034267200130838324 16.725205717414617 132 167252.05717414618;
9.080808034672156 0.034267200130838324 25.373854769921305 132.5 253738.54769921303;
9.115075234802994 0.034267200130838324 34.039929219412805 133 340399.29219412804;
9.1493424349338319 0.034267200130838324 42.723044061338904 133.5 427230.44061338902;
9.1836096350646717 0.034267200130838324 51.422814290606979 134 514228.14290606976;
9.2178768351955096 0.034267200130838324 60.138854902642969 134.5 601388.54902642965;
9.2521440353263475 0.034267200130838324 68.870780892652277 135 688707.80892652273;
9.2864112354571855 0.034267200130838324 77.618207256031042 135.5 776182.07256031036;
9.3206784355880234 0.034267200130838324 86.380748987793922 136 863807.48987793922;
9.3549456357188632 0.034267200130838324 95.15802108325363 136.5 951580.21083253622;
9.3892128358497011 0.034267200130838324 103.94963853771687 137 1039496.3853771687;
9.4234800359805391 0.034267200130838324 112.75521634640694 137.5 1127552.1634640694;
9.457747236111377 0.034267200130838324 121.57436950464846 138 1215743.6950464845;
9.492014436242215 0.034267200130838324 130.40671300756335 138.5 1304067.1300756335;
9.5262816363730547 0.034267200130838324 139.25186185041071 139 1392518.618504107;
9.5605488365038926 0.034267200130838324 148.1094310283959 139.5 1481094.3102839589;
9.5948160366347306 0.034267200130838324 156.97903553690912 140 1569790.355369091;
9.6290832367655685 0.034267200130838324 165.86029037116171 140.5 1658602.903711617;
9.6633504368964065 0.034267200130838324 174.75281052619815 141 1747528.1052619815;
9.6976176370272462 0.034267200130838324 183.65621099758746 141.5 1836562.1099758744;
9.7318848371580842 0.034267200130838324 192.57010678026677 142 1925701.0678026676;
9.7661520372889221 0.034267200130838324 201.49411286965014 142.5 2014941.1286965013;
9.8004192374197601 0.012988524459221436 205.20087073858673 143 2052008.7073858671;
9.8134077618789828 0.021278675671616887 -49.154840282938707 143.18951832086702 -491548.40282938705;
9.8346864375505998 0.034267200130838324 -41.905708361244201 143.5 -419057.08361244202;
9.8689536376814377 0.034267200130838324 -32.953681380265955 144 -329536.81380265951;
9.9032208378122757 0.034267200130838324 -23.993084111738206 144.5 -239930.84111738205;
9.9374880379431136 0.034267200130838324 -15.024301560229064 145 -150243.01560229063;
9.9717552380739516 0.034267200130838324 -6.0477187306821349 145.5 -60477.187306821346;
10.006022438204791 0.0059763034300628799 -0.77353362476472942 146 -7735.3362476472939;
10.011998741634853 0.028290896700775444 3.7199578952505439 146.08720151350627 37199.578952505435;
10.040289638335629 0.034267200130838324 11.927307743942738 146.5 119273.07743942738;
10.074556838466467 0.034267200130838324 20.924981379449367 147 209249.81379449368;
10.108824038597305 0.034267200130838324 32.041103205585479 147.5 320411.0320558548;
10.143091238728143 0.034267200130838324 58.723375688844925 148 587233.75688844919;
10.177358438858983 0.034267200130838324 58.723375688844925 148.5 587233.75688844919;
10.211625638989821 0.034267200130838324 58.723375688838964 149 587233.75688838959;
10.245892839120659 0.034267200130838324 58.723375688844925 149.5 587233.75688844919;
10.280160039251497 0.034267200130838324 58.723375688844925 150 587233.75688844919;
10.314427239382335 0.034267200130838324 58.723375688844925 150.5 587233.75688844919;
10.348694439513174 0.034267200130838324 58.723375688844925 151 587233.75688844919;
10.382961639644012 0.034267200130838324 58.723375688844925 151.5 587233.75688844919;
10.41722883977485 0.034267200130838324 58.723375688844925 152 587233.75688844919;
10.451496039905688 0.034267200130838324 58.723375688844925 152.5 587233.75688844919;
10.485763240036528 0.034267200130838324 58.723375688844925 153 587233.75688844919;
10.520030440167366 0.034267200130838324 58.723375688844925 153.5 587233.75688844919;
10.554297640298204 0.034267200130838324 58.723375688844925 154 587233.75688844919;
10.588564840429042 0.034267200130838324 58.723375688844925 154.5 587233.75688844919;
10.62283204055988 0.034267200130838324 58.723375688844925 155 587233.75688844919;
10.657099240690719 0.034267200130838324 58.723375688844925 155.5 587233.75688844919;
10.691366440821557 0.034267200130838324 58.723375688844925 156 587233.75688844919;
10.725633640952395 0.034267200130838324 58.723375688844925 156.5 587233.75688844919;
10.759900841083233 0.034267200130838324 58.723375688844925 157 587233.75688844919;
10.794168041214071 0.034267200130838324 58.723375688844925 157.5 587233.75688844919;
10.828435241344911 0.034267200130838324 58.723375688844925 158 587233.75688844919;
10.862702441475749 0.034267200130838324 58.723375688844925 158.5 587233.75688844919;
10.896969641606587 0.034267200130838324 58.723375688844925 159 587233.75688844919;
10.931236841737425 0.034267200130838324 58.723375688844925 159.5 587233.75688844919;
10.965504041868265 0.034267200130838324 58.723375688844925 160 587233.75688844919;
10.999771241999103 0.034267200130838324 58.723375688844925 160.5 587233.75688844919;
11.03403844212994 0.034267200130838324 58.723375688838964 161 587233.75688838959;
11.068305642260778 0.034267200130838324 58.723375688844925 161.5 587233.75688844919;
11.102572842391616 0.0085463434410577195 58.723375688861282 162 587233.75688861276;
11.111119185832674 0.025720856689780604 -279.99999999905958 162.12470151352352 -2799999.999990596;
11.136840042522456 0.034267200130838324 -279.99999999906424 162.5 -2799999.9999906421;
11.171107242653294 0.034267200130838324 -279.99999999906424 163 -2799999.9999906421;
11.205374442784132 0.034267200130838324 -279.99999999906424 163.5 -2799999.9999906421;
11.23964164291497 0.034267200130838324 -279.99999999905828 164 -2799999.9999905825;
11.273908843045808 0.034267200130838324 -279.99999999906424 164.5 -2799999.9999906421;
11.308176043176648 0.034267200130838324 -279.99999999906424 165 -2799999.9999906421;
11.342443243307486 0.034267200130838324 -279.99999999905828 165.5 -2799999.9999905825;
11.376710443438323 0.034267200130838324 -279.16804566449525 166 -2791680.4566449523;
11.410977643569161 0.034267200130838324 -271.90563293319343 166.5 -2719056.3293319345;
11.445244843699999 0.034267200130838324 -263.2747942824364 167 -2632747.9428243637;
11.479512043830839 0.034267200130838324 -254.62614522996546 167.5 -2546261.4522996545;
11.513779243961677 0.034267200130838324 -245.96007078034282 168 -2459600.7078034282;
11.548046444092515 0.034267200130838324 -237.2769559384048 168.5 -2372769.559384048;
11.582313644223353 0.034267200130838324 -228.14324108092785 169 -2281432.4108092785;
11.616580844354193 0.034267200130838324 -212.39554978235961 169.5 -2123955.497823596;
11.650848044485031 0.034267200130838324 -194.39862340986133 170 -1943986.2340986133;
11.685115244615869 0.034267200130838324 -176.38092521650793 170.5 -1763809.2521650791;
11.719382444746707 0.034267200130838324 -158.34249370298983 171 -1583424.9370298982;
11.753649644877544 0.034267200130838324 -140.28336736967563 171.5 -1402833.6736967564;
11.787916845008384 0.034267200130838324 -122.20358471701742 172 -1222035.8471701741;
11.822184045139222 0.034267200130838324 -104.10318424565793 172.5 -1041031.8424565792;
11.85645124527006 0.034267200130838324 -85.982204455804833 173 -859822.04455804825;
11.890718445400898 0.034267200130838324 -67.84068384822011 173.5 -678406.8384822011;
11.924985645531736 0.034267200130838324 -49.678660923182967 174 -496786.60923182964;
11.959252845662576 0.034267200130838324 -31.496174181199077 174.5 -314961.74181199074;
11.993520045793414 0.034267200130838324 -13.293262122821808 175 -132932.62122821808;
12.027787245924252 0.0078609994376000972 -2.0946792448806253 175.5 -20946.792448806253;
12.035648245361852 0.026406200693238225 7.0212610492988752 175.61470151351125 70212.610492988752;
12.06205444605509 0.034267200130838324 23.173683941525223 176 231736.83941525221;
12.096321646185928 0.034267200130838324 41.437640946489573 176.5 414376.40946489573;
12.130588846316767 0.034267200130838324 59.72186926586032 177 597218.69265860319;
12.164856046447605 0.034267200130838324 78.026330399483442 177.5 780263.30399483442;
12.199123246578443 0.034267200130838324 96.350985846596956 178 963509.85846596956;
12.233390446709281 0.034267200130838324 114.69579710685015 178.5 1146957.9710685015;
12.267657646840121 0.034267200130838324 133.06072567982673 179 1330607.2567982674;
12.301924846970959 0.034267200130838324 151.44573306487203 179.5 1514457.3306487203;
12.336192047101797 0.034267200130838324 169.85078076162338 180 1698507.8076162338;
12.370459247232635 0.034267200130838324 188.27583026963472 180.5 1882758.3026963472;
12.404726447363473 0.034267200130838324 206.72084308831694 181 2067208.4308831692;
12.438993647494312 0.034267200130838324 225.18578071733117 181.5 2251857.8071733117;
12.47326084762515 0.034267200130838324 243.67060465607645 182 2436706.0465607643;
12.507528047755988 0.034267200130838324 264.28746433575753 182.5 2642874.6433575749;
12.541795247886826 0.034267200130838324 300.48440872702002 183 3004844.0872702003;
12.576062448017664 0.034267200130838324 310.01336119364504 183.5 3100133.61193645;
12.610329648148504 0.034267200130838324 318.57429620204567 184 3185742.9620204568;
12.644596848279342 0.034267200130838324 320.00000000029206 184.5 3200000.0000029206;
12.67886404841018 0.034267200130838324 320.00000000029206 185 3200000.0000029206;
12.713131248541018 0.034267200130838324 320.00000000029206 185.5 3200000.0000029206;
12.747398448671856 0.034267200130838324 320.00000000029206 186 3200000.0000029206;
12.781665648802695 0.034267200130838324 320.00000000029206 186.5 3200000.0000029206;
12.815932848933533 0.034267200130838324 320.00000000028609 187 3200000.000002861;
12.850200049064371 0.034267200130838324 320.00000000029206 187.5 3200000.0000029206;
12.884467249195209 0.034267200130838324 320.00000000029206 188 3200000.0000029206;
12.918734449326049 0.034267200130838324 320.00000000029206 188.5 3200000.0000029206;
12.953001649456887 0.034267200130838324 320.00000000029206 189 3200000.0000029206;
12.987268849587725 0.034267200130838324 320.00000000028609 189.5 3200000.000002861;
13.021536049718563 0.034267200130838324 320.00000000028609 190 3200000.000002861;
13.055803249849401 0.034267200130838324 320.00000000026228 190.5 3200000.0000026226;
13.09007044998024 0.034267200130838324 320.00000000022652 191 3200000.000002265;
13.124337650111078 0.034267200130838324 320.00000000024437 191.5 3200000.0000024438;
13.158604850241916 0.034267200130838324 320.00000000019077 192 3200000.0000019073;
13.192872050372754 0.034267200130838324 320.00000000022055 192.5 3200000.0000022054;
13.227139250503592 0.034267200130838324 320.00000000010732 193 3200000.0000010729;
13.261406450634432 0.034267200130838324 320.00000000011329 193.5 3200000.0000011325;
13.29567365076527 0.034267200130838324 320.00000000017286 194 3200000.0000017285;
13.329940850896108 0.034267200130838324 286.3704860538125 194.5 2863704.860538125;
13.364208051026946 0.034267200130838324 56.431717641407253 195 564317.17641407251;
13.398475251157784 0.034267200130838324 56.431717641407253 195.5 564317.17641407251;
13.432742451288624 0.034267200130838324 56.431717641401292 196 564317.17641401291;
13.467009651419461 0.034267200130838324 56.431717641407253 196.5 564317.17641407251;
13.501276851550299 0.034267200130838324 56.431717641401292 197 564317.17641401291;
13.535544051681137 0.034267200130838324 56.431717641407253 197.5 564317.17641407251;
13.569811251811977 0.034267200130838324 56.431717641407253 198 564317.17641407251;
13.604078451942815 0.034267200130838324 56.431717641401292 198.5 564317.17641401291;
13.638345652073653 0.034267200130838324 56.431717641407253 199 564317.17641407251;
13.672612852204491 0.034267200130838324 56.431717641401292 199.5 564317.17641401291;
13.706880052335329 0.034267200130838324 56.431717641407253 200 564317.17641407251;
13.741147252466169 0.034267200130838324 56.431717641407253 200.5 564317.17641407251;
13.775414452597007 0.034267200130838324 56.431717641401292 201 564317.17641401291;
13.809681652727845 0.034267200130838324 56.431717641407253 201.5 564317.17641407251;
13.843948852858682 0.034267200130838324 56.431717641407253 202 564317.17641407251;
13.87821605298952 0.034267200130838324 56.431717641401292 202.5 564317.17641401291;
13.91248325312036 0.034267200130838324 56.431717641407253 203 564317.17641407251;
13.946750453251198 0.034267200130838324 56.431717641401292 203.5 564317.17641401291;
13.981017653382036 0.034267200130838324 56.865662269294262 204 568656.62269294262;
14.015284853512874 0.034267200130838324 63.897312955385452 204.5 638973.12955385447;
14.049552053643712 0.034267200130838324 73.162313337874423 205 731623.13337874413;
14.083819253774552 0.034267200130838324 82.432585167795423 205.5 824325.8516779542;
14.11808645390539 0.034267200130838324 91.708474949544666 206 917084.74949544668;
14.152353654036228 0.034267200130838324 100.99032918733359 206.5 1009903.2918733358;
14.186620854167066 0.034267200130838324 110.27849438548088 207 1102784.9438548088;
14.220888054297905 0.034267200130838324 119.57331704826356 207.5 1195733.1704826355;
14.255155254428743 0.034267200130838324 128.87514367969632 208 1288751.4367969632;
14.289422454559581 0.034267200130838324 138.18432078455092 208.5 1381843.2078455091;
14.323689654690419 0.034267200130838324 147.50119486682416 209 1475011.9486682415;
14.357956854821257 0.034267200130838324 156.82611243075132 209.5 1568261.1243075132;
14.392224054952097 0.034267200130838324 166.15941998053194 210 1661594.1998053193;
14.426491255082935 0.034267200130838324 175.50146402090192 210.5 1755014.6402090192;
14.460758455213773 0.034267200130838324 184.85259105581642 211 1848525.9105581641;
14.495025655344611 0.034267200130838324 194.21314758940937 211.5 1942131.4758940935;
14.529292855475449 0.034267200130838324 203.58348012604714 212 2035834.8012604713;
14.563560055606288 0.034267200130838324 212.96393516993524 212.5 2129639.3516993523;
14.597827255737126 0.034267200130838324 222.35485922586324 213 2223548.5922586322;
14.632094455867964 0.033644723767777496 231.67114688077257 213.5 2316711.4688077257;
14.665739179635741 0.00062247636306082734 -100.05645971559728 213.99091731509017 -1000564.5971559727;
14.666361655998802 0.034267200130838324 -95.262217251032595 214 -952622.17251032591;
14.70062885612964 0.034267200130838324 -85.837807134616384 214.5 -858378.07134616375;
14.73489605626048 0.034267200130838324 -76.401541989177474 215 -764015.41989177465;
14.769163256391318 0.034267200130838324 -66.953075310850153 215.5 -669530.75310850143;
14.803430456522156 0.034267200130838324 -57.492060595148807 216 -574920.60595148802;
14.837697656652994 0.034267200130838324 -47.00570472966433 216.5 -470057.04729664326;
14.871964856783833 0.034267200130838324 -30.045649356842041 217 -300456.49356842041;
14.906232056914671 0.034267200130838324 -11.913256886333228 217.5 -119132.56886333227;
14.940499257045509 0.0053742836595810986 -1.4120823651339003 218 -14120.823651339002;
14.94587354070509 0.028892916471257225 7.6762237031799208 218.07841731508645 76762.237031799203;
14.974766457176347 0.034267200130838324 24.446670547801258 218.5 244466.70547801256;
15.009033657307185 0.034267200130838324 41.691483988946679 219 416914.83988946676;
15.043300857438025 0.034267200130838324 51.817704148548842 219.5 518177.04148548841;
15.077568057568863 0.034267200130838324 60.534473434412483 220 605344.73434412479;
15.111835257699701 0.034267200130838324 69.267110639941691 220.5 692671.10639941692;
15.146102457830539 0.034267200130838324 78.015230760198833 221 780152.30760198832;
15.180369657961377 0.034267200130838324 86.778448790431028 221.5 867784.48790431023;
15.214636858092216 0.034267200130838324 95.556379725861561 222 955563.79725861549;
15.248904058223054 0.034267200130838324 104.34863856173754 222.5 1043486.3856173754;
15.283171258353892 0.034267200130838324 113.1548402933538 223 1131548.402933538;
15.31743845848473 0.034267200130838324 121.9745999161005 223.5 1219745.999161005;
15.351705658615568 0.034267200130838324 130.80753242488504 224 1308075.3242488503;
15.385972858746408 0.034267200130838324 139.65325281516314 224.5 1396532.5281516314;
15.420240058877246 0.034267200130838324 148.51137608222365 225 1485113.7608222365;
15.454507259008084 0.034267200130838324 157.38151722128987 225.5 1573815.1722128987;
15.488774459138922 0.034267200130838324 166.26329122744801 226 1662632.9122744799;
15.523041659269762 0.034267200130838324 175.15631309604646 226.5 1751563.1309604645;
15.557308859400599 0.034267200130838324 184.06019782232048 227 1840601.9782232046;
15.591576059531437 0.034267200130838324 192.97456040170195 227.5 1929745.6040170193;
15.625843259662275 0.034267200130838324 201.89901582907439 228 2018990.1582907438;
15.660110459793113 0.034267200130838324 210.83317909997703 228.5 2108331.7909997702;
15.694377659923953 0.034267200130838324 219.77666520960929 229 2197766.6520960927;
15.728644860054791 0.029944306184983237 227.72953841070077 229.5 2277295.3841070076;
15.758589166239775 0.0043228939458550874 -30.925310257751828 229.93692373568092 -309253.10257751826;
15.762912060185629 0.034267200130838324 -25.878216433382036 230 -258782.16433382034;
15.797179260316467 0.034267200130838324 -16.909071836405992 230.5 -169090.71836405993;
15.831446460447305 0.034267200130838324 -7.9321444196224213 231 -79321.444196224213;
15.865713660578145 0.013084403688171231 -1.7258074614596914 231.5 -17258.074614596913;
15.878798064266315 0.021182796442667091 2.7681166709277329 231.69091731507407 27681.166709277328;
15.899980860708983 0.034267200130838324 10.043518853604795 232 100435.18853604794;
15.93424806083982 0.034267200130838324 19.041484700679781 232.5 190414.84700679779;
15.968515260970658 0.034267200130838324 31.180503835219145 233 311805.03835219145;
16.002782461101496 0.034267200130838324 56.431717640215162 233.5 564317.17640215158;
16.037049661232334 0.034267200130838324 56.4317176402092 234 564317.17640209198;
16.071316861363172 0.034267200130838324 56.431717640215162 234.5 564317.17640215158;
16.105584061494014 0.034267200130838324 56.431717640215162 235 564317.17640215158;
16.139851261624852 0.034267200130838324 56.4317176402092 235.5 564317.17640209198;
16.17411846175569 0.034267200130838324 56.431717640215162 236 564317.17640215158;
16.208385661886528 0.034267200130838324 56.4317176402092 236.5 564317.17640209198;
16.242652862017366 0.034267200130838324 56.431717640215162 237 564317.17640215158;
16.276920062148204 0.034267200130838324 56.431717640215162 237.5 564317.17640215158;
16.311187262279041 0.034267200130838324 56.4317176402092 238 564317.17640209198;
16.345454462409879 0.034267200130838324 56.431717640215162 238.5 564317.17640215158;
16.379721662540717 0.034267200130838324 56.4317176402092 239 564317.17640209198;
16.413988862671559 0.034267200130838324 56.431717640215162 239.5 564317.17640215158;
16.448256062802397 0.034267200130838324 56.431717640215162 240 564317.17640215158;
16.482523262933235 0.034267200130838324 56.4317176402092 240.5 564317.17640209198;
16.516790463064073 0.034267200130838324 56.431717640215162 241 564317.17640215158;
16.551057663194911 0.034267200130838324 56.431717640215162 241.5 564317.17640215158;
16.585324863325749 0.034267200130838324 56.4317176402092 242 564317.17640209198;
16.619592063456587 0.034267200130838324 56.431717640215162 242.5 564317.17640215158;
16.653859263587425 0.034267200130838324 56.4317176402092 243 564317.17640209198;
16.688126463718262 0.034267200130838324 56.431717640215162 243.5 564317.17640215158;
16.7223936638491 0.034267200130838324 56.431717640215162 244 564317.17640215158;
16.756660863979942 0.034267200130838324 56.4317176402092 244.5 564317.17640209198;
16.79092806411078 0.034267200130838324 56.431717640215162 245 564317.17640215158;
16.825195264241618 0.034267200130838324 56.4317176402092 245.5 564317.17640209198;
16.859462464372456 0.034267200130838324 56.431717640215162 246 564317.17640215158;
16.893729664503294 0.034267200130838324 56.431717640215162 246.5 564317.17640215158;
16.927996864634132 0.034267200130838324 56.4317176402092 247 564317.17640209198;
16.96226406476497 0.034267200130838324 56.431717640215162 247.5 564317.17640215158;
16.996531264895808 0.034267200130838324 56.4317176402092 248 564317.17640209198;
17.030798465026646 0.033644723767777496 56.431717640218899 248.5 564317.17640218895;
17.064443188794424 0.00062247636306082734 -279.99999999905555 248.99091731509017 -2799999.9999905555;
17.065065665157487 0.034267200130838324 -279.99999999906424 249 -2799999.9999906421;
17.099332865288325 0.034267200130838324 -279.99999999905828 249.5 -2799999.9999905825;
17.133600065419163 0.034267200130838324 -279.99999999906424 250 -2799999.9999906421;
17.167867265550001 0.034267200130838324 -279.99999999906424 250.5 -2799999.9999906421;
17.202134465680839 0.034267200130838324 -279.99999999906424 251 -2799999.9999906421;
17.236401665811677 0.034267200130838324 -278.98755339140894 251.5 -2789875.5339140892;
17.270668865942515 0.034267200130838324 -271.51464832245114 252 -2715146.4832245111;
17.304936066073353 0.034267200130838324 -262.88299370530251 252.5 -2628829.9370530248;
17.339203266204191 0.034267200130838324 -254.23354614493252 253 -2542335.4614493251;
17.373470466335029 0.034267200130838324 -245.5666906459272 253.5 -2455666.9064592719;
17.40773766646587 0.034267200130838324 -236.88281221305132 254 -2368828.1221305132;
17.442004866596708 0.034267200130838324 -228.18229585133196 254.5 -2281822.9585133195;
17.476272066727546 0.034267200130838324 -219.46552656542659 255 -2194655.2656542659;
17.510539266858384 0.034267200130838324 -210.73288935989143 255.5 -2107328.8935989141;
17.544806466989222 0.034267200130838324 -201.9847692397237 256 -2019847.6923972368;
17.57907366712006 0.034267200130838324 -200.25152527420522 256.5 -2002515.2527420521;
17.613340867250898 0.034267200130838324 -204.44362027397753 257 -2044436.2027397752;
17.647608067381736 0.034267200130838324 -195.65136143807769 257.5 -1956513.6143807769;
17.681875267512574 0.034267200130838324 -186.84515970642568 258 -1868451.5970642567;
17.716142467643415 0.034267200130838324 -178.02540008373856 258.5 -1780254.0008373857;
17.750409667774253 0.034267200130838324 -169.19246757488847 259 -1691924.6757488847;
17.784676867905091 0.034267200130838324 -160.34674718451501 259.5 -1603467.47184515;
17.818944068035929 0.034267200130838324 -151.48862391747238 260 -1514886.2391747236;
17.853211268166767 0.034267200130838324 -142.61848277847767 260.5 -1426184.8277847767;
17.887478468297605 0.034267200130838324 -133.73670877227784 261 -1337367.0877227783;
17.921745668428443 0.034267200130838324 -124.84368690364361 261.5 -1248436.8690364361;
17.956012868559281 0.034267200130838324 -115.93980217731595 262 -1159398.0217731595;
17.990280068690119 0.034267200130838324 -107.02543959802389 262.5 -1070254.3959802389;
18.024547268820957 0.034267200130838324 -98.100984170556075 263 -981009.84170556068;
18.058814468951798 0.034267200130838324 -89.166820899659399 263.5 -891668.20899659395;
18.093081669082636 0.034267200130838324 -80.22333479013443 264 -802233.3479013443;
18.127348869213474 0.034267200130838324 -71.270910846662531 264.5 -712709.10846662521;
18.161616069344312 0.034267200130838324 -62.309934073984628 265 -623099.34073984623;
18.19588326947515 0.034267200130838324 -53.340789476996662 265.5 -533407.8947699666;
18.230150469605988 0.034267200130838324 -44.363862060302495 266 -443638.62060302496;
18.264417669736826 0.034267200130838324 -35.379536828720575 266.5 -353795.3682872057;
18.298684869867664 0.034267200130838324 -26.388198786979913 267 -263881.98786979914;
18.332952069998502 0.034267200130838324 -17.390232939887049 267.5 -173902.32939887047;
18.367219270129343 0.029875331752175188 -8.9633067238348083 268 -89633.067238348085;
18.397094601881516 0.0043918683786631349 20.000000000030667 268.43591731507252 200000.00000030667;
18.401486470260181 0.034267200130838324 20.000000000017881 268.5 200000.00000017881;
18.435753670391019 0.034267200130838324 20.000000000017881 269 200000.00000017881;
18.470020870521857 0.034267200130838324 20.000000000017881 269.5 200000.00000017881;
18.504288070652695 0.034267200130838324 20.000000000017881 270 200000.00000017881;
18.538555270783533 0.034267200130838324 20.000000000017881 270.5 200000.00000017881;
18.572822470914371 0.034267200130838324 20.000000000023842 271 200000.00000023842;
18.607089671045209 0.034267200130838324 20.000000000017881 271.5 200000.00000017881;
18.641356871176047 0.034267200130838324 20.000000000017881 272 200000.00000017881;
18.675624071306885 0.034267200130838324 20.000000000017881 272.5 200000.00000017881;
18.709891271437726 0.034267200130838324 20.000000000017881 273 200000.00000017881;
18.744158471568564 0.034267200130838324 20.000000000017881 273.5 200000.00000017881;
18.778425671699402 0.034267200130838324 20.000000000017881 274 200000.00000017881;
18.81269287183024 0.034267200130838324 20.000000000017881 274.5 200000.00000017881;
18.846960071961078 0.034267200130838324 20.000000000017881 275 200000.00000017881;
18.881227272091916 0.034267200130838324 20.000000000017881 275.5 200000.00000017881;
18.915494472222754 0.034267200130838324 20.000000000017881 276 200000.00000017881;
18.949761672353592 0.034267200130838324 20.000000000017881 276.5 200000.00000017881;
18.98402887248443 0.034267200130838324 20.000000000017881 277 200000.00000017881;
19.018296072615271 0.034267200130838324 20.000000000017881 277.5 200000.00000017881;
19.052563272746109 0.034267200130838324 20.000000000017881 278 200000.00000017881;
19.086830472876947 0.034267200130838324 20.000000000017881 278.5 200000.00000017881;
19.121097673007785 0.034267200130838324 20.000000000017881 279 200000.00000017881;
19.155364873138623 0.034267200130838324 20.000000000017881 279.5 200000.00000017881;
19.189632073269461 0.034267200130838324 20.000000000017881 280 200000.00000017881;
19.223899273400299 0.034267200130838324 20.000000000017881 280.5 200000.00000017881;
19.258166473531137 0.034267200130838324 20.000000000023842 281 200000.00000023842;
19.292433673661975 0.034267200130838324 20.000000000017881 281.5 200000.00000017881;
19.326700873792813 0.034267200130838324 20.000000000017881 282 200000.00000017881;
19.360968073923654 0.034267200130838324 20.000000000017881 282.5 200000.00000017881;
19.395235274054492 0.034267200130838324 20.000000000017881 283 200000.00000017881;
19.42950247418533 0.034267200130838324 20.000000000017881 283.5 200000.00000017881;
19.463769674316168 0.034267200130838324 20.000000000017881 284 200000.00000017881;
19.498036874447006 0.034267200130838324 20.000000000017881 284.5 200000.00000017881;
19.532304074577844 0.034267200130838324 20.000000000017881 285 200000.00000017881;
19.566571274708682 0.034267200130838324 20.000000000017881 285.5 200000.00000017881;
19.60083847483952 0.034267200130838324 20.000000000017881 286 200000.00000017881;
19.635105674970358 0.034267200130838324 20.000000000017881 286.5 200000.00000017881;
19.6693728751012 0.034267200130838324 20.000000000017881 287 200000.00000017881;
19.703640075232038 0.034267200130838324 20.000000000017881 287.5 200000.00000017881;
19.737907275362875 0.034267200130838324 20.000000000017881 288 200000.00000017881;
19.772174475493713 0.034267200130838324 20.000000000017881 288.5 200000.00000017881;
19.806441675624551 0.034267200130838324 20.000000000017881 289 200000.00000017881;
19.840708875755389 0.034267200130838324 20.000000000017881 289.5 200000.00000017881;
19.874976075886227 0.034267200130838324 20.000000000017881 290 200000.00000017881;
19.909243276017065 0.034267200130838324 20.000000000023842 290.5 200000.00000023842;
19.943510476147903 0.034267200130838324 20.000000000011923 291 200000.00000011921;
19.977777676278741 0.022222323721259159 20.000000000018638 291.5 200000.00000018638;
];
end

function data=native_baseline_fixture()
data=[
1 0 0 3000 60 0 25167.491222777899 0 180 0;
1 2 0 2986.38958754329 59.827820185771799 354.751463639311 24939.6492776175 0 178.968403409052 0;
1 4 0 2972.8324447346099 60.4845185271571 536.24998808642397 24713.7290306248 0 182.918849073101 0;
1 6 0 2959.3283630823298 68.0697984882908 594.16877908577897 24489.7149140406 0 231.67487331182599 0;
1 8 0 2945.8771349110002 59.690718441577303 935.47498479259298 24267.591483901098 0 178.14909340358301 0;
1 10 0 2932.4785533579902 60.462645802792601 1152.67779255917 24047.3434190603 0 182.78657687369801 0;
1 12 0 2919.1324123702302 68.072426558888907 1207.6877322451201 23828.955520219901 0 231.69276288076699 0;
1 14 0 2905.83850670117 59.715478361669597 1527.7597631905201 23612.4127089717 0 178.29691779815201 0;
1 16 0 2892.5966319075301 59.873339966235399 1714.0940207641399 23397.700026843399 0 179.24084193562001 0;
1 18 0 2879.4065843462699 68.290645149343206 1773.5828924848599 23184.8026343538 0 233.18061074567601 0;
1 20 0 2866.2681611712601 63.133829167269901 1773.5828924848599 22973.705810073399 0 199.294019266101 0;
1 22 20.000783726410901 2890.4678397827902 56.652077176374299 3068.7446081900098 23363.273857137599 4.0003134967066298 160.47289241989299 0;
1 24 20.0007868926645 2914.66101398619 56.637815438498301 4410.7676951015201 23756.0111416689 4.00031476325782 160.39210688227001 0;
1 26 20.000790046660601 2938.75949878344 56.623601925067099 5758.4858275541301 24150.465608618499 4.0003160249059997 160.31161474842301 0;
1 28 20.0007931884514 2962.7636647784302 56.609436494614997 7111.8797440698099 24546.605112937301 4.00031728167205 160.23141501189301 0;
1 30 20.000796318319001 2986.67388112447 56.5953190058868 8470.9302397231604 24944.397834012299 4.0003185336688096 160.15150666890401 0;
1 32 9.9260539536498893 2999.7400160105299 58.778562946620802 9311.53450304543 25163.129315275099 0.98526547090768701 172.74597310349299 2.3425184165666;
1 34 7.3387753435832197 3001.6196401002899 59.186753607836501 9695.2528510375305 25194.673410363201 0.53857623543584898 175.15359013173801 1.7694361502934799;
1 36 6.9668652354921301 3001.22387511444 59.240903594688199 10005.2751234436 25188.0299888712 0.48537211209508901 175.47423293575699 0.98193881302032604;
1 38 7.0437241343309598 3000.6792668033199 59.230465147029697 10310.387771697 25178.8894739145 0.49614049680556399 175.412400076675 0.481445819642916;
1 40 7.1504192399836297 3000.3330658397999 59.215468253497697 10621.3398472524 25173.079820722302 0.51128495307528099 175.32358402404901 0.22058816140620399;
1 42 7.2183354473765302 3000.1526092803601 59.205827484274003 10937.267958214799 25170.0518163872 0.52104366630852605 175.26650040488099 0.096803987486499196;
1 44 7.2537560764442102 3000.0669734683202 59.200774103159297 11256.066782538899 25168.6149381049 0.52616977216551397 175.23658272066501 0.041223407305582098;
1 46 7.2705700092147802 3000.0285207686402 59.198369014612801 11576.300307263 25167.969755848801 0.52861188258893399 175.222344699513 0.017166994889792699;
1 48 7.2781213375767297 3000.0118772944902 59.197287370723501 11897.1985248497 25167.690504308801 0.529710502044897 175.21594160260099 0.0070258780532160697;
1 50 7.2813902104675297 3000.0048610315898 59.196818782981197 12218.390534502199 25167.572782823801 0.53018643397092402 175.213167701256 0.0028354868669765798;
1 52 7.2827683793745104 3000.00196181928 59.1966211339398 12539.7082798583 25167.524138834899 0.53038715267617298 175.21199768375999 0.0011311349668137801;
1 54 7.2833379002664698 3000.0007826149699 59.196539431752797 12861.078580863301 25167.504353749799 0.53047010969457997 175.21151403475301 0.00044681068155922899;
1 56 7.28356955717312 3000.0003091418698 59.196506191472103 13182.470453452501 25167.496409661599 0.53050385494178998 175.21131726384999 0.00017499703714521901;
1 58 7.2836625767387 3000.0001210769501 59.196492841882197 13503.8710522778 25167.493254246601 0.53051740531783798 175.21123823894999 6.8027189236503804e-05;
1 60 7.2836995258891397 3000.0000470651999 59.1964875384325 13825.275138987299 25167.492012453102 0.53052278783437701 175.21120684439001 2.62686453996974e-05;
1 62 7.2837140675792904 3000.0000181728301 59.196485451019399 14146.680605752401 25167.4915276875 0.53052490618252501 175.21119448763699 1.00834188907736e-05;
1 64 7.28371974413575 3000.0000069740499 59.196484636001102 14468.0866138045 25167.4913397907 0.53052573311112905 175.211189663016 3.8504292039799796e-06;
1 66 7.2837219451182396 3000.0000026616999 59.196484320019401 14789.4928325889 25167.491267436799 0.53052605373797002 175.21118779251501 1.4644891556525e-06;
1 68 7.2837227955789396 3000.0000010082299 59.196484197923297 15110.899132848601 25167.491239694202 0.53052617762836296 175.211187069749 5.5638892094227896e-07;
1 70 7.2837231106395803 3000.0000003866899 59.196484152585597 15432.305464205499 25167.491229265899 0.53052622352465095 175.21118680136601 2.1085373366352199e-07;
1 72 7.2837232332619202 3000.0000001469598 59.196484135001803 15753.7118072538 25167.491225243601 0.53052624138759497 175.21118669727599 7.8682254995125605e-08;
1 74 7.2837232825489204 3000.0000000549699 59.196484128073301 16075.118154832 25167.491223700199 0.53052624856745101 175.21118665626199 2.8450035885522801e-08;
1 76 7.2837232985888303 3000.00000002145 59.196484125643501 16396.524504159199 25167.4912231378 0.53052625090405803 175.21118664187799 9.5605699794094205e-09;
1 78 7.2837233051572303 3000.0000000089799 59.196484124731001 16717.930854171598 25167.491222928598 0.53052625186090596 175.21118663647599 2.5506720799301698e-09;
1 80 7.2837233049054397 3000.0000000054702 59.196484124720598 17039.337204293399 25167.491222869601 0.53052625182422597 175.21118663641499 -1.22524774221637e-09;
1 82 7.28372330548852 3000.0000000028999 59.196484124647199 17360.743554415199 25167.491222826498 0.53052625190916602 175.21118663598 -3.4470639452348998e-09;
1 84 7.2837233061427797 3000.0000000004802 59.196484124522399 17682.149904544902 25167.491222785899 0.53052625200447501 175.211186635242 -4.31689870945155e-09;
1 86 7.2837233065428499 3000.0000000002401 59.196484124413203 18003.556254812302 25167.4912227819 0.53052625206275505 175.21118663459501 -4.4909569812472802e-09;
1 88 7.2837233076027799 3000.0000000001501 59.196484124394502 18324.9626050796 25167.4912227803 0.53052625221715999 175.21118663448399 -4.5924529235646198e-09;
1 90 7.28372330746069 3000.00000000008 59.196484124393898 18646.368955346999 25167.491222779299 0.53052625219646099 175.21118663448101 -4.6527451747562603e-09;
3 0 0 3000 60 0 25167.491222777899 0 180 0;
3 2 0 2979.60437050268 59.827820185771799 354.751463639311 24826.449918078801 0 178.968403409052 0;
3 4 0 2959.32836312172 60.4845185271571 536.24998808642397 24489.714914692599 0 182.918849073101 0;
3 6 0 2939.1712762632301 68.0697984882908 594.16877908577897 24157.233984585098 0 231.67487331182599 0;
3 8 0 2919.1324124481398 59.690718441577303 935.47498479259298 23828.9555214918 0 178.14909340358301 0;
3 10 0 2899.21107828813 60.462645802792601 1152.67779255917 23504.828533582498 0 182.78657687369801 0;
3 12 0 2879.4065844616298 68.072426558888907 1207.6877322451201 23184.8026362116 0 231.69276288076699 0;
3 14 0 2859.7182456901201 59.715478361669597 1527.7597631905201 22868.828044755101 0 178.29691779815201 0;
3 16 0 2840.1453807143198 59.873339966235399 1714.0940207641399 22556.855567529201 0 179.24084193562001 0;
3 18 0 2820.6873122704701 68.290645149343206 1773.5828924848599 22248.836598789901 0 233.18061074567601 0;
3 20 0 2801.3433670670602 63.133829167269901 1773.5828924848599 21944.723111820302 0 199.294019266101 0;
3 22 20.000774422284099 2819.36381280356 56.693887916148299 3053.0857943457099 22227.962668545799 4.0003097749109298 160.709846352439 0;
3 24 20.000776777802901 2837.3659257599302 56.683292782726603 4377.6515918876103 22512.7274842474 4.0003107171550196 160.649784034616 0;
3 26 20.000779119544902 2855.26245477978 56.6727556191044 5706.4438389468796 22797.618700301799 4.00031165388822 160.59006147313599 0;
3 28 20.000781447532798 2873.0540191218802 56.662276129193302 7039.43940686308 23082.614563080399 4.0003125851197199 160.530676807047 0;
3 30 20.000783762144302 2890.7412344130598 56.651854018134898 8376.6152851726001 23367.693692297598 4.0003135110005497 160.47162818460399 0;
3 32 20.0007860632934 2908.32471266944 56.641488992459301 9717.9485810666902 23652.8350759448 4.0003144314963102 160.41291376414401 0;
3 34 20.000788351152501 2925.80506231765 56.631180759949899 11063.416518882799 23938.018065291701 4.00031534667598 160.35453171330599 0;
3 36 20.0007906256543 2943.1828882157602 56.620929029698303 12412.996439569801 24223.222369945001 4.0003162565126198 160.296480209306 0;
3 38 20.0007928869335 2960.4587916744399 56.610733512061401 13766.665800200701 24508.428052977 4.0003171610600896 160.238757438682 0;
3 40 20.000795134883901 2977.6333704775002 56.600593918697498 15124.402173442901 24793.615526105001 4.0003180602759496 160.18136159746501 0;
3 42 16.374892577822902 2993.27708497822 57.4896277476319 16411.196476818299 25054.818342893999 2.6813710693523798 165.25286492806401 1.9221156373171999;
3 44 12.246825653724301 2998.8109385643902 58.3704560035413 17196.5144142928 25147.544714336102 1.4998473859271899 170.35550670306699 3.69175172231648;
3 46 11.1598866767202 3000.03449483034 58.573398513403802 17798.1285927932 25168.069991665099 1.24543070637237 171.542150670501 3.9104352825708002;
3 48 10.919181212879501 3000.18577092135 58.616904296353098 18357.709970096999 25170.608244638599 1.1922851835970101 171.79707346439099 3.8321396306895399;
3 50 10.889189897446 3000.1316907273399 58.622379980445103 18909.3421404738 25169.700821423699 1.1857445662264099 171.82917172858399 3.7451655134195199;
3 52 10.899659079257599 3000.0715854668802 58.6205730092762 19460.690153529398 25168.692321514201 1.1880256804404199 171.818578996794 3.69189668222071;
3 54 10.9113899457474 3000.0347692117798 58.618507087882499 20012.897954567899 25168.074595379901 1.1905843054815799 171.80646866060599 3.66453673802138;
3 56 10.9185870227456 3000.0158588202999 58.617234142871503 20565.775504886398 25167.757307961601 1.1921554257326801 171.79900692801101 3.6516442345945999;
3 58 10.9222862961281 3000.0069476839699 58.616578599256698 21119.028680142499 25167.607793429801 1.19296337934588 171.79516433414199 3.64587384489682;
3 60 10.9240301730075 3000.0029592013502 58.616269244821098 21672.4671707981 25167.540873251699 1.19334435220779 171.793351009068 3.6433784329698402;
3 62 10.924810896687401 3000.00123435861 58.616130659443797 22225.990983253301 25167.511933255199 1.1935149312838 171.79253867424899 3.6423256041850798;
3 64 10.9251485829059 3000.0005066316598 58.616070691277898 22779.552409587199 25167.499723210502 1.1935887155857099 171.79218716424401 3.6418896209227398;
3 66 10.925291073906999 3000.0002052733498 58.616045379125097 23333.129928745999 25167.494666921499 1.1936198504959099 171.79203879438299 3.6417117036725899;
3 68 10.925350086342 3000.0000822936599 58.616034893684102 23886.714183420401 25167.492603527899 1.19363274509134 171.79197733287899 3.6416399544758402;
3 70 10.925374169859801 3000.0000326993199 58.6160306136548 24440.301209995501 25167.491771417699 1.1936380075144 171.79195224504599 3.6416113030192201;
3 72 10.9253838838495 3000.0000128941001 58.616028887151401 24993.889362083799 25167.4914391192 1.1936401300947801 171.79194212496901 3.6415999563774699;
3 74 10.9253877642858 3000.0000050501499 58.616028197382199 25547.477966209699 25167.491307511002 1.1936409780000601 171.791938081816 3.6415954949813201;
3 76 10.9253892990821 3000.0000019670902 58.616027924502497 26101.066750129001 25167.491255782301 1.1936413133649799 171.79193648230299 3.6415937511649799;
3 78 10.9253899084647 3000.0000007582498 58.616027816175098 26654.655605330601 25167.491235500001 1.19364144651981 171.79193584733099 3.64159307498669;
3 80 10.925390138193 3000.0000002966899 58.616027775274198 27208.2444884711 25167.491227755701 1.19364149671725 171.791935607586 3.64159281396197;
3 82 10.9253902267805 3000.00000011677 58.616027759545197 27761.833381996901 25167.491224737001 1.1936415160742999 171.79193551538901 3.64159271112467;
3 84 10.9253902610296 3000.00000004616 58.616027753389098 28315.422279642 25167.491223552301 1.193641523558 171.79193547930399 3.64159267075101;
3 86 10.9253902747414 3000.0000000181099 58.616027750970197 28869.011178883298 25167.491223081699 1.19364152655413 171.79193546512499 3.64159265471497;
3 88 10.925390279972801 3000.0000000078098 58.616027750083099 29422.600078773899 25167.491222908899 1.1936415276972401 171.79193545992501 3.6415926488131598;
3 90 10.9253902797254 3000.0000000046298 58.616027750043202 29976.1889787113 25167.491222855599 1.19364152764317 171.79193545969201 3.6415926455768002;
5 0 0 3000 57 0 32076.214303540401 0 129.96000000000001 0;
5 2 0 2983.98714350723 56.727613785250597 359.84918274372501 31734.7069495096 0 128.720886630742 0;
5 4 0 2968.0480222168098 57.526754631005602 542.54498923646702 31396.587260530101 0 132.373099935037 0;
5 6 0 2952.1822965966498 68.064743863556501 600.84286321465095 31061.8229594925 0 185.312374288462 0;
5 8 0 2936.389628678 56.512993502508202 943.73779285212697 30730.382071153599 0 127.74873738458101 0;
5 10 0 2920.6696820483999 57.512202732370497 1163.03718403582 30402.232919341099 0 132.30613852517101 0;
5 12 0 2905.0221218445399 68.067018569761601 1218.3421389063001 30077.3441241816 0 185.324760679051 0;
5 14 0 2889.4466147448802 56.549530935479297 1539.6440576661701 29755.684599349101 0 127.91397796090899 0;
5 16 0 2873.94282896298 56.809226517694299 1727.8904628909299 29437.223549352198 0 129.09152870154799 0;
5 18 0 2858.51043424012 68.2878967330237 1787.3602726940401 29121.9304668324 0 186.52947360880401 0;
5 20 0 2843.1491018382299 61.850032655608501 1787.3602726940401 28809.775129891201 0 153.01706157999399 0;
5 22 20.0025303696295 2857.1176059435902 50.667350361452698 3330.5583672052398 29093.557670775899 2.80070854831567 102.687215706008 0;
5 24 20.0025356150249 2871.0774369495198 50.652509140971802 4936.7107332150499 29378.5535331666 2.8007100172123902 102.627067291049 0;
5 26 20.002540836553901 2884.97298642234 50.637726380834899 6546.6154659214399 29663.616572623901 2.8007114794260302 102.567173320812 0;
5 28 20.002546034534401 2898.8045503624598 50.623001882959102 8160.2577804578696 29948.7338044514 2.8007129350456701 102.507532785683 0;
5 30 20.0025512087099 2912.57242340724 50.608335449902803 9777.6229420741201 30233.892420207801 2.8007143839994302 102.448144680395 0;
5 32 20.0025563594121 2926.27689883738 50.593726884481597 11398.696266008799 30519.079785827798 2.8007158263801899 102.389008002461 0;
5 34 20.002561486968499 2939.9182685829901 50.5791759899856 13023.463117392601 30804.283439755702 2.8007172622796901 102.33012175303701 0;
5 36 20.002566590804602 2953.4968232301298 50.564682570413702 14651.9089110611 31089.491091106 2.8007186915369999 102.271484937868 0;
5 38 20.002571671808202 2967.0128520264302 50.550246429808901 16284.0191115949 31374.690617825901 2.8007201144007601 102.21309656457601 0;
5 40 20.002576729199401 2980.46664288785 50.535867373154602 17919.7792329646 31659.8700648987 2.8007215306525701 102.154955646283 0;
5 42 17.0598394688943 2992.8657830637098 52.042444182207397 19472.322693465401 31923.836587618898 2.03726685893111 108.336639858327 2.1747938780182698;
5 44 13.0512403289106 2998.53803631657 53.793594983966898 20467.4735368908 32044.959080787401 1.1923441188608701 115.750034451963 4.2021087052735302;
5 46 11.4249524646557 3000.26332863266 54.388541765338097 21190.655344496601 32081.8456077792 0.91370677173749804 118.324539014397 4.41483594640634;
5 48 10.9007952313482 3000.5240555929399 54.568050688552603 21824.511500880701 32087.421762014099 0.83179135673048199 119.106886237938 4.1707183564183197;
5 50 10.8014068623977 3000.3828561023201 54.601979291292501 22434.702576851101 32084.401875541 0.81669273144936705 119.25504570107 3.9225993159107002;
5 52 10.827454087803501 3000.2106981727402 54.593771814233001 23042.8921759068 32080.7200615888 0.82063633416445103 119.219196836181 3.7661814509683702;
5 54 10.869883073580599 3000.09630426885 54.579846773037197 23654.274397932801 32078.273720839101 0.82708050623319795 119.158386950729 3.6871758092836302;
5 56 10.8998966586301 3000.0365898099499 54.569905387893698 24268.7461759371 32076.996750035501 0.83165423018171503 119.114982961747 3.6537395383058802;
5 58 10.916134041522 3000.0105208935402 54.564498941618403 24885.136077708401 32076.4392842255 0.83413387688732099 119.091381789995 3.64225333399982;
5 60 10.923449822645299 3000.0011738060698 54.562053497614002 25502.484896993901 32076.239404381999 0.83525229219494002 119.08070727506001 3.6396173284371098;
5 62 10.926181187816599 2999.99879146285 54.561136647775498 26120.235220256101 32076.1884600144 0.83567004744298301 119.076705291889 3.6398056059805799;
5 64 10.9269401671796 2999.9987465486402 54.560879880964002 26738.121263722802 32076.187499562999 0.835786149919854 119.075584535399 3.6405112357522702;
5 66 10.927005754009301 2999.9992046676002 54.560856219714502 27356.037100854799 32076.197296040998 0.83579618323707205 119.075481257134 3.6410613382972001;
5 68 10.9269026259943 2999.9995965870198 54.560889879690897 27973.949581135901 32076.205676900201 0.83578040698572997 119.07562817855001 3.6413739291728202;
5 70 10.9268028586201 2999.9998285715901 54.5609229115001 28591.853059758199 32076.2106376909 0.835765144978032 119.075772358186 3.64152052997362;
5 72 10.926740998911001 2999.9999407667201 54.560943493613998 29209.749719482901 32076.213036887399 0.83575568200097605 119.075862196533 3.6415779245528799;
5 74 10.9267100946361 2999.9999861982901 54.560953809795897 29827.6425574475 32076.2140084026 0.83575095444556002 119.075907225387 3.6415953556851601;
5 76 10.9266971559063 3000.0000007977001 54.560958143108898 30445.5336224762 32076.214320598701 0.83574897515824098 119.075926139763 3.64159797195778;
5 78 10.926692783371699 3000.0000035347598 54.560959614416397 31063.424002120701 32076.214379128302 0.83574830627531504 119.075932561839 3.6415965310421101;
5 80 10.9266918235645 3000.0000027852202 54.560959941797499 31681.314178373301 32076.214363099902 0.83574815945005998 119.07593399081701 3.64159478426429;
5 82 10.926691928651801 3000.0000015914702 54.5609599096869 32299.204327418 32076.214337572601 0.83574817552565805 119.075933850659 3.6415936261597901;
5 84 10.926692211083401 3000.0000007543399 54.560959816860397 32917.094495377001 32076.2143196713 0.83574821873025595 119.07593344548199 3.64159301953985;
5 86 10.926692430895301 3000.0000002976399 54.560959744161302 33534.984685030897 32076.214309905201 0.83574825235569905 119.07593312816 3.6415927535993302;
5 88 10.9266925545702 3000.00000009115 54.560959702849303 34152.874889036502 32076.214305489499 0.83574827127469897 119.075932947838 3.6415926581678799;
5 90 10.9266926126902 3000.00000001428 54.560959683508599 34770.765100481301 32076.214303845802 0.83574828016553404 119.075932863418 3.6415926339899798;
];
end

function data=native_legacy_totals()
data=[
18646.368955346967 18515.952271059617 130.4166842873492;
29976.188978711321 29779.912103717048 196.27687499427338;
34770.765100481287 36535.936746244755 -1765.1716457634684;
];
end
