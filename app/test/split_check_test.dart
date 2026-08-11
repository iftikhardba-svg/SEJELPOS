/// Splitting a check between the guests who ate it.
///
/// Four people, four bills. Each share is its own sale, so each gets its own
/// receipt number and its own ZATCA stamp — which is why a share is made of
/// items and never of an amount. The table stays open until nothing is owed.
///
/// The other half of this file is the thing splitting depends on: a check
/// picked back up off the server has to come back at the price it was quoted
/// and with the structure it was ordered in. Re-pricing it through the catalog
/// charges a meal's covered drink at menu rate on a bill the guest has already
/// been shown.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/ui/till_screen.dart';

import 'helpers.dart';

/// A table's check, kept the way the backend keeps it: numbered lines, a
/// parent for anything chosen inside an item, and a bill against each line
/// once somebody has paid for it.
class _FakeCheck {
  _FakeCheck(this.lines);

  final List<Map<String, dynamic>> lines;
  final List<String> settled = [];

  int get _next =>
      lines.fold<int>(0, (a, l) => a > (l['line_no'] as int)
          ? a
          : l['line_no'] as int) + 1;

  Map<String, dynamic> get detail => {
        'session_id': 'ses-11',
        'table_no': 11,
        'status': lines.every((l) => l['settled_sale_uuid'] != null)
            ? 'billed'
            : 'open',
        'lines': lines,
      };

  void add(List<dynamic> incoming) {
    final assigned = <int, int>{};
    for (var i = 0; i < incoming.length; i++) {
      final line = (incoming[i] as Map).cast<String, dynamic>();
      final no = _next;
      assigned[i] = no;
      final parentIndex = line['parent_index'] as int?;
      lines.add({
        'line_no': no,
        'prodnum': line['prodnum'],
        'line_des': line['line_des'],
        'qty': (line['qty'] as num).toDouble(),
        'unit_price': line['unit_price'],
        'parent_line_no':
            parentIndex == null ? null : assigned[parentIndex - 1],
        'settled_sale_uuid': null,
        'voided': false,
      });
    }
  }

  /// Break [qty] off a line, taking anything chosen inside it along in
  /// proportion — exactly what the endpoint does.
  void split(int lineNo, double qty) {
    final source = lines.firstWhere((l) => l['line_no'] == lineNo);
    final share = qty / (source['qty'] as double);

    void move(Map<String, dynamic> from, double moved, int? parent) {
      final no = _next;
      lines.add({
        'line_no': no,
        'prodnum': from['prodnum'],
        'line_des': from['line_des'],
        'qty': moved,
        'unit_price': from['unit_price'],
        'parent_line_no': parent,
        'settled_sale_uuid': null,
        'voided': false,
      });
      from['qty'] = (from['qty'] as double) - moved;
      for (final child in [
        for (final l in List.of(lines))
          if (l['parent_line_no'] == from['line_no']) l,
      ]) {
        move(child, (child['qty'] as double) * share, no);
      }
    }

    move(source, qty, null);
  }

