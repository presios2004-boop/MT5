//+------------------------------------------------------------------+
//|                                     LiquidityImbalanceExpert.mq5 |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H1;      // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;      // Higher Timeframe
input double          InpImbalanceThreshold = 0.8;     // Price Imbalance Threshold
input double          InpVolSkewThreshold   = 0.8;     // Volume Skew Threshold
input int             InpRankLookback       = 15;      // Body Rank Lookback Period
input double          InpRankTopPct         = 45.0;    // Body Rank Top Percentage (Increased to boost trade count)
input double          InpSLMultiplier       = 1.2;     // ATR SL Multiplier (Decreased for faster exit/better RF)
input double          InpTPMultiplier       = 3.5;     // ATR TP Multiplier (Optimized RR ratio)
input double          InpTrailActivation    = 1.5;     // ATR Trail Activation Multiplier
input double          InpTrailStep          = 0.5;     // ATR Trail Step Multiplier
input double          InpMaxSpreadPips      = 5.0;     // Max Spread (Pips)
input int             InpMagicNumber        = 202600801; // Magic Number

//--- Global Variables
CTrade   trade;
double   pips_multiplier;
int      handleATR_Exec;
int      handleATR_High;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    double digits = SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    if(digits == 3 || digits == 5) pips_multiplier = 10.0 * _Point;
    else pips_multiplier = _Point;

    handleATR_Exec = iATR(_Symbol, InpExecutionTF, 14);
    handleATR_High = iATR(_Symbol, InpHigherTF, 14);

    if(handleATR_Exec == INVALID_HANDLE || handleATR_High == INVALID_HANDLE)
    {
        Print("Error initializing indicators");
        return(INIT_FAILED);
    }

    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(30);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handleATR_Exec);
    IndicatorRelease(handleATR_High);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spread = (ask - bid) / pips_multiplier;
    if(spread > InpMaxSpreadPips) return;

    ManageTrailingStop();

    if(!IsNewBar(InpExecutionTF)) return;
    if(PositionSelectByMagic(InpMagicNumber)) return;

    double currentATR = GetATR(handleATR_Exec, 0);
    if(currentATR <= 0) return;

    double imbalance = CalculateImbalance(InpExecutionTF, 1);
    double volSkew = CalculateVolumeSkew(InpExecutionTF, 1);
    
    double close1 = iClose(_Symbol, InpExecutionTF, 1);
    double open1 = iOpen(_Symbol, InpExecutionTF, 1);
    double currentBody = MathAbs(close1 - open1);
    bool isTopBody = CheckBodyRank(InpExecutionTF, InpRankLookback, currentBody, InpRankTopPct);

    int trend = GetHigherTF_Trend();

    double sl_dist = currentATR * InpSLMultiplier;
    double tp_dist = currentATR * InpTPMultiplier;

    if(imbalance > InpImbalanceThreshold && volSkew > InpVolSkewThreshold && isTopBody && trend == 1)
    {
        if(trade.Buy(0.1, _Symbol, ask, 0, 0, "Imbalance Buy"))
        {
            if(PositionSelectByMagic(InpMagicNumber))
            {
                double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
                double sl = ClampStop(true, entry_price - sl_dist);
                double tp = ClampStop(true, entry_price + tp_dist);
                trade.PositionModify(PositionGetTicket(0), sl, tp);
            }
        }
    }
    else if(imbalance > InpImbalanceThreshold && volSkew > InpVolSkewThreshold && isTopBody && trend == -1)
    {
        if(trade.Sell(0.1, _Symbol, bid, 0, 0, "Imbalance Sell"))
        {
            if(PositionSelectByMagic(InpMagicNumber))
            {
                double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
                double sl = ClampStop(false, entry_price + sl_dist);
                double tp = ClampStop(false, entry_price - tp_dist);
                trade.PositionModify(PositionGetTicket(0), sl, tp);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+

double ClampStop(bool isBuy, double targetPrice)
{
    double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    double currentPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    if(isBuy)
    {
        if(currentPrice - targetPrice < stopLevel)
            return (currentPrice - stopLevel > 0) ? currentPrice - stopLevel : targetPrice;
    }
    else
    {
        if(targetPrice - currentPrice < stopLevel)
            return (currentPrice + stopLevel < targetPrice) ? currentPrice + stopLevel : targetPrice;
    }
    return targetPrice;
}

bool IsNewBar(ENUM_TIMEFRAMES tf)
{
    static datetime last_time = 0;
    datetime current_time = iTime(_Symbol, tf, 0);
    if(current_time != last_time)
    {
        last_time = current_time;
        return true;
    }
    return false;
}

double CalculateImbalance(ENUM_TIMEFRAMES tf, int shift)
{
    double total_dist = 0;
    int lookback = 20;
    for(int i=shift+1; i<shift+1+lookback; i++)
    {
        total_dist += MathAbs(iClose(_Symbol, tf, i) - iOpen(_Symbol, tf, i));
    }
    double avg_dist = total_dist / lookback;
    double current_dist = MathAbs(iClose(_Symbol, tf, shift) - iOpen(_Symbol, tf, shift));
    if(avg_dist <= 0) return 0;
    return current_dist / avg_dist;
}

double CalculateVolumeSkew(ENUM_TIMEFRAMES tf, int shift)
{
    long current_vol = iTickVolume(_Symbol, tf, shift);
    double total_vol = 0;
    int lookback = 20;
    for(int i=shift+1; i<shift+1+lookback; i++)
    {
        total_vol += (double)iTickVolume(_Symbol, tf, i);
    }
    double avg_vol = total_vol / lookback;
    if(avg_vol <= 0) return 0;
    return (double)current_vol / avg_vol;
}

bool CheckBodyRank(ENUM_TIMEFRAMES tf, int lookback, double currentBody, double topPct)
{
    double bodies[];
    ArrayResize(bodies, lookback);
    for(int i=0; i<lookback; i++)
    {
        bodies[i] = MathAbs(iClose(_Symbol, tf, i+1) - iOpen(_Symbol, tf, i+1));
    }
    for(int i=0; i<lookback-1; i++)
    {
        for(int j=i+1; j<lookback; j++)
        {
            if(bodies[i] < bodies[j])
            {
                double temp = bodies[i];
                bodies[i] = bodies[j];
                bodies[j] = temp;
            }
        }
    }
    int rank_idx = (int)MathFloor((topPct / 100.0) * lookback);
    if(rank_idx >= lookback) rank_idx = lookback - 1;
    return (currentBody >= bodies[rank_idx]);
}

int GetHigherTF_Trend()
{
    int ma_period = 20;
    double close_buffer[];
    ArrayResize(close_buffer, 2);

    if(CopyClose(_Symbol, InpHigherTF, 0, 2, close_buffer) < 2) return 0;
    
    double sum = 0;
    for(int i=0; i<ma_period; i++)
    {
        sum += iClose(_Symbol, InpHigherTF, i+1);
    }
    double sma = sum / ma_period;

    if(close_buffer[1] > sma) return 1;
    if(close_buffer[1] < sma) return -1;
    return 0;
}

double GetATR(int handle, int shift)
{
    double buffer[];
    if(CopyBuffer(handle, 0, shift, 1, buffer) > 0) return buffer[0];
    return 0;
}

bool PositionSelectByMagic(long magic)
{
    for(int i=PositionsTotal()-1; i>=0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
        }
    }
    return false;
}

void ManageTrailingStop()
{
    if(!PositionSelectByMagic(InpMagicNumber)) return;

    double currentATR = GetATR(handleATR_Exec, 0);
    if(currentATR <= 0) return;

    long pos_type = PositionGetInteger(POSITION_TYPE);
    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_sl = PositionGetDouble(POSITION_SL);
    double current_tp = PositionGetDouble(POSITION_TP);
    double cur_price = (pos_type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    ulong ticket = PositionGetTicket(0);

    if(pos_type == POSITION_TYPE_BUY)
    {
        double profit_atr = (cur_price - open_price) / currentATR;
        if(profit_atr >= InpTrailActivation)
        {
            double new_sl = ClampStop(true, cur_price - (currentATR * InpTrailStep));
            if(new_sl > current_sl + (0.1 * pips_multiplier))
            {
                trade.PositionModify(ticket, new_sl, current_tp);
            }
        }
    }
    else if(pos_type == POSITION_TYPE_SELL)
    {
        double profit_atr = (open_price - cur_price) / currentATR;
        if(profit_atr >= InpTrailActivation)
        {
            double new_sl = ClampStop(false, cur_price + (currentATR * InpTrailStep));
            if(current_sl == 0 || new_sl < current_sl - (0.1 * pips_multiplier))
            {
                trade.PositionModify(ticket, new_sl, current_tp);
            }
        }
    }
}
