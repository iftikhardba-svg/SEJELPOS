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
import 'package:uuid/uuid.dart';

import '../sync/sync_api.dart';
import 'kds_screen.dart' show ageColor;

class CdsScreen extends StatefulWidget {
  const CdsScreen({
    super.key,
    required this.api,
    this.brandName = '',
    this.branchName,
    this.brandNameAr = '',
    this.vatNumber = '',
    this.pollInterval = const Duration(seconds: 4),
    this.demo = false,
    this.stationNos = const [],
  });

  final SyncApi api;

  /// The seller, the branch and the VAT number, all from the device row.
  /// Empty by default and never invented: a board carrying another
  /// restaurant's name is worse than a board carrying none.
  final String brandName;
  final String? branchName;

  /// Only when the company actually registered an Arabic name. There is no
  /// transliteration here — a guessed Arabic name on a customer-facing board
  /// is somebody else's restaurant.
  final String brandNameAr;
  final String vatNumber;
  final Duration pollInterval;

  /// The three controls the design mockup carries, driving the **real**
  /// queue: a new order becomes a kitchen ticket, a bump bumps the oldest
  /// open one, and both show up on the kitchen screen as well as here.
  /// That is the point — it demonstrates the link rather than imitating it.
  ///
  /// Off unless the app was started with `--demo`, and deliberately so: a
  /// customer display is the one screen that faces the street, and these
  /// buttons write to the kitchen. On a live board they would be buttons
  /// anybody walking past can press.
  final bool demo;

  /// The branch's kitchen stations, for demo mode only. A ticket line must
  /// name a station the kitchen actually has — the API requires one, and a
  /// number invented here would land on a screen nobody is standing at.
  final List<int> stationNos;

  @override
  State<CdsScreen> createState() => _CdsScreenState();
}

class _CdsScreenState extends State<CdsScreen> {
  List<Map<String, dynamic>> _preparing = const [];
  List<Map<String, dynamic>> _ready = const [];
  Timer? _poll;
  Timer? _clock;
  DateTime _now = DateTime.now().toUtc();

  // Demo only.
  Timer? _auto;
  bool _autoOn = false;
  String? _busy;

