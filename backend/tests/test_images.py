"""Pictures on till buttons.

A picture is read faster than a name, which is the point of one. It has to
reach a tablet that may be offline for a day, so it travels in the catalog
like everything else — and it has to be the size a tile draws, which is what
the rules and the checks here are about.
"""

from __future__ import annotations

import struct
import zlib
from base64 import b64decode, b64encode

import pytest

from app import models as m
from app.db import SessionLocal

pytestmark = pytest.mark.asyncio


def png(width: int, height: int) -> bytes:
    """A real PNG of the given size — small, and readable by the checks."""
    def chunk(kind: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body)) + kind + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + b"\xff\x00\x00" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def jpeg(width: int, height: int) -> bytes:
    """Enough of a JPEG for the header walk: SOI, a segment, then SOF0."""
    return (
        b"\xff\xd8"
        + b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x00" * 9
        + b"\xff\xc0" + struct.pack(">H", 17) + b"\x08"
        + struct.pack(">HH", height, width) + b"\x03" + b"\x00" * 9
        + b"\xff\xd9"
    )


async def office(client, seeded, who="a"):
    """A back-office session for a tenant."""
    return {"Authorization": "Bearer " + seeded[who]["office_token"]}


async def a_product(seeded) -> int:
    return seeded["a"]["prodnum"]


async def test_the_rules_come_from_the_server(client, seeded):
    """So the guidance a manager reads cannot drift from what is enforced."""
    r = await client.get("/v1/office/image-rules", headers=await office(client, seeded))
    assert r.status_code == 200, r.text
    rules = r.json()
    assert rules["ideal_px"] >= rules["min_px"]
    assert rules["max_px"] >= rules["ideal_px"]
    assert "image/jpeg" in rules["formats"]
    assert rules["max_bytes"] > 0


async def test_a_picture_is_stored_at_the_size_it_really_is(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    r = await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/png", "data_b64": b64encode(png(64, 48)).decode()},
        headers=headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["has_image"] is True

    async with SessionLocal() as s:
        from sqlalchemy import select
        row = (
            await s.execute(
                select(m.ProductImage).where(
                    m.ProductImage.tenant_id == seeded["a"]["tenant_id"],
                    m.ProductImage.prodnum == prodnum,
                )
            )
        ).scalar_one()
    # Measured from the bytes, not taken on trust from whatever uploaded them.
    assert (row.width, row.height) == (64, 48)
    assert row.byte_size == len(row.data)


async def test_a_jpeg_is_measured_too(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    r = await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/jpeg",
              "data_b64": b64encode(jpeg(300, 200)).decode()},
        headers=headers,
    )
    assert r.status_code == 200, r.text
    async with SessionLocal() as s:
        from sqlalchemy import select
        row = (
            await s.execute(
                select(m.ProductImage).where(
                    m.ProductImage.tenant_id == seeded["a"]["tenant_id"],
                    m.ProductImage.prodnum == prodnum,
                )
            )
        ).scalar_one()
    assert (row.width, row.height) == (300, 200)


async def test_bytes_that_are_not_what_they_claim_are_refused(client, seeded):
    """A .png renamed to .jpg would otherwise reach every till and draw as a
    grey square nobody can explain."""
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    r = await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/jpeg", "data_b64": b64encode(png(8, 8)).decode()},
        headers=headers,
    )
    assert r.status_code == 400
    assert "not a JPEG" in r.text


async def test_an_oversized_picture_is_refused_with_the_limit(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    rules = (await client.get("/v1/office/image-rules", headers=headers)).json()
    too_big = b"\x89PNG\r\n\x1a\n" + b"\x00" * (rules["max_bytes"] + 1)
    r = await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/png", "data_b64": b64encode(too_big).decode()},
        headers=headers,
    )
    assert r.status_code == 400
    assert "KB" in r.json()["detail"]


