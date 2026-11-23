import unittest

from catalog.cache import Cache


class CacheTests(unittest.TestCase):
    def test_miss_then_hit_updates_counters(self):
        cache = Cache()
        self.assertEqual(cache.lookup("k"), (False, None))
        cache.store("k", [1, 2])
        self.assertEqual(cache.lookup("k"), (True, [1, 2]))
        self.assertEqual((cache.hits, cache.misses), (1, 1))
        self.assertEqual(len(cache), 1)

    def test_falsy_values_are_still_hits(self):
        cache = Cache()
        for key, value in (("none", None), ("zero", 0), ("empty", [])):
            cache.store(key, value)
            self.assertEqual(cache.lookup(key), (True, value))


if __name__ == "__main__":
    unittest.main()
