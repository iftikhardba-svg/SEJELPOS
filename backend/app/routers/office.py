"""The back office.

What a restaurant actually needs before it can run this POS: see what sold,
change a price, add a till. Until now none of that existed - prices came in
through the PixelPoint migration and could only be changed with SQL, and
enrolment codes could only be minted with a curl command holding the
installation-wide admin token.

Two rules run through every endpoint here:

* **The tenant comes from the session token**, never from the request. Every
  query filters on it explicitly even where RLS would also catch it.
* **A catalog edit bumps `server_version`.** That counter is the only thing
  telling tablets there is something new to pull; an edit that does not bump it
  is an edit no till will ever see.
"""

from __future__ import annotations

import datetime as dt
import secrets
import uuid

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import func, or_, select

from ..config import settings
from ..db import SessionLocal, tenant_session
from ..models import (
    BackOfficeUser,
    Branch,
    Company,
    Device,
    EnrolmentCode,
    KitchenStation,
    MenuButton,
    MenuScreen,
    Product,
    ReportCategory,
    Sale,
    SalesType,
)
from ..office_auth import (
    OfficeContext,
    OfficeDep,
    issue_office_token,
    verify_password,
)
from ..schemas import (
    PRICE_TIERS,
    OfficeDashboard,
    OfficeDeviceOut,
    OfficeEnrolmentOut,
    OfficeLoginIn,
    OfficeLoginOut,
    OfficeMenuButtonMove,
    OfficeMenuButtonOut,
    OfficeMenuButtonPlace,
    OfficeMenuScreenCreate,
    OfficeMenuScreenOut,
    OfficeMenuScreenUpdate,
    OfficeProductCreate,
    OfficeProductOut,
    OfficeProductUpdate,
    OfficeSaleOut,
)

router = APIRouter(prefix="/office", tags=["back office"])


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _aware(value: dt.datetime | None) -> dt.datetime | None:
    """SQLite hands back naive datetimes; treat them as the UTC they were."""
    if value is None:
        return None
    return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value


async def _next_catalog_version(session, tenant_id: uuid.UUID) -> int:
    """One counter above everything the tenant's catalog currently holds.

    Taken across all the catalog tables a device pulls, because they share the
    device's single `since` watermark - versioning them independently would let
    a product edit hide behind a higher menu version.
    """
    highest = 0
    for model in (Product, MenuScreen, SalesType, ReportCategory):
        value = (
            await session.execute(
                select(func.max(model.server_version)).where(
                    model.tenant_id == tenant_id
                )
            )
        ).scalar()
        highest = max(highest, value or 0)
    return highest + 1


# --------------------------------------------------------------------------
# Session
# --------------------------------------------------------------------------

# A valid-shaped hash of a password nobody holds, used only to keep the failure
# path as slow as the success path.
_DUMMY_HASH = (
    "scrypt$32768$8$1$"
    "AAAAAAAAAAAAAAAAAAAAAA==$"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
)


@router.post("/login", response_model=OfficeLoginOut)
async def login(body: OfficeLoginIn) -> OfficeLoginOut:
    """Unauthenticated by design - this is how a session is obtained.

    A plain `SessionLocal`, not a `tenant_session`: there is no tenant yet,
    which is also why `back_office_user` carries no RLS policy. Email is
    globally unique, so this lookup can only ever match one account.

    The failure message never distinguishes an unknown address from a wrong
    password: telling an attacker which addresses exist is a free gift.
    """
    async with SessionLocal() as session:
        user = (
            await session.execute(
                select(BackOfficeUser).where(
                    func.lower(BackOfficeUser.email) == body.email.strip().lower()
                )
            )
        ).scalar_one_or_none()

        # Verify even when there is no such user, so a missing account and a
        # wrong password take the same time. Otherwise the response time
        # enumerates the user table.
        stored = user.password_hash if user else _DUMMY_HASH
        ok = verify_password(body.password, stored)

        if user is None or not ok or not user.is_active:
            raise HTTPException(
                status.HTTP_401_UNAUTHORIZED, "wrong email or password"
            )

        user.last_login_at = _now()
        token = issue_office_token(user.id, user.tenant_id)
        name, role, email, tenant_id = (
            user.name, user.role, user.email, user.tenant_id,
        )
        await session.commit()

        company_name = (
            await session.execute(
                select(Company.name).where(Company.tenant_id == tenant_id)
            )
        ).scalars().first()

    return OfficeLoginOut(
        token=token,
        name=name,
        email=email,
        role=role,
        company_name=company_name or "",
    )


