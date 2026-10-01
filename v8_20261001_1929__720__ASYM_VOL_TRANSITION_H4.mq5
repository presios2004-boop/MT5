#include <Trade\Trade.mqh>

//--- Input Parameters
input double InpLotSize          = 0.1;    // Fixed Lot Size
input int    InpMagicNum         = 202600801;
input double InpMaxSpread        = 5.0;    // Max Spread (pips)
input int    InpMaxPositions     = 1;      // Max Positions

input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4; // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1; // Higher Timeframe

input double InpER_Threshold     = 0.1;    // ER Threshold
input double InpVol_Threshold    = 0.00347; // Volatility Threshold (ATR/Price)
input double InpJump_Multiplier  = 1.5;    // Jump Ratio Multiplier
input int    InpATR_Period       = 14;     // ATR Period
input int    InpATR_Vol_Period   = 30;     // ATR for Volatility check
input int    InpBB_Period        = 20;     // Bollinger Bands Period
input double InpBB_Dev           = 2.0;    // Bollinger Bands Deviation
input int    InpSMA_Macro_Period = 120;    // Macro SMA Period
input int    InpER_Period        = 60;     // ER Period

input double InpSL_ATR_BEAR_HV   = 2.5;    // SL ATR Multiplier (BEAR HV)
input double InpTP_ATR_BEAR_HV   = 3.0;    // TP ATR Multiplier (BEAR HV)
input double InpSL_ATR_BULL_LV   = 2.0;    // SL ATR Multiplier (BULL LV)
input double InpTP_ATR_BULL_LV   = 4.0;    // TP ATR Multiplier (BULL LV)
input double InpSL_ATR_FLAT      = 2.0;    // SL ATR Multiplier (FLAT)
input double InpTP_ATR_FLAT      = 2.5;    // TP ATR Multiplier (FLAT)

input int    InpMaxRetry         = 5;      // Retry Count
input int    InpRetryDelay       = 300;    // Retry Delay (ms)

//--- Enums
enum ENUM_REGIME { REGIME_HV_UP, REGIME_HV_DOWN, REGIME_HV_RANGE, REGIME_LV_UP, REGIME_LV_DOWN, REGIME_LV_RANGE, REGIME_UNKNOWN };
enum ENUM_MACRO  { MACRO_BULL, MACRO_BEAR, MACRO_FLAT };

//--- Global Variables
CTrade trade;
int hATR_exec, hATR_vol, hBB_exec, hSMA_macro, hSMA_h4;
double g_pendSlDist = 0.0;
double g_pendTpDist = 0.0;
bool   g_entryBusy  = false;
datetime g_lastEntryTry = 0;

//--- Regime Hysteresis
ENUM_REGIME g_last_regime = REGIME_UNKNOWN;
int g_hysteresis_counter = 0;

//================ OANDA 実発注ブロック ここから ================
#define OANDA_MIN_SL_PIPS  5.0      // 発注価格とSLの最小距離（OANDA制約）

input int InpMaxRetry_OANDA   = 5;        // 発注リトライ回数
input int InpRetryDelay_OANDA = 300;      // リトライ間隔(ms)

double PipSize()
{
    return((_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point);
}

double StopDist()
{
    long lv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    if(lv <= 0) lv = 5;
    double d     = lv * _Point;
    double minSl = OANDA_MIN_SL_PIPS * PipSize();
    return(d > minSl ? d : minSl);
}

double NormalizeLot(double lot)
{
    double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(mn <= 0) mn = 0.01;
    if(mx <= 0) mx = 100.0;
    if(st <= 0) st = 0.01;
    if(lot < mn) lot = mn;
    if(lot > mx) lot = mx;
    lot = MathFloor(lot / st) * st;
    int dg = (int)MathMax(-MathLog10(st), 0);
    lot = NormalizeDouble(lot, dg);
    if(lot < mn) lot = mn;
    return(lot);
}

bool CanTrade()
{
    if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return(false);
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED))       return(false);
    if(IsStopped())                              return(false);
    double a = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double b = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    return(a > 0 && b > 0);
}

