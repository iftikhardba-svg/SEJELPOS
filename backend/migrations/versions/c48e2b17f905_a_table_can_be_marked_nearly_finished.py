"""a table can be marked nearly finished

Revision ID: c48e2b17f905
Revises: b7d1c93af204
Create Date: 2026-08-11 11:30:00.000000

The floor plan a host works the door from tells them three things about a
table: free, in use, and about to leave. The first two fall out of the session
existing; the third is somebody's judgement and has to be recorded.

Nullable-free with a default, because every existing open table is simply not
marked yet.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c48e2b17f905'
down_revision: Union[str, Sequence[str], None] = 'b7d1c93af204'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column(
        'table_session',
        sa.Column(
            'done_soon', sa.Boolean(), server_default=sa.text('false'),
            nullable=False,
        ),
    )
    # And who seated it, for the floor's "who is here?" view. By name rather
    # than by staff_id: migrated staff arrive without accounts to point at.
    op.add_column(
        'table_session', sa.Column('opened_by', sa.Text(), nullable=True)
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column('table_session', 'opened_by')
    op.drop_column('table_session', 'done_soon')
