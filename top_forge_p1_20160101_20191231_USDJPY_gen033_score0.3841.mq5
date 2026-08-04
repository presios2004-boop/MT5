//+------------------------------------------------------------------+
//|                                         ADX_Dual_Regime_Hybrid.mq5|
//|                                  Copyright 2024, MQL5 Expert Dev |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;    // Higher Timeframe
input double          InpLotSize     = 0.1;          // Fixed Lot Size
input int             InpMagicNum    = 202600801;    // Magic Number
input double          InpMaxSpread   = 5.0;          // Max Spread (Pips)
input int             InpSlippage    = 30;           // Slippage (Points)

//--- Indicator Parameters
input int             InpADXPeriod   = 25;           // ADX Period
input int             InpBBPeriod    = 20;           // BB Period
input double          InpBBDev       = 2.0;          // BB Deviation
input int             InpEMAPeriod   = 50;           // EMA Period
input int             InpATRPeriod   = 14;           // ATR Period
input int             InpRSIPeriod   = 14;           // RSI Period
input int             InpATRMAPeriod = 200;          // ATR MA Period
input int             InpStateMinBars = 3;           // Min Bars in State

//--- Enums
enum ENUM_REGIME {
   STATE_NONE,
   STATE_TREND,
   STATE_RANGE
};

//--- Global Variables
int      hADX, hBB, hEMA, hATR, hRSI;
CTrade   m_trade;
CPositionInfo m_pos;
double   m_pips_multiplier;

//--- Regime State
ENUM_REGIME current_regime = STATE_NONE;
int         g_bars_in_state = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNum);
   m_trade.SetDeviationInPoints(InpSlippage);
   
   // Handle pips multiplier
   if(_Digits == 3 || _Digits == 5) m_pips_multiplier = 10.0 * _Point;
   else m_pips_multiplier = _Point;

   // Initialize Handles
   hADX    = iADX(_Symbol, InpExecutionTF, InpADXPeriod);
   hBB     = iBands(_Symbol, InpExecutionTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hEMA    = iMA(_Symbol, InpHigherTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hATR    = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
   hRSI    = iRSI(_Symbol, InpExecutionTF, InpRSIPeriod, PRICE_CLOSE);
   
   if(hADX == INVALID_HANDLE || hBB == INVALID_HANDLE || hEMA == INVALID_HANDLE || 
      hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE)
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
   IndicatorRelease(hADX);
   IndicatorRelease(hBB);
   IndicatorRelease(hEMA);
   IndicatorRelease(hATR);
   IndicatorRelease(hRSI);
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
      ManageTrailingStop(); 
      return; 
   }
   g_last_bar = t;

   // 2. Check Spread
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(spread > InpMaxSpread * m_pips_multiplier) return;

   // 3. Update Regime (with State Cooldown)
   UpdateRegime();

   // 4. Manage Existing Positions
   ManageTrailingStop();

   // 5. Check for New Entry
   if(!PositionExists())
   {
      CheckEntry();
   }
}

//+------------------------------------------------------------------+
//| Update Market Regime                                             |
//+------------------------------------------------------------------+
void UpdateRegime()
{
   double adx_buf[4];
   // Use index 1, 2, 3 (closed bars)
   if(CopyBuffer(hADX, 0, 1, 3, adx_buf) < 3) return;

   // In CopyBuffer with start_pos=1, index 0 is bar 1, index 1 is bar 2, index 2 is bar 3
   double val1 = adx_buf[2]; // Bar 1 (most recent closed)
   double val2 = adx_buf[1]; // Bar 2
   double val3 = adx_buf[0]; // Bar 3

   ENUM_REGIME next_regime = current_regime;

   if(current_regime == STATE_NONE)
   {
      if(val1 > 25 && val1 > val2 && val2 > val3) next_regime = STATE_TREND;
      else if(val1 < 20 && val1 <= val2 && val2 <= val3) next_regime = STATE_RANGE;
   }
   else if(current_regime == STATE_TREND)
   {
      if(val1 < 20) next_regime = STATE_RANGE;
   }
   else if(current_regime == STATE_RANGE)
   {
      if(val1 > 25 && val1 > val2 && val2 > val3) next_regime = STATE_TREND;
   }

   if(next_regime != current_regime)
   {
      if(g_bars_in_state >= InpStateMinBars)
      {
         current_regime = next_regime;
         g_bars_in_state = 0;
      }
   }
   else
   {
      g_bars_in_state++;
   }
}

