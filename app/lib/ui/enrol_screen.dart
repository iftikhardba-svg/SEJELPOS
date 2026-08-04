/// First-run screen: turn this tablet into a device.
///
/// Two ways in: an enrolment code from the back office (the real path — the
/// device gets its credential, then pulls its catalog), or demo mode, which
/// seeds the built-in demo catalog and goes straight to the till.
library;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../data/demo_catalog.dart';
import '../data/pos_database.dart';
import '../sync/sync_api.dart';
import '../sync/sync_service.dart';

class EnrolScreen extends StatefulWidget {
  const EnrolScreen({
    super.key,
    required this.db,
    required this.onReady,
    this.clientFactory,
  });

  final PosDatabase db;
  final VoidCallback onReady;

  /// Test seam; production uses a plain http.Client.
  final http.Client Function()? clientFactory;

  @override
  State<EnrolScreen> createState() => _EnrolScreenState();
}

class _EnrolScreenState extends State<EnrolScreen> {
  final _serverController =
      TextEditingController(text: 'http://10.0.2.2:8000');
  final _codeController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _enrol() async {
    final server = _serverController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final code = _codeController.text.trim();
    if (server.isEmpty || code.isEmpty) {
      setState(() => _error = 'Server address and enrolment code are both needed');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final api = SyncApi(
      baseUrl: server,
      client: widget.clientFactory?.call(),
    );
    final sync = SyncService(db: widget.db, api: api);
    try {
      await sync.enrolAndPrime(
        code: code,
        deviceUuid: const Uuid().v4(),
      );
      if (mounted) widget.onReady();
    } on SyncApiException catch (e) {
      setState(() => _error = e.detail);
    } on Exception catch (e) {
      setState(() => _error = 'Could not reach the server: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _demo() {
    seedDemoCatalog(widget.db);
    widget.onReady();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Set up this device',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Enter the enrolment code from the back office. It works '
                  'once and expires within a day.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _serverController,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Server address',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _codeController,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Enrolment code',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _enrol,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Enrol this device'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _demo,
                  child: const Text('Try the demo instead'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
