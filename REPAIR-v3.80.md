# SEGS.mq5 — v3.80

## Second independent setup on the same instrument

An existing account position is no longer treated as proof that the current chart's candidate signal executed. The EA does not need to have been attached to that particular chart when an existing trade opened. Existing broker positions and new advice are now tracked separately.

The scanner no longer locks itself to the first setup's entry/SL/TP. It continues looking for an independently confirmed setup while capacity remains. The default is **two simultaneous advisor setups per exact broker symbol** (`InpMaxSetsPerSymbol=2`). Each setup retains the existing four-leg allocation, subject to portfolio capacity, permissions, margin, circuit breakers and all v3.79 direction/reversal/zone gates. A second setup is not an unconditional duplicate order.

Explicit setup IDs—not an arbitrary five-second time window—determine which legs belong together. A partially filled second set consumes a slot immediately. A new completed M5 confirmation must have formed after the other position's opening time. The current set's own legs are excluded from that test so placing its second/third/fourth leg does not invalidate its confirmation. Confirmation-bar timestamps form part of the full signal identity. Completed, consumed and aborted signal IDs stay consumed, even after all their positions close.

Execution and pending keys now hash the full signal identity so MT5's 63-character global-variable-name limit cannot silently break deduplication. Set capacity and duplicate identity are rechecked while holding the account execution mutex. Closing an unrelated chart's trade does not consume a new candidate signal. Old positions missing explicit setup identity are counted separately rather than guessed to be one group.

Independent broker stops/targets require a **hedging account**. A netting account merges entries on one symbol; the EA therefore refuses an additional independent setup when a position already exists on that symbol. An initial position on an otherwise empty netting symbol retains the existing behavior.

## Bounded dual stop policy

The default remains `SL_STYLE_AUTO_DUAL`, now with this priority:

1. **Entry order-block wick first.** BUY SL sits below that block candle's full wick low; SELL SL sits above its full wick high. The scan stores the actual origin candle's wick separately from the displayed zone, so body-only zone drawing cannot move the stop inside the wick. A small outward buffer and broker minimum distance apply. Final execution uses the exact selected block, not a different nearest block.
2. **Nearby institutional fallback.** When no usable entry-block anchor is available, consider the nearest valid completed structural swing/support/resistance or prior daily/weekly liquidity level on the correct side. A fallback cannot sit inside a known entry block's wick. A remote multi-day extreme cannot automatically widen a valid wick stop.
3. **Distance cap after broker adjustment and rounding.** The final entry-to-stop distance must fit both configured limits. If a valid structural invalidation cannot fit, defer the entry; never manufacture a stop inside the block just to meet the cap.

Defaults:

| Input | Default | Meaning |
| --- | --- | --- |
| `InpStructuralStopStyle` | `SL_STYLE_AUTO_DUAL` | Wick first, institutional fallback |
| `InpStructuralBufferATR` | `0.05` | Buffer beyond the anchor in closed H1 ATR |
| `InpActiveOBBufferTicks` | `3` | Minimum outward buffer in broker trade ticks |
| `InpMaxStructuralStopATR` | `1.5` | Maximum stop distance in closed H1 ATR |
| `InpMaxStructuralStopPercent` | `1.0` | Additional maximum of 1% of entry price; `0` disables this additional cap |
| `InpPublishStopSettingsToAllCharts` | `false` | Enable on one chart to publish Inputs to this account's other upgraded charts |

The effective maximum is the smaller of 1.5 H1 ATR and 1% of entry price by default. The percentage is a **price-distance cap**, not an account-risk percentage. Lot sizing still uses the finalized stop and existing risk/lot settings. These are practical defaults, not a claim of optimal performance for every market.

The optional wick-only, institutional-only and active-zone modes remain available, with the same distance cap. Active-zone trailing still only tightens an existing stop; when opening a trade, an explicit entry block takes precedence. The old `InpDualProximityATR` / `InpActiveOBBufferATR` inputs remain compatibility fields; the new system policy uses `InpStructuralBufferATR` and the published limits. New entries require the real closed H1 ATR and reject per-leg prices whose finalized stop would exceed the cap. Pending previews recompute SL/targets from the same policy; the HUD no longer invents a separate minimum 18-pip display stop.

New setups have independent symbol/setup-scoped saved SL/TP. Existing broker protection is retained. Changing the policy does not retrospectively widen stops on existing trades. Open-trade markings use actual per-ticket broker targets rather than a different candidate's projected targets.

## System-wide setup and installation

1. Download the full **SEGS.mq5** file, put it in `MQL5/Experts`, and compile this exact file with F7 in MetaEditor. Replace the attached EA on every chart that should use v3.80; verify the version shown in its HUD.
2. On **one chart**, select the stop style, buffer and maximum distances, and set `InpPublishStopSettingsToAllCharts=true`. Other charts should leave that switch false. They consume the policy on their next ready event, normally within a second. The account-scoped `SEGS_SL_V3_` policy persists across restart within this terminal. Old wider V2 defaults are ignored. Do not leave multiple charts publishing different policies.
3. Keep `InpMaxSetsPerSymbol=2` on the trading charts unless another limit is desired. That limit is per instance Input, whereas the stop policy is shared system-wide. Manual/unrelated-EA positions are not silently relabeled as advisor setups; their presence still requires a new confirmation before an advisor entry.
4. On demo, confirm that an existing first setup continues to be protected while a fresh independent second setup can appear, and that a third setup / repeated consumed signal is rejected. Reconcile broker SL/TP and sizing for both setups. Test body-only zones, BUY and SELL wick stops, nearby fallback, oversized/broker-constrained stop rejection and restart before enabling demo trading.

## Validation

- 31 assertions execute the actual extracted bounded-stop functions with C++ broker stubs: wick-first priority, full candle wick with body-only zones, nearest institutional fallback, invalid/missing anchors, ATR/price caps, broker minimum distance, tick rounding and optional trailing modes.
- 33 assertions execute actual setup counting, identity, fresh-confirmation and system-policy synchronization functions with stubs, including separate chart Inputs consuming a publisher's policy and account separation. Source integration checks cover the execution mutex and removal of unconditional same-symbol position vetoes.
- Existing entry-policy checks (37 assertions), expiry/stop-guard tests and the 40,000-deal history workload still pass. Expired candidates can now clear without touching a different live setup. All original EA functions remain present, and source copies / embedded source remain synchronized.

No native MetaEditor compiler or MT5 broker runtime is available in this environment. Successful native compilation, live/demo fills, terminal stability and profitability are not established by these tests. The update changes future entries and stop selection; it cannot establish the origin of historical positions from screenshots alone.
