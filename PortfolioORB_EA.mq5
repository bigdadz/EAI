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
// InpSymbolSuffix is appended to every BASE name below AND to InpCorrGroups members,
// so the same base list works on any broker — switch brokers by changing ONLY the suffix:
//   Exness="m"  IUX Standard=".iux"  IUX(other account)="."  plain/none=""
// Active = validated 2-leg JPY+Gold (net-positive every year on IUX, 2024-2026).
// GBPUSD/EURUSD London legs DROPPED (lose every year on IUX). Full 4-leg config for reference:
//   InpSymbols="GBPUSD,EURUSD,USDJPY,XAUUSD" InpORStartHours="6,6,9,12" InpORWindowMins="30,30,30,15" InpMaxSpreadPts="40,40,40,600" InpCorrGroups="GBPUSD,EURUSD"
input string InpSymbolSuffix = ".iux";
input string InpSymbols      = "USDJPY,XAUUSD";  // BASE names (suffix appended)
input string InpORStartHours = "9,12";           // per symbol
input string InpORWindowMins = "30,15";          // per symbol (OR length)
input string InpMaxSpreadPts = "40,600";         // per symbol

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
input string InpCorrGroups   = "";   // BASE names (suffix auto-applied); ; = groups, , = members. e.g. "GBPUSD,EURUSD" when FX legs active; empty for JPY+Gold (uncorrelated).

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

// Append the broker suffix to a BASE symbol name (trims surrounding spaces first),
// so InpSymbols/InpCorrGroups stay broker-agnostic. Suffix "" => base name unchanged.
string WithSuffix(string base)
{
   StringTrimLeft(base);
   StringTrimRight(base);
   return base + InpSymbolSuffix;
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
      g_symbol[i]   = WithSuffix(syms[i]);
      g_orStartH[i] = (int)StringToInteger(shs[i]);
      g_orStartM[i] = 0;
      int win       = (int)StringToInteger(wins[i]);
      if(g_orStartH[i] < 0 || g_orStartH[i] > 23 || win <= 0)
      {
         PrintFormat("PortfolioORB: invalid OR config for %s (start=%d win=%d) — check CSV", g_symbol[i], g_orStartH[i], win);
         return INIT_FAILED;
      }
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
      if(needBE)
      {
         if(!trade.PositionModify(g_symbol[i], be, curTP) && InpDebugMode)
            PrintFormat("PortfolioORB %s: BE modify FAILED retcode=%d (%s)", g_symbol[i],
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
         return;
      }
   }
   if(rMult >= InpTrailStartR)
   {
      double dist  = InpTrailDistPoints * SymPoint(i);
      double newSL = (type == POSITION_TYPE_BUY) ? (price - dist) : (price + dist);
      newSL = NormalizeDouble(newSL, dg);
      bool needTrail = (type == POSITION_TYPE_BUY)  ? (newSL > curSL)
                     : (type == POSITION_TYPE_SELL) ? (newSL < curSL || curSL == 0) : false;
      if(needTrail && !trade.PositionModify(g_symbol[i], newSL, curTP) && InpDebugMode)
         PrintFormat("PortfolioORB %s: trail modify FAILED retcode=%d (%s)", g_symbol[i],
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

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
      for(int m = 0; m < nm; m++) if(WithSuffix(members[m]) == g_symbol[i]) { iInGroup = true; break; }
      if(!iInGroup) continue;
      // i is in this group: scan other members for a same-direction open position
      for(int m = 0; m < nm; m++)
      {
         string mem = WithSuffix(members[m]);
         if(mem == g_symbol[i]) continue;
         if(PositionSelect(mem) && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         {
            long t = PositionGetInteger(POSITION_TYPE);
            ENUM_SIGNAL openDir = (t == POSITION_TYPE_BUY) ? SIGNAL_BUY : SIGNAL_SELL;
            if(openDir == dir) return true;   // same-direction correlated exposure
         }
      }
   }
   return false;
}

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

void ProcessSymbol(int i)
{
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
            if(InpDebugMode) Print("PortfolioORB ", g_symbol[i], ": ARMED ", (sig==SIGNAL_BUY?"BUY":"SELL"));
         }
         else OpenTrade(i, sig);
      }
   }
   else if(g_st[i].entryState == ENTRY_ARMED)
   {
      g_st[i].armedBarsElapsed++;
      if(g_st[i].armedBarsElapsed > InpRetestTimeoutBars)
      {
         g_st[i].entryState = ENTRY_IDLE;
         if(InpDebugMode) Print("PortfolioORB ", g_symbol[i], ": retest timeout — disarmed");
      }
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
         g_st[i].initialRisk      = 0.0;
      }
   }

   // Manage open positions + force-close ALWAYS, regardless of DD-stop state.
   for(int i = 0; i < g_symCount; i++)
   {
      ManageTrailing(i);
      if(InpForceCloseEnable && PastForceClose()) CloseSym(i);
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
