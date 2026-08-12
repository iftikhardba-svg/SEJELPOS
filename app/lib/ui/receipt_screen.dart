/// The receipt, on screen.
///
/// A till with no printer plugged in — a demo on a laptop, a new site before
/// the hardware arrives, a printer out of paper — still has to be able to
/// show a customer their invoice. And a cashier needs to be able to look at
/// the last one without reprinting it.
///
/// It renders the **same bytes the printer is sent**, decoded back by
/// `escpos_preview.dart`. Building the picture separately from the receipt
/// data would let the screen and the paper disagree, and a screen nobody
/// checks against paper is exactly where that would not be noticed.
///
/// The QR is drawn here rather than described: on paper the printer draws it
/// from the payload in the stream, so on screen this does the same, from the
/// same payload. A ZATCA QR a phone can actually scan is the point of showing
/// one at all.
library;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../printing/escpos_preview.dart';

class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({
    super.key,
    required this.bytes,
    this.title = 'Receipt',
    this.note,
    this.onPrint,
  });

  /// Exactly what would go down the wire to the printer.
  final List<int> bytes;
  final String title;

  /// Why this is on screen rather than on paper, when there is a reason.
  final String? note;

  /// Offered when a printer is configured, so one can be reprinted from here.
  final Future<void> Function()? onPrint;

  @override
  Widget build(BuildContext context) {
    final parts = decodeReceipt(bytes);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (onPrint != null)
            TextButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await onPrint!();
                messenger.showSnackBar(
                  const SnackBar(content: Text('Sent to the printer')),
                );
              },
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              if (note != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Text(
                    note!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ReceiptPaper(parts: parts),
            ],
          ),
        ),
      ),
    );
  }
}

/// 80mm of paper. The width is fixed in characters, not pixels: the printer
/// lays out in 42 columns and so does `escpos.dart`, so anything that fits
/// there fits here and a line that would wrap on paper wraps here too.
class ReceiptPaper extends StatelessWidget {
  const ReceiptPaper({super.key, required this.parts});

  final List<ReceiptPart> parts;

  static const _columns = 42;
  static const _fontSize = 13.0;

  @override
  Widget build(BuildContext context) {
    // Monospace, measured, so the column arithmetic on the paper lands on
    // screen. A proportional font would put the amounts anywhere.
    final painter = TextPainter(
      text: const TextSpan(
        text: '0',
        style: TextStyle(fontFamily: 'monospace', fontSize: _fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width * _columns;

    return Container(
      width: width + 32,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: const [
          BoxShadow(blurRadius: 12, color: Color(0x33000000)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final part in parts) ..._draw(part, width),
        ],
      ),
    );
  }

  List<Widget> _draw(ReceiptPart part, double width) {
    switch (part) {
      case ReceiptTextPart(:final text, :final align, :final bold,
          :final doubleSize):
        return [
          Text(
            text,
            textAlign: switch (align) {
              1 => TextAlign.center,
              2 => TextAlign.right,
              _ => TextAlign.left,
            },
            style: TextStyle(
              fontFamily: 'monospace',
              // Double size on the printer is double width AND height; on
              // screen one size covers both, and the 42-column grid still
              // holds because the wide lines are the centred ones.
              fontSize: doubleSize ? _fontSize * 1.8 : _fontSize,
              fontWeight:
                  bold || doubleSize ? FontWeight.bold : FontWeight.normal,
              color: Colors.black,
              height: 1.35,
            ),
          ),
        ];
      case ReceiptQrPart(:final data):
        return [
          const SizedBox(height: 8),
          Center(child: _Qr(data: data, size: width * 0.62)),
          const SizedBox(height: 8),
        ];
      case ReceiptFeedPart(:final lines):
        return [SizedBox(height: _fontSize * 1.35 * lines)];
      case ReceiptCutPart():
        return [const SizedBox(height: 8), const _CutLine()];
      case ReceiptUnknownPart(:final description):
        // Shown, not swallowed: it means the printer is being sent something
        // this screen has not learned to draw.
        return [
          Text(
            '[$description]',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Colors.redAccent,
            ),
          ),
        ];
    }
  }
}

/// The QR the printer would draw, drawn.
class _Qr extends StatelessWidget {
  const _Qr({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Error correction M, the level `escpos.dart` tells the printer to use,
    // and the smallest version the payload fits in — which is what the
    // printer picks too. A ZATCA payload carrying a signature and a public
    // key needs a big one.
    final QrCode code;
    try {
      code = QrCode(
        payload: QrPayload.fromString(data),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      );
    } on Exception catch (e) {
      return SizedBox(
        width: size,
        child: Text(
          'This payload will not fit in a QR: $e',
          style: const TextStyle(fontSize: 11, color: Colors.redAccent),
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _QrPainter(QrImage(code))),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = image.moduleCount;
    // A quiet zone of four modules, which the specification asks for and a
    // scanner needs to find the symbol at all.
    final cell = size.width / (modules + 8);
    final paint = Paint()..color = Colors.black;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    for (var y = 0; y < modules; y++) {
      for (var x = 0; x < modules; x++) {
        if (!image.isDark(y, x)) continue;
        canvas.drawRect(
          Rect.fromLTWH((x + 4) * cell, (y + 4) * cell, cell, cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}

/// Where the paper is cut, drawn the way it looks.
class _CutLine extends StatelessWidget {
  const _CutLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.content_cut, size: 14, color: Colors.black45),
        const SizedBox(width: 4),
        Expanded(
          child: CustomPaint(
            size: const Size(double.infinity, 1),
            painter: _DashPainter(),
          ),
        ),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x + 4, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => false;
}
