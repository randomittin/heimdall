#!/usr/bin/env bash
# Hidden acceptance for 02: cwd = the agent's workdir.
set -u
PYTHONPATH="$PWD" python3 - <<'PY'
from textutil import slugify, title_case, word_count

assert title_case("hELLO wORLD") == "Hello World" and word_count(" a  b c ") == 3
cases = [
    ("Hello, World!", None, "hello-world"),
    ("  Crème Brûlée  ", None, "creme-brulee"),
    ("a--b__c", None, "a-b-c"),
    ("---", None, "n-a"),
    ("", None, "n-a"),
    ("日本語", None, "n-a"),
    ("Ünïcödé ñ", None, "unicode-n"),
    ("Hello World Again", 11, "hello-world"),
    ("Hello World Again", 14, "hello-world"),
    ("Hello World Again", 17, "hello-world-again"),
    ("abcdefghij", 4, "abcd"),
    ("ab cd", 3, "ab"),
    ("x", 1, "x"),
    ("one two three", 7, "one-two"),
    ("one two three", 8, "one-two"),
]
for text, max_length, expected in cases:
    got = slugify(text, max_length) if max_length is not None else slugify(text)
    assert got == expected, (text, max_length, got, expected)
    assert not got.endswith("-") and not got.startswith("-"), got
for kwargs in ({"max_length": 0}, {"max_length": -2}):
    raised = False
    try:
        slugify("abc", **kwargs)
    except ValueError:
        raised = True
    assert raised, kwargs
raised = False
try:
    slugify(5)
except TypeError:
    raised = True
assert raised
PY
