/// The floor: where a dine-in order starts.
///
/// Table service is part of the till, not a screen beside it. A waiter opens
/// the app, sees the room, taps a table and is on the order screen with that
/// table's bill in front of them — the same journey the paper pads had.
///
/// The status shown is the server's, fetched on opening rather than cached
/// with the catalog: a second waiter has to see that table 12 was seated a
/// minute ago from someone else's tablet. Tables are drawn at their imported
/// positions, because a waiter finds a table by where it is in the room.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../sync/sync_api.dart';

/// One table as the floor sees it.
class FloorTable {
  FloorTable({
    required this.id,
    required this.tableNo,
    required this.sectionId,
    required this.seats,
    required this.maxSeats,
    required this.posX,
    required this.posY,
    required this.width,
    required this.height,
    required this.shape,
    required this.status,
    required this.isActive,
    this.label,
    this.sessionId,
    this.guests,
    this.openedAt,
    this.runningTotal,
  });

  factory FloorTable.fromJson(Map<String, dynamic> j) => FloorTable(
        id: j['id'] as String,
        tableNo: j['table_no'] as int,
        sectionId: j['section_id'] as String,
        seats: (j['seats'] as int?) ?? 2,
        maxSeats: (j['max_seats'] as int?) ?? (j['seats'] as int?) ?? 2,
        posX: (j['pos_x'] as int?) ?? 0,
        posY: (j['pos_y'] as int?) ?? 0,
        width: (j['width'] as int?) ?? 2,
        height: (j['height'] as int?) ?? 2,
        shape: (j['shape'] as String?) ?? 'square',
        status: (j['status'] as String?) ?? 'free',
        isActive: (j['is_active'] as bool?) ?? true,
        label: j['label'] as String?,
        sessionId: j['session_id'] as String?,
        guests: j['guests'] as int?,
        openedAt: j['opened_at'] == null
            ? null
            : DateTime.tryParse(j['opened_at'] as String),
        runningTotal: j['running_total'] as int?,
      );

  final String id;
  final int tableNo;
  final String sectionId;
  final int seats;
  final int maxSeats;
  final int posX;
  final int posY;
  final int width;
  final int height;
  final String shape;

  /// 'free' | 'open' | 'reserved'
  final String status;

  /// In service. The imported floor carries every table PixelPoint ever had,
  /// and most of this customer's have never taken a bill.
  final bool isActive;
  final String? label;
  final String? sessionId;
  final int? guests;
  final DateTime? openedAt;
  final int? runningTotal;

  String get name => label ?? 'Table $tableNo';
  bool get isOpen => status == 'open';
}

/// What the till knows about the table it is ringing for.
class SeatedTable {
  const SeatedTable({
    required this.id,
    required this.tableNo,
    required this.name,
    required this.sessionId,
    required this.guests,
  });

  final String id;
  final int tableNo;
  final String name;
  final String sessionId;
  final int guests;
}

class FloorScreen extends StatefulWidget {
  const FloorScreen({
    super.key,
    required this.api,
    required this.onSeated,
    this.cartTotals = const {},
    this.ours = const {},
  });

  final SyncApi api;

  /// A table was chosen and is ready to take an order.
  final void Function(SeatedTable) onSeated;

  /// table id -> what this device already has on that table but has not
  /// charged. The server does not know about it until the bill is closed, and
  /// a waiter who cannot see it would ring the round twice.
  final Map<String, int> cartTotals;

  /// Tables this device seated and still holds. Walking back onto one goes
  /// straight to its order: asking for covers again would open a second
  /// session on a table we already have, and the backend would refuse it.
  final Map<String, SeatedTable> ours;

