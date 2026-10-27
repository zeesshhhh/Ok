"""Server-side Signal Lab. Runs inside the GitHub Actions bot, so collection no longer depends on the phone app.

For the top USDT perpetuals (OKX data) on 15m, 1h, 4h and 1d it records what every indicator voted at each candle close
(same names and rules as the Android app), then scores each vote against what price did over the next 6 candles:
  * direction: was the 6-candle move in the vote's direction
  * race: did price move 1.5 ATR in the vote's direction before 1.5 ATR against it
Because indicators can be computed on any past candle, the first runs backfill history, so thousands of scored signals
exist after the first run instead of after days of waiting. Later runs only add candles that closed since last time.

Outputs (all in docs/, committed by the workflow):
  lab_state.json       full state (aggregates, progress marks) so every run continues where the last one stopped
  lab.json             small summary the app downloads
  lab_accuracy.csv     one row per indicator and style, with the expected score from market drift
  lab_snapshots.csv    newest raw snapshots per style (every indicator's vote and what happened next)
"""
import json
import math
import os
import sys
import time

import numpy as np
import pandas as pd
import requests

OKX = "https://www.okx.com/api/v5"
OKX_BAR = {"5m": "5m", "15m": "15m", "30m": "30m", "1h": "1H", "4h": "4H", "1d": "1D"}
BAR_MS = {"5m": 300_000, "15m": 900_000, "30m": 1_800_000, "1h": 3_600_000, "4h": 14_400_000, "1d": 86_400_000}
STYLE = {"5m": "Scalping", "15m": "Scalping", "30m": "Intraday", "1h": "Intraday", "4h": "Swing", "1d": "Position"}
STYLES = ["Scalping", "Intraday", "Swing", "Position"]

TOP_N = int(os.getenv("LAB_TOP_N", "40"))
TFS = [t for t in os.getenv("LAB_TFS", "15m,1h,4h,1d").split(",") if t in OKX_BAR]
BACKFILL = {"5m": 1200, "15m": 1500, "30m": 1500, "1h": 1500, "4h": 1500, "1d": 900}   # candles fetched the first time a pair is seen
HORIZON = 6          # candles after the signal that are judged
RACE_ATR = 1.5       # target and stop distance of the race test, in ATR
WARMUP = 100         # skip the first candles of a series, long indicators are not ready
MAX_SECONDS = int(os.getenv("LAB_MAX_SECONDS", "840"))     # stop starting new work after 14 minutes
MAX_CALLS = int(os.getenv("LAB_MAX_CALLS", "1800"))
KEEP_ROWS_PER_STYLE = 1000
EXCLUDE = {"USDC", "FDUSD", "TUSD", "USDT", "DAI", "USDE", "USD1", "PYUSD"}

DOCS = "docs"
STATE = f"{DOCS}/lab_state.json"
SUMMARY = f"{DOCS}/lab.json"
ACC_CSV = f"{DOCS}/lab_accuracy.csv"
ROWS_CSV = f"{DOCS}/lab_snapshots.csv"

MR = {"RSI (14)", "Stochastic (14,3)", "CCI (20)", "Williams %R (14)", "Bollinger %B (20,2)", "MFI (14)",
      "Stochastic RSI", "Ultimate Oscillator", "Support / Resistance"}

_calls = 0


# ---------------------------------------------------------------- data
def _get(path, params):
    global _calls
    for attempt in range(3):
        _calls += 1
        time.sleep(0.12)                       # OKX allows 20 requests / 2 s on these endpoints
        try:
            r = requests.get(f"{OKX}{path}", params=params, timeout=20)
            if r.status_code == 429:
                time.sleep(2 + attempt * 2)
                continue
            j = r.json()
            if j.get("code") == "0":
                return j.get("data") or []
        except Exception:
            time.sleep(1)
    return None


def _to_arrays(rows):
    """OKX rows are newest first: [ts, o, h, l, c, vol, volCcy, volCcyQuote, confirm]. Keep closed candles, oldest first."""
    seen = {}
    for r in rows:
        if len(r) > 8 and str(r[8]) != "1":
            continue
        seen[int(r[0])] = r
    if not seen:
        return None
    ts = sorted(seen)
    a = np.array([[float(seen[t][k]) for k in range(1, 6)] for t in ts])
    return {"ts": np.array(ts, dtype=np.int64), "o": a[:, 0], "h": a[:, 1], "l": a[:, 2], "c": a[:, 3], "v": a[:, 4]}


def fetch_latest(inst, tf):
    rows = _get("/market/candles", {"instId": inst + "-SWAP", "bar": OKX_BAR[tf], "limit": "300"})
    return _to_arrays(rows) if rows else None


