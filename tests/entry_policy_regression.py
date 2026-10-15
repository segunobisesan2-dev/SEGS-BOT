"""Execute extracted entry policy against deterministic completed-bar broker stubs."""
from pathlib import Path
import re,subprocess,tempfile
r=Path(__file__).resolve().parents[1];s=(r/'SEGS_Trade_Manager_Pro_v3.78.mq5').read_text()
parts=[]
def function(name):
 m=re.search(r'^(?:bool|int|string|uint|void) '+name+r'\([^;]*?\)\n\{',s,re.M)
 assert m,name
 start=m.start();i=m.end();depth=1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[start:i]+'\n'
for name in ['SEGSHistoryHash','SEGSStructureDirection','SEGSClosedTrend','SEGSEntryGeometry','SEGSSelectEntryBlock','SEGSRejectionCandle','SEGSRecentZoneRejection','SEGSConfirmedStructureShift','CountOrderBlockBounceCycles','EvaluateMultiTimeframeTrendAndReversal','EvaluateTrendReversalConditions','SEGSAdvisorEntryGate','SEGSShortSignalID','SEGSSetupTargetKey','SaveAdvisorSetupTargets','LoadAdvisorSetupTargets']:
 parts.append(function(name))
code='\n'.join(parts)
code=code.replace('double f[],s[];', 'std::vector<double> f,s;')
code=re.sub(r'\b(MqlRates|double) (\w+)\[\]',r'std::vector<\1> \2',code)
code=code.replace('ENUM_TIMEFRAMES frames[]=', 'std::vector<ENUM_TIMEFRAMES> frames=')
preamble=r'''
#include <string>
#include <vector>
#include <map>
#include <cmath>
#include <cassert>
#include <cstdint>
#include <algorithm>
#include <iostream>
#include <cstdio>
using string=std::string;using datetime=long;using ENUM_TIMEFRAMES=int;using ENUM_POSITION_TYPE=int;
#define uint uint32_t
const int PERIOD_M5=5,PERIOD_M15=15,PERIOD_M30=30,PERIOD_H1=60,PERIOD_H2=120,PERIOD_H4=240;
const int INVALID_HANDLE=-1,SYMBOL_BID=1,SYMBOL_ASK=2,SYMBOL_TRADE_TICK_SIZE=3,ACCOUNT_LOGIN=4;
struct MqlRates{datetime time=0;double open=0,high=0,low=0,close=0;};
struct M30OrderBlock{bool bullish=false;double high=0,low=0;datetime originTime=0,confirmTime=0;bool invalidated=false;double wickLow=low,wickHigh=high;};
std::vector<M30OrderBlock> g_orderBlocks,g_h1OrderBlocks;
std::map<int,std::vector<MqlRates>> bars;
double g_executionZoneLow=0,g_executionZoneHigh=0;string g_currentSignalID="test";
string _Symbol="NDAQ",g_h1Bias,g_h2Bias,g_h4Bias,g_overallBias,g_activeEntryStrategy="ORDER_BLOCK";
double g_recentSupport=0,g_recentResistance=0;
int g_hAtr_H1=0,g_hEma20_H1=1,g_hEma50_H1=2,g_hEma20_H2=3,g_hEma50_H2=4,g_hEma20_H4=5,g_hEma50_H4=6;
int InpReversalH1MinBounces=3,InpReversalM30MinBounces=4;
bool fresh=true,bull=false;double bid=100,ask=100.01,atr=10,scale=1;long account=1;
std::map<string,double> globals;
bool SEGSQuoteFresh(string){return fresh;}
bool SEGSFreshConfirmationAfterOtherSet(string,string){return true;}
template<class T>int ArraySize(const std::vector<T>& a){return a.size();}
template<class T>void ArraySetAsSeries(std::vector<T>&,bool){}
int CopyRates(string,int tf,int start,int count,std::vector<MqlRates>& out){assert(start==1);out=bars[tf];if((int)out.size()>count)out.resize(count);return out.size();}
int CopyBuffer(int handle,int,int start,int count,std::vector<double>& out){assert(start==1);if(handle<0)return -1;out.assign(count,handle==0?atr:(handle%2 ? (bull?110:90)*scale:100*scale));return count;}
void InitIndicatorHandles(string){}
double iClose(string,int tf,int shift){assert(shift==1);return bars[tf].empty()?0:bars[tf][0].close;}
double iOpen(string,int tf,int){return bars[tf].empty()?0:bars[tf][0].open;}
double iHigh(string,int tf,int){return bars[tf].empty()?0:bars[tf][0].high;}
double iLow(string,int tf,int){return bars[tf].empty()?0:bars[tf][0].low;}
double SymbolInfoDouble(string,int key){return key==SYMBOL_BID?bid:(key==SYMBOL_ASK?ask:0.01*scale);}
double GetPipSize(string){return 0.01*scale;}
bool MathIsValidNumber(double x){return std::isfinite(x);}double MathAbs(double x){return std::abs(x);}
template<class A,class B>double MathMax(A a,B b){return std::max((double)a,(double)b);}
template<class A,class B>double MathMin(A a,B b){return std::min((double)a,(double)b);}
int StringLen(string s){return s.size();}uint32_t StringGetCharacter(string s,int i){return (unsigned char)s.at(i);}
string IntegerToString(long n){return std::to_string(n);}
string StringFormat(const char* fmt,uint32_t a,uint32_t b){char v[80];std::snprintf(v,sizeof(v),fmt,a,b);return v;}
long AccountInfoInteger(int){return account;}datetime TimeCurrent(){return 1000;}
void GlobalVariableSet(string k,double v){globals[k]=v;}bool GlobalVariableCheck(string k){return globals.count(k);}
double GlobalVariableGet(string k){return globals[k];}
template<class...T>void PrintFormat(const char*,T...){}
// MQL resolves forward declarations globally.
void EvaluateMultiTimeframeTrendAndReversal(string,string&,string&,string&,string&,bool&,string&,double&);
bool EvaluateTrendReversalConditions(string,string,double&,double&,int&,int&,string&);
'''
tests=r'''
void reset(bool up=false){
 bull=up;fresh=true;scale=1;atr=10;bid=100;ask=100.01;g_hAtr_H1=0;
 g_orderBlocks.clear();g_h1OrderBlocks.clear();bars.clear();g_activeEntryStrategy="ORDER_BLOCK";
 for(int tf:{5,15,30,60,120,240}){
  for(int i=0;i<80;i++)bars[tf].push_back(up?MqlRates{1000-i*10,110,112,108,111}:MqlRates{1000-i*10,90,101,88,89});
 }
}
void zone(bool buy){g_orderBlocks={{buy,buy?100.:101.,buy?99.:100.,1,2,false}};}
void rejection(bool buy){MqlRates c=buy?MqlRates{1000,99.8,100.6,99.2,100.3}:MqlRates{1000,100.2,100.8,99.5,99.7};bars[5][0]=c;bars[15][0]=c;}
void reversed(){
 for(int tf:{30,60})for(int i=0;i<80;i++)bars[tf][i]={1000-i*10,101.7,102,101.5,101.8};
 for(int i:{22,18,14,10})bars[30][i]={1000-i*10,99.8,100.6,99.2,100.3};
 bars[30][3]={970,102,104,101.5,103};
 bars[30][0]={1000,103,105.5,102,105};
 rejection(true);
}
int main(){string reason;int checks=0;
 // Strong downtrend cannot buy merely because a demand block is nearby.
 reset(false);zone(true);rejection(true);assert(!SEGSAdvisorEntryGate(_Symbol,"BUY",100,98,true,reason));checks++;
 // Trend-aligned SELL requires exact retest AND a completed rejection.
 reset(false);zone(false);rejection(false);assert(SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));checks++;
 // A stale historical wick must never authorize a chased USDCHF sell.
 bid=98;ask=98.01;assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));checks++;
 bid=92;ask=92.01;assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,false,reason));checks++;
 // Future pullback remains a plan; it cannot execute before the exact entry is reached.
 bid=99;ask=99.01;assert(SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,false,reason));checks++;
 assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));checks++;
 // Nearby unrelated zone cannot replace a candidate's own zone.
 reset(false);zone(false);rejection(false);assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",98,102,true,reason));checks++;
 // Invalid stops, feed loss, opposing-zone collision and missing data all block orders.
 assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,99,true,reason));checks++;
 fresh=false;assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));fresh=true;checks++;
 g_h1OrderBlocks={{true,100.5,99.5,1,2,false}};assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));g_h1OrderBlocks.clear();checks++;
 bars[5][0]={};bars[15][0]={};assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));checks++;
 reset(true);zone(false);rejection(false);assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));checks++;
 // Real counter-trend reversal needs 4 distinct M30 bounces AND a confirmed swing break.
 reset(false);zone(true);reversed();
 assert(CountOrderBlockBounceCycles(_Symbol,30,99,100,true,10,.01,576)==4);checks++;
 {bool ok=SEGSAdvisorEntryGate(_Symbol,"BUY",100,98,true,reason);if(!ok)std::cerr<<reason<<"\n";assert(ok);checks++;}
 bars[30][0].close=103;assert(!SEGSAdvisorEntryGate(_Symbol,"BUY",100,98,true,reason));checks++;
 // Mirrored confirmed SELL reversal is also permitted: no one-sided prohibition.
 reset(true);zone(true);reversed();
 for(auto &kv:bars)for(auto &v:kv.second){auto h=v.high;v.high=200-v.low;v.low=200-h;v.open=200-v.open;v.close=200-v.close;}
 // H2/H4 must also describe the bullish macro context after the mirror.
 bars[120][0]={1000,110,112,108,111};bars[240][0]={1000,110,112,108,111};
 zone(false);assert(SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,true,reason));checks++;
 // Consecutive touching candles do not accumulate distinct bounce cycles.
 reset(false);zone(true);reversed();
 for(int i=10;i<=22;i++)bars[30][i]={1000-i*10,99.8,100.6,99.2,100.3};
 assert(CountOrderBlockBounceCycles(_Symbol,30,99,100,true,10,.01,576)==1);checks++;
 assert(!SEGSAdvisorEntryGate(_Symbol,"BUY",100,98,true,reason));checks++;
 bars[30][0].close=98;assert(CountOrderBlockBounceCycles(_Symbol,30,99,100,true,10,.01,576)==0);checks++;
 // A planned SELL below current price cannot be presented as a supply pullback.
 reset(false);zone(false);rejection(false);bid=100.8;ask=100.81;
 assert(!SEGSAdvisorEntryGate(_Symbol,"SELL",100,102,false,reason));checks++;
 // Skip a supply entry already below price and select the next viable pullback above it.
 g_orderBlocks.push_back({false,103,102,1,2,false});
 assert(SEGSSelectEntryBlock(_Symbol,false,false,10)==1);checks++;
 // Complete gate checks use identical logic for instruments with different units.
 for(auto pair:std::vector<std::pair<string,double>>{{"NDAQ",1.},{"USDCHF",0.0083},{"USDJPY",1.58},{"XAUUSD",23.}}){
  reset(false);zone(false);rejection(false);_Symbol=pair.first;double k=pair.second;
  scale=k;atr*=k;bid*=k;ask*=k;
  for(auto &kv:bars)for(auto &v:kv.second){v.open*=k;v.high*=k;v.low*=k;v.close*=k;}
  for(auto &v:g_orderBlocks){v.high*=k;v.low*=k;}
  assert(SEGSAdvisorEntryGate(_Symbol,"SELL",100*k,102*k,true,reason));checks++;
 }
 // Candle and proximity rules are invariant to instrument units (equities, FX, metals).
 for(double k:{1.,0.0083,1.58,23.}){
  assert(SEGSEntryGeometry(false,100*k,100*k,102*k,10*k,.01*k,.01*k,true));
  assert(!SEGSEntryGeometry(false,98*k,100*k,102*k,10*k,.01*k,.01*k,true));checks+=2;
 }
 // Exact-symbol/account persisted targets and signal IDs cannot share timestamp-only tails.
 auto id1=SEGSShortSignalID("1_NDAQ_BUY_20261015_1200_PIVOT_20261015_1100");
 auto id2=SEGSShortSignalID("1_USDJPY_BUY_20261015_1200_PIVOT_20261015_1100");
 assert(id1.size()==16&&id2.size()==16&&id1!=id2);checks++;
 SaveAdvisorSetupTargets("ADV_same","NDAQ",0,93,89,95,96,97,98,4);
 SaveAdvisorSetupTargets("ADV_same","USDJPY",0,158,157,159,160,161,162,4);
 double e,sl,t1,t2,t3,t4;int type,legs;
 assert(LoadAdvisorSetupTargets("NDAQ","ADV_same",e,sl,t1,t2,t3,t4,type,legs)&&e==93&&t1==95);checks++;
 assert(LoadAdvisorSetupTargets("USDJPY","ADV_same",e,sl,t1,t2,t3,t4,type,legs)&&e==158&&t1==159);checks++;
 account=2;assert(!LoadAdvisorSetupTargets("NDAQ","ADV_same",e,sl,t1,t2,t3,t4,type,legs));checks++;
 std::cout<<checks<<" entry-policy assertions passed.\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'policy.cpp';p.write_text(preamble+code+tests);exe=Path(d)/'policy'
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
print('Extracted MQL entry logic tested with broker stubs; native MT5 compilation/replay still required.')
