# Portfolio ORB EA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the validated London ORB strategy from GBPUSDm to a single-EA multi-symbol portfolio (GBPUSDm + EURUSDm/USDJPYm/XAUUSDm) to raise total return, with account-level risk coordination.

**Architecture:** Two phases. **Phase 1 (research)** uses the *existing* `LondonORB_EA.mq5` (already `_Symbol`-based) plus a headless sweep driver to find and OOS-validate each new symbol's best OR-start × OR-window config. **Phase 2 (build)** creates a new `PortfolioORB_EA.mq5` that holds per-symbol state in an array, runs the same ORB logic per symbol, and adds an account-level daily-DD breaker + a GBP/EUR correlation guard. **Phase 3** runs the combined multi-symbol backtest (2024 in-sample / 2025 OOS).

**Tech Stack:** MQL5 (MetaTrader 5), `CTrade`. Headless build via `Experts/AIEA/tools/compile.sh` (homebrew Wine). Headless Strategy Tester via bundled wine64 + `terminal64.exe /config:...ini`. Bash for the sweep driver. Symbols are Exness `m`-suffix (`GBPUSDm` etc.).

**Testing reality (read first):** MQL5 has no xUnit harness in this repo. The verification loop for *code* tasks is **`tools/compile.sh <file>` → `[compile] PASS`**; for *behavior* it is a **headless backtest** whose final balance is parsed from the UTF-16 agent log (`Tester/Agent-127.0.0.1-3000/logs/<YYYYMMDD>.log`). `rm` that log before each run to isolate it; sequential launches occasionally fail silently — retry 2–3×. Research-phase results are *discovered*, not asserted in advance, so those tasks specify the procedure and the recording format, not an "expected PASS".

---

## File Structure

- `Experts/AIEA/LondonORB_EA.mq5` — **unchanged.** Single-symbol EA; reused as the Phase 1 research vehicle. Do not edit.
- `Experts/AIEA/tools/sweep.sh` — **new.** Bash driver: loops OR-start × OR-window combos for one symbol/year, runs the headless tester per combo via a generated `[TesterInputs]` ini, parses final balance, appends a CSV row.
- `Experts/AIEA/tools/parse_balance.sh` — **new.** Helper: given an agent log path, prints the final balance (decodes UTF-16). Extracted so both `sweep.sh` and humans can reuse it.
- `Experts/AIEA/docs/superpowers/specs/2026-05-21-portfolio-symbol-configs.md` — **new.** The validated per-symbol config table (Phase 1 output) + dropped symbols and reasons.
- `Experts/AIEA/PortfolioORB_EA.mq5` — **new.** The portfolio EA. Built in Phase 2.
- `Experts/AIEA/docs/superpowers/specs/2026-05-21-portfolio-backtest-results.md` — **new.** Phase 3 combined-backtest results + caveats.

---

## Phase 1 — Research (validate edge per symbol)

### Task 1: Pre-flight — confirm symbols, data, and spread baselines

**Files:**
- Test/scratch only (no source committed in this task).

- [ ] **Step 1: Confirm the three candidate symbols exist and carry 2024–2025 history**

Create a throwaway script `Experts/AIEA/tools/_preflight.mq5` (a Script, not an EA) OR reuse a tester run. Simplest: run the existing EA once per symbol over `2024.01.01–2024.02.01` in the tester and confirm the agent log shows ticks/bars (no "history not found"). For each of `EURUSDm`, `USDJPYm`, `XAUUSDm`, launch:

Run (per symbol, editing `Symbol=` and the date in a `[Tester]` ini):
```
"/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64" \
  terminal64.exe "/config:C:\Program Files\MetaTrader 5\preflight.ini"
```
Expected: agent log produced, no `history` errors. If a symbol is missing/empty, record it as **unavailable** in the Phase 1 output doc and drop it.

- [ ] **Step 2: Record each symbol's typical spread (for per-symbol max-spread config)**

