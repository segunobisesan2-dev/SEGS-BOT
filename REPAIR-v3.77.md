# MT5 repair v3.77 — 15 October 2026

## What the supplied evidence establishes

The accessible attachment, `Mt5 Error log file oct 14 night.txt`, is UTF-16 MetaEditor compile/MCP history, not the MT5 runtime Experts/Journal log. On 14 October it records v3.75 compilation successes at 05:47:09, 19:43:45 and 19:49:18, failures at 06:28:33 and 09:05:17, and a successful `v3.76_Bounce_Entry_Fix` build at 09:05:26. It contains build summaries rather than diagnostic line details. A failed rebuild can leave an earlier executable in use. These entries do not establish the cause of terminal process termination or which executable was attached at failure time.

The other attachment, `mt5 log file oct 14 night.txt`, could not be transferred because it exceeds the tool's 32 MiB limit. It was not analyzed. A smaller Experts/Journal excerpt covering approximately five minutes before and after the shutdown, and any Windows Application Error entry for terminal64.exe, are needed to diagnose the actual shutdown. The workspace contains v3.75 source, but not the separately named v3.76 Bounce Entry Fix source. This repair is based on the workspace source.

## Confirmed defects corrected

- The HUD called itself setup-level but counted each individual exit deal. A four-leg setup or partial closures could inflate its win/loss totals. Both win-rate calculation paths now use the same completed-setup ledger.
- Entry commissions were absent from the prior calculation, fees were omitted, and the HUD and helper used different breakeven thresholds. The ledger includes profit, swap, commission and fee on both entries and exits; a net result within ±0.05 account-currency units is breakeven. Decisive win rate is wins / (wins + losses). All net P/L, including breakeven amounts, contributes to profit factor and net totals. No-loss profit factor retains the existing 9.99 display convention.
- Close-by exits are included. Partial closes and netting reversals remain part of the same position lifetime. A setup remains pending while any known leg is open or its entry history is missing. Explicit SEGS setup IDs group advisor legs; MAN master IDs group manual clones and their master. Untagged positions remain individual. Unrecoverable/truncated comment identities cannot be reconstructed by guessing based on nearby timestamps.
- Risk-template category AMD was also used as instrument identity. NDAQ, AAPL, MSFT and other stocks could match each other, contaminating per-symbol reporting and position selection. Equity identity now follows the ticker, including broker prefixes/suffixes for recognized symbols; cooldown/circuit-breaker namespaces retain separate equity keys. NDAQ100 is explicitly recognized as an index.
- A valid price was accepted even when its timestamp was stale. A visible warning now identifies stale quotes, disconnected feeds or unavailable startup history. New advisor entries and strategy scans pause after 120 seconds without a symbol quote. Existing broker protection is retained. A fresh scan is forced when quotes recover. The threshold is conservative: quiet instruments and closed sessions can show this warning legitimately.
- Full-history discovery and aggregation were repeated during HUD rendering, with nested history searches in the previous helper. A shared hashed snapshot now refreshes at most every 30 seconds, invalidates on trade transactions, and retries failures no faster than once a second. Failed refreshes withhold displayed totals. Accounts with more than 100,000 selected deals report unavailable rather than allocating an unbounded snapshot or silently truncating results.
- Startup history readiness checks now run at most once a second, and tick dashboard redraws were reduced from five per second to one. These reduce repeated CPU and allocation work across charts; they do not prove the terminal shutdown is fixed.

The legacy NDAQ anchor input default is now zero and labeled as unused compatibility input. The old 93.42 default was not referenced by executable logic, so it was not established as the source of the stale display. H1 zones continue to use market history. Circuit-breaker loss-count policy was not redesigned in this repair.

## Validation

`python tests/verify_source.py` passes existing extracted structural-stop, stop-guard and expired-signal checks, lexical checks and synchronization checks. The original EA function set was checked for accidental removal.

`python tests/history_regression.py` compiles the extracted history, asset identity and quote freshness functions as C++ with broker stubs and `-Wall -Wextra -Werror`. Scenarios cover four-leg aggregation, partial closes, entry commissions and fees, open siblings, separate equities, manual master/clones, missing entries, close-by exits, reversals, breakevens, cache reuse/failure, account changes and a 40,000-deal workload. These tests exercise extracted logic, not the MT5 runtime.

No native MetaEditor compiler or MT5 runtime is available here. Native compilation, actual broker-history reconciliation and terminal stability remain unverified.

## Installation and native verification

1. Save `SEGS_Trade_Manager_Pro_v3.77.mq5` in MQL5/Experts and compile that exact file with F7 in MetaEditor. Confirm zero errors and the new EX5 modification time. A source file alone cannot replace a running EX5.
2. Test on demo with Algo Trading off first. Attach only the newly compiled v3.77 to NDAQ and another equity. Check the chart/Experts version, restart and timeframe changes. Keep the old Inputs preset available; new equity-specific keys will no longer share another stock's old namespace.
3. Open Win Rate [G]. Manually reconcile one completed four-leg setup and a commission-bearing trade with Account History. Verify a partly open setup is excluded until its remaining leg closes. Historical broker comments and history availability limit reconstruction.
4. After market close or feed loss, verify the stale warning appears and new advisor entries pause. On feed recovery, verify a fresh strategy scan. Do not expect changing EA code to create fresh broker ticks outside the instrument's session.
5. Enable demo trading only after these checks. If MT5 still closes, provide the smaller runtime excerpt and terminal64.exe crash information. A successful compile or this patch is not evidence of permanent crash resolution.
