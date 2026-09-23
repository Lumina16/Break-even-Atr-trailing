// ASTRA Guard 2.01 - autonomous XAUUSD M5->M1 pullback reclaim scalper.
// Research and execution code. No promised profitability. Compile and test in MT5.
#property strict
#property version   "2.01"
#property description "Autonomous XAUUSD M5-M1 pullback-reclaim scalper with broker-aware sizing and layered account protection."
#include <Trade/Trade.mqh>

enum ASTRA_MODE { TESTER_ONLY=0, DEMO_AND_TESTER=1, REVIEWED_LIVE=2 };
enum ASTRA_SETUP_STATE { SETUP_WAIT_PULLBACK=0, SETUP_WAIT_TURN=1, SETUP_WAIT_BREAK=2 };
enum ASTRA_TRADE_MANAGEMENT { TM_FIXED_TP_INVALIDATION=0, TM_BE_ATR_TRAIL=1, TM_PARTIAL_ATR_TRAIL=2 };
enum ASTRA_REJECT_CLASS { REJECT_NONE=0, REJECT_TEMPORARY=1, REJECT_STRUCTURAL=2, REJECT_EMERGENCY=3 };

input group "01 | Environment"
input ASTRA_MODE InpMode=DEMO_AND_TESTER;
input bool   InpLiveValidationAcknowledged=false;
input ulong  InpMagic=9022201;
input bool   InpAllowBuy=true;
input bool   InpAllowSell=true;

input group "02 | Per-trade risk (USD, including cent accounts; 0 disables a cap)"
input double InpRiskPercent=1.0;
input double InpHardRiskUSD=0.50;
input double InpMaxLots=0.02;
input double InpCommissionUSDPerLotRoundTrip=8.0;
input double InpSlippageReservePrice=0.10;
input double InpMaxDeviationPrice=0.10;
input double InpMinMarginLevel=300.0;
input double InpMaxMarginUsePercent=30.0;

input group "03 | Account protection (0 disables the corresponding limit)"
input double InpMaxDailyLossUSD=1.00;
input double InpMaxDailyLossPercent=2.0;
input double InpMaxWeeklyLossUSD=2.00;
input double InpMaxWeeklyLossPercent=5.0;
input double InpEquityFloorPercent=90.0;
input double InpMaxPeakDDPercent=8.0;
input int    InpMaxConsecutiveLosses=3;
input int    InpLossStreakCooldownMinutes=60;
input int    InpMaxTradesPerDay=6;
input int    InpMaxTradesPerHour=2;
input int    InpCooldownMinutes=5;
input double InpDailyProfitStopUSD=0.0;
input double InpWeeklyProfitStopUSD=0.0;

input group "04 | M5 regime (closed candles only)"
input int    InpTrendFastEMA=20;
input int    InpTrendSlowEMA=50;
input bool   InpRequireM5CloseBeyondFastEMA=false;
input bool   InpUseM5ADXFilter=false;
input int    InpADXPeriod=14;
input double InpMinM5ADX=18.0;
input bool   InpUseM5DIFilter=false;

input group "05 | M1 pullback / turn / live reclaim"
input int    InpM1ReferenceLookback=5;
input double InpM1PullbackATR=0.40;
input double InpTurnInvalidationATR=0.10;
input double InpMaxTurnCandleATR=0.0;
input int    InpSetupExpiryMinutes=15;
input int    InpMaxEntryAttemptsPerSetup=0;

input group "06 | Execution permissions (0 disables optional strategy filters)"
input int    InpATRPeriod=14;
input double InpMinATRPrice=0.15;
input double InpMaxATRPrice=15.0;
input double InpMaxSpreadPrice=0.35;
input double InpMaxSpreadATR=0.0;
input bool   InpUseSpikeEntryFilter=true;
input double InpSpikeATR=3.0;
input int    InpSpikePauseMinutes=15;
input bool   InpCloseOnSpike=true;
input int    InpMaxTickAgeSeconds=10;

input group "07 | TOP 3 trade management"
input ASTRA_TRADE_MANAGEMENT InpTradeManagement=TM_FIXED_TP_INVALIDATION;
input double InpStructurePaddingATR=0.15;
input double InpMaxInitialSL_ATR=2.50;
input double InpTakeProfitR=1.60;
input double InpMinimumNetRewardRisk=1.05;
input double InpBreakEvenAtR=1.00;
input double InpTrailStartR=1.20;
input double InpTrailATR=1.20;
input double InpStopStepATR=0.10;
input double InpPartialAtR=1.00;
input double InpPartialClosePercent=50.0;
input int    InpStallExitMinutes=8;
input int    InpMaxHoldMinutes=15;
input bool   InpExitOnM5TrendFlip=true;

input group "08 | Session (broker server clock; 0/false disables only optional policy)"
input bool   InpUseSessionFilter=true;
input bool   InpRequireFullHoldInsideSession=false;
input bool   InpRequireBrokerSessionMetadata=false;
input bool   InpCloseAtSessionEnd=true;
input int    InpSessionStartHour=7;
input int    InpSessionEndHour=20;
input int    InpSessionBufferMinutes=10;
input int    InpFridayCloseHour=18;
input int    InpBrokerCloseBufferMinutes=5;

input group "09 | Scheduled news"
input bool   InpUseNewsFilter=true;
input bool   InpNewsFailClosed=true;
input bool   InpRequireNewsClearForFullHold=false;
input bool   InpCloseOnNews=true;
input int    InpNewsBeforeMinutes=30;
input int    InpNewsAfterMinutes=20;
input bool   InpBlockMediumNews=false;
input string InpNewsCSV="ASTRA_USD_News.csv";
input bool   InpTesterSkipNews=false;

input group "10 | Display, diagnostics and tester"
input bool   InpShowPanel=true;
input bool   InpShowLevels=true;
input bool   InpShowTradeMarkers=true;
input bool   InpJournal=true;
input bool   InpPushNotifications=false;
input int    InpTesterMinTrades=0;

// ASTRA_PORTABLE_BEGIN
// Pure functions below are tested directly as C++ as well as used by this EA.
// No broker data, history, or trading execution is simulated by those tests.
double AG_Min(const double a,const double b) { return a<b ? a:b; }
double AG_Max(const double a,const double b) { return a>b ? a:b; }
double AG_Clamp(const double x,const double lo,const double hi)
{ return AG_Max(lo,AG_Min(hi,x)); }
double AG_Budget(const double equity,const double risk_pct,const double cash_cap,
                 const double day_left,const double week_left,const double floor_left)
{
   if(equity<=0 || risk_pct<=0 || cash_cap<=0) return 0;
   return AG_Max(0,AG_Min(AG_Min(equity*risk_pct/100.0,cash_cap),
                        AG_Min(AG_Min(day_left,week_left),floor_left)));
}
double AG_Lots(const double budget,const double risk_per_lot,const double minimum,
               const double step,const double maximum)
{
   if(budget<=0 || risk_per_lot<=0 || minimum<=0 || step<=0 || maximum<minimum) return 0;
   double raw=AG_Min(budget/risk_per_lot,maximum);
   if(raw+1e-12<minimum) return 0;
   double units=MathFloor((raw-minimum)/step+1e-9);
   double lots=minimum+units*step;
   if(lots*risk_per_lot>budget+1e-9) lots-=step;
   if(lots<minimum-1e-12) return 0;
   return lots;
}
double AG_Floor(const double initial,const double peak,const double floor_pct,const double dd_pct)
{ return AG_Max(floor_pct>0 ? initial*floor_pct/100.0:0,dd_pct>0 ? peak*(1.0-dd_pct/100.0):0); }
bool AG_Tightens(const int side,const double old_sl,const double candidate,const double min_step)
{
   if(candidate<=0 || min_step<=0) return false;
   if(old_sl<=0) return true;
   if(side==1) return candidate>=old_sl+min_step;
   if(side==-1) return candidate<=old_sl-min_step;
   return false;
}
bool AG_Overlap(const long begin,const long end,const long news_from,const long news_to)
{ return begin<=news_to && end>=news_from; }
bool AG_LiveCross(const int side,const double trigger,const double previous,const double current,bool &ready)
{
   if(trigger<=0 || current<=0 || previous<=0 || (side!=1 && side!=-1))return false;
   if(side==1 ? current<trigger:current>trigger)ready=true;
   return ready && (side==1 ? previous<trigger && current>=trigger:previous>trigger && current<=trigger);
}
bool AG_VolumeValid(const double volume,const double minimum,const double step,const double maximum)
{
   if(minimum<=0 || step<=0 || volume<minimum-1e-8 || volume>maximum+1e-8)return false;
   double units=(volume-minimum)/step;
   return MathAbs(units-MathRound(units))*step<=1e-8;
}
double AG_PartialLots(const double current,const double initial,const double percent,
                      const double minimum,const double step,const double maximum)
{
   if(current<=0 || initial<=0 || current>initial+1e-8 || percent<=0 || percent>=100)return 0;
   double wanted=AG_Min(current,initial)*percent/100.0;
   double cap=AG_Min(maximum,AG_Min(wanted,current-minimum));
   double close_lots=AG_Lots(cap,1.0,minimum,step,maximum);
   double remainder=current-close_lots;
   if(close_lots<=0 || close_lots>wanted+1e-8 || close_lots>=current ||
      !AG_VolumeValid(close_lots,minimum,step,maximum) ||
      !AG_VolumeValid(remainder,minimum,step,maximum))return 0;
   return close_lots;
}
// ASTRA_PORTABLE_END

struct AGSignal { int side; int setup; double invalidation; string label; };
struct AGNews { datetime from; datetime to; string name; };
struct AGTrade
{
   ulong id; bool ours; bool mixed; bool closed; int setup; int side; int management;
   datetime opened; datetime exited; double entered_volume; double exited_volume;
   double entry_value; double exit_value; double net; int exit_reason;
};
struct AGDiagnostics
{
   long m1_bars; long m5_bull; long m5_bear; long m5_neutral;
   long pullbacks; long turns; long turn_tolerance; long turn_invalidations;
   long expiries; long live_crosses; long entry_attempts; long fills;
   long reject_risk; long reject_spread; long reject_atr; long reject_spike;
   long reject_cooldown; long reject_hour; long reject_day; long reject_session;
   long reject_broker_session; long reject_news_actual; long reject_news_unavailable;
   long reject_stale; long reject_stop; long reject_max_stop; long reject_margin;
   long reject_foreign; long reject_broker; long reject_fill; long reject_ordercheck;
   long reject_send; long reject_postfill; long orders_sent; long partials;
   long partial_unavailable; long stop_modifications; long stop_modify_rejects;
   long exits_tp; long exits_sl; long exits_be_trail; long exits_maxhold;
   long exits_stall; long exits_flip; long exits_news; long exits_session;
   long exits_spike; long exits_emergency;
};

CTrade g_trade;
MqlRates g_m1[],g_m5[];
AGNews g_news[];
AGTrade g_ledger[];
ulong g_loggedIds[];
double g_loggedNet[];
AGDiagnostics g_diag;
int g_hFast=INVALID_HANDLE,g_hSlow=INVALID_HANDLE,g_hATR=INVALID_HANDLE,g_hADX=INVALID_HANDLE;
int g_lease=INVALID_HANDLE,g_journal=INVALID_HANDLE;
bool g_test=false,g_opt=false,g_ready=false,g_historyOK=false,g_historyDirty=true;
bool g_newsOK=false,g_newsBypass=false,g_newsBlocked=false,g_newsActualBlocked=false,g_newsUnavailable=false;
bool g_sessionOK=false,g_userSessionOK=false,g_brokerSessionOK=true,g_sessionMetadataWarning=false;
bool g_spreadOK=false,g_collapsed=false,g_stateOK=true,g_saveFailed=false;
bool g_prevNewsBlocked=false,g_prevNewsUnavailable=false,g_diagPrinted=false,g_legacyStateV1=false;
string g_stateKey="",g_stateFile="",g_ui="",g_status="Starting",g_newsReason="Not loaded";
double g_units=1.0,g_initial=0,g_peak=0,g_atr=0,g_adx=0,g_plus=0,g_minus=0;
double g_fast=0,g_slow=0,g_dayNet=0,g_weekNet=0,g_dayBase=0,g_weekBase=0;
double g_minLotRisk=0,g_lastBudget=0,g_initialR=0,g_openRiskBudget=0,g_openFeePerLot=0,g_referenceSL=0;
double g_initialVolume=0,g_guardSL=0,g_turnCandleRange=0;
bool g_partialDone=true;
int g_openManagement=-1;
ulong g_positionId=0;
int g_positionSetup=0,g_bias=0,g_pause=0,g_hardKill=0;
int g_dailyEntries=0,g_hourEntries=0,g_lossStreak=0,g_lossStreakCooldownStreak=0,g_historyOffset=0,g_x=12,g_y=24;
datetime g_startTime=0,g_bar=0,g_lastHistory=0,g_lastNewsFetch=0,g_newsValidFrom=0,g_newsValidTo=0;
datetime g_dayLock=0,g_weekLock=0,g_ackStreak=0,g_lastExit=0,g_lastEntry=0,g_spikeUntil=0;
datetime g_lossStreakCooldownUntil=0,g_dayProfitLock=0,g_weekProfitLock=0;
datetime g_lastCloseAttempt=0,g_lastModify=0,g_lastFlush=0,g_lastJournalExit=0;
datetime g_lastTicketClose=0;
ulong g_lastClosedTicket=0;
ASTRA_SETUP_STATE g_setupState=SETUP_WAIT_PULLBACK;
int g_setupSide=0,g_setupAttempts=0;
datetime g_setupStart=0,g_setupAfter=0,g_crossQuoteTime=0;
double g_reference=0,g_invalidation=0,g_trigger=0,g_pullbackDepth=0,g_previousQuote=0;
bool g_crossReady=false;

string EntryStateName();
string ManagementModeName(const int mode);
int CountOwned();

// Account values are normalized to USD. A cent account is explicitly converted;
// unsupported currencies are rejected during initialization.
double USD(const double account_units) { return account_units/g_units; }
double Money(const double usd) { return usd*g_units; }
double Equity() { return USD(AccountInfoDouble(ACCOUNT_EQUITY)); }
double Balance() { return USD(AccountInfoDouble(ACCOUNT_BALANCE)); }
datetime Now() { return g_test ? TimeCurrent() : TimeTradeServer(); }
datetime DayStart(const datetime t)
{ MqlDateTime d; TimeToStruct(t,d); d.hour=0; d.min=0; d.sec=0; return StructToTime(d); }
datetime WeekStart(const datetime t)
{ MqlDateTime d; TimeToStruct(t,d); return DayStart(t)-((d.day_of_week+6)%7)*86400; }
uint Hash(const string value)
{
   uint h=2166136261;
   for(int i=0;i<StringLen(value);i++) h=(h^(uint)StringGetCharacter(value,i))*16777619;
   return h;
}
string SetupName(const int setup) { return setup==1 ? "PullbackReclaim":(setup<0 ? "Legacy":"None"); }

