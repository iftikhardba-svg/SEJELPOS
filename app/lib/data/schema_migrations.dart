/// Moving an installed tablet's database forward.
///
/// `assets/schema.sql` is a CREATE script: it builds a database from nothing.
/// That is all a device needed on its first run, and for a while it was all
/// this code did — so every schema change shipped in an app update simply
/// broke every till already in service, which would open its old database,
/// find a column missing and fail on the first query. In development the file
/// gets deleted; a restaurant cannot do that to a till mid-shift.
///
/// `PRAGMA user_version` records which schema built the file. On open, each
/// step above that number runs in order, inside one transaction, and the
/// version is stamped forward.
///
/// Rules for adding a step:
///
/// * Bump [tabletSchemaVersion] and add the entry. Never edit a released one —
///   a device that already ran it will not run it again.
/// * Additive changes only where possible. A tablet may be holding sales that
///   have not reached the backend yet, so a step that drops or rewrites a
///   table can destroy the only copy of a day's takings.
/// * Steps must tolerate being run against a database that has already had
///   the change applied by other means; [_addColumn] checks first, because
///   SQLite has no `ADD COLUMN IF NOT EXISTS`.
library;

import 'package:sqlite3/sqlite3.dart';

/// What `assets/schema.sql` currently creates.
const int tabletSchemaVersion = 7;

