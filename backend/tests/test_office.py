"""The back office.

The dangerous surface here is not the UI, it is that a back-office session
carries far more authority than a device token: it reads every sale in a tenant
and rewrites prices. So most of what follows is about what a session is NOT
allowed to reach — the other tenant's anything, and the endpoints at all
without the right kind of token.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import select

from app.db import SessionLocal
from app.models import BackOfficeUser, Product, Sale, SalesType
from app.office_auth import hash_password, verify_password

from .conftest import OFFICE_PASSWORD


def office(seeded, key="a"):
    return {"Authorization": f"Bearer {seeded[key]['office_token']}"}


def device(seeded, key="a"):
    return {"Authorization": f"Bearer {seeded[key]['token']}"}


# --------------------------------------------------------------------------
# Passwords


def test_password_round_trips():
    encoded = hash_password("correct horse battery")
    assert verify_password("correct horse battery", encoded)
    assert not verify_password("wrong horse battery", encoded)


def test_the_same_password_hashes_differently_each_time():
    # Per-user salt: two people choosing the same password must not be
    # visibly identical in a stolen table.
    a = hash_password("same password")
    b = hash_password("same password")
    assert a != b
    assert verify_password("same password", a)
    assert verify_password("same password", b)


def test_a_short_password_is_refused_at_the_source():
    with pytest.raises(ValueError):
        hash_password("short")


def test_a_corrupt_hash_fails_the_login_rather_than_the_request():
    assert verify_password("anything", "not-a-real-hash") is False
    assert verify_password("anything", "scrypt$bad$bad$bad$bad$bad") is False


# --------------------------------------------------------------------------
# Sign-in


async def test_login_returns_a_working_session(client, seeded):
    r = await client.post("/v1/office/login", json={
        "email": seeded["a"]["office_email"],
        "password": OFFICE_PASSWORD,
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["role"] == "owner"
    assert body["company_name"]

    me = await client.get(
        "/v1/office/me",
        headers={"Authorization": f"Bearer {body['token']}"},
    )
    assert me.status_code == 200
    assert me.json()["email"] == seeded["a"]["office_email"]


async def test_email_is_matched_case_insensitively(client, seeded):
    r = await client.post("/v1/office/login", json={
        "email": seeded["a"]["office_email"].upper(),
        "password": OFFICE_PASSWORD,
    })
    assert r.status_code == 200


async def test_a_wrong_password_and_an_unknown_email_look_identical(
    client, seeded
):
    """Anything that distinguishes them turns the login form into a directory
    of who holds an account."""
    wrong = await client.post("/v1/office/login", json={
        "email": seeded["a"]["office_email"], "password": "not the password",
    })
    unknown = await client.post("/v1/office/login", json={
        "email": "nobody@example.sa", "password": "not the password",
    })
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json()["detail"] == unknown.json()["detail"]


async def test_a_disabled_account_cannot_sign_in(client, seeded):
    async with SessionLocal() as s:
        user = (await s.execute(
            select(BackOfficeUser).where(
                BackOfficeUser.id == seeded["a"]["office_user_id"])
        )).scalar_one()
        user.is_active = False
        await s.commit()

    r = await client.post("/v1/office/login", json={
        "email": seeded["a"]["office_email"], "password": OFFICE_PASSWORD,
    })
    assert r.status_code == 401


async def test_disabling_an_account_kills_the_session_it_already_has(
    client, seeded
):
    """Checked per request, not just at login. Otherwise revoking someone's
    access waits for their token to expire, which may be hours."""
    assert (await client.get("/v1/office/dashboard",
                             headers=office(seeded))).status_code == 200

    async with SessionLocal() as s:
        user = (await s.execute(
            select(BackOfficeUser).where(
                BackOfficeUser.id == seeded["a"]["office_user_id"])
        )).scalar_one()
        user.is_active = False
        await s.commit()

    r = await client.get("/v1/office/dashboard", headers=office(seeded))
    assert r.status_code == 403


# --------------------------------------------------------------------------
# Token separation


async def test_a_device_token_cannot_open_the_back_office(client, seeded):
    """A tablet on a counter must never hold back-office authority. Both are
    signed with the same secret, so only the token type separates them."""
    r = await client.get("/v1/office/dashboard", headers=device(seeded))
    assert r.status_code == 401
    assert "back-office" in r.json()["detail"]


async def test_an_office_token_cannot_pull_the_catalog_as_a_device(
    client, seeded
):
    r = await client.get("/v1/catalog?since=0", headers=office(seeded))
    assert r.status_code == 401


async def test_no_token_is_refused(client, seeded):
    for path in ("/v1/office/dashboard", "/v1/office/products",
                 "/v1/office/devices", "/v1/office/sales"):
        assert (await client.get(path)).status_code == 401


# --------------------------------------------------------------------------
# Tenant isolation


async def test_products_show_only_this_tenants_catalog(client, seeded):
    r = await client.get("/v1/office/products", headers=office(seeded, "a"))
    assert r.status_code == 200
    prodnums = {p["prodnum"] for p in r.json()}
    assert seeded["a"]["prodnum"] in prodnums
    assert seeded["b"]["prodnum"] not in prodnums


async def test_a_price_cannot_be_changed_across_tenants(client, seeded):
    """The id is real and the caller is a genuine owner — of the wrong
    tenant. This is the request a leaked id makes possible."""
    async with SessionLocal() as s:
        victim = (await s.execute(
            select(Product).where(Product.tenant_id == seeded["b"]["tenant_id"])
        )).scalars().first()

    r = await client.patch(
        f"/v1/office/products/{victim.id}",
        json={"price_a": 1},
        headers=office(seeded, "a"),
    )
    assert r.status_code == 404

    async with SessionLocal() as s:
        unchanged = (await s.execute(
            select(Product).where(Product.id == victim.id)
        )).scalar_one()
        assert unchanged.price_a == victim.price_a


async def test_devices_are_scoped_to_the_tenant(client, seeded):
    r = await client.get("/v1/office/devices", headers=office(seeded, "a"))
    assert r.status_code == 200
    prefixes = {d["receipt_prefix"] for d in r.json()}
    assert prefixes == {"T01"}


async def test_an_enrolment_cannot_be_minted_for_another_tenants_branch(
    client, seeded
):
    r = await client.post(
        "/v1/office/devices/enrolments",
        params={
            "branch_id": str(seeded["b"]["branch_id"]),
            "label": "Stolen till",
            "receipt_prefix": "X9",
        },
        headers=office(seeded, "a"),
    )
    # 404, not 403: a scoped lookup should not confirm the id exists.
    assert r.status_code == 404


# --------------------------------------------------------------------------
# Catalog editing


async def test_a_price_edit_bumps_the_version_so_tills_see_it(client, seeded):
    """server_version is the only thing telling a tablet there is something to
    pull. An edit that does not bump it is an edit no till ever applies."""
    listed = (await client.get("/v1/office/products",
                               headers=office(seeded))).json()
    product = listed[0]
    before = product["server_version"]

    r = await client.patch(
        f"/v1/office/products/{product['id']}",
        json={"price_a": 4200},
        headers=office(seeded),
    )
    assert r.status_code == 200, r.text
    assert r.json()["price_a"] == 4200
    assert r.json()["server_version"] > before

    # And the device pull actually carries it.
    catalog = await client.get(
        f"/v1/catalog?since={before}", headers=device(seeded)
    )
    assert catalog.status_code == 200
    prices = {p["prodnum"]: p["price_a"] for p in catalog.json()["products"]}
    assert prices[product["prodnum"]] == 4200


async def test_an_empty_patch_is_refused(client, seeded):
    listed = (await client.get("/v1/office/products",
                               headers=office(seeded))).json()
    r = await client.patch(
        f"/v1/office/products/{listed[0]['id']}",
        json={},
        headers=office(seeded),
    )
    assert r.status_code == 400


async def test_a_negative_price_is_refused(client, seeded):
    listed = (await client.get("/v1/office/products",
                               headers=office(seeded))).json()
    r = await client.patch(
        f"/v1/office/products/{listed[0]['id']}",
        json={"price_a": -100},
        headers=office(seeded),
    )
    assert r.status_code == 422


async def test_an_aggregator_tenant_cannot_leave_a_product_without_tier_b(
    client, seeded
):
    """The real cost of a missing tier B is a cashier who cannot ring a Keeta
    order at all — the till refuses rather than charging the walk-in price and
    giving away the commission. Blocking it here is where someone can fix it."""
    async with SessionLocal() as s:
        s.add(SalesType(
            tenant_id=seeded["a"]["tenant_id"],
            company_id=seeded["a"]["company_id"],
            sale_type_no=2004,
            descript="Keeta",
            price_tier="b",
            is_aggregator=True,
            requires_external_ref=True,
            server_version=1,
        ))
        await s.commit()

    listed = (await client.get("/v1/office/products",
                               headers=office(seeded))).json()
    r = await client.patch(
        f"/v1/office/products/{listed[0]['id']}",
        json={"price_b": None, "is_active": True},
        headers=office(seeded),
    )
    assert r.status_code == 400
    assert "tier B" in r.json()["detail"]


async def test_zero_priced_products_can_be_singled_out(client, seeded):
    """68 of these came through the migration and need a human decision before
    go-live. This is how that person finds them."""
    async with SessionLocal() as s:
        s.add(Product(
            tenant_id=seeded["a"]["tenant_id"],
            branch_id=seeded["a"]["branch_id"],
            prodnum=7777,
            descript="Needs a price",
            price_a=0,
            server_version=1,
        ))
        await s.commit()

    r = await client.get(
        "/v1/office/products?only_zero_price=true", headers=office(seeded)
    )
    assert r.status_code == 200
    assert [p["prodnum"] for p in r.json()] == [7777]


# --------------------------------------------------------------------------
# Enrolment and dashboard


async def test_an_enrolment_code_from_the_office_actually_enrols(
    client, seeded
):
    """The point of this endpoint: a manager adds a till without ever holding
    the installation-wide admin token."""
    r = await client.post(
        "/v1/office/devices/enrolments",
        params={
            "branch_id": str(seeded["a"]["branch_id"]),
            "label": "Second counter",
            "receipt_prefix": "T05",
        },
        headers=office(seeded),
    )
    assert r.status_code == 201, r.text
    code = r.json()["code"]

    # Randomised: device_uuid is globally unique, and the PostgreSQL test
    # database persists between runs, so a fixed value passes once and 409s
    # forever after.
    enrolled = await client.post("/v1/enrol", json={
        "code": code,
        "device_uuid": f"office-made-{uuid.uuid4().hex[:12]}",
        "platform": "windows",
    })
    assert enrolled.status_code == 200, enrolled.text
    assert enrolled.json()["receipt_prefix"] == "T05"

    devices = await client.get("/v1/office/devices", headers=office(seeded))
    assert "T05" in {d["receipt_prefix"] for d in devices.json()}


async def test_an_unknown_role_is_refused(client, seeded):
    r = await client.post(
        "/v1/office/devices/enrolments",
        params={
            "branch_id": str(seeded["a"]["branch_id"]),
            "label": "Odd one",
            "receipt_prefix": "T06",
            "role": "printer",
        },
        headers=office(seeded),
    )
    assert r.status_code == 400


async def test_the_dashboard_counts_unsigned_sales_separately(client, seeded):
    """An unsigned sale is not a queue that drains — it is an invoice that was
    never legally issued, so it gets its own number rather than hiding in a
    total."""
    import datetime as dt
    import uuid as _uuid

    today = dt.date.today()
    async with SessionLocal() as s:
        for icv, qr in ((501, "cVJ="), (502, None)):
            s.add(Sale(
                tenant_id=seeded["a"]["tenant_id"],
                company_id=seeded["a"]["company_id"],
                branch_id=seeded["a"]["branch_id"],
                device_id=seeded["a"]["device_id"],
                sale_uuid=_uuid.uuid4(),
                receipt_no=f"T01-{icv:06d}",
                opened_at=dt.datetime.now(dt.timezone.utc),
                closed_at=dt.datetime.now(dt.timezone.utc),
                business_date=today,
                sale_type=1,
                net_total=1000,
                tax_total=150,
                final_total=1150,
                status="closed",
                zatca_icv=icv,
                zatca_qr=qr,
            ))
        await s.commit()

    r = await client.get("/v1/office/dashboard", headers=office(seeded))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["sale_count"] == 2
    assert body["gross_total"] == 2300
    assert body["vat_total"] == 300
    assert body["net_total"] == 2000
    assert body["unsigned_sales"] == 1


async def test_sales_can_be_filtered_to_the_unsigned_ones(client, seeded):
    import datetime as dt
    import uuid as _uuid

    async with SessionLocal() as s:
        s.add(Sale(
            tenant_id=seeded["a"]["tenant_id"],
            company_id=seeded["a"]["company_id"],
            branch_id=seeded["a"]["branch_id"],
            device_id=seeded["a"]["device_id"],
            sale_uuid=_uuid.uuid4(),
            receipt_no="T01-000900",
            opened_at=dt.datetime.now(dt.timezone.utc),
            closed_at=dt.datetime.now(dt.timezone.utc),
            business_date=dt.date.today(),
            sale_type=1,
            net_total=100, tax_total=15, final_total=115,
            status="closed", zatca_icv=900, zatca_qr=None,
        ))
        await s.commit()

    r = await client.get(
        "/v1/office/sales?unsigned_only=true", headers=office(seeded)
    )
    assert r.status_code == 200
    assert r.json()
    assert all(not s["is_signed"] for s in r.json())


async def test_sales_never_include_another_tenants(client, seeded):
    import datetime as dt
    import uuid as _uuid

    async with SessionLocal() as s:
        s.add(Sale(
            tenant_id=seeded["b"]["tenant_id"],
            company_id=seeded["b"]["company_id"],
            branch_id=seeded["b"]["branch_id"],
            device_id=seeded["b"]["device_id"],
            sale_uuid=_uuid.uuid4(),
            receipt_no="T02-SECRET",
            opened_at=dt.datetime.now(dt.timezone.utc),
            closed_at=dt.datetime.now(dt.timezone.utc),
            business_date=dt.date.today(),
            sale_type=1,
            net_total=99999, tax_total=1, final_total=100000,
            status="closed", zatca_icv=1, zatca_qr="x",
        ))
        await s.commit()

    r = await client.get("/v1/office/sales", headers=office(seeded, "a"))
    assert r.status_code == 200
    assert "T02-SECRET" not in {s["receipt_no"] for s in r.json()}
