//+------------------------------------------------------------------+
//|        GrokMurphy ELITE v1.0 – MT5 Expert Advisor               |
//|  MERGE: GrokAlgo v2 (Gaussian+Fibonacci+Ehlers) +               |
//|         Murphy-Elder Pro (EMA200 + EMA13 + MACD Impulse)        |
//|                                                                  |
//|  Architecture:                                                   |
//|  • GrokAlgo Gaussian/Ehlers engine → primary signal             |
//|  • Murphy-Elder Impulse filter → confirmation layer             |
//|  • Combined strength score (Gaussian str 1-10 + Murphy score)   |
//|  • ATR trailing stop + break-even (Murphy)                       |
//|  • Daily profit/loss limits (Murphy)                             |
//|  • Warmup guard + full history rebuild (GrokAlgo)               |
//|  • Auto filling + spread check + session filter                 |
//|  • Dashboard via Comment()                                       |
//+------------------------------------------------------------------+
#property copyright "GrokMurphy Elite v1.0"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//═══════════════════════════════════════════════════════════════
//  INPUTS
//═══════════════════════════════════════════════════════════════

input group "=== GAUSSIAN ENGINE (GrokAlgo) ==="
input int    SmthPer       = 10;     // Gaussian Levels Depth
input int    ExtraSmthPer  = 10;     // Ehlers Two-Pole Smoother Period
input double AtrMult       = 0.628;  // Channel ATR Multiplier
input int    AtrPer        = 21;     // ATR Period (Gaussian channel)
input double VolThreshold  = 50.0;   // Volume Threshold % (0-100)
input bool   UseSentiment  = true;   // Use Volume Sentiment Filter
input int    SwingLen      = 10;     // Swing Length for Supply/Demand

input group "=== MURPHY-ELDER FILTER ==="
input int    LongEmaLen    = 200;    // Murphy EMA (trend)
input int    ShortEmaLen   = 13;     // Elder EMA (impulse)
input bool   UseMurphy     = true;   // Enable Murphy-Elder confirmation
input bool   UseRSIFilter  = true;   // RSI extreme filter
input int    RSI_Period    = 14;     // RSI period
input double RSI_OB        = 75.0;   // RSI overbought — block LONG
input double RSI_OS        = 25.0;   // RSI oversold  — block SHORT

input group "=== RISK MANAGEMENT ==="
input double RiskPercent   = 1.0;    // Risk % per trade
input double RR            = 2.0;    // Risk:Reward ratio
input double SlMultiplier  = 1.5;    // SL = ATR × this (Murphy ATR)
input bool   UseTrailing   = true;   // Enable ATR trailing stop
input double TrailMult     = 1.2;    // Trail = ATR × this
input bool   UseBreakEven  = true;   // Enable break-even
input double BE_RR_Trigger = 1.0;    // Move to BE when profit >= RR×this

input group "=== DAILY LIMITS ==="
input bool   UseDailyLimits    = true;
input double DailyProfitLimit  = 500.0;  // Max daily profit ($)
input double DailyLossLimit    = 100.0;  // Max daily loss  ($)

input group "=== FILTERS ==="
input double MaxSpread     = 30.0;   // Max spread (points)
input bool   UseSession    = true;   // Session filter
input int    SessionStart  = 7;      // Session start hour (broker time)
input int    SessionEnd    = 20;     // Session end hour

input group "=== TRADE SETTINGS ==="
input ulong  MagicNumber   = 20250308;
input int    WarmupBars    = 100;    // Bars needed before trading
input bool   AllowLong     = true;
input bool   AllowShort    = true;

input group "=== DISPLAY ==="
input bool   ShowPanel     = true;

//═══════════════════════════════════════════════════════════════
//  INDICATOR HANDLES (Murphy-Elder)
//═══════════════════════════════════════════════════════════════
int h_ema200, h_ema13, h_macd, h_atr_m, h_rsi;

