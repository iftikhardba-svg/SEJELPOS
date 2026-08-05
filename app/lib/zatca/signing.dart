/// ECDSA signing for ZATCA cryptographic stamps.
///
/// Dart port of `zatca/zatca/signing.py`. ZATCA requires **secp256k1** with
/// SHA-256. Each device holds its own key pair and its own CSID, so each
/// tablet can stamp invoices with no network — the only reason offline
/// billing is possible at all.
///
/// **Key custody — corrected.** The schema comment and the Python module both
/// say the private key belongs in the Android Keystore. That is not
/// achievable: Android Keystore generates and holds NIST curves (P-256/384/
/// 521) only, and ZATCA mandates secp256k1, which it will not accept. The key
/// therefore has to live in application storage. What the Keystore *can* do
/// is hold a symmetric key that encrypts it at rest — see
/// [EncryptedKeyStore] in `key_store.dart`. This module deals only in key
/// material handed to it; it never reads or writes storage itself.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:pointycastle/api.dart';

import 'dart:math' show Random;

final ECDomainParameters zatcaCurve = ECCurve_secp256k1();

/// OIDs for a secp256k1 SubjectPublicKeyInfo.
const List<int> _oidEcPublicKey = [1, 2, 840, 10045, 2, 1];
const List<int> _oidSecp256k1 = [1, 3, 132, 0, 10];

class ZatcaKeyPair {
  ZatcaKeyPair({required this.privatePem, required this.publicDer});

  /// PKCS#8 PEM. Same format the Python reference emits, so a key generated
  /// on either side works on the other.
  final String privatePem;

  /// SubjectPublicKeyInfo DER — QR tag 8 carries these bytes verbatim.
  final Uint8List publicDer;

  String get publicKeyBase64 => base64Encode(publicDer);
}

SecureRandom _secureRandom() {
  final random = FortunaRandom();
  final seed = Uint8List(32);
  final rng = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = rng.nextInt(256);
  }
  random.seed(KeyParameter(seed));
  return random;
}

ZatcaKeyPair generateKeyPair() {
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(zatcaCurve),
        _secureRandom()));
  final pair = generator.generateKeyPair();
  final private = pair.privateKey;
  final public = pair.publicKey;
  return ZatcaKeyPair(
    privatePem: encodePrivateKeyPem(private, public),
    publicDer: encodePublicKeyDer(public),
  );
}

// ------------------------------------------------------------- DER writing
//
// Written by hand rather than through pointycastle's ASN1 builders: the
// output has to be byte-exact (it is hashed, and it is what ZATCA parses),
// and DER for the handful of structures below is small enough that owning it
// beats depending on a library's encoding choices.

Uint8List _derLength(int length) {
  if (length < 0x80) return Uint8List.fromList([length]);
  final bytes = <int>[];
  var n = length;
  while (n > 0) {
    bytes.insert(0, n & 0xff);
    n >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _der(int tag, List<int> content) =>
    Uint8List.fromList([tag, ..._derLength(content.length), ...content]);

Uint8List _derSequence(List<List<int>> parts) =>
    _der(0x30, parts.expand((p) => p).toList());

Uint8List _derInteger(BigInt value) {
  if (value == BigInt.zero) return _der(0x02, const [0]);
  final bytes = <int>[];
  var v = value;
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xff)).toInt());
    v = v >> 8;
  }
  // DER integers are signed; a leading bit set would read as negative.
  if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _der(0x02, bytes);
}

Uint8List _derOctetString(List<int> octets) => _der(0x04, octets);

/// BIT STRING with no unused trailing bits — the only form we emit.
Uint8List _derBitString(List<int> bits) => _der(0x03, [0, ...bits]);

Uint8List _derOid(List<int> arcs) {
  final content = <int>[arcs[0] * 40 + arcs[1]];
  for (final arc in arcs.skip(2)) {
    final chunks = <int>[arc & 0x7f];
    var n = arc >> 7;
    while (n > 0) {
      chunks.insert(0, (n & 0x7f) | 0x80);
      n >>= 7;
    }
    content.addAll(chunks);
  }
  return _der(0x06, content);
}

// ---------------------------------------------------------------- encoding

Uint8List _bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

/// Uncompressed point: 0x04 || X || Y, both padded to the field size.
Uint8List encodePoint(ECPublicKey key) {
  final q = key.Q!;
  final x = _bigIntToBytes(q.x!.toBigInteger()!, 32);
  final y = _bigIntToBytes(q.y!.toBigInteger()!, 32);
  return Uint8List.fromList([0x04, ...x, ...y]);
}

Uint8List _algorithmIdentifier() => _derSequence([
      _derOid(_oidEcPublicKey),
      _derOid(_oidSecp256k1),
    ]);

Uint8List encodePublicKeyDer(ECPublicKey key) => _derSequence([
      _algorithmIdentifier(),
      _derBitString(encodePoint(key)),
    ]);

