import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:math' as math;

const feedUrl = String.fromEnvironment('FEED_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SignalApp());
}

double num0(dynamic v) => (v as num?)?.toDouble() ?? 0;

// Binance USDT-M perpetual futures: base coin -> contract symbol (filled from exchangeInfo, e.g. 'PEPE' -> '1000PEPEUSDT')
final Map<String, String> futSymbols = {};
const favorites = ['BTC', 'ETH', 'SOL', 'BNB', 'XRP', 'DOGE', 'GOLD', 'SILVER', 'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD', 'USDCAD', 'OIL'];
const yahooPairs = {
  'GOLD': 'GC=F', 'SILVER': 'XAGUSD=X', 'EURUSD': 'EURUSD=X', 'GBPUSD': 'GBPUSD=X',
  'USDJPY': 'USDJPY=X', 'AUDUSD': 'AUDUSD=X', 'USDCAD': 'USDCAD=X', 'OIL': 'CL=F',
};
const yahooTf = {
  '1m': ['1m', '5d'], '5m': ['5m', '5d'], '15m': ['15m', '1mo'], '30m': ['30m', '1mo'],
  '1h': ['60m', '3mo'], '4h': ['60m', '6mo'], '1d': ['1d', '2y'],
};
const tfList = ['1m', '5m', '15m', '30m', '1h', '4h', '1d'];
const mtfList = ['5m', '15m', '30m', '1h', '4h', '1d'];
const fxPairs = {'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD', 'USDCAD'};
int decimalsFor(String sym, double price) {
  if (yahooPairs.containsKey(sym)) return decimals(sym);
  if (price >= 1000) return 2;
  if (price >= 10) return 3;
  if (price >= 1) return 4;
  if (price >= 0.1) return 5;
  if (price >= 0.01) return 6;
  return 8;
}

String fmtPrice(double p) => p.toStringAsFixed(decimalsFor('', p));

int decimals(String sym) => sym == 'USDJPY' ? 3 : fxPairs.contains(sym) ? 5 : sym == 'SILVER' ? 3 : 2;

String fmt(dynamic v) {
  final x = num0(v);
  return x > 50 ? x.toStringAsFixed(2) : x >= 0.1 ? x.toStringAsFixed(5) : x.toStringAsFixed(8);
}

String ago(dynamic iso) {
  final t = DateTime.tryParse('$iso')?.toLocal();
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}


class ScanRow {
  final String coin;
  final double price, change, volume;
  final Analysis a;
  ScanRow(this.coin, this.price, this.change, this.volume, this.a);
}

class Reading {
  final String name, value;
  final int sig; // 1 buy, -1 sell, 0 neutral
  final bool mr; // mean-reversion oscillator (trusted more in ranges, less in strong trends)
  const Reading(this.name, this.value, this.sig, [this.mr = false]);
}

class Analysis {
  final List<Reading> ma, osc, info;
  final int buys, sells, neutrals;
  final double last, atr, adx, score;
  final List<double> sup, res;   // nearest support / resistance levels found on the chart (nearest first)
  Analysis(this.ma, this.osc, this.info, this.buys, this.sells, this.neutrals, this.last, this.atr, this.adx, this.score, this.sup, this.res);
  int get total => buys + sells + neutrals;
  int get side => score >= .2 ? 1 : score <= -.2 ? -1 : 0;
  String get verdict => score >= .5 ? 'STRONG BUY' : score >= .2 ? 'BUY' : score <= -.5 ? 'STRONG SELL' : score <= -.2 ? 'SELL' : 'NEUTRAL';
}

List<double> emaSeries(List<double> v, int n) {
  if (v.isEmpty) return <double>[];
  final k = 2 / (n + 1);
  final out = <double>[v[0]];
  for (var i = 1; i < v.length; i++) {
    out.add(v[i] * k + out[i - 1] * (1 - k));
  }
  return out;
}

List<double> wilder(List<double> v, int n) {
  if (v.isEmpty) return <double>[];
  final out = <double>[v[0]];
  for (var i = 1; i < v.length; i++) {
    out.add(out[i - 1] + (v[i] - out[i - 1]) / n);
  }
  return out;
}

double smaLast(List<double> v, int n) {
  if (v.length < n) return double.nan;
  var s = 0.0;
  for (var i = v.length - n; i < v.length; i++) {
    s += v[i];
  }
  return s / n;
}

List<double> trSeries(List<double> h, List<double> l, List<double> c) {
  final out = <double>[h[0] - l[0]];
  for (var i = 1; i < c.length; i++) {
    out.add(math.max(h[i] - l[i], math.max((h[i] - c[i - 1]).abs(), (l[i] - c[i - 1]).abs())));
  }
  return out;
}

double rsiLast(List<double> c, int n) {
  if (c.length <= n) return double.nan;
  final up = <double>[0], dn = <double>[0];
  for (var i = 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    up.add(d > 0 ? d : 0);
    dn.add(d < 0 ? -d : 0);
  }
  final u = wilder(up, n).last, dd = wilder(dn, n).last;
  return dd == 0 ? 100 : 100 - 100 / (1 + u / dd);
}

// Swing-high / swing-low clustering: returns [price, touches] pairs, ascending by price.
List<List<double>> srLevels(List<double> h, List<double> l, double last, double atr) {
  final n = h.length;
  final piv = <double>[];
  for (var i = 3; i < n - 3; i++) {
    var isH = true, isL = true;
    for (var j = 1; j <= 3; j++) {
      if (h[i] <= h[i - j] || h[i] <= h[i + j]) isH = false;
      if (l[i] >= l[i - j] || l[i] >= l[i + j]) isL = false;
    }
    if (isH) piv.add(h[i]);
    if (isL) piv.add(l[i]);
  }
  piv.sort();
  final tol = atr.isNaN || atr <= 0 ? last * 0.002 : atr * 0.5;
  final lv = <List<double>>[];
  for (final p in piv) {
    if (lv.isNotEmpty && (p - lv.last[0]).abs() <= tol) {
      final k = lv.last[1];
      lv.last[0] = (lv.last[0] * k + p) / (k + 1);
      lv.last[1] = k + 1;
    } else {
      lv.add([p, 1.0]);
    }
  }
  return lv;
}

double wmaAt(List<double> v, int end, int p) {
  var acc = 0.0, den = 0.0;
  for (var k = 0; k < p; k++) {
    final w = (p - k).toDouble();
    acc += w * v[end - k];
    den += w;
  }
  return acc / den;
}

List<double> rsiSeries(List<double> c, int n) {
  final up = <double>[0], dn = <double>[0];
  for (var i = 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    up.add(d > 0 ? d : 0);
    dn.add(d < 0 ? -d : 0);
  }
  final u = wilder(up, n), w = wilder(dn, n);
  return [for (var i = 0; i < c.length; i++) w[i] == 0 ? 100.0 : 100 - 100 / (1 + u[i] / w[i])];
}

List<double> adxCalc(List<double> h, List<double> l, List<double> c, int n) {
  final tr = trSeries(h, l, c);
  final pdm = <double>[0], ndm = <double>[0];
  for (var i = 1; i < c.length; i++) {
    final up = h[i] - h[i - 1], dn = l[i - 1] - l[i];
    pdm.add(up > dn && up > 0 ? up : 0);
    ndm.add(dn > up && dn > 0 ? dn : 0);
  }
  final a = wilder(tr, n), p = wilder(pdm, n), m = wilder(ndm, n);
  final dx = <double>[];
  var pdiL = 0.0, ndiL = 0.0;
  for (var i = 0; i < c.length; i++) {
    final pdi = a[i] == 0 ? 0.0 : 100 * p[i] / a[i];
    final ndi = a[i] == 0 ? 0.0 : 100 * m[i] / a[i];
    final sum = pdi + ndi;
    dx.add(sum == 0 ? 0.0 : 100 * (pdi - ndi).abs() / sum);
    pdiL = pdi;
    ndiL = ndi;
  }
  return [wilder(dx, n).last, pdiL, ndiL];
}

int supertrendDir(List<double> h, List<double> l, List<double> c) {
  final atr = wilder(trSeries(h, l, c), 10);
  var fu = 0.0, fl = 0.0, dir = 1;
  for (var i = 0; i < c.length; i++) {
    final hl2 = (h[i] + l[i]) / 2;
    final ub = hl2 + 3 * atr[i], lb = hl2 - 3 * atr[i];
    if (i == 0) {
      fu = ub;
      fl = lb;
      continue;
    }
    final pfu = fu, pfl = fl;
    fu = (ub < pfu || c[i - 1] > pfu) ? ub : pfu;
    fl = (lb > pfl || c[i - 1] < pfl) ? lb : pfl;
    if (dir == 1 && c[i] < fl) {
      dir = -1;
    } else if (dir == -1 && c[i] > fu) {
      dir = 1;
    }
  }
  return dir;
}

