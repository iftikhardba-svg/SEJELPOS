/// Assemble the ZATCA invoice QR payload.
///
/// Dart port of `zatca/zatca/qr.py`. This is what gets printed on the
/// customer's receipt. It is produced on the device, at the moment of sale,
/// with no network — which is the whole reason each tablet holds its own
/// CSID.
///
/// Money arrives as integer halalas (as it is stored everywhere else) and is
/// formatted to two decimals only at this boundary, because ZATCA wants a
/// decimal string. The conversion is integer division, never float
/// arithmetic.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'signing.dart';
import 'tlv.dart';

/// 1234 -> '12.34'. Integer maths only; no float ever touches a total.
String halalasToDecimalString(int halalas) {
  if (halalas < 0) {
    throw ArgumentError('amount cannot be negative');
  }
  return '${halalas ~/ 100}.${(halalas % 100).toString().padLeft(2, '0')}';
}

/// ISO 8601 in UTC with a trailing Z, no microseconds.
String zatcaTimestamp(DateTime when) {
  final utc = when.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}T'
      '${utc.hour.toString().padLeft(2, '0')}:'
      '${utc.minute.toString().padLeft(2, '0')}:'
      '${utc.second.toString().padLeft(2, '0')}Z';
}

class QrInput {
  const QrInput({
    required this.sellerName,
    required this.vatNumber,
    required this.issuedAt,
    required this.totalWithVat,
    required this.vatTotal,
    required this.invoiceHash,
    required this.publicKeyDer,
    required this.csidSignature,
  });

  /// Arabic name as registered with ZATCA.
  final String sellerName;

  /// 15 digits.
  final String vatNumber;
  final DateTime issuedAt;

  /// halalas
  final int totalWithVat;

  /// halalas
  final int vatTotal;

  /// base64
  final String invoiceHash;
  final Uint8List publicKeyDer;

  /// base64, ZATCA's signature over the public key.
  final String csidSignature;
}

/// Return the base64 TLV payload to encode as a QR on the receipt.
String buildQr(QrInput data, String privatePem) {
  if (data.vatNumber.length != 15 ||
      !RegExp(r'^\d{15}$').hasMatch(data.vatNumber)) {
    throw ArgumentError('VAT registration number must be 15 digits');
  }
  if (data.vatTotal > data.totalWithVat) {
    throw ArgumentError('VAT cannot exceed the invoice total');
  }

  // The stamp is over the invoice hash, which is what binds the QR to the
  // document it was printed for.
  final signature = signDigest(privatePem, ascii.encode(data.invoiceHash));

  return encodeTlvBase64({
    ZatcaTag.sellerName: data.sellerName,
    ZatcaTag.vatNumber: data.vatNumber,
    ZatcaTag.timestamp: zatcaTimestamp(data.issuedAt),
    ZatcaTag.invoiceTotal: halalasToDecimalString(data.totalWithVat),
    ZatcaTag.vatTotal: halalasToDecimalString(data.vatTotal),
    ZatcaTag.invoiceHash: data.invoiceHash,
    ZatcaTag.signature: signature,
    ZatcaTag.publicKey: data.publicKeyDer,
    ZatcaTag.csidSignature: data.csidSignature,
  });
}

/// Decode a QR payload for support and debugging.
Map<String, String> inspectQr(String qrBase64) {
  const names = {
    ZatcaTag.sellerName: 'seller_name',
    ZatcaTag.vatNumber: 'vat_number',
    ZatcaTag.timestamp: 'timestamp',
    ZatcaTag.invoiceTotal: 'total_with_vat',
    ZatcaTag.vatTotal: 'vat_total',
    ZatcaTag.invoiceHash: 'invoice_hash',
    ZatcaTag.signature: 'signature',
    ZatcaTag.publicKey: 'public_key',
    ZatcaTag.csidSignature: 'csid_signature',
  };
  final out = <String, String>{};
  decodeTlvBase64(qrBase64).forEach((tag, value) {
    final key = names[tag] ?? 'tag_$tag';
    if (tag == ZatcaTag.publicKey) {
      out[key] = '<${value.length} bytes>';
    } else {
      try {
        out[key] = utf8.decode(value);
      } on FormatException {
        out[key] = '<${value.length} bytes>';
      }
    }
  });
  return out;
}