def fetch_history(inst, tf, bars):
    rows = _get("/market/candles", {"instId": inst + "-SWAP", "bar": OKX_BAR[tf], "limit": "300"})
    if not rows:
        return None
    allrows = list(rows)
    while len(allrows) < bars:
        oldest = min(int(r[0]) for r in allrows)
        page = _get("/market/history-candles", {"instId": inst + "-SWAP", "bar": OKX_BAR[tf], "after": str(oldest), "limit": "100"})
        if not page:
            break
        allrows.extend(page)
        if len(page) < 100:
            break
    return _to_arrays(allrows)


def top_swaps(n):
    rows = _get("/market/tickers", {"instType": "SWAP"}) or []
    out = []
    for t in rows:
        inst = t.get("instId", "")
        base = inst.split("-")[0]
        if not inst.endswith("-USDT-SWAP") or base in EXCLUDE:
            continue
        try:
            out.append((float(t["volCcy24h"]) * float(t["last"]), base))
        except Exception:
            pass
    out.sort(reverse=True)
    return [f"{b}-USDT" for _, b in out[:n]]


# ---------------------------------------------------------------- indicators (same rules as the app's analyze())
def _ema(a, n):
    return pd.Series(a).ewm(span=n, adjust=False).mean().to_numpy()


def _wilder(a, n):
    return pd.Series(a).ewm(alpha=1 / n, adjust=False).mean().to_numpy()


def _sma(a, n):
    return pd.Series(a).rolling(n).mean().to_numpy()


def _rmax(a, n):
    return pd.Series(a).rolling(n).max().to_numpy()


def _rmin(a, n):
    return pd.Series(a).rolling(n).min().to_numpy()


def _rsum(a, n, minp=None):
    return pd.Series(a).rolling(n, min_periods=minp or n).sum().to_numpy()


def _wma(x, p):
    out = np.full(len(x), np.nan)
    if len(x) >= p:
        w = np.arange(1, p + 1, dtype=float)
        win = np.lib.stride_tricks.sliding_window_view(x, p)
        out[p - 1:] = win @ w / w.sum()
    return out


def _sig(buy, sell, start, valid=None):
    s = np.where(buy, 1.0, np.where(sell, -1.0, 0.0))
    s[:start] = np.nan
    if valid is not None:
        s[~valid] = np.nan
    return s


