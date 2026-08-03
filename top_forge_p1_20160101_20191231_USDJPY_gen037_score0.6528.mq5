#include <Trade\Trade.mqh>

// === input parameters ===
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_M30; // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H4;  // Higher Timeframe
input int             InpSTPeriod    = 14;         // SuperTrend Period
input double          InpSTMultiplier = 3.5;       // SuperTrend Multiplier
input int             InpADXPeriod   = 14;         // ADX Period
input int             InpBBPeriod    = 20;         // Bollinger Bands Period
input double          InpBBStdDev    = 2.0;        // Bollinger Bands StdDev
input double          InpBBThreshold = 1.8;        // BB Width Expansion Threshold (Increased to filter range)
input double          InpLotSize     = 0.1;        // Fixed Lot Size
input int             InpMaxSpread   = 50;         // Max Spread (Points)
input int             InpMagicNum    = 202600801;  // Magic Number
input int             InpSlippage    = 30;         // Slippage (Points)

// === global variables ===
CTrade trade;
int    handleST_Higher;
int    handleADX_Exec;
int    handleBB_Exec;
int    handleATR_Exec;

// === Function to check existing positions by Magic Number ===
bool PositionSelectByMagic(long magic)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
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

// === Trailing Stop Implementation ===
void ManageTrailingStop()
{
    // AI Decision: Trend Following Strategy -> Use ATR-based Trailing Stop
    // Since this is a trend following logic, we use a trailing stop to lock in profits.
    
    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(handleATR_Exec, 0, 0, 1, atr) <= 0) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
                double current_sl = PositionGetDouble(POSITION_SL);
                double current_tp = PositionGetDouble(POSITION_TP);
                double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

                // Trigger trailing when profit > 2.0 * ATR
                double trigger_dist = atr[0] * 2.0;

                if(type == POSITION_TYPE_BUY)
                {
                    if(bid - open_price > trigger_dist)
                    {
                        double new_sl = NormalizeDouble(bid - (atr[0] * 1.5), _Digits);
                        if(new_sl > current_sl + _Point * 10) 
                        {
                            trade.PositionModify(ticket, new_sl, current_tp);
                        }
                    }
                }
                else if(type == POSITION_TYPE_SELL)
                {
                    if(open_price - ask > trigger_dist)
                    {
                        double new_sl = NormalizeDouble(ask + (atr[0] * 1.5), _Digits);
                        if(current_sl == 0 || new_sl < current_sl - _Point * 10)
                        {
                            trade.PositionModify(ticket, new_sl, current_tp);
                        }
                    }
                }
            }
        }
    }
}

// === OnInit ===
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetDeviationInPoints(InpSlippage);

    handleST_Higher = iATR(_Symbol, InpHigherTF, InpSTPeriod); 
    handleADX_Exec  = iADX(_Symbol, InpExecutionTF, InpADXPeriod);
    handleBB_Exec   = iBands(_Symbol, InpExecutionTF, InpBBPeriod, 0, InpBBStdDev, PRICE_CLOSE);
    handleATR_Exec  = iATR(_Symbol, InpExecutionTF, 14);

    if(handleST_Higher == INVALID_HANDLE || handleADX_Exec == INVALID_HANDLE || 
       handleBB_Exec == INVALID_HANDLE || handleATR_Exec == INVALID_HANDLE)
    {
        Print("Error initializing handles");
        return(INIT_FAILED);
    }

    return(INIT_SUCCEEDED);
}

// === OnDeinit ===
void OnDeinit(const int reason)
{
    IndicatorRelease(handleST_Higher);
    IndicatorRelease(handleADX_Exec);
    IndicatorRelease(handleBB_Exec);
    IndicatorRelease(handleATR_Exec);
}

// === OnTick ===
void OnTick()
{
    // 1. Check Spread
    double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(spread > (double)InpMaxSpread) return;

    // 2. Check Position Count
    if(PositionSelectByMagic(InpMagicNum))
    {
        ManageTrailingStop();
        return; 
    }

    // 3. Data Buffers
    double adx[], bb_upper[], bb_lower[], bb_mid[], atr[];
    ArraySetAsSeries(adx, true);
    ArraySetAsSeries(bb_upper, true);
    ArraySetAsSeries(bb_lower, true);
    ArraySetAsSeries(bb_mid, true);
    ArraySetAsSeries(atr, true);

    if(CopyBuffer(handleADX_Exec, 0, 0, 2, adx) <= 0) return;
    if(CopyBuffer(handleBB_Exec, 1, 0, 20, bb_upper) <= 0) return;
    if(CopyBuffer(handleBB_Exec, 2, 0, 20, bb_lower) <= 0) return;
    if(CopyBuffer(handleBB_Exec, 0, 0, 20, bb_mid) <= 0) return;
    if(CopyBuffer(handleATR_Exec, 0, 0, 20, atr) <= 0) return;

    // Calculate BB Width and Average Width
    double current_width = bb_upper[0] - bb_lower[0];
    double sum_width = 0;
    for(int i=1; i<20; i++) sum_width += (bb_upper[i] - bb_lower[i]);
    double avg_width = sum_width / 19.0;

    // 4. SuperTrend Logic (Higher TF)
    double close_higher[];
    ArraySetAsSeries(close_higher, true);
    if(CopyClose(_Symbol, InpHigherTF, 0, 1, close_higher) <= 0) return;
    
    int handleMA_Higher = iMA(_Symbol, InpHigherTF, InpSTPeriod, 0, MODE_SMA, PRICE_CLOSE);
    double ma_higher[];
    ArraySetAsSeries(ma_higher, true);
    if(CopyBuffer(handleMA_Higher, 0, 0, 1, ma_higher) <= 0) 
    {
        IndicatorRelease(handleMA_Higher);
        return;
    }
    IndicatorRelease(handleMA_Higher);

    bool higher_trend_up = (close_higher[0] > ma_higher[0]);
    bool higher_trend_down = (close_higher[0] < ma_higher[0]);

    // 5. Entry Conditions
    double ask_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    bool vol_expansion = (current_width >= avg_width * InpBBThreshold);
    bool adx_active = (adx[0] >= 35.0); // Increased from 30 to 35 to filter more noise

    // BUY
    if(higher_trend_up && adx_active && vol_expansion && bid_price > bb_mid[0])
    {
        // SL: ATR * 1.8 (Tightened for DD control)
        // TP: ATR * 5.0 (Expanded for PF improvement)
        double sl = bid_price - (atr[0] * 1.8); 
        double tp = bid_price + (atr[0] * 5.0); 
        if(trade.Buy(InpLotSize, _Symbol, ask_price, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "TEB Buy"))
        {
            Print("Buy Order Sent");
        }
    }
    // SELL
    else if(higher_trend_down && adx_active && vol_expansion && ask_price < bb_mid[0])
    {
        // SL: ATR * 1.8 (Tightened for DD control)
        // TP: ATR * 5.0 (Expanded for PF improvement)
        double sl = ask_price + (atr[0] * 1.8); 
        double tp = ask_price - (atr[0] * 5.0); 
        if(trade.Sell(InpLotSize, _Symbol, bid_price, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "TEB Sell"))
        {
            Print("Sell Order Sent");
        }
    }
}
