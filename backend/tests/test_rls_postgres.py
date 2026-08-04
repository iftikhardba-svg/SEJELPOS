"""Row Level Security tests — these need a real PostgreSQL.

SQLite has no RLS, so the isolation tests in `test_sync.py` only exercise the
application's query filters. These tests prove the other half: that the
**database itself** refuses cross-tenant access, so a query that forgets its
filter still cannot leak one customer's data to another.

Run with a superuser connection string so the fixture can create roles and seed
both tenants:

    $env:POS_TEST_PG = "postgresql://postgres:postgres@localhost:5432/pos_rls_test"
    python -m pytest tests/test_rls_postgres.py

Skipped entirely when POS_TEST_PG is unset.
"""

from __future__ import annotations

import os
import uuid

import pytest

asyncpg = pytest.importorskip("asyncpg")

PG_DSN = os.environ.get("POS_TEST_PG")
pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(not PG_DSN, reason="POS_TEST_PG not set"),
]

APP_PASSWORD = "rls-test-password"


def _app_dsn() -> str:
    """Same database, but as the non-superuser application role."""
    tail = PG_DSN.split("@", 1)[1]
    return f"postgresql://pos_app:{APP_PASSWORD}@{tail}"


@pytest.fixture(autouse=True)
async def _app_role_password():
    """Give the app role a known password. Autouse: every test connects as it."""
    su = await asyncpg.connect(PG_DSN)
    try:
        await su.execute(f"ALTER ROLE pos_app WITH PASSWORD '{APP_PASSWORD}'")
    finally:
        await su.close()


@pytest.fixture
async def tenants():
    """Two tenants, each with one product. Seeded as superuser."""
    su = await asyncpg.connect(PG_DSN)
    try:
        made = {}
        for key, prodnum in (("a", 2001), ("b", 9001)):
            tid = uuid.uuid4()
            slug = f"{key}-{uuid.uuid4().hex[:8]}"
            await su.execute(
                "INSERT INTO tenant (id, name, slug) VALUES ($1, $2, $3)",
                tid, f"Tenant {key}", slug,
            )
            cid = uuid.uuid4()
            await su.execute(
                """INSERT INTO company (id, tenant_id, name, vat_number, address)
                   VALUES ($1, $2, $3, $4, '{}'::jsonb)""",
                cid, tid, f"Co {key}", f"3{uuid.uuid4().int % 10**14:014d}",
            )
            # Primary keys are supplied explicitly: uuid generation is a Python
            # default on the model, not a server default, because SQLite has no
            # gen_random_uuid() and the dev path builds its schema with
            # create_all(). Anything inserting outside SQLAlchemy owns its ids.
            await su.execute(
                """INSERT INTO product
                     (id, tenant_id, prodnum, descript, price_a, server_version)
                   VALUES ($1, $2, $3, $4, $5, 1)""",
                uuid.uuid4(), tid, prodnum, f"Item {prodnum}", 3800,
            )
            made[key] = {"tenant_id": tid, "company_id": cid, "prodnum": prodnum}

        yield made

        for v in made.values():
            await su.execute("DELETE FROM product WHERE tenant_id = $1", v["tenant_id"])
            await su.execute("DELETE FROM company WHERE tenant_id = $1", v["tenant_id"])
            await su.execute("DELETE FROM tenant WHERE id = $1", v["tenant_id"])
    finally:
        await su.close()


async def _as_tenant(tenant_id, sql, *args):
    """Run a query as the application role, scoped to one tenant."""
    conn = await asyncpg.connect(_app_dsn())
    try:
        async with conn.transaction():
            await conn.execute("SELECT set_config('app.tenant_id', $1, true)",
                               str(tenant_id))
            return await conn.fetch(sql, *args)
    finally:
        await conn.close()


# --------------------------------------------------------------------------

async def test_app_role_is_not_superuser():
    """The whole mechanism collapses if the app connects as a superuser."""
    conn = await asyncpg.connect(_app_dsn())
    try:
        assert await conn.fetchval("SELECT current_setting('is_superuser')") == "off"
    finally:
        await conn.close()


async def test_tenant_sees_only_its_own_rows(tenants):
    rows = await _as_tenant(tenants["a"]["tenant_id"], "SELECT prodnum FROM product")
    nums = {r["prodnum"] for r in rows}
    assert tenants["a"]["prodnum"] in nums
    assert tenants["b"]["prodnum"] not in nums


async def test_unfiltered_query_still_cannot_leak(tenants):
    """The point of RLS: no WHERE clause, and still no other tenant's data.

    This is the case application-level filtering cannot protect against — one
    forgotten predicate in one query.
    """
    rows = await _as_tenant(
        tenants["b"]["tenant_id"], "SELECT tenant_id, prodnum FROM product"
    )
    assert {r["tenant_id"] for r in rows} == {tenants["b"]["tenant_id"]}


async def test_explicitly_targeting_another_tenant_returns_nothing(tenants):
    """Even naming the other tenant's id outright is refused."""
    rows = await _as_tenant(
        tenants["a"]["tenant_id"],
        "SELECT prodnum FROM product WHERE tenant_id = $1",
        tenants["b"]["tenant_id"],
    )
    assert rows == []


async def test_no_tenant_set_means_no_rows(tenants):
    """Fail closed: a connection that forgets to scope itself sees nothing."""
    conn = await asyncpg.connect(_app_dsn())
    try:
        rows = await conn.fetch("SELECT prodnum FROM product")
        assert rows == []
    finally:
        await conn.close()


async def test_cannot_insert_rows_for_another_tenant(tenants):
    """WITH CHECK stops a compromised or buggy request writing across tenants."""
    conn = await asyncpg.connect(_app_dsn())
    try:
        async with conn.transaction():
            await conn.execute(
                "SELECT set_config('app.tenant_id', $1, true)",
                str(tenants["a"]["tenant_id"]),
            )
            with pytest.raises(asyncpg.exceptions.InsufficientPrivilegeError):
                await conn.execute(
                    """INSERT INTO product
                         (tenant_id, prodnum, descript, price_a, server_version)
                       VALUES ($1, 7777, 'smuggled', 100, 1)""",
                    tenants["b"]["tenant_id"],
                )
    finally:
        await conn.close()


async def test_scope_does_not_leak_between_transactions(tenants):
    """SET LOCAL is transaction-scoped, so a pooled connection cannot carry
    one request's tenant into the next."""
    conn = await asyncpg.connect(_app_dsn())
    try:
        async with conn.transaction():
            await conn.execute("SELECT set_config('app.tenant_id', $1, true)",
                               str(tenants["a"]["tenant_id"]))
            assert len(await conn.fetch("SELECT 1 FROM product")) >= 1

        # New transaction, no scope set — must see nothing.
        async with conn.transaction():
            assert await conn.fetch("SELECT 1 FROM product") == []
    finally:
        await conn.close()


async def test_application_cannot_delete_sales(tenants):
    """Sales are append-only; a tax record must not be deletable by the app."""
    conn = await asyncpg.connect(_app_dsn())
    try:
        async with conn.transaction():
            await conn.execute("SELECT set_config('app.tenant_id', $1, true)",
                               str(tenants["a"]["tenant_id"]))
            with pytest.raises(asyncpg.exceptions.InsufficientPrivilegeError):
                await conn.execute("DELETE FROM sale")
    finally:
        await conn.close()
