//+------------------------------------------------------------------+
//|                                      Trap_Divergence_Bot_v1.0.mq5 |
//|                                  Trap Divergence Bot — v1.0       |
//+------------------------------------------------------------------+
#property copyright "Trap Divergence Bot v1.0"
#property link      ""
#property version   "1.00"
#property description "Trap Divergence Bot — BB/Keltner squeeze + RSI hook/divergence trap"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| News filter (manual): goal is to stand aside ~45 min before and |
//| after high-impact releases (needs a calendar feed in full auto). |
//| For now: UseNewsFilter=true pauses NEW entries; disable the EA or |
//| attach a free News Filter indicator around known events.        |
//| Full auto WebRequest + calendar parsing can be added later.      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input string            InpSymbol            = "";
input ENUM_TIMEFRAMES   InpTF               = PERIOD_M5;
input ulong             InpMagic             = 202604051;
input string            InpTradeComment     = "TrapDiv v1";
input int               InpSlippage          = 30;
input double            InpRiskPercent       = 1.0;
input int               InpMaxSpreadPoints   = 30;
input bool              InpUseDailyLossLimit = true;
input double            InpDailyLossPercent  = 4.0;
input double            InpStaticDDPercent   = 10.0;
input bool              InpUseStaticDDLimit  = false;

input group "=== News filter (manual) ==="
input bool              InpUseNewsFilter     = true;

input group "=== Bollinger Bands ==="
input int               InpBBPeriod          = 20;
input double            InpBBDeviation       = 2.0;
input ENUM_APPLIED_PRICE InpBBApplied         = PRICE_CLOSE;

input group "=== Keltner (EMA + ATR*mult) ==="
input int               InpKeltnerEmaPeriod    = 20;
input double            InpKeltnerMult       = 1.5;
input int               InpKeltnerAtrPeriod    = 10;

input group "=== RSI ==="
input int               InpRsiPeriod         = 14;
input ENUM_APPLIED_PRICE InpRsiApplied       = PRICE_CLOSE;
input int               InpRsiPeak1High       = 70;
input int               InpRsiPeak1Low        = 30;
input int               InpRsiBearPeak2Lo     = 50;
input int               InpRsiBearPeak2Hi     = 65;
input int               InpRsiBullPeak2Lo     = 35;
input int               InpRsiBullPeak2Hi     = 50;

input group "=== SMA (TP1 anchor) ==="
input int               InpSmaPeriod         = 20;
input ENUM_APPLIED_PRICE InpSmaApplied       = PRICE_CLOSE;

input group "=== Strategy windows ==="
input int               InpSqueezeLookback   = 5;
input int               InpPeak2Window       = 10;
input int               InpTimeExitBars      = 12;
input double            InpSlExtraPips       = 2.0;
input double            InpTp1VolumePct      = 50.0;

input group "=== Dashboard ==="
input bool              InpShowDashboard     = true;
input int               InpDashFontSize      = 9;
input int               InpDashCornerX       = 10;
input int               InpDashCornerY       = 20;
input color             InpColorGood         = clrLime;
input color             InpColorWait         = clrTomato;
input color             InpColorProgress     = clrGold;
input color             InpColorTitle        = clrWhite;

//+------------------------------------------------------------------+
enum ENUM_TRAP_STATE
  {
   TRAP_IDLE = 0,
   TRAP_NEED_PEAK1,
   TRAP_PEAK1_OK,
   TRAP_WAIT_TRIGGER
  };

CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

string            g_sym_name;
ENUM_TIMEFRAMES   g_tf;

int    g_hBB, g_hEMA, g_hATR, g_hRSI, g_hSMA;
double g_point;
int    g_digits;

datetime g_last_chart_bar_time = 0;
datetime g_news_pause_last_log = 0;

