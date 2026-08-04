"""UBL invoice generation tests.

These prove the document is well-formed, the arithmetic reconciles, and the
hash inputs are stable. They do **not** prove ZATCA accepts it — only the
official validator can say that.
"""

from __future__ import annotations

import datetime as dt
import uuid
from decimal import Decimal

import pytest
from lxml import etree

from zatca import hashing
from zatca.invoice import (
    NS,
    Address,
    Invoice,
    Line,
    Party,
    build_and_canonicalize,
    build_xml,
    canonicalize,
    line_from_inclusive_price,
    money,
)


def seller() -> Party:
    return Party(
        name="مطعم فاطمة",
        vat_number="310000000000003",
        cr_number="1010101010",
        address=Address(
            street="طريق الملك فهد",
            building="1234",
            city="الرياض",
            postal_code="12345",
            district="العليا",
        ),
    )


def an_invoice(lines=None, **over) -> Invoice:
    base = dict(
        invoice_number="T01-000123",
        uuid=uuid.uuid4(),
        issued_at=dt.datetime(2026, 8, 3, 12, 0, 0, tzinfo=dt.timezone.utc),
        seller=seller(),
        # `is None`, not `or`: an empty list is a case worth testing, and `or`
        # would quietly substitute the default line for it.
        lines=lines if lines is not None else [line_from_inclusive_price(
            line_id=1, name="MOUSHAKAL SABAH", quantity=1,
            unit_price_inclusive=3800,
        )],
        icv=1,
        pih=hashing.INITIAL_PIH,
    )
    base.update(over)
    return Invoice(**base)


def xpath(doc: bytes, path: str) -> list[str]:
    root = etree.fromstring(doc)
    return [n.text for n in root.xpath(path, namespaces=NS)]


# --------------------------------------------------------------------------
# Money

@pytest.mark.parametrize("halalas,expected", [
    (0, "0.00"), (65, "0.65"), (3800, "38.00"), (2520, "25.20"), (-500, "-5.00"),
])
def test_money_format(halalas, expected):
    assert money(halalas) == expected


def test_inclusive_price_splits_without_losing_a_halala():
    """The customer paid the gross figure; it must not move."""
    for gross in range(1, 5000):
        ln = line_from_inclusive_price(
            line_id=1, name="x", quantity=1, unit_price_inclusive=gross
        )
        assert ln.line_net + ln.line_tax == gross, f"broke at {gross}"


def test_known_vat_split():
    ln = line_from_inclusive_price(
        line_id=1, name="x", quantity=1, unit_price_inclusive=3800
    )
    # 38.00 inclusive of 15% -> 33.04 net + 4.96 tax
    assert (ln.line_net, ln.line_tax) == (3304, 496)


def test_quantity_scales_the_split():
    ln = line_from_inclusive_price(
        line_id=1, name="x", quantity=3, unit_price_inclusive=1000
    )
    assert ln.line_net + ln.line_tax == 3000


# --------------------------------------------------------------------------
# Document structure

def test_document_is_well_formed():
    doc = build_xml(an_invoice())
    root = etree.fromstring(doc)
    assert root.tag == f"{{{NS['inv']}}}Invoice"


def test_carries_identity_and_chain():
    inv = an_invoice(icv=7, pih="cHJldmlvdXM=")
    doc = build_xml(inv)

    assert xpath(doc, "//cbc:ID")[0] == "T01-000123"
    assert xpath(doc, "//cbc:UUID")[0] == str(inv.uuid)

    icv = xpath(doc, "//cac:AdditionalDocumentReference[cbc:ID='ICV']/cbc:UUID")
    assert icv == ["7"]

    pih = xpath(
        doc,
        "//cac:AdditionalDocumentReference[cbc:ID='PIH']"
        "/cac:Attachment/cbc:EmbeddedDocumentBinaryObject",
    )
    assert pih == ["cHJldmlvdXM="]


def test_marked_as_simplified_invoice():
    root = etree.fromstring(build_xml(an_invoice()))
    node = root.xpath("//cbc:InvoiceTypeCode", namespaces=NS)[0]
    assert node.text == "388"
    assert node.get("name") == "0200000"      # simplified / B2C


def test_seller_arabic_name_survives():
    doc = build_xml(an_invoice())
    assert "مطعم فاطمة" in xpath(doc, "//cac:PartyLegalEntity/cbc:RegistrationName")


