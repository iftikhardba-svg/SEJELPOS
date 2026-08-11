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
from base64 import b64decode
from binascii import Error as BinasciiError

from fastapi import APIRouter, HTTPException, Query, Response, status
from sqlalchemy import func, or_, select

from ..config import settings
from ..db import SessionLocal, tenant_session
from ..models import (
    BackOfficeUser,
    Branch,
    ComboItem,
    Company,
    Device,
    DiningTable,
    EnrolmentCode,
    FloorSection,
    KitchenStation,
    Menu,
    MenuButton,
    MenuPage,
    MenuScreen,
    Product,
    ProductImage,
    ProductQuestion,
    Question,
    QuestionChoice,
    ReportCategory,
    Sale,
    SalesType,
    SessionTable,
    TableSession,
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
    OfficeFloorSectionCreate,
    OfficeFloorSectionOut,
    OfficeFloorSectionUpdate,
    OfficeLoginIn,
    OfficeLoginOut,
    OfficeMenuButtonMove,
    OfficeMenuButtonOut,
    OfficeMenuButtonPlace,
    OfficeMenuOut,
    OfficeMenuPageOut,
    OfficeMenuPagePlace,
    OfficeMenuScreenCreate,
    OfficeMenuScreenOut,
    OfficeMenuScreenUpdate,
    OfficeProductCreate,
    ImageRules,
    OfficeProductOut,
    ProductImageIn,
    OfficeProductUpdate,
    OfficeQuestionOut,
    OfficeSaleOut,
    OfficeTableCreate,
    OfficeTableOut,
    OfficeTableUpdate,
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
    for model in (Product, MenuScreen, SalesType, ReportCategory, Menu,
                  MenuPage, MenuButton, Question, QuestionChoice,
                  ProductQuestion, ComboItem, ProductImage):
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

@router.get("/questions", response_model=list[OfficeQuestionOut])
async def list_questions(ctx: OfficeContext = OfficeDep) -> list[OfficeQuestionOut]:
    """The meal-deal prompts, with their choices and how many items ask them."""
    async with tenant_session(ctx.tenant_id) as session:
        questions = list(
            (await session.execute(
                select(Question)
                .where(Question.tenant_id == ctx.tenant_id,
                       Question.is_deleted.is_(False))
                .order_by(Question.prompt)
            )).scalars().all()
        )

        choices = (
            await session.execute(
                select(QuestionChoice, Product.descript, Product.price_a)
                .join(
                    Product,
                    (Product.prodnum == QuestionChoice.prodnum)
                    & (Product.tenant_id == QuestionChoice.tenant_id),
                    isouter=True,
                )
                .where(QuestionChoice.tenant_id == ctx.tenant_id,
                       QuestionChoice.is_deleted.is_(False))
                .order_by(QuestionChoice.question_no, QuestionChoice.sort_order)
            )
        ).all()

        used = dict(
            (
                await session.execute(
                    select(ProductQuestion.question_no,
                           func.count(ProductQuestion.id))
                    .where(ProductQuestion.tenant_id == ctx.tenant_id,
                           ProductQuestion.is_deleted.is_(False))
                    .group_by(ProductQuestion.question_no)
                )
            ).all()
        )

    by_question: dict[int, list[dict]] = {}
    for choice, descript, price in choices:
        by_question.setdefault(choice.question_no, []).append({
            "prodnum": choice.prodnum,
            "name": descript or f"(missing product {choice.prodnum})",
            "price_a": price or 0,
        })

    return [
        OfficeQuestionOut(
            question_no=q.question_no,
            prompt=q.prompt,
            is_required=q.is_required,
            pick_count=q.pick_count,
            allow_repeats=q.allow_repeats,
            is_active=q.is_active,
            choices=by_question.get(q.question_no, []),
            used_by=used.get(q.question_no, 0),
        )
        for q in questions
    ]


def _product_out(p: Product, menu_ids: list[int] | None = None,
                 question_nos: list[int] | None = None,
                 image: ProductImage | None = None) -> OfficeProductOut:
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
        has_image=bool(image and not image.is_deleted),
        image_version=image.server_version if image else 0,
        server_version=p.server_version,
        menu_ids=menu_ids or [],
        question_nos=question_nos or [],
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
        question_nos = list(
            (
                await session.execute(
                    select(ProductQuestion.question_no)
                    .where(
                        ProductQuestion.tenant_id == ctx.tenant_id,
                        ProductQuestion.prodnum == product.prodnum,
                        ProductQuestion.is_deleted.is_(False),
                    )
                    .order_by(ProductQuestion.slot)
                )
            ).scalars().all()
        )
        image = (
            await session.execute(
                select(ProductImage).where(
                    ProductImage.tenant_id == ctx.tenant_id,
                    ProductImage.prodnum == product.prodnum,
                )
            )
        ).scalar_one_or_none()

    return _product_out(product, menu_ids, question_nos, image=image)


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

        # The prompt list is replaced wholesale: five ordered slots have no
        # sensible partial update, and re-slotting them one at a time would
        # let a save land with two prompts in slot 2.
        question_nos = fields.pop("question_nos", None)
        for key, value in fields.items():
            setattr(product, key, value)

        if question_nos is not None:
            known = set(
                (
                    await session.execute(
                        select(Question.question_no).where(
                            Question.tenant_id == ctx.tenant_id,
                            Question.is_deleted.is_(False),
                        )
                    )
                ).scalars().all()
            )
            unknown = [q for q in question_nos if q not in known]
            if unknown:
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    f"no such prompt: {', '.join(str(q) for q in unknown)}",
                )
            if len(set(question_nos)) != len(question_nos):
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    "the same prompt cannot be asked twice for one item",
                )

            existing = list(
                (
                    await session.execute(
                        select(ProductQuestion).where(
                            ProductQuestion.tenant_id == ctx.tenant_id,
                            ProductQuestion.prodnum == product.prodnum,
                        )
                    )
                ).scalars().all()
            )
            by_slot = {row.slot: row for row in existing}
            for slot in range(1, 6):
                row = by_slot.get(slot)
                wanted = (
                    question_nos[slot - 1] if slot <= len(question_nos) else None
                )
                if wanted is None:
                    if row is not None and not row.is_deleted:
                        # Tombstoned, not removed: a device learns a prompt is
                        # gone by seeing the row deleted.
                        row.is_deleted = True
                        row.server_version = 0
                elif row is None:
                    session.add(ProductQuestion(
                        tenant_id=ctx.tenant_id,
                        prodnum=product.prodnum,
                        question_no=wanted,
                        slot=slot,
                        server_version=0,
                    ))
                else:
                    row.question_no = wanted
                    row.is_deleted = False

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
        version = await _next_catalog_version(session, ctx.tenant_id)
        product.server_version = version
        await session.flush()

        # Stamp the prompt rows with the same version, including the ones just
        # created, so a device pulls the product and its prompts together.
        for row in (
            await session.execute(
                select(ProductQuestion).where(
                    ProductQuestion.tenant_id == ctx.tenant_id,
                    ProductQuestion.prodnum == product.prodnum,
                    ProductQuestion.server_version == 0,
                )
            )
        ).scalars():
            row.server_version = version
        await session.flush()

        current = list(
            (
                await session.execute(
                    select(ProductQuestion.question_no)
                    .where(
                        ProductQuestion.tenant_id == ctx.tenant_id,
                        ProductQuestion.prodnum == product.prodnum,
                        ProductQuestion.is_deleted.is_(False),
                    )
                    .order_by(ProductQuestion.slot)
                )
            ).scalars().all()
        )
        return _product_out(product, question_nos=current)


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


