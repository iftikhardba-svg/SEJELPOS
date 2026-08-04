/// Money arithmetic — must agree with the backend to the halala.
///
/// The pinned values are not invented: they are the numbers the backend's
/// tests assert, derived from the first customer's real sales.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/core/money.dart';

void main() {
  group('formatHalalas', () {
    test('formats known values', () {
      expect(formatHalalas(0), '0.00');
      expect(formatHalalas(65), '0.65');
      expect(formatHalalas(3800), '38.00');
      expect(formatHalalas(2520), '25.20');
      expect(formatHalalas(-500), '-5.00');
    });
  });

  group('splitInclusive', () {
    test('pins the backend parity values', () {
      // HUMMOS tier A: 8.00 -> 6.96 + 1.04
      expect(splitInclusive(800), (net: 696, tax: 104));
      // HUMMOS tier B: 9.00 -> 7.83 + 1.17
      expect(splitInclusive(900), (net: 783, tax: 117));
      // MOUSHAKAL SABAH: 38.00 -> 33.04 + 4.96
      expect(splitInclusive(3800), (net: 3304, tax: 496));
      // The CDS demo order: 106.00 -> 92.17 + 13.83
      expect(splitInclusive(10600), (net: 9217, tax: 1383));
    });

    test('never loses a halala across the whole price range', () {
      for (var gross = 0; gross <= 30000; gross++) {
        final s = splitInclusive(gross);
        expect(s.net + s.tax, gross, reason: 'broke at $gross');
      }
    });
  });

  group('lineTotal', () {
    test('rounds once, on the line, not per unit', () {
      expect(lineTotal(800, 2), 1600);
      expect(lineTotal(333, 0.5), 167); // weighed item
    });
  });
}
