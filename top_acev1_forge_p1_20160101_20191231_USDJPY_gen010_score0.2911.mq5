//+------------------------------------------------------------------+
//|                                     SignalPurityExplosion.mq5    |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024"
#property link      "https://www.mql5.com"
#property version   "1.01"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4; // Execution Timeframe
input double           InpLotSize    = 0.1;       // Fixed Lot Size
input int              InpMagicNum   = 202600801; // Magic Number
input double           InpMaxSpread  = 5.0;       // Max Spread in Pips
input int              InpSlippage   = 30;        // Slippage in Points

//--- Indicator Settings (Internal)
input int              InpATRPeriod  = 14;        // ATR Period

//--- Global Variables
CTrade         m_trade;
CPositionInfo  m_position;
int            m_handle_atr;
double         m_pips_multiplier;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNum);
   m_trade.SetDeviationInPoints(InpSlippage);

   // Handle Pips multiplier for 3/5 digit brokers
   double digits = SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      m_pips_multiplier = 10.0 * _Point;
   else
      m_pips_multiplier = _Point;

   // Initialize ATR handle
   m_handle_atr = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
   if(m_handle_atr == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(m_handle_atr);
}

//+------------------------------------------------------------------+
//| Trailing Stop Logic                                              |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   // Use index 1 for stability
   if(CopyBuffer(m_handle_atr, 0, 1, 1, atr_buffer) < 1) return;
   double current_atr = atr_buffer[0];

   double entry_price = m_position.PriceOpen();
   double current_price = (m_position.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double current_sl = m_position.StopLoss();

   if(m_position.PositionType() == POSITION_TYPE_BUY)
   {
      double profit_dist = current_price - entry_price;
      // Trigger trailing when profit > 1.5 * ATR
      if(profit_dist > current_atr * 1.5)
      {
         double new_sl = current_price - (current_atr * 1.0);
         if(new_sl > current_sl + _Point) 
         {
            m_trade.PositionModify(m_position.Ticket(), new_sl, m_position.TakeProfit());
         }
      }
   }
   else if(m_position.PositionType() == POSITION_TYPE_SELL)
   {
      double profit_dist = entry_price - current_price;
      // Trigger trailing when profit > 1.5 * ATR
      if(profit_dist > current_atr * 1.5)
      {
         double new_sl = current_price + (current_atr * 1.0);
         if(current_sl == 0 || new_sl < current_sl - _Point) 
         {
            m_trade.PositionModify(m_position.Ticket(), new_sl, m_position.TakeProfit());
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
   
   // If it's the same bar, only manage existing positions
   if(t == g_last_bar) 
   { 
      // Check if we have a position to manage
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(m_position.SelectByIndex(i))
         {
            if(m_position.Magic() == InpMagicNum && m_position.Symbol() == _Symbol)
            {
               ManageTrailingStop();
               break;
            }
         }
      }
      return; 
   }
   g_last_bar = t;

   // 2. Check Spread
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(spread > InpMaxSpread * m_pips_multiplier) return;

   // 3. Check existing positions (Max 1 position)
   bool has_position = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == InpMagicNum && m_position.Symbol() == _Symbol)
         {
            has_position = true;
            break;
         }
      }
   }

   if(has_position) return;

   // 4. Data Collection (Using index 1 for closed bar)
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpExecutionTF, 1, 25, rates) < 25) return;

   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(m_handle_atr, 0, 1, 1, atr_buffer) < 1) return;
   double current_atr = atr_buffer[0];

   // 5. Calculate Indicators (Based on rates[0] which is the first closed bar in the CopyRates range)
   // Signal_Purity: Abs(Close - Open) / (High - Low)
   double high = rates[0].high;
   double low  = rates[0].low;
   double range = high - low;
   if(range <= 0) return;
   double signal_purity = MathAbs(rates[0].close - rates[0].open) / range;

   // Energy_Acceleration: Current Body / Avg Body of last 20
   double current_body = MathAbs(rates[0].close - rates[0].open);
   double sum_body = 0;
   for(int i = 1; i <= 20; i++)
   {
      sum_body += MathAbs(rates[i].close - rates[i].open);
   }
   double avg_body = sum_body / 20.0;
   double energy_accel = (avg_body > 0) ? (current_body / avg_body) : 0;

   // Level_Distance_Ratio: (Price - MathFloor(Price/0.5)*0.5) / ATR
   double price = rates[0].close;
   double level = MathFloor(price / 0.5) * 0.5;
   double level_dist_ratio = MathAbs(price - level) / current_atr;

   // 6. Entry Logic
   bool buy_condition = (energy_accel > 2.0 && signal_purity > 0.75 && rates[0].close > rates[0].open && level_dist_ratio > 0.2);
   bool sell_condition = (energy_accel > 2.0 && signal_purity > 0.75 && rates[0].close < rates[0].open && level_dist_ratio > 0.2);

   if(buy_condition)
   {
      // Adjusted SL to 1.5 * ATR and TP to 4.0 * ATR for better RF and PF
      double sl_dist = current_atr * 1.5;
      double sl_price = rates[0].close - sl_dist;
      double tp_price = rates[0].close + (current_atr * 4.0);
      
      if(m_trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl_price, tp_price, "SignalPurity_Buy"))
      {
         Print("Buy Order Placed");
      }
   }
   else if(sell_condition)
   {
      // Adjusted SL to 1.5 * ATR and TP to 4.0 * ATR for better RF and PF
      double sl_dist = current_atr * 1.5;
      double sl_price = rates[0].close + sl_dist;
      double tp_price = rates[0].close - (current_atr * 4.0);

      if(m_trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl_price, tp_price, "SignalPurity_Sell"))
      {
         Print("Sell Order Placed");
      }
   }
}
