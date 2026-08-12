-- ============================================================
-- Offline-first POS — local SQLite schema (tablet / desktop)
-- Source of record: PixelSQLbase (SQL Anywhere 16)
-- Region: Saudi Arabia — 15% VAT, VAT-inclusive pricing, ZATCA Phase 2
-- ============================================================
--
-- Design rules:
--  1. Catalog tables are PULL-only (server wins, never edited on device).
--  2. Sale tables are PUSH-only, append-only, UUID keyed on the device.
--  3. Money stored as INTEGER halalas (1 SAR = 100 halalas) — never REAL.
--     Prices in PixelPoint are VAT-INCLUSIVE doubles; convert on sync.
--  4. Every synced table carries server_version for incremental pull.
--
-- ============================================================

PRAGMA journal_mode = WAL;      -- concurrent read while writing
PRAGMA foreign_keys = ON;

-- ------------------------------------------------------------
-- SYNC BOOKKEEPING
-- ------------------------------------------------------------

-- One row per pull-table: what watermark we last received.
CREATE TABLE sync_state (
    table_name    TEXT PRIMARY KEY,
    last_version  INTEGER NOT NULL DEFAULT 0,  -- server change counter
    last_pulled_at TEXT                        -- ISO8601 UTC
);

-- Identifies this physical device. Single row.
-- Each device is its own ZATCA EGS unit: own CSID, own ICV counter, own hash
-- chain. That is what lets any tablet close a bill and print a compliant QR
-- receipt with no network and no dependency on the hub.
CREATE TABLE device (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    device_uuid     TEXT NOT NULL UNIQUE,
    station_no      INTEGER NOT NULL,   -- maps to POSHEADER.STATNUM
    store_no        INTEGER NOT NULL,   -- maps to POSHEADER.StoreNum
    receipt_prefix  TEXT NOT NULL,      -- e.g. 'T01' -> receipts T01-000123
    next_receipt_seq INTEGER NOT NULL DEFAULT 1,
    is_hub          INTEGER NOT NULL DEFAULT 0,  -- coordination role, not billing
    -- What this screen does: till, kitchen display, or customer display.
    -- Assigned at enrolment; one app, three roles.
    role            TEXT NOT NULL DEFAULT 'pos'
                    CHECK (role IN ('pos','kds','cds')),
    kds_station_no  INTEGER,            -- kds only: pin to one station
    api_base_url    TEXT,
    auth_token      TEXT,
    -- Which branch this till stands in, delivered at enrolment. Here rather
    -- than compiled in: one build serves every customer, and a name in the
    -- binary is the wrong restaurant on every other tenant's screen.
    branch_name     TEXT,
    -- Receipt printer on the LAN (ESC/POS over port 9100). Unset = no printing.
    printer_host    TEXT,
    printer_port    INTEGER NOT NULL DEFAULT 9100,
    -- Who is on this till. Every sale records a cashier (sale.emp_open is NOT
    -- NULL and a foreign key), so this must be set before anything can be
    -- charged. NOT a login: migrated staff arrive with must_set_pin and no
    -- pin_hash, so this identifies the cashier without yet authenticating
    -- them. Until PINs are set, anyone at the till can select anyone.
    active_empnum   INTEGER REFERENCES employee(empnum),
    -- What this till was last doing. Sale types decide far more than price: a
    -- table-service type starts the order on the floor plan, a counter one goes
    -- straight to the menu. Remembered so a drive-thru till does not boot into
    -- the floor because Dine-In happens to sort first.
    active_sale_type INTEGER,
    -- ZATCA EGS identity. Only public material and metadata live here.
    --
    -- The private key is NOT in this database and NOT in the Android
    -- Keystore either: ZATCA mandates secp256k1 and the Keystore holds NIST
    -- curves only, so a Keystore-resident signing key is not possible. It
    -- lives in application storage, encrypted at rest under a Keystore-held
    -- symmetric key. See lib/zatca/device_signer.dart.
    zatca_egs_serial TEXT,              -- 1-<vendor>|2-<model>|3-<device_uuid>
    zatca_csid       TEXT,              -- compliance/production CSID (cert)
    zatca_csid_expires_at TEXT,
    zatca_public_key TEXT,              -- base64 SubjectPublicKeyInfo DER (QR tag 8)
    zatca_csid_signature TEXT,          -- base64, ZATCA's signature over it (QR tag 9)
    zatca_vat_number TEXT,              -- seller VAT registration number
    zatca_seller_name TEXT,
    zatca_seller_cr  TEXT,              -- commercial registration number
    zatca_seller_address TEXT,          -- JSON: street/building/district/city/postal_code
    zatca_next_icv   INTEGER NOT NULL DEFAULT 1,  -- strictly sequential, never reused
    zatca_last_pih   TEXT               -- hash of this device's previous invoice
);

