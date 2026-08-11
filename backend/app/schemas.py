"""Request/response models.

Sale payloads are validated hard at the boundary. A device that has been offline
for hours is the only witness to what happened; if its arithmetic disagrees with
itself we want to know at ingest, not when someone reconciles VAT at month end.
"""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import BaseModel, ConfigDict, Field, model_validator


# --------------------------------------------------------------------------
# Catalog (server -> device)
# --------------------------------------------------------------------------

class CatalogItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    server_version: int
    is_deleted: bool


class ProductOut(CatalogItem):
    prodnum: int
    descript: str
    descript_ar: str | None = None
    print_des: str | None = None
    price_a: int
    price_b: int | None = None
    price_c: int | None = None
    price_d: int | None = None
    price_e: int | None = None
    price_f: int | None = None
    price_g: int | None = None
    price_h: int | None = None
    price_i: int | None = None
    price_j: int | None = None
    prodtype: int | None = None
    tax_applies: bool
    is_weighed: bool
    manual_price: bool
    is_modifier: bool
    print_loc: int = 0
    ref_code: str | None = None
    unit_des: str | None = None
    # How the till draws the button. Without these the grid renders every item
    # identically and the imported colour-coded menu is lost on the device
    # even though the back office can see it.
    button_text: str | None = None
    fore_color: str | None = None
    back_color: str | None = None
    is_active: bool


class MenuScreenOut(CatalogItem):
    menu_id: int
    name: str
    name_ar: str | None = None
    sort_order: int
    buttons_across: int | None = None
    buttons_down: int | None = None
    fore_color: str | None = None
    back_color: str | None = None
    is_modifier_screen: bool
    is_active: bool


class MenuOut(CatalogItem):
    """A whole menu — the grid of page tiles a till lands on."""

    menu_no: int
    name: str
    name_ar: str | None = None
    is_active: bool


class MenuPageOut(CatalogItem):
    """Where a page sits on a menu's grid."""

    menu_no: int
    screen_no: int
    pos_x: int | None = None
    pos_y: int | None = None
    sort_order: int
    is_active: bool


class MenuButtonOut(CatalogItem):
    id: uuid.UUID
    menu_id: int
    prodnum: int
    position: int
    pos_x: int | None = None
    pos_y: int | None = None
    caption: str | None = None
    is_active: bool


class PayMethodOut(CatalogItem):
    methodnum: int
    descript: str
    descript_ar: str | None = None
    is_cash: bool
    opens_drawer: bool
    sort_order: int
    is_active: bool


class StaffOut(CatalogItem):
    empnum: int
    name: str
    must_set_pin: bool
    sec_level: int
    is_active: bool
    # pin_hash is deliberately absent — the server never ships credentials
    # down to a device, not even hashed.


class TaxRateOut(CatalogItem):
    tax_id: int
    name: str
    percent: float
    is_inclusive: bool
    effective_from: dt.date
    effective_to: dt.date | None = None
    # Tax rates are never tombstoned — they end via effective_to, because a
    # past rate must stay resolvable for old bills. The model has no is_deleted
    # column, so the catalog contract's field is a constant here.
    is_deleted: bool = False


class SalesTypeOut(CatalogItem):
    sale_type_no: int
    descript: str
    descript_ar: str | None = None
    price_tier: str
    is_aggregator: bool
    requires_external_ref: bool
    needs_table: bool
    default_methodnum: int | None = None
    sort_order: int
    is_active: bool


class KitchenStationOut(CatalogItem):
    station_no: int
    name: str
    name_ar: str | None = None
    sort_order: int
    is_active: bool


class QuestionOut(CatalogItem):
    """A prompt the till must ask before an item can be rung."""

    question_no: int
    prompt: str
    prompt_ar: str | None = None
    is_required: bool
    pick_count: int
    allow_repeats: bool
    free_choices: int
    is_active: bool


