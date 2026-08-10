"""SQLAlchemy models — the single source of truth for the database schema.

Migrations are generated from this file (`alembic revision --autogenerate`), so
a column added here reaches the database through a migration and nowhere else.
What the ORM cannot express — Row Level Security policies, CHECK constraints,
the non-superuser application role — lives in hand-written migration steps.

This used to mirror a separate hand-maintained `docs/backend_schema.sql`. The
two drifted apart, and the mismatch only surfaced when PostgreSQL rejected an
insert. There is now one definition, and `tests/test_schema_drift.py` checks it
against the live database.

Money is BigInteger halalas everywhere. Never Float: a tax invoice that is off
by a halala is wrong, and binary floating point will eventually make it so.
"""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy import func
from sqlalchemy import text as sa_text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base

# Defaults are declared server-side as well as in Python. A `default=` alone
# lives only in SQLAlchemy, so anything writing to the database another way —
# the catalog importer, provisioning scripts, the ERP worker, a DBA at a psql
# prompt — inserts NULL into a NOT NULL column and fails. The database should
# be able to state its own defaults.
TRUE = sa_text("true")
FALSE = sa_text("false")

# JSONB on PostgreSQL, plain JSON on SQLite. Declared once so the models and
# docs/backend_schema.sql cannot disagree about it again — they already did, and
# it only surfaced when the suite was first run against a real PostgreSQL.
JsonCol = JSON().with_variant(JSONB, "postgresql")


def _uuid_pk() -> Mapped[uuid.UUID]:
    return mapped_column(Uuid, primary_key=True, default=uuid.uuid4)


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


# --------------------------------------------------------------------------
# Tenancy
# --------------------------------------------------------------------------

class Tenant(Base):
    __tablename__ = "tenant"

    id: Mapped[uuid.UUID] = _uuid_pk()
    name: Mapped[str] = mapped_column(Text)
    slug: Mapped[str] = mapped_column(String(64), unique=True)
    # 'standalone' -> we own catalog and ZATCA reporting
    # 'erp'        -> the ERP is master for catalog and reports to ZATCA
    mode: Mapped[str] = mapped_column(String(16), default="standalone", server_default=sa_text("'standalone'"))
    erp_base_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    erp_credentials: Mapped[dict | None] = mapped_column(JsonCol, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_now, server_default=func.now()
    )


