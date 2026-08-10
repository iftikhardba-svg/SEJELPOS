"""Menu layout.

A page is a grid and where a button sits is what staff navigate by — they
reach for a position long before they read a label. So the things that must
hold are about the grid: two buttons never share a cell, moving one onto
another rearranges rather than destroys, and a page can never be shrunk to
hide a button that is still sellable.
"""

from __future__ import annotations

import uuid as _uuid

from app.db import SessionLocal
from app.models import Menu, MenuButton, MenuScreen, Product
from sqlalchemy import select


def office(seeded, key="a"):
    return {"Authorization": f"Bearer {seeded[key]['office_token']}"}


async def _page(client, seeded, key="a", menu_id=10, name="Grill"):
    """The conftest seed already has one screen at menu_id 10."""
    r = await client.get("/v1/office/menu-screens", headers=office(seeded, key))
    assert r.status_code == 200, r.text
    for screen in r.json():
        if screen["menu_id"] == menu_id:
            return screen
    made = await client.post(
        "/v1/office/menu-screens",
        json={"menu_id": menu_id, "name": name, "buttons_across": 4,
              "buttons_down": 3},
        headers=office(seeded, key),
    )
    assert made.status_code == 201, made.text
    return made.json()


async def _extra_product(seeded, prodnum, key="a"):
    async with SessionLocal() as s:
        async with s.begin():
            s.add(Product(
                tenant_id=seeded[key]["tenant_id"],
                branch_id=seeded[key]["branch_id"],
                prodnum=prodnum,
                descript=f"Item {prodnum}",
                price_a=1000,
                server_version=1,
            ))
    return prodnum


# --------------------------------------------------------------------------
# Placing


async def test_a_product_can_be_put_on_a_cell(client, seeded):
    page = await _page(client, seeded)
    r = await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": seeded["a"]["prodnum"], "pos_x": 2, "pos_y": 1},
        headers=office(seeded),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert (body["pos_x"], body["pos_y"]) == (2, 1)
    assert body["prodnum"] == seeded["a"]["prodnum"]


async def test_two_buttons_cannot_share_a_cell(client, seeded):
    """The failure this prevents is a button a cashier can see but not press,
    because another is drawn on top of it."""
    page = await _page(client, seeded)
    other = await _extra_product(seeded, 8801)

    first = await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": seeded["a"]["prodnum"], "pos_x": 3, "pos_y": 2},
        headers=office(seeded),
    )
    assert first.status_code == 201

    clash = await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": other, "pos_x": 3, "pos_y": 2},
        headers=office(seeded),
    )
    assert clash.status_code == 409


async def test_placing_an_unknown_product_is_refused(client, seeded):
    page = await _page(client, seeded)
    r = await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": 999999, "pos_x": 1, "pos_y": 3},
        headers=office(seeded),
    )
    assert r.status_code == 404


async def test_a_button_carries_the_products_look(client, seeded):
    """The editor draws the grid as a till would, so it needs the colours and
    the label with the button rather than a request per cell."""
    async with SessionLocal() as s:
        async with s.begin():
            product = (await s.execute(
                select(Product).where(
                    Product.tenant_id == seeded["a"]["tenant_id"],
                    Product.prodnum == seeded["a"]["prodnum"],
                )
            )).scalar_one()
            product.button_text = "SHORT\nLABEL"
            product.back_color = "#FF80C0"

    page = await _page(client, seeded)
    await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": seeded["a"]["prodnum"], "pos_x": 4, "pos_y": 3},
        headers=office(seeded),
    )
    r = await client.get(
        f"/v1/office/menu-screens/{page['id']}/buttons", headers=office(seeded)
    )
    button = next(b for b in r.json() if (b["pos_x"], b["pos_y"]) == (4, 3))
    assert button["button_text"] == "SHORT\nLABEL"
    assert button["back_color"] == "#FF80C0"


# --------------------------------------------------------------------------
# Moving


