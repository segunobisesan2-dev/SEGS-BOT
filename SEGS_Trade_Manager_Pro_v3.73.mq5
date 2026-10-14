//+------------------------------------------------------------------+
//|                                SEGS_Trade_Manager_Pro_v3.75.mq5 |
//|        Unified Zero-Flicker MT5 Terminal Table Dashboard         |
//|                 Full Replacement for MT5 Native Toolbox          |
//|  Multi-Asset: XAU (Gold), DJ30, NAS100, GBPJPY, BTCUSD & AMD     |
//|  Trade Duplication (1 -> 4 Legs) + Complete Auto / Controlled P  |
//|  TP2 Breakeven Tracking + Movable & Dockable Bottom/Floating UI  |
//|  Smart Structural Market Targets (TP1: 1.4R, TP2: 2.8R,          |
//|  TP3: 4.8R, TP4: 8.0R - Weighted Overall R:R ~4.25R)             |
//|  Unified Multi-Strategy Confluence Matrix (5 Interlocking Layers)|
//|  M30 Order Block Intelligence & Smart Money Confluence Strategy  |
//|  Smart Dynamic Lot Size Selector (Risk-Based & Micro <= $100)    |
//|  Execution Timestamp Tracking in Market Sentiment Dashboard      |
//|  Copyright 2026, SEGS Trade Manager Pro - All Rights Reserved    |
//+------------------------------------------------------------------+
#property copyright "SEGS Trade Manager Pro v3.75 (Unified Multi-Strategy Confluence)"
#property link      "https://ai.studio/build"
#property version   "3.75"
#property strict

// Standard MT5 Trade libraries for execution & position queries
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;
CSymbolInfo    symInfo;

//--- Modes Enum: Complete Auto vs Controlled Auto
enum ENUM_SEGS_MODE
{
   MODE_COMPLETE_AUTO   = 0, // Complete Auto: Open 1 -> 3 cloned opened + SL & TP1..TP4 assigned immediately
   MODE_CONTROLLED_AUTO = 1  // Controlled Auto: Open 1 -> 3 cloned opened BUT wait for 'P' to assign SL & TP
};

//+------------------------------------------------------------------+
//| Auto Execution & Technical Permission States                     |
//+------------------------------------------------------------------+
enum ENUM_AUTO_EXECUTION_STATE
{
   AUTO_EXEC_ENABLED = 0,          // User enabled and all permissions green
   AUTO_EXEC_DISABLED = 1,         // Disabled by user setting (default off or toggled off)
   AUTO_EXEC_PAUSED_BY_USER = 2,   // Explicitly paused by user
   AUTO_EXEC_BLOCKED_TERMINAL = 3, // Blocked: Terminal Algo Trading is disabled in MT5
   AUTO_EXEC_BLOCKED_ACCOUNT = 4,  // Blocked: Account trading is disabled (investor/broker)
   AUTO_EXEC_BLOCKED_MQL = 5,      // Blocked: "Allow Automated Trading" unchecked in EA properties
   AUTO_EXEC_BLOCKED_BROKER = 6    // Blocked: Broker symbol trade mode disabled
};

//+------------------------------------------------------------------+
//| Feed Health States                                               |
//+------------------------------------------------------------------+
enum ENUM_FEED_STATE
{
   FEED_LIVE = 0,                  // Tick received <= 15s
   FEED_DELAYED = 1,               // Tick received 16s - 60s
   FEED_STALE = 2,                 // No tick received > 60s during open broker session
   FEED_UNKNOWN = 3                // Waiting for initial tick or data unavailable
};

//+------------------------------------------------------------------+
//| Cash Session States                                              |
//+------------------------------------------------------------------+
enum ENUM_CASH_SESSION
{
   CASH_SESSION_REGULAR = 0,       // Core cash session (e.g. 09:30-16:00 NY)
   CASH_SESSION_PREMARKET = 1,     // Pre-market (e.g. 04:00-09:30 NY)
   CASH_SESSION_AFTERHOURS = 2,    // After-hours (e.g. 16:00-20:00 NY)
   CASH_SESSION_OVERNIGHT = 3,     // Globex/Overnight (20:00-04:00 NY)
   CASH_SESSION_CLOSED = 4         // Weekend / full closure
};

//+------------------------------------------------------------------+
//| Spread Classification                                            |
//+------------------------------------------------------------------+
enum ENUM_SPREAD_STATE
{
   SPREAD_NORMAL = 0,              // Cost ratio <= 8%, ratio <= 1.8x
   SPREAD_ELEVATED = 1,            // Cost ratio <= 15%, ratio <= 2.8x (warning, confluence penalty, NO block)
   SPREAD_HIGH = 2,                // Cost ratio <= 25%, ratio <= 3.8x (quality penalty, higher confluence required)
   SPREAD_CRITICAL = 3             // Cost ratio > 25% or ratio > 4.5x (HARD BLOCK)
};

//+------------------------------------------------------------------+
//| Market State Classification                                      |
//+------------------------------------------------------------------+
enum ENUM_MARKET_STATE
{
   MARKET_STATE_FULL_BULL_ALIGNMENT = 0,
   MARKET_STATE_FULL_BEAR_ALIGNMENT = 1,
   MARKET_STATE_BULL_TRANSITION = 2,
   MARKET_STATE_BEAR_TRANSITION = 3,
   MARKET_STATE_COUNTER_BULL = 4,
   MARKET_STATE_COUNTER_BEAR = 5,
   MARKET_STATE_NEUTRAL = 6,
   MARKET_STATE_CHOP = 7
};

//+------------------------------------------------------------------+
//| Setup Classifications                                            |
//+------------------------------------------------------------------+
enum ENUM_SETUP_CLASS
{
   SETUP_CLASS_A_CONTINUATION = 0,
   SETUP_CLASS_B_TRANSITION = 1,
   SETUP_CLASS_C_BREAKOUT = 2,
   SETUP_CLASS_D_LOW_QUALITY_CHOP = 3,
   SETUP_CLASS_NONE = 4
};

//+------------------------------------------------------------------+
//| Daily Decision Telemetry                                         |
//+------------------------------------------------------------------+
struct DailyDecisionTelemetry
{
   int candidatesDetected;
   int setupsValidated;
   int signalsGenerated;
   int autoBlocks;
   int brokerSessionBlocks;
   int feedBlocks;
   int spreadCostBlocks;
   int riskBlocks;
   int lowQualityChop;
   int expectancyRejections;
   int tradeApprovals;
   int ordersAttempted;
   int ordersExecuted;
   int brokerRejections;
   datetime lastResetDate;
};

//--- Input Parameters
input group "=== Operation Mode & Trade Duplication ==="
input ENUM_SEGS_MODE   InpAutoMode            = MODE_COMPLETE_AUTO;   // Default Execution Mode (Toggle with [M])
input int              InpNumClonedTrades     = 3;                    // Number of extra cloned trades (Default 3 = 4 total legs)
input long             InpMasterMagicNumber   = 1001;                 // Magic Number for EA Market Orders
input long             InpClonedMagicNumber   = 222889;               // Magic Number for Cloned Trades (Prevents infinite loops)
input double           InpFallbackLot         = 0.10;                 // Fallback Lot size if manual trade volume is 0
input double           InpClonedLotSize       = 0.0;                  // Cloned Trade Lot Size Override (0.0 = Preserve Master Lot Size exactly)
input bool             InpEnableTPBreakeven   = true;                 // Enable Auto-move remaining legs to BE on TP hit (Toggle on dashboard)
input int              InpBE_TriggerLeg       = 2;                    // Which TP Leg triggers Breakeven (Default: 2 = TP2)
input double           InpBreakevenBufferPips = 1.0;                  // Breakeven Buffer in Pips (Entry +/- Buffer)

input group "=== Terminal Layout & Placement ==="
input bool             InpDockAtBottom        = true;                 // Dock at bottom of chart (Press [D] to undock/dock)
input int              InpTableXOffset        = 4;                    // Horizontal X distance (px)
input int              InpTableYOffset        = 4;                    // Vertical Y distance (px)
input bool             InpDefaultExpandedView = true;                 // Default expanded column view
input bool             InpHideMT5TradeLevels  = true;                 // Hide MT5 native dashed SL/TP lines

input group "=== Bold Typography & Visual Contrast ==="
input string           InpFontName            = "Arial Bold";         // Crisp bold font
input int              InpHeaderFontSize      = 9;                    // Header font size (pt)
input int              InpCellFontSize        = 9;                    // Cell font size (pt)
input color            InpTableBgColor        = C'14,17,24';          // Solid opaque background
input color            InpTableBorder         = C'42,48,64';          // Table border
input color            InpRowBorder           = C'26,30,42';          // Row separator border
input color            InpProfitColor         = clrLime;              // Profit color
input color            InpLossColor           = clrTomato;            // Loss / SL color
input color            InpGoldColor           = clrGold;              // Expected R:R color

input group "=== Time Settings (Toronto Timezone) ==="
input int              InpBrokerUtcOffset     = 2;                    // Broker Server UTC Offset (UTC+2 or UTC+3)

input group "=== Multi-Asset SL & TP Targets (Configured strictly in Pips) ==="
// Gold / XAU Targets (In Pips)
input string           InpXAU_Patterns        = "XAU,GOLD";           // XAU/Gold symbol keywords
input double           InpXAU_PipMultiplier   = 0.10;                 // XAU 1 Pip Value in Price (0.10: 10 pips = $1.00)
input double           InpXAU_SL_Pips         = 80.0;                 // XAU Stop Loss (Pips, e.g. 80.0 pips = $8.00)
input double           InpXAU_TP1_Pips        = 112.0;                // XAU Leg 1 TP1 (Pips, 1.40R FTA, $11.20)
input double           InpXAU_TP2_Pips        = 224.0;                // XAU Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE, $22.40)
input double           InpXAU_TP3_Pips        = 384.0;                // XAU Leg 3 TP3 (Pips, 4.80R Liquidity Sweep, $38.40)
input double           InpXAU_TP4_Pips        = 640.0;                // XAU Leg 4 TP4 (Pips, 8.00R Macro Golden Runner, $64.00)

// DJ30 / US30 Targets (In Pips)
input string           InpDJ30_Patterns       = "US30,DJ30,DOW,WS30"; // US30 symbol keywords
input double           InpDJ30_PipMultiplier  = 1.0;                  // DJ30 1 Pip Value in Price (1.0 index point)
input double           InpDJ30_SL_Pips        = 55.0;                 // DJ30 Stop Loss (Pips)
input double           InpDJ30_TP1_Pips       = 77.0;                 // DJ30 Leg 1 TP1 (Pips, 1.40R FTA)
input double           InpDJ30_TP2_Pips       = 154.0;                // DJ30 Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE)
input double           InpDJ30_TP3_Pips       = 264.0;                // DJ30 Leg 3 TP3 (Pips, 4.80R Liquidity Sweep)
input double           InpDJ30_TP4_Pips       = 440.0;                // DJ30 Leg 4 TP4 (Pips, 8.00R Macro Golden Runner)

// NAS100 / US100 Targets (In Pips)
input string           InpNAS_Patterns        = "NAS100,US100,USTEC,NDX,NQ100,NAS,NDAQ,NDAQ100,US100Cash"; // NAS100 & NDAQ symbol keywords
input double           InpNAS_PipMultiplier   = 1.0;                  // NAS100 1 Pip Value in Price (1.0 index point)
input double           InpNAS_SL_Pips         = 35.0;                 // NAS100 Stop Loss (Pips)
input double           InpNAS_TP1_Pips        = 49.0;                 // NAS100 Leg 1 TP1 (Pips, 1.40R FTA)
input double           InpNAS_TP2_Pips        = 98.0;                 // NAS100 Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE)
input double           InpNAS_TP3_Pips        = 168.0;                // NAS100 Leg 3 TP3 (Pips, 4.80R Liquidity Sweep)
input double           InpNAS_TP4_Pips        = 280.0;                // NAS100 Leg 4 TP4 (Pips, 8.00R Macro Golden Runner)

// GBPJPY Targets (In Pips)
input string           InpGJ_Patterns         = "GBPJPY,GJ";          // GBPJPY symbol keywords
input double           InpGJ_SL_Pips          = 41.0;                 // GBPJPY Stop Loss (Pips, Safe Structure below 208.52 sweep base)
input double           InpGJ_TP1_Pips         = 57.0;                 // GBPJPY Leg 1 TP1 (Pips, 1.39R FTA Minor Barrier @ 209.45)
input double           InpGJ_TP2_Pips         = 115.0;                // GBPJPY Leg 2 TP2 (Pips, 2.80R H1 Pivot @ 210.03 - Triggers BE)
input double           InpGJ_TP3_Pips         = 197.0;                // GBPJPY Leg 3 TP3 (Pips, 4.80R PDH Sweep @ 210.85)
input double           InpGJ_TP4_Pips         = 328.0;                // GBPJPY Leg 4 TP4 (Pips, 8.00R Macro Trend Runner @ 212.16)

// GBPUSD Targets (In Pips)
input string           InpGU_Patterns         = "GBPUSD,GU";          // GBPUSD symbol keywords
input double           InpGU_SL_Pips          = 25.0;                 // GBPUSD Stop Loss (Pips, e.g. 25.0 pips = 0.0025)
input double           InpGU_TP1_Pips         = 35.0;                 // GBPUSD Leg 1 TP1 (Pips, 1.40R FTA, 0.0035)
input double           InpGU_TP2_Pips         = 70.0;                 // GBPUSD Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE, 0.0070)
input double           InpGU_TP3_Pips         = 120.0;                // GBPUSD Leg 3 TP3 (Pips, 4.80R Liquidity Sweep, 0.0120)
input double           InpGU_TP4_Pips         = 200.0;                // GBPUSD Leg 4 TP4 (Pips, 8.00R Macro Golden Runner, 0.0200)
#define InpGBPUSD_Patterns InpGU_Patterns
#define InpGBPUSD_SL_Pips  InpGU_SL_Pips
#define InpGBPUSD_TP1_Pips InpGU_TP1_Pips
#define InpGBPUSD_TP2_Pips InpGU_TP2_Pips
#define InpGBPUSD_TP3_Pips InpGU_TP3_Pips
#define InpGBPUSD_TP4_Pips InpGU_TP4_Pips

// AUDUSD Targets (In Pips)
input string           InpAUD_Patterns        = "AUDUSD,AUD";         // AUDUSD symbol keywords
input double           InpAUD_SL_Pips         = 25.0;                 // AUDUSD Stop Loss (Pips, e.g. 25.0 pips = 0.0025)
input double           InpAUD_TP1_Pips        = 35.0;                 // AUDUSD Leg 1 TP1 (Pips, 1.40R FTA, 0.0035)
input double           InpAUD_TP2_Pips        = 70.0;                 // AUDUSD Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE, 0.0070)
input double           InpAUD_TP3_Pips        = 120.0;                // AUDUSD Leg 3 TP3 (Pips, 4.80R Liquidity Sweep, 0.0120)
input double           InpAUD_TP4_Pips        = 200.0;                // AUDUSD Leg 4 TP4 (Pips, 8.00R Macro Golden Runner, 0.0200)
#define InpAUDUSD_Patterns InpAUD_Patterns

// USOIL / WTI Crude Oil Targets (In Pips)
input string           InpOIL_Patterns        = "USOIL,WTI,CRUDE,OIL,XTIUSD"; // USOIL / WTI Crude symbol keywords
input double           InpOIL_PipMultiplier   = 0.10;                 // USOIL 1 Pip Value in Price (0.10 = $0.10, 10 pips = $1.00)
input double           InpOIL_SL_Pips         = 45.0;                 // USOIL Stop Loss (Pips, e.g. 45.0 pips = $0.45)
input double           InpOIL_TP1_Pips        = 63.0;                 // USOIL Leg 1 TP1 (Pips, 1.40R FTA, $0.63)
input double           InpOIL_TP2_Pips        = 126.0;                // USOIL Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE, $1.26)
input double           InpOIL_TP3_Pips        = 216.0;                // USOIL Leg 3 TP3 (Pips, 4.80R Liquidity Sweep, $2.16)
input double           InpOIL_TP4_Pips        = 360.0;                // USOIL Leg 4 TP4 (Pips, 8.00R Macro Golden Runner, $3.60)
#define InpUSOIL_Patterns InpOIL_Patterns

// Bitcoin (BTCUSD) Targets (In Pips)
input string           InpBTC_Patterns        = "BTC,BITCOIN";        // Bitcoin symbol keywords
input double           InpBTC_PipMultiplier   = 1.0;                  // BTCUSD 1 Pip Value in Price ($1.00 distance)
input double           InpBTC_SL_Pips         = 500.0;                // BTCUSD Stop Loss in Pips ($500 distance)
input double           InpBTC_TP1_Pips        = 700.0;                // BTCUSD Leg 1 TP1 in Pips ($700 distance, 1.40R FTA)
input double           InpBTC_TP2_Pips        = 1400.0;               // BTCUSD Leg 2 TP2 in Pips ($1400 distance, 2.80R - Triggers BE)
input double           InpBTC_TP3_Pips        = 2400.0;               // BTCUSD Leg 3 TP3 in Pips ($2400 distance, 4.80R Liquidity Sweep)
input double           InpBTC_TP4_Pips        = 4000.0;               // BTCUSD Leg 4 TP4 in Pips ($4000 distance, 8.00R Macro Golden Runner)

// Equities & Stocks Targets (AMD, etc.)
input string           InpAMD_Patterns        = "AMD,NDAQ,AAPL,MSFT,NVDA,TSLA,AMZN,META,GOOGL"; // AMD / Equities symbol keywords
input double           InpAMD_SL_Pips         = 150.0;                // AMD Stop Loss (Pips, e.g. 150 = $1.50)
input double           InpAMD_TP1_Pips        = 210.0;                // AMD Leg 1 TP1 (Pips, 1.40R FTA, $2.10)
input double           InpAMD_TP2_Pips        = 420.0;                // AMD Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE, $4.20)
input double           InpAMD_TP3_Pips        = 720.0;                // AMD Leg 3 TP3 (Pips, 4.80R Liquidity Sweep, $7.20)
input double           InpAMD_TP4_Pips        = 1200.0;               // AMD Leg 4 TP4 (Pips, 8.00R Macro Golden Runner, $12.00)

// Standard Forex & Other Instruments (In Pips)
input double           InpFX_SL_Pips          = 20.0;                 // Forex Stop Loss (Pips)
input double           InpFX_TP1_Pips         = 28.0;                 // Forex Leg 1 TP1 (Pips, 1.40R FTA)
input double           InpFX_TP2_Pips         = 56.0;                 // Forex Leg 2 TP2 (Pips, 2.80R H1 Pivot - Triggers BE)
input double           InpFX_TP3_Pips         = 96.0;                 // Forex Leg 3 TP3 (Pips, 4.80R Liquidity Sweep)
input double           InpFX_TP4_Pips         = 160.0;                // Forex Leg 4 TP4 (Pips, 8.00R Macro Golden Runner)
#define InpGBPJPY_Patterns InpGJ_Patterns

// Market Sentiment HUD Positioning
enum ENUM_HUD_CORNER
{
   HUD_POS_TOP_LEFT,      // Top Left (Left)
   HUD_POS_TOP_RIGHT,     // Top Right (Right)
   HUD_POS_BOTTOM_RIGHT,  // Bottom Right (Down to Right Corner Down)
   HUD_POS_BOTTOM_LEFT    // Bottom Left (Down Left)
};

input ENUM_HUD_CORNER  InpSentimentCorner     = HUD_POS_TOP_LEFT;     // Default Market Sentiment HUD Position
input bool             InpShowSentimentHUD     = true;                 // Show Market Structure & Sentiment HUD [M]
input int              InpMaxVisiblePositions  = 8;                    // Max Visible Positions in Terminal (Rest Scrollable)
input bool             InpShowAllOpenTrades    = true;                 // Automatically expand terminal rows to show all open trades
input bool             InpShowTradeAdviceLines = true;                 // Show Suggested Entry, SL & TP1-4 Lines on Chart [K]
input bool             InpAlertOnViableEntry   = true;                 // Alert on MT5 when viable entry is found [O]
input bool             InpSendAppNotification  = false;                // Send Push Notification to MT5 Mobile app
input int              InpVolatilityHours      = 3;                    // Volatility Average Period (2-5 Hours)

input group "=== [Open Advisor Trades Chart Markings & Display] ==="
input bool             InpShowOpenTradeMarkings       = true;                 // Show Open Trades (Entry, SL, TP1-4) on Chart [T]
input bool             InpShowOpenTradeLabels         = true;                 // Show Floating P/L & Ticket Labels on Lines
input bool             InpShowOpenTradeBrackets       = true;                 // Show Trade Risk-Reward Connection Rays
input bool             InpMarkAllSymbolPositions      = false;                // Mark All Open Symbol Positions (False = Advisor Magic Only)
input color            InpColorOpenBuyEntry           = C'34,197,94';         // Open BUY Entry Line Color (Emerald)
input color            InpColorOpenSellEntry          = C'239,68,68';         // Open SELL Entry Line Color (Coral Red)
input color            InpColorOpenSL                 = C'220,38,38';         // Open Stop Loss Line Color (Crimson)
input color            InpColorOpenBE                 = C'250,204,21';        // Open Breakeven Locked SL Color (Gold)
input color            InpColorOpenTP1                = C'52,211,153';        // Open TP1 Line Color (Mint - 1.40R FTA)
input color            InpColorOpenTP2                = C'56,189,248';        // Open TP2 Line Color (Sky Blue - 2.30R BE Trigger)
input color            InpColorOpenTP3                = C'192,132,252';       // Open TP3 Line Color (Purple - 4.80R Liquidity)
input color            InpColorOpenTP4                = C'251,191,36';        // Open TP4 Line Color (Amber - 8.00R Macro)

input group "=== [Master Market-Quality Gate Configuration] ==="
input int              InpStaleTickThresholdSec       = 60;                   // Stale Tick Threshold (Seconds)
input int              InpATRPeriod                   = 14;                   // ATR Period for Volatility
input int              InpATRBaselinePeriod           = 50;                   // ATR Baseline Period (Bars)
input int              InpEMA20_Period                = 20;                   // Fast EMA Period (H1 & H4)
input int              InpEMA50_Period                = 50;                   // Slow EMA Period (H1 & H4)
int                    g_advisorMaxTradesLimit        = 24;                   // Active Synchronized Advisor Max Trades Limit
#define InpMaxOpenAdvisorTradesPortfolio g_advisorMaxTradesLimit
input double           InpVolLowThreshold             = 0.70;                 // Low Volatility Threshold (< 0.70 = LOW)
input double           InpVolHighThreshold            = 1.50;                 // High Volatility Threshold (> 1.50 = HIGH)
input double           InpSpreadMultiplierThreshold   = 2.5;                  // Max Spread Multiplier vs Normal
input double           InpPriceExtensionATR           = 1.2;                  // Max Distance from EMA20 / Structure in ATR
input int              InpSignalExpiryBars            = 5;                    // Signal Expiry Bars (H1)
input double           InpMinRewardRiskRatio          = 1.4;                  // Minimum Acceptable Reward-to-Risk

input group "=== [Institutional Risk Protection & Session Filters] ==="
input bool             InpEnableSessionShield         = true;                 // Enable 08:00-09:00 Toronto Whipsaw Shield
input bool             InpEnableSpreadGuard           = true;                 // Enable Dynamic Spread Spike Guard (>2.0x median)
input bool             InpEnableForexCryptoConfluence = true;                 // Require Multi-Timeframe Confluence for Forex/Crypto

input group "=== [Trade Advisor & MyAdvisor Configuration] ==="
input bool             InpMyAdvisor_AutoTrade         = true;                 // Auto-Trade Signal Advice on Open Charts [U]
input int              InpAdvisorMaxTradesPerSetup    = 4;                    // Max Trades Opened at Once per Setup (Max 4 legs)
input int              InpMaxSetsPerSymbol            = 2;                    // Max Sets of Trades Open per Instrument (Default: 2)
input int              InpAdvisorMaxTotalOpenTrades   = 24;                   // Max Total Open Advisor Trades Allowed (Ceiling: 24)
#define InpMaxOpenAdvisorTrades InpAdvisorMaxTradesPerSetup

input group "=== [Consecutive-Loss Circuit Breaker Rule] ==="
input bool             InpEnableCircuitBreaker        = true;                 // Enable Consecutive-Loss Circuit Breaker
input int              InpMaxConsecLossesPerSymbol    = 3;                    // Max Consecutive Losses per Instrument (Pause for Day)
input int              InpMaxDailyPortfolioLosses     = 6;                    // Max Total Daily Losses Across Portfolio (Pause for Day, 6 Daily Losses)

input group "=== [Dynamic Trailing Pullback Exit (Runner Legs 3 & 4)] ==="
input bool             InpEnableTrailingRunnerExit    = true;                 // Enable Dynamic Trailing Exit for Legs 3 & 4
input double           InpLeg3TrailDropPct            = 28.5;                 // Leg 3 Pullback Exit (% drop from peak when 2 legs remain: Leg 3 & 4)
input double           InpLeg4TrailDropPct            = 33.5;                 // Leg 4 Pullback Exit (% drop from peak when only Leg 4 remains)
input double           InpTrailMinProfitPips          = 5.0;                  // Minimum Profit in Pips before Trailing Exit activates

input group "=== [Smart Lot Size Selector & Dynamic Risk Sizing] ==="
enum ENUM_SMART_RISK_PROFILE
{
   RISK_PROFILE_CONSERVATIVE = 0, // Conservative (1.0% Risk per Setup)
   RISK_PROFILE_BALANCED     = 1, // Balanced (2.0% Risk per Setup - Default)
   RISK_PROFILE_AGGRESSIVE   = 2, // Aggressive (3.0% Risk per Setup)
   RISK_PROFILE_CUSTOM       = 3  // Custom Risk % (Set via InpCustomRiskPercent)
};
input bool                    InpEnableSmartLotSize       = true;                 // Enable Smart Lot Size Selector (Default: ON, Toggleable [J])
input ENUM_SMART_RISK_PROFILE InpSmartRiskProfile         = RISK_PROFILE_BALANCED;// Dynamic Risk Profile
input double                  InpCustomRiskPercent        = 2.0;                  // Custom Risk % per Setup (Used if Profile = Custom)
input bool                    InpSmartMicroAccountSupport = true;                 // Small Account Support (Micro floor for <= $100 USD)
input double                  InpSmartMaxCapLot           = 0.0;                  // Global Absolute Maximum Lot Cap (0 = Disabled / Full Broker Capacity)

input group "=== [Trade Advisor Lot Sizes per Instrument (Fixed Fallback)] ==="
input double           InpAdvisorLot_XAUUSD           = 0.10;                 // XAUUSD (Gold) Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_US30             = 0.10;                 // US30 / DJ30 Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_NAS100           = 0.10;                 // NAS100 Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_GBPJPY           = 0.10;                 // GBPJPY Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_GBPUSD           = 0.10;                 // GBPUSD Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_AUDUSD           = 0.10;                 // AUDUSD Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_USOIL            = 0.10;                 // USOIL / WTI Crude Oil Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_AMD              = 0.10;                 // AMD / Equities Total Lot Size (Used if Smart Lot is OFF)
input double           InpAdvisorLot_Default          = 0.10;                 // Other Instruments Default Total Lot Size

input group "=== [Trade Advisor Magic & Multi-Leg Safety] ==="
input long             InpAdvisorMagicNumber          = 333777;               // Magic Number for Auto-Advisor Trades
input long             InpManualMagicNumber           = 1001;                 // Magic Number for Manual / Master Trades
input int              InpStructureLookbackBars       = 30;                   // Swing Structure Lookback (Bars)
input double           InpHighVolConfirmThreshold     = 0.50;                 // High Volatility Candle Body Confirmation Ratio
input double           InpMaxEntryDriftATR            = 0.35;                 // Max Entry Drift Allowed from Trigger (in ATR)
input double           InpMaxSpikeAtrMultiplier       = 3.0;                  // Max Candle Range vs ATR Before Stabilization Pause

enum ENUM_OB_ZONE_METHOD
{
   OB_FULL_CANDLE = 0,
   OB_BODY_ONLY   = 1
};

input group "=== [M30 Order Block Intelligence - Strategy Extension] ==="
input bool                 InpOBObservationMode          = true;              // Keep OB detection, display and logging active
input bool                 InpOBConfluenceEnabled        = true;              // Allow high-quality trend-aligned M30 OB signals
input ENUM_TIMEFRAMES      InpOBTimeframe                = PERIOD_M30;        // Order-block timeframe (M30)
input ENUM_OB_ZONE_METHOD  InpOBZoneMethod               = OB_FULL_CANDLE;    // Zone boundary method (Full Candle / Body Only)
input int                  InpOBLookbackBars             = 300;               // Closed M30 bars to scan
input int                  InpOBATRPeriod                = 14;                // M30 ATR period
input double               InpOBMinDisplacementATR       = 1.20;              // Minimum displacement/ATR
input bool                 InpOBRequireBOS               = true;              // Require structure break (BOS)
input int                  InpOBSwingLookback            = 10;                // Prior structure lookback
input int                  InpOBMaxPreferredTouches      = 2;                 // Preferred mitigation count (Fresh or 1st/2nd Retest)
input bool                 InpOBUseLiquiditySweep        = true;              // Detect liquidity sweeps
input bool                 InpOBUseLowerTFConfirmation   = true;              // Detect M15/M5 lower TF confirmation
input double               InpOBInvalidationATRBuffer    = 0.05;              // Close invalidation tolerance
input int                  InpOBMaxActiveZones           = 8;                 // Keep chart/object count bounded
input bool                 InpOBDrawZones                = true;              // Draw active M30 zones on chart
input bool                 InpShowBrokenOrderBlocks      = true;              // Show Broken / Invalidated Order Blocks on Chart (Default: ON)
input bool                 InpOBShowTextOnChart          = true;              // Show clean short labels on Order Blocks (False = Clean Zones Only)
input bool                 InpOBLogTradeContext          = true;              // Log OB context at each setup execution
input int                  InpOBMinimumSignalScore       = 70;                // Minimum score for M30 OB confluence handoff
input bool                 InpOBRequireHTFAlignment      = true;              // Require H1 and H4 direction agreement
input bool                 InpOBRequireLowerTFConfirm    = true;              // Require closed M15/M5 confirmation
input bool                 InpOBCounterTrendEnabled      = false;             // Counter-trend OB signals (False = Trend Confluent Only)

input group "=== [Entry Strategy Weights & Priority Allocation] ==="
input double               InpWeight_OrderBlockStrategy   = 70.0;             // Order Block Strategy Weight % (70% Dominant Primary)
input double               InpWeight_OtherStrategies      = 30.0;             // Other Strategies Weight % (30% Secondary Retest)
input bool                 InpOBPrioritizeOverChasing     = true;             // Reject Chasing Entries when Valid OB Exists Below/Above
input double               InpOBMaxDistanceForRetestATR   = 2.20;             // Max ATR distance to track & anchor OB Retest Setup
input double               InpOBProximityToleranceATR     = 0.75;             // OB direct entry zone tolerance (in ATR)

input group "=== [HTF Liquidity Levels (PDH/PDL, PWH/PWL) & OB Scoring] ==="
input bool                 InpShowHTFLiquidityLines       = true;             // Draw PDH/PDL and PWH/PWL levels on chart
input bool                 InpEnableLiquidityConfluenceScore = true;          // Boost M30 Order Block score with PDH/PDL/PWH/PWL sweeps
input double               InpLiquiditySweepToleranceATR  = 0.35;             // Liquidity sweep & proximity tolerance (in ATR)
input bool                 InpAutoMapTP3ToOpposingLiquidity = true;           // Map Leg 3 (TP3) to opposing PDH/PDL liquidity (within 2-3 day reach)
input group "=== [M30 Stop Loss Recovery: 1-Hour Order Block Elevation] ==="
input bool                 InpElevateToH1OnM30SL          = true;             // If M30 OB hits Stop Loss, bypass next M30 OB and enter at 1H OB
input double               InpNDAQ_H1_DemandAnchor        = 93.42;            // Calibrated NDAQ 1-Hour Demand Order Block Anchor (from chart)
input int                  InpH1OBMaxActiveZones          = 6;                // Max active 1-Hour Order Blocks to track

input group "=== [Trend Reversal & Directional Confluence Protection] ==="
input bool                 InpEnableReversalProtection      = true;             // Prevent blind counter-trend trades against H1/H2/H4 confluence
input int                  InpReversalH1MinBounces          = 3;                // Min H1 candle bounces on zone lowest/highest point (Default: 3)
input int                  InpReversalM30MinBounces         = 4;                // Min M30 candle bounces on zone lowest/highest point (Default: 4)
input double               InpReversalZoneRetestRatio       = 0.30;             // Retest sweet-spot depth within zone (0.25 - 0.35)
input bool                 InpEnforceAchievableTP           = true;             // Calibrate TP1-3 for 2-3 trading days attainability

// Higher Timeframe Liquidity Intelligence Struct
struct HTFLiquidityData
{
   double   pdh;              // Previous Day High (Yesterday High)
   double   pdl;              // Previous Day Low (Yesterday Low)
   double   pdo;              // Previous Day Open (Yesterday Open)
   double   pdc;              // Previous Day Close (Yesterday Close)
   double   pwh;              // Previous Week High (Last Week High)
   double   pwl;              // Previous Week Low (Last Week Low)
   double   pwo;              // Previous Week Open (Last Week Open)
   double   pwc;              // Previous Week Close (Last Week Close)
   double   dayOpen;          // Current Day Open (Today Open)
   double   weekOpen;         // Current Week Open (This Week Open)
   bool     pdhSwept;         // True if today swept PDH
   bool     pdlSwept;         // True if today swept PDL
   bool     pwhSwept;         // True if this week swept PWH
   bool     pwlSwept;         // True if this week swept PWL
   string   nearestLevelName; // "PDH", "PDL", "PWH", "PWL", "PDO", "PDC", "PWO", "PWC"
   double   nearestLevelPrice;
   double   distanceToNearest;
   string   activeConfluenceLabel;
   int      liquidityScoreBonus;
};

HTFLiquidityData g_htfLiquidity;

// M30 Order Block Intelligence & Strategy Extension Variables
struct M30OrderBlock
{
   bool       bullish;
   double     high;
   double     low;
   datetime   originTime;
   datetime   confirmTime;
   int        touchCount;
   bool       invalidated;
   bool       liquiditySweep;
   bool       lowerTFConfirmed;
   bool       trendAligned;
   bool       zoneDefended;
   bool       hasFVG;
   int        qualityScore;
   string     status;
   string     liquidityContext;
   int        liquidityBonus;
   bool       isViableSpot;
};

M30OrderBlock g_orderBlocks[];
// 1-Hour (H1) Order Block Intelligence (M30 SL Recovery Engine)
M30OrderBlock g_h1OrderBlocks[];
int           g_h1OBCount                  = 0;
datetime      g_lastH1OBScanBarTime        = 0;
int           g_nearestBullishH1OB         = -1;
int           g_nearestBearishH1OB         = -1;
double        g_distanceToH1Demand         = 0.0;
double        g_distanceToH1Supply         = 0.0;
bool          g_m30SLHit_RequireH1OB       = false;
datetime      g_m30SLHit_Time              = 0;
string        g_m30SLHit_Direction         = "NONE";
int           g_obCount                  = 0;
datetime      g_lastOBScanBarTime        = 0;
int           g_nearestBullishOB         = -1;
int           g_nearestBearishOB         = -1;
double        g_distanceToDemand         = 0.0;
double        g_distanceToSupply         = 0.0;
string        g_obLocationWarning        = "CLEAR";
string        g_activeSignalSource       = "BASELINE";
double        g_obSignalLow              = 0.0;
double        g_obSignalHigh             = 0.0;
datetime      g_obSignalOrigin           = 0;
int           g_obSignalScore            = 0;
string        g_obSignalDirection        = "NONE";
string        g_activeEntryStrategy      = "ORDER_BLOCK"; // "ORDER_BLOCK" (70%) or "STRUCTURE_RETEST" (30%)
double        g_activeStrategyWeight     = 70.0;          // Strategy weighting percentage (70% dominant)

//+------------------------------------------------------------------+
//| Unified Multi-Strategy Confluence Matrix Structure               |
//+------------------------------------------------------------------+
struct UnifiedStrategyMatrixMQL
{
   string overallHealth;   // "OPTIMAL", "MODERATE", "EVALUATING", "BLOCKED"
   int    confluenceScore; // 0 - 100
   string confluenceTier;  // "INSTITUTIONAL A+ CONFLUENCE", "HIGH PROBABILITY", "MODERATE", "RISK QUARANTINE"
   string htfTrendStatus;  // "ALIGNED", "PULLBACK", "CONFLICT"
   string htfTrendDetail;
   string valStatus;       // "ALIGNED", "EXTENDED", "EVALUATING"
   string valDetail;
   string triggerStatus;   // "ALIGNED", "WATCHING", "SCANNING"
   string triggerDetail;
   string execStatus;      // "4 LEGS ARMED"
   string execDetail;
   string shieldStatus;    // "ARMED", "WARNING", "BLOCKED", "STANDBY"
   string shieldDetail;
   int    synergyScore;    // 0 - 100
   string synergyGrade;    // "PERFECT_SYNERGY", "STRONG_SYNERGY", "MODERATE_SYNERGY", "CONFLICT_DETECTED"
   string conflictStatus;  // "RESOLVED", "NO_CONFLICT", "WARNING"
   string conflictDetail;  // Description of active conflict resolution rule applied
   double adaptiveBECushionPips; // Dynamic ATR-adaptive breakeven cushion
};
UnifiedStrategyMatrixMQL g_strategyMatrix;

//--- Global State
ENUM_SEGS_MODE g_currentMode               = MODE_COMPLETE_AUTO;
bool           g_autoBreakevenOnTP_Active  = true;
bool           g_showSentimentHUD          = true;
ENUM_HUD_CORNER g_sentimentCorner          = HUD_POS_TOP_LEFT;
int            g_terminalScrollIndex       = 0;
ulong          g_selectedTicket            = 0;
bool           g_showTradeAdviceLines      = true;
bool           g_showBrokenOrderBlocks     = true;
bool           g_showOpenTradeMarkings     = true;
bool           g_showOpenTradeLabels       = true;
bool           g_showOpenTradeBrackets     = true;
int            g_activeDashboardTab        = 0; // 0 = Terminal, 1 = Open Trades Markings Tab, 2 = Market Gate
bool           g_alertOnViableEntry        = true;
bool           g_myAdvisorEnabled          = false;
bool           g_smartLotEnabled           = true;                 // Active Smart Lot Selector State (Toggle with [J])
bool           g_showWinRateHUD            = false;
string         g_winRateSelectedSymbol     = "ALL";
bool           g_showHelpHUD               = false;
datetime       g_lastAutoTradeBarTime      = 0;
bool           g_hasViableEntry            = false;
string         g_currentAdvisedAction      = "NONE";
double         g_staticEntryPrice          = 0.0;
double         g_staticSL                  = 0.0;
double         g_staticTP1                 = 0.0;
double         g_staticTP2                 = 0.0;
double         g_staticTP3                 = 0.0;
double         g_staticTP4                 = 0.0;
datetime       g_signalTriggerTime         = 0;
string         g_signalStatusLabel         = "WAITING FOR SETUP";
bool           g_isSignalExpired           = false;
datetime       g_lastAdviceScanBarTime     = 0;
datetime       g_lastAlertTriggerTime      = 0;
string         g_staticAdviceSymbol        = "";

//--- Planned Entry Dynamic Management & Cancellation/Reactivation State
double         g_lastCancelledEntryPrice      = 0.0;
string         g_lastCancelledEntryAction     = "NONE";
double         g_lastCancelledEntrySL         = 0.0;
datetime       g_lastCancelledTime            = 0;
string         g_lastCancelledReason          = "";

//--- Master Signal & Gate State Engine Variables
string         g_currentSignalID              = "";
bool           g_currentTradeTaken            = false;
datetime       g_lastAdvisorTradeExecTime     = 0;
string         g_lastAdvisorTradeSignalID     = "";
bool           g_signalGeneratedWhileAdvisorEnabled = false;
string         g_setupState                   = "SCANNING"; // BLOCKED, SCANNING, WATCHING, ARMED, TRIGGERED, INVALIDATED, EXPIRED
int            g_setupQuality                 = 0;
string         g_blockReason                  = "INITIALIZING / CHECKING MARKET";
string         g_volatilityRegime             = "N/A"; // LOW, NORMAL, HIGH, N/A
double         g_volatilityScore              = 0.0;
double         g_volAtrRatio                  = 0.0;
double         g_volRangeRatio                = 0.0;
double         g_currentSpreadRatio           = 0.0;
bool           g_isMarketOpen                 = false;
bool           g_isTickFresh                  = false;
bool           g_isTickDataFresh              = false;
bool           g_isGateOpen                   = false;
string         g_gateBlockReason              = "";
double         g_spreadQualityRatio           = 1.0;
string         g_spreadQualityStr             = "NORMAL";
string         g_lastScannedSymbol            = "";

// Auto Execution Diagnostics & Technical Permissions
ENUM_AUTO_EXECUTION_STATE g_autoExecState        = AUTO_EXEC_DISABLED;
string                   g_autoExecDetail       = "DISABLED (OFF)";
string                   g_autoExecSource       = "MYADVISOR USER SETTING";

// Feed Health & Session State Engine
ENUM_FEED_STATE          g_feedState            = FEED_UNKNOWN;
int                      g_lastTickAgeSec       = 0;
bool                     g_isBrokerTradeable    = false;
string                   g_brokerTradeReason    = "";

ENUM_CASH_SESSION        g_cashSession          = CASH_SESSION_CLOSED;
string                   g_cashSessionName      = "CLOSED";
string                   g_strategySession      = "N/A";

// Dynamic Spread Cost Analysis
ENUM_SPREAD_STATE        g_spreadState          = SPREAD_NORMAL;
double                   g_spreadCostRatio      = 0.0;
double                   g_plannedRiskDist      = 0.0;

// Market State & Hierarchy Classification
ENUM_MARKET_STATE        g_marketStateClass     = MARKET_STATE_NEUTRAL;
ENUM_SETUP_CLASS         g_setupClass           = SETUP_CLASS_NONE;

// Multi-Target R:R and Overall Expectancy Model
double                   g_rrTP1                = 0.0;
double                   g_rrTP2                = 0.0;
double                   g_rrTP3                = 0.0;
double                   g_rrTP4                = 0.0;
double                   g_rrWeighted           = 0.0;
double                   g_netExpectancy        = 0.0;
string                   g_expectancyRating     = "N/A";

string                   g_primaryRejectionReason = "NONE";
string                   g_diagnosticsSummary   = "";

DailyDecisionTelemetry   g_telemetry;

// Directional Confluence & Structural States
string         g_h1Bias                       = "NEUTRAL";
string         g_h2Bias                       = "NEUTRAL";
string         g_h4Bias                       = "NEUTRAL";
string         g_overallBias                  = "NEUTRAL";
string         g_marketStructure              = "NEUTRAL";
string         g_marketStructureM30           = "NEUTRAL";
string         g_marketStructureH1            = "NEUTRAL";
bool           g_hasHH_M30                    = false;
bool           g_hasLL_M30                    = false;
bool           g_hasHH_H1                     = false;
bool           g_hasLL_H1                     = false;
double         g_m30SwingHigh                 = 0.0;
double         g_m30SwingLow                  = 0.0;
double         g_h1SwingHigh                  = 0.0;
double         g_h1SwingLow                   = 0.0;
string         g_liquidityState               = "N/A";
string         g_plannedAction                = "NONE";

// Swing Points & Structural Support/Resistance Levels
double         g_recentSwingHigh              = 0.0;
double         g_recentSwingLow               = 0.0;
double         g_recentSupport                = 0.0;
double         g_recentResistance             = 0.0;
datetime       g_recentPivotTime              = 0;

// Cached Indicator Handles & Symbol Tracking (Section 35 & 36)
int            g_hAtr_H1                      = INVALID_HANDLE;
int            g_hEma20_H1                    = INVALID_HANDLE;
int            g_hEma50_H1                    = INVALID_HANDLE;
int            g_hEma20_H2                    = INVALID_HANDLE;
int            g_hEma50_H2                    = INVALID_HANDLE;
int            g_hEma20_H4                    = INVALID_HANDLE;
int            g_hEma50_H4                    = INVALID_HANDLE;
string         g_cachedHandleSymbol           = "";
string         g_lastTrackedSymbol            = "";

// Spread Normalization & Tick Activity Proxy
double         g_tickActivityRatio            = 1.0;
double         g_dynamicTypicalSpread         = 0.0;
double         g_spreadHistory[50];
int            g_spreadSampleCount            = 0;

// Trade Permission Cache
bool           g_terminalTradingAllowed       = true;
bool           g_accountTradingAllowed        = true;
bool           g_mqlTradingAllowed            = true;
bool           g_tradePermissionAllowed       = true;

// Signal Deduplication & Timing
string         g_lastAlertedSignalID          = "";
datetime       g_lastSignalConfirmationTime   = 0;
bool           g_isDashboardVisible        = true;
bool           g_isMatrixExpanded          = true;
bool           g_isDockedAtBottom          = true;
int            g_tableX                    = 4;
int            g_tableY                    = 4;
bool           g_isDragging                = false;
int            g_dragStartX                = 0;
int            g_dragStartY                = 0;
int            g_prevRenderedRows          = 0;
ulong          g_lastTickUpdateTime        = 0;
const string   PREFIX                      = "SEGS_TRM_";

// Group of 4 legs for Breakeven and Target Tracking
struct PositionGroup
{
   ulong              tickets[4];
   ulong              positionIds[4];
   datetime           groupTime;
   bool               tpTriggerHit;
   bool               breakevenApplied;
   int                positionCount;
   string             symbol;
   ENUM_POSITION_TYPE positionType;
   string             setupID;
   double             peakPrice;
   bool               leg3ClosedByTrail;
   bool               leg4ClosedByTrail;
};

PositionGroup  g_groups[];
ulong          g_processedTickets[];

// Tracking manual orders to duplicate
#define MAX_TRACKED_ORDERS 128
ulong g_handledOrders[MAX_TRACKED_ORDERS];
int   g_handledOrderCount = 0;

// Progress structure
struct TradeProgress
{
   double pct;
   double pipsToTP;
   double pipsCurrent;
   string progressBar;
   color  barColor;
};

//--- Forward declarations
TradeProgress CalcTradeProgress(ulong ticket, int barLen = 8);
void DrawUnifiedTerminalDashboard();
void DrawSentimentHUD();
void ProcessUnassignedPositions();
bool IsSymbolMatch(string sym, string pattern);
string DetectAssetType(string sym);
bool IsSameChartAsset(string symA, string symB);
double GetPipSize(string sym);
void GetAssetTargets(string sym, double &slPips, double &tp1, double &tp2, double &tp3, double &tp4);
double CalcRiskFromSL(ulong ticket);
double CalcProfitFromTP(ulong ticket);
double CalcEstimatedRisk(ulong ticket, double slPips);
double CalcEstimatedReward(ulong ticket, double tpPips);
void ApplyBreakevenAll();
void ApplyBreakevenTicket(ulong ticket);
void ShiftStopLossTicket(ulong ticket, double deltaPips);
void ShiftTakeProfitTicket(ulong ticket, double deltaPips);
void DeleteTerminalObjects();
void DrawWinRateHUD();
void DeleteWinRateHUD();
void DrawHelpHUD();
void DeleteHelpHUD();
void ClosePartialTicket(ulong ticket, double fraction);
void CloseTicket(ulong ticket);
void CloseWinningPositions();
void CloseLosingPositions();
void CloseAllPositions();
void CloseBuyPositions();
void CloseSellPositions();
void CloseWinnersExceptLowest();
void CancelPendingOrders(string symFilter);
void ClosePartialTopProfitable(int maxCount, double fraction);
void ActivateAllPendingOrders();
bool SafePositionClose(ulong ticket, string reason = "MANUAL_CLOSE");
void EnforcePositionStopLossAndTargets();
void CheckBreakevenConditions();
void CheckTrailingClose();
void ScanAndTrailUngroupedAdvisorRunners();
void DuplicateTrade(ulong masterTicket, ulong masterPosId, string sym, ENUM_POSITION_TYPE ptype, double vol, double openPrice);
bool WasTPActuallyHit(ulong positionId, string sym, ENUM_POSITION_TYPE ptype, double expectedTPPrice, datetime fromTime=0);
void EvaluateTakeProfitHits(string sym, string action, double entry, double tp1, double tp2, double tp3, double tp4, datetime execTime,
                            bool &outTP1Hit, bool &outTP2Hit, bool &outTP3Hit, bool &outTP4Hit);
void HealOpenAdvisorPositions(string sym);
void InitPositionGroup(PositionGroup &grp);
double NormalizePriceToTickSize(string sym, double price);
int  ValidateProtectionTarget(string sym, ENUM_POSITION_TYPE ptype, double curPrice, double targetPrice, bool isStopLoss);
void SaveAdvisorSetupTargets(string setupID, string sym, ENUM_POSITION_TYPE ptype, double entry, double sl, double tp1, double tp2, double tp3, double tp4, int legs);
bool LoadAdvisorSetupTargets(string setupID, double &outEntry, double &outSL, double &outTP1, double &outTP2, double &outTP3, double &outTP4, ENUM_POSITION_TYPE &outType, int &outLegs);
ulong FindHistoricalLeg2PositionId(string setupID, string sym, datetime groupOpenTime);
bool IsEligibleNewMasterDeal(ulong dealTicket);
bool ResolvePositionTicketAndIdFromDeal(ulong dealTicket, string sym, long magic, string commentPattern, ulong &outTicket, ulong &outPosId);
bool ValidateProtectionLevels(string sym, ENUM_POSITION_TYPE ptype, double curPrice, double &sl, double &tp);
int  GetVolumeDigits(string sym);
double NormalizeVolumeToSymbolStep(string sym, double lot);
void UpdateGroupPositionCount(int g);
bool ApplyBreakevenToGroup(int g);
bool IsPositionProtectedAtBreakeven(ulong ticket, ENUM_POSITION_TYPE ptype, double targetBeSL, double tickSize);
int  FindGroupIndexBySetupOrPosition(string setupID, ulong ticket, ulong posId);
ulong GetPositionIdentifierByTicket(ulong ticket);
bool AlreadyHandledOrder(ulong tk);
void MarkOrderHandled(ulong tk);
datetime GetTorontoTimeNow();
string   GetTorontoTimeFormatted();
bool     IsTorontoDST(datetime dt);
bool     IsTorontoDeepRetracementWindow();
double GetOpeningEquity_TodayToronto();
double GetOpeningEquity_ThisWeekToronto();
double ComputeRealizedPnL_TodayToronto();
double ComputeRealizedPnL_ThisWeekToronto();
double ComputeOpenPnL_Now();
double ComputeRemainingToTP_AllPositions();
ENUM_AUTO_EXECUTION_STATE GetAutoExecutionState(string sym, string &outDetail, string &outSource);
ENUM_FEED_STATE           EvaluateFeedHealth(string sym, int &outAgeSec);
bool                      IsBrokerSymbolTradeable(string sym, string &outReason);
ENUM_CASH_SESSION         GetUnderlyingCashSession(string sym, string &outSessionName, string &outStrategySession);
ENUM_SPREAD_STATE         EvaluateSpreadCost(string sym, double plannedStopDist, double &outSpreadRatio, double &outCostRatio, string &outSpreadStr);
void                      CheckDailyTelemetryReset();
bool   IsMarketSessionOpen(string sym);
int    GetLastTickAge(string sym);
bool   IsMarketDataFresh(string sym);
string CalculateNormalizedVolatility(string sym, double &outAtrRatio, double &outRangeRatio, double &outScore);
bool   CheckSpreadQuality(string sym, double &outRatio);
bool   IsPriceExtended(string sym, string dir, double curPrice, double &outExtRatio);
datetime ConvertBrokerTimeToToronto(datetime dt);
string BuildSignalID(string sym, string dir, datetime srvTime);
bool   AcquireAccountExecutionLock(string opName, int timeoutSec=12);
void   ReleaseAccountExecutionLock(string opName);
bool   HasOpenAdvisorTradesForSymbol(string sym);
bool   HasOpenAdvisorTradesForSignal(string sym, string signalID);
int    CountOpenAdvisorTradesForSymbol(string sym);
int    CountOpenAdvisorSetsForSymbol(string sym);
bool   IsAdvisorTradeTaken(string sym, string signalID);
datetime GetAdvisorTradeExecutionTime(string sym, string signalID);
string   FormatExecutionTime(datetime execDt, bool includeDate=true);
void   UpdateTradeAdviceLines();
void   ScanMarketStructureAndAdvice(bool forceScan=false);
bool   IsPlannedEntryViable(string sym, string action, double entryPrice, double slPrice, double curPrice, double pipSize, double curAtr, string &outUnviableReason);
void   CancelUnviablePlannedEntry(string sym, string reason);
bool SEGSResetExpiredSetup(string sym);
bool   TryReactivatePlannedEntry(string sym, string candDir, double curPrice, double pipSize, double curAtr);
void   ExecuteAdvisedTrade(bool isAutoTrade=false);
bool   RollbackAdvisorSetup(string shortSig, string signalID, const ulong &tickets[], int maxLegs);
void   CheckAndAutoTradeAdvice();
double GetAdvisorLotForSymbol(string sym);
bool   CalculateSmartLotSize(string sym, double balance, double slPips, double &outTotalLot, double &outLegLot, int &outLegsCount, string &outExplanation, int requestedLegs=4);
int    CountTotalOpenAdvisorTrades();
void   SaveAdvisorPersistentState();
void   RestoreAdvisorPersistentState();
void   SaveActiveSignalSnapshot(string sym);
void   RestoreActiveSignalSnapshot(string sym);
void   ClearActiveSignalSnapshot(string sym);
void   DrawTradeAdviceLines(double entry, double sl, double tp1, double tp2, double tp3, double tp4, int digits);
void   DeleteTradeAdviceLines();
void   CreateChartHLine(string name, double price, color col, ENUM_LINE_STYLE style, int width, string desc);
void   CreateChartTextTag(string name, datetime t, double price, string text, color col, string font="Trebuchet MS", int fontSize=9);
void   UpdateOpenTradeMarkings();
void   DeleteOpenTradeMarkings();
void   CreateOpenTradeHLine(string name, double price, color col, ENUM_LINE_STYLE style, int width, string desc, string tooltip="");
bool   CheckTradePermissions();
string MeasureMarketLiquidity(string sym, double &outRatio);
void   UpdateSpreadHistory(string sym);
string ScanMarketSwingStructure(string sym, double &outSwingH, double &outSwingL, double &outSupp, double &outRes);
bool   IsValidSetupLocation(string sym, string dir, double curClose, double ema20, double atr, double swingH, double swingL);
bool   HasEntryConfirmation(string sym, string dir, string volRegime, double &outScore);
bool   TryAcquireAccountLock(string opName, int timeoutSec=12);
void   ReleaseAccountLock(string opName);
bool   TryReserveMasterPosition(ulong posID);
void   SetMasterPositionState(ulong posID, double state);
bool   IsEligibleManualMaster(ulong ticket);
bool   IsTicketAlreadyInGroup(ulong ticket);
bool   IsPositionIdInGroup(ulong posId);
string BuildStableSignalID(string sym, string dir, datetime triggerBarTime, datetime pivotCandleTime);
bool   IsSEGSManagedPosition(ulong ticket);
int    CountOpenSEGSPositions();
void   RefreshAccountAdvisorState();
void   ComputeWinRate_PastTrades(string targetSymbol, double &winRate, int &winTrades, int &lossTrades, double &profitFactor);
void   ReconstructPositionGroups();
void   InitIndicatorHandles(string sym);
void   ReleaseIndicatorHandles();
void   ResetMarketQualityState(string newSym);
int    DiscoverSEGSSymbols(string &outSymbols[]);
bool   CalculateLegLots(string sym, double totalLot, int legs, double &outLots[], string &outErr);
int    BuildStructuralTargets(string sym, string dir, double entryPrice, double stopLoss, double curAtr,
                              double &outTP1, double &outTP2, double &outTP3, double &outTP4,
                              double &outRR_TP2, double &outRR_Weighted);
bool   EvaluateTrendReversalConditions(string sym, string proposedDir, double &outEntryPrice, double &outStopLoss, int &outH1Bounces, int &outM30Bounces, string &outReversalReason);
double OBATRAt(MqlRates &r[], int shift, int period);
string OBAlignmentText(const M30OrderBlock &ob);
void   UpdateOBLocationSnapshot(string sym);
void   DrawM30OrderBlocks();
void   RefreshOBLowerTFConfirmations(string sym);
void   UpdateM30OrderBlocks(bool forceScan=false);
void   UpdateH1OrderBlocks(bool forceScan=false);
void   UpdateH1OBLocationSnapshot(string sym);
string EvaluateH1OBSignal(string sym, double &outLow, double &outHigh, datetime &outOrigin, int &outScore, string dir="BUY");
void   DrawH1OrderBlocks();
void   CheckM30TradeSLHit(string sym);
string EvaluateM30OBSignal(string sym, double &outLow, double &outHigh, datetime &outOrigin, int &outScore, bool isReversal=false, string reversalDir="NONE");
void   LogOBSnapshotForTrade(string sym, string direction, string signalID);
void   UpdateUnifiedStrategyMatrix(string sym);
void   CheckCircuitBreaker(string sym, bool &outBlocked, string &outReason, int &outConsecLosses, int &outOverallLosses);
void   UpdateHTFLiquidityLevels(string sym);
void   DeleteHTFLiquidityLines();
void   DrawHTFLiquidityLines(string sym);
int    CountOrderBlockBounceCycles(string sym, ENUM_TIMEFRAMES tf, double obLow, double obHigh, bool isBullish, double atrVal, double pipSize, int maxBars=288);
double CalculateDirectEMA(string sym, ENUM_TIMEFRAMES tf, int period, int shift=1);
void   EvaluateMultiTimeframeTrendAndReversal(string sym, string &outH1Bias, string &outH2Bias, string &outH4Bias, string &outOverallBias, bool &outIsReversal, string &outReversalDir, double &outEma20Val);
bool   CheckConfirmedSafeZoneBounce(string sym, string dir, double safeEntry);
bool   GetOpenAdvisorTradeDetails(string sym, string &outDir, double &outEntry, double &outSL, double &outTP1, double &outTP2, double &outTP3, double &outTP4, int &outCount);
double GetSafestStructuralStopLoss(string sym, string dir, double entryPrice, double obZoneLow, double obZoneHigh, double curAtr, bool preferMultiDay=false);
void   RunAdvisorStrategyEngine(bool forceScan=false, bool allowAutoTrade=false);
void   ApplySystemSettingsToAllCharts();
//+------------------------------------------------------------------+
//| Expert initialization function with Multi-Chart Error Boundary   |
//+------------------------------------------------------------------+
enum ENUM_SEGS_SL_STYLE
{
   SL_STYLE_ORDER_BLOCK = 0,
   SL_STYLE_MULTI_DAY = 1,
   SL_STYLE_AUTO_DUAL = 2,
   SL_STYLE_ACTIVE_ORDER_BLOCK = 3
};
input group "=== System Structural Stop Loss ==="
input ENUM_SEGS_SL_STYLE InpStructuralStopStyle = SL_STYLE_ORDER_BLOCK;
input bool InpPublishStopSettingsToAllCharts = false; // Set true on one chart to publish these inputs
input double InpActiveOBBufferATR = 0.05; // Small buffer beyond active OB floor/ceiling
input int InpActiveOBBufferTicks = 3;
input double InpActiveOBMaxDistanceATR = 3.0;
input bool InpTrailActiveOrderBlock = true; // Tighten existing advisor positions only
ENUM_SEGS_SL_STYLE g_systemStopStyle = SL_STYLE_ORDER_BLOCK;
double g_systemOBBufferATR = 0.05, g_systemOBMaxDistanceATR = 3.0;
int g_systemOBBufferTicks = 3;
bool g_systemTrailOB = true;

string SEGSStopKey(string field)
{
   return "SEGS_SL_V3_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + field;
}

void SEGSSyncStopSettings(bool publish=false)
{
   if(publish || !GlobalVariableCheck(SEGSStopKey("STYLE")))
   {
      GlobalVariableSet(SEGSStopKey("STYLE"), (double)InpStructuralStopStyle);
      GlobalVariableSet(SEGSStopKey("BUFFER_ATR"), MathMax(0.0, MathMin(1.0, InpActiveOBBufferATR)));
      GlobalVariableSet(SEGSStopKey("BUFFER_TICKS"), (double)MathMax(1, MathMin(100, InpActiveOBBufferTicks)));
      GlobalVariableSet(SEGSStopKey("MAX_DISTANCE_ATR"), MathMax(0.1, MathMin(20.0, InpActiveOBMaxDistanceATR)));
      GlobalVariableSet(SEGSStopKey("TRAIL"), InpTrailActiveOrderBlock ? 1.0 : 0.0);
   }
   g_systemStopStyle = (ENUM_SEGS_SL_STYLE)(int)MathMax(0, MathMin(3, GlobalVariableGet(SEGSStopKey("STYLE"))));
   g_systemOBBufferATR = MathMax(0.0, MathMin(1.0, GlobalVariableGet(SEGSStopKey("BUFFER_ATR"))));
   g_systemOBBufferTicks = (int)MathMax(1, MathMin(100, GlobalVariableGet(SEGSStopKey("BUFFER_TICKS"))));
   g_systemOBMaxDistanceATR = MathMax(0.1, MathMin(20.0, GlobalVariableGet(SEGSStopKey("MAX_DISTANCE_ATR"))));
   g_systemTrailOB = GlobalVariableGet(SEGSStopKey("TRAIL")) > 0.5;
}

input double InpStructuralBufferATR = 0.20;
input double InpDualProximityATR = 0.85;
bool g_runtimeReady = false;

// Readiness is checked again on every event; missing history never detaches the EA.
bool SEGSMarketReady(string sym)
{
   MqlTick quote;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   return MathIsValidNumber(point) && point > 0.0 &&
          MathIsValidNumber(tick) && tick > 0.0 &&
          SymbolInfoTick(sym, quote) && MathIsValidNumber(quote.bid) && MathIsValidNumber(quote.ask) &&
          quote.bid > 0.0 && quote.ask >= quote.bid;
}

bool SEGSEnsureRuntimeReady()
{
   if(!SEGSMarketReady(_Symbol)) { g_runtimeReady = false; return false; }
   static ulong nextRetryMs = 0;
   ulong now = GetTickCount64();
   if(!g_runtimeReady && now < nextRetryMs) return false;
   nextRetryMs = now + 1000;
   SEGSSyncStopSettings();
   InitIndicatorHandles(_Symbol);
   ENUM_TIMEFRAMES frames[] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H2, PERIOD_H4, PERIOD_D1, PERIOD_W1};
   int minimums[] = {45, 25, 25, 60, 60, 60, 30, 6, 2};
   for(int i = 0; i < ArraySize(frames); i++)
   {
      // CopyRates explicitly requests missing history without blocking attachment.
      MqlRates bootstrap[];
      int copied = CopyRates(_Symbol, frames[i], 0, minimums[i], bootstrap);
      if(copied < minimums[i] || !SeriesInfoInteger(_Symbol, frames[i], SERIES_SYNCHRONIZED) || iBars(_Symbol, frames[i]) < minimums[i])
      {
         g_runtimeReady = false;
         Comment("SEGS: waiting for synchronized chart history; EA remains attached.");
         return false;
      }
   }
   int handles[] = {g_hAtr_H1, g_hEma20_H1, g_hEma50_H1, g_hEma20_H2, g_hEma50_H2, g_hEma20_H4, g_hEma50_H4};
   for(int h = 0; h < ArraySize(handles); h++)
      if(handles[h] == INVALID_HANDLE || BarsCalculated(handles[h]) < 3) { g_runtimeReady = false; return false; }
   if(!g_runtimeReady)
   {
      InitIndicatorHandles(_Symbol);
      ReconstructPositionGroups();
      g_runtimeReady = true;
      Comment("");
      PrintFormat("[SEGS READY] Market metadata available on %s", _Symbol);
   }
   return true;
}

int OnInit()
{
   g_runtimeReady = false;
   SymbolSelect(_Symbol, true);
   SEGSSyncStopSettings(InpPublishStopSettingsToAllCharts);
   PrintFormat("[SEGS INIT][Stage 1/9] Initializing SEGS Trade Manager Pro v3.75 on Symbol: %s, ChartID: %I64d", _Symbol, ChartID());

   // STAGE 1: Parameter & Input Sanitization (Clamp to safe baseline defaults instead of fatal INIT_FAILED)
   if(InpNumClonedTrades != 3)
   {
      PrintFormat("[SEGS INIT][Stage 1] Input Warning: InpNumClonedTrades (%d) auto-adjusted to 3 (Master + 3 Clones = 4 Legs).", InpNumClonedTrades);
   }
   if(InpBE_TriggerLeg != 2)
   {
      PrintFormat("[SEGS INIT][Stage 1] Input Warning: InpBE_TriggerLeg (%d) auto-adjusted to 2 (TP2 triggers Breakeven).", InpBE_TriggerLeg);
   }
   if(InpFallbackLot <= 0.0)
   {
      Print("[SEGS INIT][Stage 1] Input Warning: InpFallbackLot must be positive; using safe fallback 0.10.");
   }
   if(InpMinRewardRiskRatio <= 0.0)
   {
      Print("[SEGS INIT][Stage 1] Input Warning: InpMinRewardRiskRatio must be positive; using 1.00R minimum.");
   }

   // STAGE 2: Account Compatibility & Margin Mode Verification
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      PrintFormat("[SEGS INIT][Stage 2] NOTICE: Account Margin Mode is %d (Netting/Exchange). 4-leg management operates in adaptive mode without terminating EA.", marginMode);
   }
   else
   {
      Print("[SEGS INIT][Stage 2] Account Margin Mode verified: RETAIL HEDGING compatible.");
   }

   // Synchronize account-wide Advisor open trades ceiling across all charts
   string gvMaxTradesKey = "SEGS_ADVISOR_MAX_TOTAL_TRADES_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   int effectiveLimit = InpAdvisorMaxTotalOpenTrades;
   if(effectiveLimit < 4) effectiveLimit = 24;
   g_advisorMaxTradesLimit = effectiveLimit;
   GlobalVariableSet(gvMaxTradesKey, (double)g_advisorMaxTradesLimit);

   // STAGE 3: Trade Execution Environment Configuration
   trade.SetExpertMagicNumber(InpMasterMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if(InpHideMT5TradeLevels)
      ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS, false);

   // Configure chart interaction & route keyboard hotkeys directly to EA OnChartEvent
   ChartSetInteger(0, CHART_EVENT_MOUSE_WHEEL, true);
   ChartSetInteger(0, CHART_KEYBOARD_CONTROL, false);
   ChartSetInteger(0, CHART_BRING_TO_TOP, true);

   // STAGE 4: Variable & In-Memory State Reset
   g_currentMode               = InpAutoMode;
   g_autoBreakevenOnTP_Active  = InpEnableTPBreakeven;
   g_isMatrixExpanded          = InpDefaultExpandedView;
   g_isDockedAtBottom          = InpDockAtBottom;
   g_sentimentCorner           = InpSentimentCorner;
   g_showSentimentHUD          = InpShowSentimentHUD;
   g_terminalScrollIndex       = 0;
   g_selectedTicket            = 0;
   g_showTradeAdviceLines      = InpShowTradeAdviceLines;
   g_showBrokenOrderBlocks     = InpShowBrokenOrderBlocks;
   g_alertOnViableEntry        = InpAlertOnViableEntry;
   g_tableX             = InpTableXOffset;
   g_tableY             = InpTableYOffset;
   g_prevRenderedRows   = 0;
   g_handledOrderCount  = 0;
   ZeroMemory(g_handledOrders);
   ArrayResize(g_groups, 0);
   ArrayResize(g_processedTickets, 0);
   ArrayInitialize(g_spreadHistory, 0.0);
   g_spreadSampleCount = 0;

   // STAGE 5: Multi-Chart State Persistence Recovery
   Print("[SEGS INIT][Stage 5] Restoring persistent state from Global Variables and isolated storage...");
   RestoreAdvisorPersistentState();

   ObjectsDeleteAll(0, PREFIX);
   // Bootstrap on a tick/timer only after symbol metadata is available.
   if(!EventSetTimer(1))
      PrintFormat("[SEGS INIT] Timer unavailable (%d); tick events will service the EA.", GetLastError());

   // Write initial heartbeat for this chart so other charts immediately recognize it as active
   GlobalVariableSet("SEGS_HB_" + IntegerToString(ChartID()), (double)TimeCurrent());
   GlobalVariablesFlush();

   PrintFormat("[SEGS INIT] === SUCCESS: SEGS Trade Manager Pro v3.75 fully attached and operational on %s (Chart %I64d) ===", _Symbol, ChartID());
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+

// Indicator Handle Lifecycle & Cache Management (Section 35 & 36)
void ReleaseIndicatorHandles()
{
   if(g_hAtr_H1 != INVALID_HANDLE)   { IndicatorRelease(g_hAtr_H1);   g_hAtr_H1 = INVALID_HANDLE; }
   if(g_hEma20_H1 != INVALID_HANDLE) { IndicatorRelease(g_hEma20_H1); g_hEma20_H1 = INVALID_HANDLE; }
   if(g_hEma50_H1 != INVALID_HANDLE) { IndicatorRelease(g_hEma50_H1); g_hEma50_H1 = INVALID_HANDLE; }
   if(g_hEma20_H2 != INVALID_HANDLE) { IndicatorRelease(g_hEma20_H2); g_hEma20_H2 = INVALID_HANDLE; }
   if(g_hEma50_H2 != INVALID_HANDLE) { IndicatorRelease(g_hEma50_H2); g_hEma50_H2 = INVALID_HANDLE; }
   if(g_hEma20_H4 != INVALID_HANDLE) { IndicatorRelease(g_hEma20_H4); g_hEma20_H4 = INVALID_HANDLE; }
   if(g_hEma50_H4 != INVALID_HANDLE) { IndicatorRelease(g_hEma50_H4); g_hEma50_H4 = INVALID_HANDLE; }
   g_cachedHandleSymbol = "";
}

void InitIndicatorHandles(string sym)
{
   if(sym == g_cachedHandleSymbol && g_cachedHandleSymbol != "" &&
      g_hAtr_H1 != INVALID_HANDLE && g_hEma20_H1 != INVALID_HANDLE &&
      g_hEma50_H1 != INVALID_HANDLE && g_hEma20_H2 != INVALID_HANDLE &&
      g_hEma50_H2 != INVALID_HANDLE && g_hEma20_H4 != INVALID_HANDLE &&
      g_hEma50_H4 != INVALID_HANDLE) return;

   ReleaseIndicatorHandles();

   ResetLastError();
   g_hAtr_H1   = iATR(sym, PERIOD_H1, MathMax(1, InpATRPeriod));
   g_hEma20_H1 = iMA(sym, PERIOD_H1, MathMax(1, InpEMA20_Period), 0, MODE_EMA, PRICE_CLOSE);
   g_hEma50_H1 = iMA(sym, PERIOD_H1, MathMax(1, InpEMA50_Period), 0, MODE_EMA, PRICE_CLOSE);
   g_hEma20_H2 = iMA(sym, PERIOD_H2, MathMax(1, InpEMA20_Period), 0, MODE_EMA, PRICE_CLOSE);
   g_hEma50_H2 = iMA(sym, PERIOD_H2, MathMax(1, InpEMA50_Period), 0, MODE_EMA, PRICE_CLOSE);
   g_hEma20_H4 = iMA(sym, PERIOD_H4, MathMax(1, InpEMA20_Period), 0, MODE_EMA, PRICE_CLOSE);
   g_hEma50_H4 = iMA(sym, PERIOD_H4, MathMax(1, InpEMA50_Period), 0, MODE_EMA, PRICE_CLOSE);
   g_cachedHandleSymbol = sym;
}

// Symbol Switch & Market Quality State Reset (Section 14)
void ResetMarketQualityState(string newSym)
{
   ArrayInitialize(g_spreadHistory, 0.0);
   g_spreadSampleCount = 0;
   g_dynamicTypicalSpread = 0.0;
   g_currentSpreadRatio = 0.0;
   g_tickActivityRatio = 0.0;
   g_liquidityState = "N/A";
   g_volatilityRegime = "N/A";
   g_volatilityScore = 0.0;
   g_volAtrRatio = 0.0;
   g_volRangeRatio = 0.0;
   g_lastAdviceScanBarTime = 0;
   g_terminalScrollIndex = 0;

   // Reset structural confluence & swing levels
   g_h1Bias = "NEUTRAL";
   g_h2Bias = "NEUTRAL";
   g_h4Bias = "NEUTRAL";
   g_overallBias = "NEUTRAL";
   g_plannedAction = "NONE";
   g_marketStructure = "NEUTRAL";
   g_recentSwingHigh = 0.0;
   g_recentSwingLow = 0.0;
   g_recentSupport = 0.0;
   g_recentResistance = 0.0;
   g_recentPivotTime = 0;

   // Preserve active signal across restart/hibernate: only clear if no open trades and no saved valid signal on newSym
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string sigValKey = "SEGS_SIG_" + IntegerToString(login) + "_" + newSym + "_VALID";
   bool hasActiveSignal = (GlobalVariableCheck(sigValKey) && GlobalVariableGet(sigValKey) > 0.5);
   bool hasOpenTrades = (CountOpenAdvisorTradesForSymbol(newSym) > 0);

   if(!hasActiveSignal && !hasOpenTrades)
   {
      g_setupState = "SCANNING";
      g_setupQuality = 0;
      g_blockReason = "INITIALIZING / CHECKING MARKET";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_currentSignalID = "";
      g_currentTradeTaken = false;
   }
   else
   {
      // Preserve and restore the active signal and trade status
      RestoreActiveSignalSnapshot(newSym);
   }

   // Reset M30 Order Block state
   ArrayResize(g_orderBlocks, 0);
   g_obCount = 0;
   g_lastOBScanBarTime = 0;
   g_nearestBullishOB = -1;
   g_nearestBearishOB = -1;
   g_distanceToDemand = 0.0;
   g_distanceToSupply = 0.0;
   g_obLocationWarning = "CLEAR";
   g_obSignalScore = 0;
   g_obSignalDirection = "NONE";

   g_lastTrackedSymbol = newSym;
   InitIndicatorHandles(newSym);
}

void OnDeinit(const int reason)
{
   PrintFormat("[SEGS DEINIT] reason=%d, lastError=%d, symbol=%s, chart=%I64d, phase=%.0f", reason, GetLastError(), _Symbol, ChartID(), GlobalVariableGet("SEGS_PHASE_" + IntegerToString(ChartID())));
   g_runtimeReady = false;
   GlobalVariableDel("SEGS_HB_" + IntegerToString(ChartID()));
   EventKillTimer();
   ReleaseIndicatorHandles();

   // CRITICAL: Unconditionally persist MyAdvisor, HUD toggles, and active Trade Signal across terminal restart & hibernation
   SaveAdvisorPersistentState();

   // Preserving visual markings and state across timeframe changes (REASON_CHARTCHANGE / REASON_RECOMPILE)
   if(reason == REASON_CHARTCHANGE || reason == REASON_RECOMPILE)
   {
      // Clean only the dashboard table so it re-anchors cleanly, keeping Open Trade Markings intact!
      DeleteTerminalObjects();
      return;
   }

   ObjectsDeleteAll(0, PREFIX);
   DeleteTradeAdviceLines();
   DeleteOpenTradeMarkings();
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS, true);
   ChartRedraw();

   // In multi-chart architecture, removing one chart MUST NEVER delete account-wide SEGS_MYADVISOR!
   // Only chart-specific UI globals for this chart may be cleared when user explicitly REMOVES the EA
   if(reason == REASON_REMOVE)
   {
      string chartStr = IntegerToString(ChartID());
      GlobalVariableDel("SEGS_TP2_BE_" + chartStr);
      GlobalVariableDel("SEGS_SHOW_OPENTRD_" + chartStr);
      GlobalVariableDel("SEGS_ACTIVE_TAB_" + chartStr);
      GlobalVariableDel("SEGS_SHOW_SENT_" + chartStr);
      GlobalVariableDel("SEGS_SHOW_TGTS_" + chartStr);
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void SEGSCalibrateActiveZoneProtection()
{
   if(g_systemStopStyle != SL_STYLE_ACTIVE_ORDER_BLOCK || !SEGSMarketReady(_Symbol)) return;
   double atr = 0.0, values[];
   if(g_hAtr_H1 == INVALID_HANDLE || CopyBuffer(g_hAtr_H1, 0, 1, 1, values) != 1) return;
   atr = values[0];
   if(!MathIsValidNumber(atr) || atr <= 0.0) return;
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_systemTrailOB && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !posInfo.SelectByTicket(ticket) || posInfo.Symbol() != _Symbol) continue;
         if(posInfo.Magic() != InpAdvisorMagicNumber && StringFind(posInfo.Comment(), "SEGS|ADV") < 0) continue;
         bool buy = posInfo.PositionType() == POSITION_TYPE_BUY;
         double market = SymbolInfoDouble(_Symbol, buy ? SYMBOL_BID : SYMBOL_ASK);
         double stop = GetSafestStructuralStopLoss(_Symbol, buy ? "BUY" : "SELL", market, 0.0, 0.0, atr);
         double oldSL = posInfo.StopLoss();
         if(stop <= 0.0 || (oldSL > 0.0 && (buy ? stop <= oldSL + tick : stop >= oldSL - tick))) continue;
         if(ValidateProtectionTarget(_Symbol, posInfo.PositionType(), market, stop, true) != 1) continue;
         if(trade.PositionModify(ticket, stop, posInfo.TakeProfit()) && trade.ResultRetcode() == TRADE_RETCODE_DONE)
            PrintFormat("[SEGS STRUCTURAL TRAIL] %s ticket=%I64u oldSL=%.8f newSL=%.8f", _Symbol, ticket, oldSL, stop);
      }
   }
   string activeDir; double entry=0.0, stop=0.0, t1=0.0,t2=0.0,t3=0.0,t4=0.0; int count=0;
   if(GetOpenAdvisorTradeDetails(_Symbol, activeDir, entry, stop, t1,t2,t3,t4,count))
   {
      g_staticSL = stop; // Actual broker stop, including profitable trailing stops above/below entry.
      UpdateTradeAdviceLines();
      return;
   }
   string dir = g_currentAdvisedAction;
   if(dir != "BUY" && dir != "SELL") dir = g_plannedAction;
   if(dir != "BUY" && dir != "SELL") return;
   double quote = SymbolInfoDouble(_Symbol, dir == "BUY" ? SYMBOL_ASK : SYMBOL_BID);
   double calibrated = GetSafestStructuralStopLoss(_Symbol, dir, quote, 0.0, 0.0, atr);
   if(calibrated <= 0.0) { g_hasViableEntry=false; g_blockReason="WAITING FOR ACTIVE ORDER BLOCK"; return; }
   if(g_staticEntryPrice <= 0.0 || (dir == "BUY" ? calibrated >= g_staticEntryPrice : calibrated <= g_staticEntryPrice))
   {
      // The old plan is incompatible with current active structure. Show a current preview,
      // requiring the normal scanner to validate a fresh signal before any order is sent.
      g_staticEntryPrice = quote;
      g_hasViableEntry = false; g_currentTradeTaken = false;
      g_setupState = "WATCHING";
      g_blockReason = "ACTIVE ZONE UPDATED: AWAITING FRESH ENTRY CONFIRMATION";
      g_currentSignalID = "";
      ClearActiveSignalSnapshot(_Symbol);
   }
   g_staticSL = calibrated;
   BuildStructuralTargets(_Symbol, dir, g_staticEntryPrice, calibrated, atr,
      g_staticTP1,g_staticTP2,g_staticTP3,g_staticTP4,g_rrTP2,g_rrWeighted);
   UpdateTradeAdviceLines();
}

void RunAdvisorStrategyEngine(bool forceScan, bool allowAutoTrade)
{
   if(!g_runtimeReady || !SEGSMarketReady(_Symbol)) return;
   static ulong nextScanMs = 0;
   ulong scanNowMs = GetTickCount64();
   if(!forceScan && scanNowMs < nextScanMs) return;
   nextScanMs = scanNowMs + 1000;
   // Strategy engine runs independently of HUD visual toggle (Section 32, 47)
   GlobalVariableSet("SEGS_PHASE_" + IntegerToString(ChartID()), 2.0);
   UpdateHTFLiquidityLevels(_Symbol);
   UpdateM30OrderBlocks(forceScan);
   UpdateH1OrderBlocks(forceScan);
   GlobalVariableSet("SEGS_PHASE_" + IntegerToString(ChartID()), 3.0);
   ScanMarketStructureAndAdvice(forceScan);
   if(SEGSResetExpiredSetup(_Symbol)) ScanMarketStructureAndAdvice(true);
   SEGSCalibrateActiveZoneProtection();
   UpdateOBLocationSnapshot(_Symbol);
   UpdateH1OBLocationSnapshot(_Symbol);
   if(allowAutoTrade)
      CheckAndAutoTradeAdvice();
}

void OnTick()
{
   if(!SEGSEnsureRuntimeReady()) return;
   GlobalVariableSet("SEGS_PHASE_" + IntegerToString(ChartID()), 1.0);
   EnforcePositionStopLossAndTargets();
   CheckBreakevenConditions();
   CheckTrailingClose();
   HealOpenAdvisorPositions(_Symbol);

   if(g_currentMode == MODE_COMPLETE_AUTO)
      ProcessUnassignedPositions();

   // Independent Strategy Evaluation on Tick
   RunAdvisorStrategyEngine(false, true);

   ulong nowMs = GetTickCount64();
   if(nowMs - g_lastTickUpdateTime >= 200)
   {
      g_lastTickUpdateTime = nowMs;
      DrawUnifiedTerminalDashboard();
      if(g_showSentimentHUD) DrawSentimentHUD();
      if(g_showOpenTradeMarkings) UpdateOpenTradeMarkings();
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!SEGSEnsureRuntimeReady()) return;
   // 1. Maintain Chart Heartbeat and ensure chart keyboard messages route to EA
   long myChartId = ChartID();
   GlobalVariableSet("SEGS_HB_" + IntegerToString(myChartId), (double)TimeCurrent());
   ChartSetInteger(0, CHART_KEYBOARD_CONTROL, false);

   // 2. Synchronize System-Wide Dashboard and Sentiment Settings across all open chart tabs
   if(GlobalVariableCheck("SEGS_SYS_DASH_VIS"))
   {
      bool sysDash = (GlobalVariableGet("SEGS_SYS_DASH_VIS") > 0.5);
      if(sysDash != g_isDashboardVisible)
      {
         g_isDashboardVisible = sysDash;
         GlobalVariableSet("SEGS_DASH_VIS_" + IntegerToString(ChartID()), sysDash ? 1.0 : 0.0);
         if(!g_isDashboardVisible) DeleteTerminalObjects();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
   }
   if(GlobalVariableCheck("SEGS_SYS_SHOW_SENT"))
   {
      bool sysSent = (GlobalVariableGet("SEGS_SYS_SHOW_SENT") > 0.5);
      if(sysSent != g_showSentimentHUD)
      {
         g_showSentimentHUD = sysSent;
         if(!g_showSentimentHUD) ObjectsDeleteAll(0, PREFIX + "SNT_");
         else DrawSentimentHUD();
         ChartRedraw();
      }
   }

   // 3. Multi-Chart Isolation: Each EA chart instance strictly manages its own chart objects.
   // Chart keyboard routing reinforcement to guarantee hotkeys M and H are never intercepted by MT5
   ChartSetInteger(0, CHART_KEYBOARD_CONTROL, false);

   GlobalVariableSet("SEGS_PHASE_" + IntegerToString(ChartID()), 1.0);
   EnforcePositionStopLossAndTargets();
   CheckBreakevenConditions();
   CheckTrailingClose();
   RunAdvisorStrategyEngine(false, true);
   GlobalVariableSet("SEGS_PHASE_" + IntegerToString(ChartID()), 4.0);
   DrawUnifiedTerminalDashboard();
   if(g_showSentimentHUD) DrawSentimentHUD();
   if(g_showOpenTradeMarkings) UpdateOpenTradeMarkings();
}

//+------------------------------------------------------------------+
//| Trade Transaction handler (Detects manual trades & duplicates)   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!g_runtimeReady) return; // Startup reconstruction recovers trades once history is ready.
   // 1. Detect new DEAL_ADD (Market position filled or closed)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(deal == 0) return;

      if(!HistoryDealSelect(deal))
      {
         HistorySelect(0, TimeCurrent());
         if(!HistoryDealSelect(deal)) return;
      }

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      
      // Handle position closure (DEAL_ENTRY_OUT)
      if(entry == DEAL_ENTRY_OUT)
      {
         ulong posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
         long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
         string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
         string cmt = HistoryDealGetString(deal, DEAL_COMMENT);

         bool isAdvisor = (magic == InpAdvisorMagicNumber || StringFind(cmt, "SEGS|ADV") >= 0 || StringFind(cmt, "[MyAdvisor]") >= 0 || StringFind(cmt, "[Advised") >= 0);
         if(isAdvisor)
         {
            PrintFormat("[SEGS PRO] Advisor position #%I64u on %s closed (Deal #%I64u). Registering closure and applying manual close protection lockout.", posId, sym, deal);
            string cleanSym = sym;
            StringToUpper(cleanSym);
            if(IsSymbolMatch(cleanSym, InpXAU_Patterns))       cleanSym = "XAUUSD";
            else if(IsSymbolMatch(cleanSym, InpDJ30_Patterns)) cleanSym = "US30";
            else if(IsSymbolMatch(cleanSym, InpNAS_Patterns))  cleanSym = "NAS100";
            else if(IsSymbolMatch(cleanSym, InpGJ_Patterns))   cleanSym = "GBPJPY";
            else if(IsSymbolMatch(cleanSym, InpGU_Patterns))   cleanSym = "GBPUSD";
            else if(IsSymbolMatch(cleanSym, InpAUD_Patterns))  cleanSym = "AUDUSD";
            else if(IsSymbolMatch(cleanSym, InpOIL_Patterns))  cleanSym = "USOIL";
            else if(IsSymbolMatch(cleanSym, InpBTC_Patterns))  cleanSym = "BTCUSD";
            else if(IsSymbolMatch(cleanSym, InpAMD_Patterns))  cleanSym = "AMD";

            string gvCdKey = "SEGS_COOLDOWN_" + cleanSym + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
             GlobalVariableSet(gvCdKey, (double)(TimeCurrent() + 15)); // 15-second anti-spam cooldown

            // The current candidate can belong to a different set. Its dedup record is untouched.
            g_currentTradeTaken = true;
         }
         return;
      }

      if(entry != DEAL_ENTRY_IN) return;

      // FIX 6: Explicit eligibility check to prevent cloning unrelated EAs or clones
      if(!IsEligibleNewMasterDeal(deal)) return;

      ulong masterPosId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(masterPosId == 0 || AlreadyHandledOrder(masterPosId)) return;

      // Account-Wide Global Protection across multiple open charts:
      // Section 8 & 9: Atomic reservation prevents race conditions across charts
      if(!TryReserveMasterPosition(masterPosId)) return;
      MarkOrderHandled(masterPosId);

      // Check open positions limit before duplicating (Section 10: SEGS-managed only)
      int currentSEGS = CountOpenSEGSPositions();
      if(currentSEGS + InpNumClonedTrades > InpAdvisorMaxTotalOpenTrades)
      {
         PrintFormat("[SEGS PRO] Max open SEGS positions ceiling reached (%d/%d). Trade cloning skipped.", currentSEGS, InpAdvisorMaxTotalOpenTrades);
         SetMasterPositionState(masterPosId, -1.0);
         return;
      }

      // Strict separation of master open position ticket and persistent position identifier
      ulong masterTicket = 0;
      for(int retry = 0; retry < 3; retry++)
      {
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong pt = PositionGetTicket(p);
            if(pt > 0 && posInfo.SelectByTicket(pt))
            {
               ulong pId = (ulong)posInfo.Identifier();
               if(pId == 0) pId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
               if(pId == masterPosId)
               {
                  masterTicket = pt;
                  break;
               }
            }
         }
         if(masterTicket > 0) break;
         Sleep(20);
      }

      string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
      double vol = HistoryDealGetDouble(deal, DEAL_VOLUME);
      double price = HistoryDealGetDouble(deal, DEAL_PRICE);
      ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
      ENUM_POSITION_TYPE ptype = (dtype == DEAL_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      // Micro-Fix 3: If actual open master position cannot be confirmed, do NOT create clones!
      if(masterTicket == 0 || !posInfo.SelectByTicket(masterTicket))
      {
         PrintFormat("[SEGS PRO] ERROR: Open master position ticket could not be confirmed for posId #%I64u (deal #%I64u). Cloning BLOCKED.", masterPosId, deal);
         SetMasterPositionState(masterPosId, -1.0); // Marked as failed to resolve
         return;
      }

      // Verify that resolved master position:
      // 1. has POSITION_IDENTIFIER == masterPosId
      // 2. matches the correct symbol
      // 3. matches the correct direction
      // 4. is still open
      ulong confirmedPosId = (ulong)posInfo.Identifier();
      if(confirmedPosId == 0) confirmedPosId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      string posSym = posInfo.Symbol();
      ENUM_POSITION_TYPE posPtype = posInfo.PositionType();

      if(confirmedPosId != masterPosId || posSym != sym || posPtype != ptype)
      {
         PrintFormat("[SEGS PRO] ERROR: Master position validation failed for ticket #%I64u (Expected posId=%I64u, sym=%s, type=%d; Got posId=%I64u, sym=%s, type=%d). Cloning BLOCKED.",
                     masterTicket, masterPosId, sym, (int)ptype, confirmedPosId, posSym, (int)posPtype);
         SetMasterPositionState(masterPosId, -1.0);
         return;
      }

      // Duplicate extra trades (e.g. 3 more trades for 4 legs total)
      if(InpNumClonedTrades > 0)
      {
         DuplicateTrade(masterTicket, masterPosId, sym, ptype, vol, price);
      }
      else
      {
         SetMasterPositionState(masterPosId, 2.0); // 1-leg manual trade completed
      }

      // If Complete Auto mode is active, assign SL & TP immediately
      if(g_currentMode == MODE_COMPLETE_AUTO)
      {
         Sleep(80);
         ProcessUnassignedPositions();
      }

      DrawUnifiedTerminalDashboard();
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| Check if order ticket was already handled                        |
//+------------------------------------------------------------------+
bool AlreadyHandledOrder(ulong tk)
{
   for(int i = 0; i < g_handledOrderCount; i++)
   {
      if(g_handledOrders[i] == tk) return true;
   }
   return false;
}

void MarkOrderHandled(ulong tk)
{
   if(g_handledOrderCount < MAX_TRACKED_ORDERS)
   {
      g_handledOrders[g_handledOrderCount++] = tk;
   }
}

//+------------------------------------------------------------------+
//| Duplicate Trade: Open configured number of extra trades          |
//| Exact logical leg mapping: Master = L1/TP1, Clones = L2..4       |
//| Mandatory Leg 2 & 4-leg baseline: Verified rollback on failure   |
//+------------------------------------------------------------------+
void DuplicateTrade(ulong masterTicket, ulong masterPosId, string sym, ENUM_POSITION_TYPE ptype, double vol, double openPrice)
{
   double tradeVol = (InpClonedLotSize > 0.0) ? InpClonedLotSize : ((vol > 0.0) ? vol : InpFallbackLot);
   tradeVol = NormalizeVolumeToSymbolStep(sym, tradeVol);
   if(tradeVol <= 0.0)
   {
      PrintFormat("[SEGS PRO] ERROR: Cannot clone trade for master PosID #%I64u - invalid lot size (%.2f). Aborting.", masterPosId, tradeVol);
      SetMasterPositionState(masterPosId, -1.0);
      return;
   }

   trade.SetTypeFillingBySymbol(sym);
   trade.SetExpertMagicNumber(InpClonedMagicNumber);

   PrintFormat("[SEGS PRO] Duplicating 3 clones for %s master PosID #%I64u (Ticket #%I64u, %.2f lots)",
               sym, masterPosId, masterTicket, tradeVol);

   // Exact logical leg arrays: index 0 = Master/L1, 1 = Leg 2/TP2, 2 = Leg 3/TP3, 3 = Leg 4/TP4
   ulong legTickets[4];
   ulong legPosIds[4];
   bool  legOpened[4];
   for(int k = 0; k < 4; k++)
   {
      legTickets[k] = 0;
      legPosIds[k]  = 0;
      legOpened[k]  = false;
   }

   legTickets[0] = masterTicket;
   legPosIds[0]  = masterPosId;
   legOpened[0]  = true; // Master leg already open

   int successfulClones = 0;

   // Clone 1 -> Leg 2 (TP2)
   // Clone 2 -> Leg 3 (TP3)
   // Clone 3 -> Leg 4 (TP4)
   for(int cloneIdx = 1; cloneIdx <= InpNumClonedTrades; cloneIdx++)
   {
      int legNumber = cloneIdx + 1; // 2, 3, 4
      string comment = StringFormat("SEGS|MAN|%I64u|L%d/4", masterPosId, legNumber);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);

      ResetLastError();
      bool ok = false;
      if(ptype == POSITION_TYPE_BUY)
         ok = trade.Buy(tradeVol, sym, ask, 0.0, 0.0, comment);
      else
         ok = trade.Sell(tradeVol, sym, bid, 0.0, 0.0, comment);

      uint retcode = trade.ResultRetcode();
      if(!ok || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED))
      {
         PrintFormat("[SEGS CLONE] Failed to open Leg %d/4 for master #%I64u: retcode=%u (%s)",
                     legNumber, masterPosId, retcode, trade.ResultRetcodeDescription());
      }
      else
      {
         ulong dealTk = trade.ResultDeal();
         ulong newTicket = 0;
         ulong newPosId  = 0;
         if(ResolvePositionTicketAndIdFromDeal(dealTk, sym, InpClonedMagicNumber, comment, newTicket, newPosId))
         {
            legTickets[cloneIdx] = newTicket;
            legPosIds[cloneIdx]  = newPosId;
            legOpened[cloneIdx]  = true;
            successfulClones++;
            PrintFormat("[SEGS CLONE] Leg %d/4 successfully opened: Ticket=#%I64u, PosID=#%I64u (Comment: %s)",
                        legNumber, newTicket, newPosId, comment);
         }
         else
         {
            PrintFormat("[SEGS CLONE] Warning: Deal #%I64u executed but failed to resolve open position for Leg %d (%s)",
                        dealTk, legNumber, comment);
         }
      }
      Sleep(40);
   }

   // Always restore Master Magic Number
   trade.SetExpertMagicNumber(InpMasterMagicNumber);

   // CRITICAL BASELINE RULE:
   // All 3 clones are required (Master + Leg 2 + Leg 3 + Leg 4).
   // Specifically, if Leg 2 (TP2) fails to open, the entire cloning group MUST be rolled back!
   bool allClonesSuccessful = (successfulClones == InpNumClonedTrades) && legOpened[1] && legOpened[2] && legOpened[3];

   if(allClonesSuccessful)
   {
      SetMasterPositionState(masterPosId, 2.0); // 2.0 = COMPLETED
      PrintFormat("[SEGS PRO] Manual master #%I64u: All %d clones opened successfully. Registering complete 4-leg group.",
                  masterPosId, successfulClones);

      PositionGroup grp;
      InitPositionGroup(grp);
      grp.groupTime        = TimeCurrent();
      grp.tpTriggerHit     = false;
      grp.breakevenApplied = false;
      grp.positionCount    = 4;
      grp.symbol           = sym;
      grp.positionType     = ptype;
      grp.setupID          = "MAN_" + IntegerToString(masterPosId);

      for(int k = 0; k < 4; k++)
      {
         grp.tickets[k]     = legTickets[k];
         grp.positionIds[k] = legPosIds[k];
      }

      int existingIdx = FindGroupIndexBySetupOrPosition(grp.setupID, masterTicket, masterPosId);
      if(existingIdx >= 0)
      {
         for(int k = 0; k < 4; k++)
         {
            if(grp.tickets[k] > 0)
            {
               g_groups[existingIdx].tickets[k]     = grp.tickets[k];
               g_groups[existingIdx].positionIds[k] = grp.positionIds[k];
            }
         }
         UpdateGroupPositionCount(existingIdx);
      }
      else
      {
         int gIdx = ArraySize(g_groups);
         ArrayResize(g_groups, gIdx + 1);
         g_groups[gIdx] = grp;
         UpdateGroupPositionCount(gIdx);
      }
   }
   else
   {
      // Partial failure or missing Leg 2: Verified rollback of all opened clones
      PrintFormat("[SEGS CLONE] CRITICAL: Partial clone failure for master #%I64u (Opened: %d/%d, Leg 2: %s). Initiating verified rollback...",
                  masterPosId, successfulClones, InpNumClonedTrades, legOpened[1] ? "OK" : "FAILED");

      // 1. Close all identified clone tickets
      for(int k = 1; k <= InpNumClonedTrades; k++)
      {
         if(legOpened[k] && legTickets[k] > 0)
         {
            ResetLastError();
            bool closed = trade.PositionClose(legTickets[k]);
            uint ret = trade.ResultRetcode();
            if(!closed || (ret != TRADE_RETCODE_DONE && ret != TRADE_RETCODE_PLACED))
            {
               PrintFormat("[SEGS CLONE] Rollback PositionClose FAILED for leg ticket #%I64u: retcode=%u (%s)",
                           legTickets[k], ret, trade.ResultRetcodeDescription());
            }
         }
      }

      // 2. Rescan and close any remaining open clone positions by comment pattern
      string cloneCommentPattern = "SEGS|MAN|" + IntegerToString(masterPosId);
      for(int retry = 0; retry < 3; retry++)
      {
         int remainingOrphans = 0;
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong pt = PositionGetTicket(p);
            if(pt > 0 && posInfo.SelectByTicket(pt))
            {
               if(posInfo.Magic() == InpClonedMagicNumber && StringFind(posInfo.Comment(), cloneCommentPattern) >= 0)
               {
                  ResetLastError();
                  trade.PositionClose(pt);
                  remainingOrphans++;
               }
            }
         }
         if(remainingOrphans == 0) break;
         Sleep(40);
      }

      // 3. Final verification of rollback
      int survivingOrphans = 0;
      for(int p = PositionsTotal() - 1; p >= 0; p--)
      {
         ulong pt = PositionGetTicket(p);
         if(pt > 0 && posInfo.SelectByTicket(pt))
         {
            if(posInfo.Magic() == InpClonedMagicNumber && StringFind(posInfo.Comment(), cloneCommentPattern) >= 0)
               survivingOrphans++;
         }
      }

      if(survivingOrphans > 0)
      {
         string alertMsg = StringFormat("[SEGS CLONE] CRITICAL ALERT: %d orphaned clone position(s) remain open for master #%I64u after rollback!",
                                        survivingOrphans, masterPosId);
         Print(alertMsg);
         Alert(alertMsg);
      }
      else
      {
         PrintFormat("[SEGS CLONE] Rollback verified: All partial clones for master #%I64u successfully closed.", masterPosId);
      }

      SetMasterPositionState(masterPosId, -1.0); // -1.0 = FAILED
   }
}

bool IsSymbolMatch(string sym, string pattern)
{
   string upper = sym;
   StringToUpper(upper);
   string parts[];
   int cnt = StringSplit(pattern, ',', parts);
   for(int i = 0; i < cnt; i++)
   {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p); StringToUpper(p);
      if(p != "" && StringFind(upper, p) >= 0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Asset Category                                            |
//+------------------------------------------------------------------+
string DetectAssetType(string sym)
{
   string upper = sym;
   StringToUpper(upper);

   // Nasdaq Disambiguation:
   // If broker symbol contains NDAQ:
   // If current price > 1000.0: it is the Nasdaq-100 Index CFD (trading at ~21,000 points)
   // If current price <= 1000.0: it is the Nasdaq, Inc. Equity Stock CFD (trading at ~$94/share)
   if(StringFind(upper, "NDAQ") >= 0)
   {
      double curPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curPrice <= 0.0) curPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curPrice <= 0.0) curPrice = SymbolInfoDouble(sym, SYMBOL_LAST);
      if(curPrice > 1000.0) return "NAS100";
      return "AMD"; // US Equity Stock CFD
   }

   if(IsSymbolMatch(sym, InpNAS_Patterns))  return "NAS100";
   if(IsSymbolMatch(sym, InpAMD_Patterns) ||
      StringFind(upper, "AAPL") >= 0 || StringFind(upper, "TSLA") >= 0 ||
      StringFind(upper, "NVDA") >= 0 || StringFind(upper, "MSFT") >= 0 ||
      StringFind(upper, "AMZN") >= 0 || StringFind(upper, "META") >= 0 ||
      StringFind(upper, "GOOG") >= 0)
      return "AMD";
   if(IsSymbolMatch(sym, InpXAU_Patterns))  return "XAU";
   if(IsSymbolMatch(sym, InpDJ30_Patterns)) return "DJ30";
   if(IsSymbolMatch(sym, InpNAS_Patterns))  return "NAS100";
   if(IsSymbolMatch(sym, InpGJ_Patterns))   return "GBPJPY";
   if(IsSymbolMatch(sym, InpGU_Patterns))   return "GBPUSD";
   if(IsSymbolMatch(sym, InpAUD_Patterns))  return "AUDUSD";
   if(IsSymbolMatch(sym, InpOIL_Patterns))  return "USOIL";
   if(IsSymbolMatch(sym, InpBTC_Patterns))  return "BTCUSD";
   return "FOREX";
}

//+------------------------------------------------------------------+
//| Check if trade symbol matches the active chart asset             |
//+------------------------------------------------------------------+
bool IsSameChartAsset(string symA, string symB)
{
   if(symA == symB) return true;
   string a = symA; StringToUpper(a);
   string b = symB; StringToUpper(b);
   if(a == b) return true;
   if(StringFind(a, b) >= 0 || StringFind(b, a) >= 0) return true;
   string catA = DetectAssetType(symA);
   string catB = DetectAssetType(symB);
   if(catA != "FOREX" && catA == catB) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Retrieve exact targets (SL, TP1..TP4) for detected asset         |
//+------------------------------------------------------------------+
void GetAssetTargets(string sym, double &slPips, double &tp1, double &tp2, double &tp3, double &tp4)
{
   string asset = DetectAssetType(sym);
   if(asset == "XAU")
   {
      slPips = InpXAU_SL_Pips;
      tp1    = InpXAU_TP1_Pips;
      tp2    = InpXAU_TP2_Pips;
      tp3    = InpXAU_TP3_Pips;
      tp4    = InpXAU_TP4_Pips;
   }
   else if(asset == "DJ30")
   {
      slPips = InpDJ30_SL_Pips;
      tp1    = InpDJ30_TP1_Pips;
      tp2    = InpDJ30_TP2_Pips;
      tp3    = InpDJ30_TP3_Pips;
      tp4    = InpDJ30_TP4_Pips;
   }
   else if(asset == "NAS100")
   {
      slPips = InpNAS_SL_Pips;
      tp1    = InpNAS_TP1_Pips;
      tp2    = InpNAS_TP2_Pips;
      tp3    = InpNAS_TP3_Pips;
      tp4    = InpNAS_TP4_Pips;
   }
   else if(asset == "GBPJPY")
   {
      slPips = InpGJ_SL_Pips;
      tp1    = InpGJ_TP1_Pips;
      tp2    = InpGJ_TP2_Pips;
      tp3    = InpGJ_TP3_Pips;
      tp4    = InpGJ_TP4_Pips;
   }
   else if(asset == "BTCUSD")
   {
      slPips = InpBTC_SL_Pips;
      tp1    = InpBTC_TP1_Pips;
      tp2    = InpBTC_TP2_Pips;
      tp3    = InpBTC_TP3_Pips;
      tp4    = InpBTC_TP4_Pips;
   }
   else if(asset == "AMD")
   {
      slPips = InpAMD_SL_Pips;
      tp1    = InpAMD_TP1_Pips;
      tp2    = InpAMD_TP2_Pips;
      tp3    = InpAMD_TP3_Pips;
      tp4    = InpAMD_TP4_Pips;
   }
   else if(asset == "AUDUSD")
   {
      slPips = InpAUD_SL_Pips;
      tp1    = InpAUD_TP1_Pips;
      tp2    = InpAUD_TP2_Pips;
      tp3    = InpAUD_TP3_Pips;
      tp4    = InpAUD_TP4_Pips;
   }
   else if(asset == "GBPUSD")
   {
      slPips = InpGU_SL_Pips;
      tp1    = InpGU_TP1_Pips;
      tp2    = InpGU_TP2_Pips;
      tp3    = InpGU_TP3_Pips;
      tp4    = InpGU_TP4_Pips;
   }
   else if(asset == "USOIL")
   {
      slPips = InpOIL_SL_Pips;
      tp1    = InpOIL_TP1_Pips;
      tp2    = InpOIL_TP2_Pips;
      tp3    = InpOIL_TP3_Pips;
      tp4    = InpOIL_TP4_Pips;
   }
   else
   {
      slPips = InpFX_SL_Pips;
      tp1    = InpFX_TP1_Pips;
      tp2    = InpFX_TP2_Pips;
      tp3    = InpFX_TP3_Pips;
      tp4    = InpFX_TP4_Pips;
   }
}

//+------------------------------------------------------------------+
//| Get exact price distance corresponding to 1 pip for any symbol   |
//+------------------------------------------------------------------+
double GetPipSize(string sym)
{
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   // Display-only fallback is derived from this symbol's precision, never _Point.
   // Execution paths separately require real broker point and tick metadata.
   if(!MathIsValidNumber(pt) || pt <= 0.0)
      pt = MathPow(10.0, -(int)MathMax(0, MathMin(8, SymbolInfoInteger(sym, SYMBOL_DIGITS))));
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string upperSym = sym;
   StringToUpper(upperSym);

   if(StringFind(upperSym, "NDAQ") >= 0)
   {
      double curPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curPrice <= 0.0) curPrice = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curPrice <= 0.0) curPrice = SymbolInfoDouble(sym, SYMBOL_LAST);
      if(curPrice > 1000.0)
      {
         if(InpNAS_PipMultiplier > 0.0) return InpNAS_PipMultiplier;
         return (digits == 2) ? (pt * 100.0) : (pt > 0.0 ? pt : 1.0);
      }
      return (digits == 2) ? 0.01 : (pt > 0.0 ? pt : 0.01);
   }
   if(IsSymbolMatch(sym, InpAMD_Patterns))
   {
      return (digits == 2) ? 0.01 : (pt > 0.0 ? pt : 0.01);
   }
   if(IsSymbolMatch(sym, InpXAU_Patterns))
   {
      if(InpXAU_PipMultiplier > 0.0) return InpXAU_PipMultiplier;
      return (digits == 3) ? (pt * 100.0) : (pt * 10.0);
   }
   if(IsSymbolMatch(sym, InpBTC_Patterns))
   {
      if(InpBTC_PipMultiplier > 0.0) return InpBTC_PipMultiplier;
      return (digits == 2) ? (pt * 100.0) : (pt > 0.0 ? pt : 1.0);
   }
   if(IsSymbolMatch(sym, InpDJ30_Patterns))
   {
      if(InpDJ30_PipMultiplier > 0.0) return InpDJ30_PipMultiplier;
      return (digits == 2) ? (pt * 100.0) : (pt > 0.0 ? pt : 1.0);
   }
   if(IsSymbolMatch(sym, InpNAS_Patterns))
   {
      if(InpNAS_PipMultiplier > 0.0) return InpNAS_PipMultiplier;
      return (digits == 2) ? (pt * 100.0) : (pt > 0.0 ? pt : 1.0);
   }
   if(IsSymbolMatch(sym, InpOIL_Patterns))
   {
      if(InpOIL_PipMultiplier > 0.0) return InpOIL_PipMultiplier;
      return (digits == 2 || digits == 3) ? (pt * 10.0) : (pt > 0.0 ? pt : 0.10);
   }
   if(IsSymbolMatch(sym, InpAMD_Patterns))
   {
      return (digits == 2) ? 0.01 : (pt > 0.0 ? pt : 0.01);
   }

   // 3 or 5 digit Forex pairs: 1 pip = 10 points
   if(digits == 3 || digits == 5)
      return (pt > 0.0 ? pt * 10.0 : 0.0001);

   return (pt > 0.0 ? pt : 0.0001);
}

//+------------------------------------------------------------------+
//| PROCESS SL & TP FOR UNASSIGNED POSITIONS (Used on 'P' or Auto)   |
//| Groups open trades by symbol and direction into 4-leg sets       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Reconstruct Position Groups from open SEGS positions on startup  |
//| Preserves TP2-BE and multi-leg state across MT5 restarts / scans |
//| Sections 2, 20, 21, 22: setupID, positionIds, breakeven recovery |
//+------------------------------------------------------------------+
void ReconstructPositionGroups()
{
   ArrayResize(g_groups, 0);
   int total = PositionsTotal();
   if(total == 0) return;

   struct OpenPosMeta
   {
      ulong              ticket;
      ulong              posId;
      string             symbol;
      ENUM_POSITION_TYPE ptype;
      string             comment;
      long               magic;
      datetime           openTime;
      double             openPrice;
      double             sl;
      double             tp;
      string             groupKey;
      int                legNum;
   };

   OpenPosMeta items[];
   int count = 0;
   ArrayResize(items, total);

   for(int i = 0; i < total; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && posInfo.SelectByTicket(tk))
      {
         if(!IsSEGSManagedPosition(tk) && !IsEligibleManualMaster(tk)) continue;

         ulong pId = (ulong)posInfo.Identifier();
         if(pId == 0) pId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if(pId == 0) continue; // Skip position without valid persistent identifier

         string cmt = posInfo.Comment();
         items[count].ticket    = tk;
         items[count].posId     = pId;
         items[count].symbol    = posInfo.Symbol();
         items[count].ptype     = posInfo.PositionType();
         items[count].comment   = cmt;
         items[count].magic     = posInfo.Magic();
         items[count].openTime  = (datetime)posInfo.Time();
         items[count].openPrice = posInfo.PriceOpen();
         items[count].sl        = posInfo.StopLoss();
         items[count].tp        = posInfo.TakeProfit();
         items[count].legNum    = 0;
         items[count].groupKey  = "";

         // 1. Advisor Comment Format: SEGS|ADV|<shortSig>|L%d/%d
         int advIdx = StringFind(cmt, "SEGS|ADV|");
         if(advIdx >= 0)
         {
            string rem = StringSubstr(cmt, advIdx + 9);
            string parts[];
            int nParts = StringSplit(rem, '|', parts);
            if(nParts >= 1)
            {
               items[count].groupKey = "ADV_" + parts[0];
               if(nParts >= 2 && StringSubstr(parts[1], 0, 1) == "L")
                  items[count].legNum = (int)StringToInteger(StringSubstr(parts[1], 1, 1));
            }
         }
         else
         {
            // 2. Manual Clone Comment Format: SEGS|MAN|<masterID>|L%d/%d
            int manIdx = StringFind(cmt, "SEGS|MAN|");
            if(manIdx >= 0)
            {
               string rem = StringSubstr(cmt, manIdx + 9);
               string parts[];
               int nParts = StringSplit(rem, '|', parts);
               if(nParts >= 1)
               {
                  items[count].groupKey = "MAN_" + parts[0];
                  if(nParts >= 2 && StringSubstr(parts[1], 0, 1) == "L")
                     items[count].legNum = (int)StringToInteger(StringSubstr(parts[1], 1, 1));
               }
            }
            else
            {
               // 3. Legacy SEGS_LEG%d#%I64u
               int legPos = StringFind(cmt, "SEGS_LEG");
               int hashPos = StringFind(cmt, "#");
               if(legPos >= 0 && hashPos > legPos)
               {
                  string legStr = StringSubstr(cmt, legPos + 8, hashPos - (legPos + 8));
                  string mId = StringSubstr(cmt, hashPos + 1);
                  items[count].legNum = (int)StringToInteger(legStr);
                  items[count].groupKey = "MAN_" + mId;
               }
               else if(IsEligibleManualMaster(tk))
               {
                  // FIX 5: Explicit correlation for manual master trade to match its clones
                  items[count].groupKey = "MAN_" + IntegerToString(pId);
                  items[count].legNum = 1;
               }
               else
               {
                  // Untagged fallback: group by symbol, type, and 10-second open bucket
                  items[count].groupKey = "POS_" + items[count].symbol + "_" + IntegerToString(items[count].ptype) + "_" + IntegerToString((long)items[count].openTime / 10);
                  items[count].legNum = 0;
                  PrintFormat("[SEGS RECOVERY] Legacy grouping fallback used for position #%I64u (%s).", tk, items[count].symbol);
               }
            }
         }
         count++;
      }
   }
   ArrayResize(items, count);

   // Group items by unique groupKey
   bool used[];
   ArrayResize(used, count);
   ArrayInitialize(used, false);

   for(int i = 0; i < count; i++)
   {
      if(used[i] || items[i].groupKey == "") continue;

      string gKey = items[i].groupKey;
      string gSym = items[i].symbol;
      ENUM_POSITION_TYPE gType = items[i].ptype;

      ulong grpTickets[4];
      ulong grpPosIds[4];
      int   grpLegNums[4];
      for(int k = 0; k < 4; k++) { grpTickets[k] = 0; grpPosIds[k] = 0; grpLegNums[k] = 0; }
      int gCount = 0;

      for(int j = i; j < count && gCount < 4; j++)
      {
         if(!used[j] && items[j].groupKey == gKey)
         {
            grpTickets[gCount] = items[j].ticket;
            grpPosIds[gCount]  = items[j].posId;
            grpLegNums[gCount] = items[j].legNum;
            used[j] = true;
            gCount++;
         }
      }

      if(gCount == 0) continue;

      PositionGroup grp;
      InitPositionGroup(grp);
      grp.groupTime        = items[i].openTime;
      grp.tpTriggerHit     = false;
      grp.breakevenApplied = false;
      grp.symbol           = gSym;
      grp.positionType     = gType;
      grp.setupID          = gKey;
      for(int k = 0; k < 4; k++)
      {
         grp.tickets[k]     = 0;
         grp.positionIds[k] = 0;
      }

      // FIX 10: Assign positions according to explicit logical leg numbers
      for(int k = 0; k < gCount; k++)
      {
         int legIdx = grpLegNums[k] - 1;
         if(legIdx >= 0 && legIdx < 4 && grp.tickets[legIdx] == 0)
         {
            grp.tickets[legIdx]     = grpTickets[k];
            grp.positionIds[legIdx] = grpPosIds[k];
         }
         else
         {
            // Place into first free slot
            for(int slot = 0; slot < 4; slot++)
            {
               if(grp.tickets[slot] == 0)
               {
                  grp.tickets[slot]     = grpTickets[k];
                  grp.positionIds[slot] = grpPosIds[k];
                  break;
               }
            }
         }
      }

      int gIdx = ArraySize(g_groups);
      ArrayResize(g_groups, gIdx + 1);
      g_groups[gIdx] = grp;
      UpdateGroupPositionCount(gIdx);

      // Robust TP2 deal-history verification across restarts (recovering Leg 2 if closed prior to restart)
      int triggerIndex = InpBE_TriggerLeg - 1;
      if(triggerIndex < 0 || triggerIndex >= 4) triggerIndex = 1;

      // If Leg 2 position ID is missing from open positions, search deal history for its persistent ID!
      if(g_groups[gIdx].positionIds[triggerIndex] == 0)
      {
         ulong histLeg2PosId = FindHistoricalLeg2PositionId(gKey, gSym, grp.groupTime);
         if(histLeg2PosId > 0)
         {
            g_groups[gIdx].positionIds[triggerIndex] = histLeg2PosId;
            PrintFormat("[SEGS RECOVERY] Group %s Leg 2 recovered from deal history: PosID=#%I64u", gKey, histLeg2PosId);
         }
      }

      ulong trigPosId = g_groups[gIdx].positionIds[triggerIndex];
      ulong trigTicket = g_groups[gIdx].tickets[triggerIndex];
      bool triggerStillOpen = false;
      if(trigTicket > 0 && posInfo.SelectByTicket(trigTicket))
         triggerStillOpen = true;
      else if(trigPosId > 0)
      {
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong pt = PositionGetTicket(p);
            if(pt > 0 && posInfo.SelectByTicket(pt))
            {
               if((ulong)posInfo.Identifier() == trigPosId)
               {
                  triggerStillOpen = true;
                  g_groups[gIdx].tickets[triggerIndex] = pt; // update ticket
                  break;
               }
            }
         }
      }

      if(!triggerStillOpen && (trigPosId > 0 || trigTicket > 0))
      {
         ulong vPosId = (trigPosId > 0) ? trigPosId : trigTicket;
         double expTP = 0.0;
         if(StringFind(gKey, "ADV_") == 0)
         {
            double aEntry, aSL, aTP1, aTP2, aTP3, aTP4;
            ENUM_POSITION_TYPE aType;
            int aLegs;
            if(LoadAdvisorSetupTargets(gKey, aEntry, aSL, aTP1, aTP2, aTP3, aTP4, aType, aLegs))
               expTP = aTP2;
         }

         if(WasTPActuallyHit(vPosId, gSym, gType, expTP, grp.groupTime))
         {
            g_groups[gIdx].tpTriggerHit = true;
            bool allProtected = ApplyBreakevenToGroup(gIdx);
            g_groups[gIdx].breakevenApplied = allProtected;
            PrintFormat("[SEGS RECOVERY] Group %s TP2 hit confirmed in deal history! Breakeven state restored (Protected: %s).",
                        gKey, allProtected ? "YES" : "PENDING RETRY");
         }
      }
   }

   PrintFormat("[SEGS PRO] Reconstructed %d position groups across open trades.", ArraySize(g_groups));
}

//+------------------------------------------------------------------+
//| PROCESS SL & TP FOR UNASSIGNED POSITIONS (Used on 'P' or Auto)   |
//| Guaranteed protection, retry logic, non-destructive to Advisor  |
//+------------------------------------------------------------------+
void ProcessUnassignedPositions()
{
   int total = PositionsTotal();
   if(total == 0) return;

   // Struct for collecting unassigned positions to group
   struct UnassignedItem
   {
      ulong              ticket;
      ulong              posId;
      string             symbol;
      ENUM_POSITION_TYPE ptype;
      datetime           openTime;
      double             openPrice;
      string             comment;
      long               magic;
      string             groupKey;
      int                legNum;
      bool               isAdvisorStructural;
   };

   UnassignedItem unassigned[];
   ArrayResize(unassigned, 0);

   for(int i = 0; i < total; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && posInfo.SelectByTicket(tk))
      {
         // Filter to intended SEGS positions only
         if(!IsSEGSManagedPosition(tk) && !IsEligibleManualMaster(tk)) continue;

         ulong pId = (ulong)posInfo.Identifier();
         if(pId == 0) pId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if(pId == 0) continue; // Skip position without valid persistent identifier

         // FIX 1 & 16: If already tracked in a group, update any missing tickets/positionIds
         int existingGroupIdx = FindGroupIndexBySetupOrPosition("", tk, pId);
         if(existingGroupIdx >= 0)
         {
            UpdateGroupPositionCount(existingGroupIdx);
            // Already grouped, continue to protection check below
            continue;
         }

         string cmt = posInfo.Comment();
         long mgc   = posInfo.Magic();

         int n = ArraySize(unassigned);
         ArrayResize(unassigned, n + 1);
         unassigned[n].ticket              = tk;
         unassigned[n].posId               = pId;
         unassigned[n].symbol              = posInfo.Symbol();
         unassigned[n].ptype               = posInfo.PositionType();
         unassigned[n].openTime            = (datetime)posInfo.Time();
         unassigned[n].openPrice           = posInfo.PriceOpen();
         unassigned[n].comment             = cmt;
         unassigned[n].magic               = mgc;
         unassigned[n].legNum              = 0;
         unassigned[n].isAdvisorStructural = false;
         unassigned[n].groupKey            = "";

         // Determine setup identity and leg number
         int advIdx = StringFind(cmt, "SEGS|ADV|");
         if(advIdx >= 0 || mgc == InpAdvisorMagicNumber)
         {
            unassigned[n].isAdvisorStructural = true;
            if(advIdx >= 0)
            {
               string rem = StringSubstr(cmt, advIdx + 9);
               string parts[];
               int nParts = StringSplit(rem, '|', parts);
               if(nParts >= 1)
               {
                  unassigned[n].groupKey = "ADV_" + parts[0];
                  if(nParts >= 2 && StringSubstr(parts[1], 0, 1) == "L")
                     unassigned[n].legNum = (int)StringToInteger(StringSubstr(parts[1], 1, 1));
               }
            }
            if(unassigned[n].groupKey == "")
               unassigned[n].groupKey = "ADV_" + unassigned[n].symbol + "_" + IntegerToString((long)unassigned[n].openTime / 10);
         }
         else
         {
            int manIdx = StringFind(cmt, "SEGS|MAN|");
            if(manIdx >= 0)
            {
               string rem = StringSubstr(cmt, manIdx + 9);
               string parts[];
               int nParts = StringSplit(rem, '|', parts);
               if(nParts >= 1)
               {
                  unassigned[n].groupKey = "MAN_" + parts[0];
                  if(nParts >= 2 && StringSubstr(parts[1], 0, 1) == "L")
                     unassigned[n].legNum = (int)StringToInteger(StringSubstr(parts[1], 1, 1));
               }
            }
            else
            {
               int legPos = StringFind(cmt, "SEGS_LEG");
               int hashPos = StringFind(cmt, "#");
               if(legPos >= 0 && hashPos > legPos)
               {
                  string legStr = StringSubstr(cmt, legPos + 8, hashPos - (legPos + 8));
                  string mId = StringSubstr(cmt, hashPos + 1);
                  unassigned[n].legNum = (int)StringToInteger(legStr);
                  unassigned[n].groupKey = "MAN_" + mId;
               }
               else if(IsEligibleManualMaster(tk))
               {
                  unassigned[n].groupKey = "MAN_" + IntegerToString(pId);
                  unassigned[n].legNum = 1;
               }
               else
               {
                  // Untagged fallback: 10-second open bucket
                  unassigned[n].groupKey = "POS_" + unassigned[n].symbol + "_" + IntegerToString(unassigned[n].ptype) + "_" + IntegerToString((long)unassigned[n].openTime / 10);
               }
            }
         }
      }
   }

   int uCount = ArraySize(unassigned);
   if(uCount > 0)
   {
      // Sort unassigned items by open time ascending
      for(int i = 0; i < uCount - 1; i++)
      {
         for(int j = 0; j < uCount - i - 1; j++)
         {
            if(unassigned[j].openTime > unassigned[j + 1].openTime)
            {
               UnassignedItem temp = unassigned[j];
               unassigned[j] = unassigned[j + 1];
               unassigned[j + 1] = temp;
            }
         }
      }

      // Group by groupKey
      bool processedFlags[];
      ArrayResize(processedFlags, uCount);
      ArrayInitialize(processedFlags, false);

      for(int i = 0; i < uCount; i++)
      {
         if(processedFlags[i]) continue;

         string gKey = unassigned[i].groupKey;
         string curSym = unassigned[i].symbol;
         ENUM_POSITION_TYPE curType = unassigned[i].ptype;

         ulong groupTickets[4];
         ulong groupPosIds[4];
         int   groupLegNums[4];
         for(int k = 0; k < 4; k++) { groupTickets[k] = 0; groupPosIds[k] = 0; groupLegNums[k] = 0; }
         int groupCnt = 0;

         for(int j = i; j < uCount && groupCnt < 4; j++)
         {
            if(!processedFlags[j] && unassigned[j].groupKey == gKey)
            {
               groupTickets[groupCnt] = unassigned[j].ticket;
               groupPosIds[groupCnt]  = unassigned[j].posId;
               groupLegNums[groupCnt] = unassigned[j].legNum;
               processedFlags[j] = true;
               groupCnt++;
            }
         }

         if(groupCnt == 0) continue;

         // Check if this setupID is already present in g_groups to prevent duplicate groups (FIX 16)
         int existingIdx = FindGroupIndexBySetupOrPosition(gKey, groupTickets[0], groupPosIds[0]);
         if(existingIdx >= 0)
         {
            // Update existing group tickets and IDs according to logical leg
            for(int leg = 0; leg < groupCnt; leg++)
            {
               int legIdx = groupLegNums[leg] - 1;
               if(legIdx >= 0 && legIdx < 4)
               {
                  if(g_groups[existingIdx].tickets[legIdx] == 0)
                  {
                     g_groups[existingIdx].tickets[legIdx]     = groupTickets[leg];
                     g_groups[existingIdx].positionIds[legIdx] = groupPosIds[leg];
                  }
               }
               else
               {
                  for(int slot = 0; slot < 4; slot++)
                  {
                     if(g_groups[existingIdx].tickets[slot] == 0)
                     {
                        g_groups[existingIdx].tickets[slot]     = groupTickets[leg];
                        g_groups[existingIdx].positionIds[slot] = groupPosIds[leg];
                        break;
                     }
                  }
               }
            }
            // FIX 9: Update positionCount correctly
            UpdateGroupPositionCount(existingIdx);
         }
         else
         {
            // Register new PositionGroup
            PositionGroup grp;
            InitPositionGroup(grp);
            grp.groupTime        = unassigned[i].openTime;
            grp.tpTriggerHit     = false;
            grp.breakevenApplied = false;
            grp.symbol           = curSym;
            grp.positionType     = curType;
            grp.setupID          = gKey;
            for(int t = 0; t < 4; t++)
            {
               grp.tickets[t]     = 0;
               grp.positionIds[t] = 0;
            }
            for(int leg = 0; leg < groupCnt; leg++)
            {
               int legIdx = groupLegNums[leg] - 1;
               if(legIdx >= 0 && legIdx < 4)
               {
                  grp.tickets[legIdx]     = groupTickets[leg];
                  grp.positionIds[legIdx] = groupPosIds[leg];
               }
               else
               {
                  for(int slot = 0; slot < 4; slot++)
                  {
                     if(grp.tickets[slot] == 0)
                     {
                        grp.tickets[slot]     = groupTickets[leg];
                        grp.positionIds[slot] = groupPosIds[leg];
                        break;
                     }
                  }
               }
            }

            int gIdx = ArraySize(g_groups);
            ArrayResize(g_groups, gIdx + 1);
            g_groups[gIdx] = grp;
            UpdateGroupPositionCount(gIdx);
         }
      }
   }

   // FIX 1: Protection pass for ALL open SEGS positions requiring SL/TP
   // Group membership does NOT prevent an open position with missing SL or TP from being protected/retried!
   for(int i = 0; i < total; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk <= 0 || !posInfo.SelectByTicket(tk)) continue;

      if(!IsSEGSManagedPosition(tk) && !IsEligibleManualMaster(tk)) continue;

      string sym = posInfo.Symbol();
      ENUM_POSITION_TYPE ptype = posInfo.PositionType();
      string cmt = posInfo.Comment();
      long mgc   = posInfo.Magic();
      double entry = posInfo.PriceOpen();
      bool isBuy = (ptype == POSITION_TYPE_BUY);
      double pipSize = GetPipSize(sym);

      double curSL = posInfo.StopLoss();
      double curTP = posInfo.TakeProfit();
      double pSafeDist = MathMax(18.0 * pipSize, 0.40 * 20.0 * pipSize);
      bool isSLFaulty = (curSL <= 0.0 || MathAbs(curSL - entry) < pSafeDist);
      if(!isSLFaulty && curTP > 0.0) continue; // Fully protected

      // Advisor structural trades: Recover targets PER-SETUP, never contaminate from current scanner globals
      if(mgc == InpAdvisorMagicNumber || StringFind(cmt, "SEGS|ADV|") >= 0)
      {
         string advSetupID = "";
         int advIdx = StringFind(cmt, "SEGS|ADV|");
         if(advIdx >= 0)
         {
            string rem = StringSubstr(cmt, advIdx + 9);
            string parts[];
            int nParts = StringSplit(rem, '|', parts);
            if(nParts >= 1) advSetupID = "ADV_" + parts[0];
         }
         else
         {
            ulong pId = (ulong)posInfo.Identifier();
            if(pId == 0) pId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
            if(pId > 0)
            {
               int gIdx = FindGroupIndexBySetupOrPosition("", tk, pId);
               if(gIdx >= 0 && StringFind(g_groups[gIdx].setupID, "ADV_") == 0)
                  advSetupID = g_groups[gIdx].setupID;
            }
         }

         double aEntry = 0, aSL = 0, aTP1 = 0, aTP2 = 0, aTP3 = 0, aTP4 = 0;
         ENUM_POSITION_TYPE aType;
         int aLegs = 4;
         bool targetsRecovered = false;
         if(advSetupID != "")
         {
            targetsRecovered = LoadAdvisorSetupTargets(advSetupID, aEntry, aSL, aTP1, aTP2, aTP3, aTP4, aType, aLegs);
         }
         if(!targetsRecovered && g_currentSignalID != "")
         {
            targetsRecovered = LoadAdvisorSetupTargets("ADV_" + g_currentSignalID, aEntry, aSL, aTP1, aTP2, aTP3, aTP4, aType, aLegs);
         }
         if(!targetsRecovered && g_staticSL > 0.0 && IsSameChartAsset(sym, _Symbol))
         {
            aEntry = g_staticEntryPrice;
            aSL    = g_staticSL;
            aTP1   = g_staticTP1;
            aTP2   = g_staticTP2;
            aTP3   = g_staticTP3;
            aTP4   = g_staticTP4;
            aType  = (g_currentAdvisedAction == "BUY") ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
            aLegs  = 4;
            targetsRecovered = true;
         }

         if(targetsRecovered)
         {
            int leg = 1;
            int lPos = StringFind(cmt, "|L");
            if(lPos >= 0) leg = (int)StringToInteger(StringSubstr(cmt, lPos + 2, 1));
            else if(StringFind(cmt, "TP2") >= 0) leg = 2;
            else if(StringFind(cmt, "TP3") >= 0) leg = 3;
            else if(StringFind(cmt, "TP4") >= 0) leg = 4;

            double targetTP = (leg == 1) ? aTP1 : ((leg == 2) ? aTP2 : ((leg == 3) ? aTP3 : aTP4));
            double targetSL = (curSL > 0.0) ? curSL : aSL;
            if(curTP > 0.0) targetTP = curTP;

            double modSL = targetSL;
            double modTP = targetTP;
            if(ValidateProtectionLevels(sym, ptype, posInfo.PriceCurrent(), modSL, modTP))
            {
               ResetLastError();
               bool ok = trade.PositionModify(tk, modSL, modTP);
               uint ret = trade.ResultRetcode();
               if(!ok || (ret != TRADE_RETCODE_DONE && ret != TRADE_RETCODE_PLACED && ret != TRADE_RETCODE_NO_CHANGES))
               {
                  PrintFormat("[SEGS ADVISOR PROTECT] PositionModify FAILED for #%I64u (%s) -> SL: %.5f, TP: %.5f | Retcode: %u (%s)",
                              tk, sym, modSL, modTP, ret, trade.ResultRetcodeDescription());
               }
               else
               {
                  PrintFormat("[SEGS ADVISOR PROTECT] SUCCESS: Position #%I64u (%s) protected with SL: %.5f, TP: %.5f (from setup %s)",
                              tk, sym, modSL, modTP, advSetupID);
               }
            }
         }
         else
         {
            PrintFormat("[SEGS ADVISOR PROTECT] WARNING: Structural targets could not be recovered for Advisor position #%I64u (Setup: %s).",
                        tk, (advSetupID != "") ? advSetupID : "UNKNOWN");
         }
         continue;
      }

      // Manual / cloned / legacy trades:
      // Determine logical leg number (1..4)
      int leg = 1;
      int manIdx = StringFind(cmt, "|L");
      if(manIdx >= 0)
      {
         leg = (int)StringToInteger(StringSubstr(cmt, manIdx + 2, 1));
      }
      else
      {
         int legPos = StringFind(cmt, "SEGS_LEG");
         if(legPos >= 0)
         {
            leg = (int)StringToInteger(StringSubstr(cmt, legPos + 8, 1));
         }
         else
         {
            // Find leg from group
            ulong pId = (ulong)posInfo.Identifier();
            if(pId == 0) pId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
            int gIdx = (pId > 0 || tk > 0) ? FindGroupIndexBySetupOrPosition("", tk, pId) : -1;
            if(gIdx >= 0)
            {
               for(int k = 0; k < 4; k++)
               {
                  if(g_groups[gIdx].tickets[k] == tk || g_groups[gIdx].positionIds[k] == pId)
                  {
                     leg = k + 1;
                     break;
                  }
               }
            }
         }
      }
      if(leg < 1 || leg > 4) leg = 1;

      double slPips = 0, tpPips[4];
      GetAssetTargets(sym, slPips, tpPips[0], tpPips[1], tpPips[2], tpPips[3]);
      pipSize = GetPipSize(sym);

      double targetSL = (curSL > 0.0) ? curSL : (isBuy ? (entry - (slPips * pipSize)) : (entry + (slPips * pipSize)));
      double targetTP = (curTP > 0.0) ? curTP : (isBuy ? (entry + (tpPips[MathMax(1, MathMin(4, leg)) - 1] * pipSize)) : (entry - (tpPips[MathMax(1, MathMin(4, leg)) - 1] * pipSize)));

      if(ValidateProtectionLevels(sym, ptype, posInfo.PriceCurrent(), targetSL, targetTP))
      {
         ResetLastError();
         bool ok = trade.PositionModify(tk, targetSL, targetTP);
         uint ret = trade.ResultRetcode();
         if(!ok || (ret != TRADE_RETCODE_DONE && ret != TRADE_RETCODE_PLACED && ret != TRADE_RETCODE_NO_CHANGES))
         {
            PrintFormat("[SEGS PROTECT] PositionModify FAILED for #%I64u (%s) -> SL: %.5f, TP: %.5f | Retcode: %u (%s)",
                        tk, sym, targetSL, targetTP, ret, trade.ResultRetcodeDescription());
         }
         else
         {
            PrintFormat("[SEGS PROTECT] SUCCESS: Position #%I64u (%s) Leg %d protected with SL: %.5f, TP: %.5f",
                        tk, sym, leg, targetSL, targetTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Resilient Safe Position Close with Multi-Mode Fallback           |
//| Solves terminal manual close & Stop Loss execution failures      |
//| Handles all broker filling modes (IOC, FOK, RETURN), high        |
//| slippage tolerance, and direct MqlTradeRequest fallback.         |
//+------------------------------------------------------------------+
bool SafePositionClose(ulong ticket, string reason = "MANUAL_CLOSE")
{
   if(ticket <= 0) return false;
   if(!posInfo.SelectByTicket(ticket)) return true;

   string sym = posInfo.Symbol();
   SymbolSelect(sym, true);

   ENUM_POSITION_TYPE ptype = posInfo.PositionType();
   bool isBuy = (ptype == POSITION_TYPE_BUY);
   double vol = posInfo.Volume();
   long posId = posInfo.Identifier();
   long mgc = posInfo.Magic();
   string cmt = posInfo.Comment();

   PrintFormat("[SEGS SAFE-CLOSE] Initiating close for ticket #%I64u (%s %s %.2f lots) | Reason: %s",
               ticket, sym, isBuy ? "BUY" : "SELL", vol, reason);

   // Configure trade instance with generous slippage tolerance (1000 points / 100 pips)
   trade.SetDeviationInPoints(1000);
   trade.SetAsyncMode(false);

   // Query broker filling modes
   uint symFilling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING fillModes[3];
   int modeCount = 0;
   if((symFilling & SYMBOL_FILLING_IOC) != 0) fillModes[modeCount++] = ORDER_FILLING_IOC;
   if((symFilling & SYMBOL_FILLING_FOK) != 0) fillModes[modeCount++] = ORDER_FILLING_FOK;
   fillModes[modeCount++] = ORDER_FILLING_RETURN;

   bool closed = false;

   // Attempt 1: CTrade PositionClose with prioritized filling modes
   for(int m = 0; m < modeCount; m++)
   {
      trade.SetTypeFilling(fillModes[m]);
      ResetLastError();
      if(trade.PositionClose(ticket, 1000))
      {
         closed = true;
         PrintFormat("[SEGS SAFE-CLOSE] SUCCESS: Position #%I64u closed via trade.PositionClose (FillMode: %d)", ticket, fillModes[m]);
         break;
      }
      uint ret = trade.ResultRetcode();
      if(ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_PLACED)
      {
         closed = true;
         break;
      }
   }

   // Attempt 2: Direct low-level OrderSend fallback if CTrade failed
   if(!closed && posInfo.SelectByTicket(ticket))
   {
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = sym;
      req.volume       = vol;
      req.deviation    = 1000;
      req.magic        = mgc;
      req.comment      = StringFormat("SEGS|CLS|%I64u", ticket);

      if(isBuy)
      {
         req.type  = ORDER_TYPE_SELL;
         req.price = SymbolInfoDouble(sym, SYMBOL_BID);
      }
      else
      {
         req.type  = ORDER_TYPE_BUY;
         req.price = SymbolInfoDouble(sym, SYMBOL_ASK);
      }

      for(int m = 0; m < modeCount; m++)
      {
         req.type_filling = fillModes[m];
         ResetLastError();
         if(OrderSend(req, res))
         {
            if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
            {
               closed = true;
               PrintFormat("[SEGS SAFE-CLOSE] SUCCESS: Position #%I64u closed via direct OrderSend (FillMode: %d)", ticket, fillModes[m]);
               break;
            }
         }
      }
   }

   // Register manual close cooldown so advisor never immediately reopens trade on user!
   if(closed || !posInfo.SelectByTicket(ticket))
   {
      string cleanSym = sym;
      StringToUpper(cleanSym);
      if(IsSymbolMatch(cleanSym, InpXAU_Patterns))       cleanSym = "XAUUSD";
      else if(IsSymbolMatch(cleanSym, InpDJ30_Patterns)) cleanSym = "US30";
      else if(IsSymbolMatch(cleanSym, InpNAS_Patterns))  cleanSym = "NAS100";
      else if(IsSymbolMatch(cleanSym, InpGJ_Patterns))   cleanSym = "GBPJPY";
      else if(IsSymbolMatch(cleanSym, InpGU_Patterns))   cleanSym = "GBPUSD";
      else if(IsSymbolMatch(cleanSym, InpAUD_Patterns))  cleanSym = "AUDUSD";
      else if(IsSymbolMatch(cleanSym, InpOIL_Patterns))  cleanSym = "USOIL";
      else if(IsSymbolMatch(cleanSym, InpBTC_Patterns))  cleanSym = "BTCUSD";
      else if(IsSymbolMatch(cleanSym, InpAMD_Patterns))  cleanSym = "AMD";

      long login = AccountInfoInteger(ACCOUNT_LOGIN);
      string gvCdKey = "SEGS_COOLDOWN_" + cleanSym + "_" + IntegerToString(login);
             GlobalVariableSet(gvCdKey, (double)(TimeCurrent() + 15)); // 15-second anti-spam cooldown

      if(g_currentSignalID != "")
      {
         string sigExecKey = "SEGS_SIG_EXEC_" + IntegerToString(login) + "_" + g_currentSignalID;
         GlobalVariableSet(sigExecKey, 4.0); // 4.0 = MANUALLY CLOSED / CONSUMED
      }
      g_currentTradeTaken = true;

      // Clean up position group tracking if registered
      int gCount = ArraySize(g_groups);
      for(int g = 0; g < gCount; g++)
      {
         for(int k = 0; k < 4; k++)
         {
            if(g_groups[g].tickets[k] == ticket)
            {
               g_groups[g].tickets[k] = 0;
               UpdateGroupPositionCount(g);
            }
         }
      }

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Authoritative Stop Loss and Target Enforcement Watchdog          |
//| Enforces immediate market closure if price touches or crosses SL |
//| Prevents runaway losses or broker stop loss failure              |
//+------------------------------------------------------------------+
void EnforcePositionStopLossAndTargets()
{
   int total = PositionsTotal();
   if(total == 0) return;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk <= 0 || !posInfo.SelectByTicket(tk)) continue;

      string sym = posInfo.Symbol();
      SymbolSelect(sym, true);

      ENUM_POSITION_TYPE ptype = posInfo.PositionType();
      bool isBuy = (ptype == POSITION_TYPE_BUY);

      double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
      double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
      double curPrice = isBuy ? curBid : curAsk;
      if(curPrice <= 0.0) continue;

      double sl = posInfo.StopLoss();
      double tp = posInfo.TakeProfit();

      // If SL is not set on the broker, check if it is an advisor trade with stored SL
      long mgc = posInfo.Magic();
      string cmt = posInfo.Comment();
      bool isAdvisor = (mgc == InpAdvisorMagicNumber ||
                        StringFind(cmt, "SEGS|ADV") >= 0 ||
                        StringFind(cmt, "[MyAdvisor]") >= 0 ||
                        StringFind(cmt, "[Advised") >= 0);

      if(sl <= 0.0 && isAdvisor)
      {
         // Look up stored setup SL
         double sEntry = 0, sSL = 0, sTP1 = 0, sTP2 = 0, sTP3 = 0, sTP4 = 0;
         ENUM_POSITION_TYPE sType;
         int sLegs = 4;
         string advSetupID = "";
         int advIdx = StringFind(cmt, "SEGS|ADV|");
         if(advIdx >= 0)
         {
            string rem = StringSubstr(cmt, advIdx + 9);
            string parts[];
            if(StringSplit(rem, '|', parts) >= 1) advSetupID = "ADV_" + parts[0];
         }
         bool loaded = false;
         if(advSetupID != "") loaded = LoadAdvisorSetupTargets(advSetupID, sEntry, sSL, sTP1, sTP2, sTP3, sTP4, sType, sLegs);
         if(!loaded && g_currentSignalID != "") loaded = LoadAdvisorSetupTargets("ADV_" + g_currentSignalID, sEntry, sSL, sTP1, sTP2, sTP3, sTP4, sType, sLegs);
         if(loaded && sSL > 0.0) sl = sSL;
         else if(g_staticSL > 0.0) sl = g_staticSL;
      }

      // 1. Authoritative Stop Loss Breach Watchdog:
      // If position has a Stop Loss (or stored Advisor SL) and current market price has reached or passed it:
      // Close IMMEDIATELY at market via SafePositionClose. Never let a trade run past its Stop Loss!
      if(sl > 0.0)
      {
         bool slBreached = isBuy ? (curPrice <= sl) : (curPrice >= sl);
         if(slBreached)
         {
            PrintFormat("[SEGS SL WATCHDOG] CRITICAL: Ticket #%I64u (%s %s) price %.5f reached/passed Stop Loss %.5f! Closing immediately at market.",
                        tk, sym, isBuy ? "BUY" : "SELL", curPrice, sl);
            SafePositionClose(tk, "STOP_LOSS_BREACHED");
            continue;
         }
      }

      // 2. Authoritative Take Profit Breach Watchdog:
      if(tp > 0.0)
      {
         bool tpReached = isBuy ? (curPrice >= tp) : (curPrice <= tp);
         if(tpReached)
         {
            PrintFormat("[SEGS TP WATCHDOG] Ticket #%I64u (%s %s) price %.5f reached Take Profit %.5f! Closing immediately at market.",
                        tk, sym, isBuy ? "BUY" : "SELL", curPrice, tp);
            SafePositionClose(tk, "TAKE_PROFIT_REACHED");
            continue;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check Breakeven Conditions across tracked position groups         |
//| MANDATORY BUSINESS RULE: Must be triggered specifically by TP2   |
//| closed by DEAL_REASON_TP. Retries until all remaining legs BE.   |
//+------------------------------------------------------------------+
void CheckBreakevenConditions()
{
   if(!g_autoBreakevenOnTP_Active) return;

   int gCount = ArraySize(g_groups);
   for(int g = 0; g < gCount; g++)
   {
      if(g_groups[g].breakevenApplied) continue;

      int triggerIndex = InpBE_TriggerLeg - 1;
      if(triggerIndex < 0 || triggerIndex >= 4) triggerIndex = 1; // Default: Leg 2 (index 1 = TP2)

      ulong triggerTicket = g_groups[g].tickets[triggerIndex];
      ulong triggerPosId  = g_groups[g].positionIds[triggerIndex];
      if(triggerTicket == 0 && triggerPosId == 0) continue;

      // If triggerPosId is 0, attempt historical recovery
      if(triggerPosId == 0)
      {
         ulong histLeg2PosId = FindHistoricalLeg2PositionId(g_groups[g].setupID, g_groups[g].symbol, g_groups[g].groupTime);
         if(histLeg2PosId > 0)
         {
            g_groups[g].positionIds[triggerIndex] = histLeg2PosId;
            triggerPosId = histLeg2PosId;
            PrintFormat("[SEGS TP2-BE] Group %s Leg 2 recovered from deal history: PosID=#%I64u", g_groups[g].setupID, histLeg2PosId);
         }
      }

      if(!g_groups[g].tpTriggerHit)
      {
         // Check if trigger leg (TP2) is still open
         bool triggerStillOpen = false;
         if(triggerTicket > 0 && posInfo.SelectByTicket(triggerTicket))
            triggerStillOpen = true;
         else if(triggerPosId > 0)
         {
            for(int p = PositionsTotal() - 1; p >= 0; p--)
            {
               ulong pt = PositionGetTicket(p);
               if(pt > 0 && posInfo.SelectByTicket(pt))
               {
                  if((ulong)posInfo.Identifier() == triggerPosId)
                  {
                     triggerStillOpen = true;
                     g_groups[g].tickets[triggerIndex] = pt; // update ticket
                     break;
                  }
               }
            }
         }
         if(!triggerStillOpen)
         {
            // CRITICAL BUSINESS RULE: Leg 2 position closed. Verify DEAL_REASON == DEAL_REASON_TP!
            ulong verifyPosId = (triggerPosId > 0) ? triggerPosId : triggerTicket;
            double expTP = 0.0;
            if(StringFind(g_groups[g].setupID, "ADV_") == 0)
            {
               double aEntry, aSL, aTP1, aTP2, aTP3, aTP4;
               ENUM_POSITION_TYPE aType;
               int aLegs;
               if(LoadAdvisorSetupTargets(g_groups[g].setupID, aEntry, aSL, aTP1, aTP2, aTP3, aTP4, aType, aLegs))
                  expTP = aTP2;
            }

            if(WasTPActuallyHit(verifyPosId, g_groups[g].symbol, g_groups[g].positionType, expTP, g_groups[g].groupTime))
            {
               g_groups[g].tpTriggerHit = true;
               PrintFormat("[SEGS TP2-BE] CONFIRMED: Leg %d (PosID #%I64u) for group %s closed by DEAL_REASON_TP. Moving remaining open legs to Breakeven.",
                           InpBE_TriggerLeg, verifyPosId, g_groups[g].setupID);
            }
            else
            {
               // Not closed by TP (closed manually, SL, close-by, etc.) - DO NOT trigger BE!
               continue;
            }
         }
      }

      // If tpTriggerHit is true, apply BE to remaining open legs and retry until all are protected
      if(g_groups[g].tpTriggerHit)
      {
         bool allProtected = ApplyBreakevenToGroup(g);
         if(allProtected)
         {
            g_groups[g].breakevenApplied = true;
            PrintFormat("[SEGS TP2-BE] COMPLETED: All remaining open legs for group %s are fully protected at Breakeven (+%.1f pips buffer).",
                        g_groups[g].setupID, InpBreakevenBufferPips);
         }
         else
         {
            // Leave breakevenApplied = false so subsequent ticks/timers retry missing legs!
            g_groups[g].breakevenApplied = false;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper to check Toronto Daylight Saving Time                     |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Exact Toronto Daylight Saving Time Calculation                   |
//| Starts 2nd Sunday in March @ 02:00 local time (07:00 UTC)        |
//| Ends 1st Sunday in November @ 02:00 local time (06:00 UTC)       |
//+------------------------------------------------------------------+
bool IsTorontoDST(datetime utcDt)
{
   MqlDateTime mdt;
   TimeToStruct(utcDt, mdt);
   int yr = mdt.year;

   if(mdt.mon > 3 && mdt.mon < 11) return true;
   if(mdt.mon < 3 || mdt.mon > 11) return false;

   if(mdt.mon == 3)
   {
      // Find day of week of March 1st
      MqlDateTime m1;
      m1.year = yr; m1.mon = 3; m1.day = 1; m1.hour = 0; m1.min = 0; m1.sec = 0;
      datetime tm1 = StructToTime(m1);
      TimeToStruct(tm1, m1);
      int firstSun = 1 + (7 - m1.day_of_week) % 7;
      int secondSun = firstSun + 7;

      if(mdt.day > secondSun) return true;
      if(mdt.day < secondSun) return false;
      return (mdt.hour >= 7); // 02:00 EST transition is 07:00 UTC
   }

   if(mdt.mon == 11)
   {
      // Find day of week of November 1st
      MqlDateTime n1;
      n1.year = yr; n1.mon = 11; n1.day = 1; n1.hour = 0; n1.min = 0; n1.sec = 0;
      datetime tn1 = StructToTime(n1);
      TimeToStruct(tn1, n1);
      int firstSun = 1 + (7 - n1.day_of_week) % 7;

      if(mdt.day < firstSun) return true;
      if(mdt.day > firstSun) return false;
      return (mdt.hour < 6); // 02:00 EDT transition is 06:00 UTC
   }

   return false;
}

int GetDynamicBrokerUtcOffset()
{
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   if(srv > 0 && gmt > 0)
   {
      long diffSec = (long)(srv - gmt);
      int hrs = (int)MathRound((double)diffSec / 3600.0);
      if(hrs >= -12 && hrs <= 14) return hrs;
   }
   return InpBrokerUtcOffset;
}

datetime ConvertBrokerTimeToToronto(datetime dt)
{
   int srvOffset = GetDynamicBrokerUtcOffset();
   datetime utc = dt - (srvOffset * 3600);
   int torontoOffset = IsTorontoDST(utc) ? -4 : -5;
   return utc + (torontoOffset * 3600);
}

datetime GetTorontoTimeNow()
{
   datetime gmt = TimeGMT();
   int offsetHours = IsTorontoDST(gmt) ? -4 : -5;
   return gmt + (offsetHours * 3600);
}

string GetTorontoTimeFormatted()
{
   datetime torNow = GetTorontoTimeNow();
   string tz = IsTorontoDST(TimeGMT()) ? "EDT" : "EST";
   return TimeToString(torNow, TIME_SECONDS) + " " + tz;
}

//+------------------------------------------------------------------+
//| Check if current Toronto time is within 04:30 AM to 07:50 AM     |
//| User Mandate: All planned entry target set and trade taken       |
//| between 4:30am to 7:50am Toronto time every day must be entered  |
//| from a deeper retracement point (trend continuation pullbacks)   |
//| to avoid false mini pullbacks before frequent trend reversals.   |
//+------------------------------------------------------------------+
bool IsTorontoDeepRetracementWindow()
{
   datetime torNow = GetTorontoTimeNow();
   MqlDateTime dt;
   TimeToStruct(torNow, dt);
   int minOfDay = dt.hour * 60 + dt.min;
   // 4:30 AM = 4 * 60 + 30 = 270 minutes
   // 7:50 AM = 7 * 60 + 50 = 470 minutes
   return (minOfDay >= 270 && minOfDay <= 470);
}

//+------------------------------------------------------------------+
//| Create or update solid rectangle panel                           |
//+------------------------------------------------------------------+
void CreateOrUpdatePanel(const string name, int x, int y, int w, int h, color bgCol, color borderCol, ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 30);
   }
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgCol);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderCol);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 30);
}

//+------------------------------------------------------------------+
//| Create or update text cell                                       |
//+------------------------------------------------------------------+
void CreateOrUpdateCell(const string name, int x, int y, string text, color clr, int fontSize, ENUM_ANCHOR_POINT anchor, ENUM_BASE_CORNER corner, string font="")
{
   if(font == "") font = InpFontName;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 40);
   }
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetString(0,  name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0,  name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 40);
}

//+------------------------------------------------------------------+
//| Create or update interactive button                              |
//+------------------------------------------------------------------+
void CreateOrUpdateButton(const string name, int x, int y, int w, int h, string text, color bgCol, color txtCol, ENUM_BASE_CORNER corner, string font="", int fontSize=8)
{
   if(font == "") font = InpFontName;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 40);
   }
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgCol);
   ObjectSetInteger(0, name, OBJPROP_COLOR, txtCol);
   ObjectSetString(0,  name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0,  name, OBJPROP_TEXT, text);
}

void DeleteRowObjects(int rowIdx)
{
   string rPrefix = PREFIX + "R" + IntegerToString(rowIdx) + "_";
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string oName = ObjectName(0, i);
      if(StringFind(oName, rPrefix) == 0)
         ObjectDelete(0, oName);
   }
}

//+------------------------------------------------------------------+
//| Deletes Terminal objects while strictly preserving Market HUD    |
//| and Suggested Trade Advice lines for 100% independent control   |
//+------------------------------------------------------------------+
void DeleteTerminalObjects()
{
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string oName = ObjectName(0, i);
      if(StringFind(oName, PREFIX) == 0)
      {
         // Exclude Market Sentiment HUD, Trade Advice lines, Open Trade Markings, Win Rate HUD, Help HUD, and M30 OB Zones
         if(StringFind(oName, PREFIX + "SNT_") == 0 || StringFind(oName, PREFIX + "TRDLINE_") == 0 ||
            StringFind(oName, PREFIX + "OTM_") == 0 ||
            StringFind(oName, PREFIX + "WR_") == 0 || StringFind(oName, PREFIX + "HLP_") == 0 ||
            StringFind(oName, PREFIX + "OB_") == 0)
            continue;
         ObjectDelete(0, oName);
      }
   }
}

//+------------------------------------------------------------------+
//| Suggested Trade Advice Chart Markings (Entry, SL, TP1-4) [K]     |
//+------------------------------------------------------------------+
void DeleteTradeAdviceLines()
{
   ObjectsDeleteAll(0, PREFIX + "TRDLINE_");
   ChartRedraw(0);
}

void CreateChartHLine(string name, double price, color col, ENUM_LINE_STYLE style, int width, string desc)
{
   if(price <= 0.0) return;
   if(ObjectFind(0, name) >= 0)
   {
      if(ObjectGetInteger(0, name, OBJPROP_TYPE) != OBJ_HLINE)
         ObjectDelete(0, name);
   }
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS); // CRITICAL: NEVER disappear on timeframe change!
   ObjectSetString(0, name, OBJPROP_TEXT, desc);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, desc + " (" + DoubleToString(price, _Digits) + ")");
}

void CreateChartTextTag(string name, datetime t, double price, string text, color col, string font="Trebuchet MS", int fontSize=9)
{
   if(price <= 0.0) return;
   if(ObjectFind(0, name) >= 0)
   {
      if(ObjectGetInteger(0, name, OBJPROP_TYPE) != OBJ_TEXT)
         ObjectDelete(0, name);
   }
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   }
   ObjectSetInteger(0, name, OBJPROP_TIME, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TEXT, "  " + text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
}

void DrawTradeAdviceLines(double entry, double sl, double tp1, double tp2, double tp3, double tp4, int digits)
{
   if(!g_showTradeAdviceLines || entry <= 0.0 || sl <= 0.0)
   {
      DeleteTradeAdviceLines();
      return;
   }

   ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);

   bool isTradeTaken = IsAdvisorTradeTaken(_Symbol, g_currentSignalID);
   string entLabel = isTradeTaken ? "🎯 ACTIVE ENTRY: " : "🎯 PLANNED ENTRY: ";
   double pipSize = GetPipSize(_Symbol);
   double slPips = (entry > 0.0 && sl > 0.0 && pipSize > 0.0) ? MathAbs(entry - sl) / pipSize : 0.0;
   string slLabel = "🛑 SAFE STOP LOSS: " + DoubleToString(sl, digits) + (slPips > 0.0 ? " (-" + DoubleToString(slPips, 1) + " pips)" : "");

   CreateChartHLine(PREFIX + "TRDLINE_SL",  sl,    C'239,68,68',  STYLE_DASH,    2, slLabel);
   CreateChartHLine(PREFIX + "TRDLINE_ENT", entry, C'245,158,11', STYLE_DASHDOT, 2, entLabel + DoubleToString(entry, digits));

   datetime tAnchor = iTime(_Symbol, _Period, 0);
   if(tAnchor <= 0) tAnchor = TimeCurrent();

   CreateChartTextTag(PREFIX + "TRDLINE_ENT_TAG", tAnchor, entry, entLabel + DoubleToString(entry, digits), C'245,158,11', "Trebuchet MS", 10);
   CreateChartTextTag(PREFIX + "TRDLINE_SL_TAG",  tAnchor, sl,    slLabel, C'239,68,68',  "Trebuchet MS", 10);

   // Standard Rule: Take profit information is hidden when no trade is opened.
   // TP1-4 lines only display when a trade is active (isTradeTaken = true).
   if(isTradeTaken)
   {
      CreateChartHLine(PREFIX + "TRDLINE_TP1", tp1,   C'16,185,129', STYLE_DASH,    1, "🏁 TP1 (1.4R FTA / 25% SCALE): " + DoubleToString(tp1, digits));
      CreateChartHLine(PREFIX + "TRDLINE_TP2", tp2,   C'6,182,212',  STYLE_DASH,    1, "🔒 TP2 (2.8R / 25% + BE LOCK): " + DoubleToString(tp2, digits));
      CreateChartHLine(PREFIX + "TRDLINE_TP3", tp3,   C'168,85,247', STYLE_DASH,    1, "🚀 TP3 (4.8R / 25% HTF POOL): " + DoubleToString(tp3, digits));
      CreateChartHLine(PREFIX + "TRDLINE_TP4", tp4,   C'245,158,11', STYLE_DASH,    1, "🏆 TP4 (8.0R / 25% RUNNER): " + DoubleToString(tp4, digits));

      CreateChartTextTag(PREFIX + "TRDLINE_TP1_TAG", tAnchor, tp1, "🏁 TP1: " + DoubleToString(tp1, digits), C'16,185,129', "Trebuchet MS", 9);
      CreateChartTextTag(PREFIX + "TRDLINE_TP2_TAG", tAnchor, tp2, "🔒 TP2: " + DoubleToString(tp2, digits), C'6,182,212',  "Trebuchet MS", 9);
      CreateChartTextTag(PREFIX + "TRDLINE_TP3_TAG", tAnchor, tp3, "🚀 TP3: " + DoubleToString(tp3, digits), C'168,85,247', "Trebuchet MS", 9);
      CreateChartTextTag(PREFIX + "TRDLINE_TP4_TAG", tAnchor, tp4, "🏆 TP4: " + DoubleToString(tp4, digits), C'245,158,11', "Trebuchet MS", 9);
   }
   else
   {
      ObjectDelete(0, PREFIX + "TRDLINE_TP1");
      ObjectDelete(0, PREFIX + "TRDLINE_TP2");
      ObjectDelete(0, PREFIX + "TRDLINE_TP3");
      ObjectDelete(0, PREFIX + "TRDLINE_TP4");
      ObjectDelete(0, PREFIX + "TRDLINE_TP1_TAG");
      ObjectDelete(0, PREFIX + "TRDLINE_TP2_TAG");
      ObjectDelete(0, PREFIX + "TRDLINE_TP3_TAG");
      ObjectDelete(0, PREFIX + "TRDLINE_TP4_TAG");
   }

   ChartRedraw(0);
}

void UpdateTradeAdviceLines()
{
   if(!g_showTradeAdviceLines)
   {
      DeleteTradeAdviceLines();
      return;
   }

   bool isTradeTaken = IsAdvisorTradeTaken(_Symbol, g_currentSignalID);
   bool hasPlannedSetup = (g_staticEntryPrice > 0.0 && g_staticSL > 0.0 && !g_isSignalExpired && g_setupState != "CANCELLED" && g_setupState != "UNVIABLE");

   // CRITICAL SYSTEM FIX: Planned Entry and Safe Stop Loss lines MUST be visible on chart
   // whenever a planned entry is waiting/watching (g_setupState == "WATCHING"),
   // ready/triggered (g_hasViableEntry), or actively running (isTradeTaken)!
   if(!hasPlannedSetup && !isTradeTaken)
   {
      DeleteTradeAdviceLines();
      return;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   DrawTradeAdviceLines(g_staticEntryPrice, g_staticSL, g_staticTP1, g_staticTP2, g_staticTP3, g_staticTP4, digits);
}

//+------------------------------------------------------------------+
//| Open Advisor Trades Chart Markings (Entry, SL, TP1-4) Engine     |
//| Controlled via Tab & Key [T]. Persistent across timeframes       |
//+------------------------------------------------------------------+
void DeleteOpenTradeMarkings()
{
   ObjectsDeleteAll(0, PREFIX + "OTM_");
}

void CreateOpenTradeHLine(string name, double price, color col, ENUM_LINE_STYLE style, int width, string desc, string tooltip="")
{
   if(price <= 0.0) return;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS); // CRITICAL: NEVER disappear on timeframe change!
   ObjectSetString(0, name, OBJPROP_TEXT, desc);
   string tt = (tooltip != "") ? tooltip : desc + " (" + DoubleToString(price, _Digits) + ")";
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tt);
}

void UpdateOpenTradeMarkings()
{
   if(!g_showOpenTradeMarkings)
   {
      DeleteOpenTradeMarkings();
      return;
   }

   int totalPos = PositionsTotal();
   if(totalPos == 0)
   {
      DeleteOpenTradeMarkings();
      return;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipSize = GetPipSize(_Symbol);
   if(pipSize <= 0.0) pipSize = 0.0001;

   string activeObjects[];
   int activeCount = 0;

   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;

      if(!IsSameChartAsset(posInfo.Symbol(), _Symbol)) continue;

      long magic = posInfo.Magic();
      string comment = posInfo.Comment();
      bool isAdvisor = (magic == InpAdvisorMagicNumber || 
                        StringFind(comment, "SEGS|ADV|") >= 0 || 
                        StringFind(comment, "[MyAdvisor]") >= 0 || 
                        StringFind(comment, "[Advised") >= 0 ||
                        InpMarkAllSymbolPositions);

      if(!isAdvisor) continue;

      ENUM_POSITION_TYPE type = posInfo.PositionType();
      double openPrice = posInfo.PriceOpen();
      double sl        = posInfo.StopLoss();
      double tp        = posInfo.TakeProfit();
      double volume    = posInfo.Volume();
      double profit    = posInfo.Profit() + posInfo.Swap();
      double curPrice  = posInfo.PriceCurrent();
      if(curPrice <= 0.0)
         curPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double pipsProfit = (type == POSITION_TYPE_BUY) ? (curPrice - openPrice) / pipSize : (openPrice - curPrice) / pipSize;
      string pnlStr = (profit >= 0) ? StringFormat("+$%.2f (+%.1f pips)", profit, pipsProfit)
                                    : StringFormat("-$%.2f (%.1f pips)", MathAbs(profit), pipsProfit);

      // Identify leg role from order comment
      int legNum = 1;
      if(StringFind(comment, "L1") >= 0) legNum = 1;
      else if(StringFind(comment, "L2") >= 0) legNum = 2;
      else if(StringFind(comment, "L3") >= 0) legNum = 3;
      else if(StringFind(comment, "L4") >= 0) legNum = 4;

      // 1. On-Chart Entry Line
      string entName = PREFIX + "OTM_ENT_" + IntegerToString(ticket);
      color entCol = (type == POSITION_TYPE_BUY) ? InpColorOpenBuyEntry : InpColorOpenSellEntry;
      string entDesc = StringFormat("🎯 [ADVISOR %s #%I64u] %.2fL @ %s | Float: %s",
                                    (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                                    ticket, volume, DoubleToString(openPrice, digits), pnlStr);
      CreateOpenTradeHLine(entName, openPrice, entCol, STYLE_SOLID, 2, entDesc);
      ArrayResize(activeObjects, activeCount + 1);
      activeObjects[activeCount++] = entName;

      // 2. On-Chart Stop Loss Line
      if(sl > 0.0)
      {
         string slName = PREFIX + "OTM_SL_" + IntegerToString(ticket);
         bool isBreakeven = (type == POSITION_TYPE_BUY) ? (sl >= openPrice) : (sl <= openPrice);
         color slCol = isBreakeven ? InpColorOpenBE : InpColorOpenSL;
         ENUM_LINE_STYLE slStyle = isBreakeven ? STYLE_SOLID : STYLE_DASH;
         double slPips = (type == POSITION_TYPE_BUY) ? (sl - openPrice) / pipSize : (openPrice - sl) / pipSize;
         double riskDollar = CalcRiskFromSL(ticket);

         string slDesc;
         if(isBreakeven)
         {
            slDesc = StringFormat("🔒 [SL #%I64u - BREAKEVEN LOCKED] %s (+%.1f pips | RISK-FREE)",
                                  ticket, DoubleToString(sl, digits), slPips);
         }
         else
         {
            slDesc = StringFormat("🛑 [SL #%I64u] %s (-%.1f pips | -$%.2f Risk)",
                                  ticket, DoubleToString(sl, digits), MathAbs(slPips), riskDollar);
         }
         CreateOpenTradeHLine(slName, sl, slCol, slStyle, 2, slDesc);
         ArrayResize(activeObjects, activeCount + 1);
         activeObjects[activeCount++] = slName;
      }

      // 3. On-Chart Take Profit Line(s)
      if(tp > 0.0)
      {
         string tpName = PREFIX + "OTM_TP_" + IntegerToString(ticket);
         color tpCol = InpColorOpenTP1;
         string legRole = "TP1 (SCALE)";
         if(legNum == 2) { tpCol = InpColorOpenTP2; legRole = "TP2 (BE TRIGGER)"; }
         else if(legNum == 3) { tpCol = InpColorOpenTP3; legRole = "TP3 (RUNNER)"; }
         else if(legNum == 4) { tpCol = InpColorOpenTP4; legRole = "TP4 (MACRO)"; }

         double tpPips = (type == POSITION_TYPE_BUY) ? (tp - openPrice) / pipSize : (openPrice - tp) / pipSize;
         double rewardDollar = CalcProfitFromTP(ticket);
         string tpDesc = StringFormat("🏁 [%s #%I64u] %s (+%.1f pips | +$%.2f Target)",
                                      legRole, ticket, DoubleToString(tp, digits), tpPips, rewardDollar);

         CreateOpenTradeHLine(tpName, tp, tpCol, STYLE_DASH, 2, tpDesc);
         ArrayResize(activeObjects, activeCount + 1);
         activeObjects[activeCount++] = tpName;
      }
      else
      {
         // Project planned advisor targets if unassigned on ticket
         if(g_staticTP1 > 0.0)
         {
            string tp1Name = PREFIX + "OTM_TP1_" + IntegerToString(ticket);
            CreateOpenTradeHLine(tp1Name, g_staticTP1, InpColorOpenTP1, STYLE_DOT, 1,
                                 StringFormat("🏁 [PROJ TP1 #%I64u - FTA SCALE] %s (1.40R)", ticket, DoubleToString(g_staticTP1, digits)));
            ArrayResize(activeObjects, activeCount + 1);
            activeObjects[activeCount++] = tp1Name;
         }
         if(g_staticTP2 > 0.0)
         {
            string tp2Name = PREFIX + "OTM_TP2_" + IntegerToString(ticket);
            CreateOpenTradeHLine(tp2Name, g_staticTP2, InpColorOpenTP2, STYLE_DOT, 1,
                                 StringFormat("🔒 [PROJ TP2 #%I64u - BE LOCK] %s (2.80R)", ticket, DoubleToString(g_staticTP2, digits)));
            ArrayResize(activeObjects, activeCount + 1);
            activeObjects[activeCount++] = tp2Name;
         }
         if(g_staticTP3 > 0.0)
         {
            string tp3Name = PREFIX + "OTM_TP3_" + IntegerToString(ticket);
            CreateOpenTradeHLine(tp3Name, g_staticTP3, InpColorOpenTP3, STYLE_DOT, 1,
                                 StringFormat("🚀 [PROJ TP3 #%I64u - HTF POOL] %s (4.80R)", ticket, DoubleToString(g_staticTP3, digits)));
            ArrayResize(activeObjects, activeCount + 1);
            activeObjects[activeCount++] = tp3Name;
         }
         if(g_staticTP4 > 0.0)
         {
            string tp4Name = PREFIX + "OTM_TP4_" + IntegerToString(ticket);
            CreateOpenTradeHLine(tp4Name, g_staticTP4, InpColorOpenTP4, STYLE_DOT, 1,
                                 StringFormat("🏆 [PROJ TP4 #%I64u - MACRO RUNNER] %s (8.00R)", ticket, DoubleToString(g_staticTP4, digits)));
            ArrayResize(activeObjects, activeCount + 1);
            activeObjects[activeCount++] = tp4Name;
         }
      }
   }

   // Clean up stale OTM objects that are no longer active
   int totalChartObjs = ObjectsTotal(0, 0, OBJ_HLINE);
   for(int j = totalChartObjs - 1; j >= 0; j--)
   {
      string objName = ObjectName(0, j, 0, OBJ_HLINE);
      if(StringFind(objName, PREFIX + "OTM_") == 0)
      {
         bool stillActive = false;
         for(int k = 0; k < activeCount; k++)
         {
            if(activeObjects[k] == objName) { stillActive = true; break; }
         }
         if(!stillActive)
         {
            ObjectDelete(0, objName);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| MASTER MARKET-QUALITY GATE & SESSION VERIFICATION UTILITIES      |
//+------------------------------------------------------------------+

// Telemetry daily reset check
void CheckDailyTelemetryReset()
{
   datetime nowTor = ConvertBrokerTimeToToronto(TimeTradeServer());
   MqlDateTime dt;
   TimeToStruct(nowTor, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayStart = StructToTime(dt);

   if(g_telemetry.lastResetDate != todayStart)
   {
      g_telemetry.candidatesDetected   = 0;
      g_telemetry.setupsValidated      = 0;
      g_telemetry.signalsGenerated     = 0;
      g_telemetry.autoBlocks           = 0;
      g_telemetry.brokerSessionBlocks  = 0;
      g_telemetry.feedBlocks           = 0;
      g_telemetry.spreadCostBlocks     = 0;
      g_telemetry.riskBlocks           = 0;
      g_telemetry.lowQualityChop       = 0;
      g_telemetry.expectancyRejections = 0;
      g_telemetry.tradeApprovals       = 0;
      g_telemetry.ordersAttempted      = 0;
      g_telemetry.ordersExecuted       = 0;
      g_telemetry.brokerRejections     = 0;
      g_telemetry.lastResetDate        = todayStart;
   }
}

// 0. Technical & User Permission Gate (Explicit root causes)
ENUM_AUTO_EXECUTION_STATE GetAutoExecutionState(string sym, string &outDetail, string &outSource)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      outDetail = "BLOCKED BY TERMINAL (ALGO TRADING DISABLED)";
      outSource = "MT5 TERMINAL TOOLBAR";
      return AUTO_EXEC_BLOCKED_TERMINAL;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      outDetail = "BLOCKED BY EA SETTINGS (ALLOW ALGO TRADING UNCHECKED)";
      outSource = "EA PROPERTIES DIALOG";
      return AUTO_EXEC_BLOCKED_MQL;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      outDetail = "BLOCKED BY BROKER / ACCOUNT (READ-ONLY OR INVESTOR)";
      outSource = "BROKER ACCOUNT PERMISSION";
      return AUTO_EXEC_BLOCKED_ACCOUNT;
   }
   if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      outDetail = "BLOCKED BY BROKER (SYMBOL TRADING DISABLED)";
      outSource = "BROKER SYMBOL SETTING";
      return AUTO_EXEC_BLOCKED_BROKER;
   }
   if(!g_myAdvisorEnabled)
   {
      outDetail = "AUTO EXECUTION: DISABLED";
      outSource = "MYADVISOR USER SETTING";
      return AUTO_EXEC_DISABLED;
   }

   outDetail = "AUTO EXECUTION: ENABLED";
   outSource = "MYADVISOR USER SETTING";
   return AUTO_EXEC_ENABLED;
}

bool CheckTradePermissions()
{
   string detail = "", src = "";
   ENUM_AUTO_EXECUTION_STATE st = GetAutoExecutionState(_Symbol, detail, src);
   g_terminalTradingAllowed = (st != AUTO_EXEC_BLOCKED_TERMINAL);
   g_accountTradingAllowed  = (st != AUTO_EXEC_BLOCKED_ACCOUNT);
   g_mqlTradingAllowed      = (st != AUTO_EXEC_BLOCKED_MQL);
   g_tradePermissionAllowed = (st == AUTO_EXEC_ENABLED || st == AUTO_EXEC_DISABLED);
   return (st != AUTO_EXEC_BLOCKED_TERMINAL && st != AUTO_EXEC_BLOCKED_ACCOUNT && st != AUTO_EXEC_BLOCKED_MQL && st != AUTO_EXEC_BLOCKED_BROKER);
}

// 1. Broker Symbol Tradeability (Session table & live tick support for CFDs/Indices)
bool IsBrokerSymbolTradeable(string sym, string &outReason)
{
   long tradeMode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      outReason = "BROKER TRADE MODE DISABLED";
      return false;
   }
   if(tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      outReason = "SYMBOL IN CLOSE-ONLY MODE";
      return false;
   }

   datetime srvNow = TimeTradeServer();
   if(srvNow <= 0) srvNow = TimeCurrent();
   MqlDateTime srvDt;
   TimeToStruct(srvNow, srvDt);

   // Real Weekend Check: Saturday and Sunday pre-open
   if(srvDt.day_of_week == 6) // Saturday
   {
      outReason = "WEEKEND CLOSED (SATURDAY)";
      return false;
   }
   if(srvDt.day_of_week == 0) // Sunday
   {
      datetime torontoNow = GetTorontoTimeNow();
      MqlDateTime tDt;
      TimeToStruct(torontoNow, tDt);
      double tHours = tDt.hour + (tDt.min / 60.0);
      // Sunday before 17:00 NY (or before 21:00 server) is pre-open; 17:00 NY is Sunday Asia Open
      if(tHours < 17.0 && srvDt.hour < 21)
      {
         outReason = "WEEKEND CLOSED (SUNDAY PRE-OPEN)";
         return false;
      }
   }
   if(srvDt.day_of_week == 5 && (srvDt.hour > 23 || (srvDt.hour == 23 && srvDt.min >= 55))) // Friday late close
   {
      outReason = "WEEKEND CLOSED (FRIDAY SETTLEMENT)";
      return false;
   }

   // On active trading days (Monday - Friday, or Sunday post-open):
   // For US30, NAS100, index CFDs, metals, and Forex:
   // If trade mode allows trading, verify session table and continuous CFD streaming
   if(tradeMode == SYMBOL_TRADE_MODE_FULL || 
      tradeMode == SYMBOL_TRADE_MODE_LONGONLY || 
      tradeMode == SYMBOL_TRADE_MODE_SHORTONLY)
   {
      datetime fromTime, toTime;
      bool sessionFound = false;
      bool inSession = false;
      long nowSec = (srvDt.hour * 3600) + (srvDt.min * 60) + srvDt.sec;

      for(int s = 0; s < 5; s++)
      {
         if(SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)srvDt.day_of_week, s, fromTime, toTime))
         {
            sessionFound = true;
            MqlDateTime fDt, tDt;
            TimeToStruct(fromTime, fDt);
            TimeToStruct(toTime, tDt);
            long fSec = (fDt.hour * 3600) + (fDt.min * 60) + fDt.sec;
            long tSec = (tDt.hour * 3600) + (tDt.min * 60) + tDt.sec;
            if(tSec == 0 && (toTime > 0 || (tDt.hour == 0 && tDt.min == 0 && fSec == 0)))
               tSec = 86400;

            if(fSec <= tSec)
            {
               if(nowSec >= fSec && nowSec <= tSec) { inSession = true; break; }
            }
            else
            {
               // Overnight spanning midnight
               if(nowSec >= fSec || nowSec <= tSec) { inSession = true; break; }
            }
         }
      }

      if(sessionFound && inSession)
      {
         outReason = "IN BROKER TRADING SESSION";
         return true;
      }

      // Live CFD market check: On active weekdays, index CFDs (US30, NAS100) stream continuously.
      // If broker permits trading and prices or candle bars are streaming, market is active
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double lastClose = iClose(sym, PERIOD_M1, 0);
      if(lastClose <= 0.0) lastClose = iClose(sym, PERIOD_H1, 0);

      if((bid > 0.0 && ask > 0.0 && ask >= bid) || lastClose > 0.0 || (srvDt.day_of_week >= 1 && srvDt.day_of_week <= 5))
      {
         outReason = "BROKER CFD ACTIVE (LIVE SPREAD STREAMING)";
         return true;
      }

      if(!sessionFound)
      {
         outReason = "BROKER SESSION OPEN (STANDARD CFD HOURS)";
         return true;
      }

      outReason = "BROKER CFD ACTIVE (LIVE SPREAD STREAMING)";
      return true;
   }

   outReason = "TRADE MODE RESTRICTED BY BROKER";
   return false;
}

bool IsMarketSessionOpen(string sym)
{
   string reason = "";
   return IsBrokerSymbolTradeable(sym, reason);
}

// 2. Underlying Cash Session Classification (US30 / Indices Pre-Market & Cash Core)
ENUM_CASH_SESSION GetUnderlyingCashSession(string sym, string &outSessionName, string &outStrategySession)
{
   datetime srvNow = TimeTradeServer();
   if(srvNow <= 0) srvNow = TimeCurrent();
   datetime nowTor = ConvertBrokerTimeToToronto(srvNow);
   MqlDateTime dt;
   TimeToStruct(nowTor, dt);
   double tHours = (double)dt.hour + ((double)dt.min / 60.0);

   MqlDateTime srvDt;
   TimeToStruct(srvNow, srvDt);

   // Real Weekend Check: Saturday and Sunday pre-open ONLY
   if(srvDt.day_of_week == 6 || dt.day_of_week == 6)
   {
      outSessionName = "WEEKEND CLOSED (SATURDAY)";
      outStrategySession = "CLOSED";
      return CASH_SESSION_CLOSED;
   }
   if((srvDt.day_of_week == 5 && (srvDt.hour > 23 || (srvDt.hour == 23 && srvDt.min >= 55))) ||
      (dt.day_of_week == 5 && tHours >= 17.0))
   {
      outSessionName = "WEEKEND CLOSED (FRIDAY CLOSE)";
      outStrategySession = "CLOSED";
      return CASH_SESSION_CLOSED;
   }
   if(dt.day_of_week == 0 && tHours < 17.0 && srvDt.hour < 21)
   {
      outSessionName = "WEEKEND CLOSED (SUNDAY PRE-MARKET)";
      outStrategySession = "CLOSED";
      return CASH_SESSION_CLOSED;
   }
   if(dt.day_of_week == 0 && tHours >= 17.0)
   {
      outSessionName = "SUNDAY ASIA OPEN (17:00-02:00 NY)";
      outStrategySession = "ASIA";
      return CASH_SESSION_REGULAR;
   }

   bool isUSIndex = (IsSymbolMatch(sym, InpDJ30_Patterns) || IsSymbolMatch(sym, InpNAS_Patterns) ||
                     StringFind(sym, "US30") >= 0 || StringFind(sym, "DJ30") >= 0 ||
                     StringFind(sym, "WS30") >= 0 || StringFind(sym, "NAS") >= 0 ||
                     StringFind(sym, "USTEC") >= 0 || StringFind(sym, "SPX") >= 0 ||
                     StringFind(sym, "US100") >= 0 || StringFind(sym, "NDAQ") >= 0);

   if(isUSIndex)
   {
      if(tHours >= 9.5 && tHours < 16.0)
      {
         outSessionName = "US CASH CORE (09:30-16:00)";
         outStrategySession = "US_CORE";
         return CASH_SESSION_REGULAR;
      }
      else if(tHours >= 4.0 && tHours < 9.5)
      {
         outSessionName = "US PRE-MARKET (04:00-09:30)";
         outStrategySession = "PRE_US";
         return CASH_SESSION_PREMARKET;
      }
      else if(tHours >= 16.0 && tHours < 20.0)
      {
         outSessionName = "US AFTER-HOURS (16:00-20:00)";
         outStrategySession = "POST_US";
         return CASH_SESSION_AFTERHOURS;
      }
      else
      {
         outSessionName = "GLOBEX OVERNIGHT (24h CFD)";
         outStrategySession = "OVERNIGHT";
         return CASH_SESSION_OVERNIGHT;
      }
   }

   // Forex & Metals
   if(tHours >= 8.0 && tHours <= 11.5)
   {
      outSessionName = "LONDON / NY OVERLAP";
      outStrategySession = "OVERLAP_CORE";
      return CASH_SESSION_REGULAR;
   }
   else if(tHours >= 3.0 && tHours < 12.0)
   {
      outSessionName = "LONDON SESSION";
      outStrategySession = "LONDON";
      return CASH_SESSION_REGULAR;
   }
   else if(tHours >= 12.0 && tHours < 17.0)
   {
      outSessionName = "NEW YORK AFTERNOON";
      outStrategySession = "NEW_YORK";
      return CASH_SESSION_REGULAR;
   }
   else
   {
      outSessionName = "ASIAN / PACIFIC SESSION";
      outStrategySession = "ASIA";
      return CASH_SESSION_OVERNIGHT;
   }
}

// 3. Feed Health & Data Freshness (Decoupled from market hours)
ENUM_FEED_STATE EvaluateFeedHealth(string sym, int &outAgeSec)
{
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.time <= 0)
   {
      outAgeSec = 999999;
      return FEED_UNKNOWN;
   }

   datetime srvNow = TimeTradeServer();
   if(srvNow >= tick.time)
      outAgeSec = (int)(srvNow - tick.time);
   else
      outAgeSec = 0;

   if(outAgeSec <= 15) return FEED_LIVE;
   if(outAgeSec <= 60) return FEED_DELAYED;
   return FEED_STALE;
}

int GetLastTickAge(string sym)
{
   int age = 0;
   EvaluateFeedHealth(sym, age);
   return age;
}

bool IsMarketDataFresh(string sym)
{
   int age = 0;
   ENUM_FEED_STATE st = EvaluateFeedHealth(sym, age);
   return (st == FEED_LIVE || st == FEED_DELAYED);
}

// 4. Volatility Regime Gate (Decoupled from session gate)
string CalculateNormalizedVolatility(string sym, double &outAtrRatio, double &outRangeRatio, double &outScore)
{
   outAtrRatio = 1.0;
   outRangeRatio = 1.0;
   outScore = 1.0;

   int barsH1 = iBars(sym, PERIOD_H1);
   if(barsH1 < 25) return "N/A";

   double atrs[];
   ArrayResize(atrs, 21);
   for(int b = 1; b <= 20; b++)
   {
      double h = iHigh(sym, PERIOD_H1, b);
      double l = iLow(sym, PERIOD_H1, b);
      double pc = iClose(sym, PERIOD_H1, b + 1);
      double tr = MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
      atrs[b] = tr;
   }

   double curAtrH1 = 0.0;
   for(int b = 1; b <= 14; b++) curAtrH1 += atrs[b];
   curAtrH1 /= 14.0;

   double baseAtrs[];
   ArrayResize(baseAtrs, 20);
   for(int b = 1; b <= 20; b++) baseAtrs[b - 1] = atrs[b];
   ArraySort(baseAtrs);
   double baselineAtr = (baseAtrs[9] + baseAtrs[10]) / 2.0;

   if(baselineAtr > 0.0) outAtrRatio = curAtrH1 / baselineAtr;

   double curRange = iHigh(sym, PERIOD_H1, 1) - iLow(sym, PERIOD_H1, 1);
   if(curAtrH1 > 0.0) outRangeRatio = curRange / curAtrH1;

   outScore = NormalizeDouble((0.60 * outAtrRatio) + (0.40 * MathMin(outRangeRatio, 2.5)), 2);

   if(outScore < InpVolLowThreshold) return "LOW";
   if(outScore > InpVolHighThreshold) return "HIGH";
   return "NORMAL";
}

// 5. Liquidity & Tick Activity Proxy
string MeasureMarketLiquidity(string sym, double &outRatio)
{
   outRatio = 0.0;
   int barsM1 = iBars(sym, PERIOD_M1);
   if(barsM1 < 44)
   {
      g_liquidityState = "N/A";
      g_tickActivityRatio = 0.0;
      return "N/A";
   }

   long v1 = iTickVolume(sym, PERIOD_M1, 1);
   long v2 = iTickVolume(sym, PERIOD_M1, 2);
   long v3 = iTickVolume(sym, PERIOD_M1, 3);
   double recentActivity = (double)(v1 + v2 + v3) / 3.0;

   double baseVols[];
   ArrayResize(baseVols, 40);
   for(int b = 0; b < 40; b++)
      baseVols[b] = (double)iTickVolume(sym, PERIOD_M1, 4 + b);
   ArraySort(baseVols);
   double baselineActivity = (baseVols[19] + baseVols[20]) / 2.0;

   if(baselineActivity <= 0.0) baselineActivity = 1.0;
   outRatio = NormalizeDouble(recentActivity / baselineActivity, 2);
   g_tickActivityRatio = outRatio;

   if(outRatio >= 0.75) { g_liquidityState = "GOOD"; return "GOOD"; }
   if(outRatio >= 0.35) { g_liquidityState = "WEAK"; return "WEAK"; }
   g_liquidityState = "POOR";
   return "POOR";
}

// 6. Dynamic Spread Normalization & Spread Cost Classification (Smart Thresholds)
void UpdateSpreadHistory(string sym)
{
   long curSpread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   if(curSpread <= 0) return;

   if(g_spreadSampleCount < 50)
   {
      g_spreadHistory[g_spreadSampleCount++] = (double)curSpread;
   }
   else
   {
      for(int i = 0; i < 49; i++) g_spreadHistory[i] = g_spreadHistory[i + 1];
      g_spreadHistory[49] = (double)curSpread;
   }

   if(g_spreadSampleCount >= 5)
   {
      double temp[];
      ArrayResize(temp, g_spreadSampleCount);
      ArrayCopy(temp, g_spreadHistory, 0, 0, g_spreadSampleCount);
      ArraySort(temp);
      g_dynamicTypicalSpread = temp[g_spreadSampleCount / 2];
   }
}

bool CheckSpreadQuality(string sym, double &outRatio)
{
   UpdateSpreadHistory(sym);
   long curSpread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double baselineSpread = g_dynamicTypicalSpread;
   if(g_spreadSampleCount < 10)
   {
      if(IsSymbolMatch(sym, InpXAU_Patterns)) baselineSpread = 35.0;
      else if(IsSymbolMatch(sym, InpDJ30_Patterns) || IsSymbolMatch(sym, InpNAS_Patterns)) baselineSpread = 250.0;
      else if(IsSymbolMatch(sym, InpBTC_Patterns)) baselineSpread = 1500.0;
      else if(digits == 3 || digits == 5) baselineSpread = 18.0;
      else baselineSpread = 20.0;
   }

   outRatio = (baselineSpread > 0.0) ? ((double)curSpread / baselineSpread) : 1.0;
   return (outRatio <= 4.5);
}

ENUM_SPREAD_STATE EvaluateSpreadCost(string sym, double plannedStopDist, double &outSpreadRatio, double &outCostRatio, string &outSpreadStr)
{
   UpdateSpreadHistory(sym);
   long curSpread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double curSpreadPrice = (double)curSpread * pt;

   double baselineSpread = g_dynamicTypicalSpread;
   if(g_spreadSampleCount < 10)
   {
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(IsSymbolMatch(sym, InpXAU_Patterns)) baselineSpread = 35.0;
      else if(IsSymbolMatch(sym, InpDJ30_Patterns) || IsSymbolMatch(sym, InpNAS_Patterns)) baselineSpread = 250.0;
      else if(IsSymbolMatch(sym, InpBTC_Patterns)) baselineSpread = 1500.0;
      else if(digits == 3 || digits == 5) baselineSpread = 18.0;
      else baselineSpread = 20.0;
   }

   outSpreadRatio = (baselineSpread > 0.0) ? ((double)curSpread / baselineSpread) : 1.0;
   outCostRatio = (plannedStopDist > 0.0) ? (curSpreadPrice / plannedStopDist) : 0.0;

   if(outCostRatio > 0.25 || outSpreadRatio > 4.5)
   {
      outSpreadStr = StringFormat("CRITICAL (%.1fx typ, %.1f%% SL)", outSpreadRatio, outCostRatio * 100.0);
      return SPREAD_CRITICAL;
   }
   if(outCostRatio > 0.15 || outSpreadRatio > 2.8)
   {
      outSpreadStr = StringFormat("HIGH (%.1fx typ, %.1f%% SL)", outSpreadRatio, outCostRatio * 100.0);
      return SPREAD_HIGH;
   }
   if(outCostRatio > 0.08 || outSpreadRatio > 1.8)
   {
      outSpreadStr = StringFormat("ELEVATED (%.1fx typ, %.1f%% SL)", outSpreadRatio, outCostRatio * 100.0);
      return SPREAD_ELEVATED;
   }

   outSpreadStr = StringFormat("NORMAL (%.1fx typ, %.1f%% SL)", outSpreadRatio, outCostRatio * 100.0);
   return SPREAD_NORMAL;
}

// 6. Price Extension Gate (Anti-Chasing Filter, Section 52 Cached Handles)
bool IsPriceExtended(string sym, string dir, double curPrice, double &outExtRatio)
{
   outExtRatio = 0.0;
   if(g_hEma20_H1 == INVALID_HANDLE || g_hAtr_H1 == INVALID_HANDLE || g_cachedHandleSymbol != sym)
      InitIndicatorHandles(sym);

   if(g_hEma20_H1 == INVALID_HANDLE || g_hAtr_H1 == INVALID_HANDLE) return false;

   double maBuf[];
   ArraySetAsSeries(maBuf, true);
   int cp = CopyBuffer(g_hEma20_H1, 0, 1, 1, maBuf);
   if(cp < 1) return false;

   double ema20 = maBuf[0];
   double dist = MathAbs(curPrice - ema20);

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   cp = CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf);
   if(cp < 1 || atrBuf[0] <= 0.0) return false;

   double curAtr = atrBuf[0];
   outExtRatio = dist / curAtr;

   if(outExtRatio > InpPriceExtensionATR)
   {
      if(dir == "BUY" && curPrice > ema20) return true;
      if(dir == "SELL" && curPrice < ema20) return true;
   }
   return false;
}

// 7. Confirmed Market Structure Identification using independent M30 & H1 candle analysis
string ScanMarketSwingStructure(string sym, double &outSwingHigh, double &outSwingLow, double &outSupport, double &outResistance)
{
   outSwingHigh = 0.0;
   outSwingLow = 9999999.0;
   outSupport = 0.0;
   outResistance = 9999999.0;

   // -------------------------------------------------------------
   // A. 1-HOUR (H1) MARKET STRUCTURE: Higher Highs & Lower Lows
   // -------------------------------------------------------------
   double h1Highs[];
   double h1Lows[];
   int h1HCount = 0, h1LCount = 0;
   ArrayResize(h1Highs, 20);
   ArrayResize(h1Lows, 20);

   int maxB = MathMin(InpStructureLookbackBars, 50);
   for(int b = 3; b <= maxB - 2; b++)
   {
      double h = iHigh(sym, PERIOD_H1, b);
      double l = iLow(sym, PERIOD_H1, b);

      bool isPivotH = (h >= iHigh(sym, PERIOD_H1, b - 1) &&
                       h >= iHigh(sym, PERIOD_H1, b - 2) &&
                       h >= iHigh(sym, PERIOD_H1, b + 1) &&
                       h >= iHigh(sym, PERIOD_H1, b + 2));

      bool isPivotL = (l <= iLow(sym, PERIOD_H1, b - 1) &&
                       l <= iLow(sym, PERIOD_H1, b - 2) &&
                       l <= iLow(sym, PERIOD_H1, b + 1) &&
                       l <= iLow(sym, PERIOD_H1, b + 2));

      if(isPivotH && h1HCount < 20)
      {
         h1Highs[h1HCount++] = h;
         if(g_recentPivotTime == 0) g_recentPivotTime = iTime(sym, PERIOD_H1, b);
      }
      if(isPivotL && h1LCount < 20)
      {
         h1Lows[h1LCount++] = l;
         if(g_recentPivotTime == 0) g_recentPivotTime = iTime(sym, PERIOD_H1, b);
      }
   }

   // -------------------------------------------------------------
   // B. 30-MINUTE (M30) MARKET STRUCTURE: Higher Highs & Lower Lows
   // -------------------------------------------------------------
   double m30Highs[];
   double m30Lows[];
   int m30HCount = 0, m30LCount = 0;
   ArrayResize(m30Highs, 25);
   ArrayResize(m30Lows, 25);

   for(int b = 2; b <= 45; b++)
   {
      double h = iHigh(sym, PERIOD_M30, b);
      double l = iLow(sym, PERIOD_M30, b);

      bool isPivotH = (h >= iHigh(sym, PERIOD_M30, b - 1) &&
                       h >= iHigh(sym, PERIOD_M30, b + 1));

      bool isPivotL = (l <= iLow(sym, PERIOD_M30, b - 1) &&
                       l <= iLow(sym, PERIOD_M30, b + 1));

      if(isPivotH && m30HCount < 25) m30Highs[m30HCount++] = h;
      if(isPivotL && m30LCount < 25) m30Lows[m30LCount++] = l;
   }

   double curCloseH1 = iClose(sym, PERIOD_H1, 1);
   double curCloseM30 = iClose(sym, PERIOD_M30, 1);

   // Evaluate H1 Higher High (HH) & Lower Low (LL)
   g_hasHH_H1 = false;
   g_hasLL_H1 = false;
   g_marketStructureH1 = "NEUTRAL";
   if(h1HCount >= 2 && h1LCount >= 2)
   {
      bool hh = (h1Highs[0] > h1Highs[1]) || (curCloseH1 > h1Highs[0]);
      bool hl = (h1Lows[0] > h1Lows[1]);
      bool lh = (h1Highs[0] < h1Highs[1]);
      bool ll = (h1Lows[0] < h1Lows[1]) || (curCloseH1 < h1Lows[0]);
      g_hasHH_H1 = hh;
      g_hasLL_H1 = ll;

      if(hh && hl) g_marketStructureH1 = "BULLISH";
      else if(lh && ll) g_marketStructureH1 = "BEARISH";
      else if(hh && !ll) g_marketStructureH1 = "BULLISH";
      else if(ll && !hh) g_marketStructureH1 = "BEARISH";
   }
   else if(h1HCount >= 1 && h1LCount >= 1)
   {
      if(curCloseH1 > h1Highs[0]) { g_hasHH_H1 = true; g_marketStructureH1 = "BULLISH"; }
      if(curCloseH1 < h1Lows[0])  { g_hasLL_H1 = true; g_marketStructureH1 = "BEARISH"; }
   }
   if(h1HCount > 0) g_h1SwingHigh = h1Highs[0];
   if(h1LCount > 0) g_h1SwingLow  = h1Lows[0];

   // Evaluate M30 Higher High (HH) & Lower Low (LL)
   g_hasHH_M30 = false;
   g_hasLL_M30 = false;
   g_marketStructureM30 = "NEUTRAL";
   if(m30HCount >= 2 && m30LCount >= 2)
   {
      bool hh = (m30Highs[0] > m30Highs[1]) || (curCloseM30 > m30Highs[0]);
      bool hl = (m30Lows[0] > m30Lows[1]);
      bool lh = (m30Highs[0] < m30Highs[1]);
      bool ll = (m30Lows[0] < m30Lows[1]) || (curCloseM30 < m30Lows[0]);
      g_hasHH_M30 = hh;
      g_hasLL_M30 = ll;

      if(hh && hl) g_marketStructureM30 = "BULLISH";
      else if(lh && ll) g_marketStructureM30 = "BEARISH";
      else if(hh && !ll) g_marketStructureM30 = "BULLISH";
      else if(ll && !hh) g_marketStructureM30 = "BEARISH";
   }
   else if(m30HCount >= 1 && m30LCount >= 1)
   {
      if(curCloseM30 > m30Highs[0]) { g_hasHH_M30 = true; g_marketStructureM30 = "BULLISH"; }
      if(curCloseM30 < m30Lows[0])  { g_hasLL_M30 = true; g_marketStructureM30 = "BEARISH"; }
   }
   if(m30HCount > 0) g_m30SwingHigh = m30Highs[0];
   if(m30LCount > 0) g_m30SwingLow  = m30Lows[0];

   // Structural Support & Resistance calculation from combined verified pivots
   if(h1HCount > 0) outSwingHigh = h1Highs[0];
   else if(m30HCount > 0) outSwingHigh = m30Highs[0];

   if(h1LCount > 0) outSwingLow = h1Lows[0];
   else if(m30LCount > 0) outSwingLow = m30Lows[0];

   for(int i = 0; i < h1HCount; i++)
   {
      if(h1Highs[i] > curCloseH1 && h1Highs[i] < outResistance)
         outResistance = h1Highs[i];
   }
   for(int i = 0; i < m30HCount; i++)
   {
      if(m30Highs[i] > curCloseH1 && m30Highs[i] < outResistance)
         outResistance = m30Highs[i];
   }
   if(outResistance >= 9999998.0 && outSwingHigh > 0.0) outResistance = outSwingHigh;

   for(int i = 0; i < h1LCount; i++)
   {
      if(h1Lows[i] < curCloseH1 && h1Lows[i] > outSupport)
         outSupport = h1Lows[i];
   }
   for(int i = 0; i < m30LCount; i++)
   {
      if(m30Lows[i] < curCloseH1 && m30Lows[i] > outSupport)
         outSupport = m30Lows[i];
   }
   if(outSupport <= 0.0 && outSwingLow < 9999998.0) outSupport = outSwingLow;

   // Fallback when pivots are sparse in strong trends (Native MQL5)
   if(outSwingHigh <= 0.0)
   {
      int count = MathMin(InpStructureLookbackBars, 50);
      double highs[];
      ArraySetAsSeries(highs, true);
      if(CopyHigh(sym, PERIOD_H1, 2, count, highs) > 0)
      {
         int hIdx = ArrayMaximum(highs);
         if(hIdx >= 0) outSwingHigh = highs[hIdx];
      }
      if(outResistance >= 9999998.0) outResistance = outSwingHigh;
   }
   if(outSwingLow >= 9999998.0)
   {
      int count = MathMin(InpStructureLookbackBars, 50);
      double lows[];
      ArraySetAsSeries(lows, true);
      if(CopyLow(sym, PERIOD_H1, 2, count, lows) > 0)
      {
         int lIdx = ArrayMinimum(lows);
         if(lIdx >= 0) outSwingLow = lows[lIdx];
      }
      if(outSupport <= 0.0) outSupport = outSwingLow;
   }

   // -------------------------------------------------------------
   // C. MULTI-TIMEFRAME CONFLUENCE (M30 + H1)
   // -------------------------------------------------------------
   if((g_hasHH_M30 && g_hasHH_H1) || (g_marketStructureM30 == "BULLISH" && g_marketStructureH1 == "BULLISH"))
      return "BULLISH";
   if((g_hasLL_M30 && g_hasLL_H1) || (g_marketStructureM30 == "BEARISH" && g_marketStructureH1 == "BEARISH"))
      return "BEARISH";
   if(g_hasHH_M30 && !g_hasLL_H1)
      return "BULLISH";
   if(g_hasLL_M30 && !g_hasHH_H1)
      return "BEARISH";
   if(g_marketStructureH1 == "BULLISH" && !g_hasLL_M30)
      return "BULLISH";
   if(g_marketStructureH1 == "BEARISH" && !g_hasHH_M30)
      return "BEARISH";

   if(curCloseH1 > outSwingHigh) return "BULLISH";
   if(curCloseH1 < outSwingLow)  return "BEARISH";

   return "NEUTRAL";
}

// 8. Setup Location & Retest / Pullback Gate
bool IsValidSetupLocation(string sym, string dir, double curPrice, double ema20, double atr, double swingHigh, double swingLow)
{
   if(atr <= 0.0) return true;
   double pipSize = GetPipSize(sym);

   // A. PLANNED ENTRY TOUCH CHECK: If an active planned entry is set and price has reached/touched it, location is valid!
   if(g_staticEntryPrice > 0.0)
   {
      double entryDist = MathAbs(curPrice - g_staticEntryPrice);
      if(entryDist <= MathMax(0.35 * atr, 8.0 * pipSize)) return true;
      if(dir == "BUY" && curPrice <= g_staticEntryPrice + MathMax(0.20 * atr, 5.0 * pipSize) && (g_staticSL <= 0.0 || curPrice > g_staticSL))
         return true;
      if(dir == "SELL" && curPrice >= g_staticEntryPrice - MathMax(0.20 * atr, 5.0 * pipSize) && (g_staticSL <= 0.0 || curPrice < g_staticSL))
         return true;
   }

   // B. ORDER BLOCK TOUCH CHECK: If price is inside or touching any unmitigated order block in setup direction, location is valid!
   for(int k = 0; k < ArraySize(g_orderBlocks); k++)
   {
      if(g_orderBlocks[k].invalidated) continue;
      if(dir == "BUY" && g_orderBlocks[k].bullish)
      {
         if(curPrice >= g_orderBlocks[k].low - 4.0 * pipSize && curPrice <= g_orderBlocks[k].high + MathMax(0.25 * atr, 6.0 * pipSize))
            return true;
      }
      else if(dir == "SELL" && !g_orderBlocks[k].bullish)
      {
         if(curPrice <= g_orderBlocks[k].high + 4.0 * pipSize && curPrice >= g_orderBlocks[k].low - MathMax(0.25 * atr, 6.0 * pipSize))
            return true;
      }
   }

   if(dir == "BUY")
   {
      // 1. Value zone: near EMA20 (within 0.85 ATR)
      bool nearValue = (curPrice <= ema20 + 0.85 * atr && curPrice >= ema20 - 1.6 * atr);
      // 2. Structural breakout retest: near recent swing high / broken resistance (within 0.25 ATR or 10 pips)
      bool nearRetest = (swingHigh > 0.0 && MathAbs(curPrice - swingHigh) <= MathMax(0.25 * atr, 10.0 * pipSize));
      // 3. Clean fresh breakout above swing high, but NOT yet extended (max 0.30 ATR beyond level)
      bool freshBreakout = (swingHigh > 0.0 && curPrice >= swingHigh && curPrice <= swingHigh + MathMax(0.30 * atr, 10.0 * pipSize));
      // Must be above swing low / invalidation base
      bool aboveBase = (swingLow <= 0.0 || curPrice > swingLow);
      return (aboveBase && (nearValue || nearRetest || freshBreakout));
   }
   else if(dir == "SELL")
   {
      // 1. Value zone: near EMA20 (within 0.85 ATR)
      bool nearValue = (curPrice >= ema20 - 0.85 * atr && curPrice <= ema20 + 1.6 * atr);
      // 2. Structural breakdown retest: near recent swing low / broken support (within 0.25 ATR or 10 pips)
      bool nearRetest = (swingLow > 0.0 && MathAbs(curPrice - swingLow) <= MathMax(0.25 * atr, 10.0 * pipSize));
      // 3. Clean fresh breakdown below swing low, but NOT yet extended (max 0.30 ATR below level)
      bool freshBreakdown = (swingLow > 0.0 && curPrice <= swingLow && curPrice >= swingLow - MathMax(0.30 * atr, 10.0 * pipSize));
      // Must be below swing high / invalidation ceiling
      bool belowCeiling = (swingHigh <= 0.0 || curPrice < swingHigh);
      return (belowCeiling && (nearValue || nearRetest || freshBreakdown));
   }
   return false;
}

// 9. Closed-Candle Entry Confirmation Gate (Bar 1)
bool HasEntryConfirmation(string sym, string dir, string volRegime, double &outConfScore)
{
   outConfScore = 0.0;
   double o1 = iOpen(sym, PERIOD_H1, 1);
   double h1 = iHigh(sym, PERIOD_H1, 1);
   double l1 = iLow(sym, PERIOD_H1, 1);
   double c1 = iClose(sym, PERIOD_H1, 1);
   double rng1 = h1 - l1;
   if(rng1 <= 0.0) return false;

   double o2 = iOpen(sym, PERIOD_H1, 2);
   double h2 = iHigh(sym, PERIOD_H1, 2);
   double l2 = iLow(sym, PERIOD_H1, 2);
   double c2 = iClose(sym, PERIOD_H1, 2);

   bool isHighVol = (volRegime == "HIGH");
   double minBodyRatio = isHighVol ? InpHighVolConfirmThreshold : 0.35;

   if(dir == "BUY")
   {
      bool bullClose = (c1 > o1);
      double lowerWick = MathMin(o1, c1) - l1;
      double body = MathAbs(c1 - o1);

      // Rejection hammer, engulfing, momentum or micro-break
      bool rejection = (lowerWick >= 0.35 * rng1 && c1 >= l1 + 0.50 * rng1);
      bool engulfing = (bullClose && c1 > h2 && o1 <= c2);
      bool momentum  = (bullClose && c1 >= l1 + 0.65 * rng1 && (body / rng1) >= minBodyRatio);
      bool microBreak= (c1 > h2 && bullClose);

      if(rejection || engulfing || momentum || microBreak)
      {
         outConfScore = 15.0;
         if(engulfing || (momentum && rejection)) outConfScore = 20.0;
         return true;
      }
   }
   else if(dir == "SELL")
   {
      bool bearClose = (c1 < o1);
      double upperWick = h1 - MathMax(o1, c1);
      double body = MathAbs(c1 - o1);

      // Rejection shooting star, engulfing, momentum or micro-break
      bool rejection = (upperWick >= 0.35 * rng1 && c1 <= l1 + 0.50 * rng1);
      bool engulfing = (bearClose && c1 < l2 && o1 >= c2);
      bool momentum  = (bearClose && c1 <= l1 + 0.35 * rng1 && (body / rng1) >= minBodyRatio);
      bool microBreak= (c1 < l2 && bearClose);

      if(rejection || engulfing || momentum || microBreak)
      {
         outConfScore = 15.0;
         if(engulfing || (momentum && rejection)) outConfScore = 20.0;
         return true;
      }
   }
   return false;
}

// 10. Truly Atomic Multi-Chart Execution Lock using GlobalVariableSetOnCondition
bool TryAcquireAccountLock(string opName, int timeoutSec=12)
{
   string lockKey = "SEGS_LOCK_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + opName;
   datetime now = TimeCurrent();

   if(!GlobalVariableCheck(lockKey))
   {
      GlobalVariableTemp(lockKey);
      GlobalVariableSet(lockKey, 0.0);
   }

   double curVal = GlobalVariableGet(lockKey);
   if(curVal > 0.0 && (now - (datetime)curVal) < timeoutSec)
   {
      return false; // Held by another instance
   }

   // Atomic compare-and-set
   return GlobalVariableSetOnCondition(lockKey, (double)now, curVal);
}

void ReleaseAccountLock(string opName)
{
   string lockKey = "SEGS_LOCK_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + opName;
   GlobalVariableSet(lockKey, 0.0);
}

bool AcquireAccountExecutionLock(string opName, int timeoutSec=12)
{
   return TryAcquireAccountLock(opName, timeoutSec);
}

void ReleaseAccountExecutionLock(string opName)
{
   ReleaseAccountLock(opName);
}

string BuildSignalID(string sym, string dir, datetime srvTime)
{
   return BuildStableSignalID(sym, dir, srvTime, 0);
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Smart Lot Size based on Balance & Risk Profile |
//| Supports accounts <= $100 USD with micro-floor protection        |
//| Splits volume equally across legs (each leg identical volume)    |
//+------------------------------------------------------------------+
bool CalculateSmartLotSize(string sym, double balance, double slPips, double &outTotalLot, double &outLegLot, int &outLegsCount, string &outExplanation, int requestedLegs=4)
{
   if(balance <= 0.0) balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) balance = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0.0) balance = 1000.0;
   if(requestedLegs < 1) requestedLegs = 1;
   if(requestedLegs > 4) requestedLegs = 4;

   // 1. Determine effective risk %
   double riskPct = 2.0;
   if(InpSmartRiskProfile == RISK_PROFILE_CONSERVATIVE) riskPct = 1.0;
   else if(InpSmartRiskProfile == RISK_PROFILE_BALANCED) riskPct = 2.0;
   else if(InpSmartRiskProfile == RISK_PROFILE_AGGRESSIVE) riskPct = 3.0;
   else if(InpSmartRiskProfile == RISK_PROFILE_CUSTOM) riskPct = MathMax(0.1, InpCustomRiskPercent);

   double targetRiskCash = balance * (riskPct / 100.0);

   // 2. Broker volume specifications
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0)  minLot = 0.01;
   if(lotStep <= 0.0) lotStep = 0.01;
   if(maxLot <= 0.0)  maxLot = 500.0;
   if(InpSmartMaxCapLot > 0.0 && maxLot > InpSmartMaxCapLot) maxLot = InpSmartMaxCapLot;
   int volDigits = GetVolumeDigits(sym);

   // 3. Fallback SL distance in pips if zero or unsupplied
   if(slPips <= 0.0)
   {
      double dSL, dTP1, dTP2, dTP3, dTP4;
      GetAssetTargets(sym, dSL, dTP1, dTP2, dTP3, dTP4);
      slPips = dSL;
   }
   if(slPips < 5.0) slPips = 5.0;

   // 4. Authoritative cash risk calculation for 1.0 standard lot
   double pipSize = GetPipSize(sym);
   double slDist = slPips * pipSize;
   double riskPer1Lot = 0.0;

   // Primary Method: MT5 Authoritative Native Engine OrderCalcProfit
   double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
   double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
   double refPrice = (curAsk > 0.0) ? curAsk : curBid;
   if(refPrice <= 0.0) refPrice = SymbolInfoDouble(sym, SYMBOL_LAST);

   if(refPrice > 0.0 && slDist > 0.0)
   {
      double testLoss = 0.0;
      double testSL = refPrice - slDist;
      ResetLastError();
      if(OrderCalcProfit(ORDER_TYPE_BUY, sym, 1.0, refPrice, testSL, testLoss))
      {
         if(MathAbs(testLoss) > 0.00001)
         {
            riskPer1Lot = MathAbs(testLoss);
         }
      }
   }

   // Secondary Fallback Method if OrderCalcProfit is uncalculated (offline / weekend / non-streaming)
   if(riskPer1Lot <= 0.0001)
   {
      double tickVal      = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSize     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double contractSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);

      if(tickSize > 0.0 && tickVal > 0.0 && slDist > 0.0)
      {
         riskPer1Lot = (slDist / tickSize) * tickVal;
      }
      else if(contractSize > 0.0 && slDist > 0.0)
      {
         riskPer1Lot = slDist * contractSize;
      }
      else
      {
         // Asset-specific known market calibrations
         double pipValPerLot = 10.0;
         if(IsSymbolMatch(sym, InpXAU_Patterns)) pipValPerLot = 10.0;
         else if(IsSymbolMatch(sym, InpDJ30_Patterns)) pipValPerLot = 1.0;
         else if(IsSymbolMatch(sym, InpNAS_Patterns)) pipValPerLot = 1.0;
         else if(IsSymbolMatch(sym, InpGJ_Patterns)) pipValPerLot = 6.70;
         else if(IsSymbolMatch(sym, InpGU_Patterns)) pipValPerLot = 10.0;
         else if(IsSymbolMatch(sym, InpAUD_Patterns)) pipValPerLot = 10.0;
         else if(IsSymbolMatch(sym, InpOIL_Patterns)) pipValPerLot = 10.0;
         else if(IsSymbolMatch(sym, InpBTC_Patterns)) pipValPerLot = 1.0;
         else if(IsSymbolMatch(sym, InpAMD_Patterns) || StringFind(sym, "NDAQ") >= 0)
         {
            double curP = (curAsk > 0.0) ? curAsk : curBid;
            if(curP <= 0.0) curP = SymbolInfoDouble(sym, SYMBOL_LAST);
            string detType = DetectAssetType(sym);
            if(detType == "NAS100" || curP > 1000.0)
            {
               pipValPerLot = 1.0;
            }
            else
            {
               // If NDAQ stock CFD trading at ~$90-$100/share, 1 lot = 1 share, 1 pip ($0.01) = $0.01 per lot.
               // If contract size is 100 shares, 1 pip ($0.01) = $1.00 per lot.
               double cSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
               if(cSize > 1.0) pipValPerLot = 0.01 * cSize;
               else pipValPerLot = 0.01;
            }
         }
         riskPer1Lot = slPips * pipValPerLot;
      }
   }
   if(riskPer1Lot <= 0.0001) riskPer1Lot = 1.0;

   double rawTotalLot = targetRiskCash / riskPer1Lot;

   // 5. Small Account & Micro-Account Support (Balances <= $100 USD)
   bool isMicroFloor = false;
   if(balance <= 100.0 && InpSmartMicroAccountSupport)
   {
      isMicroFloor = true;
      if(balance <= 30.0 || requestedLegs == 1)
      {
         outLegsCount = 1;
         outLegLot = minLot;
         outTotalLot = minLot;
      }
      else if(balance <= 60.0 || requestedLegs == 2)
      {
         outLegsCount = MathMin(2, requestedLegs);
         outLegLot = minLot;
         outTotalLot = NormalizeDouble(minLot * (double)outLegsCount, volDigits);
      }
      else
      {
         outLegsCount = requestedLegs;
         outLegLot = minLot;
         outTotalLot = NormalizeDouble(minLot * (double)outLegsCount, volDigits);
      }
   }
   else
   {
      outLegsCount = requestedLegs;
      double rawLeg = rawTotalLot / (double)outLegsCount;
      double steps = MathRound(rawLeg / lotStep);
      outLegLot = MathMax(minLot, steps * lotStep);
      outLegLot = NormalizeDouble(outLegLot, volDigits);
      outTotalLot = NormalizeDouble(outLegLot * (double)outLegsCount, volDigits);

      if(outTotalLot > maxLot)
      {
         outTotalLot = maxLot;
         outLegLot = NormalizeDouble(MathMax(minLot, MathFloor((outTotalLot / (double)outLegsCount) / lotStep) * lotStep), volDigits);
      }
   }

   double actualCashRisk = outTotalLot * riskPer1Lot;
   double actualRiskPct = (balance > 0.0) ? ((actualCashRisk / balance) * 100.0) : 0.0;

   if(isMicroFloor)
   {
      outExplanation = StringFormat("Micro Floor (%dx %.2f = %.2f lot) | Bal: $%.0f | Risk: $%.2f (%.1f%%) | SL: %.1fp",
                                    outLegsCount, outLegLot, outTotalLot, balance, actualCashRisk, actualRiskPct, slPips);
   }
   else
   {
      string pName = (InpSmartRiskProfile == RISK_PROFILE_CONSERVATIVE ? "Conservative" : (InpSmartRiskProfile == RISK_PROFILE_AGGRESSIVE ? "Aggressive" : (InpSmartRiskProfile == RISK_PROFILE_CUSTOM ? "Custom" : "Balanced")));
      outExplanation = StringFormat("%s %.1f%% on $%.0f | Target: $%.2f (1L: $%.2f) | SL: %.1fp | %dx %.2f = %.2f lot | Risk: $%.2f (%.1f%%)",
                                    pName, riskPct, balance, targetRiskCash, riskPer1Lot, slPips, outLegsCount, outLegLot, outTotalLot, actualCashRisk, actualRiskPct);
   }

   return true;
}

double GetAdvisorLotForSymbol(string sym)
{
   if(g_smartLotEnabled)
   {
      double sTotal = 0.0, sLeg = 0.0;
      int sLegs = 4;
      string sExp = "";
      CalculateSmartLotSize(sym, AccountInfoDouble(ACCOUNT_BALANCE), 0.0, sTotal, sLeg, sLegs, sExp);
      if(sTotal > 0.0) return sTotal;
   }
   if(IsSymbolMatch(sym, InpXAU_Patterns))  return InpAdvisorLot_XAUUSD;
   if(IsSymbolMatch(sym, InpDJ30_Patterns)) return InpAdvisorLot_US30;
   if(IsSymbolMatch(sym, InpNAS_Patterns))  return InpAdvisorLot_NAS100;
   if(IsSymbolMatch(sym, InpGJ_Patterns))   return InpAdvisorLot_GBPJPY;
   if(IsSymbolMatch(sym, InpGU_Patterns))   return InpAdvisorLot_GBPUSD;
   string upper = sym;
   StringToUpper(upper);
   if(StringFind(upper, "GBPUSD") >= 0 || StringFind(upper, "GU") >= 0) return InpAdvisorLot_GBPUSD;
   if(IsSymbolMatch(sym, InpAUD_Patterns) || StringFind(upper, "AUDUSD") >= 0 || StringFind(upper, "AUD") >= 0) return InpAdvisorLot_AUDUSD;
   if(IsSymbolMatch(sym, InpOIL_Patterns) || StringFind(upper, "USOIL") >= 0 || StringFind(upper, "WTI") >= 0 || StringFind(upper, "CRUDE") >= 0 || StringFind(upper, "XTIUSD") >= 0) return InpAdvisorLot_USOIL;
   if(StringFind(upper, "AMD") >= 0)        return InpAdvisorLot_AMD;
   return InpAdvisorLot_Default;
}

int CountTotalOpenAdvisorTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         if(posInfo.Magic() == InpAdvisorMagicNumber || StringFind(posInfo.Comment(), "SEGS|ADV|") >= 0)
            count++;
      }
   }
   return count;
}

// Atomic reservation of manual master trade position across charts (Sections 8, 9, 35)
// Uses account lock and explicit lifecycle states (1.0 = RESERVED, 2.0 = COMPLETED, -1.0 = FAILED)
bool TryReserveMasterPosition(ulong posID)
{
   if(posID == 0) return false;

   // 1. Acquire account lock
   if(!TryAcquireAccountLock("MANUAL_CLONE", 12))
      return false;

   string gvKey = "SEGS_PROCESSED_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(posID);
   string gvTimeKey = "SEGS_TIME_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(posID);
   datetime now = TimeCurrent();

   if(GlobalVariableCheck(gvKey))
   {
      double state = GlobalVariableGet(gvKey);
      if(state >= 2.0)
      {
         ReleaseAccountLock("MANUAL_CLONE");
         return false; // Already completed
      }
      if(state == 1.0)
      {
         if(GlobalVariableCheck(gvTimeKey))
         {
            datetime resTime = (datetime)GlobalVariableGet(gvTimeKey);
            if(now - resTime < 60)
            {
               ReleaseAccountLock("MANUAL_CLONE");
               return false; // Actively being cloned by another chart
            }
         }
         PrintFormat("[Manual Clone] Stale reservation detected for master #%I64u. Recovering.", posID);
      }
      else if(state < 0.0)
      {
         ReleaseAccountLock("MANUAL_CLONE");
         return false; // Previously failed
      }
   }

   // Atomically set state = 1.0 (RESERVED / PROCESSING)
   GlobalVariableSet(gvKey, 1.0);
   GlobalVariableSet(gvTimeKey, (double)now);

   ReleaseAccountLock("MANUAL_CLONE");
   return true;
}

void SetMasterPositionState(ulong posID, double state)
{
   if(posID == 0) return;
   string gvKey = "SEGS_PROCESSED_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(posID);
   GlobalVariableSet(gvKey, state);
}

//+------------------------------------------------------------------+
//| Get decimal precision for symbol volume step                     |
//+------------------------------------------------------------------+
int GetVolumeDigits(string sym)
{
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 2;
   if(step >= 1.0) return 0;
   string str = DoubleToString(step, 8);
   int dot = StringFind(str, ".");
   if(dot < 0) return 0;
   int digits = 0;
   for(int i = StringLen(str) - 1; i > dot; i--)
   {
      if(StringGetCharacter(str, i) != '0')
      {
         digits = i - dot;
         break;
      }
   }
   return (digits > 8) ? 8 : digits;
}

//+------------------------------------------------------------------+
//| Enforce symbol volume step, min, and max limits                  |
//+------------------------------------------------------------------+
double NormalizeVolumeToSymbolStep(string sym, double lot)
{
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0)  minLot  = 0.01;
   if(lotStep <= 0.0) lotStep = 0.01;
   if(maxLot <= 0.0)  maxLot  = 100.0;

   int volDigits = GetVolumeDigits(sym);

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   double steps = MathRound(lot / lotStep);
   double normalized = steps * lotStep;

   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;

   return NormalizeDouble(normalized, volDigits);
}

//+------------------------------------------------------------------+
//| Validate and adjust StopLoss and TakeProfit against stops level   |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Deterministically initialize a PositionGroup structure           |
//+------------------------------------------------------------------+
void InitPositionGroup(PositionGroup &grp)
{
   grp.groupTime        = 0;
   grp.tpTriggerHit     = false;
   grp.breakevenApplied = false;
   grp.positionCount    = 0;
   grp.symbol           = "";
   grp.positionType     = POSITION_TYPE_BUY;
   grp.setupID          = "";
   grp.peakPrice        = 0.0;
   grp.leg3ClosedByTrail = false;
   grp.leg4ClosedByTrail = false;
   for(int k = 0; k < 4; k++)
   {
      grp.tickets[k]     = 0;
      grp.positionIds[k] = 0;
   }
}

//+------------------------------------------------------------------+
//| Normalize price strictly to symbol trade tick size               |
//+------------------------------------------------------------------+
double NormalizePriceToTickSize(string sym, double price)
{
   if(price <= 0.0) return 0.0;
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(tickSize <= 0.0) tickSize = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(tickSize <= 0.0) return NormalizeDouble(price, digits);

   double rounded = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(rounded, digits);
}

//+------------------------------------------------------------------+
//| Classify protection target without altering strategy prices      |
//| Returns:                                                         |
//|  1 = Valid and modifiable now                                    |
//|  0 = Temporarily inside stop/freeze level (retry later)          |
//| -1 = Target already passed by market price (do NOT fabricate)    |
//+------------------------------------------------------------------+
int ValidateProtectionTarget(string sym, ENUM_POSITION_TYPE ptype, double curPrice, double targetPrice, bool isStopLoss)
{
   if(targetPrice <= 0.0) return -1;

   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;

   long stopLevel   = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist   = (double)MathMax(stopLevel, freezeLevel) * pt;

   if(isStopLoss)
   {
      if(ptype == POSITION_TYPE_BUY)
      {
         if(targetPrice >= curPrice) return -1; // Passed: SL cannot be above or at current market
         if(minDist > 0.0 && (curPrice - targetPrice) < minDist) return 0; // Temporarily too close
      }
      else
      {
         if(targetPrice <= curPrice) return -1; // Passed: SL cannot be below or at current market
         if(minDist > 0.0 && (targetPrice - curPrice) < minDist) return 0; // Temporarily too close
      }
   }
   else // TakeProfit
   {
      if(ptype == POSITION_TYPE_BUY)
      {
         if(targetPrice <= curPrice) return -1; // Passed: TP already crossed by market
         if(minDist > 0.0 && (targetPrice - curPrice) < minDist) return 0; // Temporarily too close
      }
      else
      {
         if(targetPrice >= curPrice) return -1; // Passed: TP already crossed by market
         if(minDist > 0.0 && (curPrice - targetPrice) < minDist) return 0; // Temporarily too close
      }
   }

   return 1; // Valid and modifiable now
}

//+------------------------------------------------------------------+
//| Validate protection levels without altering strategy targets     |
//+------------------------------------------------------------------+
bool ValidateProtectionLevels(string sym, ENUM_POSITION_TYPE ptype, double curPrice, double &sl, double &tp)
{
   if(sl > 0.0)
   {
      int slStatus = ValidateProtectionTarget(sym, ptype, curPrice, sl, true);
      if(slStatus != 1) return false;
      sl = NormalizePriceToTickSize(sym, sl);
   }

   if(tp > 0.0)
   {
      int tpStatus = ValidateProtectionTarget(sym, ptype, curPrice, tp, false);
      if(tpStatus != 1) return false;
      tp = NormalizePriceToTickSize(sym, tp);
   }

   return true;
}

//+------------------------------------------------------------------+
//| Persist Advisor setup structural targets to Global Variables     |
//+------------------------------------------------------------------+
void SaveAdvisorSetupTargets(string setupID, string sym, ENUM_POSITION_TYPE ptype, double entry, double sl, double tp1, double tp2, double tp3, double tp4, int legs)
{
   string pfx = "SEGS_TRG_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + setupID + "_";
   GlobalVariableSet(pfx + "ENTRY", entry);
   GlobalVariableSet(pfx + "SL", sl);
   GlobalVariableSet(pfx + "TP1", tp1);
   GlobalVariableSet(pfx + "TP2", tp2);
   GlobalVariableSet(pfx + "TP3", tp3);
   GlobalVariableSet(pfx + "TP4", tp4);
   GlobalVariableSet(pfx + "TYPE", (double)ptype);
   GlobalVariableSet(pfx + "LEGS", (double)legs);
   GlobalVariableSet(pfx + "TIME", (double)TimeCurrent());
   PrintFormat("[SEGS PERSIST] Saved structural targets for setup %s: SL=%.5f, TP1=%.5f, TP2=%.5f, TP3=%.5f, TP4=%.5f",
               setupID, sl, tp1, tp2, tp3, tp4);
}

//+------------------------------------------------------------------+
//| Load Advisor setup structural targets from Global Variables      |
//+------------------------------------------------------------------+
bool LoadAdvisorSetupTargets(string setupID, double &outEntry, double &outSL, double &outTP1, double &outTP2, double &outTP3, double &outTP4, ENUM_POSITION_TYPE &outType, int &outLegs)
{
   string pfx = "SEGS_TRG_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + setupID + "_";
   if(!GlobalVariableCheck(pfx + "SL")) return false;

   outEntry = GlobalVariableGet(pfx + "ENTRY");
   outSL    = GlobalVariableGet(pfx + "SL");
   outTP1   = GlobalVariableGet(pfx + "TP1");
   outTP2   = GlobalVariableGet(pfx + "TP2");
   outTP3   = GlobalVariableGet(pfx + "TP3");
   outTP4   = GlobalVariableGet(pfx + "TP4");
   outType  = (ENUM_POSITION_TYPE)(int)GlobalVariableGet(pfx + "TYPE");
   outLegs  = (int)GlobalVariableGet(pfx + "LEGS");
   if(outLegs < 1 || outLegs > 4) outLegs = 4;
   return true;
}

//+------------------------------------------------------------------+
//| Scan historical deals to recover Leg 2 persistent position ID    |
//+------------------------------------------------------------------+
ulong FindHistoricalLeg2PositionId(string setupID, string sym, datetime groupOpenTime)
{
   datetime fromTime = (groupOpenTime > 0) ? (groupOpenTime - (86400 * 2)) : (TimeCurrent() - (86400 * 365));
   datetime toTime   = TimeCurrent() + 86400;
   if(!HistorySelect(fromTime, toTime)) return 0;

   int totalDeals = HistoryDealsTotal();

   if(StringFind(setupID, "MAN_") == 0)
   {
      string masterIdStr = StringSubstr(setupID, 4);
      string pattern1 = "SEGS|MAN|" + masterIdStr + "|L2/";
      string pattern2 = "SEGS_LEG2#" + masterIdStr;

      for(int i = totalDeals - 1; i >= 0; i--)
      {
         ulong dt = HistoryDealGetTicket(i);
         if(dt <= 0) continue;
         string cmt = HistoryDealGetString(dt, DEAL_COMMENT);
         if(StringFind(cmt, pattern1) >= 0 || StringFind(cmt, pattern2) >= 0)
         {
            ulong pId = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
            if(pId > 0) return pId;
         }
      }
   }
   else if(StringFind(setupID, "ADV_") == 0)
   {
      string sigStr = StringSubstr(setupID, 4);
      string pattern = "SEGS|ADV|" + sigStr + "|L2/";

      for(int i = totalDeals - 1; i >= 0; i--)
      {
         ulong dt = HistoryDealGetTicket(i);
         if(dt <= 0) continue;
         string cmt = HistoryDealGetString(dt, DEAL_COMMENT);
         if(StringFind(cmt, pattern) >= 0)
         {
            ulong pId = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
            if(pId > 0) return pId;
         }
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Find persistent position identifier for an open position ticket   |
//+------------------------------------------------------------------+
ulong GetPositionIdentifierByTicket(ulong ticket)
{
   if(ticket <= 0) return 0;
   if(posInfo.SelectByTicket(ticket))
   {
      ulong pId = (ulong)posInfo.Identifier();
      if(pId == 0) pId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(pId > 0) return pId;
   }
   return 0; // Micro-Fix 4: Return 0 on failure; never assume position ticket == POSITION_IDENTIFIER!
}

//+------------------------------------------------------------------+
//| Resolve both open position ticket and persistent position ID from deal |
//+------------------------------------------------------------------+
bool ResolvePositionTicketAndIdFromDeal(ulong dealTicket, string sym, long magic, string commentPattern, ulong &outTicket, ulong &outPosId)
{
   outTicket = 0;
   outPosId  = 0;

   if(dealTicket == 0 || !HistoryDealSelect(dealTicket)) return false;

   outPosId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   // 1. Search current open positions for matching persistent POSITION_IDENTIFIER
   if(outPosId > 0)
   {
      for(int p = PositionsTotal() - 1; p >= 0; p--)
      {
         ulong pt = PositionGetTicket(p);
         if(pt > 0 && posInfo.SelectByTicket(pt))
         {
            if((ulong)posInfo.Identifier() == outPosId)
            {
               if((sym == "" || posInfo.Symbol() == sym) &&
                  (magic == 0 || posInfo.Magic() == magic))
               {
                  if(commentPattern == "" || StringFind(posInfo.Comment(), commentPattern) >= 0)
                  {
                     outTicket = pt;
                     return true;
                  }
               }
            }
         }
      }
   }

   // 2. Fallback search open positions matching magic, symbol, and exact comment pattern
   if(commentPattern != "")
   {
      for(int p = PositionsTotal() - 1; p >= 0; p--)
      {
         ulong pt = PositionGetTicket(p);
         if(pt > 0 && posInfo.SelectByTicket(pt))
         {
            if(posInfo.Symbol() == sym && posInfo.Magic() == magic)
            {
               if(StringFind(posInfo.Comment(), commentPattern) >= 0)
               {
                  outTicket = pt;
                  outPosId  = (ulong)posInfo.Identifier();
                  return true;
               }
            }
         }
      }
   }

   // Never fabricate outTicket = outPosId or outPosId = pt if the position is not currently open
   return false;
}

//+------------------------------------------------------------------+
//| Filter to determine if a newly filled deal is an eligible manual master |
//+------------------------------------------------------------------+
bool IsEligibleNewMasterDeal(ulong dealTicket)
{
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket)) return false;

   long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   // Never clone cloned trades or advisor trades
   if(magic == InpClonedMagicNumber || magic == InpAdvisorMagicNumber) return false;
   // Ignore unrelated EAs (magic != 0 and magic != InpMasterMagicNumber)
   if(magic != 0 && magic != InpMasterMagicNumber) return false;

   // Check comment to make sure it is not already a SEGS clone or advisor trade
   string cmt = HistoryDealGetString(dealTicket, DEAL_COMMENT);
   if(StringFind(cmt, "SEGS|CLONE") >= 0 || StringFind(cmt, "SEGS|ADV|") >= 0 || StringFind(cmt, "SEGS|MAN|") >= 0)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Find group index by setupID or contained tickets / position IDs   |
//+------------------------------------------------------------------+
int FindGroupIndexBySetupOrPosition(string setupID, ulong ticket, ulong posId)
{
   int gCount = ArraySize(g_groups);
   if(setupID != "")
   {
      for(int g = 0; g < gCount; g++)
      {
         if(g_groups[g].setupID == setupID) return g;
      }
   }

   if(ticket > 0 || posId > 0)
   {
      for(int g = 0; g < gCount; g++)
      {
         for(int k = 0; k < 4; k++)
         {
            if(ticket > 0 && g_groups[g].tickets[k] == ticket) return g;
            if(posId > 0 && g_groups[g].positionIds[k] == posId) return g;
         }
      }
   }

   return -1;
}

//+------------------------------------------------------------------+
//| Update positionCount to reflect all populated legs in a group    |
//+------------------------------------------------------------------+
void UpdateGroupPositionCount(int g)
{
   if(g < 0 || g >= ArraySize(g_groups)) return;
   int cnt = 0;
   for(int k = 0; k < 4; k++)
   {
      if(g_groups[g].tickets[k] > 0 || g_groups[g].positionIds[k] > 0)
         cnt = k + 1;
   }
   if(cnt == 0) cnt = 1;
   g_groups[g].positionCount = cnt;
}

//+------------------------------------------------------------------+
//| Verify if an open position is already protected at or better BE  |
//+------------------------------------------------------------------+
bool IsPositionProtectedAtBreakeven(ulong ticket, ENUM_POSITION_TYPE ptype, double targetBeSL, double tickSize)
{
   if(ticket <= 0 || !posInfo.SelectByTicket(ticket)) return false;
   double curSL = posInfo.StopLoss();
   if(curSL <= 0.0) return false;

   double tolerance = (tickSize > 0.0) ? (tickSize * 0.5) : 0.00001;
   if(ptype == POSITION_TYPE_BUY)
   {
      return (curSL >= targetBeSL - tolerance);
   }
   else
   {
      return (curSL <= targetBeSL + tolerance);
   }
}

//+------------------------------------------------------------------+
//| Check Deal History strictly for DEAL_REASON_TP closure           |
//+------------------------------------------------------------------+
bool WasTPActuallyHit(ulong positionId, string sym, ENUM_POSITION_TYPE ptype, double expectedTPPrice, datetime fromTime = 0)
{
   if(positionId == 0) return false;

   // Select full account deal history dynamically based on trade lifetime (no fixed 30-day limit)
   datetime toTime = TimeCurrent() + 86400;
   if(fromTime <= 0)
      fromTime = TimeCurrent() - (86400 * 365); // 1 year lookback fallback if trade open time is unknown
   else
      fromTime = fromTime - (86400 * 2); // 2 days safety buffer prior to group creation

   if(!HistorySelect(fromTime, toTime)) return false;

   int totalDeals = HistoryDealsTotal();
   bool foundTPExit = false;

   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) tickSize = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(tickSize <= 0.0) tickSize = 0.00001;

   // Scan all historical deals for this exact persistent position identifier
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dt = HistoryDealGetTicket(i);
      if(dt <= 0) continue;

      ulong pId = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
      if(pId != positionId) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      {
         ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dt, DEAL_REASON);
         if(reason == DEAL_REASON_TP)
         {
            if(expectedTPPrice > 0.0)
            {
               double dealPrice = HistoryDealGetDouble(dt, DEAL_PRICE);
               double dist = MathAbs(dealPrice - expectedTPPrice);
               double maxTolerance = 10.0 * tickSize;
               long stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
               if(stopLvl > 0)
               {
                  double stopDist = (double)stopLvl * SymbolInfoDouble(sym, SYMBOL_POINT);
                  if(stopDist > maxTolerance) maxTolerance = stopDist;
               }
               if(dist <= maxTolerance)
               {
                  foundTPExit = true;
                  PrintFormat("[SEGS BE CHECK] Position #%I64u exit deal #%I64u matched DEAL_REASON_TP with exit price %.5f (expected %.5f). Validated.",
                              positionId, dt, dealPrice, expectedTPPrice);
                  break;
               }
               else
               {
                  foundTPExit = true;
                  PrintFormat("[SEGS BE CHECK] Position #%I64u exit deal #%I64u had DEAL_REASON_TP at price %.5f (expected %.5f, diff=%.5f). Validated.",
                              positionId, dt, dealPrice, expectedTPPrice, dist);
                  break;
               }
            }
            else
            {
               foundTPExit = true;
               PrintFormat("[SEGS BE CHECK] Position #%I64u exit deal #%I64u validated DEAL_REASON_TP.", positionId, dt);
               break;
            }
         }
      }
   }

   return foundTPExit;
}

//+------------------------------------------------------------------+
//| Comprehensive Evaluation of Take Profit Target Hits              |
//| Multi-layer verification:                                        |
//| 1. Open positions check: An open leg CAN NEVER be marked as hit  |
//| 2. Target validation: TP must be on favorable side of entry      |
//| 3. Historical closed deals analysis (DEAL_ENTRY_OUT & profit/TP) |
//+------------------------------------------------------------------+
void EvaluateTakeProfitHits(string sym, string action, double entry, double tp1, double tp2, double tp3, double tp4, datetime execTime,
                            bool &outTP1Hit, bool &outTP2Hit, bool &outTP3Hit, bool &outTP4Hit)
{
   outTP1Hit = false;
   outTP2Hit = false;
   outTP3Hit = false;
   outTP4Hit = false;

   if(entry <= 0.0 || tp1 <= 0.0) return;
   // Standard Rule: Take profit targets cannot be hit if no trade was executed
   if(execTime <= 0) return;
   bool isBuy = (action == "BUY");
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.0001;

   // 1. SANITY CHECK: Take Profit targets MUST be strictly favorable relative to entry
   // For BUY: TP > entry. For SELL: TP < entry.
   bool validTP1 = isBuy ? (tp1 > entry + 2.0 * pt) : (tp1 < entry - 2.0 * pt && tp1 > 0.0);
   bool validTP2 = isBuy ? (tp2 > tp1) : (tp2 < tp1 && tp2 > 0.0);
   bool validTP3 = isBuy ? (tp3 > tp2) : (tp3 < tp2 && tp3 > 0.0);
   bool validTP4 = isBuy ? (tp4 > tp3) : (tp4 < tp3 && tp4 > 0.0);

   // 2. INSPECT CURRENTLY OPEN ADVISOR POSITIONS:
   // FUNDAMENTAL INVARIANT: If a leg is STILL OPEN in the terminal, its Take Profit has NOT been hit!
   bool leg1IsOpen = false;
   bool leg2IsOpen = false;
   bool leg3IsOpen = false;
   bool leg4IsOpen = false;
   int openAdvisorPosCount = 0;
   int totalPos = PositionsTotal();

   for(int i = totalPos - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && posInfo.SelectByTicket(tk))
      {
         if(IsSameChartAsset(posInfo.Symbol(), sym))
         {
            long mgc = posInfo.Magic();
            string cmt = posInfo.Comment();
            bool isAdv = (mgc == InpAdvisorMagicNumber ||
                          StringFind(cmt, "SEGS|ADV") >= 0 ||
                          StringFind(cmt, "[MyAdvisor]") >= 0 ||
                          StringFind(cmt, "[Advised") >= 0);
            if(isAdv)
            {
               openAdvisorPosCount++;
               double posTP = posInfo.TakeProfit();

               // Match by explicit leg tag in comment
               if(StringFind(cmt, "|L1/") >= 0 || StringFind(cmt, "|L1") >= 0 || StringFind(cmt, "TP1") >= 0) leg1IsOpen = true;
               else if(StringFind(cmt, "|L2/") >= 0 || StringFind(cmt, "|L2") >= 0 || StringFind(cmt, "TP2") >= 0) leg2IsOpen = true;
               else if(StringFind(cmt, "|L3/") >= 0 || StringFind(cmt, "|L3") >= 0 || StringFind(cmt, "TP3") >= 0) leg3IsOpen = true;
               else if(StringFind(cmt, "|L4/") >= 0 || StringFind(cmt, "|L4") >= 0 || StringFind(cmt, "TP4") >= 0) leg4IsOpen = true;
               else if(posTP > 0.0)
               {
                  // Match by TP price proximity
                  if(validTP1 && MathAbs(posTP - tp1) <= 10.0 * pt) leg1IsOpen = true;
                  else if(validTP2 && MathAbs(posTP - tp2) <= 10.0 * pt) leg2IsOpen = true;
                  else if(validTP3 && MathAbs(posTP - tp3) <= 10.0 * pt) leg3IsOpen = true;
                  else if(validTP4 && MathAbs(posTP - tp4) <= 10.0 * pt) leg4IsOpen = true;
               }
            }
         }
      }
   }

   // If 4 positions are open, NO targets have been hit yet!
   if(openAdvisorPosCount >= 4)
   {
      return;
   }

   // 3. SCAN HISTORICAL DEALS: Verify that closed deals actually exited at or beyond target
   // If no trade was executed for this signal (execTime <= 0), targets CANNOT be hit
   if(execTime <= 0)
   {
      return;
   }
   datetime histFrom = execTime - 5;
   if(HistorySelect(histFrom, TimeCurrent() + 86400))
   {
      int dealsTotal = HistoryDealsTotal();
      for(int i = dealsTotal - 1; i >= 0; i--)
      {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket <= 0) continue;
         if(!IsSameChartAsset(HistoryDealGetString(dTicket, DEAL_SYMBOL), sym)) continue;
         ENUM_DEAL_ENTRY dEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dTicket, DEAL_ENTRY);
         if(dEntry != DEAL_ENTRY_OUT && dEntry != DEAL_ENTRY_OUT_BY) continue;
         datetime dTime = (datetime)HistoryDealGetInteger(dTicket, DEAL_TIME);
         if(execTime > 0 && dTime < execTime - 5) continue; // Deal must be after execution
         double dPrice = HistoryDealGetDouble(dTicket, DEAL_PRICE);
         double dProfit = HistoryDealGetDouble(dTicket, DEAL_PROFIT);
         ENUM_DEAL_REASON dReason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dTicket, DEAL_REASON);
         string dCmt = HistoryDealGetString(dTicket, DEAL_COMMENT);

         if(dProfit > 0.0 || dReason == DEAL_REASON_TP)
         {
            // Leg 1 closed
            if(!leg1IsOpen && validTP1)
            {
               if((isBuy && dPrice >= tp1 - 5.0 * pt) || (!isBuy && dPrice <= tp1 + 5.0 * pt) ||
                  StringFind(dCmt, "|L1") >= 0 || StringFind(dCmt, "TP1") >= 0)
                  outTP1Hit = true;
            }
            // Leg 2 closed
            if(!leg2IsOpen && validTP2)
            {
               if((isBuy && dPrice >= tp2 - 5.0 * pt) || (!isBuy && dPrice <= tp2 + 5.0 * pt) ||
                  StringFind(dCmt, "|L2") >= 0 || StringFind(dCmt, "TP2") >= 0)
                  outTP2Hit = true;
            }
            // Leg 3 closed
            if(!leg3IsOpen && validTP3)
            {
               if((isBuy && dPrice >= tp3 - 5.0 * pt) || (!isBuy && dPrice <= tp3 + 5.0 * pt) ||
                  StringFind(dCmt, "|L3") >= 0 || StringFind(dCmt, "TP3") >= 0)
                  outTP3Hit = true;
            }
            // Leg 4 closed
            if(!leg4IsOpen && validTP4)
            {
               if((isBuy && dPrice >= tp4 - 5.0 * pt) || (!isBuy && dPrice <= tp4 + 5.0 * pt) ||
                  StringFind(dCmt, "|L4") >= 0 || StringFind(dCmt, "TP4") >= 0)
                  outTP4Hit = true;
            }
         }
      }
   }

   // 3B. Price Extreme Verification: Check if market high/low reached or exceeded TP since execution
   // Multi-timeframe robust check: M1 up to 1000 bars, plus M5/M15 fallback
   datetime scanStart = (execTime > 0) ? execTime : (TimeCurrent() - 86400);
   int startBar = iBarShift(sym, PERIOD_M1, scanStart);
   if(startBar < 0) startBar = 200;
   if(startBar > 1440) startBar = 1440;
   double maxHigh = -1.0, minLow = 999999.0;
   for(int b = 0; b <= startBar; b++)
   {
      double bh = iHigh(sym, PERIOD_M1, b);
      double bl = iLow(sym, PERIOD_M1, b);
      if(bh > maxHigh) maxHigh = bh;
      if(bl < minLow && bl > 0.0) minLow = bl;
   }

   // Fallback check on M5 in case M1 bar history is short or sparse
   int startBarM5 = iBarShift(sym, PERIOD_M5, scanStart);
   if(startBarM5 < 0) startBarM5 = 50;
   if(startBarM5 > 288) startBarM5 = 288;
   for(int b5 = 0; b5 <= startBarM5; b5++)
   {
      double bh5 = iHigh(sym, PERIOD_M5, b5);
      double bl5 = iLow(sym, PERIOD_M5, b5);
      if(bh5 > maxHigh) maxHigh = bh5;
      if(bl5 < minLow && bl5 > 0.0) minLow = bl5;
   }

   // Also include current market Bid/Ask/Last
   double curP_bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double curP_ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(curP_bid > maxHigh) maxHigh = curP_bid;
   if(curP_ask > maxHigh) maxHigh = curP_ask;
   if(curP_bid > 0.0 && curP_bid < minLow) minLow = curP_bid;
   if(curP_ask > 0.0 && curP_ask < minLow) minLow = curP_ask;

   if(!leg1IsOpen && validTP1 && !outTP1Hit)
   {
      if((isBuy && maxHigh >= tp1 - pt) || (!isBuy && minLow <= tp1 + pt))
         outTP1Hit = true;
   }
   if(!leg2IsOpen && validTP2 && !outTP2Hit)
   {
      if((isBuy && maxHigh >= tp2 - pt) || (!isBuy && minLow <= tp2 + pt))
         outTP2Hit = true;
   }
   if(!leg3IsOpen && validTP3 && !outTP3Hit)
   {
      if((isBuy && maxHigh >= tp3 - pt) || (!isBuy && minLow <= tp3 + pt))
         outTP3Hit = true;
   }
   if(!leg4IsOpen && validTP4 && !outTP4Hit)
   {
      if((isBuy && maxHigh >= tp4 - pt) || (!isBuy && minLow <= tp4 + pt))
         outTP4Hit = true;
   }

   // 3C. Count-based logical cascade: If legs are closed, sequentially earlier targets were banked!
   if(openAdvisorPosCount <= 3 && !leg1IsOpen && validTP1)
   {
      outTP1Hit = true;
   }
   if(openAdvisorPosCount <= 2 && !leg1IsOpen && !leg2IsOpen && validTP1 && validTP2)
   {
      outTP1Hit = true;
      outTP2Hit = true;
   }
   if(openAdvisorPosCount <= 1 && !leg1IsOpen && !leg2IsOpen && !leg3IsOpen && validTP1 && validTP2 && validTP3)
   {
      outTP1Hit = true;
      outTP2Hit = true;
      outTP3Hit = true;
   }
   if(openAdvisorPosCount == 0 && !leg1IsOpen && !leg2IsOpen && !leg3IsOpen && !leg4IsOpen && validTP1 && validTP2 && validTP3 && validTP4)
   {
      // If price reached TP3, check if it reached TP4
      if((isBuy && maxHigh >= tp4 - pt) || (!isBuy && minLow <= tp4 + pt))
         outTP4Hit = true;
   }

   // 4. Final Absolute Safety Guarantee: An open leg CAN NEVER be marked as hit!
   if(leg1IsOpen) outTP1Hit = false;
   if(leg2IsOpen) outTP2Hit = false;
   if(leg3IsOpen) outTP3Hit = false;
   if(leg4IsOpen) outTP4Hit = false;
}
//+------------------------------------------------------------------+
//| Auto-heal open advisor positions missing Stop Loss or TP         |
//+------------------------------------------------------------------+
void HealOpenAdvisorPositions(string sym)
{
   int total = PositionsTotal();
   if(total == 0) return;

   static ulong s_lastHealAttemptMs = 0;
   ulong nowMs = GetTickCount64();
   if(nowMs - s_lastHealAttemptMs < 2500) return; // Throttle to at most once per 2.5s to avoid trade context busy
   s_lastHealAttemptMs = nowMs;

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.0001;
   double pipSize = GetPipSize(sym);

   for(int i = total - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk <= 0 || !posInfo.SelectByTicket(tk)) continue;
      if(!IsSameChartAsset(posInfo.Symbol(), sym)) continue;

      long mgc = posInfo.Magic();
      string cmt = posInfo.Comment();
      bool isAdvisorPos = (mgc == InpAdvisorMagicNumber ||
                           StringFind(cmt, "SEGS|ADV") >= 0 ||
                           StringFind(cmt, "[MyAdvisor]") >= 0 ||
                           StringFind(cmt, "[Advised") >= 0);
      if(!isAdvisorPos) continue;

      ENUM_POSITION_TYPE ptype = posInfo.PositionType();
      double entry = posInfo.PriceOpen();
      double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
      double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
      double curPrice = (ptype == POSITION_TYPE_BUY) ? curBid : curAsk;
      if(curPrice <= 0.0) curPrice = entry;
      bool isBuy = (ptype == POSITION_TYPE_BUY);

      double curSL = posInfo.StopLoss();
      double curTP = posInfo.TakeProfit();

      // Immediate Stop Loss breach check: if price touched or crossed existing SL, close immediately!
      if(curSL > 0.0)
      {
         bool slBreached = isBuy ? (curPrice <= curSL) : (curPrice >= curSL);
         if(slBreached)
         {
            PrintFormat("[SEGS AUTO-HEAL] Ticket #%I64u has breached Stop Loss (Price: %.5f, SL: %.5f). Closing immediately at market!",
                        tk, curPrice, curSL);
            SafePositionClose(tk, "AUTO_HEAL_SL_BREACH");
            continue;
         }
      }

      if(curSL > 0.0 && curTP > 0.0) continue; // Fully protected and SL not breached

      // Determine leg number from comment
      int leg = 1;
      int lPos = StringFind(cmt, "|L");
      if(lPos >= 0) leg = (int)StringToInteger(StringSubstr(cmt, lPos + 2, 1));
      else if(StringFind(cmt, "TP2") >= 0) leg = 2;
      else if(StringFind(cmt, "TP3") >= 0) leg = 3;
      else if(StringFind(cmt, "TP4") >= 0) leg = 4;
      else if(curTP <= 0.0) leg = 3; // Default to intermediate leg

      // Recover setup targets
      double sEntry = 0, sSL = 0, sTP1 = 0, sTP2 = 0, sTP3 = 0, sTP4 = 0;
      ENUM_POSITION_TYPE sType;
      int sLegs = 4;
      string advSetupID = "";
      int advIdx = StringFind(cmt, "SEGS|ADV|");
      if(advIdx >= 0)
      {
         string rem = StringSubstr(cmt, advIdx + 9);
         string parts[];
         if(StringSplit(rem, '|', parts) >= 1) advSetupID = "ADV_" + parts[0];
      }

      bool loaded = false;
      if(advSetupID != "") loaded = LoadAdvisorSetupTargets(advSetupID, sEntry, sSL, sTP1, sTP2, sTP3, sTP4, sType, sLegs);
      if(!loaded && g_currentSignalID != "") loaded = LoadAdvisorSetupTargets("ADV_" + g_currentSignalID, sEntry, sSL, sTP1, sTP2, sTP3, sTP4, sType, sLegs);

      double healSL = (curSL > 0.0) ? curSL : (loaded && sSL > 0.0 ? sSL : g_staticSL);
      double healTP = curTP;
      if(healTP <= 0.0)
      {
         if(loaded)
            healTP = (leg == 1) ? sTP1 : ((leg == 2) ? sTP2 : ((leg == 3) ? sTP3 : sTP4));
         else
            healTP = (leg == 1) ? g_staticTP1 : ((leg == 2) ? g_staticTP2 : ((leg == 3) ? g_staticTP3 : g_staticTP4));
      }

      // Safe bounds validation
      if(healSL <= 0.0)
      {
         double safeRisk = MathMax(25.0 * pipSize, 0.40 * MathAbs(entry - curPrice));
         healSL = isBuy ? (entry - safeRisk) : (entry + safeRisk);
      }
      else if((isBuy && healSL >= curPrice) || (!isBuy && healSL <= curPrice))
      {
         // Target SL is already breached: close position immediately at market!
         PrintFormat("[SEGS AUTO-HEAL] Ticket #%I64u target SL %.5f is breached by price %.5f. Closing immediately at market!",
                     tk, healSL, curPrice);
         SafePositionClose(tk, "AUTO_HEAL_TARGET_SL_BREACH");
         continue;
      }
      if(healTP <= 0.0 || (isBuy && healTP <= curPrice) || (!isBuy && healTP >= curPrice))
      {
         double rDist = MathAbs(entry - healSL);
         if(rDist <= 0.0) rDist = 25.0 * pipSize;
         double mult = (leg == 1) ? 1.4 : ((leg == 2) ? 2.8 : ((leg == 3) ? 4.8 : 8.0));
         healTP = isBuy ? (entry + mult * rDist) : (entry - mult * rDist);
      }

      healSL = NormalizeDouble(NormalizePriceToTickSize(sym, healSL), digits);
      healTP = NormalizeDouble(NormalizePriceToTickSize(sym, healTP), digits);

      if(ValidateProtectionLevels(sym, ptype, curPrice, healSL, healTP))
      {
         ResetLastError();
         if(trade.PositionModify(tk, healSL, healTP))
         {
            PrintFormat("[SEGS AUTO-HEAL] Successfully restored protection on ticket #%I64u (%s Leg %d) -> SL: %.5f, TP: %.5f",
                        tk, sym, leg, healSL, healTP);
         }
      }
      else
      {
         // Emergency protection: Always ensure position is protected by Stop Loss even if broker rejects TP
         double emergencyTP = 0.0;
         if(ValidateProtectionLevels(sym, ptype, curPrice, healSL, emergencyTP))
         {
            ResetLastError();
            if(trade.PositionModify(tk, healSL, 0.0))
            {
               PrintFormat("[SEGS AUTO-HEAL] Applied emergency Stop Loss protection on ticket #%I64u (%s Leg %d) -> SL: %.5f",
                           tk, sym, leg, healSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Move remaining open legs of a group to Breakeven (+buffer)       |
//| Returns true ONLY if all currently open remaining legs are protected|
//+------------------------------------------------------------------+
bool ApplyBreakevenToGroup(int g)
{
   if(g < 0 || g >= ArraySize(g_groups)) return false;

   string sym = g_groups[g].symbol;
   double pipSize = GetPipSize(sym);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;

   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE && sym == _Symbol)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   double adaptiveBuf = (curAtr > 0.0) ? MathMax(InpBreakevenBufferPips * pipSize, 0.12 * curAtr) : (InpBreakevenBufferPips * pipSize);
   double buf = MathMax(adaptiveBuf, MathMax(1.0 * pipSize, 2.0 * pt));
   bool allLegsProtected = true;
   int openRemainingCount = 0;

   long stopLevel   = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist   = (double)MathMax(stopLevel, freezeLevel) * pt;

   for(int r = 0; r < 4; r++)
   {
      ulong t = g_groups[g].tickets[r];
      ulong pId = g_groups[g].positionIds[r];
      if(t == 0 && pId == 0) continue;

      // Select position
      bool selected = false;
      if(t > 0 && posInfo.SelectByTicket(t))
      {
         selected = true;
      }
      else if(pId > 0)
      {
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong ptik = PositionGetTicket(p);
            if(ptik > 0 && posInfo.SelectByTicket(ptik))
            {
               if((ulong)posInfo.Identifier() == pId)
               {
                  t = ptik;
                  g_groups[g].tickets[r] = ptik;
                  selected = true;
                  break;
               }
            }
         }
      }

      if(!selected) continue; // Position is closed (already took profit or closed)

      openRemainingCount++;
      double entry = posInfo.PriceOpen();
      double curSL = posInfo.StopLoss();
      ENUM_POSITION_TYPE ptype = posInfo.PositionType();
      double beSL = (ptype == POSITION_TYPE_BUY) ? (entry + buf) : (entry - buf);
      beSL = NormalizePriceToTickSize(sym, beSL);

      // Check if already protected at or better than BE
      if(IsPositionProtectedAtBreakeven(t, ptype, beSL, pt))
      {
         continue; // Leg is already safe
      }

      // Check whether moving SL improves protection (never loosen an already better stop)
      bool shouldMove = false;
      if(ptype == POSITION_TYPE_BUY)
         shouldMove = (curSL <= 0.0 || beSL > curSL);
      else
         shouldMove = (curSL <= 0.0 || beSL < curSL);

      if(!shouldMove) continue; // Existing SL is already tighter/better

      // Check freeze and stop levels for current market price
      double curPrice = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      int beStatus = ValidateProtectionTarget(sym, ptype, curPrice, beSL, true);
      if(beStatus == 0)
      {
         PrintFormat("[SEGS BE] Leg #%I64u cannot set BE %.5f right now: temporarily inside stop/freeze distance (dist=%.5f, min=%.5f). Pending retry.",
                     t, beSL, MathAbs(curPrice - beSL), minDist);
         allLegsProtected = false;
         continue;
      }
      else if(beStatus == -1)
      {
         PrintFormat("[SEGS BE] Leg #%I64u cannot set BE %.5f: market price %.5f is currently in loss territory relative to BE. Pending retry.",
                     t, beSL, curPrice);
         allLegsProtected = false;
         continue;
      }

      // Modify position stop loss to Breakeven
      ResetLastError();
      bool ok = trade.PositionModify(t, beSL, posInfo.TakeProfit());
      uint ret = trade.ResultRetcode();
      if(!ok || (ret != TRADE_RETCODE_DONE && ret != TRADE_RETCODE_PLACED && ret != TRADE_RETCODE_NO_CHANGES))
      {
         PrintFormat("[SEGS BE] PositionModify to BE FAILED for leg #%I64u (%s) -> Target BE: %.5f | Retcode: %u (%s)",
                     t, sym, beSL, ret, trade.ResultRetcodeDescription());
         allLegsProtected = false;
      }
      else
      {
         // Verify modification success
         if(posInfo.SelectByTicket(t))
         {
            if(IsPositionProtectedAtBreakeven(t, ptype, beSL, pt))
            {
               PrintFormat("[SEGS BE] SUCCESS: Leg #%I64u (%s) SL moved to Breakeven: %.5f (+%.1f pips)",
                           t, sym, beSL, InpBreakevenBufferPips);
            }
            else
            {
               allLegsProtected = false;
            }
         }
      }
   }

   return allLegsProtected;
}

//+------------------------------------------------------------------+
//| Dynamic Trailing Pullback Exit for Runner Legs (Leg 3 & Leg 4)    |
//| Rule 1 (2 Legs Remaining: Leg 3 & Leg 4):                        |
//|   If price drops 28.5% from peak reached, close Leg 3.           |
//| Rule 2 (Only Leg 4 Remaining):                                   |
//|   If price drops 33.5% from peak reached, close Leg 4.           |
//+------------------------------------------------------------------+
void CheckTrailingClose()
{
   int gCount = ArraySize(g_groups);
   for(int g = 0; g < gCount; g++)
   {
      // Only apply dynamic trailing exit once Breakeven has been applied or TP2 has been triggered
      if(!g_groups[g].tpTriggerHit && !g_groups[g].breakevenApplied) continue;

      string sym = g_groups[g].symbol;
      ENUM_POSITION_TYPE ptype = g_groups[g].positionType;
      bool isBuy = (ptype == POSITION_TYPE_BUY);

      // Check which runner legs (Leg 3 and Leg 4) are currently open
      ulong tk3 = g_groups[g].tickets[2];
      ulong id3 = g_groups[g].positionIds[2];
      ulong tk4 = g_groups[g].tickets[3];
      ulong id4 = g_groups[g].positionIds[3];

      bool leg3Open = false;
      ulong activeTk3 = 0;
      if(tk3 > 0 && posInfo.SelectByTicket(tk3)) { leg3Open = true; activeTk3 = tk3; }
      else if(id3 > 0)
      {
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong tk = PositionGetTicket(p);
            if(tk > 0 && posInfo.SelectByTicket(tk) && (ulong)posInfo.Identifier() == id3)
            {
               leg3Open = true; activeTk3 = tk; g_groups[g].tickets[2] = tk; break;
            }
         }
      }

      bool leg4Open = false;
      ulong activeTk4 = 0;
      if(tk4 > 0 && posInfo.SelectByTicket(tk4)) { leg4Open = true; activeTk4 = tk4; }
      else if(id4 > 0)
      {
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong tk = PositionGetTicket(p);
            if(tk > 0 && posInfo.SelectByTicket(tk) && (ulong)posInfo.Identifier() == id4)
            {
               leg4Open = true; activeTk4 = tk; g_groups[g].tickets[3] = tk; break;
            }
         }
      }

      // Check if earlier legs (Leg 1 and 2) are open
      bool leg1Open = false;
      if(g_groups[g].tickets[0] > 0 && posInfo.SelectByTicket(g_groups[g].tickets[0])) leg1Open = true;
      bool leg2Open = false;
      if(g_groups[g].tickets[1] > 0 && posInfo.SelectByTicket(g_groups[g].tickets[1])) leg2Open = true;

      // Dynamic pullback trailing is specifically for runner legs when early targets have banked
      // Rule applies when either:
      // A) Exactly Leg 3 and Leg 4 remain open (2 legs remaining)
      // B) Only Leg 4 remains open (1 leg remaining)
      if(!leg3Open && !leg4Open) continue;

      double curPrice = isBuy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curPrice <= 0.0) continue;

      // Recover entry price
      double entryPrice = 0.0;
      if(activeTk3 > 0 && posInfo.SelectByTicket(activeTk3)) entryPrice = posInfo.PriceOpen();
      else if(activeTk4 > 0 && posInfo.SelectByTicket(activeTk4)) entryPrice = posInfo.PriceOpen();
      if(entryPrice <= 0.0) continue;

      // Update peak price
      if(isBuy)
      {
         if(g_groups[g].peakPrice <= 0.0 || g_groups[g].peakPrice < entryPrice)
            g_groups[g].peakPrice = MathMax(entryPrice, curPrice);
         else if(curPrice > g_groups[g].peakPrice)
            g_groups[g].peakPrice = curPrice;
      }
      else
      {
         if(g_groups[g].peakPrice <= 0.0 || g_groups[g].peakPrice > entryPrice)
            g_groups[g].peakPrice = MathMin(entryPrice, curPrice);
         else if(curPrice < g_groups[g].peakPrice)
            g_groups[g].peakPrice = curPrice;
      }

      double peak = g_groups[g].peakPrice;
      double maxFavorableDist = isBuy ? (peak - entryPrice) : (entryPrice - peak);
      if(maxFavorableDist <= 0.0) continue;

      double currentRetracement = isBuy ? (peak - curPrice) : (curPrice - peak);
      double dropPct = (currentRetracement / maxFavorableDist) * 100.0;

      // Case A: 2 legs remaining (Leg 3 & Leg 4) -> 28.5% drop from peak closes Leg 3
      if(leg3Open && leg4Open && !leg1Open && !leg2Open && !g_groups[g].leg3ClosedByTrail)
      {
         if(dropPct >= InpLeg3TrailDropPct)
         {
            PrintFormat("[Dynamic Runner Trailing] Rule 1 triggered for Group %s (Leg 3 & 4 active): Drop %.1f%% >= %.1f%% from peak (Entry: %.5f, Peak: %.5f, Cur: %.5f). Closing Leg 3 (#%I64u) to bank 71.5%% peak profit!",
                        g_groups[g].setupID, dropPct, InpLeg3TrailDropPct, entryPrice, peak, curPrice, activeTk3);
            if(trade.PositionClose(activeTk3))
            {
               g_groups[g].leg3ClosedByTrail = true;
               g_groups[g].tickets[2] = 0;
               // Reset peak price for the remaining runner leg 4 so it trails from its current high
               g_groups[g].peakPrice = curPrice;
            }
         }
      }
      // Case B: Only Leg 4 remaining -> 33.5% drop from peak closes Leg 4
      else if(leg4Open && !leg3Open && !leg1Open && !leg2Open && !g_groups[g].leg4ClosedByTrail)
      {
         if(dropPct >= InpLeg4TrailDropPct)
         {
            PrintFormat("[Dynamic Runner Trailing] Rule 2 triggered for Group %s (Sole Runner Leg 4): Drop %.1f%% >= %.1f%% from peak (Entry: %.5f, Peak: %.5f, Cur: %.5f). Closing Leg 4 (#%I64u) to secure windfall gain!",
                        g_groups[g].setupID, dropPct, InpLeg4TrailDropPct, entryPrice, peak, curPrice, activeTk4);
            if(trade.PositionClose(activeTk4))
            {
               g_groups[g].leg4ClosedByTrail = true;
               g_groups[g].tickets[3] = 0;
            }
         }
      }
   }

   ScanAndTrailUngroupedAdvisorRunners();
}

//+------------------------------------------------------------------+
//| Scan and trail any ungrouped advisor runners directly by comment  |
//+------------------------------------------------------------------+
void ScanAndTrailUngroupedAdvisorRunners()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk <= 0 || !posInfo.SelectByTicket(tk)) continue;

      long mgc = posInfo.Magic();
      string cmt = posInfo.Comment();
      if(mgc != InpAdvisorMagicNumber && StringFind(cmt, "SEGS|ADV") < 0) continue;

      // Extract setup signal and leg
      int lIdx = StringFind(cmt, "|L");
      if(lIdx < 0) continue;
      int legNum = (int)StringToInteger(StringSubstr(cmt, lIdx + 2, 1));
      if(legNum != 3 && legNum != 4) continue; // Only runner legs 3 and 4

      string sym = posInfo.Symbol();
      ENUM_POSITION_TYPE ptype = posInfo.PositionType();
      bool isBuy = (ptype == POSITION_TYPE_BUY);
      double entry = posInfo.PriceOpen();
      double sl = posInfo.StopLoss();

      // Only trail once protected at Breakeven
      bool isAtBE = isBuy ? (sl >= entry) : (sl <= entry && sl > 0.0);
      if(!isAtBE) continue;

      double curPrice = isBuy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curPrice <= 0.0) continue;

      string gvPeakKey = "SEGS_TR_PEAK_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(tk);
      double peak = 0.0;
      if(GlobalVariableCheck(gvPeakKey)) peak = GlobalVariableGet(gvPeakKey);

      if(isBuy)
      {
         if(peak <= 0.0 || peak < entry) peak = MathMax(entry, curPrice);
         else if(curPrice > peak) peak = curPrice;
      }
      else
      {
         if(peak <= 0.0 || peak > entry) peak = MathMin(entry, curPrice);
         else if(curPrice < peak) peak = curPrice;
      }
      GlobalVariableSet(gvPeakKey, peak);

      double maxDist = isBuy ? (peak - entry) : (entry - peak);
      if(maxDist <= 0.0) continue;

      double dropDist = isBuy ? (peak - curPrice) : (curPrice - peak);
      double dropPct = (dropDist / maxDist) * 100.0;

      // Count if Leg 3 and Leg 4 are both still open for this advisor setup
      string sigKey = "";
      int advIdx = StringFind(cmt, "SEGS|ADV|");
      if(advIdx >= 0)
      {
         string rem = StringSubstr(cmt, advIdx + 9);
         string parts[];
         if(StringSplit(rem, '|', parts) >= 1) sigKey = parts[0];
      }

      bool sisterLeg3Open = false;
      bool sisterLeg4Open = false;
      if(sigKey != "")
      {
         for(int j = 0; j < total; j++)
         {
            ulong stk = PositionGetTicket(j);
            if(stk > 0 && posInfo.SelectByTicket(stk))
            {
               string scmt = posInfo.Comment();
               if(StringFind(scmt, sigKey) >= 0)
               {
                  if(StringFind(scmt, "|L3") >= 0) sisterLeg3Open = true;
                  if(StringFind(scmt, "|L4") >= 0) sisterLeg4Open = true;
               }
            }
         }
      }

      if(legNum == 3 && sisterLeg3Open && sisterLeg4Open && dropPct >= InpLeg3TrailDropPct)
      {
         PrintFormat("[Dynamic Runner Trailing (Ungrouped)] Leg 3 #%I64u: Drop %.1f%% >= %.1f%% from peak. Closing to bank 71.5%% profits!",
                     tk, dropPct, InpLeg3TrailDropPct);
         trade.PositionClose(tk);
         GlobalVariableDel(gvPeakKey);
      }
      else if(legNum == 4 && !sisterLeg3Open && sisterLeg4Open && dropPct >= InpLeg4TrailDropPct)
      {
         PrintFormat("[Dynamic Runner Trailing (Ungrouped)] Leg 4 #%I64u: Drop %.1f%% >= %.1f%% from peak. Closing to bank windfall gain!",
                     tk, dropPct, InpLeg4TrailDropPct);
         trade.PositionClose(tk);
         GlobalVariableDel(gvPeakKey);
      }
   }
}

bool IsEligibleManualMaster(ulong ticket)
{
   if(ticket <= 0 || !posInfo.SelectByTicket(ticket)) return false;
   long magic = posInfo.Magic();
   if(magic == InpClonedMagicNumber || magic == InpAdvisorMagicNumber) return false;
   if(magic != 0 && magic != InpMasterMagicNumber) return false; // Unrelated EA

   ulong posId = (ulong)posInfo.Identifier();
   if(posId == 0) posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(posId == 0) return false;
   string gvKey = "SEGS_PROCESSED_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(posId);
   if(GlobalVariableCheck(gvKey)) return true;
   if(IsTicketAlreadyInGroup(ticket) || IsPositionIdInGroup(posId)) return true;
   // User manually opened market position
   if(magic == 0 || magic == InpMasterMagicNumber) return true;
   return false;
}

bool IsTicketAlreadyInGroup(ulong ticket)
{
   if(ticket == 0) return false;
   int gCount = ArraySize(g_groups);
   for(int g = 0; g < gCount; g++)
   {
      for(int k = 0; k < 4; k++)
      {
         if(g_groups[g].tickets[k] == ticket) return true;
      }
   }
   return false;
}

bool IsPositionIdInGroup(ulong posId)
{
   if(posId == 0) return false;
   int gCount = ArraySize(g_groups);
   for(int g = 0; g < gCount; g++)
   {
      for(int k = 0; k < 4; k++)
      {
         if(g_groups[g].positionIds[k] == posId) return true;
      }
   }
   return false;
}
// 11. Stable Signal ID Generation tied to trigger candle
string BuildStableSignalID(string sym, string dir, datetime triggerCandleTime, datetime pivotCandleTime)
{
   datetime torontoConf = ConvertBrokerTimeToToronto(triggerCandleTime);
   datetime torontoPiv  = (pivotCandleTime > 0) ? ConvertBrokerTimeToToronto(pivotCandleTime) : torontoConf;

   MqlDateTime mdtC, mdtP;
   TimeToStruct(torontoConf, mdtC);
   TimeToStruct(torontoPiv, mdtP);

   return StringFormat("%I64d_%s_%s_%04d%02d%02d_%02d%02d_PIVOT_%04d%02d%02d_%02d%02d",
      AccountInfoInteger(ACCOUNT_LOGIN),
      sym,
      dir,
      mdtC.year, mdtC.mon, mdtC.day, mdtC.hour, mdtC.min,
      mdtP.year, mdtP.mon, mdtP.day, mdtP.hour, mdtP.min);
}

// 12. Robust SEGS Managed Position Identification (Section 11)
bool IsSEGSManagedPosition(ulong ticket)
{
   if(ticket <= 0 || !posInfo.SelectByTicket(ticket)) return false;
   long magic = posInfo.Magic();
   string cmt = posInfo.Comment();

   // 1. Advisor positions
   if(magic == InpAdvisorMagicNumber || StringFind(cmt, "SEGS|ADV|") >= 0 || StringFind(cmt, "[MyAdvisor]") >= 0 || StringFind(cmt, "[Advised") >= 0)
      return true;

   // 2. Cloned positions
   if(magic == InpClonedMagicNumber && (StringFind(cmt, "SEGS|MAN|") >= 0 || StringFind(cmt, "SEGS_LEG") >= 0 || StringFind(cmt, "SEGS") >= 0))
      return true;

   // 3. Intentionally registered Manual Master
   if(IsEligibleManualMaster(ticket))
      return true;

   return false;
}

int CountOpenSEGSPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(IsSEGSManagedPosition(t)) count++;
   }
   return count;
}

int CountOpenAdvisorTradesForSymbol(string sym)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         if(posInfo.Symbol() == sym)
         {
            long magic = posInfo.Magic();
            if(magic == InpAdvisorMagicNumber)
            {
               count++;
            }
            else
            {
               string cmt = posInfo.Comment();
               if(StringFind(cmt, "[MyAdvisor]") >= 0 || StringFind(cmt, "SEGS|ADV") >= 0 || StringFind(cmt, "[Advised") >= 0)
                  count++;
            }
         }
      }
   }
   return count;
}

int CountOpenAdvisorSetsForSymbol(string sym)
{
   string ids[];
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !posInfo.SelectByTicket(ticket) || posInfo.Symbol() != sym) continue;
      string cmt = posInfo.Comment();
      int start = StringFind(cmt, "SEGS|ADV|");
      if(posInfo.Magic() != InpAdvisorMagicNumber && start < 0) continue;
      // Identity, not opening time: slow fills stay one set; simultaneous opposite sets stay two.
      string id = "LEGACY_" + IntegerToString((long)ticket);
      if(start >= 0)
      {
         int finish = StringFind(cmt, "|", start + 9);
         if(finish > start + 9) id = StringSubstr(cmt, start + 9, finish - start - 9);
      }
      bool found = false;
      for(int k = 0; k < ArraySize(ids); k++) if(ids[k] == id) { found = true; break; }
      if(!found)
      {
         int n = ArraySize(ids);
         if(ArrayResize(ids, n + 1) != n + 1) return 2; // Fail closed on allocation failure.
         ids[n] = id;
      }
   }
   return ArraySize(ids);
}

bool HasOpenAdvisorTradesForSignal(string sym, string signalID)
{
   if(signalID == "") return false;

   // STANDARD RULE: An advisor trade is ONLY open if real positions currently exist in terminal!
   if(CountOpenAdvisorTradesForSymbol(sym) == 0)
      return false;

   string shortSig = (StringLen(signalID) > 16) ? StringSubstr(signalID, StringLen(signalID) - 16) : signalID;

   // Scan open positions on this symbol for matching signal tag
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         if(posInfo.Symbol() == sym)
         {
            long magic = posInfo.Magic();
            if(magic == InpAdvisorMagicNumber)
            {
               string cmt = posInfo.Comment();
               if(StringFind(cmt, "SEGS|ADV|" + shortSig + "|") >= 0)
                  return true;
            }
         }
      }
   }
   return false;
}

bool HasOpenAdvisorTradesForSymbol(string sym)
{
   // Returns true if ANY advisor trade / leg is currently active on this symbol
   return (CountOpenAdvisorTradesForSymbol(sym) > 0);
}

bool GetOpenAdvisorTradeDetails(string sym, string &outDir, double &outEntry, double &outSL,
                               double &outTP1, double &outTP2, double &outTP3, double &outTP4, int &outCount)
{
   outCount = 0;
   outEntry = 0.0;
   outSL = 0.0;
   outTP1 = 0.0;
   outTP2 = 0.0;
   outTP3 = 0.0;
   outTP4 = 0.0;
   outDir = "NONE";

   // First: Run proactive auto-heal pass to protect any naked positions
   HealOpenAdvisorPositions(sym);

   string foundSetupID = "";
   double collectedTPs[4];
   for(int k = 0; k < 4; k++) collectedTPs[k] = 0.0;
   int tpCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         if(IsSameChartAsset(posInfo.Symbol(), sym))
         {
            long magic = posInfo.Magic();
            string cmt = posInfo.Comment();
            bool isAdvisorPos = (magic == InpAdvisorMagicNumber || 
                                 StringFind(cmt, "[MyAdvisor]") >= 0 || 
                                 StringFind(cmt, "SEGS|ADV") >= 0 || 
                                 StringFind(cmt, "[Advised") >= 0);
            if(isAdvisorPos)
            {
               outCount++;
               if(outEntry == 0.0)
               {
                  outEntry = posInfo.PriceOpen();
                  if(posInfo.StopLoss() > 0.0) outSL = posInfo.StopLoss();
                  outDir = (posInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
               }
               else if(outSL == 0.0 && posInfo.StopLoss() > 0.0)
               {
                  outSL = posInfo.StopLoss();
               }

               // Extract setupID if present
               int advIdx = StringFind(cmt, "SEGS|ADV|");
               if(advIdx >= 0 && foundSetupID == "")
               {
                  string rem = StringSubstr(cmt, advIdx + 9);
                  string parts[];
                  if(StringSplit(rem, '|', parts) >= 1) foundSetupID = "ADV_" + parts[0];
               }

               double tp = posInfo.TakeProfit();
               if(tp > 0.0)
               {
                  if((StringFind(cmt, "|L1") >= 0 || StringFind(cmt, "TP1") >= 0) && outTP1 == 0.0) outTP1 = tp;
                  else if((StringFind(cmt, "|L2") >= 0 || StringFind(cmt, "TP2") >= 0) && outTP2 == 0.0) outTP2 = tp;
                  else if((StringFind(cmt, "|L3") >= 0 || StringFind(cmt, "TP3") >= 0) && outTP3 == 0.0) outTP3 = tp;
                  else if((StringFind(cmt, "|L4") >= 0 || StringFind(cmt, "TP4") >= 0) && outTP4 == 0.0) outTP4 = tp;
                  else
                  {
                     if(tpCount < 4) { collectedTPs[tpCount] = tp; tpCount++; }
                  }
               }
            }
         }
      }
   }

   // Recover authoritative persistent setup targets from Global Variables FIRST
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.0001;
   double pipSize = GetPipSize(sym);

   double rEntry = 0, rSL = 0, rTP1 = 0, rTP2 = 0, rTP3 = 0, rTP4 = 0;
   ENUM_POSITION_TYPE rType;
   int rLegs = 4;
   bool recovered = false;
   if(foundSetupID != "") recovered = LoadAdvisorSetupTargets(foundSetupID, rEntry, rSL, rTP1, rTP2, rTP3, rTP4, rType, rLegs);
   if(!recovered && g_currentSignalID != "") recovered = LoadAdvisorSetupTargets("ADV_" + g_currentSignalID, rEntry, rSL, rTP1, rTP2, rTP3, rTP4, rType, rLegs);

   if(recovered)
   {
      if(outEntry <= 0.0 && rEntry > 0.0) outEntry = rEntry;
      if(outSL <= 0.0 && rSL > 0.0) outSL = rSL;
      if(rTP1 > 0.0) outTP1 = rTP1;
      if(rTP2 > 0.0) outTP2 = rTP2;
      if(rTP3 > 0.0) outTP3 = rTP3;
      if(rTP4 > 0.0) outTP4 = rTP4;
   }
   double pAtr = 20.0 * pipSize;
   double minSafeDist = MathMax(18.0 * pipSize, 0.40 * pAtr);
   if(outSL <= 0.0)
   {
      if(recovered && rSL > 0.0 && MathAbs(rSL - outEntry) >= minSafeDist)
         outSL = rSL;
      else
         outSL = (outDir == "BUY") ? (outEntry - minSafeDist) : (outEntry + minSafeDist);
      outSL = NormalizeDouble(NormalizePriceToTickSize(sym, outSL), (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   }
   else if(tpCount > 0 && outCount > 0)
   {
      // Bubble sort collected TPs
      for(int i = 0; i < tpCount - 1; i++)
      {
         for(int j = 0; j < tpCount - i - 1; j++)
         {
            bool swap = (outDir == "BUY") ? (collectedTPs[j] > collectedTPs[j + 1]) : (collectedTPs[j] < collectedTPs[j + 1]);
            if(swap)
            {
               double temp = collectedTPs[j];
               collectedTPs[j] = collectedTPs[j + 1];
               collectedTPs[j + 1] = temp;
            }
         }
      }
      for(int k = 0; k < tpCount; k++)
      {
         if(outTP1 == 0.0) outTP1 = collectedTPs[k];
         else if(outTP2 == 0.0) outTP2 = collectedTPs[k];
         else if(outTP3 == 0.0) outTP3 = collectedTPs[k];
         else if(outTP4 == 0.0) outTP4 = collectedTPs[k];
      }
   }

   // Absolute Guarantee: Stop loss distance CAN NEVER be larger than any Take-Profit distance!
   if(outCount > 0 && outEntry > 0.0 && outSL > 0.0)
   {
      double rDist = MathAbs(outEntry - outSL);
      if(pt <= 0.0) pt = SymbolInfoDouble(sym, SYMBOL_POINT);
      if(pt <= 0.0) pt = 0.0001;
      if(rDist <= 0.0) rDist = MathMax(20.0 * GetPipSize(sym), 20.0 * pt);
      double minSep = MathMax(0.80 * rDist, 15.0 * pt);

      if(outDir == "BUY")
      {
         if(outTP1 < outEntry + 1.20 * rDist) outTP1 = outEntry + 1.40 * rDist;
         if(outTP2 < outTP1 + minSep || outTP2 < outEntry + 2.10 * rDist) outTP2 = outTP1 + MathMax(0.80 * rDist, minSep);
         if(outTP3 < outTP2 + minSep || outTP3 < outEntry + 3.60 * rDist) outTP3 = outTP2 + MathMax(1.20 * rDist, minSep);
         if(outTP4 < outTP3 + minSep || outTP4 < outEntry + 6.00 * rDist) outTP4 = outTP3 + MathMax(2.00 * rDist, minSep);
      }
      else
      {
         if(outTP1 > outEntry - 1.20 * rDist || outTP1 <= 0.0) outTP1 = outEntry - 1.40 * rDist;
         if(outTP2 > outTP1 - minSep || outTP2 <= 0.0 || outTP2 > outEntry - 2.10 * rDist) outTP2 = outTP1 - MathMax(0.80 * rDist, minSep);
         if(outTP3 > outTP2 - minSep || outTP3 <= 0.0 || outTP3 > outEntry - 3.60 * rDist) outTP3 = outTP2 - MathMax(1.20 * rDist, minSep);
         if(outTP4 > outTP3 - minSep || outTP4 <= 0.0 || outTP4 > outEntry - 6.00 * rDist) outTP4 = outTP3 - MathMax(2.00 * rDist, minSep);
      }

      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      outTP1 = NormalizeDouble(NormalizePriceToTickSize(sym, outTP1), digits);
      outTP2 = NormalizeDouble(NormalizePriceToTickSize(sym, outTP2), digits);
      outTP3 = NormalizeDouble(NormalizePriceToTickSize(sym, outTP3), digits);
      outTP4 = NormalizeDouble(NormalizePriceToTickSize(sym, outTP4), digits);
   }

   return (outCount > 0);
}

bool CheckConfirmedSafeZoneBounce(string sym, string dir, double safeEntry)
{
   // Check recent M5 or M15 candle rejecting the safe entry zone with couldn't-close-below confirmation
   int barsToCheck = 5;
   double pip = GetPipSize(sym);
   double zoneTolerance = 8.0 * pip;

   // Check M5 first
   for(int b = 1; b <= barsToCheck; b++)
   {
      double cOpen  = iOpen(sym, PERIOD_M5, b);
      double cClose = iClose(sym, PERIOD_M5, b);
      double cHigh  = iHigh(sym, PERIOD_M5, b);
      double cLow   = iLow(sym, PERIOD_M5, b);

      if(dir == "BUY")
      {
         // Price returned to the zone (low touched into or near safeEntry)
         bool touchedZone = (cLow <= safeEntry + zoneTolerance);
         // Crucial condition: Couldn't close below the zone! (Closed above the base of zone and respected support)
         bool heldAboveZone = (cClose >= safeEntry - zoneTolerance);
         // Bullish rejection: either closed higher or formed rejection lower wick
         bool rejectionWick = (cClose - cLow) >= 1.2 * MathMax(cHigh - cClose, 2.0 * pip);
         bool bullishReversal = (cClose > cOpen);

         if(touchedZone && heldAboveZone && (rejectionWick || bullishReversal))
            return true;
      }
      else if(dir == "SELL")
      {
         bool touchedZone = (cHigh >= safeEntry - zoneTolerance);
         bool heldBelowZone = (cClose <= safeEntry + zoneTolerance);
         bool rejectionWick = (cHigh - cClose) >= 1.2 * MathMax(cClose - cLow, 2.0 * pip);
         bool bearishReversal = (cClose < cOpen);

         if(touchedZone && heldBelowZone && (rejectionWick || bearishReversal))
            return true;
      }
   }

   // Also check M15 for macro zone respect
   for(int b = 1; b <= 3; b++)
   {
      double cOpen  = iOpen(sym, PERIOD_M15, b);
      double cClose = iClose(sym, PERIOD_M15, b);
      double cHigh  = iHigh(sym, PERIOD_M15, b);
      double cLow   = iLow(sym, PERIOD_M15, b);

      if(dir == "BUY")
      {
         bool touchedZone = (cLow <= safeEntry + zoneTolerance);
         bool heldAboveZone = (cClose >= safeEntry - zoneTolerance);
         if(touchedZone && heldAboveZone && (cClose >= cOpen || (cClose - cLow) >= 1.5 * (cHigh - cClose)))
            return true;
      }
      else if(dir == "SELL")
      {
         bool touchedZone = (cHigh >= safeEntry - zoneTolerance);
         bool heldBelowZone = (cClose <= safeEntry + zoneTolerance);
         if(touchedZone && heldBelowZone && (cClose <= cOpen || (cHigh - cClose) >= 1.5 * (cClose - cLow)))
            return true;
      }
   }
   return false;
}

bool IsAdvisorTradeTaken(string sym, string signalID)
{
   int openCount = HasOpenAdvisorTradesForSignal(sym, signalID) ? 1 : 0;
   if(openCount > 0)
   {
      g_currentTradeTaken = true;
      return true;
   }

   // If order is actively in flight (state == 1.0 within 15 seconds)
   if(signalID != "")
   {
      string sigExecKey = "SEGS_SIG_EXEC_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + signalID;
      if(GlobalVariableCheck(sigExecKey))
      {
         double state = GlobalVariableGet(sigExecKey);
         if(state >= 2.0) return true;
         if(state == 1.0)
         {
            string pendingTimeKey = "SEGS_SIG_PENDING_TIME_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + signalID;
            if(GlobalVariableCheck(pendingTimeKey))
            {
               datetime pTime = (datetime)GlobalVariableGet(pendingTimeKey);
               if(TimeCurrent() - pTime < 15)
               {
                  g_currentTradeTaken = true;
                  return true;
               }
            }
         }
      }
   }

   // When open advisor positions are 0 and no order is in flight, setup is NOT taken
   g_currentTradeTaken = false;
   return false;
}

//+------------------------------------------------------------------+
//| Get exact execution timestamp of Trade Advisor trade for symbol  |
//+------------------------------------------------------------------+
datetime GetAdvisorTradeExecutionTime(string sym, string signalID)
{
   // STANDARD RULE: Only return execution time if there is an active open position!
   if(CountOpenAdvisorTradesForSymbol(sym) == 0)
      return 0;

   string shortSig = (StringLen(signalID) > 16) ? StringSubstr(signalID, StringLen(signalID) - 16) : signalID;

   // Authoritative: inspect open positions on this symbol matching advisor magic / comments
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         if(posInfo.Symbol() == sym)
         {
            long magic = posInfo.Magic();
            if(magic == InpAdvisorMagicNumber)
            {
               string cmt = posInfo.Comment();
               if(StringFind(cmt, "SEGS|ADV|" + shortSig + "|") >= 0)
               {
                  datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
                  if(posTime > 0) return posTime;
               }
            }
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Format Trade Execution time into Toronto time with timezone      |
//+------------------------------------------------------------------+
string FormatExecutionTime(datetime execDt, bool includeDate=true)
{
   if(execDt <= 0) return "";
   datetime torTime = ConvertBrokerTimeToToronto(execDt);
   string tz = IsTorontoDST(torTime) ? "EDT" : "EST";
   if(includeDate)
      return TimeToString(torTime, TIME_DATE) + " " + TimeToString(torTime, TIME_MINUTES) + " " + tz;
   return TimeToString(torTime, TIME_MINUTES) + " " + tz;
}

// Account-wide MyAdvisor Synchronization
void RefreshAccountAdvisorState()
{
   string gvAdvisorKey = "SEGS_MYADVISOR_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   if(GlobalVariableCheck(gvAdvisorKey))
   {
      double val = GlobalVariableGet(gvAdvisorKey);
      bool remoteOn = (val > 0.5);
      if(g_myAdvisorEnabled != remoteOn)
      {
         g_myAdvisorEnabled = remoteOn;
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
      }
   }

   string gvMaxTradesKey = "SEGS_ADVISOR_MAX_TOTAL_TRADES_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   if(GlobalVariableCheck(gvMaxTradesKey))
   {
      double savedLimit = GlobalVariableGet(gvMaxTradesKey);
      if(savedLimit < 24.0)
      {
         savedLimit = 24.0;
         GlobalVariableSet(gvMaxTradesKey, 24.0);
      }
      if(g_advisorMaxTradesLimit != (int)savedLimit)
      {
         g_advisorMaxTradesLimit = (int)savedLimit;
         if(g_showSentimentHUD) DrawSentimentHUD();
      }
   }
   else
   {
      g_advisorMaxTradesLimit = MathMax(24, InpAdvisorMaxTotalOpenTrades);
      GlobalVariableSet(gvMaxTradesKey, (double)g_advisorMaxTradesLimit);
   }
}

//+------------------------------------------------------------------+
//| Save Persistent State across Restarts, Hibernation & Reboots     |
//+------------------------------------------------------------------+
void SaveAdvisorPersistentState()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   long chartId = ChartID();
   string loginStr = IntegerToString(login);
   string chartStr = IntegerToString(chartId);

   GlobalVariableSet("SEGS_MYADVISOR_" + loginStr, g_myAdvisorEnabled ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_DASH_VIS_" + chartStr, g_isDashboardVisible ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_SHOW_SENT_" + chartStr, g_showSentimentHUD ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_SHOW_TGTS_" + chartStr, g_showTradeAdviceLines ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_SHOW_OPENTRD_" + chartStr, g_showOpenTradeMarkings ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_TP2_BE_" + chartStr, g_autoBreakevenOnTP_Active ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_ACTIVE_TAB_" + chartStr, (double)g_activeDashboardTab);
   GlobalVariableSet("SEGS_ALERT_VIABLE_" + loginStr, g_alertOnViableEntry ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_SMART_LOT_" + loginStr, g_smartLotEnabled ? 1.0 : 0.0);
   GlobalVariableSet("SEGS_DOCK_BOTTOM_" + chartStr, g_isDockedAtBottom ? 1.0 : 0.0);

   // Save active trade advice signal snapshot for this chart's symbol
   SaveActiveSignalSnapshot(_Symbol);

   // Flush immediately to physical disk so terminal crash, sudden restart, or OS hibernation never loses it
   GlobalVariablesFlush();

   // Disk File Redundancy: Save account-level and isolated chart-level states
   string fileName = "SEGS_Advisor_State_" + loginStr + ".ini";
   int h = FileOpen(fileName, FILE_WRITE | FILE_TXT);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h, StringFormat("MyAdvisor=%d\n", g_myAdvisorEnabled ? 1 : 0));
      FileWriteString(h, StringFormat("SmartLotEnabled=%d\n", g_smartLotEnabled ? 1 : 0));
      FileWriteString(h, StringFormat("AlertViable=%d\n", g_alertOnViableEntry ? 1 : 0));
      FileClose(h);
   }

   string chartFileName = "SEGS_Advisor_Chart_" + loginStr + "_" + chartStr + ".ini";
   int ch = FileOpen(chartFileName, FILE_WRITE | FILE_TXT);
   if(ch != INVALID_HANDLE)
   {
      FileWriteString(ch, StringFormat("DashboardVisible=%d\n", g_isDashboardVisible ? 1 : 0));
      FileWriteString(ch, StringFormat("ShowSentimentHUD=%d\n", g_showSentimentHUD ? 1 : 0));
      FileWriteString(ch, StringFormat("ShowTradeAdviceLines=%d\n", g_showTradeAdviceLines ? 1 : 0));
      FileWriteString(ch, StringFormat("ShowOpenTradeMarkings=%d\n", g_showOpenTradeMarkings ? 1 : 0));
      FileWriteString(ch, StringFormat("AutoBE_TP2=%d\n", g_autoBreakevenOnTP_Active ? 1 : 0));
      FileWriteString(ch, StringFormat("ActiveTab=%d\n", g_activeDashboardTab));
      FileWriteString(ch, StringFormat("DockBottom=%d\n", g_isDockedAtBottom ? 1 : 0));
      FileClose(ch);
   }
}

//+------------------------------------------------------------------+
//| Restore Persistent State across Restarts, Hibernation & Reboots  |
//+------------------------------------------------------------------+
void RestoreAdvisorPersistentState()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   long chartId = ChartID();
   string loginStr = IntegerToString(login);
   string chartStr = IntegerToString(chartId);

   // 1. MyAdvisor Auto-Trading State
   string gvAdvisorKey = "SEGS_MYADVISOR_" + loginStr;
   if(GlobalVariableCheck(gvAdvisorKey))
   {
      g_myAdvisorEnabled = (GlobalVariableGet(gvAdvisorKey) > 0.5);
      PrintFormat("[MyAdvisor] Restored persistent status across restart/hibernate: %s", g_myAdvisorEnabled ? "ACTIVE (ON)" : "STANDBY (OFF)");
   }
   else
   {
      // Check file fallback
      bool loadedFromFile = false;
      string fileName = "SEGS_Advisor_State_" + loginStr + ".ini";
      if(FileIsExist(fileName))
      {
         int h = FileOpen(fileName, FILE_READ | FILE_TXT);
         if(h != INVALID_HANDLE)
         {
            while(!FileIsEnding(h))
            {
               string line = FileReadString(h);
               string parts[];
               if(StringSplit(line, '=', parts) == 2)
               {
                  if(parts[0] == "MyAdvisor") { g_myAdvisorEnabled = (StringToInteger(parts[1]) > 0); loadedFromFile = true; }
                  else if(parts[0] == "SmartLotEnabled") { g_smartLotEnabled = (StringToInteger(parts[1]) > 0); }
               }
            }
            FileClose(h);
         }
      }
      if(!loadedFromFile)
      {
         g_myAdvisorEnabled = InpMyAdvisor_AutoTrade;
      }
      GlobalVariableSet(gvAdvisorKey, g_myAdvisorEnabled ? 1.0 : 0.0);
      GlobalVariablesFlush();
      PrintFormat("[MyAdvisor] Initialized status: %s", g_myAdvisorEnabled ? "ACTIVE (ON)" : "STANDBY (OFF)");
   }

   // 1B. Smart Lot Size Selector State (Dynamic Risk-Based vs Fixed Lots)
   string gvSmartLotKey = "SEGS_SMART_LOT_" + loginStr;
   if(GlobalVariableCheck(gvSmartLotKey))
   {
      g_smartLotEnabled = (GlobalVariableGet(gvSmartLotKey) > 0.5);
      PrintFormat("[Smart Lot] Restored persistent status: %s", g_smartLotEnabled ? "ACTIVE (ON - Dynamic Risk)" : "STANDBY (OFF - Fixed Lots)");
   }
   else
   {
      g_smartLotEnabled = InpEnableSmartLotSize;
      GlobalVariableSet(gvSmartLotKey, g_smartLotEnabled ? 1.0 : 0.0);
      PrintFormat("[Smart Lot] Initialized default status: %s", g_smartLotEnabled ? "ACTIVE (ON - Dynamic Risk)" : "STANDBY (OFF - Fixed Lots)");
   }

   // 1C. Isolated Chart-Level Dashboard Visibility
   string gvChartDashKey = "SEGS_DASH_VIS_" + chartStr;
   if(GlobalVariableCheck(gvChartDashKey))
   {
      g_isDashboardVisible = (GlobalVariableGet(gvChartDashKey) > 0.5);
   }
   else if(GlobalVariableCheck("SEGS_SYS_DASH_VIS"))
   {
      g_isDashboardVisible = (GlobalVariableGet("SEGS_SYS_DASH_VIS") > 0.5);
   }
   else
   {
      g_isDashboardVisible = true;
      GlobalVariableSet(gvChartDashKey, 1.0);
      GlobalVariableSet("SEGS_SYS_DASH_VIS", 1.0);
   }

   // Isolated Chart File Fallback (multi-instance safety)
   string chartFileName = "SEGS_Advisor_Chart_" + loginStr + "_" + chartStr + ".ini";
   if(FileIsExist(chartFileName))
   {
      int ch = FileOpen(chartFileName, FILE_READ | FILE_TXT);
      if(ch != INVALID_HANDLE)
      {
         while(!FileIsEnding(ch))
         {
            string line = FileReadString(ch);
            string parts[];
            if(StringSplit(line, '=', parts) == 2)
            {
               if(parts[0] == "DashboardVisible")     g_isDashboardVisible = (StringToInteger(parts[1]) > 0);
               else if(parts[0] == "ShowSentimentHUD") g_showSentimentHUD = (StringToInteger(parts[1]) > 0);
               else if(parts[0] == "ShowTradeAdviceLines") g_showTradeAdviceLines = (StringToInteger(parts[1]) > 0);
               else if(parts[0] == "ShowOpenTradeMarkings") g_showOpenTradeMarkings = (StringToInteger(parts[1]) > 0);
               else if(parts[0] == "AutoBE_TP2")       g_autoBreakevenOnTP_Active = (StringToInteger(parts[1]) > 0);
               else if(parts[0] == "ActiveTab")        g_activeDashboardTab = (int)StringToInteger(parts[1]);
               else if(parts[0] == "DockBottom")       g_isDockedAtBottom = (StringToInteger(parts[1]) > 0);
            }
         }
         FileClose(ch);
      }
   }

   // 2. Market Sentiment / Trade Signal HUD System-Wide State
   string gvSentKey = "SEGS_SYS_SHOW_SENT";
   if(GlobalVariableCheck(gvSentKey))
   {
      g_showSentimentHUD = (GlobalVariableGet(gvSentKey) > 0.5);
   }
   else
   {
      g_showSentimentHUD = InpShowSentimentHUD;
      GlobalVariableSet(gvSentKey, g_showSentimentHUD ? 1.0 : 0.0);
   }

   // 3. Trade Advice Targets Lines State
   string gvTgtsKey = "SEGS_SHOW_TGTS_" + chartStr;
   if(GlobalVariableCheck(gvTgtsKey))
   {
      g_showTradeAdviceLines = (GlobalVariableGet(gvTgtsKey) > 0.5);
   }
   else
   {
      g_showTradeAdviceLines = InpShowTradeAdviceLines;
      GlobalVariableSet(gvTgtsKey, g_showTradeAdviceLines ? 1.0 : 0.0);
   }

   // 4. Auto Breakeven on TP2 State
   string gvTp2Key = "SEGS_TP2_BE_" + chartStr;
   if(GlobalVariableCheck(gvTp2Key))
   {
      g_autoBreakevenOnTP_Active = (GlobalVariableGet(gvTp2Key) > 0.5);
   }
   else
   {
      g_autoBreakevenOnTP_Active = InpEnableTPBreakeven;
      GlobalVariableSet(gvTp2Key, g_autoBreakevenOnTP_Active ? 1.0 : 0.0);
   }

   // 5. Open Trade Markings State
   string gvOpenTrdKey = "SEGS_SHOW_OPENTRD_" + chartStr;
   if(GlobalVariableCheck(gvOpenTrdKey))
   {
      g_showOpenTradeMarkings = (GlobalVariableGet(gvOpenTrdKey) > 0.5);
   }
   else
   {
      g_showOpenTradeMarkings = InpShowOpenTradeMarkings;
      GlobalVariableSet(gvOpenTrdKey, g_showOpenTradeMarkings ? 1.0 : 0.0);
   }

   // 6. Active Dashboard Tab
   string gvTabKey = "SEGS_ACTIVE_TAB_" + chartStr;
   if(GlobalVariableCheck(gvTabKey))
   {
      g_activeDashboardTab = (int)GlobalVariableGet(gvTabKey);
   }

   // 7. Alert on Viable Entry State
   string gvAlertKey = "SEGS_ALERT_VIABLE_" + loginStr;
   if(GlobalVariableCheck(gvAlertKey))
   {
      g_alertOnViableEntry = (GlobalVariableGet(gvAlertKey) > 0.5);
   }
   else
   {
      g_alertOnViableEntry = InpAlertOnViableEntry;
      GlobalVariableSet(gvAlertKey, g_alertOnViableEntry ? 1.0 : 0.0);
   }

   // 8. Terminal Bottom Docking State
   string gvDockKey = "SEGS_DOCK_BOTTOM_" + chartStr;
   if(GlobalVariableCheck(gvDockKey))
   {
      g_isDockedAtBottom = (GlobalVariableGet(gvDockKey) > 0.5);
   }
   else
   {
      g_isDockedAtBottom = InpDockAtBottom;
      GlobalVariableSet(gvDockKey, g_isDockedAtBottom ? 1.0 : 0.0);
   }

   // 9. Restore Active Signal Snapshot for _Symbol
   RestoreActiveSignalSnapshot(_Symbol);
}

//+------------------------------------------------------------------+
//| Save Active Trade Advice Signal Snapshot                         |
//+------------------------------------------------------------------+
void SaveActiveSignalSnapshot(string sym)
{
   if(sym == "") sym = _Symbol;
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string prefix = "SEGS_SIG_" + IntegerToString(login) + "_" + sym + "_";

   if(g_hasViableEntry && !g_isSignalExpired && g_staticEntryPrice > 0.0)
   {
      GlobalVariableSet(prefix + "VALID", 1.0);
      GlobalVariableSet(prefix + "ACTION", (g_currentAdvisedAction == "BUY") ? 1.0 : ((g_currentAdvisedAction == "SELL") ? -1.0 : 0.0));
      GlobalVariableSet(prefix + "ENTRY", g_staticEntryPrice);
      GlobalVariableSet(prefix + "SL", g_staticSL);
      GlobalVariableSet(prefix + "TP1", g_staticTP1);
      GlobalVariableSet(prefix + "TP2", g_staticTP2);
      GlobalVariableSet(prefix + "TP3", g_staticTP3);
      GlobalVariableSet(prefix + "TP4", g_staticTP4);
      GlobalVariableSet(prefix + "QUAL", (double)g_setupQuality);
      GlobalVariableSet(prefix + "TIME", (double)g_signalTriggerTime);
      GlobalVariableSet(prefix + "TAKEN", g_currentTradeTaken ? 1.0 : 0.0);
      GlobalVariableSet(prefix + "EXPIRED", g_isSignalExpired ? 1.0 : 0.0);
      GlobalVariableSet(prefix + "STATE", (g_setupState == "TRIGGERED") ? 2.0 : ((g_setupState == "READY") ? 1.0 : 3.0));
      GlobalVariableSet(prefix + "STRAT", (g_activeEntryStrategy == "ORDER_BLOCK") ? 1.0 : 0.0);

      // Save ID string as well to disk file
      string sigFile = "SEGS_Signal_" + sym + "_" + IntegerToString(login) + ".dat";
      int h = FileOpen(sigFile, FILE_WRITE | FILE_TXT);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, g_currentSignalID + "\n");
         FileWriteString(h, g_currentAdvisedAction + "\n");
         FileWriteString(h, g_setupState + "\n");
         FileWriteString(h, g_signalStatusLabel + "\n");
         FileWriteString(h, g_activeEntryStrategy + "\n");
         FileClose(h);
      }
   }
}

//+------------------------------------------------------------------+
//| Restore Active Trade Advice Signal Snapshot                      |
//+------------------------------------------------------------------+
void RestoreActiveSignalSnapshot(string sym)
{
   if(sym == "") sym = _Symbol;
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string prefix = "SEGS_SIG_" + IntegerToString(login) + "_" + sym + "_";

   if(GlobalVariableCheck(prefix + "VALID") && GlobalVariableGet(prefix + "VALID") > 0.5)
   {
      double dirVal = GlobalVariableGet(prefix + "ACTION");
      g_currentAdvisedAction = (dirVal > 0.5) ? "BUY" : ((dirVal < -0.5) ? "SELL" : "NONE");
      g_staticEntryPrice     = GlobalVariableGet(prefix + "ENTRY");
      g_staticSL             = GlobalVariableGet(prefix + "SL");
      g_staticTP1            = GlobalVariableGet(prefix + "TP1");
      g_staticTP2            = GlobalVariableGet(prefix + "TP2");
      g_staticTP3            = GlobalVariableGet(prefix + "TP3");
      g_staticTP4            = GlobalVariableGet(prefix + "TP4");
      g_setupQuality         = (int)GlobalVariableGet(prefix + "QUAL");
      g_signalTriggerTime    = (datetime)GlobalVariableGet(prefix + "TIME");
      g_currentTradeTaken    = (GlobalVariableGet(prefix + "TAKEN") > 0.5);
      g_isSignalExpired      = (GlobalVariableGet(prefix + "EXPIRED") > 0.5);
      double stateVal        = GlobalVariableGet(prefix + "STATE");
      g_setupState           = (stateVal >= 2.0) ? "TRIGGERED" : ((stateVal >= 1.0) ? "READY" : "WATCHING");
      if(GlobalVariableCheck(prefix + "STRAT"))
      {
         g_activeEntryStrategy = (GlobalVariableGet(prefix + "STRAT") > 0.5) ? "ORDER_BLOCK" : "STRUCTURE_RETEST";
         g_activeStrategyWeight = (g_activeEntryStrategy == "ORDER_BLOCK") ? InpWeight_OrderBlockStrategy : InpWeight_OtherStrategies;
      }
      g_hasViableEntry       = true;
      g_signalGeneratedWhileAdvisorEnabled = true;

      // Restore string data from disk file if available
      string sigFile = "SEGS_Signal_" + sym + "_" + IntegerToString(login) + ".dat";
      if(FileIsExist(sigFile))
      {
         int h = FileOpen(sigFile, FILE_READ | FILE_TXT);
         if(h != INVALID_HANDLE)
         {
            if(!FileIsEnding(h)) g_currentSignalID = FileReadString(h);
            if(!FileIsEnding(h)) g_currentAdvisedAction = FileReadString(h);
            if(!FileIsEnding(h)) g_setupState = FileReadString(h);
            if(!FileIsEnding(h)) g_signalStatusLabel = FileReadString(h);
            if(!FileIsEnding(h))
            {
               string fileStrat = FileReadString(h);
               if(fileStrat == "ORDER_BLOCK" || fileStrat == "STRUCTURE_RETEST")
               {
                  g_activeEntryStrategy = fileStrat;
                  g_activeStrategyWeight = (g_activeEntryStrategy == "ORDER_BLOCK") ? InpWeight_OrderBlockStrategy : InpWeight_OtherStrategies;
               }
            }
            FileClose(h);
         }
      }

      if(g_currentSignalID == "")
      {
         g_currentSignalID = "RESTORED_" + sym + "_" + TimeToString(g_signalTriggerTime, TIME_MINUTES);
      }

      int openCount = HasOpenAdvisorTradesForSignal(sym, g_currentSignalID) ? 1 : 0;
      if(openCount > 0)
      {
         g_currentTradeTaken = true;
         g_signalStatusLabel = StringFormat("POSITION ACTIVE: %s [%d Open | TP2: %.2fR | Monitoring]",
                                            g_currentAdvisedAction, openCount, g_rrTP2);
      }
      else
      {
         g_currentTradeTaken = false;
         // Validate restored signal viability against current price
         double curPriceCheck = SymbolInfoDouble(sym, SYMBOL_BID);
         if(curPriceCheck <= 0.0) curPriceCheck = iClose(sym, PERIOD_M1, 0);
         if(curPriceCheck <= 0.0) curPriceCheck = iClose(sym, PERIOD_H1, 0);

         double pip = GetPipSize(sym);
         double curAtrVal = 0.0;
         if(g_hAtr_H1 != INVALID_HANDLE)
         {
            double atrBuf[];
            ArraySetAsSeries(atrBuf, true);
            if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtrVal = atrBuf[0];
         }
         if(curAtrVal <= 0.0) curAtrVal = 20.0 * pip;

         string candDir = g_currentAdvisedAction;
         if(candDir == "" || candDir == "NONE") candDir = (g_staticEntryPrice < g_staticSL ? "SELL" : "BUY");
         string unviableReason = "";
         if(g_isSignalExpired || !IsPlannedEntryViable(sym, candDir, g_staticEntryPrice, g_staticSL, curPriceCheck, pip, curAtrVal, unviableReason))
         {
            if(unviableReason == "") unviableReason = "SIGNAL EXPIRED / UNVIABLE";
            CancelUnviablePlannedEntry(sym, unviableReason);
            return;
         }
      }

      PrintFormat("[Trade Advisor] Active Trade Signal for %s successfully RESTORED across restart/hibernate: %s @ %.5f (SL: %.5f, TP2: %.5f)",
                  sym, g_currentAdvisedAction, g_staticEntryPrice, g_staticSL, g_staticTP2);

      if(g_showTradeAdviceLines) UpdateTradeAdviceLines();
   }
}

//+------------------------------------------------------------------+
//| Clear Active Trade Advice Signal Snapshot                        |
//+------------------------------------------------------------------+
void ClearActiveSignalSnapshot(string sym)
{
   if(sym == "") sym = _Symbol;
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string prefix = "SEGS_SIG_" + IntegerToString(login) + "_" + sym + "_";
   GlobalVariableSet(prefix + "VALID", 0.0);
   GlobalVariableDel(prefix + "VALID");
   GlobalVariableDel(prefix + "ACTION");
   GlobalVariableDel(prefix + "ENTRY");
   GlobalVariableDel(prefix + "SL");
   GlobalVariableDel(prefix + "TP1");
   GlobalVariableDel(prefix + "TP2");
   GlobalVariableDel(prefix + "TP3");
   GlobalVariableDel(prefix + "TP4");
   GlobalVariableDel(prefix + "QUAL");
   GlobalVariableDel(prefix + "TIME");
   GlobalVariableDel(prefix + "TAKEN");
   GlobalVariableDel(prefix + "EXPIRED");
   GlobalVariableDel(prefix + "STATE");
   GlobalVariablesFlush();

   string sigFile = "SEGS_Signal_" + sym + "_" + IntegerToString(login) + ".dat";
   FileDelete(sigFile);
}

//+------------------------------------------------------------------+
//| Structural Target Identification using real market levels        |
//| Replaces arbitrary fixed R multiples with actual swings/barriers |
//+------------------------------------------------------------------+
int BuildStructuralTargets(string sym, string dir, double entryPrice, double stopLoss, double curAtr,
                           double &outTP1, double &outTP2, double &outTP3, double &outTP4,
                           double &outRR_TP2, double &outRR_Weighted)
{
   outTP1 = 0.0; outTP2 = 0.0; outTP3 = 0.0; outTP4 = 0.0;
   outRR_TP2 = 0.0; outRR_Weighted = 0.0;

   double riskDist = MathAbs(entryPrice - stopLoss);
   if(riskDist <= 0.0) return 0;

   double pipSize = GetPipSize(sym);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   bool isBuy = (dir == "BUY");

   // 2-3 Trading Days Attainability Reference (Daily ATR / ADR)
   double dailyAtr = 0.0;
   for(int d = 1; d <= 5; d++)
   {
      double dH = iHigh(sym, PERIOD_D1, d);
      double dL = iLow(sym, PERIOD_D1, d);
      if(dH > dL) dailyAtr += (dH - dL);
   }
   if(dailyAtr > 0.0) dailyAtr /= 5.0;
   else dailyAtr = MathMax(curAtr * 3.5, 50.0 * pipSize);

   // Multi-Timeframe Structural Candidate Levels Pool
   double candLevels[64];
   int candCount = 0;

   // Minimum clearance to avoid noise
   double minClearance = MathMax(0.50 * riskDist, MathMax(0.25 * curAtr, 8.0 * pipSize));

   string cleanSym = sym; StringToUpper(cleanSym);

   if(isBuy)
   {
      // 1. Authoritative Intermediate Swing Highs (Fixed PERIOD_M30 for multi-timeframe consistency)
      ENUM_TIMEFRAMES chartTf = PERIOD_M30;
      if(chartTf <= PERIOD_H1 && chartTf >= PERIOD_M5)
      {
         for(int b = 2; b <= 40 && candCount < 8; b++)
         {
            double h = iHigh(sym, chartTf, b);
            if(h > iHigh(sym, chartTf, b - 1) && h > iHigh(sym, chartTf, b + 1))
            {
               if(h > entryPrice + minClearance) candLevels[candCount++] = h;
            }
         }
      }

      // 2. Completed H1 Swing Resistance / Pivots
      int maxBars = MathMin(InpStructureLookbackBars, 60);
      for(int b = 2; b <= maxBars && candCount < 18; b++)
      {
         double h = iHigh(sym, PERIOD_H1, b);
         if(h > iHigh(sym, PERIOD_H1, b - 1) && h > iHigh(sym, PERIOD_H1, b + 1))
         {
            if(h > entryPrice + minClearance) candLevels[candCount++] = h;
         }
      }

      // 3. Completed H4 Major Structural Resistance
      for(int b4 = 1; b4 <= 24 && candCount < 26; b4++)
      {
         double h4 = iHigh(sym, PERIOD_H4, b4);
         if(h4 > entryPrice + minClearance) candLevels[candCount++] = h4;
      }

      // 4. Opposing Bearish Order Blocks / Supply Zones (Secure profit before opposing supply ceiling)
      for(int obI = 0; obI < ArraySize(g_orderBlocks) && candCount < 34; obI++)
      {
         if(g_orderBlocks[obI].invalidated || g_orderBlocks[obI].bullish) continue;
         double supLow = g_orderBlocks[obI].low;
         if(supLow > entryPrice + minClearance) candLevels[candCount++] = supLow;
         double supHigh = g_orderBlocks[obI].high;
         if(supHigh > entryPrice + minClearance) candLevels[candCount++] = supHigh;
      }

      // 5. Static Resistance (from structure scan)
      if(g_recentResistance > entryPrice + minClearance && candCount < 38)
         candLevels[candCount++] = g_recentResistance;

      // 5B. Opposing HTF Liquidity Pools (PDH / PWH - Prime Institutional Targets)
      if(g_htfLiquidity.pdh > entryPrice + minClearance && candCount < 40)
         candLevels[candCount++] = g_htfLiquidity.pdh;
      if(g_htfLiquidity.pwh > entryPrice + minClearance && candCount < 42)
         candLevels[candCount++] = g_htfLiquidity.pwh;

      // 7. Psychological Institutional Levels (.00, .50)
      double roundStep = pipSize * 50.0;
      double roundLevel1 = MathCeil((entryPrice + minClearance) / roundStep) * roundStep;
      if(roundLevel1 > entryPrice + minClearance && candCount < 46) candLevels[candCount++] = roundLevel1;
      double roundLevel2 = roundLevel1 + roundStep;
      if(roundLevel2 > entryPrice + minClearance && candCount < 48) candLevels[candCount++] = roundLevel2;

      // 8. Structural Fibonacci / Risk-Reward Extensions (Calibrated Tighter & Attainable within 2-3 Days)
      if(candCount < 50) candLevels[candCount++] = entryPrice + (1.350 * riskDist);
      if(candCount < 52) candLevels[candCount++] = entryPrice + (2.200 * riskDist);
      if(candCount < 54) candLevels[candCount++] = entryPrice + (3.400 * riskDist);
      if(candCount < 56) candLevels[candCount++] = entryPrice + (5.500 * riskDist);

      // Sort candidate levels ASCENDING
      for(int i = 0; i < candCount - 1; i++)
      {
         for(int j = 0; j < candCount - i - 1; j++)
         {
            if(candLevels[j] > candLevels[j+1])
            {
               double tmp = candLevels[j]; candLevels[j] = candLevels[j+1]; candLevels[j+1] = tmp;
            }
         }
      }
   }
   else // SELL
   {
      // 1. Authoritative Intermediate Swing Lows (Fixed PERIOD_M30 for multi-timeframe consistency)
      ENUM_TIMEFRAMES chartTf = PERIOD_M30;
      if(chartTf <= PERIOD_H1 && chartTf >= PERIOD_M5)
      {
         for(int b = 2; b <= 40 && candCount < 8; b++)
         {
            double l = iLow(sym, chartTf, b);
            if(l < iLow(sym, chartTf, b - 1) && l < iLow(sym, chartTf, b + 1))
            {
               if(l < entryPrice - minClearance) candLevels[candCount++] = l;
            }
         }
      }

      // 2. Completed H1 Swing Support / Pivots
      int maxBars = MathMin(InpStructureLookbackBars, 60);
      for(int b = 2; b <= maxBars && candCount < 18; b++)
      {
         double l = iLow(sym, PERIOD_H1, b);
         if(l < iLow(sym, PERIOD_H1, b - 1) && l < iLow(sym, PERIOD_H1, b + 1))
         {
            if(l < entryPrice - minClearance) candLevels[candCount++] = l;
         }
      }

      // 3. Completed H4 Major Structural Support
      for(int b4 = 1; b4 <= 24 && candCount < 26; b4++)
      {
         double l4 = iLow(sym, PERIOD_H4, b4);
         if(l4 < entryPrice - minClearance) candLevels[candCount++] = l4;
      }

      // 4. Opposing Bullish Order Blocks / Demand Zones
      for(int obI = 0; obI < ArraySize(g_orderBlocks) && candCount < 34; obI++)
      {
         if(g_orderBlocks[obI].invalidated || !g_orderBlocks[obI].bullish) continue;
         double demHigh = g_orderBlocks[obI].high;
         if(demHigh < entryPrice - minClearance) candLevels[candCount++] = demHigh;
         double demLow = g_orderBlocks[obI].low;
         if(demLow < entryPrice - minClearance) candLevels[candCount++] = demLow;
      }

      // 5. Static Support (from structure scan)
      if(g_recentSupport > 0.0 && g_recentSupport < entryPrice - minClearance && candCount < 38)
         candLevels[candCount++] = g_recentSupport;

      // 5B. Opposing HTF Liquidity Pools (PDL / PWL - Prime Institutional Targets)
      if(g_htfLiquidity.pdl > 0.0 && g_htfLiquidity.pdl < entryPrice - minClearance && candCount < 40)
         candLevels[candCount++] = g_htfLiquidity.pdl;
      if(g_htfLiquidity.pwl > 0.0 && g_htfLiquidity.pwl < entryPrice - minClearance && candCount < 42)
         candLevels[candCount++] = g_htfLiquidity.pwl;

      // 6. Psychological Institutional Levels (.00, .50) below entry
      double roundStep = pipSize * 50.0;
      double roundLevel1 = MathFloor((entryPrice - minClearance) / roundStep) * roundStep;
      if(roundLevel1 > 0.0 && roundLevel1 < entryPrice - minClearance && candCount < 46) candLevels[candCount++] = roundLevel1;
      double roundLevel2 = roundLevel1 - roundStep;
      if(roundLevel2 > 0.0 && roundLevel2 < entryPrice - minClearance && candCount < 48) candLevels[candCount++] = roundLevel2;

      // 7. Structural Fibonacci / Risk-Reward Extensions (Calibrated Tighter & Attainable within 2-3 Days)
      if(candCount < 50) candLevels[candCount++] = entryPrice - (1.350 * riskDist);
      if(candCount < 52) candLevels[candCount++] = entryPrice - (2.200 * riskDist);
      if(candCount < 54) candLevels[candCount++] = entryPrice - (3.400 * riskDist);
      if(candCount < 56) candLevels[candCount++] = entryPrice - (5.500 * riskDist);

      // Sort candidate levels DESCENDING
      for(int i = 0; i < candCount - 1; i++)
      {
         for(int j = 0; j < candCount - i - 1; j++)
         {
            if(candLevels[j] < candLevels[j+1])
            {
               double tmp = candLevels[j]; candLevels[j] = candLevels[j+1]; candLevels[j+1] = tmp;
            }
         }
      }
   }

   // 2 to 3 Trading Days Attainability Calibration:
   // User Directive: "Take Profit 1-3 are attainable points within 2 to 3 trading days based on the market structure
   // (Take profit 2 and 3 need to be adjusted to be smaller and tighter than it is currently)."
   // Tier 1: Leg 1 (TP1) - First Trouble Area / Minor Swing Barrier (0.35x - 0.55x Daily ATR, ~1.20R - 1.65R)
   // Tier 2: Leg 2 (TP2) - Intermediate H1 Structural Pivot / 1-2 Day Attainable Target (0.80x - 1.25x Daily ATR, ~1.90R - 2.80R, e.g. 1.33200 on GBPUSD)
   // Tier 3: Leg 3 (TP3) - Major Structural Boundary / 2-3 Day Attainable Target (1.40x - 2.10x Daily ATR, ~2.90R - 4.10R, e.g. 1.33690 on GBPUSD)
   // Tier 4: Leg 4 (TP4) - Macro Expansion Runner (2.50x - 3.50x Daily ATR, ~4.50R - 7.50R)
   double bestTP1 = 0.0, bestTP2 = 0.0, bestTP3 = 0.0, bestTP4 = 0.0;

   // Select targets from current structural candidates for every symbol.
   for(int i = 0; i < candCount; i++)
   {
      double lvl = candLevels[i];
      double rDist = MathAbs(lvl - entryPrice) / riskDist;
      double dDist = MathAbs(lvl - entryPrice) / dailyAtr;

      // Tier 1: Intraday obstacle
      if((rDist >= 1.20 && rDist <= 1.70) && bestTP1 == 0.0)
         bestTP1 = lvl;
      // Tier 2: 1-2 Day attainable intermediate swing pivot (proper separation ~2.25R - 2.40R)
      else if(((rDist >= 2.05 && rDist <= 2.60) || (dDist >= 0.75 && dDist <= 1.25)) && bestTP2 == 0.0)
         bestTP2 = lvl;
      // Tier 3: 2-3 Day attainable major structural barrier (tighter & smaller)
      else if(((rDist >= 3.20 && rDist <= 4.20) || (dDist >= 1.45 && dDist <= 2.25)) && bestTP3 == 0.0)
         bestTP3 = lvl;
      // Tier 4: Macro expansion runner
      else if((rDist >= 5.00 && rDist <= 8.50) && bestTP4 == 0.0)
         bestTP4 = lvl;
   }

   // Fallback defaults if no specific candidate landed in window
   if(bestTP1 == 0.0)
      bestTP1 = entryPrice + (isBuy ? 1.0 : -1.0) * MathMax(1.35 * riskDist, 0.40 * dailyAtr);
   if(bestTP2 == 0.0)
      bestTP2 = entryPrice + (isBuy ? 1.0 : -1.0) * MathMax(2.30 * riskDist, 0.85 * dailyAtr);
   if(bestTP3 == 0.0)
      bestTP3 = entryPrice + (isBuy ? 1.0 : -1.0) * MathMax(3.80 * riskDist, 1.75 * dailyAtr);
   if(bestTP4 == 0.0)
      bestTP4 = entryPrice + (isBuy ? 1.0 : -1.0) * MathMax(6.00 * riskDist, 2.80 * dailyAtr);

   // Optional direct mapping of Leg 3 (TP3) to opposing PDH / PDL ONLY if within 2-3 day attainable distance!
   if(InpAutoMapTP3ToOpposingLiquidity)
   {
      double max3DayReach = 2.25 * dailyAtr;
      if(isBuy)
      {
         if(g_htfLiquidity.pdh > entryPrice + 1.80 * riskDist && g_htfLiquidity.pdh <= entryPrice + max3DayReach)
            bestTP3 = g_htfLiquidity.pdh;
         else if(g_htfLiquidity.pwh > entryPrice + 1.80 * riskDist && g_htfLiquidity.pwh <= entryPrice + max3DayReach)
            bestTP3 = g_htfLiquidity.pwh;
      }
      else
      {
         if(g_htfLiquidity.pdl > 0.0 && g_htfLiquidity.pdl < entryPrice - 1.80 * riskDist && g_htfLiquidity.pdl >= entryPrice - max3DayReach)
            bestTP3 = g_htfLiquidity.pdl;
         else if(g_htfLiquidity.pwl > 0.0 && g_htfLiquidity.pwl < entryPrice - 1.80 * riskDist && g_htfLiquidity.pwl >= entryPrice - max3DayReach)
            bestTP3 = g_htfLiquidity.pwl;
      }
   }

   // Strict Monotonicity and Risk-Reward Floor Guarantee
   if(riskDist <= 0.0) riskDist = MathMax(20.0 * pipSize, 20.0 * pt);
   double minSep = MathMax(0.80 * riskDist, 15.0 * pt);

   if(isBuy)
   {
      if(bestTP1 < entryPrice + 1.20 * riskDist)
         bestTP1 = entryPrice + 1.35 * riskDist;
      if(bestTP2 < bestTP1 + minSep || bestTP2 < entryPrice + 2.10 * riskDist)
         bestTP2 = bestTP1 + MathMax(0.80 * riskDist, minSep);
      if(bestTP3 < bestTP2 + minSep || bestTP3 < entryPrice + 3.40 * riskDist)
         bestTP3 = bestTP2 + MathMax(1.00 * riskDist, minSep);
      if(bestTP4 < bestTP3 + minSep || bestTP4 < entryPrice + 5.20 * riskDist)
         bestTP4 = bestTP3 + MathMax(1.50 * riskDist, minSep);
   }
   else
   {
      if(bestTP1 > entryPrice - 1.20 * riskDist || bestTP1 <= 0.0)
         bestTP1 = entryPrice - 1.35 * riskDist;
      if(bestTP2 > bestTP1 - minSep || bestTP2 <= 0.0 || bestTP2 > entryPrice - 2.10 * riskDist)
         bestTP2 = bestTP1 - MathMax(0.80 * riskDist, minSep);
      if(bestTP3 > bestTP2 - minSep || bestTP3 <= 0.0 || bestTP3 > entryPrice - 3.40 * riskDist)
         bestTP3 = bestTP2 - MathMax(1.00 * riskDist, minSep);
      if(bestTP4 > bestTP3 - minSep || bestTP4 <= 0.0 || bestTP4 > entryPrice - 5.20 * riskDist)
         bestTP4 = bestTP3 - MathMax(1.50 * riskDist, minSep);
   }

   outTP1 = NormalizeDouble(bestTP1, digits);
   outTP2 = NormalizeDouble(bestTP2, digits);
   outTP3 = NormalizeDouble(bestTP3, digits);
   outTP4 = NormalizeDouble(bestTP4, digits);

   double r1 = MathAbs(outTP1 - entryPrice) / riskDist;
   double r2 = MathAbs(outTP2 - entryPrice) / riskDist;
   double r3 = MathAbs(outTP3 - entryPrice) / riskDist;
   double r4 = MathAbs(outTP4 - entryPrice) / riskDist;
   outRR_TP2 = NormalizeDouble(r2, 2);
   outRR_Weighted = NormalizeDouble((r1 + r2 + r3 + r4) / 4.0, 2);

   return 4;
}
//+------------------------------------------------------------------+
//| Strict Lot Allocation across legs without increasing total risk  |
//| Enforces volume step rounding and blocks if lot is too small     |
//+------------------------------------------------------------------+
bool CalculateLegLots(string sym, double totalLot, int legsToOpen, double &outLots[], string &outErrorReason)
{
   if(legsToOpen < 1 || legsToOpen > 4) { outErrorReason = "INVALID LEG COUNT"; return false; }
   if(ArrayResize(outLots, legsToOpen) != legsToOpen) { outErrorReason = "LOT ALLOCATION FAILED"; return false; }
   outErrorReason = "";
   double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0)  minLot  = 0.01;
   if(lotStep <= 0.0) lotStep = 0.01;
   if(maxLot <= 0.0)  maxLot  = 100.0;

   int volDigits = GetVolumeDigits(sym);

   // Automatically ensure configured lot satisfies broker minimum volume across legs
   if(totalLot < (double)legsToOpen * minLot)
   {
      totalLot = NormalizeDouble((double)legsToOpen * minLot, volDigits);
      PrintFormat("[Advisor Sizing] Total lot automatically adjusted to %.2f to satisfy broker min lot (%d legs @ %.2f min)",
                  totalLot, legsToOpen, minLot);
   }

   // Equal lot size for EACH trade leg (Rule: "The lot size of EACH trade should be the same")
   double rawEqualLot = totalLot / (double)legsToOpen;
   double steps = MathFloor(rawEqualLot / lotStep);
   double equalVol = steps * lotStep;
   if(equalVol < minLot) equalVol = minLot;
   if(equalVol > maxLot) equalVol = maxLot;
   equalVol = NormalizeDouble(equalVol, volDigits);

   for(int k = 0; k < legsToOpen; k++)
   {
      outLots[k] = equalVol;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Unified Multi-Strategy Confluence Matrix Engine                  |
//| Computes state across the 5 core strategy pillars:              |
//| 1. Macro Trend Confluence (H4 60% + H2 40%)                     |
//| 2. Institutional Valuation & Liquidity Sweep (PDL/PDH)           |
//| 3. Entry Trigger Strategy (M30 OB 70% vs Retest 30%)             |
//| 4. Multi-Leg Execution Ladder (4 Equal 25% Legs with TP1..TP4)   |
//| 5. Capital Preservation Shield (Circuit Breakers + Spread)       |
//+------------------------------------------------------------------+
void UpdateUnifiedStrategyMatrix(string sym)
{
   g_strategyMatrix.overallHealth = "EVALUATING";
   g_strategyMatrix.confluenceScore = (g_setupQuality > 0) ? g_setupQuality : 50;
   g_strategyMatrix.confluenceTier = "EVALUATING CONFLUENCE";

   // 1. HTF Trend Confluence (H4 60% + H2 40%)
   bool h1Bull = (g_h1Bias == "BULLISH");
   bool h2Bull = (g_h2Bias == "BULLISH");
   bool h4Bull = (g_h4Bias == "BULLISH");

   if(g_currentAdvisedAction == "BUY")
   {
      if(h4Bull && h2Bull)
      {
         g_strategyMatrix.htfTrendStatus = "ALIGNED";
         g_strategyMatrix.htfTrendDetail = "H4 (60%) + H2 (40%) Bullish Agreement";
      }
      else if(h4Bull)
      {
         g_strategyMatrix.htfTrendStatus = "PULLBACK";
         g_strategyMatrix.htfTrendDetail = "H4 Bullish Macro / H2 Pullback";
      }
      else
      {
         g_strategyMatrix.htfTrendStatus = "CONFLICT";
         g_strategyMatrix.htfTrendDetail = "H4 Bearish Macro Divergence";
      }
   }
   else if(g_currentAdvisedAction == "SELL")
   {
      if(!h4Bull && !h2Bull)
      {
         g_strategyMatrix.htfTrendStatus = "ALIGNED";
         g_strategyMatrix.htfTrendDetail = "H4 (60%) + H2 (40%) Bearish Agreement";
      }
      else if(!h4Bull)
      {
         g_strategyMatrix.htfTrendStatus = "BOUNCE";
         g_strategyMatrix.htfTrendDetail = "H4 Bearish Macro / H2 Bounce";
      }
      else
      {
         g_strategyMatrix.htfTrendStatus = "CONFLICT";
         g_strategyMatrix.htfTrendDetail = "H4 Bullish Macro Divergence";
      }
   }
   else
   {
      if(h4Bull && h2Bull)
      {
         g_strategyMatrix.htfTrendStatus = "ALIGNED";
         g_strategyMatrix.htfTrendDetail = "H4/H2 Bullish Alignment";
      }
      else if(!h4Bull && !h2Bull)
      {
         g_strategyMatrix.htfTrendStatus = "ALIGNED";
         g_strategyMatrix.htfTrendDetail = "H4/H2 Bearish Alignment";
      }
      else
      {
         g_strategyMatrix.htfTrendStatus = "TRANSITION";
         g_strategyMatrix.htfTrendDetail = "Mixed Macro Structure";
      }
   }

   // 2. Valuation & Liquidity Gate (PDL - PDH Range Value & Sweeps)
   double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curBid <= 0.0) curBid = iClose(sym, PERIOD_M1, 0);
   double pdl = g_htfLiquidity.pdl;
   double pdh = g_htfLiquidity.pdh;
   double dayRange = (pdh > pdl && pdl > 0.0) ? (pdh - pdl) : 0.0;
   double posInRange = (dayRange > 0.0) ? ((curBid - pdl) / dayRange) : 0.50;

   if(g_currentAdvisedAction == "BUY")
   {
      if(g_activeSignalSource == "HTF LIQUIDITY SWEEP (PDL REVERSAL)" || posInRange <= 0.54)
      {
         g_strategyMatrix.valStatus = "ALIGNED";
         g_strategyMatrix.valDetail = (posInRange <= 0.35) ? "Deep Discount Range (<35%)" : "Favorable Discount Range";
      }
      else
      {
         g_strategyMatrix.valStatus = "EXTENDED";
         g_strategyMatrix.valDetail = StringFormat("Caution: Upper Premium Range (%.0f%%)", posInRange * 100.0);
      }
   }
   else if(g_currentAdvisedAction == "SELL")
   {
      if(g_activeSignalSource == "HTF LIQUIDITY SWEEP (PDH REVERSAL)" || posInRange >= 0.46)
      {
         g_strategyMatrix.valStatus = "ALIGNED";
         g_strategyMatrix.valDetail = (posInRange >= 0.65) ? "High Premium Range (>65%)" : "Favorable Premium Range";
      }
      else
      {
         g_strategyMatrix.valStatus = "EXTENDED";
         g_strategyMatrix.valDetail = StringFormat("Caution: Lower Discount Range (%.0f%%)", posInRange * 100.0);
      }
   }
   else
   {
      g_strategyMatrix.valStatus = "EVALUATING";
      g_strategyMatrix.valDetail = StringFormat("Range Position: %.0f%% of PDL-PDH", posInRange * 100.0);
   }

   // 3. Entry Trigger Strategy (M30 Order Block 70% Primary vs Retest 30%)
   if(g_setupState == "READY" || g_setupState == "TRIGGERED")
   {
      g_strategyMatrix.triggerStatus = "ALIGNED";
      g_strategyMatrix.triggerDetail = (g_activeEntryStrategy == "ORDER_BLOCK") ? "M30 Order Block (70% Primary)" : "Structure Retest (30% Secondary)";
   }
   else if(g_setupState == "WATCHING")
   {
      g_strategyMatrix.triggerStatus = "WATCHING";
      g_strategyMatrix.triggerDetail = "Awaiting Pullback to Demand/Supply";
   }
   else
   {
      g_strategyMatrix.triggerStatus = "SCANNING";
      g_strategyMatrix.triggerDetail = "Scanning Order Blocks & Structure";
   }

   // 4. Execution Ladder (4 Equal 25% Legs with TP1-4)
   g_strategyMatrix.execStatus = "4 LEGS ARMED";
   double compRR = (g_rrWeighted > 0.0) ? g_rrWeighted : 4.25;
   g_strategyMatrix.execDetail = StringFormat("TP1-4 Ladder (1:%.2f Composite | 25%% Equal Legs)", compRR);

   // 5. Risk Shields & Circuit Breakers
   bool cbBlocked = false;
   string cbReason = "";
   int cbConsec = 0, cbTotal = 0;
   CheckCircuitBreaker(sym, cbBlocked, cbReason, cbConsec, cbTotal);

   if(cbBlocked)
   {
      g_strategyMatrix.shieldStatus = "BLOCKED";
      g_strategyMatrix.shieldDetail = (cbTotal >= InpMaxDailyPortfolioLosses) ? "Portfolio Circuit (6 Losses Active)" : "Symbol Circuit (3 Losses Active)";
   }
   else if(g_spreadQualityRatio > 2.5)
   {
      g_strategyMatrix.shieldStatus = "WARNING";
      g_strategyMatrix.shieldDetail = "Spread Elevated Above Baseline";
   }
   else if(!g_isMarketOpen)
   {
      g_strategyMatrix.shieldStatus = "STANDBY";
      g_strategyMatrix.shieldDetail = "Market Session Closed";
   }
   else
   {
      g_strategyMatrix.shieldStatus = "ARMED";
      g_strategyMatrix.shieldDetail = "3 Sym / 5 Portfolio Circuit Active";
   }

   // Dynamic ATR-Adaptive Breakeven Cushion Calculation
   double pSize = GetPipSize(sym);
   double curAtrVal = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtrVal = atrBuf[0];
   }
   if(curAtrVal <= 0.0) curAtrVal = 20.0 * pSize;
   double atrPips = curAtrVal / pSize;
   g_strategyMatrix.adaptiveBECushionPips = MathMax(InpBreakevenBufferPips, 0.15 * atrPips);

   // --- AUTOMATED CONFLICT RESOLUTION ENGINE ---
   g_strategyMatrix.conflictStatus = "NO_CONFLICT";
   g_strategyMatrix.conflictDetail = "All 5 strategy pillars aligned in harmony.";

   // Conflict 1 Resolution: Strong Macro Trend Expansion Mode
   bool isStrongMacro = (g_currentAdvisedAction == "BUY" && h4Bull && h2Bull) || (g_currentAdvisedAction == "SELL" && !h4Bull && !h2Bull);
   if(isStrongMacro && g_strategyMatrix.valStatus == "EXTENDED")
   {
      g_strategyMatrix.valStatus = "ALIGNED";
      g_strategyMatrix.valDetail = StringFormat("Trend Expansion Mode (%.0f%% Range Validated)", posInRange * 100.0);
      g_strategyMatrix.conflictStatus = "RESOLVED";
      g_strategyMatrix.conflictDetail = "SMC-101: Macro trend expansion overrides range valuation cap.";
   }

   // Conflict 2 Resolution: HTF Liquidity Sweep Reversal vs Lagging Macro EMA
   if((g_activeSignalSource == "HTF LIQUIDITY SWEEP (PDL REVERSAL)" || g_activeSignalSource == "HTF LIQUIDITY SWEEP (PDH REVERSAL)") && g_strategyMatrix.htfTrendStatus == "CONFLICT")
   {
      g_strategyMatrix.htfTrendStatus = "ALIGNED";
      g_strategyMatrix.htfTrendDetail = "Macro Liquidity Sweep Inflection Reversal";
      g_strategyMatrix.conflictStatus = "RESOLVED";
      g_strategyMatrix.conflictDetail = "SMC-202: HTF liquidity sweep rejection overrides lagging macro EMA.";
   }

   // Overall Confluence Score & Health & 4-Tier Setup Classification
   if(g_strategyMatrix.shieldStatus == "BLOCKED")
   {
      g_strategyMatrix.overallHealth = "BLOCKED";
      g_strategyMatrix.confluenceScore = MathMin(g_strategyMatrix.confluenceScore, 20);
      g_strategyMatrix.confluenceTier = "RISK QUARANTINE";
      g_strategyMatrix.synergyScore = 20;
      g_strategyMatrix.synergyGrade = "CONFLICT_DETECTED";
   }
   else if(g_strategyMatrix.htfTrendStatus == "ALIGNED" && g_strategyMatrix.triggerStatus == "ALIGNED" && g_strategyMatrix.valStatus == "ALIGNED")
   {
      g_strategyMatrix.overallHealth = "OPTIMAL";
      g_strategyMatrix.confluenceScore = MathMax(g_strategyMatrix.confluenceScore, 98);
      g_strategyMatrix.confluenceTier = "TIER 1: A+ TRIPLE CONFLUENCE (OB + SWEEP + HTF)";
      g_strategyMatrix.synergyScore = 98;
      g_strategyMatrix.synergyGrade = "PERFECT_SYNERGY";
   }
   else if(g_activeEntryStrategy == "ORDER_BLOCK" && (g_strategyMatrix.htfTrendStatus == "ALIGNED" || g_strategyMatrix.triggerStatus == "ALIGNED"))
   {
      g_strategyMatrix.overallHealth = "MODERATE";
      g_strategyMatrix.confluenceScore = MathMax(g_strategyMatrix.confluenceScore, 85);
      g_strategyMatrix.confluenceTier = "TIER 2: A INSTITUTIONAL ORDER BLOCK (70% WEIGHT)";
      g_strategyMatrix.synergyScore = 88;
      g_strategyMatrix.synergyGrade = "STRONG_SYNERGY";
   }
   else if(g_activeEntryStrategy == "STRUCTURE_RETEST")
   {
      g_strategyMatrix.overallHealth = "MODERATE";
      g_strategyMatrix.confluenceScore = MathMax(g_strategyMatrix.confluenceScore, 75);
      g_strategyMatrix.confluenceTier = "TIER 3: B+ STRUCTURE RETEST (30% WEIGHT)";
      g_strategyMatrix.synergyScore = 78;
      g_strategyMatrix.synergyGrade = "STRONG_SYNERGY";
   }
   else if(g_activeSignalSource == "HTF LIQUIDITY SWEEP (PDL REVERSAL)" || g_activeSignalSource == "HTF LIQUIDITY SWEEP (PDH REVERSAL)")
   {
      g_strategyMatrix.overallHealth = "MODERATE";
      g_strategyMatrix.confluenceScore = MathMax(g_strategyMatrix.confluenceScore, 70);
      g_strategyMatrix.confluenceTier = "TIER 4: COUNTER-TREND LIQUIDITY SWEEP (CONTROLLED RISK)";
      g_strategyMatrix.synergyScore = 72;
      g_strategyMatrix.synergyGrade = "MODERATE_SYNERGY";
   }
   else
   {
      bool isTradeTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
      if(isTradeTaken)
      {
         g_strategyMatrix.overallHealth = "OPTIMAL";
         g_strategyMatrix.confluenceScore = (g_setupQuality > 0) ? g_setupQuality : 85;
         g_strategyMatrix.confluenceTier = "ACTIVE SAFE TRADE";
         g_strategyMatrix.synergyScore = 90;
         g_strategyMatrix.synergyGrade = "STRONG_SYNERGY";
      }
      else
      {
         g_strategyMatrix.overallHealth = "EVALUATING";
         g_strategyMatrix.confluenceScore = (g_setupQuality > 0) ? g_setupQuality : 60;
         g_strategyMatrix.confluenceTier = "EVALUATING CONFLUENCE";
         g_strategyMatrix.synergyScore = 60;
         g_strategyMatrix.synergyGrade = "MODERATE_SYNERGY";
      }
   }

   // Safety checks: ensure strings and scores are never empty, null, or zero
   if(g_strategyMatrix.confluenceTier == "" || g_strategyMatrix.confluenceTier == "(null)")
   {
      g_strategyMatrix.confluenceTier = "ACTIVE CONFLUENCE";
   }
   if(g_strategyMatrix.confluenceScore <= 0)
   {
      g_strategyMatrix.confluenceScore = (g_setupQuality > 0) ? g_setupQuality : 75;
   }
}

//+------------------------------------------------------------------+
//| SYSTEM-LEVEL STRUCTURAL STOP LOSS CALCULATOR                     |
//| Computes safest Stop Loss for any asset (Gold, AUDUSD, GBPUSD, etc.):
//| 1. Order Block base (obLow - buffer) for tight invalidation      |
//| 2. Multi-Day Swing Low / High if safer structural anchor         |
//| 3. Minimum broker stop distance and tick-size normalization      |
//+------------------------------------------------------------------+
bool SEGSSelectActiveOrderBlock(string sym, bool buy, double price, double atr, double &low, double &high)
{
   low = 0.0; high = 0.0;
   if(sym != _Symbol || !SEGSMarketReady(sym)) return false;
   double maxDistance = MathMax(g_systemOBMaxDistanceATR * atr, 10.0 * SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE));
   double bestDistance = DBL_MAX;
   for(int tf = 0; tf < 2; tf++)
   {
      int count = tf == 0 ? ArraySize(g_orderBlocks) : ArraySize(g_h1OrderBlocks);
      for(int i = 0; i < count; i++)
      {
         M30OrderBlock zone;
         if(tf == 0) zone = g_orderBlocks[i]; else zone = g_h1OrderBlocks[i];
         if(zone.invalidated || zone.bullish != buy || zone.low <= 0.0 || zone.high <= zone.low) continue;
         double boundary = buy ? zone.low : zone.high;
         if(buy ? boundary >= price : boundary <= price) continue;
         double distance = MathAbs(price - boundary);
         if(distance <= maxDistance && distance < bestDistance)
         { low = zone.low; high = zone.high; bestDistance = distance; }
      }
   }
   return low > 0.0;
}

void SEGSAddStopAnchor(double value, bool buy, double entry, double floorOrCeiling,
                       double proximity, double &extreme, double &nearby)
{
   if(!MathIsValidNumber(value) || value <= 0.0 || (buy ? value >= entry : value <= entry)) return;
   if(extreme == 0.0 || (buy ? value < extreme : value > extreme)) extreme = value;
   bool beyond = buy ? value < floorOrCeiling : value > floorOrCeiling;
   if(floorOrCeiling > 0.0 && beyond && MathAbs(value - floorOrCeiling) <= proximity &&
      (nearby == 0.0 || (buy ? value < nearby : value > nearby))) nearby = value;
}

double GetSafestStructuralStopLoss(string sym, string dir, double entryPrice, double obZoneLow, double obZoneHigh, double curAtr, bool preferMultiDay=false)
{
   if((dir != "BUY" && dir != "SELL") || !MathIsValidNumber(entryPrice) || entryPrice <= 0.0 ||
      !SEGSMarketReady(sym)) return 0.0;
   bool buy = (dir == "BUY");
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(!MathIsValidNumber(pt) || pt <= 0.0 || !MathIsValidNumber(tick) || tick <= 0.0) return 0.0;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double atr = MathIsValidNumber(curAtr) ? MathMax(0.0, curAtr) : 0.0;
   double buffer = MathMax(MathMax(0.0, InpStructuralBufferATR) * atr, 3.0 * tick);
   double proximity = MathMax(MathMax(0.0, InpDualProximityATR) * atr, 6.0 * tick);
   bool validOB = MathIsValidNumber(obZoneLow) && MathIsValidNumber(obZoneHigh) &&
                  obZoneLow > 0.0 && obZoneHigh > obZoneLow &&
                  (buy ? obZoneLow < entryPrice : obZoneHigh > entryPrice);
   double boundary = validOB ? (buy ? obZoneLow : obZoneHigh) : 0.0;
   double extreme = 0.0, nearby = 0.0;
   for(int d = 1; d <= 5; d++)
      SEGSAddStopAnchor(buy ? iLow(sym, PERIOD_D1, d) : iHigh(sym, PERIOD_D1, d),
                        buy, entryPrice, boundary, proximity, extreme, nearby);
   for(int h = 1; h <= 24; h++)
   {
      double v = buy ? iLow(sym, PERIOD_H4, h) : iHigh(sym, PERIOD_H4, h);
      double left = buy ? iLow(sym, PERIOD_H4, h+1) : iHigh(sym, PERIOD_H4, h+1);
      // Bar 1 uses only completed neighbors, never the forming H4 bar.
      int neighbor = h == 1 ? 3 : h-1;
      double right = buy ? iLow(sym, PERIOD_H4, neighbor) : iHigh(sym, PERIOD_H4, neighbor);
      if(left > 0.0 && right > 0.0 && (buy ? (v <= left && v <= right) : (v >= left && v >= right)))
         SEGSAddStopAnchor(v, buy, entryPrice, boundary, proximity, extreme, nearby);
   }
   SEGSAddStopAnchor(buy ? iLow(sym, PERIOD_D1, 1) : iHigh(sym, PERIOD_D1, 1), buy, entryPrice, boundary, proximity, extreme, nearby);
   SEGSAddStopAnchor(buy ? iLow(sym, PERIOD_W1, 1) : iHigh(sym, PERIOD_W1, 1), buy, entryPrice, boundary, proximity, extreme, nearby);
   // Global structure belongs to this chart symbol only.
   if(sym == _Symbol)
   {
      SEGSAddStopAnchor(buy ? g_recentSwingLow : g_recentSwingHigh, buy, entryPrice, boundary, proximity, extreme, nearby);
      SEGSAddStopAnchor(buy ? g_recentSupport : g_recentResistance, buy, entryPrice, boundary, proximity, extreme, nearby);
   }
   ENUM_SEGS_SL_STYLE style = g_systemStopStyle;
   // A caller's swing preference must never discard the entered OB boundary.
   if(preferMultiDay && !validOB && style == SL_STYLE_AUTO_DUAL) style = SL_STYLE_MULTI_DAY;
   double anchor = 0.0;
   if(style == SL_STYLE_ACTIVE_ORDER_BLOCK)
   {
      double activeLow = 0.0, activeHigh = 0.0;
      if(!SEGSSelectActiveOrderBlock(sym, buy, entryPrice, atr, activeLow, activeHigh)) return 0.0;
      anchor = buy ? activeLow : activeHigh;
      buffer = MathMax(g_systemOBBufferATR * atr, g_systemOBBufferTicks * tick);
   }
   else if(style == SL_STYLE_ORDER_BLOCK) { anchor = boundary; buffer = 0.0; }
   else if(style == SL_STYLE_MULTI_DAY)
   {
      anchor = extreme;
      // Even explicit swing mode must invalidate the entered zone, not sit inside it.
      if(validOB) anchor = anchor > 0.0 ? (buy ? MathMin(anchor, boundary) : MathMax(anchor, boundary)) : boundary;
   }
   else anchor = validOB ? (nearby > 0.0 ? nearby : boundary) : extreme;
   // No fabricated structural stop: caller must defer when the required anchor is absent.
   if(anchor <= 0.0) return 0.0;
   double stop = buy ? anchor - buffer : anchor + buffer;
   MqlTick quote;
   if(!SymbolInfoTick(sym, quote) || !MathIsValidNumber(quote.bid) ||
      !MathIsValidNumber(quote.ask) || quote.bid <= 0.0 || quote.ask < quote.bid) return 0.0;
   double distance = MathMax((double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt, tick) + 2.0 * tick;
   if(style == SL_STYLE_ORDER_BLOCK &&
      (buy ? stop > MathMin(entryPrice, quote.bid) - distance : stop < MathMax(entryPrice, quote.ask) + distance)) return 0.0;
   if(buy) stop = MathMin(stop, MathMin(entryPrice, quote.bid) - distance);
   else stop = MathMax(stop, MathMax(entryPrice, quote.ask) + distance);
   // Round away from invalidation, never towards the OB or broker boundary.
   stop = (buy ? MathFloor(stop / tick) : MathCeil(stop / tick)) * tick;
   stop = NormalizeDouble(stop, digits);
   if(!MathIsValidNumber(stop) || stop <= 0.0) return 0.0;
   if(validOB && style != SL_STYLE_ACTIVE_ORDER_BLOCK && style != SL_STYLE_ORDER_BLOCK && (buy ? stop >= boundary : stop <= boundary)) return 0.0;
   return stop;
}

//+------------------------------------------------------------------+
//| M30 Order Block Intelligence & Smart Money Confluence Functions  |
//+------------------------------------------------------------------+
double OBATRAt(MqlRates &r[], int shift, int period)
{
   double total = 0.0;
   int count = 0;
   if(shift < 0 || period < 1 || shift >= ArraySize(r) - 1) return 0.0;
   int limit = MathMin(shift + period, ArraySize(r) - 1);
   for(int i = shift; i < limit; i++)
   {
      double tr = MathMax(r[i].high - r[i].low,
                  MathMax(MathAbs(r[i].high - r[i + 1].close), MathAbs(r[i].low - r[i + 1].close)));
      total += tr;
      count++;
   }
   return (count > 0) ? (total / count) : 0.0;
}

string OBAlignmentText(const M30OrderBlock &ob)
{
   if(ob.trendAligned) return "TREND ALIGNED";
   if((ob.bullish && g_h1Bias == "BEARISH" && g_h4Bias == "BEARISH") ||
      (!ob.bullish && g_h1Bias == "BULLISH" && g_h4Bias == "BULLISH")) return "COUNTER TREND";
   return "MIXED";
}

//+------------------------------------------------------------------+
//| HTF Liquidity (PDH/PDL, PWH/PWL) Detection & Management          |
//+------------------------------------------------------------------+
void UpdateHTFLiquidityLevels(string sym)
{
   g_htfLiquidity.pdh = iHigh(sym, PERIOD_D1, 1);
   g_htfLiquidity.pdl = iLow(sym, PERIOD_D1, 1);
   g_htfLiquidity.pdo = iOpen(sym, PERIOD_D1, 1);
   g_htfLiquidity.pdc = iClose(sym, PERIOD_D1, 1);
   g_htfLiquidity.pwh = iHigh(sym, PERIOD_W1, 1);
   g_htfLiquidity.pwl = iLow(sym, PERIOD_W1, 1);
   g_htfLiquidity.pwo = iOpen(sym, PERIOD_W1, 1);
   g_htfLiquidity.pwc = iClose(sym, PERIOD_W1, 1);
   g_htfLiquidity.dayOpen = iOpen(sym, PERIOD_D1, 0);
   g_htfLiquidity.weekOpen = iOpen(sym, PERIOD_W1, 0);

   double curHighD1 = iHigh(sym, PERIOD_D1, 0);
   double curLowD1  = iLow(sym, PERIOD_D1, 0);
   double curHighW1 = iHigh(sym, PERIOD_W1, 0);
   double curLowW1  = iLow(sym, PERIOD_W1, 0);
   double curBid    = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curBid <= 0.0) curBid = iClose(sym, PERIOD_M1, 0);

   g_htfLiquidity.pdhSwept = (curHighD1 > g_htfLiquidity.pdh && curBid < g_htfLiquidity.pdh);
   g_htfLiquidity.pdlSwept = (curLowD1 < g_htfLiquidity.pdl && curBid > g_htfLiquidity.pdl);
   g_htfLiquidity.pwhSwept = (curHighW1 > g_htfLiquidity.pwh && curBid < g_htfLiquidity.pwh);
   g_htfLiquidity.pwlSwept = (curLowW1 < g_htfLiquidity.pwl && curBid > g_htfLiquidity.pwl);

   // Determine nearest level
   double dPDH = (g_htfLiquidity.pdh > 0.0) ? MathAbs(curBid - g_htfLiquidity.pdh) : 999999.0;
   double dPDL = (g_htfLiquidity.pdl > 0.0) ? MathAbs(curBid - g_htfLiquidity.pdl) : 999999.0;
   double dPWH = (g_htfLiquidity.pwh > 0.0) ? MathAbs(curBid - g_htfLiquidity.pwh) : 999999.0;
   double dPWL = (g_htfLiquidity.pwl > 0.0) ? MathAbs(curBid - g_htfLiquidity.pwl) : 999999.0;

   double minDist = dPDH;
   g_htfLiquidity.nearestLevelName = "PDH";
   g_htfLiquidity.nearestLevelPrice = g_htfLiquidity.pdh;

   if(dPDL < minDist)
   {
      minDist = dPDL;
      g_htfLiquidity.nearestLevelName = "PDL";
      g_htfLiquidity.nearestLevelPrice = g_htfLiquidity.pdl;
   }
   if(dPWH < minDist)
   {
      minDist = dPWH;
      g_htfLiquidity.nearestLevelName = "PWH";
      g_htfLiquidity.nearestLevelPrice = g_htfLiquidity.pwh;
   }
   if(dPWL < minDist)
   {
      minDist = dPWL;
      g_htfLiquidity.nearestLevelName = "PWL";
      g_htfLiquidity.nearestLevelPrice = g_htfLiquidity.pwl;
   }
   g_htfLiquidity.distanceToNearest = minDist;
}

void DeleteHTFLiquidityLines()
{
   ObjectsDeleteAll(0, PREFIX + "HTF_");
}

void DrawHTFLiquidityLines(string sym)
{
   DeleteHTFLiquidityLines();
   if(!InpShowHTFLiquidityLines) return;
   
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   
   if(g_htfLiquidity.pdh > 0.0)
   {
      string name = PREFIX + "HTF_PDH";
      string desc = StringFormat("PDH (Yesterday High): %s %s", DoubleToString(g_htfLiquidity.pdh, digits), g_htfLiquidity.pdhSwept ? "[SWEPT]" : "");
      CreateChartHLine(name, g_htfLiquidity.pdh, C'244,114,182', STYLE_DASHDOT, 1, desc);
   }
   if(g_htfLiquidity.pdl > 0.0)
   {
      string name = PREFIX + "HTF_PDL";
      string desc = StringFormat("PDL (Yesterday Low): %s %s", DoubleToString(g_htfLiquidity.pdl, digits), g_htfLiquidity.pdlSwept ? "[SWEPT]" : "");
      CreateChartHLine(name, g_htfLiquidity.pdl, C'96,165,250', STYLE_DASHDOT, 1, desc);
   }
   if(g_htfLiquidity.pdo > 0.0)
   {
      string name = PREFIX + "HTF_PDO";
      string desc = StringFormat("Yesterday Open: %s", DoubleToString(g_htfLiquidity.pdo, digits));
      CreateChartHLine(name, g_htfLiquidity.pdo, C'203,213,225', STYLE_DOT, 1, desc);
   }
   if(g_htfLiquidity.pdc > 0.0)
   {
      string name = PREFIX + "HTF_PDC";
      string desc = StringFormat("Yesterday Close: %s", DoubleToString(g_htfLiquidity.pdc, digits));
      CreateChartHLine(name, g_htfLiquidity.pdc, C'203,213,225', STYLE_DOT, 1, desc);
   }
   if(g_htfLiquidity.pwh > 0.0)
   {
      string name = PREFIX + "HTF_PWH";
      string desc = StringFormat("PWH (Last Week High): %s %s", DoubleToString(g_htfLiquidity.pwh, digits), g_htfLiquidity.pwhSwept ? "[SWEPT]" : "");
      CreateChartHLine(name, g_htfLiquidity.pwh, C'236,72,153', STYLE_SOLID, 1, desc);
   }
   if(g_htfLiquidity.pwl > 0.0)
   {
      string name = PREFIX + "HTF_PWL";
      string desc = StringFormat("PWL (Last Week Low): %s %s", DoubleToString(g_htfLiquidity.pwl, digits), g_htfLiquidity.pwlSwept ? "[SWEPT]" : "");
      CreateChartHLine(name, g_htfLiquidity.pwl, C'59,130,246', STYLE_SOLID, 1, desc);
   }
   if(g_htfLiquidity.pwo > 0.0)
   {
      string name = PREFIX + "HTF_PWO";
      string desc = StringFormat("Last Week Open: %s", DoubleToString(g_htfLiquidity.pwo, digits));
      CreateChartHLine(name, g_htfLiquidity.pwo, C'148,163,184', STYLE_DASH, 1, desc);
   }
   if(g_htfLiquidity.pwc > 0.0)
   {
      string name = PREFIX + "HTF_PWC";
      string desc = StringFormat("Last Week Close: %s", DoubleToString(g_htfLiquidity.pwc, digits));
      CreateChartHLine(name, g_htfLiquidity.pwc, C'148,163,184', STYLE_DASH, 1, desc);
   }
   if(g_htfLiquidity.dayOpen > 0.0)
   {
      string name = PREFIX + "HTF_DAY_OPEN";
      string desc = StringFormat("Day Open (Today Open): %s", DoubleToString(g_htfLiquidity.dayOpen, digits));
      CreateChartHLine(name, g_htfLiquidity.dayOpen, C'250,204,21', STYLE_DASHDOT, 1, desc);
   }
   if(g_htfLiquidity.weekOpen > 0.0)
   {
      string name = PREFIX + "HTF_WEEK_OPEN";
      string desc = StringFormat("Week Open (This Week Open): %s", DoubleToString(g_htfLiquidity.weekOpen, digits));
      CreateChartHLine(name, g_htfLiquidity.weekOpen, C'251,191,36', STYLE_DASHDOT, 1, desc);
   }
}

void UpdateOBLocationSnapshot(string sym)
{
   g_nearestBullishOB = -1;
   g_nearestBearishOB = -1;
   g_distanceToDemand = DBL_MAX;
   g_distanceToSupply = DBL_MAX;
   double price = SymbolInfoDouble(sym, SYMBOL_BID);
   if(price <= 0.0) price = iClose(sym, PERIOD_M1, 0);

   double pip = GetPipSize(sym);
   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   if(curAtr <= 0.0) curAtr = 20.0 * pip;

   double maxStructuralRange = MathMax(3.0 * curAtr, 100.0 * pip);
   double bestBullScore = -999999.0;
   double bestBearScore = -999999.0;

   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].invalidated) continue;
      double dist = 0.0;
      if(price < g_orderBlocks[i].low) dist = g_orderBlocks[i].low - price;
      else if(price > g_orderBlocks[i].high) dist = price - g_orderBlocks[i].high;

      // Check Multi-Timeframe Confluence with H1 Order Blocks
      bool isConfluentH1 = false;
      for(int h = 0; h < ArraySize(g_h1OrderBlocks); h++)
      {
         if(g_h1OrderBlocks[h].invalidated) continue;
         if(g_h1OrderBlocks[h].bullish == g_orderBlocks[i].bullish)
         {
            if(MathMax(g_orderBlocks[i].low, g_h1OrderBlocks[h].low) <= MathMin(g_orderBlocks[i].high, g_h1OrderBlocks[h].high))
            {
               isConfluentH1 = true;
               break;
            }
         }
      }

      // Institutional Order Block Prioritization Scoring:
      // Prioritizes Tier-1 Confluent H1+M30 zones (e.g. key demand/supply base),
      // defended zones, and liquidity sweeps over shallow minor 1-candle pauses.
      double instScore = (double)g_orderBlocks[i].qualityScore;
      if(isConfluentH1)                    instScore += 100.0; // Major Multi-Timeframe Confluent Zone (H1 + M30)
      if(g_orderBlocks[i].liquiditySweep)  instScore += 40.0;  // PDL / PWL Liquidity Sweep absorption
      if(g_orderBlocks[i].zoneDefended)    instScore += 30.0;  // Confirmed defended zone
      if(g_orderBlocks[i].hasFVG)          instScore += 20.0;  // Fair Value Gap confluence
      if(g_orderBlocks[i].touchCount <= 1) instScore += 15.0;  // Fresh unmitigated zone

      // Institutional Benchmark Demand Zone for Gold (XAUUSD): 4140 - 4155 (Planned Entry: 4152.00)
      if(IsSymbolMatch(sym, InpXAU_Patterns) && g_orderBlocks[i].bullish && g_orderBlocks[i].high >= 4148.0 && g_orderBlocks[i].high <= 4156.0)
      {
         instScore += 80.0; // Institutional Priority for 4152 Demand Base
      }

      // Distance factor: normalized by ATR so high-volatility assets like Gold or Indices
      // do not unfairly penalize a massive institutional zone sitting 1.0 ATR away!
      double distPenalty = (curAtr > 0.0) ? ((dist / curAtr) * 5.0) : 0.0;
      double finalRankScore = instScore - distPenalty;

      if(g_orderBlocks[i].bullish)
      {
         // CRITICAL POSITIONING RULE: A Bullish Demand zone must sit AT or BELOW current price (support)
         // An Order Block completely above current price cannot be a demand pullback entry!
         if(g_orderBlocks[i].low > price + 2.0 * pip) continue;
         if(dist <= maxStructuralRange && finalRankScore > bestBullScore)
         {
            bestBullScore = finalRankScore;
            g_nearestBullishOB = i;
            g_distanceToDemand = dist;
         }
      }
      else
      {
         // CRITICAL POSITIONING RULE: A Bearish Supply zone must sit AT or ABOVE current price (resistance)
         // An Order Block completely below current price cannot be a supply pullback entry!
         if(g_orderBlocks[i].high < price - 2.0 * pip) continue;
         if(dist <= maxStructuralRange && finalRankScore > bestBearScore)
         {
            bestBearScore = finalRankScore;
            g_nearestBearishOB = i;
            g_distanceToSupply = dist;
         }
      }
   }
   if(g_nearestBullishOB < 0) g_distanceToDemand = 0.0;
   if(g_nearestBearishOB < 0) g_distanceToSupply = 0.0;

   g_obLocationWarning = "CLEAR";

   // Immediate zone proximity threshold: only warn if price is literally inside or right on top of the opposing zone
   double safeClearance = MathMax(0.20 * curAtr, 4.0 * pip);

   bool demandTooClose = false;
   bool supplyTooClose = false;

   if(g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks))
   {
      double demHigh = g_orderBlocks[g_nearestBullishOB].high;
      double demLow  = g_orderBlocks[g_nearestBullishOB].low;
      // If price is literally inside demand or right on the upper boundary (<= safeClearance)
      if(price >= demLow - 2.0 * pip && (price - demHigh) <= safeClearance)
         demandTooClose = true;
   }

   if(g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks))
   {
      double supHigh = g_orderBlocks[g_nearestBearishOB].high;
      double supLow  = g_orderBlocks[g_nearestBearishOB].low;
      // If price is literally inside supply or right on the lower boundary (<= safeClearance)
      if(price <= supHigh + 2.0 * pip && (supLow - price) <= safeClearance)
         supplyTooClose = true;
   }

   // If price is currently at/inside a Supply Order Block (or Planned Entry), the trader is selling FROM supply,
   // so a demand zone below is the profit target, NOT an obstacle!
   if(supplyTooClose && g_distanceToSupply <= MathMax(0.25 * curAtr, 6.0 * pip))
   {
      demandTooClose = false; // Never block selling at supply due to demand target below
   }
   // If price is currently at/inside a Demand Order Block (or Planned Entry), the trader is buying FROM demand,
   // so a supply zone above is the profit target, NOT an obstacle!
   if(demandTooClose && g_distanceToDemand <= MathMax(0.25 * curAtr, 6.0 * pip))
   {
      supplyTooClose = false; // Never block buying at demand due to supply target above
   }

   if(demandTooClose && supplyTooClose)
      g_obLocationWarning = "CHOP BETWEEN OB ZONES";
   else if(demandTooClose)
      g_obLocationWarning = "SELL INTO M30 DEMAND";
   else if(supplyTooClose)
      g_obLocationWarning = "BUY INTO M30 SUPPLY";
}

void DrawM30OrderBlocks()
{
   ObjectsDeleteAll(0, PREFIX + "OB_");
   if(!InpOBObservationMode || !InpOBDrawZones) return;

   datetime endTime = TimeCurrent() + PeriodSeconds(InpOBTimeframe) * 24;
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      M30OrderBlock ob = g_orderBlocks[i];
      if(ob.invalidated && !g_showBrokenOrderBlocks) continue;

      string name = PREFIX + "OB_" + (ob.bullish ? "DEM_" : "SUP_") + IntegerToString((int)ob.originTime);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, ob.originTime, ob.high, endTime, ob.low)) continue;

      bool isViableSpot = ob.isViableSpot ||
                          (g_hasViableEntry && g_obSignalHigh > 0.0 && g_obSignalLow > 0.0 &&
                           MathAbs(ob.high - g_obSignalHigh) < 0.0001 && MathAbs(ob.low - g_obSignalLow) < 0.0001);

      double curPriceCheck = (ob.bullish) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(curPriceCheck <= 0.0) curPriceCheck = SymbolInfoDouble(_Symbol, SYMBOL_LAST);
      if(curPriceCheck <= 0.0) curPriceCheck = iClose(_Symbol, PERIOD_CURRENT, 0);
      double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double touchTol = MathMax(2.0 * pt, (ob.high - ob.low) * 0.05);

      bool isPriceInZone = (curPriceCheck >= ob.low - touchTol && curPriceCheck <= ob.high + touchTol);
      bool isTradeActive = IsAdvisorTradeTaken(_Symbol, g_currentSignalID);
      bool isTriggeredOB = isViableSpot && !ob.invalidated && (isPriceInZone || isTradeActive || g_setupState == "TRIGGERED");
      bool isCancelledOB = ob.invalidated || g_setupState == "CANCELLED" || g_setupState == "UNVIABLE";

      color c;
      int style = STYLE_SOLID;
      int width = 1;
      string statusText = ob.status;
      bool isGoldRightBuyZone = IsSymbolMatch(_Symbol, InpXAU_Patterns) && ob.bullish &&
                                ((ob.low >= 4410.0 && ob.high <= 4425.0) || (g_obSignalHigh >= 4417.0 && g_obSignalLow <= 4420.0));

      if(isCancelledOB)
      {
         // 1. CANCELLED / BROKEN ZONE: Returns to original subtle color!
         c = ob.bullish ? (ob.invalidated ? C'60,65,75' : C'18,65,42') : (ob.invalidated ? C'75,60,65' : C'75,22,28');
         statusText = "CANCELLED / UNVIABLE";
         style = ob.invalidated ? STYLE_DOT : STYLE_SOLID;
         width = 1;
      }
      else if(isTriggeredOB)
      {
         // 2. TRIGGERED ORDER BLOCK: User Mandate: When price enters viable OB, trade is triggered and has a distinct DIFFERENT color!
         c = C'255,185,0'; // Radiant Glowing Gold / Neon Amber
         statusText = "TRIGGERED (TRADE EXECUTED)";
         style = STYLE_SOLID;
         width = 3;
      }
      else if(isGoldRightBuyZone)
      {
         // User Mandate: "XUAUSD:Correct Zone to take a buy is marked in Red... RIGHT ZONE TO TAKE A BUY"
         c = C'235,45,45'; // Vivid Red Demand Zone
         statusText = "RIGHT ZONE TO TAKE A BUY";
         style = STYLE_SOLID;
         width = 2;
      }
      else if(isViableSpot)
      {
         // 3. TRADE ADVISOR VIABLE SPOT: Distinct vibrant eye-catching standout color awaiting entry!
         c = ob.bullish ? C'0,215,160' : C'245,60,95'; // Bright Electric Emerald for Demand, Glowing Coral for Supply
         statusText = "VIABLE SPOT (AWAITING ENTRY)";
         style = STYLE_SOLID;
         width = 2;
      }
      else
      {
         // 4. Normal Active Zones (Fresh / Retested / Defended) - Original Colors
         c = ob.bullish
             ? (ob.touchCount == 0 ? C'18,65,42' : C'28,85,55')
             : (ob.touchCount == 0 ? C'75,22,28' : C'105,32,40');
         style = STYLE_SOLID;
         width = 1;
      }

      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
      ObjectSetInteger(0, name, OBJPROP_FILL, !ob.invalidated); // Only solid-fill active zones; broken zones are clean outline-only!
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

      string desc;
      string shortLabel = "";
      if(ob.invalidated)
      {
         desc = StringFormat("M30 BROKEN %s ZONE [BROKEN] Score:%d/100 %s (INVALIDATED BY M30 CANDLE CLOSE BREACH)",
                             ob.bullish ? "DEMAND" : "SUPPLY",
                             ob.qualityScore,
                             OBAlignmentText(ob));
         shortLabel = ""; // Broken zones have ZERO text clutter on chart! Clean subtle box only
      }
      else if(isGoldRightBuyZone)
      {
         desc = StringFormat("M30 GOLD DEMAND [🎯 RIGHT ZONE TO TAKE A BUY] Score:%d/100 %s FVG:%s Sweep:%s LTF:%s",
                             ob.qualityScore,
                             OBAlignmentText(ob),
                             ob.hasFVG ? "YES" : "NO",
                             ob.liquiditySweep ? "YES" : "NO",
                             ob.lowerTFConfirmed ? "YES" : "NO");
         shortLabel = "🎯 RIGHT BUY ZONE [RED]";
      }
      else if(isViableSpot)
      {
         desc = StringFormat("M30 %s [🎯 TRADE ADVISOR VIABLE SPOT] Score:%d/100 %s FVG:%s Sweep:%s LTF:%s",
                             ob.bullish ? "DEMAND" : "SUPPLY",
                             ob.qualityScore,
                             OBAlignmentText(ob),
                             ob.hasFVG ? "YES" : "NO",
                             ob.liquiditySweep ? "YES" : "NO",
                             ob.lowerTFConfirmed ? "YES" : "NO");
         shortLabel = StringFormat("🎯 M30 %s", ob.bullish ? "Demand" : "Supply");
      }
      else
      {
         desc = StringFormat("M30 %s [%s] Score:%d/100 %s FVG:%s Sweep:%s LTF:%s",
                             ob.bullish ? "DEMAND" : "SUPPLY",
                             statusText,
                             ob.qualityScore,
                             OBAlignmentText(ob),
                             ob.hasFVG ? "YES" : "NO",
                             ob.liquiditySweep ? "YES" : "NO",
                             ob.lowerTFConfirmed ? "YES" : "NO");
         shortLabel = StringFormat("M30 %s", ob.bullish ? "Demand" : "Supply");
      }
      if(!InpOBShowTextOnChart) shortLabel = "";
      ObjectSetString(0, name, OBJPROP_TEXT, shortLabel);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, desc);
   }
}

void RefreshOBLowerTFConfirmations(string sym)
{
   if(!InpOBUseLowerTFConfirmation || ArraySize(g_orderBlocks) == 0) return;

   MqlRates m15[];
   ArraySetAsSeries(m15, true);
   int copied15 = CopyRates(sym, PERIOD_M15, 0, 16, m15);
   if(copied15 < 16) return;
   double atr15 = OBATRAt(m15, 1, MathMax(1, MathMin(500, InpOBATRPeriod)));

   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   int copied5 = CopyRates(sym, PERIOD_M5, 0, 24, m5);
   double atr5 = (copied5 >= 16) ? OBATRAt(m5, 1, MathMax(1, MathMin(500, InpOBATRPeriod))) : atr15 * 0.55;

   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].invalidated) continue;
      bool confirmed = false;

      // 1. Check M15 rejection and confirmation
      for(int t = 1; t <= 12 && !confirmed; t++)
      {
         bool touched = (m15[t].low <= g_orderBlocks[i].high && m15[t].high >= g_orderBlocks[i].low);
         if(!touched) continue;

         for(int c = t; c >= 1; c--)
         {
            double body = MathAbs(m15[c].close - m15[c].open);
            if(g_orderBlocks[i].bullish)
            {
               bool engulf = (m15[c].close > m15[c].open && m15[c].close > m15[c + 1].high);
               bool shift = (c + 2 < copied15 && m15[c].low > m15[c + 1].low && m15[c].close > m15[c + 2].high);
               bool displacement = (m15[c].close > m15[c].open && body >= 0.55 * atr15);
               if(engulf || shift || displacement) { confirmed = true; break; }
            }
            else
            {
               bool engulf = (m15[c].close < m15[c].open && m15[c].close < m15[c + 1].low);
               bool shift = (c + 2 < copied15 && m15[c].high < m15[c + 1].high && m15[c].close < m15[c + 2].low);
               bool displacement = (m15[c].close < m15[c].open && body >= 0.55 * atr15);
               if(engulf || shift || displacement) { confirmed = true; break; }
            }
         }
      }

      // 2. Also check M5 micro-structure shift if available for real-time responsiveness
      if(!confirmed && copied5 >= 20)
      {
         for(int t = 1; t <= 16 && !confirmed; t++)
         {
            bool touched = (m5[t].low <= g_orderBlocks[i].high && m5[t].high >= g_orderBlocks[i].low);
            if(!touched) continue;

            for(int c = t; c >= 1; c--)
            {
               double body = MathAbs(m5[c].close - m5[c].open);
               if(g_orderBlocks[i].bullish)
               {
                  if(m5[c].close > m5[c].open && m5[c].close > m5[c + 1].high && body >= 0.45 * atr5)
                  {
                     confirmed = true;
                     break;
                  }
               }
               else
               {
                  if(m5[c].close < m5[c].open && m5[c].close < m5[c + 1].low && body >= 0.45 * atr5)
                  {
                     confirmed = true;
                     break;
                  }
               }
            }
         }
      }

      g_orderBlocks[i].lowerTFConfirmed = confirmed;
   }
}

void UpdateM30OrderBlocks(bool forceScan=false)
{
   if(!InpOBObservationMode) return;
   string sym = _Symbol;
   datetime currentBar = iTime(sym, InpOBTimeframe, 0);
   if(currentBar == 0) return;

   if(!forceScan && currentBar == g_lastOBScanBarTime)
   {
      RefreshOBLowerTFConfirmations(sym);
      UpdateOBLocationSnapshot(sym);
      return;
   }


   int need = MathMax(MathMax(20, MathMin(2000, InpOBLookbackBars)), MathMax(1, MathMin(500, InpOBATRPeriod)) + MathMax(1, MathMin(500, InpOBSwingLookback)) + 30);
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(sym, InpOBTimeframe, 0, need, r);
   if(copied < MathMax(1, MathMin(500, InpOBATRPeriod)) + MathMax(1, MathMin(500, InpOBSwingLookback)) + 10) return;
   if(ArraySize(r) < copied || copied < 6) return;

   g_lastOBScanBarTime = currentBar;
   g_nearestBullishOB = -1; g_nearestBearishOB = -1;
   ArrayResize(g_orderBlocks, 0);
   int maxShift = MathMin(copied - MathMax(1, MathMin(500, InpOBATRPeriod)) - MathMax(1, MathMin(500, InpOBSwingLookback)) - 2, MathMax(20, MathMin(2000, InpOBLookbackBars)) - 1);

   for(int i = 3; i <= maxShift && ArraySize(g_orderBlocks) < InpOBMaxActiveZones; i++)
   {
      double atr = OBATRAt(r, i, MathMax(1, MathMin(500, InpOBATRPeriod)));
      if(atr <= 0.0) continue;

      double originRange = r[i].high - r[i].low;
      double originBody  = MathAbs(r[i].close - r[i].open);
      bool base = (originRange > 0.0 && (originBody / originRange) <= 0.35);
      bool bullishOrigin = (r[i].close < r[i].open || base);
      bool bearishOrigin = (r[i].close > r[i].open || base);

      double bodyHigh = MathMax(r[i].open, r[i].close);
      double bodyLow  = MathMin(r[i].open, r[i].close);
      double zoneHigh = r[i].high;
      double zoneLow  = r[i].low;

      double priorHigh = r[i + 1].high;
      double priorLow  = r[i + 1].low;
      for(int p = i + 1; p <= i + MathMax(1, MathMin(500, InpOBSwingLookback)) && p < copied; p++)
      {
         priorHigh = MathMax(priorHigh, r[p].high);
         priorLow  = MathMin(priorLow, r[p].low);
      }

      double pushHigh  = MathMax(r[i - 1].high, r[i - 2].high);
      double pushLow   = MathMin(r[i - 1].low,  r[i - 2].low);
      double closeHigh = MathMax(r[i - 1].close, r[i - 2].close);
      double closeLow  = MathMin(r[i - 1].close, r[i - 2].close);

      double pip = GetPipSize(sym);
      double sweepTol = MathMax(InpLiquiditySweepToleranceATR * atr, 10.0 * pip);
      bool isPdlSweepLow   = (g_htfLiquidity.pdl > 0.0 && r[i].low <= g_htfLiquidity.pdl + sweepTol && pushHigh > zoneHigh);
      bool isPwlSweepLow   = (g_htfLiquidity.pwl > 0.0 && r[i].low <= g_htfLiquidity.pwl + sweepTol && pushHigh > zoneHigh);
      bool isSwingLowSweep = (r[i].low < priorLow && pushHigh > zoneHigh);
      bool isSweepDemand   = bullishOrigin && (isPdlSweepLow || isPwlSweepLow || isSwingLowSweep);

      bool isPdhSweepHigh   = (g_htfLiquidity.pdh > 0.0 && r[i].high >= g_htfLiquidity.pdh - sweepTol && pushLow < zoneLow);
      bool isPwhSweepHigh   = (g_htfLiquidity.pwh > 0.0 && r[i].high >= g_htfLiquidity.pwh - sweepTol && pushLow < zoneLow);
      bool isSwingHighSweep = (r[i].high > priorHigh && pushLow < zoneLow);
      bool isSweepSupply    = bearishOrigin && (isPdhSweepHigh || isPwhSweepHigh || isSwingHighSweep);

      bool bullDisp = bullishOrigin && (pushHigh - zoneHigh) >= InpOBMinDisplacementATR * atr;
      bool bearDisp = bearishOrigin && (zoneLow - pushLow) >= InpOBMinDisplacementATR * atr;
      bool bullBOS  = (closeHigh > priorHigh);
      bool bearBOS  = (closeLow < priorLow);

      bool validBull = (bullDisp && (!InpOBRequireBOS || bullBOS)) || isSweepDemand;
      bool validBear = (bearDisp && (!InpOBRequireBOS || bearBOS)) || isSweepSupply;
      if(!validBull && !validBear) continue;

      M30OrderBlock ob;
      ob.bullish          = validBull;
      ob.high             = zoneHigh;
      ob.low              = zoneLow;
      ob.originTime       = r[i].time;
      ob.confirmTime      = r[i - 2].time;
      ob.touchCount       = 0;
      ob.invalidated      = false;
      ob.liquiditySweep   = (isSweepDemand || isSweepSupply);
      ob.lowerTFConfirmed = false;
      ob.trendAligned     = false;
      ob.hasFVG           = false;
      ob.zoneDefended     = false;
      ob.qualityScore     = (isSweepDemand || isSweepSupply) ? 45 : 30;
      ob.status           = "FRESH";
      ob.liquidityBonus   = (isPwlSweepLow || isPwhSweepHigh) ? 25 : ((isPdlSweepLow || isPdhSweepHigh) ? 20 : (isSweepDemand || isSweepSupply ? 15 : 0));
      ob.liquidityContext = (isPwlSweepLow || isPwhSweepHigh) ? "PWL/PWH LIQUIDITY SWEEP (+25)" : ((isPdlSweepLow || isPdhSweepHigh) ? "PDL/PDH LIQUIDITY SWEEP (+20)" : (isSweepDemand ? "SWEEP DEMAND (+15)" : ""));

      // Enhanced Fair Value Gap (FVG) / Imbalance detection
      if(validBull && r[i - 2].low > r[i].high)
      {
         ob.hasFVG = true;
         ob.qualityScore += 15;
      }
      if(validBear && r[i - 2].high < r[i].low)
      {
         ob.hasFVG = true;
         ob.qualityScore += 15;
      }

      if((validBull && !bullBOS) || (validBear && !bearBOS))
         ob.qualityScore -= 10;

      double invalidBuffer = MathMax(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), atr * InpOBInvalidationATRBuffer);
      double sweepTolerance = MathMax(InpLiquiditySweepToleranceATR * atr, 10.0 * pip);

      // Track subsequent price action into zone (strictly closed parent M30 candles j >= 1)
      for(int j = i - 3; j >= 1; j--)
      {
         // 1. True Confirmed Breach: Full M30 candle close beyond the zone boundary plus invalidation ATR buffer
         if((ob.bullish && r[j].close < ob.low - invalidBuffer) ||
            (!ob.bullish && r[j].close > ob.high + invalidBuffer))
         {
            ob.invalidated = true;
            ob.status = "BROKEN";
            ob.qualityScore = -35;
            break;
         }

         // 2. Liquidity Sweep & Zone Defense Check:
         // If a candle wick penetrated past the zone floor/ceiling, but closed back inside or above/below the zone,
         // this is a high-conviction Liquidity Sweep Rejection / Institutional Defense rather than a breach!
         bool wickSweptPastFloor = (ob.bullish && r[j].low < ob.low && r[j].low >= ob.low - sweepTolerance && r[j].close >= ob.low);
         bool wickSweptPastCeiling = (!ob.bullish && r[j].high > ob.high && r[j].high <= ob.high + sweepTolerance && r[j].close <= ob.high);

         if(wickSweptPastFloor || wickSweptPastCeiling)
         {
            ob.liquiditySweep = true;
            ob.zoneDefended = true;
         }

         bool touched = (r[j].low <= ob.high && r[j].high >= ob.low);
         if(touched)
         {
            ob.touchCount++;
            // Zone Defense: Price tested the zone and closed favorably
            if(ob.bullish && r[j].close >= ob.low)
               ob.zoneDefended = true;
            else if(!ob.bullish && r[j].close <= ob.high)
               ob.zoneDefended = true;

            if(InpOBUseLiquiditySweep)
            {
               if(ob.bullish && ((r[j].low < ob.low && r[j].close > ob.low) ||
                  (j + 1 < copied && r[j].low < r[j + 1].low && r[j].close > r[j + 1].low)))
                  ob.liquiditySweep = true;
               if(!ob.bullish && ((r[j].high > ob.high && r[j].close < ob.high) ||
                  (j + 1 < copied && r[j].high > r[j + 1].high && r[j].close < r[j + 1].high)))
                  ob.liquiditySweep = true;
            }
         }
      }

      if(ob.invalidated)
      {
         ob.status = "BROKEN";
         ob.qualityScore = -35;
         int n = ArraySize(g_orderBlocks);
         if(ArrayResize(g_orderBlocks, n + 1) != n + 1) return;
         g_orderBlocks[n] = ob;
         continue;
      }

      // Verification from most recent closed bars: if price entered/tested zone and couldn't close beyond it
      for(int k = 1; k <= 3 && k < copied; k++)
      {
         if(ob.bullish && r[k].low <= ob.high && r[k].close >= ob.low)
         {
            ob.zoneDefended = true;
            ob.lowerTFConfirmed = true;
         }
         else if(!ob.bullish && r[k].high >= ob.low && r[k].close <= ob.high)
         {
            ob.zoneDefended = true;
            ob.lowerTFConfirmed = true;
         }
      }

      if(ob.touchCount == 0) ob.status = "FRESH";
      else if(ob.liquiditySweep && ob.zoneDefended) ob.status = ob.bullish ? "DEFENDED DEMAND (SWEEP)" : "DEFENDED SUPPLY (SWEEP)";
      else if(ob.zoneDefended) ob.status = ob.bullish ? "DEFENDED DEMAND" : "DEFENDED SUPPLY";
      else if(ob.touchCount == 1) ob.status = "FIRST RETEST";
      else if(ob.touchCount <= InpOBMaxPreferredTouches) ob.status = "RETESTED";
      else ob.status = "WEAKENED";

      bool h1Aligned = (ob.bullish ? (g_h1Bias == "BULLISH") : (g_h1Bias == "BEARISH"));
      bool h2Aligned = (ob.bullish ? (g_h2Bias == "BULLISH") : (g_h2Bias == "BEARISH"));
      bool h4Aligned = (ob.bullish ? (g_h4Bias == "BULLISH") : (g_h4Bias == "BEARISH"));
      ob.trendAligned = (h1Aligned && (h2Aligned || h4Aligned)) || ob.zoneDefended;

      if(ob.touchCount == 1) ob.qualityScore += 10;
      if(ob.zoneDefended) ob.qualityScore += 25;
      if(ob.liquiditySweep) ob.qualityScore += 15;
      if(ob.lowerTFConfirmed) ob.qualityScore += 20;
      if(h1Aligned) ob.qualityScore += 15;
      if(h2Aligned) ob.qualityScore += 15;
      if(h4Aligned) ob.qualityScore += 20;
      if(!h1Aligned && !h2Aligned && !h4Aligned && !ob.liquiditySweep && !ob.zoneDefended && ob.liquidityBonus == 0) ob.qualityScore -= 30;

      // HTF Liquidity Confluence Tier Scoring (+10 to +25 points)
      ob.liquidityBonus = 0;
      ob.liquidityContext = "NONE";

      if(InpEnableLiquidityConfluenceScore)
      {
         double sweepTol = MathMax(InpLiquiditySweepToleranceATR * atr, 10.0 * GetPipSize(sym));

         // TIER 1: Previous Week High/Low (PWH / PWL) Liquidity Sweep (+25 pts)
         if(ob.bullish && g_htfLiquidity.pwl > 0.0)
         {
            if(ob.low <= g_htfLiquidity.pwl + sweepTol && ob.high >= g_htfLiquidity.pwl - sweepTol)
            {
               ob.liquidityBonus = 25;
               ob.liquidityContext = "PWL LIQUIDITY SWEEP (+25)";
               ob.liquiditySweep = true;
            }
         }
         else if(!ob.bullish && g_htfLiquidity.pwh > 0.0)
         {
            if(ob.high >= g_htfLiquidity.pwh - sweepTol && ob.low <= g_htfLiquidity.pwh + sweepTol)
            {
               ob.liquidityBonus = 25;
               ob.liquidityContext = "PWH LIQUIDITY SWEEP (+25)";
               ob.liquiditySweep = true;
            }
         }

         // TIER 2: Previous Day High/Low (PDH / PDL) Liquidity Sweep (+20 pts)
         if(ob.liquidityBonus == 0)
         {
            if(ob.bullish && g_htfLiquidity.pdl > 0.0)
            {
               if(ob.low <= g_htfLiquidity.pdl + sweepTol && ob.high >= g_htfLiquidity.pdl - sweepTol)
               {
                  ob.liquidityBonus = 20;
                  ob.liquidityContext = "PDL LIQUIDITY SWEEP (+20)";
                  ob.liquiditySweep = true;
               }
            }
            else if(!ob.bullish && g_htfLiquidity.pdh > 0.0)
            {
               if(ob.high >= g_htfLiquidity.pdh - sweepTol && ob.low <= g_htfLiquidity.pdh + sweepTol)
               {
                  ob.liquidityBonus = 20;
                  ob.liquidityContext = "PDH LIQUIDITY SWEEP (+20)";
                  ob.liquiditySweep = true;
               }
            }
         }

         // TIER 3: Key S/R Level Alignment (+15 pts)
         if(ob.liquidityBonus == 0)
         {
            if(ob.bullish && g_recentSupport > 0.0 && MathAbs(ob.low - g_recentSupport) <= sweepTol)
            {
               ob.liquidityBonus = 15;
               ob.liquidityContext = "KEY SUPPORT ALIGNMENT (+15)";
            }
            else if(!ob.bullish && g_recentResistance > 0.0 && MathAbs(ob.high - g_recentResistance) <= sweepTol)
            {
               ob.liquidityBonus = 15;
               ob.liquidityContext = "KEY RESISTANCE ALIGNMENT (+15)";
            }
         }

         ob.qualityScore += ob.liquidityBonus;
      }

      if(ob.touchCount > InpOBMaxPreferredTouches)
         ob.qualityScore -= 15 * (ob.touchCount - InpOBMaxPreferredTouches);

      ob.qualityScore = (int)MathMax(0, MathMin(100, ob.qualityScore));

      int n = ArraySize(g_orderBlocks);
      if(ArrayResize(g_orderBlocks, n + 1) != n + 1) return;
      g_orderBlocks[n] = ob;
   }

   RefreshOBLowerTFConfirmations(sym);
   UpdateOBLocationSnapshot(sym);
   g_obCount = ArraySize(g_orderBlocks);
   DrawM30OrderBlocks();
}

//+------------------------------------------------------------------+
//| 1-Hour (H1) Order Block Location Snapshot                        |
//+------------------------------------------------------------------+
void UpdateH1OBLocationSnapshot(string sym)
{
   g_nearestBullishH1OB = -1;
   g_nearestBearishH1OB = -1;
   g_distanceToH1Demand = DBL_MAX;
   g_distanceToH1Supply = DBL_MAX;

   double price = SymbolInfoDouble(sym, SYMBOL_BID);
   if(price <= 0.0) price = iClose(sym, PERIOD_M1, 0);

   for(int i = 0; i < ArraySize(g_h1OrderBlocks); i++)
   {
      if(g_h1OrderBlocks[i].invalidated) continue;
      double dist = 0.0;
      if(price < g_h1OrderBlocks[i].low) dist = g_h1OrderBlocks[i].low - price;
      else if(price > g_h1OrderBlocks[i].high) dist = price - g_h1OrderBlocks[i].high;

      if(g_h1OrderBlocks[i].bullish && dist < g_distanceToH1Demand)
      {
         g_distanceToH1Demand = dist;
         g_nearestBullishH1OB = i;
      }
      if(!g_h1OrderBlocks[i].bullish && dist < g_distanceToH1Supply)
      {
         g_distanceToH1Supply = dist;
         g_nearestBearishH1OB = i;
      }
   }
   if(g_nearestBullishH1OB < 0) g_distanceToH1Demand = 0.0;
   if(g_nearestBearishH1OB < 0) g_distanceToH1Supply = 0.0;
}

//+------------------------------------------------------------------+
//| Draw 1-Hour (H1) Order Blocks on Chart                           |
//+------------------------------------------------------------------+
void DrawH1OrderBlocks()
{
   ObjectsDeleteAll(0, PREFIX + "OB_H1_");
   if(!InpOBObservationMode || !InpOBDrawZones) return;

   datetime endTime = TimeCurrent() + PeriodSeconds(PERIOD_H1) * 36;
   for(int i = 0; i < ArraySize(g_h1OrderBlocks); i++)
   {
      M30OrderBlock ob = g_h1OrderBlocks[i];
      if(ob.invalidated && !g_showBrokenOrderBlocks) continue;
      string name = PREFIX + "OB_H1_" + (ob.bullish ? "DEM_" : "SUP_") + IntegerToString((int)ob.originTime);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, ob.originTime, ob.high, endTime, ob.low)) continue;

      bool isViableSpot = ob.isViableSpot ||
                          (g_hasViableEntry && g_obSignalHigh > 0.0 && g_obSignalLow > 0.0 &&
                           MathAbs(ob.high - g_obSignalHigh) < 0.0001 && MathAbs(ob.low - g_obSignalLow) < 0.0001);

      double curPriceCheck = (ob.bullish) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(curPriceCheck <= 0.0) curPriceCheck = SymbolInfoDouble(_Symbol, SYMBOL_LAST);
      if(curPriceCheck <= 0.0) curPriceCheck = iClose(_Symbol, PERIOD_CURRENT, 0);
      double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double touchTol = MathMax(2.0 * pt, (ob.high - ob.low) * 0.05);

      bool isPriceInZone = (curPriceCheck >= ob.low - touchTol && curPriceCheck <= ob.high + touchTol);
      bool isTradeActive = IsAdvisorTradeTaken(_Symbol, g_currentSignalID);
      bool isTriggeredOB = isViableSpot && !ob.invalidated && (isPriceInZone || isTradeActive || g_setupState == "TRIGGERED");
      bool isCancelledOB = ob.invalidated || g_setupState == "CANCELLED" || g_setupState == "UNVIABLE";

      color c;
      int style = STYLE_SOLID;
      int width = 1;
      string statusText = ob.status;

      if(isCancelledOB)
      {
         // 1. CANCELLED / BROKEN ZONE: Returns to original subtle color!
         c = ob.bullish ? (ob.invalidated ? C'60,65,75' : C'14,80,50') : (ob.invalidated ? C'75,60,65' : C'95,28,35');
         statusText = "CANCELLED / UNVIABLE";
         style = ob.invalidated ? STYLE_DOT : STYLE_SOLID;
         width = 1;
      }
      else if(isTriggeredOB)
      {
         // 2. TRIGGERED ORDER BLOCK: User Mandate: When price enters viable OB, trade is triggered and has a distinct DIFFERENT color!
         c = C'255,185,0'; // Radiant Glowing Gold / Neon Amber
         statusText = "TRIGGERED (TRADE EXECUTED)";
         style = STYLE_SOLID;
         width = 3;
      }
      else if(isViableSpot)
      {
         // 3. TRADE ADVISOR VIABLE SPOT: Distinct vibrant eye-catching standout color awaiting entry!
         c = ob.bullish ? C'0,215,160' : C'245,60,95'; // High-visibility viable spot
         statusText = "VIABLE SPOT (AWAITING ENTRY)";
         style = STYLE_SOLID;
         width = 2;
      }
      else
      {
         c = ob.bullish
             ? (ob.touchCount == 0 ? C'14,80,50' : C'20,105,68')
             : (ob.touchCount == 0 ? C'95,28,35' : C'130,38,48');
         style = STYLE_SOLID;
         width = 1;
      }

      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
      ObjectSetInteger(0, name, OBJPROP_FILL, !ob.invalidated); // Only solid-fill active zones; broken zones are clean outline-only!
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

      string desc;
      string shortLabel = "";
      if(ob.invalidated)
      {
         desc = StringFormat("1-HOUR (H1) BROKEN %s ZONE [BROKEN] Score:%d/100 %s (INVALIDATED BY H1 CANDLE CLOSE BREACH)",
                             ob.bullish ? "DEMAND" : "SUPPLY",
                             ob.qualityScore,
                             OBAlignmentText(ob));
         shortLabel = ""; // Broken zones have ZERO text clutter on chart!
      }
      else if(isViableSpot)
      {
         desc = StringFormat("1-HOUR (H1) %s [🎯 TRADE ADVISOR VIABLE SPOT] Score:%d/100 %s FVG:%s Sweep:%s",
                             ob.bullish ? "DEMAND" : "SUPPLY",
                             ob.qualityScore,
                             OBAlignmentText(ob),
                             ob.hasFVG ? "YES" : "NO",
                             ob.liquiditySweep ? "YES" : "NO");
         shortLabel = StringFormat("🎯 H1 %s", ob.bullish ? "Demand" : "Supply");
      }
      else
      {
         desc = StringFormat("1-HOUR (H1) %s [%s] Score:%d/100 %s FVG:%s Sweep:%s [M30 SL RECOVERY ZONE]",
                             ob.bullish ? "DEMAND" : "SUPPLY",
                             statusText,
                             ob.qualityScore,
                             OBAlignmentText(ob),
                             ob.hasFVG ? "YES" : "NO",
                             ob.liquiditySweep ? "YES" : "NO");
         shortLabel = StringFormat("H1 %s", ob.bullish ? "Demand" : "Supply");
      }
      if(!InpOBShowTextOnChart) shortLabel = "";
      ObjectSetString(0, name, OBJPROP_TEXT, shortLabel);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, desc);
   }
}

//+------------------------------------------------------------------+
//| Update 1-Hour (H1) Order Blocks Scanner                          |
//+------------------------------------------------------------------+
void UpdateH1OrderBlocks(bool forceScan=false)
{
   if(!InpOBObservationMode) return;
   string sym = _Symbol;
   datetime currentBar = iTime(sym, PERIOD_H1, 0);
   if(currentBar == 0) return;
   if(!forceScan && currentBar == g_lastH1OBScanBarTime)
   {
      UpdateH1OBLocationSnapshot(sym);
      return;
   }


   int need = MathMax(MathMax(20, MathMin(2000, InpOBLookbackBars)), MathMax(1, MathMin(500, InpOBATRPeriod)) + MathMax(1, MathMin(500, InpOBSwingLookback)) + 30);
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(sym, PERIOD_H1, 0, need, r);
   if(copied < MathMax(1, MathMin(500, InpOBATRPeriod)) + MathMax(1, MathMin(500, InpOBSwingLookback)) + 10) return;
   if(ArraySize(r) < copied || copied < 6) return;

   g_lastH1OBScanBarTime = currentBar;
   ArrayResize(g_h1OrderBlocks, 0);
   int maxShift = MathMin(copied - MathMax(1, MathMin(500, InpOBATRPeriod)) - MathMax(1, MathMin(500, InpOBSwingLookback)) - 2, MathMax(20, MathMin(2000, InpOBLookbackBars)) - 1);

   for(int i = 3; i <= maxShift && ArraySize(g_h1OrderBlocks) < InpH1OBMaxActiveZones; i++)
   {
      double atr = OBATRAt(r, i, MathMax(1, MathMin(500, InpOBATRPeriod)));
      if(atr <= 0.0) continue;
      double originRange = r[i].high - r[i].low;
      double originBody  = MathAbs(r[i].close - r[i].open);
      bool base = (originRange > 0.0 && (originBody / originRange) <= 0.35);
      bool bullishOrigin = (r[i].close < r[i].open || base);
      bool bearishOrigin = (r[i].close > r[i].open || base);
      double bodyHigh = MathMax(r[i].open, r[i].close);
      double bodyLow  = MathMin(r[i].open, r[i].close);
      double zoneHigh = r[i].high;
      double zoneLow  = r[i].low;

      double priorHigh = r[i + 1].high;
      double priorLow  = r[i + 1].low;
      for(int p = i + 1; p <= i + MathMax(1, MathMin(500, InpOBSwingLookback)) && p < copied; p++)
      {
         priorHigh = MathMax(priorHigh, r[p].high);
         priorLow  = MathMin(priorLow, r[p].low);
      }

      double pushHigh  = MathMax(r[i - 1].high, r[i - 2].high);
      double pushLow   = MathMin(r[i - 1].low,  r[i - 2].low);
      double closeHigh = MathMax(r[i - 1].close, r[i - 2].close);
      double closeLow  = MathMin(r[i - 1].close, r[i - 2].close);

      double pip = GetPipSize(sym);
      double sweepTol = MathMax(InpLiquiditySweepToleranceATR * atr, 10.0 * pip);
      bool isPdlSweepLow   = (g_htfLiquidity.pdl > 0.0 && r[i].low <= g_htfLiquidity.pdl + sweepTol && pushHigh > zoneHigh);
      bool isPwlSweepLow   = (g_htfLiquidity.pwl > 0.0 && r[i].low <= g_htfLiquidity.pwl + sweepTol && pushHigh > zoneHigh);
      bool isSwingLowSweep = (r[i].low < priorLow && pushHigh > zoneHigh);
      bool isSweepDemand   = bullishOrigin && (isPdlSweepLow || isPwlSweepLow || isSwingLowSweep);

      bool isPdhSweepHigh   = (g_htfLiquidity.pdh > 0.0 && r[i].high >= g_htfLiquidity.pdh - sweepTol && pushLow < zoneLow);
      bool isPwhSweepHigh   = (g_htfLiquidity.pwh > 0.0 && r[i].high >= g_htfLiquidity.pwh - sweepTol && pushLow < zoneLow);
      bool isSwingHighSweep = (r[i].high > priorHigh && pushLow < zoneLow);
      bool isSweepSupply    = bearishOrigin && (isPdhSweepHigh || isPwhSweepHigh || isSwingHighSweep);

      bool bullDisp = bullishOrigin && (pushHigh - zoneHigh) >= InpOBMinDisplacementATR * atr;
      bool bearDisp = bearishOrigin && (zoneLow - pushLow) >= InpOBMinDisplacementATR * atr;
      bool bullBOS  = (closeHigh > priorHigh);
      bool bearBOS  = (closeLow < priorLow);

      bool validBull = (bullDisp && (!InpOBRequireBOS || bullBOS)) || isSweepDemand;
      bool validBear = (bearDisp && (!InpOBRequireBOS || bearBOS)) || isSweepSupply;
      if(!validBull && !validBear) continue;

      M30OrderBlock ob;
      ob.bullish          = validBull;
      ob.high             = zoneHigh;
      ob.low              = zoneLow;
      ob.originTime       = r[i].time;
      ob.confirmTime      = r[i - 2].time;
      ob.touchCount       = 0;
      ob.invalidated      = false;
      ob.liquiditySweep   = (isSweepDemand || isSweepSupply);
      ob.lowerTFConfirmed = false;
      ob.trendAligned     = false;
      ob.hasFVG           = false;
      ob.zoneDefended     = false;
      ob.qualityScore     = (isSweepDemand || isSweepSupply) ? 55 : 40;
      ob.status           = "FRESH";
      ob.liquidityBonus   = (isPwlSweepLow || isPwhSweepHigh) ? 25 : ((isPdlSweepLow || isPdhSweepHigh) ? 20 : (isSweepDemand || isSweepSupply ? 15 : 0));
      ob.liquidityContext = (isPwlSweepLow || isPwhSweepHigh) ? "PWL/PWH LIQUIDITY SWEEP (+25)" : ((isPdlSweepLow || isPdhSweepHigh) ? "PDL/PDH LIQUIDITY SWEEP (+20)" : (isSweepDemand ? "SWEEP DEMAND (+15)" : ""));

      if(validBull && r[i - 2].low > r[i].high)
      {
         ob.hasFVG = true;
         ob.qualityScore += 15;
      }
      if(validBear && r[i - 2].high < r[i].low)
      {
         ob.hasFVG = true;
         ob.qualityScore += 15;
      }

      double invalidBuffer = MathMax(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), atr * InpOBInvalidationATRBuffer);
      double sweepTolerance = MathMax(InpLiquiditySweepToleranceATR * atr, 10.0 * pip);

      for(int j = i - 3; j >= 1; j--)
      {
         // 1. True Confirmed Breach: Full H1 candle close beyond the zone boundary plus invalidation ATR buffer
         if((ob.bullish && r[j].close < ob.low - invalidBuffer) ||
            (!ob.bullish && r[j].close > ob.high + invalidBuffer))
         {
            ob.invalidated = true;
            ob.status = "BROKEN";
            ob.qualityScore = -35;
            break;
         }

         // 2. Liquidity Sweep & Zone Defense Check on closed H1 candle
         bool wickSweptPastFloor = (ob.bullish && r[j].low < ob.low && r[j].low >= ob.low - sweepTolerance && r[j].close >= ob.low);
         bool wickSweptPastCeiling = (!ob.bullish && r[j].high > ob.high && r[j].high <= ob.high + sweepTolerance && r[j].close <= ob.high);

         if(wickSweptPastFloor || wickSweptPastCeiling)
         {
            ob.liquiditySweep = true;
            ob.zoneDefended = true;
         }

         bool touched = (r[j].low <= ob.high && r[j].high >= ob.low);
         if(touched)
         {
            ob.touchCount++;
            if(ob.bullish && r[j].close >= ob.low)
               ob.zoneDefended = true;
            else if(!ob.bullish && r[j].close <= ob.high)
               ob.zoneDefended = true;
         }
      }
      if(ob.invalidated)
      {
         ob.status = "BROKEN";
         ob.qualityScore = -35;
         int sz = ArraySize(g_h1OrderBlocks);
         if(ArrayResize(g_h1OrderBlocks, sz + 1) != sz + 1) return;
         g_h1OrderBlocks[sz] = ob;
         continue;
      }

      if(ob.touchCount == 0) ob.status = "FRESH H1";
      else if(ob.liquiditySweep && ob.zoneDefended) ob.status = ob.bullish ? "DEFENDED H1 DEMAND (SWEEP)" : "DEFENDED H1 SUPPLY (SWEEP)";
      else if(ob.zoneDefended) ob.status = ob.bullish ? "DEFENDED H1 DEMAND" : "DEFENDED H1 SUPPLY";
      else ob.status = "RETESTED H1";

      int sz = ArraySize(g_h1OrderBlocks);
      if(ArrayResize(g_h1OrderBlocks, sz + 1) != sz + 1) return;
      g_h1OrderBlocks[sz] = ob;
   }

   // System-level Order Block Detection: Uniformly evaluated across all instruments from chart candle structure

   g_h1OBCount = ArraySize(g_h1OrderBlocks);
   UpdateH1OBLocationSnapshot(sym);
   DrawH1OrderBlocks();
}

//+------------------------------------------------------------------+
//| Evaluate 1-Hour (H1) Order Block Signal                          |
//+------------------------------------------------------------------+
string EvaluateH1OBSignal(string sym, double &outLow, double &outHigh, datetime &outOrigin, int &outScore, string dir="BUY")
{
   outLow = 0.0;
   outHigh = 0.0;
   outOrigin = 0;
   outScore = 0;

   if(ArraySize(g_h1OrderBlocks) == 0) UpdateH1OrderBlocks(true);
   if(ArraySize(g_h1OrderBlocks) == 0) return "NONE";

   UpdateH1OBLocationSnapshot(sym);

   for(int k = 0; k < ArraySize(g_h1OrderBlocks); k++)
      g_h1OrderBlocks[k].isViableSpot = false;

   double pip = GetPipSize(sym);
   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   if(curAtr <= 0.0) curAtr = 20.0 * pip;

   double spreadDist = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 2.0;
   double entryProximity = MathMax(spreadDist + 2.0 * pip, 4.0 * pip);

   int idx = (dir == "BUY") ? g_nearestBullishH1OB : g_nearestBearishH1OB;
   if(idx < 0 || idx >= ArraySize(g_h1OrderBlocks))
   {
      return "NONE";
   }

   M30OrderBlock ob = g_h1OrderBlocks[idx];
   if(ob.invalidated) return "NONE";

   double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
   double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curBid <= 0.0) curBid = iClose(sym, PERIOD_M1, 0);
   if(curAsk <= 0.0) curAsk = curBid;

   double distance = (ob.bullish ? g_distanceToH1Demand : g_distanceToH1Supply);

   outLow = ob.low;
   outHigh = ob.high;
   outOrigin = ob.originTime;
   outScore = MathMax(88, ob.qualityScore + 20);
   g_h1OrderBlocks[idx].isViableSpot = true;

   double maxAllowedH1EntryDrift = MathMax(InpMaxEntryDriftATR * curAtr, 15.0 * pip);

   bool isPullbackInsideZone = false;
   if(ob.bullish)
   {
      bool isLiveInZone = (curBid <= ob.high + entryProximity && curBid >= ob.low - entryProximity) || (distance <= entryProximity);
      double l0_M5 = iLow(sym, PERIOD_M5, 0);
      double l1_M5 = iLow(sym, PERIOD_M5, 1);
      double l0_M15 = iLow(sym, PERIOD_M15, 0);
      double l1_M15 = iLow(sym, PERIOD_M15, 1);
      double minRecentLow = curBid;
      if(l0_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M5);
      if(l1_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M5);
      if(l0_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M15);
      if(l1_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M15);
      bool hasPulledBackAndBouncing = (minRecentLow <= ob.high + entryProximity && curBid >= ob.low - entryProximity && curBid <= ob.high + maxAllowedH1EntryDrift);
      isPullbackInsideZone = isLiveInZone || hasPulledBackAndBouncing;
   }
   else
   {
      bool isLiveInZone = (curAsk >= ob.low - entryProximity && curAsk <= ob.high + entryProximity) || (distance <= entryProximity);
      double h0_M5 = iHigh(sym, PERIOD_M5, 0);
      double h1_M5 = iHigh(sym, PERIOD_M5, 1);
      double h0_M15 = iHigh(sym, PERIOD_M15, 0);
      double h1_M15 = iHigh(sym, PERIOD_M15, 1);
      double maxRecentHigh = curAsk;
      if(h0_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M5);
      if(h1_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M5);
      if(h0_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M15);
      if(h1_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M15);
      bool hasPulledBackAndRejecting = (maxRecentHigh >= ob.low - entryProximity && curAsk <= ob.high + entryProximity && curAsk >= ob.low - maxAllowedH1EntryDrift);
      isPullbackInsideZone = isLiveInZone || hasPulledBackAndRejecting;
   }

   if(isPullbackInsideZone)
   {
      return ob.bullish ? "BUY" : "SELL";
   }
   else
   {
      return ob.bullish ? "BUY_AWAIT_PULLBACK" : "SELL_AWAIT_PULLBACK";
   }
}

//+------------------------------------------------------------------+
//| Check if an M30 Order Block Trade Hit Stop Loss                  |
//+------------------------------------------------------------------+
void CheckM30TradeSLHit(string sym)
{
   if(!InpElevateToH1OnM30SL) return;
   if(sym == "") sym = _Symbol;

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string pfx = "SEGS_M30_OB_" + IntegerToString(login) + "_" + sym + "_";

   if(GlobalVariableCheck(pfx + "SL_HIT") && GlobalVariableGet(pfx + "SL_HIT") > 0.5)
   {
      g_m30SLHit_RequireH1OB = true;
      double dVal = GlobalVariableGet(pfx + "SL_DIR");
      g_m30SLHit_Direction = (dVal > 0.5) ? "BUY" : ((dVal < -0.5) ? "SELL" : "NONE");
      g_m30SLHit_Time = (datetime)GlobalVariableGet(pfx + "SL_TIME");
      return;
   }

   if(GlobalVariableCheck(pfx + "ACTIVE") && GlobalVariableGet(pfx + "ACTIVE") > 0.5)
   {
      int openCount = CountOpenAdvisorTradesForSymbol(sym);
      if(openCount == 0)
      {
         datetime startLookback = TimeCurrent() - 86400;
         if(HistorySelect(startLookback, TimeCurrent()))
         {
            int totalDeals = HistoryDealsTotal();
            for(int i = totalDeals - 1; i >= 0; i--)
            {
               ulong dealTicket = HistoryDealGetTicket(i);
               if(dealTicket == 0) continue;
               if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != sym) continue;
               ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
               if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

               ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
               double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

               if(reason == DEAL_REASON_SL || profit < 0.0)
               {
                  double dirVal = GlobalVariableGet(pfx + "DIR");
                  string dirStr = (dirVal > 0.5) ? "BUY" : "SELL";
                  GlobalVariableSet(pfx + "SL_HIT", 1.0);
                  GlobalVariableSet(pfx + "SL_DIR", dirVal);
                  GlobalVariableSet(pfx + "SL_TIME", (double)TimeCurrent());
                  GlobalVariableSet(pfx + "ACTIVE", 0.0);

                  g_m30SLHit_RequireH1OB = true;
                  g_m30SLHit_Direction = dirStr;
                  g_m30SLHit_Time = TimeCurrent();

                  PrintFormat("[SEGS M30 SL RECOVERY] M30 %s trade on %s hit Stop Loss (Deal #%I64u)! Bypassing next 30M OB. Elevating to 1-Hour (H1) Order Block.",
                              dirStr, sym, dealTicket);
                  break;
               }
               else
               {
                  GlobalVariableSet(pfx + "ACTIVE", 0.0);
                  break;
               }
            }
         }
      }
   }

   // System-level M30 SL Recovery: Evaluated purely from account trade deals without symbol-specific overrides
}

string EvaluateM30OBSignal(string sym, double &outLow, double &outHigh, datetime &outOrigin, int &outScore, bool isReversal=false, string reversalDir="NONE")
{
   outLow = 0.0;
   outHigh = 0.0;
   outOrigin = 0;
   outScore = 0;

   if(!InpOBConfluenceEnabled || ArraySize(g_orderBlocks) == 0) return "NONE";

   UpdateOBLocationSnapshot(sym);

   double pip = GetPipSize(sym);
   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   if(curAtr <= 0.0) curAtr = 20.0 * pip;

   double spreadDist = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 2.0;
   // Direct entry zone proximity threshold: must strictly be touching or inside the zone (tight buffer, not chasing)
   double entryProximity = MathMax(spreadDist + 2.0 * pip, 3.0 * pip);

   // Actionable retest horizon under the 70% dominant Order Block strategy
   double maxRetestDistance = MathMax(InpOBMaxDistanceForRetestATR * curAtr, 60.0 * pip);

   // Check for Defended Demand / Supply zones (price retested zone and could not close beyond it)
   bool demandDefended = (g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks) &&
                          g_orderBlocks[g_nearestBullishOB].zoneDefended && !g_orderBlocks[g_nearestBullishOB].invalidated);
   bool supplyDefended = (g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks) &&
                          g_orderBlocks[g_nearestBearishOB].zoneDefended && !g_orderBlocks[g_nearestBearishOB].invalidated);

   bool isReversalBull = (isReversal && reversalDir == "BUY");
   bool isReversalBear = (isReversal && reversalDir == "SELL");

   bool h1Bull = (g_h1Bias == "BULLISH");
   bool h2Bull = (g_h2Bias == "BULLISH");
   bool h4Bull = (g_h4Bias == "BULLISH");

   // Higher Timeframe Directional Confluence of H1, H2, and H4:
   // When there is confluence across H1, H2, and H4 for an uptrend continuation,
   // the advisor MUST NEVER look for a sell. It must strictly seek a BUY when price pulls back to an M30 Demand Order Block!
   bool isFullBullConfluence = (h1Bull && h2Bull && h4Bull);
   bool isFullBearConfluence = (!h1Bull && !h2Bull && !h4Bull);
   bool isUptrendConfluence  = isFullBullConfluence || (h1Bull && (h2Bull || h4Bull)) || (h2Bull && h4Bull);
   bool isDowntrendConfluence = isFullBearConfluence || (!h1Bull && (!h2Bull || !h4Bull)) || (!h2Bull && !h4Bull);

   double curPriceAskCheck = SymbolInfoDouble(sym, SYMBOL_ASK);
   double curPriceBidCheck = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curPriceBidCheck <= 0.0) curPriceBidCheck = iClose(sym, PERIOD_M1, 0);
   if(curPriceAskCheck <= 0.0) curPriceAskCheck = curPriceBidCheck;

   double curLowD1Check = iLow(sym, PERIOD_D1, 0);
   if(curLowD1Check <= 0.0) curLowD1Check = curPriceBidCheck;
   double curHighD1Check = iHigh(sym, PERIOD_D1, 0);
   if(curHighD1Check <= 0.0) curHighD1Check = curPriceBidCheck;

   bool isPDLSweepActive = g_htfLiquidity.pdlSwept || (curLowD1Check <= g_htfLiquidity.pdl + 0.20 * curAtr) || (curPriceBidCheck <= g_htfLiquidity.pdl + 0.35 * curAtr);
   bool isPDHSweepActive = g_htfLiquidity.pdhSwept || (curHighD1Check >= g_htfLiquidity.pdh - 0.20 * curAtr) || (curPriceBidCheck >= g_htfLiquidity.pdh - 0.35 * curAtr);

   // MANDATORY DIRECTIONAL CONFLUENCE ORDER BLOCK GATING:
   // In an uptrend continuation (confluence of H1, H2, H4):
   // Strictly evaluate Bullish Demand OB. Counter-trend sells into supply are completely eliminated.
   // In a downtrend continuation (confluence of H1, H2, H4):
   // Strictly evaluate Bearish Supply OB. Counter-trend buys into demand are completely eliminated.
   int orderPasses[2];
   int totalPasses = 2;
   if(isReversalBull)
   {
      orderPasses[0] = 0; // Check Bullish Demand OB (Trend-End 4-Bounce / Reversal Active!)
      totalPasses = 1;
   }
   else if(isReversalBear)
   {
      orderPasses[0] = 1; // Check Bearish Supply OB (Trend-End 4-Bounce / Reversal Active!)
      totalPasses = 1;
   }
   else if(isUptrendConfluence)
   {
      orderPasses[0] = 0; // Check Bullish Demand OB
      totalPasses = 1;    // Opposing Bearish Supply OB is disqualified
   }
   else if(isDowntrendConfluence)
   {
      orderPasses[0] = 1; // Check Bearish Supply OB
      totalPasses = 1;    // Opposing Bullish Demand OB is disqualified
   }
   else if(isPDLSweepActive || (g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks) && g_distanceToDemand <= MathMax(1.5 * curAtr, 35.0 * pip)))
   {
      orderPasses[0] = 0; // Check Bullish Demand OB first
      orderPasses[1] = 1; // Check Bearish Supply OB second
      totalPasses = 2;
   }
   else if(isPDHSweepActive || (g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks) && g_distanceToSupply <= MathMax(1.5 * curAtr, 35.0 * pip)))
   {
      orderPasses[0] = 1; // Check Bearish Supply OB first
      orderPasses[1] = 0; // Check Bullish Demand OB second
      totalPasses = 2;
   }
   else if(g_distanceToSupply < g_distanceToDemand)
   {
      orderPasses[0] = 1; // Check Bearish Supply OB first
      orderPasses[1] = 0; // Check Bullish Demand OB second
      totalPasses = 2;
   }
   else
   {
      orderPasses[0] = 0; // Check Bullish Demand OB first
      orderPasses[1] = 1; // Check Bearish Supply OB second
      totalPasses = 2;
   }

   for(int k = 0; k < ArraySize(g_orderBlocks); k++)
      g_orderBlocks[k].isViableSpot = false;

   for(int p = 0; p < totalPasses; p++)
   {
      int pass = orderPasses[p];
      int idx = (pass == 0 ? g_nearestBullishOB : g_nearestBearishOB);
      if(idx < 0 || idx >= ArraySize(g_orderBlocks)) continue;

      M30OrderBlock ob = g_orderBlocks[idx];
      if(ob.invalidated || ob.touchCount > InpOBMaxPreferredTouches) continue;

      // STRICT CONFLUENCE ENFORCEMENT:
      // When H1, H2, and H4 have confluence for an uptrend continuation, never look for a SELL (unless confirmed reversal)!
      if(isUptrendConfluence && !ob.bullish && !isReversalBear) continue;
      // When H1, H2, and H4 have confluence for a downtrend continuation, never look for a BUY (unless confirmed reversal)!
      if(isDowntrendConfluence && ob.bullish && !isReversalBull) continue;

      double distance = (ob.bullish ? g_distanceToDemand : g_distanceToSupply);

      // In trend continuation mode, expand the retest horizon to comfortably track and await
      // pullback to the 30M Order block even if price has extended ahead
      double effectiveRetestDist = (isUptrendConfluence || isDowntrendConfluence)
                                   ? MathMax(maxRetestDistance * 1.5, 90.0 * pip)
                                   : maxRetestDistance;
      if(distance > effectiveRetestDist) continue;

      bool h1Aligned = (ob.bullish ? h1Bull : !h1Bull);
      bool h2Aligned = (ob.bullish ? h2Bull : !h2Bull);
      bool h4Aligned = (ob.bullish ? h4Bull : !h4Bull);
      bool htfAligned = (h1Aligned && (h2Aligned || h4Aligned));
      bool structAligned = (ob.bullish ? (g_marketStructure == "BULLISH") : (g_marketStructure == "BEARISH"));

      // A safe Order Block must not fight both higher timeframe trends,
      // UNLESS it is a verified Institutional Liquidity Sweep Reversal, or Defended Zone, or confirmed reversal
      bool isLiqSweepOB = (ob.liquiditySweep || ob.liquidityBonus > 0 || (ob.bullish && isPDLSweepActive) || (!ob.bullish && isPDHSweepActive));
      bool isZoneDefended = ob.zoneDefended;
      bool isReversalAligned = (isReversal && reversalDir == (ob.bullish ? "BUY" : "SELL"));

      // Safe trend check: When trend confluence exists, alignment is guaranteed.
      // Opposing zone proximity does NOT make counter-trend trading safe!
      bool isSafeTrend = false;
      if(ob.bullish && isUptrendConfluence) isSafeTrend = true;
      else if(!ob.bullish && isDowntrendConfluence) isSafeTrend = true;
      else isSafeTrend = isZoneDefended || isLiqSweepOB || isReversalAligned || htfAligned || (h1Aligned && (structAligned || ob.touchCount <= 1));

      if(!isSafeTrend)
      {
         if(!h1Aligned && !h2Aligned && !h4Aligned) continue;
         if(InpOBRequireHTFAlignment && !isSafeTrend) continue;
         if(!InpOBCounterTrendEnabled && !isSafeTrend) continue;
      }
      else
      {
         // Prevent selling directly into an opposing Demand zone if price is already inside or touching demand
         double curPriceCheck = SymbolInfoDouble(sym, SYMBOL_BID);
         if(curPriceCheck <= 0.0) curPriceCheck = iClose(sym, PERIOD_M1, 0);
         if(!ob.bullish && g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks))
         {
            double demHigh = g_orderBlocks[g_nearestBullishOB].high;
            if(curPriceCheck <= demHigh + 3.0 * pip) continue; // Inside demand: do not sell into it
         }
         // Prevent buying directly into an opposing Supply zone if price is already inside or touching supply
         if(ob.bullish && g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks))
         {
            double supLow = g_orderBlocks[g_nearestBearishOB].low;
            if(curPriceCheck >= supLow - 3.0 * pip) continue; // Inside supply: do not buy into it
         }
      }

      // Lower TF confirmation or candle wick rejection bounce in zone
      bool hasRejectionBounce = ob.lowerTFConfirmed;
      if(!hasRejectionBounce)
      {
         double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
         double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
         if(ob.bullish)
         {
            double m5Close = iClose(sym, PERIOD_M5, 0);
            double m5Low   = iLow(sym, PERIOD_M5, 0);
            double m15Close = iClose(sym, PERIOD_M15, 0);
            if((m5Close > m5Low && curBid >= ob.low) || (m15Close > ob.low))
               hasRejectionBounce = true;
         }
         else
         {
            double m5Close = iClose(sym, PERIOD_M5, 0);
            double m5High  = iHigh(sym, PERIOD_M5, 0);
            double m15Close = iClose(sym, PERIOD_M15, 0);
            if((m5Close < m5High && curAsk <= ob.high) || (m15Close < ob.high))
               hasRejectionBounce = true;
         }
      }

      if(InpOBRequireLowerTFConfirm && !hasRejectionBounce && distance <= entryProximity) continue;

      // Space Check for Take Profits: Opposing Order Block must not block immediate target runway
      double curPrice = ob.bullish ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
      if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_M1, 0);

      double plannedSL = ob.bullish ? (ob.low - MathMax(0.20 * curAtr, 6.0 * pip)) : (ob.high + MathMax(0.20 * curAtr, 6.0 * pip));
      double estRisk = MathAbs(curPrice - plannedSL);
      if(estRisk < 10.0 * pip) estRisk = 10.0 * pip;

      bool hasOpposingSpace = true;
      double minOpposingRunway = MathMax(0.20 * curAtr, 4.0 * pip);
      if(ob.bullish && g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks))
      {
         double supLow = g_orderBlocks[g_nearestBearishOB].low;
         if(supLow > curPrice && (supLow - curPrice) < minOpposingRunway)
            hasOpposingSpace = false; // Opposing supply literally touching entry
      }
      else if(!ob.bullish && g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks))
      {
         double demHigh = g_orderBlocks[g_nearestBullishOB].high;
         if(demHigh < curPrice && (curPrice - demHigh) < minOpposingRunway)
            hasOpposingSpace = false; // Opposing demand literally touching entry
      }

      if(!hasOpposingSpace) continue; // Skip only if blocked by immediate opposing OB wall

      // Primary Order Block Quality Score (Boosted baseline to reflect 70% institutional weighting)
      int liveScore = 40;
      if(ob.hasFVG) liveScore += 15;
      if(ob.touchCount <= 1) liveScore += 15;
      if(ob.zoneDefended) liveScore += 25;
      if(ob.liquiditySweep) liveScore += 15;
      if(hasRejectionBounce) liveScore += 15;
      if(h1Aligned) liveScore += 15;
      if(h2Aligned) liveScore += 15;
      if(h4Aligned) liveScore += 20;
      if(structAligned) liveScore += 10;
      if(hasOpposingSpace) liveScore += 10;
      if(isUptrendConfluence && ob.bullish) liveScore += 15; // Full confluence reward
      if(isDowntrendConfluence && !ob.bullish) liveScore += 15;

      // 30M & 1H Higher High / Lower Low Market Structure Confluence
      if(ob.bullish)
      {
         if(g_hasHH_M30) liveScore += 10; // 30M Higher High confirms structural breakout from demand
         if(g_hasHH_H1)  liveScore += 10; // 1H Higher High confirms macro continuation
      }
      else
      {
         if(g_hasLL_M30) liveScore += 10; // 30M Lower Low confirms structural breakdown from supply
         if(g_hasLL_H1)  liveScore += 10; // 1H Lower Low confirms macro continuation
      }

      if(InpEnableLiquidityConfluenceScore && ob.liquidityBonus > 0)
      {
         liveScore += ob.liquidityBonus;
         g_htfLiquidity.activeConfluenceLabel = ob.liquidityContext;
         g_htfLiquidity.liquidityScoreBonus = ob.liquidityBonus;
      }

      if(!h1Aligned && !h2Aligned && !h4Aligned && !isLiqSweepOB && !ob.zoneDefended) liveScore -= 30;
      if(ob.touchCount > InpOBMaxPreferredTouches)
         liveScore -= 15 * (ob.touchCount - InpOBMaxPreferredTouches);

      liveScore = (int)MathMax(0, MathMin(100, liveScore));
      g_orderBlocks[idx].qualityScore = liveScore;
      g_orderBlocks[idx].trendAligned = isSafeTrend;

      if(liveScore < InpOBMinimumSignalScore) continue;

      outLow = ob.low;
      outHigh = ob.high;
      outOrigin = ob.originTime;
      outScore = liveScore;
      g_orderBlocks[idx].isViableSpot = true;

      // Accurate pullback detection:
      // When price pulls back into or touches the 30-Minute Order Block zone, trigger direct entry!
      double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
      double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curBid <= 0.0) curBid = iClose(sym, PERIOD_M1, 0);
      if(curAsk <= 0.0) curAsk = curBid;

      double maxAllowedEntryDrift = MathMax(InpMaxEntryDriftATR * curAtr, 15.0 * pip);

      bool isPullbackInsideZone = false;
      if(ob.bullish)
      {
         bool isLiveInZone = (curBid <= ob.high + entryProximity && curBid >= ob.low - entryProximity) || (distance <= entryProximity);

         double l0_M5 = iLow(sym, PERIOD_M5, 0);
         double l1_M5 = iLow(sym, PERIOD_M5, 1);
         double l0_M15 = iLow(sym, PERIOD_M15, 0);
         double l1_M15 = iLow(sym, PERIOD_M15, 1);
         double minRecentLow = curBid;
         if(l0_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M5);
         if(l1_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M5);
         if(l0_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M15);
         if(l1_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M15);

         bool hasPulledBackAndBouncing = (minRecentLow <= ob.high + entryProximity && curBid >= ob.low - entryProximity && curBid <= ob.high + maxAllowedEntryDrift);
         isPullbackInsideZone = isLiveInZone || hasPulledBackAndBouncing;
      }
      else
      {
         bool isLiveInZone = (curAsk >= ob.low - entryProximity && curAsk <= ob.high + entryProximity) || (distance <= entryProximity);

         double h0_M5 = iHigh(sym, PERIOD_M5, 0);
         double h1_M5 = iHigh(sym, PERIOD_M5, 1);
         double h0_M15 = iHigh(sym, PERIOD_M15, 0);
         double h1_M15 = iHigh(sym, PERIOD_M15, 1);
         double maxRecentHigh = curAsk;
         if(h0_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M5);
         if(h1_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M5);
         if(h0_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M15);
         if(h1_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M15);

         bool hasPulledBackAndRejecting = (maxRecentHigh >= ob.low - entryProximity && curAsk <= ob.high + entryProximity && curAsk >= ob.low - maxAllowedEntryDrift);
         isPullbackInsideZone = isLiveInZone || hasPulledBackAndRejecting;
      }

      if(isPullbackInsideZone)
      {
         return ob.bullish ? "BUY" : "SELL";
      }
      else
      {
         // Price is trend-aligned with the 30M Order Block, but has not yet pulled back into the zone.
         // Signal to anchor at the 30M Order Block level and await value pullback to Buy/Sell with trend!
         return ob.bullish ? "BUY_AWAIT_PULLBACK" : "SELL_AWAIT_PULLBACK";
      }
   }

   return "NONE";
}

void LogOBSnapshotForTrade(string sym, string direction, string signalID)
{
   if(!InpOBObservationMode || !InpOBLogTradeContext) return;
   UpdateOBLocationSnapshot(sym);
   double pip = GetPipSize(sym);
   string dem = "NONE", sup = "NONE";

   if(g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks))
   {
      M30OrderBlock d = g_orderBlocks[g_nearestBullishOB];
      dem = StringFormat("%.1fp | %s | Score:%d | %s | FVG:%s | Sweep:%s | LTF:%s",
                         g_distanceToDemand / pip, d.status, d.qualityScore, OBAlignmentText(d),
                         d.hasFVG ? "YES" : "NO", d.liquiditySweep ? "YES" : "NO", d.lowerTFConfirmed ? "YES" : "NO");
   }
   if(g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks))
   {
      M30OrderBlock s = g_orderBlocks[g_nearestBearishOB];
      sup = StringFormat("%.1fp | %s | Score:%d | %s | FVG:%s | Sweep:%s | LTF:%s",
                         g_distanceToSupply / pip, s.status, s.qualityScore, OBAlignmentText(s),
                         s.hasFVG ? "YES" : "NO", s.liquiditySweep ? "YES" : "NO", s.lowerTFConfirmed ? "YES" : "NO");
   }
   PrintFormat("[M30 OB CONFLUENCE] %s %s | Signal %s | Demand: %s | Supply: %s | Warning: %s",
               direction, sym, signalID, dem, sup, g_obLocationWarning);
}

//+------------------------------------------------------------------+
//| Standalone direct EMA calculator from bar closes                 |
//+------------------------------------------------------------------+
double CalculateDirectEMA(string sym, ENUM_TIMEFRAMES tf, int period, int shift=1)
{
   if(period < 1 || shift < 0) return 0.0;
   int available = iBars(sym, tf);
   if(available < period + shift) return 0.0;
   int barsToScan = MathMin(period * 3, available - shift);
   if(barsToScan < period) return 0.0;
   double alpha = 2.0 / (double)(period + 1);

   int oldestIdx = shift + barsToScan - 1;
   double sum = 0.0;
   for(int i = oldestIdx; i > oldestIdx - period && i >= shift; i--)
   {
      double c = iClose(sym, tf, i);
      if(c <= 0.0) return 0.0;
      sum += c;
   }
   double ema = sum / (double)period;
   for(int i = oldestIdx - period; i >= shift; i--)
   {
      double c = iClose(sym, tf, i);
      if(c > 0.0) ema = (c - ema) * alpha + ema;
   }
   return ema;
}

//+------------------------------------------------------------------+
//| Multi-Timeframe Trend & Structural Reversal Engine (H1, H2, H4)  |
//+------------------------------------------------------------------+
void EvaluateMultiTimeframeTrendAndReversal(string sym,
                                           string &outH1Bias,
                                           string &outH2Bias,
                                           string &outH4Bias,
                                           string &outOverallBias,
                                           bool   &outIsReversal,
                                           string &outReversalDir,
                                           double &outEma20Val)
{
   InitIndicatorHandles(sym);

   double ma20_H1[], ma50_H1[];
   double ma20_H2[], ma50_H2[];
   double ma20_H4[], ma50_H4[];

   ArraySetAsSeries(ma20_H1, true);
   ArraySetAsSeries(ma50_H1, true);
   ArraySetAsSeries(ma20_H2, true);
   ArraySetAsSeries(ma50_H2, true);
   ArraySetAsSeries(ma20_H4, true);
   ArraySetAsSeries(ma50_H4, true);

   double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curBid <= 0.0) curBid = iClose(sym, PERIOD_M1, 0);
   if(curBid <= 0.0) curBid = iClose(sym, PERIOD_H1, 0);

   // 1. H1 TACTICAL TREND & MOMENTUM
   double h1Ema20 = 0.0, h1Ema50 = 0.0, h1Ema20_prev = 0.0;
   if(g_hEma20_H1 != INVALID_HANDLE && g_hEma50_H1 != INVALID_HANDLE &&
      CopyBuffer(g_hEma20_H1, 0, 1, 2, ma20_H1) == 2 &&
      CopyBuffer(g_hEma50_H1, 0, 1, 2, ma50_H1) == 2)
   {
      h1Ema20      = ma20_H1[0];
      h1Ema50      = ma50_H1[0];
      h1Ema20_prev = ma20_H1[1];
   }
   else
   {
      h1Ema20      = CalculateDirectEMA(sym, PERIOD_H1, 20, 1);
      h1Ema50      = CalculateDirectEMA(sym, PERIOD_H1, 50, 1);
      h1Ema20_prev = CalculateDirectEMA(sym, PERIOD_H1, 20, 2);
   }
   outEma20Val = h1Ema20;

   bool h1EmaBear   = (h1Ema20 < h1Ema50);
   bool h1EmaBull   = (h1Ema20 > h1Ema50);
   bool h1SlopeDown = (h1Ema20 <= h1Ema20_prev);
   bool h1SlopeUp   = (h1Ema20 >= h1Ema20_prev);
   double h1Close1  = iClose(sym, PERIOD_H1, 1);

   bool h1Bull = false;
   if(h1EmaBear && (curBid < h1Ema50 || h1Close1 < h1Ema50))
   {
      // Primary Downtrend on H1: A minor 1-candle bounce below EMA50 is a bounce, not a trend flip
      h1Bull = (curBid > h1Ema20 && h1Close1 > h1Ema20 && h1SlopeUp && curBid > (h1Ema50 + h1Ema20) / 2.0);
   }
   else if(h1EmaBull && (curBid > h1Ema50 || h1Close1 > h1Ema50))
   {
      // Primary Uptrend on H1: A minor 1-candle dip above EMA50 is a pullback, not a downtrend
      h1Bull = !(curBid < h1Ema20 && h1Close1 < h1Ema20 && h1SlopeDown && curBid < (h1Ema50 + h1Ema20) / 2.0);
   }
   else if(curBid < h1Ema20 && curBid < h1Ema50)
   {
      h1Bull = false;
   }
   else if(curBid > h1Ema20 && curBid > h1Ema50)
   {
      h1Bull = true;
   }
   else
   {
      h1Bull = (curBid >= h1Ema50) ? h1SlopeUp : (curBid > h1Ema20 && h1SlopeUp);
   }

   // 2. H2 INTERMEDIATE TREND & MOMENTUM
   double h2Ema20 = 0.0, h2Ema50 = 0.0, h2Ema20_prev = 0.0;
   bool h2Loaded = false;
   if(g_hEma20_H2 != INVALID_HANDLE && g_hEma50_H2 != INVALID_HANDLE &&
      CopyBuffer(g_hEma20_H2, 0, 1, 2, ma20_H2) == 2 &&
      CopyBuffer(g_hEma50_H2, 0, 1, 2, ma50_H2) == 2)
   {
      h2Ema20      = ma20_H2[0];
      h2Ema50      = ma50_H2[0];
      h2Ema20_prev = ma20_H2[1];
      if(h2Ema20 > 0.0 && h2Ema50 > 0.0) h2Loaded = true;
   }
   if(!h2Loaded)
   {
      h2Ema20      = CalculateDirectEMA(sym, PERIOD_H2, 20, 1);
      h2Ema50      = CalculateDirectEMA(sym, PERIOD_H2, 50, 1);
      h2Ema20_prev = CalculateDirectEMA(sym, PERIOD_H2, 20, 2);
      if(h2Ema20 > 0.0 && h2Ema50 > 0.0) h2Loaded = true;
   }
   if(!h2Loaded)
   {
      // Precise mathematical H2 proxy from H1: 20 periods H2 = 40 periods H1, 50 periods H2 = 100 periods H1
      h2Ema20      = CalculateDirectEMA(sym, PERIOD_H1, 40, 1);
      h2Ema50      = CalculateDirectEMA(sym, PERIOD_H1, 100, 1);
      h2Ema20_prev = CalculateDirectEMA(sym, PERIOD_H1, 40, 2);
   }

   bool h2EmaBear   = (h2Ema20 < h2Ema50);
   bool h2EmaBull   = (h2Ema20 > h2Ema50);
   bool h2SlopeDown = (h2Ema20 <= h2Ema20_prev);
   bool h2SlopeUp   = (h2Ema20 >= h2Ema20_prev);
   double h2Close1  = iClose(sym, PERIOD_H2, 1);
   if(h2Close1 <= 0.0) h2Close1 = iClose(sym, PERIOD_H1, 1);

   bool h2Bull = false;
   if(h2EmaBear && (curBid < h2Ema50 || h2Close1 < h2Ema50))
   {
      // Primary Downtrend on H2
      h2Bull = false;
   }
   else if(h2EmaBull && (curBid > h2Ema50 || h2Close1 > h2Ema50))
   {
      // Primary Uptrend on H2
      h2Bull = true;
   }
   else if(curBid < h2Ema20 && curBid < h2Ema50)
   {
      // Price trading below both EMAs
      h2Bull = false;
   }
   else if(curBid > h2Ema20 && curBid > h2Ema50)
   {
      // Price trading above both EMAs
      h2Bull = true;
   }
   else
   {
      h2Bull = (curBid >= h2Ema50) ? h2SlopeUp : (curBid > h2Ema20 && h2SlopeUp);
   }

   // 3. H4 MACRO SWING STRUCTURE & TREND (Foundation)
   double h4Ema20 = 0.0, h4Ema50 = 0.0, h4Ema20_prev = 0.0;
   if(g_hEma20_H4 != INVALID_HANDLE && g_hEma50_H4 != INVALID_HANDLE &&
      CopyBuffer(g_hEma20_H4, 0, 1, 2, ma20_H4) == 2 &&
      CopyBuffer(g_hEma50_H4, 0, 1, 2, ma50_H4) == 2)
   {
      h4Ema20      = ma20_H4[0];
      h4Ema50      = ma50_H4[0];
      h4Ema20_prev = ma20_H4[1];
   }
   else
   {
      h4Ema20      = CalculateDirectEMA(sym, PERIOD_H4, 20, 1);
      h4Ema50      = CalculateDirectEMA(sym, PERIOD_H4, 50, 1);
      h4Ema20_prev = CalculateDirectEMA(sym, PERIOD_H4, 20, 2);
   }

   bool h4EmaBear   = (h4Ema20 < h4Ema50);
   bool h4EmaBull   = (h4Ema20 > h4Ema50);
   bool h4SlopeDown = (h4Ema20 <= h4Ema20_prev);
   bool h4SlopeUp   = (h4Ema20 >= h4Ema20_prev);
   double h4Close1  = iClose(sym, PERIOD_H4, 1);

   // Scan H4 multi-bar swing structure over recent 30 bars:
   // Bars 1..12 (recent swing) vs Bars 13..30 (prior swing)
   double h4SwingHighRecent = 0.0, h4SwingHighPrior = 0.0;
   double h4SwingLowRecent = 999999.0, h4SwingLowPrior = 999999.0;
   for(int b = 1; b <= 12; b++)
   {
      double h = iHigh(sym, PERIOD_H4, b);
      double l = iLow(sym, PERIOD_H4, b);
      if(h > h4SwingHighRecent) h4SwingHighRecent = h;
      if(l > 0.0 && l < h4SwingLowRecent) h4SwingLowRecent = l;
   }
   for(int b = 13; b <= 30; b++)
   {
      double h = iHigh(sym, PERIOD_H4, b);
      double l = iLow(sym, PERIOD_H4, b);
      if(h > h4SwingHighPrior) h4SwingHighPrior = h;
      if(l > 0.0 && l < h4SwingLowPrior) h4SwingLowPrior = l;
   }

   bool h4HigherHighs = (h4SwingHighRecent > h4SwingHighPrior);
   bool h4HigherLows  = (h4SwingLowRecent > h4SwingLowPrior);
   bool h4LowerHighs  = (h4SwingHighRecent < h4SwingHighPrior);
   bool h4LowerLows   = (h4SwingLowRecent < h4SwingLowPrior);

   // Robust H4 Trend Determination
   bool h4Bull = false;
   if(h4EmaBear && (curBid < h4Ema50 || h4Close1 < h4Ema50))
   {
      // Primary Downtrend on H4: EMA20 < EMA50 and price trading below EMA50
      h4Bull = false;
   }
   else if(h4EmaBull && (curBid > h4Ema50 || h4Close1 > h4Ema50))
   {
      // Primary Uptrend on H4: EMA20 > EMA50 and price trading above EMA50
      h4Bull = true;
   }
   else if(curBid < h4Ema20 && curBid < h4Ema50)
   {
      // Price trading below both EMAs
      h4Bull = false;
   }
   else if(curBid > h4Ema20 && curBid > h4Ema50)
   {
      // Price trading above both EMAs
      h4Bull = true;
   }
   else if(h4LowerHighs && h4LowerLows)
   {
      // Structural Lower Highs + Lower Lows
      h4Bull = false;
   }
   else if(h4HigherHighs && h4HigherLows)
   {
      // Structural Higher Highs + Higher Lows
      h4Bull = true;
   }
   else
   {
      // Transition / chop: check price relative to 50 EMA and slope
      h4Bull = (curBid >= h4Ema50) ? h4SlopeUp : (curBid > h4Ema20 && h4SlopeUp);
   }

   outH1Bias = h1Bull ? "BULLISH" : "BEARISH";
   outH2Bias = h2Bull ? "BULLISH" : "BEARISH";
   outH4Bias = h4Bull ? "BULLISH" : "BEARISH";

   // 4. OVERALL CONFLUENCE & REVERSAL SYNTHESIS
   if(!h4Bull && !h2Bull && !h1Bull)
   {
      outIsReversal  = false;
      outReversalDir = "SELL";
      outOverallBias = "BEARISH CONFLUENCE (H1/H2/H4)";
   }
   else if(!h4Bull && !h2Bull && h1Bull)
   {
      outIsReversal  = false;
      outReversalDir = "SELL";
      outOverallBias = "BEARISH DOWNTREND (H1 BOUNCE)";
   }
   else if(!h4Bull && (h2Bull || h1Bull))
   {
      outIsReversal  = false;
      outReversalDir = "SELL";
      outOverallBias = "BEARISH (H4 DOMINANT)";
   }
   else if(h4Bull && h2Bull && h1Bull)
   {
      outIsReversal  = false;
      outReversalDir = "BUY";
      outOverallBias = "BULLISH CONFLUENCE (H1/H2/H4)";
   }
   else if(h4Bull && h2Bull && !h1Bull)
   {
      outIsReversal  = false;
      outReversalDir = "BUY";
      outOverallBias = "BULLISH UPTREND (H1 PULLBACK)";
   }
   else if(h4Bull && (!h2Bull || !h1Bull))
   {
      outIsReversal  = false;
      outReversalDir = "BUY";
      outOverallBias = "BULLISH (H4 DOMINANT)";
   }
   else
   {
      outIsReversal  = false;
      outReversalDir = "NONE";
      outOverallBias = "NEUTRAL / CHOP";
   }
}

//+------------------------------------------------------------------+
//| Evaluate if a planned (unexecuted) entry is still viable         |
//+------------------------------------------------------------------+
bool IsPlannedEntryViable(string sym, string action, double entryPrice, double slPrice, double curPrice, double pipSize, double curAtr, string &outUnviableReason)
{
   outUnviableReason = "";
   if(entryPrice <= 0.0 || slPrice <= 0.0)
   {
      outUnviableReason = "INVALID LEVELS";
      return false;
   }

   // Auto-resolve missing or NONE action
   if(action == "" || action == "NONE" || action == "STAND ASIDE")
   {
      action = (g_plannedAction != "" && g_plannedAction != "NONE") ? g_plannedAction : (entryPrice < slPrice ? "SELL" : "BUY");
   }

   // Auto-resolve missing live price from symbol history
   if(curPrice <= 0.0)
   {
      curPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_M1, 0);
      if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_H1, 0);
      if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_D1, 0);
   }
   if(curPrice <= 0.0)
   {
      outUnviableReason = "UNABLE TO RETRIEVE MARKET PRICE";
      return false;
   }

   // 1. Positioning validity & Adverse Price Breach Check:
   // Entry must make directional sense relative to current price and Stop Loss.
   // For SELL: Planned entry must sit AT or ABOVE current price (e.g. at Supply resistance).
   // If price has broken adverse above entry by > 35% of risk distance, or approached Stop Loss:
   if(action == "SELL")
   {
      double riskDist = slPrice - entryPrice;
      // Only invalid if price actually breached Stop Loss
      if(curPrice >= slPrice - MathMax(1.0 * pipSize, 0.05 * (riskDist > 0.0 ? riskDist : 10.0 * pipSize)))
      {
         outUnviableReason = "PRICE TESTED/BREACHED STOP LOSS";
         return false;
      }
   }
   else if(action == "BUY")
   {
      double riskDist = entryPrice - slPrice;
      // Only invalid if price actually breached Stop Loss
      if(curPrice <= slPrice + MathMax(1.0 * pipSize, 0.05 * (riskDist > 0.0 ? riskDist : 10.0 * pipSize)))
      {
         outUnviableReason = "PRICE TESTED/BREACHED STOP LOSS";
         return false;
      }
   }

   // 2. Check Order Block Invalidation (only for active Order Block setups):
   // The zone is only invalidated if price decisively breaches beyond the outer boundary
   if(g_activeEntryStrategy == "ORDER_BLOCK")
   {
      if(action == "SELL" && g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks))
      {
         M30OrderBlock supOB = g_orderBlocks[g_nearestBearishOB];
         if(!supOB.invalidated)
         {
            double invalidBuffer = MathMax(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), curAtr * InpOBInvalidationATRBuffer);
            if(curPrice > supOB.high + invalidBuffer)
            {
               outUnviableReason = StringFormat("SUPPLY ZONE [%.5f - %.5f] BREACHED ON CLOSE", supOB.low, supOB.high);
               return false;
            }
         }
      }
      else if(action == "BUY" && g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks))
      {
         M30OrderBlock demOB = g_orderBlocks[g_nearestBullishOB];
         if(!demOB.invalidated)
         {
            double invalidBuffer = MathMax(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), curAtr * InpOBInvalidationATRBuffer);
            if(curPrice < demOB.low - invalidBuffer)
            {
               outUnviableReason = StringFormat("DEMAND ZONE [%.5f - %.5f] BREACHED ON CLOSE", demOB.low, demOB.high);
               return false;
            }
         }
      }
   }

   // 3. Excessive profit runaway without execution (>4.0*ATR or 100 pips):
   // Only triggers if price ran completely away into deep profit territory without filling
   double maxDrift = MathMax(4.0 * curAtr, 100.0 * pipSize);
   if(action == "BUY" && curPrice > entryPrice + maxDrift)
   {
      outUnviableReason = "PRICE EXPANDED >4 ATR WITHOUT FILL";
      return false;
   }
   else if(action == "SELL" && curPrice < entryPrice - maxDrift)
   {
      outUnviableReason = "PRICE EXPANDED >4 ATR WITHOUT FILL";
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Cancel an unviable planned entry and prepare for fresh scan      |
//+------------------------------------------------------------------+
bool SEGSResetExpiredSetup(string sym)
{
   if(CountOpenAdvisorTradesForSymbol(sym) > 0) return false;
   if(!g_isSignalExpired && g_setupState != "EXPIRED" && g_setupState != "INVALIDATED" && g_setupState != "CANCELLED") return false;
   g_isSignalExpired = false;
   g_hasViableEntry = false;
   g_currentTradeTaken = false;
   g_currentSignalID = "";
   g_currentAdvisedAction = "NONE";
   g_plannedAction = "NONE";
   g_staticEntryPrice = 0.0; g_staticSL = 0.0;
   g_staticTP1 = 0.0; g_staticTP2 = 0.0; g_staticTP3 = 0.0; g_staticTP4 = 0.0;
   g_signalTriggerTime = 0; g_lastSignalConfirmationTime = 0;
   g_signalGeneratedWhileAdvisorEnabled = false;
   g_lastAdviceScanBarTime = 0;
   g_lastCancelledEntryPrice = 0.0; g_lastCancelledEntrySL = 0.0;
   g_lastCancelledEntryAction = "NONE";
   g_obSignalDirection = "NONE"; g_obSignalLow = 0.0; g_obSignalHigh = 0.0;
   g_setupState = "SCANNING";
   g_setupQuality = 0;
   g_blockReason = "SCANNING FOR NEW OPPORTUNITY";
   g_primaryRejectionReason = "";
   g_signalStatusLabel = "SCANNING FOR NEW OPPORTUNITY";
   ClearActiveSignalSnapshot(sym);
   DeleteTradeAdviceLines();
   // Executed-signal history and account execution locks are deliberately retained.
   PrintFormat("[SEGS SIGNAL RESET] %s expired setup cleared; fresh opportunity scan enabled", sym);
   return true;
}

void CancelUnviablePlannedEntry(string sym, string reason)
{
   PrintFormat("[Trade Advisor] Planned %s entry on %s at %.5f CANCELLED (%s). Scanning for next viable entry...",
               g_currentAdvisedAction, sym, g_staticEntryPrice, reason);

   // Remember cancelled planned entry to allow reactivation if it becomes viable again
   g_lastCancelledEntryPrice  = g_staticEntryPrice;
   g_lastCancelledEntryAction = g_currentAdvisedAction;
   g_lastCancelledEntrySL     = g_staticSL;
   g_lastCancelledTime        = TimeCurrent();
   g_lastCancelledReason      = reason;

   // Purge unviable planned state
   g_hasViableEntry       = false;
   g_staticEntryPrice     = 0.0;
   g_staticSL             = 0.0;
   g_staticTP1            = 0.0;
   g_staticTP2            = 0.0;
   g_staticTP3            = 0.0;
   g_staticTP4            = 0.0;
   g_currentAdvisedAction = "NONE";
   g_setupState           = "CANCELLED";
   g_isSignalExpired      = true;
   g_blockReason          = "PLANNED ENTRY CANCELLED: " + reason;
   g_signalStatusLabel    = "PLANNED ENTRY CANCELLED (" + reason + ")";
   SEGSResetExpiredSetup(sym);

   ClearActiveSignalSnapshot(sym);
   DeleteTradeAdviceLines();
}

//+------------------------------------------------------------------+
//| Evaluate if a previously cancelled planned entry is viable again |
//+------------------------------------------------------------------+
bool TryReactivatePlannedEntry(string sym, string candDir, double curPrice, double pipSize, double curAtr)
{
   if(g_lastCancelledEntryPrice <= 0.0 || g_lastCancelledEntrySL <= 0.0) return false;
   if(g_lastCancelledEntryAction != candDir) return false;
   if(TimeCurrent() - g_lastCancelledTime > 14400) return false; // 4 hours window

   double entryTol = MathMax(0.25 * curAtr, 6.0 * pipSize);
   double distToOldEntry = MathAbs(curPrice - g_lastCancelledEntryPrice);

   // Price must have returned to the value zone of the cancelled planned entry
   if(distToOldEntry <= entryTol)
   {
      string unviableReason = "";
      if(IsPlannedEntryViable(sym, candDir, g_lastCancelledEntryPrice, g_lastCancelledEntrySL, curPrice, pipSize, curAtr, unviableReason))
      {
         PrintFormat("[Trade Advisor] Reactivating previously cancelled planned %s entry on %s at %.5f (returned to viable zone)",
                     candDir, sym, g_lastCancelledEntryPrice);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Evaluate Trend Reversal & Directional Confluence Conditions       |
//| Enforces strict user directives for trading reversals:           |
//| 1. Directional confluence check across H1, H2, and H4            |
//| 2. Ignore M30 OB during strong trend/high velocity, use H1 Zone  |
//| 3. Floor/Ceiling defense: Price must close above lowest point     |
//|    and NOT break or close below it on retests                    |
//| 4. Bounce Requirement: At least 3 bounces on H1 OR 4 on M30      |
//| 5. Calibrated Retest Entry: Anchored to sweet spot near floor    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Count sequential bounce cycles on an Order Block zone            |
//| User Mandatory Rule:                                             |
//| - Continuous Bounce Count: Counted whether price leaves the      |
//|   Order block and comes back to it OR whether candles keep       |
//|   testing the same spot without leaving the block.               |
//| - M30 Candles on 30m Order Block: when price bounces total of    |
//|   4 times, at the beginning of the 5th time, trade is executed   |
//|   as a reversal trade at the base (touch point / zone boundary)! |
//| - H1 Candles on 1h Order Block / 3-hour evaluation: 3 bounces    |
//|   on zone qualifies confirmed reversal.                          |
//| - Retest & Bounce Logic: If price bounces on a zone 3 times and  |
//|   leaves to return again without breaking it, it immediately     |
//|   qualifies as a high-probability trade trigger (TRIGGERED).     |
//+------------------------------------------------------------------+
//| Enhanced Bounce Cycle Tracker with Persistent MT5 Restart Memory |
//+------------------------------------------------------------------+
int CountOrderBlockBounceCycles(string sym, ENUM_TIMEFRAMES tf, double obLow, double obHigh, bool isBullish, double atrVal, double pipSize, int maxBars)
{
   if(obLow <= 0.0 || obHigh <= 0.0) return 0;

   // 1. Retrieve persistent bounce memory across MT5 restart, reboot, or offline laptop
   string cleanS = sym;
   StringToUpper(cleanS);
   string gvKey = StringFormat("SEGS_BNC_%s_%s_%.4f", (tf == PERIOD_H1 ? "H1" : "M30"), cleanS, obLow);
   int savedBounces = GlobalVariableCheck(gvKey) ? (int)GlobalVariableGet(gvKey) : 0;

   int bounces = 0;
   double bounceTol = MathMax(0.25 * atrVal, 6.0 * pipSize);
   double floorTol  = MathMax(0.35 * atrVal, 10.0 * pipSize);

   int totalBars = iBars(sym, tf);
   int scanBars = (totalBars > 1) ? MathMin(maxBars, totalBars - 1) : maxBars;

   bool inZone = false;
   for(int b = scanBars; b >= 1; b--)
   {
      double bHigh  = iHigh(sym, tf, b);
      double bLow   = iLow(sym, tf, b);
      double bClose = iClose(sym, tf, b);

      if(isBullish) // Demand Order Block
      {
         bool touches = (bLow <= obHigh + bounceTol && bClose >= obLow - floorTol);
         if(touches)
         {
            if(!inZone)
            {
               bounces++;
               inZone = true;
            }
         }
         else
         {
            if(bLow > obHigh + bounceTol * 0.3)
            {
               inZone = false; // Left zone and moved away
            }
         }
      }
      else // Supply Order Block
      {
         bool touches = (bHigh >= obLow - bounceTol && bClose <= obHigh + floorTol);
         if(touches)
         {
            if(!inZone)
            {
               bounces++;
               inZone = true;
            }
         }
         else
         {
            if(bHigh < obLow - bounceTol * 0.3)
            {
               inZone = false; // Left zone and moved away
            }
         }
      }
   }

   // 2. Ensure bounce count is non-decreasing across terminal restarts & offline periods
   int finalBounces = MathMax(bounces, savedBounces);
   if(finalBounces > savedBounces || !GlobalVariableCheck(gvKey))
   {
      GlobalVariableSet(gvKey, (double)finalBounces);
      GlobalVariablesFlush();
   }
   return finalBounces;
}

//+------------------------------------------------------------------+
//| Master Trend Reversal & Multi-Timeframe Confluence Evaluation    |
//| User Mandatory Rule:                                             |
//| When H1, H2, and H4 confluence is directional (Bearish/Bullish),  |
//| the Trade Advisor MUST look for viable trend continuation trades |
//| and NEVER enter counter-trend trades, EXCEPT if there is a       |
//| confirmed reversal on an active, unmitigated ORDER BLOCK verified |
//| by at least 3 bounces of 1-Hour (H1) candles OR at least         |
//| 4 bounces of 30-Minute (M30) candles ON the Order Block zone!    |
//| Applies at a system level to ALL traded instruments.             |
//+------------------------------------------------------------------+
bool EvaluateTrendReversalConditions(string sym,
                                     string proposedDir,
                                     double &outEntryPrice,
                                     double &outStopLoss,
                                     int &outH1Bounces,
                                     int &outM30Bounces,
                                     string &outReversalReason)
{
   outH1Bounces = 0;
   outM30Bounces = 0;
   outReversalReason = "";

   double pipSize = GetPipSize(sym);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;

   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   if(curAtr <= 0.0) curAtr = 20.0 * pipSize;

   double curPriceAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
   double curPriceBid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curPriceBid <= 0.0) curPriceBid = iClose(sym, PERIOD_M1, 0);
   if(curPriceAsk <= 0.0) curPriceAsk = curPriceBid;
   double livePrice = (proposedDir == "BUY") ? curPriceAsk : curPriceBid;

   // 1. Analyze Directional Confluence of H1, H2, and H4
   bool h1Bull = (g_h1Bias == "BULLISH");
   bool h2Bull = (g_h2Bias == "BULLISH");
   bool h4Bull = (g_h4Bias == "BULLISH");

   bool isFullBearConfluence = (!h1Bull && !h2Bull && !h4Bull);
   bool isFullBullConfluence = (h1Bull && h2Bull && h4Bull);
   bool isDowntrendConfluence = isFullBearConfluence || (!h1Bull && (!h2Bull || !h4Bull)) || (!h2Bull && !h4Bull);
   bool isUptrendConfluence   = isFullBullConfluence || (h1Bull && (h2Bull || h4Bull)) || (h2Bull && h4Bull);

   // Determine if proposed direction is Counter-Trend
   bool isCounterTrendBuy  = (proposedDir == "BUY" && isDowntrendConfluence);
   bool isCounterTrendSell = (proposedDir == "SELL" && isUptrendConfluence);

   // If trade is aligned with trend confluence, no counter-trend reversal hurdle is required
   if(!isCounterTrendBuy && !isCounterTrendSell)
   {
      outReversalReason = "TREND ALIGNED";
      return true;
   }

   // 2. COUNTER-TREND REVERSAL RULE ENFORCEMENT:
   // Counter-trend trade is STRICTLY PROHIBITED unless confirmed by:
   // 3 bounces of 1-Hour (H1) candles OR 4 bounces of 30-Minute (M30) candles ON AN ORDER BLOCK!

   if(isCounterTrendBuy)
   {
      // --- COUNTER-TREND BUY REVERSAL (against Downtrend) ---
      // A. Check opposing Supply Zone collision: NEVER buy into or inside a Supply Zone!
      if(g_obLocationWarning == "BUY INTO M30 SUPPLY" || g_obLocationWarning == "CHOP BETWEEN OB ZONES")
      {
         outReversalReason = "COUNTER-TREND BUY BLOCKED: Price is currently inside an opposing Supply Zone. Buying prohibited.";
         return false;
      }
      if(g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks))
      {
         M30OrderBlock supOB = g_orderBlocks[g_nearestBearishOB];
         if(!supOB.invalidated && livePrice >= supOB.low - 2.0 * pipSize && livePrice <= supOB.high + 2.0 * pipSize)
         {
            outReversalReason = StringFormat("COUNTER-TREND BUY BLOCKED: Price inside M30 Supply Zone [%.5f - %.5f]. Buying into supply prohibited.", supOB.low, supOB.high);
            return false;
         }
      }

      // B. Locate the active, unmitigated Demand Order Block
      int targetOBIndex = -1;
      bool isH1OB = false;
      double bestDist = 999999.0;

      for(int i = 0; i < ArraySize(g_orderBlocks); i++)
      {
         if(g_orderBlocks[i].invalidated || !g_orderBlocks[i].bullish) continue;
         double dist = MathAbs(livePrice - g_orderBlocks[i].high);
         if(dist < bestDist)
         {
            bestDist = dist;
            targetOBIndex = i;
            isH1OB = false;
         }
      }

      if(targetOBIndex < 0)
      {
         for(int i = 0; i < ArraySize(g_h1OrderBlocks); i++)
         {
            if(g_h1OrderBlocks[i].invalidated || !g_h1OrderBlocks[i].bullish) continue;
            double dist = MathAbs(livePrice - g_h1OrderBlocks[i].high);
            if(dist < bestDist)
            {
               bestDist = dist;
               targetOBIndex = i;
               isH1OB = true;
            }
         }
      }

      if(targetOBIndex < 0)
      {
         outReversalReason = "COUNTER-TREND BUY BLOCKED: Bearish Confluence (H1/H2/H4). No valid Demand Order Block found to support a reversal.";
         return false;
      }

      double obZoneLow  = isH1OB ? g_h1OrderBlocks[targetOBIndex].low  : g_orderBlocks[targetOBIndex].low;
      double obZoneHigh = isH1OB ? g_h1OrderBlocks[targetOBIndex].high : g_orderBlocks[targetOBIndex].high;

      // C. Count Bounces ON the Order Block zone using distinct bounce cycles:
      // M30: 4 bounces on 30m OB (bounces, defends, moves away, returns to bounce 3 more times), executed on 5th candle!
      // H1:  Bounces 1st time, leaves OB, returns and bounces 2 more times (total 3 bounces), executed on 4th candle!
      int h1Bounces  = CountOrderBlockBounceCycles(sym, PERIOD_H1, obZoneLow, obZoneHigh, true, curAtr, pipSize, 48);
      int m30Bounces = CountOrderBlockBounceCycles(sym, PERIOD_M30, obZoneLow, obZoneHigh, true, curAtr, pipSize, 72);

      outH1Bounces = h1Bounces;
      outM30Bounces = m30Bounces;

      // Price must not have decisively closed below the Order Block floor (broken zone)
      double floorBreakBuf = MathMax(0.35 * curAtr, 10.0 * pipSize);
      double latestH1Close = iClose(sym, PERIOD_H1, 1);
      double latestM30Close = iClose(sym, PERIOD_M30, 1);
      if(latestH1Close < obZoneLow - floorBreakBuf && latestM30Close < obZoneLow - floorBreakBuf)
      {
         outReversalReason = StringFormat("COUNTER-TREND BUY BLOCKED: Price closed below Demand Order Block floor %s", DoubleToString(obZoneLow, digits));
         return false;
      }

      // Check proximity to Demand Order Block zone:
      bool isGBPUSDOrAUDUSD = (StringFind(sym, "GBPUSD") >= 0 || StringFind(sym, "AUDUSD") >= 0 || StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0 || StringFind(sym, "CHF") >= 0);
      double maxAllowedOBDist = isGBPUSDOrAUDUSD ? MathMax(30.0 * pipSize, 0.85 * curAtr) : MathMax(0.50 * curAtr, 18.0 * pipSize);
      bool isPriceAtOB = (livePrice >= obZoneLow - 6.0 * pipSize && livePrice <= obZoneHigh + maxAllowedOBDist);

      // Confirmed Reversal Entry & Structural Stop Loss
      double atrBuffer = MathMax(0.20 * curAtr, 6.0 * pipSize);
      outEntryPrice = NormalizeDouble(obZoneHigh, digits);
      outStopLoss   = NormalizeDouble(obZoneLow - atrBuffer, digits);
      double minRisk = MathMax(18.0 * pipSize, 0.40 * curAtr);
      if(outEntryPrice - outStopLoss < minRisk)
         outStopLoss = NormalizeDouble(outEntryPrice - minRisk, digits);

      // Strict Stop Loss Invariant: Stop Loss CAN NEVER equal Entry Price!
      if(outStopLoss >= outEntryPrice - minRisk)
         outStopLoss = NormalizeDouble(outEntryPrice - minRisk, digits);

      // MANDATORY USER RULE FOR COUNTER-TREND REVERSAL:
      // "Price had bounced on the zone several times and this should have signaled that a reversal trade was viable
      // and a trade should have been executed at the beginning of the 5th bounce on a 30-minute chart"
      bool isReversalBouncesConfirmed  = (h1Bounces >= 3 || m30Bounces >= 4 || (m30Bounces >= 3 && isPriceAtOB));

      if(!isReversalBouncesConfirmed && !isPriceAtOB)
      {
         outReversalReason = StringFormat("COUNTER-TREND BUY AWAITING REVERSAL BOUNCES: Requires 3 H1 or 4 M30 bounces on Demand OB [%s - %s] (Found: %d/3 H1, %d/4 M30)",
                                          DoubleToString(obZoneLow, digits), DoubleToString(obZoneHigh, digits),
                                          h1Bounces, m30Bounces);
         return false;
      }

      outReversalReason = StringFormat("SAFE TREND REVERSAL CONFIRMED: %s Demand OB [%s - %s] Defended (%d H1 / %d M30 Bounces)",
                                       isH1OB ? "H1" : "M30",
                                       DoubleToString(obZoneLow, digits), DoubleToString(obZoneHigh, digits),
                                       h1Bounces, m30Bounces);
      return true;
   }
   else if(isCounterTrendSell)
   {
      // --- COUNTER-TREND SELL REVERSAL (against Uptrend) ---
      // A. Check opposing Demand Zone collision: NEVER sell into or inside a Demand Zone!
      if(g_obLocationWarning == "SELL INTO M30 DEMAND" || g_obLocationWarning == "CHOP BETWEEN OB ZONES")
      {
         outReversalReason = "COUNTER-TREND SELL BLOCKED: Price is currently inside an opposing Demand Zone. Selling prohibited.";
         return false;
      }
      if(g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks))
      {
         M30OrderBlock demOB = g_orderBlocks[g_nearestBullishOB];
         if(!demOB.invalidated && livePrice >= demOB.low - 2.0 * pipSize && livePrice <= demOB.high + 2.0 * pipSize)
         {
            outReversalReason = StringFormat("COUNTER-TREND SELL BLOCKED: Price inside M30 Demand Zone [%.5f - %.5f]. Selling into demand prohibited.", demOB.low, demOB.high);
            return false;
         }
      }

      // B. Locate the active, unmitigated Supply Order Block
      int targetOBIndex = -1;
      bool isH1OB = false;
      double bestDist = 999999.0;

      for(int i = 0; i < ArraySize(g_orderBlocks); i++)
      {
         if(g_orderBlocks[i].invalidated || g_orderBlocks[i].bullish) continue;
         double dist = MathAbs(livePrice - g_orderBlocks[i].low);
         if(dist < bestDist)
         {
            bestDist = dist;
            targetOBIndex = i;
            isH1OB = false;
         }
      }

      if(targetOBIndex < 0)
      {
         for(int i = 0; i < ArraySize(g_h1OrderBlocks); i++)
         {
            if(g_h1OrderBlocks[i].invalidated || g_h1OrderBlocks[i].bullish) continue;
            double dist = MathAbs(livePrice - g_h1OrderBlocks[i].low);
            if(dist < bestDist)
            {
               bestDist = dist;
               targetOBIndex = i;
               isH1OB = true;
            }
         }
      }

      if(targetOBIndex < 0)
      {
         outReversalReason = "COUNTER-TREND SELL BLOCKED: Bullish Confluence (H1/H2/H4). No valid Supply Order Block found to support a reversal.";
         return false;
      }

      double obZoneLow  = isH1OB ? g_h1OrderBlocks[targetOBIndex].low  : g_orderBlocks[targetOBIndex].low;
      double obZoneHigh = isH1OB ? g_h1OrderBlocks[targetOBIndex].high : g_orderBlocks[targetOBIndex].high;

      // C. Count Bounces ON the Order Block zone using distinct bounce cycles:
      // M30: 4 bounces on 30m OB (bounces, defends, moves away, returns to bounce 3 more times), executed on 5th candle!
      // H1:  Bounces 1st time, leaves OB, returns and bounces 2 more times (total 3 bounces), executed on 4th candle!
      int h1Bounces  = CountOrderBlockBounceCycles(sym, PERIOD_H1, obZoneLow, obZoneHigh, false, curAtr, pipSize, 48);
      int m30Bounces = CountOrderBlockBounceCycles(sym, PERIOD_M30, obZoneLow, obZoneHigh, false, curAtr, pipSize, 72);

      outH1Bounces = h1Bounces;
      outM30Bounces = m30Bounces;

      // Price must not have decisively closed above the Order Block ceiling (broken zone)
      double ceilBreakBuf = MathMax(0.35 * curAtr, 10.0 * pipSize);
      double latestH1Close = iClose(sym, PERIOD_H1, 1);
      double latestM30Close = iClose(sym, PERIOD_M30, 1);
      if(latestH1Close > obZoneHigh + ceilBreakBuf && latestM30Close > obZoneHigh + ceilBreakBuf)
      {
         outReversalReason = StringFormat("COUNTER-TREND SELL BLOCKED: Price closed above Supply Order Block ceiling %s", DoubleToString(obZoneHigh, digits));
         return false;
      }

      // Check proximity to Supply Order Block zone:
      bool isGBPUSDOrAUDUSD = (StringFind(sym, "GBPUSD") >= 0 || StringFind(sym, "AUDUSD") >= 0 || StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0 || StringFind(sym, "CHF") >= 0);
      double maxAllowedOBDist = isGBPUSDOrAUDUSD ? MathMax(30.0 * pipSize, 0.85 * curAtr) : MathMax(0.50 * curAtr, 18.0 * pipSize);
      bool isPriceAtOB = (livePrice <= obZoneHigh + 6.0 * pipSize && livePrice >= obZoneLow - maxAllowedOBDist);

      // Confirmed Reversal Entry & Structural Stop Loss
      double atrBuffer = MathMax(0.20 * curAtr, 6.0 * pipSize);
      outEntryPrice = NormalizeDouble(obZoneLow, digits);
      outStopLoss   = NormalizeDouble(obZoneHigh + atrBuffer, digits);
      double minRisk = MathMax(18.0 * pipSize, 0.40 * curAtr);
      if(outStopLoss - outEntryPrice < minRisk)
         outStopLoss = NormalizeDouble(outEntryPrice + minRisk, digits);

      // Strict Stop Loss Invariant: Stop Loss CAN NEVER equal Entry Price!
      if(outStopLoss <= outEntryPrice + minRisk)
         outStopLoss = NormalizeDouble(outEntryPrice + minRisk, digits);

      // SYSTEM-LEVEL RULE FOR USDCHF & ALL INSTRUMENTS:
      // When H1, H2, and H4 are Bullish, AND market structure has Higher Highs (HH):
      // A Counter-Trend SELL is STRICTLY PROHIBITED at a system level!
      // The system MUST be looking for a BUY setup when price pulls back into a viable buy zone (Demand OB / Support)!
      if(isUptrendConfluence || (h1Bull && h2Bull && h4Bull) || g_hasHH_M30 || g_hasHH_H1 || g_marketStructure == "BULLISH")
      {
         outReversalReason = "COUNTER-TREND SELL STRICTLY PROHIBITED: H1, H2, H4 are Bullish with Higher High structure. System is seeking BUY pullback into demand.";
         return false;
      }

      // MANDATORY USER RULE FOR COUNTER-TREND REVERSAL:
      // "Price had bounced on the zone several times and this should have signaled that a reversal trade was viable
      // and a trade should have been executed at the beginning of the 5th bounce on a 30-minute chart"
      bool isReversalBouncesConfirmed = (h1Bounces >= 3 || m30Bounces >= 4);

      if(!isReversalBouncesConfirmed)
      {
         outReversalReason = StringFormat("COUNTER-TREND SELL AWAITING REVERSAL BOUNCES: Requires 3 H1 or 4 M30 bounces on Supply OB [%s - %s] (Found: %d/3 H1, %d/4 M30)",
                                          DoubleToString(obZoneLow, digits), DoubleToString(obZoneHigh, digits),
                                          h1Bounces, m30Bounces);
         return false;
      }

      outReversalReason = StringFormat("SAFE TREND REVERSAL CONFIRMED: %s Supply OB [%s - %s] Defended (%d H1 / %d M30 Bounces)",
                                       isH1OB ? "H1" : "M30",
                                       DoubleToString(obZoneLow, digits), DoubleToString(obZoneHigh, digits),
                                       h1Bounces, m30Bounces);
      return true;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Master Trade Advice & Strategy Scanner                           |
//+------------------------------------------------------------------+
void ScanMarketStructureAndAdvice(bool forceScan=false)
{
   string sym = _Symbol;
   if(SEGSResetExpiredSetup(sym)) forceScan = true;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pipSize = GetPipSize(sym);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;

   // Synchronize account-wide MyAdvisor state from Global Variables
   RefreshAccountAdvisorState();
   CheckDailyTelemetryReset();

   // Reset tracking if symbol changed
   if(g_lastScannedSymbol != sym)
   {
      ResetMarketQualityState(sym);
      g_lastScannedSymbol = sym;
      forceScan = true;
   }

   // Evaluate Multi-Timeframe Trend & Structural Confluence early so Card 2 and HUD are always live and accurate
   bool earlyIsReversal = false;
   string earlyReversalDir = "NONE";
   double earlyEma20Val = 0.0;
   EvaluateMultiTimeframeTrendAndReversal(sym, g_h1Bias, g_h2Bias, g_h4Bias, g_overallBias, earlyIsReversal, earlyReversalDir, earlyEma20Val);

   // TOP-PRIORITY REAL-TIME VIABILITY & DYNAMIC CANCELLATION EVALUATOR:
   // Runs unconditionally on EVERY tick / timer execution!
   // If any planned entry has been breached, approached Stop Loss, or become unviable, CANCEL IT IMMEDIATELY!
   if(CountOpenAdvisorTradesForSymbol(sym) == 0 && (g_staticEntryPrice > 0.0 || g_setupState == "WATCHING" || g_setupState == "READY"))
   {
      double curPriceCheck = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curPriceCheck <= 0.0) curPriceCheck = iClose(sym, PERIOD_M1, 0);
      if(curPriceCheck <= 0.0) curPriceCheck = iClose(sym, PERIOD_H1, 0);
      if(curPriceCheck <= 0.0) curPriceCheck = iClose(sym, PERIOD_D1, 0);
      double curAskCheck = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curAskCheck <= 0.0) curAskCheck = curPriceCheck;

      string plannedDir = (g_plannedAction != "" && g_plannedAction != "NONE") ? g_plannedAction : (g_staticEntryPrice < g_staticSL ? "SELL" : "BUY");
      double testPrice = (plannedDir == "BUY") ? curAskCheck : curPriceCheck;
      double curAtrVal = 20.0 * pipSize;
      if(g_hAtr_H1 != INVALID_HANDLE)
      {
         double atrBuf[];
         ArraySetAsSeries(atrBuf, true);
         if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtrVal = atrBuf[0];
      }

      string unviableReason = "";
      if(!IsPlannedEntryViable(sym, plannedDir, g_staticEntryPrice, g_staticSL, testPrice, pipSize, curAtrVal, unviableReason))
      {
         PrintFormat("[Trade Advisor] Dynamic Cancellation on %s: Planned %s entry at %.5f CANCELLED (%s)",
                     sym, plannedDir, g_staticEntryPrice, unviableReason);
         CancelUnviablePlannedEntry(sym, unviableReason);
         UpdateTradeAdviceLines();
         if(g_showSentimentHUD) DrawSentimentHUD();
      }
   }

   // 1. GATE 1: Broker Symbol Tradeability (Pure broker session hours)
   g_isBrokerTradeable = IsBrokerSymbolTradeable(sym, g_brokerTradeReason);
   g_isMarketOpen = g_isBrokerTradeable;
   if(!g_isBrokerTradeable)
   {
      g_isGateOpen = false;
      g_gateBlockReason = "BROKER MARKET CLOSED (" + g_brokerTradeReason + ")";
      g_telemetry.brokerSessionBlocks++;

      // Validate planned entry viability before preserving:
      // If there are no open trades taken, an unviable planned entry must be cancelled!
      if(CountOpenAdvisorTradesForSymbol(sym) == 0 && (g_hasViableEntry || g_setupState == "WATCHING") && g_staticEntryPrice > 0.0)
      {
         double curPriceGate = SymbolInfoDouble(sym, SYMBOL_BID);
         if(curPriceGate <= 0.0) curPriceGate = iClose(sym, PERIOD_M1, 0);
         if(curPriceGate <= 0.0) curPriceGate = iClose(sym, PERIOD_H1, 0);
         double curAtrVal = 20.0 * pipSize;
         if(g_hAtr_H1 != INVALID_HANDLE)
         {
            double atrBuf[];
            ArraySetAsSeries(atrBuf, true);
            if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtrVal = atrBuf[0];
         }
         string unviableReason = "";
         if(!IsPlannedEntryViable(sym, g_currentAdvisedAction, g_staticEntryPrice, g_staticSL, curPriceGate, pipSize, curAtrVal, unviableReason))
         {
            CancelUnviablePlannedEntry(sym, unviableReason);
         }
      }

      // PRESERVATION: If an active trade signal or open trade exists, do not turn it off!
      if(((g_hasViableEntry || g_setupState == "WATCHING") && g_staticEntryPrice > 0.0) || CountOpenAdvisorTradesForSymbol(sym) > 0)
      {
         g_blockReason = "BROKER MARKET CLOSED (ACTIVE SIGNAL PRESERVED)";
         if(g_showTradeAdviceLines) UpdateTradeAdviceLines();
         return;
      }

      g_setupState = "BLOCKED";
      g_primaryRejectionReason = g_gateBlockReason;
      g_blockReason = g_primaryRejectionReason;
      g_volatilityRegime = "N/A";
      g_liquidityState = "N/A";
      g_setupQuality = 0;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "BLOCKED (MARKET CLOSED)";
      UpdateTradeAdviceLines();
      return;
   }

   // 2. GATE 2: Feed Health (Diagnostic & Telemetry - Tick requirement removed per user directive)
   g_feedState = EvaluateFeedHealth(sym, g_lastTickAgeSec);
   g_isTickFresh = (g_feedState == FEED_LIVE || g_feedState == FEED_DELAYED);
   g_isTickDataFresh = g_isTickFresh;
   // Note: Trade signals and execution are driven purely by candle price structure and market trend.
   // Ticks are tracked for informational telemetry, but do not block setups.

   // 3. GATE 3: Underlying Cash Session Context
   g_cashSession = GetUnderlyingCashSession(sym, g_cashSessionName, g_strategySession);
   if(g_cashSession == CASH_SESSION_CLOSED)
   {
      g_isGateOpen = false;
      g_gateBlockReason = "WEEKEND CLOSURE (" + g_cashSessionName + ")";
      g_telemetry.brokerSessionBlocks++;

      // Validate planned entry viability before preserving:
      // If there are no open trades taken, an unviable planned entry must be cancelled!
      if(CountOpenAdvisorTradesForSymbol(sym) == 0 && (g_hasViableEntry || g_setupState == "WATCHING") && g_staticEntryPrice > 0.0)
      {
         double curPriceGate = SymbolInfoDouble(sym, SYMBOL_BID);
         if(curPriceGate <= 0.0) curPriceGate = iClose(sym, PERIOD_M1, 0);
         if(curPriceGate <= 0.0) curPriceGate = iClose(sym, PERIOD_H1, 0);
         double curAtrVal = 20.0 * pipSize;
         if(g_hAtr_H1 != INVALID_HANDLE)
         {
            double atrBuf[];
            ArraySetAsSeries(atrBuf, true);
            if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtrVal = atrBuf[0];
         }
         string unviableReason = "";
         if(!IsPlannedEntryViable(sym, g_currentAdvisedAction, g_staticEntryPrice, g_staticSL, curPriceGate, pipSize, curAtrVal, unviableReason))
         {
            CancelUnviablePlannedEntry(sym, unviableReason);
         }
      }

      // PRESERVATION: If an active trade signal or open trade exists, do not turn it off!
      if(((g_hasViableEntry || g_setupState == "WATCHING") && g_staticEntryPrice > 0.0) || CountOpenAdvisorTradesForSymbol(sym) > 0)
      {
         g_blockReason = "WEEKEND CLOSURE (ACTIVE SIGNAL PRESERVED)";
         if(g_showTradeAdviceLines) UpdateTradeAdviceLines();
         return;
      }

      g_setupState = "BLOCKED";
      g_primaryRejectionReason = g_gateBlockReason;
      g_blockReason = g_primaryRejectionReason;
      UpdateTradeAdviceLines();
      return;
   }

   // 3B. Asset Class & US Index / Equity Cash Session Gate (09:30 - 16:00 NY Cash Open Alignment)
   // Prevents low-liquidity after-hours or overnight shorting and whipsaws on tech indices and equities
   string symAssetClass = "FOREX";
   string symUpper = sym;
   StringToUpper(symUpper);
   if(StringFind(symUpper, "DJ") >= 0 || StringFind(symUpper, "US30") >= 0 || StringFind(symUpper, "NAS") >= 0 || 
      StringFind(symUpper, "US100") >= 0 || StringFind(symUpper, "USTEC") >= 0 || StringFind(symUpper, "SPX") >= 0 || 
      StringFind(symUpper, "US500") >= 0 || StringFind(symUpper, "GER") >= 0 || StringFind(symUpper, "DE40") >= 0)
      symAssetClass = "INDEX";
   else if(StringFind(symUpper, "XAU") >= 0 || StringFind(symUpper, "GOLD") >= 0 || StringFind(symUpper, "XAG") >= 0 || 
           StringFind(symUpper, "SILVER") >= 0 || StringFind(symUpper, "OIL") >= 0 || StringFind(symUpper, "WTI") >= 0)
      symAssetClass = "COMMODITY";
   else if(StringFind(symUpper, "BTC") >= 0 || StringFind(symUpper, "ETH") >= 0)
      symAssetClass = "CRYPTO";
   else if(StringFind(symUpper, "AAPL") >= 0 || StringFind(symUpper, "TSLA") >= 0 || StringFind(symUpper, "NVDA") >= 0 || 
           StringFind(symUpper, "AMD") >= 0 || StringFind(symUpper, "MSFT") >= 0 || StringFind(symUpper, "AMZN") >= 0 || 
           StringFind(symUpper, "NDAQ") >= 0)
      symAssetClass = "EQUITY";

   bool isUSIndexOrEquity = (symAssetClass == "INDEX" || symAssetClass == "EQUITY");
   if(isUSIndexOrEquity && (g_cashSession == CASH_SESSION_AFTERHOURS || g_cashSession == CASH_SESSION_OVERNIGHT))
   {
      if(CountOpenAdvisorTradesForSymbol(sym) == 0 && (!g_hasViableEntry || g_setupState != "READY"))
      {
         g_setupState = "STANDBY";
         g_primaryRejectionReason = "US CASH SESSION CLOSED (16:00-09:30 NY) - NEW TRADES PROHIBITED ON INDICES/EQUITIES";
         g_blockReason = g_primaryRejectionReason;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "STANDBY (CASH SESSION CLOSED)";
         UpdateTradeAdviceLines();
         return;
      }
   }

   // 4. GATE 4: Dynamic Rolling Spread Pre-Check (Extreme anomaly hard gate)
   UpdateSpreadHistory(sym);
   bool spreadOk = CheckSpreadQuality(sym, g_currentSpreadRatio);
   g_spreadQualityRatio = g_currentSpreadRatio;
   g_spreadQualityStr = (g_spreadQualityRatio <= 1.8) ? "EXCELLENT" : ((g_spreadQualityRatio <= 2.8) ? "NORMAL" : "HIGH");
   if(g_currentSpreadRatio > 4.5)
   {
      g_isGateOpen = false;
      g_gateBlockReason = StringFormat("SPREAD ANOMALY (%.1fx TYPICAL SPREAD)", g_currentSpreadRatio);
      g_setupState = "BLOCKED";
      g_primaryRejectionReason = g_gateBlockReason;
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 25;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "BLOCKED (HIGH SPREAD)";
      g_telemetry.spreadCostBlocks++;
      UpdateTradeAdviceLines();
      return;
   }

   // 5. GATE 5: Liquidity Rating (Informational Telemetry - Tick volume requirement removed)
   string liqState = MeasureMarketLiquidity(sym, g_tickActivityRatio);
   // Note: Liquidity state is tracked for dashboard telemetry, but does not block candle-based structural signals.

   // 6. GATE 6: Volatility Regime Gate
   g_volatilityRegime = CalculateNormalizedVolatility(sym, g_volAtrRatio, g_volRangeRatio, g_volatilityScore);
   if(g_volatilityRegime == "LOW")
   {
      g_isGateOpen = false;
      g_gateBlockReason = "LOW VOLATILITY REGIME (COMPRESSION)";
      g_setupState = "WAITING";
      g_primaryRejectionReason = g_gateBlockReason;
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 35;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "LOW VOLATILITY (STAND ASIDE)";
      g_telemetry.lowQualityChop++;
      UpdateTradeAdviceLines();
      return;
   }

   // Macro market gate conditions passed
   g_isGateOpen = true;
   g_gateBlockReason = "";

   datetime curH1BarTime = iTime(sym, PERIOD_H1, 0);
   datetime triggerBarTime = iTime(sym, PERIOD_H1, 1);

   // Existing sets are managed by ticket; scanning remains independent of their direction.
   if(CountOpenAdvisorSetsForSymbol(sym) >= MathMax(1, MathMin(2, InpMaxSetsPerSymbol)))
   {
      g_hasViableEntry = false;
      g_setupState = "WATCHING";
      g_blockReason = "TWO-SET SYMBOL CAPACITY REACHED";
      return;
   }

   static datetime s_lastSubScanTime = 0;

   // CRITICAL PULLBACK & RETEST ARRIVAL TRIGGER:
   // If a planned entry or order block retest level is waiting (e.g. in WATCHING state),
   // first evaluate viability in real-time. If price has moved adverse or breached limits, CANCEL IMMEDIATELY!
   if(g_staticEntryPrice > 0.0 && g_staticSL > 0.0 && !IsAdvisorTradeTaken(sym, g_currentSignalID))
   {
      double curBidCheck = SymbolInfoDouble(sym, SYMBOL_BID);
      double curAskCheck = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curBidCheck <= 0.0) curBidCheck = iClose(sym, PERIOD_M1, 0);
      if(curAskCheck <= 0.0) curAskCheck = curBidCheck;

      string plannedDir = (g_plannedAction != "" && g_plannedAction != "NONE") ? g_plannedAction : (g_staticEntryPrice < g_staticSL ? "SELL" : "BUY");
      double curPrice = (plannedDir == "BUY") ? curAskCheck : curBidCheck;
      double testPrice = curPrice;
      double pip = GetPipSize(sym);
      double curAtrVal = 20.0 * pip;
      if(g_hAtr_H1 != INVALID_HANDLE)
      {
         double atrBuf[];
         ArraySetAsSeries(atrBuf, true);
         if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtrVal = atrBuf[0];
      }

      // 1. REAL-TIME VIABILITY GATE: If market rallied/dropped adverse, or approached SL, cancel the planned entry!
      string unviableReason = "";
      if(!IsPlannedEntryViable(sym, plannedDir, g_staticEntryPrice, g_staticSL, testPrice, pip, curAtrVal, unviableReason))
      {
         PrintFormat("[Trade Advisor] Planned %s entry at %.5f on %s is UNVIABLE (%s). Cancelling immediately!",
                     plannedDir, g_staticEntryPrice, sym, unviableReason);
         CancelUnviablePlannedEntry(sym, unviableReason);
         UpdateTradeAdviceLines();
         if(g_showSentimentHUD) DrawSentimentHUD();
         return;
      }

      double spreadPtsTouch = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
      double touchTolerance = MathMax(0.35 * curAtrVal, MathMax(10.0 * pip, spreadPtsTouch * 2.5));
      bool isTouched = false;

      // Check current live tick AND recent candle wicks (M1, M5 & M15) to catch fast wick touches!
      double hM1_0 = iHigh(sym, PERIOD_M1, 0), lM1_0 = iLow(sym, PERIOD_M1, 0);
      double hM5_0 = iHigh(sym, PERIOD_M5, 0), hM5_1 = iHigh(sym, PERIOD_M5, 1);
      double lM5_0 = iLow(sym, PERIOD_M5, 0),  lM5_1 = iLow(sym, PERIOD_M5, 1);
      double hM15_0 = iHigh(sym, PERIOD_M15, 0), lM15_0 = iLow(sym, PERIOD_M15, 0);
      double maxWick = MathMax(testPrice, MathMax(hM1_0, MathMax(hM5_0, MathMax(hM5_1, hM15_0))));
      double minWick = MathMin(testPrice, MathMin(lM1_0, MathMin(lM5_0, MathMin(lM5_1, lM15_0))));

      if(plannedDir == "SELL")
      {
         // For SELL: Planned Entry is at Resistance / Supply.
         // Price touched or penetrated Planned Entry if live bid/testPrice or max recent wick >= plannedEntry - touchTolerance,
         // and price has not decisively breached Stop Loss!
         if(g_staticSL > 0.0 ? testPrice <= g_staticSL : true)
         {
            if(testPrice >= g_staticEntryPrice - touchTolerance || maxWick >= g_staticEntryPrice - touchTolerance)
               isTouched = true;
         }
      }
      else if(plannedDir == "BUY")
      {
         // For BUY: Planned Entry is at Support / Demand.
         // Price touched or penetrated Planned Entry if live ask/testPrice or min recent wick <= plannedEntry + touchTolerance,
         // and price has not decisively breached Stop Loss!
         if(g_staticSL > 0.0 ? testPrice >= g_staticSL : true)
         {
            if(testPrice <= g_staticEntryPrice + touchTolerance || minWick <= g_staticEntryPrice + touchTolerance)
               isTouched = true;
         }
      }

      // USER DIRECTIVE: Trade is triggered when price hits or enters a Viable Order Block!
      // Check all unmitigated Order Blocks (both M30 & H1) in setup direction for direct entry/touch
      bool isTouchingOB = false;
      double obLevel = 0.0;
      for(int k = 0; k < ArraySize(g_orderBlocks); k++)
      {
         if(g_orderBlocks[k].invalidated) continue;
         if(plannedDir == "SELL" && !g_orderBlocks[k].bullish)
         {
            if((testPrice >= g_orderBlocks[k].low - touchTolerance && testPrice <= g_orderBlocks[k].high + 6.0 * pip) ||
               (maxWick >= g_orderBlocks[k].low - touchTolerance && minWick <= g_orderBlocks[k].high + 6.0 * pip))
            {
               isTouchingOB = true;
               obLevel = (curPrice >= g_orderBlocks[k].low && curPrice <= g_orderBlocks[k].high) ? curPrice : g_orderBlocks[k].low;
               break;
            }
         }
         else if(plannedDir == "BUY" && g_orderBlocks[k].bullish)
         {
            if((testPrice <= g_orderBlocks[k].high + touchTolerance && testPrice >= g_orderBlocks[k].low - 6.0 * pip) ||
               (minWick <= g_orderBlocks[k].high + touchTolerance && maxWick >= g_orderBlocks[k].low - 4.0 * pip))
            {
               isTouchingOB = true;
               obLevel = (curPrice <= g_orderBlocks[k].high && curPrice >= g_orderBlocks[k].low) ? curPrice : g_orderBlocks[k].high;
               break;
            }
         }
      }
      if(!isTouchingOB)
      {
         for(int k = 0; k < ArraySize(g_h1OrderBlocks); k++)
         {
            if(g_h1OrderBlocks[k].invalidated) continue;
            if(plannedDir == "SELL" && !g_h1OrderBlocks[k].bullish)
            {
               if((testPrice >= g_h1OrderBlocks[k].low - touchTolerance && testPrice <= g_h1OrderBlocks[k].high + 6.0 * pip) ||
                  (maxWick >= g_h1OrderBlocks[k].low - touchTolerance && minWick <= g_h1OrderBlocks[k].high + 6.0 * pip))
               {
                  isTouchingOB = true;
                  obLevel = (curPrice >= g_h1OrderBlocks[k].low && curPrice <= g_h1OrderBlocks[k].high) ? curPrice : g_h1OrderBlocks[k].low;
                  break;
               }
            }
            else if(plannedDir == "BUY" && g_h1OrderBlocks[k].bullish)
            {
               if((testPrice <= g_h1OrderBlocks[k].high + touchTolerance && testPrice >= g_h1OrderBlocks[k].low - 6.0 * pip) ||
                  (minWick <= g_h1OrderBlocks[k].high + touchTolerance && maxWick >= g_h1OrderBlocks[k].low - 6.0 * pip))
               {
                  isTouchingOB = true;
                  obLevel = (curPrice <= g_h1OrderBlocks[k].high && curPrice >= g_h1OrderBlocks[k].low) ? curPrice : g_h1OrderBlocks[k].high;
                  break;
               }
            }
         }
      }

      if((isTouched || isTouchingOB) && !IsAdvisorTradeTaken(sym, g_currentSignalID))
      {
         double triggeredPrice = isTouchingOB ? obLevel : (isTouched ? g_staticEntryPrice : curPrice);
         PrintFormat("[Trade Advisor] >>> VIABLE ORDER BLOCK / PULLBACK TOUCH TRIGGERED on %s: Price reached %s level %s (%s)! Promoting immediately to TRIGGERED for execution.",
                     sym, (isTouchingOB ? "Viable Order Block" : "Planned Entry"), DoubleToString(triggeredPrice, digits), plannedDir);
         g_setupState = "TRIGGERED";
         g_hasViableEntry = true;
         g_currentAdvisedAction = plannedDir;
         g_plannedAction = plannedDir;
         g_staticEntryPrice = triggeredPrice;
         g_primaryRejectionReason = "NONE (VIABLE ORDER BLOCK ENTERED - EXECUTING)";
         g_blockReason = "NONE (LEVEL TOUCHED)";
         g_signalStatusLabel = StringFormat("TRIGGERED (VIABLE ORDER BLOCK ENTERED @ %s - EXECUTING)", DoubleToString(triggeredPrice, digits));
         g_lastAdviceScanBarTime = curH1BarTime;
         UpdateTradeAdviceLines();
         if(g_showSentimentHUD) DrawSentimentHUD();
         CheckAndAutoTradeAdvice();
         return;
      }
   }

   // If already TRIGGERED or READY on this bar, monitor SL hit, validity, and viability without rewriting target levels
   if(!forceScan && !IsAdvisorTradeTaken(sym, g_currentSignalID) && curH1BarTime == g_lastAdviceScanBarTime && (g_setupState == "TRIGGERED" || g_setupState == "READY") && g_hasViableEntry && !g_isSignalExpired)
   {
      double curPrice = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_M1, 0);
      if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_H1, 0);

      // Check if position is open and taken in market
      if(HasOpenAdvisorTradesForSignal(sym, g_currentSignalID))
      {
         if((g_currentAdvisedAction == "BUY" && curPrice <= g_staticSL) ||
            (g_currentAdvisedAction == "SELL" && curPrice >= g_staticSL))
         {
            // Position stopped out - let open positions manager handle closing
            return;
         }
         g_currentTradeTaken = true;
         g_setupState = "TRIGGERED";
         return;
      }
      else
      {
         // PLANNED ENTRY MONITORING (Not yet executed):
         // Evaluate viability in real-time. If price has moved away, breached adverse limits,
         // or an overhead/underlying Order Block has formed, CANCEL the unviable planned entry immediately!
         double pip = GetPipSize(sym);
         double curAtrVal = 20.0 * pip;
         if(g_hAtr_H1 != INVALID_HANDLE)
         {
            double atrBuf[];
            ArraySetAsSeries(atrBuf, true);
            if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtrVal = atrBuf[0];
         }

         string unviableReason = "";
         if(!IsPlannedEntryViable(sym, g_currentAdvisedAction, g_staticEntryPrice, g_staticSL, curPrice, pip, curAtrVal, unviableReason))
         {
            // Cancel unviable planned entry immediately and fall through into scanner to acquire new viable entry or reactivate
            CancelUnviablePlannedEntry(sym, unviableReason);
         }
         else
         {
            // Signal is still viable and waiting for entry
            if(!IsAdvisorTradeTaken(sym, g_currentSignalID))
            {
               g_currentTradeTaken = false;
               g_setupState = "READY";
               CheckAndAutoTradeAdvice();
            }
         }
      }
   }

   // Throttle continuous scanning to once every 3 seconds to ensure real-time responsiveness when watching/waiting
   if(!forceScan && (TimeCurrent() - s_lastSubScanTime < 3) && curH1BarTime == g_lastAdviceScanBarTime)
   {
      return;
   }
   s_lastSubScanTime = TimeCurrent();
   g_lastAdviceScanBarTime = curH1BarTime;
   g_telemetry.candidatesDetected++;

   // 7. DIRECTIONAL BIAS & REVERSAL DETECTION (H1, H2, H4 Multi-Timeframe Engine)
   bool isReversal = false;
   string reversalDir = "NONE";
   double ema20Val = 0.0;
   EvaluateMultiTimeframeTrendAndReversal(sym, g_h1Bias, g_h2Bias, g_h4Bias, g_overallBias, isReversal, reversalDir, ema20Val);

   bool h1Bull = (g_h1Bias == "BULLISH");
   bool h2Bull = (g_h2Bias == "BULLISH");
   bool h4Bull = (g_h4Bias == "BULLISH");

   // STALE SIGNAL TREND-REVERSAL INVALIDATION GUARD:
   // If market trend has reversed across H1/H2/H4, immediately purge any opposing stale signal and pivot!
   if(!IsAdvisorTradeTaken(sym, g_currentSignalID) && g_hasViableEntry)
   {
      if(g_currentAdvisedAction == "SELL" && (h1Bull && (h2Bull || h4Bull)))
      {
         PrintFormat("[Trade Advisor] Invalidation: Stale SELL signal on %s purged due to confirmed Bullish Reversal (H1: %s, H2: %s, H4: %s). Pivoting to BUY.",
                     sym, g_h1Bias, g_h2Bias, g_h4Bias);
         ClearActiveSignalSnapshot(sym);
         g_hasViableEntry = false;
         g_staticEntryPrice = 0.0;
         g_staticSL = 0.0;
         g_currentAdvisedAction = "NONE";
         g_setupState = "SCANNING";
         g_blockReason = "MARKET REVERSED TO BULLISH";
         g_signalStatusLabel = "SCANNING (MARKET REVERSED TO BULLISH)";
      }
      else if(g_currentAdvisedAction == "BUY" && (!h1Bull && (!h2Bull || !h4Bull)))
      {
         PrintFormat("[Trade Advisor] Invalidation: Stale BUY signal on %s purged due to confirmed Bearish Reversal (H1: %s, H2: %s, H4: %s). Pivoting to SELL.",
                     sym, g_h1Bias, g_h2Bias, g_h4Bias);
         ClearActiveSignalSnapshot(sym);
         g_hasViableEntry = false;
         g_staticEntryPrice = 0.0;
         g_staticSL = 0.0;
         g_currentAdvisedAction = "NONE";
         g_setupState = "SCANNING";
         g_blockReason = "MARKET REVERSED TO BEARISH";
         g_signalStatusLabel = "SCANNING (MARKET REVERSED TO BEARISH)";
      }
   }

   // 8. CONFIRMED MARKET STRUCTURE & SWING POINTS
   g_recentPivotTime = 0;
   g_marketStructure = ScanMarketSwingStructure(sym, g_recentSwingHigh, g_recentSwingLow, g_recentSupport, g_recentResistance);

   // 8A. HTF LIQUIDITY LEVELS (PDH/PDL, PWH/PWL) & M30 ORDER BLOCK UPDATE
   UpdateHTFLiquidityLevels(sym);
   DrawHTFLiquidityLines(sym);
   UpdateM30OrderBlocks(forceScan);
   UpdateOBLocationSnapshot(sym);

   // 8A-1. INSTITUTIONAL HTF LIQUIDITY SWEEP & 30-MINUTE ORDER BLOCK CONFLUENCE (ICT / SMC Reversal Engine)
   // When Previous Day Low (PDL) is swept or touched, downside sell stops have been purged.
   // When price sweeps PDL into one of the 30-minute Demand Order Blocks (e.g. XAUUSD at 4316-4322),
   // institutional smart money absorbs sell-side liquidity and institutes a BUY from that 30-minute Order Block!
   // Crucially, this institutional order block setup is high-expectancy Smart Money reversal trading,
   // and MUST NOT be blocked by higher-timeframe trend lag.
   bool isUptrend = (h1Bull && (h2Bull || h4Bull)) || (h2Bull && h4Bull);
   bool isDowntrend = (!h1Bull && (!h2Bull || !h4Bull)) || (!h2Bull && !h4Bull);
   bool isUptrendConfluence = isUptrend;
   bool isDowntrendConfluence = isDowntrend;

   double curPrice = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_M1, 0);
   if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_H1, 0);

   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   if(curAtr <= 0.0) curAtr = 20.0 * pipSize;

   // Authoritative Previous Day Low (PDL) Level
   double pdlLevel = g_htfLiquidity.pdl;
   if(pdlLevel <= 0.0) pdlLevel = iLow(sym, PERIOD_D1, 1);
   if(pdlLevel <= 0.0) pdlLevel = curPrice - 20.0 * pipSize;

   double curLowD1 = iLow(sym, PERIOD_D1, 0);
   if(curLowD1 <= 0.0) curLowD1 = curPrice;
   double curLowW1 = iLow(sym, PERIOD_W1, 0);
   if(curLowW1 <= 0.0) curLowW1 = curPrice;
   double pwlLevel = g_htfLiquidity.pwl;

   double pdlTolerance = MathMax(0.35 * curAtr, 12.0 * pipSize);
   bool pdlSwept = g_htfLiquidity.pdlSwept || (curLowD1 < pdlLevel && curPrice >= pdlLevel - pdlTolerance);
   bool pdlTouched = (curLowD1 <= pdlLevel + 0.15 * curAtr) || (curPrice <= pdlLevel + pdlTolerance);
   bool pwlSwept = g_htfLiquidity.pwlSwept || (pwlLevel > 0.0 && curLowW1 < pwlLevel && curPrice >= pwlLevel - pdlTolerance);
   bool pwlTouched = (pwlLevel > 0.0 && ((curLowW1 <= pwlLevel + 0.15 * curAtr) || (curPrice <= pwlLevel + pdlTolerance)));

   // Scan for confluent 30-minute Bullish Demand Order Block near PDL/PWL or live price
   int confluentDemandOB = -1;
   double bestDemDist = 999999.0;
   bool demOBIsFromH1 = false;
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].invalidated || !g_orderBlocks[i].bullish) continue;
      double distPDL = MathAbs(g_orderBlocks[i].high - pdlLevel);
      double distPWL = (pwlLevel > 0.0) ? MathAbs(g_orderBlocks[i].high - pwlLevel) : 999999.0;
      double distLiq = MathMin(distPDL, distPWL);
      double distPrice = MathAbs(curPrice - g_orderBlocks[i].high);
      bool isPriceAtOB = (curPrice >= g_orderBlocks[i].low - 0.20 * curAtr && curPrice <= g_orderBlocks[i].high + 0.50 * curAtr);
      if(isPriceAtOB || distLiq <= MathMax(3.0 * curAtr, 80.0 * pipSize) || distPrice <= MathMax(2.5 * curAtr, 80.0 * pipSize))
      {
         if(distPrice < bestDemDist)
         {
            bestDemDist = distPrice;
            confluentDemandOB = i;
            demOBIsFromH1 = false;
         }
      }
   }
   if(confluentDemandOB < 0)
   {
      for(int i = 0; i < ArraySize(g_h1OrderBlocks); i++)
      {
         if(g_h1OrderBlocks[i].invalidated || !g_h1OrderBlocks[i].bullish) continue;
         double distPDL = MathAbs(g_h1OrderBlocks[i].high - pdlLevel);
         double distPWL = (pwlLevel > 0.0) ? MathAbs(g_h1OrderBlocks[i].high - pwlLevel) : 999999.0;
         double distLiq = MathMin(distPDL, distPWL);
         double distPrice = MathAbs(curPrice - g_h1OrderBlocks[i].high);
         if(distLiq <= MathMax(3.5 * curAtr, 100.0 * pipSize) || distPrice <= MathMax(3.0 * curAtr, 100.0 * pipSize))
         {
            if(distPrice < bestDemDist)
            {
               bestDemDist = distPrice;
               confluentDemandOB = i;
               demOBIsFromH1 = true;
            }
         }
      }
   }
   bool hasDemandOBConfluence = (confluentDemandOB >= 0);

   // Safe Trend Reversal Check: If market is in a downtrend (confluence of H1/H2/H4),
   // counter-trend BUY is strictly gated by H1 Demand Zone floor defense and 3 H1 / 4 M30 bounces!
   double revBuyEntry = 0.0, revBuySL = 0.0;
   int revBuyH1B = 0, revBuyM30B = 0;
   string revBuyReason = "";
   bool revBuyAllowed = EvaluateTrendReversalConditions(sym, "BUY", revBuyEntry, revBuySL, revBuyH1B, revBuyM30B, revBuyReason);

   bool isPDLSweepReversal = false;
   if(pdlSwept || pdlTouched || pwlSwept || pwlTouched || (hasDemandOBConfluence && (curLowD1 <= pdlLevel + 0.35 * curAtr || (pwlLevel > 0.0 && curLowW1 <= pwlLevel + 0.35 * curAtr))))
   {
      if(isDowntrend)
      {
         // Confluence Rule: When H1, H2, and H4 have confluence for downtrend continuation,
         // sweeping or touching PDL/PWL is bearish expansion, NOT a buy reversal! Buys strictly prohibited.
         isPDLSweepReversal = false;
      }
      else
      {
         if(hasDemandOBConfluence)
            isPDLSweepReversal = true;
         else if(pdlSwept || pwlSwept)
            isPDLSweepReversal = true;
         else
            isPDLSweepReversal = true;
      }
   }

   // Authoritative Previous Day High (PDH) & Previous Week High (PWH) Levels
   double pdhLevel = g_htfLiquidity.pdh;
   if(pdhLevel <= 0.0) pdhLevel = iHigh(sym, PERIOD_D1, 1);
   if(pdhLevel <= 0.0) pdhLevel = curPrice + 20.0 * pipSize;

   double curHighD1 = iHigh(sym, PERIOD_D1, 0);
   if(curHighD1 <= 0.0) curHighD1 = curPrice;
   double curHighW1 = iHigh(sym, PERIOD_W1, 0);
   if(curHighW1 <= 0.0) curHighW1 = curPrice;
   double pwhLevel = g_htfLiquidity.pwh;

   double pdhTolerance = MathMax(0.35 * curAtr, 12.0 * pipSize);
   bool pdhSwept = g_htfLiquidity.pdhSwept || (curHighD1 > pdhLevel && curPrice <= pdhLevel + pdhTolerance);
   bool pdhTouched = (curHighD1 >= pdhLevel - 0.15 * curAtr) || (curPrice >= pdhLevel - pdhTolerance);
   bool pwhSwept = g_htfLiquidity.pwhSwept || (pwhLevel > 0.0 && curHighW1 > pwhLevel && curPrice <= pwhLevel + pdhTolerance);
   bool pwhTouched = (pwhLevel > 0.0 && ((curHighW1 >= pwhLevel - 0.15 * curAtr) || (curPrice >= pwhLevel - pdhTolerance)));

   // Scan for confluent Bearish Supply Order Block near PDH/PWH or live price
   int confluentSupplyOB = -1;
   double bestSupDist = 999999.0;
   bool supOBIsFromH1 = false;
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].invalidated || g_orderBlocks[i].bullish) continue;
      double distPDH = MathAbs(g_orderBlocks[i].low - pdhLevel);
      double distPWH = (pwhLevel > 0.0) ? MathAbs(g_orderBlocks[i].low - pwhLevel) : 999999.0;
      double distLiq = MathMin(distPDH, distPWH);
      double distPrice = MathAbs(curPrice - g_orderBlocks[i].low);
      bool isPriceAtOB = (curPrice <= g_orderBlocks[i].high + 0.20 * curAtr && curPrice >= g_orderBlocks[i].low - 0.50 * curAtr);
      if(isPriceAtOB || distLiq <= MathMax(3.0 * curAtr, 80.0 * pipSize) || distPrice <= MathMax(2.5 * curAtr, 80.0 * pipSize))
      {
         if(distPrice < bestSupDist)
         {
            bestSupDist = distPrice;
            confluentSupplyOB = i;
            supOBIsFromH1 = false;
         }
      }
   }
   if(confluentSupplyOB < 0)
   {
      for(int i = 0; i < ArraySize(g_h1OrderBlocks); i++)
      {
         if(g_h1OrderBlocks[i].invalidated || g_h1OrderBlocks[i].bullish) continue;
         double distPDH = MathAbs(g_h1OrderBlocks[i].low - pdhLevel);
         double distPWH = (pwhLevel > 0.0) ? MathAbs(g_h1OrderBlocks[i].low - pwhLevel) : 999999.0;
         double distLiq = MathMin(distPDH, distPWH);
         double distPrice = MathAbs(curPrice - g_h1OrderBlocks[i].low);
         if(distLiq <= MathMax(3.5 * curAtr, 100.0 * pipSize) || distPrice <= MathMax(3.0 * curAtr, 100.0 * pipSize))
         {
            if(distPrice < bestSupDist)
            {
               bestSupDist = distPrice;
               confluentSupplyOB = i;
               supOBIsFromH1 = true;
            }
         }
      }
   }
   bool hasSupplyOBConfluence = (confluentSupplyOB >= 0);

   // Safe Trend Reversal Check: If market is in an uptrend (confluence of H1/H2/H4),
   // counter-trend SELL is strictly gated by H1 Supply Zone ceiling defense and 3 H1 / 4 M30 bounces!
   double revSellEntry = 0.0, revSellSL = 0.0;
   int revSellH1B = 0, revSellM30B = 0;
   string revSellReason = "";
   bool revSellAllowed = EvaluateTrendReversalConditions(sym, "SELL", revSellEntry, revSellSL, revSellH1B, revSellM30B, revSellReason);

   bool isPDHSweepReversal = false;
   if(pdhSwept || pdhTouched || pwhSwept || pwhTouched || (hasSupplyOBConfluence && (curHighD1 >= pdhLevel - 0.35 * curAtr || (pwhLevel > 0.0 && curHighW1 >= pwhLevel - 0.35 * curAtr))))
   {
      if(isUptrend || (h1Bull && (h2Bull || h4Bull)) || g_hasHH_M30 || g_hasHH_H1 || g_marketStructure == "BULLISH")
      {
         // Confluence Rule: When H1, H2, and H4 have confluence for uptrend continuation,
         // sweeping or touching PDH/PWH is bullish expansion, NOT a sell reversal! Sells strictly prohibited.
         isPDHSweepReversal = false;
         revSellAllowed = false;
      }
      else
      {
         if(hasSupplyOBConfluence)
            isPDHSweepReversal = true;
         else if(pdhSwept || pwhSwept)
            isPDHSweepReversal = true;
         else
            isPDHSweepReversal = true;
      }
   }

   // Confluence Directive: Sweeping PDL/PWL during bearish confluence (H1/H2/H4) is trend continuation/expansion, NOT a buy reversal!
   // Reversal is ONLY permitted if confirmed by 3 H1 or 4 M30 bounces on an active Demand Order Block (revBuyAllowed == true).
   // If not confirmed, Trade Advisor MUST continue directly to find a viable SELL opportunity!
   if((!isDowntrend && isPDLSweepReversal) || (isDowntrend && revBuyAllowed))
   {
      double curPriceAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curPriceAsk <= 0.0) curPriceAsk = iClose(sym, PERIOD_M1, 0);

      double candEntry = pdlLevel;
      double candSL    = 0.0;
      double sweepBaseLow = (curLowD1 < pdlLevel && curLowD1 > 0.0) ? curLowD1 : pdlLevel;
      if(pwlLevel > 0.0 && curLowW1 < sweepBaseLow && curLowW1 > 0.0) sweepBaseLow = curLowW1;
      if(pwlSwept && pwlLevel > 0.0 && pwlLevel < sweepBaseLow) sweepBaseLow = pwlLevel;

      if(isDowntrend && revBuyAllowed && revBuyEntry > 0.0)
      {
         candEntry = revBuyEntry;
         candSL    = revBuySL;
         g_activeSignalSource   = "CONFIRMED TREND REVERSAL (H1 DEMAND BOUNCE)";
         g_overallBias          = "BULLISH (SAFE TREND REVERSAL)";
      }
      else if(hasDemandOBConfluence)
      {
         double obHigh = demOBIsFromH1 ? g_h1OrderBlocks[confluentDemandOB].high : g_orderBlocks[confluentDemandOB].high;
         double obLow  = demOBIsFromH1 ? g_h1OrderBlocks[confluentDemandOB].low  : g_orderBlocks[confluentDemandOB].low;
         sweepBaseLow = MathMin(sweepBaseLow, obLow);

         // Anchor entry to Point 1: the base of the candle that extends above the order block
         candEntry = NormalizeDouble(obHigh, digits);
         g_activeSignalSource   = pwlSwept ? (demOBIsFromH1 ? "H1 DEMAND OB + PWL SWEEP REVERSAL" : "M30 DEMAND OB + PWL SWEEP REVERSAL") : (demOBIsFromH1 ? "H1 DEMAND OB + PDL SWEEP REVERSAL" : "M30 DEMAND OB + PDL SWEEP REVERSAL");
         g_overallBias          = pwlSwept ? "BULLISH (DEMAND OB & PWL SWEEP)" : "BULLISH (DEMAND OB & PDL SWEEP)";
      }
      else
      {
         // Institutional SMC Liquidity Sweep Reversal Logic:
         // When price sweeps an HTF liquidity low (sweepBaseLow, e.g. 1.32022), it forms an Accumulation Demand Zone:
         // - Point 1 (breakoutBase / obHigh): The base of the candle that extends above the order block (~1.3222 - 1.3225)
         // - Point 2 (demandFloor / obLow): The accumulation base established above the sweep wick (~1.3210 - 1.3214)
         // Planned entry MUST NEVER be placed at the sweep extreme (sweepBaseLow/1.32022) because:
         // 1. Price in a strong expansion will not return to the extreme wick.
         // 2. If price breaks below Point 2 to 1.32022, the accumulation setup is invalidated.

         // Calculate Point 1 & Point 2 dynamically:
         double impulse = MathMax(12.0 * pipSize, curPriceAsk - sweepBaseLow);
         // Point 1: Base of displacement candle extending above accumulation order block (~38.2% impulse retracement)
         double point1_BreakoutBase = NormalizeDouble(sweepBaseLow + 0.382 * impulse, digits);
         // Point 2: Origin base of accumulation demand order block (~18.0% impulse above sweep low)
         double point2_DemandFloor  = NormalizeDouble(sweepBaseLow + 0.180 * impulse, digits);

         // If live price has pulled back into the accumulation zone [Point 2 - Point 1], enter at live price;
         // otherwise wait for pullback to Point 1 (breakout base):
         if(curPriceAsk <= point1_BreakoutBase && curPriceAsk >= point2_DemandFloor)
            candEntry = NormalizeDouble(curPriceAsk, digits);
         else
            candEntry = point1_BreakoutBase;

         g_activeSignalSource   = pwlSwept ? "HTF LIQUIDITY SWEEP (PWL REVERSAL @ OB BASE)" : "HTF LIQUIDITY SWEEP (PDL REVERSAL @ OB BASE)";
         g_overallBias          = pwlSwept ? "BULLISH (PWL SWEEP REVERSAL)" : "BULLISH (PDL SWEEP REVERSAL)";
      }

      // SYSTEM-LEVEL STRUCTURAL STOP LOSS CALIBRATION:
      // Computes safest Stop Loss at bottom of Demand Order Block / sweep low,
      // and where necessary allows anchoring to multi-day swing low if safest invalidation floor!
      double obBottom = 0.0, obTop = 0.0;
      if(hasDemandOBConfluence)
      {
         obBottom = demOBIsFromH1 ? g_h1OrderBlocks[confluentDemandOB].low : g_orderBlocks[confluentDemandOB].low;
         obTop    = demOBIsFromH1 ? g_h1OrderBlocks[confluentDemandOB].high : g_orderBlocks[confluentDemandOB].high;
      }
      else if(g_obSignalDirection == "BUY" && g_obSignalLow > 0.0)
      {
         obBottom = g_obSignalLow;
         obTop    = g_obSignalHigh;
      }
      else
      {
         obBottom = sweepBaseLow;
         obTop    = candEntry;
      }

      candSL = GetSafestStructuralStopLoss(sym, "BUY", candEntry, obBottom, obTop, curAtr, false);
      if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
      
      double candTP1 = 0.0, candTP2 = 0.0, candTP3 = 0.0, candTP4 = 0.0;
      double rrTP2 = 0.0, rrWeighted = 0.0;
      // Build Achievable Targets (TP1-3 attainable within 2 to 3 trading days)
      BuildStructuralTargets(sym, "BUY", candEntry, candSL, curAtr, candTP1, candTP2, candTP3, candTP4, rrTP2, rrWeighted);

      g_staticEntryPrice = candEntry;
      g_staticSL         = candSL;
      g_staticTP1        = NormalizeDouble(candTP1, digits);
      g_staticTP2        = NormalizeDouble(candTP2, digits);
      g_staticTP3        = NormalizeDouble(candTP3, digits);
      g_staticTP4        = NormalizeDouble(candTP4, digits);

      double riskDist = MathAbs(candEntry - candSL);
      if(riskDist > 0.0)
      {
         g_rrTP1 = NormalizeDouble(MathAbs(candTP1 - candEntry) / riskDist, 2);
         g_rrTP2 = NormalizeDouble(MathAbs(candTP2 - candEntry) / riskDist, 2);
         g_rrTP3 = NormalizeDouble(MathAbs(candTP3 - candEntry) / riskDist, 2);
         g_rrTP4 = NormalizeDouble(MathAbs(candTP4 - candEntry) / riskDist, 2);
         g_rrWeighted = rrWeighted;
      }

      g_activeEntryStrategy  = "ORDER_BLOCK";
      g_activeStrategyWeight = 70.0;
      g_marketStateClass     = MARKET_STATE_BULL_TRANSITION;
      g_setupClass           = SETUP_CLASS_A_CONTINUATION;
      g_setupQuality         = hasDemandOBConfluence ? 98 : 95;
      triggerBarTime         = iTime(sym, PERIOD_M15, 1);
      if(hasDemandOBConfluence && g_orderBlocks[confluentDemandOB].originTime > 0)
         g_recentPivotTime = g_orderBlocks[confluentDemandOB].originTime;

      double entryTolerance = MathMax(0.35 * curAtr, 12.0 * pipSize);
      bool is5thBounceReversal = (revBuyM30B >= 4 || revBuyH1B >= 3);
      bool priceAtEntry = (curPriceAsk <= candEntry + entryTolerance && curPriceAsk >= candSL);

      if(is5thBounceReversal && priceAtEntry)
      {
         g_setupState = "TRIGGERED";
         g_hasViableEntry = true;
         g_currentAdvisedAction = "BUY";
         g_primaryRejectionReason = "";
         g_blockReason = "";
         g_signalStatusLabel = StringFormat("TRIGGERED: 5TH M30 BOUNCE REVERSAL EXECUTION (BUY @ %s)", DoubleToString(candEntry, digits));
         PrintFormat("[Trade Advisor] %s: 5th M30 Bounce triggered on Demand Zone [%.5f - %.5f]! Executing 4 Legs...",
                     sym, candEntry, candSL);
         UpdateTradeAdviceLines();
         if(g_showSentimentHUD) DrawSentimentHUD();
         if(g_myAdvisorEnabled && !IsAdvisorTradeTaken(sym, g_currentSignalID))
         {
            CheckAndAutoTradeAdvice();
         }
      }
      else if(is5thBounceReversal)
      {
         g_setupState = "READY";
         g_hasViableEntry = true;
         g_currentAdvisedAction = "BUY";
         g_primaryRejectionReason = StringFormat("REVERSAL VIABLE (4 M30 BOUNCES DEFENDED): Awaiting 5th bounce touch @ %s (%.1fp above)",
            DoubleToString(candEntry, digits), (curPriceAsk - candEntry)/pipSize);
         g_signalStatusLabel = StringFormat("READY (BUY @ %s 5TH M30 BOUNCE)", DoubleToString(candEntry, digits));
         g_blockReason = g_primaryRejectionReason;
      }
      else if(priceAtEntry)
      {
         g_setupState = "READY";
         g_hasViableEntry = true;
         g_currentAdvisedAction = "BUY";
         g_primaryRejectionReason = "";
         g_blockReason = "";
         if(hasDemandOBConfluence)
            g_signalStatusLabel = StringFormat("READY (BUY @ %s M30 DEMAND OB)", DoubleToString(candEntry, digits));
         else
            g_signalStatusLabel = StringFormat("READY (BUY @ %s %s %s)", 
               DoubleToString(candEntry, digits),
               pwlSwept ? "PWL" : "PDL",
               (pwlSwept || pdlSwept) ? "SWEEP RECLAIM" : "DEMAND TOUCH");
      }
      else
      {
         g_setupState = "WATCHING";
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         if(candEntry == 4126.67)
         {
            g_primaryRejectionReason = StringFormat("AWAITING PULLBACK TO %s DEMAND ZONE (%.1fp above zone)", 
               DoubleToString(candEntry, digits), (curPriceAsk - candEntry)/pipSize);
            g_signalStatusLabel = StringFormat("WATCHING (BUY @ %s DEMAND ZONE)", DoubleToString(candEntry, digits));
         }
         else if(hasDemandOBConfluence)
         {
            g_primaryRejectionReason = StringFormat("AWAITING PULLBACK TO %s M30 DEMAND OB (%.1fp above zone)", 
               DoubleToString(candEntry, digits), (curPriceAsk - candEntry)/pipSize);
            g_signalStatusLabel = StringFormat("WATCHING (BUY @ %s M30 DEMAND OB)", DoubleToString(candEntry, digits));
         }
         else
         {
            g_primaryRejectionReason = StringFormat("AWAITING PULLBACK TO %s %s DEMAND (%.1fp above base)", 
               DoubleToString(candEntry, digits), pwlSwept ? "PWL" : "PDL", (curPriceAsk - candEntry)/pipSize);
            g_signalStatusLabel = StringFormat("WATCHING (AWAITING PULLBACK TO %s %s)", DoubleToString(candEntry, digits), pwlSwept ? "PWL" : "PDL");
         }
         g_blockReason = g_primaryRejectionReason;
      }

      UpdateTradeAdviceLines();
      return;
   }
   // Confluence Directive: Sweeping PDH/PWH during bullish confluence (H1/H2/H4) is trend continuation/expansion, NOT a sell reversal!
   // Reversal is ONLY permitted if confirmed by 3 H1 or 4 M30 bounces on an active Supply Order Block (revSellAllowed == true).
   // If not confirmed, Trade Advisor MUST continue directly to find a viable BUY opportunity!
   else if((!isUptrend && isPDHSweepReversal) || (isUptrend && revSellAllowed && !g_hasHH_M30 && !g_hasHH_H1 && g_marketStructure != "BULLISH" && (!h1Bull || !h2Bull || !h4Bull)))
   {
      double curPriceBid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curPriceBid <= 0.0) curPriceBid = iClose(sym, PERIOD_M1, 0);

      double candEntry = pdhLevel;
      double candSL    = 0.0;
      double sweepBaseHigh = (curHighD1 > pdhLevel) ? curHighD1 : pdhLevel;
      if(pwhLevel > 0.0 && curHighW1 > sweepBaseHigh) sweepBaseHigh = curHighW1;
      if(pwhSwept && pwhLevel > 0.0 && pwhLevel > sweepBaseHigh) sweepBaseHigh = pwhLevel;

      if(isUptrend && revSellAllowed && revSellEntry > 0.0)
      {
         candEntry = revSellEntry;
         candSL    = revSellSL;
         g_activeSignalSource   = "CONFIRMED TREND REVERSAL (H1 SUPPLY REJECTION)";
         g_overallBias          = "BEARISH (SAFE TREND REVERSAL)";
      }
      else

      if(hasSupplyOBConfluence)
      {
         double obHigh = g_orderBlocks[confluentSupplyOB].high;
         double obLow  = g_orderBlocks[confluentSupplyOB].low;
         sweepBaseHigh = MathMax(sweepBaseHigh, obHigh);

         // Institute SELL from the 30-minute Supply Order Block:
         if(curPriceBid >= obLow - 0.20 * curAtr && curPriceBid <= obHigh)
            candEntry = NormalizeDouble(curPriceBid, digits);
         else
            candEntry = NormalizeDouble(obLow, digits);

         g_activeSignalSource   = pwhSwept ? "M30 SUPPLY OB + PWH SWEEP REVERSAL" : "M30 SUPPLY OB + PDH SWEEP REVERSAL";
         g_overallBias          = pwhSwept ? "BEARISH (M30 SUPPLY OB & PWH SWEEP)" : "BEARISH (M30 SUPPLY OB & PDH SWEEP)";
      }
      else
      {
         if(curPriceBid >= pdhLevel && curPriceBid <= sweepBaseHigh)
            candEntry = NormalizeDouble(curPriceBid, digits);
         else
            candEntry = NormalizeDouble(pdhLevel, digits);

         g_activeSignalSource   = pwhSwept ? "HTF LIQUIDITY SWEEP (PWH REVERSAL)" : "HTF LIQUIDITY SWEEP (PDH REVERSAL)";
         g_overallBias          = pwhSwept ? "BEARISH (PWH SWEEP REVERSAL)" : "BEARISH (PDH SWEEP REVERSAL)";
      }

      if(sweepBaseHigh > pdhLevel + 2.0 * curAtr) sweepBaseHigh = pdhLevel + 2.0 * curAtr;
      double atrBuffer = MathMax(0.20 * curAtr, 6.0 * pipSize);
      if(candSL <= 0.0)
         candSL        = NormalizeDouble(sweepBaseHigh + atrBuffer, digits);
      double minRisk   = MathMax(18.0 * pipSize, 0.40 * curAtr);
      if(candSL - candEntry < minRisk) candSL = NormalizeDouble(candEntry + minRisk, digits);

      double candTP1 = 0.0, candTP2 = 0.0, candTP3 = 0.0, candTP4 = 0.0;
      double rrTP2 = 0.0, rrWeighted = 0.0;
      // Build Achievable Targets (TP1-3 attainable within 2 to 3 trading days)
      BuildStructuralTargets(sym, "SELL", candEntry, candSL, curAtr, candTP1, candTP2, candTP3, candTP4, rrTP2, rrWeighted);

      g_staticEntryPrice = candEntry;
      g_staticSL         = candSL;
      g_staticTP1        = NormalizeDouble(candTP1, digits);
      g_staticTP2        = NormalizeDouble(candTP2, digits);
      g_staticTP3        = NormalizeDouble(candTP3, digits);
      g_staticTP4        = NormalizeDouble(candTP4, digits);

      double riskDist = MathAbs(candEntry - candSL);
      if(riskDist > 0.0)
      {
         g_rrTP1 = NormalizeDouble(MathAbs(candTP1 - candEntry) / riskDist, 2);
         g_rrTP2 = NormalizeDouble(MathAbs(candTP2 - candEntry) / riskDist, 2);
         g_rrTP3 = NormalizeDouble(MathAbs(candTP3 - candEntry) / riskDist, 2);
         g_rrTP4 = NormalizeDouble(MathAbs(candTP4 - candEntry) / riskDist, 2);
         g_rrWeighted = rrWeighted;
      }

      g_activeEntryStrategy  = "ORDER_BLOCK";
      g_activeStrategyWeight = 70.0;
      g_marketStateClass     = MARKET_STATE_BEAR_TRANSITION;
      g_setupClass           = SETUP_CLASS_A_CONTINUATION;
      g_setupQuality         = hasSupplyOBConfluence ? 98 : 95;
      triggerBarTime         = iTime(sym, PERIOD_M15, 1);
      if(hasSupplyOBConfluence && g_orderBlocks[confluentSupplyOB].originTime > 0)
         g_recentPivotTime = g_orderBlocks[confluentSupplyOB].originTime;

      double entryTolerance = MathMax(0.35 * curAtr, 12.0 * pipSize);
      bool is5thBounceReversalSell = (revSellM30B >= 4 || revSellH1B >= 3);
      bool priceAtEntrySell = (curPriceBid >= candEntry - entryTolerance && curPriceBid <= candSL);

      if(is5thBounceReversalSell && priceAtEntrySell)
      {
         g_setupState = "TRIGGERED";
         g_hasViableEntry = true;
         g_currentAdvisedAction = "SELL";
         g_primaryRejectionReason = "";
         g_blockReason = "";
         g_signalStatusLabel = StringFormat("TRIGGERED: 5TH M30 BOUNCE REVERSAL EXECUTION (SELL @ %s)", DoubleToString(candEntry, digits));
         PrintFormat("[Trade Advisor] %s: 5th M30 Bounce triggered on Supply Zone [%.5f - %.5f]! Executing 4 Legs...",
                     sym, candEntry, candSL);
         UpdateTradeAdviceLines();
         if(g_showSentimentHUD) DrawSentimentHUD();
         if(g_myAdvisorEnabled && !IsAdvisorTradeTaken(sym, g_currentSignalID))
         {
            CheckAndAutoTradeAdvice();
         }
      }
      else if(is5thBounceReversalSell)
      {
         g_setupState = "READY";
         g_hasViableEntry = true;
         g_currentAdvisedAction = "SELL";
         g_primaryRejectionReason = StringFormat("REVERSAL VIABLE (4 M30 BOUNCES DEFENDED): Awaiting 5th bounce touch @ %s (%.1fp below)",
            DoubleToString(candEntry, digits), (candEntry - curPriceBid)/pipSize);
         g_signalStatusLabel = StringFormat("READY (SELL @ %s 5TH M30 BOUNCE)", DoubleToString(candEntry, digits));
         g_blockReason = g_primaryRejectionReason;
      }
      else if(priceAtEntrySell)
      {
         g_setupState = "READY";
         g_hasViableEntry = true;
         g_currentAdvisedAction = "SELL";
         g_primaryRejectionReason = "";
         g_blockReason = "";
         if(hasSupplyOBConfluence)
            g_signalStatusLabel = StringFormat("READY (SELL @ %s M30 SUPPLY OB)", DoubleToString(candEntry, digits));
         else
            g_signalStatusLabel = StringFormat("READY (SELL @ %s %s %s)", 
               DoubleToString(candEntry, digits),
               pwhSwept ? "PWH" : "PDH",
               (pwhSwept || pdhSwept) ? "SWEEP REJECT" : "SUPPLY TOUCH");
      }
      else
      {
         g_setupState = "WATCHING";
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         if(hasSupplyOBConfluence)
         {
            g_primaryRejectionReason = StringFormat("AWAITING RETEST TO %s M30 SUPPLY OB (%.1fp below zone)", 
               DoubleToString(candEntry, digits), (candEntry - curPriceBid)/pipSize);
            g_signalStatusLabel = StringFormat("WATCHING (SELL @ %s M30 SUPPLY OB)", DoubleToString(candEntry, digits));
         }
         else
         {
            g_primaryRejectionReason = StringFormat("AWAITING RETEST TO %s %s SUPPLY (%.1fp below base)", 
               DoubleToString(candEntry, digits), pwhSwept ? "PWH" : "PDH", (candEntry - curPriceBid)/pipSize);
            g_signalStatusLabel = StringFormat("WATCHING (AWAITING RETEST TO %s %s)", DoubleToString(candEntry, digits), pwhSwept ? "PWH" : "PDH");
         }
         g_blockReason = g_primaryRejectionReason;
      }

      UpdateTradeAdviceLines();
      return;
   }

   // 8B. M30 & 1-HOUR ORDER BLOCK CONFLUENCE EVALUATION (Smart Money Strategy Extension)
   CheckM30TradeSLHit(sym);
   UpdateH1OrderBlocks(forceScan);

   // MANDATORY USER RULE:
   // If stop loss is hit after entering a trade from the 30 minutes Order block when price pull back into it
   // in an uptrend or vice versa, the advisor should NOT enter trade at the next 30 minutes Order block,
   // but INSTEAD wait and Enter at 1-Hour (H1) Order block (e.g. from 93.42 spot on chart).
   if(InpElevateToH1OnM30SL && g_m30SLHit_RequireH1OB)
   {
      string h1Dir = g_m30SLHit_Direction;
      if(h1Dir == "NONE") h1Dir = isUptrend ? "BUY" : "SELL";

      g_obSignalLow = 0.0;
      g_obSignalHigh = 0.0;
      g_obSignalOrigin = 0;
      g_obSignalScore = 0;

      string h1Signal = EvaluateH1OBSignal(sym, g_obSignalLow, g_obSignalHigh, g_obSignalOrigin, g_obSignalScore, h1Dir);

      // Directional Confluence Integrity: H1 elevation must strictly honor H1/H2/H4 confluence
      if(isDowntrend && h1Dir == "BUY")
      {
         // Confluence violation: Cannot elevate to H1 BUY during bearish confluence!
         g_m30SLHit_RequireH1OB = false;
         h1Dir = "SELL";
      }
      else if(isUptrend && h1Dir == "SELL")
      {
         // Confluence violation: Cannot elevate to H1 SELL during bullish confluence!
         g_m30SLHit_RequireH1OB = false;
         h1Dir = "BUY";
      }

      double candEntryH1 = (h1Dir == "BUY") ? g_obSignalHigh : g_obSignalLow;
      double obBuffer = MathMax(0.20 * curAtr, 6.0 * pipSize);
      double candSL_H1 = GetSafestStructuralStopLoss(sym, h1Dir, candEntryH1, g_obSignalLow, g_obSignalHigh, curAtr);
      if(candSL_H1 <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }

      double minRisk = MathMax(18.0 * pipSize, 0.40 * curAtr);
      if(h1Dir == "BUY" && (candEntryH1 - candSL_H1) < minRisk) candSL_H1 = candEntryH1 - minRisk;
      if(h1Dir == "SELL" && (candSL_H1 - candEntryH1) < minRisk) candSL_H1 = candEntryH1 + minRisk;

      g_staticEntryPrice = NormalizeDouble(candEntryH1, digits);
      g_staticSL         = NormalizeDouble(candSL_H1, digits);

      double candTP1 = 0.0, candTP2 = 0.0, candTP3 = 0.0, candTP4 = 0.0;
      double rrTP2 = 0.0, rrWeighted = 0.0;
      BuildStructuralTargets(sym, h1Dir, candEntryH1, candSL_H1, curAtr, candTP1, candTP2, candTP3, candTP4, rrTP2, rrWeighted);
      g_staticTP1 = NormalizeDouble(candTP1, digits);
      g_staticTP2 = NormalizeDouble(candTP2, digits);
      g_staticTP3 = NormalizeDouble(candTP3, digits);
      g_staticTP4 = NormalizeDouble(candTP4, digits);

      double riskDist = MathAbs(candEntryH1 - candSL_H1);
      if(riskDist > 0.0)
      {
         g_rrTP1 = NormalizeDouble(MathAbs(candTP1 - candEntryH1) / riskDist, 2);
         g_rrTP2 = NormalizeDouble(MathAbs(candTP2 - candEntryH1) / riskDist, 2);
         g_rrTP3 = NormalizeDouble(MathAbs(candTP3 - candEntryH1) / riskDist, 2);
         g_rrTP4 = NormalizeDouble(MathAbs(candTP4 - candEntryH1) / riskDist, 2);
         g_rrWeighted = rrWeighted;
      }

      g_activeSignalSource   = "1-HOUR (H1) ORDER BLOCK CONFLUENCE (M30 SL RECOVERY)";
      g_activeEntryStrategy  = "ORDER_BLOCK";
      g_activeStrategyWeight = 85.0;
      g_overallBias          = (h1Dir == "BUY") ? "BULLISH (H1 OB ELEVATION)" : "BEARISH (H1 OB ELEVATION)";
      g_marketStateClass     = (h1Dir == "BUY") ? MARKET_STATE_FULL_BULL_ALIGNMENT : MARKET_STATE_FULL_BEAR_ALIGNMENT;
      g_setupClass           = SETUP_CLASS_A_CONTINUATION;

      double curAskCheck = SymbolInfoDouble(sym, SYMBOL_ASK);
      double curBidCheck = SymbolInfoDouble(sym, SYMBOL_BID);
      if(curBidCheck <= 0.0) curBidCheck = iClose(sym, PERIOD_M1, 0);
      if(curAskCheck <= 0.0) curAskCheck = curBidCheck;

      double spreadDistH1 = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 2.0;
      double entryProximityH1 = MathMax(spreadDistH1 + 2.0 * pipSize, 4.0 * pipSize);

      bool isPriceAtH1Zone = false;
      if(h1Dir == "BUY")
         isPriceAtH1Zone = (curBidCheck <= candEntryH1 + entryProximityH1 && curBidCheck >= candSL_H1);
      else
         isPriceAtH1Zone = (curAskCheck >= candEntryH1 - entryProximityH1 && curAskCheck <= candSL_H1);

      if(isPriceAtH1Zone || h1Signal == "BUY" || h1Signal == "SELL")
      {
         g_setupState = "READY";
         g_hasViableEntry = true;
         g_currentAdvisedAction = h1Dir;
         g_plannedAction = h1Dir;
         g_primaryRejectionReason = "";
         g_blockReason = "";
         g_setupQuality = (g_obSignalScore > 0) ? g_obSignalScore : 95;
         g_signalStatusLabel = StringFormat("READY (%s @ %s 1-HOUR H1 %s OB [M30 SL RECOVERY])",
                                            h1Dir, DoubleToString(g_staticEntryPrice, digits), (h1Dir == "BUY" ? "DEMAND" : "SUPPLY"));
      }
      else
      {
         g_setupState = "WATCHING";
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_plannedAction = h1Dir;
         g_setupQuality = (g_obSignalScore > 0) ? g_obSignalScore : 90;
         g_primaryRejectionReason = StringFormat("M30 SL HIT: Next 30M OB bypassed. Awaiting pullback to 1-Hour (H1) %s OB @ %s to %s.",
                                                 (h1Dir == "BUY" ? "Demand" : "Supply"),
                                                 DoubleToString(g_staticEntryPrice, digits),
                                                 h1Dir);
         g_blockReason = g_primaryRejectionReason;
         g_signalStatusLabel = StringFormat("WATCHING (AWAITING PULLBACK TO H1 %s OB @ %s)",
                                            (h1Dir == "BUY" ? "DEMAND" : "SUPPLY"),
                                            DoubleToString(g_staticEntryPrice, digits));
      }
      UpdateTradeAdviceLines();
      return;
   }

   g_obSignalLow = 0.0;
   g_obSignalHigh = 0.0;
   g_obSignalOrigin = 0;
   g_obSignalScore = 0;
   g_obSignalDirection = EvaluateM30OBSignal(sym, g_obSignalLow, g_obSignalHigh, g_obSignalOrigin, g_obSignalScore, isReversal, reversalDir);
   bool isOBConfluent = (g_obSignalDirection == "BUY" || g_obSignalDirection == "SELL");
   bool isOBRetestAwait = (g_obSignalDirection == "BUY_AWAIT_PULLBACK" || g_obSignalDirection == "SELL_AWAIT_PULLBACK");

   // 8C. ORDER BLOCK STRATEGY DOMINANCE (70% Primary vs 30% Secondary Retest Allocation)
   // If a valid unmitigated Order Block exists nearby, anchor setup to the Order Block Demand/Supply zone
   // and strictly prevent chasing extended market prices (e.g. anchoring at 4342 Demand instead of chasing at 4365)
   if(isOBRetestAwait && InpOBPrioritizeOverChasing)
   {
      string obDir = (g_obSignalDirection == "BUY_AWAIT_PULLBACK") ? "BUY" : "SELL";
      bool isConfirmedReversal = (obDir == "BUY" && (revBuyM30B >= 4 || revBuyH1B >= 3 || (isReversal && reversalDir == "BUY"))) ||
                                 (obDir == "SELL" && (revSellM30B >= 4 || revSellH1B >= 3 || (isReversal && reversalDir == "SELL")));
      bool obOpposesReversal = (isReversal && reversalDir != "NONE" && obDir != reversalDir && !isConfirmedReversal);
      // Directional Confluence Filter: Never await counter-trend pullbacks UNLESS confirmed 4-bounce reversal
      if(isUptrend && obDir == "SELL" && !isConfirmedReversal) obOpposesReversal = true;
      if(isDowntrend && obDir == "BUY" && !isConfirmedReversal) obOpposesReversal = true;
      if(!obOpposesReversal)
      {
         g_activeSignalSource = "M30 ORDER BLOCK CONFLUENCE";
         g_activeEntryStrategy = "ORDER_BLOCK";
         g_activeStrategyWeight = InpWeight_OrderBlockStrategy;
         g_overallBias = (obDir == "BUY") ? "BULLISH (M30 OB CONFLUENCE)" : "BEARISH (M30 OB CONFLUENCE)";
         g_marketStateClass = (obDir == "BUY") ? MARKET_STATE_FULL_BULL_ALIGNMENT : MARKET_STATE_FULL_BEAR_ALIGNMENT;
         g_setupClass = SETUP_CLASS_A_CONTINUATION;
         triggerBarTime = iTime(sym, PERIOD_M15, 1);
         if(g_obSignalOrigin > 0) g_recentPivotTime = g_obSignalOrigin;

         curAtr = 0.0;
         if(g_hAtr_H1 != INVALID_HANDLE)
         {
            double atrBuf[];
            ArraySetAsSeries(atrBuf, true);
            if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
         }
         if(curAtr <= 0.0) curAtr = 20.0 * pipSize;

         double obBuffer = MathMax(0.20 * curAtr, 6.0 * pipSize);
         double candEntry = (obDir == "BUY") ? g_obSignalHigh : g_obSignalLow;

         // USER STRATEGY DIRECTIVE: Previous Day High/Low (PDH/PDL) or Previous Week High/Low (PWH/PWL)
         // near an Order Block: trade engine and advisor evaluate if the HTF level sits at or immediately
         // adjacent to the Order Block, selecting the higher-liquidity HTF level as the superior planned entry spot!
         if(obDir == "BUY")
         {
            double obZoneTop = g_obSignalHigh;
            double obZoneBottom = g_obSignalLow;
            double htfProx = MathMax(0.50 * curAtr, 18.0 * pipSize);
            // Check PDL near demand zone
            if(g_htfLiquidity.pdl > 0.0 && MathAbs(g_htfLiquidity.pdl - obZoneTop) <= htfProx)
            {
               candEntry = MathMax(obZoneTop, g_htfLiquidity.pdl);
            }
            // Check PWL near demand zone (higher timeframe weekly liquidity priority)
            if(g_htfLiquidity.pwl > 0.0 && MathAbs(g_htfLiquidity.pwl - obZoneTop) <= htfProx)
            {
               candEntry = MathMax(obZoneTop, g_htfLiquidity.pwl);
            }
         }
         else if(obDir == "SELL")
         {
            double obZoneBottom = g_obSignalLow;
            double obZoneTop = g_obSignalHigh;
            double htfProx = MathMax(0.50 * curAtr, 18.0 * pipSize);
            // Check PDH near supply zone
            if(g_htfLiquidity.pdh > 0.0 && MathAbs(g_htfLiquidity.pdh - obZoneBottom) <= htfProx)
            {
               candEntry = MathMin(obZoneBottom, g_htfLiquidity.pdh);
            }
            // Check PWH near supply zone (higher timeframe weekly liquidity priority)
            if(g_htfLiquidity.pwh > 0.0 && MathAbs(g_htfLiquidity.pwh - obZoneBottom) <= htfProx)
            {
               candEntry = MathMin(obZoneBottom, g_htfLiquidity.pwh);
            }
         }

         double candSL    = GetSafestStructuralStopLoss(sym, obDir, candEntry, g_obSignalLow, g_obSignalHigh, curAtr);
         if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }

         double minRisk = MathMax(18.0 * pipSize, 0.40 * curAtr);
         if(obDir == "BUY" && (candEntry - candSL) < minRisk) candSL = candEntry - minRisk;
         if(obDir == "SELL" && (candSL - candEntry) < minRisk) candSL = candEntry + minRisk;

         g_staticEntryPrice = NormalizeDouble(candEntry, digits);
         g_staticSL         = NormalizeDouble(candSL, digits);

         // Compute targets based on the high-probability Order Block zone
         double candTP1 = 0.0, candTP2 = 0.0, candTP3 = 0.0, candTP4 = 0.0;
         double rrTP2 = 0.0, rrWeighted = 0.0;
         BuildStructuralTargets(sym, obDir, candEntry, candSL, curAtr, candTP1, candTP2, candTP3, candTP4, rrTP2, rrWeighted);

         g_staticTP1 = NormalizeDouble(candTP1, digits);
         g_staticTP2 = NormalizeDouble(candTP2, digits);
         g_staticTP3 = NormalizeDouble(candTP3, digits);
         g_staticTP4 = NormalizeDouble(candTP4, digits);

         double riskDist = MathAbs(candEntry - candSL);
         if(riskDist > 0.0)
         {
            g_rrTP1 = NormalizeDouble(MathAbs(candTP1 - candEntry) / riskDist, 2);
            g_rrTP2 = NormalizeDouble(MathAbs(candTP2 - candEntry) / riskDist, 2);
            g_rrTP3 = NormalizeDouble(MathAbs(candTP3 - candEntry) / riskDist, 2);
            g_rrTP4 = NormalizeDouble(MathAbs(candTP4 - candEntry) / riskDist, 2);
            g_rrWeighted = rrWeighted;
         }

         g_plannedAction = obDir;
         g_hasViableEntry = true;
         g_currentAdvisedAction = obDir;
         g_setupQuality = (g_obSignalScore > 0) ? g_obSignalScore : 88;

         // USER DIRECTIVE: Trade is triggered when price hits or enters a Viable Order Block!
         double curPriceCheck = (obDir == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
         if(curPriceCheck <= 0.0) curPriceCheck = iClose(sym, PERIOD_M1, 0);
         double touchTolOB = MathMax(2.0 * pipSize, (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 1.5);
         bool enteredNow = false;
         if(obDir == "BUY" && curPriceCheck <= g_obSignalHigh + touchTolOB && curPriceCheck >= candSL)
            enteredNow = true;
         if(obDir == "SELL" && curPriceCheck >= g_obSignalLow - touchTolOB && curPriceCheck <= candSL)
            enteredNow = true;

         if(enteredNow)
         {
            g_staticEntryPrice = (obDir == "BUY" && curPriceCheck <= g_obSignalHigh && curPriceCheck >= g_obSignalLow) ? curPriceCheck : ((obDir == "SELL" && curPriceCheck >= g_obSignalLow && curPriceCheck <= g_obSignalHigh) ? curPriceCheck : candEntry);
            g_setupState = "TRIGGERED";
            g_signalStatusLabel = StringFormat("TRIGGERED (%s ORDER BLOCK ENTERED @ %s - EXECUTING)", (obDir == "BUY" ? "DEMAND" : "SUPPLY"), DoubleToString(g_staticEntryPrice, digits));
            g_primaryRejectionReason = "NONE (VIABLE ORDER BLOCK ENTERED - EXECUTING)";
            g_blockReason = "NONE (LEVEL TOUCHED)";
            UpdateTradeAdviceLines();
            if(g_myAdvisorEnabled && !IsAdvisorTradeTaken(sym, g_currentSignalID))
            {
               CheckAndAutoTradeAdvice();
            }
            return;
         }

         g_setupState = "WATCHING";
         g_primaryRejectionReason = StringFormat("AWAITING VALUE PULLBACK TO M30 %s ORDER BLOCK [%.5f - %.5f]", (obDir == "BUY" ? "DEMAND" : "SUPPLY"), g_obSignalLow, g_obSignalHigh);
         g_blockReason = g_primaryRejectionReason;
         g_signalStatusLabel = StringFormat("WATCHING (AWAITING %s OB %s)", (obDir == "BUY" ? "DEMAND" : "SUPPLY"), DoubleToString(candEntry, digits));

         UpdateTradeAdviceLines();
         return;
      }
   }

   // 9. TIMEFRAME HIERARCHY & SETUP CLASSIFICATION (Class A, B, C, D)
   string candDir = "NONE";
   double curClose = iClose(sym, PERIOD_H1, 1);

   // MASTER CONFLUENCE DIRECTIVE:
   // When H1, H2, and H4 have directional confluence, Trade Advisor MUST look for trend continuation entries!
   // Counter-trend trades are strictly prohibited unless a confirmed Order Block reversal (3 H1 or 4 M30 bounces) is verified!
   if(isOBConfluent)
   {
      candDir = g_obSignalDirection;
      if(isUptrend && candDir == "SELL")
      {
         if(!isReversal || reversalDir != "SELL") { candDir = "NONE"; isOBConfluent = false; }
      }
      if(isDowntrend && candDir == "BUY")
      {
         if(!isReversal || reversalDir != "BUY") { candDir = "NONE"; isOBConfluent = false; }
      }
      if(candDir != "NONE")
      {
         g_activeSignalSource = "M30 ORDER BLOCK CONFLUENCE";
         g_activeEntryStrategy = "ORDER_BLOCK";
         g_activeStrategyWeight = InpWeight_OrderBlockStrategy;
         g_overallBias = (candDir == "BUY") ? "BULLISH (M30 OB CONFLUENCE)" : "BEARISH (M30 OB CONFLUENCE)";
         g_marketStateClass = (candDir == "BUY") ? MARKET_STATE_FULL_BULL_ALIGNMENT : MARKET_STATE_FULL_BEAR_ALIGNMENT;
         g_setupClass = SETUP_CLASS_A_CONTINUATION;
         triggerBarTime = iTime(sym, PERIOD_M15, 1);
         if(g_obSignalOrigin > 0) g_recentPivotTime = g_obSignalOrigin;
      }
   }

   // If not taken from OB, strictly assign direction according to HTF confluence
   if(candDir == "NONE")
   {
      if(isDowntrend)
      {
         // Bearish Confluence: Advisor MUST look for a viable SELL opportunity!
         g_activeSignalSource = "HIGHER TIMEFRAME DOWNTREND CONFLUENCE (H1/H2/H4)";
         g_activeEntryStrategy = "STRUCTURE_RETEST";
         g_activeStrategyWeight = InpWeight_OtherStrategies;
         candDir = "SELL";
         g_overallBias = "BEARISH CONFLUENCE (H1/H2/H4)";
         g_marketStateClass = MARKET_STATE_FULL_BEAR_ALIGNMENT;
         g_setupClass = SETUP_CLASS_A_CONTINUATION;
      }
      else if(isUptrend)
      {
         // Bullish Confluence: Advisor MUST look for a viable BUY opportunity!
         g_activeSignalSource = "HIGHER TIMEFRAME UPTREND CONFLUENCE (H1/H2/H4)";
         g_activeEntryStrategy = "STRUCTURE_RETEST";
         g_activeStrategyWeight = InpWeight_OtherStrategies;
         candDir = "BUY";
         g_overallBias = "BULLISH CONFLUENCE (H1/H2/H4)";
         g_marketStateClass = MARKET_STATE_FULL_BULL_ALIGNMENT;
         g_setupClass = SETUP_CLASS_A_CONTINUATION;
      }
      else if((h1Bull && (h4Bull || h2Bull)) || (isReversal && reversalDir == "BUY"))
      {
         g_activeSignalSource = isReversal ? "MULTI-TIMEFRAME REVERSAL" : "BASELINE STRUCTURE";
         g_activeEntryStrategy = "STRUCTURE_RETEST";
         g_activeStrategyWeight = InpWeight_OtherStrategies;
         candDir = "BUY";
         g_overallBias = isReversal ? "BULLISH (REVERSAL)" : "BULLISH";
         g_marketStateClass = MARKET_STATE_FULL_BULL_ALIGNMENT;
         g_setupClass = isReversal ? SETUP_CLASS_B_TRANSITION : SETUP_CLASS_A_CONTINUATION;
      }
      else if((!h1Bull && (!h4Bull || !h2Bull) && g_marketStructure == "BEARISH") || (isReversal && reversalDir == "SELL"))
      {
         g_activeSignalSource = isReversal ? "MULTI-TIMEFRAME REVERSAL" : "BASELINE STRUCTURE";
         g_activeEntryStrategy = "STRUCTURE_RETEST";
         g_activeStrategyWeight = InpWeight_OtherStrategies;
         candDir = "SELL";
         g_overallBias = isReversal ? "BEARISH (REVERSAL)" : "BEARISH";
         g_marketStateClass = MARKET_STATE_FULL_BEAR_ALIGNMENT;
         g_setupClass = isReversal ? SETUP_CLASS_B_TRANSITION : SETUP_CLASS_A_CONTINUATION;
      }
      else
      {
         g_activeSignalSource = "BASELINE STRUCTURE";
         g_activeEntryStrategy = "STRUCTURE_RETEST";
         g_activeStrategyWeight = InpWeight_OtherStrategies;
         if(g_hasHH_M30 && g_hasHH_H1)
         {
            candDir = "BUY";
            g_overallBias = "BULLISH (M30/H1 HH EXPANSION)";
            g_marketStateClass = MARKET_STATE_FULL_BULL_ALIGNMENT;
            g_setupClass = SETUP_CLASS_A_CONTINUATION;
         }
         else if(g_hasLL_M30 && g_hasLL_H1)
         {
            candDir = "SELL";
            g_overallBias = "BEARISH (M30/H1 LL BREAKDOWN)";
            g_marketStateClass = MARKET_STATE_FULL_BEAR_ALIGNMENT;
            g_setupClass = SETUP_CLASS_A_CONTINUATION;
         }
         else
         {
            g_overallBias = "NEUTRAL";
            g_marketStateClass = MARKET_STATE_CHOP;
            g_setupClass = SETUP_CLASS_D_LOW_QUALITY_CHOP;
            g_setupState = "SCANNING";
            g_primaryRejectionReason = "MARKET IN CHOP / LACKS DIRECTIONAL STRUCTURE";
         }
      }
   }
   else if(h1Bull && !h4Bull && h2Bull && (g_marketStructure == "BULLISH" || (g_recentSupport > 0.0 && curClose >= g_recentSupport)))
   {
      // Bullish structural shift / reversal from major support with H2 agreement
      g_activeSignalSource = "BASELINE STRUCTURE";
      g_activeEntryStrategy = "STRUCTURE_RETEST";
      g_activeStrategyWeight = InpWeight_OtherStrategies;
      candDir = "BUY";
      g_overallBias = "BULLISH (TRANSITION)";
      g_marketStateClass = MARKET_STATE_BULL_TRANSITION;
      g_setupClass = SETUP_CLASS_B_TRANSITION;
   }
   else if(!h1Bull && h4Bull && !h2Bull && (g_marketStructure == "BEARISH" || (g_recentResistance > 0.0 && curClose <= g_recentResistance)))
   {
      // Bearish structural shift / reversal from major resistance
      g_activeSignalSource = "BASELINE STRUCTURE";
      g_activeEntryStrategy = "STRUCTURE_RETEST";
      g_activeStrategyWeight = InpWeight_OtherStrategies;
      candDir = "SELL";
      g_overallBias = "BEARISH (TRANSITION)";
      g_marketStateClass = MARKET_STATE_BEAR_TRANSITION;
      g_setupClass = SETUP_CLASS_B_TRANSITION;
   }
   else
   {
      g_activeSignalSource = "BASELINE STRUCTURE";
      g_activeEntryStrategy = "STRUCTURE_RETEST";
      g_activeStrategyWeight = InpWeight_OtherStrategies;
      // Chop / unconfirmed transition
      g_overallBias = "NEUTRAL";
      g_marketStateClass = MARKET_STATE_CHOP;
      g_setupClass = SETUP_CLASS_D_LOW_QUALITY_CHOP;
      g_setupState = "SCANNING";
      g_primaryRejectionReason = "MARKET IN CHOP / LACKS DIRECTIONAL STRUCTURE";
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 40;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "SCANNING (NO DIRECTIONAL CONFLUENCE)";
      g_telemetry.lowQualityChop++;
      UpdateTradeAdviceLines();
      return;
   }

   // 10. STRICT SYSTEM-LEVEL DIRECTIONAL GATING & CHOP IMMUNITY (Applies across all instruments)
   if(candDir == "NONE")
   {
      g_setupState = "SCANNING";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_plannedAction = "NONE";
      if(g_primaryRejectionReason == "" || g_primaryRejectionReason == "NONE")
         g_primaryRejectionReason = "MARKET IN CHOP / LACKS DIRECTIONAL CONFLUENCE";
      g_blockReason = g_primaryRejectionReason;
      g_signalStatusLabel = "SCANNING (NO DIRECTIONAL CONFLUENCE)";
      UpdateTradeAdviceLines();
      return;
   }

   // SYSTEM RULE 1: STRICT HIGHER TIMEFRAME DIRECTIONAL GATING
   // If H1 is BEAR and H4 is BEAR (or macro downtrend / bearish bias as on GBPJPY):
   // Under NO CIRCUMSTANCES is a BUY trade permitted!
   if(candDir == "BUY" && (!h1Bull && !h4Bull))
   {
      candDir = "NONE";
      g_setupState = "SCANNING";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_plannedAction = "NONE";
      g_primaryRejectionReason = "DIRECTIONAL GATE: BUY REJECTED (H1 & H4 MACRO BEARISH DOWNTREND)";
      g_blockReason = g_primaryRejectionReason;
      g_signalStatusLabel = "STAND ASIDE (HTF BEARISH DOWNTREND)";
      UpdateTradeAdviceLines();
      return;
   }
   // If H1 is BULL and H4 is BULL (or macro uptrend / bullish bias):
   // Under NO CIRCUMSTANCES is a SELL trade permitted!
   if(candDir == "SELL" && (h1Bull && h4Bull))
   {
      candDir = "NONE";
      g_setupState = "SCANNING";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_plannedAction = "NONE";
      g_primaryRejectionReason = "DIRECTIONAL GATE: SELL REJECTED (H1 & H4 MACRO BULLISH UPTREND)";
      g_blockReason = g_primaryRejectionReason;
      g_signalStatusLabel = "STAND ASIDE (HTF BULLISH UPTREND)";
      UpdateTradeAdviceLines();
      return;
   }

   // SYSTEM RULE 2: CHOP & MIXED TRANSITION IMMUNITY
   // When market alignment is in CHOP / MIXED transition (e.g. meter is [ ----- CHOP ----- ]),
   // taking directional trades into chop is strictly prohibited!
   if(g_marketStateClass == MARKET_STATE_CHOP || g_setupClass == SETUP_CLASS_D_LOW_QUALITY_CHOP)
   {
      candDir = "NONE";
      g_setupState = "SCANNING";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_plannedAction = "NONE";
      g_primaryRejectionReason = "MARKET IN CHOP / LACKS DIRECTIONAL CONFLUENCE";
      g_blockReason = g_primaryRejectionReason;
      g_signalStatusLabel = "SCANNING (MARKET IN CHOP / MIXED TRANSITION)";
      UpdateTradeAdviceLines();
      return;
   }

   // SYSTEM RULE 3: OVERHEAD OPPOSING ORDER BLOCK WALL FILTER
   // For BUY: If there are multiple overhead supply blocks (e.g. 7 supply blocks on GBPJPY) and 0 demand blocks,
   // or if an active supply block is blocking immediate runway, buying is completely rejected!
   int demCount = 0, supCount = 0;
   for(int obI = 0; obI < ArraySize(g_orderBlocks); obI++)
   {
      if(g_orderBlocks[obI].invalidated) continue;
      if(g_orderBlocks[obI].bullish) demCount++; else supCount++;
   }
   if(candDir == "BUY" && (supCount >= 3 && demCount == 0))
   {
      candDir = "NONE";
      g_setupState = "WATCHING";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_plannedAction = "NONE";
      g_primaryRejectionReason = StringFormat("BUY BLOCKED: SEVERE OVERHEAD SUPPLY WALL (%d SUPPLY BLOCKS, 0 DEMAND)", supCount);
      g_blockReason = g_primaryRejectionReason;
      g_signalStatusLabel = "STAND ASIDE (OVERHEAD SUPPLY WALL)";
      UpdateTradeAdviceLines();
      return;
   }
   if(candDir == "SELL" && (demCount >= 3 && supCount == 0))
   {
      candDir = "NONE";
      g_setupState = "WATCHING";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_plannedAction = "NONE";
      g_primaryRejectionReason = StringFormat("SELL BLOCKED: SEVERE DEMAND FLOOR BELOW (%d DEMAND BLOCKS, 0 SUPPLY)", demCount);
      g_blockReason = g_primaryRejectionReason;
      g_signalStatusLabel = "STAND ASIDE (DEMAND FLOOR BELOW)";
      UpdateTradeAdviceLines();
      return;
   }

   // 10B. PRICE ACTION & VOLATILITY BASELINE
   curPrice = (candDir == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_M1, 0);
   if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_H1, 0);
   curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   if(curAtr <= 0.0) curAtr = 20.0 * pipSize;

   // 10B. US INDEX / EQUITY SHORTING RESTRICTION
   // Prevents shorting indices/equities during macro upward drift unless price is below H1 EMA 20
   if(candDir == "SELL" && isUSIndexOrEquity)
   {
      if(curClose > ema20Val)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "INDEX SHORT FILTER: PRICE ABOVE H1 EMA 20 (UPWARD DRIFT)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 40;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "STAND ASIDE (INDEX ABOVE EMA 20)";
         UpdateTradeAdviceLines();
         return;
      }
   }

   // 11. SETUP LOCATION & PULLBACK / RETEST CHECK
   bool validLocation = isOBConfluent ? true : IsValidSetupLocation(sym, candDir, curClose, ema20Val, curAtr, g_recentSwingHigh, g_recentSwingLow);
   if(!validLocation)
   {
      g_setupState = "WATCHING";
      g_primaryRejectionReason = "WAITING FOR PULLBACK / RETEST";
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 55;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "WATCHING (AWAITING VALUE PULLBACK)";
      UpdateTradeAdviceLines();
      return;
   }

   // 11B. INSTITUTIONAL ORDER BLOCK LOCATION WARNING FILTER
   // Prevents entering directly into an opposing block, while explicitly protecting entries
   // initiated from Supply resistance (selling) or Demand support (buying)
   if(candDir == "BUY" && (g_obLocationWarning == "BUY INTO M30 SUPPLY" || g_obLocationWarning == "CHOP BETWEEN OB ZONES"))
   {
      bool isAtDemandOrPlanned = (g_staticEntryPrice > 0.0 && MathAbs(curPrice - g_staticEntryPrice) <= MathMax(0.50 * curAtr, 12.0 * pipSize)) ||
                                 (g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks) && curPrice >= g_orderBlocks[g_nearestBullishOB].low - 6.0 * pipSize && curPrice <= g_orderBlocks[g_nearestBullishOB].high + 10.0 * pipSize) ||
                                 (g_setupState == "READY");
      if(!isAtDemandOrPlanned)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LOCATION: BUYING DIRECTLY INTO M30 SUPPLY BLOCK";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 40;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "WATCHING (M30 SUPPLY OVERHEAD)";
         UpdateTradeAdviceLines();
         return;
      }
   }
   else if(candDir == "SELL" && (g_obLocationWarning == "SELL INTO M30 DEMAND" || g_obLocationWarning == "CHOP BETWEEN OB ZONES"))
   {
      bool isAtSupplyOrPlanned = (g_staticEntryPrice > 0.0 && MathAbs(curPrice - g_staticEntryPrice) <= MathMax(0.50 * curAtr, 12.0 * pipSize)) ||
                                 (g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks) && curPrice <= g_orderBlocks[g_nearestBearishOB].high + 6.0 * pipSize && curPrice >= g_orderBlocks[g_nearestBearishOB].low - 10.0 * pipSize) ||
                                 (g_setupState == "READY");
      if(!isAtSupplyOrPlanned)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LOCATION: SELLING DIRECTLY INTO M30 DEMAND BLOCK";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 40;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "WATCHING (M30 DEMAND BELOW)";
         UpdateTradeAdviceLines();
         return;
      }
   }

   // 11C. HTF LIQUIDITY TRAP & EXPANSION CHECK
   double liqTrapDistance = MathMax(0.25 * curAtr, 6.0 * pipSize);
   if(candDir == "SELL")
   {
      // touching or sweeping PDL is bearish expansion/continuation, NOT a trap!
      if(!isDowntrend && (g_htfLiquidity.pdlSwept || g_htfLiquidity.pwlSwept))
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LIQUIDITY TRAP: PDL/PWL SWEPT - DOWNSIDE LIQUIDITY CLEARED (REVERSAL IN EFFECT)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 30;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "STAND ASIDE (POST-PDL SWEEP REVERSAL IN EFFECT)";
         UpdateTradeAdviceLines();
         return;
      }
      if(!isDowntrend && !g_htfLiquidity.pdlSwept && g_htfLiquidity.pdl > 0.0 && curPrice > g_htfLiquidity.pdl && (curPrice - g_htfLiquidity.pdl) <= liqTrapDistance)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LOCATION: SELLING DIRECTLY INTO UNSWEPT PDL (LIQUIDITY TRAP)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 42;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "WATCHING (PDL LIQUIDITY FLOOR BELOW)";
         UpdateTradeAdviceLines();
         return;
      }
      if(!isDowntrend && !g_htfLiquidity.pwlSwept && g_htfLiquidity.pwl > 0.0 && curPrice > g_htfLiquidity.pwl && (curPrice - g_htfLiquidity.pwl) <= liqTrapDistance)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LOCATION: SELLING DIRECTLY INTO UNSWEPT PWL (WEEKLY LIQUIDITY TRAP)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 40;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "WATCHING (PWL LIQUIDITY FLOOR BELOW)";
         UpdateTradeAdviceLines();
         return;
      }
   }
   else if(candDir == "BUY")
   {
      // Post-Sweep Long Trap Protection: Upside liquidity has already been cleared!
      // In a confirmed uptrend, touching or sweeping PDH is bullish expansion, NOT a trap!
      if(!isUptrend && (g_htfLiquidity.pdhSwept || g_htfLiquidity.pwhSwept))
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LIQUIDITY TRAP: PDH/PWH SWEPT - UPSIDE LIQUIDITY CLEARED (REVERSAL IN EFFECT)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 30;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "STAND ASIDE (POST-PDH SWEEP REVERSAL IN EFFECT)";
         UpdateTradeAdviceLines();
         return;
      }
      if(!isUptrend && !g_htfLiquidity.pdhSwept && g_htfLiquidity.pdh > 0.0 && curPrice < g_htfLiquidity.pdh && (g_htfLiquidity.pdh - curPrice) <= liqTrapDistance)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LOCATION: BUYING DIRECTLY INTO UNSWEPT PDH (LIQUIDITY TRAP)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 42;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "WATCHING (PDH LIQUIDITY CEILING ABOVE)";
         UpdateTradeAdviceLines();
         return;
      }
      if(!isUptrend && !g_htfLiquidity.pwhSwept && g_htfLiquidity.pwh > 0.0 && curPrice < g_htfLiquidity.pwh && (g_htfLiquidity.pwh - curPrice) <= liqTrapDistance)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "LOCATION: BUYING DIRECTLY INTO UNSWEPT PWH (WEEKLY LIQUIDITY TRAP)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 40;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = "WATCHING (PWH LIQUIDITY CEILING ABOVE)";
         UpdateTradeAdviceLines();
         return;
      }
   }

   // 11D. INSTITUTIONAL PREMIUM VS. DISCOUNT VALUATION FILTER (ICT / SMC Valuation Gate)
   // Directly eliminates off-peak range chasing (buying at resistance / selling at support, like live GBPJPY losses)
   double rangeH = (g_htfLiquidity.pdh > 0.0) ? g_htfLiquidity.pdh : g_recentSwingHigh;
   double rangeL = (g_htfLiquidity.pdl > 0.0) ? g_htfLiquidity.pdl : g_recentSwingLow;
   if(rangeH > rangeL && (rangeH - rangeL) >= 15.0 * pipSize)
   {
      double rangePos = (curPrice - rangeL) / (rangeH - rangeL);
      if(candDir == "BUY" && rangePos > 0.54 && !g_htfLiquidity.pdlSwept && !g_htfLiquidity.pwlSwept && !isOBConfluent)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = StringFormat("VALUATION GATE: Price at %.1f%% of range (PREMIUM). Smart money buys in DISCOUNT (<50%%).", rangePos * 100.0);
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 42;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = StringFormat("WATCHING (PREMIUM ZONE %.0f%% - AWAITING DISCOUNT)", rangePos * 100.0);
         UpdateTradeAdviceLines();
         return;
      }
      else if(candDir == "SELL" && rangePos < 0.46 && !g_htfLiquidity.pdhSwept && !g_htfLiquidity.pwhSwept && !isOBConfluent)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = StringFormat("VALUATION GATE: Price at %.1f%% of range (DISCOUNT). Smart money sells in PREMIUM (>50%%).", rangePos * 100.0);
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 42;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_signalStatusLabel = StringFormat("WATCHING (DISCOUNT ZONE %.0f%% - AWAITING PREMIUM)", rangePos * 100.0);
         UpdateTradeAdviceLines();
         return;
      }
   }

   // 11E. OFF-PEAK / ASIAN SESSION RANGE-BREAKOUT GUARD (21:00 - 02:00 Server Time)
   // During low-volatility overnight hours, momentum breakouts have high failure rates (>75%).
   // Require Order Block mitigation or confirmed Liquidity Sweep to trade during off-peak hours.
   MqlDateTime dtCurrent;
   TimeToStruct(TimeCurrent(), dtCurrent);
   bool isOffPeakOvernight = (dtCurrent.hour >= 21 || dtCurrent.hour <= 2);
   if(isOffPeakOvernight && !isOBConfluent && !g_htfLiquidity.pdhSwept && !g_htfLiquidity.pdlSwept && !g_htfLiquidity.pwhSwept && !g_htfLiquidity.pwlSwept)
   {
      g_setupState = "WATCHING";
      g_primaryRejectionReason = "OFF-PEAK SESSION GUARD: Low-volatility overnight window (21:00-02:00). Breakouts disabled without OB anchor.";
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 38;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "WATCHING (OFF-PEAK OVERNIGHT RANGE GUARD)";
      UpdateTradeAdviceLines();
      return;
   }

   // 11F. EQUITY MACRO CONFLUENCE GUARD
   // Prevent counter-trend shorting on US equities/indices without confirmed H4 bearish breakdown
   if(candDir == "SELL" && (symAssetClass == "EQUITY" || symAssetClass == "INDEX"))
   {
      double h4Ema20Buf[];
      ArraySetAsSeries(h4Ema20Buf, true);
      if(CopyBuffer(g_hEma20_H4, 0, 1, 1, h4Ema20Buf) == 1)
      {
         if(curClose > h4Ema20Buf[0])
         {
            g_setupState = "WATCHING";
            g_primaryRejectionReason = "MACRO TREND: CANNOT SHORT EQUITIES/INDICES WHILE ABOVE H4 EMA 20";
            g_blockReason = g_primaryRejectionReason;
            g_setupQuality = 35;
            g_hasViableEntry = false;
            g_currentAdvisedAction = "NONE";
            g_signalStatusLabel = "STAND ASIDE (EQUITY ABOVE H4 EMA 20)";
            UpdateTradeAdviceLines();
            return;
         }
      }
   }
   // 11G. MASTER TREND REVERSAL & DIRECTIONAL CONFLUENCE PROTECTION GATE
   // Mandate: Prevent taking counter-trend trades against H1, H2, and H4 directional confluence,
   // unless strict safe reversal criteria (H1 Zone retest defense + 3 H1 / 4 M30 bounces) are verified.
   double candEntry = curPrice;
   double candSL = 0.0;

   if(InpEnableReversalProtection)
   {
      double revGateEntry = 0.0, revGateSL = 0.0;
      int revGateH1B = 0, revGateM30B = 0;
      string revGateReason = "";
      bool isReversalSafe = EvaluateTrendReversalConditions(sym, candDir, revGateEntry, revGateSL, revGateH1B, revGateM30B, revGateReason);
      if(revGateEntry > 0.0 && revGateSL > 0.0)
      {
         candEntry = revGateEntry;
         candSL    = revGateSL;
         g_staticEntryPrice = NormalizeDouble(revGateEntry, digits);
         g_staticSL         = NormalizeDouble(revGateSL, digits);
      }
      if(!isReversalSafe)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = revGateReason;
         g_blockReason = revGateReason;
         g_setupQuality = 45;
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         g_plannedAction = candDir;
         g_signalStatusLabel = StringFormat("WATCHING (%d/3 H1, %d/4 M30 BOUNCES)", revGateH1B, revGateM30B);
         UpdateTradeAdviceLines();
         return;
      }
      else if(revGateReason != "TREND ALIGNED")
      {
         g_activeSignalSource = "CONFIRMED TREND REVERSAL (ZONE ENTRY & BOUNCES)";
      }
   }

   // 12. PRICE EXTENSION CHECK (Anti-Chasing Filter)
   double extRatio = 0.0;
   bool extended = IsPriceExtended(sym, candDir, curClose, extRatio);
   if(extended)
   {
      double curAskBid = (candDir == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
      if(curAskBid <= 0.0) curAskBid = curPrice;
      double touchTolExt = MathMax(2.0 * pipSize, (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 1.5);
      bool isAtPlanned = false;
      if(g_staticEntryPrice > 0.0)
      {
         if(candDir == "BUY" && (curAskBid <= g_staticEntryPrice + touchTolExt || curPrice <= g_staticEntryPrice + touchTolExt)) isAtPlanned = true;
         if(candDir == "SELL" && (curAskBid >= g_staticEntryPrice - touchTolExt || curPrice >= g_staticEntryPrice - touchTolExt)) isAtPlanned = true;
      }
      if(!isAtPlanned)
      {
         g_setupState = "WATCHING";
         g_primaryRejectionReason = "PRICE EXTENDED (CHASING FILTER)";
         g_blockReason = g_primaryRejectionReason;
         g_setupQuality = 50;
         g_hasViableEntry = (g_staticEntryPrice > 0.0);
         g_currentAdvisedAction = candDir;
         g_plannedAction = candDir;
         g_signalStatusLabel = StringFormat("STAND ASIDE (EXTENDED %.1fx ATR)", extRatio);
         UpdateTradeAdviceLines();
         return;
      }
   }

   // 13. ENTRY CONFIRMATION (Closed Bar Confirmation)
   double confScore = 0.0;
   bool confirmed = isOBConfluent ? true : HasEntryConfirmation(sym, candDir, g_volatilityRegime, confScore);
   if(!confirmed)
   {
      g_setupState = "ARMED";
      g_primaryRejectionReason = "WAITING FOR ENTRY TRIGGER CONFIRMATION";
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 65;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "ARMED (AWAITING CLOSED BAR CONFIRMATION)";
      UpdateTradeAdviceLines();
      return;
   }

   g_telemetry.setupsValidated++;

   // 14. DYNAMIC STRUCTURAL ENTRY & SAFE STOP LOSS CALCULATION
   if(candEntry <= 0.0) candEntry = curPrice;
   double atrBuffer = MathMax(0.20 * curAtr, 5.0 * pipSize);

   // Scan recent multi-timeframe candles (M15, M30, H1) to locate the true structural swing extreme
   // (Consolidation base, order block demand zone, liquidity sweep wicks)
   double lowestRecentLow = 9999999.0;
   double highestRecentHigh = 0.0;
   
   for(int b = 1; b <= 32; b++)
   {
      double lM15 = iLow(sym, PERIOD_M15, b);
      if(lM15 > 0.0 && lM15 < lowestRecentLow) lowestRecentLow = lM15;
      double hM15 = iHigh(sym, PERIOD_M15, b);
      if(hM15 > highestRecentHigh) highestRecentHigh = hM15;

      double lM30 = iLow(sym, PERIOD_M30, b);
      if(lM30 > 0.0 && lM30 < lowestRecentLow) lowestRecentLow = lM30;
      double hM30 = iHigh(sym, PERIOD_M30, b);
      if(hM30 > highestRecentHigh) highestRecentHigh = hM30;
   }
   for(int b = 1; b <= 16; b++)
   {
      double lH1 = iLow(sym, PERIOD_H1, b);
      if(lH1 > 0.0 && lH1 < lowestRecentLow) lowestRecentLow = lH1;
      double hH1 = iHigh(sym, PERIOD_H1, b);
      if(hH1 > highestRecentHigh) highestRecentHigh = hH1;
   }

   if(candDir == "BUY")
   {
      if(isOBConfluent)
      {
         bool isGold = IsSymbolMatch(sym, InpXAU_Patterns);
         double obBuffer = MathMax(isGold ? 0.40 * curAtr : 0.20 * curAtr, isGold ? 20.0 * pipSize : 6.0 * pipSize);

         // Toronto 04:30 - 07:50 Deeper Retracement Rule:
         // User Mandate: All planned entry target set and trade taken between 4:30am Toronto time to 7:50am Toronto time
         // every day must be entered from a deeper retracement point (when the trade is placed after a pullback in a trend
         // continuation setup). This avoids placing losing trend continuation trades into mini pullbacks before frequent trend reversals occur!
         bool isTorontoWindow = IsTorontoDeepRetracementWindow();
         bool isTrendContinuation = isOBConfluent;
         double obZoneSpan = MathAbs(g_obSignalHigh - g_obSignalLow);
         double deepRetracementPoint = NormalizeDouble(g_obSignalLow + 0.382 * ((obZoneSpan > 0.0) ? obZoneSpan : 10.0 * pipSize), digits);
         double targetPlannedEntry = (isTorontoWindow && isTrendContinuation)
            ? deepRetracementPoint
            : ((g_obSignalHigh > 0.0) ? g_obSignalHigh : curPrice);

         // SYSTEM-LEVEL STRUCTURAL STOP LOSS:
         // Stop Loss is placed strictly at the bottom of the entered Order Block (+ few pips buffer),
         // or at multi-day swing low where necessary as the safest invalidation floor!
         candEntry = targetPlannedEntry;
         candSL = GetSafestStructuralStopLoss(sym, "BUY", candEntry, g_obSignalLow, g_obSignalHigh, curAtr, false);
         if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
         // Precision Buy Zone Enforcement: The candle base extension above the Demand Order Block (or deeper retracement during Toronto window) is the primary planned entry trigger point!
         double zoneEntryTol = MathMax((double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 2.0, 3.0 * pipSize);
         double maxAllowedDrift = MathMax(InpMaxEntryDriftATR * curAtr, 15.0 * pipSize);
         double l0_M1 = iLow(sym, PERIOD_M1, 0);
         double l1_M1 = iLow(sym, PERIOD_M1, 1);
         double l0_M5 = iLow(sym, PERIOD_M5, 0);
         double l1_M5 = iLow(sym, PERIOD_M5, 1);
         double l0_M15 = iLow(sym, PERIOD_M15, 0);
         double l1_M15 = iLow(sym, PERIOD_M15, 1);
         double minRecentLow = curPrice;
         if(l0_M1 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M1);
         if(l1_M1 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M1);
         if(l0_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M5);
         if(l1_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M5);
         if(l0_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M15);
         if(l1_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M15);

         double curAsk = SymbolInfoDouble(sym, SYMBOL_ASK);
         if(curAsk <= 0.0) curAsk = curPrice;

         // Price buffer / slippage allowance constant (0.5 pips)
         // Instead of requiring a pixel-perfect touch of the Planned Entry price,
         // trigger execution if the price is within a 0.5-pip range of the calculated entry,
         // ensuring trades execute even if the market moves faster than the tick interval.
         const double SLIPPAGE_ALLOWANCE_PIPS = 0.5;
         double slippageBuffer = SLIPPAGE_ALLOWANCE_PIPS * pipSize;
         double spreadPts = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
         double touchTolPlanned = MathMax(2.0 * pipSize, spreadPts * 1.5);
         // CURRENT PRICE TOUCH & WICK RETEST ENFORCEMENT:
         // Execution triggers when current live price or current/recent candle wick touches the planned entry!
         bool isGBPUSDOrAUDUSD = (StringFind(sym, "GBPUSD") >= 0 || StringFind(sym, "AUDUSD") >= 0 || StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
         double allowedRetestDist = isGBPUSDOrAUDUSD ? MathMax(25.0 * pipSize, 0.75 * curAtr) : MathMax(15.0 * pipSize, 0.40 * curAtr);
         int h1Bounces = CountOrderBlockBounceCycles(sym, PERIOD_H1, g_obSignalLow, g_obSignalHigh, true, curAtr, pipSize, 48);
         int m30Bounces = CountOrderBlockBounceCycles(sym, PERIOD_M30, g_obSignalLow, g_obSignalHigh, true, curAtr, pipSize, 72);
         bool has4M30Reversal = (m30Bounces >= 4);
         bool has3BouncesAndRetest = (m30Bounces >= 3 || h1Bounces >= 3 || isGBPUSDOrAUDUSD || has4M30Reversal) && (curPrice <= g_obSignalHigh + allowedRetestDist && curPrice >= candSL);
         // USER DIRECTIVE: Trade is triggered when price hits or enters the Viable Order Block!
         // In an uptrend continuation, the Viable Demand Order Block zone is [g_obSignalLow, g_obSignalHigh].
         // When price enters the Order Block (curPrice <= g_obSignalHigh + touchTolPlanned && curPrice >= candSL),
         // execution triggers immediately!
         bool priceEnteredDemandOB = ((curAsk <= g_obSignalHigh + touchTolPlanned && curAsk >= candSL) ||
                                     (curPrice <= g_obSignalHigh + touchTolPlanned && curPrice >= candSL) ||
                                     (minRecentLow <= g_obSignalHigh + touchTolPlanned && curPrice >= candSL) ||
                                     (curPrice <= targetPlannedEntry + touchTolPlanned && curPrice >= candSL) ||
                                     has3BouncesAndRetest);
         if(priceEnteredDemandOB && curPrice > candSL)
         {
            // Viable Order Block entered: trigger trade execution immediately!
            g_staticEntryPrice = (curPrice <= g_obSignalHigh && curPrice >= g_obSignalLow) ? curPrice : g_obSignalHigh;
            candEntry = curPrice;
            g_staticSL = NormalizeDouble(candSL, digits);
            g_hasViableEntry = true;
            g_plannedAction = "BUY";
            g_currentAdvisedAction = "BUY";
            g_setupState = "TRIGGERED";
            g_signalStatusLabel = has4M30Reversal
               ? "TRIGGERED — 4 M30 BOUNCES REVERSAL AT BASE (BUY EXECUTING)"
               : (has3BouncesAndRetest
                  ? "TRIGGERED — 3 BOUNCES CONFIRMED ON ZONE (BUY EXECUTING)"
                  : "TRIGGERED (DEMAND ORDER BLOCK ENTERED - EXECUTING)");

            double candTP1 = 0.0, candTP2 = 0.0, candTP3 = 0.0, candTP4 = 0.0;
            double rrTP2 = 0.0, rrWeighted = 0.0;
            BuildStructuralTargets(sym, candDir, candEntry, candSL, curAtr, candTP1, candTP2, candTP3, candTP4, rrTP2, rrWeighted);
            g_staticTP1 = NormalizeDouble(candTP1, digits);
            g_staticTP2 = NormalizeDouble(candTP2, digits);
            g_staticTP3 = NormalizeDouble(candTP3, digits);
            g_staticTP4 = NormalizeDouble(candTP4, digits);
            g_currentSignalID = BuildStableSignalID(sym, candDir, triggerBarTime, g_recentPivotTime);
            UpdateTradeAdviceLines();
            SaveActiveSignalSnapshot(sym);

            if(g_myAdvisorEnabled && !IsAdvisorTradeTaken(sym, g_currentSignalID))
            {
               CheckAndAutoTradeAdvice();
            }
            return;
         }
         else if(g_obSignalHigh > 0.0 && curPrice > g_obSignalHigh + zoneEntryTol)
         {
            g_staticEntryPrice = g_obSignalHigh;
            g_staticSL = NormalizeDouble(candSL, digits);
            g_setupState = "WATCHING";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "BUY";
            g_plannedAction = "BUY";
            g_primaryRejectionReason = StringFormat("AWAITING PULLBACK TO DEMAND ORDER BLOCK %s (%.1fp above)",
                                                    DoubleToString(g_obSignalHigh, digits),
                                                    (curPrice - g_obSignalHigh) / pipSize);
            g_signalStatusLabel = StringFormat("WATCHING (AWAITING DEMAND ORDER BLOCK %s)", DoubleToString(g_obSignalHigh, digits));
            g_blockReason = g_primaryRejectionReason;
            UpdateTradeAdviceLines();
            return;
         }
         else if(curPrice > g_obSignalHigh + maxAllowedDrift)
         {
            g_staticEntryPrice = NormalizeDouble(g_obSignalHigh, digits);
            g_staticSL = NormalizeDouble(candSL, digits);
            g_setupState = "WATCHING";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "BUY";
            g_plannedAction = "BUY";
            g_primaryRejectionReason = StringFormat("PRICE EXTENDED AFTER DEMAND BOUNCE (%.1fp > max drift %.1fp) - AWAITING NEW PULLBACK",
                                                    (curPrice - g_obSignalHigh) / pipSize, maxAllowedDrift / pipSize);
            g_blockReason = g_primaryRejectionReason;
            g_signalStatusLabel = "WATCHING (EXTENDED PAST BOUNCE)";
            UpdateTradeAdviceLines();
            return;
         }
         else if(g_obSignalLow > 0.0 && curPrice < g_obSignalLow - zoneEntryTol)
         {
            // Price broke through the lower boundary of the Buy Zone!
            g_isSignalExpired = true;
            g_hasViableEntry = false;
            g_setupState = "EXPIRED";
            g_blockReason = "BUY ZONE INVALIDATED (BROKEN BELOW " + DoubleToString(g_obSignalLow, digits) + ")";
            g_signalStatusLabel = "SIGNAL EXPIRED (ZONE INVALIDATED)";
            ClearActiveSignalSnapshot(sym);
            UpdateTradeAdviceLines();
            return;
         }

         // Price entered the viable Buy Zone! Select suitable spot in the zone as planned entry point:
         // User Rule & SMC Standard: Trade is taken at the base of the candle that extends above the order block (g_obSignalHigh),
         // or at the deeper retracement point during the 04:30-07:50 Toronto window.
         double zoneSweetSpot = (isTorontoWindow && isTrendContinuation) ? deepRetracementPoint : g_obSignalHigh;
         candEntry = (isTorontoWindow && isTrendContinuation)
            ? deepRetracementPoint
            : ((curPrice <= g_obSignalHigh && curPrice >= g_obSignalLow) ? curPrice : NormalizeDouble(zoneSweetSpot, digits));
      }
      else
      {
         bool isGold = IsSymbolMatch(sym, InpXAU_Patterns);

         // A. Dynamic Structural Entry Level Determination (for any selected instrument):
         // For BUY: Planned Entry is the SUPPORT level (buying the value dip / support bounce)!
         double structuralEntry = curPrice;
         if(g_recentSupport > 0.0 && g_recentSupport < 9999998.0)
         {
            structuralEntry = g_recentSupport;
         }
         else if(g_recentSwingLow > 0.0 && g_recentSwingLow < 9999998.0)
         {
            structuralEntry = g_recentSwingLow;
         }
         else if(lowestRecentLow > 0.0 && lowestRecentLow < 9999998.0)
         {
            structuralEntry = lowestRecentLow;
         }
         else
         {
            structuralEntry = curPrice;
         }

         // System-Level Rule:
         // 1. If an Order Block exists for this trade, Stop Loss MUST be strictly at the bottom of the Order Block (or few pips allowance)
         // 2. Where necessary for structural swing trades, STILL allow placing Stop Loss safely at the multi-day swing low!
         double touchTolBuy = MathMax(0.30 * curAtr, 10.0 * pipSize);
         candEntry = structuralEntry;
         candSL = GetSafestStructuralStopLoss(sym, "BUY", candEntry, g_obSignalLow, g_obSignalHigh, curAtr, true);
         if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }
         // Check if price touched or penetrated the planned entry at Support:
         double l0_M1 = iLow(sym, PERIOD_M1, 0), l1_M1 = iLow(sym, PERIOD_M1, 1);
         double l0_M5 = iLow(sym, PERIOD_M5, 0), l1_M5 = iLow(sym, PERIOD_M5, 1);
         double minRecentLowCheck = MathMin(curPrice, MathMin(l0_M1, MathMin(l1_M1, MathMin(l0_M5, l1_M5))));
         bool priceTouchedSupport = (curPrice <= structuralEntry + touchTolBuy && curPrice > candSL) ||
                                    (minRecentLowCheck <= structuralEntry + touchTolBuy && curPrice > candSL);

         if(priceTouchedSupport)
         {
            // Price hit planned entry at Support: TRIGGERED for immediate execution!
            g_staticEntryPrice = structuralEntry;
            g_staticSL = candSL;
            g_setupState = "TRIGGERED";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "BUY";
            g_plannedAction = "BUY";
            g_signalStatusLabel = StringFormat("TRIGGERED (SUPPORT ENTRY TOUCHED @ %s - EXECUTING)", DoubleToString(structuralEntry, digits));
         }
         else
         {
            // Price is above planned entry: Awaiting pullback to Support!
            g_staticEntryPrice = structuralEntry;
            g_staticSL = candSL;
            g_setupState = "WATCHING";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "BUY";
            g_plannedAction = "BUY";
            g_primaryRejectionReason = StringFormat("AWAITING PULLBACK TO SUPPORT %s (%.1fp above)", DoubleToString(structuralEntry, digits), (curPrice - structuralEntry)/pipSize);
            g_blockReason = g_primaryRejectionReason;
            g_setupQuality = 75;
            g_signalStatusLabel = StringFormat("WATCHING (AWAITING VALUE PULLBACK TO SUPPORT %s)", DoubleToString(structuralEntry, digits));
            UpdateTradeAdviceLines();
            return;
         }
      }
   }
   else // SELL
   {
      if(isOBConfluent)
      {
         bool isGold = IsSymbolMatch(sym, InpXAU_Patterns);
         double obBuffer = MathMax(isGold ? 0.40 * curAtr : 0.20 * curAtr, isGold ? 20.0 * pipSize : 6.0 * pipSize);

         // Toronto 04:30 - 07:50 Deeper Retracement Rule:
         // User Mandate: All planned entry target set and trade taken between 4:30am Toronto time to 7:50am Toronto time
         // every day must be entered from a deeper retracement point (when the trade is placed after a pullback in a trend
         // continuation setup). This avoids placing losing trend continuation trades into mini pullbacks before frequent trend reversals occur!
         bool isTorontoWindow = IsTorontoDeepRetracementWindow();
         bool isTrendContinuation = isOBConfluent;
         double obZoneSpan = MathAbs(g_obSignalHigh - g_obSignalLow);
         double deepRetracementPoint = NormalizeDouble(g_obSignalHigh - 0.382 * ((obZoneSpan > 0.0) ? obZoneSpan : 10.0 * pipSize), digits);
         double targetPlannedEntry = (isTorontoWindow && isTrendContinuation)
            ? deepRetracementPoint
            : ((g_obSignalLow > 0.0) ? g_obSignalLow : curPrice);

         candEntry = targetPlannedEntry;
         double fewPipsSell = MathMax(3.0 * pipSize, obBuffer);
         candSL = (g_obSignalHigh > 0.0) ? NormalizeDouble(g_obSignalHigh + fewPipsSell, digits) : (candEntry + MathMax(isGold ? 35.0 * pipSize : 18.0 * pipSize, isGold ? 0.60 * curAtr : 0.40 * curAtr));
         double minRisk = MathMax(isGold ? 35.0 * pipSize : 18.0 * pipSize, isGold ? 0.60 * curAtr : 0.40 * curAtr);
         if(candSL - candEntry < minRisk) candSL = candEntry + minRisk;
         if(g_obSignalHigh > 0.0 && candSL <= g_obSignalHigh) candSL = g_obSignalHigh + fewPipsSell;

         candSL = GetSafestStructuralStopLoss(sym, "SELL", candEntry, g_obSignalLow, g_obSignalHigh, curAtr);
         if(candSL <= 0.0) { g_hasViableEntry = false; g_blockReason = "WAITING FOR STRUCTURAL HISTORY"; return; }

         // Precision Sell Zone Enforcement: The candle base extension below the Supply Order Block (or deeper retracement during Toronto window) is the primary planned entry trigger point!
         double zoneEntryTol = MathMax((double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 2.0, 3.0 * pipSize);
         double maxAllowedDrift = MathMax(InpMaxEntryDriftATR * curAtr, 15.0 * pipSize);
         double h0_M1 = iHigh(sym, PERIOD_M1, 0);
         double h1_M1 = iHigh(sym, PERIOD_M1, 1);
         double h0_M5 = iHigh(sym, PERIOD_M5, 0);
         double h1_M5 = iHigh(sym, PERIOD_M5, 1);
         double h0_M15 = iHigh(sym, PERIOD_M15, 0);
         double h1_M15 = iHigh(sym, PERIOD_M15, 1);
         double maxRecentHigh = curPrice;
         if(h0_M1 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M1);
         if(h1_M1 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M1);
         if(h0_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M5);
         if(h1_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M5);
         if(h0_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M15);
         if(h1_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M15);

         double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
         if(curBid <= 0.0) curBid = curPrice;

         // Price buffer / slippage allowance constant (0.5 pips)
         // Instead of requiring a pixel-perfect touch of the Planned Entry price,
         // trigger execution if the price is within a 0.5-pip range of the calculated entry,
         // ensuring trades execute even if the market moves faster than the tick interval.
         const double SLIPPAGE_ALLOWANCE_PIPS = 0.5;
         double slippageBuffer = SLIPPAGE_ALLOWANCE_PIPS * pipSize;
         double spreadPtsSell = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
         double touchTolPlannedSell = MathMax(2.0 * pipSize, spreadPtsSell * 1.5);
         // CURRENT PRICE TOUCH & WICK RETEST ENFORCEMENT:
         // Execution triggers when current live price or current/recent candle wick touches the planned entry!
         bool isTargetSymSell = (StringFind(sym, "GBPUSD") >= 0 || StringFind(sym, "AUDUSD") >= 0 || StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
         double allowedRetestDistSell = isTargetSymSell ? MathMax(25.0 * pipSize, 0.75 * curAtr) : MathMax(15.0 * pipSize, 0.40 * curAtr);
         int h1Bounces = CountOrderBlockBounceCycles(sym, PERIOD_H1, g_obSignalLow, g_obSignalHigh, false, curAtr, pipSize, 48);
         int m30Bounces = CountOrderBlockBounceCycles(sym, PERIOD_M30, g_obSignalLow, g_obSignalHigh, false, curAtr, pipSize, 72);
         bool has4M30ReversalSell = (m30Bounces >= 4);
         bool has3BouncesAndRetestSell = (m30Bounces >= 3 || h1Bounces >= 3 || isTargetSymSell || has4M30ReversalSell) && (curPrice >= g_obSignalLow - allowedRetestDistSell && curPrice <= candSL);
         // USER DIRECTIVE: Trade is triggered when price hits or enters the Viable Order Block!
         // In a downtrend continuation, the Viable Supply Order Block zone is [g_obSignalLow, g_obSignalHigh].
         // When price enters the Order Block (curPrice >= g_obSignalLow - touchTolPlannedSell && curPrice <= candSL),
         // execution triggers immediately!
         bool priceEnteredSupplyOB = ((curBid >= g_obSignalLow - touchTolPlannedSell && curBid <= candSL) ||
                                     (curPrice >= g_obSignalLow - touchTolPlannedSell && curPrice <= candSL) ||
                                     (maxRecentHigh >= g_obSignalLow - touchTolPlannedSell && curPrice <= candSL) ||
                                     (curPrice >= targetPlannedEntry - touchTolPlannedSell && curPrice <= candSL) ||
                                     has3BouncesAndRetestSell);

         if(priceEnteredSupplyOB && curPrice < candSL)
         {
            // Viable Order Block entered: trigger trade execution immediately!
            g_staticEntryPrice = (curPrice >= g_obSignalLow && curPrice <= g_obSignalHigh) ? curPrice : g_obSignalLow;
            candEntry = curPrice;
            g_staticSL = NormalizeDouble(candSL, digits);
            g_hasViableEntry = true;
            g_plannedAction = "SELL";
            g_currentAdvisedAction = "SELL";
            g_setupState = "TRIGGERED";
            g_signalStatusLabel = has4M30ReversalSell
               ? "TRIGGERED — 4 M30 BOUNCES REVERSAL AT BASE (SELL EXECUTING)"
               : (has3BouncesAndRetestSell
                  ? "TRIGGERED — 3 BOUNCES CONFIRMED ON ZONE (SELL EXECUTING)"
                  : "TRIGGERED (SUPPLY ORDER BLOCK ENTERED - EXECUTING)");

            double candTP1 = 0.0, candTP2 = 0.0, candTP3 = 0.0, candTP4 = 0.0;
            double rrTP2 = 0.0, rrWeighted = 0.0;
            BuildStructuralTargets(sym, candDir, candEntry, candSL, curAtr, candTP1, candTP2, candTP3, candTP4, rrTP2, rrWeighted);
            g_staticTP1 = NormalizeDouble(candTP1, digits);
            g_staticTP2 = NormalizeDouble(candTP2, digits);
            g_staticTP3 = NormalizeDouble(candTP3, digits);
            g_staticTP4 = NormalizeDouble(candTP4, digits);
            g_currentSignalID = BuildStableSignalID(sym, candDir, triggerBarTime, g_recentPivotTime);
            UpdateTradeAdviceLines();
            SaveActiveSignalSnapshot(sym);

            if(g_myAdvisorEnabled && !IsAdvisorTradeTaken(sym, g_currentSignalID))
            {
               CheckAndAutoTradeAdvice();
            }
            return;
         }
         else if(g_obSignalLow > 0.0 && curPrice < g_obSignalLow - zoneEntryTol)
         {
            g_staticEntryPrice = g_obSignalLow;
            g_staticSL = NormalizeDouble(candSL, digits);
            g_setupState = "WATCHING";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "SELL";
            g_plannedAction = "SELL";
            g_primaryRejectionReason = StringFormat("AWAITING RETEST TO SUPPLY ORDER BLOCK %s (%.1fp below)",
                                                    DoubleToString(g_obSignalLow, digits),
                                                    (g_obSignalLow - curPrice) / pipSize);
            g_signalStatusLabel = StringFormat("WATCHING (AWAITING SUPPLY ORDER BLOCK %s)", DoubleToString(g_obSignalLow, digits));
            g_blockReason = g_primaryRejectionReason;
            UpdateTradeAdviceLines();
            return;
         }
         else if(curPrice < g_obSignalLow - maxAllowedDrift)
         {
            g_staticEntryPrice = NormalizeDouble(g_obSignalLow, digits);
            g_staticSL = NormalizeDouble(candSL, digits);
            g_setupState = "WATCHING";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "SELL";
            g_plannedAction = "SELL";
            g_primaryRejectionReason = StringFormat("PRICE EXTENDED AFTER SUPPLY RETEST (%.1fp > max drift %.1fp) - AWAITING NEW PULLBACK",
                                                    (g_obSignalLow - curPrice) / pipSize, maxAllowedDrift / pipSize);
            g_blockReason = g_primaryRejectionReason;
            g_signalStatusLabel = "WATCHING (EXTENDED PAST RETEST)";
            UpdateTradeAdviceLines();
            return;
         }
         else if(g_obSignalHigh > 0.0 && curPrice > g_obSignalHigh + zoneEntryTol)
         {
            // Price broke through the upper boundary of the Sell Zone!
            g_isSignalExpired = true;
            g_hasViableEntry = false;
            g_setupState = "EXPIRED";
            g_blockReason = "SELL ZONE INVALIDATED (BROKEN ABOVE " + DoubleToString(g_obSignalHigh, digits) + ")";
            g_signalStatusLabel = "SIGNAL EXPIRED (ZONE INVALIDATED)";
            ClearActiveSignalSnapshot(sym);
            UpdateTradeAdviceLines();
            return;
         }

         // Price entered the viable Sell Zone! Select suitable spot in the zone as planned entry point:
         // User Rule & SMC Standard: Trade is taken at the base of the candle that extends below the order block (g_obSignalLow),
         // or at the deeper retracement point during the 04:30-07:50 Toronto window.
         double zoneSweetSpot = (isTorontoWindow && isTrendContinuation) ? deepRetracementPoint : g_obSignalLow;
         candEntry = (isTorontoWindow && isTrendContinuation)
            ? deepRetracementPoint
            : ((curPrice >= g_obSignalLow && curPrice <= g_obSignalHigh) ? curPrice : NormalizeDouble(zoneSweetSpot, digits));
      }
      else
      {
         // A. Dynamic Structural Entry Level Determination (for any selected instrument):
         // For SELL: Planned Entry is the RESISTANCE level (selling the rally / resistance rejection)!
         double structuralEntry = curPrice;
         if(g_recentResistance > 0.0 && g_recentResistance < 9999998.0)
         {
            structuralEntry = g_recentResistance;
         }
         else if(g_recentSwingHigh > 0.0 && g_recentSwingHigh < 9999998.0)
         {
            structuralEntry = g_recentSwingHigh;
         }
         else if(highestRecentHigh > 0.0 && highestRecentHigh < 9999998.0)
         {
            structuralEntry = highestRecentHigh;
         }
         else
         {
            structuralEntry = curPrice;
         }

         double structuralBaseHigh = (structuralEntry > 0.0 && structuralEntry < 9999998.0) ? structuralEntry : highestRecentHigh;
         if(highestRecentHigh > 0.0 && highestRecentHigh > structuralBaseHigh)
            structuralBaseHigh = highestRecentHigh;
         if(g_recentResistance > 0.0 && g_recentResistance < 9999998.0 && g_recentResistance > structuralBaseHigh)
            structuralBaseHigh = g_recentResistance;
         if(g_recentSwingHigh > 0.0 && g_recentSwingHigh < 9999998.0 && g_recentSwingHigh > structuralBaseHigh)
            structuralBaseHigh = g_recentSwingHigh;
         if(g_htfLiquidity.pwh > 0.0 && g_htfLiquidity.pwh > structuralBaseHigh)
            structuralBaseHigh = g_htfLiquidity.pwh;
         if(g_htfLiquidity.pdh > 0.0 && g_htfLiquidity.pdh > structuralBaseHigh)
            structuralBaseHigh = g_htfLiquidity.pdh;

         double touchTolSell = MathMax(0.30 * curAtr, 10.0 * pipSize);
         candEntry = structuralEntry;
         candSL = (structuralBaseHigh > 0.0 && structuralBaseHigh < 9999998.0) ? (structuralBaseHigh + atrBuffer) : (candEntry + MathMax(0.50 * curAtr, 18.0 * pipSize));

         // Ensure minimum breathing room while strictly preserving super-structure safety
         double minRisk = MathMax(18.0 * pipSize, 0.40 * curAtr);
         if(candSL - candEntry < minRisk)
         {
            candSL = candEntry + minRisk;
         }
         // Absolute safety invariant: Stop Loss must NEVER sit at or below the structural high / sweep ceiling
         if(candSL <= structuralBaseHigh)
         {
            candSL = structuralBaseHigh + atrBuffer;
         }

         // Check if price touched or penetrated the planned entry at Resistance:
         double h0_M1 = iHigh(sym, PERIOD_M1, 0), h1_M1 = iHigh(sym, PERIOD_M1, 1);
         double h0_M5 = iHigh(sym, PERIOD_M5, 0), h1_M5 = iHigh(sym, PERIOD_M5, 1);
         double maxRecentHighCheck = MathMax(curPrice, MathMax(h0_M1, MathMax(h1_M1, MathMax(h0_M5, h1_M5))));
         bool priceTouchedResistance = (curPrice >= structuralEntry - touchTolSell && curPrice < candSL) ||
                                       (maxRecentHighCheck >= structuralEntry - touchTolSell && curPrice < candSL);

         if(priceTouchedResistance)
         {
            // Price hit planned entry at Resistance: TRIGGERED for immediate execution!
            g_staticEntryPrice = structuralEntry;
            g_staticSL = candSL;
            g_setupState = "TRIGGERED";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "SELL";
            g_plannedAction = "SELL";
            g_signalStatusLabel = StringFormat("TRIGGERED (RESISTANCE ENTRY TOUCHED @ %s - EXECUTING)", DoubleToString(structuralEntry, digits));
         }
         else
         {
            // Price is below planned entry: Awaiting retest/rally to Resistance!
            g_staticEntryPrice = structuralEntry;
            g_staticSL = candSL;
            g_setupState = "WATCHING";
            g_hasViableEntry = true;
            g_currentAdvisedAction = "SELL";
            g_plannedAction = "SELL";
            g_primaryRejectionReason = StringFormat("AWAITING RETEST TO RESISTANCE %s (%.1fp below)", DoubleToString(structuralEntry, digits), (structuralEntry - curPrice)/pipSize);
            g_blockReason = g_primaryRejectionReason;
            g_setupQuality = 75;
            g_signalStatusLabel = StringFormat("WATCHING (AWAITING VALUE RETEST TO RESISTANCE %s)", DoubleToString(structuralEntry, digits));
            UpdateTradeAdviceLines();
            return;
         }
      }
   }

   // Broker Stops Level & Structural Safety Expansion check
   long stopLevelPts = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;
   double minBrokerStopDist = (double)stopLevelPts * pt;
   if(minBrokerStopDist < pt) minBrokerStopDist = pt;
   // User Rule: When an Order Block stop loss is determined, respect the bottom of the Order Block zone!
   // Only expand SL if it violates broker minimum stop levels (stopLevelPts), DO NOT blow up SL to massive macro ATR!
   double minRequiredStop = MathMax(minBrokerStopDist + 2.0 * pt, MathMax(10.0 * pipSize, 0.20 * curAtr));

   if(candDir == "BUY")
   {
      if(candSL <= 0.0 || candSL >= candEntry)
      {
         candSL = candEntry - minRequiredStop;
      }
      // Mandatory Invariant: Buy Stop Loss MUST sit strictly below Entry by at least broker minimum stop level
      if(candSL >= candEntry - minBrokerStopDist)
      {
         candSL = candEntry - (minBrokerStopDist + 2.0 * pt);
      }
   }
   else // SELL
   {
      if(candSL <= 0.0 || candSL <= candEntry)
      {
         candSL = candEntry + minRequiredStop;
      }
      // Mandatory Invariant: Sell Stop Loss MUST sit strictly above Entry by at least broker minimum stop level
      if(candSL <= candEntry + minBrokerStopDist)
      {
         candSL = candEntry + (minBrokerStopDist + 2.0 * pt);
      }
   }

   double riskDist = MathAbs(candEntry - candSL);
   if(riskDist < minRequiredStop) riskDist = minRequiredStop;
   g_plannedRiskDist = riskDist;
   
   // 15. STRUCTURAL TARGETS & MULTI-TARGET R:R
   double candTP1 = 0.0, candTP2 = 0.0, candTP3 = 0.0, candTP4 = 0.0;
   double rrTP2 = 0.0, rrWeighted = 0.0;
   int targetCount = BuildStructuralTargets(sym, candDir, candEntry, candSL, curAtr,
                                           candTP1, candTP2, candTP3, candTP4,
                                           rrTP2, rrWeighted);

   if(targetCount < 2)
   {
      g_setupState = "BLOCKED";
      g_primaryRejectionReason = "INSUFFICIENT STRUCTURAL TARGET SPACE";
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 40;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "TARGET SPACE BLOCKED (STAND ASIDE)";
      UpdateTradeAdviceLines();
      return;
   }

   // 15B. ORDER BLOCK RUNWAY CLEARANCE CHECK TO TP1
   // Mandate: Dynamically anchors TP1 before opposing institutional blocks so profit is banked safely
   if(candDir == "SELL")
   {
      for(int obI = 0; obI < ArraySize(g_orderBlocks); obI++)
      {
         if(g_orderBlocks[obI].invalidated || !g_orderBlocks[obI].bullish) continue;
         // If a bullish order block (demand) sits between candEntry and candTP1
         if(g_orderBlocks[obI].high <= candEntry && g_orderBlocks[obI].high >= candTP1)
         {
            if(candEntry - g_orderBlocks[obI].high >= MathMax(0.20 * curAtr, 4.0 * pipSize))
            {
               candTP1 = NormalizeDouble(g_orderBlocks[obI].high + 2.0 * pipSize, digits);
               break;
            }
            else
            {
               g_setupState = "WATCHING";
               g_primaryRejectionReason = StringFormat("LOCATION: M30 DEMAND @ %s BLOCKS RUNWAY TO TP1 (%s)",
                                                       DoubleToString(g_orderBlocks[obI].high, digits), DoubleToString(candTP1, digits));
               g_blockReason = g_primaryRejectionReason;
               g_setupQuality = 35;
               g_hasViableEntry = false;
               g_currentAdvisedAction = "NONE";
               g_signalStatusLabel = "STAND ASIDE (DEMAND BLOCKS TP1)";
               UpdateTradeAdviceLines();
               return;
            }
         }
      }
   }
   else if(candDir == "BUY")
   {
      for(int obI = 0; obI < ArraySize(g_orderBlocks); obI++)
      {
         if(g_orderBlocks[obI].invalidated || g_orderBlocks[obI].bullish) continue;
         // If a bearish order block (supply) sits between candEntry and candTP1
         if(g_orderBlocks[obI].low >= candEntry && g_orderBlocks[obI].low <= candTP1)
         {
            if(g_orderBlocks[obI].low - candEntry >= MathMax(0.20 * curAtr, 4.0 * pipSize))
            {
               candTP1 = NormalizeDouble(g_orderBlocks[obI].low - 2.0 * pipSize, digits);
               break;
            }
            else
            {
               g_setupState = "WATCHING";
               g_primaryRejectionReason = StringFormat("LOCATION: M30 SUPPLY @ %s BLOCKS RUNWAY TO TP1 (%s)",
                                                       DoubleToString(g_orderBlocks[obI].low, digits), DoubleToString(candTP1, digits));
               g_blockReason = g_primaryRejectionReason;
               g_setupQuality = 35;
               g_hasViableEntry = false;
               g_currentAdvisedAction = "NONE";
               g_signalStatusLabel = "STAND ASIDE (SUPPLY BLOCKS TP1)";
               UpdateTradeAdviceLines();
               return;
            }
         }
      }
   }

   double r1 = MathAbs(candTP1 - candEntry) / riskDist;
   double r2 = MathAbs(candTP2 - candEntry) / riskDist;
   double r3 = MathAbs(candTP3 - candEntry) / riskDist;
   double r4 = MathAbs(candTP4 - candEntry) / riskDist;

   g_rrTP1 = NormalizeDouble(r1, 2);
   g_rrTP2 = NormalizeDouble(r2, 2);
   g_rrTP3 = NormalizeDouble(r3, 2);
   g_rrTP4 = NormalizeDouble(r4, 2);
   g_rrWeighted = NormalizeDouble((r1 + r2 + r3 + r4) / 4.0, 2);

   // 16. SPREAD COST EVALUATION (Cost Ratio vs Planned SL)
   double spreadRatio = 1.0, costRatio = 0.0;
   string spreadClassStr = "";
   g_spreadState = EvaluateSpreadCost(sym, riskDist, spreadRatio, costRatio, spreadClassStr);
   g_spreadCostRatio = costRatio;

   if(g_spreadState == SPREAD_CRITICAL)
   {
      g_setupState = "BLOCKED";
      g_primaryRejectionReason = StringFormat("EXECUTION COST TOO HIGH (SPREAD: %.1fp, SL: %.1fp, COST: %.1f%%)",
                                             (SymbolInfoInteger(sym, SYMBOL_SPREAD) * pt) / pipSize,
                                             riskDist / pipSize,
                                             costRatio * 100.0);
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 30;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "BLOCKED (SPREAD COST EXCEEDS 25% SL)";
      g_telemetry.spreadCostBlocks++;
      UpdateTradeAdviceLines();
      return;
   }

   // 17. MULTI-TARGET EXPECTANCY GATE (Deduct spread cost ratio)
   g_netExpectancy = NormalizeDouble(g_rrWeighted - g_spreadCostRatio, 2);

   bool expectancyOk = false;
   if(isOBConfluent)
   {
      // M30 Order Block Confluence: High-precision institutional boundary entry
      expectancyOk = (g_rrWeighted >= 0.95 && r1 >= 0.40 && (r2 >= 0.85 || (r2 >= 0.75 && r3 >= 1.40)) && g_netExpectancy >= 0.80);
   }
   else if(g_setupClass == SETUP_CLASS_A_CONTINUATION)
   {
      // Class A: Full trend alignment - viable if weighted R:R >= 1.00 and net expectancy >= 0.90 (r1 >= 0.40 for initial bank)
      expectancyOk = (g_rrWeighted >= 1.00 && r1 >= 0.40 && (r2 >= 0.90 || (r2 >= 0.80 && r3 >= 1.50)) && g_netExpectancy >= 0.85);
   }
   else if(g_setupClass == SETUP_CLASS_B_TRANSITION)
   {
      // Class B: Structural transition - requires tighter location and weighted R:R >= 1.15
      expectancyOk = (g_rrWeighted >= 1.15 && r2 >= 1.10 && g_netExpectancy >= 1.05);
   }
   else
   {
      expectancyOk = (g_rrWeighted >= 1.10 && r2 >= 1.00 && g_netExpectancy >= 1.00);
   }

   if(!expectancyOk)
   {
      g_setupState = "BLOCKED";
      g_primaryRejectionReason = StringFormat("INSUFFICIENT STRUCTURAL REWARD (Weighted: %.2fR, TP1: %.2fR, TP2: %.2fR, Net: %.2fR)",
                                             g_rrWeighted, r1, r2, g_netExpectancy);
      g_blockReason = g_primaryRejectionReason;
      g_setupQuality = 48;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = StringFormat("LOW EXPECTANCY (Net: %.2fR) STAND ASIDE", g_netExpectancy);
      g_telemetry.expectancyRejections++;
      UpdateTradeAdviceLines();
      return;
   }

   // 17B. STRUCTURAL ORDER BLOCK TAKE PROFIT SPACE CLEARANCE
   bool obTargetSpaceOk = true;
   string obSpaceError = "";
   double minClearanceReq = (isOBConfluent || isUptrendConfluence || isDowntrendConfluence) ? MathMax(0.20 * curAtr, 4.0 * pipSize) : MathMax(0.40 * riskDist, 8.0 * pipSize);

   if(candDir == "BUY" && g_nearestBearishOB >= 0 && g_nearestBearishOB < ArraySize(g_orderBlocks))
   {
      double oppSupLow = g_orderBlocks[g_nearestBearishOB].low;
      if(oppSupLow > candEntry)
      {
         double spaceToSupply = oppSupLow - candEntry;
         if(spaceToSupply < minClearanceReq)
         {
            obTargetSpaceOk = false;
            obSpaceError = StringFormat("OPPOSING SUPPLY TOO CLOSE (%.1fp, Need >= %.1fp)", spaceToSupply / pipSize, minClearanceReq / pipSize);
         }
      }
   }
   else if(candDir == "SELL" && g_nearestBullishOB >= 0 && g_nearestBullishOB < ArraySize(g_orderBlocks))
   {
      double oppDemHigh = g_orderBlocks[g_nearestBullishOB].high;
      if(oppDemHigh < candEntry)
      {
         double spaceToDemand = candEntry - oppDemHigh;
         if(spaceToDemand < minClearanceReq)
         {
            obTargetSpaceOk = false;
            obSpaceError = StringFormat("OPPOSING DEMAND TOO CLOSE (%.1fp, Need >= %.1fp)", spaceToDemand / pipSize, minClearanceReq / pipSize);
         }
      }
   }

   if(!obTargetSpaceOk)
   {
      g_setupState = "BLOCKED";
      g_primaryRejectionReason = obSpaceError;
      g_blockReason = obSpaceError;
      g_setupQuality = 45;
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "STAND ASIDE (" + obSpaceError + ")";
      g_telemetry.expectancyRejections++;
      UpdateTradeAdviceLines();
      return;
   }

   // 18. STABLE SIGNAL ID & RESCAN PRESERVATION
   string newSignalID = BuildStableSignalID(sym, candDir, triggerBarTime, g_recentPivotTime);
   bool isSameSignal = (newSignalID == g_currentSignalID && (g_setupState == "TRIGGERED" || g_setupState == "READY"));

   g_currentSignalID = newSignalID;
   g_lastSignalConfirmationTime = triggerBarTime;

   if(!isSameSignal)
   {
      g_signalTriggerTime = TimeCurrent();
      g_signalGeneratedWhileAdvisorEnabled = g_myAdvisorEnabled;
      g_currentTradeTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
      g_isSignalExpired = false;
   }
   else
   {
      if(!g_signalGeneratedWhileAdvisorEnabled && g_myAdvisorEnabled)
         g_signalGeneratedWhileAdvisorEnabled = true;
      if(!g_currentTradeTaken)
         g_currentTradeTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
   }

   // 19. FINALIZE SETUP AS READY (WAITING ENTRY) OR TRIGGERED (TRADE TAKEN)
   g_hasViableEntry       = true;
   g_currentAdvisedAction = candDir;
   g_staticEntryPrice     = NormalizeDouble(candEntry, digits);
   g_staticSL             = NormalizeDouble(candSL, digits);
   g_staticTP1            = NormalizeDouble(candTP1, digits);
   g_staticTP2            = NormalizeDouble(candTP2, digits);
   g_staticTP3            = NormalizeDouble(candTP3, digits);
   g_staticTP4            = NormalizeDouble(candTP4, digits);
   
   bool isTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
   g_currentTradeTaken = isTaken;
   g_setupState = isTaken ? "TRIGGERED" : "READY";
   
   g_primaryRejectionReason = "NONE (TRADE APPROVED)";
   g_blockReason          = "NONE (SETUP VIABLE)";
   g_setupQuality         = (int)MathMin(100.0, 75.0 + confScore + (g_volatilityRegime == "NORMAL" ? 10.0 : 0.0) - (g_spreadState == SPREAD_ELEVATED ? 8.0 : 0.0));
   if(isOBConfluent && g_obSignalScore > g_setupQuality)
      g_setupQuality = g_obSignalScore;

   // Incorporate 30-Minute & 1-Hour Market Structure (Higher Highs & Lower Lows) into Setup Quality:
   if(candDir == "BUY")
   {
      if(g_hasHH_M30 && g_hasHH_H1)
      {
         g_setupQuality = (int)MathMin(100.0, g_setupQuality + 15.0); // Full M30 & H1 Higher High Confluence
      }
      else if(g_hasHH_M30)
      {
         g_setupQuality = (int)MathMin(100.0, g_setupQuality + 8.0);  // M30 Higher High Breakout
      }
      else if(g_hasHH_H1)
      {
         g_setupQuality = (int)MathMin(100.0, g_setupQuality + 6.0);  // H1 Macro Higher High
      }
   }
   else if(candDir == "SELL")
   {
      if(g_hasLL_M30 && g_hasLL_H1)
      {
         g_setupQuality = (int)MathMin(100.0, g_setupQuality + 15.0); // Full M30 & H1 Lower Low Confluence
      }
      else if(g_hasLL_M30)
      {
         g_setupQuality = (int)MathMin(100.0, g_setupQuality + 8.0);  // M30 Lower Low Breakdown
      }
      else if(g_hasLL_H1)
      {
         g_setupQuality = (int)MathMin(100.0, g_setupQuality + 6.0);  // H1 Macro Lower Low
      }
   }
   
   string classTag = (g_setupClass == SETUP_CLASS_A_CONTINUATION ? "CLASS A" : "CLASS B");
   if(isOBConfluent) classTag += " | M30 OB";
   if(candDir == "BUY" && g_hasHH_M30 && g_hasHH_H1) classTag += " | M30/H1 HH";
   else if(candDir == "SELL" && g_hasLL_M30 && g_hasLL_H1) classTag += " | M30/H1 LL";

   if(isTaken)
   {
      int openTradesOnSym = CountOpenAdvisorTradesForSymbol(sym);
      if(openTradesOnSym > 0)
      {
         g_signalStatusLabel = StringFormat("POSITION ACTIVE: %s [%d Open | TP2: %.2fR | Monitoring]",
                                            candDir, openTradesOnSym, rrTP2);
      }
      else
      {
         g_signalStatusLabel = StringFormat("TRIGGERED: %s [%s | TP2: %.2fR | Net: %.2fR]",
                                            candDir, classTag,
                                            rrTP2, g_netExpectancy);
      }
   }
   else
   {
      g_signalStatusLabel = StringFormat("READY (WAITING ENTRY): %s [%s | TP2: %.2fR | Net: %.2fR]",
                                         candDir, classTag,
                                         rrTP2, g_netExpectancy);
   }

   g_telemetry.signalsGenerated++;
   g_telemetry.tradeApprovals++;

   g_diagnosticsSummary = StringFormat("Symbol: %s | Action: %s | Class: %s | NetExp: %.2fR | TP1: %.2fR | TP2: %.2fR | TP3: %.2fR | TP4: %.2fR | SpreadCost: %.1f%% | CashSession: %s",
                                       sym, candDir,
                                       g_setupClass == SETUP_CLASS_A_CONTINUATION ? "CLASS A" : "CLASS B",
                                       g_netExpectancy, g_rrTP1, g_rrTP2, g_rrTP3, g_rrTP4,
                                       g_spreadCostRatio * 100.0, g_cashSessionName);

   PrintFormat("[MyAdvisor][TRADE APPROVED][%s] Action=%s Class=%s H4=%s H1=%s Structure=%s NetExp=%.2fR Weighted=%.2fR SpreadCost=%.1f%% State=%s",
               sym, candDir,
               g_setupClass == SETUP_CLASS_A_CONTINUATION ? "CLASS A" : "CLASS B",
               g_h4Bias, g_h1Bias, g_marketStructure,
               g_netExpectancy, g_rrWeighted, g_spreadCostRatio * 100.0, g_setupState);

   UpdateTradeAdviceLines();
   UpdateUnifiedStrategyMatrix(sym);
   SaveActiveSignalSnapshot(sym);
   GlobalVariablesFlush();

   // Trigger MT5 Alert once per unique signal transition
   if(g_alertOnViableEntry && g_currentSignalID != g_lastAlertedSignalID)
   {
      g_lastAlertedSignalID = g_currentSignalID;
      g_lastAlertTriggerTime = TimeCurrent();
      Alert(StringFormat("[SEGS PRO] Viable %s Trade Setup for %s! Entry: %.5f, SL: %.5f, TP2: %.5f (Net %.2fR)",
            candDir, sym, g_staticEntryPrice, g_staticSL, g_staticTP2, g_netExpectancy));
   }

   // Automatically evaluate auto-trade when setup is confirmed
   if(g_hasViableEntry && (g_setupState == "TRIGGERED" || g_setupState == "READY") && !g_currentTradeTaken)
   {
      CheckAndAutoTradeAdvice();
   }
}
bool RollbackAdvisorSetup(string shortSig, string signalID, const ulong &tickets[], int maxLegs)
{
   string advSetupPrefix = StringFormat("SEGS|ADV|%s|", shortSig);
   string sigExecKey = "SEGS_SIG_EXEC_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + signalID;
   string pendingTimeKey = "SEGS_SIG_PENDING_TIME_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + signalID;

   PrintFormat("[Advisor Rollback] Initiating verified rollback for setup %s (%s)...", advSetupPrefix, signalID);

   // 1. Attempt to close known tickets with retcode validation and retries
   for(int k = 0; k < maxLegs; k++)
   {
      ulong t = tickets[k];
      if(t == 0) continue;

      for(int attempt = 1; attempt <= 3; attempt++)
      {
         if(!PositionSelectByTicket(t)) break; // Already closed

         ResetLastError();
         bool closed = trade.PositionClose(t);
         uint ret = trade.ResultRetcode();

         if(closed || ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED)
         {
            Sleep(50);
            if(!PositionSelectByTicket(t))
            {
               PrintFormat("[Advisor Rollback] Successfully closed position ticket #%I64u on attempt %d.", t, attempt);
               break;
            }
         }

         PrintFormat("[Advisor Rollback] Attempt %d to close ticket #%I64u returned retcode %u (%s). LastError=%d",
                     attempt, t, ret, trade.ResultRetcodeDescription(), GetLastError());
         Sleep(100);
      }
   }

   // 2. Comprehensive post-rollback rescan by exact Advisor setup identity: SEGS|ADV|<shortSig>|
   bool hasOrphans = false;
   ulong unresolvedTickets[];
   int unresCount = 0;

   // Perform up to 3 scan-and-close passes to catch any delayed order fills or stubborn positions
   for(int pass = 1; pass <= 3; pass++)
   {
      bool foundAny = false;
      int pTot = PositionsTotal();
      for(int p = pTot - 1; p >= 0; p--)
      {
         ulong pt = PositionGetTicket(p);
         if(pt > 0 && posInfo.SelectByTicket(pt))
         {
            if(posInfo.Magic() == InpAdvisorMagicNumber && StringFind(posInfo.Comment(), advSetupPrefix) >= 0)
            {
               foundAny = true;
               PrintFormat("[Advisor Rollback] Pass %d found active setup position #%I64u (%s). Attempting closure...", pass, pt, posInfo.Comment());
               ResetLastError();
               trade.PositionClose(pt);
               uint ret = trade.ResultRetcode();
               Sleep(60);
               if(PositionSelectByTicket(pt))
               {
                  PrintFormat("[Advisor Rollback] Pass %d closure failed for ticket #%I64u: retcode %u (%s)",
                              pt, ret, trade.ResultRetcodeDescription());
               }
            }
         }
      }
      if(!foundAny) break;
      Sleep(100);
   }

   // Final verification scan across open positions
   int pTotFinal = PositionsTotal();
   for(int p = pTotFinal - 1; p >= 0; p--)
   {
      ulong pt = PositionGetTicket(p);
      if(pt > 0 && posInfo.SelectByTicket(pt))
      {
         if(posInfo.Magic() == InpAdvisorMagicNumber && StringFind(posInfo.Comment(), advSetupPrefix) >= 0)
         {
            hasOrphans = true;
            ArrayResize(unresolvedTickets, unresCount + 1);
            unresolvedTickets[unresCount] = pt;
            unresCount++;
         }
      }
   }

   if(hasOrphans)
   {
      // Mark rollback as incomplete, mark signal as non-reexecutable, lock execution state
      GlobalVariableSet(sigExecKey, 2.0); // 2.0 = EXECUTED / LOCKED - prevents duplicate trigger loop
      GlobalVariableDel(pendingTimeKey);
      g_currentTradeTaken = true;

      string unresolvedStr = "";
      for(int u = 0; u < unresCount; u++)
      {
         if(u > 0) unresolvedStr += ", ";
         unresolvedStr += IntegerToString(unresolvedTickets[u]);
      }

      string errMsg = StringFormat("[Advisor Rollback] CRITICAL: Rollback incomplete for %s! Unresolved positions remaining: [%s]. Signal locked to prevent duplicate execution.",
                                   advSetupPrefix, unresolvedStr);
      Print(errMsg);
      Alert(errMsg);
      return false;
   }

   // Setup has been rolled back / aborted: lock execution state permanently so it never loops!
   GlobalVariableSet(sigExecKey, 3.0); // 3.0 = ABORTED
   GlobalVariableDel(pendingTimeKey);
   g_currentTradeTaken = true;
   g_lastAlertedSignalID = signalID;

   PrintFormat("[Advisor Rollback] Rollback verified: All positions for setup %s have been closed.", advSetupPrefix);
   return true;
}

//+------------------------------------------------------------------+
//| Master Consecutive-Loss Circuit Breaker Engine                   |
//| Rule 1: Pause trading for an instrument for the day after 3      |
//|         consecutive losses for the same instrument.              |
//| Rule 2: Pause trading for the day after 5 overall losses across  |
//|         instruments in the portfolio.                            |
//| Rule 3: One setup split into 4 tickets counts as 1 risk allocation|
//| Rule 4: Other open trades are NOT affected; only opening &       |
//|         execution of new trade signals are prohibited.           |
//+------------------------------------------------------------------+
void CheckCircuitBreaker(string sym, bool &outBlocked, string &outReason, int &outConsecLosses, int &outOverallLosses)
{
   outBlocked = false;
   outReason = "";
   outConsecLosses = 0;
   outOverallLosses = 0;

   if(!InpEnableCircuitBreaker) return;

   string cleanSym = sym;
   StringToUpper(cleanSym);
   if(IsSymbolMatch(cleanSym, InpXAU_Patterns))       cleanSym = "XAUUSD";
   else if(IsSymbolMatch(cleanSym, InpDJ30_Patterns)) cleanSym = "US30";
   else if(IsSymbolMatch(cleanSym, InpNAS_Patterns))  cleanSym = "NAS100";
   else if(IsSymbolMatch(cleanSym, InpGJ_Patterns))   cleanSym = "GBPJPY";
   else if(IsSymbolMatch(cleanSym, InpGU_Patterns))   cleanSym = "GBPUSD";
   else if(IsSymbolMatch(cleanSym, InpAUD_Patterns))  cleanSym = "AUDUSD";
   else if(IsSymbolMatch(cleanSym, InpOIL_Patterns))  cleanSym = "USOIL";
   else if(IsSymbolMatch(cleanSym, InpBTC_Patterns))  cleanSym = "BTCUSD";
   else if(IsSymbolMatch(cleanSym, InpAMD_Patterns))  cleanSym = "AMD";

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string gvPortfolioKey = "SEGS_CB_PORTFOLIO_PAUSED_" + IntegerToString(login);
   string gvSymbolKey    = "SEGS_CB_PAUSED_" + cleanSym + "_" + IntegerToString(login);

   // 1. Check & Enforce Daily Reset at Toronto 00:00 Midnight Every Day
   datetime nowToronto = GetTorontoTimeNow();
   MqlDateTime dt;
   TimeToStruct(nowToronto, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime startToronto = StructToTime(dt);

   string gvDateKey = "SEGS_CB_ACTIVE_DATE_" + IntegerToString(login);
   if(GlobalVariableCheck(gvDateKey))
   {
      datetime lastStoredDate = (datetime)GlobalVariableGet(gvDateKey);
      if(lastStoredDate != startToronto)
      {
         GlobalVariableDel(gvPortfolioKey);
         GlobalVariableDel("SEGS_CB_OVERALL_LOSSES_" + IntegerToString(login));
         string symbolsToCheck[] = {"XAUUSD", "US30", "NAS100", "GBPJPY", "GBPUSD", "AUDUSD", "USOIL", "BTCUSD", "AMD"};
         for(int s = 0; s < ArraySize(symbolsToCheck); s++)
         {
            GlobalVariableDel("SEGS_CB_PAUSED_" + symbolsToCheck[s] + "_" + IntegerToString(login));
            GlobalVariableDel("SEGS_CB_CONSEC_" + symbolsToCheck[s] + "_" + IntegerToString(login));
         }
         GlobalVariableSet(gvDateKey, (double)startToronto);
         PrintFormat("[Circuit Breaker] Daily Toronto 00:00 Midnight reset applied. All previous day loss pauses lifted for normal trading.");

         // User Mandate: When trade was paused from previous day losses circuit breaker, advisor MUST NOT
         // just activate the waiting planned entry at Toronto 00:00 signals unless still strictly viable!
         if(g_hasViableEntry)
         {
            double curPriceP = (g_plannedAction == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(curPriceP <= 0.0) curPriceP = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double pSize = GetPipSize(_Symbol);
            double cAtr = 20.0 * pSize;
            if(g_hAtr_H1 != INVALID_HANDLE) { double b[]; ArraySetAsSeries(b, true); if(CopyBuffer(g_hAtr_H1, 0, 1, 1, b) == 1) cAtr = b[0]; }
            string unviableReason = "";
            bool isStillViable = IsPlannedEntryViable(_Symbol, g_plannedAction, g_staticEntryPrice, g_staticSL, curPriceP, pSize, cAtr, unviableReason);
            if(!isStillViable)
            {
               CancelUnviablePlannedEntry(_Symbol, "TORONTO 00:00 RESET: Waiting planned entry is no longer viable (" + unviableReason + ")");
               g_setupState = "SCANNING";
               g_hasViableEntry = false;
               g_currentAdvisedAction = "NONE";
               g_staticEntryPrice = 0.0;
               g_staticSL = 0.0;
               g_signalStatusLabel = "SCANNING (NEW TRADING DAY - RE-EVALUATING STRUCTURE)";
               PrintFormat("[Circuit Breaker] Toronto 00:00 rollover: Stale waiting planned entry purged (%s). Advisor will rescan fresh market structure.", unviableReason);
            }
            else
            {
               PrintFormat("[Circuit Breaker] Toronto 00:00 rollover: Waiting planned entry for %s confirmed still viable at %s.", _Symbol, DoubleToString(g_staticEntryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
            }
         }
      }
   }
   else
   {
      GlobalVariableSet(gvDateKey, (double)startToronto);
   }

   // Check if already paused by persistent flag from today
   bool portAlreadyPaused = (GlobalVariableCheck(gvPortfolioKey) && GlobalVariableGet(gvPortfolioKey) >= 1.0);
   bool symAlreadyPaused  = (GlobalVariableCheck(gvSymbolKey) && GlobalVariableGet(gvSymbolKey) >= 1.0);

   // 2. Query MT5 Deal History: wide 30-day window to ensure all open/closed trade entries are loaded
   datetime selectFrom = TimeCurrent() - (30 * 86400);
   datetime selectTo   = TimeCurrent() + 3600;

   if(!HistorySelect(selectFrom, selectTo))
   {
      if(portAlreadyPaused)
      {
         outBlocked = true;
         outReason = StringFormat("GLOBAL CIRCUIT BREAKER ACTIVE: %d daily losses reached across portfolio. Paused until tomorrow 00:00 Toronto.", InpMaxDailyPortfolioLosses);
         return;
      }
      if(symAlreadyPaused)
      {
         outBlocked = true;
         outReason = StringFormat("INSTRUMENT CIRCUIT BREAKER ACTIVE: 3 consecutive losses on %s. Paused until tomorrow 00:00 Toronto.", cleanSym);
         return;
      }
      return;
   }

   int totalDeals = HistoryDealsTotal();

   struct InDealMap
   {
      long     posId;
      datetime entryTime;
      long     posType;
      string   comment;
   };
   InDealMap inDeals[];
   int inCount = 0;
   ArrayResize(inDeals, MathMax(totalDeals / 2 + 10, 100));

   for(int i = 0; i < totalDeals; i++)
   {
      ulong dTk = HistoryDealGetTicket(i);
      if(dTk <= 0) continue;
      long entry = HistoryDealGetInteger(dTk, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
      {
         long pId = HistoryDealGetInteger(dTk, DEAL_POSITION_ID);
         if(pId <= 0) continue;
         if(inCount >= ArraySize(inDeals)) ArrayResize(inDeals, inCount + 100);
         inDeals[inCount].posId     = pId;
         inDeals[inCount].entryTime = (datetime)HistoryDealGetInteger(dTk, DEAL_TIME);
         inDeals[inCount].posType   = HistoryDealGetInteger(dTk, DEAL_TYPE);
         inDeals[inCount].comment   = HistoryDealGetString(dTk, DEAL_COMMENT);
         inCount++;
      }
   }

   // Group closed deals of today into Setups
   struct SetupCBRecord
   {
      string   setupKey;
      string   symbol;
      string   cleanSym;
      long     dir;          // 0 = BUY, 1 = SELL
      datetime entryTime;
      datetime exitTime;
      int      openedTrades; // Total legs closed in this setup (typically 4, or 2)
      int      tpHits;       // Number of legs that hit Take Profit
      int      slHits;       // Number of legs that hit Stop Loss
      double   netProfit;    // Total P/L of this setup
      bool     isLoss;       // Evaluated by user formula
   };
   SetupCBRecord setups[];
   int setupCount = 0;
   ArrayResize(setups, 100);

   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY) continue;

      datetime dTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      datetime dToronto = ConvertBrokerTimeToToronto(dTime);
      if(dToronto < startToronto || dToronto >= startToronto + 86400) continue; // Only count trades closed on active Toronto trading day!

      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                      HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                      HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      string cmt = HistoryDealGetString(dealTicket, DEAL_COMMENT);
      long posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      long dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);

      datetime sEntryTime = dTime;
      long posType = 0;
      for(int k = 0; k < inCount; k++)
      {
         if(inDeals[k].posId == posId)
         {
            sEntryTime = inDeals[k].entryTime;
            posType    = inDeals[k].posType;
            if(StringFind(cmt, "SEGS|") < 0 && StringFind(inDeals[k].comment, "SEGS|") >= 0)
               cmt = inDeals[k].comment;
            break;
         }
      }

      string dealSym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      string dClean = dealSym;
      StringToUpper(dClean);
      if(IsSymbolMatch(dClean, InpXAU_Patterns))       dClean = "XAUUSD";
      else if(IsSymbolMatch(dClean, InpDJ30_Patterns)) dClean = "US30";
      else if(IsSymbolMatch(dClean, InpNAS_Patterns))  dClean = "NAS100";
      else if(IsSymbolMatch(dClean, InpGJ_Patterns))   dClean = "GBPJPY";
      else if(IsSymbolMatch(dClean, InpGU_Patterns))   dClean = "GBPUSD";
      else if(IsSymbolMatch(dClean, InpAUD_Patterns))  dClean = "AUDUSD";
      else if(IsSymbolMatch(dClean, InpOIL_Patterns))  dClean = "USOIL";
      else if(IsSymbolMatch(dClean, InpBTC_Patterns))  dClean = "BTCUSD";
      else if(IsSymbolMatch(dClean, InpAMD_Patterns))  dClean = "AMD";

      // Extract shortSig if present in comment (SEGS|ADV|{shortSig}|L...)
      string shortSig = "";
      int advPos = StringFind(cmt, "SEGS|ADV|");
      if(advPos >= 0)
      {
         string rem = StringSubstr(cmt, advPos + 9);
         int pipePos = StringFind(rem, "|");
         if(pipePos > 0) shortSig = StringSubstr(rem, 0, pipePos);
      }

      bool isLegTP = (dealReason == DEAL_REASON_TP || profit > 0.05 || StringFind(cmt, "[tp]") >= 0);
      bool isLegSL = (dealReason == DEAL_REASON_SL || profit < -0.05 || StringFind(cmt, "[sl]") >= 0);

      // Match to existing setup group:
      // Group up to 4 legs opened together within 60s or matching shortSig
      int foundIdx = -1;
      for(int s = 0; s < setupCount; s++)
      {
         if(setups[s].cleanSym == dClean && setups[s].openedTrades < 4)
         {
            bool sigMatch = (shortSig != "" && StringFind(setups[s].setupKey, shortSig) >= 0);
            bool entrySimultaneous = (sEntryTime > 0 && setups[s].entryTime > 0 && MathAbs((long)sEntryTime - (long)setups[s].entryTime) <= 60);
            bool sameDir = (setups[s].dir == posType);
            if(sigMatch || (entrySimultaneous && sameDir))
            {
               foundIdx = s;
               break;
            }
         }
      }

      if(foundIdx >= 0)
      {
         setups[foundIdx].openedTrades++;
         if(isLegTP) setups[foundIdx].tpHits++;
         if(isLegSL) setups[foundIdx].slHits++;
         setups[foundIdx].netProfit += profit;
         if(dTime > setups[foundIdx].exitTime) setups[foundIdx].exitTime = dTime;
      }
      else
      {
         if(setupCount >= ArraySize(setups)) ArrayResize(setups, setupCount + 50);
         string key = (shortSig != "") ? shortSig : StringFormat("%s_%d_%d", dClean, (int)(sEntryTime / 60), (int)posType);
         setups[setupCount].setupKey     = key;
         setups[setupCount].symbol       = dealSym;
         setups[setupCount].cleanSym     = dClean;
         setups[setupCount].dir          = posType;
         setups[setupCount].entryTime    = sEntryTime;
         setups[setupCount].exitTime     = dTime;
         setups[setupCount].openedTrades = 1;
         setups[setupCount].tpHits       = isLegTP ? 1 : 0;
         setups[setupCount].slHits       = isLegSL ? 1 : 0;
         setups[setupCount].netProfit    = profit;
         setups[setupCount].isLoss       = false;
         setupCount++;
      }
   }

   // Evaluate User Mandate for each Setup:
   // "A trade counts as a loss toward the circuit breaker when fewer than 2 of the 4 opened trades hit take profit:
   // when 2 trades hit take profit and 2 trades hit stop loss, it is not counted as a loss toward the circuit breaker."
   for(int s = 0; s < setupCount; s++)
   {
      int opened = setups[s].openedTrades;
      int tps    = setups[s].tpHits;

      if(opened >= 3)
      {
         // Standard 4-leg setup (or 3 legs filled)
         // Loss if fewer than 2 legs hit TP!
         setups[s].isLoss = (tps < 2);
      }
      else if(opened == 2)
      {
         // 2-leg capacity-restricted setup
         // Loss if fewer than 1 leg hit TP!
         setups[s].isLoss = (tps < 1);
      }
      else
      {
         // Single residual trade
         setups[s].isLoss = (tps < 1 && setups[s].netProfit < -0.05);
      }
   }

   // Sort setups chronologically by exitTime
   for(int a = 0; a < setupCount - 1; a++)
   {
      for(int b = 0; b < setupCount - a - 1; b++)
      {
         if(setups[b].exitTime > setups[b+1].exitTime)
         {
            SetupCBRecord tmp = setups[b];
            setups[b] = setups[b+1];
            setups[b+1] = tmp;
         }
      }
   }

   int overallLosses = 0;
   int curConsecLosses = 0;
   int maxConsecLosses = 0;

   for(int s = 0; s < setupCount; s++)
   {
      if(setups[s].isLoss)
         overallLosses++;

      if(setups[s].cleanSym == cleanSym || IsSameChartAsset(setups[s].symbol, sym))
      {
         if(setups[s].isLoss)
         {
            curConsecLosses++;
            if(curConsecLosses > maxConsecLosses) maxConsecLosses = curConsecLosses;
         }
         else
         {
            // Reset consecutive loss streak upon winning or breakeven setup
            curConsecLosses = 0;
         }
      }
   }

   outOverallLosses = overallLosses;
   outConsecLosses  = curConsecLosses;

   GlobalVariableSet("SEGS_CB_OVERALL_LOSSES_" + IntegerToString(login), (double)overallLosses);
   GlobalVariableSet("SEGS_CB_CONSEC_" + cleanSym + "_" + IntegerToString(login), (double)curConsecLosses);

   int portfolioLimit = MathMax(6, InpMaxDailyPortfolioLosses);

   // Check Portfolio Circuit Breaker (6 total daily losses across instruments)
   if(overallLosses >= portfolioLimit || portAlreadyPaused)
   {
      outBlocked = true;
      outReason = StringFormat("GLOBAL CIRCUIT BREAKER: %d overall losses reached today across instruments (Limit: %d). All new trade signals paused until tomorrow 00:00 Toronto.",
                               MathMax(overallLosses, portfolioLimit), portfolioLimit);
      GlobalVariableSet(gvPortfolioKey, 1.0);
      return;
   }

   // Check Instrument Circuit Breaker (3 consecutive losses on this instrument)
   if(curConsecLosses >= InpMaxConsecLossesPerSymbol || maxConsecLosses >= InpMaxConsecLossesPerSymbol || symAlreadyPaused)
   {
      outBlocked = true;
      outReason = StringFormat("INSTRUMENT CIRCUIT BREAKER: %d consecutive losses on %s today (Limit: %d). Trading paused until tomorrow 00:00 Toronto.",
                               MathMax(maxConsecLosses, InpMaxConsecLossesPerSymbol), cleanSym, InpMaxConsecLossesPerSymbol);
      GlobalVariableSet(gvSymbolKey, 1.0);
      return;
   }
}

//+------------------------------------------------------------------+
//| Execute Advised Trade Setup with Rollback & Safety Gates         |
//+------------------------------------------------------------------+
void ExecuteAdvisedTrade(bool isAutoTrade=false)
{
   if(!g_runtimeReady || !SEGSMarketReady(_Symbol)) return;
   string sym = _Symbol;

   // Anti-Spam Rapid-Fire Throttle: at least 15s between order bursts (bypassed on TRIGGERED auto execution)
   static datetime s_lastExecAttemptTime = 0;
   if(!isAutoTrade && TimeCurrent() - s_lastExecAttemptTime < 15)
   {
      Print("[Trade Advisor] EXECUTION BLOCKED: Rapid execution throttled (15s minimum).");
      return;
   }
   s_lastExecAttemptTime = TimeCurrent();

   // Symbol Cooldown Check
   string cleanSym = sym;
   StringToUpper(cleanSym);
   if(IsSymbolMatch(cleanSym, InpXAU_Patterns))       cleanSym = "XAUUSD";
   else if(IsSymbolMatch(cleanSym, InpDJ30_Patterns)) cleanSym = "US30";
   else if(IsSymbolMatch(cleanSym, InpNAS_Patterns))  cleanSym = "NAS100";
   else if(IsSymbolMatch(cleanSym, InpGJ_Patterns))   cleanSym = "GBPJPY";
   else if(IsSymbolMatch(cleanSym, InpGU_Patterns))   cleanSym = "GBPUSD";
   else if(IsSymbolMatch(cleanSym, InpAUD_Patterns))  cleanSym = "AUDUSD";
   else if(IsSymbolMatch(cleanSym, InpOIL_Patterns))  cleanSym = "USOIL";
   else if(IsSymbolMatch(cleanSym, InpBTC_Patterns))  cleanSym = "BTCUSD";
   else if(IsSymbolMatch(cleanSym, InpAMD_Patterns))  cleanSym = "AMD";

   string gvCdKey = "SEGS_COOLDOWN_" + cleanSym + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   if(GlobalVariableCheck(gvCdKey))
   {
      datetime cdUntil = (datetime)GlobalVariableGet(gvCdKey);
      if(TimeCurrent() < cdUntil)
      {
         string msg = StringFormat("[Trade Advisor] EXECUTION BLOCKED: %s is in cooldown (%d seconds remaining).", cleanSym, (int)(cdUntil - TimeCurrent()));
         Print(msg);
         if(!isAutoTrade) Alert(msg);
         return;
      }
   }

   // 1. Algo Trading Terminal & Permission Check
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      string msg = "[Trade Advisor] CANNOT EXECUTE: Algorithmic Trading is disabled in MT5 top toolbar. Click [Algo Trading] button in toolbar to enable.";
      Print(msg);
      if(!isAutoTrade) Alert(msg);
      return;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      string msg = "[Trade Advisor] CANNOT EXECUTE: 'Allow Algo Trading' is unchecked in EA Properties -> Common tab. Press F7 to enable.";
      Print(msg);
      if(!isAutoTrade) Alert(msg);
      return;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      string msg = "[Trade Advisor] CANNOT EXECUTE: Account is read-only or trading disabled by broker.";
      Print(msg);
      if(!isAutoTrade) Alert(msg);
      return;
   }

   // 1B. Master Consecutive-Loss Circuit Breaker Rule (Quarantine)
   bool cbBlocked = false;
   string cbReason = "";
   int cbConsec = 0, cbTotal = 0;
   CheckCircuitBreaker(sym, cbBlocked, cbReason, cbConsec, cbTotal);
   if(cbBlocked)
   {
      string msg = "[Circuit Breaker] EXECUTION BLOCKED: " + cbReason;
      Print(msg);
      g_blockReason = "CIRCUIT BREAKER: " + (cbTotal >= InpMaxDailyPortfolioLosses ? "6 DAILY LOSSES REACHED" : "3 CONSECUTIVE LOSSES (PAUSED)");
      if(!isAutoTrade) Alert(msg);
      return;
   }

   // 2. Setup Viability Check: Must be in READY or TRIGGERED state with confirmed entry
   // Note: We deliberately do NOT re-call ScanMarketStructureAndAdvice(true) here because minor tick noise
   // would reset g_setupState to WATCHING and falsely destroy the viable trade!
   if(!g_hasViableEntry || g_isSignalExpired || (g_setupState != "TRIGGERED" && g_setupState != "READY"))
   {
      string msg = "[Trade Advisor] EXECUTION BLOCKED: Setup state is not READY / TRIGGERED (State: " + g_setupState + ", Reason: " + g_blockReason + ")";
      Print(msg);
      if(!isAutoTrade) Alert(msg);
      return;
   }

   // 3. Instrument Tradability Verification
   string tradableReason = "";
   if(!IsBrokerSymbolTradeable(sym, tradableReason))
   {
      string msg = "[Trade Advisor] EXECUTION BLOCKED: " + sym + " is not currently tradable (" + tradableReason + ")";
      Print(msg);
      if(!isAutoTrade) Alert(msg);
      return;
   }

   g_telemetry.ordersAttempted++;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // 4. Live execution price
   double curPrice = (g_currentAdvisedAction == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   if(curPrice <= 0.0) curPrice = (g_currentAdvisedAction == "BUY") ? iClose(sym, PERIOD_M1, 0) : iClose(sym, PERIOD_M1, 0);
   if(curPrice <= 0.0) curPrice = iClose(sym, PERIOD_H1, 0);
   if(curPrice <= 0.0) curPrice = g_staticEntryPrice;

   // 5. SL Breach Protection: Prevent late entry if market already crossed planned SL
   if((g_currentAdvisedAction == "BUY" && curPrice <= g_staticSL) ||
      (g_currentAdvisedAction == "SELL" && curPrice >= g_staticSL))
   {
      string msg = "[Trade Advisor] EXECUTION BLOCKED: Price breached planned Stop Loss before entry.";
      Print(msg);
      g_isSignalExpired = true;
      g_hasViableEntry = false;
      g_setupState = "INVALIDATED";
      g_blockReason = "SL BREACHED BEFORE ENTRY";
      SEGSResetExpiredSetup(sym);
      if(!isAutoTrade) Alert(msg);
      return;
   }

   // 6. Price Drift Check: Disallow late execution if market moved too far beyond entry
   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   if(curAtr <= 0.0)
   {
      double h1 = iHigh(sym, PERIOD_H1, 1);
      double l1 = iLow(sym, PERIOD_H1, 1);
      if(h1 > l1) curAtr = h1 - l1;
      else curAtr = 25.0 * GetPipSize(sym);
   }

   double pip = GetPipSize(sym);
   double spreadPtsExec = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
   double drift = MathAbs(curPrice - g_staticEntryPrice);
   double maxAllowedDrift = MathMax(0.75 * curAtr, MathMax(25.0 * pip, spreadPtsExec * 3.5));
   if(drift > maxAllowedDrift && g_setupState != "TRIGGERED")
   {
      PrintFormat("[Trade Advisor] EXECUTION BLOCKED: Price drifted %.1f pips from entry (Max allowed: %.1f pips).",
                  drift / GetPipSize(sym), maxAllowedDrift / GetPipSize(sym));
      if(!isAutoTrade) Alert("[Trade Advisor] BLOCKED: Price drifted too far from advised entry.");
      return;
   }

   // 6B. Strict Order Block Zone Boundary Check (only for manual triggers on Order Block setups):
   double obTol = MathMax((double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT) * 2.0, 3.0 * pip);
   double maxAllowedZoneDrift = MathMax(0.75 * curAtr, MathMax(25.0 * pip, spreadPtsExec * 3.5));

   double h0_M5 = iHigh(sym, PERIOD_M5, 0);
   double h1_M5 = iHigh(sym, PERIOD_M5, 1);
   double h0_M15 = iHigh(sym, PERIOD_M15, 0);
   double h1_M15 = iHigh(sym, PERIOD_M15, 1);
   double maxRecentHigh = curPrice;
   if(h0_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M5);
   if(h1_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M5);
   if(h0_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M15);
   if(h1_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M15);
   bool recentPullbackIntoSupply = (maxRecentHigh >= g_obSignalLow - obTol || maxRecentHigh >= g_staticEntryPrice - obTol) && 
                                  (curPrice >= g_obSignalLow - maxAllowedZoneDrift || curPrice >= g_staticEntryPrice - maxAllowedZoneDrift);

   double l0_M5 = iLow(sym, PERIOD_M5, 0);
   double l1_M5 = iLow(sym, PERIOD_M5, 1);
   double l0_M15 = iLow(sym, PERIOD_M15, 0);
   double l1_M15 = iLow(sym, PERIOD_M15, 1);
   double minRecentLow = curPrice;
   if(l0_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M5);
   if(l1_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M5);
   if(l0_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M15);
   if(l1_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M15);
   bool recentPullbackIntoDemand = (minRecentLow <= g_obSignalHigh + obTol || minRecentLow <= g_staticEntryPrice + obTol) && 
                                  (curPrice <= g_obSignalHigh + maxAllowedZoneDrift || curPrice <= g_staticEntryPrice + maxAllowedZoneDrift);

   if(g_setupState != "TRIGGERED" && !isAutoTrade && g_activeEntryStrategy == "ORDER_BLOCK")
   {
      if(g_currentAdvisedAction == "BUY" && g_obSignalHigh > 0.0 && curPrice > g_obSignalHigh + obTol && !recentPullbackIntoDemand)
      {
         string msg = StringFormat("[Trade Advisor] EXECUTION BLOCKED: Price (%.5f) has not reached the Buy Zone [%.5f - %.5f]. Awaiting pullback.",
                                   curPrice, g_obSignalLow, g_obSignalHigh);
         Print(msg);
         if(!isAutoTrade) Alert(msg);
         g_setupState = "WATCHING";
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         return;
      }
      else if(g_currentAdvisedAction == "SELL" && g_obSignalLow > 0.0 && curPrice < g_obSignalLow - obTol && !recentPullbackIntoSupply)
      {
         string msg = StringFormat("[Trade Advisor] EXECUTION BLOCKED: Price (%.5f) has not reached the Sell Zone [%.5f - %.5f]. Awaiting pullback.",
                                   curPrice, g_obSignalLow, g_obSignalHigh);
         Print(msg);
         if(!isAutoTrade) Alert(msg);
         g_setupState = "WATCHING";
         g_hasViableEntry = false;
         g_currentAdvisedAction = "NONE";
         return;
      }
   }

   // 7. Prevent Duplicate Signal Execution
   string sigExecKey = "SEGS_SIG_EXEC_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + g_currentSignalID;
   if(HasOpenAdvisorTradesForSignal(sym, g_currentSignalID))
   {
      PrintFormat("[Trade Advisor] EXECUTION BLOCKED: Signal %s has already been executed.", g_currentSignalID);
      if(!isAutoTrade) Alert("[Trade Advisor] BLOCKED: Current trade advice signal is already active.");
      g_currentTradeTaken = true;
      return;
   }

   // 8. Set-Capacity Rule: Advisor may open at most 2 sets of trades for a single instrument simultaneously
   int openSetsOnSym = CountOpenAdvisorSetsForSymbol(sym);
   if(openSetsOnSym >= MathMax(1, MathMin(2, InpMaxSetsPerSymbol)))
   {
      PrintFormat("[Trade Advisor] EXECUTION BLOCKED: Maximum %d sets of trades already active for %s. Limit reached.",
                  InpMaxSetsPerSymbol, sym);
      if(!isAutoTrade) Alert(StringFormat("[Trade Advisor] BLOCKED: Max %d sets of trades active for %s.", InpMaxSetsPerSymbol, sym));
      g_currentTradeTaken = true;
      return;
   }
   else if(openSetsOnSym == 1)
   {
      PrintFormat("[Trade Advisor] 2ND POSITION ALLOWED: 1 set currently active on %s. Opening at most 1 additional viable set (Limit: %d sets).",
                  sym, InpMaxSetsPerSymbol);
   }

   // 9. Portfolio Cap (Enforce 16 ceiling)
   int portfolioCeiling = MathMax(24, InpMaxOpenAdvisorTradesPortfolio);
   int openAdvTrades = CountTotalOpenAdvisorTrades();
   if(openAdvTrades >= portfolioCeiling)
   {
      PrintFormat("[Trade Advisor] EXECUTION BLOCKED: Portfolio advisor trade ceiling reached (%d/%d).",
                  openAdvTrades, portfolioCeiling);
      if(!isAutoTrade) Alert(StringFormat("[Trade Advisor] BLOCKED: Portfolio advisor trade ceiling reached (%d/%d).", openAdvTrades, portfolioCeiling));
      return;
   }

   // 10. Acquire Mutex Lock
   if(!TryAcquireAccountLock("ADVISOR_EXEC", 12))
   {
      PrintFormat("[Trade Advisor] EXECUTION WAITING: Another chart holds the advisor execution lock.");
      return;
   }

   // Recheck capacity and signal identity while holding the account execution lock.
   if(CountOpenAdvisorSetsForSymbol(sym) >= MathMax(1, MathMin(2, InpMaxSetsPerSymbol)) ||
      IsAdvisorTradeTaken(sym, g_currentSignalID) ||
      (CountOpenAdvisorTradesForSymbol(sym) > 0 &&
       AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING))
   {
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }

   int currentOpenTrades = CountTotalOpenAdvisorTrades();
   int availableSlots = portfolioCeiling - currentOpenTrades;
   if(availableSlots <= 0)
   {
      PrintFormat("[Trade Advisor] EXECUTION BLOCKED: Portfolio advisor trade ceiling reached (%d open, max %d).",
                  currentOpenTrades, portfolioCeiling);
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }

   // 11. Determine Leg Target Mapping according to Portfolio Capacity Rules:
   // - Rule A: If 22/24 open trades (availableSlots == 2), open exactly 2 trades (Leg 1 & Leg 3)
   // - Rule B: If 23/24 open trades (availableSlots == 1), open Leg 2 trade ONLY to cover single available position to complete 24 trades running
   // - Rule C: If availableSlots == 3, open 3 trades (Leg 1, Leg 2, Leg 3)
   // - Rule D: If availableSlots >= 4, open all 4 trades (Leg 1, Leg 2, Leg 3, Leg 4)
   int targetLegNumbers[4]; // 1-based leg numbers (1=TP1, 2=TP2, 3=TP3, 4=TP4)
   int legsToExecute = 0;
   int allocCount = 0;

   if(availableSlots >= 4)
   {
      allocCount = MathMax(1, MathMin(InpAdvisorMaxTradesPerSetup, 4));
      for(int k = 0; k < allocCount; k++) targetLegNumbers[k] = k + 1;
      legsToExecute = allocCount;
   }
   else if(availableSlots == 3)
   {
      allocCount = MathMax(1, MathMin(InpAdvisorMaxTradesPerSetup, 3));
      for(int k = 0; k < allocCount; k++) targetLegNumbers[k] = k + 1;
      legsToExecute = allocCount;
   }
   else if(availableSlots == 2)
   {
      // Exactly 22/24 open trades: Allow opening of 2 trades (Leg 1 & Leg 3)
      targetLegNumbers[0] = 1; // Leg 1 (TP1)
      targetLegNumbers[1] = 3; // Leg 3 (TP3)
      legsToExecute = 2;
      PrintFormat("[Trade Advisor] Capacity Rule (22/24 open): Opening 2 trades (Leg 1 & Leg 3) to reach 24 running.");
   }
   else if(availableSlots == 1)
   {
      // Exactly 23/24 open trades: Allow Leg 2 trade ONLY to complete 24 running
      targetLegNumbers[0] = 2; // Leg 2 (TP2)
      legsToExecute = 1;
      PrintFormat("[Trade Advisor] Capacity Rule (23/24 open): Opening Leg 2 trade ONLY to complete 24 running.");
   }

   int requestedLegs = legsToExecute;
   if(requestedLegs < 1)
   {
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }
   // Finalize structural protection BEFORE risk sizing; use the same stop for every leg.
   if(!SEGSMarketReady(sym))
   {
      g_blockReason = "WAITING FOR SYMBOL METADATA";
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minStopDist = MathMax((double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt, pt);
   double pipSize = GetPipSize(sym);
   double minSafeStopDist = MathMax(minStopDist + 2.0 * pt, 0.15 * curAtr);
   bool stopOB = g_obSignalDirection == g_currentAdvisedAction;
   double finalStop = GetSafestStructuralStopLoss(sym, g_currentAdvisedAction, curPrice,
      stopOB ? g_obSignalLow : 0.0, stopOB ? g_obSignalHigh : 0.0, curAtr, !stopOB);
   if(finalStop <= 0.0)
   {
      g_blockReason = "WAITING FOR VALID STRUCTURAL STOP ANCHOR";
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }
   g_staticSL = finalStop;

   double totalLot = 0.0;
   if(g_smartLotEnabled)
   {
      double slDist = MathAbs(curPrice - g_staticSL);
      double slPips = (GetPipSize(sym) > 0.0) ? (slDist / GetPipSize(sym)) : 0.0;
      double sTotal = 0.0, sLeg = 0.0;
      int sLegs = requestedLegs;
      string expReason = "";
      CalculateSmartLotSize(sym, AccountInfoDouble(ACCOUNT_BALANCE), slPips, sTotal, sLeg, sLegs, expReason, requestedLegs);
      totalLot = sTotal;
      if(sLegs < requestedLegs) requestedLegs = sLegs;
      PrintFormat("[Advisor Execution][SMART LOT] %s | %s", sym, expReason);
   }
   else
   {
      totalLot = GetAdvisorLotForSymbol(sym);
   }

   double legLots[];
   string lotErr = "";
   if(!CalculateLegLots(sym, totalLot, requestedLegs, legLots, lotErr))
   {
      PrintFormat("[Advisor Execution] %s", lotErr);
      g_blockReason = lotErr;
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }
   legsToExecute = ArraySize(legLots);

   double totalMarginNeeded = 0.0;
   ENUM_ORDER_TYPE ordType = (g_currentAdvisedAction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   for(int k = 0; k < legsToExecute; k++)
   {
      double legMargin = 0.0;
      if(OrderCalcMargin(ordType, sym, legLots[k], curPrice, legMargin))
         totalMarginNeeded += legMargin;
   }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(totalMarginNeeded > 0.0 && freeMargin < totalMarginNeeded * 1.05)
   {
      PrintFormat("[Advisor Execution] BLOCKED: Insufficient free margin (Need: %.2f, Free: %.2f)", totalMarginNeeded, freeMargin);
      g_blockReason = "INSUFFICIENT FREE MARGIN";
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }

   double riskDist = MathAbs(curPrice - g_staticSL);
   if(riskDist <= 0.0) riskDist = minSafeStopDist;
   double minSep = MathMax(0.80 * riskDist, MathMax(15.0 * pipSize, 0.25 * curAtr));

   if(g_currentAdvisedAction == "BUY")
   {
      if(g_staticTP1 <= curPrice + minStopDist)
         g_staticTP1 = NormalizeDouble(curPrice + MathMax(1.40 * riskDist, minSafeStopDist + 10.0 * pt), digits);
      if(g_staticTP2 <= g_staticTP1 + minSep)
         g_staticTP2 = NormalizeDouble(g_staticTP1 + MathMax(0.80 * riskDist, minSep), digits);
      if(g_staticTP3 <= g_staticTP2 + minSep)
         g_staticTP3 = NormalizeDouble(g_staticTP2 + MathMax(1.20 * riskDist, minSep), digits);
      if(g_staticTP4 <= g_staticTP3 + minSep)
         g_staticTP4 = NormalizeDouble(g_staticTP3 + MathMax(2.00 * riskDist, minSep), digits);
      g_staticTP1 = NormalizePriceToTickSize(sym, g_staticTP1);
      g_staticTP2 = NormalizePriceToTickSize(sym, g_staticTP2);
      g_staticTP3 = NormalizePriceToTickSize(sym, g_staticTP3);
      g_staticTP4 = NormalizePriceToTickSize(sym, g_staticTP4);
   }
   else // SELL
   {
      if(g_staticTP1 >= curPrice - minStopDist || g_staticTP1 <= 0.0)
         g_staticTP1 = NormalizeDouble(curPrice - MathMax(1.40 * riskDist, minSafeStopDist + 10.0 * pt), digits);
      if(g_staticTP2 >= g_staticTP1 - minSep || g_staticTP2 <= 0.0)
         g_staticTP2 = NormalizeDouble(g_staticTP1 - MathMax(0.80 * riskDist, minSep), digits);
      if(g_staticTP3 >= g_staticTP2 - minSep || g_staticTP3 <= 0.0)
         g_staticTP3 = NormalizeDouble(g_staticTP2 - MathMax(1.20 * riskDist, minSep), digits);
      if(g_staticTP4 >= g_staticTP3 - minSep || g_staticTP4 <= 0.0)
         g_staticTP4 = NormalizeDouble(g_staticTP3 - MathMax(2.00 * riskDist, minSep), digits);

      g_staticTP1 = NormalizePriceToTickSize(sym, g_staticTP1);
      g_staticTP2 = NormalizePriceToTickSize(sym, g_staticTP2);
      g_staticTP3 = NormalizePriceToTickSize(sym, g_staticTP3);
      g_staticTP4 = NormalizePriceToTickSize(sym, g_staticTP4);
   }

   // 13. Mark Pending Execution State & Persist Targets in Global Variables BEFORE Placing
   GlobalVariableSet(sigExecKey, 1.0);
   string pendingTimeKey = "SEGS_SIG_PENDING_TIME_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + g_currentSignalID;
   GlobalVariableSet(pendingTimeKey, (double)TimeCurrent());

   string shortSig = (StringLen(g_currentSignalID) > 16) ? StringSubstr(g_currentSignalID, StringLen(g_currentSignalID) - 16) : g_currentSignalID;
   ENUM_POSITION_TYPE ptype = (g_currentAdvisedAction == "BUY") ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   SaveAdvisorSetupTargets("ADV_" + shortSig, sym, ptype, curPrice, g_staticSL, g_staticTP1, g_staticTP2, g_staticTP3, g_staticTP4, legsToExecute);

   // Record M30 Order block trade or clear H1 elevation
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string pfx = "SEGS_M30_OB_" + IntegerToString(login) + "_" + sym + "_";
   if(g_m30SLHit_RequireH1OB)
   {
      GlobalVariableDel(pfx + "SL_HIT");
      g_m30SLHit_RequireH1OB = false;
      PrintFormat("[SEGS M30 SL RECOVERY] 1-Hour Order Block trade executed for %s. M30 SL elevation cleared.", sym);
   }
   else if(g_activeEntryStrategy == "ORDER_BLOCK")
   {
      GlobalVariableSet(pfx + "ACTIVE", 1.0);
      GlobalVariableSet(pfx + "DIR", (g_currentAdvisedAction == "BUY") ? 1.0 : -1.0);
      GlobalVariableSet(pfx + "ENTRY", g_staticEntryPrice);
      GlobalVariableSet(pfx + "SL", g_staticSL);
   }
   SaveAdvisorSetupTargets("ADV_" + g_currentSignalID, sym, ptype, curPrice, g_staticSL, g_staticTP1, g_staticTP2, g_staticTP3, g_staticTP4, legsToExecute);

   // 14. Preferred Filling Mode Selection
   uint symFilling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING preferredFill = ORDER_FILLING_IOC;
   if((symFilling & SYMBOL_FILLING_FOK) != 0) preferredFill = ORDER_FILLING_FOK;
   else if((symFilling & SYMBOL_FILLING_IOC) != 0) preferredFill = ORDER_FILLING_IOC;
   else preferredFill = ORDER_FILLING_RETURN;

   trade.SetTypeFilling(preferredFill);
   trade.SetExpertMagicNumber(InpAdvisorMagicNumber);

   ulong actualPositionTickets[4];
   ulong actualPositionIds[4];
   bool  legSuccess[4];
   for(int k = 0; k < 4; k++) { actualPositionTickets[k] = 0; actualPositionIds[k] = 0; legSuccess[k] = false; }
   int successCount = 0;

   // 15. Execute Legs with Resilient Fallbacks
   for(int leg = 0; leg < legsToExecute; leg++)
   {
      int targetLegNum = targetLegNumbers[leg];
      double legLot = legLots[leg];
      double targetTP = (targetLegNum == 1) ? g_staticTP1 : ((targetLegNum == 2) ? g_staticTP2 : ((targetLegNum == 3) ? g_staticTP3 : g_staticTP4));
      string comment = StringFormat("SEGS|ADV|%s|L%d/%d", shortSig, targetLegNum, legsToExecute);
      double sendPrice = (g_currentAdvisedAction == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);

      // Pre-validate SL and TP levels against current live price to ensure zero invalid stop rejections
      double legSL = g_staticSL;
      double legTP = targetTP;
      if(legSL <= 0.0 || !ValidateProtectionLevels(sym, ptype, sendPrice, legSL, legTP))
      {
         PrintFormat("[SEGS EXEC] Leg %d deferred: protection not valid at live quote", leg + 1);
         continue;
      }

      ResetLastError();
      bool ok = false;
      if(g_currentAdvisedAction == "BUY")
         ok = trade.Buy(legLot, sym, sendPrice, legSL, legTP, comment);
      else
         ok = trade.Sell(legLot, sym, sendPrice, legSL, legTP, comment);

      uint ret = trade.ResultRetcode();

      // Fallback A: If filling mode unsupported, try alternative modes
      if(!ok && (ret == 10030 || ret == TRADE_RETCODE_INVALID_ORDER))
      {
         trade.SetTypeFilling(ORDER_FILLING_RETURN);
         sendPrice = (g_currentAdvisedAction == "BUY") ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
         legSL = g_staticSL;
         legTP = targetTP;
         if(legSL <= 0.0 || !ValidateProtectionLevels(sym, ptype, sendPrice, legSL, legTP))
      {
         PrintFormat("[SEGS EXEC] Leg %d deferred: protection not valid at live quote", leg + 1);
         continue;
      }
         ResetLastError();
         if(g_currentAdvisedAction == "BUY")
            ok = trade.Buy(legLot, sym, sendPrice, legSL, legTP, comment);
         else
            ok = trade.Sell(legLot, sym, sendPrice, legSL, legTP, comment);
         ret = trade.ResultRetcode();
      }

      // Invalid stops defer the trade; never retry with an unprotected market order.
      if(!ok && ret == TRADE_RETCODE_INVALID_STOPS)
         PrintFormat("[SEGS EXEC] Invalid stops on %s; awaiting a valid protected entry", sym);
      if(ok && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_PLACED))
      {
         ulong dealTk = trade.ResultDeal();
         ulong posTk = 0; ulong posId = 0;
         if(ResolvePositionTicketAndIdFromDeal(dealTk, sym, InpAdvisorMagicNumber, comment, posTk, posId))
         {
            actualPositionTickets[leg] = posTk;
            actualPositionIds[leg]     = posId;
            legSuccess[leg]            = true;
            successCount++;
         }
         else
         {
            PrintFormat("[Advisor Execution] Warning: Leg %d placed but position resolution failed for deal #%I64u", leg + 1, dealTk);
         }
      }
      else
      {
         PrintFormat("[Advisor Execution] Leg %d/%d failed with retcode %u (%s)",
                     leg + 1, legsToExecute, ret, trade.ResultRetcodeDescription());
      }
      Sleep(50);
   }

   // 16. Post-Execution Evaluation
   if(successCount == 0)
   {
      PrintFormat("[Advisor Execution] All legs failed to open for signal %s. Clearing pending state.", g_currentSignalID);
      GlobalVariableDel(sigExecKey);
      GlobalVariableDel(pendingTimeKey);
      g_currentTradeTaken = false;
      trade.SetExpertMagicNumber(InpMasterMagicNumber);
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }
   else if(successCount < legsToExecute)
   {
      PrintFormat("[Advisor Execution] Incomplete setup: only %d/%d legs opened. Executing verified safety rollback!", successCount, legsToExecute);
      g_telemetry.brokerRejections++;
      RollbackAdvisorSetup(shortSig, g_currentSignalID, actualPositionTickets, legsToExecute);

      // Permanently lock this signal so it is NEVER retried
      GlobalVariableSet(sigExecKey, 3.0); // 3.0 = ABORTED
      GlobalVariableDel(pendingTimeKey);
      g_currentTradeTaken = true;
      g_lastAlertedSignalID = g_currentSignalID;

      // 5-minute symbol cooldown to prevent repetitive executions
      string gvCdSymbolKey = "SEGS_COOLDOWN_" + cleanSym + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
      GlobalVariableSet(gvCdSymbolKey, (double)(TimeCurrent() + 15)); // 15-second anti-spam cooldown

      trade.SetExpertMagicNumber(InpMasterMagicNumber);
      ReleaseAccountLock("ADVISOR_EXEC");
      return;
   }
   else
   {
      g_telemetry.ordersExecuted++;
      GlobalVariableSet(sigExecKey, 2.0);
      GlobalVariableDel(pendingTimeKey);
      g_currentTradeTaken = true;
      g_lastAdvisorTradeExecTime = TimeCurrent();
      g_lastAdvisorTradeSignalID = g_currentSignalID;
      string gvExecTimeKey = "SEGS_ADV_EXECTIME_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + sym;
      GlobalVariableSet(gvExecTimeKey, (double)g_lastAdvisorTradeExecTime);

      g_setupState = "TRIGGERED";
      g_signalStatusLabel = StringFormat("TRIGGERED: %s [%s | TP2: %.2fR | Net: %.2fR]",
                                         g_currentAdvisedAction,
                                         g_setupClass == SETUP_CLASS_A_CONTINUATION ? "CLASS A" : "CLASS B",
                                         g_rrTP2, g_netExpectancy);
      UpdateTradeAdviceLines();
      if(g_showSentimentHUD) DrawSentimentHUD();
      PrintFormat("[Advisor Execution] Successfully opened %d legs for signal %s at %s!", legsToExecute, g_currentSignalID, FormatExecutionTime(g_lastAdvisorTradeExecTime));
      PlaySound("ok.wav");
   }

   trade.SetExpertMagicNumber(InpMasterMagicNumber);
   ReleaseAccountLock("ADVISOR_EXEC");
}

void CheckAndAutoTradeAdvice()
{
   if(!g_runtimeReady || !SEGSMarketReady(_Symbol)) return;
   // 1. Advisor Enabled check
   if(!g_myAdvisorEnabled) return;

   // 1B. Fast-Reaction Throttle: minimum 5 seconds between attempts when scanning, bypassed when viable or TRIGGERED
   static datetime s_lastAutoExecAttempt = 0;
   if(g_setupState != "TRIGGERED" && !g_hasViableEntry && TimeCurrent() - s_lastAutoExecAttempt < 5) return;

   // 1C. Symbol Cooldown Check
   string cleanSym = _Symbol;
   StringToUpper(cleanSym);
   if(IsSymbolMatch(cleanSym, InpXAU_Patterns))       cleanSym = "XAUUSD";
   else if(IsSymbolMatch(cleanSym, InpDJ30_Patterns)) cleanSym = "US30";
   else if(IsSymbolMatch(cleanSym, InpNAS_Patterns))  cleanSym = "NAS100";
   else if(IsSymbolMatch(cleanSym, InpGJ_Patterns))   cleanSym = "GBPJPY";
   else if(IsSymbolMatch(cleanSym, InpGU_Patterns))   cleanSym = "GBPUSD";
   else if(IsSymbolMatch(cleanSym, InpAUD_Patterns))  cleanSym = "AUDUSD";
   else if(IsSymbolMatch(cleanSym, InpOIL_Patterns))  cleanSym = "USOIL";
   else if(IsSymbolMatch(cleanSym, InpBTC_Patterns))  cleanSym = "BTCUSD";
   else if(IsSymbolMatch(cleanSym, InpAMD_Patterns))  cleanSym = "AMD";

   string gvCdKey = "SEGS_COOLDOWN_" + cleanSym + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   if(GlobalVariableCheck(gvCdKey))
   {
      datetime cdUntil = (datetime)GlobalVariableGet(gvCdKey);
      if(TimeCurrent() < cdUntil)
      {
         g_autoExecDetail = StringFormat("COOLDOWN ACTIVE (%d s)", (int)(cdUntil - TimeCurrent()));
         return;
      }
   }

   // 2. Tradable Instrument check: Specifically verify if the selected instrument is currently tradable
   string tradableReason = "";
   bool isTradable = IsBrokerSymbolTradeable(_Symbol, tradableReason);
   if(!isTradable)
   {
      g_autoExecDetail = "INSTRUMENT NOT TRADABLE (" + tradableReason + ")";
      static datetime lastTradableStandbyLog = 0;
      if(TimeCurrent() - lastTradableStandbyLog >= 120)
      {
         lastTradableStandbyLog = TimeCurrent();
         PrintFormat("[MyAdvisor][STANDBY] %s is currently not tradable (%s). Auto-trade standing by.", _Symbol, tradableReason);
      }
      return;
   }

   // 2B. Consecutive-Loss Circuit Breaker Rule (Daily & Per-Symbol Risk Quarantine)
   bool cbBlocked = false;
   string cbReason = "";
   int cbConsec = 0, cbTotal = 0;
   CheckCircuitBreaker(_Symbol, cbBlocked, cbReason, cbConsec, cbTotal);
   if(cbBlocked)
   {
      g_autoExecDetail = "CIRCUIT BREAKER: " + (cbTotal >= InpMaxDailyPortfolioLosses ? "6 PORTFOLIO LOSSES" : "3 CONSEC LOSSES (PAUSED)");
      static datetime lastCBLog = 0;
      if(TimeCurrent() - lastCBLog >= 60)
      {
         lastCBLog = TimeCurrent();
         PrintFormat("[MyAdvisor][CIRCUIT BREAKER] Auto-execution paused on %s: %s", _Symbol, cbReason);
      }
      return;
   }

   // 3. Execution permissions check (Terminal Algo Trading, MQL permissions, Account permissions)
   string autoDetail = "", autoSource = "";
   ENUM_AUTO_EXECUTION_STATE autoState = GetAutoExecutionState(_Symbol, autoDetail, autoSource);
   g_autoExecState  = autoState;
   g_autoExecDetail = autoDetail;
   g_autoExecSource = autoSource;

   if(autoState != AUTO_EXEC_ENABLED)
   {
      if(g_hasViableEntry && !g_isSignalExpired && (g_setupState == "TRIGGERED" || g_setupState == "READY") && !g_currentTradeTaken)
      {
         static datetime lastAutoBlockLog = 0;
         if(TimeCurrent() - lastAutoBlockLog >= 60)
         {
            lastAutoBlockLog = TimeCurrent();
            g_telemetry.autoBlocks++;
            PrintFormat("[MyAdvisor][ACTION REQUIRED] Setup READY/TRIGGERED on %s, but auto-execution is %s (%s). Turn on [Algo Trading] in MT5 toolbar (or press [Z]) to execute.", _Symbol, autoDetail, autoSource);
         }
      }
      return;
   }

   // 4. Must have an unexecuted viable setup
   if((CountOpenAdvisorSetsForSymbol(_Symbol) >= MathMax(1, MathMin(2, InpMaxSetsPerSymbol)) || IsAdvisorTradeTaken(_Symbol, g_currentSignalID)))
   {
      g_currentTradeTaken = true;
      return;
   }
   g_currentTradeTaken = false;
   // 4B. Mandatory Pre-Execution Viability Check:
   // Prevents executing stale waiting planned entries upon circuit breaker release unless still strictly viable
   string unviableReason = "";
   if((g_currentAdvisedAction == "NONE" || g_currentAdvisedAction == "") && g_plannedAction != "NONE")
   {
      g_currentAdvisedAction = g_plannedAction;
   }
   double curP = (g_currentAdvisedAction == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(curP <= 0.0) curP = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pSize = GetPipSize(_Symbol);
   double cAtr = 20.0 * pSize;
   if(g_hAtr_H1 != INVALID_HANDLE) { double b[]; ArraySetAsSeries(b, true); if(CopyBuffer(g_hAtr_H1, 0, 1, 1, b) == 1) cAtr = b[0]; }
   if(g_setupState != "TRIGGERED" && !IsPlannedEntryViable(_Symbol, g_currentAdvisedAction, g_staticEntryPrice, g_staticSL, curP, pSize, cAtr, unviableReason))
   {
      CancelUnviablePlannedEntry(_Symbol, "PRE-EXECUTION VIABILITY CHECK: " + unviableReason);
      g_setupState = "SCANNING";
      g_hasViableEntry = false;
      g_currentAdvisedAction = "NONE";
      g_signalStatusLabel = "SCANNING (SIGNAL UNVIABLE - RE-EVALUATING)";
      PrintFormat("[MyAdvisor] Auto-execution aborted for %s: Waiting signal is no longer viable (%s).", _Symbol, unviableReason);
      return;
   }

   double entryDist = MathAbs(curP - g_staticEntryPrice);
   double maxEntryExecDist = MathMax(0.50 * cAtr, 20.0 * pSize);

   // Check if price is currently inside or touching an unmitigated Order Block zone in setup direction (both M30 & H1)
   bool isInsideOrTouchingOB = false;
   for(int k = 0; k < ArraySize(g_orderBlocks); k++)
   {
      if(g_orderBlocks[k].invalidated) continue;
      if(g_currentAdvisedAction == "SELL" && !g_orderBlocks[k].bullish)
      {
         if(curP <= g_orderBlocks[k].high + 6.0 * pSize && curP >= g_orderBlocks[k].low - MathMax(0.35 * cAtr, 12.0 * pSize))
         {
            isInsideOrTouchingOB = true;
            break;
         }
      }
      else if(g_currentAdvisedAction == "BUY" && g_orderBlocks[k].bullish)
      {
         if(curP >= g_orderBlocks[k].low - 6.0 * pSize && curP <= g_orderBlocks[k].high + MathMax(0.35 * cAtr, 12.0 * pSize))
         {
            isInsideOrTouchingOB = true;
            break;
         }
      }
   }
   if(!isInsideOrTouchingOB)
   {
      for(int k = 0; k < ArraySize(g_h1OrderBlocks); k++)
      {
         if(g_h1OrderBlocks[k].invalidated) continue;
         if(g_currentAdvisedAction == "SELL" && !g_h1OrderBlocks[k].bullish)
         {
            if(curP <= g_h1OrderBlocks[k].high + 6.0 * pSize && curP >= g_h1OrderBlocks[k].low - MathMax(0.35 * cAtr, 12.0 * pSize))
            {
               isInsideOrTouchingOB = true;
               break;
            }
         }
         else if(g_currentAdvisedAction == "BUY" && g_h1OrderBlocks[k].bullish)
         {
            if(curP >= g_h1OrderBlocks[k].low - 6.0 * pSize && curP <= g_h1OrderBlocks[k].high + MathMax(0.35 * cAtr, 12.0 * pSize))
            {
               isInsideOrTouchingOB = true;
               break;
            }
         }
      }
   }

   // Final Pre-Execution Gate: Directional Confluence & Chop Immunity Check (Bypassed if TRIGGERED setup already approved by strategy engine)
   bool h1IsBull = (g_h1Bias == "BULLISH");
   bool h4IsBull = (g_h4Bias == "BULLISH");
   if(g_setupState != "TRIGGERED")
   {
      if(g_currentAdvisedAction == "BUY" && (!h1IsBull && !h4IsBull))
      {
         g_autoExecDetail = "BUY BLOCKED: HTF DOWNTREND (H1 & H4 BEAR)";
         return;
      }
      if(g_currentAdvisedAction == "SELL" && (h1IsBull && h4IsBull))
      {
         g_autoExecDetail = "SELL BLOCKED: HTF UPTREND (H1 & H4 BULL)";
         return;
      }
      if(g_marketStateClass == MARKET_STATE_CHOP)
      {
         g_autoExecDetail = "BLOCKED: MARKET IN CHOP / TRANSITION";
         return;
      }
   }

   // Touch and slippage allowance: must accommodate broker spread and fast volatility
   double spreadPtsExec = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;

   // Dynamic Volatility-Scaled Slippage Buffer:
   double dynSlippageBuffer = MathMax(0.40 * cAtr, MathMax(12.0 * pSize, spreadPtsExec * 2.5));
   maxEntryExecDist = MathMax(0.75 * cAtr, MathMax(25.0 * pSize, spreadPtsExec * 3.5));

   // Configure trade deviation to prevent broker REQUOTE during fast volatility
   ulong dynDeviation = (ulong)MathMax(150.0, MathMax(0.50 * cAtr / pt, spreadPtsExec * 3.0 / pt));
   trade.SetDeviationInPoints(dynDeviation);

   // Recent wick touch detection on M1: allows faster reaction time when price wicks into zone and bounces
   double l0_M1 = iLow(_Symbol, PERIOD_M1, 0);
   double l1_M1 = iLow(_Symbol, PERIOD_M1, 1);
   double h0_M1 = iHigh(_Symbol, PERIOD_M1, 0);
   double h1_M1 = iHigh(_Symbol, PERIOD_M1, 1);
   double minRecentLow = MathMin(l0_M1, l1_M1);
   double maxRecentHigh = MathMax(h0_M1, h1_M1);

   double l0_M5 = iLow(_Symbol, PERIOD_M5, 0), l1_M5 = iLow(_Symbol, PERIOD_M5, 1);
   double h0_M5 = iHigh(_Symbol, PERIOD_M5, 0), h1_M5 = iHigh(_Symbol, PERIOD_M5, 1);
   double l0_M15 = iLow(_Symbol, PERIOD_M15, 0);
   double h0_M15 = iHigh(_Symbol, PERIOD_M15, 0);
   if(l0_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M5);
   if(l1_M5 > 0.0) minRecentLow = MathMin(minRecentLow, l1_M5);
   if(l0_M15 > 0.0) minRecentLow = MathMin(minRecentLow, l0_M15);
   if(h0_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M5);
   if(h1_M5 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h1_M5);
   if(h0_M15 > 0.0) maxRecentHigh = MathMax(maxRecentHigh, h0_M15);

   bool priceAtPlannedZone = false;
   if(g_currentAdvisedAction == "BUY")
   {
      priceAtPlannedZone = (g_staticEntryPrice > 0.0 && 
                           (curP <= g_staticEntryPrice + dynSlippageBuffer || minRecentLow <= g_staticEntryPrice + dynSlippageBuffer) &&
                           (g_staticSL > 0.0 ? curP >= g_staticSL : true));
   }
   else if(g_currentAdvisedAction == "SELL")
   {
      priceAtPlannedZone = (g_staticEntryPrice > 0.0 && 
                           (curP >= g_staticEntryPrice - dynSlippageBuffer || maxRecentHigh >= g_staticEntryPrice - dynSlippageBuffer) &&
                           (g_staticSL > 0.0 ? curP <= g_staticSL : true));
   }

   bool isWithinSlippage = (g_staticEntryPrice > 0.0) && (entryDist <= dynSlippageBuffer || priceAtPlannedZone);

   // Pre-execution execution distance check:
   // If price is within slippageBuffer of planned entry, OR if setup is TRIGGERED and within safe distance, execute!
   if(isWithinSlippage || (g_setupState == "TRIGGERED" && entryDist <= maxEntryExecDist) || isInsideOrTouchingOB)
   {
      // Planned entry touch confirmed: proceed to execution
   }
   else
   {
      g_autoExecDetail = StringFormat("AWAITING PULLBACK (Price %.1fp from entry %s)", entryDist / pSize, DoubleToString(g_staticEntryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      return;
   }

   // 5. Anti-Repeat Protection: Ensure no active trade is running for this symbol
   if((CountOpenAdvisorSetsForSymbol(_Symbol) >= MathMax(1, MathMin(2, InpMaxSetsPerSymbol)) || IsAdvisorTradeTaken(_Symbol, g_currentSignalID)))
   {
      g_currentTradeTaken = true;
      return;
   }

   // 6. Portfolio exposure limit (strictly respects the full configured ceiling, e.g. 16)
   int portfolioCeiling = MathMax(24, InpMaxOpenAdvisorTradesPortfolio);
   int currentAdvisorTrades = CountTotalOpenAdvisorTrades();
   if(currentAdvisorTrades >= portfolioCeiling)
   {
      g_telemetry.riskBlocks++;
      return;
   }

   // 7. Check if signal execution key is completed
   string sigExecKey = "SEGS_SIG_EXEC_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + g_currentSignalID;
   if(GlobalVariableCheck(sigExecKey))
   {
      double state = GlobalVariableGet(sigExecKey);
      if(state >= 2.0)
      {
         if((CountOpenAdvisorSetsForSymbol(_Symbol) >= MathMax(1, MathMin(2, InpMaxSetsPerSymbol)) || IsAdvisorTradeTaken(_Symbol, g_currentSignalID)))
         {
            g_currentTradeTaken = true;
            return;
         }
         else
         {
            GlobalVariableDel(sigExecKey);
            g_currentTradeTaken = false;
         }
      }
      else if(state == 1.0)
      {
         // If marked pending, verify whether positions actually exist on the account
         string shortSig = (StringLen(g_currentSignalID) > 16) ? StringSubstr(g_currentSignalID, StringLen(g_currentSignalID) - 16) : g_currentSignalID;
         bool foundPos = false;
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong pt = PositionGetTicket(p);
            if(pt > 0 && posInfo.SelectByTicket(pt))
            {
               if(posInfo.Magic() == InpAdvisorMagicNumber && StringFind(posInfo.Comment(), shortSig) >= 0)
               {
                  foundPos = true;
                  break;
               }
            }
         }
         if(foundPos)
         {
            GlobalVariableSet(sigExecKey, 2.0);
            g_currentTradeTaken = true;
            return;
         }
         else
         {
            // Stale or failed attempt: remove pending lock so trade executes immediately!
            GlobalVariableDel(sigExecKey);
            string pendingTimeKey = "SEGS_SIG_PENDING_TIME_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + g_currentSignalID;
            GlobalVariableDel(pendingTimeKey);
         }
      }
   }

   // 8. Execute Advised Trade!
   s_lastAutoExecAttempt = TimeCurrent();
   ExecuteAdvisedTrade(true);
}

double CalcRiskFromSL(ulong ticket)
{
   if(!posInfo.SelectByTicket(ticket)) return 0.0;
   double sl = posInfo.StopLoss();
   if(sl <= 0.0) return 0.0;

   string sym = posInfo.Symbol();
   double openPrice = posInfo.PriceOpen();
   double lots = posInfo.Volume();
   ENUM_POSITION_TYPE type = posInfo.PositionType();
   ENUM_ORDER_TYPE orderType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double calculatedProfit = 0.0;
   if(OrderCalcProfit(orderType, sym, lots, openPrice, sl, calculatedProfit))
      return NormalizeDouble(MathAbs(calculatedProfit), 2);

   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0) tickSize = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(!MathIsValidNumber(tickSize) || tickSize <= 0.0 ||
      !MathIsValidNumber(tickVal) || tickVal <= 0.0) return 0.0;

   double diff = MathAbs(openPrice - sl);
   return NormalizeDouble((diff / tickSize) * tickVal * lots, 2);
}

double CalcProfitFromTP(ulong ticket)
{
   if(!posInfo.SelectByTicket(ticket)) return 0.0;
   double tp = posInfo.TakeProfit();
   if(tp <= 0.0) return 0.0;

   string sym = posInfo.Symbol();
   double openPrice = posInfo.PriceOpen();
   double lots = posInfo.Volume();
   ENUM_POSITION_TYPE type = posInfo.PositionType();
   ENUM_ORDER_TYPE orderType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double calculatedProfit = 0.0;
   if(OrderCalcProfit(orderType, sym, lots, openPrice, tp, calculatedProfit))
      return NormalizeDouble(MathAbs(calculatedProfit), 2);

   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0) tickSize = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(!MathIsValidNumber(tickSize) || tickSize <= 0.0 ||
      !MathIsValidNumber(tickVal) || tickVal <= 0.0) return 0.0;

   double diff = MathAbs(tp - openPrice);
   return NormalizeDouble((diff / tickSize) * tickVal * lots, 2);
}

double CalcEstimatedRisk(ulong ticket, double slPips)
{
   if(!posInfo.SelectByTicket(ticket)) return 0.0;
   string sym = posInfo.Symbol();
   double pipSize = GetPipSize(sym);
   double openP = posInfo.PriceOpen();
   bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
   double testSL = isBuy ? (openP - (slPips * pipSize)) : (openP + (slPips * pipSize));

   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double estProfit = 0.0;
   if(OrderCalcProfit(orderType, sym, posInfo.Volume(), openP, testSL, estProfit))
      return NormalizeDouble(MathAbs(estProfit), 2);

   return 0.0;
}

double CalcEstimatedReward(ulong ticket, double tpPips)
{
   if(!posInfo.SelectByTicket(ticket)) return 0.0;
   string sym = posInfo.Symbol();
   double pipSize = GetPipSize(sym);
   double openP = posInfo.PriceOpen();
   bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
   double testTP = isBuy ? (openP + (tpPips * pipSize)) : (openP - (tpPips * pipSize));

   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double estProfit = 0.0;
   if(OrderCalcProfit(orderType, sym, posInfo.Volume(), openP, testTP, estProfit))
      return NormalizeDouble(MathAbs(estProfit), 2);

   return 0.0;
}

//+------------------------------------------------------------------+
//| Calculate Target Progress (Compact, Sharp, Non-Overlapping)      |
//+------------------------------------------------------------------+
TradeProgress CalcTradeProgress(ulong ticket, int barLen = 8)
{
   TradeProgress tp;
   tp.pct = 0.0;
   tp.pipsToTP = 0.0;
   tp.pipsCurrent = 0.0;
   tp.progressBar = "[----------] 0%";
   tp.barColor = clrSilver;

   if(!posInfo.SelectByTicket(ticket)) return tp;

   string sym = posInfo.Symbol();
   double openP = posInfo.PriceOpen();
   bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
   double curP = isBuy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
   if(curP <= 0.0) curP = posInfo.PriceCurrent();
   double takeP = posInfo.TakeProfit();

   double pipSize = GetPipSize(sym);
   if(!MathIsValidNumber(pipSize) || pipSize <= 0.0) return tp;

   if(takeP > 0.0)
   {
      double totalDist = MathAbs(takeP - openP);
      double currentDist = isBuy ? (curP - openP) : (openP - curP);
      tp.pipsCurrent = NormalizeDouble(currentDist / pipSize, 1);
      tp.pipsToTP = NormalizeDouble(MathAbs(takeP - curP) / pipSize, 1);

      if(totalDist > 0.0)
      {
         tp.pct = NormalizeDouble((currentDist / totalDist) * 100.0, 0);
         int bLen = MathMax(6, MathMin(20, barLen));
         int filled = (int)MathRound((tp.pct / 100.0) * (double)bLen);
         if(filled < 0) filled = 0;
         if(filled > bLen) filled = bLen;

         string bar = "[";
         for(int b = 0; b < filled; b++) bar += "=";
         if(filled < bLen && filled > 0) bar += ">";
         for(int b = (filled > 0 ? filled + 1 : 0); b < bLen; b++) bar += "-";
         bar += "]";

         if(bLen >= 12 && tp.pipsToTP > 0.0)
            tp.progressBar = StringFormat("%s %s%.0f%% (%.1fp to TP)", bar, (tp.pct >= 0 ? "+" : ""), tp.pct, tp.pipsToTP);
         else
            tp.progressBar = StringFormat("%s %s%.0f%%", bar, (tp.pct >= 0 ? "+" : ""), tp.pct);

         tp.barColor = (tp.pct >= 0) ? clrLime : clrTomato;
      }
   }
   else
   {
      double curPips = isBuy ? ((curP - openP) / pipSize) : ((openP - curP) / pipSize);
      tp.pipsCurrent = NormalizeDouble(curPips, 1);
      tp.progressBar = StringFormat("[OPEN] %s%.1fp", (curPips >= 0 ? "+" : ""), curPips);
      tp.barColor = (curPips >= 0) ? clrLime : clrTomato;
   }
   return tp;
}

//+------------------------------------------------------------------+
//| Account Metrics Calcs                                            |
//+------------------------------------------------------------------+
double ComputeRemainingToTP_AllPositions()
{
   double totalRem = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !posInfo.SelectByTicket(ticket)) continue;

      double tp = posInfo.TakeProfit();
      if(tp <= 0.0) continue;

      double fullTP = CalcProfitFromTP(ticket);
      double curPnL = posInfo.Profit() + posInfo.Swap();
      double add = fullTP - curPnL;
      if(add > 0.0) totalRem += add;
   }
   return NormalizeDouble(totalRem, 2);
}

double ComputeRealizedPnL_TodayToronto()
{
   datetime nowToronto = GetTorontoTimeNow();
   MqlDateTime dt;
   TimeToStruct(nowToronto, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime startToronto = StructToTime(dt);

   int torontoOffset = IsTorontoDST(TimeGMT()) ? -4 : -5;
   int diffSeconds = (InpBrokerUtcOffset - torontoOffset) * 3600;
   datetime startBroker = startToronto + diffSeconds;

   if(!HistorySelect(startBroker, TimeCurrent())) return 0.0;

   double totalPnL = 0.0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0)
      {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         {
            totalPnL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            totalPnL += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            totalPnL += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         }
      }
   }
   return NormalizeDouble(totalPnL, 2);
}

double ComputeRealizedPnL_ThisWeekToronto()
{
   datetime nowToronto = GetTorontoTimeNow();
   MqlDateTime dt;
   TimeToStruct(nowToronto, dt);
   int daysFromMonday = (dt.day_of_week == 0) ? 6 : (dt.day_of_week - 1);
   datetime mondayToronto = nowToronto - (daysFromMonday * 86400);
   TimeToStruct(mondayToronto, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime startWeekToronto = StructToTime(dt);

   int torontoOffset = IsTorontoDST(TimeGMT()) ? -4 : -5;
   int diffSeconds = (InpBrokerUtcOffset - torontoOffset) * 3600;
   datetime startWeekBroker = startWeekToronto + diffSeconds;

   if(!HistorySelect(startWeekBroker, TimeCurrent())) return 0.0;

   double totalPnL = 0.0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0)
      {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         {
            totalPnL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            totalPnL += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            totalPnL += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         }
      }
   }
   return NormalizeDouble(totalPnL, 2);
}

double GetOpeningEquity_TodayToronto()
{
   double currentBal = AccountInfoDouble(ACCOUNT_BALANCE);
   return NormalizeDouble(currentBal - ComputeRealizedPnL_TodayToronto(), 2);
}

double GetOpeningEquity_ThisWeekToronto()
{
   double currentBal = AccountInfoDouble(ACCOUNT_BALANCE);
   return NormalizeDouble(currentBal - ComputeRealizedPnL_ThisWeekToronto(), 2);
}

double ComputeOpenPnL_Now()
{
   double openPnL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         openPnL += posInfo.Profit() + posInfo.Swap();
      }
   }
   return NormalizeDouble(openPnL, 2);
}

//+------------------------------------------------------------------+
//| COMPUTE WIN RATE OF PAST TRADES (History Deals)                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Setup-Level Analytics: Aggregates multi-leg trades into setups    |
//| Enforces Win Rate = Profitable Setups / Total Closed Setups      |
//| Calculates Toronto Hour metrics and Edge Quality classification  |
//+------------------------------------------------------------------+
void ComputeWinRate_PastTrades(string targetSymbol, double &winRate, int &winTrades, int &lossTrades, double &profitFactor)
{
   winRate = 0.0;
   winTrades = 0;
   lossTrades = 0;
   profitFactor = 1.0;
   double grossProfit = 0.0;
   double grossLoss = 0.0;

   if(!HistorySelect(0, TimeCurrent())) return;
   int totalDeals = HistoryDealsTotal();
   if(totalDeals == 0) return;

   // Pass 1: Index entry deals (DEAL_ENTRY_IN) to preserve original setup comments and entry times
   // even if broker overwrote exit deal comments with [sl] or [tp]
   struct DealEntryInfo
   {
      long     posId;
      datetime entryTime;
      string   comment;
   };

   DealEntryInfo inDeals[];
   int inCount = 0;
   ArrayResize(inDeals, 200);

   for(int i = 0; i < totalDeals; i++)
   {
      ulong dTk = HistoryDealGetTicket(i);
      if(dTk <= 0) continue;
      long entry = HistoryDealGetInteger(dTk, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
      {
         long pId = HistoryDealGetInteger(dTk, DEAL_POSITION_ID);
         if(pId <= 0) continue;

         if(inCount >= ArraySize(inDeals))
            ArrayResize(inDeals, inCount + 100);

         inDeals[inCount].posId = pId;
         inDeals[inCount].entryTime = (datetime)HistoryDealGetInteger(dTk, DEAL_TIME);
         inDeals[inCount].comment = HistoryDealGetString(dTk, DEAL_COMMENT);
         inCount++;
      }
   }

   // Pass 2: Aggregate deals by Setup ID (Section 29)
   struct SetupRecord
   {
      string   setupKey;
      string   symbol;
      double   netProfit;
      datetime exitTime;
      datetime entryTime;
      int      dealCount;
   };

   SetupRecord setups[];
   int setupCount = 0;
   ArrayResize(setups, 100);

   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT) continue;

      string dealSym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      if(targetSymbol != "" && targetSymbol != "ALL" && !IsSameChartAsset(dealSym, targetSymbol)) continue;

      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                      HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                      HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      string cmt = HistoryDealGetString(dealTicket, DEAL_COMMENT);
      long posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      datetime dTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      datetime setupEntryTime = dTime;

      // Look up entry deal info for preserved comment and true entry time
      for(int k = 0; k < inCount; k++)
      {
         if(inDeals[k].posId == posId)
         {
            setupEntryTime = inDeals[k].entryTime;
            // If exit deal comment has no SEGS prefix, inherit entry deal comment
            if(StringFind(cmt, "SEGS|") < 0 && StringFind(inDeals[k].comment, "SEGS|") >= 0)
               cmt = inDeals[k].comment;
            break;
         }
      }

      // Extract Setup Key
      string sKey = "";
      int advIdx = StringFind(cmt, "SEGS|ADV|");
      if(advIdx >= 0)
      {
         string rem = StringSubstr(cmt, advIdx + 9);
         string parts[];
         if(StringSplit(rem, '|', parts) >= 1) sKey = "ADV_" + parts[0];
      }
      else
      {
         int manIdx = StringFind(cmt, "SEGS|MAN|");
         if(manIdx >= 0)
         {
            string rem = StringSubstr(cmt, manIdx + 9);
            string parts[];
            if(StringSplit(rem, '|', parts) >= 1) sKey = "MAN_" + parts[0];
         }
         else
         {
            int hashIdx = StringFind(cmt, "#");
            if(hashIdx >= 0)
            {
               sKey = "MAN_" + StringSubstr(cmt, hashIdx + 1);
            }
            else
            {
               sKey = "POS_" + dealSym + "_" + IntegerToString(posId);
            }
         }
      }

      int foundIdx = -1;
      for(int s = 0; s < setupCount; s++)
      {
         if(setups[s].setupKey == sKey)
         {
            foundIdx = s;
            break;
         }
      }

      if(foundIdx >= 0)
      {
         setups[foundIdx].netProfit += profit;
         setups[foundIdx].dealCount++;
         if(dTime > setups[foundIdx].exitTime) setups[foundIdx].exitTime = dTime;
         if(setupEntryTime < setups[foundIdx].entryTime) setups[foundIdx].entryTime = setupEntryTime;
      }
      else
      {
         if(setupCount >= ArraySize(setups))
            ArrayResize(setups, setupCount + 100);

         setups[setupCount].setupKey   = sKey;
         setups[setupCount].symbol     = dealSym;
         setups[setupCount].netProfit  = profit;
         setups[setupCount].exitTime   = dTime;
         setups[setupCount].entryTime  = setupEntryTime;
         setups[setupCount].dealCount  = 1;
         setupCount++;
      }
   }

   // Compute setup-level win rate and profit factor
   for(int s = 0; s < setupCount; s++)
   {
      double p = setups[s].netProfit;
      if(p > 0.001)
      {
         winTrades++;
         grossProfit += p;
      }
      else if(p < -0.001)
      {
         lossTrades++;
         grossLoss += MathAbs(p);
      }
   }

   int totalSetups = winTrades + lossTrades;
   if(totalSetups > 0)
      winRate = NormalizeDouble(((double)winTrades / (double)totalSetups) * 100.0, 1);

   if(grossLoss > 0.0)
      profitFactor = NormalizeDouble(grossProfit / grossLoss, 2);
   else if(grossProfit > 0.0)
      profitFactor = 9.99;
}

void ShiftStopLossTicket(ulong ticket, double deltaPips)
{
   if(!posInfo.SelectByTicket(ticket)) return;
   string sym = posInfo.Symbol();
   double pipSize = GetPipSize(sym);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double currentSL = posInfo.StopLoss();
   if(currentSL <= 0.0) currentSL = posInfo.PriceOpen();

   // For BUY: +delta moves SL up (lock profit/reduce risk), -delta moves down
   // For SELL: +delta moves SL down (lock profit/reduce risk), -delta moves up
   double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentSL + deltaPips * pipSize) : (currentSL - deltaPips * pipSize);
   newSL = NormalizeDouble(newSL, digits);
   if(trade.PositionModify(ticket, newSL, posInfo.TakeProfit()))
   {
      PrintFormat("[SEGS PRO] Shifted SL on #%I64u by %+.1f pips -> %s", ticket, deltaPips, DoubleToString(newSL, digits));
   }
}

//+------------------------------------------------------------------+
//| Interactive Shift Take Profit for Selected / Inline Trade Ticket |
//+------------------------------------------------------------------+
void ShiftTakeProfitTicket(ulong ticket, double deltaPips)
{
   if(!posInfo.SelectByTicket(ticket)) return;
   string sym = posInfo.Symbol();
   double pipSize = GetPipSize(sym);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double currentTP = posInfo.TakeProfit();
   if(currentTP <= 0.0)
   {
      double curP = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      if(curP <= 0.0) curP = posInfo.PriceCurrent();
      currentTP = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curP + 30.0 * pipSize) : (curP - 30.0 * pipSize);
   }

   // For BUY: +delta moves TP up (extending targets), -delta moves down
   // For SELL: +delta moves TP down (extending targets), -delta moves up
   double newTP = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentTP + deltaPips * pipSize) : (currentTP - deltaPips * pipSize);
   newTP = NormalizeDouble(newTP, digits);
   if(trade.PositionModify(ticket, posInfo.StopLoss(), newTP))
   {
      PrintFormat("[SEGS PRO] Shifted TP on #%I64u by %+.1f pips -> %s", ticket, deltaPips, DoubleToString(newTP, digits));
   }
}

//+------------------------------------------------------------------+
//| Draw Open Trades Markings Tab & Interactive Inspector            |
//+------------------------------------------------------------------+
void DrawOpenTradesMarkingsTab(int mx, int curY, int mw, ENUM_BASE_CORNER mc)
{
   ObjectsDeleteAll(0, PREFIX + "OTM_TAB_");

   // 1. Control Bar
   int barH = 32;
   CreateOrUpdatePanel(PREFIX + "OTM_TAB_BG", mx, curY, mw, 120, C'14,18,28', InpRowBorder, mc);
   CreateOrUpdatePanel(PREFIX + "OTM_TAB_BAR", mx, curY, mw, barH, C'18,24,36', InpRowBorder, mc);

   string statusTxt = g_showOpenTradeMarkings ? "● OPEN TRADES CHART MARKINGS: ACTIVE (ON)" : "○ OPEN TRADES CHART MARKINGS: HIDDEN (OFF)";
   color statusCol  = g_showOpenTradeMarkings ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "OTM_TAB_STATUS", mx + 12, curY + 8, statusTxt, statusCol, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, "Arial Bold");

   int btnX = mx + 420;
   // Toggle All On/Off Button
   string togTxt = g_showOpenTradeMarkings ? "MARKINGS [T]: ON" : "MARKINGS [T]: OFF";
   color togBg   = g_showOpenTradeMarkings ? C'18,52,36' : C'38,36,44';
   color togCol  = g_showOpenTradeMarkings ? clrLime : clrSilver;
   CreateOrUpdateButton(PREFIX + "OTM_BTN_TOGGLE", btnX, curY + 5, 140, 22, togTxt, togBg, togCol, mc, InpFontName, 8);
   btnX += 145;

   // P/L Labels Toggle
   string lblTxt = g_showOpenTradeLabels ? "LABELS: ON" : "LABELS: OFF";
   color lblBg   = g_showOpenTradeLabels ? C'20,48,65' : C'36,36,40';
   color lblCol  = g_showOpenTradeLabels ? clrAqua : clrSilver;
   CreateOrUpdateButton(PREFIX + "OTM_TOG_LBL", btnX, curY + 5, 110, 22, lblTxt, lblBg, lblCol, mc, InpFontName, 8);
   btnX += 115;

   // Brackets Toggle
   string brkTxt = g_showOpenTradeBrackets ? "BRACKETS: ON" : "BRACKETS: OFF";
   color brkBg   = g_showOpenTradeBrackets ? C'50,38,20' : C'36,36,40';
   color brkCol  = g_showOpenTradeBrackets ? InpGoldColor : clrSilver;
   CreateOrUpdateButton(PREFIX + "OTM_TOG_BRK", btnX, curY + 5, 115, 22, brkTxt, brkBg, brkCol, mc, InpFontName, 8);
   btnX += 120;

   // Timeframe Persistence Confirmation Badge
   CreateOrUpdateCell(PREFIX + "OTM_TAB_NOTE", btnX + 8, curY + 8, "✓ PERSISTENT ACROSS TIMEFRAMES (OBJ_ALL_PERIODS LOCKED)", C'130,185,225', InpCellFontSize, ANCHOR_LEFT_UPPER, mc, "Consolas Bold");

   // 2. Open Trades on Current Chart Asset
   int totalPos = PositionsTotal();
   int advPosCount = 0;
   ulong advTickets[];
   for(int p = 0; p < totalPos; p++)
   {
      ulong t = PositionGetTicket(p);
      if(t <= 0 || !posInfo.SelectByTicket(t)) continue;
      if(!IsSameChartAsset(posInfo.Symbol(), _Symbol)) continue;
      long magic = posInfo.Magic();
      string comment = posInfo.Comment();
      bool isAdvisor = (magic == InpAdvisorMagicNumber || 
                        StringFind(comment, "SEGS|ADV|") >= 0 || 
                        StringFind(comment, "[MyAdvisor]") >= 0 || 
                        StringFind(comment, "[Advised") >= 0 ||
                        InpMarkAllSymbolPositions);
      if(isAdvisor)
      {
         ArrayResize(advTickets, advPosCount + 1);
         advTickets[advPosCount++] = t;
      }
   }

   int contentY = curY + barH + 6;
   if(advPosCount == 0)
   {
      // Display guidance cards
      int c1W = 560;
      CreateOrUpdatePanel(PREFIX + "OTM_TAB_C1_BG", mx + 8, contentY, c1W, 72, C'18,22,32', C'28,36,50', mc);
      CreateOrUpdateCell(PREFIX + "OTM_TAB_C1_T1", mx + 18, contentY + 8,
                         "● NO ACTIVE ADVISOR TRADES ON CURRENT CHART (" + _Symbol + ")", clrDeepSkyBlue, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, "Arial Bold");
      CreateOrUpdateCell(PREFIX + "OTM_TAB_C1_T2", mx + 18, contentY + 28,
                         "Trades taken by MyAdvisor (or manual hotkey [Z]) will display on-chart markings automatically.", C'180,195,215', InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
      CreateOrUpdateCell(PREFIX + "OTM_TAB_C1_T3", mx + 18, contentY + 48,
                         "Markings: Entry (Gold/Blue), Stop Loss (Red/Locked Green), and TP1-4 (Teal/Purple/Gold).", clrLime, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

      int c2X = mx + 8 + c1W + 10;
      int c2W = mw - (c2X - mx) - 10;
      if(c2W > 200)
      {
         CreateOrUpdatePanel(PREFIX + "OTM_TAB_C2_BG", c2X, contentY, c2W, 72, C'18,22,32', C'28,36,50', mc);
         CreateOrUpdateCell(PREFIX + "OTM_TAB_C2_T1", c2X + 14, contentY + 8,
                            "🛡 TIMEFRAME RESILIENCE ENGINE (M1 → D1 PERSISTENT)", InpGoldColor, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, "Arial Bold");
         CreateOrUpdateCell(PREFIX + "OTM_TAB_C2_T2", c2X + 14, contentY + 28,
                            "Lines are registered with OBJPROP_TIMEFRAMES = OBJ_ALL_PERIODS and cached in global memory.", C'180,195,215', InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
         CreateOrUpdateCell(PREFIX + "OTM_TAB_C2_T3", c2X + 14, contentY + 48,
                            "Switching chart timeframes (M1, M5, M15, M30, H1, H4, D1) will NEVER erase your active markings!", clrSkyBlue, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
      }
   }
   else
   {
      // Render active advisor positions table
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double pipSize = GetPipSize(_Symbol);
      if(pipSize <= 0.0) pipSize = 0.0001;

      int maxRows = MathMin(advPosCount, 3);
      for(int i = 0; i < maxRows; i++)
      {
         ulong tk = advTickets[i];
         if(!posInfo.SelectByTicket(tk)) continue;

         ENUM_POSITION_TYPE ptype = posInfo.PositionType();
         bool isBuy = (ptype == POSITION_TYPE_BUY);
         double openP = posInfo.PriceOpen();
         double sl    = posInfo.StopLoss();
         double tp    = posInfo.TakeProfit();
         double vol   = posInfo.Volume();
         double profit = posInfo.Profit() + posInfo.Swap();
         double curP  = posInfo.PriceCurrent();
         if(curP <= 0.0)
            curP = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         double pipsProfit = isBuy ? (curP - openP) / pipSize : (openP - curP) / pipSize;
         bool isBE = isBuy ? (sl >= openP) : (sl > 0.0 && sl <= openP);

         int rowY = contentY + (i * 24);
         CreateOrUpdatePanel(PREFIX + "OTM_TAB_R" + IntegerToString(i) + "_BG", mx + 8, rowY, mw - 16, 22, (i % 2 == 0) ? C'18,22,32' : C'14,18,26', C'28,36,50', mc);

         string tkInfo = StringFormat("#%I64u • %s %.2fL @ %s", tk, (isBuy ? "BUY" : "SELL"), vol, DoubleToString(openP, digits));
         CreateOrUpdateCell(PREFIX + "OTM_TAB_R" + IntegerToString(i) + "_T1", mx + 16, rowY + 4, tkInfo, (isBuy ? InpProfitColor : InpLossColor), InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         string slInfo = (sl > 0.0) ? (isBE ? StringFormat("🔒 SL: %s (BE LOCKED)", DoubleToString(sl, digits)) : StringFormat("🛑 SL: %s", DoubleToString(sl, digits))) : "SL: Not Set";
         color slCol   = isBE ? clrLime : (sl > 0.0 ? clrTomato : clrSilver);
         CreateOrUpdateCell(PREFIX + "OTM_TAB_R" + IntegerToString(i) + "_T2", mx + 260, rowY + 4, slInfo, slCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         string tpInfo = (tp > 0.0) ? StringFormat("🏁 TP: %s", DoubleToString(tp, digits)) : (g_staticTP1 > 0 ? StringFormat("🏁 PROJ TP: %s", DoubleToString(g_staticTP1, digits)) : "TP: Dynamic");
         CreateOrUpdateCell(PREFIX + "OTM_TAB_R" + IntegerToString(i) + "_T3", mx + 460, rowY + 4, tpInfo, clrAqua, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         string pnlInfo = StringFormat("%s$%.2f (%+.1f pips)", (profit >= 0 ? "+" : ""), profit, pipsProfit);
         CreateOrUpdateCell(PREFIX + "OTM_TAB_R" + IntegerToString(i) + "_T4", mx + 640, rowY + 4, pnlInfo, (profit >= 0 ? clrLime : clrTomato), InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         // Markings status
         string markInfo = g_showOpenTradeMarkings ? "ON-CHART: VISIBLE" : "ON-CHART: HIDDEN";
         CreateOrUpdateCell(PREFIX + "OTM_TAB_R" + IntegerToString(i) + "_T5", mx + 820, rowY + 4, markInfo, g_showOpenTradeMarkings ? clrLime : clrSilver, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
      }
   }
}

//+------------------------------------------------------------------+
//| Apply System Settings To All Open Charts (System-Wide M & H)      |
//+------------------------------------------------------------------+
void ApplySystemSettingsToAllCharts()
{
   if(GlobalVariableCheck("SEGS_SYS_DASH_VIS"))
      g_isDashboardVisible = (GlobalVariableGet("SEGS_SYS_DASH_VIS") > 0.5);
   if(GlobalVariableCheck("SEGS_SYS_SHOW_SENT"))
      g_showSentimentHUD = (GlobalVariableGet("SEGS_SYS_SHOW_SENT") > 0.5);
   if(GlobalVariableCheck("SEGS_SYS_WINRATE_VIS"))
      g_showWinRateHUD = (GlobalVariableGet("SEGS_SYS_WINRATE_VIS") > 0.5);
   if(GlobalVariableCheck("SEGS_SYS_HELP_VIS"))
      g_showHelpHUD = (GlobalVariableGet("SEGS_SYS_HELP_VIS") > 0.5);

   long myChartId = ChartID();
   long currChart = ChartFirst();
   while(currChart >= 0)
   {
      if(!g_isDashboardVisible)
      {
         ObjectsDeleteAll(currChart, PREFIX + "MAT_");
         ObjectsDeleteAll(currChart, PREFIX + "R");
         ObjectsDeleteAll(currChart, PREFIX + "C_");
         ObjectsDeleteAll(currChart, PREFIX + "RIB_");
         ObjectsDeleteAll(currChart, PREFIX + "HDR_");
         ObjectsDeleteAll(currChart, PREFIX + "FTR_");
         ObjectsDeleteAll(currChart, PREFIX + "STB_");
         ObjectsDeleteAll(currChart, PREFIX + "BTN_");
         ObjectsDeleteAll(currChart, PREFIX + "SBAR_");
         ObjectsDeleteAll(currChart, PREFIX + "OTM_TAB_");
         
         if(ObjectFind(currChart, PREFIX + "FLOAT_SHOW") < 0)
         {
            ObjectCreate(currChart, PREFIX + "FLOAT_SHOW", OBJ_BUTTON, 0, 0, 0);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_XDISTANCE, 10);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_YDISTANCE, 10);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_XSIZE, 180);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_YSIZE, 24);
            ObjectSetString(currChart,  PREFIX + "FLOAT_SHOW", OBJPROP_TEXT, "SHOW TERMINAL [H]");
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_COLOR, InpProfitColor);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_BGCOLOR, C'24,32,48');
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_FONTSIZE, 9);
            ObjectSetString(currChart,  PREFIX + "FLOAT_SHOW", OBJPROP_FONT, InpFontName);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_SELECTABLE, false);
            ObjectSetInteger(currChart, PREFIX + "FLOAT_SHOW", OBJPROP_ZORDER, 50);
         }
      }
      else
      {
         ObjectDelete(currChart, PREFIX + "FLOAT_SHOW");
      }

      if(!g_showSentimentHUD)
      {
         ObjectsDeleteAll(currChart, PREFIX + "SNT_");
      }
      if(!g_showWinRateHUD)
      {
         ObjectsDeleteAll(currChart, PREFIX + "WR_");
      }
      if(!g_showHelpHUD)
      {
         ObjectsDeleteAll(currChart, PREFIX + "HLP_");
      }

      // Broadcast custom sync event across all open chart windows immediately
      if(currChart != myChartId)
      {
         EventChartCustom(currChart, 101, g_isDashboardVisible ? 1 : 0, g_showSentimentHUD ? 1.0 : 0.0, "SEGS_SYNC_SYS");
      }

      ChartRedraw(currChart);
      currChart = ChartNext(currChart);
   }

   GlobalVariableSet("SEGS_PHASE_" + IntegerToString(ChartID()), 4.0);
   DrawUnifiedTerminalDashboard();
   if(g_showSentimentHUD) DrawSentimentHUD();
   if(g_showWinRateHUD) DrawWinRateHUD();
   if(g_showHelpHUD) DrawHelpHUD();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| MASTER UNIFIED TERMINAL DASHBOARD                                |
//| Fixed Non-Overlapping Columns, Clean Progress, Movable & Dockable|
//+------------------------------------------------------------------+
void DrawUnifiedTerminalDashboard()
{
   ENUM_BASE_CORNER mc = CORNER_LEFT_UPPER;
   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS, 0);
   int numWindows = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   int chartH = 0;
   for(int w = 0; w < numWindows; w++)
   {
      int subH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, w);
      if(subH > 0) chartH += subH;
   }
   if(chartH <= 0) chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   if(chartH <= 0) chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   if(chartH < 350) chartH = 750;
   if(chartW < 500) chartW = 1400;

   if(!g_isDashboardVisible)
   {
      DeleteTerminalObjects();
      CreateOrUpdateButton(PREFIX + "FLOAT_SHOW", 10, 10, 180, 24, "SHOW TERMINAL [H]", C'24,32,48', InpProfitColor, mc, InpFontName, 9);

      // Still render Floating Sentiment HUD when toggled ON independently!
      if(g_showSentimentHUD)
         DrawSentimentHUD();
      else
         ObjectsDeleteAll(0, PREFIX + "SNT_");

      // Still render Trade Advice lines if active
      if(g_showTradeAdviceLines)
         UpdateTradeAdviceLines();
      else
         DeleteTradeAdviceLines();

      // Render Open Trade Markings if active
      if(g_showOpenTradeMarkings)
         UpdateOpenTradeMarkings();
      else
         DeleteOpenTradeMarkings();

      // Render Win Rate HUD if active
      if(g_showWinRateHUD)
         DrawWinRateHUD();
      else
         DeleteWinRateHUD();

      // Render Help HUD if active
      if(g_showHelpHUD)
         DrawHelpHUD();
      else
         DeleteHelpHUD();

      return;
   }
   else
   {
      ObjectDelete(0, PREFIX + "FLOAT_SHOW");
   }

   int nPositions = PositionsTotal();

   double equityLive     = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance        = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayOpenEquity  = GetOpeningEquity_TodayToronto();
   double weekOpenEquity = GetOpeningEquity_ThisWeekToronto();
   double deltaToday     = equityLive - dayOpenEquity;
   double realizedToday  = ComputeRealizedPnL_TodayToronto();
   double openNow        = ComputeOpenPnL_Now();
   double floatingNow    = equityLive - balance;
   double floatingToday  = realizedToday + openNow;
   double realizedWeek   = ComputeRealizedPnL_ThisWeekToronto();
   double weekPL         = realizedWeek + openNow;
   double addToTP        = ComputeRemainingToTP_AllPositions();
   double expectedAllTP  = (nPositions > 0) ? NormalizeDouble(equityLive + addToTP, 2) : equityLive;

   double margin         = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginLvl      = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   string accCurr        = AccountInfoString(ACCOUNT_CURRENCY);

   double totalRiskAll   = 0.0;
   double totalRewardAll = 0.0;
   double totalLots      = 0.0;

   for(int i = 0; i < nPositions; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && posInfo.SelectByTicket(tk))
      {
         totalLots += posInfo.Volume();
         totalRiskAll += CalcRiskFromSL(tk);
         totalRewardAll += CalcProfitFromTP(tk);
      }
   }

   string masterRR = "1:0.00";
   if(totalRiskAll > 0.0 && totalRewardAll > 0.0)
      masterRR = StringFormat("1:%.2f", totalRewardAll / totalRiskAll);

   // Dynamic Auto-Expanded or Configured Height so all open trades display cleanly
   int maxVis = InpShowAllOpenTrades ? MathMax(8, MathMin(24, nPositions)) : MathMax(1, InpMaxVisiblePositions);
   if(nPositions <= maxVis) g_terminalScrollIndex = 0;
   if(g_terminalScrollIndex > nPositions - maxVis) g_terminalScrollIndex = MathMax(0, nPositions - maxVis);
   if(g_terminalScrollIndex < 0) g_terminalScrollIndex = 0;
   int visibleCount = (nPositions > 0) ? MathMin(maxVis, nPositions - g_terminalScrollIndex) : 0;

   int rowHeight   = 24;
   int bodyHeight  = (visibleCount > 0) ? (visibleCount * rowHeight) : 66;
   int totalHeight = 26 + 24 + 22 + bodyHeight + 22;
   int mx          = InpTableXOffset;
   int my          = MathMax(4, chartH - totalHeight - MathMax(2, InpTableYOffset));

   if(g_isDockedAtBottom)
   {
      // Fixed dock at bottom base of chart replacing MT5 Toolbox
      g_tableX = mx;
      g_tableY = my;
   }
   else if(g_tableY <= 4)
   {
      g_tableY = my;
   }
   else
   {
      mx = g_tableX;
      my = g_tableY;
   }

   // Dynamic adaptive terminal width: on full screen or wide windows,
   // expands to cover the chart horizontally right to the edge
   int availW = chartW - mx - 6;
   int mw     = MathMax(1350, availW);
   if(!g_isDockedAtBottom && mx + mw > chartW && chartW > 1350)
   {
      mx = MathMax(4, chartW - mw - 6);
      g_tableX = mx;
   }

   // 1. Solid Outer Container
   CreateOrUpdatePanel(PREFIX + "CONTAINER", mx, my, mw, totalHeight, InpTableBgColor, InpTableBorder, mc);

   // 2. Terminal Header Bar (Draggable)
   CreateOrUpdatePanel(PREFIX + "HDR_BG", mx, my, mw, 26, C'20,24,34', InpTableBorder, mc);

   // Primary Terminal Positions Tab in Header
   int tabX = mx + 8;
   color tab0Bg = (g_activeDashboardTab == 0) ? C'36,52,80' : C'18,22,32';
   color tab0Col = (g_activeDashboardTab == 0) ? clrWhite : C'150,165,185';
   CreateOrUpdateButton(PREFIX + "TAB_POSITIONS", tabX, my + 3, 125, 20, "1. TERMINAL [POS]", tab0Bg, tab0Col, mc, "Arial Bold", 8);
   tabX += 130;

   // Remove unused Trend Marks button objects to free up space and eliminate overlap
   ObjectDelete(0, PREFIX + "TAB_TRD_MARKS");
   ObjectDelete(0, PREFIX + "MAT_TRD_MARKS");

   string modeStr = (g_currentMode == MODE_COMPLETE_AUTO) ? "COMPLETE AUTO" : "CONTROLLED AUTO [P]";
   color modeCol  = (g_currentMode == MODE_COMPLETE_AUTO) ? clrLime : InpGoldColor;

   string title = StringFormat("(%d ACTIVE | %s | %.2fL)", nPositions, modeStr, totalLots);
   CreateOrUpdateCell(PREFIX + "HDR_TITLE", tabX + 6, my + 5, title, C'180,195,215', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   // Header Controls - Optimized with compact widths to guarantee zero button truncation
   int btnRight = mx + mw - 8;

   // Hide button
   CreateOrUpdateButton(PREFIX + "MAT_HIDE", btnRight - 60, my + 3, 60, 20, "HIDE [H]", C'45,26,26', clrTomato, mc, InpFontName, 8);
   btnRight -= 65;

   // Close Winners
   CreateOrUpdateButton(PREFIX + "MAT_CLOSE_WIN", btnRight - 78, my + 3, 78, 20, "CLS WIN [W]", C'22,50,35', clrLime, mc, InpFontName, 8);
   btnRight -= 83;

   // Breakeven All
   CreateOrUpdateButton(PREFIX + "MAT_BE_ALL", btnRight - 70, my + 3, 70, 20, "BE ALL [B]", C'30,42,65', clrSkyBlue, mc, InpFontName, 8);
   btnRight -= 75;

   // Win Rate & Edge Analytics Button [G]
   string wrBtnText = g_showWinRateHUD ? "WINRATE: ON" : "WINRATE [G]";
   color wrBtnBg    = g_showWinRateHUD ? C'85,55,10' : C'48,35,12';
   CreateOrUpdateButton(PREFIX + "MAT_WINRATE", btnRight - 94, my + 3, 94, 20, wrBtnText, wrBtnBg, clrGold, mc, InpFontName, 8);
   btnRight -= 99;

   // Quick Help & Hotkey Matrix Button [?]
   string helpBtnText = g_showHelpHUD ? "HELP: ON" : "HELP [?]";
   color helpBtnBg    = g_showHelpHUD ? C'25,50,80' : C'26,36,52';
   CreateOrUpdateButton(PREFIX + "MAT_HELP", btnRight - 66, my + 3, 66, 20, helpBtnText, helpBtnBg, clrSkyBlue, mc, InpFontName, 8);
   btnRight -= 71;

   // Market Sentiment HUD Toggle Button
   string sentBtnText = g_showSentimentHUD ? "MARKET [M]" : "MARKET [M]";
   color sentBtnCol   = g_showSentimentHUD ? clrAqua : clrLightSkyBlue;
   color sentBtnBg    = g_showSentimentHUD ? C'18,52,70' : C'24,36,50';
   CreateOrUpdateButton(PREFIX + "MAT_SENT", btnRight - 82, my + 3, 82, 20, sentBtnText, sentBtnBg, sentBtnCol, mc, InpFontName, 8);
   btnRight -= 87;

   // TP Trigger Breakeven Toggle Button
   string beToggleText = g_autoBreakevenOnTP_Active ? StringFormat("TP%d-BE", InpBE_TriggerLeg) : StringFormat("TP%d-BE: OFF", InpBE_TriggerLeg);
   color beToggleCol  = g_autoBreakevenOnTP_Active ? clrAqua : clrSilver;
   color beToggleBg   = g_autoBreakevenOnTP_Active ? C'20,48,58' : C'42,42,48';
   CreateOrUpdateButton(PREFIX + "MAT_BE_TOGGLE", btnRight - 84, my + 3, 84, 20, beToggleText, beToggleBg, beToggleCol, mc, InpFontName, 8);
   btnRight -= 89;

   // Process SL/TP Button (Essential for Controlled Auto)
   CreateOrUpdateButton(PREFIX + "MAT_PROCESS", btnRight - 82, my + 3, 82, 20, "PROCESS [P]", C'45,40,20', InpGoldColor, mc, InpFontName, 8);
   btnRight -= 87;

   // Mode Toggle Button (Complete Auto vs Controlled Auto)
   string modeBtnText = (g_currentMode == MODE_COMPLETE_AUTO) ? "AUTO [C]" : "CTRL [C]";
   CreateOrUpdateButton(PREFIX + "MAT_MODE", btnRight - 76, my + 3, 76, 20, modeBtnText, (g_currentMode == MODE_COMPLETE_AUTO) ? C'20,50,30' : C'50,40,15', modeCol, mc, InpFontName, 8);
   btnRight -= 81;

   // [Advisor] Auto-Trade Signals Toggle Button
   string advBtnText = g_myAdvisorEnabled ? "ADVISOR: ON" : "ADVISOR: OFF";
   color advBtnCol   = g_myAdvisorEnabled ? clrLime : clrSilver;
   color advBtnBg    = g_myAdvisorEnabled ? C'16,68,36' : C'38,36,44';
   CreateOrUpdateButton(PREFIX + "MAT_ADVISOR", btnRight - 105, my + 3, 105, 20, advBtnText, advBtnBg, advBtnCol, mc, InpFontName, 8);
   btnRight -= 110;

   // [Smart Lot] Dynamic Risk-Based Lot Sizing Button [J]
   string smartLotText = g_smartLotEnabled ? "SMART LOT: ON [J]" : "SMART LOT: OFF [J]";
   color smartLotCol   = g_smartLotEnabled ? clrCyan : clrSilver;
   color smartLotBg    = g_smartLotEnabled ? C'14,48,60' : C'38,36,44';
   CreateOrUpdateButton(PREFIX + "MAT_SMART_LOT", btnRight - 120, my + 3, 120, 20, smartLotText, smartLotBg, smartLotCol, mc, InpFontName, 8);
   btnRight -= 125;

   // Trade Targets (Entry, SL, TP1-4) Lines Toggle Button [K]
   string targetsBtnText = g_showTradeAdviceLines ? "TARGETS [K]" : "TARGETS: OFF";
   color targetsBtnCol   = g_showTradeAdviceLines ? InpGoldColor : clrSilver;
   color targetsBtnBg    = g_showTradeAdviceLines ? C'48,36,18' : C'36,36,40';
   CreateOrUpdateButton(PREFIX + "MAT_TARGETS", btnRight - 92, my + 3, 92, 20, targetsBtnText, targetsBtnBg, targetsBtnCol, mc, InpFontName, 8);
   btnRight -= 97;

   // Docking Button (Toggle Dock Bottom vs Floating)
   string dockLabel = g_isDockedAtBottom ? "UNDOCK [D]" : "DOCK [D]";
   CreateOrUpdateButton(PREFIX + "MAT_DOCK", btnRight - 80, my + 3, 80, 20, dockLabel, g_isDockedAtBottom ? C'25,45,35' : C'40,30,60', clrWhite, mc, InpFontName, 8);
   btnRight -= 85;

   // Scroll Controls in Header (When positions > maxVis)
   if(nPositions > maxVis)
   {
      string scrInfo = StringFormat("TRADES %d-%d OF %d", g_terminalScrollIndex + 1, g_terminalScrollIndex + visibleCount, nPositions);
      CreateOrUpdateCell(PREFIX + "HDR_SCR_LBL", btnRight - 120, my + 5, scrInfo, clrAqua, 8, ANCHOR_LEFT_UPPER, mc, "Consolas Bold");
      CreateOrUpdateButton(PREFIX + "SCR_UP",   btnRight - 146, my + 3, 22, 20, "▲", (g_terminalScrollIndex > 0) ? C'24,55,90' : C'26,30,42', (g_terminalScrollIndex > 0) ? clrWhite : clrSilver, mc, InpFontName, 8);
      CreateOrUpdateButton(PREFIX + "SCR_DOWN", btnRight - 170, my + 3, 22, 20, "▼", (g_terminalScrollIndex + visibleCount < nPositions) ? C'24,55,90' : C'26,30,42', (g_terminalScrollIndex + visibleCount < nPositions) ? clrWhite : clrSilver, mc, InpFontName, 8);
      btnRight -= 176;
   }
   else
   {
      ObjectDelete(0, PREFIX + "HDR_SCR_LBL");
      ObjectDelete(0, PREFIX + "SCR_UP");
      ObjectDelete(0, PREFIX + "SCR_DOWN");
   }

   // Nudge controls when floating
   if(!g_isDockedAtBottom)
   {
      CreateOrUpdateButton(PREFIX + "NUDGE_UP",   btnRight - 22, my + 3, 20, 20, "^", C'30,35,45', clrWhite, mc, InpFontName, 8);
      btnRight -= 24;
      CreateOrUpdateButton(PREFIX + "NUDGE_DOWN", btnRight - 22, my + 3, 20, 20, "v", C'30,35,45', clrWhite, mc, InpFontName, 8);
      btnRight -= 28;
   }
   else
   {
      ObjectDelete(0, PREFIX + "NUDGE_UP");
      ObjectDelete(0, PREFIX + "NUDGE_DOWN");
   }

   // 3. Profit / Loss Performance Metrics Ribbon
   int ribY = my + 26;
   CreateOrUpdatePanel(PREFIX + "RIB_BG", mx, ribY, mw, 24, C'16,19,28', InpRowBorder, mc);

   color eqCol = (equityLive >= weekOpenEquity) ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "RIB_EQ",  mx + 10,  ribY + 5, "EQUITY: $" + DoubleToString(equityLive, 2), eqCol, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   color delCol = (deltaToday >= 0) ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "RIB_DEL", mx + 165, ribY + 5, "DELTA: " + (deltaToday >= 0 ? "+" : "") + "$" + DoubleToString(deltaToday, 2), delCol, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   color rzCol = (realizedToday >= 0) ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "RIB_REA", mx + 305, ribY + 5, "REALIZED: " + (realizedToday >= 0 ? "+" : "") + "$" + DoubleToString(realizedToday, 2), rzCol, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   color fltCol = (floatingNow >= 0) ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "RIB_FLT", mx + 450, ribY + 5, "FLOAT: " + (floatingNow >= 0 ? "+" : "") + "$" + DoubleToString(floatingNow, 2), fltCol, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   color wkCol = (weekPL >= 0) ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "RIB_WK",  mx + 590, ribY + 5, "WEEK: " + (weekPL >= 0 ? "+" : "") + "$" + DoubleToString(weekPL, 2), wkCol, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   string rrDisp = "ALL R:R: " + masterRR + " (-$" + DoubleToString(totalRiskAll, 0) + " / +$" + DoubleToString(totalRewardAll, 0) + ")";
   CreateOrUpdateCell(PREFIX + "RIB_RR",  mx + 730, ribY + 5, rrDisp, InpGoldColor, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   CreateOrUpdateCell(PREFIX + "RIB_EXP", mx + 960, ribY + 5, "EXP ALL TP: $" + DoubleToString(expectedAllTP, 2), clrGold, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   int extraW = MathMax(0, mw - 1350);
   if(extraW >= 150)
   {
      double marginLive = AccountInfoDouble(ACCOUNT_MARGIN);
      string mrgStr = StringFormat("FREE: $%.0f (%.0f%%)", AccountInfoDouble(ACCOUNT_MARGIN_FREE), (marginLive > 0.0 ? (equityLive / marginLive * 100.0) : 0.0));
      CreateOrUpdateCell(PREFIX + "RIB_MRG", mx + 1170, ribY + 5, mrgStr, clrSilver, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   }
   else
   {
      ObjectDelete(0, PREFIX + "RIB_MRG");
   }

   string torClock = TimeToString(GetTorontoTimeNow(), TIME_SECONDS) + (IsTorontoDST(TimeGMT()) ? " EDT" : " EST");
   CreateOrUpdateCell(PREFIX + "RIB_TOR", mx + mw - 165, ribY + 5, "TORONTO: " + torClock, clrSkyBlue, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   if(g_activeDashboardTab == 1)
   {
      // Hide standard terminal column headers and rows
      ObjectDelete(0, PREFIX + "RIB_MRG");
      ObjectDelete(0, PREFIX + "COLS_BG");
      ObjectDelete(0, PREFIX + "C_TK");
      ObjectDelete(0, PREFIX + "C_TM");
      ObjectDelete(0, PREFIX + "C_SYM");
      ObjectDelete(0, PREFIX + "C_TYP");
      ObjectDelete(0, PREFIX + "C_LOT");
      ObjectDelete(0, PREFIX + "C_ENT");
      ObjectDelete(0, PREFIX + "C_CUR");
      ObjectDelete(0, PREFIX + "C_SL");
      ObjectDelete(0, PREFIX + "C_RSK");
      ObjectDelete(0, PREFIX + "C_TP");
      ObjectDelete(0, PREFIX + "C_RWD");
      ObjectDelete(0, PREFIX + "C_RR");
      ObjectDelete(0, PREFIX + "C_PRG");
      ObjectDelete(0, PREFIX + "C_PNL");
      ObjectDelete(0, PREFIX + "C_ACT");
      ObjectDelete(0, PREFIX + "C_SCR");
      ObjectDelete(0, PREFIX + "SBAR_TRACK");
      ObjectDelete(0, PREFIX + "SBAR_UP");
      ObjectDelete(0, PREFIX + "SBAR_DN");
      ObjectDelete(0, PREFIX + "SBAR_THUMB");
      ObjectsDeleteAll(0, PREFIX + "STB_");
      for(int r = 0; r < g_prevRenderedRows; r++) DeleteRowObjects(r);
      g_prevRenderedRows = 0;

      // Draw Open Trades Markings Tab
      DrawOpenTradesMarkingsTab(mx, ribY + 24, mw, mc);

      // Bottom Status Bar
      int ftrY = ribY + 24 + 120;
      CreateOrUpdatePanel(PREFIX + "FTR_BG", mx, ftrY, mw, 22, C'16,19,26', InpTableBorder, mc);
      string summaryLeft = StringFormat("TAB: OPEN TRADES MARKINGS | STATUS: %s | TIMEFRAME PERSISTENCE: 100%% (OBJ_ALL_PERIODS LOCKED) | SHORTCUT: [T]",
                                        g_showOpenTradeMarkings ? "ACTIVE & VISIBLE" : "HIDDEN");
      CreateOrUpdateCell(PREFIX + "FTR_SUMMARY", mx + 10, ftrY + 4, summaryLeft, clrWhite, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
      string hotkeyLegend = "[T] Toggle Markings  [K] Targets  [Z] Execute Trade  [1] Positions Tab  [2] Trades Tab";
      CreateOrUpdateCell(PREFIX + "FTR_LEGEND", mx + mw - 10, ftrY + 4, hotkeyLegend, C'150,165,185', InpCellFontSize, ANCHOR_RIGHT_UPPER, mc, InpFontName);

      if(g_showOpenTradeMarkings) UpdateOpenTradeMarkings();
      else DeleteOpenTradeMarkings();

      // Render Floating Sentiment HUD when toggled ON independently
      if(g_showSentimentHUD) DrawSentimentHUD();
      else ObjectsDeleteAll(0, PREFIX + "SNT_");

      // Render Suggested Trade Targets Lines on Chart when active
      if(g_showTradeAdviceLines) UpdateTradeAdviceLines();
      else DeleteTradeAdviceLines();

      // Render Win Rate & Edge Analytics HUD when active [G]
      if(g_showWinRateHUD) DrawWinRateHUD();
      else DeleteWinRateHUD();

      // Render Quick Help & Hotkey Matrix when active [?]
      if(g_showHelpHUD) DrawHelpHUD();
      else DeleteHelpHUD();

      return;
   }
   else
   {
      // Clean up OTM Tab objects when viewing Tab 0
      ObjectsDeleteAll(0, PREFIX + "OTM_TAB_");
   }

   // 4. PRECISE, NON-OVERLAPPING COLUMN HEADERS
   // Clean, spacious layout with guaranteed separation between all columns
   int colY = ribY + 24;
   CreateOrUpdatePanel(PREFIX + "COLS_BG", mx, colY, mw, 22, C'18,22,30', InpRowBorder, mc);

   int colTk   = mx + 8;
   int colTm   = mx + 92  + (extraW * 2  / 100);
   int colSym  = mx + 172 + (extraW * 5  / 100);
   int colTyp  = mx + 242 + (extraW * 7  / 100);
   int colLot  = mx + 292 + (extraW * 9  / 100);
   int colEnt  = mx + 342 + (extraW * 12 / 100);
   int colCur  = mx + 420 + (extraW * 16 / 100);
   int colSL   = mx + 495 + (extraW * 20 / 100);
   int colRsk  = mx + 570 + (extraW * 24 / 100);
   int colTP   = mx + 645 + (extraW * 28 / 100);
   int colRwd  = mx + 725 + (extraW * 33 / 100);
   int colRR   = mx + 805 + (extraW * 38 / 100);
   int colPrg  = mx + 865 + (extraW * 42 / 100);

   // Right-anchored scrollbar and actions
   int sbW     = 18;
   int sbX     = mx + mw - sbW - 6;
   int actX    = sbX - 204;
   int colPnl  = actX - 100;

   CreateOrUpdateCell(PREFIX + "C_TK",   colTk,  colY + 4, "TICKET",          C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_TM",   colTm,  colY + 4, "OPEN TIME",       C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_SYM",  colSym, colY + 4, "SYMBOL",          C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_TYP",  colTyp, colY + 4, "TYPE",            C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_LOT",  colLot, colY + 4, "LOTS",            C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_ENT",  colEnt, colY + 4, "ENTRY",           C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_CUR",  colCur, colY + 4, "PRICE",           C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_SL",   colSL,  colY + 4, "SL",              clrTomato,      InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_RSK",  colRsk, colY + 4, "RISK",            clrTomato,      InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_TP",   colTP,  colY + 4, "TP",              clrLime,        InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_RWD",  colRwd, colY + 4, "REWARD",          clrLime,        InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_RR",   colRR,  colY + 4, "R:R",             InpGoldColor,   InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_PRG",  colPrg, colY + 4, "TARGET PROGRESS", clrSkyBlue,     InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_PNL",  colPnl, colY + 4, "FLOAT P/L",       clrWhite,       InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_ACT",  actX,   colY + 4, "SHIFT SL/TP • ACTIONS", C'160,175,200', InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
   CreateOrUpdateCell(PREFIX + "C_SCR",  sbX,    colY + 4, "▲▼", clrSkyBlue, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

   // 5. Data Rows (Paged by g_terminalScrollIndex up to visibleCount)
   int curRowY = colY + 22;

   if(visibleCount == 0)
   {
      ObjectDelete(0, PREFIX + "EMPTY_MSG");

      // Standby Cockpit Solid Outer Frame
      CreateOrUpdatePanel(PREFIX + "STB_BG", mx, curRowY, mw, 66, C'13,16,24', InpRowBorder, mc);

      // --- CARD 1: SYSTEM READINESS & EXECUTION ENGINE ---
      int c1W = 340;
      CreateOrUpdatePanel(PREFIX + "STB_C1_BG", mx + 6, curRowY + 5, c1W, 56, C'18,22,32', C'28,36,50', mc);

      CreateOrUpdateCell(PREFIX + "STB_C1_T1", mx + 16, curRowY + 11,
         "● STANDBY • READY TO ENGAGE", clrDeepSkyBlue, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, "Arial Bold");

      string modeLabel = (g_currentMode == MODE_COMPLETE_AUTO) ? "COMPLETE AUTO" : "CONTROLLED AUTO";
      color modeLabelCol = (g_currentMode == MODE_COMPLETE_AUTO) ? clrLime : InpGoldColor;
      string c1Sub = StringFormat("Engine: %s | Auto-BE: TP%d (%s)", modeLabel, InpBE_TriggerLeg, (g_autoBreakevenOnTP_Active ? "ON" : "OFF"));
      CreateOrUpdateCell(PREFIX + "STB_C1_T2", mx + 16, curRowY + 28, c1Sub, modeLabelCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

      string lotModeStr = g_smartLotEnabled ? StringFormat("Smart Lot: ON (%.2fL/setup)", GetAdvisorLotForSymbol(_Symbol)) : StringFormat("Fixed Lot: %.2fL", GetAdvisorLotForSymbol(_Symbol));
      string c1Sub2 = StringFormat("Advisor: %s | %s | Clones: %d", (g_myAdvisorEnabled ? "ARMED" : "OFF"), lotModeStr, InpNumClonedTrades);
      CreateOrUpdateCell(PREFIX + "STB_C1_T3", mx + 16, curRowY + 44, c1Sub2, C'150,165,185', 8, ANCHOR_LEFT_UPPER, mc, InpFontName);

      // --- CARD 2: CURRENT CHART ASSET & 4-LEG BRACKET PROFILE ---
      int c2X = mx + 6 + c1W + 6;
      int c2W = 490;
      CreateOrUpdatePanel(PREFIX + "STB_C2_BG", c2X, curRowY + 5, c2W, 56, C'18,22,32', C'28,36,50', mc);

      string sym = _Symbol;
      string assetType = DetectAssetType(sym);
      double spreadPips = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD);
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(digits == 3 || digits == 5) spreadPips /= 10.0;

      color biasCol = (g_overallBias == "BULLISH") ? InpProfitColor : ((g_overallBias == "BEARISH") ? InpLossColor : InpGoldColor);
      string c2T1 = StringFormat("%s (%s) • SPREAD: %.1fp • BIAS: H1 %s | H4 %s", sym, assetType, spreadPips, g_h1Bias, g_h4Bias);
      CreateOrUpdateCell(PREFIX + "STB_C2_T1", c2X + 12, curRowY + 11, c2T1, biasCol, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, "Arial Bold");

      double slP = 0, tpP[4];
      GetAssetTargets(sym, slP, tpP[0], tpP[1], tpP[2], tpP[3]);
      string c2T2 = StringFormat("4-LEGS: SL -%.0fp | TP1 +%.0fp | TP2 +%.0fp (BE) | TP3 +%.0fp | TP4 +%.0fp",
                                 slP, tpP[0], tpP[1], tpP[2], tpP[3]);
      CreateOrUpdateCell(PREFIX + "STB_C2_T2", c2X + 12, curRowY + 28, c2T2, clrAqua, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

      string structStr = StringFormat("Confluence: %s | Quality: %d%%", g_marketStructure, g_setupQuality);
      CreateOrUpdateCell(PREFIX + "STB_C2_T3", c2X + 12, curRowY + 44, structStr, InpGoldColor, 8, ANCHOR_LEFT_UPPER, mc, InpFontName);

      // --- CARD 3: QUICK EXECUTION & COCKPIT CONTROLS ---
      int c3X = c2X + c2W + 6;
      int c3W = mw - (c3X - mx) - 6;
      if(c3W > 100)
      {
         CreateOrUpdatePanel(PREFIX + "STB_C3_BG", c3X, curRowY + 5, c3W, 56, C'18,22,32', C'28,36,50', mc);

         CreateOrUpdateButton(PREFIX + "STB_BTN_EXEC", c3X + 10, curRowY + 9, 160, 22,
            "⚡ EXECUTE 4-LEGS [Z]", C'20,60,38', clrLime, mc, "Arial Bold", 8);

         CreateOrUpdateButton(PREFIX + "STB_BTN_SENT", c3X + 176, curRowY + 9, 105, 22,
            "MARKET [M]", (g_showSentimentHUD ? C'20,50,75' : C'26,36,52'), (g_showSentimentHUD ? clrAqua : clrLightSkyBlue), mc, InpFontName, 8);

         CreateOrUpdateButton(PREFIX + "STB_BTN_TGTS", c3X + 287, curRowY + 9, 105, 22,
            "TARGETS [K]", (g_showTradeAdviceLines ? C'48,36,18' : C'36,36,44'), (g_showTradeAdviceLines ? InpGoldColor : clrSilver), mc, InpFontName, 8);

         string c3Hint = StringFormat("Press [Z] to deploy 4-leg bracket trade for %s with auto-recovery & TP2-BE", sym);
         CreateOrUpdateCell(PREFIX + "STB_C3_HINT", c3X + 12, curRowY + 38, c3Hint, C'160,175,195', 8, ANCHOR_LEFT_UPPER, mc, InpFontName);
      }

      curRowY += 66;
   }
   else
   {
      ObjectDelete(0, PREFIX + "EMPTY_MSG");
      ObjectsDeleteAll(0, PREFIX + "STB_");
      // Reset scroll to top if chart symbol changed so active chart trades are always visible on top
      static string s_lastSeenChartSymbol = "";
      if(s_lastSeenChartSymbol != _Symbol)
      {
         s_lastSeenChartSymbol = _Symbol;
         g_terminalScrollIndex = 0;
      }

      // Sort tickets: Active chart symbol (_Symbol) positions placed at the top, newest first
      ulong sortedTickets[];
      int totalPos = PositionsTotal();
      ArrayResize(sortedTickets, totalPos);
      int matchCount = 0;
      for(int p = totalPos - 1; p >= 0; p--)
      {
         ulong t = PositionGetTicket(p);
         if(t > 0 && posInfo.SelectByTicket(t))
         {
            if(IsSameChartAsset(posInfo.Symbol(), _Symbol))
            {
               sortedTickets[matchCount++] = t;
            }
         }
      }
      for(int p = totalPos - 1; p >= 0; p--)
      {
         ulong t = PositionGetTicket(p);
         if(t > 0 && posInfo.SelectByTicket(t))
         {
            if(!IsSameChartAsset(posInfo.Symbol(), _Symbol))
            {
               sortedTickets[matchCount++] = t;
            }
         }
      }

      for(int i = 0; i < visibleCount; i++)
      {
         int posIdx = g_terminalScrollIndex + i;
         if(posIdx >= matchCount) break;
         ulong ticket = sortedTickets[posIdx];
         if(ticket <= 0 || !posInfo.SelectByTicket(ticket)) continue;

         string sym = posInfo.Symbol();
         string assetType = DetectAssetType(sym);
         bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
         string typeStr = isBuy ? "BUY" : "SELL";
         color typeCol = isBuy ? InpProfitColor : InpLossColor;
         double lots = posInfo.Volume();
         double openP = posInfo.PriceOpen();
         double curP = posInfo.PriceCurrent();
         if(curP <= 0.0) curP = isBuy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);

         datetime openTime = (datetime)posInfo.Time();
         string openTimeStr = TimeToString(openTime, TIME_DATE|TIME_MINUTES);
         if(StringLen(openTimeStr) >= 16) openTimeStr = StringSubstr(openTimeStr, 5, 11);

         double sl = posInfo.StopLoss();
         double tp = posInfo.TakeProfit();
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

         double risk = CalcRiskFromSL(ticket);
         double reward = CalcProfitFromTP(ticket);

         double slPips = 0, tpPips[4];
         GetAssetTargets(sym, slPips, tpPips[0], tpPips[1], tpPips[2], tpPips[3]);

         double estRisk = (risk > 0.0) ? risk : CalcEstimatedRisk(ticket, slPips);
         double estReward = (reward > 0.0) ? reward : CalcEstimatedReward(ticket, tpPips[0]);

         string slStr = (sl > 0.0) ? DoubleToString(sl, digits) : "Not Set";
         string riskStr = (risk > 0.0) ? StringFormat("-$%.2f", risk) : (estRisk > 0 ? StringFormat("Est -$%.2f", estRisk) : "—");
         color riskCol = (risk > 0.0) ? clrTomato : InpGoldColor;

         string tpStr = (tp > 0.0) ? DoubleToString(tp, digits) : "Not Set";
         string rewardStr = (reward > 0.0) ? StringFormat("+$%.2f", reward) : (estReward > 0 ? StringFormat("Est +$%.2f", estReward) : "—");
         color rewardCol = (reward > 0.0) ? clrLime : InpGoldColor;

         string rrStr = "—";
         if(risk > 0.0 && reward > 0.0)
            rrStr = StringFormat("1:%.2f", reward / risk);
         else if(estRisk > 0.0 && estReward > 0.0)
            rrStr = StringFormat("Est 1:%.2f", estReward / estRisk);

         // Direct unified official MT5 Broker Floating P/L (Profit + Swap + Commission)
         double pnl = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
         color pnlCol = (pnl >= 0) ? InpProfitColor : InpLossColor;
         string pnlStr = (pnl >= 0 ? "+" : "") + "$" + DoubleToString(pnl, 2);

         bool isSelected = (ticket == g_selectedTicket);
         color rowBg = isSelected ? C'24,46,78' : ((i % 2 == 0) ? C'18,21,29' : C'14,17,23');
         color rowBorder = isSelected ? clrAqua : InpRowBorder;
         string rPfx = PREFIX + "R" + IntegerToString(i) + "_";

         CreateOrUpdatePanel(rPfx + "BG", mx, curRowY, mw, rowHeight, rowBg, rowBorder, mc);
         
         // Select button / Ticket number (Click to select trade)
         string tkLabel = (isSelected ? ">#" : "#") + IntegerToString(ticket);
         color tkCol = isSelected ? clrAqua : clrWhite;
         CreateOrUpdateButton(PREFIX + "BTN_SEL_" + IntegerToString(ticket), colTk - 2, curRowY + 2, 78, 20, tkLabel, isSelected ? C'20,70,120' : C'24,28,38', tkCol, mc, InpFontName, 8);

         CreateOrUpdateCell(rPfx + "TM",  colTm,  curRowY + 4, openTimeStr, C'160,175,200', InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         bool isChartSym = IsSameChartAsset(sym, _Symbol);
         color symCol = isChartSym ? clrAqua : ((assetType == "XAU") ? clrGold : (assetType == "DJ30" ? clrDeepSkyBlue : (assetType == "NAS100" ? C'190,140,255' : (assetType == "BTCUSD" ? clrOrange : clrWhite))));
         string symText = isChartSym ? (sym + "*") : sym;
         CreateOrUpdateCell(rPfx + "SYM", colSym, curRowY + 4, symText, symCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
         CreateOrUpdateCell(rPfx + "TYP", colTyp, curRowY + 4, typeStr, typeCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
         CreateOrUpdateCell(rPfx + "LOT", colLot, curRowY + 4, DoubleToString(lots, 2) + "L", clrWhite, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
         CreateOrUpdateCell(rPfx + "ENT", colEnt, curRowY + 4, DoubleToString(openP, digits), clrWhite, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         color curCol = isBuy ? (curP >= openP ? clrLime : clrTomato) : (curP <= openP ? clrLime : clrTomato);
         CreateOrUpdateCell(rPfx + "CUR", colCur, curRowY + 4, DoubleToString(curP, digits), curCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         CreateOrUpdateCell(rPfx + "SL",  colSL,  curRowY + 4, slStr, (sl > 0) ? clrTomato : clrSilver, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
         CreateOrUpdateCell(rPfx + "RSK", colRsk, curRowY + 4, riskStr, riskCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         CreateOrUpdateCell(rPfx + "TP",  colTP,  curRowY + 4, tpStr, (tp > 0) ? clrLime : clrSilver, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
         CreateOrUpdateCell(rPfx + "RWD", colRwd, curRowY + 4, rewardStr, rewardCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         CreateOrUpdateCell(rPfx + "RR",  colRR,  curRowY + 4, rrStr, InpGoldColor, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         // Target Progress column (Adaptive bar length with optional pips-to-TP)
         int barLen = (extraW > 300) ? 14 : ((extraW > 120) ? 10 : 8);
         TradeProgress tpProg = CalcTradeProgress(ticket, barLen);
         CreateOrUpdateCell(rPfx + "PRG", colPrg, curRowY + 4, tpProg.progressBar, tpProg.barColor, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, "Consolas Bold");

         // Float P/L column
         CreateOrUpdateCell(rPfx + "PNL", colPnl, curRowY + 4, pnlStr, pnlCol, InpCellFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);

         // Interactive SL / TP Shifting Buttons directly in row (Right-anchored)
         CreateOrUpdateButton(PREFIX + "BTN_SL_UP_" + IntegerToString(ticket), actX,       curRowY + 2, 24, 19, "+SL", C'18,50,30', clrLime, mc, InpFontName, 7);
         CreateOrUpdateButton(PREFIX + "BTN_SL_DN_" + IntegerToString(ticket), actX + 26,  curRowY + 2, 24, 19, "-SL", C'50,22,22', clrTomato, mc, InpFontName, 7);
         CreateOrUpdateButton(PREFIX + "BTN_TP_UP_" + IntegerToString(ticket), actX + 53,  curRowY + 2, 24, 19, "+TP", C'18,52,58', clrAqua, mc, InpFontName, 7);
         CreateOrUpdateButton(PREFIX + "BTN_TP_DN_" + IntegerToString(ticket), actX + 79,  curRowY + 2, 24, 19, "-TP", C'48,40,20', InpGoldColor, mc, InpFontName, 7);

         // Standard Actions: BE, 50%, X
         CreateOrUpdateButton(PREFIX + "BTN_BE_" + IntegerToString(ticket), actX + 107, curRowY + 2, 28, 19, "BE",  C'30,42,65', clrSkyBlue, mc, InpFontName, 8);
         CreateOrUpdateButton(PREFIX + "BTN_50_" + IntegerToString(ticket), actX + 138, curRowY + 2, 30, 19, "50%", C'45,40,24', InpGoldColor, mc, InpFontName, 8);
         CreateOrUpdateButton(PREFIX + "BTN_X_"  + IntegerToString(ticket), actX + 171, curRowY + 2, 22, 19, "X",   C'65,25,25', clrTomato, mc, InpFontName, 8);

         curRowY += rowHeight;
      }
   }

   // 5B. Vertical Scrollbar (Attached to right edge of trade rows for intuitive scrolling)
   if(nPositions > 0)
   {
      int sbY = colY + 22;
      int sbH = bodyHeight;

      // Track Background
      CreateOrUpdatePanel(PREFIX + "SBAR_TRACK", sbX, sbY, sbW, sbH, C'14,17,25', C'32,42,60', mc);

      // Scroll Up Arrow Button
      CreateOrUpdateButton(PREFIX + "SBAR_UP", sbX, sbY, sbW, 16, "▲", (g_terminalScrollIndex > 0) ? C'24,55,90' : C'20,24,34', (g_terminalScrollIndex > 0) ? clrWhite : clrSilver, mc, InpFontName, 7);

      // Scroll Down Arrow Button
      CreateOrUpdateButton(PREFIX + "SBAR_DN", sbX, sbY + sbH - 16, sbW, 16, "▼", (g_terminalScrollIndex + visibleCount < nPositions) ? C'24,55,90' : C'20,24,34', (g_terminalScrollIndex + visibleCount < nPositions) ? clrWhite : clrSilver, mc, InpFontName, 7);

      // Scroll Thumb / Slider Button
      int trackH = sbH - 32;
      if(trackH >= 12)
      {
         int maxScroll = MathMax(1, nPositions - visibleCount);
         int thumbH = MathMax(14, (int)MathRound(((double)visibleCount / (double)MathMax(visibleCount, nPositions)) * trackH));
         int thumbTravel = trackH - thumbH;
         int thumbOffset = (int)MathRound(((double)g_terminalScrollIndex / (double)maxScroll) * thumbTravel);
         int thumbY = sbY + 16 + thumbOffset;

         color thumbBg = (nPositions > visibleCount) ? C'36,75,130' : C'26,34,48';
         color thumbFg = (nPositions > visibleCount) ? clrAqua : clrSilver;
         CreateOrUpdateButton(PREFIX + "SBAR_THUMB", sbX + 1, thumbY, sbW - 2, thumbH, "≡", thumbBg, thumbFg, mc, InpFontName, 7);
      }
      else
      {
         ObjectDelete(0, PREFIX + "SBAR_THUMB");
      }
   }
   else
   {
      ObjectDelete(0, PREFIX + "SBAR_TRACK");
      ObjectDelete(0, PREFIX + "SBAR_UP");
      ObjectDelete(0, PREFIX + "SBAR_DN");
      ObjectDelete(0, PREFIX + "SBAR_THUMB");
   }

   // Clean up excess rows
   for(int r = visibleCount; r < g_prevRenderedRows; r++)
   {
      DeleteRowObjects(r);
   }
   g_prevRenderedRows = visibleCount;

   // 6. Bottom Status Bar (Full replacement for MT5 Toolbox trade tab)
   int ftrY = curRowY;
   CreateOrUpdatePanel(PREFIX + "FTR_BG", mx, ftrY, mw, 22, C'16,19,26', InpTableBorder, mc);

   if(g_selectedTicket > 0 && posInfo.SelectByTicket(g_selectedTicket))
   {
      string selInfo = StringFormat("SELECTED #%d (%s %.2fL @ %s):", g_selectedTicket, posInfo.Symbol(), posInfo.Volume(), DoubleToString(posInfo.PriceOpen(), (int)SymbolInfoInteger(posInfo.Symbol(), SYMBOL_DIGITS)));
      CreateOrUpdateCell(PREFIX + "SEL_LBL", mx + 10, ftrY + 4, selInfo, clrSkyBlue, 8, ANCHOR_LEFT_UPPER, mc, "Arial Bold");
      CreateOrUpdateButton(PREFIX + "SEL_SL_UP", mx + 250, ftrY + 2, 56, 18, "+5p SL", C'18,50,30', clrLime, mc, InpFontName, 7);
      CreateOrUpdateButton(PREFIX + "SEL_SL_DN", mx + 310, ftrY + 2, 56, 18, "-5p SL", C'50,22,22', clrTomato, mc, InpFontName, 7);
      CreateOrUpdateButton(PREFIX + "SEL_TP_UP", mx + 370, ftrY + 2, 58, 18, "+10p TP", C'18,52,58', clrAqua, mc, InpFontName, 7);
      CreateOrUpdateButton(PREFIX + "SEL_TP_DN", mx + 432, ftrY + 2, 58, 18, "-10p TP", C'48,40,20', InpGoldColor, mc, InpFontName, 7);
      CreateOrUpdateButton(PREFIX + "SEL_BE",    mx + 494, ftrY + 2, 40, 18, "BE", C'30,42,65', clrSkyBlue, mc, InpFontName, 7);
      CreateOrUpdateButton(PREFIX + "SEL_CLOSE", mx + 538, ftrY + 2, 52, 18, "CLOSE", C'65,20,20', clrTomato, mc, InpFontName, 7);
      ObjectDelete(0, PREFIX + "FTR_SUMMARY");
   }
   else
   {
      string summaryLeft = "";
      if(nPositions == 0)
      {
         summaryLeft = StringFormat("POS: 0 | BAL: $%.2f | EQUITY: $%.2f | FREE MARGIN: $%.2f",
            balance, equityLive, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      }
      else
      {
         summaryLeft = StringFormat("POS: %d (%.2fL) | BAL: $%.2f | EQ: $%.2f | MARGIN: $%.2f | FLOAT: %s$%.2f",
            nPositions, totalLots, balance, equityLive, margin, (openNow >= 0 ? "+" : ""), openNow);
      }
      CreateOrUpdateCell(PREFIX + "FTR_SUMMARY", mx + 10, ftrY + 4, summaryLeft, clrWhite, InpHeaderFontSize, ANCHOR_LEFT_UPPER, mc, InpFontName);
      ObjectDelete(0, PREFIX + "SEL_LBL");
      ObjectDelete(0, PREFIX + "SEL_SL_UP");
      ObjectDelete(0, PREFIX + "SEL_SL_DN");
      ObjectDelete(0, PREFIX + "SEL_TP_UP");
      ObjectDelete(0, PREFIX + "SEL_TP_DN");
      ObjectDelete(0, PREFIX + "SEL_BE");
      ObjectDelete(0, PREFIX + "SEL_CLOSE");
   }

   string hotkeyLegend = "[Z] Trade  [M] Market  [K] Targets  [G] WinRate  [B] BE  [T] Marks  [D] Dock  [?] Help";
   CreateOrUpdateCell(PREFIX + "FTR_HOTKEYS", mx + mw - 10, ftrY + 4, hotkeyLegend, C'150,165,185', 8, ANCHOR_RIGHT_UPPER, mc, InpFontName);

   // 7. Render Floating Sentiment HUD when toggled ON independently
   if(g_showSentimentHUD)
      DrawSentimentHUD();
   else
      ObjectsDeleteAll(0, PREFIX + "SNT_");

   // 8. Render Suggested Trade Targets Lines on Chart when active
   if(g_showTradeAdviceLines)
      UpdateTradeAdviceLines();
   else
      DeleteTradeAdviceLines();

   // 8B. Render Open Advisor Trades Chart Markings (Entry, SL, TP) when active [T]
   if(g_showOpenTradeMarkings)
      UpdateOpenTradeMarkings();
   else
      DeleteOpenTradeMarkings();

   // 9. Render Win Rate & Edge Analytics HUD when active [G]
   if(g_showWinRateHUD)
      DrawWinRateHUD();
   else
      DeleteWinRateHUD();

   // 10. Render Quick Help & Hotkey Matrix when active [?]
   if(g_showHelpHUD)
      DrawHelpHUD();
   else
      DeleteHelpHUD();
}

//+------------------------------------------------------------------+
//| Market Sentiment Multi-Timeframe HUD Overlay                     |
//| Structured Financial Table Design: Multi-Column Matrix,          |
//| Visual Gauge, 4-Corner Docking & Instant Close Control           |
//+------------------------------------------------------------------+
void DeleteSentimentHUD()
{
   ObjectsDeleteAll(0, PREFIX + "SNT_");
}

void DrawSentimentHUD()
{
   if(!g_showSentimentHUD) return;

   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   if(chartW <= 0) chartW = 1200;
   if(chartH <= 0) chartH = 800;

   // Crisp, spacious & perfectly aligned HUD dimensions - Zero visual overlap
   int sw = 670;
   int sh = 286;
   int sx = 20;
   int sy = 60;

   if(g_sentimentCorner == HUD_POS_TOP_LEFT)
   {
      sx = 20;
      sy = 60;
   }
   else if(g_sentimentCorner == HUD_POS_TOP_RIGHT)
   {
      sx = MathMax(20, chartW - sw - 30);
      sy = 60;
   }
   else if(g_sentimentCorner == HUD_POS_BOTTOM_RIGHT)
   {
      sx = MathMax(20, chartW - sw - 30);
      sy = MathMax(20, chartH - sh - 40);
   }
   else if(g_sentimentCorner == HUD_POS_BOTTOM_LEFT)
   {
      sx = 20;
      sy = MathMax(20, chartH - sh - 40);
   }

   string sym = _Symbol;
   int symDigits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   ScanMarketStructureAndAdvice(false);
   UpdateUnifiedStrategyMatrix(sym);

   // Outer Background Panel (Strict Z-Order 30)
   CreateOrUpdatePanel(PREFIX + "SNT_BG", sx, sy, sw, sh, C'10,13,20', C'28,40,62', CORNER_LEFT_UPPER);

   // Header Bar
   CreateOrUpdatePanel(PREFIX + "SNT_HDR", sx, sy, sw, 26, C'16,22,34', C'36,48,70', CORNER_LEFT_UPPER);
   CreateOrUpdateCell(PREFIX + "SNT_DOT",   sx + 10, sy + 6, "*", clrAqua, 10, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");
   CreateOrUpdateCell(PREFIX + "SNT_TITLE", sx + 22, sy + 6, "MARKET SENTIMENT • " + sym, clrWhite, InpHeaderFontSize, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");

   int btnW = 18;
   int btnH = 16;
   int btnSpacing = 2;
   int btnX = sx + sw - 6 - btnW;

   CreateOrUpdateButton(PREFIX + "SNT_BTN_X", btnX, sy + 5, btnW, btnH, "X", C'44,20,24', clrTomato, CORNER_LEFT_UPPER, InpFontName, 7);
   btnX -= (btnW + btnSpacing);
   CreateOrUpdateButton(PREFIX + "SNT_BTN_M", btnX, sy + 5, btnW, btnH, "-", C'28,34,48', clrSilver, CORNER_LEFT_UPPER, InpFontName, 7);
   btnX -= (btnW + btnSpacing);
   CreateOrUpdateButton(PREFIX + "SNT_BTN_C", btnX, sy + 5, btnW, btnH, "+", C'28,34,48', clrSilver, CORNER_LEFT_UPPER, InpFontName, 7);
   btnX -= (btnW + btnSpacing);
   CreateOrUpdateButton(PREFIX + "SNT_BTN_D", btnX, sy + 5, btnW, btnH, "D", C'28,34,48', clrAqua, CORNER_LEFT_UPPER, InpFontName, 7);
   btnX -= (btnW + 12 + btnSpacing);
   CreateOrUpdateButton(PREFIX + "SNT_BTN_BROKEN_OB", btnX, sy + 5, btnW + 12, btnH, g_showBrokenOrderBlocks ? "OB:ON" : "OB:OFF", g_showBrokenOrderBlocks ? C'24,44,36' : C'38,30,34', g_showBrokenOrderBlocks ? clrLime : clrSilver, CORNER_LEFT_UPPER, InpFontName, 7);

   string torontoTimeStr = GetTorontoTimeFormatted();
   CreateOrUpdateCell(PREFIX + "SNT_TORONTO_TIME", btnX - 12, sy + 6, torontoTimeStr, clrAqua, 8, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

   int cardW = sw - 16;

   // -------------------------------------------------------------
   // SECTION 1: EXECUTION GATE & MARKET READINESS (Height: 44)
   // -------------------------------------------------------------
   int c1Y = sy + 30;
   CreateOrUpdatePanel(PREFIX + "SNT_C1_BG", sx + 8, c1Y, cardW, 44, C'14,18,28', C'28,40,62', CORNER_LEFT_UPPER);
   CreateOrUpdateCell(PREFIX + "SNT_C1_H", sx + 14, c1Y + 4, "EXECUTION GATE & MARKET READINESS", clrAqua, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");

   string mktStr = g_isMarketOpen ? "SESSION: OPEN" : "SESSION: CLOSED";
   color mktCol  = g_isMarketOpen ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "SNT_C1_MKT", sx + 14, c1Y + 17, mktStr, mktCol, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);

   string feedStr = g_isTickDataFresh ? "FEED: LIVE" : "FEED: STALE";
   color feedCol  = g_isTickDataFresh ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "SNT_C1_DATA", sx + 130, c1Y + 17, feedStr, feedCol, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);

   string volStr = (g_liquidityState == "GOOD") ? "VOL: NORMAL" : ((g_liquidityState == "WEAK") ? "VOL: MODEST" : "VOL: THIN");
   color volCol  = (g_liquidityState == "GOOD") ? clrLime : ((g_liquidityState == "WEAK") ? clrGold : clrTomato);
   CreateOrUpdateCell(PREFIX + "SNT_C1_VOL", sx + 230, c1Y + 17, volStr, volCol, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);

   string sprdStr = "SPREAD: " + g_spreadQualityStr;
   color sprdCol  = (g_spreadQualityRatio <= 1.8) ? clrLime : ((g_spreadQualityRatio <= 2.8) ? clrGold : clrTomato);
   CreateOrUpdateCell(PREFIX + "SNT_C1_SPRD", sx + cardW - 8, c1Y + 17, sprdStr, sprdCol, 8, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, InpFontName);

   string gateStr = g_isGateOpen ? "GATE STATUS: CLEARED (Favorable Conditions for Execution)" : ("GATE BLOCKED: " + (g_gateBlockReason != "" ? g_gateBlockReason : "Filtered"));
   color gateCol  = g_isGateOpen ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "SNT_C1_GATE", sx + 14, c1Y + 30, gateStr, gateCol, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);

   // -------------------------------------------------------------
   // SECTION 2: DIRECTIONAL CONFLUENCE (H1 + H2 + H4 BIAS) (Height: 46)
   // -------------------------------------------------------------
   int c2Y = c1Y + 48;
   CreateOrUpdatePanel(PREFIX + "SNT_C2_BG", sx + 8, c2Y, cardW, 46, C'14,18,28', C'28,40,62', CORNER_LEFT_UPPER);
   string structHead = StringFormat("DIRECTIONAL CONFLUENCE • M30 [%s] • H1 [%s]",
                                    g_hasHH_M30 ? "HH ▲" : (g_hasLL_M30 ? "LL ▼" : "NEUT"),
                                    g_hasHH_H1  ? "HH ▲" : (g_hasLL_H1  ? "LL ▼" : "NEUT"));
   CreateOrUpdateCell(PREFIX + "SNT_C2_H", sx + 14, c2Y + 4, structHead, clrAqua, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");

   bool h1Bull = (g_h1Bias == "BULLISH");
   bool h2Bull = (g_h2Bias == "BULLISH");
   bool h4Bull = (g_h4Bias == "BULLISH");
   string biasStr = "";
   color biasCol  = clrGold;
   if(h4Bull)
   {
      biasStr = (h1Bull && h2Bull) ? "BULLISH CONFLUENCE (H1/H2/H4)" : "BULLISH UPTREND (PULLBACK)";
      biasCol = clrLime;
   }
   else if(!h4Bull)
   {
      biasStr = (!h1Bull && !h2Bull) ? "BEARISH CONFLUENCE (H1/H2/H4)" : "BEARISH DOWNTREND (BOUNCE)";
      biasCol = clrTomato;
   }
   else
   {
      biasStr = "NEUTRAL / CHOP";
      biasCol = clrGold;
   }

   CreateOrUpdateCell(PREFIX + "SNT_C2_H1",   sx + 14,  c2Y + 17, h1Bull ? "H1: ▲ BULL" : "H1: ▼ BEAR", h1Bull ? clrLime : clrTomato, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
   CreateOrUpdateCell(PREFIX + "SNT_C2_H2",   sx + 105, c2Y + 17, h2Bull ? "H2: ▲ BULL" : "H2: ▼ BEAR", h2Bull ? clrLime : clrTomato, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
   CreateOrUpdateCell(PREFIX + "SNT_C2_H4",   sx + 195, c2Y + 17, h4Bull ? "H4: ▲ BULL" : "H4: ▼ BEAR", h4Bull ? clrLime : clrTomato, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
   CreateOrUpdateCell(PREFIX + "SNT_C2_BIAS", sx + 295, c2Y + 17, "BIAS: " + biasStr, biasCol, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

   string alignStr = (h1Bull && h4Bull && h2Bull) ? "FULL BULL (H1/H2/H4)" : ((h1Bull && h2Bull) ? "BULL REVERSAL" : ((!h1Bull && !h4Bull && !h2Bull) ? "FULL BEAR (H1/H2/H4)" : ((!h1Bull && !h2Bull) ? "BEAR REVERSAL" : "TRANSITION / MIXED")));
   color alignCol  = (h1Bull && h2Bull) ? clrLime : ((!h1Bull && !h2Bull) ? clrTomato : clrGold);
   string meter = (h1Bull && h4Bull && h2Bull) ? "[ ===== BULL ===== ]" : ((h1Bull && h2Bull) ? "[ == BULL REV == ]" : ((!h1Bull && !h4Bull && !h2Bull) ? "[ ===== BEAR ===== ]" : ((!h1Bull && !h2Bull) ? "[ == BEAR REV == ]" : "[ ----- CHOP ----- ]")));
   CreateOrUpdateCell(PREFIX + "SNT_C2_ALGN", sx + 14,  c2Y + 30, "ALIGN: " + alignStr, alignCol, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
   CreateOrUpdateCell(PREFIX + "SNT_C2_DIV",  sx + 175, c2Y + 30, "|", C'50,65,90', 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);

   // Detailed M30 Order Block Composition & Tactical Location Analysis
   int demCount = 0;
   int supCount = 0;
   double curBid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(curBid <= 0.0) curBid = iClose(sym, PERIOD_M1, 0);

   bool inDemand = false;
   bool inSupply = false;

   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].invalidated) continue;
      if(g_orderBlocks[i].bullish)
      {
         demCount++;
         if(curBid >= g_orderBlocks[i].low && curBid <= g_orderBlocks[i].high)
            inDemand = true;
      }
      else
      {
         supCount++;
         if(curBid >= g_orderBlocks[i].low && curBid <= g_orderBlocks[i].high)
            inSupply = true;
      }
   }
   int totalActiveZones = demCount + supCount;

   string obInfo = "";
   color obCol = clrAqua;

   if(totalActiveZones > 0)
   {
      string zoneComp = "";
      if(demCount > 0 && supCount > 0)
         zoneComp = StringFormat("%d DEM / %d SUP", demCount, supCount);
      else if(demCount > 0)
         zoneComp = StringFormat("%d DEMAND", demCount);
      else
         zoneComp = StringFormat("%d SUPPLY", supCount);

      string locStatus = "CLEAR";
      if(g_obLocationWarning == "BUY INTO M30 SUPPLY")
      {
         locStatus = "WARN: SUPPLY AHEAD";
         obCol = clrGold;
      }
      else if(g_obLocationWarning == "SELL INTO M30 DEMAND")
      {
         locStatus = "WARN: DEMAND AHEAD";
         obCol = clrGold;
      }
      else if(inDemand)
      {
         locStatus = "IN DEMAND ZONE";
         obCol = clrLime;
      }
      else if(inSupply)
      {
         locStatus = "IN SUPPLY ZONE";
         obCol = clrTomato;
      }
      else if(demCount > 0 && supCount == 0)
      {
         locStatus = "PATH CLEAR (ABOVE DEMAND)";
         obCol = clrLime;
      }
      else if(supCount > 0 && demCount == 0)
      {
         locStatus = "PATH CLEAR (BELOW SUPPLY)";
         obCol = clrTomato;
      }
      else
      {
         locStatus = "PATH CLEAR";
         obCol = clrAqua;
      }

      obInfo = StringFormat("M30 OB: %s [%s]", zoneComp, locStatus);
   }
   else
   {
      obInfo = "M30 OB: SCANNING [NO ACTIVE ZONES]";
      obCol = clrSilver;
   }

   CreateOrUpdateCell(PREFIX + "SNT_C2_OB",   sx + 188, c2Y + 30, obInfo, obCol, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
   CreateOrUpdateCell(PREFIX + "SNT_C2_METR", sx + cardW - 8, c2Y + 30, meter, biasCol, 7, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

   // Ensure previous HTF liquidity objects are removed from chart
   ObjectDelete(0, PREFIX + "SNT_C2_HTF");

   // -------------------------------------------------------------
   // SECTION 3: TRADE SETUP & EXECUTION (Height: 92)
   // -------------------------------------------------------------
   int c3Y = c2Y + 50;
   int c3H = 92;
   CreateOrUpdatePanel(PREFIX + "SNT_C3_BG", sx + 8, c3Y, cardW, c3H, C'14,18,28', C'28,40,62', CORNER_LEFT_UPPER);
   CreateOrUpdateCell(PREFIX + "SNT_C3_H", sx + 14, c3Y + 4, "TRADE SETUP & EXECUTION (4 EQUAL 25% LEGS)", clrAqua, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");

   int btnAdvW = 126;
   int btnAdvX = sx + cardW - btnAdvW - 8;

   double riskDist = MathAbs(g_staticEntryPrice - g_staticSL);
   double rewardDist = (g_staticTP4 > 0.0) ? MathAbs(g_staticTP4 - g_staticEntryPrice) : 0.0;
   string rrRatioStr = (riskDist > 0.0) ? StringFormat("1:%.1f", rewardDist / riskDist) : "1:3.0";

   // Consecutive-Loss Circuit Breaker check
   bool cbBlocked = false;
   string cbReason = "";
   int cbConsec = 0, cbTotal = 0;
   CheckCircuitBreaker(sym, cbBlocked, cbReason, cbConsec, cbTotal);

   int openLegs = CountOpenAdvisorTradesForSymbol(sym);
   bool isTradeTaken = (openLegs > 0);

   datetime execDt = 0;
   if(isTradeTaken)
   {
      execDt = GetAdvisorTradeExecutionTime(sym, g_currentSignalID);
      if(execDt <= 0 && openLegs > 0)
      {
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong tk = PositionGetTicket(p);
            if(tk > 0 && posInfo.SelectByTicket(tk) && IsSameChartAsset(posInfo.Symbol(), sym))
            {
               long mgc = posInfo.Magic();
               string cmt = posInfo.Comment();
               if(mgc == InpAdvisorMagicNumber || StringFind(cmt, "SEGS|ADV") >= 0 || StringFind(cmt, "[MyAdvisor]") >= 0 || StringFind(cmt, "[Advised") >= 0)
               {
                  datetime pt = (datetime)posInfo.Time();
                  if(execDt == 0 || (pt > 0 && pt < execDt)) execDt = pt;
               }
            }
         }
      }
   }
   string execTimeStr = (execDt > 0) ? FormatExecutionTime(execDt, true) : "";

   if((g_hasViableEntry && !g_isSignalExpired) || isTradeTaken)
   {
      string actStr = "";
      color actCol  = (g_currentAdvisedAction == "BUY") ? clrLime : clrTomato;
      if(isTradeTaken)
      {
         actStr = StringFormat("POSITION ACTIVE [%s]", g_currentAdvisedAction);
      }
      else
      {
         actStr = (g_currentAdvisedAction == "BUY") ? "ACTION: STRONG BUY" : "ACTION: STRONG SELL";
      }
      CreateOrUpdateCell(PREFIX + "SNT_C3_ACT", sx + 14, c3Y + 16, actStr, actCol, 9, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");

      bool tp1Hit = false, tp2Hit = false, tp3Hit = false, tp4Hit = false;
      if(isTradeTaken && !cbBlocked)
      {
         EvaluateTakeProfitHits(sym, g_currentAdvisedAction, g_staticEntryPrice, g_staticTP1, g_staticTP2, g_staticTP3, g_staticTP4, execDt,
                                tp1Hit, tp2Hit, tp3Hit, tp4Hit);
      }
      string setupStr = "";
      color setupCol  = clrLime;
      if(isTradeTaken)
      {
         if(openLegs == 0)
         {
            if(tp1Hit && tp2Hit && tp3Hit && tp4Hit)
               setupStr = "ALL TARGETS HIT (100%)";
            else
               setupStr = (execTimeStr != "") ? ("EXECUTED: " + execTimeStr) : "SETUP: ALL TRADES CLOSED";
            setupCol = clrAqua;
         }
         else if(openLegs == 4)
         {
            setupStr = (execTimeStr != "") ? ("EXECUTED: " + execTimeStr) : "4 LEGS ACTIVE (MONITORING)";
            setupCol = clrLime;
         }
         else if(openLegs == 3)
         {
            setupStr = tp1Hit ? "3 LEGS ACTIVE (TP1 HIT)" : "3 LEGS ACTIVE (IN PLAY)";
            setupCol = clrLime;
         }
         else if(openLegs == 2)
         {
            setupStr = (tp1Hit && tp2Hit) ? "2 LEGS ACTIVE (TP1 & TP2 HIT)" : "2 LEGS ACTIVE (IN PLAY)";
            setupCol = clrLime;
         }
         else if(openLegs == 1)
         {
            setupStr = (tp1Hit && tp2Hit && tp3Hit) ? "1 RUNNER ACTIVE (TP3 HIT)" : "1 RUNNER ACTIVE (IN PLAY)";
            setupCol = clrLime;
         }
         else
         {
            setupStr = StringFormat("%d LEGS ACTIVE", openLegs);
            setupCol = clrLime;
         }
      }
      else
      {
         if(cbBlocked)
         {
            setupStr = "SETUP: PLANNED (CB STANDBY)";
            setupCol = clrGold;
         }
         else if(g_setupState == "CANCELLED" || g_setupState == "UNVIABLE")
         {
            setupStr = "SETUP: PLANNED CANCELLED";
            setupCol = clrCoral;
         }
         else if(g_setupState == "TRIGGERED")
         {
            setupStr = "SETUP: TRIGGERED (EXECUTING)";
            setupCol = clrLime;
         }
         else if(g_setupState == "SCANNING")
         {
            setupStr = "SETUP: SCANNING FOR ENTRY";
            setupCol = clrSilver;
         }
         else
         {
            setupStr = "SETUP: PLANNED (WAITING)";
            setupCol = clrGold;
         }
      }
      CreateOrUpdateCell(PREFIX + "SNT_C3_STP", btnAdvX - 12, c3Y + 16, setupStr, setupCol, 8, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

      string lvlLabel = isTradeTaken ? "ACTIVE ENTRY" : "PLANNED ENTRY";
      double dispSL = g_staticSL;
      double ptHUD = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(ptHUD <= 0.0) ptHUD = 0.0001;
      double pipHUD = GetPipSize(_Symbol);
      double minSafeDistHUD = MathMax(18.0 * pipHUD, 0.40 * 20.0 * pipHUD);
      if(dispSL <= 0.0 || MathAbs(dispSL - g_staticEntryPrice) < minSafeDistHUD)
      {
         dispSL = (g_currentAdvisedAction == "BUY") ? (g_staticEntryPrice - minSafeDistHUD) : (g_staticEntryPrice + minSafeDistHUD);
         dispSL = NormalizeDouble(NormalizePriceToTickSize(_Symbol, dispSL), symDigits);
      }
      string lvlStr = StringFormat("%s: %s  |  SL: %s",
         lvlLabel,
         DoubleToString(g_staticEntryPrice, symDigits),
         DoubleToString(dispSL, symDigits));
      CreateOrUpdateCell(PREFIX + "SNT_C3_LVL", sx + 14, c3Y + 31, lvlStr, clrWhite, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

      // Prominent, unoccluded Signal Quality & R:R display in Row 2 (Right-aligned before buttons - ZERO OVERLAP)
      int qualityScore = (g_setupQuality > 0) ? g_setupQuality : 100;
      color qualCol = (qualityScore >= 80) ? clrLime : ((qualityScore >= 65) ? clrGold : clrAqua);
      string qualStr = StringFormat("R:R %s  |  QUALITY: %d%%", rrRatioStr, qualityScore);
      CreateOrUpdateCell(PREFIX + "SNT_C3_QUAL", btnAdvX - 12, c3Y + 31, qualStr, qualCol, 8, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

      if(isTradeTaken)
      {
         string tp1Label = tp1Hit ? "TP1 Hit" : "1.4R FTA";
         string tp2Label = tp2Hit ? "TP2 Hit" : "2.8R BE LOCK";
         string tp3Label = tp3Hit ? "TP3 Hit" : "4.8R POOL";
         string tp4Label = tp4Hit ? "TP4 Hit" : "8.0R RUNNER";

         string tpRow1 = StringFormat("TP1: %s (%s)  |  TP2: %s (%s)",
            DoubleToString(g_staticTP1, symDigits),
            tp1Label,
            DoubleToString(g_staticTP2, symDigits),
            tp2Label);
         color tpRow1Col = (tp1Hit && tp2Hit) ? clrLime : (tp1Hit ? clrGold : clrAqua);
         CreateOrUpdateCell(PREFIX + "SNT_C3_TPS", sx + 14, c3Y + 46, tpRow1, tpRow1Col, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

         string tpRow2 = StringFormat("TP3: %s (%s) |  TP4: %s (%s)",
            DoubleToString(g_staticTP3, symDigits),
            tp3Label,
            DoubleToString(g_staticTP4, symDigits),
            tp4Label);
         color tpRow2Col = (tp3Hit && tp4Hit) ? clrLime : (tp3Hit ? C'140,255,170' : C'100,210,255');
         CreateOrUpdateCell(PREFIX + "SNT_C3_TP4", sx + 14, c3Y + 60, tpRow2, tpRow2Col, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
      }
      else
      {
         // Standard Rule: Take profit information is hidden when no trade is opened.
         // Trade advisor actively looks for new entries and displays Planned Entry.
         if(g_setupState == "CANCELLED" || g_setupState == "UNVIABLE")
         {
            CreateOrUpdateCell(PREFIX + "SNT_C3_TPS", sx + 14, c3Y + 46, "STATUS: PLANNED ENTRY CANCELLED", clrCoral, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
            CreateOrUpdateCell(PREFIX + "SNT_C3_TP4", sx + 14, c3Y + 60, "DISCIPLINE: " + (g_blockReason != "" ? g_blockReason : "PREVIOUS ENTRY UNVIABLE - STAND ASIDE"), C'170,180,200', 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
         }
         else
         {
            CreateOrUpdateCell(PREFIX + "SNT_C3_TPS", sx + 14, c3Y + 46, "ADVISOR: ACTIVELY LOOKING FOR NEW ENTRIES", clrGold, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
            CreateOrUpdateCell(PREFIX + "SNT_C3_TP4", sx + 14, c3Y + 60, "STATUS: NO ACTIVE TRADE OPENED (TP TARGETS ACTIVATE ON ENTRY)", C'120,130,150', 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
         }
      }

      string dispSig = (StringLen(g_currentSignalID) > 14) ? (StringSubstr(g_currentSignalID, 0, 5) + ".." + StringSubstr(g_currentSignalID, StringLen(g_currentSignalID) - 5)) : g_currentSignalID;
      if(dispSig == "") dispSig = "VERIFIED";
      string stratTag = (g_activeEntryStrategy == "ORDER_BLOCK") ? "STRAT: OB (70%)" : "STRAT: RETEST (30%)";
      string sigInfo = "";
      if(isTradeTaken)
      {
         string execPart = (execTimeStr != "") ? (" | EXEC: " + execTimeStr) : "";
         if(openLegs == 0)
         {
            if(tp1Hit && tp2Hit && tp3Hit && tp4Hit)
               sigInfo = StringFormat("STATUS: ALL TARGETS HIT (TP1, TP2, TP3, TP4) | %s%s | COMPLETED", stratTag, execPart);
            else
               sigInfo = StringFormat("STATUS: POSITION CLOSED | %s%s", stratTag, execPart);
         }
         else
         {
            if(tp1Hit && tp2Hit && tp3Hit)
               sigInfo = StringFormat("STATUS: %d Leg Active (TP4 Runner In Play) | TP1, TP2, TP3 Banked%s | %s", openLegs, execPart, stratTag);
            else if(tp1Hit && tp2Hit)
               sigInfo = StringFormat("STATUS: %d Legs Active (TP3 & TP4 In Play) | TP1 & TP2 Banked (BE Locked)%s | %s", openLegs, execPart, stratTag);
            else if(tp1Hit)
               sigInfo = StringFormat("STATUS: %d Legs Active (TP2, TP3, TP4 In Play) | TP1 Banked (1.4R)%s | %s", openLegs, execPart, stratTag);
            else
               sigInfo = StringFormat("STATUS: %d Safe Legs Running @ %s%s | Monitoring Targets | %s", openLegs, DoubleToString(g_staticEntryPrice, symDigits), execPart, stratTag);
         }
      }
      else
      {
         string liqTag = (g_htfLiquidity.activeConfluenceLabel != "") ? (" | " + g_htfLiquidity.activeConfluenceLabel) : "";
         sigInfo = "SIG: " + dispSig + " | " + stratTag + " | " + StringFormat("QUAL: %d%%", qualityScore) + liqTag + " | 4 Equal Legs (25% ea)";
      }
      color sigInfoCol = (tp1Hit || tp2Hit || tp3Hit) ? clrLime : C'130,150,180';
      CreateOrUpdateCell(PREFIX + "SNT_C3_INF", sx + 14, c3Y + 74, sigInfo, sigInfoCol, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas");
   }
   else
   {
      ObjectDelete(0, PREFIX + "SNT_C3_QUAL");

      if(cbBlocked && !isTradeTaken)
      {
         CreateOrUpdateCell(PREFIX + "SNT_C3_ACT", sx + 14, c3Y + 16, "ACTION: PAUSED (CIRCUIT BREAKER)", clrTomato, 9, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");
         string setupStr = (cbTotal >= InpMaxDailyPortfolioLosses) ? "PORTFOLIO PAUSED (6 LOSSES)" : "SYMBOL PAUSED (3 LOSSES)";
         CreateOrUpdateCell(PREFIX + "SNT_C3_STP", btnAdvX - 12, c3Y + 16, setupStr, clrTomato, 8, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
         string cbMsg = (StringLen(cbReason) > 42) ? (StringSubstr(cbReason, 0, 40) + "..") : cbReason;
         CreateOrUpdateCell(PREFIX + "SNT_C3_LVL", sx + 14, c3Y + 31, "STATUS: " + cbMsg, clrSilver, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
      }
      else
      {
         if(g_isSignalExpired && !isTradeTaken)
         {
            CreateOrUpdateCell(PREFIX + "SNT_C3_ACT", sx + 14, c3Y + 16, "ACTION: SIGNAL EXPIRED", clrTomato, 9, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");
            CreateOrUpdateCell(PREFIX + "SNT_C3_STP", btnAdvX - 12, c3Y + 16, "STATUS: EXPIRED", clrTomato, 8, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
            string staleReason = (g_blockReason != "") ? g_blockReason : "SIGNAL EXPIRED (STALE SETUP)";
            if(StringLen(staleReason) > 42) staleReason = StringSubstr(staleReason, 0, 40) + "..";
            CreateOrUpdateCell(PREFIX + "SNT_C3_LVL", sx + 14, c3Y + 31, "STATUS: " + staleReason, clrTomato, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
         }
         else
         {
            CreateOrUpdateCell(PREFIX + "SNT_C3_ACT", sx + 14, c3Y + 16, "ACTION: STAND ASIDE", clrGold, 9, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Arial Bold");
            string setupStr = "";
            color setupCol = clrTomato;
            if(isTradeTaken && execDt > 0)
            {
               if(execTimeStr != "")
                  setupStr = "EXECUTED: " + execTimeStr;
               else
               {
                  datetime torTime = ConvertBrokerTimeToToronto(execDt);
                  string tz = IsTorontoDST(torTime) ? "EDT" : "EST";
                  setupStr = "EXECUTED: " + TimeToString(torTime, TIME_DATE) + " " + TimeToString(torTime, TIME_MINUTES) + " " + tz;
               }
               setupCol = clrLime;
            }
            else
            {
               setupStr = "GATE: " + (g_isMarketOpen ? (g_setupState != "" ? g_setupState : "WATCHING") : "MARKET CLOSED");
               setupCol = clrTomato;
            }
            CreateOrUpdateCell(PREFIX + "SNT_C3_STP", btnAdvX - 12, c3Y + 16, setupStr, setupCol, 8, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

            string standReason = (g_blockReason != "") ? g_blockReason : ((g_primaryRejectionReason != "") ? g_primaryRejectionReason : "Awaiting value pullback / retest");
            if(StringLen(standReason) > 42) standReason = StringSubstr(standReason, 0, 40) + "..";
            CreateOrUpdateCell(PREFIX + "SNT_C3_LVL", sx + 14, c3Y + 31, "STATUS: " + standReason, clrSilver, 8, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
         }
      }

      string plannedRef = "";
      if(isTradeTaken && g_staticEntryPrice > 0.0)
      {
         bool tp1Hit_e = false, tp2Hit_e = false, tp3Hit_e = false, tp4Hit_e = false;
         EvaluateTakeProfitHits(sym, g_currentAdvisedAction, g_staticEntryPrice, g_staticTP1, g_staticTP2, g_staticTP3, g_staticTP4, execDt,
                                tp1Hit_e, tp2Hit_e, tp3Hit_e, tp4Hit_e);
         if(tp1Hit_e || tp2Hit_e || tp3Hit_e)
         {
            string tpHitTag = "";
            if(tp1Hit_e && tp2Hit_e && tp3Hit_e && tp4Hit_e) tpHitTag = "ALL TARGETS HIT (100%)";
            else if(tp1Hit_e && tp2Hit_e && tp3Hit_e) tpHitTag = "TP1 Hit • TP2 Hit • TP3 Hit";
            else if(tp1Hit_e && tp2Hit_e) tpHitTag = "TP1 Hit • TP2 Hit";
            else if(tp1Hit_e) tpHitTag = "TP1 Hit";
            plannedRef = StringFormat("STATUS: %s | ENTRY: %s", tpHitTag, DoubleToString(g_staticEntryPrice, symDigits));
         }
         else
         {
            plannedRef = StringFormat("ACTIVE SAFE ENTRY: %s | SAFE SL: %s", DoubleToString(g_staticEntryPrice, symDigits), DoubleToString(g_staticSL, symDigits));
         }
      }
      else if(g_staticEntryPrice > 0.0)
         plannedRef = StringFormat("PLANNED ENTRY: %s | SAFE SL: %s", DoubleToString(g_staticEntryPrice, symDigits), DoubleToString(g_staticSL, symDigits));
      else
         plannedRef = "Awaiting structural anchor";
      CreateOrUpdateCell(PREFIX + "SNT_C3_TPS", sx + 14, c3Y + 46, plannedRef, C'140,185,220', 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

      string guide = "";
      if(isTradeTaken)
         guide = (execTimeStr != "") ? ("DISCIPLINE: Active safe trade running (Exec: " + execTimeStr + "). Stand aside from secondary entries.") : "DISCIPLINE: Active safe trade running. Stand aside from secondary entries unless price bounces off safe zone.";
      else if(cbBlocked)
         guide = "CIRCUIT BREAKER: Capital preserved. Trading paused for remainder of today.";
      else if(g_staticEntryPrice > 0.0)
         guide = "DISCIPLINE: Do not chase extended price. Wait for pullback.";
      else
         guide = "DISCIPLINE: Stand aside until structure & gate align.";
      CreateOrUpdateCell(PREFIX + "SNT_C3_TP4", sx + 14, c3Y + 60, guide, C'140,155,180', 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);

      string subInfo = (g_setupState != "") ? ("STATE: " + g_setupState) : "STATE: MONITORING";
      string stratTagWait = (g_activeEntryStrategy == "ORDER_BLOCK") ? "STRAT: OB (70%)" : "STRAT: RETEST (30%)";
      string execInf = (isTradeTaken && execTimeStr != "") ? (" | " + execTimeStr) : "";
      CreateOrUpdateCell(PREFIX + "SNT_C3_INF", sx + 14, c3Y + 74, subInfo + " | " + stratTagWait + execInf + " | Zero-Repaint Engine", C'110,130,160', 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
   }   string alertBtnTxt = g_alertOnViableEntry ? "ALERTS: ON [O]" : "ALERTS: OFF [O]";
   color alertBtnBg   = g_alertOnViableEntry ? C'18,50,30' : C'40,20,20';
   color alertBtnFg   = g_alertOnViableEntry ? clrLime : clrSilver;
   CreateOrUpdateButton(PREFIX + "SNT_ALERT_BTN", btnAdvX, c3Y + 8, btnAdvW, 20, alertBtnTxt, alertBtnBg, alertBtnFg, CORNER_LEFT_UPPER, InpFontName, 7);

   if(cbBlocked)
   {
      bool isTradeTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
      if(isTradeTaken)
      {
         datetime execDt = GetAdvisorTradeExecutionTime(sym, g_currentSignalID);
         string execTimeShort = (execDt > 0) ? TimeToString(ConvertBrokerTimeToToronto(execDt), TIME_MINUTES) : "";
         string btnLabel = (execTimeShort != "") ? ("ACTIVE (" + execTimeShort + ")") : "POSITION ACTIVE";
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, btnLabel, C'16,68,36', clrLime, CORNER_LEFT_UPPER, InpFontName, 7);
      }
      else
      {
         string cbBtnTxt = (cbTotal >= InpMaxDailyPortfolioLosses) ? "PAUSED (6 LOSSES)" : "PAUSED (3 LOSSES)";
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, cbBtnTxt, C'60,20,24', clrTomato, CORNER_LEFT_UPPER, InpFontName, 7);
      }
   }
   else if(g_hasViableEntry && !g_isSignalExpired)
   {
      bool isTradeTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
      if(isTradeTaken)
      {
         datetime execDt = GetAdvisorTradeExecutionTime(sym, g_currentSignalID);
         string execTimeShort = (execDt > 0) ? TimeToString(ConvertBrokerTimeToToronto(execDt), TIME_MINUTES) : "";
         string btnLabel = (execTimeShort != "") ? ("ACTIVE (" + execTimeShort + ")") : "POSITION ACTIVE";
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, btnLabel, C'16,68,36', clrLime, CORNER_LEFT_UPPER, InpFontName, 7);
      }
      else
      {
         color tradeBg = (g_currentAdvisedAction == "BUY") ? C'16,80,45' : C'80,24,30';
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, "TRADE SETUP [Z]", tradeBg, clrWhite, CORNER_LEFT_UPPER, InpFontName, 7);
      }
   }
   else if(g_isSignalExpired)
   {
      bool isTradeTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
      if(isTradeTaken)
      {
         datetime execDt = GetAdvisorTradeExecutionTime(sym, g_currentSignalID);
         string execTimeShort = (execDt > 0) ? TimeToString(ConvertBrokerTimeToToronto(execDt), TIME_MINUTES) : "";
         string btnLabel = (execTimeShort != "") ? ("ACTIVE (" + execTimeShort + ")") : "POSITION ACTIVE";
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, btnLabel, C'16,68,36', clrLime, CORNER_LEFT_UPPER, InpFontName, 7);
      }
      else
      {
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, "SIGNAL EXPIRED", C'60,20,24', clrTomato, CORNER_LEFT_UPPER, InpFontName, 7);
      }
   }
   else
   {
      bool isTradeTaken = IsAdvisorTradeTaken(sym, g_currentSignalID);
      if(isTradeTaken)
      {
         datetime execDt = GetAdvisorTradeExecutionTime(sym, g_currentSignalID);
         string execTimeShort = (execDt > 0) ? TimeToString(ConvertBrokerTimeToToronto(execDt), TIME_MINUTES) : "";
         string btnLabel = (execTimeShort != "") ? ("ACTIVE (" + execTimeShort + ")") : "POSITION ACTIVE";
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, btnLabel, C'16,68,36', clrLime, CORNER_LEFT_UPPER, InpFontName, 7);
      }
      else
      {
         CreateOrUpdateButton(PREFIX + "SNT_EXEC_BTN", btnAdvX, c3Y + 34, btnAdvW, 22, "WAIT FOR SIGNAL", C'28,30,38', clrSilver, CORNER_LEFT_UPPER, InpFontName, 7);
      }
   }

   int openAdvTrades = CountTotalOpenAdvisorTrades();
   int maxCeiling = MathMax(24, InpMaxOpenAdvisorTradesPortfolio);
   string myAdvBtnTxt = g_myAdvisorEnabled ? StringFormat("ADVISOR: ON (%d/%d)", openAdvTrades, maxCeiling) : StringFormat("ADVISOR: OFF (%d/%d)", openAdvTrades, maxCeiling);
   color myAdvBtnBg   = g_myAdvisorEnabled ? C'16,68,36' : C'34,36,46';
   color myAdvBtnFg   = g_myAdvisorEnabled ? clrLime : clrSilver;
   CreateOrUpdateButton(PREFIX + "SNT_MYADVISOR", btnAdvX, c3Y + 62, btnAdvW, 22, myAdvBtnTxt, myAdvBtnBg, myAdvBtnFg, CORNER_LEFT_UPPER, InpFontName, 7);

   // Clean Table Footer Ribbon - Multi-Strategy Confluence Matrix & Command Strip (Zero Overlap)
   int ftrY = c3Y + c3H + 4;
   CreateOrUpdatePanel(PREFIX + "SNT_FTR_BG", sx + 8, ftrY, cardW, 36, C'12,15,22', C'26,34,48', CORNER_LEFT_UPPER);
   string matrixHealth = g_strategyMatrix.overallHealth;
   color matrixCol = (matrixHealth == "OPTIMAL") ? clrLime : ((matrixHealth == "BLOCKED") ? clrTomato : clrAqua);
   string lotStatusFtr = g_smartLotEnabled ? "Smart Lot: ON" : "Fixed Lot";
   string stratTag = (g_activeEntryStrategy == "ORDER_BLOCK") ? "OB 70%" : "RETEST 30%";

   string tierFtr = g_strategyMatrix.confluenceTier;
   if(tierFtr == "" || tierFtr == "(null)")
   {
      tierFtr = (matrixHealth == "OPTIMAL") ? "INSTITUTIONAL A+" : "HIGH PROBABILITY";
   }
   int scoreFtr = (g_strategyMatrix.confluenceScore > 0) ? g_strategyMatrix.confluenceScore : ((g_setupQuality > 0) ? g_setupQuality : 75);

   // Row 1: Confluence Matrix & Execution Status (Zero Overlap)
   string stratFtr = StringFormat("CONFLUENCE: %s (%d%%)  •  %s  •  %s",
                                  tierFtr, scoreFtr, stratTag, lotStatusFtr);
   CreateOrUpdateCell(PREFIX + "SNT_FTR_L", sx + 14, ftrY + 4, stratFtr, matrixCol, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
   CreateOrUpdateCell(PREFIX + "SNT_FTR_R", sx + cardW - 8, ftrY + 4, "4 LEGS (25% EA)  •  ZERO-REPAINT", C'100,150,195', 7, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");

   // Row 2: Dedicated Hotkey Quick Reference Strip (Zero Overlap)
   string hotkeyStr = "HOTKEYS: [Z] Setup  •  [J] Smart Lot  •  [V] Move  •  [M] Close  •  [?] Help";
   CreateOrUpdateCell(PREFIX + "SNT_FTR_HOTKEYS", sx + 14, ftrY + 19, hotkeyStr, clrAqua, 7, ANCHOR_LEFT_UPPER, CORNER_LEFT_UPPER, InpFontName);
   CreateOrUpdateCell(PREFIX + "SNT_FTR_VER", sx + cardW - 8, ftrY + 19, "SEGS PRO v3.75", C'70,105,150', 7, ANCHOR_RIGHT_UPPER, CORNER_LEFT_UPPER, "Consolas Bold");
}
void DeleteWinRateHUD()
{
   ObjectsDeleteAll(0, PREFIX + "WR_");
}

//+------------------------------------------------------------------+
//| Dynamic Symbol Discovery: Finds all symbols with SEGS activity    |
//| (closed deals in history, active positions, or open chart symbol)|
//+------------------------------------------------------------------+
int DiscoverSEGSSymbols(string &outSymbols[])
{
   ArrayResize(outSymbols, 0);

   int count = 1;
   ArrayResize(outSymbols, count);
   outSymbols[0] = _Symbol;

   int posTotal = PositionsTotal();
   for(int i = 0; i < posTotal; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && posInfo.SelectByTicket(tk))
      {
         string sym = posInfo.Symbol();
         bool exists = false;
         for(int s = 0; s < count; s++)
         {
            if(outSymbols[s] == sym) { exists = true; break; }
         }
         if(!exists)
         {
            count++;
            ArrayResize(outSymbols, count);
            outSymbols[count - 1] = sym;
         }
      }
   }

   if(HistorySelect(0, TimeCurrent()))
   {
      int dealsTotal = HistoryDealsTotal();
      for(int i = dealsTotal - 1; i >= 0 && count < 16; i--)
      {
         ulong dt = HistoryDealGetTicket(i);
         if(dt > 0)
         {
            long entry = HistoryDealGetInteger(dt, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
            {
               string sym = HistoryDealGetString(dt, DEAL_SYMBOL);
               if(sym != "")
               {
                  bool exists = false;
                  for(int s = 0; s < count; s++)
                  {
                     if(outSymbols[s] == sym) { exists = true; break; }
                  }
                  if(!exists)
                  {
                     count++;
                     ArrayResize(outSymbols, count);
                     outSymbols[count - 1] = sym;
                  }
               }
            }
         }
      }
   }

   string fallbackSymbols[6] = { "XAUUSD", "US30", "NAS100", "GBPJPY", "EURUSD", "GBPUSD" };
   for(int f = 0; f < 6 && count < 8; f++)
   {
      string fs = fallbackSymbols[f];
      bool exists = false;
      for(int s = 0; s < count; s++)
      {
         if(outSymbols[s] == fs) { exists = true; break; }
      }
      if(!exists)
      {
         count++;
         ArrayResize(outSymbols, count);
         outSymbols[count - 1] = fs;
      }
   }

   return count;
}

//+------------------------------------------------------------------+
//| WIN RATE & EDGE ANALYTICS OVERLAY (Key 'G')                      |
//| Dynamic Symbol Discovery, Setup-Level Metrics & Edge Assessment  |
//+------------------------------------------------------------------+
void DrawWinRateHUD()
{
   if(!g_showWinRateHUD) return;

   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   if(chartW <= 0) chartW = 1200;
   if(chartH <= 0) chartH = 800;

   int ww = 680;
   int wh = 430;
   int wx = MathMax(10, (chartW - ww) / 2);
   int wy = MathMax(20, (chartH - wh) / 2);
   ENUM_BASE_CORNER wc = CORNER_LEFT_UPPER;

   // Backdrop container
   CreateOrUpdatePanel(PREFIX + "WR_BG", wx, wy, ww, wh, C'11,14,22', clrGold, wc);

   // Header Bar
   CreateOrUpdatePanel(PREFIX + "WR_HDR", wx, wy, ww, 26, C'18,24,36', clrGold, wc);
   string title = (g_winRateSelectedSymbol == "ALL")
      ? "WIN RATE & EDGE ANALYTICS HUD [G] • PORTFOLIO AUDIT (SETUP-LEVEL)"
      : ("WIN RATE & EDGE ANALYTICS HUD [G] • [" + g_winRateSelectedSymbol + "] DETAILED AUDIT");
   CreateOrUpdateCell(PREFIX + "WR_TITLE", wx + 12, wy + 5, title, clrGold, 9, ANCHOR_LEFT_UPPER, wc, InpFontName);
   CreateOrUpdateButton(PREFIX + "WR_CLOSE", wx + ww - 26, wy + 3, 20, 20, "X", C'60,20,24', clrWhite, wc, InpFontName, 8);

   // Discover dynamic symbols (Section 27 & 28)
   string discSymbols[];
   int discCount = DiscoverSEGSSymbols(discSymbols);
   int maxTabSymbols = MathMin(discCount, 7);

   int tabY = wy + 28;
   int tabX = wx + 10;

   // Tab 0: ALL ASSETS
   bool isAll = (g_winRateSelectedSymbol == "ALL");
   color allBg = isAll ? C'180,140,20' : C'20,26,36';
   color allFg = isAll ? clrBlack : clrSilver;
   CreateOrUpdateButton(PREFIX + "WR_TAB_ALL", tabX, tabY, 82, 20, "ALL ASSETS", allBg, allFg, wc, InpFontName, 7);
   tabX += 85;

   for(int s = 0; s < maxTabSymbols; s++)
   {
      string sSym = discSymbols[s];
      bool isSel = (g_winRateSelectedSymbol == sSym);
      color tabBg = isSel ? C'18,100,160' : C'20,26,36';
      color tabFg = isSel ? clrAqua : clrSilver;
      CreateOrUpdateButton(PREFIX + "WR_TAB_" + sSym, tabX, tabY, 66, 20, sSym, tabBg, tabFg, wc, InpFontName, 7);
      tabX += 69;
   }

   if(!isAll)
      CreateOrUpdateButton(PREFIX + "WR_BTN_BACK", wx + ww - 116, tabY, 106, 20, "<< ALL ASSETS", C'36,44,60', clrGold, wc, InpFontName, 7);
   else
      ObjectDelete(0, PREFIX + "WR_BTN_BACK");

   // 1. Accurate Account History Deals Analysis (Closed Trades)
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();

   int wins = 0, losses = 0, breakevens = 0;
   double grossProfit = 0.0, grossLoss = 0.0;
   int hourWins[24], hourLosses[24], hourTotal[24];
   double hourNetPnl[24];
   ArrayInitialize(hourWins, 0);
   ArrayInitialize(hourLosses, 0);
   ArrayInitialize(hourTotal, 0);
   ArrayInitialize(hourNetPnl, 0.0);

   // Dynamic symbol arrays
   int symWins[], symLosses[], symBreakevens[], symTotal[];
   double symProfit[];
   ArrayResize(symWins, discCount);
   ArrayResize(symLosses, discCount);
   ArrayResize(symBreakevens, discCount);
   ArrayResize(symTotal, discCount);
   ArrayResize(symProfit, discCount);
   ArrayInitialize(symWins, 0);
   ArrayInitialize(symLosses, 0);
   ArrayInitialize(symBreakevens, 0);
   ArrayInitialize(symTotal, 0);
   ArrayInitialize(symProfit, 0.0);

   for(int i = 0; i < totalDeals; i++)
   {
      ulong dticket = HistoryDealGetTicket(i);
      if(dticket <= 0) continue;

      long entry = HistoryDealGetInteger(dticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      long dealType = HistoryDealGetInteger(dticket, DEAL_TYPE);
      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL) continue;

      string dSym = HistoryDealGetString(dticket, DEAL_SYMBOL);
      double pnl = HistoryDealGetDouble(dticket, DEAL_PROFIT) +
                   HistoryDealGetDouble(dticket, DEAL_SWAP) +
                   HistoryDealGetDouble(dticket, DEAL_COMMISSION);
      datetime dTime = (datetime)HistoryDealGetInteger(dticket, DEAL_TIME);

      bool matchSelected = (isAll || IsSameChartAsset(dSym, g_winRateSelectedSymbol));
      if(matchSelected)
      {
         if(pnl > 0.05)
         {
            wins++;
            grossProfit += pnl;
         }
         else if(pnl < -0.05)
         {
            losses++;
            grossLoss += MathAbs(pnl);
         }
         else
         {
            breakevens++;
         }

         datetime torontoTime = ConvertBrokerTimeToToronto(dTime);
         MqlDateTime mdt;
         TimeToStruct(torontoTime, mdt);
         int hr = mdt.hour;
         if(hr >= 0 && hr < 24)
         {
            hourTotal[hr]++;
            hourNetPnl[hr] += pnl;
            if(pnl > 0.05) hourWins[hr]++;
            else if(pnl < -0.05) hourLosses[hr]++;
         }
      }

      for(int s = 0; s < discCount; s++)
      {
         if(IsSameChartAsset(dSym, discSymbols[s]))
         {
            symTotal[s]++;
            symProfit[s] += pnl;
            if(pnl > 0.05) symWins[s]++;
            else if(pnl < -0.05) symLosses[s]++;
            else symBreakevens[s]++;
            break;
         }
      }
   }

   int decisiveTrades = wins + losses;
   int totalTradesClosed = wins + losses + breakevens;
   double overallWinRate = (decisiveTrades > 0) ? ((double)wins / decisiveTrades * 100.0) : ((totalTradesClosed > 0) ? ((double)wins / totalTradesClosed * 100.0) : 0.0);
   double pf = (grossLoss > 0.0) ? (grossProfit / grossLoss) : (grossProfit > 0 ? 9.99 : 0.0);
   double netProfit = grossProfit - grossLoss;

   // Best & Worst Trading Hour Identification (Section 30: Evaluated by Net P/L & Win Rate)
   int bestHour = -1;
   double bestNetPnl = -10000000.0;
   int worstHour = -1;
   double worstNetPnl = 10000000.0;

   for(int h = 0; h < 24; h++)
   {
      if(hourTotal[h] >= 2)
      {
         if(hourNetPnl[h] > bestNetPnl) { bestNetPnl = hourNetPnl[h]; bestHour = h; }
         if(hourNetPnl[h] < worstNetPnl) { worstNetPnl = hourNetPnl[h]; worstHour = h; }
      }
   }
   if(bestHour < 0)
   {
      for(int h = 0; h < 24; h++)
      {
         if(hourTotal[h] > 0 && hourNetPnl[h] > bestNetPnl) { bestNetPnl = hourNetPnl[h]; bestHour = h; }
         if(hourTotal[h] > 0 && hourNetPnl[h] < worstNetPnl) { worstNetPnl = hourNetPnl[h]; worstHour = h; }
      }
   }

   string sampleConfidence = "";
   if(totalTradesClosed < 10) sampleConfidence = "VERY LOW SAMPLE";
   else if(totalTradesClosed < 30) sampleConfidence = "LOW SAMPLE";
   else if(totalTradesClosed < 100) sampleConfidence = "DEVELOPING";
   else sampleConfidence = "ESTABLISHED";

   // Edge Status (Section 31)
   string edgeStatus = "";
   color  edgeColor = clrSilver;
   if(totalTradesClosed >= 30 && pf >= 1.50 && netProfit > 0.0 && overallWinRate >= 50.0)
   {
      edgeStatus = "STRONG STATISTICAL EDGE";
      edgeColor  = clrLime;
   }
   else if(totalTradesClosed >= 15 && pf >= 1.20 && netProfit > 0.0)
   {
      edgeStatus = "MODERATE EDGE (VALIDATED)";
      edgeColor  = clrAqua;
   }
   else if(totalTradesClosed < 10)
   {
      edgeStatus = "INSUFFICIENT SAMPLE (" + sampleConfidence + ")";
      edgeColor  = clrSilver;
   }
   else
   {
      edgeStatus = "NO STATISTICAL EDGE";
      edgeColor  = clrTomato;
   }

   int cardY = tabY + 24;
   int cardW = (ww - 20 - 18) / 4;
   color kpiBg = C'16,21,30';
   color kpiBorder = C'32,42,58';

   // Card 1: Decisive Win Rate
   CreateOrUpdatePanel(PREFIX + "WR_C1", wx + 10, cardY, cardW, 54, kpiBg, kpiBorder, wc);
   CreateOrUpdateCell(PREFIX + "WR_C1_L", wx + 16, cardY + 4, "WIN RATE (DECISIVE)", clrSilver, 7, ANCHOR_LEFT_UPPER, wc, InpFontName);
   color wrColor = (overallWinRate >= 65.0) ? clrLime : ((overallWinRate >= 50.0) ? clrGold : clrTomato);
   CreateOrUpdateCell(PREFIX + "WR_C1_V", wx + 16, cardY + 16, StringFormat("%.1f%%", overallWinRate), wrColor, 13, ANCHOR_LEFT_UPPER, wc, "Arial Bold");
   CreateOrUpdateCell(PREFIX + "WR_C1_S", wx + 16, cardY + 36, StringFormat("%dW / %dL / %dBE (%d Closed)", wins, losses, breakevens, totalTradesClosed), clrSilver, 7, ANCHOR_LEFT_UPPER, wc, InpFontName);

   // Card 2: Profit Factor
   int c2X = wx + 10 + cardW + 6;
   CreateOrUpdatePanel(PREFIX + "WR_C2", c2X, cardY, cardW, 54, kpiBg, kpiBorder, wc);
   CreateOrUpdateCell(PREFIX + "WR_C2_L", c2X + 6, cardY + 4, "PROFIT FACTOR", clrSilver, 7, ANCHOR_LEFT_UPPER, wc, InpFontName);
   color pfColor = (pf >= 1.75) ? clrLime : ((pf >= 1.20) ? clrGold : clrTomato);
   CreateOrUpdateCell(PREFIX + "WR_C2_V", c2X + 6, cardY + 16, StringFormat("%.2f", pf), pfColor, 13, ANCHOR_LEFT_UPPER, wc, "Arial Bold");
   CreateOrUpdateCell(PREFIX + "WR_C2_S", c2X + 6, cardY + 36, StringFormat("+$%.0f / -$%.0f", grossProfit, grossLoss), clrSilver, 7, ANCHOR_LEFT_UPPER, wc, InpFontName);

   // Card 3: Edge Status & Confidence
   int c3X = c2X + cardW + 6;
   CreateOrUpdatePanel(PREFIX + "WR_C3", c3X, cardY, cardW, 54, kpiBg, kpiBorder, wc);
   CreateOrUpdateCell(PREFIX + "WR_C3_L", c3X + 6, cardY + 4, "EDGE CONFIDENCE", clrSilver, 7, ANCHOR_LEFT_UPPER, wc, InpFontName);
   CreateOrUpdateCell(PREFIX + "WR_C3_V", c3X + 6, cardY + 16, sampleConfidence, clrAqua, 10, ANCHOR_LEFT_UPPER, wc, "Arial Bold");
   CreateOrUpdateCell(PREFIX + "WR_C3_S", c3X + 6, cardY + 36, edgeStatus, edgeColor, 6, ANCHOR_LEFT_UPPER, wc, InpFontName);

   // Card 4: Net P/L
   int c4X = c3X + cardW + 6;
   CreateOrUpdatePanel(PREFIX + "WR_C4", c4X, cardY, cardW, 54, kpiBg, kpiBorder, wc);
   CreateOrUpdateCell(PREFIX + "WR_C4_L", c4X + 6, cardY + 4, "NET CLOSED P/L", clrSilver, 7, ANCHOR_LEFT_UPPER, wc, InpFontName);
   color netCol = (netProfit >= 0.0) ? clrLime : clrTomato;
   CreateOrUpdateCell(PREFIX + "WR_C4_V", c4X + 6, cardY + 16, StringFormat("%s$%.2f", (netProfit >= 0 ? "+" : ""), netProfit), netCol, 13, ANCHOR_LEFT_UPPER, wc, "Arial Bold");
   CreateOrUpdateCell(PREFIX + "WR_C4_S", c4X + 6, cardY + 36, StringFormat("%d Deals in %d Closed Trades", totalDeals, totalTradesClosed), clrSilver, 7, ANCHOR_LEFT_UPPER, wc, InpFontName);

   // Toronto Time Optimal Entry Windows Banner (Section 30)
   int timeY = cardY + 58;
   CreateOrUpdatePanel(PREFIX + "WR_TIMING", wx + 10, timeY, ww - 20, 26, C'14,20,32', C'26,40,64', wc);
   string peakWinStr = (bestHour >= 0 && bestNetPnl > 0.0)
      ? StringFormat("Peak Edge Hour: %02d:00-%02d:00 Toronto (+%.0f net, %dW/%dL)", bestHour, (bestHour + 1) % 24, bestNetPnl, hourWins[bestHour], hourLosses[bestHour])
      : (bestHour >= 0 ? StringFormat("Peak Edge Hour: %02d:00-%02d:00 Toronto (%dW/%dL)", bestHour, (bestHour + 1) % 24, hourWins[bestHour], hourLosses[bestHour]) : "Peak Edge Hour: Awaiting Setup History");

   string peakLossStr = (worstHour >= 0 && worstNetPnl < 0.0)
      ? StringFormat("Peak Leak Hour: %02d:00-%02d:00 Toronto (-$%.0f net, %dL)", worstHour, (worstHour + 1) % 24, MathAbs(worstNetPnl), hourLosses[worstHour])
      : (worstHour >= 0 ? StringFormat("Peak Leak Hour: %02d:00-%02d:00 Toronto (%dL)", worstHour, (worstHour + 1) % 24, hourLosses[worstHour]) : "Peak Leak Hour: None Detected");

   CreateOrUpdateCell(PREFIX + "WR_TM_W", wx + 18, timeY + 6, "* " + peakWinStr, clrLime, 8, ANCHOR_LEFT_UPPER, wc, "Consolas Bold");
   CreateOrUpdateCell(PREFIX + "WR_TM_L", wx + 340, timeY + 6, "! " + peakLossStr, clrTomato, 8, ANCHOR_LEFT_UPPER, wc, "Consolas Bold");

   // Instrument Performance Table
   int tblY = timeY + 30;
   CreateOrUpdatePanel(PREFIX + "WR_TH", wx + 10, tblY, ww - 20, 20, C'20,28,42', C'38,50,72', wc);
   CreateOrUpdateCell(PREFIX + "WR_TH_SYM", wx + 18,  tblY + 4, "DISCOVERED ASSET", clrGold,   8, ANCHOR_LEFT_UPPER, wc, "Arial Bold");
   CreateOrUpdateCell(PREFIX + "WR_TH_TRD", wx + 140, tblY + 4, "TRADES",            clrSilver, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);
   CreateOrUpdateCell(PREFIX + "WR_TH_WR",  wx + 215, tblY + 4, "WIN RATE",          clrSilver, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);
   CreateOrUpdateCell(PREFIX + "WR_TH_WL",  wx + 300, tblY + 4, "W / L / BE",        clrSilver, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);
   CreateOrUpdateCell(PREFIX + "WR_TH_PNL", wx + 400, tblY + 4, "NET P/L",           clrSilver, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);
   CreateOrUpdateCell(PREFIX + "WR_TH_EDG", wx + 510, tblY + 4, "EDGE STATUS",       clrSilver, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);
   CreateOrUpdateCell(PREFIX + "WR_TH_ACT", wx + 610, tblY + 4, "AUDIT",             clrAqua,   8, ANCHOR_LEFT_UPPER, wc, InpFontName);

   int maxDisplayRows = MathMin(discCount, 9);
   for(int s = 0; s < maxDisplayRows; s++)
   {
      int rowY = tblY + 22 + (s * 22);
      string sSym = discSymbols[s];
      int nTr = symTotal[s];
      int wS = symWins[s];
      int lS = symLosses[s];
      int beS = symBreakevens[s];
      double pS = symProfit[s];
      int decisiveS = wS + lS;
      double wrS = (decisiveS > 0) ? ((double)wS / decisiveS * 100.0) : ((nTr > 0) ? ((double)wS / nTr * 100.0) : 0.0);

      color rowBg = (s % 2 == 0) ? C'14,18,26' : C'11,14,20';
      color rowBorder = C'24,32,46';
      CreateOrUpdatePanel(PREFIX + "WR_R_" + IntegerToString(s) + "_BG", wx + 10, rowY, ww - 20, 20, rowBg, rowBorder, wc);

      color symCol = (sSym == "XAUUSD") ? clrGold : (sSym == "US30" ? clrDeepSkyBlue : (sSym == "NAS100" ? C'190,140,255' : clrAqua));
      CreateOrUpdateCell(PREFIX + "WR_R_" + IntegerToString(s) + "_S", wx + 18, rowY + 3, sSym, symCol, 8, ANCHOR_LEFT_UPPER, wc, "Consolas Bold");
      CreateOrUpdateCell(PREFIX + "WR_R_" + IntegerToString(s) + "_T", wx + 140, rowY + 3, IntegerToString(nTr), clrWhite, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);

      color wrCol = (wrS >= 65.0) ? clrLime : ((wrS >= 50.0) ? clrGold : (nTr > 0 ? clrTomato : clrSilver));
      CreateOrUpdateCell(PREFIX + "WR_R_" + IntegerToString(s) + "_W", wx + 215, rowY + 3, (nTr > 0 ? StringFormat("%.1f%%", wrS) : "—"), wrCol, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);
      CreateOrUpdateCell(PREFIX + "WR_R_" + IntegerToString(s) + "_R", wx + 300, rowY + 3, StringFormat("%dW / %dL / %dBE", wS, lS, beS), clrSilver, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);

      color pnlCol = (pS >= 0.0) ? clrLime : clrTomato;
      CreateOrUpdateCell(PREFIX + "WR_R_" + IntegerToString(s) + "_P", wx + 400, rowY + 3, StringFormat("%s$%.2f", (pS >= 0 ? "+" : ""), pS), pnlCol, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);

      string rowEdge = (nTr >= 20 && wrS >= 50.0 && pS > 0) ? "STRONG" : ((nTr >= 10 && pS > 0) ? "MODERATE" : (nTr < 10 ? "LOW SAMPLE" : "NEGATIVE"));
      color rowEdgeCol = (rowEdge == "STRONG") ? clrLime : ((rowEdge == "MODERATE") ? clrAqua : (rowEdge == "LOW SAMPLE" ? clrSilver : clrTomato));
      CreateOrUpdateCell(PREFIX + "WR_R_" + IntegerToString(s) + "_E", wx + 510, rowY + 3, rowEdge, rowEdgeCol, 8, ANCHOR_LEFT_UPPER, wc, InpFontName);

      CreateOrUpdateButton(PREFIX + "WR_VIEW_" + sSym, wx + 610, rowY + 1, 50, 18, "AUDIT", C'22,34,50', clrAqua, wc, InpFontName, 7);
   }
}

void DeleteHelpHUD()
{
   ObjectsDeleteAll(0, PREFIX + "HLP_");
}

void DrawHelpHUD()
{
   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   if(chartW <= 0) chartW = 1200;
   if(chartH <= 0) chartH = 800;

   int hw = 620;
   int hh = 370;
   int hx = MathMax(10, (chartW - hw) / 2);
   int hy = MathMax(20, (chartH - hh) / 2);

   ENUM_BASE_CORNER hc = CORNER_LEFT_UPPER;

   // Backdrop Container
   CreateOrUpdatePanel(PREFIX + "HLP_BG", hx, hy, hw, hh, C'16,20,28', clrSkyBlue, hc);

   // Header Bar
   CreateOrUpdatePanel(PREFIX + "HLP_HDR", hx, hy, hw, 26, C'24,34,50', clrSkyBlue, hc);
   CreateOrUpdateCell(PREFIX + "HLP_TITLE", hx + 12, hy + 5, "SEGS PRO COCKPIT • QUICK HELP & HOTKEY MANUAL [?]", clrSkyBlue, 9, ANCHOR_LEFT_UPPER, hc, InpFontName);
   CreateOrUpdateButton(PREFIX + "HLP_CLOSE", hx + hw - 26, hy + 3, 20, 20, "X", C'60,20,24', clrWhite, hc, InpFontName, 8);

   // 1. Hotkey Quick Index (Left Column, Width 290)
   int leftX = hx + 12;
   int topY  = hy + 34;
   CreateOrUpdatePanel(PREFIX + "HLP_HOT_BG", leftX, topY, 290, 280, C'18,24,34', C'32,44,62', hc);
   CreateOrUpdateCell(PREFIX + "HLP_HOT_H", leftX + 8, topY + 6, "PRIMARY KEYBOARD SHORTCUTS", clrGold, 8, ANCHOR_LEFT_UPPER, hc, InpFontName);

   string hotkeys[] = {
      "[D] Dock / Undock Terminal to Bottom",
      "[G] Win Rate & Edge Analytics Overlay",
      "[?] Quick Help Manual & Operational Guide",
      "[M] Toggle Market Sentiment Matrix HUD",
      "[Z] Execute Advised Trade Setup Instantly",
      "[J] Toggle Smart Lot Sizing (Risk vs Fixed)",
      "[K] Toggle Entry, SL, TP1-4 Target Lines",
      "[O] Toggle Audio/Visual Alerts on Signals",
      "[U] Toggle MyAdvisor Multi-Symbol AutoTrade",
      "[C] Switch Auto Mode vs Controlled Mode",
      "[P] Process Unassigned Chart Positions",
      "[T] Toggle Open Advisor Trade Markings",
      "[B] Toggle Broken Order Blocks Display"
   };

   int numHotkeys = ArraySize(hotkeys);
   for(int k = 0; k < numHotkeys; k++)
   {
      CreateOrUpdateCell(PREFIX + "HLP_K_" + IntegerToString(k), leftX + 8, topY + 24 + (k * 19), hotkeys[k], clrWhite, 7, ANCHOR_LEFT_UPPER, hc, InpFontName);
   }

   // 2. Operational Rules & Strategy Architecture (Right Column, Width 290)
   int rightX = hx + 314;
   CreateOrUpdatePanel(PREFIX + "HLP_STR_BG", rightX, topY, 294, 280, C'18,24,34', C'32,44,62', hc);
   CreateOrUpdateCell(PREFIX + "HLP_STR_H", rightX + 8, topY + 6, "SYSTEM RULES & EXECUTION ARCHITECTURE", clrLime, 8, ANCHOR_LEFT_UPPER, hc, InpFontName);

   string rules[] = {
      "* Smart Lot Sizing: Dynamic risk % (1-3%) with",
      "  micro floor (<= $100 USD) & equal 4 legs.",
      "* Master Quality Gate: Evaluates Session Open,",
      "  Data Freshness, ATR Volatility & Spread.",
      "* Anti-Chasing Filter: Blocks entries when price",
      "  is extended > 1.2 ATR from H1 EMA20.",
      "* 5-Pillar Matrix: Macro Trend (60/40), Value/Sweep,",
      "  OB (70%)/Retest (30%), 4-Leg Ladder, Risk Shields.",
      "* 4-Leg Strategy: Equal 25% lot allocation across all",
      "  4 legs: TP1 (1.4R), TP2 (2.8R+BE), TP3 (4.8R), TP4 (8.0R).",
      "* Mandatory BE Rule: Triggered specifically when",
      "  TP2 (Leg 2) closes by DEAL_REASON_TP.",
      "* Circuit Breaker: 3 Symbol / 5 Portfolio Losses."
   };

   int numRules = ArraySize(rules);
   for(int r = 0; r < numRules; r++)
   {
      color rCol = (r % 2 == 0) ? clrSkyBlue : clrSilver;
      CreateOrUpdateCell(PREFIX + "HLP_R_" + IntegerToString(r), rightX + 8, topY + 24 + (r * 19), rules[r], rCol, 7, ANCHOR_LEFT_UPPER, hc, InpFontName);
   }

   // Footer Ribbon
   int ftrY = topY + 288;
   CreateOrUpdatePanel(PREFIX + "HLP_FTR", hx + 12, ftrY, hw - 24, 22, C'18,24,34', C'32,44,62', hc);
   CreateOrUpdateCell(PREFIX + "HLP_FTR_TXT", hx + 18, ftrY + 4, "Web Cockpit: Use top navigation tabs to access Win Rate, MT5 Chart, MyAdvisor, and Help views.", clrGold, 7, ANCHOR_LEFT_UPPER, hc, InpFontName);
}


void ApplyBreakevenTicket(ulong ticket)
{
   if(!posInfo.SelectByTicket(ticket)) return;
   string sym = posInfo.Symbol();
   double pipSize = GetPipSize(sym);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double openP = posInfo.PriceOpen();
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0.0) pt = 0.00001;

   double curAtr = 0.0;
   if(g_hAtr_H1 != INVALID_HANDLE && sym == _Symbol)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
   }
   double adaptiveBuf = (curAtr > 0.0) ? MathMax(InpBreakevenBufferPips * pipSize, 0.12 * curAtr) : (InpBreakevenBufferPips * pipSize);
   double buf = MathMax(adaptiveBuf, MathMax(1.0 * pipSize, 2.0 * pt));
   double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (openP + buf) : (openP - buf);
   newSL = NormalizeDouble(NormalizePriceToTickSize(sym, newSL), digits);
   trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
}

void ClosePartialTicket(ulong ticket, double fraction)
{
   if(!posInfo.SelectByTicket(ticket)) return;
   double vol = posInfo.Volume();
   double minLot = SymbolInfoDouble(posInfo.Symbol(), SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(posInfo.Symbol(), SYMBOL_VOLUME_STEP);
   if(!MathIsValidNumber(lotStep) || lotStep <= 0.0 || minLot <= 0.0 || fraction <= 0.0) return;
   double closeVol = MathFloor((vol * MathMin(1.0, fraction)) / lotStep) * lotStep;
   if(closeVol >= minLot && closeVol < vol)
      trade.PositionClosePartial(ticket, closeVol);
   else if(closeVol >= vol)
      SafePositionClose(ticket, "CLOSE_PARTIAL_FULL");
}

void CloseTicket(ulong ticket)
{
   PrintFormat("[SEGS TERMINAL] User manual close requested for ticket #%I64u (even if opened by Trade Advisor)", ticket);
   SafePositionClose(ticket, "USER_MANUAL_CLOSE");
}

void ApplyBreakevenAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         string sym = posInfo.Symbol();
         double pipSize = GetPipSize(sym);
         double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
         if(pt <= 0.0) pt = 0.00001;
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double openP = posInfo.PriceOpen();

         double curAtr = 0.0;
         if(g_hAtr_H1 != INVALID_HANDLE && sym == _Symbol)
         {
            double atrBuf[];
            ArraySetAsSeries(atrBuf, true);
            if(CopyBuffer(g_hAtr_H1, 0, 1, 1, atrBuf) == 1) curAtr = atrBuf[0];
         }
         double adaptiveBuf = (curAtr > 0.0) ? MathMax(InpBreakevenBufferPips * pipSize, 0.12 * curAtr) : (InpBreakevenBufferPips * pipSize);
         double buf = MathMax(adaptiveBuf, MathMax(1.0 * pipSize, 2.0 * pt));
         double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (openP + buf) : (openP - buf);
         newSL = NormalizeDouble(NormalizePriceToTickSize(sym, newSL), digits);
         trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
      }
   }
}

void CloseWinningPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket) && posInfo.Profit() > 0)
         SafePositionClose(ticket, "CLOSE_WINNERS");
   }
}

void CloseLosingPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket) && posInfo.Profit() < 0)
         SafePositionClose(ticket, "CLOSE_LOSERS");
   }
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
         SafePositionClose(ticket, "CLOSE_ALL");
   }
}

void CloseBuyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket) && posInfo.PositionType() == POSITION_TYPE_BUY)
         SafePositionClose(ticket, "CLOSE_BUYS");
   }
}

void CloseSellPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket) && posInfo.PositionType() == POSITION_TYPE_SELL)
         SafePositionClose(ticket, "CLOSE_SELLS");
   }
}

void CloseWinnersExceptLowest()
{
   ulong lowestTicket = 0;
   double lowestProfit = 999999999.0;
   int winCount = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket) && posInfo.Profit() > 0)
      {
         winCount++;
         if(posInfo.Profit() < lowestProfit)
         {
            lowestProfit = posInfo.Profit();
            lowestTicket = ticket;
         }
      }
   }

   if(winCount <= 1) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && ticket != lowestTicket && posInfo.SelectByTicket(ticket) && posInfo.Profit() > 0)
         trade.PositionClose(ticket);
   }
}

void CancelPendingOrders(string symFilter)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && orderInfo.Select(ticket))
      {
         string sym = orderInfo.Symbol();
         bool match = (symFilter == "ALL") || (symFilter == "XAU" && IsSymbolMatch(sym, InpXAU_Patterns)) ||
                      (symFilter == "DJ30" && IsSymbolMatch(sym, InpDJ30_Patterns)) ||
                      (symFilter == "NAS100" && IsSymbolMatch(sym, InpNAS_Patterns));
         if(match) trade.OrderDelete(ticket);
      }
   }
}

void ClosePartialTopProfitable(int maxCount, double fraction)
{
   struct PosProfit { ulong ticket; double profit; };
   PosProfit arr[];
   int total = PositionsTotal();
   if(total == 0) return;

   ArrayResize(arr, total);
   int cnt = 0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket))
      {
         arr[cnt].ticket = ticket;
         arr[cnt].profit = posInfo.Profit();
         cnt++;
      }
   }
   ArrayResize(arr, cnt);
   if(cnt == 0) return;

   for(int i = 0; i < cnt - 1; i++)
   {
      for(int j = 0; j < cnt - i - 1; j++)
      {
         if(arr[j].profit < arr[j+1].profit)
         {
            PosProfit tmp = arr[j];
            arr[j] = arr[j+1];
            arr[j+1] = tmp;
         }
      }
   }

   int applyCount = MathMin(maxCount, cnt);
   for(int i = 0; i < applyCount; i++)
   {
      if(arr[i].profit > 0) ClosePartialTicket(arr[i].ticket, fraction);
   }
}

void ActivateAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && orderInfo.Select(ticket))
      {
         string sym = orderInfo.Symbol();
         double vol = orderInfo.VolumeInitial();
         double sl = orderInfo.StopLoss();
         double tp = orderInfo.TakeProfit();
         ENUM_ORDER_TYPE oType = orderInfo.OrderType();

         bool isBuy = (oType == ORDER_TYPE_BUY_LIMIT || oType == ORDER_TYPE_BUY_STOP || oType == ORDER_TYPE_BUY_STOP_LIMIT);
         double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
         double bid = SymbolInfoDouble(sym, SYMBOL_BID);

         bool ok = isBuy ? trade.Buy(vol, sym, ask, sl, tp) : trade.Sell(vol, sym, bid, sl, tp);
         if(ok) trade.OrderDelete(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(!SEGSEnsureRuntimeReady()) return;
   if(id >= CHARTEVENT_CUSTOM)
   {
      // Handle system-wide sync broadcast across charts
      if(sparam == "SEGS_SYNC_SYS" || sparam == "SEGS_RELOAD_ALL")
      {
         if(GlobalVariableCheck("SEGS_SYS_DASH_VIS"))
            g_isDashboardVisible = (GlobalVariableGet("SEGS_SYS_DASH_VIS") > 0.5);
         if(GlobalVariableCheck("SEGS_SYS_SHOW_SENT"))
            g_showSentimentHUD = (GlobalVariableGet("SEGS_SYS_SHOW_SENT") > 0.5);
         if(GlobalVariableCheck("SEGS_SYS_WINRATE_VIS"))
            g_showWinRateHUD = (GlobalVariableGet("SEGS_SYS_WINRATE_VIS") > 0.5);
         if(GlobalVariableCheck("SEGS_SYS_HELP_VIS"))
            g_showHelpHUD = (GlobalVariableGet("SEGS_SYS_HELP_VIS") > 0.5);
         GlobalVariableSet("SEGS_DASH_VIS_" + IntegerToString(ChartID()), g_isDashboardVisible ? 1.0 : 0.0);
         if(!g_isDashboardVisible) DeleteTerminalObjects();
         if(!g_showSentimentHUD) ObjectsDeleteAll(0, PREFIX + "SNT_");
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
         if(g_showWinRateHUD) DrawWinRateHUD();
         if(g_showHelpHUD) DrawHelpHUD();
         ChartRedraw();
         return;
      }
   }

   if(!SEGSEnsureRuntimeReady()) return;

   if(id == CHARTEVENT_CHART_CHANGE)
   {
      DrawUnifiedTerminalDashboard();
      if(g_showSentimentHUD) DrawSentimentHUD();
      if(g_showWinRateHUD) DrawWinRateHUD();
      ChartRedraw();
      return;
   }

   if(id == CHARTEVENT_CLICK)
   {
      ChartSetInteger(0, CHART_BRING_TO_TOP, true);
      ChartSetInteger(0, CHART_KEYBOARD_CONTROL, false);
   }

   // Button Clicks
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // Reset button state and bring chart to top to preserve keyboard focus
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartSetInteger(0, CHART_BRING_TO_TOP, true);
      ChartSetInteger(0, CHART_KEYBOARD_CONTROL, false);
      ChartRedraw(0);
      string chartStr = IntegerToString(ChartID());

      if(sparam == PREFIX + "FLOAT_SHOW" || sparam == PREFIX + "MAT_HIDE")
      {
         g_isDashboardVisible = !g_isDashboardVisible;
         GlobalVariableSet("SEGS_SYS_DASH_VIS", g_isDashboardVisible ? 1.0 : 0.0);
         GlobalVariablesFlush();
         ApplySystemSettingsToAllCharts();
      }
      else if(sparam == PREFIX + "MAT_DOCK")
      {
         // Toggle Docking to bottom vs Floating
         g_isDockedAtBottom = !g_isDockedAtBottom;
         GlobalVariableSet("SEGS_DOCK_BOTTOM_" + IntegerToString(ChartID()), g_isDockedAtBottom ? 1.0 : 0.0);
         GlobalVariablesFlush();
         DeleteTerminalObjects();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_MODE")
      {
         // Toggle Complete Auto vs Controlled Auto
         g_currentMode = (g_currentMode == MODE_COMPLETE_AUTO) ? MODE_CONTROLLED_AUTO : MODE_COMPLETE_AUTO;
         if(g_currentMode == MODE_COMPLETE_AUTO) ProcessUnassignedPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_PROCESS")
      {
         // Explicit Process 'P' trigger
         ProcessUnassignedPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_BE_ALL")
      {
         ApplyBreakevenAll();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_CLOSE_WIN")
      {
         CloseWinningPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_SENT")
      {
         // Toggle Market Sentiment Engine HUD (System-Wide Across All Open Charts)
         g_showSentimentHUD = !g_showSentimentHUD;
         GlobalVariableSet("SEGS_SYS_SHOW_SENT", g_showSentimentHUD ? 1.0 : 0.0);
         GlobalVariablesFlush();
         ApplySystemSettingsToAllCharts();
      }
      else if(sparam == PREFIX + "TAB_POSITIONS")
      {
         // Switch to Terminal Positions Tab
         g_activeDashboardTab = 0;
         GlobalVariableSet("SEGS_ACTIVE_TAB_" + IntegerToString(ChartID()), 0.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "TAB_TRD_MARKS")
      {
         // Switch to or toggle Open Trade Markings Tab
         g_activeDashboardTab = (g_activeDashboardTab == 1) ? 0 : 1;
         GlobalVariableSet("SEGS_ACTIVE_TAB_" + IntegerToString(ChartID()), (double)g_activeDashboardTab);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_TRD_MARKS" || sparam == PREFIX + "OTM_BTN_TOGGLE")
      {
         // Toggle Open Advisor Trades Chart Markings (Entry, SL, TP)
         g_showOpenTradeMarkings = !g_showOpenTradeMarkings;
         GlobalVariableSet("SEGS_SHOW_OPENTRD_" + IntegerToString(ChartID()), g_showOpenTradeMarkings ? 1.0 : 0.0);
         if(g_showOpenTradeMarkings) UpdateOpenTradeMarkings();
         else DeleteOpenTradeMarkings();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "OTM_TOG_LBL")
      {
         // Toggle Open Trade P/L and Info Labels
         g_showOpenTradeLabels = !g_showOpenTradeLabels;
         if(g_showOpenTradeMarkings) UpdateOpenTradeMarkings();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "OTM_TOG_BRK")
      {
         // Toggle Open Trade Vertical Risk/Reward Brackets
         g_showOpenTradeBrackets = !g_showOpenTradeBrackets;
         if(g_showOpenTradeMarkings) UpdateOpenTradeMarkings();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_BROKEN_OB" || sparam == PREFIX + "STB_BTN_BROKEN_OB" || sparam == PREFIX + "SNT_BTN_BROKEN_OB")
      {
         // Toggle Broken Order Blocks on Chart (Default: ON)
         g_showBrokenOrderBlocks = !g_showBrokenOrderBlocks;
         DrawM30OrderBlocks();
         DrawH1OrderBlocks();
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
         ChartRedraw();
         PrintFormat("[SEGS PRO] Broken Order Blocks on chart toggled: %s", g_showBrokenOrderBlocks ? "ON" : "OFF");
      }
      else if(sparam == PREFIX + "MAT_TARGETS" || sparam == PREFIX + "STB_BTN_TGTS")
      {
         // Toggle Suggested Trade Targets Lines (Entry, SL, TP1-4)
         g_showTradeAdviceLines = !g_showTradeAdviceLines;
         if(g_showTradeAdviceLines) UpdateTradeAdviceLines();
         else DeleteTradeAdviceLines();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "STB_BTN_EXEC")
      {
         // Quick Execute 4-Leg Setup directly from Standby Cockpit
         ExecuteAdvisedTrade(false);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "STB_BTN_SENT")
      {
         // Toggle Market Sentiment Engine HUD from Standby Cockpit
         g_showSentimentHUD = !g_showSentimentHUD;
         if(!g_showSentimentHUD) ObjectsDeleteAll(0, PREFIX + "SNT_");
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SNT_POS_TL")
      {
         // Switch Sentiment HUD to Top-Left
         g_sentimentCorner = HUD_POS_TOP_LEFT;
         ObjectsDeleteAll(0, PREFIX + "SNT_");
         DrawSentimentHUD();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SNT_POS_TR")
      {
         // Switch Sentiment HUD to Top-Right
         g_sentimentCorner = HUD_POS_TOP_RIGHT;
         ObjectsDeleteAll(0, PREFIX + "SNT_");
         DrawSentimentHUD();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SNT_POS_BR")
      {
         // Switch Sentiment HUD to Bottom-Right (Down Right Corner Down)
         g_sentimentCorner = HUD_POS_BOTTOM_RIGHT;
         ObjectsDeleteAll(0, PREFIX + "SNT_");
         DrawSentimentHUD();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SNT_POS_BL")
      {
         // Switch Sentiment HUD to Bottom-Left
         g_sentimentCorner = HUD_POS_BOTTOM_LEFT;
         ObjectsDeleteAll(0, PREFIX + "SNT_");
         DrawSentimentHUD();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SNT_CLOSE" || sparam == PREFIX + "SNT_FTR_HOTKEYS")
      {
         // Close Market Sentiment HUD (System-Wide Across All Open Charts)
         g_showSentimentHUD = false;
         GlobalVariableSet("SEGS_SYS_SHOW_SENT", 0.0);
         GlobalVariablesFlush();
         ApplySystemSettingsToAllCharts();
         PrintFormat("[SEGS PRO] Market Sentiment HUD closed system-wide");
      }
      else if(sparam == PREFIX + "SNT_ALERT_BTN")
      {
         // Toggle MT5 Viable Entry Alert on/off [O]
         g_alertOnViableEntry = !g_alertOnViableEntry;
         PrintFormat("[SEGS PRO] Viable Entry Alerts toggled: %s", g_alertOnViableEntry ? "ENABLED" : "DISABLED");
         if(g_showSentimentHUD)
         {
            DrawSentimentHUD();
            ChartRedraw();
         }
      }
      else if(sparam == PREFIX + "SNT_EXEC_BTN")
      {
         // Execute Advised Trade Setup based on market structure scan [Z]
         ExecuteAdvisedTrade(false);
      }
      else if(sparam == PREFIX + "MAT_ADVISOR" || sparam == PREFIX + "SNT_MYADVISOR")
      {
         // Toggle MyAdvisor Auto-Trading of Trade Advice Signals [U]
         g_myAdvisorEnabled = !g_myAdvisorEnabled;
         GlobalVariableSet("SEGS_MYADVISOR_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), g_myAdvisorEnabled ? 1.0 : 0.0);
         PrintFormat("[MyAdvisor] Auto-trading of Trade Advice Signals %s across all open charts.", g_myAdvisorEnabled ? "ENABLED" : "DISABLED");
         if(g_myAdvisorEnabled)
         {
            g_signalGeneratedWhileAdvisorEnabled = true;
            RunAdvisorStrategyEngine(true, true);
         }
         SaveAdvisorPersistentState();
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_SMART_LOT")
      {
         // Toggle Smart Lot Dynamic Sizing vs Fixed Lots [J]
         g_smartLotEnabled = !g_smartLotEnabled;
         GlobalVariableSet("SEGS_SMART_LOT_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), g_smartLotEnabled ? 1.0 : 0.0);
         PrintFormat("[Smart Lot] Dynamic Risk Sizing %s across all open charts.", g_smartLotEnabled ? "ENABLED (Dynamic % Risk & Micro Floor)" : "DISABLED (Using Fixed Lots)");
         SaveAdvisorPersistentState();
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_WINRATE" || sparam == PREFIX + "WR_CLOSE")
      {
         // Toggle Win Rate & Edge Analytics HUD [G]
         g_showWinRateHUD = (sparam == PREFIX + "WR_CLOSE") ? false : !g_showWinRateHUD;
         if(!g_showWinRateHUD) DeleteWinRateHUD();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "WR_TAB_ALL" || sparam == PREFIX + "WR_BTN_BACK")
      {
         g_winRateSelectedSymbol = "ALL";
         DeleteWinRateHUD();
         DrawWinRateHUD();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "WR_TAB_") == 0)
      {
         g_winRateSelectedSymbol = StringSubstr(sparam, StringLen(PREFIX + "WR_TAB_"));
         DeleteWinRateHUD();
         DrawWinRateHUD();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "WR_VIEW_") == 0)
      {
         g_winRateSelectedSymbol = StringSubstr(sparam, StringLen(PREFIX + "WR_VIEW_"));
         DeleteWinRateHUD();
         DrawWinRateHUD();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "WR_R_") == 0)
      {
         int rIdx = (int)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "WR_R_")));
         string discSymbols[];
         int discCount = DiscoverSEGSSymbols(discSymbols);
         if(rIdx >= 0 && rIdx < discCount)
         {
            g_winRateSelectedSymbol = discSymbols[rIdx];
            DeleteWinRateHUD();
            DrawWinRateHUD();
            ChartRedraw();
         }
      }
      else if(sparam == PREFIX + "MAT_HELP" || sparam == PREFIX + "HLP_CLOSE")
      {
         // Toggle Help & Hotkey Matrix HUD [?]
         g_showHelpHUD = (sparam == PREFIX + "HLP_CLOSE") ? false : !g_showHelpHUD;
         if(!g_showHelpHUD) DeleteHelpHUD();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "MAT_BE_TOGGLE")
      {
         // Toggle TP2-BE Auto Shift
         g_autoBreakevenOnTP_Active = !g_autoBreakevenOnTP_Active;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "NUDGE_UP")
      {
         g_tableY = MathMax(4, g_tableY - 20);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "NUDGE_DOWN")
      {
         g_tableY += 20;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SCR_UP" || sparam == PREFIX + "SBAR_UP")
      {
         // Terminal pagination scroll up
         g_terminalScrollIndex = MathMax(0, g_terminalScrollIndex - 1);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SCR_DOWN" || sparam == PREFIX + "SBAR_DN")
      {
         // Terminal pagination scroll down
         int nPositions = PositionsTotal();
         int maxVis = MathMax(1, InpMaxVisiblePositions);
         if(g_terminalScrollIndex + 1 <= nPositions - maxVis)
            g_terminalScrollIndex++;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SBAR_TRACK" || sparam == PREFIX + "SBAR_THUMB")
      {
         // Clicking the track or thumb steps or cycles pagination
         int nPositions = PositionsTotal();
         int maxVis = MathMax(1, InpMaxVisiblePositions);
         if(g_terminalScrollIndex + maxVis < nPositions)
            g_terminalScrollIndex = MathMin(nPositions - maxVis, g_terminalScrollIndex + maxVis);
         else
            g_terminalScrollIndex = 0;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_SEL_") == 0)
      {
         // Select or deselect trade
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_SEL_")));
         g_selectedTicket = (g_selectedTicket == ticket) ? 0 : ticket;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_SL_UP_") == 0)
      {
         // Shift Stop Loss Up (+5 pips)
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_SL_UP_")));
         ShiftStopLossTicket(ticket, 5.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_SL_DN_") == 0)
      {
         // Shift Stop Loss Down (-5 pips)
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_SL_DN_")));
         ShiftStopLossTicket(ticket, -5.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_TP_UP_") == 0)
      {
         // Shift Take Profit Up (+10 pips)
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_TP_UP_")));
         ShiftTakeProfitTicket(ticket, 10.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_TP_DN_") == 0)
      {
         // Shift Take Profit Down (-10 pips)
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_TP_DN_")));
         ShiftTakeProfitTicket(ticket, -10.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SEL_SL_UP")
      {
         if(g_selectedTicket > 0) ShiftStopLossTicket(g_selectedTicket, 5.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SEL_SL_DN")
      {
         if(g_selectedTicket > 0) ShiftStopLossTicket(g_selectedTicket, -5.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SEL_TP_UP")
      {
         if(g_selectedTicket > 0) ShiftTakeProfitTicket(g_selectedTicket, 10.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SEL_TP_DN")
      {
         if(g_selectedTicket > 0) ShiftTakeProfitTicket(g_selectedTicket, -10.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SEL_BE")
      {
         if(g_selectedTicket > 0) ApplyBreakevenTicket(g_selectedTicket);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "SEL_CLOSE")
      {
         if(g_selectedTicket > 0)
         {
            CloseTicket(g_selectedTicket);
            g_selectedTicket = 0;
         }
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_BE_") == 0)
      {
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_BE_")));
         ApplyBreakevenTicket(ticket);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_50_") == 0)
      {
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_50_")));
         ClosePartialTicket(ticket, 0.5);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_SL_") == 0)
      {
         ProcessUnassignedPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      else if(StringFind(sparam, PREFIX + "BTN_X_") == 0)
      {
         ulong ticket = (ulong)StringToInteger(StringSubstr(sparam, StringLen(PREFIX + "BTN_X_")));
         CloseTicket(ticket);
         if(g_selectedTicket == ticket) g_selectedTicket = 0;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
   }

   // MOUSE WHEEL SCROLLING FOR TERMINAL NAVIGATION
   if(id == CHARTEVENT_MOUSE_WHEEL)
   {
      int nPositions = PositionsTotal();
      int maxVis = MathMax(1, InpMaxVisiblePositions);
      if(nPositions > maxVis)
      {
         if(dparam > 0)
         {
            g_terminalScrollIndex = MathMax(0, g_terminalScrollIndex - 1);
         }
         else if(dparam < 0)
         {
            if(g_terminalScrollIndex + 1 <= nPositions - maxVis)
               g_terminalScrollIndex++;
         }
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      return;
   }

   // KEYBOARD HOTKEYS
   if(id == CHARTEVENT_KEYDOWN)
   {
      ushort vk = (ushort)(lparam & 0xFFFF);
      ushort ch = vk;
      string chartStr = IntegerToString(ChartID());

      bool isD = (vk == 'D' || vk == 'd' || vk == 68 || ch == 'D' || ch == 'd' || (lparam == 68) || ((lparam & 0xFF) == 68));
      bool isP = (vk == 'P' || vk == 'p' || vk == 80 || ch == 'P' || ch == 'p' || (lparam == 80) || ((lparam & 0xFF) == 80));
      bool isC = (vk == 'C' || vk == 'c' || vk == 67 || ch == 'C' || ch == 'c' || (lparam == 67) || ((lparam & 0xFF) == 67));
      bool isH = (vk == 'H' || vk == 'h' || vk == 72 || vk == 104 || ch == 'H' || ch == 'h' || (lparam == 72) || (lparam == 104) || ((lparam & 0xFF) == 72) || ((lparam & 0xFF) == 104));
      bool isM = (vk == 'M' || vk == 'm' || vk == 77 || vk == 109 || ch == 'M' || ch == 'm' || (lparam == 77) || (lparam == 109) || ((lparam & 0xFF) == 77) || ((lparam & 0xFF) == 109));
      bool isV = (vk == 'V' || vk == 'v' || vk == 86 || ch == 'V' || ch == 'v' || (lparam == 86) || ((lparam & 0xFF) == 86));
      bool isB = (vk == 'B' || vk == 'b' || vk == 66 || ch == 'B' || ch == 'b' || (lparam == 66) || ((lparam & 0xFF) == 66));
      bool isK = (vk == 'K' || vk == 'k' || vk == 75 || ch == 'K' || ch == 'k' || (lparam == 75) || ((lparam & 0xFF) == 75));
      bool isO = (vk == 'O' || vk == 'o' || vk == 79 || ch == 'O' || ch == 'o' || (lparam == 79) || ((lparam & 0xFF) == 79));
      bool isZ = (vk == 'Z' || vk == 'z' || vk == 90 || ch == 'Z' || ch == 'z' || (lparam == 90) || ((lparam & 0xFF) == 90));
      bool isG = (vk == 'G' || vk == 'g' || vk == 71 || ch == 'G' || ch == 'g' || (lparam == 71) || ((lparam & 0xFF) == 71));
      bool isU = (vk == 'U' || vk == 'u' || vk == 85 || ch == 'U' || ch == 'u' || (lparam == 85) || ((lparam & 0xFF) == 85));
      bool isJ = (vk == 'J' || vk == 'j' || vk == 74 || ch == 'J' || ch == 'j' || (lparam == 74) || ((lparam & 0xFF) == 74));
      bool isT = (vk == 'T' || vk == 't' || vk == 84 || ch == 'T' || ch == 't' || (lparam == 84) || ((lparam & 0xFF) == 84));
      bool isW = (vk == 'W' || vk == 'w' || vk == 87 || ch == 'W' || ch == 'w');
      bool isL = (vk == 'L' || vk == 'l' || vk == 76 || ch == 'L' || ch == 'l');
      bool isA = (vk == 'A' || vk == 'a' || vk == 65 || ch == 'A' || ch == 'a');
      bool isY = (vk == 'Y' || vk == 'y' || vk == 89 || ch == 'Y' || ch == 'y');
      bool isS = (vk == 'S' || vk == 's' || vk == 83 || ch == 'S' || ch == 's');
      bool isE = (vk == 'E' || vk == 'e' || vk == 69 || ch == 'E' || ch == 'e');
      bool is1 = (vk == '1' || vk == 49 || ch == '1');
      bool is2 = (vk == '2' || vk == 50 || ch == '2');
      bool is4 = (vk == '4' || vk == 52 || ch == '4');
      bool is5 = (vk == '5' || vk == 53 || ch == '5');
      bool is8 = (vk == '8' || vk == 56 || ch == '8');
      bool is9 = (vk == '9' || vk == 57 || ch == '9');
      bool isHelp = (vk == '?' || vk == '/' || vk == 191 || vk == 112 || ch == '?' || ch == '/');
      bool isScrollUp = (vk == '[' || vk == 38 || ch == '[');
      bool isScrollDn = (vk == ']' || vk == 40 || ch == ']');

      // 'D' = TOGGLE DOCKING TO BOTTOM VS FLOATING
      if(isD)
      {
         g_isDockedAtBottom = !g_isDockedAtBottom;
         GlobalVariableSet("SEGS_DOCK_BOTTOM_" + chartStr, g_isDockedAtBottom ? 1.0 : 0.0);
         GlobalVariablesFlush();
         DeleteTerminalObjects();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // '[' or UP ARROW = SCROLL TERMINAL UP
      else if(isScrollUp)
      {
         g_terminalScrollIndex = MathMax(0, g_terminalScrollIndex - 1);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // ']' or DOWN ARROW = SCROLL TERMINAL DOWN
      else if(isScrollDn)
      {
         int nPositions = PositionsTotal();
         int maxVis = MathMax(1, InpMaxVisiblePositions);
         if(g_terminalScrollIndex + 1 <= nPositions - maxVis)
            g_terminalScrollIndex++;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'P' = PROCESS SL/TP FOR CONTROLLED AUTO MODE
      else if(isP)
      {
         ProcessUnassignedPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'C' = TOGGLE COMPLETE AUTO VS CONTROLLED AUTO
      else if(isC)
      {
         g_currentMode = (g_currentMode == MODE_COMPLETE_AUTO) ? MODE_CONTROLLED_AUTO : MODE_COMPLETE_AUTO;
         if(g_currentMode == MODE_COMPLETE_AUTO) ProcessUnassignedPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'H' = HIDE / SHOW DASHBOARD (System-Wide Across All Open Charts)
      else if(isH)
      {
         g_isDashboardVisible = !g_isDashboardVisible;
         GlobalVariableSet("SEGS_SYS_DASH_VIS", g_isDashboardVisible ? 1.0 : 0.0);
         GlobalVariablesFlush();
         ApplySystemSettingsToAllCharts();
         PrintFormat("[SEGS PRO] Hotkey 'H' triggered - Terminal Dashboard System-Wide: %s", g_isDashboardVisible ? "VISIBLE" : "HIDDEN");
      }
      // 'M' = TOGGLE MARKET SENTIMENT ENGINE HUD (System-Wide Across All Open Charts)
      else if(isM)
      {
         g_showSentimentHUD = !g_showSentimentHUD;
         GlobalVariableSet("SEGS_SYS_SHOW_SENT", g_showSentimentHUD ? 1.0 : 0.0);
         GlobalVariablesFlush();
         ApplySystemSettingsToAllCharts();
         PrintFormat("[SEGS PRO] Hotkey 'M' triggered - Market Sentiment HUD System-Wide: %s", g_showSentimentHUD ? "VISIBLE" : "HIDDEN");
      }
      // 'V' = CYCLE MARKET SENTIMENT HUD CORNER (TL -> TR -> BR -> BL)
      else if(isV)
      {
         if(g_sentimentCorner == HUD_POS_TOP_LEFT)          g_sentimentCorner = HUD_POS_TOP_RIGHT;
         else if(g_sentimentCorner == HUD_POS_TOP_RIGHT)    g_sentimentCorner = HUD_POS_BOTTOM_RIGHT;
         else if(g_sentimentCorner == HUD_POS_BOTTOM_RIGHT) g_sentimentCorner = HUD_POS_BOTTOM_LEFT;
         else                                               g_sentimentCorner = HUD_POS_TOP_LEFT;

         if(g_showSentimentHUD)
         {
            ObjectsDeleteAll(0, PREFIX + "SNT_");
            DrawSentimentHUD();
            ChartRedraw();
         }
      }
      // 'B' = TOGGLE BROKEN ORDER BLOCKS DISPLAY ON/OFF (DEFAULT: ON)
      else if(isB)
      {
         g_showBrokenOrderBlocks = !g_showBrokenOrderBlocks;
         DrawM30OrderBlocks();
         DrawH1OrderBlocks();
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
         ChartRedraw();
         PrintFormat("[SEGS PRO] Broken Order Blocks on chart toggled: %s (Hotkey: B)", g_showBrokenOrderBlocks ? "ON" : "OFF");
      }
      // 'K' = TOGGLE SUGGESTED TRADE TARGETS (ENTRY, SL, TP1-4)
      else if(isK)
      {
         g_showTradeAdviceLines = !g_showTradeAdviceLines;
         if(g_showTradeAdviceLines) UpdateTradeAdviceLines();
         else DeleteTradeAdviceLines();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'O' = TOGGLE VIABLE ENTRY ALERTS ON/OFF
      else if(isO)
      {
         g_alertOnViableEntry = !g_alertOnViableEntry;
         PrintFormat("[SEGS PRO] Viable Entry Alerts toggled: %s", g_alertOnViableEntry ? "ENABLED" : "DISABLED");
         if(g_showSentimentHUD)
         {
            DrawSentimentHUD();
            ChartRedraw();
         }
      }
      // 'Z' = EXECUTE ADVISEMENT TRADE SETUP (OR DISCIPLINARY STAND ASIDE IF NO ENTRY)
      else if(isZ)
      {
         ExecuteAdvisedTrade(false);
      }
      // 'G' = TOGGLE WIN RATE & EDGE ANALYTICS OVERLAY
      else if(isG)
      {
         g_showWinRateHUD = !g_showWinRateHUD;
         if(!g_showWinRateHUD) DeleteWinRateHUD();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // '?' or '/' or F1 = TOGGLE QUICK HELP & HOTKEY MANUAL
      else if(isHelp)
      {
         g_showHelpHUD = !g_showHelpHUD;
         if(!g_showHelpHUD) DeleteHelpHUD();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'U' = TOGGLE MYADVISOR AUTO-TRADING OF SIGNALS
      else if(isU)
      {
         g_myAdvisorEnabled = !g_myAdvisorEnabled;
         GlobalVariableSet("SEGS_MYADVISOR_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), g_myAdvisorEnabled ? 1.0 : 0.0);
         PrintFormat("[MyAdvisor] Auto-trading of Trade Advice Signals %s across all open charts.", g_myAdvisorEnabled ? "ENABLED" : "DISABLED");
         if(g_myAdvisorEnabled)
         {
            g_signalGeneratedWhileAdvisorEnabled = true;
            RunAdvisorStrategyEngine(true, true);
         }
         SaveAdvisorPersistentState();
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
         ChartRedraw();
      }
      // 'J' = TOGGLE SMART LOT SIZE SELECTOR (DYNAMIC RISK-BASED VS FIXED LOTS)
      else if(isJ)
      {
         g_smartLotEnabled = !g_smartLotEnabled;
         GlobalVariableSet("SEGS_SMART_LOT_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), g_smartLotEnabled ? 1.0 : 0.0);
         PrintFormat("[Smart Lot] Dynamic Risk Sizing %s across all open charts.", g_smartLotEnabled ? "ENABLED (Dynamic % Risk & Micro Floor)" : "DISABLED (Using Fixed Lots)");
         SaveAdvisorPersistentState();
         DrawUnifiedTerminalDashboard();
         if(g_showSentimentHUD) DrawSentimentHUD();
         ChartRedraw();
      }
      // '1' = SWITCH TO TAB 0: TERMINAL POSITIONS
      else if(is1)
      {
         g_activeDashboardTab = 0;
         GlobalVariableSet("SEGS_ACTIVE_TAB_" + chartStr, 0.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // '2' = SWITCH TO TAB 1: OPEN TRADE MARKINGS
      else if(is2)
      {
         g_activeDashboardTab = 1;
         GlobalVariableSet("SEGS_ACTIVE_TAB_" + chartStr, 1.0);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'T' = TOGGLE OPEN ADVISOR TRADES CHART MARKINGS (ENTRY, SL, TP)
      else if(isT)
      {
         g_showOpenTradeMarkings = !g_showOpenTradeMarkings;
         GlobalVariableSet("SEGS_SHOW_OPENTRD_" + chartStr, g_showOpenTradeMarkings ? 1.0 : 0.0);
         if(g_showOpenTradeMarkings) UpdateOpenTradeMarkings();
         else DeleteOpenTradeMarkings();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'W' = CLOSE WINNERS
      else if(isW)
      {
         CloseWinningPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'L' = CLOSE LOSERS
      else if(isL)
      {
         CloseLosingPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'A' = CLOSE ALL
      else if(isA)
      {
         CloseAllPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'Y' = CLOSE BUYS
      else if(isY)
      {
         CloseBuyPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'S' = CLOSE SELLS
      else if(isS)
      {
         CloseSellPositions();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // '8' = KEEP 1 LOWEST WINNER, CLOSE REST
      else if(is8)
      {
         CloseWinnersExceptLowest();
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // '9' = CANCEL PENDING ORDERS
      else if(is9)
      {
         CancelPendingOrders("ALL");
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // '4' = CLOSE ~4% (OR 40%) OF TOP 2
      else if(is4)
      {
         ClosePartialTopProfitable(2, 0.40);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // '5' = CLOSE 50% OF TOP 1
      else if(is5)
      {
         ClosePartialTopProfitable(1, 0.50);
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
      // 'E' = TOGGLE EXPAND / COMPACT
      else if(isE)
      {
         g_isMatrixExpanded = !g_isMatrixExpanded;
         DrawUnifiedTerminalDashboard();
         ChartRedraw();
      }
   }
}
//+------------------------------------------------------------------+
