"""Which price a product rings at.

A restaurant charges different prices for the same dish depending on how the
order reaches the customer. At the first customer, HUMMOS is 8.00 at the drive
thru and 9.00 on Keeta; the difference is the aggregator's commission, and
charging tier A on a delivery order hands that margin away on every one of
them — 9,641 orders in the recorded history.

The rule lives here rather than in a router so there is exactly one answer to
"what does this cost", and so it can be tested against the real sales it was
derived from.
"""

from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal

TIERS = "abcdefghij"

# PixelPoint stores the tier as SalesType.ForcePrice: 0 means the default tier,
# otherwise it is 1-based (2 -> B, 10 -> J).
FORCE_PRICE_TO_TIER = {0: "a", 1: "a", 2: "b", 3: "c", 4: "d", 5: "e",
                       6: "f", 7: "g", 8: "h", 9: "i", 10: "j"}


class PriceUnavailable(Exception):
    """The product has no price on the tier this sale type demands."""


def tier_from_force_price(force_price: int | None) -> str:
    """Map PixelPoint's ForcePrice onto a tier letter."""
    if force_price is None:
        return "a"
    tier = FORCE_PRICE_TO_TIER.get(force_price)
    if tier is None:
        raise ValueError(f"unknown ForcePrice value {force_price}")
    return tier


def price_for(product, tier: str, *, allow_zero: bool = False) -> int:
    """The VAT-inclusive halalas a product rings at on `tier`.

    `allow_zero` is for comp tiers — staff meals and press visits ring at zero
    on purpose, and that is a real price, not a missing one. On a paying tier a
    zero means the product was never priced for it, which must not silently
    fall back to tier A: that would undercharge an aggregator order by the
    commission, and nobody would notice until the monthly reconciliation.
    """
    if tier not in TIERS:
        raise ValueError(f"unknown price tier {tier!r}")

    value = getattr(product, f"price_{tier}", None)

    if value is None or (value == 0 and not allow_zero):
        if tier == "a":
            raise PriceUnavailable(
                f"product {getattr(product, 'prodnum', '?')} has no base price"
            )
        raise PriceUnavailable(
            f"product {getattr(product, 'prodnum', '?')} has no price on tier "
            f"{tier.upper()}; it cannot be sold on this order type until one is set"
        )

    return int(value)


def resolve_line_price(product, sales_type) -> int:
    """Price for one line, given the product and how the order is being taken."""
    tier = (sales_type.price_tier or "a").lower() if sales_type else "a"
    # A comp tier is allowed to be zero; a paying tier is not.
    comp = bool(sales_type) and tier == "j"
    return price_for(product, tier, allow_zero=comp)


def split_inclusive(gross: int, vat_percent: Decimal = Decimal("15")) -> tuple[int, int]:
    """VAT-inclusive halalas -> (net, tax).

    Tax is the remainder so net + tax is exactly what the customer pays. The
    same rule as the till, the invoice builder and the table sessions — three
    places computing VAT three ways is how a bill ends up a halala out.
    """
    net = int(
        (Decimal(gross) * 100 / (100 + vat_percent)).quantize(
            Decimal("1"), rounding=ROUND_HALF_UP
        )
    )
    return net, gross - net
