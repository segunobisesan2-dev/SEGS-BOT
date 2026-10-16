# Precision entry delivery

This extends the actual MT5/MQL5 trading engine in `SEGS_Trade_Manager_Pro_v3.75.mq5`. The public downloads, compatibility filenames and embedded TypeScript source are synchronized. The conflict audit is in `ENTRY_ENGINE_AUDIT.md`.

## Activation and behaviour

`InpPrecisionEntries=false` is the initial default: existing strategy analysis and advisor entry selection remain available. Shared final risk checks, executable shock/session/spread protection and durable legacy execution-key handling also apply to legacy entries. Turn precision entries on only after native compilation and demo validation. When on, it exclusively owns advisor submissions; chart Z/buttons cannot force a premature entry. The legacy scanner still supplies market analysis. When precision mode has no open advisor position, chart entry/SL lines show the nearest live precision setup's frozen Bid trigger and protective stop, with its ID and numeric state. Multiple armed setups can exist; actual triggers use deterministic conflict handling. Legacy dashboard analysis can still differ from the armed plan. `[PE]` logs and `SEGS_PE_*` records supply the execution audit trail.

For direct BUY, Bid must first be observed above the selected level, then enter its tolerance band while the setup remains valid. For SELL, Bid must first be below, then enter the band. Attaching inside a zone is not a past touch. A quote that jumps over the band is not treated as a fill. The executable price is Ask for BUY and Bid for SELL; spread can therefore put actual entry outside the signal band. Current risk, price drift, margin and protection still must pass.

For continuation BUY, a later completed confirmation candle must close strictly above the frozen ceiling plus breakout buffer. A later observed touch can enter under RETEST_TOUCH. Under the default RETEST_REJECTION_CLOSE, that observed touch must belong to a later candle which closes above the ceiling plus rejection buffer. Execution uses the next available eligible quote. SELL reverses the inequalities. A breakout candle's earlier wick is never reused as a retest. OHLC-only retests without an observed quote are skipped.

For a role flip, a completed upward break of bearish supply retires the original and creates a separately identified BUY candidate. A downward break of bullish demand creates a SELL candidate. The original cannot trade alongside the flip. Only one flip is created per original; flips do not flip recursively. Role-flip candidates require their own later retest and the preserved confluence/risk checks. BREAKOUT_UNSELECTED is the default and cannot arm breakout setups. Select the interpretation explicitly in Inputs.

Manual levels are separate one-leg DIRECT_TOUCH setups with explicit ID, direction, price, SL, TP, eligible time and expiry. No direction is inferred. Their structural far boundary is the supplied protective SL, independent of the signal level; CLOSE_BREAK never removes that broker SL. Account protections apply. They do not inherit OB detection or lower-TF confirmation.

## All new settings

All `Points` values are **broker points**, multiplied by `SYMBOL_POINT`; they are not pips or trade ticks. Absolute prices must be valid for the chart symbol. Times are broker/server times. Buffers, mode and boundaries are frozen at arming.

| Input | Default | Unit / meaning |
|---|---|---|
| InpPrecisionEntries | false | Opt in; sole advisor entry owner when true |
| InpPETestRunID | test-1 | Tester-only journal namespace; change for independent backtests; live journals are isolated |
| InpPEDirectTouch | true | Enable OB direct-touch selection |
| InpPEBreakoutRetest | false | Enable breakout/retest selection |
| InpPEBothPriority | BREAKOUT_RETEST | Exactly one mode when both flags true; no fallback |
| InpPEBreakoutType | BREAKOUT_UNSELECTED | Explicit EXISTING_BLOCK_CONTINUATION, BROKEN_BLOCK_ROLE_FLIP, or BOTH_SEPARATE required |
| InpPEConfirmTF | PERIOD_M5 | Completed breakout, rejection and close-invalidation candles |
| InpPERetestTiming | RETEST_REJECTION_CLOSE | New assumption for evaluation; alternate RETEST_TOUCH |
| InpPETouchLevel | NEAR_BOUNDARY | BUY ceiling / SELL floor; alternatives ZONE_MIDPOINT, SPECIFIED_PRICE |
| InpPEHonorDeepWindow | true | Preserve existing 04:30–07:50 Toronto rule: 38.2% above floor for BUY / below ceiling for SELL, when NEAR_BOUNDARY selected; frozen when armed |
| InpPESpecifiedPrice | 0 | Absolute price; must be within the OB |
| InpPETouchTolerancePoints | 2 | Bid distance from selected level |
| InpPEBreakoutBufferPoints | 2 | Strict close beyond breakout boundary |
| InpPERejectionBufferPoints | 2 | Strict rejection close beyond near boundary |
| InpPEInvalidation | WICK_BREAK | Alternate CLOSE_BREAK uses completed confirmation candles |
| InpPEInvalidationBufferPoints | 2 | Beyond far boundary; exact equality is not a cross |
| InpPEExpiryMinutes | 300 | Minutes from actual detection; also capped by existing H1 signal-age limit from OB confirmation |
| InpPERetestExpiryMinutes | 60 | Minutes from breakout; cannot extend original expiry |
| InpPEMaxTouches | 2 | Historical OB mitigations plus distinct observed touch episodes |
| InpPEDeviationPoints | 20 | Maximum requested deviation; never widened to force entry |
| InpPEMaxQuoteAgeSeconds | 5 | Maximum executable-quote age |
| InpPEShockCooldownMinutes | 15 | Stabilization pause, extended while shock persists |
| InpPEShockRangeATR | 1.0 | Current or latest completed M1 range / completed H1 ATR; effective threshold is min(this, existing InpMaxSpikeAtrMultiplier) |
| InpPEShockGapATR | 1.0 | Adjacent observed Bid gap / completed H1 ATR |
| InpPEManualEnabled | false | Enable separate manual-level setup |
| InpPEManualID | manual-1 | User's stable identity; change only for a genuinely new setup |
| InpPEManualDirection | MANUAL_BUY | Explicit MANUAL_BUY or MANUAL_SELL |
| InpPEManualPrice | 0 | Absolute trigger price; positive required |
| InpPEManualSL | 0 | Absolute protective stop; positive, correct side required |
| InpPEManualTP | 0 | Absolute take profit; positive, correct side and minimum R:R required |
| InpPEManualEligible | 0 | Nonzero broker/server datetime required |
| InpPEManualExpiry | 0 | Explicit datetime later than eligibility required |

