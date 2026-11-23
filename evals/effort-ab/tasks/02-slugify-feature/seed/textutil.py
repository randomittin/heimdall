"""Small text helpers shared by the CMS import scripts."""


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
