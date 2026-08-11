"""Floor plan, table sessions and reservations.

The cases that matter are the ones a busy service actually produces: two waiters
tapping the same table, a retry after a dropped connection, and a table closed
without a bill.
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


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


@pytest.fixture
async def floor(seeded):
    """A small floor: one section, three tables of 2, 4 and 6 seats."""
    t = seeded["a"]
    async with SessionLocal() as s:
        section = m.FloorSection(
            tenant_id=t["tenant_id"], branch_id=t["branch_id"],
            code="MAIN", name="Main Hall", server_version=1,
        )
        s.add(section)
        await s.flush()

        tables = []
        for i, seats in enumerate([2, 4, 6], start=1):
            tb = m.DiningTable(
                tenant_id=t["tenant_id"], branch_id=t["branch_id"],
                section_id=section.id, table_no=i, seats=seats,
                max_seats=seats, pos_x=i * 3, pos_y=0, server_version=1,
            )
            s.add(tb)
            tables.append(tb)
        await s.flush()
        ids = [tb.id for tb in tables]
        await s.commit()

    return {
        "section_id": section.id,
        "table_ids": ids,
        "headers": auth(seeded, "a"),
        **t,
    }


async def test_floor_lists_every_table_as_free(client, floor):
    r = await client.get("/v1/floor", headers=floor["headers"])
    assert r.status_code == 200
    body = r.json()
    assert len(body["sections"]) == 1
    assert len(body["tables"]) == 3
    assert {t["status"] for t in body["tables"]} == {"free"}
    assert [t["seats"] for t in body["tables"]] == [2, 4, 6]


async def test_open_table_then_it_shows_as_open(client, floor):
    tid = str(floor["table_ids"][1])
    r = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 3}, headers=floor["headers"]
    )
    assert r.status_code == 200, r.text
    assert r.json()["guests"] == 3

    r = await client.get("/v1/floor", headers=floor["headers"])
    opened = [t for t in r.json()["tables"] if t["id"] == tid][0]
    assert opened["status"] == "open"
    assert opened["guests"] == 3


async def test_the_floor_says_who_is_here_and_who_is_nearly_done(client, floor):
    """The two things a host reads a room by, beyond free and busy."""
    tid = str(floor["table_ids"][1])
    opened = await client.post(
        f"/v1/tables/{tid}/open",
        json={"guests": 3, "opened_by": "Fatima"},
        headers=floor["headers"],
    )
    assert opened.status_code == 200, opened.text
    session_id = opened.json()["session_id"]

    r = await client.post(
        f"/v1/sessions/{session_id}/done-soon", headers=floor["headers"]
    )
    assert r.status_code == 200, r.text
    assert r.json()["done_soon"] is True

    table = [
        t for t in (await client.get(
            "/v1/floor", headers=floor["headers"])).json()["tables"]
        if t["id"] == tid
    ][0]
    assert table["done_soon"] is True
    assert table["opened_by"] == "Fatima"

    # And it comes off again — a party that ordered another round is not
    # leaving after all.
    await client.post(
        f"/v1/sessions/{session_id}/done-soon?done=false",
        headers=floor["headers"],
    )
    table = [
        t for t in (await client.get(
            "/v1/floor", headers=floor["headers"])).json()["tables"]
        if t["id"] == tid
    ][0]
    assert table["done_soon"] is False


async def test_a_settled_table_cannot_be_marked_nearly_done(client, floor):
    tid = str(floor["table_ids"][0])
    opened = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )
    session_id = opened.json()["session_id"]
    await client.post(
        f"/v1/sessions/{session_id}/close", headers=floor["headers"]
    )

    r = await client.post(
        f"/v1/sessions/{session_id}/done-soon", headers=floor["headers"]
    )
    assert r.status_code == 409


async def test_the_office_sets_up_the_areas_a_restaurant_works_in(
    client, floor, seeded
):
    """Ground floor, terrace, family, smoking: a restaurant is not one room.

    The migration can only produce what PixelPoint held — one section — so the
    areas a customer actually works in have to be set up here.
    """
    office = {"Authorization": f"Bearer {seeded['a']['office_token']}"}

    r = await client.post(
        "/v1/office/floor-sections",
        json={"code": "TERRACE", "name": "Terrace", "sort_order": 2},
        headers=office,
    )
    assert r.status_code == 201, r.text
    terrace = r.json()["id"]

    # Codes identify an area; two of them is a table nobody can place.
    again = await client.post(
        "/v1/office/floor-sections",
        json={"code": "terrace", "name": "Terrace 2"},
        headers=office,
    )
    assert again.status_code == 409

    r = await client.post(
        "/v1/office/tables",
        json={"section_id": terrace, "table_no": 201, "seats": 4,
              "pos_x": 0, "pos_y": 0, "shape": "round"},
        headers=office,
    )
    assert r.status_code == 201, r.text
    table_id = r.json()["id"]

    sections = (await client.get(
        "/v1/office/floor-sections", headers=office)).json()
    terrace_row = [s for s in sections if s["id"] == terrace][0]
    assert terrace_row["table_count"] == 1
    assert terrace_row["seat_count"] == 4

    # The till sees it on the floor immediately — this is live state, not
    # catalog, so there is nothing to pull.
    tables = (await client.get(
        "/v1/floor", headers=floor["headers"])).json()["tables"]
    assert 201 in [t["table_no"] for t in tables]

    # An area cannot be closed with tables still in it.
    r = await client.patch(
        f"/v1/office/floor-sections/{terrace}",
        json={"is_active": False},
        headers=office,
    )
    assert r.status_code == 400
    assert "still has 1 tables" in r.json()["detail"]

    # Take the table out of service, and then it can be.
    await client.patch(
        f"/v1/office/tables/{table_id}", json={"is_active": False},
        headers=office,
    )
    r = await client.patch(
        f"/v1/office/floor-sections/{terrace}",
        json={"is_active": False},
        headers=office,
    )
    assert r.status_code == 200, r.text


async def test_a_closed_area_is_off_the_till(client, floor, seeded):
    """A closed area on the till is a tab that opens onto nothing — and if it
    sorts first, it is what the floor opens on."""
    office = {"Authorization": f"Bearer {seeded['a']['office_token']}"}
    made = await client.post(
        "/v1/office/floor-sections",
        json={"code": "ROOF", "name": "Roof garden", "sort_order": 0},
        headers=office,
    )
    area = made.json()["id"]

    names = [s["name"] for s in (await client.get(
        "/v1/floor", headers=floor["headers"])).json()["sections"]]
    assert "Roof garden" in names

    await client.patch(f"/v1/office/floor-sections/{area}",
                       json={"is_active": False}, headers=office)

    names = [s["name"] for s in (await client.get(
        "/v1/floor", headers=floor["headers"])).json()["sections"]]
    assert "Roof garden" not in names


async def test_a_table_in_use_is_not_moved_under_the_party(client, floor, seeded):
    office = {"Authorization": f"Bearer {seeded['a']['office_token']}"}
    tid = str(floor["table_ids"][0])
    await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )

    r = await client.patch(
        f"/v1/office/tables/{tid}", json={"is_active": False}, headers=office
    )
    assert r.status_code == 409
    assert "in use" in r.json()["detail"]

    # Renaming it is fine — that does not move anybody.
    r = await client.patch(
        f"/v1/office/tables/{tid}", json={"label": "By the window"},
        headers=office,
    )
    assert r.status_code == 200, r.text
    assert r.json()["in_use"] is True


async def test_two_twos_make_a_four(client, floor):
    """Four people, two tables of two. One party, one order, one bill."""
    first, second = str(floor["table_ids"][0]), str(floor["table_ids"][1])

    opened = await client.post(
        f"/v1/tables/{first}/open", json={"guests": 2}, headers=floor["headers"]
    )
    session_id = opened.json()["session_id"]

    r = await client.post(
        f"/v1/sessions/{session_id}/tables/{second}?guests=4",
        headers=floor["headers"],
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["guests"] == 4
    assert body["seats"] == 6            # a two and a four in the fixture
    assert len(body["party_table_nos"]) == 2

    # Both tables read as the same party, so tapping either reaches the bill.
    tables = (await client.get("/v1/floor", headers=floor["headers"])).json()[
        "tables"
    ]
    joined = [t for t in tables if t["id"] in (first, second)]
    assert {t["status"] for t in joined} == {"open"}
    assert {t["session_id"] for t in joined} == {session_id}
    assert all(len(t["party_table_nos"]) == 2 for t in joined)


async def test_a_merged_table_cannot_be_taken_by_someone_else(client, floor):
    first, second = str(floor["table_ids"][0]), str(floor["table_ids"][1])
    opened = await client.post(
        f"/v1/tables/{first}/open", json={"guests": 2}, headers=floor["headers"]
    )
    session_id = opened.json()["session_id"]
    await client.post(
        f"/v1/sessions/{session_id}/tables/{second}", headers=floor["headers"]
    )

    # Another waiter tries to seat the half that was pushed over.
    r = await client.post(
        f"/v1/tables/{second}/open", json={"guests": 2}, headers=floor["headers"]
    )
    assert r.status_code == 409

    # And a second party cannot merge it either.
    third = str(floor["table_ids"][2])
    other = await client.post(
        f"/v1/tables/{third}/open", json={"guests": 2}, headers=floor["headers"]
    )
    r = await client.post(
        f"/v1/sessions/{other.json()['session_id']}/tables/{second}",
        headers=floor["headers"],
    )
    assert r.status_code == 409
    assert "another party" in r.json()["detail"]


async def test_a_party_cannot_be_bigger_than_the_tables_together(client, floor):
    first, second = str(floor["table_ids"][0]), str(floor["table_ids"][1])
    opened = await client.post(
        f"/v1/tables/{first}/open", json={"guests": 2}, headers=floor["headers"]
    )
    r = await client.post(
        f"/v1/sessions/{opened.json()['session_id']}/tables/{second}?guests=9",
        headers=floor["headers"],
    )
    assert r.status_code == 400
    assert "seat 6" in r.json()["detail"]


async def test_paying_gives_both_tables_back(client, floor):
    first, second = str(floor["table_ids"][0]), str(floor["table_ids"][1])
    opened = await client.post(
        f"/v1/tables/{first}/open", json={"guests": 2}, headers=floor["headers"]
    )
    session_id = opened.json()["session_id"]
    await client.post(
        f"/v1/sessions/{session_id}/tables/{second}", headers=floor["headers"]
    )
    await client.post(
        f"/v1/sessions/{session_id}/close", headers=floor["headers"]
    )

    tables = (await client.get("/v1/floor", headers=floor["headers"])).json()[
        "tables"
    ]
    # A four that sat on two twos must not leave one of them occupied by a
    # bill that has already been paid.
    assert {t["status"] for t in tables if t["id"] in (first, second)} == {"free"}

    # And the table can be seated again straight away.
    again = await client.post(
        f"/v1/tables/{second}/open", json={"guests": 2}, headers=floor["headers"]
    )
    assert again.status_code == 200, again.text


async def test_a_table_can_be_taken_back_out_of_a_party(client, floor):
    first, second = str(floor["table_ids"][0]), str(floor["table_ids"][1])
    opened = await client.post(
        f"/v1/tables/{first}/open", json={"guests": 2}, headers=floor["headers"]
    )
    session_id = opened.json()["session_id"]
    await client.post(
        f"/v1/sessions/{session_id}/tables/{second}", headers=floor["headers"]
    )

    r = await client.delete(
        f"/v1/sessions/{session_id}/tables/{second}", headers=floor["headers"]
    )
    assert r.status_code == 200, r.text
    assert r.json()["party_table_nos"] == [
        t["table_no"] for t in (await client.get(
            "/v1/floor", headers=floor["headers"])).json()["tables"]
        if t["id"] == first
    ]

    tables = (await client.get("/v1/floor", headers=floor["headers"])).json()[
        "tables"
    ]
    released = [t for t in tables if t["id"] == second][0]
    assert released["status"] == "free"


async def test_cannot_open_a_table_twice(client, floor):
    """Two waiters, one table. The second must be told, not given a second bill."""
    tid = str(floor["table_ids"][0])
    first = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )
    assert first.status_code == 200

    second = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )
    assert second.status_code == 409
    assert "already open" in second.json()["detail"]


async def test_cannot_seat_more_guests_than_the_table_holds(client, floor):
    tid = str(floor["table_ids"][0])   # seats 2
    r = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 6}, headers=floor["headers"]
    )
    assert r.status_code == 400
    assert "seats 2" in r.json()["detail"]


async def test_add_lines_and_totals_reconcile(client, floor):
    tid = str(floor["table_ids"][1])
    opened = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )
    sid = opened.json()["session_id"]

    r = await client.post(
        f"/v1/sessions/{sid}/lines",
        json={"lines": [
            {"prodnum": 2008, "line_des": "MOUSHAKAL SABAH", "qty": 1, "unit_price": 3800},
            {"prodnum": 2013, "line_des": "HUMMOS", "qty": 2, "unit_price": 800},
        ]},
        headers=floor["headers"],
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["lines"]) == 2
    assert body["gross_total"] == 3800 + 1600
    # The guest pays gross; net and tax must add back up to exactly that.
    assert body["net_total"] + body["tax_total"] == body["gross_total"]


async def test_lines_accumulate_across_rounds(client, floor):
    """Guests order in rounds; the second must not renumber or replace the first."""
    tid = str(floor["table_ids"][2])
    sid = (await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 4}, headers=floor["headers"]
    )).json()["session_id"]

    for price in (1000, 2000):
        await client.post(
            f"/v1/sessions/{sid}/lines",
            json={"lines": [{"prodnum": 1, "line_des": "x", "qty": 1,
                             "unit_price": price}]},
            headers=floor["headers"],
        )

    r = await client.get(f"/v1/tables/{tid}/session", headers=floor["headers"])
    body = r.json()
    assert [ln["line_no"] for ln in body["lines"]] == [1, 2]
    assert body["gross_total"] == 3000


async def test_running_total_appears_on_the_floor(client, floor):
    tid = str(floor["table_ids"][0])
    sid = (await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )).json()["session_id"]
    await client.post(
        f"/v1/sessions/{sid}/lines",
        json={"lines": [{"prodnum": 1, "line_des": "x", "qty": 3, "unit_price": 500}]},
        headers=floor["headers"],
    )

    r = await client.get("/v1/floor", headers=floor["headers"])
    row = [t for t in r.json()["tables"] if t["id"] == tid][0]
    assert row["running_total"] == 1500


async def test_closing_with_items_needs_the_sale(client, floor):
    """Otherwise the order disappears and nobody is billed for it."""
    tid = str(floor["table_ids"][0])
    sid = (await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )).json()["session_id"]
    await client.post(
        f"/v1/sessions/{sid}/lines",
        json={"lines": [{"prodnum": 1, "line_des": "x", "qty": 1, "unit_price": 900}]},
        headers=floor["headers"],
    )

    r = await client.post(f"/v1/sessions/{sid}/close", headers=floor["headers"])
    assert r.status_code == 400
    assert "vanish" in r.json()["detail"]


async def test_empty_table_can_be_abandoned(client, floor):
    """Guests who sit down and leave without ordering are not an error."""
    tid = str(floor["table_ids"][0])
    sid = (await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )).json()["session_id"]

    r = await client.post(f"/v1/sessions/{sid}/close", headers=floor["headers"])
    assert r.status_code == 200
    assert r.json()["status"] == "abandoned"

    floor_r = await client.get("/v1/floor", headers=floor["headers"])
    row = [t for t in floor_r.json()["tables"] if t["id"] == tid][0]
    assert row["status"] == "free"


async def test_closing_is_idempotent(client, floor):
    """The tablet retries after a dropped connection; the retry must not fail."""
    tid = str(floor["table_ids"][0])
    sid = (await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )).json()["session_id"]
    sale = str(uuid.uuid4())

    first = await client.post(
        f"/v1/sessions/{sid}/close?sale_uuid={sale}", headers=floor["headers"]
    )
    second = await client.post(
        f"/v1/sessions/{sid}/close?sale_uuid={sale}", headers=floor["headers"]
    )
    assert first.status_code == second.status_code == 200
    assert first.json()["status"] == second.json()["status"] == "billed"


async def test_table_frees_up_after_billing(client, floor):
    tid = str(floor["table_ids"][0])
    sid = (await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )).json()["session_id"]
    await client.post(
        f"/v1/sessions/{sid}/close?sale_uuid={uuid.uuid4()}", headers=floor["headers"]
    )

    # Freed, and can be seated again.
    r = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )
    assert r.status_code == 200


async def test_cannot_add_lines_to_a_closed_session(client, floor):
    tid = str(floor["table_ids"][0])
    sid = (await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2}, headers=floor["headers"]
    )).json()["session_id"]
    await client.post(f"/v1/sessions/{sid}/close", headers=floor["headers"])

    r = await client.post(
        f"/v1/sessions/{sid}/lines",
        json={"lines": [{"prodnum": 1, "line_des": "x", "qty": 1, "unit_price": 100}]},
        headers=floor["headers"],
    )
    assert r.status_code == 409


async def test_floor_is_tenant_scoped(client, floor, seeded):
    """Beta must not see alpha's tables."""
    r = await client.get("/v1/floor", headers=auth(seeded, "b"))
    assert r.status_code == 200
    assert r.json()["tables"] == []