class QuestionChoiceOut(CatalogItem):
    id: uuid.UUID
    question_no: int
    prodnum: int
    sort_order: int
    price_mode: int
    fixed_price: int | None = None
    default_qty: int
    is_active: bool


class ProductQuestionOut(CatalogItem):
    id: uuid.UUID
    prodnum: int
    question_no: int
    slot: int


class ComboItemOut(CatalogItem):
    id: uuid.UUID
    parent_prodnum: int
    prodnum: int
    sort_order: int
    price_mode: int
    fixed_price: int | None = None
    print_it: bool
    is_active: bool


class ProductImageOut(CatalogItem):
    """A till button's picture, base64 in the catalog delta.

    Base64 rather than a URL: the tills are offline-first, and a URL is a
    promise that the network is up at the moment a cashier opens the menu.
    It costs a third more bytes on the wire, once, and nothing afterwards.
    """

    prodnum: int
    mime: str
    width: int
    height: int
    byte_size: int
    # Absent on a tombstone — a deleted image has no bytes to send, and a
    # device that receives one drops the picture it holds.
    data_b64: str | None = None


class CatalogResponse(BaseModel):
    version: int = Field(description="Watermark to send as ?since= next time")
    has_more: bool = False
    next_cursor: str | None = Field(
        default=None,
        description=(
            "Opaque position to send as ?cursor= for the next page. Present "
            "exactly when has_more is true. Do NOT advance the stored "
            "watermark until a page comes back with has_more false."
        ),
    )
    products: list[ProductOut] = []
    menus: list[MenuOut] = []
    menu_pages: list[MenuPageOut] = []
    menu_screens: list[MenuScreenOut] = []
    menu_buttons: list[MenuButtonOut] = []
    pay_methods: list[PayMethodOut] = []
    staff: list[StaffOut] = []
    tax_rates: list[TaxRateOut] = []
    sales_types: list[SalesTypeOut] = []
    kitchen_stations: list[KitchenStationOut] = []
    questions: list[QuestionOut] = []
    question_choices: list[QuestionChoiceOut] = []
    product_questions: list[ProductQuestionOut] = []
    combo_items: list[ComboItemOut] = []
    product_images: list[ProductImageOut] = []


# --------------------------------------------------------------------------
# Sales (device -> server)
# --------------------------------------------------------------------------

class SaleLineIn(BaseModel):
    line_uuid: uuid.UUID
    line_no: int
    prodnum: int
    line_des: str
    qty: float
    unit_price: int = Field(ge=0, description="halalas, VAT-inclusive")
    discount: int = 0
    net_amount: int
    tax_amount: int
    line_total: int
    seat_no: int | None = None
    # The line this one hangs off: a drink chosen inside a meal, or an item the
    # combo always includes. Nested rather than flat because a bill that lists
    # "COCA COLA 0.00" beside the meal instead of under it cannot be read back
    # as what was actually sold — and the kitchen groups the same way.
    parent_line: uuid.UUID | None = None
    voided: bool = False

    @model_validator(mode="after")
    def _totals_reconcile(self):
        if self.net_amount + self.tax_amount != self.line_total:
            raise ValueError(
                f"line {self.line_no}: net {self.net_amount} + tax "
                f"{self.tax_amount} != total {self.line_total}"
            )
        return self


class SalePaymentIn(BaseModel):
    payment_uuid: uuid.UUID
    methodnum: int
    tender: int = Field(ge=0)
    change_given: int = 0
    amount: int
    auth_code: str | None = None
    card_type: str | None = None
    paid_at: dt.datetime
    voided: bool = False


