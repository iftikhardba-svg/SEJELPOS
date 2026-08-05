/// Stamping a sale as this device's next ZATCA invoice.
///
/// This is the piece that turns a closed sale into a tax invoice: it builds
/// the UBL document, hashes it, signs the hash, and advances the device's
/// chain — **all inside the transaction that closes the sale**. That is not
/// an implementation detail. If the stamp and the chain advance could land
/// apart, a crash between them would either reuse an ICV or leave a gap, and
/// ZATCA rejects every invoice after a broken chain. One transaction, or the
/// sale did not happen.
///
/// The device's identity (VAT number, seller name, CSID) arrives at enrolment
/// and lives in the `device` row. The private key does not: see
/// [ZatcaKeyProvider].
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'hashing.dart';
import 'invoice.dart';
import 'qr.dart';

/// Where the device's private key comes from.
///
/// ZATCA mandates **secp256k1**, which Android Keystore does not support — it
/// generates and holds NIST curves only. The key therefore cannot be a
/// Keystore-resident key, and any design that assumes it can will not ship.
/// What remains is application storage with the file encrypted at rest under
/// a Keystore-held symmetric key, which is what a production implementation
/// of this interface must do. Returning null means the device is not
/// provisioned for signing yet — the till still sells, and the receipt says
/// UNSIGNED.
abstract class ZatcaKeyProvider {
  String? privatePemFor(String deviceUuid);
}

/// Keeps the key in memory only. Fine for tests and the dev/demo path; not
/// for a tablet in a restaurant.
class InMemoryKeyProvider implements ZatcaKeyProvider {
  InMemoryKeyProvider(this._pem);

  final String? _pem;

  @override
  String? privatePemFor(String deviceUuid) => _pem;
}

/// Reads the key from a PEM file in the app's private directory.
///
/// ⚠️  **Not the production implementation.** The file is plaintext: anyone
/// with filesystem access to a rooted device can lift the signing key and
/// issue invoices as this seller. The production version encrypts it at rest
/// under a Keystore-held AES key (see the key-custody note above) — this
/// exists so the app has a working key path before that lands, and so the
/// "device cannot sign yet" state is a real, exercised code path rather than
/// a hypothetical one.
///
/// No file means no key, which means unsigned receipts — the correct state
/// for a device that has not been through CSID onboarding.
class FileKeyProvider implements ZatcaKeyProvider {
  FileKeyProvider(this.directory, {this.fileName = 'zatca_key.pem'});

  final String directory;
  final String fileName;

  String get path => '$directory${Platform.pathSeparator}$fileName';

  @override
  String? privatePemFor(String deviceUuid) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final pem = file.readAsStringSync().trim();
    return pem.isEmpty ? null : pem;
  }
}

/// What a stamped sale carries onto the receipt and into the outbox.
class ZatcaStamp {
  const ZatcaStamp({
    required this.invoiceUuid,
    required this.icv,
    required this.pih,
    required this.hash,
    required this.qr,
    required this.xml,
  });

  final String invoiceUuid;
  final int icv;
  final String pih;
  final String hash;
  final String qr;
  final String xml;
}

/// Why a sale could not be stamped. Never thrown out of the sale path — an
/// unsignable sale must still be sellable — but recorded so the reason is
/// visible instead of guessed at.
class ZatcaNotConfigured implements Exception {
  ZatcaNotConfigured(this.reason);

  final String reason;

  @override
  String toString() => 'ZATCA not configured: $reason';
}

class DeviceSigner {
  DeviceSigner({required this.keys});

  final ZatcaKeyProvider keys;

