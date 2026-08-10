/// Till screen widget tests — the real screen over the real schema.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/main.dart';

import 'helpers.dart';

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;

  setUp(() => db = seededDatabase());
  tearDown(() => db.dispose());

  Future<void> pump(WidgetTester tester) async {
    // A tablet-sized surface; the till is a landscape layout. Generous height
    // because the test font (Ahem) renders every glyph full-width, inflating
    // helper texts well past their real size.
    tester.view.physicalSize = const Size(1400, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(PosApp(db: db));
    await tester.pumpAndSettle();
  }

  testWidgets('tapping an item builds the cart and totals', (tester) async {
    await pump(tester);

    expect(find.text('Tap an item to start'), findsOneWidget);

    await tester.tap(find.text('HUMMOS').first);
    await tester.pump();
    await tester.tap(find.text('HUMMOS').first);
    await tester.pump();

    // 2 x 8.00 = 16.00 gross -> 13.91 net + 2.09 VAT
    expect(find.text('13.91'), findsOneWidget);
    expect(find.text('2.09'), findsOneWidget);
    expect(find.text('Charge 16.00 · MADA'), findsOneWidget);
  });

  testWidgets('charging completes the sale and shows the order number',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text('HUMMOS').first);
    await tester.pump();
    await tester.tap(find.textContaining('Charge '));
    await tester.pumpAndSettle();

    // A demo till has no backend to reserve numbers from, so what it calls
    // out is qualified by the device — no other till could produce 'T01-1'.
    expect(find.text('Order T01-1'), findsOneWidget);
    expect(find.textContaining('Receipt T01-000001'), findsOneWidget);

    await tester.tap(find.text('Next customer'));
    await tester.pumpAndSettle();

    // Cart cleared, order number advanced, and the sale is really in the DB.
    expect(find.text('Tap an item to start'), findsOneWidget);
    expect(find.text('ORDER T01-2'), findsOneWidget);
    expect(db.outboxDepth(), 1);

    // The number the customer was told is the one stored against the sale.
    final saleUuid = db.raw
        .select('SELECT sale_uuid FROM sale')
        .first['sale_uuid'] as String;
    expect(db.saleRow(saleUuid)['order_no'], 1);
  });

  testWidgets('aggregator type demands the reference before charging',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text('Keeta'));
    await tester.pumpAndSettle();

    // Tier B pricing shows on the grid: HUMMOS at 9.00.
    expect(find.text('9.00'), findsWidgets);

    await tester.tap(find.text('HUMMOS').first);
    await tester.pump();
    await tester.tap(find.textContaining('Charge '));
    await tester.pumpAndSettle();

    // Refused — no reference entered; still on the till, no dialog.
    expect(find.text('Next customer'), findsNothing);
    expect(db.outboxDepth(), 0);

    // The refusal toast sits over the charge button; let it expire before
    // tapping again, as a human would.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'KEETA-58211');
    await tester.tap(find.textContaining('Charge '));
    await tester.pumpAndSettle();

    expect(find.textContaining('Receipt T01-000001'), findsOneWidget);
    expect(db.outboxDepth(), 1);
  });
}
