"""Compile actual EA state-transition functions with C++ adapters; no MT5 runtime claims."""
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'SEGS_Trade_Manager_Pro_v3.75.mq5').read_text()
a=s.index('// BEGIN PE PURE CORE');b=s.index('// END PE PURE CORE',a)
core=s[a:b]
enums=s[s.index('enum PE_MODE'):s.index('input group "=== Precision Entry Engine')]
preamble=r'''
#include <cassert>
#include <cmath>
#include <iostream>
#include <string>
using string=std::string;
using datetime=long long;
int StringCompare(const string& a,const string& b) { return a.compare(b); }
double MathAbs(double v) { return std::abs(v); }
int checks=0;
#define CHECK(v) do { ++checks; if(!(v)) { std::cerr<<"Failed line "<<__LINE__<<": "<<#v<<"\n"; std::abort(); } } while(0)
'''
tests=r'''
PESetup setup(bool buy,int mode=DIRECT_TOUCH,int timing=RETEST_TOUCH) {
 PESetup s{};s.buy=buy;s.originalBuy=buy;s.low=100;s.high=110;s.level=buy?110:100;
 s.eligible=100;s.expires=2000;s.mode=mode;s.timing=timing;s.invalidation=WICK_BREAK;
 s.state=mode==DIRECT_TOUCH?ELIGIBLE:WAITING_FOR_BREAKOUT;
 s.tolerance=.25;s.invalidBuffer=1;s.breakoutBuffer=1;s.rejectionBuffer=1;s.sl=buy?98:112;
 return s;
}
PEBar closed(datetime t,double lo=101,double hi=109,double close=105) { return {t,t+60,105,hi,lo,close}; }
int main() {
 for(bool buy:{true,false}) {
  double above=buy?114:96,touch=buy?110:100,broken=buy?98:112;
  PEBar old=closed(0);
  auto s=setup(buy);
  CHECK(!PEStep(s,110,above,old));CHECK(PEStep(s,111,touch,old));CHECK(s.touches==1);
  CHECK(!PEStep(s,112,touch,old)); // repeated quote cannot emit again
  s.state=ENTRY_SUBMITTED;CHECK(!PEStep(s,113,touch,old));
  s.state=TRADED;CHECK(!PEStep(s,114,touch,old));
  s=setup(buy);CHECK(!PEStep(s,110,touch,old)); // attach inside band has no eligible approach
  s=setup(buy);PEStep(s,110,above,old);CHECK(!PEStep(s,111,broken,old));CHECK(s.state==INVALIDATED); // gap
  s=setup(buy);s.expires=111;PEStep(s,110,above,old);CHECK(!PEStep(s,111,touch,old));CHECK(s.state==EXPIRED);
  // Same tick has touch within wide tolerance AND far-boundary breach: invalidation wins.
  s=setup(buy);s.tolerance=20;s.approached=true;CHECK(!PEStep(s,111,broken,old));CHECK(s.state==INVALIDATED);
  s=setup(buy,BREAKOUT_RETEST);CHECK(!PEStep(s,110,above,old));CHECK(!PEStep(s,111,touch,old));CHECK(s.state==WAITING_FOR_BREAKOUT);
  // Wicks beyond breakout boundary alone are not confirmation.
  auto wick=closed(120,buy?100:96,buy?114:110,105);s=setup(buy,BREAKOUT_RETEST);
  CHECK(!PEStep(s,180,above,wick));CHECK(s.state==WAITING_FOR_BREAKOUT);
  auto breakout=closed(180,buy?101:97,buy?113:109,buy?112:98);
  s=setup(buy,BREAKOUT_RETEST);
  CHECK(!PEStep(s,240,above,breakout));CHECK(s.state==WAITING_FOR_RETEST);CHECK(s.breakout==240);
  CHECK(PEStep(s,241,touch,breakout));CHECK(s.state==RETEST_TOUCHED); // subsequent quote only
  // Breakout candle's low/high alone must never become a retest.
  s=setup(buy,BREAKOUT_RETEST);CHECK(!PEStep(s,240,above,breakout));CHECK(s.touches==0);
  CHECK(!PEStep(s,241,above,breakout));CHECK(s.touches==0);
  // Close confirmation must be observed after breakout, never earlier in that candle.
  s=setup(buy,BREAKOUT_RETEST,RETEST_REJECTION_CLOSE);
  CHECK(!PEStep(s,240,above,breakout));CHECK(!PEStep(s,241,touch,breakout));
  CHECK(!PEStep(s,242,above,breakout));
  auto rejection=closed(240,buy?110:97,buy?113:100,buy?112:98);
  CHECK(PEStep(s,300,above,rejection));CHECK(!PEStep(s,301,above,rejection));
  // OHLC wick retest without an observed tick is deliberately skipped.
  s=setup(buy,BREAKOUT_RETEST,RETEST_REJECTION_CLOSE);
  PEStep(s,240,above,breakout);CHECK(!PEStep(s,300,above,rejection));CHECK(s.touches==0);
  // Structural CLOSE_BREAK remains distinct from protective SL.
  s=setup(buy);s.invalidation=CLOSE_BREAK;PEStep(s,110,above,old);
  CHECK(!PEStep(s,111,broken,old));CHECK(s.state==ELIGIBLE);CHECK(s.sl==(buy?98:112));
  auto bad=closed(120,97,113,broken);CHECK(!PEStep(s,180,touch,bad));CHECK(s.state==INVALIDATED);
  s=setup(buy);PEStep(s,110,above,old);
  CHECK(!PEStep(s,180,touch,bad));CHECK(s.state==INVALIDATED); // candle breach before tick touch
  s=setup(buy);s.manual=true;s.low=s.high=s.level;
  CHECK(!PEStep(s,110,above,old));CHECK(PEStep(s,111,touch,old)); // manual stop, not level, is far boundary
  CHECK(PEBreaks(setup(buy),buy?98:112,true));CHECK(!PEBreaks(setup(buy),105,true));
 }
 auto a=setup(true),b=setup(false);a.id="A";b.id="B";
 CHECK(PEPriorityBefore(a,b));CHECK(!PEPriorityBefore(b,a));
 CHECK(PEOpposingOverlap(a,b));b.low=111;b.high=120;CHECK(!PEOpposingOverlap(a,b));
 b=setup(false);b.state=INVALIDATED;CHECK(!PEOpposingOverlap(a,b));
 b=setup(true);CHECK(!PEOpposingOverlap(a,b));
 CHECK(PEUncertainRetcode(10028));CHECK(PEUncertainRetcode(10023));CHECK(PEUncertainRetcode(99999));
 CHECK(PEUncertainRetcode(10012));CHECK(!PEUncertainRetcode(10006));CHECK(!PEUncertainRetcode(10009));
 std::cout<<checks<<" actual-state-function assertions passed\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'precision.cpp';p.write_text(preamble+enums+core+tests)
 subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',str(p),'-o',str(p.with_suffix(''))],check=True)
 subprocess.run([str(p.with_suffix(''))],check=True)
# Integration wiring assertions supplement, never replace, executable sequence tests.
assert 'PESampleShock(_Symbol);\n   PEMonitor();\n   RunAdvisorStrategyEngine' in s
assert 'if(InpPrecisionEntries) { PEMonitor(); return; }' in s
assert 'PETradeEvent(trans,request,result);' in s
assert 'bool sent=OrderSend(requests[l],result);' in s
assert s.index('PETransition(s,ENTRY_SUBMITTED') < s.index('bool sent=OrderSend(requests[l],result);')
assert 'TRADE_RETCODE_DONE_PARTIAL' in s and 'no blind retry' in s
assert 'simultaneous opposite entry events: skip both' in s
assert 'overlapping opposing eligible zones' in s
assert 'restart: no replay of unobserved ticks' in s
assert 'if(!cancel.OrderDelete(tk) || cancel.ResultRetcode()!=TRADE_RETCODE_DONE)' in s
assert 'if(!trade.OrderDelete(ticket) || trade.ResultRetcode()!=TRADE_RETCODE_DONE) continue;' in s
assert 'GlobalVariableDel(sigExecKey)' not in s[s.index('void CheckAndAutoTradeAdvice()\n{'):s.index('double CalcRiskFromSL(ulong ticket)\n{')]
print('Precision integration source assertions passed (not broker runtime tests).')