//═══════════════════════════════════════════════════════════════
//  GAUSSIAN ENGINE STATE (GrokAlgo)
//═══════════════════════════════════════════════════════════════
double g_ssOut[];
double g_gaussRaw[];
bool   g_initialized = false;
int    g_barsLoaded  = 0;

//═══════════════════════════════════════════════════════════════
//  DAILY LIMITS STATE (Murphy)
//═══════════════════════════════════════════════════════════════
double   g_dayStartBalance = 0.0;
datetime g_lastDayChecked  = 0;
bool     g_dailyLimitHit   = false;
string   g_limitReason     = "";
double   g_dailyPnL        = 0.0;

//═══════════════════════════════════════════════════════════════
//  SIGNAL STRUCT
//═══════════════════════════════════════════════════════════════
struct SignalResult
{
    bool   longSignal;
    bool   shortSignal;
    double gaussOut;    // Gaussian SS value bar[1]
    double gaussSig;    // Gaussian SS value bar[2]
    double atrGauss;    // ATR from Gaussian channel period
    double atrMurphy;   // ATR from Murphy period (for SL/TP/Trail)
    int    gaussStr;    // Gaussian strength 1-10
    double murphyScore; // Murphy-Elder confirmation score 0-100
    bool   murphyBull;
    bool   murphySell;
};

//═══════════════════════════════════════════════════════════════
//  GAUSSIAN MATH  (GrokAlgo — unchanged)
//═══════════════════════════════════════════════════════════════
double GaussWeight(double size, double x)
{
    return MathExp(-x * x * 9.0 / ((size + 1.0) * (size + 1.0)));
}

void FibLevels(int len, double &arr[])
{
    ArrayResize(arr, len);
    int t1=0, t2=1, nxt=t1+t2;
    for(int i=0;i<len;i++)
    { arr[i]=(double)nxt; t1=t2; t2=nxt; nxt=t1+t2; }
}

void GaussOut(double &levels[], double &mat[], int per)
{
    ArrayResize(mat, per*per);
    ArrayInitialize(mat, 0.0);
    for(int k=0;k<per;k++)
    {
        double sum=0.0;
        int lim=(int)levels[k];
        for(int i=0;i<per&&i<lim;i++)
        { double g=GaussWeight(levels[k],(double)i); mat[i*per+k]=g; sum+=g; }
        if(sum>0)
            for(int i=0;i<per&&i<lim;i++)
                mat[i*per+k]/=sum;
    }
}

double SmthMA(int level, int shift, double &src[], int per)
{
    if(level<0||level>=per) return 0.0;
    double levels[]; FibLevels(per,levels);
    double mat[];    GaussOut(levels,mat,per);
    double sum=0.0;
    int srcLen=ArraySize(src);
    for(int i=0;i<per;i++)
    { int idx=shift+i; if(idx>=srcLen) break; sum+=mat[i*per+level]*src[idx]; }
    return sum;
}

void TwoPoleSS_Full(double &src[], double &out[], int len, int count)
{
    double a1=MathExp(-1.414*M_PI/len);
    double b1=2.0*a1*MathCos(1.414*M_PI/len);
    double c2=b1, c3=-a1*a1, c1=1.0-c2-c3;
    ArrayResize(out,count);
    for(int i=count-1;i>=0;i--)
    {
        int i1=i+1, i2=i+2;
        double p1=(i1<count)?out[i1]:src[MathMin(i1,count-1)];
        double p2=(i2<count)?out[i2]:src[MathMin(i2,count-1)];
        out[i]=(i>=count-3)?src[i]:c1*src[i]+c2*p1+c3*p2;
    }
}

void RebuildHistory()
{
    int bars=iBars(_Symbol,PERIOD_CURRENT);
    if(bars<WarmupBars+SmthPer+10) return;
    int lmax=SmthPer+1;
    double closes[]; ArrayResize(closes,bars);
    for(int i=0;i<bars;i++) closes[i]=iClose(_Symbol,PERIOD_CURRENT,i);
    ArrayResize(g_gaussRaw,bars);
    for(int i=0;i<bars;i++) g_gaussRaw[i]=SmthMA(SmthPer,i,closes,lmax);
    TwoPoleSS_Full(g_gaussRaw,g_ssOut,ExtraSmthPer,bars);
    g_barsLoaded=bars;
    g_initialized=true;
}

