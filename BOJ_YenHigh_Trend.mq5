//+------------------------------------------------------------------+
//|                                          BOJ_YenHigh_Trend.mq5   |
//|  シナリオB（リスク 25%）: 連続利上げ1.50%+タカ派展望              |
//|  戦略: 円高（USDJPY下落）トレンドフォロー                          |
//+------------------------------------------------------------------+
#property copyright "AperCode"
#property version   "1.02"
#property strict

#include <Trade/Trade.mqh>

//--- 基本パラメータ
input double InpLotSize      = 0.1;    // ロットサイズ
input int    InpSL_Pips      = 200;    // ストップロス（pips、ATR無効時のフォールバック）
input int    InpTP_Pips      = 300;    // 利確（pips）
input long   InpMagic        = 20261030; // マジックナンバー
input int    InpMaxSpread    = 50;     // 最大スプレッド（pips）

//--- トレンド判定パラメータ
input int    InpEMA_Fast     = 12;     // 短期EMA期間
input int    InpEMA_Slow     = 26;     // 長期EMA期間
input int    InpATR_Period   = 14;     // ATR期間
input double InpATR_Mult     = 1.5;    // ATR倍率（SL用）
input double InpBreakLevel   = 155.0;  // 円高加速トリガー水準

//--- 執行足
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H1; // 執行足

//--- 運用期間（日銀会合前後3営業日）
input datetime InpActiveFrom = D'2026.10.26 00:00'; // 開始日
input datetime InpActiveTo   = D'2026.11.04 23:59'; // 終了日

//--- グローバル
CTrade   trade;
int      hEMA_Fast;
int      hEMA_Slow;
int      hATR;
datetime lastBarTime;
double   gPip;  // 1pipの価格（0.01）

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   
   //--- 1pip = 0.01（USDJPYは3桁表示、_Point=0.001）
   gPip = 0.01;
   
   hEMA_Fast = iMA(_Symbol, InpExecutionTF, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow = iMA(_Symbol, InpExecutionTF, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hATR      = iATR(_Symbol, InpExecutionTF, InpATR_Period);
   
   if(hEMA_Fast == INVALID_HANDLE || hEMA_Slow == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("ERROR: indicator handle failed");
      return(INIT_FAILED);
   }
   
   lastBarTime = 0;
   Print("BOJ_YenHigh_Trend v1.02 initialized. BreakLevel=", InpBreakLevel, " ATR_Mult=", InpATR_Mult);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA_Fast != INVALID_HANDLE) IndicatorRelease(hEMA_Fast);
   if(hEMA_Slow != INVALID_HANDLE) IndicatorRelease(hEMA_Slow);
   if(hATR != INVALID_HANDLE)      IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime curBarTime = iTime(_Symbol, InpExecutionTF, 0);
   if(curBarTime == lastBarTime)
      return false;
   lastBarTime = curBarTime;
   return true;
}

