"""a picture on the button

Revision ID: f2c8b41d7e05
Revises: e1f4a7c30b92
Create Date: 2026-08-11 17:10:00.000000

A table rather than a column on product, because an image is about a thousand
times the size of the row that names it. On product it would ride along with
every price edit and every colour change, and a till would re-download a
photograph to learn that something cost a riyal more.

The bytes live in the database, not on a disk or behind a URL. A URL is a
promise that the network is up at the moment a cashier opens the menu — which
is the moment this whole product exists to survive.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'f2c8b41d7e05'
down_revision: Union[str, Sequence[str], None] = 'e1f4a7c30b92'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'product_image',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('tenant_id', sa.Uuid(), nullable=False),
        sa.Column('prodnum', sa.Integer(), nullable=False),
        sa.Column('mime', sa.String(length=32), nullable=False),
        sa.Column('data', sa.LargeBinary(), nullable=False),
        sa.Column('width', sa.Integer(), nullable=False),
        sa.Column('height', sa.Integer(), nullable=False),
        sa.Column('byte_size', sa.Integer(), nullable=False),
        sa.Column('is_deleted', sa.Boolean(), server_default=sa.text('false'),
                  nullable=False),
        sa.Column('server_version', sa.BigInteger(), nullable=False),
        sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id'], ),
        sa.PrimaryKeyConstraint('id'),
        # One image per product: replacing it is an update, so a device sees a
        # single row change version rather than an old row and a new one.
        sa.UniqueConstraint('tenant_id', 'prodnum'),
    )
    op.create_index(op.f('ix_product_image_prodnum'), 'product_image',
                    ['prodnum'], unique=False)
    op.create_index(op.f('ix_product_image_server_version'), 'product_image',
                    ['server_version'], unique=False)
    op.create_index('ix_product_image_sync', 'product_image',
                    ['tenant_id', 'server_version'], unique=False)
    op.create_index(op.f('ix_product_image_tenant_id'), 'product_image',
                    ['tenant_id'], unique=False)

    # Autogenerate cannot see RLS. A tenant table without a policy has no
    # isolation, so it is added by hand exactly as every other one has been.
    if _is_postgres():
        op.execute("ALTER TABLE product_image ENABLE ROW LEVEL SECURITY")
        op.execute("ALTER TABLE product_image FORCE ROW LEVEL SECURITY")
        op.execute(
            """
            CREATE POLICY tenant_isolation ON product_image
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
            """
        )
        op.execute(
            "GRANT SELECT, INSERT, UPDATE, DELETE ON product_image TO pos_app"
        )


def downgrade() -> None:
    """Downgrade schema."""
    if _is_postgres():
        op.execute("DROP POLICY IF EXISTS tenant_isolation ON product_image")
    op.drop_index(op.f('ix_product_image_tenant_id'), table_name='product_image')
    op.drop_index('ix_product_image_sync', table_name='product_image')
    op.drop_index(op.f('ix_product_image_server_version'),
                  table_name='product_image')
    op.drop_index(op.f('ix_product_image_prodnum'), table_name='product_image')
    op.drop_table('product_image')
