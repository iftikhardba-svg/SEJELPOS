/// Two tills, one counter, one backend — do they ever call the same number?
///
///     dart run tool/order_number_race.dart <baseUrl> <codeA> <codeB>
///
/// This is the failure the block allocator exists to prevent, and it is not
/// something a unit test with a fake allocator can settle: it needs the real
/// endpoint, with its real atomic upsert, under concurrent pressure.
///
/// Both devices are driven hard and interleaved. Exits 0 only if every number
/// issued across both tills is distinct.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:uuid/uuid.dart';

import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/sync/order_numbers.dart';
import 'package:pos_app/sync/sync_api.dart';
import 'package:pos_app/sync/sync_service.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run tool/order_number_race.dart <baseUrl> <codeA> <codeB>',
    );
    exit(2);
  }
  final [baseUrl, codeA, codeB] = args;

  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open('winsqlite3.dll'),
    );
  }
  final schema = File('assets/schema.sql').readAsStringSync();

  Future<OrderNumbers> till(String code, String label) async {
    final db = PosDatabase.openInMemory(schema);
    final api = SyncApi(baseUrl: baseUrl);
    await SyncService(db: db, api: api).enrolAndPrime(
      code: code,
      deviceUuid: 'race-$label-${const Uuid().v4()}',
    );
    // Small blocks on purpose: this forces repeated trips to the allocator,
    // which is where a collision would happen if one were possible.
    return OrderNumbers(db: db, api: api, blockSize: 10, topUpAt: 3);
  }

  final a = await till(codeA, 'a');
  final b = await till(codeB, 'b');

  final day = DateTime.now();
  final fromA = <int>[];
  final fromB = <int>[];

  // Interleaved and concurrent, because a lock that only holds when requests
  // are politely spaced is not a lock.
  for (var round = 0; round < 25; round++) {
    final results = await Future.wait([
      a.next(day),
      b.next(day),
      a.next(day),
      b.next(day),
    ]);
    fromA.addAll([results[0].number, results[2].number]);
    fromB.addAll([results[1].number, results[3].number]);

    for (final r in results) {
      if (r.provisional) {
        stderr.writeln('a till fell back to provisional numbering while '
            'online — the allocator was unreachable');
        exit(1);
      }
    }
  }

  final all = [...fromA, ...fromB];
  final distinct = all.toSet();
  final collisions = fromA.toSet().intersection(fromB.toSet());

  stdout.writeln(const JsonEncoder.withIndent('  ').convert({
    'issued_total': all.length,
    'distinct': distinct.length,
    'till_a_range': [fromA.reduce((x, y) => x < y ? x : y),
                     fromA.reduce((x, y) => x > y ? x : y)],
    'till_b_range': [fromB.reduce((x, y) => x < y ? x : y),
                     fromB.reduce((x, y) => x > y ? x : y)],
    'shared_numbers': collisions.toList()..sort(),
    'no_collisions': collisions.isEmpty && distinct.length == all.length,
  }));

  if (collisions.isNotEmpty || distinct.length != all.length) {
    stderr.writeln('TWO TILLS CALLED THE SAME ORDER NUMBER');
    exit(1);
  }
  exit(0);
}
