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
from sqlalchemy import false as sa_false
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import selectinload

from ..auth import DeviceContext, current_device
from ..db import tenant_session
from ..models import (
    DiningTable,
    FloorSection,
    Reservation,
    SessionTable,
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
    SettleIn,
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
                        # A closed area is closed. Leaving it on the till gives
                        # waiters a tab that opens onto nothing, and the first
                        # one alphabetically becomes what the floor opens on.
                        FloorSection.is_active.is_(True),
                    )
                    .order_by(FloorSection.sort_order, FloorSection.name)
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
                        # A table off every plan is on the books, not in the
                        # room. Sending it would put it in whichever area
                        # sorted first, which is not where it is.
                        DiningTable.section_id.is_not(None),
                    )
                    .order_by(DiningTable.table_no)
                )
            )
            .scalars()
            .all()
        )

        # Open sessions, with what is owed and what has been taken, in one pass
        # rather than a query per table — a 150-table floor would otherwise be
        # 150 round trips. Split out by settled/not because a table where two
        # of the four have paid is neither free nor owing the whole bill.
        rows = (
            await session.execute(
                select(
                    TableSessionLine.session_id,
                    TableSessionLine.settled_sale_uuid.is_(None).label("owed"),
                    func.sum(
                        TableSessionLine.unit_price * TableSessionLine.qty
                    ),
                )
                .where(TableSessionLine.voided.is_(False))
                .group_by(
                    TableSessionLine.session_id,
                    TableSessionLine.settled_sale_uuid.is_(None),
                )
            )
        ).all()
        totals: dict[uuid.UUID, int] = {}
        settled_totals: dict[uuid.UUID, int] = {}
        for session_id, owed, amount in rows:
            target = totals if owed else settled_totals
            target[session_id] = target.get(session_id, 0) + int(amount or 0)

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

        # Tables pushed together with another. They belong to the session the
        # party is on, so the floor shows them occupied and tapping either one
        # reaches the same bill.
        merges = list(
            (
                await session.execute(
                    select(SessionTable).where(
                        SessionTable.tenant_id == ctx.tenant_id,
                        SessionTable.released_at.is_(None),
                        SessionTable.session_id.in_(
                            [s.id for s in open_sessions]
                        ) if open_sessions else sa_false(),
                    )
                )
            )
            .scalars()
            .all()
        )
        session_by_id = {s.id: s for s in open_sessions}
        for merge in merges:
            joined = session_by_id.get(merge.session_id)
            if joined is not None:
                by_table[merge.table_id] = joined

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

    # Which tables each party is sitting at, so both halves of a merge can say
    # so and a waiter tapping either one knows what they are walking into.
    party_tables: dict[uuid.UUID, list[int]] = {}
    for table in tables:
        s = by_table.get(table.id)
        if s is not None:
            party_tables.setdefault(s.id, []).append(table.table_no)
    for numbers in party_tables.values():
        numbers.sort()

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
                party_table_nos=party_tables.get(s.id, []) if s else [],
                guests=s.guests if s else None,
                opened_at=s.opened_at if s else None,
                running_total=gross if s else None,
                settled_total=settled_totals.get(s.id, 0) if s else 0,
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

        # Nor can it be half of a party sitting across two tables. The open
        # session lives on the party's other table, so the check above does not
        # see this one at all.
        merged = (
            await session.execute(
                select(SessionTable).where(
                    SessionTable.table_id == table_id,
                    SessionTable.released_at.is_(None),
                )
            )
        ).scalar_one_or_none()
        if merged is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"table {table.table_no} is part of another party "
                f"(session {merged.session_id})",
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
        # The sender names a parent by its position in this batch, because it
        # cannot know what line numbers the session is about to hand out.
        assigned = {index: next_no + index for index in range(len(body.lines))}
        for index, item in enumerate(body.lines):
            parent_no = None
            if item.parent_index is not None:
                if item.parent_index > index:
                    # Forward references would let a line be its own ancestor,
                    # and the till builds parents before children anyway.
                    raise HTTPException(
                        status.HTTP_400_BAD_REQUEST,
                        f"line {index + 1} says it was chosen inside line "
                        f"{item.parent_index}, which comes after it",
                    )
                parent_no = assigned[item.parent_index - 1]
            session.add(
                TableSessionLine(
                    tenant_id=ctx.tenant_id,
                    session_id=ts.id,
                    line_no=assigned[index],
                    prodnum=item.prodnum,
                    line_des=item.line_des,
                    qty=item.qty,
                    unit_price=item.unit_price,
                    parent_line_no=parent_no,
                    seat_no=item.seat_no,
                    note=item.note,
                    ordered_at=now,
                )
            )

        await session.flush()
        await session.refresh(ts, ["lines"])

        table = (
            await session.execute(
                select(DiningTable).where(DiningTable.id == ts.table_id)
            )
        ).scalar_one()
        return _detail(ts, table, sorted(ts.lines, key=lambda x: x.line_no))