ENUM_TRAP_STATE g_bear_st = TRAP_NEED_PEAK1;
double   g_bear_p1_ext = 0.0;
datetime g_bear_p1_time = 0;
double   g_bear_p2_high = 0.0;
int      g_bear_p2_age = 0;
bool     g_bear_sq = false;

ENUM_TRAP_STATE g_bull_st = TRAP_NEED_PEAK1;
double   g_bull_p1_ext = 0.0;
datetime g_bull_p1_time = 0;
double   g_bull_p2_low = 0.0;
int      g_bull_p2_age = 0;
bool     g_bull_sq = false;

int      g_pend_dir = 0;
double   g_pend_sl_extreme = 0.0;

double   g_day0_equity = 0.0;
double   g_hist_high_equity = 0.0;
int      g_day_ymd = 0;

bool     g_tp1_done = false;

string   g_last_trade_line = "Last trade: —";

//+------------------------------------------------------------------+
int OnInit()
  {
   g_sym_name = (InpSymbol == "" ? _Symbol : InpSymbol);
   g_tf       = InpTF;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(g_sym_name);
   g_trade.SetAsyncMode(false);

   if(!g_sym.Name(g_sym_name))
     {
      Print("Symbol failed: ", g_sym_name);
      return INIT_FAILED;
     }

   g_point  = g_sym.Point();
   g_digits = (int)g_sym.Digits();

   g_hBB  = iBands(g_sym_name, g_tf, InpBBPeriod, InpBBDeviation, 0, InpBBApplied);
   g_hEMA = iMA(g_sym_name, g_tf, InpKeltnerEmaPeriod, 0, MODE_EMA, InpBBApplied);
   g_hATR = iATR(g_sym_name, g_tf, InpKeltnerAtrPeriod);
   g_hRSI = iRSI(g_sym_name, g_tf, InpRsiPeriod, InpRsiApplied);
   g_hSMA = iMA(g_sym_name, g_tf, InpSmaPeriod, 0, MODE_SMA, InpSmaApplied);

   if(g_hBB == INVALID_HANDLE || g_hEMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE ||
      g_hRSI == INVALID_HANDLE || g_hSMA == INVALID_HANDLE)
     {
      Print("Indicator handle error");
      return INIT_FAILED;
     }

   DayResetIfNeeded();
   g_hist_high_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_last_chart_bar_time = iTime(g_sym_name, g_tf, 0);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hBB != INVALID_HANDLE)  IndicatorRelease(g_hBB);
   if(g_hEMA != INVALID_HANDLE) IndicatorRelease(g_hEMA);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hSMA != INVALID_HANDLE) IndicatorRelease(g_hSMA);
   ObjectsDeleteAll(0, "TDV1_");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_sym.RefreshRates();

   DayResetIfNeeded();

   if(BlockedByRisk())
     {
      UpdateDashboard();
      ManagePosition();
      return;
     }

   if(InpUseNewsFilter)
     {
      if(TimeCurrent() - g_news_pause_last_log > 300)
        {
         Print("NEWS FILTER ACTIVE - TRADING PAUSED");
         g_news_pause_last_log = TimeCurrent();
        }
      UpdateDashboard();
      ManagePosition();
      return;
     }

   ManagePosition();

   if(OurPositionExists())
     {
      UpdateDashboard();
      return;
     }

   datetime t0 = iTime(g_sym_name, g_tf, 0);
   if(t0 != g_last_chart_bar_time)
     {
      g_last_chart_bar_time = t0;
      OnBarEvent();
     }
   if(g_pend_dir != 0)
      ExecutePendingEntry();

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
void DayResetIfNeeded()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int ymd = t.year * 10000 + t.mon * 100 + t.day;
   if(ymd != g_day_ymd)
     {
      g_day_ymd = ymd;
      g_day0_equity = AccountInfoDouble(ACCOUNT_EQUITY);
     }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_hist_high_equity) g_hist_high_equity = eq;
  }