def compute_votes(d):
    """Returns (votes: name -> array of +1/-1/0/nan per candle, atr array, overall score array)."""
    o, h, l, c, v = d["o"], d["h"], d["l"], d["c"], d["v"]
    n = len(c)
    S = {}
    nan = np.nan
    pc = np.concatenate([[c[0]], c[:-1]])
    tr = np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))
    tr[0] = h[0] - l[0]
    hv = pd.Series(v).rolling(50, min_periods=1).sum().to_numpy() > 0        # has real volume
    tp = (h + l + c) / 3

    with np.errstate(all="ignore"):
        for p in (10, 20, 30, 50, 100, 200):
            S[f"EMA {p}"] = _sig(c > _ema(c, p), c <= _ema(c, p), p - 1)
        for p in (10, 20, 30, 50, 100, 200):
            sm = _sma(c, p)
            S[f"SMA {p}"] = _sig(c > sm, c <= sm, p - 1, ~np.isnan(sm))
        vv = _rsum(v, 50, 1)
        vw = _rsum(tp * v, 50, 1) / vv
        S["VWAP (50)"] = _sig(c > vw, c <= vw, 0, hv & (vv > 0))

        # Supertrend (10,3)
        atr10 = _wilder(tr, 10)
        fu = fl = 0.0
        dirv, st = 1, np.ones(n)
        for i in range(n):
            hl2 = (h[i] + l[i]) / 2
            ub, lb = hl2 + 3 * atr10[i], hl2 - 3 * atr10[i]
            if i == 0:
                fu, fl = ub, lb
                st[i] = dirv
                continue
            pfu, pfl = fu, fl
            fu = ub if (ub < pfu or c[i - 1] > pfu) else pfu
            fl = lb if (lb > pfl or c[i - 1] < pfl) else pfl
            if dirv == 1 and c[i] < fl:
                dirv = -1
            elif dirv == -1 and c[i] > fu:
                dirv = 1
            st[i] = dirv
        S["Supertrend (10,3)"] = _sig(st == 1, st == -1, 0)

        # RSI
        up = np.concatenate([[0.0], np.clip(np.diff(c), 0, None)])
        dn = np.concatenate([[0.0], np.clip(-np.diff(c), 0, None)])
        u, w = _wilder(up, 14), _wilder(dn, 14)
        rsi = np.where(w == 0, 100.0, 100 - 100 / (1 + u / w))
        S["RSI (14)"] = _sig(rsi < 30, rsi > 70, 14)

        # Stochastic (14,3)
        hh14, ll14 = _rmax(h, 14), _rmin(l, 14)
        k = np.where(hh14 == ll14, 50.0, 100 * (c - ll14) / (hh14 - ll14))
        S["Stochastic (14,3)"] = _sig(k < 20, k > 80, 15, ~np.isnan(hh14))

        # CCI (20)
        sm20 = _sma(tp, 20)
        md = np.full(n, nan)
        if n >= 20:
            win = np.lib.stride_tricks.sliding_window_view(tp, 20)
            md[19:] = np.abs(win - win.mean(axis=1, keepdims=True)).mean(axis=1)
        cci = np.where(md == 0, 0.0, (tp - sm20) / (0.015 * md))
        S["CCI (20)"] = _sig(cci < -100, cci > 100, 19, ~np.isnan(md))

        # Williams %R (14)
        wr = np.where(hh14 == ll14, -50.0, -100 * (hh14 - c) / (hh14 - ll14))
        S["Williams %R (14)"] = _sig(wr < -80, wr > -20, 13, ~np.isnan(hh14))

        # MACD
        line = _ema(c, 12) - _ema(c, 26)
        hist = line - _ema(line, 9)
        S["MACD (12,26,9)"] = _sig(hist > 0, hist < 0, 0)

        # Momentum (10), Awesome Oscillator
        mom = c - np.concatenate([np.full(10, nan), c[:-10]]) if n > 10 else np.full(n, nan)
        S["Momentum (10)"] = _sig(mom > 0, mom < 0, 10, ~np.isnan(mom))
        hl2 = (h + l) / 2
        ao = _sma(hl2, 5) - _sma(hl2, 34)
        S["Awesome Oscillator"] = _sig(ao > 0, ao <= 0, 33, ~np.isnan(ao))

        # ADX (14)
        upm = np.concatenate([[0.0], np.diff(h)])
        dnm = np.concatenate([[0.0], -np.diff(l)])
        pdm = np.where((upm > dnm) & (upm > 0), upm, 0.0)
        ndm = np.where((dnm > upm) & (dnm > 0), dnm, 0.0)
        a14, p14, m14 = _wilder(tr, 14), _wilder(pdm, 14), _wilder(ndm, 14)
        pdi = np.where(a14 == 0, 0.0, 100 * p14 / a14)
        ndi = np.where(a14 == 0, 0.0, 100 * m14 / a14)
        ssum = pdi + ndi
        dx = np.where(ssum == 0, 0.0, 100 * np.abs(pdi - ndi) / ssum)
        adx = _wilder(dx, 14)
        adx_valid = adx.copy()
        adx_valid[:29] = nan
        S["ADX (14)"] = _sig((adx > 20) & (pdi > ndi), (adx > 20) & (pdi <= ndi), 29)

        # Bollinger %B (20,2)
        mid = _sma(c, 20)
        sd = pd.Series(c).rolling(20).std(ddof=0).to_numpy()
        bup, blo = mid + 2 * sd, mid - 2 * sd
        pb = np.where(bup == blo, 0.5, (c - blo) / (bup - blo))
        S["Bollinger %B (20,2)"] = _sig(pb < 0.05, pb > 0.95, 19, ~np.isnan(mid))

        # Donchian break (20): highest high and lowest low of the 20 candles before this one
        dh = pd.Series(h).shift(1).rolling(20).max().to_numpy()
        dl = pd.Series(l).shift(1).rolling(20).min().to_numpy()
        S["Donchian break (20)"] = _sig(c > dh, c < dl, 21, ~np.isnan(dh))

        # MFI (14) and OBV vs EMA21
        rawmf = tp * v
        tpd = np.concatenate([[0.0], np.diff(tp)])
        pos = _rsum(np.where(tpd > 0, rawmf, 0.0), 14)
        neg = _rsum(np.where(tpd < 0, rawmf, 0.0), 14)
        mfi = np.where(neg == 0, 100.0, 100 - 100 / (1 + pos / neg))
        S["MFI (14)"] = _sig(mfi < 20, mfi > 80, 15, hv & ~np.isnan(pos))
        dc = np.concatenate([[0.0], np.diff(c)])
        obv = np.cumsum(np.where(dc > 0, v, np.where(dc < 0, -v, 0.0)))
        oe = _ema(obv, 21)
        S["OBV vs EMA21"] = _sig(obv > oe, obv <= oe, 15, hv)

        # Parabolic SAR
        upT, af, ep, sar = True, 0.02, h[0], l[0]
        sar_up = np.ones(n)
        for i in range(1, n):
            sar = sar + af * (ep - sar)
            if upT:
                if l[i] < sar:
                    upT, sar, ep, af = False, ep, l[i], 0.02
                elif h[i] > ep:
                    ep, af = h[i], min(af + 0.02, 0.2)
            else:
                if h[i] > sar:
                    upT, sar, ep, af = True, ep, h[i], 0.02
                elif l[i] < ep:
                    ep, af = l[i], min(af + 0.02, 0.2)
            sar_up[i] = 1 if upT else -1
        S["Parabolic SAR"] = _sig(sar_up == 1, sar_up == -1, 19)

        # Ichimoku (cloud as plotted today = computed 26 candles ago)
        hh9, ll9, hh26, ll26, hh52, ll52 = _rmax(h, 9), _rmin(l, 9), _rmax(h, 26), _rmin(l, 26), _rmax(h, 52), _rmin(l, 52)
        tenkan, kijun = (hh9 + ll9) / 2, (hh26 + ll26) / 2
        sa = pd.Series(((hh9 + ll9) / 2 + (hh26 + ll26) / 2) / 2).shift(26).to_numpy()
        sb = pd.Series((hh52 + ll52) / 2).shift(26).to_numpy()
        top, bot = np.fmax(sa, sb), np.fmin(sa, sb)
        S["Ichimoku"] = _sig((c > top) & (tenkan > kijun), (c < bot) & (tenkan < kijun), 79, ~np.isnan(top))

        # Keltner channel (20,2)
        kmid = _ema(c, 20)
        kup, klo = kmid + 2 * _wilder(tr, 10), kmid - 2 * _wilder(tr, 10)
        S["Keltner channel (20,2)"] = _sig(c > kup, c < klo, 19)

        # Stochastic RSI
        hr, lr = _rmax(rsi, 14), _rmin(rsi, 14)
        raw = np.where(hr == lr, 50.0, 100 * (rsi - lr) / (hr - lr))
        ks = (raw + pd.Series(raw).shift(1).to_numpy() + pd.Series(raw).shift(2).to_numpy()) / 3
        S["Stochastic RSI"] = _sig(ks < 20, ks > 80, 39, ~np.isnan(ks))

        # Ultimate Oscillator
        lo_, hi_ = np.minimum(l, pc), np.maximum(h, pc)
        bp, trr = c - lo_, hi_ - lo_
        def avg_u(p):
            bs, ts = _rsum(bp, p), _rsum(trr, p)
            return np.where(ts == 0, 0.5, bs / ts)
        uo = 100 * (4 * avg_u(7) + 2 * avg_u(14) + avg_u(28)) / 7
        S["Ultimate Oscillator"] = _sig(uo < 30, uo > 70, 29, ~np.isnan(uo))

        # Aroon (25)
        aro = np.full(n, nan)
        if n >= 26:
            wh = np.lib.stride_tricks.sliding_window_view(h, 26)[:, ::-1]
            wl = np.lib.stride_tricks.sliding_window_view(l, 26)[:, ::-1]
            a_up = 100 * (25 - np.argmax(wh, axis=1)) / 25
            a_dn = 100 * (25 - np.argmin(wl, axis=1)) / 25
            aro[25:] = a_up - a_dn
        S["Aroon (25)"] = _sig(aro > 50, aro < -50, 26, ~np.isnan(aro))

        # Elder Ray (13)
        e13 = _ema(c, 13)
        bull, bear = h - e13, l - e13
        pe, pbull, pbear = (pd.Series(x).shift(1).to_numpy() for x in (e13, bull, bear))
        rising = e13 > pe
        S["Elder Ray (13)"] = _sig(rising & (bear < 0) & (bear > pbear), ~rising & (bull > 0) & (bull < pbull), 14)

        # Chaikin Money Flow (20), VWMA (20)
        rg = h - l
        clv = np.where(rg == 0, 0.0, ((c - l) - (h - c)) / np.where(rg == 0, 1, rg))
        vs20 = _rsum(v, 20)
        cmf = np.where(vs20 == 0, 0.0, _rsum(clv * v, 20) / vs20)
        S["Chaikin Money Flow (20)"] = _sig(cmf > 0.05, cmf < -0.05, 19, hv & ~np.isnan(vs20))
        vwma = _rsum(c * v, 20) / vs20
        S["VWMA (20)"] = _sig(c > vwma, c <= vwma, 19, hv & ~np.isnan(vwma) & (vs20 > 0))

        # Hull MA (9)
        hma = _wma(2 * _wma(c, 4) - _wma(c, 9), 3)
        S["Hull MA (9)"] = _sig(c > hma, c <= hma, 11, ~np.isnan(hma))

        # TRIX (15), ROC (12)
        t3 = _ema(_ema(_ema(c, 15), 15), 15)
        tx = (t3 - np.concatenate([[nan], t3[:-1]])) / np.concatenate([[nan], t3[:-1]]) * 100
        S["TRIX (15)"] = _sig(tx > 0, tx < 0, 59, ~np.isnan(tx))
        c12 = pd.Series(c).shift(12).to_numpy()
        roc = (c - c12) / c12 * 100
        S["ROC (12)"] = _sig(roc > 0, roc < 0, 13, ~np.isnan(roc))

        # Vortex (14)
        vmp = np.abs(h - pd.Series(l).shift(1).to_numpy())
        vmm = np.abs(l - pd.Series(h).shift(1).to_numpy())
        trs = _rsum(tr, 14)
        vip = np.where(trs == 0, 1.0, _rsum(vmp, 14) / trs)
        vim = np.where(trs == 0, 1.0, _rsum(vmm, 14) / trs)
        S["Vortex (14)"] = _sig(vip - vim > 0.05, vip - vim < -0.05, 15, ~np.isnan(trs))

        # Squeeze Momentum
        mo = c - ((_rmax(h, 20) + _rmin(l, 20)) / 2 + _sma(c, 20)) / 2
        m0 = pd.Series(mo).shift(1).to_numpy()
        S["Squeeze Momentum"] = _sig((mo > 0) & (mo > m0), (mo < 0) & (mo < m0), 24, ~np.isnan(m0))

        # Heikin-Ashi trend (3 candles)
        hao, hac = (o[0] + c[0]) / 2, (o[0] + h[0] + l[0] + c[0]) / 4
        bullha = np.zeros(n, dtype=bool)
        bullha[0] = hac > hao
        for i in range(1, n):
            nc, no = (o[i] + h[i] + l[i] + c[i]) / 4, (hao + hac) / 2
            hao, hac = no, nc
            bullha[i] = hac > hao
        b1, b2 = np.roll(bullha, 1), np.roll(bullha, 2)
        S["Heikin-Ashi trend"] = _sig(bullha & b1 & b2, ~bullha & ~b1 & ~b2, 9)

        # Chandelier Exit (22,3)
        atr22 = _wilder(tr, 22)
        hh22, ll22 = _rmax(h, 22), _rmin(l, 22)
        lsv, ssv = hh22 - 3 * atr22, ll22 + 3 * atr22
        dirc, pls, pss = 1, nan, nan
        ch = np.ones(n)
        for i in range(21, n):
            if not math.isnan(pss):
                if c[i] > pss:
                    dirc = 1
                elif c[i] < pls:
                    dirc = -1
            pls, pss = lsv[i], ssv[i]
            ch[i] = dirc
        S["Chandelier Exit (22,3)"] = _sig(ch == 1, ch == -1, 39)

        # Linear regression (50)
        r = pd.Series(c).rolling(50).corr(pd.Series(np.arange(n, dtype=float))).to_numpy()
        r = np.where(np.isnan(r), 0.0, r)
        S["Linear regression (50)"] = _sig((r * r > 0.5) & (r > 0), (r * r > 0.5) & (r < 0), 49)

        # ATR and chart-read support / resistance + candle pattern
        atr = _wilder(tr, 14)
        S["Support / Resistance"] = _support_resistance(h, l, c, atr)
        S["Candle pattern"] = _candles(o, h, l, c, atr)

        # overall verdict, regime-aware exactly like the app
        names = list(S)
        M = np.vstack([S[k] for k in names])                  # k x n
        present = ~np.isnan(M)
        sig = np.nan_to_num(M)
        mr = np.array([k in MR for k in names])[:, None]
        wv = np.ones_like(M)
        hi, lo = (adx_valid > 25)[None, :], (adx_valid < 20)[None, :]
        wv = np.where(hi, np.where(mr, 0.5, 1.5), np.where(lo, np.where(mr, 1.3, 0.6), 1.0))
        wsum = (wv * present).sum(axis=0)
        score = np.where(wsum == 0, 0.0, (wv * sig * present).sum(axis=0) / np.where(wsum == 0, 1, wsum))
        side = np.where(score >= .2, 1.0, np.where(score <= -.2, -1.0, 0.0))
        S["OVERALL verdict"] = np.where(side != 0, side, 0.0)
        S["OVERALL strong verdict"] = np.where(np.abs(score) >= .5, side, 0.0)
        for k in ("OVERALL verdict", "OVERALL strong verdict"):
            S[k][:30] = np.nan
    return S, atr, score


