//+------------------------------------------------------------------+
//|                                    XAUUSD_M5M1_Scalper_V1_02.mq5 |
//|                                     XAUUSD M5/M1 Scalper  V1.02  |
//|                            Independent V1 strategy family (new)  |
//+------------------------------------------------------------------+
#property copyright   "XAUUSD M5/M1 Scalper V1"
#property link        ""
#property version     "1.02"
#property description "Independent causal M5/M1 pullback-reclaim scalper for XAUUSD."
#property description "M5 confirmed swing structure = directional permission only (HH+HL / LH+LL)."
#property description "M1 ATR-normalized pullback arms a setup; a fresh trigger cross executes once."
#property description "Management: initial structural SL -> break-even -> completed-M1 ATR trail."
#property description "V1.01 adds ATR-normalized initial risk geometry filtering (Min/MaxInitialRiskATR)."
#property description "V1.02 replaces the rolling N-bar M1 reclaim trigger with a confirmed"
#property description "turn-candle frozen breakout trigger (closed M1 candle -> frozen high/low -> fresh live cross)."
#property description "No fixed TP. No ABCD. No parent A/B. No H1/M15/M30 layers."
#property description "No martingale / grid / averaging / opposite-position hedging."
#property description "Netting-account note: on netting accounts same-direction entries merge into one"
#property description "position (broker behavior); management then applies to the merged position and"
#property description "MaxOpenTrades is enforced by EA trade counting, not by position tickets."

//==================================================================
// STRATEGY CONTRACT (V1)
//==================================================================
// M5  = directional regime (confirmed causal pivots, HH+HL / LH+LL)
// M1  = pullback detection (ATR-normalized retreat from N-bar extreme)
// M1  = entry trigger (V1.02): first directional CLOSED M1 turn candle
//       after pullback qualification -> freeze its high (BUY) / low
//       (SELL) -> require a fresh live Ask/Bid break of that FROZEN
//       level. The trigger never follows a rolling N-bar extreme.
// ATR = normalization, SL buffer, BE trigger, trailing distance
// Sequence: initial structural SL -> break-even -> ATR trailing
// No fixed take-profit target exists anywhere in this EA.
// V1.01: the FINAL broker-valid initial SL must produce a total
// entry-to-SL risk within [MinInitialRiskATR .. MaxInitialRiskATR]
// (completed M1 ATR units, inclusive boundaries). Out-of-band risk
// blocks the trade; the structural stop is never moved to pass.
//==================================================================

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_REGIME
  {
   REGIME_NEUTRAL = 0,
   REGIME_BULLISH = 1,
   REGIME_BEARISH = 2
  };

enum ENUM_SETUP_STATE
  {
   WAIT_PULLBACK = 0,
   WAIT_RECLAIM  = 1
  };

enum ENUM_TRADE_DIR
  {
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = 2
  };

enum ENUM_ENTRY_BLOCK
  {
   ENTRY_OK               = 0,
   ENTRY_BLOCK_INIT       = 1,
   ENTRY_BLOCK_ACTIVE     = 2,
   ENTRY_BLOCK_REGIME     = 3,
   ENTRY_BLOCK_EXPIRED    = 4,
   ENTRY_BLOCK_POS_LIMIT  = 5,
   ENTRY_BLOCK_SESSION    = 6,
   ENTRY_BLOCK_SPREAD     = 7,
   ENTRY_BLOCK_VOLATILITY = 8,
   ENTRY_BLOCK_SYMBOL     = 9,
   ENTRY_BLOCK_TERMINAL   = 10,
   ENTRY_BLOCK_VOLUME     = 11,
   ENTRY_BLOCK_MARGIN     = 12,
   ENTRY_BLOCK_STOPS      = 13,
   ENTRY_BLOCK_FILLING    = 14,
   // V1.01: initial risk geometry (stop itself is valid, its total
   // entry-to-SL risk distance relative to ATR is unacceptable)
   ENTRY_BLOCK_RISK_TOO_TIGHT = 15,
   ENTRY_BLOCK_RISK_TOO_WIDE  = 16
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "M5 REGIME"
input int    M5PivotSize = 2;

input group "M1 ENTRY"
input int    ATRPeriod              = 14;
input double PullbackATRMin         = 0.40;
input int    PullbackReferenceBars  = 5;
input int    ReclaimLookbackBars    = 3;   // Legacy V1.01 compatibility; unused by V1.02 turn-candle trigger
input int    SetupExpiryMinutes     = 15;
input int    ReentryCooldownMinutes = 2;

input group "TRADE MANAGEMENT"
input double InitialStopATRBuffer = 0.20;
input double MinInitialRiskATR    = 0.40;
input double MaxInitialRiskATR    = 1.00;
input double BreakEvenTriggerATR  = 0.60;
input double BreakEvenLockATR     = 0.00;
input double TrailStartATR        = 1.00;
input double TrailATRMult         = 1.00;

input group "VOLATILITY"
input int    VolatilityLookback   = 50;
input double VolatilitySpikeLimit = 1.50;

input group "MONEY / EXECUTION"
input double LotSize           = 0.01;
input long   MagicNumber       = 20260922;
input int    MaxOpenTrades     = 3;
input int    MaxSpreadPoints   = 350;
input int    MaxSlippagePoints = 30;

input group "SESSION"
input int TradingStartHour = 7;
input int TradingEndHour   = 20;

input group "PANEL"
input bool ShowPanel       = true;
input int  PanelRefreshMs  = 300;

input group "DEBUG"
input bool DebugMode  = false;
input bool DebugM5    = false;
input bool DebugM1    = false;
input bool DebugTrade = false;

//+------------------------------------------------------------------+
//| Validated / clamped effective inputs (inputs are never modified) |
//+------------------------------------------------------------------+
int    EffM5PivotSize            = 2;
int    EffATRPeriod              = 14;
double EffPullbackATRMin         = 0.40;
int    EffPullbackReferenceBars  = 5;
int    EffReclaimLookbackBars    = 3;
int    EffSetupExpiryMinutes     = 15;
int    EffReentryCooldownMinutes = 2;
double EffInitialStopATRBuffer   = 0.20;
double EffMinInitialRiskATR      = 0.40;
double EffMaxInitialRiskATR      = 1.00;
double EffBreakEvenTriggerATR    = 0.60;
double EffBreakEvenLockATR       = 0.00;
double EffTrailStartATR          = 1.00;
double EffTrailATRMult           = 1.00;
int    EffVolatilityLookback     = 50;
double EffVolatilitySpikeLimit   = 1.50;
double EffLotSize                = 0.01;
int    EffMaxOpenTrades          = 3;
int    EffMaxSpreadPoints        = 350;
int    EffMaxSlippagePoints      = 30;
int    EffTradingStartHour       = 7;
int    EffTradingEndHour         = 20;
int    EffPanelRefreshMs         = 300;

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct SM5Structure
  {
   double            latestSwingHigh;
   double            previousSwingHigh;
   double            latestSwingLow;
   double            previousSwingLow;
   datetime          latestSwingHighTime;
   datetime          previousSwingHighTime;
   datetime          latestSwingLowTime;
   datetime          previousSwingLowTime;
   ENUM_REGIME       regime;
   int               confirmedHighs;   // >=2 required for classification
   int               confirmedLows;
  };

struct SSetup
  {
   bool              active;             // armed, waiting for the V1.02 trigger episode
   ENUM_SETUP_STATE  state;
   ENUM_TRADE_DIR    direction;
   datetime          setupStartTime;     // = pullback qualification time (expiry anchor, never restarted)
   datetime          pullbackQualifiedTime;
   double            referenceExtreme;   // reference high (BUY) / low (SELL)
   double            pullbackExtreme;    // lowest Bid (BUY) / highest Ask (SELL) since qualification
   double            atrAtSetup;         // completed M1 ATR at qualification
   bool              crossArmed;         // price last seen on the non-breakout side of frozenTrigger
   long              setupId;
   // --- V1.02 turn-candle trigger (replaces the rolling N-bar reclaim level)
   bool              turnCandleFound;    // a qualifying closed M1 turn candle is frozen
   datetime          turnCandleTime;     // open time of the turn candle
   double            turnCandleOpen;
   double            turnCandleHigh;
   double            turnCandleLow;
   double            turnCandleClose;
   double            frozenTrigger;      // turnCandleHigh (BUY) / turnCandleLow (SELL); frozen, never rolling
  };

struct SPositionTrack
  {
   ulong             ticket;
   long              positionId;
   long              setupId;
   ENUM_TRADE_DIR    direction;
   double            entryPrice;
   double            initialSL;
   double            atrAtEntry;
   bool              breakEvenActive;
   bool              trailingActive;
   datetime          openTime;
   datetime          lastRejectTime;     // broker-reject backoff for SLTP modifies
   double            lastRequestedSL;    // duplicate-modify guard
  };

struct SStats
  {
   // M5 regime transitions
   long              regimeBullTransitions;
   long              regimeBearTransitions;
   long              regimeNeutralTransitions;
   // setups
   long              setupsArmed;
   long              setupsBuy;
   long              setupsSell;
   long              setupsExpired;
   long              setupsCancelledRegime;
   long              reclaimCrossings;      // V1.02: counts the final fresh FROZEN-trigger break (legacy name kept)
   long              turnCandlesFound;      // V1.02: qualifying closed turn candles
   long              turnCandlesBuy;        // V1.02: bullish turn candles (BUY setups)
   long              turnCandlesSell;       // V1.02: bearish turn candles (SELL setups)
   long              turnCandlesInvalidated;// V1.02: turn candles invalidated before their trigger broke
   long              frozenTriggerCrossings;// V1.02: fresh live breaks of the frozen trigger (same event as reclaimCrossings)
   // entry pipeline
   long              entryAttempts;
   long              entryExecutions;
   long              entryBlocks;
   long              spreadBlocks;
   long              volBlocks;
   long              sessionBlocks;
   long              posLimitBlocks;
   long              invalidStopBlocks;
   long              riskTooTightBlocks;   // V1.01: initial risk below MinInitialRiskATR
   long              riskTooWideBlocks;    // V1.01: initial risk above MaxInitialRiskATR
   long              marginBlocks;
   long              otherBlocks;
   long              brokerExecFails;
   // trades
   long              tradesTotal;
   long              tradesBuy;
   long              tradesSell;
   long              wins;
   long              losses;
   double            grossProfit;
   double            grossLoss;
   double            netPL;
   double            largestWin;
   double            largestLoss;
   // management
   long              beActivations;
   long              trailActivations;
   // holding time
   double            holdSecondsTotal;
   long              holdCount;
   // equity
   double            maxDDPercent;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
const string PANEL_PREFIX = "XM51V1_";

int      g_atrHandle        = INVALID_HANDLE; // single M1 ATR handle, never recreated
double   g_atrPrev          = 0.0;            // completed M1 ATR (shift 1)
double   g_atrAvg           = 0.0;            // volatility average cache

double   g_pullbackRefHigh  = 0.0;            // cached M1 reference high (completed bars)
double   g_pullbackRefLow   = 0.0;            // cached M1 reference low (completed bars)

datetime g_lastM5BarTime    = 0;
datetime g_lastM1BarTime    = 0;
datetime g_lastM5Candidate  = 0;              // last evaluated pivot candidate bar time (repaint guard)

SM5Structure g_m5;
SSetup       g_setup;
SStats       g_stats;

SPositionTrack g_tracks[];

long     g_setupIdCounter    = 0;
datetime g_lastSetupEndBuy   = 0;
datetime g_lastSetupEndSell  = 0;

double   g_prevBid           = 0.0;            // previous live price state (fresh-cross protection)
double   g_prevAsk           = 0.0;

bool     g_InitComplete      = false;
bool     g_warmingUp         = false;

double   g_entryVolume       = 0.0;            // resolved during permission check
double   g_entrySL           = 0.0;
double   g_entryRiskDistance = 0.0;            // V1.01: final entry->SL distance of the evaluated episode
double   g_entryRiskATR      = 0.0;            // V1.01: same distance in completed-M1-ATR units
string   g_stopBlockReason   = "";

string   g_lastAction        = "-";
string   g_lastManagement    = "INITIAL SL";
uint     g_lastPanelMs       = 0;
double   g_peakEquity        = 0.0;

#define CLOSED_ID_CACHE_SIZE 256
ulong    g_closedIds[CLOSED_ID_CACHE_SIZE];
int      g_closedIdIndex     = 0;

//+------------------------------------------------------------------+
//| Small utilities                                                  |
//+------------------------------------------------------------------+
bool DebugM5Enabled()   { return (DebugMode || DebugM5);   }
bool DebugM1Enabled()   { return (DebugMode || DebugM1);   }
bool DebugTradeEnabled(){ return (DebugMode || DebugTrade); }

void LogM5(const string msg)
  {
   if(DebugM5Enabled()) Print("[M5] ", msg);
  }

void LogM1(const string msg)
  {
   if(DebugM1Enabled()) Print("[M1] ", msg);
  }

void LogTrade(const string msg)
  {
   if(DebugTradeEnabled()) Print("[TRADE] ", msg);
  }

string RegimeToString(const ENUM_REGIME regime)
  {
   switch(regime)
     {
      case REGIME_BULLISH: return "BULLISH";
      case REGIME_BEARISH: return "BEARISH";
      default:             return "NEUTRAL";
     }
  }

string DirLabel(const ENUM_TRADE_DIR dir)
  {
   switch(dir)
     {
      case DIR_BUY:  return "BUY";
      case DIR_SELL: return "SELL";
      default:       return "-";
     }
  }

// Human description of current two-pivot structure (HH/LH/EQ + HL/LL/EQ)
string StructureDescription()
  {
   if(g_m5.confirmedHighs < 2 || g_m5.confirmedLows < 2)
      return "insufficient structure";
   bool hh = (g_m5.latestSwingHigh > g_m5.previousSwingHigh);
   bool lh = (g_m5.latestSwingHigh < g_m5.previousSwingHigh);
   bool hl = (g_m5.latestSwingLow  > g_m5.previousSwingLow);
   bool ll = (g_m5.latestSwingLow  < g_m5.previousSwingLow);
   string hp = (hh ? "HH" : (lh ? "LH" : "EQ"));
   string lp = (hl ? "HL" : (ll ? "LL" : "EQ"));
   return (hp + " + " + lp);
  }

string FormatDuration(const long seconds)
  {
   long s = seconds;
   if(s < 0) s = 0;
   long h = s / 3600;
   long m = (s % 3600) / 60;
   long sec = s % 60;
   if(h > 0)
      return StringFormat("%02d:%02d:%02d", (int)h, (int)m, (int)sec);
   return StringFormat("%02d:%02d", (int)m, (int)sec);
  }

void SetLastAction(const string text)
  {
   g_lastAction = text + "  @ " + TimeToString(TimeCurrent(), TIME_MINUTES);
  }

//+------------------------------------------------------------------+
//| Price / volume normalization (tick-size aware)                   |
//+------------------------------------------------------------------+
double TickSizeSafe()
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = _Point;
   return tick;
  }

double NormalizePriceToTick(const double price)
  {
   double tick = TickSizeSafe();
   if(tick <= 0.0) tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

double NormalizeVolume(const double requestedVolume)
  {
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minVol <= 0.0 || maxVol <= 0.0 || step <= 0.0)
      return 0.0;
   double vol = MathRound(requestedVolume / step) * step;
   if(vol < minVol) vol = minVol;
   if(vol > maxVol) vol = maxVol;
   vol = MathRound(vol / step) * step;
   if(vol < minVol - step * 0.01 || vol > maxVol + step * 0.01)
      return 0.0;
   return NormalizeDouble(vol, 8);
  }

// Broker minimum stop distance (stops level vs freeze level, at least one tick)
double BrokerMinStopDistance()
  {
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long frz   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long pts   = (stops > frz ? stops : frz);
   double dist = (double)pts * _Point;
   double tick = TickSizeSafe();
   if(dist < tick) dist = tick;
   return dist;
  }

//+------------------------------------------------------------------+
//| Filters: session / spread / volatility / permissions             |
//+------------------------------------------------------------------+
bool IsSessionOpen()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(EffTradingStartHour < EffTradingEndHour)
      return (h >= EffTradingStartHour && h < EffTradingEndHour);
   if(EffTradingStartHour > EffTradingEndHour)
      return (h >= EffTradingStartHour || h < EffTradingEndHour);
   return true; // start == end -> 24h permission
  }