class SaleIn(BaseModel):
    sale_uuid: uuid.UUID
    receipt_no: str
    opened_at: dt.datetime
    closed_at: dt.datetime | None = None
    business_date: dt.date
    table_no: int | None = None
    num_guests: int = 1
    sale_type: int = 0
    # Customer-facing number, short and daily. Assigned on the device so it
    # works offline; recorded here for kitchen displays and reports.
    order_no: int | None = None
    # The aggregator's own order id, captured at the till. PixelPoint stored
    # none across 9,641 aggregator orders — a disputed one had nothing to
    # match against.
    external_ref: str | None = None
    net_total: int
    tax_total: int
    final_total: int
    status: str = "closed"

    zatca_uuid: uuid.UUID | None = None
    zatca_icv: int | None = None
    zatca_pih: str | None = None
    zatca_hash: str | None = None
    zatca_qr: str | None = None
    zatca_xml: str | None = None

    lines: list[SaleLineIn]
    payments: list[SalePaymentIn] = []

    @model_validator(mode="after")
    def _consistent(self):
        if self.status not in ("closed", "voided"):
            raise ValueError("status must be 'closed' or 'voided'")

        if self.net_total + self.tax_total != self.final_total:
            raise ValueError(
                f"net {self.net_total} + tax {self.tax_total} != "
                f"final {self.final_total}"
            )

        live = [ln for ln in self.lines if not ln.voided]
        if live:
            if sum(ln.line_total for ln in live) != self.final_total:
                raise ValueError("line totals do not sum to the sale total")
            if sum(ln.tax_amount for ln in live) != self.tax_total:
                raise ValueError("line tax does not sum to the sale tax")

        paid = sum(p.amount for p in self.payments if not p.voided)
        if self.status == "closed" and self.payments and paid != self.final_total:
            raise ValueError(f"payments {paid} do not cover total {self.final_total}")

        # A closed sale must carry its ZATCA stamp: the device signs before it
        # prints, so anything arriving unsigned means the receipt the customer
        # holds is not compliant. Worth rejecting loudly.
        if self.status == "closed" and not self.zatca_qr:
            raise ValueError("closed sale has no ZATCA QR — receipt was not signed")

        # A child line must hang off a line of THIS sale. Storing one that
        # points elsewhere would produce a bill whose items cannot all be
        # reached from it — the chosen drink would exist and belong to nothing.
        own = {ln.line_uuid for ln in self.lines}
        for ln in self.lines:
            if ln.parent_line is None:
                continue
            if ln.parent_line not in own:
                raise ValueError(
                    f"line {ln.line_no} hangs off a line that is not in this sale"
                )
            if ln.parent_line == ln.line_uuid:
                raise ValueError(f"line {ln.line_no} is its own parent")

        return self


class SaleAccepted(BaseModel):
    sale_uuid: uuid.UUID
    status: str            # 'accepted' | 'duplicate'
    receipt_no: str


class SaleBatchResponse(BaseModel):
    accepted: list[SaleAccepted] = []
    rejected: list[dict] = []


# --------------------------------------------------------------------------
# Floor plan and table service
# --------------------------------------------------------------------------

class FloorSectionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    code: str
    name: str
    name_ar: str | None = None
    sort_order: int


class TableOut(BaseModel):
    """A table plus whatever is happening on it right now."""
    id: uuid.UUID
    table_no: int
    label: str | None = None
    section_id: uuid.UUID
    seats: int
    pos_x: int
    pos_y: int
    width: int
    height: int
    shape: str
    can_reserve: bool
    is_active: bool
    # 'free' | 'open' | 'reserved'
    status: str
    # Open and nearly finished. What a host reads the room by: a table about
    # to leave is worth more to them than one that just sat down.
    done_soon: bool = False
    session_id: uuid.UUID | None = None
    opened_by: str | None = None
    guests: int | None = None
    # Every table this party is sitting at, including this one, when two have
    # been pushed together. One number means an ordinary table.
    party_table_nos: list[int] = []
    opened_at: dt.datetime | None = None
    # What is still owed on this table, in halalas — not what it has eaten.
    # A waiter reading the room is looking for money to collect, and on a
    # check being split between guests those two numbers stop agreeing.
    running_total: int | None = None
    # How much of it has already been taken. Non-zero only on a split check,
    # where it is the difference between "they are still eating" and "two of
    # them have paid and left".
    settled_total: int = 0


class ReservationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    table_id: uuid.UUID | None = None
    guest_name: str
    phone: str | None = None
    party_size: int
    reserved_for: dt.datetime
    duration_minutes: int
    occasion: str | None = None
    note: str | None = None
    status: str


class FloorResponse(BaseModel):
    sections: list[FloorSectionOut] = []
    tables: list[TableOut] = []
    reservations: list[ReservationOut] = []


class OpenTableIn(BaseModel):
    guests: int = Field(ge=1, le=99)
    staff_id: uuid.UUID | None = None
    # Who seated it, by name. Migrated staff have no account to point a
    # staff_id at, and "who is here?" is a question about a person.
    opened_by: str | None = Field(default=None, max_length=64)


class SessionLineIn(BaseModel):
    prodnum: int
    line_des: str
    qty: float = Field(gt=0)
    unit_price: int = Field(ge=0, description="halalas, VAT-inclusive")
    # Which line of this same batch it was chosen inside, counted from 1. The
    # sender cannot know the line numbers the session will give them, so it
    # names its own position and the server translates.
    parent_index: int | None = Field(
        None, ge=1, description="1-based index within this batch of the line "
                                "this one was chosen inside"
    )
    seat_no: int | None = None
    note: str | None = None


class AddLinesIn(BaseModel):
    lines: list[SessionLineIn] = Field(min_length=1)


class SettleIn(BaseModel):
    """Which lines a bill has just paid for.

    `line_nos` empty means the whole outstanding check, which is the ordinary
    case: one table, one bill, everybody done.
    """

    sale_uuid: uuid.UUID
    line_nos: list[int] = Field(
        default_factory=list,
        description="lines this sale paid for; empty means everything still owed",
    )


class TableSessionLineOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    line_no: int
    prodnum: int
    line_des: str
    qty: float
    unit_price: int
    parent_line_no: int | None = None
    settled_sale_uuid: uuid.UUID | None = None
    seat_no: int | None = None
    note: str | None = None
    sent_to_kitchen: bool
    ordered_at: dt.datetime
    voided: bool


class TableSessionDetail(BaseModel):
    session_id: uuid.UUID
    table_id: uuid.UUID
    table_no: int
    status: str
    done_soon: bool = False
    # Sorted, and always contains table_no.
    party_table_nos: list[int] = []
    seats: int = 0
    guests: int
    opened_at: dt.datetime
    closed_at: dt.datetime | None = None
    sale_uuid: uuid.UUID | None = None
    lines: list[TableSessionLineOut] = []
    # The whole check — what this table has eaten. Unchanged by anyone paying:
    # a bill that shrinks as it is settled cannot be read back afterwards.
    net_total: int
    tax_total: int
    gross_total: int
    # What has been paid for and what is still owed. The two are what a waiter
    # walking back to a half-settled table actually needs.
    settled_total: int = 0
    outstanding_total: int = 0


class ReservationIn(BaseModel):
    table_id: uuid.UUID | None = None
    guest_name: str = Field(min_length=1)
    phone: str | None = None
    party_size: int = Field(ge=1, le=99)
    reserved_for: dt.datetime
    duration_minutes: int = Field(default=90, ge=15, le=600)
    occasion: str | None = None
    note: str | None = None


# --------------------------------------------------------------------------
# Kitchen display (KDS)
# --------------------------------------------------------------------------

class KitchenLineIn(BaseModel):
    line_no: int
    prodnum: int
    line_des: str
    qty: float = Field(gt=0)
    station_no: int
    note: str | None = None
    seat_no: int | None = None
    # The line on this ticket that this one belongs to — the meal a chosen
    # drink came out of. A cook reading "PEPSI" on its own has no way to know
    # which of four open meals it belongs to.
    parent_line_no: int | None = None


