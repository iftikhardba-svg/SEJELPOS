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
    this.doneSoon = false,
    this.label,
    this.sessionId,
    this.guests,
    this.openedAt,
    this.runningTotal,
    this.openedBy,
    this.partyTableNos = const [],
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
        doneSoon: (j['done_soon'] as bool?) ?? false,
        label: j['label'] as String?,
        sessionId: j['session_id'] as String?,
        guests: j['guests'] as int?,
        openedAt: j['opened_at'] == null
            ? null
            : DateTime.tryParse(j['opened_at'] as String),
        runningTotal: j['running_total'] as int?,
        openedBy: j['opened_by'] as String?,
        partyTableNos: [
          for (final n in (j['party_table_nos'] as List? ?? const []))
            n as int,
        ],
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

  /// Nearly finished — somebody's judgement, recorded so the door can use it.
  final bool doneSoon;
  final String? label;
  final String? sessionId;
  final int? guests;
  final DateTime? openedAt;
  final int? runningTotal;
  final String? openedBy;

  /// Every table this party is sitting at. More than one means tables were
  /// pushed together, and both halves say so.
  final List<int> partyTableNos;

  bool get isMerged => partyTableNos.length > 1;

  /// What the waiter calls it. A party across two tables is one thing with
  /// one bill, so it reads as one thing.
  String get name => isMerged
      ? 'Tables ${partyTableNos.join(" + ")}'
      : (label ?? 'Table $tableNo');
  bool get isOpen => status == 'open';
}

/// What the floor shows on each table besides its number.
///
/// The same set the screen this replaces offers behind its Table Info button,
/// minus the two nothing can answer yet: time since the last course, and which
/// course a table is on, both of which need rounds to be sent to the kitchen
/// through the session rather than held on the device.
enum TableView {
  none('Tables'),
  duration('Duration'),
  spend('Money spent'),
  perCover('Money / cover'),
  perMinute('Money / minute'),
  server('Who is here?');

  const TableView(this.label);

  final String label;
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
    this.onQuickOrder,
    this.quickOrderLabel,
    this.openedBy,
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

  /// Serve somebody who is not sitting down — straight to the menu, no table.
  /// Null when this catalog has no counter sale type to switch to.
  final VoidCallback? onQuickOrder;

  /// What that counter trade is called here: 'TakeAway', 'Drive Thru'…
  final String? quickOrderLabel;

  /// Who is on this till, recorded against any table they seat — that is what
  /// the floor's "who is here?" view reads.
  final String? openedBy;

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

  /// What each table is showing. Kept while the floor is reloaded so a manager
  /// watching spend does not have to choose it again every refresh.
  TableView _view = TableView.none;

  /// Ticks the clock so durations move without the waiter touching anything.
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// What this table reads as under the current view. Null leaves the tile
  /// showing only its number and total.
  String? _kpi(FloorTable table, int held) {
    if (!table.isOpen && held == 0) return null;
    final total = (table.runningTotal ?? 0) + held;
    final opened = table.openedAt;
    final minutes = opened == null
        ? null
        : DateTime.now().toUtc().difference(opened.toUtc()).inMinutes;

    switch (_view) {
      case TableView.none:
        return null;
      case TableView.duration:
        if (minutes == null) return null;
        return minutes < 60
            ? '${minutes}m'
            : '${minutes ~/ 60}h ${(minutes % 60).toString().padLeft(2, "0")}m';
      case TableView.spend:
        return formatHalalas(total);
      case TableView.perCover:
        final covers = table.guests ?? 0;
        if (covers <= 0) return null;
        return '${formatHalalas(total ~/ covers)}/c';
      case TableView.perMinute:
        // Under a minute the rate is meaningless — a table that has just sat
        // down would read as the best in the room.
        if (minutes == null || minutes < 1) return null;
        return '${formatHalalas(total ~/ minutes)}/m';
      case TableView.server:
        return table.openedBy;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // A minute is the resolution every one of these views is read at.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _view != TableView.none) setState(() {});
    });
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
      final session = await widget.api.openTable(
        table.id,
        guests: guests,
        openedBy: widget.openedBy,
      );
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

