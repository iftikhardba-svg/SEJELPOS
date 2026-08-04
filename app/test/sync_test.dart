/// Sync client tests: the wire contract with the backend.
///
/// The catalog fixtures here are shaped exactly like `CatalogResponse` in
/// backend/app/schemas.py (real booleans, server_version watermarks), and the
/// sale payload test asserts the exact `SaleIn` reconciliation rules the
/// backend enforces at ingest.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/sync/sync_service.dart';

import 'helpers.dart';

Map<String, dynamic> catalogFixture({int version = 7}) => {
      'version': version,
      'has_more': false,
      'products': [
        {
          'prodnum': 2013, 'descript': 'HUMMOS', 'print_des': null,
          'price_a': 800, 'price_b': 900, 'price_c': null, 'price_d': null,
          'price_e': null, 'price_f': null, 'price_g': null, 'price_h': null,
          'price_i': null, 'price_j': 0, 'prodtype': 0,
          'tax_applies': true, 'is_weighed': false, 'manual_price': false,
          'is_modifier': false, 'print_loc': 0, 'ref_code': null,
          'unit_des': null, 'is_active': true, 'server_version': 7,
          'is_deleted': false,
        },
        {
          'prodnum': 2152, 'descript': 'Hummos Lahm', 'print_des': null,
          'price_a': 2400, 'price_b': 2900, 'price_c': null, 'price_d': null,
          'price_e': null, 'price_f': null, 'price_g': null, 'price_h': null,
          'price_i': null, 'price_j': 0, 'prodtype': 0,
          'tax_applies': true, 'is_weighed': false, 'manual_price': false,
          'is_modifier': false, 'print_loc': 40, 'ref_code': null,
          'unit_des': null, 'is_active': true, 'server_version': 7,
          'is_deleted': false,
        },
      ],
      'menu_screens': [
        {
          'menu_id': 2010, 'name': 'Appetizers', 'name_ar': null,
          'sort_order': 0, 'buttons_across': 5, 'buttons_down': 8,
          'is_modifier_screen': false, 'is_active': true,
          'server_version': 7, 'is_deleted': false,
        },
      ],
      'menu_buttons': [
        {
          'id': 'aaaaaaaa-0000-4000-8000-000000000001', 'menu_id': 2010,
          'prodnum': 2013, 'position': 1, 'pos_x': 0, 'pos_y': 0,
          'caption': null, 'is_active': true, 'server_version': 7,
          'is_deleted': false,
        },
        {
          'id': 'aaaaaaaa-0000-4000-8000-000000000002', 'menu_id': 2010,
          'prodnum': 2152, 'position': 2, 'pos_x': 1, 'pos_y': 0,
          'caption': null, 'is_active': true, 'server_version': 7,
          'is_deleted': false,
        },
      ],
      'pay_methods': [
        {
          'methodnum': 1010, 'descript': 'MADA', 'descript_ar': null,
          'is_cash': false, 'opens_drawer': false, 'sort_order': 0,
          'is_active': true, 'server_version': 7, 'is_deleted': false,
        },
      ],
      'staff': [
        {
          'empnum': 0, 'name': 'Cashier', 'sec_level': 10, 'ref_code': null,
          'is_active': true, 'server_version': 7, 'is_deleted': false,
        },
      ],
      'tax_rates': [
        {
          'tax_id': 1, 'name': 'VAT', 'percent': 15.0, 'is_inclusive': true,
          'server_version': 7, 'is_deleted': false,
        },
      ],
      'sales_types': [
        {
          'sale_type_no': 2025, 'descript': 'Drive Thru', 'descript_ar': null,
          'price_tier': 'a', 'is_aggregator': false,
          'requires_external_ref': false, 'needs_table': false,
          'default_methodnum': null, 'sort_order': 0, 'is_active': true,
          'server_version': 7, 'is_deleted': false,
        },
        {
          'sale_type_no': 2004, 'descript': 'Keeta', 'descript_ar': null,
          'price_tier': 'b', 'is_aggregator': true,
          'requires_external_ref': true, 'needs_table': false,
          'default_methodnum': null, 'sort_order': 1, 'is_active': true,
          'server_version': 7, 'is_deleted': false,
        },
      ],
      'kitchen_stations': [
        {
          'station_no': 3, 'name': 'Grill', 'name_ar': null, 'sort_order': 3,
          'is_active': true, 'server_version': 7, 'is_deleted': false,
        },
        {
          'station_no': 5, 'name': 'DT', 'name_ar': null, 'sort_order': 5,
          'is_active': true, 'server_version': 7, 'is_deleted': false,
        },
      ],
    };

