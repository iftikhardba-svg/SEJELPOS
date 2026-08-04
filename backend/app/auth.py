"""Device authentication and tenant resolution.

The tenant is derived from the bearer token and **never** from anything the
client sends in the path, query or body. In a multi-tenant product, a tenant id
accepted from the caller is an invitation to read someone else's sales.
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass

import jwt
from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select

from .config import settings
from .db import SessionLocal
from .models import Branch, Device, Licence


@dataclass(frozen=True)
class DeviceContext:
    """Everything a request needs about who is calling."""
    device_id: uuid.UUID
    device_uuid: str
    tenant_id: uuid.UUID
    branch_id: uuid.UUID
    company_id: uuid.UUID
    receipt_prefix: str


def issue_device_token(device_id: uuid.UUID, tenant_id: uuid.UUID) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    payload = {
        "sub": str(device_id),
        "tid": str(tenant_id),
        "iat": now,
        "exp": now + dt.timedelta(days=settings.device_token_days),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def _decode(token: str) -> dict:
    try:
        return jwt.decode(
            token, settings.jwt_secret, algorithms=[settings.jwt_algorithm]
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "token expired")
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token")


async def current_device(
    authorization: str = Header(default=""),
) -> DeviceContext:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    claims = _decode(authorization.split(" ", 1)[1].strip())

    try:
        device_id = uuid.UUID(claims["sub"])
        tenant_id = uuid.UUID(claims["tid"])
    except (KeyError, ValueError):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "malformed token")

    async with SessionLocal() as session:
        row = (
            await session.execute(
                select(Device, Branch)
                .join(Branch, Branch.id == Device.branch_id)
                .where(Device.id == device_id, Device.tenant_id == tenant_id)
            )
        ).first()
        if row is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "unknown device")

        device, branch = row
        if not device.is_active:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "device deactivated")

        licence = (
            await session.execute(
                select(Licence)
                .where(Licence.tenant_id == tenant_id, Licence.is_active.is_(True))
                .order_by(Licence.expires_at.desc())
                .limit(1)
            )
        ).scalar_one_or_none()

    if licence is None:
        raise HTTPException(status.HTTP_402_PAYMENT_REQUIRED, "no active licence")

    # An expired licence does not cut a device off mid-service. Selling
    # continues through the grace window; only past that is the door closed.
    now = dt.datetime.now(dt.timezone.utc)
    expires = licence.expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=dt.timezone.utc)
    hard_stop = expires + dt.timedelta(days=licence.grace_days)
    if now > hard_stop:
        raise HTTPException(
            status.HTTP_402_PAYMENT_REQUIRED,
            f"licence expired on {expires.date()} and the grace period has ended",
        )

    return DeviceContext(
        device_id=device.id,
        device_uuid=device.device_uuid,
        tenant_id=tenant_id,
        branch_id=device.branch_id,
        company_id=branch.company_id,
        receipt_prefix=device.receipt_prefix,
    )


DeviceDep = Depends(current_device)


def require_admin(x_admin_token: str = Header(default="")) -> None:
    """Guard for back-office provisioning endpoints.

    Compares in constant time; an unset POS_ADMIN_TOKEN means the feature is
    switched off entirely rather than open.
    """
    import secrets as _secrets

    if not settings.admin_token:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "provisioning over the API is disabled (POS_ADMIN_TOKEN is not set)",
        )
    if not _secrets.compare_digest(x_admin_token, settings.admin_token):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "bad admin token")
