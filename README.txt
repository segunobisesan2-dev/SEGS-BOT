SEGS MT5 repair v3.71 — validation and installation

This is a corrected source release candidate. Native MetaEditor compilation,
Strategy Tester testing, and live MT5 chart attachment have NOT been performed.
MetaEditor/MT5/Wine are absent in this environment. No .ex5 is supplied.
The precise runtime detachment cause cannot be confirmed without Experts/Journal logs.

Verified changes
- OnInit defers market processing and all position assignment until tick/timer readiness.
- One-second timer; startup tolerates missing symbol metadata; failed indicator handles retry.
- Symbol-derived pip fallback for display; invalid monetary metadata returns unavailable (0),
  instead of inventing a tick value. Trade execution requires real point/tick data.
- Direct EMA rejects zero/negative periods; partial-close volume step is guarded.
- Deinit logs reason, last error, symbol, chart ID; timer and indicator handles are released.
- Order-block, multi-day, auto-dual styles selectable with InpStructuralStopStyle.
- Completed D1 bars 1–5; confirmed H4 pivots centered at bars 2–24 (bar 1 participates
  as the completed confirmation neighbor); PDL/PDH, PWL/PWH, chart support/resistance.
- Auto-dual considers nearby anchors independently of distant extremes, so a distant
  weekly low/high cannot hide a nearby pivot. Buffers and proximity use ATR/tick size.
- Final execution stop determined before risk sizing; all advisor legs use that stop.
- BUY stops round downward and SELL stops upward, outside live broker stop distance.
- No required structural anchor: trade deferred. Invalid-stop retry no longer opens
  a market order with zero SL/TP. Brokers requiring naked entry will defer these trades.
- Received dashboard synchronization persists per-chart visibility; hidden objects clear.

Verification actually performed
- 12 assertions against the actual extracted structural stop function in a C++ harness,
  with stubbed MT5 APIs: BUY/SELL, explicit styles, nearby and distant anchors,
  missing point/tick, broker distance, coarse tick rounding, invalid direction.
- Harness compiled using g++ -std=c++17 -Wall -Wextra -Werror.
- Static lifecycle, stop-before-sizing, no 4.29 buffer, and balanced lexical delimiters.
- All packaged .mq5 files are byte-identical; TypeScript DECODED string has the same bytes.
  A TypeScript wrapper cannot itself be byte-identical to MQL5 source. Existing project
  copies and TypeScript application tests were not available and were not verified.
- Canonical source SHA256: 5367b6f78ed1529f36e72b743a0f8d16eb802e6b7a50662e24efbae089a3de82

Installation / remaining native validation
1. Copy SEGS_Trade_Manager_Pro_v3.71.mq5 into MT5 MQL5/Experts.
2. Open it in MetaEditor and compile with F7. Verify the compiler result; resolve any
   reported errors before attaching. Do not retain an old .ex5 under the new filename.
3. Select SL_STYLE_AUTO_DUAL (default). Buffer ATR default 0.20; proximity ATR 0.85.
4. Test on a demo account with Algo Trading disabled initially: AUDUSD, GBPUSD, XAUUSD;
   new charts with history still loading, terminal restart, timeframe change, and H
   across several charts. Enable demo trading and verify both directions and actual risk.
5. If attachment still fails, provide Experts/Journal output including [SEGS DEINIT].

Scope
Original supplied code identifies itself as v3.70; patched source identifies as v3.71.
The v3.50 filenames in this ZIP are compatibility copies of the v3.71 source.
Advisor entry protection is fixed centrally. Existing management of manually opened
positions, legacy persisted targets, and trailing/breakeven behavior is retained.
This audit does not certify every path in the original 18,000-line EA.

Compiler corrections incorporated into the full EA:
- Seven malformed structural-stop guards now check only their SL variable.
- RunAdvisorStrategyEngine defaults are declared once in its prototype:
  forceScan=false, allowAutoTrade=false. The definition repeats no defaults.
- All live tick/timer and user-triggered trading calls pass allowAutoTrade=true explicitly.
Native MetaEditor recompilation is still required to confirm the compiler result.
