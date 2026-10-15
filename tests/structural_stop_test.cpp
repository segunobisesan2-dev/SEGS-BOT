
#include <cmath>
#include <string>
#include <iostream>
#include <cassert>
#include <algorithm>
using string=std::string;
using std::min; using std::max;
template<class A,class B> double MathMax(A a,B b){return max(double(a),double(b));}
template<class A,class B> double MathMin(A a,B b){return min(double(a),double(b));}
double MathAbs(double x){return std::abs(x);} double MathFloor(double x){return std::floor(x);} double MathCeil(double x){return std::ceil(x);}
bool MathIsValidNumber(double x){return std::isfinite(x);} double NormalizeDouble(double x,int n){double k=std::pow(10,n);return std::round(x*k)/k;}
enum ENUM_SEGS_SL_STYLE{SL_STYLE_ORDER_BLOCK,SL_STYLE_MULTI_DAY,SL_STYLE_AUTO_DUAL,SL_STYLE_ACTIVE_ORDER_BLOCK};
ENUM_SEGS_SL_STYLE g_systemStopStyle=SL_STYLE_AUTO_DUAL;
double InpStructuralBufferATR=.20,InpDualProximityATR=.85;
string _Symbol="TEST";double g_recentSwingLow=0,g_recentSwingHigh=0,g_recentSupport=0,g_recentResistance=0;
enum {SYMBOL_POINT,SYMBOL_TRADE_TICK_SIZE,SYMBOL_DIGITS,SYMBOL_TRADE_STOPS_LEVEL,PERIOD_D1,PERIOD_H4,PERIOD_W1};
double point=.01,tick=.01,bid=100,ask=100.02;int stops=0,digits=2;bool ready=true;
double lows[3][30]={},highs[3][30]={};
int tfindex(int tf){return tf==PERIOD_D1?0:tf==PERIOD_H4?1:2;}
double iLow(string,int tf,int bar){return lows[tfindex(tf)][bar];}
double iHigh(string,int tf,int bar){return highs[tfindex(tf)][bar];}
double SymbolInfoDouble(string,int prop){return prop==SYMBOL_POINT?point:tick;}
long SymbolInfoInteger(string,int prop){return prop==SYMBOL_DIGITS?digits:stops;}
struct MqlTick{double bid,ask;};bool SymbolInfoTick(string,MqlTick &q){q.bid=bid;q.ask=ask;return ready;}
bool SEGSMarketReady(string){return ready&&point>0&&tick>0;}
#include <vector>
#include <cfloat>
struct M30OrderBlock { double low,high; bool bullish,invalidated; double wickLow=low,wickHigh=high; };
std::vector<M30OrderBlock> g_orderBlocks,g_h1OrderBlocks;
template<class T> int ArraySize(const std::vector<T> &a){return int(a.size());}
double g_systemOBMaxDistanceATR=3.0,g_systemOBBufferATR=.05;int g_systemOBBufferTicks=3;
double g_systemMaxStopATR=1.5,g_systemMaxStopPercent=0;
bool SEGSSelectActiveOrderBlock(string sym, bool buy, double price, double atr, double &low, double &high)
{
   low = 0.0; high = 0.0;
   if(sym != _Symbol || !SEGSMarketReady(sym)) return false;
   double maxDistance = MathMax(g_systemOBMaxDistanceATR * atr, 10.0 * SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE));
   double bestDistance = DBL_MAX;
   for(int tf = 0; tf < 2; tf++)
   {
      int count = tf == 0 ? ArraySize(g_orderBlocks) : ArraySize(g_h1OrderBlocks);
      for(int i = 0; i < count; i++)
      {
         M30OrderBlock zone;
         if(tf == 0) zone = g_orderBlocks[i]; else zone = g_h1OrderBlocks[i];
         if(zone.invalidated || zone.bullish != buy || zone.low <= 0.0 || zone.high <= zone.low) continue;
         double boundary = buy ? zone.low : zone.high;
         if(buy ? boundary >= price : boundary <= price) continue;
         double distance = MathAbs(price - boundary);
         if(distance <= maxDistance && distance < bestDistance)
         { low = zone.low; high = zone.high; bestDistance = distance; }
      }
   }
   return low > 0.0;
}

