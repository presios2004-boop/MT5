#include <Trade\Trade.mqh>

//--- Input Parameters
input double InpLotSize           = 0.1;    // Fixed Lot Size
input int    InpMagicNum          = 202600801;
input double InpMaxSpread         = 5.0;    // Max Spread (pips)
input int    InpMaxPositions      = 1;      // Max Simultaneous Positions

input int    InpER_Period         = 60;     // ER Period
input int    InpDonchian_Period   = 20;     // Donchian Period
input int    InpSMA_Trend_Period  = 20;     // H4 SMA Period
input int    InpSMA_Macro_Period  = 200;    // D1 SMA Period
input double InpVolAccel_Threshold = 1.1;   // Vol Acceleration Threshold
input double InpVBD_Threshold      = 1.2;   // VBD Threshold
input double InpER_Bear_Min       = 0.2;    // ER Min for Bear Buy
input double InpER_Bull_Min       = 0.15;   // ER Min for Trend

input double InpSL_ATR_HV         = 2.5;    // SL ATR Multiplier HV
input double InpSL_ATR_LV         = 1.5;    // SL ATR Multiplier LV
input double InpSL_ATR_HV_RANGE   = 3.0;    // SL ATR Multiplier HV_RANGE
input double InpTP_ATR_HV_RANGE   = 2.0;    // TP ATR Multiplier HV_RANGE
input double InpTrail_ATR_HV      = 3.0;    // Trailing ATR Multiplier HV
input double InpTrail_ATR_LV      = 1.5;    // Trailing ATR Multiplier LV

input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H4;
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;

//--- OANDA Block Variables
#define OANDA_MIN_SL_PIPS  5.0      // 発注価格とSLの最小距離（OANDA制約）

input int InpMaxRetry   = 5;        // 発注リトライ回数
input int InpRetryDelay = 300;      // リトライ間隔(ms)

double g_pendSlDist = 0.0;          // フォールバック建玉のSL距離
double g_pendTpDist = 0.0;
bool   g_entryBusy  = false;        // 二重発注ガード
datetime g_lastEntryTry = 0;

//--- Global Variables
CTrade trade;
int hATR_H4, hSMA_Trend_H4, hSMA_Macro_D1;

//--- Enums
enum ENUM_REGIME_DIR { REG_UP, REG_DOWN, REG_RANGE };
enum ENUM_REGIME_VOL { REG_HV, REG_LV };
enum ENUM_MACRO { MAC_BULL, MAC_BEAR, MAC_FLAT };

