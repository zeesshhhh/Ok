import os

WATCHLIST = {
    "BTC-USD": "crypto", "ETH-USD": "crypto", "SOL-USD": "crypto",
    "EURUSD=X": "forex", "GBPUSD=X": "forex", "USDJPY=X": "forex",
    "AUDUSD=X": "forex", "USDCAD=X": "forex", "USDCHF=X": "forex",
    "GC=F": "futures", "SI=F": "futures", "ES=F": "futures", "NQ=F": "futures", "CL=F": "futures",
}
CURRENCIES = {
    "BTC-USD": ["USD"], "ETH-USD": ["USD"], "SOL-USD": ["USD"],
    "EURUSD=X": ["EUR", "USD"], "GBPUSD=X": ["GBP", "USD"], "USDJPY=X": ["JPY", "USD"],
    "AUDUSD=X": ["AUD", "USD"], "USDCAD=X": ["USD", "CAD"], "USDCHF=X": ["USD", "CHF"],
    "GC=F": ["USD"], "SI=F": ["USD"], "ES=F": ["USD"], "NQ=F": ["USD"], "CL=F": ["USD"],
}
NEWS_KEYWORDS = {
    "BTC-USD": ["bitcoin", "btc"], "ETH-USD": ["ethereum", "ether", "eth "], "SOL-USD": ["solana"],
    "EURUSD=X": ["euro", "ecb", "eur/usd"], "GBPUSD=X": ["pound", "sterling", "boe", "gbp"],
    "USDJPY=X": ["yen", "boj", "jpy"],
    "AUDUSD=X": ["aussie", "rba", "aud"], "USDCAD=X": ["loonie", "boc", "cad", "canadian dollar"], "USDCHF=X": ["franc", "snb", "chf"], "GC=F": ["gold"], "SI=F": ["silver"],
    "ES=F": ["s&p", "wall street", "stocks"], "NQ=F": ["nasdaq", "tech stocks"], "CL=F": ["oil", "crude", "opec"],
}
MACRO_WORDS = ["fed", "fomc", "inflation", "cpi", "dollar", "powell", "rate cut", "rate hike"]

# timeframes
INTERVAL = {"5m": "5m", "15m": "15m", "1h": "1h", "1d": "1d"}
LIVE_PERIOD = {"5m": "5d", "15m": "1mo", "1h": "60d", "1d": "2y"}
BACKTEST_PERIOD = {"5m": "60d", "15m": "60d", "1h": "730d", "1d": "5y"}
BAR_MIN = {"5m": 5, "15m": 15, "1h": 60, "1d": 1440}

# risk and filters
MIN_SCORE = 4                # swing score threshold (max 7)
RR = 2.0
ATR_SL = 1.5
NEWS_BLACKOUT_MIN = 45
NEWS_FILTER = True
FLOW_FILTER = True
FOREX_SESSION = (7, 17)      # UTC hours; intraday forex strategies only fire inside this window
# Default = only strategies with PF > 1.1 in backtest_results.txt. Re-run the backtest and edit this set.
# Set to None to run everything (Swing, Quant, Price action, Scalping, Trend, Breakout, Mean reversion lost money).
ENABLED_STRATEGIES = {"Position", "Intraday ORB", "Day trading", "Reversal"}

# special strategies
PAIRS = [("ETH-USD", "BTC-USD"), ("EURUSD=X", "GBPUSD=X"), ("GC=F", "SI=F")]
PAIR_Z_ENTRY, PAIR_MIN_CORR = 2.0, 0.6
ARB_MIN_PCT = 0.35           # cross-exchange spread must beat fees plus transfer slippage
MOMENTUM_TOP_N = 2
OPTIONS_EQUITY = ["SPY"]
COPY_SOURCE_URL = os.getenv("COPY_SOURCE_URL", "")   # JSON list of trades from a trader you follow

# investing (not intraday signals)
STOCKS = ["AAPL", "MSFT", "GOOGL", "NVDA", "V", "KO", "JNJ", "PG", "XOM", "JPM", "PEP", "HD"]
LONGTERM = ["BTC-USD", "ETH-USD", "GC=F", "SPY", "QQQ"]

# paper trading
PAPER_START = 10000
PAPER_RISK = 0.01

MAX_SIGNAL_AGE_H = 3
TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "claude-sonnet-5-5")
