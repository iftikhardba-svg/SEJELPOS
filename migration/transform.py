"""Transform extracted PixelPoint data into the new POS schema.

    python transform.py --in extracted.json --out transformed.json \
        --tenant <uuid> --company <uuid> --branch <uuid>

Runs on any Python â€” no database driver needed.

Two things here are deliberate and worth knowing before changing them:

* **Money becomes integer halalas, via Decimal.** PixelPoint stores prices as
  C doubles. `38.0 * 100` is safe but `4.35 * 100` is 434.99999999999994, and
  truncating that loses a halala on a tax invoice. Every conversion goes through
  Decimal(str(x)) so the decimal value we saw is the decimal value we store.

* **PINs are not migrated.** The source has none worth carrying: every employee
  except `Supervisor` has a NULL login code, and Supervisor's is the vendor
  default 12345. Staff get no credential here and must have a PIN set during
  onboarding. Importing a blank or default PIN into a commercial product would
  ship an open door to every customer.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import uuid
from decimal import Decimal, ROUND_HALF_UP

# Categories whose members are modifiers rather than sellable products.
# Matched on name because PixelPoint has no flag for it.
MODIFIER_CATEGORY_HINTS = ("hold", "extra", "modify", "modifier")

# PixelPoint product type for kitchen comment/instruction buttons
# ('BBQ COMMENTS', 'SALAD COMMENTS'). They sit on ordinary menu screens and are
# always zero-priced, but they are never sold â€” treating them as products would
# put unpriced junk in the sellable catalogue.
COMMENT_PRODTYPE = 12


def to_halalas(value) -> int | None:
    """SAR (as stored by PixelPoint) -> integer halalas."""
    if value is None:
        return None
    d = Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return int(d * 100)


def truthy(v) -> bool:
    """PixelPoint uses smallint 0/1, sometimes NULL, for booleans."""
    return bool(v) and v not in (0, "0")


def tcolor_to_hex(value) -> str | None:
    """Delphi TColor -> '#RRGGBB'.

    PixelPoint is a Delphi application, so colours are stored as $00BBGGRR â€”
    the byte order is the reverse of what everyone expects, and reading it as
    RGB turns their pink buttons blue.

    Negative values are Windows *system* colours (clWindowText and friends)
    rather than literal ones. There is no honest fixed translation for those â€”
    they mean "whatever the OS theme says" â€” so they become None and the till
    falls back to its own theme, which is the same intent.
    """
    if value is None:
        return None
    try:
        raw = int(value)
    except (TypeError, ValueError):
        return None
    if raw < 0:
        return None
    return "#{:02X}{:02X}{:02X}".format(
        raw & 0xFF,          # RR is the low byte
        (raw >> 8) & 0xFF,   # GG
        (raw >> 16) & 0xFF,  # BB
    )


def button_lines(row: dict) -> str | None:
    """BUTTON1..3 joined into the label a cashier actually reads.

    Kept separate from the description on purpose: 308 of 560 products differ,
    because a tile has to fit "(BSP) broasted / strip pizza" on two lines and
    the full name does not.
    """
    lines = [
        (row.get(f"BUTTON{n}") or "").strip()
        for n in (1, 2, 3)
    ]
    text = "\n".join(line for line in lines if line)
    return text or None


def derive_vat_percent(tax_sample: list[dict]) -> Decimal | None:
    """Recover the effective VAT rate from real sales, to check our assumption."""
    rates = []
    for r in tax_sample:
        taxable = Decimal(str(r["TAX1ABLE"] or 0))
        tax = Decimal(str(r["TAX1"] or 0))
        if taxable > 0:
            rates.append((tax / taxable * 100).quantize(Decimal("0.01")))
    if not rates:
        return None
    rates.sort()
    return rates[len(rates) // 2]  # median â€” robust against rounding outliers


def transform(src: dict, tenant_id: str, company_id: str, branch_id: str) -> dict:
    warnings: list[str] = []
    now = dt.datetime.now(dt.timezone.utc).isoformat()

    # ---- sanity-check the VAT rate against actual sales -------------------
    vat = derive_vat_percent(src.get("tax_sample", []))
    if vat is None:
        vat = Decimal("15.00")
        warnings.append("No tax sample available; assuming VAT 15.00%.")
    elif abs(vat - Decimal("15.00")) > Decimal("0.10"):
        warnings.append(
            f"Derived VAT rate is {vat}%, not the expected 15%. "
            "Verify before going live â€” every price depends on this."
        )

    # ---- categories -> menu screens --------------------------------------
    cat_by_id: dict[int, dict] = {}
    menu_screens = []
    for c in src["categories"]:
        cat_id = c["ORDERCAT"]
        name = (c["DESCRIPT"] or "").strip()
        is_modifier = any(h in name.lower() for h in MODIFIER_CATEGORY_HINTS)
        rec = {
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "branch_id": branch_id,
            "menu_id": cat_id,
            "name": name or f"Category {cat_id}",
            "name_ar": None,          # not present in source; must be added later
            "sort_order": c.get("ORDERPOSITION") or 0,
            "buttons_across": c.get("ButtonAcross"),
            "buttons_down": c.get("ButtonDown"),
            # The page tile's own colours, used on the menu grid a cashier
            # lands on. Same Delphi TColor encoding as the product buttons.
            "fore_color": tcolor_to_hex(c.get("TOPCOLOUR")),
            "back_color": tcolor_to_hex(c.get("BACKCOLOUR")),
            "is_modifier_screen": is_modifier,
            "is_active": truthy(c["ISACTIVE"]),
            "is_deleted": False,
        }
        cat_by_id[cat_id] = rec
        menu_screens.append(rec)

    # ---- menus, and which pages sit where on them -------------------------
    # The level above order pages. "Default Menu" is the grid of coloured page
    # tiles a cashier lands on â€” Shawarma, Grill, Appetizer and the rest â€” and
    # it is how they get anywhere. Without it a till can only offer a flat
    # list of all 57 pages, which is not the menu anyone learned.
    menus = []
    known_menu_nos = set()
    for m in src.get("menus", []):
        menu_no = m["MENUINDEX"]
        known_menu_nos.add(menu_no)
        menus.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "branch_id": branch_id,
            "menu_no": menu_no,
            "name": (m["DESCRIPT"] or "").strip() or f"Menu {menu_no}",
            "name_ar": None,
            "revenue_centre": m.get("RevCenter"),
            "is_active": truthy(m["ISACTIVE"]),
            "is_deleted": False,
        })

    # A page can have SEVERAL rows on one menu: PixelPoint leaves the old
    # placement behind with ISACTIVE = 0 when a tile is moved. Shawarma has
    # one at (1,1) live and one at (1,8) dead. Carrying both and letting the
    # last win rebuilt the menu from its own history â€” the grid came out as
    # the layout nobody uses. Only the live placement is the tile.
    menu_pages = []
    seen: dict[tuple[int, int], dict] = {}
    superseded = 0
    for p in src.get("category_positions", []):
        menu_no = p.get("MENUINDEX")
        screen_no = p.get("ORDERCAT")
        if menu_no not in known_menu_nos or screen_no not in cat_by_id:
            # A placement pointing at a menu or page that no longer exists is
            # dead configuration, not data.
            continue
        if not truthy(p["ISACTIVE"]):
            superseded += 1
            continue

        key = (menu_no, screen_no)
        rec = {
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "branch_id": branch_id,
            "menu_no": menu_no,
            "screen_no": screen_no,
            "pos_x": p.get("PosX"),
            "pos_y": p.get("PosY"),
            "sort_order": p.get("ORDERPOS") or 0,
            "is_active": True,
            "is_deleted": False,
        }
        if key in seen:
            # Two live placements of one page on one menu. Nothing can decide
            # which tile is real, so keep the first and say so rather than
            # picking silently.
            warnings.append(
                f"Page {screen_no} is placed twice on menu {menu_no} "
                f"({seen[key]['pos_x']},{seen[key]['pos_y']}) and "
                f"({rec['pos_x']},{rec['pos_y']}). Kept the first; check the "
                "menu layout."
            )
            continue
        seen[key] = rec
        menu_pages.append(rec)

    if superseded:
        warnings.append(
            f"{superseded} menu placements were superseded in the source "
            "(the old tile left behind when one was moved) and were not "
            "imported."
        )

    placed = sum(1 for p in menu_pages if p["is_active"] and p["pos_x"])
    if menus and not placed:
        warnings.append(
            "No menu has any page placed on its grid, so a till has no menu "
            "to land on. Lay one out in the back office before go-live."
        )

    # Which products live on a modifier screen? Used to classify them below.
    modifier_cats = {cid for cid, r in cat_by_id.items() if r["is_modifier_screen"]}
    prod_cats: dict[int, set[int]] = {}
    for b in src["menu_buttons"]:
        prod_cats.setdefault(b["PRODNUM"], set()).add(b["ORDERCAT"])

    # ---- report categories -----------------------------------------------
    # PixelPoint's "Report Cat" â€” what every sales report groups by, and the
    # only real organising idea the menu has. Product.REPORTNO points here.
    report_categories = []
    known_report_nos = set()
    for c in src.get("report_categories", []):
        report_no = c["REPORTNO"]
        known_report_nos.add(report_no)
        report_categories.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "company_id": company_id,
            "report_no": report_no,
            "name": (c["DESCRIPT"] or "").strip(),
            "name_ar": None,
            # The category's own routing default. Products carry their own
            # PRINTLOC and that is what actually routes; this is kept so a
            # back office can show what the category intended.
            "default_print_loc": c.get("PRINTLOC") or 0,
            "sort_order": c.get("PrintPriority") or 0,
            "is_active": truthy(c["ISACTIVE"]),
            "is_deleted": False,
        })

    # ---- products ---------------------------------------------------------
    products = []
    prod_by_num: dict[int, dict] = {}
    orphan_products: list[int] = []   # not reachable from any menu screen
    zero_priced = 0
    for p in src["products"]:
        num = p["PRODNUM"]
        price_a = to_halalas(p["PRICEA"])
        cats = prod_cats.get(num, set())
        # Modifier if it only ever appears on modifier screens, or if PixelPoint
        # types it as a comment button. Price alone is not enough to decide â€”
        # some genuine items are legitimately open-priced.
        is_comment = p["PRODTYPE"] == COMMENT_PRODTYPE
        is_modifier = is_comment or (bool(cats) and cats.issubset(modifier_cats))
        if not cats:
            orphan_products.append(num)
        if not price_a:
            zero_priced += 1

        rec = {
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "branch_id": branch_id,
            "prodnum": num,
            "descript": (p["DESCRIPT"] or "").strip() or f"Product {num}",
            "descript_ar": None,       # absent in source â€” needed for ZATCA later
            "print_des": (p["PRINTDES"] or "").strip() or None,
            "price_a": price_a or 0,
            "price_b": to_halalas(p["PRICEB"]),
            "price_c": to_halalas(p["PRICEC"]),
            "price_d": to_halalas(p.get("PRICED")),
            "price_e": to_halalas(p.get("PRICEE")),
            "price_f": to_halalas(p.get("PRICEF")),
            "price_g": to_halalas(p.get("PRICEG")),
            "price_h": to_halalas(p.get("PRICEH")),
            "price_i": to_halalas(p.get("PRICEI")),
            "price_j": to_halalas(p.get("PRICEJ")),
            # REPORTNO is the "Report Cat" a human sets on the product screen.
            # PRODTYPE is a different, near-empty column that was mistaken for
            # it on the first pass â€” kept because it costs nothing, but it is
            # not the category.
            "report_no": p.get("REPORTNO")
            if p.get("REPORTNO") in known_report_nos else None,
            "prodtype": p["PRODTYPE"],
            # How the button looks on the till. Not decoration: 28 distinct
            # background colours is a deliberate colour-coded menu, and it is
            # how staff find an item without reading it.
            "button_text": button_lines(p),
            "fore_color": tcolor_to_hex(p.get("FORCOLOR")),
            "back_color": tcolor_to_hex(p.get("BACKCOLOR")),
            # The meal-deal prompts this item asks, in order. 0 means the
            # slot is empty — PixelPoint's "NO QUESTION".
            "questions": [
                p.get(f"QUESTION{n}") for n in (1, 2, 3, 4, 5)
                if (p.get(f"QUESTION{n}") or 0) > 0
            ],
            # PrepTemp (the "Item Type: Hot / Cold / Use Report Cat." radio)
            # is deliberately NOT carried. In this data 290 products say "use
            # the report category" and all 28 categories say "none", so not a
            # single item is marked hot or cold anywhere. Importing it would
            # add a column nothing sets and nothing reads.
            # TEXEMPT marks a product exempt from tax; TAX1 marks VAT applicable.
            "tax_applies": truthy(p["TAX1"]) and not truthy(p["TEXEMPT"]),
            "is_weighed": truthy(p["ISWEIGHED"]),
            "manual_price": truthy(p["ManualPrice"]),
            "is_modifier": is_modifier,
            "print_loc": p.get("PRINTLOC") or 0,
            "ref_code": (p["REFCODE"] or "").strip() or None,
            "unit_des": (p["UnitDes"] or "").strip() or None,
            "is_active": truthy(p["ISACTIVE"]),
            "is_deleted": False,
        }
        prod_by_num[num] = rec
        products.append(rec)

    if zero_priced:
        warnings.append(
            f"{zero_priced} products have price 0. Modifiers and comment buttons "
            "are expected here; anything else is open-price or misconfigured and "
            "should be reviewed before go-live."
        )

    if orphan_products:
        warnings.append(
            f"{len(orphan_products)} products sit on no menu screen and are "
            f"unreachable in the POS (e.g. {orphan_products[:5]}). They are "
            "imported but staff cannot ring them up â€” most look like dead "
            "catalogue entries and are candidates for deletion."
        )

    # Products marked taxable=false deserve a look â€” under Saudi VAT almost
    # everything a restaurant sells is standard-rated.
    exempt = [p["prodnum"] for p in products if not p["tax_applies"] and p["is_active"]]
    if exempt:
        warnings.append(
            f"{len(exempt)} active products are marked VAT-exempt "
            f"(e.g. {exempt[:5]}). Confirm this is correct â€” Saudi VAT exemptions "
            "are narrow."
        )

    # ---- meal-deal questions and their choices ---------------------------
    # A product can ask up to five questions; each offers choices that are
    # themselves products. 85 products use one, and without it a meal rings
    # with nothing chosen and the kitchen is told to make an empty box.
    questions = []
    known_questions = set()
    for q in src.get("questions", []):
        option = q["OPTIONINDEX"]
        known_questions.add(option)
        questions.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "company_id": company_id,
            "question_no": option,
            "prompt": (q["QUESTION"] or "").strip() or f"Question {option}",
            "prompt_ar": None,
            # FORCED 0 means the cashier may skip it. Anything else means it
            # must be answered before the item can be rung.
            "is_required": bool(q.get("FORCED")),
            # How many to pick. NUMCHOICE 1 is the common case; the Tabakat
            # platters ask for six.
            "pick_count": q.get("NUMCHOICE") or 1,
            "allow_repeats": truthy(q.get("AllowMulti")),
            "free_choices": q.get("FreeChoices") or 0,
            "is_active": truthy(q["ISACTIVE"]),
            "is_deleted": False,
        })

    question_choices = []
    for c in src.get("question_choices", []):
        option = c.get("OPTIONINDEX")
        choice = c.get("CHOICE")
        if option not in known_questions or choice not in prod_by_num:
            # A choice pointing at a question or product that no longer
            # exists cannot be offered.
            continue
        question_choices.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "company_id": company_id,
            "question_no": option,
            "prodnum": choice,
            "sort_order": c.get("Sequence") or 0,
            # PriceMode decides whether the choice adds to the bill; the
            # imported data uses a fixed price of zero throughout, so a
            # choice is included rather than charged.
            "price_mode": c.get("PriceMode") or 0,
            "fixed_price": to_halalas(c.get("FixedPrice")),
            "default_qty": c.get("DefQuan") or 1,
            "is_active": truthy(c["IsActive"]),
            "is_deleted": False,
        })

    # Items a combo always includes, with nothing to choose.
    combo_items = []
    for c in src.get("combo_items", []):
        parent = c.get("ProdLinkNum")
        child = c.get("ProdNum")
        if parent not in prod_by_num or child not in prod_by_num:
            continue
        combo_items.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "company_id": company_id,
            "parent_prodnum": parent,
            "prodnum": child,
            "sort_order": c.get("Sequence") or 0,
            "price_mode": c.get("PriceMode") or 0,
            "fixed_price": to_halalas(c.get("FixedPrice")),
            "print_it": truthy(c.get("PrintIt")),
            "is_active": truthy(c["IsActive"]),
            "is_deleted": False,
        })

    orphan_questions = sum(
        1 for p in src["products"]
        for n in (1, 2, 3, 4, 5)
        if (p.get(f"QUESTION{n}") or 0) > 0
        and p.get(f"QUESTION{n}") not in known_questions
    )
    if orphan_questions:
        warnings.append(
            f"{orphan_questions} product question slots point at a question "
            "that no longer exists; those prompts will not be asked."
        )

    # ---- menu buttons -----------------------------------------------------
    menu_buttons = []
    orphans = 0
    for b in src["menu_buttons"]:
        screen = cat_by_id.get(b["ORDERCAT"])
        product = prod_by_num.get(b["PRODNUM"])
        if screen is None or product is None:
            orphans += 1
            continue
        menu_buttons.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "menu_screen_id": screen["id"],
            "product_id": product["id"],
            "prodnum": b["PRODNUM"],
            "menu_id": b["ORDERCAT"],
            "position": b.get("PRODPOS") or 0,
            "pos_x": b.get("PosX"),
            "pos_y": b.get("PosY"),
            "caption": None,           # buttons inherit the product name
            "is_active": truthy(b["ISACTIVE"]),
            "is_deleted": False,
        })
    if orphans:
        warnings.append(
            f"{orphans} menu buttons reference a missing product or category "
            "and were dropped."
        )

    # ---- payment methods --------------------------------------------------
    pay_methods = []
    for m in src["pay_methods"]:
        name = (m["DESCRIPT"] or "").strip()
        # CURRENCY marks a cash-like tender in PixelPoint.
        is_cash = truthy(m["CURRENCY"])
        looks_like_card = any(
            k in name.lower() for k in ("visa", "master", "amex", "card", "mada", "diner")
        )
        if is_cash and looks_like_card:
            warnings.append(
                f"Payment method {m['METHODNUM']} '{name}' is flagged as cash in "
                "PixelPoint but looks like a card. Verify â€” it affects drawer "
                "behaviour and cash-up."
            )
        pay_methods.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "company_id": company_id,
            "methodnum": m["METHODNUM"],
            "descript": name or f"Method {m['METHODNUM']}",
            "descript_ar": None,
            "is_cash": is_cash,
            "opens_drawer": is_cash and not truthy(m["NoDrawer"]),
            "sort_order": m.get("DispOrder") or 0,
            "is_active": truthy(m["ISACTIVE"]),
            "is_deleted": False,
        })

    # ---- staff ------------------------------------------------------------
    # No PIN is carried over: see the module docstring.
    staff = []
    for e in src["employees"]:
        first = (e["EMPNAME"] or "").strip()
        pos = (e["POSNAME"] or "").strip()
        last = (e.get("EmpLastName") or "").strip()
        # POSNAME is usually the fuller name in this data ('MD' vs 'MD Irshad').
        name = pos if len(pos) > len(first) else " ".join(x for x in (first, last) if x)
        staff.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "branch_id": branch_id,
            "empnum": e["EMPNUM"],
            "name": name or f"Employee {e['EMPNUM']}",
            "pin_hash": None,          # must be set during onboarding
            "must_set_pin": True,
            "sec_level": e.get("SECLEVEL") or 0,
            "ref_code": (e.get("REFCODE") or "").strip() or None,
            "is_active": truthy(e["ISACTIVE"]),
            "is_deleted": False,
        })
    warnings.append(
        f"{len(staff)} staff imported without PINs â€” every one must have a PIN "
        "set before they can log in. The source had no usable credentials."
    )

    # ---- sale types -------------------------------------------------------
    # ForcePrice carries the price tier. Names identify the aggregators, because
    # PixelPoint has no flag for "this order came from a third party" â€” and that
    # distinction decides both the price charged and whether we demand the
    # platform's order reference.
    AGGREGATOR_NAMES = ("hunger", "keeta", "jahez", "marsool", "chefz",
                        "aggregator", "talabat", "ninja")
    FORCE_TO_TIER = {0: "a", 1: "a", 2: "b", 3: "c", 4: "d", 5: "e",
                     6: "f", 7: "g", 8: "h", 9: "i", 10: "j"}

    sales_types = []
    unknown_tiers = []
    for st in src.get("sales_types", []):
        name = (st["DESCRIPT"] or "").strip()
        force = st.get("ForcePrice") or 0
        tier = FORCE_TO_TIER.get(force)
        if tier is None:
            unknown_tiers.append((st["SALETYPEINDEX"], name, force))
            tier = "a"
        is_agg = any(k in name.lower() for k in AGGREGATOR_NAMES)
        sales_types.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "company_id": company_id,
            "sale_type_no": st["SALETYPEINDEX"],
            "descript": name or f"Type {st['SALETYPEINDEX']}",
            "descript_ar": None,
            "price_tier": tier,
            "is_aggregator": is_agg,
            "requires_external_ref": is_agg,
            "needs_table": name.lower().startswith("dine"),
            "default_methodnum": None,
            "sort_order": 0,
            "is_active": truthy(st["ISACTIVE"]),
            "is_deleted": False,
        })

    if unknown_tiers:
        warnings.append(
            f"{len(unknown_tiers)} sale types have a ForcePrice this importer "
            f"does not recognise (e.g. {unknown_tiers[:3]}); they were given the "
            "base price tier and must be checked â€” the wrong tier means the "
            "wrong price on every order of that type."
        )

    agg = [s["descript"] for s in sales_types if s["is_aggregator"] and s["is_active"]]
    if agg:
        warnings.append(
            f"{len(agg)} active sale types were detected as delivery aggregators "
            f"({', '.join(agg[:5])}) and will charge their configured price tier. "
            "Confirm the list â€” a missed one is charged walk-in prices and loses "
            "the commission margin."
        )

    # ---- kitchen stations -------------------------------------------------
    # Print ports become KDS stations, keeping the same numbers PRINTLOC
    # bitmasks refer to, so imported routing keeps meaning what it meant.
    kitchen_stations = []
    for port in src.get("print_ports", []):
        kitchen_stations.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "branch_id": branch_id,
            "station_no": port["PortNum"],
            "name": (port["Descr"] or "").strip(),
            "name_ar": None,
            "sort_order": port["PortNum"],
            "is_active": True,
            "is_deleted": False,
        })

    if kitchen_stations:
        station_bits = {1 << s["station_no"] for s in kitchen_stations}
        # bit 1 (value 2) is the local receipt printer â€” routed but not a station
        known_mask = sum(station_bits) | 2
        stray = sorted({
            p["prodnum"] for p in products
            if p["is_active"] and p["print_loc"] and (p["print_loc"] & ~known_mask)
        })
        if stray:
            warnings.append(
                f"{len(stray)} products route to a print port with no named "
                f"station (e.g. {stray[:5]}); those lines will not appear on any "
                "KDS screen until the station is configured."
            )

    # ---- floor plan -------------------------------------------------------
    # PixelPoint stores no table geometry (its TableDrawSetup is empty), so the
    # floor has to be laid out here and rearranged by the customer afterwards.
    # A tidy grid beats scattering them: staff recognise "row 3, fourth along".
    used = {r["TABLENUM"]: r["bills"] for r in src.get("table_usage", [])}

    sections_by_num: dict[int, dict] = {}
    dining_tables = []
    per_row = 10
    # Tables the restaurant actually uses are laid out first and together.
    # Ordering by table number alone scatters the eleven live ones across a grid
    # of 150, leaving a plan full of holes that nobody can read.
    ordered = sorted(
        src.get("tables", []),
        key=lambda r: (r["TABLENUM"] not in used, r["TABLENUM"]),
    )
    for idx, t in enumerate(ordered):
        sec_num = t["SECNUM"]
        if sec_num not in sections_by_num:
            sections_by_num[sec_num] = {
                "id": str(uuid.uuid4()),
                "tenant_id": tenant_id,
                "branch_id": branch_id,
                "code": f"SEC{sec_num}",
                "name": f"Section {sec_num}",
                "name_ar": None,
                "sort_order": len(sections_by_num),
                "is_active": True,
                "is_deleted": False,
            }

        seats = t.get("NUMCUSTOMER") or 2
        # Wider footprint for bigger tables so the plan reads at a glance.
        width = 2 if seats <= 2 else (3 if seats <= 4 else 4)

        dining_tables.append({
            "id": str(uuid.uuid4()),
            "tenant_id": tenant_id,
            "branch_id": branch_id,
            "section_id": sections_by_num[sec_num]["id"],
            "table_no": t["TABLENUM"],
            "label": (t.get("Descr") or "").strip() or None,
            "seats": seats,
            "min_seats": t.get("MINNUMCUST"),
            "max_seats": t.get("MAXNUMCUST") or seats,
            "pos_x": (idx % per_row) * 5,
            "pos_y": (idx // per_row) * 4,
            "width": width,
            "height": 2,
            "shape": "round" if seats <= 2 else "rect",
            "can_reserve": truthy(t.get("CANRESERVE")),
            # Configured but never used in years of trading. Imported inactive
            # so the floor plan reflects the restaurant rather than the file.
            "is_active": t["TABLENUM"] in used,
            "is_deleted": False,
            "historical_bills": used.get(t["TABLENUM"], 0),
        })

    if dining_tables:
        live = sum(1 for t in dining_tables if t["is_active"])
        dead = len(dining_tables) - live
        if dead:
            warnings.append(
                f"{dead} of {len(dining_tables)} tables have never been used in "
                f"any recorded sale and were imported inactive; {live} are live. "
                "Activate any that are genuinely in service."
            )

    # ---- tax --------------------------------------------------------------
    tax_rates = [{
        "id": str(uuid.uuid4()),
        "tenant_id": tenant_id,
        "company_id": company_id,
        "tax_id": 1,
        "name": "VAT",
        "percent": str(vat),
        "is_inclusive": True,
        "effective_from": "2020-07-01",   # when KSA VAT went to 15%
        "effective_to": None,
    }]

    return {
        "generated_at": now,
        "source_extracted_at": src.get("extracted_at"),
        "tenant_id": tenant_id,
        "company_id": company_id,
        "branch_id": branch_id,
        "vat_percent": str(vat),
        "menus": menus,
        "menu_pages": menu_pages,
        "questions": questions,
        "question_choices": question_choices,
        "combo_items": combo_items,
        "menu_screens": menu_screens,
        "report_categories": report_categories,
        "products": products,
        "menu_buttons": menu_buttons,
        "pay_methods": pay_methods,
        "staff": staff,
        "tax_rates": tax_rates,
        "sales_types": sales_types,
        "kitchen_stations": kitchen_stations,
        "floor_sections": list(sections_by_num.values()),
        "dining_tables": dining_tables,
        "warnings": warnings,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tenant", default=str(uuid.uuid4()))
    ap.add_argument("--company", default=str(uuid.uuid4()))
    ap.add_argument("--branch", default=str(uuid.uuid4()))
    args = ap.parse_args()

    with open(args.inp, encoding="utf-8") as fh:
        src = json.load(fh)

    out = transform(src, args.tenant, args.company, args.branch)

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)

    print(f"transformed -> {args.out}")
    for key in ("menu_screens", "products", "menu_buttons", "pay_methods",
                "staff", "sales_types", "kitchen_stations", "floor_sections",
                "dining_tables"):
        print(f"  {key:15} {len(out[key])}")
    print(f"  VAT             {out['vat_percent']}%")
    if out["warnings"]:
        print("\nwarnings:")
        for w in out["warnings"]:
            print(f"  - {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
