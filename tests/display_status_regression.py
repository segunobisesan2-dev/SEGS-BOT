"""Run the read-only broker-status resolver independently of quote/history freshness."""
from pathlib import Path
import ast,re,subprocess,tempfile
r=Path(__file__).resolve().parents[1];s=(r/'SEGS.mq5').read_text()
tree=ast.parse((r/'tests/multi_setup_regression.py').read_text())
preamble=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='preamble' for t in n.targets))
preamble=preamble.replace('#include <string>','#include <string>\n#include <cmath>')
preamble=preamble.replace('datetime time;};std::vector<Position>', 'datetime time;int type=0;double entry=93.54,stop=89.89,tp=101,volume=1;};std::vector<Position>')
preamble=preamble.replace(' datetime Time(){return positions.at(selected).time;}', ''' int PositionType(){return positions.at(selected).type;}
 double PriceOpen(){return positions.at(selected).entry;}double StopLoss(){return positions.at(selected).stop;}
 double Volume(){return positions.at(selected).volume;}double TakeProfit(){return positions.at(selected).tp;}
 datetime Time(){return positions.at(selected).time;}''')
preamble+='''
bool InpShowActiveLegCounts=true,InpShowOverallActiveRR=true,InpShowPerLegActiveRR=true;
bool g_showActiveLegCounts=true,g_showOverallActiveRR=true,g_showPerLegActiveRR=true;
typedef int ENUM_ORDER_TYPE; const int ORDER_TYPE_BUY=0,ORDER_TYPE_SELL=1;
bool OrderCalcProfit(int type,string,double volume,double entry,double exit,double &p){p=(exit-entry)*volume*(type==0 ? 1 : -1);return true;}
const int POSITION_TYPE_BUY=0,POSITION_TYPE_SELL=1,SYMBOL_TRADE_TICK_SIZE=0,SYMBOL_DIGITS=1;
string g_currentSignalID="RESTORED_NDAQ",g_currentAdvisedAction="BUY",g_setupState="TRIGGERED";
bool g_isSignalExpired=false;double g_staticEntryPrice=93.54,g_staticSL=89.89;
datetime g_signalTriggerTime=1;
long SymbolInfoInteger(string,int){return 5;}
string DoubleToString(double n,int digits){char out[100];std::snprintf(out,sizeof(out),"%.*f",digits,n);return out;}
double SymbolInfoDouble(string,int){return .01;}double MathAbs(double x){return std::abs(x);}
'''
def extract(name):
 m=re.search(r'^(?:void|bool|int|string|uint) '+name+r'\([^;]*?\)\n\{',s,re.M);assert m,name
 i=m.end();depth=1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[m.start():i]+'\n'