def _support_resistance(h, l, c, atr):
    n = len(c)
    out = np.full(n, np.nan)
    ish = np.zeros(n, dtype=bool)
    isl = np.zeros(n, dtype=bool)
    if n < 8:
        return out
    hh = np.ones(n - 6, dtype=bool)
    ll = np.ones(n - 6, dtype=bool)
    mid = slice(3, n - 3)
    for j in range(1, 4):
        hh &= h[mid] > h[3 - j:n - 3 - j]
        hh &= h[mid] > h[3 + j:n - 3 + j]
        ll &= l[mid] < l[3 - j:n - 3 - j]
        ll &= l[mid] < l[3 + j:n - 3 + j]
    ish[3:n - 3], isl[3:n - 3] = hh, ll
    piv_idx = np.where(ish | isl)[0]
    for i in range(30, n):
        if not (atr[i] > 0):
            continue
        start = max(0, i - 299)
        # a pivot needs 3 candles after it, so only pivots up to i-3 exist at candle i
        sel = piv_idx[(piv_idx >= start + 3) & (piv_idx <= i - 3)]
        prices = sorted([h[x] for x in sel if ish[x]] + [l[x] for x in sel if isl[x]])
        last, tol = c[i], atr[i] * 0.5
        lv = []
        for p in prices:
            if lv and abs(p - lv[-1][0]) <= tol:
                k = lv[-1][1]
                lv[-1][0] = (lv[-1][0] * k + p) / (k + 1)
                lv[-1][1] = k + 1
            else:
                lv.append([p, 1])
        strong = [x for x in lv if x[1] >= 2]
        if len(strong) >= 2:
            lv = strong
        sups = [x[0] for x in reversed(lv) if x[0] < last]
        ress = [x[0] for x in lv if x[0] > last]
        ds = (last - sups[0]) / atr[i] if sups else 1e9
        dr = (ress[0] - last) / atr[i] if ress else 1e9
        out[i] = 1.0 if ds <= 0.6 else (-1.0 if dr <= 0.6 else 0.0)
    return out


