/// Who rang the sale.
///
/// `sale.emp_open` is NOT NULL and a foreign key to `employee`. `completeSale`
/// defaulted to empnum 0, and the demo catalog happens to seed an employee 0 —
/// so every test passed while the real migrated catalog (staff 999 and
/// 2001-2012, no zero) made every charge fail with a bare SQLite foreign key
/// error. The till could not sell at all against real data.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/ui/till_screen.dart';

import 'helpers.dart';

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;
  setUp(() => db = seededDatabase());
  tearDown(() => db.dispose());

  /// Replace the demo's single employee 0 with the shape a migrated catalog
  /// actually has: several real staff, none numbered zero.
  void useRealStaff() {
    db.raw.execute('DELETE FROM employee');
    for (final (num, name) in const [
      (999, 'Supervisor Supervisor'),
      (2001, 'Maan Mohammed'),
      (2004, 'BAKRI'),
    ]) {
      db.raw.execute(
        'INSERT INTO employee (empnum, name, must_set_pin) VALUES (?, ?, 1)',
        [num, name],
      );
    }
  }

  group('completeSale', () {
    test('refuses an unknown cashier with a readable reason', () {
      useRealStaff();
      // What the till used to pass, against a catalog with no employee 0.
      expect(
        () => chargeOneItem(db),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('no active cashier'))),
      );
    });

    test('the sale records the cashier who rang it', () {
      useRealStaff();
      final sale = chargeOneItem(db, empnum: 2004);
      expect(db.saleRow(sale.saleUuid)['emp_open'], 2004);
    });

    test('an inactive cashier cannot ring a sale', () {
      useRealStaff();
      db.raw.execute('UPDATE employee SET is_active = 0 WHERE empnum = 2001');
      expect(() => chargeOneItem(db, empnum: 2001), throwsStateError);
    });

    test('nothing is written when the cashier is rejected', () {
      useRealStaff();
      expect(() => chargeOneItem(db), throwsStateError);
      // The guard runs before the transaction, so there is no half-sale and
      // no burnt receipt number.
      expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 0);
      expect(db.outboxDepth(), 0);
      expect(
        db.raw.select('SELECT next_receipt_seq FROM device WHERE id = 1')
            .first['next_receipt_seq'],
        1,
      );
    });
  });

  group('choosing who is on the till', () {
    test('starts with nobody', () {
      expect(db.activeCashier(), isNull);
    });

    test('remembers the choice', () {
      useRealStaff();
      db.setActiveCashier(2001);
      expect(db.activeCashier(), 2001);
    });

    test('lists only active staff', () {
      useRealStaff();
      db.raw.execute('UPDATE employee SET is_active = 0 WHERE empnum = 999');
      expect(db.cashiers().map((c) => c.empnum), [2004, 2001]);
    });
  });

  group('the till', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1050);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: TillScreen(db: db)));
      await tester.pumpAndSettle();
    }

    testWidgets('asks who is on the till before the first charge',
        (tester) async {
      useRealStaff();
      await pump(tester);

      await tester.tap(find.text('HUMMOS').first);
      await tester.pump();
      await tester.tap(find.textContaining('Charge '));
      await tester.pumpAndSettle();

      expect(find.text('Who is on this till?'), findsOneWidget);
      // The sale has NOT happened yet — the cart is still loaded.
      expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 0);

      await tester.tap(find.textContaining('BAKRI'));
      await tester.pumpAndSettle();

      expect(db.activeCashier(), 2004);
      final sale = db.raw.select('SELECT emp_open FROM sale').single;
      expect(sale['emp_open'], 2004);
    });

    testWidgets('does not ask again once someone is on the till',
        (tester) async {
      useRealStaff();
      db.setActiveCashier(999);
      await pump(tester);

      await tester.tap(find.text('HUMMOS').first);
      await tester.pump();
      await tester.tap(find.textContaining('Charge '));
      await tester.pumpAndSettle();

      expect(find.text('Who is on this till?'), findsNothing);
      expect(db.raw.select('SELECT emp_open FROM sale').single['emp_open'], 999);
    });

    testWidgets('a single cashier is used without a dialog', (tester) async {
      // The demo catalog and any one-person shop. A dialog whose only answer
      // is already known is just a tap in the way.
      await pump(tester);

      await tester.tap(find.text('HUMMOS').first);
      await tester.pump();
      await tester.tap(find.textContaining('Charge '));
      await tester.pumpAndSettle();

      expect(find.text('Who is on this till?'), findsNothing);
      expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 1);
    });

    testWidgets('cancelling the picker charges nothing', (tester) async {
      useRealStaff();
      await pump(tester);

      await tester.tap(find.text('HUMMOS').first);
      await tester.pump();
      await tester.tap(find.textContaining('Charge '));
      await tester.pumpAndSettle();

      // Dismiss without choosing.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 0);
      expect(db.activeCashier(), isNull);
    });

    testWidgets('the cashier on duty is visible without opening anything',
        (tester) async {
      useRealStaff();
      db.setActiveCashier(2001);
      await pump(tester);
      expect(find.text('Maan Mohammed'), findsOneWidget);
    });
  });
}
