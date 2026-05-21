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

//=== LIFECYCLE =====================================================
int OnInit()
{
   g_atrHandle      = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   g_trendEmaHandle = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atrHandle == INVALID_HANDLE || g_trendEmaHandle == INVALID_HANDLE)
   {
      Print("LondonORB: indicator handle init FAILED");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);

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
