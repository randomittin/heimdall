import unittest

from pager import paginate


class PaginateTests(unittest.TestCase):
    def test_first_page(self):
        result = paginate(list(range(25)), 1, 10)
        self.assertEqual(result["items"], list(range(10)))
        self.assertEqual(result["page"], 1)
        self.assertEqual(result["pages"], 3)
        self.assertTrue(result["has_next"])
        self.assertFalse(result["has_prev"])

    def test_last_partial_page(self):
        result = paginate(list(range(25)), 3, 10)
        self.assertEqual(result["items"], [20, 21, 22, 23, 24])
        self.assertFalse(result["has_next"])
        self.assertTrue(result["has_prev"])

    def test_empty_list_has_one_empty_page(self):
        result = paginate([], 1, 10)
        self.assertEqual(result["items"], [])
        self.assertEqual(result["pages"], 1)
        self.assertEqual(result["total"], 0)

    def test_page_past_the_end_is_clamped(self):
        result = paginate(list(range(5)), 9, 2)
        self.assertEqual(result["page"], 3)
        self.assertEqual(result["items"], [4])

    def test_zero_per_page_raises(self):
        with self.assertRaises(ValueError):
            paginate([1, 2, 3], 1, 0)


if __name__ == "__main__":
    unittest.main()