double CurrentSpreadPoints(const MqlTick &tick)
  {
   if(_Point <= 0.0) return 0.0;
   return (tick.ask - tick.bid) / _Point;
  }

bool IsVolatilityOK()
  {
   if(g_atrPrev <= 0.0) return true; // cannot evaluate (arming already required ATR)
   if(g_atrAvg  <= 0.0) return true; // average cache not built yet
   return (g_atrPrev <= g_atrAvg * EffVolatilitySpikeLimit);
  }

bool IsSymbolTradeAllowed(const ENUM_TRADE_DIR dir)
  {
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_FULL)   return true;
   if(mode == SYMBOL_TRADE_MODE_LONGONLY  && dir == DIR_BUY)  return true;
   if(mode == SYMBOL_TRADE_MODE_SHORTONLY && dir == DIR_SELL) return true;
   return false;
  }

bool TerminalTradingAllowed()
  {
   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0) return false;
   if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)           return false;
   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)   return false;
   if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)    return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Position counting / tracks (symbol + magic only)                 |
//+------------------------------------------------------------------+
int CountEAPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      count++;
     }
   return count;
  }

bool HasTrack(const ulong ticket)
  {
   for(int i = ArraySize(g_tracks) - 1; i >= 0; i--)
      if(g_tracks[i].ticket == ticket)
         return true;
   return false;
  }

void RemoveTrack(const int index)
  {
   int n = ArraySize(g_tracks);
   if(index < 0 || index >= n) return;
   for(int i = index; i < n - 1; i++)
      g_tracks[i] = g_tracks[i + 1];
   ArrayResize(g_tracks, n - 1);
  }

// Appends a track for the currently selected position.
void AddTrackFromSelectedPosition(const ulong ticket, const ENUM_TRADE_DIR dirHint)
  {
   if(!PositionSelectByTicket(ticket)) return;
   if(HasTrack(ticket)) return;

   SPositionTrack tr;
   ZeroMemory(tr);
   tr.ticket      = ticket;
   tr.positionId  = (long)PositionGetInteger(POSITION_IDENTIFIER);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   tr.direction   = (ptype == POSITION_TYPE_BUY) ? DIR_BUY : DIR_SELL;
   if(dirHint != DIR_NONE) tr.direction = dirHint;
   tr.entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   tr.initialSL   = PositionGetDouble(POSITION_SL);
   tr.openTime    = (datetime)PositionGetInteger(POSITION_TIME);
   tr.atrAtEntry  = (g_atrPrev > 0.0 ? g_atrPrev
                     : (g_setup.active ? g_setup.atrAtSetup : 0.0)); // restart adoption fallback
   tr.setupId     = (g_setup.active ? g_setup.setupId : 0);

   // comment carries setup id for traceability / restart adoption
   string cm = PositionGetString(POSITION_COMMENT);
   int hash = StringFind(cm, "#");
   if(hash >= 0)
     {
      long parsed = StringToInteger(StringSubstr(cm, hash + 1));
      if(parsed > 0) tr.setupId = parsed;
     }

   int n = ArraySize(g_tracks);
   ArrayResize(g_tracks, n + 1);
   g_tracks[n] = tr;
  }

// Safety net: adopt our untracked positions (restart / netting merge).
void ReconcileTracks()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(HasTrack(tk)) continue;
      AddTrackFromSelectedPosition(tk, DIR_NONE);
      PrintFormat("[TRACK] Adopted existing position #%I64u (restart/recovery); ATR@entry approximated with current completed ATR", tk);
     }
  }

bool IsPositionOpen(const long positionId)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if((long)PositionGetInteger(POSITION_IDENTIFIER) == positionId)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Closed-position id cache (prevents double counting)              |
//+------------------------------------------------------------------+
bool IsClosedPositionProcessed(const long positionId)
  {
   if(positionId <= 0) return false;
   ulong id = (ulong)positionId;
   for(int i = 0; i < CLOSED_ID_CACHE_SIZE; i++)
      if(g_closedIds[i] == id)
         return true;
   return false;
  }

void MarkClosedPositionProcessed(const long positionId)
  {
   if(positionId <= 0) return;
   g_closedIds[g_closedIdIndex] = (ulong)positionId;
   g_closedIdIndex = (g_closedIdIndex + 1) % CLOSED_ID_CACHE_SIZE;
  }

//+------------------------------------------------------------------+
//| ATR (single M1 handle; cached completed values)                  |
//+------------------------------------------------------------------+
double GetATR()
  {
   return g_atrPrev; // completed M1 ATR (shift 1)
  }

void RefreshM1AtrCache()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1 && buf[0] > 0.0)
      g_atrPrev = buf[0];
   // on transient copy failure keep the previous cached value
  }

void RefreshVolatilityAverage()
  {
   if(EffVolatilityLookback <= 0)
     {
      g_atrAvg = g_atrPrev;
      return;
     }
   double buf[];
   ArraySetAsSeries(buf, true);
   int need = EffVolatilityLookback;
   int got  = CopyBuffer(g_atrHandle, 0, 2, need, buf); // shifts 2..need+1 (previous completed bars)
   if(got == need)
     {
      double sum = 0.0;
      for(int i = 0; i < got; i++)
         sum += buf[i];
      g_atrAvg = sum / (double)got;
     }
   else
      g_atrAvg = 0.0; // unavailable this cycle; filter stays permissive
  }

//+------------------------------------------------------------------+
//| M1 references (completed candles only, forming bar excluded)     |
//+------------------------------------------------------------------+
double GetM1ReferenceHigh()
  {
   int idx = iHighest(_Symbol, PERIOD_M1, MODE_HIGH, EffPullbackReferenceBars, 1);
   if(idx < 1) return 0.0;
   double v = iHigh(_Symbol, PERIOD_M1, idx);
   return (v > 0.0 ? v : 0.0);
  }

double GetM1ReferenceLow()
  {
   int idx = iLowest(_Symbol, PERIOD_M1, MODE_LOW, EffPullbackReferenceBars, 1);
   if(idx < 1) return 0.0;
   double v = iLow(_Symbol, PERIOD_M1, idx);
   return (v > 0.0 ? v : 0.0);
  }

// V1.02: GetBuyReclaimLevel() / GetSellReclaimLevel() / RefreshReclaimLevel()
// (rolling ReclaimLookbackBars highest-high / lowest-low trigger) were REMOVED.
// The only trigger in V1.02 is: closed turn candle -> frozen high/low -> fresh
// live break. ReclaimLookbackBars has zero effect on trading decisions.

void RefreshPullbackReferences()
  {
   g_pullbackRefHigh = GetM1ReferenceHigh();
   g_pullbackRefLow  = GetM1ReferenceLow();
  }

//+------------------------------------------------------------------+
//| M5 engine: causal confirmed pivots, structure, regime            |
//+------------------------------------------------------------------+
void PushSwingHigh(const double price, const datetime t)
  {
   g_m5.previousSwingHigh     = g_m5.latestSwingHigh;
   g_m5.previousSwingHighTime = g_m5.latestSwingHighTime;
   g_m5.latestSwingHigh       = price;
   g_m5.latestSwingHighTime   = t;
   if(g_m5.confirmedHighs < 2) g_m5.confirmedHighs++;
   if(!g_warmingUp)
      LogM5(StringFormat("Pivot HIGH confirmed %s @ %s", DoubleToString(price, _Digits),
                         TimeToString(t, TIME_DATE | TIME_MINUTES)));
  }

void PushSwingLow(const double price, const datetime t)
  {
   g_m5.previousSwingLow     = g_m5.latestSwingLow;
   g_m5.previousSwingLowTime = g_m5.latestSwingLowTime;
   g_m5.latestSwingLow       = price;
   g_m5.latestSwingLowTime   = t;
   if(g_m5.confirmedLows < 2) g_m5.confirmedLows++;
   if(!g_warmingUp)
      LogM5(StringFormat("Pivot LOW confirmed %s @ %s", DoubleToString(price, _Digits),
                         TimeToString(t, TIME_DATE | TIME_MINUTES)));
  }

// Confirms the completed candidate bar at `shift` (strict dominance required;
// equal highs invalidate a swing high, equal lows invalidate a swing low).
// The forming bar (shift 0) is never part of the confirmation window.
// A candidate is evaluated exactly once (time guard => no repaint, no look-ahead).
void ConfirmPivotAtShift(const int shift)
  {
   if(shift < EffM5PivotSize + 1) return;
   datetime ct = iTime(_Symbol, PERIOD_M5, shift);
   if(ct <= 0) return;
   if(ct <= g_lastM5Candidate) return; // already processed

   double h = iHigh(_Symbol, PERIOD_M5, shift);
   double l = iLow(_Symbol, PERIOD_M5, shift);
   if(h <= 0.0 || l <= 0.0) return;    // data not ready yet: retry later

   bool isHigh = true;
   bool isLow  = true;
   for(int k = 1; k <= EffM5PivotSize && (isHigh || isLow); k++)
     {
      double rh = iHigh(_Symbol, PERIOD_M5, shift - k); // right side = more recent (completed)
      double lh = iHigh(_Symbol, PERIOD_M5, shift + k); // left side = older
      double rl = iLow(_Symbol, PERIOD_M5, shift - k);
      double ll = iLow(_Symbol, PERIOD_M5, shift + k);
      if(rh <= 0.0 || lh <= 0.0 || rl <= 0.0 || ll <= 0.0)
         return; // data missing: do not mark as processed
      if(isHigh && !(h > rh && h > lh)) isHigh = false;
      if(isLow  && !(l < rl && l < ll)) isLow  = false;
     }

   g_lastM5Candidate = ct; // candidate evaluated once and forever
   if(isHigh) PushSwingHigh(h, ct);
   if(isLow)  PushSwingLow(l, ct);
  }