  /// What can be done to a table besides taking an order on it.
  Future<void> _tableMenu(FloorTable table) async {
    // Every open party except this table's own, since that is what a free
    // table can be pushed onto.
    final parties = <String, FloorTable>{};
    for (final other in _tables) {
      if (other.isOpen && other.sessionId != null &&
          other.sessionId != table.sessionId) {
        parties.putIfAbsent(other.sessionId!, () => other);
      }
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(table.name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(table.isOpen
                  ? '${table.guests ?? "?"} guests'
                  : '${table.seats} seats · free'),
            ),
            const Divider(height: 1),
            if (table.isOpen)
              ListTile(
                leading: const Icon(Icons.timelapse),
                title: Text(table.doneSoon
                    ? 'Not leaving yet after all'
                    : 'Mark as done soon'),
                onTap: () => Navigator.of(context).pop('done-soon'),
              ),
            // Pushing tables together: a four on two twos. Offered on the free
            // table, because that is the one being carried over to the party.
            if (!table.isOpen && parties.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.merge),
                title: const Text('Join to a party…'),
                subtitle: const Text('Two tables, one bill'),
                onTap: () => Navigator.of(context).pop('merge'),
              ),
            if (table.isMerged)
              ListTile(
                leading: const Icon(Icons.call_split),
                title: const Text('Take this table out of the party'),
                onTap: () => Navigator.of(context).pop('unmerge'),
              ),
          ],
        ),
      ),
    );

    switch (action) {
      case 'done-soon':
        await _toggleDoneSoon(table);
      case 'merge':
        await _merge(table, parties.values.toList());
      case 'unmerge':
        await _unmerge(table);
      default:
        return;
    }
  }

  /// Push [table] onto a party already sitting somewhere else.
  Future<void> _merge(FloorTable table, List<FloorTable> parties) async {
    final host = parties.length == 1
        ? parties.single
        : await showDialog<FloorTable>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text('Join ${table.name} to which party?'),
              children: [
                for (final party in parties)
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(context).pop(party),
                    child: Text('${party.name} · '
                        '${party.guests ?? "?"} guests'),
                  ),
              ],
            ),
          );
    if (host == null || !mounted) return;

    final seats = host.seats + table.seats;
    final guests = await showDialog<int>(
      context: context,
      builder: (context) => _GuestsDialog(
        table: table,
        title: '${host.name} + ${table.name} · how many now?',
        most: seats,
        start: host.guests ?? seats,
      ),
    );
    if (guests == null) return;

    try {
      await widget.api.joinTable(host.sessionId!, table.id, guests: guests);
    } on SyncApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.detail)));
      }
    }
    await _load();
  }

  Future<void> _unmerge(FloorTable table) async {
    try {
      await widget.api.releaseJoinedTable(table.sessionId!, table.id);
    } on SyncApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.detail)));
      }
    }
    await _load();
  }

  /// Nearly finished, or not any more.
  Future<void> _toggleDoneSoon(FloorTable table) async {
    final session = table.sessionId;
    if (session == null) return;
    try {
      await widget.api.markDoneSoon(session, done: !table.doneSoon);
    } on SyncApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.detail)));
    }
    await _load();
  }

  /// The four states a floor is read by, in the colours staff already know
  /// from the screen this replaces: blue is free, amber is somebody else's
  /// table, red is yours, green is about to leave.
  ///
  /// Fixed colours rather than theme ones on purpose. A waiter crossing a room
  /// reads a colour, not a label, and a palette that shifts with the theme
  /// would make them read the label instead.
  static const _free = Color(0xFF2F6FED);
  static const _inUse = Color(0xFFF4B400);
  static const _yours = Color(0xFFD93025);
  static const _doneSoon = Color(0xFF1E8E3E);
  static const _reserved = Color(0xFF7B5BD6);

  static Color _colourFor(FloorTable table,
      {required bool mine, required bool occupied}) {
    if (table.doneSoon) return _doneSoon;
    if (mine) return _yours;
    if (table.isOpen) return _inUse;
    if (!occupied && table.status == 'reserved') return _reserved;
    return _free;
  }

  /// Black or white, whichever can be read on the tile.
  static Color _readableOn(Color background) =>
      background.computeLuminance() > 0.5 ? Colors.black : Colors.white;

  Widget _legend() {
    Widget swatch(Color colour, String label) => Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: colour,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch(_free, 'Free'),
        swatch(_inUse, 'In use'),
        swatch(_yours, 'Yours'),
        swatch(_doneSoon, 'Done soon'),
      ],
    );
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
          // A Wrap, not a Row: the header carries a legend, the sections, the
          // view picker and the counter button, and on a narrow tablet a Row
          // paints warning stripes across the top of the floor instead.
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              // What the colours mean, on the screen rather than in a manual:
              // the floor is read at a glance by people who never open one.
              _legend(),
              if (_sections.length > 1)
                for (final s in _sections)
                  ChoiceChip(
                    selected: s.id == _section,
                    onSelected: (_) => setState(() => _section = s.id),
                    label: Text(s.name),
                  ),
              Text('${shown.where((t) => t.isOpen).length} of ${shown.length} '
                  'in use'),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reload the floor',
                onPressed: _load,
              ),
              // What the tables show. A manager reads a room by spend and by
              // how long people have been sitting; a waiter reads it by who
              // needs them. Same floor, different question.
              PopupMenuButton<TableView>(
                tooltip: 'What the tables show',
                initialValue: _view,
                onSelected: (v) => setState(() => _view = v),
                itemBuilder: (context) => [
                  for (final view in TableView.values)
                    PopupMenuItem(value: view, child: Text(view.label)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.info_outline, size: 18),
                      const SizedBox(width: 4),
                      Text('Table info · ${_view.label}'),
                    ],
                  ),
                ),
              ),
              // Somebody at the counter. One tap and the till is on the menu
              // with no table, and it stays there until it is sent back to
              // the room — a waiter's tablet and a counter till want opposite
              // defaults, and both are right.
              if (widget.onQuickOrder != null)
                FilledButton.tonalIcon(
                  onPressed: widget.onQuickOrder,
                  icon: const Icon(Icons.bolt, size: 18),
                  label: Text('Quick order'
                      '${widget.quickOrderLabel == null ? "" : " · "
                          "${widget.quickOrderLabel}"}'),
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
    final mine = widget.ours.containsKey(table.id);
    final occupied = table.isOpen || mine;
    final kpi = _kpi(table, held);
    // In a KPI view the free tables step back: the question being asked is
    // about the tables that are working.
    final muted = _view != TableView.none && !occupied;
    final background = muted
        ? const Color(0xFFBDBDBD)
        : _colourFor(table, mine: mine, occupied: occupied);
    final foreground = _readableOn(background);

    return Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          // The imported shape, so the room on screen looks like the room.
          borderRadius: BorderRadius.circular(table.shape == 'round' ? 999 : 10),
          side: BorderSide(
            color: occupied ? scheme.outline : scheme.outlineVariant,
            width: occupied ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => unawaited(_tap(table)),
          // Held down: everything that can be done to a table other than
          // taking an order on it — mark it as leaving, push it onto another
          // party, or take it back out of one.
          onLongPress: () => unawaited(_tableMenu(table)),
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
                  // Under the number: the answer to whatever the floor is
                  // being asked, or the party size when it is not being asked
                  // anything.
                  Text(
                    kpi ??
                        (occupied
                            ? '${table.guests ?? widget.ours[table.id]?.guests ?? "?"}'
                                ' guests'
                            : '${table.seats} seats'),
                    style: TextStyle(
                      fontSize: kpi == null ? 10 : 12,
                      fontWeight: kpi == null ? null : FontWeight.bold,
                      color: foreground,
                    ),
                  ),
                  if (total > 0 && _view == TableView.none)
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
  const _GuestsDialog({
    required this.table,
    this.title,
    this.most,
    this.start,
  });

  final FloorTable table;

  /// Overridden when tables are being pushed together: the question is then
  /// about the party, not the table.
  final String? title;
  final int? most;
  final int? start;

  @override
  State<_GuestsDialog> createState() => _GuestsDialogState();
}

class _GuestsDialogState extends State<_GuestsDialog> {
  late int _guests = widget.start ?? widget.table.seats;

  @override
  Widget build(BuildContext context) {
    final most = widget.most ?? widget.table.maxSeats;
    return AlertDialog(
      title: Text(widget.title ?? '${widget.table.name} · how many?'),
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
