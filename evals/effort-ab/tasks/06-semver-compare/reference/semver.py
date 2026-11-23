"""Semantic Versioning 2.0.0 precedence helpers (https://semver.org).

Version grammar
---------------
    MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]

* MAJOR, MINOR, PATCH: non-negative decimal integers written with the ASCII
  digits 0-9. No leading zeros (the single digit "0" is fine). They can be
  arbitrarily large; do not assume they fit in 64 bits.
* PRERELEASE (optional, starts at the first "-" after the core): one or more
  dot-separated identifiers. An identifier is non-empty and made of
  [0-9A-Za-z-]. An identifier made only of digits is "numeric" and must not
  have leading zeros. An identifier containing a letter or a hyphen is
  "alphanumeric" ("0a", "01a" and "-" are alphanumeric, hence valid).
* BUILD (optional, starts at the first "+"): one or more dot-separated
  non-empty identifiers of [0-9A-Za-z-]. Leading zeros are allowed here.
* Anything else is invalid: a leading "v", leading or trailing whitespace
  (a trailing newline included), a missing component ("1.2"), an extra
  component ("1.2.3.4"), an empty prerelease or build ("1.2.3-", "1.2.3+"),
  an empty identifier ("1.2.3-a..b"), non-ASCII digits or letters, and any
  value that is not a str.

Precedence
----------
Versions are compared by the first difference found, left to right:

1. MAJOR, then MINOR, then PATCH, each compared numerically.
2. If those are equal, a version WITH a prerelease has LOWER precedence than
   the same version without one.
3. If both have a prerelease, compare its identifiers left to right:
   * numeric vs numeric: compared as integers;
   * alphanumeric vs alphanumeric: compared in ASCII order (so "-" < digits
     < uppercase < lowercase, e.g. "Beta" < "alpha");
   * a numeric identifier is always LOWER than an alphanumeric one;
   * if all shared identifiers are equal, the version with fewer
     identifiers is lower.
4. BUILD metadata is IGNORED: "1.0.0+a" and "1.0.0+b" have equal precedence.

Errors
------
Invalid input raises ValueError whose message contains repr() of the offending
value. compare() validates BOTH arguments before it compares anything (a is
checked first, then b), even when the answer would be obvious, for example
when a == b or when the majors differ. When both are invalid the error is
about a.
"""


_DIGITS = frozenset("0123456789")
_IDENTIFIER_CHARS = frozenset(
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"
)


def _invalid(value):
    return ValueError(f"invalid semantic version: {value!r}")


def _all_digits(text):
    return all(ch in _DIGITS for ch in text)


def _all_identifier_chars(text):
    return all(ch in _IDENTIFIER_CHARS for ch in text)


def _numeric_key(digits):
    # No leading zeros, so a longer digit string is a larger number and equal
    # lengths compare lexicographically. Works for integers of any size.
    return (len(digits), digits)


def _core_key(part, version):
    if not part or not _all_digits(part) or (len(part) > 1 and part[0] == "0"):
        raise _invalid(version)
    return _numeric_key(part)


def _prerelease_key(identifier, version):
    if not identifier or not _all_identifier_chars(identifier):
        raise _invalid(version)
    if _all_digits(identifier):
        if len(identifier) > 1 and identifier[0] == "0":
            raise _invalid(version)
        return (0,) + _numeric_key(identifier)
    return (1, identifier)


def _precedence_key(version):
    """Validate ``version`` and return a key ordered by semver precedence."""
    if not isinstance(version, str):
        raise _invalid(version)
    rest, has_build, build = version.partition("+")
    core, has_prerelease, prerelease = rest.partition("-")
    if has_build:
        for identifier in build.split("."):
            if not identifier or not _all_identifier_chars(identifier):
                raise _invalid(version)
    parts = core.split(".")
    if len(parts) != 3:
        raise _invalid(version)
    numbers = tuple(_core_key(part, version) for part in parts)
    if not has_prerelease:
        return numbers + ((1,),)
    identifiers = tuple(_prerelease_key(i, version) for i in prerelease.split("."))
    return numbers + ((0, identifiers),)


def compare(a, b):
    """Return -1, 0 or 1 when version a has lower, equal or higher precedence than b.

    The result is exactly one of the ints -1, 0, 1.
    Raises ValueError if a or b is not a valid version string.
    """
    key_a = _precedence_key(a)
    key_b = _precedence_key(b)
    return (key_a > key_b) - (key_a < key_b)


def max_version(versions):
    """Return the highest-precedence entry of ``versions``.

    ``versions`` is any iterable of version strings (consume it only once).
    The result is the ORIGINAL string, not a normalised one. When several
    entries share the highest precedence (they differ only in build metadata)
    return the first of them. Every entry is validated: an invalid entry
    raises ValueError wherever it sits, even when it is the only entry. An
    empty iterable raises ValueError.
    """
    best = None
    best_key = None
    for version in versions:
        key = _precedence_key(version)
        if best_key is None or key > best_key:
            best, best_key = version, key
    if best_key is None:
        raise ValueError("max_version() needs at least one version")
    return best
