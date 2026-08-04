"""UBL 2.1 simplified tax invoice XML for ZATCA.

Builds the invoice document a tablet signs and prints. Money arrives as integer
halalas and is formatted to two decimals only here, at the XML boundary — the
same rule as `qr.py`, for the same reason.

⚠️  **Not validated against ZATCA's official SDK.** The element set, ordering and
canonicalisation below follow the published UBL 2.1 / ZATCA structure, but the
authority on correctness is ZATCA's validator, not this file. Run generated
invoices through the Fatoora sandbox before trusting any of it. A document that
looks right and is wrong by one canonicalisation rule fails *after* the customer
has walked out with the receipt. See README.
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass, field
from decimal import ROUND_HALF_UP, Decimal

from lxml import etree

NS = {
    "inv": "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    "cac": "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
    "cbc": "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
    "ext": "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2",
}

CURRENCY = "SAR"

# ZATCA invoice type codes. 388 is a tax invoice; the name attribute encodes
# the sub-type, where 02 means simplified (B2C) — what a restaurant issues.
INVOICE_TYPE_CODE = "388"
SIMPLIFIED = "0200000"
STANDARD = "0100000"


def money(halalas: int) -> str:
    """1234 -> '12.34'. Integer maths only."""
    sign = "-" if halalas < 0 else ""
    h = abs(halalas)
    return f"{sign}{h // 100}.{h % 100:02d}"


def quantity(value) -> str:
    return str(Decimal(str(value)).quantize(Decimal("0.001"), rounding=ROUND_HALF_UP))


@dataclass
class Address:
    street: str
    building: str
    city: str
    postal_code: str
    district: str = ""
    country: str = "SA"


@dataclass
class Party:
    name: str            # Arabic name as registered with ZATCA
    vat_number: str
    address: Address
    cr_number: str = ""


@dataclass
class Line:
    line_id: int
    name: str
    quantity: float
    unit_price: int      # halalas, VAT-EXCLUSIVE
    line_net: int        # halalas, excl. VAT
    line_tax: int        # halalas
    vat_percent: Decimal = Decimal("15.00")
    unit_code: str = "PCE"

    @property
    def line_total(self) -> int:
        return self.line_net + self.line_tax


@dataclass
class Invoice:
    invoice_number: str
    uuid: uuid.UUID
    issued_at: dt.datetime
    seller: Party
    lines: list[Line]
    icv: int
    pih: str
    invoice_subtype: str = SIMPLIFIED
    buyer: Party | None = None
    notes: list[str] = field(default_factory=list)

    @property
    def net_total(self) -> int:
        return sum(ln.line_net for ln in self.lines)

    @property
    def tax_total(self) -> int:
        return sum(ln.line_tax for ln in self.lines)

    @property
    def gross_total(self) -> int:
        return self.net_total + self.tax_total


# --------------------------------------------------------------------------


def _el(parent, tag: str, text: str | None = None, **attrs):
    prefix, _, local = tag.partition(":")
    node = etree.SubElement(parent, f"{{{NS[prefix]}}}{local}", **attrs)
    if text is not None:
        node.text = text
    return node


def _address(parent, addr: Address) -> None:
    node = _el(parent, "cac:PostalAddress")
    _el(node, "cbc:StreetName", addr.street)
    _el(node, "cbc:BuildingNumber", addr.building)
    if addr.district:
        _el(node, "cbc:CitySubdivisionName", addr.district)
    _el(node, "cbc:CityName", addr.city)
    _el(node, "cbc:PostalZone", addr.postal_code)
    country = _el(node, "cac:Country")
    _el(country, "cbc:IdentificationCode", addr.country)


def _party(parent, tag: str, party: Party) -> None:
    wrapper = _el(parent, tag)
    node = _el(wrapper, "cac:Party")

    if party.cr_number:
        ident = _el(node, "cac:PartyIdentification")
        _el(ident, "cbc:ID", party.cr_number, schemeID="CRN")

    _address(node, party.address)

    scheme = _el(node, "cac:PartyTaxScheme")
    _el(scheme, "cbc:CompanyID", party.vat_number)
    tax_scheme = _el(scheme, "cac:TaxScheme")
    _el(tax_scheme, "cbc:ID", "VAT")

    legal = _el(node, "cac:PartyLegalEntity")
    _el(legal, "cbc:RegistrationName", party.name)


def build_xml(invoice: Invoice) -> bytes:
    """Produce the unsigned UBL 2.1 invoice document."""
    if invoice.issued_at.tzinfo is None:
        raise ValueError(
            "issued_at must be timezone-aware — a naive local time produces "
            "invoices ZATCA rejects"
        )
    if not invoice.lines:
        raise ValueError("an invoice must have at least one line")
    if len(invoice.seller.vat_number) != 15 or not invoice.seller.vat_number.isdigit():
        raise ValueError("seller VAT registration number must be 15 digits")
    if invoice.icv < 1:
        raise ValueError("ICV must be 1 or greater")

    issued = invoice.issued_at.astimezone(dt.timezone.utc)

    root = etree.Element(
        f"{{{NS['inv']}}}Invoice",
        nsmap={None: NS["inv"], "cac": NS["cac"], "cbc": NS["cbc"], "ext": NS["ext"]},
    )

    # UBLExtensions holds the enveloped signature. It is created empty here and
    # populated by the signer; it is also excluded before hashing, which is why
    # it must exist as a placeholder rather than be added later.
    _el(root, "ext:UBLExtensions")

    _el(root, "cbc:ProfileID", "reporting:1.0")
    _el(root, "cbc:ID", invoice.invoice_number)
    _el(root, "cbc:UUID", str(invoice.uuid))
    _el(root, "cbc:IssueDate", issued.strftime("%Y-%m-%d"))
    _el(root, "cbc:IssueTime", issued.strftime("%H:%M:%S"))
    _el(root, "cbc:InvoiceTypeCode", INVOICE_TYPE_CODE, name=invoice.invoice_subtype)
    for note in invoice.notes:
        _el(root, "cbc:Note", note)
    _el(root, "cbc:DocumentCurrencyCode", CURRENCY)
    _el(root, "cbc:TaxCurrencyCode", CURRENCY)

    # ICV — the per-device invoice counter.
    counter = _el(root, "cac:AdditionalDocumentReference")
    _el(counter, "cbc:ID", "ICV")
    _el(counter, "cbc:UUID", str(invoice.icv))

    # PIH — hash of this device's previous invoice, forming the chain.
    pih_ref = _el(root, "cac:AdditionalDocumentReference")
    _el(pih_ref, "cbc:ID", "PIH")
    attachment = _el(pih_ref, "cac:Attachment")
    _el(attachment, "cbc:EmbeddedDocumentBinaryObject", invoice.pih,
        mimeCode="text/plain")

    _party(root, "cac:AccountingSupplierParty", invoice.seller)
    if invoice.buyer is not None:
        _party(root, "cac:AccountingCustomerParty", invoice.buyer)

    # ---- tax totals ----
    tax_total = _el(root, "cac:TaxTotal")
    _el(tax_total, "cbc:TaxAmount", money(invoice.tax_total), currencyID=CURRENCY)

    by_rate: dict[Decimal, list[Line]] = {}
    for ln in invoice.lines:
        by_rate.setdefault(ln.vat_percent, []).append(ln)

    for rate, lines in sorted(by_rate.items()):
        subtotal = _el(tax_total, "cac:TaxSubtotal")
        net = sum(x.line_net for x in lines)
        tax = sum(x.line_tax for x in lines)
        _el(subtotal, "cbc:TaxableAmount", money(net), currencyID=CURRENCY)
        _el(subtotal, "cbc:TaxAmount", money(tax), currencyID=CURRENCY)
        category = _el(subtotal, "cac:TaxCategory")
        _el(category, "cbc:ID", "S" if rate > 0 else "Z")
        _el(category, "cbc:Percent", f"{rate:.2f}")
        scheme = _el(category, "cac:TaxScheme")
        _el(scheme, "cbc:ID", "VAT")

    # ZATCA expects a second TaxTotal carrying only the amount.
    tax_total_2 = _el(root, "cac:TaxTotal")
    _el(tax_total_2, "cbc:TaxAmount", money(invoice.tax_total), currencyID=CURRENCY)

    totals = _el(root, "cac:LegalMonetaryTotal")
    _el(totals, "cbc:LineExtensionAmount", money(invoice.net_total), currencyID=CURRENCY)
    _el(totals, "cbc:TaxExclusiveAmount", money(invoice.net_total), currencyID=CURRENCY)
    _el(totals, "cbc:TaxInclusiveAmount", money(invoice.gross_total), currencyID=CURRENCY)
    _el(totals, "cbc:PayableAmount", money(invoice.gross_total), currencyID=CURRENCY)

    for ln in invoice.lines:
        node = _el(root, "cac:InvoiceLine")
        _el(node, "cbc:ID", str(ln.line_id))
        _el(node, "cbc:InvoicedQuantity", quantity(ln.quantity), unitCode=ln.unit_code)
        _el(node, "cbc:LineExtensionAmount", money(ln.line_net), currencyID=CURRENCY)

        line_tax = _el(node, "cac:TaxTotal")
        _el(line_tax, "cbc:TaxAmount", money(ln.line_tax), currencyID=CURRENCY)
        _el(line_tax, "cbc:RoundingAmount", money(ln.line_total), currencyID=CURRENCY)

        item = _el(node, "cac:Item")
        _el(item, "cbc:Name", ln.name)
        category = _el(item, "cac:ClassifiedTaxCategory")
        _el(category, "cbc:ID", "S" if ln.vat_percent > 0 else "Z")
        _el(category, "cbc:Percent", f"{ln.vat_percent:.2f}")
        scheme = _el(category, "cac:TaxScheme")
        _el(scheme, "cbc:ID", "VAT")

        price = _el(node, "cac:Price")
        _el(price, "cbc:PriceAmount", money(ln.unit_price), currencyID=CURRENCY)

    return etree.tostring(root, xml_declaration=True, encoding="UTF-8")


# --------------------------------------------------------------------------
# Canonicalisation
# --------------------------------------------------------------------------

# Removed before hashing: the signature cannot be part of what it signs, and the
# QR embeds the hash, so it cannot be part of it either.
EXCLUDED_FROM_HASH = (
    "//ext:UBLExtensions",
    "//cac:Signature",
    "//cac:AdditionalDocumentReference[cbc:ID='QR']",
)


def canonicalize(xml_bytes: bytes) -> bytes:
    """C14N 1.1 with the signature-related elements removed.

    ⚠️  Exactly which elements ZATCA excludes, and the canonicalisation variant,
    must be confirmed against their SDK. This follows the documented approach
    but has not been validated.
    """
    root = etree.fromstring(xml_bytes)

    for xpath in EXCLUDED_FROM_HASH:
        for node in root.xpath(xpath, namespaces=NS):
            node.getparent().remove(node)

    return etree.tostring(root, method="c14n2", with_comments=False)


def build_and_canonicalize(invoice: Invoice) -> tuple[bytes, bytes]:
    """Return (document, canonical form for hashing)."""
    xml = build_xml(invoice)
    return xml, canonicalize(xml)


# --------------------------------------------------------------------------
# Building an invoice from POS data
# --------------------------------------------------------------------------

def line_from_inclusive_price(
    *,
    line_id: int,
    name: str,
    quantity: float,
    unit_price_inclusive: int,
    vat_percent: Decimal = Decimal("15.00"),
    unit_code: str = "PCE",
) -> Line:
    """Build a line from a VAT-inclusive price, as the POS stores it.

    Menu prices in Saudi restaurants include VAT, but UBL wants net amounts. The
    tax is derived by subtraction rather than computed independently, so net,
    tax and gross always reconcile to the halala — the customer paid the gross
    figure, and that is the number that must not move.
    """
    gross = int(round(unit_price_inclusive * quantity))
    divisor = Decimal(100) + vat_percent
    net = int((Decimal(gross) * 100 / divisor).quantize(Decimal("1"),
                                                        rounding=ROUND_HALF_UP))
    tax = gross - net

    unit_net = int((Decimal(unit_price_inclusive) * 100 / divisor).quantize(
        Decimal("1"), rounding=ROUND_HALF_UP))

    return Line(
        line_id=line_id,
        name=name,
        quantity=quantity,
        unit_price=unit_net,
        line_net=net,
        line_tax=tax,
        vat_percent=vat_percent,
        unit_code=unit_code,
    )