//+------------------------------------------------------------------+
bool BlockedByRisk()
  {
   if(InpUseDailyLossLimit && g_day0_equity > 0.0)
     {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd = (g_day0_equity - eq) / g_day0_equity * 100.0;
      if(dd >= InpDailyLossPercent) return true;
     }
   if(InpUseStaticDDLimit && g_hist_high_equity > 0.0)
     {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd = (g_hist_high_equity - eq) / g_hist_high_equity * 100.0;
      if(dd >= InpStaticDDPercent) return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool OurPositionExists()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != g_sym_name) continue;
      if(g_pos.Magic() != InpMagic) continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool Buf1(const int h, const int buf, const int shift, double &v)
  {
   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(h, buf, shift, 1, a) != 1) return false;
   v = a[0];
   return true;
  }

//+------------------------------------------------------------------+
bool BB(const int sh, double &up, double &mid, double &lo)
  {
   if(!Buf1(g_hBB, 0, sh, up)) return false;
   if(!Buf1(g_hBB, 1, sh, mid)) return false;
   if(!Buf1(g_hBB, 2, sh, lo)) return false;
   return true;
  }

//+------------------------------------------------------------------+
bool KeltnerWidth(const int sh, double &ku, double &kl, double &w)
  {
   double ema, atr;
   if(!Buf1(g_hEMA, 0, sh, ema)) return false;
   if(!Buf1(g_hATR, 0, sh, atr)) return false;
   double off = InpKeltnerMult * atr;
   ku = ema + off;
   kl = ema - off;
   w = ku - kl;
   return true;
  }

//+------------------------------------------------------------------+
bool SqueezeBar(const int sh)
  {
   double bu, bm, bl, ku, kl, kw;
   if(!BB(sh, bu, bm, bl)) return false;
   if(!KeltnerWidth(sh, ku, kl, kw)) return false;
   return ((bu - bl) <= kw);
  }

//+------------------------------------------------------------------+
bool SqueezeRecent()
  {
   int n = MathMax(1, InpSqueezeLookback);
   for(int sh = 1; sh <= n; sh++)
      if(SqueezeBar(sh)) return true;
   return false;
  }

//+------------------------------------------------------------------+
double Hi(const int sh)
  {
   double v[];
   ArraySetAsSeries(v, true);
   if(CopyHigh(g_sym_name, g_tf, sh, 1, v) != 1) return 0.0;
   return v[0];
  }

//+------------------------------------------------------------------+
double Lo(const int sh)
  {
   double v[];
   ArraySetAsSeries(v, true);
   if(CopyLow(g_sym_name, g_tf, sh, 1, v) != 1) return 0.0;
   return v[0];
  }

//+------------------------------------------------------------------+
double Cl(const int sh)
  {
   double v[];
   ArraySetAsSeries(v, true);
   if(CopyClose(g_sym_name, g_tf, sh, 1, v) != 1) return 0.0;
   return v[0];
  }

//+------------------------------------------------------------------+
bool Rsi(const int sh, double &r)
  {
   return Buf1(g_hRSI, 0, sh, r);
  }

//+------------------------------------------------------------------+
bool Sma(const int sh, double &s)
  {
   return Buf1(g_hSMA, 0, sh, s);
  }

//+------------------------------------------------------------------+
bool InsideBB(const int sh)
  {
   double u, m, l;
   if(!BB(sh, u, m, l)) return false;
   double c = Cl(sh);
   return (c > l && c < u);
  }

//+------------------------------------------------------------------+
double PipUnit()
  {
   if(g_digits == 3 || g_digits == 5) return 10.0 * g_point;
   return g_point;
  }

//+------------------------------------------------------------------+
bool SpreadOK()
  {
   if(InpMaxSpreadPoints <= 0) return true;
   return ((double)g_sym.Spread() <= (double)InpMaxSpreadPoints);
  }

