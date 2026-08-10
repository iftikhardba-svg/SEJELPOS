/// Meal deals: the prompts a till asks, and what the answers do to a sale.
///
/// The shapes here are the real ones. '2 SANDWICH OFFER' routes to no kitchen
/// station at all, and the sandwiches chosen inside it go to the shawarma and
/// the grill — which is why a chosen item cannot simply be routed by its
/// parent, and why the parent has to appear on stations its own PRINTLOC never
/// named. The bread question hanging off a chosen sandwich is real too: eight
/// choices in the imported catalog ask something in their own right.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/main.dart';

import 'helpers.dart';

/// Adds the '2 SANDWICH OFFER' meal to a seeded demo catalog.
///
/// Prices are on the products the way the source has them — the drink really
/// does cost 3.00 on its own — because the point of most of these tests is
/// that choosing one inside a meal charges nothing for it.
void seedMealDeal(PosDatabase db) {
  final raw = db.raw;

  void product(int num, String name, int priceA, int printLoc,
      {int? menuId}) {
    raw.execute(
      'INSERT INTO product (prodnum, descript, price_a, price_b, price_j, '
      '  print_loc, tax_applies) VALUES (?, ?, ?, ?, 0, ?, 1)',
      [num, name, priceA, priceA, printLoc],
    );
    if (menuId != null) {
      raw.execute(
        'INSERT INTO menu_button (id, menu_id, prodnum, position) '
        'VALUES (?, ?, ?, ?)',
        ['btn-$num', menuId, num, num],
      );
    }
  }

  // The meal itself: on the menu, and routed nowhere.
  product(2192, '2 SANDWICH OFFER', 1500, 0, menuId: 2010);
  product(2145, 'COCA COLA MEDIUM', 300, 0);      // drink, no routing
  product(2033, 'FRIES SML', 600, 8);             // included, goes to Grill
  product(2216, '1 GARLIC', 0, 0);                // included, routed nowhere
  product(2141, '1 LITER', 3600, 0);              // included, never printed
  product(2500, 'SAMOON', 0, 0);                  // bread choices
  product(2501, 'TAMEES', 0, 0);
  // 2058 'Shawa Sandw Ckn' is already in the demo catalog, routed to Shawarma.

  void question(int no, String prompt,
      {bool required = true, int pick = 1, bool repeats = false}) {
    raw.execute(
      'INSERT INTO question (question_no, prompt, is_required, pick_count, '
      '  allow_repeats) VALUES (?, ?, ?, ?, ?)',
      [no, prompt, required ? 1 : 0, pick, repeats ? 1 : 0],
    );
  }

  void choice(int questionNo, int prodnum, int sort, {int active = 1}) {
    raw.execute(
      'INSERT INTO question_choice (id, question_no, prodnum, sort_order, '
      '  price_mode, fixed_price, is_active) VALUES (?, ?, ?, ?, 11, 0, ?)',
      ['ch-$questionNo-$prodnum', questionNo, prodnum, sort, active],
    );
  }

  void asks(int prodnum, int slot, int questionNo) {
    raw.execute(
      'INSERT INTO product_question (id, prodnum, question_no, slot) '
      'VALUES (?, ?, ?, ?)',
      ['pq-$prodnum-$slot', prodnum, questionNo, slot],
    );
  }

  void includes(String id, int parent, int prodnum,
      {int sort = 0, bool print = true}) {
    raw.execute(
      'INSERT INTO combo_item (id, parent_prodnum, prodnum, sort_order, '
      '  print_it) VALUES (?, ?, ?, ?, ?)',
      [id, parent, prodnum, sort, print ? 1 : 0],
    );
  }

  question(2002, '2 SMALL SANDWICHES', pick: 2, repeats: true);
  question(2003, '1 DRINKS', required: false);
  question(2020, 'Bread Selection');

  choice(2002, 2058, 1);
  choice(2003, 2145, 1);
  choice(2020, 2500, 1);
  choice(2020, 2501, 2);

  asks(2192, 1, 2002);
  asks(2192, 2, 2003);
  asks(2058, 1, 2020);   // a choice that asks something of its own

  includes('ci-fries', 2192, 2033, sort: 1);
  // Two rows for the same product: the offer comes with two garlics.
  includes('ci-garlic-1', 2192, 2216, sort: 2);
  includes('ci-garlic-2', 2192, 2216, sort: 2);
  includes('ci-litre', 2192, 2141, sort: 3, print: false);
}

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;

  setUp(() {
    db = seededDatabase();
    seedMealDeal(db);
  });
  tearDown(() => db.dispose());

  SalesType type(int no) => db.salesTypes().firstWhere((t) => t.no == no);
  CatalogProduct prod(int menuId, int num) =>
      db.productsForScreen(menuId).firstWhere((p) => p.prodnum == num);

  /// The offer configured the way a cashier would leave it: two sandwiches,
  /// each on its own bread, plus a drink and everything it includes.
  List<CartExtra> configuredOffer() {
    final questions = db.questionsFor(2192);
    final sandwich = questions[0].choices.single;
    final drink = questions[1].choices.single;
    final bread = db.questionsFor(2058).single.choices;

    CartExtra sandwichWith(MealChoice breadChoice) => CartExtra(
          product: sandwich.product,
          qty: sandwich.qty,
          unitPrice: sandwich.unitPrice,
          questionNo: 2002,
          extras: [
            CartExtra(
              product: breadChoice.product,
              qty: breadChoice.qty,
              unitPrice: breadChoice.unitPrice,
              questionNo: 2020,
            ),
          ],
        );

    return [
      sandwichWith(bread[0]),
      sandwichWith(bread[1]),
      CartExtra(
        product: drink.product,
        qty: drink.qty,
        unitPrice: drink.unitPrice,
        questionNo: 2003,
      ),
      ...db.comboItemsFor(2192),
    ];
  }

  // ------------------------------------------------------------ the catalog

  test('a product asks its questions in slot order', () {
    final questions = db.questionsFor(2192);

    expect(questions.map((q) => q.prompt),
        ['2 SMALL SANDWICHES', '1 DRINKS']);
    expect(questions[0].pickCount, 2);
    expect(questions[0].allowRepeats, isTrue);
    expect(questions[0].isRequired, isTrue);
    expect(questions[1].isRequired, isFalse,
        reason: 'the drink prompt may be skipped in the source data');
  });

  test('a chosen item is included, not charged', () {
    final drink = db.questionsFor(2192)[1].choices.single;

    // The product really costs 3.00 on its own. Inside the meal it is free —
    // charging tier price here would double-charge every meal in the catalog,
    // and running it through priceFor would refuse most of them outright.
    expect(drink.product.tiers[0], 300);
    expect(drink.unitPrice, 0);
  });

  test('a question with nothing left to offer is not asked', () {
    db.raw.execute('UPDATE question_choice SET is_active = 0 '
        'WHERE question_no = 2003');

    // A prompt whose choices have all been withdrawn is a dialog with no
    // buttons; if it were required the item could never be sold at all.
    expect(db.questionsFor(2192).map((q) => q.prompt), ['2 SMALL SANDWICHES']);
  });

  test('two rows for the same included item mean two of it', () {
    final included = db.comboItemsFor(2192);

    expect(included.map((e) => e.product.descript),
        ['FRIES SML', '1 GARLIC', '1 LITER']);
    expect(included[1].qty, 2, reason: 'two garlic rows folded into one line');
    expect(included[2].printIt, isFalse);
  });

  // -------------------------------------------------------------- the sale

  test('answers ride on the sale as lines hung off the meal', () {
    final sale = db.completeSale(
      cart: [CartLine(product: prod(2010, 2192), qty: 1, extras: configuredOffer())],
      salesType: type(2025),
      methodnum: 1010,
    );

    // Nothing chosen inside the meal moves the price.
    expect(sale.finalTotal, 1500);

    final lines = db.saleLines(sale.saleUuid);
    final byName = {for (final l in lines) l['line_des'] as String: l};
    final parent = byName['2 SANDWICH OFFER']!;

    expect(parent['parent_line'], isNull);
    expect(byName['COCA COLA MEDIUM']!['parent_line'], parent['line_uuid']);
    expect(byName['FRIES SML']!['parent_line'], parent['line_uuid']);
    expect(byName['1 GARLIC']!['qty'], 2);

    // The bread hangs off the sandwich it was chosen for, not off the meal.
    final sandwiches =
        lines.where((l) => l['line_des'] == 'Shawa Sandw Ckn').toList();
    final breads = lines.where(
        (l) => l['line_des'] == 'SAMOON' || l['line_des'] == 'TAMEES');
    expect(sandwiches, hasLength(2));
    expect(breads.map((b) => b['parent_line']),
        containsAll(sandwiches.map((s) => s['line_uuid'])));

    // Every line still reconciles on its own — the backend rejects the push
    // otherwise, and a zero line has to be a real zero.
    for (final line in lines) {
      expect((line['net_amount'] as int) + (line['tax_amount'] as int),
          line['line_total']);
    }
    expect(byName['COCA COLA MEDIUM']!['line_total'], 0);
  });

  test('two of the meal means two of everything inside it', () {
    final sale = db.completeSale(
      cart: [CartLine(product: prod(2010, 2192), qty: 2, extras: configuredOffer())],
      salesType: type(2025),
      methodnum: 1010,
    );

    expect(sale.finalTotal, 3000);
    final lines = db.saleLines(sale.saleUuid);
    final byName = {for (final l in lines) l['line_des'] as String: l};

    expect(byName['COCA COLA MEDIUM']!['qty'], 2);
    expect(byName['1 GARLIC']!['qty'], 4, reason: 'two garlics, twice');
    // The bread is per sandwich, and there are two sandwiches per offer.
    expect(byName['SAMOON']!['qty'], 2);
  });

  // ---------------------------------------------------------- the kitchen

  test('the meal appears wherever part of it is being cooked', () {
    final sale = db.completeSale(
      cart: [CartLine(product: prod(2010, 2192), qty: 1, extras: configuredOffer())],
      salesType: type(2025),
      methodnum: 1010,
    );

    // The offer itself routes nowhere. Without the group rule the kitchen
    // would be told nothing at all, or told to make a sandwich with no way to
    // tell which offer it belonged to.
    expect(sale.kitchenStations, ['Grill', 'Shawarma']);

    final lines = db.kitchenTicketLines(sale.saleUuid);
    List<Map<String, Object?>> at(int station) => [
          for (final l in lines)
            if (l['station_no'] == station)
              {
                'line_no': l['line_no'],
                'des': l['line_des'],
                'parent': l['parent_line_no'],
              },
        ];

    // Grill: the offer as a header, then the fries that made it come here.
    final grill = at(3);
    expect(grill.map((l) => l['des']), ['2 SANDWICH OFFER', 'FRIES SML']);
    expect(grill[1]['parent'], grill[0]['line_no']);

    // Shawarma: the offer, both sandwiches, each with its own bread under it.
    final shawarma = at(4);
    expect(shawarma.map((l) => l['des']), [
      '2 SANDWICH OFFER',
      'Shawa Sandw Ckn',
      'SAMOON',
      'Shawa Sandw Ckn',
      'TAMEES',
    ]);
    expect(shawarma[1]['parent'], shawarma[0]['line_no']);
    expect(shawarma[2]['parent'], shawarma[1]['line_no'],
        reason: 'the bread belongs to its sandwich, not to the offer');
    expect(shawarma[4]['parent'], shawarma[3]['line_no']);

    // print_it = 0 keeps the litre off the ticket while leaving it on the bill.
    expect(lines.map((l) => l['line_des']), isNot(contains('1 LITER')));
    expect(
      db.saleLines(sale.saleUuid).map((l) => l['line_des']),
      contains('1 LITER'),
    );
  });

  test('a plain item still routes exactly as it did', () {
    // The group rule must not change anything for an item with no questions.
    final sale = db.completeSale(
      cart: [CartLine(product: prod(2010, 2152), qty: 1)],   // Grill + DT
      salesType: type(2025),
      methodnum: 1010,
    );

    expect(sale.kitchenStations, ['DT', 'Grill']);
    final lines = db.kitchenTicketLines(sale.saleUuid);
    expect(lines, hasLength(2));
    expect(lines.every((l) => l['parent_line_no'] == null), isTrue);
  });

  // ------------------------------------------------------------- the till

  group('at the till', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1050);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(PosApp(db: db));
      await tester.pumpAndSettle();
    }

    testWidgets('pressing a meal asks its questions in order', (tester) async {
      await pump(tester);

      await tester.tap(find.text('2 SANDWICH OFFER').first);
      await tester.pumpAndSettle();

      // First prompt, and it wants two.
      expect(find.text('2 SMALL SANDWICHES'), findsOneWidget);
      expect(find.textContaining('Choose 2 more of 2'), findsOneWidget);
      expect(find.text('Skip'), findsNothing, reason: 'this one is required');

      // The choice buttons, not the chips of what has already been picked —
      // both carry the same text.
      Finder choice(String name) =>
          find.widgetWithText(OutlinedButton, name).last;

      // Repeats are allowed here, so the same sandwich can be taken twice.
      await tester.tap(choice('Shawa Sandw Ckn'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Choose 1 more of 2'), findsOneWidget);
      await tester.tap(choice('Shawa Sandw Ckn'));
      await tester.pumpAndSettle();

      // Each sandwich then asks for its own bread — one prompt per sandwich,
      // because the answers are not interchangeable at the grill.
      expect(find.text('Bread Selection'), findsOneWidget);
      await tester.tap(choice('SAMOON'));
      await tester.pumpAndSettle();
      expect(find.text('Bread Selection'), findsOneWidget);
      await tester.tap(choice('TAMEES'));
      await tester.pumpAndSettle();

      // Then the optional drink prompt, which may be skipped.
      expect(find.text('1 DRINKS'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      // On the cart: the meal, what was chosen, and what it includes.
      expect(find.text('· Shawa Sandw Ckn'), findsNWidgets(2));
      expect(find.text('· SAMOON'), findsOneWidget);
      expect(find.text('· 2 × 1 GARLIC'), findsOneWidget);
      // Free, so no price is shown against them.
      expect(find.text('Charge 15.00 · MADA'), findsOneWidget);
    });

    testWidgets('cancelling a prompt adds nothing at all', (tester) async {
      await pump(tester);

      await tester.tap(find.text('2 SANDWICH OFFER').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel item'));
      await tester.pumpAndSettle();

      // Half-configured is not a state a bill may be in.
      expect(find.text('Tap an item to start'), findsOneWidget);
    });

    testWidgets('a plain item is added without asking anything',
        (tester) async {
      await pump(tester);

      await tester.tap(find.text('HUMMOS').first);
      await tester.pumpAndSettle();

      expect(find.text('Charge 8.00 · MADA'), findsOneWidget);
    });
  });
}
