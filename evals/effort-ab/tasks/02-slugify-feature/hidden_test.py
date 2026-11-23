"""Hidden acceptance test for 02-slugify-feature (stdlib only).

Run with the agent's workdir on PYTHONPATH (accept.sh does this).
"""
import os
import random
import re
import signal
import sys
import unicodedata
import unittest


def _watchdog(signum, frame):
    sys.stderr.write("hidden test timed out (likely an infinite loop)\n")
    os._exit(124)


signal.signal(signal.SIGALRM, _watchdog)
signal.alarm(8)

import textutil  # noqa: E402

slugify = textutil.slugify


def oracle(text, max_length=None):
    """Independent restatement of the spec (greedy whole-word formulation)."""
    ascii_only = "".join(ch.lower() for ch in unicodedata.normalize("NFKD", text) if ord(ch) < 128)
    words = [word for word in re.split(r"[^a-z0-9]+", ascii_only) if word]
    if not words:
        return "n-a"
    if max_length is None:
        return "-".join(words)
    kept, used = [], 0
    for word in words:
        needed = len(word) if not kept else len(word) + 1
        if used + needed > max_length:
            break
        kept.append(word)
        used += needed
    if not kept:
        return words[0][:max_length]
    return "-".join(kept)


BASIC = [
    ("Hello, World!", "hello-world"),
    ("  Multiple   spaces\tand\nnewlines  ", "multiple-spaces-and-newlines"),
    ("snake_case__and--dashes", "snake-case-and-dashes"),
    ("--leading and trailing--", "leading-and-trailing"),
    ("MiXeD CaSe 123 abc", "mixed-case-123-abc"),
    ("x - y", "x-y"),
    ("v1.2.3-beta+build.5", "v1-2-3-beta-build-5"),
    ("a", "a"),
    ("A", "a"),
    ("9", "9"),
]

UNICODE = [
    ("Crème Brûlée à la façon", "creme-brulee-a-la-facon"),
    ("naïve café", "naive-cafe"),
    ("Café déjà vu", "cafe-deja-vu"),
    ("ﬁnance ﬂow", "finance-flow"),  # ligatures need NFKD (compatibility) folding
    ("Ｈｅｌｌｏ Ｗｏｒｌｄ", "hello-world"),  # full-width forms
    ("①②③ items", "123-items"),  # circled digits fold to digits under NFKD
    ("Straße", "strae"),  # no ASCII decomposition: deleted, never transliterated
    ("a日b", "ab"),  # deleted characters do not act as separators
    ("ab日cd", "abcd"),
    ("Ünïcödé ✓ ok", "unicode-ok"),
]

FALLBACK_INPUTS = ["", "   ", "!!!", "---", "_", "日本語", "✓ ✗", " - _ . "]

TRUNCATION = [
    ("hello big world", None, "hello-big-world"),
    ("hello big world", 100, "hello-big-world"),
    ("hello big world", 16, "hello-big-world"),
    ("hello big world", 15, "hello-big-world"),
    ("hello big world", 14, "hello-big"),
    ("hello big world", 13, "hello-big"),
    ("hello big world", 12, "hello-big"),
    ("hello big world", 11, "hello-big"),
    ("hello big world", 10, "hello-big"),
    ("hello big world", 9, "hello-big"),
    ("hello big world", 8, "hello"),
    ("hello big world", 7, "hello"),
    ("hello big world", 6, "hello"),
    ("hello big world", 5, "hello"),
    ("hello big world", 4, "hell"),
    ("hello big world", 3, "hel"),
    ("hello big world", 2, "he"),
    ("hello big world", 1, "h"),
    ("supercalifragilistic", 5, "super"),
    ("supercalifragilistic", 20, "supercalifragilistic"),
    ("supercalifragilistic expialidocious", 5, "super"),
    ("supercalifragilistic expialidocious", 20, "supercalifragilistic"),
    ("supercalifragilistic expialidocious", 21, "supercalifragilistic"),
    ("supercalifragilistic expialidocious", 22, "supercalifragilistic"),
    ("a b c d", 7, "a-b-c-d"),
    ("a b c d", 6, "a-b-c"),
    ("a b c d", 5, "a-b-c"),
    ("a b c d", 4, "a-b"),
    ("a b c d", 3, "a-b"),
    ("a b c d", 2, "a"),
    ("a b c d", 1, "a"),
    ("ab cd", 4, "ab"),
    ("ab cd", 3, "ab"),
    ("ab cd", 2, "ab"),
    ("ab cd", 1, "a"),
    ("  Big -- Trailing Punctuation!!!  ", 8, "big"),
    ("  Big -- Trailing Punctuation!!!  ", 9, "big"),
    ("  Big -- Trailing Punctuation!!!  ", 11, "big"),
    ("  Big -- Trailing Punctuation!!!  ", 12, "big-trailing"),
    ("  Big -- Trailing Punctuation!!!  ", 13, "big-trailing"),
    ("Crème Brûlée", 5, "creme"),
    ("Crème Brûlée", 6, "creme"),
    ("Crème Brûlée", 7, "creme"),
]