  void settle(String saleUuid, List<dynamic> lineNos) {
    settled.add(saleUuid);
    final wanted = lineNos.isEmpty
        ? [
            for (final l in lines)
              if (l['settled_sale_uuid'] == null) l['line_no'] as int,
          ]
        : lineNos.cast<int>();
    for (final l in lines) {
      if (wanted.contains(l['line_no'])) l['settled_sale_uuid'] = saleUuid;
    }
  }
}

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;
  late List<String> calls;
  late _FakeCheck check;

  void seedDineIn() {
    db.raw.execute(
      "INSERT INTO sales_type (sale_type_no, descript, price_tier, "
      "  is_aggregator, requires_external_ref, needs_table, sort_order) "
      "VALUES (1003, 'Dine-In', 'a', 0, 0, 1, -1)",
    );
  }

  Map<String, dynamic> floorFixture() => {
        'sections': [
          {'id': 'sec-1', 'code': 'SEC1', 'name': 'Main Hall', 'sort_order': 0},
        ],
        'tables': [
          {
            'id': 'tbl-11', 'table_no': 11, 'section_id': 'sec-1', 'seats': 4,
            'max_seats': 6, 'pos_x': 0, 'pos_y': 0, 'width': 2, 'height': 2,
            'shape': 'round', 'can_reserve': true, 'is_active': true,
            'status': 'free', 'party_table_nos': <int>[],
          },
        ],
        'reservations': [],
      };

  SyncApi api() => SyncApi(
        baseUrl: 'http://split.test',
        token: 'device-token',
        client: MockClient((request) async {
          final path = request.url.path;
          calls.add('${request.method} $path');
          http.Response json(Object body) => http.Response(
                jsonEncode(body), 200,
                headers: {'content-type': 'application/json'},
              );

          if (path == '/v1/floor') return json(floorFixture());
          if (path.endsWith('/open')) {
            return json({'session_id': 'ses-11', 'table_no': 11, 'lines': []});
          }
          if (path.endsWith('/session')) return json(check.detail);
          if (path.endsWith('/lines')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            check.add(body['lines'] as List);
            return json(check.detail);
          }
          if (path.contains('/split')) {
            final lineNo = int.parse(path.split('/')[5]);
            check.split(
                lineNo, double.parse(request.url.queryParameters['qty']!));
            return json(check.detail);
          }
          if (path.endsWith('/settle')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            check.settle(
                body['sale_uuid'] as String, body['line_nos'] as List);
            return json(check.detail);
          }
          return http.Response('{"detail":"unexpected ${request.url}"}', 404,
              headers: {'content-type': 'application/json'});
        }),
      );

  setUp(() {
    db = seededDatabase();
    calls = [];
    check = _FakeCheck([]);
  });
  tearDown(() => db.dispose());

  Future<void> pumpTill(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TillScreen(db: db, api: api())));
    await tester.pumpAndSettle();
  }

  Future<void> seatTable11(WidgetTester tester) async {
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Seat 4'));
    await tester.pumpAndSettle();
  }

  // ------------------------------------------------------------------------
  // A check that has already been quoted
  // ------------------------------------------------------------------------

  group('a check picked back up off the server', () {
    /// A meal at 24.00 with a water the meal covers, saved by another tablet.
    /// The water sells for 1.00 on its own, which is exactly the trap: priced
    /// through the catalog it would be charged for.
    void savedMealWithACoveredDrink() {
      check = _FakeCheck([
        {
          'line_no': 1, 'prodnum': 2152, 'line_des': 'Hummos Lahm',
          'qty': 1.0, 'unit_price': 2400, 'parent_line_no': null,
          'settled_sale_uuid': null, 'voided': false,
        },
        {
          'line_no': 2, 'prodnum': 2499, 'line_des': 'Water Small',
          'qty': 1.0, 'unit_price': 0, 'parent_line_no': 1,
          'settled_sale_uuid': null, 'voided': false,
        },
      ]);
    }

    testWidgets('rings at the price the guest was quoted', (tester) async {
      seedDineIn();
      savedMealWithACoveredDrink();
      await pumpTill(tester);
      await seatTable11(tester);

      // The bill is the meal, not the meal plus a water nobody ordered.
      expect(find.text('Charge 24.00 · MADA'), findsOneWidget);

      await tester.tap(find.textContaining('Charge 24.00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next customer'));
      await tester.pumpAndSettle();

      final lines = db.raw.select(
        'SELECT line_des, unit_price, parent_line FROM sale_line '
        'ORDER BY line_no',
      );
      expect(lines.length, 2);
      expect(lines[0]['unit_price'], 2400);
      // The covered drink stays covered, and stays underneath the meal.
      expect(lines[1]['line_des'], 'Water Small');
      expect(lines[1]['unit_price'], 0);
      expect(lines[1]['parent_line'], isNotNull);
      expect(db.raw.select('SELECT final_total FROM sale').single['final_total'],
          2400);
    });

    testWidgets('leaves out what another guest has already paid for',
        (tester) async {
      seedDineIn();
      savedMealWithACoveredDrink();
      check.lines.add({
        'line_no': 3, 'prodnum': 2013, 'line_des': 'HUMMOS', 'qty': 1.0,
        'unit_price': 800, 'parent_line_no': null,
        'settled_sale_uuid': 'someone-elses-bill', 'voided': false,
      });
      await pumpTill(tester);
      await seatTable11(tester);

      expect(find.text('Charge 24.00 · MADA'), findsOneWidget);

      // Charging takes only what is owed: the meal and its drink, not the
      // HUMMOS somebody has already paid for and left.
      await tester.tap(find.textContaining('Charge 24.00'));
      await tester.pumpAndSettle();
      final lines = db.raw.select('SELECT prodnum FROM sale_line');
      expect(lines.map((l) => l['prodnum']), [2152, 2499]);
    });
  });

  // ------------------------------------------------------------------------
  // Splitting it
  // ------------------------------------------------------------------------

  group('splitting the check', () {
    Future<void> orderTwoThings(WidgetTester tester) async {
      // 3 x HUMMOS at 8.00 and one MOUSHAKAL SABAH at 38.00.
      await tester.tap(find.text('HUMMOS').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('HUMMOS').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('HUMMOS').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('MOUSHAKAL SABAH').first);
      await tester.pumpAndSettle();
    }

    Future<void> openSplit(WidgetTester tester) async {
      await tester.tap(find.text('Split the check'));
      await tester.pumpAndSettle();
    }

    testWidgets('saves the round first, because a share names its lines',
        (tester) async {
      seedDineIn();
      await pumpTill(tester);
      await seatTable11(tester);
      await orderTwoThings(tester);
      await openSplit(tester);

      expect(calls, contains('POST /v1/sessions/ses-11/lines'));
      expect(find.text('Split Table 11'), findsOneWidget);
      expect(find.text('Still on the table'), findsOneWidget);
      // Everything starts on the table; nothing is on a guest's bill yet.
      expect(find.text('Nothing on this bill yet'), findsOneWidget);
    });

    testWidgets('one guest pays for their own item and the table stays open',
        (tester) async {
      seedDineIn();
      await pumpTill(tester);
      await seatTable11(tester);
      await orderTwoThings(tester);
      await openSplit(tester);

      await tester.tap(find.text('MOUSHAKAL SABAH'));
      await tester.pumpAndSettle();
      expect(find.text('Charge this guest 38.00'), findsOneWidget);

      await tester.tap(find.text('Charge this guest 38.00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MADA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next customer'));
      await tester.pumpAndSettle();

      // One sale, for that guest's item only — its own receipt, its own
      // invoice.
      final sale = db.raw.select('SELECT final_total FROM sale').single;
      expect(sale['final_total'], 3800);

      // The table is still open with the rest of the check on it, and the
      // server was told which lines that bill paid for.
      expect(find.text('Split Table 11'), findsOneWidget);
      expect(find.text('Charge this guest'), findsNothing);
      expect(check.lines.where((l) => l['settled_sale_uuid'] != null).length,
          1);
      expect(
        check.lines
            .firstWhere((l) => l['prodnum'] == 2008)['settled_sale_uuid'],
        isNotNull,
      );
    });

    testWidgets('the last share closes the table and leaves the split screen',
        (tester) async {
      seedDineIn();
      await pumpTill(tester);
      await seatTable11(tester);
      await orderTwoThings(tester);
      await openSplit(tester);

      for (final item in ['MOUSHAKAL SABAH', '3 × HUMMOS']) {
        await tester.tap(find.text(item));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.textContaining('Charge this guest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MADA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next customer'));
      await tester.pumpAndSettle();

      // Nothing owed: the split screen is gone and so is the table.
      expect(find.text('Split Table 11'), findsNothing);
      expect(check.lines.every((l) => l['settled_sale_uuid'] != null), isTrue);
      expect(db.raw.select('SELECT final_total FROM sale').single['final_total'],
          3800 + 2400);
    });

    testWidgets('three of a dish become one guest\'s and two more',
        (tester) async {
      seedDineIn();
      await pumpTill(tester);
      await seatTable11(tester);
      await orderTwoThings(tester);
      await openSplit(tester);

      // 3 x HUMMOS on one line; one of them is this guest's.
      await tester.tap(find.byTooltip('Split this line'));
      await tester.pumpAndSettle();
      expect(find.text('How many of HUMMOS?'), findsOneWidget);
      await tester.tap(find.text('Move it across'));
      await tester.pumpAndSettle();

      // The server divided it, and the piece that came off is already on this
      // guest's bill.
      expect(calls.any((c) => c.contains('/split')), isTrue);
      expect(find.text('Charge this guest 8.00'), findsOneWidget);
      expect(find.text('2 × HUMMOS'), findsOneWidget);
    });

    testWidgets('a share is items, never an amount', (tester) async {
      // The screen offers no way to type a number: an invoice line has to be
      // something that was sold, so "50 riyals of it" cannot be a bill of its
      // own. That case is the payment split, on one invoice.
      seedDineIn();
      await pumpTill(tester);
      await seatTable11(tester);
      await orderTwoThings(tester);
      await openSplit(tester);

      expect(find.byType(TextField), findsNothing);
    });
  });
}
