/// KDS and CDS screens over a stateful fake of the kitchen queue.
///
/// The fake keeps open/done lists and mutates them on bump/recall — so these
/// tests exercise the real request/refresh cycle, not just rendering.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/main.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/ui/cds_screen.dart';
import 'package:pos_app/ui/kds_screen.dart';
import 'package:pos_app/ui/till_screen.dart';

import 'helpers.dart';

/// A kitchen with two tickets: #7 fresh on Grill+DT, #6 older on Shawarma.
class FakeKitchen {
  FakeKitchen() {
    final now = DateTime.now().toUtc();
    open = [
      {
        'id': 'ticket-7',
        'order_no': 7,
        'sale_type_name': 'Drive Thru',
        'table_no': null,
        'external_ref': null,
        'status': 'open',
        'created_at':
            now.subtract(const Duration(seconds: 30)).toIso8601String(),
        'lines': [
          {'id': 'l-71', 'line_no': 1, 'prodnum': 2152,
           'line_des': 'Hummos Lahm', 'qty': 1, 'station_no': 3,
           'note': null, 'seat_no': null, 'done': false, 'voided': false},
          {'id': 'l-72', 'line_no': 2, 'prodnum': 2152,
           'line_des': 'Hummos Lahm', 'qty': 1, 'station_no': 5,
           'note': null, 'seat_no': null, 'done': false, 'voided': false},
        ],
      },
      {
        'id': 'ticket-6',
        'order_no': 6,
        'sale_type_name': 'Keeta',
        'table_no': null,
        'external_ref': 'KEETA-1',
        'status': 'open',
        'created_at':
            now.subtract(const Duration(minutes: 6)).toIso8601String(),
        'lines': [
          {'id': 'l-61', 'line_no': 1, 'prodnum': 2058,
           'line_des': 'Shawa Sandw Ckn', 'qty': 2, 'station_no': 4,
           'note': 'no pickles', 'seat_no': null, 'done': false,
           'voided': false},
        ],
      },
    ];
    done = [];
  }

  late List<Map<String, dynamic>> open;
  late List<Map<String, dynamic>> done;
  final requests = <String>[];

  http.Client client() => MockClient((request) async {
        requests.add('${request.method} ${request.url.path}'
            '${request.url.hasQuery ? '?${request.url.query}' : ''}');
        final path = request.url.path;

        if (path == '/v1/kds/queue') {
          final station = request.url.queryParameters['station'];
          List<Map<String, dynamic>> project(List<Map<String, dynamic>> src) {
            if (station == null) return src;
            final s = int.parse(station);
            return [
              for (final t in src)
                if ((t['lines'] as List)
                    .any((l) => (l as Map)['station_no'] == s))
                  {
                    ...t,
                    'lines': [
                      for (final l in t['lines'] as List)
                        if ((l as Map)['station_no'] == s) l,
                    ],
                  },
            ];
          }

          return http.Response(
              jsonEncode({'open': project(open), 'done': project(done)}), 200,
              headers: {'content-type': 'application/json'});
        }

        final bump = RegExp(r'^/v1/kds/tickets/(.+)/bump$').firstMatch(path);
        if (bump != null) {
          final t = open.firstWhere((x) => x['id'] == bump.group(1));
          open.remove(t);
          done.add({...t, 'status': 'done'});
          return http.Response(jsonEncode(t), 200,
              headers: {'content-type': 'application/json'});
        }

        final recall =
            RegExp(r'^/v1/kds/tickets/(.+)/recall$').firstMatch(path);
        if (recall != null) {
          final t = done.firstWhere((x) => x['id'] == recall.group(1));
          done.remove(t);
          open.add({...t, 'status': 'open'});
          return http.Response(jsonEncode(t), 200,
              headers: {'content-type': 'application/json'});
        }

        if (RegExp(r'^/v1/kds/lines/.+/done$').hasMatch(path)) {
          return http.Response(jsonEncode({'done': true}), 200,
              headers: {'content-type': 'application/json'});
        }

        return http.Response('{"detail":"unexpected ${request.url}"}', 500);
      });
}

SyncApi apiFor(FakeKitchen kitchen) => SyncApi(
    baseUrl: 'http://backend', token: 'tok', client: kitchen.client());

Future<void> unpump(WidgetTester tester) async {
  // Dispose the screen so its poll/clock timers cancel before the test ends.
  await tester.pumpWidget(const SizedBox());
}

