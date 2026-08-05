"""Device enrolment and order number allocation.

Enrolment is the front door of the whole fleet, so the failure cases matter
more than the happy path: a reused code, an expired code, a second device on
the same uuid, and a wrong admin token must all be dead ends.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import uuid

import pytest

from app.config import settings

pytestmark = pytest.mark.asyncio

ADMIN = {"X-Admin-Token": "test-admin-token-long-enough-123"}


def _set_admin(value) -> None:
    # Settings is a frozen dataclass on purpose; tests are the one place that
    # may bypass that, and must restore what they change.
    object.__setattr__(settings, "admin_token", value)


@pytest.fixture(autouse=True)
def _admin_token():
    old = settings.admin_token
    _set_admin(ADMIN["X-Admin-Token"])
    yield
    _set_admin(old)


def auth(seeded, who="a") -> dict:
    return {"Authorization": f"Bearer {seeded[who]['token']}"}


async def make_code(client, seeded, **over) -> dict:
    body = {
        "branch_id": str(seeded["a"]["branch_id"]),
        "label": "Waiter 3",
        "receipt_prefix": "T03",
    }
    body.update(over)
    r = await client.post("/v1/admin/enrolments", json=body, headers=ADMIN)
    assert r.status_code == 201, r.text
    return r.json()


# --------------------------------------------------------------------------
# Admin side

async def test_admin_creates_a_code(client, seeded):
    body = await make_code(client, seeded)
    assert len(body["code"]) >= 32
    assert body["role"] == "pos"


async def test_wrong_admin_token_is_refused(client, seeded):
    r = await client.post(
        "/v1/admin/enrolments",
        json={"branch_id": str(seeded["a"]["branch_id"]),
              "label": "x", "receipt_prefix": "T9"},
        headers={"X-Admin-Token": "wrong"},
    )
    assert r.status_code == 401


async def test_unset_admin_token_disables_provisioning(client, seeded):
    _set_admin(None)
    r = await client.post(
        "/v1/admin/enrolments",
        json={"branch_id": str(seeded["a"]["branch_id"]),
              "label": "x", "receipt_prefix": "T9"},
        headers=ADMIN,
    )
    assert r.status_code == 503


# --------------------------------------------------------------------------
# Device side

async def test_full_enrolment_gives_a_working_token(client, seeded):
    code = await make_code(client, seeded)
    r = await client.post("/v1/enrol", json={
        "code": code["code"],
        "device_uuid": f"tab-{uuid.uuid4().hex[:12]}",
        "platform": "android",
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["receipt_prefix"] == "T03"
    assert body["branch_name"]
    # The device invoices offline under the company's legal identity, so
    # enrolment must hand it over — there is no later chance to ask.
    assert body["seller_name"].endswith(" Co")
    assert len(body["seller_vat"]) == 15
    assert body["seller_address"]["city"] == "Riyadh"

    # The token must actually work as a device credential.
    q = await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {body['token']}"},
    )
    assert q.status_code == 200


async def test_kds_role_carries_its_station(client, seeded):
    code = await make_code(client, seeded, role="kds", kds_station_no=3,
                           label="Kitchen Grill", receipt_prefix="K1")
    r = await client.post("/v1/enrol", json={
        "code": code["code"], "device_uuid": f"kds-{uuid.uuid4().hex[:12]}",
    })
    assert r.json()["role"] == "kds"
    assert r.json()["kds_station_no"] == 3


async def test_code_is_single_use(client, seeded):
    code = await make_code(client, seeded)
    first = await client.post("/v1/enrol", json={
        "code": code["code"], "device_uuid": f"tab-{uuid.uuid4().hex[:12]}",
    })
    assert first.status_code == 200

    second = await client.post("/v1/enrol", json={
        "code": code["code"], "device_uuid": f"tab-{uuid.uuid4().hex[:12]}",
    })
    assert second.status_code == 410
    assert "already used" in second.json()["detail"]


async def test_unknown_code_is_refused(client, seeded):
    r = await client.post("/v1/enrol", json={
        "code": "x" * 43, "device_uuid": "tab-nope",
    })
    assert r.status_code == 404


async def test_same_device_cannot_enrol_twice(client, seeded):
    dev = f"tab-{uuid.uuid4().hex[:12]}"
    first = await make_code(client, seeded)
    assert (await client.post("/v1/enrol", json={
        "code": first["code"], "device_uuid": dev,
    })).status_code == 200

    second = await make_code(client, seeded)
    r = await client.post("/v1/enrol", json={
        "code": second["code"], "device_uuid": dev,
    })
    assert r.status_code == 409


# --------------------------------------------------------------------------
# Order numbers

TODAY = dt.date(2026, 8, 4)


async def test_order_numbers_are_sequential(client, seeded):
    got = []
    for _ in range(3):
        r = await client.post("/v1/orders/next",
                              json={"business_date": TODAY.isoformat()},
                              headers=auth(seeded))
        assert r.status_code == 200, r.text
        got.append(r.json()["order_no"])
    assert got == [got[0], got[0] + 1, got[0] + 2]


async def test_each_day_starts_fresh(client, seeded):
    day1 = dt.date(2026, 8, 10)
    day2 = dt.date(2026, 8, 11)
    a = (await client.post("/v1/orders/next",
                           json={"business_date": day1.isoformat()},
                           headers=auth(seeded))).json()
    b = (await client.post("/v1/orders/next",
                           json={"business_date": day2.isoformat()},
                           headers=auth(seeded))).json()
    assert a["order_no"] == 1
    assert b["order_no"] == 1


async def test_concurrent_allocations_never_collide(client, seeded):
    """Two tills asking at the same instant must get different numbers."""
    day = dt.date(2026, 8, 12)

    async def take():
        r = await client.post("/v1/orders/next",
                              json={"business_date": day.isoformat()},
                              headers=auth(seeded))
        return r.json()["order_no"]

    numbers = await asyncio.gather(*[take() for _ in range(8)])
    assert sorted(numbers) == list(range(1, 9))


async def test_order_numbers_are_tenant_scoped(client, seeded):
    day = dt.date(2026, 8, 13)
    a = (await client.post("/v1/orders/next",
                           json={"business_date": day.isoformat()},
                           headers=auth(seeded, "a"))).json()
    b = (await client.post("/v1/orders/next",
                           json={"business_date": day.isoformat()},
                           headers=auth(seeded, "b"))).json()
    # Each tenant's counter is its own; both start at 1.
    assert a["order_no"] == 1
    assert b["order_no"] == 1