void WarmupM5Structure()
  {
   int total = Bars(_Symbol, PERIOD_M5);
   int maxCandidateShift = total - 2;
   int depthLimit = EffM5PivotSize + 1200;
   if(maxCandidateShift > depthLimit) maxCandidateShift = depthLimit;
   if(maxCandidateShift < EffM5PivotSize + 1) return;
   // oldest -> newest so latest/previous ordering is correct (fully causal)
   for(int s = maxCandidateShift; s >= EffM5PivotSize + 1; s--)
      ConfirmPivotAtShift(s);
  }

// Called on a new M5 bar only. Re-attempts the last few candidates (gap safe);
// the internal time guard makes repeated confirmations impossible.
void UpdateM5Structure()
  {
   for(int s = EffM5PivotSize + 8; s >= EffM5PivotSize + 1; s--)
      ConfirmPivotAtShift(s);
  }

// Pure current-structure classification. No persistence: mixed structure
// (HH+LL, LH+HL, equalities) is NEUTRAL. Insufficient pivots -> NEUTRAL.
void UpdateM5Regime()
  {
   ENUM_REGIME next = REGIME_NEUTRAL;
   if(g_m5.confirmedHighs >= 2 && g_m5.confirmedLows >= 2)
     {
      bool hh = (g_m5.latestSwingHigh > g_m5.previousSwingHigh);
      bool hl = (g_m5.latestSwingLow  > g_m5.previousSwingLow);
      bool lh = (g_m5.latestSwingHigh < g_m5.previousSwingHigh);
      bool ll = (g_m5.latestSwingLow  < g_m5.previousSwingLow);
      if(hh && hl)      next = REGIME_BULLISH;
      else if(lh && ll) next = REGIME_BEARISH;
      else              next = REGIME_NEUTRAL;
     }
   if(next != g_m5.regime)
     {
      g_m5.regime = next;
      if(next == REGIME_BULLISH)      g_stats.regimeBullTransitions++;
      else if(next == REGIME_BEARISH) g_stats.regimeBearTransitions++;
      else                            g_stats.regimeNeutralTransitions++;
      if(!g_warmingUp)
         Print("[M5] Regime -> ", RegimeToString(next), " (", StructureDescription(), ")");
     }
  }

// Pending setup must die immediately when M5 permission disappears.
// Open positions are NOT touched here (they keep their own SL/BE/trail logic).
void CancelSetupOnRegimeLoss()
  {
   if(!g_setup.active || g_setup.state != WAIT_RECLAIM) return;
   bool incompatible = (g_setup.direction == DIR_BUY  && g_m5.regime != REGIME_BULLISH) ||
                       (g_setup.direction == DIR_SELL && g_m5.regime != REGIME_BEARISH);
   if(!incompatible) return;
   g_stats.setupsCancelledRegime++;
   if(g_setup.direction == DIR_BUY)  g_lastSetupEndBuy  = TimeCurrent();
   if(g_setup.direction == DIR_SELL) g_lastSetupEndSell = TimeCurrent();
   PrintFormat("[M1] %s setup #%I64d cancelled: M5 no longer %s",
               DirLabel(g_setup.direction), g_setup.setupId,
               (g_setup.direction == DIR_BUY ? "bullish" : "bearish"));
   SetLastAction("Setup cancelled (M5 regime loss)");
   ResetSetup();
  }

//+------------------------------------------------------------------+
//| Setup state machine                                              |
//+------------------------------------------------------------------+
void ResetSetup()
  {
   g_setup.active              = false;
   g_setup.state               = WAIT_PULLBACK;
   g_setup.direction           = DIR_NONE;
   g_setup.setupStartTime      = 0;
   g_setup.pullbackQualifiedTime = 0;
   g_setup.referenceExtreme    = 0.0;
   g_setup.pullbackExtreme     = 0.0;
   g_setup.atrAtSetup          = 0.0;
   g_setup.crossArmed          = false;
   g_setup.setupId             = 0;
   // V1.02 turn-candle trigger state: no stale trigger may survive a setup
   g_setup.turnCandleFound     = false;
   g_setup.turnCandleTime      = 0;
   g_setup.turnCandleOpen      = 0.0;
   g_setup.turnCandleHigh      = 0.0;
   g_setup.turnCandleLow       = 0.0;
   g_setup.turnCandleClose     = 0.0;
   g_setup.frozenTrigger       = 0.0;
  }

// V1.02: discard ONLY the turn-candle trigger state. The pullback setup
// itself stays alive (no cooldown, no new setupId, expiry timer untouched);
// pullbackExtreme tracking continues and a NEW turn candle is awaited.
void InvalidateTurnCandle()
  {
   g_setup.turnCandleFound     = false;
   g_setup.turnCandleTime      = 0;
   g_setup.turnCandleOpen      = 0.0;
   g_setup.turnCandleHigh      = 0.0;
   g_setup.turnCandleLow       = 0.0;
   g_setup.turnCandleClose     = 0.0;
   g_setup.frozenTrigger       = 0.0;
   g_setup.crossArmed          = false;
  }

void SetLastSetupEnd(const ENUM_TRADE_DIR dir, const datetime t)
  {
   if(dir == DIR_BUY)       g_lastSetupEndBuy  = t;
   else if(dir == DIR_SELL) g_lastSetupEndSell = t;
  }

bool CooldownElapsed(const ENUM_TRADE_DIR dir)
  {
   datetime lastEnd = (dir == DIR_BUY ? g_lastSetupEndBuy : g_lastSetupEndSell);
   if(lastEnd == 0) return true;
   return ((long)(TimeCurrent() - lastEnd) >= (long)EffReentryCooldownMinutes * 60);
  }

// Arms a WAIT_RECLAIM setup after a qualified pullback.
// V1.02: NO breakout trigger exists yet — the setup must first receive a
// qualifying CLOSED turn candle (never retroactively selected).
bool ArmSetup(const ENUM_TRADE_DIR dir, const MqlTick &tick)
  {
   if(g_atrPrev <= 0.0) return false; // ATR mandatory before any setup
   double refExtreme = (dir == DIR_BUY) ? g_pullbackRefHigh : g_pullbackRefLow;
   if(refExtreme <= 0.0) return false;

   g_setup.active                = true;
   g_setup.state                 = WAIT_RECLAIM;
   g_setup.direction             = dir;
   g_setup.setupStartTime        = TimeCurrent();
   g_setup.pullbackQualifiedTime = TimeCurrent();
   g_setup.referenceExtreme      = refExtreme;
   g_setup.pullbackExtreme       = (dir == DIR_BUY) ? tick.bid : tick.ask;
   g_setup.atrAtSetup            = g_atrPrev;
   g_setup.turnCandleFound       = false;
   g_setup.turnCandleTime        = 0;
   g_setup.turnCandleOpen        = 0.0;
   g_setup.turnCandleHigh        = 0.0;
   g_setup.turnCandleLow         = 0.0;
   g_setup.turnCandleClose       = 0.0;
   g_setup.frozenTrigger         = 0.0;
   g_setup.crossArmed            = false;
   g_setupIdCounter++;
   g_setup.setupId               = g_setupIdCounter;

   g_stats.setupsArmed++;
   if(dir == DIR_BUY) g_stats.setupsBuy++; else g_stats.setupsSell++;

   if(dir == DIR_BUY)
     {
      double dist = refExtreme - tick.bid;
      double req  = g_atrPrev * EffPullbackATRMin;
      PrintFormat("[M1] BUY pullback qualified (#%I64d)  ReferenceHigh=%s  CurrentBid=%s  Distance=%s  ATR=%s  Required=%s",
                  g_setup.setupId, DoubleToString(refExtreme, _Digits), DoubleToString(tick.bid, _Digits),
                  DoubleToString(dist, 2), DoubleToString(g_atrPrev, 2), DoubleToString(req, 2));
     }
   else
     {
      double dist = tick.ask - refExtreme;
      double req  = g_atrPrev * EffPullbackATRMin;
      PrintFormat("[M1] SELL pullback qualified (#%I64d)  ReferenceLow=%s  CurrentAsk=%s  Distance=%s  ATR=%s  Required=%s",
                  g_setup.setupId, DoubleToString(refExtreme, _Digits), DoubleToString(tick.ask, _Digits),
                  DoubleToString(dist, 2), DoubleToString(g_atrPrev, 2), DoubleToString(req, 2));
     }
   SetLastAction(StringFormat("%s setup armed #%I64d", DirLabel(dir), g_setup.setupId));
   return true;
  }

// WAIT_PULLBACK scanning: live retreat from the cached completed-bar extreme.
void TryArmPullbackSetup(const MqlTick &tick)
  {
   if(g_setup.active) return;
   if(g_atrPrev <= 0.0) return;

   if(g_m5.regime == REGIME_BULLISH && g_pullbackRefHigh > 0.0)
     {
      double req  = g_atrPrev * EffPullbackATRMin;
      double dist = g_pullbackRefHigh - tick.bid; // Bid measures the retreat
      if(dist >= req && CooldownElapsed(DIR_BUY))
         ArmSetup(DIR_BUY, tick);
     }
   else if(g_m5.regime == REGIME_BEARISH && g_pullbackRefLow > 0.0)
     {
      double req  = g_atrPrev * EffPullbackATRMin;
      double dist = tick.ask - g_pullbackRefLow;  // Ask measures the bounce
      if(dist >= req && CooldownElapsed(DIR_SELL))
         ArmSetup(DIR_SELL, tick);
     }
  }

// V1.02 turn-candle detection: runs ONLY on the new-M1-bar event (never per
// tick). Inspects exactly the just-completed shift-1 candle, causally:
// the candle is eligible only if it CLOSED after pullbackQualifiedTime
// (its close time equals the open time of the new shift-0 bar). No
// historical replay, no backwards scanning.
// BUY  setup: first closed candle with Close > Open qualifies (doji ignored).
// SELL setup: first closed candle with Close < Open qualifies (doji ignored).
void TryDetectTurnCandle(const MqlTick &tick)
  {
   if(!g_setup.active || g_setup.state != WAIT_RECLAIM) return;
   if(g_setup.turnCandleFound) return; // a frozen trigger already exists

   datetime closeTime = iTime(_Symbol, PERIOD_M1, 0); // close time of shift-1 candle
   if(closeTime <= g_setup.pullbackQualifiedTime) return; // closed before qualification: never eligible

   double o = iOpen(_Symbol, PERIOD_M1, 1);
   double h = iHigh(_Symbol, PERIOD_M1, 1);
   double l = iLow(_Symbol, PERIOD_M1, 1);
   double c = iClose(_Symbol, PERIOD_M1, 1);
   if(o <= 0.0 || h <= 0.0 || l <= 0.0 || c <= 0.0) return; // data not ready

   if(o == c)
     {
      LogM1(StringFormat("%s setup #%I64d: shift-1 candle is a doji (O=%s C=%s), continue waiting",
                         DirLabel(g_setup.direction), g_setup.setupId,
                         DoubleToString(o, _Digits), DoubleToString(c, _Digits)));
      return; // doji never qualifies
     }
   bool qualifies = (g_setup.direction == DIR_BUY) ? (c > o) : (c < o);
   if(!qualifies)
     {
      LogM1(StringFormat("%s setup #%I64d: shift-1 candle not a qualifying turn candle (O=%s C=%s), continue waiting",
                         DirLabel(g_setup.direction), g_setup.setupId,
                         DoubleToString(o, _Digits), DoubleToString(c, _Digits)));
      return;
     }

   // freeze the turn candle and its trigger (BUY: high, SELL: low)
   g_setup.turnCandleFound = true;
   g_setup.turnCandleTime  = iTime(_Symbol, PERIOD_M1, 1);
   g_setup.turnCandleOpen  = o;
   g_setup.turnCandleHigh  = h;
   g_setup.turnCandleLow   = l;
   g_setup.turnCandleClose = c;
   g_setup.frozenTrigger   = (g_setup.direction == DIR_BUY) ? h : l;
   // fresh-cross safety: if price is already beyond the trigger the cross is
   // consumed; require a return to the non-breakout side before arming
   g_setup.crossArmed = (g_setup.direction == DIR_BUY) ? (tick.ask <= g_setup.frozenTrigger)
                                                       : (tick.bid >= g_setup.frozenTrigger);

   g_stats.turnCandlesFound++;
   if(g_setup.direction == DIR_BUY) g_stats.turnCandlesBuy++; else g_stats.turnCandlesSell++;

   PrintFormat("[M1] %s turn candle confirmed (#%I64d)  Time=%s  O=%s  H=%s  L=%s  C=%s  Trigger=%s  (crossArmed=%s)",
               DirLabel(g_setup.direction), g_setup.setupId,
               TimeToString(g_setup.turnCandleTime, TIME_DATE | TIME_MINUTES),
               DoubleToString(o, _Digits), DoubleToString(h, _Digits),
               DoubleToString(l, _Digits), DoubleToString(c, _Digits),
               DoubleToString(g_setup.frozenTrigger, _Digits),
               (g_setup.crossArmed ? "true" : "false"));
   SetLastAction(StringFormat("%s turn candle frozen #%I64d", DirLabel(g_setup.direction), g_setup.setupId));
  }

