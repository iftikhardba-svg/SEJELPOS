/// Menu tile geometry.
///
/// This exists because the bug it guards was invisible in every other kind of
/// test: Material 3 gives OutlinedButton a StadiumBorder by default, so the
/// 170x84 menu tiles rendered as ovals with the item name and price spilling
/// out of the rounded ends. The logic was perfect and the till was unusable.
/// Only running the app on a real screen showed it.
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

  Future<void> pumpTill(WidgetTester tester,
      {Size size = const Size(1280, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TillScreen(db: db)));
    await tester.pumpAndSettle();
  }

  /// The product tiles, told apart from the CASH/Visa buttons in the cart
  /// panel by carrying a price line.
  Finder menuTiles() => find.ancestor(
        of: find.text('8.00'),
        matching: find.byType(OutlinedButton),
      );

  /// Tap the chip, not the label inside it: the label sits in a horizontally
  /// scrolling strip and its centre does not always hit-test onto the chip's
  /// own tap target.
  Future<void> selectSaleType(WidgetTester tester, String label) async {
    await tester.tap(
      find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a menu tile is a rectangle, not a stadium', (tester) async {
    await pumpTill(tester);

    final tile = tester.widget<OutlinedButton>(menuTiles().first);
    final shape = tile.style?.shape?.resolve(<WidgetState>{});

    expect(shape, isA<RoundedRectangleBorder>(),
        reason: 'a stadium-shaped tile clips its own text');
    final radius = (shape! as RoundedRectangleBorder).borderRadius
        .resolve(TextDirection.ltr).topLeft.x;
    // Anything approaching half the 84px height is an oval again.
    expect(radius, lessThan(20.0));
  });

  testWidgets('a tile is square, whatever the page it is on', (tester) async {
    await pumpTill(tester);

    // Stretched-to-fit tiles changed shape with the column count, so the same
    // item was one size on the shawarma page and another on the grill page —
    // and staff reach for a shape as much as a position.
    final tile = tester.getRect(menuTiles().first);
    expect(tile.width, tile.height);
  });

  testWidgets('a wide page scrolls sideways instead of overflowing',
      (tester) async {
    // Eleven columns on a narrow panel: the tiles hit their floor and the row
    // is wider than the space. Getting the width a single gap short paints
    // warning stripes down the middle of the menu on a real screen.
    for (var col = 1; col <= 11; col++) {
      db.raw.execute(
        'INSERT INTO menu_button (id, menu_id, prodnum, position, pos_x, pos_y)'
        ' VALUES (?, 2010, 2013, ?, ?, 1)',
        ['wide-$col', col, col],
      );
    }
    await pumpTill(tester, size: const Size(900, 800));

    expect(tester.takeException(), isNull);
  });

  testWidgets('the tile is big enough to hold its name and price',
      (tester) async {
    await pumpTill(tester);

    final tileRect = tester.getRect(menuTiles().first);
    final priceRect = tester.getRect(find.text('8.00'));

    // The price must sit inside the tile it belongs to. With a stadium border
    // it rendered outside the visible shape at the bottom-left.
    expect(tileRect.contains(priceRect.topLeft), isTrue);
    expect(tileRect.contains(priceRect.bottomRight), isTrue);
  });

  testWidgets('the cart panel keeps its width beside the menu grid',
      (tester) async {
    // The grid is Expanded and the cart is a fixed 320. If that inverts, the
    // totals column collapses and the charge button becomes unreadable.
    await pumpTill(tester);
    final cart = tester.getRect(find.text('Tap an item to start'));
    expect(cart.left, greaterThan(1280 - 320.0));
  });

  testWidgets('the aggregator reference bar appears only when required',
      (tester) async {
    await pumpTill(tester);

    // The demo catalog opens on Drive Thru, which needs no reference.
    expect(find.textContaining('order no. (required)'), findsNothing);

    await selectSaleType(tester, 'Keeta');
    expect(find.textContaining('order no. (required)'), findsOneWidget);
  });

  testWidgets('switching to the aggregator tier reprices the menu',
      (tester) async {
    await pumpTill(tester);
    // Tier A.
    expect(find.text('8.00'), findsOneWidget);

    await selectSaleType(tester, 'Keeta');

    // Tier B - the difference is the aggregator's commission, so showing the
    // walk-in price here would misprice every delivery order on screen.
    expect(find.text('9.00'), findsOneWidget);
    expect(find.text('8.00'), findsNothing);
  });
}