From each pre-flight agent log (or the terminal Journal), note the median spread in points. Gold (`XAUUSDm`) will be far wider than forex. Write these down for Task 8's `InpMaxSpreadPts` default and Task 4's sweep (so spread doesn't reject every trade). Forex majors: expect ~10–40 pts. Gold: expect hundreds.

- [ ] **Step 3: Commit nothing**

This task only gathers facts. No commit. Carry the symbol availability + spread numbers into Task 2/4.

---

### Task 2: Build the headless sweep driver

**Files:**
- Create: `Experts/AIEA/tools/parse_balance.sh`
- Create: `Experts/AIEA/tools/sweep.sh`

- [ ] **Step 1: Write `parse_balance.sh`**

```bash
#!/usr/bin/env bash
# Print the final balance from a UTF-16 MT5 tester agent log.
# Usage: parse_balance.sh <path-to-log>
set -euo pipefail
log="$1"
[ -f "$log" ] || { echo "NO_LOG"; exit 0; }
# Logs are UTF-16; iconv to UTF-8 then grab the last "final balance" figure.
iconv -f UTF-16 -t UTF-8 "$log" 2>/dev/null \
  | grep -i "final balance" \
  | tail -1 \
  | grep -oE "[0-9]+(\.[0-9]+)?" \
  | head -1
```

- [ ] **Step 2: Make it executable and smoke-test against an existing log**

Run:
```bash
chmod +x "Experts/AIEA/tools/parse_balance.sh"
# Point at any existing agent log from a prior run, if present:
bash "Experts/AIEA/tools/parse_balance.sh" \
  "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/Tester/Agent-127.0.0.1-3000/logs/$(date +%Y%m%d).log" || true
```
Expected: prints a number, or `NO_LOG` if none exists yet (acceptable here).

- [ ] **Step 3: Write `sweep.sh`**

```bash
#!/usr/bin/env bash
# Sweep OR-start hour x OR-window length for ONE symbol over ONE date range,
# using the existing LondonORB_EA via [TesterInputs] overrides. Appends CSV rows:
#   symbol,year,or_start,or_window,final_balance
# Usage: sweep.sh <SYMBOL> <FROM yyyy.mm.dd> <TO yyyy.mm.dd> <YEAR_LABEL> <MAXSPREAD> <out.csv>
set -euo pipefail
SYMBOL="$1"; FROM="$2"; TO="$3"; YEAR="$4"; MAXSPREAD="$5"; OUT="$6"

MT5_DIR="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5"
WINE="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64"
export WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
AGENTLOG="$MT5_DIR/Tester/Agent-127.0.0.1-3000/logs"
HERE="$(cd "$(dirname "$0")" && pwd)"

START_HOURS=(6 7 8 9 10 11 12 13 14 15 16)
WINDOWS=(15 30 60)

[ -f "$OUT" ] || echo "symbol,year,or_start,or_window,final_balance" > "$OUT"

for sh in "${START_HOURS[@]}"; do
  for win in "${WINDOWS[@]}"; do
    end_total=$(( sh*60 + win ))
    eh=$(( end_total / 60 )); em=$(( end_total % 60 ))
    INI="$MT5_DIR/sweep.ini"
    cat > "$INI" <<EOF
[Tester]
Expert=AIEA\\LondonORB_EA
Symbol=$SYMBOL
Period=M5
Model=1
FromDate=$FROM
ToDate=$TO
Deposit=10000
Leverage=1:500
Optimization=0
ShutdownTerminal=1
[TesterInputs]
InpORStartHour=$sh
InpORStartMin=0
InpOREndHour=$eh
InpOREndMin=$em
InpMaxSpreadPoints=$MAXSPREAD
EOF
    # Isolate this run's log
    rm -f "$AGENTLOG/"*.log 2>/dev/null || true
    # Launch (retry up to 3x on silent failure)
    bal=""
    for attempt in 1 2 3; do
      ( cd "$MT5_DIR" && "$WINE" terminal64.exe "/config:C:\\Program Files\\MetaTrader 5\\sweep.ini" ) >/dev/null 2>&1 || true
      latest="$(ls -t "$AGENTLOG/"*.log 2>/dev/null | head -1 || true)"
      [ -n "$latest" ] && bal="$(bash "$HERE/parse_balance.sh" "$latest")"
      [ -n "$bal" ] && [ "$bal" != "NO_LOG" ] && break
      sleep 2
    done
    echo "$SYMBOL,$YEAR,$sh,$win,${bal:-FAIL}" >> "$OUT"
    echo "[sweep] $SYMBOL $YEAR OR=$sh:00 win=$win -> ${bal:-FAIL}"
  done
done
```

- [ ] **Step 4: Make executable and commit the tooling**

Run:
```bash
chmod +x "Experts/AIEA/tools/sweep.sh"
git add Experts/AIEA/tools/sweep.sh Experts/AIEA/tools/parse_balance.sh
git commit -m "tools(orb): headless OR-start x OR-window sweep driver

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

> **Note on `Model=1` and `Deposit`/dates in ini:** the existing flow's `[Tester]` keys are documented in CLAUDE.md; if a key name is rejected by this terminal build, fall back to the exact ini layout that produced the prior backtest-results doc. Verify the first single combo runs and yields a number before launching the full grid.

---

### Task 3: Run the 2024 in-sample sweep for the three symbols

**Files:**
- Produces: `Experts/AIEA/tools/sweep_2024.csv` (data artifact)

- [ ] **Step 1: Compile the research EA (sanity)**

Run:
```bash
bash "Experts/AIEA/tools/compile.sh" "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/AIEA/LondonORB_EA.mq5"
```
Expected: `[compile] PASS`.

- [ ] **Step 2: Verify a single combo end-to-end before the full grid**

Temporarily run `sweep.sh` for `EURUSDm` with the arrays trimmed to one value each (edit locally, do not commit), confirm one CSV row with a real number appears. This catches ini/symbol/log issues cheaply.

- [ ] **Step 3: Run the full 2024 sweep per symbol**

Run (use the spread baseline from Task 1; forex example shown):
```bash
cd "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5"
bash Experts/AIEA/tools/sweep.sh EURUSDm 2024.01.01 2024.12.31 2024 40  Experts/AIEA/tools/sweep_2024.csv
bash Experts/AIEA/tools/sweep.sh USDJPYm 2024.01.01 2024.12.31 2024 40  Experts/AIEA/tools/sweep_2024.csv
bash Experts/AIEA/tools/sweep.sh XAUUSDm 2024.01.01 2024.12.31 2024 600 Experts/AIEA/tools/sweep_2024.csv
```
Expected: `sweep_2024.csv` gains 33 rows per symbol (99 total). `FAIL` rows are retryable individually.

- [ ] **Step 4: Commit the data artifact**

```bash
git add Experts/AIEA/tools/sweep_2024.csv
git commit -m "research(orb): 2024 in-sample OR sweep (EUR/JPY/XAU)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: OOS-confirm and select per-symbol configs

**Files:**
- Produces: `Experts/AIEA/tools/sweep_2025.csv`
- Create: `Experts/AIEA/docs/superpowers/specs/2026-05-21-portfolio-symbol-configs.md`

- [ ] **Step 1: Pick top candidates per symbol from 2024**

For each symbol, sort `sweep_2024.csv` by `final_balance` desc. Candidate = the top combo, **plus** its immediate neighbors (OR-start ±1h, adjacent window) for the robustness check. Net profit = `final_balance - 10000`.

- [ ] **Step 2: Run those candidates on 2025 (OOS)**

For each symbol, run `sweep.sh` over `2025.01.01 2025.12.31` (label `2025`) — you may trim the `START_HOURS`/`WINDOWS` arrays in a local copy to just the candidate set to save time. Output to `sweep_2025.csv`.

- [ ] **Step 3: Apply the selection rule and write the config doc**

A symbol is **KEPT** only if its chosen config is: (1) positive in 2024, (2) positive in 2025 OOS, (3) robust — neighbors not deeply negative. Otherwise **DROPPED**. Write `2026-05-21-portfolio-symbol-configs.md` with this exact table shape and the dropped list:

```markdown
# Portfolio ORB — Validated per-symbol configs (2026-05-21)

| Symbol  | OR start | OR window | Max spread (pts) | 2024 net | 2025 OOS net | Kept |
|---------|----------|-----------|------------------|----------|--------------|------|
| GBPUSDm | 06:00    | 30m       | 40               | +13.5%   | +1.8%        | yes  |
| EURUSDm | <fill>   | <fill>    | <fill>           | <fill>   | <fill>       | <y/n>|
| USDJPYm | <fill>   | <fill>    | <fill>           | <fill>   | <fill>       | <y/n>|
| XAUUSDm | <fill>   | <fill>    | <fill>           | <fill>   | <fill>       | <y/n>|

## Dropped
- <symbol>: <reason — e.g. 2025 OOS negative / not robust / no data>

## Final portfolio symbol list (kept only)
InpSymbols      = "<comma-separated kept symbols>"
InpORStartHours = "<...>"
InpORWindowMins = "<...>"
InpMaxSpreadPts = "<...>"
```

- [ ] **Step 4: Commit**

```bash
git add Experts/AIEA/tools/sweep_2025.csv "Experts/AIEA/docs/superpowers/specs/2026-05-21-portfolio-symbol-configs.md"
git commit -m "research(orb): OOS validation + per-symbol config selection

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Build the Portfolio EA

> Phase 2 builds a generic, symbol-list-driven EA; it does **not** depend on *which* symbols survived Phase 1 — only the final `InpSymbols`/config strings (from Task 4) differ. So Phase 2 can proceed in parallel with/after Phase 1. The compile loop is the verification at each step.

### Task 5: Create `PortfolioORB_EA.mq5` — inputs, config parsing, compile

**Files:**
- Create: `Experts/AIEA/PortfolioORB_EA.mq5`

- [ ] **Step 1: Write the file header, enums, and inputs**

```mql5
//+------------------------------------------------------------------+
//|                                            PortfolioORB_EA.mq5    |
//|           Multi-symbol Opening Range Breakout portfolio EA       |
//+------------------------------------------------------------------+
#property copyright   "AIEA"
#property version     "1.00"
#property description "Multi-symbol ORB portfolio EA. Per-symbol OR window + state, account-level DD breaker, correlation guard."

#include <Trade/Trade.mqh>

#define MAX_SYMBOLS 16

enum ENUM_SIGNAL      { SIGNAL_NONE, SIGNAL_BUY, SIGNAL_SELL };
enum ENUM_BUFFER_MODE { BUFFER_POINTS, BUFFER_ATR };
enum ENUM_SL_MODE     { SL_RANGE_OPPOSITE, SL_ATR };
enum ENUM_DD_ACTION   { DD_STOP_ONLY, DD_CLOSE_ALL };
enum ENUM_ENTRY_STATE { ENTRY_IDLE, ENTRY_ARMED, ENTRY_DONE };

input group "General"
input long            InpMagic            = 20260521;
input int             InpDeviation        = 20;
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;
input bool            InpDebugMode        = false;

input group "Portfolio (per-symbol, comma-separated, same order)"
input string InpSymbols        = "GBPUSDm,EURUSDm,USDJPYm,XAUUSDm";
input string InpORStartHours   = "6,7,8,9";       // per symbol
input string InpORWindowMins   = "30,30,15,60";   // per symbol (OR length)
input string InpMaxSpreadPts   = "40,40,40,600";  // per symbol

input group "Session (shared) — trade window measured from each symbol's OR end"
input int  InpTradeWindowMins  = 210;   // entries allowed for N min after OR end (210 = GBP 06:30->10:00)
input bool InpForceCloseEnable = true;
input int  InpForceCloseHour   = 20;
input int  InpForceCloseMin    = 0;

input group "Range / Signal"
input ENUM_BUFFER_MODE InpBufferMode     = BUFFER_ATR;
input int              InpBufferPoints   = 50;
input double           InpBufferATRmult  = 0.10;
input bool             InpRequireBarClose= true;
input int              InpATRPeriod      = 14;

input group "Risk"
input double         InpRiskPercent           = 1.0;     // per trade, per symbol
input double         InpMaxPortfolioDDPercent = 10.0;    // account-level daily DD breaker
input ENUM_DD_ACTION InpDDAction              = DD_STOP_ONLY;

input group "Exit / Trailing"
input ENUM_SL_MODE InpSLMode          = SL_RANGE_OPPOSITE;
input int          InpSLBufferPoints  = 30;
input double       InpSLATRmult       = 1.5;
input double       InpTP_R            = 1.8;
input double       InpBE_TriggerR     = 1.0;
input double       InpTrailStartR     = 1.2;
input int          InpTrailDistPoints = 200;

input group "Filters"
input bool            InpUseRangeFilter        = true;
input double          InpMinRangeATR           = 0.5;
input double          InpMaxRangeATR           = 3.0;
input bool            InpUseTrendFilter        = true;
input ENUM_TIMEFRAMES InpTrendTF               = PERIOD_H1;
input int             InpTrendEMA              = 50;
input bool            InpUseNewsFilter         = true;
input int             InpNewsMinsBefore        = 30;
input int             InpNewsMinsAfter         = 30;
input string          InpNewsCurrencies        = "GBP,USD,EUR,JPY";
input bool            InpUseRetest             = true;
input int             InpRetestTolerancePoints = 50;
input int             InpRetestTimeoutBars     = 6;

input group "Correlation guard"
input bool   InpUseCorrGuard = true;
input string InpCorrGroups   = "GBPUSDm,EURUSDm";  // ; separates groups, , separates members

input group "Display"
input bool InpShowDashboard = true;
```

- [ ] **Step 2: Add a string-split helper and the parse arrays (globals)**

```mql5
CTrade trade;

int    g_lastDay        = -1;     // account-level new-day reset
double g_dayStartEquity = 0.0;    // account equity at day start (portfolio DD base)
bool   g_ddStopped      = false;  // portfolio DD latch (per day)
bool   g_newsWarned     = false;

// Parsed per-symbol config (index-aligned)
string g_symbol[];          // symbol names
int    g_orStartH[];        // OR start hour
int    g_orStartM[];        // OR start min (always 0 here)
int    g_orEndH[];          // OR end hour   (derived)
int    g_orEndM[];          // OR end min    (derived)
int    g_maxSpread[];       // per-symbol max spread (points)
int    g_symCount = 0;

// Split "a,b,c" into parts[]; returns count.
int SplitCSV(const string s, string &parts[])
{
   return StringSplit(s, ',', parts);
}
```

- [ ] **Step 3: Compile to verify inputs parse**

Run:
```bash
bash "Experts/AIEA/tools/compile.sh" "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/AIEA/PortfolioORB_EA.mq5"
```
Expected: `[compile] PASS` (unused-var warnings OK at this stage).

- [ ] **Step 4: Commit**

```bash
git add Experts/AIEA/PortfolioORB_EA.mq5
git commit -m "feat(portfolio): EA scaffold — inputs + config globals

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Per-symbol state struct + init

**Files:**
- Modify: `Experts/AIEA/PortfolioORB_EA.mq5`

- [ ] **Step 1: Add the `SymbolState` struct and the state array (after the config globals)**

```mql5
struct SymbolState
{
   datetime         lastBarTime;
   double           orHigh;
   double           orLow;
   bool             rangeReady;
   ENUM_ENTRY_STATE entryState;
   ENUM_SIGNAL      armedDir;
   double           armedLevel;
   int              armedBarsElapsed;
   bool             tradedToday;
   int              atrHandle;
   int              trendEmaHandle;
   double           entryPrice;     // for R math
   double           initialRisk;    // price distance entry->initial SL
};
SymbolState g_st[];   // index-aligned with g_symbol[]
```

- [ ] **Step 2: Write `OnInit` — parse config, size arrays, create handles per symbol**

```mql5
int OnInit()
{
   string syms[], shs[], wins[], sprs[];
   int n  = SplitCSV(InpSymbols, syms);
   int n2 = SplitCSV(InpORStartHours, shs);
   int n3 = SplitCSV(InpORWindowMins, wins);
   int n4 = SplitCSV(InpMaxSpreadPts, sprs);
   if(n <= 0 || n != n2 || n != n3 || n != n4)
   {
      PrintFormat("PortfolioORB: config length mismatch syms=%d starts=%d wins=%d spreads=%d", n, n2, n3, n4);
      return INIT_FAILED;
   }
   if(n > MAX_SYMBOLS) { Print("PortfolioORB: too many symbols"); return INIT_FAILED; }

   g_symCount = n;
   ArrayResize(g_symbol, n);  ArrayResize(g_orStartH, n); ArrayResize(g_orStartM, n);
   ArrayResize(g_orEndH, n);  ArrayResize(g_orEndM, n);   ArrayResize(g_maxSpread, n);
   ArrayResize(g_st, n);

   for(int i = 0; i < n; i++)
   {
      g_symbol[i]   = syms[i];
      g_orStartH[i] = (int)StringToInteger(shs[i]);
      g_orStartM[i] = 0;
      int win       = (int)StringToInteger(wins[i]);
      int endTotal  = g_orStartH[i]*60 + g_orStartM[i] + win;
      g_orEndH[i]   = endTotal / 60;
      g_orEndM[i]   = endTotal % 60;
      g_maxSpread[i]= (int)StringToInteger(sprs[i]);

      if(!SymbolSelect(g_symbol[i], true))
         PrintFormat("PortfolioORB: WARN could not select %s in Market Watch", g_symbol[i]);

      g_st[i].lastBarTime      = 0;
      g_st[i].orHigh           = 0.0;
      g_st[i].orLow            = 0.0;
      g_st[i].rangeReady       = false;
      g_st[i].entryState       = ENTRY_IDLE;
      g_st[i].armedDir         = SIGNAL_NONE;
      g_st[i].armedLevel       = 0.0;
      g_st[i].armedBarsElapsed = 0;
      g_st[i].tradedToday      = false;
      g_st[i].entryPrice       = 0.0;
      g_st[i].initialRisk      = 0.0;

      g_st[i].atrHandle = iATR(g_symbol[i], InpTimeframe, InpATRPeriod);
      if(g_st[i].atrHandle == INVALID_HANDLE)
      { PrintFormat("PortfolioORB: ATR init FAILED for %s", g_symbol[i]); return INIT_FAILED; }

      g_st[i].trendEmaHandle = INVALID_HANDLE;
      if(InpUseTrendFilter)
      {
         g_st[i].trendEmaHandle = iMA(g_symbol[i], InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
         if(g_st[i].trendEmaHandle == INVALID_HANDLE)
         { PrintFormat("PortfolioORB: EMA init FAILED for %s", g_symbol[i]); return INIT_FAILED; }
      }
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   // Filling mode is set per-symbol just before each order (symbols differ).

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDay = -1;

   PrintFormat("PortfolioORB v1.00 init | %d symbols | ServerTime=%s",
               g_symCount, TimeToString(TimeTradeServer(), TIME_DATE|TIME_MINUTES));
   for(int i = 0; i < g_symCount; i++)
      PrintFormat("  [%d] %s OR=%02d:%02d-%02d:%02d maxSpread=%d",
                  i, g_symbol[i], g_orStartH[i], g_orStartM[i], g_orEndH[i], g_orEndM[i], g_maxSpread[i]);

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   for(int i = 0; i < g_symCount; i++)
   {
      if(g_st[i].atrHandle      != INVALID_HANDLE) IndicatorRelease(g_st[i].atrHandle);
      if(g_st[i].trendEmaHandle != INVALID_HANDLE) IndicatorRelease(g_st[i].trendEmaHandle);
   }
   EventKillTimer();
   Comment("");
   Print("PortfolioORB deinitialized. Reason: ", reason);
}
```

- [ ] **Step 2b: Add minimal `OnTick`/`OnTimer` stubs so it links**

```mql5
void OnTick()  { }
void OnTimer() { }
```

- [ ] **Step 3: Compile**

Run: `bash "Experts/AIEA/tools/compile.sh" ".../PortfolioORB_EA.mq5"`
Expected: `[compile] PASS`.

- [ ] **Step 4: Commit**

```bash
git add Experts/AIEA/PortfolioORB_EA.mq5
git commit -m "feat(portfolio): per-symbol state struct + OnInit parsing/handles

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Per-symbol time/session + range + signal helpers

**Files:**
- Modify: `Experts/AIEA/PortfolioORB_EA.mq5`

All helpers are the single-symbol EA's logic, parameterized by symbol index `i`. Add these (before `OnTick`):

- [ ] **Step 1: Time/session helpers (note: trade window is now OR-end + `InpTradeWindowMins`)**

```mql5
int MinutesOfDay(datetime t)
{
   MqlDateTime d; TimeToStruct(t, d);
   return d.hour*60 + d.min;
}

// Per-symbol new bar using that symbol's series.
bool IsNewBar(int i)
{
   datetime t = iTime(g_symbol[i], InpTimeframe, 0);
   if(t != g_st[i].lastBarTime) { g_st[i].lastBarTime = t; return true; }
   return false;
}

bool IsNewDay()
{
   MqlDateTime d; TimeToStruct(TimeCurrent(), d);
   if(d.day_of_year != g_lastDay) { g_lastDay = d.day_of_year; return true; }
   return false;
}

bool InORWindow(int i)
{
   int m = MinutesOfDay(TimeCurrent());
   return (m >= g_orStartH[i]*60 + g_orStartM[i] && m < g_orEndH[i]*60 + g_orEndM[i]);
}

bool InTradingWindow(int i)
{
   int m       = MinutesOfDay(TimeCurrent());
   int orEnd   = g_orEndH[i]*60 + g_orEndM[i];
   return (m >= orEnd && m < orEnd + InpTradeWindowMins);
}

bool PastForceClose()
{
   int m = MinutesOfDay(TimeCurrent());
   return m >= InpForceCloseHour*60 + InpForceCloseMin;
}
```

- [ ] **Step 2: Range helpers (per symbol)**

```mql5
double GetATR(int i)
{
   double buf[];
   if(CopyBuffer(g_st[i].atrHandle, 0, 1, 1, buf) < 1) return 0.0;
   return buf[0];
}

void FinalizeRange(int i)
{
   datetime now = TimeCurrent();
   MqlDateTime d; TimeToStruct(now, d);
   datetime dayStart = now - (d.hour*3600 + d.min*60 + d.sec);
   datetime orStart  = dayStart + (g_orStartH[i]*3600 + g_orStartM[i]*60);
   datetime orEnd    = dayStart + (g_orEndH[i]*3600   + g_orEndM[i]*60);

   MqlRates rates[];
   int copied = CopyRates(g_symbol[i], InpTimeframe, orStart, orEnd - 1, rates);
   if(copied <= 0) { g_st[i].orHigh=0.0; g_st[i].orLow=0.0; g_st[i].rangeReady=false; return; }

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int k = 0; k < copied; k++) { hi = MathMax(hi, rates[k].high); lo = MathMin(lo, rates[k].low); }
   g_st[i].orHigh = hi; g_st[i].orLow = lo; g_st[i].rangeReady = true;
}