async def test_a_picture_larger_than_a_tile_can_draw_is_refused(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    rules = (await client.get("/v1/office/image-rules", headers=headers)).json()
    over = rules["max_px"] + 1
    r = await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/jpeg",
              "data_b64": b64encode(jpeg(over, over)).decode()},
        headers=headers,
    )
    assert r.status_code == 400
    assert str(rules["max_px"]) in r.json()["detail"]


async def test_an_unsupported_format_is_refused(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    r = await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/gif", "data_b64": b64encode(b"GIF89a").decode()},
        headers=headers,
    )
    assert r.status_code == 400


async def test_replacing_a_picture_is_one_row_not_two(client, seeded):
    """Two rows would leave a device holding both halfway through a pull."""
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    for size in (32, 64):
        r = await client.put(
            f"/v1/office/products/{prodnum}/image",
            json={"mime": "image/png",
                  "data_b64": b64encode(png(size, size)).decode()},
            headers=headers,
        )
        assert r.status_code == 200, r.text

    async with SessionLocal() as s:
        from sqlalchemy import select
        rows = list(
            (
                await s.execute(
                    select(m.ProductImage).where(
                        m.ProductImage.tenant_id == seeded["a"]["tenant_id"],
                        m.ProductImage.prodnum == prodnum,
                    )
                )
            ).scalars().all()
        )
    assert len(rows) == 1
    assert rows[0].width == 64


async def test_the_picture_reaches_a_device_through_the_catalog(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    data = png(40, 40)
    await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/png", "data_b64": b64encode(data).decode()},
        headers=headers,
    )

    device = {"Authorization": f"Bearer {seeded['a']['token']}"}
    r = await client.get("/v1/catalog?since=0", headers=device)
    assert r.status_code == 200, r.text
    body = r.json()
    while body.get("has_more") and not body["product_images"]:
        r = await client.get(
            f"/v1/catalog?since=0&cursor={body['next_cursor']}", headers=device
        )
        body = r.json()
    images = body["product_images"]
    assert [i["prodnum"] for i in images] == [prodnum]
    # Byte-for-byte: a picture that arrives re-encoded is a picture the back
    # office cannot be held to.
    assert b64decode(images[0]["data_b64"]) == data
    assert images[0]["width"] == 40


async def test_removing_a_picture_tells_the_device_it_went(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/png", "data_b64": b64encode(png(16, 16)).decode()},
        headers=headers,
    )
    seen = (await client.get(
        "/v1/catalog?since=0",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"},
    )).json()["version"]

    r = await client.delete(
        f"/v1/office/products/{prodnum}/image", headers=headers)
    assert r.status_code == 200, r.text
    assert r.json()["has_image"] is False

    body = (await client.get(
        f"/v1/catalog?since={seen}",
        headers={"Authorization": f"Bearer {seeded['a']['token']}"},
    )).json()
    gone = [i for i in body["product_images"] if i["prodnum"] == prodnum]
    assert gone and gone[0]["is_deleted"] is True
    # A tombstone carries no bytes: there is nothing left to draw.
    assert gone[0]["data_b64"] is None


async def test_images_are_paged_more_tightly_than_other_rows(client, seeded):
    """One page of pictures is a download; one page of products is a packet."""
    from app.routers.catalog import ROW_CAPS
    from app.config import settings
    assert ROW_CAPS["product_images"] < settings.catalog_page_size


async def test_another_tenant_cannot_read_the_picture(client, seeded):
    headers = await office(client, seeded)
    prodnum = await a_product(seeded)
    await client.put(
        f"/v1/office/products/{prodnum}/image",
        json={"mime": "image/png", "data_b64": b64encode(png(16, 16)).decode()},
        headers=headers,
    )
    # A signed-in manager at another restaurant, which is the case that
    # matters: the token is valid, the row simply is not theirs.
    r = await client.get(
        f"/v1/office/products/{prodnum}/image",
        headers=await office(client, seeded, "b"),
    )
    assert r.status_code == 404
