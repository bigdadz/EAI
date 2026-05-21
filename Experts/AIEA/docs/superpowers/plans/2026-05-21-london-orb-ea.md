# London ORB EA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-file MQL5 Expert Advisor that trades the London-session Opening Range Breakout on GBPUSD with strict risk control and four independently-toggleable filters.

**Architecture:** One file `Experts/AIEA/LondonORB_EA.mq5`, built in compile-clean layers: skeleton → time/session → range → signal → filters → risk → trade execution → trade management → dashboard. Pure arithmetic (lot sizing, time-window math) is regression-tested by a standalone script under `Scripts/UnitTests/AIEA/`. The full system is validated in the Strategy Tester.

**Tech Stack:** MQL5, `<Trade/Trade.mqh>` (`CTrade`), MQL5 Economic Calendar API, MetaTrader 5 Strategy Tester.

**Spec:** `Experts/AIEA/docs/superpowers/specs/2026-05-21-london-orb-ea-design.md`

---

## ⚠️ Toolchain reality (read before executing)

Headless compilation **works** via Wine (validated 2026-05-21). The agent compiles each task itself; only the Strategy Tester needs the human.

- **COMPILE CHECKPOINT** → agent runs `bash Experts/AIEA/tools/compile.sh "<abs path to .mq5>"`. Pass = script prints `[compile] PASS` and exits 0; on failure it prints per-line `error ...` messages to fix. (Mechanism: homebrew `wine` + throwaway prefix `~/.wine_orb` with a local copy of the real `Include`; the source is mirrored into a `C:\mt\MQL5` sandbox and compiled by the real `MetaEditor64.exe`. The bundle's own prefix is never touched.)
- **RUN CHECKPOINT** → **human only**: attach the script/EA in the MT5 terminal or run the Strategy Tester, then read the **Experts**/**Journal** log. Wine can't drive the tester headlessly here.

Wherever a task below says "COMPILE CHECKPOINT (user) — F7", the agent instead runs `tools/compile.sh`. The F7 path remains valid as a manual fallback.

Agent steps (write code, compile, `git add/commit`) run normally in the shell. Each task ends with a passing compile + a commit.

All `git` and `compile.sh` commands run from the repo root:
`cd "/Users/bigdadz/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5"`

---

## File Structure

| File | Responsibility |
|---|---|
| `Experts/AIEA/LondonORB_EA.mq5` | The entire EA: inputs, enums, globals, lifecycle handlers, all helper functions |
| `Scripts/UnitTests/AIEA/Test_LondonORB_Math.mq5` | Standalone regression test for pure arithmetic (lot sizing, minute-of-day math). Mirrors the EA's formulas; if a formula changes in the EA, update both. |

Single-file EA is a deliberate choice (see spec §4). Within the file, keep functions small and grouped by the section banners introduced in Task 1.

---

## Task 1: Skeleton — properties, enums, inputs, globals, empty lifecycle

**Files:**
- Create: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Create the file with full skeleton**

```mql5
//+------------------------------------------------------------------+
//|                                                 LondonORB_EA.mq5 |
//|                            London Opening Range Breakout EA      |
//+------------------------------------------------------------------+
#property copyright   "AIEA"
#property version     "1.00"
#property description "London Opening Range Breakout EA (single-file). GBPUSD, 1 trade/day."

#include <Trade/Trade.mqh>

//=== ENUMS =========================================================
enum ENUM_SIGNAL      { SIGNAL_NONE, SIGNAL_BUY, SIGNAL_SELL };
enum ENUM_BUFFER_MODE { BUFFER_POINTS, BUFFER_ATR };
enum ENUM_SL_MODE     { SL_RANGE_OPPOSITE, SL_ATR };
enum ENUM_DD_ACTION   { DD_STOP_ONLY, DD_CLOSE_ALL };
enum ENUM_ENTRY_STATE { ENTRY_IDLE, ENTRY_ARMED, ENTRY_DONE };

//=== INPUTS ========================================================
input group "General"
input long            InpMagic            = 20260521;
input int             InpDeviation        = 20;
input int             InpMaxTradesPerDay  = 1;
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;
input bool            InpDebugMode        = false;

input group "Session (server time, Exness GMT+0)"
input int  InpORStartHour    = 8;
input int  InpORStartMin     = 0;
input int  InpOREndHour       = 8;
input int  InpOREndMin        = 30;
input int  InpTradeEndHour    = 12;
input int  InpTradeEndMin     = 0;
input bool InpForceCloseEnable= true;
input int  InpForceCloseHour  = 20;
input int  InpForceCloseMin   = 0;

input group "Range / Signal"
input ENUM_BUFFER_MODE InpBufferMode     = BUFFER_ATR;
input int              InpBufferPoints   = 50;
input double           InpBufferATRmult  = 0.10;
input bool             InpRequireBarClose= true;
input int              InpATRPeriod      = 14;

input group "Risk"
input double         InpRiskPercent      = 1.0;
input double         InpMaxDailyDDPercent = 3.0;
input ENUM_DD_ACTION InpDDAction         = DD_STOP_ONLY;

input group "Exit / Trailing"
input ENUM_SL_MODE InpSLMode          = SL_RANGE_OPPOSITE;
input int          InpSLBufferPoints  = 30;
input double       InpSLATRmult       = 1.5;
input double       InpTP_R            = 1.8;
input double       InpBE_TriggerR     = 1.0;
input double       InpTrailStartR     = 1.2;
input int          InpTrailDistPoints = 200;

input group "Filters"
input int             InpMaxSpreadPoints       = 40;
input bool            InpUseRangeFilter        = true;
input double          InpMinRangeATR           = 0.5;
input double          InpMaxRangeATR           = 3.0;
input bool            InpUseTrendFilter        = true;
input ENUM_TIMEFRAMES InpTrendTF               = PERIOD_H1;
input int             InpTrendEMA              = 50;
input bool            InpUseNewsFilter         = true;
input int             InpNewsMinsBefore        = 30;
input int             InpNewsMinsAfter         = 30;
input string          InpNewsCurrencies        = "GBP,USD";
input bool            InpUseRetest             = true;
input int             InpRetestTolerancePoints = 50;
input int             InpRetestTimeoutBars     = 6;

input group "Display"
input bool InpShowDashboard = true;

//=== GLOBALS =======================================================
CTrade           trade;
int              g_atrHandle       = INVALID_HANDLE;
int              g_trendEmaHandle  = INVALID_HANDLE;

datetime         g_lastBarTime     = 0;
int              g_lastDay         = -1;

double           g_orHigh          = 0.0;
double           g_orLow           = 0.0;
bool             g_rangeReady      = false;

ENUM_ENTRY_STATE g_entryState      = ENTRY_IDLE;
ENUM_SIGNAL      g_armedDir        = SIGNAL_NONE;
double           g_armedLevel      = 0.0;
int              g_armedBarsElapsed= 0;

bool             g_tradedToday     = false;
double           g_dayStartEquity  = 0.0;
bool             g_ddStopped       = false;
bool             g_newsWarned      = false;

double           g_entryPrice      = 0.0;  // set on open, for R math
double           g_initialRisk     = 0.0;  // price distance entry->initial SL

//=== LIFECYCLE =====================================================
int OnInit()
{
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
}

void OnTimer()
{
}
//+------------------------------------------------------------------+
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)**

User opens `Experts/AIEA/LondonORB_EA.mq5` in MetaEditor → **F7**.
Expected: `0 errors, 0 warnings`. (Unused-input warnings are acceptable at this stage if any appear; target is 0 errors.)

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): EA skeleton — inputs, enums, globals, lifecycle stubs"
```

---

## Task 2: Time & session helpers + OnInit calibration print

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5` (replace `OnInit`/`OnDeinit`/`OnTimer`, add helpers section)

- [ ] **Step 1: Add the time/session helpers** (insert a banner + functions just below the GLOBALS block, before `OnInit`)

```mql5
//=== TIME / SESSION ================================================
int MinutesOfDay(datetime t)
{
   MqlDateTime d;
   TimeToStruct(t, d);
   return d.hour * 60 + d.min;
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
   return false;
}

bool IsNewDay()
{
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   if(d.day != g_lastDay) { g_lastDay = d.day; return true; }
   return false;
}

bool InORWindow()
{
   int m = MinutesOfDay(TimeCurrent());
   return (m >= InpORStartHour * 60 + InpORStartMin &&
           m <  InpOREndHour   * 60 + InpOREndMin);
}

bool InTradingWindow()
{
   int m = MinutesOfDay(TimeCurrent());
   return (m >= InpOREndHour    * 60 + InpOREndMin &&
           m <  InpTradeEndHour * 60 + InpTradeEndMin);
}

bool PastForceClose()
{
   int m = MinutesOfDay(TimeCurrent());
   return m >= InpForceCloseHour * 60 + InpForceCloseMin;
}
```

- [ ] **Step 2: Replace `OnInit` with handle creation + calibration print**

```mql5
int OnInit()
{
   g_atrHandle      = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   g_trendEmaHandle = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atrHandle == INVALID_HANDLE || g_trendEmaHandle == INVALID_HANDLE)
   {
      Print("LondonORB: indicator handle init FAILED");
      return INIT_FAILED;
   }

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastDay        = -1;

   long offsetSec = (long)(TimeTradeServer() - TimeGMT());
   PrintFormat("LondonORB v1.00 init | Symbol=%s | ServerTime=%s | est.GMT offset=%d h (0 in tester)",
               _Symbol,
               TimeToString(TimeTradeServer(), TIME_DATE | TIME_MINUTES),
               (int)(offsetSec / 3600));

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}
```

- [ ] **Step 3: Replace `OnDeinit` to release handles**

```mql5
void OnDeinit(const int reason)
{
   if(g_atrHandle      != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_trendEmaHandle != INVALID_HANDLE) IndicatorRelease(g_trendEmaHandle);
   EventKillTimer();
   Comment("");
   Print("LondonORB deinitialized. Reason: ", reason);
}
```

- [ ] **Step 4: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`.

- [ ] **Step 5: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): time/session helpers + OnInit handles & server-time calibration"
```

---

## Task 3: ATR accessor, range building, range-size filter

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Add the RANGE section** (after the TIME/SESSION block)

```mql5
//=== RANGE =========================================================
double GetATR()
{
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1) return 0.0;
   return buf[0];
}

// Compute Opening Range high/low from completed bars in [OR start, OR end).
void FinalizeRange()
{
   datetime now = TimeCurrent();
   MqlDateTime d;
   TimeToStruct(now, d);
   datetime dayStart = now - (d.hour * 3600 + d.min * 60 + d.sec);
   datetime orStart  = dayStart + (InpORStartHour * 3600 + InpORStartMin * 60);
   datetime orEnd    = dayStart + (InpOREndHour   * 3600 + InpOREndMin   * 60);

   MqlRates rates[];
   int copied = CopyRates(_Symbol, InpTimeframe, orStart, orEnd - 1, rates);
   if(copied <= 0) { g_rangeReady = false; return; }

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < copied; i++)
   {
      hi = MathMax(hi, rates[i].high);
      lo = MathMin(lo, rates[i].low);
   }
   g_orHigh     = hi;
   g_orLow      = lo;
   g_rangeReady = true;

   if(InpDebugMode)
      PrintFormat("LondonORB: range finalized H=%s L=%s (%d bars)",
                  DoubleToString(hi, _Digits), DoubleToString(lo, _Digits), copied);
}

bool RangeSizeOK()
{
   if(!InpUseRangeFilter) return true;
   double atr = GetATR();
   if(atr <= 0) return false;
   double size = g_orHigh - g_orLow;
   return (size >= InpMinRangeATR * atr && size <= InpMaxRangeATR * atr);
}
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): ATR accessor, opening-range finalize, range-size filter"
```

---

## Task 4: Breakout signal + buffer

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Add the SIGNAL section** (after RANGE block)

```mql5
//=== SIGNAL ========================================================
double BufferValue()
{
   if(InpBufferMode == BUFFER_ATR)
      return GetATR() * InpBufferATRmult;
   return InpBufferPoints * _Point;
}

// Uses the last completed bar (index 1) close when InpRequireBarClose,
// otherwise the current price. Returns direction of a confirmed breakout.
ENUM_SIGNAL CheckBreakout()
{
   double buf = BufferValue();
   if(buf <= 0) return SIGNAL_NONE;

   double ref = InpRequireBarClose
                ? iClose(_Symbol, InpTimeframe, 1)
                : iClose(_Symbol, InpTimeframe, 0);

   if(ref > g_orHigh + buf) return SIGNAL_BUY;
   if(ref < g_orLow  - buf) return SIGNAL_SELL;
   return SIGNAL_NONE;
}
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): breakout signal with ATR/points buffer + bar-close confirmation"
```

---

## Task 5: Filters — trend, news, retest confirmation

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Add the FILTERS section** (after SIGNAL block)

```mql5
//=== FILTERS =======================================================
bool TrendFilterOK(ENUM_SIGNAL dir)
{
   if(!InpUseTrendFilter) return true;
   double ema[];
   if(CopyBuffer(g_trendEmaHandle, 0, 1, 1, ema) < 1) return false;
   double close = iClose(_Symbol, InpTrendTF, 1);
   if(dir == SIGNAL_BUY)  return close > ema[0];
   if(dir == SIGNAL_SELL) return close < ema[0];
   return false;
}

// True if a high-impact event for a watched currency falls within
// [now - minsAfter, now + minsBefore]. Gracefully no-ops (returns false,
// warns once) if calendar data is unavailable (common in Strategy Tester).
bool NewsBlocked()
{
   if(!InpUseNewsFilter) return false;

   datetime now  = TimeCurrent();
   datetime from = now - InpNewsMinsAfter  * 60;
   datetime to   = now + InpNewsMinsBefore * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, NULL);
   if(n <= 0)
   {
      if(!g_newsWarned)
      {
         Print("LondonORB: news calendar unavailable/empty — news filter inactive this run");
         g_newsWarned = true;
      }
      return false;
   }

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH)  continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(StringFind(InpNewsCurrencies, country.currency) < 0) continue;

      return true;
   }
   return false;
}

// Stage 2 of the retest state machine: price pulled back near the broken
// level (within tolerance) and the last completed bar closed back in the
// armed direction.
bool RetestConfirmed(ENUM_SIGNAL dir)
{
   double tol = InpRetestTolerancePoints * _Point;
   double c   = iClose(_Symbol, InpTimeframe, 1);
   double lo  = iLow(_Symbol,  InpTimeframe, 1);
   double hi  = iHigh(_Symbol, InpTimeframe, 1);

   if(dir == SIGNAL_BUY)
      return (lo <= g_armedLevel + tol) && (c > g_armedLevel);
   if(dir == SIGNAL_SELL)
      return (hi >= g_armedLevel - tol) && (c < g_armedLevel);
   return false;
}
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`. (If MetaEditor flags `MqlCalendarValue`/`CalendarValueHistory` as undefined, the terminal build is too old; note it to the user — these exist since build 1860.)

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): trend, news (calendar), and retest filters"
```

---

## Task 6: Risk — lot sizing & daily drawdown

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Add the RISK section** (after FILTERS block)

```mql5
//=== RISK ==========================================================
// slPoints = stop distance in points (priceDistance / _Point).
double CalculateLot(double slPoints)
{
   if(slPoints <= 0) return 0.0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0.0;

   double valuePerPoint = tickValue * (_Point / tickSize);
   double slMoneyPerLot = slPoints * valuePerPoint;
   if(slMoneyPerLot <= 0) return 0.0;

   double lot = riskMoney / slMoneyPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

bool IsDailyDDExceeded()
{
   if(g_dayStartEquity <= 0) return false;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
   return ddPct >= InpMaxDailyDDPercent;
}
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): risk module — % risk lot sizing + daily drawdown check"
```

---

## Task 7: Trade execution — spread guard, stops validation, open

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Add the TRADE section** (after RISK block)

```mql5
//=== TRADE =========================================================
bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return sp <= InpMaxSpreadPoints;
}

// Ensure the stop distance respects broker stops level + spread.
bool ValidateStops(double slPoints)
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long spread     = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double minDist  = (double)(MathMax(stopsLevel, spread) + 10);
   return slPoints >= minDist;
}

void OpenTrade(ENUM_SIGNAL signal)
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (signal == SIGNAL_BUY) ? ask : bid;

   double slBuf = InpSLBufferPoints * _Point;
   double sl;
   if(InpSLMode == SL_RANGE_OPPOSITE)
      sl = (signal == SIGNAL_BUY) ? (g_orLow - slBuf) : (g_orHigh + slBuf);
   else // SL_ATR
   {
      double a = GetATR();
      sl = (signal == SIGNAL_BUY) ? (entry - a * InpSLATRmult)
                                  : (entry + a * InpSLATRmult);
   }

   double slDist   = MathAbs(entry - sl);
   double slPoints = slDist / _Point;
   if(!ValidateStops(slPoints))
   {
      if(InpDebugMode) Print("LondonORB: SL too tight for stops level — skipping");
      return;
   }

   double tp  = (signal == SIGNAL_BUY) ? (entry + InpTP_R * slDist)
                                       : (entry - InpTP_R * slDist);
   double lot = CalculateLot(slPoints);
   if(lot <= 0) { if(InpDebugMode) Print("LondonORB: lot=0 — skipping"); return; }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);

   bool ok = (signal == SIGNAL_BUY)
             ? trade.Buy(lot, _Symbol, 0.0, sl, tp, "LondonORB")
             : trade.Sell(lot, _Symbol, 0.0, sl, tp, "LondonORB");

   if(ok)
   {
      g_entryPrice  = entry;
      g_initialRisk = slDist;
      g_tradedToday = true;
      g_entryState  = ENTRY_DONE;
      PrintFormat("LondonORB: %s lot=%s SL=%s TP=%s",
                  (signal == SIGNAL_BUY ? "BUY" : "SELL"),
                  DoubleToString(lot, 2),
                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
   }
   else
      PrintFormat("LondonORB: open FAILED retcode=%d (%s)",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
}
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): trade execution — spread guard, stops validation, OpenTrade"
```

---

## Task 8: Trade management — break-even, trailing, close-all

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Append to the TRADE section**

```mql5
void CloseAll()
{
   if(PositionSelect(_Symbol) &&
      PositionGetInteger(POSITION_MAGIC) == InpMagic)
      trade.PositionClose(_Symbol);
}

void ManageTrailing()
{
   if(!PositionSelect(_Symbol)) return;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic) return;

   long   type  = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double price = (type == POSITION_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double risk = g_initialRisk;
   if(risk <= 0) return;

   double profit = (type == POSITION_TYPE_BUY) ? (price - entry) : (entry - price);
   double rMult  = profit / risk;

   // Break-even
   if(rMult >= InpBE_TriggerR)
   {
      double be = NormalizeDouble(entry, _Digits);
      bool need = (type == POSITION_TYPE_BUY)  ? (curSL < be)
                : (type == POSITION_TYPE_SELL) ? (curSL > be || curSL == 0)
                : false;
      if(need) trade.PositionModify(_Symbol, be, curTP);
   }

   // Trailing
   if(rMult >= InpTrailStartR)
   {
      double dist  = InpTrailDistPoints * _Point;
      double newSL = (type == POSITION_TYPE_BUY) ? (price - dist) : (price + dist);
      newSL = NormalizeDouble(newSL, _Digits);
      bool need = (type == POSITION_TYPE_BUY)  ? (newSL > curSL)
                : (type == POSITION_TYPE_SELL) ? (newSL < curSL || curSL == 0)
                : false;
      if(need) trade.PositionModify(_Symbol, newSL, curTP);
   }
}
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): trade management — break-even, trailing, close-all"
```

---

## Task 9: Dashboard

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5`

- [ ] **Step 1: Add the DISPLAY section** (after TRADE block)

```mql5
//=== DISPLAY =======================================================
void UpdateDashboard(string phase, ENUM_SIGNAL signal)
{
   if(!InpShowDashboard) return;

   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_dayStartEquity > 0) ? (g_dayStartEquity - eq) / g_dayStartEquity * 100.0 : 0.0;
   string sigStr = (signal == SIGNAL_BUY) ? "BUY" : (signal == SIGNAL_SELL) ? "SELL" : "-";
   string stateStr = (g_entryState == ENTRY_IDLE) ? "IDLE"
                   : (g_entryState == ENTRY_ARMED) ? "ARMED" : "DONE";

   string txt = StringFormat(
      "=== London ORB EA ===\n"
      "Symbol: %s   Server: %s\n"
      "Phase: %s\n"
      "Range: %s  H=%s  L=%s\n"
      "Entry state: %s   Signal: %s\n"
      "Traded today: %s   Spread: %d\n"
      "Daily DD: %.2f%% / %.2f%%   DD-stopped: %s",
      _Symbol, TimeToString(TimeCurrent(), TIME_MINUTES),
      phase,
      (g_rangeReady ? "ready" : "pending"),
      DoubleToString(g_orHigh, _Digits), DoubleToString(g_orLow, _Digits),
      stateStr, sigStr,
      (g_tradedToday ? "yes" : "no"),
      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
      ddPct, InpMaxDailyDDPercent,
      (g_ddStopped ? "yes" : "no"));

   Comment(txt);
}
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): lightweight Comment() dashboard"
```

---

## Task 10: Orchestration — wire OnTick and OnTimer

**Files:**
- Modify: `Experts/AIEA/LondonORB_EA.mq5` (replace empty `OnTick`/`OnTimer`)

- [ ] **Step 1: Replace `OnTick`**

```mql5
void OnTick()
{
   // New-day reset
   if(IsNewDay())
   {
      g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradedToday     = false;
      g_rangeReady      = false;
      g_entryState      = ENTRY_IDLE;
      g_armedDir        = SIGNAL_NONE;
      g_armedBarsElapsed= 0;
      g_ddStopped       = false;
   }

   // Manage any open position every tick
   ManageTrailing();

   // Force-close cutoff
   if(InpForceCloseEnable && PastForceClose())
   {
      CloseAll();
      UpdateDashboard("force-close window", SIGNAL_NONE);
      return;
   }

   // Only evaluate logic on a new completed bar
   if(!IsNewBar())
   {
      UpdateDashboard("intrabar", SIGNAL_NONE);
      return;
   }

   // Daily drawdown circuit breaker
   if(IsDailyDDExceeded())
   {
      g_ddStopped = true;
      if(InpDDAction == DD_CLOSE_ALL) CloseAll();
      UpdateDashboard("DD stopped", SIGNAL_NONE);
      return;
   }

   // Finalize range once we are past the OR window
   int nowMin = MinutesOfDay(TimeCurrent());
   if(!g_rangeReady && !InORWindow() &&
      nowMin >= InpOREndHour * 60 + InpOREndMin)
      FinalizeRange();

   if(!g_rangeReady)            { UpdateDashboard("collecting range", SIGNAL_NONE); return; }
   if(g_tradedToday)            { UpdateDashboard("traded today", SIGNAL_NONE);     return; }
   if(!InTradingWindow())       { UpdateDashboard("outside trade window", SIGNAL_NONE); return; }
   if(!RangeSizeOK())           { UpdateDashboard("range size rejected", SIGNAL_NONE); return; }

   // Entry state machine
   ENUM_SIGNAL displaySig = SIGNAL_NONE;

   if(g_entryState == ENTRY_IDLE)
   {
      ENUM_SIGNAL sig = CheckBreakout();
      displaySig = sig;
      if(sig != SIGNAL_NONE && TrendFilterOK(sig) && !NewsBlocked() && SpreadOK())
      {
         if(InpUseRetest)
         {
            g_entryState       = ENTRY_ARMED;
            g_armedDir         = sig;
            g_armedLevel       = (sig == SIGNAL_BUY) ? g_orHigh : g_orLow;
            g_armedBarsElapsed = 0;
            if(InpDebugMode) Print("LondonORB: ARMED ", (sig == SIGNAL_BUY ? "BUY" : "SELL"));
         }
         else
            OpenTrade(sig);
      }
   }
   else if(g_entryState == ENTRY_ARMED)
   {
      displaySig = g_armedDir;
      g_armedBarsElapsed++;
      if(g_armedBarsElapsed > InpRetestTimeoutBars)
      {
         g_entryState = ENTRY_IDLE;
         if(InpDebugMode) Print("LondonORB: retest timeout — disarmed");
      }
      else if(RetestConfirmed(g_armedDir) && !NewsBlocked() && SpreadOK())
      {
         OpenTrade(g_armedDir);
      }
   }

   UpdateDashboard("active", displaySig);
}
```

- [ ] **Step 2: Replace `OnTimer`** (refresh dashboard when no ticks)

```mql5
void OnTimer()
{
   UpdateDashboard("active", SIGNAL_NONE);
}
```

- [ ] **Step 3: COMPILE CHECKPOINT (user)** — F7. Expected: `0 errors, 0 warnings`.

- [ ] **Step 4: Commit**

```bash
git add "Experts/AIEA/LondonORB_EA.mq5"
git commit -m "feat(orb): wire OnTick orchestration + OnTimer dashboard refresh"
```

---

## Task 11: Pure-math regression test script

This validates the lot-sizing and minute-of-day arithmetic with hardcoded inputs so a formula regression is caught without a full backtest. It mirrors the EA formulas; keep both in sync.

**Files:**
- Create: `Scripts/UnitTests/AIEA/Test_LondonORB_Math.mq5`

- [ ] **Step 1: Create the test script**

```mql5
//+------------------------------------------------------------------+
//|                                       Test_LondonORB_Math.mq5    |
//|        Regression checks for LondonORB pure arithmetic.          |
//|        Attach to any chart; read results in the Experts tab.     |
//+------------------------------------------------------------------+
#property script_show_inputs

int g_pass = 0;
int g_fail = 0;

void Check(string name, bool cond)
{
   if(cond) { g_pass++; Print("PASS: ", name); }
   else     { g_fail++; Print("FAIL: ", name); }
}

bool DoubleEq(double a, double b, double eps = 1e-8)
{
   return MathAbs(a - b) < eps;
}

// --- mirrors EA: MinutesOfDay ---
int MinutesOfDay(datetime t)
{
   MqlDateTime d; TimeToStruct(t, d);
   return d.hour * 60 + d.min;
}

// --- mirrors EA: lot from risk (params injected, no symbol calls) ---
double LotFromRisk(double balance, double riskPct, double slPoints,
                   double tickValue, double tickSize, double point,
                   double minLot, double maxLot, double step)
{
   if(slPoints <= 0) return 0.0;
   double riskMoney     = balance * riskPct / 100.0;
   double valuePerPoint = tickValue * (point / tickSize);
   double slMoneyPerLot = slPoints * valuePerPoint;
   if(slMoneyPerLot <= 0) return 0.0;
   double lot = riskMoney / slMoneyPerLot;
   if(step > 0) lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

void OnStart()
{
   g_pass = 0; g_fail = 0;

   // MinutesOfDay
   Check("MinutesOfDay 08:00 == 480", MinutesOfDay(D'2026.05.21 08:00:00') == 480);
   Check("MinutesOfDay 12:30 == 750", MinutesOfDay(D'2026.05.21 12:30:00') == 750);

   // Lot sizing: balance 10000, risk 1% = $100; tickValue 1, tickSize=point=0.00001
   // valuePerPoint = 1 * (0.00001/0.00001) = 1 ; slPoints 200 -> $200/lot
   // lot = 100/200 = 0.5 -> step 0.01 -> 0.5
   Check("Lot 10000@1% / 200pts == 0.50",
         DoubleEq(LotFromRisk(10000, 1.0, 200, 1.0, 0.00001, 0.00001, 0.01, 100, 0.01), 0.50));

   // Clamp to min lot when risk tiny
   Check("Lot clamps up to minLot 0.01",
         DoubleEq(LotFromRisk(100, 0.1, 1000, 1.0, 0.00001, 0.00001, 0.01, 100, 0.01), 0.01));

   // Clamp to max lot when risk huge
   Check("Lot clamps down to maxLot 5.0",
         DoubleEq(LotFromRisk(1000000, 5.0, 50, 1.0, 0.00001, 0.00001, 0.01, 5.0, 0.01), 5.0));

   // Zero/negative SL -> 0
   Check("Lot with slPoints 0 == 0",
         DoubleEq(LotFromRisk(10000, 1.0, 0, 1.0, 0.00001, 0.00001, 0.01, 100, 0.01), 0.0));

   PrintFormat("=== Test_LondonORB_Math: %d passed, %d failed ===", g_pass, g_fail);
}
//+------------------------------------------------------------------+
```

- [ ] **Step 2: COMPILE CHECKPOINT (user)** — open the script in MetaEditor → F7. Expected: `0 errors`.

- [ ] **Step 3: RUN CHECKPOINT (user)**

In MT5: drag `Scripts/UnitTests/AIEA/Test_LondonORB_Math` onto any chart. Open Toolbox → **Experts** tab.
Expected final line: `=== Test_LondonORB_Math: 6 passed, 0 failed ===` (and six `PASS:` lines, no `FAIL:`).

- [ ] **Step 4: Commit**

```bash
git add "Scripts/UnitTests/AIEA/Test_LondonORB_Math.mq5"
git commit -m "test(orb): pure-math regression script (lot sizing, minute-of-day)"
```

---

## Task 12: Strategy Tester validation checklist

No code — this task produces a recorded validation run. It is the real integration test for the EA.

**Files:**
- Create: `Experts/AIEA/docs/superpowers/plans/orb-backtest-checklist.md`

- [ ] **Step 1: Write the checklist file**

```markdown
# London ORB EA — Strategy Tester Validation

## Setup
- Symbol: GBPUSD
- Timeframe (chart): M5 (must match InpTimeframe)
- Model: "Every tick based on real ticks"
- Period: 2018.01.01 – 2025.12.31 (multi-year)
- Deposit: realistic (e.g. 10,000 USD), leverage as per live account
- Confirm tester broker server time; set InpORStart/End/TradeEnd to its London open

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
```

- [ ] **Step 2: Commit**

```bash
git add "Experts/AIEA/docs/superpowers/plans/orb-backtest-checklist.md"
git commit -m "docs(orb): Strategy Tester validation & walk-forward checklist"
```

- [ ] **Step 3: RUN CHECKPOINT (user)** — run the baseline backtest per the checklist and report the metrics back. This is where we learn whether the edge is real; expect to iterate on parameters/filters afterward.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- §3 strategy flow → Tasks 2,3,4,10 (session, range, signal, orchestration) ✓
- §4 architecture / section banners → Tasks 1–10 ✓
- §5 inputs (all groups) → Task 1 ✓
- §6 filters (range/trend/news/retest, all toggle) → Tasks 3,5,10 ✓
- §7 error handling (handle validation, CopyBuffer guards, stops level, retcode, new-day) → Tasks 2,3,6,7,10 ✓
- §8 server-time calibration print → Task 2 ✓
- §9 testing (unit script + tester checklist) → Tasks 11,12 ✓
- §10 defaults → Task 1 input defaults ✓
- Exit logic (R-multiple TP, BE, trailing, force-close) → Tasks 7,8,10 ✓
- % risk sizing + daily DD breaker → Task 6, wired Task 10 ✓
- 1 trade/day (g_tradedToday) → Task 7 set, Task 10 reset/gate ✓

**Placeholder scan:** none — every code step contains full implementation.

**Type/name consistency:** globals (`g_orHigh`, `g_armedLevel`, `g_initialRisk`, `g_entryState`, …), enums, and function names (`FinalizeRange`, `CheckBreakout`, `TrendFilterOK`, `NewsBlocked`, `RetestConfirmed`, `CalculateLot`, `OpenTrade`, `ManageTrailing`, `CloseAll`, `UpdateDashboard`) are consistent across Tasks 1–12. `UpdateDashboard(string,ENUM_SIGNAL)` signature matches all call sites in Task 10.

**Note on TDD adaptation:** MQL5 has no headless test runner available on this host (no `wine` on PATH). Per-task verification is a user-run COMPILE CHECKPOINT; pure logic is regression-tested by the Task 11 script; full behavior is validated in the Strategy Tester (Task 12). This preserves the incremental, verify-each-step, commit-often discipline within the platform's constraints.
