/// Device setup — the screen that makes a till usable in a real restaurant.
///
/// Everything here is per-device state that no back office can set for us:
/// which printer this till talks to, and whether this device is actually able
/// to issue a legal invoice. Without the printer field the receipt path is
/// dead code — `printer_host` starts null and nothing else ever writes it, so
/// every sale would complete and print nothing.
///
/// The read-only panels exist because the two questions a support call opens
/// with are "is it talking to the server" and "why does the receipt say
/// UNSIGNED". Both are answered here rather than by reading the database over
/// someone's shoulder.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Aliased: sqlite3 exports a `Row` too, and Flutter's Row widget is used
// heavily on this screen.
import 'package:sqlite3/sqlite3.dart' as sql;

import '../data/pos_database.dart';
import '../printing/escpos.dart';
import '../printing/printer.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.db,
    this.sendBytes,
  });

  final PosDatabase db;

  /// Test seam for the printer transport.
  final SendBytes? sendBytes;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final device = _device();
    _hostController =
        TextEditingController(text: (device['printer_host'] as String?) ?? '');
    _portController = TextEditingController(
        text: ((device['printer_port'] as int?) ?? 9100).toString());
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  sql.Row _device() =>
      widget.db.raw.select('SELECT * FROM device WHERE id = 1').first;

  // ---------------------------------------------------------------- actions

  /// An empty host clears the setting rather than storing '': the print path
  /// tests for null-or-empty, and a blank string that looks configured but
  /// resolves to nothing is the worse of the two failures.
  void _savePrinter() {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _toast('Port must be a number between 1 and 65535');
      return;
    }
    widget.db.raw.execute(
      'UPDATE device SET printer_host = ?, printer_port = ? WHERE id = 1',
      [host.isEmpty ? null : host, port],
    );
    setState(() {});
    _toast(host.isEmpty ? 'Printer cleared' : 'Printer saved');
  }

  /// Prints a real receipt through the real builder — a test that only opened
  /// a socket would pass on a printer that cannot render our bytes.
  Future<void> _testPrint() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 9100;
    if (host.isEmpty) {
      _toast('Enter the printer address first');
      return;
    }

    setState(() => _testing = true);
    try {
      await ReceiptPrinter(host: host, port: port, send: widget.sendBytes)
          .print(buildReceipt(ReceiptData(
        brandName: (_device()['zatca_seller_name'] as String?) ?? 'POS',
        vatNumber: (_device()['zatca_vat_number'] as String?) ?? '',
        receiptNo: 'TEST',
        orderNo: null,
        dateTime: DateTime.now(),
        lines: [ReceiptLine(qty: 1, name: 'PRINTER TEST', amount: 0)],
        netTotal: 0,
        taxTotal: 0,
        finalTotal: 0,
        payMethod: 'None',
        // Deliberately unsigned: a test slip is not a tax document, and the
        // banner says so on the paper.
        zatcaQr: null,
      )));
      if (mounted) _toast('Test slip sent to $host:$port');
    } on Exception catch (e) {
      if (mounted) _toast('Could not reach the printer: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    final device = _device();

    return Scaffold(
      appBar: AppBar(title: const Text('Device setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section(context, 'Receipt printer'),
          const Text(
            'The ESC/POS printer on this branch LAN. Leave the address empty '
            'to run this till without paper.',
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostController,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Printer address',
                    hintText: '192.168.1.50',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Port',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: _testing ? null : _savePrinter,
                child: const Text('Save'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _testing ? null : _testPrint,
                child: _testing
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Print a test slip'),
              ),
            ],
          ),

          _section(context, 'This device'),
          _row('Role', (device['role'] as String? ?? 'pos').toUpperCase()),
          _row('Receipt prefix', device['receipt_prefix'] as String? ?? '—'),
          _row('Next receipt', '${device['next_receipt_seq']}'),
          _row('Station', '${device['station_no']}'),
          _row('Server', device['api_base_url'] as String? ?? 'not enrolled'),

          _section(context, 'ZATCA e-invoicing'),
          _zatcaStatus(context, device),

          _section(context, 'Sync'),
          _row('Sales waiting to send', '${_pendingSales()}'),
          _row('Sales the server refused', '${_failedSales()}',
              warn: _failedSales() > 0),
          _row('Catalog version', '${_catalogVersion()}'),
        ],
      ),
    );
  }

  /// The answer to "why does this receipt say UNSIGNED". Readiness is asked of
  /// the signer the till actually uses, so this cannot drift from what happens
  /// at charge time.
  Widget _zatcaStatus(BuildContext context, sql.Row device) {
    final scheme = Theme.of(context).colorScheme;
    final signer = widget.db.signer;
    final problem = signer == null
        ? 'this build has no signer wired'
        : signer.describeReadiness(widget.db.raw);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: problem == null
                ? scheme.primaryContainer
                : scheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            problem == null
                ? 'Signing invoices. Receipts carry a ZATCA QR.'
                : 'NOT signing — $problem.\nReceipts print an UNSIGNED banner '
                    'and the server will refuse these sales.',
            style: TextStyle(
              color: problem == null
                  ? scheme.onPrimaryContainer
                  : scheme.onErrorContainer,
            ),
          ),
        ),
        const SizedBox(height: 8),
        _row('Seller', device['zatca_seller_name'] as String? ?? '—'),
        _row('VAT number', device['zatca_vat_number'] as String? ?? '—'),
        _row('Next invoice counter', '${device['zatca_next_icv']}'),
      ],
    );
  }

  int _pendingSales() => widget.db.raw
      .select("SELECT COUNT(*) AS n FROM outbox WHERE entity = 'sale' "
          'AND last_error IS NULL')
      .first['n'] as int;

  int _failedSales() => widget.db.raw
      .select("SELECT COUNT(*) AS n FROM outbox WHERE entity = 'sale' "
          'AND last_error IS NOT NULL')
      .first['n'] as int;

  int _catalogVersion() {
    final rows = widget.db.raw.select(
        "SELECT last_version FROM sync_state WHERE table_name = 'catalog'");
    return rows.isEmpty ? 0 : rows.first['last_version'] as int;
  }

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 28, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _row(String label, String value, {bool warn = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 180, child: Text(label)),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: warn ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ),
          ],
        ),
      );
}
