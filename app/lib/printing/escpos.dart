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
  });

  final double qty;
  final String name;
  final int amount; // halalas, VAT-inclusive
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
    required this.payMethod,
    this.zatcaQr,
  });

  final String brandName;
  final String vatNumber;
  final String receiptNo;
  final int? orderNo;
  final DateTime dateTime;
  final List<ReceiptLine> lines;
  final int netTotal;
  final int taxTotal;
  final int finalTotal;
  final String payMethod;

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
    p.row(
      '${line.qty.toStringAsFixed(line.qty % 1 == 0 ? 0 : 3)}x ${line.name}',
      formatHalalas(line.amount),
    );
  }

  p
    ..rule()
    ..row('Subtotal (excl. VAT)', formatHalalas(r.netTotal))
    ..row('VAT 15%', formatHalalas(r.taxTotal))
    ..bold(true)
    ..row('TOTAL', formatHalalas(r.finalTotal))
    ..bold(false)
    ..row('Paid', r.payMethod)
    ..rule();

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
