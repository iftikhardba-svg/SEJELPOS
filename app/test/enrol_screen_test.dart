/// The enrolment screen is the first thing anyone sees on a new tablet, and
/// the only way into the app. If its card lands off-centre or its buttons sit
/// below the fold, setup stalls before a single sale.
///
/// These assert geometry rather than eyeball a screenshot: a desktop capture
/// of a Flutter window goes through DirectX and can render offset or stale,
/// so "it looked wrong in a PNG" is not evidence and "it looked right" is not
/// either.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/ui/enrol_screen.dart';

import 'helpers.dart';

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;

  setUp(() {
    // A bare database: the enrol screen exists precisely when no device row
    // does, so seeding one would test the wrong state.
    db = PosDatabase.openInMemory(loadSchema());
  });
  tearDown(() => db.dispose());

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: EnrolScreen(db: db, onReady: () {}),
    ));
    await tester.pumpAndSettle();
  }

  group('layout', () {
    for (final size in const [
      Size(1280, 800),   // the Windows runner default
      Size(1024, 768),   // a small tablet in landscape
      Size(800, 1280),   // portrait
    ]) {
      testWidgets('the card is horizontally centred at ${size.width.toInt()}'
          'x${size.height.toInt()}', (tester) async {
        await pumpAt(tester, size);

        final card = tester.getRect(find.byKey(const Key('enrol-card')));
        final cardCentre = (card.left + card.right) / 2;
        expect(
          cardCentre,
          moreOrLessEquals(size.width / 2, epsilon: 1.0),
          reason: 'setup card drifted off centre: $card in $size',
        );
      });

      testWidgets('both ways in are reachable at ${size.width.toInt()}'
          'x${size.height.toInt()}', (tester) async {
        await pumpAt(tester, size);

        // The demo button is the last thing in the column and the first to
        // fall off the bottom.
        for (final label in ['Enrol this device', 'Try the demo instead']) {
          final button = find.text(label);
          expect(button, findsOneWidget);
          final rect = tester.getRect(button);
          expect(rect.bottom, lessThanOrEqualTo(size.height),
              reason: '"$label" is below the fold at $size');
          expect(rect.top, greaterThanOrEqualTo(0.0),
              reason: '"$label" is above the viewport at $size');
        }
      });
    }

    testWidgets('the card stops widening on a wide screen', (tester) async {
      // Full-bleed text fields on a 1280px till would be unusable to aim at.
      await pumpAt(tester, const Size(1920, 1080));
      final card = tester.getRect(find.byKey(const Key('enrol-card')));
      expect(card.width, lessThanOrEqualTo(420.0));
    });
  });

  group('behaviour', () {
    testWidgets('demo mode seeds a catalog and reports ready', (tester) async {
      var ready = false;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: EnrolScreen(db: db, onReady: () => ready = true),
      ));
      await tester.tap(find.text('Try the demo instead'));
      await tester.pumpAndSettle();

      expect(ready, isTrue);
      expect(db.productsForScreen(2010), isNotEmpty);
      expect(db.salesTypes(), isNotEmpty);
    });

    testWidgets('an empty code is refused before any network call',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: EnrolScreen(
          db: db,
          onReady: () {},
          // Any use of this would be a bug: nothing should be sent.
          clientFactory: () => throw StateError('must not reach the network'),
        ),
      ));
      await tester.tap(find.text('Enrol this device'));
      await tester.pumpAndSettle();

      expect(find.textContaining('both needed'), findsOneWidget);
    });
  });
}
