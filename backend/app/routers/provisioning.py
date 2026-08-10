"""Device provisioning and order numbers.

How a fresh tablet becomes a device:

1. Back office calls `POST /admin/enrolments` (admin token) and gets a one-time
   code for a branch.
2. Whoever is setting the tablet up types the code in; the app calls
   `POST /enrol` with it and its own device uuid.
3. The code resolves to a tenant and branch, the device row is created, the
   code is burned, and the tablet receives its JWT. From then on it is an
   ordinary authenticated device.

Order numbers are the short numbers called out at the counter. They are
allocated here when the device is online — a single atomic upsert per branch
and business day, so two tills can never be handed the same number. Offline,
the device falls back to its hub; the numbers reset daily either way.
"""

from __future__ import annotations

import datetime as dt
import secrets

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select

from ..auth import DeviceContext, current_device, issue_device_token, require_admin
from ..config import settings
from ..db import SessionLocal, tenant_session
from ..models import Branch, Company, Device, EnrolmentCode, OrderNumberCounter, Tenant
from ..schemas import (
    EnrolmentCodeOut,
    EnrolmentCreateIn,
    EnrolmentRedeemIn,
    EnrolmentRedeemOut,
    OrderNumberIn,
    OrderNumberOut,
)

router = APIRouter(tags=["provisioning"])


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _aware(value: dt.datetime) -> dt.datetime:
    """SQLite hands back naive datetimes; treat them as the UTC they were."""
    if value.tzinfo is None:
        return value.replace(tzinfo=dt.timezone.utc)
    return value


# --------------------------------------------------------------------------
# Admin: create an enrolment code
# --------------------------------------------------------------------------

@router.post(
    "/admin/enrolments",
    response_model=EnrolmentCodeOut,
    status_code=201,
    dependencies=[Depends(require_admin)],
)
async def create_enrolment(body: EnrolmentCreateIn) -> EnrolmentCodeOut:
    async with SessionLocal() as session:
        branch = (
            await session.execute(select(Branch).where(Branch.id == body.branch_id))
        ).scalar_one_or_none()
        if branch is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such branch")

        code = EnrolmentCode(
            tenant_id=branch.tenant_id,
            branch_id=branch.id,
            code=secrets.token_urlsafe(32),
            label=body.label,
            receipt_prefix=body.receipt_prefix,
            role=body.role,
            kds_station_no=body.kds_station_no,
            expires_at=_now() + dt.timedelta(hours=settings.enrolment_code_hours),
        )
        session.add(code)
        await session.commit()
        return EnrolmentCodeOut(
            code=code.code,
            branch_id=branch.id,
            label=code.label,
            role=code.role,
            expires_at=_aware(code.expires_at),
        )


# --------------------------------------------------------------------------
# Device: redeem the code
# --------------------------------------------------------------------------

@router.post("/enrol", response_model=EnrolmentRedeemOut)
async def enrol(body: EnrolmentRedeemIn) -> EnrolmentRedeemOut:
    """Unauthenticated by design — this call is how a device *gets* its
    credential. The enrolment code is the secret."""
    async with SessionLocal() as session:
        row = (
            await session.execute(
                select(EnrolmentCode).where(EnrolmentCode.code == body.code)
            )
        ).scalar_one_or_none()
        if row is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown enrolment code")
        if row.used_at is not None:
            # A used code must never enrol a second device: if a code leaks
            # after use, the attacker gets nothing.
            raise HTTPException(status.HTTP_410_GONE, "code already used")
        if _aware(row.expires_at) < _now():
            raise HTTPException(status.HTTP_410_GONE, "code expired")

        tenant_id = row.tenant_id

    async with tenant_session(tenant_id) as session:
        existing = (
            await session.execute(
                select(Device).where(Device.device_uuid == body.device_uuid)
            )
        ).scalar_one_or_none()
        if existing is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "this device is already enrolled; deactivate it before re-enrolling",
            )

        code_row = (
            await session.execute(
                select(EnrolmentCode).where(EnrolmentCode.code == body.code)
            )
        ).scalar_one()

        device = Device(
            tenant_id=tenant_id,
            branch_id=code_row.branch_id,
            device_uuid=body.device_uuid,
            label=code_row.label,
            receipt_prefix=code_row.receipt_prefix,
            role=code_row.role,
            kds_station_no=code_row.kds_station_no,
            platform=body.platform,
            app_version=body.app_version,
        )
        session.add(device)
        code_row.used_at = _now()
        await session.flush()

        branch = (
            await session.execute(
                select(Branch).where(Branch.id == code_row.branch_id)
            )
        ).scalar_one()
        tenant = (
            await session.execute(select(Tenant).where(Tenant.id == tenant_id))
        ).scalar_one()
        company = (
            await session.execute(
                select(Company).where(Company.id == branch.company_id)
            )
        ).scalar_one()

        token = issue_device_token(device.id, tenant_id)
        return EnrolmentRedeemOut(
            token=token,
            device_id=device.id,
            role=device.role,
            receipt_prefix=device.receipt_prefix,
            kds_station_no=device.kds_station_no,
            branch_name=branch.name,
            tenant_mode=tenant.mode,
            seller_name=company.name,
            seller_name_ar=company.name_ar,
            seller_vat=company.vat_number,
            seller_cr=company.cr_number,
            seller_address=company.address or {},
        )


# --------------------------------------------------------------------------
# Order numbers
# --------------------------------------------------------------------------

@router.post("/orders/next", response_model=OrderNumberOut)
async def next_order_number(
    body: OrderNumberIn,
    ctx: DeviceContext = Depends(current_device),
) -> OrderNumberOut:
    """Reserve a run of customer-facing order numbers for the branch and day.

    One atomic upsert, so two tills asking at the same moment get disjoint
    runs. `next_number` stores what the *next* caller will receive, so the
    first number of this caller's run is the value after the increment minus
    the size of the run.

    Devices reserve a block and hand out from it locally. That is what lets a
    till keep calling out order numbers with no network, without two tills at
    one counter ever landing on the same number.
    """
    async with tenant_session(ctx.tenant_id) as session:
        dialect = session.bind.dialect.name
        if dialect == "postgresql":
            from sqlalchemy.dialects.postgresql import insert
        else:
            from sqlalchemy.dialects.sqlite import insert

        stmt = insert(OrderNumberCounter).values(
            tenant_id=ctx.tenant_id,
            branch_id=ctx.branch_id,
            business_date=body.business_date,
            next_number=1 + body.count,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=["tenant_id", "branch_id", "business_date"],
            set_={"next_number": OrderNumberCounter.next_number + body.count},
        ).returning(OrderNumberCounter.next_number)

        # SQLite needs the row's id supplied (no server-side uuid default).
        if dialect != "postgresql":
            import uuid as _uuid
            stmt = stmt.values(id=_uuid.uuid4())

        next_val = (await session.execute(stmt)).scalar_one()
        return OrderNumberOut(
            business_date=body.business_date,
            order_no=next_val - body.count,
            count=body.count,
        )