bool Exists(const string name) { return !g_test && GlobalVariableCheck(g_stateKey+name); }
double Load(const string name,const double fallback)
{ if(Exists(name))return GlobalVariableGet(g_stateKey+name); return fallback; }
void Save(const string name,const double value)
{
   if(!g_test && GlobalVariableSet(g_stateKey+name,value)==0)
   { g_saveFailed=true; g_stateOK=false; }
}

bool RestorePersistentState()
{
   if(g_test || !FileIsExist(g_stateFile,FILE_COMMON))return true;
   int f=FileOpen(g_stateFile,FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON,';');
   if(f==INVALID_HANDLE)return false;
   string signature=FileReadString(f),version=FileReadString(f);
   if(signature!="ASTRA_STATE" || (version!="1" && version!="2")) { FileClose(f); return false; }
   g_legacyStateV1=version=="1";
   bool initial=false,peak=false,start=false,hard=false;
   while(!FileIsEnding(f))
   {
      string name=FileReadString(f);
      if(name=="" && FileIsEnding(f))break;
      string text_value=FileReadString(f);
      if(text_value=="" || StringLen(name)>16) { FileClose(f); return false; }
      double value=StringToDouble(text_value);
      if(!MathIsValidNumber(value)) { FileClose(f); return false; }
      if(name=="initial")initial=value>0;
      if(name=="peak")peak=value>0;
      if(name=="start")start=value>0;
      if(name=="hard")hard=true;
      if(!Exists(name))Save(name,value);
   }
   FileClose(f);
   return initial && peak && start && hard;
}
bool PersistSnapshot()
{
   if(g_test)return true;
   string names[]={"initial","peak","start","pause","hard","daylock","weeklock","dayprofit","weekprofit",
      "ack","spike","loss_cooldown","loss_streak","x","y","small","pid_hi","pid_lo","initial_r",
      "open_budget","setup","fee","ref_sl","entry_volume","partial_done","management","guard_sl"};
   string temp=g_stateFile+".tmp";
   int f=FileOpen(temp,FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,';');
   if(f==INVALID_HANDLE)return false;
   bool ok=FileWrite(f,"ASTRA_STATE","2")>0;
   for(int i=0;i<ArraySize(names);i++)
      if(FileWrite(f,names[i],DoubleToString(Load(names[i],0),16))==0)ok=false;
   FileFlush(f); FileClose(f);
   if(!ok)return false;
   return FileMove(temp,FILE_COMMON,g_stateFile,FILE_REWRITE|FILE_COMMON);
}
void FlushProtection()
{
   if(g_test)return;
   GlobalVariablesFlush();
   g_stateOK=!g_saveFailed && PersistSnapshot();
   if(!g_stateOK)
   {
      // A live persistence failure is an emergency, not an ordinary market pause.
      g_hardKill=5;
      Print("ASTRA: protection state could not be saved; trading hard-locked.");
   }
}
void SaveState(const bool flush=false)
{
   Save("initial",g_initial); Save("peak",g_peak); Save("start",(double)g_startTime);
   Save("pause",g_pause); Save("hard",g_hardKill);
   Save("daylock",(double)g_dayLock); Save("weeklock",(double)g_weekLock);
   Save("dayprofit",(double)g_dayProfitLock); Save("weekprofit",(double)g_weekProfitLock);
   Save("ack",(double)g_ackStreak); Save("spike",(double)g_spikeUntil);
   Save("loss_cooldown",(double)g_lossStreakCooldownUntil); Save("loss_streak",g_lossStreakCooldownStreak);
   Save("x",g_x); Save("y",g_y); Save("small",g_collapsed ? 1:0);
   if(flush)FlushProtection();
}
void SavePosition()
{
   Save("pid_hi",(double)(g_positionId>>32)); Save("pid_lo",(double)(g_positionId & (ulong)0xFFFFFFFF));
   Save("initial_r",g_initialR); Save("open_budget",g_openRiskBudget); Save("setup",g_positionSetup);
   Save("fee",g_openFeePerLot); Save("ref_sl",g_referenceSL); Save("entry_volume",g_initialVolume);
   Save("partial_done",g_partialDone ? 1:0); Save("management",g_openManagement); Save("guard_sl",g_guardSL);
   FlushProtection();
}
void Journal(const string event_name,const string detail,const int setup=0,
             const double expected=0,const double actual=0,const double sl=0,
             const double tp=0,const double volume=0,const double risk=0)
{
   Print("ASTRA | ",event_name," | ",detail);
   if(g_journal==INVALID_HANDLE)return;
   MqlTick q; ZeroMemory(q); SymbolInfoTick(_Symbol,q);
   FileWrite(g_journal,TimeToString(Now(),TIME_DATE|TIME_SECONDS),event_name,SetupName(setup),detail,
      expected,actual,sl,tp,volume,risk,g_lastBudget,g_minLotRisk,q.ask-q.bid,g_atr,
      EntryStateName(),g_trigger,g_invalidation,
      ManagementModeName(CountOwned()>0 ? g_openManagement:(int)InpTradeManagement),Balance(),Equity(),
      g_peak>0 ? 100*(g_peak-Equity())/g_peak:0,
      !InpUseNewsFilter ? "NEWS_OFF":(g_newsBypass ? "NEWS_BYPASSED":
      (g_newsActualBlocked ? "NEWS_BLACKOUT":(g_newsUnavailable ? "NEWS_UNAVAILABLE":"NEWS_CLEAR"))));
   FileFlush(g_journal);
}
void Status(const string text_value)
{ if(g_status!=text_value) { g_status=text_value; Journal("STATUS",text_value); } }
void Notify(const string message)
{ if(InpPushNotifications && !g_test)SendNotification("ASTRA: "+message); }
void Emergency(const int code,const string reason)
{
   if(g_hardKill!=0)return;
   g_hardKill=code; Journal("HARD_LOCK",reason); Notify(reason); ResetEntrySetup(reason); SaveState(true);
}
void PauseManual(const string reason)
{
   if(g_pause!=0)return;
   g_pause=1; Journal("MANUAL_PAUSE",reason); ResetEntrySetup(reason); SaveState(true);
}
bool ModeAllowsEntries()
{
   if(g_test)return true;
   if(InpMode==TESTER_ONLY)return false;
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_REAL)return true;
   return InpMode==REVIEWED_LIVE && InpLiveValidationAcknowledged;
}
bool CanTrade()
{
   return (g_test || TerminalInfoInteger(TERMINAL_CONNECTED)) &&
          TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_EXPERT);
}
int LedgerIndex(const ulong id)
{ for(int i=0;i<ArraySize(g_ledger);i++)if(g_ledger[i].id==id)return i; return -1; }
bool SelectedIsOurs()
{
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol)return false;
   ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   int i=LedgerIndex(id);
   if(i>=0 && g_ledger[i].mixed)return false;
   return (i>=0 && g_ledger[i].ours) || (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}
bool PositionIdOpen(const ulong id)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)>0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER)==id)return true;
   return false;
}
int CountOwned()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)>0 && SelectedIsOurs())count++;
   return count;
}
int CountForeignSameSymbolPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && !SelectedIsOurs())count++;
   }
   return count;
}
int CountForeignSameSymbolOrders()
{
   int count=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket>0 && OrderGetString(ORDER_SYMBOL)==_Symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagic)count++;
   }
   return count;
}
int CountForeignSameSymbolExposure()
{ return CountForeignSameSymbolPositions()+CountForeignSameSymbolOrders(); }
int CountForeign()
{ return CountForeignSameSymbolExposure(); }

void CountExitReason(const string reason)
{
   if(StringFind(reason,"Maximum hold")>=0)g_diag.exits_maxhold++;
   else if(StringFind(reason,"Stalled")>=0)g_diag.exits_stall++;
   else if(StringFind(reason,"trend")>=0 || StringFind(reason,"Trend")>=0)g_diag.exits_flip++;
   else if(StringFind(reason,"News")>=0 || StringFind(reason,"news")>=0)g_diag.exits_news++;
   else if(StringFind(reason,"Session")>=0 || StringFind(reason,"session")>=0)g_diag.exits_session++;
   else if(StringFind(reason,"spike")>=0 || StringFind(reason,"Spike")>=0)g_diag.exits_spike++;
   else if(StringFind(reason,"Risk")>=0 || StringFind(reason,"Protection")>=0 || StringFind(reason,"emergency")>=0)
      g_diag.exits_emergency++;
}
bool CloseTicket(const ulong ticket,const string reason)
{
   if(!CanTrade()) { Status("Cannot send exit: trading/connection unavailable"); return false; }
   if(!PositionSelectByTicket(ticket) || !SelectedIsOurs())return false;
   if(g_lastClosedTicket==ticket && g_lastTicketClose==Now())return false;
   g_lastClosedTicket=ticket; g_lastTicketClose=Now(); g_trade.SetTypeFillingBySymbol(_Symbol);
   bool sent=g_trade.PositionClose(ticket,(ulong)MathCeil(InpMaxDeviationPrice/_Point));
   uint ret=g_trade.ResultRetcode();
   bool ok=sent && (ret==TRADE_RETCODE_DONE || ret==TRADE_RETCODE_DONE_PARTIAL);
   Journal(ok ? "EXIT_REQUEST":"EXIT_REJECTED",reason+" | "+g_trade.ResultRetcodeDescription());
   if(ok)CountExitReason(reason);
   g_historyDirty=true; return ok;
}
void Flatten(const string reason)
{
   datetime now=Now(); if(g_lastCloseAttempt==now)return; g_lastCloseAttempt=now;
   for(int i=PositionsTotal()-1;i>=0;i--)
   { ulong t=PositionGetTicket(i); if(t>0 && SelectedIsOurs())CloseTicket(t,reason); }
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t>0 && (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagic && OrderGetString(ORDER_SYMBOL)==_Symbol && CanTrade())
      { g_trade.OrderDelete(t); Journal("CANCEL_ORDER",g_trade.ResultRetcodeDescription()); }
   }
}

// History is grouped by POSITION_IDENTIFIER. Deals and partial reductions never
// inflate completed-trade statistics.
bool RefreshHistory()
{
   datetime now=Now(),day=DayStart(now),week=WeekStart(now);
   datetime from=(datetime)MathMin((double)g_startTime,(double)week);
   if(!HistorySelect(from,now)) { g_historyOK=false; return false; }
   ArrayResize(g_ledger,0); double daily=0,weekly=0;
   g_dailyEntries=0; g_hourEntries=0; g_lastExit=0; g_lastEntry=0;
   int total=HistoryDealsTotal();
   for(int j=0;j<total;j++)
   {
      ulong deal=HistoryDealGetTicket(j); if(deal==0)continue;
      datetime when=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
      double cash=USD(HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_COMMISSION)+
                      HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_FEE));
      bool cash_flow=type==DEAL_TYPE_BALANCE || type==DEAL_TYPE_CREDIT || type==DEAL_TYPE_BONUS || type==DEAL_TYPE_CORRECTION;
      if(!cash_flow) { if(when>=day)daily+=cash; if(when>=week)weekly+=cash; }
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol)continue;
      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      int index=LedgerIndex(id);
      if(index<0)
      { index=ArraySize(g_ledger); ArrayResize(g_ledger,index+1); ZeroMemory(g_ledger[index]); g_ledger[index].id=id; }
      double volume=HistoryDealGetDouble(deal,DEAL_VOLUME),price=HistoryDealGetDouble(deal,DEAL_PRICE);
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      bool our_deal=(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)==InpMagic;
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
      {
         bool had_entry=g_ledger[index].entered_volume>0;
         if(had_entry && our_deal!=g_ledger[index].ours)g_ledger[index].mixed=true;
         if(entry==DEAL_ENTRY_INOUT)g_ledger[index].mixed=true;
         if(our_deal)g_ledger[index].ours=true;
         if(!had_entry)
         {
            g_ledger[index].opened=when; g_ledger[index].side=type==DEAL_TYPE_BUY ? 1:-1;
            string comment=HistoryDealGetString(deal,DEAL_COMMENT);
            if(our_deal)
            {
               g_ledger[index].setup=StringFind(comment,"AG1 v2")>=0 ? 1:-1;
               if(StringFind(comment,"BE+ATR")>=0)g_ledger[index].management=TM_BE_ATR_TRAIL;
               else if(StringFind(comment,"PARTIAL+ATR")>=0)g_ledger[index].management=TM_PARTIAL_ATR_TRAIL;
               else g_ledger[index].management=TM_FIXED_TP_INVALIDATION;
            }
         }
         g_ledger[index].entered_volume+=volume; g_ledger[index].entry_value+=price*volume;
      }
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
      {
         g_ledger[index].exited=when; g_ledger[index].exited_volume+=volume;
         g_ledger[index].exit_value+=price*volume;
         g_ledger[index].exit_reason=(int)HistoryDealGetInteger(deal,DEAL_REASON);
      }
      g_ledger[index].net+=cash;
   }
   for(int j=0;j<total;j++)
   {
      ulong deal=HistoryDealGetTicket(j);
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
      if(type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL || type==DEAL_TYPE_BALANCE || type==DEAL_TYPE_CREDIT ||
         type==DEAL_TYPE_BONUS || type==DEAL_TYPE_CORRECTION)continue;
      int index=LedgerIndex((ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID));
      if(index>=0)g_ledger[index].net+=USD(HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_COMMISSION)+
         HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_FEE));
   }
   g_dayBase=Balance()-daily; g_weekBase=Balance()-weekly;
   double floating=USD(AccountInfoDouble(ACCOUNT_EQUITY)-AccountInfoDouble(ACCOUNT_BALANCE)-AccountInfoDouble(ACCOUNT_CREDIT));
   g_dayNet=daily+floating; g_weekNet=weekly+floating;
   for(int i=0;i<ArraySize(g_ledger);i++)
   {
      if(!g_ledger[i].ours)continue;
      if(g_ledger[i].mixed && PositionIdOpen(g_ledger[i].id))Emergency(6,"Mixed netting position: manual review required");
      if(g_ledger[i].opened>=day)g_dailyEntries++;
      if(g_ledger[i].opened>now-3600)g_hourEntries++;
      if(g_ledger[i].opened>g_lastEntry)g_lastEntry=g_ledger[i].opened;
      g_ledger[i].closed=g_ledger[i].entered_volume>0 &&
         g_ledger[i].exited_volume+1e-8>=g_ledger[i].entered_volume && !PositionIdOpen(g_ledger[i].id);
      if(g_ledger[i].closed && g_ledger[i].exited>g_lastExit)g_lastExit=g_ledger[i].exited;
   }
   for(int i=1;i<ArraySize(g_ledger);i++)
   {
      AGTrade item=g_ledger[i]; int j=i-1;
      while(j>=0 && g_ledger[j].exited>item.exited) { g_ledger[j+1]=g_ledger[j]; j--; }
      g_ledger[j+1]=item;
   }
   g_lossStreak=0;
   for(int i=ArraySize(g_ledger)-1;i>=0;i--)
   {
      if(!g_ledger[i].ours || !g_ledger[i].closed || g_ledger[i].mixed)continue;
      if(g_ledger[i].exited<=g_ackStreak)break;
      if(g_ledger[i].net < -0.000001)g_lossStreak++; else break;
   }
   g_historyOK=true; g_historyDirty=false; g_lastHistory=now; return true;
}

