 SEGS-BOT — full EA v3.72

[Download the full MT5 source](https://raw.githubusercontent.com/segunobisesan2-dev/SEGS-BOT/main/SEGS_Trade_Manager_Pro_v3.72.mq5)

Download all files using **Code → Download ZIP**. Install the v3.72 source, compile with F7 in MetaEditor, then validate on demo. No native MT5 compiler or runtime was available in this environment; successful native compilation and permanent resolution of detachment are not claimed.

 Stop calibration requested from the chart

Default: `SL_STYLE_ACTIVE_ORDER_BLOCK`. Select the nearest non-invalidated, same-direction M30/H1 order block whose floor is below the BUY market or ceiling above the SELL market, within the configured ATR distance. BUY SL is below the active demand floor; SELL SL is above the active supply ceiling. No absolute GBPUSD/XAUUSD price is embedded.

The default buffer is max(0.05 × H1 ATR, 3 trade ticks). Broker minimum stop distance can require a larger separation. `InpActiveOBMaxDistanceATR` defaults to 3.0. Missing active zones defer entries; existing protection is retained.

 System setting across charts

On **one chart**, set `InpPublishStopSettingsToAllCharts=true` and select the stop style, buffer, maximum distance, and `InpTrailActiveOrderBlock` preference in Inputs. This publishes the policy to account-scoped terminal global variables. All charts load that policy on the next ready event, normally within one second. Keep `InpPublishStopSettingsToAllCharts=false` on other charts, so they consume the same policy. Initial attachment creates the default policy if absent. The policy persists across terminal restart. It applies within this terminal/account.

`InpTrailActiveOrderBlock=true` tightens existing advisor-position stops to the active zone. It never widens an existing stop. A profitable BUY stop may be above the original entry; a profitable SELL stop may be below it. Existing manual positions are not included in this new trailing runner. Normal existing manual-management behavior is retained.

When an unfilled old entry is on the wrong side of the new active-zone stop, the old plan is disarmed and a current-price preview shown. A fresh normal strategy confirmation is required before execution. It does not convert a stale signal into an immediate market entry.

 Attachment hardening and diagnostics

- Market callbacks wait for point/tick metadata, synchronized M1–W1 series, minimum history, allocated handles and calculated indicator data. Initialization does not scan or trade. Missing data retries without returning INIT_FAILED or calling ExpertRemove.
- Full scans throttle to one second; explicit forced scans remain immediate.
- Clamp OB ATR/swing/lookback inputs to safe scan ranges; guard ATR array bounds and volume-leg allocation.
- Bound cached nearest-zone indexes against actual current arrays and reset indexes when rebuilding zones.
- Do not cache a scan as complete before history copying succeeds, so incomplete scans retry.
- Chart custom events and trade transactions cannot access unready startup state.
- `SEGS_PHASE_<ChartID>` terminal globals record the last runner phase: 1 position protection, 2 liquidity/OB scan, 3 strategy scan, 4 timer UI drawing. Existing `[SEGS DEINIT]` logs include reason and last error.

The actual reported detachment has not been reproduced, and no Experts/Journal error was supplied. Fatal runtime failures cannot be caught by MQL5 exception handling. The code hardens identified paths; it cannot promise that every possible broker/data/runtime failure has been eliminated.

 Verification performed

18 assertions against the extracted current structural-stop functions compiled using g++ with `-std=c++17 -Wall -Wextra -Werror`, using stubbed MT5 APIs. Includes active demand/supply, invalidated zones, missing nearby active zones, zero metadata, tick rounding, broker distance, original dual modes, and a profitable stop above original BUY entry. This is **not native MQL5 compilation**.

Seven corrected stop-guard statements retain their regression harness. Source default-parameter and lexical-integrity checks pass. All six `.mq5` copies and the decoded TypeScript string are identical. Versioned 3.50/3.71 filenames are compatibility copies of 3.72, not old implementations.

 Required MT5 validation

1. Remove the older EA instance from the chart, replace its source with v3.72, and compile with F7. Verify the file attached is the newly compiled v3.72 executable.
2. On demo, first disable Algo Trading and attach to GBPUSD, XAUUSD, AUDUSD, USDJPY and a chart still loading history. Wait for readiness and test timeframe changes/restart.
3. Publish the system stop settings from one chart. Check active zones and both BUY/SELL protection. Enable demo Algo Trading to exercise trailing modifications.
4. If detachment remains, provide the Experts and Journal entries at the failure time, including any fatal error, `[SEGS DEINIT]`, and `SEGS_PHASE_<ChartID>` value (F3 terminal global variables).
