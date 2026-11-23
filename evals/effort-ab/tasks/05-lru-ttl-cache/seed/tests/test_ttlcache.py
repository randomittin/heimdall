import unittest

from ttlcache import TTLCache


class FakeClock:
    """A clock the tests advance by hand."""

    def __init__(self, now=0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, amount):
        self.now += amount


class BasicTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def make(self, capacity=3, ttl=10):
        return TTLCache(capacity, ttl, clock=self.clock)

    def test_put_and_get(self):
        cache = self.make()
        cache.put("a", 1)
        self.assertEqual(cache.get("a"), 1)

    def test_missing_key_returns_the_default(self):
        cache = self.make()
        self.assertIsNone(cache.get("nope"))
        self.assertEqual(cache.get("nope", "fallback"), "fallback")

    def test_len_and_contains(self):
        cache = self.make()
        cache.put("a", 1)
        cache.put("b", 2)
        self.assertEqual(len(cache), 2)
        self.assertIn("a", cache)
        self.assertNotIn("z", cache)

    def test_least_recently_used_entry_is_evicted_when_full(self):
        cache = self.make(capacity=2)
        cache.put("a", 1)
        cache.put("b", 2)
        cache.put("c", 3)
        self.assertEqual(cache.keys(), ["b", "c"])

    def test_get_makes_a_key_most_recently_used(self):
        cache = self.make(capacity=2)
        cache.put("a", 1)
        cache.put("b", 2)
        cache.get("a")
        cache.put("c", 3)
        self.assertEqual(cache.keys(), ["a", "c"])

    def test_entry_expires_after_the_ttl(self):
        cache = self.make(ttl=10)
        cache.put("a", 1)
        self.clock.advance(11)
        self.assertIsNone(cache.get("a"))
        self.assertEqual(len(cache), 0)

    def test_delete_reports_whether_the_key_was_live(self):
        cache = self.make()
        cache.put("a", 1)
        self.assertTrue(cache.delete("a"))
        self.assertFalse(cache.delete("a"))

    def test_rejects_bad_configuration(self):
        with self.assertRaises(ValueError):
            TTLCache(0, 10)
        with self.assertRaises(ValueError):
            TTLCache(2, 0)


if __name__ == "__main__":
    unittest.main()
