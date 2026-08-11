/// Translating between a cart and a table's saved check.
///
/// A check lives on the server as flat, numbered lines so any tablet can read
/// it; a cart is a tree, because what was chosen inside a meal has to stay
/// inside it. These two functions are the only place that conversion happens,
/// which is what lets a check survive being put down on one tablet and picked
/// up on another.
///
/// Two rules are load-bearing, and both were bugs before they were rules:
///
/// - **A saved line comes back at the price it was quoted.** Re-pricing it
///   through the catalog charges whatever the menu says at payment time, and
///   on a meal's covered drink — carried at nothing — charges full price for
///   something the meal already paid for.
/// - **Structure survives.** A child names its parent, so the drink comes back
///   underneath the meal instead of looking like a drink somebody ordered.
library;

import 'pos_database.dart';

/// A cart line flattened for the session: what it is, how many, what it costs,
/// and what it was chosen inside.
///
/// Chosen items come along as their own lines so the total on the floor is the
/// total on the bill, and each names its parent by position within the batch —
/// the sender cannot know what line numbers the session is about to hand out.
/// [base] is where this line starts in that batch.
List<Map<String, dynamic>> sessionLinesFor(
  CartLine line, {
  required int Function(CartLine) priceOf,
  int base = 0,
}) {
  final out = <Map<String, dynamic>>[
    {
      'prodnum': line.product.prodnum,
      'line_des': line.product.descript,
      'qty': line.qty,
      'unit_price': priceOf(line),
      'note': ?line.note,
    },
  ];
  void addExtras(List<CartExtra> extras, double parentQty, int parentIndex) {
    for (final extra in extras) {
      final childQty = extra.qty * parentQty;
      out.add({
        'prodnum': extra.product.prodnum,
        'line_des': extra.product.descript,
        'qty': childQty,
        'unit_price': extra.unitPrice,
        'parent_index': parentIndex,
      });
      addExtras(extra.extras, childQty, base + out.length);
    }
  }

  addExtras(line.extras, line.qty, base + 1);
  return out;
}

/// Every cart line in a batch, with the check lines each one became.
///
/// The server assigns the numbers, appending the batch in the order it was
/// sent, so the last lines of the check are the ones just added. Without this
/// a split has no way to say which guest's bill paid for what.
void assignLineNumbers(
  Map<String, dynamic> detail,
  Map<CartLine, ({int from, int to})> spans,
  int count,
) {
  final numbers = [
    for (final raw in (detail['lines'] as List? ?? const []))
      ((raw as Map).cast<String, dynamic>())['line_no'] as int,
  ]..sort();
  if (numbers.length < count) return; // not ours to guess at
  final ours = numbers.sublist(numbers.length - count);
  for (final entry in spans.entries) {
    entry.key.sessionLineNos = ours.sublist(entry.value.from, entry.value.to);
  }
}

/// Rebuild a saved check into cart lines — structure, prices and all.
///
/// Lines another guest has already paid for are left out: they are settled,
/// and what is left on the table is what is still owed. [product] resolves a
/// product number against this device's catalog; a line whose product it does
/// not know is dropped rather than guessed at.
List<CartLine> restoreCheck(
  Map<String, dynamic> session,
  CatalogProduct? Function(int prodnum) product,
) {
  final rows = [
    for (final raw in (session['lines'] as List? ?? const []))
      (raw as Map).cast<String, dynamic>(),
  ]..sort((a, b) => (a['line_no'] as int).compareTo(b['line_no'] as int));

  final live = [
    for (final line in rows)
      if (line['voided'] != true && line['settled_sale_uuid'] == null) line,
  ];
  final byNo = {for (final line in live) line['line_no'] as int: line};
  final children = <int, List<Map<String, dynamic>>>{};
  for (final line in live) {
    final parent = line['parent_line_no'] as int?;
    if (parent != null && byNo.containsKey(parent)) {
      children.putIfAbsent(parent, () => []).add(line);
    }
  }

  // The session stores a qty as it was eaten; a CartExtra carries its qty per
  // one of its parent, so two meals mean two drinks. Undo the multiplication
  // the save did.
  List<CartExtra> extrasOf(int lineNo, double parentQty, List<int> claimed) {
    final out = <CartExtra>[];
    for (final child in children[lineNo] ?? const []) {
      final no = child['line_no'] as int;
      claimed.add(no);
      final qty = (child['qty'] as num).toDouble();
      final item = product(child['prodnum'] as int);
      if (item == null) continue;
      out.add(CartExtra(
        product: item,
        qty: parentQty == 0 ? qty : qty / parentQty,
        unitPrice: child['unit_price'] as int,
        extras: extrasOf(no, qty, claimed),
      ));
    }
    return out;
  }

  final restored = <CartLine>[];
  for (final line in live) {
    final parent = line['parent_line_no'] as int?;
    if (parent != null && byNo.containsKey(parent)) continue;
    final item = product(line['prodnum'] as int);
    if (item == null) continue;
    final no = line['line_no'] as int;
    final qty = (line['qty'] as num).toDouble();
    final claimed = <int>[no];
    final extras = extrasOf(no, qty, claimed);
    restored.add(CartLine(
      product: item,
      qty: qty,
      note: line['note'] as String?,
      unitPrice: line['unit_price'] as int,
      extras: extras,
      sessionLineNos: claimed,
      // Already cooked and already on the check: this is what is owed, not a
      // new round.
      sent: true,
    ));
  }
  return restored;
}
