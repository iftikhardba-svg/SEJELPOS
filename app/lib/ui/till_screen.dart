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
import '../sync/order_numbers.dart';
import '../sync/sync_worker.dart';
import 'setup_screen.dart';

class TillScreen extends StatefulWidget {
  const TillScreen({
    super.key,
    required this.db,
    this.worker,
    this.sendBytes,
    this.orderNumbers,
  });

  final PosDatabase db;

  /// Allocates the customer-facing order number. Null on the demo path,
  /// where the till shows no number rather than inventing one that a second
  /// device could also invent.
  final OrderNumbers? orderNumbers;

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

  /// The number waiting to be called out for the sale being rung. Reserved
  /// from the backend in blocks — never counted locally, or two tills at one
  /// counter would call the same number to different customers.
  OrderNumber? _pending;

  /// The menu tiles a cashier lands on, empty when no menu is laid out.
  late final List<MenuTile> _tiles;
  late final ({int menuNo, String name})? _menu;

  /// Null while the menu grid is showing; set once a page is opened.
  int? _openPage;

  @override
  void initState() {
    super.initState();
    _salesTypes = widget.db.salesTypes();
    _screens = widget.db.menuScreens();
    _salesType = _salesTypes.first;
    _menu = widget.db.defaultMenu();
    final menu = _menu;
    _tiles = menu == null ? const [] : widget.db.menuTiles(menu.menuNo);
    // With no menu laid out, fall back to the flat list of pages rather than
    // showing a cashier nothing at all.
    _activeMenu = _screens.first.menuId;
    _openPage = _tiles.isEmpty ? _activeMenu : null;
    _items = widget.db.productsForScreen(_activeMenu);
    unawaited(_takeOrderNumber());
  }

  void _openMenuPage(int screenNo) {
    setState(() {
      _openPage = screenNo;
      _activeMenu = screenNo;
      _items = widget.db.productsForScreen(screenNo);
    });
  }

  void _backToMenu() {
    setState(() => _openPage = null);
  }

