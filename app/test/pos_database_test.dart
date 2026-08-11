/// The local database, exercised against the real schema file.
///
/// These tests run the actual `assets/schema.sql` (a copy of
/// docs/sqlite_schema.sql) — not a Dart re-declaration of it — so a schema
/// change that breaks the till breaks these tests first.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/data/pos_database.dart';

import 'helpers.dart';

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;

  setUp(() => db = seededDatabase());
  tearDown(() => db.dispose());

  SalesType type(int no) => db.salesTypes().firstWhere((t) => t.no == no);
  CatalogProduct prod(int menuId, int num) =>
      db.productsForScreen(menuId).firstWhere((p) => p.prodnum == num);

  test('catalog round-trips through the real schema', () {
    expect(db.menuScreens().map((s) => s.name), ['Appetizers', 'Sandwiches']);
    expect(db.salesTypes().length, 4);
    final hummos = prod(2010, 2013);
    expect(hummos.tiers[0], 800);
    expect(hummos.tiers[1], 900);
    expect(db.kitchenStations(),
        {2: 'Expo', 3: 'Grill', 4: 'Shawarma', 5: 'DT'});
  });

  test('a drive-thru sale reconciles to the halala', () {
    final sale = db.completeSale(
      cart: [
        CartLine(product: prod(2010, 2013), qty: 2),      // 2x HUMMOS @ 800
        CartLine(product: prod(2010, 2152), qty: 1),      // Hummos Lahm @ 2400
      ],
      salesType: type(2025),
      payments: [
        Tender.whole(methodnum: 1010, name: 'MADA'),
      ],
      orderNo: 124,
    );

    expect(sale.finalTotal, 1600 + 2400);
    expect(sale.netTotal + sale.taxTotal, sale.finalTotal);
    expect(sale.receiptNo, 'T01-000001');

    final row = db.saleRow(sale.saleUuid);
    expect(row['status'], 'closed');
    expect(row['order_no'], 124);

    // Every stored line must reconcile independently — the backend rejects
    // the push otherwise.
    for (final line in db.saleLines(sale.saleUuid)) {
      expect((line['net_amount'] as int) + (line['tax_amount'] as int),
          line['line_total']);
    }
  });

  test('aggregator sale charges tier B and demands the reference', () {
    final keeta = type(2004);

    expect(
      () => db.completeSale(
        cart: [CartLine(product: prod(2010, 2013), qty: 1)],
        salesType: keeta,
        payments: [
          Tender.whole(methodnum: 1010, name: 'MADA'),
        ],
      ),
      throwsStateError,
      reason: 'no external reference given',
    );

    final sale = db.completeSale(
      cart: [CartLine(product: prod(2010, 2013), qty: 1)],
      salesType: keeta,
      payments: [
        Tender.whole(methodnum: 1010, name: 'MADA'),
      ],
      externalRef: 'KEETA-58211',
    );
    expect(sale.finalTotal, 900, reason: 'tier B, not tier A');
    expect(db.saleRow(sale.saleUuid)['external_ref'], 'KEETA-58211');
  });

  test('every sale leaves exactly one outbox entry', () {
    expect(db.outboxDepth(), 0);
    db.completeSale(
      cart: [CartLine(product: prod(2010, 2013), qty: 1)],
      salesType: type(2025),
      payments: [
        Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
      ],
    );
    expect(db.outboxDepth(), 1);
  });

  test('kitchen tickets route lines by the PRINTLOC bitmask', () {
    final sale = db.completeSale(
      cart: [
        CartLine(product: prod(2010, 2013), qty: 1),      // no kitchen
        CartLine(product: prod(2010, 2152), qty: 1),      // 40 = Grill + DT
        CartLine(product: prod(2023, 2058), qty: 2),      // 16 = Shawarma
      ],
      salesType: type(2025),
      payments: [
        Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
      ],
    );

    expect(sale.kitchenStations, ['DT', 'Grill', 'Shawarma']);

    final lines = db.kitchenTicketLines(sale.saleUuid);
    // Hummos Lahm appears on two stations, Shawa on one, HUMMOS on none.
    final byStation = <int, List<String>>{};
    for (final l in lines) {
      byStation
          .putIfAbsent(l['station_no'] as int, () => [])
          .add(l['line_des'] as String);
    }
    expect(byStation[3], ['Hummos Lahm']);
    expect(byStation[5], ['Hummos Lahm']);
    expect(byStation[4], ['Shawa Sandw Ckn']);
    expect(byStation.containsKey(2), isFalse,
        reason: 'nothing routed to Expo');
  });

  test('a sale with no kitchen items cuts no ticket', () {
    final sale = db.completeSale(
      cart: [CartLine(product: prod(2010, 2013), qty: 3)],
      salesType: type(2025),
      payments: [
        Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
      ],
    );
    expect(sale.kitchenStations, isEmpty);
    expect(db.kitchenTicketLines(sale.saleUuid), isEmpty);
  });

  test('receipt numbers advance and never repeat', () {
    String make() => db.completeSale(
          cart: [CartLine(product: prod(2010, 2013), qty: 1)],
          salesType: type(2025),
          payments: [
            Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
          ],
        ).receiptNo;

    expect([make(), make(), make()],
        ['T01-000001', 'T01-000002', 'T01-000003']);
  });

  test('an empty cart cannot be charged', () {
    expect(
      () => db.completeSale(
          cart: [], salesType: type(2025), payments: [Tender.whole(methodnum: 1001, name: 'CASH', isCash: true)]),
      throwsStateError,
    );
  });

  test('staff meal rings at zero without complaint', () {
    final sale = db.completeSale(
      cart: [CartLine(product: prod(2010, 2013), qty: 1)],
      salesType: type(2026),           // tier J
      payments: [
        Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
      ],
    );
    expect(sale.finalTotal, 0);
    expect(sale.netTotal, 0);
    expect(sale.taxTotal, 0);
  });
}
