"""row level security, checks and app role

Everything the ORM cannot express, and which therefore has to live here rather
than in models.py:

* CHECK constraints on status columns and on staff credentials
* Partial indexes for the pending-work queues
* Row Level Security policies — the actual tenant isolation
* The non-superuser application role RLS depends on

PostgreSQL only. SQLite has no RLS, no roles, and the dev/test path builds its
schema with create_all() rather than running migrations, so every statement here
is guarded on the dialect.

Revision ID: 5650ee789d9a
Revises: a040bf2b32c6
Create Date: 2026-08-04 12:41:49.714477
"""

from typing import Sequence, Union

from alembic import op

revision: str = "5650ee789d9a"
down_revision: Union[str, Sequence[str], None] = "a040bf2b32c6"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# Every table carrying tenant_id. A table missing from this list is a table with
# no isolation, so adding one to the model means adding it here.
#
# `ingest_log` used to appear here, carried over from the hand-written schema.
# It never had a model and nothing ever wrote to it: idempotency is enforced by
# sale_uuid being the primary key of `sale`, so a replayed push collides there.
# Dropped rather than recreated — an unused table is the thing that drifts.
TENANT_TABLES = [
    "company", "branch", "device", "licence", "product", "menu_screen",
    "menu_button", "pay_method", "staff", "tax_rate", "sale", "sale_line",
    "sale_payment",
]

CHECKS = [
    ("tenant", "ck_tenant_mode", "mode IN ('standalone','erp')"),
    ("device", "ck_device_csid_status",
     "csid_status IN ('none','compliance','production','revoked','expired')"),
    ("sale", "ck_sale_status", "status IN ('closed','voided')"),
    ("sale", "ck_sale_zatca_status",
     "zatca_status IN ('pending','reported','cleared','rejected')"),
    ("sale", "ck_sale_erp_status",
     "erp_status IN ('pending','sent','acked','failed','n/a')"),
    # Migrated staff arrive with no credential and must set one before login;
    # this stops a row existing that is neither usable nor flagged.
    ("staff", "ck_staff_credential", "pin_hash IS NOT NULL OR must_set_pin"),
]


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    if not _is_postgres():
        return

    for table, name, expr in CHECKS:
        op.create_check_constraint(name, table, expr)

    # The partial worker-queue indexes are declared on the Sale model with
    # postgresql_where, so the initial migration creates them and `alembic
    # check` can see them. Creating them here as raw SQL made them invisible to
    # autogenerate, which then wanted to drop them on every run.

    # ---- Row Level Security -------------------------------------------
    # FORCE also applies the policy to the table owner. Nothing can constrain a
    # superuser, which is why the application must connect as pos_app below.
    for table in TENANT_TABLES:
        op.execute(f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {table} FORCE ROW LEVEL SECURITY")
        op.execute(
            f"""
            CREATE POLICY tenant_isolation ON {table}
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            """
        )

    # ---- application role ----------------------------------------------
    # Set a real password before deploying; this is a placeholder that the
    # deployment is expected to rotate.
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app') THEN
                CREATE ROLE pos_app LOGIN PASSWORD 'change-me'
                    NOSUPERUSER NOCREATEDB NOCREATEROLE;
            END IF;
        END $$;
        """
    )
    op.execute("GRANT USAGE ON SCHEMA public TO pos_app")
    op.execute("GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO pos_app")
    op.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO pos_app")

    # No DELETE, deliberately: sales are append-only and a tax record must not
    # be removable by the application. Corrections are credit notes.
    op.execute("REVOKE DELETE ON ALL TABLES IN SCHEMA public FROM pos_app")
    op.execute(
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
        "GRANT SELECT, INSERT, UPDATE ON TABLES TO pos_app"
    )


def downgrade() -> None:
    if not _is_postgres():
        return

    op.execute(
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
        "REVOKE SELECT, INSERT, UPDATE ON TABLES FROM pos_app"
    )
    op.execute("REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM pos_app")
    op.execute("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM pos_app")
    op.execute("REVOKE USAGE ON SCHEMA public FROM pos_app")
    # The role itself is left in place: it may own objects or be shared with
    # another database on the same cluster, and dropping it would fail or
    # silently break them.

    for table in TENANT_TABLES:
        op.execute(f"DROP POLICY IF EXISTS tenant_isolation ON {table}")
        op.execute(f"ALTER TABLE {table} NO FORCE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY")

    for table, name, _ in reversed(CHECKS):
        op.drop_constraint(name, table, type_="check")
