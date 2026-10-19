#include <cassert>
// Scope guard releases the scan lock on every normal return path.
bool g_strategyScanRunning = false;
class SEGSStrategyScanGuard
{
private:
   bool m_entered;
public:
   SEGSStrategyScanGuard()
   {
      m_entered = !g_strategyScanRunning;
      if(m_entered) g_strategyScanRunning = true;
   }
   ~SEGSStrategyScanGuard()
   {
      if(m_entered) g_strategyScanRunning = false;
   }
   bool Entered() { return m_entered; }
};


int runs = 0;
void scan(int depth, bool earlyReturn)
{
   SEGSStrategyScanGuard guard;
   if(!guard.Entered()) return;
   ++runs;
   assert(g_strategyScanRunning);
   if(depth) scan(depth - 1, false);
   assert(g_strategyScanRunning); // rejected nested scan must not unlock outer scan
   if(earlyReturn) return;
}
int main()
{
   assert(!g_strategyScanRunning);
   scan(100, true);
   assert(runs == 1 && !g_strategyScanRunning);
   scan(100, false);
   assert(runs == 2 && !g_strategyScanRunning);
   for(int i=0;i<1000;++i) scan(10, i%2==0);
   assert(runs == 1002 && !g_strategyScanRunning);
}
