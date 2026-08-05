"""Test fixtures.

The database URL must be set before the app package is imported: `settings` is
a frozen dataclass built at import time, and the engine is created from it.
"""

from __future__ import annotations

import datetime as dt
import os
import tempfile
import uuid

import pytest
import pytest_asyncio

# Default to a throwaway SQLite file, but honour an explicit override so the
# same suite can be run against PostgreSQL — which is the only way to catch
# drift between models.py and the hand-written docs/backend_schema.sql.
_TMP_DB = os.path.join(tempfile.gettempdir(), f"pos_test_{uuid.uuid4().hex}.db")
os.environ.setdefault("POS_DATABASE_URL", f"sqlite+aiosqlite:///{_TMP_DB}")
os.environ["POS_JWT_SECRET"] = "test-secret-long-enough-for-hmac-sha256-abcdef"

from httpx import ASGITransport, AsyncClient  # noqa: E402

from app.auth import issue_device_token  # noqa: E402
from app.db import SessionLocal, create_all, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.office_auth import hash_password, issue_office_token  # noqa: E402
from app.models import (  # noqa: E402
    BackOfficeUser,
    Branch,
    Company,
    Device,
    Licence,
    MenuScreen,
    PayMethod,
    Product,
    Staff,
    TaxRate,
    Tenant,
)

# Shared by every seeded back-office user. Hashing is scrypt and deliberately
# slow, so one constant keeps the suite from paying that cost per fixture.
OFFICE_PASSWORD = "test-office-password"


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


@pytest.fixture(scope="session")
def anyio_backend():
    return "asyncio"


@pytest_asyncio.fixture
async def seeded():
    """Two tenants with their own data, so isolation can actually be tested."""
    await create_all()

    made = {}
    async with SessionLocal() as s:
        async with s.begin():
            for key, slug, prodnum, price in (
                ("a", "alpha-foods", 2001, 3800),
                ("b", "beta-grill", 9001, 1500),
            ):
                tenant = Tenant(name=slug, slug=f"{slug}-{uuid.uuid4().hex[:6]}")
                s.add(tenant)
                await s.flush()

                company = Company(
                    tenant_id=tenant.id,
                    name=f"{slug} Co",
                    name_ar="شركة",
                    vat_number="3" + uuid.uuid4().int.__str__()[:14],
                    address={
                        "street": "King Fahd Road",
                        "building": "1234",
                        "city": "Riyadh",
                        "postal_code": "12345",
                        "country": "SA",
                    },
                )
                s.add(company)
                await s.flush()

                branch = Branch(
                    tenant_id=tenant.id,
                    company_id=company.id,
                    code=f"BR-{key.upper()}",
                    name=f"{slug} Branch",
                )
                s.add(branch)
                await s.flush()

                device = Device(
                    tenant_id=tenant.id,
                    branch_id=branch.id,
                    device_uuid=f"dev-{key}-{uuid.uuid4().hex[:8]}",
                    label=f"Tablet {key.upper()}",
                    receipt_prefix=f"T0{1 if key == 'a' else 2}",
                    csid_status="production",
                )
                s.add(device)

                s.add(Licence(
                    tenant_id=tenant.id,
                    plan="pro",
                    max_devices=5,
                    max_branches=2,
                    starts_at=_now() - dt.timedelta(days=30),
                    expires_at=_now() + dt.timedelta(days=300),
                ))

                s.add(Product(
                    tenant_id=tenant.id,
                    branch_id=branch.id,
                    prodnum=prodnum,
                    descript=f"Item {prodnum}",
                    price_a=price,
                    tax_applies=True,
                    server_version=1,
                ))
                s.add(MenuScreen(
                    tenant_id=tenant.id,
                    branch_id=branch.id,
                    menu_id=10,
                    name=f"{slug} menu",
                    server_version=1,
                ))
                s.add(PayMethod(
                    tenant_id=tenant.id,
                    company_id=company.id,
                    methodnum=1001,
                    descript="CASH",
                    is_cash=True,
                    opens_drawer=True,
                    server_version=1,
                ))
                s.add(Staff(
                    tenant_id=tenant.id,
                    branch_id=branch.id,
                    empnum=999,
                    name="Supervisor",
                    pin_hash=None,
                    must_set_pin=True,
                    server_version=1,
                ))
                # A tax rate in every seed: the catalog endpoint serialising
                # TaxRate rows once went untested because no fixture had one,
                # and the gap only surfaced in a live end-to-end run.
                s.add(TaxRate(
                    tenant_id=tenant.id,
                    company_id=company.id,
                    tax_id=1,
                    name="VAT",
                    percent=15,
                    is_inclusive=True,
                    effective_from=dt.date(2020, 7, 1),
                    server_version=1,
                ))
                await s.flush()

                # A back-office owner per tenant, so cross-tenant access can
                # be tested from the office side as well as the device side.
                office_email = f"owner-{key}-{uuid.uuid4().hex[:8]}@example.sa"
                office_user = BackOfficeUser(
                    tenant_id=tenant.id,
                    email=office_email,
                    name=f"Owner {key.upper()}",
                    role="owner",
                    password_hash=hash_password(OFFICE_PASSWORD),
                )
                s.add(office_user)
                await s.flush()

                made[key] = {
                    "tenant_id": tenant.id,
                    "company_id": company.id,
                    "branch_id": branch.id,
                    "device_id": device.id,
                    "prodnum": prodnum,
                    "token": issue_device_token(device.id, tenant.id),
                    "office_email": office_email,
                    "office_user_id": office_user.id,
                    "office_token": issue_office_token(office_user.id, tenant.id),
                }

    yield made


@pytest_asyncio.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture(scope="session", autouse=True)
async def _cleanup():
    yield
    await engine.dispose()
    try:
        os.remove(_TMP_DB)
    except OSError:
        pass
