// Independent C++ reference. PWM armature moments + implicit-midpoint slow states.
// No native MATLAB/hardware claim; provisional DC motor and semiconductor values.
#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include "train_profile.hpp"
constexpr double pi=3.14159265358979323846,tau=2*pi/60;
using Y=std::array<double,24>;using Profile=std::vector<std::array<double,3>>;
double clip(double x,double a,double b){return std::max(a,std::min(b,x));}
struct P{
 double R=.8,L=.02,Ke=.05,Kt=.05,J=.51,b=.001,Tc=.05,Ron=.02,Rd=.01,Vf=.7;
 double td=1e-6,ton=50e-9,toff=50e-9,Ceq=600e-12,Qg=30e-9,Vg=10,blend=.5;
 double Vs=60,Rs=.3,C=.1,fsw=20000,outer=.01,Imax=20,nmin=2850,nmax=3150;
 double soft=20,hyst=5,Vcharge=61,Vdischarge=59.5,Kg=80,chop_on=68,chop_band=2,Rchop=6;
 double Kp=.02*2*pi*200,Ki=.82*2*pi*200,restore_gain=4,restore_rpm=3000;
 double credit_decay=.02,credit_margin=.9,credit_reserve=5,credit_time=.2,loss_fraction=.25;
 double speed_Kp=(2*.5*.51-.001)/.05,speed_Ki=.25*.51/.05;
};
struct Case{std::string name;Profile profile;bool on=true,block=false,stiff=false,fixture=false,pwm=false;double task=20,restore=60,n0=3000,V0=60;int substeps=1;bool speed_pi=true;};
struct U{double ref=0,request=0,target=0;bool hi=false,lo=false,blocked=false;double speed_integral=0,credit=0,credited=0,spent=0,leaked=0,bus0=60;};
struct Gate{int state=-1,desired=-1;double pending=INFINITY,last_off=0;};
struct Phase{double a,b;int gate,off=-1,on=-1;};
struct Moments{double i,q,q2;};
struct M{double i=0,q=0,q2=0,port=0,terminal=0,em=0,ch=0,diode=0,tr=0,oss=0,drive=0,imported=0,returned=0,max_i=0;int zeros=0;};
struct Stats{double residual=0,max_i=0,max_ref=0,Vmin=1e9,Vmax=-1e9,nmin=1e9,nmax=-1e9,hierr=0,loerr=0,blockref=0,entry_i=0,block_end_i=0,split=0,device_split=0,iter_error=0;long long zeros=0;int iterations=0;};
const char* header="t_s,i_A,omega_rad_s,Vdc_V,Wsource_J,Wline_J,Wload_J,Wchopper_J,Wconverter_J,Wcopper_J,Wviscous_J,Wcoulomb_J,Wfess_J,Wcharge_J,Wreturn_J,Wtraction_J,Wregen_J,Qcurrent_As,Wchannel_J,Wdiode_J,Wtransition_J,Woss_J,Wgate_J,Wterminal_J,Wem_J,Pload_W,iref_A,Preq_W,Ptarget_W,high_block,low_block,gate_blocked,duty,integrator_V,cycle_mean_i_A,rpm,Erot_J,Emag_J,Ecap_J,residual_J,restore_active,connected,speed_integrator_A,recovery_credit_J,credited_J,spent_J,leaked_J,initial_bus_V";
double E(const Y& y,const P&p){return .5*p.J*y[1]*y[1]+.5*p.L*y[0]*y[0]+.5*p.C*y[2]*y[2];}
double loss(const Y& y){return y[4]+y[6]+y[7]+y[8]+y[9]+y[10];}
double balance(const Y& y,const P&p,double E0){return E(y,p)-E0-y[3]+y[5]+loss(y);}
double fixture_ref(double t){return t<.02-1e-11?0:t<.08-1e-11?15:t<.14-1e-11?-8:t<.18-1e-11?0:10;}
U outer(const Y&y,double load,double t,const P&p,const Case&c,U u,bool restoring){
 double n=y[1]/tau;if(n>=p.nmax)u.hi=true;else if(n<=p.nmax-p.hyst)u.hi=false;
 if(n<=p.nmin)u.lo=true;else if(n>=p.nmin+p.hyst)u.lo=false;
 u.blocked=c.block&&t>=5&&t<6;u.ref=0;u.request=0;double emf=p.Ke*y[1],Rt=p.R+p.Ron,raw_speed=0,speed_error=p.restore_rpm*tau-y[1];
 if(restoring){
  raw_speed=(p.b*y[1]+p.Tc)/p.Kt+(c.speed_pi?p.speed_Kp:p.restore_gain)*speed_error+(c.speed_pi?u.speed_integral:0);
  u.ref=clip(raw_speed,-p.Imax,p.Imax);
 }
 else if(c.on&&!u.blocked){
  double charge_threshold=std::min(67.,std::max(64.,u.bus0+1.)),discharge_threshold=u.bus0-.5;
  if(load<0&&y[2]>charge_threshold)u.request=std::min(-load,p.Kg*(y[2]-charge_threshold));
  else if(load>0&&y[2]<discharge_threshold)u.request=-std::min(load,p.Kg*(discharge_threshold-y[2]));
  double target=clip(u.request,-.98*emf*emf/(4*Rt),Rt*p.Imax*p.Imax+emf*p.Imax);
  u.ref=2*target/(emf+std::sqrt(std::max(0.,emf*emf+4*Rt*target)));
  // |I| <= 0.25 * EMF / Rnom bounds the nominal resistive loss fraction.
  // A causal measured-work credit prevents spending the initial rotor store.
  if(u.ref<0)u.ref=-std::min({-u.ref,p.loss_fraction*emf/Rt,std::max(0.,u.credit-p.credit_reserve)/(emf*p.credit_time)});
 }
 if(u.ref>0)u.ref*=clip((p.nmax-n)/p.soft,0,1)*(!u.hi);
 else if(u.ref<0)u.ref*=clip((n-p.nmin)/p.soft,0,1)*(!u.lo);
 if(restoring&&c.speed_pi){
  // Conditional integration includes the effective current/speed limits.
  if(std::abs(raw_speed-u.ref)<1e-10||(raw_speed>u.ref&&speed_error<0)||(raw_speed<u.ref&&speed_error>0))
   u.speed_integral+=p.outer*p.speed_Ki*speed_error;
 }
 u.target=(emf+Rt*u.ref)*u.ref;if(restoring)u.request=u.target;return u;
}
std::vector<Phase> schedule(double start,double end,double d,bool enabled,Gate&g,const P&p){
 std::vector<std::pair<double,int>> cmd;
 if(!enabled)cmd={{start,-1}};
 else if(d==0||d==1)cmd={{start,int(d)}};
 else cmd={{start,0},{start+(1-d)*(end-start)/2,1},{start+(1+d)*(end-start)/2,0}};
 std::vector<Phase> phases;double now=start;size_t j=0;
 while(now<end-1e-15){
  int off=-1,on=-1;
  while(j<cmd.size()&&cmd[j].first<=now+1e-15){
   int target=cmd[j++].second;
   if(target!=g.desired){
    if(g.state>=0){off=g.state;g.state=-1;g.last_off=now;}
    g.desired=target;g.pending=target<0?INFINITY:std::max(now,g.last_off+p.td);
   }
  }
  if(g.pending<=now+1e-15){on=g.desired;g.state=g.desired;g.pending=INFINITY;}
  double next=std::min({end,g.pending,j<cmd.size()?cmd[j].first:INFINITY});
  if(!(next>now))throw std::runtime_error("Nonpositive gate segment");
  phases.push_back({now,next,g.state,off,on});now=next;
 }
 return phases;
}
Moments moments(double i,double h,double offset,double rd,double w,const P&p){
 double a=(p.R+rd)/p.L,s=(offset-p.Ke*w)/p.L-a*i,z=a*h;
 if(z>.01)throw std::runtime_error("Electrical moment series outside bounded domain");
 double f1=1+z*(-.5+z*(1./6+z*(-1./24+z*(1./120+z*(-1./720+z/5040)))));
 double f2=.5+z*(-1./6+z*(1./24+z*(-1./120+z*(1./720+z*(-1./5040+z/40320)))));
 double f3=1./3+z*(-.25+z*(7./60+z*(-1./24+z*(31./2520+z*(-1./320+z*127./181440)))));
 return {i+s*h*f1,i*h+s*h*h*f2,i*i*h+2*i*s*h*h*f2+s*s*h*h*h*f3};
}
double zero_time(double i,double offset,double rd,double w,const P&p){
 double a=(p.R+rd)/p.L,eq=(offset-p.Ke*w)/(p.R+rd);return -std::log1p(-i/(i-eq))/a;
}
std::array<double,3> event_heat(double i,double w,double v,bool on,int device,const P&p){
 double tr=0,oss=0,drive=0;
 if(on){
  double pole=i>0?-p.Vf-p.Rd*i:i<0?v+p.Vf-p.Rd*i:p.Ke*w;
  double blocking=std::max(0.,device?v-pole:pole);tr=.5*blocking*std::abs(i)*p.ton;
  oss=.5*p.Ceq*blocking*blocking;drive=p.Qg*p.Vg;
 }else if((device==1&&i>0)||(device==0&&i<0))tr=.5*v*std::abs(i)*p.toff;
 return {tr,oss,drive};
}
void add_event(M&m,bool on,int device,double w,double v,const P&p){
 auto e=event_heat(m.i,w,v,on,device,p);m.tr+=e[0];m.oss+=e[1];m.drive+=e[2];m.imported+=e[0]+e[1]+e[2];
}
void electrical_piece(M&m,double h,int gate,double w,double v,const P&p){
 if(!(p.Ke*w>0&&p.Ke*w<v))throw std::runtime_error("Floating mode outside EMF domain");
 int mode=gate>=0?gate:m.i>0?2:m.i<0?3:4;if(mode==4)return;
 double offset=mode==0?0:mode==1?v:mode==2?-p.Vf:v+p.Vf;
 double rd=mode<=1?p.Ron:p.Rd,i0=m.i;auto q=moments(i0,h,offset,rd,w,p);
 bool zero=mode>=2&&i0*q.i<=0;
 if(zero){h=zero_time(i0,offset,rd,w,p);q=moments(i0,h,offset,rd,w,p);q.i=0;++m.zeros;}
 m.i=q.i;m.q+=q.q;m.q2+=q.q2;m.max_i=std::max({m.max_i,std::abs(i0),std::abs(m.i)});
 m.terminal+=offset*q.q-rd*q.q2;m.em+=p.Ke*w*q.q;
 if(mode<=1)m.ch+=p.Ron*q.q2;else m.diode+=(mode==2?1:-1)*p.Vf*q.q+p.Rd*q.q2;
 if(mode==1||mode==3){
  m.port+=v*q.q;
  if(i0*q.i<0){double hz=zero_time(i0,offset,rd,w,p);auto first=moments(i0,hz,offset,rd,w,p);double second=q.q-first.q;
   m.imported+=v*(std::max(first.q,0.)+std::max(second,0.));m.returned+=v*(std::max(-first.q,0.)+std::max(-second,0.));
  }else{m.imported+=v*std::max(q.q,0.);m.returned+=v*std::max(-q.q,0.);}
 }
}
M electrical_map(double i,double w,double v,const std::vector<Phase>& phases,double a,double b,const P&p){
 M m;m.i=i;m.max_i=std::abs(i);
 for(const auto& ph:phases){
  double left=std::max(a,ph.a),right=std::min(b,ph.b);if(right<=left)continue;
  if(ph.a>=a&&ph.a<b){if(ph.off>=0)add_event(m,false,ph.off,w,v,p);if(ph.on>=0)add_event(m,true,ph.on,w,v,p);}
  electrical_piece(m,right-left,ph.gate,w,v,p);
 }
 return m;
}
double load_at(const Profile& p,double t,size_t& idx){while(idx+1<p.size()&&p[idx+1][0]<=t+1e-11)++idx;return p[idx][2];}
std::array<double,3> load_integrals(const Case&c,double a,double b,bool restoring,size_t&idx){
 std::array<double,3> q{};if(restoring||c.stiff)return q;
 while(a<b-1e-15){double power=load_at(c.profile,a,idx),right=b;
  if(idx+1<c.profile.size())right=std::min(right,c.profile[idx+1][0]);
  if(!(right>a))throw std::runtime_error("Load edge error");
  q[0]+=(right-a)*power;q[1]+=(right-a)*std::max(power,0.);q[2]+=(right-a)*std::max(-power,0.);a=right;
 }return q;
}
void midpoint_step(Y&y,double a,double b,const std::vector<Phase>&ph,const std::array<double,3>&load,const P&p,bool stiff,Stats&s){
 double h=b-a,w0=y[1],v0=y[2],wg=w0,vg=v0,wm=0,vm=0,is=0,chop=0,wn=0,vn=0,defect=0;M m;int it=0;
 for(it=1;it<=10;++it){
  wm=(w0+wg)/2;vm=(v0+vg)/2;m=electrical_map(y[0],wm,vm,ph,a,b,p);
  double fess=m.port+m.tr+m.oss+m.drive;
  is=stiff?0:std::max((p.Vs-vm)/p.Rs,0.);chop=stiff?0:clip((vm-p.chop_on)/p.chop_band,0,1)*vm*vm/p.Rchop;
  wn=(w0*(1-p.b*h/(2*p.J))+(p.Kt*m.q-p.Tc*h)/p.J)/(1+p.b*h/(2*p.J));
  vn=stiff?v0:v0+(vm*is*h-load[0]-fess-chop*h)/(p.C*vm);
  defect=std::max(std::abs(wn-wg),std::abs(vn-vg));wg=wn;vg=vn;if(defect<=5e-13)break;
 }
 if(it>10||!(vn>40&&vn<85&&wn>0))throw std::runtime_error("Midpoint solve/domain failure");
 double events=m.tr+m.oss+m.drive,fess=m.port+events;
 y[0]=m.i;y[1]=wn;y[2]=vn;y[3]+=stiff?fess:p.Vs*is*h;y[4]+=stiff?0:p.Rs*is*is*h;
 y[5]+=load[0];y[6]+=chop*h;y[7]+=m.ch+m.diode+events;y[8]+=p.R*m.q2;
 y[9]+=p.b*wm*wm*h;y[10]+=p.Tc*wm*h;y[11]+=fess;y[12]+=m.imported;y[13]+=m.returned;
 y[14]+=load[1];y[15]+=load[2];y[16]+=m.q;y[17]+=m.ch;y[18]+=m.diode;
 y[19]+=m.tr;y[20]+=m.oss;y[21]+=m.drive;y[22]+=m.terminal;y[23]+=m.em;
 s.zeros+=m.zeros;s.max_i=std::max(s.max_i,m.max_i);s.iterations=std::max(s.iterations,it);s.iter_error=std::max(s.iter_error,defect);
}
Y rhs(const Y&y,int mode,double load,const P&p,bool stiff){
 double i=y[0],w=y[1],v=y[2],va=0,port=0,ch=0,diode=0;
 if(mode==0){va=-p.Ron*i;ch=p.Ron*i*i;}
 else if(mode==1){va=v-p.Ron*i;port=v*i;ch=p.Ron*i*i;}
 else if(mode==2){va=-p.Vf-p.Rd*i;diode=p.Vf*i+p.Rd*i*i;}
 else if(mode==3){va=v+p.Vf-p.Rd*i;port=v*i;diode=-p.Vf*i+p.Rd*i*i;}
 else va=p.Ke*w;
 double is=stiff?0:std::max((p.Vs-v)/p.Rs,0.),chop=stiff?0:clip((v-p.chop_on)/p.chop_band,0,1)*v*v/p.Rchop;
 return {mode==4?0:(va-p.R*i-p.Ke*w)/p.L,(p.Kt*i-p.b*w-p.Tc)/p.J,
  stiff?0:(v*is-load-port-chop)/(p.C*v),stiff?port:p.Vs*is,stiff?0:p.Rs*is*is,load,chop,ch+diode,
  p.R*i*i,p.b*w*w,p.Tc*w,port,std::max(port,0.),std::max(-port,0.),std::max(load,0.),std::max(-load,0.),i,ch,diode,0,0,0,va*i,p.Ke*w*i};
}
Y shift(const Y&y,const Y&dy,double h){Y z;for(int j=0;j<24;++j)z[j]=y[j]+h*dy[j];return z;}
Y rk4(const Y&y,double h,int mode,double load,const P&p,bool stiff){
 auto a=rhs(y,mode,load,p,stiff),b=rhs(shift(y,a,h/2),mode,load,p,stiff),c=rhs(shift(y,b,h/2),mode,load,p,stiff),d=rhs(shift(y,c,h),mode,load,p,stiff);
 Y z;for(int j=0;j<24;++j)z[j]=y[j]+h*(a[j]+2*b[j]+2*c[j]+d[j])/6;return z;
}
void pwm_event(Y&y,bool on,int device,const P&p,bool stiff){
 auto e=event_heat(y[0],y[1],y[2],on,device,p);double total=e[0]+e[1]+e[2];
 if(stiff)y[3]+=total;else y[2]=std::sqrt(y[2]*y[2]-2*total/p.C);
 y[7]+=total;y[11]+=total;y[12]+=total;y[19]+=e[0];y[20]+=e[1];y[21]+=e[2];
}
void pwm_period(Y&y,const std::vector<Phase>&ph,const P&p,const Case&c,size_t&idx,Stats&s){
 for(const auto& f:ph){
  if(f.off>=0)pwm_event(y,false,f.off,p,c.stiff);if(f.on>=0)pwm_event(y,true,f.on,p,c.stiff);
  double now=f.a;
  while(now<f.b-1e-15){
   double load=c.stiff?0:load_at(c.profile,now,idx),end=std::min(f.b,now+1/p.fsw/16);
   if(!c.stiff&&idx+1<c.profile.size())end=std::min(end,c.profile[idx+1][0]);
   double h=end-now;int mode=f.gate>=0?f.gate:y[0]>0?2:y[0]<0?3:4;auto z=rk4(y,h,mode,load,p,c.stiff);
   if(mode>=2&&mode<=3&&y[0]*z[0]<=0){
    double lo=0,hi=h;for(int n=0;n<42;++n){double mid=(lo+hi)/2;auto v=rk4(y,mid,mode,load,p,c.stiff);if(y[0]*v[0]>0)lo=mid;else hi=mid;}
    double root=(lo+hi)/2;z=rk4(y,root,mode,load,p,c.stiff);z[0]=0;z=rk4(z,h-root,4,load,p,c.stiff);++s.zeros;
   }
   y=z;s.max_i=std::max(s.max_i,std::abs(y[0]));now=end;
  }
 }
}
void observe(const Y&y,const U&u,const P&p,double E0,Stats&s){
 s.residual=std::max(s.residual,std::abs(balance(y,p,E0)));s.max_ref=std::max(s.max_ref,std::abs(u.ref));
 s.Vmin=std::min(s.Vmin,y[2]);s.Vmax=std::max(s.Vmax,y[2]);s.nmin=std::min(s.nmin,y[1]/tau);s.nmax=std::max(s.nmax,y[1]/tau);
 if(u.hi)s.hierr=std::max(s.hierr,std::max(u.ref,0.));if(u.lo)s.loerr=std::max(s.loerr,std::max(-u.ref,0.));
 if(u.blocked)s.blockref=std::max(s.blockref,std::abs(u.ref));
 s.split=std::max(s.split,std::abs(y[11]-y[12]+y[13]));s.device_split=std::max(s.device_split,std::abs(y[7]-y[17]-y[18]-y[19]-y[20]-y[21]));
}
void row(std::ofstream&f,double t,const Y&y,double load,const U&u,double duty,double xi,double imeas,const P&p,double E0,bool restore,bool connected){
 f<<t;for(double x:y)f<<','<<x;f<<','<<load<<','<<u.ref<<','<<u.request<<','<<u.target<<','<<u.hi<<','<<u.lo<<','<<u.blocked<<','<<duty<<','<<xi<<','<<imeas;
 f<<','<<y[1]/tau<<','<<.5*p.J*y[1]*y[1]<<','<<.5*p.L*y[0]*y[0]<<','<<.5*p.C*y[2]*y[2]<<','<<balance(y,p,E0)<<','<<restore<<','<<connected<<','<<u.speed_integral<<','<<u.credit<<','<<u.credited<<','<<u.spent<<','<<u.leaked<<','<<u.bus0<<'\n';
}
void simulate(const Case&c,const P&p,const std::filesystem::path&out){
 const P controller; // Fixed nominal controller; NEVER replaced by perturbed plant values.
 double Ts=1/p.fsw,finish=c.task+c.restore;long long cycles=std::llround(finish/Ts),task=std::llround(c.task/Ts);int outer_ticks=std::lround(p.outer/Ts),log_ticks=c.fixture?1:outer_ticks;
 Y y{};y[1]=c.n0*tau;y[2]=c.V0;double E0=E(y,p);Y task_y=y,settle_y=y;Gate gate;if(c.on&&!c.block){gate.state=0;gate.desired=0;}
 U u;u.bus0=y[2];u.hi=c.n0>=p.nmax;u.lo=c.n0<=p.nmin;Stats s;double xi=0,imeas=0,d=0,load=0;size_t idx=0;bool restoring=false,connected=c.on;
 auto csv_path=out/(c.name+".csv"),tmp_path=out/(c.name+".csv.tmp");std::ofstream f(tmp_path);f.exceptions(std::ios::badbit|std::ios::failbit);f<<std::setprecision(17)<<header<<'\n';
 for(long long k=0;k<cycles;++k){
  double t=k*Ts;restoring=k>=task;connected=c.on||restoring;if(k==task)task_y=y;if(k==cycles-std::llround(1/Ts))settle_y=y;
  load=restoring||c.stiff?0:load_at(c.profile,t,idx);
  if(c.fixture){u.ref=fixture_ref(t);u.target=(p.Ke*y[1]+(p.R+p.Ron)*u.ref)*u.ref;}
  else if(k%outer_ticks==0)u=outer(y,load,t,controller,c,u,restoring);
  if(c.block&&k==std::llround(5/Ts))s.entry_i=y[0];if(c.block&&k==std::llround(6/Ts))s.block_end_i=y[0];
  bool enabled=connected&&!u.blocked;
  if(enabled){
   double err=u.ref-imeas,delta=controller.td/Ts;
   double raw=controller.Ke*y[1]+(controller.R+controller.Ron)*u.ref+controller.Kp*err+xi+delta*(y[2]+2*controller.Vf)*clip(imeas/controller.blend,-1,1)+2*delta*(controller.Rd-controller.Ron)*imeas;
   d=clip(raw/y[2],0,1);if((raw>=0&&raw<=y[2])||(raw>y[2]&&err<0)||(raw<0&&err>0))xi+=Ts*controller.Ki*err;
   double minimum=2.2*p.td/Ts;if(d>0&&d<minimum)d=0;else if(d>1-minimum&&d<1)d=1;
  }else d=0;
  observe(y,u,p,E0,s);if(k%log_ticks==0)row(f,t,y,load,u,d,xi,imeas,p,E0,restoring,connected);
  auto phases=schedule(t,(k+1)*Ts,d,enabled,gate,p);double q0=y[16],w_before=y[1];
  if(c.pwm)pwm_period(y,phases,p,c,idx,s);
  else for(int sub=0;sub<c.substeps;++sub){double a=t+sub*Ts/c.substeps,b=t+(sub+1)*Ts/c.substeps;auto q=load_integrals(c,a,b,restoring,idx);midpoint_step(y,a,b,phases,q,p,c.stiff,s);}
  imeas=(y[16]-q0)/Ts;
  if(!restoring&&c.on){
   // Only current and speed measurements enter this controller ledger.
   double work=controller.Ke*.5*(w_before+y[1])*imeas*Ts;
   double gain=(load<0&&u.ref>0)?controller.credit_margin*std::max(work,0.):0.;
   double used=std::max(-work,0.),leak=controller.credit_decay*std::max(u.credit,0.)*Ts;
   u.credit+=gain-used-leak;u.credited+=gain;u.spent+=used;u.leaked+=leak;
  }
  observe(y,u,p,E0,s);
 }
 if(c.restore==0)task_y=y;row(f,finish,y,load,u,d,xi,imeas,p,E0,restoring,connected);
 f.close();std::filesystem::rename(tmp_path,csv_path);
 double target_i=(p.b*p.restore_rpm*tau+p.Tc)/p.Kt;
 std::ofstream j(out/(c.name+"_metrics.json"));j.exceptions(std::ios::badbit|std::ios::failbit);j<<std::setprecision(17)<<"{\"case_name\":\""<<c.name<<"\"";
 #define FIELD(n,x) j<<",\""<<n<<"\":"<<(x)
 FIELD("task_s",c.task);FIELD("restore_s",c.restore);FIELD("max_balance_J",s.residual);FIELD("max_current_A",s.max_i);FIELD("max_reference_A",s.max_ref);
 FIELD("Vmin",s.Vmin);FIELD("Vmax",s.Vmax);FIELD("nmin",s.nmin);FIELD("nmax",s.nmax);FIELD("high_direction_error_A",s.hierr);FIELD("low_direction_error_A",s.loerr);
 FIELD("blocked_reference_A",s.blockref);FIELD("block_entry_i_A",s.entry_i);FIELD("block_end_i_A",s.block_end_i);FIELD("zero_events",s.zeros);
 FIELD("max_midpoint_iterations",s.iterations);FIELD("midpoint_defect",s.iter_error);FIELD("ledger_split_error_J",s.split);FIELD("device_split_error_J",s.device_split);
 FIELD("task_source_J",task_y[3]);FIELD("restore_source_J",y[3]-task_y[3]);FIELD("total_source_J",y[3]);FIELD("total_losses_J",loss(y));
 FIELD("task_chopper_J",task_y[6]);FIELD("task_charge_J",task_y[12]);FIELD("task_return_J",task_y[13]);FIELD("load_J",y[5]);
 FIELD("channel_J",y[17]);FIELD("diode_J",y[18]);FIELD("transition_J",y[19]);FIELD("oss_J",y[20]);FIELD("gate_J",y[21]);
 FIELD("final_rpm",y[1]/tau);FIELD("final_i_A",y[0]);FIELD("final_V",y[2]);FIELD("target_rpm_error",std::abs(y[1]/tau-p.restore_rpm));
 FIELD("target_mean_current_error_A",std::abs(imeas-target_i));FIELD("final_second_store_drift_J",std::abs(.5*p.J*(y[1]*y[1]-settle_y[1]*settle_y[1]))+std::abs(.5*p.L*(y[0]*y[0]-settle_y[0]*settle_y[0]))+std::abs(.5*p.C*(y[2]*y[2]-settle_y[2]*settle_y[2])));
 FIELD("plant_R",p.R);FIELD("plant_L",p.L);FIELD("plant_J",p.J);FIELD("plant_b",p.b);FIELD("plant_Tc",p.Tc);
 FIELD("plant_Ron",p.Ron);FIELD("plant_Rd",p.Rd);FIELD("plant_Vf",p.Vf);FIELD("plant_Vs",p.Vs);FIELD("plant_Rs",p.Rs);FIELD("plant_C",p.C);FIELD("plant_deadtime_s",p.td);
 FIELD("controller_R",controller.R);FIELD("controller_b",controller.b);FIELD("controller_deadtime_s",controller.td);
 FIELD("controller_Kp",controller.Kp);FIELD("controller_Ki",controller.Ki);FIELD("speed_Kp",controller.speed_Kp);FIELD("speed_Ki",controller.speed_Ki);
 FIELD("speed_pi_enabled",c.speed_pi);FIELD("speed_integrator_A",u.speed_integral);
 FIELD("recovery_credit_J",u.credit);FIELD("credited_J",u.credited);FIELD("spent_J",u.spent);FIELD("leaked_J",u.leaked);FIELD("initial_bus_V",u.bus0);
 FIELD("credit_decay_per_s",controller.credit_decay);FIELD("credit_margin",controller.credit_margin);FIELD("credit_reserve_J",controller.credit_reserve);FIELD("credit_time_s",controller.credit_time);FIELD("loss_fraction",controller.loss_fraction);
 #undef FIELD
 j<<"}\n";j.close();std::cout<<c.name<<" source="<<y[3]<<" balance="<<s.residual<<" V="<<y[2]<<" rpm="<<y[1]/tau<<std::endl;
}
int main(int argc,char**argv){try{
 std::filesystem::path out=argc>1?argv[1]:"cpp_reference_output";std::filesystem::create_directories(out);
 Profile rail(train_profile.begin(),train_profile.end());
 Profile pulse={{0,2,0},{2,2,300},{4,4,-400},{8,2,0},{10,4,250},{14,4,-250},{18,2,250}};
 Profile depleted={{0,1,0},{1,1,-120},{2,18,300}};
 Profile traction=rail;for(auto&x:traction)x[2]=std::max(x[2],0.);
 std::vector<std::pair<Case,P>> cases;
 auto append=[&](std::string name,P p,bool on,const Profile&profile,double restore=70){
  Case c;c.name=name;c.profile=profile;c.on=on;c.task=20;c.restore=restore;c.V0=p.Vs;cases.push_back({c,p});
 };
 P nominal,friction,combined,strong;friction.b=.0015;friction.Tc=.075;
 combined.R=1.;combined.L=.014;combined.J=.65;combined.b=.0015;combined.Tc=.075;
 combined.Ron=.03;combined.Rd=.015;combined.Vf=.8;combined.td=2e-6;combined.Vs=57;combined.Rs=.45;combined.C=.08;
 strong.Vs=63;strong.Rs=.2;strong.C=.12;
 append("01_nominal_bypass",nominal,false,rail);append("02_nominal_dispatch",nominal,true,rail);
 append("03_friction_bypass",friction,false,rail);append("04_friction_dispatch",friction,true,rail);
 append("05_combined_bypass",combined,false,rail);append("06_combined_dispatch",combined,true,rail);
 append("07_pulse_bypass",combined,false,pulse);append("08_pulse_dispatch",combined,true,pulse);
 append("09_no_regeneration",combined,true,traction,0);append("10_high_source",strong,true,rail,0);
 append("11_credit_depletion",combined,true,depleted,0);
 for(const auto& item:cases)if(argc<=2||item.first.name==argv[2])simulate(item.first,item.second,out);
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
