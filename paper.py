"""Paper trading: every alert becomes a virtual trade so you can see which strategies actually pay."""
import json
import pandas as pd
from config import PAPER_START, PAPER_RISK

FILE = "paper.json"
COST_R = 0.05

def load():
    try:
        return json.load(open(FILE))
    except Exception:
        return {"equity": PAPER_START, "open": [], "closed": []}

def save(p):
    p["closed"] = p["closed"][-1000:]
    json.dump(p, open(FILE, "w"))

def open_pos(p, symbol, s):
    if any(o["symbol"] == symbol and o["strategy"] == s["strategy"] for o in p["open"]):
        return
    risk = abs(s["entry"] - s["sl"])
    if not risk > 0:
        return
    risk_cash = p["equity"] * PAPER_RISK
    p["open"].append({"symbol": symbol, "strategy": s["strategy"], "side": s["side"], "entry": s["entry"],
                      "sl": s["sl"], "tp": s["tp"], "units": risk_cash / risk, "risk": risk_cash,
                      "opened": pd.Timestamp.now(tz="UTC").isoformat(), "hold_h": s.get("hold_h", 72)})

def update(p, rows_by_symbol):
    """Close positions that hit SL/TP on 15m candles since entry, or timed out. Same-candle hits count as SL."""
    still, now = [], pd.Timestamp.now(tz="UTC")
    for o in p["open"]:
        R, t0, exit_px = rows_by_symbol.get(o["symbol"]) or [], pd.Timestamp(o["opened"]), None
        for x in R:
            if pd.Timestamp(x.Index) <= t0:
                continue
            hit_sl = x.low <= o["sl"] if o["side"] == 1 else x.high >= o["sl"]
            hit_tp = x.high >= o["tp"] if o["side"] == 1 else x.low <= o["tp"]
            if hit_sl:
                exit_px = o["sl"]
                break
            if hit_tp:
                exit_px = o["tp"]
                break
        if exit_px is None and now - t0 > pd.Timedelta(hours=o["hold_h"]) and R:
            exit_px = R[-1].close
        if exit_px is None:
            still.append(o)
            continue
        pnl = (exit_px - o["entry"]) * o["side"] * o["units"] - COST_R * o["risk"]
        p["equity"] += pnl
        p["closed"].append({"strategy": o["strategy"], "symbol": o["symbol"], "pnl": pnl, "r": pnl / o["risk"],
                            "closed": now.isoformat()})
    p["open"] = still

def report(p):
    c = p["closed"]
    lines = [f"💼 <b>Paper account</b>: ${p['equity']:,.0f} ({(p['equity'] / PAPER_START - 1) * 100:+.1f}%), "
             f"{len(p['open'])} open, {len(c)} closed"]
    by = {}
    for t in c:
        by.setdefault(t["strategy"], []).append(t["r"])
    for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        lines.append(f"• {k}: {len(v)} trades, {100 * sum(r > 0 for r in v) / len(v):.0f}% wins, {sum(v):+.1f}R")
    return "\n".join(lines)

def summary(p):
    by = {}
    for t in p["closed"]:
        by.setdefault(t["strategy"], []).append(t["r"])
    return {"equity": round(p["equity"], 2), "start": PAPER_START, "open": len(p["open"]), "closed": len(p["closed"]),
            "strategies": [{"name": k, "trades": len(v), "win": round(100 * sum(r > 0 for r in v) / len(v)), "r": round(sum(v), 1)}
                           for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1]))]}
