"""Load a transformed catalog into the multi-tenant backend.

    python load_backend.py --in out/transformed.json \
        --database-url sqlite+aiosqlite:///../backend/validate.db \
        --tenant-slug fatima --company "Fatima Restaurant" --branch "Arid Branch"

`load_sqlite.py` produces a tablet-shaped database, which is useful for testing
the app in isolation but is a dead end for a real customer: devices pull their
catalog from the backend, so a catalog that never reaches the backend never
reaches a till. This is the other half of that path.

Re-running is safe. Every row is upserted on its business key, and the whole
load shares one `server_version` stamp - the counter tablets compare against.
Bumping it once per load rather than once per row means a device that pulls
mid-load never sees half a catalog.

Sales tables are never touched. This loads catalog only.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import os
import pathlib
import sys

sys.path.insert(
    0, str(pathlib.Path(__file__).resolve().parent.parent / "backend")
)


def _int(value, default=0):
    return default if value is None else int(value)


def _bool(value, default=False):
    return default if value is None else bool(value)


async def load(data: dict, *, tenant_slug: str, company_name: str,
               branch_name: str, vat_number: str, branch_code: str,
               office_email: str | None = None,
               office_password: str | None = None) -> dict:
    from sqlalchemy import func, select

    from app.db import Base, SessionLocal, engine
    from app import models as m
    from app.office_auth import hash_password

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    counts: dict[str, int] = {}
    now = dt.datetime.now(dt.timezone.utc)

    async with SessionLocal() as s:
        async with s.begin():
            tenant = (await s.execute(
                select(m.Tenant).where(m.Tenant.slug == tenant_slug)
            )).scalar_one_or_none()
            if tenant is None:
                tenant = m.Tenant(name=company_name, slug=tenant_slug)
                s.add(tenant)
                await s.flush()

            company = (await s.execute(
                select(m.Company).where(
                    m.Company.tenant_id == tenant.id,
                    m.Company.vat_number == vat_number,
                )
            )).scalar_one_or_none()
            if company is None:
                company = m.Company(
                    tenant_id=tenant.id,
                    name=company_name,
                    vat_number=vat_number,
                    # ZATCA requires a structured seller address on every
                    # invoice. PixelPoint holds nothing usable, so this is a
                    # placeholder the customer MUST replace before go-live -
                    # see the warning printed at the end.
                    address={"city": "Riyadh", "country": "SA"},
                )
                s.add(company)
                await s.flush()

            branch = (await s.execute(
                select(m.Branch).where(
                    m.Branch.tenant_id == tenant.id,
                    m.Branch.code == branch_code,
                )
            )).scalar_one_or_none()
            if branch is None:
                branch = m.Branch(
                    tenant_id=tenant.id, company_id=company.id,
                    code=branch_code, name=branch_name,
                )
                s.add(branch)
                await s.flush()

            if not (await s.execute(
                select(func.count(m.Licence.id)).where(
                    m.Licence.tenant_id == tenant.id)
            )).scalar():
                s.add(m.Licence(
                    tenant_id=tenant.id, plan="migrated",
                    max_devices=20, max_branches=5,
                    starts_at=now - dt.timedelta(days=1),
                    expires_at=now + dt.timedelta(days=365),
                ))

            # One stamp for the whole load: a device pulling while this runs
            # gets either the old catalog or the new one, never a mixture.
            version = ((await s.execute(
                select(func.max(m.Product.server_version)).where(
                    m.Product.tenant_id == tenant.id)
            )).scalar() or 0) + 1

            tid, cid, bid = tenant.id, company.id, branch.id

            # Without an account, a freshly migrated customer has a catalog
            # they cannot see and no way to add a till. Created here rather
            # than by a separate step, because forgetting it leaves the
            # migration technically complete and practically unusable.
            if office_email and office_password:
                existing_user = (await s.execute(
                    select(m.BackOfficeUser).where(
                        func.lower(m.BackOfficeUser.email)
                        == office_email.strip().lower()
                    )
                )).scalar_one_or_none()
                if existing_user is None:
                    s.add(m.BackOfficeUser(
                        tenant_id=tid,
                        email=office_email.strip().lower(),
                        name=f"{company_name} Owner",
                        role="owner",
                        password_hash=hash_password(office_password),
                    ))
                    await s.flush()

            async def upsert(model, rows, keys: list[str], fields: dict):
                """Update the row matching `keys`, or insert it."""
                made = 0
                for row in rows:
                    values = {name: fn(row) for name, fn in fields.items()}
                    where = [getattr(model, k) == values[k] for k in keys]
                    where.append(model.tenant_id == tid)
                    existing = (await s.execute(
                        select(model).where(*where)
                    )).scalar_one_or_none()
                    if existing is None:
                        s.add(model(tenant_id=tid, **values))
                    else:
                        for name, value in values.items():
                            setattr(existing, name, value)
                    made += 1
                await s.flush()
                return made

            counts["menu_screens"] = await upsert(
                m.MenuScreen, data["menu_screens"], ["menu_id"], {
                    "branch_id": lambda r: bid,
                    "menu_id": lambda r: _int(r["menu_id"]),
                    "name": lambda r: r["name"],
                    "sort_order": lambda r: _int(r.get("sort_order")),
                    "buttons_across": lambda r: r.get("buttons_across"),
                    "buttons_down": lambda r: r.get("buttons_down"),
                    "is_modifier_screen": lambda r: _bool(
                        r.get("is_modifier_screen")),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "is_deleted": lambda r: _bool(r.get("is_deleted")),
                    "server_version": lambda r: version,
                })

            counts["report_categories"] = await upsert(
                m.ReportCategory, data.get("report_categories", []),
                ["report_no"], {
                    "company_id": lambda r: cid,
                    "report_no": lambda r: _int(r["report_no"]),
                    "name": lambda r: r["name"],
                    "name_ar": lambda r: r.get("name_ar"),
                    "default_print_loc": lambda r: _int(r.get("default_print_loc")),
                    "sort_order": lambda r: _int(r.get("sort_order")),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "is_deleted": lambda r: _bool(r.get("is_deleted")),
                    "server_version": lambda r: version,
                })

            counts["products"] = await upsert(
                m.Product, data["products"], ["prodnum"], {
                    "branch_id": lambda r: bid,
                    "prodnum": lambda r: _int(r["prodnum"]),
                    "descript": lambda r: r["descript"],
                    "descript_ar": lambda r: r.get("descript_ar"),
                    "print_des": lambda r: r.get("print_des"),
                    **{
                        f"price_{c}": (lambda c: lambda r: r.get(f"price_{c}"))(c)
                        for c in "abcdefghij"
                    },
                    "price_a": lambda r: _int(r.get("price_a")),
                    "report_no": lambda r: r.get("report_no"),
                    "prodtype": lambda r: r.get("prodtype"),
                    "tax_applies": lambda r: _bool(r.get("tax_applies"), True),
                    "is_weighed": lambda r: _bool(r.get("is_weighed")),
                    "manual_price": lambda r: _bool(r.get("manual_price")),
                    "is_modifier": lambda r: _bool(r.get("is_modifier")),
                    "print_loc": lambda r: _int(r.get("print_loc")),
                    "ref_code": lambda r: r.get("ref_code"),
                    "unit_des": lambda r: r.get("unit_des"),
                    "button_text": lambda r: r.get("button_text"),
                    "fore_color": lambda r: r.get("fore_color"),
                    "back_color": lambda r: r.get("back_color"),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "is_deleted": lambda r: _bool(r.get("is_deleted")),
                    "server_version": lambda r: version,
                })

            # Buttons carry real foreign keys, so the screens and products
            # they point at have to exist first.
            screens = {
                row.menu_id: row.id for row in (await s.execute(
                    select(m.MenuScreen).where(m.MenuScreen.tenant_id == tid)
                )).scalars()
            }
            products = {
                row.prodnum: row.id for row in (await s.execute(
                    select(m.Product).where(m.Product.tenant_id == tid)
                )).scalars()
            }

            buttons = [
                b for b in data["menu_buttons"]
                if _int(b["menu_id"]) in screens
            ]
            orphans = len(data["menu_buttons"]) - len(buttons)
            counts["menu_buttons"] = await upsert(
                m.MenuButton, buttons, ["menu_id", "prodnum"], {
                    "menu_screen_id": lambda r: screens[_int(r["menu_id"])],
                    "product_id": lambda r: products.get(_int(r["prodnum"])),
                    "menu_id": lambda r: _int(r["menu_id"]),
                    "prodnum": lambda r: _int(r["prodnum"]),
                    "position": lambda r: _int(r.get("position")),
                    "pos_x": lambda r: r.get("pos_x"),
                    "pos_y": lambda r: r.get("pos_y"),
                    "caption": lambda r: r.get("caption"),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "is_deleted": lambda r: _bool(r.get("is_deleted")),
                    "server_version": lambda r: version,
                })

            counts["pay_methods"] = await upsert(
                m.PayMethod, data["pay_methods"], ["methodnum"], {
                    "company_id": lambda r: cid,
                    "methodnum": lambda r: _int(r["methodnum"]),
                    "descript": lambda r: r["descript"],
                    "descript_ar": lambda r: r.get("descript_ar"),
                    "is_cash": lambda r: _bool(r.get("is_cash")),
                    "opens_drawer": lambda r: _bool(r.get("opens_drawer")),
                    "sort_order": lambda r: _int(r.get("sort_order")),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "is_deleted": lambda r: _bool(r.get("is_deleted")),
                    "server_version": lambda r: version,
                })

            counts["sales_types"] = await upsert(
                m.SalesType, data["sales_types"], ["sale_type_no"], {
                    "company_id": lambda r: cid,
                    "sale_type_no": lambda r: _int(r["sale_type_no"]),
                    "descript": lambda r: r["descript"],
                    "descript_ar": lambda r: r.get("descript_ar"),
                    "price_tier": lambda r: r.get("price_tier", "a"),
                    "is_aggregator": lambda r: _bool(r.get("is_aggregator")),
                    "requires_external_ref": lambda r: _bool(
                        r.get("requires_external_ref")),
                    "needs_table": lambda r: _bool(r.get("needs_table")),
                    "default_methodnum": lambda r: r.get("default_methodnum"),
                    "sort_order": lambda r: _int(r.get("sort_order")),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "is_deleted": lambda r: _bool(r.get("is_deleted")),
                    "server_version": lambda r: version,
                })

            counts["staff"] = await upsert(
                m.Staff, data["staff"], ["empnum"], {
                    "branch_id": lambda r: bid,
                    "empnum": lambda r: _int(r["empnum"]),
                    "name": lambda r: r["name"],
                    # Migrated staff arrive with no credential and must set a
                    # PIN before they can log in.
                    "pin_hash": lambda r: None,
                    "must_set_pin": lambda r: True,
                    "sec_level": lambda r: _int(r.get("sec_level")),
                    "ref_code": lambda r: r.get("ref_code"),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "is_deleted": lambda r: _bool(r.get("is_deleted")),
                    "server_version": lambda r: version,
                })

            counts["kitchen_stations"] = await upsert(
                m.KitchenStation, data["kitchen_stations"], ["station_no"], {
                    "branch_id": lambda r: bid,
                    "station_no": lambda r: _int(r["station_no"]),
                    "name": lambda r: r["name"],
                    "name_ar": lambda r: r.get("name_ar"),
                    "sort_order": lambda r: _int(r.get("sort_order")),
                    "is_active": lambda r: _bool(r.get("is_active"), True),
                    "server_version": lambda r: version,
                })

            counts["tax_rates"] = await upsert(
                m.TaxRate, data["tax_rates"], ["tax_id"], {
                    "company_id": lambda r: cid,
                    "tax_id": lambda r: _int(r["tax_id"]),
                    "name": lambda r: r["name"],
                    "percent": lambda r: r["percent"],
                    "is_inclusive": lambda r: _bool(r.get("is_inclusive"), True),
                    "effective_from": lambda r: dt.date.fromisoformat(
                        str(r.get("effective_from", "2020-07-01"))[:10]),
                    "server_version": lambda r: version,
                })

    return {
        "tenant_id": str(tid),
        "company_id": str(cid),
        "branch_id": str(bid),
        "server_version": version,
        "loaded": counts,
        "orphan_buttons_skipped": orphans,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default="out/transformed.json")
    ap.add_argument("--database-url", required=True)
    ap.add_argument("--tenant-slug", required=True)
    ap.add_argument("--company", required=True)
    ap.add_argument("--branch", required=True)
    ap.add_argument("--branch-code", default="MAIN")
    ap.add_argument("--vat-number", required=True,
                    help="15 digits, as registered with ZATCA")
    ap.add_argument("--office-email",
                    help="create a back-office owner account for this tenant")
    ap.add_argument("--office-password",
                    help="password for --office-email (at least 8 characters)")
    args = ap.parse_args()

    if bool(args.office_email) != bool(args.office_password):
        raise SystemExit(
            "--office-email and --office-password go together"
        )

    if len(args.vat_number) != 15 or not args.vat_number.isdigit():
        raise SystemExit("VAT registration number must be 15 digits")

    # Set before importing app.db: settings is frozen at import time.
    os.environ["POS_DATABASE_URL"] = args.database_url

    with open(args.src, encoding="utf-8") as fh:
        data = json.load(fh)

    result = asyncio.run(load(
        data,
        tenant_slug=args.tenant_slug,
        company_name=args.company,
        branch_name=args.branch,
        branch_code=args.branch_code,
        vat_number=args.vat_number,
        office_email=args.office_email,
        office_password=args.office_password,
    ))

    products = data["products"]
    zero = [
        p for p in products
        if p.get("is_active") and not p.get("is_modifier")
        and not p.get("price_a")
    ]
    result["review"] = {
        "active_products_priced_zero": len(zero),
        "seller_address_is_placeholder": True,
    }
    print(json.dumps(result, indent=2))

    if zero:
        print(
            f"\nWARNING: {len(zero)} active products have no walk-in price. "
            "They will ring at 0.00. Find them in the back office under "
            "Products -> Priced zero.",
            file=sys.stderr,
        )
    print(
        "WARNING: the company address is a placeholder. ZATCA requires a real "
        "structured seller address on every invoice - set it before go-live.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