def test_totals_reconcile_in_the_document():
    lines = [
        line_from_inclusive_price(line_id=1, name="a", quantity=1,
                                  unit_price_inclusive=3800),
        line_from_inclusive_price(line_id=2, name="b", quantity=2,
                                  unit_price_inclusive=1500),
    ]
    inv = an_invoice(lines=lines)
    doc = build_xml(inv)

    net = xpath(doc, "//cac:LegalMonetaryTotal/cbc:TaxExclusiveAmount")[0]
    gross = xpath(doc, "//cac:LegalMonetaryTotal/cbc:TaxInclusiveAmount")[0]
    payable = xpath(doc, "//cac:LegalMonetaryTotal/cbc:PayableAmount")[0]

    assert net == money(inv.net_total)
    assert gross == money(inv.gross_total)
    assert payable == gross
    assert inv.gross_total == 3800 + 3000


def test_one_line_per_item():
    lines = [
        line_from_inclusive_price(line_id=i, name=f"item{i}", quantity=1,
                                  unit_price_inclusive=1000)
        for i in range(1, 5)
    ]
    doc = build_xml(an_invoice(lines=lines))
    assert len(xpath(doc, "//cac:InvoiceLine/cbc:ID")) == 4


def test_zero_rated_line_uses_category_z():
    ln = Line(line_id=1, name="exempt", quantity=1, unit_price=1000,
              line_net=1000, line_tax=0, vat_percent=Decimal("0.00"))
    doc = build_xml(an_invoice(lines=[ln]))
    cats = xpath(doc, "//cac:ClassifiedTaxCategory/cbc:ID")
    assert cats == ["Z"]


def test_mixed_rates_produce_separate_subtotals():
    lines = [
        line_from_inclusive_price(line_id=1, name="std", quantity=1,
                                  unit_price_inclusive=1150),
        Line(line_id=2, name="zero", quantity=1, unit_price=500,
             line_net=500, line_tax=0, vat_percent=Decimal("0.00")),
    ]
    doc = build_xml(an_invoice(lines=lines))
    root = etree.fromstring(doc)
    subtotals = root.xpath("(//cac:TaxTotal)[1]/cac:TaxSubtotal", namespaces=NS)
    assert len(subtotals) == 2


# --------------------------------------------------------------------------
# Validation

def test_naive_timestamp_rejected():
    with pytest.raises(ValueError, match="timezone-aware"):
        build_xml(an_invoice(issued_at=dt.datetime(2026, 8, 3, 12, 0, 0)))


def test_empty_invoice_rejected():
    with pytest.raises(ValueError, match="at least one line"):
        build_xml(an_invoice(lines=[]))


def test_bad_vat_number_rejected():
    bad = seller()
    bad.vat_number = "123"
    with pytest.raises(ValueError, match="15 digits"):
        build_xml(an_invoice(seller=bad))


def test_icv_must_be_positive():
    with pytest.raises(ValueError, match="ICV must be 1"):
        build_xml(an_invoice(icv=0))


# --------------------------------------------------------------------------
# Canonicalisation and hashing

def test_canonical_form_drops_the_signature_placeholder():
    doc = build_xml(an_invoice())
    assert b"UBLExtensions" in doc
    assert b"UBLExtensions" not in canonicalize(doc)


def test_hash_is_stable_for_the_same_invoice():
    inv = an_invoice()
    _, c1 = build_and_canonicalize(inv)
    _, c2 = build_and_canonicalize(inv)
    assert hashing.invoice_hash(c1) == hashing.invoice_hash(c2)


def test_hash_changes_when_the_amount_changes():
    a = an_invoice()
    b = an_invoice(lines=[line_from_inclusive_price(
        line_id=1, name="MOUSHAKAL SABAH", quantity=1, unit_price_inclusive=3900
    )])
    _, ca = build_and_canonicalize(a)
    _, cb = build_and_canonicalize(b)
    assert hashing.invoice_hash(ca) != hashing.invoice_hash(cb)


def test_hash_changes_when_the_chain_position_changes():
    """Two identical sales at different points in the chain must differ."""
    a = an_invoice(icv=1, pih=hashing.INITIAL_PIH)
    b = an_invoice(uuid=a.uuid, icv=2, pih="c29tZXRoaW5nLWVsc2U=")
    _, ca = build_and_canonicalize(a)
    _, cb = build_and_canonicalize(b)
    assert hashing.invoice_hash(ca) != hashing.invoice_hash(cb)


def test_end_to_end_chain_across_three_invoices():
    """Issue three invoices on one device and confirm the chain validates."""
    from zatca.hashing import ChainState, validate_chain

    state = ChainState()
    entries = []
    for n in range(1, 4):
        inv = an_invoice(
            invoice_number=f"T01-{n:06d}",
            uuid=uuid.uuid4(),
            icv=state.icv,
            pih=state.pih,
        )
        _, canonical = build_and_canonicalize(inv)
        h = hashing.invoice_hash(canonical)
        entries.append((state.icv, state.pih, h))
        state = state.advance(h)

    validate_chain(entries)
    assert state.icv == 4