-- ------------------------------------------------------------
-- CATALOG  (pull: server -> device)
-- ------------------------------------------------------------

CREATE TABLE product (
    prodnum        INTEGER PRIMARY KEY,       -- DBA.Product.PRODNUM
    descript       TEXT    NOT NULL,          -- DESCRIPT
    descript_ar    TEXT,                      -- Arabic name, for receipts
    print_des      TEXT,                      -- PRINTDES (kitchen ticket name)
    -- Price tiers A-J, all VAT-inclusive halalas. The sale type decides which
    -- applies: walk-in pays A, delivery aggregators pay B (the difference is
    -- their commission), staff meals and press comps pay J, which is zero.
    price_a        INTEGER NOT NULL,
    price_b        INTEGER,
    price_c        INTEGER,
    price_d        INTEGER,
    price_e        INTEGER,
    price_f        INTEGER,
    price_g        INTEGER,
    price_h        INTEGER,
    price_i        INTEGER,
    price_j        INTEGER,
    prodtype       INTEGER,                   -- category id
    tax_applies    INTEGER NOT NULL DEFAULT 1,-- 1 = VAT applies
    is_weighed     INTEGER NOT NULL DEFAULT 0,
    manual_price   INTEGER NOT NULL DEFAULT 0,
    is_modifier    INTEGER NOT NULL DEFAULT 0,-- appears only on modifier screens
    -- Kitchen routing bitmask (PixelPoint PRINTLOC): bit n = station_no n.
    print_loc      INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    ref_code       TEXT,                      -- REFCODE / barcode
    unit_des       TEXT,
    -- How the till button looks. The label is NOT the description: it is what
    -- fits on a tile, and 308 of 560 imported products differ. The colours are
    -- '#RRGGBB' or NULL for the theme — the imported menu uses 27 of them, and
    -- staff find an item by colour before they read it.
    button_text    TEXT,
    fore_color     TEXT,
    back_color     TEXT,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0 -- tombstone
);
CREATE INDEX ix_product_active  ON product(is_active, is_deleted);
CREATE INDEX ix_product_type    ON product(prodtype);
CREATE INDEX ix_product_refcode ON product(ref_code);

