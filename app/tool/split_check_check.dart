/// Split a real table's check between guests, against a real customer catalog.
///
///     dart run tool/split_check_check.dart <baseUrl> <enrolmentCode>
///
/// Enrols a throwaway device, seats a free table, orders a meal that asks
/// questions plus three of a plain item, saves the round onto the check, then
/// pays for it in three separate bills — one guest's meal, one of the three,
/// and the rest — through the till's own completeSale and the same check
/// translation the screen uses.
///
/// It exists because the demo catalog hides what the real one exposes, and
/// because a split has one failure that must never happen: two bills claiming
/// the same food, or food that ends up on no bill at all. So the check is
/// re-read from the server between every payment and the three invoices are
/// added back up against it.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:uuid/uuid.dart';

import 'package:pos_app/core/pricing.dart';
import 'package:pos_app/data/check_lines.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/sync/sync_service.dart';

int _fail(String why) {
  stderr.writeln('FAILED: $why');
  exit(1);
}

/// Answer every prompt by taking the first offered choice, recursing into
/// choices that ask something themselves.
List<CartExtra> configure(PosDatabase db, int prodnum, {int depth = 0}) {
  final extras = <CartExtra>[];
  for (final question in db.questionsFor(prodnum)) {
    for (var i = 0; i < question.pickCount; i++) {
      final choice = question.allowRepeats
          ? question.choices.first
          : question.choices[i % question.choices.length];
      extras.add(CartExtra(
        product: choice.product,
        qty: choice.qty,
        unitPrice: choice.unitPrice,
        questionNo: question.questionNo,
        extras: depth < 3
            ? configure(db, choice.product.prodnum, depth: depth + 1)
            : const [],
      ));
    }
  }
  extras.addAll(db.comboItemsFor(prodnum));
  return extras;
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/split_check_check.dart '
        '<baseUrl> <enrolmentCode>');
    exit(2);
  }

  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }

  final dir = Directory.systemTemp.createTempSync('pos-split-check');
  final db = PosDatabase.openFile(
    '${dir.path}/pos.db',
    File('assets/schema.sql').readAsStringSync(),
  );
  final api = SyncApi(baseUrl: args[0]);
  final sync = SyncService(db: db, api: api);

  try {
    await sync.enrolAndPrime(
        code: args[1], deviceUuid: 'device-${const Uuid().v4()}');
    final token = db.raw
        .select('SELECT auth_token FROM device WHERE id = 1')
        .first['auth_token'] as String;
    final floorApi = SyncApi(baseUrl: args[0], token: token);

    // ------------------------------------------------------------- the room
    final floor = await floorApi.getFloor();
    final tables = (floor['tables'] as List).cast<Map<String, dynamic>>();
    final free = tables.firstWhere(
      (t) => t['status'] == 'free' && t['is_active'] == true,
      orElse: () => _fail('no free table on this floor to seat') as Never,
    );
    // Three guests where the table holds them; a two-top is still worth
    // splitting, and the backend refuses a party bigger than the table.
    final guests = (free['seats'] as int) < 3 ? free['seats'] as int : 3;
    final session =
        await floorApi.openTable(free['id'] as String, guests: guests);
    final sessionId = session['session_id'] as String;
    stdout.writeln('seated table ${free['table_no']} — session $sessionId');

    // ------------------------------------------------------- what they order
    final salesType = db.salesTypes().firstWhere(
          (t) => t.needsTable,
          orElse: () => db.salesTypes().firstWhere((t) => t.priceTier == 'a'),
        );
    final asking = db.raw.select(
      'SELECT DISTINCT pq.prodnum FROM product_question pq '
      'JOIN product p ON p.prodnum = pq.prodnum '
      'WHERE pq.is_deleted = 0 AND p.is_active = 1 AND p.price_a > 0 '
      'ORDER BY pq.prodnum',
    );
    if (asking.isEmpty) _fail('nothing in this catalog asks anything');

    final mealNo = asking.first['prodnum'] as int;
    final plainRow = db.raw.select(
      'SELECT prodnum FROM product WHERE is_active = 1 AND price_a > 0 '
      '  AND prodnum NOT IN (SELECT prodnum FROM product_question) '
      'ORDER BY prodnum LIMIT 1',
    );
    if (plainRow.isEmpty) _fail('no plain priced product in this catalog');
    final plainNo = plainRow.first['prodnum'] as int;

    CatalogProduct load(int prodnum) {
      final r = db.raw.select(
        'SELECT prodnum, descript, print_loc, tax_applies, price_a, price_b, '
        '  price_c, price_d, price_e, price_f, price_g, price_h, price_i, '
        '  price_j FROM product WHERE prodnum = ?',
        [prodnum],
      ).first;
      return CatalogProduct(
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
      );
    }

    final meal = load(mealNo);
    final plain = load(plainNo);
    var cart = [
      CartLine(product: meal, qty: 1, extras: configure(db, mealNo)),
      CartLine(product: plain, qty: 3),
    ];

    // --------------------------------------------- fire it and save the check
    final cashier = db.cashiers().first;
    final stations = db.sendRound(
      cart: cart,
      salesType: salesType,
      sessionUuid: sessionId,
      tableNo: free['table_no'] as int,
    );

    int quoted(CartLine line) =>
        line.unitPrice ??
        priceFor(line.product.tiers, salesType.priceTier,
            prodnum: line.product.prodnum);

    final batch = <Map<String, dynamic>>[];
    final spans = <CartLine, ({int from, int to})>{};
    for (final line in cart) {
      final from = batch.length;
      batch.addAll(sessionLinesFor(line, priceOf: quoted, base: from));
      spans[line] = (from: from, to: batch.length);
    }
    var detail = await floorApi.addSessionLines(sessionId, batch);
    assignLineNumbers(detail, spans, batch.length);
    final checkTotal = detail['gross_total'] as int;
    stdout.writeln('ordered ${meal.descript} + 3 x ${plain.descript} — '
        'check ${(checkTotal / 100).toStringAsFixed(2)}, '
        'kitchen: ${stations.isEmpty ? "nothing routed" : stations.join(", ")}');

    // ------------------------------ picked back up, as another tablet sees it
    final reread = await floorApi.tableSession(free['id'] as String);
    cart = restoreCheck(reread, db.product);
    final restoredTotal = cart.fold<int>(
        0,
        (sum, l) =>
            sum +
            (quoted(l) * l.qty).round() +
            _extras(l.extras, l.qty));
    if (restoredTotal != checkTotal) {
      _fail('the check reads ${restoredTotal / 100} when picked back up, '
          'but the server says ${checkTotal / 100} — a saved check must come '
          'back at the price the guest was quoted');
    }
    final restoredMeal = cart.firstWhere((l) => l.product.prodnum == mealNo);
    if (configure(db, mealNo).isNotEmpty && restoredMeal.extras.isEmpty) {
      _fail('the meal came back flat — what was chosen inside it was lost');
    }

    // --------------------------------------- guest one pays for their own meal
    final bills = <int>[];
    Future<void> pay(List<CartLine> share, String who) async {
      final sale = db.completeSale(
        cart: share,
        salesType: salesType,
        payments: [Tender.whole(methodnum: 1010, name: 'MADA')],
        empnum: cashier.empnum,
        tableNo: free['table_no'] as int,
        guests: guests,
      );
      bills.add(sale.finalTotal);
      final lineNos = [for (final l in share) ...l.sessionLineNos];
      detail = await floorApi.settleLines(
        sessionId,
        saleUuid: sale.saleUuid,
        lineNos: share.length == cart.length ? const [] : lineNos,
      );
      stdout.writeln('$who paid ${(sale.finalTotal / 100).toStringAsFixed(2)} '
          'on receipt ${sale.receiptNo} — table now '
          '${detail['status']}, still owed '
          '${((detail['outstanding_total'] as int) / 100).toStringAsFixed(2)}');
    }

    await pay([restoredMeal], 'guest 1');
    if (detail['status'] != 'open') {
      _fail('the table closed while two guests had not paid');
    }

    // ------------------- guest two takes one of the three, split off the line
    final shared = cart.firstWhere((l) => l.product.prodnum == plainNo);
    detail = await floorApi.splitLine(
        sessionId, shared.sessionLineNos.first, 1);
    cart = restoreCheck(detail, db.product);
    final one = cart.firstWhere((l) => l.product.prodnum == plainNo && l.qty == 1,
        orElse: () => _fail('splitting the line left no line of one') as Never);
    await pay([one], 'guest 2');
    if (detail['status'] != 'open') {
      _fail('the table closed while one guest had not paid');
    }

    // ------------------------------------------------- and the last one pays
    cart = restoreCheck(
        await floorApi.tableSession(free['id'] as String), db.product);
    await pay(cart, 'guest 3');

    // ----------------------------------------------------------- add it back up
    final paid = bills.fold<int>(0, (a, b) => a + b);
    if (paid != checkTotal) {
      _fail('three bills came to ${paid / 100} but the check was '
          '${checkTotal / 100} — food was billed twice or not at all');
    }
    if (detail['status'] != 'billed') {
      _fail('everything is paid but the table reads ${detail['status']}');
    }
    final stillFree = ((await floorApi.getFloor())['tables'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((t) => t['id'] == free['id']);
    if (stillFree['status'] != 'free') {
      _fail('the table still reads ${stillFree['status']} after every guest '
          'has paid');
    }

    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'table': free['table_no'],
      'check_total': checkTotal / 100,
      'bills': [for (final b in bills) b / 100],
      'sales_recorded': db.raw
          .select('SELECT COUNT(*) AS n FROM sale')
          .first['n'],
      'table_after': stillFree['status'],
    }));
    stdout.writeln('PASSED: three guests, three tax invoices, one check, '
        'nothing billed twice');
  } finally {
    db.dispose();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps the file handle a moment longer; the temp dir is fine.
    }
  }
}

int _extras(List<CartExtra> extras, double parentQty) {
  var total = 0;
  for (final extra in extras) {
    final qty = extra.qty * parentQty;
    total += (extra.unitPrice * qty).round() + _extras(extra.extras, qty);
  }
  return total;
}
