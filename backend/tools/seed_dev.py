"""Seed a development backend database for end-to-end runs.

Creates one tenant/company/branch with a licence and a small catalog carrying
the real numbers (HUMMOS 8.00/9.00, station bits 3=Grill 5=DT), then prints the
ids the caller needs. Idempotent per run — it always starts from a fresh file,
because a dev database with history in it is a debugging session waiting to
happen.

    python tools/seed_dev.py sqlite+aiosqlite:///./dev_e2e.db
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))


async def main(database_url: str) -> None:
    os.environ["POS_DATABASE_URL"] = database_url

    from app.db import Base, SessionLocal, engine
    from app import models as m

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)

    now = dt.datetime.now(dt.timezone.utc)
    async with SessionLocal() as s:
        tenant = m.Tenant(name="Dev Restaurant Group", slug="dev")
        s.add(tenant)
        await s.flush()

        company = m.Company(
            tenant_id=tenant.id,
            name="Fatima Restaurant",
            name_ar="مطعم فاطمة",
            vat_number="310000000000003",
            address={"city": "Riyadh", "country": "SA"},
        )
        s.add(company)
        await s.flush()

        branch = m.Branch(
            tenant_id=tenant.id, company_id=company.id,
            code="ARID", name="Arid Branch",
        )
        s.add(branch)
        await s.flush()

        s.add(m.Licence(
            tenant_id=tenant.id, plan="dev", max_devices=10, max_branches=2,
            starts_at=now - dt.timedelta(days=1),
            expires_at=now + dt.timedelta(days=365),
        ))

        s.add_all([
            m.Product(tenant_id=tenant.id, branch_id=branch.id, prodnum=2013,
                      descript="HUMMOS", price_a=800, price_b=900, price_j=0,
                      print_loc=0, server_version=1),
            m.Product(tenant_id=tenant.id, branch_id=branch.id, prodnum=2152,
                      descript="Hummos Lahm", price_a=2400, price_b=2900,
                      price_j=0, print_loc=40, server_version=1),
        ])
        s.add(m.MenuScreen(tenant_id=tenant.id, branch_id=branch.id,
                           menu_id=2010, name="Appetizers", server_version=1))
        s.add_all([
            m.SalesType(tenant_id=tenant.id, company_id=company.id,
                        sale_type_no=2025, descript="Drive Thru",
                        price_tier="a", server_version=1),
            m.SalesType(tenant_id=tenant.id, company_id=company.id,
                        sale_type_no=2004, descript="Keeta", price_tier="b",
                        is_aggregator=True, requires_external_ref=True,
                        server_version=1),
        ])
        s.add_all([
            m.KitchenStation(tenant_id=tenant.id, branch_id=branch.id,
                             station_no=3, name="Grill", server_version=1),
            m.KitchenStation(tenant_id=tenant.id, branch_id=branch.id,
                             station_no=5, name="DT", server_version=1),
        ])
        s.add(m.PayMethod(tenant_id=tenant.id, company_id=company.id,
                          methodnum=1010, descript="MADA", server_version=1))
        s.add(m.Staff(tenant_id=tenant.id, branch_id=branch.id, empnum=0,
                      name="Dev Cashier", must_set_pin=True, server_version=1))
        s.add(m.TaxRate(tenant_id=tenant.id, company_id=company.id, tax_id=1,
                        name="VAT", percent=15, is_inclusive=True,
                        effective_from=dt.date(2020, 7, 1), server_version=1))

        # Menu buttons so the till's grid has something to show.
        screen = (await s.execute(
            __import__("sqlalchemy").select(m.MenuScreen)
            .where(m.MenuScreen.tenant_id == tenant.id)
        )).scalars().first()
        for pos, prodnum in enumerate([2013, 2152], start=1):
            product = (await s.execute(
                __import__("sqlalchemy").select(m.Product)
                .where(m.Product.tenant_id == tenant.id,
                       m.Product.prodnum == prodnum)
            )).scalars().first()
            s.add(m.MenuButton(
                tenant_id=tenant.id, menu_screen_id=screen.id,
                product_id=product.id, menu_id=2010, prodnum=prodnum,
                position=pos, server_version=1,
            ))

        await s.commit()
        print(json.dumps({
            "tenant_id": str(tenant.id),
            "branch_id": str(branch.id),
        }))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
