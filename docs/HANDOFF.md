# SEJEL POS — handoff

Everything a new engineer needs to pick this up on a different machine. Read
this once end to end before installing anything; the traps at the bottom cost
days when they were found the hard way.

Written 2026-08-12, at commit `2480084`.

---

## 1. What this is

A **commercial offline-first POS for Saudi restaurants**, sold by the owner's IT
company as a product in their Oracle APEX ERP line. It must run **standalone or
ERP-integrated**. It **replaces** PixelPoint at the first customer.

- **First customer:** SEJEL Restaurant, branch Olaya. Their live PixelPoint
  database (`C:\PIXELSQL\PIXELSQLBASE10.db`, SAP SQL Anywhere) is the source of
  the migrated menu, staff, tables and sales history. It is a **test/dev copy**
  and safe to work against.
- **Region rules that shape the code:** VAT 15%, menu prices are **VAT-inclusive**,
  and **ZATCA (Fatoora) Phase 2 is legally mandatory** — TLV QR, signed UBL 2.1
  XML, cryptographic stamp, invoice hash chain, reporting within 24 hours.
- **Primary hardware:** Android tablets. Windows desktop is secondary and is
  what everything has actually been demonstrated on so far. **iOS is ruled out**
  for the hub role because it suspends background apps.

Four things are worth understanding before touching the code, because they
explain most of its shape:

1. **The device always signs; only reporting varies.** A customer's receipt
   cannot wait for a network, so every tablet is its own ZATCA EGS unit with its
   own CSID, ICV and hash chain. Whether the signed invoice is *reported* by our
   backend or by the customer's ERP is a deployment choice, not a code path in
   the till.
2. **Offline-first is not a feature, it is the constraint.** The till owns its
   own SQLite database and completes a sale — pricing, ZATCA stamp, kitchen
   tickets, outbox row — in one local transaction. The backend is a sync peer,
   not a dependency.
3. **Multi-tenant SaaS with PostgreSQL Row Level Security**, not application
   `WHERE` clauses. Hierarchy is tenant → company (owns the VAT number) → branch
   → device, four levels because ZATCA EGS units hang off a legal entity's VAT
   registration.
4. **The trade mix decides what matters.** At the first customer: Drive-Thru
   51%, TakeAway 18%, aggregators 16%, dine-in 12%. The counter flow matters far
   more than table service, and MADA is ~65% of payments.

`docs/architecture.md` is the long version. This file is the operational one.

---

## 2. Setting up on a new laptop

### 2.1 What must be installed

| | Version used | Notes |
|---|---|---|
| **Python 64-bit** | 3.14.6 | Backend, ZATCA library, migration transform |
| **Python 32-bit** | 3.14 | **Only** for the PixelPoint ODBC bridge — see §7 |
| **Flutter** | 3.44.8 / Dart 3.12 | Shallow clone was at `C:\tools\flutter` |
| **Visual Studio** | C++ desktop workload | Required to build the Windows app |
| **Windows Developer Mode** | on | Flutter refuses to build otherwise |
| **PostgreSQL** | 17 | Only for the full test suite (RLS) — SQLite covers day-to-day |
| **Git** | any | |

Android SDK is **not** installed and never was. `flutter test` and
`flutter analyze` work; building an APK does not yet. That is a known gap.

### 2.2 Unpack

The handoff archive contains:

```
newpos/            the repository, working tree and .git together
sybase-mcp/        the 32-bit ODBC bridge to the PixelPoint database
local-data/        everything git deliberately does not carry — see §5
newpos.bundle      the same git history as a single clonable file
HANDOFF.md         this file
```

Put `newpos` and `sybase-mcp` side by side under a common folder. Paths in
tooling are relative within each project, but the shell examples below assume
`C:\projects\newpos`; adjust or keep the same layout.

If the `.git` folder does not survive the copy for any reason, the bundle is the
fallback:

```bash
git clone newpos.bundle newpos
```

Then restore the working tree from the archive over it, and re-add the remote
(§8).

### 2.3 Install dependencies

```bash
cd newpos/backend && python -m pip install -r requirements.txt
```

```bash
cd newpos/app && flutter pub get
```

### 2.4 Restore the local data

Nothing in `local-data/` is in git, and three of the four items are **customer
data or secrets**. Copy them back to:

