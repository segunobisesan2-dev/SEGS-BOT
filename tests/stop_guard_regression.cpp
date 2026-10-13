#include <cassert>
#include <string>
bool g_hasViableEntry; std::string g_blockReason;
void check_0(double g_staticSL) {
if(g_staticSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
}
void check_1(double candSL) {
if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
}
void check_2(double candSL_H1) {
if(candSL_H1 <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
}
void check_3(double candSL) {
if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
}
void check_4(double candSL) {
if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
}
void check_5(double candSL) {
if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
}
void check_6(double candSL) {
if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
}
int main() {
g_hasViableEntry=true;g_blockReason="";check_0(0.0);assert(!g_hasViableEntry && g_blockReason=="WAITING FOR STRUCTURAL HISTORY");g_hasViableEntry=true;g_blockReason="";check_0(1.0);assert(g_hasViableEntry && g_blockReason.empty());
g_hasViableEntry=true;g_blockReason="";check_1(0.0);assert(!g_hasViableEntry && g_blockReason=="WAITING FOR STRUCTURAL HISTORY");g_hasViableEntry=true;g_blockReason="";check_1(1.0);assert(g_hasViableEntry && g_blockReason.empty());
g_hasViableEntry=true;g_blockReason="";check_2(0.0);assert(!g_hasViableEntry && g_blockReason=="WAITING FOR STRUCTURAL HISTORY");g_hasViableEntry=true;g_blockReason="";check_2(1.0);assert(g_hasViableEntry && g_blockReason.empty());
g_hasViableEntry=true;g_blockReason="";check_3(0.0);assert(!g_hasViableEntry && g_blockReason=="WAITING FOR STRUCTURAL HISTORY");g_hasViableEntry=true;g_blockReason="";check_3(1.0);assert(g_hasViableEntry && g_blockReason.empty());
g_hasViableEntry=true;g_blockReason="";check_4(0.0);assert(!g_hasViableEntry && g_blockReason=="WAITING FOR STRUCTURAL HISTORY");g_hasViableEntry=true;g_blockReason="";check_4(1.0);assert(g_hasViableEntry && g_blockReason.empty());
g_hasViableEntry=true;g_blockReason="";check_5(0.0);assert(!g_hasViableEntry && g_blockReason=="WAITING FOR STRUCTURAL HISTORY");g_hasViableEntry=true;g_blockReason="";check_5(1.0);assert(g_hasViableEntry && g_blockReason.empty());
g_hasViableEntry=true;g_blockReason="";check_6(0.0);assert(!g_hasViableEntry && g_blockReason=="WAITING FOR STRUCTURAL HISTORY");g_hasViableEntry=true;g_blockReason="";check_6(1.0);assert(g_hasViableEntry && g_blockReason.empty());
}
