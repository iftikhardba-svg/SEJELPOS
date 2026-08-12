/// POS app entry point.
///
/// Boot decides between two screens: a device that has enrolled (or seeded the
/// demo) goes to its role's screen; a fresh one gets the enrolment screen.
/// The database is a file under the app's support directory — a restart, a
/// crash or an update must never cost a sale.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/pos_database.dart';
import 'sync/order_numbers.dart';
import 'sync/sync_api.dart';
import 'sync/sync_service.dart';
import 'sync/sync_worker.dart';
import 'ui/cds_screen.dart';
import 'ui/enrol_screen.dart';
import 'ui/kds_screen.dart';
import 'ui/till_screen.dart';
import 'zatca/device_signer.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final schema = await rootBundle.loadString('assets/schema.sql');

  // One machine can hold more than one device. A restaurant has a till, a
  // kitchen screen and a customer board, and until now this app kept its
  // database at one fixed path — so a laptop could only ever be one of the
  // three, and the three could not be shown working together at all.
  //
  //     pos_app.exe --profile=kitchen
  //
  // Without the flag nothing moves: the default profile is the same path
  // every installed till already uses.
  final profile = _profileFrom(args);
  // A presentation drives the customer board by hand; a branch never should.
  final demo = args.contains('--demo');
  final support = await getApplicationSupportDirectory();
  final dir = profile == null
      ? support
      : Directory(p.join(support.path, 'profiles', profile))
    ..createSync(recursive: true);

  // Two copies of one profile open one database, and SQLite is not the thing
  // that stops them: it has already cost a device its catalog and its unsent
  // sales. The lock is held for the life of the process and released by the
  // operating system if it dies.
  final lock = _claim(dir);
  if (lock == null) {
    runApp(_AlreadyRunning(profile: profile));
    return;
  }

  final db = PosDatabase.openFile(
    p.join(dir.path, 'pos.db'),
    schema,
    // Without a signer wired here the whole ZATCA path is dead code in the
    // real app: sales complete, receipts print UNSIGNED, and the backend
    // refuses every push. FileKeyProvider returns null until the device has
    // been through CSID onboarding, which is exactly the "cannot sign yet"
    // state the till is built to survive.
    signer: DeviceSigner(keys: FileKeyProvider(dir.path)),
  );
  runApp(PosApp(db: db, profile: profile, demo: demo));
}

/// `--profile=kitchen`, or null for the installed device's own database.
String? _profileFrom(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--profile=')) {
      final name = arg.substring('--profile='.length).trim();
      // A profile becomes a directory name, so anything that could climb out
      // of the support directory is refused rather than sanitised quietly.
      if (name.isEmpty || name.contains(RegExp(r'[^A-Za-z0-9._-]'))) {
        throw ArgumentError(
          'profile names may contain letters, digits, dot, dash and '
          'underscore only; got "$name"',
        );
      }
      return name;
    }
  }
  return null;
}

/// Take the lock for this profile, or null if another copy holds it.
RandomAccessFile? _claim(Directory dir) {
  try {
    final file = File(p.join(dir.path, 'app.lock')).openSync(mode: FileMode.write);
    file.lockSync(FileLock.exclusive);
    return file;
  } on FileSystemException {
    return null;
  }
}

/// What the second copy shows. Deliberately a dead end with no way through:
/// the whole point is that it must not open the database.
class _AlreadyRunning extends StatelessWidget {
  const _AlreadyRunning({this.profile});

  final String? profile;

  @override
  Widget build(BuildContext context) {
    final which = profile == null ? 'this device' : 'the "$profile" profile';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 16),
                const Text('Already running',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  'Another copy of the app is open on $which. Two copies '
                  'share one database and can destroy a day of sales, so '
                  'this one will not start.\n\nSwitch to the window that is '
                  'already open, or start this one with a different '
                  '--profile.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PosApp extends StatefulWidget {
  const PosApp({super.key, required this.db, this.profile, this.demo = false});

  final PosDatabase db;

  /// Named when the app was started with --profile, so several devices on one
  /// machine can be told apart.
  final String? profile;

  /// `--demo`: the customer board gets the mockup's staged controls.
  final bool demo;

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  late bool _ready;
  SyncWorker? _worker;
  OrderNumbers? _orderNumbers;

  @override
  void initState() {
    super.initState();
    _ready = _deviceIsSetUp();
  }

  @override
  void dispose() {
    _worker?.stop();
    super.dispose();
  }

  bool _deviceIsSetUp() {
    final rows =
        widget.db.raw.select('SELECT COUNT(*) AS n FROM device').first;
    return (rows['n'] as int) > 0;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6D28D9)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFA78BFA),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _ready
          ? _roleScreen()
          : EnrolScreen(
              db: widget.db,
              onReady: () => setState(() => _ready = true),
            ),
    );
  }

  /// One app, three roles. What this screen is was decided at enrolment and
  /// lives in the device row; the demo path is always a till.
  Widget _roleScreen() {
    final device =
        widget.db.raw.select('SELECT * FROM device WHERE id = 1').first;
    final role = (device['role'] as String?) ?? 'pos';
    final baseUrl = device['api_base_url'] as String?;
    final token = device['auth_token'] as String?;

    if (role == 'pos') {
      // An enrolled till syncs in the background; the demo till has no
      // backend and no worker — and no timers to leak in tests.
      if (token != null && baseUrl != null && _worker == null) {
        final api = SyncApi(baseUrl: baseUrl, token: token);
        final service = SyncService(db: widget.db, api: api);
        _worker = SyncWorker(sync: service)
          ..start(interval: const Duration(seconds: 30));
        _orderNumbers = OrderNumbers(db: widget.db, api: api);
      }
      // The demo till still gets numbers, just device-prefixed ones: it has
      // no backend to reserve from, and a counter with no number to call is
      // not a counter.
      _orderNumbers ??= OrderNumbers(db: widget.db);
      return TillScreen(
        db: widget.db,
        worker: _worker,
        orderNumbers: _orderNumbers,
        // Null on the demo path: the floor is shared state and a demo till has
        // nothing to share it with, so table service stays out of reach rather
        // than pretending.
        api: token != null && baseUrl != null
            ? SyncApi(baseUrl: baseUrl, token: token)
            : null,
      );
    }

    final api = SyncApi(baseUrl: baseUrl ?? '', token: token);
    if (role == 'kds') {
      return KdsScreen(
        api: api,
        stationNo: device['kds_station_no'] as int?,
        stationNames: widget.db.kitchenStations(),
      );
    }
    return CdsScreen(
      api: api,
      // From the device row, not a constant. A board with another
      // restaurant's name on it is worse than a board with no name.
      brandName: (device['zatca_seller_name'] as String?) ?? '',
      branchName: device['branch_name'] as String?,
      vatNumber: (device['zatca_vat_number'] as String?) ?? '',
      demo: widget.demo,
      stationNos: widget.db.kitchenStations().keys.toList()..sort(),
    );
  }
}
