/// Sync: the bridge between the local database and the backend.
///
/// Two one-way flows, mirroring the architecture:
///
/// * **Catalog comes down.** The server always wins; the tablet never edits
///   catalog rows. Incremental by watermark, tombstones included, and applying
///   the same response twice changes nothing.
/// * **Sales go up.** The outbox drains oldest-first. `accepted` and
///   `duplicate` both clear the outbox row (a duplicate means the last push
///   made it and the response was lost). A `rejected` sale is NOT retried —
///   it failed validation, retrying cannot fix it — it is flagged for a human
///   and the error stored.
library;

import 'dart:convert';

import '../data/pos_database.dart';
import 'sync_api.dart';

class SyncService {
  SyncService({required this.db, required this.api});

  final PosDatabase db;
  final SyncApi api;

  // ---------------------------------------------------------------- enrol

  /// Redeem the code, persist the credential and identity, pull the catalog.
  /// After this the device is fully operational.
  Future<EnrolmentResult> enrolAndPrime({
    required String code,
    required String deviceUuid,
  }) async {
    final result = await api.enrol(code: code, deviceUuid: deviceUuid);
    // The ZATCA seller identity is stored here and never refreshed by a
    // catalog pull: an invoice already in this device's chain was issued
    // under the identity in force at the time, and rewriting it would make
    // the chain describe invoices that were never issued. A company that
    // re-registers gets a re-enrolled device.
    db.raw.execute(
      'INSERT INTO device (id, device_uuid, station_no, store_no, '
      '  receipt_prefix, role, kds_station_no, api_base_url, auth_token, '
      '  zatca_vat_number, zatca_seller_name, zatca_seller_cr, '
      '  zatca_seller_address) '
      'VALUES (1, ?, 1, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      '  device_uuid=excluded.device_uuid, '
      '  receipt_prefix=excluded.receipt_prefix, '
      '  role=excluded.role, '
      '  kds_station_no=excluded.kds_station_no, '
      '  api_base_url=excluded.api_base_url, '
      '  auth_token=excluded.auth_token, '
      '  zatca_vat_number=excluded.zatca_vat_number, '
      '  zatca_seller_name=excluded.zatca_seller_name, '
      '  zatca_seller_cr=excluded.zatca_seller_cr, '
      '  zatca_seller_address=excluded.zatca_seller_address',
      [
        deviceUuid, result.receiptPrefix, result.role,
        result.kdsStationNo, api.baseUrl, result.token,
        result.sellerVat,
        // ZATCA wants the Arabic registered name on the invoice; the Latin
        // one is the fallback when a company has not supplied it.
        result.sellerNameAr ?? result.sellerName,
        result.sellerCr,
        jsonEncode(result.sellerAddress),
      ],
    );
    await pullCatalog();
    return result;
  }

  // -------------------------------------------------------------- catalog

  int catalogWatermark() {
    final rows = db.raw.select(
      "SELECT last_version FROM sync_state WHERE table_name = 'catalog'",
    );
    return rows.isEmpty ? 0 : rows.first['last_version'] as int;
  }

  Future<int> pullCatalog() async {
    final since = catalogWatermark();
    final body = await api.getCatalog(since: since);
    applyCatalog(body);
    return body['version'] as int;
  }