bool IsSpreadOK()
{
    double a = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double b = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if(a <= 0 || b <= 0) return(false);
    return(((a - b) / PipSize()) <= InpMaxSpread);
}

void ClampBuySLTP(double price, double &sl, double &tp)
{
    double d = StopDist();
    if(sl > 0 && (price - sl) < d) sl = NormalizeDouble(price - d, _Digits);
    if(tp > 0 && (tp - price) < d) tp = NormalizeDouble(price + d, _Digits);
}

void ClampSellSLTP(double price, double &sl, double &tp)
{
    double d = StopDist();
    if(sl > 0 && (sl - price) < d) sl = NormalizeDouble(price + d, _Digits);
    if(tp > 0 && (price - tp) < d) tp = NormalizeDouble(price - d, _Digits);
}

ulong SafeBuy(double lot, double slDist, double tpDist)
{
    lot = NormalizeLot(lot);
    for(int i = 0; i < InpMaxRetry; i++)
    {
        if(!CanTrade()) { Sleep(InpRetryDelay); continue; }
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double sl  = ask - slDist;
        double tp  = (tpDist > 0) ? ask + tpDist : 0.0;
        ClampBuySLTP(ask, sl, tp);
        if(trade.Buy(lot, _Symbol, 0.0, sl, tp))
            if(trade.ResultOrder() > 0) return(trade.ResultOrder());
        Sleep(InpRetryDelay);
    }
    g_pendSlDist = slDist; g_pendTpDist = tpDist;
    for(int j = 0; j < InpMaxRetry; j++)
    {
        if(!CanTrade()) { Sleep(InpRetryDelay); continue; }
        if(trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0))
            if(trade.ResultOrder() > 0) return(trade.ResultOrder());
        Sleep(InpRetryDelay);
    }
    return(0);
}

ulong SafeSell(double lot, double slDist, double tpDist)
{
    lot = NormalizeLot(lot);
    for(int i = 0; i < InpMaxRetry; i++)
    {
        if(!CanTrade()) { Sleep(InpRetryDelay); continue; }
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double sl  = bid + slDist;
        double tp  = (tpDist > 0) ? bid - tpDist : 0.0;
        ClampSellSLTP(bid, sl, tp);
        if(trade.Sell(lot, _Symbol, 0.0, sl, tp))
            if(trade.ResultOrder() > 0) return(trade.ResultOrder());
        Sleep(InpRetryDelay);
    }
    g_pendSlDist = slDist; g_pendTpDist = tpDist;
    for(int j = 0; j < InpMaxRetry; j++)
    {
        if(!CanTrade()) { Sleep(InpRetryDelay); continue; }
        if(trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0))
            if(trade.ResultOrder() > 0) return(trade.ResultOrder());
        Sleep(InpRetryDelay);
    }
    return(0);
}

void FixMissingSLTP()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong tk = PositionGetTicket(i);
        if(tk == 0) continue;
        if(PositionGetString(POSITION_SYMBOL)   != _Symbol)    continue;
        if(PositionGetInteger(POSITION_MAGIC)   != InpMagicNum) continue;
        if(PositionGetDouble(POSITION_SL) != 0) continue;
        if(g_pendSlDist <= 0) continue;
        double op = PositionGetDouble(POSITION_PRICE_OPEN);
        long   ty = PositionGetInteger(POSITION_TYPE);
        double sl = 0.0, tp = 0.0;
        if(ty == POSITION_TYPE_BUY)
        {
            sl = op - g_pendSlDist;
            tp = (g_pendTpDist > 0) ? op + g_pendTpDist : 0.0;
            ClampBuySLTP(op, sl, tp);
        }
        else if(ty == POSITION_TYPE_SELL)
        {
            sl = op + g_pendSlDist;
            tp = (g_pendTpDist > 0) ? op - g_pendTpDist : 0.0;
            ClampSellSLTP(op, sl, tp);
        }
        else continue;
        if(!trade.PositionModify(tk, sl, tp))
            Print("[SL後付け失敗] ticket=", tk, " err=", GetLastError());
    }
}
//================ OANDA 実発注ブロック ここまで ================

