/// UBL 2.1 simplified tax invoice XML for ZATCA.
///
/// Dart port of `zatca/zatca/invoice.py`, built on [XmlEl] so the canonical
/// bytes match the Python reference exactly — the invoice hash is SHA-256
/// over those bytes, so "close enough" is not a thing here. The golden
/// vectors in `test/zatca/golden.json` pin every case.
///
/// Money arrives as integer halalas and is formatted to two decimals only
/// here, at the XML boundary — the same rule as `qr.dart`, for the same
/// reason.
///
/// ⚠️  **Not validated against ZATCA's official SDK.** The element set,
/// ordering and canonicalisation follow the published UBL 2.1 / ZATCA
/// structure, but the authority on correctness is ZATCA's validator. A
/// document that looks right and is wrong by one canonicalisation rule fails
/// *after* the customer has walked out with the receipt.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'xml_writer.dart';

const Map<String?, String> ublNamespaces = {
  null: 'urn:oasis:names:specification:ubl:schema:xsd:Invoice-2',
  'cac': 'urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2',
  'cbc': 'urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2',
  'ext': 'urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2',
};

const String currency = 'SAR';

/// 388 is a tax invoice; the name attribute encodes the sub-type, where
/// 0200000 means simplified (B2C) — what a restaurant issues.
const String invoiceTypeCode = '388';
const String simplified = '0200000';
const String standard = '0100000';

/// 1234 -> '12.34'. Integer maths only.
String money(int halalas) {
  final sign = halalas < 0 ? '-' : '';
  final h = halalas.abs();
  return '$sign${h ~/ 100}.${(h % 100).toString().padLeft(2, '0')}';
}

String quantityString(num value) => value.toStringAsFixed(3);

String percentString(num value) => value.toStringAsFixed(2);

class ZatcaAddress {
  const ZatcaAddress({
    required this.street,
    required this.building,
    required this.city,
    required this.postalCode,
    this.district = '',
    this.country = 'SA',
  });

  final String street;
  final String building;
  final String city;
  final String postalCode;
  final String district;
  final String country;

  factory ZatcaAddress.fromJson(Map<String, dynamic> json) => ZatcaAddress(
        street: (json['street'] ?? '') as String,
        building: (json['building'] ?? '') as String,
        city: (json['city'] ?? '') as String,
        postalCode: (json['postal_code'] ?? '') as String,
        district: (json['district'] ?? '') as String,
        country: (json['country'] ?? 'SA') as String,
      );
}

class ZatcaParty {
  const ZatcaParty({
    required this.name,
    required this.vatNumber,
    required this.address,
    this.crNumber = '',
  });

  /// Arabic name as registered with ZATCA.
  final String name;
  final String vatNumber;
  final ZatcaAddress address;
  final String crNumber;
}

class ZatcaLine {
  const ZatcaLine({
    required this.lineId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.lineNet,
    required this.lineTax,
    this.vatPercent = 15,
    this.unitCode = 'PCE',
  });

  final int lineId;
  final String name;
  final num quantity;

  /// halalas, VAT-EXCLUSIVE
  final int unitPrice;
  final int lineNet;
  final int lineTax;
  final num vatPercent;
  final String unitCode;

  int get lineTotal => lineNet + lineTax;

  /// Build a line from a VAT-inclusive price, as the POS stores it.
  ///
  /// Menu prices in Saudi restaurants include VAT, but UBL wants net amounts.
  /// The tax is derived by subtraction rather than computed independently, so
  /// net, tax and gross always reconcile to the halala — the customer paid
  /// the gross figure, and that is the number that must not move.
  factory ZatcaLine.fromInclusivePrice({
    required int lineId,
    required String name,
    required num quantity,
    required int unitPriceInclusive,
    num vatPercent = 15,
    String unitCode = 'PCE',
  }) {
    final gross = (unitPriceInclusive * quantity).round();
    final divisor = 100 + vatPercent;
    final net = (gross * 100 / divisor).round();
    final unitNet = (unitPriceInclusive * 100 / divisor).round();
    return ZatcaLine(
      lineId: lineId,
      name: name,
      quantity: quantity,
      unitPrice: unitNet,
      lineNet: net,
      lineTax: gross - net,
      vatPercent: vatPercent,
      unitCode: unitCode,
    );
  }
}

class ZatcaInvoice {
  ZatcaInvoice({
    required this.invoiceNumber,
    required this.uuid,
    required this.issuedAt,
    required this.seller,
    required this.lines,
    required this.icv,
    required this.pih,
    this.invoiceSubtype = simplified,
    this.buyer,
    this.notes = const [],
  });

  final String invoiceNumber;
  final String uuid;
  final DateTime issuedAt;
  final ZatcaParty seller;
  final List<ZatcaLine> lines;
  final int icv;
  final String pih;
  final String invoiceSubtype;
  final ZatcaParty? buyer;
  final List<String> notes;

  int get netTotal => lines.fold(0, (sum, l) => sum + l.lineNet);
  int get taxTotal => lines.fold(0, (sum, l) => sum + l.lineTax);
  int get grossTotal => netTotal + taxTotal;
}