String _pem(String label, Uint8List der) {
  final body = base64Encode(der);
  final lines = <String>[];
  for (var i = 0; i < body.length; i += 64) {
    lines.add(body.substring(i, i + 64 > body.length ? body.length : i + 64));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

/// PKCS#8 PrivateKeyInfo wrapping an RFC 5915 ECPrivateKey.
String encodePrivateKeyPem(ECPrivateKey private, ECPublicKey public) {
  final ecPrivateKey = _derSequence([
    _derInteger(BigInt.one),
    _derOctetString(_bigIntToBytes(private.d!, 32)),
    // [1] publicKey BIT STRING. [0] params is omitted — the algorithm
    // identifier above already names the curve.
    _der(0xa1, _derBitString(encodePoint(public))),
  ]);

  return _pem(
    'PRIVATE KEY',
    _derSequence([
      _derInteger(BigInt.zero),
      _algorithmIdentifier(),
      _derOctetString(ecPrivateKey),
    ]),
  );
}

Uint8List _pemBody(String pem) {
  final body = pem
      .split('\n')
      .where((line) => !line.startsWith('-----') && line.trim().isNotEmpty)
      .join();
  return base64Decode(body);
}

/// Load a PKCS#8 PEM private key, checking it is on the curve ZATCA requires.
ECPrivateKey loadPrivateKey(String privatePem) {
  final parser = ASN1Parser(_pemBody(privatePem));
  final pkcs8 = parser.nextObject() as ASN1Sequence;
  final algorithm = pkcs8.elements![1] as ASN1Sequence;
  final curveOid =
      (algorithm.elements![1] as ASN1ObjectIdentifier).objectIdentifierAsString;
  if (curveOid != _oidSecp256k1.join('.')) {
    throw ArgumentError(
      'key uses curve $curveOid; ZATCA requires secp256k1 '
      '(${_oidSecp256k1.join('.')})',
    );
  }
  final inner = ASN1Parser(
    Uint8List.fromList((pkcs8.elements![2] as ASN1OctetString).octets!),
  ).nextObject() as ASN1Sequence;
  final d = (inner.elements![1] as ASN1OctetString).octets!;
  var value = BigInt.zero;
  for (final byte in d) {
    value = (value << 8) | BigInt.from(byte);
  }
  return ECPrivateKey(value, zatcaCurve);
}

ECPublicKey loadPublicKeyDer(Uint8List der) {
  final spki = ASN1Parser(der).nextObject() as ASN1Sequence;
  final bits = spki.elements![1] as ASN1BitString;
  final point = Uint8List.fromList(bits.stringValues!);
  return ECPublicKey(zatcaCurve.curve.decodePoint(point), zatcaCurve);
}

/// DER SEQUENCE { INTEGER r, INTEGER s } — the encoding ZATCA expects and
/// the one Python's `cryptography` produces.
Uint8List encodeSignatureDer(ECSignature signature) => _derSequence([
      _derInteger(signature.r),
      _derInteger(signature.s),
    ]);

ECSignature decodeSignatureDer(Uint8List der) {
  final sequence = ASN1Parser(der).nextObject() as ASN1Sequence;
  return ECSignature(
    (sequence.elements![0] as ASN1Integer).integer!,
    (sequence.elements![1] as ASN1Integer).integer!,
  );
}

// ----------------------------------------------------------------- signing

/// Sign [payload] and return the DER signature, base64-encoded.
String signDigest(String privatePem, List<int> payload) {
  final signer = ECDSASigner(SHA256Digest())
    ..init(
      true,
      ParametersWithRandom(
        PrivateKeyParameter<ECPrivateKey>(loadPrivateKey(privatePem)),
        _secureRandom(),
      ),
    );
  final signature =
      signer.generateSignature(Uint8List.fromList(payload)) as ECSignature;
  return base64Encode(encodeSignatureDer(signature));
}

bool verifySignature(Uint8List publicDer, String signatureB64,
    List<int> payload) {
  try {
    final signer = ECDSASigner(SHA256Digest())
      ..init(false,
          PublicKeyParameter<ECPublicKey>(loadPublicKeyDer(publicDer)));
    return signer.verifySignature(
      Uint8List.fromList(payload),
      decodeSignatureDer(base64Decode(signatureB64)),
    );
  } catch (_) {
    return false;
  }
}

// -------------------------------------------------------------- onboarding

/// The EGS unit serial ZATCA expects: `1-<vendor>|2-<model>|3-<device uuid>`.
String egsSerial(String vendor, String model, String deviceUuid) {
  for (final (part, label) in [
    (vendor, 'vendor'),
    (model, 'model'),
    (deviceUuid, 'uuid'),
  ]) {
    if (part.isEmpty || part.contains('|')) {
      throw ArgumentError("$label must be non-empty and contain no '|'");
    }
  }
  return '1-$vendor|2-$model|3-$deviceUuid';
}
