# SEGS-BOT — corrected v3.75 source

## Entry-block wick stops

The default is now `SL_STYLE_ORDER_BLOCK`: BUY stop at the entered demand candle's full wick low, SELL stop at the entered supply candle's full wick high, rounded outward to the broker's trade tick. No ATR buffer or multi-day extension applies in this mode. Blocks now retain full wick bounds even when a previous body-only input was selected. Missing block coordinates or broker minimum-distance conflicts defer entry instead of inventing a wider stop. Final stop selection occurs before lot sizing.

Stop-policy persistence uses `SEGS_SL_V3_<account>_*` so the former persisted dual default cannot silently override the corrected default. Other stop styles remain explicit options. Upgrade every chart; mixed old/new versions do not share this policy namespace. This patch does not retroactively move already open trades to a guessed entry block.

## Two independent sets per symbol

The scanner no longer locks onto the first open trade's direction or requires a bounce at that trade's entry before looking for another setup. A fresh viable signal can open a second set, including a SELL while a BUY remains open on a hedging account. The configured per-symbol limit is clamped to 1–2 sets. Portfolio, risk, permission, viability and broker checks remain in force.

Signal matching now requires the specific signal tag, rather than treating every advisor position as the same signal. Sets are counted by signal ID instead of fills within five seconds. Capacity and duplicate checks repeat under the account execution lock. Untagged legacy advisor positions conservatively count separately. Netting accounts cannot hold these independent opposing sets; an additional set is deferred while positions remain open there.

## Startup and USDCHF

Existing deferred startup and synchronized-history/indicator guards remain. Readiness now resets after lost quotes/history/indicator readiness; OB array growth checks allocation before writing. Diagnostic phase globals and deinitialization logs remain available.

**The reported USDCHF terminal crash/detachment has not been reproduced.** These guards address identified failure paths, but permanent crash resolution is unverified without native MT5 reproduction and the Experts/Journal error around the failure. No MetaEditor compiler, Wine or MT5 runtime is installed in this workspace.

## Verification

Run:

```
python tests/verify_source.py
python tests/trade_sets_test.py
```

The first command checks synchronization across all 12 MQL5 copies and the embedded TypeScript source, lexical integrity, and compiles/runs extracted C++ stop, stop-guard and expired-signal harnesses. Stop tests include 27 assertions, including wick boundaries, ATR independence, and deferral on broker-distance conflicts. The second compiles/runs the extracted set counter with eight assertions covering multiple legs, distinct simultaneous sets, other symbols, manual positions, partial closure and untagged legacy positions. These use stubbed broker APIs and do not establish native MQL5 compilation or runtime correctness.

## MT5 acceptance checks

1. Compile `SEGS_Trade_Manager_Pro_v3.75.mq5` with F7 in MetaEditor and attach that newly compiled executable on demo. Historical filenames are synchronized compatibility copies of the same implementation.
2. Confirm `InpStructuralStopStyle=SL_STYLE_ORDER_BLOCK` and `InpMaxSetsPerSymbol=2`. If this terminal already published V3 settings, publish the corrected selection from one chart using `InpPublishStopSettingsToAllCharts=true`.
3. Verify BUY/SELL stops against the actual entry candle wicks. A broker-distance conflict must defer entry.
4. With one set open, verify the advisor continues scanning; a distinct viable opposite setup can open a second set on a hedging account. Verify no third set, no repeated execution of the same signal, and independent ticket management through partial closures and restart.
5. Attach on USDCHF with history still loading, change timeframes, and restart MT5. If it crashes/detaches, collect Experts and Journal entries, the fatal runtime message, `[SEGS DEINIT]`, and `SEGS_PHASE_<ChartID>` (F3 terminal globals). That evidence is needed to identify the remaining failure precisely.
