"""Small text helpers shared by the CMS import scripts."""

import re
import unicodedata

_NON_SLUG_RUN = re.compile(r"[^a-z0-9]+")


def word_count(text):
    """Return the number of whitespace-separated words in ``text``.

    Any run of whitespace separates words; leading and trailing whitespace is
    ignored, so an empty or all-whitespace string has zero words.

    >>> word_count("  the quick  brown\tfox\n")
    4
    """
    return len(text.split())


def title_case(text):
    """Capitalise each word: first letter upper-case, the rest lower-case.

    Words are separated by runs of whitespace, which are collapsed to a single
    space; leading and trailing whitespace is dropped.

    >>> title_case("  hELLO   wORLD ")
    'Hello World'
    """
    return " ".join(word[:1].upper() + word[1:].lower() for word in text.split())


def slugify(text, max_length=None):
    """Turn ``text`` into a URL slug made of ``[a-z0-9]`` words joined by ``-``.

    >>> slugify("Crème Brûlée")
    'creme-brulee'
    >>> slugify("hello big world", 12)
    'hello-big'
    """
    if not isinstance(text, str):
        raise TypeError("text must be a str")
    if max_length is not None and max_length < 1:
        raise ValueError("max_length must be >= 1")

    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    slug = _NON_SLUG_RUN.sub("-", ascii_text.lower()).strip("-")
    if not slug:
        return "n-a"
    if max_length is None or len(slug) <= max_length:
        return slug

    cut = slug[:max_length]
    cut_is_inside_a_word = slug[max_length] != "-" and cut[-1] != "-"
    if cut_is_inside_a_word:
        boundary = cut.rfind("-")
        if boundary > 0:
            cut = cut[:boundary]
    return cut.rstrip("-")