class KitchenTicketIn(BaseModel):
    ticket_id: uuid.UUID           # generated on the till; the idempotency key
    order_no: int | None = None
    sale_type_no: int | None = None
    sale_type_name: str | None = None
    table_no: int | None = None
    external_ref: str | None = None
    sale_uuid: uuid.UUID | None = None
    session_id: uuid.UUID | None = None
    created_at: dt.datetime
    lines: list[KitchenLineIn] = Field(min_length=1)


class KitchenLineOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    line_no: int
    prodnum: int
    line_des: str
    qty: float
    station_no: int
    note: str | None = None
    seat_no: int | None = None
    parent_line_no: int | None = None
    done: bool
    voided: bool


class KitchenTicketOut(BaseModel):
    id: uuid.UUID
    order_no: int | None = None
    sale_type_no: int | None = None
    sale_type_name: str | None = None
    table_no: int | None = None
    external_ref: str | None = None
    status: str
    created_at: dt.datetime
    bumped_at: dt.datetime | None = None
    lines: list[KitchenLineOut] = []


class KitchenQueueResponse(BaseModel):
    open: list[KitchenTicketOut] = []
    done: list[KitchenTicketOut] = []   # recent, for the recall lane


# --------------------------------------------------------------------------
# Provisioning
# --------------------------------------------------------------------------

class EnrolmentCreateIn(BaseModel):
    branch_id: uuid.UUID
    label: str = Field(min_length=1, max_length=64)
    receipt_prefix: str = Field(min_length=1, max_length=8)
    role: str = Field(default="pos", pattern="^(pos|kds|cds)$")
    kds_station_no: int | None = None


class EnrolmentCodeOut(BaseModel):
    code: str
    branch_id: uuid.UUID
    label: str
    role: str
    expires_at: dt.datetime


class EnrolmentRedeemIn(BaseModel):
    code: str = Field(min_length=16, max_length=64)
    device_uuid: str = Field(min_length=8, max_length=64)
    platform: str | None = Field(default=None, max_length=16)
    app_version: str | None = Field(default=None, max_length=32)


class EnrolmentRedeemOut(BaseModel):
    token: str
    device_id: uuid.UUID
    role: str
    receipt_prefix: str
    kds_station_no: int | None = None
    branch_name: str
    tenant_mode: str
    # The legal seller identity the device invoices under. Delivered at
    # enrolment because the tablet must be able to issue a compliant ZATCA
    # invoice with no network — it cannot ask for these at sale time.
    seller_name: str
    seller_name_ar: str | None = None
    seller_vat: str
    seller_cr: str | None = None
    seller_address: dict = Field(default_factory=dict)


class OrderNumberIn(BaseModel):
    business_date: dt.date
    # Devices reserve a block rather than one number at a time, so they can
    # keep calling out numbers with no network. Capped because an unbounded
    # request would let one till burn a day's worth of numbers in one call.
    count: int = Field(default=1, ge=1, le=500)


class OrderNumberOut(BaseModel):
    business_date: dt.date
    # First number of the reserved run. The caller owns
    # order_no .. order_no + count - 1 inclusive.
    order_no: int
    count: int = 1


# --------------------------------------------------------------------------
# Back office
# --------------------------------------------------------------------------

class OfficeLoginIn(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=1, max_length=256)


class OfficeLoginOut(BaseModel):
    token: str
    name: str
    email: str
    role: str
    company_name: str


class OfficeDashboard(BaseModel):
    business_date: dt.date
    sale_count: int
    gross_total: int
    vat_total: int
    net_total: int
    # Sales that closed without a ZATCA stamp. Not a queue that drains —
    # each one is an invoice that was never legally issued.
    unsigned_sales: int
    unreported_sales: int
    active_devices: int
    silent_devices: int
    by_sale_type: list[dict]


