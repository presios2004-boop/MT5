//+------------------------------------------------------------------+
//|                                          BOJ_YenLow_Trend.mq5    |
//|  シナリオC（リスク 25%）: 据え置き+ハト派/米利上げ継続            |
//|  戦略: 円安（USDJPY上昇）トレンドフォロー（介入リスク考慮）        |
//+------------------------------------------------------------------+
#property copyright "AperCode"
#property version   "1.02"
#property strict

#include <Trade/Trade.mqh>

//--- 基本パラメータ
input double InpLotSize      = 0.1;    // ロットサイズ
input int    InpSL_Pips      = 200;    // ストップロス（pips）
input int    InpTP_Pips      = 250;    // 利確（pips、介入水準より上なら介入水準で利確）
input long   InpMagic        = 20261031; // マジックナンバー
input int    InpMaxSpread    = 50;     // 最大スプレッド（pips）

//--- トレンド判定パラメータ
input int    InpEMA_Fast     = 12;     // 短期EMA期間
input int    InpEMA_Slow     = 26;     // 長期EMA期間
input double InpBreakLevel   = 160.0;  // 円安加速トリガー水準
input double InpIntervention = 162.0;  // 介入警戒水準（TP上限+ポジション決済）

//--- 執行足
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H1; // 執行足

//--- 運用期間（日銀会合前後3営業日）
input datetime InpActiveFrom = D'2026.10.26 00:00'; // 開始日
input datetime InpActiveTo   = D'2026.11.04 23:59'; // 終了日

