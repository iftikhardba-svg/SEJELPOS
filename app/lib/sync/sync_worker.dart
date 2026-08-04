/// The background sync loop.
///
/// One pass = kitchen tickets, then sales, then catalog — in that order,
/// because the kitchen is waiting on the first, accountants on the second and
/// nobody urgently on the third. Every step is fenced: sync failing must never
/// take the till down, so errors are collected and reported, not thrown.
///
/// This is an in-app timer for now. The Android foreground-service treatment
/// (surviving the app being backgrounded) belongs to the hub work — the rules
/// here do not change when that lands, only who calls [syncNow].
library;

import 'dart:async';

import 'sync_service.dart';

class SyncResult {
  SyncResult({
    required this.kitchenSent,
    required this.salesSent,
    required this.salesFailed,
    required this.catalogVersion,
    required this.errors,
  });

  final int kitchenSent;
  final int salesSent;
  final int salesFailed;
  final int? catalogVersion;
  final List<String> errors;

  bool get clean => errors.isEmpty;

  @override
  String toString() =>
      'kitchen $kitchenSent · sales $salesSent (+$salesFailed flagged) · '
      'catalog v$catalogVersion'
      '${errors.isEmpty ? '' : ' · errors: ${errors.join('; ')}'}';
}

class SyncWorker {
  SyncWorker({required this.sync, this.onResult});

  final SyncService sync;
  final void Function(SyncResult result)? onResult;

  Timer? _timer;
  bool _running = false;

  void start({Duration interval = const Duration(seconds: 30)}) {
    stop();
    _timer = Timer.periodic(interval, (_) => syncNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One full pass. Re-entrancy is refused rather than queued: if the last
  /// pass is still running, another timer tick has nothing new to add.
  Future<SyncResult> syncNow() async {
    if (_running) {
      return SyncResult(
        kitchenSent: 0, salesSent: 0, salesFailed: 0,
        catalogVersion: null, errors: const ['previous pass still running'],
      );
    }
    _running = true;
    final errors = <String>[];
    var kitchenSent = 0;
    var salesSent = 0;
    var salesFailed = 0;
    int? catalogVersion;

    try {
      try {
        kitchenSent = await sync.pushKitchenTickets();
      } on Exception catch (e) {
        errors.add('kitchen: $e');
      }
      try {
        final push = await sync.pushOutbox();
        salesSent = push.sent;
        salesFailed = push.failed;
      } on Exception catch (e) {
        errors.add('sales: $e');
      }
      try {
        catalogVersion = await sync.pullCatalog();
      } on Exception catch (e) {
        errors.add('catalog: $e');
      }
    } finally {
      _running = false;
    }

    final result = SyncResult(
      kitchenSent: kitchenSent,
      salesSent: salesSent,
      salesFailed: salesFailed,
      catalogVersion: catalogVersion,
      errors: errors,
    );
    onResult?.call(result);
    return result;
  }
}
