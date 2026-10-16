"""Execute actual PERequestCheck with deterministic symbol, margin and broker-check APIs."""
from pathlib import Path
import ast,re,subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'SEGS_Trade_Manager_Pro_v3.75.mq5').read_text()
tree=ast.parse((root/'tests/test_precision_execution.py').read_text());data={}
for n in tree.body:
 if isinstance(n,ast.Assign) and isinstance(n.value,ast.Constant) and isinstance(n.value.value,str):
  for t in n.targets:
   if isinstance(t,ast.Name):data[t.id]=n.value.value
stubs=data['stubs'];stubs=re.sub(r'bool PERequestCheck\(.*?\n','',stubs)
stubs=stubs.replace('string PositionGetString(int){return "TEST";}enum{POSITION_SYMBOL};','enum{POSITION_SYMBOL,POSITION_TYPE,POSITION_VOLUME};\nstring PositionGetString(int){return "TEST";}\nlong PositionGetInteger(int){return ORDER_TYPE_BUY;}\ndouble PositionGetDouble(int){return .5;}')
stubs=stubs.replace('if(key==SYMBOL_VOLUME_STEP', 'if(key==SYMBOL_VOLUME_LIMIT)return volumeLimit;if(key==SYMBOL_VOLUME_STEP')
stubs=stubs.replace('double SymbolInfoDouble(', 'double volumeLimit=0;\ndouble SymbolInfoDouble(')
stubs=stubs.replace('margin=vol*10;', 'margin=vol*marginFactor;').replace('bool OrderCalcMargin(', 'double marginFactor=10;\nbool OrderCalcMargin(')
extra=r'''
enum{ORDER_SYMBOL,ORDER_TYPE,ORDER_VOLUME_CURRENT,ORDER_TYPE_BUY_LIMIT,ORDER_TYPE_BUY_STOP,ORDER_TYPE_BUY_STOP_LIMIT};
using ENUM_ORDER_TYPE_FILLING=int;
bool gateOK=true,checkOK=true;unsigned brokerRet=0;
struct MqlTradeCheckResult{unsigned retcode=0;string comment;};
int OrdersTotal(){return 0;}unsigned long OrderGetTicket(int){return 1;}string OrderGetString(int){return "TEST";}
long OrderGetInteger(int){return ORDER_TYPE_BUY_LIMIT;}double OrderGetDouble(int){return 0;}
bool PEFinalGate(string,bool,double,double,double,string&){return gateOK;}
bool OrderCheck(MqlTradeRequest&,MqlTradeCheckResult& result){result.retcode=brokerRet;return checkOK;}
double MathRound(double v){return std::round(v);}
'''
# Symbol constant must be defined before the stub SymbolInfoDouble implementation.
stubs=stubs.replace('SYMBOL_POINT,','SYMBOL_POINT,SYMBOL_VOLUME_LIMIT,')
fn=s[s.index('bool PERequestCheck('):s.index('ENUM_ORDER_TYPE_FILLING PEFill(')]
tests=r'''
int main(){
 for(bool buy:{true,false}){
 MqlTradeRequest q{};q.symbol="TEST";q.type=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;q.price=110;q.sl=buy?100:120;q.tp=buy?130:90;q.volume=1;
 string why;gateOK=checkOK=true;brokerRet=0;volumeLimit=0;positions=0;marginFactor=10;
 CHECK(PERequestCheck(q,10,why));CHECK(!PERequestCheck(q,9.99,why));
 q.volume=.001;CHECK(!PERequestCheck(q,100,why));q.volume=.333;CHECK(!PERequestCheck(q,100,why));
 q.volume=101;CHECK(!PERequestCheck(q,2000,why));q.volume=1;
 gateOK=false;CHECK(!PERequestCheck(q,100,why));gateOK=true;
 checkOK=false;CHECK(!PERequestCheck(q,100,why));checkOK=true;
 brokerRet=10006;CHECK(!PERequestCheck(q,100,why));brokerRet=TRADE_RETCODE_DONE;CHECK(PERequestCheck(q,100,why));brokerRet=0;
 marginFactor=20000;CHECK(!PERequestCheck(q,100,why));marginFactor=10;
 volumeLimit=.5;CHECK(!PERequestCheck(q,100,why));volumeLimit=0;
 q.sl=buy?120:100;CHECK(!PERequestCheck(q,100,why));
 }
 std::cout<<checksCount<<" actual-request-risk assertions passed (stubbed broker)\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'risk.cpp';p.write_text(stubs+extra+fn+tests)
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(p.with_suffix(''))],check=True)
 subprocess.run([str(p.with_suffix(''))],check=True)
