#include <Trade\Trade.mqh>

enum ENUM_STATE
{
   STATE_RANGE,
   STATE_TREND
};

// === input parameters ===
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;    // Higher Timeframe
input int             InpADXPeriod   = 25;           // ADX Period
input double          InpAdxEnter    = 25.0;         // ADX Enter Trend (Range -> Trend)
input double          InpAdxExit     = 20.0;         // ADX Exit Trend (Trend -> Range)
input int             InpStateMinBars = 3;           // Min Bars in State
input int             InpBBPeriod    = 20;           // Bollinger Bands Period
input double          InpBBDev       = 2.0;          // Bollinger Bands Deviation
input int             InpATRPeriod   = 14;           // ATR Period
input int             InpRSIPeriod   = 14;           // RSI Period
input int             InpEMAHigher   = 50;           // Higher TF EMA Period
input double          InpLotSize     = 0.1;          // Fixed Lot Size
input int             InpMaxSpread   = 50;           // Max Spread (Points)
input int             InpMagicNum    = 202600801;    // Magic Number
input int             InpSlippage    = 30;           // Slippage (Points)

// === global variables ===
CTrade   trade;
int      handleADX, handleBB, handleATR, handleRSI, handleEMA_Higher;
double   pipsMultiplier;
ENUM_STATE g_state = STATE_RANGE;
int        g_bars_in_state = 0;
datetime   g_last_state_change = 0;

// === Function Prototypes ===
ENUM_STATE DetectRegime(double adx_val);
void ManageTrailingStop(double atr_val);
bool PositionSelectByMagic(long magic);

// === OnInit ===
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);

   handleADX = iADX(_Symbol, InpExecutionTF, InpADXPeriod);
   handleBB  = iBands(_Symbol, InpExecutionTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   handleATR = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
   handleRSI = iRSI(_Symbol, InpExecutionTF, InpRSIPeriod, PRICE_CLOSE);
   handleEMA_Higher = iMA(_Symbol, InpHigherTF, InpEMAHigher, 0, MODE_EMA, PRICE_CLOSE);

   if(handleADX == INVALID_HANDLE || handleBB == INVALID_HANDLE || 
      handleATR == INVALID_HANDLE || handleRSI == INVALID_HANDLE || 
      handleEMA_Higher == INVALID_HANDLE)
   {
      Print("Error initializing indicators");
      return(INIT_FAILED);
   }

   if(_Digits == 3 || _Digits == 5) pipsMultiplier = 10.0;
   else pipsMultiplier = 1.0;

   g_state = STATE_RANGE;
   g_bars_in_state = 0;

   return(INIT_SUCCEEDED);
}

// === OnDeinit ===
void OnDeinit(const int reason)
{
   IndicatorRelease(handleADX);
   IndicatorRelease(handleBB);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleEMA_Higher);
}

// === OnTick ===
void OnTick()
{
   // Trailing Stop Logic
   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(handleATR, 0, 0, 1, atr_buffer) > 0)
   {
      ManageTrailingStop(atr_buffer[0]);
   }

   // Check for new bar on Execution TF
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, InpExecutionTF, 0);
   
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Check Spread
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > (double)InpMaxSpread) return;

   // Check existing positions
   if(PositionSelectByMagic(InpMagicNum)) return;

   // Data Buffers
   double adx[], bbUpper[], bbLower[], atr[], rsi[], emaHigher[], close[], high[], low[];
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(emaHigher, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   if(CopyBuffer(handleADX, 0, 1, 1, adx) < 1) return;
   if(CopyBuffer(handleBB, 1, 1, 1, bbUpper) < 1) return;
   if(CopyBuffer(handleBB, 2, 1, 1, bbLower) < 1) return;
   if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1) return;
   if(CopyBuffer(handleRSI, 0, 1, 1, rsi) < 1) return;
   if(CopyBuffer(handleEMA_Higher, 0, 1, 1, emaHigher) < 1) return;
   if(CopyClose(_Symbol, InpExecutionTF, 1, 1, close) < 1) return;
   if(CopyHigh(_Symbol, InpExecutionTF, 1, 1, high) < 1) return;
   if(CopyLow(_Symbol, InpExecutionTF, 1, 1, low) < 1) return;

   ENUM_STATE currentState = DetectRegime(adx[0]);
   bool isEmaUp = (close[0] > emaHigher[0]);
   bool isEmaDown = (close[0] < emaHigher[0]);

   // Entry Logic
   if(currentState == STATE_TREND)
   {
      if(close[0] > bbUpper[0] && isEmaUp)
      {
         double sl = close[0] - (atr[0] * 1.2); // Reduced SL multiplier for DD control
         double tp = close[0] + (atr[0] * 6.0); // Increased TP multiplier for PF improvement
         if(!trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Trend Buy"))
            Print("Buy Error: ", GetLastError());
      }
      else if(close[0] < bbLower[0] && isEmaDown)
      {
         double sl = close[0] + (atr[0] * 1.2);
         double tp = close[0] - (atr[0] * 6.0);
         if(!trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Trend Sell"))
            Print("Sell Error: ", GetLastError());
      }
   }
   else if(currentState == STATE_RANGE)
   {
      if(low[0] < bbLower[0] && rsi[0] < 30.0)
      {
         double sl = close[0] - (atr[0] * 1.2);
         double tp = close[0] + (atr[0] * 6.0);
         if(!trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Range Buy"))
            Print("Buy Error: ", GetLastError());
      }
      else if(high[0] > bbUpper[0] && rsi[0] > 70.0)
      {
         double sl = close[0] + (atr[0] * 1.2);
         double tp = close[0] - (atr[0] * 6.0);
         if(!trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Range Sell"))
            Print("Sell Error: ", GetLastError());
      }
   }
}

// === Helper Functions ===

ENUM_STATE DetectRegime(double adx_val)
{
   if(g_state == STATE_RANGE && adx_val > InpAdxEnter)
   {
      g_state = STATE_TREND;
      g_bars_in_state = 0;
   }
   else if(g_state == STATE_TREND && adx_val < InpAdxExit)
   {
      g_state = STATE_RANGE;
      g_bars_in_state = 0;
   }
   else
   {
      g_bars_in_state++;
   }
   return g_state;
}

void ManageTrailingStop(double atr_val)
{
   if(!PositionSelectByMagic(InpMagicNum)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   
   // Trailing activation: 1.5 * ATR profit
   double activationDist = atr_val * 1.5;
   
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
   {
      if(currentPrice - openPrice > activationDist)
      {
         double newSL = currentPrice - (atr_val * 1.0);
         if(newSL > currentSL + (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10))
         {
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
   else
   {
      if(openPrice - currentPrice > activationDist)
      {
         double newSL = currentPrice + (atr_val * 1.0);
         if(currentSL == 0 || newSL < currentSL - (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10))
         {
            trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

bool PositionSelectByMagic(long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
      }
   }
   return false;
}