# Price tiers A-J. All ten exist in the source catalog and all ten are
# editable: which one applies is decided by the sale type, so a tier nobody
# uses today becomes load-bearing the day an aggregator is added.
PRICE_TIERS = tuple("abcdefghij")


class OfficeProductOut(BaseModel):
    id: uuid.UUID
    prodnum: int
    descript: str
    descript_ar: str | None = None
    print_des: str | None = None
    price_a: int
    price_b: int | None = None
    price_c: int | None = None
    price_d: int | None = None
    price_e: int | None = None
    price_f: int | None = None
    price_g: int | None = None
    price_h: int | None = None
    price_i: int | None = None
    price_j: int | None = None
    tax_applies: bool
    is_weighed: bool
    manual_price: bool
    is_modifier: bool
    is_active: bool
    # Kitchen routing bitmask carried over from PixelPoint's PRINTLOC: bit n
    # means the item goes to the station on printer port n.
    print_loc: int
    # -> ReportCategory.report_no. What sales reports group this under.
    report_no: int | None = None
    prodtype: int | None = None
    ref_code: str | None = None
    unit_des: str | None = None
    # How the till button looks. The imported menu is colour-coded — staff
    # find items by colour before they read them.
    button_text: str | None = None
    fore_color: str | None = None
    back_color: str | None = None
    # A picture is read faster than a name, which is the point of one. Only
    # whether it is set and which version it is at - the bytes come from
    # /products/{prodnum}/image so a list stays a list.
    has_image: bool = False
    image_version: int = 0
    server_version: int
    # Which menu screens this product sits on. Read-only here - moving
    # buttons around is a menu-layout job, not a product one.
    menu_ids: list[int] = Field(default_factory=list)
    # The meal-deal prompts this item asks, in the order they are asked.
    # PixelPoint's five "Forced Questions" slots.
    question_nos: list[int] = Field(default_factory=list)


class OfficeProductUpdate(BaseModel):
    """Every field optional: a PATCH changes what it names and nothing else.

    Prices are VAT-inclusive halalas, the same unit as everywhere else — the
    UI converts, the API does not, so there is one place where 8.00 becomes
    800 and it is not on the wire.
    """

    descript: str | None = Field(default=None, min_length=1)
    descript_ar: str | None = None
    print_des: str | None = None
    price_a: int | None = Field(default=None, ge=0)
    price_b: int | None = Field(default=None, ge=0)
    price_c: int | None = Field(default=None, ge=0)
    price_d: int | None = Field(default=None, ge=0)
    price_e: int | None = Field(default=None, ge=0)
    price_f: int | None = Field(default=None, ge=0)
    price_g: int | None = Field(default=None, ge=0)
    price_h: int | None = Field(default=None, ge=0)
    price_i: int | None = Field(default=None, ge=0)
    price_j: int | None = Field(default=None, ge=0)
    tax_applies: bool | None = None
    is_weighed: bool | None = None
    manual_price: bool | None = None
    is_modifier: bool | None = None
    is_active: bool | None = None
    print_loc: int | None = Field(default=None, ge=0)
    report_no: int | None = Field(default=None, ge=0)
    prodtype: int | None = Field(default=None, ge=0)
    ref_code: str | None = None
    unit_des: str | None = None
    button_text: str | None = None
    # '#RRGGBB' or null for "use the theme". Validated so a typo cannot reach
    # a till and render as nothing.
    fore_color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    back_color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    # The prompts this item asks, in order. Replaces the whole list when
    # present — five ordered slots have no sensible partial update.
    question_nos: list[int] | None = Field(default=None, max_length=5)


