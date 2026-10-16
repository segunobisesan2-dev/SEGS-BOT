"""Execute actual reconciliation, cancellation and trade-event functions with broker history stubs."""
from pathlib import Path
import ast,subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'SEGS_Trade_Manager_Pro_v3.75.mq5').read_text()
# Share the explicitly stubbed MT5 vocabulary, without importing/rerunning its tests.
tree=ast.parse((root/'tests/test_precision_execution.py').read_text());data={}
for n in tree.body:
 if isinstance(n,ast.Assign) and isinstance(n.value,ast.Constant) and isinstance(n.value.value,str):
  for t in n.targets:
   if isinstance(t,ast.Name):data[t.id]=n.value.value
stubs=data['stubs'].replace('string PositionGetString(int){return "TEST";}enum{POSITION_SYMBOL};','enum{POSITION_SYMBOL,POSITION_COMMENT,POSITION_MAGIC};\nstring PositionGetString(int key){return key==POSITION_SYMBOL?"TEST":"SEGS|ADV|0000000000000001|L1/4";}\nlong PositionGetInteger(int){return InpAdvisorMagicNumber;}')
enums=s[s.index('enum PE_MODE'):s.index('input group "=== Precision Entry Engine')]
core=s[s.index('// BEGIN PE PURE CORE'):s.index('// END PE PURE CORE')]
reconcile=s[s.index('void PEReconcile()'):s.index('double PEATR(')]
cancel=s[s.index('bool PECancelAdvisorOrders(string sym)'):s.index('void PESetOwner(')]
event=s[s.index('void PETradeEvent('):s.index('void PESampleShock(')]
stubs=stubs.replace('bool PECancelAdvisorOrders(string){return canceled;}','')
extra=r'''
int StringFind(const string& a,const string& b){auto p=a.find(b);return p==string::npos?-1:(int)p;}
std::vector<PESetup> g_pe;
string _Symbol="TEST";bool InpPrecisionEntries=true;
template<class T>int ArraySize(const std::vector<T>& v){return v.size();}
using ENUM_ORDER_STATE=int;using ENUM_DEAL_ENTRY=int;
enum{ORDER_STATE_FILLED=20,ORDER_STATE_CANCELED,ORDER_STATE_REJECTED,ORDER_STATE_EXPIRED,ORDER_STATE_PLACED,
 ORDER_STATE,DEAL_SYMBOL,DEAL_MAGIC,DEAL_ENTRY,DEAL_COMMENT,DEAL_ENTRY_IN,DEAL_ENTRY_INOUT,
 ORDER_SYMBOL,ORDER_MAGIC,ORDER_TYPE,ORDER_TYPE_BUY_LIMIT,TRADE_TRANSACTION_REQUEST,TRADE_TRANSACTION_DEAL_ADD};
bool historyReady=true,orderKnown=true;int orderState=ORDER_STATE_FILLED,deals=0,pending=0,pendingType=ORDER_TYPE_BUY_LIMIT;
struct MqlTradeTransaction{int type;};
bool HistorySelect(datetime,datetime){return historyReady;}
bool HistoryOrderSelect(unsigned long){return orderKnown;}
long HistoryOrderGetInteger(unsigned long,int){return orderState;}
int HistoryDealsTotal(){return deals;}unsigned long HistoryDealGetTicket(int){return 1;}
string HistoryDealGetString(unsigned long,int key){return key==DEAL_SYMBOL?"TEST":"SEGS|ADV|0000000000000001|L1/4";}
long HistoryDealGetInteger(unsigned long,int key){return key==DEAL_MAGIC?InpAdvisorMagicNumber:(long)DEAL_ENTRY_IN;}
int OrdersTotal(){return pending;}unsigned long OrderGetTicket(int){return 7;}
string OrderGetString(int){return "TEST";}
long OrderGetInteger(int key){return key==ORDER_MAGIC?InpAdvisorMagicNumber:pendingType;}
struct CTrade{void SetAsyncMode(bool){}bool OrderDelete(unsigned long){if(canceled)pending--;return canceled;}unsigned ResultRetcode(){return canceled?TRADE_RETCODE_DONE:10006;}};
bool owns=true;
bool PEOwns(const PESetup&){return owns;}
void PEJournal(const PESetup&){journals++;}
void PETransition(PESetup& p,int next,string){p.state=next;journals++;}
PESetup submitted(){PESetup p{};p.symbol="TEST";p.id="0000000000000001";p.state=ENTRY_SUBMITTED;p.unresolved=true;p.order=7;p.request=1;return p;}
void reset(){globals.clear();globals["root/BUSY"]=100;g_pe={submitted()};positions=0;deals=0;historyReady=orderKnown=true;orderState=ORDER_STATE_FILLED;pending=0;canceled=true;pendingType=ORDER_TYPE_BUY_LIMIT;owns=true;}
'''
tests=r'''
int main(){
 reset();deals=1;PEReconcile();CHECK(g_pe[0].state==TRADED);CHECK(!g_pe[0].unresolved);CHECK(globals["root/BUSY"]==0);
 reset();positions=1;PEReconcile();CHECK(g_pe[0].state==TRADED);CHECK(globals["root/BUSY"]==0);
 reset();orderState=ORDER_STATE_PLACED;deals=1;PEReconcile();CHECK(g_pe[0].state==TRADED);CHECK(g_pe[0].unresolved);CHECK(globals["root/BUSY"]>0);
 orderState=ORDER_STATE_FILLED;PEReconcile();CHECK(!g_pe[0].unresolved);CHECK(globals["root/BUSY"]==0);
 reset();orderState=ORDER_STATE_REJECTED;PEReconcile();CHECK(g_pe[0].state==INVALIDATED);CHECK(globals["root/BUSY"]==0);
 reset();orderKnown=false;PEReconcile();CHECK(g_pe[0].state==ENTRY_SUBMITTED);CHECK(globals["root/BUSY"]>0);
 reset();historyReady=false;PEReconcile();CHECK(g_pe[0].state==ENTRY_SUBMITTED);CHECK(globals["root/BUSY"]>0);
 reset();globals["root/LEGACY"]=1;deals=1;PEReconcile();CHECK(globals["root/BUSY"]>0); // precision must not clear legacy uncertainty
 reset();pending=1;CHECK(PECancelAdvisorOrders("TEST"));CHECK(pending==0);
 reset();pending=1;canceled=false;CHECK(!PECancelAdvisorOrders("TEST"));CHECK(pending==1);
 reset();pending=1;pendingType=ORDER_TYPE_BUY;CHECK(!PECancelAdvisorOrders("TEST"));CHECK(pending==1);
 reset();orderKnown=false;MqlTradeRequest req{};req.symbol="TEST";req.magic=InpAdvisorMagicNumber;req.comment="SEGS|ADV|0000000000000001|L1/4";
 MqlTradeResult result{};result.request_id=1;result.retcode=10006;
 PETradeEvent({TRADE_TRANSACTION_REQUEST},req,result);CHECK(g_pe[0].state==INVALIDATED);CHECK(!g_pe[0].unresolved);CHECK(globals["root/BUSY"]==0);
 reset();orderKnown=false;result.request_id=2;PETradeEvent({TRADE_TRANSACTION_REQUEST},req,result);CHECK(g_pe[0].state==ENTRY_SUBMITTED);CHECK(g_pe[0].unresolved);
 reset();orderKnown=false;result.request_id=1;result.retcode=TRADE_RETCODE_TIMEOUT;PETradeEvent({TRADE_TRANSACTION_REQUEST},req,result);CHECK(g_pe[0].state==ENTRY_SUBMITTED);CHECK(g_pe[0].unresolved);
 reset();orderKnown=false;deals=1;PETradeEvent({TRADE_TRANSACTION_DEAL_ADD},req,result);CHECK(g_pe[0].state==TRADED);CHECK(g_pe[0].unresolved);
 reset();owns=false;deals=1;PEReconcile();CHECK(globals["root/BUSY"]>0);
 reset();g_pe.clear();PEReconcile();CHECK(globals["root/BUSY"]>0);
 std::cout<<checksCount<<" actual-reconciliation/cancellation/event assertions passed (stubbed broker)\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'reconcile.cpp';p.write_text(stubs+enums+core+extra+cancel+reconcile+event+tests)
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(p.with_suffix(''))],check=True)
 subprocess.run([str(p.with_suffix(''))],check=True)
