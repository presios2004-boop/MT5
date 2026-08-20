#property copyright "Copyright 2024, Expert Advisor"
#property link      "https://www.mql5.com"
#property version   "1.03"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_M30; // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;  // Higher Timeframe
input int             InpAvgPeriod   = 30;         // Average Period
input double          InpMaxSpread   = 5.0;        // Max Spread in Pips
input int             InpMagic       = 202600801;  // Magic Number
input double          InpLot         = 0.1;        // Fixed Lot Size

//--- Logic Thresholds (Adjusted for Recovery Factor and Profit Factor)
input double          InpMinBodyRatio = 2.5;       // Increased to filter weak candles
input double          InpMinVolRatio  = 2.0;       // Increased to filter low liquidity
input double          InpTPATRMult    = 10.0;      // Increased to maximize profit per trade
input double          InpSLATRMult    = 1.5;       // Decreased to reduce drawdown

//--- Global Variables
CTrade         m_trade;
CPositionInfo  m_position;
int            handle_atr_exec;
int            handle_atr_high;
double         m_pips_multiplier;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(30); 

   if(_Digits == 3 || _Digits == 5)
      m_pips_multiplier = 10.0 * _Point;
   else
      m_pips_multiplier = _Point;

   handle_atr_exec = iATR(_Symbol, InpExecutionTF, 14);
   handle_atr_high = iATR(_Symbol, InpHigherTF, 14);
   
   if(handle_atr_exec == INVALID_HANDLE || handle_atr_high == INVALID_HANDLE)
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
   IndicatorRelease(handle_atr_exec);
   IndicatorRelease(handle_atr_high);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. New Bar Check
   static datetime g_last_bar = 0;
   datetime t = iTime(_Symbol, InpExecutionTF, 0);
   if(t == g_last_bar) 
   { 
      ManageOpenPosition(); 
      return; 
   }
   g_last_bar = t;

   // 2. Check Spread
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(spread > InpMaxSpread * m_pips_multiplier) return;

   // 3. Check Position Count (Max 1)
   bool has_position = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == InpMagic && m_position.Symbol() == _Symbol)
         {
            has_position = true;
            break;
         }
      }
   }

   // 4. Get Data
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpExecutionTF, 0, InpAvgPeriod + 2, rates) < InpAvgPeriod + 2) return;

   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(handle_atr_exec, 0, 1, 1, atr_buffer) < 1) return;
   double current_atr = atr_buffer[0];

   double atr_high_buffer[];
   ArraySetAsSeries(atr_high_buffer, true);
   if(CopyBuffer(handle_atr_high, 0, 1, 1, atr_high_buffer) < 1) return;
   double higher_atr = atr_high_buffer[0];

   // 5. Calculate Ratios
   double current_body = MathAbs(rates[1].open - rates[1].close);
   double sum_body = 0;
   double sum_vol = 0;
   for(int i=2; i<=InpAvgPeriod+1; i++)
   {
      sum_body += MathAbs(rates[i].open - rates[i].close);
      sum_vol += (double)rates[i].tick_volume;
   }
   double avg_body = sum_body / InpAvgPeriod;
   double avg_vol = sum_vol / InpAvgPeriod;

   if(avg_body == 0 || avg_vol == 0) return;

   double body_ratio = current_body / avg_body;
   double vol_ratio = (double)rates[1].tick_volume / avg_vol;

   // 6. Round Number Logic
   double price = rates[1].close;
   double round_low = MathFloor(price * 2.0) / 2.0; 
   double round_high = round_low + 0.5;
   
   // 7. Higher TF Direction
   MqlRates rates_high[];
   ArraySetAsSeries(rates_high, true);
   if(CopyRates(_Symbol, InpHigherTF, 1, 2, rates_high) < 2) return;
   bool higher_tf_up = (rates_high[0].close > rates_high[1].close);
   bool higher_tf_down = (rates_high[0].close < rates_high[1].close);

   // 8. Breakout Detection
   double highest_prev = rates[2].high;
   double lowest_prev = rates[2].low;
   for(int i=2; i<=11; i++) {
      if(rates[i].high > highest_prev) highest_prev = rates[i].high;
      if(rates[i].low < lowest_prev) lowest_prev = rates[i].low;
   }

   // 9. Entry Logic
   if(!has_position)
   {
      // BUY
      bool round_up = (rates[2].close <= round_low && rates[1].close > round_low);
      if(rates[1].close > highest_prev && round_up && body_ratio > InpMinBodyRatio && vol_ratio > InpMinVolRatio && higher_tf_up)
      {
         double sl = MathMin(lowest_prev, rates[1].close - (current_atr * InpSLATRMult));
         double tp = rates[1].close + (current_atr * InpTPATRMult);
         if(m_trade.Buy(InpLot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "RoundUp"))
         {
            if(!m_trade.ResultRetcode()) Print("Buy Error: ", m_trade.ResultRetcodeDescription());
         }
      }
      // SELL
      bool round_down = (rates[2].close >= round_high && rates[1].close < round_high);
      if(rates[1].close < lowest_prev && round_down && body_ratio > InpMinBodyRatio && vol_ratio > InpMinVolRatio && higher_tf_down)
      {
         double sl = MathMax(highest_prev, rates[1].close + (current_atr * InpSLATRMult));
         double tp = rates[1].close - (current_atr * InpTPATRMult);
         if(m_trade.Sell(InpLot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "RoundDown"))
         {
            if(!m_trade.ResultRetcode()) Print("Sell Error: ", m_trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Function to manage trailing stop                                |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(handle_atr_exec, 0, 1, 1, atr_buffer) < 1) return;
   double current_atr = atr_buffer[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == InpMagic && m_position.Symbol() == _Symbol)
         {
            double pos_entry = m_position.PriceOpen();
            double pos_current = m_position.PriceCurrent();
            double pos_sl = m_position.StopLoss();
            
            if(m_position.PositionType() == POSITION_TYPE_BUY)
            {
               if(pos_current - pos_entry > current_atr * 1.5)
               {
                  double new_sl = pos_current - (current_atr * 0.5);
                  if(new_sl > pos_sl + _Point) m_trade.PositionModify(m_position.Ticket(), new_sl, m_position.TakeProfit());
               }
            }
            else if(m_position.PositionType() == POSITION_TYPE_SELL)
            {
               if(pos_entry - pos_current > current_atr * 1.5)
               {
                  double new_sl = pos_current + (current_atr * 0.5);
                  if(new_sl < pos_sl - _Point || pos_sl == 0) m_trade.PositionModify(m_position.Ticket(), new_sl, m_position.TakeProfit());
               }
            }
         }
      }
   }
}
