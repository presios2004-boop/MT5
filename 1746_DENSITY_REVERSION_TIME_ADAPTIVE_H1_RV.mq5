#include <Trade\Trade.mqh>

//================ OANDA 実発注ブロック ここから ================
#define OANDA_MIN_SL_PIPS  5.0      // 発注価格とSLの最小距離（OANDA制約）

input int InpMaxRetry   = 5;        // 発注リトライ回数
input int InpRetryDelay = 300;      // リトライ間隔(ms)

double g_pendSlDist = 0.0;          // フォールバック建玉のSL距離
double g_pendTpDist = 0.0;
bool   g_entryBusy  = false;        // 二重発注ガード
datetime g_lastEntryTry = 0;

// 1pip の価格幅。3桁/5桁業者は 10*_Point
double PipSize()
{
    return((_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point);
}

// SL/TP を置ける最小距離。STOPS_LEVEL と 5pips の大きい方
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

// SYMBOL_SPREAD は使わない。実 ask-bid で測る
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

// 第1段: SL/TP付きで発注。ダメなら第2段: 素の成行で入れて後からSLを付ける
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

// 第2段で入った SL 無し建玉に SL を後付けする。OnTick から毎回呼ぶ
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
        if(!SafeModify(tk, sl, tp))
            Print("[SL後付け失敗] ticket=", tk, " retcode=", trade.ResultRetcode());
    }
}

// ---- 同時発注対策（2026-10-20）: 同じ口座で複数の EA を動かすと、注文が重なった側が拒否される。
//      決済・SL 変更も入口と同じくリトライし、拒否の理由で「送り直す／諦める」を分ける。
//      決済がリトライで通らなければ「決済待ち」に積み、OnTick の先頭（新足判定の外）で毎ティック送り直す。
ulong g_pendClose[];                // 決済待ちのチケット

// 送り直して通る見込みのある拒否か
bool IsRetryableRetcode(uint rc)
{
    switch(rc)
    {
        case TRADE_RETCODE_REQUOTE:           // 10004
        case TRADE_RETCODE_REJECT:            // 10006
        case TRADE_RETCODE_TIMEOUT:           // 10012
        case TRADE_RETCODE_PRICE_CHANGED:     // 10020
        case TRADE_RETCODE_PRICE_OFF:         // 10021
        case TRADE_RETCODE_TOO_MANY_REQUESTS: // 10024
        case TRADE_RETCODE_CONNECTION:        // 10031
        case TRADE_RETCODE_LOCKED:            // 10029
            return(true);
    }
    return(false);
}

// 建玉がまだあるか（チケットで）
bool PositionExists(ulong tk)
{
    return(PositionSelectByTicket(tk));
}

void AddPendingClose(ulong tk)
{
    int n = ArraySize(g_pendClose);
    for(int i = 0; i < n; i++) if(g_pendClose[i] == tk) return;
    ArrayResize(g_pendClose, n + 1);
    g_pendClose[n] = tk;
}

// 決済。通れば true。送り直しても通らなければ決済待ちに積んで false
bool SafeClose(ulong tk)
{
    for(int i = 0; i < InpMaxRetry; i++)
    {
        if(!PositionExists(tk)) return(true);                     // もう無い（決済済み）
        if(!CanTrade()) { Sleep(InpRetryDelay); continue; }
        if(trade.PositionClose(tk)) return(true);
        uint rc = trade.ResultRetcode();
        if(rc == TRADE_RETCODE_POSITION_CLOSED) return(true);     // 10036
        if(!IsRetryableRetcode(rc))
        {
            Print("[決済失敗・再送しない] ticket=", tk, " retcode=", rc);
            break;
        }
        Sleep(InpRetryDelay);
    }
    AddPendingClose(tk);
    Print("[決済待ちに積む] ticket=", tk);
    return(false);
}

