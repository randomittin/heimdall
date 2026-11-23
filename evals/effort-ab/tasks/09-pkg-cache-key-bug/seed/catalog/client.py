"""Catalog API client with a read-through cache."""
from .cache import Cache
from .keys import build_key

ENDPOINT = "items"
DEFAULT_LIMIT = 50
DEFAULT_PAGE = 1


class CatalogClient:
    """Reads catalog items through `fetch_fn(endpoint, params)` and remembers results.

    `fetch_fn` performs the real request and returns its result (any object).
    The cache used is available as `client.cache`.
    """

    def __init__(self, fetch_fn, cache=None):
        self._fetch = fetch_fn
        self.cache = cache if cache is not None else Cache()

    def list_items(self, params=None, **extra):
        """Return the items for the query given by `params` and keyword arguments.

        `params` is a Mapping or None; keyword arguments win over `params`.

        * An entry whose value is None counts as not given.
        * A missing limit or page defaults to DEFAULT_LIMIT (50) or
          DEFAULT_PAGE (1). The defaults belong to the query: list_items()
          and list_items(page=1, limit=50) are the same request.
        * The cache key is build_key(ENDPOINT, query) of the completed query,
          and each call performs exactly one cache lookup. On a hit the cached
          object is returned and fetch_fn is not called. On a miss
          fetch_fn(ENDPOINT, query) is called once, its return value is
          stored and returned; if fetch_fn raises, the exception propagates
          and nothing is stored.
        * fetch_fn receives a dict equal to the completed query, with values
          as the caller gave them (a list keeps the caller's order). That dict
          and the lists inside it are independent of the caller's objects, so
          nothing fetch_fn does to its argument can change the caller's data.
        * The caller's params mapping and the values inside it are never
          modified.
        """
        if params is None:
            params = {}
        params.update(extra)
        for name in [name for name, value in params.items() if value is None]:
            del params[name]
        params.setdefault("limit", DEFAULT_LIMIT)
        params.setdefault("page", DEFAULT_PAGE)
        key = build_key(ENDPOINT, params)
        hit, value = self.cache.lookup(key)
        if hit:
            return value
        value = self._fetch(ENDPOINT, params)
        self.cache.store(key, value)
        return value
