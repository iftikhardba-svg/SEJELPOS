"""Backend settings."""

from __future__ import annotations

import os
from dataclasses import dataclass

DEV_JWT_SECRET = "dev-only-change-me-not-for-production-use"

# Anything shorter than this is below the RFC 7518 recommendation for HS256.
MIN_JWT_SECRET_BYTES = 32


@dataclass(frozen=True)
class Settings:
    # postgresql+asyncpg://user:pass@host/db in production;
    # sqlite+aiosqlite for tests, where RLS does not exist.
    database_url: str = os.environ.get(
        "POS_DATABASE_URL", "sqlite+aiosqlite:///./pos_dev.db"
    )
    jwt_secret: str = os.environ.get("POS_JWT_SECRET", DEV_JWT_SECRET)
    jwt_algorithm: str = "HS256"
    device_token_days: int = 90

    # Back-office secret for provisioning endpoints (creating enrolment codes).
    # Unset means provisioning over the API is switched off — not an error.
    admin_token: str | None = os.environ.get("POS_ADMIN_TOKEN") or None

    # Enrolment codes are typed in by a human standing at a tablet; they should
    # not survive being written on a sticky note for long.
    enrolment_code_hours: int = 24

    # A device may not push a sale older than this without being flagged.
    # ZATCA requires simplified invoices reported within 24h, so an outbox
    # older than that is a compliance problem, not just a stale queue.
    max_offline_hours: int = 24

    # Cap on a single catalog page, to keep tablet memory bounded.
    catalog_page_size: int = 1000

    @property
    def is_postgres(self) -> bool:
        return self.database_url.startswith("postgresql")

    def check_production_safety(self) -> None:
        """Refuse to run a real deployment with development defaults.

        A commercial product shipped to many customers must not fall back to a
        secret that is published in its own source. Anyone holding it could mint
        a device token for any tenant. Failing to start is the correct outcome —
        the alternative is a silently insecure deployment.

        Called from main.py at startup. PostgreSQL is the proxy for "this is not
        a developer's laptop".
        """
        if not self.is_postgres:
            return

        problems = []
        if self.jwt_secret == DEV_JWT_SECRET:
            problems.append(
                "POS_JWT_SECRET is unset, so the built-in development secret is "
                "in use. It is public — anyone could forge a device token for "
                "any tenant."
            )
        elif len(self.jwt_secret.encode()) < MIN_JWT_SECRET_BYTES:
            problems.append(
                f"POS_JWT_SECRET is {len(self.jwt_secret.encode())} bytes; "
                f"HS256 wants at least {MIN_JWT_SECRET_BYTES}."
            )

        if self.admin_token is not None and len(self.admin_token) < 24:
            problems.append(
                "POS_ADMIN_TOKEN is set but short; provisioning would be "
                "guardable by brute force. Use at least 24 characters, or unset "
                "it to disable API provisioning."
            )

        if problems:
            raise RuntimeError(
                "refusing to start with an insecure configuration:\n  - "
                + "\n  - ".join(problems)
            )


settings = Settings()