// SL/TP 変更。今と同じ値なら送らない（10025 を避ける）。通れば true
bool SafeModify(ulong tk, double sl, double tp)
{
    if(!PositionExists(tk)) return(false);
    double curSl = PositionGetDouble(POSITION_SL);
    double curTp = PositionGetDouble(POSITION_TP);
    if(MathAbs(curSl - sl) < _Point / 2 && MathAbs(curTp - tp) < _Point / 2) return(true);
    for(int i = 0; i < InpMaxRetry; i++)
    {
        if(!CanTrade()) { Sleep(InpRetryDelay); continue; }
        if(trade.PositionModify(tk, sl, tp)) return(true);
        uint rc = trade.ResultRetcode();
        if(rc == TRADE_RETCODE_NO_CHANGES) return(true);          // 10025
        if(!IsRetryableRetcode(rc))
        {
            Print("[SL変更失敗・再送しない] ticket=", tk, " retcode=", rc);
            return(false);
        }
        Sleep(InpRetryDelay);
    }
    return(false);
}

// 決済待ちを送り直す。OnTick の先頭（新足判定より前）から毎回呼ぶ。決済の判断は確定足で済んでいるので、ここは執行の再試行だけ
void ProcessPendingCloses()
{
    int n = ArraySize(g_pendClose);
    if(n == 0) return;
    for(int i = n - 1; i >= 0; i--)
    {
        ulong tk = g_pendClose[i];
        bool done = false;
        if(!PositionExists(tk)) done = true;
        else if(CanTrade() && trade.PositionClose(tk)) done = true;
        else if(trade.ResultRetcode() == TRADE_RETCODE_POSITION_CLOSED) done = true;
        else if(!IsRetryableRetcode(trade.ResultRetcode()))
        {
            Print("[決済待ち・諦める] ticket=", tk, " retcode=", trade.ResultRetcode());
            done = true;
        }
        if(done)
        {
            for(int j = i; j < ArraySize(g_pendClose) - 1; j++) g_pendClose[j] = g_pendClose[j + 1];
            ArrayResize(g_pendClose, ArraySize(g_pendClose) - 1);
        }
    }
}
//================ OANDA 実発注ブロック ここまで ================

// Inputs
input double InpLotSize      = 0.1;   // 固定ロット（変更禁止）
input int    InpMagicNum     = 202600801;
input double InpMaxSpread    = 5.0;   // 最大スプレッド(pips)
input int    InpMaxPositions = 1;     // 同時保有の上限

input ENUM_TIMEFRAMES InpExecutionTF = PERIOD_H1;   // Execution Timeframe
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_D1;   // Higher Timeframe

input int    Inp_ATR_Period      = 30;    // ATR Period
input int    Inp_ER_Period       = 60;    // ER Period
input int    Inp_SMA_Period      = 200;   // SMA Period (D1)
input double Inp_Vol_Threshold   = 0.0035;// Volatility Threshold (ATR/Price)
input double Inp_ER_Threshold    = 0.15;  // ER Threshold
input double Inp_Jump_BEAR_Sell  = 3.5;   // Jump Ratio BEAR Sell
input double Inp_Jump_BULL_Buy   = 2.5;   // Jump Ratio BULL Buy
input double Inp_Jump_Default    = 2.0;   // Jump Ratio Default
input double Inp_Jump_LV         = 3.0;   // Jump Ratio LV
input double InpSL_ATR_HV        = 2.5;   // SL Multiplier HV
input double InpSL_ATR_LV        = 1.5;   // SL Multiplier LV
input double InpTP_ATR_LV        = 2.5;   // TP Multiplier LV
input double InpTrail_ATR        = 2.0;   // Trailing Stop Multiplier HV
input int    Inp_TimeStop_Hours  = 6;     // Time Stop Hours
input double InpMacro_Bull_Pct   = 1.01;  // Macro Bull Threshold (1.01 = 1%)
input double InpMacro_Bear_Pct   = 0.99;  // Macro Bear Threshold (0.99 = -1%)
double g_last_valid_atr = 0.0;
bool g_state_restored = false;

