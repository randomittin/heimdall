"""Small text helpers."""
import re
import unicodedata


def title_case(text):
    """Capitalise the first letter of every whitespace-separated word, lowercase the rest."""
    return " ".join(word[:1].upper() + word[1:].lower() for word in text.split())


def word_count(text):
    """Number of whitespace-separated words."""
    return len(text.split())


def slugify(text, max_length=None):
    if not isinstance(text, str):
        raise TypeError("text must be a str")
    if max_length is not None and max_length < 1:
        raise ValueError("max_length must be >= 1")
    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")
    if max_length is not None and len(slug) > max_length:
        cut = slug[:max_length]
        if slug[max_length] != "-" and "-" in cut:
            cut = cut[:cut.rindex("-")]
        slug = cut.strip("-")
    return slug or "n-a"