double DailyLimit()
{
   double limit=1.0e100;
   if(InpMaxDailyLossUSD>0)limit=MathMin(limit,InpMaxDailyLossUSD);
   if(InpMaxDailyLossPercent>0)limit=MathMin(limit,MathMax(0,g_dayBase)*InpMaxDailyLossPercent/100.0);
   return limit==1.0e100 ? 0:limit;
}
double WeeklyLimit()
{
   double limit=1.0e100;
   if(InpMaxWeeklyLossUSD>0)limit=MathMin(limit,InpMaxWeeklyLossUSD);
   if(InpMaxWeeklyLossPercent>0)limit=MathMin(limit,MathMax(0,g_weekBase)*InpMaxWeeklyLossPercent/100.0);
   return limit==1.0e100 ? 0:limit;
}
double RiskFloor()
{ return AG_Floor(g_initial,g_peak,InpEquityFloorPercent,InpMaxPeakDDPercent); }
double TradeRiskBudget()
{
   double budget=1.0e100;
   if(InpRiskPercent>0)budget=MathMin(budget,Equity()*InpRiskPercent/100.0);
   if(InpHardRiskUSD>0)budget=MathMin(budget,InpHardRiskUSD);
   return budget==1.0e100 ? 0:MathMax(0,budget);
}
double Budget() { return TradeRiskBudget(); }
void UpdateAutomaticLocks()
{
   datetime now=Now(),day=DayStart(now),week=WeekStart(now);
   if(g_dayLock!=0 && g_dayLock!=day) { Journal("DAILY_LOCK_END","New broker day; daily lock cleared"); g_dayLock=0; SaveState(false); }
   if(g_weekLock!=0 && g_weekLock!=week) { Journal("WEEKLY_LOCK_END","New broker week; weekly lock cleared"); g_weekLock=0; SaveState(false); }
   if(g_dayProfitLock!=0 && g_dayProfitLock!=day) { Journal("DAY_PROFIT_LOCK_END","New broker day; profit lock cleared"); g_dayProfitLock=0; SaveState(false); }
   if(g_weekProfitLock!=0 && g_weekProfitLock!=week) { Journal("WEEK_PROFIT_LOCK_END","New broker week; profit lock cleared"); g_weekProfitLock=0; SaveState(false); }
   if((InpMaxConsecutiveLosses<=0 || InpLossStreakCooldownMinutes<=0) && g_lossStreakCooldownUntil>0)
   { Journal("LOSS_STREAK_COOLDOWN_END","Loss-streak protection disabled by input"); g_lossStreakCooldownUntil=0; SaveState(false); }
   if(g_lossStreakCooldownUntil>0 && now>=g_lossStreakCooldownUntil)
   { Journal("LOSS_STREAK_COOLDOWN_END","Automatic loss-streak cooldown expired"); g_lossStreakCooldownUntil=0; SaveState(true); }
   if(InpMaxConsecutiveLosses>0 && InpLossStreakCooldownMinutes>0 && g_lossStreak>=InpMaxConsecutiveLosses &&
      g_lossStreakCooldownUntil==0 && g_lossStreak!=g_lossStreakCooldownStreak)
   {
      g_lossStreakCooldownStreak=g_lossStreak; g_lossStreakCooldownUntil=now+InpLossStreakCooldownMinutes*60;
      Journal("LOSS_STREAK_COOLDOWN_START",StringFormat("Loss streak %d; resumes at %s",g_lossStreak,TimeToString(g_lossStreakCooldownUntil,TIME_DATE|TIME_SECONDS)));
      SaveState(true);
   }
}
void UpdateRisk()
{
   double eq=Equity(); if(eq>g_peak) { g_peak=eq; Save("peak",g_peak); }
   g_dayNet=eq-USD(AccountInfoDouble(ACCOUNT_CREDIT))-g_dayBase;
   g_weekNet=eq-USD(AccountInfoDouble(ACCOUNT_CREDIT))-g_weekBase;
   datetime day=DayStart(Now()),week=WeekStart(Now());
   if(InpEquityFloorPercent>0 && eq<=g_initial*InpEquityFloorPercent/100.0)Emergency(3,"Initial-equity floor reached");
   if(InpMaxPeakDDPercent>0 && eq<=g_peak*(1-InpMaxPeakDDPercent/100.0))Emergency(4,"Peak drawdown limit reached");
   UpdateAutomaticLocks();
   double dl=DailyLimit(),wl=WeeklyLimit();
   if(dl<=0 && g_dayLock!=0) { Journal("DAILY_LOCK_END","Daily loss protection disabled by input"); g_dayLock=0; SaveState(false); }
   if(wl<=0 && g_weekLock!=0) { Journal("WEEKLY_LOCK_END","Weekly loss protection disabled by input"); g_weekLock=0; SaveState(false); }
   if(InpDailyProfitStopUSD<=0 && g_dayProfitLock!=0) { Journal("DAY_PROFIT_LOCK_END","Daily profit stop disabled by input"); g_dayProfitLock=0; SaveState(false); }
   if(InpWeeklyProfitStopUSD<=0 && g_weekProfitLock!=0) { Journal("WEEK_PROFIT_LOCK_END","Weekly profit stop disabled by input"); g_weekProfitLock=0; SaveState(false); }
   if(g_historyOK && dl>0 && g_dayNet<=-dl && g_dayLock!=day)
   { g_dayLock=day; Journal("DAILY_LOCK_START","Account daily loss limit reached"); SaveState(true); }
   if(g_historyOK && wl>0 && g_weekNet<=-wl && g_weekLock!=week)
   { g_weekLock=week; Journal("WEEKLY_LOCK_START","Account weekly loss limit reached"); SaveState(true); }
   if(InpDailyProfitStopUSD>0 && g_dayNet>=InpDailyProfitStopUSD && g_dayProfitLock!=day)
   { g_dayProfitLock=day; Journal("DAY_PROFIT_LOCK_START","Daily profit stop reached"); SaveState(true); }
   if(InpWeeklyProfitStopUSD>0 && g_weekNet>=InpWeeklyProfitStopUSD && g_weekProfitLock!=week)
   { g_weekProfitLock=week; Journal("WEEK_PROFIT_LOCK_START","Weekly profit stop reached"); SaveState(true); }
   g_lastBudget=TradeRiskBudget();
}

void AddNews(const datetime begin,const datetime end,const string name)
{ int n=ArraySize(g_news); ArrayResize(g_news,n+1); g_news[n].from=begin; g_news[n].to=end; g_news[n].name=name; }
void SortMergeNews()
{
   for(int i=1;i<ArraySize(g_news);i++)
   { AGNews item=g_news[i]; int j=i-1; while(j>=0 && g_news[j].from>item.from){g_news[j+1]=g_news[j];j--;} g_news[j+1]=item; }
   int used=0;
   for(int i=0;i<ArraySize(g_news);i++)
   {
      if(used>0 && g_news[i].from<=g_news[used-1].to) { if(g_news[i].to>g_news[used-1].to)g_news[used-1].to=g_news[i].to; }
      else { g_news[used]=g_news[i]; used++; }
   }
   ArrayResize(g_news,used);
}
bool LoadNewsCSV()
{
   int file=FileOpen(InpNewsCSV,FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON,';');
   if(file==INVALID_HANDLE) { g_newsReason="Missing historical news CSV"; return false; }
   bool header=false,bad=false; ArrayResize(g_news,0);
   while(!FileIsEnding(file))
   {
      string kind=FileReadString(file); if(kind=="" && FileIsEnding(file))break;
      string a=FileReadString(file),b=FileReadString(file),c=FileReadString(file),d=FileReadString(file);
      if(kind=="COVERAGE" && !header)
      {
         g_newsValidFrom=StringToTime(a); g_newsValidTo=StringToTime(b);
         header=c=="SERVER" && g_newsValidFrom>0 && g_newsValidTo>g_newsValidFrom;
         if(!header)bad=true;
      }
      else if(kind=="EVENT")
      {
         datetime t=StringToTime(a); int importance=(int)StringToInteger(b),exact=(int)StringToInteger(c);
         if(!header || t<g_newsValidFrom || t>g_newsValidTo || importance<0 || importance>3 || (exact!=0 && exact!=1))
         { bad=true; break; }
         if(importance<3 && !(InpBlockMediumNews && importance==2))continue;
         if(exact==1)AddNews(t-InpNewsBeforeMinutes*60,t+InpNewsAfterMinutes*60,d);
         else AddNews(DayStart(t),DayStart(t)+86399,d+" [time uncertain]");
      }
      else { bad=true; break; }
   }
   FileClose(file);
   if(bad || !header) { g_newsReason="Invalid news CSV/coverage"; return false; }
   // Empty matching-event windows are valid when coverage is valid.
   SortMergeNews(); g_newsReason="Historical news CSV loaded"; return true;
}
void RefreshNativeNews()
{
   datetime now=Now(); if(g_lastNewsFetch>0 && now-g_lastNewsFetch<60)return; g_lastNewsFetch=now;
   MqlCalendarValue values[]; ResetLastError();
   int n=CalendarValueHistory(values,DayStart(now)-86400,DayStart(now)+3*86400,"","USD");
   int error=GetLastError();
   if(n<0 || error!=0) { g_newsOK=false; g_newsReason=StringFormat("USD calendar unavailable (%d)",error); return; }
   ArrayResize(g_news,0);
   for(int i=0;i<n;i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id,event)) { g_newsOK=false; g_newsReason="Calendar event detail unavailable"; return; }
      int importance=(int)event.importance; if(importance<3 && !(InpBlockMediumNews && importance==2))continue;
      datetime t=values[i].time;
      if(event.time_mode==CALENDAR_TIMEMODE_DATETIME)AddNews(t-InpNewsBeforeMinutes*60,t+InpNewsAfterMinutes*60,event.name);
      else AddNews(DayStart(t),DayStart(t)+86399,event.name+" [time uncertain]");
   }
   g_newsValidFrom=DayStart(now)-86400; g_newsValidTo=DayStart(now)+3*86400;
   SortMergeNews(); g_newsOK=true; g_newsReason="USD calendar ready";
}
bool NewsClear(const datetime now,const int horizon_seconds,string &why)
{
   g_newsActualBlocked=false; g_newsUnavailable=false;
   if(!InpUseNewsFilter) { why="NEWS OFF"; return true; }
   if(g_newsBypass) { why="TESTER ONLY: NEWS BYPASSED"; return true; }
   int horizon=InpRequireNewsClearForFullHold ? horizon_seconds:0;
   if(!g_newsOK) { g_newsUnavailable=true; why=g_newsReason; return !InpNewsFailClosed; }
   if(now-InpNewsAfterMinutes*60<g_newsValidFrom || now+horizon+InpNewsBeforeMinutes*60>g_newsValidTo)
   { g_newsUnavailable=true; why="News data does not cover this date"; return !InpNewsFailClosed; }
   if(!g_test && now-g_lastNewsFetch>120)
   { g_newsUnavailable=true; why="News cache stale"; return !InpNewsFailClosed; }
   int low=0,high=ArraySize(g_news)-1,index=-1;
   while(low<=high)
   { int mid=(low+high)/2; if(g_news[mid].from<=now+horizon){index=mid;low=mid+1;} else high=mid-1; }
   if(index>=0 && AG_Overlap((long)now,(long)now+horizon,(long)g_news[index].from,(long)g_news[index].to))
   { g_newsActualBlocked=true; why="News: "+g_news[index].name; return false; }
   why=g_test ? "Historical news clear":"USD news clear"; return true;
}

bool BrokerSessionClear(const datetime now,const int horizon_seconds)
{
   MqlDateTime d; TimeToStruct(now,d); int seconds=d.hour*3600+d.min*60+d.sec;
   bool saw=false;
   for(uint i=0;i<20;i++)
   {
      datetime begin=0,end=0;
      if(!SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)d.day_of_week,i,begin,end))break;
      saw=true; int from=(int)((long)begin%86400),to=(int)((long)end%86400);
      if(to<=from)to+=86400;
      if(seconds>=from && seconds+horizon_seconds<to-InpBrokerCloseBufferMinutes*60)return true;
   }
   if(!saw)
   {
      g_brokerSessionOK=false;
      if(!g_sessionMetadataWarning)
      { g_sessionMetadataWarning=true; Journal("BROKER_SESSION_METADATA_UNAVAILABLE","Using configured session fallback"); }
      return !InpRequireBrokerSessionMetadata;
   }
   g_brokerSessionOK=false; return false;
}
bool SessionClear(const datetime now,const int horizon_seconds)
{
   g_userSessionOK=false; g_brokerSessionOK=true;
   if(!InpUseSessionFilter) { g_userSessionOK=true; return BrokerSessionClear(now,horizon_seconds); }
   MqlDateTime d; TimeToStruct(now,d);
   if(d.day_of_week==0 || d.day_of_week==6)return false;
   int seconds=d.hour*3600+d.min*60+d.sec;
   int from=InpSessionStartHour*3600+InpSessionBufferMinutes*60;
   int to=InpSessionEndHour*3600-InpSessionBufferMinutes*60;
   if(d.day_of_week==5)to=(int)MathMin(to,InpFridayCloseHour*3600-InpSessionBufferMinutes*60);
   if(seconds<from || seconds+horizon_seconds>=to)return false;
   g_userSessionOK=true;
   return BrokerSessionClear(now,horizon_seconds);
}

