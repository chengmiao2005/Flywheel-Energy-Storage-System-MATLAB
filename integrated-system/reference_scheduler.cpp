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

struct ControlMemory{U u;double xi=0,previous_load=0;bool previous_restore=false;};
struct ControlOutput{ControlMemory next;double duty=0;bool enabled=false;};
ControlOutput controller_output(double t,long long k,const Y&sense,double imeas,double wprevious,double power,
 const ControlMemory&memory,const P&nominal,const Case&c){
 ControlOutput out;out.next=memory;U&u=out.next.u;double&xi=out.next.xi;double Ts=1/nominal.fsw;
 bool restoring=k>=std::llround(c.task/Ts),connected=c.on||restoring;
 if(k==0)u.bus0=sense[2];
 else if(c.on&&!memory.previous_restore){
  double work=nominal.Ke*.5*(wprevious+sense[1])*imeas*Ts;
  double gain=(memory.previous_load<0&&u.ref>0)?nominal.credit_margin*std::max(work,0.):0.;
  double used=std::max(-work,0.),leak=nominal.credit_decay*std::max(u.credit,0.)*Ts;
  u.credit+=gain-used-leak;u.credited+=gain;u.spent+=used;u.leaked+=leak;
 }
 if(k%std::lround(nominal.outer/Ts)==0)u=outer(sense,power,t,nominal,c,u,restoring);
 out.enabled=connected&&!u.blocked;
 if(out.enabled){
  double err=u.ref-imeas,delta=nominal.td/Ts;
  double raw=nominal.Ke*sense[1]+(nominal.R+nominal.Ron)*u.ref+nominal.Kp*err+xi
   +delta*(sense[2]+2*nominal.Vf)*clip(imeas/nominal.blend,-1,1)+2*delta*(nominal.Rd-nominal.Ron)*imeas;
  out.duty=clip(raw/sense[2],0,1);
  if((raw>=0&&raw<=sense[2])||(raw>sense[2]&&err<0)||(raw<0&&err>0))xi+=Ts*nominal.Ki*err;
 }
 out.next.previous_load=power;out.next.previous_restore=restoring;return out;
}
double physical_driver(double d,const P&p){double minimum=2.2*p.td*p.fsw;
 if(d>0&&d<minimum)d=0;else if(d>1-minimum&&d<1)d=1;return d;}
int main(int argc,char**argv){try{
 std::filesystem::path out=argc>1?argv[1]:"scheduler_output";std::filesystem::create_directories(out);
 const P nominal;P p;p.R=1;p.L=.014;p.J=.65;p.b=.0015;p.Tc=.075;p.Ron=.03;p.Rd=.015;p.Vf=.8;p.td=2e-6;p.Vs=57;p.Rs=.45;p.C=.08;
 Case c;c.name="scheduler_combined";c.profile=Profile(train_profile.begin(),train_profile.end());c.task=20;c.restore=70;c.V0=57;
 Y y{};y[1]=3000*tau;y[2]=57;double E0=E(y,p),imeas=0,wprevious=y[1];Gate gate;gate.state=0;gate.desired=0;
 ControlMemory memory;Stats stats;size_t idx=0;double Ts=1/nominal.fsw;long long cycles=std::llround(90/Ts);
 auto csv=out/"scheduler_trace.csv",tmp=out/"scheduler_trace.csv.tmp";std::ofstream f(tmp);f.exceptions(std::ios::failbit|std::ios::badbit);f<<std::setprecision(17)<<header<<'\n';
 double max_purity_error=0;
 for(long long k=0;k<=cycles;++k){
  double t=k*Ts;bool restoring=k>=std::llround(c.task/Ts);double power=restoring?0:load_at(c.profile,t,idx);
  // Only measurable states reach the controller; never cumulative energy or actual parameters.
  Y sense{};sense[0]=y[0];sense[1]=y[1];sense[2]=y[2];
  auto control=controller_output(t,k,sense,imeas,wprevious,power,memory,nominal,c);
  double applied=physical_driver(control.duty,p);
  if(k%200==0){
   auto repeat=controller_output(t,k,sense,imeas,wprevious,power,memory,nominal,c);
   max_purity_error=std::max({max_purity_error,std::abs(control.duty-repeat.duty),std::abs(control.next.xi-repeat.next.xi),
    std::abs(control.next.u.credit-repeat.next.u.credit),std::abs(control.next.u.ref-repeat.next.u.ref)});
   row(f,t,y,power,control.next.u,applied,control.next.xi,imeas,p,E0,restoring,true);
  }
  if(k==cycles)break;
  memory=control.next;
  auto q=load_integrals(c,t,t+Ts,restoring,idx);auto phases=schedule(t,(k+1)*Ts,applied,control.enabled,gate,p);
  double q0=y[16];wprevious=y[1];midpoint_step(y,t,t+Ts,phases,q,p,false,stats);imeas=(y[16]-q0)/Ts;observe(y,memory.u,p,E0,stats);
 }
 f.close();std::filesystem::rename(tmp,csv);
 std::ofstream j(out/"scheduler_metrics.json");j.exceptions(std::ios::failbit|std::ios::badbit);
 j<<std::setprecision(17)<<"{\"max_purity_error\":"<<max_purity_error<<",\"max_current_A\":"<<stats.max_i
  <<",\"max_balance_J\":"<<stats.residual<<",\"midpoint_defect\":"<<stats.iter_error<<"}\n";j.close();
 std::cout<<"Scheduler completed: 90 s, "<<y[3]<<" J source energy, purity error "<<max_purity_error<<'\n';
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