class OfficeProductCreate(BaseModel):
    """A new product.

    `prodnum` is chosen by the caller rather than generated: it is the key the
    tills, the kitchen routing and the imported PixelPoint history all use, so
    it has to be a number a human can recognise and reuse.
    """

    prodnum: int = Field(ge=1)
    descript: str = Field(min_length=1)
    descript_ar: str | None = None
    print_des: str | None = None
    price_a: int = Field(ge=0)
    price_b: int | None = Field(default=None, ge=0)
    price_j: int | None = Field(default=None, ge=0)
    tax_applies: bool = True
    is_weighed: bool = False
    manual_price: bool = False
    is_modifier: bool = False
    print_loc: int = Field(default=0, ge=0)
    report_no: int | None = Field(default=None, ge=0)
    ref_code: str | None = None
    unit_des: str | None = None


# --------------------------------------------------------------------------
# Menu layout
#
# An order page is a grid of buttons. The imported layout puts every button at
# a real (x, y) — staff reach for position before they read the label — so the
# editor works in grid coordinates rather than a list order.

class OfficeQuestionOut(BaseModel):
    """A meal-deal prompt, with what it offers."""

    question_no: int
    prompt: str
    is_required: bool
    pick_count: int
    allow_repeats: bool
    is_active: bool
    choices: list[dict] = Field(default_factory=list)
    used_by: int = 0


class OfficeMenuOut(BaseModel):
    """A whole menu: the grid of page tiles a till lands on."""

    id: uuid.UUID
    menu_no: int
    name: str
    name_ar: str | None = None
    is_active: bool
    page_count: int = 0
    used_across: int = 0
    used_down: int = 0


class OfficeMenuPageOut(BaseModel):
    id: uuid.UUID
    screen_no: int
    name: str
    pos_x: int | None = None
    pos_y: int | None = None
    fore_color: str | None = None
    back_color: str | None = None
    button_count: int = 0
    is_active: bool


class OfficeMenuPagePlace(BaseModel):
    screen_no: int = Field(ge=1)
    pos_x: int = Field(ge=1, le=20)
    pos_y: int = Field(ge=1, le=20)


class OfficeMenuScreenOut(BaseModel):
    id: uuid.UUID
    menu_id: int
    name: str
    name_ar: str | None = None
    sort_order: int
    # The grid the page is drawn on. NULL in every imported row, because
    # PixelPoint stored 0 for all of them, so the effective size is derived
    # from where the buttons actually sit until someone sets one.
    buttons_across: int | None = None
    buttons_down: int | None = None
    is_modifier_screen: bool
    is_active: bool
    button_count: int = 0
    # What the grid must be at least, to show every button already placed.
    used_across: int = 0
    used_down: int = 0


class OfficeMenuScreenCreate(BaseModel):
    menu_id: int = Field(ge=1)
    name: str = Field(min_length=1)
    name_ar: str | None = None
    sort_order: int = 0
    buttons_across: int | None = Field(default=None, ge=1, le=20)
    buttons_down: int | None = Field(default=None, ge=1, le=20)
    is_modifier_screen: bool = False


class OfficeMenuScreenUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1)
    name_ar: str | None = None
    sort_order: int | None = None
    buttons_across: int | None = Field(default=None, ge=1, le=20)
    buttons_down: int | None = Field(default=None, ge=1, le=20)
    is_active: bool | None = None


class OfficeMenuButtonOut(BaseModel):
    id: uuid.UUID
    prodnum: int
    pos_x: int
    pos_y: int
    # Denormalised from the product so the editor can draw the button exactly
    # as a till would, without a request per cell.
    descript: str
    button_text: str | None = None
    fore_color: str | None = None
    back_color: str | None = None
    price_a: int
    is_active: bool
    # Whether a picture is set, not the picture itself: a 30-cell page would
    # otherwise be a megabyte of base64 before the editor drew anything. The
    # editor fetches each one from its own endpoint, which the browser caches.
    has_image: bool = False
    image_version: int = 0


class ImageRules(BaseModel):
    """What the back office may upload, straight from the server.

    Served rather than written into the page so the guidance a manager reads
    and the rule the server enforces cannot drift apart.
    """

    ideal_px: int = Field(description="the square the browser crops and exports to")
    min_px: int = Field(description="below this the picture is soft on a tile")
    max_px: int = Field(description="hard ceiling on either side")
    max_bytes: int = Field(description="hard ceiling after cropping")
    formats: list[str] = Field(description="accepted mime types")


