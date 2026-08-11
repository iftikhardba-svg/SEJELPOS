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
  late final List<PayMethod> _payMethods;
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
    _payMethods = widget.db.payMethods();
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

  /// What the customer pays, including anything chosen inside an item.
  ///
  /// Extras are free throughout the imported catalog, but they are summed
  /// here rather than assumed to be zero: completeSale prices them, and a
  /// till that showed a total the receipt then disagreed with would be
  /// charging one number and printing another.
  int get _grossTotal =>
      _cart.fold(0, (sum, l) =>
          sum +
          lineTotal(_unitPrice(l.product) ?? 0, l.qty) +
          _extrasTotal(l.extras, l.qty));

  static int _extrasTotal(List<CartExtra> extras, double parentQty) {
    var total = 0;
    for (final extra in extras) {
      final qty = extra.qty * parentQty;
      total += lineTotal(extra.unitPrice, qty) + _extrasTotal(extra.extras, qty);
    }
    return total;
  }

  // ------------------------------------------------------------------ acts

  Future<void> _add(CatalogProduct p) async {
    if (_unitPrice(p) == null) {
      _toast(
          '${p.descript} has no price for ${_salesType.descript} — set one in '
          'the back office first');
      return;
    }

    final extras = await _configure(p);
    if (extras == null) return; // the cashier backed out; nothing is added
    if (!mounted) return;

    setState(() {
      // A configured item never merges with an identical one already in the
      // cart: two of the same meal can have different answers, and adding to
      // the first line would silently give the second customer the first
      // one's drink.
      final existing = _cart.where(
          (l) => l.product.prodnum == p.prodnum && l.extras.isEmpty);
      if (extras.isEmpty && existing.isNotEmpty) {
        existing.first.qty += 1;
      } else {
        _cart.add(CartLine(product: p, qty: 1, extras: extras));
      }
    });
  }

  /// How deep a chain of prompts may go before the till stops asking.
  ///
  /// Nothing in the imported catalog nests more than twice. The cap is here
  /// because a choice that offers a product which offers it back would
  /// otherwise open dialogs forever, and a cashier could never finish the
  /// sale or escape it.
  static const _maxPromptDepth = 3;

  /// Ask everything [product] asks, and collect what it always includes.
  ///
  /// Returns the answers, an empty list when there is nothing to ask, or null
  /// if the cashier cancelled — in which case the item is not added at all.
  /// Half-configured is not a state a bill may be in.
  Future<List<CartExtra>?> _configure(CatalogProduct product,
      {int depth = 0}) async {
    final extras = <CartExtra>[];

    for (final question in widget.db.questionsFor(product.prodnum)) {
      final picked = await _ask(product, question);
      if (picked == null) return null;
      for (final choice in picked) {
        var nested = const <CartExtra>[];
        if (depth < _maxPromptDepth) {
          final inner = await _configure(choice.product, depth: depth + 1);
          if (inner == null) return null;
          nested = inner;
        }
        extras.add(CartExtra(
          product: choice.product,
          qty: choice.qty,
          unitPrice: choice.unitPrice,
          questionNo: question.questionNo,
          extras: nested,
        ));
      }
    }

    // Nobody is asked about these — they come with the item — but the kitchen
    // and the bill still have to carry them.
    extras.addAll(widget.db.comboItemsFor(product.prodnum));
    return extras;
  }

  Future<List<MealChoice>?> _ask(
      CatalogProduct product, MealQuestion question) {
    return showDialog<List<MealChoice>>(
      context: context,
      // A prompt is not dismissible by tapping outside: an item that ends up
      // half-answered because a sleeve brushed the screen reaches the kitchen
      // as an order nobody can make.
      barrierDismissible: false,
      builder: (context) => _QuestionDialog(
        itemName: product.label,
        question: question,
      ),
    );
  }

  void _bump(CartLine line, double by) {
    setState(() {
      line.qty += by;
      if (line.qty <= 0) _cart.remove(line);
    });
  }

  /// Take a whole bill on one method. Cash asks what was handed over first —
  /// that is where change comes from, and a till that assumes exact money
  /// makes the cashier do the subtraction in their head.
  Future<void> _take(PayMethod method) async {
    if (_cart.isEmpty) return;
    int? tendered;
    if (method.isCash) {
      tendered = await _askCashReceived(_grossTotal);
      if (tendered == null) return;
    }
    await _charge([
      Tender.whole(
        methodnum: method.methodnum,
        name: method.descript,
        tendered: tendered,
        isCash: method.isCash,
      ),
    ]);
  }

  Future<void> _charge(List<Tender> tenders) async {
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
        payments: tenders,
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
    unawaited(_printReceipt(sale, completedOrder));
    unawaited(widget.worker?.syncNow());

    final change = sale.payments.fold<int>(0, (a, p) => a + p.change);

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
            Text('Receipt ${sale.receiptNo} · '
                '${sale.payments.map((p) => p.name).join(" + ")}'),
            const SizedBox(height: 4),
            Text('Total ${formatHalalas(sale.finalTotal)} '
                '(VAT ${formatHalalas(sale.taxTotal)})'),
            // The number the cashier is about to count out of the drawer, big
            // enough to read without leaning in.
            if (change > 0) ...[
              const SizedBox(height: 8),
              Text('CHANGE ${formatHalalas(change)}',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
            ],
            if (sale.payments.length > 1) ...[
              const SizedBox(height: 4),
              for (final p in sale.payments)
                Text('${p.name}  ${formatHalalas(p.amount)}',
                    style: const TextStyle(fontSize: 12)),
            ],
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

  Future<void> _printReceipt(CompletedSale sale, String orderLabel) async {
    final device =
        widget.db.raw.select('SELECT * FROM device WHERE id = 1').first;
    final host = device['printer_host'] as String?;
    if (host == null || host.isEmpty) return; // no printer configured

    // Depth comes from the stored parent chain, not from what the screen
    // happens to be holding: the receipt has to describe the sale that was
    // recorded. Children always follow their parent in line order, so one
    // pass resolves every depth.
    final depths = <String, int>{};
    final lines = [
      for (final l in widget.db.saleLines(sale.saleUuid))
        () {
          final parent = l['parent_line'] as String?;
          final depth = parent == null ? 0 : (depths[parent] ?? 0) + 1;
          depths[l['line_uuid'] as String] = depth;
          return ReceiptLine(
            qty: (l['qty'] as num).toDouble(),
            name: l['line_des'] as String,
            amount: l['line_total'] as int,
            depth: depth,
          );
        }(),
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
      payments: [
        for (final p in sale.payments)
          ReceiptTender(name: p.name, amount: p.amount, change: p.change),
      ],
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
  /// Every tile is square, and no bigger than this.
  ///
  /// Square because a till is reached for by position and shape: the old
  /// stretched-to-fit rectangles changed size with the number of columns, so
  /// the same item was a different shape on the shawarma page and the grill
  /// page. The cap stops a two-tile page from producing enormous buttons; the
  /// floor keeps an eleven-column page pressable, and the grid scrolls
  /// sideways rather than shrinking past it.
  static const _maxTile = 150.0;
  static const _minTile = 84.0;
  static const _gap = 8.0;

  Widget _positionedGrid<T>({
    required List<T> items,
    required int? Function(T) x,
    required int? Function(T) y,
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - _gap * 2;
        final side = (((available - _gap * (columns - 1)) / columns)
            .clamp(_minTile, _maxTile));

        final grid = ListView(
          padding: const EdgeInsets.all(_gap),
          children: [
            for (var row = 1; row <= rows; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: _gap),
                // NOT CrossAxisAlignment.stretch: a Row inside a vertical
                // ListView has unbounded height, and stretching into that is
                // an invalid constraint. The SizedBox below sets the size.
                child: Row(
                  children: [
                    for (var col = 1; col <= columns; col++)
                      Padding(
                        padding: const EdgeInsets.only(right: _gap),
                        child: SizedBox(
                          width: side,
                          height: side,
                          child: placed[row]?[col] == null
                              ? const SizedBox.shrink()
                              : build(placed[row]![col] as T),
                        ),
                      ),
                  ],
                ),
              ),
            if (loose.isNotEmpty)
              Wrap(
                spacing: _gap,
                runSpacing: _gap,
                children: [
                  for (final item in loose)
                    SizedBox(width: side, height: side, child: build(item)),
                ],
              ),
          ],
        );

        // At the floor the row can be wider than the panel. Scrolling it is
        // the honest answer: squeezing the tiles further makes them unreadable
        // and, on a page laid out at eleven columns, unhittable.
        //
        // The width is the list's own padding plus every cell and the gap that
        // follows it: one gap short and the row overflows by exactly that gap,
        // which the app draws as warning stripes across the menu.
        final needed = columns * (side + _gap) + _gap * 2;
        if (needed <= constraints.maxWidth) return grid;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: needed, child: grid),
        );
      },
    );
  }

  Widget _menuGrid(ColorScheme scheme) {
    return _positionedGrid<MenuTile>(
      items: _tiles,
      x: (t) => t.posX,
      y: (t) => t.posY,
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
            onPressed: unit == null ? null : () => unawaited(_add(p)),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.all(10),
              shape: shape,
            ),
            child: label,
          );
        }
        return FilledButton(
          onPressed: unit == null ? null : () => unawaited(_add(p)),
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
                      for (final line in _cart) ...[
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
                        // What was chosen inside the item, under it. Shown
                        // because the cashier has to be able to read back what
                        // they just answered before taking the money.
                        ..._extraTiles(line.extras, line.qty, scheme),
                      ],
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
                _payButtons(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The methods, the big one, and the way out to a split bill.
  Widget _payButtons() {
    final primary = _primaryMethod;
    final others = [
      for (final m in _payMethods)
        if (m.methodnum != primary?.methodnum) m,
    ];
    final ready = _cart.isNotEmpty;

    return Column(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final method in others)
              SizedBox(
                width: 92,
                child: OutlinedButton(
                  onPressed: ready ? () => unawaited(_take(method)) : null,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  child: Text(
                    method.descript,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (primary != null)
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: ready ? () => unawaited(_take(primary)) : null,
              child: Text('Charge ${formatHalalas(_grossTotal)} · '
                  '${primary.descript}'),
            ),
          ),
        TextButton.icon(
          onPressed: ready ? () => unawaited(_splitPayment()) : null,
          icon: const Icon(Icons.call_split, size: 18),
          label: const Text('Split payment'),
        ),
      ],
    );
  }

  /// The method the big button charges.
  ///
  /// The sale type's own default wins where the catalog sets one. Nothing in
  /// this customer's data does, so MADA takes it: it is ~65% of their
  /// payments, and the button a cashier hits without looking should be the
  /// one they hit two times in three.
  PayMethod? get _primaryMethod {
    if (_payMethods.isEmpty) return null;
    final byNumber = {for (final m in _payMethods) m.methodnum: m};
    final preferred = byNumber[_salesType.defaultMethodnum];
    if (preferred != null) return preferred;
    for (final m in _payMethods) {
      if (m.descript.toUpperCase() == 'MADA') return m;
    }
    for (final m in _payMethods) {
      if (!m.isCash) return m;
    }
    return _payMethods.first;
  }

  /// How much cash was handed over. Returns null if the cashier backs out.
  Future<int?> _askCashReceived(int due) {
    return showDialog<int>(
      context: context,
      builder: (context) => _CashDialog(due: due),
    );
  }

  /// Settle one bill across several methods.
  Future<void> _splitPayment() async {
    final tenders = await showDialog<List<Tender>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SplitDialog(
        total: _grossTotal,
        methods: _payMethods,
      ),
    );
    if (tenders == null || tenders.isEmpty) return;
    await _charge(tenders);
  }

  /// The chosen and included items under a cart line, indented by depth.
  List<Widget> _extraTiles(
    List<CartExtra> extras,
    double parentQty,
    ColorScheme scheme, {
    int depth = 1,
  }) {
    final tiles = <Widget>[];
    for (final extra in extras) {
      final qty = extra.qty * parentQty;
      tiles.add(Padding(
        padding: EdgeInsets.only(left: 16.0 * depth, right: 16, bottom: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                qty == 1
                    ? '· ${extra.product.descript}'
                    : '· ${qty.toStringAsFixed(0)} × ${extra.product.descript}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            // Silent when it is included, which is every row in this catalog.
            // A price that appears is one the customer is being charged.
            if (extra.unitPrice != 0)
              Text(formatHalalas(lineTotal(extra.unitPrice, qty)),
                  style: const TextStyle(fontSize: 12)),
          ],
        ),
      ));
      tiles.addAll(_extraTiles(extra.extras, qty, scheme, depth: depth + 1));
    }
    return tiles;
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

