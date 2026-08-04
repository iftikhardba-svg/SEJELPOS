"""rls for kds tables

Revision ID: fc3e2a1d8642
Revises: 3f8d6119d693
Create Date: 2026-08-04 14:50:17.577961
"""

from typing import Sequence, Union

from alembic import op

revision: str = "fc3e2a1d8642"
down_revision: Union[str, Sequence[str], None] = "3f8d6119d693"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


NEW_TENANT_TABLES = ["kitchen_station", "kitchen_ticket", "kitchen_ticket_line"]

CHECKS = [
    ("kitchen_ticket", "ck_kitchen_ticket_status", "status IN ('open','done')"),
    ("device", "ck_device_role", "role IN ('pos','kds','cds')"),
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
