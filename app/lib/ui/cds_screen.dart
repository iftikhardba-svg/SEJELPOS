/// The customer order board — a device whose role is `cds`.
///
/// Two lanes, order numbers listed vertically: Preparing on the left, Ready
/// on the right — the fast-food pattern. A read-only projection of the same
/// `/kds/queue` the kitchen reads, so board and kitchen can never disagree.
/// Preparing tiles carry the kitchen's traffic light on their left edge,
/// using the same thresholds as the KDS screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../sync/sync_api.dart';
import 'kds_screen.dart' show ageColor;

class CdsScreen extends StatefulWidget {
  const CdsScreen({
    super.key,
    required this.api,
    this.brandName = 'Fatima Restaurant',
    this.brandNameAr = 'مطعم فاطمة',
    this.vatNumber = '310000000000003',
    this.pollInterval = const Duration(seconds: 4),
  });

  final SyncApi api;
  final String brandName;
  final String brandNameAr;
  final String vatNumber;
  final Duration pollInterval;

  @override
  State<CdsScreen> createState() => _CdsScreenState();
}

class _CdsScreenState extends State<CdsScreen> {
  List<Map<String, dynamic>> _preparing = const [];
  List<Map<String, dynamic>> _ready = const [];
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
      final body = await widget.api.kdsQueue();
      if (!mounted) return;
      setState(() {
        _preparing = _tickets(body['open']);
        _ready = _tickets(body['done']);
      });
    } on Exception {
      // A customer board on a blip keeps showing what it knew; there is
      // nobody standing at it who could act on an error message.
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const green = Color(0xFF0E9384);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  Text(widget.brandNameAr,
                      textDirection: TextDirection.rtl,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w800)),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(widget.brandName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15, color: scheme.onSurfaceVariant)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _lane(
                      title: 'Preparing',
                      titleAr: 'جاري التحضير',
                      color: scheme.onSurfaceVariant,
                      tiles: [
                        for (final t in _preparing)
                          _numberTile(t, scheme, ready: false),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _lane(
                      title: 'Ready',
                      titleAr: 'جاهز للاستلام',
                      color: green,
                      tiles: [
                        for (final t in _ready)
                          _numberTile(t, scheme, ready: true),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Please collect your order when your number turns green',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  Text('VAT ${widget.vatNumber}',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lane({
    required String title,
    required String titleAr,
    required Color color,
    required List<Widget> tiles,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800, color: color)),
              const SizedBox(width: 10),
              Text(titleAr,
                  textDirection: TextDirection.rtl,
                  style: TextStyle(fontSize: 15, color: color)),
              const Spacer(),
              Text('${tiles.length}',
                  style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ],
          ),
        ),
        Divider(color: color, thickness: 2, height: 8),
        Expanded(
          child: tiles.isEmpty
              ? const Center(child: Text('—'))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final tile in tiles)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: tile,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _numberTile(Map<String, dynamic> t, ColorScheme scheme,
      {required bool ready}) {
    const green = Color(0xFF0E9384);
    final number = '${t['order_no'] ?? '—'}';

    if (ready) {
      return Container(
        decoration: BoxDecoration(
          color: green,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(number,
              style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
        ),
      );
    }

    // The age stripe is a child, not a border side: Flutter only allows a
    // borderRadius on uniform borders, and the rounded tile matters.
    final band = ageColor(_ageSeconds(t), scheme);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 6, color: band),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(number,
                      style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