bool ReadBufferValue(const int handle,const int buffer,const int shift,double &value)
{
   double a[]; if(CopyBuffer(handle,buffer,shift,1,a)!=1 || !MathIsValidNumber(a[0]) || a[0]==EMPTY_VALUE)return false;
   value=a[0]; return true;
}
double CandleRange(const int shift) { return g_m1[shift].high-g_m1[shift].low; }
double Lowest(const int from,const int count)
{ double v=g_m1[from].low; for(int i=from+1;i<from+count;i++)v=MathMin(v,g_m1[i].low); return v; }
double Highest(const int from,const int count)
{ double v=g_m1[from].high; for(int i=from+1;i<from+count;i++)v=MathMax(v,g_m1[i].high); return v; }
int M5BaseDirection()
{
   if(!MathIsValidNumber(g_fast) || !MathIsValidNumber(g_slow) || g_fast==g_slow)return 0;
   return g_fast>g_slow ? 1:-1;
}
int M5Direction()
{
   int side=M5BaseDirection(); if(side==0)return 0;
   if(InpRequireM5CloseBeyondFastEMA && ((side==1 && g_m5[0].close<=g_fast)||(side==-1 && g_m5[0].close>=g_fast)))return 0;
   if(InpUseM5ADXFilter && g_adx<InpMinM5ADX)return 0;
   if(InpUseM5DIFilter && ((side==1 && g_plus<=g_minus)||(side==-1 && g_minus<=g_plus)))return 0;
   return side;
}
bool BuildSnapshot()
{
   g_ready=false;
   if(BarsCalculated(g_hSlow)<InpTrendSlowEMA+5 || BarsCalculated(g_hFast)<InpTrendFastEMA+5 || BarsCalculated(g_hATR)<InpATRPeriod+5)return false;
   bool adx_needed=InpUseM5ADXFilter || InpUseM5DIFilter;
   if(adx_needed && BarsCalculated(g_hADX)<2*InpADXPeriod+5)return false;
   int needed=InpM1ReferenceLookback+2; ArraySetAsSeries(g_m1,true); ArraySetAsSeries(g_m5,true);
   if(CopyRates(_Symbol,PERIOD_M1,0,needed,g_m1)!=needed || CopyRates(_Symbol,PERIOD_M5,1,1,g_m5)!=1)return false;
   if(!ReadBufferValue(g_hATR,0,1,g_atr) || !ReadBufferValue(g_hFast,0,1,g_fast) || !ReadBufferValue(g_hSlow,0,1,g_slow) || g_atr<=0)return false;
   g_adx=0; g_plus=0; g_minus=0;
   if(adx_needed && (!ReadBufferValue(g_hADX,0,1,g_adx)||!ReadBufferValue(g_hADX,1,1,g_plus)||!ReadBufferValue(g_hADX,2,1,g_minus)))return false;
   g_bias=M5Direction(); g_ready=true; return true;
}
string DirectionName() { return g_bias==1 ? "BULL":(g_bias==-1 ? "BEAR":"NEUTRAL"); }
string EntryStateName()
{ if(g_setupState==SETUP_WAIT_TURN)return "WAIT_TURN"; if(g_setupState==SETUP_WAIT_BREAK)return "WAIT_BREAK"; return "WAIT_PULLBACK"; }
string ManagementModeName(const int mode)
{ if(mode==TM_FIXED_TP_INVALIDATION)return "FIXED"; if(mode==TM_BE_ATR_TRAIL)return "BE+ATR"; if(mode==TM_PARTIAL_ATR_TRAIL)return "PARTIAL+ATR"; return "UNKNOWN"; }
void ClearCrossObservation() { g_crossReady=false; g_previousQuote=0; g_crossQuoteTime=0; }
void ResetEntrySetup(const string reason,const bool block_current_bar=true)
{
   bool active=g_setupState!=SETUP_WAIT_PULLBACK;
   g_setupState=SETUP_WAIT_PULLBACK; g_setupSide=0; g_setupStart=0; g_setupAttempts=0;
   g_reference=0; g_invalidation=0; g_trigger=0; g_pullbackDepth=0; g_turnCandleRange=0; g_minLotRisk=0;
   ClearCrossObservation(); if(block_current_bar)g_setupAfter=g_bar;
   if(active && reason!="")Journal("SETUP_RESET",reason);
}
bool ExpireEntrySetup()
{
   if(InpSetupExpiryMinutes>0 && g_setupStart>0 && Now()-g_setupStart>=InpSetupExpiryMinutes*60)
   { g_diag.expiries++; ResetEntrySetup("Setup expired; fresh pullback required"); Journal("SETUP_EXPIRED","Setup lifetime elapsed",1); return true; }
   return false;
}
bool ArmTurnTrigger()
{
   g_turnCandleRange=CandleRange(1);
   if(InpMaxTurnCandleATR>0 && g_turnCandleRange>InpMaxTurnCandleATR*g_atr)
   { Journal("TURN_REJECTED","Turn candle exceeds configured ATR quality limit",1); return false; }
   g_trigger=g_setupSide==1 ? g_m1[1].high:g_m1[1].low; g_setupState=SETUP_WAIT_BREAK; ClearCrossObservation();
   MqlTick q;
   if(QuoteFresh(q))
   {
      // Chart highs/lows are Bid-derived. Bid is deliberately used for both directions.
      g_previousQuote=q.bid; g_crossReady=g_setupSide==1 ? q.bid<g_trigger:q.bid>g_trigger; g_crossQuoteTime=q.time;
   }
   g_diag.turns++;
   Journal("TURN_ARMED",StringFormat("%s trigger=%.5f invalidation=%.5f; fresh Bid cross required",
      g_setupSide==1 ? "BUY":"SELL",g_trigger,g_invalidation),1); Status("Turn armed; waiting for a fresh live cross"); return true;
}
void UpdateClosedBarSetup()
{
   if(!g_ready || ArraySize(g_m1)<InpM1ReferenceLookback+2)return;
   int base=M5BaseDirection();
   if(base==0) { ResetEntrySetup("M5 EMA regime unavailable/equal"); return; }
   if(g_setupSide!=0 && g_setupSide!=base) { ResetEntrySetup("M5 EMA regime changed",false); return; }
   // Optional ADX/DI/close filters qualify new setups; they do not erase a valid
   // setup merely because one closed bar temporarily fails a filter.
   if(ExpireEntrySetup() || g_m1[1].time<=g_setupAfter)return;
   if(g_pause!=0 || g_hardKill!=0 || CountOwned()>0 || CountForeignSameSymbolExposure()>0)
   { ResetEntrySetup("Exposure or review lock"); return; }
   if(g_setupState==SETUP_WAIT_BREAK)
   {
      double penetration=g_setupSide==1 ? g_invalidation-g_m1[1].low:g_m1[1].high-g_invalidation;
      if(penetration>0)
      {
         if(InpTurnInvalidationATR>0 && penetration<InpTurnInvalidationATR*g_atr)
         {
            g_invalidation=g_setupSide==1 ? g_m1[1].low:g_m1[1].high;
            g_pullbackDepth=g_setupSide*(g_reference-g_invalidation)/g_atr; g_diag.turn_tolerance++;
            Journal("TURN_TOLERANCE_UPDATE",StringFormat("Frozen trigger kept; new invalidation %.5f",g_invalidation),1);
         }
         else
         {
            g_invalidation=g_setupSide==1 ? g_m1[1].low:g_m1[1].high;
            g_pullbackDepth=g_setupSide*(g_reference-g_invalidation)/g_atr; g_trigger=0;
            g_setupState=SETUP_WAIT_TURN; g_diag.turn_invalidations++; ClearCrossObservation();
            Journal("TURN_INVALIDATED","Pullback penetration exceeded turn tolerance; wait for NEW turn candle",1);
         }
      }
      return;
   }
   if(g_setupState==SETUP_WAIT_PULLBACK)
   {
      if(g_bias==0) { Status("Waiting for M5 setup filters"); return; }
      double reference=g_bias==1 ? Highest(2,InpM1ReferenceLookback):Lowest(2,InpM1ReferenceLookback);
      double extreme=g_bias==1 ? g_m1[1].low:g_m1[1].high;
      double depth=g_bias*(reference-extreme)/g_atr;
      if(depth<InpM1PullbackATR) { Status("Waiting for a meaningful M1 pullback"); return; }
      g_setupSide=g_bias; g_reference=reference; g_invalidation=extreme; g_pullbackDepth=depth;
      g_setupStart=g_m1[1].time+60; g_setupState=SETUP_WAIT_TURN; g_diag.pullbacks++;
      Journal("PULLBACK_DETECTED",StringFormat("%s reference=%.5f invalidation=%.5f depth=%.2f ATR",
         g_setupSide==1 ? "BUY":"SELL",g_reference,g_invalidation,depth),1);
   }
   else
   {
      g_invalidation=g_setupSide==1 ? MathMin(g_invalidation,g_m1[1].low):MathMax(g_invalidation,g_m1[1].high);
      g_pullbackDepth=g_setupSide*(g_reference-g_invalidation)/g_atr;
   }
   bool turn=g_setupSide==1 ? g_m1[1].close>g_m1[1].open:g_m1[1].close<g_m1[1].open;
   if(turn)ArmTurnTrigger(); else Status("Pullback found; waiting for first closed turn candle");
}

// Current Bid is used for both live crossing directions; Ask is only execution price.
void ProcessLiveEntryTrigger()
{
   if(ExpireEntrySetup() || g_setupState!=SETUP_WAIT_BREAK || !g_ready)return;
   if(M5BaseDirection()!=g_setupSide) { ResetEntrySetup("M5 EMA regime no longer matches"); return; }
   MqlTick q; if(!QuoteFresh(q)) { ClearCrossObservation(); return; }
   double current=q.bid;
   if(g_previousQuote<=0 || q.time<g_crossQuoteTime || q.time-g_crossQuoteTime>InpMaxTickAgeSeconds)
   { g_previousQuote=current; g_crossQuoteTime=q.time; g_crossReady=g_setupSide==1 ? current<g_trigger:current>g_trigger; return; }
   bool crossed=AG_LiveCross(g_setupSide,g_trigger,g_previousQuote,current,g_crossReady);
   g_previousQuote=current; g_crossQuoteTime=q.time;
   if(!crossed)return;
   g_diag.live_crosses++; g_diag.entry_attempts++;
   Journal("LIVE_CROSS",StringFormat("%s frozen=%.5f live Bid=%.5f; entry attempt %d",
      g_setupSide==1 ? "BUY":"SELL",g_trigger,current,g_setupAttempts+1),1);
   AGSignal signal; signal.side=g_setupSide; signal.setup=1; signal.invalidation=g_invalidation;
   signal.label="M5 / M1 pullback-turn-live-Bid-reclaim";
   ASTRA_REJECT_CLASS cls=REJECT_NONE;
   bool executed=TryEntry(signal,cls);
   if(executed)
   { ResetEntrySetup("Live cross executed"); return; }
   if(cls==REJECT_EMERGENCY)return;
   g_setupAttempts++; g_crossReady=false;
   if(InpMaxEntryAttemptsPerSetup>0 && g_setupAttempts>=InpMaxEntryAttemptsPerSetup)
   { ResetEntrySetup("Maximum fresh entry attempts for setup reached"); return; }
   if(cls==REJECT_STRUCTURAL) { ResetEntrySetup("Structural entry rejection"); return; }
   Journal("ENTRY_ATTEMPT_REARMED","Temporary rejection; Bid must return to the pre-trigger side",1);
}

// Price, broker and risk helpers.
double TickSize() { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }
double RoundPrice(const double price,const bool up)
{
   double size=TickSize(); if(size<=0)return 0;
   double units=up ? MathCeil(price/size-1e-9):MathFloor(price/size+1e-9);
   return NormalizeDouble(units*size,_Digits);
}
double MinimumStopDistance(const bool modify=false)
{
   long level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(modify)level=(long)MathMax(level,SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL));
   return (double)level*_Point+2*TickSize();
}
bool LossAtStop(const int side,const double lots,const double entry,const double sl,
                const bool reserve_entry,const double fee_per_lot,double &risk)
{
   double entry_price=entry+(reserve_entry ? side*InpSlippageReservePrice:0);
   double stop_price=sl-side*InpSlippageReservePrice,profit=0;
   if(!OrderCalcProfit(side==1 ? ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,lots,entry_price,stop_price,profit))return false;
   if(!MathIsValidNumber(profit))return false;
   risk=MathMax(0,-USD(profit))+fee_per_lot*lots; return MathIsValidNumber(risk) && risk>=0;
}
bool QuoteFresh(MqlTick &q)
{
   if(!SymbolInfoTick(_Symbol,q) || q.ask<=q.bid || q.bid<=0)return false;
   long age=(long)Now()-(long)q.time; return age>=-2 && age<=InpMaxTickAgeSeconds;
}
bool MarginSafe(const double total_margin,const double risk,string &why)
{
   double stressed=Equity()-risk; if(stressed<=0 || total_margin<0){why="Invalid/stressed margin";return false;}
   double call=USD(AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL)),stop=USD(AccountInfoDouble(ACCOUNT_MARGIN_SO_SO));
   if(AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)==ACCOUNT_STOPOUT_MODE_PERCENT)
   {
      double broker_level=MathMax(call,stop)+100.0,minimum=InpMinMarginLevel>0 ? MathMax(InpMinMarginLevel,broker_level):broker_level;
      if(total_margin<=0 || 100*stressed/total_margin<minimum){why="Margin level too low after modeled stop";return false;}
   }
   else if(stressed-total_margin<=MathMax(call,stop)+risk){why="Cash stop-out buffer too small";return false;}
   if(InpMaxMarginUsePercent>0 && 100*total_margin/MathMax(Equity(),0.0000001)>InpMaxMarginUsePercent)
   {why="Margin-use ceiling reached";return false;}
   if(stressed-total_margin<=0){why="No free margin after modeled stop";return false;}
   return true;
}
bool ChooseFilling(ENUM_ORDER_TYPE_FILLING &fill)
{
   long flags=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((flags&SYMBOL_FILLING_FOK)!=0){fill=ORDER_FILLING_FOK;return true;}
   if((flags&SYMBOL_FILLING_IOC)!=0){fill=ORDER_FILLING_IOC;return true;}
   if(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE)!=SYMBOL_TRADE_EXECUTION_MARKET){fill=ORDER_FILLING_RETURN;return true;}
   return false;
}
void PermissionReject(string &why,ASTRA_REJECT_CLASS &cls,const string text,const long kind)
{
   why=text; cls=REJECT_TEMPORARY;
   if(kind==1)g_diag.reject_cooldown++; else if(kind==2)g_diag.reject_hour++; else if(kind==3)g_diag.reject_day++;
   else if(kind==4)g_diag.reject_session++; else if(kind==5)g_diag.reject_broker_session++;
   else if(kind==6)g_diag.reject_news_actual++; else if(kind==7)g_diag.reject_news_unavailable++;
   else if(kind==8)g_diag.reject_spread++; else if(kind==9)g_diag.reject_atr++; else if(kind==10)g_diag.reject_spike++;
   else if(kind==11)g_diag.reject_stale++; else if(kind==12)g_diag.reject_foreign++;
   else if(kind==13)g_diag.reject_risk++;
}
bool EntryAllowed(string &why,ASTRA_REJECT_CLASS &cls)
{
   cls=REJECT_TEMPORARY;
   if(!ModeAllowsEntries()){PermissionReject(why,cls,"Entries disabled by environment setting",0);return false;}
   if(!CanTrade()){PermissionReject(why,cls,"Connection or Algo Trading unavailable",0);return false;}
   if(!g_historyOK){PermissionReject(why,cls,"Trade history unavailable",0);return false;}
   if(!g_stateOK){cls=REJECT_EMERGENCY;g_diag.reject_postfill++;why="Protection state cannot be persisted";return false;}
   if(g_hardKill!=0){cls=REJECT_EMERGENCY;why="HARD LOCK: equity/drawdown limit";return false;}
   if(g_pause!=0){why="PAUSED: manual review required";return false;}
   if(g_dayLock==DayStart(Now())){PermissionReject(why,cls,"Daily loss lock",3);return false;}
   if(g_weekLock==WeekStart(Now())){PermissionReject(why,cls,"Weekly loss lock",3);return false;}
   if(CountOwned()>0){PermissionReject(why,cls,"Managing existing ASTRA trade",12);return false;}
   if(CountForeignSameSymbolExposure()>0){PermissionReject(why,cls,"Foreign same-symbol exposure",12);return false;}
   if(g_dayProfitLock==DayStart(Now())){PermissionReject(why,cls,"Daily profit stop",3);return false;}
   if(g_weekProfitLock==WeekStart(Now())){PermissionReject(why,cls,"Weekly profit stop",3);return false;}
   if(InpMaxTradesPerDay>0 && g_dailyEntries>=InpMaxTradesPerDay){PermissionReject(why,cls,"Daily trade count limit",3);return false;}
   if(InpMaxTradesPerHour>0 && g_hourEntries>=InpMaxTradesPerHour){PermissionReject(why,cls,"Hourly trade count limit",2);return false;}
   if(InpCooldownMinutes>0 && g_lastExit>0 && Now()-g_lastExit<InpCooldownMinutes*60){PermissionReject(why,cls,"Cooldown after exit",1);return false;}
   if(InpCooldownMinutes>0 && g_lastEntry>0 && Now()-g_lastEntry<InpCooldownMinutes*60){PermissionReject(why,cls,"Cooldown after entry",1);return false;}
   if(g_lossStreakCooldownUntil>Now()){PermissionReject(why,cls,"Loss-streak automatic cooldown",1);return false;}
   if(InpUseSpikeEntryFilter && Now()<g_spikeUntil){PermissionReject(why,cls,"Volatility spike cooldown",10);return false;}
   int horizon=InpRequireFullHoldInsideSession && InpMaxHoldMinutes>0 ? InpMaxHoldMinutes*60:0;
   if(!SessionClear(Now(),horizon))
   { PermissionReject(why,cls,g_brokerSessionOK ? "Configured session closed":"Broker-session metadata/session closed",g_brokerSessionOK ? 4:5);return false; }
   if(!NewsClear(Now(),horizon,why))
   { PermissionReject(why,cls,why,g_newsActualBlocked ? 6:7);return false; }
   MqlTick q; if(!QuoteFresh(q)){PermissionReject(why,cls,"Quote missing or stale",11);return false;}
   if(!g_ready){PermissionReject(why,cls,"Waiting for indicator history",0);return false;}
   double spread=q.ask-q.bid;
   if((InpMaxSpreadPrice>0 && spread>InpMaxSpreadPrice)||(InpMaxSpreadATR>0 && g_atr>0 && spread/g_atr>InpMaxSpreadATR))
   {PermissionReject(why,cls,"Spread too expensive",8);return false;}
   if((InpMinATRPrice>0 && g_atr<InpMinATRPrice)||(InpMaxATRPrice>0 && g_atr>InpMaxATRPrice))
   {PermissionReject(why,cls,"ATR outside allowed volatility band",9);return false;}
   if(Budget()<=0){PermissionReject(why,cls,"No per-trade risk budget",13);return false;}
   return true;
}

