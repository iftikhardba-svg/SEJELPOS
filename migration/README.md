# PixelPoint → new POS catalog migration

Moves catalog data (products, menus, payment methods, staff, tax) out of a
PixelPoint SQL Anywhere database into the new POS schema.

Historical **sales are not migrated** — they stay in PixelPoint, readable for
reporting. They were already invoiced under the old system and must never be
re-reported to ZATCA.

## Run it

```powershell
.\run.ps1 -Fresh
```

Four stages, each usable on its own:

| | Script | Runs on | Does |
|---|---|---|---|
| 1 | `extract.py` | **32-bit** Python | PixelPoint → `out/extracted.json` |
| 2 | `transform.py` | any Python | → new schema shape, money to halalas |
| 3 | `load_sqlite.py` | any Python | → tablet SQLite |
| 4 | `verify.py` | any Python | checks the result, non-zero exit on failure |

Extraction needs 32-bit Python because the SQL Anywhere ODBC driver installed
here is 32-bit only — a 64-bit process cannot load it.

## What it does with the awkward parts

**Money.** PixelPoint stores prices as C doubles. Everything converts to integer
halalas through `Decimal`, never through float arithmetic: `4.35 * 100` is
434.99999999999994 in binary floating point, and truncating that loses a halala
on a tax invoice. `verify.py` re-checks every price against the source.

**PINs are not migrated.** The source has none worth keeping — every employee
except `Supervisor` has a NULL login code, and Supervisor's is the vendor
default `12345`. Staff arrive with `must_set_pin = 1` and cannot log in until a
PIN is set. Importing a default credential into a product sold to many customers
would ship the same open door to all of them.

**Modifiers vs products.** PixelPoint has no flag distinguishing them. A product
is treated as a modifier if it only ever appears on modifier screens (categories
named *Hold* / *Extra* / *Modify*), or if it is typed as a kitchen comment button
(`PRODTYPE = 12`, e.g. *BBQ COMMENTS*). Everything else is sellable.

**The VAT rate is derived, not assumed.** `transform.py` recovers the effective
rate from 200 real sales and warns if it is not 15%. Every price depends on that
number being right.

## Findings from the first customer's data

Surfaced as warnings, not silently fixed — they are business decisions:

- **70 products sit on no menu screen.** Imported, but staff cannot ring them up.
  Most look like dead catalogue entries.
- **68 active sellable products have price 0** and are not open-price. Either
  misconfigured or unpriced extras.
- **Payment method 1008 "Discover Card" is flagged as cash**, which affects
  drawer behaviour and cash-up. Almost certainly a config error.
- **No Arabic names anywhere.** ZATCA needs the seller name in Arabic (company
  config, not migrated data). Arabic product names would have to be added.

## Re-running

Safe. Catalog rows upsert on their business key, so a re-run converges rather
than duplicating. `pin_hash` is deliberately **not** overwritten on conflict — a
catalog refresh must not wipe PINs staff have already set.