  /// '#RRGGBB' from the catalog, or null to leave the theme alone.
  static Color? _colour(String? hex) {
    if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
    final value = int.tryParse(hex.substring(1), radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  /// Black or white, whichever the eye can read on [background].
  ///
  /// The imported menu has 27 background colours and almost no foreground
  /// ones, so most tiles would otherwise be theme-coloured text on an
  /// arbitrary colour — white on yellow, for instance.
  static Color _readableOn(Color background) {
    final luminance = background.computeLuminance();
    return luminance > 0.45 ? const Color(0xFF111111) : Colors.white;
  }

  /// Held before the sale, not after, so the number is on screen while the
  /// order is being rung and the cashier can say it as they take the money.
  Future<void> _takeOrderNumber() async {
    final order = await widget.orderNumbers?.next(DateTime.now());
    if (mounted) setState(() => _pending = order);
  }

  String get _orderLabel {
    final order = _pending;
    if (order == null) return '—';
    return widget.orderNumbers?.format(order) ?? '${order.number}';
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

  Future<void> _charge(int methodnum, String methodName) async {
    if (_cart.isEmpty) return;
    if (_salesType.requiresExternalRef &&
        _refController.text.trim().isEmpty) {
      _toast('${_salesType.descript} orders need the aggregator order number');
      return;
    }

    // Every sale records who rang it. Asked here rather than at boot so the
    // cashier is chosen by the person actually standing at the till.
    var empnum = widget.db.activeCashier();
    if (empnum == null) {
      final staff = widget.db.cashiers();
      if (staff.length == 1) {
        // Nothing to choose between. Asking would be a dialog whose only
        // answer is already known.
        empnum = staff.single.empnum;
        widget.db.setActiveCashier(empnum);
      } else {
        empnum = await _pickCashier();
        if (empnum == null) return; // cancelled
      }
    }

    final CompletedSale sale;
    try {
      sale = widget.db.completeSale(
        cart: List.of(_cart),
        salesType: _salesType,
        methodnum: methodnum,
        empnum: empnum,
        externalRef: _salesType.requiresExternalRef
            ? _refController.text.trim()
            : null,
        orderNo: _pending?.number,
      );
    } on Exception catch (e) {
      _toast('$e');
      return;
    }

    final completedOrder = _orderLabel;
    setState(() {
      _cart.clear();
      _refController.clear();
    });
    // The next customer's number is reserved now, so it is on screen before
    // they have finished ordering.
    unawaited(_takeOrderNumber());

    // Paper and kitchen happen off the critical path: the cashier moves to
    // the next customer whether or not the printer answers.
    unawaited(_printReceipt(sale, methodName, completedOrder));
    unawaited(widget.worker?.syncNow());

    // The cashier picker above may have awaited, so the till could be gone.
    if (!mounted) return;
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

  Future<void> _printReceipt(
      CompletedSale sale, String methodName, String orderLabel) async {
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
      // From the device row, not a constant: enrolment delivers the seller
      // identity, and a hardcoded name printed another tenant's restaurant on
      // every receipt.
      brandName: (device['zatca_seller_name'] as String?) ?? '',
      vatNumber: (device['zatca_vat_number'] as String?) ?? '',
      receiptNo: sale.receiptNo,
      orderNo: orderLabel == '—' ? null : orderLabel,
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

  /// Choose who is on the till, and remember it on the device.
  ///
  /// Deliberately not a login: migrated staff arrive with `must_set_pin` and
  /// no `pin_hash`, so there is nothing to check a PIN against yet. This
  /// records who rang the sale; it does not prove it.
  Future<int?> _pickCashier() async {
    final staff = widget.db.cashiers();
    if (staff.isEmpty) {
      _toast('No staff have synced to this till yet');
      return null;
    }

    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Who is on this till?'),
        children: [
          for (final person in staff)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(person.empnum),
              child: Text('${person.name}  ·  ${person.empnum}'),
            ),
        ],
      ),
    );

    if (chosen != null) {
      widget.db.setActiveCashier(chosen);
      if (mounted) setState(() {});
    }
    return chosen;
  }

  String get _cashierLabel {
    final empnum = widget.db.activeCashier();
    if (empnum == null) return 'No cashier';
    final person = widget.db
        .cashiers()
        .where((c) => c.empnum == empnum);
    return person.isEmpty ? 'Cashier $empnum' : person.first.name;
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
              child: Text('ORDER $_orderLabel',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.person_outline),
            label: Text(_cashierLabel),
            onPressed: () => _pickCashier(),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Device setup',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SetupScreen(
                  db: widget.db,
                  sendBytes: widget.sendBytes,
                ),
              ),
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

  /// Two screens in one panel, the way the old till worked: the menu is a
  /// grid of coloured page tiles, and opening one shows that page's buttons.
  /// Staff reach for a position and a colour long before they read a label,
  /// so both are carried over exactly.
  Widget _menuPanel(ColorScheme scheme) {
    if (_openPage == null) return _menuGrid(scheme);
    return Column(
      children: [
        _pageHeader(scheme),
        Expanded(child: _buttonGrid(scheme)),
      ],
    );
  }

  /// Lay items out at their real grid coordinates, leaving gaps empty.
  ///
  /// Packing them in order instead would be much simpler and would quietly
  /// destroy the thing being carried over: staff reach for a position. If a
  /// page is hidden — because everything on it is a modifier, say — the ones
  /// after it must NOT slide up into its place.
  Widget _positionedGrid<T>({
    required List<T> items,
    required int? Function(T) x,
    required int? Function(T) y,
    required double tileHeight,
    required Widget Function(T) build,
  }) {
    final placed = <int, Map<int, T>>{};
    var columns = 1;
    var rows = 1;
    for (final item in items) {
      final ix = x(item), iy = y(item);
      if (ix == null || iy == null) continue;
      placed.putIfAbsent(iy, () => {})[ix] = item;
      if (ix > columns) columns = ix;
      if (iy > rows) rows = iy;
    }

    // Anything without coordinates still has to be reachable, so it goes on
    // the end rather than being dropped.
    final loose = [for (final i in items) if (x(i) == null || y(i) == null) i];

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (var row = 1; row <= rows; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // NOT CrossAxisAlignment.stretch: a Row inside a vertical
            // ListView has unbounded height, and stretching into that is an
            // invalid constraint. The SizedBox below sets the height instead.
            child: Row(
              children: [
                for (var col = 1; col <= columns; col++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        height: tileHeight,
                        child: placed[row]?[col] == null
                            ? const SizedBox.shrink()
                            : build(placed[row]![col] as T),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (loose.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in loose)
                SizedBox(width: 170, height: tileHeight, child: build(item)),
            ],
          ),
      ],
    );
  }

  Widget _menuGrid(ColorScheme scheme) {
    return _positionedGrid<MenuTile>(
      items: _tiles,
      x: (t) => t.posX,
      y: (t) => t.posY,
      tileHeight: 96,
      build: (tile) {
        final back = _colour(tile.backColor);
        final fore = _colour(tile.foreColor) ??
            (back == null ? null : _readableOn(back));
        return FilledButton(
          onPressed: () => _openMenuPage(tile.screenNo),
          style: FilledButton.styleFrom(
            backgroundColor: back,
            foregroundColor: fore,
            padding: const EdgeInsets.all(10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(
            tile.name,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        );
      },
    );
  }

  Widget _pageHeader(ColorScheme scheme) {
    final name = _screens
        .where((s) => s.menuId == _openPage)
        .map((s) => s.name)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          // Only offered when there is a menu to go back to. With no menu laid
          // out the till falls back to a flat page strip and this would lead
          // to an empty screen.
          if (_tiles.isNotEmpty)
            TextButton.icon(
              onPressed: _backToMenu,
              icon: const Icon(Icons.arrow_back),
              label: Text(_menu?.name ?? 'Menu'),
            ),
          const SizedBox(width: 8),
          Text(name ?? '',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          if (_tiles.isEmpty) ...[
            const Spacer(),
            SizedBox(
              width: 320,
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final s in _screens)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        selected: s.menuId == _activeMenu,
                        showCheckmark: false,
                        onSelected: (_) => _openMenuPage(s.menuId),
                        label: Text(s.name),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buttonGrid(ColorScheme scheme) {
    return _positionedGrid<CatalogProduct>(
      items: _items,
      x: (p) => p.posX,
      y: (p) => p.posY,
      tileHeight: 84,
      build: (p) {
        final unit = _unitPrice(p);
        final back = _colour(p.backColor);
        final fore = _colour(p.foreColor) ??
            (back == null ? null : _readableOn(back));

        // Material 3 defaults OutlinedButton to a StadiumBorder, which on an
        // 84px-tall tile is a full oval: the corners eat the name and the
        // price. A menu tile has to be a rectangle.
        final shape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        );
        final label = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(p.label,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
            ),
            Text(
              unit == null ? 'no price' : formatHalalas(unit),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: fore ?? scheme.primary,
              ),
            ),
          ],
        );

        // A coloured button is filled; one with no colour keeps the outlined
        // look rather than being painted an invented shade.
        if (back == null) {
          return OutlinedButton(
            onPressed: unit == null ? null : () => _add(p),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.all(10),
              shape: shape,
            ),
            child: label,
          );
        }
        return FilledButton(
          onPressed: unit == null ? null : () => _add(p),
          style: FilledButton.styleFrom(
            backgroundColor: back,
            foregroundColor: fore,
            alignment: Alignment.topLeft,
            padding: const EdgeInsets.all(10),
            shape: shape,
          ),
          child: label,
        );
      },
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