| From `local-data/` | To |
|---|---|
| `migration-out/` | `newpos/migration/out/` |
| `backend-real.db` | `newpos/backend/real.db` |
| `migration-env.local.ps1` | `newpos/migration/env.local.ps1` |
| `sybase-mcp.env` | `sybase-mcp/.env` |

`backend/real.db` is the demo backend: the real customer catalog (560 products,
64 menu screens, 34 sale types, 150 tables), the back-office user, and the
sales, tables and kitchen tickets produced during development. **It is a
snapshot taken with `VACUUM INTO`**, so it is internally consistent even though
the backend was running when it was taken.

### 2.5 Prove the install

```bash
cd newpos/backend && python -m pytest -q
```

```bash
cd newpos/app && flutter test && flutter analyze
```

Both suites pass with no server running and no PostgreSQL. The numbers to
expect, as of this handoff: **222 backend tests pass and 14 skip** (the skips
are the PostgreSQL-only RLS and drift tests), and **245 Dart tests pass** with
`analyze` clean. If you see those, the install is good.

---

## 3. Running it

### 3.1 The backend

From `backend/`. The environment variables are not optional — the service
refuses to start without them, and the back office needs both.

```powershell
$env:POS_DATABASE_URL='sqlite+aiosqlite:///./real.db'
$env:POS_JWT_SECRET='validate-session-secret-key-at-least-44-chars-long'
$env:POS_ADMIN_TOKEN='validate-admin-token-24-chars'
python -m uvicorn app.main:app --port 8100
```

- API docs: `http://127.0.0.1:8100/docs`
- **Back office:** `http://127.0.0.1:8100/office`
- Back-office login on `real.db`: `owner@fatima.sa` / `fatima-office-pass`
  (the email is a leftover from the original placeholder tenant name; a real
  customer must never be given this account)

Those two secrets are development values, chosen to satisfy the length checks.
**Generate real ones for anything a customer touches.**

### 3.2 Building and running the app

```bash
cd app && flutter build windows --debug
```

The binary is `app/build/windows/x64/runner/Debug/pos_app.exe`.

**Three roles, one binary.** `device.role` — assigned at enrolment — decides
whether the app boots the till, the kitchen screen or the customer order board.
To run more than one on a single machine, give each its own database with
`--profile`:

```bash
pos_app.exe                          # the till   (%APPDATA%\sa.pos\pos_app\pos.db)
pos_app.exe --profile=kitchen        # KDS
pos_app.exe --profile=board --demo   # CDS, with the demo bar
```

An exclusive file lock refuses a **second copy of the same profile** with a
plain "already running" screen rather than letting two processes fight over one
SQLite file — which corrupted the device database three times before the lock
existed.

`--demo` adds the CDS demo bar (**New order**, **Kitchen bumps next**,
**Auto-cycle**). Those buttons write to the **real** kitchen queue, so a demo
can be driven from the board alone with no till.

### 3.3 Enrolling a device

A fresh profile has no credential and shows the enrolment screen. Get a code
from the back office (Devices tab, choose the role and — for KDS — the station),
then either type it in, or:

```bash
cd app && dart run tool/enrol_device.dart http://127.0.0.1:8100 <code>
```

**Argument order is `<baseUrl> <code> [dbPath]`.** Leave the path off and it
finds the app's own database. For a profile, pass the profile's path:
`%APPDATA%\sa.pos\pos_app\profiles\<name>\pos.db`.

Enrolment is also when the device receives its **seller identity** (VAT number,
Arabic name, CR, address, branch name). It is never refreshed by a catalog pull,
deliberately: a device's ZATCA hash chain must keep describing the identity its
invoices were issued under. **Renaming a company means re-enrolling its
devices.**

### 3.4 The demo flow, end to end

This is what to show, and it works today:

1. **Till** — floor plan → seat a table → order (a meal opens its modifier
   prompts) → **Send & save check** → later **Charge**, split the check between
   guests if asked, **Show receipt** to display the ZATCA invoice with its QR on
   screen.
2. **KDS** — the ticket appears on its station tab within a poll. Tick lines
   off, then **Bump**.
3. **CDS** — the number moves from *Preparing* to *Ready*. **Delivered** takes
   it off both screens.

Verified on the real system on 2026-08-12 (order 117): New order → both screens
show it → bump → Ready on the board and Done in the kitchen → Delivered → gone
from both, still in `kitchen_ticket` with status `collected`.

