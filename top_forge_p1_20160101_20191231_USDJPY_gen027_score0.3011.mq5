//+------------------------------------------------------------------+
//|                                         HurstTrendFollower.mq5   |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024, MQL5 Expert"
#property link      "https://www.mql5.com"
#property version   "1.05"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_M30; // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;  // Higher Timeframe
input int             InpHurstPeriod = 300;        // Hurst Exponent Period
input int             InpEMA_Exec    = 100;        // Execution EMA Period
input int             InpEMA_High    = 250;        // Higher EMA Period
input int             InpATR_Period  = 14;         // ATR Period
input int             InpAvgATR_Per  = 300;        // Average ATR Period
input double          InpLotSize    = 0.1;         // Fixed Lot Size
input double          InpMaxSpread  = 5.0;         // Max Spread (Pips)
input int             InpMagic      = 202600801;   // Magic Number
input int             InpSlippage   = 30;          // Slippage (Points)

//--- Global Variables
int      handle_ema_exec;
int      handle_ema_high;
int      handle_atr_exec;
CTrade   trade;
CPositionInfo pos_info;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);

   handle_ema_exec = iMA(_Symbol, InpExecutionTF, InpEMA_Exec, 0, MODE_EMA, PRICE_CLOSE);
   handle_ema_high = iMA(_Symbol, InpHigherTF, InpEMA_High, 0, MODE_EMA, PRICE_CLOSE);
   handle_atr_exec = iATR(_Symbol, InpExecutionTF, InpATR_Period);

   if(handle_ema_exec == INVALID_HANDLE || handle_ema_high == INVALID_HANDLE || handle_atr_exec == INVALID_HANDLE)
   {
      Print("Error initializing indicators");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handle_ema_exec);
   IndicatorRelease(handle_ema_high);
   IndicatorRelease(handle_atr_exec);
}

//+------------------------------------------------------------------+
//| Calculate Hurst Exponent                                        |
//+------------------------------------------------------------------+
double CalculateHurst(int period)
{
   double close_prices[];
   ArraySetAsSeries(close_prices, true);
   if(CopyClose(_Symbol, InpExecutionTF, 1, period, close_prices) < period) return 0.5;

   int n = period;
   double mean = 0;
   for(int i=0; i<n; i++) mean += close_prices[i];
   mean /= n;

   double std_dev = 0;
   for(int i=0; i<n; i++) std_dev += MathPow(close_prices[i] - mean, 2);
   std_dev = MathSqrt(std_dev / n);

   if(std_dev == 0) return 0.5;

   double max_val = -1e18;
   double min_val = 1e18;
   double cum_sum = 0;
   
   for(int i=0; i<n; i++)
   {
      double diff = close_prices[i] - mean;
      cum_sum += diff;
      if(cum_sum > max_val) max_val = cum_sum;
      if(cum_sum < min_val) min_val = cum_sum;
   }
   
   double rs = (max_val - min_val) / std_dev;
   double hurst = MathLog(rs) / MathLog(n);
   
   if(hurst > 1.0) hurst = 1.0;
   if(hurst < 0.0) hurst = 0.0;
   
   return hurst;
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop                                             |
//+------------------------------------------------------------------+
void ManageOpenPosition(double atr_1, double point)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(pos_info.SelectByIndex(i))
      {
         if(pos_info.Magic() == InpMagic && pos_info.Symbol() == _Symbol)
         {
            double current_sl = pos_info.StopLoss();
            double open_price = pos_info.PriceOpen();
            double current_price = (pos_info.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            if(pos_info.PositionType() == POSITION_TYPE_BUY)
            {
               if(current_price - open_price > atr_1 * 1.5)
               {
                  double new_sl = current_price - (atr_1 * 1.0);
                  if(new_sl > current_sl + (point * 10)) 
                  {
                     trade.PositionModify(pos_info.Ticket(), new_sl, pos_info.TakeProfit());
                  }
               }
            }
            else if(pos_info.PositionType() == POSITION_TYPE_SELL)
            {
               if(open_price - current_price > atr_1 * 1.5)
               {
                  double new_sl = current_price + (atr_1 * 1.0);
                  if(current_sl == 0 || new_sl < current_sl - (point * 10))
                  {
                     trade.PositionModify(pos_info.Ticket(), new_sl, pos_info.TakeProfit());
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. New Bar Check
   static datetime g_last_bar = 0;
   datetime t = iTime(_Symbol, InpExecutionTF, 0);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Get ATR for trailing stop even if not a new bar
   double atr_buf_single[];
   if(CopyBuffer(handle_atr_exec, 0, 1, 1, atr_buf_single) < 1) return;
   double atr_1 = atr_buf_single[0];

   if(t == g_last_bar) 
   { 
      ManageOpenPosition(atr_1, point); 
      return; 
   }
   g_last_bar = t;

   // 2. Check Spread
   long spread_points = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spread_val = spread_points * point;
   double pips_multiplier = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
   double current_spread_pips = spread_val / (point * pips_multiplier);

   // 3. Check Position Count
   int pos_count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(pos_info.SelectByIndex(i))
      {
         if(pos_info.Magic() == InpMagic && pos_info.Symbol() == _Symbol)
            pos_count++;
      }
   }

   // 4. Get Indicator Data (Using index 1 for closed bar)
   double ema_exec_val[1];
   double ema_high_val[1];
   double atr_val[1];

   if(CopyBuffer(handle_ema_exec, 0, 1, 1, ema_exec_val) < 1) return;
   if(CopyBuffer(handle_ema_high, 0, 1, 1, ema_high_val) < 1) return;
   if(CopyBuffer(handle_atr_exec, 0, 1, 1, atr_val) < 1) return;

   double close_1 = iClose(_Symbol, InpExecutionTF, 1);
   double current_atr_1 = atr_val[0];

   // Calculate Average ATR
   double sum_atr = 0;
   double atr_history[];
   if(CopyBuffer(handle_atr_exec, 0, 1, InpAvgATR_Per, atr_history) > 0)
   {
      int copied = ArraySize(atr_history);
      for(int i=0; i<copied; i++) sum_atr += atr_history[i];
      sum_atr /= copied;
   }
   double avg_atr = (sum_atr > 0) ? sum_atr : current_atr_1;

   double hurst = CalculateHurst(InpHurstPeriod);

   // 5. Entry Logic
   if(pos_count == 0)
   {
      if(current_spread_pips <= InpMaxSpread)
      {
         // BUY Condition (Strict thresholds: Hurst > 0.75, ATR > 2.0 * AvgATR)
         if(hurst > 0.75 && 
            close_1 > ema_exec_val[0] && 
            close_1 > ema_high_val[0] && 
            current_atr_1 > avg_atr * 2.0)
         {
            double sl = close_1 - (current_atr_1 * 2.0);
            double tp = close_1 + (current_atr_1 * 5.0);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Hurst Buy");
         }
         
         // SELL Condition (Strict thresholds: Hurst > 0.75, ATR > 2.0 * AvgATR)
         if(hurst > 0.75 && 
            close_1 < ema_exec_val[0] && 
            close_1 < ema_high_val[0] && 
            current_atr_1 > avg_atr * 2.0)
         {
            double sl = close_1 + (current_atr_1 * 2.0);
            double tp = close_1 - (current_atr_1 * 5.0);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Hurst Sell");
         }
      }
   }
   
   // Initial trailing check for the new bar
   ManageOpenPosition(current_atr_1, point);
}
