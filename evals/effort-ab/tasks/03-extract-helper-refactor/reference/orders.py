"""Order helpers.

An order is a plain dict:

    {"id": str, "quantity": int, "unit_price_cents": int}

Quantities, prices and part counts are positive integers.  ``bool`` is rejected
even though it is an ``int`` subclass, and every rejection is a ``ValueError``
that names the offending argument.
"""


def _require_positive_int(value, name):
    """Raise ``ValueError`` unless ``value`` is a positive ``int`` (``bool`` is not)."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{name} must be a positive integer")


def create_order(order_id, quantity, unit_price_cents):
    """Return a new order dict.

    ``quantity`` is validated first, then ``unit_price_cents``.
    """
    _require_positive_int(quantity, "quantity")
    _require_positive_int(unit_price_cents, "unit_price_cents")
    return {"id": order_id, "quantity": quantity, "unit_price_cents": unit_price_cents}


def update_quantity(order, new_quantity):
    """Return a copy of ``order`` with its quantity replaced.

    ``order`` itself is left untouched.  ``new_quantity`` is validated before
    ``order`` is read.
    """
    _require_positive_int(new_quantity, "new_quantity")
    updated = dict(order)
    updated["quantity"] = new_quantity
    return updated


def split_order(order, parts):
    """Split ``order`` into ``parts`` orders and return them as a list.

    The piece quantities add up to the original quantity; the first
    ``quantity % parts`` pieces get one extra unit.  Piece ids are the original
    id plus "-1", "-2", ... and every other field is copied unchanged.

    ``parts`` is validated before ``order`` is read.  Asking for more parts
    than there are units raises ``ValueError``.
    """
    _require_positive_int(parts, "parts")
    quantity = order["quantity"]
    if parts > quantity:
        raise ValueError(f"cannot split an order of {quantity} into {parts} parts")
    base, extra = divmod(quantity, parts)
    pieces = []
    for index in range(parts):
        piece = dict(order)
        piece["id"] = f"{order['id']}-{index + 1}"
        piece["quantity"] = base + (1 if index < extra else 0)
        pieces.append(piece)
    return pieces