//+------------------------------------------------------------------+
bool IsInActivePeriod()
{
   if(MQLInfoInteger(MQL_TESTER))
      return true;
   datetime now = TimeCurrent();
   if(InpActiveFrom > 0 && now < InpActiveFrom)
      return false;
   if(InpActiveTo > 0 && now > InpActiveTo)
      return false;
   return true;
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      count++;
   }
   return count;
}

 //+------------------------------------------------------------------+
 //| CloseAllPositions: retry up to 3 times                           |
 //+------------------------------------------------------------------+
 bool CloseAllPositions()
 {
    for(int retry = 0; retry < 3; retry++)
    {
       bool allClosed = true;
       for(int i = PositionsTotal() - 1; i >= 0; i--)
       {
          ulong ticket = PositionGetTicket(i);
          if(ticket == 0) continue;
          if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
          if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
          if(!trade.PositionClose(ticket))
          {
             allClosed = false;
             Print("CloseAllPositions: close failed ticket=", ticket,
                   " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
          }
       }
       if(allClosed) return true;
       Print("CloseAllPositions: retry ", retry + 1, " of 3");
    }
    Print("WARNING: CloseAllPositions - some positions may remain after 3 retries");
    return false;
 }


//+------------------------------------------------------------------+
double GetSpreadPips()
{
   double a = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double b = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(a <= 0 || b <= 0) return 9999;
   return (a - b) / gPip;
}

//+------------------------------------------------------------------+
//| CheckStopsLevel: Buy=bid基準, Sell=ask基準で検証                 |
//+------------------------------------------------------------------+
bool CheckStopsLevel(double sl, double tp, double refPrice, int direction)
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax(stopsLevel, freezeLevel) * _Point;
   if(minDist <= 0) return true;
   if(direction > 0)
   {
      if(refPrice - sl < minDist) return false;
      if(tp - refPrice < minDist) return false;
   }
   else
   {
      if(sl - refPrice < minDist) return false;
      if(refPrice - tp < minDist) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| SL距離を計算: ATR有効ならATR倍率、無効なら固定pips               |
//+------------------------------------------------------------------+
double CalcSLDistance(double atr1)
{
   if(atr1 > 0 && atr1 != EMPTY_VALUE)
      return InpATR_Mult * atr1;
   //--- ATR無効時は固定pipsにフォールバック
   Print("INFO: ATR invalid, fallback to fixed SL=", InpSL_Pips, " pips");
   return InpSL_Pips * gPip;
}

//+------------------------------------------------------------------+
void OnTick()
{
   //--- 運用期間終了後の強制決済
   if(!MQLInfoInteger(MQL_TESTER) && InpActiveTo > 0 && TimeCurrent() > InpActiveTo && CountPositions() >= 1)
   {
      Print("PERIOD ENDED: closing all positions");
      CloseAllPositions();
      return;
   }
   if(!IsNewBar())
      return;
   if(!IsInActivePeriod())
      return;
   if(CountPositions() >= 1)
      return;
   if(GetSpreadPips() > InpMaxSpread)
      return;
   
   //--- 現在価格を取得
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return;
   
   //--- 確定バー（shift=1）のデータを取得
   double close1 = iClose(_Symbol, InpExecutionTF, 1);
   if(close1 <= 0)
   {
      Print("SKIP: close1 invalid (history not loaded)");
      return;
   }
   double close2 = iClose(_Symbol, InpExecutionTF, 2);
   if(close2 <= 0)
      return;
   
   double emaFastBuf[], emaSlowBuf[], atrBuf[];
   ArraySetAsSeries(emaFastBuf, true);
   ArraySetAsSeries(emaSlowBuf, true);
   ArraySetAsSeries(atrBuf, true);
   
   if(CopyBuffer(hEMA_Fast, 0, 1, 2, emaFastBuf) < 2) return;
   if(CopyBuffer(hEMA_Slow, 0, 1, 2, emaSlowBuf) < 2) return;
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) < 1) return;
   
   double emaFast1 = emaFastBuf[0];
   double emaSlow1 = emaSlowBuf[0];
   double emaFast2 = emaFastBuf[1];
   double emaSlow2 = emaSlowBuf[1];
   double atr1     = atrBuf[0];
   
   if(emaFast1 == EMPTY_VALUE || emaSlow1 == EMPTY_VALUE)
      return;
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   //=== 円高トレンドフォロー（売り）===
   //--- 条件1: 短期EMAが長期EMAを下回る（デッドクロス状態）
   //--- 条件2: 前バーはクロス直前（短期>長期）、確定バーで短期<長期 → 新規デッドクロス
   //--- 条件3: 価格がトリガー水準以下（円高加速）
   
   bool deadCrossNow  = (emaFast1 < emaSlow1);
   bool wasBullBefore = (emaFast2 > emaSlow2);
   bool belowTrigger  = (close1 <= InpBreakLevel);
   
   if(deadCrossNow && wasBullBefore && belowTrigger)
   {
      //--- SL: ATR倍率（ボラティリティに追従）/ ATR無効時は固定pips
      double slDist = CalcSLDistance(atr1);
      double sl = NormalizeDouble(ask + slDist, digits);
      double tp = NormalizeDouble(ask - InpTP_Pips * gPip, digits);
      
      if(!CheckStopsLevel(sl, tp, ask, -1))
      {
         Print("SKIP: stops level too close (trend sell)");
         return;
      }
      if(trade.Sell(InpLotSize, _Symbol, 0, sl, tp, "BOJ_B_trend_sell"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("TREND SELL OK SL=", sl, " TP=", tp,
                  " EMA_F=", emaFast1, " EMA_S=", emaSlow1, " ATR=", atr1);
         else
            Print("TREND SELL retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("TREND SELL FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
   
   //--- 条件4: 既にデッドクロス状態 + 価格がトリガー水準を割り込み → 追加売り
   if(deadCrossNow && !wasBullBefore && belowTrigger && close1 < close2)
   {
      double slDist = CalcSLDistance(atr1);
      double sl = NormalizeDouble(ask + slDist, digits);
      double tp = NormalizeDouble(ask - InpTP_Pips * gPip, digits);
      
      if(!CheckStopsLevel(sl, tp, ask, -1))
      {
         Print("SKIP: stops level too close (momentum sell)");
         return;
      }
      if(trade.Sell(InpLotSize, _Symbol, 0, sl, tp, "BOJ_B_momentum_sell"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("MOMENTUM SELL OK SL=", sl, " TP=", tp,
                  " EMA_F=", emaFast1, " EMA_S=", emaSlow1);
         else
            Print("MOMENTUM SELL retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("MOMENTUM SELL FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
}
//+------------------------------------------------------------------+
