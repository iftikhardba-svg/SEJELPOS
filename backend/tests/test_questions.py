"""Meal-deal prompts, attached to the product.

PixelPoint's "Forced Questions": a product asks up to five, each offering
choices that are themselves products. 91 imported items ask at least one, and
until now the back office could not show or change them.

The slots are ORDERED and sparse, which is where the sharp edges are: a partial
update can land two prompts in one slot, and a removed prompt has to be
tombstoned or no device will ever learn it went.
"""

from __future__ import annotations

from app.db import SessionLocal
from app.models import ComboItem, ProductQuestion, Question, QuestionChoice
from sqlalchemy import select


def office(seeded, key="a"):
    return {"Authorization": f"Bearer {seeded[key]['office_token']}"}


async def _seed_questions(seeded, key="a"):
    """Two prompts with choices, the shape the real catalog has."""
    async with SessionLocal() as s:
        async with s.begin():
            for no, prompt, pick in ((2020, "Bread Selection", 1),
                                     (2021, "Pickels Selection", 1),
                                     (2003, "1 DRINKS", 1)):
                s.add(Question(
                    tenant_id=seeded[key]["tenant_id"],
                    company_id=seeded[key]["company_id"],
                    question_no=no, prompt=prompt, pick_count=pick,
                    server_version=1,
                ))
            s.add(QuestionChoice(
                tenant_id=seeded[key]["tenant_id"],
                company_id=seeded[key]["company_id"],
                question_no=2020, prodnum=seeded[key]["prodnum"],
                server_version=1,
            ))


async def _product_id(client, seeded, key="a"):
    r = await client.get(
        f"/v1/office/products?search={seeded[key]['prodnum']}",
        headers=office(seeded, key))
    return r.json()[0]["id"]


async def test_questions_list_their_choices_and_usage(client, seeded):
    await _seed_questions(seeded)
    r = await client.get("/v1/office/questions", headers=office(seeded))
    assert r.status_code == 200, r.text
    bread = next(q for q in r.json() if q["question_no"] == 2020)
    assert bread["prompt"] == "Bread Selection"
    assert len(bread["choices"]) == 1
    assert bread["choices"][0]["prodnum"] == seeded["a"]["prodnum"]


async def test_a_product_carries_its_prompts_in_order(client, seeded):
    await _seed_questions(seeded)
    pid = await _product_id(client, seeded)

    r = await client.patch(
        f"/v1/office/products/{pid}",
        json={"question_nos": [2021, 2020]},
        headers=office(seeded),
    )
    assert r.status_code == 200, r.text
    # The order is the order they are asked, not sorted.
    assert r.json()["question_nos"] == [2021, 2020]

    again = await client.get(f"/v1/office/products/{pid}",
                             headers=office(seeded))
    assert again.json()["question_nos"] == [2021, 2020]


async def test_clearing_a_slot_tombstones_it(client, seeded):
    """A removed prompt has to stay as a deleted row: a device pulling
    incrementally learns it went by seeing the tombstone, and a vanished row
    would leave the till asking forever."""
    await _seed_questions(seeded)
    pid = await _product_id(client, seeded)

    await client.patch(f"/v1/office/products/{pid}",
                       json={"question_nos": [2020, 2021]},
                       headers=office(seeded))
    await client.patch(f"/v1/office/products/{pid}",
                       json={"question_nos": [2020]},
                       headers=office(seeded))

    r = await client.get(f"/v1/office/products/{pid}", headers=office(seeded))
    assert r.json()["question_nos"] == [2020]

    async with SessionLocal() as s:
        rows = (await s.execute(
            select(ProductQuestion).where(
                ProductQuestion.tenant_id == seeded["a"]["tenant_id"],
                ProductQuestion.prodnum == seeded["a"]["prodnum"],
            )
        )).scalars().all()
        slot2 = next(r for r in rows if r.slot == 2)
        assert slot2.is_deleted is True


async def test_the_same_prompt_cannot_be_asked_twice(client, seeded):
    await _seed_questions(seeded)
    pid = await _product_id(client, seeded)
    r = await client.patch(
        f"/v1/office/products/{pid}",
        json={"question_nos": [2020, 2020]},
        headers=office(seeded),
    )
    assert r.status_code == 400
    assert "twice" in r.json()["detail"]


async def test_an_unknown_prompt_is_refused(client, seeded):
    await _seed_questions(seeded)
    pid = await _product_id(client, seeded)
    r = await client.patch(
        f"/v1/office/products/{pid}",
        json={"question_nos": [99999]},
        headers=office(seeded),
    )
    assert r.status_code == 400


async def test_more_than_five_prompts_is_refused(client, seeded):
    """PixelPoint has five slots and so does this. Six would silently drop
    one."""
    await _seed_questions(seeded)
    pid = await _product_id(client, seeded)
    r = await client.patch(
        f"/v1/office/products/{pid}",
        json={"question_nos": [2020, 2021, 2003, 2020, 2021, 2003]},
        headers=office(seeded),
    )
    assert r.status_code == 422


async def test_prompt_changes_reach_a_device(client, seeded):
    """The product and its prompts must arrive together — a device that pulls
    the item without its prompts rings a meal with nothing chosen."""
    await _seed_questions(seeded)
    pid = await _product_id(client, seeded)

    before = (await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"})).json()["version"]

    await client.patch(f"/v1/office/products/{pid}",
                       json={"question_nos": [2020]},
                       headers=office(seeded))

    async with SessionLocal() as s:
        row = (await s.execute(
            select(ProductQuestion).where(
                ProductQuestion.tenant_id == seeded["a"]["tenant_id"],
                ProductQuestion.prodnum == seeded["a"]["prodnum"],
                ProductQuestion.slot == 1,
            )
        )).scalar_one()
        assert row.server_version > before, \
            "the prompt row kept version 0 and no device would ever pull it"


async def test_a_device_pulls_everything_it_needs_to_ask(client, seeded):
    """The prompts have to reach the till, not just the back office.

    Until they did, a manager could set an assignment every till ignored — and
    the meal rang with nothing chosen while the kitchen was told to make an
    empty box.
    """
    await _seed_questions(seeded)
    prodnum = seeded["a"]["prodnum"]
    async with SessionLocal() as s:
        async with s.begin():
            s.add(ProductQuestion(
                tenant_id=seeded["a"]["tenant_id"],
                prodnum=prodnum, question_no=2020, slot=1, server_version=1,
            ))
            s.add(ComboItem(
                tenant_id=seeded["a"]["tenant_id"],
                company_id=seeded["a"]["company_id"],
                parent_prodnum=prodnum, prodnum=prodnum, server_version=1,
            ))

    body = (await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"},
    )).json()

    assert {q["question_no"] for q in body["questions"]} == {2020, 2021, 2003}
    choice = next(c for c in body["question_choices"] if c["question_no"] == 2020)
    assert choice["prodnum"] == prodnum
    # What the till prices the answer at. Nothing here means included.
    assert choice["fixed_price"] is None
    assert body["product_questions"][0]["slot"] == 1
    assert body["combo_items"][0]["parent_prodnum"] == prodnum
    assert body["combo_items"][0]["print_it"] is True


async def test_another_tenants_device_pulls_none_of_them(client, seeded):
    await _seed_questions(seeded, "a")
    body = (await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {seeded['b']['token']}"},
    )).json()
    assert body["questions"] == []
    assert body["question_choices"] == []


async def test_questions_never_leak_across_tenants(client, seeded):
    await _seed_questions(seeded, "a")
    r = await client.get("/v1/office/questions", headers=office(seeded, "b"))
    assert r.json() == []
