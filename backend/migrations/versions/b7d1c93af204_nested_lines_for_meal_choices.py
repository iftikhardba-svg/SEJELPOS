"""nested lines for meal choices

Revision ID: b7d1c93af204
Revises: 65316c6c31fa
Create Date: 2026-08-10 19:40:00.000000

A meal that asks "which drink?" produces a bill and a kitchen ticket where the
answer belongs to the meal. Without a parent link both arrive flat: the bill
lists a 0.00 drink beside the meal with nothing tying them together, and the
cook sees a loose PEPSI with four open meals to guess between.

Both columns are nullable and nothing backfills them — every line written
before this stands alone, which is exactly what it was.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b7d1c93af204'
down_revision: Union[str, Sequence[str], None] = '65316c6c31fa'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column('sale_line', sa.Column('parent_line', sa.Uuid(), nullable=True))
    op.add_column(
        'kitchen_ticket_line',
        sa.Column('parent_line_no', sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column('kitchen_ticket_line', 'parent_line_no')
    op.drop_column('sale_line', 'parent_line')