bool RangeSizeOK(int i)
{
   if(!InpUseRangeFilter) return true;
   double atr = GetATR(i);
   if(atr <= 0) return false;
   double size = g_st[i].orHigh - g_st[i].orLow;
   return (size >= InpMinRangeATR*atr && size <= InpMaxRangeATR*atr);
}
```

- [ ] **Step 3: Signal + filter helpers (per symbol)**

```mql5
double SymPoint(int i) { return SymbolInfoDouble(g_symbol[i], SYMBOL_POINT); }
int    SymDigits(int i){ return (int)SymbolInfoInteger(g_symbol[i], SYMBOL_DIGITS); }

double BufferValue(int i)
{
   if(InpBufferMode == BUFFER_ATR) return GetATR(i) * InpBufferATRmult;
   return InpBufferPoints * SymPoint(i);
}

ENUM_SIGNAL CheckBreakout(int i)
{
   double buf = BufferValue(i);
   if(buf <= 0) return SIGNAL_NONE;
   double ref = InpRequireBarClose ? iClose(g_symbol[i], InpTimeframe, 1)
                                   : iClose(g_symbol[i], InpTimeframe, 0);
   if(ref > g_st[i].orHigh + buf) return SIGNAL_BUY;
   if(ref < g_st[i].orLow  - buf) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

bool TrendFilterOK(int i, ENUM_SIGNAL dir)
{
   if(!InpUseTrendFilter) return true;
   double ema[];
   if(CopyBuffer(g_st[i].trendEmaHandle, 0, 1, 1, ema) < 1) return false;
   double close = iClose(g_symbol[i], InpTrendTF, 1);
   if(dir == SIGNAL_BUY)  return close > ema[0];
   if(dir == SIGNAL_SELL) return close < ema[0];
   return false;
}

bool RetestConfirmed(int i, ENUM_SIGNAL dir)
{
   double tol = InpRetestTolerancePoints * SymPoint(i);
   double c   = iClose(g_symbol[i], InpTimeframe, 1);
   double lo  = iLow(g_symbol[i],  InpTimeframe, 1);
   double hi  = iHigh(g_symbol[i], InpTimeframe, 1);
   if(dir == SIGNAL_BUY)  return (lo <= g_st[i].armedLevel + tol) && (c > g_st[i].armedLevel);
   if(dir == SIGNAL_SELL) return (hi >= g_st[i].armedLevel - tol) && (c < g_st[i].armedLevel);
   return false;
}

// News filter is time-based and account-global (uses InpNewsCurrencies). Unchanged from single EA.
bool NewsBlocked()
{
   if(!InpUseNewsFilter) return false;
   datetime now = TimeCurrent();
   datetime from = now - InpNewsMinsAfter*60;
   datetime to   = now + InpNewsMinsBefore*60;
   MqlCalendarValue values[];
   int nv = CalendarValueHistory(values, from, to, NULL, NULL);
   if(nv <= 0)
   {
      if(!g_newsWarned) { Print("PortfolioORB: news calendar unavailable — filter inactive this run"); g_newsWarned=true; }
      return false;
   }
   for(int k = 0; k < nv; k++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[k].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)  continue;
      MqlCalendarCountry country;
      if(!CalendarCountryById(ev.country_id, country)) continue;
      if(StringFind("," + InpNewsCurrencies + ",", "," + country.currency + ",") < 0) continue;
      return true;
   }
   return false;
}
```

- [ ] **Step 4: Compile + commit**

Run: `compile.sh` → expect `[compile] PASS` (unused-function warnings OK).
```bash
git add Experts/AIEA/PortfolioORB_EA.mq5
git commit -m "feat(portfolio): per-symbol time/range/signal/filter helpers

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Per-symbol trade execution + management