Existing settings still matter: OB observation, displacement/BOS, zone method, minimum score, preferred touches, H1 age, completed lower-TF confirmation, HTF alignment, risk profile/custom percent, fixed total lots, lot cap, per-setup/portfolio position ceilings, stop style, minimum R:R and maximum ATR drift. Score is observed at arming, not projected backwards. Closed M5/M15 rejection confirmation is independently checked; when required it can intentionally skip a first touch. Disable that existing requirement explicitly if pure unconfirmed first-touch entry is your intended strategy.

## Safety and deliberate changes

- The new path admits the existing displacement/BOS detector branch. Sweep-only historical detections are excluded because the old scanner compares historical origins to current daily/weekly liquidity levels. Existing scanner/chart behaviour is preserved. This is a conservative new eligibility assumption. Boundaries and targets freeze only when actually observed eligible; confirmation availability is corrected from candle open to candle end.
- Expiry and invalidation run before trigger evaluation, including simultaneous touch/breach. WICK_BREAK also checks the completed candle extremes in case a breach tick was missed. More than two missing confirmation intervals expires an interrupted sequence. Rejection entries need an observed post-breakout touch; ambiguous OHLC event ordering is skipped.
- BUY/SELL simultaneous events skip both. Opposing overlapping live zones block entry. Same-direction candidates use oldest eligibility, then lexical stable ID. Existing exposure of **any** direction on the symbol blocks a new precision basket, including netting-account manual positions. Netting accounts and manual-level setups use one leg; hedging accounts can use the existing four-leg ladder and capacity mapping (two last slots TP1/TP3; last slot TP2).
- Every order entry path uses the common final gate and broker OrderCheck: permissions, broker/cash sessions, Toronto shield, low-volatility compression, loss circuit breaker, spread/cost, SL/TP, tick alignment, volume step/limits, minimum R:R, margin and configured position ceilings. Generic pending activation confirms cancellation before sending its replacement market order; advisor pending activation cannot override precision sequencing. Manual-master clones now require the master's protective stop and a valid target before submission. This fixes their prior unprotected entry path.
- Precision sizing uses OrderCalcProfit for the actual BUY/SELL side and current proposed entry/SL. The existing risk profile supplies one combined setup cash budget. Broker minimums never increase risk. Fixed lots and the legacy smart-micro floor also face the shared cash-risk cap. Fees and adverse fills can still change realised loss; this is planned protective-stop risk, not a guaranteed loss ceiling.
- Structural targets are calculated at arming with the existing target builder, then frozen. Delayed quotes failing R:R, drift or stop distance are skipped, without extending targets or removing stops. Legacy target calculation remains, followed by the stricter shared final gate; legacy automatic filling fallback is removed.
- Shock detection runs on ticks outside the scanner throttle. Old precision setups expire; old legacy confirmations cannot execute after cooldown. A new OB must confirm after stabilization to become eligible. This reduces stale continuation entries; it does not prove a reversal or anticipate a scheduled release. The original EA has no economic-calendar/news blackout service; none is claimed here.
- Before submitting, reserve the setup and account/symbol in terminal globals and an append-only common-file journal. No retry after rejection, timeout, partial execution or uncertain response. Confirmed fills consume the setup. A partial precision basket is retained with its broker SL/TP; missing legs are not replaced. Existing management routines continue managing actual positions. Legacy incomplete-basket rollback remains.
- Broker REQUEST, DEAL_ADD and history reconciliation distinguish submitted, rejected, partial and filled outcomes. A filled earlier leg does not resolve an unknown later request. Unresolved requests without conclusive broker history intentionally keep the symbol blocked. Legacy partial/uncertain responses set a separate LEGACY reservation; review actual broker exposure/Experts logs before any operator recovery. There is no timer-based unlock or automatic retry.
- Restart replays the account/server/magic/symbol journal, reconciles positions/orders/history, cancels incompatible advisor pending orders, and expires interrupted unsubmitted tick sequences. It does not assume that old touches occurred. Consumed IDs remain tombstones even beyond MT5 terminal-global expiry. Do not delete `SEGS_PE_*` globals or the corresponding Common/Files journal to force a retry. An unreadable/corrupt/unwritable journal blocks new precision submissions.
- Existing exits, breakeven, structural trailing, runner exits, stop settings synchronization and protective healing are retained. The precision state machine drives its own frozen chart plan and logs numeric states: 0 DETECTED, 1 ELIGIBLE, 2 WAITING_FOR_BREAKOUT, 3 WAITING_FOR_RETEST, 4 RETEST_TOUCHED, 5 ENTRY_SUBMITTED, 6 TRADED, 7 INVALIDATED, 8 EXPIRED.

## Verification boundaries

See `VALIDATION.md` for actual commands/results and the remaining MT5 checklist. No screenshot or USDCHF Experts/Journal records were provided, so its historical missed sell cannot be attributed conclusively to a filter, permission state, quote sequence, or throttle. No native executable is included.
