"""Execute the actual EA role helpers and closed-bar replay loop using C++ MT5 stubs."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'SEGS_Trade_Manager_Pro_v3.77.mq5').read_text()
a=s.index('struct M30OrderBlock\n{');b=s.index('M30OrderBlock g_orderBlocks[];',a)
helpers=s[a:b]
a=s.index('      for(int j = i - 3; j >= 1; j--)');b=s.index('\n      if(ob.awaitingRoleRetest) ob.invalidated',a)
loop=s[a:b]
code=r'''
#include <string>
#include <vector>
#include <algorithm>
#include <cassert>
#include <iostream>
using string=std::string; using datetime=long long;
template<class A,class B> double MathMax(A a,B b){return std::max(double(a),double(b));}
template<class A,class B> double MathMin(A a,B b){return std::min(double(a),double(b));}
bool InpEnableOBRoleReversal=true, InpOBUseLiquiditySweep=true; int InpOBMaxRoleReversals=3;
struct MqlRates {datetime time;double low,high,close;};
'''+helpers+r'''
M30OrderBlock replay(bool bullish, const std::vector<MqlRates> &chronological) {
 M30OrderBlock ob{};ob.bullish=bullish;ob.low=100;ob.high=110;
 ob.touchCount=7;ob.zoneDefended=true;ob.hasFVG=true;ob.liquidityBonus=25;
 std::vector<MqlRates> r(chronological.size()+1);
 for(size_t k=0;k<chronological.size();k++)r[chronological.size()-k]=chronological[k];
 int copied=r.size(),i=copied+2;
 double invalidBuffer=1,sweepTolerance=2;
'''+loop+r'''
 if(ob.awaitingRoleRetest)ob.invalidated=true;
 return ob;
}
int main(){
 auto ob=replay(false,{{1,109,113,112}});
 assert(ob.bullish&&ob.roleReversals==1&&ob.awaitingRoleRetest&&ob.invalidated);
 assert(ob.touchCount==0&&!ob.hasFVG&&!ob.zoneDefended&&ob.liquidityBonus==0);
 ob=replay(false,{{1,109,113,112},{2,109,114,113}});
 assert(ob.bullish&&!ob.awaitingRoleRetest&&!ob.invalidated&&ob.touchCount==1&&ob.zoneDefended);
 ob=replay(true,{{1,97,101,98},{2,96,102,99}});
 assert(!ob.bullish&&ob.roleReversals==1&&!ob.invalidated&&ob.zoneDefended);
 ob=replay(false,{{1,109,120,109}}); // Wick only: no conversion.
 assert(!ob.bullish&&ob.roleReversals==0&&!ob.invalidated);
 ob=replay(false,{{1,109,113,112},{2,111,115,114}}); // No overlap, still pending.
 assert(ob.awaitingRoleRetest&&ob.invalidated);
 ob=replay(false,{{1,109,113,112},{2,97,102,98},{3,96,102,99}});
 assert(!ob.bullish&&ob.roleReversals==2&&!ob.invalidated&&ob.roleChangeTime==2);
 InpOBMaxRoleReversals=1;
 ob=replay(false,{{1,109,113,112},{2,97,102,98}});
 assert(ob.invalidated&&!ob.awaitingRoleRetest&&ob.status=="BROKEN");
 InpEnableOBRoleReversal=false;
 ob=replay(false,{{1,109,113,112}});
 assert(ob.invalidated&&ob.roleReversals==0);
 InpEnableOBRoleReversal=true;InpOBMaxRoleReversals=3;
 auto first=replay(false,{{1,109,113,112},{2,109,114,113}});
 auto restarted=replay(false,{{1,109,113,112},{2,109,114,113}});
 assert(first.bullish==restarted.bullish&&first.roleChangeTime==restarted.roleChangeTime&&first.touchCount==restarted.touchCount);
 M30OrderBlock direct{};direct.low=100;direct.high=110;
 assert(SEGSReverseOrderBlock(direct,5));
 assert(!SEGSConfirmRoleRetest(direct,{5,109,114,113})); // Break bar cannot retest itself.
 assert(SEGSConfirmRoleRetest(direct,{6,109,114,113}));
 std::cout<<"10 role reversal/retest scenarios passed using extracted EA functions and replay loop\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'test.cpp';p.write_text(code);exe=Path(tmp)/'test'
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
# Verify both actual scanners share conversion/retest gating and source-index fix.
assert s.count('if(SEGSReverseOrderBlock(ob, r[j].time)) continue;')==2
assert s.count('if(ob.awaitingRoleRetest && !SEGSConfirmRoleRetest(ob, r[j])) continue;')==2
assert s.count('if(ob.awaitingRoleRetest) ob.invalidated = true;')==2
for side,flag in [('Demand','dem'),('Supply','sup')]:
 start=s.index(f'bool has{side}OBConfluence =');tail=s[start:]
 for line in tail.splitlines():
  if f'g_orderBlocks[confluent{side}OB]' in line:
   assert f'{flag}OBIsFromH1 ?' in line,line
assert 'iTime(sym, tf, b) <= roleEpoch' in s
assert 'roleEpoch > 0 && (!GlobalVariableCheck(epochKey)' in s
assert 'SaveAdvisorPersistentState();\n      lastCheckpointMs' in s
print('M30/H1 integration, bounce epoch, index source and checkpoint guards passed')
