"""Hidden acceptance test for 10-csv-parser. Imports csvparse from the cwd.

This test may import the stdlib csv module (the code under test may not): it is
the oracle of a differential test on well-formed and on malformed input.
"""
import csv
import io
import os
import random
import sys
import unittest

sys.path.insert(0, os.getcwd())

from csvparse import parse_csv  # noqa: E402

BOM = "﻿"


def stdlib_rows(text, delimiter=","):
    """csv.reader semantics the spec is defined against (BOM handled by the caller)."""
    if text.startswith(BOM):
        text = text[1:]
    return list(csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, strict=True))


BATTERY = [
    ("", ","),
    ("\n", ","),
    ("\r\n", ","),
    ("\r", ","),
    ("\n\n", ","),
    ("\r\r", ","),
    ("\n\r", ","),
    ("a", ","),
    ("a\n", ","),
    ("a\r\n", ","),
    ("a\r", ","),
    ("a,b,c", ","),
    ("a,b,c\n1,2,3\n", ","),
    ("a,b,c\r\n1,2,3\r\n", ","),
    ("a,b\r1,2\r", ","),
    ("a,b\n1,2\r\n3,4\r5,6", ","),
    ("a,,c", ","),
    (",,", ","),
    (",", ","),
    ("a,", ","),
    (",a", ","),
    ('""', ","),
    ('"",""', ","),
    ('"",,""', ","),
    ('a,"",b', ","),
    ('"a"', ","),
    ('"a","b"', ","),
    ('"a"\n"b"\n', ","),
    ('"a,b",c', ","),
    ('"a""b",c', ","),
    ('""""', ","),
    ('"a""",b', ","),
    ('"line1\nline2",x', ","),
    ('"line1\r\nline2",x\r\ny,z', ","),
    ('"cr\rinside",x\ry', ","),
    ('a,"b\n\nc",d\n', ","),
    ('"\n"', ","),
    ('"\r\n"', ","),
    ("a\n\nb", ","),
    ("a\n\n\nb\n\n", ","),
    ("\n\na", ","),
    ('a"b,c"d', ","),
    (' "a",b', ","),
    ('a, "b"', ","),
    ('x "y" z,w', ","),
    ("  \n", ","),
    (" a , b ", ","),
    ("a;b;c", ";"),
    ('"a;b";c', ";"),
    ("a,b;c", ";"),
    ("a\tb\tc\n1\t2\t3", "\t"),
    ('"a\tb"\tc', "\t"),
    ('a|b|"c|d"', "|"),
    ('a b "c d"', " "),
    ("1a2a3", "a"),
    ("é,ü,日本", ","),
    ("a b,c\x0bd\x0ce\x85f g\n", ","),
    ('a\\b,c\\"d', ","),
    ("x" * 10000 + ",y", ","),
    (",".join(str(i) for i in range(500)) + "\n", ","),
    ("\n".join("a,b,c" for _ in range(300)), ","),
    (BOM + "a,b\n1,2\n", ","),
    (BOM + '"a",b', ","),
    (BOM, ","),
    (BOM + "\n", ","),
    (BOM + BOM + "a", ","),
    ("a\n" + BOM + "b", ","),
    ("a" + BOM + "b,c", ","),
]

JUNK_AFTER_CLOSING_QUOTE = [
    ('"a"b', ",", 1),
    ('a,"b"c,d', ",", 1),
    ('a,b\n"c"x\n', ",", 2),
    ('x\n"multi\nline"y', ",", 3),
    ("a\r\nb\r\n\"c\" d", ",", 3),
    ('a\rb\r"c"d', ",", 3),
    ('"x\r\ny"z', ",", 2),
    ('"a"\n"b" ', ",", 2),
    ('""x', ",", 1),
    ('"a""b"c', ",", 1),
    ('"a"\t', ",", 1),
    ('a;"b"c', ";", 1),
    ('"a"\n\n\n"b"\n"c"d', ",", 5),
    ('"p\n\nq"\n"r"s', ",", 4),
]

UNTERMINATED = ['"', '"abc', 'a,"b', 'a\n"b\nc', '"a""', '"a\r\n', '"""', 'x,y\n"unfinished,field\n']

