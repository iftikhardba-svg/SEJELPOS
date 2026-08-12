/// The kitchen display — a device whose role is `kds`.
///
/// Reads the same `/kds/queue` the customer board reads, filtered to this
/// device's station when it is pinned to one. Ageing follows the kitchen's
/// rule everywhere in this product: green under 3:00, yellow from 3:00 to
/// 4:59, red at 5:00 — and the mockups, this screen and the CDS board all
/// share those exact thresholds.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../sync/sync_api.dart';

/// Seconds → age band. One function so KDS and CDS can never disagree.
Color ageColor(int seconds, ColorScheme scheme) {
  if (seconds >= 300) return scheme.error;
  if (seconds >= 180) return const Color(0xFFA16207); // true yellow band
  return const Color(0xFF0E9384); // green
}

class KdsScreen extends StatefulWidget {
  const KdsScreen({
    super.key,
    required this.api,
    this.stationNo,
    this.stationNames = const {},
    this.pollInterval = const Duration(seconds: 4),
  });

  final SyncApi api;
  final int? stationNo;
  final Map<int, String> stationNames;
  final Duration pollInterval;

  @override
  State<KdsScreen> createState() => _KdsScreenState();
}

class _KdsScreenState extends State<KdsScreen> {
  /// The station tab in view. Null is "All".
  ///
  /// A device pinned at enrolment starts on its own station; an unpinned one
  /// starts on All. Either way the cook can switch, because a kitchen that
  /// cannot see the other stations cannot see why its own is waiting.
  int? _tab;

  List<Map<String, dynamic>> _open = const [];
  List<Map<String, dynamic>> _done = const [];
  String? _error;
  Timer? _poll;
  Timer? _clock;
  DateTime _now = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    _tab = widget.stationNo;
    _refresh();
    _poll = Timer.periodic(widget.pollInterval, (_) => _refresh());
    _clock = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _now = DateTime.now().toUtc()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      // The whole branch's queue, filtered on screen. Asking the server for
      // one station would make the tabs a lie — they would each show the
      // same thing.
      final body = await widget.api.kdsQueue();
      if (!mounted) return;
      setState(() {
        _open = _tickets(body['open']);
        _done = _tickets(body['done']);
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      // The kitchen keeps its last known rail on a blip — a flashing empty
      // screen mid-service is worse than slightly stale tickets.
      setState(() => _error = '$e');
    }
  }

  static List<Map<String, dynamic>> _tickets(Object? v) => [
        for (final t in (v as List? ?? const []))
          (t as Map).cast<String, dynamic>(),
      ];

  int _ageSeconds(Map<String, dynamic> ticket) {
    final created = DateTime.parse(ticket['created_at'] as String).toUtc();
    final s = _now.difference(created).inSeconds;
    return s < 0 ? 0 : s;
  }

  /// The station a line belongs to, in words. An unrouted line says so
  /// rather than showing a blank: "no station" is information, and it means
  /// Expo has it.
  String _stationChip(Map<String, dynamic> line) {
    final no = line['station_no'] as int?;
    if (no == null) return 'Expo';
    return widget.stationNames[no] ?? 'St $no';
  }

