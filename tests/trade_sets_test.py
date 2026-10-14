"""Execute the current set counter with MT5 position/string stubs."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'SEGS_Trade_Manager_Pro_v3.75.mq5').read_text()
a=s.index('int CountOpenAdvisorSetsForSymbol(string sym)\n{');b=s.index('\nbool HasOpenAdvisorTradesForSignal',a)
fn=s[a:b].replace('string ids[];', 'std::vector<string> ids;')
preamble=r'''
#include <string>
#include <vector>
#include <cassert>
using string=std::string;
using ulong=unsigned long;
struct Position { string symbol,comment; long magic; };
std::vector<Position> positions;
long InpAdvisorMagicNumber=333777;
int selected=0;
struct Info {
 bool SelectByTicket(ulong t){selected=int(t)-1;return selected>=0 && selected<int(positions.size());}
 string Symbol(){return positions[selected].symbol;}
 string Comment(){return positions[selected].comment;}
 long Magic(){return positions[selected].magic;}
} posInfo;
int PositionsTotal(){return int(positions.size());}
ulong PositionGetTicket(int i){return i+1;}
int StringFind(string s,string v,int start=0){auto p=s.find(v,start);return p==string::npos?-1:int(p);}
string StringSubstr(string s,int start,int n){return s.substr(start,n);}
string IntegerToString(long n){return std::to_string(n);}
int ArraySize(const std::vector<string>& v){return int(v.size());}
int ArrayResize(std::vector<string>& v,int n){v.resize(n);return n;}
'''
cases=r'''
int main(){
 assert(CountOpenAdvisorSetsForSymbol("XAUUSD")==0);
 positions={{"XAUUSD","SEGS|ADV|buy123|L1/4",333777},
            {"XAUUSD","SEGS|ADV|buy123|L4/4",333777}};
 assert(CountOpenAdvisorSetsForSymbol("XAUUSD")==1);
 positions.push_back({"XAUUSD","SEGS|ADV|sell456|L1/4",333777});
 positions.push_back({"XAUUSD","SEGS|ADV|sell456|L3/4",333777});
 assert(CountOpenAdvisorSetsForSymbol("XAUUSD")==2);
 assert(CountOpenAdvisorSetsForSymbol("USDCHF")==0);
 positions.push_back({"USDCHF","SEGS|ADV|other|L1/4",333777});
 positions.push_back({"XAUUSD","manual",0});
 assert(CountOpenAdvisorSetsForSymbol("XAUUSD")==2);
 assert(CountOpenAdvisorSetsForSymbol("USDCHF")==1);
 positions.erase(positions.begin(),positions.begin()+2);
 assert(CountOpenAdvisorSetsForSymbol("XAUUSD")==1);
 positions.push_back({"XAUUSD","truncated",333777});
 assert(CountOpenAdvisorSetsForSymbol("XAUUSD")==2);
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'test.cpp';p.write_text(preamble+fn+cases)
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',d+'/test'],check=True)
 subprocess.run([d+'/test'],check=True)
print('8 extracted set-count assertions passed')
