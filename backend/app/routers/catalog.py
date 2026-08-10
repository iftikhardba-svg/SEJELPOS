"""GET /catalog - incremental pull, server to device.

A tablet needs the whole catalog to work offline, so this returns everything
that changed since the device's watermark. The first real customer's catalog is
~1,200 rows, which does not fit in one sensible response, so it is **paged**.

Paging cannot key off `server_version` alone. A bulk load stamps every row it
writes with one version - that is deliberate, so a device never sees half a
catalog version - which means a single version can hold thousands of rows and
there is nothing to advance through. The cursor therefore carries
`(table, server_version, id)`: a position in a fixed walk across the tables,
stable under re-request because the ordering is total.

**The device must not advance its watermark until `has_more` is false.** A
partial pull that commits its watermark permanently skips whatever it did not
fetch, and that shows up weeks later as "that item isn't on the till". Pulling
again from the old watermark re-fetches rows it already has, which is free -
every apply is an upsert on a business key.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_, select, tuple_

from ..auth import DeviceContext, current_device
from ..config import settings
from ..db import tenant_session
from ..models import (
    ComboItem,
    KitchenStation,
    Menu,
    MenuButton,
    MenuPage,
    MenuScreen,
    PayMethod,
    Product,
    ProductQuestion,
    Question,
    QuestionChoice,
    SalesType,
    Staff,
    TaxRate,
)
from ..schemas import (
    CatalogResponse,
    ComboItemOut,
    KitchenStationOut,
    MenuButtonOut,
    MenuOut,
    MenuPageOut,
    MenuScreenOut,
    PayMethodOut,
    ProductOut,
    ProductQuestionOut,
    QuestionChoiceOut,
    QuestionOut,
    SalesTypeOut,
    StaffOut,
    TaxRateOut,
)

router = APIRouter(tags=["catalog"])

# The walk order. Fixed and append-only: a cursor issued before a reorder would
# otherwise resume in the wrong table and skip rows. `branch_scoped` marks the
# models where a NULL branch means "every branch in the tenant".
#
# Screens and products come before buttons so a device that stops mid-pull
# holds referents before referrers.
TABLES = [
    ("menus", Menu, MenuOut, True),
    ("menu_screens", MenuScreen, MenuScreenOut, True),
    ("products", Product, ProductOut, True),
    ("menu_pages", MenuPage, MenuPageOut, True),
    ("menu_buttons", MenuButton, MenuButtonOut, False),
    ("pay_methods", PayMethod, PayMethodOut, False),
    ("staff", Staff, StaffOut, True),
    ("tax_rates", TaxRate, TaxRateOut, False),
    ("sales_types", SalesType, SalesTypeOut, False),
    ("kitchen_stations", KitchenStation, KitchenStationOut, True),
    # Meal-deal prompts. Appended, never inserted: a cursor issued before this
    # change names a table by index, and putting these in the middle would
    # resume that pull in the wrong table.
    ("questions", Question, QuestionOut, False),
    ("question_choices", QuestionChoice, QuestionChoiceOut, False),
    ("product_questions", ProductQuestion, ProductQuestionOut, False),
    ("combo_items", ComboItem, ComboItemOut, False),
]


def _parse_cursor(cursor: str | None) -> tuple[int, int, uuid.UUID | None] | None:
    """`<table index>:<server_version>:<id>` - opaque to the client.

    The id is parsed back into a UUID rather than left as text: the primary
    keys are Uuid columns, and comparing them against a string makes the
    driver fail on the bind rather than the row.
    """
    if not cursor:
        return None
    try:
        index, version, row_id = cursor.split(":", 2)
        return int(index), int(version), uuid.UUID(row_id) if row_id else None
    except (ValueError, AttributeError):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "malformed cursor; start the pull again without one",
        )


@router.get("/catalog", response_model=CatalogResponse)
async def get_catalog(
    since: int = Query(0, ge=0, description="watermark from the previous response"),
    cursor: str | None = Query(
        None,
        description="opaque position from the previous page; omit to start",
    ),
    ctx: DeviceContext = Depends(current_device),
) -> CatalogResponse:
    position = _parse_cursor(cursor)
    start_index = position[0] if position else 0
    if start_index >= len(TABLES):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "cursor points past the end of the catalog; start again without one",
        )

    budget = settings.catalog_page_size
    collected: dict[str, list] = {name: [] for name, _, _, _ in TABLES}
    highest = since
    next_cursor: str | None = None

    async with tenant_session(ctx.tenant_id) as session:
        for index in range(start_index, len(TABLES)):
            name, model, _, branch_scoped = TABLES[index]

            if budget <= 0:
                # Out of room with tables still to walk: resume at this one.
                next_cursor = f"{index}:{since}:"
                break

            stmt = select(model).where(
                model.tenant_id == ctx.tenant_id,
                model.server_version > since,
            )
            if branch_scoped and hasattr(model, "branch_id"):
                stmt = stmt.where(
                    or_(model.branch_id.is_(None),
                        model.branch_id == ctx.branch_id)
                )

            # Resume strictly after the last row of the previous page, but only
            # within the table that page stopped in.
            if position and index == start_index and position[2]:
                stmt = stmt.where(
                    tuple_(model.server_version, model.id)
                    > (position[1], position[2])
                )

            # One extra row tells us whether this table has more without a
            # second query.
            stmt = stmt.order_by(model.server_version, model.id).limit(budget + 1)
            rows = list((await session.execute(stmt)).scalars().all())

            more_in_table = len(rows) > budget
            if more_in_table:
                rows = rows[:budget]

            collected[name] = rows
            budget -= len(rows)
            if rows:
                highest = max(highest, max(r.server_version for r in rows))

            if more_in_table:
                last = rows[-1]
                next_cursor = f"{index}:{last.server_version}:{last.id}"
                break

    groups = [collected[name] for name, _, _, _ in TABLES]
    serialised = {
        name: [schema.model_validate(r) for r in collected[name]]
        for name, _, schema, _ in TABLES
    }

    if next_cursor is None and not any(groups):
        # Nothing changed. Hold the watermark where it was.
        highest = since

    return CatalogResponse(
        # While more pages are outstanding the device must keep its OLD
        # watermark, so echo it back rather than the highest version seen. A
        # client that ignored has_more and stored this would still be correct.
        version=since if next_cursor else highest,
        has_more=next_cursor is not None,
        next_cursor=next_cursor,
        **serialised,
    )
