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
      'menus': [
        {
          'menu_no': 7, 'name': 'Default Menu', 'name_ar': null,
          'is_active': true, 'server_version': 7, 'is_deleted': false,
        },
      ],
      // No id: MenuPageOut does not carry one, and inventing one here is what
      // let a real bug through — the fixture upserted on a key the wire never
      // sends.
      'menu_pages': [
        {
          'menu_no': 7, 'screen_no': 2010, 'pos_x': 1, 'pos_y': 1,
          'sort_order': 0, 'is_active': true, 'server_version': 7,
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
      'questions': [
        {
          'question_no': 2003, 'prompt': '1 DRINKS', 'prompt_ar': null,
          'is_required': false, 'pick_count': 1, 'allow_repeats': false,
          'free_choices': 99, 'is_active': true, 'server_version': 7,
          'is_deleted': false,
        },
      ],
      'question_choices': [
        {
          'id': 'cccccccc-0000-4000-8000-000000000001', 'question_no': 2003,
          'prodnum': 2013, 'sort_order': 1, 'price_mode': 11,
          'fixed_price': 0, 'default_qty': 1, 'is_active': true,
          'server_version': 7, 'is_deleted': false,
        },
      ],
      'product_questions': [
        {
          'id': 'dddddddd-0000-4000-8000-000000000001', 'prodnum': 2152,
          'question_no': 2003, 'slot': 1, 'server_version': 7,
          'is_deleted': false,
        },
      ],
      'combo_items': [
        {
          'id': 'eeeeeeee-0000-4000-8000-000000000001',
          'parent_prodnum': 2152, 'prodnum': 2013, 'sort_order': 1,
          'price_mode': 0, 'fixed_price': null, 'print_it': true,
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
      // The second pull of a menu page used to raise a UNIQUE violation that
      // aborted the entire apply, leaving the device with no catalog at all.
      expect(
          db.raw.select('SELECT COUNT(*) AS n FROM menu_page').first['n'], 1);
    });

    test('the prompts arrive with the products they belong to', () {
      service().applyCatalog(catalogFixture());

      // Shipped to the device, not just held on the server: until this the
      // back office could set a prompt no till would ever ask.
      final questions = db.questionsFor(2152);
      expect(questions.single.prompt, '1 DRINKS');
      expect(questions.single.isRequired, isFalse);
      expect(questions.single.choices.single.product.prodnum, 2013);
      expect(questions.single.choices.single.unitPrice, 0,
          reason: 'fixed_price 0 under price_mode 11 means included');
      expect(db.comboItemsFor(2152).single.product.descript, 'HUMMOS');
    });

    test('clearing a prompt slot stops the till asking', () {
      final s = service();
      s.applyCatalog(catalogFixture());

      final delta = catalogFixture(version: 8);
      final dropped =
          (delta['product_questions'] as List).first as Map<String, dynamic>;
      dropped['is_deleted'] = true;
      delta['products'] = [];
      delta['menu_screens'] = [];
      delta['menu_buttons'] = [];
      delta['pay_methods'] = [];
      delta['staff'] = [];
      delta['tax_rates'] = [];
      delta['sales_types'] = [];
      delta['kitchen_stations'] = [];
      delta['questions'] = [];
      delta['question_choices'] = [];
      delta['combo_items'] = [];
      s.applyCatalog(delta);

      // The row is tombstoned rather than missing: a vanished row is
      // invisible to an incremental pull, and the till would ask forever.
      expect(db.questionsFor(2152), isEmpty);
      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM product_question')
            .first['n'],
        1,
      );
    });

    test('a row re-issued under a new id replaces the old one', () {
      final s = service();
      s.applyCatalog(catalogFixture());

      // A catalog rebuilt on the server hands the same placement and the same
      // prompt slot a new uuid. Keyed only by id, the insert hits the business
      // -key unique index and takes the WHOLE catalog apply down with it — the
      // device ends up with no catalog at all, not just a stale menu. Found on
      // a real till whose menu had been reloaded on the backend.
      final delta = catalogFixture(version: 10);
      for (final row in (delta['product_questions'] as List)) {
        (row as Map<String, dynamic>)['id'] =
            'ffffffff-0000-4000-8000-${row['id'].toString().split('-').last}';
      }

      expect(() => s.applyCatalog(delta), returnsNormally);
      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM product_question').first['n'],
        1,
        reason: 'the slot must be replaced, not doubled',
      );
      expect(db.questionsFor(2152).single.prompt, '1 DRINKS');
      expect(db.defaultMenu()?.name, 'Default Menu');
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
      var pushes = 0;
      final api = SyncApi(
        baseUrl: 'http://backend',
        token: 'tok',
        client: MockClient((request) async {
          pushes += 1;
          return _json({
            'accepted': [],
            'rejected': [
              {'sale_uuid': uuid, 'error': 'closed sale has no ZATCA QR'}
            ],
          });
        }),
      );

      final sync = SyncService(db: db, api: api);
      final result = await sync.pushOutbox();
      expect(result.sent, 0);
      expect(result.failed, 1);

      final outbox =
          db.raw.select('SELECT attempts, last_error FROM outbox').first;
      expect(outbox['attempts'], 1);
      expect(outbox['last_error'], contains('ZATCA'));
      expect(db.saleRow(uuid)['sync_status'], 'failed');

      // "Not retried" has to mean across cycles, not just within one. The
      // sync worker drains on a timer, so a row that keeps coming back is a
      // dead sale re-pushed for the life of the device.
      final again = await sync.pushOutbox();
      expect(again.sent, 0);
      expect(again.failed, 0);
      expect(pushes, 1, reason: 'a flagged sale must never be pushed again');
      expect(
        db.raw.select('SELECT attempts FROM outbox').first['attempts'],
        1,
      );
    });

    test('a fresh sale still drains past a flagged one', () async {
      final dead = makeSale();
      final api = SyncApi(
        baseUrl: 'http://backend',
        token: 'tok',
        client: MockClient((request) async {
          final body = (jsonDecode(request.body) as List).cast<Map>();
          final uuid = body.single['sale_uuid'];
          return _json(uuid == dead
              ? {
                  'accepted': [],
                  'rejected': [
                    {'sale_uuid': uuid, 'error': 'closed sale has no ZATCA QR'}
                  ],
                }
              : {
                  'accepted': [
                    {'sale_uuid': uuid}
                  ],
                  'rejected': [],
                });
        }),
      );

      final sync = SyncService(db: db, api: api);
      await sync.pushOutbox();

      // One poison record must not stall the queue behind it.
      final good = makeSale();
      final result = await sync.pushOutbox();
      expect(result.sent, 1);
      expect(db.saleRow(good)['sync_status'], 'acked');
      expect(db.outboxDepth(), 1, reason: 'only the flagged row remains');
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
              'seller_name': 'Fatima Restaurant',
              'seller_name_ar': 'مطعم فاطمة',
              'seller_vat': '310000000000003',
              'seller_cr': '1010012345',
              'seller_address': {
                'street': 'King Fahd Road',
                'building': '8228',
                'city': 'Riyadh',
                'postal_code': '12244',
                'country': 'SA',
              },
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

      // Without the seller identity the device could never issue a compliant
      // invoice offline, so enrolment is the one chance to deliver it.
      expect(device['zatca_vat_number'], '310000000000003');
      expect(device['zatca_seller_name'], 'مطعم فاطمة',
          reason: 'ZATCA wants the Arabic registered name on the invoice');
      expect(device['zatca_seller_cr'], '1010012345');
      expect(
        (jsonDecode(device['zatca_seller_address'] as String)
            as Map)['postal_code'],
        '12244',
      );
    });

    test('falls back to the Latin name when no Arabic one is registered',
        () async {
      final api = SyncApi(
        baseUrl: 'http://backend',
        client: MockClient((request) async {
          if (request.url.path == '/v1/enrol') {
            return _json({
              'token': 'jwt-abc',
              'device_id': 'bbbbbbbb-0000-4000-8000-000000000001',
              'role': 'pos',
              'receipt_prefix': 'T07',
              'kds_station_no': null,
              'branch_name': 'Arid Branch',
              'tenant_mode': 'standalone',
              'seller_name': 'Fatima Restaurant',
              'seller_name_ar': null,
              'seller_vat': '310000000000003',
              'seller_cr': null,
              'seller_address': <String, dynamic>{},
            });
          }
          return _json(catalogFixture());
        }),
      );

      await SyncService(db: db, api: api)
          .enrolAndPrime(code: 'CODE-123456789012', deviceUuid: 'tablet-xyz');

      final device = db.raw.select('SELECT * FROM device WHERE id = 1').first;
      expect(device['zatca_seller_name'], 'Fatima Restaurant');
    });
  });
}
