/// ESC/POS receipt bytes for 80mm Epson-class printers (TM-T88V family —
/// the printers this restaurant already runs).
///
/// Pure functions: data in, bytes out. Nothing here touches the network, so
/// every command sequence is asserted byte-for-byte in tests. The honest
/// limitation: text is ASCII/Latin for now — Arabic needs codepage selection
/// plus RTL shaping, which lands with the bilingual receipt work.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../core/money.dart';

const _esc = 0x1B;
const _gs = 0x1D;

/// 80mm paper, font A.
const _cols = 42;

class ReceiptLine {
  const ReceiptLine({
    required this.qty,
    required this.name,
    required this.amount,
    this.depth = 0,
  });

  final double qty;
  final String name;
  final int amount; // halalas, VAT-inclusive

  /// How far this line hangs off another: 0 is an item the customer chose
  /// from the menu, 1 is what they were asked about or what the meal
  /// includes, and so on. Printed as an indent — a customer checking their
  /// receipt has to be able to see that the drink came out of the meal rather
  /// than reading it as a separate item that happened to cost nothing.
  final int depth;
}

/// One tender as it goes on the paper.
class ReceiptTender {
  const ReceiptTender({
    required this.name,
    required this.amount,
    this.change = 0,
  });

  final String name;
  final int amount;

  /// Cash handed back. Printed on its own line — a customer checking the
  /// paper against their wallet is checking this number.
  final int change;
}

class ReceiptData {
  const ReceiptData({
    required this.brandName,
    required this.vatNumber,
    required this.receiptNo,
    required this.orderNo,
    required this.dateTime,
    required this.lines,
    required this.netTotal,
    required this.taxTotal,
    required this.finalTotal,
    required this.payments,
    this.zatcaQr,
  });

  final String brandName;
  final String vatNumber;
  final String receiptNo;

  /// Printed as given, because it is what the customer was told out loud. A
  /// provisional number carries its device prefix ("R01-205"), so this is a
  /// string rather than an int.
  final String? orderNo;
  final DateTime dateTime;
  final List<ReceiptLine> lines;
  final int netTotal;
  final int taxTotal;
  final int finalTotal;

  /// Every tender taken, in the order it was taken. A bill settled half on a
  /// card and half in cash has to show both, or the customer cannot check it
  /// against the two receipts their bank and their pocket give them.
  final List<ReceiptTender> payments;

  /// Base64 TLV payload from the signer. Absent until the ZATCA port lands —
  /// and an unsigned receipt says so in print rather than pretending.
  final String? zatcaQr;
}

class EscPos {
  final _out = BytesBuilder();

  List<int> get bytes => _out.toBytes();

  void init() => _out.add(const [_esc, 0x40]);

  /// 0 = left, 1 = centre, 2 = right.
  void align(int n) => _out.add([_esc, 0x61, n]);

  void bold(bool on) => _out.add([_esc, 0x45, on ? 1 : 0]);

  /// Double width + height on, or back to normal.
  void doubleSize(bool on) => _out.add([_gs, 0x21, on ? 0x11 : 0x00]);

  void text(String s) {
    _out.add(ascii.encode(_asciiSafe(s)));
    _out.add(const [0x0A]);
  }

  void feed(int n) => _out.add([_esc, 0x64, n]);

  /// Partial cut with feed — GS V 66.
  void cut() => _out.add(const [_gs, 0x56, 0x42, 0x00]);

  /// ZATCA QR: model 2, module size 6, error correction M, store, print.
  void qr(String data) {
    final payload = ascii.encode(_asciiSafe(data));
    final len = payload.length + 3;
    _out.add(const [_gs, 0x28, 0x6B, 4, 0, 49, 65, 50, 0]); // model 2
    _out.add(const [_gs, 0x28, 0x6B, 3, 0, 49, 67, 6]); // module size
    _out.add(const [_gs, 0x28, 0x6B, 3, 0, 49, 69, 49]); // EC level M
    _out.add([_gs, 0x28, 0x6B, len % 256, len ~/ 256, 49, 80, 48]);
    _out.add(payload);
    _out.add(const [_gs, 0x28, 0x6B, 3, 0, 49, 81, 48]); // print
  }

  /// Left/right columns padded to the paper width.
  void row(String left, String right) {
    var l = left;
    final max = _cols - right.length - 1;
    if (l.length > max) l = l.substring(0, max);
    text('$l${' ' * (_cols - l.length - right.length)}$right');
  }

  void rule() => text('-' * _cols);

  static String _asciiSafe(String s) =>
      String.fromCharCodes(s.runes.map((r) => r < 0x80 ? r : 0x3F)); // '?'
}

/// The customer receipt, whole and in order.
List<int> buildReceipt(ReceiptData r) {
  final p = EscPos()..init();

  p
    ..align(1)
    ..doubleSize(true)
    ..text(r.brandName)
    ..doubleSize(false)
    ..text('VAT ${r.vatNumber}')
    ..feed(1)
    ..align(0)
    ..row('Receipt ${r.receiptNo}', _stamp(r.dateTime));
  if (r.orderNo != null) {
    p
      ..align(1)
      ..doubleSize(true)
      ..text('ORDER ${r.orderNo}')
      ..doubleSize(false)
      ..align(0);
  }
  p.rule();

  for (final line in r.lines) {
    final qty = line.qty.toStringAsFixed(line.qty % 1 == 0 ? 0 : 3);
    // An included item at a quantity of one needs no "1x": it is one of the
    // thing above it. Anything else keeps the count, because "2x 1 GARLIC"
    // and "1 GARLIC" are different orders.
    final prefix = line.depth > 0 && line.qty == 1 ? '' : '$qty' 'x ';
    p.row(
      '${'  ' * line.depth}$prefix${line.name}',
      // Nothing in the amount column when the meal already covers it. A price
      // on the paper is a price the customer paid; printing 0.00 down the
      // side of every meal invites the question at the counter.
      line.depth > 0 && line.amount == 0 ? '' : formatHalalas(line.amount),
    );
  }

  p
    ..rule()
    ..row('Subtotal (excl. VAT)', formatHalalas(r.netTotal))
    ..row('VAT 15%', formatHalalas(r.taxTotal))
    ..bold(true)
    ..row('TOTAL', formatHalalas(r.finalTotal))
    ..bold(false);

  for (final payment in r.payments) {
    p.row('Paid ${payment.name}', formatHalalas(payment.amount));
  }
  final change = r.payments.fold<int>(0, (a, t) => a + t.change);
  if (change > 0) {
    p
      ..bold(true)
      ..row('CHANGE', formatHalalas(change))
      ..bold(false);
  }
  p.rule();

  if (r.zatcaQr != null) {
    p
      ..align(1)
      ..qr(r.zatcaQr!)
      ..feed(1);
  } else {
    // Until the device signs, the paper must not pretend to be a tax
    // invoice. Loud, on every receipt, by design.
    p
      ..align(1)
      ..bold(true)
      ..text('*** UNSIGNED - NOT A TAX INVOICE ***')
      ..bold(false);
  }

  p
    ..align(1)
    ..text('Shukran!')
    ..feed(3)
    ..cut();
  return p.bytes;
}

String _stamp(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}