@router.get("/menus", response_model=list[OfficeMenuOut])
async def list_menus(ctx: OfficeContext = OfficeDep) -> list[OfficeMenuOut]:
    """The menus a till can land on. Most sites have one; this customer has
    three, and only one of them is laid out."""
    async with tenant_session(ctx.tenant_id) as session:
        menus = list(
            (await session.execute(
                select(Menu)
                .where(Menu.tenant_id == ctx.tenant_id,
                       Menu.is_deleted.is_(False))
                .order_by(Menu.name)
            )).scalars().all()
        )
        usage = {
            menu_no: (count, x or 0, y or 0)
            for menu_no, count, x, y in (
                await session.execute(
                    select(
                        MenuPage.menu_no,
                        func.count(MenuPage.id),
                        func.max(MenuPage.pos_x),
                        func.max(MenuPage.pos_y),
                    )
                    .where(MenuPage.tenant_id == ctx.tenant_id,
                           MenuPage.is_deleted.is_(False))
                    .group_by(MenuPage.menu_no)
                )
            ).all()
        }

    return [
        OfficeMenuOut(
            id=m.id, menu_no=m.menu_no, name=m.name, name_ar=m.name_ar,
            is_active=m.is_active,
            page_count=usage.get(m.menu_no, (0, 0, 0))[0],
            used_across=usage.get(m.menu_no, (0, 0, 0))[1],
            used_down=usage.get(m.menu_no, (0, 0, 0))[2],
        )
        for m in menus
    ]