def _candles(o, h, l, c, atr):
    n = len(c)
    out = np.full(n, np.nan)
    for i in range(3, n):
        body, rg = abs(c[i] - o[i]), h[i] - l[i]
        upw, low_w = h[i] - max(c[i], o[i]), min(c[i], o[i]) - l[i]
        pbody, bigprev = abs(c[i - 1] - o[i - 1]), abs(c[i - 2] - o[i - 2])
        sg = 0.0
        if c[i - 2] < o[i - 2] and bigprev > atr[i] * 0.6 and pbody < bigprev * 0.4 and c[i] > o[i] and c[i] > (c[i - 2] + o[i - 2]) / 2:
            sg = 1.0
        elif c[i - 2] > o[i - 2] and bigprev > atr[i] * 0.6 and pbody < bigprev * 0.4 and c[i] < o[i] and c[i] < (c[i - 2] + o[i - 2]) / 2:
            sg = -1.0
        elif c[i - 1] < o[i - 1] and c[i] > o[i] and c[i] >= o[i - 1] and o[i] <= c[i - 1] and body > pbody:
            sg = 1.0
        elif c[i - 1] > o[i - 1] and c[i] < o[i] and c[i] <= o[i - 1] and o[i] >= c[i - 1] and body > pbody:
            sg = -1.0
        elif rg > 0 and body > 0 and low_w > 2 * body and upw < 0.25 * rg:
            sg = 1.0
        elif rg > 0 and body > 0 and upw > 2 * body and low_w < 0.25 * rg:
            sg = -1.0
        out[i] = sg
    return out