/// How much cash the customer handed over, and what comes back.
///
/// Opens on the exact amount, so the common case is one tap. The quick
/// buttons are the notes a Saudi customer actually pays with.
class _CashDialog extends StatefulWidget {
  const _CashDialog({required this.due});

  final int due;

  @override
  State<_CashDialog> createState() => _CashDialogState();
}

class _CashDialogState extends State<_CashDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: formatHalalas(widget.due));

  int? get _received => parseHalalas(_controller.text);
  int? get _change {
    final received = _received;
    if (received == null || received < widget.due) return null;
    return received - widget.due;
  }

  /// The next notes up from the bill: 50, 100, 200 and the round tens
  /// between. Only ones that would actually cover it.
  List<int> get _suggestions {
    final out = <int>{};
    for (final note in [1000, 2000, 5000, 10000, 20000, 50000]) {
      if (note >= widget.due) out.add(note);
    }
    // The next whole ten and hundred riyals — what a customer hands over when
    // they are not paying with a single note.
    for (final step in [1000, 10000]) {
      final rounded = ((widget.due + step - 1) ~/ step) * step;
      if (rounded > widget.due) out.add(rounded);
    }
    final list = out.toList()..sort();
    return list.take(4).toList();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final change = _change;
    return AlertDialog(
      title: Text('Cash · ${formatHalalas(widget.due)} due'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true),
              decoration: const InputDecoration(
                labelText: 'Cash received',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_change != null) Navigator.of(context).pop(_received);
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final note in _suggestions)
                  OutlinedButton(
                    onPressed: () => setState(
                        () => _controller.text = formatHalalas(note)),
                    child: Text(formatHalalas(note)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              change == null
                  ? 'Not enough to cover the bill'
                  : 'Change ${formatHalalas(change)}',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: change == null ? Theme.of(context).colorScheme.error
                    : null,
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
          onPressed:
              change == null ? null : () => Navigator.of(context).pop(_received),
          child: const Text('Take cash'),
        ),
      ],
    );
  }
}

