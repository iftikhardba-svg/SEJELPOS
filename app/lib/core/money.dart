/// Money.
///
/// Every amount in this app is an integer count of halalas (1 SAR = 100).
/// Never a double: binary floating point drifts, and a tax invoice that is off
/// by a halala is wrong. The backend, the migration tooling and the ZATCA
/// library all follow the same rule — this file is the Dart end of it.
library;

/// 1234 -> "12.34". Integer arithmetic only.
String formatHalalas(int halalas) {
  final sign = halalas < 0 ? '-' : '';
  final a = halalas.abs();
  final whole = a ~/ 100;
  final cents = (a % 100).toString().padLeft(2, '0');
  return '$sign$whole.$cents';
}

/// The VAT split of a VAT-inclusive amount.
///
/// Tax is the remainder, never computed independently, so `net + tax` is
/// always exactly the gross the customer pays. This must produce the same
/// numbers as the backend's `split_inclusive` — there is a test that pins the
/// known values from real sales.
({int net, int tax}) splitInclusive(int gross, {int vatPercent = 15}) {
  final net = ((gross * 100) / (100 + vatPercent)).round();
  return (net: net, tax: gross - net);
}

/// "12.50" -> 1250, for amounts a cashier types in. Null if it is not one.
///
/// Parsed as digits rather than through `double`: 0.1 + 0.2 is the reason
/// nothing else in this app touches floating point for money, and a tender
/// that lands a halala out is a drawer that does not balance at close.
int? parseHalalas(String input) {
  final text = input.trim().replaceAll(',', '.');
  if (text.isEmpty) return null;
  if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(text)) return null;

  final dot = text.indexOf('.');
  if (dot < 0) return int.parse(text) * 100;
  final whole = text.substring(0, dot);
  final fraction = text.substring(dot + 1).padRight(2, '0');
  return int.parse(whole.isEmpty ? '0' : whole) * 100 + int.parse(fraction);
}

/// Line total for a quantity at a unit price, in halalas.
///
/// Quantities can be fractional (weighed items), so the rounding happens once,
/// on the line total — not per unit.
int lineTotal(int unitPrice, double qty) => (unitPrice * qty).round();
