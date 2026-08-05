/// Stamping a real sale, through the real till transaction.
///
/// The golden tests prove the crypto matches the Python reference. These
/// prove the thing that actually breaks in production: that the chain
/// advances exactly once per invoice, inside the sale's transaction, and that
/// a device which cannot sign still sells.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/data/pos_database.dart';
import 'package:pos_app/zatca/device_signer.dart';
import 'package:pos_app/zatca/hashing.dart';
import 'package:pos_app/zatca/qr.dart';
import 'package:pos_app/zatca/signing.dart';
import 'package:pos_app/zatca/tlv.dart';

import '../helpers.dart';

const _sellerAddress = {
  'street': 'شارع الملك فهد',
  'building': '8228',
  'district': 'العليا',
  'city': 'الرياض',
  'postal_code': '12244',
  'country': 'SA',
};

/// A device provisioned exactly as enrolment + CSID onboarding leaves it.
void _provisionForZatca(PosDatabase db, ZatcaKeyPair keys) {
  db.raw.execute(
    'UPDATE device SET zatca_vat_number = ?, zatca_seller_name = ?, '
    '  zatca_seller_cr = ?, zatca_seller_address = ?, '
    '  zatca_public_key = ?, zatca_csid_signature = ? WHERE id = 1',
    [
      '310000000000003',
      'مطعم فاطمة',
      '1010012345',
      jsonEncode(_sellerAddress),
      keys.publicKeyBase64,
      // Stands in for ZATCA's signature over the public key until sandbox
      // onboarding supplies a real CSID.
      base64Encode(utf8.encode('placeholder-csid-signature')),
    ],
  );
}

void main() {
  setUpAll(useSystemSqlite);

  late ZatcaKeyPair keys;
  late PosDatabase db;

  setUp(() {
    keys = generateKeyPair();
    db = seededDatabase(
      signer: DeviceSigner(keys: InMemoryKeyProvider(keys.privatePem)),
    );
  });

  tearDown(() => db.dispose());

  group('a provisioned device', () {
    setUp(() => _provisionForZatca(db, keys));

    test('stamps a closed sale and prints a verifiable QR', () {
      final sale = chargeOneItem(db);
      final stamp = sale.stamp;

      expect(stamp, isNotNull, reason: 'a provisioned device must sign');
      expect(stamp!.icv, 1);
      expect(stamp.pih, initialPih);

      final fields = decodeTlvBase64(stamp.qr);
      expect(utf8.decode(fields[ZatcaTag.vatNumber]!), '310000000000003');
      expect(utf8.decode(fields[ZatcaTag.sellerName]!), 'مطعم فاطمة');
      expect(utf8.decode(fields[ZatcaTag.invoiceTotal]!),
          halalasToDecimalString(sale.finalTotal));
      expect(utf8.decode(fields[ZatcaTag.vatTotal]!),
          halalasToDecimalString(sale.taxTotal));

      // The stamp must verify against the hash it covers — that is what binds
      // the QR to this document rather than any document.
      expect(
        verifySignature(
          keys.publicDer,
          utf8.decode(fields[ZatcaTag.signature]!),
          ascii.encode(stamp.hash),
        ),
        isTrue,
      );
    });

    test('the QR totals are the ones the customer actually paid', () {
      final sale = chargeOneItem(db);
      final fields = decodeTlvBase64(sale.stamp!.qr);
      final printed = utf8.decode(fields[ZatcaTag.invoiceTotal]!);
      final row = db.saleRow(sale.saleUuid);
      expect(printed, halalasToDecimalString(row['final_total'] as int));
    });

    test('the chain advances by exactly one per sale, with no gaps', () {
      final stamps = [
        for (var i = 0; i < 5; i++) chargeOneItem(db).stamp!,
      ];

      expect(stamps.map((s) => s.icv), [1, 2, 3, 4, 5]);

      // Each invoice carries the previous one's hash. A gap or a repeat here
      // is what makes ZATCA reject everything downstream.
      expect(stamps.first.pih, initialPih);
      for (var i = 1; i < stamps.length; i++) {
        expect(stamps[i].pih, stamps[i - 1].hash,
            reason: 'invoice ${i + 1} does not chain to invoice $i');
      }

      final device =
          db.raw.select('SELECT * FROM device WHERE id = 1').first;
      expect(device['zatca_next_icv'], 6);
      expect(device['zatca_last_pih'], stamps.last.hash);
    });

    test('the stamp is persisted on the sale row for the outbox to push', () {
      final sale = chargeOneItem(db);
      final row = db.saleRow(sale.saleUuid);
      expect(row['zatca_qr'], sale.stamp!.qr);
      expect(row['zatca_icv'], 1);
      expect(row['zatca_hash'], sale.stamp!.hash);
      expect(row['zatca_pih'], initialPih);
      expect(row['zatca_uuid'], isNotNull);
    });

    test('two sales never share an invoice UUID', () {
      final a = chargeOneItem(db).stamp!;
      final b = chargeOneItem(db).stamp!;
      expect(a.invoiceUuid, isNot(b.invoiceUuid));
    });

    test('readiness reports no complaint', () {
      final signer = DeviceSigner(keys: InMemoryKeyProvider(keys.privatePem));
      expect(signer.describeReadiness(db.raw), isNull);
    });
  });

  group('an unprovisioned device', () {
    test('still sells, and says why the receipt is unsigned', () {
      // No CSID material at all — the state every device is in before
      // onboarding completes.
      final sale = chargeOneItem(db);
      expect(sale.stamp, isNull);
      expect(sale.finalTotal, greaterThan(0),
          reason: 'a provisioning gap must never block a customer');

      final row = db.saleRow(sale.saleUuid);
      expect(row['zatca_qr'], isNull);
      // The outbox still holds it; the backend will reject it, visibly.
      expect(db.outboxDepth(), 1);

      final signer = DeviceSigner(keys: InMemoryKeyProvider(keys.privatePem));
      expect(signer.describeReadiness(db.raw), 'no seller VAT number');
    });

    test('a device with identity but no key reports the missing key', () {
      _provisionForZatca(db, keys);
      final signer = DeviceSigner(keys: InMemoryKeyProvider(null));
      expect(signer.describeReadiness(db.raw), 'no signing key on this device');
      expect(signer.stampSale(db.raw, chargeOneItem(db).saleUuid), isNull);
    });

    test('the ICV is not consumed when nothing was signed', () {
      chargeOneItem(db);
      final device =
          db.raw.select('SELECT * FROM device WHERE id = 1').first;
      expect(device['zatca_next_icv'], 1,
          reason: 'an unsigned sale must not burn a counter value');
      expect(device['zatca_last_pih'], isNull);
    });
  });
}
