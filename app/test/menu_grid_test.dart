/// The menu a till lands on.
///
/// Staff reach for a position and a colour long before they read a label, so
/// the imported layout is carried over exactly. The failure this guards is
/// subtle and expensive: packing tiles in order instead of placing them at
/// their coordinates looks fine on a full page and silently rearranges the
/// menu the moment one tile is hidden — which is the first day of a
/// migration, when everyone is already nervous.
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

  /// The shape the real catalog has: a menu, pages placed on its grid, and
  /// products sitting at coordinates on those pages.
  void seedMenu() {
    db.raw.execute(
      "INSERT INTO menu (menu_no, name) VALUES (7, 'Default Menu')",
    );
    // Appetizers already exists in the demo seed at menu_id 2010.
    db.raw.execute(
      "INSERT INTO menu_screen (menu_id, name, back_color) "
      "VALUES (3001, 'Grill', '#0080FF')",
    );
    db.raw.execute(
      "UPDATE menu_screen SET back_color = '#80FFFF' WHERE menu_id = 2010",
    );
    // A page whose only product is a modifier — a dead end for a cashier.
    db.raw.execute(
      "INSERT INTO menu_screen (menu_id, name, back_color) "
      "VALUES (3002, 'Extra', '#FF0000')",
    );
    db.raw.execute(
      "INSERT INTO product (prodnum, descript, price_a, price_j, is_modifier) "
      "VALUES (9500, 'Comment', 0, 0, 1)",
    );
    db.raw.execute(
      "INSERT INTO menu_button (id, menu_id, prodnum, position, pos_x, pos_y) "
      "VALUES ('b-extra', 3002, 9500, 1, 1, 1)",
    );
    db.raw.execute(
      "INSERT INTO menu_button (id, menu_id, prodnum, position, pos_x, pos_y) "
      "VALUES ('b-grill', 3001, 2152, 1, 1, 1)",
    );

    for (final (id, screen, x, y) in const [
      ('p-1', 2010, 1, 1),   // Appetizers
      ('p-2', 3002, 2, 1),   // Extra — will be hidden
      ('p-3', 3001, 3, 1),   // Grill
    ]) {
      db.raw.execute(
        'INSERT INTO menu_page (id, menu_no, screen_no, pos_x, pos_y) '
        'VALUES (?, 7, ?, ?, ?)',
        [id, screen, x, y],
      );
    }
  }

  group('reading the menu', () {
    test('the default menu is the first one with pages laid out', () {
      expect(db.defaultMenu(), isNull, reason: 'no menu seeded yet');
      seedMenu();
      expect(db.defaultMenu()?.menuNo, 7);
    });

    test('a menu with no laid-out pages is never landed on', () {
      // Three menus and only one laid out is the real shape at this customer.
      db.raw.execute("INSERT INTO menu (menu_no, name) VALUES (2, 'Empty')");
      seedMenu();
      expect(db.defaultMenu()?.menuNo, 7,
          reason: 'landing on an empty menu looks like a broken till');
    });

    test('a tile onto a page with nothing sellable is not shown', () {
      seedMenu();
      final tiles = db.menuTiles(7);
      expect(tiles.map((t) => t.name), isNot(contains('Extra')));
      expect(tiles.map((t) => t.name), containsAll(['Appetizers', 'Grill']));
    });

    test('tiles keep their own coordinates when one is hidden', () {
      seedMenu();
      final tiles = db.menuTiles(7);
      final grill = tiles.firstWhere((t) => t.name == 'Grill');
      // Extra sat at x=2 and is gone; Grill must NOT slide into its place.
      expect(grill.posX, 3);
    });

    test('tiles carry the page colour', () {
      seedMenu();
      final tiles = db.menuTiles(7);
      expect(tiles.firstWhere((t) => t.name == 'Grill').backColor, '#0080FF');
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

    testWidgets('opens on the menu, not on a page', (tester) async {
      seedMenu();
      await pump(tester);

      expect(find.text('Grill'), findsOneWidget);
      expect(find.text('Appetizers'), findsOneWidget);
      // No products until a page is opened.
      expect(find.text('HUMMOS'), findsNothing);
    });

    testWidgets('a tile opens its page, and back returns to the menu',
        (tester) async {
      seedMenu();
      await pump(tester);

      await tester.tap(find.text('Appetizers'));
      await tester.pumpAndSettle();
      expect(find.text('HUMMOS'), findsOneWidget);

      await tester.tap(find.text('Default Menu'));
      await tester.pumpAndSettle();
      expect(find.text('Grill'), findsOneWidget);
      expect(find.text('HUMMOS'), findsNothing);
    });

    testWidgets('a till with no menu falls back to the page strip',
        (tester) async {
      // No menu rows at all — an older catalog, or one never laid out. The
      // cashier must still be able to reach the products.
      await pump(tester);
      expect(find.text('HUMMOS'), findsOneWidget);
    });

    testWidgets('the button label is the tile label, not the description',
        (tester) async {
      db.raw.execute(
        "UPDATE product SET button_text = 'HUM\nMOS' WHERE prodnum = 2013",
      );
      await pump(tester);
      // The full description does not fit a tile; the label is what does.
      expect(find.text('HUM\nMOS'), findsOneWidget);
      expect(find.text('HUMMOS'), findsNothing);
    });
  });
}
