/// The number the customer is called by.
///
/// 69% of this customer's trade is drive-thru and takeaway, where the order
/// number IS how the food finds its owner. The till used to count these
/// locally from 1, which meant two tills at one counter called out the same
/// number to different people, and every app restart began again at "ORDER 1".
///
/// A device therefore does not count. It **reserves a contiguous block** from
/// the backend, which allocates atomically per branch and per business day,
/// and hands out from that block locally. That is what keeps the numbers
/// usable with no network without ever colliding: two tills hold disjoint
/// runs.
///
/// The block is topped up while there is still room left, so a till that goes
/// offline mid-service is already holding numbers rather than discovering it
/// needs some.
library;

import '../data/pos_database.dart';
import 'sync_api.dart';

/// What to call out, and whether it can be trusted to be unique.
typedef OrderNumber = ({int number, bool provisional});

class OrderNumbers {
  OrderNumbers({
    required this.db,
    this.api,
    this.blockSize = 200,
    this.topUpAt = 40,
  }) : assert(
          blockSize > topUpAt,
          'blockSize must exceed topUpAt, or every sale triggers a top-up and '
          'burns a block per customer',
        );

  final PosDatabase db;

  /// Null on a device with no backend (the demo path). Everything then falls
  /// through to provisional numbering, which is correct for a single till.
  final SyncApi? api;

  /// How many numbers to reserve at a time. Comfortably more than a day of
  /// counter trade at this customer, so a normal outage never exhausts it.
  final int blockSize;

  /// Top up once the block has this many left, rather than on the last one:
  /// a till that hits zero offline has nothing to hand out.
  final int topUpAt;

  static String _key(DateTime businessDate) =>
      businessDate.toUtc().toIso8601String().substring(0, 10);

  /// Take the next number for [businessDate].
  ///
  /// Returns `provisional: true` when the block is spent and the backend
  /// could not be reached. Such a number is NOT guaranteed unique across
  /// tills, so callers must display it in a way that says which device issued
  /// it — see [format].
  Future<OrderNumber> next(DateTime businessDate) async {
    final day = _key(businessDate);
    _ensureRow(day);

    var (next, end) = _read(day);

    // Top up early. Doing it before the block runs out is the whole point:
    // the reserve is there to survive an outage, not to be discovered during
    // one.
    if (end - next < topUpAt) {
      await _topUp(day, businessDate);
      (next, end) = _read(day);
    }

    if (next <= end) {
      db.raw.execute(
        'UPDATE order_counter SET next_number = ? WHERE business_date = ?',
        [next + 1, day],
      );
      return (number: next, provisional: false);
    }

    // Block spent and no backend. Selling must not stop for a numbering
    // problem, so keep counting and mark it: the display carries the device
    // prefix, which no other till shares.
    db.raw.execute(
      'UPDATE order_counter SET next_number = ? WHERE business_date = ?',
      [next + 1, day],
    );
    return (number: next, provisional: true);
  }

  /// What the customer is told. A provisional number is qualified by the
  /// device that issued it, because two tills may both be holding one.
  String format(OrderNumber order) {
    if (!order.provisional) return '${order.number}';
    final rows = db.raw.select(
      'SELECT receipt_prefix FROM device WHERE id = 1',
    );
    final prefix = rows.isEmpty ? '?' : rows.first['receipt_prefix'] as String;
    return '$prefix-${order.number}';
  }

  /// Numbers still held for [businessDate]. Surfaced in device setup so
  /// "why do the numbers look odd" has an answer before service, not after.
  int remaining(DateTime businessDate) {
    final day = _key(businessDate);
    final rows = db.raw.select(
      'SELECT next_number, block_end FROM order_counter WHERE business_date = ?',
      [day],
    );
    if (rows.isEmpty) return 0;
    final next = rows.first['next_number'] as int;
    final end = rows.first['block_end'] as int;
    return end >= next ? end - next + 1 : 0;
  }

  void _ensureRow(String day) {
    db.raw.execute(
      'INSERT OR IGNORE INTO order_counter (business_date, next_number, '
      '  block_end) VALUES (?, 1, 0)',
      [day],
    );
  }

  (int, int) _read(String day) {
    final row = db.raw.select(
      'SELECT next_number, block_end FROM order_counter WHERE business_date = ?',
      [day],
    ).first;
    return (row['next_number'] as int, row['block_end'] as int);
  }

  /// Reserve another block and move onto it.
  ///
  /// Whatever was left of the old block is **discarded**, not carried. A row
  /// holds one run, and tracking two would buy nothing: these are call-out
  /// numbers, so a jump from 160 to 201 is invisible to a customer, while a
  /// bug that let two tills share a run is not. The waste is bounded by
  /// [topUpAt] per block.
  ///
  /// Failure is not an error the caller should see: being offline is the
  /// normal state this whole design exists for.
  Future<void> _topUp(String day, DateTime businessDate) async {
    final client = api;
    if (client == null) return;

    try {
      final block = await client.reserveOrderNumbers(
        businessDate: businessDate,
        count: blockSize,
      );
      db.raw.execute(
        'UPDATE order_counter SET next_number = ?, block_end = ? '
        'WHERE business_date = ?',
        [block.first, block.first + block.count - 1, day],
      );
    } on Exception {
      // Offline, or the backend refused. Carry on with what is held.
    }
  }
}
