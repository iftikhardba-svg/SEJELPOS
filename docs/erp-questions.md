# Questions for the Oracle APEX ERP / ZATCA team

Context: we are replacing PixelPoint with a new Android tablet POS. Each tablet
will operate offline and must print a ZATCA-compliant QR receipt at the moment of
sale, with no network. The ERP is already ZATCA-integrated.

**Question 1 is blocking** — the signing module cannot be built until it is answered.

---

## 1. Who signs the invoice? (BLOCKING)

Because the tablets must work with no internet, each tablet is planned as its own
**EGS unit**: its own CSID, its own invoice counter (ICV), its own hash chain (PIH).
The tablet generates the signed XML and the QR at sale time.

- **Can the ERP accept invoices that are already signed by the POS device, and
  simply report them to ZATCA?**
- Or does the ERP require to sign invoices itself?

If the ERP must sign, offline billing is not possible and we need to redesign —
please say so explicitly.

Related:
- Does the ERP already treat POS terminals as separate EGS units, or does it
  assume one EGS unit for the whole company?
- Who performs ZATCA onboarding for each device (CSR → CSID)? ERP team or us?
- What is the CSID renewal process and who is responsible for it?

## 2. Invoice numbering and the hash chain

- Does the ERP generate invoice numbers, or will it accept ours?
- With per-device chains, each tablet has its own ICV sequence starting at 1.
  Can the ERP store and report multiple independent chains?
- How should a device replacement be handled — new EGS unit, or continue the
  old chain?

## 3. API contract

- Endpoint, authentication method, and environments (test / production)?
- Expected payload for a sale — is there an existing schema we should match?
- Is the API idempotent? We retry after connection loss and must not create
  duplicate invoices. Can we send our `sale_uuid` as an idempotency key?
- Are batch submissions supported, or one call per sale?
- Rate limits?

## 4. Errors and reconciliation

- What does the ERP return if ZATCA rejects an invoice, and what should the POS do?
- Can we query an invoice's ZATCA status by our `sale_uuid`?
- Is there a reconciliation report we can use to prove every sale reached the ERP?
- How are returns / refunds / voids represented? (ZATCA credit notes)

## 5. Master data

- Should products, prices and tax settings live in the ERP and flow down to the
  POS, or stay POS-side?
- If ERP-side: is there an API to pull the catalog, and does it expose a change
  watermark (`updated_since`) so we can sync incrementally?
- Are payment methods and staff records also mastered in the ERP?

## 6. Timing and compliance

- ZATCA requires simplified invoices to be reported within 24 hours. How quickly
  does the ERP forward what we send?
- What is the maximum offline window the business will accept for a tablet before
  it must reconnect?
- VAT registration number, seller name and address for the QR payload — please
  confirm the exact values.

## 7. Historical data

- The PixelPoint database holds 61,165 historical bills. Should these be imported
  into the ERP, or kept read-only for reporting only?
- They were already invoiced under PixelPoint and must **not** be re-reported
  to ZATCA. Please confirm.