  String _mmss(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';

  Future<void> _bump(String id) async {
    await widget.api.kdsBump(id);
    await _refresh();
  }

  /// The customer took it: off this lane and off the customer board.
  Future<void> _collect(String id) async {
    await widget.api.kdsCollect(id);
    await _refresh();
  }

  Future<void> _recall(String id) async {
    await widget.api.kdsRecall(id);
    await _refresh();
  }

  /// The lines of [t] this station has to make.
  ///
  /// A line with no station is Expo's: the imported catalog routes by a
  /// PRINTLOC bitmask and 0 means "nobody prints it", which in this kitchen
  /// is the pass. Dropping those lines would hide whole items from the only
  /// screen that assembles an order.
  List<Map<String, dynamic>> _linesFor(Map<String, dynamic> t, int? station) {
    final lines = _tickets(t['lines']);
    if (station == null) return lines;
    return [
      for (final l in lines)
        if (l['station_no'] == station ||
            (station == _expo && (l['station_no'] as int?) == null))
          l,
    ];
  }

  /// Expo is where an unrouted line belongs. Named by the station whose name
  /// says so rather than by a number compiled in, so a kitchen that calls it
  /// something else still works.
  int? get _expo {
    for (final entry in widget.stationNames.entries) {
      if (entry.value.toLowerCase().contains('expo')) return entry.key;
    }
    return null;
  }

  List<Map<String, dynamic>> get _shown => [
        for (final t in _open) if (_linesFor(t, _tab).isNotEmpty) t,
      ];

  String _stationName(int? no) => no == null
      ? 'All stations'
      : widget.stationNames[no] ?? 'Station $no';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown;
    final late = shown.where((t) => _ageSeconds(t) >= 300).length;
    final avg = shown.isEmpty
        ? null
        : shown.map(_ageSeconds).reduce((a, b) => a + b) ~/ shown.length;
    final station = _stationName(_tab);

    return Scaffold(
      appBar: AppBar(
        title: Text('Kitchen — $station'),
        actions: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Icon(Icons.cloud_off, color: scheme.error),
              ),
            ),
          _tile('${shown.length}', 'Open', scheme),
          _tile(avg == null ? '—' : _mmss(avg), 'Avg wait', scheme),
          _tile('$late', 'Late \u2265 5 min', scheme,
              alert: late > 0),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh now',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stationTabs(scheme),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _rail(scheme, shown)),
                SizedBox(width: 220, child: _doneLane(scheme)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One of the three figures a kitchen actually runs on.
  Widget _tile(String value, String label, ColorScheme scheme,
      {bool alert = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: alert ? scheme.error : null,
              )),
          Text(label,
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// All, then every station, each carrying how many open tickets it has
  /// work in — the count is what tells a cook where the queue actually is.
  Widget _stationTabs(ColorScheme scheme) {
    final stations = widget.stationNames.keys.toList()..sort();
    Widget tab(int? no) {
      final count = _open.where((t) => _linesFor(t, no).isNotEmpty).length;
      final selected = no == _tab;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => setState(() => _tab = no),
          label: Text('${_stationName(no)}  $count'),
        ),
      );
    }

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        children: [tab(null), for (final no in stations) tab(no)],
      ),
    );
  }

  Widget _rail(ColorScheme scheme, List<Map<String, dynamic>> shown) {
    if (shown.isEmpty) {
      return Center(
        child: Text(_tab == null
            ? 'No open tickets'
            : 'No open tickets for ${_stationName(_tab)}'),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisExtent: 240,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: shown.length,
      itemBuilder: (context, i) => _ticketCard(shown[i], scheme),
    );
  }

  Widget _ticketCard(Map<String, dynamic> t, ColorScheme scheme) {
    final age = _ageSeconds(t);
    final band = ageColor(age, scheme);
    final lines = _linesFor(t, _tab);
    final isAggregator = t['external_ref'] != null;
    // Solid once there is nothing left to tick: the cook should be able to
    // see a finished ticket across the kitchen without reading it.
    final ready = lines.every((l) => l['done'] == true);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: band, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('#${t['order_no'] ?? '—'}',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(_mmss(age),
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: band)),
              ],
            ),
            Text(
              [
                if (t['sale_type_name'] != null) t['sale_type_name'],
                if (t['table_no'] != null) 'Table ${t['table_no']}',
                if (isAggregator) t['external_ref'],
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final l in lines)
                    CheckboxListTile(
                      dense: true,
                      // Chosen and included items sit under the item they came
                      // out of. Flat, a cook reading "PEPSI" has four open
                      // meals to guess between.
                      contentPadding: EdgeInsets.only(
                          left: l['parent_line_no'] == null ? 0 : 20),
                      controlAffinity: ListTileControlAffinity.leading,
                      value: l['done'] == true,
                      onChanged: (v) async {
                        await widget.api
                            .kdsLineDone(l['id'] as String, done: v ?? false);
                        await _refresh();
                      },
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${(l['qty'] as num).toStringAsFixed(0)}× '
                              '${l['line_des']}',
                              style: TextStyle(
                                fontSize: 13,
                                decoration: l['done'] == true
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          // Which station owns the line, but only on All —
                          // on a station's own tab every chip would say the
                          // same word.
                          if (_tab == null)
                            Text(
                              _stationChip(l),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                      subtitle: l['note'] == null
                          ? null
                          : Text(l['note'] as String,
                              style: const TextStyle(
                                  fontStyle: FontStyle.italic, fontSize: 11)),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ready
                  ? FilledButton(
                      onPressed: () => _bump(t['id'] as String),
                      child: Text('Bump #${t['order_no'] ?? ''}'),
                    )
                  : OutlinedButton(
                      onPressed: () => _bump(t['id'] as String),
                      child: Text('Bump #${t['order_no'] ?? ''}'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _doneLane(ColorScheme scheme) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text('Done · last ${_done.length}',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: _done.isEmpty
                ? const Center(child: Text('—'))
                : ListView(
                    children: [
                      for (final t in _done)
                        ListTile(
                          dense: true,
                          title: Text('#${t['order_no'] ?? '—'}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          subtitle: TextButton(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              alignment: Alignment.centerLeft,
                              minimumSize: const Size(0, 28),
                            ),
                            // Handed over: it leaves this lane and the
                            // customer board with it. Recall is still there
                            // for the press that was a mistake.
                            onPressed: () => _collect(t['id'] as String),
                            child: const Text('Delivered'),
                          ),
                          trailing: TextButton(
                            onPressed: () => _recall(t['id'] as String),
                            child: const Text('Recall'),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
