"""The production configuration guard.

A commercial product installed for many customers must not fall back to a secret
that is printed in its own source code. These tests pin that behaviour.
"""

from __future__ import annotations

import pytest

from app.config import DEV_JWT_SECRET, Settings


def test_dev_default_is_fine_on_sqlite():
    """A developer's laptop should not need ceremony."""
    Settings(
        database_url="sqlite+aiosqlite:///./x.db",
        jwt_secret=DEV_JWT_SECRET,
    ).check_production_safety()


def test_dev_secret_is_refused_on_postgres():
    cfg = Settings(
        database_url="postgresql+asyncpg://u:p@h/db",
        jwt_secret=DEV_JWT_SECRET,
    )
    with pytest.raises(RuntimeError, match="forge a device token"):
        cfg.check_production_safety()


def test_short_secret_is_refused_on_postgres():
    cfg = Settings(
        database_url="postgresql+asyncpg://u:p@h/db",
        jwt_secret="too-short",
    )
    with pytest.raises(RuntimeError, match="at least 32"):
        cfg.check_production_safety()


def test_strong_secret_is_accepted():
    Settings(
        database_url="postgresql+asyncpg://u:p@h/db",
        jwt_secret="x" * 48,
    ).check_production_safety()