**Files:**
- Modify: `Experts/AIEA/PortfolioORB_EA.mq5`

- [ ] **Step 1: Risk + spread + stops helpers (per symbol)**

```mql5
double CalculateLot(int i, double slPoints)
{
   if(slPoints <= 0) return 0.0;
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(g_symbol[i], SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(g_symbol[i], SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0.0;
   double valuePerPoint = tickValue * (SymPoint(i) / tickSize);
   double slMoneyPerLot = slPoints * valuePerPoint;
   if(slMoneyPerLot <= 0) return 0.0;
   double lot = riskMoney / slMoneyPerLot;
   double minLot = SymbolInfoDouble(g_symbol[i], SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_symbol[i], SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(g_symbol[i], SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot/step)*step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

bool SpreadOK(int i)
{
   if(g_maxSpread[i] <= 0) return true;
   long sp = SymbolInfoInteger(g_symbol[i], SYMBOL_SPREAD);
   return sp <= g_maxSpread[i];
}

bool ValidateStops(int i, double slPoints)
{
   long stopsLevel = SymbolInfoInteger(g_symbol[i], SYMBOL_TRADE_STOPS_LEVEL);
   long spread     = SymbolInfoInteger(g_symbol[i], SYMBOL_SPREAD);
   double minDist  = (double)(MathMax(stopsLevel, spread) + 10);
   return slPoints >= minDist;
}

// True if this EA holds an open position on symbol i; fills dir if so.
bool HasOpenPosition(int i, ENUM_SIGNAL &dir)
{
   dir = SIGNAL_NONE;
   if(!PositionSelect(g_symbol[i])) return false;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic) return false;
   long t = PositionGetInteger(POSITION_TYPE);
   dir = (t == POSITION_TYPE_BUY) ? SIGNAL_BUY : SIGNAL_SELL;
   return true;
}
```