// WAIT_RECLAIM processing: expiry, monotonic pullback extreme, V1.02
// turn-candle invalidation, then fresh live break of the FROZEN trigger.
void ProcessLiveSetup(const MqlTick &tick)
  {
   if(!g_setup.active)
     {
      TryArmPullbackSetup(tick);
      return;
     }
   if(g_setup.state != WAIT_RECLAIM) return;

   // --- expiry (timer starts at pullback qualification)
   if((long)(TimeCurrent() - g_setup.setupStartTime) > (long)EffSetupExpiryMinutes * 60)
     {
      g_stats.setupsExpired++;
      PrintFormat("[M1] %s setup #%I64d expired after %d min",
                  DirLabel(g_setup.direction), g_setup.setupId, EffSetupExpiryMinutes);
      SetLastSetupEnd(g_setup.direction, TimeCurrent());
      SetLastAction("Setup expired");
      ResetSetup();
      return;
     }

   // --- pullback extreme tracking (may only extend against the trade direction)
   if(g_setup.direction == DIR_BUY)
     {
      if(tick.bid < g_setup.pullbackExtreme) g_setup.pullbackExtreme = tick.bid;
     }
   else
     {
      if(tick.ask > g_setup.pullbackExtreme) g_setup.pullbackExtreme = tick.ask;
     }

   // --- V1.02: no trigger exists until a turn candle is frozen
   if(!g_setup.turnCandleFound)
      return;

   // --- turn-candle invalidation (PRIORITY over breakout execution).
   // Strict comparison: equality alone does not invalidate; no ATR buffer.
   // BUY:  live Bid trading BELOW the turn candle low fails the turn candle.
   // SELL: live Ask trading ABOVE the turn candle high fails the turn candle.
   // Only the turn state is cleared: the pullback setup survives (no cooldown,
   // no new setupId, expiry timer untouched); pullbackExtreme keeps updating.
   if(g_setup.direction == DIR_BUY)
     {
      if(tick.bid < g_setup.turnCandleLow)
        {
         g_stats.turnCandlesInvalidated++;
         PrintFormat("[M1] BUY turn candle #%I64d invalidated: Bid below turn low", g_setup.setupId);
         PrintFormat("[M1] BUY waiting for new bullish turn candle");
         InvalidateTurnCandle();
         return;
        }
     }
   else
     {
      if(tick.ask > g_setup.turnCandleHigh)
        {
         g_stats.turnCandlesInvalidated++;
         PrintFormat("[M1] SELL turn candle #%I64d invalidated: Ask above turn high", g_setup.setupId);
         PrintFormat("[M1] SELL waiting for new bearish turn candle");
         InvalidateTurnCandle();
         return;
        }
     }

   // --- fresh live breakout of the FROZEN trigger (BUY=Ask, SELL=Bid).
   // The frozen level never moves: no rolling recalculation exists anymore.
   bool crossed = false;
   if(g_setup.direction == DIR_BUY)
     {
      if(tick.ask <= g_setup.frozenTrigger)
         g_setup.crossArmed = true;                 // price on the non-breakout side
      else if(g_setup.crossArmed)
         crossed = true;                            // genuine fresh up-break
     }
   else
     {
      if(tick.bid >= g_setup.frozenTrigger)
         g_setup.crossArmed = true;
      else if(g_setup.crossArmed)
         crossed = true;                            // genuine fresh down-break
     }

   if(crossed)
     {
      g_setup.crossArmed = false;      // episode consumed immediately
      g_stats.reclaimCrossings++;       // legacy counter (V1.02: frozen trigger break)
      g_stats.frozenTriggerCrossings++;// V1.02 explicit counter, same single event
      AttemptEntry(tick);
     }
  }

//+------------------------------------------------------------------+
//| Entry permission pipeline                                        |
//+------------------------------------------------------------------+
string EntryBlockReason(const ENUM_ENTRY_BLOCK block)
  {
   switch(block)
     {
      case ENTRY_BLOCK_INIT:       return "initialization incomplete";
      case ENTRY_BLOCK_ACTIVE:     return "setup no longer active";
      case ENTRY_BLOCK_REGIME:     return "M5 regime no longer matches setup direction";
      case ENTRY_BLOCK_EXPIRED:    return "setup expired";
      case ENTRY_BLOCK_POS_LIMIT:  return "max open trades reached";
      case ENTRY_BLOCK_SESSION:    return "outside trading session";
      case ENTRY_BLOCK_SPREAD:     return "spread above limit";
      case ENTRY_BLOCK_VOLATILITY: return "volatility spike";
      case ENTRY_BLOCK_SYMBOL:     return "symbol trading not permitted";
      case ENTRY_BLOCK_TERMINAL:   return "terminal/autotrading disabled";
      case ENTRY_BLOCK_VOLUME:     return "lot size cannot produce valid tradable volume";
      case ENTRY_BLOCK_MARGIN:     return "insufficient margin";
      case ENTRY_BLOCK_STOPS:      return (g_stopBlockReason != "" ? g_stopBlockReason : "protective stop invalid");
      case ENTRY_BLOCK_RISK_TOO_TIGHT: return "initial risk below MinInitialRiskATR";
      case ENTRY_BLOCK_RISK_TOO_WIDE:  return "initial risk above MaxInitialRiskATR";
      case ENTRY_BLOCK_FILLING:    return "no supported filling mode";
      default:                     return "ok";
     }
  }

void CountBlock(const ENUM_ENTRY_BLOCK block)
  {
   switch(block)
     {
      case ENTRY_BLOCK_SPREAD:     g_stats.spreadBlocks++;      break;
      case ENTRY_BLOCK_VOLATILITY: g_stats.volBlocks++;         break;
      case ENTRY_BLOCK_SESSION:    g_stats.sessionBlocks++;     break;
      case ENTRY_BLOCK_POS_LIMIT:  g_stats.posLimitBlocks++;    break;
      case ENTRY_BLOCK_STOPS:      g_stats.invalidStopBlocks++; break;
      case ENTRY_BLOCK_RISK_TOO_TIGHT: g_stats.riskTooTightBlocks++; break;
      case ENTRY_BLOCK_RISK_TOO_WIDE:  g_stats.riskTooWideBlocks++;  break;
      case ENTRY_BLOCK_MARGIN:     g_stats.marginBlocks++;      break;
      default:                     g_stats.otherBlocks++;       break;
     }
  }

// Initial protective stop: structural pullback extreme +/- ATR buffer.
// Returns false if no legally placeable stop exists that preserves the idea.
bool BuildInitialStop(const ENUM_TRADE_DIR dir, const MqlTick &tick,
                      const double atrEntry, const double pullbackExtreme,
                      double &slOut, string &reason)
  {
   slOut  = 0.0;
   reason = "";
   if(atrEntry <= 0.0)
     {
      reason = "ATR unavailable for stop construction";
      return false;
     }
   double stopsDist = BrokerMinStopDistance();
   double buffer    = atrEntry * EffInitialStopATRBuffer;
   double tickSize  = TickSizeSafe();

   if(dir == DIR_BUY)
     {
      if(pullbackExtreme <= 0.0 || pullbackExtreme >= tick.bid)
        {
         reason = "structural pullback low is not below market";
         return false;
        }
      double raw       = NormalizePriceToTick(pullbackExtreme - buffer);
      double maxAllowed = NormalizePriceToTick(tick.bid - stopsDist);
      if(raw >= tick.bid)
        {
         reason = "structural SL not below market";
         return false;
        }
      if(raw > maxAllowed)
        {
         // broker forces the stop further away than the structural level;
         // tolerate up to the size of the ATR buffer, otherwise block
         double forcedExtra = raw - maxAllowed;
         if(forcedExtra > buffer + tickSize * 0.5)
           {
            reason = "protective stop incompatible with broker minimum distance";
            return false;
           }
         LogTrade(StringFormat("Initial SL adjusted to broker minimum: %s -> %s",
                               DoubleToString(raw, _Digits), DoubleToString(maxAllowed, _Digits)));
         raw = maxAllowed;
        }
      slOut = raw;
     }
   else
     {
      if(pullbackExtreme <= 0.0 || pullbackExtreme <= tick.ask)
        {
         reason = "structural pullback high is not above market";
         return false;
        }
      double raw       = NormalizePriceToTick(pullbackExtreme + buffer);
      double minAllowed = NormalizePriceToTick(tick.ask + stopsDist);
      if(raw <= tick.ask)
        {
         reason = "structural SL not above market";
         return false;
        }
      if(raw < minAllowed)
        {
         double forcedExtra = minAllowed - raw;
         if(forcedExtra > buffer + tickSize * 0.5)
           {
            reason = "protective stop incompatible with broker minimum distance";
            return false;
           }
         LogTrade(StringFormat("Initial SL adjusted to broker minimum: %s -> %s",
                               DoubleToString(raw, _Digits), DoubleToString(minAllowed, _Digits)));
         raw = minAllowed;
        }
      slOut = raw;
     }
   return (slOut > 0.0);
  }

// Filling modes supported by the symbol, most restrictive first.
int BuildFillingCandidates(ENUM_ORDER_TYPE_FILLING &modes[])
  {
   int count = 0;
   long flags = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK) != 0) { modes[count] = ORDER_FILLING_FOK; count++; }
   if((flags & SYMBOL_FILLING_IOC) != 0) { modes[count] = ORDER_FILLING_IOC; count++; }
   if(count == 0)                        { modes[count] = ORDER_FILLING_RETURN; count++; }
   return count;
  }

bool IsSuccessRetcode(const uint retcode)
  {
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_DONE_PARTIAL ||
           retcode == TRADE_RETCODE_PLACED);
  }

void LogExecutionFailure(const MqlTradeResult &res, const bool sent)
  {
   string reason;
   switch(res.retcode)
     {
      case TRADE_RETCODE_REQUOTE:            reason = "requote"; break;
      case TRADE_RETCODE_REJECT:             reason = "request rejected by broker"; break;
      case TRADE_RETCODE_CANCEL:             reason = "request cancelled"; break;
      case TRADE_RETCODE_ERROR:              reason = "request error"; break;
      case TRADE_RETCODE_TIMEOUT:            reason = "request timeout"; break;
      case TRADE_RETCODE_INVALID:            reason = "invalid request"; break;
      case TRADE_RETCODE_INVALID_VOLUME:     reason = "invalid volume"; break;
      case TRADE_RETCODE_INVALID_PRICE:      reason = "invalid price"; break;
      case TRADE_RETCODE_INVALID_STOPS:      reason = "invalid stops"; break;
      case TRADE_RETCODE_TRADE_DISABLED:     reason = "trade disabled"; break;
      case TRADE_RETCODE_MARKET_CLOSED:      reason = "market closed"; break;
      case TRADE_RETCODE_NO_MONEY:           reason = "insufficient funds"; break;
      case TRADE_RETCODE_PRICE_CHANGED:      reason = "price changed"; break;
      case TRADE_RETCODE_PRICE_OFF:          reason = "off quotes / no quotes"; break;
      case TRADE_RETCODE_INVALID_EXPIRATION: reason = "invalid expiration"; break;
      case TRADE_RETCODE_ORDER_CHANGED:      reason = "order changed"; break;
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  reason = "too many requests"; break;
      case TRADE_RETCODE_NO_CHANGES:         reason = "no changes"; break;
      case TRADE_RETCODE_SERVER_DISABLES_AT: reason = "autotrading disabled by server"; break;
      case TRADE_RETCODE_CLIENT_DISABLES_AT: reason = "autotrading disabled by terminal"; break;
      case TRADE_RETCODE_LOCKED:             reason = "request locked"; break;
      case TRADE_RETCODE_FROZEN:             reason = "order/position frozen"; break;
      case TRADE_RETCODE_INVALID_FILL:       reason = "unsupported filling mode"; break;
      case TRADE_RETCODE_CONNECTION:         reason = "no connection to trade server"; break;
      case TRADE_RETCODE_ONLY_REAL:          reason = "live accounts only"; break;
      case TRADE_RETCODE_LIMIT_ORDERS:       reason = "pending order limit reached"; break;
      case TRADE_RETCODE_LIMIT_VOLUME:       reason = "volume limit reached"; break;
      case TRADE_RETCODE_INVALID_ORDER:      reason = "invalid/prohibited order type"; break;
      case TRADE_RETCODE_POSITION_CLOSED:    reason = "position already closed"; break;
      default:                               reason = "broker-side error " + IntegerToString((int)res.retcode); break;
     }
   if(!sent)
      reason += " (OrderSend failed, last error " + IntegerToString(GetLastError()) + ")";
   Print("[TRADE] Execution FAILED: ", reason, " (retcode=", (int)res.retcode, ")");
  }