void SEGSAddStopAnchor(double value, bool buy, double entry, double floorOrCeiling,
                       double proximity, double &extreme, double &nearby)
{
   if(!MathIsValidNumber(value) || value <= 0.0 || (buy ? value >= entry : value <= entry)) return;
   if(extreme == 0.0 || (buy ? value < extreme : value > extreme)) extreme = value;
   bool beyond = buy ? value < floorOrCeiling : value > floorOrCeiling;
   if(floorOrCeiling > 0.0 && beyond && MathAbs(value - floorOrCeiling) <= proximity &&
      (nearby == 0.0 || (buy ? value < nearby : value > nearby))) nearby = value;
}

// A structural invalidation is never moved inside the block to satisfy a distance limit.
double SEGSStopLimit(double entry, double atr)
{
   if(entry<=0 || atr<=0 || !MathIsValidNumber(entry) || !MathIsValidNumber(atr)) return 0.0;
   double limit=g_systemMaxStopATR*atr;
   if(g_systemMaxStopPercent>0) limit=MathMin(limit,entry*g_systemMaxStopPercent/100.0);
   return MathIsValidNumber(limit) && limit>0 ? limit : 0.0;
}

bool SEGSResolveEntryWick(string sym, double zoneLow, double zoneHigh, bool buy, double &low, double &high)
{
   low=zoneLow; high=zoneHigh;
   if(sym!=_Symbol || low<=0 || high<=low) return false;
   double tick=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   for(int pass=0; pass<2; pass++)
   {
      int count=pass==0 ? ArraySize(g_orderBlocks) : ArraySize(g_h1OrderBlocks);
      for(int i=0; i<count; i++)
      {
         M30OrderBlock ob;
         if(pass==0) ob=g_orderBlocks[i]; else ob=g_h1OrderBlocks[i];
         if(ob.invalidated || ob.bullish!=buy || MathAbs(ob.low-zoneLow)>tick || MathAbs(ob.high-zoneHigh)>tick) continue;
         if(ob.wickLow>0 && ob.wickHigh>ob.wickLow)
            { low=ob.wickLow; high=ob.wickHigh; return true; }
         return false; // A body-only zone without its origin wick is not an authoritative stop anchor.
      }
   }
   // Structural callers may supply explicit wick bounds; live execution always resolves an actual block.
   return low>0 && high>low;
}

double SEGSFinalizeStructuralStop(string sym, bool buy, double entry, double anchor, double atr, double boundary)
{
   double tick=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE),pt=SymbolInfoDouble(sym,SYMBOL_POINT);
   if(anchor<=0 || tick<=0 || pt<=0 || (buy ? anchor>=entry : anchor<=entry)) return 0.0;
   double buffer=MathMax(g_systemOBBufferATR*atr,g_systemOBBufferTicks*tick);
   double stop=buy ? anchor-buffer : anchor+buffer;
   MqlTick quote;
   if(!SymbolInfoTick(sym,quote) || !MathIsValidNumber(quote.bid) || !MathIsValidNumber(quote.ask) || quote.bid<=0 || quote.ask<quote.bid) return 0.0;
   double broker=MathMax((double)SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL)*pt,tick)+2*tick;
   stop=buy ? MathMin(stop,MathMin(entry,quote.bid)-broker) : MathMax(stop,MathMax(entry,quote.ask)+broker);
   stop=(buy ? MathFloor(stop/tick) : MathCeil(stop/tick))*tick;
   stop=NormalizeDouble(stop,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
   if(!MathIsValidNumber(stop) || stop<=0 || (buy ? stop>=entry : stop<=entry)) return 0.0;
   if(boundary>0 && (buy ? stop>=boundary : stop<=boundary)) return 0.0;
   double limit=SEGSStopLimit(entry,atr);
   if(limit<=0 || MathAbs(entry-stop)>limit+tick*0.000001) return 0.0;
   return stop;
}

void SEGSConsiderInstitutionalStop(string sym, bool buy, double entry, double anchor, double atr,
                                  double boundary, double &best)
{
   // A fallback may not sit inside the entered block's full wick.
   if(boundary>0 && (buy ? anchor>=boundary : anchor<=boundary)) return;
   double candidate=SEGSFinalizeStructuralStop(sym,buy,entry,anchor,atr,boundary);
   if(candidate>0 && (best<=0 || MathAbs(entry-candidate)<MathAbs(entry-best))) best=candidate;
}

