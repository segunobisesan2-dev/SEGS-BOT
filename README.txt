# SEGS-BOT — full EA v3.77

The latest source is `SEGS_Trade_Manager_Pro_v3.77.mq5`, based on the uploaded v3.76. Read `public/SEGS_v3.77_RELEASE_NOTES.txt` for installation and restart checks.

This release fixes wrong-array reads on H1 fallback zones, adds periodic state saving and shutdown visual preservation, and implements closed-candle supply/demand conversion followed by a separate confirmed retest. Converted blocks retain normal strategy and risk gates. MT5 itself restores saved profile attachments; terminal shutdown/crashes cannot be prevented by an EA.

Validation: `python tests/verify_source.py` and `python tests/role_reversal_test.py` pass. Native MetaEditor compilation and MT5 restart tests remain required. Compatibility `.mq5` downloads and embedded TypeScript source are synchronized to v3.77.

The earlier release notes below describe retained behavior and prior validation.

# SEGS-BOT — full EA v3.75

[Download the full MT5 source](https://raw.githubusercontent.com/segunobisesan2-dev/SEGS-BOT/main/SEGS_Trade_Manager_Pro_v3.75.mq5)

Download all files using **Code → Download ZIP**. Install the v3.75 source, compile with F7 in MetaEditor, then validate on demo. No native MT5 compiler or runtime was available in this environment; successful native compilation and permanent resolution of detachment are not claimed.

## Stop calibration requested from the chart

Default: `SL_STYLE_AUTO_DUAL`. BUY stops invalidate the entered demand block below its floor; SELL stops invalidate the entered supply block above its ceiling. When a D1/H4 pivot, previous day/week level, or structural support/resistance lies just beyond that boundary within `InpDualProximityATR`, dual mode anchors beyond that level instead. The default structural buffer is max(0.20 × H1 ATR, 3 trade ticks). Broker distance and outward tick rounding may move the stop farther away.

Caller swing preferences cannot discard a valid entered block. Explicit multi-day mode also keeps stops outside the entered zone. With no entered block, dual mode uses available multi-day structure. Missing anchors defer execution. No absolute instrument price is embedded.

`SL_STYLE_ACTIVE_ORDER_BLOCK` remains an optional mode for nearest active M30/H1 zone calibration and trailing, with its own buffer settings. It is not the default. Existing protected positions retain their broker stops; dual selection applies to new entries and does not retroactively widen existing stops.

### System setting across charts

On **one chart**, set `InpPublishStopSettingsToAllCharts=true` and select the stop style, buffer, maximum distance, and `InpTrailActiveOrderBlock` preference in Inputs. This publishes the policy to account-scoped terminal global variables. All charts load that policy on the next ready event, normally within one second. Keep `InpPublishStopSettingsToAllCharts=false` on other charts, so they consume the same policy. v3.75 uses the new `SEGS_SL_V2_<account>_*` namespace, initialized from Inputs once, so an older stored active-zone default cannot silently override the new dual default. Republish custom settings from one chart after upgrading all charts. The policy persists across terminal restart. It applies within this terminal/account.

`InpTrailActiveOrderBlock=true` tightens existing advisor-position stops to the active zone. It never widens an existing stop. A profitable BUY stop may be above the original entry; a profitable SELL stop may be below it. Existing manual positions are not included in this new trailing runner. Normal existing manual-management behavior is retained.

When an unfilled old entry is on the wrong side of the new active-zone stop, the old plan is disarmed and a current-price preview shown. A fresh normal strategy confirmation is required before execution. It does not convert a stale signal into an immediate market entry.

## Attachment hardening and diagnostics

- Market callbacks wait for point/tick metadata, synchronized M1–W1 series, minimum history, allocated handles and calculated indicator data. Initialization does not scan or trade. Missing data retries without returning INIT_FAILED or calling ExpertRemove.
- Full scans throttle to one second; explicit forced scans remain immediate.
- Clamp OB ATR/swing/lookback inputs to safe scan ranges; guard ATR array bounds and volume-leg allocation.
- Bound cached nearest-zone indexes against actual current arrays and reset indexes when rebuilding zones.
- Do not cache a scan as complete before history copying succeeds, so incomplete scans retry.
- Chart custom events and trade transactions cannot access unready startup state.
- `SEGS_PHASE_<ChartID>` terminal globals record the last runner phase: 1 position protection, 2 liquidity/OB scan, 3 strategy scan, 4 timer UI drawing. Existing `[SEGS DEINIT]` logs include reason and last error.

The actual reported detachment has not been reproduced, and no Experts/Journal error was supplied. Fatal runtime failures cannot be caught by MQL5 exception handling. The code hardens identified paths; it cannot promise that every possible broker/data/runtime failure has been eliminated.

## Verification performed

24 assertions against the extracted current structural-stop functions compiled using g++ with `-std=c++17 -Wall -Wextra -Werror`, using stubbed MT5 APIs. Includes active demand/supply, invalidated zones, missing nearby active zones, zero metadata, tick rounding, broker distance, original dual modes, and a profitable stop above original BUY entry. This is **not native MQL5 compilation**.

Seven corrected stop-guard statements retain their regression harness. Source default-parameter and lexical-integrity checks pass. All twelve `.mq5` copies and the decoded TypeScript string are identical. Versioned 3.50/3.71 filenames are compatibility copies of 3.75, not old implementations.

## Required MT5 validation

1. Remove the older EA instance from the chart, replace its source with v3.75, and compile with F7. Verify the file attached is the newly compiled v3.75 executable.
2. On demo, first disable Algo Trading and attach to GBPUSD, XAUUSD, AUDUSD, USDJPY and a chart still loading history. Wait for readiness and test timeframe changes/restart.
3. Publish the system stop settings from one chart. Check active zones and both BUY/SELL protection. Enable demo Algo Trading to exercise trailing modifications.
4. If detachment remains, provide the Experts and Journal entries at the failure time, including any fatal error, `[SEGS DEINIT]`, and `SEGS_PHASE_<ChartID>` value (F3 terminal global variables).

## Expired-signal recovery (v3.75)

Expired, cancelled, and invalidated pending setups reset to SCANNING when no advisor positions remain. Clears stale flag, signal identity, entry/SL/TP, old cancellation coordinates, cached scan time and active snapshot. Recovery forces a fresh scan; a newly expired candidate gets one immediate retry per engine cycle. Existing positions and executed-signal deduplication records are preserved. Automatic execution remains subject to viable setup, market gates, permissions, and configured limits. Native MT5 verification remains required.

Expiry regression assertions verify clearing stale state, immediate scan eligibility, repeat-reset idempotency and preservation of actual open positions using the extracted reset function.

## v3.75 validation limits

Regression checks include six new cases covering caller preference, both entry-zone boundaries in multi-day mode, and completed H4 bar-1 pivot selection. Startup source assertions check deferred execution, success return, explicit history requests, monetary tick guards, pip guards and visibility synchronization. C++ tests execute extracted stop functions with stubbed broker APIs; lexical/source checks do not establish native MQL5 compilation. There is no TypeScript project or compiler in this workspace, so TypeScript verification checks the decoded source string only.

Trade calls are deliberately deferred until readiness; this is a lifecycle safeguard, not a claim that MQL5 universally prohibits all trade calls from OnInit. Actual permanent detachment resolution requires MT5 Experts/Journal evidence and native demo validation.

## v3.75 compile correction

Removed the obsolete fixed-price GBPUSD target branch and its two undeclared `isGBPUSD` references (reported at lines 7159 and 7200). All symbols use structural candidate levels with risk/ATR fallbacks; optional opposing-liquidity TP3 mapping also applies to GBPUSD. Prior dual-stop and startup safeguards are retained. Native MetaEditor compilation remains required.
