/// Upgrading a tablet that is already in service.
///
/// This exists because it did not. `openFile` ran schema.sql on a fresh file
/// and nothing at all on an existing one, so the first schema change shipped
/// in an update would have met every installed till with "no such column" on
/// its first query. It surfaced in development as a crash on an app database
/// that had survived a rebuild — which is exactly what a customer's tablet is,
/// permanently.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/data/schema_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

import 'helpers.dart';

/// The v1 shape of what the later versions touch: no block_end, no
/// active_empnum, no button colours, no menu tables. Trimmed from the real
/// schema so the test does not depend on a copy of the whole file — it grows
/// only when a migration step needs another table to alter.
const _v1 = '''
CREATE TABLE device (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    device_uuid     TEXT NOT NULL UNIQUE,
    station_no      INTEGER NOT NULL,
    store_no        INTEGER NOT NULL,
    receipt_prefix  TEXT NOT NULL,
    next_receipt_seq INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE employee (
    empnum   INTEGER PRIMARY KEY,
    name     TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE order_counter (
    business_date  TEXT PRIMARY KEY,
    next_number    INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE product (prodnum INTEGER PRIMARY KEY);
CREATE TABLE menu_screen (
    menu_id  INTEGER PRIMARY KEY,
    name     TEXT NOT NULL
);
CREATE TABLE sync_state (
    table_name     TEXT PRIMARY KEY,
    last_version   INTEGER NOT NULL DEFAULT 0,
    last_pulled_at TEXT
);
CREATE TABLE kitchen_ticket_line (
    line_uuid   TEXT PRIMARY KEY,
    ticket_uuid TEXT NOT NULL,
    line_no     INTEGER NOT NULL,
    prodnum     INTEGER NOT NULL,
    line_des    TEXT NOT NULL,
    qty         REAL NOT NULL DEFAULT 1,
    station_no  INTEGER NOT NULL
);
''';

