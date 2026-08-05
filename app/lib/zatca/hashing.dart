/// Invoice hashing and the per-device hash chain.
///
/// Dart port of `zatca/zatca/hashing.py`. Every ZATCA invoice carries the
/// hash of the one before it (PIH), forming a chain per EGS unit. Because
/// each tablet is its own EGS unit, **each tablet owns its own chain and its
/// own counter** — chains are never shared, merged, or restarted. The chain
/// state lives in the `device` row and advances inside the same transaction
/// that closes the sale.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

Uint8List sha256Bytes(List<int> data) =>
    SHA256Digest().process(Uint8List.fromList(data));

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// ZATCA's documented seed for the first invoice in a chain: the SHA-256 hex
/// digest of the string "0", base64-encoded.
final String initialPih =
    base64Encode(ascii.encode(_hex(sha256Bytes(ascii.encode('0')))));

/// base64(SHA-256(canonicalised invoice XML)).
String invoiceHash(List<int> canonicalXml) =>
    base64Encode(sha256Bytes(canonicalXml));

/// Where one device's invoice chain currently stands.
///
/// `icv` is the counter for the **next** invoice. It must increase by exactly
/// one per invoice and must never be reused: a gap or a repeat breaks the
/// chain and ZATCA rejects everything after it.
class ChainState {
  const ChainState({this.icv = 1, this.storedPih});

  final int icv;

  /// Null on a device that has issued nothing yet — [pih] then seeds the
  /// chain, rather than a caller having to know the seed value.
  final String? storedPih;

  String get pih => storedPih ?? initialPih;

  ChainState advance(String newHash) =>
      ChainState(icv: icv + 1, storedPih: newHash);
}