---

## 4. What is in the repository

```
app/         Flutter application — the till, KDS and CDS are roles of this one binary
  lib/data/       SQLite: schema, migrations, pricing, completeSale
  lib/sync/       enrolment, catalog delta, outbox push, order-number blocks
  lib/zatca/      Dart port of the Python library, pinned to it by golden vectors
  lib/printing/   ESC/POS receipt building, and the on-screen decoder
  lib/ui/         screens
  tool/           runnable proofs against a live backend (see below)
backend/     FastAPI multi-tenant sync API
  app/models.py   the single source of truth for the schema
  app/routers/    catalog, sales, floor, kds, office, enrolment
  app/static/office.html   the whole back office, one self-contained page
  migrations/     Alembic
  tools/          seed_dev.py, sync_dev_schema.py
zatca/       the reference implementation: TLV QR, ECDSA stamp, hash chain, UBL 2.1
migration/   PixelPoint extract → transform → load
docs/        architecture.md, the schema, the project plan, the published mockups
```

**`app/tool/` is not scratch work.** Each of those scripts enrols a throwaway
device against a live backend and drives the app's own code — they are the
proofs that something works on the *real* catalog, and they have caught defects
no unit test could:

| | |
|---|---|
| `e2e_smoke.dart` | enrol → catalog → sale → the ZATCA gate from both sides |
| `meal_deal_check.dart` | rings a real meal deal through `completeSale` |
| `split_check_check.dart` | seats a table, splits the check, adds the bills back up |
| `order_number_race.dart` | two tills, 100 numbers, proves none are shared |
| `enrol_device.dart` | enrol an installed device without touching its keyboard |

---

## 5. Secrets, customer data, and what git carries

`.gitignore` keeps three categories out of the repository on purpose:

- **`migration/env.local.ps1`** — holds the PixelPoint database password. The
  same password is in `sybase-mcp/.env`. `migration/run.ps1` refuses to run
  without the local copy. `env.example.ps1` is the committed template.
- **`migration/out/`** — the extracted customer data: their real menu, staff
  list and figures derived from their sales. The repository holds the tooling,
  not the customer's data.
- **`*.db`** — every local database.

**The GitHub repository must stay private.** The docs carry the customer's
business figures.

`local-data/` in the handoff archive is exactly these excluded items. Treat that
folder as confidential: it is a restaurant's commercial data and one live
database password.

---

## 6. Testing

```powershell
# Backend, SQLite — RLS, drift and migration tests skip
cd backend; $env:POS_DATABASE_URL=''; $env:POS_TEST_PG=''; python -m pytest

# Backend, PostgreSQL — the full suite
$env:POS_DATABASE_URL='postgresql+asyncpg://postgres:postgres@localhost:5432/pos_mig_test'
$env:POS_TEST_PG='postgresql://postgres:postgres@localhost:5432/pos_mig_test'
python -m pytest

# App
cd app; flutter test; flutter analyze
```

**Run the PostgreSQL suite before believing anything about tenant isolation.**
SQLite silently skips RLS and schema-drift tests, and doing exactly that once
hid a bug where `SET LOCAL app.tenant_id = :tid` fails on PostgreSQL — it takes
no bind parameters — which had left the entire RLS mechanism inert.

**After any change under `zatca/`**, regenerate the golden vectors and re-run
the Dart tests, or the two implementations drift apart silently:

```powershell
cd zatca; python tools\gen_golden.py     # writes app/test/zatca/golden.json
cd ..\app; flutter test test\zatca\
```

---

## 7. The PixelPoint source database

Only needed to re-extract the customer's data; the extract in `migration/out/`
is from 2026-08-04 and is enough for everything else.

The database is SAP SQL Anywhere and can only be reached through a **32-bit**
ODBC driver — this machine had no 64-bit SQL Anywhere driver, so a 64-bit
process cannot load it in-process. The bridge in `sybase-mcp/`:

- `server.py` runs on 64-bit Python, registered as the `sybase` MCP server
- `db_helper.py` runs on **32-bit** Python and does the ODBC work; the server
  shells out to it
- `q.ps1` is a shortcut for ad-hoc read-only queries
- credentials in `.env`; read-only is the default

The engine is started by `C:\PIXELSQL\start_pixelsql_v16.bat`. The database was
moved to the v16 engine but the catalog was left in v10 format on purpose —
`dbupgrad` was never run and is not needed.

