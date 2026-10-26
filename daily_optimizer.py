"""Daily strategy/indicator performance optimizer.

Runs the same backtest engine used by backtest.py, stores a dated snapshot,
and automatically selects the strongest strategies for live signal grading.
It deliberately uses multiple metrics rather than win-rate alone.
"""
import csv
import json
import os
from datetime import datetime, timezone

import numpy as np

from config import WATCHLIST, BACKTEST_PERIOD, BAR_MIN
from main import load_rows
from strategies import REGISTRY
from backtest import run_strategy, stats
import telegram

STATE_FILE = "strategy_state.json"
HISTORY_FILE = "strategy_performance.csv"
MIN_TRADES = 30
MIN_ACTIVE = 2
MAX_ACTIVE = 8


def score(m):
    """Risk-aware score; higher is better."""
    if m.get("trades", 0) < MIN_TRADES:
        return -999.0
    pf = m.get("PF")
    if pf is None:
        return -999.0
    # Reward positive expectancy and PF, prefer higher win rate, penalize DD.
    return round(
        2.0 * max(m.get("avgR", 0.0), -2.0)
        + 0.8 * min(max(pf - 1.0, -1.0), 3.0)
        + 0.008 * m.get("win%", 0.0)
        - 0.015 * m.get("maxDD_R", 0.0), 4
    )


def append_history(rows):
    exists = os.path.exists(HISTORY_FILE)
    fields = ["date", "strategy", "timeframe", "trades", "win_pct", "profit_factor", "avg_r", "total_r", "max_dd_r", "score"]
    with open(HISTORY_FILE, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        if not exists:
            w.writeheader()
        w.writerows(rows)


def main():
    today = datetime.now(timezone.utc).date().isoformat()
    agg = {}
    errors = []

    for name, tf, fn, _, hold, _style in REGISTRY:
        key = (name, tf)
        agg[key] = []
        for sym in WATCHLIST:
            try:
                R = load_rows(sym, tf, BACKTEST_PERIOD[tf])
                if R:
                    warm = 210 if tf == "1d" else 250
                    agg[key].extend(run_strategy(R, fn, int(hold * 60 / BAR_MIN[tf]), warm))
            except Exception as e:
                errors.append(f"{sym} {name}: {e}")

    results = []
    for (name, tf), rs in agg.items():
        m = stats(rs)
        m["score"] = score(m)
        results.append({"strategy": name, "timeframe": tf, **m})

    eligible = [r for r in results if r["score"] > -900 and r.get("avgR", 0) > 0 and (r.get("PF") or 0) > 1.0]
    eligible.sort(key=lambda r: (r["score"], r.get("PF") or 0, r.get("win%", 0)), reverse=True)

    # Keep a diversified set: strongest strategies, not only one timeframe.
    active = []
    seen_tf = set()
    for r in eligible:
        if len(active) >= MAX_ACTIVE:
            break
        if r["timeframe"] not in seen_tf or len(active) < MIN_ACTIVE:
            active.append(r)
            seen_tf.add(r["timeframe"])
    if len(active) < MIN_ACTIVE:
        active = eligible[:MAX_ACTIVE]

    state = {
        "updated_utc": datetime.now(timezone.utc).isoformat(),
        "min_trades": MIN_TRADES,
        "active": [r["strategy"] for r in active],
        "active_details": active,
        "all_results": sorted(results, key=lambda r: r["score"], reverse=True),
    }
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

    hist_rows = []
    for r in results:
        hist_rows.append({
            "date": today, "strategy": r["strategy"], "timeframe": r["timeframe"],
            "trades": r.get("trades", 0), "win_pct": r.get("win%", ""),
            "profit_factor": r.get("PF", ""), "avg_r": r.get("avgR", ""),
            "total_r": r.get("totalR", ""), "max_dd_r": r.get("maxDD_R", ""),
            "score": r.get("score", ""),
        })
    append_history(hist_rows)

    lines = ["📊 <b>Daily Strategy Accuracy Update</b>", f"UTC date: {today}", ""]
    if active:
        lines.append("<b>🏆 Active best strategies</b>")
        for r in active:
            lines.append(f"• <b>{r['strategy']}</b> ({r['timeframe']}) — Win {r.get('win%', 0):.1f}% | PF {r.get('PF', 0):.2f} | Avg R {r.get('avgR', 0):+.3f} | Trades {r.get('trades', 0)}")
    else:
        lines.append("⚠️ No strategy met the minimum profitability criteria today; live strategy selection is unchanged/empty.")

    lines.append("\n<b>Top 5 by risk-adjusted score</b>")
    for r in sorted(results, key=lambda x: x["score"], reverse=True)[:5]:
        lines.append(f"• {r['strategy']} {r['timeframe']} — Win {r.get('win%', 0):.1f}% | PF {r.get('PF') or 0:.2f} | AvgR {r.get('avgR', 0):+.3f} | DD {r.get('maxDD_R', 0):.1f}R | N={r.get('trades', 0)}")
    if errors:
        lines.append(f"\n⚠️ Data errors: {len(errors)}")
    telegram.send("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
