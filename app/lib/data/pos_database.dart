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
    this.needsTable = false,
    this.defaultMethodnum,
  });

  final int no;
  final String descript;
  final String priceTier;
  final bool isAggregator;
  final bool requiresExternalRef;

  /// Table service. Dine-In carries this in the imported catalog, and it is
  /// what makes the till start on the floor instead of the menu.
  final bool needsTable;

  /// The method this trade is normally settled with, when the catalog says.
  /// Null throughout this customer's data, so the till falls back to its own
  /// rule.
  final int? defaultMethodnum;
}

/// A prompt a product asks before it can be rung: "1 DRINKS", "Bread
/// Selection". The answers are themselves products.
class MealQuestion {
  MealQuestion({
    required this.questionNo,
    required this.prompt,
    required this.isRequired,
    required this.pickCount,
    required this.allowRepeats,
    required this.choices,
  });

  final int questionNo;
  final String prompt;

  /// False lets the cashier move on without answering. Two of the imported
  /// prompts are optional; the rest must be answered.
  final bool isRequired;

  /// How many answers to take. One is the common case; the Tabakat platters
  /// ask for six.
  final int pickCount;
  final bool allowRepeats;
  final List<MealChoice> choices;
}

class MealChoice {
  MealChoice({
    required this.product,
    required this.unitPrice,
    required this.qty,
  });

  final CatalogProduct product;

  /// What it adds to the bill. Zero throughout the imported catalog — the
  /// meal price already includes it.
  final int unitPrice;
  final double qty;
}

/// Something that hangs off a cart line: an answer the cashier chose, or an
/// item the combo always includes and nobody is asked about.
class CartExtra {
  CartExtra({
    required this.product,
    required this.qty,
    required this.unitPrice,
    this.questionNo,
    this.printIt = true,
    this.extras = const [],
  });

  final CatalogProduct product;

  /// Per one of the parent line. Two of the parent means two of these.
  final double qty;
  final int unitPrice;

  /// Which prompt it answers, or null when it is a fixed combo item.
  final int? questionNo;

  /// False keeps it off the kitchen ticket while leaving it on the bill.
  final bool printIt;

  /// Answers to prompts this item asks in its own right. Eight choices in the
  /// imported catalog are themselves products that ask something — the two
  /// sandwiches inside "2 SANDWICH OFFER" each want their own bread — and
  /// flattening those onto the meal would lose which bread went with which
  /// sandwich.
  final List<CartExtra> extras;
}

class CartLine {
  CartLine({
    required this.product,
    required this.qty,
    this.note,
    this.extras = const [],
    this.sent = false,
  });

  final CatalogProduct product;
  double qty;
  String? note;

  /// Already fired to the kitchen and saved onto the table's check. A dine-in
  /// round goes to the kitchen long before anyone pays, so the bill that
  /// eventually closes must not send the food a second time.
  bool sent;

  /// Chosen answers and included combo items, in the order they were asked.
  final List<CartExtra> extras;
}

/// A payment method the till can take, from the synced catalog.
class PayMethod {
  PayMethod({
    required this.methodnum,
    required this.descript,
    required this.isCash,
    required this.opensDrawer,
  });

  final int methodnum;
  final String descript;

  /// Cash behaves differently in two ways that matter: it is the only tender
  /// that can be over-paid and give change, and it opens the drawer.
  final bool isCash;
  final bool opensDrawer;
}

/// One tender against a bill.
///
/// A bill can be settled with several: half on a card and the rest in cash is
/// ordinary at a counter, and a till that can only take one payment forces the
/// cashier to ring two sales for one customer — which splits the tax invoice,
/// the order number and the kitchen ticket for no reason.
class Tender {
  const Tender({
    required this.methodnum,
    required this.name,
    required int this.amount,
    this.tendered,
    this.isCash = false,
  });

  /// Covers whatever the bill comes to. The one-payment case, where the
  /// caller cannot know the total before the sale has been priced.
  const Tender.whole({
    required this.methodnum,
    required this.name,
    this.tendered,
    this.isCash = false,
  }) : amount = null;

  final int methodnum;

  /// Snapshot for the receipt: what the customer is told they paid with.
  final String name;

  /// What this tender settles, in halalas. Null means "the rest of the bill".
  final int? amount;