// Handles
int h_atr_h1 = INVALID_HANDLE;
int h_sma_d1 = INVALID_HANDLE;

// Globals
CTrade trade;
double g_highest_since_entry = 0.0;
double g_lowest_since_entry = 0.0;
bool   g_trailing_active = false;
bool   g_is_hv_position = false;
int    g_macro_state_at_entry = 0;

int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNum);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    
    h_atr_h1 = iATR(_Symbol, InpExecutionTF, Inp_ATR_Period);
    h_sma_d1 = iMA(_Symbol, InpHigherTF, Inp_SMA_Period, 0, MODE_SMA, PRICE_CLOSE);
    
    if(h_atr_h1 == INVALID_HANDLE || h_sma_d1 == INVALID_HANDLE)
    {
        Print("Indicator handle creation failed");
        return(INIT_FAILED);
    }
    
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
    if(h_atr_h1 != INVALID_HANDLE) IndicatorRelease(h_atr_h1);
    if(h_sma_d1 != INVALID_HANDLE) IndicatorRelease(h_sma_d1);
}

double GetATR(int shift)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(h_atr_h1, 0, shift, 1, buf) <= 0) 
    {
        return(g_last_valid_atr);
    }
    if(buf[0] > 0.000001)
    {
        g_last_valid_atr = buf[0];
    }
    return(g_last_valid_atr);
}

double GetSMA_D1(int shift)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(h_sma_d1, 0, shift, 1, buf) <= 0) return(0.0);
    return(buf[0]);
}

double GetClose(ENUM_TIMEFRAMES tf, int shift)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyClose(_Symbol, tf, shift, 1, buf) <= 0) return(0.0);
    return(buf[0]);
}

double GetOpen(ENUM_TIMEFRAMES tf, int shift)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyOpen(_Symbol, tf, shift, 1, buf) <= 0) return(0.0);
    return(buf[0]);
}

// Signed ER = Net Change / Sum of Absolute Changes
double CalculateER(int period)
{
    double close[];
    ArraySetAsSeries(close, true);
    if(CopyClose(_Symbol, InpExecutionTF, 1, period, close) < period) return(0.0);
    
    double netChange = close[0] - close[period-1];
    double sumChange = 0.0;
    for(int i = 0; i < period - 1; i++)
    {
        sumChange += MathAbs(close[i] - close[i+1]);
    }
    
    if(sumChange <= 0.000001) return(0.0); // L1: Avoid division by zero
    
    return(netChange / sumChange);
}

int CountMyPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong tk = PositionGetTicket(i);
        if(tk == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
        count++;
    }
    return(count);
}

void ResetTrailingState()
{
    g_highest_since_entry = 0.0;
    g_lowest_since_entry = 0.0;
    g_trailing_active = false;
    g_is_hv_position = false;
    g_macro_state_at_entry = 0;
}