//═══════════════════════════════════════════════════════════════
//  ATR  (manual SMA of TR)
//═══════════════════════════════════════════════════════════════
double CalcATR(int shift, int period)
{
    double atr=0;
    for(int i=shift;i<shift+period;i++)
    {
        double hi=iHigh(_Symbol,PERIOD_CURRENT,i);
        double lo=iLow (_Symbol,PERIOD_CURRENT,i);
        double pc=iClose(_Symbol,PERIOD_CURRENT,i+1);
        atr+=MathMax(hi-lo,MathMax(MathAbs(hi-pc),MathAbs(lo-pc)));
    }
    return atr/period;
}

//═══════════════════════════════════════════════════════════════
//  MURPHY-ELDER IMPULSE SCORE
//  Returns bull/bear bool + score 0-100
//  Score components:
//   40 — price above/below EMA200 (Murphy trend)
//   30 — Elder EMA13 rising/falling + MACD histogram expanding
//   20 — Elder EMA13 direction alone
//   10 — RSI momentum alignment
//═══════════════════════════════════════════════════════════════
void CalcMurphyScore(double &scoreBull, double &scoreBear,
                     bool &impulBull, bool &impulBear)
{
    scoreBull=0; scoreBear=0;
    impulBull=false; impulBear=false;

    double ema200[], ema13[], macdMain[], macdSig[], macdHist[], rsiVal[];
    ArraySetAsSeries(ema200,true); ArraySetAsSeries(ema13,true);
    ArraySetAsSeries(macdMain,true); ArraySetAsSeries(macdSig,true);
    ArraySetAsSeries(macdHist,true); ArraySetAsSeries(rsiVal,true);

    if(CopyBuffer(h_ema200,0,0,4,ema200)   <4) return;
    if(CopyBuffer(h_ema13, 0,0,4,ema13)    <4) return;
    if(CopyBuffer(h_macd,  0,0,4,macdMain) <4) return;
    if(CopyBuffer(h_macd,  1,0,4,macdSig)  <4) return;
    if(CopyBuffer(h_macd,  2,0,4,macdHist) <4) return;
    if(CopyBuffer(h_rsi,   0,0,3,rsiVal)   <3) return;

    double closeP=iClose(_Symbol,PERIOD_CURRENT,1);

    // [1] Murphy Trend — 40 pts
    bool aboveEma200 = (closeP > ema200[1]);
    bool belowEma200 = (closeP < ema200[1]);
    scoreBull += aboveEma200 ? 40.0 : 0.0;
    scoreBear += belowEma200 ? 40.0 : 0.0;

    // [2] Elder Impulse (EMA13 + MACD hist expanding) — 30 pts
    bool ema13Rising  = (ema13[1] > ema13[2]);
    bool ema13Falling = (ema13[1] < ema13[2]);
    bool histExpBull  = (macdHist[1] > macdHist[2]) && (macdHist[1] > 0);
    bool histExpBear  = (macdHist[1] < macdHist[2]) && (macdHist[1] < 0);
    bool impulse_bull = ema13Rising  && histExpBull;
    bool impulse_bear = ema13Falling && histExpBear;

    // Detect NEW impulse (wasn't active bar before — Murphy's entry rule)
    bool prevImpBull  = (ema13[2]>ema13[3]) && (macdHist[2]>macdHist[3]) && (macdHist[2]>0);
    bool prevImpBear  = (ema13[2]<ema13[3]) && (macdHist[2]<macdHist[3]) && (macdHist[2]<0);
    impulBull = impulse_bull && !prevImpBull;  // first bar of new bullish impulse
    impulBear = impulse_bear && !prevImpBear;  // first bar of new bearish impulse

    scoreBull += impulse_bull ? 30.0 : (ema13Rising  ? 15.0 : 0.0);
    scoreBear += impulse_bear ? 30.0 : (ema13Falling ? 15.0 : 0.0);

    // [3] EMA13 direction alone — 20 pts (partial credit)
    scoreBull += ema13Rising  ? 20.0 : 0.0;
    scoreBear += ema13Falling ? 20.0 : 0.0;

    // [4] RSI alignment — 10 pts
    bool rsiBull = (closeP > ema200[1] && rsiVal[1] > 50 && rsiVal[1] < RSI_OB);
    bool rsiBear = (closeP < ema200[1] && rsiVal[1] < 50 && rsiVal[1] > RSI_OS);
    scoreBull += rsiBull ? 10.0 : 0.0;
    scoreBear += rsiBear ? 10.0 : 0.0;

    // Normalize max = 100 (40+30+20+10)
    scoreBull = MathMin(scoreBull, 100.0);
    scoreBear = MathMin(scoreBear, 100.0);
}

