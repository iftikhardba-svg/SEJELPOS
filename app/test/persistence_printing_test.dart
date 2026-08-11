/// Persistence, the sync worker, and receipt bytes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pos_app/data/demo_catalog.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/printing/escpos.dart';
import 'package:pos_app/printing/printer.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/sync/sync_service.dart';
import 'package:pos_app/sync/sync_worker.dart';

import 'helpers.dart';

void main() {
  setUpAll(useSystemSqlite);

  group('file-backed database', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('posdb'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a sale survives close and reopen, and the receipt counter continues',
        () {
      final path = '${tmp.path}${Platform.pathSeparator}pos.db';
      final schema = loadSchema();

      var db = PosDatabase.openFile(path, schema);
      seedDemoCatalog(db);
      final first = db.completeSale(
        cart: [
          CartLine(
              product: db
                  .productsForScreen(2010)
                  .firstWhere((p) => p.prodnum == 2013),
              qty: 1),
        ],
        salesType: db.salesTypes().firstWhere((t) => t.no == 2025),
        payments: [
          Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
        ],
      );
      expect(first.receiptNo, 'T01-000001');
      db.dispose();

      // The restart. Schema must NOT run again; everything must still be there.
      db = PosDatabase.openFile(path, schema);
      expect(db.saleRow(first.saleUuid)['receipt_no'], 'T01-000001');
      expect(db.outboxDepth(), 1);
      expect(db.productsForScreen(2010), isNotEmpty);

      final second = db.completeSale(
        cart: [
          CartLine(
              product: db
                  .productsForScreen(2010)
                  .firstWhere((p) => p.prodnum == 2013),
              qty: 1),
        ],
        salesType: db.salesTypes().firstWhere((t) => t.no == 2025),
        payments: [
          Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
        ],
      );
      expect(second.receiptNo, 'T01-000002',
          reason: 'receipt numbers must never restart after a reboot');
      db.dispose();
    });

    test('foreign keys are enforced on a reopened file', () {
      final path = '${tmp.path}${Platform.pathSeparator}pos.db';
      var db = PosDatabase.openFile(path, loadSchema());
      seedDemoCatalog(db);
      db.dispose();

      db = PosDatabase.openFile(path, loadSchema());
      // sale.emp_open references employee; empnum 4242 does not exist.
      expect(
        () => db.raw.execute(
          "INSERT INTO sale (sale_uuid, receipt_no, opened_at, business_date, "
          "  station_no, store_no, emp_open, net_total, tax_total, "
          "  final_total, status) "
          "VALUES ('x', 'R-1', 'now', '2026-08-04', 1, 1, 4242, 0, 0, 0, "
          "'closed')",
        ),
        throwsA(anything),
        reason: 'PRAGMA foreign_keys is per-connection and must be re-armed',
      );
      db.dispose();
    });
  });

  group('SyncWorker', () {
    test('one pass pushes kitchen first, then sales, then catalog', () async {
      final db = seededDatabase();
      final lahm = db
          .productsForScreen(2010)
          .firstWhere((p) => p.prodnum == 2152);
      db.completeSale(
        cart: [CartLine(product: lahm, qty: 1)],
        salesType: db.salesTypes().firstWhere((t) => t.no == 2025),
        payments: [
          Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
        ],
      );

      final calls = <String>[];
      final api = SyncApi(
        baseUrl: 'http://b',
        token: 't',
        client: MockClient((request) async {
          calls.add(request.url.path);
          if (request.url.path == '/v1/kds/tickets') {
            return http.Response(request.body, 201,
                headers: {'content-type': 'application/json'});
          }
          if (request.url.path == '/v1/sales') {
            final uuid = ((jsonDecode(request.body) as List).single
                as Map)['sale_uuid'];
            return http.Response(
                jsonEncode({
                  'accepted': [
                    {'sale_uuid': uuid, 'status': 'accepted', 'receipt_no': 'x'}
                  ],
                  'rejected': [],
                }),
                200,
                headers: {'content-type': 'application/json'});
          }
          // catalog
          return http.Response(
              jsonEncode({'version': 2, 'has_more': false}), 200,
              headers: {'content-type': 'application/json'});
        }),
      );

      final result =
          await SyncWorker(sync: SyncService(db: db, api: api)).syncNow();

      expect(result.clean, isTrue, reason: '${result.errors}');
      expect(result.kitchenSent, 1);
      expect(result.salesSent, 1);
      expect(result.catalogVersion, 2);
      expect(calls, ['/v1/kds/tickets', '/v1/sales', '/v1/catalog'],
          reason: 'the kitchen is waiting; bookkeeping is not');
      db.dispose();
    });

    test('a dead backend is reported, never thrown', () async {
      final db = seededDatabase();
      final api = SyncApi(
        baseUrl: 'http://b',
        token: 't',
        client: MockClient((_) async => http.Response('down', 503)),
      );

      final result =
          await SyncWorker(sync: SyncService(db: db, api: api)).syncNow();
      expect(result.clean, isFalse);
      expect(result.errors, isNotEmpty);
      db.dispose();
    });
  });

  group('ESC/POS receipt', () {
    ReceiptData receipt({String? qr}) => ReceiptData(
          brandName: 'Fatima Restaurant',
          vatNumber: '310000000000003',
          receiptNo: 'T01-000042',
          orderNo: '17',
          dateTime: DateTime(2026, 8, 4, 20, 15),
          lines: const [
            ReceiptLine(qty: 2, name: 'HUMMOS', amount: 1600),
            ReceiptLine(qty: 1, name: 'KABSA MASHAWI 1/2 KG', amount: 9900),
          ],
          netTotal: 10000,
          taxTotal: 1500,
          finalTotal: 11500,
          payments: const [
            ReceiptTender(name: 'MADA', amount: 11500),
          ],
          zatcaQr: qr,
        );

    test('carries init, the totals and a cut, in order', () {
      final bytes = buildReceipt(receipt());
      final s = String.fromCharCodes(bytes);

      expect(bytes.sublist(0, 2), [0x1B, 0x40]); // ESC @ init first
      expect(s, contains('Fatima Restaurant'));
      expect(s, contains('ORDER 17'));
      expect(s, contains('TOTAL'));
      expect(s, contains('115.00'));
      expect(s, contains('2x HUMMOS'));
      // Partial cut is the last command.
      expect(bytes.sublist(bytes.length - 4), [0x1D, 0x56, 0x42, 0x00]);
    });

    test('what came inside a meal prints under it, without a price', () {
      final s = String.fromCharCodes(buildReceipt(ReceiptData(
        brandName: 'Fatima Restaurant',
        vatNumber: '310000000000003',
        receiptNo: 'T01-000043',
        orderNo: '18',
        dateTime: DateTime(2026, 8, 4, 20, 15),
        lines: const [
          ReceiptLine(qty: 1, name: 'Shawa Sandw Ckn', amount: 500),
          ReceiptLine(qty: 1, name: 'Saj Bread', amount: 0, depth: 1),
          ReceiptLine(qty: 2, name: '1 GARLIC', amount: 0, depth: 1),
        ],
        netTotal: 435,
        taxTotal: 65,
        finalTotal: 500,
        payments: const [ReceiptTender(name: 'MADA', amount: 500)],
      )));

      // Indented, and no "1x" on something that is one of the item above it.
      expect(s, contains('  Saj Bread'));
      expect(s, isNot(contains('1x Saj Bread')));
      // A count that is not one still has to show: two garlics is a different
      // order from one.
      expect(s, contains('  2x 1 GARLIC'));
      // No price column against them. A figure on the paper is a figure the
      // customer paid, and 0.00 down the side of a meal invites the question.
      expect(s, isNot(contains('0.00')));
    });

    test('unsigned receipts say so instead of pretending', () {
      final s = String.fromCharCodes(buildReceipt(receipt()));
      expect(s, contains('UNSIGNED - NOT A TAX INVOICE'));
    });

    test('a signed receipt prints the QR and drops the banner', () {
      final bytes = buildReceipt(receipt(qr: 'AQVmYXRpbWE='));
      final s = String.fromCharCodes(bytes);
      expect(s, isNot(contains('UNSIGNED')));
      // QR store command: GS ( k ... 49 80 48 followed by the payload.
      final store = [0x1D, 0x28, 0x6B, 15, 0, 49, 80, 48];
      expect(_indexOf(bytes, store), greaterThan(0));
      expect(s, contains('AQVmYXRpbWE='));
    });

    test('rows never exceed the 42-column paper', () {
      // Tested on row() itself: scanning the whole stream is unreliable
      // because ESC/GS parameter bytes look like printable letters.
      String render(String left, String right) {
        final p = EscPos()..row(left, right);
        return String.fromCharCodes(p.bytes).replaceAll('\n', '');
      }

      for (final (left, right) in [
        ('Receipt T01-000042', '2026-08-04 20:15'),
        ('1x KABSA MASHAWI 1/2 KG EXTRA LONG NAME OVERFLOWING', '199.00'),
        ('Subtotal (excl. VAT)', '1234567.89'),
        ('x', 'y'),
      ]) {
        final line = render(left, right);
        expect(line.length, lessThanOrEqualTo(42),
            reason: 'row wrapped: "$line"');
        expect(line, endsWith(right),
            reason: 'the amount must never be the part that gets truncated');
      }
    });

    test('printer transport sends the exact bytes to host:9100', () async {
      final sent = <(String, int, List<int>)>[];
      final printer = ReceiptPrinter(
        host: '192.168.1.50',
        send: (host, port, bytes) async => sent.add((host, port, bytes)),
      );
      final bytes = buildReceipt(receipt());
      await printer.print(bytes);

      expect(sent.single.$1, '192.168.1.50');
      expect(sent.single.$2, 9100);
      expect(sent.single.$3, bytes);
    });
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