/// version -> the statements that lift a database TO that version.
const Map<int, List<String>> _steps = {
  // Order numbers stopped being counted locally and started being reserved
  // from the backend in blocks; the till learned who is standing at it.
  2: [
    'ALTER TABLE order_counter ADD COLUMN block_end INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE device ADD COLUMN active_empnum INTEGER '
        'REFERENCES employee(empnum)',
  ],
  // The menu a till lands on, and the look of the buttons on it. Until this
  // the till showed a flat strip of every page in alphabetical order, in one
  // colour — not the menu staff had learned.
  3: [
    'ALTER TABLE product ADD COLUMN button_text TEXT',
    'ALTER TABLE product ADD COLUMN fore_color TEXT',
    'ALTER TABLE product ADD COLUMN back_color TEXT',
    'ALTER TABLE menu_screen ADD COLUMN fore_color TEXT',
    'ALTER TABLE menu_screen ADD COLUMN back_color TEXT',
    '''
    CREATE TABLE IF NOT EXISTS menu (
        menu_no        INTEGER PRIMARY KEY,
        name           TEXT NOT NULL,
        name_ar        TEXT,
        is_active      INTEGER NOT NULL DEFAULT 1,
        server_version INTEGER NOT NULL DEFAULT 0,
        is_deleted     INTEGER NOT NULL DEFAULT 0
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS menu_page (
        id             TEXT PRIMARY KEY,
        menu_no        INTEGER NOT NULL,
        screen_no      INTEGER NOT NULL,
        pos_x          INTEGER,
        pos_y          INTEGER,
        sort_order     INTEGER NOT NULL DEFAULT 0,
        is_active      INTEGER NOT NULL DEFAULT 1,
        server_version INTEGER NOT NULL DEFAULT 0,
        is_deleted     INTEGER NOT NULL DEFAULT 0,
        UNIQUE (menu_no, screen_no)
    )
    ''',
    'CREATE INDEX IF NOT EXISTS ix_menu_page_menu '
        'ON menu_page(menu_no, pos_y, pos_x)',
  ],
  // Meal deals: what the till asks before an item can be rung, and what a
  // combo always includes. Before this a meal rang with nothing chosen and
  // the kitchen was told to make an empty box.
  4: [
    '''
    CREATE TABLE IF NOT EXISTS question (
        question_no    INTEGER PRIMARY KEY,
        prompt         TEXT NOT NULL,
        prompt_ar      TEXT,
        is_required    INTEGER NOT NULL DEFAULT 1,
        pick_count     INTEGER NOT NULL DEFAULT 1,
        allow_repeats  INTEGER NOT NULL DEFAULT 0,
        free_choices   INTEGER NOT NULL DEFAULT 0,
        is_active      INTEGER NOT NULL DEFAULT 1,
        server_version INTEGER NOT NULL DEFAULT 0,
        is_deleted     INTEGER NOT NULL DEFAULT 0
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS question_choice (
        id             TEXT PRIMARY KEY,
        question_no    INTEGER NOT NULL,
        prodnum        INTEGER NOT NULL,
        sort_order     INTEGER NOT NULL DEFAULT 0,
        price_mode     INTEGER NOT NULL DEFAULT 0,
        fixed_price    INTEGER,
        default_qty    INTEGER NOT NULL DEFAULT 1,
        is_active      INTEGER NOT NULL DEFAULT 1,
        server_version INTEGER NOT NULL DEFAULT 0,
        is_deleted     INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX IF NOT EXISTS ix_question_choice_q '
        'ON question_choice(question_no, sort_order)',
    '''
    CREATE TABLE IF NOT EXISTS product_question (
        id             TEXT PRIMARY KEY,
        prodnum        INTEGER NOT NULL,
        question_no    INTEGER NOT NULL,
        slot           INTEGER NOT NULL,
        server_version INTEGER NOT NULL DEFAULT 0,
        is_deleted     INTEGER NOT NULL DEFAULT 0,
        UNIQUE (prodnum, slot)
    )
    ''',
    'CREATE INDEX IF NOT EXISTS ix_product_question_prod '
        'ON product_question(prodnum, slot)',
    '''
    CREATE TABLE IF NOT EXISTS combo_item (
        id             TEXT PRIMARY KEY,
        parent_prodnum INTEGER NOT NULL,
        prodnum        INTEGER NOT NULL,
        sort_order     INTEGER NOT NULL DEFAULT 0,
        price_mode     INTEGER NOT NULL DEFAULT 0,
        fixed_price    INTEGER,
        print_it       INTEGER NOT NULL DEFAULT 1,
        is_active      INTEGER NOT NULL DEFAULT 1,
        server_version INTEGER NOT NULL DEFAULT 0,
        is_deleted     INTEGER NOT NULL DEFAULT 0
    )
    ''',
    'CREATE INDEX IF NOT EXISTS ix_combo_item_parent '
        'ON combo_item(parent_prodnum, sort_order)',
    'ALTER TABLE kitchen_ticket_line ADD COLUMN parent_line_no INTEGER',
    // Forget the catalog watermark: the rows for these tables were written
    // long before this build existed, so their server_version is BELOW what
    // this device has already pulled and an incremental pull would skip every
    // one of them — the till would upgrade and still ask nothing, for good.
    // Re-pulling the whole catalog is free; every apply is an upsert.
    "UPDATE sync_state SET last_version = 0 WHERE table_name = 'catalog'",
  ],
  // The till remembers what it was doing. Without this every restart lands on
  // whichever sale type sorts first — Dine-In in this catalog — so a drive-thru
  // till booted into the floor plan and a waiter's tablet booted into
  // drive-thru.
  5: [
    'ALTER TABLE device ADD COLUMN active_sale_type INTEGER',
  ],
  // A picture on the button. Its own table, not a column on product, for the
  // same reason it is one on the server: a product row is read on every
  // repaint of the menu and an image is a thousand times its size.
  6: [
    '''
    CREATE TABLE IF NOT EXISTS product_image (
        prodnum        INTEGER PRIMARY KEY,
        mime           TEXT NOT NULL,
        data           BLOB NOT NULL,
        width          INTEGER NOT NULL DEFAULT 0,
        height         INTEGER NOT NULL DEFAULT 0,
        byte_size      INTEGER NOT NULL DEFAULT 0,
        server_version INTEGER NOT NULL DEFAULT 0,
        is_deleted     INTEGER NOT NULL DEFAULT 0
    )
    ''',
    // Same trap as the prompts at v4: any picture uploaded before this build
    // shipped carries a server_version BELOW an installed till's watermark,
    // so an incremental pull would skip every one of them and the tiles would
    // stay blank for good. Re-pulling is free — every apply is an upsert.
    "UPDATE sync_state SET last_version = 0 WHERE table_name = 'catalog'",
  ],
  // Whose restaurant this is. The till used to have the first customer's
  // branch compiled into it, which every other tenant would have read as
  // somebody else's name across the top of their screen. Null until the
  // device re-enrols, and the header falls back to the seller name.
  7: [
    'ALTER TABLE device ADD COLUMN branch_name TEXT',
  ],
};

class TabletSchemaTooNew implements Exception {
  TabletSchemaTooNew(this.found, this.expected);

  final int found;
  final int expected;

  @override
  String toString() =>
      'this database was written by schema version $found but this build '
      'only knows $expected — install the newer app rather than letting an '
      'older one write to it';
}

/// Bring [db] up to [tabletSchemaVersion]. Returns the versions applied.
List<int> migrateTabletSchema(Database db) {
  final from = db.select('PRAGMA user_version').first.values.first as int;

  if (from > tabletSchemaVersion) {
    // Downgrading would mean an older build writing rows a newer one shaped.
    // Refusing is the only safe answer: the alternative is silent corruption
    // of sales that have not synced yet.
    throw TabletSchemaTooNew(from, tabletSchemaVersion);
  }
  if (from == tabletSchemaVersion) return const [];

  final applied = <int>[];
  // One transaction for the whole climb: a half-migrated database on a till
  // is worse than an unmigrated one, because nothing downstream expects it.
  db.execute('BEGIN');
  try {
    for (var version = from + 1; version <= tabletSchemaVersion; version++) {
      for (final statement in _steps[version] ?? const <String>[]) {
        _run(db, statement);
      }
      applied.add(version);
    }
    // PRAGMA does not take a bind parameter, and the value is an int we
    // control, never anything from outside.
    db.execute('PRAGMA user_version = $tabletSchemaVersion');
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
  return applied;
}

/// Runs one migration statement, skipping an ADD COLUMN whose column is
/// already there. SQLite has no `IF NOT EXISTS` for that, and a step that
/// cannot be re-run turns a partially-upgraded database into a brick.
void _run(Database db, String statement) {
  final add = RegExp(
    r'ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)',
    caseSensitive: false,
  ).firstMatch(statement);

  if (add != null) {
    final table = add.group(1)!;
    final column = add.group(2)!;
    final existing = db
        .select('PRAGMA table_info($table)')
        .map((r) => r['name'] as String);
    if (existing.contains(column)) return;
  }

  db.execute(statement);
}
