import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:math' as math;

const feedUrl = String.fromEnvironment('FEED_URL');

void main() => runApp(const SignalApp());

double num0(dynamic v) => (v as num?)?.toDouble() ?? 0;

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

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => load());
    loadMarket();
    marketTimer = Timer.periodic(const Duration(minutes: 1), (_) => loadMarket());
  }

  @override
  void dispose() {
    timer?.cancel();
    marketTimer?.cancel();
    super.dispose();
  }

  Future<void> loadMarket() async {
    if (marketLoading) return;
    if (mounted) setState(() { marketLoading = true; marketError = null; });
    try {
      final symbols = marketSymbol == 'SILVER'
          ? <String, String>{'SILVER': 'XAGUSD=X'}
          : <String, String>{'BTC': 'BTCUSDT', 'ETH': 'ETHUSDT', 'SOL': 'SOLUSDT'};
      if (marketSymbol == 'SILVER') {
        final uri = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/XAGUSD%3DX?range=1d&interval=1m');
        final response = await http.get(uri, headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) throw 'Silver data unavailable (HTTP ${response.statusCode}). Free source may be rate-limited.';
        final root = jsonDecode(response.body)['chart']['result'][0];
        final times = (root['timestamp'] as List?) ?? [];
        final q = root['indicators']['quote'][0];
        final os = q['open'] as List? ?? [], hs = q['high'] as List? ?? [], ls = q['low'] as List? ?? [], cs = q['close'] as List? ?? [];
        final list = <Candle>[];
        for (var i=0; i<times.length; i++) {
          if ([os[i],hs[i],ls[i],cs[i]].any((v) => v == null)) continue;
          list.add(Candle(DateTime.fromMillisecondsSinceEpoch((times[i] as num).toInt()*1000), (os[i] as num).toDouble(), (hs[i] as num).toDouble(), (ls[i] as num).toDouble(), (cs[i] as num).toDouble()));
        }
        candles['SILVER'] = list.takeLast(60).toList();
        if (list.isNotEmpty) latestPrices['SILVER'] = list.last.close;
      } else {
        final symbol = symbols[marketSymbol] ?? 'BTCUSDT';
        final uri = Uri.https('api.binance.com', '/api/v3/klines', {'symbol': symbol, 'interval': marketInterval, 'limit': '60'});
        final response = await http.get(uri).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) throw 'Market data unavailable (HTTP ${response.statusCode}).';
        final rows = jsonDecode(response.body) as List;
        final list = rows.map((r) => Candle(DateTime.fromMillisecondsSinceEpoch((r[0] as num).toInt()), double.parse(r[1].toString()), double.parse(r[2].toString()), double.parse(r[3].toString()), double.parse(r[4].toString()))).toList();
        candles[marketSymbol] = list;
        if (list.isNotEmpty) latestPrices[marketSymbol] = list.last.close;
      }
      marketUpdated = DateTime.now();
    } catch (e) {
      marketError = '$e';
    } finally {
      if (mounted) setState(() => marketLoading = false);
    }
  }

  Future<void> load() async {
    if (feedUrl.isEmpty) {
      setState(() => error = 'FEED_URL was not set when the app was built.');
      return;
    }
    setState(() => loading = true);
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
    final list = candles[marketSymbol] ?? <Candle>[];
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
      Wrap(spacing: 8, children: [for (final a in ['BTC','ETH','SOL','SILVER']) ChoiceChip(label: Text(a), selected: marketSymbol==a, onSelected: (_) { setState(() => marketSymbol=a); loadMarket(); })]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [for (final tf in ['1m','5m','15m','1h']) if (marketSymbol!='SILVER') ChoiceChip(label: Text(tf), selected: marketInterval==tf, onSelected: (_) { setState(() => marketInterval=tf); loadMarket(); })]),
      const SizedBox(height: 10),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(marketSymbol, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(price == null ? 'Price unavailable' : '\$${price.toStringAsFixed(marketSymbol=='SILVER'?3:2)}', style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700)),
        Text('Free public data • Last update: ${marketUpdated == null ? 'not yet' : ago(marketUpdated!.toIso8601String())}'),
        const SizedBox(height: 12),
        if (marketLoading) const LinearProgressIndicator(),
        if (marketError != null) Text(marketError!, style: const TextStyle(color: Colors.orange)),
        if (list.length > 1) SizedBox(height: 260, child: CustomPaint(painter: CandlePainter(list, Theme.of(context).brightness==Brightness.dark), child: const SizedBox.expand())) else const SizedBox(height: 200, child: Center(child: Text('Waiting for candlestick data...'))),
        const Text('Candles show open, high, low and close. Free APIs may delay or limit data.', style: TextStyle(fontSize: 11)),
        const SizedBox(height: 14),
        Text('Technical indicators', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (list.length >= 15) _indicatorPanel(list) else const Text('More candles are needed to calculate indicators.'),
      ]))),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Market sessions • Pakistan time (UTC+5)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final x in sessions) ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(x['name'] as String), subtitle: Text('${hm((x['start'] as int) ~/ 60, (x['start'] as int)%60)} – ${hm((x['end'] as int) ~/ 60, (x['end'] as int)%60)} PKT'), trailing: Text(isOpen(x) ? 'OPEN' : 'CLOSED', style: TextStyle(fontWeight: FontWeight.bold, color: isOpen(x) ? Colors.green : Colors.grey))),
        const Text('Indicative session hours only; holidays and daylight-saving changes may affect hours. Crypto trades 24/7.', style: TextStyle(fontSize: 11)),
      ]))),
    ]));
  }

  double _sma(List<double> values, int period) {
    if (values.length < period) return double.nan;
    return values.skip(values.length - period).reduce((a, b) => a + b) / period;
  }

  double _ema(List<double> values, int period) {
    if (values.isEmpty) return double.nan;
    final k = 2 / (period + 1);
    var result = values.take(math.min(period, values.length)).reduce((a, b) => a + b) / math.min(period, values.length);
    for (final value in values.skip(math.min(period, values.length))) {
      result = value * k + result * (1 - k);
    }
    return result;
  }

  double _rsi(List<double> closes, int period) {
    if (closes.length <= period) return double.nan;
    var gains = 0.0, losses = 0.0;
    for (var i = closes.length - period; i < closes.length; i++) {
      final change = closes[i] - closes[i - 1];
      if (change > 0) gains += change; else losses -= change;
    }
    if (losses == 0) return 100;
    final rs = (gains / period) / (losses / period);
    return 100 - (100 / (1 + rs));
  }

  Widget _indicatorPanel(List<Candle> list) {
    final closes = list.map((c) => c.close).toList();
    final last = closes.last;
    final ema20 = _ema(closes, 20);
    final sma20 = _sma(closes, 20);
    final sma50 = _sma(closes, 50);
    final rsi = _rsi(closes, 14);
    final ema12 = _ema(closes, 12);
    final ema26 = _ema(closes, 26);
    final macd = ema12 - ema26;
    final stdSlice = closes.length >= 20 ? closes.skip(closes.length - 20).toList() : closes;
    final mean = stdSlice.reduce((a, b) => a + b) / stdSlice.length;
    final variance = stdSlice.map((v) => math.pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) / stdSlice.length;
    final deviation = math.sqrt(variance);
    String val(double v) => v.isNaN || v.isInfinite ? 'N/A' : v.toStringAsFixed(marketSymbol == 'SILVER' ? 3 : 2);
    String rsiText = rsi.isNaN ? 'N/A' : '${rsi.toStringAsFixed(1)} • ${rsi >= 70 ? 'Overbought' : rsi <= 30 ? 'Oversold' : 'Neutral'}';
    final trend = last > ema20 ? 'Above EMA20 (bullish bias)' : 'Below EMA20 (bearish bias)';
    return Column(children: [
      _indicatorRow('RSI (14)', rsiText, rsi >= 70 ? Colors.orange : rsi <= 30 ? Colors.lightBlue : null),
      _indicatorRow('EMA (20)', val(ema20), last >= ema20 ? Colors.green : Colors.red),
      _indicatorRow('SMA (20)', val(sma20), null),
      _indicatorRow('SMA (50)', val(sma50), null),
      _indicatorRow('MACD (12,26)', val(macd), macd >= 0 ? Colors.green : Colors.red),
      _indicatorRow('Bollinger Bands (20,2)', '${val(mean + 2 * deviation)} / ${val(mean)} / ${val(mean - 2 * deviation)}', null),
      Padding(padding: const EdgeInsets.only(top: 6), child: Text('Quick trend: $trend. Indicators are calculated from the candles currently loaded and are not guaranteed trading signals.', style: const TextStyle(fontSize: 11))),
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
    final list =
        all.where((s) => filter == 'All' || s['side'] == filter).toList();
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
            Text('${s['strategy']} (${s['tf']}) - ${s['style']}',
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
  final double open, high, low, close;
  Candle(this.time, this.open, this.high, this.low, this.close);
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