// Full 14-step permission pipeline at the instant of a fresh frozen-trigger cross.
ENUM_ENTRY_BLOCK CheckEntryPermissions(const MqlTick &tick)
  {
   // 1. initialization
   if(!g_InitComplete)
      return ENTRY_BLOCK_INIT;
   // 2. setup still active
   if(!g_setup.active || g_setup.state != WAIT_RECLAIM)
      return ENTRY_BLOCK_ACTIVE;
   // 3. direction still matches M5 regime
   if(g_setup.direction == DIR_BUY && g_m5.regime != REGIME_BULLISH)
      return ENTRY_BLOCK_REGIME;
   if(g_setup.direction == DIR_SELL && g_m5.regime != REGIME_BEARISH)
      return ENTRY_BLOCK_REGIME;
   // 4. not expired
   if((long)(TimeCurrent() - g_setup.setupStartTime) > (long)EffSetupExpiryMinutes * 60)
      return ENTRY_BLOCK_EXPIRED;
   // 5. position limit (this symbol + this magic only)
   if(CountEAPositions() >= EffMaxOpenTrades)
      return ENTRY_BLOCK_POS_LIMIT;
   // 6. session
   if(!IsSessionOpen())
      return ENTRY_BLOCK_SESSION;
   // 7. spread
   if(CurrentSpreadPoints(tick) > (double)EffMaxSpreadPoints)
      return ENTRY_BLOCK_SPREAD;
   // 8. volatility
   if(!IsVolatilityOK())
      return ENTRY_BLOCK_VOLATILITY;
   // 9. symbol trading permitted (direction aware)
   if(!IsSymbolTradeAllowed(g_setup.direction))
      return ENTRY_BLOCK_SYMBOL;
   // 10. terminal / account / EA trading permitted
   if(!TerminalTradingAllowed())
      return ENTRY_BLOCK_TERMINAL;
   // 11. lot size produces a valid tradable volume
   double vol = NormalizeVolume(EffLotSize);
   if(vol <= 0.0)
      return ENTRY_BLOCK_VOLUME;
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(MathAbs(vol - EffLotSize) > volStep * 0.5)
      PrintFormat("[TRADE] LotSize %s normalized to tradable volume %s (effective)",
                  DoubleToString(EffLotSize, 2), DoubleToString(vol, 2));
   g_entryVolume = vol;
   // 12. margin
   double price = (g_setup.direction == DIR_BUY) ? tick.ask : tick.bid;
   ENUM_ORDER_TYPE ot = (g_setup.direction == DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double marginReq = 0.0;
   if(!OrderCalcMargin(ot, _Symbol, vol, price, marginReq))
      return ENTRY_BLOCK_MARGIN;
   if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      return ENTRY_BLOCK_MARGIN;
   // 13. protective stop (structural, atomic) + V1.01 initial risk geometry filter
   // ATR_at_entry = latest completed M1 ATR immediately before entry
   g_stopBlockReason   = "";
   g_entryRiskDistance = 0.0;
   g_entryRiskATR      = 0.0;
   double atrEntry = GetATR();
   if(atrEntry <= 0.0)
     {
      g_stopBlockReason = "ATR unavailable for stop construction";
      return ENTRY_BLOCK_STOPS;
     }
   double sl = 0.0;
   if(!BuildInitialStop(g_setup.direction, tick, atrEntry, g_setup.pullbackExtreme, sl, g_stopBlockReason))
      return ENTRY_BLOCK_STOPS;
   g_entrySL = sl; // final broker-valid SL of this evaluation (used by execution and risk logging)
   // V1.01: measure the ACTUAL broker-valid SL that would be submitted
   // (after pullback anchoring, ATR buffer, tick normalization and
   // StopsLevel/FreezeLevel adjustment), using the executable-side price.
   double entryPrice = (g_setup.direction == DIR_BUY) ? NormalizePriceToTick(tick.ask)
                                                      : NormalizePriceToTick(tick.bid);
   double riskDistance = (g_setup.direction == DIR_BUY) ? (entryPrice - sl)
                                                        : (sl - entryPrice);
   if(riskDistance <= 0.0)
     {
      g_stopBlockReason = "final SL not on the protective side of entry";
      return ENTRY_BLOCK_STOPS;
     }
   double riskATR = riskDistance / atrEntry;
   if(!MathIsValidNumber(riskATR) || riskATR <= 0.0)
     {
      g_stopBlockReason = "initial risk calculation invalid";
      return ENTRY_BLOCK_STOPS;
     }
   g_entryRiskDistance = riskDistance;
   g_entryRiskATR      = riskATR;
   if(riskATR < EffMinInitialRiskATR)
      return ENTRY_BLOCK_RISK_TOO_TIGHT;   // never widen the stop to pass
   if(riskATR > EffMaxInitialRiskATR)
      return ENTRY_BLOCK_RISK_TOO_WIDE;    // never tighten the stop to pass
   // 14. supported filling mode exists
   ENUM_ORDER_TYPE_FILLING modes[3];
   for(int i = 0; i < 3; i++) modes[i] = ORDER_FILLING_FOK;
   if(BuildFillingCandidates(modes) == 0)
      return ENTRY_BLOCK_FILLING;

   return ENTRY_OK;
  }

void RegisterExecutedPosition(const MqlTradeResult &res, const ENUM_TRADE_DIR dir)
  {
   ulong ticket = res.order;
   if(ticket == 0 && res.deal > 0)
     {
      if(HistoryDealSelect(res.deal))
         ticket = (ulong)HistoryDealGetInteger(res.deal, DEAL_POSITION_ID);
     }
   if(ticket > 0 && PositionSelectByTicket(ticket))
     {
      AddTrackFromSelectedPosition(ticket, dir);
      g_lastManagement = "INITIAL SL";
      return;
     }
   // fallback: adopt the first untracked EA position (netting merges etc.)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(HasTrack(tk)) continue;
      AddTrackFromSelectedPosition(tk, dir);
      g_lastManagement = "INITIAL SL";
      return;
     }
   Print("[TRADE] WARNING: executed position not immediately visible; it will be adopted by reconciliation");
  }

bool OpenBuy(const MqlTick &tick)
  {
   ENUM_ORDER_TYPE_FILLING modes[3];
   for(int i = 0; i < 3; i++) modes[i] = ORDER_FILLING_FOK;
   int modeCount = BuildFillingCandidates(modes);
   if(modeCount == 0)
     {
      Print("[TRADE] BUY rejected: no supported filling mode");
      return false;
     }
   string comment = StringFormat("M5M1_V1#%I64d", g_setup.setupId);
   double price   = NormalizePriceToTick(tick.ask);

   for(int i = 0; i < modeCount; i++)
     {
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = g_entryVolume;
      req.type         = ORDER_TYPE_BUY;
      req.price        = price;
      req.sl           = g_entrySL;
      req.tp           = 0.0; // no take-profit by design
      req.deviation    = (ulong)EffMaxSlippagePoints;
      req.magic        = (ulong)MagicNumber;
      req.comment      = comment;
      req.type_time    = ORDER_TIME_GTC;
      req.type_filling = modes[i];
      ResetLastError();
      bool sent = OrderSend(req, res);
      if(sent && IsSuccessRetcode(res.retcode))
        {
         g_stats.entryExecutions++;
         double fillPrice = (res.price > 0.0 ? res.price : price);
         PrintFormat("[ENTRY] BUY setup #%I64d EXECUTED  Entry=%s  PullbackLow=%s  ATR=%s  InitialSL=%s",
                     g_setup.setupId, DoubleToString(fillPrice, _Digits),
                     DoubleToString(g_setup.pullbackExtreme, _Digits),
                     DoubleToString(GetATR(), 2), DoubleToString(g_entrySL, _Digits));
         RegisterExecutedPosition(res, DIR_BUY);
         SetLastAction(StringFormat("BUY #%I64d executed", g_setup.setupId));
         return true;
        }
      if(res.retcode == TRADE_RETCODE_INVALID_FILL && i < modeCount - 1)
         continue; // try next supported filling mode
      LogExecutionFailure(res, sent);
      g_stats.brokerExecFails++;
      SetLastAction("BUY execution failed");
      return false;
     }
   return false;
  }

bool OpenSell(const MqlTick &tick)
  {
   ENUM_ORDER_TYPE_FILLING modes[3];
   for(int i = 0; i < 3; i++) modes[i] = ORDER_FILLING_FOK;
   int modeCount = BuildFillingCandidates(modes);
   if(modeCount == 0)
     {
      Print("[TRADE] SELL rejected: no supported filling mode");
      return false;
     }
   string comment = StringFormat("M5M1_V1#%I64d", g_setup.setupId);
   double price   = NormalizePriceToTick(tick.bid);

   for(int i = 0; i < modeCount; i++)
     {
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = g_entryVolume;
      req.type         = ORDER_TYPE_SELL;
      req.price        = price;
      req.sl           = g_entrySL;
      req.tp           = 0.0; // no take-profit by design
      req.deviation    = (ulong)EffMaxSlippagePoints;
      req.magic        = (ulong)MagicNumber;
      req.comment      = comment;
      req.type_time    = ORDER_TIME_GTC;
      req.type_filling = modes[i];
      ResetLastError();
      bool sent = OrderSend(req, res);
      if(sent && IsSuccessRetcode(res.retcode))
        {
         g_stats.entryExecutions++;
         double fillPrice = (res.price > 0.0 ? res.price : price);
         PrintFormat("[ENTRY] SELL setup #%I64d EXECUTED  Entry=%s  PullbackHigh=%s  ATR=%s  InitialSL=%s",
                     g_setup.setupId, DoubleToString(fillPrice, _Digits),
                     DoubleToString(g_setup.pullbackExtreme, _Digits),
                     DoubleToString(GetATR(), 2), DoubleToString(g_entrySL, _Digits));
         RegisterExecutedPosition(res, DIR_SELL);
         SetLastAction(StringFormat("SELL #%I64d executed", g_setup.setupId));
         return true;
        }
      if(res.retcode == TRADE_RETCODE_INVALID_FILL && i < modeCount - 1)
         continue;
      LogExecutionFailure(res, sent);
      g_stats.brokerExecFails++;
      SetLastAction("SELL execution failed");
      return false;
     }
   return false;
  }

