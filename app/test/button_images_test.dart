/// Pictures on till buttons.
///
/// A picture is read faster than a name, which is the point of putting one on
/// a button — but a cashier still has to check what they pressed and what it
/// costs, so the tile carries all three rather than the picture replacing the
/// words.
///
/// The bytes travel in the catalog and live on the device, because a till has
/// to draw its menu with no network at all.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/data/schema_migrations.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/sync/sync_service.dart';
import 'package:pos_app/ui/till_screen.dart';

import 'helpers.dart';

/// A 1x1 red PNG — real bytes, so anything that decodes them succeeds.
final redDot = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==');

Map<String, dynamic> imageDelta({
  int prodnum = 2013,
  int version = 9,
  bool deleted = false,
}) =>
    {
      'version': version,
      'has_more': false,
      'product_images': [
        {
          'prodnum': prodnum,
          'mime': 'image/png',
          'width': 512,
          'height': 512,
          'byte_size': redDot.length,
          'data_b64': deleted ? null : base64Encode(redDot),
          'server_version': version,
          'is_deleted': deleted,
        },
      ],
    };

void main() {
  setUpAll(useSystemSqlite);

  late PosDatabase db;
  setUp(() => db = seededDatabase());
  tearDown(() => db.dispose());

  SyncService service() => SyncService(
        db: db,
        api: SyncApi(
          baseUrl: 'http://images.test',
          client: MockClient((_) async =>
              throw StateError('applyCatalog must not touch the wire')),
        ),
      );

  group('a picture arriving from the catalog', () {
    test('is stored with the product it belongs to', () {
      service().applyCatalog(imageDelta());
      final row = db.raw
          .select('SELECT * FROM product_image WHERE prodnum = 2013')
          .single;
      expect(row['mime'], 'image/png');
      expect(row['data'], redDot);
      expect(row['width'], 512);
      expect(row['server_version'], 9);
    });

    test('replaces the one before it rather than piling up', () {
      final s = service();
      s.applyCatalog(imageDelta(version: 9));
      s.applyCatalog(imageDelta(version: 10));
      final rows = db.raw.select('SELECT * FROM product_image');
      expect(rows.length, 1);
      expect(rows.single['server_version'], 10);
    });

    test('a tombstone takes the picture off the device', () {
      final s = service();
      s.applyCatalog(imageDelta());
      s.applyCatalog(imageDelta(version: 11, deleted: true));
      // Removed outright: on a tablet the only use for a tombstone is knowing
      // the picture went, and its absence already says that.
      expect(db.raw.select('SELECT * FROM product_image'), isEmpty);
    });

    test('a row with no bytes leaves what the device holds alone', () {
      // Belt and braces against a server that ever sends a live row without
      // its data: blanking a good picture would be worse than keeping it.
      final s = service();
      s.applyCatalog(imageDelta());
      s.applyCatalog({
        'version': 12,
        'has_more': false,
        'product_images': [
          {
            'prodnum': 2013, 'mime': 'image/png', 'width': 512, 'height': 512,
            'byte_size': 0, 'data_b64': null, 'server_version': 12,
            'is_deleted': false,
          },
        ],
      });
      expect(
        db.raw.select('SELECT data FROM product_image').single['data'],
        redDot,
      );
    });
  });

  group('the menu', () {
    test('carries the picture with the button', () {
      service().applyCatalog(imageDelta());
      final items = db.productsForScreen(2010);
      final hummos = items.firstWhere((p) => p.prodnum == 2013);
      expect(hummos.image, isNotNull);
      expect(hummos.image, isA<Uint8List>());
      expect(hummos.imageVersion, 9);
      // And a product nobody has set one on is simply without.
      expect(items.firstWhere((p) => p.prodnum == 2008).image, isNull);
    });

    testWidgets('draws the image, the name and the price on one button',
        (tester) async {
      service().applyCatalog(imageDelta());
      tester.view.physicalSize = const Size(1400, 1050);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(home: TillScreen(db: db)));
      await tester.pumpAndSettle();

      // The picture is on the tile...
      expect(find.byType(Image), findsWidgets);
      // ...and so are both of the things a cashier has to be able to check.
      expect(find.text('HUMMOS'), findsOneWidget);
      expect(find.text('8.00'), findsWidgets);
    });

    testWidgets('a button with no picture keeps the plain tile',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1050);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(home: TillScreen(db: db)));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.text('HUMMOS'), findsOneWidget);
    });
  });

  group('an installed till upgrading', () {
    test('gains the table and re-pulls the catalog', () {
      // A v5 database — what a till in service is running before this build.
      final raw = sqlite3.openInMemory();
      raw.execute(loadSchema());
      raw.execute('DROP TABLE product_image');
      raw.execute(
        "INSERT INTO sync_state (table_name, last_version) "
        "VALUES ('catalog', 4200) "
        'ON CONFLICT(table_name) DO UPDATE SET last_version = 4200',
      );
      raw.execute('PRAGMA user_version = 5');

      final applied = migrateTabletSchema(raw);
      expect(applied, contains(6));
      expect(
        raw.select("SELECT name FROM sqlite_master WHERE name='product_image'"),
        isNotEmpty,
      );
      // The watermark goes back to zero, or a picture uploaded before this
      // build shipped is below it and never arrives.
      expect(
        raw
            .select("SELECT last_version FROM sync_state "
                "WHERE table_name = 'catalog'")
            .single['last_version'],
        0,
      );
      raw.dispose();
    });
  });
}