// --------------------------------------------------------------------------

XmlEl _el(XmlEl parent, String tag,
    [String? text, List<(String, String)> attrs = const []]) {
  final parts = tag.split(':');
  final node = parts.length == 1
      ? XmlEl(null, parts[0], attrs: attrs)
      : XmlEl(parts[0], parts[1], attrs: attrs);
  if (text != null) node.add(text);
  parent.add(node);
  return node;
}

void _address(XmlEl parent, ZatcaAddress addr) {
  final node = _el(parent, 'cac:PostalAddress');
  _el(node, 'cbc:StreetName', addr.street);
  _el(node, 'cbc:BuildingNumber', addr.building);
  if (addr.district.isNotEmpty) {
    _el(node, 'cbc:CitySubdivisionName', addr.district);
  }
  _el(node, 'cbc:CityName', addr.city);
  _el(node, 'cbc:PostalZone', addr.postalCode);
  final country = _el(node, 'cac:Country');
  _el(country, 'cbc:IdentificationCode', addr.country);
}

void _party(XmlEl parent, String tag, ZatcaParty party) {
  final wrapper = _el(parent, tag);
  final node = _el(wrapper, 'cac:Party');

  if (party.crNumber.isNotEmpty) {
    final ident = _el(node, 'cac:PartyIdentification');
    _el(ident, 'cbc:ID', party.crNumber, [('schemeID', 'CRN')]);
  }

  _address(node, party.address);

  final scheme = _el(node, 'cac:PartyTaxScheme');
  _el(scheme, 'cbc:CompanyID', party.vatNumber);
  final taxScheme = _el(scheme, 'cac:TaxScheme');
  _el(taxScheme, 'cbc:ID', 'VAT');

  final legal = _el(node, 'cac:PartyLegalEntity');
  _el(legal, 'cbc:RegistrationName', party.name);
}