/// Settle one bill across several methods.
///
/// The rule the dialog enforces is the one the transaction enforces: the
/// tenders have to come to the bill exactly. Charging is impossible until
/// they do, so a half-paid sale cannot be closed by accident.
class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.total, required this.methods});

  final int total;
  final List<PayMethod> methods;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  final List<Tender> _taken = [];
  final _amount = TextEditingController();
  final _received = TextEditingController();
  PayMethod? _method;

  int get _settled => _taken.fold(0, (a, t) => a + (t.amount ?? 0));
  int get _remaining => widget.total - _settled;

  @override
  void initState() {
    super.initState();
    _method = widget.methods.isEmpty ? null : widget.methods.first;
    _amount.text = formatHalalas(widget.total);
  }

  @override
  void dispose() {
    _amount.dispose();
    _received.dispose();
    super.dispose();
  }

  void _add() {
    final method = _method;
    final amount = parseHalalas(_amount.text);
    if (method == null || amount == null || amount <= 0) return;
    if (amount > _remaining) return;

    final received =
        method.isCash ? parseHalalas(_received.text) ?? amount : amount;
    if (received < amount) return;

    setState(() {
      _taken.add(Tender(
        methodnum: method.methodnum,
        name: method.descript,
        amount: amount,
        tendered: received,
        isCash: method.isCash,
      ));
      _amount.text = formatHalalas(_remaining);
      _received.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final change = _taken.fold<int>(
        0, (a, t) => a + ((t.tendered ?? t.amount!) - t.amount!));

    return AlertDialog(
      title: const Text('Split payment'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Bill ${formatHalalas(widget.total)}'),
                Text(
                  'Remaining ${formatHalalas(_remaining)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _remaining == 0 ? scheme.primary : scheme.error,
                  ),
                ),
              ],
            ),
            const Divider(),
            for (var i = 0; i < _taken.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${_taken[i].name}  '
                    '${formatHalalas(_taken[i].amount!)}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Take it off',
                  onPressed: () => setState(() {
                    _taken.removeAt(i);
                    _amount.text = formatHalalas(_remaining);
                  }),
                ),
              ),
            if (_remaining > 0) ...[
              Wrap(
                spacing: 8,
                children: [
                  for (final method in widget.methods)
                    ChoiceChip(
                      selected: method.methodnum == _method?.methodnum,
                      onSelected: (_) => setState(() => _method = method),
                      label: Text(method.descript),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Amount',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  // Only cash can be over-tendered, so only cash is asked.
                  if (_method?.isCash ?? false) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _received,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Cash received',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _add,
                    child: const Text('Add'),
                  ),
                ],
              ),
            ],
            if (change > 0) ...[
              const SizedBox(height: 8),
              Text('Change ${formatHalalas(change)}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Not until the bill is covered exactly. A sale that closes short is
          // money nobody can find at close of day.
          onPressed: _remaining == 0 && _taken.isNotEmpty
              ? () => Navigator.of(context).pop(List.of(_taken))
              : null,
          child: const Text('Charge'),
        ),
      ],
    );
  }
}

