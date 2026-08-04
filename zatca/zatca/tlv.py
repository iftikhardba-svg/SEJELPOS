"""TLV encoding for the ZATCA invoice QR code.

The QR payload is a base64-encoded sequence of tag-length-value triples. Each
tag and each length is a single byte, so no value may exceed 255 bytes — true
for every field ZATCA defines, but enforced here rather than assumed, because a
silently truncated signature would produce a QR that scans and fails validation.

Tags (ZATCA Phase 2, simplified tax invoice):

    1  seller name                     5  VAT total
    2  seller VAT registration number  6  invoice XML hash (base64)
    3  invoice timestamp (ISO 8601 Z)  7  ECDSA signature (base64)
    4  invoice total incl. VAT         8  ECDSA public key (DER)
                                       9  CSID signature over the public key
"""

from __future__ import annotations

import base64
from enum import IntEnum

MAX_TLV_VALUE = 255


class Tag(IntEnum):
    SELLER_NAME = 1
    VAT_NUMBER = 2
    TIMESTAMP = 3
    INVOICE_TOTAL = 4
    VAT_TOTAL = 5
    INVOICE_HASH = 6
    SIGNATURE = 7
    PUBLIC_KEY = 8
    CSID_SIGNATURE = 9


def encode_field(tag: int, value: str | bytes) -> bytes:
    raw = value.encode("utf-8") if isinstance(value, str) else bytes(value)
    if len(raw) > MAX_TLV_VALUE:
        raise ValueError(
            f"tag {tag}: value is {len(raw)} bytes, over the {MAX_TLV_VALUE}-byte "
            "single-byte-length limit"
        )
    if not 0 <= tag <= 255:
        raise ValueError(f"tag {tag} out of range")
    return bytes([tag, len(raw)]) + raw


def encode(fields: dict[int, str | bytes]) -> bytes:
    """Encode fields in ascending tag order, as ZATCA expects."""
    return b"".join(encode_field(t, fields[t]) for t in sorted(fields))


def encode_base64(fields: dict[int, str | bytes]) -> str:
    return base64.b64encode(encode(fields)).decode("ascii")


def decode(payload: bytes) -> dict[int, bytes]:
    """Parse a TLV sequence. Used by tests and by tooling that inspects a QR."""
    out: dict[int, bytes] = {}
    i = 0
    while i < len(payload):
        if i + 2 > len(payload):
            raise ValueError(f"truncated TLV header at byte {i}")
        tag, length = payload[i], payload[i + 1]
        i += 2
        if i + length > len(payload):
            raise ValueError(
                f"tag {tag} claims {length} bytes but only "
                f"{len(payload) - i} remain"
            )
        out[tag] = payload[i:i + length]
        i += length
    return out


def decode_base64(payload: str) -> dict[int, bytes]:
    return decode(base64.b64decode(payload))
