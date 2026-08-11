/// The dine-in journey: the room first, then the order.
///
/// Table service is part of the till. A dine-in sale type opens the floor,
/// seating a table opens the menu with that table's bill attached, and paying
/// gives the table back. Counter trade — 88% of this customer's bills — never
/// sees any of it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/ui/floor_screen.dart';
import 'package:pos_app/ui/till_screen.dart';

import 'helpers.dart';

/// Two tables in one section, one of them already taken by another waiter.
Map<String, dynamic> floorFixture({bool table12Open = true}) => {
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
        {
          'id': 'tbl-12', 'table_no': 12, 'section_id': 'sec-1', 'seats': 2,
          'max_seats': 2, 'pos_x': 5, 'pos_y': 0, 'width': 2, 'height': 2,
          'shape': 'square', 'can_reserve': true, 'is_active': true,
          'status': table12Open ? 'open' : 'free',
          if (table12Open) 'session_id': 'ses-12',
          if (table12Open) 'guests': 2,
          if (table12Open) 'running_total': 4500,
          'party_table_nos': table12Open ? <int>[12] : <int>[],
        },
      ],
      'reservations': [],
    };

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;
  late List<String> calls;

  /// Dine-In, first in the strip and carrying needs_table — exactly as the
  /// imported catalog has it.
  void seedDineIn() {
    db.raw.execute(
      "INSERT INTO sales_type (sale_type_no, descript, price_tier, "
      "  is_aggregator, requires_external_ref, needs_table, sort_order) "
      "VALUES (1003, 'Dine-In', 'a', 0, 0, 1, -1)",
    );
  }

  SyncApi api() {
    return SyncApi(
      baseUrl: 'http://floor.test',
      token: 'device-token',
      client: MockClient((request) async {
        final path = request.url.path;
        calls.add('${request.method} $path');
        http.Response json(Object body) => http.Response(
              jsonEncode(body), 200,
              headers: {'content-type': 'application/json'},
            );

        if (path == '/v1/floor') return json(floorFixture());
        // The endpoint's own shape. A fixture that invented a key the server
        // never sends is what let a crash on seating a table go unnoticed.
        if (path.endsWith('/open')) {
          return json({'session_id': 'ses-new', 'table_no': 11, 'lines': []});
        }
        if (path.endsWith('/close')) return json({'id': 'ses-new'});
        if (path.endsWith('/lines')) return json({'session_id': 'ses-new'});
        if (path.endsWith('/session')) {
          // Only table 12 has a check saved on it; table 11 was just seated.
          if (!path.contains('tbl-12')) {
            return json({'session_id': 'ses-new', 'lines': []});
          }
          // What another tablet already saved onto table 12.
          return json({
            'session_id': 'ses-12',
            'lines': [
              {
                'id': 'l1', 'line_no': 1, 'prodnum': 2013, 'line_des': 'HUMMOS',
                'qty': 2.0, 'unit_price': 800, 'sent_to_kitchen': true,
                'ordered_at': '2026-08-11T10:00:00Z', 'voided': false,
              },
            ],
          });
        }
        return http.Response('{"detail":"unexpected ${request.url}"}', 404,
            headers: {'content-type': 'application/json'});
      }),
    );
  }

  setUp(() {
    db = seededDatabase();
    calls = [];
  });
  tearDown(() => db.dispose());

  Future<void> pumpTill(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: TillScreen(db: db, api: api()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a dine-in order opens the room, not the menu', (tester) async {
    seedDineIn();
    await pumpTill(tester);

    // The floor, with the other waiter's table already showing its bill.
    expect(calls, contains('GET /v1/floor'));
    expect(find.text('11'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('45.00'), findsOneWidget);
    expect(find.text('1 of 2 in use'), findsOneWidget);
    // A dine-in bill with no table is one nobody can deliver food to.
    expect(find.text('HUMMOS'), findsNothing);
  });

  testWidgets('counter trade never sees the floor', (tester) async {
    // No dine-in type seeded: the demo catalog opens on Drive Thru.
    await pumpTill(tester);

    expect(calls, isEmpty);
    expect(find.text('HUMMOS'), findsOneWidget);
  });

  testWidgets('seating a table opens the menu with the table attached',
      (tester) async {
    seedDineIn();
    await pumpTill(tester);

    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();

    // Covers are asked for: every restaurant report divides by them, and the
    // backend refuses a party bigger than the table.
    expect(find.text('Table 11 · how many?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Seat 4'));
    await tester.pumpAndSettle();

    expect(calls, contains('POST /v1/tables/tbl-11/open'));
    expect(find.text('HUMMOS'), findsOneWidget);
    expect(find.text('Table 11 · 4 guests'), findsOneWidget);
  });

  testWidgets('an order waits on its table while the waiter takes another',
      (tester) async {
    seedDineIn();
    await pumpTill(tester);

    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Seat 4'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('HUMMOS').first);
    await tester.pumpAndSettle();
    expect(find.text('Charge 8.00 · MADA'), findsOneWidget);

    // Back to the room. Leaving with a round nobody is cooking is offered as
    // a choice rather than done silently.
    await tester.tap(find.text('Table 11 · 4 guests'));
    await tester.pumpAndSettle();
    expect(find.text('Send this round first?'), findsOneWidget);
    await tester.tap(find.text('Leave without sending'));
    await tester.pumpAndSettle();
    expect(find.text('8.00'), findsOneWidget, reason: 'held on table 11');

    // And walking back onto it picks the same order up.
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    expect(find.text('Charge 8.00 · MADA'), findsOneWidget);
    expect(find.text('Table 11 · how many?'), findsNothing,
        reason: 'the table is already ours; do not seat it twice');
  });

  testWidgets('paying gives the table back', (tester) async {
    seedDineIn();
    await pumpTill(tester);

    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Seat 4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HUMMOS').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Charge 8.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next customer'));
    await tester.pumpAndSettle();

    // The sale carries the table and the covers.
    final sale = db.raw.select('SELECT table_no, num_guests FROM sale').single;
    expect(sale['table_no'], 11);
    expect(sale['num_guests'], 4);

    // The session is closed against that bill, and the till is back in the
    // room ready for the next party.
    // Settled rather than closed: the same call carries a split, and an empty
    // list of lines means "everything still owed", which frees the table.
    expect(calls, contains('POST /v1/sessions/ses-new/settle'));
    expect(find.text('11'), findsOneWidget);
    expect(find.text('HUMMOS'), findsNothing);
  });

  testWidgets('joining a table someone else opened does not re-seat it',
      (tester) async {
    seedDineIn();
    await pumpTill(tester);

    await tester.tap(find.text('12'));
    await tester.pumpAndSettle();

    // No guest prompt and no second session: the waiter joins the bill that is
    // already on the table.
    expect(find.textContaining('how many?'), findsNothing);
    expect(calls.where((c) => c.endsWith('/open')), isEmpty);
    expect(find.text('Table 12 · 2 guests'), findsOneWidget);
  });

  testWidgets('the counter can be served from the floor, and the till stays '
      'there', (tester) async {
    seedDineIn();
    await pumpTill(tester);

    // Somebody walks up while the waiter is in the room.
    await tester.tap(find.textContaining('Quick order'));
    await tester.pumpAndSettle();

    expect(find.text('HUMMOS'), findsOneWidget);
    // Not a dine-in bill with no table: it is takeaway, and it is reported as
    // takeaway.
    expect(find.text('Tables'), findsOneWidget);
    expect(db.activeSaleType(), 2025,
        reason: 'the choice is remembered, so the till stays on counter trade');

    // And the way back to the room is one tap.
    await tester.tap(find.text('Tables'));
    await tester.pumpAndSettle();
    expect(find.text('11'), findsOneWidget);
    expect(db.activeSaleType(), 1003);
  });

  testWidgets('a till starts where it was left, not where the catalog sorts',
      (tester) async {
    seedDineIn();
    // This device does counter trade; Dine-In sorts first in the strip.
    db.setActiveSaleType(2025);

    await pumpTill(tester);

    expect(find.text('HUMMOS'), findsOneWidget);
    expect(calls, isEmpty, reason: 'no floor was fetched for a counter till');
  });

  testWidgets('a floor that cannot be reached says so and offers a retry',
      (tester) async {
    seedDineIn();
    tester.view.physicalSize = const Size(1400, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: TillScreen(
        db: db,
        api: SyncApi(
          baseUrl: 'http://floor.test',
          client: MockClient((_) async => http.Response(
              '{"detail":"floor service is down"}', 503,
              headers: {'content-type': 'application/json'})),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('The floor could not be loaded'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
  });

  testWidgets('a round goes to the kitchen and the check stays open',
      (tester) async {
    seedDineIn();
    await pumpTill(tester);

    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Seat 4'));
    await tester.pumpAndSettle();
    // Hummos Lahm routes to the grill and the drive-thru window (PRINTLOC 40).
    await tester.tap(find.text('Hummos Lahm').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send & save check'));
    await tester.pumpAndSettle();

    // The food is on its way and the round is on the table's check — with no
    // sale, because nobody has paid.
    expect(db.raw.select('SELECT COUNT(*) AS n FROM kitchen_ticket_line')
        .first['n'], 2, reason: 'one line per station it goes to');
    expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 0);
    expect(calls, contains('POST /v1/sessions/ses-new/lines'));
    // And the waiter is back in the room with the table still occupied.
    expect(find.text('11'), findsOneWidget);

    // Coming back and settling does not cook it twice.
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    expect(find.text('Charge 24.00 · MADA'), findsOneWidget);
    await tester.tap(find.textContaining('Charge 24.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next customer'));
    await tester.pumpAndSettle();

    expect(db.raw.select('SELECT COUNT(*) AS n FROM kitchen_ticket_line')
        .first['n'], 2, reason: 'the round was already sent');
    expect(db.raw.select('SELECT COUNT(*) AS n FROM sale').first['n'], 1);
  });

  testWidgets('a check saved on another tablet is picked up, not lost',
      (tester) async {
    seedDineIn();
    await pumpTill(tester);

    // Table 12 belongs to somebody else and has 45.00 on it.
    await tester.tap(find.text('12'));
    await tester.pumpAndSettle();

    // The waiter taking the payment sees the bill, not an empty cart.
    expect(calls, contains('GET /v1/tables/tbl-12/session'));
    expect(find.text('Charge 16.00 · MADA'), findsOneWidget);
    expect(find.textContaining('Picked up 1 items'), findsOneWidget);
  });

  testWidgets('two twos are pushed together into one party', (tester) async {
    seedDineIn();
    await pumpTill(tester);

    // Table 12 has a party of two on it; table 11 is free. Four have arrived.
    await tester.longPress(find.text('11'));
    await tester.pumpAndSettle();
    expect(find.text('Join to a party…'), findsOneWidget);
    await tester.tap(find.text('Join to a party…'));
    await tester.pumpAndSettle();

    // One party open, so no picker — straight to the party size, which the
    // two tables together can now hold.
    expect(find.textContaining('how many now?'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '4'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Seat 4'));
    await tester.pumpAndSettle();

    expect(calls, contains('POST /v1/sessions/ses-12/tables/tbl-11'));
  });

  testWidgets('a merged party reads as one thing on both its tables',
      (tester) async {
    final table = FloorTable.fromJson({
      'id': 'tbl-12', 'table_no': 12, 'section_id': 'sec-1', 'seats': 2,
      'pos_x': 0, 'pos_y': 0, 'width': 2, 'height': 2, 'shape': 'square',
      'status': 'open', 'is_active': true, 'session_id': 'ses-12',
      'party_table_nos': [11, 12],
    });

    // One party, one bill, one name — not "table 12" on one tile and
    // "table 11" on the other.
    expect(table.isMerged, isTrue);
    expect(table.name, 'Tables 11 + 12');
  });

  testWidgets('the areas a restaurant works in are what the till shows',
      (tester) async {
    seedDineIn();
    // Ground floor and terrace, set up in the back office. A waiter picks the
    // area before the table, and only that area's tables are in the way.
    calls = [];
    final api = SyncApi(
      baseUrl: 'http://floor.test',
      token: 'device-token',
      client: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        return http.Response(
          jsonEncode({
            'sections': [
              {'id': 'sec-1', 'code': 'GROUND', 'name': 'Ground floor',
               'sort_order': 1},
              {'id': 'sec-2', 'code': 'TERRACE', 'name': 'Terrace',
               'sort_order': 2},
            ],
            'tables': [
              {
                'id': 'g-1', 'table_no': 1, 'section_id': 'sec-1', 'seats': 2,
                'pos_x': 0, 'pos_y': 0, 'width': 2, 'height': 2,
                'shape': 'round', 'can_reserve': true, 'is_active': true,
                'status': 'free', 'party_table_nos': <int>[],
              },
              {
                'id': 't-7', 'table_no': 7, 'section_id': 'sec-2', 'seats': 4,
                'pos_x': 0, 'pos_y': 0, 'width': 2, 'height': 2,
                'shape': 'rect', 'can_reserve': true, 'is_active': true,
                'status': 'free', 'party_table_nos': <int>[],
              },
            ],
            'reservations': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    tester.view.physicalSize = const Size(1400, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TillScreen(db: db, api: api)));
    await tester.pumpAndSettle();

    // Ground floor first, and only its table.
    expect(find.text('Ground floor'), findsOneWidget);
    expect(find.text('Terrace'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('7'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Terrace'));
    await tester.pumpAndSettle();
    expect(find.text('7'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('an empty area says so, and does not blame the branch',
      (tester) async {
    seedDineIn();
    calls = [];
    final api = SyncApi(
      baseUrl: 'http://floor.test',
      token: 'device-token',
      client: MockClient((request) async => http.Response(
            jsonEncode({
              'sections': [
                {'id': 'sec-1', 'code': 'ROOF', 'name': 'Roof garden',
                 'sort_order': 0},
                {'id': 'sec-2', 'code': 'GROUND', 'name': 'Ground floor',
                 'sort_order': 1},
              ],
              'tables': [
                {
                  'id': 'g-1', 'table_no': 1, 'section_id': 'sec-2',
                  'seats': 2, 'pos_x': 0, 'pos_y': 0, 'width': 2, 'height': 2,
                  'shape': 'round', 'can_reserve': true, 'is_active': true,
                  'status': 'free', 'party_table_nos': <int>[],
                },
              ],
              'reservations': [],
            }),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

    tester.view.physicalSize = const Size(1400, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TillScreen(db: db, api: api)));
    await tester.pumpAndSettle();

    // The floor opens on an area with nothing in it. Telling a waiter the
    // branch has no tables — while the next area along is full — is how a
    // screen loses their trust.
    expect(find.textContaining('Nothing in Roof garden yet'), findsOneWidget);
    expect(find.textContaining('No tables are set up'), findsNothing);

    // And the way out is right there: the area chips are still on screen.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Ground floor'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('the room is read by colour, the way the old screen was',
      (tester) async {
    seedDineIn();
    await pumpTill(tester);

    Color colourOf(String tableNo) {
      final material = tester.widget<Material>(find.ancestor(
        of: find.text(tableNo),
        matching: find.byType(Material),
      ).first);
      return material.color!;
    }

    // Blue is free, amber is somebody else's table — the legend staff already
    // know from the screen this replaces.
    expect(colourOf('11'), const Color(0xFF2F6FED));
    expect(colourOf('12'), const Color(0xFFF4B400));
    expect(find.text('Free'), findsOneWidget);
    expect(find.text('Done soon'), findsOneWidget);

    // Ours turns red the moment we seat it.
    await tester.tap(find.text('11'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Seat 4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Table 11 · 4 guests'));
    await tester.pumpAndSettle();
    expect(colourOf('11'), const Color(0xFFD93025));
  });

  testWidgets('Table info answers a different question on the same floor',
      (tester) async {
    seedDineIn();
    await pumpTill(tester);

    // Money spent: the open table shows its bill, the free one steps back.
    await tester.tap(find.textContaining('Table info'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Money spent').last);
    await tester.pumpAndSettle();
    expect(find.text('45.00'), findsOneWidget);

    // Spend per cover: 45.00 across two covers.
    await tester.tap(find.textContaining('Table info'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Money / cover').last);
    await tester.pumpAndSettle();
    expect(find.text('22.50/c'), findsOneWidget);
  });

  test('a table knows what it is called and how full it is', () {
    final table = FloorTable.fromJson(
        (floorFixture()['tables'] as List)[1] as Map<String, dynamic>);
    expect(table.name, 'Table 12');
    expect(table.isOpen, isTrue);
    expect(table.runningTotal, 4500);
  });
}
