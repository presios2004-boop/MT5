//+------------------------------------------------------------------+
//|                                Dual-Regime Adaptive Scalper.mq5 |
//|                                  Copyright 2024, MQL5 Expert    |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;    // Higher Timeframe
input double          InpLotSize     = 0.1;          // Fixed Lot Size
input int             InpMagicNum    = 202600801;    // Magic Number
input double          InpMaxSpread   = 5.0;          // Max Spread (Pips)
input int             InpSlippage    = 30;           // Slippage (Points)
input int             InpStateMinBars = 8;           // Min Bars in State (Increased to filter noise)

//--- Constants
#define STATE_TREND 1
#define STATE_RANGE 2

//--- Global Variables
int h_adx, h_bb, h_ema_s, h_ema_l, h_atr;
CTrade trade;
double pips_multiplier;

//--- Regime State
enum ENUM_REGIME { REGIME_TREND, REGIME_RANGE };
ENUM_REGIME current_regime = REGIME_RANGE;
int g_bars_in_state = 0;
datetime g_last_bar = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    pips_multiplier = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;

    // Optimized Handles
    h_adx    = iADX(_Symbol, InpExecutionTF, 14);
    h_bb     = iBands(_Symbol, InpExecutionTF, 20, 0, 2.0, PRICE_CLOSE);
    h_ema_s  = iMA(_Symbol, InpExecutionTF, 10, 0, MODE_EMA, PRICE_CLOSE);
    h_ema_l  = iMA(_Symbol, InpExecutionTF, 50, 0, MODE_EMA, PRICE_CLOSE);
    h_atr    = iATR(_Symbol, InpExecutionTF, 14);

    if(h_adx == INVALID_HANDLE || h_bb == INVALID_HANDLE || h_ema_s == INVALID_HANDLE || 
       h_ema_l == INVALID_HANDLE || h_atr == INVALID_HANDLE)
    {
        Print("Error initializing handles");
        return(INIT_FAILED);
    }

    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetDeviationInPoints(InpSlippage);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(h_adx);
    IndicatorRelease(h_bb);
    IndicatorRelease(h_ema_s);
    IndicatorRelease(h_ema_l);
    IndicatorRelease(h_atr);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. New Bar Check
    datetime t = iTime(_Symbol, InpExecutionTF, 0);
    if(t == g_last_bar) 
    { 
        ManageExits(); 
        return; 
    }
    g_last_bar = t;
    g_bars_in_state++;

    // 2. Spread Check
    double current_spread_pips = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / (_Point * pips_multiplier);
    if(current_spread_pips > InpMaxSpread) return;

    // 3. Data Buffers
    double adx[], bb_upper[], bb_lower[], ema_s[], ema_l[], atr[], close_exec[];
    
    if(CopyBuffer(h_adx, 0, 1, 2, adx) < 2) return;
    if(CopyBuffer(h_bb, 1, 1, 2, bb_upper) < 2) return;
    if(CopyBuffer(h_bb, 2, 1, 2, bb_lower) < 2) return;
    if(CopyBuffer(h_ema_s, 0, 1, 2, ema_s) < 2) return;
    if(CopyBuffer(h_ema_l, 0, 1, 2, ema_l) < 2) return;
    if(CopyBuffer(h_atr, 0, 1, 2, atr) < 2) return;
    if(CopyClose(_Symbol, InpExecutionTF, 1, 2, close_exec) < 2) return;

    // 4. Regime Detection with Stricter Thresholds to prevent whipsaws
    ENUM_REGIME next_regime = current_regime;
    double adx_val = adx[0]; 
    
    // Increased Trend Threshold: 35.0 -> 38.0
    // Increased Range Threshold: 25.0 -> 28.0
    if(adx_val > 38.0) next_regime = REGIME_TREND;
    else if(adx_val < 28.0) next_regime = REGIME_RANGE;

    if(next_regime != current_regime)
    {
        if(g_bars_in_state >= InpStateMinBars)
        {
            current_regime = next_regime;
            g_bars_in_state = 0;
        }
    }

    // 5. Position Management
    if(PositionSelectByMagic(_Symbol, InpMagicNum))
    {
        ManageExits();
        return;
    }

    // 6. Entry Logic
    bool trend_up = (ema_l[0] > ema_l[1]);
    bool trend_down = (ema_l[0] < ema_l[1]);

    if(current_regime == REGIME_TREND)
    {
        // BUY TREND
        bool ema_cross_up = (ema_s[0] > ema_l[0] && ema_s[1] <= ema_l[1]);
        if(trend_up && close_exec[0] > ema_l[0] && ema_cross_up)
        {
            double sl = close_exec[0] - (atr[0] * 2.5); // Slightly wider SL for trend stability
            double tp = 0;
            if(!trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Trend Buy"))
                Print("Buy Error: ", GetLastError());
        }
        // SELL TREND
        bool ema_cross_down = (ema_s[0] < ema_l[0] && ema_s[1] >= ema_l[1]);
        if(trend_down && close_exec[0] < ema_l[0] && ema_cross_down)
        {
            double sl = close_exec[0] + (atr[0] * 2.5);
            double tp = 0;
            if(!trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Trend Sell"))
                Print("Sell Error: ", GetLastError());
        }
    }
    else if(current_regime == REGIME_RANGE)
    {
        // BUY RANGE
        if(close_exec[0] < bb_lower[0])
        {
            double sl = close_exec[0] - (atr[0] * 1.5);
            double tp = close_exec[0] + (atr[0] * 6.0); // Increased TP for PF improvement
            if(!trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Range Buy"))
                Print("Buy Error: ", GetLastError());
        }
        // SELL RANGE
        if(close_exec[0] > bb_upper[0])
        {
            double sl = close_exec[0] + (atr[0] * 1.5);
            double tp = close_exec[0] - (atr[0] * 6.0); // Increased TP for PF improvement
            if(!trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Range Sell"))
                Print("Sell Error: ", GetLastError());
        }
    }
}

//+------------------------------------------------------------------+
//| Manage Exits and Trailing Stop                                   |
//+------------------------------------------------------------------+
void ManageExits()
{
    if(!PositionSelectByMagic(_Symbol, InpMagicNum)) return;

    long type = PositionGetInteger(POSITION_TYPE);
    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_sl = PositionGetDouble(POSITION_SL);
    double current_tp = PositionGetDouble(POSITION_TP);
    double cur_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double atr_val[];
    if(CopyBuffer(h_atr, 0, 1, 1, atr_val) < 1) return;
    double atr = atr_val[0];

    if(current_regime == REGIME_TREND)
    {
        double profit_points = MathAbs(cur_price - open_price);
        // Trigger: 2.5 ATR | Width: 0.7 ATR
        double trigger_dist = atr * 2.5;
        double trail_width = atr * 0.7;

        if(profit_points >= trigger_dist)
        {
            if(type == POSITION_TYPE_BUY)
            {
                double new_sl = cur_price - trail_width;
                if(new_sl > current_sl + _Point) 
                {
                    if(!trade.PositionModify(_Symbol, new_sl, current_tp))
                        Print("Modify Error: ", GetLastError());
                }
            }
            else
            {
                double new_sl = cur_price + trail_width;
                if(new_sl < current_sl - _Point || current_sl == 0) 
                {
                    if(!trade.PositionModify(_Symbol, new_sl, current_tp))
                        Print("Modify Error: ", GetLastError());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Helper: Select position by Magic Number                          |
//+------------------------------------------------------------------+
bool PositionSelectByMagic(string symbol, int magic)
{
    for(int i=PositionsTotal()-1; i>=0; i--)
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