//+------------------------------------------------------------------+
void OnBarEvent()
  {
   if(!SpreadOK()) return;

   const int sh = 1;

   bool sq = SqueezeRecent();
   g_bear_sq = sq;
   g_bull_sq = sq;
   if(g_pend_dir != 0)
      return;

   double bu, bm, bl;
   double ku, kl, kw;
   double rsi1;
   if(!BB(sh, bu, bm, bl) || !KeltnerWidth(sh, ku, kl, kw) || !Rsi(sh, rsi1))
      return;

   double H = Hi(sh);
   double L = Lo(sh);
   datetime tbar = iTime(g_sym_name, g_tf, sh);

   //--- Bearish
   if(g_bear_st == TRAP_NEED_PEAK1)
     {
      if(sq && H >= bu && rsi1 >= (double)InpRsiPeak1High)
        {
         g_bear_st = TRAP_PEAK1_OK;
         g_bear_p1_ext = H;
         g_bear_p1_time = tbar;
         g_bear_p2_age = 0;
         g_bear_p2_high = 0.0;
        }
     }
   else if(g_bear_st == TRAP_PEAK1_OK)
     {
      g_bear_p2_age++;
      if(g_bear_p2_age > InpPeak2Window)
        {
         g_bear_st = TRAP_NEED_PEAK1;
        }
      else
        {
         double r2;
         if(Rsi(sh, r2) && H > g_bear_p1_ext &&
            r2 >= (double)InpRsiBearPeak2Lo && r2 <= (double)InpRsiBearPeak2Hi)
           {
            g_bear_p2_high = H;
            g_bear_st = TRAP_WAIT_TRIGGER;
           }
        }
     }
   else if(g_bear_st == TRAP_WAIT_TRIGGER)
     {
      if(InsideBB(sh))
        {
         g_pend_dir = -1;
         g_pend_sl_extreme = g_bear_p2_high + InpSlExtraPips * PipUnit();
         g_bear_st = TRAP_NEED_PEAK1;
         g_bear_p2_age = 0;
         if(g_bull_st == TRAP_WAIT_TRIGGER)
            g_bull_st = TRAP_NEED_PEAK1;
        }
     }

   //--- Bullish
   if(g_bull_st == TRAP_NEED_PEAK1)
     {
      if(sq && L <= bl && rsi1 <= (double)InpRsiPeak1Low)
        {
         g_bull_st = TRAP_PEAK1_OK;
         g_bull_p1_ext = L;
         g_bull_p1_time = tbar;
         g_bull_p2_age = 0;
         g_bull_p2_low = 0.0;
        }
     }
   else if(g_bull_st == TRAP_PEAK1_OK)
     {
      g_bull_p2_age++;
      if(g_bull_p2_age > InpPeak2Window)
        {
         g_bull_st = TRAP_NEED_PEAK1;
        }
      else
        {
         double r2b;
         if(Rsi(sh, r2b) && L < g_bull_p1_ext &&
            r2b >= (double)InpRsiBullPeak2Lo && r2b <= (double)InpRsiBullPeak2Hi)
           {
            g_bull_p2_low = L;
            g_bull_st = TRAP_WAIT_TRIGGER;
           }
        }
     }
   else if(g_bull_st == TRAP_WAIT_TRIGGER)
     {
      if(InsideBB(sh) && g_pend_dir == 0)
        {
         g_pend_dir = +1;
         g_pend_sl_extreme = g_bull_p2_low - InpSlExtraPips * PipUnit();
         g_bull_st = TRAP_NEED_PEAK1;
         g_bull_p2_age = 0;
         if(g_bear_st == TRAP_WAIT_TRIGGER)
            g_bear_st = TRAP_NEED_PEAK1;
        }
     }
  }