async def test_moving_onto_an_occupied_cell_swaps_them(client, seeded):
    """Dragging one button onto another is a rearrangement. Refusing would
    make someone empty a cell first, which is busywork; overwriting would lose
    a button silently."""
    page = await _page(client, seeded, menu_id=21, name="Swap page")
    a = await _extra_product(seeded, 8811)
    b = await _extra_product(seeded, 8812)

    first = (await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": a, "pos_x": 1, "pos_y": 1},
        headers=office(seeded))).json()
    second = (await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": b, "pos_x": 2, "pos_y": 1},
        headers=office(seeded))).json()

    moved = await client.patch(
        f"/v1/office/menu-buttons/{second['id']}",
        json={"pos_x": 1, "pos_y": 1},
        headers=office(seeded),
    )
    assert moved.status_code == 200, moved.text

    rows = (await client.get(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        headers=office(seeded))).json()
    placed = {r["prodnum"]: (r["pos_x"], r["pos_y"]) for r in rows}
    assert placed[b] == (1, 1)
    assert placed[a] == (2, 1), "the displaced button was lost instead of moved"
    assert len(rows) == 2


async def test_moving_to_an_empty_cell_leaves_nothing_behind(client, seeded):
    page = await _page(client, seeded, menu_id=22, name="Move page")
    p = await _extra_product(seeded, 8821)
    button = (await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": p, "pos_x": 1, "pos_y": 1},
        headers=office(seeded))).json()

    await client.patch(
        f"/v1/office/menu-buttons/{button['id']}",
        json={"pos_x": 3, "pos_y": 2},
        headers=office(seeded),
    )
    rows = (await client.get(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        headers=office(seeded))).json()
    assert len(rows) == 1
    assert (rows[0]["pos_x"], rows[0]["pos_y"]) == (3, 2)


# --------------------------------------------------------------------------
# Removing


async def test_removing_a_button_tombstones_it_for_the_tills(client, seeded):
    """A hard delete is invisible to a device pulling incrementally, so the
    button would stay on the till for good."""
    page = await _page(client, seeded, menu_id=23, name="Remove page")
    p = await _extra_product(seeded, 8831)
    button = (await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": p, "pos_x": 1, "pos_y": 1},
        headers=office(seeded))).json()

    r = await client.delete(f"/v1/office/menu-buttons/{button['id']}",
                            headers=office(seeded))
    assert r.status_code == 204

    rows = (await client.get(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        headers=office(seeded))).json()
    assert rows == []

    async with SessionLocal() as s:
        row = (await s.execute(
            select(MenuButton).where(
                MenuButton.id == _uuid.UUID(button["id"]))
        )).scalar_one()
        assert row.is_deleted is True, "row vanished; devices can never learn"

    # And the tombstone reaches a device.
    catalog = await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"},
    )
    assert any(
        b["id"] == button["id"] and b["is_deleted"]
        for b in catalog.json()["menu_buttons"]
    )


# --------------------------------------------------------------------------
# The page itself


async def test_a_page_cannot_be_shrunk_under_its_buttons(client, seeded):
    """Otherwise the button is invisible on every till and still sellable by
    number — present, unreachable, and impossible to notice."""
    page = await _page(client, seeded, menu_id=24, name="Shrink page")
    p = await _extra_product(seeded, 8841)
    await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": p, "pos_x": 4, "pos_y": 3},
        headers=office(seeded))

    r = await client.patch(
        f"/v1/office/menu-screens/{page['id']}",
        json={"buttons_across": 2},
        headers=office(seeded),
    )
    assert r.status_code == 400
    assert "column 4" in r.json()["detail"]

    r = await client.patch(
        f"/v1/office/menu-screens/{page['id']}",
        json={"buttons_down": 1},
        headers=office(seeded),
    )
    assert r.status_code == 400
    assert "row 3" in r.json()["detail"]


async def test_a_duplicate_page_number_is_refused(client, seeded):
    await _page(client, seeded, menu_id=25, name="First")
    r = await client.post(
        "/v1/office/menu-screens",
        json={"menu_id": 25, "name": "Second"},
        headers=office(seeded),
    )
    assert r.status_code == 409


