/// The receipt on screen, and the promise it makes.
///
/// The promise is that the screen shows what the paper would: it is decoded
/// from the same bytes the printer is sent, never rebuilt from the receipt
/// data. These pin that — the decoder against the builder, so the two cannot
/// drift apart without a test going red.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pos_app/core/money.dart';
import 'package:pos_app/printing/escpos.dart';
import 'package:pos_app/printing/escpos_preview.dart';
import 'package:pos_app/ui/receipt_screen.dart';

/// A ZATCA QR is base64 TLV — long, and the reason the payload has to survive
/// the round trip byte for byte.
const _qr = 'AQVTRUpFTAIPMzEwMDAwMDAwMDAwMDAzAxQyMDI2LTA4LTEyVDE4OjIwOjAwWgQ'
    'FNTQuMDAFBDcuMDQ=';

ReceiptData sample({String? qr, String? branch = 'Olaya'}) => ReceiptData(
      brandName: 'SEJEL Restaurant',
      branchName: branch,
      vatNumber: '310000000000003',
      receiptNo: 'A01-000042',
      orderNo: 'C01-205',
      dateTime: DateTime(2026, 8, 12, 18, 20),
      lines: [
        ReceiptLine(qty: 2, name: 'KEBAB LAHM SMALLL', amount: 2000),
        ReceiptLine(qty: 1, name: 'Twin Combo Meal', amount: 3400),
        ReceiptLine(qty: 1, name: 'COCA COLA MEDIUM', amount: 0, depth: 1),
      ],
      netTotal: 4696,
      taxTotal: 704,
      finalTotal: 5400,
      payments: const [
        ReceiptTender(name: 'CASH', amount: 5400, change: 600),
      ],
      zatcaQr: qr,
    );

List<ReceiptTextPart> textOf(List<ReceiptPart> parts) =>
    [for (final p in parts) if (p is ReceiptTextPart) p];

void main() {
  group('decoding the stream the printer gets', () {
    test('every line of the receipt comes back, in order', () {
      final lines = textOf(decodeReceipt(buildReceipt(sample(qr: _qr))))
          .map((t) => t.text)
          .toList();

      expect(lines.first, 'SEJEL Restaurant');
      expect(lines[1], 'Olaya', reason: 'the branch, under the seller');
      expect(lines, contains('VAT 310000000000003'));
      expect(lines, contains('ORDER C01-205'));
      expect(lines.any((l) => l.startsWith('Receipt A01-000042')), isTrue);
      expect(lines.any((l) => l.contains('KEBAB LAHM SMALLL')), isTrue);
      expect(lines.any((l) => l.contains('TOTAL') && l.contains('54.00')),
          isTrue);
      expect(lines.any((l) => l.contains('CHANGE') && l.contains('6.00')),
          isTrue);
      expect(lines.last, 'Shukran!');
    });

    test('a device with no branch simply omits the line', () {
      final lines = textOf(decodeReceipt(buildReceipt(sample(branch: null))))
          .map((t) => t.text)
          .toList();
      expect(lines.first, 'SEJEL Restaurant');
      expect(lines[1], 'VAT 310000000000003');
    });

    test('nothing is silently dropped', () {
      // The decoder reports what it does not understand rather than skipping
      // it: a preview missing a line looks right, which is the dangerous kind
      // of wrong.
      expect(
        decodeReceipt(buildReceipt(sample(qr: _qr)))
            .whereType<ReceiptUnknownPart>(),
        isEmpty,
      );
    });

    test('the attributes in force are carried with the line', () {
      final parts = textOf(decodeReceipt(buildReceipt(sample(qr: _qr))));
      final brand = parts.firstWhere((t) => t.text == 'SEJEL Restaurant');
      expect(brand.doubleSize, isTrue, reason: 'the name is the big line');
      expect(brand.align, 1, reason: 'centred');

      final total = parts.firstWhere((t) => t.text.startsWith('TOTAL'));
      expect(total.bold, isTrue);
      expect(total.align, 0);

      final item =
          parts.firstWhere((t) => t.text.contains('KEBAB LAHM SMALLL'));
      expect(item.bold, isFalse, reason: 'bold ended before the items');
      expect(item.doubleSize, isFalse);
    });

    test('the QR payload survives byte for byte', () {
      final qr = decodeReceipt(buildReceipt(sample(qr: _qr)))
          .whereType<ReceiptQrPart>()
          .single;
      // Anything less and the screen shows a QR that scans to something other
      // than the invoice — which is worse than showing none.
      expect(qr.data, _qr);
      expect(qr.align, 1);
    });

    test('an unsigned receipt shows the banner and no QR', () {
      final parts = decodeReceipt(buildReceipt(sample()));
      expect(parts.whereType<ReceiptQrPart>(), isEmpty);
      final banner =
          textOf(parts).firstWhere((t) => t.text.contains('UNSIGNED'));
      expect(banner.bold, isTrue);
      expect(banner.text, contains('NOT A TAX INVOICE'));
    });

    test('the paper is fed and cut where the builder says', () {
      final parts = decodeReceipt(buildReceipt(sample(qr: _qr)));
      expect(parts.whereType<ReceiptCutPart>().length, 1);
      expect(parts.last, isA<ReceiptCutPart>());
      expect(parts.whereType<ReceiptFeedPart>(), isNotEmpty);
    });

    test('a stream that ends mid-command is reported, not guessed at', () {
      final truncated = [...buildReceipt(sample()).take(3), 0x1B];
      expect(decodeReceipt(truncated).whereType<ReceiptUnknownPart>(),
          isNotEmpty);
    });
  });

  group('the receipt on screen', () {
    Future<void> pump(WidgetTester tester, List<int> bytes) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: ReceiptScreen(bytes: bytes)));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the invoice a customer would be handed',
        (tester) async {
      await pump(tester, buildReceipt(sample(qr: _qr)));
      expect(find.text('SEJEL Restaurant'), findsOneWidget);
      expect(find.text('Olaya'), findsOneWidget);
      expect(find.textContaining('ORDER C01-205'), findsOneWidget);
      expect(find.textContaining('KEBAB LAHM SMALLL'), findsOneWidget);
      expect(find.textContaining(formatHalalas(5400)), findsWidgets);
      // And the QR is drawn, not described.
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('an unsigned receipt says so on the glass too',
        (tester) async {
      await pump(tester, buildReceipt(sample()));
      expect(find.textContaining('UNSIGNED'), findsOneWidget);
    });

    testWidgets('offers printing only when there is a printer',
        (tester) async {
      await pump(tester, buildReceipt(sample()));
      expect(find.text('Print'), findsNothing);

      var printed = false;
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(MaterialApp(
        home: ReceiptScreen(
          bytes: buildReceipt(sample()),
          onPrint: () async => printed = true,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      expect(printed, isTrue);
    });
  });
}
