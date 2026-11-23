import unittest

from catalog.client import CatalogClient


class CatalogClientTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def fetch(endpoint, params):
            self.calls.append((endpoint, dict(params)))
            return {"endpoint": endpoint, "params": dict(params)}

        self.client = CatalogClient(fetch)

    def test_miss_then_hit(self):
        first = self.client.list_items(page=2)
        second = self.client.list_items(page=2)
        self.assertIs(first, second)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.client.cache.hits, self.client.cache.misses), (1, 1))

    def test_backend_receives_endpoint_and_defaults(self):
        self.client.list_items(tags=["a"])
        self.assertEqual(self.calls, [("items", {"tags": ["a"], "limit": 50, "page": 1})])

    def test_false_flag_is_a_different_request(self):
        self.client.list_items()
        self.client.list_items(archived=False)
        self.assertEqual(len(self.calls), 2)

    def test_tag_order_does_not_matter(self):
        self.client.list_items(tags=["a", "b"])
        self.client.list_items(tags=["b", "a"])
        self.assertEqual(len(self.calls), 1)

    def test_same_params_dict_sends_the_same_request_twice(self):
        params = {"tags": ["x"]}
        self.client.list_items(params, page=2)
        self.client.list_items(params)
        self.assertEqual([call[1]["page"] for call in self.calls], [2, 1])
        self.assertEqual(params, {"tags": ["x"]})


if __name__ == "__main__":
    unittest.main()
