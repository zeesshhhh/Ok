import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const feedUrl = String.fromEnvironment('FEED_URL');

final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await notifications.initialize(initSettings);
  await notifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  runApp(const SignalApp());
}

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
  Set<String>? knownSignalIds;

  String signalId(Map<String, dynamic> s) =>
      '${s['symbol']}|${s['side']}|${s['strategy']}|${s['time']}';

  Future<void> notifyNewSignal(Map<String, dynamic> s) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'new_signals',
        'New trading signals',
        channelDescription: 'Alerts when the Signal Bot feed receives a new signal',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    final side = '${s['side'] ?? 'SIGNAL'}';
    await notifications.show(
      signalId(s).hashCode & 0x7fffffff,
      '$side ${s['symbol'] ?? ''}',
      '${s['strategy'] ?? 'New signal'} · Entry ${s['entry'] ?? '-'} · SL ${s['sl'] ?? '-'} · TP ${s['tp'] ?? '-'}',
      details,
    );
  }

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
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
      final newData = jsonDecode(r.body) as Map<String, dynamic>;
      final newSignals = (newData['signals'] as List? ?? [])
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
      final currentIds = newSignals.map(signalId).toSet();
      final previousIds = knownSignalIds;
      if (previousIds != null) {
        for (final signal in newSignals.reversed) {
          if (!previousIds.contains(signalId(signal))) {
            await notifyNewSignal(signal);
          }
        }
      }
      knownSignalIds = currentIds;
      data = newData;
      error = null;
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

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
      length: 3,
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
          bottom: const TabBar(tabs: [
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
              child: TabBarView(children: [signalsTab(), accountTab(), reportTab()]),
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
