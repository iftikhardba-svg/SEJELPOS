"""POST /sales — device pushes closed sales.

Idempotency is the whole point of this endpoint. A tablet that loses its
connection mid-push will retry, and it must be impossible for that retry to
create a second sale: the customer was charged once. The device-generated
`sale_uuid` is the idempotency key, and a replay returns `duplicate` rather
than an error, so the device can clear its outbox and move on.

Sales are accepted individually inside a batch. One malformed sale must not
block the other nineteen — the device would retry the whole batch forever and
the outbox would never drain.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends
from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from ..auth import DeviceContext, current_device
from ..config import settings
from ..db import tenant_session
from ..models import Device, Sale, SaleLine, SalePayment, SalesType
from ..schemas import SaleAccepted, SaleBatchResponse, SaleIn

router = APIRouter(tags=["sales"])


def _validation_summary(exc: ValidationError) -> str:
    return "; ".join(e["msg"] for e in exc.errors())


@router.post("/sales", response_model=SaleBatchResponse)
async def push_sales(
    batch: list[dict],
    ctx: DeviceContext = Depends(current_device),
) -> SaleBatchResponse:
    # The batch arrives as raw dicts and each sale is validated individually.
    # Declaring `list[SaleIn]` here would let one malformed sale 422 the whole
    # request — exactly the poison-record behaviour this endpoint promises not
    # to have. Per-sale validation keeps the other nineteen flowing and gives
    # the device a per-sale verdict it can act on.
    accepted: list[SaleAccepted] = []
    rejected: list[dict] = []
    parsed: list[SaleIn] = []
    now = dt.datetime.now(dt.timezone.utc)

    for raw in batch:
        sale_uuid = str(raw.get("sale_uuid", "?")) if isinstance(raw, dict) else "?"
        try:
            incoming = SaleIn(**raw)
        except (ValidationError, TypeError) as exc:
            detail = (
                _validation_summary(exc)
                if isinstance(exc, ValidationError)
                else "sale is not an object"
            )
            rejected.append({"sale_uuid": sale_uuid, "error": detail})
            continue
        parsed.append(incoming)
        try:
            result = await _ingest_one(incoming, ctx, now)
            accepted.append(result)
        except ValueError as exc:
            rejected.append({"sale_uuid": str(incoming.sale_uuid), "error": str(exc)})

    async with tenant_session(ctx.tenant_id) as session:
        device = await session.get(Device, ctx.device_id)
        if device is not None:
            device.last_seen_at = now
            icvs = [s.zatca_icv for s in parsed if s.zatca_icv is not None]
            if icvs:
                device.last_icv = max(icvs)

    return SaleBatchResponse(accepted=accepted, rejected=rejected)


async def _ingest_one(
    incoming: SaleIn, ctx: DeviceContext, now: dt.datetime
) -> SaleAccepted:
    async with tenant_session(ctx.tenant_id) as session:
        existing = await session.get(Sale, incoming.sale_uuid)
        if existing is not None:
            # Replay. Confirm it is genuinely the same sale — a different
            # receipt under the same uuid means a device bug, and silently
            # accepting it would hide the duplicate charge.
            if existing.receipt_no != incoming.receipt_no:
                raise ValueError(
                    f"sale_uuid already exists with receipt {existing.receipt_no}, "
                    f"not {incoming.receipt_no}"
                )
            return SaleAccepted(
                sale_uuid=existing.sale_uuid,
                status="duplicate",
                receipt_no=existing.receipt_no,
            )

        # An aggregator sale without the platform's order id cannot be matched
        # when the platform disputes it. The device should have enforced this at
        # the till; the check here catches devices running older builds. Stored
        # anyway — the sale is real — but flagged, mirroring the stale-sale rule.
        agg_note = None
        if incoming.sale_type and not incoming.external_ref:
            st = (
                await session.execute(
                    select(SalesType).where(
                        SalesType.tenant_id == ctx.tenant_id,
                        SalesType.sale_type_no == incoming.sale_type,
                    )
                )
            ).scalar_one_or_none()
            if st is not None and st.requires_external_ref:
                agg_note = (
                    f"{st.descript} sale arrived without the platform's order "
                    "reference; it cannot be reconciled against the aggregator"
                )

        opened = incoming.opened_at
        if opened.tzinfo is None:
            opened = opened.replace(tzinfo=dt.timezone.utc)
        age_hours = (now - opened).total_seconds() / 3600
        if age_hours > settings.max_offline_hours:
            # Not a rejection: the sale is real and must be recorded. But it is
            # past ZATCA's reporting window, so it is flagged for follow-up.
            zatca_note = (
                f"sale reached the server {age_hours:.1f}h after it was opened, "
                f"beyond the {settings.max_offline_hours}h reporting window"
            )
        else:
            zatca_note = None

        sale = Sale(
            sale_uuid=incoming.sale_uuid,
            tenant_id=ctx.tenant_id,
            company_id=ctx.company_id,
            branch_id=ctx.branch_id,
            device_id=ctx.device_id,
            receipt_no=incoming.receipt_no,
            opened_at=incoming.opened_at,
            closed_at=incoming.closed_at,
            business_date=incoming.business_date,
            table_no=incoming.table_no,
            num_guests=incoming.num_guests,
            sale_type=incoming.sale_type,
            order_no=incoming.order_no,
            external_ref=incoming.external_ref,
            net_total=incoming.net_total,
            tax_total=incoming.tax_total,
            final_total=incoming.final_total,
            status=incoming.status,
            zatca_uuid=incoming.zatca_uuid,
            zatca_icv=incoming.zatca_icv,
            zatca_pih=incoming.zatca_pih,
            zatca_hash=incoming.zatca_hash,
            zatca_qr=incoming.zatca_qr,
            zatca_xml=incoming.zatca_xml,
            zatca_status="pending",
            zatca_error=zatca_note,
            erp_error=agg_note,
            erp_status="pending",
            received_at=now,
        )
        session.add(sale)

        for ln in incoming.lines:
            session.add(SaleLine(
                line_uuid=ln.line_uuid,
                sale_uuid=incoming.sale_uuid,
                tenant_id=ctx.tenant_id,
                line_no=ln.line_no,
                prodnum=ln.prodnum,
                line_des=ln.line_des,
                qty=ln.qty,
                unit_price=ln.unit_price,
                discount=ln.discount,
                net_amount=ln.net_amount,
                tax_amount=ln.tax_amount,
                line_total=ln.line_total,
                seat_no=ln.seat_no,
                parent_line=ln.parent_line,
                voided=ln.voided,
            ))

        for pm in incoming.payments:
            session.add(SalePayment(
                payment_uuid=pm.payment_uuid,
                sale_uuid=incoming.sale_uuid,
                tenant_id=ctx.tenant_id,
                methodnum=pm.methodnum,
                tender=pm.tender,
                change_given=pm.change_given,
                amount=pm.amount,
                auth_code=pm.auth_code,
                card_type=pm.card_type,
                paid_at=pm.paid_at,
                voided=pm.voided,
            ))

        try:
            await session.flush()
        except IntegrityError as exc:
            # The most likely cause is the (device_id, zatca_icv) unique index:
            # a device reusing an invoice counter value breaks its ZATCA hash
            # chain, and must not be quietly stored.
            raise ValueError(f"constraint violation: {exc.orig}") from exc

    return SaleAccepted(
        sale_uuid=incoming.sale_uuid,
        status="accepted",
        receipt_no=incoming.receipt_no,
    )


@router.get("/sales/{sale_uuid}/status")
async def sale_status(
    sale_uuid: uuid.UUID,
    ctx: DeviceContext = Depends(current_device),
) -> dict:
    """Let a device confirm what happened to a sale it pushed."""
    async with tenant_session(ctx.tenant_id) as session:
        sale = (
            await session.execute(
                select(Sale).where(
                    Sale.sale_uuid == sale_uuid,
                    Sale.tenant_id == ctx.tenant_id,
                )
            )
        ).scalar_one_or_none()

    if sale is None:
        return {"found": False}
    return {
        "found": True,
        "receipt_no": sale.receipt_no,
        "zatca_status": sale.zatca_status,
        "erp_status": sale.erp_status,
        "zatca_error": sale.zatca_error,
    }
