"""Counter flow: sale types in the catalog, aggregator refs on sales push.

This is 88% of the first customer's trade — Drive Thru, TakeAway and the
delivery aggregators — so the rules here carry more revenue than the floor plan.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest

from app import models as m
from app.db import SessionLocal

pytestmark = pytest.mark.asyncio


def auth(seeded, who="a") -> dict:
    return {"Authorization": f"Bearer {seeded[who]['token']}"}


@pytest.fixture
async def sale_types(seeded):
    """Drive Thru (tier A) and Keeta (tier B, aggregator) for tenant a."""
    t = seeded["a"]
    async with SessionLocal() as s:
        s.add(m.SalesType(
            tenant_id=t["tenant_id"], company_id=t["company_id"],
            sale_type_no=2025, descript="Drive Thru", price_tier="a",
            server_version=1,
        ))
        s.add(m.SalesType(
            tenant_id=t["tenant_id"], company_id=t["company_id"],
            sale_type_no=2004, descript="Keeta", price_tier="b",
            is_aggregator=True, requires_external_ref=True,
            server_version=1,
        ))
        await s.commit()
    return t


def make_sale(**over) -> dict:
    """38.00 SAR inclusive, one line, cash."""
    sale_uuid = str(uuid.uuid4())
    now = dt.datetime.now(dt.timezone.utc)
    base = {
        "sale_uuid": sale_uuid,
        "receipt_no": f"T01-{uuid.uuid4().hex[:6]}",
        "opened_at": now.isoformat(),
        "closed_at": now.isoformat(),
        "business_date": now.date().isoformat(),
        "num_guests": 1,
        "sale_type": 2025,
        "net_total": 3304,
        "tax_total": 496,
        "final_total": 3800,
        "status": "closed",
        "zatca_qr": "ZGVtbw==",
        "zatca_icv": 1,
        "lines": [{
            "line_uuid": str(uuid.uuid4()),
            "line_no": 1,
            "prodnum": 2008,
            "line_des": "MOUSHAKAL SABAH",
            "qty": 1,
            "unit_price": 3800,
            "net_amount": 3304,
            "tax_amount": 496,
            "line_total": 3800,
        }],
        "payments": [{
            "payment_uuid": str(uuid.uuid4()),
            "methodnum": 1001,
            "tender": 3800,
            "amount": 3800,
            "paid_at": now.isoformat(),
        }],
    }
    base.update(over)
    return base


async def test_sale_types_arrive_in_the_catalog(client, sale_types, seeded):
    r = await client.get("/v1/catalog?since=0", headers=auth(seeded))
    body = r.json()
    types = {t["sale_type_no"]: t for t in body["sales_types"]}
    assert types[2025]["price_tier"] == "a"
    assert types[2004]["price_tier"] == "b"
    assert types[2004]["is_aggregator"] is True
    assert types[2004]["requires_external_ref"] is True


async def test_catalog_ships_all_price_tiers(client, sale_types, seeded):
    """The tablet cannot charge tier B if the catalog never sent it."""
    r = await client.get("/v1/catalog?since=0", headers=auth(seeded))
    p = r.json()["products"][0]
    for tier in "abcdefghij":
        assert f"price_{tier}" in p


async def test_order_number_and_ref_are_stored(client, sale_types, seeded):
    sale = make_sale(order_no=42, external_ref="KEETA-9912", sale_type=2004)
    r = await client.post("/v1/sales", json=[sale], headers=auth(seeded))
    assert r.json()["accepted"], r.text

    status = await client.get(
        f"/v1/sales/{sale['sale_uuid']}/status", headers=auth(seeded)
    )
    assert status.status_code == 200

    async with SessionLocal() as s:
        row = await s.get(m.Sale, uuid.UUID(sale["sale_uuid"]))
        assert row.order_no == 42
        assert row.external_ref == "KEETA-9912"


async def test_aggregator_sale_without_ref_is_flagged_not_rejected(
    client, sale_types, seeded
):
    """The sale is real money and must be stored; the missing reference is a
    reconciliation problem, so it is flagged the way stale sales are."""
    sale = make_sale(sale_type=2004, external_ref=None)
    r = await client.post("/v1/sales", json=[sale], headers=auth(seeded))
    assert r.json()["accepted"], r.text

    async with SessionLocal() as s:
        row = await s.get(m.Sale, uuid.UUID(sale["sale_uuid"]))
        assert row.erp_error is not None
        assert "reconciled" in row.erp_error


async def test_walk_in_sale_without_ref_is_clean(client, sale_types, seeded):
    sale = make_sale(sale_type=2025, external_ref=None)
    r = await client.post("/v1/sales", json=[sale], headers=auth(seeded))
    assert r.json()["accepted"], r.text

    async with SessionLocal() as s:
        row = await s.get(m.Sale, uuid.UUID(sale["sale_uuid"]))
        assert row.erp_error is None


async def test_unknown_sale_type_does_not_block_the_sale(client, sale_types, seeded):
    """A device with a stale catalog may send a type the server has not seen.
    The money is still real."""
    sale = make_sale(sale_type=9999)
    r = await client.post("/v1/sales", json=[sale], headers=auth(seeded))
    assert r.json()["accepted"], r.text