//--- グローバル
CTrade   trade;
int      hEMA_Fast;
int      hEMA_Slow;
datetime lastBarTime;
double   gPip;  // 1pipの価格（0.01）
bool     gInterventionTriggered;  // 介入トリガー済みフラグ

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   
   //--- 1pip = 0.01（USDJPYは3桁表示、_Point=0.001）
   gPip = 0.01;
   
   hEMA_Fast = iMA(_Symbol, InpExecutionTF, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow = iMA(_Symbol, InpExecutionTF, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   
   if(hEMA_Fast == INVALID_HANDLE || hEMA_Slow == INVALID_HANDLE)
   {
      Print("ERROR: indicator handle failed");
      return(INIT_FAILED);
   }
   
   lastBarTime = 0;
   gInterventionTriggered = false;
   Print("BOJ_YenLow_Trend v1.02 initialized. BreakLevel=", InpBreakLevel, " Intervention=", InpIntervention);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA_Fast != INVALID_HANDLE) IndicatorRelease(hEMA_Fast);
   if(hEMA_Slow != INVALID_HANDLE) IndicatorRelease(hEMA_Slow);
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
//| CloseAllPositions: リトライ付き（最大3回）                       |
//+------------------------------------------------------------------+
bool CloseAllPositions()
{
   bool allClosed = true;
   for(int retry = 0; retry < 3; retry++)
   {
      bool anyRemaining = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         
         long posType = PositionGetInteger(POSITION_TYPE);
         if(trade.PositionClose(ticket))
         {
            if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
               Print("CLOSED #", ticket, " type=", posType, " retry=", retry);
            else
            {
               Print("CLOSE #", ticket, " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
               anyRemaining = true;
            }
         }
         else
         {
            Print("CLOSE #", ticket, " FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            anyRemaining = true;
         }
      }
      if(!anyRemaining)
      {
         allClosed = true;
         break;
      }
      allClosed = false;
      if(retry < 2)
         Sleep(500);  // 0.5秒待ってリトライ
   }
   if(!allClosed)
      Print("WARNING: CloseAllPositions - some positions may remain after 3 retries");
   return allClosed;
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
void OnTick()
{
   //=== 期間終了後の強制決済 ===
   if(!MQLInfoInteger(MQL_TESTER) && InpActiveTo > 0 && TimeCurrent() > InpActiveTo && CountPositions() >= 1)
   {
      Print("PERIOD ENDED: closing all positions");
      CloseAllPositions();
      return;
   }
   //=== 介入警戒: 毎ティック実行（IsNewBarより前）===
   //--- 価格が介入水準を超えたら既存ポジションを即時決済
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask > 0 && ask >= InpIntervention)
   {
      if(!gInterventionTriggered)
      {
         gInterventionTriggered = true;
         Print("INTERVENTION TRIGGERED: ask=", ask, " >= ", InpIntervention);
      }
      if(CountPositions() >= 1)
      {
         Print("INTERVENTION: closing all positions @ ask=", ask);
         CloseAllPositions();
      }
      return;  // 新規エントリーも停止
   }
   //--- 介入水準を割れたらフラグ解除（価格が戻った場合）
   if(gInterventionTriggered && ask < InpIntervention)
      gInterventionTriggered = false;
   
   //=== 通常エントリーロジック（確定バーのみ）===
   if(!IsNewBar())
      return;
   if(!IsInActivePeriod())
      return;
   if(CountPositions() >= 1)
      return;
   if(GetSpreadPips() > InpMaxSpread)
      return;
   
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
   
   double emaFastBuf[], emaSlowBuf[];
   ArraySetAsSeries(emaFastBuf, true);
   ArraySetAsSeries(emaSlowBuf, true);
   
   if(CopyBuffer(hEMA_Fast, 0, 1, 2, emaFastBuf) < 2) return;
   if(CopyBuffer(hEMA_Slow, 0, 1, 2, emaSlowBuf) < 2) return;
   
   double emaFast1 = emaFastBuf[0];
   double emaSlow1 = emaSlowBuf[0];
   double emaFast2 = emaFastBuf[1];
   double emaSlow2 = emaSlowBuf[1];
   
   if(emaFast1 == EMPTY_VALUE || emaSlow1 == EMPTY_VALUE)
      return;
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   //=== 円安トレンドフォロー（買い）===
   //--- 条件1: 短期EMAが長期EMAを上回る（ゴールデンクロス状態）
   //--- 条件2: 前バーはクロス直前（短期<長期）、確定バーで短期>長期 → 新規ゴールデンクロス
   //--- 条件3: 価格がトリガー水準以上（円安加速）
   
   bool goldenCrossNow  = (emaFast1 > emaSlow1);
   bool wasBearBefore   = (emaFast2 < emaSlow2);
   bool aboveTrigger    = (close1 >= InpBreakLevel);
   
   if(goldenCrossNow && wasBearBefore && aboveTrigger)
   {
      double sl = NormalizeDouble(bid - InpSL_Pips * gPip, digits);
      double tp = NormalizeDouble(bid + InpTP_Pips * gPip, digits);
      //--- 介入水準がTPより下なら、介入水準で利確（矛盾解消）
      if(InpIntervention < tp)
         tp = NormalizeDouble(InpIntervention - 5 * gPip, digits);
       if(tp <= bid + 5 * gPip)
       {
          Print("SKIP: TP too close to bid tp=", tp, " bid=", bid);
          return;
       }

      
      if(!CheckStopsLevel(sl, tp, bid, 1))
      {
         Print("SKIP: stops level too close (trend buy)");
         return;
      }
      if(trade.Buy(InpLotSize, _Symbol, 0, sl, tp, "BOJ_C_trend_buy"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("TREND BUY OK SL=", sl, " TP=", tp,
                  " EMA_F=", emaFast1, " EMA_S=", emaSlow1);
         else
            Print("TREND BUY retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("TREND BUY FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
   
   //--- 条件4: 既にゴールデンクロス状態 + 価格がトリガー水準を突破 → 追加買い
   if(goldenCrossNow && !wasBearBefore && aboveTrigger && close1 > close2)
   {
      double sl = NormalizeDouble(bid - InpSL_Pips * gPip, digits);
      double tp = NormalizeDouble(bid + InpTP_Pips * gPip, digits);
      if(InpIntervention < tp)
         tp = NormalizeDouble(InpIntervention - 5 * gPip, digits);
       if(tp <= bid + 5 * gPip)
       {
          Print("SKIP: TP too close to bid tp=", tp, " bid=", bid);
          return;
       }

      
      if(!CheckStopsLevel(sl, tp, bid, 1))
      {
         Print("SKIP: stops level too close (momentum buy)");
         return;
      }
      if(trade.Buy(InpLotSize, _Symbol, 0, sl, tp, "BOJ_C_momentum_buy"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("MOMENTUM BUY OK SL=", sl, " TP=", tp,
                  " EMA_F=", emaFast1, " EMA_S=", emaSlow1);
         else
            Print("MOMENTUM BUY retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("MOMENTUM BUY FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
}
//+------------------------------------------------------------------+