//═══════════════════════════════════════════════════════════════
//  GAUSSIAN + MURPHY COMBINED SIGNAL
//═══════════════════════════════════════════════════════════════
SignalResult CalcSignal()
{
    SignalResult r;
    r.longSignal=r.shortSignal=false;
    r.gaussOut=r.gaussSig=r.atrGauss=r.atrMurphy=0;
    r.gaussStr=1; r.murphyScore=0;
    r.murphyBull=r.murphySell=false;

    if(!g_initialized || g_barsLoaded<WarmupBars+4) return r;

    // ── Gaussian values ──
    r.gaussOut  = g_ssOut[1];
    r.gaussSig  = g_ssOut[2];
    r.atrGauss  = CalcATR(1, AtrPer);

    double smax = r.gaussOut + r.atrGauss * AtrMult;
    double smin = r.gaussOut - r.atrGauss * AtrMult;

    // Volume sentiment
    double volMA = 0;
    for(int i=1;i<=14;i++) volMA += (double)iVolume(_Symbol,PERIOD_CURRENT,i);
    volMA /= 14.0;
    double vol1   = (double)iVolume(_Symbol,PERIOD_CURRENT,1);
    double open1  = iOpen (_Symbol,PERIOD_CURRENT,1);
    double close1 = iClose(_Symbol,PERIOD_CURRENT,1);
    double volThr = volMA * (VolThreshold/100.0);
    bool bullSent = (close1>open1) && (vol1>volThr);
    bool bearSent = (close1<open1) && (vol1>volThr);

    // Pivot Supply/Demand
    double ph=EMPTY_VALUE, pl=EMPTY_VALUE;
    bool phFound=true, plFound=true;
    double pivH=iHigh(_Symbol,PERIOD_CURRENT,1+SwingLen);
    double pivL=iLow (_Symbol,PERIOD_CURRENT,1+SwingLen);
    for(int i=1;i<1+SwingLen*2+1;i++)
    {
        if(iHigh(_Symbol,PERIOD_CURRENT,i)>pivH){ phFound=false; break; }
    }
    for(int i=1;i<1+SwingLen*2+1;i++)
    {
        if(iLow(_Symbol,PERIOD_CURRENT,i)<pivL){ plFound=false; break; }
    }
    double supply = phFound ? pivH : 0;
    double demand = plFound ? pivL : 0;

    // Gaussian crossover
    double prevOut=g_ssOut[2], prevSig=g_ssOut[3];
    bool crossOver  = (prevOut<=prevSig) && (r.gaussOut>r.gaussSig);
    bool crossUnder = (prevOut>=prevSig) && (r.gaussOut<r.gaussSig);

    bool sentOkL = !UseSentiment || bullSent;
    bool sentOkS = !UseSentiment || bearSent;
    bool demOk   = (demand==0) || (close1>demand);
    bool supOk   = (supply==0) || (close1<supply);

    bool gaussLong  = crossOver  && sentOkL && demOk && (close1<smax);
    bool gaussShort = crossUnder && sentOkS && supOk && (close1>smin);

    // Gaussian strength 1-10
    double distToMA  = (r.atrGauss>0)?MathAbs(close1-r.gaussOut)/r.atrGauss:0;
    double volFactor = (volMA>0)?MathMin(vol1/volMA,3.0):1.0;
    double sentFact  = UseSentiment?((bullSent||bearSent)?1.5:0.5):1.0;
    r.gaussStr = (int)MathRound(MathMin(MathMax(distToMA*2.0+volFactor+sentFact,1.0),10.0));

    // ── Murphy-Elder score ──
    double mBull=0, mBear=0;
    CalcMurphyScore(mBull, mBear, r.murphyBull, r.murphySell);
    r.murphyScore = gaussLong ? mBull : mBear;

    // RSI extreme block
    if(UseRSIFilter)
    {
        double rsiArr[]; ArraySetAsSeries(rsiArr,true);
        if(CopyBuffer(h_rsi,0,1,1,rsiArr)>=1)
        {
            if(gaussLong  && rsiArr[0]>=RSI_OB) gaussLong=false;
            if(gaussShort && rsiArr[0]<=RSI_OS) gaussShort=false;
        }
    }

    // Murphy confirmation gate
    if(UseMurphy)
    {
        if(gaussLong  && mBull < 40.0) gaussLong=false;   // need at least Murphy trend
        if(gaussShort && mBear < 40.0) gaussShort=false;
    }

    r.longSignal  = gaussLong;
    r.shortSignal = gaussShort;

    // Murphy ATR for SL/TP/Trail
    double atrBuf[]; ArraySetAsSeries(atrBuf,true);
    r.atrMurphy = (CopyBuffer(h_atr_m,0,1,1,atrBuf)>=1) ? atrBuf[0] : r.atrGauss;

    return r;
}