Re-extract with `.\migration\run.ps1 -Fresh`, then load a backend:

```powershell
cd migration
python load_backend.py --in out/transformed.json `
  --database-url "sqlite+aiosqlite:///../backend/real.db" `
  --tenant-slug sejel --company "SEJEL Restaurant" --branch "Olaya" `
  --branch-code OLYA --vat-number 310000000000003 `
  --office-email owner@sejel.sa --office-password <choose one>
```

Idempotent. It warns about the 68 zero-priced products and the placeholder
seller address, both of which are still open items.

---

## 8. GitHub and the cloud account

Remote is `https://github.com/iftikhardba-svg/Demo.git`. That repository already
held an unrelated project on `origin/main`, so **this project lives on the `pos`
branch**:

```bash
git -C <path>/newpos push -u origin main:pos
```

Local `main` tracks `origin/pos`. As of this handoff there are **2 commits not
yet pushed** (`39343b4` project plan, `2480084` the KDS/CDS link) — push them
from the new machine once git credentials are set up there.

The published mockups are private Claude artifacts on the owner's account, and
their source HTML is also committed to `docs/preview/` so nothing depends on
those links surviving:

| | |
|---|---|
| Till | https://claude.ai/code/artifact/067a8968-d548-4198-acaa-3cf7f9896b77 |
| Floor plan | https://claude.ai/code/artifact/f8a9a6d1-4e89-432f-8ff4-1949acbe9f85 |
| Counter / Drive-Thru | https://claude.ai/code/artifact/ceb57d91-2f06-4efc-ac8f-4a71a9aab7b9 |
| KDS | https://claude.ai/code/artifact/f5a53866-8a8b-467b-8b88-77b294fbae26 |
| CDS order board | https://claude.ai/code/artifact/af315fa7-4b62-4269-8239-17e2ee05ecac |
| Build status | https://claude.ai/code/artifact/4ade2803-f42d-4cd9-8bdd-864b743fc5b7 |

They share one token system and a theme picker (`localStorage` keys
`pos.accent`, `pos.mode`); the owner chose the Foodics-style violet default.

---

## 9. Traps that cost real time

Each of these was found the expensive way. They are not hypothetical.

**The demo catalog hides bugs the real one exposes.** `seedDemoCatalog` has 2
products, one menu screen and `employee(empnum=0)`. The real catalog has 560
products, 64 screens (some empty), 34 sale types and no employee 0. Two hard
blockers survived every test because the demo masked them: the catalog endpoint
had no paging so **no real catalog could reach a device at all**, and every
charge failed with SQLite 787 because `sale.emp_open` is a NOT NULL FK and the
demo's employee 0 does not exist in real data. **Test against `real.db` before
believing anything works.**

**`real.db` and `dev_e2e.db` are outside Alembic.** `load_backend.py` and
`seed_dev.py` build them with `create_all`, so they carry no version stamp and
`alembic upgrade` cannot touch them. They drift silently until something fails
at runtime. After any schema change:

```bash
python backend/tools/sync_dev_schema.py real.db
```

That tool cannot see a **nullability** change. For those: stamp the database at
the revision before the change and run `alembic upgrade head`, which rebuilds
the table in batch mode.

**Bump `tabletSchemaVersion` and add a step for every schema change**, and never
edit a released step — `app/lib/data/schema_migrations.dart`, currently at **v7**.
Before it existed, any shipped schema change broke every installed till with
"no such column".

**A new catalog family needs a watermark reset.** Rows written before the
feature existed carry a `server_version` *below* an installed till's watermark,
so the device upgrades and never pulls them. v4 and v6 both reset the watermark
to 0 for exactly this reason. Re-pulling is free — every apply is an upsert.
Remember it for every future catalog family.

**`app/assets/schema.sql` is a byte copy of `docs/sqlite_schema.sql`.** One
schema, never re-declared in Dart. Re-copy it whenever the schema changes.

**Delphi `TColor` is `$00BBGGRR`, not RGB.** Read as RGB, the customer's pink
buttons come out blue. Negative values are Windows system colours and become
`null` so the till uses its theme.

**Kitchen stations are printer ports.** PixelPoint routes items via the
`PRINTLOC` bitmask (bit n = port n); the named ports are 2=Expo, 3=Grill,
4=Shawarma, 5=DT. The KDS keeps those numbers so imported routing stays valid.

