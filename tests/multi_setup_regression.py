"""Run the actual setup identity, set-count and fresh-confirmation functions with broker stubs."""
from pathlib import Path
import re,subprocess,tempfile
r=Path(__file__).resolve().parents[1];s=(r/'SEGS_Trade_Manager_Pro_v3.79.mq5').read_text()
def extract(name):
 m=re.search(r'^(?:bool|int|string|uint|void) '+name+r'\([^;]*?\)\n\{',s,re.M);assert m,name
 i=m.end();depth=1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[m.start():i]+'\n'
code='\n'.join(extract(n) for n in ['SEGSStopKey','SEGSSyncStopSettings','SEGSHistoryHash','SEGSShortSignalID','SEGSExecutionKey','CountOpenAdvisorSetsForSymbol','HasOpenAdvisorTradesForSignal','SEGSCanScanNewSetup','SEGSFreshConfirmationAfterOtherSet','IsAdvisorTradeTaken'])
code=code.replace('string keys[];', 'std::vector<string> keys;')
preamble=r'''
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <iostream>
using string=std::string;using datetime=long;
#define uint uint32_t
int InpAdvisorMagicNumber=123,InpMaxSetsPerSymbol=2;
const int ACCOUNT_LOGIN=0,ACCOUNT_MARGIN_MODE=1,ACCOUNT_MARGIN_MODE_RETAIL_HEDGING=2,PERIOD_M5=5;
long account=1;int margin=2;bool g_currentTradeTaken=false;datetime confirmation=200;
struct Position{string symbol,comment;int magic;long id;datetime time;};std::vector<Position> positions;
struct PositionInfo{
 int selected=-1;
 bool SelectByTicket(unsigned long t){selected=(int)t-1;return selected>=0&&selected<(int)positions.size();}
 string Symbol(){return positions.at(selected).symbol;}string Comment(){return positions.at(selected).comment;}
 int Magic(){return positions.at(selected).magic;}long Identifier(){return positions.at(selected).id;}
 datetime Time(){return positions.at(selected).time;}
}posInfo;
int PositionsTotal(){return positions.size();}unsigned long PositionGetTicket(int i){return i+1;}
long AccountInfoInteger(int key){return key==ACCOUNT_LOGIN?account:margin;}
int StringLen(string s){return s.size();}uint32_t StringGetCharacter(string s,int i){return (unsigned char)s.at(i);}
int StringFind(string a,string b){auto i=a.find(b);return i==string::npos?-1:i;}
string StringSubstr(string s,int start,int n=-1){return s.substr(start,n<0?string::npos:n);}
string IntegerToString(long n){return std::to_string(n);}
string StringFormat(const char* fmt,uint32_t a,uint32_t b){char v[80];std::snprintf(v,sizeof(v),fmt,a,b);return v;}
template<class T>int ArraySize(const std::vector<T>& a){return a.size();}
template<class T>int ArrayResize(std::vector<T>& a,int n){a.resize(n);return n;}
template<class A,class B>double MathMax(A a,B b){return std::max((double)a,(double)b);}
template<class A,class B>double MathMin(A a,B b){return std::min((double)a,(double)b);}
datetime iTime(string,int,int shift){assert(shift==1);return confirmation;}
enum ENUM_SEGS_SL_STYLE{SL_STYLE_ORDER_BLOCK,SL_STYLE_MULTI_DAY,SL_STYLE_AUTO_DUAL,SL_STYLE_ACTIVE_ORDER_BLOCK};
ENUM_SEGS_SL_STYLE InpStructuralStopStyle=SL_STYLE_AUTO_DUAL,g_systemStopStyle=SL_STYLE_AUTO_DUAL;
double InpStructuralBufferATR=.05,InpActiveOBMaxDistanceATR=3,InpMaxStructuralStopATR=1.5,InpMaxStructuralStopPercent=1;
int InpActiveOBBufferTicks=3;bool InpTrailActiveOrderBlock=true;
double g_systemOBBufferATR=0,g_systemOBMaxDistanceATR=0,g_systemMaxStopATR=0,g_systemMaxStopPercent=0;
int g_systemOBBufferTicks=0;bool g_systemTrailOB=false;
std::map<string,double> globals;
void GlobalVariableSet(string k,double v){globals[k]=v;}
bool GlobalVariableCheck(string k){return globals.count(k);}
double GlobalVariableGet(string k){return globals.at(k);}datetime TimeCurrent(){return 210;}
'''
tests=r'''
string tag(string id){return "SEGS|ADV|"+SEGSShortSignalID(id)+"|";}
int main(){int checks=0;
 assert(CountOpenAdvisorSetsForSymbol("NDAQ")==0);checks++;
 for(int i=0;i<4;i++)positions.push_back({"NDAQ",tag("first")+"L"+std::to_string(i+1)+"/4",123,i+1,100+i*10});
 assert(CountOpenAdvisorSetsForSymbol("NDAQ")==1);checks++;
 assert(SEGSCanScanNewSetup("NDAQ"));checks++;
 assert(HasOpenAdvisorTradesForSignal("NDAQ","first"));checks++;
 assert(!HasOpenAdvisorTradesForSignal("NDAQ","second"));checks++;
 assert(!HasOpenAdvisorTradesForSignal("USDJPY","first"));checks++;
 assert(!IsAdvisorTradeTaken("NDAQ","second"));checks++;
 assert(IsAdvisorTradeTaken("NDAQ","first"));checks++;
 assert(SEGSFreshConfirmationAfterOtherSet("NDAQ","second"));checks++;
 confirmation=120;assert(!SEGSFreshConfirmationAfterOtherSet("NDAQ","second"));checks++;
 confirmation=200;
 positions.push_back({"NDAQ",tag("second")+"L1/4",123,5,205});
 // A partially filled second set counts immediately but does not block its own next leg's confirmation.
 assert(CountOpenAdvisorSetsForSymbol("NDAQ")==2);checks++;
 assert(SEGSFreshConfirmationAfterOtherSet("NDAQ","second"));checks++;
 assert(!SEGSCanScanNewSetup("NDAQ"));checks++;
 positions.back().symbol="USDJPY";
 assert(CountOpenAdvisorSetsForSymbol("NDAQ")==1&&CountOpenAdvisorSetsForSymbol("USDJPY")==1);checks++;
 assert(SEGSCanScanNewSetup("NDAQ"));checks++;
 // Independent legacy tickets are never merged just because they opened within five seconds.
 positions={{"NDAQ","[MyAdvisor]",123,7,100},{"NDAQ","[MyAdvisor]",123,8,101}};
 assert(CountOpenAdvisorSetsForSymbol("NDAQ")==2);checks++;
 assert(!HasOpenAdvisorTradesForSignal("NDAQ","new"));checks++;
 positions={{"NDAQ","",0,9,100}};
 assert(CountOpenAdvisorSetsForSymbol("NDAQ")==0&&SEGSCanScanNewSetup("NDAQ"));checks++;
 confirmation=99;assert(!SEGSFreshConfirmationAfterOtherSet("NDAQ","new"));checks++;
 confirmation=200;assert(SEGSFreshConfirmationAfterOtherSet("NDAQ","new"));checks++;
 margin=0;assert(!SEGSCanScanNewSetup("NDAQ"));checks++;
 positions.clear();assert(SEGSCanScanNewSetup("NDAQ"));checks++;
 // Exact delimiter prevents a prefix match from treating a different signal as executed.
 positions={{"NDAQ",tag("first").substr(0,25)+"EXTRA|L1/4",123,10,100}};
 assert(!HasOpenAdvisorTradesForSignal("NDAQ","first"));checks++;
 assert(SEGSExecutionKey(string(200,'x'),false).size()<=63);checks++;
 assert(SEGSExecutionKey(string(200,'x'),true).size()<=63);checks++;
 assert(SEGSExecutionKey("first",false)!=SEGSExecutionKey("second",false));checks++;
 // One publisher's stop policy is consumed by another chart without its default Inputs overwriting it.
 SEGSSyncStopSettings(false);assert(g_systemMaxStopATR==1.5&&g_systemMaxStopPercent==1);checks++;
 InpMaxStructuralStopATR=2;InpMaxStructuralStopPercent=.5;InpStructuralBufferATR=.07;
 SEGSSyncStopSettings(true);assert(g_systemMaxStopATR==2&&g_systemMaxStopPercent==.5&&g_systemOBBufferATR==.07);checks++;
 InpMaxStructuralStopATR=.5;InpMaxStructuralStopPercent=3;InpStructuralBufferATR=.01;
 SEGSSyncStopSettings(false);assert(g_systemMaxStopATR==2&&g_systemMaxStopPercent==.5&&g_systemOBBufferATR==.07);checks++;
 account=2;SEGSSyncStopSettings(false);assert(g_systemMaxStopATR==.5&&g_systemMaxStopPercent==3);checks++;
 account=1;SEGSSyncStopSettings(false);assert(g_systemMaxStopATR==2&&g_systemMaxStopPercent==.5);checks++;
 InpMaxStructuralStopATR=-1;InpMaxStructuralStopPercent=-1;SEGSSyncStopSettings(true);
 assert(g_systemMaxStopATR==.1&&g_systemMaxStopPercent==0);checks++;
 assert(SEGSStopKey("STYLE").find("SEGS_SL_V3_")==0);checks++;
 std::cout<<checks<<" independent-setup / system-setting assertions passed\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'multi.cpp';p.write_text(preamble+code+tests);exe=Path(d)/'multi'
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
# Actual execution paths must not contain the old any-position vetoes.
execute=s.split('void ExecuteAdvisedTrade(bool isAutoTrade=false)\n{',1)[1].split('void CheckAndAutoTradeAdvice()\n{',1)[0]
auto=s.split('void CheckAndAutoTradeAdvice()\n{',1)[1].split('double CalcRiskFromSL(',1)[0]
assert 'CountOpenAdvisorTradesForSymbol(' not in execute+auto
assert execute.count('SEGSCanScanNewSetup(sym)')==2 # Pre-check and recheck inside the account mutex.
assert 'SEGSFreshConfirmationAfterOtherSet(sym,g_currentSignalID)' in s
assert 'SEGSReleaseExecutedCandidate(sym);' in s
assert 'bool isTradeTaken = HasOpenAdvisorTradesForSignal(sym,g_currentSignalID);' in s
print('Live-position policy and actual execution integration checks passed; native MT5 replay still required.')
