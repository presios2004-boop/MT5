//+------------------------------------------------------------------+
//|                                     HurstRegimeAdaptiveDual.mq5 |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H1;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H4;    // Higher Timeframe
input int             InpHurstPeriod = 250;          // Hurst Exponent Period (Increased to reduce noise)
input int             InpBBPeriod    = 40;           // Bollinger Bands Period (Increased to reduce noise)
input double          InpBBDev      = 2.8;           // Bollinger Bands Deviation (Increased for strictness)
input int             InpATRPeriod   = 14;           // ATR Period
input int             InpRSIPeriod   = 14;           // RSI Period
input int             InpStateMinBars = 18;          // Min Bars in State (Increased to prevent rapid switching)
input double          InpLotSize    = 0.1;           // Fixed Lot Size
input int             InpMagic      = 202600801;     // Magic Number
input double          InpMaxSpread  = 5.0;           // Max Spread (Pips)
input int             InpSlippage   = 30;            // Slippage (Points)

//--- Enums
enum ENUM_STATE
{
   STATE_RANGE,
   STATE_TREND
};

//--- Global Variables
int      handleBB, handleATR, handleRSI;
CTrade   trade;
double   pips_multiplier;
ENUM_STATE g_state = STATE_RANGE;
int        g_bars_in_state = 0;
datetime   g_last_bar = 0;

