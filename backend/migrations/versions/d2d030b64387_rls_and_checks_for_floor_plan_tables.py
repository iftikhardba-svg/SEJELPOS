"""rls and checks for floor plan tables

Every new table carrying tenant_id needs its own isolation policy. A table
without one is readable across customers, and autogenerate will never warn you:
policies are invisible to it.

Revision ID: d2d030b64387
Revises: 009ad17b35e3
Create Date: 2026-08-04 14:12:34.160069
"""

from typing import Sequence, Union

from alembic import op

revision: str = "d2d030b64387"
down_revision: Union[str, Sequence[str], None] = "009ad17b35e3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


NEW_TENANT_TABLES = [
    "floor_section", "dining_table", "table_session",
    "table_session_line", "reservation",
]

CHECKS = [
    ("table_session", "ck_table_session_status",
     "status IN ('open','billed','closed','abandoned')"),
    ("reservation", "ck_reservation_status",
     "status IN ('booked','seated','cancelled','no_show')"),
    ("dining_table", "ck_dining_table_shape",
     "shape IN ('square','round','rect')"),
    # A table with no seats cannot be sat at; a negative one is nonsense.
    ("dining_table", "ck_dining_table_seats", "seats > 0"),
    ("reservation", "ck_reservation_party", "party_size > 0"),
]


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    if not _is_postgres():
        return

    for table, name, expr in CHECKS:
        op.create_check_constraint(name, table, expr)

    for table in NEW_TENANT_TABLES:
        op.execute(f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {table} FORCE ROW LEVEL SECURITY")
        op.execute(
            f"""
            CREATE POLICY tenant_isolation ON {table}
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            """
        )

    # Tables created after the role existed do not inherit its grants.
    op.execute("GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO pos_app")
    op.execute("REVOKE DELETE ON ALL TABLES IN SCHEMA public FROM pos_app")


def downgrade() -> None:
    if not _is_postgres():
        return

    for table in NEW_TENANT_TABLES:
        op.execute(f"DROP POLICY IF EXISTS tenant_isolation ON {table}")
        op.execute(f"ALTER TABLE {table} NO FORCE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY")

    for table, name, _ in reversed(CHECKS):
        op.drop_constraint(name, table, type_="check")
