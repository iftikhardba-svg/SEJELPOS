"""Tests for the ZATCA signing module.

These prove the parts that are self-contained and verifiable here: TLV round
trips, money formatting, signature validity, and chain integrity. They do NOT
prove ZATCA compliance — that requires the official SDK. See README.
"""

from __future__ import annotations

import base64
import datetime as dt

import pytest

from zatca import hashing, qr, signing, tlv


# --------------------------------------------------------------------------
# TLV

def test_tlv_round_trip():
    fields = {1: "مطعم فاطمة", 2: "310000000000003", 3: "2026-08-03T12:00:00Z"}
    decoded = tlv.decode_base64(tlv.encode_base64(fields))
    assert decoded[1].decode() == "مطعم فاطمة"
    assert decoded[2].decode() == "310000000000003"


def test_tlv_orders_tags_ascending():
    payload = tlv.encode({3: "c", 1: "a", 2: "b"})
    assert [payload[0], payload[3], payload[6]] == [1, 2, 3]


def test_tlv_rejects_oversized_value():
    with pytest.raises(ValueError, match="over the 255-byte"):
        tlv.encode_field(1, "x" * 256)


def test_tlv_rejects_truncated_payload():
    good = tlv.encode({1: "hello"})
    with pytest.raises(ValueError, match="only"):
        tlv.decode(good[:-2])


def test_arabic_length_is_counted_in_bytes_not_characters():
    """Arabic is multi-byte; a character count would under-measure the field."""
    name = "م" * 128            # 128 chars, 256 bytes in UTF-8
    with pytest.raises(ValueError):
        tlv.encode_field(1, name)


# --------------------------------------------------------------------------
# Money

@pytest.mark.parametrize("halalas,expected", [
    (0, "0.00"), (5, "0.05"), (65, "0.65"), (100, "1.00"),
    (435, "4.35"), (1304, "13.04"), (3800, "38.00"), (2520, "25.20"),
    (123456789, "1234567.89"),
])
def test_halalas_format(halalas, expected):
    assert qr.halalas_to_decimal_string(halalas) == expected


def test_negative_amount_rejected():
    with pytest.raises(ValueError):
        qr.halalas_to_decimal_string(-1)


# --------------------------------------------------------------------------
# Timestamps

def test_timestamp_is_utc_zulu():
    riyadh = dt.timezone(dt.timedelta(hours=3))
    when = dt.datetime(2026, 8, 3, 15, 30, 45, 123456, tzinfo=riyadh)
    assert qr.zatca_timestamp(when) == "2026-08-03T12:30:45Z"


def test_naive_timestamp_rejected():
    with pytest.raises(ValueError, match="timezone-aware"):
        qr.zatca_timestamp(dt.datetime(2026, 8, 3, 12, 0, 0))


# --------------------------------------------------------------------------
# Signing

def test_generated_key_is_secp256k1():
    kp = signing.generate_keypair()
    key = signing.load_private_key(kp.private_pem)
    assert key.curve.name == "secp256k1"


def test_signature_verifies():
    kp = signing.generate_keypair()
    payload = b"invoice-hash-goes-here"
    sig = signing.sign_digest(kp.private_pem, payload)
    assert signing.verify(kp.public_der, sig, payload)


def test_signature_fails_on_tampered_payload():
    kp = signing.generate_keypair()
    sig = signing.sign_digest(kp.private_pem, b"original")
    assert not signing.verify(kp.public_der, sig, b"tampered")


def test_wrong_curve_rejected():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    p256 = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    with pytest.raises(ValueError, match="secp256k1"):
        signing.load_private_key(p256)


def test_egs_serial_format():
    s = signing.egs_serial("PosVendor", "TabModel", "abc-123")
    assert s == "1-PosVendor|2-TabModel|3-abc-123"


def test_egs_serial_rejects_pipe():
    with pytest.raises(ValueError):
        signing.egs_serial("bad|vendor", "m", "u")


def test_csr_builds_and_carries_the_key():
    kp = signing.generate_keypair()
    pem = signing.build_csr(
        private_pem=kp.private_pem,
        common_name="TST-886431145-399999999900003",
        organisation="Fatima Restaurant",
        organisational_unit="Riyadh Branch",
        serial=signing.egs_serial("PosVendor", "TabModel", "dev-1"),
        vat_number="310000000000003",
        location="Riyadh",
        industry="restaurant",
    )
    assert pem.startswith(b"-----BEGIN CERTIFICATE REQUEST-----")


# --------------------------------------------------------------------------
# QR assembly