// Restore state from position comment to handle restarts
void RestoreStateFromPosition()
{
    if(CountMyPositions() == 0) return;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong tk = PositionGetTicket(i);
        if(tk == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
        
        string comment = PositionGetString(POSITION_COMMENT);
        double sl = PositionGetDouble(POSITION_SL);
        double op = PositionGetDouble(POSITION_PRICE_OPEN);
        long ty = PositionGetInteger(POSITION_TYPE);
        
        // 1. レビュー復元: ポジションコメントまたはSL距離構造からHV/LVおよびMacro状態を自己判定
        bool isHV = false;
        if(StringFind(comment, "HV") >= 0) isHV = true;
        else if(sl > 0.0 && op > 0.0)
        {
            double atr = GetATR(1);
            if(atr > 0.000001)
            {
                double slDist = MathAbs(op - sl);
                if(slDist > 2.0 * atr) isHV = true; // HVのSL倍率は2.5*ATR
            }
        }
        
        g_is_hv_position = isHV;
        
        // 大局状態の復元
        if(StringFind(comment, "BEAR") >= 0) g_macro_state_at_entry = -1;
        else if(StringFind(comment, "BULL") >= 0) g_macro_state_at_entry = 1;
        else
        {
            // コメントが途絶えている場合は現時点のD1 SMA判定で代替フォールバック
            double d1Close = GetClose(InpHigherTF, 1);
            double d1SMA   = GetSMA_D1(1);
            if(d1Close > 0.0 && d1SMA > 0.0)
            {
                double ratio = d1Close / d1SMA;
                if(ratio > InpMacro_Bull_Pct) g_macro_state_at_entry = 1;
                else if(ratio < InpMacro_Bear_Pct) g_macro_state_at_entry = -1;
                else g_macro_state_at_entry = 0;
            }
        }

        // トレーリングフラグの復元: HVポジションであれば有効化（BEARかつHVの場合はTime-Stop優先）
        g_trailing_active = isHV;
        
        // 価格高値・安値ラチェットの初期化
        if(ty == POSITION_TYPE_BUY)
        {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            g_highest_since_entry = MathMax(op, bid);
            g_lowest_since_entry = MathMin(op, bid);
        }
        else if(ty == POSITION_TYPE_SELL)
        {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            g_lowest_since_entry = MathMin(op, ask);
            g_highest_since_entry = MathMax(op, ask);
        }
        break;
    }
}