http.Response _json(Object body, {int status = 200}) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

void main() {
  setUpAll(useSystemSqlite);

  group('applyCatalog', () {
    late PosDatabase db;

    setUp(() {
      db = PosDatabase.openInMemory(loadSchema());
    });
    tearDown(() => db.dispose());

    SyncService service() => SyncService(
        db: db, api: SyncApi(baseUrl: 'http://x', client: MockClient((r) async {
              throw StateError('applyCatalog must not touch the wire');
            })));

    test('lands every catalog family and the watermark', () {
      service().applyCatalog(catalogFixture());

      final items = db.productsForScreen(2010);
      expect(items.map((p) => p.prodnum), [2013, 2152]);
      expect(items.first.tiers[0], 800);
      expect(items.first.tiers[1], 900);
      expect(items.last.printLoc, 40);
      expect(db.kitchenStations(), {3: 'Grill', 5: 'DT'});
      expect(db.salesTypes().map((t) => t.descript), ['Drive Thru', 'Keeta']);
      expect(service().catalogWatermark(), 7);
    });

    test('is idempotent — applying twice changes nothing', () {
      final s = service();
      s.applyCatalog(catalogFixture());
      s.applyCatalog(catalogFixture());

      expect(db.productsForScreen(2010).length, 2);
      expect(
          db.raw.select('SELECT COUNT(*) AS n FROM menu_button').first['n'], 2);
    });

    test('a tombstone removes the product from the till', () {
      final s = service();
      s.applyCatalog(catalogFixture());

      final delta = catalogFixture(version: 8);
      final gone = (delta['products'] as List).first as Map<String, dynamic>;
      gone['is_deleted'] = true;
      delta['products'] = [gone];
      delta['menu_screens'] = [];
      delta['menu_buttons'] = [];
      delta['pay_methods'] = [];
      delta['staff'] = [];
      delta['tax_rates'] = [];
      delta['sales_types'] = [];
      delta['kitchen_stations'] = [];
      s.applyCatalog(delta);

      expect(db.productsForScreen(2010).map((p) => p.prodnum), [2152]);
      expect(s.catalogWatermark(), 8);
    });

    test('a price change lands without touching other rows', () {
      final s = service();
      s.applyCatalog(catalogFixture());

      final delta = catalogFixture(version: 9);
      final hummos = (delta['products'] as List).first as Map<String, dynamic>;
      hummos['price_a'] = 850;
      delta['products'] = [hummos];
      s.applyCatalog(delta);

      final items = db.productsForScreen(2010);
      expect(items.firstWhere((p) => p.prodnum == 2013).tiers[0], 850);
      expect(items.firstWhere((p) => p.prodnum == 2152).tiers[0], 2400);
    });
  });

  group('sales push', () {
    late PosDatabase db;

    setUp(() => db = seededDatabase());
    tearDown(() => db.dispose());

    String makeSale() {
      final hummos = db
          .productsForScreen(2010)
          .firstWhere((p) => p.prodnum == 2013);
      return db
          .completeSale(
            cart: [CartLine(product: hummos, qty: 2)],
            salesType: db.salesTypes().firstWhere((t) => t.no == 2025),
            methodnum: 1010,
            orderNo: 42,
          )
          .saleUuid;
    }

    test('payload matches the SaleIn contract', () {
      final uuid = makeSale();
      final p = SyncService(
              db: db,
              api: SyncApi(baseUrl: 'http://x'))
          .buildSalePayload(uuid);

      expect(p['net_total'] + p['tax_total'], p['final_total']);
      for (final line in p['lines'] as List) {
        final l = line as Map<String, dynamic>;
        expect(l['net_amount'] + l['tax_amount'], l['line_total']);
      }
      final paid = (p['payments'] as List)
          .fold<int>(0, (s, x) => s + (x as Map)['amount'] as int);
      expect(paid, p['final_total']);
      expect(p['status'], 'closed');
      expect(p['order_no'], 42);
      expect(p['business_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('accepted sale clears the outbox and marks the sale acked', () async {
      final uuid = makeSale();
      late Map<String, dynamic> sent;

      final api = SyncApi(
        baseUrl: 'http://backend',
        token: 'tok',
        client: MockClient((request) async {
          expect(request.url.path, '/v1/sales');
          expect(request.headers['authorization'], 'Bearer tok');
          sent = ((jsonDecode(request.body) as List).single as Map)
              .cast<String, dynamic>();
          return _json({
            'accepted': [
              {'sale_uuid': uuid, 'status': 'accepted', 'receipt_no': 'x'}
            ],
            'rejected': [],
          });
        }),
      );

      final result =
          await SyncService(db: db, api: api).pushOutbox();
      expect(result.sent, 1);
      expect(result.failed, 0);
      expect(sent['sale_uuid'], uuid);
      expect(db.outboxDepth(), 0);
      expect(db.saleRow(uuid)['sync_status'], 'acked');
    });

    test('kitchen tickets push before anything else and only once', () async {
      // Hummos Lahm routes to Grill + DT, so completing this sale cuts one
      // kitchen ticket with two lines.
      final lahm = db
          .productsForScreen(2010)
          .firstWhere((p) => p.prodnum == 2152);
      db.completeSale(
        cart: [CartLine(product: lahm, qty: 1)],
        salesType: db.salesTypes().firstWhere((t) => t.no == 2025),
        methodnum: 1010,
        orderNo: 9,
      );

      final posted = <Map<String, dynamic>>[];
      final api = SyncApi(
        baseUrl: 'http://backend',
        token: 'tok',
        client: MockClient((request) async {
          expect(request.url.path, '/v1/kds/tickets');
          final body =
              (jsonDecode(request.body) as Map).cast<String, dynamic>();
          posted.add(body);
          return _json(body, status: 201);
        }),
      );

      final sync = SyncService(db: db, api: api);
      expect(await sync.pushKitchenTickets(), 1);
      expect(posted.single['order_no'], 9);
      expect((posted.single['lines'] as List).length, 2);
      expect(
        {for (final l in posted.single['lines'] as List) (l as Map)['station_no']},
        {3, 5},
      );

      // Already sent — a second drain must not cook the order twice.
      expect(await sync.pushKitchenTickets(), 0);
    });

    test('rejected sale is flagged, not retried forever', () async {
      final uuid = makeSale();
      final api = SyncApi(
        baseUrl: 'http://backend',
        token: 'tok',
        client: MockClient((request) async => _json({
              'accepted': [],
              'rejected': [
                {'sale_uuid': uuid, 'error': 'closed sale has no ZATCA QR'}
              ],
            })),
      );

      final result =
          await SyncService(db: db, api: api).pushOutbox();
      expect(result.sent, 0);
      expect(result.failed, 1);

      final outbox =
          db.raw.select('SELECT attempts, last_error FROM outbox').first;
      expect(outbox['attempts'], 1);
      expect(outbox['last_error'], contains('ZATCA'));
      expect(db.saleRow(uuid)['sync_status'], 'failed');
    });
  });

  group('enrolAndPrime', () {
    late PosDatabase db;

    setUp(() {
      db = PosDatabase.openInMemory(loadSchema());
    });
    tearDown(() => db.dispose());

    test('stores the credential and pulls the catalog in one go', () async {
      final api = SyncApi(
        baseUrl: 'http://backend',
        client: MockClient((request) async {
          if (request.url.path == '/v1/enrol') {
            final body =
                (jsonDecode(request.body) as Map).cast<String, dynamic>();
            expect(body['code'], 'CODE-123456789012');
            return _json({
              'token': 'jwt-abc',
              'device_id': 'bbbbbbbb-0000-4000-8000-000000000001',
              'role': 'pos',
              'receipt_prefix': 'T07',
              'kds_station_no': null,
              'branch_name': 'Arid Branch',
              'tenant_mode': 'standalone',
            });
          }
          expect(request.url.path, '/v1/catalog');
          expect(request.headers['authorization'], 'Bearer jwt-abc');
          return _json(catalogFixture());
        }),
      );

      final result = await SyncService(db: db, api: api).enrolAndPrime(
        code: 'CODE-123456789012',
        deviceUuid: 'tablet-xyz',
      );

      expect(result.branchName, 'Arid Branch');
      final device = db.raw.select('SELECT * FROM device WHERE id = 1').first;
      expect(device['auth_token'], 'jwt-abc');
      expect(device['receipt_prefix'], 'T07');
      expect(device['api_base_url'], 'http://backend');
      expect(db.productsForScreen(2010).length, 2);
    });
  });
}