//================ OANDA 実発注ブロック ここから ================
double PipSize()
{
    return((_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point);
}

double StopDist()
{
    long lv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    if(lv <= 0) lv = 5;                       // 0を返す環境の下限
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

double GetER(int period)
{
    double close[], open[];
    ArraySetAsSeries(close, true); ArraySetAsSeries(open, true);
    if(CopyClose(_Symbol, InpExecutionTF, 1, period + 1, close) <= period) return 0;
    if(CopyOpen(_Symbol, InpExecutionTF, 1, period + 1, open) <= period) return 0;
    double diff_total = 0;
    for(int i = 0; i < period; i++) diff_total += MathAbs(close[i] - close[i+1]);
    double net_diff = MathAbs(close[0] - close[period]);
    return (diff_total == 0) ? 0 : net_diff / diff_total;
}

int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    hATR_H4 = iATR(_Symbol, InpExecutionTF, 14);
    hSMA_Trend_H4 = iMA(_Symbol, InpExecutionTF, InpSMA_Trend_Period, 0, MODE_SMA, PRICE_CLOSE);
    hSMA_Macro_D1 = iMA(_Symbol, InpHigherTF, InpSMA_Macro_Period, 0, MODE_SMA, PRICE_CLOSE);
    
    if(hATR_H4 == INVALID_HANDLE || hSMA_Trend_H4 == INVALID_HANDLE || hSMA_Macro_D1 == INVALID_HANDLE) return INIT_FAILED;
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(hATR_H4);
    IndicatorRelease(hSMA_Trend_H4);
    IndicatorRelease(hSMA_Macro_D1);
}

void OnTick()
{
    FixMissingSLTP();

    //--- Position Management (Trailing & Time-Stop)
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            ulong tk = PositionGetTicket(i);
            double open_time = (double)PositionGetInteger(POSITION_TIME);
            double current_time = (double)TimeCurrent();
            
            // Time-Stop for BEAR Sell (48h = 172800s)
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            {
                double d_close[], d_sma[];
                if(CopyClose(_Symbol, InpHigherTF, 1, 1, d_close) > 0 && CopyBuffer(hSMA_Macro_D1, 0, 1, 1, d_sma) > 0)
                {
                    if(d_close[0] < d_sma[0] && (current_time - open_time) > 172800)
                    {
                        trade.PositionClose(tk);
                        continue;
                    }
                }
            }

            // ATR Trailing
            double atr_buf[];
            if(CopyBuffer(hATR_H4, 0, 1, 1, atr_buf) > 0)
            {
                double atr_val = atr_buf[0];
                double atr_vals_accel[];
                if(CopyBuffer(hATR_H4, 0, 1, 30, atr_vals_accel) > 0)
                {
                    double sum_atr = 0; for(int j=0; j<30; j++) sum_atr += atr_vals_accel[j];
                    double sma_atr = sum_atr / 30.0;
                    double vol_accel = (sma_atr > 0) ? atr_vals_accel[0] / sma_atr : 1.0;
                    bool is_hv = (vol_accel > InpVolAccel_Threshold);
                    
                    double trail_mult = is_hv ? InpTrail_ATR_HV : InpTrail_ATR_LV;
                    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                    
                    if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                    {
                        double new_sl = bid - (trail_mult * atr_val);
                        if(new_sl > PositionGetDouble(POSITION_SL)) trade.PositionModify(tk, new_sl, 0);
                    }
                    else
                    {
                        double new_sl = ask + (trail_mult * atr_val);
                        if(new_sl < PositionGetDouble(POSITION_SL) || PositionGetDouble(POSITION_SL) == 0) trade.PositionModify(tk, new_sl, 0);
                    }
                }
            }
        }
    }

    //--- New Bar Detection
    static datetime g_lastBar = 0;
    datetime t = iTime(_Symbol, InpExecutionTF, 0);
    if(t == g_lastBar) return;
    g_lastBar = t;

    //--- Check Position Limit
    int pos_count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol) pos_count++;
    }
    if(pos_count >= InpMaxPositions) return;

    //--- Data Acquisition
    double close_h4[], open_h4[], high_h4[], low_h4[], sma_h4[], atr_h4[];
    if(CopyClose(_Symbol, InpExecutionTF, 1, 1, close_h4) <= 0) return;
    if(CopyOpen(_Symbol, InpExecutionTF, 1, 1, open_h4) <= 0) return;
    if(CopyHigh(_Symbol, InpExecutionTF, 1, InpDonchian_Period, high_h4) <= 0) return;
    if(CopyLow(_Symbol, InpExecutionTF, 1, InpDonchian_Period, low_h4) <= 0) return;
    if(CopyBuffer(hSMA_Trend_H4, 0, 1, 1, sma_h4) <= 0) return;
    if(CopyBuffer(hATR_H4, 0, 1, 1, atr_h4) <= 0) return;
    
    // Ensure arrays are series for correct indexing
    ArraySetAsSeries(close_h4, true); ArraySetAsSeries(open_h4, true);
    ArraySetAsSeries(high_h4, true); ArraySetAsSeries(low_h4, true);
    ArraySetAsSeries(sma_h4, true); ArraySetAsSeries(atr_h4, true);

    double d_close[], d_sma[];
    if(CopyClose(_Symbol, InpHigherTF, 1, 1, d_close) <= 0) return;
    if(CopyBuffer(hSMA_Macro_D1, 0, 1, 1, d_sma) <= 0) return;
    ArraySetAsSeries(d_close, true); ArraySetAsSeries(d_sma, true);

    //--- Custom Indicators Calculation
    double er = GetER(InpER_Period);
    double atr_vals_accel[];
    if(CopyBuffer(hATR_H4, 0, 1, 30, atr_vals_accel) <= 0) return;
    ArraySetAsSeries(atr_vals_accel, true);
    double sum_atr = 0; for(int j=0; j<30; j++) sum_atr += atr_vals_accel[j];
    double sma_atr = sum_atr / 30.0;
    double vol_accel = (sma_atr > 0) ? atr_vals_accel[0] / sma_atr : 1.0;
    double vbd = (atr_h4[0] > 0) ? MathAbs(close_h4[0] - open_h4[0]) / atr_h4[0] : 0;

    // Donchian Calculation
    double d_high = high_h4[0];
    for(int k=1; k<InpDonchian_Period; k++) if(high_h4[k] > d_high) d_high = high_h4[k];
    double d_low = low_h4[0];
    for(int k=1; k<InpDonchian_Period; k++) if(low_h4[k] < d_low) d_low = low_h4[k];

    //--- Regime Classification
    ENUM_REGIME_DIR dir = REG_RANGE;
    if(er > InpER_Bull_Min) {
        if(close_h4[0] > sma_h4[0]) dir = REG_UP;
        else if(close_h4[0] < sma_h4[0]) dir = REG_DOWN;
    }
    ENUM_REGIME_VOL vol = (vol_accel > InpVolAccel_Threshold) ? REG_HV : REG_LV;
    ENUM_MACRO macro = (d_close[0] > d_sma[0]) ? MAC_BULL : (d_close[0] < d_sma[0] ? MAC_BEAR : MAC_FLAT);

    if(!IsSpreadOK()) return;

    //--- Entry Logic
    bool buy_sig = false; double b_sl = 0, b_tp = 0;
    bool sell_sig = false; double s_sl = 0, s_tp = 0;

    // BUY Logic
    if((macro == MAC_BULL || macro == MAC_FLAT) && dir != REG_RANGE) {
        if(vol == REG_HV) {
            if(dir == REG_UP && close_h4[0] > d_high) {
                buy_sig = true; b_sl = InpSL_ATR_HV * atr_h4[0];
            }
        } else {
            if(dir == REG_UP && MathAbs(close_h4[0] - sma_h4[0]) < (0.5 * atr_h4[0])) {
                buy_sig = true; b_sl = InpSL_ATR_LV * atr_h4[0];
            }
        }
        // HV_RANGE Buy
        if(vol == REG_HV && dir == REG_RANGE && close_h4[0] < d_low) {
            buy_sig = true; b_sl = InpSL_ATR_HV_RANGE * atr_h4[0]; b_tp = InpTP_ATR_HV_RANGE * atr_h4[0];
        }
        // Macro Bear restriction for Buy
        if(buy_sig && macro == MAC_BEAR) {
            if(!(dir == REG_UP && er > InpER_Bear_Min)) buy_sig = false;
        }
    }

    // SELL Logic
    if((macro == MAC_BEAR || macro == MAC_FLAT) && dir != REG_RANGE) {
        if(vbd > InpVBD_Threshold) {
            if(vol == REG_HV) {
                if(dir == REG_DOWN && close_h4[0] < d_low) {
                    sell_sig = true; s_sl = InpSL_ATR_HV * atr_h4[0];
                }
            } else {
                if(dir == REG_DOWN && MathAbs(close_h4[0] - sma_h4[0]) < (0.5 * atr_h4[0])) {
                    sell_sig = true; s_sl = InpSL_ATR_LV * atr_h4[0];
                }
            }
            // HV_RANGE Sell
            if(vol == REG_HV && dir == REG_RANGE && close_h4[0] > d_high) {
                sell_sig = true; s_sl = InpSL_ATR_HV_RANGE * atr_h4[0]; s_tp = InpTP_ATR_HV_RANGE * atr_h4[0];
            }
        }
        // Macro Bull restriction for Sell
        if(sell_sig && macro == MAC_BULL) {
            if(!(dir == REG_DOWN && vbd > InpVBD_Threshold)) sell_sig = false;
        }
    }

    // Execution
    if(buy_sig) SafeBuy(InpLotSize, b_sl, b_tp);
    else if(sell_sig) SafeSell(InpLotSize, s_sl, s_tp);
}
