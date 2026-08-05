//+------------------------------------------------------------------+
//|                                  SuperTrend-CCI Trend Follower |
//|                                  Copyright 2024, MQL5 Expert    |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;    // Higher Timeframe
input int             InpST_Period   = 10;           // SuperTrend ATR Period
input double          InpST_Mult     = 3.0;          // SuperTrend Multiplier
input int             InpCCI_Period  = 14;           // CCI Period
input int             InpATR_Period  = 14;           // ATR Period for Volatility/SL
input double          InpMaxSpread   = 5.0;          // Max Spread (Pips)
input double          InpLotSize     = 0.1;          // Fixed Lot Size
input long            InpMagicNum    = 202600801;    // Magic Number

//--- Global Variables
int      handle_cci;
int      handle_atr;
int      handle_st_atr;
int      handle_st_close;
CTrade   trade;
double   pips_multiplier;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Setup Pip multiplier for 3/5 digit brokers
    double digits = SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    if(digits == 3 || digits == 5) pips_multiplier = 10.0 * _Point;
    else pips_multiplier = _Point;

    // Initialize Handles
    handle_cci = iCCI(_Symbol, InpExecutionTF, InpCCI_Period, PRICE_CLOSE);
    handle_atr = iATR(_Symbol, InpExecutionTF, InpATR_Period);
    
    // SuperTrend components (Approximated via ATR and Close for logic)
    handle_st_atr   = iATR(_Symbol, InpHigherTF, InpST_Period);
    handle_st_close = iMA(_Symbol, InpHigherTF, InpST_Period, 0, MODE_SMA, PRICE_CLOSE);

    if(handle_cci == INVALID_HANDLE || handle_atr == INVALID_HANDLE || 
       handle_st_atr == INVALID_HANDLE || handle_st_close == INVALID_HANDLE)
    {
        Print("Error initializing indicators");
        return(INIT_FAILED);
    }

    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetDeviationInPoints(30); // 3 pips for 5-digit

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handle_cci);
    IndicatorRelease(handle_atr);
    IndicatorRelease(handle_st_atr);
    IndicatorRelease(handle_st_close);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. Check Spread
    double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
    if(spread > InpMaxSpread * pips_multiplier) return;

    // 2. Manage Existing Positions (Trailing Stop)
    ManageTrailingStop();

    // 3. Check if position already exists
    if(PositionSelectByMagic(InpMagicNum)) return;

    // 4. Get Indicator Data
    double cci_buffer[];
    double atr_buffer[];
    double st_atr_buffer[];
    double st_close_buffer[];
    
    ArraySetAsSeries(cci_buffer, true);
    ArraySetAsSeries(atr_buffer, true);
    ArraySetAsSeries(st_atr_buffer, true);
    ArraySetAsSeries(st_close_buffer, true);

    if(CopyBuffer(handle_cci, 0, 0, 2, cci_buffer) < 2) return;
    if(CopyBuffer(handle_atr, 0, 0, 2, atr_buffer) < 2) return;
    if(CopyBuffer(handle_st_atr, 0, 0, 2, st_atr_buffer) < 2) return;
    if(CopyBuffer(handle_st_close, 0, 0, 2, st_close_buffer) < 2) return;

    // 5. SuperTrend Logic (Simplified for MTF implementation)
    // SuperTrend Up if Close > (Median - Mult * ATR) and Close < (Median + Mult * ATR)
    // We use the directionality: Close > UpperBand or Close < LowerBand
    // For this EA, we define Trend based on Close vs (Close +/- Mult*ATR)
    double st_upper = st_close_buffer[0] + (InpST_Mult * st_atr_buffer[0]);
    double st_lower = st_close_buffer[0] - (InpST_Mult * st_atr_buffer[0]);
    
    // We need to determine if we are in an uptrend or downtrend.
    // Since SuperTrend is a custom indicator, we simulate the trend direction:
    // If current close is above the previous period's calculated trend line.
    bool is_uptrend = (st_close_buffer[0] > st_close_buffer[1]); // Simplified trend proxy
    // More robust: check if price is above the trailing stop level
    // For the sake of this logic, we assume the direction is based on price relative to ATR bands
    bool higher_trend_up = (st_close_buffer[0] > (st_close_buffer[1] - InpST_Mult * st_atr_buffer[1]));
    bool higher_trend_dn = (st_close_buffer[0] < (st_close_buffer[1] + InpST_Mult * st_atr_buffer[1]));
    
    // Refined SuperTrend Direction Proxy
    bool st_up = (st_close_buffer[0] > st_close_buffer[1]); 
    // In a real SuperTrend, the line only moves up in uptrend. 
    // We will use a simplified version: Close > Prev Close + ATR logic
    bool trend_up = (st_close_buffer[0] > (st_close_buffer[1])); 
    // To strictly follow "SuperTrend is uptrend", we check if price is above the calculated floor
    double floor = st_close_buffer[1] - (InpST_Mult * st_atr_buffer[1]);
    double ceil  = st_close_buffer[1] + (InpST_Mult * st_atr_buffer[1]);
    
    // Re-evaluating trend direction based on price position
    bool st_is_up = (st_close_buffer[0] > floor);
    bool st_is_dn = (st_close_buffer[0] < ceil);
    // To avoid ambiguity, we use the standard SuperTrend logic:
    // If Close > Prev UpperBand (which becomes new support)
    bool direction_up = (st_close_buffer[0] > st_close_buffer[1]); 
    // Let's use a more reliable proxy for SuperTrend direction:
    // If Close > (Close[1] + ATR[1] * Mult) is false, but Close > (Close[1] - ATR[1] * Mult)
    // We will use the relationship between Close and the ATR band.
    bool is_st_up = (st_close_buffer[0] > (st_close_buffer[1] - InpST_Mult * st_atr_buffer[0]));
    // Actually, the most common way to detect SuperTrend direction in code without the indicator:
    // If Close[0] > Close[1] and Close[1] > LowerBand[1]
    bool st_up_signal = (st_close_buffer[0] > (st_close_buffer[1] - InpST_Mult * st_atr_buffer[0]));
    bool st_dn_signal = (st_close_buffer[0] < (st_close_buffer[1] + InpST_Mult * st_atr_buffer[0]));

    // 6. Volatility Condition (ATR must be increasing or above a threshold)
    // "ATR is exiting low volatility zone" -> ATR[0] > ATR[1]
    bool vol_ok = (atr_buffer[0] > atr_buffer[1]);

    // 7. Entry Execution
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // BUY: HigherTF SuperTrend Up AND ExecutionTF CCI crosses +100 AND Volatility OK
    if(st_up_signal && cci_buffer[0] > 100 && cci_buffer[1] <= 100 && vol_ok)
    {
        double sl_dist = atr_buffer[0] * 2.0;
        double sl = ask - sl_dist;
        double tp = ask + (sl_dist * 1.5);
        
        if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "ST-CCI Buy"))
        {
            Print("Buy Order Sent");
        }
    }
    // SELL: HigherTF SuperTrend Down AND ExecutionTF CCI crosses -100 AND Volatility OK
    else if(!st_up_signal && cci_buffer[0] < -100 && cci_buffer[1] >= -100 && vol_ok)
    {
        double sl_dist = atr_buffer[0] * 2.0;
        double sl = bid + sl_dist;
        double tp = bid - (sl_dist * 1.5);
        
        if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "ST-CCI Sell"))
        {
            Print("Sell Order Sent");
        }
    }
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(!PositionSelectByMagic(InpMagicNum)) return;

    double atr_buffer[];
    ArraySetAsSeries(atr_buffer, true);
    if(CopyBuffer(handle_atr, 0, 0, 1, atr_buffer) < 1) return;
    double current_atr = atr_buffer[0];

    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
    double current_sl = PositionGetDouble(POSITION_SL);
    long type = PositionGetInteger(POSITION_TYPE);

    if(type == POSITION_TYPE_BUY)
    {
        // Trigger: Profit > ATR * 1.5
        if(current_price - open_price > current_atr * 1.5)
        {
            // Trailing: Price drops by ATR * 1.0 from peak
            double new_sl = current_price - (current_atr * 1.0);
            if(new_sl > current_sl + _Point) 
            {
                trade.PositionModify(_Symbol, new_sl, PositionGetDouble(POSITION_TP));
            }
        }
    }
    else if(type == POSITION_TYPE_SELL)
    {
        // Trigger: Profit > ATR * 1.5
        if(open_price - current_price > current_atr * 1.5)
        {
            // Trailing: Price rises by ATR * 1.0 from peak
            double new_sl = current_price + (current_atr * 1.0);
            if(current_sl == 0 || new_sl < current_sl - _Point)
            {
                trade.PositionModify(_Symbol, new_sl, PositionGetDouble(POSITION_TP));
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Helper: Select Position by Magic Number                          |
//+------------------------------------------------------------------+
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
