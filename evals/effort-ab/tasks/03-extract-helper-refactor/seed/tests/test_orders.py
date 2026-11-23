import unittest

import orders


class CreateOrderTests(unittest.TestCase):
    def test_builds_an_order_dict(self):
        self.assertEqual(
            orders.create_order("A-1", 3, 250),
            {"id": "A-1", "quantity": 3, "unit_price_cents": 250},
        )

    def test_rejects_zero_quantity(self):
        with self.assertRaises(ValueError) as caught:
            orders.create_order("A-1", 0, 250)
        self.assertEqual(str(caught.exception), "quantity must be a positive integer")

    def test_rejects_bool_unit_price(self):
        with self.assertRaises(ValueError) as caught:
            orders.create_order("A-1", 1, True)
        self.assertEqual(str(caught.exception), "unit_price_cents must be a positive integer")


class UpdateQuantityTests(unittest.TestCase):
    def test_returns_an_updated_copy(self):
        original = {"id": "A-1", "quantity": 3, "unit_price_cents": 250}
        updated = orders.update_quantity(original, 5)
        self.assertEqual(updated, {"id": "A-1", "quantity": 5, "unit_price_cents": 250})
        self.assertEqual(original["quantity"], 3)

    def test_rejects_float_quantity(self):
        order = {"id": "A-1", "quantity": 3, "unit_price_cents": 250}
        with self.assertRaises(ValueError) as caught:
            orders.update_quantity(order, 2.0)
        self.assertEqual(str(caught.exception), "new_quantity must be a positive integer")


class SplitOrderTests(unittest.TestCase):
    def test_spreads_the_remainder_over_the_first_pieces(self):
        pieces = orders.split_order({"id": "A-1", "quantity": 7, "unit_price_cents": 100}, 3)
        self.assertEqual([piece["id"] for piece in pieces], ["A-1-1", "A-1-2", "A-1-3"])
        self.assertEqual([piece["quantity"] for piece in pieces], [3, 2, 2])

    def test_rejects_negative_parts(self):
        order = {"id": "A-1", "quantity": 7, "unit_price_cents": 100}
        with self.assertRaises(ValueError) as caught:
            orders.split_order(order, -1)
        self.assertEqual(str(caught.exception), "parts must be a positive integer")

    def test_rejects_more_parts_than_units(self):
        order = {"id": "A-1", "quantity": 2, "unit_price_cents": 100}
        with self.assertRaises(ValueError):
            orders.split_order(order, 3)


if __name__ == "__main__":
    unittest.main()
