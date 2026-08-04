"""Load transformed catalog data into a tablet SQLite database.

    python load_sqlite.py --in transformed.json --db pos.db --schema ../docs/sqlite_schema.sql

Creates the database from the schema if it does not exist, then loads the
catalog. Re-running is safe: catalog rows are upserted on their business key,
because a device re-provisioned against the same branch must converge on the
same catalog rather than accumulate duplicates.

Sales tables are never touched here — this loads catalog only.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3


def ensure_schema(con: sqlite3.Connection, schema_path: str) -> None:
    have = con.execute(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='product'"
    ).fetchone()[0]
    if have:
        return
    with open(schema_path, encoding="utf-8") as fh:
        con.executescript(fh.read())


def load(con: sqlite3.Connection, data: dict) -> dict[str, int]:
    cur = con.cursor()
    counts: dict[str, int] = {}

    # Catalog rows all share one version stamp per load, which is what the
    # tablets' incremental pull compares against.
    version = (con.execute(
        "SELECT COALESCE(MAX(server_version), 0) FROM product"
    ).fetchone()[0] or 0) + 1

    cur.executemany(
        """
        INSERT INTO menu_screen (menu_id, name, sort_order, buttons_across,
                                 buttons_down, is_modifier_screen, is_active,
                                 server_version, is_deleted)
        VALUES (:menu_id, :name, :sort_order, :buttons_across, :buttons_down,
                :is_modifier_screen, :is_active, :v, :is_deleted)
        ON CONFLICT(menu_id) DO UPDATE SET
            name=excluded.name, sort_order=excluded.sort_order,
            buttons_across=excluded.buttons_across,
            buttons_down=excluded.buttons_down,
            is_modifier_screen=excluded.is_modifier_screen,
            is_active=excluded.is_active,
            server_version=excluded.server_version,
            is_deleted=excluded.is_deleted
        """,
        [dict(r, v=version) for r in data["menu_screens"]],
    )
    counts["menu_screens"] = len(data["menu_screens"])

    cur.executemany(
        """
        INSERT INTO product (prodnum, descript, print_des, price_a, price_b,
                             price_c, price_d, price_e, price_f, price_g,
                             price_h, price_i, price_j,
                             prodtype, tax_applies, is_weighed,
                             manual_price, is_modifier, print_loc, is_active,
                             ref_code, unit_des, server_version, is_deleted)
        VALUES (:prodnum, :descript, :print_des, :price_a, :price_b, :price_c,
                :price_d, :price_e, :price_f, :price_g, :price_h, :price_i,
                :price_j,
                :prodtype, :tax_applies, :is_weighed, :manual_price,
                :is_modifier, :print_loc, :is_active, :ref_code, :unit_des,
                :v, :is_deleted)
        ON CONFLICT(prodnum) DO UPDATE SET
            descript=excluded.descript, print_des=excluded.print_des,
            price_a=excluded.price_a, price_b=excluded.price_b,
            price_c=excluded.price_c, price_d=excluded.price_d,
            price_e=excluded.price_e, price_f=excluded.price_f,
            price_g=excluded.price_g, price_h=excluded.price_h,
            price_i=excluded.price_i, price_j=excluded.price_j,
            print_loc=excluded.print_loc,
            prodtype=excluded.prodtype,
            tax_applies=excluded.tax_applies, is_weighed=excluded.is_weighed,
            manual_price=excluded.manual_price, is_modifier=excluded.is_modifier,
            is_active=excluded.is_active, ref_code=excluded.ref_code,
            unit_des=excluded.unit_des, server_version=excluded.server_version,
            is_deleted=excluded.is_deleted
        """,
        [dict(r, v=version) for r in data["products"]],
    )
    counts["products"] = len(data["products"])

    cur.executemany(
        """
        INSERT INTO menu_button (id, menu_id, prodnum, position, pos_x, pos_y,
                                 caption, is_active, server_version, is_deleted)
        VALUES (:id, :menu_id, :prodnum, :position, :pos_x, :pos_y, :caption,
                :is_active, :v, :is_deleted)
        ON CONFLICT(id) DO UPDATE SET
            menu_id=excluded.menu_id, prodnum=excluded.prodnum,
            position=excluded.position, pos_x=excluded.pos_x,
            pos_y=excluded.pos_y, is_active=excluded.is_active,
            server_version=excluded.server_version, is_deleted=excluded.is_deleted
        """,
        [dict(r, v=version) for r in data["menu_buttons"]],
    )
    counts["menu_buttons"] = len(data["menu_buttons"])

    cur.executemany(
        """
        INSERT INTO pay_method (methodnum, descript, is_active, is_cash,
                                opens_drawer, sort_order, server_version, is_deleted)
        VALUES (:methodnum, :descript, :is_active, :is_cash, :opens_drawer,
                :sort_order, :v, :is_deleted)
        ON CONFLICT(methodnum) DO UPDATE SET
            descript=excluded.descript, is_active=excluded.is_active,
            is_cash=excluded.is_cash, opens_drawer=excluded.opens_drawer,
            sort_order=excluded.sort_order,
            server_version=excluded.server_version, is_deleted=excluded.is_deleted
        """,
        [dict(r, v=version) for r in data["pay_methods"]],
    )
    counts["pay_methods"] = len(data["pay_methods"])

    cur.executemany(
        """
        INSERT INTO employee (empnum, name, pin_hash, must_set_pin, sec_level,
                              ref_code, is_active, server_version, is_deleted)
        VALUES (:empnum, :name, :pin_hash, :must_set_pin, :sec_level,
                :ref_code, :is_active, :v, :is_deleted)
        ON CONFLICT(empnum) DO UPDATE SET
            name=excluded.name, sec_level=excluded.sec_level,
            ref_code=excluded.ref_code, is_active=excluded.is_active,
            server_version=excluded.server_version, is_deleted=excluded.is_deleted
        """,
        # pin_hash is deliberately NOT updated on conflict — a device that has
        # already had PINs set must not have them wiped by a catalog refresh.
        [dict(r, v=version, must_set_pin=1 if r["must_set_pin"] else 0)
         for r in data["staff"]],
    )
    counts["staff"] = len(data["staff"])

    if data.get("sales_types"):
        cur.executemany(
            """
            INSERT INTO sales_type (sale_type_no, descript, descript_ar, price_tier,
                                    is_aggregator, requires_external_ref, needs_table,
                                    default_methodnum, sort_order, is_active,
                                    server_version, is_deleted)
            VALUES (:sale_type_no, :descript, :descript_ar, :price_tier,
                    :is_aggregator, :requires_external_ref, :needs_table,
                    :default_methodnum, :sort_order, :is_active, :v, :is_deleted)
            ON CONFLICT(sale_type_no) DO UPDATE SET
                descript=excluded.descript, descript_ar=excluded.descript_ar,
                price_tier=excluded.price_tier,
                is_aggregator=excluded.is_aggregator,
                requires_external_ref=excluded.requires_external_ref,
                needs_table=excluded.needs_table,
                default_methodnum=excluded.default_methodnum,
                sort_order=excluded.sort_order, is_active=excluded.is_active,
                server_version=excluded.server_version, is_deleted=excluded.is_deleted
            """,
            [{k: v for k, v in dict(r, v=version).items()
              if k not in ("id", "tenant_id", "company_id")}
             for r in data["sales_types"]],
        )
        counts["sales_types"] = len(data["sales_types"])

    if data.get("kitchen_stations"):
        cur.executemany(
            """
            INSERT INTO kitchen_station (station_no, name, name_ar, sort_order,
                                         is_active, server_version, is_deleted)
            VALUES (:station_no, :name, :name_ar, :sort_order, :is_active,
                    :v, :is_deleted)
            ON CONFLICT(station_no) DO UPDATE SET
                name=excluded.name, name_ar=excluded.name_ar,
                sort_order=excluded.sort_order, is_active=excluded.is_active,
                server_version=excluded.server_version, is_deleted=excluded.is_deleted
            """,
            [{k: v for k, v in dict(r, v=version).items()
              if k not in ("id", "tenant_id", "branch_id")}
             for r in data["kitchen_stations"]],
        )
        counts["kitchen_stations"] = len(data["kitchen_stations"])

    if data.get("floor_sections"):
        cur.executemany(
            """
            INSERT INTO floor_section (section_id, code, name, name_ar,
                                       sort_order, is_active, server_version, is_deleted)
            VALUES (:id, :code, :name, :name_ar, :sort_order, :is_active, :v, :is_deleted)
            ON CONFLICT(section_id) DO UPDATE SET
                code=excluded.code, name=excluded.name, name_ar=excluded.name_ar,
                sort_order=excluded.sort_order, is_active=excluded.is_active,
                server_version=excluded.server_version, is_deleted=excluded.is_deleted
            """,
            [dict(r, v=version) for r in data["floor_sections"]],
        )
        counts["floor_sections"] = len(data["floor_sections"])

    if data.get("dining_tables"):
        cur.executemany(
            """
            INSERT INTO dining_table (table_id, section_id, table_no, label, seats,
                                      min_seats, max_seats, pos_x, pos_y, width,
                                      height, shape, can_reserve, is_active,
                                      server_version, is_deleted)
            VALUES (:id, :section_id, :table_no, :label, :seats, :min_seats,
                    :max_seats, :pos_x, :pos_y, :width, :height, :shape,
                    :can_reserve, :is_active, :v, :is_deleted)
            ON CONFLICT(table_id) DO UPDATE SET
                section_id=excluded.section_id, table_no=excluded.table_no,
                label=excluded.label, seats=excluded.seats,
                min_seats=excluded.min_seats, max_seats=excluded.max_seats,
                pos_x=excluded.pos_x, pos_y=excluded.pos_y,
                width=excluded.width, height=excluded.height, shape=excluded.shape,
                can_reserve=excluded.can_reserve, is_active=excluded.is_active,
                server_version=excluded.server_version, is_deleted=excluded.is_deleted
            """,
            # historical_bills is analysis, not schema — dropped before load.
            [{k: v for k, v in dict(r, v=version).items() if k != "historical_bills"}
             for r in data["dining_tables"]],
        )
        counts["dining_tables"] = len(data["dining_tables"])

    for t in data["tax_rates"]:
        cur.execute(
            """
            INSERT INTO tax_rate (tax_id, name, percent, is_inclusive, server_version)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(tax_id) DO UPDATE SET
                name=excluded.name, percent=excluded.percent,
                is_inclusive=excluded.is_inclusive,
                server_version=excluded.server_version
            """,
            (t["tax_id"], t["name"], float(t["percent"]),
             1 if t["is_inclusive"] else 0, version),
        )
    counts["tax_rates"] = len(data["tax_rates"])

    for name in ("product", "menu_screen", "menu_button", "pay_method",
                 "employee", "tax_rate"):
        cur.execute(
            """
            INSERT INTO sync_state (table_name, last_version, last_pulled_at)
            VALUES (?, ?, datetime('now'))
            ON CONFLICT(table_name) DO UPDATE SET
                last_version=excluded.last_version,
                last_pulled_at=excluded.last_pulled_at
            """,
            (name, version),
        )

    con.commit()
    return counts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--schema", required=True)
    args = ap.parse_args()

    with open(args.inp, encoding="utf-8") as fh:
        data = json.load(fh)

    fresh = not os.path.exists(args.db)
    con = sqlite3.connect(args.db)
    con.execute("PRAGMA foreign_keys = ON")
    try:
        ensure_schema(con, args.schema)
        counts = load(con, data)
    finally:
        con.close()

    print(f"loaded -> {args.db}" + ("  (created)" if fresh else "  (updated)"))
    for k, v in counts.items():
        print(f"  {k:15} {v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
