"""Kitchen display tests.

The scenarios are the ones a real service produces: the till retrying a ticket
after a dropped connection, a station screen that must only see its own lines,
a double-tapped bump, and a ticket bumped by mistake.
"""

from __future__ import annotations

import datetime as dt
import uuid

import pytest

pytestmark = pytest.mark.asyncio

# Station numbers as imported from PixelPoint's printer ports.
EXPO, GRILL, SHAWARMA, DT = 2, 3, 4, 5


def auth(seeded, who="a") -> dict:
    return {"Authorization": f"Bearer {seeded[who]['token']}"}


def make_ticket(**over) -> dict:
    """A drive-thru ticket with lines on two stations."""
    base = {
        "ticket_id": str(uuid.uuid4()),
        "order_no": 124,
        "sale_type_no": 2025,
        "sale_type_name": "Drive Thru",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "lines": [
            {"line_no": 1, "prodnum": 2070, "line_des": "KABAB LAHAM LARGE",
             "qty": 1, "station_no": GRILL},
            {"line_no": 2, "prodnum": 2058, "line_des": "Shawa Sandw Ckn",
             "qty": 2, "station_no": SHAWARMA, "note": "no pickles"},
        ],
    }
    base.update(over)
    return base


async def test_create_and_read_back(client, seeded):
    t = make_ticket()
    r = await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["status"] == "open"
    assert [ln["station_no"] for ln in body["lines"]] == [GRILL, SHAWARMA]

    q = await client.get("/v1/kds/queue", headers=auth(seeded))
    assert t["ticket_id"] in [x["id"] for x in q.json()["open"]]


async def test_a_chosen_item_says_which_meal_it_came_out_of(client, seeded):
    """The cook needs the grouping: "PEPSI" on its own could belong to any of
    four open meals on the rail."""
    t = make_ticket(lines=[
        {"line_no": 1, "prodnum": 2192, "line_des": "2 SANDWICH OFFER",
         "qty": 1, "station_no": SHAWARMA},
        {"line_no": 2, "prodnum": 2058, "line_des": "Shawa Sandw Ckn",
         "qty": 1, "station_no": SHAWARMA, "parent_line_no": 1},
    ])
    r = await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))
    assert r.status_code == 201, r.text

    q = await client.get(f"/v1/kds/queue?station={SHAWARMA}",
                         headers=auth(seeded))
    ticket = next(x for x in q.json()["open"] if x["id"] == t["ticket_id"])
    assert [ln["parent_line_no"] for ln in ticket["lines"]] == [None, 1]


async def test_replay_does_not_cook_the_order_twice(client, seeded):
    """The till's outbox retries after a network blink."""
    t = make_ticket()
    first = await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))
    second = await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))
    assert first.status_code == 201 and second.status_code == 201

    q = await client.get("/v1/kds/queue", headers=auth(seeded))
    ids = [x["id"] for x in q.json()["open"]]
    assert ids.count(t["ticket_id"]) == 1


async def test_station_screen_sees_only_its_lines(client, seeded):
    """The grill must not be told to make a shawarma."""
    t = make_ticket()
    await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))

    grill = await client.get(f"/v1/kds/queue?station={GRILL}", headers=auth(seeded))
    mine = [x for x in grill.json()["open"] if x["id"] == t["ticket_id"]][0]
    assert [ln["line_des"] for ln in mine["lines"]] == ["KABAB LAHAM LARGE"]


async def test_ticket_with_nothing_for_a_station_is_hidden(client, seeded):
    t = make_ticket(lines=[{"line_no": 1, "prodnum": 2070,
                            "line_des": "KABAB LAHAM LARGE", "qty": 1,
                            "station_no": GRILL}])
    await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))

    expo = await client.get(f"/v1/kds/queue?station={EXPO}", headers=auth(seeded))
    assert t["ticket_id"] not in [x["id"] for x in expo.json()["open"]]


async def test_bump_moves_to_recall_lane_and_is_idempotent(client, seeded):
    t = make_ticket()
    await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))

    one = await client.post(f"/v1/kds/tickets/{t['ticket_id']}/bump",
                            headers=auth(seeded))
    two = await client.post(f"/v1/kds/tickets/{t['ticket_id']}/bump",
                            headers=auth(seeded))
    assert one.status_code == two.status_code == 200
    assert one.json()["status"] == two.json()["status"] == "done"
    # The double-tap must not move bumped_at.
    assert one.json()["bumped_at"] == two.json()["bumped_at"]

    q = (await client.get("/v1/kds/queue", headers=auth(seeded))).json()
    assert t["ticket_id"] not in [x["id"] for x in q["open"]]
    assert t["ticket_id"] in [x["id"] for x in q["done"]]


async def test_recall_brings_it_back(client, seeded):
    t = make_ticket()
    await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))
    await client.post(f"/v1/kds/tickets/{t['ticket_id']}/bump", headers=auth(seeded))

    r = await client.post(f"/v1/kds/tickets/{t['ticket_id']}/recall",
                          headers=auth(seeded))
    assert r.json()["status"] == "open"
    assert r.json()["bumped_at"] is None

    q = (await client.get("/v1/kds/queue", headers=auth(seeded))).json()
    assert t["ticket_id"] in [x["id"] for x in q["open"]]


async def test_line_done_toggle(client, seeded):
    t = make_ticket()
    created = (await client.post("/v1/kds/tickets", json=t,
                                 headers=auth(seeded))).json()
    line_id = created["lines"][0]["id"]

    done = await client.post(f"/v1/kds/lines/{line_id}/done", headers=auth(seeded))
    assert done.json()["done"] is True

    undone = await client.post(f"/v1/kds/lines/{line_id}/done?done=false",
                               headers=auth(seeded))
    assert undone.json()["done"] is False


async def test_queue_is_oldest_first(client, seeded):
    """The kitchen works the rail in order; newest-first would starve the
    oldest order."""
    now = dt.datetime.now(dt.timezone.utc)
    old = make_ticket(order_no=1,
                      created_at=(now - dt.timedelta(minutes=9)).isoformat())
    new = make_ticket(order_no=2, created_at=now.isoformat())
    await client.post("/v1/kds/tickets", json=new, headers=auth(seeded))
    await client.post("/v1/kds/tickets", json=old, headers=auth(seeded))

    q = (await client.get("/v1/kds/queue", headers=auth(seeded))).json()
    mine = [x for x in q["open"] if x["id"] in (old["ticket_id"], new["ticket_id"])]
    assert [x["order_no"] for x in mine] == [1, 2]


async def test_aggregator_ticket_carries_its_reference(client, seeded):
    t = make_ticket(sale_type_no=2004, sale_type_name="Keeta",
                    external_ref="KEETA-58211")
    r = await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))
    assert r.json()["external_ref"] == "KEETA-58211"


async def test_kitchen_is_tenant_scoped(client, seeded):
    t = make_ticket()
    await client.post("/v1/kds/tickets", json=t, headers=auth(seeded, "a"))

    other = await client.get("/v1/kds/queue", headers=auth(seeded, "b"))
    assert t["ticket_id"] not in [x["id"] for x in other.json()["open"]]

    steal = await client.post(f"/v1/kds/tickets/{t['ticket_id']}/bump",
                              headers=auth(seeded, "b"))
    assert steal.status_code == 404


async def test_empty_ticket_is_rejected(client, seeded):
    t = make_ticket(lines=[])
    r = await client.post("/v1/kds/tickets", json=t, headers=auth(seeded))
    assert r.status_code == 422
