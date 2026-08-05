# ZATCA Phase 2 signing

Reference implementation of the cryptographic parts of ZATCA e-invoicing, in
Python so it can be tested. The tablet runs a Dart port of the same logic in
`app/lib/zatca/`.

```powershell
python -m pytest        # 62 tests
```

## Keeping the Dart port honest

The two implementations must produce **byte-identical** output — the invoice
hash is SHA-256 over canonical XML, so a single differing byte is a different
invoice. They are pinned to each other by golden vectors rather than by
inspection:

```powershell
python tools/gen_golden.py     # writes app/test/zatca/golden.json
cd ../app; flutter test test/zatca/
```

`gen_golden.py` emits TLV payloads, money and timestamp formatting, the chain
seed, three full invoices (canonical bytes + hash), a key pair and a QR.
`app/test/zatca/golden_test.dart` replays every case and compares bytes, so
when this library is corrected against ZATCA's SDK, the tablet either follows
or the build fails.

ECDSA signatures cannot be compared this way — the nonce is random — so the
goldens carry a Python-made signature that Dart **verifies**, and vice versa.
That is the stronger check anyway: it proves both sides agree on the curve,
the digest and the DER encoding.

**Regenerate the goldens after any change here, and re-run the Dart tests.**

## Why this runs on the device

Each tablet is its own EGS unit: own key pair, own CSID, own invoice counter
(ICV), own hash chain (PIH). That is what lets a waiter close a bill and print a
compliant QR receipt with no network — the whole reason offline billing works.

Chains are **per device**. Never share, merge, or restart one.

## What is here

| Module | Does |
|---|---|
| `tlv.py` | TLV encoding/decoding for the QR payload |
| `hashing.py` | invoice hash, PIH chain, chain validation |
| `signing.py` | secp256k1 key pairs, ECDSA stamps, CSR, EGS serial |
| `qr.py` | assembles the base64 QR printed on the receipt |
| `invoice.py` | UBL 2.1 invoice XML, C14N canonicalisation |

Some decisions worth knowing:

- **Money never becomes a float.** `halalas_to_decimal_string` is integer
  division and modulo. `2520 -> "25.20"`.
- **Naive timestamps are rejected.** A device with a drifting clock and no
  timezone produces invoices ZATCA rejects; failing at construction is cheaper
  than failing at reporting.
- **TLV lengths are counted in bytes, not characters.** Arabic seller names are
  multi-byte; a character count would under-measure and produce a QR that scans
  but fails validation. There is a test for exactly this.
- **`validate_chain` exists for reconciliation.** When ZATCA rejects something,
  the first question is whether that device's chain is intact. This answers it.

### VAT is split per line, not per invoice

`line_from_inclusive_price` converts each VAT-inclusive menu price to net and
tax, deriving tax by subtraction so the gross the customer paid never moves.
There is a test that walks every gross value from 0.01 to 50.00 and asserts
`net + tax == gross` at each one.

Note the consequence: a 54.00 invoice splits to 46.95 + 7.05 per line, where
rounding the whole invoice at once would give 46.96 + 7.04. Both reconcile;
they differ by a halala. Which one ZATCA expects is on the validation list
below.

## ⚠️ What is NOT done — read before trusting this

**Nothing here is validated against ZATCA's official SDK.** The tests prove
internal consistency — TLV round-trips, signatures verify, chains detect gaps,
totals reconcile — they do **not** prove compliance. Specifically unverified:

- XML canonicalisation (C14N variant) and which elements are excluded before
  hashing
- Whether the invoice hash is base64 of the digest bytes or of the hex digest
  (implementations differ; ZATCA's SDK is the arbiter)
- Element ordering and the exact UBL element set ZATCA requires
- **Per-line vs per-invoice VAT rounding** — a one-halala difference that a
  validator may well reject
- The CSR custom extension OIDs and `invoice_type` semantics, which have changed
  between spec revisions
- The signed-properties structure inside `UBLExtensions` — the enveloped
  signature itself is **not implemented**; `build_xml` emits an empty
  placeholder element

**Before production:** run generated invoices through ZATCA's official validator
in the sandbox, and only then treat this as correct. A hash that looks right
locally and is wrong by one canonicalisation rule fails at Fatoora, after the
customer has already walked out with the receipt.

The Dart port shares every one of these gaps — it is the same logic, proven
identical, which means it is identically unvalidated. Byte-parity with this
library is not evidence of compliance; it only guarantees that fixing this
library fixes the tablet.

`sample_invoice.xml` is a generated example, useful as the first thing to feed
the validator.

### Key custody: the Android Keystore cannot hold this key

An earlier version of this file said the private key must live in the Android
Keystore. **It cannot.** Android Keystore generates and stores NIST curves
(P-256/384/521) only; ZATCA mandates **secp256k1**, which it will not accept.
There is no configuration that fixes this — the constraint is the hardware
keymaster's supported curve list.

What is achievable, and what the Dart port is built for:

- the key is generated in-process and stored in application-private storage;
- it is encrypted at rest under an **AES key that does live in the Keystore**,
  so extracting the file off a rooted device does not yield a usable key;
- `ZatcaKeyProvider` (`app/lib/zatca/device_signer.dart`) is the seam — the
  in-memory implementation is for tests, and the encrypted-storage one is the
  production path.

This is weaker than a hardware-bound key and it is the ceiling the platform
allows. Worth stating plainly to a customer rather than implying hardware
custody we do not have.

## Onboarding flow (for reference)

1. Generate a secp256k1 key pair on the device (see key custody above — this
   is a software key by necessity, not a Keystore-resident one)
2. Build a CSR carrying the EGS serial and the company VAT number
3. Send it to ZATCA → compliance CSID
4. Pass the compliance checks → production CSID
5. Store the CSID; track its expiry centrally and renew before it lapses

We perform steps 2–5 on the customer's behalf as service provider.
