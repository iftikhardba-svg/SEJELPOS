"""Back-office sign-in.

Separate from `auth.py` on purpose. That file authenticates *devices*, which
hold a long-lived token minted at enrolment and belong to one branch. This one
authenticates *people*, who type a password, get a short session, and work
across the branches of their tenant.

What both share is the rule that matters: **the tenant comes from the token and
never from the request.** A tenant id in a path or body is an invitation to read
someone else's sales.

Passwords are hashed with scrypt from the standard library rather than adding a
dependency. It is memory-hard, which is the property that matters against
offline cracking of a stolen table.
"""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import secrets
import uuid
from dataclasses import dataclass

import jwt
from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select

from .config import settings
from .db import SessionLocal
from .models import BackOfficeUser

# Chosen to cost roughly 100ms per verification on a normal server: slow enough
# to make a stolen table expensive to crack, fast enough that a login does not
# feel broken.
_SCRYPT_N = 2 ** 15
_SCRYPT_R = 8
_SCRYPT_P = 1
_SALT_BYTES = 16
_KEY_BYTES = 32

# scrypt needs 128 * N * r bytes — exactly 32 MiB at these parameters, which is
# OpenSSL's *default* ceiling, so it fails without an explicit allowance. Set
# high enough to leave headroom if the cost parameters are ever raised.
_SCRYPT_MAXMEM = 128 * _SCRYPT_N * _SCRYPT_R * 2

# Shorter than a device token by a wide margin. A device is a tablet bolted to a
# counter; this is a browser session that may be on a laptop in a café.
OFFICE_TOKEN_HOURS = 12


def hash_password(password: str) -> str:
    if len(password) < 8:
        raise ValueError("password must be at least 8 characters")
    salt = secrets.token_bytes(_SALT_BYTES)
    key = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=_SCRYPT_N,
        r=_SCRYPT_R,
        p=_SCRYPT_P,
        dklen=_KEY_BYTES,
        maxmem=_SCRYPT_MAXMEM,
    )
    return "scrypt${}${}${}${}${}".format(
        _SCRYPT_N,
        _SCRYPT_R,
        _SCRYPT_P,
        base64.b64encode(salt).decode("ascii"),
        base64.b64encode(key).decode("ascii"),
    )


def verify_password(password: str, encoded: str) -> bool:
    """Constant-time check. Returns False on a malformed hash rather than
    raising: a corrupt row must fail the login, not the request."""
    try:
        scheme, n, r, p, salt_b64, key_b64 = encoded.split("$")
        if scheme != "scrypt":
            return False
        expected = base64.b64decode(key_b64)
        actual = hashlib.scrypt(
            password.encode("utf-8"),
            salt=base64.b64decode(salt_b64),
            n=int(n),
            r=int(r),
            p=int(p),
            dklen=len(expected),
            # Derived from the stored parameters, not the current constants:
            # a hash written before the cost was raised must still verify.
            maxmem=128 * int(n) * int(r) * 2,
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(expected, actual)


@dataclass(frozen=True)
class OfficeContext:
    user_id: uuid.UUID
    tenant_id: uuid.UUID
    email: str
    name: str
    role: str

    @property
    def is_owner(self) -> bool:
        return self.role == "owner"


def issue_office_token(user_id: uuid.UUID, tenant_id: uuid.UUID) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    return jwt.encode(
        {
            "sub": str(user_id),
            "tid": str(tenant_id),
            # Marks this as an office session. Without it a device token would
            # be accepted here and vice versa — different privileges, so they
            # must not be interchangeable.
            "typ": "office",
            "iat": now,
            "exp": now + dt.timedelta(hours=OFFICE_TOKEN_HOURS),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )


async def current_office_user(
    authorization: str = Header(default=""),
) -> OfficeContext:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")

    token = authorization.split(" ", 1)[1].strip()
    try:
        claims = jwt.decode(
            token, settings.jwt_secret, algorithms=[settings.jwt_algorithm]
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "session expired")
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token")

    if claims.get("typ") != "office":
        # A device token reaching here would otherwise be handed back-office
        # privileges, which is a far bigger grant than a tablet should hold.
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, "not a back-office session"
        )

    try:
        user_id = uuid.UUID(claims["sub"])
        tenant_id = uuid.UUID(claims["tid"])
    except (KeyError, ValueError):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "malformed token")

    async with SessionLocal() as session:
        user = (
            await session.execute(
                select(BackOfficeUser).where(
                    BackOfficeUser.id == user_id,
                    BackOfficeUser.tenant_id == tenant_id,
                )
            )
        ).scalar_one_or_none()

    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "unknown user")
    if not user.is_active:
        # Checked per request, not just at login: disabling someone must take
        # effect now, not whenever their token happens to expire.
        raise HTTPException(status.HTTP_403_FORBIDDEN, "account disabled")

    return OfficeContext(
        user_id=user.id,
        tenant_id=user.tenant_id,
        email=user.email,
        name=user.name,
        role=user.role,
    )


OfficeDep = Depends(current_office_user)


def require_owner(ctx: OfficeContext = OfficeDep) -> OfficeContext:
    if not ctx.is_owner:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "only an owner can do this"
        )
    return ctx