//═══════════════════════════════════════════════════════════════
//  LOT SIZE
//═══════════════════════════════════════════════════════════════
double CalcLotSize(double slDist)
{
    if(slDist<=0) return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double risk    = AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0;
    double tickVal = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double tickSz  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double lotStep = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    double minLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    if(tickSz==0||tickVal==0) return minLot;
    double vpl=(slDist/tickSz)*tickVal;
    if(vpl<=0) return minLot;
    double lots=MathFloor((risk/vpl)/lotStep)*lotStep;
    return NormalizeDouble(MathMax(minLot,MathMin(maxLot,lots)),2);
}

//═══════════════════════════════════════════════════════════════
//  DAILY LIMITS  (Murphy)
//═══════════════════════════════════════════════════════════════
bool CheckDailyLimits()
{
    if(!UseDailyLimits) return true;

    datetime todayStart=StringToTime(TimeToString(TimeCurrent(),TIME_DATE));
    if(todayStart!=g_lastDayChecked)
    {
        g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        g_lastDayChecked  = todayStart;
        g_dailyLimitHit   = false;
        g_limitReason     = "";
        PrintFormat("=== NEW DAY | Bal:$%.2f ===",g_dayStartBalance);
    }

    if(g_dailyLimitHit) return false;

    g_dailyPnL = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBalance;

    if(g_dailyPnL >= DailyProfitLimit)
    {
        g_dailyLimitHit=true;
        g_limitReason=StringFormat("PROFIT +$%.2f",g_dailyPnL);
        PrintFormat("⛔ Daily profit limit hit: %s",g_limitReason);
        CloseAllPositions();
        return false;
    }
    if(g_dailyPnL <= -DailyLossLimit)
    {
        g_dailyLimitHit=true;
        g_limitReason=StringFormat("LOSS $%.2f",g_dailyPnL);
        PrintFormat("⛔ Daily loss limit hit: %s",g_limitReason);
        CloseAllPositions();
        return false;
    }
    return true;
}

void CloseAllPositions()
{
    for(int i=PositionsTotal()-1;i>=0;i--)
        if(posInfo.SelectByIndex(i))
            if(posInfo.Symbol()==_Symbol && posInfo.Magic()==MagicNumber)
                trade.PositionClose(posInfo.Ticket());
}

