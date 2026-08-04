# POS Product — Architecture

A commercial, multi-tenant POS sold to restaurant customers. Runs **standalone**
or **integrated with our Oracle APEX ERP**. Android tablets first, Windows desktop
secondary. Built for Saudi Arabia: 15% VAT, VAT-inclusive pricing, ZATCA Phase 2.

Decisions locked 2026-08-03.

---

## 1. Two modes, one codebase

The same build runs either way; mode is configuration, not a separate product.

| | **Standalone** | **ERP-integrated** |
|---|---|---|
| Back-office (menu, prices, staff, config) | POS back-office | **ERP is master** |
| Reports / analytics | POS | **ERP** |
| ZATCA reporting + compliance record | POS backend → ZATCA | **ERP → ZATCA** |
| Invoice signing (QR + stamp) | **device** | **device** — same |
| Sales data | POS DB | POS DB → pushed to ERP |

Two pluggable interfaces carry the difference:

```
MasterDataSource  →  SelfManaged   |  ErpManaged
ZatcaReporter     →  DirectToZatca |  ViaErp
```

### The invariant: the device always signs

ZATCA has two separate jobs and they must not be confused:

1. **Signing** — QR + cryptographic stamp, at the moment the receipt prints
2. **Reporting** — sending the signed invoice to Fatoora, within 24 hours

Signing happens **on the device in both modes**. The customer walks away with the
receipt; if the network is down there is no way to fetch a QR from anywhere else.
Putting signing on the server would mean billing stops when the internet does.

Reporting is asynchronous, so it can live wherever the mode says — POS backend
when standalone, ERP when integrated. The ERP still owns the compliance record
and the ZATCA relationship; the device only applies the stamp.

---

## 2. Tenancy

```
Tenant        — our customer, the one who buys the licence
  └── Company — legal entity; owns a VAT registration number
        └── Branch — a physical restaurant; own address, menu, prices
              └── Device — a tablet; own CSID and ZATCA invoice chain
```

Four levels, not two, because in Saudi Arabia the **VAT number belongs to the
legal entity**, and ZATCA EGS units are registered against that VAT number. A
tenant may own several companies (separate brands, separate VAT numbers), and
menus and prices routinely differ per branch.

### Isolation

Shared PostgreSQL, `tenant_id` on every table, enforced by **Row Level Security**
— not by application code remembering to add a `WHERE` clause. One forgotten
filter in a multi-tenant system leaks one customer's sales to another, so the
database refuses cross-tenant reads rather than trusting the query.

A large customer demanding physical separation can be moved to a dedicated
database later; the schema is identical, so nothing has to be rewritten.

Every API request resolves to exactly one tenant, from the token — never from a
parameter the client supplies.

---

## 3. Shape of the system

```
   ┌───────────────── BRANCH (no server box) ──────────────────┐
   │                                                           │
   │  [Tablet A]       [Tablet B]       [Tablet C]  …          │
   │   SQLite           SQLite           SQLite                │
   │   own CSID         own CSID         own CSID              │
   │   signs own        signs own        signs own             │
   │      │                │                │                  │
   │      └───────── LAN / WiFi ────────────┘                  │
   │            (shared table + order state)                   │
   │                       │                                   │
   │            one tablet holds the HUB role                  │
   │            (coordination only — NOT billing)              │
   └───────────────────────┼───────────────────────────────────┘
                           │  internet, when available
                           ▼
              ┌──────────────────────────────┐
              │  SaaS backend (our cloud)    │
              │  PostgreSQL, multi-tenant    │
              └──────┬──────────────┬────────┘
                     │              │
          standalone │              │ integrated
                     ▼              ▼
                 ZATCA        Oracle APEX ERP ──► ZATCA
```

### Why every tablet signs its own invoices

Each tablet is its own ZATCA **EGS unit**: own CSID, own invoice counter (ICV),
own hash chain (PIH).

