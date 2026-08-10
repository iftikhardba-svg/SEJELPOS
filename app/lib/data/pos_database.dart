/// The tablet's local database.
///
/// The schema is NOT defined here: `assets/schema.sql` is a byte copy of
/// `docs/sqlite_schema.sql`, the same file the migration tooling loads into
/// test databases — one schema, two consumers, no drift. This wrapper only
/// executes it and speaks SQL against the result.
///
/// Everything the till does offline goes through this class: catalog reads,
/// writing a sale (with its outbox entry, so sync can never miss one), and
/// cutting kitchen tickets routed by the product's PRINTLOC bitmask.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../core/money.dart';
import '../core/pricing.dart';
import '../zatca/device_signer.dart';
import 'schema_migrations.dart';

const _uuid = Uuid();

class CatalogProduct {
  CatalogProduct({
    required this.prodnum,
    required this.descript,
    required this.tiers,
    required this.printLoc,
    required this.taxApplies,
    this.buttonText,
    this.foreColor,
    this.backColor,
    this.posX,
    this.posY,
  });

  final int prodnum;
  final String descript;
  final PriceTiers tiers;
  final int printLoc;
  final bool taxApplies;

  /// What the tile says, which is not the description: it is what fits, and
  /// on the imported menu 308 of 560 differ.
  final String? buttonText;

  /// '#RRGGBB', or null to use the app's theme.
  final String? foreColor;
  final String? backColor;

  /// Where the button sits on its page. Null on a product fetched outside a
  /// page context.
  final int? posX;
  final int? posY;

  /// The label a cashier reads.
  String get label => (buttonText == null || buttonText!.isEmpty)
      ? descript
      : buttonText!;
}

/// A page tile on the menu a till opens on.
class MenuTile {
  MenuTile({
    required this.screenNo,
    required this.name,
    required this.posX,
    required this.posY,
    this.foreColor,
    this.backColor,
  });

  final int screenNo;
  final String name;
  final int posX;
  final int posY;
  final String? foreColor;
  final String? backColor;
}

class SalesType {
  SalesType({
    required this.no,
    required this.descript,
    required this.priceTier,
    required this.isAggregator,
    required this.requiresExternalRef,
  });

  final int no;
  final String descript;
  final String priceTier;
  final bool isAggregator;
  final bool requiresExternalRef;
}

class CartLine {
  CartLine({required this.product, required this.qty, this.note});

  final CatalogProduct product;
  double qty;
  String? note;
}

class CompletedSale {
  CompletedSale({
    required this.saleUuid,
    required this.receiptNo,
    required this.netTotal,
    required this.taxTotal,
    required this.finalTotal,
    required this.kitchenStations,
    this.stamp,
  });

  final String saleUuid;
  final String receiptNo;
  final int netTotal;
  final int taxTotal;
  final int finalTotal;

  /// Station names that received a ticket for this sale.
  final List<String> kitchenStations;

  /// The ZATCA stamp, or null when this device is not provisioned to sign.
  /// Null means the receipt prints the UNSIGNED banner and the backend will
  /// reject the push — both deliberate, both visible.
  final ZatcaStamp? stamp;
}

class PosDatabase {
  PosDatabase(this._db, {this.signer});

  final Database _db;

  /// Stamps each closed sale as this device's next ZATCA invoice. Null on a
  /// device that is not provisioned to sign; sales still complete and print
  /// with the UNSIGNED banner.
  final DeviceSigner? signer;

  /// Opens an in-memory database and builds it from [schemaSql] — the content
  /// of assets/schema.sql. Used by tests and the demo path.
  factory PosDatabase.openInMemory(String schemaSql, {DeviceSigner? signer}) {
    final db = sqlite3.openInMemory();
    db.execute(schemaSql);
    return PosDatabase(db, signer: signer);
  }