//+------------------------------------------------------------------+
//| Check Entry Conditions                                           |
//+------------------------------------------------------------------+
void CheckEntry()
{
   // Volatility Filter
   double atr_buf[1];
   if(CopyBuffer(hATR, 0, 1, 1, atr_buf) < 1) return;
   double current_atr = atr_buf[0];

   double atr_history[200];
   if(CopyBuffer(hATR, 0, 1, 200, atr_history) == 200)
   {
      double atr_sum = 0;
      for(int i=0; i<200; i++) atr_sum += atr_history[i];
      double atr_ma = atr_sum / 200.0;
      if(current_atr < atr_ma * 0.7) return; 
   }

   double close_buf[1];
   if(CopyClose(_Symbol, InpExecutionTF, 1, 1, close_buf) < 1) return;
   double price = close_buf[0];

   if(current_regime == STATE_TREND)
   {
      double ema_val[2];
      if(CopyBuffer(hEMA, 0, 1, 2, ema_val) < 2) return;
      // ema_val[1] is bar 1, ema_val[0] is bar 2
      bool ema_rising = ema_val[1] > ema_val[0];
      bool ema_falling = ema_val[1] < ema_val[0];

      double bb_up[1], bb_low[1];
      if(CopyBuffer(hBB, 1, 1, 1, bb_up) < 1) return;
      if(CopyBuffer(hBB, 2, 1, 1, bb_low) < 1) return;

      if(ema_rising && price > ema_val[1] && price > bb_up[0])
      {
         double sl = price - (current_atr * 1.5);
         double tp = price + (current_atr * 1.5 * 2.0);
         m_trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Trend Buy");
      }
      else if(ema_falling && price < ema_val[1] && price < bb_low[0])
      {
         double sl = price + (current_atr * 1.5);
         double tp = price - (current_atr * 1.5 * 2.0);
         m_trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Trend Sell");
      }
   }
   else if(current_regime == STATE_RANGE)
   {
      double bb_up[1], bb_low[1], rsi_buf[1];
      if(CopyBuffer(hBB, 1, 1, 1, bb_up) < 1) return;
      if(CopyBuffer(hBB, 2, 1, 1, bb_low) < 1) return;
      if(CopyBuffer(hRSI, 0, 1, 1, rsi_buf) < 1) return;

      if(price < bb_low[0] && rsi_buf[0] < 30)
      {
         double sl = price - (current_atr * 1.5);
         double tp = price + (current_atr * 1.5 * 2.0);
         m_trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Range Buy");
      }
      else if(price > bb_up[0] && rsi_buf[0] > 70)
      {
         double sl = price + (current_atr * 1.5);
         double tp = price - (current_atr * 1.5 * 2.0);
         m_trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Range Sell");
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop Logic                                              |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(current_regime != STATE_TREND) return;

   double atr_buf[1];
   if(CopyBuffer(hATR, 0, 1, 1, atr_buf) < 1) return;
   double atr = atr_buf[0];

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(m_pos.SelectByIndex(i))
      {
         if(m_pos.Magic() == InpMagicNum && m_pos.Symbol() == _Symbol)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double price = (m_pos.PositionType() == POSITION_TYPE_BUY) ? bid : ask;
            double open_price = m_pos.PriceOpen();
            double current_sl = m_pos.StopLoss();

            if(m_pos.PositionType() == POSITION_TYPE_BUY)
            {
               if(bid - open_price > atr * 1.5)
               {
                  double new_sl = bid - (atr * 1.0);
                  if(new_sl > current_sl + _Point) 
                     m_trade.PositionModify(m_pos.Ticket(), new_sl, m_pos.TakeProfit());
               }
            }
            else if(m_pos.PositionType() == POSITION_TYPE_SELL)
            {
               if(open_price - ask > atr * 1.5)
               {
                  double new_sl = ask + (atr * 1.0);
                  if(current_sl == 0 || new_sl < current_sl - _Point)
                     m_trade.PositionModify(m_pos.Ticket(), new_sl, m_pos.TakeProfit());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Check if position exists                                 |
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(m_pos.SelectByIndex(i))
      {
         if(m_pos.Magic() == InpMagicNum && m_pos.Symbol() == _Symbol) return true;
      }
   }
   return false;
}