bool StructuralStop(const int side,const double invalidation,const MqlTick &q,double &stop,string &why)
{
   why="";
   if(g_atr<=0 || invalidation<=0 || (side!=1 && side!=-1)){why="INVALID_STRUCTURE";return false;}
   double entry=side==1?q.ask:q.bid;
   stop=invalidation-side*InpStructurePaddingATR*g_atr;
   if(stop<=0 || side*(entry-stop)<=0){why="INVALID_STRUCTURE";return false;}
   double raw_distance=side*(entry-stop);
   stop=side==1 ? MathMin(stop,q.bid-MinimumStopDistance()):MathMax(stop,q.ask+MinimumStopDistance());
   stop=RoundPrice(stop,side==-1);
   double distance=side*(entry-stop);
   if(distance<=0){why="INVALID_STRUCTURE";return false;}
   if(InpMaxInitialSL_ATR>0 && distance>InpMaxInitialSL_ATR*g_atr)
   {why=raw_distance>InpMaxInitialSL_ATR*g_atr ? "MAX_SL_ATR_REJECT":"BROKER_STOP_ADJUSTED_TOO_WIDE";return false;}
   return true;
}
void SizingPreview()
{
   g_minLotRisk=0; g_lastBudget=TradeRiskBudget();
   if(!g_ready || g_setupStart<=0 || g_setupSide==0)return;
   MqlTick q; double stop=0; string why;
   if(!QuoteFresh(q) || !StructuralStop(g_setupSide,g_invalidation,q,stop,why))return;
   double minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),risk=0;
   if(LossAtStop(g_setupSide,minimum,g_setupSide==1?q.ask:q.bid,stop,true,InpCommissionUSDPerLotRoundTrip,risk))g_minLotRisk=risk;
}