  /// Apply one catalog response. Idempotent: upserts on business keys, the
  /// same ones the migration loader uses.
  void applyCatalog(Map<String, dynamic> body) {
    final raw = db.raw;
    raw.execute('BEGIN');
    try {
      for (final p in _list(body['products'])) {
        raw.execute(
          'INSERT INTO product (prodnum, descript, descript_ar, print_des, '
          '  price_a, price_b, price_c, price_d, price_e, price_f, '
          '  price_g, price_h, price_i, price_j, prodtype, tax_applies, '
          '  is_weighed, manual_price, is_modifier, print_loc, ref_code, '
          '  unit_des, is_active, server_version, is_deleted) '
          'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(prodnum) DO UPDATE SET '
          '  descript=excluded.descript, descript_ar=excluded.descript_ar, '
          '  print_des=excluded.print_des, '
          '  price_a=excluded.price_a, price_b=excluded.price_b, '
          '  price_c=excluded.price_c, price_d=excluded.price_d, '
          '  price_e=excluded.price_e, price_f=excluded.price_f, '
          '  price_g=excluded.price_g, price_h=excluded.price_h, '
          '  price_i=excluded.price_i, price_j=excluded.price_j, '
          '  prodtype=excluded.prodtype, tax_applies=excluded.tax_applies, '
          '  is_weighed=excluded.is_weighed, '
          '  manual_price=excluded.manual_price, '
          '  is_modifier=excluded.is_modifier, print_loc=excluded.print_loc, '
          '  ref_code=excluded.ref_code, unit_des=excluded.unit_des, '
          '  is_active=excluded.is_active, '
          '  server_version=excluded.server_version, '
          '  is_deleted=excluded.is_deleted',
          [
            p['prodnum'], p['descript'], p['descript_ar'], p['print_des'],
            p['price_a'], p['price_b'], p['price_c'], p['price_d'],
            p['price_e'], p['price_f'], p['price_g'], p['price_h'],
            p['price_i'], p['price_j'], p['prodtype'],
            _b(p['tax_applies']), _b(p['is_weighed']),
            _b(p['manual_price']), _b(p['is_modifier']),
            p['print_loc'] ?? 0, p['ref_code'], p['unit_des'],
            _b(p['is_active']), p['server_version'], _b(p['is_deleted']),
          ],
        );
      }

      for (final s in _list(body['menu_screens'])) {
        raw.execute(
          'INSERT INTO menu_screen (menu_id, name, name_ar, sort_order, '
          '  buttons_across, buttons_down, is_modifier_screen, is_active, '
          '  server_version, is_deleted) '
          'VALUES (?,?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(menu_id) DO UPDATE SET '
          '  name=excluded.name, name_ar=excluded.name_ar, '
          '  sort_order=excluded.sort_order, '
          '  buttons_across=excluded.buttons_across, '
          '  buttons_down=excluded.buttons_down, '
          '  is_modifier_screen=excluded.is_modifier_screen, '
          '  is_active=excluded.is_active, '
          '  server_version=excluded.server_version, '
          '  is_deleted=excluded.is_deleted',
          [
            s['menu_id'], s['name'], s['name_ar'], s['sort_order'] ?? 0,
            s['buttons_across'], s['buttons_down'],
            _b(s['is_modifier_screen']), _b(s['is_active']),
            s['server_version'], _b(s['is_deleted']),
          ],
        );
      }

      for (final b in _list(body['menu_buttons'])) {
        raw.execute(
          'INSERT INTO menu_button (id, menu_id, prodnum, position, pos_x, '
          '  pos_y, caption, is_active, server_version, is_deleted) '
          'VALUES (?,?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(id) DO UPDATE SET '
          '  menu_id=excluded.menu_id, prodnum=excluded.prodnum, '
          '  position=excluded.position, pos_x=excluded.pos_x, '
          '  pos_y=excluded.pos_y, caption=excluded.caption, '
          '  is_active=excluded.is_active, '
          '  server_version=excluded.server_version, '
          '  is_deleted=excluded.is_deleted',
          [
            b['id'], b['menu_id'], b['prodnum'], b['position'] ?? 0,
            b['pos_x'], b['pos_y'], b['caption'], _b(b['is_active']),
            b['server_version'], _b(b['is_deleted']),
          ],
        );
      }

      for (final m in _list(body['pay_methods'])) {
        raw.execute(
          'INSERT INTO pay_method (methodnum, descript, descript_ar, '
          '  is_cash, opens_drawer, sort_order, is_active, server_version, '
          '  is_deleted) VALUES (?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(methodnum) DO UPDATE SET '
          '  descript=excluded.descript, descript_ar=excluded.descript_ar, '
          '  is_cash=excluded.is_cash, opens_drawer=excluded.opens_drawer, '
          '  sort_order=excluded.sort_order, is_active=excluded.is_active, '
          '  server_version=excluded.server_version, '
          '  is_deleted=excluded.is_deleted',
          [
            m['methodnum'], m['descript'], m['descript_ar'],
            _b(m['is_cash']), _b(m['opens_drawer']), m['sort_order'] ?? 0,
            _b(m['is_active']), m['server_version'], _b(m['is_deleted']),
          ],
        );
      }

      for (final e in _list(body['staff'])) {
        // pin_hash is deliberately never overwritten from the catalog: a
        // catalog refresh must not wipe PINs staff set on the device.
        raw.execute(
          'INSERT INTO employee (empnum, name, pin_hash, must_set_pin, '
          '  sec_level, ref_code, is_active, server_version, is_deleted) '
          'VALUES (?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(empnum) DO UPDATE SET '
          '  name=excluded.name, sec_level=excluded.sec_level, '
          '  ref_code=excluded.ref_code, is_active=excluded.is_active, '
          '  server_version=excluded.server_version, '
          '  is_deleted=excluded.is_deleted',
          [
            e['empnum'], e['name'], null, 1,
            e['sec_level'] ?? 0, e['ref_code'],
            _b(e['is_active']), e['server_version'], _b(e['is_deleted']),
          ],
        );
      }

      for (final t in _list(body['tax_rates'])) {
        raw.execute(
          'INSERT INTO tax_rate (tax_id, name, percent, is_inclusive, '
          '  server_version) VALUES (?,?,?,?,?) '
          'ON CONFLICT(tax_id) DO UPDATE SET '
          '  name=excluded.name, percent=excluded.percent, '
          '  is_inclusive=excluded.is_inclusive, '
          '  server_version=excluded.server_version',
          [
            t['tax_id'], t['name'], t['percent'],
            _b(t['is_inclusive']), t['server_version'],
          ],
        );
      }

      for (final s in _list(body['sales_types'])) {
        raw.execute(
          'INSERT INTO sales_type (sale_type_no, descript, descript_ar, '
          '  price_tier, is_aggregator, requires_external_ref, needs_table, '
          '  default_methodnum, sort_order, is_active, server_version, '
          '  is_deleted) VALUES (?,?,?,?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(sale_type_no) DO UPDATE SET '
          '  descript=excluded.descript, descript_ar=excluded.descript_ar, '
          '  price_tier=excluded.price_tier, '
          '  is_aggregator=excluded.is_aggregator, '
          '  requires_external_ref=excluded.requires_external_ref, '
          '  needs_table=excluded.needs_table, '
          '  default_methodnum=excluded.default_methodnum, '
          '  sort_order=excluded.sort_order, is_active=excluded.is_active, '
          '  server_version=excluded.server_version, '
          '  is_deleted=excluded.is_deleted',
          [
            s['sale_type_no'], s['descript'], s['descript_ar'],
            s['price_tier'], _b(s['is_aggregator']),
            _b(s['requires_external_ref']), _b(s['needs_table']),
            s['default_methodnum'], s['sort_order'] ?? 0,
            _b(s['is_active']), s['server_version'], _b(s['is_deleted']),
          ],
        );
      }

      for (final k in _list(body['kitchen_stations'])) {
        raw.execute(
          'INSERT INTO kitchen_station (station_no, name, name_ar, '
          '  sort_order, is_active, server_version, is_deleted) '
          'VALUES (?,?,?,?,?,?,?) '
          'ON CONFLICT(station_no) DO UPDATE SET '
          '  name=excluded.name, name_ar=excluded.name_ar, '
          '  sort_order=excluded.sort_order, is_active=excluded.is_active, '
          '  server_version=excluded.server_version, '
          '  is_deleted=excluded.is_deleted',
          [
            k['station_no'], k['name'], k['name_ar'], k['sort_order'] ?? 0,
            _b(k['is_active']), k['server_version'], _b(k['is_deleted']),
          ],
        );
      }

      raw.execute(
        "INSERT INTO sync_state (table_name, last_version, last_pulled_at) "
        "VALUES ('catalog', ?, ?) "
        'ON CONFLICT(table_name) DO UPDATE SET '
        '  last_version=excluded.last_version, '
        '  last_pulled_at=excluded.last_pulled_at',
        [body['version'], DateTime.now().toUtc().toIso8601String()],
      );

      raw.execute('COMMIT');
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  // ---------------------------------------------------------------- sales

  /// The exact SaleIn shape `POST /v1/sales` validates. Built from stored
  /// rows, not from UI state — what syncs is what was recorded.
  Map<String, dynamic> buildSalePayload(String saleUuid) {
    final s = db.saleRow(saleUuid);
    final lines = db.saleLines(saleUuid);
    final payments = db.raw.select(
      'SELECT * FROM sale_payment WHERE sale_uuid = ?', [saleUuid],
    );
    return {
      'sale_uuid': s['sale_uuid'],
      'receipt_no': s['receipt_no'],
      'opened_at': s['opened_at'],
      'closed_at': s['closed_at'],
      'business_date': s['business_date'],
      'table_no': s['table_no'],
      'num_guests': s['num_guests'] ?? 1,
      'sale_type': s['sale_type'],
      'order_no': s['order_no'],
      'external_ref': s['external_ref'],
      'net_total': s['net_total'],
      'tax_total': s['tax_total'],
      'final_total': s['final_total'],
      'status': s['status'],
      'zatca_uuid': s['zatca_uuid'],
      'zatca_icv': s['zatca_icv'],
      'zatca_pih': s['zatca_pih'],
      'zatca_hash': s['zatca_hash'],
      'zatca_qr': s['zatca_qr'],
      'lines': [
        for (final l in lines)
          {
            'line_uuid': l['line_uuid'],
            'line_no': l['line_no'],
            'prodnum': l['prodnum'],
            'line_des': l['line_des'],
            'qty': l['qty'],
            'unit_price': l['unit_price'],
            'discount': l['discount'] ?? 0,
            'net_amount': l['net_amount'],
            'tax_amount': l['tax_amount'],
            'line_total': l['line_total'],
            'seat_no': l['seat_no'],
            'voided': (l['voided'] as int? ?? 0) != 0,
          },
      ],
      'payments': [
        for (final p in payments)
          {
            'payment_uuid': p['payment_uuid'],
            'methodnum': p['methodnum'],
            'tender': p['tender'],
            'change_given': p['change_given'] ?? 0,
            'amount': p['amount'],
            'auth_code': p['auth_code'],
            'card_type': p['card_type'],
            'paid_at': p['paid_at'],
            'voided': (p['voided'] as int? ?? 0) != 0,
          },
      ],
    };
  }

  /// Push pending kitchen tickets to the backend, where KDS and CDS screens
  /// read them. Runs before the sales push — the kitchen is waiting on these;
  /// bookkeeping is not.
  Future<int> pushKitchenTickets() async {
    final tickets = db.raw.select(
      "SELECT * FROM kitchen_ticket WHERE sync_status = 'pending' "
      'ORDER BY created_at',
    );
    var sent = 0;
    for (final t in tickets) {
      final ticketUuid = t['ticket_uuid'] as String;
      final lines = db.raw.select(
        'SELECT * FROM kitchen_ticket_line WHERE ticket_uuid = ? '
        'ORDER BY line_no',
        [ticketUuid],
      );
      await api.createKdsTicket({
        'ticket_id': ticketUuid,
        'order_no': t['order_no'],
        'sale_type_no': t['sale_type_no'],
        'sale_type_name': t['sale_type_name'],
        'table_no': t['table_no'],
        'external_ref': t['external_ref'],
        'sale_uuid': t['sale_uuid'],
        'session_id': t['session_uuid'],
        'created_at': t['created_at'],
        'lines': [
          for (final l in lines)
            {
              'line_no': l['line_no'],
              'prodnum': l['prodnum'],
              'line_des': l['line_des'],
              'qty': l['qty'],
              'station_no': l['station_no'],
              'note': l['note'],
              'seat_no': l['seat_no'],
            },
        ],
      });
      db.raw.execute(
        "UPDATE kitchen_ticket SET sync_status = 'sent' "
        'WHERE ticket_uuid = ?',
        [ticketUuid],
      );
      sent += 1;
    }
    return sent;
  }

  /// Drain the outbox. Returns (sent, flaggedAsFailed).
  ///
  /// Rows already flagged with a `last_error` are skipped, not retried: the
  /// backend rejected those bytes on validation and the same bytes fail the
  /// same way forever. Without this filter every sync cycle would re-push
  /// every permanently-dead sale for the life of the device.
  Future<({int sent, int failed})> pushOutbox() async {
    final rows = db.raw.select(
      "SELECT id, entity_uuid FROM outbox WHERE entity = 'sale' "
      '  AND last_error IS NULL '
      'ORDER BY id',
    );
    var sent = 0;
    var failed = 0;

    for (final row in rows) {
      final saleUuid = row['entity_uuid'] as String;
      final result = await api.pushSales([buildSalePayload(saleUuid)]);

      final accepted = result.accepted
          .any((a) => a['sale_uuid'] == saleUuid);
      if (accepted) {
        db.raw.execute('DELETE FROM outbox WHERE id = ?', [row['id']]);
        db.raw.execute(
          "UPDATE sale SET sync_status = 'acked' WHERE sale_uuid = ?",
          [saleUuid],
        );
        sent += 1;
        continue;
      }

      final rejection = result.rejected.firstWhere(
        (r) => r['sale_uuid'] == saleUuid,
        orElse: () => {'error': 'backend gave no verdict for this sale'},
      );
      // Validation failures are not retried — the same bytes fail the same
      // way forever. Flag for a human, keep the sale, move on so one poison
      // record cannot stall the queue behind it.
      db.raw.execute(
        'UPDATE outbox SET attempts = attempts + 1, last_error = ? '
        'WHERE id = ?',
        [jsonEncode(rejection), row['id']],
      );
      db.raw.execute(
        "UPDATE sale SET sync_status = 'failed' WHERE sale_uuid = ?",
        [saleUuid],
      );
      failed += 1;
    }
    return (sent: sent, failed: failed);
  }

  // -------------------------------------------------------------- helpers

  static List<Map<String, dynamic>> _list(Object? v) => [
        for (final e in (v as List? ?? const []))
          (e as Map).cast<String, dynamic>(),
      ];

  static int _b(Object? v) =>
      v == true || v == 1 ? 1 : 0; // backend sends real booleans
}
