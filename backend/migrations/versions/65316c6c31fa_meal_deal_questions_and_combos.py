"""meal deal questions and combos

Revision ID: 65316c6c31fa
Revises: 82b4ae6b00eb
Create Date: 2026-08-10 17:00:51.446580

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '65316c6c31fa'
down_revision: Union[str, Sequence[str], None] = '82b4ae6b00eb'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


NEW_TENANT_TABLES = [
    "question", "question_choice", "product_question", "combo_item",
]


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('product_question',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('tenant_id', sa.Uuid(), nullable=False),
    sa.Column('prodnum', sa.Integer(), nullable=False),
    sa.Column('question_no', sa.Integer(), nullable=False),
    sa.Column('slot', sa.Integer(), nullable=False),
    sa.Column('is_deleted', sa.Boolean(), server_default=sa.text('false'), nullable=False),
    sa.Column('server_version', sa.BigInteger(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('tenant_id', 'prodnum', 'slot')
    )
    op.create_index(op.f('ix_product_question_prodnum'), 'product_question', ['prodnum'], unique=False)
    op.create_index(op.f('ix_product_question_server_version'), 'product_question', ['server_version'], unique=False)
    op.create_index('ix_product_question_sync', 'product_question', ['tenant_id', 'server_version'], unique=False)
    op.create_index(op.f('ix_product_question_tenant_id'), 'product_question', ['tenant_id'], unique=False)
    op.create_table('combo_item',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('tenant_id', sa.Uuid(), nullable=False),
    sa.Column('company_id', sa.Uuid(), nullable=True),
    sa.Column('parent_prodnum', sa.Integer(), nullable=False),
    sa.Column('prodnum', sa.Integer(), nullable=False),
    sa.Column('sort_order', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('price_mode', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('fixed_price', sa.BigInteger(), nullable=True),
    sa.Column('print_it', sa.Boolean(), server_default=sa.text('true'), nullable=False),
    sa.Column('is_active', sa.Boolean(), server_default=sa.text('true'), nullable=False),
    sa.Column('is_deleted', sa.Boolean(), server_default=sa.text('false'), nullable=False),
    sa.Column('server_version', sa.BigInteger(), nullable=False),
    sa.ForeignKeyConstraint(['company_id'], ['company.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_combo_item_parent', 'combo_item', ['tenant_id', 'parent_prodnum'], unique=False)
    op.create_index(op.f('ix_combo_item_server_version'), 'combo_item', ['server_version'], unique=False)
    op.create_index('ix_combo_item_sync', 'combo_item', ['tenant_id', 'server_version'], unique=False)
    op.create_index(op.f('ix_combo_item_tenant_id'), 'combo_item', ['tenant_id'], unique=False)
    op.create_table('question',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('tenant_id', sa.Uuid(), nullable=False),
    sa.Column('company_id', sa.Uuid(), nullable=True),
    sa.Column('question_no', sa.Integer(), nullable=False),
    sa.Column('prompt', sa.Text(), nullable=False),
    sa.Column('prompt_ar', sa.Text(), nullable=True),
    sa.Column('is_required', sa.Boolean(), server_default=sa.text('true'), nullable=False),
    sa.Column('pick_count', sa.Integer(), server_default=sa.text('1'), nullable=False),
    sa.Column('allow_repeats', sa.Boolean(), server_default=sa.text('false'), nullable=False),
    sa.Column('free_choices', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('is_active', sa.Boolean(), server_default=sa.text('true'), nullable=False),
    sa.Column('is_deleted', sa.Boolean(), server_default=sa.text('false'), nullable=False),
    sa.Column('server_version', sa.BigInteger(), nullable=False),
    sa.ForeignKeyConstraint(['company_id'], ['company.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('tenant_id', 'company_id', 'question_no')
    )
    op.create_index(op.f('ix_question_server_version'), 'question', ['server_version'], unique=False)
    op.create_index('ix_question_sync', 'question', ['tenant_id', 'server_version'], unique=False)
    op.create_index(op.f('ix_question_tenant_id'), 'question', ['tenant_id'], unique=False)
    op.create_table('question_choice',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('tenant_id', sa.Uuid(), nullable=False),
    sa.Column('company_id', sa.Uuid(), nullable=True),
    sa.Column('question_no', sa.Integer(), nullable=False),
    sa.Column('prodnum', sa.Integer(), nullable=False),
    sa.Column('sort_order', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('price_mode', sa.Integer(), server_default=sa.text('0'), nullable=False),
    sa.Column('fixed_price', sa.BigInteger(), nullable=True),
    sa.Column('default_qty', sa.Integer(), server_default=sa.text('1'), nullable=False),
    sa.Column('is_active', sa.Boolean(), server_default=sa.text('true'), nullable=False),
    sa.Column('is_deleted', sa.Boolean(), server_default=sa.text('false'), nullable=False),
    sa.Column('server_version', sa.BigInteger(), nullable=False),
    sa.ForeignKeyConstraint(['company_id'], ['company.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenant.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('tenant_id', 'question_no', 'prodnum')
    )
    op.create_index(op.f('ix_question_choice_server_version'), 'question_choice', ['server_version'], unique=False)
    op.create_index('ix_question_choice_sync', 'question_choice', ['tenant_id', 'server_version'], unique=False)
    op.create_index(op.f('ix_question_choice_tenant_id'), 'question_choice', ['tenant_id'], unique=False)

    # Autogenerate cannot see RLS. A tenant table without a policy has no
    # isolation, so it is added by hand exactly as every other one has been.
    if _is_postgres():
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
            op.execute(f"GRANT SELECT, INSERT, UPDATE ON {table} TO pos_app")


def downgrade() -> None:
    """Downgrade schema."""
    if _is_postgres():
        for table in NEW_TENANT_TABLES:
            op.execute(f"DROP POLICY IF EXISTS tenant_isolation ON {table}")
    op.drop_index(op.f('ix_question_choice_tenant_id'), table_name='question_choice')
    op.drop_index('ix_question_choice_sync', table_name='question_choice')
    op.drop_index(op.f('ix_question_choice_server_version'), table_name='question_choice')
    op.drop_table('question_choice')
    op.drop_index(op.f('ix_question_tenant_id'), table_name='question')
    op.drop_index('ix_question_sync', table_name='question')
    op.drop_index(op.f('ix_question_server_version'), table_name='question')
    op.drop_table('question')
    op.drop_index(op.f('ix_combo_item_tenant_id'), table_name='combo_item')
    op.drop_index('ix_combo_item_sync', table_name='combo_item')
    op.drop_index(op.f('ix_combo_item_server_version'), table_name='combo_item')
    op.drop_index('ix_combo_item_parent', table_name='combo_item')
    op.drop_table('combo_item')
    op.drop_index(op.f('ix_product_question_tenant_id'), table_name='product_question')
    op.drop_index('ix_product_question_sync', table_name='product_question')
    op.drop_index(op.f('ix_product_question_server_version'), table_name='product_question')
    op.drop_index(op.f('ix_product_question_prodnum'), table_name='product_question')
    op.drop_table('product_question')
    # ### end Alembic commands ###