//--- Indicator Calculation Functions
double GetER(int period)
{
    double close[];
    ArraySetAsSeries(close, true);
    if(CopyClose(_Symbol, InpExecutionTF, 1, period + 1, close) <= period) return 0;
    
    double diff_sum = 0;
    for(int i = 0; i < period; i++)
        diff_sum += MathAbs(close[i] - close[i+1]);
    
    if(diff_sum == 0) return 0;
    return MathAbs(close[0] - close[period]) / diff_sum;
}

ENUM_REGIME GetRegime(double &jump_ratio_out)
{
    double atr_vals[];
    ArraySetAsSeries(atr_vals, true);
    if(CopyBuffer(hATR_exec, 0, 1, 30, atr_vals) < 30) return REGIME_UNKNOWN;
    
    double atr1 = atr_vals[0];
    double atr14 = 0;
    for(int i=0; i<14; i++) atr14 += atr_vals[i];
    atr14 /= 14.0;
    
    jump_ratio_out = (atr14 > 0) ? (atr1 / atr14) : 0;
    
    double er = GetER(InpER_Period);
    double atr30 = 0;
    for(int i=0; i<30; i++) atr30 += atr_vals[i];
    atr30 /= 30.0;
    
    double close_val[];
    if(CopyClose(_Symbol, InpExecutionTF, 1, 1, close_val) <= 0) return REGIME_UNKNOWN;
    double price = close_val[0];
    
    bool is_hv = (atr30 / price >= InpVol_Threshold);
    
    // Direction
    int dir = 0; // 1: UP, -1: DOWN, 0: RANGE
    if(er > InpER_Threshold) dir = 1;
    else if(er < -InpER_Threshold) dir = -1;
    
    // Hysteresis logic
    ENUM_REGIME current_detected = REGIME_UNKNOWN;
    if(is_hv) {
        if(dir == 1) current_detected = REGIME_HV_UP;
        else if(dir == -1) current_detected = REGIME_HV_DOWN;
        else current_detected = REGIME_HV_RANGE;
    } else {
        if(dir == 1) current_detected = REGIME_LV_UP;
        else if(dir == -1) current_detected = REGIME_LV_DOWN;
        else current_detected = REGIME_LV_RANGE;
    }
    
    if(g_hysteresis_counter > 0) {
        g_hysteresis_counter--;
        return g_last_regime;
    } else {
        g_last_regime = current_detected;
        g_hysteresis_counter = 2;
        return current_detected;
    }
}

ENUM_MACRO GetMacro()
{
    double sma_vals[];
    if(CopyBuffer(hSMA_macro, 0, 1, 1, sma_vals) <= 0) return MACRO_FLAT;
    
    double close_vals[];
    if(CopyClose(_Symbol, InpHigherTF, 1, InpSMA_Macro_Period + 1, close_vals) <= InpSMA_Macro_Period) return MACRO_FLAT;
    ArraySetAsSeries(close_vals, true);
    
    double price_now = close_vals[0];
    double price_old = close_vals[InpSMA_Macro_Period];
    double ret = (price_old != 0) ? (price_now - price_old) / price_old : 0;
    
    if(price_now > sma_vals[0] && ret > 0) return MACRO_BULL;
    if(price_now < sma_vals[0] && ret < 0) return MACRO_BEAR;
    return MACRO_FLAT;
}

//--- EA Core
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    
    hATR_exec = iATR(_Symbol, InpExecutionTF, InpATR_Period);
    hATR_vol  = iATR(_Symbol, InpExecutionTF, InpATR_Vol_Period);
    hBB_exec  = iBands(_Symbol, InpExecutionTF, InpBB_Period, 0, InpBB_Dev, PRICE_CLOSE);
    hSMA_macro = iMA(_Symbol, InpHigherTF, InpSMA_Macro_Period, 0, MODE_SMA, PRICE_CLOSE);
    hSMA_h4   = iMA(_Symbol, InpExecutionTF, 20, 0, MODE_SMA, PRICE_CLOSE);
    
    if(hATR_exec == INVALID_HANDLE || hBB_exec == INVALID_HANDLE || hSMA_macro == INVALID_HANDLE) return INIT_FAILED;
    
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(hATR_exec);
    IndicatorRelease(hATR_vol);
    IndicatorRelease(hBB_exec);
    IndicatorRelease(hSMA_macro);
    IndicatorRelease(hSMA_h4);
}