void OnTick()
{
    ProcessPendingCloses();      /* 決済待ちの送り直し（同時発注対策） */

    FixMissingSLTP();
    
    // 状態復元処理（EA再起動時・再接続時）
    if(CountMyPositions() > 0 && !g_state_restored)
    {
        RestoreStateFromPosition();
        g_state_restored = true;
    }
    
    // New Bar Check
    static datetime g_lastBar = 0;
    datetime t = iTime(_Symbol, InpExecutionTF, 0);
    if(t == g_lastBar) 
    {
        // 建玉管理（毎ティック実行）
        if(CountMyPositions() > 0)
        {
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                ulong tk = PositionGetTicket(i);
                if(tk == 0) continue;
                if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
                if(PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
                
                long ty = PositionGetInteger(POSITION_TYPE);
                double op = PositionGetDouble(POSITION_PRICE_OPEN);
                double curSl = PositionGetDouble(POSITION_SL);
                double curTp = PositionGetDouble(POSITION_TP);
                
                // 【違反3修正】大局BEAR時のHVポジションは、売買方向（HV_UP/HV_DOWN/HV_RANGE）を問わず全て6時間Time-Stop適用
                if(g_is_hv_position && g_macro_state_at_entry == -1)
                {
                    datetime entryTime = (datetime)PositionGetInteger(POSITION_TIME);
                    datetime currentTime = TimeCurrent();
                    int elapsedHours = (int)((currentTime - entryTime) / 3600);
                    if(elapsedHours >= Inp_TimeStop_Hours)
                    {
                        if(IsSpreadOK())
                        {
                            SafeClose(tk);
                            ResetTrailingState();
                            g_state_restored = false;
                            return;
                        }
                    }
                    // BEARかつHVのポジションはTime-Stopで管理するため、ATRトレーリングはスキップ
                    continue;
                }
                
                // ATRトレーリングの適用（BULL / FLATにおけるHVポジション）
                if(!g_trailing_active || !g_is_hv_position) continue;
                
                double atr = GetATR(1);
                if(atr <= 0.000001) continue; // REVIEW_4: GetATR内でフォールバック済み
                
                double trailDist = InpTrail_ATR * atr;
                double minDist = StopDist();
                
                if(ty == POSITION_TYPE_BUY)
                {
                    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                    if(bid > g_highest_since_entry) g_highest_since_entry = bid;
                    
                    double newSl = g_highest_since_entry - trailDist;
                    if(newSl > curSl && (newSl - op) > minDist)
                    {
                        if(newSl > op)
                        {
                            SafeModify(tk, newSl, curTp);
                        }
                    }
                }
                else if(ty == POSITION_TYPE_SELL)
                {
                    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                    if(ask < g_lowest_since_entry) g_lowest_since_entry = ask;
                    
                    double newSl = g_lowest_since_entry + trailDist;
                    if(newSl < curSl && (op - newSl) > minDist)
                    {
                        if(newSl < op)
                        {
                            SafeModify(tk, newSl, curTp);
                        }
                    }
                }
            }
        }
        return;
    }
    g_lastBar = t;
    
    // 新しい足になった際にポジションが無ければ状態リセット
    if(CountMyPositions() == 0)
    {
        ResetTrailingState();
        g_state_restored = false;
    }
    
    // 1. 保有数チェック
    if(CountMyPositions() >= InpMaxPositions) return;
    
    // 2. 確定足データ取得 (Shift 1)
    double close1 = GetClose(InpExecutionTF, 1);
    double open1  = GetOpen(InpExecutionTF, 1);
    double atr1   = GetATR(1);
    
    if(close1 <= 0.000001 || atr1 <= 0.000001) return;
    
    double volRatio = atr1 / close1;
    double erVal    = CalculateER(Inp_ER_Period);
    double jumpRatio = MathAbs(close1 - open1) / atr1;
    
    // 3. 大局判定 (D1)
    double d1Close = GetClose(InpHigherTF, 1);
    double d1SMA   = GetSMA_D1(1);
    
    if(d1Close <= 0.000001 || d1SMA <= 0.000001) return;
    
    double ratio = d1Close / d1SMA;
    int macroState = 0; // 0: FLAT, 1: BULL, -1: BEAR
    if(ratio > InpMacro_Bull_Pct) macroState = 1;
    else if(ratio < InpMacro_Bear_Pct) macroState = -1;
    
    // 4. レジーム判定とシグナル生成
    bool isHV = (volRatio > Inp_Vol_Threshold);
    bool isUp = (erVal > Inp_ER_Threshold);
    bool isDown = (erVal < -Inp_ER_Threshold);
    bool isRange = (!isUp && !isDown);
    
    bool entryBuy = false;
    bool entrySell = false;
    double slDist = 0.0;
    double tpDist = 0.0;
    bool isHVEntry = false;
    
    // 【違反2修正】大局BULL時、売りのJumpRatio閾値を厳選（Inp_Jump_BEAR_Sell = 3.5等の高閾値を使用）
    if(isHV && isUp)
    {
        // HV_UP (売り判定): 大局BEARなら3.5、大局BULLなら売りの入口を厳選（Inp_Jump_BEAR_Sell = 3.5）、FLATなら2.0
        double threshold = (macroState == -1) ? Inp_Jump_BEAR_Sell : ((macroState == 1) ? Inp_Jump_BEAR_Sell : Inp_Jump_Default);
        if(jumpRatio > threshold && close1 < open1)
        {
            entrySell = true;
            slDist = InpSL_ATR_HV * atr1;
            isHVEntry = true;
        }
    }
    else if(isHV && isDown)
    {
        // HV_DOWN (買い判定): 大局BULLなら2.5(Inp_Jump_BULL_Buy)、大局BEARなら厳選、FLATなら2.0
        double threshold = (macroState == 1) ? Inp_Jump_BULL_Buy : ((macroState == -1) ? Inp_Jump_BEAR_Sell : Inp_Jump_Default);
        if(jumpRatio > threshold && close1 > open1)
        {
            entryBuy = true;
            slDist = InpSL_ATR_HV * atr1;
            isHVEntry = true;
        }
    }
    else if(isHV && isRange)
    {
        // 【違反1修正】HV_RANGE: どちらの方向でも2.0を超えた場合に反転を狙う
        if(jumpRatio > Inp_Jump_Default)
        {
            if(close1 < open1) entryBuy = true;
            else if(close1 > open1) entrySell = true;
            
            if(entryBuy || entrySell)
            {
                slDist = InpSL_ATR_HV * atr1;
                isHVEntry = true;
            }
        }
    }
    else if(!isHV && isUp)
    {
        // LV_UP: 買い
        if(jumpRatio > Inp_Jump_LV)
        {
            entryBuy = true;
            slDist = InpSL_ATR_LV * atr1;
            tpDist = InpTP_ATR_LV * atr1;
        }
    }
    else if(!isHV && isDown)
    {
        // LV_DOWN: 売り
        if(jumpRatio > Inp_Jump_LV)
        {
            entrySell = true;
            slDist = InpSL_ATR_LV * atr1;
            tpDist = InpTP_ATR_LV * atr1;
        }
    }
    // LV_RANGE: 見送り
    
    // 5. 発注実行
    if(entryBuy || entrySell)
    {
        if(!IsSpreadOK()) return;
        if(slDist <= 0.000001) return;
        
        double minSl = StopDist();
        if(slDist < minSl) slDist = minSl;
        
        if(entryBuy)
        {
            ulong orderTicket = SafeBuy(InpLotSize, slDist, tpDist);
            if(orderTicket > 0)
            {
                // REVIEW_3 修正: SafeBuy成功後、実際に成立したポジションチケットを取得
                ulong posTicket = 0;
                for(int i = PositionsTotal() - 1; i >= 0; i--)
                {
                    ulong pt = PositionGetTicket(i);
                    if(pt == 0) continue;
                    if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
                    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
                    posTicket = pt;
                    break;
                }
                
                if(posTicket > 0)
                {
                    g_highest_since_entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                    g_lowest_since_entry = g_highest_since_entry;
                    g_is_hv_position = isHVEntry;
                    g_trailing_active = isHVEntry;
                    g_macro_state_at_entry = macroState;
                    g_state_restored = true;
                }
            }
        }
        else if(entrySell)
        {
            ulong orderTicket = SafeSell(InpLotSize, slDist, tpDist);
            if(orderTicket > 0)
            {
                // REVIEW_3 修正: SafeSell成功後、実際に成立したポジションチケットを取得
                ulong posTicket = 0;
                for(int i = PositionsTotal() - 1; i >= 0; i--)
                {
                    ulong pt = PositionGetTicket(i);
                    if(pt == 0) continue;
                    if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
                    if(PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
                    posTicket = pt;
                    break;
                }
                
                if(posTicket > 0)
                {
                    g_lowest_since_entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                    g_highest_since_entry = g_lowest_since_entry;
                    g_is_hv_position = isHVEntry;
                    g_trailing_active = isHVEntry;
                    g_macro_state_at_entry = macroState;
                    g_state_restored = true;
                }
            }
        }
    }
}

// 教訓の適用: L1 → CalculateER/OnTick（ゼロ除算防御: sumChange <= 0.000001, atr <= 0.000001 チェック）
// 教訓の適用: L2 → OnTick（トレーリング開始条件: newSl > op / newSl < op で含み益確認）
// 教訓の適用: L3 → OnTick（トレーリング方向判定: newSl > curSl / newSl < curSl でラチェット）
// 教訓の適用: L4 → OnTick（新バー判定とトレーリング実行の同期: g_lastBar チェック）
// 教訓の適用: L5 → OnTick（g_highest/lowest_since_entry によるラチェット管理）
// 教訓の適用: L6 → OnTick（売りSL更新: newSl < curSl かつ 有利方向判定）
// 教訓の適用: L7 → OnTick（FixMissingSLTP 直後に新バー門を配置）
// 教訓の適用: L8 → CalculateER（価格変化量と変動幅合計を用いた正しいER計算）
