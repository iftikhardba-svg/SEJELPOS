"""POS sync backend."""

from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse, HTMLResponse

from .config import settings
from .db import create_all
from .routers import catalog, floor, kds, office, provisioning, sales

# The back office is one self-contained page served from here rather than a
# separate front-end build. It talks to the same API a third party would, so
# there is no privileged back door — and no second toolchain to install before
# a customer can see their sales.
OFFICE_HTML = Path(__file__).resolve().parent / "static" / "office.html"


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
app.include_router(office.router, prefix="/v1")


@app.get("/health", tags=["ops"])
async def health() -> dict:
    return {"status": "ok", "postgres": settings.is_postgres}


@app.get("/office", response_class=HTMLResponse, include_in_schema=False)
async def back_office() -> FileResponse:
    if not OFFICE_HTML.exists():
        raise RuntimeError(f"back office page missing at {OFFICE_HTML}")
    return FileResponse(OFFICE_HTML, media_type="text/html")