def _qr_input(**over):
    base = dict(
        seller_name="مطعم فاطمة",
        vat_number="310000000000003",
        issued_at=dt.datetime(2026, 8, 3, 12, 0, 0, tzinfo=dt.timezone.utc),
        total_with_vat=3800,
        vat_total=496,
        invoice_hash=hashing.invoice_hash(b"<Invoice/>"),
        public_key_der=b"\x30\x59" + b"\x00" * 30,
        csid_signature=base64.b64encode(b"csid-sig").decode(),
    )
    base.update(over)
    return qr.QrInput(**base)


def test_qr_contains_every_required_tag():
    kp = signing.generate_keypair()
    payload = qr.build_qr(_qr_input(), kp.private_pem)
    decoded = tlv.decode_base64(payload)
    assert set(decoded) == set(range(1, 10))


def test_qr_signature_verifies_against_the_invoice_hash():
    kp = signing.generate_keypair()
    data = _qr_input()
    payload = qr.build_qr(data, kp.private_pem)
    decoded = tlv.decode_base64(payload)

    signature_b64 = decoded[tlv.Tag.SIGNATURE].decode()
    assert signing.verify(
        kp.public_der, signature_b64, data.invoice_hash.encode("ascii")
    )


def test_qr_amounts_are_formatted_as_decimals():
    kp = signing.generate_keypair()
    payload = qr.build_qr(_qr_input(total_with_vat=2520, vat_total=329),
                          kp.private_pem)
    fields = qr.inspect(payload)
    assert fields["total_with_vat"] == "25.20"
    assert fields["vat_total"] == "3.29"


def test_qr_rejects_bad_vat_number():
    kp = signing.generate_keypair()
    with pytest.raises(ValueError, match="15 digits"):
        qr.build_qr(_qr_input(vat_number="123"), kp.private_pem)


def test_qr_rejects_vat_greater_than_total():
    kp = signing.generate_keypair()
    with pytest.raises(ValueError, match="cannot exceed"):
        qr.build_qr(_qr_input(total_with_vat=100, vat_total=200), kp.private_pem)


# --------------------------------------------------------------------------
# Hash chain

def test_initial_pih_is_the_documented_seed():
    assert hashing.INITIAL_PIH == (
        "NWZlY2ViNjZmZmM4NmYzOGQ5NTI3ODZjNmQ2OTZjNzljMmRiYzIzOWRkNGU5MWI0"
        "NjcyOWQ3M2EyN2ZiNTdlOQ=="
    )


def test_invoice_hash_is_stable_and_base64():
    h = hashing.invoice_hash(b"<Invoice>x</Invoice>")
    assert h == hashing.invoice_hash(b"<Invoice>x</Invoice>")
    assert base64.b64decode(h)  # valid base64
    assert h != hashing.invoice_hash(b"<Invoice>y</Invoice>")


def test_chain_advances():
    state = hashing.ChainState()
    assert state.icv == 1 and state.pih == hashing.INITIAL_PIH

    h1 = hashing.invoice_hash(b"<one/>")
    state = state.advance(h1)
    assert state.icv == 2 and state.pih == h1


def test_valid_chain_passes():
    h1 = hashing.invoice_hash(b"<one/>")
    h2 = hashing.invoice_hash(b"<two/>")
    hashing.validate_chain([
        (1, hashing.INITIAL_PIH, h1),
        (2, h1, h2),
    ])


def test_chain_with_a_gap_is_caught():
    h1 = hashing.invoice_hash(b"<one/>")
    h3 = hashing.invoice_hash(b"<three/>")
    with pytest.raises(hashing.ChainError, match="out of sequence"):
        hashing.validate_chain([
            (1, hashing.INITIAL_PIH, h1),
            (3, h1, h3),
        ])


def test_chain_with_a_broken_link_is_caught():
    h1 = hashing.invoice_hash(b"<one/>")
    h2 = hashing.invoice_hash(b"<two/>")
    wrong = hashing.invoice_hash(b"<something-else/>")
    with pytest.raises(hashing.ChainError, match="does not match"):
        hashing.validate_chain([
            (1, hashing.INITIAL_PIH, h1),
            (2, wrong, h2),
        ])


def test_chain_must_start_at_one():
    h = hashing.invoice_hash(b"<x/>")
    with pytest.raises(hashing.ChainError, match="starts at ICV"):
        hashing.validate_chain([(5, hashing.INITIAL_PIH, h)])


def test_two_devices_keep_independent_chains():
    """Each tablet is its own EGS unit — chains must not interfere."""
    a1 = hashing.invoice_hash(b"<a1/>")
    b1 = hashing.invoice_hash(b"<b1/>")
    hashing.validate_chain([(1, hashing.INITIAL_PIH, a1)])
    hashing.validate_chain([(1, hashing.INITIAL_PIH, b1)])
