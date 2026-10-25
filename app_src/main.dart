import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:math' as math;

const feedUrl = String.fromEnvironment('FEED_URL');

void main() => runApp(const SignalApp());

double num0(dynamic v) => (v as num?)?.toDouble() ?? 0;

const cryptoPairs = {'BTC': 'BTCUSDT', 'ETH': 'ETHUSDT', 'SOL': 'SOLUSDT'};
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
int decimals(String sym) => sym == 'USDJPY' ? 3 : fxPairs.contains(sym) ? 5 : sym == 'SILVER' ? 3 : 2;

String fmt(dynamic v) {
  final x = num0(v);
  return x > 50 ? x.toStringAsFixed(2) : x.toStringAsFixed(5);
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


class Reading {
  final String name, value;
  final int sig; // 1 buy, -1 sell, 0 neutral
  const Reading(this.name, this.value, this.sig);
}

class Analysis {
  final List<Reading> ma, osc, info;
  final int buys, sells, neutrals;
  final double last, atr;
  Analysis(this.ma, this.osc, this.info, this.buys, this.sells, this.neutrals, this.last, this.atr);
  int get total => buys + sells + neutrals;
  double get score => total == 0 ? 0 : (buys - sells) / total;
  int get side => score >= .15 ? 1 : score <= -.15 ? -1 : 0;
  String get verdict => score >= .5 ? 'STRONG BUY' : score >= .15 ? 'BUY' : score <= -.5 ? 'STRONG SELL' : score <= -.15 ? 'SELL' : 'NEUTRAL';
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

  // ---- trend / moving averages
  for (final p in [9, 20, 50, 200]) {
    if (n >= p) {
      final e = emaSeries(c, p).last;
      ma.add(Reading('EMA $p', f(e), last > e ? 1 : -1));
    }
  }
  for (final p in [20, 50, 200]) {
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
  osc.add(Reading('RSI (14)', f1(rsi), rsi < 30 ? 1 : rsi > 70 ? -1 : 0));

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
    osc.add(Reading('Stochastic (14,3)', 'K ${f1(k)} / D ${f1(dd)}', k < 20 ? 1 : k > 80 ? -1 : 0));
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
    osc.add(Reading('CCI (20)', f1(cci), cci < -100 ? 1 : cci > 100 ? -1 : 0));
  }
  if (n >= 14) {
    var hh = -1e300, ll = 1e300;
    for (var j = n - 14; j < n; j++) {
      if (h[j] > hh) hh = h[j];
      if (l[j] < ll) ll = l[j];
    }
    final wr = hh == ll ? -50.0 : -100 * (hh - last) / (hh - ll);
    osc.add(Reading('Williams %R (14)', f1(wr), wr < -80 ? 1 : wr > -20 ? -1 : 0));
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
    osc.add(Reading('Bollinger %B (20,2)', pb.toStringAsFixed(2), pb < 0.05 ? 1 : pb > 0.95 ? -1 : 0));
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
    osc.add(Reading('MFI (14)', f1(mfi), mfi < 20 ? 1 : mfi > 80 ? -1 : 0));
    final obv = <double>[0];
    for (var i = 1; i < n; i++) {
      obv.add(obv[i - 1] + (c[i] > c[i - 1] ? v[i] : c[i] < c[i - 1] ? -v[i] : 0));
    }
    final oe = emaSeries(obv, 21).last;
    osc.add(Reading('OBV vs EMA21', obv.last > oe ? 'Rising' : 'Falling', obv.last > oe ? 1 : -1));
  }

  // ---- info
  final atr = wilder(trSeries(h, l, c), 14).last;
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
  return Analysis(ma, osc, info, b, s, z, last, atr);
}

Future<List<Candle>> fetchCandles(String sym, String tf) async {
  final cSym = cryptoPairs[sym];
  if (cSym != null) {
    final uri = Uri.https('api.binance.com', '/api/v3/klines', {'symbol': cSym, 'interval': tf, 'limit': '300'});
    final r = await http.get(uri).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw 'Market data unavailable (HTTP ${r.statusCode}).';
    return (jsonDecode(r.body) as List)
        .map((x) => Candle(DateTime.fromMillisecondsSinceEpoch((x[0] as num).toInt()), double.parse('${x[1]}'),
            double.parse('${x[2]}'), double.parse('${x[3]}'), double.parse('${x[4]}'), double.parse('${x[5]}')))
        .toList();
  }
  final ySym = yahooPairs[sym];
  if (ySym == null) throw 'Unknown symbol $sym';
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

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => load(silent: true));
    loadMarket();
    marketTimer = Timer.periodic(const Duration(seconds: 1), (_) => loadMarket(silent: true));
    loadMtf();
    mtfTimer = Timer.periodic(const Duration(seconds: 30), (_) => loadMtf());
  }

  @override
  void dispose() {
    timer?.cancel();
    marketTimer?.cancel();
    mtfTimer?.cancel();
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

  Future<void> loadMtf() async {
    if (mtfBusy) return;
    mtfBusy = true;
    final sym = marketSymbol;
    try {
      final res = await Future.wait(mtfList.map<Future<Analysis?>>((tf) async {
        try {
          final cs = await fetchCandles(sym, tf);
          return cs.length >= 35 ? analyze(cs, decimals(sym)) : null;
        } catch (_) {
          return null;
        }
      }));
      if (sym == marketSymbol) {
        mtf = {for (var i = 0; i < mtfList.length; i++) mtfList[i]: res[i]};
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
      Wrap(spacing: 8, children: [for (final a in ['BTC','ETH','SOL','GOLD','SILVER','EURUSD','GBPUSD','USDJPY','AUDUSD','USDCAD','OIL']) ChoiceChip(label: Text(a), selected: marketSymbol==a, onSelected: (_) { setState(() { marketSymbol=a; mtf = {}; }); loadMarket(); loadMtf(); })]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [for (final tf in tfList) ChoiceChip(label: Text(tf), selected: marketInterval==tf, onSelected: (_) { setState(() => marketInterval=tf); loadMarket(); })]),
      const SizedBox(height: 10),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(marketSymbol, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(price == null ? 'Price unavailable' : '${fxPairs.contains(marketSymbol) ? '' : '\$'}${price.toStringAsFixed(decimals(marketSymbol))}', style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700)),
        Text('Free public data • Last update: ${marketUpdated == null ? 'not yet' : ago(marketUpdated!.toIso8601String())}'),
        const SizedBox(height: 12),
        if (marketLoading) const LinearProgressIndicator(),
        if (marketError != null) Text(marketError!, style: const TextStyle(color: Colors.orange)),
        if (list.length > 1) SizedBox(height: 260, child: CustomPaint(painter: CandlePainter(list, Theme.of(context).brightness==Brightness.dark), child: const SizedBox.expand())) else const SizedBox(height: 200, child: Center(child: Text('Waiting for candlestick data...'))),
        const Text('Candles show open, high, low and close. Free APIs may delay or limit data.', style: TextStyle(fontSize: 11)),
        const SizedBox(height: 14),
        Text('Technical indicators', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (all.length >= 35) _indicatorPanel(all) else const Text('More candles are needed to calculate indicators.'),
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

  Widget _indicatorPanel(List<Candle> all) {
    final d = decimals(marketSymbol);
    final a = analyze(all, d);
    final col = a.side == 1 ? Colors.green : a.side == -1 ? Colors.red : Colors.grey;
    String f(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(d);
    final plan = a.side == 0 || a.atr.isNaN
        ? 'No clear trade: indicators are mixed'
        : '${a.side == 1 ? 'BUY' : 'SELL'} ${f(a.last)} | SL ${f(a.last - a.side * 1.5 * a.atr)} | TP ${f(a.last + a.side * 3 * a.atr)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
      const Padding(padding: EdgeInsets.only(top: 8), child: Text('Calculated from the last 300 candles. Not a guaranteed signal. Stop = 1.5x ATR, target = 3x ATR. Gold, forex and oil are closed on weekends. Forex has no real volume, so volume indicators (VWAP, MFI, OBV) only appear for crypto, gold and oil.', style: TextStyle(fontSize: 11))),
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

  Widget accountTab() {
    if (data == null) return wrap([message(error ?? 'Loading...')]);
    final p = (data!['paper'] as Map?)?.cast<String, dynamic>() ?? {};
    if (p.isEmpty) return wrap([message('Paper account starts after the first signal.')]);
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
      length: 4,
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
            Tab(text: 'Signals'),
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
              child: TabBarView(children: [marketTab(), signalsTab(), accountTab(), reportTab()]),
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
  CandlePainter(this.candles, this.dark);
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
    tp.text=TextSpan(text:maxV.toStringAsFixed(maxV>100?2:4),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,0));
    tp.text=TextSpan(text:minV.toStringAsFixed(minV>100?2:4),style:TextStyle(fontSize:10,color:dark?Colors.white70:Colors.black54)); tp.layout(); tp.paint(canvas,Offset(2,size.height-14));
  }
  @override
  bool shouldRepaint(covariant CandlePainter oldDelegate) => oldDelegate.candles != candles || oldDelegate.dark != dark;
}

extension TakeLastList<E> on List<E> {
  List<E> takeLast(int count) => skip(math.max(0, length-count)).toList();
}
