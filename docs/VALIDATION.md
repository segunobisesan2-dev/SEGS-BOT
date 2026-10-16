# Validation results and remaining MT5 checks

All checks below ran in this workspace. MetaEditor, Wine and an MT5 terminal are unavailable. **Native MQL5 compilation was not performed; no EX5 is delivered.** No broker connection, historical tick files, USDCHF screenshot or Experts/Journal incident logs were supplied.

| Command | Actual result |
|---|---|
| `python tests/test_precision.py` | 102 assertions passed against the EA's extracted state-machine, response-classification and overlap/selection predicates; integration source assertions passed |
| `python tests/test_precision_execution.py` | 124 assertions passed against the actual extracted PESubmit function with broker stubs |
| `python tests/test_precision_reconciliation.py` | 34 assertions passed against actual PEReconcile, PECancelAdvisorOrders and PETradeEvent functions with order/deal/history stubs |
| `python tests/test_precision_risk.py` | 24 assertions passed against actual PERequestCheck with symbol, margin, profit and OrderCheck stubs |
| `python tests/verify_source.py` | Source synchronization, existing lexical/startup/default checks, current structural-stop function identity, 24 structural-stop assertions, and existing stop-guard and expired-signal harnesses |

284 new executable assertions in total. Extracted functions were compiled with g++ C++17 and `-Wall -Wextra -Werror`. C++ type/API adapters are test scaffolding, not native MQL5 compilation or a replacement engine. In request-risk tests PEFinalGate is stubbed: session/spread/shock policy itself still needs MT5 runtime validation. Tests extract production function bodies each run, so they do not silently exercise an obsolete copy.

## Coverage

| Scenario | Check performed | Remaining MT5 evidence |
|---|---|---|
| BUY/SELL direct touch, correct approach, attach inside band, repeated quotes | Actual state-function assertions | Real tick execution/spread |
| Breakout without retest; wick without breakout close | Actual state-function assertions | Real symbol candles |
| Retest touch; rejection close; no breakout-wick reuse | Actual state-function assertions | Real ticks across confirmation boundary |
| Invalidation before entry; simultaneous touch/breach; gap past level | Actual state-function assertions | Real gaps and broker protection |
| Close invalidation while retaining protective SL | State assertions; submitted requests contain SL | Intrabar broker stop behaviour |
| Expired setup and repeated submissions | State/submission assertions | Server-time boundaries |
| Overlapping/opposing zones and deterministic ordering | Actual overlap/priority predicates and monitor source assertions | Full monitor with simultaneous events |
| Pending cancellation success/failure/in-flight market request | Actual cancellation function with stubs | Broker freeze/race restrictions |
| Rejected, partial, placed, timeout, connection and unknown results | Actual submission/event/reconciliation functions with stubs | Actual transaction ordering/fill prices |
| Restart with exposure/unknown request | Submission/reconciliation checks with existing exposure/history | Actual restart and journal replay |
| Symbol ownership across charts | Reconciliation proves another owner's lock is not cleared | Concurrent terminal charts/journal access |
| Volume/risk/margin/OrderCheck rejection | Actual request-risk function tests | Broker-specific metadata/permissions |
| Role flips | Opposite-break predicate and integration review | Full upward/downward flip sequence |
| Shock cooldown, stale-signal retirement, session/spread/volatility filters | Production integration and source review | Tick-driven policy scenarios |
| Frozen precision chart plan | Source integration review | Native chart display and toggles |

## Native acceptance checklist

1. Compile the canonical MQ5 file with F7 in MetaEditor. Record compiler version and complete errors/warnings. Resolve native-language/API issues before trading. Successful EX5 compilation is not claimed here.
2. Use a separate demo account/terminal and Strategy Tester real-tick mode. Enable precision mode only after compilation. Change `InpPETestRunID` for independent backtests; retain it only for deliberate persistence tests. Tester and live journals use separate namespaces.
3. Repeat both directions of all scenarios above. Include a touch shorter than one second, the first quote after a candle closes, a gap through the zone and an intrabar far-boundary breach. With OHLC-only data, skipped unobserved touches are expected; never assume favourable ordering.
4. Compare `[PE]` logs, frozen chart entry/SL lines, Bid and Ask. Verify combined leg risk, broker minimum lots/steps/limits, stop/freeze distances, live R:R, margin failures, and unchanged frozen targets after delayed entry.
5. Test both breakout interpretations, both retest timings, both invalidation styles, manual BUY/SELL levels and the Toronto retracement rule. Lower-TF confirmation can intentionally skip a first touch; disabling it is an explicit strategy choice.
6. Exercise rejection, partial fill, timeout, delayed trade events, concurrent charts and restart during an unresolved request. Verify no automatic retry, no competing opposite trade, no unprotected entry, and preservation of another chart's reservation. Check Common/Files journal access and consumed-ID persistence.
7. Validate existing position-group reconstruction, breakeven, runner exits, trailing and netting/hedging behaviour, including incomplete protected baskets. Those exit routines were retained, not independently revalidated by entry tests.
8. Reproduce sharp M1 ranges/gaps; confirm cooldown extension, retirement of stale setups and the requirement for fresh post-stabilization confirmation. No scheduled-news/calendar blackout service exists in the original project or this extension.

The historical missed USDCHF sell cannot be diagnosed conclusively without its quote sequence, settings and terminal logs. This delivery adds explicit sequencing and fixes identified conflicts; final live-trading acceptance requires native compilation and MT5 evidence.
