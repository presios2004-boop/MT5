//+------------------------------------------------------------------+
//|                                     Vol-Regime Dual Switcher.mq5 |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024"
#property link      "https://www.mql5.com"
#property version   "1.55"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4; // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1; // Higher Timeframe
input double          InpLotSize     = 0.1;       // Fixed Lot Size
input int             InpMaxSpread   = 50;        // Max Spread (Points)
input int             InpSlippage    = 30;        // Slippage (Points)
input long            InpMagicNum    = 202600801; // Magic Number

//--- Indicator Parameters
input int             InpBBPeriod    = 20;        // BB Period
input double          InpBBDev       = 2.0;       // BB Deviation
input int             InpATRPeriod   = 14;        // ATR Period
input int             InpADXPeriod   = 14;        // ADX Period
input int             InpEMAPeriod   = 25;        // EMA Period
input int             InpATRMA       = 200;       // ATR MA Period
input int             InpStateMinBars = 5;        // Min Bars in State

//--- Global Variables
int      handleBB, handleATR, handleADX, handleEMA;
CTrade   trade;
CPositionInfo posInfo;

enum ENUM_STATE { STATE_RANGE_MODE, STATE_TREND_MODE };

//--- Persistent State Variables
ENUM_STATE g_state = STATE_RANGE_MODE;
int        g_bars_in_state = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);

   handleBB    = iBands(_Symbol, InpExecutionTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   handleATR   = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
   handleADX   = iADX(_Symbol, InpExecutionTF, InpADXPeriod);
   handleEMA   = iMA(_Symbol, InpExecutionTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(handleBB == INVALID_HANDLE || handleATR == INVALID_HANDLE || 
      handleADX == INVALID_HANDLE || handleEMA == INVALID_HANDLE)
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
   IndicatorRelease(handleBB);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleEMA);
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop for Trend Strategy                          |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleATR, 0, 1, 1, atr) <= 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == InpMagicNum && posInfo.Symbol() == _Symbol)
         {
            double currentPrice = posInfo.PriceCurrent();
            double openPrice = posInfo.PriceOpen();
            double currentSL = posInfo.StopLoss();
            double profitPoints = MathAbs(currentPrice - openPrice);
            
            double trigger = atr[0] * 1.0; 
            double trailWidth = atr[0] * 0.4;

            if(posInfo.PositionType() == POSITION_TYPE_BUY)
            {
               if(profitPoints > trigger)
               {
                  double newSL = currentPrice - trailWidth;
                  if(newSL > currentSL + _Point * 10)
                  {
                     trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                  }
               }
            }
            else if(posInfo.PositionType() == POSITION_TYPE_SELL)
            {
               if(profitPoints > trigger)
               {
                  double newSL = currentPrice + trailWidth;
                  if(currentSL == 0 || newSL < currentSL - _Point * 10)
                  {
                     trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
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
   if(t == g_last_bar) 
   { 
      ManageTrailingStop(); 
      return; 
   }
   g_last_bar = t;

   // 2. Check Spread
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread) return;

   // 3. Check Existing Positions
   bool hasPosition = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == InpMagicNum && posInfo.Symbol() == _Symbol)
         {
            hasPosition = true;
            break;
         }
      }
   }

   // 4. Get Indicator Data
   double bbUpper[], bbLower[], bbMid[], atr[], adx[], ema[], close[], open[];
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMid, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(open, true);

   if(CopyBuffer(handleBB, 1, 1, 2, bbUpper) <= 0) return;
   if(CopyBuffer(handleBB, 2, 1, 2, bbLower) <= 0) return;
   if(CopyBuffer(handleBB, 0, 1, 2, bbMid) <= 0) return;
   if(CopyBuffer(handleATR, 0, 1, InpATRMA + 1, atr) <= 0) return;
   if(CopyBuffer(handleADX, 0, 1, 2, adx) <= 0) return;
   if(CopyBuffer(handleEMA, 0, 1, 2, ema) <= 0) return;
   if(CopyClose(_Symbol, InpExecutionTF, 1, 2, close) <= 0) return;
   if(CopyOpen(_Symbol, InpExecutionTF, 1, 2, open) <= 0) return;

   // 5. Calculate ATR MA
   double sumATR = 0;
   int count = 0;
   for(int i=0; i<InpATRMA && i<ArraySize(atr); i++) 
   {
      sumATR += atr[i];
      count++;
   }
   if(count == 0) return;
   double atrMA = sumATR / count;

   // 6. Detect Regime with Hysteresis and Cooldown
   g_bars_in_state++;
   
   if(g_state == STATE_RANGE_MODE)
   {
      if(adx[0] >= 25.0 && g_bars_in_state >= InpStateMinBars)
      {
         g_state = STATE_TREND_MODE;
         g_bars_in_state = 0;
      }
   }
   else if(g_state == STATE_TREND_MODE)
   {
      if(adx[0] < 20.0 && g_bars_in_state >= InpStateMinBars)
      {
         g_state = STATE_RANGE_MODE;
         g_bars_in_state = 0;
      }
   }

   // 7. Volatility Filter
   if(atr[0] < (atrMA * 0.7)) return;

   // 8. Strategy Execution
   if(!hasPosition)
   {
      if(g_state == STATE_TREND_MODE)
      {
         if(close[0] > ema[0] && close[0] > bbUpper[0] && close[1] <= bbUpper[1])
         {
            double sl = close[0] - (atr[0] * 1.2);
            double tp = close[0] + (atr[0] * 15.0);
            trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Trend Buy");
         }
         else if(close[0] < ema[0] && close[0] < bbLower[0] && close[1] >= bbLower[1])
         {
            double sl = close[0] + (atr[0] * 1.2);
            double tp = close[0] - (atr[0] * 15.0);
            trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Trend Sell");
         }
      }
      else if(g_state == STATE_RANGE_MODE)
      {
         if(close[0] < bbLower[0] && close[0] > open[0])
         {
            double sl = close[0] - (atr[0] * 1.0);
            double tp = bbMid[0];
            trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Range Buy");
         }
         else if(close[0] > bbUpper[0] && close[0] < open[0])
         {
            double sl = close[0] + (atr[0] * 1.0);
            double tp = bbMid[0];
            trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Range Sell");
         }
      }
   }
}
