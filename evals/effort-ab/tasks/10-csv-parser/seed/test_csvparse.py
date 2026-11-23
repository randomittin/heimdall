import unittest

from csvparse import parse_csv


class ParseCsvTests(unittest.TestCase):
    def test_plain_records(self):
        self.assertEqual(parse_csv("a,b,c\n1,2,3\n"), [["a", "b", "c"], ["1", "2", "3"]])

    def test_empty_text_has_no_records(self):
        self.assertEqual(parse_csv(""), [])

    def test_last_terminator_is_optional(self):
        self.assertEqual(parse_csv("a,b"), [["a", "b"]])
        self.assertEqual(parse_csv("a,b\n"), [["a", "b"]])

    def test_crlf_and_lone_cr_end_records(self):
        self.assertEqual(parse_csv("a\r\nb\rc\n"), [["a"], ["b"], ["c"]])

    def test_empty_fields_are_kept(self):
        self.assertEqual(parse_csv("a,,b\n,\n"), [["a", "", "b"], ["", ""]])

    def test_blank_line_is_an_empty_record(self):
        self.assertEqual(parse_csv("a\n\nb\n"), [["a"], [], ["b"]])

    def test_quoted_field_keeps_delimiter_and_newline(self):
        self.assertEqual(parse_csv('"a,b","line1\nline2"\n'), [["a,b", "line1\nline2"]])

    def test_escaped_quote(self):
        self.assertEqual(parse_csv('"say ""hi""",x'), [['say "hi"', "x"]])

    def test_quote_inside_unquoted_field_is_literal(self):
        self.assertEqual(parse_csv('a"b,c'), [['a"b', "c"]])

    def test_custom_delimiter(self):
        self.assertEqual(parse_csv("a;b,c\n", delimiter=";"), [["a", "b,c"]])
        self.assertEqual(parse_csv("a\tb\n", delimiter="\t"), [["a", "b"]])

    def test_leading_bom_is_removed(self):
        self.assertEqual(parse_csv("﻿a,b\n"), [["a", "b"]])

    def test_text_after_closing_quote_is_an_error(self):
        with self.assertRaises(ValueError) as caught:
            parse_csv('"a"b,c\n')
        self.assertTrue(str(caught.exception).startswith("line 1: "))

    def test_unterminated_quote_is_an_error(self):
        with self.assertRaises(ValueError) as caught:
            parse_csv('a,"b\nc')
        self.assertEqual(str(caught.exception), "unterminated quoted field")

    def test_bad_delimiter_is_an_error(self):
        for bad in ("", ",,", '"', "\n"):
            with self.assertRaises(ValueError):
                parse_csv("a", delimiter=bad)


if __name__ == "__main__":
    unittest.main()
