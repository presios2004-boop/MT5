//+------------------------------------------------------------------+
//|                                Dual-Regime Adaptive Switcher.mq5 |
//|                                  Copyright 2024, MQL5 Expert     |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;    // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;    // Higher Timeframe
input double          InpLotSize     = 0.1;          // Fixed Lot Size
input int             InpMagicNum    = 202600801;    // Magic Number
input int             InpMaxSpread   = 50;           // Max Spread (Points)
input int             InpSlippage    = 30;           // Slippage (Points)

//--- Indicator Parameters
input int             InpADXPeriod   = 28;           // ADX Period
input int             InpBBPeriod    = 20;           // Bollinger Bands Period
input double          InpBBDev       = 2.0;          // Bollinger Bands Deviation
input int             InpATRPeriod   = 14;           // ATR Period
input int             InpRSIPeriod   = 14;           // RSI Period
input int             InpEMAPeriod   = 20;           // EMA Period for Trend
input int             InpSMAPeriod   = 200;          // SMA Period for ATR Filter

//--- Global Variables
int      handleADX, handleBB, handleATR, handleRSI, handleEMA, handleSMA_ATR;
CTrade   trade;
enum ENUM_STATE { STATE_TREND, STATE_RANGE, STATE_NONE };
ENUM_STATE current_state = STATE_NONE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetDeviationInPoints(InpSlippage);

    handleADX     = iADX(_Symbol, InpExecutionTF, InpADXPeriod);
    handleBB      = iBands(_Symbol, InpExecutionTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
    handleATR     = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
    handleRSI     = iRSI(_Symbol, InpExecutionTF, InpRSIPeriod, PRICE_CLOSE);
    handleEMA     = iMA(_Symbol, InpExecutionTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    
    // For ATR SMA filter, we need a handle for ATR on the execution TF, 
    // then we calculate SMA of that ATR buffer manually or via iMA on ATR handle.
    // Since MQL5 doesn't allow iMA on a handle directly easily without custom indicator, 
    // we will use a buffer approach in OnTick.
    handleSMA_ATR = iMA(_Symbol, InpExecutionTF, InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE); 
    // Note: The requirement says SMA(ATR, 200). In MQL5, to get SMA of ATR, 
    // we must calculate it from ATR buffer.
    
    if(handleADX == INVALID_HANDLE || handleBB == INVALID_HANDLE || 
       handleATR == INVALID_HANDLE || handleRSI == INVALID_HANDLE || 
       handleEMA == INVALID_HANDLE)
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
    IndicatorRelease(handleADX);
    IndicatorRelease(handleBB);
    IndicatorRelease(handleATR);
    IndicatorRelease(handleRSI);
    IndicatorRelease(handleEMA);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. Check Spread
    double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(spread > InpMaxSpread) return;

    // 2. Check Existing Positions
    bool hasPosition = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
                hasPosition = true;
                ManageTrailingStop();
                break;
            }
        }
    }

    // 3. Regime Detection
    double adx_buffer[];
    ArraySetAsSeries(adx_buffer, true);
    if(CopyBuffer(handleADX, 0, 0, 2, adx_buffer) < 2) return;
    
    double current_adx = adx_buffer[0];
    if(current_adx > 25.0)      current_state = STATE_TREND;
    else if(current_adx < 20.0) current_state = STATE_RANGE;

    // 4. Volatility Filter (ATR > SMA(ATR, 200) * 0.7)
    double atr_buffer[];
    ArraySetAsSeries(atr_buffer, true);
    if(CopyBuffer(handleATR, 0, 0, 201, atr_buffer) < 201) return;
    
    double current_atr = atr_buffer[0];
    double sum_atr = 0;
    for(int i=0; i<InpSMAPeriod; i++) sum_atr += atr_buffer[i];
    double sma_atr = sum_atr / InpSMAPeriod;

    if(current_atr <= sma_atr * 0.7) return;

    // 5. Entry Logic
    if(!hasPosition)
    {
        double close_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        
        // Get Indicator Values
        double bb_upper[], bb_lower[], rsi[], ema[];
        ArraySetAsSeries(bb_upper, true); ArraySetAsSeries(bb_lower, true);
        ArraySetAsSeries(rsi, true); ArraySetAsSeries(ema, true);
        
        if(CopyBuffer(handleBB, 1, 0, 1, bb_upper) < 1) return;
        if(CopyBuffer(handleBB, 2, 0, 1, bb_lower) < 1) return;
        if(CopyBuffer(handleRSI, 0, 0, 1, rsi) < 1) return;
        if(CopyBuffer(handleEMA, 0, 0, 1, ema) < 1) return;

        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if(current_state == STATE_TREND)
        {
            // BUY: Price > Upper BB AND Price > EMA
            if(bid > bb_upper[0] && bid > ema[0])
            {
                double sl = bid - (current_atr * 2.0);
                double tp = bid + (current_atr * 2.0 * 1.5);
                trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Trend Buy");
            }
            // SELL: Price < Lower BB AND Price < EMA
            else if(ask < bb_lower[0] && ask < ema[0])
            {
                double sl = ask + (current_atr * 2.0);
                double tp = ask - (current_atr * 2.0 * 1.5);
                trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Trend Sell");
            }
        }
        else if(current_state == STATE_RANGE)
        {
            // BUY: Price < Lower BB AND RSI < 30
            if(ask < bb_lower[0] && rsi[0] < 30.0)
            {
                double sl = ask - (current_atr * 2.0);
                double tp = ask + (current_atr * 2.0 * 1.5);
                trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Range Buy");
            }
            // SELL: Price > Upper BB AND RSI > 70
            else if(bid > bb_upper[0] && rsi[0] > 70.0)
            {
                double sl = bid + (current_atr * 2.0);
                double tp = bid - (current_atr * 2.0 * 1.5);
                trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Range Sell");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Trailing Stop Logic (Trend Mode Only)                            |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    // Only for Trend Mode
    if(current_state != STATE_TREND) return;

    double atr_buffer[];
    ArraySetAsSeries(atr_buffer, true);
    if(CopyBuffer(handleATR, 0, 0, 1, atr_buffer) < 1) return;
    double atr = atr_buffer[0];

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
                double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
                double current_sl = PositionGetDouble(POSITION_SL);
                double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
                ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

                if(type == POSITION_TYPE_BUY)
                {
                    // Trigger: Profit > ATR * 1.5
                    if(current_price - open_price > atr * 1.5)
                    {
                        double new_sl = current_price - (atr * 0.5); // Step logic simplified to ATR 0.5
                        // Ensure SL only moves up
                        if(new_sl > current_sl + (atr * 0.1)) 
                        {
                            trade.PositionModify(ticket, NormalizeDouble(new_sl, _Digits), PositionGetDouble(POSITION_TP));
                        }
                    }
                }
                else if(type == POSITION_TYPE_SELL)
                {
                    // Trigger: Profit > ATR * 1.5
                    if(open_price - current_price > atr * 1.5)
                    {
                        double new_sl = current_price + (atr * 0.5);
                        // Ensure SL only moves down
                        if(current_sl == 0 || new_sl < current_sl - (atr * 0.1))
                        {
                            trade.PositionModify(ticket, NormalizeDouble(new_sl, _Digits), PositionGetDouble(POSITION_TP));
                        }
                    }
                }
            }
        }
    }
}
