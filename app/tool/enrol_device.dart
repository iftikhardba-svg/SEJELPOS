/// Enrol an installed device's database from the command line.
///
///     dart run tool/enrol_device.dart <baseUrl> <enrolmentCode>
///     dart run tool/enrol_device.dart <baseUrl> <code> <dbPath>
///
/// The database path is optional and defaults to where the app actually puts
/// it. That default exists because the path is the easy thing to get wrong:
/// `%APPDATA%` is cmd syntax and does not expand in PowerShell, so pasting it
/// hands this tool a literal string and it reports a missing database.
///
/// Runs the same `SyncService.enrolAndPrime` the setup screen calls, against
/// the real on-disk database the app opens - so it is the app's own code path,
/// not a reimplementation of it.
///
/// Two uses: bringing a device up without touching the tablet's keyboard, and
/// support - when a till will not enrol, running this shows the actual error
/// instead of whatever the screen had room to display.
///
/// The app must not be running: SQLite allows concurrent connections, but the
/// app caches the device row in memory at boot and would not see this.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:uuid/uuid.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/sync/sync_service.dart';

/// Where the app's own `getApplicationSupportDirectory` lands on each
/// platform, for the bundle id in the runner.
String? _defaultDbPath() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    return '$appData\\sa.pos\\pos_app\\pos.db';
  }
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  if (Platform.isMacOS) {
    return '$home/Library/Application Support/sa.pos.pos_app/pos.db';
  }
  return '$home/.local/share/sa.pos.pos_app/pos.db';
}

Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'usage: dart run tool/enrol_device.dart <baseUrl> <code> [dbPath]',
    );
    exit(2);
  }
  final baseUrl = args[0];
  final code = args[1];
  final dbPath = args.length == 3 ? args[2] : _defaultDbPath();

  if (dbPath == null) {
    stderr.writeln('could not work out where the app keeps its database; '
        'pass the path as the third argument');
    exit(2);
  }

  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }

  if (!File(dbPath).existsSync()) {
    stderr.writeln('no database at $dbPath\n'
        'Run the app once first so it creates one with the current schema. '
        'If you passed the path yourself, note that %APPDATA% is cmd syntax '
        'and does not expand in PowerShell - use \$env:APPDATA, or leave the '
        'argument off entirely.');
    exit(1);
  }

  stdout.writeln('database: $dbPath');

  final schema = File('assets/schema.sql').readAsStringSync();
  final db = PosDatabase.openFile(dbPath, schema);
  final api = SyncApi(baseUrl: baseUrl);
  final sync = SyncService(db: db, api: api);

  try {
    final result = await sync.enrolAndPrime(
      code: code,
      deviceUuid: 'device-${const Uuid().v4()}',
    );
    final screens = db.menuScreens();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'branch': result.branchName,
      'role': result.role,
      'receipt_prefix': result.receiptPrefix,
      'mode': result.tenantMode,
      'seller': result.sellerNameAr ?? result.sellerName,
      'seller_vat': result.sellerVat,
      'catalog': {
        'screens': screens.length,
        'products': [
          for (final s in screens) db.productsForScreen(s.menuId).length,
        ].fold<int>(0, (a, b) => a + b),
        'sales_types': db.salesTypes().length,
        'kitchen_stations': db.kitchenStations().length,
        'watermark': sync.catalogWatermark(),
      },
    }));
  } on SyncApiException catch (e) {
    stderr.writeln('backend refused the enrolment: $e');
    exit(1);
  } finally {
    db.dispose();
  }
}