  /// Stamp [saleUuid], which must already be written by the caller's open
  /// transaction. Returns null when the device is not provisioned for
  /// signing; the sale stands and prints unsigned.
  ///
  /// [invoiceUuidFactory] exists so tests can pin the UUID; production passes
  /// nothing and gets a random one.
  ZatcaStamp? stampSale(
    Database db,
    String saleUuid, {
    String Function()? invoiceUuidFactory,
  }) {
    final device = db.select('SELECT * FROM device WHERE id = 1').first;
    final unmet = _whyNotConfigured(device);
    if (unmet != null) return null;

    final pem = keys.privatePemFor(device['device_uuid'] as String);
    if (pem == null) return null;

    final sale = db
        .select('SELECT * FROM sale WHERE sale_uuid = ?', [saleUuid]).first;
    final lines = db.select(
      'SELECT * FROM sale_line WHERE sale_uuid = ? AND COALESCE(voided,0) = 0 '
      'ORDER BY line_no',
      [saleUuid],
    );
    if (lines.isEmpty) {
      throw ZatcaNotConfigured('sale $saleUuid has no lines to invoice');
    }

    final icv = device['zatca_next_icv'] as int;
    final pih = (device['zatca_last_pih'] as String?) ?? initialPih;
    final invoiceUuid = (invoiceUuidFactory ?? _randomUuid)();
    final issuedAt = DateTime.parse(sale['closed_at'] as String).toUtc();

    // Amounts are read back from the stored rows, never from UI state: the
    // invoice must describe what was recorded, not what was intended.
    final invoice = ZatcaInvoice(
      invoiceNumber: sale['receipt_no'] as String,
      uuid: invoiceUuid,
      issuedAt: issuedAt,
      seller: ZatcaParty(
        name: device['zatca_seller_name'] as String,
        vatNumber: device['zatca_vat_number'] as String,
        address: ZatcaAddress.fromJson(
          jsonDecode((device['zatca_seller_address'] as String?) ?? '{}')
              as Map<String, dynamic>,
        ),
        crNumber: (device['zatca_seller_cr'] as String?) ?? '',
      ),
      lines: [
        for (final line in lines)
          ZatcaLine(
            lineId: line['line_no'] as int,
            name: line['line_des'] as String,
            quantity: (line['qty'] as num),
            unitPrice: _unitNet(line),
            lineNet: line['net_amount'] as int,
            lineTax: line['tax_amount'] as int,
            vatPercent: (line['tax_amount'] as int) == 0 ? 0 : 15,
          ),
      ],
      icv: icv,
      pih: pih,
    );

    final built = buildAndCanonicalize(invoice);
    final hash = invoiceHash(built.canonical);

    final qr = buildQr(
      QrInput(
        sellerName: device['zatca_seller_name'] as String,
        vatNumber: device['zatca_vat_number'] as String,
        issuedAt: issuedAt,
        totalWithVat: sale['final_total'] as int,
        vatTotal: sale['tax_total'] as int,
        invoiceHash: hash,
        publicKeyDer:
            base64Decode(device['zatca_public_key'] as String),
        csidSignature: device['zatca_csid_signature'] as String,
      ),
      pem,
    );

    final xml = utf8.decode(built.xml);

    db.execute(
      'UPDATE sale SET zatca_uuid = ?, zatca_icv = ?, zatca_pih = ?, '
      '  zatca_hash = ?, zatca_qr = ? WHERE sale_uuid = ?',
      [invoiceUuid, icv, pih, hash, qr, saleUuid],
    );
    // The chain advances here and nowhere else. Same transaction as the sale
    // and the stamp above: an ICV is consumed exactly when an invoice claims
    // it.
    db.execute(
      'UPDATE device SET zatca_next_icv = ?, zatca_last_pih = ? WHERE id = 1',
      [icv + 1, hash],
    );

    return ZatcaStamp(
      invoiceUuid: invoiceUuid,
      icv: icv,
      pih: pih,
      hash: hash,
      qr: qr,
      xml: xml,
    );
  }

  /// The human-readable reason a device cannot sign, or null when it can.
  /// Surfaced in settings so "why is every receipt unsigned" has an answer.
  String? describeReadiness(Database db) {
    final device = db.select('SELECT * FROM device WHERE id = 1').first;
    final unmet = _whyNotConfigured(device);
    if (unmet != null) return unmet;
    if (keys.privatePemFor(device['device_uuid'] as String) == null) {
      return 'no signing key on this device';
    }
    return null;
  }

  static String? _whyNotConfigured(Row device) {
    for (final (column, label) in const [
      ('zatca_vat_number', 'seller VAT number'),
      ('zatca_seller_name', 'seller name'),
      ('zatca_public_key', 'device public key'),
      ('zatca_csid_signature', 'CSID signature'),
    ]) {
      final value = device[column] as String?;
      if (value == null || value.isEmpty) return 'no $label';
    }
    return null;
  }

  /// UBL wants the VAT-exclusive unit price; the sale stores the inclusive
  /// one. Derived from the line's own net so it cannot disagree with it.
  static int _unitNet(Row line) {
    final qty = (line['qty'] as num).toDouble();
    if (qty == 0) return line['net_amount'] as int;
    return ((line['net_amount'] as int) / qty).round();
  }

  static String _randomUuid() {
    // The invoice UUID is a document identifier, not a secret; sale_uuid
    // already comes from the uuid package and this mirrors its format.
    final bytes = List<int>.generate(16, (_) => _rand.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int from, int to) => bytes
        .sublist(from, to)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

final _rand = Random.secure();
