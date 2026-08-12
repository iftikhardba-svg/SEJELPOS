/// Reading an ESC/POS stream back, so a screen can show what the paper will.
///
/// The preview is decoded from **the bytes the printer is sent**, not built a
/// second time from the receipt data. That is the whole point of it: a screen
/// that renders the receipt independently can show something the printer
/// would never produce, and the first time anyone finds out is when a real
/// TM-T88V disagrees in front of a customer.
///
/// It follows that this file knows only what `escpos.dart` emits. Anything
/// else is reported as unknown rather than skipped silently — a preview that
/// quietly drops a line is worse than no preview, because it looks right.
library;

import 'dart:convert';

const _esc = 0x1B;
const _gs = 0x1D;

/// One thing on the paper.
sealed class ReceiptPart {
  const ReceiptPart();
}

/// A line of text with the attributes in force when it was printed.
class ReceiptTextPart extends ReceiptPart {
  const ReceiptTextPart({
    required this.text,
    required this.align,
    required this.bold,
    required this.doubleSize,
  });

  final String text;

  /// 0 left, 1 centre, 2 right — ESC a.
  final int align;
  final bool bold;
  final bool doubleSize;
}

/// A QR the printer will draw itself, with the payload it will draw.
class ReceiptQrPart extends ReceiptPart {
  const ReceiptQrPart(this.data, {required this.align});

  final String data;
  final int align;
}

/// Blank paper: ESC d n.
class ReceiptFeedPart extends ReceiptPart {
  const ReceiptFeedPart(this.lines);

  final int lines;
}

/// Where the paper is cut.
class ReceiptCutPart extends ReceiptPart {
  const ReceiptCutPart();
}

/// A command this decoder does not know.
///
/// Kept and shown rather than dropped: it means `escpos.dart` grew something
/// the preview has not learned, and silence would let the two drift apart
/// while looking fine.
class ReceiptUnknownPart extends ReceiptPart {
  const ReceiptUnknownPart(this.description);

  final String description;
}

/// Decode a receipt stream into what a person would see on the paper.
List<ReceiptPart> decodeReceipt(List<int> bytes) {
  final parts = <ReceiptPart>[];
  final line = <int>[];
  var align = 0;
  var bold = false;
  var double = false;

  void flush() {
    if (line.isEmpty) return;
    parts.add(ReceiptTextPart(
      text: ascii.decode(line, allowInvalid: true),
      align: align,
      bold: bold,
      doubleSize: double,
    ));
    line.clear();
  }

  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];

    if (b == 0x0A) {
      // A newline ends the line even when it is empty: the printer advances
      // the paper, so the preview has to as well.
      parts.add(ReceiptTextPart(
        text: ascii.decode(line, allowInvalid: true),
        align: align,
        bold: bold,
        doubleSize: double,
      ));
      line.clear();
      i += 1;
      continue;
    }

    if (b != _esc && b != _gs) {
      line.add(b);
      i += 1;
      continue;
    }

    // A command interrupts whatever was being typed. Printers apply the new
    // state from here on, and so does this.
    flush();

    if (b == _esc && i + 1 < bytes.length) {
      final code = bytes[i + 1];
      if (code == 0x40) {                         // ESC @ — initialise
        align = 0;
        bold = false;
        double = false;
        i += 2;
        continue;
      }
      if (code == 0x61 && i + 2 < bytes.length) { // ESC a n — align
        align = bytes[i + 2];
        i += 3;
        continue;
      }
      if (code == 0x45 && i + 2 < bytes.length) { // ESC E n — bold
        bold = bytes[i + 2] != 0;
        i += 3;
        continue;
      }
      if (code == 0x64 && i + 2 < bytes.length) { // ESC d n — feed
        parts.add(ReceiptFeedPart(bytes[i + 2]));
        i += 3;
        continue;
      }
      parts.add(ReceiptUnknownPart('ESC 0x${code.toRadixString(16)}'));
      i += 2;
      continue;
    }

    if (b == _gs && i + 1 < bytes.length) {
      final code = bytes[i + 1];
      if (code == 0x21 && i + 2 < bytes.length) { // GS ! n — character size
        double = bytes[i + 2] != 0;
        i += 3;
        continue;
      }
      if (code == 0x56 && i + 3 < bytes.length) { // GS V — cut
        parts.add(const ReceiptCutPart());
        i += 4;
        continue;
      }
      if (code == 0x28 && i + 4 < bytes.length && bytes[i + 2] == 0x6B) {
        // GS ( k — the two-dimensional symbol commands. The length is carried
        // in the two bytes after the function, so an unrecognised one can
        // still be stepped over exactly rather than guessed at.
        final length = bytes[i + 3] + (bytes[i + 4] << 8);
        final body = bytes.sublist(i + 5, i + 5 + length);
        // fn 80 ('P') with cn 49 ('1') is "store the data"; the payload is
        // everything after the two selector bytes and the m byte.
        if (body.length >= 3 && body[0] == 49 && body[1] == 80) {
          parts.add(ReceiptQrPart(
            ascii.decode(body.sublist(3), allowInvalid: true),
            align: align,
          ));
        }
        i += 5 + length;
        continue;
      }
      parts.add(ReceiptUnknownPart('GS 0x${code.toRadixString(16)}'));
      i += 2;
      continue;
    }

    // A trailing ESC or GS with nothing after it.
    parts.add(const ReceiptUnknownPart('truncated command'));
    i += 1;
  }

  flush();
  return parts;
}
