"""Cache keys for catalog requests.

build_key(endpoint, params) maps a request (an endpoint name plus query
parameters) to a str that is used as the cache key. Equal keys must mean "same
request", so:

* The key depends on the endpoint and on the parameters only. The order in
  which parameters were inserted into the dict never matters.
* A parameter whose value is None counts as "not given" and is left out of the
  key. Every other value is part of the key, falsy ones included: 0, False,
  "" and [] are real values and differ from "not given".
* Values keep their type: 1, "1" and True are three different values, and so
  are 0, False and "0".
* list, tuple, set and frozenset values are unordered collections: ["a", "b"],
  ("b", "a") and {"a", "b"} give the same key. Their items may be of mixed
  types (strings and ints together). Duplicates are kept, so ["a", "a"]
  differs from ["a"], and a collection is never confused with a scalar:
  ["a"] differs from "a".
* Different requests never collide, whatever characters names and values
  contain: {"a": "1&b=2"} differs from {"a": "1", "b": "2"}.
* build_key never modifies params or the values inside it.
"""


def build_key(endpoint, params):
    """Return the cache key (a str) for `endpoint` called with `params`."""
    parts = []
    for name, value in params.items():
        if not value:
            continue
        parts.append(f"{name!r}={_encode(value)}")
    return endpoint + "?" + "&".join(parts)


def _encode(value):
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(repr(item) for item in value) + "]"
    return repr(value)