Analysis analyze(List<Candle> cs, int d) {
  String f(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(d);
  String f1(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(1);
  final n = cs.length;
  final c = cs.map((x) => x.close).toList();
  final h = cs.map((x) => x.high).toList();
  final l = cs.map((x) => x.low).toList();
  final v = cs.map((x) => x.volume).toList();
  final last = c.last;
  final hasVol = v.skip(math.max(0, n - 50)).fold<double>(0, (a, b) => a + b) > 0;
  final ma = <Reading>[], osc = <Reading>[], info = <Reading>[];
  var adxV = double.nan;

  // ---- trend / moving averages
  for (final p in [10, 20, 30, 50, 100, 200]) {
    if (n >= p) {
      final e = emaSeries(c, p).last;
      ma.add(Reading('EMA $p', f(e), last > e ? 1 : -1));
    }
  }
  for (final p in [10, 20, 30, 50, 100, 200]) {
    final sm = smaLast(c, p);
    if (!sm.isNaN) ma.add(Reading('SMA $p', f(sm), last > sm ? 1 : -1));
  }
  if (hasVol) {
    var pv = 0.0, vv = 0.0;
    for (var i = math.max(0, n - 50); i < n; i++) {
      pv += (h[i] + l[i] + c[i]) / 3 * v[i];
      vv += v[i];
    }
    final vw = pv / vv;
    ma.add(Reading('VWAP (50)', f(vw), last > vw ? 1 : -1));
  }
  final st = supertrendDir(h, l, c);
  ma.add(Reading('Supertrend (10,3)', st == 1 ? 'Uptrend' : 'Downtrend', st));

  // ---- oscillators
  final rsi = rsiLast(c, 14);
  osc.add(Reading('RSI (14)', f1(rsi), rsi < 30 ? 1 : rsi > 70 ? -1 : 0, true));

  double kAt(int i) {
    var hh = -1e300, ll = 1e300;
    for (var j = i - 13; j <= i; j++) {
      if (h[j] > hh) hh = h[j];
      if (l[j] < ll) ll = l[j];
    }
    return hh == ll ? 50 : 100 * (c[i] - ll) / (hh - ll);
  }
  if (n >= 16) {
    final k = kAt(n - 1), dd = (kAt(n - 1) + kAt(n - 2) + kAt(n - 3)) / 3;
    osc.add(Reading('Stochastic (14,3)', 'K ${f1(k)} / D ${f1(dd)}', k < 20 ? 1 : k > 80 ? -1 : 0, true));
  }
  if (n >= 20) {
    final tp = <double>[for (var i = 0; i < n; i++) (h[i] + l[i] + c[i]) / 3];
    final sm = smaLast(tp, 20);
    var md = 0.0;
    for (var i = n - 20; i < n; i++) {
      md += (tp[i] - sm).abs();
    }
    md /= 20;
    final cci = md == 0 ? 0.0 : (tp.last - sm) / (0.015 * md);
    osc.add(Reading('CCI (20)', f1(cci), cci < -100 ? 1 : cci > 100 ? -1 : 0, true));
  }
  if (n >= 14) {
    var hh = -1e300, ll = 1e300;
    for (var j = n - 14; j < n; j++) {
      if (h[j] > hh) hh = h[j];
      if (l[j] < ll) ll = l[j];
    }
    final wr = hh == ll ? -50.0 : -100 * (hh - last) / (hh - ll);
    osc.add(Reading('Williams %R (14)', f1(wr), wr < -80 ? 1 : wr > -20 ? -1 : 0, true));
  }
  final e12 = emaSeries(c, 12), e26 = emaSeries(c, 26);
  final macdLine = <double>[for (var i = 0; i < n; i++) e12[i] - e26[i]];
  final macdSig = emaSeries(macdLine, 9);
  final hist = macdLine.last - macdSig.last;
  osc.add(Reading('MACD (12,26,9)', '${f(macdLine.last)} / ${f(macdSig.last)}', hist > 0 ? 1 : hist < 0 ? -1 : 0));
  if (n > 10) {
    final mom = last - c[n - 11];
    osc.add(Reading('Momentum (10)', f(mom), mom > 0 ? 1 : mom < 0 ? -1 : 0));
  }
  if (n >= 34) {
    final hl2 = <double>[for (var i = 0; i < n; i++) (h[i] + l[i]) / 2];
    final ao = smaLast(hl2, 5) - smaLast(hl2, 34);
    osc.add(Reading('Awesome Oscillator', f(ao), ao > 0 ? 1 : -1));
  }
  if (n >= 30) {
    final ax = adxCalc(h, l, c, 14);
    adxV = ax[0];
    osc.add(Reading('ADX (14)', '${f1(ax[0])}  +DI ${f1(ax[1])} / -DI ${f1(ax[2])}', ax[0] > 20 ? (ax[1] > ax[2] ? 1 : -1) : 0));
  }
  if (n >= 20) {
    final mid = smaLast(c, 20);
    var varc = 0.0;
    for (var i = n - 20; i < n; i++) {
      varc += math.pow(c[i] - mid, 2).toDouble();
    }
    final sd = math.sqrt(varc / 20);
    final up = mid + 2 * sd, lo = mid - 2 * sd;
    final pb = up == lo ? 0.5 : (last - lo) / (up - lo);
    osc.add(Reading('Bollinger %B (20,2)', pb.toStringAsFixed(2), pb < 0.05 ? 1 : pb > 0.95 ? -1 : 0, true));
    info.add(Reading('Bollinger bands', '${f(up)} / ${f(mid)} / ${f(lo)}', 0));
  }
  if (n > 21) {
    var hh = -1e300, ll = 1e300;
    for (var j = n - 21; j <= n - 2; j++) {
      if (h[j] > hh) hh = h[j];
      if (l[j] < ll) ll = l[j];
    }
    osc.add(Reading('Donchian break (20)', last > hh ? 'Broke high' : last < ll ? 'Broke low' : 'Inside range', last > hh ? 1 : last < ll ? -1 : 0));
  }
  if (hasVol && n > 15) {
    final tp = <double>[for (var i = 0; i < n; i++) (h[i] + l[i] + c[i]) / 3];
    var pos = 0.0, neg = 0.0;
    for (var i = n - 14; i < n; i++) {
      final raw = tp[i] * v[i];
      if (tp[i] > tp[i - 1]) {
        pos += raw;
      } else if (tp[i] < tp[i - 1]) {
        neg += raw;
      }
    }
    final mfi = neg == 0 ? 100.0 : 100 - 100 / (1 + pos / neg);
    osc.add(Reading('MFI (14)', f1(mfi), mfi < 20 ? 1 : mfi > 80 ? -1 : 0, true));
    final obv = <double>[0];
    for (var i = 1; i < n; i++) {
      obv.add(obv[i - 1] + (c[i] > c[i - 1] ? v[i] : c[i] < c[i - 1] ? -v[i] : 0));
    }
    final oe = emaSeries(obv, 21).last;
    osc.add(Reading('OBV vs EMA21', obv.last > oe ? 'Rising' : 'Falling', obv.last > oe ? 1 : -1));
  }

  // ---- extra indicators
  if (n >= 20) {
    var upT = true, af = 0.02, ep = h[0], sar = l[0];
    for (var i = 1; i < n; i++) {
      sar = sar + af * (ep - sar);
      if (upT) {
        if (l[i] < sar) {
          upT = false;
          sar = ep;
          ep = l[i];
          af = 0.02;
        } else if (h[i] > ep) {
          ep = h[i];
          af = math.min(af + 0.02, 0.2);
        }
      } else {
        if (h[i] > sar) {
          upT = true;
          sar = ep;
          ep = h[i];
          af = 0.02;
        } else if (l[i] < ep) {
          ep = l[i];
          af = math.min(af + 0.02, 0.2);
        }
      }
    }
    ma.add(Reading('Parabolic SAR', f(sar), upT ? 1 : -1));
  }
  if (n >= 80) {
    double hhOf(int from, int to) {
      var m = -1e300;
      for (var j = from; j <= to; j++) {
        if (h[j] > m) m = h[j];
      }
      return m;
    }
    double llOf(int from, int to) {
      var m = 1e300;
      for (var j = from; j <= to; j++) {
        if (l[j] < m) m = l[j];
      }
      return m;
    }
    final tenkan = (hhOf(n - 9, n - 1) + llOf(n - 9, n - 1)) / 2;
    final kijun = (hhOf(n - 26, n - 1) + llOf(n - 26, n - 1)) / 2;
    final e = n - 27; // the cloud shown today was computed 26 bars ago
    final sa = ((hhOf(e - 8, e) + llOf(e - 8, e)) / 2 + (hhOf(e - 25, e) + llOf(e - 25, e)) / 2) / 2;
    final sb = (hhOf(e - 51, e) + llOf(e - 51, e)) / 2;
    final cloudTop = math.max(sa, sb), cloudBot = math.min(sa, sb);
    final sg = last > cloudTop && tenkan > kijun ? 1 : last < cloudBot && tenkan < kijun ? -1 : 0;
    ma.add(Reading('Ichimoku', last > cloudTop ? 'Above cloud' : last < cloudBot ? 'Below cloud' : 'Inside cloud', sg));
  }
  if (n >= 20) {
    final kMid = emaSeries(c, 20).last;
    final a10 = wilder(trSeries(h, l, c), 10).last;
    final kUp = kMid + 2 * a10, kLo = kMid - 2 * a10;
    osc.add(Reading('Keltner channel (20,2)', last > kUp ? 'Above upper' : last < kLo ? 'Below lower' : 'Inside', last > kUp ? 1 : last < kLo ? -1 : 0));
  }
  if (n >= 40) {
    final rs = rsiSeries(c, 14);
    final raw = <double>[];
    for (var i = 27; i < n; i++) {
      var hh = -1e300, ll = 1e300;
      for (var j = i - 13; j <= i; j++) {
        if (rs[j] > hh) hh = rs[j];
        if (rs[j] < ll) ll = rs[j];
      }
      raw.add(hh == ll ? 50.0 : 100 * (rs[i] - ll) / (hh - ll));
    }
    final k = (raw[raw.length - 1] + raw[raw.length - 2] + raw[raw.length - 3]) / 3;
    osc.add(Reading('Stochastic RSI', f1(k), k < 20 ? 1 : k > 80 ? -1 : 0, true));
  }
  if (n >= 30) {
    double avgU(int p) {
      var bp = 0.0, tr = 0.0;
      for (var i = n - p; i < n; i++) {
        final lo = math.min(l[i], c[i - 1]), hi = math.max(h[i], c[i - 1]);
        bp += c[i] - lo;
        tr += hi - lo;
      }
      return tr == 0 ? 0.5 : bp / tr;
    }
    final uo = 100 * (4 * avgU(7) + 2 * avgU(14) + avgU(28)) / 7;
    osc.add(Reading('Ultimate Oscillator', f1(uo), uo < 30 ? 1 : uo > 70 ? -1 : 0, true));
  }
  if (n > 26) {
    var hi = n - 26, lo = n - 26;
    for (var j = n - 26; j < n; j++) {
      if (h[j] >= h[hi]) hi = j;
      if (l[j] <= l[lo]) lo = j;
    }
    final aUp = 100 * (25 - (n - 1 - hi)) / 25, aDn = 100 * (25 - (n - 1 - lo)) / 25;
    final ao = aUp - aDn;
    osc.add(Reading('Aroon (25)', 'Up ${f1(aUp)} / Down ${f1(aDn)}', ao > 50 ? 1 : ao < -50 ? -1 : 0));
  }
  if (n > 14) {
    final e13 = emaSeries(c, 13);
    final bull = h[n - 1] - e13[n - 1], bear = l[n - 1] - e13[n - 1];
    final pBull = h[n - 2] - e13[n - 2], pBear = l[n - 2] - e13[n - 2];
    final rising = e13[n - 1] > e13[n - 2];
    final sg = rising && bear < 0 && bear > pBear ? 1 : !rising && bull > 0 && bull < pBull ? -1 : 0;
    osc.add(Reading('Elder Ray (13)', 'Bull ${f(bull)} / Bear ${f(bear)}', sg));
  }
  if (hasVol && n >= 20) {
    var mfv = 0.0, vs = 0.0;
    for (var i = n - 20; i < n; i++) {
      final rg = h[i] - l[i];
      final clv = rg == 0 ? 0.0 : ((c[i] - l[i]) - (h[i] - c[i])) / rg;
      mfv += clv * v[i];
      vs += v[i];
    }
    final cmf = vs == 0 ? 0.0 : mfv / vs;
    osc.add(Reading('Chaikin Money Flow (20)', cmf.toStringAsFixed(2), cmf > 0.05 ? 1 : cmf < -0.05 ? -1 : 0));
  }

  // ---- more TradingView-style indicators
  if (hasVol && n >= 20) {
    var pv = 0.0, vv = 0.0;
    for (var i = n - 20; i < n; i++) {
      pv += c[i] * v[i];
      vv += v[i];
    }
    final vw = pv / vv;
    ma.add(Reading('VWMA (20)', f(vw), last > vw ? 1 : -1));
  }
  if (hasVol && n >= 23) {
    var sv = 0.0;
    for (var i = n - 22; i <= n - 3; i++) {
      sv += v[i];
    }
    final avgV = sv / 20;
    if (avgV > 0) info.add(Reading('Last closed candle volume', '${(v[n - 2] / avgV).toStringAsFixed(2)}x average', 0));
  }
  if (n >= 12) {
    final dd = <double>[for (var i = n - 3; i < n; i++) 2 * wmaAt(c, i, 4) - wmaAt(c, i, 9)];
    final hma = wmaAt(dd, 2, 3);
    ma.add(Reading('Hull MA (9)', f(hma), last > hma ? 1 : -1));
  }
  if (n >= 60) {
    final t3 = emaSeries(emaSeries(emaSeries(c, 15), 15), 15);
    final tx = (t3[n - 1] - t3[n - 2]) / t3[n - 2] * 100;
    osc.add(Reading('TRIX (15)', tx.toStringAsFixed(4), tx > 0 ? 1 : tx < 0 ? -1 : 0));
  }
  if (n > 13) {
    final roc = (last - c[n - 13]) / c[n - 13] * 100;
    osc.add(Reading('ROC (12)', '${roc.toStringAsFixed(2)}%', roc > 0 ? 1 : roc < 0 ? -1 : 0));
  }
  if (n > 15) {
    var vmp = 0.0, vmm = 0.0, trs = 0.0;
    for (var i = n - 14; i < n; i++) {
      vmp += (h[i] - l[i - 1]).abs();
      vmm += (l[i] - h[i - 1]).abs();
      trs += math.max(h[i] - l[i], math.max((h[i] - c[i - 1]).abs(), (l[i] - c[i - 1]).abs()));
    }
    final viP = trs == 0 ? 1.0 : vmp / trs, viM = trs == 0 ? 1.0 : vmm / trs;
    osc.add(Reading('Vortex (14)', '+${viP.toStringAsFixed(2)} / -${viM.toStringAsFixed(2)}', viP - viM > 0.05 ? 1 : viP - viM < -0.05 ? -1 : 0));
  }
  if (n >= 25) {
    double hMax(int e, int p) {
      var m = -1e300;
      for (var j = e - p + 1; j <= e; j++) {
        if (h[j] > m) m = h[j];
      }
      return m;
    }
    double lMin(int e, int p) {
      var m = 1e300;
      for (var j = e - p + 1; j <= e; j++) {
        if (l[j] < m) m = l[j];
      }
      return m;
    }
    double momAt(int e) {
      final mid = (hMax(e, 20) + lMin(e, 20)) / 2;
      var sm = 0.0;
      for (var j = e - 19; j <= e; j++) {
        sm += c[j];
      }
      return c[e] - (mid + sm / 20) / 2;
    }
    final m1 = momAt(n - 1), m0 = momAt(n - 2);
    final mean20 = smaLast(c, 20);
    var sq = 0.0;
    for (var j = n - 20; j < n; j++) {
      sq += (c[j] - mean20) * (c[j] - mean20);
    }
    final sd = math.sqrt(sq / 20);
    final a20 = wilder(trSeries(h, l, c), 20).last;
    final sqOn = 2 * sd < 1.5 * a20;
    osc.add(Reading('Squeeze Momentum', '${sqOn ? 'Squeeze ON' : 'Squeeze OFF'}, momentum ${m1 > m0 ? 'rising' : 'falling'}',
        m1 > 0 && m1 > m0 ? 1 : m1 < 0 && m1 < m0 ? -1 : 0));
  }
  if (n >= 10) {
    var hao = (cs[0].open + c[0]) / 2;
    var hac = (cs[0].open + h[0] + l[0] + c[0]) / 4;
    final bullHa = <bool>[hac > hao];
    for (var i = 1; i < n; i++) {
      final nc = (cs[i].open + h[i] + l[i] + c[i]) / 4;
      final no = (hao + hac) / 2;
      hao = no;
      hac = nc;
      bullHa.add(hac > hao);
    }
    final b3 = bullHa[n - 1] && bullHa[n - 2] && bullHa[n - 3];
    final s3 = !bullHa[n - 1] && !bullHa[n - 2] && !bullHa[n - 3];
    osc.add(Reading('Heikin-Ashi trend', b3 ? 'Bullish (3 candles)' : s3 ? 'Bearish (3 candles)' : 'Mixed', b3 ? 1 : s3 ? -1 : 0));
  }
  if (n >= 40) {
    final atr22 = wilder(trSeries(h, l, c), 22);
    var dirC = 1;
    var pls = double.nan, pss = double.nan;
    for (var i = 21; i < n; i++) {
      var hh = -1e300, ll = 1e300;
      for (var j = i - 21; j <= i; j++) {
        if (h[j] > hh) hh = h[j];
        if (l[j] < ll) ll = l[j];
      }
      final lsv = hh - 3 * atr22[i], ssv = ll + 3 * atr22[i];
      if (!pss.isNaN) {
        if (c[i] > pss) {
          dirC = 1;
        } else if (c[i] < pls) {
          dirC = -1;
        }
      }
      pls = lsv;
      pss = ssv;
    }
    osc.add(Reading('Chandelier Exit (22,3)', dirC == 1 ? 'Long' : 'Short', dirC));
  }
  if (n >= 50) {
    const win = 50;
    var sx = 0.0, sy = 0.0;
    for (var k = 0; k < win; k++) {
      sx += k;
      sy += c[n - win + k];
    }
    final mx = sx / win, my = sy / win;
    var sxy = 0.0, sxx = 0.0, syy = 0.0;
    for (var k = 0; k < win; k++) {
      final dx = k - mx, dy = c[n - win + k] - my;
      sxy += dx * dy;
      sxx += dx * dx;
      syy += dy * dy;
    }
    final slope = sxx == 0 ? 0.0 : sxy / sxx;
    final r2 = syy == 0 || sxx == 0 ? 0.0 : sxy * sxy / (sxx * syy);
    final pct = my == 0 ? 0.0 : slope * win / my * 100;
    osc.add(Reading('Linear regression (50)', '${pct.toStringAsFixed(1)}% over 50 bars, R2 ${r2.toStringAsFixed(2)}', r2 > 0.5 ? (slope > 0 ? 1 : -1) : 0));
  }
  if (n >= 30) {
    final w = math.min(n, 100);
    var hiF = -1e300, loF = 1e300;
    for (var j = n - w; j < n; j++) {
      if (h[j] > hiF) hiF = h[j];
      if (l[j] < loF) loF = l[j];
    }
    final rg = hiF - loF;
    info.add(Reading('Fib 38.2 / 50 / 61.8 (100 bars)', '${f(hiF - 0.382 * rg)} / ${f(hiF - 0.5 * rg)} / ${f(hiF - 0.618 * rg)}', 0));
  }

  // ---- info
  final atr = wilder(trSeries(h, l, c), 14).last;

  // ---- support / resistance read from the chart
  var lvAll = srLevels(h, l, last, atr);
  final strong = lvAll.where((x) => x[1] >= 2).toList();
  if (strong.length >= 2) lvAll = strong;
  final sups = <double>[for (final x in lvAll.reversed) if (x[0] < last) x[0]];
  final ress = <double>[for (final x in lvAll) if (x[0] > last) x[0]];
  if (atr > 0) {
    final dS = sups.isEmpty ? 1e9 : (last - sups.first) / atr;
    final dR = ress.isEmpty ? 1e9 : (ress.first - last) / atr;
    final txt = '${sups.isEmpty ? 'S -' : 'S ${f(sups.first)} (${dS.toStringAsFixed(1)} ATR)'}  ${ress.isEmpty ? 'R -' : 'R ${f(ress.first)} (${dR.toStringAsFixed(1)} ATR)'}';
    osc.add(Reading('Support / Resistance', txt, dS <= 0.6 ? 1 : dR <= 0.6 ? -1 : 0, true));
  }
  if (sups.isNotEmpty) info.add(Reading('Support levels', sups.take(3).map(f).join(' / '), 0));
  if (ress.isNotEmpty) info.add(Reading('Resistance levels', ress.take(3).map(f).join(' / '), 0));

  // ---- candlestick pattern on the latest candles
  if (n >= 4) {
    final i = n - 1;
    final body = (c[i] - cs[i].open).abs(), rg = h[i] - l[i];
    final upW = h[i] - math.max(c[i], cs[i].open), loW = math.min(c[i], cs[i].open) - l[i];
    final pBody = (c[i - 1] - cs[i - 1].open).abs();
    final bigPrev = (c[i - 2] - cs[i - 2].open).abs();
    var name = 'None', sg = 0;
    if (c[i - 2] < cs[i - 2].open && bigPrev > atr * 0.6 && pBody < bigPrev * 0.4 && c[i] > cs[i].open && c[i] > (c[i - 2] + cs[i - 2].open) / 2) {
      name = 'Morning star';
      sg = 1;
    } else if (c[i - 2] > cs[i - 2].open && bigPrev > atr * 0.6 && pBody < bigPrev * 0.4 && c[i] < cs[i].open && c[i] < (c[i - 2] + cs[i - 2].open) / 2) {
      name = 'Evening star';
      sg = -1;
    } else if (c[i - 1] < cs[i - 1].open && c[i] > cs[i].open && c[i] >= cs[i - 1].open && cs[i].open <= c[i - 1] && body > pBody) {
      name = 'Bullish engulfing';
      sg = 1;
    } else if (c[i - 1] > cs[i - 1].open && c[i] < cs[i].open && c[i] <= cs[i - 1].open && cs[i].open >= c[i - 1] && body > pBody) {
      name = 'Bearish engulfing';
      sg = -1;
    } else if (rg > 0 && body > 0 && loW > 2 * body && upW < 0.25 * rg) {
      name = 'Hammer';
      sg = 1;
    } else if (rg > 0 && body > 0 && upW > 2 * body && loW < 0.25 * rg) {
      name = 'Shooting star';
      sg = -1;
    } else if (rg > 0 && body < 0.1 * rg) {
      name = 'Doji';
    }
    osc.add(Reading('Candle pattern', name, sg));
  }
  info.add(Reading('ATR (14)', '${f(atr)}  (${(atr / last * 100).toStringAsFixed(2)}%)', 0));
  if (n > 2) {
    final p = (h[n - 2] + l[n - 2] + c[n - 2]) / 3;
    info.add(Reading('Pivot / R1 / S1', '${f(p)} / ${f(2 * p - l[n - 2])} / ${f(2 * p - h[n - 2])}', 0));
  }

  var b = 0, s = 0, z = 0;
  for (final r in [...ma, ...osc]) {
    if (r.sig > 0) {
      b++;
    } else if (r.sig < 0) {
      s++;
    } else {
      z++;
    }
  }
  // regime-aware score: trust trend indicators in strong trends, oscillators in ranges
  var wsum = 0.0, ssum = 0.0;
  for (final r in [...ma, ...osc]) {
    var w = 1.0;
    if (!adxV.isNaN) {
      if (adxV > 25) {
        w = r.mr ? 0.5 : 1.5;
      } else if (adxV < 20) {
        w = r.mr ? 1.3 : 0.6;
      }
    }
    wsum += w;
    ssum += w * r.sig;
  }
  final score = wsum == 0 ? 0.0 : ssum / wsum;
  return Analysis(ma, osc, info, b, s, z, last, atr, adxV, score, sups.take(3).toList(), ress.take(3).toList());
}

Future<List<Candle>> fetchCandles(String sym, String tf) async {
  if (!yahooPairs.containsKey(sym)) {
    final pair = futSymbols[sym] ?? '${sym}USDT';
    final q = {'symbol': pair, 'interval': tf, 'limit': '300'};
    var r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/klines', q)).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      r = await http.get(Uri.https('api.binance.com', '/api/v3/klines', q)).timeout(const Duration(seconds: 15));   // spot fallback
    }
    if (r.statusCode != 200) throw 'Binance data unavailable for $sym (HTTP ${r.statusCode}). It may be blocked on your network.';
    return (jsonDecode(r.body) as List)
        .map((x) => Candle(DateTime.fromMillisecondsSinceEpoch((x[0] as num).toInt()), double.parse('${x[1]}'),
            double.parse('${x[2]}'), double.parse('${x[3]}'), double.parse('${x[4]}'), double.parse('${x[5]}')))
        .toList();
  }
  final ySym = yahooPairs[sym]!;
  final cfg = yahooTf[tf] ?? ['1m', '1d'];
  final uri = Uri.https('query1.finance.yahoo.com', '/v8/finance/chart/$ySym', {'range': cfg[1], 'interval': cfg[0]});
  final r = await http.get(uri, headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw '$sym data unavailable (HTTP ${r.statusCode}). Free source may be rate-limited or the market is closed.';
  final result = (jsonDecode(r.body)['chart']['result'] as List?) ?? [];
  if (result.isEmpty) throw '$sym has no data right now (market may be closed).';
  final root = result[0];
  final times = (root['timestamp'] as List?) ?? [];
  final q = root['indicators']['quote'][0];
  final os = q['open'] as List? ?? [], hs = q['high'] as List? ?? [], ls = q['low'] as List? ?? [], cs = q['close'] as List? ?? [], vs = q['volume'] as List? ?? [];
  var list = <Candle>[];
  for (var i = 0; i < times.length; i++) {
    if ([os[i], hs[i], ls[i], cs[i]].any((x) => x == null)) continue;
    final vol = i < vs.length && vs[i] != null ? (vs[i] as num).toDouble() : 0.0;
    list.add(Candle(DateTime.fromMillisecondsSinceEpoch((times[i] as num).toInt() * 1000), (os[i] as num).toDouble(),
        (hs[i] as num).toDouble(), (ls[i] as num).toDouble(), (cs[i] as num).toDouble(), vol));
  }
  if (tf == '4h') list = aggregateCandles(list, 4);
  return list.takeLast(300);
}

List<Candle> aggregateCandles(List<Candle> src, int hours) {
  final ms = hours * 3600 * 1000;
  final out = <Candle>[];
  int? key;
  for (final c in src) {
    final k = c.time.millisecondsSinceEpoch ~/ ms;
    if (key == k && out.isNotEmpty) {
      final p = out.last;
      out[out.length - 1] = Candle(p.time, p.open, math.max(p.high, c.high), math.min(p.low, c.low), c.close, p.volume + c.volume);
    } else {
      out.add(c);
      key = k;
    }
  }
  return out;
}


// ---------- news, sentiment and web data ----------
const newsFeeds = {
  'CoinDesk': 'https://www.coindesk.com/arc/outboundfeeds/rss/',
  'Cointelegraph': 'https://cointelegraph.com/rss',
  'Decrypt': 'https://decrypt.co/feed',
  'FXStreet': 'https://www.fxstreet.com/rss/news',
  'ForexLive': 'https://www.forexlive.com/feed/news',
  'CNBC': 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=10000664',
  'BBC Business': 'https://feeds.bbci.co.uk/news/business/rss.xml',
};
const bullWords = ['surge', 'rally', 'soar', 'approve', 'inflow', 'adoption', 'rate cut', 'beats', 'record high', 'gains', 'bullish', 'jumps', 'rebound', 'recovers', 'upgrade', 'breakout', 'etf approval'];
const bearWords = ['crash', 'plunge', 'hack', 'exploit', 'ban ', 'lawsuit', 'sues', 'rate hike', 'liquidat', 'fears', 'selloff', 'sell-off', 'bearish', 'slump', 'tumbles', 'warns', 'outflow', 'downgrade', 'sanction', 'default'];
const macroWords = ['fed ', 'fomc', 'inflation', 'cpi', 'dollar', 'powell', 'yields', 'tariff'];
const coinKeys = {
  'BTC': ['bitcoin', 'btc'], 'ETH': ['ethereum', 'ether '], 'SOL': ['solana'], 'BNB': ['bnb', 'binance'], 'XRP': ['xrp', 'ripple'],
  'DOGE': ['dogecoin', 'doge'], 'GOLD': ['gold'], 'SILVER': ['silver'], 'OIL': ['oil', 'crude', 'opec', 'brent'],
  'EURUSD': ['euro ', 'ecb', 'eur/usd'], 'GBPUSD': ['sterling', 'boe', 'gbp', 'pound'], 'USDJPY': ['yen', 'boj', 'jpy'],
  'AUDUSD': ['aussie', 'rba', 'aud '], 'USDCAD': ['loonie', 'boc', 'canadian dollar'],
};
const symCurrencies = {
  'EURUSD': ['EUR', 'USD'], 'GBPUSD': ['GBP', 'USD'], 'USDJPY': ['USD', 'JPY'], 'AUDUSD': ['AUD', 'USD'], 'USDCAD': ['USD', 'CAD'],
};

List<String> keysFor(String sym) => coinKeys[sym] ?? [sym.length >= 4 ? sym.toLowerCase() : ' ${sym.toLowerCase()} '];

class NewsItem {
  final String title, source;
  final DateTime? time;
  final int score;
  NewsItem(this.title, this.source, this.time, this.score);
}

class EconEvent {
  final String title, country, forecast, previous;
  final DateTime time;
  EconEvent(this.title, this.country, this.time, this.forecast, this.previous);
}

int scoreTitle(String t) {
  final x = ' ${t.toLowerCase()} ';
  var sc = 0;
  for (final w in bullWords) {
    if (x.contains(w)) sc++;
  }
  for (final w in bearWords) {
    if (x.contains(w)) sc--;
  }
  return sc;
}

String unescapeXml(String s) => s
    .replaceAll('<![CDATA[', '')
    .replaceAll(']]>', '')
    .replaceAll('&amp;', '&')
    .replaceAll('&#39;', "'")
    .replaceAll('&#8217;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .trim();

DateTime? parseRfc822(String s) {
  final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2})(?::(\d{2}))?').firstMatch(s);
  if (m == null) return DateTime.tryParse(s);
  const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  final mo = months.indexOf(m.group(2)!.toLowerCase()) + 1;
  if (mo == 0) return null;
  var t = DateTime.utc(int.parse(m.group(3)!), mo, int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!), int.parse(m.group(6) ?? '0'));
  final z = RegExp(r'([+-])(\d{2})(\d{2})\s*$').firstMatch(s.trim());
  if (z != null) {
    final off = Duration(hours: int.parse(z.group(2)!), minutes: int.parse(z.group(3)!));
    t = z.group(1) == '+' ? t.subtract(off) : t.add(off);
  }
  return t;
}