void OnTick()
{
    FixMissingSLTP();
    
    static datetime g_lastBar = 0;
    datetime t = iTime(_Symbol, InpExecutionTF, 0);
    if(t == g_lastBar) return;
    g_lastBar = t;

    // Check position limit
    int pos_count = 0;
    for(int i=0; i<PositionsTotal(); i++) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) pos_count++;
    }
    if(pos_count >= InpMaxPositions) return;

    // Data buffers
    double atr_buf[], bb_up[], bb_low[], close_buf[], low_buf[], high_buf[], sma_h4_buf[];
    ArraySetAsSeries(atr_buf, true);
    ArraySetAsSeries(bb_up, true);
    ArraySetAsSeries(bb_low, true);
    ArraySetAsSeries(close_buf, true);
    ArraySetAsSeries(low_buf, true);
    ArraySetAsSeries(high_buf, true);
    ArraySetAsSeries(sma_h4_buf, true);

    if(CopyBuffer(hATR_exec, 0, 1, 2, atr_buf) < 2) return;
    if(CopyBuffer(hBB_exec, 1, 1, 2, bb_up) < 2) return;
    if(CopyBuffer(hBB_exec, 2, 1, 2, bb_low) < 2) return;
    if(CopyClose(_Symbol, InpExecutionTF, 1, 2, close_buf) < 2) return;
    if(CopyLow(_Symbol, InpExecutionTF, 1, 2, low_buf) < 2) return;
    if(CopyHigh(_Symbol, InpExecutionTF, 1, 2, high_buf) < 2) return;
    if(CopyBuffer(hSMA_h4, 0, 1, 2, sma_h4_buf) < 2) return;

    double jump_ratio = 0;
    ENUM_REGIME regime = GetRegime(jump_ratio);
    ENUM_MACRO macro = GetMacro();
    
    if(!IsSpreadOK()) return;

    double atr14 = atr_buf[0];

    //--- Entry Logic
    // BEAR: HV_RANGE + Jump > 1.5 + Low[1] < BB_Low[1] + Close[1] > BB_Low[1]
    if(macro == MACRO_BEAR) {
        if(regime == REGIME_HV_RANGE && jump_ratio > InpJump_Multiplier) {
            if(low_buf[0] < bb_low[0] && close_buf[0] > bb_low[0]) {
                double sl = atr14 * InpSL_ATR_BEAR_HV;
                double tp = atr14 * InpTP_ATR_BEAR_HV;
                SafeSell(InpLotSize, sl, tp);
            }
        }
    }
    // BULL: LV_UP + ER > 0.1 + Close[1] > SMA20(H4)
    else if(macro == MACRO_BULL) {
        if(regime == REGIME_LV_UP && GetER(InpER_Period) > InpER_Threshold) {
            if(close_buf[0] > sma_h4_buf[0]) {
                double sl = atr14 * InpSL_ATR_BULL_LV;
                double tp = atr14 * InpTP_ATR_BULL_LV;
                SafeBuy(InpLotSize, sl, tp);
            }
        }
    }
    // FLAT: HV_RANGE or LV_UP/DOWN (BB Reversal)
    else if(macro == MACRO_FLAT) {
        bool can_entry = (regime == REGIME_HV_RANGE || regime == REGIME_LV_UP || regime == REGIME_LV_DOWN);
        if(can_entry) {
            double sl = atr14 * InpSL_ATR_FLAT;
            double tp = atr14 * InpTP_ATR_FLAT;
            // Buy reversal: Low[1] < BB_Low[1] and Close[1] > BB_Low[1]
            if(low_buf[0] < bb_low[0] && close_buf[0] > bb_low[0]) SafeBuy(InpLotSize, sl, tp);
            // Sell reversal: High[1] > BB_Up[1] and Close[1] < BB_Up[1]
            else if(high_buf[0] > bb_up[0] && close_buf[0] < bb_up[0]) SafeSell(InpLotSize, sl, tp);
        }
    }
}