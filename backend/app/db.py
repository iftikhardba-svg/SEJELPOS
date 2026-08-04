"""Database engine, sessions, and tenant scoping.

Tenant isolation is enforced in two independent places, on purpose:

1. **PostgreSQL Row Level Security.** Every request runs
   `SET LOCAL app.tenant_id = ...`, and the policies in `backend_schema.sql`
   make the database itself refuse rows belonging to anyone else. If a query
   forgets its filter, RLS still holds.

2. **Explicit tenant filters in queries.** Belt and braces — and it means the
   test suite can run on SQLite, which has no RLS, and still prove the query
   layer scopes correctly.

Neither is redundant: RLS is the guarantee, the filters make intent visible and
testable.
"""

from __future__ import annotations

import contextlib
import uuid
from collections.abc import AsyncIterator

from sqlalchemy import event, text
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from .config import settings


class Base(DeclarativeBase):
    pass


engine = create_async_engine(settings.database_url, echo=False, future=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


if settings.database_url.startswith("sqlite"):
    @event.listens_for(engine.sync_engine, "connect")
    def _sqlite_pragmas(dbapi_conn, _):
        cur = dbapi_conn.cursor()
        cur.execute("PRAGMA foreign_keys=ON")
        cur.close()


@contextlib.asynccontextmanager
async def tenant_session(tenant_id: uuid.UUID) -> AsyncIterator[AsyncSession]:
    """A session scoped to one tenant for its whole lifetime.

    On PostgreSQL this sets the RLS variable; `SET LOCAL` is transaction-scoped,
    so it cannot leak into another request even if the connection is reused.
    """
    async with SessionLocal() as session:
        async with session.begin():
            if settings.is_postgres:
                # set_config(), not `SET LOCAL app.tenant_id = :tid`: PostgreSQL's
                # SET statement does not accept bind parameters, so that form
                # fails at runtime. Interpolating the id into the SQL would work
                # but hands the isolation key to string formatting, which is the
                # last place it belongs. set_config takes it as a parameter.
                # The third argument, true, makes it transaction-local, so a
                # pooled connection cannot carry one request's tenant into the next.
                await session.execute(
                    text("SELECT set_config('app.tenant_id', :tid, true)"),
                    {"tid": str(tenant_id)},
                )
            yield session


async def create_all() -> None:
    """Create tables from the models. Real deployments use migrations."""
    from . import models  # noqa: F401  (registers mappers)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