- [ ] **Step 2: `OpenTrade` (per symbol)**

```mql5
void OpenTrade(int i, ENUM_SIGNAL signal)
{
   double ask   = SymbolInfoDouble(g_symbol[i], SYMBOL_ASK);
   double bid   = SymbolInfoDouble(g_symbol[i], SYMBOL_BID);
   double entry = (signal == SIGNAL_BUY) ? ask : bid;
   int    dg    = SymDigits(i);

   double slBuf = InpSLBufferPoints * SymPoint(i);
   double sl;
   if(InpSLMode == SL_RANGE_OPPOSITE)
      sl = (signal == SIGNAL_BUY) ? (g_st[i].orLow - slBuf) : (g_st[i].orHigh + slBuf);
   else { double a = GetATR(i); sl = (signal == SIGNAL_BUY) ? (entry - a*InpSLATRmult) : (entry + a*InpSLATRmult); }

   double slDist   = MathAbs(entry - sl);
   double slPoints = slDist / SymPoint(i);
   if(!ValidateStops(i, slPoints)) { if(InpDebugMode) PrintFormat("PortfolioORB %s: SL too tight", g_symbol[i]); return; }

   double tp  = (signal == SIGNAL_BUY) ? (entry + InpTP_R*slDist) : (entry - InpTP_R*slDist);
   double lot = CalculateLot(i, slPoints);
   if(lot <= 0) { if(InpDebugMode) PrintFormat("PortfolioORB %s: lot=0", g_symbol[i]); return; }

   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);
   trade.SetTypeFillingBySymbol(g_symbol[i]);   // per-symbol filling (Exness ECN)

   bool ok = (signal == SIGNAL_BUY)
             ? trade.Buy(lot, g_symbol[i], 0.0, sl, tp, "PortfolioORB")
             : trade.Sell(lot, g_symbol[i], 0.0, sl, tp, "PortfolioORB");
   if(ok)
   {
      g_st[i].entryPrice  = entry;
      g_st[i].initialRisk = slDist;
      g_st[i].tradedToday = true;
      g_st[i].entryState  = ENTRY_DONE;
      PrintFormat("PortfolioORB %s: %s lot=%s entry=%s SL=%s TP=%s", g_symbol[i],
                  (signal==SIGNAL_BUY?"BUY":"SELL"), DoubleToString(lot,2),
                  DoubleToString(entry,dg), DoubleToString(sl,dg), DoubleToString(tp,dg));
   }
   else PrintFormat("PortfolioORB %s: open FAILED retcode=%d (%s)", g_symbol[i],
                    trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

void CloseSym(int i)
{
   if(PositionSelect(g_symbol[i]) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
      trade.PositionClose(g_symbol[i]);
}
```