# ---------------------------------------------------------------- scoring
def score_outcomes(d, atr, idx):
    """For candle indexes idx: price move after HORIZON candles in ATR, and the race result (+1 up first, -1 down first, 0 none/both)."""
    c, h, l = d["c"], d["h"], d["l"]
    px, a = c[idx], atr[idx]
    move = (c[idx + HORIZON] - px) / np.where(a > 0, a, np.nan)
    up, dn = px + RACE_ATR * a, px - RACE_ATR * a
    race = np.zeros(len(idx))
    decided = np.zeros(len(idx), dtype=bool)
    for k in range(1, HORIZON + 1):
        hu, hd = h[idx + k] >= up, l[idx + k] <= dn
        new = ~decided & (hu | hd)
        race[new & hu & ~hd] = 1
        race[new & hd & ~hu] = -1
        decided |= new
    return np.nan_to_num(move), race


def empty_row():
    return [0.0] * 8


def add_to_agg(agg, tf, votes, idx, move, race):
    """agg row: [n, directionHits, raceWins, raceLosses, sumSignedMoveAtr, decidedBuys, decidedSells, buyVotes]
    '__BASE__|style' row: [snapshots, upFirst, downFirst, movedUp, 0, 0, 0, 0]"""
    style = STYLE[tf]
    dec = race != 0
    for key in (f"__BASE__|{style}", "__BASE__|All"):
        b = agg.setdefault(key, empty_row())
        b[0] += len(idx)
        b[1] += float((race == 1).sum())
        b[2] += float((race == -1).sum())
        b[3] += float((move > 0).sum())
    for name, arr in votes.items():
        vs = np.nan_to_num(arr[idx])
        for sig in (1.0, -1.0):
            m = vs == sig
            cnt = float(m.sum())
            if cnt == 0:
                continue
            for key in (f"{name}|{style}", f"{name}|All"):
                a = agg.setdefault(key, empty_row())
                a[0] += cnt
                a[1] += float((m & (move * sig > 0)).sum())
                a[2] += float((m & (race == sig)).sum())
                a[3] += float((m & (race == -sig)).sum())
                a[4] += float((move * sig)[m].sum())
                if sig == 1.0:
                    a[5] += float((m & dec).sum())
                    a[7] += cnt
                else:
                    a[6] += float((m & dec).sum())


