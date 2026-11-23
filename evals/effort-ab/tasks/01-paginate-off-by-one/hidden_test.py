"""Hidden acceptance test for 01-paginate-off-by-one (stdlib only).

Run with the agent's workdir on PYTHONPATH (accept.sh does this).
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

from pager import paginate  # noqa: E402

KEYS = {"items", "page", "per_page", "total", "pages", "has_next", "has_prev"}


def expected(items, page, per_page):
    """Independent restatement of the spec, used for the exhaustive sweep."""
    total = len(items)
    pages = max(1, (total + per_page - 1) // per_page)
    page = min(max(page, 1), pages)
    start = (page - 1) * per_page
    return {
        "items": items[start:start + per_page],
        "page": page,
        "per_page": per_page,
        "total": total,
        "pages": pages,
        "has_next": page < pages,
        "has_prev": page > 1,
    }


class PaginateHiddenTests(unittest.TestCase):
    def test_empty_list_is_one_empty_page(self):
        self.assertEqual(
            paginate([], 1, 10),
            {"items": [], "page": 1, "per_page": 10, "total": 0,
             "pages": 1, "has_next": False, "has_prev": False},
        )

    def test_empty_list_clamps_any_page_to_one(self):
        for page in (-5, 0, 2, 99):
            with self.subTest(page=page):
                result = paginate([], page, 3)
                self.assertEqual(result["page"], 1)
                self.assertEqual(result["pages"], 1)
                self.assertEqual(result["items"], [])
                self.assertIs(result["has_next"], False)
                self.assertIs(result["has_prev"], False)

    def test_exact_multiple_has_no_trailing_empty_page(self):
        items = list(range(20))
        first = paginate(items, 1, 10)
        self.assertEqual(first["items"], list(range(10)))
        self.assertEqual(first["pages"], 2)
        self.assertIs(first["has_next"], True)
        self.assertIs(first["has_prev"], False)
        second = paginate(items, 2, 10)
        self.assertEqual(second["items"], list(range(10, 20)))
        self.assertEqual(second["pages"], 2)
        self.assertIs(second["has_next"], False)
        self.assertIs(second["has_prev"], True)

    def test_one_past_an_exact_multiple_adds_a_page(self):
        items = list(range(21))
        self.assertEqual(paginate(items, 1, 10)["pages"], 3)
        last = paginate(items, 3, 10)
        self.assertEqual(last["items"], [20])
        self.assertIs(last["has_next"], False)
        self.assertIs(last["has_prev"], True)

    def test_clamp_low(self):
        items = list(range(5))
        for page in (0, -1, -100):
            with self.subTest(page=page):
                result = paginate(items, page, 2)
                self.assertEqual(result["page"], 1)
                self.assertEqual(result["items"], [0, 1])
                self.assertIs(result["has_prev"], False)
                self.assertIs(result["has_next"], True)

    def test_clamp_high(self):
        items = list(range(5))
        for page in (4, 10, 10 ** 9):
            with self.subTest(page=page):
                result = paginate(items, page, 2)
                self.assertEqual(result["page"], 3)
                self.assertEqual(result["items"], [4])
                self.assertIs(result["has_next"], False)
                self.assertIs(result["has_prev"], True)

    def test_middle_page_has_both_neighbours(self):
        result = paginate(list("abcdefghij"), 2, 3)
        self.assertEqual(result["items"], ["d", "e", "f"])
        self.assertEqual(result["pages"], 4)
        self.assertIs(result["has_next"], True)
        self.assertIs(result["has_prev"], True)

    def test_per_page_larger_than_total(self):
        for page in (1, 2, 50):
            with self.subTest(page=page):
                result = paginate([1, 2, 3], page, 10)
                self.assertEqual(result["items"], [1, 2, 3])
                self.assertEqual(result["page"], 1)
                self.assertEqual(result["pages"], 1)
                self.assertEqual(result["per_page"], 10)
                self.assertIs(result["has_next"], False)
                self.assertIs(result["has_prev"], False)

    def test_per_page_equal_to_total(self):
        result = paginate([1, 2, 3], 1, 3)
        self.assertEqual(result["pages"], 1)
        self.assertEqual(result["items"], [1, 2, 3])

    def test_per_page_one(self):
        result = paginate(list("abcde"), 3, 1)
        self.assertEqual(result["items"], ["c"])
        self.assertEqual(result["pages"], 5)
        self.assertIs(result["has_next"], True)
        self.assertIs(result["has_prev"], True)

    def test_larger_input(self):
        items = list(range(1000))
        result = paginate(items, 143, 7)
        self.assertEqual(result["pages"], 143)
        self.assertEqual(result["items"], items[994:])
        self.assertEqual(len(result["items"]), 6)
        self.assertIs(result["has_next"], False)

    def test_per_page_below_one_raises_value_error(self):
        for per_page in (0, -1, -3):
            for items in ([], [1, 2, 3]):
                for page in (1, 0, 99):
                    with self.subTest(per_page=per_page, items=items, page=page):
                        with self.assertRaises(ValueError):
                            paginate(items, page, per_page)

    def test_result_shape_and_types(self):
        result = paginate(list(range(7)), 2, 3)
        self.assertEqual(set(result), KEYS)
        self.assertIs(type(result["items"]), list)
        for key in ("page", "per_page", "total", "pages"):
            self.assertIs(type(result[key]), int, key)
        self.assertIs(type(result["has_next"]), bool)
        self.assertIs(type(result["has_prev"]), bool)

    def test_input_is_not_modified_and_slice_is_a_copy(self):
        items = [3, 1, 2]
        snapshot = list(items)
        result = paginate(items, 1, 10)
        self.assertEqual(items, snapshot)
        self.assertIsNot(result["items"], items)
        result["items"].append(99)
        self.assertEqual(items, snapshot)

    def test_exhaustive_sweep_against_the_spec(self):
        for total in range(0, 31):
            items = list(range(total))
            for per_page in range(1, 9):
                pages = max(1, (total + per_page - 1) // per_page)
                for page in range(-2, pages + 4):
                    with self.subTest(total=total, per_page=per_page, page=page):
                        self.assertEqual(
                            paginate(items, page, per_page),
                            expected(items, page, per_page),
                        )


if __name__ == "__main__":
    unittest.main()