ODD_DELIMITERS = (";", "\t", "|", " ", ":", "a", "é", "\x1f", "'", "\\")


def odd_delimiter_text(delimiter):
    return f"1{delimiter}2{delimiter}{delimiter}3\n4{delimiter}5\n"


def build_fuzz_cases():
    """Random inputs with the oracle's verdict: rows, 'unterminated' or the junk line."""
    rng = random.Random(20260611)
    cases = []
    for delimiter in (",", ";", "\t", "|", " "):
        alphabet = ["a", "b", "x", " ", delimiter, '"', '"', '"', "\n", "\r", "\r\n"]
        for _ in range(1200):
            text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 14)))
            reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, strict=True)
            try:
                cases.append((text, delimiter, "rows", list(reader)))
            except csv.Error as stdlib_error:
                if "end of data" in str(stdlib_error):
                    cases.append((text, delimiter, "unterminated", None))
                else:
                    cases.append((text, delimiter, "junk", reader.line_num))
    return cases


# Every oracle answer is computed up front. The csv module is then dropped from
# sys.modules so that tearDownModule can prove the code under test never
# imported it (not even dynamically, while parsing).
BATTERY_EXPECTED = [(text, delimiter, stdlib_rows(text, delimiter)) for text, delimiter in BATTERY]
FUZZ_CASES = build_fuzz_cases()
ODD_DELIMITER_EXPECTED = [
    (d, odd_delimiter_text(d), stdlib_rows(odd_delimiter_text(d), d)) for d in ODD_DELIMITERS
]
sys.modules.pop("csv", None)


def tearDownModule():
    if "csv" in sys.modules:
        raise AssertionError("the code under test imported the csv module while parsing")


class ShapeTests(unittest.TestCase):
    def test_result_is_a_list_of_lists_of_str(self):
        rows = parse_csv('a,"b"\nc,d\n')
        self.assertIs(type(rows), list)
        for row in rows:
            self.assertIs(type(row), list)
            for field in row:
                self.assertIs(type(field), str)

    def test_calls_share_no_state(self):
        first = parse_csv("a")
        first[0].append("z")
        first.append(["y"])
        self.assertEqual(parse_csv("a"), [["a"]])

    def test_spec_examples(self):
        self.assertEqual(parse_csv(""), [])
        self.assertEqual(parse_csv("a\n"), [["a"]])
        self.assertEqual(parse_csv("a"), [["a"]])
        self.assertEqual(parse_csv("a\n\nb"), [["a"], [], ["b"]])
        self.assertEqual(parse_csv("\n"), [[]])
        self.assertEqual(parse_csv("a\n\n"), [["a"], []])
        self.assertEqual(parse_csv("  \n"), [["  "]])
        self.assertEqual(parse_csv('""\n'), [[""]])
        self.assertEqual(parse_csv("a,,b"), [["a", "", "b"]])
        self.assertEqual(parse_csv("a,"), [["a", ""]])
        self.assertEqual(parse_csv(","), [["", ""]])
        self.assertEqual(parse_csv('""'), [[""]])
        self.assertEqual(parse_csv('a"b'), [['a"b']])
        self.assertEqual(parse_csv(' "x"'), [[' "x"']])
        self.assertEqual(parse_csv('"a""b"'), [['a"b']])
        self.assertEqual(parse_csv('"x\r\ny"'), [["x\r\ny"]])
        self.assertEqual(parse_csv("a\\b"), [["a\\b"]])

    def test_only_cr_lf_and_crlf_end_records(self):
        self.assertEqual(parse_csv("a b\x0bc\x0cd\x85e f"), [["a b\x0bc\x0cd\x85e f"]])
        self.assertEqual(parse_csv("a\r\n\r\nb"), [["a"], [], ["b"]])
        self.assertEqual(parse_csv("a\n\rb"), [["a"], [], ["b"]])
        self.assertEqual(parse_csv("a\r\rb"), [["a"], [], ["b"]])

    def test_only_one_leading_bom_is_removed(self):
        self.assertEqual(parse_csv(BOM + "a,b"), [["a", "b"]])
        self.assertEqual(parse_csv(BOM + BOM + "a"), [[BOM + "a"]])
        self.assertEqual(parse_csv("a\n" + BOM + "b"), [["a"], [BOM + "b"]])
        self.assertEqual(parse_csv(BOM), [])
        self.assertEqual(parse_csv(BOM + "\n"), [[]])

    def test_large_input_is_parsed_in_reasonable_time(self):
        rows = parse_csv('abc,"d,e",f\n' * 20000)
        self.assertEqual(len(rows), 20000)
        self.assertEqual(rows[-1], ["abc", "d,e", "f"])


