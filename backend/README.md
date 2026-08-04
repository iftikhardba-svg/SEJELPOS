# POS sync backend

Multi-tenant FastAPI service the tablets sync against.

```powershell
$env:POS_DATABASE_URL = "sqlite+aiosqlite:///./pos_dev.db"
python -m uvicorn app.main:app --reload
```

Docs at `/docs`. Tests: `python -m pytest` (SQLite, no server needed).

## Schema and migrations

`app/models.py` is the single source of truth. Migrations are generated from it:

```powershell
alembic upgrade head                                  # build or update a database
alembic revision --autogenerate -m "what changed"     # after editing models.py
alembic check                                         # models vs database
```

Row Level Security, CHECK constraints and the non-superuser `pos_app` role
cannot be expressed by the ORM and live in a hand-written migration
(`5650ee789d9a_...`). `docs/backend_schema.sql` is superseded and kept only as
a tombstone explaining why.

## Endpoints

| | |
|---|---|
| `GET /v1/catalog?since=<version>` | incremental catalog pull |
| `POST /v1/sales` | batch push of closed sales, idempotent |
| `GET /v1/sales/{uuid}/status` | what happened to a pushed sale |
| `GET /health` | liveness |

## The parts that carry weight

**Tenant comes from the token, never from the request.** A tenant id accepted
from a caller is an invitation to read another customer's sales. `DeviceContext`
is resolved from the bearer token and every query is scoped to it.

**Idempotency.** A tablet that drops its connection mid-push will retry, and the
retry must not charge the customer twice. `sale_uuid` is the idempotency key; a
replay returns `duplicate`, not an error, so the device can clear its outbox.
If the same uuid arrives with a *different* receipt number that is a device bug,
and it is rejected rather than silently stored.

**Per-sale results in a batch.** One malformed sale does not fail the batch —
otherwise a single poison record stalls the outbox forever and the device never
drains.

**Arithmetic is validated at the boundary.** Lines must reconcile
(`net + tax == total`), lines must sum to the sale, payments must cover it. An
offline device is the only witness to what happened; if its maths disagrees with
itself we want to know at ingest, not at VAT filing.

**A closed sale without a ZATCA QR is rejected.** The device signs before it
prints, so an unsigned sale means the receipt the customer is holding was not
compliant. That is worth failing loudly.

**Reused invoice counters are rejected** by a unique index on
`(device_id, zatca_icv)` — reuse breaks that device's ZATCA hash chain.

**A stale sale is stored, then flagged.** Past ZATCA's 24-hour reporting window
the sale is still real and still recorded; it is marked for follow-up. Dropping
it would lose money and a tax record.

**An expired licence does not kill a till mid-service.** Selling continues
through the grace window; only past that is the device cut off.

## Running the tests

```powershell
python -m pytest        # SQLite; RLS and drift tests skip
```

Against PostgreSQL, which is the only way to exercise RLS and schema drift:

```powershell
createdb pos_test
$env:POS_DATABASE_URL = "postgresql+asyncpg://postgres:postgres@localhost:5432/pos_test"
$env:POS_TEST_PG      = "postgresql://postgres:postgres@localhost:5432/pos_test"
alembic upgrade head
python -m pytest        # 35 tests
```

## What running against PostgreSQL found

Defects SQLite could never have surfaced:

1. **`SET LOCAL app.tenant_id = :tid` does not work.** PostgreSQL's `SET` takes
   no bind parameters, so every tenant-scoped request would have failed in
   production — the entire RLS mechanism was inert. Now uses `set_config()`,
   which is parameterised and transaction-local.
2. **Model/schema drift.** `company.address` was `JSONB` in the SQL and `TEXT`
   in the models; `staff.pin_hash` was `NOT NULL` after migration made it
   nullable; several columns existed only in the models. Fixed structurally —
   there is now one definition, and `tests/test_migrations.py` fails the build
   if models and migrations disagree.
3. **Defaults that lived only in Python.** `default=` is a SQLAlchemy-side
   value: anything writing to the database another way — the catalog importer,
   provisioning scripts, the ERP worker, a DBA at a psql prompt — inserted NULL
   into a NOT NULL column. Every such column now carries a `server_default` too.
   Primary keys deliberately do not: SQLite has no `gen_random_uuid()`, so id
   generation stays with the application.
4. **Dead schema objects.** `ingest_log` and `catalog_version_seq` existed in
   the hand-written SQL and nothing ever used them. Dropped rather than carried
   forward — idempotency is enforced by `sale_uuid` being the primary key.
5. **Test loop scope.** Function-scoped event loops break connection pooling
   with asyncpg.

## Known gaps

- **The app still connects as a superuser in these tests**, which bypasses RLS.
  The RLS suite proves the policies work for the non-superuser `pos_app` role,
  but wiring the application itself to that role needs a second, privileged role
  for tenant provisioning — creating a tenant cannot be done from inside a
  tenant scope. Worth doing before onboarding a second customer.
- No device enrolment endpoint — tokens are minted directly via
  `issue_device_token`. Provisioning flow still to build.
- No ERP push worker and no ZATCA reporting worker; sales land with
  `zatca_status='pending'` and `erp_status='pending'` and nothing drains them yet.
- Catalog does not page. It returns the whole delta and fails loudly above
  `catalog_page_size` rather than truncating — fine for a restaurant catalog
  (~1,200 rows), not fine for a chain with a very large menu.