class ProductImageIn(BaseModel):
    """An already-cropped picture from the back office.

    The browser does the resizing and cropping, so this is the final image —
    the server checks it rather than transforming it, which keeps image
    processing (and a native image library) out of the deployment.
    """

    mime: str
    data_b64: str


class OfficeMenuButtonPlace(BaseModel):
    prodnum: int = Field(ge=1)
    pos_x: int = Field(ge=1, le=20)
    pos_y: int = Field(ge=1, le=20)


class OfficeMenuButtonMove(BaseModel):
    pos_x: int = Field(ge=1, le=20)
    pos_y: int = Field(ge=1, le=20)


class OfficeFloorSectionOut(BaseModel):
    """An area of the restaurant: ground floor, terrace, family, smoking."""

    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    code: str
    name: str
    name_ar: str | None = None
    sort_order: int
    is_active: bool
    table_count: int = 0
    seat_count: int = 0


class OfficeFloorSectionCreate(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    name: str = Field(min_length=1)
    name_ar: str | None = None
    sort_order: int = 0


class OfficeFloorSectionUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1)
    name_ar: str | None = None
    sort_order: int | None = None
    is_active: bool | None = None


class OfficeTableOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    section_id: uuid.UUID
    table_no: int
    label: str | None = None
    seats: int
    min_seats: int | None = None
    max_seats: int | None = None
    pos_x: int
    pos_y: int
    width: int
    height: int
    shape: str
    can_reserve: bool
    is_active: bool
    # True while somebody is sitting at it. A table in use cannot be taken out
    # of service or moved to another area under the party eating at it.
    in_use: bool = False


class OfficeTableCreate(BaseModel):
    section_id: uuid.UUID
    table_no: int = Field(ge=1)
    label: str | None = Field(default=None, max_length=32)
    seats: int = Field(default=2, ge=1, le=99)
    max_seats: int | None = Field(default=None, ge=1, le=99)
    pos_x: int = Field(default=0, ge=0)
    pos_y: int = Field(default=0, ge=0)
    width: int = Field(default=2, ge=1, le=20)
    height: int = Field(default=2, ge=1, le=20)
    shape: str = Field(default="square", pattern="^(square|round|rect)$")
    can_reserve: bool = True


class OfficeTableUpdate(BaseModel):
    section_id: uuid.UUID | None = None
    label: str | None = None
    seats: int | None = Field(default=None, ge=1, le=99)
    max_seats: int | None = Field(default=None, ge=1, le=99)
    pos_x: int | None = Field(default=None, ge=0)
    pos_y: int | None = Field(default=None, ge=0)
    width: int | None = Field(default=None, ge=1, le=20)
    height: int | None = Field(default=None, ge=1, le=20)
    shape: str | None = Field(default=None, pattern="^(square|round|rect)$")
    can_reserve: bool | None = None
    is_active: bool | None = None


class OfficeDeviceOut(BaseModel):
    id: uuid.UUID
    label: str
    branch_name: str
    role: str
    receipt_prefix: str
    platform: str | None = None
    app_version: str | None = None
    csid_status: str
    last_seen_at: dt.datetime | None = None
    last_icv: int | None = None
    is_active: bool


class OfficeEnrolmentOut(BaseModel):
    code: str
    branch_name: str
    label: str
    role: str
    expires_at: dt.datetime | None = None


class OfficeSaleOut(BaseModel):
    receipt_no: str
    closed_at: dt.datetime | None = None
    business_date: dt.date
    sale_type_name: str
    order_no: int | None = None
    external_ref: str | None = None
    net_total: int
    tax_total: int
    final_total: int
    is_signed: bool
    zatca_icv: int | None = None
    zatca_status: str
    zatca_error: str | None = None
