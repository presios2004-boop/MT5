#property copyright "Copyright 2024, Expert Advisor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H4;
input double           InpLotSize    = 0.1;
input int              InpMagicNum   = 202600801;
input double           InpMaxSpread  = 5.0; // pips
input int              InpSlippage   = 30;  // points (3 pips)
input int              InpATRPeriod  = 14;

//--- Global Variables
CTrade         m_trade;
CPositionInfo  m_position;
int            m_handle_atr;
double         m_pips_multiplier;

//--- Constants for Strategy (Adjusted for higher Recovery Factor)
const double TARGET_BODY_RATIO_BUY  = 0.6;
const double TARGET_BODY_RATIO_SELL = 0.4;
const double TARGET_VOL_EXPANSION   = 1.5;
const double TARGET_LINEARITY       = 0.7;
const double SL_ATR_MULT            = 1.3;   // Tightened from 1.5 to improve RF
const double TP_RR_RATIO            = 5.0;   // Increased from 4.5 to improve PF
const double TRAIL_START_ATR_MULT   = 1.5;
const double TRAIL_STEP_ATR_MULT    = 0.5;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    m_trade.SetExpertMagicNumber(InpMagicNum);
    m_trade.SetDeviationInPoints(InpSlippage);

    // Handle pips multiplier for 3/5 digit brokers
    double digits = SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    if(digits == 3 || digits == 5)
        m_pips_multiplier = 10.0 * _Point;
    else
        m_pips_multiplier = _Point;

    m_handle_atr = iATR(_Symbol, InpExecutionTF, InpATRPeriod);
    if(m_handle_atr == INVALID_HANDLE)
    {
        Print("Failed to create ATR handle");
        return(INIT_FAILED);
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(m_handle_atr);
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
    double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if(spread > InpMaxSpread * m_pips_multiplier) return;

    // 3. Check Existing Positions (Max 1)
    int pos_count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(m_position.SelectByIndex(i))
        {
            if(m_position.Magic() == InpMagicNum && m_position.Symbol() == _Symbol)
            {
                pos_count++;
                ManageTrailingStop();
            }
        }
    }

    // 4. Entry Logic
    if(pos_count == 0)
    {
        CheckForEntry();
    }
}

//+------------------------------------------------------------------+
//| Entry Logic                                                      |
//+------------------------------------------------------------------+
void CheckForEntry()
{
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    if(CopyRates(_Symbol, InpExecutionTF, 0, 3, rates) < 3) return;

    // Use index 1 for the completed candle
    double open  = rates[1].open;
    double high  = rates[1].high;
    double low   = rates[1].low;
    double close = rates[1].close;
    double total_range = high - low;
    if(total_range <= 0) return;

    double body = MathAbs(close - open);
    double body_ratio = body / total_range;

    // Volatility Expansion (Current Range / Avg Range)
    double atr_buffer[];
    ArraySetAsSeries(atr_buffer, true);
    // Use index 1 for the completed ATR value
    if(CopyBuffer(m_handle_atr, 0, 1, 2, atr_buffer) < 2) return;
    double avg_range = atr_buffer[0]; 
    double vol_expansion = (avg_range > 0) ? (total_range / avg_range) : 0;

    // Linearity (Net Movement / Total Path)
    double net_movement = MathAbs(close - open);
    double linearity = (total_range > 0) ? (net_movement / total_range) : 0;

    // ATR for SL/TP
    double current_atr = atr_buffer[0];

    // BUY Condition
    if(body_ratio > TARGET_BODY_RATIO_BUY && vol_expansion > TARGET_VOL_EXPANSION && linearity > TARGET_LINEARITY)
    {
        if(close > open) // Ensure it's a bullish bar
        {
            double sl = close - (current_atr * SL_ATR_MULT);
            double tp = close + (current_atr * SL_ATR_MULT * TP_RR_RATIO);
            if(m_trade.Buy(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "Explosive Buy"))
            {
                Print("Buy Order Sent");
            }
        }
    }
    // SELL Condition
    else if(body_ratio < TARGET_BODY_RATIO_SELL && vol_expansion > TARGET_VOL_EXPANSION && linearity > TARGET_LINEARITY)
    {
        if(close < open) // Ensure it's a bearish bar
        {
            double sl = close + (current_atr * SL_ATR_MULT);
            double tp = close - (current_atr * SL_ATR_MULT * TP_RR_RATIO);
            if(m_trade.Sell(InpLotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "Explosive Sell"))
            {
                Print("Sell Order Sent");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Trailing Stop Logic                                              |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    double atr_buffer[];
    ArraySetAsSeries(atr_buffer, true);
    // Use index 1 for the completed ATR value
    if(CopyBuffer(m_handle_atr, 0, 1, 1, atr_buffer) < 1) return;
    double current_atr = atr_buffer[0];

    double price_open = m_position.PriceOpen();
    double price_current = m_position.PriceCurrent();
    double sl_current = m_position.StopLoss();
    
    if(m_position.PositionType() == POSITION_TYPE_BUY)
    {
        double profit_dist = price_current - price_open;
        if(profit_dist > current_atr * TRAIL_START_ATR_MULT)
        {
            double new_sl = price_current - (current_atr * TRAIL_STEP_ATR_MULT);
            if(new_sl > sl_current + _Point) 
            {
                m_trade.PositionModify(m_position.Ticket(), new_sl, m_position.TakeProfit());
            }
        }
    }
    else if(m_position.PositionType() == POSITION_TYPE_SELL)
    {
        double profit_dist = price_open - price_current;
        if(profit_dist > current_atr * TRAIL_START_ATR_MULT)
        {
            double new_sl = price_current + (current_atr * TRAIL_STEP_ATR_MULT);
            if(sl_current == 0 || new_sl < sl_current - _Point)
            {
                m_trade.PositionModify(m_position.Ticket(), new_sl, m_position.TakeProfit());
            }
        }
    }
}