  @override
  void initState() {
    super.initState();
    // The board always reads the real queue. Demo mode adds controls that
    // write to it; it does not change what is shown.
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
    _auto?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ demo mode

  /// Put a real ticket on the kitchen queue.
  ///
  /// The same endpoint a till uses when it fires a round, so the kitchen
  /// screen picks it up exactly as it would a real order — and this board
  /// then shows it under Preparing because it is genuinely open.
  Future<void> _newOrder() async {
    if (_busy != null || widget.stationNos.isEmpty) return;
    setState(() => _busy = 'new');
    final no = _nextOrderNo();
    try {
      await widget.api.createKdsTicket({
        // A real UUID: the backend uses it as the idempotency key, so a
        // retried demo order is the same order and not a second one.
        'ticket_id': const Uuid().v4(),
        'order_no': no,
        'sale_type_no': 1006,
        'sale_type_name': 'Demo',
        'table_no': null,
        'external_ref': null,
        'sale_uuid': null,
        'session_id': null,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'lines': [
          {
            'line_no': 1,
            'prodnum': 0,
            'line_des': 'Demonstration order',
            'qty': 1,
            'station_no': widget.stationNos.first,
            'note': null,
            'seat_no': null,
            'parent_line_no': null,
          },
        ],
      });
    } on Exception {
      // Shown by the board staying still; there is nothing else to do here.
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _refresh();
  }

  /// A number in the demo's own range, above anything a till hands out.
  ///
  /// Order numbers come from blocks the backend reserves, and they are small.
  /// Starting demo orders at 101 keeps them out of that range: a staged order
  /// sitting next to a real one with the same number is a customer collecting
  /// somebody else's food.
  int _nextOrderNo() {
    var highest = 100;
    for (final t in [..._preparing, ..._ready]) {
      final no = t['order_no'];
      if (no is int && no > highest) highest = no;
    }
    return highest + 1;
  }

  /// The customer took it. The ticket leaves this board and the kitchen's
  /// done lane, and stays in the record as collected — a report that counts
  /// what a station produced cannot count rows somebody deleted.
  Future<void> _collect(String ticketId) async {
    if (_busy != null) return;
    setState(() => _busy = ticketId);
    try {
      await widget.api.kdsCollect(ticketId);
    } on Exception {
      // The number simply stays on the board; pressing again is safe.
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _refresh();
  }

  /// Bump the oldest open ticket — the same call the kitchen screen makes,
  /// so the ticket moves to Ready here and to Done there.
  Future<void> _bumpNext() async {
    if (_busy != null || _preparing.isEmpty) return;
    setState(() => _busy = 'bump');
    try {
      await widget.api.kdsBump(_preparing.first['id'] as String);
    } on Exception {
      // Same: the board simply does not move.
    }
    if (!mounted) return;
    setState(() => _busy = null);
    await _refresh();
  }

  void _toggleAuto() {
    setState(() {
      _autoOn = !_autoOn;
      _auto?.cancel();
      if (!_autoOn) return;
      // The mockup's own rhythm, against the real queue: an order arrives,
      // then the kitchen bumps one.
      var beat = 0;
      _auto = Timer.periodic(const Duration(seconds: 5), (_) {
        beat += 1;
        if (beat.isOdd) {
          unawaited(_newOrder());
        } else {
          unawaited(_bumpNext());
        }
      });
    });
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

  /// Local wall-clock time, which is what a customer reads. The ageing
  /// arithmetic stays in UTC.
  String _clockText() {
    final t = _now.toLocal();
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

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
            if (widget.demo) _demoBar(scheme),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  if (widget.brandNameAr.isNotEmpty) ...[
                    Text(widget.brandNameAr,
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 12),
                  ],
                  Flexible(
                    child: Text(widget.brandName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: widget.brandNameAr.isEmpty ? 22 : 15,
                          fontWeight: widget.brandNameAr.isEmpty
                              ? FontWeight.w800
                              : FontWeight.normal,
                          color: widget.brandNameAr.isEmpty
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        )),
                  ),
                  if (widget.branchName != null &&
                      widget.branchName!.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(widget.branchName!,
                        style: TextStyle(
                            fontSize: 15, color: scheme.onSurfaceVariant)),
                  ],
                  const Spacer(),
                  // The clock the mockup carries: a board with a stopped
                  // clock is the first thing a customer notices.
                  Text(_clockText(),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant)),
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
                      'Please collect your order when your number turns green '
                      '· يرجى استلام طلبك عندما يتحول رقمك إلى الأخضر',
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

  /// The three controls from the design mockup, and the sentence that keeps
  /// anyone from mistaking this board for a live one.
  Widget _demoBar(ColorScheme scheme) {
    return Container(
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          OutlinedButton(
              onPressed: _busy != null || widget.stationNos.isEmpty
                  ? null
                  : () => unawaited(_newOrder()),
              child: const Text('New order')),
          const SizedBox(width: 8),
          OutlinedButton(
              onPressed: _busy != null || _preparing.isEmpty
                  ? null
                  : () => unawaited(_bumpNext()),
              child: const Text('Kitchen bumps next')),
          const SizedBox(width: 8),
          FilterChip(
            selected: _autoOn,
            showCheckmark: false,
            onSelected: (_) => _toggleAuto(),
            label: const Text('Auto-cycle'),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _autoOn
                  ? 'Demo controls — these write to the real kitchen queue. '
                      'Orders arrive and are bumped on their own; the kitchen '
                      'screen shows the same tickets.'
                  : 'Demo controls — these write to the real kitchen queue. '
                      'A new order appears under Preparing; bumping it moves '
                      'it to Ready here and to Done on the kitchen screen.',
              style: TextStyle(
                  fontSize: 11, color: scheme.onTertiaryContainer),
            ),
          ),
        ],
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
      final tile = Container(
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
      // Only where somebody is meant to press it. On a board facing the
      // street this is a button a passer-by can use to clear the number
      // somebody else is waiting for; on a counter screen it is the whole
      // point. The kitchen screen carries it too, for the same reason.
      if (!widget.demo) return tile;
      return Row(
        children: [
          Expanded(child: tile),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _busy != null
                ? null
                : () => unawaited(_collect(t['id'] as String)),
            child: const Text('Delivered'),
          ),
        ],
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
