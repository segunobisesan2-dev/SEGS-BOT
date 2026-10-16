"""Execute the EA's real PESubmit function against deterministic broker stubs."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'SEGS_Trade_Manager_Pro_v3.75.mq5').read_text()
enums=s[s.index('enum PE_MODE'):s.index('input group "=== Precision Entry Engine')]
core=s[s.index('// BEGIN PE PURE CORE'):s.index('// END PE PURE CORE')]
submit=s[s.index('void PESubmit(PESetup &s)'):s.index('void PERoleFlip(')]
stubs=r'''
#include <cassert>
#include <cmath>
#include <string>
#include <map>
#include <vector>
#include <iostream>
using string=std::string;using datetime=long long;
int StringCompare(const string& a,const string& b){return a.compare(b);}
double MathAbs(double v){return std::abs(v);} double MathMin(double a,double b){return std::min(a,b);}
double MathFloor(double a){return std::floor(a);} double NormalizeDouble(double v,int){return v;}
enum {AUTO_EXEC_ENABLED,ACCOUNT_MARGIN_MODE_RETAIL_HEDGING,ACCOUNT_MARGIN_MODE,SYMBOL_VOLUME_STEP,SYMBOL_VOLUME_MIN,SYMBOL_VOLUME_MAX,SYMBOL_POINT,
 ORDER_TYPE_BUY,ORDER_TYPE_SELL,TRADE_ACTION_DEAL,POSITION_TYPE_BUY,POSITION_TYPE_SELL,ACCOUNT_MARGIN_FREE,
 TRADE_RETCODE_DONE=10009,TRADE_RETCODE_DONE_PARTIAL=10010,TRADE_RETCODE_PLACED=10008,
 TRADE_RETCODE_TIMEOUT=10012,TRADE_RETCODE_CONNECTION=10031,TRADE_RETCODE_ERROR=10011};
using ENUM_ORDER_TYPE=int;using ENUM_POSITION_TYPE=int;
struct MqlTick{double ask=110.02,bid=110;};
struct MqlTradeRequest{int action=0;string symbol;long magic=0;int type=0;double price=0,sl=0,tp=0,volume=0;unsigned deviation=0;int type_filling=0;string comment;};
struct MqlTradeResult{unsigned retcode=0;unsigned long order=0,deal=0;unsigned request_id=0;};
template<class T>void ZeroMemory(T& v){v=T{};}
template<class... A>void PrintFormat(const char*,const A&...){}
string StringFormat(const char*,const string& id,int l,int total){return "SEGS|ADV|"+id+"|L"+std::to_string(l)+"/"+std::to_string(total);}
bool g_peStorageOK=true,g_myAdvisorEnabled=true,g_smartLotEnabled=true;
int InpAdvisorMaxTotalOpenTrades=24,InpMaxOpenAdvisorTradesPortfolio=24,InpAdvisorMaxTradesPerSetup=4;
long InpAdvisorMagicNumber=333777;
double InpMaxEntryDriftATR=.35,InpSmartMaxCapLot=0;
unsigned InpPEDeviationPoints=20;
string g_currentSignalID,g_currentAdvisedAction,g_lastAdvisorTradeSignalID;
bool g_currentTradeTaken=false;
double g_staticEntryPrice=0,g_staticSL=0,g_staticTP1=0,g_staticTP2=0,g_staticTP3=0,g_staticTP4=0;
datetime g_lastAdvisorTradeExecTime=0;
std::map<string,double> globals;
std::vector<unsigned> outcomes;
int sends=0,positions=0,openCount=0,checks=0,journals=0;
bool canceled=true,permit=true,lock=true,history=true,preflight=true;
double quote=110,atr=20,budget=100,seenBudget=0;
int checksCount=0;
#define CHECK(x) do{++checksCount;if(!(x)){std::cerr<<"failure "<<__LINE__<<": "<<#x<<"\n";std::abort();}}while(0)
int GetAutoExecutionState(string,string&,string&){return permit?AUTO_EXEC_ENABLED:-1;}
bool TryAcquireAccountLock(string,int){return lock;}void ReleaseAccountLock(string){}
string PERoot(string){return "root/";}
int PositionsTotal(){return positions;}unsigned long PositionGetTicket(int){return 1;}
string PositionGetString(int){return "TEST";}enum{POSITION_SYMBOL};
double GlobalVariableGet(string k){return globals[k];}void GlobalVariableSet(string k,double v){globals[k]=v;}
void GlobalVariablesFlush(){}
bool PECancelAdvisorOrders(string){return canceled;}
bool SymbolInfoTick(string,MqlTick& q){q.bid=quote;q.ask=quote+.02;return true;}
double PEATR(string){return atr;}double PERiskBudget(){return budget;}
double AccountInfoDouble(int){return 10000;}
bool OrderCalcMargin(int,string,double vol,double,double& margin){margin=vol*10;return true;}
int CountTotalOpenAdvisorTrades(){return openCount;}long AccountInfoInteger(int){return ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;}
bool OrderCalcProfit(int type,string,double vol,double entry,double sl,double& loss){loss=(type==ORDER_TYPE_BUY?sl-entry:entry-sl)*vol;return true;}
double GetAdvisorLotForSymbol(string){return 4;}
double SymbolInfoDouble(string,int key){if(key==SYMBOL_VOLUME_STEP||key==SYMBOL_VOLUME_MIN)return .01;if(key==SYMBOL_VOLUME_MAX)return 100;return .01;}
int GetVolumeDigits(string){return 2;}int PEFill(string){return 0;}
bool PERequestCheck(MqlTradeRequest& req,double available,string&){checks++;seenBudget=available;return preflight&&req.volume>0&&available>=std::abs(req.price-req.sl)*req.volume-1e-6;}
void SaveAdvisorSetupTargets(string,string,int,double,double,double,double,double,double,int){}
datetime TimeCurrent(){return 200;}
bool HistoryDealSelect(unsigned long){return history;}
bool OrderSend(MqlTradeRequest&,MqlTradeResult& r){CHECK(globals["root/BUSY"]>0);CHECK(journals>0);r.retcode=outcomes.at(sends++);r.request_id=sends;r.order=sends;r.deal=(r.retcode==TRADE_RETCODE_DONE||r.retcode==TRADE_RETCODE_DONE_PARTIAL)?sends:0;return r.deal>0;}
'''
postcore=r'''
void PESetOwner(const PESetup&){}
void PEJournal(const PESetup&){journals++;}
void PETransition(PESetup& s,int state,string){s.state=state;journals++;}
PESetup plan(bool buy=true){PESetup s{};s.id="0000000000000001";s.symbol="TEST";s.state=RETEST_TOUCHED;s.ready=true;s.buy=buy;s.level=110;s.low=100;s.high=120;s.tolerance=.25;s.sl=buy?100:120;for(auto& tp:s.tp)tp=buy?130:90;s.expires=1000;return s;}
void reset(){globals.clear();outcomes={TRADE_RETCODE_DONE,TRADE_RETCODE_DONE,TRADE_RETCODE_DONE,TRADE_RETCODE_DONE};sends=positions=openCount=checks=journals=0;canceled=permit=lock=history=preflight=true;quote=110;budget=100;g_peStorageOK=true;}
'''
tests=r'''
int main(){
 for(bool buy:{true,false}){
 reset();auto s=plan(buy);PESubmit(s);CHECK(sends==4);CHECK(s.state==TRADED);CHECK(!s.unresolved);CHECK(globals["root/BUSY"]==0);PESubmit(s);CHECK(sends==4);
 reset();s=plan(buy);outcomes[0]=TRADE_RETCODE_DONE_PARTIAL;PESubmit(s);CHECK(sends==1);CHECK(s.state==TRADED);CHECK(!s.unresolved);
 reset();s=plan(buy);outcomes[0]=10006;PESubmit(s);CHECK(sends==1);CHECK(s.state==INVALIDATED);PESubmit(s);CHECK(sends==1);
 reset();s=plan(buy);outcomes[0]=TRADE_RETCODE_TIMEOUT;PESubmit(s);CHECK(sends==1);CHECK(s.state==ENTRY_SUBMITTED);CHECK(s.unresolved);CHECK(globals["root/BUSY"]>0);PESubmit(s);CHECK(sends==1);
 reset();s=plan(buy);outcomes[1]=TRADE_RETCODE_CONNECTION;PESubmit(s);CHECK(sends==2);CHECK(s.state==TRADED);CHECK(s.unresolved);CHECK(globals["root/BUSY"]>0);
 reset();s=plan(buy);outcomes[0]=TRADE_RETCODE_PLACED;PESubmit(s);CHECK(sends==1);CHECK(s.state==ENTRY_SUBMITTED);CHECK(s.unresolved);
 reset();s=plan(buy);history=false;PESubmit(s);CHECK(sends==1);CHECK(s.state==ENTRY_SUBMITTED);CHECK(s.unresolved);
 reset();s=plan(buy);globals["root/BUSY"]=100;PESubmit(s);CHECK(sends==0); // restart unresolved reservation
 reset();s=plan(buy);positions=1;PESubmit(s);CHECK(sends==0); // existing exposure (either direction)
 reset();s=plan(buy);canceled=false;PESubmit(s);CHECK(sends==0); // pending cancellation failed
 reset();s=plan(buy);preflight=false;PESubmit(s);CHECK(sends==0);CHECK(s.state==EXPIRED);
 reset();s=plan(buy);quote=120;PESubmit(s);CHECK(sends==0);CHECK(s.state==EXPIRED);
 reset();s=plan(buy);openCount=24;PESubmit(s);CHECK(sends==0);
 reset();s=plan(buy);openCount=23;PESubmit(s);CHECK(sends==1); // configured portfolio cap
 reset();s=plan(buy);budget=.001;PESubmit(s);CHECK(sends==0); // minimum broker lot exceeds risk
 reset();s=plan(buy);permit=false;PESubmit(s);CHECK(sends==0);
 reset();s=plan(buy);g_peStorageOK=false;PESubmit(s);CHECK(sends==0);
 }
 std::cout<<checksCount<<" actual-submit-function assertions passed (stubbed broker)\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'execution.cpp';p.write_text(stubs+enums+core+postcore+submit+tests)
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(p.with_suffix(''))],check=True)
 subprocess.run([str(p.with_suffix(''))],check=True)
