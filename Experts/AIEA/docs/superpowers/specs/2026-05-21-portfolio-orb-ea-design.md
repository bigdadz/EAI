# Portfolio ORB EA — Design (2026-05-21)

## Goal
Increase **total return** by expanding the validated London ORB strategy from a single
symbol (GBPUSDm) to a **multi-symbol portfolio** traded by one EA. The user accepts a
**high drawdown profile (40%+)** in exchange for higher absolute returns, but only on a
**genuinely validated edge per market** — not by amplifying a thin single-symbol edge.

Baseline to beat: GBPUSDm alone returned **+13.5% (2024 in-sample) / +1.8% (2025 OOS)**.

## Scope decisions (from brainstorming)
- **Same ORB strategy**, expanded across symbols/sessions. No new strategy type.
- **Candidate symbols:** GBPUSDm (existing) + **EURUSDm, USDJPYm, XAUUSDm**.
  Indices (US30m/NAS100m) were explicitly **dropped** (data/spread risk, out of scope).
- **Architecture:** single **Portfolio EA** managing all symbols (not multiple instances)
  — enables portfolio-level risk coordination and a true combined backtest.
- **Approach:** **research first, then build** — validate each symbol's edge with the
  existing single-symbol EA before writing the portfolio EA, so we never build for a
  market that has no edge.
- **Session question is absorbed** into the OR-start-hour sweep: a wide sweep
  (06:00–16:00 server) covers both the European/London open and the NY open, so each
  symbol finds its own best session empirically.

## Success criteria (Definition of Done)
1. A **validated config table per symbol** (OR-start, OR-window, max-spread) plus a record
   of any symbol **dropped** and why.
2. Portfolio EA **compiles** and runs a **multi-symbol backtest**.
3. Portfolio **2025 OOS** total return is **meaningfully above the +1.8% GBPUSDm baseline**,
   with drawdown within the accepted (high) tolerance.
4. Results + honest caveats documented (same style as the existing backtest-results doc).

---

## Phase 1 — Research (validate edge per symbol)

Uses the **existing `LondonORB_EA.mq5`** as-is (its logic is already `_Symbol`-based) driven
by the established headless-Wine Strategy Tester flow.

### Sweep grid (per new symbol: EURUSDm, USDJPYm, XAUUSDm)
- **OR-start hour:** 06:00 → 16:00 server time, step 1h (11 values). Covers
  Frankfurt/London open and NY/index open so each symbol's best session emerges.
- **OR-window length:** **15 / 30 / 60 min** (3 values).
- **Combos:** 11 × 3 = **33 per symbol per year** (~99 in-sample 2024 runs + OOS confirmation).
- **Other inputs:** validated defaults — TP_R=1.8, SL_RANGE_OPPOSITE, retest on,
  **ATR-based buffer** (`BUFFER_ATR`) so the breakout buffer auto-scales to each market's
  volatility (critical for gold vs forex).

### Validation rule (controls selection bias — combo count is high)
A symbol is **kept** only if its chosen config is:
1. **Positive in 2024 (in-sample)** — pick the best OR-start × OR-window, AND
2. **Positive in 2025 (OOS)** — same bar GBPUSD had to clear, AND
3. **Robust** — neighboring configs (OR-start ±1h, adjacent window length) are not deeply
   negative. Guards against a "lucky island" config that is good only by chance.

Symbols failing any rule are **dropped** and recorded with the reason.

### Per-symbol practical handling
- **Spread:** gold's spread is far wider than forex; the default `InpMaxSpreadPoints=40`
  would reject every gold trade. Each symbol gets its own max-spread (in points).
- **History/symbol existence:** confirm each `*m` symbol exists and has 2024–2025 data on
  the account before sweeping.
- **Tester reliability:** sequential headless launches occasionally fail silently — retry
  2–3× (per CLAUDE.md). Parse the UTF-16 agent log for final balance; `rm` it before each run.

### Output
A table written to `docs/.../specs/`:

