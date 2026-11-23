"""A small in-memory cache that counts how often it is asked."""


class Cache:
    """Maps keys to values and keeps hit and miss counters.

    Any value can be stored, falsy ones (None, 0, "", []) included: a key that
    was stored is always a hit.
    """

    def __init__(self):
        self._entries = {}
        self.hits = 0
        self.misses = 0

    def lookup(self, key):
        """Return (True, value) when key is stored, else (False, None).

        Every call counts as exactly one hit or one miss.
        """
        if key in self._entries:
            self.hits += 1
            return True, self._entries[key]
        self.misses += 1
        return False, None

    def store(self, key, value):
        """Remember value under key, replacing an earlier value."""
        self._entries[key] = value

    def __len__(self):
        return len(self._entries)
