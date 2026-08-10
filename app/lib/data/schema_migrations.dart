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
const int tabletSchemaVersion = 3;

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
