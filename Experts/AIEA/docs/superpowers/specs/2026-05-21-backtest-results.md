# London ORB EA — Backtest & Tuning Results (2026-05-21)

## Method
- **Engine:** MetaTrader 5 Strategy Tester, driven **headless via Wine** (`terminal64.exe /config:...`, bundled wine64 + auto-login to the saved Exness account).
- **Symbol:** `GBPUSDm` (Exness "m"-suffix symbol on the connected account).
- **Model:** 1-minute OHLC (real-tick cache too sparse for multi-year). Well-suited to an M5 bar-close strategy.
- **Deposit:** 10,000 USD, leverage 1:500.
- **In-sample:** 2024.01.01–2024.12.31. **Out-of-sample:** 2025.01.01–2025.12.31.
- Net profit / trade counts extracted from the tester agent log.

## Findings

**1. Defaults (OR 08:00) lost money.** Baseline and a TP_R × SL-mode × retest sweep (12 combos) on 2024 were all negative; best was TP_R=1.8 / range-opposite SL / retest-on at **−5.4%/yr**. ATR-based SL was clearly worse than range-opposite. Win rate ~10–24%.

**2. Root cause was session mis-timing.** For a session-breakout strategy, the OR window must sit on the real volatility open. Sweeping the OR-start hour (06:00–11:00 server) on 2024:

| OR start (server) | 2024 net |
|---|---|
| 06:00 | **+13.5%** |
| 07:00 | −7.1% |
| 08:00 (old default) | −5.4% |
| 09:00 | −22.4% |
| 10:00 | −23.0% |
| 11:00 | −13.3% |

**3. Out-of-sample validation (2025).** Only **06:00** is positive in *both* years — not a single-year fluke:

| OR start | 2024 (in-sample) | 2025 (out-of-sample) |
|---|---|---|
| 05:00 | — | −11.7% |
| **06:00** | **+13.5%** | **+1.8%** |
| 07:00 | −7.1% | +7.7% |

## Validated configuration (now the EA defaults)
`InpORStartHour=6, InpOREndHour=6 (06:00–06:30), InpTradeEndHour=10, InpForceCloseHour=20, InpTP_R=1.8, InpSLMode=SL_RANGE_OPPOSITE, InpUseRetest=true` (other inputs unchanged).

Confirmed reproducing on compiled defaults: **2024 +1,351.77 (+13.5%), 168 trades** · **2025 +182.31 (+1.8%), 157 trades**.

## Honest caveats (read before risking money)
- **1-min OHLC model**, not real ticks — live spread/slippage at the open will reduce returns. Expect lower than +13.5%.
- **Only 2 years of data** (2024–2025). Small sample; not statistically conclusive.
- **2025 edge is thin (+1.8%)** — the strategy is marginally positive, not a money printer. 2024 was the stronger year.
- The profitable window (06:00 server) is **earlier than the classic 08:00 London open** — it captures the early-European/Frankfurt move on this Exness account. Confirm your live terminal's server time matches (the EA prints it at init).
- News filter is inactive in the tester (no calendar data) — its live effect is unmeasured here.
- Result is "best of a small principled search," so mild selection bias remains. Forward-test on demo before live.

## Reproduce
1. Compile `Experts/AIEA/LondonORB_EA.mq5` (F7 or `tools/compile.sh`).
2. Tester config: GBPUSDm, M5, model "1 minute OHLC", 2024.01.01–2025.12.31, deposit 10000.
3. Use default inputs (or delete a stale `MQL5/Profiles/Tester/LondonORB_EA.set` first — it overrides compiled defaults).

## Next steps toward live
Demo forward-test ≥ 1–2 months → real-tick backtest if more tick data is downloaded → live at minimum lot → scale only if demo/live track the backtest.
