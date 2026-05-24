//+------------------------------------------------------------------+
//|                                       Test_ORB_Math.mq5    |
//|        Regression checks for PortfolioORB pure arithmetic.          |
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