async def test_cannot_open_another_tenants_table(client, floor, seeded):
    tid = str(floor["table_ids"][0])
    r = await client.post(
        f"/v1/tables/{tid}/open", json={"guests": 2},
        headers=auth(seeded, "b"),
    )
    assert r.status_code == 404


# --------------------------------------------------------------------------
# Reservations

async def test_create_and_list_a_reservation(client, floor):
    when = _now().replace(microsecond=0) + dt.timedelta(hours=3)
    r = await client.post(
        "/v1/reservations",
        json={
            "table_id": str(floor["table_ids"][2]),
            "guest_name": "Al Rossais",
            "phone": "0500000000",
            "party_size": 5,
            "reserved_for": when.isoformat(),
            "occasion": "BIRTHDAY PARTY",
        },
        headers=floor["headers"],
    )
    assert r.status_code == 201, r.text
    assert r.json()["guest_name"] == "Al Rossais"

    listing = await client.get(
        f"/v1/reservations?on={when.date().isoformat()}", headers=floor["headers"]
    )
    assert len(listing.json()) == 1


async def test_double_booking_the_same_table_is_refused(client, floor):
    when = _now().replace(microsecond=0) + dt.timedelta(hours=4)
    payload = {
        "table_id": str(floor["table_ids"][2]),
        "guest_name": "First",
        "party_size": 4,
        "reserved_for": when.isoformat(),
        "duration_minutes": 90,
    }
    assert (await client.post("/v1/reservations", json=payload,
                              headers=floor["headers"])).status_code == 201

    clash = dict(payload, guest_name="Second",
                 reserved_for=(when + dt.timedelta(minutes=30)).isoformat())
    r = await client.post("/v1/reservations", json=clash, headers=floor["headers"])
    assert r.status_code == 409
    assert "already booked" in r.json()["detail"]