void MarkLevel(const string label,const double price,const color shade)
{
   if(!InpShowLevels || g_opt || (g_test && !MQLInfoInteger(MQL_VISUAL_MODE)))return;
   string name=g_ui+label; if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price); ObjectSetInteger(0,name,OBJPROP_COLOR,shade);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT); ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false); ObjectSetString(0,name,OBJPROP_TEXT,label);
}
void BindFilledPosition(const double expected,const int side)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i); if(ticket==0 || !SelectedIsOurs())continue;
      g_positionId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double price=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),lots=PositionGetDouble(POSITION_VOLUME);
      g_initialR=side*(price-g_referenceSL); g_initialVolume=lots; g_guardSL=sl;
      if(HistorySelectByPosition(g_positionId))
      {
         double paid=0,entered=0;
         for(int j=0;j<HistoryDealsTotal();j++)
         {
            ulong d=HistoryDealGetTicket(j); if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN)continue;
            paid+=MathMax(0,-USD(HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE)));
            entered+=HistoryDealGetDouble(d,DEAL_VOLUME);
         }
         if(entered>0)g_openFeePerLot=MathMax(g_openFeePerLot,2*paid/entered);
      }
      g_historyDirty=true; SavePosition(); double actual_risk=0;
      bool risk_ok=sl>0 && g_initialR>0 && (g_openManagement!=TM_FIXED_TP_INVALIDATION || PositionGetDouble(POSITION_TP)>0) &&
         LossAtStop(side,lots,price,sl,false,g_openFeePerLot,actual_risk);
      Journal("FILL",StringFormat("Adverse slippage %.5f; post-fill modeled risk %.4f USD",side*(price-expected),actual_risk),
         g_positionSetup,expected,price,sl,PositionGetDouble(POSITION_TP),lots,actual_risk);
      g_diag.fills++;
         if(!risk_ok || actual_risk>g_openRiskBudget+0.000001 || side*(price-expected)>InpMaxDeviationPrice+TickSize())
      { g_diag.reject_postfill++; Emergency(5,"Execution outside budget: exit and review"); CloseTicket(ticket,"Post-fill execution/risk check"); }
      else Notify(SetupName(g_positionSetup)+" opened; modeled risk $"+DoubleToString(actual_risk,2));
      return;
   }
   g_historyDirty=true;
}
void RejectEntry(const string reason,const ASTRA_REJECT_CLASS cls)
{
   if(cls==REJECT_STRUCTURAL)
   {
      g_diag.reject_stop++;
      if(StringFind(reason,"MAX_SL_ATR")>=0 || StringFind(reason,"TOO_WIDE")>=0)g_diag.reject_max_stop++;
      Journal("ENTRY_STRUCTURAL_REJECT",reason,1);
   }
   else if(cls==REJECT_EMERGENCY){g_diag.reject_postfill++;Journal("ENTRY_EMERGENCY_REJECT",reason,1);}
   else Journal("ENTRY_TEMP_REJECT",reason,1);
   Status(reason);
}
bool TryEntry(AGSignal &s,ASTRA_REJECT_CLASS &cls)
{
   string why; cls=REJECT_TEMPORARY;
   if(!EntryAllowed(why,cls)){RejectEntry(why,cls);return false;}
   if((s.side==1 && !InpAllowBuy)||(s.side==-1 && !InpAllowSell)){RejectEntry("Signal direction disabled",REJECT_STRUCTURAL);cls=REJECT_STRUCTURAL;return false;}
   long trade_mode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(trade_mode==SYMBOL_TRADE_MODE_DISABLED || trade_mode==SYMBOL_TRADE_MODE_CLOSEONLY ||
      (s.side==1 && trade_mode==SYMBOL_TRADE_MODE_SHORTONLY)||(s.side==-1 && trade_mode==SYMBOL_TRADE_MODE_LONGONLY))
   {g_diag.reject_broker++;RejectEntry("Broker disallows this direction",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   long orders=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if((orders&SYMBOL_ORDER_MARKET)==0 || (orders&SYMBOL_ORDER_SL)==0 ||
      (InpTradeManagement==TM_FIXED_TP_INVALIDATION && (orders&SYMBOL_ORDER_TP)==0))
   {g_diag.reject_broker++;RejectEntry("Broker does not permit protected market orders",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   MqlTick q; if(!QuoteFresh(q)){g_diag.reject_stale++;RejectEntry("Fresh quote unavailable",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   double entry=s.side==1?q.ask:q.bid,stop=0; string stop_why;
   if(!StructuralStop(s.side,s.invalidation,q,stop,stop_why))
   {
      cls=REJECT_STRUCTURAL;
      RejectEntry(stop_why,cls); return false;
   }
   double distance=s.side*(entry-stop),target=0;
   if(InpTradeManagement==TM_FIXED_TP_INVALIDATION)target=RoundPrice(entry+s.side*distance*InpTakeProfitR,s.side==1);
   double minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),maximum=MathMin(InpMaxLots,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX));
   double limit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT); if(limit>0)maximum=MathMin(maximum,limit);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),risk_at_min=0;
   if(!LossAtStop(s.side,minimum,entry,stop,true,InpCommissionUSDPerLotRoundTrip,risk_at_min)||risk_at_min<=0)
   {g_diag.reject_risk++;RejectEntry("Risk calculation unavailable",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   g_minLotRisk=risk_at_min;g_lastBudget=TradeRiskBudget();
   double lots=NormalizeDouble(AG_Lots(g_lastBudget,risk_at_min/minimum,minimum,step,maximum),8);
   if(lots<minimum){g_diag.reject_risk++;RejectEntry(StringFormat("MIN_LOT_RISK_TOO_HIGH: min-lot $%.2f > budget $%.2f",risk_at_min,g_lastBudget),REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   double risk=0;
   if(!LossAtStop(s.side,lots,entry,stop,true,InpCommissionUSDPerLotRoundTrip,risk)||risk>g_lastBudget+1e-8)
   {g_diag.reject_risk++;RejectEntry("Risk recheck rejected position size",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   if(InpTradeManagement==TM_FIXED_TP_INVALIDATION && InpMinimumNetRewardRisk>0)
   {
      double gross_reward=0;
      if(!OrderCalcProfit(s.side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,lots,
         entry+s.side*InpSlippageReservePrice,target-s.side*InpSlippageReservePrice,gross_reward))
      {g_diag.reject_risk++;RejectEntry("Reward calculation unavailable",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
      double reward=USD(gross_reward)-InpCommissionUSDPerLotRoundTrip*lots;
      if(reward<=0 || reward/risk<InpMinimumNetRewardRisk)
      {g_diag.reject_risk++;RejectEntry("Fixed target reward too small after modeled costs",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   }
   double margin=0;
   if(!OrderCalcMargin(s.side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,lots,entry,margin))
   {g_diag.reject_margin++;RejectEntry("Broker margin calculation unavailable",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   double margin_usd=USD(margin),free_usd=USD(AccountInfoDouble(ACCOUNT_MARGIN_FREE));
   if(margin_usd>=free_usd || !MarginSafe(USD(AccountInfoDouble(ACCOUNT_MARGIN))+margin_usd,risk,why))
   {g_diag.reject_margin++;RejectEntry(why==""?"Insufficient free margin":why,REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   MqlTradeRequest request;MqlTradeCheckResult check;MqlTradeResult result;ZeroMemory(request);ZeroMemory(check);ZeroMemory(result);
   request.action=TRADE_ACTION_DEAL;request.symbol=_Symbol;request.magic=InpMagic;request.volume=lots;
   request.type=s.side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL;request.price=entry;request.sl=stop;request.tp=target;
   request.deviation=(ulong)MathCeil(InpMaxDeviationPrice/_Point);request.comment="AG1 v2 "+ManagementModeName((int)InpTradeManagement);request.type_time=ORDER_TIME_GTC;
   if(!ChooseFilling(request.type_filling)){g_diag.reject_fill++;RejectEntry("Unsupported broker fill policy",REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   if(!OrderCheck(request,check)||(check.retcode!=0&&check.retcode!=TRADE_RETCODE_DONE))
   {g_diag.reject_ordercheck++;RejectEntry("OrderCheck: "+check.comment,REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   if(!MarginSafe(USD(AccountInfoDouble(ACCOUNT_MARGIN))+USD(check.margin),risk,why)){g_diag.reject_margin++;RejectEntry(why,REJECT_TEMPORARY);cls=REJECT_TEMPORARY;return false;}
   // Write intent before send. An uncertain response is never retried.
   g_positionId=0;g_initialR=0;g_openRiskBudget=g_lastBudget;g_openFeePerLot=InpCommissionUSDPerLotRoundTrip;
   g_positionSetup=s.setup;g_referenceSL=stop;g_openManagement=(int)InpTradeManagement;g_initialVolume=lots;g_partialDone=false;g_guardSL=stop;
   SavePosition();if(!g_stateOK){cls=REJECT_EMERGENCY;RejectEntry("Order cancelled: state could not be saved",cls);return false;}
   Journal("ORDER_INTENT",s.label,s.setup,entry,0,stop,target,lots,risk);g_diag.orders_sent++;
   bool sent=OrderSend(request,result);
   if(!sent || (result.retcode!=TRADE_RETCODE_DONE&&result.retcode!=TRADE_RETCODE_DONE_PARTIAL))
   {
      g_diag.reject_send++;Journal("ORDER_REJECTED",StringFormat("retcode=%u %s",result.retcode,result.comment),s.setup);
      if(!sent && result.retcode==TRADE_RETCODE_REQUOTE) { cls=REJECT_TEMPORARY; return false; }
      Emergency(5,"Order not confirmed: reconcile before Resume");g_historyDirty=true;Flatten("Unconfirmed order");cls=REJECT_EMERGENCY;return false;
   }
   g_lastEntry=Now();BindFilledPosition(entry,s.side);MarkLevel("Invalidation",stop,clrTomato);
   if(target>0)MarkLevel("Target",target,clrMediumSeaGreen);else ObjectDelete(0,g_ui+"Target");
   Status("Managing "+SetupName(s.setup));
   if(g_hardKill!=0){cls=REJECT_EMERGENCY;return false;}
   return true;
}

void ObserveSpike()
{
   if(!InpUseSpikeEntryFilter || g_atr<=0)return;
   double high=iHigh(_Symbol,PERIOD_M1,0),low=iLow(_Symbol,PERIOD_M1,0);
   if(InpSpikePauseMinutes>0 && high>low && high-low>=InpSpikeATR*g_atr && Now()>=g_spikeUntil)
   {g_spikeUntil=Now()+InpSpikePauseMinutes*60;Journal("SPIKE_BLOCK_START","Current M1 range exceeds spike threshold");SaveState(true);}
}
void TryPartialProfit(const ulong ticket)
{
   if(g_partialDone||g_openManagement!=TM_PARTIAL_ATR_TRAIL)return;
   g_partialDone=true;SavePosition();if(!g_stateOK){Emergency(5,"Partial intent could not be persisted");return;}
   if(!PositionSelectByTicket(ticket)||!SelectedIsOurs()||(ulong)PositionGetInteger(POSITION_IDENTIFIER)!=g_positionId)return;
   double before=PositionGetDouble(POSITION_VOLUME),minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),maximum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double lots=NormalizeDouble(AG_PartialLots(before,g_initialVolume,InpPartialClosePercent,minimum,step,maximum),8);
   if(lots<=0){g_diag.partial_unavailable++;Journal("PARTIAL_UNAVAILABLE","No legal close + remainder; consumed once; ATR trail continues",1,0,0,0,0,before);return;}
   long account_mode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(account_mode!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING&&account_mode!=ACCOUNT_MARGIN_MODE_RETAIL_NETTING&&account_mode!=ACCOUNT_MARGIN_MODE_EXCHANGE)
   {g_diag.partial_unavailable++;Journal("PARTIAL_UNAVAILABLE","Unknown account mode; ATR trail continues",1);return;}
   MqlTick q;if(!CanTrade()||!QuoteFresh(q)){g_diag.partial_unavailable++;Journal("PARTIAL_UNAVAILABLE","No fresh executable quote/permission; action consumed",1);return;}
   int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
   MqlTradeRequest request;MqlTradeCheckResult check;MqlTradeResult result;ZeroMemory(request);ZeroMemory(check);ZeroMemory(result);
   request.action=TRADE_ACTION_DEAL;request.position=ticket;request.symbol=_Symbol;request.magic=InpMagic;
   request.type=side==1?ORDER_TYPE_SELL:ORDER_TYPE_BUY;request.price=side==1?q.bid:q.ask;request.volume=lots;request.deviation=(ulong)MathCeil(InpMaxDeviationPrice/_Point);
   request.comment="AG1 v2 partial";request.type_time=ORDER_TIME_GTC;
   if(!ChooseFilling(request.type_filling)||request.type_filling==ORDER_FILLING_RETURN){g_diag.partial_unavailable++;Journal("PARTIAL_UNAVAILABLE","Requires FOK/IOC; no resting reduction order",1);return;}
   if(!OrderCheck(request,check)||(check.retcode!=0&&check.retcode!=TRADE_RETCODE_DONE)){g_diag.partial_unavailable++;Journal("PARTIAL_UNAVAILABLE","OrderCheck: "+check.comment+"; consumed, no retry",1);return;}
   if(!PositionSelectByTicket(ticket)||!SelectedIsOurs()||(ulong)PositionGetInteger(POSITION_IDENTIFIER)!=g_positionId||
      (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1)!=side||MathAbs(PositionGetDouble(POSITION_VOLUME)-before)>1e-8||CountForeignSameSymbolExposure()>0)
   {g_diag.partial_unavailable++;Journal("PARTIAL_UNAVAILABLE","Position/exposure changed before send; action consumed",1);return;}
   Journal("PARTIAL_INTENT",StringFormat("Ticket %I64u; close %.8f; keep %.8f",ticket,lots,before-lots),1,0,0,0,0,lots);
   bool sent=OrderSend(request,result);g_historyDirty=true;
   bool ok=sent&&(result.retcode==TRADE_RETCODE_DONE||result.retcode==TRADE_RETCODE_DONE_PARTIAL);
   if(!ok||result.volume>lots+1e-8){Journal("PARTIAL_NOT_CONFIRMED",StringFormat("retcode=%u %s; no repeat",result.retcode,result.comment),1);Emergency(5,"Partial execution uncertain: reconcile and review");Flatten("Uncertain partial execution");return;}
   g_diag.partials++;Journal("PARTIAL_TAKEN",StringFormat("Server accepted one reduction; filled %.8f of %.8f",result.volume,lots),1,request.price,result.price,0,0,result.volume);
}
void TightenStop(const ulong ticket,double candidate,const string reason)
{
   if(!CanTrade()||!PositionSelectByTicket(ticket)||!SelectedIsOurs())return;
   if((ulong)PositionGetInteger(POSITION_IDENTIFIER)!=g_positionId||g_openManagement==TM_FIXED_TP_INVALIDATION)return;
   MqlTick q;if(!QuoteFresh(q)||g_atr<=0)return;
   int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
   double sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),current=side==1?q.bid:q.ask;
   candidate=RoundPrice(candidate,side==-1);
   if(sl<=0||!AG_Tightens(side,sl,candidate,MathMax(TickSize(),InpStopStepATR*g_atr)))return;
   if(side*(current-candidate)<MinimumStopDistance(true))return;
   double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   if(freeze>0&&(MathAbs(current-sl)<=freeze||(tp>0&&MathAbs(current-tp)<=freeze)))return;
   if(Now()-g_lastModify<2)return;
   g_lastModify=Now();bool sent=g_trade.PositionModify(ticket,candidate,tp);uint ret=g_trade.ResultRetcode();
   if(sent&&(ret==TRADE_RETCODE_DONE||ret==TRADE_RETCODE_NO_CHANGES))
   {g_diag.stop_modifications++;g_guardSL=candidate;SavePosition();Journal("STOP_TIGHTENED",reason,g_positionSetup,sl,candidate,candidate,tp);}
   else {g_diag.stop_modify_rejects++;Journal("STOP_REJECTED",g_trade.ResultRetcodeDescription());}
}
void ManagePositions()
{
   if(g_hardKill!=0||g_pause!=0){Flatten(g_hardKill!=0?"Account emergency lock":"Manual pause");return;}
   if(!g_sessionOK && InpUseSessionFilter && InpCloseAtSessionEnd){Flatten("Session/Friday/broker close buffer");return;}
   if(g_newsActualBlocked && InpCloseOnNews){Flatten("Actual news blackout");return;}
   if(InpUseSpikeEntryFilter && InpCloseOnSpike && Now()<g_spikeUntil){Flatten("Volatility spike");return;}
   if(g_dayProfitLock==DayStart(Now())||g_weekProfitLock==WeekStart(Now()))return;
   if(CountOwned()>1){Emergency(5,"More than one ASTRA position detected");Flatten("Unexpected position count");return;}
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);if(ticket==0||!SelectedIsOurs())continue;
      ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),volume=PositionGetDouble(POSITION_VOLUME);
      bool mode_valid=g_openManagement>=TM_FIXED_TP_INVALIDATION&&g_openManagement<=TM_PARTIAL_ATR_TRAIL;
      bool target_ok=g_openManagement==TM_FIXED_TP_INVALIDATION?tp>0:tp==0;
      if(id!=g_positionId||g_initialR<=0||g_referenceSL<=0||g_openRiskBudget<=0||g_initialVolume<=0||volume>g_initialVolume+1e-8||!mode_valid||!target_ok||sl<=0||g_guardSL<=0||
         side*(sl-g_guardSL)<-TickSize()*0.5||side*(sl-g_referenceSL)<-TickSize()||
         (g_openManagement==TM_FIXED_TP_INVALIDATION&&MathAbs(sl-g_referenceSL)>TickSize()*0.5))
      {g_diag.reject_postfill++;Emergency(5,"Position protection/state missing or altered");CloseTicket(ticket,"Protection audit");continue;}
      double risk=0;
      if(!LossAtStop(side,volume,entry,sl,false,g_openFeePerLot,risk)||risk>g_openRiskBudget+0.000001)
      {g_diag.reject_postfill++;Emergency(5,"Open position exceeds stored risk budget");CloseTicket(ticket,"Open-risk audit");continue;}
      if(side*(sl-g_guardSL)>TickSize()*0.5){g_guardSL=sl;SavePosition();if(!g_stateOK){CloseTicket(ticket,"SL state save failed");continue;}}
      long age=(long)Now()-PositionGetInteger(POSITION_TIME);
      double net=USD(PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP))-g_openFeePerLot*volume;
      if(InpMaxHoldMinutes>0&&age>=InpMaxHoldMinutes*60){CloseTicket(ticket,"Maximum hold");continue;}
      if(InpStallExitMinutes>0&&age>=InpStallExitMinutes*60&&net<=0){CloseTicket(ticket,"Stalled trade");continue;}
      if(InpExitOnM5TrendFlip&&g_ready&&M5BaseDirection()==-side){CloseTicket(ticket,"Closed M5 EMA trend flipped");continue;}
      if(g_openManagement==TM_FIXED_TP_INVALIDATION)continue;
      MqlTick q;if(!g_ready||!QuoteFresh(q)||!CanTrade())continue;
      double current=side==1?q.bid:q.ask,r=side*(current-entry)/g_initialR;
      if(g_openManagement==TM_PARTIAL_ATR_TRAIL&&!g_partialDone&&r>=InpPartialAtR)
      {
         TryPartialProfit(ticket);
         if(g_hardKill!=0||!PositionSelectByTicket(ticket)||!SelectedIsOurs()||(ulong)PositionGetInteger(POSITION_IDENTIFIER)!=id)continue;
         sl=PositionGetDouble(POSITION_SL);volume=PositionGetDouble(POSITION_VOLUME);if(!QuoteFresh(q))continue;
         current=side==1?q.bid:q.ask;r=side*(current-entry)/g_initialR;
      }
      double candidate=sl;
      if(g_openManagement==TM_BE_ATR_TRAIL&&r>=InpBreakEvenAtR)
      {
         double one_unit=0;
         if(OrderCalcProfit(side==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,volume,entry,entry+side,one_unit))
         {
            double value_per_price=USD(one_unit);
            if(value_per_price>0){double be=RoundPrice(entry+side*(g_openFeePerLot*volume/value_per_price+InpSlippageReservePrice),side==1);candidate=side==1?MathMax(candidate,be):MathMin(candidate,be);}
         }
      }
      bool trail=(g_openManagement==TM_BE_ATR_TRAIL&&r>=InpTrailStartR)||(g_openManagement==TM_PARTIAL_ATR_TRAIL&&g_partialDone);
      if(trail){double trailing=current-side*InpTrailATR*g_atr;candidate=side==1?MathMax(candidate,trailing):MathMin(candidate,trailing);}
      TightenStop(ticket,candidate,ManagementModeName(g_openManagement));
   }
}

// Lightweight panel and chart support.
bool UIEnabled() { return InpShowPanel&&!g_opt&&(!g_test||MQLInfoInteger(MQL_VISUAL_MODE)); }
void Box(const string key,const int x,const int y,const int w,const int h,const color background,const bool drag=false)
{
   string name=g_ui+key;if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);ObjectSetInteger(0,name,OBJPROP_YSIZE,h);ObjectSetInteger(0,name,OBJPROP_BGCOLOR,background);ObjectSetInteger(0,name,OBJPROP_COLOR,background);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);ObjectSetInteger(0,name,OBJPROP_BACK,false);ObjectSetInteger(0,name,OBJPROP_SELECTABLE,drag);ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);ObjectSetInteger(0,name,OBJPROP_ZORDER,drag?2:0);
}
string Short(const string value,const int limit) { return StringLen(value)<=limit?value:StringSubstr(value,0,limit-3)+"..."; }
void Label(const string key,const int row,const string value,const color shade=clrGainsboro,const int size=9)
{
   string name=g_ui+key;if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,name,OBJPROP_XDISTANCE,g_x+12);ObjectSetInteger(0,name,OBJPROP_YDISTANCE,g_y+row);
   ObjectSetInteger(0,name,OBJPROP_COLOR,shade);ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);ObjectSetString(0,name,OBJPROP_FONT,"Consolas");ObjectSetString(0,name,OBJPROP_TEXT,Short(value,size<=8?63:52));ObjectSetString(0,name,OBJPROP_TOOLTIP,value);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);ObjectSetInteger(0,name,OBJPROP_ZORDER,3);
}
void Button(const string key,const int dx,const int dy,const int width,const string value,const color background)
{
   string name=g_ui+key;if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,name,OBJPROP_XDISTANCE,g_x+dx);ObjectSetInteger(0,name,OBJPROP_YDISTANCE,g_y+dy);ObjectSetInteger(0,name,OBJPROP_XSIZE,width);ObjectSetInteger(0,name,OBJPROP_YSIZE,22);ObjectSetInteger(0,name,OBJPROP_BGCOLOR,background);ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);ObjectSetInteger(0,name,OBJPROP_ZORDER,5);ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);ObjectSetString(0,name,OBJPROP_TEXT,value);
}
void Counts(const datetime from,int &wins,int &losses,int &zeros)
{
   wins=0;losses=0;zeros=0;
   for(int i=0;i<ArraySize(g_ledger);i++){if(!g_ledger[i].ours||!g_ledger[i].closed||g_ledger[i].mixed||g_ledger[i].exited<from)continue;if(g_ledger[i].net>0.000001)wins++;else if(g_ledger[i].net<-0.000001)losses++;else zeros++;}
}
string WinRateText(const datetime from)
{int w,l,z;Counts(from,w,l,z);int n=w+l+z;return n>0?StringFormat("%.1f%% (%d/%d)",100.0*w/n,w,n):"-- (0 trades)";}
void DrawTradeMarkers()
{
   if(!InpShowTradeMarkers||g_opt||(g_test&&!MQLInfoInteger(MQL_VISUAL_MODE)))return;int shown=0;
   for(int i=ArraySize(g_ledger)-1;i>=0&&shown<40;i--)
   {
      if(!g_ledger[i].ours||!g_ledger[i].closed||g_ledger[i].mixed)continue;
      string id=StringFormat("%I64u",g_ledger[i].id),en=g_ui+"E"+id,xn=g_ui+"X"+id;double entry=g_ledger[i].entry_value/g_ledger[i].entered_volume,exit_price=g_ledger[i].exit_value/g_ledger[i].exited_volume;
      if(ObjectFind(0,en)<0)ObjectCreate(0,en,g_ledger[i].side==1?OBJ_ARROW_BUY:OBJ_ARROW_SELL,0,g_ledger[i].opened,entry);
      if(ObjectFind(0,xn)<0)ObjectCreate(0,xn,OBJ_ARROW,0,g_ledger[i].exited,exit_price);
      ObjectSetInteger(0,xn,OBJPROP_ARROWCODE,251);ObjectSetInteger(0,xn,OBJPROP_COLOR,g_ledger[i].net>0?clrMediumSeaGreen:clrTomato);ObjectSetString(0,xn,OBJPROP_TOOLTIP,SetupName(g_ledger[i].setup)+" net $"+DoubleToString(g_ledger[i].net,2));shown++;
   }
}
string AutoLockText()
{
   datetime now=Now();
   if(g_hardKill!=0)return "HARD LOCK / REVIEW";
   if(g_pause!=0)return "MANUAL PAUSE";
   if(g_lossStreakCooldownUntil>now)return "LOSS-STREAK "+IntegerToString((int)((g_lossStreakCooldownUntil-now)/60))+"m";
   if(g_dayLock==DayStart(now))return "DAILY until next day";
   if(g_weekLock==WeekStart(now))return "WEEKLY until next week";
   if(g_dayProfitLock==DayStart(now))return "DAY PROFIT until next day";
   if(g_weekProfitLock==WeekStart(now))return "WEEK PROFIT until next week";
   return "NONE";
}
void DrawPanel()
{
   if(!UIEnabled())return;
   color tint=g_hardKill!=0||g_pause!=0||g_newsBlocked?C'76,37,46':(g_bias!=0?C'28,69,67':C'41,49,67');
   int height=g_collapsed?126:500;Box("body",g_x,g_y,416,height,C'19,25,36);Box("header",g_x,g_y,416,27,tint,true);
   Label("title",5,"ASTRA GUARD 2.01 | M5 "+DirectionName(),clrWhite,10);Button("collapse",380,2,30,g_collapsed?"+":"-",C'54,64,82');Label("status",35,Short(g_status,52),g_pause!=0||g_hardKill!=0?clrTomato:clrLightSteelBlue);
   Label("equity",54,StringFormat("Equity $%.2f  Balance $%.2f  Margin %.0f%%",Equity(),Balance(),AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)));
   double dd=g_peak>0?100*(g_peak-Equity())/g_peak:0;Label("risk",73,StringFormat("DD %.2f%% | budget $%.2f | floor $%.2f",dd,g_lastBudget,RiskFloor()));
   int button_y=g_collapsed?98:469;Button("pause",12,button_y,124,g_pause!=0?"REVIEW / RESUME":"PAUSE + FLATTEN",C'54,64,82');Button("kill",146,button_y,180,"FLATTEN EA + PAUSE",C'142,53,64');
   if(g_collapsed){ChartRedraw();return;}
   Box("ddbg",g_x+12,g_y+98,392,6,C'48,55,69');double floor=RiskFloor(),span=MathMax(0.0001,g_peak-floor);int used=(int)MathRound(392*AG_Clamp((g_peak-Equity())/span,0,1));Box("ddfill",g_x+12,g_y+98,(int)MathMax(1,used),6,clrTomato);
   Label("filters",113,StringFormat("Spread %s | News %s | Session %s",g_spreadOK?"OK":"BLOCK",!InpUseNewsFilter?"OFF":(g_newsActualBlocked?"EVENT":(g_newsUnavailable?"UNAVAIL":(g_newsBypass?"BYPASS":"OK"))),g_sessionOK?"OPEN":"CLOSED"));
   Label("setup",133,"M1 "+EntryStateName()+" | M5 "+DirectionName());Label("structure",153,StringFormat("Depth %s ATR | invalidation %s",g_setupStart>0?DoubleToString(g_pullbackDepth,2):"--",g_invalidation>0?DoubleToString(g_invalidation,_Digits):"--"));
   Label("trigger",173,"Frozen Bid trigger: "+(g_trigger>0?DoubleToString(g_trigger,_Digits):"--")+(g_trigger>0?(g_crossReady?" | cross ready":" | need fresh near-side Bid") :""));
   int active_mode=CountOwned()>0?g_openManagement:(int)InpTradeManagement;Label("management",193,"Management "+ManagementModeName(active_mode)+(active_mode==TM_PARTIAL_ATR_TRAIL&&CountOwned()>0?(g_partialDone?" | partial consumed":" | partial pending"):""));
   Label("sizing",213,g_minLotRisk>0?StringFormat("Min-lot structural risk ~$%.2f | budget $%.2f",g_minLotRisk,g_lastBudget):"Min-lot structural risk: -- (need a valid setup)",g_minLotRisk>g_lastBudget?clrOrange:clrGainsboro);
   string current="No ASTRA position";
   for(int i=PositionsTotal()-1;i>=0;i--){if(PositionGetTicket(i)==0||!SelectedIsOurs())continue;double entry=PositionGetDouble(POSITION_PRICE_OPEN),price=PositionGetDouble(POSITION_PRICE_CURRENT);int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1;double estimated_net=USD(PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP))-g_openFeePerLot*PositionGetDouble(POSITION_VOLUME);current=StringFormat("%s %.3f | remaining net~$%.2f | %.2fR",side==1?"BUY":"SELL",PositionGetDouble(POSITION_VOLUME),estimated_net,g_initialR>0?side*(price-entry)/g_initialR:0);double tp=PositionGetDouble(POSITION_TP);Label("position_levels",253,StringFormat("Entry %.2f | SL %.2f | TP %s",entry,PositionGetDouble(POSITION_SL),tp>0?DoubleToString(tp,_Digits):"--"));break;}
   if(CountOwned()==0)Label("position_levels",253,StringFormat("Same-symbol foreign exposure: %d | Loss streak: %d",CountForeignSameSymbolExposure(),g_lossStreak));Label("position",233,current);
   Label("daily",278,StringFormat("Account net: day $%.2f | week $%.2f",g_dayNet,g_weekNet));Label("wins",298,"EA wins: day "+WinRateText(DayStart(Now()))+" week "+WinRateText(WeekStart(Now())));
   int shown=0,skipped=0;for(int i=ArraySize(g_ledger)-1;i>=0&&shown<3;i--){if(!g_ledger[i].ours||!g_ledger[i].closed||g_ledger[i].mixed)continue;if(skipped++<g_historyOffset)continue;string line=TimeToString(g_ledger[i].exited,TIME_MINUTES)+" "+SetupName(g_ledger[i].setup)+StringFormat(" %.2f > %.2f  $%+.2f",g_ledger[i].entry_value/g_ledger[i].entered_volume,g_ledger[i].exit_value/g_ledger[i].exited_volume,g_ledger[i].net);Label("hist"+IntegerToString(shown),332+shown*23,line,g_ledger[i].net>0?clrMediumSeaGreen:clrTomato,8);shown++;}
   for(int i=shown;i<3;i++)Label("hist"+IntegerToString(i),332+i*23,i==0?"Closed trade history: none yet":"",clrSilver,8);
   Label("diag1",401,StringFormat("SETUPS PB %I64d | TURN %I64d | CROSS %I64d | FILL %I64d",g_diag.pullbacks,g_diag.turns,g_diag.live_crosses,g_diag.fills),clrLightSteelBlue,8);
   Label("diag2",419,StringFormat("BLOCKS Risk %I64d | Spread %I64d | News %I64d | Session %I64d",g_diag.reject_risk,g_diag.reject_spread,g_diag.reject_news_actual+g_diag.reject_news_unavailable,g_diag.reject_session+g_diag.reject_broker_session),clrLightSteelBlue,8);
   Label("autolock",437,"Auto lock: "+AutoLockText(),AutoLockText()=="NONE"?clrSilver:clrOrange,8);
   Button("newer",343,button_y,28,"<",C'54,64,82');Button("older",376,button_y,28,">",C'54,64,82');ChartRedraw();
}
void ClearPanel() { ObjectsDeleteAll(0,g_ui); }
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(!UIEnabled())return;
   if(id==CHARTEVENT_OBJECT_DRAG&&sparam==g_ui+"header"){g_x=(int)MathMax(0,ObjectGetInteger(0,sparam,OBJPROP_XDISTANCE));g_y=(int)MathMax(0,ObjectGetInteger(0,sparam,OBJPROP_YDISTANCE));ObjectSetInteger(0,sparam,OBJPROP_SELECTED,false);SaveState(true);DrawPanel();}
   if(id!=CHARTEVENT_OBJECT_CLICK)return;
   if(sparam==g_ui+"collapse"){g_collapsed=!g_collapsed;ClearPanel();SaveState(true);}
   if(sparam==g_ui+"kill"){PauseManual("Manual flatten and pause");Flatten("Panel kill button");}
   if(sparam==g_ui+"pause")
   {
      if(g_pause==0){PauseManual("Manual pause");Flatten("Manual pause");}
      else if(g_hardKill!=0||g_dayLock==DayStart(Now())||g_weekLock==WeekStart(Now())||Equity()<=RiskFloor()||CountForeignSameSymbolExposure()>0||CountOwned()>0)
         Status("Resume blocked: resolve exposure or active risk lock");
      else {g_pause=0;g_ackStreak=g_lastExit;g_lossStreak=0;g_lossStreakCooldownUntil=0;ResetEntrySetup("Manual resume");SaveState(true);Journal("MANUAL_REVIEW","User pressed Resume; limits and equity baseline retained");Status("Resumed; waiting for next M1 bar");}
   }
   if(sparam==g_ui+"older")g_historyOffset=(int)MathMin(MathMax(0,ArraySize(g_ledger)-1),g_historyOffset+3);if(sparam==g_ui+"newer")g_historyOffset=(int)MathMax(0,g_historyOffset-3);
   if(ObjectFind(0,sparam)>=0)ObjectSetInteger(0,sparam,OBJPROP_STATE,false);DrawPanel();
}

bool ValidInputs()
{
   if(InpMagic==0||(!InpAllowBuy&&!InpAllowSell)||InpMode<TESTER_ONLY||InpMode>REVIEWED_LIVE||InpTradeManagement<TM_FIXED_TP_INVALIDATION||InpTradeManagement>TM_PARTIAL_ATR_TRAIL)return false;
   if(InpRiskPercent<0||InpRiskPercent>100||InpHardRiskUSD<0|| (InpRiskPercent<=0&&InpHardRiskUSD<=0))return false;
   if(InpMaxLots<=0||InpCommissionUSDPerLotRoundTrip<0||InpSlippageReservePrice<=0||InpMaxDeviationPrice<0||InpMaxDeviationPrice>InpSlippageReservePrice||InpMinMarginLevel<0||InpMaxMarginUsePercent<0||InpMaxMarginUsePercent>100)return false;
   if(InpMaxDailyLossUSD<0||InpMaxDailyLossPercent<0||InpMaxDailyLossPercent>100||InpMaxWeeklyLossUSD<0||InpMaxWeeklyLossPercent<0||InpMaxWeeklyLossPercent>100||InpEquityFloorPercent<0||InpEquityFloorPercent>=100||InpMaxPeakDDPercent<0||InpMaxPeakDDPercent>100)return false;
   if(InpMaxConsecutiveLosses<0||InpLossStreakCooldownMinutes<0||InpMaxTradesPerDay<0||InpMaxTradesPerHour<0||InpCooldownMinutes<0||InpDailyProfitStopUSD<0||InpWeeklyProfitStopUSD<0)return false;
   if(InpTrendFastEMA<1||InpTrendSlowEMA<=InpTrendFastEMA||InpADXPeriod<1||InpMinM5ADX<0||InpMinM5ADX>100||InpM1ReferenceLookback<2||InpM1PullbackATR<=0||InpTurnInvalidationATR<0||InpMaxTurnCandleATR<0||InpSetupExpiryMinutes<0||InpMaxEntryAttemptsPerSetup<0)return false;
   if(InpATRPeriod<1||InpMinATRPrice<0||InpMaxATRPrice<0||(InpMaxATRPrice>0&&InpMinATRPrice>0&&InpMaxATRPrice<=InpMinATRPrice)||InpMaxSpreadPrice<0||InpMaxSpreadATR<0||InpSpikeATR<0||(InpUseSpikeEntryFilter&&InpSpikeATR<=0)||(InpUseSpikeEntryFilter&&InpSpikePauseMinutes<0)||InpMaxTickAgeSeconds<1)return false;
   if(InpStructurePaddingATR<0||InpMaxInitialSL_ATR<0||InpMaxHoldMinutes<0||InpStallExitMinutes<0||InpStallExitMinutes>0&&InpMaxHoldMinutes>0&&InpStallExitMinutes>InpMaxHoldMinutes||(InpTradeManagement!=TM_FIXED_TP_INVALIDATION&&InpStopStepATR<=0))return false;
   if(InpTradeManagement==TM_FIXED_TP_INVALIDATION && (InpTakeProfitR<=0||InpMinimumNetRewardRisk<0))return false;
   if(InpTradeManagement==TM_BE_ATR_TRAIL && (InpBreakEvenAtR<=0||InpTrailStartR<=0||InpTrailATR<=0))return false;
   if(InpTradeManagement==TM_PARTIAL_ATR_TRAIL && (InpTrailATR<=0||InpPartialAtR<=0||InpPartialClosePercent<=0||InpPartialClosePercent>=100))return false;
   if(InpBrokerCloseBufferMinutes<0||InpBrokerCloseBufferMinutes>=60)return false;
   if(InpUseSessionFilter && (InpSessionStartHour<0||InpSessionStartHour>23||InpSessionEndHour<0||InpSessionEndHour>23||InpSessionStartHour>=InpSessionEndHour||InpFridayCloseHour<InpSessionStartHour||InpFridayCloseHour>InpSessionEndHour||InpSessionBufferMinutes<0||InpSessionBufferMinutes>=60))return false;
   if(InpNewsBeforeMinutes<0||InpNewsAfterMinutes<0||InpTesterMinTrades<0)return false;
   return true;
}

void LogClosedTrades()
{
   for(int i=0;i<ArraySize(g_ledger);i++)
   {
      if(!g_ledger[i].ours||!g_ledger[i].closed||g_ledger[i].mixed)continue;
      int logged=-1;for(int j=0;j<ArraySize(g_loggedIds);j++)if(g_loggedIds[j]==g_ledger[i].id){logged=j;break;}
      if(logged<0&&g_ledger[i].exited<=g_lastJournalExit)continue;if(logged>=0&&MathAbs(g_loggedNet[logged]-g_ledger[i].net)<0.000001)continue;
      bool correction=logged>=0;if(logged<0){logged=ArraySize(g_loggedIds);ArrayResize(g_loggedIds,logged+1);ArrayResize(g_loggedNet,logged+1);g_loggedIds[logged]=g_ledger[i].id;}
      g_loggedNet[logged]=g_ledger[i].net;
      if(!correction)
      {
         if(g_ledger[i].exit_reason==DEAL_REASON_TP)g_diag.exits_tp++;
         else if(g_ledger[i].exit_reason==DEAL_REASON_SL)
         {
            if(g_ledger[i].management==TM_BE_ATR_TRAIL||g_ledger[i].management==TM_PARTIAL_ATR_TRAIL)g_diag.exits_be_trail++;
            else g_diag.exits_sl++;
         }
      }
      Journal(correction?"CORRECTED_TRADE":"CLOSED_TRADE",StringFormat("Position %I64u net %.4f USD",g_ledger[i].id,g_ledger[i].net),g_ledger[i].setup,g_ledger[i].entry_value/g_ledger[i].entered_volume,g_ledger[i].exit_value/g_ledger[i].exited_volume,0,0,g_ledger[i].entered_volume);
      Notify(SetupName(g_ledger[i].setup)+" closed: $"+DoubleToString(g_ledger[i].net,2));
   }
   g_lastJournalExit=g_lastExit;
}
void PrintDiagnostics()
{
   if(g_diagPrinted)return;g_diagPrinted=true;
   Print("===== ASTRA 2.01 DIAGNOSTICS =====");
   PrintFormat("Bars evaluated: %I64d | Bull M5: %I64d | Bear M5: %I64d | Neutral M5: %I64d",g_diag.m1_bars,g_diag.m5_bull,g_diag.m5_bear,g_diag.m5_neutral);
   PrintFormat("Pullbacks: %I64d | Turns: %I64d | Tolerance updates: %I64d | Invalidations: %I64d | Expiries: %I64d",g_diag.pullbacks,g_diag.turns,g_diag.turn_tolerance,g_diag.turn_invalidations,g_diag.expiries);
   PrintFormat("Crosses: %I64d | Entry attempts: %I64d | Orders sent: %I64d | Fills: %I64d",g_diag.live_crosses,g_diag.entry_attempts,g_diag.orders_sent,g_diag.fills);
   PrintFormat("Rejected risk: %I64d | spread: %I64d | ATR: %I64d | spike: %I64d | cooldown: %I64d | hour: %I64d | day: %I64d",g_diag.reject_risk,g_diag.reject_spread,g_diag.reject_atr,g_diag.reject_spike,g_diag.reject_cooldown,g_diag.reject_hour,g_diag.reject_day);
   PrintFormat("Rejected session: %I64d | broker-session: %I64d | news event: %I64d | news unavailable: %I64d | stale: %I64d | stop: %I64d | max-stop: %I64d",g_diag.reject_session,g_diag.reject_broker_session,g_diag.reject_news_actual,g_diag.reject_news_unavailable,g_diag.reject_stale,g_diag.reject_stop,g_diag.reject_max_stop);
   PrintFormat("Rejected margin: %I64d | foreign: %I64d | broker: %I64d | fill: %I64d | OrderCheck: %I64d | send: %I64d",g_diag.reject_margin,g_diag.reject_foreign,g_diag.reject_broker,g_diag.reject_fill,g_diag.reject_ordercheck,g_diag.reject_send);
   PrintFormat("Partials: %I64d | unavailable: %I64d | stop modifications: %I64d | rejects: %I64d",g_diag.partials,g_diag.partial_unavailable,g_diag.stop_modifications,g_diag.stop_modify_rejects);
   PrintFormat("Exits TP: %I64d | SL: %I64d | BE/trail: %I64d | max hold: %I64d | stall: %I64d | flip: %I64d | news: %I64d | session: %I64d | spike: %I64d | emergency: %I64d",g_diag.exits_tp,g_diag.exits_sl,g_diag.exits_be_trail,g_diag.exits_maxhold,g_diag.exits_stall,g_diag.exits_flip,g_diag.exits_news,g_diag.exits_session,g_diag.exits_spike,g_diag.exits_emergency);
   PrintFormat("Completed positions: %d",ArraySize(g_ledger));Print("===================================");
}

bool ServiceProtection(const bool manage_positions=true)
{
   datetime now=Now();if(now<=0)return false;
   bool need_history=g_historyDirty||!g_historyOK||DayStart(now)!=DayStart(g_lastHistory);
   if(need_history){if(!RefreshHistory())Status("History unavailable: new entries blocked");else{LogClosedTrades();DrawTradeMarkers();}}
   UpdateRisk();g_sessionOK=SessionClear(now,0);
   if(g_hardKill!=0||g_pause!=0)Flatten(g_hardKill!=0?"Account emergency lock":"Manual pause");
   if(InpUseNewsFilter)
   {
      if(!g_test)RefreshNativeNews();
      string why;bool clear=NewsClear(now,InpMaxHoldMinutes>0?InpMaxHoldMinutes*60:0,why);
      g_newsBlocked=!clear;g_newsReason=why;
      if(g_newsBlocked&&!g_prevNewsBlocked)Journal(g_newsActualBlocked?"NEWS_BLOCK_START":"NEWS_UNAVAILABLE_BLOCK","News permission blocked: "+why);
      if(!g_newsBlocked&&g_prevNewsBlocked)Journal("NEWS_BLOCK_END","News permission clear");
      g_prevNewsBlocked=g_newsBlocked;
   }
   else {g_newsBlocked=false;g_newsActualBlocked=false;g_newsUnavailable=false;g_newsReason="NEWS OFF";}
   if(g_newsUnavailable&&!g_prevNewsUnavailable)Journal("NEWS_UNAVAILABLE","News feed unavailable; fail-closed policy applies");
   if(!g_newsUnavailable&&g_prevNewsUnavailable)Journal("NEWS_AVAILABLE","News feed permission restored");g_prevNewsUnavailable=g_newsUnavailable;
   MqlTick q;bool quote_ok=QuoteFresh(q);if(!quote_ok)ClearCrossObservation();
   g_spreadOK=quote_ok&&g_atr>0&&(InpMaxSpreadPrice<=0||q.ask-q.bid<=InpMaxSpreadPrice)&&(InpMaxSpreadATR<=0||(q.ask-q.bid)/g_atr<=InpMaxSpreadATR);
   if(CountOwned()>0&&CountForeignSameSymbolExposure()>0) { Emergency(6,"Other same-symbol exposure detected: exit ASTRA and review");Flatten("Mixed same-symbol exposure"); }
   ObserveSpike();if(g_spikeUntil>0&&Now()>=g_spikeUntil){Journal("SPIKE_BLOCK_END","Automatic volatility cooldown expired");g_spikeUntil=0;SaveState(false);}
   ExpireEntrySetup();if(manage_positions)ManagePositions();
   if(now-g_lastFlush>=30){SaveState(true);g_lastFlush=now;}
   return g_historyOK;
}

int OnInit()
{
   ZeroMemory(g_diag);g_test=(bool)MQLInfoInteger(MQL_TESTER);g_opt=(bool)MQLInfoInteger(MQL_OPTIMIZATION);
   if(!ValidInputs()){Print("ASTRA: invalid inputs; check mathematically impossible combinations.");return INIT_PARAMETERS_INCORRECT;}
   string symbol=_Symbol;StringToUpper(symbol);if(StringFind(symbol,"XAUUSD")<0||SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT)!="USD"){Print("ASTRA requires an XAUUSD symbol with USD profit currency (broker suffix allowed).");return INIT_FAILED;}
   string currency=AccountInfoString(ACCOUNT_CURRENCY);StringToUpper(currency);if(currency=="USD")g_units=1;else if(currency=="USC"||currency=="USCENT")g_units=100;else{Print("ASTRA supports USD or explicitly labeled USC/USCENT accounts only; no guessed conversion.");return INIT_FAILED;}
   if(TickSize()<=0||SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)<=0||SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)<=0){Print("ASTRA: broker symbol specification unavailable.");return INIT_FAILED;}
   uint server=Hash(AccountInfoString(ACCOUNT_SERVER));g_stateKey=StringFormat("AG.%I64d.%u.%u.%I64u.",AccountInfoInteger(ACCOUNT_LOGIN),server,Hash(_Symbol),InpMagic);if(StringLen(g_stateKey)>48){Print("ASTRA: magic/account key too long.");return INIT_FAILED;}
   g_ui="AG_UI_"+StringFormat("%I64d",ChartID())+"_";g_stateFile=g_stateKey+"state.csv";
   if(!g_test)
   {
      string lock=StringFormat("ASTRA_lock_%I64d_%u_%u_%I64u.bin",AccountInfoInteger(ACCOUNT_LOGIN),server,Hash(_Symbol),InpMagic);
      g_lease=FileOpen(lock,FILE_READ|FILE_WRITE|FILE_BIN|FILE_COMMON);if(g_lease==INVALID_HANDLE){Print("ASTRA: another identical instance owns this strategy, or lock file cannot open.");return INIT_FAILED;}
   }
   if(!RestorePersistentState()){Print("ASTRA: invalid/unreadable saved protection state; review required.");return INIT_FAILED;}
   g_initial=Load("initial",Equity());g_peak=Load("peak",Equity());g_startTime=(datetime)Load("start",(double)Now());if(g_initial<=0||g_peak<=0||g_startTime<=0)return INIT_FAILED;
   g_pause=(int)Load("pause",0);g_hardKill=(int)Load("hard",0);
   // 2.00 used pause code 2 for the routine consecutive-loss lock. That
   // temporary condition is autonomous in 2.01; retain manual/emergency codes.
   if(g_legacyStateV1 && g_pause==2){g_pause=0;Journal("STATE_MIGRATED","Cleared legacy consecutive-loss pause; protection baselines retained");}
   g_dayLock=(datetime)Load("daylock",0);g_weekLock=(datetime)Load("weeklock",0);g_dayProfitLock=(datetime)Load("dayprofit",0);g_weekProfitLock=(datetime)Load("weekprofit",0);g_ackStreak=(datetime)Load("ack",0);g_spikeUntil=(datetime)Load("spike",0);g_lossStreakCooldownUntil=(datetime)Load("loss_cooldown",0);g_lossStreakCooldownStreak=(int)Load("loss_streak",0);g_x=(int)Load("x",12);g_y=(int)Load("y",24);g_collapsed=Load("small",0)>0;
   g_positionId=((ulong)Load("pid_hi",0)<<32)|(ulong)Load("pid_lo",0);g_initialR=Load("initial_r",0);g_openRiskBudget=Load("open_budget",0);g_positionSetup=(int)Load("setup",0);g_openFeePerLot=Load("fee",InpCommissionUSDPerLotRoundTrip);g_referenceSL=Load("ref_sl",0);g_initialVolume=Load("entry_volume",0);g_partialDone=Load("partial_done",1)>0;g_openManagement=(int)Load("management",-1);g_guardSL=Load("guard_sl",g_referenceSL);
   if(InpJournal&&!g_opt)
   {
      string file=StringFormat("ASTRA2_%I64d_%u_%I64u_%s_%I64d.csv",AccountInfoInteger(ACCOUNT_LOGIN),Hash(_Symbol),InpMagic,g_test?"TEST":"FORWARD",(long)Now());
      g_journal=FileOpen(file,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ,';');if(g_journal==INVALID_HANDLE){Print("ASTRA: requested journal cannot be opened.");return INIT_FAILED;}
      if(FileSize(g_journal)==0)FileWrite(g_journal,"server_time","event","setup","detail","expected","actual","sl","tp","lots","modeled_risk_usd","budget_usd","min_lot_risk_usd","spread_price","atr_price","entry_state","frozen_trigger","invalidation","management","balance_usd","equity_usd","drawdown_pct","news_mode");FileSeek(g_journal,0,SEEK_END);
   }
   g_trade.SetExpertMagicNumber(InpMagic);g_trade.SetAsyncMode(false);g_trade.SetTypeFillingBySymbol(_Symbol);g_hFast=iMA(_Symbol,PERIOD_M5,InpTrendFastEMA,0,MODE_EMA,PRICE_CLOSE);g_hSlow=iMA(_Symbol,PERIOD_M5,InpTrendSlowEMA,0,MODE_EMA,PRICE_CLOSE);g_hATR=iATR(_Symbol,PERIOD_M1,InpATRPeriod);if(InpUseM5ADXFilter||InpUseM5DIFilter)g_hADX=iADX(_Symbol,PERIOD_M5,InpADXPeriod);
   if(g_hFast==INVALID_HANDLE||g_hSlow==INVALID_HANDLE||g_hATR==INVALID_HANDLE||((InpUseM5ADXFilter||InpUseM5DIFilter)&&g_hADX==INVALID_HANDLE))return INIT_FAILED;
   g_newsBypass=g_test&&InpTesterSkipNews;
   if(InpUseNewsFilter){if(g_test)g_newsOK=g_newsBypass||LoadNewsCSV();else RefreshNativeNews();}
   if(!RefreshHistory())Print("ASTRA: waiting for trade history before entries.");g_lastJournalExit=g_lastExit;BuildSnapshot();g_bar=iTime(_Symbol,PERIOD_M1,0);ResetEntrySetup("Initialization");g_setupAfter=g_bar>0?g_bar-1:0;SizingPreview();SaveState(false);SavePosition();if(!g_stateOK)return INIT_FAILED;
   Journal("START",StringFormat("Mode=%s; currency=%s; unit conversion=%.0f; min lot=%.4f; contract=%.2f; account leverage=%I64d",EnumToString(InpMode),currency,g_units,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE),AccountInfoInteger(ACCOUNT_LEVERAGE)));
   Journal("CONFIG",StringFormat("v2.01; management=%s; riskPct=%.2f hardUSD=%.2f; pullbackATR=%.2f lookback=%d expiry=%d; M5Close=%s; news=%s; session=%s",ManagementModeName((int)InpTradeManagement),InpRiskPercent,InpHardRiskUSD,InpM1PullbackATR,InpM1ReferenceLookback,InpSetupExpiryMinutes,InpRequireM5CloseBeyondFastEMA?"ON":"OFF",InpUseNewsFilter?"ON":"OFF",InpUseSessionFilter?"ON":"OFF"));
   if(g_newsBypass||!InpUseNewsFilter)Journal("RESEARCH_WARNING",g_newsBypass?"NEWS BYPASSED: results do not validate production news protection.":"NEWS FILTER OFF: production news protection not validated.");
   if(!EventSetTimer(1))return INIT_FAILED;Status(ModeAllowsEntries()?"Ready; wait for a fresh M1 candle":"Entries disabled by environment setting");DrawPanel();return INIT_SUCCEEDED;
}
void OnTick()
{
   ServiceProtection(false);datetime bar=iTime(_Symbol,PERIOD_M1,0);
   if(bar>0&&bar!=g_bar)
   {
      datetime previous_bar=g_bar;g_bar=bar;bool gap=previous_bar<=0||bar-previous_bar!=60;g_diag.m1_bars++;g_ready=BuildSnapshot();
      if(g_ready){if(g_bias==1)g_diag.m5_bull++;else if(g_bias==-1)g_diag.m5_bear++;else g_diag.m5_neutral++;}
      if(!g_ready||gap){ResetEntrySetup(gap?"M1 feed/session gap; no catch-up setup":"Indicator history not ready");Status(gap?"Feed synchronized; wait for a fresh M1 bar":"Waiting for closed-bar indicator history");}
      else UpdateClosedBarSetup();SizingPreview();
   }
   ManagePositions();if(g_pause!=0||g_hardKill!=0||CountOwned()>0){ResetEntrySetup("Exposure or risk review");return;}ProcessLiveEntryTrigger();
}
void OnTimer(){ServiceProtection();SizingPreview();DrawPanel();}
void OnTradeTransaction(const MqlTradeTransaction &transaction,const MqlTradeRequest &request,const MqlTradeResult &result){g_historyDirty=true;}
double OnTester()
{
   if(!RefreshHistory())return -1000000.0;LogClosedTrades();int trades=0;double winners=0,losers=0;
   for(int i=0;i<ArraySize(g_ledger);i++){if(!g_ledger[i].ours||!g_ledger[i].closed||g_ledger[i].mixed)continue;trades++;if(g_ledger[i].net>0)winners+=g_ledger[i].net;else losers-=g_ledger[i].net;}
   if((InpTesterMinTrades>0&&trades<InpTesterMinTrades)||trades==0){PrintDiagnostics();return -1000000.0;}
   double dd=TesterStatistics(STAT_EQUITY_DDREL_PERCENT),pf=losers>0?winners/losers:(winners>0?5.0:0.0),net=winners-losers;
   if(g_newsBypass||!InpUseNewsFilter)Journal("RESEARCH_WARNING","OnTester score does not validate production-news behavior.");
   PrintDiagnostics();return net<=0?net/(1+dd):net*MathMin(pf,5.0)*MathLog(1+trades)/(1+dd);
}
void OnDeinit(const int reason)
{
   EventKillTimer();if(g_initial>0&&g_stateKey!=""){SaveState(false);SavePosition();}PrintDiagnostics();if(g_ui!="")ClearPanel();
   if(g_hFast!=INVALID_HANDLE)IndicatorRelease(g_hFast);if(g_hSlow!=INVALID_HANDLE)IndicatorRelease(g_hSlow);if(g_hATR!=INVALID_HANDLE)IndicatorRelease(g_hATR);if(g_hADX!=INVALID_HANDLE)IndicatorRelease(g_hADX);
   if(g_journal!=INVALID_HANDLE)FileClose(g_journal);if(g_lease!=INVALID_HANDLE)FileClose(g_lease);
   // Broker SL/TP remain. Removing or stopping the EA stops timed/news exits.
}
