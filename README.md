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
4. The app has three tabs: Signals (filter Buy/Sell), Account (paper trading by strategy), Report. Pull down to refresh.
Telegram stays your push-notification channel. The app is for viewing.