//+------------------------------------------------------------------+
bool LotsForRisk(const bool is_buy, const double entry, const double sl, double &lots)
  {
   lots = 0.0;
   double dist = is_buy ? (entry - sl) : (sl - entry);
   if(dist <= 0.0) return false;

   double risk_money = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;

   double loss_per_lot = 0.0;
   if(is_buy)
     {
      if(!OrderCalcProfit(ORDER_TYPE_BUY, g_sym_name, 1.0, entry, sl, loss_per_lot))
         return false;
     }
   else
     {
      if(!OrderCalcProfit(ORDER_TYPE_SELL, g_sym_name, 1.0, entry, sl, loss_per_lot))
         return false;
     }

   loss_per_lot = MathAbs(loss_per_lot);
   if(loss_per_lot <= 0.0)
      loss_per_lot = MathAbs(entry - sl) / g_sym.TickSize() * g_sym.TickValue();

   if(loss_per_lot <= 0.0) return false;

   lots = risk_money / loss_per_lot;
   double step = g_sym.LotsStep();
   double mn = g_sym.LotsMin();
   double mx = g_sym.LotsMax();
   lots = MathFloor(lots / step) * step;
   if(lots < mn) lots = mn;
   if(lots > mx) lots = mx;
   return true;
  }

//+------------------------------------------------------------------+
void ExecutePendingEntry()
  {
   if(g_pend_dir == 0) return;
   if(!SpreadOK()) return;

   int dir = g_pend_dir;
   double sl_price = g_pend_sl_extreme;

   if(dir < 0)
     {
      double price = g_sym.Bid();
      if(sl_price <= price) sl_price = price + 10.0 * g_point;
      double lots;
      if(!LotsForRisk(false, price, sl_price, lots)) return;
      if(!g_trade.Sell(lots, g_sym_name, price, sl_price, 0.0, InpTradeComment))
        {
         Print("Sell error ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         return;
        }
      g_pend_dir = 0;
      g_tp1_done = false;
      g_last_trade_line = StringFormat("Last trade: SELL %.2f lots @ %s", lots, DoubleToString(price, g_digits));
     }
   else if(dir > 0)
     {
      double price = g_sym.Ask();
      if(sl_price >= price) sl_price = price - 10.0 * g_point;
      double lots;
      if(!LotsForRisk(true, price, sl_price, lots)) return;
      if(!g_trade.Buy(lots, g_sym_name, price, sl_price, 0.0, InpTradeComment))
        {
         Print("Buy error ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
         return;
        }
      g_pend_dir = 0;
      g_tp1_done = false;
      g_last_trade_line = StringFormat("Last trade: BUY %.2f lots @ %s", lots, DoubleToString(price, g_digits));
     }
  }

//+------------------------------------------------------------------+
void ManagePosition()
  {
   ulong ticket = 0;
   bool have = false;
   for(int k = PositionsTotal() - 1; k >= 0; k--)
     {
      if(!g_pos.SelectByIndex(k)) continue;
      if(g_pos.Symbol() != g_sym_name) continue;
      if(g_pos.Magic() != InpMagic) continue;
      have = true;
      ticket = g_pos.Ticket();
      break;
     }
   if(!have)
     {
      g_tp1_done = false;
      return;
     }

   long typ = g_pos.PositionType();
   double vol = g_pos.Volume();
   double openp = g_pos.PriceOpen();

   double sma0, bu0, bm0, bl0;
   if(!Sma(0, sma0) || !BB(0, bu0, bm0, bl0)) return;

   datetime et = (datetime)g_pos.Time();
   int sh_entry = iBarShift(g_sym_name, g_tf, et, true);
   if(sh_entry < 0) sh_entry = 0;
   int bars_since = sh_entry;

   if(!g_tp1_done && bars_since >= InpTimeExitBars)
     {
      if(g_trade.PositionClose(ticket))
         g_last_trade_line = "Last trade: TIME EXIT (no TP1)";
      return;
     }

   double pct = MathMax(1.0, MathMin(100.0, InpTp1VolumePct));
   double part = vol * (pct / 100.0);
   double step = g_sym.LotsStep();
   part = MathFloor(part / step) * step;
   if(part < g_sym.LotsMin()) part = g_sym.LotsMin();
   if(part > vol) part = vol;

   if(typ == POSITION_TYPE_SELL)
     {
      if(!g_tp1_done && g_sym.Bid() <= sma0)
        {
         if(g_trade.PositionClosePartial(ticket, part))
           {
            g_tp1_done = true;
            if(!g_trade.PositionModify(ticket, openp, 0.0))
               Print("BE sell failed ", g_trade.ResultRetcodeDescription());
           }
        }
      if(g_tp1_done && g_sym.Bid() <= bl0)
        {
         if(g_trade.PositionClose(ticket))
            g_last_trade_line = "Last trade: SELL TP2 (lower BB)";
        }
     }
   else if(typ == POSITION_TYPE_BUY)
     {
      if(!g_tp1_done && g_sym.Ask() >= sma0)
        {
         if(g_trade.PositionClosePartial(ticket, part))
           {
            g_tp1_done = true;
            if(!g_trade.PositionModify(ticket, openp, 0.0))
               Print("BE buy failed ", g_trade.ResultRetcodeDescription());
           }
        }
      if(g_tp1_done && g_sym.Ask() >= bu0)
        {
         if(g_trade.PositionClose(ticket))
            g_last_trade_line = "Last trade: BUY TP2 (upper BB)";
        }
     }
  }

//+------------------------------------------------------------------+
int CompletionPct(const bool bull, const ENUM_TRAP_STATE st, const int age, const int win)
  {
   bool sq = bull ? g_bull_sq : g_bear_sq;
   if(!sq) return 0;
   if(st == TRAP_NEED_PEAK1) return 20;
   if(st == TRAP_PEAK1_OK)
     {
      double f = (double)MathMin(age, win) / (double)MathMax(1, win);
      return 20 + (int)(40.0 * f);
     }
   if(st == TRAP_WAIT_TRIGGER) return 100;
   return 0;
  }

//+------------------------------------------------------------------+
string CriteriaLine(const bool bull, const ENUM_TRAP_STATE st, const int age, const int win)
  {
   if(!bull && !g_bear_sq) return "Criteria left: squeeze";
   if(bull && !g_bull_sq) return "Criteria left: squeeze";
   if(st == TRAP_NEED_PEAK1) return "Criteria left: Peak1 hook";
   if(st == TRAP_PEAK1_OK) return "Criteria left: Peak2 div";
   if(st == TRAP_WAIT_TRIGGER) return "Ready to trade";
   return "Criteria left: —";
  }

//+------------------------------------------------------------------+
void DashLbl(const string id, const int x, int &y, const int dy, const string tx, const color c)
  {
   string n = "TDV1_" + id;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, InpDashFontSize);
   ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, n, OBJPROP_TEXT, tx);
   y += dy;
  }