  @override
  State<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends State<FloorScreen> {
  /// Grid units to pixels. The imported plan pitches tables five units apart
  /// and makes them two wide, so this is what turns that into something a
  /// finger can hit: the smallest table lands at 80px.
  static const _unit = 40.0;

  List<FloorTable> _tables = const [];
  List<({String id, String name})> _sections = const [];
  String? _section;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final body = await widget.api.getFloor();
      final sections = [
        for (final s in (body['sections'] as List? ?? const []))
          (id: s['id'] as String, name: s['name'] as String),
      ];
      final tables = [
        for (final t in (body['tables'] as List? ?? const []))
          FloorTable.fromJson((t as Map).cast<String, dynamic>()),
      ];
      if (!mounted) return;
      setState(() {
        _sections = sections;
        // Only tables that are in service. This customer's floor carries 150
        // and 139 of them have never taken a bill; drawing them all would bury
        // the eleven that are really used. They are still in the catalog and
        // in the back office — a table put back in service appears here.
        _tables = tables.where((t) => t.isActive).toList();
        _section ??= sections.isEmpty ? null : sections.first.id;
        _loading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Seat a free table, or walk back onto an open one.
  Future<void> _tap(FloorTable table) async {
    // Ours already — go straight to its order. The floor may have been loaded
    // before we seated it, and asking for covers again would try to open a
    // second session on the same table.
    final mine = widget.ours[table.id];
    if (mine != null) {
      widget.onSeated(mine);
      return;
    }

    if (table.isOpen) {
      widget.onSeated(SeatedTable(
        id: table.id,
        tableNo: table.tableNo,
        name: table.name,
        sessionId: table.sessionId!,
        guests: table.guests ?? 1,
      ));
      return;
    }

    final guests = await showDialog<int>(
      context: context,
      builder: (context) => _GuestsDialog(table: table),
    );
    if (guests == null) return;

    try {
      final session = await widget.api.openTable(table.id, guests: guests);
      if (!mounted) return;
      widget.onSeated(SeatedTable(
        id: table.id,
        tableNo: table.tableNo,
        name: table.name,
        sessionId: session['id'] as String,
        guests: guests,
      ));
    } on SyncApiException catch (e) {
      if (!mounted) return;
      // Two waiters tapped the same table. The backend says who has it; the
      // floor is reloaded so the second one sees it as occupied.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.detail)));
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The floor could not be loaded'),
            const SizedBox(height: 4),
            Text(_error!, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }

    final shown = [
      for (final t in _tables)
        if (_section == null || t.sectionId == _section) t,
    ];
    if (shown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No tables are set up for this branch yet. Add them in the back '
            'office, or take the order on a counter sale type.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    var right = 0.0, bottom = 0.0;
    for (final t in shown) {
      right = right < (t.posX + t.width) * _unit
          ? (t.posX + t.width) * _unit
          : right;
      bottom = bottom < (t.posY + t.height) * _unit
          ? (t.posY + t.height) * _unit
          : bottom;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              if (_sections.length > 1)
                for (final s in _sections)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selected: s.id == _section,
                      onSelected: (_) => setState(() => _section = s.id),
                      label: Text(s.name),
                    ),
                  ),
              const Spacer(),
              Text('${shown.where((t) => t.isOpen).length} of ${shown.length} '
                  'in use'),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reload the floor',
                onPressed: _load,
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: right + 12,
                height: bottom + 12,
                child: Stack(
                  children: [
                    for (final table in shown)
                      Positioned(
                        left: table.posX * _unit,
                        top: table.posY * _unit,
                        width: table.width * _unit,
                        height: table.height * _unit,
                        child: _tableTile(table, scheme),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tableTile(FloorTable table, ColorScheme scheme) {
    final held = widget.cartTotals[table.id] ?? 0;
    final total = (table.runningTotal ?? 0) + held;
    final occupied = table.isOpen || widget.ours.containsKey(table.id);

    final background = occupied
        ? scheme.primaryContainer
        : table.status == 'reserved'
            ? scheme.tertiaryContainer
            : scheme.surfaceContainerHighest;
    final foreground = occupied
        ? scheme.onPrimaryContainer
        : table.status == 'reserved'
            ? scheme.onTertiaryContainer
            : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          // The imported shape, so the room on screen looks like the room.
          borderRadius: BorderRadius.circular(table.shape == 'round' ? 999 : 10),
          side: BorderSide(
            color: occupied ? scheme.primary : scheme.outlineVariant,
            width: occupied ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => unawaited(_tap(table)),
          child: Padding(
            padding: const EdgeInsets.all(4),
            // Scaled to fit rather than sized to hope: a two-seat table is a
            // small square, and a tile that overflows paints warning stripes
            // across the floor plan instead of showing the room.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${table.tableNo}',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: foreground,
                    ),
                  ),
                  Text(
                    occupied
                        ? '${table.guests ?? widget.ours[table.id]?.guests ?? "?"}'
                            ' guests'
                        : '${table.seats} seats',
                    style: TextStyle(fontSize: 10, color: foreground),
                  ),
                  if (total > 0)
                    Text(
                      formatHalalas(total),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How many are sitting down. Asked because the backend refuses a party
/// bigger than the table, and because covers are the number every restaurant
/// report is built on.
class _GuestsDialog extends StatefulWidget {
  const _GuestsDialog({required this.table});

  final FloorTable table;

  @override
  State<_GuestsDialog> createState() => _GuestsDialogState();
}

class _GuestsDialogState extends State<_GuestsDialog> {
  late int _guests = widget.table.seats;

  @override
  Widget build(BuildContext context) {
    final most = widget.table.maxSeats;
    return AlertDialog(
      title: Text('${widget.table.name} · how many?'),
      content: SizedBox(
        width: 360,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var n = 1; n <= most; n++)
              SizedBox(
                width: 56,
                height: 56,
                child: n == _guests
                    ? FilledButton(
                        onPressed: () => Navigator.of(context).pop(n),
                        child: Text('$n'),
                      )
                    : OutlinedButton(
                        onPressed: () => setState(() => _guests = n),
                        child: Text('$n'),
                      ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_guests),
          child: Text('Seat $_guests'),
        ),
      ],
    );
  }
}