class SlugifyHiddenTests(unittest.TestCase):
    def test_basic_cases(self):
        for text, want in BASIC:
            with self.subTest(text=text):
                self.assertEqual(slugify(text), want)

    def test_unicode_cases(self):
        for text, want in UNICODE:
            with self.subTest(text=text):
                self.assertEqual(slugify(text), want)

    def test_empty_result_is_n_a(self):
        for text in FALLBACK_INPUTS:
            with self.subTest(text=text):
                self.assertEqual(slugify(text), "n-a")

    def test_n_a_fallback_ignores_max_length(self):
        for max_length in (1, 2, 3, 50):
            for text in ("", "!!!", "日本語"):
                with self.subTest(text=text, max_length=max_length):
                    self.assertEqual(slugify(text, max_length), "n-a")

    def test_truncation_cases(self):
        for text, max_length, want in TRUNCATION:
            with self.subTest(text=text, max_length=max_length):
                self.assertEqual(slugify(text, max_length), want)

    def test_max_length_accepted_as_keyword_and_none(self):
        self.assertEqual(slugify("hello big world", max_length=9), "hello-big")
        self.assertEqual(slugify("hello big world", max_length=None), "hello-big-world")
        self.assertEqual(slugify("hello big world", None), "hello-big-world")

    def test_max_length_below_one_raises_value_error(self):
        for max_length in (0, -1, -100):
            for text in ("abc", "hello big world", "", "!!!", "日本語"):
                with self.subTest(text=text, max_length=max_length):
                    with self.assertRaises(ValueError):
                        slugify(text, max_length)

    def test_non_str_text_raises_type_error(self):
        for bad in (None, 123, 1.5, b"bytes", ["a"], ("a",), {"a": 1}, object()):
            with self.subTest(bad=bad):
                with self.assertRaises(TypeError):
                    slugify(bad)
                with self.assertRaises(TypeError):
                    slugify(bad, 5)

    def test_output_invariants_and_oracle_on_random_inputs(self):
        rng = random.Random(20261123)
        alphabet = list("abcXYZ019 -_.,!?\t\n") + [
            "é", "ü", "日", "ß", "ﬁ", "①", "́", "Ｈ", "✓",
        ]
        for _ in range(4000):
            text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 24)))
            max_length = rng.choice([None, None] + list(range(1, 31)))
            got = slugify(text, max_length)
            with self.subTest(text=text, max_length=max_length):
                self.assertEqual(got, oracle(text, max_length))
                self.assertRegex(got, r"^[a-z0-9]+(-[a-z0-9]+)*$")
                if got != "n-a" and max_length is not None:
                    self.assertLessEqual(len(got), max_length)
                self.assertEqual(slugify(got), got)

    def test_existing_helpers_still_work(self):
        self.assertEqual(textutil.word_count("  the quick  brown\tfox\n"), 4)
        self.assertEqual(textutil.word_count(""), 0)
        self.assertEqual(textutil.word_count("   \t\n"), 0)
        self.assertEqual(textutil.title_case("  hELLO   wORLD "), "Hello World")
        self.assertEqual(textutil.title_case(""), "")
        self.assertEqual(textutil.title_case("one"), "One")


if __name__ == "__main__":
    unittest.main()
