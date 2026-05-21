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

void OnTick()  { }
void OnTimer() { }