List<NewsItem> parseRss(String body, String source) {
  final out = <NewsItem>[];
  for (final m in RegExp(r'<item[\s>](.*?)</item>', dotAll: true).allMatches(body)) {
    final blk = m.group(1) ?? '';
    final t = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true).firstMatch(blk)?.group(1);
    if (t == null) continue;
    final d = RegExp(r'<pubDate[^>]*>(.*?)</pubDate>', dotAll: true).firstMatch(blk)?.group(1);
    final title = unescapeXml(t);
    out.add(NewsItem(title, source, d == null ? null : parseRfc822(d.trim()), scoreTitle(title)));
  }
  return out;
}

Future<List<NewsItem>> fetchNews() async {
  final res = await Future.wait(newsFeeds.entries.map<Future<List<NewsItem>>>((e) async {
    try {
      final r = await http.get(Uri.parse(e.value), headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return <NewsItem>[];
      return parseRss(r.body, e.key).take(20).toList();
    } catch (_) {
      return <NewsItem>[];
    }
  }));
  final all = [for (final l in res) ...l];
  all.sort((a, b) => (b.time ?? DateTime(2000)).compareTo(a.time ?? DateTime(2000)));
  return all.take(120).toList();
}

Future<Map<String, dynamic>?> fetchFng() async {
  try {
    final r = await http.get(Uri.parse('https://api.alternative.me/fng/?limit=2')).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return null;
    final d = jsonDecode(r.body)['data'] as List;
    return {'value': int.parse('${d[0]['value']}'), 'label': '${d[0]['value_classification']}', 'prev': d.length > 1 ? int.parse('${d[1]['value']}') : null};
  } catch (_) {
    return null;
  }
}

Future<List<EconEvent>> fetchEvents() async {
  try {
    final r = await http.get(Uri.parse('https://nfs.faireconomy.media/ff_calendar_thisweek.json'), headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return [];
    final out = <EconEvent>[];
    for (final e in jsonDecode(r.body) as List) {
      if (e['impact'] != 'High') continue;
      final t = DateTime.tryParse('${e['date']}');
      if (t == null) continue;
      out.add(EconEvent('${e['title']}', '${e['country']}', t.toLocal(), '${e['forecast'] ?? ''}', '${e['previous'] ?? ''}'));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  } catch (_) {
    return [];
  }
}

// Binance futures positioning: funding rate (%), open interest (coins), long/short account ratio
Future<Map<String, double>> fetchFutMeta(String coin) async {
  final pair = futSymbols[coin] ?? '${coin}USDT';
  final out = <String, double>{};
  try {
    final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/premiumIndex', {'symbol': pair})).timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) out['funding'] = double.parse('${jsonDecode(r.body)['lastFundingRate']}') * 100;
  } catch (_) {}
  try {
    final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/openInterest', {'symbol': pair})).timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) out['oi'] = double.parse('${jsonDecode(r.body)['openInterest']}');
  } catch (_) {}
  try {
    final r = await http.get(Uri.https('fapi.binance.com', '/futures/data/globalLongShortAccountRatio', {'symbol': pair, 'period': '1h', 'limit': '1'})).timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) {
      final d = jsonDecode(r.body) as List;
      if (d.isNotEmpty) out['ls'] = double.parse('${d[0]['longShortRatio']}');
    }
  } catch (_) {}
  return out;
}

String compactNum(double v) => v >= 1e9 ? '${(v / 1e9).toStringAsFixed(2)}B' : v >= 1e6 ? '${(v / 1e6).toStringAsFixed(2)}M' : v >= 1e3 ? '${(v / 1e3).toStringAsFixed(1)}K' : v.toStringAsFixed(2);

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String untilText(DateTime t) {
  final d = t.difference(DateTime.now());
  final a = d.abs();
  final txt = a.inDays >= 1 ? '${a.inDays}d ${a.inHours % 24}h' : a.inHours >= 1 ? '${a.inHours}h ${a.inMinutes % 60}m' : '${a.inMinutes}m';
  return d.isNegative ? '$txt ago' : 'in $txt';
}

// Stop / target using chart support and resistance when they are close enough to be useful.
List<double> tradePlan(Analysis a) {
  final side = a.side;
  var sl = a.last - side * 1.5 * a.atr;
  final lvl = side == 1 ? (a.sup.isEmpty ? double.nan : a.sup.first - 0.2 * a.atr) : (a.res.isEmpty ? double.nan : a.res.first + 0.2 * a.atr);
  if (!lvl.isNaN) {
    final dist = (a.last - lvl).abs();
    if (dist >= 0.8 * a.atr && dist <= 3 * a.atr) sl = lvl;
  }
  final risk = (a.last - sl).abs();
  var tp = a.last + side * 2 * risk;
  final tgt = side == 1 ? (a.res.isEmpty ? double.nan : a.res.first) : (a.sup.isEmpty ? double.nan : a.sup.first);
  if (!tgt.isNaN) {
    final dist = (tgt - a.last).abs();
    if (dist >= 1.2 * risk && dist < 2 * risk) tp = tgt;
  }
  return [sl, tp, risk == 0 ? 0.0 : (tp - a.last).abs() / risk];
}


// ---------- custom price alerts ----------
class PriceAlert {
  final int id;
  final String sym, note;
  final double price;
  final bool above; // true: notify when price rises to the target, false: when it falls to it
  bool done;
  DateTime? firedAt;
  PriceAlert(this.id, this.sym, this.price, this.above, this.note, {this.done = false, this.firedAt});
  Map<String, dynamic> toJson() => {'id': id, 'sym': sym, 'price': price, 'above': above, 'note': note, 'done': done, 'fired': firedAt?.toIso8601String()};
  factory PriceAlert.fromJson(Map<String, dynamic> j) => PriceAlert(
        (j['id'] as num).toInt(), '${j['sym']}', (j['price'] as num).toDouble(), j['above'] == true, '${j['note'] ?? ''}',
        done: j['done'] == true, firedAt: j['fired'] == null ? null : DateTime.tryParse('${j['fired']}'));
}

final FlutterLocalNotificationsPlugin notifier = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  try {
    const init = InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher'));
    await notifier.initialize(init);
    await notifier.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  } catch (_) {}
}

Future<void> notify(int id, String title, String body) async {
  try {
    const details = NotificationDetails(
      android: AndroidNotificationDetails('price_alerts', 'Price alerts',
          channelDescription: 'Tells you when a price you chose is reached', importance: Importance.max, priority: Priority.high, playSound: true, enableVibration: true),
    );
    await notifier.show(id, title, body, details);
  } catch (_) {}
}

Future<double?> fetchPrice(String sym) async {
  try {
    if (!yahooPairs.containsKey(sym)) {
      final pair = futSymbols[sym] ?? '${sym}USDT';
      var r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/ticker/price', {'symbol': pair})).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        r = await http.get(Uri.https('api.binance.com', '/api/v3/ticker/price', {'symbol': pair})).timeout(const Duration(seconds: 10));
      }
      if (r.statusCode != 200) return null;
      return double.parse('${jsonDecode(r.body)['price']}');
    }
    final r = await http
        .get(Uri.https('query1.finance.yahoo.com', '/v8/finance/chart/${yahooPairs[sym]}', {'range': '1d', 'interval': '5m'}), headers: {'User-Agent': 'Mozilla/5.0'})
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    return (jsonDecode(r.body)['chart']['result'][0]['meta']['regularMarketPrice'] as num).toDouble();
  } catch (_) {
    return null;
  }
}

