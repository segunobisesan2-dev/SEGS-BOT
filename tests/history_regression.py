"""Execute extracted MQL history functions with C++ broker stubs; no MT5 runtime claim."""
from pathlib import Path
import re, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'SEGS_Trade_Manager_Pro_v3.75.mq5').read_text()
a=s.index('struct SEGSHistoryRecord\n'); b=s.index('bool g_runtimeReady',a)
code=s[a:b]
a=s.index('uint SEGSHistoryHash(');b=s.index('void ShiftStopLossTicket',a)
code+=s[a:b]
# Exercise actual asset matching and quote-age gates as well as the shared ledger.
a=s.index('bool IsSymbolMatch(string sym, string pattern)\n{'); b=s.index('//+------------------------------------------------------------------+',a)
identity=s[a:b]
a=s.index('string DetectAssetType(string sym)\n{');b=s.index('//+------------------------------------------------------------------+',a)
identity+=s[a:b]
a=s.index('string SEGSInstrumentKey(string sym)\n{');b=s.index('//+------------------------------------------------------------------+',s.index('bool IsSameChartAsset(string symA, string symB)\n{',a))
identity+=s[a:b]
a=s.index('bool SEGSQuoteFresh(string sym)\n{');b=s.index('bool SEGSServiceDataStatus',a)
identity+=s[a:b]
inputs='\n'.join('string '+name+'='+value+';' for name,value in re.findall(r'input string\s+(Inp\w+_Patterns)\s*=\s*("[^"]*")',s))
code=inputs+identity+code
code=code.replace('string tickers[] =', 'std::vector<string> tickers =')
code=code.replace('string &keys[]','std::vector<string> &keys').replace('int &indexes[]','std::vector<int> &indexes')
code=re.sub(r'\b(string|int|SEGSHistoryRecord) (\w+)\[\]',r'std::vector<\1> \2',code)
code=code.replace('SEGSHistoryRecord positions[], setups[];', 'std::vector<SEGSHistoryRecord> positions, setups;')
# After replacing the first array of a paired declaration, transform its second.
code=code.replace('std::vector<SEGSHistoryRecord> positions, setups[];', 'std::vector<SEGSHistoryRecord> positions, setups;')
preamble=r'''
#include <vector>
#include <string>
#include <cmath>
#include <algorithm>
#include <cassert>
#include <iostream>
#include <cstdint>
#include <cctype>
#include <sstream>
using string=std::string; using datetime=long;
using std::uint32_t;
#define uint uint32_t
const int ACCOUNT_LOGIN=1, DEAL_TYPE=2, DEAL_POSITION_ID=3, DEAL_ENTRY=4, DEAL_TIME=5,
 DEAL_SYMBOL=6, DEAL_COMMENT=7, DEAL_PROFIT=8, DEAL_SWAP=9, DEAL_COMMISSION=10,
 DEAL_FEE=11, DEAL_VOLUME=12, POSITION_SYMBOL=13, POSITION_IDENTIFIER=14;
const int DEAL_TYPE_BUY=0,DEAL_TYPE_SELL=1,DEAL_ENTRY_IN=0,DEAL_ENTRY_OUT=1,
 DEAL_ENTRY_INOUT=2,DEAL_ENTRY_OUT_BY=3;
struct Deal {long id,type,entry; string symbol,comment; double pnl,commission,fee,volume;};
std::vector<Deal> deals; std::vector<long> live; int selected=0, selections=0;
unsigned long clockMs=100; long account=1; bool available=true;
template<class T> int ArraySize(const std::vector<T>& v){return (int)v.size();}
template<class T> int ArrayResize(std::vector<T>& v,int n){v.resize(n);return n;}
template<class T> void ArrayInitialize(std::vector<T>& v,T x){std::fill(v.begin(),v.end(),x);}
int StringLen(string s){return s.size();} uint32_t StringGetCharacter(string s,int i){return (unsigned char)s.at(i);}
int StringFind(string s,string t){auto i=s.find(t);return i==string::npos?-1:(int)i;}
string StringSubstr(string s,int start,int n=-1){return s.substr(start,n<0?string::npos:n);}
string IntegerToString(long n){return std::to_string(n);}
template<class T,class U> auto MathMax(T a,U b){return std::max((double)a,(double)b);}
double MathAbs(double n){return std::abs(n);} double NormalizeDouble(double n,int d){auto k=std::pow(10,d);return std::round(n*k)/k;}
unsigned long GetTickCount64(){return clockMs;}
long AccountInfoInteger(int){return account;} datetime TimeCurrent(){return 1000;}
bool HistorySelect(datetime,datetime){selections++;return available;} int HistoryDealsTotal(){return deals.size();}
unsigned long HistoryDealGetTicket(int i){return i+1;}
long HistoryDealGetInteger(unsigned long t,int f){auto d=deals.at(t-1);if(f==DEAL_TYPE)return d.type;if(f==DEAL_POSITION_ID)return d.id;if(f==DEAL_ENTRY)return d.entry;return t;}
string HistoryDealGetString(unsigned long t,int f){auto d=deals.at(t-1);return f==DEAL_SYMBOL?d.symbol:d.comment;}
double HistoryDealGetDouble(unsigned long t,int f){auto d=deals.at(t-1);if(f==DEAL_PROFIT)return d.pnl;if(f==DEAL_COMMISSION)return d.commission;if(f==DEAL_FEE)return d.fee;if(f==DEAL_VOLUME)return d.volume;return 0;}
int PositionsTotal(){return live.size();} unsigned long PositionGetTicket(int i){selected=i;return live.at(i);}
string PositionGetString(int){return "NDAQ";} long PositionGetInteger(int){return live.at(selected);}

void StringToUpper(string &s){for(char &c:s)c=std::toupper((unsigned char)c);}
void StringTrimLeft(string &s){s.erase(0,s.find_first_not_of(" "));}
void StringTrimRight(string &s){auto i=s.find_last_not_of(" ");s=i==string::npos?"":s.substr(0,i+1);}
int StringSplit(string s,char delimiter,std::vector<string> &parts){parts.clear();std::stringstream in(s);string v;while(std::getline(in,v,delimiter))parts.push_back(v);return parts.size();}
const int SYMBOL_BID=0,SYMBOL_ASK=1,SYMBOL_LAST=2,TERMINAL_CONNECTED=3;
double SymbolInfoDouble(string sym,int){return sym.find("100")!=string::npos?20000:90;}
struct MqlTick {datetime time=1000;};
datetime quoteTime=1000,serverTime=1000;bool connected=true,quoteAvailable=true,metadata=true;
bool TerminalInfoInteger(int){return connected;}
bool SymbolInfoTick(string,MqlTick &q){q.time=quoteTime;return quoteAvailable;}
datetime TimeTradeServer(){return serverTime;}
bool SEGSMarketReady(string){return metadata;}

'''
tests=r'''
void refresh(){g_historyDirty=true;g_historyNextRefresh=0;assert(SEGSRefreshHistory());}
void add(long id,long type,long entry,string sym,string comment,double pnl=0,double cost=0,double fee=0,double vol=1){deals.push_back({id,type,entry,sym,comment,pnl,cost,fee,vol});}
void metrics(string sym,int w,int l,double rate){double wr,pf;int wins,losses;ComputeWinRate_PastTrades(sym,wr,wins,losses,pf);assert(wins==w&&losses==l&&std::abs(wr-rate)<0.01);}
int main(){
 assert(!IsSameChartAsset("NDAQ","AMD"));assert(!IsSameChartAsset("AAPL","MSFT"));
 assert(!IsSameChartAsset("NDAQ","NDAQ100"));assert(!IsSameChartAsset("","NDAQ"));
 assert(IsSameChartAsset("NDAQ","NDAQ.cash"));assert(IsSameChartAsset("US100","NAS100"));
 assert(SEGSInstrumentKey("NDAQ.cash")=="NDAQ");assert(SEGSInstrumentKey("AMD")=="AMD");
 assert(SEGSQuoteFresh("NDAQ"));serverTime=1120;assert(SEGSQuoteFresh("NDAQ"));
 serverTime=1121;assert(!SEGSQuoteFresh("NDAQ"));serverTime=990;assert(!SEGSQuoteFresh("NDAQ"));
 serverTime=1000;connected=false;assert(!SEGSQuoteFresh("NDAQ"));connected=true;
 quoteAvailable=false;assert(!SEGSQuoteFresh("NDAQ"));quoteAvailable=true;
 metadata=false;assert(!SEGSQuoteFresh("NDAQ"));metadata=true;

 // Four legs, including partial exit and broker-replaced comments, count once.
 for(int i=1;i<=4;i++){add(i,0,0,"NDAQ","SEGS|ADV|abc|L1/4",0,-1);add(i,1,1,"NDAQ","[tp]",3,0,0,0.5);add(i,1,1,"NDAQ","[tp]",3,0,0,0.5);}
 refresh();metrics("NDAQ",1,0,100);assert(g_historySetups.size()==1&&g_historySetups[0].pnl==20);
 int calls=selections;metrics("NDAQ",1,0,100);assert(calls==selections);
 // Entry commission and fee turn a gross winner into a net loser.
 add(5,0,0,"NDAQ","",0,-3,-1);add(5,1,3,"NDAQ","",2);refresh();metrics("NDAQ",1,1,50);
 // Open sibling suppresses the entire setup, not only the remaining leg.
 add(6,0,0,"NDAQ","SEGS|ADV|abc|L4/4");live={6};refresh();metrics("NDAQ",0,1,0);
 live.clear();add(6,1,1,"NDAQ","[sl]",-1);refresh();metrics("NDAQ",1,1,50);
 // Same signal text on another symbol must not collide.
 add(7,0,0,"AAPL","SEGS|ADV|abc|L1/4");add(7,1,1,"AAPL","[sl]",-2);refresh();metrics("AAPL",0,1,0);metrics("ALL",1,2,33.3);
 // Master and clones share one manual setup, while unrelated manual trades stay separate.
 add(8,0,0,"NDAQ","");add(8,1,1,"NDAQ","",5);
 add(9,0,0,"NDAQ","SEGS|MAN|8|L2/4");add(9,1,1,"NDAQ","",-6);refresh();metrics("NDAQ",1,2,33.3);
 // An orphan exit with incomplete entry history cannot masquerade as a completed win.
 add(10,1,1,"NDAQ","",100);refresh();metrics("NDAQ",1,2,33.3);
 // INOUT reversal remains incomplete until the remaining position closes.
 add(11,0,0,"NDAQ","");add(11,1,2,"NDAQ","",1,0,0,2);refresh();metrics("NDAQ",1,2,33.3);
 add(11,0,1,"NDAQ","",1);refresh();metrics("NDAQ",2,2,50);
 // Small breakeven P/L contributes to net profit, not decisive wins.
 add(12,0,0,"NDAQ","");add(12,1,1,"NDAQ","",0.02);refresh();metrics("NDAQ",2,2,50);
 // Failed refresh withholds old totals, and account switches clear the snapshot.
 available=false;g_historyDirty=true;g_historyNextRefresh=0;assert(!SEGSRefreshHistory());
 clockMs+=2000;account=2;assert(!SEGSRefreshHistory());assert(g_historySetups.empty());
 available=true;deals.clear();clockMs+=2000;refresh();metrics("ALL",0,0,0);
 // Large input exercises the hashed grouping rather than quadratic position searches.
 for(int i=1;i<=20000;i++){add(i,0,0,"NDAQ","");add(i,1,1,"NDAQ","",1);}
 refresh();metrics("ALL",20000,0,100);
 std::cout<<"History regression scenarios passed (40,000-deal workload included).\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 cpp=Path(d)/'history.cpp';exe=Path(d)/'history'
 cpp.write_text(preamble+code+tests)
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(cpp),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
print('Extracted MQL history logic passed broker-stub execution; native MetaEditor validation remains required.')
