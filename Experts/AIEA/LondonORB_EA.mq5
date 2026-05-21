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
   // day_of_year avoids the day-of-month collision across months (e.g. Dec 15 / Jan 15)
   if(d.day_of_year != g_lastDay) { g_lastDay = d.day_of_year; return true; }
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

   // CopyRates selects bars by OPEN time, inclusive of both bounds; orEnd-1s
   // keeps the window half-open [orStart, orEnd) for all standard timeframes.
   MqlRates rates[];
   int copied = CopyRates(_Symbol, InpTimeframe, orStart, orEnd - 1, rates);
   if(copied <= 0) { g_orHigh = 0.0; g_orLow = 0.0; g_rangeReady = false; return; }

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
      // exact token match (avoids substring false-positives); list is comma-separated 3-letter codes
      if(StringFind("," + InpNewsCurrencies + ",", "," + country.currency + ",") < 0) continue;

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

   // trade is fully configured once in OnInit (magic, deviation, filling mode)
   bool ok = (signal == SIGNAL_BUY)
             ? trade.Buy(lot, _Symbol, 0.0, sl, tp, "LondonORB")
             : trade.Sell(lot, _Symbol, 0.0, sl, tp, "LondonORB");

   if(ok)
   {
      g_entryPrice  = entry;
      g_initialRisk = slDist;
      g_tradedToday = true;
      g_entryState  = ENTRY_DONE;
      PrintFormat("LondonORB: %s lot=%s entry=%s SL=%s TP=%s",
                  (signal == SIGNAL_BUY ? "BUY" : "SELL"),
                  DoubleToString(lot, 2), DoubleToString(entry, _Digits),
                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
   }
   else
   {
      // On failure g_tradedToday stays false: the caller may retry on the next
      // bar within the trading window (resilience to transient/requote errors).
      PrintFormat("LondonORB: open FAILED retcode=%d (%s)",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

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

   // Break-even (curSL==0 => no stop set). Return after moving to BE so the
   // trailing block doesn't fire a second modify on the same tick with a stale curSL.
   if(rMult >= InpBE_TriggerR)
   {
      double be = NormalizeDouble(entry, _Digits);
      bool needBE = (type == POSITION_TYPE_BUY)  ? (curSL < be)
                  : (type == POSITION_TYPE_SELL) ? (curSL > be || curSL == 0)
                  : false;
      if(needBE)
      {
         if(!trade.PositionModify(_Symbol, be, curTP) && InpDebugMode)
            PrintFormat("LondonORB: BE modify FAILED retcode=%d (%s)",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
         return;
      }
   }

   // Trailing (curSL==0 => no stop set)
   if(rMult >= InpTrailStartR)
   {
      double dist  = InpTrailDistPoints * _Point;
      double newSL = (type == POSITION_TYPE_BUY) ? (price - dist) : (price + dist);
      newSL = NormalizeDouble(newSL, _Digits);
      bool needTrail = (type == POSITION_TYPE_BUY)  ? (newSL > curSL)
                     : (type == POSITION_TYPE_SELL) ? (newSL < curSL || curSL == 0)
                     : false;
      if(needTrail)
      {
         if(!trade.PositionModify(_Symbol, newSL, curTP) && InpDebugMode)
            PrintFormat("LondonORB: trail modify FAILED retcode=%d (%s)",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
}

//=== LIFECYCLE =====================================================
int OnInit()
{
   g_atrHandle = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("LondonORB: ATR handle init FAILED");
      return INIT_FAILED;
   }

   // EMA handle only needed when the trend filter is enabled
   if(InpUseTrendFilter)
   {
      g_trendEmaHandle = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_trendEmaHandle == INVALID_HANDLE)
      {
         Print("LondonORB: trend EMA handle init FAILED");
         return INIT_FAILED;
      }
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);   // Exness/ECN need IOC/RETURN, not the FOK default

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

void OnDeinit(const int reason)
{
   if(g_atrHandle      != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_trendEmaHandle != INVALID_HANDLE) IndicatorRelease(g_trendEmaHandle);
   EventKillTimer();
   Comment("");
   Print("LondonORB deinitialized. Reason: ", reason);
}

void OnTick()
{
}

void OnTimer()
{
}
//+------------------------------------------------------------------+
