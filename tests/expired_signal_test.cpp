#include <string>
#include <cassert>
using string=std::string;
bool g_isSignalExpired = false;
bool g_hasViableEntry = false;
bool g_currentTradeTaken = false;
string g_currentSignalID = "";
string g_currentAdvisedAction = "NONE";
string g_plannedAction = "NONE";
double g_staticEntryPrice = 0.0;
double g_staticSL = 0.0;
double g_staticTP1 = 0.0;
double g_staticTP2 = 0.0;
double g_staticTP3 = 0.0;
double g_staticTP4 = 0.0;
double g_signalTriggerTime = 0;
double g_lastSignalConfirmationTime = 0;
bool g_signalGeneratedWhileAdvisorEnabled = false;
double g_lastAdviceScanBarTime = 0;
double g_lastCancelledEntryPrice = 0.0;
double g_lastCancelledEntrySL = 0.0;
string g_lastCancelledEntryAction = "NONE";
string g_obSignalDirection = "NONE";
double g_obSignalLow = 0.0;
double g_obSignalHigh = 0.0;
string g_setupState = "SCANNING";
double g_setupQuality = 0;
string g_blockReason = "SCANNING FOR NEW OPPORTUNITY";
string g_primaryRejectionReason = "";
string g_signalStatusLabel = "SCANNING FOR NEW OPPORTUNITY";
int openPositions=0,clears=0,deletes=0;
int CountOpenAdvisorTradesForSymbol(string){return openPositions;}
void ClearActiveSignalSnapshot(string){clears++;}
void DeleteTradeAdviceLines(){deletes++;}
void PrintFormat(const char*,string){}
bool SEGSResetExpiredSetup(string sym)
{
   if(CountOpenAdvisorTradesForSymbol(sym) > 0) return false;
   if(!g_isSignalExpired && g_setupState != "EXPIRED" && g_setupState != "INVALIDATED" && g_setupState != "CANCELLED") return false;
   g_isSignalExpired = false;
   g_hasViableEntry = false;
   g_currentTradeTaken = false;
   g_currentSignalID = "";
   g_currentAdvisedAction = "NONE";
   g_plannedAction = "NONE";
   g_staticEntryPrice = 0.0; g_staticSL = 0.0;
   g_staticTP1 = 0.0; g_staticTP2 = 0.0; g_staticTP3 = 0.0; g_staticTP4 = 0.0;
   g_signalTriggerTime = 0; g_lastSignalConfirmationTime = 0;
   g_signalGeneratedWhileAdvisorEnabled = false;
   g_lastAdviceScanBarTime = 0;
   g_lastCancelledEntryPrice = 0.0; g_lastCancelledEntrySL = 0.0;
   g_lastCancelledEntryAction = "NONE";
   g_obSignalDirection = "NONE"; g_obSignalLow = 0.0; g_obSignalHigh = 0.0;
   g_setupState = "SCANNING";
   g_setupQuality = 0;
   g_blockReason = "SCANNING FOR NEW OPPORTUNITY";
   g_primaryRejectionReason = "";
   g_signalStatusLabel = "SCANNING FOR NEW OPPORTUNITY";
   ClearActiveSignalSnapshot(sym);
   DeleteTradeAdviceLines();
   // Executed-signal history and account execution locks are deliberately retained.
   PrintFormat("[SEGS SIGNAL RESET] %s expired setup cleared; fresh opportunity scan enabled", sym);
   return true;
}
int main(){
 g_isSignalExpired=true;g_setupState="EXPIRED";g_currentSignalID="STALE_USDCHF";g_staticEntryPrice=.8326;g_currentTradeTaken=true;
 assert(SEGSResetExpiredSetup("USDCHF"));assert(!g_isSignalExpired&&!g_currentTradeTaken&&!g_hasViableEntry);
 assert(g_setupState=="SCANNING"&&g_currentSignalID.empty()&&g_staticEntryPrice==0&&g_lastAdviceScanBarTime==0);
 assert(clears==1&&deletes==1);assert(!SEGSResetExpiredSetup("USDCHF"));
 g_isSignalExpired=true;g_setupState="EXPIRED";g_currentSignalID="LIVE_POSITION";openPositions=1;
 assert(!SEGSResetExpiredSetup("USDCHF"));assert(g_isSignalExpired&&g_currentSignalID=="LIVE_POSITION"&&clears==1);
 openPositions=0;g_isSignalExpired=false;g_setupState="CANCELLED";
 assert(SEGSResetExpiredSetup("USDCHF"));assert(g_setupState=="SCANNING"&&g_currentSignalID.empty());
}
