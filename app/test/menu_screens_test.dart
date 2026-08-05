/// Which menu screens reach a till.
///
/// Found by loading the first customer's real migrated catalog: it carries 64
/// menu screens, and the ones that sort first are 'No Page', 'Test Page' and
/// 'Commands' — PixelPoint scaffolding with nothing sellable on them. The till
/// opened on the first screen, so a cashier saw an empty grid.
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

  /// A screen that exists and is active but has no buttons at all — the
  /// 'No Page' case.
  void addEmptyScreen({required int menuId, required String name,
      int sortOrder = -10}) {
    db.raw.execute(
      'INSERT INTO menu_screen (menu_id, name, sort_order) VALUES (?, ?, ?)',
      [menuId, name, sortOrder],
    );
  }

  test('an empty screen never reaches the till', () {
    addEmptyScreen(menuId: 9001, name: 'No Page');
    final names = db.menuScreens().map((s) => s.name);
    expect(names, isNot(contains('No Page')));
    expect(names, contains('Appetizers'));
  });

  test('a screen whose only products are inactive is empty too', () {
    addEmptyScreen(menuId: 9002, name: 'Discontinued', sortOrder: -9);
    db.raw.execute(
      'INSERT INTO product (prodnum, descript, price_a, price_j, is_active) '
      'VALUES (9101, ?, 500, 0, 0)',
      ['Retired item'],
    );
    db.raw.execute(
      'INSERT INTO menu_button (id, menu_id, prodnum, position) '
      'VALUES (?, 9002, 9101, 0)',
      ['btn-9101'],
    );

    expect(db.menuScreens().map((s) => s.name), isNot(contains('Discontinued')));
  });

  test('a screen holding only modifiers is not a till screen', () {
    // Modifier screens are already excluded by is_modifier_screen, but a
    // plain screen carrying only modifier products is the same problem
    // wearing a different hat.
    addEmptyScreen(menuId: 9003, name: 'Sauces', sortOrder: -8);
    db.raw.execute(
      'INSERT INTO product (prodnum, descript, price_a, price_j, is_modifier) '
      'VALUES (9102, ?, 100, 0, 1)',
      ['Extra garlic'],
    );
    db.raw.execute(
      'INSERT INTO menu_button (id, menu_id, prodnum, position) '
      'VALUES (?, 9003, 9102, 0)',
      ['btn-9102'],
    );

    expect(db.menuScreens().map((s) => s.name), isNot(contains('Sauces')));
  });

  test('a deleted button does not keep a screen alive', () {
    addEmptyScreen(menuId: 9004, name: 'Old Menu', sortOrder: -7);
    db.raw.execute(
      'INSERT INTO menu_button (id, menu_id, prodnum, position, is_deleted) '
      'VALUES (?, 9004, 2013, 0, 1)',
      ['btn-old'],
    );

    expect(db.menuScreens().map((s) => s.name), isNot(contains('Old Menu')));
  });

  testWidgets('the till opens on a screen with products on it', (tester) async {
    // Sorted ahead of everything real, exactly as the migrated junk screens
    // are.
    addEmptyScreen(menuId: 9005, name: 'No Page');

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: TillScreen(db: db)));
    await tester.pumpAndSettle();

    expect(find.text('No Page'), findsNothing);
    // A real product is on screen rather than an empty grid.
    expect(find.text('HUMMOS'), findsOneWidget);
  });
}
