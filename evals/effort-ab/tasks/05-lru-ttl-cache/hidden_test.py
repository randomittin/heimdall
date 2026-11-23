"""Hidden acceptance test for 05-lru-ttl-cache (stdlib only).

Run with the agent's workdir on PYTHONPATH (accept.sh does this).  A hand-advanced
fake clock is used everywhere, so nothing depends on real time.
"""
import os
import random
import signal
import sys
import unittest


def _watchdog(signum, frame):
    sys.stderr.write("hidden test timed out (likely an infinite loop)\n")
    os._exit(124)


signal.signal(signal.SIGALRM, _watchdog)
signal.alarm(8)

from ttlcache import TTLCache  # noqa: E402


class FakeClock:
    def __init__(self, now=0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, amount):
        self.now += amount


class Model:
    """Obviously-correct list-based model: every expired entry is purged before each operation."""

    def __init__(self, capacity, ttl):
        self.capacity = capacity
        self.ttl = ttl
        self.items = []  # [key, value, stored_at], least recently used first

    def purge(self, now):
        self.items = [item for item in self.items if now - item[2] < self.ttl]

    def put(self, key, value, now):
        self.purge(now)
        for item in self.items:
            if item[0] == key:
                self.items.remove(item)
                break
        else:
            if len(self.items) >= self.capacity:
                self.items.pop(0)
        self.items.append([key, value, now])

    def get(self, key, default, now):
        self.purge(now)
        for item in self.items:
            if item[0] == key:
                self.items.remove(item)
                self.items.append(item)
                return item[1]
        return default

    def delete(self, key, now):
        self.purge(now)
        for item in self.items:
            if item[0] == key:
                self.items.remove(item)
                return True
        return False

    def keys(self, now):
        self.purge(now)
        return [item[0] for item in self.items]

    def contains(self, key, now):
        self.purge(now)
        return any(item[0] == key for item in self.items)


class TTLCacheHiddenTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def make(self, capacity=3, ttl=10):
        return TTLCache(capacity, ttl, clock=self.clock)

    def test_invalid_configuration_raises_value_error(self):
        for capacity in (0, -1, -10):
            with self.subTest(capacity=capacity):
                with self.assertRaises(ValueError):
                    TTLCache(capacity, 10, clock=self.clock)
        for ttl in (0, -1, -0.5):
            with self.subTest(ttl=ttl):
                with self.assertRaises(ValueError):
                    TTLCache(2, ttl, clock=self.clock)
        TTLCache(1, 0.001, clock=self.clock)

    def test_default_clock_is_usable(self):
        cache = TTLCache(2, 3600)
        cache.put("a", 1)
        self.assertEqual(cache.get("a"), 1)
        self.assertEqual(cache.keys(), ["a"])
        self.assertEqual(len(cache), 1)

    def test_expiry_boundary_is_inclusive(self):
        cache = self.make(ttl=10)
        cache.put("a", 1)
        self.clock.advance(9)
        self.assertIn("a", cache)
        self.assertEqual(cache.get("a"), 1)
        self.clock.advance(1)  # exactly ttl old
        self.assertNotIn("a", cache)
        self.assertIsNone(cache.get("a"))
        self.assertEqual(len(cache), 0)
        self.assertEqual(cache.keys(), [])

    def test_expiry_boundary_with_float_times(self):
        clock = FakeClock(0.25)
        cache = TTLCache(2, 0.5, clock=clock)
        cache.put("a", 1)
        clock.now = 0.74
        self.assertEqual(cache.get("a"), 1)
        clock.now = 0.75
        self.assertEqual(cache.get("a", "gone"), "gone")

    def test_get_does_not_extend_the_ttl(self):
        cache = self.make(ttl=10)
        cache.put("a", 1)
        self.clock.advance(6)
        self.assertEqual(cache.get("a"), 1)
        self.clock.advance(3.5)  # t = 9.5
        self.assertEqual(cache.get("a"), 1)
        self.clock.advance(0.5)  # t = 10: ten units after the put, four after the first get
        self.assertIsNone(cache.get("a"))
        self.assertNotIn("a", cache)

    def test_put_on_an_existing_key_replaces_the_value_and_resets_the_ttl(self):
        cache = self.make(ttl=10)
        cache.put("a", 1)
        self.clock.advance(6)
        cache.put("a", 2)
        self.clock.advance(6)  # t = 12: twelve after the first put, six after the second
        self.assertEqual(cache.get("a"), 2)
        self.assertEqual(len(cache), 1)
        self.clock.advance(4)  # t = 16: ten after the second put
        self.assertIsNone(cache.get("a"))

    def test_put_on_an_existing_key_resets_recency_without_evicting(self):
        cache = self.make(capacity=2)
        cache.put("a", 1)
        cache.put("b", 2)
        cache.put("a", 3)
        self.assertEqual(cache.keys(), ["b", "a"])
        self.assertEqual(len(cache), 2)
        self.assertEqual(cache.get("b"), 2)
        cache.put("c", 4)
        self.assertEqual(cache.keys(), ["b", "c"])
        self.assertNotIn("a", cache)

    def test_eviction_follows_recency_of_use(self):
        cache = self.make(capacity=3)
        for key in "abc":
            cache.put(key, key.upper())
        cache.get("a")
        cache.put("d", "D")
        self.assertEqual(cache.keys(), ["c", "a", "d"])
        self.assertNotIn("b", cache)
        cache.get("c")
        cache.put("e", "E")
        self.assertEqual(cache.keys(), ["d", "c", "e"])
        self.assertNotIn("a", cache)

    def test_expired_entries_are_purged_before_a_live_entry_is_evicted(self):
        cache = self.make(capacity=2, ttl=10)
        cache.put("b", "B")           # t = 0
        self.clock.advance(5)
        cache.put("a", "A")           # t = 5
        self.clock.advance(1)
        cache.get("b")                # t = 6: b is now the most recently used but the older entry
        self.assertEqual(cache.keys(), ["a", "b"])
        self.clock.advance(5)         # t = 11: b expired (11 >= 10), a live (6 < 10)
        cache.put("c", "C")
        self.assertEqual(cache.keys(), ["a", "c"])
        self.assertEqual(cache.get("a"), "A")
        self.assertEqual(len(cache), 2)

    def test_expired_entry_in_the_middle_is_purged_not_a_live_lru_entry(self):
        cache = self.make(capacity=3, ttl=10)
        cache.put("x", 1)             # t = 0
        self.clock.advance(1)
        cache.put("y", 2)             # t = 1
        self.clock.advance(1)
        cache.put("z", 3)             # t = 2
        self.clock.advance(1)
        cache.get("x")                # t = 3: order y, z, x
        self.clock.advance(7.5)       # t = 10.5: x expired; y (9.5) and z (8.5) live
        cache.put("w", 4)
        self.assertEqual(cache.keys(), ["y", "z", "w"])
        self.assertEqual(cache.get("y"), 2)

    def test_an_expired_least_recently_used_entry_is_reused_first(self):
        cache = self.make(capacity=2, ttl=10)
        cache.put("a", 1)             # t = 0
        self.clock.advance(5)
        cache.put("b", 2)             # t = 5
        self.clock.advance(7)         # t = 12: a expired, b live
        cache.put("c", 3)
        self.assertEqual(cache.keys(), ["b", "c"])

    def test_all_expired_entries_are_purged_before_inserting(self):
        cache = self.make(capacity=2, ttl=10)
        cache.put("a", 1)
        cache.put("b", 2)
        self.clock.advance(10)
        cache.put("c", 3)
        cache.put("d", 4)
        self.assertEqual(cache.keys(), ["c", "d"])
        self.assertEqual(len(cache), 2)

    def test_len_contains_and_keys_never_include_expired_entries(self):
        cache = self.make(capacity=5, ttl=10)
        cache.put("a", 1)             # t = 0
        self.clock.advance(4)
        cache.put("b", 2)             # t = 4
        self.clock.advance(4)
        cache.put("c", 3)             # t = 8
        self.clock.advance(2)         # t = 10: a expired
        self.assertEqual(len(cache), 2)
        self.assertEqual(cache.keys(), ["b", "c"])
        self.assertNotIn("a", cache)
        self.clock.advance(4)         # t = 14: b expired
        self.assertEqual(len(cache), 1)
        self.assertEqual(cache.keys(), ["c"])
        self.clock.advance(4)         # t = 18: c expired
        self.assertEqual(len(cache), 0)
        self.assertEqual(cache.keys(), [])

    def test_contains_does_not_change_recency(self):
        cache = self.make(capacity=2)
        cache.put("a", 1)
        cache.put("b", 2)
        self.assertIn("a", cache)
        self.assertNotIn("zzz", cache)
        self.assertEqual(cache.keys(), ["a", "b"])
        cache.put("c", 3)
        self.assertEqual(cache.keys(), ["b", "c"])

    def test_keys_is_a_list_from_least_to_most_recently_used(self):
        cache = self.make()
        for key in "abc":
            cache.put(key, 0)
        cache.get("b")
        keys = cache.keys()
        self.assertIs(type(keys), list)
        self.assertEqual(keys, ["a", "c", "b"])
        keys.append("intruder")
        self.assertEqual(cache.keys(), ["a", "c", "b"])

    def test_a_get_miss_changes_nothing(self):
        cache = self.make(capacity=2)
        cache.put("a", 1)
        cache.put("b", 2)
        self.assertIsNone(cache.get("nope"))
        self.assertEqual(cache.keys(), ["a", "b"])
        cache.put("c", 3)
        self.assertEqual(cache.keys(), ["b", "c"])

    def test_delete(self):
        cache = self.make(capacity=2, ttl=10)
        cache.put("a", 1)
        cache.put("b", 2)
        self.assertIs(cache.delete("a"), True)
        self.assertIs(cache.delete("a"), False)
        self.assertIs(cache.delete("never"), False)
        cache.put("c", 3)  # the freed slot is reused: b is not evicted
        self.assertEqual(cache.keys(), ["b", "c"])
        self.clock.advance(10)
        self.assertIs(cache.delete("b"), False)  # expired counts as absent
        self.assertEqual(len(cache), 0)

    def test_none_and_other_falsy_values_are_stored(self):
        cache = self.make(capacity=5)
        for key, value in (("none", None), ("zero", 0), ("empty", ""), ("false", False), ("list", [])):
            cache.put(key, value)
        for key, value in (("none", None), ("zero", 0), ("empty", ""), ("false", False), ("list", [])):
            self.assertIn(key, cache)
            self.assertEqual(cache.get(key, "default"), value)
            self.assertIs(type(cache.get(key, "default")), type(value))

    def test_non_string_keys(self):
        cache = self.make(capacity=3)
        cache.put(1, "one")
        cache.put((1, 2), "pair")
        cache.put(None, "nothing")
        self.assertEqual(cache.get(1), "one")
        self.assertEqual(cache.get((1, 2)), "pair")
        self.assertEqual(cache.get(None), "nothing")
        self.assertEqual(cache.keys(), [1, (1, 2), None])

    def test_capacity_one(self):
        cache = self.make(capacity=1)
        cache.put("a", 1)
        cache.put("b", 2)
        self.assertEqual(cache.keys(), ["b"])
        self.assertIsNone(cache.get("a"))
        cache.put("b", 3)
        self.assertEqual(cache.get("b"), 3)
        self.assertEqual(len(cache), 1)

    def test_putting_an_expired_key_again_stores_a_fresh_entry(self):
        cache = self.make(capacity=2, ttl=10)
        cache.put("a", 1)
        cache.put("b", 2)
        self.clock.advance(10)
        cache.put("a", 3)
        self.assertEqual(cache.keys(), ["a"])
        self.assertEqual(cache.get("a"), 3)
        self.clock.advance(9)
        self.assertEqual(cache.get("a"), 3)
        self.clock.advance(1)
        self.assertIsNone(cache.get("a"))

    def test_random_operations_match_the_reference_model(self):
        rng = random.Random(20261123)
        for capacity, ttl in ((1, 3), (3, 5), (4, 5), (6, 2)):
            clock = FakeClock()
            cache = TTLCache(capacity, ttl, clock=clock)
            model = Model(capacity, ttl)
            for step in range(1500):
                clock.advance(rng.choice([0, 0, 0, 1, 1, 2, 3, 5]))
                now = clock.now
                key = rng.choice("abcdefgh")
                op = rng.choice(["put", "put", "get", "get", "delete", "contains", "keys", "len"])
                where = f"cap={capacity} ttl={ttl} step={step} op={op} key={key} now={now}"
                if op == "put":
                    value = rng.randint(0, 99)
                    cache.put(key, value)
                    model.put(key, value, now)
                elif op == "get":
                    self.assertEqual(cache.get(key, "MISS"), model.get(key, "MISS", now), where)
                elif op == "delete":
                    self.assertIs(cache.delete(key), model.delete(key, now), where)
                elif op == "contains":
                    self.assertIs(key in cache, model.contains(key, now), where)
                elif op == "keys":
                    self.assertEqual(cache.keys(), model.keys(now), where)
                else:
                    self.assertEqual(len(cache), len(model.keys(now)), where)
                self.assertEqual(cache.keys(), model.keys(now), where)


if __name__ == "__main__":
    unittest.main()
