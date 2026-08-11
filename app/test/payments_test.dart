/// Taking the money: several tenders on one bill, and the change.
///
/// A counter takes half on a card and the rest in cash often enough that a
/// till which cannot do it makes the cashier ring two sales for one customer —
/// two tax invoices, two order numbers, two kitchen tickets, one meal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pos_app/core/money.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/printing/escpos.dart';

import 'helpers.dart';

void main() {
  setUpAll(useSystemSqlite);

  group('typing an amount', () {
    test('reads what a cashier types, to the halala', () {
      expect(parseHalalas('12'), 1200);
      expect(parseHalalas('12.5'), 1250);
      expect(parseHalalas('12.50'), 1250);
      expect(parseHalalas('0.05'), 5);
      expect(parseHalalas(' 38.00 '), 3800);
      // Some keypads produce a comma.
      expect(parseHalalas('12,50'), 1250);
    });

    test('refuses anything that is not an amount', () {
      for (final input in ['', 'abc', '-5', '12.345', '1.2.3', '12 50']) {
        expect(parseHalalas(input), isNull, reason: input);
      }
    });
  });

  group('a bill settled several ways', () {
    late PosDatabase db;

    setUp(() => db = seededDatabase());
    tearDown(() => db.dispose());

    SalesType type(int no) => db.salesTypes().firstWhere((t) => t.no == no);
    CatalogProduct prod(int num) =>
        db.productsForScreen(2010).firstWhere((p) => p.prodnum == num);

    CompletedSale charge(List<Tender> payments, {int qty = 3}) =>
        db.completeSale(
          cart: [CartLine(product: prod(2013), qty: qty.toDouble())],
          salesType: type(2025),
          payments: payments,
        );

    test('half on a card and the rest in cash is one sale', () {
      // 3 x HUMMOS at 8.00 = 24.00.
      final sale = charge([
        const Tender(methodnum: 1010, name: 'MADA', amount: 1000),
        const Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
      ]);

      expect(sale.finalTotal, 2400);
      expect(sale.payments.map((p) => p.amount), [1000, 1400]);

      final rows = db.raw.select(
        'SELECT methodnum, amount, tender, change_given FROM sale_payment '
        'WHERE sale_uuid = ? ORDER BY methodnum',
        [sale.saleUuid],
      );
      expect(rows.map((r) => r['methodnum']), [1001, 1010]);
      expect(rows.map((r) => r['amount']), [1400, 1000]);
      // One sale, one receipt number, one order.
      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'],
        1,
      );
    });

    test('cash over the amount is change, and it is recorded', () {
      final sale = charge([
        const Tender.whole(
            methodnum: 1001, name: 'CASH', tendered: 5000, isCash: true),
      ]);

      expect(sale.payments.single.change, 2600);
      final row = db.raw.select(
        'SELECT amount, tender, change_given FROM sale_payment '
        'WHERE sale_uuid = ?',
        [sale.saleUuid],
      ).first;
      // What was owed, what was handed over, what went back.
      expect(row['amount'], 2400);
      expect(row['tender'], 5000);
      expect(row['change_given'], 2600);
    });

    test('a card cannot give change', () {
      // A terminal takes the amount it is given; change on one is a typo, and
      // storing it puts money in the drawer that no tender ever paid in.
      expect(
        () => charge([
          const Tender.whole(methodnum: 1010, name: 'MADA', tendered: 5000),
        ]),
        throwsStateError,
      );
    });

    test('tenders that do not come to the bill are refused', () {
      expect(
        () => charge([
          const Tender(methodnum: 1010, name: 'MADA', amount: 1000),
          const Tender(methodnum: 1001, name: 'CASH', amount: 500),
        ]),
        throwsStateError,
        reason: 'short: the rest of the money is nowhere',
      );
      expect(
        () => charge([
          const Tender(methodnum: 1010, name: 'MADA', amount: 3000),
        ]),
        throwsStateError,
        reason: 'over: that is change, not a bigger tender',
      );
      expect(() => charge(const []), throwsStateError);
      // Nothing was written by any of the refusals.
      expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 0);
    });

    test('only one tender can cover "the rest"', () {
      expect(
        () => charge([
          const Tender.whole(methodnum: 1010, name: 'MADA'),
          const Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
        ]),
        throwsStateError,
      );
    });

    test('a split bill still reconciles for the backend', () {
      final sale = charge([
        const Tender(methodnum: 1010, name: 'MADA', amount: 900),
        const Tender.whole(methodnum: 1001, name: 'CASH', isCash: true),
      ]);

      // The backend refuses a sale whose payments do not cover the total; the
      // change is not part of that sum.
      final paid = db.raw
          .select('SELECT SUM(amount) AS n FROM sale_payment '
              'WHERE sale_uuid = ?', [sale.saleUuid])
          .first['n'] as int;
      expect(paid, sale.finalTotal);
    });
  });

  group('the receipt', () {
    test('shows each tender and what went back', () {
      final s = String.fromCharCodes(buildReceipt(ReceiptData(
        brandName: 'Fatima Restaurant',
        vatNumber: '310000000000003',
        receiptNo: 'T01-000044',
        orderNo: '19',
        dateTime: DateTime(2026, 8, 11, 13, 0),
        lines: const [ReceiptLine(qty: 1, name: 'HUMMOS', amount: 2400)],
        netTotal: 2087,
        taxTotal: 313,
        finalTotal: 2400,
        payments: const [
          ReceiptTender(name: 'MADA', amount: 1000),
          ReceiptTender(name: 'CASH', amount: 1400, change: 600),
        ],
      )));

      expect(s, contains('Paid MADA'));
      expect(s, contains('Paid CASH'));
      expect(s, contains('CHANGE'));
      expect(s, contains('6.00'));
    });
  });

  group('at the till', () {
    late PosDatabase db;

    setUp(() => db = seededDatabase());
    tearDown(() => db.dispose());

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1050);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(PosApp(db: db));
      await tester.pumpAndSettle();
    }

    testWidgets('the buttons are the methods the catalog carries',
        (tester) async {
      await pump(tester);

      // Not a hardcoded three: this customer has six live methods, and a till
      // offering the wrong ones pushes trade through the wrong button.
      expect(find.widgetWithText(FilledButton, 'Charge 0.00 · MADA'),
          findsOneWidget);
      expect(find.text('CASH'), findsOneWidget);
      expect(find.text('Visa'), findsOneWidget);
    });

    testWidgets('cash asks what was handed over and shows the change',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('HUMMOS').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('CASH'));
      await tester.pumpAndSettle();

      // Opens on the exact amount: the common case is one tap.
      expect(find.text('Cash · 8.00 due'), findsOneWidget);
      expect(find.text('Change 0.00'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '10.00');
      await tester.pumpAndSettle();
      expect(find.text('Change 2.00'), findsOneWidget);

      await tester.tap(find.text('Take cash'));
      await tester.pumpAndSettle();

      expect(find.textContaining('CHANGE 2.00'), findsOneWidget);
      final row = db.raw
          .select('SELECT tender, change_given FROM sale_payment')
          .first;
      expect(row['tender'], 1000);
      expect(row['change_given'], 200);
    });

    testWidgets('a split bill cannot be charged until it is covered',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text('HUMMOS').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Split payment'));
      await tester.pumpAndSettle();
      expect(find.text('Remaining 8.00'), findsOneWidget);

      // Part on the card.
      await tester.tap(find.widgetWithText(ChoiceChip, 'MADA'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '3.00');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Remaining 5.00'), findsOneWidget);
      // A sale that closes short is money nobody can find at close of day.
      final charge = find.widgetWithText(FilledButton, 'Charge');
      expect(tester.widget<FilledButton>(charge).onPressed, isNull);

      // The rest in cash.
      await tester.tap(find.widgetWithText(ChoiceChip, 'CASH'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Remaining 0.00'), findsOneWidget);
      await tester.tap(charge);
      await tester.pumpAndSettle();

      // One sale, two tenders.
      final rows = db.raw.select(
          'SELECT methodnum, amount FROM sale_payment ORDER BY methodnum');
      expect(rows.map((r) => r['methodnum']), [1001, 1010]);
      expect(rows.map((r) => r['amount']), [500, 300]);
      expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 1);
    });
  });
}