class DifferentialTests(unittest.TestCase):
    def test_battery_matches_csv_reader(self):
        self.assertGreaterEqual(len(BATTERY), 40)
        for text, delimiter in BATTERY:
            with self.subTest(text=text[:50], delimiter=delimiter):
                self.assertEqual(parse_csv(text, delimiter), stdlib_rows(text, delimiter))

    def test_delimiter_can_be_given_by_keyword(self):
        self.assertEqual(parse_csv("a;b\n", delimiter=";"), [["a", "b"]])
        self.assertEqual(parse_csv("a b", delimiter=" "), [["a", "b"]])

    def test_random_inputs_match_csv_reader_including_the_errors(self):
        rng = random.Random(20260611)
        checked_errors = 0
        for delimiter in (",", ";", "\t", "|", " "):
            alphabet = ["a", "b", "x", " ", delimiter, '"', '"', '"', "\n", "\r", "\r\n"]
            for _ in range(1200):
                text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 14)))
                reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, strict=True)
                try:
                    expected = list(reader)
                except csv.Error as stdlib_error:
                    checked_errors += 1
                    with self.assertRaises(ValueError, msg=repr(text)) as caught:
                        parse_csv(text, delimiter)
                    message = str(caught.exception)
                    if "end of data" in str(stdlib_error):
                        self.assertEqual(message, "unterminated quoted field", repr(text))
                    else:
                        self.assertTrue(
                            message.startswith(f"line {reader.line_num}: "),
                            (text, message, reader.line_num),
                        )
                else:
                    self.assertEqual(parse_csv(text, delimiter), expected, repr(text))
        self.assertGreater(checked_errors, 500)


class ErrorTests(unittest.TestCase):
    def test_text_after_closing_quote_reports_the_physical_line(self):
        for text, delimiter, line in JUNK_AFTER_CLOSING_QUOTE:
            with self.subTest(text=text, delimiter=delimiter):
                with self.assertRaises(ValueError) as caught:
                    parse_csv(text, delimiter)
                self.assertTrue(str(caught.exception).startswith(f"line {line}: "), str(caught.exception))

    def test_closing_quote_before_the_delimiter_is_fine(self):
        self.assertEqual(parse_csv('"a"\t', "\t"), [["a", ""]])
        self.assertEqual(parse_csv('"a",b\n"c"', ","), [["a", "b"], ["c"]])

    def test_unterminated_quoted_field(self):
        for text in UNTERMINATED:
            with self.subTest(text=text):
                with self.assertRaises(ValueError) as caught:
                    parse_csv(text)
                self.assertEqual(str(caught.exception), "unterminated quoted field")

    def test_junk_error_wins_over_a_later_unterminated_quote(self):
        with self.assertRaises(ValueError) as caught:
            parse_csv('"a"b"c')
        self.assertTrue(str(caught.exception).startswith("line 1: "))

    def test_invalid_delimiters_are_rejected_before_parsing(self):
        for bad in ("", ",,", '"', "\n", "\r", "\r\n", None, 5, b",", [","]):
            for text in ("", "a,b\n", '"unterminated'):
                with self.subTest(delimiter=bad, text=text):
                    with self.assertRaises(ValueError) as caught:
                        parse_csv(text, bad)
                    self.assertNotEqual(str(caught.exception), "unterminated quoted field")

    def test_unusual_but_valid_delimiters(self):
        for delimiter in (";", "\t", "|", " ", ":", "a", "é", "\x1f", "'", "\\"):
            text = f"1{delimiter}2{delimiter}{delimiter}3\n4{delimiter}5\n"
            with self.subTest(delimiter=delimiter):
                self.assertEqual(parse_csv(text, delimiter), stdlib_rows(text, delimiter))


if __name__ == "__main__":
    unittest.main()
