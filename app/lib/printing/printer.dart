/// Getting receipt bytes onto paper.
///
/// ESC/POS printers on a restaurant LAN listen on TCP 9100 (the restaurant's
/// existing printers are configured as NETWORK: in PixelPoint). The transport
/// is injectable so tests capture bytes instead of needing a printer.
library;

import 'dart:async';
import 'dart:io';

typedef SendBytes = Future<void> Function(String host, int port, List<int> bytes);

/// The real transport: connect, write, flush, close. A printer that cannot be
/// reached in four seconds is off or unplugged — waiting longer just holds up
/// the queue at the till.
Future<void> sendOverTcp(String host, int port, List<int> bytes) async {
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 4),
  );
  try {
    socket.add(bytes);
    await socket.flush();
  } finally {
    await socket.close();
  }
}

class ReceiptPrinter {
  ReceiptPrinter({
    required this.host,
    this.port = 9100,
    SendBytes? send,
  }) : _send = send ?? sendOverTcp;

  final String host;
  final int port;
  final SendBytes _send;

  Future<void> print(List<int> bytes) => _send(host, port, bytes);
}
