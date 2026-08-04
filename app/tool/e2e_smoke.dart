/// End-to-end smoke against a REAL running backend.
///
///     dart run tool/e2e_smoke.dart <baseUrl> <enrolmentCode>
///
/// Walks the whole device lifecycle over the wire: enrol with a one-time code,
/// pull the catalog, ring a real sale from that catalog, push the outbox.
/// The push is EXPECTED to be rejected — the app cannot sign invoices until
/// the ZATCA port lands, and the backend refuses unsigned closed sales. That
/// rejection is the compliance gate doing its job, and this script treats it
/// as the passing outcome.
///
/// Exits 0 only if every step behaves exactly as designed.
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
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/e2e_smoke.dart <baseUrl> <code>');
    exit(2);
  }
  final [baseUrl, code] = args;

  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }

  final schema = File('assets/schema.sql').readAsStringSync();
  final db = PosDatabase.openInMemory(schema);
  final api = SyncApi(baseUrl: baseUrl);
  final sync = SyncService(db: db, api: api);
  final report = <String, Object?>{};

  // 1. Enrol — the tablet becomes a device.
  final enrolment = await sync.enrolAndPrime(
    code: code,
    deviceUuid: 'e2e-${const Uuid().v4()}',
  );
  report['enrolled'] = {
    'branch': enrolment.branchName,
    'receipt_prefix': enrolment.receiptPrefix,
    'mode': enrolment.tenantMode,
  };

  // 2. The catalog actually landed.
  final screens = db.menuScreens();
  final items = db.productsForScreen(screens.first.menuId);
  final stations = db.kitchenStations();
  report['catalog'] = {
    'screens': screens.length,
    'products': items.length,
    'stations': stations.map((no, name) => MapEntry('$no', name)),
    'watermark': sync.catalogWatermark(),
  };
  if (items.isEmpty || stations.isEmpty) {
    stderr.writeln('catalog pull came back empty: $report');
    exit(1);
  }

  // 3. Ring a real sale from the synced catalog on the aggregator tier.
  final keeta = db.salesTypes().firstWhere((t) => t.no == 2004);
  final sale = db.completeSale(
    cart: [
      CartLine(
          product: items.firstWhere((p) => p.prodnum == 2013), qty: 2),
      CartLine(
          product: items.firstWhere((p) => p.prodnum == 2152), qty: 1),
    ],
    salesType: keeta,
    methodnum: 1010,
    externalRef: 'KEETA-E2E-1',
    orderNo: 1,
  );
  report['sale'] = {
    'receipt': sale.receiptNo,
    'total': sale.finalTotal,
    'kitchen': sale.kitchenStations,
  };
  // Tier B: 2x900 + 2900 = 4700.
  if (sale.finalTotal != 4700) {
    stderr.writeln('tier B pricing wrong over the wire: $report');
    exit(1);
  }

  // 4. Push. The backend must refuse the unsigned sale — that is the ZATCA
  // gate working, not a bug. The outbox must record the refusal.
  final push = await sync.pushOutbox();
  final outbox = db.raw
      .select('SELECT attempts, last_error FROM outbox')
      .map((r) => {'attempts': r['attempts'], 'error': r['last_error']})
      .toList();
  report['push'] = {
    'sent': push.sent,
    'failed': push.failed,
    'outbox': outbox,
  };

  final rejectedForZatca = push.sent == 0 &&
      push.failed == 1 &&
      outbox.length == 1 &&
      (outbox.single['error'] as String).contains('ZATCA');
  report['zatca_gate_held'] = rejectedForZatca;

  // 5. Kitchen tickets DO flow — compliance gates sales, not food. Push the
  // ticket this sale cut, read it back from the queue a KDS screen would
  // poll, bump it, and confirm it lands in the done lane a CDS board shows
  // as "Ready".
  final kitchenSent = await sync.pushKitchenTickets();
  final queue = await api.kdsQueue();
  // Assertions are scoped to THIS run's ticket by its uuid — the queue view
  // carries no sale_uuid, and a re-run against a lived-in backend must not
  // trip over earlier tickets.
  final ourTicketId = db.raw
      .select('SELECT ticket_uuid FROM kitchen_ticket')
      .first['ticket_uuid'] as String;

  final openTickets = (queue['open'] as List).cast<Map<String, dynamic>>();
  final ticket = openTickets.firstWhere(
    (t) => t['id'] == ourTicketId,
    orElse: () => {},
  );
  if (ticket.isEmpty) {
    stderr.writeln('our ticket never appeared on the kitchen queue: $report');
    exit(1);
  }

  final grillOnly = await api.kdsQueue(station: 3);
  final grillLinesOfOurs = [
    for (final t in (grillOnly['open'] as List))
      if ((t as Map)['id'] == ourTicketId) ...(t['lines'] as List),
  ];

  await api.kdsBump(ourTicketId);
  final after = await api.kdsQueue();
  final stillOpen =
      (after['open'] as List).any((t) => (t as Map)['id'] == ourTicketId);
  final nowReady =
      (after['done'] as List).any((t) => (t as Map)['id'] == ourTicketId);

  report['kitchen'] = {
    'pushed': kitchenSent,
    'ticket_lines': (ticket['lines'] as List).length,
    'grill_station_lines': grillLinesOfOurs.length,
    'open_after_bump': stillOpen,
    'ready_after_bump': nowReady,
  };

  final kitchenFlowed = kitchenSent == 1 &&
      (ticket['lines'] as List).length == 2 &&      // Grill + DT
      grillLinesOfOurs.length == 1 &&               // station filter works
      !stillOpen &&
      nowReady;
  report['kitchen_flow_proven'] = kitchenFlowed;

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  if (!rejectedForZatca) {
    stderr.writeln('expected the unsigned sale to be rejected by the '
        'ZATCA gate; something else happened');
    exit(1);
  }
  if (!kitchenFlowed) {
    stderr.writeln('kitchen ticket flow did not behave as designed');
    exit(1);
  }
  exit(0);
}
