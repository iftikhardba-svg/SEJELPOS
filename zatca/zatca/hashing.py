"""Invoice hashing and the per-device hash chain.

Every ZATCA invoice carries the hash of the one before it (PIH), forming a chain
per EGS unit. Because each tablet is its own EGS unit, **each tablet owns its own
chain and its own counter** — chains are never shared, merged, or restarted.

⚠️  The canonicalization and hashing rules below must be validated against
ZATCA's official SDK before production. Getting C14N subtly wrong produces a
hash that looks fine locally and is rejected by Fatoora. See README.
"""

from __future__ import annotations

import base64
import hashlib
from dataclasses import dataclass

# ZATCA's documented seed for the first invoice in a chain: the SHA-256 hex
# digest of the string "0", base64-encoded.
INITIAL_PIH = base64.b64encode(
    hashlib.sha256(b"0").hexdigest().encode("ascii")
).decode("ascii")


def invoice_hash(canonical_xml: bytes) -> str:
    """base64(SHA-256(canonicalised invoice XML))."""
    return base64.b64encode(hashlib.sha256(canonical_xml).digest()).decode("ascii")


@dataclass
class ChainState:
    """Where one device's invoice chain currently stands.

    `icv` is the counter for the **next** invoice. It must increase by exactly
    one per invoice and must never be reused: a gap or a repeat breaks the chain
    and ZATCA rejects everything after it.
    """

    icv: int = 1
    pih: str = INITIAL_PIH

    def advance(self, new_hash: str) -> "ChainState":
        return ChainState(icv=self.icv + 1, pih=new_hash)


class ChainError(RuntimeError):
    pass


def validate_chain(entries: list[tuple[int, str, str]]) -> None:
    """Check a device's issued invoices form an unbroken chain.

    `entries` is (icv, pih, invoice_hash) ordered by icv. Raises on the first
    problem — this is what a reconciliation job runs to prove a device's history
    is intact before anyone tries to explain a rejection to the tax authority.
    """
    if not entries:
        return

    expected_icv = entries[0][0]
    if expected_icv != 1:
        raise ChainError(f"chain starts at ICV {expected_icv}, expected 1")

    prev_hash = INITIAL_PIH
    for icv, pih, own_hash in entries:
        if icv != expected_icv:
            raise ChainError(
                f"ICV {icv} out of sequence, expected {expected_icv} "
                "(a gap or reuse breaks the chain)"
            )
        if pih != prev_hash:
            raise ChainError(
                f"ICV {icv}: PIH does not match the previous invoice's hash"
            )
        prev_hash = own_hash
        expected_icv += 1
