"""Verify recursion removal and execute the actual guarded engine with simulated MT5 calls."""
from pathlib import Path
import subprocess,tempfile
from source_call_graph import functions,graph,cycles
root=Path(__file__).resolve().parents[1]
s=(root/'SEGS_Trade_Manager_Pro_v3.78.mq5').read_text();defs=functions(s);g=graph(s)
assert not cycles(g),cycles(g)
# No render callback can reach scanner or execution, even through other helpers.
def reachable(name):
 result=set();pending=list(g[name])
 while pending:
  n=pending.pop()
  if n not in result:result.add(n);pending.extend(g[n])
 return result
for render in ('DrawSentimentHUD','DrawUnifiedTerminalDashboard','UpdateTradeAdviceLines'):
 assert not reachable(render)&{'ScanMarketStructureAndAdvice','CheckAndAutoTradeAdvice','ExecuteAdvisedTrade','RunAdvisorStrategyEngine'},render
assert 'CheckAndAutoTradeAdvice' not in reachable('ScanMarketStructureAndAdvice')
assert g['RunAdvisorStrategyEngine'] >= {'ScanMarketStructureAndAdvice','CheckAndAutoTradeAdvice'}
for name in ('RunAdvisorStrategyEngine','ScanMarketStructureAndAdvice','DrawSentimentHUD','CheckAndAutoTradeAdvice','ExecuteAdvisedTrade'):
 body=s[defs[name][0]:defs[name][1]]
 assert body.lstrip().startswith('CSEGSCallbackGuard callbackGuard('),name
engine='void RunAdvisorStrategyEngine(bool forceScan, bool allowAutoTrade)\n{'+s[defs['RunAdvisorStrategyEngine'][0]:defs['RunAdvisorStrategyEngine'][1]]+'\n}\n'
a=s.index('enum ENUM_SEGS_CALLBACK_SLOT');b=s.index('// Readiness is checked again',a);guard=s[a:b]
code=r'''
#include <string>
#include <cassert>
#include <iostream>
using string=std::string;using ulong=unsigned long;
bool g_runtimeReady=true,marketReady=true,resetExpired=false,recursiveScan=false;
string _Symbol="USDJPY";ulong nowMs=1000;
int scans=0,autoChecks=0,liquidityUpdates=0;
bool SEGSMarketReady(string){return marketReady;}
ulong GetTickCount64(){return nowMs;}
long ChartID(){return 10;}
string IntegerToString(long x){return std::to_string(x);}
void GlobalVariableSet(string,double){}
void UpdateHTFLiquidityLevels(string){liquidityUpdates++;}
void UpdateM30OrderBlocks(bool){}void UpdateH1OrderBlocks(bool){}
void RunAdvisorStrategyEngine(bool,bool);
void ScanMarketStructureAndAdvice(bool){scans++;if(recursiveScan)RunAdvisorStrategyEngine(true,true);}
bool SEGSResetExpiredSetup(string){bool old=resetExpired;resetExpired=false;return old;}
void SEGSCalibrateActiveZoneProtection(){}
void UpdateOBLocationSnapshot(string){}void UpdateH1OBLocationSnapshot(string){}
void CheckAndAutoTradeAdvice(){autoChecks++;}
'''+guard+engine+r'''
int main(){
 g_runtimeReady=false;RunAdvisorStrategyEngine(true,true);
 assert(scans==0&&!g_segsCallbackBusy[SEGS_CALLBACK_ENGINE]);
 g_runtimeReady=true;marketReady=false;RunAdvisorStrategyEngine(true,true);
 assert(scans==0&&!g_segsCallbackBusy[SEGS_CALLBACK_ENGINE]);
 marketReady=true;RunAdvisorStrategyEngine(true,false);assert(scans==1&&autoChecks==0);
 nowMs=1001;RunAdvisorStrategyEngine(false,true);assert(scans==1&&autoChecks==0);
 nowMs=2000;RunAdvisorStrategyEngine(false,true);assert(scans==2&&autoChecks==1);
 resetExpired=true;RunAdvisorStrategyEngine(true,true);assert(scans==4&&autoChecks==2);
 recursiveScan=true;RunAdvisorStrategyEngine(true,true);assert(scans==5&&autoChecks==3);
 recursiveScan=false;RunAdvisorStrategyEngine(true,true);assert(scans==6&&autoChecks==4);
 assert(!g_segsCallbackBusy[SEGS_CALLBACK_ENGINE]);
 for(int slot=0;slot<5;slot++){
  {CSEGSCallbackGuard owner(slot);assert(owner.Entered());
   {CSEGSCallbackGuard nested(slot);assert(!nested.Entered());}
   assert(g_segsCallbackBusy[slot]);}
  assert(!g_segsCallbackBusy[slot]);
 }
 std::cout<<"Guarded engine passed readiness, throttle, scan-only, bounded rescan, recursion and 5-slot ownership checks\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'test.cpp';p.write_text(code);exe=Path(tmp)/'test'
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
print('Full source call graph is acyclic; rendering cannot scan or execute; scanner cannot execute')
print('These are stubbed C++/source tests, not native MQL5 compilation or terminal crash tests.')
