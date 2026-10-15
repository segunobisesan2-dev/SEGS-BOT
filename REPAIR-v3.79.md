# v3.79: instrument-independent entry policy

The screenshots show existing USDJPY and NDAQ BUY positions, and an unexecuted USDCHF SELL plan. The existing positions' execution timestamps precede the screenshots; a current bearish chart does not establish the trend at their original entry time. The source nevertheless contained execution and reversal loopholes capable of allowing the behavior described.

## Corrected logic

- READY and TRIGGERED, manual and auto execution use the same final direction/zone gate. The first send, every further leg, and filling-mode retries revalidate. A setup label never bypasses the policy. A failed check after a partial fill uses the existing setup rollback behavior.
- Trend uses completed H1/H2/H4 bars and confirmed swing highs/lows. A live forming candle cannot alone flip the bias. Missing/ambiguous macro data does not count as bearish by negating a bullish flag.
- Trend continuations follow H1/H4 direction and must not oppose confirmed H1/M30 swing structure. Counter-trend BUY and SELL have symmetric requirements: at least 3 distinct completed H1 rejection cycles OR 4 M30 cycles on an active block; a completed M30 close breaking a confirmed local swing after block confirmation; and a fresh completed M5/M15 rejection of the selected block. Being near demand is insufficient. The old unconditional ban on SELL reversals in bullish confluence is removed. Configurable reversal-bounce thresholds can be increased, but cannot bypass these minimums.
- Bounce counts are rebuilt from closed bars after the actual block's confirmation. Adjacent touches count once until price departs. Broken blocks return zero. Old global counts cannot preserve a confirmation forever or borrow touches from before formation.
- Market execution requires price close to the exact planned entry: tolerance derives from ATR, trade tick and spread. Wide spreads cannot create a valid touch. Past M1/M5/M15 extrema and touching a different nearby block cannot authorize a late order. Opposing M30/H1 zone collisions block execution. Non-OB structural retests must match the identified support/resistance and pass the same proximity and rejection rules.
- Zone selection skips entries on the wrong side of current price and looks for the next viable active block instead of repeatedly selecting an unusable nearest block.
- Pending BUY pullback plans sit at/below price; SELL pullbacks sit at/above price, within half an H1 ATR. The USDCHF plan below current price shown in the screenshot would fail this planned-entry geometry check rather than advertise STRONG SELL. Pending advice is reviewed after scanning, and invalid levels/identity are cleared before normal dashboard rendering. The engine then scans for a fresh opportunity.
- New entry rules apply without instrument-specific GBPUSD/CHF/equity exceptions. ATR and broker trade tick scale the gate. Older scanner hints still exist, but they cannot bypass the final gate. The legacy reversal-protection input cannot disable that final policy.

## NDAQ's 91.96 line and target contamination

The unlabeled green 91.96 horizontal line at the last candle appears to be MT5's last Bid/price line. The screenshot separately labels an entry at 93.54 and stop at 89.89. No 91.96 constant exists in the EA. With a stale/delayed feed, a last-price line is a cached broker quote, not a current executable price. The stale warning now includes the exact last Bid to make this distinction visible. The screenshot alone cannot prove the chart-object owner.

The screenshot's NDAQ TP1 around 158.65 is implausible relative to its 93.54 entry and 89.89 stop and resembles the USDJPY target range. The old comment ID retained only the final 16 characters of a full signal ID—a pivot timestamp, losing symbol and direction—and persisted targets omitted the symbol. Group reconstruction also grouped by that shared short ID without checking symbol/direction. These are confirmed routes for cross-chart state contamination; runtime evidence would be needed to prove the precise route for that position.

v3.79 hashes the full signal identity into its 16-character comment tag, scopes target storage to account and exact broker symbol with additional fingerprints, and requires matching symbol/direction when rebuilding groups. It does not trust legacy unscoped target globals or another setup's chart snapshot. Actual broker TP/SL values take precedence in reporting; the display no longer expands existing targets into artificial R-multiples. Missing protection uses the position's own broker levels and verified snapshot, with the existing local recovery fallback. Already-submitted broker targets are retained: review the older NDAQ position's actual broker TP/SL on demo because new code cannot undo historical fills or establish which old targets were intentional.

## Display and log corrections

Existing positions are labeled as existing executions, with the current macro direction shown separately. Drawing the sentiment HUD no longer reruns the strategy scanner. A stale feed overrides cached market-gate status. Passing market conditions is distinguished from an approved entry. Unchanged advisor SL/TP pairs are skipped, and retcode 10025 (NO_CHANGES) is not reported as a modification failure.

## Verification and installation

- `python tests/entry_policy_regression.py`: 37 assertions execute extracted MQL entry, bounce, reversal, identity and persistence functions with C++ broker stubs. Cases include both confirmed reversal directions, unconfirmed counter-trend rejection, no chasing, pending-plan geometry, adjacent-touch counting, broken blocks, opposing zones, data loss, account/symbol isolation and NDAQ/USDCHF/USDJPY/gold price scales.
- `python tests/history_regression.py`: shared-ledger cases and the 40,000-deal workload still pass.
- `python tests/verify_source.py`: structural-stop/expiry harnesses, lexical checks, synchronized source copies and actual-send gate integration checks pass.
- All original EA functions remain present. No native MetaEditor/MT5 compiler or market replay is available here; these tests do not establish native compilation, broker execution, profitability, or terminal stability.

Compile the exact `SEGS_Trade_Manager_Pro_v3.79.mq5` with F7. Replace old attached executables on every chart using the policy, and verify the HUD reports v3.79 even if an old filename was used. First test with demo Algo Trading off. Reconcile existing NDAQ broker targets; then test bearish/bullish continuations, unconfirmed and confirmed reversals, stale feed, restart, partial fills and retests before enabling demo execution. Keep existing position protection under review during the upgrade. Legacy target globals are left in place but ignored by the new scoped loader.