/// One prompt: "1 DRINKS", "Bread Selection", "TABAKAT 6 GRILL".
///
/// Pops the chosen answers, an empty list when an optional prompt is skipped,
/// or null when the cashier cancels the item altogether.
class _QuestionDialog extends StatefulWidget {
  const _QuestionDialog({required this.itemName, required this.question});

  final String itemName;
  final MealQuestion question;

  @override
  State<_QuestionDialog> createState() => _QuestionDialogState();
}

class _QuestionDialogState extends State<_QuestionDialog> {
  final List<MealChoice> _picked = [];

  MealQuestion get _q => widget.question;

  void _choose(MealChoice choice) {
    setState(() => _picked.add(choice));
    if (_picked.length >= _q.pickCount) {
      // The last answer closes the prompt. Most prompts take exactly one, and
      // making the cashier confirm a decision they have already made is a tap
      // per item across a lunch rush.
      Navigator.of(context).pop(List.of(_picked));
    }
  }

  bool _taken(MealChoice choice) =>
      !_q.allowRepeats &&
      _picked.any((c) => c.product.prodnum == choice.product.prodnum);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remaining = _q.pickCount - _picked.length;

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_q.prompt),
          Text(
            widget.itemName,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_q.pickCount > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Choose $remaining more of ${_q.pickCount}'
                  '${_q.allowRepeats ? " — repeats allowed" : ""}',
                  style: TextStyle(color: scheme.primary),
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final choice in _q.choices)
                      SizedBox(
                        width: 170,
                        height: 72,
                        child: OutlinedButton(
                          onPressed:
                              _taken(choice) ? null : () => _choose(choice),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.all(8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text(
                            choice.product.descript,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_picked.isNotEmpty) ...[
              const Divider(),
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < _picked.length; i++)
                    InputChip(
                      label: Text(_picked[i].product.descript),
                      onDeleted: () => setState(() => _picked.removeAt(i)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel item'),
        ),
        // Only where the source says the prompt may go unanswered. Two of the
        // twenty-two are optional; offering Skip on the rest would let a meal
        // reach the kitchen with no main course chosen.
        if (!_q.isRequired)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(List.of(_picked)),
            child: Text(_picked.isEmpty ? 'Skip' : 'Done'),
          ),
      ],
    );
  }
}