-- A whole menu: the grid of page tiles a till opens on. The level above order
-- pages, and how a cashier gets anywhere. Without it the till can only offer a
-- flat list of every page, which is not the menu anyone learned.
CREATE TABLE menu (
    menu_no        INTEGER PRIMARY KEY,
    name           TEXT NOT NULL,
    name_ar        TEXT,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

-- Where a page sits on a menu. A join, not a column on menu_screen: one page
-- appears on several menus, at a different tile on each.
CREATE TABLE menu_page (
    id             TEXT PRIMARY KEY,          -- uuid, assigned by the backend
    menu_no        INTEGER NOT NULL,
    screen_no      INTEGER NOT NULL,          -- -> menu_screen.menu_id
    pos_x          INTEGER,
    pos_y          INTEGER,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0,
    UNIQUE (menu_no, screen_no)
);
CREATE INDEX ix_menu_page_menu ON menu_page(menu_no, pos_y, pos_x);

-- Menu screens (PIXELMENU) and the buttons on them (MenuProdPos).
CREATE TABLE menu_screen (
    menu_id        INTEGER PRIMARY KEY,
    name           TEXT NOT NULL,
    name_ar        TEXT,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    buttons_across INTEGER,                   -- grid layout from the source
    buttons_down   INTEGER,
    -- The page tile's colours on the menu grid, '#RRGGBB' or NULL.
    fore_color     TEXT,
    back_color     TEXT,
    is_modifier_screen INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE menu_button (
    id             TEXT PRIMARY KEY,          -- uuid, assigned by the backend
    menu_id        INTEGER NOT NULL REFERENCES menu_screen(menu_id),
    prodnum        INTEGER REFERENCES product(prodnum),
    position       INTEGER NOT NULL,
    pos_x          INTEGER,
    pos_y          INTEGER,
    caption        TEXT,
    fore_color     INTEGER,
    back_color     INTEGER,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_menu_button_menu ON menu_button(menu_id, position);

-- ------------------------------------------------------------
-- MEAL DEALS  (pull: server -> device)
-- ------------------------------------------------------------
-- What the till must ask before an item can be rung, and what a combo always
-- includes. 91 imported products ask at least one question; without these the
-- meal rings with nothing chosen and the kitchen is told to make an empty box.
--
-- No foreign keys onto product on purpose: these reference products by number,
-- a product can be withdrawn in the back office after the prompt was written,
-- and a stale reference must make the choice unofferable — not fail the whole
-- catalog apply. Every read joins product, so a missing one simply drops out.

CREATE TABLE question (
    question_no    INTEGER PRIMARY KEY,       -- PixelPoint OPTIONINDEX
    prompt         TEXT NOT NULL,             -- '1 DRINKS', 'Bread Selection'
    prompt_ar      TEXT,
    is_required    INTEGER NOT NULL DEFAULT 1,-- 0 = the cashier may skip it
    pick_count     INTEGER NOT NULL DEFAULT 1,-- the Tabakat platters ask for 6
    allow_repeats  INTEGER NOT NULL DEFAULT 0,-- same choice more than once
    free_choices   INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

-- One answer to a question — itself a product.
CREATE TABLE question_choice (
    id             TEXT PRIMARY KEY,          -- uuid, assigned by the backend
    question_no    INTEGER NOT NULL,
    prodnum        INTEGER NOT NULL,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    -- PixelPoint's PriceMode, carried raw. Both values in the import (0 with
    -- no fixed price, 11 with a fixed price of zero) mean the same thing: the
    -- choice is included in the meal. The till charges fixed_price when set
    -- and nothing otherwise; it does not interpret the mode.
    price_mode     INTEGER NOT NULL DEFAULT 0,
    fixed_price    INTEGER,
    default_qty    INTEGER NOT NULL DEFAULT 1,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_question_choice_q ON question_choice(question_no, sort_order);

-- Which questions a product asks, in slot order (1-5).
CREATE TABLE product_question (
    id             TEXT PRIMARY KEY,          -- uuid, assigned by the backend
    prodnum        INTEGER NOT NULL,
    question_no    INTEGER NOT NULL,
    slot           INTEGER NOT NULL,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0,
    UNIQUE (prodnum, slot)
);
CREATE INDEX ix_product_question_prod ON product_question(prodnum, slot);

-- What a combo always includes, with nothing to choose: a Bucket BROSTED comes
-- with a litre, a garlic and a hummos. The customer is not asked; the kitchen
-- still has to be told. Two rows for the same product mean two of them.
CREATE TABLE combo_item (
    id             TEXT PRIMARY KEY,          -- uuid, assigned by the backend
    parent_prodnum INTEGER NOT NULL,
    prodnum        INTEGER NOT NULL,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    price_mode     INTEGER NOT NULL DEFAULT 0,
    fixed_price    INTEGER,
    print_it       INTEGER NOT NULL DEFAULT 1,-- 0 = on the bill, not the ticket
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_combo_item_parent ON combo_item(parent_prodnum, sort_order);

-- The picture on a product's till button. A table rather than a column on
-- product: a product row is read on every repaint of the menu grid, and an
-- image is roughly a thousand times its size. The bytes live here rather than
-- behind a URL because a till has to draw its menu with no network at all.
CREATE TABLE product_image (
    prodnum        INTEGER PRIMARY KEY,       -- one picture per product
    mime           TEXT NOT NULL,             -- image/jpeg from the back office
    data           BLOB NOT NULL,
    width          INTEGER NOT NULL DEFAULT 0,
    height         INTEGER NOT NULL DEFAULT 0,
    byte_size      INTEGER NOT NULL DEFAULT 0,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE pay_method (
    methodnum      INTEGER PRIMARY KEY,       -- DBA.MethodPay.METHODNUM
    descript       TEXT NOT NULL,             -- CASH / MADA / Visa ...
    descript_ar    TEXT,
    is_active      INTEGER NOT NULL DEFAULT 1,
    is_cash        INTEGER NOT NULL DEFAULT 0,-- opens drawer, allows change
    opens_drawer   INTEGER NOT NULL DEFAULT 0,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

-- How the order reaches the customer. Carries the price tier, so this is not
-- a cosmetic label: the wrong tier is the wrong price on every order.
CREATE TABLE sales_type (
    sale_type_no   INTEGER PRIMARY KEY,
    descript       TEXT NOT NULL,
    descript_ar    TEXT,
    price_tier     TEXT NOT NULL DEFAULT 'a'
                   CHECK (length(price_tier) = 1 AND price_tier BETWEEN 'a' AND 'j'),
    is_aggregator  INTEGER NOT NULL DEFAULT 0,
    requires_external_ref INTEGER NOT NULL DEFAULT 0,
    needs_table    INTEGER NOT NULL DEFAULT 0,
    default_methodnum INTEGER,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

-- Customer-facing order numbers, reset daily so they stay short enough to call
-- across a kitchen. PixelPoint recorded none at all in 31,000 drive-thru orders.
--
-- A device does NOT count these on its own: two tills at one counter would call
-- out the same number to different customers. It asks the backend for a
-- contiguous BLOCK and hands out from that, so the allocation is atomic per
-- branch and per day while the numbers themselves stay usable with no network.
-- `next_number` is the next to hand out; `block_end` is the last one this
-- device owns (inclusive). next_number > block_end means the block is spent.
CREATE TABLE order_counter (
    business_date  TEXT PRIMARY KEY,
    next_number    INTEGER NOT NULL DEFAULT 1,
    block_end      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE employee (
    empnum         INTEGER PRIMARY KEY,
    name           TEXT NOT NULL,
    -- Nullable on purpose: staff migrated from PixelPoint arrive with no
    -- credential (the source had none worth carrying), and must set a PIN
    -- during onboarding. must_set_pin gates login until they do.
    pin_hash       TEXT,                      -- never store the raw PIN
    must_set_pin   INTEGER NOT NULL DEFAULT 1,
    sec_level      INTEGER NOT NULL DEFAULT 0,
    ref_code       TEXT,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0,
    CHECK (pin_hash IS NOT NULL OR must_set_pin = 1)
);

-- Tax rates kept as data, not hardcoded — rates change by law.
CREATE TABLE tax_rate (
    tax_id         INTEGER PRIMARY KEY,       -- 1..5, matches TAX1..TAX5
    name           TEXT NOT NULL,             -- 'VAT'
    percent        REAL NOT NULL,             -- 15.0
    is_inclusive   INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0
);

-- ------------------------------------------------------------
-- KITCHEN  (stations pulled from the server; tickets live on the hub)
-- ------------------------------------------------------------

CREATE TABLE kitchen_station (
    station_no     INTEGER PRIMARY KEY,       -- the printer port it replaces
    name           TEXT NOT NULL,             -- Expo / Grill / Shawarma / DT
    name_ar        TEXT,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

-- A kitchen ticket is workflow, not a tax record: bumping or voiding one never
-- touches money. Created by the till when the order goes to the kitchen.
CREATE TABLE kitchen_ticket (
    ticket_uuid    TEXT PRIMARY KEY,
    order_no       INTEGER,
    sale_type_no   INTEGER,
    sale_type_name TEXT,
    table_no       INTEGER,
    external_ref   TEXT,
    sale_uuid      TEXT,
    session_uuid   TEXT,
    status         TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','done')),
    created_at     TEXT NOT NULL,
    bumped_at      TEXT,
    sync_status    TEXT NOT NULL DEFAULT 'pending'
);
CREATE INDEX ix_kticket_rail ON kitchen_ticket(status, created_at);

CREATE TABLE kitchen_ticket_line (
    line_uuid      TEXT PRIMARY KEY,
    ticket_uuid    TEXT NOT NULL REFERENCES kitchen_ticket(ticket_uuid) ON DELETE CASCADE,
    line_no        INTEGER NOT NULL,
    prodnum        INTEGER NOT NULL,
    line_des       TEXT NOT NULL,             -- snapshot at order time
    qty            REAL NOT NULL DEFAULT 1,
    station_no     INTEGER NOT NULL,          -- resolved from product.print_loc
    note           TEXT,
    -- The line_no on this ticket this one belongs to: the meal a chosen drink
    -- came out of. A cook reading 'PEPSI' alone cannot tell which of four open
    -- meals it is for. Per ticket AND per station: a group that reaches two
    -- stations is written twice, and each copy carries its own numbering.
    parent_line_no INTEGER,
    seat_no        INTEGER,
    done           INTEGER NOT NULL DEFAULT 0,
    voided         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_kline_ticket ON kitchen_ticket_line(ticket_uuid, line_no);
CREATE INDEX ix_kline_station ON kitchen_ticket_line(station_no);

-- ------------------------------------------------------------
-- FLOOR PLAN  (pull: server -> device)
-- ------------------------------------------------------------

CREATE TABLE floor_section (
    section_id     TEXT PRIMARY KEY,          -- uuid from the backend
    code           TEXT NOT NULL,
    name           TEXT NOT NULL,
    name_ar        TEXT,
    sort_order     INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE dining_table (
    table_id       TEXT PRIMARY KEY,
    section_id     TEXT NOT NULL REFERENCES floor_section(section_id),
    table_no       INTEGER NOT NULL UNIQUE,
    label          TEXT,
    seats          INTEGER NOT NULL DEFAULT 2,
    min_seats      INTEGER,
    max_seats      INTEGER,
    -- Abstract grid; the client scales it to the screen. PixelPoint had no
    -- geometry at all, so an imported plan is laid out by the migration.
    pos_x          INTEGER NOT NULL DEFAULT 0,
    pos_y          INTEGER NOT NULL DEFAULT 0,
    width          INTEGER NOT NULL DEFAULT 2,
    height         INTEGER NOT NULL DEFAULT 2,
    shape          TEXT NOT NULL DEFAULT 'square',
    can_reserve    INTEGER NOT NULL DEFAULT 1,
    is_active      INTEGER NOT NULL DEFAULT 1,
    server_version INTEGER NOT NULL DEFAULT 0,
    is_deleted     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_dining_table_section ON dining_table(section_id);

-- ------------------------------------------------------------
-- OPEN TABLES  (local first, shared over the LAN by the hub)
-- ------------------------------------------------------------
-- A session is an order in progress. It becomes a `sale` when the bill closes;
-- until then it lives only here and on whichever tablets are sharing state.

CREATE TABLE table_session (
    session_uuid   TEXT PRIMARY KEY,
    table_id       TEXT NOT NULL REFERENCES dining_table(table_id),
    staff_empnum   INTEGER REFERENCES employee(empnum),
    guests         INTEGER NOT NULL DEFAULT 1,
    opened_at      TEXT NOT NULL,
    closed_at      TEXT,
    status         TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','billed','closed','abandoned')),
    sale_uuid      TEXT REFERENCES sale(sale_uuid),
    sync_status    TEXT NOT NULL DEFAULT 'pending'
);
-- One open session per table: two would mean two waiters building separate
-- bills for the same guests without either knowing.
CREATE UNIQUE INDEX ux_session_one_open ON table_session(table_id)
    WHERE status = 'open';
CREATE INDEX ix_session_status ON table_session(status);

CREATE TABLE table_session_line (
    line_uuid      TEXT PRIMARY KEY,
    session_uuid   TEXT NOT NULL REFERENCES table_session(session_uuid) ON DELETE CASCADE,
    line_no        INTEGER NOT NULL,
    prodnum        INTEGER NOT NULL REFERENCES product(prodnum),
    line_des       TEXT NOT NULL,             -- snapshot at order time
    qty            REAL NOT NULL DEFAULT 1,
    unit_price     INTEGER NOT NULL,          -- halalas, VAT-inclusive snapshot
    seat_no        INTEGER,
    note           TEXT,
    sent_to_kitchen INTEGER NOT NULL DEFAULT 0,
    ordered_at     TEXT NOT NULL,
    voided         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_session_line ON table_session_line(session_uuid, line_no);

CREATE TABLE reservation (
    reservation_uuid TEXT PRIMARY KEY,
    table_id       TEXT REFERENCES dining_table(table_id),
    guest_name     TEXT NOT NULL,
    phone          TEXT,
    party_size     INTEGER NOT NULL,
    reserved_for   TEXT NOT NULL,
    duration_minutes INTEGER NOT NULL DEFAULT 90,
    occasion       TEXT,
    note           TEXT,
    status         TEXT NOT NULL DEFAULT 'booked'
                   CHECK (status IN ('booked','seated','cancelled','no_show')),
    sync_status    TEXT NOT NULL DEFAULT 'pending'
);
CREATE INDEX ix_reservation_when ON reservation(reserved_for);

-- ------------------------------------------------------------
-- SALES  (push: device -> server).  Append-only.
-- ------------------------------------------------------------

CREATE TABLE sale (
    sale_uuid      TEXT PRIMARY KEY,          -- generated on device
    receipt_no     TEXT NOT NULL UNIQUE,      -- 'T01-000123', device-local
    opened_at      TEXT NOT NULL,             -- ISO8601 UTC
    closed_at      TEXT,
    business_date  TEXT NOT NULL,             -- maps to OPENDATE
    station_no     INTEGER NOT NULL,
    store_no       INTEGER NOT NULL,
    emp_open       INTEGER NOT NULL REFERENCES employee(empnum),
    emp_close      INTEGER REFERENCES employee(empnum),
    table_no       INTEGER,
    num_guests     INTEGER NOT NULL DEFAULT 1,
    sale_type      INTEGER NOT NULL DEFAULT 0 REFERENCES sales_type(sale_type_no),
    order_no       INTEGER,                   -- called out when the food is up
    external_ref   TEXT,                      -- the aggregator's own order id
    net_total      INTEGER NOT NULL DEFAULT 0,-- halalas, excl. VAT
    tax_total      INTEGER NOT NULL DEFAULT 0,
    final_total    INTEGER NOT NULL DEFAULT 0,-- what the customer pays
    status         TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','closed','voided')),
    -- ZATCA Phase 2 (generated on-device at close time)
    zatca_uuid     TEXT,                      -- invoice UUID
    zatca_pih      TEXT,                      -- previous invoice hash (chain)
    zatca_hash     TEXT,                      -- this invoice hash
    zatca_qr       TEXT,                      -- base64 TLV QR payload
    zatca_xml_path TEXT,                      -- signed UBL 2.1 XML on disk
    zatca_status   TEXT NOT NULL DEFAULT 'pending'
                   CHECK (zatca_status IN ('pending','reported','failed')),
    zatca_icv      INTEGER,                   -- invoice counter value
    -- sync
    sync_status    TEXT NOT NULL DEFAULT 'pending'
                   CHECK (sync_status IN ('pending','sent','acked','failed')),
    sync_attempts  INTEGER NOT NULL DEFAULT 0,
    sync_error     TEXT,
    server_transact INTEGER                   -- POSHEADER.TRANSACT once acked
);
CREATE INDEX ix_sale_sync     ON sale(sync_status, opened_at);
CREATE INDEX ix_sale_zatca    ON sale(zatca_status);
CREATE INDEX ix_sale_bizdate  ON sale(business_date);
CREATE INDEX ix_sale_status   ON sale(status);

CREATE TABLE sale_line (
    line_uuid      TEXT PRIMARY KEY,
    sale_uuid      TEXT NOT NULL REFERENCES sale(sale_uuid) ON DELETE CASCADE,
    line_no        INTEGER NOT NULL,
    prodnum        INTEGER NOT NULL REFERENCES product(prodnum),
    line_des       TEXT NOT NULL,             -- snapshot: name at sale time
    qty            REAL NOT NULL DEFAULT 1,   -- REAL: weighed items
    unit_price     INTEGER NOT NULL,          -- halalas, VAT-inclusive snapshot
    discount       INTEGER NOT NULL DEFAULT 0,
    net_amount     INTEGER NOT NULL,          -- excl. VAT
    tax_amount     INTEGER NOT NULL,
    line_total     INTEGER NOT NULL,          -- incl. VAT
    apply_tax1     INTEGER NOT NULL DEFAULT 1,
    seat_no        INTEGER,
    parent_line    TEXT REFERENCES sale_line(line_uuid), -- modifiers
    ordered_at     TEXT NOT NULL,
    voided         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_line_sale ON sale_line(sale_uuid, line_no);

CREATE TABLE sale_payment (
    payment_uuid   TEXT PRIMARY KEY,
    sale_uuid      TEXT NOT NULL REFERENCES sale(sale_uuid) ON DELETE CASCADE,
    methodnum      INTEGER NOT NULL REFERENCES pay_method(methodnum),
    tender         INTEGER NOT NULL,          -- halalas handed over
    change_given   INTEGER NOT NULL DEFAULT 0,
    amount         INTEGER NOT NULL,          -- applied to the bill
    auth_code      TEXT,                      -- card approval ref
    card_type      TEXT,
    paid_at        TEXT NOT NULL,
    voided         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_payment_sale ON sale_payment(sale_uuid);

-- ------------------------------------------------------------
-- OUTBOX — durable queue so nothing is lost while offline
-- ------------------------------------------------------------

CREATE TABLE outbox (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    entity         TEXT NOT NULL,             -- 'sale' | 'shift' | ...
    entity_uuid    TEXT NOT NULL,
    payload        TEXT NOT NULL,             -- JSON body to POST
    created_at     TEXT NOT NULL,
    attempts       INTEGER NOT NULL DEFAULT 0,
    next_retry_at  TEXT,
    last_error     TEXT,
    UNIQUE (entity, entity_uuid)               -- idempotent: one row per entity
);
CREATE INDEX ix_outbox_retry ON outbox(next_retry_at);

-- ------------------------------------------------------------
-- SHIFTS / CASH DRAWER
-- ------------------------------------------------------------

CREATE TABLE shift (
    shift_uuid     TEXT PRIMARY KEY,
    empnum         INTEGER NOT NULL REFERENCES employee(empnum),
    station_no     INTEGER NOT NULL,
    opened_at      TEXT NOT NULL,
    closed_at      TEXT,
    opening_float  INTEGER NOT NULL DEFAULT 0,
    declared_cash  INTEGER,
    expected_cash  INTEGER,
    sync_status    TEXT NOT NULL DEFAULT 'pending'
);

-- ------------------------------------------------------------
-- Seed: Saudi VAT
-- ------------------------------------------------------------
INSERT INTO tax_rate (tax_id, name, percent, is_inclusive)
VALUES (1, 'VAT', 15.0, 1);