//--- Hurst Calculation Function
double CalculateHurst(ENUM_TIMEFRAMES tf, int period)
{
   double close_prices[];
   ArraySetAsSeries(close_prices, true);
   if(CopyClose(_Symbol, tf, 0, period + 1, close_prices) < period) return 0.5;

   double log_returns[];
   ArrayResize(log_returns, period - 1);
   for(int i = 0; i < period - 1; i++)
   {
      log_returns[i] = MathLog(close_prices[i] / close_prices[i+1]);
   }

   double mean_ret = 0;
   for(int i = 0; i < period - 1; i++) mean_ret += log_returns[i];
   mean_ret /= (period - 1);

   double cum_sum[];
   ArrayResize(cum_sum, period - 1);
   double current_sum = 0;
   for(int i = 0; i < period - 1; i++)
   {
      current_sum += (log_returns[i] - mean_ret);
      cum_sum[i] = current_sum;
   }

   double max_val = cum_sum[0], min_val = cum_sum[0];
   for(int i = 1; i < period - 1; i++)
   {
      if(cum_sum[i] > max_val) max_val = cum_sum[i];
      if(cum_sum[i] < min_val) min_val = cum_sum[i];
   }

   double R = max_val - min_val;
   double S = 0;
   for(int i = 0; i < period - 1; i++) S += MathAbs(cum_sum[i]);
   S /= (period - 1);

   if(R <= 0 || S <= 0) return 0.5;
   
   double hurst = MathLog(R / S) / MathLog(period); 
   return MathMax(0.0, MathMin(1.0, 0.5 + (hurst * 0.5))); 
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);

   pips_multiplier = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;

   handleBB = iBands(_Symbol, InpExecutionTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   handleATR = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
   handleRSI = iRSI(_Symbol, InpExecutionTF, InpRSIPeriod, PRICE_CLOSE);

   if(handleBB == INVALID_HANDLE || handleATR == INVALID_HANDLE || handleRSI == INVALID_HANDLE)
   {
      Print("Error initializing indicators");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleBB);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleRSI);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. New Bar Check
   datetime t = iTime(_Symbol, InpExecutionTF, 0);
   if(t == g_last_bar) 
   { 
      ManageTrailingStop(); 
      return; 
   }
   g_last_bar = t;

   // 2. Check Spread
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(spread > InpMaxSpread * _Point * pips_multiplier) return;

   // 3. Check Position Count
   if(PositionSelectByMagic(InpMagic)) 
   {
      ManageTrailingStop();
      return; 
   }

   // 4. Data Buffers (Using index 1 for closed bar stability)
   double upperBB[], lowerBB[], close_prices[], rsi_val[], atr_val[];
   ArraySetAsSeries(upperBB, true);
   ArraySetAsSeries(lowerBB, true);
   ArraySetAsSeries(close_prices, true);
   ArraySetAsSeries(rsi_val, true);
   ArraySetAsSeries(atr_val, true);

   if(CopyBuffer(handleBB, 1, 1, 2, upperBB) < 2) return;
   if(CopyBuffer(handleBB, 2, 1, 2, lowerBB) < 2) return;
   if(CopyClose(_Symbol, InpExecutionTF, 1, 3, close_prices) < 3) return;
   if(CopyBuffer(handleRSI, 0, 1, 2, rsi_val) < 2) return;
   if(CopyBuffer(handleATR, 0, 1, 200, atr_val) < 200) return;

   // 5. Hurst and Regime Detection
   double hurst = CalculateHurst(InpExecutionTF, InpHurstPeriod);
   
   ENUM_STATE next_state = g_state;
   // Tightened thresholds to reduce regime switching frequency and filter noise
   if(hurst > 0.65) next_state = STATE_TREND;
   else if(hurst < 0.35) next_state = STATE_RANGE;

   if(next_state != g_state)
   {
      if(g_bars_in_state >= InpStateMinBars)
      {
         g_state = next_state;
         g_bars_in_state = 0;
      }
      else
      {
         g_bars_in_state++;
      }
   }
   else
   {
      g_bars_in_state++;
   }

   // 6. ATR Average Calculation
   double sum_atr = 0;
   for(int i=0; i<200; i++) sum_atr += atr_val[i];
   double avg_atr = sum_atr / 200.0;

   // 7. Logic Execution
   if(g_state == STATE_TREND)
   {
      // BUY: Close[1] > UpperBB[1] AND Close[2] <= UpperBB[2]
      if(close_prices[0] > upperBB[0] && close_prices[1] <= upperBB[1])
      {
         // Increased TP for Trend mode to capture larger moves (RR ratio improvement)
         double sl = close_prices[0] - (atr_val[0] * 2.5);
         double tp = close_prices[0] + (atr_val[0] * 7.0);
         trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Trend Buy");
      }
      // SELL: Close[1] < LowerBB[1] AND Close[2] >= LowerBB[2]
      else if(close_prices[0] < lowerBB[0] && close_prices[1] >= lowerBB[1])
      {
         double sl = close_prices[0] + (atr_val[0] * 2.5);
         double tp = close_prices[0] - (atr_val[0] * 7.0);
         trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Trend Sell");
      }
   }
   else if(g_state == STATE_RANGE)
   {
      // Volatility Filter: ATR(14) < 0.5 * AvgATR(200) (Tightened to avoid volatile range/whipsaw)
      if(atr_val[0] < 0.5 * avg_atr)
      {
         // BUY: Close[1] < LowerBB[1] AND RSI(14)[1] < 30
         if(close_prices[0] < lowerBB[0] && rsi_val[0] < 30.0)
         {
            double sl = close_prices[0] - (atr_val[0] * 1.5);
            double tp = close_prices[0] + (atr_val[0] * 3.5);
            trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Range Buy");
         }
         // SELL: Close[1] > UpperBB[1] AND RSI(14)[1] > 70
         else if(close_prices[0] > upperBB[0] && rsi_val[0] > 70.0)
         {
            double sl = close_prices[0] + (atr_val[0] * 1.5);
            double tp = close_prices[0] - (atr_val[0] * 3.5);
            trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Range Sell");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop for Trend Mode                              |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!PositionSelectByMagic(InpMagic)) return;
   
   double atr_val[];
   if(CopyBuffer(handleATR, 0, 1, 1, atr_val) < 1) return;
   
   double current_price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   double profit_points = MathAbs(current_price - open_price);
   
   if(profit_points > atr_val[0] * 1.5)
   {
      double new_sl = 0;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double low_prices[];
         ArraySetAsSeries(low_prices, true);
         if(CopyLow(_Symbol, InpExecutionTF, 1, 3, low_prices) >= 3)
         {
            new_sl = low_prices[ArrayMinimum(low_prices)];
            if(new_sl > current_sl && new_sl < current_price)
               trade.PositionModify(_Symbol, new_sl, PositionGetDouble(POSITION_TP));
         }
      }
      else
      {
         double high_prices[];
         ArraySetAsSeries(high_prices, true);
         if(CopyHigh(_Symbol, InpExecutionTF, 1, 3, high_prices) >= 3)
         {
            new_sl = high_prices[ArrayMaximum(high_prices)];
            if((new_sl < current_sl || current_sl == 0) && new_sl > current_price)
               trade.PositionModify(_Symbol, new_sl, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Select Position by Magic Number                          |
//+------------------------------------------------------------------+
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
