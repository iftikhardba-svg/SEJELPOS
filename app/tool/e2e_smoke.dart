/// End-to-end smoke against a REAL running backend.
///
///     dart run tool/e2e_smoke.dart <baseUrl> <enrolmentCode>
///
/// Walks the whole device lifecycle over the wire: enrol with a one-time code,
/// pull the catalog, ring real sales from that catalog, push the outbox.
///
/// It proves the ZATCA gate from BOTH sides, which is the only way to know it
/// is a gate and not a wall:
///
///   * a sale rung before the device holds CSID material is unsigned, and the
///     backend must REJECT it;
///   * the same device, once provisioned, signs on-device and the backend
///     must ACCEPT it.
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
import 'package:pos_app/zatca/device_signer.dart';
import 'package:pos_app/zatca/signing.dart';

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
  final keys = generateKeyPair();
  final db = PosDatabase.openInMemory(
    schema,
    signer: DeviceSigner(keys: InMemoryKeyProvider(keys.privatePem)),
  );
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
    'seller': enrolment.sellerNameAr ?? enrolment.sellerName,
    'seller_vat': enrolment.sellerVat,
  };
  if (enrolment.sellerVat.length != 15) {
    stderr.writeln('enrolment did not deliver a usable seller VAT: $report');
    exit(1);
  }

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

  if (sale.stamp != null) {
    stderr.writeln('a device with no CSID material must not have signed');
    exit(1);
  }

  // 4. Push. The backend must refuse the unsigned sale — that is the ZATCA
  // gate working, not a bug. The outbox must record the refusal.
  final push = await sync.pushOutbox();
  final outbox = db.raw
      .select('SELECT attempts, last_error FROM outbox')
      .map((r) => {'attempts': r['attempts'], 'error': r['last_error']})
      .toList();
  report['push_unsigned'] = {
    'sent': push.sent,
    'failed': push.failed,
    'outbox': outbox,
  };

  final rejectedForZatca = push.sent == 0 &&
      push.failed == 1 &&
      outbox.length == 1 &&
      (outbox.single['error'] as String).contains('ZATCA');
  report['zatca_gate_held'] = rejectedForZatca;

  // 4b. Now provision the device the way CSID onboarding will, ring the same
  // kind of sale, and require the backend to ACCEPT it. Until this passed,
  // "the gate holds" only proved nothing could ever get through.
  //
  // The CSID signature is a placeholder: obtaining a real one needs Fatoora
  // portal credentials. Everything else — the key, the UBL document, the
  // hash chain, the QR — is the production path.
  db.raw.execute(
    'UPDATE device SET zatca_public_key = ?, zatca_csid_signature = ?, '
    '  zatca_egs_serial = ? WHERE id = 1',
    [
      keys.publicKeyBase64,
      base64Encode(utf8.encode('e2e-placeholder-csid-signature')),
      egsSerial('Bufia', 'e2e-smoke', 'e2e-device'),
    ],
  );

  final signedSale = db.completeSale(
    cart: [
      CartLine(product: items.firstWhere((p) => p.prodnum == 2013), qty: 2),
      CartLine(product: items.firstWhere((p) => p.prodnum == 2152), qty: 1),
    ],
    salesType: keeta,
    methodnum: 1010,
    externalRef: 'KEETA-E2E-2',
    orderNo: 2,
  );
  final stamp = signedSale.stamp;
  if (stamp == null) {
    stderr.writeln('a provisioned device failed to sign: $report');
    exit(1);
  }

  final signedPush = await sync.pushOutbox();
  final storedRow = db.saleRow(signedSale.saleUuid);
  report['push_signed'] = {
    'receipt': signedSale.receiptNo,
    'icv': stamp.icv,
    'qr_bytes': base64Decode(stamp.qr).length,
    'sent': signedPush.sent,
    'failed': signedPush.failed,
    'sync_status': storedRow['sync_status'],
  };

  // The flagged unsigned sale must NOT have been retried: same bytes, same
  // rejection, forever. Only the signed one should have moved.
  final acceptedSigned = signedPush.sent == 1 &&
      signedPush.failed == 0 &&
      storedRow['sync_status'] == 'acked' &&
      db.outboxDepth() == 1; // the flagged unsigned row, and only it
  report['zatca_signed_accepted'] = acceptedSigned;

  // 5. Kitchen tickets DO flow — compliance gates sales, not food. Push the
  // ticket this sale cut, read it back from the queue a KDS screen would
  // poll, bump it, and confirm it lands in the done lane a CDS board shows
  // as "Ready".
  final kitchenSent = await sync.pushKitchenTickets();
  final queue = await api.kdsQueue();
  // Assertions are scoped to THIS run's ticket by its uuid — the queue view
  // carries no sale_uuid, and a re-run against a lived-in backend must not
  // trip over earlier tickets.
  // Both sales cut a ticket; assert against the signed one.
  final ourTicketId = db.raw.select(
    'SELECT ticket_uuid FROM kitchen_ticket WHERE sale_uuid = ?',
    [signedSale.saleUuid],
  ).first['ticket_uuid'] as String;

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

  final kitchenFlowed = kitchenSent == 2 &&        // one per sale
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
  if (!acceptedSigned) {
    stderr.writeln('a device-signed sale was not accepted; the gate is a '
        'wall, not a gate');
    exit(1);
  }
  if (!kitchenFlowed) {
    stderr.writeln('kitchen ticket flow did not behave as designed');
    exit(1);
  }
  exit(0);
}
