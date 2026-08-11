"""Floor plan, table service and reservations.

The shared view of who is sitting where. While a branch is offline the hub
tablet is the authority — this is the copy that lets the back office see the
floor, lets a tablet recover its open tables after a restart, and lets a second
waiter see that table 12 already has an order on it.

Open table state is deliberately *not* the billing path. A sale is closed and
signed on the device and pushed through `POST /v1/sales`; the session here is
then marked billed. If this service is unreachable the till still sells.
"""

from __future__ import annotations

import datetime as dt
import uuid
from decimal import ROUND_HALF_UP, Decimal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import selectinload

from ..auth import DeviceContext, current_device
from ..db import tenant_session
from ..models import (
    DiningTable,
    FloorSection,
    Reservation,
    TableSession,
    TableSessionLine,
)
from ..schemas import (
    AddLinesIn,
    FloorResponse,
    FloorSectionOut,
    OpenTableIn,
    ReservationIn,
    ReservationOut,
    TableOut,
    TableSessionDetail,
    TableSessionLineOut,
)

router = APIRouter(tags=["floor"])

OPEN = "open"
BILLED = "billed"
CLOSED = "closed"
ABANDONED = "abandoned"


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def split_inclusive(gross: int, vat_percent: Decimal = Decimal("15")) -> tuple[int, int]:
    """VAT-inclusive halalas -> (net, tax).

    Tax is the remainder, never computed separately, so net + tax is always
    exactly what the guest will be asked to pay.
    """
    net = int(
        (Decimal(gross) * 100 / (100 + vat_percent)).quantize(
            Decimal("1"), rounding=ROUND_HALF_UP
        )
    )
    return net, gross - net


# --------------------------------------------------------------------------
# Floor
# --------------------------------------------------------------------------

@router.get("/floor", response_model=FloorResponse)
async def get_floor(ctx: DeviceContext = Depends(current_device)) -> FloorResponse:
    """The whole floor with live status — what a waiter sees on opening the app."""
    async with tenant_session(ctx.tenant_id) as session:
        sections = list(
            (
                await session.execute(
                    select(FloorSection)
                    .where(
                        FloorSection.tenant_id == ctx.tenant_id,
                        FloorSection.branch_id == ctx.branch_id,
                        FloorSection.is_deleted.is_(False),
                    )
                    .order_by(FloorSection.sort_order, FloorSection.code)
                )
            )
            .scalars()
            .all()
        )

        tables = list(
            (
                await session.execute(
                    select(DiningTable)
                    .where(
                        DiningTable.tenant_id == ctx.tenant_id,
                        DiningTable.branch_id == ctx.branch_id,
                        DiningTable.is_deleted.is_(False),
                    )
                    .order_by(DiningTable.table_no)
                )
            )
            .scalars()
            .all()
        )

        # Open sessions, with their running total, in one pass rather than a
        # query per table — a 150-table floor would otherwise be 150 round trips.
        totals = dict(
            (
                await session.execute(
                    select(
                        TableSessionLine.session_id,
                        func.sum(
                            TableSessionLine.unit_price * TableSessionLine.qty
                        ),
                    )
                    .where(TableSessionLine.voided.is_(False))
                    .group_by(TableSessionLine.session_id)
                )
            ).all()
        )

        open_sessions = list(
            (
                await session.execute(
                    select(TableSession).where(
                        TableSession.tenant_id == ctx.tenant_id,
                        TableSession.branch_id == ctx.branch_id,
                        TableSession.status == OPEN,
                    )
                )
            )
            .scalars()
            .all()
        )
        by_table = {s.table_id: s for s in open_sessions}

        now = _now()
        upcoming = list(
            (
                await session.execute(
                    select(Reservation)
                    .where(
                        Reservation.tenant_id == ctx.tenant_id,
                        Reservation.branch_id == ctx.branch_id,
                        Reservation.status == "booked",
                        Reservation.reserved_for >= now - dt.timedelta(hours=1),
                        Reservation.reserved_for <= now + dt.timedelta(hours=12),
                    )
                    .order_by(Reservation.reserved_for)
                )
            )
            .scalars()
            .all()
        )
        reserved_tables = {r.table_id for r in upcoming if r.table_id}

    out_tables = []
    for t in tables:
        s = by_table.get(t.id)
        gross = int(totals.get(s.id, 0)) if s else 0
        out_tables.append(
            TableOut(
                id=t.id,
                table_no=t.table_no,
                label=t.label,
                section_id=t.section_id,
                seats=t.seats,
                pos_x=t.pos_x,
                pos_y=t.pos_y,
                width=t.width,
                height=t.height,
                shape=t.shape,
                can_reserve=t.can_reserve,
                is_active=t.is_active,
                status=(OPEN if s else ("reserved" if t.id in reserved_tables else "free")),
                done_soon=bool(s and s.done_soon),
                session_id=s.id if s else None,
                opened_by=s.opened_by if s else None,
                guests=s.guests if s else None,
                opened_at=s.opened_at if s else None,
                running_total=gross if s else None,
            )
        )

    return FloorResponse(
        sections=[FloorSectionOut.model_validate(x) for x in sections],
        tables=out_tables,
        reservations=[ReservationOut.model_validate(r) for r in upcoming],
    )


