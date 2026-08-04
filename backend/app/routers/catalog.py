"""GET /catalog — incremental pull, server to device.

Paging note: a restaurant catalog is small (the first real customer's is ~1,200
rows in total), and a tablet needs all of it to function offline, so this
endpoint returns everything that changed in one response rather than paging.

The cap below is a guard, not a page size: if a tenant's catalog ever exceeds
it, the request fails loudly instead of silently truncating. A tablet quietly
missing half its products would show up as "that item isn't on the till"
days later, which is far worse than an error here.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_, select

from ..auth import DeviceContext, current_device
from ..config import settings
from ..db import tenant_session
from ..models import (
    KitchenStation,
    MenuButton,
    MenuScreen,
    PayMethod,
    Product,
    SalesType,
    Staff,
    TaxRate,
)
from ..schemas import (
    CatalogResponse,
    KitchenStationOut,
    MenuButtonOut,
    MenuScreenOut,
    PayMethodOut,
    ProductOut,
    SalesTypeOut,
    StaffOut,
    TaxRateOut,
)

router = APIRouter(tags=["catalog"])


@router.get("/catalog", response_model=CatalogResponse)
async def get_catalog(
    since: int = Query(0, ge=0, description="watermark from the previous response"),
    ctx: DeviceContext = Depends(current_device),
) -> CatalogResponse:
    async with tenant_session(ctx.tenant_id) as session:

        async def fetch(model, extra_scope=True):
            stmt = select(model).where(
                model.tenant_id == ctx.tenant_id,
                model.server_version > since,
            )
            if extra_scope and hasattr(model, "branch_id"):
                # NULL branch means "applies to every branch in the tenant".
                stmt = stmt.where(
                    or_(model.branch_id.is_(None), model.branch_id == ctx.branch_id)
                )
            stmt = stmt.order_by(model.server_version, model.id)
            return list((await session.execute(stmt)).scalars().all())

        products = await fetch(Product)
        screens = await fetch(MenuScreen)
        buttons = await fetch(MenuButton, extra_scope=False)
        methods = await fetch(PayMethod, extra_scope=False)
        staff = await fetch(Staff)
        taxes = await fetch(TaxRate, extra_scope=False)
        sale_types = await fetch(SalesType, extra_scope=False)
        stations = await fetch(KitchenStation)

    groups = (products, screens, buttons, methods, staff, taxes, sale_types,
              stations)
    total = sum(len(g) for g in groups)
    if total > settings.catalog_page_size:
        raise HTTPException(
            status.HTTP_507_INSUFFICIENT_STORAGE,
            f"catalog delta is {total} rows, above the {settings.catalog_page_size} "
            "row limit; paging is required for a catalog this size",
        )

    version = max(
        (row.server_version for g in groups for row in g),
        default=since,
    )

    return CatalogResponse(
        version=version,
        has_more=False,
        products=[ProductOut.model_validate(r) for r in products],
        menu_screens=[MenuScreenOut.model_validate(r) for r in screens],
        menu_buttons=[MenuButtonOut.model_validate(r) for r in buttons],
        pay_methods=[PayMethodOut.model_validate(r) for r in methods],
        staff=[StaffOut.model_validate(r) for r in staff],
        tax_rates=[TaxRateOut.model_validate(r) for r in taxes],
        sales_types=[SalesTypeOut.model_validate(r) for r in sale_types],
        kitchen_stations=[KitchenStationOut.model_validate(r) for r in stations],
    )
