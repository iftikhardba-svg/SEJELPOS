/// POS app entry point.
///
/// Boot decides between two screens: a device that has enrolled (or seeded the
/// demo) goes to its role's screen; a fresh one gets the enrolment screen.
/// The database is a file under the app's support directory — a restart, a
/// crash or an update must never cost a sale.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/pos_database.dart';
import 'sync/sync_api.dart';
import 'sync/sync_service.dart';
import 'sync/sync_worker.dart';
import 'ui/cds_screen.dart';
import 'ui/enrol_screen.dart';
import 'ui/kds_screen.dart';
import 'ui/till_screen.dart';
import 'zatca/device_signer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final schema = await rootBundle.loadString('assets/schema.sql');
  final dir = await getApplicationSupportDirectory();
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
  runApp(PosApp(db: db));
}

class PosApp extends StatefulWidget {
  const PosApp({super.key, required this.db});

  final PosDatabase db;

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  late bool _ready;
  SyncWorker? _worker;

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
        final service = SyncService(
          db: widget.db,
          api: SyncApi(baseUrl: baseUrl, token: token),
        );
        _worker = SyncWorker(sync: service)
          ..start(interval: const Duration(seconds: 30));
      }
      return TillScreen(db: widget.db, worker: _worker);
    }

    final api = SyncApi(baseUrl: baseUrl ?? '', token: token);
    if (role == 'kds') {
      return KdsScreen(
        api: api,
        stationNo: device['kds_station_no'] as int?,
        stationNames: widget.db.kitchenStations(),
      );
    }
    return CdsScreen(api: api);
  }
}
