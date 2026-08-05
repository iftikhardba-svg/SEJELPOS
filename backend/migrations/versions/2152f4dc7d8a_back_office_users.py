"""back office users

Adds the accounts people sign into the back office with.

**Deliberately no Row Level Security on this table**, and that is not an
oversight. RLS keys off `app.tenant_id`, which is set from the caller's token —
but sign-in is what *produces* that token, so at lookup time there is no tenant
to scope by and a policy would make every login fail. `enrolment_code` is
excluded for exactly the same reason: both are the tables that establish
tenancy rather than live inside it.

What protects them instead:

* the login lookup is by a globally unique email and returns exactly one row;
* `current_office_user` re-reads the account filtered on BOTH id and tenant_id
  from the token, so a token cannot name a user in another tenant;
* every back-office query filters on the session's tenant_id, and the tables
  those queries touch do have RLS.

Revision ID: 2152f4dc7d8a
Revises: a7f08ca72e44
Create Date: 2026-08-05 11:12:05.671345
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = '2152f4dc7d8a'
down_revision: Union[str, Sequence[str], None] = 'a7f08ca72e44'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    op.create_table(
        'back_office_user',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('tenant_id', sa.Uuid(), nullable=False),
        sa.Column('email', sa.String(length=320), nullable=False),
        sa.Column('name', sa.Text(), nullable=False),
        sa.Column('password_hash', sa.Text(), nullable=False),
        sa.Column('role', sa.String(length=16),
                  server_default=sa.text("'manager'"), nullable=False),
        sa.Column('is_active', sa.Boolean(), server_default=sa.text('true'),
                  nullable=False),
        sa.Column('last_login_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True),
                  server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id'], ),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('email'),
    )
    op.create_index(op.f('ix_back_office_user_tenant_id'), 'back_office_user',
                    ['tenant_id'], unique=False)

    if _is_postgres():
        op.create_check_constraint(
            "ck_back_office_user_role", "back_office_user",
            "role IN ('owner','manager')",
        )
        # No DELETE, matching every other table: accounts are deactivated, so
        # the audit trail of who changed a price survives them leaving.
        op.execute(
            "GRANT SELECT, INSERT, UPDATE ON back_office_user TO pos_app"
        )


def downgrade() -> None:
    if _is_postgres():
        op.drop_constraint("ck_back_office_user_role", "back_office_user",
                           type_="check")
    op.drop_index(op.f('ix_back_office_user_tenant_id'),
                  table_name='back_office_user')
    op.drop_table('back_office_user')