async def test_booking_after_the_previous_one_ends_is_allowed(client, floor):
    when = _now().replace(microsecond=0) + dt.timedelta(hours=6)
    payload = {
        "table_id": str(floor["table_ids"][2]),
        "guest_name": "Early",
        "party_size": 4,
        "reserved_for": when.isoformat(),
        "duration_minutes": 60,
    }
    assert (await client.post("/v1/reservations", json=payload,
                              headers=floor["headers"])).status_code == 201

    later = dict(payload, guest_name="Late",
                 reserved_for=(when + dt.timedelta(minutes=75)).isoformat())
    r = await client.post("/v1/reservations", json=later, headers=floor["headers"])
    assert r.status_code == 201


async def test_party_too_large_for_the_table_is_refused(client, floor):
    when = _now() + dt.timedelta(hours=2)
    r = await client.post(
        "/v1/reservations",
        json={
            "table_id": str(floor["table_ids"][0]),   # seats 2
            "guest_name": "Too many",
            "party_size": 8,
            "reserved_for": when.isoformat(),
        },
        headers=floor["headers"],
    )
    assert r.status_code == 400


async def test_reserved_table_is_flagged_on_the_floor(client, floor):
    when = _now() + dt.timedelta(hours=1)
    tid = str(floor["table_ids"][1])
    await client.post(
        "/v1/reservations",
        json={"table_id": tid, "guest_name": "Soon", "party_size": 2,
              "reserved_for": when.isoformat()},
        headers=floor["headers"],
    )
    r = await client.get("/v1/floor", headers=floor["headers"])
    row = [t for t in r.json()["tables"] if t["id"] == tid][0]
    assert row["status"] == "reserved"