**Aggregator orders charge price tier B**, walk-in charges tier A, and the
difference is the aggregator's commission. Falling back to tier A on a missing
tier B price would silently give the commission away — `pricing.py` refuses
instead.

**Screenshotting the running app is unreliable** and twice looked like an app
bug when it was not. Use `PrintWindow` with `PW_RENDERFULLCONTENT` *and* call
`SetProcessDPIAware()` first, and match the window by process name (`pos_app`),
not title — a browser on the back office also has "POS" in its title. Synthetic
clicks are **delayed, not dead**: one turned up in the app's persisted state
minutes later. Prefer widget tests with `tester.view.physicalSize` for anything
about layout.

**Nothing in `zatca/` has been validated against ZATCA's official SDK.** The
tests prove internal consistency only, and the Dart port shares every gap
identically. Sandbox validation is still required, and the enveloped signature
inside `UBLExtensions` is not implemented.

**`FileKeyProvider` stores the signing key as plaintext PEM** and is explicitly
not production. The private key **cannot** live in the Android Keystore —
Keystore holds NIST curves only and ZATCA mandates secp256k1. The achievable
design is a software key encrypted at rest under a Keystore-held AES key;
`ZatcaKeyProvider` in `device_signer.dart` is that seam.

---

## 10. Status: what is built, what is not

`docs/SEJEL-POS-Project-Plan.xlsx` is the tracked plan — 38 workstreams across
four sheets, with status and timeline. It is the authority; this is the summary.

**Working, tested, and demonstrated on the real catalog:**

migration from PixelPoint · multi-tenant backend with RLS · device enrolment ·
incremental catalog sync with tombstones and paging · offline `completeSale`
with pricing tiers · modifier/combo prompts · multi-tender with change ·
customer-facing order numbers reserved in blocks · table service, merging and
splitting a check between guests · pictures on till buttons · ESC/POS receipts
and the on-screen receipt with QR · KDS with station tabs · CDS order board ·
the back office (products, menus, layouts, floor plan, tables, modifiers,
devices, sales) · ZATCA signing on-device, cross-verified between the Dart and
Python implementations.

**Not built.** These are the customer's outstanding list, in the plan with
timelines:

Discount setup · Employee setup · Customer setup · Sales type setup · Payment
mode setup · Printer setup · Till setup · Modifiers setup (back office exists;
the master screens do not) · KDS setup · CDS setup · Kiosk · Report category
setup · Security setup · Reports.

**Also open:**

- **ZATCA sandbox validation and real CSIDs** — compliance is unproven until the
  Fatoora sandbox validates it, and the e2e uses a placeholder tag-9 value.
- **Encrypted key storage** must replace `FileKeyProvider` before any device
  ships.
- **Arabic on receipts** — needs printer codepage plus RTL shaping. Receipt text
  is ASCII-only today.
- **Android/APK builds** — the SDK is not installed anywhere yet.
- **68 active non-modifier products priced zero** need a human decision before
  go-live. The back office lists them (Products tab, "Priced zero" filter).
- `docs/erp-questions.md` still awaits the ERP team's answers on the API
  contract and master-data ownership. Not blocking standalone mode.

---

## 11. Where to pick up

The next piece of work, in the order it makes sense:

1. **Push the two unpushed commits** once git credentials exist on the new
   machine (§8).
2. **The setup masters from the customer's list.** They are mostly back-office
   CRUD over tables that already exist, and Payment mode / Sales type / Printer
   / Till are the ones the till itself already reads from the catalog — so they
   unblock configuring a *second* customer without a developer.
3. **Reports**, which is the largest single gap and the thing a restaurant owner
   judges the product by.
4. **Then ZATCA**: sandbox credentials, real CSIDs, encrypted key storage. The
   owner's priority, set explicitly, is *till first, ZATCA after* — but nothing
   ships to a live customer until this is done, so it cannot slip indefinitely.

A note on how this project has gone, because it will save the next person the
same discovery: **the defects that mattered were all found by running the real
app against the real catalog**, not by tests. Three separate data-loss bugs and
two "no catalog reaches the device at all" blockers were invisible to a green
suite. Keep the `app/tool/` proofs in the loop, and run the actual binary
against `real.db` before calling anything done.
