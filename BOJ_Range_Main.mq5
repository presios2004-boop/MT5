//+------------------------------------------------------------------+
//|                                              BOJ_Range_Main.mq5 |
//|  シナリオA（メイン 50%）: 据え置き+12月利上げシグナル            |
//|  戦略: 155〜160 レンジ内逆張り / ブレイク追従                    |
//+------------------------------------------------------------------+
#property copyright "AperCode"
#property version   "1.02"
#property strict

#include <Trade/Trade.mqh>

//--- 基本パラメータ
input double InpLotSize      = 0.1;    // ロットサイズ
input int    InpSL_Pips      = 150;    // ストップロス（pips）
input int    InpTP_Pips      = 100;    // 利確（pips）
input long   InpMagic        = 20261029; // マジックナンバー
input int    InpMaxSpread    = 50;     // 最大スプレッド（pips）

//--- レンジパラメータ
input double InpRangeLow     = 155.0;  // レンジ下値
input double InpRangeHigh    = 160.0;  // レンジ上値
input int    InpRSI_Period   = 14;     // RSI期間
input double InpRSI_OB       = 70.0;   // RSI買われすぎ
input double InpRSI_OS       = 30.0;   // RSI売られすぎ

//--- 執行足
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H1; // 執行足

//--- 運用期間（日銀会合前後3営業日）
input datetime InpActiveFrom = D'2026.10.26 00:00'; // 開始日
input datetime InpActiveTo   = D'2026.11.04 23:59'; // 終了日

//--- グローバル
CTrade   trade;
int      hRSI;
datetime lastBarTime;
double   gPip;  // 1pipの価格（0.01）

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   
   //--- 1pip = 0.01（USDJPYは3桁表示、_Point=0.001）
   gPip = 0.01;
   
   hRSI = iRSI(_Symbol, InpExecutionTF, InpRSI_Period, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE)
   {
      Print("ERROR: iRSI handle failed");
      return(INIT_FAILED);
   }
   
   lastBarTime = 0;
   Print("BOJ_Range_Main v1.02 initialized. Range: ", InpRangeLow, "-", InpRangeHigh);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hRSI != INVALID_HANDLE)
      IndicatorRelease(hRSI);
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
      //--- Buy: SL < refPrice(bid), TP > refPrice(bid)
      if(refPrice - sl < minDist) return false;
      if(tp - refPrice < minDist) return false;
   }
   else
   {
      //--- Sell: SL > refPrice(ask), TP < refPrice(ask)
      if(sl - refPrice < minDist) return false;
      if(refPrice - tp < minDist) return false;
   }
   return true;
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
   
   //--- 確定バー（shift=1）の価格・RSIを取得
   double close1 = iClose(_Symbol, InpExecutionTF, 1);
   if(close1 <= 0)
   {
      Print("SKIP: close1 invalid (history not loaded)");
      return;
   }
   
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(hRSI, 0, 1, 2, rsiBuf) < 2)
      return;
   double rsi1 = rsiBuf[0];  // 確定バーのRSI
   double rsi2 = rsiBuf[1];  // 前バーのRSI
   if(rsi1 == EMPTY_VALUE || rsi2 == EMPTY_VALUE)
      return;
   
   double sl, tp;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   //=== レンジ内逆張り（レンジ内の価格のみ）===
   //--- 下値付近 + RSI売られすぎ → 買い
   if(close1 >= InpRangeLow && close1 <= InpRangeLow * 1.002 && rsi1 < InpRSI_OS)
   {
      sl = NormalizeDouble(bid - InpSL_Pips * gPip, digits);
      tp = NormalizeDouble(bid + InpTP_Pips * gPip, digits);
      if(!CheckStopsLevel(sl, tp, bid, 1))
      {
         Print("SKIP: stops level too close (range buy)");
         return;
      }
      if(trade.Buy(InpLotSize, _Symbol, 0, sl, tp, "BOJ_A_range_buy"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("RANGE BUY OK SL=", sl, " TP=", tp, " RSI=", rsi1);
         else
            Print("RANGE BUY retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("RANGE BUY FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
   
   //--- 上値付近 + RSI買われすぎ → 売り
   if(close1 <= InpRangeHigh && close1 >= InpRangeHigh * 0.998 && rsi1 > InpRSI_OB)
   {
      sl = NormalizeDouble(ask + InpSL_Pips * gPip, digits);
      tp = NormalizeDouble(ask - InpTP_Pips * gPip, digits);
      if(!CheckStopsLevel(sl, tp, ask, -1))
      {
         Print("SKIP: stops level too close (range sell)");
         return;
      }
      if(trade.Sell(InpLotSize, _Symbol, 0, sl, tp, "BOJ_A_range_sell"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("RANGE SELL OK SL=", sl, " TP=", tp, " RSI=", rsi1);
         else
            Print("RANGE SELL retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("RANGE SELL FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
   
   //=== レンジブレイク追従（レンジ外の価格のみ）===
   //--- 下値ブレイク（確定バーがレンジ下値割れ）→ 売り
   if(close1 < InpRangeLow && rsi1 < 50)
   {
      sl = NormalizeDouble(ask + InpSL_Pips * gPip, digits);
      tp = NormalizeDouble(ask - InpTP_Pips * gPip, digits);
      if(!CheckStopsLevel(sl, tp, ask, -1))
      {
         Print("SKIP: stops level too close (break sell)");
         return;
      }
      if(trade.Sell(InpLotSize, _Symbol, 0, sl, tp, "BOJ_A_break_sell"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("BREAK SELL OK SL=", sl, " TP=", tp);
         else
            Print("BREAK SELL retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("BREAK SELL FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
   
   //--- 上値ブレイク（確定バーがレンジ上値突破）→ 買い
   if(close1 > InpRangeHigh && rsi1 > 50)
   {
      sl = NormalizeDouble(bid - InpSL_Pips * gPip, digits);
      tp = NormalizeDouble(bid + InpTP_Pips * gPip, digits);
      if(!CheckStopsLevel(sl, tp, bid, 1))
      {
         Print("SKIP: stops level too close (break buy)");
         return;
      }
      if(trade.Buy(InpLotSize, _Symbol, 0, sl, tp, "BOJ_A_break_buy"))
      {
         if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
            Print("BREAK BUY OK SL=", sl, " TP=", tp);
         else
            Print("BREAK BUY retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      else
         Print("BREAK BUY FAILED retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }
}
//+------------------------------------------------------------------+