// One frozen-trigger break = one entry episode. Executed, blocked, or failed:
// the episode is always retired and cooldown starts.
void AttemptEntry(const MqlTick &tick)
  {
   g_stats.entryAttempts++;

   if(g_setup.direction == DIR_BUY)
      PrintFormat("[M1] BUY frozen-trigger fresh-cross  PrevAsk=%s  Ask=%s  Trigger=%s",
                  DoubleToString(g_prevAsk, _Digits), DoubleToString(tick.ask, _Digits),
                  DoubleToString(g_setup.frozenTrigger, _Digits));
   else
      PrintFormat("[M1] SELL frozen-trigger fresh-cross  PrevBid=%s  Bid=%s  Trigger=%s",
                  DoubleToString(g_prevBid, _Digits), DoubleToString(tick.bid, _Digits),
                  DoubleToString(g_setup.frozenTrigger, _Digits));

   ENUM_ENTRY_BLOCK block = CheckEntryPermissions(tick);
   if(block == ENTRY_OK)
     {
      if(DebugTradeEnabled())
         PrintFormat("[RISK] %s setup #%I64d  Entry=%s  FinalSL=%s  ATR=%s  Distance=%s  RiskATR=%s  Allowed=%s..%s",
                     DirLabel(g_setup.direction), g_setup.setupId,
                     DoubleToString((g_setup.direction == DIR_BUY ? NormalizePriceToTick(tick.ask)
                                                                  : NormalizePriceToTick(tick.bid)), _Digits),
                     DoubleToString(g_entrySL, _Digits), DoubleToString(GetATR(), 2),
                     DoubleToString(g_entryRiskDistance, 2), DoubleToString(g_entryRiskATR, 2),
                     DoubleToString(EffMinInitialRiskATR, 2), DoubleToString(EffMaxInitialRiskATR, 2));
      if(g_setup.direction == DIR_BUY)
         OpenBuy(tick);
      else
         OpenSell(tick);
      // broker failure (if any) already logged and counted inside Open*
     }
   else
     {
      g_stats.entryBlocks++;
      CountBlock(block);
      PrintFormat("[ENTRY] %s setup #%I64d BLOCKED: %s",
                  DirLabel(g_setup.direction), g_setup.setupId, EntryBlockReason(block));
      if(block == ENTRY_BLOCK_RISK_TOO_TIGHT || block == ENTRY_BLOCK_RISK_TOO_WIDE)
        {
         // V1.01 risk-geometry detail (fired once per retired trigger episode only)
         PrintFormat("[ENTRY]   Entry=%s  SL=%s  ATR=%s",
                     DoubleToString((g_setup.direction == DIR_BUY ? NormalizePriceToTick(tick.ask)
                                                                  : NormalizePriceToTick(tick.bid)), _Digits),
                     DoubleToString(g_entrySL, _Digits), DoubleToString(GetATR(), 2));
         PrintFormat("[ENTRY]   RiskDistance=%s  RiskATR=%s  Allowed=%s..%s",
                     DoubleToString(g_entryRiskDistance, 2), DoubleToString(g_entryRiskATR, 2),
                     DoubleToString(EffMinInitialRiskATR, 2), DoubleToString(EffMaxInitialRiskATR, 2));
        }
      SetLastAction("Entry blocked: " + EntryBlockReason(block));
     }

   // retire the episode no matter what happened
   SetLastSetupEnd(g_setup.direction, TimeCurrent());
   ResetSetup();
  }

//+------------------------------------------------------------------+
//| Position management: BE -> ATR trailing (monotonic, one modify)  |
//+------------------------------------------------------------------+
bool IsMoreProtective(const ENUM_TRADE_DIR dir, const double candidate, const double reference)
  {
   double eps = TickSizeSafe() * 0.5;
   if(dir == DIR_BUY)  return (candidate > reference + eps);
   return (candidate < reference - eps);
  }

// Minimum improvement of one valid tick versus the current SL.
bool ImprovesStop(const ENUM_TRADE_DIR dir, const double candidate, const double currentSL)
  {
   if(currentSL <= 0.0) return true; // no SL yet (should not happen; adopt any legal stop)
   double tick = TickSizeSafe();
   if(dir == DIR_BUY)  return (candidate >= currentSL + tick);
   return (candidate <= currentSL - tick);
  }

bool IsStopLegalForModify(const ENUM_TRADE_DIR dir, const double sl, const MqlTick &tick)
  {
   double dist = BrokerMinStopDistance();
   if(dir == DIR_BUY)
      return (sl > 0.0 && sl <= tick.bid - dist);
   return (sl > 0.0 && sl >= tick.ask + dist);
  }

bool GetBreakEvenCandidate(const SPositionTrack &tr, double &candidate)
  {
   if(!tr.breakEvenActive) return false;
   double c = (tr.direction == DIR_BUY)
              ? tr.entryPrice + tr.atrAtEntry * EffBreakEvenLockATR
              : tr.entryPrice - tr.atrAtEntry * EffBreakEvenLockATR;
   candidate = NormalizePriceToTick(c);
   return true;
  }

bool GetTrailCandidate(const SPositionTrack &tr, const MqlTick &tick, double &candidate)
  {
   if(!tr.trailingActive) return false;
   if(g_atrPrev <= 0.0) return false; // need completed ATR
   double c = (tr.direction == DIR_BUY)
              ? tick.bid - g_atrPrev * EffTrailATRMult
              : tick.ask + g_atrPrev * EffTrailATRMult;
   candidate = NormalizePriceToTick(c);
   return true;
  }

// Sends a single SLTP modification. Never loosens a stop.
bool ApplyProtectiveStop(SPositionTrack &tr, const double newSL, const bool fromTrail)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = tr.ticket;
   req.sl       = newSL;
   req.tp       = PositionGetDouble(POSITION_TP);
   ResetLastError();
   bool sent = OrderSend(req, res);
   if(sent && (res.retcode == TRADE_RETCODE_DONE ||
               res.retcode == TRADE_RETCODE_PLACED ||
               res.retcode == TRADE_RETCODE_NO_CHANGES))
     {
      tr.lastRequestedSL = newSL;
      tr.lastRejectTime  = 0;
      return true;
     }
   tr.lastRejectTime = TimeCurrent(); // backoff before retrying an illegal moment
   LogExecutionFailure(res, sent);
   return false;
  }

void ManageOnePosition(SPositionTrack &tr, const MqlTick &tick)
  {
   if(tr.atrAtEntry <= 0.0 || tr.entryPrice <= 0.0) return;

   double favorable = (tr.direction == DIR_BUY)
                      ? (tick.bid - tr.entryPrice)
                      : (tr.entryPrice - tick.ask);

   // --- break-even activation (uses ATR captured at entry)
   if(!tr.breakEvenActive && favorable >= tr.atrAtEntry * EffBreakEvenTriggerATR)
     {
      tr.breakEvenActive = true;
      g_stats.beActivations++;
      g_lastManagement = "BREAK EVEN";
     }

   // --- ATR trailing activation (eligibility via ATR at entry)
   if(!tr.trailingActive && favorable >= tr.atrAtEntry * EffTrailStartATR)
     {
      tr.trailingActive = true;
      g_stats.trailActivations++;
      g_lastManagement = "ATR TRAILING";
     }

   // --- candidates (BE from entry ATR, trail from latest completed ATR)
   double beCandidate    = 0.0;
   bool   haveBE         = GetBreakEvenCandidate(tr, beCandidate);
   double trailCandidate = 0.0;
   bool   haveTrail      = GetTrailCandidate(tr, tick, trailCandidate);
   if(!haveBE && !haveTrail) return;

   // choose the MOST protective candidate -> one modification, never two
   bool   fromTrail = false;
   double best      = 0.0;
   if(haveBE) best = beCandidate;
   if(haveTrail && (!haveBE || IsMoreProtective(tr.direction, trailCandidate, best)))
     {
      best = trailCandidate;
      fromTrail = true;
     }

   double currentSL = PositionGetDouble(POSITION_SL);

   // --- monotonic protection only, with tick-size-aware minimum improvement
   if(!ImprovesStop(tr.direction, best, currentSL)) return;
   double tickSize = TickSizeSafe();
   if(tr.lastRequestedSL > 0.0 && MathAbs(best - tr.lastRequestedSL) < tickSize * 0.5)
      return; // identical request already in flight
   if(!IsStopLegalForModify(tr.direction, best, tick))
     {
      tr.lastRejectTime = TimeCurrent(); // illegal right now: keep eligibility, retry later
      return;
     }
   if(tr.lastRejectTime > 0 && (long)(TimeCurrent() - tr.lastRejectTime) < 2)
      return; // reject backoff: no per-tick spam

   double oldSL = currentSL;
   if(ApplyProtectiveStop(tr, best, fromTrail))
     {
      if(fromTrail)
         PrintFormat("[TRAIL] Position #%I64u  ATR=%s  OldSL=%s  NewSL=%s",
                     tr.ticket, DoubleToString(g_atrPrev, 2),
                     DoubleToString(oldSL, _Digits), DoubleToString(best, _Digits));
      else
         PrintFormat("[BE] Position #%I64u activated  OldSL=%s  NewSL=%s",
                     tr.ticket, DoubleToString(oldSL, _Digits), DoubleToString(best, _Digits));
      g_lastManagement = (fromTrail ? "ATR TRAILING" : "BREAK EVEN");
      SetLastAction(StringFormat("%s SL #%I64u -> %s",
                                 (fromTrail ? "TRAIL" : "BE"), tr.ticket, DoubleToString(best, _Digits)));
     }
  }

void ManagePositions(const MqlTick &tick)
  {
   ReconcileTracks();
   for(int i = ArraySize(g_tracks) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_tracks[i].ticket))
        {
         ProcessClosedPosition(g_tracks[i].positionId); // fallback if transaction was missed
         RemoveTrack(i);
         continue;
        }
      ManageOnePosition(g_tracks[i], tick);
     }
  }

//+------------------------------------------------------------------+
//| Realized trade statistics from completed deal history            |
//+------------------------------------------------------------------+
void ProcessClosedPosition(const long positionId)
  {
   if(positionId <= 0) return;
   if(IsClosedPositionProcessed(positionId)) return;
   if(!HistorySelectByPosition(positionId)) return;
   int dealCount = HistoryDealsTotal();
   if(dealCount <= 0) return;

   double   net = 0.0;
   datetime firstIn = 0;
   datetime lastOut = 0;
   ENUM_DEAL_TYPE inType = DEAL_TYPE_BALANCE;
   bool hasIn = false;
   bool ours  = false;

   for(int i = 0; i < dealCount; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      double profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double swap       = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      net += profit + swap + commission;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(entry == DEAL_ENTRY_IN)
        {
         if(!hasIn || dealTime < firstIn)
           {
            firstIn = dealTime;
            inType  = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
           }
         hasIn = true;
         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MagicNumber)
            ours = true;
        }
      else
        {
         if(dealTime > lastOut) lastOut = dealTime;
        }
     }

   MarkClosedPositionProcessed(positionId);
   if(!ours) return; // not opened by this EA

   g_stats.tradesTotal++;
   if(inType == DEAL_TYPE_BUY)       g_stats.tradesBuy++;
   else if(inType == DEAL_TYPE_SELL) g_stats.tradesSell++;

   if(net > 0.0)
     {
      g_stats.wins++;
      g_stats.grossProfit += net;
      if(net > g_stats.largestWin) g_stats.largestWin = net;
     }
   else if(net < 0.0)
     {
      g_stats.losses++;
      g_stats.grossLoss += -net;
      if(-net > g_stats.largestLoss) g_stats.largestLoss = -net;
     }
   g_stats.netPL += net;

   if(hasIn && lastOut > firstIn)
     {
      g_stats.holdSecondsTotal += (double)(lastOut - firstIn);
      g_stats.holdCount++;
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN) return;

   long positionId = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(positionId <= 0) return;
   if(IsPositionOpen(positionId)) return; // partial close: wait for the final one

   ProcessClosedPosition(positionId);
  }

//+------------------------------------------------------------------+
//| Equity drawdown tracking                                         |
//+------------------------------------------------------------------+
void UpdateEquityDrawdown()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return;
   if(eq > g_peakEquity) g_peakEquity = eq;
   if(g_peakEquity > 0.0)
     {
      double dd = (g_peakEquity - eq) / g_peakEquity * 100.0;
      if(dd > g_stats.maxDDPercent) g_stats.maxDDPercent = dd;
     }
  }

//+------------------------------------------------------------------+
//| Panel (display only; no trading logic reads panel state)         |
//+------------------------------------------------------------------+
void EnsurePanelBackground(const string name, const int x, const int y, const int w, const int h)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'8,12,24');
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'36,52,96');
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
     }
  }

// Persistent label objects: created once, then only text/color updates.
void EnsurePanelLabel(const string name, const int x, const int y,
                      const string text, const color clr, const int fontSize)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void BuildPanel()
  {
   EnsurePanelBackground(PANEL_PREFIX + "BG", 8, 8, 320, 376);
   EnsurePanelLabel(PANEL_PREFIX + "TITLE", 16, 14, "XAUUSD M5/M1 SCALPER V1.02", C'0,210,255', 10);
   EnsurePanelLabel(PANEL_PREFIX + "SUB", 16, 32, _Symbol + "  chart M1", C'170,180,200', 8);
  }

void DeletePanel()
  {
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ChartRedraw(0);
  }

void PanelHeader(const int idx, const string text)
  {
   int y = 50 + idx * 14;
   EnsurePanelLabel(PANEL_PREFIX + "H" + IntegerToString(idx), 16, y, text, C'0,210,255', 8);
  }

void PanelRow(const int idx, const string label, const string value, const color valueColor)
  {
   int y = 50 + idx * 14;
   EnsurePanelLabel(PANEL_PREFIX + "L" + IntegerToString(idx), 16, y, label, C'170,180,200', 8);
   EnsurePanelLabel(PANEL_PREFIX + "V" + IntegerToString(idx), 150, y, value, valueColor, 8);
  }