  /// What the customer actually handed over. Null means exactly [amount];
  /// more than that is change, and only cash can do it.
  final int? tendered;
  final bool isCash;
}

/// What one tender came to once the bill was priced.
class SettledTender {
  SettledTender({
    required this.methodnum,
    required this.name,
    required this.amount,
    required this.change,
  });

  final int methodnum;
  final String name;
  final int amount;
  final int change;
}

class CompletedSale {
  CompletedSale({
    required this.saleUuid,
    required this.receiptNo,
    required this.netTotal,
    required this.taxTotal,
    required this.finalTotal,
    required this.kitchenStations,
    this.payments = const [],
    this.stamp,
  });

  final String saleUuid;
  final String receiptNo;
  final int netTotal;
  final int taxTotal;
  final int finalTotal;

  /// Station names that received a ticket for this sale.
  final List<String> kitchenStations;

  /// What was actually taken, in the order it was taken. Comes back from the
  /// transaction rather than from the screen so the receipt prints what was
  /// recorded.
  final List<SettledTender> payments;

  /// The ZATCA stamp, or null when this device is not provisioned to sign.
  /// Null means the receipt prints the UNSIGNED banner and the backend will
  /// reject the push — both deliberate, both visible.
  final ZatcaStamp? stamp;
}

/// One item on a kitchen ticket while the ticket is being cut: see
/// [PosDatabase._cutKitchenTickets].
class _TicketNode {
  _TicketNode({
    required this.product,
    required this.qty,
    required this.note,
    required this.reach,
    required this.children,
  });

  final CatalogProduct product;
  final double qty;
  final String? note;

  /// Every station this item or anything inside it cooks at.
  final Set<int> reach;
  final List<_TicketNode> children;
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
    // Another process may hold the file — a second copy of the app, or the
    // enrolment tool. Waiting is right; failing instantly is not.
    db.execute('PRAGMA busy_timeout = 5000');

    // Deciding whether this file is new, and building it if it is, happens
    // inside ONE exclusive transaction. Two copies of the app starting
    // together — a double-tapped icon — could otherwise both read an empty
    // schema and both run the CREATE script, and that wipes a till which may
    // be holding a day of sales that never reached the backend. A database
    // was destroyed exactly this way while testing this build.
    //
    // The test is "has this file ANY table", not "has it a product table":
    // a file left half-built by an interrupted first run has tables but no
    // product, and running the create script over it is at best an error and
    // at worst the same loss.
    db.execute('BEGIN EXCLUSIVE');
    bool fresh;
    try {
      fresh = db
          .select("SELECT name FROM sqlite_master "
              "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1")
          .isEmpty;
      if (fresh) {
        db.execute(schemaSql);
        db.execute('PRAGMA user_version = $tabletSchemaVersion');
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      // Close the handle before giving up. Leaving it open holds a lock on a
      // database the caller has no reference to and cannot close.
      db.dispose();
      rethrow;
    }

    // Outside the transaction above: the migration runs one of its own, and a
    // half-migrated tablet must be able to roll back on its own terms.
    if (!fresh) {
      try {
        migrateTabletSchema(db);
      } catch (_) {
        db.dispose();
        rethrow;
      }
    }
    return PosDatabase(db, signer: signer);
  }

  void dispose() => _db.dispose();

  // ---------------------------------------------------------------- catalog

