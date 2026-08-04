"""Sync API tests.

The ones that matter most are tenant isolation and idempotency: the first
protects one customer's data from another, the second protects a customer from
being charged twice by their own till.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest

pytestmark = pytest.mark.asyncio


def auth(seeded, who="a") -> dict:
    return {"Authorization": f"Bearer {seeded[who]['token']}"}


def make_sale(**over) -> dict:
    """A well-formed single-line cash sale: 38.00 SAR inclusive of 15% VAT."""
    total = over.pop("total", 3800)
    net = round(total * 100 / 115)
    tax = total - net
    sid = over.pop("sale_uuid", str(uuid.uuid4()))
    now = dt.datetime.now(dt.timezone.utc)
    sale = {
        "sale_uuid": sid,
        "receipt_no": over.pop("receipt_no", f"T01-{uuid.uuid4().hex[:6]}"),
        "opened_at": (over.pop("opened_at", now)).isoformat()
            if isinstance(over.get("opened_at", now), dt.datetime) else over.pop("opened_at"),
        "closed_at": now.isoformat(),
        "business_date": now.date().isoformat(),
        "num_guests": 2,
        "net_total": net,
        "tax_total": tax,
        "final_total": total,
        "status": "closed",
        "zatca_uuid": str(uuid.uuid4()),
        "zatca_icv": over.pop("zatca_icv", 1),
        "zatca_pih": "NWZlY2ViNjZmZmM4NmYzOGQ5NTI3ODZjNmQ2OTZjNzk=",
        "zatca_hash": "abc123",
        "zatca_qr": "AQVTZWxsZXICD1ZBVDEyMzQ1Njc4OTAx",
        "lines": [{
            "line_uuid": str(uuid.uuid4()),
            "line_no": 1,
            "prodnum": 2001,
            "line_des": "MOUSHAKAL SABAH",
            "qty": 1.0,
            "unit_price": total,
            "net_amount": net,
            "tax_amount": tax,
            "line_total": total,
        }],
        "payments": [{
            "payment_uuid": str(uuid.uuid4()),
            "methodnum": 1001,
            "tender": total,
            "change_given": 0,
            "amount": total,
            "paid_at": now.isoformat(),
        }],
    }
    sale.update(over)
    return sale


# --------------------------------------------------------------------------

async def test_health(client):
    r = await client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


async def test_catalog_requires_auth(client):
    r = await client.get("/v1/catalog")
    assert r.status_code == 401


async def test_catalog_initial_pull(client, seeded):
    r = await client.get("/v1/catalog?since=0", headers=auth(seeded))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["version"] == 1
    assert [p["prodnum"] for p in body["products"]] == [seeded["a"]["prodnum"]]
    assert len(body["menu_screens"]) == 1
    assert len(body["pay_methods"]) == 1


async def test_catalog_incremental_returns_nothing_when_current(client, seeded):
    r = await client.get("/v1/catalog?since=1", headers=auth(seeded))
    assert r.status_code == 200
    body = r.json()
    assert body["products"] == []
    # Watermark must not go backwards when there is nothing new.
    assert body["version"] == 1


async def test_catalog_never_ships_credentials(client, seeded):
    r = await client.get("/v1/catalog?since=0", headers=auth(seeded))
    staff = r.json()["staff"]
    assert staff and "pin_hash" not in staff[0]
    assert staff[0]["must_set_pin"] is True


async def test_tenant_isolation(client, seeded):
    """Tenant A's token must never surface tenant B's catalog."""
    a = await client.get("/v1/catalog?since=0", headers=auth(seeded, "a"))
    b = await client.get("/v1/catalog?since=0", headers=auth(seeded, "b"))

    a_nums = {p["prodnum"] for p in a.json()["products"]}
    b_nums = {p["prodnum"] for p in b.json()["products"]}

    assert a_nums == {seeded["a"]["prodnum"]}
    assert b_nums == {seeded["b"]["prodnum"]}
    assert not (a_nums & b_nums)


# --------------------------------------------------------------------------

async def test_push_sale(client, seeded):
    sale = make_sale()
    r = await client.post("/v1/sales", json=[sale], headers=auth(seeded))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["rejected"] == []
    assert body["accepted"][0]["status"] == "accepted"


async def test_push_is_idempotent(client, seeded):
    """A retry after a dropped connection must not create a second sale."""
    sale = make_sale(zatca_icv=51)
    first = await client.post("/v1/sales", json=[sale], headers=auth(seeded))
    second = await client.post("/v1/sales", json=[sale], headers=auth(seeded))

    assert first.json()["accepted"][0]["status"] == "accepted"
    assert second.json()["accepted"][0]["status"] == "duplicate"
    assert second.json()["rejected"] == []

    status = await client.get(
        f"/v1/sales/{sale['sale_uuid']}/status", headers=auth(seeded)
    )
    assert status.json()["found"] is True


async def test_same_uuid_different_receipt_is_rejected(client, seeded):
    """Same key, different content means a device bug — do not silently accept."""
    sid = str(uuid.uuid4())
    a = make_sale(sale_uuid=sid, receipt_no="T01-AAAAAA", zatca_icv=61)
    b = make_sale(sale_uuid=sid, receipt_no="T01-BBBBBB", zatca_icv=62)

    await client.post("/v1/sales", json=[a], headers=auth(seeded))
    r = await client.post("/v1/sales", json=[b], headers=auth(seeded))

    assert r.json()["accepted"] == []
    assert "already exists" in r.json()["rejected"][0]["error"]


async def test_reused_icv_is_rejected(client, seeded):
    """Reusing an invoice counter breaks the device's ZATCA hash chain."""
    first = make_sale(zatca_icv=777)
    clash = make_sale(zatca_icv=777)

    await client.post("/v1/sales", json=[first], headers=auth(seeded))
    r = await client.post("/v1/sales", json=[clash], headers=auth(seeded))

    assert r.json()["accepted"] == []
    assert r.json()["rejected"]