class Company(Base):
    """A legal entity. Owns the VAT registration ZATCA EGS units hang off."""

    __tablename__ = "company"
    __table_args__ = (UniqueConstraint("tenant_id", "vat_number"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    name: Mapped[str] = mapped_column(Text)
    name_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    vat_number: Mapped[str] = mapped_column(String(15))
    cr_number: Mapped[str | None] = mapped_column(String(32), nullable=True)
    # Not nullable: ZATCA requires a structured seller address on every invoice,
    # so a company without one cannot legally trade.
    address: Mapped[dict] = mapped_column(JsonCol)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)


class Branch(Base):
    __tablename__ = "branch"
    __table_args__ = (UniqueConstraint("tenant_id", "code"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("company.id"), index=True)
    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(Text)
    name_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    address: Mapped[dict | None] = mapped_column(JsonCol, nullable=True)
    timezone: Mapped[str] = mapped_column(String(64), default="Asia/Riyadh", server_default=sa_text("'Asia/Riyadh'"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)


class Device(Base):
    """A tablet. Each one is its own ZATCA EGS unit."""

    __tablename__ = "device"

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    device_uuid: Mapped[str] = mapped_column(String(64), unique=True)
    label: Mapped[str] = mapped_column(Text)
    receipt_prefix: Mapped[str] = mapped_column(String(8))
    is_hub: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    # What this screen does: a till ('pos'), a kitchen display ('kds') or a
    # customer display ('cds'). KDS and CDS devices authenticate exactly like
    # tills but never create sales; a kds device may pin itself to one station.
    role: Mapped[str] = mapped_column(
        String(8), default="pos", server_default=sa_text("'pos'")
    )
    kds_station_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    platform: Mapped[str | None] = mapped_column(String(16), nullable=True)
    app_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    egs_serial: Mapped[str | None] = mapped_column(Text, nullable=True)
    csid: Mapped[str | None] = mapped_column(Text, nullable=True)
    csid_expires_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    csid_status: Mapped[str] = mapped_column(String(16), default="none", server_default=sa_text("'none'"))
    last_seen_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_icv: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)


class BackOfficeUser(Base):
    """A person who signs into the back office.

    Deliberately NOT the shared `POS_ADMIN_TOKEN`. That token is one secret for
    the whole installation — handing it to a restaurant manager would give them
    every tenant's data. A back-office session is scoped to one tenant by the
    same mechanism device tokens use, so the isolation story is the same
    everywhere.

    Separate from `Employee` on purpose: an employee is a cashier who exists in
    the catalog and rings sales on a tablet with a numeric PIN. These are people
    with a password and a browser, and the two sets barely overlap.
    """

    __tablename__ = "back_office_user"

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    # Globally unique, NOT unique-per-tenant. Sign-in happens before any tenant
    # is known — there is nothing to scope the lookup by — so a duplicate
    # address across two tenants would make the login query ambiguous and the
    # account unreachable. The cost is that one person cannot hold accounts in
    # two tenants under the same address; they need a second address, which is
    # the rarer problem.
    email: Mapped[str] = mapped_column(String(320), unique=True)
    name: Mapped[str] = mapped_column(Text)
    # scrypt, salted per user. Never a bare hash: these are chosen passwords.
    password_hash: Mapped[str] = mapped_column(Text)
    # 'owner' may manage users and every branch; 'manager' works the day to day.
    role: Mapped[str] = mapped_column(
        String(16), default="manager", server_default=sa_text("'manager'")
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    last_login_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_now, server_default=func.now()
    )


class Licence(Base):
    __tablename__ = "licence"

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    plan: Mapped[str] = mapped_column(String(32))
    max_devices: Mapped[int] = mapped_column(Integer)
    max_branches: Mapped[int] = mapped_column(Integer)
    starts_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    # Deliberate: an expired licence must not kill a POS mid-service. The device
    # keeps selling through the grace window while the account is chased.
    grace_days: Mapped[int] = mapped_column(Integer, default=7, server_default=sa_text("7"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)


# --------------------------------------------------------------------------
# Catalog — pulled by devices, never written by them
# --------------------------------------------------------------------------

class Product(Base):
    __tablename__ = "product"
    __table_args__ = (
        UniqueConstraint("tenant_id", "branch_id", "prodnum"),
        Index("ix_product_sync", "tenant_id", "branch_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("branch.id"), nullable=True
    )
    prodnum: Mapped[int] = mapped_column(Integer)
    descript: Mapped[str] = mapped_column(Text)
    descript_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    print_des: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Price tiers A–J, all VAT-inclusive halalas. Which one applies is decided
    # by the sale type: walk-in trade pays A, delivery aggregators pay B (their
    # commission is the difference), staff meals and press comps pay J, which is
    # zero. All ten are populated in the source catalog.
    price_a: Mapped[int] = mapped_column(BigInteger)
    price_b: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_c: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_d: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_e: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_f: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_g: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_h: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_i: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    price_j: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    # -> ReportCategory.report_no. Nullable because a product may reference a
    # category that no longer exists in the source.
    report_no: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)
    prodtype: Mapped[int | None] = mapped_column(Integer, nullable=True)
    tax_applies: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_weighed: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    manual_price: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    is_modifier: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    # Kitchen routing bitmask carried over from PixelPoint's PRINTLOC: bit n set
    # means the item goes to the station on printer port n (2=Expo, 3=Grill,
    # 4=Shawarma, 5=DT at the first customer). 0 = no kitchen ticket.
    print_loc: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    ref_code: Mapped[str | None] = mapped_column(String(32), nullable=True)
    unit_des: Mapped[str | None] = mapped_column(String(16), nullable=True)
    # ---- how the button looks on a till ---------------------------------
    # The label a cashier reads, newline-separated. Deliberately not the
    # description: 308 of 560 imported products differ, because a tile has to
    # fit "(BSP) broasted / strip pizza" and the full name does not.
    button_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    # '#RRGGBB', or NULL meaning "use the theme". The imported menu has 28
    # distinct backgrounds — a deliberate colour-coded layout that staff
    # navigate by sight. Dropping it would make a familiar menu unfamiliar on
    # the first day of a migration, which is the worst possible day for that.
    fore_color: Mapped[str | None] = mapped_column(String(7), nullable=True)
    back_color: Mapped[str | None] = mapped_column(String(7), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class ReportCategory(Base):
    """PixelPoint's "Report Cat" — what sales reports group by.

    Distinct from a menu screen: a screen is where a button sits on a till, a
    report category is what the item IS. An item can appear on several screens
    and belongs to exactly one category.

    Missed on the first migration pass, which took `Product.PRODTYPE` for the
    category — a different column that is 0 on 536 of 560 products. The real
    link is `Product.REPORTNO`, and without it the back office had nothing to
    group or filter a 560-product menu by.
    """

    __tablename__ = "report_category"
    __table_args__ = (
        UniqueConstraint("tenant_id", "company_id", "report_no"),
        Index("ix_report_category_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("company.id"), nullable=True
    )
    report_no: Mapped[int] = mapped_column(Integer)
    name: Mapped[str] = mapped_column(Text)
    name_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The category's own kitchen-routing default. Products carry their own
    # print_loc and that is what actually routes; this records what the
    # category intended, which is useful when a product looks misrouted.
    default_print_loc: Mapped[int] = mapped_column(
        Integer, default=0, server_default=sa_text("0")
    )
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class Question(Base):
    """A meal-deal prompt: "1 DRINKS", "TABAKAT 6 GRILL".

    A product can ask up to five of these, and each offers choices that are
    themselves products. 91 imported products ask at least one. Without them a
    meal rings with nothing chosen and the kitchen is told to make an empty
    box, so this is not a nicety — it is what makes those items sellable.
    """

    __tablename__ = "question"
    __table_args__ = (
        UniqueConstraint("tenant_id", "company_id", "question_no"),
        Index("ix_question_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("company.id"), nullable=True
    )
    question_no: Mapped[int] = mapped_column(Integer)
    prompt: Mapped[str] = mapped_column(Text)
    prompt_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Whether the sale can proceed without an answer.
    is_required: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    # How many to pick. Usually one; the Tabakat platters ask for six.
    pick_count: Mapped[int] = mapped_column(Integer, default=1, server_default=sa_text("1"))
    # Whether the same choice may be picked more than once.
    allow_repeats: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    free_choices: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class QuestionChoice(Base):
    """One answer to a [Question] — itself a product."""

    __tablename__ = "question_choice"
    __table_args__ = (
        UniqueConstraint("tenant_id", "question_no", "prodnum"),
        Index("ix_question_choice_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("company.id"), nullable=True
    )
    question_no: Mapped[int] = mapped_column(Integer)
    prodnum: Mapped[int] = mapped_column(Integer)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    # PixelPoint's PriceMode, carried through raw. The import uses two values —
    # 0 with no fixed price (100 rows) and 11 with a fixed price of zero (19) —
    # and both come to the same thing: the choice is included in the meal, not
    # charged. So the till prices a choice at `fixed_price` when one is set and
    # zero otherwise, and does not try to interpret the mode. A mode meaning
    # "charge the tier price" does not appear in this data, and guessing at one
    # would invent behaviour that silently double-charges a meal.
    price_mode: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    fixed_price: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    default_qty: Mapped[int] = mapped_column(Integer, default=1, server_default=sa_text("1"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class ProductQuestion(Base):
    """Which prompts a product asks, and in what order.

    A join rather than five columns on Product: the slots are ordered and
    sparse, and "question 3 of this product" is not a property of the product
    so much as a position in a list.
    """

    __tablename__ = "product_question"
    __table_args__ = (
        UniqueConstraint("tenant_id", "prodnum", "slot"),
        Index("ix_product_question_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    prodnum: Mapped[int] = mapped_column(Integer, index=True)
    question_no: Mapped[int] = mapped_column(Integer)
    # 1-5, the order the prompts are asked in.
    slot: Mapped[int] = mapped_column(Integer)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class ComboItem(Base):
    """Something a combo always includes, with nothing to choose.

    "Bucket BROSTED Regular" comes with a litre, a garlic and a hummos. The
    customer is not asked; the kitchen still has to be told.
    """

    __tablename__ = "combo_item"
    __table_args__ = (
        Index("ix_combo_item_parent", "tenant_id", "parent_prodnum"),
        Index("ix_combo_item_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("company.id"), nullable=True
    )
    parent_prodnum: Mapped[int] = mapped_column(Integer)
    prodnum: Mapped[int] = mapped_column(Integer)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    price_mode: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    fixed_price: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    print_it: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class Menu(Base):
    """A whole menu — the level above order pages.

    "Default Menu" is the grid of coloured page tiles a cashier lands on:
    Shawarma, Grill, Appetizer, Beverage and the rest. It is how they get
    anywhere, and it is what makes a migrated till feel like the one they
    already knew.

    Missed on the first migration pass, which imported the 64 order pages but
    not the menus that arrange them — so the till could only show a flat strip
    of every page, which is not a menu anyone learned.
    """

    __tablename__ = "menu"
    __table_args__ = (
        UniqueConstraint("tenant_id", "branch_id", "menu_no"),
        Index("ix_menu_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("branch.id"), nullable=True
    )
    menu_no: Mapped[int] = mapped_column(Integer)
    name: Mapped[str] = mapped_column(Text)
    name_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    # PixelPoint's revenue centre. Carried for reference; nothing reads it yet.
    revenue_centre: Mapped[int | None] = mapped_column(Integer, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class MenuPage(Base):
    """Where an order page sits on a menu's grid.

    Deliberately a join rather than a column on MenuScreen: one page appears
    on more than one menu, at a different spot on each. 'Shawarma' is tile
    (1,1) of the Default Menu and may be somewhere else entirely on Kantaka.
    """

    __tablename__ = "menu_page"
    __table_args__ = (
        UniqueConstraint("tenant_id", "menu_no", "screen_no"),
        Index("ix_menu_page_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("branch.id"), nullable=True
    )
    # -> Menu.menu_no and MenuScreen.menu_id. Business keys rather than row
    # ids, because that is what the device catalog and the imports speak.
    menu_no: Mapped[int] = mapped_column(Integer)
    screen_no: Mapped[int] = mapped_column(Integer)
    pos_x: Mapped[int | None] = mapped_column(Integer, nullable=True)
    pos_y: Mapped[int | None] = mapped_column(Integer, nullable=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class MenuScreen(Base):
    __tablename__ = "menu_screen"
    __table_args__ = (UniqueConstraint("tenant_id", "branch_id", "menu_id"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("branch.id"), nullable=True
    )
    menu_id: Mapped[int] = mapped_column(Integer)
    name: Mapped[str] = mapped_column(Text)
    name_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    buttons_across: Mapped[int | None] = mapped_column(Integer, nullable=True)
    buttons_down: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # The page tile's colours on the menu grid, '#RRGGBB' or NULL for the
    # theme. Same reason as the product buttons: staff reach for a colour.
    fore_color: Mapped[str | None] = mapped_column(String(7), nullable=True)
    back_color: Mapped[str | None] = mapped_column(String(7), nullable=True)
    is_modifier_screen: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class MenuButton(Base):
    __tablename__ = "menu_button"

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    menu_screen_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("menu_screen.id"))
    product_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product.id"), nullable=True
    )
    menu_id: Mapped[int] = mapped_column(Integer)
    prodnum: Mapped[int] = mapped_column(Integer)
    position: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    pos_x: Mapped[int | None] = mapped_column(Integer, nullable=True)
    pos_y: Mapped[int | None] = mapped_column(Integer, nullable=True)
    caption: Mapped[str | None] = mapped_column(Text, nullable=True)
    fore_color: Mapped[int | None] = mapped_column(Integer, nullable=True)
    back_color: Mapped[int | None] = mapped_column(Integer, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class PayMethod(Base):
    __tablename__ = "pay_method"
    __table_args__ = (UniqueConstraint("tenant_id", "company_id", "methodnum"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("company.id"), nullable=True
    )
    methodnum: Mapped[int] = mapped_column(Integer)
    descript: Mapped[str] = mapped_column(Text)
    descript_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    is_cash: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    opens_drawer: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class Staff(Base):
    __tablename__ = "staff"
    __table_args__ = (UniqueConstraint("tenant_id", "branch_id", "empnum"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("branch.id"), nullable=True
    )
    empnum: Mapped[int] = mapped_column(Integer)
    name: Mapped[str] = mapped_column(Text)
    # Nullable: staff migrated from PixelPoint arrive with no credential and
    # must set a PIN before they can log in. See migration/README.md.
    pin_hash: Mapped[str | None] = mapped_column(Text, nullable=True)
    must_set_pin: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    sec_level: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    ref_code: Mapped[str | None] = mapped_column(String(32), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class TaxRate(Base):
    __tablename__ = "tax_rate"

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("company.id"))
    tax_id: Mapped[int] = mapped_column(Integer)
    name: Mapped[str] = mapped_column(String(32))
    percent: Mapped[float] = mapped_column(Numeric(5, 2))
    is_inclusive: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    effective_from: Mapped[dt.date] = mapped_column(Date)
    effective_to: Mapped[dt.date | None] = mapped_column(Date, nullable=True)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


# --------------------------------------------------------------------------
# Sales — pushed by devices, append-only
# --------------------------------------------------------------------------

class Sale(Base):
    __tablename__ = "sale"
    __table_args__ = (
        UniqueConstraint("tenant_id", "branch_id", "receipt_no"),
        # A device's ZATCA chain must be strictly sequential with no reuse.
        UniqueConstraint("device_id", "zatca_icv", name="ux_sale_device_icv"),
        Index("ix_sale_tenant_date", "tenant_id", "business_date"),
        # Partial indexes for the two worker queues. The pending rows are a
        # small, shrinking tail of a table that only grows, so indexing the
        # whole column would cost more to maintain than it saves.
        # postgresql_where is ignored on SQLite, which just builds a full index.
        Index(
            "ix_sale_zatca_todo", "zatca_status",
            postgresql_where=sa_text("zatca_status = 'pending'"),
        ),
        Index(
            "ix_sale_erp_todo", "erp_status",
            postgresql_where=sa_text("erp_status = 'pending'"),
        ),
    )

    sale_uuid: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("company.id"))
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"))
    device_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("device.id"))
    receipt_no: Mapped[str] = mapped_column(String(32))
    opened_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    closed_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    business_date: Mapped[dt.date] = mapped_column(Date)
    table_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    num_guests: Mapped[int] = mapped_column(Integer, default=1, server_default=sa_text("1"))
    sale_type: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    # Customer-facing number called out when the food is ready. Short and
    # resets daily, so it is not unique on its own — scoped to branch and date.
    order_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # The aggregator's own order id. Without it a disputed Keeta or
    # HungerStation order cannot be matched to anything.
    external_ref: Mapped[str | None] = mapped_column(String(64), nullable=True)
    net_total: Mapped[int] = mapped_column(BigInteger)
    tax_total: Mapped[int] = mapped_column(BigInteger)
    final_total: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[str] = mapped_column(String(16), default="closed", server_default=sa_text("'closed'"))

    zatca_uuid: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    zatca_icv: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    zatca_pih: Mapped[str | None] = mapped_column(Text, nullable=True)
    zatca_hash: Mapped[str | None] = mapped_column(Text, nullable=True)
    zatca_qr: Mapped[str | None] = mapped_column(Text, nullable=True)
    zatca_xml: Mapped[str | None] = mapped_column(Text, nullable=True)
    zatca_status: Mapped[str] = mapped_column(String(16), default="pending", server_default=sa_text("'pending'"))
    zatca_reported_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    zatca_error: Mapped[str | None] = mapped_column(Text, nullable=True)

    erp_status: Mapped[str] = mapped_column(String(16), default="pending", server_default=sa_text("'pending'"))
    erp_ref: Mapped[str | None] = mapped_column(Text, nullable=True)
    erp_error: Mapped[str | None] = mapped_column(Text, nullable=True)

    received_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_now, server_default=func.now()
    )

    lines: Mapped[list["SaleLine"]] = relationship(
        back_populates="sale", cascade="all, delete-orphan", lazy="selectin"
    )
    payments: Mapped[list["SalePayment"]] = relationship(
        back_populates="sale", cascade="all, delete-orphan", lazy="selectin"
    )


class SaleLine(Base):
    __tablename__ = "sale_line"

    line_uuid: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    sale_uuid: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("sale.sale_uuid", ondelete="CASCADE"), index=True
    )
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    line_no: Mapped[int] = mapped_column(Integer)
    prodnum: Mapped[int] = mapped_column(Integer)
    # Snapshots: if the product is renamed or repriced tomorrow, this bill must
    # still show what the customer actually bought and paid.
    line_des: Mapped[str] = mapped_column(Text)
    qty: Mapped[float] = mapped_column(Numeric(12, 3))
    unit_price: Mapped[int] = mapped_column(BigInteger)
    discount: Mapped[int] = mapped_column(BigInteger, default=0, server_default=sa_text("0"))
    net_amount: Mapped[int] = mapped_column(BigInteger)
    tax_amount: Mapped[int] = mapped_column(BigInteger)
    line_total: Mapped[int] = mapped_column(BigInteger)
    seat_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # The line this one belongs to: the meal a chosen drink came out of, or an
    # item a combo always includes. Self-referential and nullable — most lines
    # stand alone. No foreign key: lines arrive in one batch from a device and
    # the order within that batch is the device's business, not a constraint
    # worth failing a whole sale over.
    parent_line: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    voided: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)

    sale: Mapped[Sale] = relationship(back_populates="lines")


class SalePayment(Base):
    __tablename__ = "sale_payment"

    payment_uuid: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    sale_uuid: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("sale.sale_uuid", ondelete="CASCADE"), index=True
    )
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    methodnum: Mapped[int] = mapped_column(Integer)
    tender: Mapped[int] = mapped_column(BigInteger)
    change_given: Mapped[int] = mapped_column(BigInteger, default=0, server_default=sa_text("0"))
    amount: Mapped[int] = mapped_column(BigInteger)
    auth_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    card_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    paid_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    voided: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)

    sale: Mapped[Sale] = relationship(back_populates="payments")


# --------------------------------------------------------------------------
# Sale types — how the order reaches the customer
# --------------------------------------------------------------------------

class SalesType(Base):
    """Drive Thru, TakeAway, Dine-In, or a delivery aggregator.

    Carries the **price tier**, which is not cosmetic: at the first customer,
    aggregator orders are charged a different tier than walk-in trade, and the
    difference is the aggregator's commission. Proven against their sales —
    HUMMOS rang at 8.00 on Drive Thru and 9.00 on Keeta, matching PRICEA and
    PRICEB exactly. Charging tier A on an aggregator order gives that margin
    away on every delivery.
    """

    __tablename__ = "sales_type"
    __table_args__ = (
        UniqueConstraint("tenant_id", "company_id", "sale_type_no"),
        Index("ix_sales_type_sync", "tenant_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("company.id"), nullable=True
    )
    sale_type_no: Mapped[int] = mapped_column(Integer)
    descript: Mapped[str] = mapped_column(Text)
    descript_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    # 'a'..'j' — which of the product's price columns this type charges.
    price_tier: Mapped[str] = mapped_column(
        String(1), default="a", server_default=sa_text("'a'")
    )
    # Orders arriving from a third party: Keeta, HungerStation, Jahez, Marsool.
    is_aggregator: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=FALSE
    )
    # Aggregator orders without their reference cannot be reconciled when the
    # platform disputes one. PixelPoint never captured it — 9,641 orders with
    # nothing to match against — so the new POS asks for it.
    requires_external_ref: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=FALSE
    )
    needs_table: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=FALSE
    )
    default_methodnum: Mapped[int | None] = mapped_column(Integer, nullable=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class OrderNumberCounter(Base):
    """Per-branch, per-day customer-facing order numbers.

    A drive-thru hands the customer a number and calls it when the food is up.
    PixelPoint recorded none at all across 31,000 drive-thru orders, so staff
    were matching orders to cars by memory.

    Resets daily so the numbers stay short enough to shout across a kitchen.
    """

    __tablename__ = "order_number_counter"
    __table_args__ = (UniqueConstraint("tenant_id", "branch_id", "business_date"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    business_date: Mapped[dt.date] = mapped_column(Date)
    next_number: Mapped[int] = mapped_column(
        Integer, default=1, server_default=sa_text("1")
    )


# --------------------------------------------------------------------------
# Device provisioning
# --------------------------------------------------------------------------

class EnrolmentCode(Base):
    """A one-time code that turns a fresh tablet into an enrolled device.

    Back office creates the code for a branch; whoever sets the tablet up types
    it in; the tablet redeems it exactly once and receives its JWT. The code is
    the secret — 32 random url-safe bytes — so it is never reused, expires
    quickly, and identifies the tenant on its own.

    This table deliberately has NO row-level-security policy: redemption
    happens before the device has any tenant context, so the lookup must work
    without `app.tenant_id` set. The code column being unguessable is the
    protection; the redeem handler scopes everything else through the normal
    tenant session the moment the code resolves.
    """

    __tablename__ = "enrolment_code"

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"))
    code: Mapped[str] = mapped_column(String(64), unique=True)
    label: Mapped[str] = mapped_column(Text)            # 'Waiter 3', 'Kitchen Grill'
    receipt_prefix: Mapped[str] = mapped_column(String(8))
    role: Mapped[str] = mapped_column(
        String(8), default="pos", server_default=sa_text("'pos'")
    )
    kds_station_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    expires_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_now, server_default=func.now()
    )


# --------------------------------------------------------------------------
# Kitchen display (KDS)
# --------------------------------------------------------------------------
# The old system printed paper tickets to station printers (Expo, Grill,
# Shawarma, DT at the first customer); KDS replaces the printers with screens.
# Tickets are created by the till the moment an order is sent to the kitchen —
# before payment on dine-in, at payment on counter trade — and are deliberately
# separate from `sale`: a kitchen ticket is workflow, a sale is a tax record.

class KitchenStation(Base):
    """A prep station. station_no is the printer port it replaces, so imported
    PRINTLOC bitmasks keep meaning what they always meant."""

    __tablename__ = "kitchen_station"
    __table_args__ = (
        UniqueConstraint("tenant_id", "branch_id", "station_no"),
        Index("ix_kitchen_station_sync", "tenant_id", "branch_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    station_no: Mapped[int] = mapped_column(Integer)
    name: Mapped[str] = mapped_column(Text)
    name_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class KitchenTicket(Base):
    """One order on the kitchen rail.

    The uuid is generated on the till, so creation is idempotent across
    retries the same way sales are. `sale_uuid`/`session_id` tie the ticket
    back to where the order came from without making the kitchen wait for
    either to exist.
    """

    __tablename__ = "kitchen_ticket"
    __table_args__ = (
        Index("ix_kitchen_ticket_rail", "tenant_id", "branch_id", "status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    order_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    sale_type_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    sale_type_name: Mapped[str | None] = mapped_column(Text, nullable=True)
    table_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    external_ref: Mapped[str | None] = mapped_column(String(64), nullable=True)
    sale_uuid: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    session_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    device_uuid: Mapped[str | None] = mapped_column(String(64), nullable=True)
    status: Mapped[str] = mapped_column(
        String(12), default="open", server_default=sa_text("'open'")
    )
    created_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    bumped_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    lines: Mapped[list["KitchenTicketLine"]] = relationship(
        back_populates="ticket", cascade="all, delete-orphan"
    )


class KitchenTicketLine(Base):
    __tablename__ = "kitchen_ticket_line"
    __table_args__ = (Index("ix_kticket_line", "ticket_id", "line_no"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    ticket_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("kitchen_ticket.id", ondelete="CASCADE"), index=True
    )
    line_no: Mapped[int] = mapped_column(Integer)
    prodnum: Mapped[int] = mapped_column(Integer)
    line_des: Mapped[str] = mapped_column(Text)      # snapshot at order time
    qty: Mapped[float] = mapped_column(Numeric(12, 3))
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    seat_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Which station cooks it — resolved from product.print_loc on the till, so
    # the kitchen sees the routing even if the catalog changes afterwards.
    station_no: Mapped[int] = mapped_column(Integer)
    # The line_no on this ticket that this line belongs to. A cook reading
    # "PEPSI" on its own cannot tell which of four open meals it came out of.
    parent_line_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    done: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    voided: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)

    ticket: Mapped[KitchenTicket] = relationship(back_populates="lines")


# --------------------------------------------------------------------------
# Floor plan and table service
# --------------------------------------------------------------------------
# Dine-in is a minority of trade at the first customer — 12% of bills, and most
# of those on a pseudo-table used for counter service. Built as a proper product
# feature all the same, because a restaurant that does run table service cannot
# use a POS that does not.

class FloorSection(Base):
    """A named area of the restaurant — main hall, terrace, family section."""

    __tablename__ = "floor_section"
    __table_args__ = (UniqueConstraint("tenant_id", "branch_id", "code"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(Text)
    name_ar: Mapped[str | None] = mapped_column(Text, nullable=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class DiningTable(Base):
    """One table on the floor plan.

    Geometry is carried here because PixelPoint has none — its TableDrawSetup
    was never populated, so an imported floor plan has to be laid out by the
    importer and then arranged by the customer.
    """

    __tablename__ = "dining_table"
    __table_args__ = (
        UniqueConstraint("tenant_id", "branch_id", "table_no"),
        Index("ix_dining_table_sync", "tenant_id", "branch_id", "server_version"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    section_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("floor_section.id"))
    table_no: Mapped[int] = mapped_column(Integer)
    label: Mapped[str | None] = mapped_column(String(32), nullable=True)
    seats: Mapped[int] = mapped_column(Integer, default=2, server_default=sa_text("2"))
    min_seats: Mapped[int | None] = mapped_column(Integer, nullable=True)
    max_seats: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Floor-plan geometry, in an abstract grid the client scales to its screen.
    pos_x: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    pos_y: Mapped[int] = mapped_column(Integer, default=0, server_default=sa_text("0"))
    width: Mapped[int] = mapped_column(Integer, default=2, server_default=sa_text("2"))
    height: Mapped[int] = mapped_column(Integer, default=2, server_default=sa_text("2"))
    shape: Mapped[str] = mapped_column(
        String(12), default="square", server_default=sa_text("'square'")
    )
    can_reserve: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=TRUE)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)
    server_version: Mapped[int] = mapped_column(BigInteger, index=True)


class TableSession(Base):
    """A table currently in use — the thing an order hangs off.

    While the branch is offline the hub tablet is the authority for who is
    sitting where; this is the shared copy, so the back office can see the floor
    and a tablet that restarts can recover its open tables instead of losing
    them. `sale_uuid` is filled in once the bill is closed and pushed.
    """

    __tablename__ = "table_session"
    __table_args__ = (
        Index("ix_table_session_open", "tenant_id", "branch_id", "status"),
        # A table can hold at most one open session. Two would mean two waiters
        # unknowingly building separate bills for the same customers.
        #
        # The WHERE clause must be given per dialect. With only
        # postgresql_where, SQLite builds a *full* unique index on table_id —
        # which silently means a table can never be seated a second time, and
        # the tablets run on SQLite.
        Index(
            "ux_table_session_one_open", "table_id",
            unique=True,
            postgresql_where=sa_text("status = 'open'"),
            sqlite_where=sa_text("status = 'open'"),
        ),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    table_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("dining_table.id"), index=True)
    device_uuid: Mapped[str | None] = mapped_column(String(64), nullable=True)
    staff_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("staff.id"), nullable=True
    )
    guests: Mapped[int] = mapped_column(Integer, default=1, server_default=sa_text("1"))
    opened_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    closed_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    status: Mapped[str] = mapped_column(
        String(16), default="open", server_default=sa_text("'open'")
    )
    sale_uuid: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)

    lines: Mapped[list["TableSessionLine"]] = relationship(
        back_populates="session", cascade="all, delete-orphan"
    )


class TableSessionLine(Base):
    """An item ordered against a table before the bill is closed.

    Prices are snapshots for the same reason as SaleLine: the bill must show
    what was quoted when the guest ordered, not what the menu says later.
    """

    __tablename__ = "table_session_line"
    __table_args__ = (Index("ix_session_line_session", "session_id", "line_no"),)

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    session_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("table_session.id", ondelete="CASCADE"), index=True
    )
    line_no: Mapped[int] = mapped_column(Integer)
    prodnum: Mapped[int] = mapped_column(Integer)
    line_des: Mapped[str] = mapped_column(Text)
    qty: Mapped[float] = mapped_column(Numeric(12, 3))
    unit_price: Mapped[int] = mapped_column(BigInteger)   # halalas, VAT-inclusive
    seat_no: Mapped[int | None] = mapped_column(Integer, nullable=True)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    sent_to_kitchen: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=FALSE
    )
    ordered_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    voided: Mapped[bool] = mapped_column(Boolean, default=False, server_default=FALSE)

    session: Mapped[TableSession] = relationship(back_populates="lines")


class Reservation(Base):
    """A booking. May name a table or leave it to be assigned on arrival."""

    __tablename__ = "reservation"
    __table_args__ = (
        Index("ix_reservation_when", "tenant_id", "branch_id", "reserved_for"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    tenant_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tenant.id"), index=True)
    branch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("branch.id"), index=True)
    table_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("dining_table.id"), nullable=True
    )
    guest_name: Mapped[str] = mapped_column(Text)
    phone: Mapped[str | None] = mapped_column(String(32), nullable=True)
    party_size: Mapped[int] = mapped_column(Integer)
    reserved_for: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    duration_minutes: Mapped[int] = mapped_column(
        Integer, default=90, server_default=sa_text("90")
    )
    occasion: Mapped[str | None] = mapped_column(String(32), nullable=True)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(
        String(16), default="booked", server_default=sa_text("'booked'")
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_now, server_default=func.now()
    )
