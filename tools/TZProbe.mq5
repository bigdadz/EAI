//+------------------------------------------------------------------+
//| TZProbe.mq5 - infer broker server GMT offset from weekend gaps.   |
//| Run headless in the Strategy Tester over a few weeks on an FX     |
//| symbol; parse "TZ-GAP" lines. The first H1 bar after each weekend |
//| gap is the week-open in SERVER time; compare to the true FX open  |
//| (Sun 21:00 GMT in summer/DST, 22:00 GMT in winter) to get offset. |
//| Also prints a bar-count-by-hour histogram (session boundaries).   |
//+------------------------------------------------------------------+
#property version "1.00"

void OnTick() {}

void OnDeinit(const int reason)
{
   string wd[7] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_H1, 0, 3000, r);
   if(n <= 0) { Print("TZ: no H1 rates for ", _Symbol); return; }

   PrintFormat("TZ-INFO %s H1 bars=%d first=%s last=%s", _Symbol, n,
               TimeToString(r[0].time, TIME_DATE|TIME_MINUTES),
               TimeToString(r[n-1].time, TIME_DATE|TIME_MINUTES));

   // Weekend gaps: first bar after a >=2h gap = week-open in server time.
   for(int k = 1; k < n; k++)
   {
      int gap = (int)(r[k].time - r[k-1].time);
      if(gap >= 7200)
      {
         MqlDateTime a, b; TimeToStruct(r[k-1].time, a); TimeToStruct(r[k].time, b);
         PrintFormat("TZ-GAP %2dh | last %s %s | first %s %s",
            gap/3600,
            wd[a.day_of_week], TimeToString(r[k-1].time, TIME_DATE|TIME_MINUTES),
            wd[b.day_of_week], TimeToString(r[k].time, TIME_DATE|TIME_MINUTES));
      }
   }

   // Hour-of-day histogram (server time): reveals daily session start/end hours.
   int hist[24]; ArrayInitialize(hist, 0);
   for(int k = 0; k < n; k++) { MqlDateTime d; TimeToStruct(r[k].time, d); hist[d.hour]++; }
   string line = "TZ-HIST(server hour:bars) ";
   for(int h = 0; h < 24; h++) line += StringFormat("%02d:%d ", h, hist[h]);
   Print(line);
}