@router.get("/me", response_model=OfficeLoginOut)
async def me(ctx: OfficeContext = OfficeDep) -> OfficeLoginOut:
    async with tenant_session(ctx.tenant_id) as session:
        company = (
            await session.execute(
                select(Company.name).where(Company.tenant_id == ctx.tenant_id)
            )
        ).scalars().first()
    return OfficeLoginOut(
        token="",  # already held by the caller; never re-issued on a read
        name=ctx.name,
        email=ctx.email,
        role=ctx.role,
        company_name=company or "",
    )


# --------------------------------------------------------------------------
# Dashboard
# --------------------------------------------------------------------------

@router.get("/dashboard", response_model=OfficeDashboard)
async def dashboard(
    business_date: dt.date | None = None,
    ctx: OfficeContext = OfficeDep,
) -> OfficeDashboard:
    """Today at a glance, and the two numbers nobody wants to discover late:
    sales that never got a ZATCA stamp, and devices that have gone quiet."""
    day = business_date or _now().date()

    async with tenant_session(ctx.tenant_id) as session:
        scope = [Sale.tenant_id == ctx.tenant_id, Sale.business_date == day]

        totals = (
            await session.execute(
                select(
                    func.count(Sale.sale_uuid),
                    func.coalesce(func.sum(Sale.final_total), 0),
                    func.coalesce(func.sum(Sale.tax_total), 0),
                ).where(*scope)
            )
        ).one()

        by_type_rows = (
            await session.execute(
                select(
                    Sale.sale_type,
                    func.count(Sale.sale_uuid),
                    func.coalesce(func.sum(Sale.final_total), 0),
                )
                .where(*scope)
                .group_by(Sale.sale_type)
                .order_by(func.sum(Sale.final_total).desc())
            )
        ).all()

        type_names = dict(
            (
                await session.execute(
                    select(SalesType.sale_type_no, SalesType.descript).where(
                        SalesType.tenant_id == ctx.tenant_id
                    )
                )
            ).all()
        )

        unsigned = (
            await session.execute(
                select(func.count(Sale.sale_uuid)).where(
                    *scope, Sale.zatca_qr.is_(None)
                )
            )
        ).scalar() or 0

        unreported = (
            await session.execute(
                select(func.count(Sale.sale_uuid)).where(
                    Sale.tenant_id == ctx.tenant_id,
                    Sale.zatca_status == "pending",
                )
            )
        ).scalar() or 0

        devices = (
            await session.execute(
                select(func.count(Device.id)).where(
                    Device.tenant_id == ctx.tenant_id, Device.is_active.is_(True)
                )
            )
        ).scalar() or 0

        # A till that has not spoken in a day is either off or broken, and
        # either way its sales are not here.
        silent_before = _now() - dt.timedelta(hours=24)
        silent = (
            await session.execute(
                select(func.count(Device.id)).where(
                    Device.tenant_id == ctx.tenant_id,
                    Device.is_active.is_(True),
                    (Device.last_seen_at.is_(None))
                    | (Device.last_seen_at < silent_before),
                )
            )
        ).scalar() or 0

    count, gross, vat = totals
    return OfficeDashboard(
        business_date=day,
        sale_count=count,
        gross_total=int(gross),
        vat_total=int(vat),
        net_total=int(gross) - int(vat),
        unsigned_sales=int(unsigned),
        unreported_sales=int(unreported),
        active_devices=int(devices),
        silent_devices=int(silent),
        by_sale_type=[
            {
                "sale_type": no,
                "name": type_names.get(no, f"Type {no}"),
                "count": c,
                "gross": int(g),
            }
            for no, c, g in by_type_rows
        ],
    )


# --------------------------------------------------------------------------
# Products and prices
# --------------------------------------------------------------------------

