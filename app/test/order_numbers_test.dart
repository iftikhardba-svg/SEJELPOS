/// Customer-facing order numbers.
///
/// The till used to count these locally from 1. Two tills at one counter
/// therefore called out the same number to different customers, and every app
/// restart began again at "ORDER 1" — on a business where drive-thru and
/// takeaway are 69% of trade and the number is how the food finds its owner.
///
/// What matters here is not that numbers increment. It is that two devices
/// never hand out the same one, including across an outage.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/order_numbers.dart';
import 'package:pos_app/sync/sync_api.dart';

import 'helpers.dart';

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Stands in for the backend's atomic per-branch, per-day allocator: every
/// call hands out the next disjoint run.
class FakeAllocator {
  int _next = 1;
  int calls = 0;
  final List<int> requested = [];

  SyncApi api({bool offline = false}) => SyncApi(
        baseUrl: 'http://backend',
        token: 'tok',
        client: MockClient((request) async {
          if (offline) throw const SocketishFailure();
          calls += 1;
          final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
          final count = body['count'] as int;
          requested.add(count);
          final first = _next;
          _next += count;
          return _json({
            'business_date': body['business_date'],
            'order_no': first,
            'count': count,
          });
        }),
      );
}

class SocketishFailure implements Exception {
  const SocketishFailure();
  @override
  String toString() => 'connection refused';
}

void main() {
  setUpAll(useSystemSqlite);

  final today = DateTime.utc(2026, 8, 6, 9);

  late PosDatabase db;
  setUp(() => db = seededDatabase());
  tearDown(() => db.dispose());

  test('numbers come from the backend, not from 1', () async {
    final allocator = FakeAllocator();
    allocator._next = 500; // the branch has already sold today
    final orders = OrderNumbers(
        db: db, api: allocator.api(), blockSize: 20, topUpAt: 2);

    final first = await orders.next(today);
    expect(first.number, 500);
    expect(first.provisional, isFalse);
    expect((await orders.next(today)).number, 501);
  });

  test('one reservation serves many sales', () async {
    final allocator = FakeAllocator();
    final orders =
        OrderNumbers(db: db, api: allocator.api(), blockSize: 50, topUpAt: 5);

    for (var i = 0; i < 30; i++) {
      await orders.next(today);
    }
    // A network round trip per customer would make the counter depend on the
    // network, which is the thing this design exists to avoid.
    expect(allocator.calls, 1);
    expect(allocator.requested, [50]);
  });

  test('two tills never hand out the same number', () async {
    // One allocator, two devices — the real shape of a counter with two
    // tills.
    final allocator = FakeAllocator();
    final other = seededDatabase();
    addTearDown(other.dispose);

    final a = OrderNumbers(db: db, api: allocator.api(), blockSize: 10,
        topUpAt: 2);
    final b = OrderNumbers(db: other, api: allocator.api(), blockSize: 10,
        topUpAt: 2);

    final issued = <int>[];
    for (var i = 0; i < 25; i++) {
      issued.add((await a.next(today)).number);
      issued.add((await b.next(today)).number);
    }

    expect(issued.length, 50);
    expect(issued.toSet().length, 50, reason: 'two tills shared a number');
  });

  test('the block is topped up before it runs out, not after', () async {
    final allocator = FakeAllocator();
    final orders =
        OrderNumbers(db: db, api: allocator.api(), blockSize: 20, topUpAt: 5);

    await orders.next(today);
    // Reserved 20, used 1: a till that loses the network now still has
    // numbers in hand.
    expect(orders.remaining(today), greaterThan(5));
  });

  test('an offline till keeps issuing from what it holds', () async {
    final allocator = FakeAllocator();
    final orders =
        OrderNumbers(db: db, api: allocator.api(), blockSize: 30, topUpAt: 5);

    final online = await orders.next(today);
    expect(online.provisional, isFalse);

    // The network goes away mid-service.
    final offline = OrderNumbers(
      db: db, api: allocator.api(offline: true), blockSize: 30, topUpAt: 5);

    final issued = <int>[];
    for (var i = 0; i < 20; i++) {
      final o = await offline.next(today);
      expect(o.provisional, isFalse, reason: 'still inside the reserved block');
      issued.add(o.number);
    }
    expect(issued.toSet().length, 20);
    expect(issued.first, online.number + 1);
  });

  test('exhausting the block offline is flagged, never blocked', () async {
    final allocator = FakeAllocator();
    // Reserve a tiny block while online, then lose the network.
    await OrderNumbers(db: db, api: allocator.api(), blockSize: 3, topUpAt: 0)
        .next(today);

    final offline = OrderNumbers(
        db: db, api: allocator.api(offline: true), blockSize: 3, topUpAt: 0);

    await offline.next(today);
    await offline.next(today);
    final beyond = await offline.next(today);

    // Selling must not stop because numbering ran out...
    expect(beyond.provisional, isTrue);
    // ...but the number is qualified by the device, so it cannot be confused
    // with another till's.
    expect(offline.format(beyond), startsWith('T01-'));
    expect(offline.format((number: 7, provisional: false)), '7');
  });

  test('a new business day starts its own block', () async {
    final allocator = FakeAllocator();
    final orders = OrderNumbers(
        db: db, api: allocator.api(), blockSize: 10, topUpAt: 2);

    final todayFirst = await orders.next(today);
    final tomorrow = today.add(const Duration(days: 1));
    final tomorrowFirst = await orders.next(tomorrow);

    // Each day reserves separately, so a day's numbers cannot be handed out
    // twice by carrying yesterday's block into today.
    expect(allocator.calls, 2);
    expect(tomorrowFirst.number, isNot(todayFirst.number));

    // Yesterday's block is still intact and untouched by today's trade.
    final todaySecond = await orders.next(today);
    expect(todaySecond.number, todayFirst.number + 1);
  });

  test('a top-up abandons the tail of the old block rather than reusing it',
      () async {
    // Documented behaviour: a row holds one run. The alternative is tracking
    // two ranges to save a handful of call-out numbers, which buys nothing
    // and risks the one thing that must never happen.
    final allocator = FakeAllocator();
    final orders = OrderNumbers(
        db: db, api: allocator.api(), blockSize: 10, topUpAt: 8);

    final issued = <int>[];
    for (var i = 0; i < 6; i++) {
      issued.add((await orders.next(today)).number);
    }

    expect(issued.toSet().length, 6, reason: 'a number was handed out twice');
    expect(issued, equals([...issued]..sort()),
        reason: 'numbers must never go backwards');
  });

  test('a device with no backend issues provisional numbers only', () async {
    // The demo path. One till, so counting locally is harmless — but it must
    // still be labelled, not passed off as allocated.
    final orders = OrderNumbers(db: db, api: null);
    final first = await orders.next(today);
    expect(first.provisional, isTrue);
    expect(orders.format(first), 'T01-1');
  });

  test('reservations survive a restart', () async {
    final allocator = FakeAllocator();
    final before =
        OrderNumbers(db: db, api: allocator.api(), blockSize: 25, topUpAt: 2);
    await before.next(today);
    await before.next(today);

    // A new instance against the same database is what a relaunch looks like.
    final after =
        OrderNumbers(db: db, api: allocator.api(), blockSize: 25, topUpAt: 2);
    final next = await after.next(today);

    expect(next.number, 3, reason: 'restart must not rewind to 1');
    expect(allocator.calls, 1, reason: 'the held block was reused');
  });
}