| Symbol | OR start | OR window | Max spread | 2024 | 2025 OOS | Kept? |
|--------|----------|-----------|------------|------|----------|-------|
| GBPUSDm | 06:00 | 30m | 40 | +13.5% | +1.8% | yes (baseline) |
| EURUSDm | TBD-by-research | … | … | … | … | … |
| USDJPYm | … | … | … | … | … | … |
| XAUUSDm | … | … | … | … | … | … |

---

## Phase 2 — Build (Portfolio EA)

Refactor the single-global-state EA into **per-symbol state**, reusing all ORB logic
verbatim (breakout, retest state machine, BE/trailing, lot sizing, force-close, news filter).

### Config (comma-separated string inputs, parsed in `OnInit`)
```
InpSymbols        = "GBPUSDm,EURUSDm,USDJPYm,XAUUSDm"
InpORStartHours   = "6,7,8,9"        // per symbol, from Phase 1
InpORWindowMins   = "30,30,15,60"    // per symbol, from Phase 1
InpMaxSpreadPts   = "40,40,40,400"   // per symbol (gold wider)
```
String inputs (vs a compiled-in table) keep the EA tunable from the tester / `.set`
without recompiling. Parsed once at init into an array of `SymbolState` structs:
`orHigh, orLow, rangeReady, entryState, armedDir, armedLevel, armedBarsElapsed,
tradedToday, atrHandle, trendEmaHandle, entryPrice, initialRisk` — one per symbol.

### Execution
- **`OnTick`** iterates the symbol list; for each symbol it checks a per-symbol new bar
  (`iTime(symbol,...)`) and runs the existing ORB logic parameterized by symbol index.
- Positions are filtered by **symbol + magic**.
- Per-symbol indicator handles (ATR, trend EMA) created once at init.

### Portfolio risk coordination (the reason for a single EA)
1. **Per-trade risk:** each symbol risks `InpRiskPercent` of balance per trade (unchanged).
   Up to ~4 symbols/day → ~4× daily risk, acceptable under the high-DD profile; tunable up.
2. **Portfolio daily DD breaker:** measured on **whole-account equity** vs day-start equity.
   Exceeding `InpMaxPortfolioDDPercent` latches a stop on **all** symbols for the day.
3. **Correlation guard (default ON):** `InpCorrGroups = "GBPUSDm,EURUSDm"`. Within a group,
   if a position is open in one direction, a second same-direction entry is blocked
   (opposite direction allowed). Configurable off to maximize total return at the cost of
   stacked drawdown.
4. **Magic:** single magic; all position queries filter by symbol + magic.

---

## Phase 3 — Validate the portfolio

- **Multi-symbol backtest** in MT5 tester: one lead chart, EA trades all symbols in the
  list; tester downloads M1 history for every symbol; Model = 1-min OHLC.
- **2024 = in-sample (optimistic — configs were chosen on it). 2025 = OOS = the real verdict.**
- Compare portfolio equity curve and total return vs the GBPUSDm-only baseline.

---

## Honest caveats (to carry into the results doc)
- **Multi-symbol tester is slower and finickier** than single-symbol; verify history loads
  for all symbols, expect retries.
- **Selection bias is higher** here (33 combos/symbol) — mitigated by the both-years-positive
  + robustness rule, but not eliminated.
- **Only 2 years of data (2024–2025)** — small sample, not statistically conclusive.
- **Real correlation may exceed assumptions** — on strong USD-news days every pair can move
  together despite the correlation guard.
- **1-min OHLC, not real ticks** — live spread/slippage at the open will erode returns,
  especially on gold.
- **Always demo forward-test** before risking real money.

## Non-goals (YAGNI)
- No new strategy type (no trend-following / mean-reversion engine).
- No indices.
- No OR-window sweep beyond {15,30,60} and no sweep of TP_R/SL-mode/retest in Phase 1
  (kept at validated GBPUSD values to limit overfitting and run time).
- No automated portfolio optimizer; per-symbol configs are chosen by the principled manual sweep.
