# Crypto, forex and futures strategy bot

30 strategy styles in one Telegram bot. Run backtest first, then let paper trading prove which ones pay.

## Setup
1. @BotFather > /newbot > copy token. Message your bot, open https://api.telegram.org/bot<TOKEN>/getUpdates, copy `chat.id`.
2. Repo > Settings > Secrets > Actions: `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`. Optional: `ANTHROPIC_API_KEY` (AI summary), `COPY_SOURCE_URL`.
3. Actions > Signal bot > Run workflow > mode `backtest`. Read it before trusting anything.
4. Schedules: scan every 15 min, daily report 06:00 UTC, investing report Mondays 07:00 UTC.
   Private repos have 2,000 free Actions minutes per month: use a public repo or change the cron to hourly.

## Where each strategy lives
| Strategy | How it works here | Where |
|---|---|---|
| Scalping | 5m EMA9/21 cross, ADX filter, tight stop | strategies.py |
| Day trading | 15m pullback to EMA21, VWAP side | strategies.py |
| Intraday | 15m opening-range breakout, same-day exit | strategies.py |
| Swing | 1H entry confirmed by 4H trend, scored out of 7 | signals.py |
| Position | Daily golden/death cross, wide stop | strategies.py |
| Trend | Aligned EMAs, ADX above 25, dip entry | strategies.py |
| Momentum | Weekly cross-asset 60-day ranking, long top / short bottom | special.py |
| Breakout | 20-bar Donchian break, expansion, volume | strategies.py |
| Reversal | Band exhaustion plus engulfing or hammer | strategies.py |
| Range | Low ADX, fade range edges, target mid | strategies.py |
| Mean reversion | Z-score below -2 or above +2 with RSI, target mean | strategies.py |
| Price action | Pin bar or engulfing at confirmed swing levels | strategies.py |
| Quantitative | Multi-factor z-score (momentum, flow, trend) | indicators.py, strategies.py |
| News trading | Headline sentiment plus confirming candle | special.py |
| Event-driven | Break of pre-event range after high-impact release, plus 1-hour heads-up | special.py, main.py |
| Pairs trading | Hedge-ratio regression, spread z-score (ETH/BTC, EUR/GBP, gold/silver) | special.py |
| Arbitrage | Coinbase vs Kraken vs OKX spread alerts (alert only) | special.py |
| Options trading | Deribit put/call ratio and IV, SPY chain, option-structure ideas | special.py |
| Futures trading | Gold, silver, S&P, Nasdaq, crude run through all strategies, plus funding data | config.py |
| Forex / Crypto trading | Asset classes with forex session filter and crypto order flow | main.py |
| Algorithmic trading | The scheduled engine itself, rules only, no discretion | main.py |
| HFT | Order-book depth snapshot only (see limits) | special.py |
| Copy trading | Relays trades from a JSON feed you point to | special.py |
| Paper trading | Every alert becomes a virtual trade with per-strategy results | paper.py |
| Value / Growth / Dividend investing | Weekly fundamental screens on STOCKS | fundamentals.py |
| Long-term / buy and hold | 200DMA, 12-month return, drawdown, DCA guidance, benchmark in backtest | fundamentals.py, backtest.py |

## Crypto futures coins
`FUTURES_TOP_N` in config.py (default 30) adds the top USDT perpetual coins by 24h volume, scanned with OKX data on 15m, 30m, 1H, 4H and 1D. They run every strategy but are always tagged experimental. Set it to 0 to switch off. Binance coins outside the top N are available in the app's Scanner tab only.

## Honest limits
- True HFT needs colocated servers and microsecond latency. GitHub Actions cannot do it. The bot only reads order-book imbalance at scan time.
- Arbitrage and copy trading are alerts. Fees, withdrawal time and USD-vs-USDT premiums often erase small spreads.
- Yahoo data can be delayed or patchy, and forex volume is mostly missing.
- Backtests ignore slippage in fast markets. Judge strategies by their paper-trading record, not one backtest.
- Analysis only, not financial advice.

## Android app (APK)
The bot publishes `docs/feed.json` after each run. The app reads it, so the repo must be public.
1. Run the Signal bot workflow once so `docs/feed.json` exists.
2. Actions > Build APK > Run workflow (about 10 minutes).
3. Open the repo's Releases page on your phone, download `signal-bot.apk`, and allow "install unknown apps" when asked.
4. Tabs: Markets, Scanner, Signals, News, Alerts, Account (the bot's paper trades), Paper (the app's own paper trades), Report. Pull down to refresh.