# ---------------------------------------------------------------- reports
def category_of(n):
    trend = ("EMA", "SMA", "Supertrend", "Parabolic", "Ichimoku", "Hull", "Linear regression", "Heikin", "Chandelier", "Aroon", "Vortex", "ADX", "TRIX")
    vol = ("VWAP", "VWMA", "MFI", "OBV", "Chaikin", "Last closed candle volume")
    brk = ("Bollinger", "Donchian", "Keltner", "Squeeze")
    sr = ("Support", "Fib", "Pivot")
    if n.startswith("OVERALL"):
        return "Overall verdict"
    if n.startswith("Candle pattern"):
        return "Candle patterns"
    if n.startswith(vol):
        return "Volume"
    if n.startswith(brk):
        return "Breakout / volatility"
    if n.startswith(sr):
        return "Support / resistance"
    if n.startswith(trend):
        return "Trend"
    return "Momentum / oscillators"


def lab_m(a, b):
    """Win rate vs the rate a random mix of buys and sells would have had in the same market."""
    if not b:
        return None
    dec = b[1] + b[2]
    decided = a[5] + a[6]
    if dec == 0 or a[0] == 0 or decided == 0:
        return None
    p_up = b[1] / dec
    exp = a[5] * p_up + a[6] * (1 - p_up)
    var = decided * p_up * (1 - p_up)
    p_move = b[3] / b[0]
    dir_exp = a[7] * p_move + (a[0] - a[7]) * (1 - p_move)
    return {"win": 100 * a[2] / decided, "base": 100 * exp / decided, "excess": 100 * (a[2] - exp) / decided,
            "z": (a[2] - exp) / math.sqrt(var) if var > 0 else 0.0, "dir": 100 * a[1] / a[0], "dir_base": 100 * dir_exp / a[0]}


def _cell(x):
    t = str(x)
    return '"' + t.replace('"', '""') + '"' if any(ch in t for ch in ',"\n') else t


def acc_csv(agg):
    lines = ["indicator,category,style,signals,direction_accuracy_pct,direction_expected_pct,race_wins,race_losses,race_win_pct,"
             "race_expected_pct,excess_pts,z_if_independent,avg_move_atr"]
    for k in sorted(x for x in agg if not x.startswith("__BASE__")):
        a = agg[k]
        name, style = k.rsplit("|", 1)
        den = a[2] + a[3]
        m = lab_m(a, agg.get(f"__BASE__|{style}"))
        lines.append(",".join([_cell(name), _cell(category_of(name)), style, str(int(a[0])), f"{100 * a[1] / a[0]:.1f}",
                               f"{m['dir_base']:.1f}" if m else "", str(int(a[2])), str(int(a[3])),
                               f"{100 * a[2] / den:.1f}" if den > 0 else "", f"{m['base']:.1f}" if m else "",
                               f"{m['excess']:.1f}" if m else "", f"{m['z']:.2f}" if m else "", f"{a[4] / a[0]:.3f}"]))
    for k in sorted(x for x in agg if x.startswith("__BASE__")):
        b = agg[k]
        lines.append(f"MARKET (all coins),Market,{k.split('|')[1]},{int(b[0])},{100 * b[3] / b[0]:.1f} up,,{int(b[1])} up first,{int(b[2])} down first,,,,,")
    return "\n".join(lines) + "\n"