- [ ] **Step 3: `ManageTrailing` (per symbol)**

```mql5
void ManageTrailing(int i)
{
   if(!PositionSelect(g_symbol[i])) return;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic) return;

   long   type  = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   int    dg    = SymDigits(i);
   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(g_symbol[i], SYMBOL_BID)
                                              : SymbolInfoDouble(g_symbol[i], SYMBOL_ASK);
   double risk = g_st[i].initialRisk;
   if(risk <= 0) return;

   double profit = (type == POSITION_TYPE_BUY) ? (price - entry) : (entry - price);
   double rMult  = profit / risk;

   if(rMult >= InpBE_TriggerR)
   {
      double be = NormalizeDouble(entry, dg);
      bool needBE = (type == POSITION_TYPE_BUY)  ? (curSL < be)
                  : (type == POSITION_TYPE_SELL) ? (curSL > be || curSL == 0) : false;
      if(needBE) { trade.PositionModify(g_symbol[i], be, curTP); return; }
   }
   if(rMult >= InpTrailStartR)
   {
      double dist  = InpTrailDistPoints * SymPoint(i);
      double newSL = (type == POSITION_TYPE_BUY) ? (price - dist) : (price + dist);
      newSL = NormalizeDouble(newSL, dg);
      bool needTrail = (type == POSITION_TYPE_BUY)  ? (newSL > curSL)
                     : (type == POSITION_TYPE_SELL) ? (newSL < curSL || curSL == 0) : false;
      if(needTrail) trade.PositionModify(g_symbol[i], newSL, curTP);
   }
}
```

