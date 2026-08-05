"""Generate golden vectors for the Dart port of this library.

The Dart implementation on the tablet must produce byte-identical output to
this Python implementation — same TLV, same canonical XML, same hash — so that
when sandbox validation lands here, it lands for both. This script writes
``app/test/zatca/golden.json``; the Dart test suite replays every case and
compares bytes.

Signatures are the one non-deterministic part (ECDSA uses a random nonce), so
the goldens carry a keypair and a Python-made signature for Dart to *verify*,
rather than a signature for Dart to reproduce.

Re-run after any change to this library, then re-run ``flutter test``:

    python tools/gen_golden.py
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import sys
import uuid
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from zatca import hashing, signing, tlv
from zatca import invoice as inv
from zatca import qr as qrmod

OUT = Path(__file__).resolve().parents[2] / "app" / "test" / "zatca" / "golden.json"

RIYADH = dt.timezone(dt.timedelta(hours=3))

SELLER = inv.Party(
    name="مطعم فاطمة",
    vat_number="310000000000003",
    cr_number="1010012345",
    address=inv.Address(
        street="شارع الملك فهد",
        building="8228",
        city="الرياض",
        postal_code="12244",
        district="العليا",
    ),
)


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def line_json(line: inv.Line) -> dict:
    return {
        "line_id": line.line_id,
        "name": line.name,
        "quantity": line.quantity,
        "unit_price": line.unit_price,
        "line_net": line.line_net,
        "line_tax": line.line_tax,
        "vat_percent": str(line.vat_percent),
        "unit_code": line.unit_code,
    }


def invoice_case(name: str, invoice: inv.Invoice) -> dict:
    xml, canonical = inv.build_and_canonicalize(invoice)
    return {
        "name": name,
        "input": {
            "invoice_number": invoice.invoice_number,
            "uuid": str(invoice.uuid),
            "issued_at": invoice.issued_at.isoformat(),
            "icv": invoice.icv,
            "pih": invoice.pih,
            "notes": invoice.notes,
            "seller": {
                "name": SELLER.name,
                "vat_number": SELLER.vat_number,
                "cr_number": SELLER.cr_number,
                "address": {
                    "street": SELLER.address.street,
                    "building": SELLER.address.building,
                    "city": SELLER.address.city,
                    "postal_code": SELLER.address.postal_code,
                    "district": SELLER.address.district,
                    "country": SELLER.address.country,
                },
            },
            "lines": [line_json(line) for line in invoice.lines],
        },
        "canonical_b64": b64(canonical),
        "hash": hashing.invoice_hash(canonical),
    }


def main() -> None:
    golden: dict = {}

    # ---- TLV ------------------------------------------------------------
    # The Arabic seller name is deliberate: TLV lengths count BYTES, and an
    # implementation that counts characters passes every ASCII test and
    # breaks on the first real receipt.
    tlv_cases = [
        {1: "Bufia", 2: "310000000000003"},
        {1: "مطعم فاطمة", 2: "310000000000003", 3: "2026-08-04T06:30:00Z"},
        {6: "aGFzaA==", 7: "c2ln", 8: b"\x30\x03\x02\x01\x01", 9: "Y3NpZA=="},
    ]
    golden["tlv"] = [
        {
            "fields": {
                str(tag): (b64(value) if isinstance(value, bytes) else value)
                for tag, value in fields.items()
            },
            "binary_tags": [
                str(tag) for tag, value in fields.items() if isinstance(value, bytes)
            ],
            "b64": tlv.encode_base64(fields),
        }
        for fields in tlv_cases
    ]

    # ---- money and timestamps ------------------------------------------
    golden["money"] = [
        [halalas, qrmod.halalas_to_decimal_string(halalas)]
        for halalas in [0, 5, 99, 100, 104, 696, 80000, 123456, 100000000]
    ]
    stamps = [
        dt.datetime(2026, 8, 4, 9, 30, 0, tzinfo=RIYADH),
        dt.datetime(2026, 8, 4, 23, 59, 59, 999999, tzinfo=RIYADH),
        dt.datetime(2026, 1, 1, 0, 0, 0, tzinfo=dt.timezone.utc),
    ]
    golden["timestamps"] = [
        [when.isoformat(), qrmod.zatca_timestamp(when)] for when in stamps
    ]

    # ---- signing --------------------------------------------------------
    keypair = signing.generate_keypair()
    payload = b"golden payload: what the tablet will sign"
    golden["signing"] = {
        "private_pem": keypair.private_pem.decode("ascii"),
        "public_der_b64": b64(keypair.public_der),
        "payload": payload.decode("ascii"),
        "signature_b64": signing.sign_digest(keypair.private_pem, payload),
    }

    # ---- hash chain -----------------------------------------------------
    golden["initial_pih"] = hashing.INITIAL_PIH

    # ---- invoices -------------------------------------------------------
    # Pinned VAT parity values from real sales: HUMMOS 800 -> 696 + 104,
    # tier B 900 -> 783 + 117.
    hummos = inv.line_from_inclusive_price(
        line_id=1, name="HUMMOS", quantity=1, unit_price_inclusive=800
    )
    assert (hummos.line_net, hummos.line_tax) == (696, 104)

    golden["invoices"] = [
        invoice_case(
            "single_line",
            inv.Invoice(
                invoice_number="T01-000001",
                uuid=uuid.UUID("7a0e3f6e-1111-4222-8333-444455556666"),
                issued_at=dt.datetime(2026, 8, 4, 9, 30, 0, tzinfo=RIYADH),
                seller=SELLER,
                lines=[hummos],
                icv=1,
                pih=hashing.INITIAL_PIH,
            ),
        ),
        invoice_case(
            "multi_line_zero_vat_and_weighed",
            inv.Invoice(
                invoice_number="T01-000042",
                uuid=uuid.UUID("7a0e3f6e-aaaa-4bbb-8ccc-dddd11112222"),
                issued_at=dt.datetime(2026, 8, 4, 23, 59, 59, tzinfo=RIYADH),
                seller=SELLER,
                lines=[
                    inv.line_from_inclusive_price(
                        line_id=1, name="HUMMOS", quantity=2, unit_price_inclusive=800
                    ),
                    inv.Line(
                        line_id=2,
                        name="WATER SMALL",
                        quantity=1,
                        unit_price=150,
                        line_net=150,
                        line_tax=0,
                        vat_percent=Decimal("0.00"),
                    ),
                    inv.line_from_inclusive_price(
                        line_id=3,
                        name="SHAWARMA MEAT KG",
                        quantity=0.5,
                        unit_price_inclusive=9000,
                        unit_code="KGM",
                    ),
                ],
                icv=42,
                pih="1riDrjKUOOJXvOnkE9G6r6+dcyaeCzOTZQ2GN9Nwjfs=",
            ),
        ),
        invoice_case(
            "aggregator_tier_b_with_note",
            inv.Invoice(
                invoice_number="T02-000317",
                uuid=uuid.UUID("7a0e3f6e-9999-4888-b777-666655554444"),
                issued_at=dt.datetime(2026, 8, 4, 14, 5, 30, tzinfo=RIYADH),
                seller=SELLER,
                lines=[
                    inv.line_from_inclusive_price(
                        line_id=1, name="HUMMOS", quantity=1, unit_price_inclusive=900
                    ),
                ],
                icv=317,
                pih="Ym9ndXMtYnV0LXZhbGlkLWxvb2tpbmctcGloLXZhbHVl",
                notes=["Keeta order K-889123"],
            ),
        ),
    ]

    # ---- full QR --------------------------------------------------------
    # Built with the golden keypair over the first invoice's hash. The
    # signature inside is random-nonce ECDSA: Dart VERIFIES it rather than
    # reproducing it, and byte-compares every other tag.
    first = golden["invoices"][0]
    qr_input = qrmod.QrInput(
        seller_name=SELLER.name,
        vat_number=SELLER.vat_number,
        issued_at=dt.datetime(2026, 8, 4, 9, 30, 0, tzinfo=RIYADH),
        total_with_vat=800,
        vat_total=104,
        invoice_hash=first["hash"],
        public_key_der=base64.b64decode(golden["signing"]["public_der_b64"]),
        csid_signature="ZmFrZS1jc2lkLXNpZ25hdHVyZQ==",
    )
    golden["qr"] = {
        "input": {
            "seller_name": qr_input.seller_name,
            "vat_number": qr_input.vat_number,
            "issued_at": qr_input.issued_at.isoformat(),
            "total_with_vat": qr_input.total_with_vat,
            "vat_total": qr_input.vat_total,
            "invoice_hash": qr_input.invoice_hash,
            "csid_signature": qr_input.csid_signature,
        },
        "qr_b64": qrmod.build_qr(qr_input, keypair.private_pem),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(golden, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(f"wrote {OUT}")
    print(f"  invoices: {[c['name'] for c in golden['invoices']]}")


if __name__ == "__main__":
    main()