The consequence that matters: **no single device can stop a branch from billing.**
If the hub tablet dies, waiters keep taking orders, closing bills and printing
compliant receipts. Only shared-table visibility degrades.

A single shared CSID would have made one tablet a single point of failure for
every sale in the building. Rejected for that reason.

### What the hub role does

Shared view of open tables and orders; aggregates closed sales; pushes to the
backend. It is **not** in the billing path, and any tablet can be promoted.

---

## 4. Offline behaviour

| Situation | Order taking | Close bill + QR | Shared tables | Backend push |
|---|---|---|---|---|
| Everything up | ✅ | ✅ | ✅ | ✅ |
| Internet down, LAN up | ✅ | ✅ | ✅ | queued |
| Hub tablet dead | ✅ | ✅ | own tables only | queued |
| Tablet alone, no LAN | ✅ | ✅ | own tables only | queued |

Nothing in the billing path touches the network.

**Limit:** ZATCA requires simplified invoices reported within 24 hours, so a
tablet may not stay offline for a full day. The app warns the operator as that
window approaches rather than failing silently.

---

## 5. Data flow

**Catalog — pull only.** Products, menus, payment methods, staff, tax rates.
Server always wins; tablets never edit catalog. Incremental by `server_version`
watermark with `is_deleted` tombstones so removals propagate.

**Sales — push only, append-only.** Every sale carries a device-generated UUID
and a device-local receipt number (`T01-000123`), so billing never waits on a
central sequence.

The `outbox` table is a durable queue with a UNIQUE constraint on
`(entity, entity_uuid)` — a retry after a dropped connection cannot create a
duplicate sale.

**Numbering.** `sale_uuid` is the real identity. `zatca_icv` and `zatca_pih` are
**per device**, strictly sequential, never reused, never shared or reset.

---

## 6. Money and tax

Money is stored as **INTEGER halalas** (1 SAR = 100). Never floating point — REAL
totals drift and produce bills off by a halala, which is wrong on a tax invoice.

Prices are **VAT-inclusive**:

```
line_total  = round(unit_price * qty)        # inclusive, halalas
net_amount  = round(line_total * 100 / 115)  # 15% VAT
tax_amount  = line_total - net_amount        # derived, never computed separately
```

Deriving tax by subtraction guarantees the three figures always reconcile.

Tax rates live in data, per company — rates change by law, and a multi-tenant
product cannot hardcode one.

---

## 7. Android and device security

Hub role runs as a **foreground service** with a persistent notification:

- Battery optimization exemption; WifiLock held; WiFi sleep disabled
- Kept on charger; kiosk / lock-task mode so it cannot be swiped away
- Static DHCP reservation, with mDNS discovery as fallback

iOS is ruled out for the hub role — it suspends background apps, so a server on
an iPad runs only while the app is in the foreground.

**Security:**

- CSID private key in the **Android Keystore** — never in SQLite, never in a file
- Local database encrypted (SQLCipher); it holds sales and staff records
- Employee PINs stored as hashes
- Tablet-to-tablet traffic over TLS with pinned certs; a peer must authenticate
  before joining
- A device is bound to one tenant/company/branch; re-provisioning wipes local data
  so one customer's data can never surface on another's device

---

## 8. Kitchen and customer displays

**KDS.** The old system printed paper tickets to station printers — Expo,
Grill, Shawarma and DT at the first customer. KDS replaces the printers with
screens. Design decisions that matter:

- **Routing is data, imported intact.** A product's `print_loc` is PixelPoint's
  PRINTLOC bitmask, and station numbers are the printer ports the stations
  replace — so twenty years of routing configuration keeps meaning exactly what
  it meant.
- **Ticket creation is idempotent** on a till-generated uuid, like sales: a
  network blink must not cook an order twice.
- **A kitchen ticket is workflow, not a record.** Bumping, recalling or voiding
  one never touches money or tax. When ticket and sale disagree, the sale is
  the truth.
