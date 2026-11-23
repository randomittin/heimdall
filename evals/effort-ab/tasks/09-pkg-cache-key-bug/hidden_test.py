"""Hidden acceptance test for 09-pkg-cache-key-bug. Imports catalog from the cwd."""
import copy
import itertools
import os
import sys
import types
import unittest
from collections import OrderedDict

sys.path.insert(0, os.getcwd())

from catalog.cache import Cache  # noqa: E402
from catalog.client import CatalogClient  # noqa: E402
from catalog.keys import build_key  # noqa: E402


class Backend:
    """Records every call and returns a fresh object describing it."""

    def __init__(self):
        self.calls = []

    def __call__(self, endpoint, params):
        self.calls.append((endpoint, copy.deepcopy(params)))
        return {"call": len(self.calls), "page": params.get("page"), "limit": params.get("limit")}

    @property
    def sent(self):
        return [params for _endpoint, params in self.calls]


class KeyTests(unittest.TestCase):
    def assertSame(self, a, b, endpoint="items"):
        self.assertEqual(build_key(endpoint, a), build_key(endpoint, b), (a, b))

    def assertDifferent(self, a, b, endpoint="items"):
        self.assertNotEqual(build_key(endpoint, a), build_key(endpoint, b), (a, b))

    def test_key_is_a_deterministic_hashable_str(self):
        key = build_key("items", {"a": 1, "tags": ["x", "y"]})
        self.assertIsInstance(key, str)
        self.assertEqual(key, build_key("items", {"a": 1, "tags": ["x", "y"]}))
        self.assertEqual(hash(key), hash(build_key("items", {"tags": ["y", "x"], "a": 1})))

    def test_only_none_is_dropped(self):
        self.assertSame({"a": None}, {})
        self.assertSame({"a": None, "b": 1}, {"b": 1})
        self.assertSame({"a": None, "b": None}, {})

    def test_falsy_values_are_kept(self):
        for name, value in (("page", 0), ("flag", False), ("q", ""), ("tags", []), ("tags", ()),
                            ("ratio", 0.0), ("tags", set())):
            with self.subTest(name=name, value=value):
                self.assertDifferent({name: value}, {})
        self.assertDifferent({"page": 0}, {"page": 1})
        self.assertDifferent({"flag": False}, {"flag": True})
        self.assertDifferent({"page": 0}, {"page": None})
        self.assertDifferent({"q": ""}, {"q": "x"})
        self.assertDifferent({"flag": False, "page": 2}, {"page": 2})

    def test_values_keep_their_type(self):
        pairs = [(1, "1"), (True, 1), (False, 0), (0, "0"), (False, "0"), (False, ""), (None, "None")]
        for left, right in pairs:
            with self.subTest(left=left, right=right):
                if left is None:
                    self.assertDifferent({"x": right}, {})
                else:
                    self.assertDifferent({"x": left}, {"x": right})
        self.assertDifferent({"x": [1, 2]}, {"x": ["1", "2"]})
        self.assertDifferent({"x": ["1"]}, {"x": [1]})
        self.assertDifferent({"x": [True]}, {"x": [1]})

    def test_parameter_insertion_order_is_irrelevant(self):
        self.assertSame({"a": 1, "b": 2, "c": [1, 2]}, {"c": [1, 2], "b": 2, "a": 1})
        self.assertSame(OrderedDict([("a", 1), ("b", 2)]), OrderedDict([("b", 2), ("a", 1)]))
        self.assertSame({"z": 0, "y": False, "x": ""}, {"x": "", "y": False, "z": 0})

    def test_collections_are_unordered(self):
        self.assertSame({"tags": ["a", "b"]}, {"tags": ["b", "a"]})
        self.assertSame({"tags": ["a", "b"]}, {"tags": ("b", "a")})
        self.assertSame({"tags": ["a", "b"]}, {"tags": {"a", "b"}})
        self.assertSame({"tags": ["a", "b"]}, {"tags": frozenset(["b", "a"])})
        self.assertSame({"x": [1, "a", True, 2.5]}, {"x": [True, 2.5, "a", 1]})
        base = build_key("items", {"tags": ["c", "a", "b", "d"]})
        for permutation in itertools.permutations(["c", "a", "b", "d"]):
            self.assertEqual(build_key("items", {"tags": list(permutation)}), base)

    def test_collections_still_distinguish_content(self):
        self.assertDifferent({"tags": ["a", "a", "b"]}, {"tags": ["a", "b"]})
        self.assertDifferent({"tags": ["a"]}, {"tags": "a"})
        self.assertDifferent({"tags": ["a", "b"]}, {"tags": ["a", "c"]})
        self.assertDifferent({"tags": []}, {"tags": [""]})
        self.assertDifferent({"tags": ["a", "b"]}, {"other": ["a", "b"]})

    def test_separator_characters_cannot_cause_collisions(self):
        self.assertDifferent({"a": "1&b=2"}, {"a": "1", "b": "2"})
        self.assertDifferent({"a": ["x,y"]}, {"a": ["x", "y"]})
        self.assertDifferent({"a": 1, "b": 2}, {"a=1&b": 2})
        self.assertDifferent({"a": 1, "b": "2=3"}, {"a": 1, "b=2": 3})
        self.assertDifferent({"a": "x,y"}, {"a": ["x", "y"]})

    def test_endpoint_is_part_of_the_key(self):
        params = {"page": 1}
        self.assertNotEqual(build_key("items", params), build_key("other", params))
        self.assertEqual(build_key("items", params), build_key("items", {"page": 1}))

    def test_build_key_never_modifies_its_input(self):
        params = {"tags": ["b", "a"], "page": 0, "skip": None, "set": {"b", "a"}, "t": ("z", "y")}
        snapshot = copy.deepcopy(params)
        build_key("items", params)
        self.assertEqual(params, snapshot)
        self.assertEqual(list(params), list(snapshot))
        self.assertEqual(params["tags"], ["b", "a"])
        self.assertEqual(params["t"], ("z", "y"))


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.backend = Backend()
        self.client = CatalogClient(self.backend)

    def test_defaults_are_part_of_the_request(self):
        first = self.client.list_items()
        others = [
            self.client.list_items(page=1, limit=50),
            self.client.list_items({"page": 1}),
            self.client.list_items({"limit": 50}, page=1),
            self.client.list_items(limit=None, page=None),
            self.client.list_items({"limit": 50, "page": 1}),
            self.client.list_items(None),
        ]
        for other in others:
            self.assertIs(other, first)
        self.assertEqual(self.backend.calls, [("items", {"limit": 50, "page": 1})])
        self.assertEqual((self.client.cache.hits, self.client.cache.misses), (6, 1))
        self.assertEqual(len(self.client.cache), 1)

    def test_other_page_or_limit_is_another_request(self):
        self.assertEqual(self.client.list_items(page=1)["page"], 1)
        self.assertEqual(self.client.list_items(page=2)["page"], 2)
        self.assertEqual(self.client.list_items(page=2, limit=10)["limit"], 10)
        self.assertEqual(self.client.list_items(page=1)["page"], 1)
        self.assertEqual(self.client.list_items(page=2)["page"], 2)
        self.assertEqual(len(self.backend.calls), 3)
        self.assertEqual(self.backend.sent[1], {"page": 2, "limit": 50})

    def test_falsy_params_are_distinct_requests(self):
        self.client.list_items()
        self.client.list_items(archived=False)
        self.client.list_items(archived=True)
        self.client.list_items(page=0)
        self.client.list_items(q="")
        self.client.list_items(tags=[])
        self.assertEqual(len(self.backend.calls), 6)
        self.assertEqual(self.backend.sent[1], {"archived": False, "limit": 50, "page": 1})
        self.assertEqual(self.backend.sent[3], {"page": 0, "limit": 50})
        self.assertEqual(self.backend.sent[4], {"q": "", "limit": 50, "page": 1})
        self.assertEqual(self.backend.sent[5], {"tags": [], "limit": 50, "page": 1})
        self.client.list_items(archived=False)
        self.client.list_items(page=0)
        self.assertEqual(len(self.backend.calls), 6)

    def test_none_means_not_given_everywhere(self):
        self.client.list_items()
        self.client.list_items(archived=None)
        self.assertEqual(len(self.backend.calls), 1)
        self.client.list_items(archived=None, tags=["a"])
        self.assertEqual(self.backend.sent[1], {"tags": ["a"], "limit": 50, "page": 1})

    def test_tag_order_and_parameter_order_hit_the_same_entry(self):
        first = self.client.list_items(tags=["b", "a"], page=2)
        self.assertIs(self.client.list_items(tags=["a", "b"], page=2), first)
        self.assertIs(self.client.list_items(page=2, tags=("a", "b")), first)
        self.assertIs(self.client.list_items({"page": 2, "tags": {"a", "b"}}), first)
        self.assertEqual(len(self.backend.calls), 1)
        self.assertEqual(self.backend.sent[0]["tags"], ["b", "a"])
        self.assertEqual((self.client.cache.hits, self.client.cache.misses), (3, 1))
        self.client.list_items({"x": 1, "y": 2})
        self.client.list_items({"y": 2, "x": 1})
        self.assertEqual(len(self.backend.calls), 2)

    def test_falsy_results_are_cached(self):
        calls = []

        def fetch(endpoint, params):
            calls.append(params)
            return [] if len(calls) == 1 else None

        client = CatalogClient(fetch)
        self.assertEqual(client.list_items(page=3), [])
        self.assertEqual(client.list_items(page=3), [])
        self.assertIsNone(client.list_items(page=4))
        self.assertIsNone(client.list_items(page=4))
        self.assertEqual(len(calls), 2)

    def test_failed_fetch_is_not_cached(self):
        state = {"calls": 0}

        def flaky(endpoint, params):
            state["calls"] += 1
            if state["calls"] == 1:
                raise RuntimeError("backend down")
            return "ok"

        client = CatalogClient(flaky)
        with self.assertRaises(RuntimeError):
            client.list_items(page=2)
        self.assertEqual(len(client.cache), 0)
        self.assertEqual(client.list_items(page=2), "ok")
        self.assertEqual(client.list_items(page=2), "ok")
        self.assertEqual(state["calls"], 2)
        self.assertEqual((client.cache.hits, client.cache.misses), (1, 2))

    def test_caller_inputs_are_never_modified(self):
        params = {"tags": ["b", "a"], "limit": 10, "archived": False, "q": None}
        snapshot = copy.deepcopy(params)
        self.client.list_items(params)
        self.assertEqual(params, snapshot)
        self.assertEqual(list(params), list(snapshot))
        self.client.list_items(params, page=2)
        self.assertEqual(params, snapshot)
        self.client.list_items(params, limit=None, tags=["z"])
        self.assertEqual(params, snapshot)
        self.assertEqual(self.backend.sent[0], {"tags": ["b", "a"], "limit": 10, "archived": False, "page": 1})
        self.assertEqual(self.backend.sent[1]["page"], 2)
        tags = ["b", "a"]
        self.client.list_items(tags=tags, page=7)
        self.assertEqual(tags, ["b", "a"])

    def test_same_params_dict_sends_the_same_requests_every_time(self):
        params = {"tags": ["x"]}
        self.client.list_items(params, page=2)
        self.client.list_items(params, limit=5)
        self.client.list_items(params)
        self.client.list_items(params)
        self.assertEqual(self.backend.sent, [
            {"tags": ["x"], "page": 2, "limit": 50},
            {"tags": ["x"], "limit": 5, "page": 1},
            {"tags": ["x"], "limit": 50, "page": 1},
        ])
        self.assertEqual(params, {"tags": ["x"]})

    def test_backend_gets_independent_copies(self):
        def rude(endpoint, params):
            params["tags"].sort()
            params["tags"].append("injected")
            params.pop("limit")
            params["extra"] = 1
            return "result"

        tags = ["b", "a"]
        params = {"tags": tags}
        client = CatalogClient(rude)
        self.assertEqual(client.list_items(params), "result")
        self.assertEqual(tags, ["b", "a"])
        self.assertEqual(params, {"tags": ["b", "a"]})
        self.assertEqual(client.list_items(params), "result")
        self.assertEqual((client.cache.hits, client.cache.misses), (1, 1))
        self.assertEqual(len(client.cache), 1)

    def test_dict_like_params_and_keyword_precedence(self):
        proxy = types.MappingProxyType({"page": 2, "tags": ["b", "a"]})
        first = self.client.list_items(proxy)
        self.assertIs(self.client.list_items(page=2, tags=["a", "b"]), first)
        self.assertIs(self.client.list_items(OrderedDict([("tags", ["a", "b"]), ("page", 2)])), first)
        self.assertEqual(len(self.backend.calls), 1)
        self.assertEqual(proxy["tags"], ["b", "a"])
        self.client.list_items({"page": 2}, page=3)
        self.assertEqual(self.backend.sent[-1], {"page": 3, "limit": 50})

    def test_counters_count_one_lookup_per_call(self):
        sequence = [{"page": 1}, {"page": 2}, {"page": 1}, {"page": 3}, {"page": 2}, {"page": 1}]
        for params in sequence:
            self.client.list_items(params)
        self.assertEqual((self.client.cache.hits, self.client.cache.misses), (3, 3))
        self.assertEqual(len(self.client.cache), 3)
        self.assertEqual(len(self.backend.calls), 3)

    def test_cache_argument_and_endpoint(self):
        shared = Cache()
        backend = Backend()
        client = CatalogClient(backend, cache=shared)
        client.list_items()
        self.assertIs(client.cache, shared)
        self.assertEqual(len(shared), 1)
        self.assertEqual(backend.calls[0][0], "items")
        self.assertIsNot(CatalogClient(backend).cache, CatalogClient(backend).cache)


class CacheTests(unittest.TestCase):
    def test_counters_and_falsy_values(self):
        cache = Cache()
        self.assertEqual(cache.lookup("k"), (False, None))
        for key, value in (("none", None), ("zero", 0), ("empty", [])):
            cache.store(key, value)
            self.assertEqual(cache.lookup(key), (True, value))
        cache.store("none", "now set")
        self.assertEqual(cache.lookup("none"), (True, "now set"))
        self.assertEqual((cache.hits, cache.misses), (4, 1))
        self.assertEqual(len(cache), 3)


if __name__ == "__main__":
    unittest.main()
