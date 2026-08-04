"""ECDSA signing for ZATCA cryptographic stamps.

ZATCA requires secp256k1 with SHA-256. Each device holds its own key pair and
its own CSID, so each tablet can stamp invoices with no network — which is the
only reason offline billing is possible at all.

**Key custody.** On Android the private key belongs in the Keystore and must
never reach SQLite or a file. This module is the reference implementation used
for tests and for the backend-side tooling; the Dart port on the tablet must
delegate the actual private-key operation to the Keystore rather than loading
key bytes into memory.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

CURVE = ec.SECP256K1()
HASH = hashes.SHA256()


@dataclass(frozen=True)
class KeyPair:
    private_pem: bytes
    public_der: bytes

    @property
    def public_key_base64(self) -> str:
        return base64.b64encode(self.public_der).decode("ascii")


def generate_keypair() -> KeyPair:
    key = ec.generate_private_key(CURVE)
    return KeyPair(
        private_pem=key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ),
        public_der=key.public_key().public_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        ),
    )


def load_private_key(private_pem: bytes):
    key = serialization.load_pem_private_key(private_pem, password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("not an EC private key")
    if key.curve.name != CURVE.name:
        raise ValueError(
            f"key uses {key.curve.name}; ZATCA requires {CURVE.name}"
        )
    return key


def sign_digest(private_pem: bytes, payload: bytes) -> str:
    """Sign `payload` and return the DER signature, base64-encoded."""
    key = load_private_key(private_pem)
    return base64.b64encode(key.sign(payload, ec.ECDSA(HASH))).decode("ascii")


def verify(public_der: bytes, signature_b64: str, payload: bytes) -> bool:
    pub = serialization.load_der_public_key(public_der)
    try:
        pub.verify(base64.b64decode(signature_b64), payload, ec.ECDSA(HASH))
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------
# Device onboarding
# --------------------------------------------------------------------------

def egs_serial(vendor: str, model: str, device_uuid: str) -> str:
    """The EGS unit serial ZATCA expects: 1-<vendor>|2-<model>|3-<device uuid>."""
    for part, label in ((vendor, "vendor"), (model, "model"), (device_uuid, "uuid")):
        if not part or "|" in part:
            raise ValueError(f"{label} must be non-empty and contain no '|'")
    return f"1-{vendor}|2-{model}|3-{device_uuid}"


def build_csr(
    *,
    private_pem: bytes,
    common_name: str,
    organisation: str,
    organisational_unit: str,
    country: str = "SA",
    serial: str,
    vat_number: str,
    invoice_type: str = "0100",   # 1st digit standard, 2nd simplified
    location: str,
    industry: str,
) -> bytes:
    """Build the CSR sent to ZATCA to obtain a CSID.

    ⚠️  The custom extension OIDs and the exact `invoice_type` semantics must be
    checked against the current ZATCA onboarding spec before use in production —
    they have changed between spec revisions. See README.
    """
    key = load_private_key(private_pem)

    subject = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, common_name),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, organisation),
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, organisational_unit),
        x509.NameAttribute(NameOID.COUNTRY_NAME, country),
    ])

    # ZATCA carries EGS metadata in a subjectAltName otherName bag keyed by
    # these labels.
    san_value = (
        f"SN={serial}|UUID={vat_number}|TITLE={invoice_type}|"
        f"ADDRESS={location}|CATEGORY={industry}"
    )

    builder = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(subject)
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(san_value[:255])]),
            critical=False,
        )
    )
    csr = builder.sign(key, HASH)
    return csr.public_bytes(serialization.Encoding.PEM)


def csid_public_key_signature(certificate_pem: bytes) -> str:
    """QR tag 9: ZATCA's signature over the device public key.

    This is the signature field of the CSID certificate ZATCA issued.
    """
    cert = x509.load_pem_x509_certificate(certificate_pem)
    return base64.b64encode(cert.signature).decode("ascii")


def public_key_from_certificate(certificate_pem: bytes) -> bytes:
    cert = x509.load_pem_x509_certificate(certificate_pem)
    return cert.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
