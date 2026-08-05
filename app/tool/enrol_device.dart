/// Enrol an installed device's database from the command line.
///
///     dart run tool/enrol_device.dart <dbPath> <baseUrl> <enrolmentCode>
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

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run tool/enrol_device.dart <dbPath> <baseUrl> <code>',
    );
    exit(2);
  }
  final [dbPath, baseUrl, code] = args;

  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }

  if (!File(dbPath).existsSync()) {
    stderr.writeln('no database at $dbPath - run the app once first, so it '
        'creates one with the current schema');
    exit(1);
  }

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
