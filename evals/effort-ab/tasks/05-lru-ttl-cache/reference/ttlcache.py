"""A bounded cache whose entries also expire.

    cache = TTLCache(capacity=2, ttl=60)
    cache.put("a", 1)
    cache.get("a")          # -> 1

Rules
-----
* ``capacity`` (an int >= 1) is the maximum number of live entries and ``ttl``
  (a number > 0) is how long an entry lives, both in the units of ``clock``, a
  zero-argument callable that returns the current time as a number (default
  ``time.monotonic``; tests inject a fake one).  ``capacity < 1`` or
  ``ttl <= 0`` raises ``ValueError``.
* An entry stored at time ``t0`` is expired once ``clock() - t0 >= ttl``: an
  entry that is exactly ``ttl`` old is already expired.
* ``put(key, value)`` stamps the entry with the current time.
    - Key already present and live: replace the value, restart its TTL and make
      it the most recently used.
    - New key (an expired key counts as absent): first purge every expired
      entry; then, if ``capacity`` live entries remain, evict the least recently
      used one; then store the new entry as the most recently used.  An expired
      slot is therefore reused before any live entry is evicted.
* ``get(key, default=None)`` returns the stored value (``None`` is a valid
  value) and makes the key the most recently used.  It does NOT extend the TTL.
  A missing or expired key returns ``default`` and changes nothing else.
* ``delete(key)`` removes the key.  It returns True if a live entry was
  removed and False if the key was absent or already expired.
* ``len(cache)`` counts live entries only and ``key in cache`` is True only for
  a live key; ``in`` does NOT change recency.
* ``keys()`` returns a new list of the live keys, least recently used first and
  most recently used last.
* Recency changes only through ``put`` and through a ``get`` that finds a live
  key.
"""
import time
from collections import OrderedDict


class TTLCache:
    """LRU cache with a per-entry time to live (see the module docstring)."""

    def __init__(self, capacity, ttl, clock=time.monotonic):
        """Validate the arguments and create an empty cache."""
        if capacity < 1:
            raise ValueError("capacity must be >= 1")
        if ttl <= 0:
            raise ValueError("ttl must be > 0")
        self._capacity = capacity
        self._ttl = ttl
        self._clock = clock
        self._entries = OrderedDict()  # key -> (value, stored_at), least recently used first

    def _is_expired(self, stored_at, now):
        return now - stored_at >= self._ttl

    def _purge_expired(self, now):
        expired = [key for key, (_, stored_at) in self._entries.items() if self._is_expired(stored_at, now)]
        for key in expired:
            del self._entries[key]

    def put(self, key, value):
        """Store ``value`` under ``key`` (purge expired, evict LRU if full)."""
        now = self._clock()
        self._purge_expired(now)
        if key in self._entries:
            del self._entries[key]
        elif len(self._entries) >= self._capacity:
            self._entries.popitem(last=False)
        self._entries[key] = (value, now)

    def get(self, key, default=None):
        """Return the live value for ``key`` and mark it most recently used."""
        entry = self._entries.get(key)
        if entry is None:
            return default
        value, stored_at = entry
        if self._is_expired(stored_at, self._clock()):
            del self._entries[key]
            return default
        self._entries.move_to_end(key)
        return value

    def delete(self, key):
        """Remove ``key``; True if a live entry was removed, else False."""
        entry = self._entries.pop(key, None)
        if entry is None:
            return False
        return not self._is_expired(entry[1], self._clock())

    def keys(self):
        """Return the live keys as a list, least recently used first."""
        self._purge_expired(self._clock())
        return list(self._entries)

    def __len__(self):
        """Return the number of live entries."""
        self._purge_expired(self._clock())
        return len(self._entries)

    def __contains__(self, key):
        """Return True if ``key`` is live, without changing recency."""
        entry = self._entries.get(key)
        return entry is not None and not self._is_expired(entry[1], self._clock())