void UpdatePanel(const MqlTick &tick)
  {
   // --- row 0: M5 section
   PanelHeader(0, "-- M5 REGIME ----------------");

   // --- row 1: regime
   color regimeColor = C'255,193,7';
   if(g_m5.regime == REGIME_BULLISH)      regimeColor = C'0,230,140';
   else if(g_m5.regime == REGIME_BEARISH) regimeColor = C'255,105,97';
   PanelRow(1, "Regime", RegimeToString(g_m5.regime), regimeColor);

   // --- rows 2-3: swings
   string hiTxt = (g_m5.latestSwingHigh > 0.0 ? DoubleToString(g_m5.latestSwingHigh, _Digits) : "-")
                  + " / " +
                  (g_m5.previousSwingHigh > 0.0 ? DoubleToString(g_m5.previousSwingHigh, _Digits) : "-");
   string loTxt = (g_m5.latestSwingLow > 0.0 ? DoubleToString(g_m5.latestSwingLow, _Digits) : "-")
                  + " / " +
                  (g_m5.previousSwingLow > 0.0 ? DoubleToString(g_m5.previousSwingLow, _Digits) : "-");
   PanelRow(2, "Swing High L/P", hiTxt, clrWhite);
   PanelRow(3, "Swing Low  L/P", loTxt, clrWhite);

   // --- row 4: setup section
   PanelHeader(4, "-- M1 SETUP -----------------");

   // --- row 5: state + direction (V1.02: WAIT_TURN before, WAIT_BREAK after freeze)
   string stateText;
   color  stateColor = C'255,193,7';
   if(!g_InitComplete)
     {
      stateText = "INITIALIZING";
     }
   else if(g_setup.active && g_setup.state == WAIT_RECLAIM)
     {
      stateText = (g_setup.turnCandleFound ? "WAIT_BREAK " : "WAIT_TURN ") + DirLabel(g_setup.direction);
      stateColor = (g_setup.direction == DIR_BUY ? C'0,230,140' : C'255,105,97');
     }
   else
      stateText = "WAIT_PULLBACK";
   PanelRow(5, "State", stateText, stateColor);

   // --- row 6: age / expiry
   string ageText = "- / " + FormatDuration((long)EffSetupExpiryMinutes * 60);
   if(g_setup.active && g_setup.state == WAIT_RECLAIM)
     {
      long elapsed = (long)(TimeCurrent() - g_setup.setupStartTime);
      ageText = FormatDuration(elapsed) + " / " + FormatDuration((long)EffSetupExpiryMinutes * 60);
     }
   PanelRow(6, "Age / Expiry", ageText, clrWhite);

   // --- row 7: ATR
   PanelRow(7, "ATR (M1)", (g_atrPrev > 0.0 ? DoubleToString(g_atrPrev, 2) : "n/a"), clrWhite);

   // --- row 8: pullback distance / required
   string pbText = "-";
   bool pbShow = false;
   double dist = 0.0;
   double req  = 0.0;
   if(g_setup.active && g_setup.state == WAIT_RECLAIM && g_setup.atrAtSetup > 0.0)
     {
      dist = (g_setup.direction == DIR_BUY)
             ? (g_setup.referenceExtreme - tick.bid)
             : (tick.ask - g_setup.referenceExtreme);
      req = g_setup.atrAtSetup * EffPullbackATRMin;
      pbShow = true;
     }
   else if(g_m5.regime == REGIME_BULLISH && g_pullbackRefHigh > 0.0 && g_atrPrev > 0.0)
     {
      dist = g_pullbackRefHigh - tick.bid;
      req  = g_atrPrev * EffPullbackATRMin;
      pbShow = true;
     }
   else if(g_m5.regime == REGIME_BEARISH && g_pullbackRefLow > 0.0 && g_atrPrev > 0.0)
     {
      dist = tick.ask - g_pullbackRefLow;
      req  = g_atrPrev * EffPullbackATRMin;
      pbShow = true;
     }
   if(pbShow)
      pbText = DoubleToString(dist, 2) + " / " + DoubleToString(req, 2);
   PanelRow(8, "Pullback / Req", pbText, clrWhite);

   // --- row 9: pullback extreme
   PanelRow(9, "PB Extreme",
            (g_setup.active && g_setup.pullbackExtreme > 0.0
             ? DoubleToString(g_setup.pullbackExtreme, _Digits) : "-"), clrWhite);

   // --- row 10: V1.02 frozen turn-candle trigger level (display only)
   PanelRow(10, "Trigger Level",
            (g_setup.active && g_setup.turnCandleFound && g_setup.frozenTrigger > 0.0
             ? DoubleToString(g_setup.frozenTrigger, _Digits) : "-"), clrWhite);

   // --- row 11: filters section
   PanelHeader(11, "-- FILTERS ------------------");

   // --- row 12: spread
   double spreadPts = CurrentSpreadPoints(tick);
   PanelRow(12, "Spread", DoubleToString(spreadPts, 0) + " pts",
            (spreadPts > (double)EffMaxSpreadPoints ? C'255,105,97' : C'0,230,140'));

   // --- row 13: volatility
   string volText = "n/a";
   color  volColor = C'255,193,7';
   if(g_atrPrev > 0.0 && g_atrAvg > 0.0)
     {
      if(IsVolatilityOK())
        {
         volText = "OK  avg " + DoubleToString(g_atrAvg, 2);
         volColor = C'0,230,140';
        }
      else
        {
         volText = "SPIKE blocked";
         volColor = C'255,105,97';
        }
     }
   PanelRow(13, "Volatility", volText, volColor);

   // --- row 14: session
   bool sessionOpen = IsSessionOpen();
   PanelRow(14, "Session",
            (sessionOpen ? "OPEN " + IntegerToString(EffTradingStartHour) + "-" + IntegerToString(EffTradingEndHour)
                         : "CLOSED " + IntegerToString(EffTradingStartHour) + "-" + IntegerToString(EffTradingEndHour)),
            (sessionOpen ? C'0,230,140' : C'255,105,97'));

   // --- row 15: trading section
   PanelHeader(15, "-- TRADING ------------------");

   // --- row 16: open EA trades
   int openTrades = CountEAPositions();
   PanelRow(16, "Open EA Trades", IntegerToString(openTrades) + " / " + IntegerToString(EffMaxOpenTrades),
            (openTrades >= EffMaxOpenTrades ? C'255,193,7' : clrWhite));

   // --- row 17: BE / Trail activations
   PanelRow(17, "BE / Trail", IntegerToString(g_stats.beActivations) + " / " + IntegerToString(g_stats.trailActivations), clrWhite);

   // --- row 18: latest management status
   PanelRow(18, "Last Mgmt", g_lastManagement, C'0,210,255');

   // --- row 19: last action
   string la = g_lastAction;
   if(StringLen(la) > 26) la = StringSubstr(la, 0, 26);
   PanelRow(19, "Last Action", la, C'255,193,7');

   // --- row 20: V1.01 estimated initial risk ATR (INFORMATIONAL ONLY -- no
   //     trading logic reads panel state; estimate mirrors the entry filter:
   //     executable-side price vs pullbackExtreme +/- ATR*InitialStopATRBuffer)
   string riskText = "-";
   color  riskColor = clrWhite;
   if(g_setup.active && g_setup.state == WAIT_RECLAIM &&
      g_atrPrev > 0.0 && g_setup.pullbackExtreme > 0.0)
     {
      double estSL = (g_setup.direction == DIR_BUY)
                     ? g_setup.pullbackExtreme - g_atrPrev * EffInitialStopATRBuffer
                     : g_setup.pullbackExtreme + g_atrPrev * EffInitialStopATRBuffer;
      double refPx = (g_setup.direction == DIR_BUY) ? tick.ask : tick.bid;
      double estRisk = (g_setup.direction == DIR_BUY) ? (refPx - estSL) : (estSL - refPx);
      if(estRisk > 0.0)
        {
         double estRiskATR = estRisk / g_atrPrev;
         riskText  = DoubleToString(estRiskATR, 2) + " (" +
                     DoubleToString(EffMinInitialRiskATR, 2) + ".." +
                     DoubleToString(EffMaxInitialRiskATR, 2) + ")";
         riskColor = (estRiskATR < EffMinInitialRiskATR || estRiskATR > EffMaxInitialRiskATR)
                     ? C'255,193,7' : C'0,230,140';
        }
     }
   PanelRow(20, "Risk ATR", riskText, riskColor);

   // --- row 21: V1.02 frozen turn candle info (display only)
   string turnText = "-";
   if(g_setup.active && g_setup.turnCandleFound && g_setup.turnCandleTime > 0)
      turnText = TimeToString(g_setup.turnCandleTime, TIME_MINUTES) +
                 "  H" + DoubleToString(g_setup.turnCandleHigh, _Digits) +
                 " L" + DoubleToString(g_setup.turnCandleLow, _Digits);
   PanelRow(21, "Turn Candle", turnText, clrWhite);
  }

