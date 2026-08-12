"""Kitchen display: tickets on the rail.

The till creates a ticket the moment an order is sent to the kitchen — before
payment on dine-in, at payment on counter trade. KDS screens poll the queue for
their station and bump tickets as food goes out.

Two rules carry the design:

* **Creation is idempotent on the till-generated ticket id.** The till retries
  after a dropped connection exactly like the sales outbox, and the kitchen
  must not cook an order twice because the network blinked.
* **A kitchen ticket is workflow, not a record.** It is deliberately separate
  from `sale`: bumping, recalling or voiding a ticket never touches money or
  tax. When the two disagree, the sale is the truth.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from ..auth import DeviceContext, current_device
from ..db import tenant_session
from ..models import KitchenTicket, KitchenTicketLine
from ..schemas import (
    KitchenLineOut,
    KitchenQueueResponse,
    KitchenTicketIn,
    KitchenTicketOut,
)

router = APIRouter(tags=["kds"])

OPEN = "open"
DONE = "done"
# Handed over. A bumped ticket is cooked and waiting on the pass; a collected
# one is with the customer, and has to leave both the kitchen's done lane and
# the order board — otherwise the board fills with numbers nobody is waiting
# for and the one number that matters is somewhere down the list.
COLLECTED = "collected"

RECALL_LANE_SIZE = 5


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _utc(value: dt.datetime | None) -> dt.datetime | None:
    """Stamp UTC on naive datetimes so the API is consistent across backends.

    PostgreSQL hands back timezone-aware values; SQLite hands back naive ones.
    Without this, the same ticket serialises differently depending on which
    database served it — the first response says ...Z, the replay does not.
    """
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=dt.timezone.utc)
    return value


def _out(t: KitchenTicket, lines=None) -> KitchenTicketOut:
    rows = lines if lines is not None else sorted(t.lines, key=lambda x: x.line_no)
    return KitchenTicketOut(
        id=t.id,
        order_no=t.order_no,
        sale_type_no=t.sale_type_no,
        sale_type_name=t.sale_type_name,
        table_no=t.table_no,
        external_ref=t.external_ref,
        status=t.status,
        created_at=_utc(t.created_at),
        bumped_at=_utc(t.bumped_at),
        lines=[KitchenLineOut.model_validate(x) for x in rows],
    )


@router.post("/kds/tickets", response_model=KitchenTicketOut, status_code=201)
async def create_ticket(
    body: KitchenTicketIn,
    ctx: DeviceContext = Depends(current_device),
) -> KitchenTicketOut:
    async with tenant_session(ctx.tenant_id) as session:
        existing = (
            await session.execute(
                select(KitchenTicket)
                .options(selectinload(KitchenTicket.lines))
                .where(KitchenTicket.id == body.ticket_id)
            )
        ).scalar_one_or_none()
        if existing is not None:
            # A replay from the till's outbox. Same answer as the first time —
            # the kitchen must not see the order twice.
            return _out(existing)

        created = body.created_at
        if created.tzinfo is None:
            created = created.replace(tzinfo=dt.timezone.utc)

        ticket = KitchenTicket(
            id=body.ticket_id,
            tenant_id=ctx.tenant_id,
            branch_id=ctx.branch_id,
            order_no=body.order_no,
            sale_type_no=body.sale_type_no,
            sale_type_name=body.sale_type_name,
            table_no=body.table_no,
            external_ref=body.external_ref,
            sale_uuid=body.sale_uuid,
            session_id=body.session_id,
            device_uuid=ctx.device_uuid,
            status=OPEN,
            created_at=created,
        )
        session.add(ticket)
        for ln in body.lines:
            session.add(KitchenTicketLine(
                tenant_id=ctx.tenant_id,
                ticket_id=ticket.id,
                line_no=ln.line_no,
                prodnum=ln.prodnum,
                line_des=ln.line_des,
                qty=ln.qty,
                station_no=ln.station_no,
                note=ln.note,
                seat_no=ln.seat_no,
                parent_line_no=ln.parent_line_no,
            ))
        await session.flush()
        await session.refresh(ticket, ["lines"])
        return _out(ticket)


@router.get("/kds/queue", response_model=KitchenQueueResponse)
async def queue(
    station: int | None = Query(
        None, description="only tickets with lines for this station"
    ),
    ctx: DeviceContext = Depends(current_device),
) -> KitchenQueueResponse:
    async with tenant_session(ctx.tenant_id) as session:
        open_rows = list(
            (
                await session.execute(
                    select(KitchenTicket)
                    .options(selectinload(KitchenTicket.lines))
                    .where(
                        KitchenTicket.tenant_id == ctx.tenant_id,
                        KitchenTicket.branch_id == ctx.branch_id,
                        KitchenTicket.status == OPEN,
                    )
                    .order_by(KitchenTicket.created_at)
                )
            )
            .scalars()
            .all()
        )

        done_rows = list(
            (
                await session.execute(
                    select(KitchenTicket)
                    .options(selectinload(KitchenTicket.lines))
                    .where(
                        KitchenTicket.tenant_id == ctx.tenant_id,
                        KitchenTicket.branch_id == ctx.branch_id,
                        KitchenTicket.status == DONE,
                    )
                    .order_by(KitchenTicket.bumped_at.desc())
                    .limit(RECALL_LANE_SIZE)
                )
            )
            .scalars()
            .all()
        )

    def project(rows) -> list[KitchenTicketOut]:
        out = []
        for t in rows:
            lines = sorted(t.lines, key=lambda x: x.line_no)
            if station is not None:
                lines = [x for x in lines if x.station_no == station]
                if not lines:
                    continue   # nothing for this station on this ticket
            out.append(_out(t, lines))
        return out

    return KitchenQueueResponse(open=project(open_rows), done=project(done_rows))


@router.post("/kds/tickets/{ticket_id}/bump", response_model=KitchenTicketOut)
async def bump(
    ticket_id: uuid.UUID,
    ctx: DeviceContext = Depends(current_device),
) -> KitchenTicketOut:
    """Food went out. Idempotent — a double-tap must not error."""
    async with tenant_session(ctx.tenant_id) as session:
        t = await _get(session, ticket_id, ctx)
        if t.status != DONE:
            t.status = DONE
            t.bumped_at = _now()
            await session.flush()
        return _out(t)


@router.post("/kds/tickets/{ticket_id}/recall", response_model=KitchenTicketOut)
async def recall(
    ticket_id: uuid.UUID,
    ctx: DeviceContext = Depends(current_device),
) -> KitchenTicketOut:
    """Bumped or collected by mistake — bring it back to the rail."""
    async with tenant_session(ctx.tenant_id) as session:
        t = await _get(session, ticket_id, ctx)
        if t.status != OPEN:
            t.status = OPEN
            t.bumped_at = None
            await session.flush()
        return _out(t)


@router.post("/kds/tickets/{ticket_id}/collect",
             response_model=KitchenTicketOut)
async def collect(
    ticket_id: uuid.UUID,
    ctx: DeviceContext = Depends(current_device),
) -> KitchenTicketOut:
    """The customer took it. Idempotent, like bump and recall.

    Deliberately a third state rather than a delete: the ticket is the record
    that the kitchen made this food, and a report that counts what a station
    produced cannot count rows somebody removed from a board.
    """
    async with tenant_session(ctx.tenant_id) as session:
        t = await _get(session, ticket_id, ctx)
        if t.status != COLLECTED:
            t.status = COLLECTED
            await session.flush()
        return _out(t)


@router.post("/kds/lines/{line_id}/done", response_model=KitchenLineOut)
async def toggle_line(
    line_id: uuid.UUID,
    done: bool = Query(True),
    ctx: DeviceContext = Depends(current_device),
) -> KitchenLineOut:
    async with tenant_session(ctx.tenant_id) as session:
        ln = (
            await session.execute(
                select(KitchenTicketLine).where(
                    KitchenTicketLine.id == line_id,
                    KitchenTicketLine.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if ln is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such line")
        ln.done = done
        await session.flush()
        return KitchenLineOut.model_validate(ln)


async def _get(session, ticket_id: uuid.UUID, ctx: DeviceContext) -> KitchenTicket:
    t = (
        await session.execute(
            select(KitchenTicket)
            .options(selectinload(KitchenTicket.lines))
            .where(
                KitchenTicket.id == ticket_id,
                KitchenTicket.tenant_id == ctx.tenant_id,
                KitchenTicket.branch_id == ctx.branch_id,
            )
        )
    ).scalar_one_or_none()
    if t is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such ticket")
    return t
