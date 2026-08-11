"""tables pushed together

Revision ID: d5a91c3e77b8
Revises: c48e2b17f905
Create Date: 2026-08-11 12:20:00.000000

Four people on two twos is one party, one order and one bill. The session keeps
its own table and gains the rest through this join, which is also what lets the
capacity check add the seats up.

The unique index is partial on `released_at IS NULL` so a table can be in one
live merge at a time and still carry the history of every party it was pushed
into. The WHERE clause is given per dialect: with only postgresql_where, SQLite
builds a full unique index and a table could never be merged twice — the same
trap the open-session index documents.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'd5a91c3e77b8'
down_revision: Union[str, Sequence[str], None] = 'c48e2b17f905'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'session_table',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('tenant_id', sa.Uuid(), nullable=False),
        sa.Column('session_id', sa.Uuid(), nullable=False),
        sa.Column('table_id', sa.Uuid(), nullable=False),
        sa.Column('joined_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('released_at', sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id']),
        sa.ForeignKeyConstraint(
            ['session_id'], ['table_session.id'], ondelete='CASCADE'
        ),
        sa.ForeignKeyConstraint(['table_id'], ['dining_table.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_session_table_tenant_id'), 'session_table', ['tenant_id']
    )
    op.create_index(
        op.f('ix_session_table_session_id'), 'session_table', ['session_id']
    )
    op.create_index('ix_session_table_session', 'session_table', ['session_id'])
    op.create_index(
        'ux_session_table_live', 'session_table', ['table_id'],
        unique=True,
        postgresql_where=sa.text('released_at IS NULL'),
        sqlite_where=sa.text('released_at IS NULL'),
    )

    # Autogenerate cannot see RLS. A tenant table without a policy has no
    # isolation at all.
    if _is_postgres():
        op.execute("ALTER TABLE session_table ENABLE ROW LEVEL SECURITY")
        op.execute("ALTER TABLE session_table FORCE ROW LEVEL SECURITY")
        op.execute(
            """
            CREATE POLICY tenant_isolation ON session_table
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            """
        )
        op.execute(
            "GRANT SELECT, INSERT, UPDATE, DELETE ON session_table TO pos_app"
        )


def downgrade() -> None:
    """Downgrade schema."""
    if _is_postgres():
        op.execute("DROP POLICY IF EXISTS tenant_isolation ON session_table")
    op.drop_index('ux_session_table_live', table_name='session_table')
    op.drop_index('ix_session_table_session', table_name='session_table')
    op.drop_index(op.f('ix_session_table_session_id'), table_name='session_table')
    op.drop_index(op.f('ix_session_table_tenant_id'), table_name='session_table')
    op.drop_table('session_table')