@router.get("/menus/{menu_id}/pages", response_model=list[OfficeMenuPageOut])
async def list_menu_pages(
    menu_id: uuid.UUID,
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeMenuPageOut]:
    async with tenant_session(ctx.tenant_id) as session:
        menu = (
            await session.execute(
                select(Menu).where(Menu.id == menu_id,
                                   Menu.tenant_id == ctx.tenant_id)
            )
        ).scalar_one_or_none()
        if menu is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such menu")

        rows = (
            await session.execute(
                select(MenuPage, MenuScreen)
                .join(
                    MenuScreen,
                    (MenuScreen.menu_id == MenuPage.screen_no)
                    & (MenuScreen.tenant_id == MenuPage.tenant_id),
                    isouter=True,
                )
                .where(
                    MenuPage.tenant_id == ctx.tenant_id,
                    MenuPage.menu_no == menu.menu_no,
                    MenuPage.is_deleted.is_(False),
                )
                .order_by(MenuPage.pos_y, MenuPage.pos_x)
            )
        ).all()

        counts = dict(
            (
                await session.execute(
                    select(MenuButton.menu_id, func.count(MenuButton.id))
                    .where(MenuButton.tenant_id == ctx.tenant_id,
                           MenuButton.is_deleted.is_(False))
                    .group_by(MenuButton.menu_id)
                )
            ).all()
        )

    return [
        OfficeMenuPageOut(
            id=p.id,
            screen_no=p.screen_no,
            name=s.name if s else f"(missing page {p.screen_no})",
            pos_x=p.pos_x, pos_y=p.pos_y,
            fore_color=s.fore_color if s else None,
            back_color=s.back_color if s else None,
            button_count=counts.get(p.screen_no, 0),
            is_active=p.is_active and bool(s.is_active) if s else False,
        )
        for p, s in rows
    ]


