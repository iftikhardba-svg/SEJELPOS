/// Ring a meal that asks questions, against a real customer catalog.
///
///     dart run tool/meal_deal_check.dart <baseUrl> <enrolmentCode> [prodnum]
///
/// Enrols a throwaway device, pulls the catalog, then finds the products that
/// ask something and rings one through the till's own completeSale — the same
/// code path the screen uses — printing the bill lines and the kitchen ticket
/// it produced. Name a product number to ring that one instead of the first
/// that both asks and includes.
///
/// This exists because the demo catalog hides what the real one exposes: two
/// hard blockers survived every test on a two-product seed. Prompts are worth
/// the same suspicion — a meal here can ask about a product that was withdrawn
/// years ago, route to a station nothing else uses, or include an item twice.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:uuid/uuid.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/sync/sync_service.dart';

/// Answer every prompt by taking the first offered choice, as many times as
/// the prompt asks for, recursing into choices that ask something themselves.
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
  if (args.length < 2 || args.length > 3) {
    stderr.writeln('usage: dart run tool/meal_deal_check.dart '
        '<baseUrl> <enrolmentCode> [prodnum]');
    exit(2);
  }
  final wanted = args.length == 3 ? int.tryParse(args[2]) : null;

  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }

  final dir = Directory.systemTemp.createTempSync('pos-meal-deal');
  final db = PosDatabase.openFile(
    '${dir.path}/pos.db',
    File('assets/schema.sql').readAsStringSync(),
  );
  final sync = SyncService(db: db, api: SyncApi(baseUrl: args[0]));

  try {
    await sync.enrolAndPrime(
        code: args[1], deviceUuid: 'device-${const Uuid().v4()}');

    final asking = db.raw.select(
      'SELECT DISTINCT pq.prodnum, p.descript FROM product_question pq '
      'JOIN product p ON p.prodnum = pq.prodnum '
      'WHERE pq.is_deleted = 0 AND p.is_active = 1 AND p.price_a > 0 '
      'ORDER BY pq.prodnum',
    );
    final combos = db.raw
        .select('SELECT COUNT(DISTINCT parent_prodnum) AS n FROM combo_item')
        .first['n'];

    stdout.writeln('catalog: ${asking.length} products ask something, '
        '$combos include something');
    if (asking.isEmpty) {
      stderr.writeln('nothing in this catalog asks anything — '
          'either the load did not run or the prompts never reached the device');
      exit(1);
    }

    // A cashier would not choose the meal; the meal is whatever they pressed.
    // Take the first that both asks and includes, so one sale exercises both.
    final chosen = wanted != null
        ? asking.firstWhere((r) => r['prodnum'] == wanted,
            orElse: () => throw StateError(
                'product $wanted is not in this catalog, or asks nothing'))
        : asking.firstWhere(
            (r) => db.comboItemsFor(r['prodnum'] as int).isNotEmpty,
            orElse: () => asking.first,
          );
    final prodnum = chosen['prodnum'] as int;

    final product = db.raw.select(
      'SELECT p.prodnum, p.descript, p.print_loc, p.tax_applies, '
      '  p.price_a, p.price_b, p.price_c, p.price_d, p.price_e, p.price_f, '
      '  p.price_g, p.price_h, p.price_i, p.price_j '
      'FROM product p WHERE p.prodnum = ?',
      [prodnum],
    ).first;

    final catalogProduct = CatalogProduct(
      prodnum: product['prodnum'] as int,
      descript: product['descript'] as String,
      tiers: [
        for (final c in const [
          'price_a', 'price_b', 'price_c', 'price_d', 'price_e',
          'price_f', 'price_g', 'price_h', 'price_i', 'price_j',
        ])
          product[c] as int?,
      ],
      printLoc: (product['print_loc'] as int?) ?? 0,
      taxApplies: (product['tax_applies'] as int) != 0,
    );

    final extras = configure(db, prodnum);
    final cashier = db.cashiers().first;
    final salesType = db.salesTypes().firstWhere((t) => t.priceTier == 'a');

    final sale = db.completeSale(
      cart: [CartLine(product: catalogProduct, qty: 1, extras: extras)],
      salesType: salesType,
      payments: [
        Tender.whole(methodnum: 1010, name: 'MADA'),
      ],
      empnum: cashier.empnum,
    );

    final stations = db.kitchenStations();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'item': '${catalogProduct.descript} ($prodnum)',
      'asked': [
        for (final q in db.questionsFor(prodnum))
          '${q.prompt} — pick ${q.pickCount} of ${q.choices.length}'
              '${q.isRequired ? "" : " (optional)"}',
      ],
      'includes': [
        for (final e in db.comboItemsFor(prodnum))
          '${e.qty.toStringAsFixed(0)} x ${e.product.descript}'
              '${e.printIt ? "" : " (not printed)"}',
      ],
      'total': sale.finalTotal / 100,
      'bill': [
        for (final l in db.saleLines(sale.saleUuid))
          '${l['parent_line'] == null ? "" : "    "}'
              '${(l['qty'] as num).toStringAsFixed(0)} x ${l['line_des']}'
              '  ${((l['line_total'] as int) / 100).toStringAsFixed(2)}',
      ],
      'kitchen': [
        for (final l in db.kitchenTicketLines(sale.saleUuid))
          '[${stations[l['station_no']]}] '
              '${l['parent_line_no'] == null ? "" : "    "}'
              '${(l['qty'] as num).toStringAsFixed(0)} x ${l['line_des']}',
      ],
    }));

    // The bill must still add up: a zero-priced answer is a real zero, and
    // the backend refuses a sale whose lines do not reconcile.
    final lines = db.saleLines(sale.saleUuid);
    final sum = lines.fold<int>(0, (a, l) => a + (l['line_total'] as int));
    if (sum != sale.finalTotal) {
      stderr.writeln('lines sum to $sum but the sale says ${sale.finalTotal}');
      exit(1);
    }
    stdout.writeln('lines reconcile: $sum halalas across ${lines.length} lines');
  } on SyncApiException catch (e) {
    stderr.writeln('backend refused: $e');
    exit(1);
  } finally {
    db.dispose();
    dir.deleteSync(recursive: true);
  }
}
