#include <cassert>
#include <cmath>
#include <string>
#include <vector>
using string=std::string;
struct M30OrderBlock { bool bullish; double high,low; bool invalidated; };
struct MqlTick { double bid,ask; };
bool g_hasViableEntry=true,g_isSignalExpired=false,g_currentTradeTaken=false;
string g_currentSignalID="plan",g_setupState="WATCHING",g_currentAdvisedAction="BUY";
double g_staticEntryPrice=100,g_staticSL=90;
std::vector<M30OrderBlock> g_orderBlocks,g_h1OrderBlocks;
MqlTick live={101,101.02};
bool quoteOK=true; double tickSize=.01;
const int SYMBOL_TRADE_TICK_SIZE=1;
bool SymbolInfoTick(string, MqlTick &q) { q=live; return quoteOK; }
double SymbolInfoDouble(string,int) { return tickSize; }
bool MathIsValidNumber(double v) {return std::isfinite(v);}
double MathAbs(double v) {return std::abs(v);}
int ArraySize(const std::vector<M30OrderBlock> &v) {return (int)v.size();}
bool SEGSPriceInPlannedBlock(const M30OrderBlock &ob, bool buy, double entry, double price)
{
   return !ob.invalidated && ob.bullish == buy &&
          MathIsValidNumber(ob.low) && MathIsValidNumber(ob.high) &&
          ob.low > 0.0 && ob.high > ob.low &&
          entry >= ob.low && entry <= ob.high && price >= ob.low && price <= ob.high;
}

bool SEGSPlannedEntryTouched(string sym)
{
   if(!g_hasViableEntry || g_isSignalExpired || g_currentTradeTaken ||
      g_currentSignalID == "" ||
      (g_setupState != "WATCHING" && g_setupState != "READY" && g_setupState != "TRIGGERED") ||
      (g_currentAdvisedAction != "BUY" && g_currentAdvisedAction != "SELL")) return false;
   double entry = g_staticEntryPrice;
   if(!MathIsValidNumber(entry) || entry <= 0.0 ||
      !MathIsValidNumber(g_staticSL) || g_staticSL <= 0.0) return false;
   MqlTick quote;
   if(!SymbolInfoTick(sym, quote) || !MathIsValidNumber(quote.ask) ||
      !MathIsValidNumber(quote.bid) || quote.bid <= 0.0 || quote.ask < quote.bid) return false;
   bool buy = (g_currentAdvisedAction == "BUY");
   double price = buy ? quote.ask : quote.bid;
   if((buy && price <= g_staticSL) || (!buy && price >= g_staticSL)) return false;
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(!MathIsValidNumber(tick) || tick <= 0.0) return false;
   // Half a trade tick handles rounding; no ATR/pip proximity allowance.
   if(MathAbs(price - entry) <= tick * 0.5) return true;
   for(int k = 0; k < ArraySize(g_orderBlocks); k++)
      if(SEGSPriceInPlannedBlock(g_orderBlocks[k], buy, entry, price)) return true;
   for(int k = 0; k < ArraySize(g_h1OrderBlocks); k++)
      if(SEGSPriceInPlannedBlock(g_h1OrderBlocks[k], buy, entry, price)) return true;
   return false;
}


int main() {
 auto touched=[](){return SEGSPlannedEntryTouched("TEST");};
 assert(!touched()); // proximity alone
 g_setupState="TRIGGERED"; assert(!touched());
 live={99.98,100}; assert(touched()); // BUY Ask contact
 live={100,100.02}; assert(!touched()); // Bid contact alone cannot fill BUY
 g_orderBlocks={{true,102,99,false}}; assert(touched());
 live={101,101.02}; assert(touched()); // inside containing demand
 g_staticEntryPrice=98; assert(!touched()); // unrelated block
 g_staticEntryPrice=100; g_orderBlocks[0].invalidated=true; assert(!touched());
 g_orderBlocks[0].invalidated=false;g_orderBlocks[0].bullish=false;assert(!touched());
 g_orderBlocks.clear();g_h1OrderBlocks={{true,102,99,false}};assert(touched());
 live={102.01,102.03};assert(!touched()); // outside boundary
 g_currentAdvisedAction="SELL";g_staticSL=110;
 g_h1OrderBlocks={{false,102,99,false}};live={101,101.02};assert(touched());
 live={98.98,99};assert(!touched()); // Ask inside is insufficient for SELL
 live={100,100.02};g_h1OrderBlocks.clear();assert(touched());
 live={99.98,100};assert(!touched()); // SELL uses Bid
 live={100,100.02};g_isSignalExpired=true;assert(!touched());g_isSignalExpired=false;
 g_currentTradeTaken=true;assert(!touched());g_currentTradeTaken=false;
 g_hasViableEntry=false;assert(!touched());g_hasViableEntry=true;
 g_setupState="CANCELLED";assert(!touched());g_setupState="WATCHING";
 g_currentSignalID="";assert(!touched());g_currentSignalID="plan";
 quoteOK=false;assert(!touched());quoteOK=true;
 tickSize=0;assert(!touched());tickSize=.01;
 g_staticSL=100;assert(!touched());g_staticSL=110;
 live={0,0};assert(!touched());
}
