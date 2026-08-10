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
  List<Map<String, dynamic>> _open = const [];
  List<Map<String, dynamic>> _done = const [];
  String? _error;
  Timer? _poll;
  Timer? _clock;
  DateTime _now = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
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
      final body = await widget.api.kdsQueue(station: widget.stationNo);
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

  String _mmss(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';

  Future<void> _bump(String id) async {
    await widget.api.kdsBump(id);
    await _refresh();
  }

  Future<void> _recall(String id) async {
    await widget.api.kdsRecall(id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final late = _open.where((t) => _ageSeconds(t) >= 300).length;
    final station = widget.stationNo == null
        ? 'All stations'
        : widget.stationNames[widget.stationNo] ??
            'Station ${widget.stationNo}';

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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                '${_open.length} open · $late late',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: late > 0 ? scheme.error : null,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh now',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _rail(scheme)),
          SizedBox(width: 220, child: _doneLane(scheme)),
        ],
      ),
    );
  }

  Widget _rail(ColorScheme scheme) {
    if (_open.isEmpty) {
      return const Center(child: Text('No open tickets'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisExtent: 240,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _open.length,
      itemBuilder: (context, i) => _ticketCard(_open[i], scheme),
    );
  }

  Widget _ticketCard(Map<String, dynamic> t, ColorScheme scheme) {
    final age = _ageSeconds(t);
    final band = ageColor(age, scheme);
    final lines = _tickets(t['lines']);
    final isAggregator = t['external_ref'] != null;

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
                      title: Text(
                        '${(l['qty'] as num).toStringAsFixed(0)}× '
                        '${l['line_des']}',
                        style: TextStyle(
                          fontSize: 13,
                          decoration: l['done'] == true
                              ? TextDecoration.lineThrough
                              : null,
                        ),
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
              child: FilledButton(
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
            child: Text('Done',
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
