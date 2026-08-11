/// Splitting a check between the guests who ate it.
///
/// Two different things get called "splitting the bill", and only one of them
/// is this screen. Settling one bill across several methods — half on a card,
/// the rest in cash — is a payment split: one order, one tax invoice, several
/// tenders, and the till already does it from the cart panel.
///
/// This is the other one: four people, four bills. Each guest's share is its
/// own sale, with its own receipt number and its own ZATCA stamp, because each
/// of them is a tax invoice in its own right. Which is why a share can only be
/// made of *items*: an invoice line has to be something that was sold, so
/// "pay 50 riyals of it" cannot be a bill of its own — that is a payment
/// split, and it belongs on one invoice.
///
/// The table stays open until nothing on it is owed.
library;

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../data/pos_database.dart';

/// Rebuilds the unpaid check after the server has divided a line.
typedef SplitLine = Future<List<CartLine>?> Function(CartLine line, double qty);

/// Takes the money for one guest's share. True means the table is settled and
/// there is nothing left to split.
typedef ChargeShare = Future<bool> Function(List<CartLine> share);

class SplitCheckScreen extends StatefulWidget {
  const SplitCheckScreen({
    super.key,
    required this.tableName,
    required this.lines,
    required this.totalOf,
    required this.onSplitLine,
    required this.onCharge,
  });

  final String tableName;

  /// Everything still owed on the table.
  final List<CartLine> lines;

  /// What a line comes to, priced by the till so the two cannot disagree.
  final int Function(CartLine) totalOf;

  final SplitLine onSplitLine;
  final ChargeShare onCharge;

  @override
  State<SplitCheckScreen> createState() => _SplitCheckScreenState();
}

class _SplitCheckScreenState extends State<SplitCheckScreen> {
  late List<CartLine> _lines = List.of(widget.lines);

  /// The check lines in this guest's share, by their number on the check.
  ///
  /// Kept by number rather than by object because dividing a line rebuilds
  /// every line from the server's answer — the objects change, the numbers do
  /// not.
  final Set<int> _picked = {};

  bool _busy = false;

  int _numberOf(CartLine line) =>
      line.sessionLineNos.isEmpty ? -1 : line.sessionLineNos.first;

  List<CartLine> get _share =>
      [for (final l in _lines) if (_picked.contains(_numberOf(l))) l];

  List<CartLine> get _rest =>
      [for (final l in _lines) if (!_picked.contains(_numberOf(l))) l];

  int get _shareTotal =>
      _share.fold(0, (sum, l) => sum + widget.totalOf(l));

  int get _restTotal => _rest.fold(0, (sum, l) => sum + widget.totalOf(l));

  void _toggle(CartLine line) {
    final no = _numberOf(line);
    if (no < 0) return;
    setState(() {
      if (!_picked.remove(no)) _picked.add(no);
    });
  }

  /// Break a quantity off a line so two guests can pay for one each.
  ///
  /// The server does the dividing and answers with the whole check, because
  /// it owns the line numbers and a share that named the wrong ones would bill
  /// the wrong food.
  Future<void> _divide(CartLine line) async {
    final want = await showDialog<double>(
      context: context,
      builder: (context) => _HowManyDialog(
        name: line.product.descript,
        available: line.qty,
      ),
    );
    if (want == null || !mounted) return;

    final before = {for (final l in _lines) _numberOf(l)};
    setState(() => _busy = true);
    final rebuilt = await widget.onSplitLine(line, want);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (rebuilt == null) return;
      _lines = rebuilt;
      // What was just broken off is what the guest asked for, so it lands in
      // their share without the waiter having to find it.
      for (final l in _lines) {
        final no = _numberOf(l);
        if (no >= 0 && !before.contains(no)) _picked.add(no);
      }
    });
  }

  Future<void> _charge() async {
    final share = List<CartLine>.of(_share);
    if (share.isEmpty || _busy) return;
    setState(() => _busy = true);
    final settled = await widget.onCharge(share);
    if (!mounted) return;
    if (settled) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _lines.removeWhere(share.contains);
      _picked.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Split ${widget.tableName}'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Tap an item to move it onto this guest\'s bill. Each share is '
              'charged on its own and gets its own receipt.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _panel(
                    scheme,
                    title: 'Still on the table',
                    total: _restTotal,
                    lines: _rest,
                    empty: 'Everything is on this guest\'s bill',
                    dividable: true,
                  ),
                ),
                Expanded(
                  child: _panel(
                    scheme,
                    title: 'This guest',
                    total: _shareTotal,
                    lines: _share,
                    empty: 'Tap items on the left',
                    tinted: true,
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _share.isEmpty || _busy ? null : _charge,
                  child: Text(_share.isEmpty
                      ? 'Nothing on this bill yet'
                      : 'Charge this guest ${formatHalalas(_shareTotal)}'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel(
    ColorScheme scheme, {
    required String title,
    required int total,
    required List<CartLine> lines,
    required String empty,
    bool tinted = false,
    bool dividable = false,
  }) {
    return Card(
      margin: const EdgeInsets.all(8),
      color: tinted ? scheme.secondaryContainer : null,
      child: Column(
        children: [
          ListTile(
            dense: true,
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            trailing: Text(formatHalalas(total),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Divider(height: 1),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(empty,
                        style: TextStyle(color: scheme.onSurfaceVariant)))
                : ListView(
                    children: [
                      for (final line in lines)
                        ListTile(
                          dense: true,
                          title: Text(
                            line.qty == 1
                                ? line.product.descript
                                : '${line.qty.toStringAsFixed(0)} × '
                                    '${line.product.descript}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: line.extras.isEmpty
                              ? null
                              : Text(
                                  line.extras
                                      .map((e) => e.product.descript)
                                      .join(', '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11),
                                ),
                          onTap: _busy ? null : () => _toggle(line),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(formatHalalas(widget.totalOf(line))),
                              // Two of a dish on one line, one guest each.
                              if (dividable && line.qty > 1)
                                IconButton(
                                  icon: const Icon(Icons.call_split, size: 18),
                                  tooltip: 'Split this line',
                                  onPressed:
                                      _busy ? null : () => _divide(line),
                                ),
                            ],
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

/// How much of a line moves onto a bill of its own.
class _HowManyDialog extends StatefulWidget {
  const _HowManyDialog({required this.name, required this.available});

  final String name;
  final double available;

  @override
  State<_HowManyDialog> createState() => _HowManyDialogState();
}

class _HowManyDialogState extends State<_HowManyDialog> {
  double _qty = 1;

  @override
  Widget build(BuildContext context) {
    // One has to be left behind, or the line has not been split at all.
    final most = widget.available - 1;
    return AlertDialog(
      title: Text('How many of ${widget.name}?'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: _qty <= 1 ? null : () => setState(() => _qty -= 1),
          ),
          SizedBox(
            width: 64,
            child: Text(
              _qty.toStringAsFixed(0),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _qty >= most ? null : () => setState(() => _qty += 1),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_qty),
          child: const Text('Move it across'),
        ),
      ],
    );
  }
}