@router.post(
    "/menus/{menu_id}/pages",
    response_model=OfficeMenuPageOut,
    status_code=201,
)
async def place_menu_page(
    menu_id: uuid.UUID,
    body: OfficeMenuPagePlace,
    ctx: OfficeContext = OfficeDep,
) -> OfficeMenuPageOut:
    """Put an order page on a menu's grid."""
    async with tenant_session(ctx.tenant_id) as session:
        menu = (
            await session.execute(
                select(Menu).where(Menu.id == menu_id,
                                   Menu.tenant_id == ctx.tenant_id)
            )
        ).scalar_one_or_none()
        if menu is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such menu")

        screen = (
            await session.execute(
                select(MenuScreen).where(
                    MenuScreen.tenant_id == ctx.tenant_id,
                    MenuScreen.menu_id == body.screen_no,
                    MenuScreen.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if screen is None:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND, f"no page numbered {body.screen_no}"
            )

        existing = (
            await session.execute(
                select(MenuPage).where(
                    MenuPage.tenant_id == ctx.tenant_id,
                    MenuPage.menu_no == menu.menu_no,
                    MenuPage.screen_no == body.screen_no,
                )
            )
        ).scalar_one_or_none()

        occupant = (
            await session.execute(
                select(MenuPage).where(
                    MenuPage.tenant_id == ctx.tenant_id,
                    MenuPage.menu_no == menu.menu_no,
                    MenuPage.pos_x == body.pos_x,
                    MenuPage.pos_y == body.pos_y,
                    MenuPage.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if occupant is not None and (
            existing is None or occupant.id != existing.id
        ):
            if existing is None:
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    f"that tile already holds page {occupant.screen_no}",
                )
            # Moving an already-placed page onto another: swap, same as the
            # button grid, for the same reason.
            occupant.pos_x, occupant.pos_y = existing.pos_x, existing.pos_y
            await _bump_menu(session, ctx.tenant_id, occupant)

        if existing is not None:
            existing.pos_x, existing.pos_y = body.pos_x, body.pos_y
            existing.is_deleted = False
            existing.is_active = True
            page = existing
        else:
            page = MenuPage(
                tenant_id=ctx.tenant_id,
                branch_id=screen.branch_id,
                menu_no=menu.menu_no,
                screen_no=body.screen_no,
                pos_x=body.pos_x,
                pos_y=body.pos_y,
                sort_order=(body.pos_y - 1) * 100 + body.pos_x,
                server_version=0,
            )
            session.add(page)
        await _bump_menu(session, ctx.tenant_id, page)
        await session.flush()

        buttons = (
            await session.execute(
                select(func.count(MenuButton.id)).where(
                    MenuButton.tenant_id == ctx.tenant_id,
                    MenuButton.menu_id == body.screen_no,
                    MenuButton.is_deleted.is_(False),
                )
            )
        ).scalar() or 0

    return OfficeMenuPageOut(
        id=page.id, screen_no=page.screen_no, name=screen.name,
        pos_x=page.pos_x, pos_y=page.pos_y,
        fore_color=screen.fore_color, back_color=screen.back_color,
        button_count=buttons, is_active=screen.is_active,
    )


@router.delete("/menu-pages/{page_id}", status_code=204)
async def remove_menu_page(
    page_id: uuid.UUID,
    ctx: OfficeContext = OfficeDep,
) -> None:
    """Take a page off a menu. The page and its buttons survive — this only
    removes the tile that reaches it."""
    async with tenant_session(ctx.tenant_id) as session:
        page = (
            await session.execute(
                select(MenuPage).where(
                    MenuPage.id == page_id,
                    MenuPage.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if page is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such tile")
        page.is_deleted = True
        await _bump_menu(session, ctx.tenant_id, page)


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
                select(MenuButton, Product, ProductImage)
                .join(
                    Product,
                    (Product.prodnum == MenuButton.prodnum)
                    & (Product.tenant_id == MenuButton.tenant_id),
                    isouter=True,
                )
                # Joined rather than fetched per cell: a thirty-button page
                # would otherwise be thirty round trips before the editor
                # could say which buttons have a picture.
                .join(
                    ProductImage,
                    (ProductImage.prodnum == MenuButton.prodnum)
                    & (ProductImage.tenant_id == MenuButton.tenant_id)
                    & (ProductImage.is_deleted.is_(False)),
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
            has_image=img is not None,
            image_version=img.server_version if img else 0,
        )
        for b, p, img in rows
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
# Floor plan
# --------------------------------------------------------------------------
# A restaurant is not one room. Ground floor, first floor, terrace, family,
# singles, smoking and non-smoking are different areas with different tables,
# and a waiter picks the area before the table. The migration can only produce
# what PixelPoint held — one section per revenue centre — so the areas a
# customer actually works in are set up here.


async def _tables_in_use(session, tenant_id: uuid.UUID) -> set[uuid.UUID]:
    """Tables with somebody sitting at them, including merged halves."""
    open_sessions = list(
        (
            await session.execute(
                select(TableSession).where(
                    TableSession.tenant_id == tenant_id,
                    TableSession.status == "open",
                )
            )
        )
        .scalars()
        .all()
    )
    busy = {s.table_id for s in open_sessions}
    if open_sessions:
        merged = (
            await session.execute(
                select(SessionTable.table_id).where(
                    SessionTable.tenant_id == tenant_id,
                    SessionTable.released_at.is_(None),
                )
            )
        ).scalars().all()
        busy.update(merged)
    return busy


@router.get("/floor-sections", response_model=list[OfficeFloorSectionOut])
async def list_floor_sections(
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeFloorSectionOut]:
    async with tenant_session(ctx.tenant_id) as session:
        sections = list(
            (
                await session.execute(
                    select(FloorSection)
                    .where(
                        FloorSection.tenant_id == ctx.tenant_id,
                        FloorSection.is_deleted.is_(False),
                    )
                    .order_by(FloorSection.sort_order, FloorSection.name)
                )
            )
            .scalars()
            .all()
        )
        counts = dict(
            (
                await session.execute(
                    select(
                        DiningTable.section_id,
                        func.count(DiningTable.id),
                    )
                    .where(
                        DiningTable.tenant_id == ctx.tenant_id,
                        DiningTable.is_deleted.is_(False),
                        DiningTable.is_active.is_(True),
                    )
                    .group_by(DiningTable.section_id)
                )
            ).all()
        )
        seats = dict(
            (
                await session.execute(
                    select(
                        DiningTable.section_id,
                        func.sum(DiningTable.seats),
                    )
                    .where(
                        DiningTable.tenant_id == ctx.tenant_id,
                        DiningTable.is_deleted.is_(False),
                        DiningTable.is_active.is_(True),
                    )
                    .group_by(DiningTable.section_id)
                )
            ).all()
        )

    return [
        OfficeFloorSectionOut(
            id=s.id, code=s.code, name=s.name, name_ar=s.name_ar,
            sort_order=s.sort_order, is_active=s.is_active,
            table_count=int(counts.get(s.id, 0)),
            seat_count=int(seats.get(s.id, 0) or 0),
        )
        for s in sections
    ]


@router.post("/floor-sections", response_model=OfficeFloorSectionOut,
             status_code=201)
async def create_floor_section(
    body: OfficeFloorSectionCreate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeFloorSectionOut:
    async with tenant_session(ctx.tenant_id) as session:
        branch = (
            await session.execute(
                select(Branch.id).where(Branch.tenant_id == ctx.tenant_id)
            )
        ).scalars().first()
        if branch is None:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST, "this tenant has no branch yet"
            )

        clash = (
            await session.execute(
                select(FloorSection).where(
                    FloorSection.tenant_id == ctx.tenant_id,
                    FloorSection.branch_id == branch,
                    func.lower(FloorSection.code) == body.code.strip().lower(),
                )
            )
        ).scalar_one_or_none()
        if clash is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"code {body.code} is already {clash.name}",
            )

        area = FloorSection(
            tenant_id=ctx.tenant_id,
            branch_id=branch,
            code=body.code.strip(),
            name=body.name.strip(),
            name_ar=body.name_ar,
            sort_order=body.sort_order,
            server_version=await _next_catalog_version(session, ctx.tenant_id),
        )
        session.add(area)
        await session.flush()

    return OfficeFloorSectionOut(
        id=area.id, code=area.code, name=area.name, name_ar=area.name_ar,
        sort_order=area.sort_order, is_active=area.is_active,
    )


@router.patch("/floor-sections/{section_id}",
              response_model=OfficeFloorSectionOut)
async def update_floor_section(
    section_id: uuid.UUID,
    body: OfficeFloorSectionUpdate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeFloorSectionOut:
    fields = body.model_dump(exclude_unset=True)
    if not fields:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "nothing to change")

    async with tenant_session(ctx.tenant_id) as session:
        area = (
            await session.execute(
                select(FloorSection).where(
                    FloorSection.id == section_id,
                    FloorSection.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if area is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such area")

        count = (
            await session.execute(
                select(func.count(DiningTable.id)).where(
                    DiningTable.tenant_id == ctx.tenant_id,
                    DiningTable.section_id == section_id,
                    DiningTable.is_deleted.is_(False),
                    DiningTable.is_active.is_(True),
                )
            )
        ).scalar() or 0

        # Closing an area with tables still in it would take them off every
        # till while leaving them seated in the database. Empty it first.
        if fields.get("is_active") is False and count:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"{area.name} still has {count} tables in service; move them "
                "to another area or take them out of service first",
            )

        for key, value in fields.items():
            setattr(area, key, value)
        area.server_version = await _next_catalog_version(session, ctx.tenant_id)
        await session.flush()

    return OfficeFloorSectionOut(
        id=area.id, code=area.code, name=area.name, name_ar=area.name_ar,
        sort_order=area.sort_order, is_active=area.is_active,
        table_count=int(count),
    )


@router.get("/tables", response_model=list[OfficeTableOut])
async def list_office_tables(
    section_id: uuid.UUID | None = None,
    include_inactive: bool = Query(
        False, description="the imported floor carries tables nobody uses"
    ),
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeTableOut]:
    async with tenant_session(ctx.tenant_id) as session:
        stmt = select(DiningTable).where(
            DiningTable.tenant_id == ctx.tenant_id,
            DiningTable.is_deleted.is_(False),
        )
        if section_id is not None:
            stmt = stmt.where(DiningTable.section_id == section_id)
        if not include_inactive:
            stmt = stmt.where(DiningTable.is_active.is_(True))
        rows = list(
            (await session.execute(stmt.order_by(DiningTable.table_no)))
            .scalars()
            .all()
        )
        busy = await _tables_in_use(session, ctx.tenant_id)

    return [
        OfficeTableOut.model_validate(t).model_copy(
            update={"in_use": t.id in busy}
        )
        for t in rows
    ]


@router.post("/tables", response_model=OfficeTableOut, status_code=201)
async def create_table(
    body: OfficeTableCreate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeTableOut:
    async with tenant_session(ctx.tenant_id) as session:
        area = (
            await session.execute(
                select(FloorSection).where(
                    FloorSection.id == body.section_id,
                    FloorSection.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if area is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such area")

        clash = (
            await session.execute(
                select(DiningTable).where(
                    DiningTable.tenant_id == ctx.tenant_id,
                    DiningTable.branch_id == area.branch_id,
                    DiningTable.table_no == body.table_no,
                    DiningTable.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if clash is not None:
            # Table numbers are how staff and receipts refer to a table; two
            # of them is a bill nobody can place.
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"table {body.table_no} already exists in this branch",
            )

        table = DiningTable(
            tenant_id=ctx.tenant_id,
            branch_id=area.branch_id,
            server_version=await _next_catalog_version(session, ctx.tenant_id),
            **body.model_dump(),
        )
        session.add(table)
        await session.flush()
        out = OfficeTableOut.model_validate(table)

    return out


@router.patch("/tables/{table_id}", response_model=OfficeTableOut)
async def update_table(
    table_id: uuid.UUID,
    body: OfficeTableUpdate,
    ctx: OfficeContext = OfficeDep,
) -> OfficeTableOut:
    fields = body.model_dump(exclude_unset=True)
    if not fields:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "nothing to change")

    async with tenant_session(ctx.tenant_id) as session:
        table = (
            await session.execute(
                select(DiningTable).where(
                    DiningTable.id == table_id,
                    DiningTable.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if table is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such table")

        busy = await _tables_in_use(session, ctx.tenant_id)
        moving = {"section_id", "pos_x", "pos_y", "is_active"} & fields.keys()
        if table.id in busy and moving:
            # Somebody is eating at it. Moving it to another area or taking it
            # out of service under them loses the till's grip on their bill.
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"table {table.table_no} is in use; settle it first",
            )

        if "section_id" in fields:
            area = (
                await session.execute(
                    select(FloorSection).where(
                        FloorSection.id == fields["section_id"],
                        FloorSection.tenant_id == ctx.tenant_id,
                    )
                )
            ).scalar_one_or_none()
            if area is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "no such area")

        for key, value in fields.items():
            setattr(table, key, value)
        table.server_version = await _next_catalog_version(session, ctx.tenant_id)
        await session.flush()
        out = OfficeTableOut.model_validate(table).model_copy(
            update={"in_use": table.id in busy}
        )

    return out


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


# --------------------------------------------------------------------------
# Button pictures
#
# A picture on a till button is read faster than a name, which is the whole
# point of one: staff on a busy counter find an item by sight. So it has to be
# legible at the size a tile actually draws — and a tile is square, 84 to 150
# logical pixels, which is up to ~450 physical pixels on a tablet.
#
# The browser crops and resizes before upload. That keeps a native image
# library out of the deployment, and it is also the only place a human can say
# which part of a photograph matters — a server-side centre crop would cut the
# top off half of them.
# --------------------------------------------------------------------------

# What the tile draws at, on the densest screen we sell to. Bigger buys
# nothing a cashier can see and costs every device the download.
IMAGE_IDEAL_PX = 512
# Below this a picture is visibly soft on a tile, so the browser warns.
IMAGE_MIN_PX = 256
# A ceiling, not a target: an upload this big is a mistake somewhere.
IMAGE_MAX_PX = 1024
# ~90 KB. A 512px JPEG of food lands around 50-70 KB, and 560 products would
# be ~35 MB of catalog if every one had a picture — which is why the catalog
# ships them a few rows at a time.
IMAGE_MAX_BYTES = 90_000
IMAGE_FORMATS = ["image/jpeg", "image/png", "image/webp"]

_MAGIC = {
    "image/jpeg": (b"\xff\xd8\xff",),
    "image/png": (b"\x89PNG\r\n\x1a\n",),
    "image/webp": (b"RIFF",),
}


def _png_size(data: bytes) -> tuple[int, int] | None:
    # IHDR is always the first chunk: 8 byte signature, 4 length, 4 type.
    if len(data) < 24 or data[12:16] != b"IHDR":
        return None
    return (
        int.from_bytes(data[16:20], "big"),
        int.from_bytes(data[20:24], "big"),
    )


def _jpeg_size(data: bytes) -> tuple[int, int] | None:
    """Walk the markers to the frame header.

    Worth doing rather than trusting the browser's word: the row says what the
    server actually holds, and a lie there is the kind that surfaces months
    later as a tile that draws wrong on one device.
    """
    i = 2
    end = len(data)
    while i + 9 < end:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        # Standalone markers carry no length.
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = int.from_bytes(data[i + 2:i + 4], "big")
        # SOF0..SOF15, excluding the four that are not frame headers.
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            return (
                int.from_bytes(data[i + 7:i + 9], "big"),
                int.from_bytes(data[i + 5:i + 7], "big"),
            )
        i += 2 + length
    return None


def _webp_size(data: bytes) -> tuple[int, int] | None:
    if len(data) < 30 or data[8:12] != b"WEBP":
        return None
    kind = data[12:16]
    if kind == b"VP8X":
        return (
            int.from_bytes(data[24:27], "little") + 1,
            int.from_bytes(data[27:30], "little") + 1,
        )
    if kind == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
    if kind == b"VP8 ":
        return (
            int.from_bytes(data[26:28], "little") & 0x3FFF,
            int.from_bytes(data[28:30], "little") & 0x3FFF,
        )
    return None


def _measure(mime: str, data: bytes) -> tuple[int, int]:
    """The picture's real size, or a 400 saying it is not what it claims."""
    reader = {
        "image/png": _png_size,
        "image/jpeg": _jpeg_size,
        "image/webp": _webp_size,
    }[mime]
    size = reader(data)
    if size is None or size[0] <= 0 or size[1] <= 0:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"that file is not readable as {mime}",
        )
    return size


@router.get("/image-rules", response_model=ImageRules)
async def image_rules(ctx: OfficeContext = OfficeDep) -> ImageRules:
    """What may be uploaded — the page shows this rather than repeating it."""
    return ImageRules(
        ideal_px=IMAGE_IDEAL_PX,
        min_px=IMAGE_MIN_PX,
        max_px=IMAGE_MAX_PX,
        max_bytes=IMAGE_MAX_BYTES,
        formats=IMAGE_FORMATS,
    )


@router.get("/products/{prodnum}/image")
async def get_product_image(
    prodnum: int,
    ctx: OfficeContext = OfficeDep,
) -> Response:
    """The bytes, for the editor to draw.

    Served as an image rather than base64 in a list so a page of thirty
    buttons is thirty cacheable requests instead of a megabyte of JSON before
    anything appears.
    """
    async with tenant_session(ctx.tenant_id) as session:
        row = (
            await session.execute(
                select(ProductImage).where(
                    ProductImage.tenant_id == ctx.tenant_id,
                    ProductImage.prodnum == prodnum,
                    ProductImage.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no image on that product")
    return Response(
        content=row.data,
        media_type=row.mime,
        # Keyed by the catalog version in the URL, so a replaced picture is a
        # different URL and the old one may be cached hard.
        headers={"Cache-Control": "private, max-age=86400"},
    )


@router.put("/products/{prodnum}/image", response_model=OfficeProductOut)
async def set_product_image(
    prodnum: int,
    body: ProductImageIn,
    ctx: OfficeContext = OfficeDep,
) -> OfficeProductOut:
    """Put a picture on a product's till button.

    Replacing is an update to the same row, so a device sees one version
    change rather than a tombstone and an insert — and never holds two
    pictures for one button while a pull is halfway through.
    """
    if body.mime not in IMAGE_FORMATS:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"{body.mime} is not one of {', '.join(IMAGE_FORMATS)}",
        )
    try:
        data = b64decode(body.data_b64, validate=True)
    except (BinasciiError, ValueError):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "the image is not valid base64")
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "the image is empty")
    if len(data) > IMAGE_MAX_BYTES:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"the image is {len(data) // 1024} KB; the limit is "
            f"{IMAGE_MAX_BYTES // 1024} KB — crop it smaller or save it at "
            f"lower quality",
        )
    if not any(data.startswith(m) for m in _MAGIC[body.mime]):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"the bytes are not a {body.mime.split('/')[1].upper()} file",
        )
    width, height = _measure(body.mime, data)
    if width > IMAGE_MAX_PX or height > IMAGE_MAX_PX:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"{width}x{height} is larger than the {IMAGE_MAX_PX}px limit",
        )

    async with tenant_session(ctx.tenant_id) as session:
        product = (
            await session.execute(
                select(Product).where(
                    Product.tenant_id == ctx.tenant_id,
                    Product.prodnum == prodnum,
                )
            )
        ).scalar_one_or_none()
        if product is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such product")

        version = await _next_catalog_version(session, ctx.tenant_id)
        row = (
            await session.execute(
                select(ProductImage).where(
                    ProductImage.tenant_id == ctx.tenant_id,
                    ProductImage.prodnum == prodnum,
                )
            )
        ).scalar_one_or_none()
        if row is None:
            row = ProductImage(tenant_id=ctx.tenant_id, prodnum=prodnum)
            session.add(row)
        row.mime = body.mime
        row.data = data
        row.width = width
        row.height = height
        row.byte_size = len(data)
        row.is_deleted = False
        row.server_version = version
        await session.flush()
        return _product_out(product, image=row)


@router.delete("/products/{prodnum}/image", response_model=OfficeProductOut)
async def clear_product_image(
    prodnum: int,
    ctx: OfficeContext = OfficeDep,
) -> OfficeProductOut:
    """Take the picture off the button.

    The row stays as a tombstone with its bytes dropped: a device has to be
    told the picture went, and a deleted row cannot tell it anything.
    """
    async with tenant_session(ctx.tenant_id) as session:
        product = (
            await session.execute(
                select(Product).where(
                    Product.tenant_id == ctx.tenant_id,
                    Product.prodnum == prodnum,
                )
            )
        ).scalar_one_or_none()
        if product is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such product")

        row = (
            await session.execute(
                select(ProductImage).where(
                    ProductImage.tenant_id == ctx.tenant_id,
                    ProductImage.prodnum == prodnum,
                )
            )
        ).scalar_one_or_none()
        if row is not None and not row.is_deleted:
            row.is_deleted = True
            row.data = b""
            row.byte_size = 0
            row.server_version = await _next_catalog_version(
                session, ctx.tenant_id
            )
            await session.flush()
        return _product_out(product, image=row)


@router.post("/floor-sections/{section_id}/tidy",
             response_model=list[OfficeTableOut])
async def tidy_floor_section(
    section_id: uuid.UUID,
    ctx: OfficeContext = OfficeDep,
) -> list[OfficeTableOut]:
    """Close up the empty rows and columns in an area's plan.

    PixelPoint stored table positions on a fine canvas — this customer's five
    tables in Section 1001 sit at x = 0, 5, 10, 20 and 25 — because it drew
    them free-standing at whatever size each one was. The till and the back
    office now lay tables out on the same square grid the menu uses, one table
    per square, and on that grid those five tables are five squares in
    twenty-six columns of nothing.

    This maps the distinct positions onto consecutive ones, so the plan keeps
    the order and the shape a manager arranged and loses only the gaps. It is
    deliberately an action somebody asks for rather than something that
    happens on its own: it moves furniture, and a floor plan that rearranges
    itself is one nobody trusts.

    Retired tables move with the rest — they are still on the plan when the
    manager shows them.
    """
    async with tenant_session(ctx.tenant_id) as session:
        area = (
            await session.execute(
                select(FloorSection).where(
                    FloorSection.id == section_id,
                    FloorSection.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if area is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such area")

        tables = list(
            (
                await session.execute(
                    select(DiningTable).where(
                        DiningTable.tenant_id == ctx.tenant_id,
                        DiningTable.section_id == section_id,
                        DiningTable.is_deleted.is_(False),
                    )
                )
            )
            .scalars()
            .all()
        )
        if not tables:
            return []

        columns = {x: i for i, x in
                   enumerate(sorted({t.pos_x or 0 for t in tables}))}
        rows = {y: i for i, y in
                enumerate(sorted({t.pos_y or 0 for t in tables}))}

        moved = 0
        version = await _next_catalog_version(session, ctx.tenant_id)
        for table in tables:
            nx, ny = columns[table.pos_x or 0], rows[table.pos_y or 0]
            if (table.pos_x, table.pos_y) == (nx, ny):
                continue
            table.pos_x, table.pos_y = nx, ny
            # Only what moved changes version: a device pulling a delta should
            # not be sent the whole room because two tables shifted.
            table.server_version = version
            moved += 1
        await session.flush()

        # Two tables can share a position once the gaps close — they were
        # apart on the old canvas and land on the same square now. Spread the
        # duplicates along the row rather than stacking them, because a table
        # hidden underneath another is one nobody can seat.
        taken: set[tuple[int, int]] = set()
        for table in sorted(tables, key=lambda t: (t.pos_y or 0, t.pos_x or 0,
                                                   t.table_no)):
            spot = (table.pos_x or 0, table.pos_y or 0)
            while spot in taken:
                spot = (spot[0] + 1, spot[1])
            if spot != (table.pos_x, table.pos_y):
                table.pos_x, table.pos_y = spot
                table.server_version = version
                moved += 1
            taken.add(spot)
        await session.flush()

        rows_out = sorted(tables, key=lambda t: (t.pos_y or 0, t.pos_x or 0))
        busy = await _tables_in_use(session, ctx.tenant_id)

    return [
        OfficeTableOut.model_validate(t).model_copy(
            update={"in_use": t.id in busy}
        )
        for t in rows_out
    ]