# --------------------------------------------------------------------------
# Table sessions
# --------------------------------------------------------------------------

@router.post("/tables/{table_id}/open", response_model=TableSessionDetail)
async def open_table(
    table_id: uuid.UUID,
    body: OpenTableIn,
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Seat a table. Refuses if it is already occupied."""
    async with tenant_session(ctx.tenant_id) as session:
        table = (
            await session.execute(
                select(DiningTable).where(
                    DiningTable.id == table_id,
                    DiningTable.tenant_id == ctx.tenant_id,
                    DiningTable.branch_id == ctx.branch_id,
                )
            )
        ).scalar_one_or_none()
        if table is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such table")
        if not table.is_active:
            raise HTTPException(status.HTTP_409_CONFLICT, "table is out of service")

        existing = (
            await session.execute(
                select(TableSession).where(
                    TableSession.table_id == table_id,
                    TableSession.status == OPEN,
                )
            )
        ).scalar_one_or_none()
        if existing is not None:
            # Not an error the waiter caused — tell them who has it, so they can
            # join the existing bill rather than start a second one.
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"table {table.table_no} is already open (session {existing.id})",
            )

        if body.guests > (table.max_seats or table.seats):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"table {table.table_no} seats {table.max_seats or table.seats}, "
                f"not {body.guests}",
            )

        ts = TableSession(
            tenant_id=ctx.tenant_id,
            branch_id=ctx.branch_id,
            table_id=table_id,
            device_uuid=ctx.device_uuid,
            staff_id=body.staff_id,
            opened_by=body.opened_by,
            guests=body.guests,
            opened_at=_now(),
            status=OPEN,
        )
        session.add(ts)
        try:
            await session.flush()
        except IntegrityError:
            # Two waiters tapped the same free table at the same moment. The
            # partial unique index is what actually decides it.
            raise HTTPException(
                status.HTTP_409_CONFLICT, "table was opened by someone else"
            )

        return _detail(ts, table, [])


@router.get("/tables/{table_id}/session", response_model=TableSessionDetail)
async def get_table_session(
    table_id: uuid.UUID,
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    async with tenant_session(ctx.tenant_id) as session:
        table = (
            await session.execute(
                select(DiningTable).where(
                    DiningTable.id == table_id,
                    DiningTable.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if table is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such table")

        ts = (
            await session.execute(
                select(TableSession)
                .options(selectinload(TableSession.lines))
                .where(
                    TableSession.table_id == table_id,
                    TableSession.status == OPEN,
                )
            )
        ).scalar_one_or_none()
        if ts is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "table is not open")

        return _detail(ts, table, sorted(ts.lines, key=lambda x: x.line_no))


@router.post("/sessions/{session_id}/lines", response_model=TableSessionDetail)
async def add_lines(
    session_id: uuid.UUID,
    body: AddLinesIn,
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Add ordered items to an open table."""
    async with tenant_session(ctx.tenant_id) as session:
        ts = (
            await session.execute(
                select(TableSession)
                .options(selectinload(TableSession.lines))
                .where(
                    TableSession.id == session_id,
                    TableSession.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if ts is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such session")
        if ts.status != OPEN:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"session is {ts.status}; reopen the table to add items",
            )

        next_no = max((x.line_no for x in ts.lines), default=0) + 1
        now = _now()
        for item in body.lines:
            session.add(
                TableSessionLine(
                    tenant_id=ctx.tenant_id,
                    session_id=ts.id,
                    line_no=next_no,
                    prodnum=item.prodnum,
                    line_des=item.line_des,
                    qty=item.qty,
                    unit_price=item.unit_price,
                    seat_no=item.seat_no,
                    note=item.note,
                    ordered_at=now,
                )
            )
            next_no += 1

        await session.flush()
        await session.refresh(ts, ["lines"])

        table = (
            await session.execute(
                select(DiningTable).where(DiningTable.id == ts.table_id)
            )
        ).scalar_one()
        return _detail(ts, table, sorted(ts.lines, key=lambda x: x.line_no))


@router.post("/sessions/{session_id}/done-soon", response_model=TableSessionDetail)
async def mark_done_soon(
    session_id: uuid.UUID,
    done: bool = Query(True, description="false takes the marker off again"),
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Flag a table as nearly finished, so the floor shows it as freeing up.

    A hint for whoever is working the door, not a state the bill depends on:
    it changes the colour of a table and nothing else, and it goes away when
    the session closes.
    """
    async with tenant_session(ctx.tenant_id) as session:
        ts = (
            await session.execute(
                select(TableSession)
                .options(selectinload(TableSession.lines))
                .where(
                    TableSession.id == session_id,
                    TableSession.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if ts is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such session")
        if ts.status != OPEN:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "that table has already been settled",
            )

        ts.done_soon = done
        await session.flush()
        table = (
            await session.execute(
                select(DiningTable).where(DiningTable.id == ts.table_id)
            )
        ).scalar_one()
        return _detail(ts, table, sorted(ts.lines, key=lambda x: x.line_no))


@router.post("/sessions/{session_id}/close", response_model=TableSessionDetail)
async def close_session(
    session_id: uuid.UUID,
    sale_uuid: uuid.UUID | None = Query(
        None, description="the sale this table was billed to, once pushed"
    ),
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Free the table.

    `sale_uuid` links the session to the bill. Closing without one is allowed —
    a table abandoned without ordering is a real thing — but it is recorded as
    abandoned rather than billed so it does not look like lost revenue.
    """
    async with tenant_session(ctx.tenant_id) as session:
        ts = (
            await session.execute(
                select(TableSession)
                .options(selectinload(TableSession.lines))
                .where(
                    TableSession.id == session_id,
                    TableSession.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()
        if ts is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "no such session")

        if ts.status in (BILLED, CLOSED, ABANDONED):
            # Idempotent: the tablet retries this after a dropped connection.
            table = (
                await session.execute(
                    select(DiningTable).where(DiningTable.id == ts.table_id)
                )
            ).scalar_one()
            return _detail(ts, table, sorted(ts.lines, key=lambda x: x.line_no))

        has_lines = any(not x.voided for x in ts.lines)
        if sale_uuid is None and has_lines:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "session has ordered items; closing it needs the sale it was "
                "billed to, or those items vanish without a bill",
            )

        ts.sale_uuid = sale_uuid
        ts.status = BILLED if sale_uuid else ABANDONED
        ts.closed_at = _now()
        await session.flush()

        table = (
            await session.execute(
                select(DiningTable).where(DiningTable.id == ts.table_id)
            )
        ).scalar_one()
        return _detail(ts, table, sorted(ts.lines, key=lambda x: x.line_no))


# --------------------------------------------------------------------------
# Reservations
# --------------------------------------------------------------------------

@router.get("/reservations", response_model=list[ReservationOut])
async def list_reservations(
    on: dt.date | None = Query(None, description="business date; defaults to today"),
    ctx: DeviceContext = Depends(current_device),
) -> list[ReservationOut]:
    day = on or _now().date()
    start = dt.datetime.combine(day, dt.time.min, tzinfo=dt.timezone.utc)
    end = start + dt.timedelta(days=1)

    async with tenant_session(ctx.tenant_id) as session:
        rows = list(
            (
                await session.execute(
                    select(Reservation)
                    .where(
                        Reservation.tenant_id == ctx.tenant_id,
                        Reservation.branch_id == ctx.branch_id,
                        Reservation.reserved_for >= start,
                        Reservation.reserved_for < end,
                    )
                    .order_by(Reservation.reserved_for)
                )
            )
            .scalars()
            .all()
        )
    return [ReservationOut.model_validate(r) for r in rows]


@router.post("/reservations", response_model=ReservationOut, status_code=201)
async def create_reservation(
    body: ReservationIn,
    ctx: DeviceContext = Depends(current_device),
) -> ReservationOut:
    async with tenant_session(ctx.tenant_id) as session:
        if body.table_id is not None:
            table = (
                await session.execute(
                    select(DiningTable).where(
                        DiningTable.id == body.table_id,
                        DiningTable.tenant_id == ctx.tenant_id,
                        DiningTable.branch_id == ctx.branch_id,
                    )
                )
            ).scalar_one_or_none()
            if table is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "no such table")
            if not table.can_reserve:
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    f"table {table.table_no} cannot be reserved",
                )
            if body.party_size > (table.max_seats or table.seats):
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    f"table {table.table_no} seats {table.max_seats or table.seats}",
                )

            # Overlap check. Two bookings on one table at the same hour is a
            # promise the restaurant cannot keep.
            #
            # The end of an existing booking is start + duration, which SQL
            # cannot express portably (PostgreSQL has make_interval, SQLite does
            # not). A table has a handful of bookings a day, so the candidates
            # are fetched over a generous window and compared in Python.
            window_end = body.reserved_for + dt.timedelta(
                minutes=body.duration_minutes
            )
            candidates = list(
                (
                    await session.execute(
                        select(Reservation).where(
                            Reservation.table_id == body.table_id,
                            Reservation.status == "booked",
                            Reservation.reserved_for > body.reserved_for
                            - dt.timedelta(hours=12),
                            Reservation.reserved_for < window_end,
                        )
                    )
                )
                .scalars()
                .all()
            )
            for existing in candidates:
                start = existing.reserved_for
                if start.tzinfo is None:
                    start = start.replace(tzinfo=dt.timezone.utc)
                end = start + dt.timedelta(minutes=existing.duration_minutes)
                if start < window_end and end > body.reserved_for:
                    raise HTTPException(
                        status.HTTP_409_CONFLICT,
                        f"table already booked at {start:%H:%M}",
                    )

        res = Reservation(
            tenant_id=ctx.tenant_id,
            branch_id=ctx.branch_id,
            table_id=body.table_id,
            guest_name=body.guest_name,
            phone=body.phone,
            party_size=body.party_size,
            reserved_for=body.reserved_for,
            duration_minutes=body.duration_minutes,
            occasion=body.occasion,
            note=body.note,
        )
        session.add(res)
        await session.flush()
        return ReservationOut.model_validate(res)


# --------------------------------------------------------------------------

def _detail(ts, table, lines) -> TableSessionDetail:
    gross = sum(
        int(round(x.unit_price * float(x.qty))) for x in lines if not x.voided
    )
    net, tax = split_inclusive(gross)
    return TableSessionDetail(
        session_id=ts.id,
        table_id=ts.table_id,
        table_no=table.table_no,
        status=ts.status,
        done_soon=ts.done_soon,
        guests=ts.guests,
        opened_at=ts.opened_at,
        closed_at=ts.closed_at,
        sale_uuid=ts.sale_uuid,
        lines=[TableSessionLineOut.model_validate(x) for x in lines],
        net_total=net,
        tax_total=tax,
        gross_total=gross,
    )
