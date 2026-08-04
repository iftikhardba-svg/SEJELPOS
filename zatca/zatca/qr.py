"""Assemble the ZATCA invoice QR payload.

This is what gets printed on the customer's receipt. It is produced on the
device, at the moment of sale, with no network — which is the whole reason each
tablet holds its own CSID.

Money arrives here as integer halalas (as it is stored everywhere else) and is
formatted to two decimals only at this boundary, because ZATCA wants a decimal
string. The conversion is integer division, never float arithmetic.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass

from . import tlv
from .signing import sign_digest


def halalas_to_decimal_string(halalas: int) -> str:
    """1234 -> '12.34'. Integer maths only; no float ever touches a total."""
    if halalas < 0:
        raise ValueError("amount cannot be negative")
    return f"{halalas // 100}.{halalas % 100:02d}"


def zatca_timestamp(when: dt.datetime) -> str:
    """ISO 8601 in UTC with a trailing Z, no microseconds."""
    if when.tzinfo is None:
        raise ValueError(
            "timestamp must be timezone-aware — a naive local time on a device "
            "with drifting clock produces invoices ZATCA rejects"
        )
    return when.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


@dataclass(frozen=True)
class QrInput:
    seller_name: str          # Arabic name as registered with ZATCA
    vat_number: str           # 15 digits
    issued_at: dt.datetime
    total_with_vat: int       # halalas
    vat_total: int            # halalas
    invoice_hash: str         # base64
    public_key_der: bytes
    csid_signature: str       # base64, ZATCA's signature over the public key


def build_qr(data: QrInput, private_pem: bytes) -> str:
    """Return the base64 TLV payload to encode as a QR on the receipt."""
    if len(data.vat_number) != 15 or not data.vat_number.isdigit():
        raise ValueError("VAT registration number must be 15 digits")
    if data.vat_total > data.total_with_vat:
        raise ValueError("VAT cannot exceed the invoice total")

    # The stamp is over the invoice hash, which is what binds the QR to the
    # document it was printed for.
    signature = sign_digest(private_pem, data.invoice_hash.encode("ascii"))

    return tlv.encode_base64({
        tlv.Tag.SELLER_NAME:    data.seller_name,
        tlv.Tag.VAT_NUMBER:     data.vat_number,
        tlv.Tag.TIMESTAMP:      zatca_timestamp(data.issued_at),
        tlv.Tag.INVOICE_TOTAL:  halalas_to_decimal_string(data.total_with_vat),
        tlv.Tag.VAT_TOTAL:      halalas_to_decimal_string(data.vat_total),
        tlv.Tag.INVOICE_HASH:   data.invoice_hash,
        tlv.Tag.SIGNATURE:      signature,
        tlv.Tag.PUBLIC_KEY:     data.public_key_der,
        tlv.Tag.CSID_SIGNATURE: data.csid_signature,
    })


def inspect(qr_base64: str) -> dict[str, str]:
    """Decode a QR payload for support and debugging."""
    raw = tlv.decode_base64(qr_base64)
    names = {
        tlv.Tag.SELLER_NAME: "seller_name",
        tlv.Tag.VAT_NUMBER: "vat_number",
        tlv.Tag.TIMESTAMP: "timestamp",
        tlv.Tag.INVOICE_TOTAL: "total_with_vat",
        tlv.Tag.VAT_TOTAL: "vat_total",
        tlv.Tag.INVOICE_HASH: "invoice_hash",
        tlv.Tag.SIGNATURE: "signature",
        tlv.Tag.PUBLIC_KEY: "public_key",
        tlv.Tag.CSID_SIGNATURE: "csid_signature",
    }
    out = {}
    for tag, value in raw.items():
        key = names.get(tag, f"tag_{tag}")
        if tag in (tlv.Tag.PUBLIC_KEY,):
            out[key] = f"<{len(value)} bytes>"
        else:
            try:
                out[key] = value.decode("utf-8")
            except UnicodeDecodeError:
                out[key] = f"<{len(value)} bytes>"
    return out
