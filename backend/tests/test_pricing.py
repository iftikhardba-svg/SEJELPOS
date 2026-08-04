"""Price tier resolution.

The numbers here are taken from the first customer's real sales, not invented.
HUMMOS (product 2013) is priced 8.00 at tier A and 9.00 at tier B, and their
history shows it ringing at exactly those on walk-in and aggregator orders
respectively.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

import pytest

from app.pricing import (
    PriceUnavailable,
    price_for,
    resolve_line_price,
    split_inclusive,
    tier_from_force_price,
)


@dataclass
class FakeProduct:
    prodnum: int = 2013
    price_a: int | None = 800
    price_b: int | None = 900
    price_c: int | None = 0
    price_d: int | None = None
    price_e: int | None = None
    price_f: int | None = None
    price_g: int | None = None
    price_h: int | None = None
    price_i: int | None = None
    price_j: int | None = 0


@dataclass
class FakeType:
    price_tier: str = "a"


# --------------------------------------------------------------------------
# ForcePrice mapping

@pytest.mark.parametrize("force,tier", [
    (0, "a"),    # Dine-In, TakeAway, Drive Thru
    (2, "b"),    # HungerStation, Keeta, Jahez, Marsool, The Chefz
    (10, "j"),   # Staff Meal, MKRT-Blogger, MKRT-Photo Session
    (None, "a"),
])
def test_force_price_maps_to_tier(force, tier):
    assert tier_from_force_price(force) == tier


def test_unknown_force_price_is_refused():
    with pytest.raises(ValueError):
        tier_from_force_price(99)


# --------------------------------------------------------------------------
# Tier selection

def test_walk_in_pays_tier_a():
    assert resolve_line_price(FakeProduct(), FakeType("a")) == 800


def test_aggregator_pays_tier_b():
    """The 100-halala difference is the aggregator's commission."""
    assert resolve_line_price(FakeProduct(), FakeType("b")) == 900


def test_aggregator_price_is_higher_than_walk_in():
    p = FakeProduct()
    assert resolve_line_price(p, FakeType("b")) > resolve_line_price(p, FakeType("a"))


def test_comp_tier_is_allowed_to_be_zero():
    """Staff meals and press visits ring at zero on purpose."""
    assert resolve_line_price(FakeProduct(), FakeType("j")) == 0


def test_missing_paying_tier_refuses_rather_than_falling_back():
    """The dangerous case.

    Falling back to tier A on an aggregator order undercharges by the
    commission on every line, and nothing surfaces it until someone reconciles
    the month. Better to refuse the sale and have the price fixed.
    """
    p = FakeProduct(price_b=None)
    with pytest.raises(PriceUnavailable, match="tier B"):
        resolve_line_price(p, FakeType("b"))


def test_zero_on_a_paying_tier_is_also_refused():
    p = FakeProduct(price_c=0)
    with pytest.raises(PriceUnavailable):
        resolve_line_price(p, FakeType("c"))


def test_missing_base_price_is_refused():
    p = FakeProduct(price_a=0)
    with pytest.raises(PriceUnavailable, match="no base price"):
        resolve_line_price(p, FakeType("a"))


def test_no_sale_type_falls_back_to_base_tier():
    assert resolve_line_price(FakeProduct(), None) == 800


def test_unknown_tier_is_refused():
    with pytest.raises(ValueError):
        price_for(FakeProduct(), "z")


# --------------------------------------------------------------------------
# VAT split — must agree with the till, the invoice builder and table sessions

@pytest.mark.parametrize("gross,net,tax", [
    (800, 696, 104),      # HUMMOS at tier A
    (900, 783, 117),      # HUMMOS at tier B
    (3800, 3304, 496),    # MOUSHAKAL SABAH
    (0, 0, 0),
])
def test_known_vat_splits(gross, net, tax):
    assert split_inclusive(gross) == (net, tax)


def test_split_never_loses_a_halala():
    for gross in range(0, 20001):
        net, tax = split_inclusive(gross)
        assert net + tax == gross, f"broke at {gross}"


def test_split_matches_the_historical_net_prices():
    """PixelPoint stored line prices VAT-exclusive; ours must land on the same
    figure. HUMMOS at 8.00 inclusive was recorded as 6.9565 net."""
    net, _ = split_inclusive(800)
    assert net == 696                                   # 6.96 to the halala
    assert abs(Decimal(net) / 100 - Decimal("6.9565")) < Decimal("0.005")

    net_b, _ = split_inclusive(900)
    assert abs(Decimal(net_b) / 100 - Decimal("7.8261")) < Decimal("0.005")
