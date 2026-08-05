/// The wire: talking to the POS backend.
///
/// Thin on purpose — every request/response shape here mirrors a Pydantic
/// schema in `backend/app/schemas.py`, and nothing else in the app knows HTTP
/// exists. The http.Client is injected so tests can fake the wire without
/// faking the logic.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class SyncApiException implements Exception {
  SyncApiException(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  @override
  String toString() => 'backend said $statusCode: $detail';
}

class EnrolmentResult {
  EnrolmentResult({
    required this.token,
    required this.deviceId,
    required this.role,
    required this.receiptPrefix,
    required this.kdsStationNo,
    required this.branchName,
    required this.tenantMode,
    required this.sellerName,
    required this.sellerVat,
    this.sellerNameAr,
    this.sellerCr,
    this.sellerAddress = const {},
  });

  factory EnrolmentResult.fromJson(Map<String, dynamic> j) => EnrolmentResult(
        token: j['token'] as String,
        deviceId: j['device_id'] as String,
        role: j['role'] as String,
        receiptPrefix: j['receipt_prefix'] as String,
        kdsStationNo: j['kds_station_no'] as int?,
        branchName: j['branch_name'] as String,
        tenantMode: j['tenant_mode'] as String,
        sellerName: j['seller_name'] as String,
        sellerNameAr: j['seller_name_ar'] as String?,
        sellerVat: j['seller_vat'] as String,
        sellerCr: j['seller_cr'] as String?,
        sellerAddress:
            (j['seller_address'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  final String token;
  final String deviceId;
  final String role;
  final String receiptPrefix;
  final int? kdsStationNo;
  final String branchName;
  final String tenantMode;

  /// The legal seller this device invoices as. Delivered at enrolment because
  /// a tablet must be able to issue a ZATCA invoice with no network — there
  /// is no later opportunity to ask.
  final String sellerName;
  final String? sellerNameAr;
  final String sellerVat;
  final String? sellerCr;
  final Map<String, dynamic> sellerAddress;
}

class SyncApi {
  SyncApi({required this.baseUrl, this.token, http.Client? client})
      : _client = client ?? http.Client();

  /// e.g. `https://pos.example.sa` — `/v1/...` is appended here.
  final String baseUrl;
  String? token;
  final http.Client _client;

  Uri _u(String path) => Uri.parse('$baseUrl/v1$path');

  Map<String, String> _headers({bool authed = true}) => {
        'content-type': 'application/json',
        if (authed && token != null) 'authorization': 'Bearer $token',
      };

  Map<String, dynamic> _decode(http.Response r, {int expect = 200}) {
    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (r.statusCode != expect) {
      final detail = body['detail'];
      throw SyncApiException(r.statusCode, detail?.toString() ?? r.body);
    }
    return body;
  }

  /// Redeem a one-time enrolment code. Unauthenticated — this call is how the
  /// device gets its credential.
  Future<EnrolmentResult> enrol({
    required String code,
    required String deviceUuid,
    String platform = 'android',
    String? appVersion,
  }) async {
    final r = await _client.post(
      _u('/enrol'),
      headers: _headers(authed: false),
      body: jsonEncode({
        'code': code,
        'device_uuid': deviceUuid,
        'platform': platform,
        'app_version': ?appVersion,
      }),
    );
    final result = EnrolmentResult.fromJson(_decode(r));
    token = result.token;
    return result;
  }

  /// Incremental catalog pull. `since` is the watermark from the previous
  /// response; 0 means everything.
  /// One page of the catalog delta. [cursor] comes from the previous page's
  /// `next_cursor` and is opaque — its shape is the backend's business.
  Future<Map<String, dynamic>> getCatalog({
    required int since,
    String? cursor,
  }) async {
    final query = StringBuffer('/catalog?since=$since');
    if (cursor != null) {
      query.write('&cursor=${Uri.encodeQueryComponent(cursor)}');
    }
    final r = await _client.get(_u(query.toString()), headers: _headers());
    return _decode(r);
  }

  /// Push a batch of closed sales. Returns the backend's per-sale verdicts —
  /// `accepted` (including `duplicate` replays) and `rejected`.
  Future<({List<Map<String, dynamic>> accepted, List<Map<String, dynamic>> rejected})>
      pushSales(List<Map<String, dynamic>> sales) async {
    final r = await _client.post(
      _u('/sales'),
      headers: _headers(),
      body: jsonEncode(sales),
    );
    final body = _decode(r);
    List<Map<String, dynamic>> listOf(String key) => [
          for (final e in (body[key] as List? ?? const []))
            (e as Map).cast<String, dynamic>(),
        ];
    return (accepted: listOf('accepted'), rejected: listOf('rejected'));
  }

  /// Create a kitchen ticket. Idempotent on the till-generated ticket id —
  /// a retry after a network blink must not cook the order twice.
  Future<Map<String, dynamic>> createKdsTicket(
      Map<String, dynamic> ticket) async {
    final r = await _client.post(
      _u('/kds/tickets'),
      headers: _headers(),
      body: jsonEncode(ticket),
    );
    return _decode(r, expect: 201);
  }

  /// The kitchen queue: open tickets plus the recent done lane. A station
  /// number narrows lines to that station; tickets with nothing for it are
  /// omitted entirely by the backend.
  Future<Map<String, dynamic>> kdsQueue({int? station}) async {
    final query = station == null ? '' : '?station=$station';
    final r = await _client.get(
      _u('/kds/queue$query'),
      headers: _headers(),
    );
    return _decode(r);
  }

  Future<Map<String, dynamic>> kdsBump(String ticketId) async {
    final r = await _client.post(
      _u('/kds/tickets/$ticketId/bump'),
      headers: _headers(),
    );
    return _decode(r);
  }

  Future<Map<String, dynamic>> kdsRecall(String ticketId) async {
    final r = await _client.post(
      _u('/kds/tickets/$ticketId/recall'),
      headers: _headers(),
    );
    return _decode(r);
  }

  Future<void> kdsLineDone(String lineId, {bool done = true}) async {
    final r = await _client.post(
      _u('/kds/lines/$lineId/done?done=$done'),
      headers: _headers(),
    );
    _decode(r);
  }

  /// Allocate the next customer-facing order number (online path; the hub
  /// allocates offline).
  Future<int> nextOrderNumber({required DateTime businessDate}) async {
    final r = await _client.post(
      _u('/orders/next'),
      headers: _headers(),
      body: jsonEncode({
        'business_date':
            businessDate.toIso8601String().substring(0, 10),
      }),
    );
    return _decode(r)['order_no'] as int;
  }

  void close() => _client.close();
}
