# London ORB EA — Strategy Tester Validation

## Setup
- Symbol: GBPUSD
- Timeframe (chart): M5 (must match InpTimeframe)
- Model: "Every tick based on real ticks"
- Period: 2018.01.01 – 2025.12.31 (multi-year)
- Deposit: realistic (e.g. 10,000 USD), leverage as per live account
- Confirm tester broker server time; set InpORStart/End/TradeEnd to its London open
  (Exness ≈ GMT+0 → OR 08:00–08:30 default; the EA prints server time on init)

## Baseline run (all filters ON)
Record: Net profit, Profit Factor, Max DD %, Win rate, Trades, Expectancy (R), Recovery factor.
- [ ] Trades count is high enough to be meaningful (watch for over-filter → too few trades)

## Filter A/B (toggle ONE at a time, compare to baseline)
- [ ] InpUseRangeFilter = false
- [ ] InpUseTrendFilter = false
- [ ] InpUseNewsFilter  = false  (note: calendar may be inactive in tester)
- [ ] InpUseRetest      = false
Keep the filters that improve expectancy/DD; drop the ones that only cut trades.

## Walk-forward (avoid overfit — optimize FEW params)
- [ ] Optimize only: InpBufferATRmult, InpTP_R, InpOREnd (range length), InpTrendEMA
- [ ] In-sample optimize → out-of-sample validate; reject if OOS collapses

## Forward
- [ ] Demo forward test ≥ 1–2 months
- [ ] Live smallest size; scale only if demo/live align
