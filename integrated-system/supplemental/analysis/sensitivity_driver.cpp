// Supplemental study: same original 12 pairs, restored after workspace reset.
// Reuses the accepted core; not independent physical/MATLAB validation.
#define main accepted_reference_original_main
#include "reference_dispatch.cpp"
#undef main
struct StudyCase {std::string id; P plant;};
int main(int argc,char**argv) { try {
  if(argc!=3) { std::cerr<<"Usage: sensitivity_driver OUTPUT_DIR CASE_ID\n"; return 2; }
  const std::filesystem::path out=argv[1];std::filesystem::create_directories(out);
  std::vector<StudyCase> v;P p;
  v.push_back({"nominal",p});
  p=P{};p.R=1.;v.push_back({"R_high",p});
  p=P{};p.L=.014;v.push_back({"L_low",p});
  p=P{};p.J=.65;v.push_back({"J_high",p});
  p=P{};p.b=.0015;v.push_back({"b_high",p});
  p=P{};p.Tc=.075;v.push_back({"Tc_high",p});
  p=P{};p.Vs=57;v.push_back({"Vs_low",p});
  p=P{};p.Rs=.45;v.push_back({"Rs_high",p});
  p=P{};p.C=.08;v.push_back({"C_low",p});
  p=P{};p.b=.0015;p.Tc=.075;v.push_back({"friction_high",p});
  p=P{};p.Ron=.03;p.Rd=.015;p.Vf=.8;p.td=2e-6;v.push_back({"device_high",p});
  p=P{};p.R=1.;p.L=.014;p.J=.65;p.b=.0015;p.Tc=.075;
  p.Ron=.03;p.Rd=.015;p.Vf=.8;p.td=2e-6;p.Vs=57;p.Rs=.45;p.C=.08;
  v.push_back({"combined",p});
  const std::string requested=argv[2];bool found=false;
  for(const auto& x:v) for(bool enabled:{false,true}) {
    Case c;c.name=x.id+(enabled?"_dispatch":"_bypass");
    if(c.name!=requested)continue;found=true;c.profile=Profile(train_profile.begin(),train_profile.end());
    c.on=enabled;c.task=20;c.restore=70;c.n0=3000;c.V0=x.plant.Vs;
    simulate(c,x.plant,out);
  }
  if(!found)throw std::runtime_error("Unknown study case: "+requested);
  return 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;} }

