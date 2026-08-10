"""report categories

Revision ID: 86f4d1f40b31
Revises: 2152f4dc7d8a
Create Date: 2026-08-10 15:24:21.921755

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '86f4d1f40b31'
down_revision: Union[str, Sequence[str], None] = '2152f4dc7d8a'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('report_category',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('tenant_id', sa.Uuid(), nullable=False),
    sa.Column('company_id', sa.Uuid(), nullable=True),
    sa.Column('report_no', sa.Integer(), nullable=False),
    sa.Column('name', sa.Text(), nullable=False),
    sa.Column('name_ar', sa.Text(), nullable=True),
    sa.Column('default_print_loc', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('sort_order', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('is_active', sa.Boolean(), server_default=sa.text('true'), nullable=False),
    sa.Column('is_deleted', sa.Boolean(), server_default=sa.text('false'), nullable=False),
    sa.Column('server_version', sa.BigInteger(), nullable=False),
    sa.ForeignKeyConstraint(['company_id'], ['company.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('tenant_id', 'company_id', 'report_no')
    )
    op.create_index(op.f('ix_report_category_server_version'), 'report_category', ['server_version'], unique=False)
    op.create_index('ix_report_category_sync', 'report_category', ['tenant_id', 'server_version'], unique=False)
    op.create_index(op.f('ix_report_category_tenant_id'), 'report_category', ['tenant_id'], unique=False)
    op.add_column('product', sa.Column('report_no', sa.Integer(), nullable=True))
    op.create_index(op.f('ix_product_report_no'), 'product', ['report_no'], unique=False)

    # Autogenerate cannot see RLS. A tenant table without a policy is a tenant
    # table with no isolation, so it is added by hand here exactly as every
    # other one has been.
    if _is_postgres():
        op.execute("ALTER TABLE report_category ENABLE ROW LEVEL SECURITY")
        op.execute("ALTER TABLE report_category FORCE ROW LEVEL SECURITY")
        op.execute(
            """
            CREATE POLICY tenant_isolation ON report_category
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            """
        )
        op.execute(
            "GRANT SELECT, INSERT, UPDATE ON report_category TO pos_app"
        )


def downgrade() -> None:
    """Downgrade schema."""
    if _is_postgres():
        op.execute("DROP POLICY IF EXISTS tenant_isolation ON report_category")
    op.drop_index(op.f('ix_product_report_no'), table_name='product')
    op.drop_column('product', 'report_no')
    op.drop_index(op.f('ix_report_category_tenant_id'), table_name='report_category')
    op.drop_index('ix_report_category_sync', table_name='report_category')
    op.drop_index(op.f('ix_report_category_server_version'), table_name='report_category')
    op.drop_table('report_category')
    # ### end Alembic commands ###