async def test_layout_changes_bump_the_version_so_tills_see_them(
    client, seeded
):
    """The counter is the only thing telling a tablet there is something to
    pull. A layout change nothing stamps is a layout change no till applies."""
    page = await _page(client, seeded, menu_id=26, name="Version page")
    p = await _extra_product(seeded, 8851)

    before = (await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"})).json()["version"]

    await client.post(
        f"/v1/office/menu-screens/{page['id']}/buttons",
        json={"prodnum": p, "pos_x": 1, "pos_y": 1},
        headers=office(seeded))

    after = await client.get(
        f"/v1/catalog?since={before}",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"})
    assert after.status_code == 200
    assert any(b["prodnum"] == p for b in after.json()["menu_buttons"]), \
        "a device pulling since the old watermark never sees the new button"


# --------------------------------------------------------------------------
# Isolation


# --------------------------------------------------------------------------
# The menus level — the grid of page tiles a till lands on


async def _menu(client, seeded, key="a", menu_no=1, name="Default Menu"):
    async with SessionLocal() as s:
        async with s.begin():
            s.add(Menu(
                tenant_id=seeded[key]["tenant_id"],
                branch_id=seeded[key]["branch_id"],
                menu_no=menu_no, name=name, server_version=1,
            ))
    r = await client.get("/v1/office/menus", headers=office(seeded, key))
    return next(m for m in r.json() if m["menu_no"] == menu_no)


async def test_a_page_can_be_put_on_a_menu(client, seeded):
    menu = await _menu(client, seeded, menu_no=41)
    page = await _page(client, seeded, menu_id=41 * 10, name="Shawarma")

    r = await client.post(
        f"/v1/office/menus/{menu['id']}/pages",
        json={"screen_no": page["menu_id"], "pos_x": 1, "pos_y": 1},
        headers=office(seeded),
    )
    assert r.status_code == 201, r.text
    assert r.json()["name"] == "Shawarma"


async def test_two_pages_cannot_share_a_tile(client, seeded):
    menu = await _menu(client, seeded, menu_no=42)
    a = await _page(client, seeded, menu_id=421, name="Grill")
    b = await _page(client, seeded, menu_id=422, name="Beverage")

    await client.post(f"/v1/office/menus/{menu['id']}/pages",
                      json={"screen_no": a["menu_id"], "pos_x": 2, "pos_y": 1},
                      headers=office(seeded))
    clash = await client.post(
        f"/v1/office/menus/{menu['id']}/pages",
        json={"screen_no": b["menu_id"], "pos_x": 2, "pos_y": 1},
        headers=office(seeded))
    assert clash.status_code == 409


async def test_placing_a_page_twice_moves_it_rather_than_duplicating(
    client, seeded
):
    """One page has one tile per menu. Placing it again is a move — two tiles
    reaching the same page is a menu that lies about how big it is."""
    menu = await _menu(client, seeded, menu_no=43)
    page = await _page(client, seeded, menu_id=431, name="Appetizer")

    await client.post(f"/v1/office/menus/{menu['id']}/pages",
                      json={"screen_no": 431, "pos_x": 1, "pos_y": 1},
                      headers=office(seeded))
    await client.post(f"/v1/office/menus/{menu['id']}/pages",
                      json={"screen_no": 431, "pos_x": 3, "pos_y": 2},
                      headers=office(seeded))

    tiles = (await client.get(f"/v1/office/menus/{menu['id']}/pages",
                              headers=office(seeded))).json()
    assert len(tiles) == 1
    assert (tiles[0]["pos_x"], tiles[0]["pos_y"]) == (3, 2)
    assert page["menu_id"] == 431


async def test_a_tile_carries_the_pages_colour_and_button_count(client, seeded):
    """The editor draws the menu as a till would — staff reach for a colour
    before they read a name."""
    menu = await _menu(client, seeded, menu_no=44)
    page = await _page(client, seeded, menu_id=441, name="Beverage")

    async with SessionLocal() as s:
        async with s.begin():
            screen = (await s.execute(
                select(MenuScreen).where(
                    MenuScreen.id == _uuid.UUID(page["id"]))
            )).scalar_one()
            screen.back_color = "#FF7F7F"

    p = await _extra_product(seeded, 8861)
    await client.post(f"/v1/office/menu-screens/{page['id']}/buttons",
                      json={"prodnum": p, "pos_x": 1, "pos_y": 1},
                      headers=office(seeded))
    await client.post(f"/v1/office/menus/{menu['id']}/pages",
                      json={"screen_no": 441, "pos_x": 1, "pos_y": 1},
                      headers=office(seeded))

    tiles = (await client.get(f"/v1/office/menus/{menu['id']}/pages",
                              headers=office(seeded))).json()
    assert tiles[0]["back_color"] == "#FF7F7F"
    assert tiles[0]["button_count"] == 1


async def test_removing_a_tile_keeps_the_page_and_its_buttons(client, seeded):
    """Taking a page off a menu is not deleting the page. Everything on it
    survives; only the way in is gone."""
    menu = await _menu(client, seeded, menu_no=45)
    page = await _page(client, seeded, menu_id=451, name="Extra")
    p = await _extra_product(seeded, 8871)
    await client.post(f"/v1/office/menu-screens/{page['id']}/buttons",
                      json={"prodnum": p, "pos_x": 1, "pos_y": 1},
                      headers=office(seeded))
    tile = (await client.post(f"/v1/office/menus/{menu['id']}/pages",
                              json={"screen_no": 451, "pos_x": 1, "pos_y": 1},
                              headers=office(seeded))).json()

    r = await client.delete(f"/v1/office/menu-pages/{tile['id']}",
                            headers=office(seeded))
    assert r.status_code == 204

    assert (await client.get(f"/v1/office/menus/{menu['id']}/pages",
                             headers=office(seeded))).json() == []
    buttons = (await client.get(f"/v1/office/menu-screens/{page['id']}/buttons",
                                headers=office(seeded))).json()
    assert len(buttons) == 1, "the page's buttons went with the tile"


async def test_menu_changes_reach_a_device(client, seeded):
    menu = await _menu(client, seeded, menu_no=46)
    page = await _page(client, seeded, menu_id=461, name="Keeta")

    before = (await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"})).json()["version"]

    await client.post(f"/v1/office/menus/{menu['id']}/pages",
                      json={"screen_no": 461, "pos_x": 2, "pos_y": 2},
                      headers=office(seeded))

    after = (await client.get(
        f"/v1/catalog?since={before}",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"})).json()
    assert any(p["screen_no"] == 461 for p in after["menu_pages"])
    assert page["menu_id"] == 461


async def test_another_tenants_menu_cannot_be_laid_out(client, seeded):
    theirs = await _menu(client, seeded, key="b", menu_no=47, name="Theirs")
    mine = await _page(client, seeded, key="a", menu_id=471, name="Mine")
    r = await client.post(
        f"/v1/office/menus/{theirs['id']}/pages",
        json={"screen_no": mine["menu_id"], "pos_x": 1, "pos_y": 1},
        headers=office(seeded, "a"),
    )
    assert r.status_code == 404


async def test_pages_are_scoped_to_the_tenant(client, seeded):
    mine = (await client.get("/v1/office/menu-screens",
                             headers=office(seeded, "a"))).json()
    theirs = (await client.get("/v1/office/menu-screens",
                               headers=office(seeded, "b"))).json()
    assert {s["id"] for s in mine}.isdisjoint({s["id"] for s in theirs})


async def test_a_button_cannot_be_placed_on_another_tenants_page(
    client, seeded
):
    page_b = await _page(client, seeded, key="b", menu_id=10)
    r = await client.post(
        f"/v1/office/menu-screens/{page_b['id']}/buttons",
        json={"prodnum": seeded["a"]["prodnum"], "pos_x": 1, "pos_y": 1},
        headers=office(seeded, "a"),
    )
    # 404, not 403: a scoped lookup must not confirm the page exists.
    assert r.status_code == 404


async def test_another_tenants_button_cannot_be_moved(client, seeded):
    page_b = await _page(client, seeded, key="b", menu_id=31, name="Theirs")
    async with SessionLocal() as s:
        async with s.begin():
            screen = (await s.execute(
                select(MenuScreen).where(
                    MenuScreen.id == _uuid.UUID(page_b["id"]))
            )).scalar_one()
            s.add(MenuButton(
                tenant_id=seeded["b"]["tenant_id"],
                menu_screen_id=screen.id,
                menu_id=screen.menu_id,
                prodnum=seeded["b"]["prodnum"],
                pos_x=1, pos_y=1, position=1, server_version=1,
            ))
        victim = (await s.execute(
            select(MenuButton).where(
                MenuButton.tenant_id == seeded["b"]["tenant_id"])
        )).scalars().first()

    r = await client.patch(
        f"/v1/office/menu-buttons/{victim.id}",
        json={"pos_x": 2, "pos_y": 2},
        headers=office(seeded, "a"),
    )
    assert r.status_code == 404