- A station screen sees only its own lines; a ticket with nothing for that
  station does not appear on it at all.
- Devices carry a `role` — `pos`, `kds` or `cds`. KDS/CDS devices authenticate
  like tills but never create sales.

**CDS.** The customer-facing screen is an **order status board** — two lanes on
one screen, order numbers listed vertically: *Preparing* and *Ready for
collection*, the fast-food pattern. It is a read-only projection of kitchen
state: an order sits in Preparing while its kitchen ticket is `open` and moves
to Ready the moment the kitchen bumps it — the same `/kds/queue` feed the
kitchen screens read, so the board can never disagree with the kitchen. It
holds no state of its own and never takes input.

**KDS ticket ageing** is the kitchen's traffic light, fixed by the customer:
green under 3:00, yellow from 3:00 to 4:59, red at 5:00 — and the "late"
counter on the summary tiles counts red tickets.

## 9. Commercial concerns

Things a product needs that an in-house build does not:

- **Licensing** — subscription expiry, device-count limits, feature tiers,
  enforced server-side; a device with an expired licence keeps working long
  enough to finish the shift rather than dying mid-service
- **Provisioning** — self-serve onboarding for a new tenant; manual setup per
  customer does not scale
- **ZATCA onboarding as a service** — we perform CSR → CSID for each device on
  the customer's behalf, and track expiry/renewal centrally
- **Branding** — logo and receipt header per company
- **Versioning** — customers will not all be on the same build; the sync API must
  tolerate older clients
- **Diagnostics** — remote view of a device's sync state and outbox depth

---

## 9. Failure handling

| Failure | Behaviour |
|---|---|
| Hub tablet dies | Another is promoted. Billing unaffected. |
| Tablet lost / stolen | Unsynced sales are lost — push early and often, not once a day. Revoke its CSID. |
| Backend unreachable | Outbox grows, retries with backoff. No user-visible effect. |
| ERP rejects a sale | Flag and alert; never silently drop. |
| ZATCA rejects an invoice | Keep the sale, surface it for correction. The sale happened; the record must not vanish. |
| Clock drift | ZATCA timestamps must be right. Sync on every connection; warn above 60s drift. |
| CSID expired | Warn well ahead; renewal is our responsibility as service provider. |

---

## 10. Stack

| Layer | Choice | Why |
|---|---|---|
| App | Flutter (Android + Windows) | one codebase for both targets |
| Local DB | SQLite via `drift`, SQLCipher | type-safe queries, migrations, encryption |
| Hub server | `shelf` inside the app | no extra process on the tablet |
| Signing | `pointycastle` (ECDSA secp256k1) | what ZATCA requires |
| Backend | FastAPI + PostgreSQL (RLS) | matches existing tooling; RLS enforces tenancy |
| ERP link | Oracle APEX REST | integrated mode only |

---

## 11. Migration from PixelPoint

The existing `PixelSQLbase` (SQL Anywhere 16) is our first customer's data:
61,165 bills, 560 products, 13 staff, 3 stations.

- Catalog (`Product`, `PIXELMENU`, `MenuProdPos`, `MethodPay`, `employee`) imported
  and slimmed — PixelPoint's `Product` has 130+ columns; the new schema keeps ~15
- Historical sales stay read-only for reporting; they are **not** replayed through
  ZATCA — they were already invoiced under PixelPoint
- Cut over at a clean business-day boundary; keep PixelPoint readable for at least
  one full VAT filing period

This migration doubles as the template for onboarding future PixelPoint customers,
which is worth building properly rather than as a one-off script.

---

## 12. Open questions

- Licence enforcement: what exactly happens when a subscription lapses mid-service?
- Multi-branch consolidation: does a tenant need cross-branch reporting in the POS
  back-office, or is that always the ERP's job?
- Offline window: how long may a tablet run disconnected before we hard-block new
  sales? ZATCA's 24h reporting rule is the outer bound.
- ERP integration contract — see `erp-questions.md`.
