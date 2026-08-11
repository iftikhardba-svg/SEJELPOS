"""tables exist before they are placed

Revision ID: a4d61f0c92b7
Revises: f2c8b41d7e05
Create Date: 2026-08-11 18:20:00.000000

A table and its place on a plan are two different facts. What a table IS —
its number, what staff call it, how many it seats, whether it can be booked —
belongs to the restaurant. Where it sits belongs to a room, and a restaurant
rearranges rooms without inventing new tables.

Until now a table could not exist without an area, so setting one up meant
deciding where it goes in the same breath, and taking it off a plan meant
retiring it. `section_id` becomes nullable: null is a table on the books and
off the floor, which is exactly what a stack of spare twos in the back is.

The same split the menu already has — products are a master, and the menu
layout places them.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'a4d61f0c92b7'
down_revision: Union[str, Sequence[str], None] = 'f2c8b41d7e05'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # SQLite cannot ALTER a column, so batch mode rebuilds the table. Every
    # existing row keeps its area: nothing is unplaced by this.
    with op.batch_alter_table('dining_table') as batch:
        batch.alter_column('section_id', existing_type=sa.Uuid(),
                           nullable=True)


def downgrade() -> None:
    """Downgrade schema.

    Refuses while any table is off a plan: dropping them into an arbitrary
    area would move furniture nobody asked to move.
    """
    unplaced = op.get_bind().execute(
        sa.text("SELECT COUNT(*) FROM dining_table WHERE section_id IS NULL")
    ).scalar()
    if unplaced:
        raise RuntimeError(
            f"{unplaced} tables are not on a plan; place them before "
            f"downgrading, or they would have to be given an area at random"
        )
    with op.batch_alter_table('dining_table') as batch:
        batch.alter_column('section_id', existing_type=sa.Uuid(),
                           nullable=False)
