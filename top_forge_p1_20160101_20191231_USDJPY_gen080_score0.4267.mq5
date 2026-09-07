#property strict
#include <Trade\Trade.mqh>

//--- Input Parameters
input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4; // Execution Timeframe
input double         InpLotSize      = 0.1;       // Lot Size
input int            InpMagicNum     = 202600801; // Magic Number
input double         InpMaxSpread    = 5.0;       // Max Spread (pips)

//--- Indicator Parameters
input int            InpEnvPeriod    = 18;        // Envelopes Period
input double         InpEnvDeviation = 0.45;      // Envelopes Deviation
input int            InpDemPeriod    = 12;        // DeMarker Period
input int            InpAtrPeriod    = 14;        // ATR Period
input double         InpSlAtrMult    = 1.3;       // SL ATR Multiplier (Reduced for DD control)
input double         InpTpAtrMult    = 6.5;       // TP ATR Multiplier (Increased for PF improvement)
input double         InpTrailStart   = 1.2;       // Trailing Start ATR Multiplier
input double         InpTrailDist    = 1.0;       // Trailing Distance ATR Multiplier

//--- Global Variables
CTrade trade;
int    handleEnv     = INVALID_HANDLE;
int    handleDem     = INVALID_HANDLE;
int    handleATR     = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    handleEnv = iEnvelopes(_Symbol, InpExecutionTF, InpEnvPeriod, 0, MODE_SMA, PRICE_CLOSE, InpEnvDeviation);
    if(handleEnv == INVALID_HANDLE) return INIT_FAILED;

    handleDem = iDeMarker(_Symbol, InpExecutionTF, InpDemPeriod);
    if(handleDem == INVALID_HANDLE) return INIT_FAILED;

    handleATR = iATR(_Symbol, InpExecutionTF, InpAtrPeriod);
    if(handleATR == INVALID_HANDLE) return INIT_FAILED;

    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetDeviationInPoints(30); 
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handleEnv);
    IndicatorRelease(handleDem);
    IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    static datetime g_last_bar = 0;
    datetime t = iTime(_Symbol, InpExecutionTF, 0);
    if(t == g_last_bar) 
    { 
        ManageTrailingStop();
        return; 
    }
    g_last_bar = t;

    if(!IsSpreadOK()) return;

    if(PositionSelectByMagic()) 
    {
        ManageTrailingStop();
        return;
    }

    CheckEntry();
}

//+------------------------------------------------------------------+
//| Check for Entry Conditions                                       |
//+------------------------------------------------------------------+
void CheckEntry()
{
    double envUpper[], envLower[], dem[], close[];
    ArraySetAsSeries(envUpper, true);
    ArraySetAsSeries(envLower, true);
    ArraySetAsSeries(dem, true);
    ArraySetAsSeries(close, true);

    if(CopyBuffer(handleEnv, 0, 1, 2, envUpper) < 2) return;
    if(CopyBuffer(handleEnv, 1, 1, 2, envLower) < 2) return;
    if(CopyBuffer(handleDem, 0, 1, 2, dem) < 2) return;
    if(CopyClose(_Symbol, InpExecutionTF, 1, 2, close) < 2) return;

    bool buy_trigger  = (dem[0] > 0.6 && dem[1] <= 0.6);
    bool sell_trigger = (dem[0] < 0.4 && dem[1] >= 0.4);
    
    bool buy_trend    = (close[0] > envUpper[0]);
    bool sell_trend   = (close[0] < envLower[0]);

    if(buy_trigger && buy_trend)
    {
        ExecuteOrder(ORDER_TYPE_BUY);
    }
    else if(sell_trigger && sell_trend)
    {
        ExecuteOrder(ORDER_TYPE_SELL);
    }
}

//+------------------------------------------------------------------+
//| Execute Trade with ATR-based SL/TP                               |
//+------------------------------------------------------------------+
void ExecuteOrder(ENUM_ORDER_TYPE type)
{
    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1) return;
    
    double atr_val = atr[0];
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    double sl, tp;
    if(type == ORDER_TYPE_BUY)
    {
        sl = price - (atr_val * InpSlAtrMult);
        tp = price + (atr_val * InpTpAtrMult);
        if(!trade.Buy(InpLotSize, _Symbol, price, sl, tp))
        {
            Print("Buy Order Failed: ", GetLastError());
        }
    }
    else
    {
        sl = price + (atr_val * InpSlAtrMult);
        tp = price - (atr_val * InpTpAtrMult);
        if(!trade.Sell(InpLotSize, _Symbol, price, sl, tp))
        {
            Print("Sell Order Failed: ", GetLastError());
        }
    }
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(!PositionSelectByMagic()) return;

    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1) return;
    double atr_val = atr[0];

    double pos_open = PositionGetDouble(POSITION_PRICE_OPEN);
    double pos_sl   = PositionGetDouble(POSITION_SL);
    double pos_tp   = PositionGetDouble(POSITION_TP);
    double cur_price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    if(type == POSITION_TYPE_BUY)
    {
        if(cur_price - pos_open > atr_val * InpTrailStart)
        {
            double new_sl = cur_price - (atr_val * InpTrailDist);
            if(new_sl > pos_sl + _Point * 10) 
            {
                if(!trade.PositionModify(_Symbol, new_sl, pos_tp))
                    Print("Trailing Buy Modify Failed: ", GetLastError());
            }
        }
    }
    else if(type == POSITION_TYPE_SELL)
    {
        if(pos_open - cur_price > atr_val * InpTrailStart)
        {
            double new_sl = cur_price + (atr_val * InpTrailDist);
            if(new_sl < pos_sl - _Point * 10 || pos_sl == 0) 
            {
                if(!trade.PositionModify(_Symbol, new_sl, pos_tp))
                    Print("Trailing Sell Modify Failed: ", GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
    return (spread <= InpMaxSpread * 10);
}

bool PositionSelectByMagic()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
        }
    }
    return false;
}
