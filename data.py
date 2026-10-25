import pandas as pd
import yfinance as yf

def get_ohlc(symbol, interval="1h", period="60d"):
    df = yf.download(symbol, interval=interval, period=period, progress=False, auto_adjust=True)
    if df is None or df.empty:
        return pd.DataFrame()
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df = df.rename(columns=str.lower)[["open", "high", "low", "close", "volume"]].dropna()
    return df

def resample(df, rule="4h"):
    return df.resample(rule).agg(
        {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"}
    ).dropna()