void main() {
  setUpAll(useSystemSqlite);

  Database openV1() {
    final db = sqlite3.openInMemory();
    db.execute(_v1);
    db.execute('PRAGMA user_version = 1');
    return db;
  }

  List<String> columns(Database db, String table) => db
      .select('PRAGMA table_info($table)')
      .map((r) => r['name'] as String)
      .toList();

  int version(Database db) =>
      db.select('PRAGMA user_version').first.values.first as int;

  test('a version 1 database climbs to the current version', () {
    final db = openV1();
    addTearDown(db.dispose);

    expect(columns(db, 'order_counter'), isNot(contains('block_end')));
    expect(columns(db, 'device'), isNot(contains('active_empnum')));

    final applied = migrateTabletSchema(db);

    // Every step above 1, in order — not just the newest.
    expect(applied, [for (var v = 2; v <= tabletSchemaVersion; v++) v]);
    expect(columns(db, 'order_counter'), contains('block_end'));
    expect(columns(db, 'device'), contains('active_empnum'));
    expect(version(db), tabletSchemaVersion);
  });

  test('the menu a till lands on arrives with version 3', () {
    final db = openV1();
    addTearDown(db.dispose);

    migrateTabletSchema(db);

    // A till that upgraded rather than reinstalled must get the menu tables,
    // or it falls back to a flat page list forever.
    expect(columns(db, 'menu'), contains('menu_no'));
    expect(columns(db, 'menu_page'), contains('screen_no'));
    expect(columns(db, 'menu_screen'), contains('back_color'));
    expect(columns(db, 'product'), contains('button_text'));
    expect(columns(db, 'product'), contains('back_color'));
  });

  test('meal-deal prompts arrive with version 4', () {
    final db = openV1();
    addTearDown(db.dispose);

    migrateTabletSchema(db);

    // Without these an upgraded till holds a catalog it cannot store: the
    // apply would fail on the first question and no catalog would land at all.
    expect(columns(db, 'question'), contains('pick_count'));
    expect(columns(db, 'question_choice'), contains('fixed_price'));
    expect(columns(db, 'product_question'), contains('slot'));
    expect(columns(db, 'combo_item'), contains('parent_prodnum'));
    expect(columns(db, 'kitchen_ticket_line'), contains('parent_line_no'));
  });

  test('the till remembers what it was doing, from version 5', () {
    final db = openV1();
    addTearDown(db.dispose);

    migrateTabletSchema(db);

    // Without this a drive-thru till boots into the floor plan every morning,
    // because Dine-In sorts first in the imported catalog.
    expect(columns(db, 'device'), contains('active_sale_type'));
  });

  test('an upgraded till forgets its catalog watermark', () {
    final db = openV1();
    addTearDown(db.dispose);
    db.execute("INSERT INTO sync_state (table_name, last_version) "
        "VALUES ('catalog', 4211)");

    migrateTabletSchema(db);

    // The prompts were written to the backend before this build existed, so
    // their server_version is below what this device already pulled. Keeping
    // the watermark would mean an incremental pull skipped every one of them
    // and the upgraded till went on asking nothing, permanently.
    expect(
      db.select("SELECT last_version FROM sync_state "
          "WHERE table_name = 'catalog'").first['last_version'],
      0,
    );
  });

  test('migrating twice is a no-op, not an error', () {
    final db = openV1();
    addTearDown(db.dispose);

    migrateTabletSchema(db);
    expect(migrateTabletSchema(db), isEmpty);
    expect(version(db), tabletSchemaVersion);
  });

  test('a step whose column already exists is skipped', () {
    // A database that got the column some other way — a hand fix, or a
    // partially applied upgrade. The step must not brick it.
    final db = openV1();
    addTearDown(db.dispose);
    db.execute('ALTER TABLE device ADD COLUMN active_empnum INTEGER');

    expect(() => migrateTabletSchema(db), returnsNormally);
    expect(columns(db, 'device'), contains('active_empnum'));
    expect(version(db), tabletSchemaVersion);
  });

  test('data already on the tablet survives the upgrade', () {
    // The point of migrating rather than recreating: a till may be holding
    // sales that have not reached the backend.
    final db = openV1();
    addTearDown(db.dispose);
    db.execute(
      "INSERT INTO device (id, device_uuid, station_no, store_no, "
      "  receipt_prefix, next_receipt_seq) VALUES (1, 'tab-1', 3, 1, 'T09', 42)",
    );
    db.execute("INSERT INTO order_counter (business_date, next_number) "
        "VALUES ('2026-08-06', 137)");

    migrateTabletSchema(db);

    final device = db.select('SELECT * FROM device WHERE id = 1').first;
    expect(device['receipt_prefix'], 'T09');
    expect(device['next_receipt_seq'], 42, reason: 'receipt numbering reset');
    expect(device['active_empnum'], isNull);

    final counter = db.select('SELECT * FROM order_counter').first;
    expect(counter['next_number'], 137);
    // Existing rows get the documented default rather than a null.
    expect(counter['block_end'], 0);
  });

  test('a database from a newer build is refused, not downgraded', () {
    final db = openV1();
    addTearDown(db.dispose);
    db.execute('PRAGMA user_version = 99');

    // An older app writing rows a newer one shaped is silent corruption of
    // sales that may not have synced.
    expect(() => migrateTabletSchema(db), throwsA(isA<TabletSchemaTooNew>()));
  });

  test('a failed step leaves the version untouched', () {
    final db = openV1();
    addTearDown(db.dispose);
    // order_counter is what the first step alters; removing it makes the
    // climb fail part way.
    db.execute('DROP TABLE order_counter');

    expect(() => migrateTabletSchema(db), throwsA(anything));
    expect(version(db), 1, reason: 'a half-migrated tablet must not claim v2');
  });

  test('openFile migrates a real file left by an older build', () async {
    // The end-to-end shape of the bug: an app database that survived an
    // update.
    final dir = await Directory.systemTemp.createTemp('pos-migrate');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/pos.db';

    final old = sqlite3.open(path);
    old.execute(_v1);
    old.execute('PRAGMA user_version = 1');
    old.execute(
      "INSERT INTO device (id, device_uuid, station_no, store_no, "
      "  receipt_prefix) VALUES (1, 'tab-1', 1, 1, 'T01')",
    );
    old.dispose();

    final db = PosDatabase.openFile(path, loadSchema());
    addTearDown(db.dispose);

    // The query that crashed the running app.
    expect(db.activeCashier(), isNull);
    expect(
      db.raw.select('PRAGMA user_version').first.values.first,
      tabletSchemaVersion,
    );
  });

  test('a database already holding tables is never rebuilt', () async {
    // The create script must not run over an existing file. A till destroyed
    // during testing is the reason this is pinned: the file it opened was
    // judged fresh, the script ran, and a database with a day of sales in it
    // would have gone the same way.
    final dir = await Directory.systemTemp.createTemp('pos-notfresh');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/pos.db';

    // Half-built: tables, but not the one the old check looked for.
    final partial = sqlite3.open(path);
    partial.execute('CREATE TABLE sync_state (table_name TEXT PRIMARY KEY, '
        'last_version INTEGER NOT NULL DEFAULT 0, last_pulled_at TEXT)');
    partial.execute("INSERT INTO sync_state (table_name, last_version) "
        "VALUES ('catalog', 99)");
    partial.dispose();

    // It cannot be migrated either — the steps have nothing to alter — but it
    // must fail loudly rather than silently become an empty new database.
    expect(() => PosDatabase.openFile(path, loadSchema()), throwsA(anything));

    final after = sqlite3.open(path);
    addTearDown(after.dispose);
    expect(
      after.select("SELECT last_version FROM sync_state "
          "WHERE table_name = 'catalog'").first['last_version'],
      99,
      reason: 'the existing file was overwritten',
    );
  });

  test('a second app opening the same file does not rebuild it', () async {
    final dir = await Directory.systemTemp.createTemp('pos-second');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/pos.db';

    final first = PosDatabase.openFile(path, loadSchema());
    addTearDown(first.dispose);
    first.raw.execute("INSERT INTO product (prodnum, descript, price_a) "
        "VALUES (2013, 'HUMMOS', 800)");

    // Two copies of the app on one tablet: the second must find the first's
    // database, not replace it.
    final second = PosDatabase.openFile(path, loadSchema());
    addTearDown(second.dispose);

    expect(
      second.raw.select('SELECT COUNT(*) AS n FROM product').first['n'],
      1,
    );
  });

  test('a fresh file is stamped with the current version, not 1', () async {
    final dir = await Directory.systemTemp.createTemp('pos-fresh');
    addTearDown(() => dir.delete(recursive: true));

    final db = PosDatabase.openFile('${dir.path}/pos.db', loadSchema());
    addTearDown(db.dispose);

    // Stamping a new file with 1 would make the next release try to re-apply
    // steps its schema already contains.
    expect(
      db.raw.select('PRAGMA user_version').first.values.first,
      tabletSchemaVersion,
    );
  });
}