void UpdatePanelThrottled(const MqlTick &tick)
  {
   if(!ShowPanel) return;
   uint now = GetTickCount();
   if(g_lastPanelMs != 0 && now - g_lastPanelMs < (uint)EffPanelRefreshMs)
      return;
   g_lastPanelMs = now;
   UpdatePanel(tick);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Backtest / session summary                                       |
//+------------------------------------------------------------------+
void PrintBacktestSummary()
  {
   double totalTrades = (double)g_stats.tradesTotal;
   double winRate = (totalTrades > 0.0) ? 100.0 * (double)g_stats.wins / totalTrades : 0.0;
   double avgWin  = (g_stats.wins > 0) ? g_stats.grossProfit / (double)g_stats.wins : 0.0;
   double avgLoss = (g_stats.losses > 0) ? g_stats.grossLoss / (double)g_stats.losses : 0.0;
   string pfText = "n/a";
   if(g_stats.grossLoss > 0.0)
      pfText = DoubleToString(g_stats.grossProfit / g_stats.grossLoss, 2);
   else if(g_stats.grossProfit > 0.0)
      pfText = "inf";
   string holdText = (g_stats.holdCount > 0)
                     ? FormatDuration((long)(g_stats.holdSecondsTotal / (double)g_stats.holdCount))
                     : "n/a";

   Print("==================================================");
   Print("XAUUSD M5/M1 SCALPER V1 SUMMARY");
   Print("--------------------------------------------------");
   Print("M5 regime transitions:");
   Print("  Bullish: ", g_stats.regimeBullTransitions);
   Print("  Bearish: ", g_stats.regimeBearTransitions);
   Print("  Neutral: ", g_stats.regimeNeutralTransitions);
   Print("--------------------------------------------------");
   Print("Setups armed: ", g_stats.setupsArmed,
         "  (BUY ", g_stats.setupsBuy, " / SELL ", g_stats.setupsSell, ")");
   Print("Setups expired: ", g_stats.setupsExpired);
   Print("Setups cancelled (M5 regime loss): ", g_stats.setupsCancelledRegime);
   Print("Reclaim crossings: ", g_stats.reclaimCrossings,
         "  (V1.02: final frozen turn-trigger breaks)");
   Print("Turn candles found: ", g_stats.turnCandlesFound);
   Print("  BUY: ", g_stats.turnCandlesBuy);
   Print("  SELL: ", g_stats.turnCandlesSell);
   Print("Turn candles invalidated: ", g_stats.turnCandlesInvalidated);
   Print("Frozen trigger crossings: ", g_stats.frozenTriggerCrossings);
   Print("--------------------------------------------------");
   Print("Entry attempts: ", g_stats.entryAttempts);
   Print("  Executed: ", g_stats.entryExecutions);
   Print("  Blocked:  ", g_stats.entryBlocks);
   Print("Blocks detail:");
   Print("  Spread:         ", g_stats.spreadBlocks);
   Print("  Volatility:     ", g_stats.volBlocks);
   Print("  Session:        ", g_stats.sessionBlocks);
   Print("  Position limit: ", g_stats.posLimitBlocks);
   Print("  Invalid stop:   ", g_stats.invalidStopBlocks);
   Print("  Risk too tight: ", g_stats.riskTooTightBlocks);
   Print("  Risk too wide:  ", g_stats.riskTooWideBlocks);
   Print("  Margin:         ", g_stats.marginBlocks);
   Print("  Other:          ", g_stats.otherBlocks);
   Print("Broker execution failures: ", g_stats.brokerExecFails);
   Print("--------------------------------------------------");
   Print("Trades:");
   Print("  Total: ", g_stats.tradesTotal,
         "  (BUY ", g_stats.tradesBuy, " / SELL ", g_stats.tradesSell, ")");
   Print("  Wins: ", g_stats.wins, "  Losses: ", g_stats.losses,
         "  Win rate: ", DoubleToString(winRate, 1), "%");
   Print("  Gross profit: ", DoubleToString(g_stats.grossProfit, 2));
   Print("  Gross loss:   ", DoubleToString(g_stats.grossLoss, 2));
   Print("  Net P/L:      ", DoubleToString(g_stats.netPL, 2));
   Print("  Profit factor: ", pfText);
   Print("  Average win:  ", DoubleToString(avgWin, 2),
         "   Average loss: ", DoubleToString(avgLoss, 2));
   Print("  Largest win:  ", DoubleToString(g_stats.largestWin, 2),
         "   Largest loss: ", DoubleToString(g_stats.largestLoss, 2));
   Print("Break-even activations:   ", g_stats.beActivations);
   Print("ATR trailing activations: ", g_stats.trailActivations);
   Print("Average holding time: ", holdText);
   Print("Maximum drawdown: ", DoubleToString(g_stats.maxDDPercent, 2), "%");
   Print("==================================================");
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
int ClampInt(const int value, const int minValue, const int maxValue, const string name)
  {
   if(value < minValue)
     {
      PrintFormat("[INIT] Input %s=%d clamped to %d", name, value, minValue);
      return minValue;
     }
   if(value > maxValue)
     {
      PrintFormat("[INIT] Input %s=%d clamped to %d", name, value, maxValue);
      return maxValue;
     }
   return value;
  }

double ClampDouble(const double value, const double minValue, const double maxValue, const string name)
  {
   if(value < minValue)
     {
      PrintFormat("[INIT] Input %s=%.4f clamped to %.4f", name, value, minValue);
      return minValue;
     }
   if(value > maxValue)
     {
      PrintFormat("[INIT] Input %s=%.4f clamped to %.4f", name, value, maxValue);
      return maxValue;
     }
   return value;
  }

bool ValidateInputs()
  {
   bool ok = true;

   // --- critical values: reject
   if(M5PivotSize < 1 || !MathIsValidNumber((double)M5PivotSize))
     {
      Print("[INIT] FATAL: M5PivotSize must be >= 1");
      ok = false;
     }
   else
      EffM5PivotSize = M5PivotSize;

   if(ATRPeriod < 1)
     {
      Print("[INIT] FATAL: ATRPeriod must be >= 1");
      ok = false;
     }
   else
      EffATRPeriod = ATRPeriod;

   if(!MathIsValidNumber(PullbackATRMin) || PullbackATRMin <= 0.0)
     {
      Print("[INIT] FATAL: PullbackATRMin must be > 0");
      ok = false;
     }
   else
      EffPullbackATRMin = PullbackATRMin;

   if(!MathIsValidNumber(BreakEvenTriggerATR) || BreakEvenTriggerATR <= 0.0)
     {
      Print("[INIT] FATAL: BreakEvenTriggerATR must be > 0");
      ok = false;
     }

   if(!MathIsValidNumber(TrailStartATR) || TrailStartATR <= 0.0)
     {
      Print("[INIT] FATAL: TrailStartATR must be > 0");
      ok = false;
     }

   if(!MathIsValidNumber(TrailATRMult) || TrailATRMult <= 0.0)
     {
      Print("[INIT] FATAL: TrailATRMult must be > 0");
      ok = false;
     }

   // --- V1.01 initial risk geometry: critical relationship validation
   if(!MathIsValidNumber(MinInitialRiskATR) || MinInitialRiskATR < 0.0)
     {
      Print("[INIT] FATAL: MinInitialRiskATR must be >= 0.0");
      ok = false;
     }
   if(!MathIsValidNumber(MaxInitialRiskATR) || MaxInitialRiskATR <= 0.0)
     {
      Print("[INIT] FATAL: MaxInitialRiskATR must be > 0.0");
      ok = false;
     }
   if(MathIsValidNumber(MinInitialRiskATR) && MathIsValidNumber(MaxInitialRiskATR) &&
      MinInitialRiskATR > MaxInitialRiskATR)
     {
      Print("[INIT] FATAL: MinInitialRiskATR must be <= MaxInitialRiskATR (values are not reversed silently)");
      ok = false;
     }

   if(!MathIsValidNumber(LotSize) || LotSize <= 0.0)
     {
      Print("[INIT] FATAL: LotSize must be > 0");
      ok = false;
     }
   else
      EffLotSize = LotSize;

   if(MaxOpenTrades < 1)
     {
      Print("[INIT] FATAL: MaxOpenTrades must be >= 1");
      ok = false;
     }

   if(TradingStartHour < 0 || TradingStartHour > 23)
     {
      Print("[INIT] FATAL: TradingStartHour must be within 0..23");
      ok = false;
     }
   else
      EffTradingStartHour = TradingStartHour;

   if(TradingEndHour < 0 || TradingEndHour > 23)
     {
      Print("[INIT] FATAL: TradingEndHour must be within 0..23");
      ok = false;
     }
   else
      EffTradingEndHour = TradingEndHour;

   if(!ok) return false;

   // --- non-critical: clamp excessive values and log the effective value
   EffPullbackReferenceBars  = ClampInt(PullbackReferenceBars, 1, 500, "PullbackReferenceBars");
   EffReclaimLookbackBars    = ClampInt(ReclaimLookbackBars, 1, 200, "ReclaimLookbackBars");
   EffSetupExpiryMinutes     = ClampInt(SetupExpiryMinutes, 1, 1440, "SetupExpiryMinutes");
   EffReentryCooldownMinutes = ClampInt(ReentryCooldownMinutes, 0, 120, "ReentryCooldownMinutes");
   EffInitialStopATRBuffer   = ClampDouble(InitialStopATRBuffer, 0.0, 10.0, "InitialStopATRBuffer");
   EffMinInitialRiskATR      = ClampDouble(MinInitialRiskATR, 0.0, 10.0, "MinInitialRiskATR");
   EffMaxInitialRiskATR      = ClampDouble(MaxInitialRiskATR, 0.0, 10.0, "MaxInitialRiskATR");
   EffBreakEvenTriggerATR    = ClampDouble(BreakEvenTriggerATR, 0.05, 50.0, "BreakEvenTriggerATR");
   EffBreakEvenLockATR       = ClampDouble(BreakEvenLockATR, 0.0, 10.0, "BreakEvenLockATR");
   EffTrailStartATR          = ClampDouble(TrailStartATR, 0.05, 50.0, "TrailStartATR");
   EffTrailATRMult           = ClampDouble(TrailATRMult, 0.05, 20.0, "TrailATRMult");
   EffVolatilityLookback     = ClampInt(VolatilityLookback, 2, 2000, "VolatilityLookback");
   EffVolatilitySpikeLimit   = ClampDouble(VolatilitySpikeLimit, 0.1, 100.0, "VolatilitySpikeLimit");
   EffMaxOpenTrades          = ClampInt(MaxOpenTrades, 1, 1000, "MaxOpenTrades");
   EffMaxSpreadPoints        = ClampInt(MaxSpreadPoints, 0, 1000000, "MaxSpreadPoints");
   EffMaxSlippagePoints      = ClampInt(MaxSlippagePoints, 0, 10000, "MaxSlippagePoints");
   EffPanelRefreshMs         = ClampInt(PanelRefreshMs, 50, 60000, "PanelRefreshMs");

   return true;
  }

//+------------------------------------------------------------------+
//| Initialization / warmup (fully causal, no historical trades)     |
//+------------------------------------------------------------------+
void ZeroStats()
  {
   ZeroMemory(g_stats);
   g_peakEquity = 0.0;
  }

void TryCompleteInitialization()
  {
   if(g_InitComplete) return;

   // V1.02: ReclaimLookbackBars is legacy/unused and must have ZERO effect
   // anywhere (including warmup gating), so it is deliberately not consulted.
   int m1Need = MathMax(EffPullbackReferenceBars, EffVolatilityLookback + 2) + 2;
   if(Bars(_Symbol, PERIOD_M5) < EffM5PivotSize * 2 + 4) return;
   if(Bars(_Symbol, PERIOD_M1) < m1Need) return;
   if(BarsCalculated(g_atrHandle) < EffVolatilityLookback + 3) return;

   g_warmingUp = true;
   WarmupM5Structure();
   UpdateM5Regime();
   RefreshM1AtrCache();
   RefreshVolatilityAverage();
   RefreshPullbackReferences();
   g_warmingUp = false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(tick.bid <= 0.0 || tick.ask <= 0.0) return;

   // startup cross protection: seed price/bar state so the first tick
   // cannot fabricate a historical crossing
   g_lastM5BarTime = iTime(_Symbol, PERIOD_M5, 0);
   g_lastM1BarTime = iTime(_Symbol, PERIOD_M1, 0);
   g_prevBid = tick.bid;
   g_prevAsk = tick.ask;

   g_InitComplete = true;
   PrintFormat("[INIT] XAUUSD M5/M1 Scalper V1.02 warmup complete on %s. Regime=%s (%s)  Swings H %s/%s  L %s/%s  ATR(M1)=%s",
               _Symbol, RegimeToString(g_m5.regime), StructureDescription(),
               DoubleToString(g_m5.latestSwingHigh, _Digits), DoubleToString(g_m5.previousSwingHigh, _Digits),
               DoubleToString(g_m5.latestSwingLow, _Digits), DoubleToString(g_m5.previousSwingLow, _Digits),
               DoubleToString(g_atrPrev, 2));
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_InitComplete = false;
   ZeroStats();
   ResetSetup();
   g_lastAction     = "-";
   g_lastManagement = "INITIAL SL";
   g_atrPrev        = 0.0;
   g_atrAvg         = 0.0;
   g_pullbackRefHigh = 0.0;
   g_pullbackRefLow  = 0.0;
   g_lastM5BarTime  = 0;
   g_lastM1BarTime  = 0;
   g_lastM5Candidate = 0;
   g_setupIdCounter = 0;
   g_lastSetupEndBuy = 0;
   g_lastSetupEndSell = 0;
   ArrayResize(g_tracks, 0);
   for(int i = 0; i < CLOSED_ID_CACHE_SIZE; i++) g_closedIds[i] = 0;
   g_closedIdIndex = 0;

   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   // one ATR handle for the whole lifetime; never recreated per tick
   g_atrHandle = iATR(_Symbol, PERIOD_M1, EffATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("[INIT] FATAL: failed to create M1 ATR handle, error ", GetLastError());
      return INIT_FAILED;
     }

   if(StringFind(_Symbol, "XAU") < 0)
      Print("[INIT] NOTE: primary target is XAUUSD; running on ", _Symbol);

   TryCompleteInitialization();
   if(!g_InitComplete)
      Print("[INIT] Waiting for M1/M5 history and ATR data to complete warmup (no trading until ready)...");

   if(ShowPanel)
      BuildPanel();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
   if(ShowPanel)
      DeletePanel();
   PrintBacktestSummary();
  }

//+------------------------------------------------------------------+
//| New-bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar(const ENUM_TIMEFRAMES tf, datetime &lastBarTime)
  {
   datetime t = iTime(_Symbol, tf, 0);
   if(t <= 0) return false;
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| M1 new-bar processing (caches only; no per-tick history scans)   |
//+------------------------------------------------------------------+
void ProcessNewM1Bar(const MqlTick &tick)
  {
   RefreshM1AtrCache();          // completed ATR cache
   RefreshVolatilityAverage();   // volatility average cache
   RefreshPullbackReferences();  // reference window (completed bars)
   // V1.02: inspect the just-completed shift-1 candle ONCE for a turn candle;
   // freeze its high/low trigger and initialize crossArmed from the live price.
   // No rolling trigger is calculated anymore.
   TryDetectTurnCandle(tick);
  }

//+------------------------------------------------------------------+
//| Expert tick — deterministic event order                          |
//+------------------------------------------------------------------+
void OnTick()
  {
   // no trading until initialization is complete
   if(!g_InitComplete)
     {
      TryCompleteInitialization();
      if(!g_InitComplete) return;
     }

   // 1. current tick
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(tick.bid <= 0.0 || tick.ask <= 0.0) return;

   // 2. new M5 bar: causal pivots -> structure -> regime -> setup invalidation
   if(IsNewBar(PERIOD_M5, g_lastM5BarTime))
     {
      UpdateM5Structure();
      UpdateM5Regime();
      CancelSetupOnRegimeLoss();
     }

   // 3. new M1 bar: refresh ATR / volatility / reference caches + turn-candle check
   if(IsNewBar(PERIOD_M1, g_lastM1BarTime))
      ProcessNewM1Bar(tick);

   // 4. live M1 pullback / turn-candle frozen-trigger engine
   ProcessLiveSetup(tick);

   // 5. open-position management: break-even -> ATR trailing
   ManagePositions(tick);

   // remember previous live prices (fresh-cross audit / logging)
   g_prevBid = tick.bid;
   g_prevAsk = tick.ask;

   // 6. throttled panel update
   UpdateEquityDrawdown();
   UpdatePanelThrottled(tick);
  }
//+------------------------------------------------------------------+