class SignalApp extends StatelessWidget {
  const SignalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Signal Bot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
          brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Map<String, dynamic>? data;
  String? error;
  bool loading = false;
  String filter = 'All';
  Timer? timer;
  Timer? marketTimer;
  String marketSymbol = 'BTC';
  String marketInterval = '1m';
  bool marketLoading = false;
  String? marketError;
  DateTime? marketUpdated;
  final Map<String, List<Candle>> candles = {};
  final Map<String, double> latestPrices = {};
  Map<String, Analysis?> mtf = {};
  bool mtfBusy = false;
  Timer? mtfTimer;
  String tfFilter = 'All';
  List<PriceAlert> alerts = [];
  bool alertBusy = false;
  final Map<String, DateTime> alertChecked = {};
  Timer? alertTimer;
  List<NewsItem> news = [];
  List<EconEvent> events = [];
  Map<String, dynamic>? fng;
  bool newsBusy = false;
  String? newsError;
  DateTime? newsUpdated;
  String newsFilter = 'All';
  Map<String, double> futMeta = {};
  String futMetaSym = '';
  Timer? newsTimer;
  String? futuresError;
  List<ScanRow> scanRows = [];
  List<Map<String, dynamic>> movers = [];
  bool scanning = false, autoScan = false;
  double scanProgress = 0;
  String scanTf = '1h', scanFilter = 'All', scanSort = 'Strength';
  int scanN = 50;
  String? scanError;
  DateTime? scanUpdated;
  Timer? scanTimer;

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load(silent: true));
    loadMarket();
    marketTimer = Timer.periodic(const Duration(seconds: 1), (_) => loadMarket(silent: true));
    loadFutures();
    loadAlerts();
    initNotifications();
    alertTimer = Timer.periodic(const Duration(seconds: 5), (_) => checkAlerts());
    loadNews();
    newsTimer = Timer.periodic(const Duration(minutes: 5), (_) => loadNews());
    loadMtf();
    mtfTimer = Timer.periodic(const Duration(seconds: 30), (_) => loadMtf());
  }

  @override
  void dispose() {
    timer?.cancel();
    marketTimer?.cancel();
    mtfTimer?.cancel();
    scanTimer?.cancel();
    newsTimer?.cancel();
    alertTimer?.cancel();
    super.dispose();
  }

  bool marketBusy = false;

  Future<void> loadMarket({bool silent = false}) async {
    if (marketBusy) return;                       // never overlap requests
    if (silent && yahooPairs.containsKey(marketSymbol) && marketUpdated != null &&
        DateTime.now().difference(marketUpdated!).inSeconds < 15) {
      return;                                     // Yahoo rate-limits: forex, gold and oil refresh every 15s
    }
    marketBusy = true;
    final sym = marketSymbol, tf = marketInterval;
    if (!silent && mounted) setState(() { marketLoading = true; marketError = null; });
    try {
      final list = await fetchCandles(sym, tf);
      candles['$sym|$tf'] = list;
      if (list.isNotEmpty) latestPrices[sym] = list.last.close;
      marketUpdated = DateTime.now();
      marketError = null;
    } catch (e) {
      marketError = '$e';
    } finally {
      marketBusy = false;
      if (mounted) setState(() => marketLoading = false);
    }
  }

  Future<void> loadFutures() async {
    try {
      final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/exchangeInfo')).timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final syms = jsonDecode(r.body)['symbols'] as List;
      final m = <String, String>{};
      for (final x in syms) {
        if (x['contractType'] == 'PERPETUAL' && x['quoteAsset'] == 'USDT' && x['status'] == 'TRADING') {
          m['${x['baseAsset']}'] = '${x['symbol']}';
        }
      }
      futSymbols
        ..clear()
        ..addAll(m);
      futuresError = null;
    } catch (e) {
      futuresError = 'Could not load the Binance futures coin list ($e). Binance may be blocked on your network.';
    }
    if (mounted) setState(() {});
  }

  Future<List<Map<String, dynamic>>> fetchTickers() async {
    final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/ticker/24hr')).timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) throw 'Binance futures unavailable (HTTP ${r.statusCode}).';
    final base = {for (final e in futSymbols.entries) e.value: e.key};
    final out = <Map<String, dynamic>>[];
    for (final t in jsonDecode(r.body) as List) {
      final coin = base['${t['symbol']}'];
      if (coin == null) continue;
      out.add({
        'coin': coin,
        'price': double.tryParse('${t['lastPrice']}') ?? 0.0,
        'chg': double.tryParse('${t['priceChangePercent']}') ?? 0.0,
        'vol': double.tryParse('${t['quoteVolume']}') ?? 0.0,
      });
    }
    out.sort((a, b) => (b['vol'] as double).compareTo(a['vol'] as double));
    return out;
  }

  Future<void> runScan() async {
    if (scanning) return;
    setState(() { scanning = true; scanError = null; scanProgress = 0; });
    try {
      if (futSymbols.isEmpty) await loadFutures();
      if (futSymbols.isEmpty) throw futuresError ?? 'No futures coins loaded.';
      final tickers = await fetchTickers();
      movers = tickers;
      final top = tickers.take(scanN).toList();
      final rows = <ScanRow>[];
      for (var i = 0; i < top.length; i += 8) {
        final batch = top.skip(i).take(8).toList();
        final res = await Future.wait(batch.map<Future<ScanRow?>>((t) async {
          try {
            final cs = await fetchCandles(t['coin'] as String, scanTf);
            if (cs.length < 35) return null;
            return ScanRow(t['coin'] as String, cs.last.close, t['chg'] as double, t['vol'] as double, analyze(cs, 2));
          } catch (_) {
            return null;
          }
        }));
        rows.addAll(res.whereType<ScanRow>());
        if (mounted) setState(() => scanProgress = math.min(1.0, (i + 8) / top.length));
      }
      scanRows = rows;
      scanUpdated = DateTime.now();
    } catch (e) {
      scanError = '$e';
    } finally {
      scanning = false;
      if (mounted) setState(() {});
    }
  }

  void openCoin(String coin, String tf, BuildContext ctx) {
    setState(() { marketSymbol = coin; marketInterval = tf; mtf = {}; });
    loadMarket();
    loadMtf();
    DefaultTabController.of(ctx).animateTo(0);
  }

  Future<void> pickCoin() async {
    if (futSymbols.isEmpty) await loadFutures();
    if (!mounted) return;
    final coins = futSymbols.keys.toList()..sort();
    var q = '';
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setM) {
        final shown = coins.where((c) => c.contains(q.toUpperCase())).toList();
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * .75,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search ${coins.length} Binance futures coins', border: const OutlineInputBorder()),
                    onChanged: (v) => setM(() => q = v),
                  ),
                ),
                Expanded(
                  child: coins.isEmpty
                      ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(futuresError ?? 'No coins loaded.')))
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (_, i) => ListTile(dense: true, title: Text(shown[i]), subtitle: Text(futSymbols[shown[i]] ?? ''), onTap: () => Navigator.pop(ctx, shown[i])),
                        ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
    if (choice != null) {
      setState(() { marketSymbol = choice; mtf = {}; });
      loadMarket();
      loadMtf();
    }
  }

  Future<void> loadNews() async {
    if (newsBusy) return;
    newsBusy = true;
    try {
      final fn = fetchNews(), ff = fetchFng(), fe = fetchEvents();
      news = await fn;
      fng = await ff;
      events = await fe;
      newsError = news.isEmpty ? 'No headlines could be loaded. Check your internet connection.' : null;
      newsUpdated = DateTime.now();
    } catch (e) {
      newsError = '$e';
    } finally {
      newsBusy = false;
      if (mounted) setState(() {});
    }
  }

  // headlines from the last 24h that mention the symbol (full weight) or macro themes (half weight)
  int newsScore(String sym) {
    final keys = keysFor(sym);
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    var tot = 0.0;
    for (final n in news) {
      if (n.time != null && n.time!.isBefore(cutoff)) continue;
      final t = ' ${n.title.toLowerCase()} ';
      if (keys.any((k) => t.contains(k))) {
        tot += n.score;
      } else if (macroWords.any((k) => t.contains(k))) {
        tot += 0.5 * n.score;
      }
    }
    return tot.round();
  }

  bool newsMatches(NewsItem n, String sym) {
    final t = ' ${n.title.toLowerCase()} ';
    return keysFor(sym).any((k) => t.contains(k));
  }

  EconEvent? eventSoon(String sym) {
    final cur = symCurrencies[sym] ?? ['USD'];
    final now = DateTime.now();
    for (final e in events) {
      if (cur.contains(e.country) && e.time.difference(now).inMinutes.abs() <= 45) return e;
    }
    return null;
  }

  void toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> loadAlerts() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('alerts');
      if (raw != null) {
        alerts = (jsonDecode(raw) as List).map((e) => PriceAlert.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> saveAlerts() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('alerts', jsonEncode(alerts.map((a) => a.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> addAlert(String sym, double target, String note) async {
    final cur = latestPrices[sym] ?? await fetchPrice(sym);
    if (cur == null) {
      toast('Could not read the current $sym price. Try again in a moment.');
      return;
    }
    if ((target - cur).abs() < 1e-12) {
      toast('The target is the same as the current price.');
      return;
    }
    alerts.add(PriceAlert(DateTime.now().millisecondsSinceEpoch % 2000000000, sym, target, target > cur, note));
    await saveAlerts();
    if (mounted) setState(() {});
    toast('Alert set: $sym ${target > cur ? 'rises to' : 'falls to'} ${fmtPrice(target)}');
  }

  Future<void> checkAlerts() async {
    if (alertBusy) return;
    final active = alerts.where((a) => !a.done).toList();
    if (active.isEmpty) return;
    alertBusy = true;
    try {
      var changed = false;
      for (final sym in active.map((a) => a.sym).toSet()) {
        if (yahooPairs.containsKey(sym)) {
          final last = alertChecked[sym];
          if (last != null && DateTime.now().difference(last).inSeconds < 15) continue;
          alertChecked[sym] = DateTime.now();
        }
        final px = await fetchPrice(sym);
        if (px == null) continue;
        latestPrices[sym] = px;
        for (final a in active.where((x) => x.sym == sym)) {
          if ((a.above && px >= a.price) || (!a.above && px <= a.price)) {
            a.done = true;
            a.firedAt = DateTime.now();
            changed = true;
            final msg = '${a.sym} ${a.above ? 'rose to' : 'fell to'} ${fmtPrice(px)} (your alert ${fmtPrice(a.price)})${a.note.isEmpty ? '' : '. ${a.note}'}';
            await notify(a.id, 'Price alert: ${a.sym}', msg);
            HapticFeedback.heavyImpact();
            SystemSound.play(SystemSoundType.alert);
            toast(msg);
          }
        }
      }
      if (changed) {
        await saveAlerts();
      }
      if (mounted) setState(() {});
    } finally {
      alertBusy = false;
    }
  }

  Future<void> alertDialog({double? preset, String note = ''}) async {
    final cur = latestPrices[marketSymbol];
    final priceCtl = TextEditingController(text: preset != null ? fmtPrice(preset) : (cur == null ? '' : fmtPrice(cur)));
    final noteCtl = TextEditingController(text: note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Price alert: $marketSymbol'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(cur == null ? 'Current price unavailable' : 'Current price ${fmtPrice(cur)}'),
          TextField(controller: priceCtl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Notify me when price reaches')),
          TextField(controller: noteCtl, decoration: const InputDecoration(labelText: 'Note (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Set alert')),
        ],
      ),
    );
    if (ok == true) {
      final v = double.tryParse(priceCtl.text.trim().replaceAll(',', '.'));
      if (v == null || v <= 0) {
        toast('Enter a valid price.');
      } else {
        await addAlert(marketSymbol, v, noteCtl.text.trim());
      }
    }
  }

  Future<void> loadMtf() async {
    if (mtfBusy) return;
    mtfBusy = true;
    final sym = marketSymbol;
    try {
      final res = await Future.wait(mtfList.map<Future<Analysis?>>((tf) async {
        try {
          final cs = await fetchCandles(sym, tf);
          return cs.length >= 35 ? analyze(cs, decimalsFor(sym, cs.last.close)) : null;
        } catch (_) {
          return null;
        }
      }));
      if (sym == marketSymbol) {
        mtf = {for (var i = 0; i < mtfList.length; i++) mtfList[i]: res[i]};
        if (!yahooPairs.containsKey(sym)) {
          final meta = await fetchFutMeta(sym);
          if (sym == marketSymbol) {
            futMeta = meta;
            futMetaSym = sym;
          }
        } else {
          futMeta = {};
          futMetaSym = '';
        }
      }
    } finally {
      mtfBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> load({bool silent = false}) async {
    if (feedUrl.isEmpty) {
      setState(() => error = 'FEED_URL was not set when the app was built.');
      return;
    }
    if (!silent) setState(() => loading = true);
    try {
      final r = await http
          .get(Uri.parse('$feedUrl?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw 'Feed not found (HTTP ${r.statusCode}). Run the bot once and make sure the repo is public.';
      }
      data = jsonDecode(r.body) as Map<String, dynamic>;
      error = null;
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  Widget marketTab() {
    final all = candles['$marketSymbol|$marketInterval'] ?? <Candle>[];
    final list = all.takeLast(60);
    final an = all.length >= 35 ? analyze(all, decimalsFor(marketSymbol, all.last.close)) : null;
    final price = latestPrices[marketSymbol];
    final pkt = DateTime.now().toUtc().add(const Duration(hours: 5));
    String hm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    final sessions = <Map<String, dynamic>>[
      {'name':'Tokyo', 'start':5*60, 'end':14*60},
      {'name':'London', 'start':13*60, 'end':22*60},
      {'name':'New York Forex', 'start':17*60, 'end':2*60},
      {'name':'US Stocks', 'start':18*60+30, 'end':1*60},
    ];
    final nowMin = pkt.hour*60 + pkt.minute;
    bool isOpen(Map<String,dynamic> x) { final a=x['start'] as int, b=x['end'] as int; return a < b ? nowMin >= a && nowMin < b : nowMin >= a || nowMin < b; }
    return RefreshIndicator(onRefresh: loadMarket, child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
      Wrap(spacing: 8, runSpacing: 4, children: [
        ActionChip(avatar: const Icon(Icons.add_alert, size: 18), label: const Text('Set price alert'), onPressed: () => alertDialog()),
        ActionChip(avatar: const Icon(Icons.search, size: 18), label: Text(futSymbols.isEmpty ? 'All futures coins' : 'All coins (${futSymbols.length})'), onPressed: pickCoin),
        for (final a in {...favorites, marketSymbol}) ChoiceChip(label: Text(a), selected: marketSymbol == a, onSelected: (_) { setState(() { marketSymbol = a; mtf = {}; }); loadMarket(); loadMtf(); }),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [for (final tf in tfList) ChoiceChip(label: Text(tf), selected: marketInterval==tf, onSelected: (_) { setState(() => marketInterval=tf); loadMarket(); })]),
      const SizedBox(height: 10),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(marketSymbol, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(price == null ? 'Price unavailable' : '${fxPairs.contains(marketSymbol) ? '' : '\$'}${price.toStringAsFixed(decimalsFor(marketSymbol, price))}', style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700)),
        Text('Free public data • Last update: ${marketUpdated == null ? 'not yet' : ago(marketUpdated!.toIso8601String())}'),
        const SizedBox(height: 12),
        if (marketLoading) const LinearProgressIndicator(),
        if (marketError != null) Text(marketError!, style: const TextStyle(color: Colors.orange)),
        if (list.length > 1) SizedBox(height: 260, child: CustomPaint(painter: CandlePainter(list, Theme.of(context).brightness==Brightness.dark, an?.sup ?? const <double>[], an?.res ?? const <double>[]), child: const SizedBox.expand())) else const SizedBox(height: 200, child: Center(child: Text('Waiting for candlestick data...'))),
        const Text('Candles show open, high, low and close. Free APIs may delay or limit data.', style: TextStyle(fontSize: 11)),
        const SizedBox(height: 14),
        Text('Technical indicators', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (an != null) _indicatorPanel(an) else const Text('More candles are needed to calculate indicators.'),
      ]))),
      _mtfCard(),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Market sessions • Pakistan time (UTC+5)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final x in sessions) ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(x['name'] as String), subtitle: Text('${hm((x['start'] as int) ~/ 60, (x['start'] as int)%60)} – ${hm((x['end'] as int) ~/ 60, (x['end'] as int)%60)} PKT'), trailing: Text(isOpen(x) ? 'OPEN' : 'CLOSED', style: TextStyle(fontWeight: FontWeight.bold, color: isOpen(x) ? Colors.green : Colors.grey))),
        const Text('Indicative session hours only; holidays and daylight-saving changes may affect hours. Crypto trades 24/7.', style: TextStyle(fontSize: 11)),
      ]))),
    ]));
  }

  Widget _mtfCard() {
    Color col(int side) => side == 1 ? Colors.green : side == -1 ? Colors.red : Colors.grey;
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Signals by timeframe', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      for (final tf in mtfList)
        Builder(builder: (_) {
          final a = mtf[tf];
          return ListTile(
            contentPadding: EdgeInsets.zero, dense: true,
            selected: marketInterval == tf,
            onTap: () { setState(() => marketInterval = tf); loadMarket(); },
            title: Text(tf, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(a == null ? (mtfBusy ? 'Loading...' : 'No data') : 'Buy ${a.buys} / Neutral ${a.neutrals} / Sell ${a.sells}'),
            trailing: Text(a == null ? '-' : a.verdict, style: TextStyle(fontWeight: FontWeight.bold, color: a == null ? Colors.grey : col(a.side))),
          );
        }),
      const Text('Tap a timeframe to open its chart. Updates every 30 seconds.', style: TextStyle(fontSize: 11)),
    ])));
  }

  Widget _section(String title, List<Reading> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    Color? col(int s) => s == 1 ? Colors.green : s == -1 ? Colors.red : null;
    String lab(int s) => s == 1 ? 'BUY' : s == -1 ? 'SELL' : 'NEUTRAL';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 10, bottom: 2), child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
      for (final r in rows)
        _indicatorRow(r.name, title == 'Levels' ? r.value : '${r.value}  ${lab(r.sig)}', col(r.sig)),
    ]);
  }

  Widget _finalCall(Analysis a) {
    final d = decimalsFor(marketSymbol, a.last);
    String f(double v) => v.toStringAsFixed(d);
    final side = a.side;
    final why = <String>[];
    var pts = 0;
    why.add(a.adx.isNaN
        ? '• Trend strength unknown'
        : a.adx > 25
            ? '• Strong trend (ADX ${a.adx.toStringAsFixed(0)}): trend indicators count more'
            : a.adx < 20
                ? '• Ranging market (ADX ${a.adx.toStringAsFixed(0)}): oscillators count more'
                : '• Moderate trend (ADX ${a.adx.toStringAsFixed(0)})');
    final idx = mtfList.indexOf(marketInterval);
    for (final tf in mtfList.skip(idx + 1).take(2)) {
      final h = mtf[tf];
      if (h == null) continue;
      if (side != 0 && h.side == side) {
        pts++;
        why.add('✔ $tf agrees (${h.verdict})');
      } else if (side != 0 && h.side == -side) {
        pts--;
        why.add('✖ $tf disagrees (${h.verdict})');
      } else {
        why.add('• $tf is ${h.verdict}');
      }
    }
    if (side != 0 && a.atr > 0) {
      final wall = side == 1 ? a.res : a.sup;
      final floor = side == 1 ? a.sup : a.res;
      if (wall.isNotEmpty && (wall.first - a.last).abs() / a.atr < 1.0) {
        pts--;
        why.add('✖ ${side == 1 ? 'Resistance' : 'Support'} ${f(wall.first)} is very close');
      }
      if (floor.isNotEmpty && (a.last - floor.first).abs() / a.atr < 0.8) {
        pts++;
        why.add('✔ Price is next to ${side == 1 ? 'support' : 'resistance'} ${f(floor.first)}');
      }
    }
    if (news.isNotEmpty) {
      final ns = newsScore(marketSymbol);
      if (ns >= 2) {
        if (side == 1) pts++;
        if (side == -1) pts--;
        why.add('${side == -1 ? '✖' : side == 1 ? '✔' : '•'} News is bullish (score $ns)');
      } else if (ns <= -2) {
        if (side == -1) pts++;
        if (side == 1) pts--;
        why.add('${side == 1 ? '✖' : side == -1 ? '✔' : '•'} News is bearish (score $ns)');
      } else {
        why.add('• News is mixed (score $ns)');
      }
    }
    if (futMetaSym == marketSymbol && futMeta.isNotEmpty) {
      final fr = futMeta['funding'];
      if (fr != null) {
        if (side == 1 && fr > 0.05) {
          pts--;
          why.add('✖ Funding ${fr.toStringAsFixed(3)}%: crowded longs');
        } else if (side == -1 && fr < -0.05) {
          pts--;
          why.add('✖ Funding ${fr.toStringAsFixed(3)}%: crowded shorts');
        } else {
          why.add('• Funding ${fr.toStringAsFixed(3)}%');
        }
      }
      if (futMeta['ls'] != null) why.add('• Long/short accounts ${futMeta['ls']!.toStringAsFixed(2)}');
      if (futMeta['oi'] != null) why.add('• Open interest ${compactNum(futMeta['oi']!)} coins');
    }
    final fg = fng;
    if (fg != null && !yahooPairs.containsKey(marketSymbol)) why.add('• Crypto Fear & Greed ${fg['value']} (${fg['label']})');
    final ev = eventSoon(marketSymbol);
    String call;
    Color col;
    if (ev != null) {
      call = 'WAIT: ${ev.country} ${ev.title} ${untilText(ev.time)}';
      col = Colors.orange;
    } else if (side == 0) {
      call = 'NEUTRAL: no clear edge';
      col = Colors.grey;
    } else {
      final conf = (a.score.abs() >= .5 && pts >= 1) || pts >= 2 ? 'HIGH' : pts >= 0 ? 'MEDIUM' : 'LOW';
      call = '${side == 1 ? 'BUY' : 'SELL'}: $conf confidence';
      col = side == 1 ? Colors.green : Colors.red;
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: col, width: 2), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Final call (indicators + timeframes + chart levels + news)', style: TextStyle(fontSize: 11)),
        Text(call, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: col)),
        const SizedBox(height: 4),
        for (final w in why) Text(w, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  Widget _indicatorPanel(Analysis a) {
    final d = decimalsFor(marketSymbol, a.last);
    final col = a.side == 1 ? Colors.green : a.side == -1 ? Colors.red : Colors.grey;
    String f(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(d);
    String plan;
    List<double>? tpl;
    var tp1 = 0.0;
    if (a.side == 0 || a.atr.isNaN) {
      plan = 'No clear trade: indicators are mixed';
    } else {
      tpl = tradePlan(a);
      tp1 = a.last + a.side * (a.last - tpl[0]).abs();
      plan = '${a.side == 1 ? 'BUY' : 'SELL'} ${f(a.last)} | SL ${f(tpl[0])} | TP1 ${f(tp1)} (1R) | TP2 ${f(tpl[1])} | R:R 1:${tpl[2].toStringAsFixed(1)}';
    }
    final plan2 = tpl;
    final dirName = a.side == 1 ? 'BUY' : 'SELL';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _finalCall(a),
      if (plan2 != null)
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(onPressed: () => addAlert(marketSymbol, tp1, '$dirName plan: TP1 reached'), icon: const Icon(Icons.add_alert, size: 16), label: const Text('Alert TP1')),
          OutlinedButton.icon(onPressed: () => addAlert(marketSymbol, plan2[1], '$dirName plan: TP2 reached'), icon: const Icon(Icons.add_alert, size: 16), label: const Text('Alert TP2')),
          OutlinedButton.icon(onPressed: () => addAlert(marketSymbol, plan2[0], '$dirName plan: stop loss hit'), icon: const Icon(Icons.add_alert, size: 16), label: const Text('Alert SL')),
        ]),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(border: Border.all(color: col), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$marketInterval: ${a.verdict}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: col)),
          Text('Buy ${a.buys}  Neutral ${a.neutrals}  Sell ${a.sells}  (${a.total} indicators)'),
          const SizedBox(height: 4),
          Text(plan, style: TextStyle(fontWeight: FontWeight.w600, color: a.side == 0 ? null : col)),
        ]),
      ),
      _section('Moving averages and trend', a.ma),
      _section('Oscillators and momentum', a.osc),
      _section('Levels', a.info),
      const Padding(padding: EdgeInsets.only(top: 8), child: Text('Calculated from the last 300 candles. Support and resistance are swing levels read from the chart (green and red dashed lines). Stop and target use those levels when they are close, otherwise 1.5x ATR and 2x risk. Not a guaranteed signal. Gold, forex and oil are closed on weekends. Forex has no real volume, so volume indicators (VWAP, MFI, OBV) only appear for crypto, gold and oil.', style: TextStyle(fontSize: 11))),
    ]);
  }

  Widget _indicatorRow(String name, String value, Color? color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(name)),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: TextStyle(fontWeight: FontWeight.w600, color: color),
              ),
            ),
          ],
        ),
      );

  Widget wrap(List<Widget> children) {
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: children,
      ),
    );
  }

  Widget message(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      );

  Widget scannerTab() {
    final rows = scanRows.where((r) => scanFilter == 'All' || (scanFilter == 'BUY' && r.a.side == 1) || (scanFilter == 'SELL' && r.a.side == -1) || (scanFilter == 'NEUTRAL' && r.a.side == 0) || r.a.verdict == scanFilter).toList();
    if (scanSort == 'Strength') {
      rows.sort((a, b) => b.a.score.abs().compareTo(a.a.score.abs()));
    } else if (scanSort == '24h %') {
      rows.sort((a, b) => b.change.abs().compareTo(a.change.abs()));
    } else {
      rows.sort((a, b) => b.volume.compareTo(a.volume));
    }
    final gain = [...movers]..sort((a, b) => (b['chg'] as double).compareTo(a['chg'] as double));
    final lose = [...movers]..sort((a, b) => (a['chg'] as double).compareTo(b['chg'] as double));
    Color col(int side) => side == 1 ? Colors.green : side == -1 ? Colors.red : Colors.grey;
    return Builder(builder: (ctx) {
      return RefreshIndicator(
        onRefresh: runScan,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
          Text('Binance Futures scanner', style: Theme.of(ctx).textTheme.titleMedium),
          Text(futSymbols.isEmpty ? (futuresError ?? 'Loading the coin list...') : '${futSymbols.length} USDT perpetual coins. Scans the most active ones with all indicators.', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [for (final t in ['5m', '15m', '30m', '1h', '4h', '1d']) ChoiceChip(label: Text(t), selected: scanTf == t, onSelected: (_) => setState(() => scanTf = t))]),
          Wrap(spacing: 8, children: [
            for (final n in [20, 50, 100, 999]) ChoiceChip(label: Text(n == 999 ? 'All coins' : 'Top $n'), selected: scanN == n, onSelected: (_) => setState(() => scanN = n)),
          ]),
          Wrap(spacing: 8, children: [for (final f in ['All', 'BUY', 'NEUTRAL', 'SELL', 'STRONG BUY', 'STRONG SELL']) ChoiceChip(label: Text(f), selected: scanFilter == f, onSelected: (_) => setState(() => scanFilter = f))]),
          Wrap(spacing: 8, children: [for (final f in ['Strength', '24h %', 'Volume']) ChoiceChip(label: Text('Sort: $f'), selected: scanSort == f, onSelected: (_) => setState(() => scanSort = f))]),
          Row(children: [
            ElevatedButton.icon(onPressed: scanning ? null : runScan, icon: const Icon(Icons.radar), label: Text(scanning ? 'Scanning...' : 'Scan now')),
            const SizedBox(width: 12),
            const Text('Auto 60s'),
            Switch(value: autoScan, onChanged: (v) {
              setState(() => autoScan = v);
              scanTimer?.cancel();
              if (v) {
                runScan();
                scanTimer = Timer.periodic(const Duration(seconds: 60), (_) => runScan());
              }
            }),
          ]),
          if (scanning) LinearProgressIndicator(value: scanProgress == 0 ? null : scanProgress),
          if (scanError != null) Padding(padding: const EdgeInsets.all(8), child: Text(scanError!, style: const TextStyle(color: Colors.orange))),
          if (scanUpdated != null) Text('Scanned ${rows.length} coins on $scanTf, ${ago(scanUpdated!.toIso8601String())}', style: const TextStyle(fontSize: 12)),
          if (movers.isNotEmpty)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('24h movers (all ${movers.length} coins)', style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final m in gain.take(6)) ActionChip(label: Text('${m['coin']} +${(m['chg'] as double).toStringAsFixed(1)}%', style: const TextStyle(color: Colors.green)), onPressed: () => openCoin('${m['coin']}', scanTf, ctx)),
              ]),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final m in lose.take(6)) ActionChip(label: Text('${m['coin']} ${(m['chg'] as double).toStringAsFixed(1)}%', style: const TextStyle(color: Colors.red)), onPressed: () => openCoin('${m['coin']}', scanTf, ctx)),
              ]),
            ]))),
          if (scanRows.isEmpty && !scanning) const Padding(padding: EdgeInsets.all(24), child: Text('Tap Scan now to check every coin on the timeframe you picked.', textAlign: TextAlign.center)),
          for (final r in rows)
            ListTile(
              dense: true,
              onTap: () => openCoin(r.coin, scanTf, ctx),
              title: Text('${r.coin}   ${fmtPrice(r.price)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('24h ${r.change >= 0 ? '+' : ''}${r.change.toStringAsFixed(1)}%  |  Buy ${r.a.buys} / Neutral ${r.a.neutrals} / Sell ${r.a.sells}'),
              trailing: Text(r.a.verdict, style: TextStyle(fontWeight: FontWeight.bold, color: col(r.a.side))),
            ),
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Verdicts come from about 45 indicators on the loaded candles. Not a guaranteed signal. Tap a coin to open its chart.', style: TextStyle(fontSize: 11))),
        ]),
      );
    });
  }

  Widget newsTab() {
    final shown = news.where((n) {
      if (newsFilter == 'Bullish') return n.score > 0;
      if (newsFilter == 'Bearish') return n.score < 0;
      if (newsFilter.startsWith('Selected')) return newsMatches(n, marketSymbol);
      return true;
    }).take(60).toList();
    final now = DateTime.now();
    final upcoming = events.where((e) => e.time.isAfter(now.subtract(const Duration(hours: 2)))).take(10).toList();
    final fg = fng;
    Color fgColor(int v) => v < 25 ? Colors.red : v < 45 ? Colors.orange : v < 55 ? Colors.grey : v < 75 ? Colors.lightGreen : Colors.green;
    return RefreshIndicator(
      onRefresh: loadNews,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(12), children: [
        Text('News and market data', style: Theme.of(context).textTheme.titleMedium),
        Text(newsUpdated == null ? 'Loading...' : 'Updated ${ago(newsUpdated!.toIso8601String())}. Sources: CoinDesk, Cointelegraph, Decrypt, FXStreet, ForexLive, CNBC, BBC Business.', style: const TextStyle(fontSize: 12)),
        if (fg != null)
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Crypto Fear & Greed: ${fg['value']} (${fg['label']})', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: (fg['value'] as int) / 100, color: fgColor(fg['value'] as int), minHeight: 8),
            if (fg['prev'] != null) Text('Yesterday: ${fg['prev']}', style: const TextStyle(fontSize: 12)),
          ]))),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('High-impact economic events', style: TextStyle(fontWeight: FontWeight.w700)),
          if (upcoming.isEmpty) const Text('None found for this week (or the calendar could not load).', style: TextStyle(fontSize: 12)),
          for (final e in upcoming)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${e.country} ${e.title}  |  ${hhmm(e.time)} (${untilText(e.time)})${e.forecast.isNotEmpty ? '  fc ${e.forecast}' : ''}${e.previous.isNotEmpty ? '  prev ${e.previous}' : ''}', style: const TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 4),
          const Text('The Final call shows WAIT when an event for the pair is within 45 minutes.', style: TextStyle(fontSize: 11)),
        ]))),
        Wrap(spacing: 8, children: [
          for (final f in ['All', 'Selected: $marketSymbol', 'Bullish', 'Bearish'])
            ChoiceChip(label: Text(f), selected: newsFilter == f || (f.startsWith('Selected') && newsFilter.startsWith('Selected')), onSelected: (_) => setState(() => newsFilter = f)),
        ]),
        if (news.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(newsError ?? 'Loading news...')),
        for (final n in shown)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(n.score > 0 ? Icons.arrow_upward : n.score < 0 ? Icons.arrow_downward : Icons.remove, color: n.score > 0 ? Colors.green : n.score < 0 ? Colors.red : Colors.grey),
            title: Text(n.title, maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text('${n.source}${n.time == null ? '' : '  |  ${ago(n.time!.toIso8601String())}'}'),
          ),
        const Padding(padding: EdgeInsets.only(top: 8), child: Text('Headline sentiment is a simple keyword count, so treat it as a hint, not a verdict.', style: TextStyle(fontSize: 11))),
      ]),
    );
  }

  Widget alertsTab() {
    final active = alerts.where((a) => !a.done).toList();
    final done = alerts.where((a) => a.done).toList().reversed.toList();
    String away(PriceAlert a) {
      final px = latestPrices[a.sym];
      if (px == null) return 'waiting for price';
      return '${((a.price - px) / px * 100).toStringAsFixed(2)}% away (now ${fmtPrice(px)})';
    }
    return ListView(padding: const EdgeInsets.all(12), children: [
      Text('Price alerts', style: Theme.of(context).textTheme.titleMedium),
      const Text('Pick a price and the app notifies you when it is reached. Prices are checked every 5 seconds (15 seconds for gold, forex and oil) while the app is running, including in the background for a while. Android can pause the app when it is fully closed or in battery saver, so keep it open for important levels. Allow notifications when asked, and exclude the app from battery optimization in Android settings.', style: TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      ElevatedButton.icon(onPressed: () => alertDialog(), icon: const Icon(Icons.add_alert), label: Text('New alert for $marketSymbol')),
      const Text('Change the coin in the Markets tab. In Markets you can also tap Alert TP1, TP2 or SL under the Final call.', style: TextStyle(fontSize: 11)),
      const SizedBox(height: 8),
      Text('Active (${active.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
      if (active.isEmpty) const Text('No active alerts.'),
      for (final a in active)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(a.above ? Icons.trending_up : Icons.trending_down, color: a.above ? Colors.green : Colors.red),
          title: Text('${a.sym} ${a.above ? 'rises to' : 'falls to'} ${fmtPrice(a.price)}'),
          subtitle: Text('${away(a)}${a.note.isEmpty ? '' : '\n${a.note}'}'),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { setState(() => alerts.remove(a)); saveAlerts(); }),
        ),
      const SizedBox(height: 8),
      Text('Triggered (${done.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
      for (final a in done)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.check_circle, color: Colors.green),
          title: Text('${a.sym} ${a.above ? 'reached' : 'dropped to'} ${fmtPrice(a.price)}'),
          subtitle: Text('${a.firedAt == null ? '' : ago(a.firedAt!.toIso8601String())}${a.note.isEmpty ? '' : '  |  ${a.note}'}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.replay), tooltip: 'Set again', onPressed: () { setState(() => alerts.remove(a)); addAlert(a.sym, a.price, a.note); }),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { setState(() => alerts.remove(a)); saveAlerts(); }),
          ]),
        ),
    ]);
  }

  Widget signalsTab() {
    if (data == null) {
      return wrap([message(error ?? 'Loading signals...')]);
    }
    final all = (data!['signals'] as List? ?? []).cast<Map<String, dynamic>>();
    final list = all
        .where((s) => (filter == 'All' || s['side'] == filter) && (tfFilter == 'All' || s['tf'] == tfFilter))
        .toList();
    return wrap([
      Wrap(
        spacing: 8,
        children: [
          for (final f in ['All', 'BUY', 'SELL'])
            ChoiceChip(
              label: Text(f),
              selected: filter == f,
              onSelected: (_) => setState(() => filter = f),
            ),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final f in ['All', '5m', '15m', '30m', '1h', '4h', '1d'])
            ChoiceChip(
              label: Text(f),
              selected: tfFilter == f,
              onSelected: (_) => setState(() => tfFilter = f),
            ),
        ],
      ),
      if (error != null) message(error!),
      if (list.isEmpty) message('No signals yet. The bot posts here when a setup appears.'),
      for (final s in list) signalCard(s),
    ]);
  }

  Widget signalCard(Map<String, dynamic> s) {
    final buy = s['side'] == 'BUY';
    final color = buy ? Colors.green : Colors.red;
    final agree = (s['agree'] as num?)?.toInt() ?? 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(buy ? Icons.arrow_upward : Icons.arrow_downward, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${s['side']} ${s['symbol']}',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600, color: color)),
                ),
                Text(agree > 1 ? '$agree agree' : '',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Text('${s['strategy']} (${s['tf']}) - ${s['style']}${s['grade'] == 'experimental' ? '  [experimental]' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            Text('Entry ${fmt(s['entry'])}   SL ${fmt(s['sl'])}   TP ${fmt(s['tp'])}'),
            const SizedBox(height: 4),
            Text('${s['why']}', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Text(ago(s['time']), style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Future<String?> fetchPaperCsv() async {
    try {
      final url = feedUrl.replaceAll('feed.json', 'paper_log.csv');
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        toast('Log not found yet (HTTP ${r.statusCode}). It appears after the updated bot has run once and closed a trade.');
        return null;
      }
      return utf8.decode(r.bodyBytes);
    } catch (e) {
      toast('Could not download the log: $e');
      return null;
    }
  }

  Future<void> shareLog() async {
    final csv = await fetchPaperCsv();
    if (csv == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/paper_trading_log.csv');
      await f.writeAsString(csv);
      await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')], subject: 'Paper trading log');
    } catch (e) {
      toast('Could not share the file: $e');
    }
  }

  Future<void> copyLog() async {
    final csv = await fetchPaperCsv();
    if (csv == null) return;
    await Clipboard.setData(ClipboardData(text: csv));
    toast('Copied ${csv.trim().split('\n').length - 1} trades to the clipboard. Paste them into a chat or note.');
  }

  Widget exportCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Paper trading log', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Every virtual trade as a CSV file: entry, stop, target, exit and reason, result in R, best and worst move after entry, plus ADX, RSI, news mood, 4h trend, hour and weekday at the time of the signal. Send it to tune the bot.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            ElevatedButton.icon(onPressed: shareLog, icon: const Icon(Icons.download), label: const Text('Download / share CSV')),
            OutlinedButton.icon(onPressed: copyLog, icon: const Icon(Icons.copy), label: const Text('Copy to clipboard')),
          ]),
          const SizedBox(height: 6),
          const Text('Also available in your GitHub repo at docs/paper_log.csv (open the file, then Download raw file).', style: TextStyle(fontSize: 11)),
        ]),
      ),
    );
  }

  Widget accountTab() {
    if (data == null) return wrap([message(error ?? 'Loading...')]);
    final p = (data!['paper'] as Map?)?.cast<String, dynamic>() ?? {};
    if (p.isEmpty) return wrap([message('Paper account starts after the first signal.'), exportCard()]);
    final eq = num0(p['equity']);
    final start = num0(p['start']);
    final pct = start > 0 ? (eq / start - 1) * 100 : 0;
    final strategies = (p['strategies'] as List? ?? []).cast<Map<String, dynamic>>();
    return wrap([
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Paper account (virtual money)'),
              Text('\$${eq.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
              Text('${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%   '
                  '${p['open']} open, ${p['closed']} closed'),
            ],
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text('Results by strategy', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      if (strategies.isEmpty) message('No closed trades yet.'),
      for (final s in strategies)
        ListTile(
          dense: true,
          title: Text('${s['name']}'),
          subtitle: Text('${s['trades']} trades, ${s['win']}% wins'),
          trailing: Text('${num0(s['r']) >= 0 ? '+' : ''}${s['r']} R',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: num0(s['r']) >= 0 ? Colors.green : Colors.red)),
        ),
      exportCard(),
    ]);
  }

  Widget reportTab() {
    if (data == null) return wrap([message(error ?? 'Loading...')]);
    final text = '${data!['report'] ?? ''}';
    return wrap([
      if (text.isEmpty)
        message('The daily report appears here after 06:00 UTC.')
      else
        SelectableText(text, style: const TextStyle(height: 1.5)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Signal Bot'),
          actions: [
            if (loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), onPressed: load),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Markets'),
            Tab(text: 'Scanner'),
            Tab(text: 'Signals'),
            Tab(text: 'News'),
            Tab(text: 'Alerts'),
            Tab(text: 'Account'),
            Tab(text: 'Report'),
          ]),
        ),
        body: Column(
          children: [
            if (data != null && '${data!['updated']}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Updated ${ago(data!['updated'])}', style: const TextStyle(fontSize: 12)),
              ),
            Expanded(
              child: TabBarView(children: [marketTab(), scannerTab(), signalsTab(), newsTab(), alertsTab(), accountTab(), reportTab()]),
            ),
            const Padding(
              padding: EdgeInsets.all(6),
              child: Text('Analysis only, not financial advice.', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}


class Candle {
  final DateTime time;
  final double open, high, low, close, volume;
  Candle(this.time, this.open, this.high, this.low, this.close, [this.volume = 0]);
}

class CandlePainter extends CustomPainter {
  final List<Candle> candles;
  final bool dark;
  final List<double> sup, res;
  CandlePainter(this.candles, this.dark, [this.sup = const [], this.res = const []]);
  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;
    final minV = candles.map((c)=>c.low).reduce(math.min);
    final maxV = candles.map((c)=>c.high).reduce(math.max);
    final range = (maxV-minV).abs() < 1e-9 ? 1.0 : maxV-minV;
    final pad = 12.0;
    double y(double v) => size.height-pad-(v-minV)/range*(size.height-pad*2);
    final grid = Paint()..color = (dark ? Colors.white : Colors.black).withOpacity(.12)..strokeWidth=1;
    for (int i=0;i<5;i++) { final yy=pad+(size.height-pad*2)*i/4; canvas.drawLine(Offset(0,yy),Offset(size.width,yy),grid); }
    final step = size.width/candles.length;
    final bodyW = math.max(2.0, step*.62);
    for (int i=0;i<candles.length;i++) {
      final c=candles[i]; final x=step*(i+.5); final color=c.close>=c.open?Colors.green:Colors.red;
      final wick=Paint()..color=color..strokeWidth=1.2;
      canvas.drawLine(Offset(x,y(c.high)),Offset(x,y(c.low)),wick);
      final top=math.min(y(c.open),y(c.close)); final bottom=math.max(y(c.open),y(c.close));
      final rect=Rect.fromLTRB(x-bodyW/2,top,x+bodyW/2,math.max(top+1,bottom));
      canvas.drawRect(rect,Paint()..color=color);
    }
    final tp=TextPainter(textDirection: TextDirection.ltr);
    void level(double v, Color col) {
      if (v < minV || v > maxV) return;
      final yy = y(v);
      final p = Paint()..color = col.withOpacity(.75)..strokeWidth = 1;
      for (double x = 0; x < size.width; x += 10) { canvas.drawLine(Offset(x, yy), Offset(math.min(x + 5, size.width), yy), p); }
      tp.text = TextSpan(text: fmtPrice(v), style: TextStyle(fontSize: 10, color: col));
      tp.layout();
      tp.paint(canvas, Offset(size.width - tp.width - 2, yy - 12));
    }
    for (final v in sup) { level(v, Colors.green); }
    for (final v in res) { level(v, Colors.red); }
    tp.text=TextSpan(text:fmtPrice(maxV),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,0));
    tp.text=TextSpan(text:fmtPrice(minV),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,size.height-14));
  }
  @override
  bool shouldRepaint(covariant CandlePainter oldDelegate) => true;
}

extension TakeLastList<E> on List<E> {
  List<E> takeLast(int count) => skip(math.max(0, length-count)).toList();
}
