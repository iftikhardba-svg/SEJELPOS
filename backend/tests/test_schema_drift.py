"""Catch drift between models.py and docs/backend_schema.sql.

There are two definitions of the same database: the SQLAlchemy models the
application uses, and the hand-written SQL that actually gets deployed (which
also carries the RLS policies the ORM cannot express). Nothing keeps them in
step, and they have already diverged once — `company.address` was JSONB in the
schema and TEXT in the models, which only surfaced the first time the suite ran
against a real PostgreSQL.

This compares the models against a live PostgreSQL built from the SQL file.

The structural fix is Alembic, with models as the single source of truth and the
RLS policies as a hand-written migration. Until that exists, this test is the
guard rail.
"""

from __future__ import annotations

import os

import pytest

asyncpg = pytest.importorskip("asyncpg")

PG_DSN = os.environ.get("POS_TEST_PG")
pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(not PG_DSN, reason="POS_TEST_PG not set"),
]

# Types that differ in name but are the same thing to the driver.
EQUIVALENT = {
    ("VARCHAR", "text"), ("TEXT", "text"),
    ("BIGINT", "bigint"), ("INTEGER", "integer"),
    ("BOOLEAN", "boolean"), ("DATE", "date"),
    ("TIMESTAMP", "timestamp with time zone"),
    ("UUID", "uuid"), ("NUMERIC", "numeric"),
    ("JSONB", "jsonb"), ("JSON", "jsonb"),
}


def _comparable(sa_type: str, pg_type: str) -> bool:
    sa = sa_type.split("(")[0].upper()
    if (sa, pg_type) in EQUIVALENT:
        return True
    # VARCHAR(n) and TEXT are interchangeable for our purposes.
    if sa in ("VARCHAR", "TEXT") and pg_type in ("text", "character varying"):
        return True
    return sa.lower() == pg_type


async def _live_columns(table: str) -> dict[str, dict]:
    conn = await asyncpg.connect(PG_DSN)
    try:
        rows = await conn.fetch(
            """SELECT column_name, data_type, is_nullable
               FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = $1""",
            table,
        )
    finally:
        await conn.close()
    return {
        r["column_name"]: {
            "type": r["data_type"],
            "nullable": r["is_nullable"] == "YES",
        }
        for r in rows
    }


async def test_every_model_table_exists():
    from app.db import Base

    conn = await asyncpg.connect(PG_DSN)
    try:
        rows = await conn.fetch(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = 'public'"
        )
    finally:
        await conn.close()

    live = {r["table_name"] for r in rows}
    missing = set(Base.metadata.tables) - live
    assert not missing, f"models declare tables missing from the SQL schema: {missing}"


async def test_model_columns_exist_with_compatible_types():
    from app.db import Base

    problems: list[str] = []
    for name, table in Base.metadata.tables.items():
        live = await _live_columns(name)
        if not live:
            continue
        for col in table.columns:
            if col.name not in live:
                problems.append(f"{name}.{col.name} missing from the SQL schema")
                continue
            pg = live[col.name]
            try:
                sa_type = col.type.compile(dialect=_pg_dialect())
            except Exception:
                continue
            if not _comparable(sa_type, pg["type"]):
                problems.append(
                    f"{name}.{col.name}: model says {sa_type}, "
                    f"database says {pg['type']}"
                )

    assert not problems, "model/schema drift:\n  " + "\n  ".join(problems)


async def test_nullability_matches_where_it_matters():
    """A column the model thinks is optional but the database requires will
    fail at insert time, in production, on a real sale."""
    from app.db import Base

    problems: list[str] = []
    for name, table in Base.metadata.tables.items():
        live = await _live_columns(name)
        if not live:
            continue
        for col in table.columns:
            pg = live.get(col.name)
            if pg is None or col.primary_key:
                continue
            if col.nullable and not pg["nullable"]:
                problems.append(
                    f"{name}.{col.name}: model allows NULL, database does not"
                )

    assert not problems, "nullability drift:\n  " + "\n  ".join(problems)


def _pg_dialect():
    from sqlalchemy.dialects import postgresql

    return postgresql.dialect()
