//+------------------------------------------------------------------+
//|                                     CCI_BB_Regime_Switch.mq5     |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024, MQL5 Expert"
#property link      "https://www.mql5.com"
#property version   "1.02"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H1;   // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H4;   // Higher Timeframe
input double          InpLotSize     = 0.1;         // Fixed Lot Size
input int             InpMagicNum    = 202600801;   // Magic Number
input double          InpMaxSpread   = 5.0;         // Max Spread (Pips)
input int             InpSlippage    = 30;          // Slippage (Points)
input int             InpStateMinBars = 12;         // Min Bars in State (Increased to filter noise)

//--- Indicator Parameters
input int             InpCCIPeriod   = 50;          // CCI Period (Increased to reduce noise)
input int             InpBBPeriod    = 50;          // BB Period (Increased for smoother bands)
input double          InpBBDev       = 2.5;         // BB Deviation (Increased for stricter breakout)
input int             InpATRPeriod   = 14;          // ATR Period
input int             InpATRAvgPer   = 200;         // ATR Average Period

//--- Global Variables
int      handleCCI, handleBB, handleATR, handleATRAvg, handleH4MA;
CTrade   trade;
CPositionInfo posInfo;

enum ENUM_REGIME {
   STATE_TREND,
   STATE_RANGE
};

enum ENUM_STATE {
   STATE_TREND_REGIME,
   STATE_RANGE_REGIME
};

ENUM_STATE g_state = STATE_RANGE_REGIME;
int        g_bars_in_state = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);

   handleCCI    = iCCI(_Symbol, InpExecutionTF, InpCCIPeriod, PRICE_CLOSE);
   handleBB     = iBands(_Symbol, InpExecutionTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   handleATR    = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
   handleATRAvg = iATR(_Symbol, InpExecutionTF, InpATRAvgPer);
   handleH4MA   = iMA(_Symbol, InpHigherTF, 20, 0, MODE_SMA, PRICE_CLOSE);

   if(handleCCI == INVALID_HANDLE || handleBB == INVALID_HANDLE || 
      handleATR == INVALID_HANDLE || handleATRAvg == INVALID_HANDLE || 
      handleH4MA == INVALID_HANDLE)
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
   IndicatorRelease(handleCCI);
   IndicatorRelease(handleBB);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleATRAvg);
   IndicatorRelease(handleH4MA);
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

   // 2. Spread Check
   double currentSpreadPips = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / GetPipValue();
   if(currentSpreadPips > InpMaxSpread) return;

   // 3. Data Buffers (Using index 1 for closed bar)
   double cci[], bbUpper[], bbLower[], bbMiddle[], atr[], atrAvg[], h4Close[], h4MA[];
   ArraySetAsSeries(cci, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMiddle, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(atrAvg, true);
   ArraySetAsSeries(h4Close, true);
   ArraySetAsSeries(h4MA, true);

   if(CopyBuffer(handleCCI, 0, 1, 2, cci) < 2) return;
   if(CopyBuffer(handleBB, 1, 1, 1, bbUpper) < 1) return;
   if(CopyBuffer(handleBB, 2, 1, 1, bbLower) < 1) return;
   if(CopyBuffer(handleBB, 0, 1, 1, bbMiddle) < 1) return;
   if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1) return;
   if(CopyBuffer(handleATRAvg, 0, 1, 1, atrAvg) < 1) return;
   if(CopyClose(_Symbol, InpHigherTF, 1, 1, h4Close) < 1) return;
   if(CopyBuffer(handleH4MA, 0, 1, 1, h4MA) < 1) return;

   // 4. Regime Detection with Hysteresis
   double current_bb_width = bbUpper[0] - bbLower[0];
   double current_atr_avg = atrAvg[0];
   
   ENUM_STATE next_state = g_state;
   if(cci[0] > 120.0 && current_bb_width >= (current_atr_avg * 1.6)) 
      next_state = STATE_TREND_REGIME;
   else if(cci[0] < -120.0 && current_bb_width <= (current_atr_avg * 0.8)) 
      next_state = STATE_RANGE_REGIME;

   if(next_state != g_state)
   {
      if(g_bars_in_state >= InpStateMinBars)
      {
         g_state = next_state;
         g_bars_in_state = 0;
      }
   }
   else
   {
      g_bars_in_state++;
   }

   // 5. H4 Trend & Volatility
   int h4Trend = 0; 
   if(h4Close[0] > h4MA[0]) h4Trend = 1;
   else if(h4Close[0] < h4MA[0]) h4Trend = -1;

   bool volFilter = (atr[0] < (current_atr_avg * 0.8));

   // 6. Position Management
   bool hasPosition = PositionSelectByMagic(_Symbol, InpMagicNum);
   if(hasPosition) 
   {
      ManageExit(g_state, atr[0], bbMiddle[0], bbUpper[0], bbLower[0]);
   }

   // 7. Entry Logic
   if(!hasPosition && !volFilter)
   {
      double close1 = iClose(_Symbol, InpExecutionTF, 1);
      double high1  = iHigh(_Symbol, InpExecutionTF, 1);
      double low1   = iLow(_Symbol, InpExecutionTF, 1);

      if(g_state == STATE_TREND_REGIME)
      {
         if(cci[0] > 120.0 && close1 > bbUpper[0] && h4Trend == 1)
         {
            double sl = low1 - (atr[0] * 1.8);
            double tp = close1 + (atr[0] * 6.5);
            trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Trend Buy");
         }
         else if(cci[0] < -120.0 && close1 < bbLower[0] && h4Trend == -1)
         {
            double sl = high1 + (atr[0] * 1.8);
            double tp = close1 - (atr[0] * 6.5);
            trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Trend Sell");
         }
      }
      else if(g_state == STATE_RANGE_REGIME)
      {
         if(cci[0] < -120.0 && low1 <= bbLower[0] && h4Trend == 0)
         {
            double sl = bbUpper[0];
            double tp = bbMiddle[0];
            trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Range Buy");
         }
         else if(cci[0] > 120.0 && high1 >= bbUpper[0] && h4Trend == 0)
         {
            double sl = bbLower[0];
            double tp = bbMiddle[0];
            trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Range Sell");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Exit and Trailing                                         |
//+------------------------------------------------------------------+
void ManageExit(ENUM_STATE regime, double atrVal, double bbMid, double bbUp, double bbLow)
{
   if(!posInfo.SelectByMagic(_Symbol, InpMagicNum)) return;

   double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double openPrice = posInfo.PriceOpen();
   double currentSL = posInfo.StopLoss();

   if(regime == STATE_TREND_REGIME)
   {
      double profitPoints = MathAbs(currentPrice - openPrice);
      if(profitPoints > (atrVal * 2.0))
      {
         double newSL = 0;
         if(posInfo.PositionType() == POSITION_TYPE_BUY)
         {
            newSL = currentPrice - (atrVal * 0.7);
            if(newSL > currentSL + (atrVal * 0.1)) 
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
         }
         else
         {
            newSL = currentPrice + (atrVal * 0.7);
            if(currentSL == 0 || newSL < currentSL - (atrVal * 0.1)) 
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
void ManageOpenPosition() { }

double GetPipValue()
{
   if(_Digits == 3 || _Digits == 5) return _Point * 10;
   return _Point;
}

bool PositionSelectByMagic(string symbol, int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == magic)
            return true;
      }
   }
   return false;
}
