"""POS sync backend."""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI

from .config import settings
from .db import create_all
from .routers import catalog, floor, kds, provisioning, sales


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Fails fast rather than serving a deployment that uses the published
    # development JWT secret. See config.check_production_safety.
    settings.check_production_safety()

    if not settings.is_postgres:
        # Dev/test convenience only. Production runs migrations, and needs them
        # anyway for the Row Level Security policies, which the ORM cannot
        # express — see docs/backend_schema.sql.
        await create_all()
    yield


app = FastAPI(
    title="POS Sync API",
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(catalog.router, prefix="/v1")
app.include_router(sales.router, prefix="/v1")
app.include_router(floor.router, prefix="/v1")
app.include_router(kds.router, prefix="/v1")
app.include_router(provisioning.router, prefix="/v1")


@app.get("/health", tags=["ops"])
async def health() -> dict:
    return {"status": "ok", "postgres": settings.is_postgres}
