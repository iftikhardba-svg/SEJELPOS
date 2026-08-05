/// The main till screen — the working implementation of the finalized mockup.
///
/// Everything on this screen goes through PosDatabase: prices come from the
/// catalog via the sale type's tier, and Charge runs the real completeSale
/// transaction — sale, lines, payment, outbox entry and kitchen tickets, all
/// or nothing. There is no screen-side arithmetic that could disagree with
/// what gets stored.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/pricing.dart';
import '../data/pos_database.dart';
import '../printing/escpos.dart';
import '../printing/printer.dart';
import '../sync/sync_worker.dart';

class TillScreen extends StatefulWidget {
  const TillScreen({
    super.key,
    required this.db,
    this.worker,
    this.sendBytes,
  });

  final PosDatabase db;

  /// Present when the device is enrolled; a charge nudges a sync pass so the
  /// kitchen sees the ticket within seconds, not at the next timer tick.
  final SyncWorker? worker;

  /// Test seam for the printer transport.
  final SendBytes? sendBytes;

  @override
  State<TillScreen> createState() => _TillScreenState();
}

class _TillScreenState extends State<TillScreen> {
  late final List<SalesType> _salesTypes;
  late final List<({int menuId, String name})> _screens;
  late SalesType _salesType;
  late int _activeMenu;
  List<CatalogProduct> _items = const [];

  final List<CartLine> _cart = [];
  final _refController = TextEditingController();
  int _orderNo = 1;

  @override
  void initState() {
    super.initState();
    _salesTypes = widget.db.salesTypes();
    _screens = widget.db.menuScreens();
    _salesType = _salesTypes.first;
    _activeMenu = _screens.first.menuId;
    _items = widget.db.productsForScreen(_activeMenu);
  }

