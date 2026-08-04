/// Price tier resolution — the Dart port must refuse exactly what the backend
/// refuses. Falling back to tier A on an aggregator order gives the commission
/// away silently; both ends fail loudly instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_app/core/pricing.dart';

void main() {
  // HUMMOS: 8.00 walk-in, 9.00 aggregator, zero-priced comp tier.
  final hummos = <int?>[800, 900, 0, null, null, null, null, null, null, 0];

  test('walk-in pays tier A', () {
    expect(priceFor(hummos, 'a'), 800);
  });

  test('aggregator pays tier B', () {
    expect(priceFor(hummos, 'b'), 900);
  });

  test('comp tier J may be zero', () {
    expect(priceFor(hummos, 'j'), 0);
  });

  test('missing paying tier refuses rather than falling back', () {
    expect(
      () => priceFor(hummos, 'd', prodnum: 2013),
      throwsA(isA<PriceUnavailable>()),
    );
  });

  test('zero on a paying tier is refused too', () {
    expect(
      () => priceFor(hummos, 'c', prodnum: 2013),
      throwsA(isA<PriceUnavailable>()),
    );
  });

  test('missing base price is refused', () {
    expect(
      () => priceFor(<int?>[0, 900], 'a', prodnum: 9),
      throwsA(isA<PriceUnavailable>()),
    );
  });

  test('unknown tier is a programming error, not a price problem', () {
    expect(() => priceFor(hummos, 'z'), throwsArgumentError);
  });
}
