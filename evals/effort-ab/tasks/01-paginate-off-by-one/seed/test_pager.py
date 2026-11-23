import unittest

from pager import paginate


class PaginateTest(unittest.TestCase):
    def test_first_page(self):
        self.assertEqual(paginate(list(range(10)), 1, 3)["items"], [0, 1, 2])

    def test_second_page(self):
        self.assertEqual(paginate(list(range(10)), 2, 3)["items"], [3, 4, 5])

    def test_page_count_rounds_up(self):
        self.assertEqual(paginate(list(range(10)), 1, 3)["pages"], 4)


if __name__ == "__main__":
    unittest.main()