- [ ] **Step 4: Compile + commit**

Run `compile.sh` → `[compile] PASS`.
```bash
git add Experts/AIEA/PortfolioORB_EA.mq5
git commit -m "feat(portfolio): per-symbol trade open/manage/close + lot sizing

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Correlation guard

**Files:**
- Modify: `Experts/AIEA/PortfolioORB_EA.mq5`

- [ ] **Step 1: Add the guard (returns true if entry is blocked by a correlated open position)**

```mql5
// Blocked if InpUseCorrGuard and a same-direction position is already open
// on another symbol within the same correlation group as g_symbol[i].
bool CorrBlocked(int i, ENUM_SIGNAL dir)
{
   if(!InpUseCorrGuard) return false;
   string groups[];
   int ng = StringSplit(InpCorrGroups, ';', groups);
   for(int gi = 0; gi < ng; gi++)
   {
      string members[];
      int nm = StringSplit(groups[gi], ',', members);
      bool iInGroup = false;
      for(int m = 0; m < nm; m++) if(members[m] == g_symbol[i]) { iInGroup = true; break; }
      if(!iInGroup) continue;
      // i is in this group: scan other members for a same-direction open position
      for(int m = 0; m < nm; m++)
      {
         if(members[m] == g_symbol[i]) continue;
         if(PositionSelect(members[m]) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         {
            long t = PositionGetInteger(POSITION_TYPE);
            ENUM_SIGNAL openDir = (t == POSITION_TYPE_BUY) ? SIGNAL_BUY : SIGNAL_SELL;
            if(openDir == dir) return true;   // same-direction correlated exposure
         }
      }
   }
   return false;
}
```

- [ ] **Step 2: Compile + commit**

Run `compile.sh` → `[compile] PASS`.
```bash
git add Experts/AIEA/PortfolioORB_EA.mq5
git commit -m "feat(portfolio): GBP/EUR correlation guard

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: `OnTick` portfolio loop + new-day reset + account DD breaker + dashboard

**Files:**
- Modify: `Experts/AIEA/PortfolioORB_EA.mq5` (replace the stubs from Task 6)

- [ ] **Step 1: Replace the `OnTick`/`OnTimer` stubs with the full loop**

```mql5
void ProcessSymbol(int i)
{
   // Manage any open position every tick
   ManageTrailing(i);

   if(InpForceCloseEnable && PastForceClose()) { CloseSym(i); return; }

   if(!IsNewBar(i)) return;   // entry logic only on a new completed bar (per symbol)

   int nowMin = MinutesOfDay(TimeCurrent());
   if(!g_st[i].rangeReady && !InORWindow(i) && nowMin >= g_orEndH[i]*60 + g_orEndM[i])
      FinalizeRange(i);

   if(!g_st[i].rangeReady)   return;
   if(g_st[i].tradedToday)   return;
   if(!InTradingWindow(i))   return;
   if(!RangeSizeOK(i))       return;

   if(g_st[i].entryState == ENTRY_IDLE)
   {
      ENUM_SIGNAL sig = CheckBreakout(i);
      if(sig != SIGNAL_NONE && TrendFilterOK(i,sig) && !NewsBlocked() && SpreadOK(i) && !CorrBlocked(i,sig))
      {
         if(InpUseRetest)
         {
            g_st[i].entryState       = ENTRY_ARMED;
            g_st[i].armedDir         = sig;
            g_st[i].armedLevel       = (sig == SIGNAL_BUY) ? g_st[i].orHigh : g_st[i].orLow;
            g_st[i].armedBarsElapsed = 0;
         }
         else OpenTrade(i, sig);
      }
   }
   else if(g_st[i].entryState == ENTRY_ARMED)
   {
      g_st[i].armedBarsElapsed++;
      if(g_st[i].armedBarsElapsed > InpRetestTimeoutBars) g_st[i].entryState = ENTRY_IDLE;
      else if(RetestConfirmed(i, g_st[i].armedDir) && !NewsBlocked() && SpreadOK(i)
              && !CorrBlocked(i, g_st[i].armedDir))
         OpenTrade(i, g_st[i].armedDir);
   }
}

void OnTick()
{
   if(IsNewDay())
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_ddStopped      = false;
      g_newsWarned     = false;
      for(int i = 0; i < g_symCount; i++)
      {
         g_st[i].tradedToday      = false;
         g_st[i].rangeReady       = false;
         g_st[i].entryState       = ENTRY_IDLE;
         g_st[i].armedDir         = SIGNAL_NONE;
         g_st[i].armedBarsElapsed = 0;
         g_st[i].entryPrice       = 0.0;
         g_st[i].initialRisk      = 0.0;
      }
   }

   // Account-level daily DD breaker — checked every tick; latches for the day.
   if(g_dayStartEquity > 0)
   {
      double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
      if(g_ddStopped || ddPct >= InpMaxPortfolioDDPercent)
      {
         g_ddStopped = true;
         if(InpDDAction == DD_CLOSE_ALL)
            for(int i = 0; i < g_symCount; i++) CloseSym(i);
         UpdateDashboard();
         return;
      }
   }

   for(int i = 0; i < g_symCount; i++) ProcessSymbol(i);
   UpdateDashboard();
}

void OnTimer() { UpdateDashboard(); }
```

- [ ] **Step 2: Compile**

Run `compile.sh`. Expected: error — `UpdateDashboard` not yet defined. That's expected; defined in Task 11. (If you prefer green-at-every-step, add a temporary `void UpdateDashboard(){}` stub now and replace in Task 11.)

- [ ] **Step 3: Add a temporary dashboard stub so this task compiles green**

```mql5
void UpdateDashboard() { }
```
Run `compile.sh` → `[compile] PASS`.

- [ ] **Step 4: Commit**

```bash
git add Experts/AIEA/PortfolioORB_EA.mq5
git commit -m "feat(portfolio): OnTick loop + new-day reset + account DD breaker

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Aggregate dashboard

**Files:**
- Modify: `Experts/AIEA/PortfolioORB_EA.mq5` (replace the Task 10 stub)

- [ ] **Step 1: Replace the `UpdateDashboard` stub with the real one**

```mql5
void UpdateDashboard()
{
   if(!InpShowDashboard) return;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_dayStartEquity > 0) ? (g_dayStartEquity - eq)/g_dayStartEquity*100.0 : 0.0;

   string txt = StringFormat("=== Portfolio ORB EA ===\nServer: %s   Equity: %.2f\nDaily DD: %.2f%% / %.2f%%   DD-stopped: %s\n",
                  TimeToString(TimeCurrent(), TIME_MINUTES), eq, ddPct, InpMaxPortfolioDDPercent,
                  (g_ddStopped ? "yes" : "no"));
   for(int i = 0; i < g_symCount; i++)
   {
      string st = (g_st[i].entryState==ENTRY_IDLE)?"IDLE":(g_st[i].entryState==ENTRY_ARMED)?"ARMED":"DONE";
      txt += StringFormat("%-9s OR[%s] H=%s L=%s %s traded=%s sp=%d\n",
                g_symbol[i], (g_st[i].rangeReady?"rdy":"pend"),
                DoubleToString(g_st[i].orHigh, SymDigits(i)), DoubleToString(g_st[i].orLow, SymDigits(i)),
                st, (g_st[i].tradedToday?"Y":"N"), (int)SymbolInfoInteger(g_symbol[i], SYMBOL_SPREAD));
   }
   Comment(txt);
}
```

- [ ] **Step 2: Compile**

Run `compile.sh` → `[compile] PASS`.

- [ ] **Step 3: Commit**

```bash
git add Experts/AIEA/PortfolioORB_EA.mq5
git commit -m "feat(portfolio): aggregate multi-symbol dashboard

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Validate the portfolio