def effective_moments(state):
    """Distinct candle closes divided by the horizon. Windows overlap and coins signal together, so neither counts as independent."""
    per_tf = {tf: (hi - lo) // (BAR_MS[tf] // 60000) + 1 for tf, (lo, hi) in state["moments"].items() if tf in BAR_MS}
    out = {st: int(math.ceil(sum(c for tf, c in per_tf.items() if STYLE.get(tf) == st) / HORIZON)) for st in STYLES}
    out["All"] = int(math.ceil(sum(per_tf.values()) / HORIZON))
    return out


# ---------------------------------------------------------------- main
def load_state():
    try:
        s = json.load(open(STATE))
        s.setdefault("marks", {})
        s.setdefault("moments", {})
        s.setdefault("agg", {})
        s.setdefault("scored", 0)
        return s
    except Exception:
        return {"marks": {}, "moments": {}, "agg": {}, "scored": 0}


def merge_rows(new_rows, names):
    cols = ["time_utc", "coin", "tf", "style", "price", "atr", "move_atr", "race"] + names
    old = pd.DataFrame(columns=cols)
    if os.path.exists(ROWS_CSV):
        try:
            old = pd.read_csv(ROWS_CSV)
        except Exception:
            pass
    df = pd.concat([old, pd.DataFrame(new_rows)], ignore_index=True) if new_rows else old
    for n in names:
        if n not in df.columns:
            df[n] = 0
    df = df[cols].fillna(0)
    df = df.sort_values("time_utc").groupby("style", group_keys=False).tail(KEEP_ROWS_PER_STYLE)
    df.to_csv(ROWS_CSV, index=False)


def run():
    started = time.time()
    os.makedirs(DOCS, exist_ok=True)
    state = load_state()
    coins = top_swaps(TOP_N)
    if not coins:
        print("lab: could not load the coin list, nothing done")
        return
    now = int(time.time() * 1000)
    keys = [(c, tf) for c in coins for tf in TFS]
    due = [k for k in keys if f"{k[0]}|{k[1]}" in state["marks"] and now >= state["marks"][f"{k[0]}|{k[1]}"] + (HORIZON + 1) * BAR_MS[k[1]]]
    fresh = [k for k in keys if f"{k[0]}|{k[1]}" not in state["marks"]]
    work = due + fresh
    new_rows, names_seen, done_keys, added = [], set(), 0, 0
    for coin, tf in work:
        if time.time() - started > MAX_SECONDS or _calls > MAX_CALLS:
            break
        key = f"{coin}|{tf}"
        mark = state["marks"].get(key)
        d = fetch_history(coin, tf, BACKFILL[tf]) if mark is None else fetch_latest(coin, tf)
        if d is None or len(d["c"]) < WARMUP + HORIZON + 30:
            continue
        try:
            votes, atr, _ = compute_votes(d)
        except Exception as e:                      # one bad series must not stop the run
            print(f"lab: {key} failed: {e}")
            continue
        t0 = d["ts"] + BAR_MS[tf]                    # moment each candle closed
        last = len(d["c"]) - 1 - HORIZON
        first = WARMUP
        if mark is not None:
            first = max(first, int(np.searchsorted(t0, mark, side="right")))
        if first > last:
            continue
        idx = np.arange(first, last + 1)
        idx = idx[atr[idx] > 0]
        if len(idx) == 0:
            continue
        move, race = score_outcomes(d, atr, idx)
        add_to_agg(state["agg"], tf, votes, idx, move, race)
        tm = t0[idx] // 60000
        lo, hi = int(tm.min()), int(tm.max())
        cur = state["moments"].get(tf)
        state["moments"][tf] = [min(lo, cur[0]), max(hi, cur[1])] if cur else [lo, hi]   # first and last candle close, in minutes
        state["marks"][key] = int(t0[last])
        state["scored"] += len(idx)
        done_keys += 1
        added += len(idx)
        names_seen.update(votes)
        # keep only the newest candles per pair as raw rows, the merge trims per style
        per_key = max(5, KEEP_ROWS_PER_STYLE // max(1, len(coins)))
        for j, m, r in zip(idx[-per_key:], move[-per_key:], race[-per_key:]):
            row = {"time_utc": pd.Timestamp(int(t0[j]), unit="ms", tz="UTC").strftime("%Y-%m-%dT%H:%M:%SZ"), "coin": coin.split("-")[0],
                   "tf": tf, "style": STYLE[tf], "price": float(d["c"][j]), "atr": float(atr[j]), "move_atr": round(float(m), 3), "race": int(r)}
            for nme, arr in votes.items():
                v = arr[j]
                row[nme] = 0 if np.isnan(v) else int(v)
            new_rows.append(row)
    names = sorted(names_seen or {k.rsplit("|", 1)[0] for k in state["agg"] if not k.startswith("__BASE__")})
    if new_rows:
        merge_rows(new_rows, names)
    done_pairs = sum(1 for c, t in keys if f"{c}|{t}" in state["marks"])
    mom = effective_moments(state)
    status = (f"Server run {pd.Timestamp.now(tz='UTC').strftime('%Y-%m-%d %H:%M')} UTC: {added} new scored signal sets, "
              f"{done_pairs} of {len(keys)} coin/timeframe pairs started, {state['scored']} scored in total.")
    json.dump(state, open(STATE, "w"), separators=(",", ":"))
    json.dump({"updated": pd.Timestamp.now(tz="UTC").isoformat(), "status": status, "horizon": HORIZON, "race_atr": RACE_ATR,
               "coins": [c.split("-")[0] for c in coins], "tfs": TFS, "scored": state["scored"], "pairs_done": done_pairs,
               "pairs_total": len(keys), "moments": mom, "agg": state["agg"]}, open(SUMMARY, "w"), separators=(",", ":"))
    open(ACC_CSV, "w").write(acc_csv(state["agg"]))
    print(status)


if __name__ == "__main__":
    try:
        run()
    except Exception as e:                           # never fail the signal bot because of the lab
        print(f"lab: stopped with error: {e}")
        sys.exit(0)