async def test_one_bad_sale_does_not_block_the_batch(client, seeded):
    """Otherwise a single poison record stalls the outbox forever."""
    good = make_sale(zatca_icv=101)
    dup_target = make_sale(zatca_icv=102)
    await client.post("/v1/sales", json=[dup_target], headers=auth(seeded))
    clash = make_sale(sale_uuid=dup_target["sale_uuid"], receipt_no="T01-OTHER",
                      zatca_icv=103)

    r = await client.post("/v1/sales", json=[clash, good], headers=auth(seeded))
    body = r.json()
    assert len(body["rejected"]) == 1
    assert len(body["accepted"]) == 1
    assert body["accepted"][0]["status"] == "accepted"


# --------------------------------------------------------------------------
# Validation — arithmetic a device must never get wrong

# Validation failures are per-sale verdicts, not a 422 for the whole batch —
# a device pushing twenty sales must get nineteen accepted and one explained.

def _only_rejection(r) -> dict:
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["accepted"] == []
    assert len(body["rejected"]) == 1
    return body["rejected"][0]


async def test_rejects_line_that_does_not_reconcile(client, seeded):
    sale = make_sale()
    sale["lines"][0]["tax_amount"] += 1          # net + tax no longer == total
    rejection = _only_rejection(
        await client.post("/v1/sales", json=[sale], headers=auth(seeded)))
    assert rejection["sale_uuid"] == sale["sale_uuid"]
    assert "net" in rejection["error"]


async def test_rejects_totals_that_do_not_sum(client, seeded):
    sale = make_sale()
    sale["final_total"] += 100
    rejection = _only_rejection(
        await client.post("/v1/sales", json=[sale], headers=auth(seeded)))
    assert "final" in rejection["error"]


async def test_rejects_payments_that_do_not_cover_total(client, seeded):
    sale = make_sale()
    sale["payments"][0]["amount"] -= 50
    rejection = _only_rejection(
        await client.post("/v1/sales", json=[sale], headers=auth(seeded)))
    assert "payments" in rejection["error"]


async def test_rejects_closed_sale_without_zatca_qr(client, seeded):
    """An unsigned closed sale means the printed receipt was not compliant."""
    sale = make_sale()
    sale["zatca_qr"] = None
    rejection = _only_rejection(
        await client.post("/v1/sales", json=[sale], headers=auth(seeded)))
    assert "ZATCA" in rejection["error"]


async def test_schema_invalid_sale_does_not_block_the_batch(client, seeded):
    """The poison-record rule holds for schema failures too, not just ingest
    failures — this is exactly what the device's outbox relies on."""
    bad = make_sale()
    bad["zatca_qr"] = None
    good = make_sale(zatca_icv=555)

    r = await client.post("/v1/sales", json=[bad, good], headers=auth(seeded))
    body = r.json()
    assert len(body["rejected"]) == 1
    assert len(body["accepted"]) == 1
    assert body["accepted"][0]["sale_uuid"] == good["sale_uuid"]


async def test_stale_sale_is_stored_but_flagged(client, seeded):
    """Past ZATCA's 24h window: record it, flag it, never drop it."""
    old = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=40)
    sale = make_sale(zatca_icv=901)
    sale["opened_at"] = old.isoformat()

    r = await client.post("/v1/sales", json=[sale], headers=auth(seeded))
    assert r.json()["accepted"][0]["status"] == "accepted"

    status = await client.get(
        f"/v1/sales/{sale['sale_uuid']}/status", headers=auth(seeded)
    )
    body = status.json()
    assert body["found"] is True
    assert "reporting window" in (body["zatca_error"] or "")


async def test_sale_status_is_tenant_scoped(client, seeded):
    """Tenant B must not be able to look up tenant A's sale."""
    sale = make_sale(zatca_icv=555)
    await client.post("/v1/sales", json=[sale], headers=auth(seeded, "a"))

    r = await client.get(
        f"/v1/sales/{sale['sale_uuid']}/status", headers=auth(seeded, "b")
    )
    assert r.json()["found"] is False
