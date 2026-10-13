
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
enum ENUM_SEGS_SL_STYLE{SL_STYLE_ORDER_BLOCK,SL_STYLE_MULTI_DAY,SL_STYLE_AUTO_DUAL};
ENUM_SEGS_SL_STYLE InpStructuralStopStyle=SL_STYLE_AUTO_DUAL;
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
void SEGSAddStopAnchor(double value, bool buy, double entry, double floorOrCeiling,
                       double proximity, double &extreme, double &nearby)
{
   if(!MathIsValidNumber(value) || value <= 0.0 || (buy ? value >= entry : value <= entry)) return;
   if(extreme == 0.0 || (buy ? value < extreme : value > extreme)) extreme = value;
   bool beyond = buy ? value < floorOrCeiling : value > floorOrCeiling;
   if(floorOrCeiling > 0.0 && beyond && MathAbs(value - floorOrCeiling) <= proximity &&
      (nearby == 0.0 || (buy ? value < nearby : value > nearby))) nearby = value;
}

double GetSafestStructuralStopLoss(string sym, string dir, double entryPrice, double obZoneLow, double obZoneHigh, double curAtr, bool preferMultiDay=false)
{
   if((dir != "BUY" && dir != "SELL") || !MathIsValidNumber(entryPrice) || entryPrice <= 0.0 ||
      !SEGSMarketReady(sym)) return 0.0;
   bool buy = (dir == "BUY");
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double atr = MathIsValidNumber(curAtr) ? MathMax(0.0, curAtr) : 0.0;
   double buffer = MathMax(MathMax(0.0, InpStructuralBufferATR) * atr, 3.0 * tick);
   double proximity = MathMax(MathMax(0.0, InpDualProximityATR) * atr, 6.0 * tick);
   bool validOB = MathIsValidNumber(obZoneLow) && MathIsValidNumber(obZoneHigh) &&
                  obZoneLow > 0.0 && obZoneHigh > obZoneLow &&
                  (buy ? obZoneLow < entryPrice : obZoneHigh > entryPrice);
   double boundary = validOB ? (buy ? obZoneLow : obZoneHigh) : 0.0;
   double extreme = 0.0, nearby = 0.0;
   for(int d = 1; d <= 5; d++)
      SEGSAddStopAnchor(buy ? iLow(sym, PERIOD_D1, d) : iHigh(sym, PERIOD_D1, d),
                        buy, entryPrice, boundary, proximity, extreme, nearby);
   for(int h = 2; h <= 24; h++)
   {
      double v = buy ? iLow(sym, PERIOD_H4, h) : iHigh(sym, PERIOD_H4, h);
      double left = buy ? iLow(sym, PERIOD_H4, h+1) : iHigh(sym, PERIOD_H4, h+1);
      double right = buy ? iLow(sym, PERIOD_H4, h-1) : iHigh(sym, PERIOD_H4, h-1);
      if(left > 0.0 && right > 0.0 && (buy ? (v <= left && v <= right) : (v >= left && v >= right)))
         SEGSAddStopAnchor(v, buy, entryPrice, boundary, proximity, extreme, nearby);
   }
   SEGSAddStopAnchor(buy ? iLow(sym, PERIOD_D1, 1) : iHigh(sym, PERIOD_D1, 1), buy, entryPrice, boundary, proximity, extreme, nearby);
   SEGSAddStopAnchor(buy ? iLow(sym, PERIOD_W1, 1) : iHigh(sym, PERIOD_W1, 1), buy, entryPrice, boundary, proximity, extreme, nearby);
   // Global structure belongs to this chart symbol only.
   if(sym == _Symbol)
   {
      SEGSAddStopAnchor(buy ? g_recentSwingLow : g_recentSwingHigh, buy, entryPrice, boundary, proximity, extreme, nearby);
      SEGSAddStopAnchor(buy ? g_recentSupport : g_recentResistance, buy, entryPrice, boundary, proximity, extreme, nearby);
   }
   ENUM_SEGS_SL_STYLE style = InpStructuralStopStyle;
   if(preferMultiDay && style == SL_STYLE_AUTO_DUAL) style = SL_STYLE_MULTI_DAY;
   double anchor = 0.0;
   if(style == SL_STYLE_ORDER_BLOCK) anchor = boundary;
   else if(style == SL_STYLE_MULTI_DAY) anchor = extreme;
   else anchor = validOB ? (nearby > 0.0 ? nearby : boundary) : extreme;
   // No fabricated structural stop: caller must defer when the required anchor is absent.
   if(anchor <= 0.0) return 0.0;
   double stop = buy ? anchor - buffer : anchor + buffer;
   MqlTick quote;
   if(!SymbolInfoTick(sym, quote)) return 0.0;
   double distance = MathMax((double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt, tick) + 2.0 * tick;
   if(buy) stop = MathMin(stop, MathMin(entryPrice, quote.bid) - distance);
   else stop = MathMax(stop, MathMax(entryPrice, quote.ask) + distance);
   // Round away from invalidation, never towards the OB or broker boundary.
   stop = (buy ? MathFloor(stop / tick) : MathCeil(stop / tick)) * tick;
   return stop > 0.0 ? NormalizeDouble(stop, digits) : 0.0;
}


int main(){
 lows[0][1]=98.8;lows[0][2]=90;highs[0][1]=101.2;highs[0][2]=110;
 // Nearby swing must survive presence of a more distant weekly/daily extreme.
 double v=GetSafestStructuralStopLoss("TEST","BUY",100,99,99.7,1);
 assert(std::abs(v-98.6)<1e-8);
 v=GetSafestStructuralStopLoss("TEST","SELL",100,100.3,101,1);
 assert(std::abs(v-101.4)<1e-8);
 InpStructuralStopStyle=SL_STYLE_ORDER_BLOCK;
 assert(std::abs(GetSafestStructuralStopLoss("TEST","BUY",100,99,99.7,1)-98.8)<1e-8);
 assert(std::abs(GetSafestStructuralStopLoss("TEST","SELL",100,100.3,101,1)-101.2)<1e-8);
 assert(GetSafestStructuralStopLoss("TEST","BUY",100,0,0,1)==0);
 InpStructuralStopStyle=SL_STYLE_MULTI_DAY;
 assert(std::abs(GetSafestStructuralStopLoss("TEST","BUY",100,99,99.7,1)-89.8)<1e-8);
 assert(std::abs(GetSafestStructuralStopLoss("TEST","SELL",100,100.3,101,1)-110.2)<1e-8);
 InpStructuralStopStyle=SL_STYLE_AUTO_DUAL;
 point=0;assert(GetSafestStructuralStopLoss("TEST","BUY",100,99,99.7,1)==0);point=.01;
 tick=0;assert(GetSafestStructuralStopLoss("TEST","BUY",100,99,99.7,1)==0);tick=.25;
 stops=250;
 v=GetSafestStructuralStopLoss("TEST","BUY",100,99,99.7,1);
 assert(v<=bid-stops*point-2*tick&&v<99&&std::abs(v/tick-std::round(v/tick))<1e-8);
 v=GetSafestStructuralStopLoss("TEST","SELL",100,100.3,101,1);
 assert(v>=ask+stops*point+2*tick&&v>101&&std::abs(v/tick-std::round(v/tick))<1e-8);
 assert(GetSafestStructuralStopLoss("TEST","INVALID",100,99,101,1)==0);
 std::cout<<"12 structural-stop assertions passed\n";
}