//═══════════════════════════════════════════════════════════════
//  TRAILING STOP + BREAK-EVEN  (Murphy style)
//═══════════════════════════════════════════════════════════════
void ManagePositions()
{
    double atrArr[]; ArraySetAsSeries(atrArr,true);
    if(CopyBuffer(h_atr_m,0,1,1,atrArr)<1) return;
    double atr=atrArr[0];
    if(atr<=0) return;

    for(int i=PositionsTotal()-1;i>=0;i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Symbol()!=_Symbol || posInfo.Magic()!=MagicNumber) continue;

        double openP=posInfo.PriceOpen(), sl=posInfo.StopLoss(), tp=posInfo.TakeProfit();
        double slDist=MathAbs(openP-sl);
        if(slDist<=0) continue;

        if(posInfo.PositionType()==POSITION_TYPE_BUY)
        {
            double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
            double profR=(bid-openP)/slDist;

            // Break-even
            if(UseBreakEven && profR>=BE_RR_Trigger && sl<openP-_Point)
            {
                double nsl=NormalizeDouble(openP+_Point*2,_Digits);
                if(nsl>sl) trade.PositionModify(posInfo.Ticket(),nsl,tp);
            }
            // Trailing
            if(UseTrailing)
            {
                double tsl=NormalizeDouble(bid-atr*TrailMult,_Digits);
                if(tsl>sl && tsl<bid) trade.PositionModify(posInfo.Ticket(),tsl,tp);
            }
        }
        else
        {
            double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
            double profR=(openP-ask)/slDist;

            if(UseBreakEven && profR>=BE_RR_Trigger && sl>openP+_Point)
            {
                double nsl=NormalizeDouble(openP-_Point*2,_Digits);
                if(nsl<sl) trade.PositionModify(posInfo.Ticket(),nsl,tp);
            }
            if(UseTrailing)
            {
                double tsl=NormalizeDouble(ask+atr*TrailMult,_Digits);
                if(tsl<sl && tsl>ask) trade.PositionModify(posInfo.Ticket(),tsl,tp);
            }
        }
    }
}

//═══════════════════════════════════════════════════════════════
//  SESSION FILTER
//═══════════════════════════════════════════════════════════════
bool InSession()
{
    if(!UseSession) return true;
    MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
    return (dt.hour>=SessionStart && dt.hour<SessionEnd);
}

//═══════════════════════════════════════════════════════════════
//  POSITION CHECK
//═══════════════════════════════════════════════════════════════
bool HasPosition(ENUM_POSITION_TYPE type)
{
    for(int i=PositionsTotal()-1;i>=0;i--)
        if(posInfo.SelectByIndex(i))
            if(posInfo.Symbol()==_Symbol && posInfo.Magic()==MagicNumber &&
               posInfo.PositionType()==type)
                return true;
    return false;
}

bool HasAnyPosition()
{
    for(int i=PositionsTotal()-1;i>=0;i--)
        if(posInfo.SelectByIndex(i))
            if(posInfo.Symbol()==_Symbol && posInfo.Magic()==MagicNumber)
                return true;
    return false;
}

