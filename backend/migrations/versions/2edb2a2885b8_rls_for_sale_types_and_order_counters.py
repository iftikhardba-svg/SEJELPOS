"""rls for sale types and order counters

Revision ID: 2edb2a2885b8
Revises: c3b21e9fb7c8
Create Date: 2026-08-04 14:31:08.532295
"""

from typing import Sequence, Union

from alembic import op

revision: str = "2edb2a2885b8"
down_revision: Union[str, Sequence[str], None] = "c3b21e9fb7c8"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


NEW_TENANT_TABLES = ["sales_type", "order_number_counter"]

CHECKS = [
    # Tier is a single letter a-j and decides the price charged. A junk value
    # would either fail the lookup or, worse, silently fall through to the
    # base tier and undercharge every aggregator order.
    ("sales_type", "ck_sales_type_tier",
     "price_tier ~ '^[a-j]$'"),
    ("order_number_counter", "ck_order_counter_positive", "next_number > 0"),
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
