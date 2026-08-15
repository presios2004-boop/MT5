//+------------------------------------------------------------------+
//|                                    AdaptiveMomentumHybrid.mq5    |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- Enums
enum ENUM_STATE
{
    STATE_RANGE,
    STATE_TREND
};

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_M30; // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H4;  // Higher Timeframe
input double          InpLotSize     = 0.1;        // Fixed Lot Size
input int             InpMagicNum    = 202600801;  // Magic Number
input double          InpMaxSpread   = 5.0;        // Max Spread (Pips)
input int             InpSlippage    = 30;         // Slippage (Points)
input int             InpStateMinBars = 30;        // Min Bars in State (Cooldown)

//--- Indicator Handles
int handleKAMA;
int handleEMA;
int handleATR;

//--- Global Variables
CTrade trade;
double pips_multiplier;
ENUM_STATE g_state = STATE_RANGE;
int        g_bars_in_state = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    pips_multiplier = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;

    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetDeviationInPoints(InpSlippage);

    // Adjusted MA periods to reduce noise and frequency of trades
    handleKAMA = iMA(_Symbol, InpExecutionTF, 40, 0, MODE_SMA, PRICE_CLOSE);
    handleEMA  = iMA(_Symbol, InpExecutionTF, 35, 0, MODE_EMA, PRICE_CLOSE);
    handleATR  = iATR(_Symbol, InpExecutionTF, 14);

    if(handleKAMA == INVALID_HANDLE || handleEMA == INVALID_HANDLE || handleATR == INVALID_HANDLE)
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
    IndicatorRelease(handleKAMA);
    IndicatorRelease(handleEMA);
    IndicatorRelease(handleATR);
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
    double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
    double spread_pips = spread / (_Point * pips_multiplier);
    if(spread_pips > InpMaxSpread) return;

    // 3. Detect Regime (State Management)
    DetectRegime();

    // 4. Check Position Count
    if(PositionSelectByMagic(InpMagicNum))
    {
        ManageTrailingStop();
        return; 
    }

    // 5. Get Indicator Data (Using Closed Bars: start_pos = 1)
    double kama[], ema[], atr[], close[], high[], low[];
    ArraySetAsSeries(kama, true);
    ArraySetAsSeries(ema, true);
    ArraySetAsSeries(atr, true);
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    if(CopyBuffer(handleKAMA, 0, 1, 2, kama) < 2) return;
    if(CopyBuffer(handleEMA, 0, 1, 2, ema) < 2) return;
    if(CopyBuffer(handleATR, 0, 1, 200, atr) < 200) return;
    if(CopyClose(_Symbol, InpExecutionTF, 1, 2, close) < 2) return;
    if(CopyHigh(_Symbol, InpExecutionTF, 1, 2, high) < 2) return;
    if(CopyLow(_Symbol, InpExecutionTF, 1, 2, low) < 2) return;

    // Calculate ATR Average (200 periods)
    double sum_atr = 0;
    for(int i=0; i<200; i++) sum_atr += atr[i];
    double avg_atr_200 = sum_atr / 200.0;

    // Elder Ray Calculation (Bull Power = High - EMA, Bear Power = Low - EMA)
    double bull_p0 = high[0] - ema[0];
    double bull_p1 = high[1] - ema[1];
    double bear_p0 = low[0] - ema[0];
    double bear_p1 = low[1] - ema[1];

    // 6. Entry Logic (Only in Trend State)
    if(g_state == STATE_TREND)
    {
        // Increased threshold from 1.5 to 1.8 to reduce overtrading
        bool atr_condition = atr[0] > (avg_atr_200 * 1.8);
        
        // BUY Condition
        if(kama[0] < close[0] && bull_p0 > 0 && bull_p0 > bull_p1 && atr_condition)
        {
            // Reduced SL multiplier from 2.5 to 1.8 to protect drawdown
            double sl = close[0] - (atr[0] * 1.8);
            // Increased TP multiplier from 6.0 to 8.0 to improve PF
            double tp = close[0] + (atr[0] * 1.8 * 8.0);
            if(trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "AMH Buy"))
                Print("Buy Order Sent");
        }
        // SELL Condition
        else if(kama[0] > close[0] && bear_p0 < 0 && bear_p0 < bear_p1 && atr_condition)
        {
            // Reduced SL multiplier from 2.5 to 1.8 to protect drawdown
            double sl = close[0] + (atr[0] * 1.8);
            // Increased TP multiplier from 6.0 to 8.0 to improve PF
            double tp = close[0] - (atr[0] * 1.8 * 8.0);
            if(trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "AMH Sell"))
                Print("Sell Order Sent");
        }
    }
}

//+------------------------------------------------------------------+
//| Detect Regime with Cooldown                                      |
//+------------------------------------------------------------------+
void DetectRegime()
{
    double kama[], close[], ema[], high[], low[];
    ArraySetAsSeries(kama, true);
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(ema, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    if(CopyBuffer(handleKAMA, 0, 1, 2, kama) < 2) return;
    if(CopyClose(_Symbol, InpExecutionTF, 1, 2, close) < 2) return;
    if(CopyBuffer(handleEMA, 0, 1, 2, ema) < 2) return;
    if(CopyHigh(_Symbol, InpExecutionTF, 1, 2, high) < 2) return;
    if(CopyLow(_Symbol, InpExecutionTF, 1, 2, low) < 2) return;

    // Simple Trend Logic: Price distance from KAMA and Bull/Bear Power direction
    // Increased distance threshold from 0.0015 to 0.0020 to filter noise
    bool is_trending = (MathAbs(close[0] - kama[0]) > (ema[0] * 0.0020)) && (high[0]-ema[0] > 0 || low[0]-ema[0] < 0);
    
    ENUM_STATE next_state = is_trending ? STATE_TREND : STATE_RANGE;

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
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(!PositionSelectByMagic(InpMagicNum)) return;

    double atr_val[];
    ArraySetAsSeries(atr_val, true);
    if(CopyBuffer(handleATR, 0, 1, 1, atr_val) < 1) return;
    double current_atr = atr_val[0];

    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
    double current_sl = PositionGetDouble(POSITION_SL);
    long type = PositionGetInteger(POSITION_TYPE);

    if(type == POSITION_TYPE_BUY)
    {
        double profit_dist = current_price - open_price;
        // Trigger trailing when profit is 2.5 ATR
        if(profit_dist >= current_atr * 2.5)
        {
            double target_sl = current_price - (current_atr * 0.7);
            if(target_sl > current_sl + 0.00001)
            {
                trade.PositionModify(_Symbol, target_sl, PositionGetDouble(POSITION_TP));
            }
        }
    }
    else if(type == POSITION_TYPE_SELL)
    {
        double profit_dist = open_price - current_price;
        // Trigger trailing when profit is 2.5 ATR
        if(profit_dist >= current_atr * 2.5)
        {
            double target_sl = current_price + (current_atr * 0.7);
            if(current_sl == 0 || target_sl < current_sl - 0.00001)
            {
                trade.PositionModify(_Symbol, target_sl, PositionGetDouble(POSITION_TP));
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