void main() {
  setUpAll(useSystemSqlite);

  group('KdsScreen', () {
    testWidgets('shows the rail and flags late tickets', (tester) async {
      final kitchen = FakeKitchen();
      await tester.pumpWidget(MaterialApp(
          home: KdsScreen(
              api: apiFor(kitchen),
              pollInterval: const Duration(minutes: 10))));
      await tester.pump();
      await tester.pump();

      expect(find.text('#7'), findsOneWidget);
      expect(find.text('#6'), findsOneWidget);
      expect(find.textContaining('no pickles'), findsOneWidget);
      // #6 is 6 minutes old — past the 5:00 red line.
      expect(find.text('2 open · 1 late'), findsOneWidget);
      await unpump(tester);
    });

    testWidgets('a pinned station sees only its own lines', (tester) async {
      final kitchen = FakeKitchen();
      await tester.pumpWidget(MaterialApp(
          home: KdsScreen(
              api: apiFor(kitchen),
              stationNo: 4,
              stationNames: const {4: 'Shawarma'},
              pollInterval: const Duration(minutes: 10))));
      await tester.pump();
      await tester.pump();

      expect(find.text('Kitchen — Shawarma'), findsOneWidget);
      expect(find.text('#6'), findsOneWidget);
      expect(find.text('#7'), findsNothing);
      expect(kitchen.requests.first, contains('station=4'));
      await unpump(tester);
    });

    testWidgets('bump moves a ticket to the done lane; recall brings it back',
        (tester) async {
      final kitchen = FakeKitchen();
      await tester.pumpWidget(MaterialApp(
          home: KdsScreen(
              api: apiFor(kitchen),
              pollInterval: const Duration(minutes: 10))));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Bump #7'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Bump #7'), findsNothing);
      expect(kitchen.done.single['id'], 'ticket-7');
      expect(find.text('Recall'), findsOneWidget);

      await tester.tap(find.text('Recall'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Bump #7'), findsOneWidget);
      expect(kitchen.done, isEmpty);
      await unpump(tester);
    });
  });

  group('CdsScreen', () {
    testWidgets('shows preparing and ready lanes with order numbers',
        (tester) async {
      final kitchen = FakeKitchen();
      kitchen.done.add({
        'id': 'ticket-5',
        'order_no': 5,
        'status': 'done',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'lines': [
          {'id': 'l-51', 'line_no': 1, 'prodnum': 1, 'line_des': 'x',
           'qty': 1, 'station_no': 3, 'note': null, 'seat_no': null,
           'done': true, 'voided': false},
        ],
      });

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: CdsScreen(
              api: apiFor(kitchen),
              pollInterval: const Duration(minutes: 10))));
      await tester.pump();
      await tester.pump();

      expect(find.text('Preparing'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);   // preparing
      expect(find.text('6'), findsOneWidget);   // preparing
      expect(find.text('5'), findsOneWidget);   // ready
      expect(find.textContaining('VAT 310000000000003'), findsOneWidget);
      await unpump(tester);
    });
  });

  group('role routing', () {
    testWidgets('a kds-enrolled device boots into the kitchen screen',
        (tester) async {
      final db = PosDatabase.openInMemory(loadSchema());
      db.raw.execute(
        'INSERT INTO device (id, device_uuid, station_no, store_no, '
        "  receipt_prefix, role, kds_station_no, api_base_url, auth_token) "
        "VALUES (1, 'kds-dev', 1, 1, 'K1', 'kds', 3, 'http://b', 't')",
      );
      await tester.pumpWidget(PosApp(db: db));
      await tester.pump();
      expect(find.byType(KdsScreen), findsOneWidget);
      await unpump(tester);
      db.dispose();
    });

    testWidgets('a cds-enrolled device boots into the order board',
        (tester) async {
      final db = PosDatabase.openInMemory(loadSchema());
      db.raw.execute(
        'INSERT INTO device (id, device_uuid, station_no, store_no, '
        "  receipt_prefix, role, api_base_url, auth_token) "
        "VALUES (1, 'cds-dev', 1, 1, 'C1', 'cds', 'http://b', 't')",
      );
      await tester.pumpWidget(PosApp(db: db));
      await tester.pump();
      expect(find.byType(CdsScreen), findsOneWidget);
      await unpump(tester);
      db.dispose();
    });

    testWidgets('a pos device still gets the till', (tester) async {
      final db = seededDatabase();
      tester.view.physicalSize = const Size(1400, 1050);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(PosApp(db: db));
      await tester.pumpAndSettle();
      expect(find.byType(TillScreen), findsOneWidget);
      await unpump(tester);
      db.dispose();
    });
  });
}
