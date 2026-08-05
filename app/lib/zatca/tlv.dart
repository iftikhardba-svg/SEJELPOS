/// TLV encoding for the ZATCA invoice QR code.
///
/// Dart port of `zatca/zatca/tlv.py` — the reference implementation. The two
/// must produce identical bytes; `test/zatca/` replays golden vectors
/// generated from the Python side to prove it.
///
/// The QR payload is a base64-encoded sequence of tag-length-value triples.
/// Each tag and each length is a single byte, so no value may exceed 255
/// bytes — true for every field ZATCA defines, but enforced rather than
/// assumed. Lengths count BYTES, not characters: an Arabic seller name is the
/// case that catches implementations counting the wrong one.
library;

import 'dart:convert';
import 'dart:typed_data';

const int maxTlvValue = 255;

/// Tags (ZATCA Phase 2, simplified tax invoice).
abstract final class ZatcaTag {
  static const int sellerName = 1;
  static const int vatNumber = 2;
  static const int timestamp = 3;
  static const int invoiceTotal = 4;
  static const int vatTotal = 5;
  static const int invoiceHash = 6;
  static const int signature = 7;
  static const int publicKey = 8;
  static const int csidSignature = 9;
}

/// [value] is a [String] (UTF-8 encoded) or a byte list.
Uint8List encodeTlvField(int tag, Object value) {
  final raw = value is String
      ? utf8.encode(value)
      : Uint8List.fromList(value as List<int>);
  if (raw.length > maxTlvValue) {
    throw ArgumentError(
      'tag $tag: value is ${raw.length} bytes, over the '
      '$maxTlvValue-byte single-byte-length limit',
    );
  }
  if (tag < 0 || tag > 255) {
    throw ArgumentError('tag $tag out of range');
  }
  return Uint8List.fromList([tag, raw.length, ...raw]);
}

/// Encode fields in ascending tag order, as ZATCA expects.
Uint8List encodeTlv(Map<int, Object> fields) {
  final tags = fields.keys.toList()..sort();
  final out = BytesBuilder(copy: false);
  for (final tag in tags) {
    out.add(encodeTlvField(tag, fields[tag]!));
  }
  return out.toBytes();
}

String encodeTlvBase64(Map<int, Object> fields) => base64Encode(encodeTlv(fields));

/// Parse a TLV sequence. Used by tests and by tooling that inspects a QR.
Map<int, Uint8List> decodeTlv(Uint8List payload) {
  final out = <int, Uint8List>{};
  var i = 0;
  while (i < payload.length) {
    if (i + 2 > payload.length) {
      throw FormatException('truncated TLV header at byte $i');
    }
    final tag = payload[i];
    final length = payload[i + 1];
    i += 2;
    if (i + length > payload.length) {
      throw FormatException(
        'tag $tag claims $length bytes but only ${payload.length - i} remain',
      );
    }
    out[tag] = payload.sublist(i, i + length);
    i += length;
  }
  return out;
}

Map<int, Uint8List> decodeTlvBase64(String payload) =>
    decodeTlv(base64Decode(payload));
