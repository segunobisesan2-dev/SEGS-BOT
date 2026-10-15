# v3.83 — one active summary and system R:R settings

The sentiment dashboard now shows exactly one ACTIVE ENTRY summary for the exact chart symbol, including the actual fill-price range and BUY/SELL/MIXED direction. Independent setup identities and trading limits are preserved. Old per-group dashboard objects are removed on refresh, including after compilation. Execution date/time shows first and latest surviving fills in the existing dashboard timezone.

Legs opened, remaining and closed are shown where a verified original count exists. Successful new executions persist the actual opened count by account, exact symbol hash and setup identity. Legacy trades without that record show opened N/A; remaining always comes from current broker positions. Remaining means live broker legs, not unsubmitted planned orders. Counts cover setups with surviving positions, rather than lifetime instrument trade totals.

Overall R:R sums gross monetary reward to actual current broker TPs and monetary downside to current SLs, using OrderCalcProfit and actual volume per leg. It does not average individual ratios, offset opposite-direction risk, or invent a target. Missing SL/TP or failed valuation produces N/A. Zero downside with valid protection shows PROTECTED. These are surviving-position ratios using current SL/TP, excluding fees, already realized profit and original entry risk. Optional ticket ratios show up to four positions and a remainder count. If text would exceed the available row width it is hidden with a compact explanation. Position order follows the terminal's current position list.

System inputs: InpShowActiveLegCounts, InpShowOverallActiveRR, InpShowPerLegActiveRR. Set InpPublishDisplaySettingsToAllCharts=true on one controlling chart to publish the three values across this account's EA charts. Other charts consume shared values during readiness updates. Keep other charts' publisher switch false. Existing broker positions remain independent of new planned entries. Per-ticket chart trade markings are unchanged; consolidation concerns the sentiment dashboard.

Overwrite the existing SEGS.mq5 at its existing path and compile it there so MT5 can reinitialize charts already attached to that same EA. Changing paths or filenames creates a different EA and cannot replace an attached binary automatically.

Validation: extracted resolver/valuation logic compiled with C++ broker stubs, source consistency and existing entry, multi-setup, stop and history regressions. Native MetaEditor compilation and MT5 visual verification are not available in this environment.
