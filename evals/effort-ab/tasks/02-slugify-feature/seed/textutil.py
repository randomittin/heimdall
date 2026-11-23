"""Small text helpers."""


def title_case(text):
    """Capitalise the first letter of every whitespace-separated word, lowercase the rest."""
    return " ".join(word[:1].upper() + word[1:].lower() for word in text.split())


def word_count(text):
    """Number of whitespace-separated words."""
    return len(text.split())
