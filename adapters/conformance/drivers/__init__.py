"""Per-adapter drivers: the one adapter-specific part of the conformance suite.

A driver is `drivers/<name>.py` exposing `variants(fixture) -> [(variant_name, task), ...]`. It turns the
suite's abstract scenario (the fixture repository, its base and head commits and the canonical diff
between them) into the concrete `task` objects that make THIS adapter claim exactly that change,
offline and without credentials. A driver carries no expectation and no check: every expected value
comes from the fixture, so a driver cannot loosen the suite.
"""
