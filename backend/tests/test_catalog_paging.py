"""Catalog paging.

This exists because the first real customer's catalog is ~1,200 rows and the
endpoint used to refuse anything over 1,000 with "paging is required" - which
was never built. Loading their real menu made every device unable to sync at
all, so none of this is hypothetical.

The property that matters most is not "pages come back". It is that walking
the pages yields **every row exactly once**, and that a device which stops
half way does not lose the rows it never saw.
"""

from __future__ import annotations

import uuid

from app.config import settings
from app.db import SessionLocal
from app.models import MenuScreen, Product

from .conftest import OFFICE_PASSWORD  # noqa: F401  (keeps fixtures importable)


async def _bulk_catalog(seeded, key="a", products=0, screens=0, version=1):
    """Write rows the way a migration load does: one shared server_version.

    That sharing is the whole difficulty - a version cannot be paged through,
    so the cursor has to carry a position within it.
    """
    async with SessionLocal() as s:
        async with s.begin():
            for i in range(products):
                s.add(Product(
                    tenant_id=seeded[key]["tenant_id"],
                    branch_id=seeded[key]["branch_id"],
                    prodnum=10_000 + i,
                    descript=f"Bulk product {i}",
                    price_a=100 + i,
                    server_version=version,
                ))
            for i in range(screens):
                s.add(MenuScreen(
                    tenant_id=seeded[key]["tenant_id"],
                    branch_id=seeded[key]["branch_id"],
                    menu_id=5_000 + i,
                    name=f"Bulk screen {i}",
                    server_version=version,
                ))


def _device(seeded, key="a"):
    return {"Authorization": f"Bearer {seeded[key]['token']}"}


async def _walk(client, seeded, key="a", since=0):
    """Follow the cursor to exhaustion, as a device does."""
    rows: dict[str, list] = {}
    cursor = None
    pages = 0
    version = since

    while True:
        url = f"/v1/catalog?since={since}"
        if cursor:
            url += f"&cursor={cursor}"
        r = await client.get(url, headers=_device(seeded, key))
        assert r.status_code == 200, r.text
        body = r.json()
        pages += 1

        for name in ("products", "menu_screens", "menu_buttons", "pay_methods",
                     "staff", "tax_rates", "sales_types", "kitchen_stations"):
            rows.setdefault(name, []).extend(body[name])

        if not body["has_more"]:
            version = body["version"]
            assert body["next_cursor"] is None
            break

        assert body["next_cursor"], "has_more with no cursor is a dead end"
        # While more pages are outstanding the device must keep its old
        # watermark, or a crash mid-walk loses everything it has not fetched.
        assert body["version"] == since
        cursor = body["next_cursor"]
        assert pages < 100, "paging did not converge"

    return rows, pages, version


async def test_a_catalog_larger_than_one_page_is_served_in_full(
    client, seeded
):
    total = settings.catalog_page_size + 250
    await _bulk_catalog(seeded, products=total, version=5)

    rows, pages, version = await _walk(client, seeded)

    assert pages > 1, "a catalog this size must have paged"
    prodnums = [p["prodnum"] for p in rows["products"]]
    assert len(prodnums) == len(set(prodnums)), "a row was served twice"
    assert len({p for p in prodnums if p >= 10_000}) == total
    assert version >= 5


async def test_paging_crosses_table_boundaries_without_dropping_rows(
    client, seeded
):
    """The cursor has to survive running out of rows in one table and
    continuing into the next."""
    per = settings.catalog_page_size // 2 + 10
    await _bulk_catalog(seeded, products=per, screens=per, version=7)

    rows, pages, _ = await _walk(client, seeded)

    assert pages > 1
    assert len({p["prodnum"] for p in rows["products"] if p["prodnum"] >= 10_000}) == per
    assert len({s["menu_id"] for s in rows["menu_screens"] if s["menu_id"] >= 5_000}) == per


async def test_a_small_catalog_still_comes_back_in_one_page(client, seeded):
    r = await client.get("/v1/catalog?since=0", headers=_device(seeded))
    assert r.status_code == 200
    body = r.json()
    assert body["has_more"] is False
    assert body["next_cursor"] is None


async def test_the_watermark_only_advances_on_the_last_page(client, seeded):
    await _bulk_catalog(seeded, products=settings.catalog_page_size + 50,
                        version=9)

    first = (await client.get("/v1/catalog?since=0",
                              headers=_device(seeded))).json()
    assert first["has_more"] is True
    # Storing this would skip everything on later pages, permanently.
    assert first["version"] == 0

    _, _, final_version = await _walk(client, seeded)
    assert final_version == 9


async def test_pulling_again_from_the_new_watermark_returns_nothing(
    client, seeded
):
    await _bulk_catalog(seeded, products=settings.catalog_page_size + 20,
                        version=11)
    _, _, version = await _walk(client, seeded)

    rows, pages, _ = await _walk(client, seeded, since=version)
    assert pages == 1
    assert all(not v for v in rows.values()), "a settled device re-pulled rows"


async def test_a_malformed_cursor_is_refused_rather_than_guessed(
    client, seeded
):
    r = await client.get("/v1/catalog?since=0&cursor=nonsense",
                         headers=_device(seeded))
    assert r.status_code == 400


async def test_a_cursor_past_the_last_table_is_refused(client, seeded):
    r = await client.get("/v1/catalog?since=0&cursor=99:1:x",
                         headers=_device(seeded))
    assert r.status_code == 400


async def test_paging_never_leaks_another_tenants_rows(client, seeded):
    await _bulk_catalog(seeded, key="b",
                        products=settings.catalog_page_size + 30, version=13)

    rows, _, _ = await _walk(client, seeded, key="a")
    assert not [p for p in rows["products"] if p["prodnum"] >= 10_000]


async def test_a_cursor_from_one_tenant_is_useless_to_another(client, seeded):
    """The cursor names a row id. It must not become a way to read across
    tenants, since every page is still filtered by the caller's tenant."""
    await _bulk_catalog(seeded, key="b",
                        products=settings.catalog_page_size + 30, version=15)

    first_b = (await client.get("/v1/catalog?since=0",
                                headers=_device(seeded, "b"))).json()
    assert first_b["has_more"]

    stolen = first_b["next_cursor"]
    r = await client.get(f"/v1/catalog?since=0&cursor={stolen}",
                         headers=_device(seeded, "a"))
    assert r.status_code == 200
    assert not [p for p in r.json()["products"] if p["prodnum"] >= 10_000]
