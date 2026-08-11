"""a check split between guests

Revision ID: e1f4a7c30b92
Revises: d5a91c3e77b8
Create Date: 2026-08-11 15:40:00.000000

Two columns on the session line, both about the same evening: four people eat
together and pay separately.

`settled_sale_uuid` is what makes that possible. Splitting a check is not one
bill taken in parts — each guest gets their own tax invoice, with their own
ZATCA stamp on their own receipt — so the session cannot record a single
`sale_uuid` and be done. Payment is recorded against the lines that were paid
for, and the table closes when nothing is owed.

`parent_line_no` is the structure a saved check loses without it. A meal
deal's drink is carried on the check at the price the meal covers, usually
nothing; flattened, it comes back looking like a drink somebody ordered on its
own, and the till re-prices it at menu rate on a bill the guest was already
quoted. Same shape, and for the same reason, as kitchen_ticket_line.parent_line_no.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e1f4a7c30b92'
down_revision: Union[str, Sequence[str], None] = 'd5a91c3e77b8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column(
        'table_session_line',
        sa.Column('parent_line_no', sa.Integer(), nullable=True),
    )
    op.add_column(
        'table_session_line',
        sa.Column('settled_sale_uuid', sa.Uuid(), nullable=True),
    )
    # What every settle and every running total asks: what on this check is
    # still owed. Partial so it indexes only the rows that are.
    op.create_index(
        'ix_session_line_unsettled',
        'table_session_line',
        ['session_id'],
        postgresql_where=sa.text('settled_sale_uuid IS NULL'),
        sqlite_where=sa.text('settled_sale_uuid IS NULL'),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index('ix_session_line_unsettled', table_name='table_session_line')
    op.drop_column('table_session_line', 'settled_sale_uuid')
    op.drop_column('table_session_line', 'parent_line_no')
