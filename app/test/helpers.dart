/// Shared test setup.
///
/// On Windows the Dart VM has no sqlite3.dll of its own; the OS ships
/// winsqlite3.dll in System32, which is a current SQLite. On-device builds use
/// sqlite3_flutter_libs instead, so this override is test-only.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

import 'package:pos_app/data/demo_catalog.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/zatca/device_signer.dart';

void useSystemSqlite() {
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }
}

String loadSchema() => File('assets/schema.sql').readAsStringSync();

/// One seed for app and tests: the demo catalog carries the real numbers
/// (HUMMOS 8.00/9.00, station bits 2=Expo 3=Grill 4=Shawarma 5=DT), so every
/// test exercises the same arithmetic the real catalog will.
PosDatabase seededDatabase({DeviceSigner? signer}) {
  final db = PosDatabase.openInMemory(loadSchema(), signer: signer);
  seedDemoCatalog(db);
  return db;
}

/// Ring up one item the way the till does — through the real completeSale
/// transaction, so tests never build sale rows by hand and drift from it.
/// Defaults to HUMMOS on Drive Thru paid by MADA: the most common sale at the
/// first customer.
CompletedSale chargeOneItem(
  PosDatabase db, {
  int prodnum = 2013,
  double qty = 1,
  int saleTypeNo = 2025,
  int methodnum = 1010,
  String methodName = 'MADA',
  int empnum = 0,
}) {
  final salesType = db.salesTypes().firstWhere((t) => t.no == saleTypeNo);
  final product = db
      .productsForScreen(2010)
      .firstWhere((p) => p.prodnum == prodnum);
  return db.completeSale(
    cart: [CartLine(product: product, qty: qty)],
    salesType: salesType,
    payments: [Tender.whole(methodnum: methodnum, name: methodName)],
    empnum: empnum,
  );
}