  @override
  void dispose() {
    _refController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- cart maths

  int? _unitPrice(CatalogProduct p) {
    try {
      return priceFor(p.tiers, _salesType.priceTier, prodnum: p.prodnum);
    } on PriceUnavailable {
      return null; // shown disabled; refused at add time too
    }
  }

  int get _grossTotal => _cart.fold(
      0,
      (sum, l) =>
          sum + lineTotal(_unitPrice(l.product) ?? 0, l.qty));

  // ------------------------------------------------------------------ acts

  void _add(CatalogProduct p) {
    if (_unitPrice(p) == null) {
      _toast(
          '${p.descript} has no price for ${_salesType.descript} — set one in '
          'the back office first');
      return;
    }
    setState(() {
      final existing = _cart.where((l) => l.product.prodnum == p.prodnum);
      if (existing.isNotEmpty) {
        existing.first.qty += 1;
      } else {
        _cart.add(CartLine(product: p, qty: 1));
      }
    });
  }

  void _bump(CartLine line, double by) {
    setState(() {
      line.qty += by;
      if (line.qty <= 0) _cart.remove(line);
    });
  }

  void _charge(int methodnum, String methodName) {
    if (_cart.isEmpty) return;
    if (_salesType.requiresExternalRef &&
        _refController.text.trim().isEmpty) {
      _toast('${_salesType.descript} orders need the aggregator order number');
      return;
    }
    final CompletedSale sale;
    try {
      sale = widget.db.completeSale(
        cart: List.of(_cart),
        salesType: _salesType,
        methodnum: methodnum,
        externalRef: _salesType.requiresExternalRef
            ? _refController.text.trim()
            : null,
        orderNo: _orderNo,
      );
    } on Exception catch (e) {
      _toast('$e');
      return;
    }

    final completedOrder = _orderNo;
    setState(() {
      _cart.clear();
      _refController.clear();
      _orderNo += 1;
    });

    // Paper and kitchen happen off the critical path: the cashier moves to
    // the next customer whether or not the printer answers.
    unawaited(_printReceipt(sale, methodName));
    unawaited(widget.worker?.syncNow());

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Order $completedOrder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Receipt ${sale.receiptNo} · $methodName'),
            const SizedBox(height: 4),
            Text('Total ${formatHalalas(sale.finalTotal)} '
                '(VAT ${formatHalalas(sale.taxTotal)})'),
            if (sale.kitchenStations.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Kitchen: ${sale.kitchenStations.join(", ")}'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Next customer'),
          ),
        ],
      ),
    );
  }

  Future<void> _printReceipt(CompletedSale sale, String methodName) async {
    final device =
        widget.db.raw.select('SELECT * FROM device WHERE id = 1').first;
    final host = device['printer_host'] as String?;
    if (host == null || host.isEmpty) return; // no printer configured

    final lines = [
      for (final l in widget.db.saleLines(sale.saleUuid))
        ReceiptLine(
          qty: (l['qty'] as num).toDouble(),
          name: l['line_des'] as String,
          amount: l['line_total'] as int,
        ),
    ];
    final bytes = buildReceipt(ReceiptData(
      brandName: 'Fatima Restaurant',
      vatNumber: '310000000000003',
      receiptNo: sale.receiptNo,
      orderNo: _orderNo - 1,
      dateTime: DateTime.now(),
      lines: lines,
      netTotal: sale.netTotal,
      taxTotal: sale.taxTotal,
      finalTotal: sale.finalTotal,
      payMethod: methodName,
      // Null on a device not provisioned to sign — the receipt then carries
      // the UNSIGNED banner rather than a QR that would not validate.
      zatcaQr: sale.stamp?.qr,
    ));

    try {
      await ReceiptPrinter(
        host: host,
        port: (device['printer_port'] as int?) ?? 9100,
        send: widget.sendBytes,
      ).print(bytes);
    } on Exception {
      if (mounted) _toast('Printer unreachable — receipt not printed');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // -------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final split = splitInclusive(_grossTotal);

    return Scaffold(
      appBar: AppBar(
        title: const Text('POS — Arid Branch'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text('ORDER $_orderNo',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _saleTypeStrip(scheme),
          if (_salesType.requiresExternalRef) _refBar(scheme),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _menuPanel(scheme)),
                SizedBox(width: 320, child: _cartPanel(scheme, split)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _saleTypeStrip(ColorScheme scheme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          for (final t in _salesTypes)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: t.no == _salesType.no,
                onSelected: (_) => setState(() => _salesType = t),
                label: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.descript,
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      t.isAggregator
                          ? 'TIER ${t.priceTier.toUpperCase()} · AGGREGATOR'
                          : 'TIER ${t.priceTier.toUpperCase()}',
                      style: TextStyle(
                        fontSize: 10,
                        color: t.isAggregator
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _refBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: TextField(
        controller: _refController,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          isDense: true,
          labelText: '${_salesType.descript} order no. (required)',
          helperText:
              'Without it a disputed order can never be matched to anything',
        ),
      ),
    );
  }

  Widget _menuPanel(ColorScheme scheme) {
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final s in _screens)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    selected: s.menuId == _activeMenu,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _activeMenu = s.menuId;
                      _items = widget.db.productsForScreen(s.menuId);
                    }),
                    label: Text(s.name),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 170,
              mainAxisExtent: 84,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) {
              final p = _items[i];
              final unit = _unitPrice(p);
              return OutlinedButton(
                onPressed: unit == null ? null : () => _add(p),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.topLeft,
                  padding: const EdgeInsets.all(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(p.descript,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Text(
                      unit == null ? 'no price' : formatHalalas(unit),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _cartPanel(ColorScheme scheme, ({int net, int tax}) split) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        children: [
          Expanded(
            child: _cart.isEmpty
                ? const Center(child: Text('Tap an item to start'))
                : ListView(
                    children: [
                      for (final line in _cart)
                        ListTile(
                          dense: true,
                          title: Text(line.product.descript,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${line.qty.toStringAsFixed(0)} × '
                              '${formatHalalas(_unitPrice(line.product) ?? 0)}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove),
                                tooltip: 'One fewer',
                                onPressed: () => _bump(line, -1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add),
                                tooltip: 'One more',
                                onPressed: () => _bump(line, 1),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                _totalRow('Subtotal (excl. VAT)', split.net),
                _totalRow('VAT 15%', split.tax),
                const Divider(),
                _totalRow('Total', _grossTotal, bold: true),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _cart.isEmpty
                            ? null
                            : () => _charge(1001, 'CASH'),
                        child: const Text('CASH'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _cart.isEmpty
                            ? null
                            : () => _charge(1002, 'Visa'),
                        child: const Text('Visa'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed:
                        _cart.isEmpty ? null : () => _charge(1010, 'MADA'),
                    child: Text('Charge ${formatHalalas(_grossTotal)} · MADA'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, int halalas, {bool bold = false}) {
    final style = bold
        ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          // The label yields to the amount: a truncated word is annoying, a
          // truncated total is a mischarge waiting to happen.
          Expanded(
            child: Text(label,
                style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Text(formatHalalas(halalas), style: style),
        ],
      ),
    );
  }
}