double GetSafestStructuralStopLoss(string sym, string dir, double entryPrice, double obZoneLow, double obZoneHigh, double curAtr, bool preferMultiDay=false)
{
   if((dir!="BUY" && dir!="SELL") || !SEGSMarketReady(sym) || !MathIsValidNumber(curAtr) || curAtr<=0 ||
      !MathIsValidNumber(entryPrice) || entryPrice<=0) return 0.0;
   bool buy=dir=="BUY";
   double low=0,high=0;
   bool hasBlock=SEGSResolveEntryWick(sym,obZoneLow,obZoneHigh,buy,low,high);
   if(obZoneLow>0 && obZoneHigh>obZoneLow && !hasBlock) return 0.0;
   if(g_systemStopStyle==SL_STYLE_ACTIVE_ORDER_BLOCK && !hasBlock)
   {
      double activeLow=0,activeHigh=0;
      if(!SEGSSelectActiveOrderBlock(sym,buy,entryPrice,curAtr,activeLow,activeHigh) ||
         !SEGSResolveEntryWick(sym,activeLow,activeHigh,buy,low,high)) return 0.0;
      hasBlock=true;
   }
   double boundary=hasBlock ? (buy ? low : high) : 0.0;
   if(hasBlock && (buy ? boundary>=entryPrice : boundary<=entryPrice)) return 0.0;
   // Dual default is wick FIRST. A nearby daily/weekly extreme can no longer silently widen it.
   bool preferInstitutional=g_systemStopStyle==SL_STYLE_MULTI_DAY || (preferMultiDay && !hasBlock);
   if(hasBlock && !preferInstitutional)
   {
      double primary=SEGSFinalizeStructuralStop(sym,buy,entryPrice,boundary,curAtr,boundary);
      if(primary>0) return primary;
   }
   if(g_systemStopStyle==SL_STYLE_ORDER_BLOCK || g_systemStopStyle==SL_STYLE_ACTIVE_ORDER_BLOCK) return 0.0;
   double best=0;
   for(int d=1; d<=5; d++)
      SEGSConsiderInstitutionalStop(sym,buy,entryPrice,buy ? iLow(sym,PERIOD_D1,d) : iHigh(sym,PERIOD_D1,d),curAtr,boundary,best);
   for(int h=2; h<=24; h++)
   {
      double value=buy ? iLow(sym,PERIOD_H4,h) : iHigh(sym,PERIOD_H4,h);
      double older=buy ? iLow(sym,PERIOD_H4,h+1) : iHigh(sym,PERIOD_H4,h+1);
      double newer=buy ? iLow(sym,PERIOD_H4,h-1) : iHigh(sym,PERIOD_H4,h-1);
      if(value>0 && older>0 && newer>0 && (buy ? value<older && value<=newer : value>older && value>=newer))
         SEGSConsiderInstitutionalStop(sym,buy,entryPrice,value,curAtr,boundary,best);
   }
   SEGSConsiderInstitutionalStop(sym,buy,entryPrice,buy ? iLow(sym,PERIOD_W1,1) : iHigh(sym,PERIOD_W1,1),curAtr,boundary,best);
   if(sym==_Symbol)
   {
      SEGSConsiderInstitutionalStop(sym,buy,entryPrice,buy ? g_recentSwingLow : g_recentSwingHigh,curAtr,boundary,best);
      SEGSConsiderInstitutionalStop(sym,buy,entryPrice,buy ? g_recentSupport : g_recentResistance,curAtr,boundary,best);
   }
   return best; // Zero means defer; no arbitrary tight stop replaces missing institutional structure.
}


