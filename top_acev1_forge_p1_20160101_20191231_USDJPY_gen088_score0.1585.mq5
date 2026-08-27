//+------------------------------------------------------------------+
//|                                     RoundNumberBreakoutEA.mq5    |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;    // Higher Timeframe
input double           InpLotSize    = 0.1;          // Fixed Lot Size
input int              InpMagicNum   = 202600801;    // Magic Number
input double           InpMaxSpread  = 5.0;          // Max Spread (Pips)
input int              InpSlippage   = 30;           // Slippage (Points)
input int              InpATRPeriod  = 14;           // ATR Period
input int              InpMAPeriod   = 20;           // Trend MA Period

//--- Global Variables
CTrade      trade;
int         handle_atr_exec;
int         handle_atr_high;
double      pips_multiplier;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetDeviationInPoints(InpSlippage);

    // Determine pips multiplier for 3/5 digit brokers
    double digits = SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    if(digits == 3 || digits == 5) pips_multiplier = 10.0 * _Point;
    else pips_multiplier = _Point;

    // Initialize Handles
    handle_atr_exec = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
    handle_atr_high = iATR(_Symbol, InpHigherTF, InpATRPeriod);

    if(handle_atr_exec == INVALID_HANDLE || handle_atr_high == INVALID_HANDLE)
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
    IndicatorRelease(handle_atr_exec);
    IndicatorRelease(handle_atr_high);
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
    double current_spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pips_multiplier;
    if(current_spread > InpMaxSpread) return;

    // 3. Check Position Count (Max 1)
    if(PositionSelectByMagic(InpMagicNum))
    {
        ManageTrailingStop();
        return;
    }

    // 4. Get Data for Conditions (Using index 1 for closed bar)
    double close_prices[];
    double open_prices[];
    long   volume_ticks[];
    double atr_values[];
    
    ArraySetAsSeries(close_prices, true);
    ArraySetAsSeries(open_prices, true);
    ArraySetAsSeries(volume_ticks, true);
    ArraySetAsSeries(atr_values, true);

    if(CopyClose(_Symbol, InpExecutionTF, 1, 13, close_prices) < 13) return;
    if(CopyOpen(_Symbol, InpExecutionTF, 1, 13, open_prices) < 13) return;
    if(CopyTickVolume(_Symbol, InpExecutionTF, 1, 13, volume_ticks) < 13) return;
    if(CopyBuffer(handle_atr_exec, 0, 1, 1, atr_values) < 1) return;

    double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    //--- RN_Dist Calculation
    double price_in_pips = current_price / pips_multiplier;
    double rn_val_pips = MathRound(price_in_pips / 50.0) * 50.0; 
    double nearest_rn_price = rn_val_pips * pips_multiplier;
    double rn_dist = MathAbs(current_price - nearest_rn_price) / pips_multiplier;

    //--- Breakout_Force Calculation (Ratio of current body to avg of last 12)
    double current_body = MathAbs(close_prices[0] - open_prices[0]);
    double sum_body = 0;
    for(int i=1; i<=12; i++) sum_body += MathAbs(close_prices[i] - open_prices[i]);
    double avg_body = sum_body / 12.0;
    double breakout_force = (avg_body > 0) ? (current_body / avg_body) : 0;

    //--- Vol_Ratio Calculation
    double sum_vol = 0;
    for(int i=1; i<=12; i++) sum_vol += (double)volume_ticks[i];
    double avg_vol = sum_vol / 12.0;
    double vol_ratio = (avg_vol > 0) ? ((double)volume_ticks[0] / avg_vol) : 0;

    //--- D1 Trend (Price vs Self-calculated MA)
    double d1_close[];
    double d1_open[];
    if(CopyClose(_Symbol, InpHigherTF, 1, InpMAPeriod + 1, d1_close) < InpMAPeriod) return;
    if(CopyOpen(_Symbol, InpHigherTF, 1, InpMAPeriod + 1, d1_open) < InpMAPeriod) return;
    
    ArraySetAsSeries(d1_close, true);
    ArraySetAsSeries(d1_open, true);

    double sum_ma = 0;
    for(int i=0; i<InpMAPeriod; i++) sum_ma += d1_close[i];
    double ma_d1_val = sum_ma / (double)InpMAPeriod;
    
    bool d1_up = (d1_close[0] > ma_d1_val);
    bool d1_down = (d1_close[0] < ma_d1_val);

    // 5. Entry Logic
    double atr = atr_values[0];
    
    // BUY Condition
    if(rn_dist < 15.0 && breakout_force > 2.0 && vol_ratio > 1.5 && current_price > nearest_rn_price && d1_up)
    {
        double sl = current_price - (atr * 2.0);
        double tp = current_price + (MathAbs(current_price - sl) * 5.0);
        
        if(trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "RN Breakout Buy"))
        {
            Print("Buy Order Sent");
        }
    }
    
    // SELL Condition
    if(rn_dist < 15.0 && breakout_force > 2.0 && vol_ratio > 1.5 && current_price < nearest_rn_price && d1_down)
    {
        double sl = current_price + (atr * 2.0);
        double tp = current_price - (MathAbs(current_price - sl) * 5.0);
        
        if(trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "RN Breakout Sell"))
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

    double atr_values[];
    if(CopyBuffer(handle_atr_exec, 0, 1, 1, atr_values) < 1) return;
    double atr = atr_values[0];

    double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double current_sl = PositionGetDouble(POSITION_SL);
    double current_tp = PositionGetDouble(POSITION_TP);
    
    double profit_pips = MathAbs(current_price - entry_price) / pips_multiplier;
    double atr_pips = atr / pips_multiplier;

    // Trigger: Profit >= ATR * 2.0
    if(profit_pips >= (atr_pips * 2.0))
    {
        if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
            double new_sl = current_price - (atr * 1.0);
            if(new_sl > current_sl + _Point) 
            {
                trade.PositionModify(_Symbol, new_sl, current_tp);
            }
        }
        else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
            double new_sl = current_price + (atr * 1.0);
            if(new_sl < current_sl - _Point || current_sl == 0) 
            {
                trade.PositionModify(_Symbol, new_sl, current_tp);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Helper: Select Position by Magic Number                          |
//+------------------------------------------------------------------+
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