def _product_out(p: Product, menu_ids: list[int] | None = None) -> OfficeProductOut:
    return OfficeProductOut(
        id=p.id,
        prodnum=p.prodnum,
        descript=p.descript,
        descript_ar=p.descript_ar,
        print_des=p.print_des,
        tax_applies=p.tax_applies,
        is_weighed=p.is_weighed,
        manual_price=p.manual_price,
        is_modifier=p.is_modifier,
        is_active=p.is_active,
        print_loc=p.print_loc,
        report_no=p.report_no,
        prodtype=p.prodtype,
        ref_code=p.ref_code,
        unit_des=p.unit_des,
        button_text=p.button_text,
        fore_color=p.fore_color,
        back_color=p.back_color,
        server_version=p.server_version,
        menu_ids=menu_ids or [],
        **{f"price_{t}": getattr(p, f"price_{t}") for t in PRICE_TIERS},
    )


@router.get("/report-categories")
async def list_report_categories(ctx: OfficeContext = OfficeDep) -> list[dict]:
    """What sales reports group by, and how a 560-product menu is navigated."""
    async with tenant_session(ctx.tenant_id) as session:
        rows = (
            await session.execute(
                select(ReportCategory)
                .where(
                    ReportCategory.tenant_id == ctx.tenant_id,
                    ReportCategory.is_deleted.is_(False),
                )
                .order_by(ReportCategory.name)
            )
        ).scalars().all()

        counts = dict(
            (
                await session.execute(
                    select(Product.report_no, func.count(Product.id))
                    .where(
                        Product.tenant_id == ctx.tenant_id,
                        Product.is_deleted.is_(False),
                    )
                    .group_by(Product.report_no)
                )
            ).all()
        )

    return [
        {
            "report_no": c.report_no,
            "name": c.name,
            "name_ar": c.name_ar,
            "is_active": c.is_active,
            "default_print_loc": c.default_print_loc,
            "product_count": counts.get(c.report_no, 0),
        }
        for c in rows
    ]


@router.get("/kitchen-stations")
async def list_kitchen_stations(ctx: OfficeContext = OfficeDep) -> list[dict]:
    """Station numbers ARE printer ports, so a product's print_loc bitmask can
    be edited as names instead of a number nobody can read."""
    async with tenant_session(ctx.tenant_id) as session:
        rows = (
            await session.execute(
                select(KitchenStation)
                .where(
                    KitchenStation.tenant_id == ctx.tenant_id,
                    KitchenStation.is_deleted.is_(False),
                )
                .order_by(KitchenStation.station_no)
            )
        ).scalars().all()
    return [
        {"station_no": s.station_no, "name": s.name, "is_active": s.is_active}
        for s in rows
    ]


@router.get("/products", response_model=list[OfficeProductOut])
async def list_products(
    search: str = "",
    only_zero_price: bool = False,
    report_no: int | None = None,
    include_inactive: bool = True,
    limit: int = Query(default=200, le=1000),
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeProductOut]:
    """`only_zero_price` exists for a real backlog item: the migration left 68
    active, non-modifier products priced at zero. They need a human decision
    before go-live, and this is how that person finds them."""
    async with tenant_session(ctx.tenant_id) as session:
        stmt = select(Product).where(
            Product.tenant_id == ctx.tenant_id,
            Product.is_deleted.is_(False),
        )
        if search.strip():
            term = f"%{search.strip()}%"
            # Number as well as name: staff know items by their prodnum, and
            # it is what the kitchen tickets and the old system show.
            conditions = [Product.descript.ilike(term)]
            if search.strip().isdigit():
                conditions.append(Product.prodnum == int(search.strip()))
            stmt = stmt.where(or_(*conditions))
        if report_no is not None:
            stmt = stmt.where(Product.report_no == report_no)
        if not include_inactive:
            stmt = stmt.where(Product.is_active.is_(True))
        if only_zero_price:
            stmt = stmt.where(
                Product.price_a == 0,
                Product.is_modifier.is_(False),
                Product.is_active.is_(True),
            )
        stmt = stmt.order_by(Product.descript).limit(limit)
        rows = list((await session.execute(stmt)).scalars().all())

    return [_product_out(p) for p in rows]