async def _live_session(session, session_id: uuid.UUID, tenant_id: uuid.UUID):
    """The open session, with its lines, or a 404/409 explaining why not."""
    ts = (
        await session.execute(
            select(TableSession)
            .options(selectinload(TableSession.lines))
            .where(
                TableSession.id == session_id,
                TableSession.tenant_id == tenant_id,
            )
        )
    ).scalar_one_or_none()
    if ts is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no such session")
    if ts.status != OPEN:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "that table has already been settled"
        )
    return ts


async def _party_tables(session, ts) -> list[DiningTable]:
    """Every table this party is sitting at, its own first."""
    joined = list(
        (
            await session.execute(
                select(SessionTable).where(
                    SessionTable.session_id == ts.id,
                    SessionTable.released_at.is_(None),
                )
            )
        )
        .scalars()
        .all()
    )
    ids = [ts.table_id] + [m.table_id for m in joined]
    rows = list(
        (
            await session.execute(
                select(DiningTable).where(DiningTable.id.in_(ids))
            )
        )
        .scalars()
        .all()
    )
    rows.sort(key=lambda t: (t.id != ts.table_id, t.table_no))
    return rows


@router.post("/sessions/{session_id}/tables/{table_id}",
             response_model=TableSessionDetail)
async def join_table(
    session_id: uuid.UUID,
    table_id: uuid.UUID,
    guests: int | None = Query(
        None, description="the party size now the tables are together"
    ),
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Push another table onto this party — two twos for a four.

    One party, one order, one bill. The alternative a till without this forces
    is two sessions for one table of people, which splits their order across
    two kitchen tickets and two invoices and leaves the waiter reconciling it
    by hand.
    """
    async with tenant_session(ctx.tenant_id) as session:
        ts = await _live_session(session, session_id, ctx.tenant_id)

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
            raise HTTPException(
                status.HTTP_409_CONFLICT, "table is out of service"
            )
        if table.id == ts.table_id:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "that is the party's own table",
            )

        # It cannot be somebody else's, whether they seated it or merged it.
        taken = (
            await session.execute(
                select(TableSession).where(
                    TableSession.table_id == table_id,
                    TableSession.status == OPEN,
                )
            )
        ).scalar_one_or_none()
        if taken is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"table {table.table_no} is already open (session {taken.id})",
            )
        already = (
            await session.execute(
                select(SessionTable).where(
                    SessionTable.table_id == table_id,
                    SessionTable.released_at.is_(None),
                )
            )
        ).scalar_one_or_none()
        if already is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"table {table.table_no} is already part of another party",
            )

        session.add(SessionTable(
            tenant_id=ctx.tenant_id,
            session_id=ts.id,
            table_id=table_id,
            joined_at=_now(),
        ))
        try:
            await session.flush()
        except IntegrityError:
            # Two waiters merged the same table at once; the partial unique
            # index is what actually decides it.
            raise HTTPException(
                status.HTTP_409_CONFLICT, "table was taken by someone else"
            )

        tables = await _party_tables(session, ts)
        seats = sum(t.max_seats or t.seats for t in tables)
        if guests is not None:
            if guests > seats:
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    f"the tables together seat {seats}, not {guests}",
                )
            ts.guests = guests
            await session.flush()

        return _detail(ts, tables[0], sorted(ts.lines, key=lambda x: x.line_no),
                       tables=tables)


@router.delete("/sessions/{session_id}/tables/{table_id}",
               response_model=TableSessionDetail)
async def release_joined_table(
    session_id: uuid.UUID,
    table_id: uuid.UUID,
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Take a table back out of a party — merged by mistake, or they moved."""
    async with tenant_session(ctx.tenant_id) as session:
        ts = await _live_session(session, session_id, ctx.tenant_id)
        merge = (
            await session.execute(
                select(SessionTable).where(
                    SessionTable.session_id == session_id,
                    SessionTable.table_id == table_id,
                    SessionTable.released_at.is_(None),
                )
            )
        ).scalar_one_or_none()
        if merge is None:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND,
                "that table is not part of this party",
            )

        merge.released_at = _now()
        await session.flush()
        tables = await _party_tables(session, ts)
        return _detail(ts, tables[0], sorted(ts.lines, key=lambda x: x.line_no),
                       tables=tables)