  /// Opens (or creates) the on-disk database at [path].
  ///
  /// A brand new file gets `schema.sql`, which is a CREATE script. An
  /// existing one gets migrated forward from whatever `PRAGMA user_version`
  /// says built it — see [migrateTabletSchema]. Without that, every schema
  /// change shipped in an update breaks every tablet already in service:
  /// during development the file just gets deleted, and a restaurant cannot
  /// do that to a till mid-shift.
  ///
  /// foreign_keys is per-connection in SQLite and must be switched on at
  /// every open, not just at creation.
  factory PosDatabase.openFile(String path, String schemaSql,
      {DeviceSigner? signer}) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA foreign_keys = ON');
    final fresh = db
        .select("SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name = 'product'")
        .isEmpty;
    if (fresh) {
      db.execute(schemaSql);
      db.execute('PRAGMA user_version = $tabletSchemaVersion');
    } else {
      migrateTabletSchema(db);
    }
    return PosDatabase(db, signer: signer);
  }

  void dispose() => _db.dispose();

  // ---------------------------------------------------------------- catalog

  List<SalesType> salesTypes() {
    final rows = _db.select(
      'SELECT sale_type_no, descript, price_tier, is_aggregator, '
      '       requires_external_ref '
      'FROM sales_type WHERE is_active = 1 AND is_deleted = 0 '
      'ORDER BY sort_order, sale_type_no',
    );
    return [
      for (final r in rows)
        SalesType(
          no: r['sale_type_no'] as int,
          descript: r['descript'] as String,
          priceTier: r['price_tier'] as String,
          isAggregator: (r['is_aggregator'] as int) != 0,
          requiresExternalRef: (r['requires_external_ref'] as int) != 0,
        ),
    ];
  }

  List<CatalogProduct> productsForScreen(int menuId) {
    final rows = _db.select(
      'SELECT p.prodnum, p.descript, p.print_loc, p.tax_applies, '
      '       p.price_a, p.price_b, p.price_c, p.price_d, p.price_e, '
      '       p.price_f, p.price_g, p.price_h, p.price_i, p.price_j, '
      '       p.button_text, p.fore_color, p.back_color, '
      '       b.pos_x, b.pos_y '
      'FROM menu_button b '
      'JOIN product p ON p.prodnum = b.prodnum '
      'WHERE b.menu_id = ? AND b.is_deleted = 0 '
      '  AND p.is_active = 1 AND p.is_deleted = 0 AND p.is_modifier = 0 '
      'ORDER BY b.pos_y, b.pos_x, b.position',
      [menuId],
    );
    return [for (final r in rows) _product(r)];
  }

  /// The menu a till opens on: the tiles, in grid order.
  ///
  /// Picks the first active menu that actually has pages on it. A site with
  /// several menus — this customer has three — usually has one laid out and
  /// the rest empty, and landing on an empty one would look like a broken
  /// till.
  ({int menuNo, String name})? defaultMenu() {
    final rows = _db.select(
      'SELECT m.menu_no, m.name FROM menu m '
      'WHERE m.is_active = 1 AND m.is_deleted = 0 '
      '  AND EXISTS (SELECT 1 FROM menu_page p '
      '              WHERE p.menu_no = m.menu_no AND p.is_active = 1 '
      '                AND p.is_deleted = 0 AND p.pos_x IS NOT NULL) '
      'ORDER BY m.menu_no LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return (menuNo: rows.first['menu_no'] as int,
            name: rows.first['name'] as String);
  }

  /// Page tiles on [menuNo], only those that lead somewhere: a tile onto an
  /// empty page is a dead end a cashier finds mid-service.
  List<MenuTile> menuTiles(int menuNo) {
    final rows = _db.select(
      'SELECT p.screen_no, p.pos_x, p.pos_y, s.name, '
      '       s.fore_color, s.back_color '
      'FROM menu_page p '
      'JOIN menu_screen s ON s.menu_id = p.screen_no '
      'WHERE p.menu_no = ? AND p.is_active = 1 AND p.is_deleted = 0 '
      '  AND p.pos_x IS NOT NULL AND p.pos_y IS NOT NULL '
      '  AND s.is_active = 1 AND s.is_deleted = 0 '
      '  AND EXISTS ('
      '    SELECT 1 FROM menu_button b '
      '    JOIN product pr ON pr.prodnum = b.prodnum '
      '    WHERE b.menu_id = s.menu_id AND b.is_deleted = 0 '
      '      AND pr.is_active = 1 AND pr.is_deleted = 0 AND pr.is_modifier = 0'
      '  ) '
      'ORDER BY p.pos_y, p.pos_x',
      [menuNo],
    );
    return [
      for (final r in rows)
        MenuTile(
          screenNo: r['screen_no'] as int,
          name: r['name'] as String,
          posX: r['pos_x'] as int,
          posY: r['pos_y'] as int,
          foreColor: r['fore_color'] as String?,
          backColor: r['back_color'] as String?,
        ),
    ];
  }

  /// Menu screens a cashier can actually use.
  ///
  /// Screens with no sellable product on them are excluded. A migrated
  /// PixelPoint catalog carries plenty of them — 'No Page', 'Test Page',
  /// 'Commands' — and they sort to the front, so the till opened on an empty
  /// grid and a cashier saw nothing at all. Nothing is deleted: the screens
  /// remain in the catalog and in the back office, they just do not take a
  /// tab on a till where they would do nothing.
  List<({int menuId, String name})> menuScreens() {
    final rows = _db.select(
      'SELECT s.menu_id, s.name FROM menu_screen s '
      'WHERE s.is_active = 1 AND s.is_deleted = 0 '
      '  AND s.is_modifier_screen = 0 '
      '  AND EXISTS ('
      '    SELECT 1 FROM menu_button b '
      '    JOIN product p ON p.prodnum = b.prodnum '
      '    WHERE b.menu_id = s.menu_id AND b.is_deleted = 0 '
      '      AND p.is_active = 1 AND p.is_deleted = 0 AND p.is_modifier = 0'
      '  ) '
      'ORDER BY s.sort_order, s.menu_id',
    );
    return [
      for (final r in rows)
        (menuId: r['menu_id'] as int, name: r['name'] as String),
    ];
  }

  CatalogProduct _product(Row r) => CatalogProduct(
        prodnum: r['prodnum'] as int,
        descript: r['descript'] as String,
        tiers: [
          for (final c in const [
            'price_a', 'price_b', 'price_c', 'price_d', 'price_e',
            'price_f', 'price_g', 'price_h', 'price_i', 'price_j',
          ])
            r[c] as int?,
        ],
        printLoc: (r['print_loc'] as int?) ?? 0,
        taxApplies: (r['tax_applies'] as int) != 0,
        buttonText: _maybe(r, 'button_text'),
        foreColor: _maybe(r, 'fore_color'),
        backColor: _maybe(r, 'back_color'),
        posX: _maybeInt(r, 'pos_x'),
        posY: _maybeInt(r, 'pos_y'),
      );

  /// Not every query selects the button columns, so reading one that was not
  /// asked for must be absent rather than an error.
  static String? _maybe(Row r, String column) {
    try {
      final value = r[column];
      return value is String && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  static int? _maybeInt(Row r, String column) {
    try {
      return r[column] as int?;
    } catch (_) {
      return null;
    }
  }

  /// Cashiers who can be put on this till, in the order a human scans a list.
  List<({int empnum, String name})> cashiers() {
    final rows = _db.select(
      'SELECT empnum, name FROM employee '
      'WHERE is_active = 1 AND is_deleted = 0 ORDER BY name, empnum',
    );
    return [
      for (final r in rows)
        (empnum: r['empnum'] as int, name: r['name'] as String),
    ];
  }

  /// Who is on the till, or null if nobody has been chosen yet.
  int? activeCashier() {
    final rows = _db.select('SELECT active_empnum FROM device WHERE id = 1');
    if (rows.isEmpty) return null;
    return rows.first['active_empnum'] as int?;
  }

  void setActiveCashier(int? empnum) {
    _db.execute(
      'UPDATE device SET active_empnum = ? WHERE id = 1',
      [empnum],
    );
  }

  /// station_no -> name, for routing lines off the PRINTLOC bitmask.
  Map<int, String> kitchenStations() {
    final rows = _db.select(
      'SELECT station_no, name FROM kitchen_station '
      'WHERE is_active = 1 AND is_deleted = 0',
    );
    return {
      for (final r in rows) r['station_no'] as int: r['name'] as String,
    };
  }

  // ------------------------------------------------------------------ sales

  /// Close a sale: the one transaction the whole till exists for.
  ///
  /// Writes the sale, its lines and payment, an outbox entry (so sync can
  /// never miss it), the kitchen tickets its lines route to, and advances the
  /// device's receipt counter — atomically. If anything fails, nothing
  /// happened; the customer is never mid-charged.
  CompletedSale completeSale({
    required List<CartLine> cart,
    required SalesType salesType,
    required int methodnum,
    String? externalRef,
    int? orderNo,
    int empnum = 0,
  }) {
    if (cart.isEmpty) {
      throw StateError('an empty cart cannot be charged');
    }
    // A sale always has a cashier — emp_open is NOT NULL and a foreign key.
    // Checked here so an unknown one reads as a cashier problem instead of
    // surfacing as "SQLException 787" from deep inside the transaction. The
    // demo catalog seeds empnum 0, which hid this until a real migrated
    // catalog (staff 999, 2001-2012, no zero) reached a till.
    final known = _db.select(
      'SELECT 1 FROM employee WHERE empnum = ? AND is_active = 1',
      [empnum],
    );
    if (known.isEmpty) {
      throw StateError(
        'no active cashier with number $empnum on this device — '
        'choose who is on the till before charging',
      );
    }
    if (salesType.requiresExternalRef &&
        (externalRef == null || externalRef.trim().isEmpty)) {
      throw StateError(
        '${salesType.descript} orders need the aggregator order reference — '
        'without it a disputed order can never be matched',
      );
    }

    final saleUuid = _uuid.v4();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final today = nowIso.substring(0, 10);

    _db.execute('BEGIN IMMEDIATE');
    try {
      final device = _db.select(
        'SELECT receipt_prefix, next_receipt_seq, station_no, store_no '
        'FROM device WHERE id = 1',
      ).first;
      final seq = device['next_receipt_seq'] as int;
      final receiptNo =
          '${device['receipt_prefix']}-${seq.toString().padLeft(6, '0')}';

      var netTotal = 0;
      var taxTotal = 0;
      var grossTotal = 0;
      final lineRows = <Map<String, Object?>>[];

      var lineNo = 1;
      for (final line in cart) {
        final unit = priceFor(
          line.product.tiers,
          salesType.priceTier,
          prodnum: line.product.prodnum,
        );
        final gross = lineTotal(unit, line.qty);
        final split = line.product.taxApplies
            ? splitInclusive(gross)
            : (net: gross, tax: 0);
        netTotal += split.net;
        taxTotal += split.tax;
        grossTotal += gross;
        lineRows.add({
          'line_uuid': _uuid.v4(),
          'line_no': lineNo++,
          'prodnum': line.product.prodnum,
          'line_des': line.product.descript,
          'qty': line.qty,
          'unit_price': unit,
          'net_amount': split.net,
          'tax_amount': split.tax,
          'line_total': gross,
          'apply_tax1': line.product.taxApplies ? 1 : 0,
        });
      }

      _db.execute(
        'INSERT INTO sale (sale_uuid, receipt_no, opened_at, closed_at, '
        '  business_date, station_no, store_no, emp_open, sale_type, '
        '  order_no, external_ref, net_total, tax_total, final_total, status) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          saleUuid, receiptNo, nowIso, nowIso, today,
          device['station_no'], device['store_no'], empnum, salesType.no,
          orderNo, externalRef, netTotal, taxTotal, grossTotal, 'closed',
        ],
      );

      for (final r in lineRows) {
        _db.execute(
          'INSERT INTO sale_line (line_uuid, sale_uuid, line_no, prodnum, '
          '  line_des, qty, unit_price, net_amount, tax_amount, line_total, '
          '  apply_tax1, ordered_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            r['line_uuid'], saleUuid, r['line_no'], r['prodnum'],
            r['line_des'], r['qty'], r['unit_price'], r['net_amount'],
            r['tax_amount'], r['line_total'], r['apply_tax1'], nowIso,
          ],
        );
      }

      _db.execute(
        'INSERT INTO sale_payment (payment_uuid, sale_uuid, methodnum, '
        '  tender, amount, paid_at) VALUES (?, ?, ?, ?, ?, ?)',
        [_uuid.v4(), saleUuid, methodnum, grossTotal, grossTotal, nowIso],
      );

      // Stamp it as this device's next ZATCA invoice. Inside the transaction
      // by necessity: the stamp and the ICV it consumes have to land together
      // or the device's hash chain breaks. A device that cannot sign returns
      // null and the sale stands — the customer is never blocked by a
      // provisioning problem.
      final stamp = signer?.stampSale(_db, saleUuid);

      // The outbox row IS the guarantee the sale reaches the backend. Written
      // in the same transaction as the sale: there is no code path where one
      // exists without the other.
      _db.execute(
        'INSERT INTO outbox (entity, entity_uuid, payload, created_at) '
        'VALUES (?, ?, ?, ?)',
        ['sale', saleUuid, jsonEncode({'sale_uuid': saleUuid}), nowIso],
      );

      final stations = _cutKitchenTickets(
        saleUuid: saleUuid,
        cart: cart,
        salesType: salesType,
        orderNo: orderNo,
        externalRef: externalRef,
        nowIso: nowIso,
      );

      _db.execute(
        'UPDATE device SET next_receipt_seq = ? WHERE id = 1',
        [seq + 1],
      );

      _db.execute('COMMIT');
      return CompletedSale(
        saleUuid: saleUuid,
        receiptNo: receiptNo,
        netTotal: netTotal,
        taxTotal: taxTotal,
        finalTotal: grossTotal,
        kitchenStations: stations,
        stamp: stamp,
      );
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// One ticket per sale; each line lands on every station its PRINTLOC bits
  /// name. Bit 1 (the local receipt printer) is not a kitchen station.
  List<String> _cutKitchenTickets({
    required String saleUuid,
    required List<CartLine> cart,
    required SalesType salesType,
    required int? orderNo,
    required String? externalRef,
    required String nowIso,
  }) {
    final stations = kitchenStations();
    final routed = <({CartLine line, int stationNo})>[];
    for (final line in cart) {
      for (final entry in stations.entries) {
        if (line.product.printLoc & (1 << entry.key) != 0) {
          routed.add((line: line, stationNo: entry.key));
        }
      }
    }
    if (routed.isEmpty) return const [];

    final ticketUuid = _uuid.v4();
    _db.execute(
      'INSERT INTO kitchen_ticket (ticket_uuid, order_no, sale_type_no, '
      '  sale_type_name, external_ref, sale_uuid, status, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        ticketUuid, orderNo, salesType.no, salesType.descript,
        externalRef, saleUuid, 'open', nowIso,
      ],
    );
    var lineNo = 1;
    for (final r in routed) {
      _db.execute(
        'INSERT INTO kitchen_ticket_line (line_uuid, ticket_uuid, line_no, '
        '  prodnum, line_des, qty, station_no, note) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          _uuid.v4(), ticketUuid, lineNo++, r.line.product.prodnum,
          r.line.product.descript, r.line.qty, r.stationNo, r.line.note,
        ],
      );
    }
    return (routed.map((r) => stations[r.stationNo]!).toSet().toList())..sort();
  }

  // ------------------------------------------------------------------ setup

  /// Minimal device identity until enrolment is wired to the backend.
  void provisionDevice({
    required String deviceUuid,
    required String receiptPrefix,
    int stationNo = 1,
    int storeNo = 1,
  }) {
    _db.execute(
      'INSERT OR IGNORE INTO device (id, device_uuid, station_no, store_no, '
      '  receipt_prefix) VALUES (1, ?, ?, ?, ?)',
      [deviceUuid, stationNo, storeNo, receiptPrefix],
    );
  }

  int outboxDepth() =>
      _db.select('SELECT COUNT(*) AS n FROM outbox').first['n'] as int;

  Row saleRow(String saleUuid) => _db
      .select('SELECT * FROM sale WHERE sale_uuid = ?', [saleUuid]).first;

  List<Row> saleLines(String saleUuid) => _db.select(
      'SELECT * FROM sale_line WHERE sale_uuid = ? ORDER BY line_no',
      [saleUuid]);

  List<Row> kitchenTicketLines(String saleUuid) => _db.select(
      'SELECT l.* FROM kitchen_ticket_line l '
      'JOIN kitchen_ticket t ON t.ticket_uuid = l.ticket_uuid '
      'WHERE t.sale_uuid = ? ORDER BY l.line_no',
      [saleUuid]);

  Database get raw => _db;
}