//═══════════════════════════════════════════════════════════════
//  FILLING AUTO-DETECT
//═══════════════════════════════════════════════════════════════
ENUM_ORDER_TYPE_FILLING GetFilling()
{
    uint f=(uint)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
    if((f&SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
    if((f&SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

//═══════════════════════════════════════════════════════════════
//  DASHBOARD
//═══════════════════════════════════════════════════════════════
void DrawPanel(SignalResult &sig, bool spreadOK, bool session)
{
    if(!ShowPanel) return;

    string gaussDir = sig.longSignal  ? "▲ LONG" :
                      sig.shortSignal ? "▼ SHORT" : "— WAIT";
    string murphyDir = sig.murphyBull ? "▲ BULL" :
                       sig.murphySell ? "▼ BEAR" : "— NEUTRAL";
    string gaussBar=""; int gb=(int)(sig.gaussStr/10.0*8);
    for(int i=0;i<8;i++) gaussBar+=i<gb?"█":"░";
    string murphyBar=""; int mb=(int)(sig.murphyScore/100.0*8);
    for(int i=0;i<8;i++) murphyBar+=i<mb?"█":"░";
    string pnlS=g_dailyPnL>=0?"+":"";
    string limitBar="";
    double lim=g_dailyPnL>=0?DailyProfitLimit:DailyLossLimit;
    double pct=lim>0?MathMin(MathAbs(g_dailyPnL)/lim*100,100):0;
    int lb=(int)(pct/10);
    for(int i=0;i<10;i++) limitBar+=i<lb?"█":"░";

    string status=g_dailyLimitHit?("⛔ HALTED: "+g_limitReason):"✅ TRADING";

    string panel=
        "╔══════════════════════════════════════╗\n"
        "║   GrokMurphy ELITE v1.0              ║\n"
        "║   Gaussian+Ehlers × Murphy-Elder     ║\n"
        "╠══════════════════════════════════════╣\n"
        "║  GAUSSIAN ENGINE                     ║\n"
        +StringFormat("║  Signal  : %-25s║\n", gaussDir)
        +StringFormat("║  Strength: [%s] %d/10         ║\n", gaussBar, sig.gaussStr)
        +StringFormat("║  SS Out  : %-10.5f SS Sig:%-8.5f║\n", sig.gaussOut, sig.gaussSig)
        +StringFormat("║  ATR(G)  : %-10.5f                ║\n", sig.atrGauss)
        +"╠══════════════════════════════════════╣\n"
        +"║  MURPHY-ELDER FILTER                 ║\n"
        +StringFormat("║  Impulse : %-25s║\n", murphyDir)
        +StringFormat("║  Score   : [%s] %.0f%%          ║\n", murphyBar, sig.murphyScore)
        +StringFormat("║  ATR(M)  : %-10.5f                ║\n", sig.atrMurphy)
        +"╠══════════════════════════════════════╣\n"
        +"║  FILTERS                             ║\n"
        +StringFormat("║  Spread  : %-3s  Session: %-3s       ║\n",
                      spreadOK?"OK":"HI", session?"OK":"--")
        +StringFormat("║  Warmup  : %d / %d bars         ║\n", g_barsLoaded, WarmupBars)
        +"╠══════════════════════════════════════╣\n"
        +"║  DAILY P/L                           ║\n"
        +StringFormat("║  P/L     : %s$%.2f                 ║\n", pnlS, g_dailyPnL)
        +StringFormat("║  [%s] %.0f%%            ║\n", limitBar, pct)
        +StringFormat("║  Status  : %-25s║\n", status)
        +"╚══════════════════════════════════════╝";

    Comment(panel);
}

//═══════════════════════════════════════════════════════════════
//  OnInit
//═══════════════════════════════════════════════════════════════
int OnInit()
{
    // Murphy-Elder handles
    h_ema200 = iMA(_Symbol,PERIOD_CURRENT,LongEmaLen, 0,MODE_EMA,PRICE_CLOSE);
    h_ema13  = iMA(_Symbol,PERIOD_CURRENT,ShortEmaLen,0,MODE_EMA,PRICE_CLOSE);
    h_macd   = iMACD(_Symbol,PERIOD_CURRENT,12,26,9,PRICE_CLOSE);
    h_atr_m  = iATR(_Symbol,PERIOD_CURRENT,14);
    h_rsi    = iRSI(_Symbol,PERIOD_CURRENT,RSI_Period,PRICE_CLOSE);

    if(h_ema200==INVALID_HANDLE || h_ema13==INVALID_HANDLE ||
       h_macd==INVALID_HANDLE   || h_atr_m==INVALID_HANDLE ||
       h_rsi==INVALID_HANDLE)
    { Print("ERROR: Indicator init failed!"); return INIT_FAILED; }

    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(GetFilling());

    // Gaussian warmup
    RebuildHistory();

    // Daily tracking
    g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_lastDayChecked  = StringToTime(TimeToString(TimeCurrent(),TIME_DATE));
    g_dailyLimitHit   = false;
    g_dailyPnL        = 0.0;

    PrintFormat("GrokMurphy Elite v1.0 | %s | Bars:%d/%d | Gauss:%d Ehlers:%d | Murphy:%s",
                _Symbol, g_barsLoaded, WarmupBars,
                SmthPer, ExtraSmthPer, UseMurphy?"ON":"OFF");
    return INIT_SUCCEEDED;
}

//═══════════════════════════════════════════════════════════════
//  OnDeinit
//═══════════════════════════════════════════════════════════════
void OnDeinit(const int reason)
{
    IndicatorRelease(h_ema200);
    IndicatorRelease(h_ema13);
    IndicatorRelease(h_macd);
    IndicatorRelease(h_atr_m);
    IndicatorRelease(h_rsi);
    ArrayFree(g_ssOut);
    ArrayFree(g_gaussRaw);
    Comment("");
    Print("GrokMurphy Elite v1.0 stopped. Reason:",reason);
}

//═══════════════════════════════════════════════════════════════
//  OnTick
//═══════════════════════════════════════════════════════════════
void OnTick()
{
    // Manage trailing/BE on every tick
    if(HasAnyPosition()) ManagePositions();

    // New bar only for signal logic
    static datetime lastBar=0;
    datetime barTime=iTime(_Symbol,PERIOD_CURRENT,1);
    if(barTime==lastBar) return;
    lastBar=barTime;

    // Rebuild Gaussian history (incremental each new bar)
    RebuildHistory();

    // Daily limits
    if(!CheckDailyLimits()) { SignalResult dummy; DrawPanel(dummy,true,true); return; }

    // Warmup guard
    if(g_barsLoaded<WarmupBars)
    {
        PrintFormat("Warmup: %d/%d bars",g_barsLoaded,WarmupBars);
        return;
    }

    // Spread check
    long spreadPts=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
    bool spreadOK=(spreadPts<=(long)MaxSpread);

    // Session check
    bool session=InSession();

    // Calculate combined signal
    SignalResult sig=CalcSignal();

    // Draw dashboard
    DrawPanel(sig,spreadOK,session);

    // Guards
    if(!spreadOK || !session) return;

    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double slDist=sig.atrMurphy*SlMultiplier;
    if(slDist<=0) return;

    // ── LONG ──────────────────────────────────────────────────
    if(sig.longSignal && AllowLong && !HasPosition(POSITION_TYPE_BUY))
    {
        CloseAllPositions();
        double sl  = NormalizeDouble(ask-slDist,_Digits);
        double tp  = NormalizeDouble(ask+slDist*RR,_Digits);
        double lot = CalcLotSize(slDist);
        if(lot>0)
        {
            if(trade.Buy(lot,_Symbol,ask,sl,tp,"GrokMurphy_LONG"))
                PrintFormat("▲ LONG | GStr:%d/10 MScore:%.0f%% | Ask:%.5f SL:%.5f TP:%.5f | Lots:%.2f",
                            sig.gaussStr, sig.murphyScore, ask, sl, tp, lot);
            else
                PrintFormat("LONG failed [%d]: %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
        }
    }

    // ── SHORT ─────────────────────────────────────────────────
    if(sig.shortSignal && AllowShort && !HasPosition(POSITION_TYPE_SELL))
    {
        CloseAllPositions();
        double sl  = NormalizeDouble(bid+slDist,_Digits);
        double tp  = NormalizeDouble(bid-slDist*RR,_Digits);
        double lot = CalcLotSize(slDist);
        if(lot>0)
        {
            if(trade.Sell(lot,_Symbol,bid,sl,tp,"GrokMurphy_SHORT"))
                PrintFormat("▼ SHORT | GStr:%d/10 MScore:%.0f%% | Bid:%.5f SL:%.5f TP:%.5f | Lots:%.2f",
                            sig.gaussStr, sig.murphyScore, bid, sl, tp, lot);
            else
                PrintFormat("SHORT failed [%d]: %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
        }
    }
}
//+------------------------------------------------------------------+
