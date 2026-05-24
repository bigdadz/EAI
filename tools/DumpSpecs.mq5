//+------------------------------------------------------------------+
//| DumpSpecs.mq5 - utility: print contract/volume/tick specs for a   |
//| fixed list of symbols, used to verify real broker (IUX) values    |
//| for position-sizing math. Writes a CSV to the COMMON Files folder  |
//| (Terminal\Common\Files\symbol_specs.csv) AND prints to the log.    |
//| Run headless in the Strategy Tester on any valid symbol; exits.    |
//+------------------------------------------------------------------+
#property version "1.00"

// Symbols to probe (IUX Standard => .iux suffix). The chart symbol is added too.
string g_symbols[] = { "GBPUSD.iux", "EURUSD.iux", "USDJPY.iux", "XAUUSD.iux", "AUDJPY.iux", "AUDUSD.iux" };

void DumpOne(int fh, string sym)
{
   if(!SymbolSelect(sym, true))
   {
      PrintFormat("SPEC %s NOT_AVAILABLE", sym);
      FileWrite(fh, sym, "NOT_AVAILABLE");
      return;
   }

   double volMin   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double volMax    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double volStep   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double contract  = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   double point     = SymbolInfoDouble(sym, SYMBOL_POINT);
   long   digits    = SymbolInfoInteger(sym, SYMBOL_DIGITS);
   long   stopsLvl  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double bid       = SymbolInfoDouble(sym, SYMBOL_BID);

   double valuePerPoint = (tickSize > 0) ? tickValue * (point / tickSize) : 0.0;

   PrintFormat("SPEC %s | bid=%.5f digits=%d point=%.8f | volMin=%.4f step=%.4f volMax=%.2f | tickValue=%.5f tickSize=%.8f contract=%.2f | valuePerPoint=%.6f stopsLevel=%d",
               sym, bid, (int)digits, point, volMin, volStep, volMax,
               tickValue, tickSize, contract, valuePerPoint, (int)stopsLvl);

   FileWrite(fh, sym, bid, digits, point, volMin, volStep, volMax,
             tickValue, tickSize, contract, valuePerPoint, stopsLvl);
}

int OnInit()
{
   Print("SPEC_BEGIN");
   int fh = FileOpen("symbol_specs.csv", FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(fh == INVALID_HANDLE)
      PrintFormat("SPEC file open FAILED err=%d (printing to log only)", GetLastError());
   else
      FileWrite(fh, "symbol", "bid", "digits", "point", "volMin", "volStep",
                "volMax", "tickValue", "tickSize", "contract", "valuePerPoint", "stopsLevel");

   // chart symbol first, then the fixed probe list
   DumpOne(fh, _Symbol);
   for(int i = 0; i < ArraySize(g_symbols); i++)
      DumpOne(fh, g_symbols[i]);

   if(fh != INVALID_HANDLE) FileClose(fh);
   Print("SPEC_END");
   ExpertRemove();
   return INIT_SUCCEEDED;
}
void OnTick() {}
