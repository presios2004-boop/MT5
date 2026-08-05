//+------------------------------------------------------------------+
//|                                              TrendFollowerEA.mq5 |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

// === input parameters ===
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;    // Higher Timeframe
input int             InpADXPeriod   = 30;           // ADX Period (Increased to reduce trades)
input int             InpADXThreshold= 35;           // ADX Threshold (Increased for stricter filter)
input double          InpSARStep     = 0.02;         // PSAR Step
input double          InpSARMax      = 0.2;          // PSAR Maximum
input int             InpATRPeriod   = 14;           // ATR Period for SL/Trailing
input double          InpSLMultiplier= 3.0;          // SL ATR Multiplier (Increased for stability)
input double          InpTSTrigger   = 2.0;          // Trailing Trigger ATR Multiplier (Increased)
input double          InpTPMultiplier= 5.0;          // TP ATR Multiplier (Increased for RR)
input double          InpLotSize     = 0.1;          // Fixed Lot Size
input int             InpMaxSpread   = 50;           // Max Spread in Points (5.0 pips)
input int             InpMagic       = 202600801;    // Magic Number
input int             InpSlippage    = 30;           // Slippage in Points

// === global variables ===
CTrade   trade;
int      handleADX;
int      handleSAR;
int      handleATR;
double   pips_multiplier;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   
   handleADX = iADX(_Symbol, InpExecutionTF, InpADXPeriod);
   handleSAR = iSAR(_Symbol, InpExecutionTF, InpSARStep, InpSARMax);
   handleATR = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
   
   if(handleADX == INVALID_HANDLE || handleSAR == INVALID_HANDLE || handleATR == INVALID_HANDLE)
   {
      Print("Failed to create handles");
      return(INIT_FAILED);
   }
   
   pips_multiplier = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleADX);
   IndicatorRelease(handleSAR);
   IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Check Spread
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > (double)InpMaxSpread) return;

   // 2. Check existing positions
   bool has_position = false;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            has_position = true;
            break;
         }
      }
   }

   // 3. Get Indicator Data
   double adx_buf[];
   double sar_buf[];
   double atr_buf[];
   ArraySetAsSeries(adx_buf, true);
   ArraySetAsSeries(sar_buf, true);
   ArraySetAsSeries(atr_buf, true);

   if(CopyBuffer(handleADX, 0, 0, 2, adx_buf) <= 0) return;
   if(CopyBuffer(handleSAR, 0, 0, 2, sar_buf) <= 0) return;
   if(CopyBuffer(handleATR, 0, 0, 2, atr_buf) <= 0) return;

   double current_adx = adx_buf[0];
   double current_sar = sar_buf[0];
   double current_atr = atr_buf[0];
   double current_bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // 4. SuperTrend Logic (Higher TF)
   bool st_uptrend = false;
   double st_val = 0;
   double high_d1[], low_d1[], close_d1[], atr_d1[];
   ArraySetAsSeries(high_d1, true); 
   ArraySetAsSeries(low_d1, true); 
   ArraySetAsSeries(close_d1, true); 
   ArraySetAsSeries(atr_d1, true);
   
   int hATR_D1 = iATR(_Symbol, InpHigherTF, 10);
   if(hATR_D1 == INVALID_HANDLE) return;

   if(CopyHigh(_Symbol, InpHigherTF, 0, 20, high_d1) <= 0 || 
      CopyLow(_Symbol, InpHigherTF, 0, 20, low_d1) <= 0 || 
      CopyClose(_Symbol, InpHigherTF, 0, 20, close_d1) <= 0 ||
      CopyBuffer(hATR_D1, 0, 0, 20, atr_d1) <= 0) 
   {
      IndicatorRelease(hATR_D1);
      return;
   }

   double st_upper = 0, st_lower = 0;
   bool st_up = true;
   double mult = 3.0;
   
   for(int i=19; i>=0; i--) {
      double hl2 = (high_d1[i] + low_d1[i])/2.0;
      double up = hl2 + mult * atr_d1[i];
      double lo = hl2 - mult * atr_d1[i];
      
      if(close_d1[i] > st_upper) st_up = true;
      else if(close_d1[i] < st_lower) st_up = false;
      
      st_upper = (up < st_upper || (i < 19 && close_d1[i+1] > st_upper)) ? up : st_upper;
      st_lower = (lo > st_lower || (i < 19 && close_d1[i+1] < st_lower)) ? lo : st_lower;
   }
   st_uptrend = (close_d1[0] > st_lower);
   st_val = st_uptrend ? st_lower : st_upper;
   IndicatorRelease(hATR_D1);

   // 5. Trailing Stop Logic
   if(has_position)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
               long type = PositionGetInteger(POSITION_TYPE);
               double pos_sl = PositionGetDouble(POSITION_SL);
               double pos_open = PositionGetDouble(POSITION_PRICE_OPEN);
               double pos_tp = PositionGetDouble(POSITION_TP);
               
               if(type == POSITION_TYPE_BUY)
               {
                  double profit_atr = (current_bid - pos_open) / current_atr;
                  if(profit_atr >= InpTSTrigger)
                  {
                     double new_sl = current_bid - (current_atr * 1.5);
                     if(new_sl > pos_sl + (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10))
                     {
                        trade.PositionModify(ticket, new_sl, pos_tp);
                     }
                  }
               }
               else if(type == POSITION_TYPE_SELL)
               {
                  double profit_atr = (pos_open - current_ask) / current_atr;
                  if(profit_atr >= InpTSTrigger)
                  {
                     double new_sl = current_ask + (current_atr * 1.5);
                     if(new_sl < pos_sl - (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10) || pos_sl == 0)
                     {
                        trade.PositionModify(ticket, new_sl, pos_tp);
                     }
                  }
               }
            }
         }
      }
   }
   else // 6. Entry Logic
   {
      // Trend Filter: ADX > Threshold AND SuperTrend matches direction
      if(current_adx > InpADXThreshold)
      {
         // Buy Condition: Price > SAR AND SuperTrend is Up
         if(current_bid > current_sar && st_uptrend)
         {
            double sl = current_bid - (current_atr * InpSLMultiplier);
            double tp = current_bid + (current_atr * InpTPMultiplier);
            if(trade.Buy(InpLotSize, _Symbol, current_ask, sl, tp))
            {
               Print("Buy Order Sent");
            }
         }
         // Sell Condition: Price < SAR AND SuperTrend is Down
         else if(current_ask < current_sar && !st_uptrend)
         {
            double sl = current_ask + (current_atr * InpSLMultiplier);
            double tp = current_ask - (current_atr * InpTPMultiplier);
            if(trade.Sell(InpLotSize, _Symbol, current_bid, sl, tp))
            {
               Print("Sell Order Sent");
            }
         }
      }
   }
}

// Helper function to select position by magic
bool PositionSelectByMagic(string symbol, int magic)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == symbol)
            return true;
      }
   }
   return false;
}