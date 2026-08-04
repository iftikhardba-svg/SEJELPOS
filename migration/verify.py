"""Verify a migrated SQLite catalog against the PixelPoint extract.

    python verify.py --extract extracted.json --db pos.db

Checks that matter, in order of how much damage they would do if wrong:

1. Money — every price in the database equals the source price in halalas.
   A silent rounding error here misprices the menu and corrupts VAT.
2. Counts — nothing vanished between extract and load.
3. Referential integrity — no menu button points at a missing product.
4. Nothing sellable is unpriced or unnamed.

Exits non-zero if any check fails, so it can gate a real migration.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from decimal import Decimal, ROUND_HALF_UP


def to_halalas(value) -> int | None:
    if value is None:
        return None
    return int(Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP) * 100)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--extract", required=True)
    ap.add_argument("--db", required=True)
    args = ap.parse_args()

    with open(args.extract, encoding="utf-8") as fh:
        src = json.load(fh)

    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row

    failures: list[str] = []   # block the migration
    reviews: list[str] = []    # do not block, but a human must look
    notes: list[str] = []

    # -- 1. money ----------------------------------------------------------
    db_prices = {r["prodnum"]: r["price_a"]
                 for r in con.execute("SELECT prodnum, price_a FROM product")}
    mismatches = []
    for p in src["products"]:
        want = to_halalas(p["PRICEA"]) or 0
        got = db_prices.get(p["PRODNUM"])
        if got != want:
            mismatches.append((p["PRODNUM"], p["PRICEA"], want, got))
    if mismatches:
        failures.append(f"{len(mismatches)} price mismatches, e.g. {mismatches[:3]}")
    else:
        notes.append(f"prices: all {len(src['products'])} match source exactly")

    # Prove the conversion survives the values that break naive float maths.
    for sar, expect in (("4.35", 435), ("13.04", 1304), ("21.91", 2191),
                        ("0.1", 10), ("38.0", 3800)):
        if to_halalas(sar) != expect:
            failures.append(f"halala conversion wrong for {sar}")

    # -- 2. counts ---------------------------------------------------------
    expected = {
        "product": len(src["products"]),
        "menu_screen": len(src["categories"]),
        "pay_method": len(src["pay_methods"]),
        "employee": len(src["employees"]),
    }
    for table, want in expected.items():
        got = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        if got != want:
            failures.append(f"{table}: expected {want} rows, found {got}")
    if not failures:
        notes.append("counts: match source")

    # menu_buttons may legitimately be fewer — orphans are dropped on purpose.
    src_buttons = len(src["menu_buttons"])
    db_buttons = con.execute("SELECT COUNT(*) FROM menu_button").fetchone()[0]
    if db_buttons < src_buttons:
        notes.append(f"menu buttons: {db_buttons} of {src_buttons} "
                     f"({src_buttons - db_buttons} orphans dropped)")
    elif db_buttons == src_buttons:
        notes.append(f"menu buttons: all {db_buttons} retained")

    # -- 3. referential integrity ------------------------------------------
    fk = con.execute("PRAGMA foreign_key_check").fetchall()
    if fk:
        failures.append(f"{len(fk)} foreign key violations")
    else:
        notes.append("foreign keys: clean")

    orphan_buttons = con.execute("""
        SELECT COUNT(*) FROM menu_button b
        LEFT JOIN product p ON p.prodnum = b.prodnum
        WHERE p.prodnum IS NULL
    """).fetchone()[0]
    if orphan_buttons:
        failures.append(f"{orphan_buttons} menu buttons reference a missing product")

    # -- 4. sellable products are usable -----------------------------------
    unnamed = con.execute(
        "SELECT COUNT(*) FROM product WHERE descript IS NULL OR trim(descript) = ''"
    ).fetchone()[0]
    if unnamed:
        failures.append(f"{unnamed} products have no name")

    unpriced = con.execute("""
        SELECT COUNT(*) FROM product
        WHERE is_active = 1 AND is_modifier = 0 AND manual_price = 0 AND price_a = 0
    """).fetchone()[0]
    if unpriced:
        reviews.append(f"{unpriced} active non-modifier products have price 0 and "
                       "are not open-price — check these before go-live")

    # -- 5. VAT ------------------------------------------------------------
    vat = con.execute("SELECT percent, is_inclusive FROM tax_rate WHERE tax_id=1").fetchone()
    if not vat:
        failures.append("no VAT rate loaded")
    elif abs(vat["percent"] - 15.0) > 0.01 or not vat["is_inclusive"]:
        failures.append(f"VAT looks wrong: {vat['percent']}% inclusive={vat['is_inclusive']}")
    else:
        notes.append("VAT: 15.0% inclusive")

    # -- 6. staff credentials ---------------------------------------------
    with_pin = con.execute(
        "SELECT COUNT(*) FROM employee WHERE pin_hash IS NOT NULL"
    ).fetchone()[0]
    must_set = con.execute(
        "SELECT COUNT(*) FROM employee WHERE must_set_pin = 1"
    ).fetchone()[0]
    notes.append(f"staff: {with_pin} with a PIN, {must_set} must set one before login")

    con.close()

    for n in notes:
        print(f"  ok   {n}")
    for r in reviews:
        print(f"  warn {r}")
    for f in failures:
        print(f"  FAIL {f}")
    print()
    if failures:
        print(f"FAILED — {len(failures)} problem(s)")
        return 1
    if reviews:
        print(f"checks passed, {len(reviews)} item(s) need review")
    else:
        print("all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