a=s.index('struct SEGSActiveDisplay\n');b=s.index('};',a)+2
code=s[a:b]+'\n'+'\n'.join(extract(n) for n in ['SEGSHistoryHash','SEGSShortSignalID','SEGSExecutionKey','HasOpenAdvisorTradesForSignal','SEGSSelectedAdvisorPosition','SEGSReadActiveDisplay','SEGSHasDisplayPlan','SEGSDisplayKey','SEGSSyncDisplaySettings','SEGSOpenedLegKey','SEGSOriginalOpenedLegs','SEGSFormatActiveRR','SEGSActiveRR'])
code=code.replace('SEGSActiveDisplay &rows[]','std::vector<SEGSActiveDisplay> &rows')
tests=r'''
string tag(string key){return "SEGS|ADV|"+key+"|L1/4";}
int main(){int checks=0;std::vector<SEGSActiveDisplay> rows;
 // Screenshot case: existing old-version fills remain active despite an unrelated restored candidate ID.
 for(int i=0;i<4;i++)positions.push_back({"NDAQ",tag("old_timestamp_id"),123,i+1,100+i});
 assert(SEGSReadActiveDisplay("NDAQ",rows)==1&&rows[0].legs==4);checks++;
 assert(rows[0].direction=="BUY"&&rows[0].entryLow==93.54&&rows[0].stopLow==89.89);checks++;
 assert(!SEGSHasDisplayPlan("NDAQ"));checks++;
 // Empty current signal cannot hide actual active entries after restart.
 g_currentSignalID="";assert(SEGSReadActiveDisplay("NDAQ",rows)==1);checks++;
 assert(!SEGSHasDisplayPlan("NDAQ"));checks++;
 // A new independently generated candidate coexists with those existing positions.
 g_currentSignalID="next_signal";g_signalTriggerTime=200;g_staticEntryPrice=92;g_staticSL=91;g_setupState="WATCHING";
 assert(SEGSHasDisplayPlan("NDAQ"));checks++;
 assert(SEGSReadActiveDisplay("NDAQ",rows)==1&&rows[0].entryLow==93.54);checks++;
 // In-flight or TRIGGERED approval does not count as an active fill.
 positions.clear();g_setupState="TRIGGERED";
 globals[SEGSExecutionKey(g_currentSignalID,false)]=1;
 assert(SEGSReadActiveDisplay("NDAQ",rows)==0&&SEGSHasDisplayPlan("NDAQ"));checks++;
 // Once actually filled, that candidate is no longer a planned entry.
 positions.push_back({"NDAQ",tag(SEGSShortSignalID(g_currentSignalID)),123,9,210,0,92,91});
 assert(SEGSReadActiveDisplay("NDAQ",rows)==1&&!SEGSHasDisplayPlan("NDAQ"));checks++;
 // Closed/executed IDs must not reappear as a plan simply because the position is gone.
 positions.clear();globals[SEGSExecutionKey(g_currentSignalID,false)]=2;
 assert(SEGSReadActiveDisplay("NDAQ",rows)==0&&!SEGSHasDisplayPlan("NDAQ"));checks++;
 globals.clear();
 // Opposite directions / multiple setup identities stay separate on the same symbol.
 positions={{"NDAQ",tag("one"),123,10,100,0,93,89},{"NDAQ",tag("two"),123,11,200,1,94,96}};
 assert(SEGSReadActiveDisplay("NDAQ",rows)==2);checks++;
 assert(rows[0].direction!=rows[1].direction);checks++;
 assert(SEGSReadActiveDisplay("AMD",rows)==0);checks++;
 positions.push_back({"AMD",tag("one"),123,12,100,0,160,155});
 assert(SEGSReadActiveDisplay("NDAQ",rows)==2&&SEGSReadActiveDisplay("AMD",rows)==1&&rows[0].entryLow==160);checks++;
 // Different leg fill prices are shown as a range, not mislabeled with an invented single entry.
 positions={{"USDCHF",tag("same"),123,13,100,1,.8312,.833},{"USDCHF",tag("same"),123,14,101,1,.8314,.833}};
 assert(SEGSReadActiveDisplay("USDCHF",rows)==1&&rows[0].entryLow==.8312&&rows[0].entryHigh==.8314);checks++;
 positions.pop_back();assert(SEGSReadActiveDisplay("USDCHF",rows)==1&&rows[0].legs==1);checks++;
 positions.clear();assert(SEGSReadActiveDisplay("USDCHF",rows)==0);checks++;
 // Ordinary unrelated manual trades are not silently relabeled as advisor fills.
 positions={{"NDAQ","",0,15,100}};assert(SEGSReadActiveDisplay("NDAQ",rows)==0);checks++;
 // Screenshot: old four-leg entries without a recoverable setup tag produce ONE active price row.
 positions.clear();for(int i=0;i<4;i++)positions.push_back({"USDJPY","[MyAdvisor]",123,20+i,100+i,0,158.363,157.398});
 assert(SEGSReadActiveDisplay("USDJPY",rows)==1&&rows[0].legs==4&&rows[0].legacy);checks++;
 assert(rows[0].opened==100&&rows[0].lastOpened==103);checks++;
 // Distinct known setups with identical prices are intentionally preserved as separate setups.
 positions={{"USDJPY",tag("first"),123,30,100,0,158.363,157.398},{"USDJPY",tag("second"),123,31,200,0,158.363,157.398}};
 assert(SEGSReadActiveDisplay("USDJPY",rows)==2&&!rows[0].legacy&&!rows[1].legacy);checks++;
 // Unknown legacy entries separated in time share a price row with an honest first/last fill range.
 positions={{"USDJPY","[MyAdvisor]",123,40,100,0,158.363,157.398},{"USDJPY","[MyAdvisor]",123,41,90000,0,158.363,157.398}};
 assert(SEGSReadActiveDisplay("USDJPY",rows)==1&&rows[0].opened==100&&rows[0].lastOpened==90000);checks++;
 // Slightly different fills consolidate in the HUD; raw setup identities remain distinct.
 positions={{"GBPUSD",tag("a"),123,51,100,1,100,110,80,1},{"GBPUSD",tag("b"),123,52,101,1,101,111,61,3}};
 string overall,detail;SEGSActiveRR("GBPUSD",overall,detail);
 assert(overall=="1:3.50");checks++; // 140 cash reward / 40 cash risk, not mean(2,4).
 assert(detail.find("#1 1:2.00")!=string::npos&&detail.find("#2 1:4.00")!=string::npos);checks++;
 positions[0].stop=0;SEGSActiveRR("GBPUSD",overall,detail);assert(overall=="N/A");checks++;
 positions[0].stop=99;positions[1].stop=100;SEGSActiveRR("GBPUSD",overall,detail);assert(overall=="PROTECTED");checks++;
 positions[0].tp=0;SEGSActiveRR("GBPUSD",overall,detail);assert(overall=="N/A");checks++;
 SEGSActiveRR("NDAQ",overall,detail);assert(overall=="N/A"&&detail=="");checks++;
 assert(SEGSReadActiveDisplay("GBPUSD",rows)==2);checks++;
 assert(SEGSOriginalOpenedLegs("GBPUSD",rows)==-1);checks++;
 globals[SEGSOpenedLegKey("GBPUSD","a")]=4;globals[SEGSOpenedLegKey("GBPUSD","b")]=4;
 assert(SEGSOriginalOpenedLegs("GBPUSD",rows)==8);checks++;
 SEGSSyncDisplaySettings(true);assert(g_showOverallActiveRR&&g_showPerLegActiveRR&&g_showActiveLegCounts);checks++;
 InpShowPerLegActiveRR=false;SEGSSyncDisplaySettings();assert(g_showPerLegActiveRR);checks++;
 SEGSSyncDisplaySettings(true);assert(!g_showPerLegActiveRR);checks++;
 account=2;SEGSSyncDisplaySettings();assert(!g_showPerLegActiveRR);checks++;
 account=1;InpShowPerLegActiveRR=true;SEGSSyncDisplaySettings();assert(!g_showPerLegActiveRR);checks++;
 std::cout<<checks<<" active/planned display assertions passed\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'display.cpp';p.write_text(preamble+code+tests);exe=Path(d)/'display'
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
collector=extract('SEGSReadActiveDisplay')
assert not any(x in collector for x in ['SEGSQuoteFresh','GetSafestStructuralStopLoss','HealOpenAdvisorPositions','trade.'])
hud=s.split('void DrawSentimentHUD()\n{',1)[1].split('void DeleteWinRateHUD()',1)[0]
assert 'SEGSReadActiveDisplay(_Symbol,activeRows)' in hud
assert 'NO ACTIVE TRADE OPENED' not in hud
assert 'bool isTradeTaken=activeCount>0;' in hud
assert 'ACTIVE_ENTRY_' in s and 'NEXT PLANNED ENTRY' in s
print('Broker status is independent of quotes and candidate state; native MT5 UI validation remains required.')

assert 'FormatExecutionTime(first,true)' in hud
assert 'SNT_C3_ACTIVE_SUMMARY' in hud
assert 'SNT_C3_ACTIVE_"+IntegerToString(i)' not in hud
assert 'SEGSSyncDisplaySettings(InpPublishDisplaySettingsToAllCharts)' in s
