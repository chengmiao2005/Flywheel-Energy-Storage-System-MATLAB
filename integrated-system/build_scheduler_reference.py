"""Independent scheduler refactor: output first, one state commit per tick."""
from pathlib import Path
import hashlib,json
HERE=Path(__file__).resolve().parent
base=(HERE/'accepted_core/reference_dispatch.cpp').read_text()
# Retain the accepted physical routines, supervisor and output format.
s=base[:base.index('void simulate(')]
s+=r'''
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
'''
core='std::vector<Phase> schedule(';end='void row('
assert base[base.index(core):base.index(end)]==s[s.index(core):s.index(end)]
(HERE/'reference_scheduler.cpp').write_text(s)
print('Built independent callback-order scheduler with accepted physical core')