  List<SalesType> salesTypes() {
    final rows = _db.select(
      'SELECT sale_type_no, descript, price_tier, is_aggregator, '
      '       requires_external_ref, needs_table, default_methodnum '
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
          needsTable: (r['needs_table'] as int? ?? 0) != 0,
          defaultMethodnum: r['default_methodnum'] as int?,
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

  /// The product columns every catalog read selects, aliased off `p`.
  static const _productColumns =
      'p.prodnum, p.descript, p.print_loc, p.tax_applies, '
      'p.price_a, p.price_b, p.price_c, p.price_d, p.price_e, '
      'p.price_f, p.price_g, p.price_h, p.price_i, p.price_j, '
      'p.button_text, p.fore_color, p.back_color';

  /// What [prodnum] must ask before it can be rung, in slot order.
  ///
  /// A question with no offerable answer left is dropped rather than shown: a
  /// prompt whose choices have all been withdrawn is a dialog with no buttons,
  /// and if it were required the item could never be sold at all.
  List<MealQuestion> questionsFor(int prodnum) {
    final rows = _db.select(
      'SELECT q.question_no, q.prompt, q.is_required, q.pick_count, '
      '       q.allow_repeats '
      'FROM product_question pq '
      'JOIN question q ON q.question_no = pq.question_no '
      'WHERE pq.prodnum = ? AND pq.is_deleted = 0 '
      '  AND q.is_active = 1 AND q.is_deleted = 0 '
      'ORDER BY pq.slot',
      [prodnum],
    );

    final questions = <MealQuestion>[];
    for (final r in rows) {
      final questionNo = r['question_no'] as int;
      final choices = _choicesFor(questionNo);
      if (choices.isEmpty) continue;
      questions.add(MealQuestion(
        questionNo: questionNo,
        prompt: r['prompt'] as String,
        isRequired: (r['is_required'] as int) != 0,
        pickCount: (r['pick_count'] as int?) ?? 1,
        allowRepeats: (r['allow_repeats'] as int? ?? 0) != 0,
        choices: choices,
      ));
    }
    return questions;
  }

  List<MealChoice> _choicesFor(int questionNo) {
    final rows = _db.select(
      'SELECT $_productColumns, c.fixed_price, c.default_qty '
      'FROM question_choice c '
      'JOIN product p ON p.prodnum = c.prodnum '
      'WHERE c.question_no = ? AND c.is_active = 1 AND c.is_deleted = 0 '
      '  AND p.is_active = 1 AND p.is_deleted = 0 '
      'ORDER BY c.sort_order, p.descript',
      [questionNo],
    );
    return [
      for (final r in rows)
        MealChoice(
          product: _product(r),
          unitPrice: _includedPrice(r['fixed_price'] as int?),
          qty: ((r['default_qty'] as int?) ?? 1).toDouble(),
        ),
    ];
  }

  /// What a chosen or included item adds to the bill.
  ///
  /// The meal price already covers it, so the answer is normally nothing. A
  /// fixed price is honoured if one is ever set — every imported row has
  /// either no fixed price or a fixed price of zero.
  ///
  /// Deliberately NOT [priceFor]: an included drink is priced at zero on
  /// every tier, and priceFor refuses a zero on a paying tier — correctly,
  /// for something being sold on its own. Running answers through it would
  /// make almost every meal in this catalog unsellable.
  static int _includedPrice(int? fixedPrice) => fixedPrice ?? 0;

  /// What a combo always includes. Two rows for the same product mean two of
  /// them, so identical rows are folded into one line with a quantity — the
  /// kitchen reads "2 x HUMMOS" more reliably than the same line twice.
  List<CartExtra> comboItemsFor(int prodnum) {
    final rows = _db.select(
      'SELECT $_productColumns, ci.fixed_price, ci.print_it, '
      '       COUNT(*) AS how_many, MIN(ci.sort_order) AS first_sort '
      'FROM combo_item ci '
      'JOIN product p ON p.prodnum = ci.prodnum '
      'WHERE ci.parent_prodnum = ? AND ci.is_active = 1 AND ci.is_deleted = 0 '
      '  AND p.is_active = 1 AND p.is_deleted = 0 '
      'GROUP BY p.prodnum, ci.fixed_price, ci.print_it '
      'ORDER BY first_sort, p.descript',
      [prodnum],
    );
    return [
      for (final r in rows)
        CartExtra(
          product: _product(r),
          qty: (r['how_many'] as int).toDouble(),
          unitPrice: _includedPrice(r['fixed_price'] as int?),
          printIt: (r['print_it'] as int? ?? 1) != 0,
        ),
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

  /// One product by number, or null if this catalog has no such thing.
  ///
  /// Used to rebuild a check saved from another device: a session line names
  /// a product number, and the price and routing have to come from the
  /// catalog rather than from whatever the other tablet believed.
  CatalogProduct? product(int prodnum) {
    final rows = _db.select(
      'SELECT $_productColumns FROM product p '
      'WHERE p.prodnum = ? AND p.is_deleted = 0',
      [prodnum],
    );
    return rows.isEmpty ? null : _product(rows.first);
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

  /// The sale type this till was last set to, or null on a new device.
  ///
  /// Worth remembering because a sale type decides more than price: a
  /// table-service one starts the order on the floor and a counter one goes
  /// straight to the menu. A drive-thru till that boots into the floor plan
  /// every morning — because Dine-In sorts first — is one nobody trusts.
  int? activeSaleType() {
    final rows = _db.select('SELECT active_sale_type FROM device WHERE id = 1');
    if (rows.isEmpty) return null;
    return rows.first['active_sale_type'] as int?;
  }

  void setActiveSaleType(int? saleTypeNo) {
    _db.execute(
      'UPDATE device SET active_sale_type = ? WHERE id = 1',
      [saleTypeNo],
    );
  }

  /// What this till can take money with, in the order the catalog gives.
  ///
  /// From the catalog, not a hardcoded list: this customer has six live
  /// methods and an aggregator one, and a till that offers three of them
  /// forces the other trade through the wrong button.
  List<PayMethod> payMethods() {
    final rows = _db.select(
      'SELECT methodnum, descript, is_cash, opens_drawer FROM pay_method '
      'WHERE is_active = 1 AND is_deleted = 0 '
      'ORDER BY sort_order, methodnum',
    );
    return [
      for (final r in rows)
        PayMethod(
          methodnum: r['methodnum'] as int,
          descript: r['descript'] as String,
          isCash: (r['is_cash'] as int) != 0,
          opensDrawer: (r['opens_drawer'] as int) != 0,
        ),
    ];
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
    required List<Tender> payments,
    String? externalRef,
    int? orderNo,
    int empnum = 0,
    int? tableNo,
    int? guests,
  }) {
    if (cart.isEmpty) {
      throw StateError('an empty cart cannot be charged');
    }
    if (payments.isEmpty) {
      throw StateError('a sale has to be paid for');
    }
    // Exactly one tender may say "the rest": two of them have no answer, and
    // silently splitting the remainder between them would invent a division
    // nobody asked for.
    if (payments.where((p) => p.amount == null).length > 1) {
      throw StateError(
        'only one tender can cover the rest of the bill; give the others an '
        'amount',
      );
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

      String addRow({
        required CatalogProduct product,
        required double qty,
        required int unit,
        String? parentUuid,
      }) {
        final gross = lineTotal(unit, qty);
        final split = product.taxApplies
            ? splitInclusive(gross)
            : (net: gross, tax: 0);
        netTotal += split.net;
        taxTotal += split.tax;
        grossTotal += gross;
        final lineUuid = _uuid.v4();
        lineRows.add({
          'line_uuid': lineUuid,
          'line_no': lineNo++,
          'prodnum': product.prodnum,
          'line_des': product.descript,
          'qty': qty,
          'unit_price': unit,
          'net_amount': split.net,
          'tax_amount': split.tax,
          'line_total': gross,
          'apply_tax1': product.taxApplies ? 1 : 0,
          'parent_line': parentUuid,
        });
        return lineUuid;
      }

      // Chosen answers and included combo items, each hung off the line it
      // came out of. They ring at their own price — normally nothing — and
      // scale with the parent: two meals means two drinks. Recursive because
      // a chosen item can itself ask something.
      void addExtras(
          List<CartExtra> extras, double parentQty, String parentUuid) {
        for (final extra in extras) {
          final qty = extra.qty * parentQty;
          final uuid = addRow(
            product: extra.product,
            qty: qty,
            unit: extra.unitPrice,
            parentUuid: parentUuid,
          );
          addExtras(extra.extras, qty, uuid);
        }
      }

      for (final line in cart) {
        final unit = priceFor(
          line.product.tiers,
          salesType.priceTier,
          prodnum: line.product.prodnum,
        );
        final uuid = addRow(product: line.product, qty: line.qty, unit: unit);
        addExtras(line.extras, line.qty, uuid);
      }

      _db.execute(
        'INSERT INTO sale (sale_uuid, receipt_no, opened_at, closed_at, '
        '  business_date, station_no, store_no, emp_open, sale_type, '
        '  table_no, num_guests, order_no, external_ref, net_total, '
        '  tax_total, final_total, status) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          saleUuid, receiptNo, nowIso, nowIso, today,
          device['station_no'], device['store_no'], empnum, salesType.no,
          // Which table this was, and how many sat at it. Covers are what
          // every restaurant report divides by; a dine-in bill without them
          // can be counted but not understood.
          tableNo, guests ?? 1,
          orderNo, externalRef, netTotal, taxTotal, grossTotal, 'closed',
        ],
      );

      for (final r in lineRows) {
        _db.execute(
          'INSERT INTO sale_line (line_uuid, sale_uuid, line_no, prodnum, '
          '  line_des, qty, unit_price, net_amount, tax_amount, line_total, '
          '  apply_tax1, parent_line, ordered_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            r['line_uuid'], saleUuid, r['line_no'], r['prodnum'],
            r['line_des'], r['qty'], r['unit_price'], r['net_amount'],
            r['tax_amount'], r['line_total'], r['apply_tax1'],
            r['parent_line'], nowIso,
          ],
        );
      }

      // Payments, checked against the bill the lines just produced. The till
      // cannot know the total before this point, which is why a tender is
      // allowed to say "the rest" rather than carry an amount.
      final settled = <SettledTender>[];
      final fixed = payments.fold<int>(0, (a, p) => a + (p.amount ?? 0));
      final open = payments.where((p) => p.amount == null).length;
      if (open == 0 && fixed != grossTotal) {
        throw StateError(
          'payments come to ${formatHalalas(fixed)} but the bill is '
          '${formatHalalas(grossTotal)}',
        );
      }
      if (fixed > grossTotal) {
        throw StateError(
          'payments come to ${formatHalalas(fixed)}, more than the '
          '${formatHalalas(grossTotal)} bill — over-payment is change, not a '
          'bigger tender',
        );
      }

      for (final payment in payments) {
        final amount = payment.amount ?? (grossTotal - fixed);
        final tendered = payment.tendered ?? amount;
        final change = tendered - amount;
        if (amount < 0) {
          throw StateError('a tender cannot be negative');
        }
        if (change < 0) {
          throw StateError(
            '${payment.name}: ${formatHalalas(tendered)} handed over does not '
            'cover the ${formatHalalas(amount)} it is settling',
          );
        }
        if (change > 0 && !payment.isCash) {
          // A card terminal takes the amount it is given. Change on one is a
          // typo, and storing it would put money in the drawer that no tender
          // ever paid in.
          throw StateError('${payment.name} cannot give change');
        }
        _db.execute(
          'INSERT INTO sale_payment (payment_uuid, sale_uuid, methodnum, '
          '  tender, change_given, amount, paid_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            _uuid.v4(), saleUuid, payment.methodnum, tendered, change,
            amount, nowIso,
          ],
        );
        settled.add(SettledTender(
          methodnum: payment.methodnum,
          name: payment.name,
          amount: amount,
          change: change,
        ));
      }

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
        tableNo: tableNo,
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
        payments: settled,
        stamp: stamp,
      );
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Send a round to the kitchen without billing it — dine-in's normal case.
  ///
  /// A table orders, eats, orders again and pays at the end, so the food has
  /// to leave the till long before any money does. Everything that has not
  /// been sent yet is fired and marked, and the check stays open on the table
  /// until somebody asks for it.
  ///
  /// No sale, no outbox entry, no ZATCA stamp: none of those exist until the
  /// bill is closed, and inventing them for a round would put an unpaid,
  /// unsigned invoice into the day's takings.
  List<String> sendRound({
    required List<CartLine> cart,
    required SalesType salesType,
    required String sessionUuid,
    int? tableNo,
    int? orderNo,
  }) {
    final unsent = [for (final line in cart) if (!line.sent) line];
    if (unsent.isEmpty) return const [];

    final nowIso = DateTime.now().toUtc().toIso8601String();
    _db.execute('BEGIN IMMEDIATE');
    try {
      final stations = _cutKitchenTickets(
        sessionUuid: sessionUuid,
        tableNo: tableNo,
        cart: unsent,
        salesType: salesType,
        orderNo: orderNo,
        externalRef: null,
        nowIso: nowIso,
      );
      _db.execute('COMMIT');
      for (final line in unsent) {
        line.sent = true;
      }
      return stations;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// One ticket per sale; each line lands on every station its PRINTLOC bits
  /// name. Bit 1 (the local receipt printer) is not a kitchen station.
  ///
  /// A configured item is written as a group. The item goes to every station
  /// the group touches — its own stations plus any its chosen or included
  /// items route to — and each chosen item is written under it there. Two
  /// rules make that necessary rather than tidy:
  ///
  /// * A chosen item often cooks somewhere its parent does not. "2 SANDWICH
  ///   OFFER" routes nowhere at all, and the sandwiches picked inside it go to
  ///   the grill and the shawarma. Routing only by the parent would send the
  ///   kitchen nothing; routing only by the child would put a bare sandwich on
  ///   a screen with no way to tell which offer it belongs to.
  /// * A chosen item with no routing of its own rides with its parent — it is
  ///   part of that item, and the station assembling the meal has to know
  ///   which drink goes in the bag.
  List<String> _cutKitchenTickets({
    String? saleUuid,
    String? sessionUuid,
    int? tableNo,
    required List<CartLine> cart,
    required SalesType salesType,
    required int? orderNo,
    required String? externalRef,
    required String nowIso,
  }) {
    final stations = kitchenStations();
    Set<int> route(int printLoc) => {
          for (final no in stations.keys)
            if (printLoc & (1 << no) != 0) no,
        };

    /// One item on the ticket, with everything chosen inside it.
    ///
    /// `own` is where this item cooks — its own routing, or its parent's when
    /// it has none. `reach` adds where anything under it cooks, and is what
    /// decides the stations the item is written to: an item has to appear
    /// wherever part of it is being made, or the cook there sees a component
    /// belonging to nothing.
    _TicketNode build(
      CatalogProduct product,
      double qty,
      List<CartExtra> extras,
      Set<int> inherited,
      String? note,
    ) {
      var own = route(product.printLoc);
      if (own.isEmpty) own = inherited;
      final children = [
        for (final e in extras)
          if (e.printIt)
            build(e.product, e.qty * qty, e.extras, own, null),
      ];
      final reach = {...own, for (final c in children) ...c.reach};
      return _TicketNode(
        product: product,
        qty: qty,
        note: note,
        reach: reach,
        children: children,
      );
    }

    final groups = [
      // Only what has not already been made. On a table, earlier rounds went
      // to the kitchen when they were ordered; sending them again with the
      // bill would cook the whole meal twice.
      for (final line in cart)
        if (!line.sent)
          build(line.product, line.qty, line.extras, const {}, line.note),
    ].where((n) => n.reach.isNotEmpty).toList();
    if (groups.isEmpty) return const [];

    final ticketUuid = _uuid.v4();
    _db.execute(
      'INSERT INTO kitchen_ticket (ticket_uuid, order_no, sale_type_no, '
      '  sale_type_name, external_ref, sale_uuid, session_uuid, table_no, '
      '  status, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        ticketUuid, orderNo, salesType.no, salesType.descript,
        externalRef, saleUuid, sessionUuid, tableNo, 'open', nowIso,
      ],
    );

    void insertLine({
      required int lineNo,
      required int prodnum,
      required String des,
      required double qty,
      required int stationNo,
      String? note,
      int? parentLineNo,
    }) {
      _db.execute(
        'INSERT INTO kitchen_ticket_line (line_uuid, ticket_uuid, line_no, '
        '  prodnum, line_des, qty, station_no, note, parent_line_no) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          _uuid.v4(), ticketUuid, lineNo, prodnum, des, qty, stationNo,
          note, parentLineNo,
        ],
      );
    }

    final used = <int>{};
    var lineNo = 1;

    void writeAt(_TicketNode node, int stationNo, int? parentLineNo) {
      if (!node.reach.contains(stationNo)) return;
      final myLineNo = lineNo++;
      insertLine(
        lineNo: myLineNo,
        prodnum: node.product.prodnum,
        des: node.product.descript,
        qty: node.qty,
        stationNo: stationNo,
        note: node.note,
        parentLineNo: parentLineNo,
      );
      for (final child in node.children) {
        writeAt(child, stationNo, myLineNo);
      }
    }

    for (final group in groups) {
      for (final stationNo in group.reach.toList()..sort()) {
        used.add(stationNo);
        writeAt(group, stationNo, null);
      }
    }
    return (used.map((no) => stations[no]!).toSet().toList())..sort();
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