### In-app auto paper trading (Paper tab)
- Switch on Auto paper trading. Choose the coins (top 20, 50 or 100 by 24h volume) and the timeframes (5m, 15m, 30m, 1h, 4h, 1d). When a candle closes on a chosen timeframe, the app checks each coin once on that candle and opens virtual trades from signals that meet your minimum strength and quality filter. Signals more than 60% of a candle old are skipped so entries are never stale.
- Rules: 1.2+ reward to risk, one open trade per coin and timeframe, none during a high-impact news window, cooldown after a close. 1% risk per trade, 0.05R fees, same-candle stop and target counts as a loss.
- Quality filter (Paper tab, default 3 of 5). Before a scanner trade opens, the app re-checks it: the verdict must hold on the closed candle (the forming candle repaints), price must not be stretched over 3 ATR from EMA20 or RSI exhausted, volume must not be dead, and the next higher timeframe must not oppose it. Altcoins also must not fight the Bitcoin 1h and 4h trend. Five points are then scored: next timeframe agrees, the one above agrees, volume 1.2x average or more, ADX 20+, and funding and news not crowded against it. Choose Off, 3 of 5 or 4 of 5. Quality is logged per trade, so the Paper tab and CSV show whether the filter actually improves results.
- Direction cap: no more than 60% of the open-trade limit may point the same way, since many coins move together.
- Stop rule: Fixed stop, Break-even (stop moves to entry after +1R, from the next candle), or A/B test (alternate trades), so the Paper tab shows which rule performs better.
- Markets tab has a Paper trade this button for a manual entry.
- Stops, targets and timeouts are checked every 60 seconds while the app is open. On reopening, the app replays candles since entry, so hits made while it was closed are still recorded.
- Accuracy: win rate, average R, profit factor, hit target vs stop vs timeout, breakdown by timeframe, direction, signal strength and coin, plus a short list of the best and worst groups.
- Download logs: in-app CSV, bot CSV, or both at once (share sheet, or copy to clipboard). Column names match, so the two can be compared. Send the files to tune the bot.

### Keeping your data between installs
The build now also writes the fixed key into the Gradle signing config, and a build step prints the certificate. A correct build shows a SHA-256 ending in 95:89:00 (Actions, Build APK, step "Show signing certificate"). If it shows anything else, Android will refuse to install it over the old app.

Builds are now signed with a fixed key (app_src/debug.keystore) and a rising version number, so a new APK installs over the old one and keeps your paper trades and Lab data. The one time you move from an older APK to this one, Android will ask you to uninstall first, which erases the old data. Use All logs to export before that. Data is stored as files in the app's own folder, written safely, and never overwritten if it cannot be read.

### Server-side Signal Lab (runs 24/7, no app needed)
`lab.py` runs inside the same GitHub Actions bot, right after each scan, so collection no longer stops when the phone app is closed.
- It follows the top 40 USDT perpetuals (OKX data) on 15m, 1h, 4h and 1d, using the same indicator names and rules as the app (47 indicators plus the overall verdict). Change `LAB_TOP_N` and `LAB_TFS` in the workflow env if you want more or fewer.
- The first runs backfill history (about 1,500 candles per pair), computing each indicator only from data available at that candle, so thousands of scored signals exist straight away and cover more than one market regime. Later runs add only candles that closed since the last run. A run stops starting new work after 12 minutes and continues next time, so the full backfill may take a few runs.
- Results go to a separate branch called `lab-data` (history is not kept, so your repo does not grow). The branch is created by the first run. Raw files: `https://raw.githubusercontent.com/<you>/<repo>/lab-data/lab.json`, `lab_accuracy.csv`, `lab_snapshots.csv`.
- The Lab tab in the app now defaults to Server (24/7) and shows the same drift-adjusted rankings. Pull down to refresh. The phone collector is still there under This phone.
- Run it by hand any time: Actions, Signal bot, Run workflow, mode `lab`.
- Needs the repo to be public (same as the feed) and Actions write permission (already set).
- Honest limits: backfilled coins are the top by volume today, 15-minute cron runs can be delayed by GitHub, and neighbouring candles overlap, so the app shows "independent windows" (distinct closes divided by 6) and keeps rankings grey until there are 30 or more.

The Lab tab also has a Trades placed card: paper trades grouped by style (Scalping, Intraday, Swing, Position) next to the Lab's result for the same style, plus the latest 15 trades with entry, stop, target, quality and result.

### Candidate composites and the Forward test
The server Lab also scores fixed composite rules: the trend-following family only, the contrarian oscillators only, and the app's own verdict split by ADX regime (above 25, 20 to 25, below 20). The rules are fixed and not tuned. The first run of this version rebuilds the Lab from history once (a few runs), then the Forward style counts only candles that closed after that moment, so it is a fair out-of-sample test. Judge the composites on Forward, not on the history.

### Signal Lab on the phone (Lab tab, This phone)
- Switch it on and keep the app open. At every candle close (15m, 1h, 4h, 1d, optional 5m) for the top 10, 20 or 40 coins, it records the vote of every indicator (trend, momentum, volume, breakout, support/resistance, candle patterns, overall verdict).
- 6 candles later it scores each vote: direction right or wrong, how far price moved in ATR, and a race test (+1.5 ATR before -1.5 ATR).
- The tab compares trading styles (Scalping 15m, Intraday 1h, Swing 4h, Position 1d), indicator families and each single indicator, best first. Anything under 30 signals is greyed out.
- Every score is compared with what a random mix of buys and sells would have scored in the same market ("expected"), so a falling day cannot make bearish indicators look good. Rankings stay grey until there are 30+ distinct candle closes, because coins that signal at the same close move together.
- Download the accuracy table, the raw snapshots, or All logs (also includes paper trades and the bot log).

- Trades live on the phone only. Clearing app data or Reset deletes them, so download first.
Telegram stays your push-notification channel. The app is for viewing.