@router.get("/products/{product_id}", response_model=OfficeProductOut)
async def get_product(
    product_id: uuid.UUID,
    ctx: OfficeContext = OfficeDep,
) -> OfficeProductOut:
    """One product, with the menu screens it appears on."""
    async with tenant_session(ctx.tenant_id) as session:
        product = (
            await session.execute(
                select(Product).where(
                    Product.id == product_id,
                    Product.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if product is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such product")

        menu_ids = list(
            (
                await session.execute(
                    select(MenuButton.menu_id).where(
                        MenuButton.tenant_id == ctx.tenant_id,
                        MenuButton.prodnum == product.prodnum,
                        MenuButton.is_deleted.is_(False),
                    ).distinct()
                )
            ).scalars().all()
        )

    return _product_out(product, menu_ids)


@router.post("/products", response_model=OfficeProductOut, status_code=201)
async def create_product(
    body: OfficeProductCreate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeProductOut:
    """Add a product.

    A new product is not on any menu screen yet, so no till will show it until
    someone puts a button on one. That is deliberate: silently placing it
    somewhere would move a button under a cashier's finger mid-service.
    """
    async with tenant_session(ctx.tenant_id) as session:
        clash = (
            await session.execute(
                select(Product).where(
                    Product.tenant_id == ctx.tenant_id,
                    Product.prodnum == body.prodnum,
                )
            )
        ).scalar_one_or_none()
        if clash is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"product number {body.prodnum} is already {clash.descript}",
            )

        branch = (
            await session.execute(
                select(Branch.id).where(Branch.tenant_id == ctx.tenant_id)
            )
        ).scalars().first()

        product = Product(
            tenant_id=ctx.tenant_id,
            branch_id=branch,
            server_version=await _next_catalog_version(session, ctx.tenant_id),
            **body.model_dump(),
        )
        session.add(product)
        await session.flush()
        return _product_out(product)


@router.patch("/products/{product_id}", response_model=OfficeProductOut)
async def update_product(
    product_id: uuid.UUID,
    body: OfficeProductUpdate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeProductOut:
    """Change a price or availability.

    Refuses to leave an aggregator-priced product without a tier B price. The
    till will not silently fall back to tier A - it refuses the sale - so the
    real cost of a missing tier B is a cashier who cannot ring a Keeta order at
    the counter. Better to block it here, where someone can fix it.
    """
    async with tenant_session(ctx.tenant_id) as session:
        product = (
            await session.execute(
                select(Product).where(
                    Product.id == product_id,
                    Product.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if product is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such product")

        fields = body.model_dump(exclude_unset=True)
        if not fields:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "nothing to change")

        for key, value in fields.items():
            setattr(product, key, value)

        aggregator_exists = (
            await session.execute(
                select(func.count(SalesType.id)).where(
                    SalesType.tenant_id == ctx.tenant_id,
                    SalesType.is_aggregator.is_(True),
                    SalesType.price_tier == "b",
                )
            )
        ).scalar() or 0
        if (
            aggregator_exists
            and product.is_active
            and not product.is_modifier
            and product.price_b is None
        ):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"{product.descript} needs a tier B price: this tenant sells "
                "through an aggregator, and a till refuses the sale rather "
                "than charging the walk-in price and giving away the "
                "commission",
            )

        # Without this the edit is invisible to every till already in the field.
        product.server_version = await _next_catalog_version(session, ctx.tenant_id)
        await session.flush()
        return _product_out(product)


# --------------------------------------------------------------------------
# Menu layout
#
# An order page is a grid of buttons, and where a button sits is the thing
# staff actually navigate by — they reach for a position long before they read
# a label. So this works in (x, y), not list order.
# --------------------------------------------------------------------------

async def _bump_menu(session, tenant_id: uuid.UUID, *rows) -> int:
    """Stamp a menu change so tills pull it. Without this the layout changes
    in the back office and on no till."""
    version = await _next_catalog_version(session, tenant_id)
    for row in rows:
        row.server_version = version
    return version


@router.get("/menu-screens", response_model=list[OfficeMenuScreenOut])
async def list_menu_screens(
    include_modifier: bool = False,
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeMenuScreenOut]:
    async with tenant_session(ctx.tenant_id) as session:
        stmt = select(MenuScreen).where(
            MenuScreen.tenant_id == ctx.tenant_id,
            MenuScreen.is_deleted.is_(False),
        )
        if not include_modifier:
            stmt = stmt.where(MenuScreen.is_modifier_screen.is_(False))
        screens = list(
            (await session.execute(
                stmt.order_by(MenuScreen.sort_order, MenuScreen.name)
            )).scalars().all()
        )

        # Counts and the space the existing buttons need, in one pass rather
        # than a query per page — there are 64 of them.
        usage = {
            menu_id: (count, across or 0, down or 0)
            for menu_id, count, across, down in (
                await session.execute(
                    select(
                        MenuButton.menu_id,
                        func.count(MenuButton.id),
                        func.max(MenuButton.pos_x),
                        func.max(MenuButton.pos_y),
                    )
                    .where(
                        MenuButton.tenant_id == ctx.tenant_id,
                        MenuButton.is_deleted.is_(False),
                    )
                    .group_by(MenuButton.menu_id)
                )
            ).all()
        }

    return [
        OfficeMenuScreenOut(
            id=s.id,
            menu_id=s.menu_id,
            name=s.name,
            name_ar=s.name_ar,
            sort_order=s.sort_order,
            buttons_across=s.buttons_across or None,
            buttons_down=s.buttons_down or None,
            is_modifier_screen=s.is_modifier_screen,
            is_active=s.is_active,
            button_count=usage.get(s.menu_id, (0, 0, 0))[0],
            used_across=usage.get(s.menu_id, (0, 0, 0))[1],
            used_down=usage.get(s.menu_id, (0, 0, 0))[2],
        )
        for s in screens
    ]


@router.post("/menu-screens", response_model=OfficeMenuScreenOut, status_code=201)
async def create_menu_screen(
    body: OfficeMenuScreenCreate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeMenuScreenOut:
    async with tenant_session(ctx.tenant_id) as session:
        clash = (
            await session.execute(
                select(MenuScreen).where(
                    MenuScreen.tenant_id == ctx.tenant_id,
                    MenuScreen.menu_id == body.menu_id,
                )
            )
        ).scalar_one_or_none()
        if clash is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"page number {body.menu_id} is already {clash.name}",
            )

        branch = (
            await session.execute(
                select(Branch.id).where(Branch.tenant_id == ctx.tenant_id)
            )
        ).scalars().first()

        screen = MenuScreen(
            tenant_id=ctx.tenant_id,
            branch_id=branch,
            server_version=await _next_catalog_version(session, ctx.tenant_id),
            **body.model_dump(),
        )
        session.add(screen)
        await session.flush()

    return OfficeMenuScreenOut(
        id=screen.id, menu_id=screen.menu_id, name=screen.name,
        name_ar=screen.name_ar, sort_order=screen.sort_order,
        buttons_across=screen.buttons_across, buttons_down=screen.buttons_down,
        is_modifier_screen=screen.is_modifier_screen,
        is_active=screen.is_active,
    )


@router.patch("/menu-screens/{screen_id}", response_model=OfficeMenuScreenOut)
async def update_menu_screen(
    screen_id: uuid.UUID,
    body: OfficeMenuScreenUpdate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeMenuScreenOut:
    fields = body.model_dump(exclude_unset=True)
    if not fields:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "nothing to change")

    async with tenant_session(ctx.tenant_id) as session:
        screen = (
            await session.execute(
                select(MenuScreen).where(
                    MenuScreen.id == screen_id,
                    MenuScreen.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if screen is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such page")

        # Shrinking a grid below the buttons on it would hide them from every
        # till while leaving them in the database — invisible and still sold
        # by number. Refuse and say which corner is in the way.
        used = (
            await session.execute(
                select(func.max(MenuButton.pos_x), func.max(MenuButton.pos_y))
                .where(
                    MenuButton.tenant_id == ctx.tenant_id,
                    MenuButton.menu_id == screen.menu_id,
                    MenuButton.is_deleted.is_(False),
                )
            )
        ).one()
        used_x, used_y = used[0] or 0, used[1] or 0
        across = fields.get("buttons_across", screen.buttons_across)
        down = fields.get("buttons_down", screen.buttons_down)
        if across and across < used_x:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"a button sits in column {used_x}; move it before making the "
                f"page {across} wide",
            )
        if down and down < used_y:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"a button sits in row {used_y}; move it before making the "
                f"page {down} tall",
            )

        for key, value in fields.items():
            setattr(screen, key, value)
        await _bump_menu(session, ctx.tenant_id, screen)
        await session.flush()

        count = (
            await session.execute(
                select(func.count(MenuButton.id)).where(
                    MenuButton.tenant_id == ctx.tenant_id,
                    MenuButton.menu_id == screen.menu_id,
                    MenuButton.is_deleted.is_(False),
                )
            )
        ).scalar() or 0

    return OfficeMenuScreenOut(
        id=screen.id, menu_id=screen.menu_id, name=screen.name,
        name_ar=screen.name_ar, sort_order=screen.sort_order,
        buttons_across=screen.buttons_across, buttons_down=screen.buttons_down,
        is_modifier_screen=screen.is_modifier_screen,
        is_active=screen.is_active, button_count=count,
        used_across=used_x, used_down=used_y,
    )


@router.get(
    "/menu-screens/{screen_id}/buttons",
    response_model=list[OfficeMenuButtonOut],
)
async def list_menu_buttons(
    screen_id: uuid.UUID,
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeMenuButtonOut]:
    async with tenant_session(ctx.tenant_id) as session:
        screen = (
            await session.execute(
                select(MenuScreen).where(
                    MenuScreen.id == screen_id,
                    MenuScreen.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if screen is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such page")

        rows = (
            await session.execute(
                select(MenuButton, Product)
                .join(
                    Product,
                    (Product.prodnum == MenuButton.prodnum)
                    & (Product.tenant_id == MenuButton.tenant_id),
                    isouter=True,
                )
                .where(
                    MenuButton.tenant_id == ctx.tenant_id,
                    MenuButton.menu_id == screen.menu_id,
                    MenuButton.is_deleted.is_(False),
                )
                .order_by(MenuButton.pos_y, MenuButton.pos_x)
            )
        ).all()

    return [
        OfficeMenuButtonOut(
            id=b.id,
            prodnum=b.prodnum,
            pos_x=b.pos_x or 1,
            pos_y=b.pos_y or 1,
            descript=p.descript if p else f"(missing product {b.prodnum})",
            button_text=p.button_text if p else None,
            fore_color=p.fore_color if p else None,
            back_color=p.back_color if p else None,
            price_a=p.price_a if p else 0,
            is_active=bool(p.is_active) if p else False,
        )
        for b, p in rows
    ]


@router.post(
    "/menu-screens/{screen_id}/buttons",
    response_model=OfficeMenuButtonOut,
    status_code=201,
)
async def place_menu_button(
    screen_id: uuid.UUID,
    body: OfficeMenuButtonPlace,
    ctx: OfficeContext = OfficeDep,
) -> OfficeMenuButtonOut:
    """Put a product on a page at a cell."""
    async with tenant_session(ctx.tenant_id) as session:
        screen = (
            await session.execute(
                select(MenuScreen).where(
                    MenuScreen.id == screen_id,
                    MenuScreen.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if screen is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such page")

        product = (
            await session.execute(
                select(Product).where(
                    Product.tenant_id == ctx.tenant_id,
                    Product.prodnum == body.prodnum,
                    Product.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if product is None:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND,
                f"no product numbered {body.prodnum}",
            )

        occupant = (
            await session.execute(
                select(MenuButton).where(
                    MenuButton.tenant_id == ctx.tenant_id,
                    MenuButton.menu_id == screen.menu_id,
                    MenuButton.pos_x == body.pos_x,
                    MenuButton.pos_y == body.pos_y,
                    MenuButton.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if occupant is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"that cell already holds product {occupant.prodnum}",
            )

        button = MenuButton(
            tenant_id=ctx.tenant_id,
            menu_screen_id=screen.id,
            product_id=product.id,
            menu_id=screen.menu_id,
            prodnum=product.prodnum,
            pos_x=body.pos_x,
            pos_y=body.pos_y,
            # Row-major, so a till that ignores the grid still shows buttons
            # in the order they read on the page.
            position=(body.pos_y - 1) * 100 + body.pos_x,
            server_version=await _next_catalog_version(session, ctx.tenant_id),
        )
        session.add(button)
        await session.flush()

    return OfficeMenuButtonOut(
        id=button.id, prodnum=product.prodnum,
        pos_x=button.pos_x, pos_y=button.pos_y,
        descript=product.descript, button_text=product.button_text,
        fore_color=product.fore_color, back_color=product.back_color,
        price_a=product.price_a, is_active=product.is_active,
    )


@router.patch("/menu-buttons/{button_id}", response_model=OfficeMenuButtonOut)
async def move_menu_button(
    button_id: uuid.UUID,
    body: OfficeMenuButtonMove,
    ctx: OfficeContext = OfficeDep,
) -> OfficeMenuButtonOut:
    async with tenant_session(ctx.tenant_id) as session:
        button = (
            await session.execute(
                select(MenuButton).where(
                    MenuButton.id == button_id,
                    MenuButton.tenant_id == ctx.tenant_id,
                    MenuButton.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if button is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such button")

        occupant = (
            await session.execute(
                select(MenuButton).where(
                    MenuButton.tenant_id == ctx.tenant_id,
                    MenuButton.menu_id == button.menu_id,
                    MenuButton.pos_x == body.pos_x,
                    MenuButton.pos_y == body.pos_y,
                    MenuButton.id != button.id,
                    MenuButton.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()

        if occupant is not None:
            # Swap rather than refuse: dragging one button onto another is a
            # rearrangement, and making someone empty a cell first is busywork.
            occupant.pos_x, occupant.pos_y = button.pos_x, button.pos_y
            occupant.position = (occupant.pos_y - 1) * 100 + occupant.pos_x
            await _bump_menu(session, ctx.tenant_id, occupant)

        button.pos_x, button.pos_y = body.pos_x, body.pos_y
        button.position = (body.pos_y - 1) * 100 + body.pos_x
        await _bump_menu(session, ctx.tenant_id, button)
        await session.flush()

        product = (
            await session.execute(
                select(Product).where(
                    Product.tenant_id == ctx.tenant_id,
                    Product.prodnum == button.prodnum,
                )
            )
        ).scalar_one_or_none()

    return OfficeMenuButtonOut(
        id=button.id, prodnum=button.prodnum,
        pos_x=button.pos_x, pos_y=button.pos_y,
        descript=product.descript if product else "",
        button_text=product.button_text if product else None,
        fore_color=product.fore_color if product else None,
        back_color=product.back_color if product else None,
        price_a=product.price_a if product else 0,
        is_active=bool(product.is_active) if product else False,
    )


@router.delete("/menu-buttons/{button_id}", status_code=204)
async def remove_menu_button(
    button_id: uuid.UUID,
    ctx: OfficeContext = OfficeDep,
) -> None:
    """Take a button off a page.

    Soft delete, and not only because the application role has no DELETE
    grant: a device pulling incrementally learns that a button is gone by
    seeing the row marked deleted. A hard delete is invisible to it, and the
    button would stay on the till for good.
    """
    async with tenant_session(ctx.tenant_id) as session:
        button = (
            await session.execute(
                select(MenuButton).where(
                    MenuButton.id == button_id,
                    MenuButton.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if button is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such button")

        button.is_deleted = True
        await _bump_menu(session, ctx.tenant_id, button)


# --------------------------------------------------------------------------
# Devices
# --------------------------------------------------------------------------

@router.get("/devices", response_model=list[OfficeDeviceOut])
async def list_devices(ctx: OfficeContext = OfficeDep) -> list[OfficeDeviceOut]:
    async with tenant_session(ctx.tenant_id) as session:
        rows = (
            await session.execute(
                select(Device, Branch.name)
                .join(Branch, Branch.id == Device.branch_id)
                .where(Device.tenant_id == ctx.tenant_id)
                .order_by(Device.receipt_prefix)
            )
        ).all()

    return [
        OfficeDeviceOut(
            id=d.id,
            label=d.label,
            branch_name=branch_name,
            role=d.role,
            receipt_prefix=d.receipt_prefix,
            platform=d.platform,
            app_version=d.app_version,
            csid_status=d.csid_status,
            last_seen_at=_aware(d.last_seen_at),
            last_icv=d.last_icv,
            is_active=d.is_active,
        )
        for d, branch_name in rows
    ]


@router.post(
    "/devices/enrolments",
    response_model=OfficeEnrolmentOut,
    status_code=201,
)
async def create_enrolment(
    branch_id: uuid.UUID,
    label: str,
    receipt_prefix: str,
    role: str = "pos",
    kds_station_no: int | None = None,
    ctx: OfficeContext = OfficeDep,
) -> OfficeEnrolmentOut:
    """Mint a one-time code for a new till.

    This is the tenant-scoped replacement for `POST /admin/enrolments`, which
    needs the installation-wide admin token. A restaurant manager adding a
    till should not be holding a secret that reaches every other customer.
    """
    if role not in ("pos", "kds", "cds"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "unknown device role")

    async with tenant_session(ctx.tenant_id) as session:
        branch = (
            await session.execute(
                select(Branch).where(
                    Branch.id == branch_id, Branch.tenant_id == ctx.tenant_id
                )
            )
        ).scalar_one_or_none()
        if branch is None:
            # Scoped lookup, so another tenant's branch id reads as absent
            # rather than forbidden - it should not confirm the id exists.
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such branch")

        code = EnrolmentCode(
            tenant_id=ctx.tenant_id,
            branch_id=branch.id,
            code=secrets.token_urlsafe(32),
            label=label,
            receipt_prefix=receipt_prefix,
            role=role,
            kds_station_no=kds_station_no,
            expires_at=_now() + dt.timedelta(hours=settings.enrolment_code_hours),
        )
        session.add(code)
        await session.flush()

        return OfficeEnrolmentOut(
            code=code.code,
            branch_name=branch.name,
            label=label,
            role=role,
            expires_at=_aware(code.expires_at),
        )


@router.get("/branches")
async def list_branches(ctx: OfficeContext = OfficeDep) -> list[dict]:
    async with tenant_session(ctx.tenant_id) as session:
        rows = (
            await session.execute(
                select(Branch)
                .where(Branch.tenant_id == ctx.tenant_id)
                .order_by(Branch.name)
            )
        ).scalars().all()
    return [{"id": str(b.id), "name": b.name, "code": b.code} for b in rows]


# --------------------------------------------------------------------------
# Sales
# --------------------------------------------------------------------------

@router.get("/sales", response_model=list[OfficeSaleOut])
async def list_sales(
    business_date: dt.date | None = None,
    unsigned_only: bool = False,
    limit: int = Query(default=100, le=500),
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeSaleOut]:
    async with tenant_session(ctx.tenant_id) as session:
        stmt = select(Sale).where(Sale.tenant_id == ctx.tenant_id)
        if business_date is not None:
            stmt = stmt.where(Sale.business_date == business_date)
        if unsigned_only:
            stmt = stmt.where(Sale.zatca_qr.is_(None))
        stmt = stmt.order_by(Sale.closed_at.desc()).limit(limit)
        rows = list((await session.execute(stmt)).scalars().all())

        type_names = dict(
            (
                await session.execute(
                    select(SalesType.sale_type_no, SalesType.descript).where(
                        SalesType.tenant_id == ctx.tenant_id
                    )
                )
            ).all()
        )

    return [
        OfficeSaleOut(
            receipt_no=s.receipt_no,
            closed_at=_aware(s.closed_at),
            business_date=s.business_date,
            sale_type_name=type_names.get(s.sale_type, f"Type {s.sale_type}"),
            order_no=s.order_no,
            external_ref=s.external_ref,
            net_total=s.net_total,
            tax_total=s.tax_total,
            final_total=s.final_total,
            is_signed=s.zatca_qr is not None,
            zatca_icv=s.zatca_icv,
            zatca_status=s.zatca_status,
            zatca_error=s.zatca_error,
        )
        for s in rows
    ]
