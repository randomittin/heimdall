"""Hidden behavioural test for 03-extract-helper-refactor (stdlib only).

The refactor must not change behaviour, so this passes on the seed AND on a
correct refactor.  Run with the agent's workdir on PYTHONPATH (accept.sh does).
"""
import os
import signal
import sys
import unittest


def _watchdog(signum, frame):
    sys.stderr.write("hidden test timed out (likely an infinite loop)\n")
    os._exit(124)


signal.signal(signal.SIGALRM, _watchdog)
signal.alarm(8)

import orders  # noqa: E402

INVALID = [
    0, -1, -(10 ** 9), True, False, 1.0, 2.5, float("nan"), float("inf"),
    "3", "", None, [], (1,), {}, b"1", 1 + 0j,
]
VALID = [1, 2, 7, 10 ** 30]


def make_order(**overrides):
    order = {"id": "A-1", "quantity": 6, "unit_price_cents": 125}
    order.update(overrides)
    return order


class ExactValueErrorMixin:
    def assertRejects(self, message, func, *args, **kwargs):
        with self.assertRaises(ValueError) as caught:
            func(*args, **kwargs)
        self.assertIs(type(caught.exception), ValueError)
        self.assertEqual(str(caught.exception), message)


class CreateOrderBehaviour(ExactValueErrorMixin, unittest.TestCase):
    def test_valid_values_build_the_order(self):
        for quantity in VALID:
            for price in VALID:
                with self.subTest(quantity=quantity, price=price):
                    self.assertEqual(
                        orders.create_order("X", quantity, price),
                        {"id": "X", "quantity": quantity, "unit_price_cents": price},
                    )

    def test_keyword_arguments_and_any_id(self):
        self.assertEqual(
            orders.create_order(order_id=None, quantity=2, unit_price_cents=3),
            {"id": None, "quantity": 2, "unit_price_cents": 3},
        )

    def test_invalid_quantity(self):
        for bad in INVALID:
            with self.subTest(bad=bad):
                self.assertRejects("quantity must be a positive integer",
                                   orders.create_order, "X", bad, 100)

    def test_invalid_unit_price(self):
        for bad in INVALID:
            with self.subTest(bad=bad):
                self.assertRejects("unit_price_cents must be a positive integer",
                                   orders.create_order, "X", 3, bad)

    def test_quantity_is_validated_before_unit_price(self):
        for bad_quantity in (0, True, "1", None):
            for bad_price in (0, False, 2.5, None):
                with self.subTest(quantity=bad_quantity, price=bad_price):
                    self.assertRejects("quantity must be a positive integer",
                                       orders.create_order, "X", bad_quantity, bad_price)

    def test_bool_is_rejected_even_though_it_is_an_int(self):
        self.assertRejects("quantity must be a positive integer",
                           orders.create_order, "X", True, 5)
        self.assertRejects("unit_price_cents must be a positive integer",
                           orders.create_order, "X", 5, True)


class UpdateQuantityBehaviour(ExactValueErrorMixin, unittest.TestCase):
    def test_returns_updated_copy_and_keeps_other_fields(self):
        original = make_order(note="gift")
        snapshot = dict(original)
        updated = orders.update_quantity(original, 9)
        self.assertEqual(updated, {"id": "A-1", "quantity": 9, "unit_price_cents": 125, "note": "gift"})
        self.assertIsNot(updated, original)
        self.assertEqual(original, snapshot)

    def test_valid_values(self):
        for quantity in VALID:
            with self.subTest(quantity=quantity):
                self.assertEqual(orders.update_quantity(make_order(), quantity)["quantity"], quantity)

    def test_invalid_new_quantity(self):
        for bad in INVALID:
            with self.subTest(bad=bad):
                self.assertRejects("new_quantity must be a positive integer",
                                   orders.update_quantity, make_order(), bad)

    def test_validation_happens_before_the_order_is_read(self):
        for broken_order in (None, "not an order", 42, object()):
            with self.subTest(order=broken_order):
                self.assertRejects("new_quantity must be a positive integer",
                                   orders.update_quantity, broken_order, 0)
                self.assertRejects("new_quantity must be a positive integer",
                                   orders.update_quantity, broken_order, True)


class SplitOrderBehaviour(ExactValueErrorMixin, unittest.TestCase):
    def quantities(self, quantity, parts):
        pieces = orders.split_order(make_order(quantity=quantity), parts)
        return [piece["quantity"] for piece in pieces]

    def test_remainder_goes_to_the_first_pieces(self):
        self.assertEqual(self.quantities(7, 3), [3, 2, 2])
        self.assertEqual(self.quantities(10, 4), [3, 3, 2, 2])
        self.assertEqual(self.quantities(5, 5), [1, 1, 1, 1, 1])
        self.assertEqual(self.quantities(4, 1), [4])
        self.assertEqual(self.quantities(9, 3), [3, 3, 3])

    def test_ids_and_copied_fields(self):
        original = make_order(quantity=5, note="fragile")
        snapshot = dict(original)
        pieces = orders.split_order(original, 2)
        self.assertEqual(pieces, [
            {"id": "A-1-1", "quantity": 3, "unit_price_cents": 125, "note": "fragile"},
            {"id": "A-1-2", "quantity": 2, "unit_price_cents": 125, "note": "fragile"},
        ])
        self.assertEqual(original, snapshot)
        self.assertIsNot(pieces[0], pieces[1])

    def test_invalid_parts(self):
        for bad in INVALID:
            with self.subTest(bad=bad):
                self.assertRejects("parts must be a positive integer",
                                   orders.split_order, make_order(), bad)

    def test_validation_happens_before_the_order_is_read(self):
        for broken_order in (None, {}, "not an order", object()):
            with self.subTest(order=broken_order):
                self.assertRejects("parts must be a positive integer",
                                   orders.split_order, broken_order, 0)
                self.assertRejects("parts must be a positive integer",
                                   orders.split_order, broken_order, True)

    def test_parts_are_validated_before_the_range_check(self):
        self.assertRejects("parts must be a positive integer",
                           orders.split_order, make_order(quantity=2), 0)
        self.assertRejects("parts must be a positive integer",
                           orders.split_order, make_order(quantity=2), False)

    def test_more_parts_than_units(self):
        self.assertRejects("cannot split an order of 2 into 5 parts",
                           orders.split_order, make_order(quantity=2), 5)
        self.assertRejects("cannot split an order of 1 into 2 parts",
                           orders.split_order, make_order(quantity=1), 2)


if __name__ == "__main__":
    unittest.main()
