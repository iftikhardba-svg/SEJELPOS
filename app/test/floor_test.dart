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
          'status': 'free',
        },
        {
          'id': 'tbl-12', 'table_no': 12, 'section_id': 'sec-1', 'seats': 2,
          'max_seats': 2, 'pos_x': 5, 'pos_y': 0, 'width': 2, 'height': 2,
          'shape': 'square', 'can_reserve': true, 'is_active': true,
          'status': table12Open ? 'open' : 'free',
          if (table12Open) 'session_id': 'ses-12',
          if (table12Open) 'guests': 2,
          if (table12Open) 'running_total': 4500,
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
        if (path.endsWith('/open')) return json({'id': 'ses-new'});
        if (path.endsWith('/close')) return json({'id': 'ses-new'});
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

    // Back to the room: the round stays on the table rather than being lost.
    await tester.tap(find.text('Table 11 · 4 guests'));
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
    expect(calls, contains('POST /v1/sessions/ses-new/close'));
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

  test('a table knows what it is called and how full it is', () {
    final table = FloorTable.fromJson(
        (floorFixture()['tables'] as List)[1] as Map<String, dynamic>);
    expect(table.name, 'Table 12');
    expect(table.isOpen, isTrue);
    expect(table.runningTotal, 4500);
  });
}