/// Build the unsigned UBL 2.1 invoice element tree.
XmlEl buildInvoiceTree(ZatcaInvoice invoice) {
  if (!invoice.issuedAt.isUtc && invoice.issuedAt.timeZoneOffset == Duration.zero) {
    // A DateTime is always zoned in Dart; nothing to guard. Kept as a no-op
    // branch so the Python precondition has a visible counterpart.
  }
  if (invoice.lines.isEmpty) {
    throw ArgumentError('an invoice must have at least one line');
  }
  if (invoice.seller.vatNumber.length != 15 ||
      !RegExp(r'^\d{15}$').hasMatch(invoice.seller.vatNumber)) {
    throw ArgumentError('seller VAT registration number must be 15 digits');
  }
  if (invoice.icv < 1) {
    throw ArgumentError('ICV must be 1 or greater');
  }

  final issued = invoice.issuedAt.toUtc();

  final root = XmlEl(null, 'Invoice');

  // UBLExtensions holds the enveloped signature. Created empty here and
  // populated by the signer; also excluded before hashing, which is why it
  // must exist as a placeholder rather than be added later.
  _el(root, 'ext:UBLExtensions');

  _el(root, 'cbc:ProfileID', 'reporting:1.0');
  _el(root, 'cbc:ID', invoice.invoiceNumber);
  _el(root, 'cbc:UUID', invoice.uuid);
  _el(root, 'cbc:IssueDate', _date(issued));
  _el(root, 'cbc:IssueTime', _time(issued));
  _el(root, 'cbc:InvoiceTypeCode', invoiceTypeCode,
      [('name', invoice.invoiceSubtype)]);
  for (final note in invoice.notes) {
    _el(root, 'cbc:Note', note);
  }
  _el(root, 'cbc:DocumentCurrencyCode', currency);
  _el(root, 'cbc:TaxCurrencyCode', currency);

  // ICV — the per-device invoice counter.
  final counter = _el(root, 'cac:AdditionalDocumentReference');
  _el(counter, 'cbc:ID', 'ICV');
  _el(counter, 'cbc:UUID', invoice.icv.toString());

  // PIH — hash of this device's previous invoice, forming the chain.
  final pihRef = _el(root, 'cac:AdditionalDocumentReference');
  _el(pihRef, 'cbc:ID', 'PIH');
  final attachment = _el(pihRef, 'cac:Attachment');
  _el(attachment, 'cbc:EmbeddedDocumentBinaryObject', invoice.pih,
      [('mimeCode', 'text/plain')]);

  _party(root, 'cac:AccountingSupplierParty', invoice.seller);
  if (invoice.buyer != null) {
    _party(root, 'cac:AccountingCustomerParty', invoice.buyer!);
  }

  // ---- tax totals ----
  final taxTotal = _el(root, 'cac:TaxTotal');
  _el(taxTotal, 'cbc:TaxAmount', money(invoice.taxTotal),
      [('currencyID', currency)]);

  final byRate = <num, List<ZatcaLine>>{};
  for (final line in invoice.lines) {
    byRate.putIfAbsent(line.vatPercent, () => []).add(line);
  }

  final rates = byRate.keys.toList()..sort((a, b) => a.compareTo(b));
  for (final rate in rates) {
    final group = byRate[rate]!;
    final subtotal = _el(taxTotal, 'cac:TaxSubtotal');
    final net = group.fold(0, (sum, l) => sum + l.lineNet);
    final tax = group.fold(0, (sum, l) => sum + l.lineTax);
    _el(subtotal, 'cbc:TaxableAmount', money(net), [('currencyID', currency)]);
    _el(subtotal, 'cbc:TaxAmount', money(tax), [('currencyID', currency)]);
    final category = _el(subtotal, 'cac:TaxCategory');
    _el(category, 'cbc:ID', rate > 0 ? 'S' : 'Z');
    _el(category, 'cbc:Percent', percentString(rate));
    final scheme = _el(category, 'cac:TaxScheme');
    _el(scheme, 'cbc:ID', 'VAT');
  }

  // ZATCA expects a second TaxTotal carrying only the amount.
  final taxTotal2 = _el(root, 'cac:TaxTotal');
  _el(taxTotal2, 'cbc:TaxAmount', money(invoice.taxTotal),
      [('currencyID', currency)]);

  final totals = _el(root, 'cac:LegalMonetaryTotal');
  _el(totals, 'cbc:LineExtensionAmount', money(invoice.netTotal),
      [('currencyID', currency)]);
  _el(totals, 'cbc:TaxExclusiveAmount', money(invoice.netTotal),
      [('currencyID', currency)]);
  _el(totals, 'cbc:TaxInclusiveAmount', money(invoice.grossTotal),
      [('currencyID', currency)]);
  _el(totals, 'cbc:PayableAmount', money(invoice.grossTotal),
      [('currencyID', currency)]);

  for (final line in invoice.lines) {
    final node = _el(root, 'cac:InvoiceLine');
    _el(node, 'cbc:ID', line.lineId.toString());
    _el(node, 'cbc:InvoicedQuantity', quantityString(line.quantity),
        [('unitCode', line.unitCode)]);
    _el(node, 'cbc:LineExtensionAmount', money(line.lineNet),
        [('currencyID', currency)]);

    final lineTax = _el(node, 'cac:TaxTotal');
    _el(lineTax, 'cbc:TaxAmount', money(line.lineTax),
        [('currencyID', currency)]);
    _el(lineTax, 'cbc:RoundingAmount', money(line.lineTotal),
        [('currencyID', currency)]);

    final item = _el(node, 'cac:Item');
    _el(item, 'cbc:Name', line.name);
    final category = _el(item, 'cac:ClassifiedTaxCategory');
    _el(category, 'cbc:ID', line.vatPercent > 0 ? 'S' : 'Z');
    _el(category, 'cbc:Percent', percentString(line.vatPercent));
    final scheme = _el(category, 'cac:TaxScheme');
    _el(scheme, 'cbc:ID', 'VAT');

    final price = _el(node, 'cac:Price');
    _el(price, 'cbc:PriceAmount', money(line.unitPrice),
        [('currencyID', currency)]);
  }

  return root;
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _time(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}:'
    '${d.second.toString().padLeft(2, '0')}';

/// The document as stored and reported.
Uint8List buildInvoiceXml(ZatcaInvoice invoice) => Uint8List.fromList(
      utf8.encode(serializeXml(
        buildInvoiceTree(invoice),
        namespaces: ublNamespaces,
        xmlDeclaration: true,
        declareAllAtRoot: true,
      )),
    );

/// Removed before hashing: the signature cannot be part of what it signs, and
/// the QR embeds the hash, so it cannot be part of it either.
bool _excludedFromHash(XmlEl el) {
  if (el.prefix == 'ext' && el.local == 'UBLExtensions') return true;
  if (el.prefix == 'cac' && el.local == 'Signature') return true;
  if (el.prefix == 'cac' && el.local == 'AdditionalDocumentReference') {
    for (final child in el.children) {
      if (child is XmlEl &&
          child.prefix == 'cbc' &&
          child.local == 'ID' &&
          child.children.length == 1 &&
          child.children.first == 'QR') {
        return true;
      }
    }
  }
  return false;
}

/// C14N with the signature-related elements removed — the bytes that get
/// hashed.
Uint8List canonicalizeInvoice(XmlEl tree) => Uint8List.fromList(
      utf8.encode(serializeXml(
        tree,
        namespaces: ublNamespaces,
        exclude: _excludedFromHash,
      )),
    );

/// Returns (document, canonical form for hashing).
({Uint8List xml, Uint8List canonical}) buildAndCanonicalize(
    ZatcaInvoice invoice) {
  final tree = buildInvoiceTree(invoice);
  return (
    xml: Uint8List.fromList(utf8.encode(serializeXml(
      tree,
      namespaces: ublNamespaces,
      xmlDeclaration: true,
      declareAllAtRoot: true,
    ))),
    canonical: canonicalizeInvoice(tree),
  );
}
