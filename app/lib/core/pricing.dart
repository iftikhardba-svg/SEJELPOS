/// Which price a product rings at.
///
/// A restaurant charges different prices for the same dish depending on how
/// the order reaches the customer: walk-in trade pays tier A, delivery
/// aggregators pay tier B (the difference is their commission), staff meals
/// and press comps pay tier J, which is zero. This is the Dart port of the
/// backend's `pricing.py` and must agree with it exactly.
library;

/// The product's price tiers, halalas, VAT-inclusive. Index 0 = tier A.
typedef PriceTiers = List<int?>;

const tierLetters = 'abcdefghij';

class PriceUnavailable implements Exception {
  PriceUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The VAT-inclusive halalas a product rings at on [tier] ('a'..'j').
///
/// A comp tier (J) is allowed to be zero — that is a real price. On a paying
/// tier a zero or missing price must NOT silently fall back to tier A: that
/// would undercharge an aggregator order by the commission on every line, and
/// nobody would notice until the monthly reconciliation. Refusing the sale so
/// someone fixes the price is the cheaper failure.
int priceFor(PriceTiers tiers, String tier, {int prodnum = 0}) {
  final index = tierLetters.indexOf(tier);
  if (index < 0 || tier.length != 1) {
    throw ArgumentError('unknown price tier "$tier"');
  }
  final value = index < tiers.length ? tiers[index] : null;
  final isComp = tier == 'j';

  if (value == null || (value == 0 && !isComp)) {
    if (tier == 'a') {
      throw PriceUnavailable('product $prodnum has no base price');
    }
    throw PriceUnavailable(
      'product $prodnum has no price on tier ${tier.toUpperCase()}; '
      'it cannot be sold on this order type until one is set',
    );
  }
  return value;
}
