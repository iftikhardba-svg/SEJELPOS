/// The setup screen is what makes a till usable: without the printer field
/// nothing can ever print, and without the ZATCA panel nobody can answer why
/// a receipt says UNSIGNED. These tests hold both to the behaviour the till
/// depends on.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/printing/printer.dart';
import 'package:pos_app/ui/setup_screen.dart';
import 'package:pos_app/zatca/device_signer.dart';
import 'package:pos_app/zatca/signing.dart';

import 'helpers.dart';

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;
  late ZatcaKeyPair keys;

  setUp(() {
    keys = generateKeyPair();
    db = seededDatabase(
      signer: DeviceSigner(keys: InMemoryKeyProvider(keys.privatePem)),
    );
  });
  tearDown(() => db.dispose());

  Future<void> show(WidgetTester tester, {SendBytes? send}) async {
    await tester.pumpWidget(MaterialApp(
      home: SetupScreen(db: db, sendBytes: send),
    ));
  }

  String? printerHost() =>
      db.raw.select('SELECT printer_host FROM device WHERE id = 1')
          .first['printer_host'] as String?;

  group('printer configuration', () {
    testWidgets('saving an address is what finally lets a receipt print',
        (tester) async {
      // The state every fresh device is in: no printer, so the till's print
      // path returns immediately and no paper ever comes out.
      expect(printerHost(), isNull);

      await show(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Printer address'), '192.168.1.50');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(printerHost(), '192.168.1.50');
      expect(
        db.raw.select('SELECT printer_port FROM device WHERE id = 1')
            .first['printer_port'],
        9100,
      );
    });

    testWidgets('a blank address clears the setting rather than storing ""',
        (tester) async {
      db.raw.execute(
          "UPDATE device SET printer_host = '10.0.0.9' WHERE id = 1");

      await show(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Printer address'), '   ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // An empty string would read as "configured" to anything checking for
      // null, then fail at connect time instead of being skipped.
      expect(printerHost(), isNull);
    });

    testWidgets('a nonsense port is refused instead of stored', (tester) async {
      await show(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Printer address'), '192.168.1.50');
      await tester.enterText(find.widgetWithText(TextField, 'Port'), '99999');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(printerHost(), isNull, reason: 'nothing should have been saved');
      expect(find.textContaining('between 1 and 65535'), findsOneWidget);
    });

    testWidgets('the test slip goes to the address on screen, unsigned',
        (tester) async {
      String? sentHost;
      int? sentPort;
      List<int>? sentBytes;

      await show(tester, send: (host, port, bytes) async {
        sentHost = host;
        sentPort = port;
        sentBytes = bytes;
      });

      await tester.enterText(
          find.widgetWithText(TextField, 'Printer address'), '192.168.1.77');
      await tester.enterText(find.widgetWithText(TextField, 'Port'), '9101');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Print a test slip'));
      await tester.pumpAndSettle();

      expect(sentHost, '192.168.1.77');
      expect(sentPort, 9101);
      // A test slip is not a tax document and must say so on the paper.
      expect(utf8.decode(sentBytes!, allowMalformed: true),
          contains('UNSIGNED'));
    });

    testWidgets('an unreachable printer reports instead of throwing',
        (tester) async {
      await show(tester, send: (host, port, bytes) async {
        throw const SocketishFailure();
      });

      await tester.enterText(
          find.widgetWithText(TextField, 'Printer address'), '10.0.0.1');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Print a test slip'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not reach the printer'), findsOneWidget);
    });
  });

  group('ZATCA readiness', () {
    testWidgets('an unprovisioned device says exactly what is missing',
        (tester) async {
      await show(tester);
      expect(find.textContaining('NOT signing'), findsOneWidget);
      expect(find.textContaining('no seller VAT number'), findsOneWidget);
      expect(find.textContaining('UNSIGNED banner'), findsOneWidget);
    });

    testWidgets('a provisioned device reports that it signs', (tester) async {
      db.raw.execute(
        'UPDATE device SET zatca_vat_number = ?, zatca_seller_name = ?, '
        '  zatca_public_key = ?, zatca_csid_signature = ? WHERE id = 1',
        [
          '310000000000003',
          'مطعم فاطمة',
          keys.publicKeyBase64,
          base64Encode(utf8.encode('placeholder')),
        ],
      );

      await show(tester);
      expect(find.textContaining('Signing invoices'), findsOneWidget);
      expect(find.text('310000000000003'), findsOneWidget);
    });
  });

  group('sync status', () {
    testWidgets('separates what is queued from what the server refused',
        (tester) async {
      final queued = chargeOneItem(db);
      final refused = chargeOneItem(db);
      db.raw.execute(
        "UPDATE outbox SET last_error = 'rejected' WHERE entity_uuid = ?",
        [refused.saleUuid],
      );

      await show(tester);
      // The sync panel is the last section, below the fold on a small
      // viewport, so the ListView has not built it yet.
      await tester.scrollUntilVisible(
        find.text('Sales the server refused'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // Both numbers matter and they mean different things: one drains on its
      // own, the other never will without a human. A bare find.text('1')
      // would also match the station and receipt counters, so each assertion
      // is scoped to its own row.
      Finder valueOf(String label) => find.descendant(
            of: find.ancestor(
              of: find.text(label),
              matching: find.byType(Row),
            ),
            matching: find.text('1'),
          );

      expect(valueOf('Sales waiting to send'), findsOneWidget);
      expect(valueOf('Sales the server refused'), findsOneWidget);
      expect(queued.saleUuid, isNot(refused.saleUuid));
    });
  });
}

/// Stands in for a socket failure without needing dart:io in a widget test.
class SocketishFailure implements Exception {
  const SocketishFailure();

  @override
  String toString() => 'connection refused';
}