void reset(){
 point=.01;tick=.01;bid=100;ask=100.02;stops=0;digits=2;ready=true;
 g_systemStopStyle=SL_STYLE_AUTO_DUAL;g_systemMaxStopATR=1.5;g_systemMaxStopPercent=0;
 g_systemOBBufferATR=.05;g_systemOBBufferTicks=3;
 g_orderBlocks.clear();g_h1OrderBlocks.clear();
 g_recentSwingLow=g_recentSwingHigh=g_recentSupport=g_recentResistance=0;
 for(int i=0;i<3;i++)for(int j=0;j<30;j++){lows[i][j]=0;highs[i][j]=0;}
}
void near(double got,double expected){assert(std::abs(got-expected)<1e-8);}
int main(){int checks=0;
 reset();lows[0][1]=99.3;lows[0][2]=90;highs[0][1]=100.7;
 near(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1),99.45);checks++;
 near(GetSafestStructuralStopLoss("TEST","SELL",100,100.1,100.5,1),100.55);checks++;
 // Wick-first does not widen to nearby daily liquidity, including caller swing preference.
 near(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1,true),99.45);checks++;
 g_orderBlocks={{99.6,99.9,true,false,99.2,100.1}};
 near(GetSafestStructuralStopLoss("TEST","BUY",100,99.6,99.9,1),99.15);checks++;
 g_orderBlocks={{100.1,100.4,false,false,99.9,100.8}};
 near(GetSafestStructuralStopLoss("TEST","SELL",100,100.1,100.4,1),100.85);checks++;
 // Missing origin wick on a known body block must defer.
 g_orderBlocks[0].wickLow=0;g_orderBlocks[0].wickHigh=0;
 assert(GetSafestStructuralStopLoss("TEST","SELL",100,100.1,100.4,1)==0);checks++;
 // An oversized wick cannot be replaced by an institutional point inside that wick.
 reset();lows[0][1]=99.6;
 assert(GetSafestStructuralStopLoss("TEST","BUY",100,97,99.9,1)==0);checks++;
 assert(GetSafestStructuralStopLoss("TEST","SELL",100,100.1,103,1)==0);checks++;
 // With no entry OB, select the nearest valid institutional point, not a remote extreme.
 reset();lows[0][1]=99.4;lows[0][2]=90;lows[2][1]=80;
 near(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1),99.35);checks++;
 g_recentSupport=99.8;near(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1),99.75);checks++;
 highs[0][1]=100.4;highs[0][2]=110;
 near(GetSafestStructuralStopLoss("TEST","SELL",100,0,0,1),100.45);checks++;
 reset();lows[0][1]=90;assert(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1)==0);checks++;
 reset();assert(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1)==0);checks++;
 // Explicit modes remain functional and remain capped.
 g_systemStopStyle=SL_STYLE_ORDER_BLOCK;
 assert(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1)==0);checks++;
 near(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1),99.45);checks++;
 g_systemStopStyle=SL_STYLE_MULTI_DAY;lows[0][1]=99.3;
 near(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1),99.25);checks++;
 // Caps apply AFTER broker minimum-distance adjustment and outward tick rounding.
 reset();stops=200;assert(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1)==0);checks++;
 assert(GetSafestStructuralStopLoss("TEST","SELL",100,100.1,100.5,1)==0);checks++;
 reset();tick=.25;
 double stop=GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1);
 near(stop,98.75);assert(std::abs(stop/tick-std::round(stop/tick))<1e-8);checks+=2;
 reset();g_systemMaxStopPercent=.5;
 assert(GetSafestStructuralStopLoss("TEST","BUY",100,99.4,99.9,1)==0);checks++;
 near(GetSafestStructuralStopLoss("TEST","BUY",100,99.8,99.9,1),99.75);checks++;
 g_systemMaxStopPercent=1;near(GetSafestStructuralStopLoss("TEST","BUY",100,99.05,99.9,1),99);checks++;
 // Optional active-zone trailing still chooses a real wick and permits profit protection.
 reset();g_systemStopStyle=SL_STYLE_ACTIVE_ORDER_BLOCK;
 g_orderBlocks={{99.5,99.8,true,false,99.4,99.9}};
 near(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1),99.35);checks++;
 assert(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1)>98);checks++;
 g_orderBlocks[0].invalidated=true;assert(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1)==0);checks++;
 reset();point=0;assert(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1)==0);checks++;
 reset();tick=0;assert(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,1)==0);checks++;
 reset();assert(GetSafestStructuralStopLoss("TEST","BUY",100,99.5,99.9,0)==0);checks++;
 assert(GetSafestStructuralStopLoss("TEST","INVALID",100,99.5,99.9,1)==0);checks++;
 assert(GetSafestStructuralStopLoss("TEST","BUY",100,100.1,100.5,1)==0);checks++;
 std::cout<<checks<<" bounded dual-stop assertions passed\n";
}