### Task 12: Smoke backtest (one short window) to prove multi-symbol execution

**Files:**
- No source changes; verification only.

- [ ] **Step 1: Run a 1-month multi-symbol backtest**

Build a `[Tester]` ini: `Expert=AIEA\PortfolioORB_EA`, a lead `Symbol=GBPUSDm`, `Period=M5`, `Model=1`, `FromDate=2024.06.01`, `ToDate=2024.07.01`, `Deposit=10000`, `ShutdownTerminal=1`. Use **Phase 1's validated config strings** in `[TesterInputs]` (`InpSymbols`, `InpORStartHours`, `InpORWindowMins`, `InpMaxSpreadPts`). `rm` the agent log first.

Run via bundled wine64 (see CLAUDE.md). Expected: log shows the init line listing all symbols and at least some `PortfolioORB <sym>: BUY/SELL ...` entries across **more than one** symbol → confirms multi-symbol trading works in the tester.

- [ ] **Step 2: Confirm history loaded for every symbol**

In the log, verify no `history not found`/empty-data errors for any symbol. If a secondary symbol has no trades and shows history errors, fix Market Watch selection (the `SymbolSelect` in `OnInit`) or pre-download history, then re-run.

- [ ] **Step 3: No commit (verification task).**

---

### Task 13: Full 2024/2025 portfolio backtest + results doc

**Files:**
- Create: `Experts/AIEA/docs/superpowers/specs/2026-05-21-portfolio-backtest-results.md`

- [ ] **Step 1: Run the full in-sample year (2024)**

Same ini as Task 12 but `FromDate=2024.01.01 ToDate=2024.12.31`. Parse final balance → net %.

- [ ] **Step 2: Run the OOS year (2025)**

`FromDate=2025.01.01 ToDate=2025.12.31`. Parse final balance → net %. This is the real verdict.

- [ ] **Step 3: Write the results doc**

Record method (mirror the existing `2026-05-21-backtest-results.md` style), the per-symbol configs used, portfolio net % and max DD for 2024 and 2025, and a comparison vs the GBPUSDm-only baseline (+13.5% / +1.8%). State plainly whether the success criterion (2025 OOS meaningfully > +1.8%, DD within tolerance) is met. Include the honest caveats from the spec (multi-symbol tester finicky, selection bias higher, 2-year sample, correlation, 1-min OHLC not real ticks, demo-test before live).

- [ ] **Step 4: Commit**

```bash
git add "Experts/AIEA/docs/superpowers/specs/2026-05-21-portfolio-backtest-results.md"
git commit -m "docs(portfolio): combined 2024/2025 backtest results + caveats

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: If the OOS result fails the success criterion**

Do **not** crank risk to mask a weak edge. Options, in order: (a) re-check per-symbol configs for robustness, (b) drop the weakest symbol(s) and re-run, (c) report honestly that the portfolio does not beat the baseline OOS and stop. Record the decision in the results doc.

---

## Self-Review notes (author)
- **Spec coverage:** Phase 1 sweep+selection (Tasks 1–4) ↔ spec Phase 1; portfolio EA per-symbol state, string config, account DD breaker, correlation guard, dashboard (Tasks 5–11) ↔ spec Phase 2; multi-symbol backtest 2024/2025 + caveats (Tasks 12–13) ↔ spec Phase 3 + caveats. `InpTradeWindowMins` is a necessary generalization of the single-EA's hardcoded 10:00 trade-end (documented in the EA inputs and File Structure).
- **No-placeholder check:** research-phase `<fill>` cells are *data outputs* of running the sweep, not unwritten plan content; every code task carries complete code.
- **Type consistency:** state accessed as `g_st[i].<field>` throughout; helpers uniformly take `int i`; `g_symbol[i]` used for all symbol-scoped API calls; `SymPoint(i)`/`SymDigits(i)` replace the single-EA's `_Point`/`_Digits`.