async def _close(session, ts, sale_uuid: uuid.UUID | None) -> list[DiningTable]:
    """Settle the session itself and hand its tables back.

    Any tables pushed together for this party go back to being their own
    tables. Without this a four that sat on two twos leaves one of them
    occupied by a bill that has already been paid.
    """
    now = _now()
    if ts.sale_uuid is None:
        ts.sale_uuid = sale_uuid
    ts.status = BILLED if ts.sale_uuid else ABANDONED
    ts.closed_at = now

    tables = await _party_tables(session, ts)
    joined = list(
        (
            await session.execute(
                select(SessionTable).where(
                    SessionTable.session_id == ts.id,
                    SessionTable.released_at.is_(None),
                )
            )
        )
        .scalars()
        .all()
    )
    for merge in joined:
        merge.released_at = now
    await session.flush()
    return tables


@router.post("/sessions/{session_id}/lines/{line_no}/split",
             response_model=TableSessionDetail)
async def split_line(
    session_id: uuid.UUID,
    line_no: int,
    qty: float = Query(..., gt=0, description="how much moves onto a line of its own"),
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Break a quantity off a line so two guests can pay for one each.

    Two of a dish ring as one line of two; splitting the check between the
    people eating them needs two lines. Nothing about the order changes — the
    kitchen has already cooked both — so this only divides how the check is
    written, and each part is then settled by whoever pays for it.

    A line is paid for by exactly one bill. That invariant is why this exists
    at all: without it the only honest split of a shared line would be a bill
    for part of a line item, which is not something an invoice can describe.
    """
    async with tenant_session(ctx.tenant_id) as session:
        ts = await _live_session(session, session_id, ctx.tenant_id)

        by_no = {x.line_no: x for x in ts.lines}
        line = by_no.get(line_no)
        if line is None or line.voided:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND, f"line {line_no} is not on this check"
            )
        if line.settled_sale_uuid is not None:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"line {line_no} has already been paid for",
            )
        if line.parent_line_no is not None:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"line {line_no} was chosen inside line {line.parent_line_no}; "
                f"split that instead and this goes with it",
            )
        if qty >= float(line.qty):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"line {line_no} is only {float(line.qty)}; splitting {qty} off "
                f"it would leave nothing behind",
            )

        children: dict[int, list[TableSessionLine]] = {}
        for row in ts.lines:
            if row.parent_line_no is not None and not row.voided:
                children.setdefault(row.parent_line_no, []).append(row)

        next_no = max(x.line_no for x in ts.lines) + 1
        share = qty / float(line.qty)
        now = _now()

        def move(source: TableSessionLine, moved_qty: float,
                 parent: int | None) -> None:
            """Copy `moved_qty` of `source` onto a new line, and take it off."""
            nonlocal next_no
            mine = next_no
            next_no += 1
            session.add(
                TableSessionLine(
                    tenant_id=ctx.tenant_id,
                    session_id=ts.id,
                    line_no=mine,
                    prodnum=source.prodnum,
                    line_des=source.line_des,
                    qty=moved_qty,
                    unit_price=source.unit_price,
                    parent_line_no=parent,
                    seat_no=source.seat_no,
                    note=source.note,
                    # It was cooked with the original. Splitting the check does
                    # not send anything to the kitchen a second time.
                    sent_to_kitchen=source.sent_to_kitchen,
                    ordered_at=source.ordered_at or now,
                )
            )
            source.qty = float(source.qty) - moved_qty
            # Anything chosen inside it goes proportionally, so the drink that
            # came with two meals ends up as one drink under each.
            for child in children.get(source.line_no, []):
                move(child, float(child.qty) * share, mine)

        move(line, qty, None)
        await session.flush()
        await session.refresh(ts, ["lines"])

        tables = await _party_tables(session, ts)
        return _detail(ts, tables[0], sorted(ts.lines, key=lambda x: x.line_no),
                       tables=tables)


@router.post("/sessions/{session_id}/settle", response_model=TableSessionDetail)
async def settle_lines(
    session_id: uuid.UUID,
    body: SettleIn,
    ctx: DeviceContext = Depends(current_device),
) -> TableSessionDetail:
    """Record that a bill has paid for part of this check.

    Four people eating together and paying separately is not one bill taken in
    several tenders — each of them gets their own tax invoice, stamped on the
    device that took their money. So payment is recorded against the lines it
    covered, and the table stays open until nothing on it is owed.

    An empty `line_nos` settles everything outstanding, which is the ordinary
    case: one table, one bill.
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

        by_no = {x.line_no: x for x in ts.lines if not x.voided}
        mine = [
            x for x in by_no.values() if x.settled_sale_uuid == body.sale_uuid
        ]
        if ts.status != OPEN:
            # The tablet retries this after a dropped connection. If this sale
            # is what closed the table, saying so again is not an error.
            if mine or ts.sale_uuid == body.sale_uuid:
                table = (
                    await session.execute(
                        select(DiningTable).where(DiningTable.id == ts.table_id)
                    )
                ).scalar_one()
                return _detail(
                    ts, table, sorted(ts.lines, key=lambda x: x.line_no)
                )
            raise HTTPException(
                status.HTTP_409_CONFLICT, "that table has already been settled"
            )

        unknown = [n for n in body.line_nos if n not in by_no]
        if unknown:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND,
                f"lines {sorted(unknown)} are not on this check",
            )

        if body.line_nos:
            wanted = set(body.line_nos)
            # A child always goes with its parent. Half of a meal deal is not
            # a thing anyone can be billed for, and an invoice carrying the
            # drink but not the sandwich it came inside does not describe
            # anything that was sold.
            children: dict[int, list[int]] = {}
            for line in by_no.values():
                if line.parent_line_no is not None:
                    children.setdefault(line.parent_line_no, []).append(
                        line.line_no
                    )
            queue = list(wanted)
            while queue:
                for child in children.get(queue.pop(), []):
                    if child not in wanted:
                        wanted.add(child)
                        queue.append(child)
            orphans = [
                n for n in sorted(wanted)
                if by_no[n].parent_line_no is not None
                and by_no[n].parent_line_no not in wanted
                and by_no[by_no[n].parent_line_no].settled_sale_uuid
                != body.sale_uuid
            ]
            if orphans:
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    f"lines {orphans} were chosen inside another item; they "
                    f"can only be billed with it",
                )
            targets = [by_no[n] for n in sorted(wanted)]
        else:
            targets = [
                x for x in sorted(by_no.values(), key=lambda x: x.line_no)
                if x.settled_sale_uuid is None
            ]

        taken = [
            x for x in targets
            if x.settled_sale_uuid is not None
            and x.settled_sale_uuid != body.sale_uuid
        ]
        if taken:
            # Two waiters settled overlapping halves of one check. Charging
            # the same food twice is the one outcome a split must never have,
            # and the second bill has already been taken on a device — so this
            # has to be loud enough that somebody refunds it.
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"lines {[x.line_no for x in taken]} have already been paid "
                f"for by another bill",
            )

        for line in targets:
            line.settled_sale_uuid = body.sale_uuid
        # The first bill against this check gets to name the session. On a
        # split there is no single one — which is exactly why the lines carry
        # theirs — but leaving it null while guests pay would make an open
        # table that has already taken money look untouched.
        if ts.sale_uuid is None:
            ts.sale_uuid = body.sale_uuid
        await session.flush()

        outstanding = [
            x for x in by_no.values() if x.settled_sale_uuid is None
        ]
        tables = None
        if not outstanding:
            tables = await _close(session, ts, body.sale_uuid)
        else:
            await session.refresh(ts, ["lines"])
            tables = await _party_tables(session, ts)

        return _detail(ts, tables[0], sorted(ts.lines, key=lambda x: x.line_no),
                       tables=tables)


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

        owed = [
            x for x in ts.lines
            if not x.voided and x.settled_sale_uuid is None
        ]
        if sale_uuid is None and owed:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "session has ordered items; closing it needs the sale it was "
                "billed to, or those items vanish without a bill",
            )

        # Whatever is still owed goes onto this bill. A billed session with
        # unsettled lines on it would read as food nobody paid for, and the
        # split path would let a second bill claim them.
        for line in owed:
            line.settled_sale_uuid = sale_uuid

        tables = await _close(session, ts, sale_uuid)
        return _detail(ts, tables[0], sorted(ts.lines, key=lambda x: x.line_no),
                       tables=tables)


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

def _line_gross(line) -> int:
    return int(round(line.unit_price * float(line.qty)))


def _detail(ts, table, lines, tables=None) -> TableSessionDetail:
    live = [x for x in lines if not x.voided]
    gross = sum(_line_gross(x) for x in live)
    settled = sum(_line_gross(x) for x in live if x.settled_sale_uuid is not None)
    net, tax = split_inclusive(gross)
    party = tables or [table]
    return TableSessionDetail(
        session_id=ts.id,
        table_id=ts.table_id,
        table_no=table.table_no,
        status=ts.status,
        done_soon=ts.done_soon,
        party_table_nos=sorted(t.table_no for t in party),
        seats=sum(t.max_seats or t.seats for t in party),
        guests=ts.guests,
        opened_at=ts.opened_at,
        closed_at=ts.closed_at,
        sale_uuid=ts.sale_uuid,
        lines=[TableSessionLineOut.model_validate(x) for x in lines],
        net_total=net,
        tax_total=tax,
        gross_total=gross,
        settled_total=settled,
        outstanding_total=gross - settled,
    )