//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpShowDashboard) return;

   int x = InpDashCornerX;
   int y = InpDashCornerY;
   int dy = InpDashFontSize + 4;

   color ok = InpColorGood, wt = InpColorWait, pr = InpColorProgress, wt2 = InpColorTitle;

   string nf = InpUseNewsFilter ? "NEWS FILTER: PAUSED (manual mode)" : "News filter: OFF";
   color nc = InpUseNewsFilter ? wt : ok;
   if(BlockedByRisk())
     {
      nf += " | RISK STOP";
      nc = wt;
     }

   DashLbl("t", x, y, dy + 2, "Trap Divergence Bot v1.0   " + g_sym_name + " / " + EnumToString(g_tf), wt2);
   DashLbl("n", x, y, dy, nf, nc);

   // SELL trap
   string sqs = g_bear_sq ? "HIT" : "MISS";
   color sqc = g_bear_sq ? ok : wt;
   string p1s = (g_bear_st >= TRAP_PEAK1_OK && g_bear_p1_time > 0)
                   ? StringFormat("HIT (%.5f @ %s)", g_bear_p1_ext, TimeToString(g_bear_p1_time, TIME_DATE|TIME_MINUTES))
                   : "—";
   color p1c = (g_bear_st >= TRAP_PEAK1_OK) ? pr : wt;
   int p2prog = 0;
   if(g_bear_st == TRAP_PEAK1_OK) p2prog = MathMin(g_bear_p2_age, InpPeak2Window);
   string p2s = (g_bear_st == TRAP_WAIT_TRIGGER)
                   ? StringFormat("%d / %d (Peak2 OK)", InpPeak2Window, InpPeak2Window)
                   : StringFormat("%d / %d candles", p2prog, InpPeak2Window);
   string trg = (g_bear_st == TRAP_WAIT_TRIGGER) ? "YES" : "NO";
   color trc = (g_bear_st == TRAP_WAIT_TRIGGER) ? ok : wt;
   int cmp = CompletionPct(false, g_bear_st, g_bear_p2_age, InpPeak2Window);
   string crit = CriteriaLine(false, g_bear_st, g_bear_p2_age, InpPeak2Window);

   DashLbl("h1", x, y, dy + 3, "—— BEAR (SELL) TRAP ——", wt2);
   DashLbl("b0", x, y, dy, "Squeeze: " + sqs, sqc);
   DashLbl("b1", x, y, dy, "Peak 1: " + p1s, p1c);
   DashLbl("b2", x, y, dy, "Peak 2 progress: " + p2s, pr);
   DashLbl("b3", x, y, dy, "Trigger ready: " + trg, trc);
   DashLbl("b4", x, y, dy, "Trap completion: " + IntegerToString(cmp) + "%", pr);
   DashLbl("b5", x, y, dy, crit, (cmp >= 85 ? ok : pr));
   DashLbl("b6", x, y, dy + 4, "", wt2);

   // BUY trap
   string sqbs = g_bull_sq ? "HIT" : "MISS";
   color sqbc = g_bull_sq ? ok : wt;
   string p1bs = (g_bull_st >= TRAP_PEAK1_OK && g_bull_p1_time > 0)
                    ? StringFormat("HIT (%.5f @ %s)", g_bull_p1_ext, TimeToString(g_bull_p1_time, TIME_DATE|TIME_MINUTES))
                    : "—";
   color p1bc = (g_bull_st >= TRAP_PEAK1_OK) ? pr : wt;
   int p2progb = 0;
   if(g_bull_st == TRAP_PEAK1_OK) p2progb = MathMin(g_bull_p2_age, InpPeak2Window);
   string p2bs = (g_bull_st == TRAP_WAIT_TRIGGER)
                    ? StringFormat("%d / %d (Peak2 OK)", InpPeak2Window, InpPeak2Window)
                    : StringFormat("%d / %d candles", p2progb, InpPeak2Window);
   string trgb = (g_bull_st == TRAP_WAIT_TRIGGER) ? "YES" : "NO";
   color trcb = (g_bull_st == TRAP_WAIT_TRIGGER) ? ok : wt;
   int cmpb = CompletionPct(true, g_bull_st, g_bull_p2_age, InpPeak2Window);
   string critb = CriteriaLine(true, g_bull_st, g_bull_p2_age, InpPeak2Window);

   DashLbl("h2", x, y, dy + 3, "—— BULL (BUY) TRAP ——", wt2);
   DashLbl("u0", x, y, dy, "Squeeze: " + sqbs, sqbc);
   DashLbl("u1", x, y, dy, "Peak 1: " + p1bs, p1bc);
   DashLbl("u2", x, y, dy, "Peak 2 progress: " + p2bs, pr);
   DashLbl("u3", x, y, dy, "Trigger ready: " + trgb, trcb);
   DashLbl("u4", x, y, dy, "Trap completion: " + IntegerToString(cmpb) + "%", pr);
   DashLbl("u5", x, y, dy, critb, (cmpb >= 85 ? ok : pr));
   DashLbl("u6", x, y, dy + 4, g_last_trade_line, ok);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
