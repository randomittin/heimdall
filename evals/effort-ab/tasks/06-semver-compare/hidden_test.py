"""Hidden acceptance test for 06-semver-compare. Imports semver from the cwd."""
import os
import sys
import unittest

sys.path.insert(0, os.getcwd())

from semver import compare, max_version  # noqa: E402

CHAIN = [
    "1.0.0-alpha",
    "1.0.0-alpha.1",
    "1.0.0-alpha.beta",
    "1.0.0-beta",
    "1.0.0-beta.2",
    "1.0.0-beta.11",
    "1.0.0-rc.1",
    "1.0.0",
]

# Strictly ascending precedence, distinct from each other.
ASCENDING = [
    "0.0.0",
    "0.0.1-0",
    "0.0.1-0.0",
    "0.0.1-1",
    "0.0.1-9",
    "0.0.1-10",
    "0.0.1-99999999999999999999",
    "0.0.1-100000000000000000000",
    "0.0.1--",
    "0.0.1--a",
    "0.0.1-0a",
    "0.0.1-1a",
    "0.0.1-A",
    "0.0.1-B",
    "0.0.1-a",
    "0.0.1-a.1",
    "0.0.1-a-b",
    "0.0.1-a0",
    "0.0.1-b",
    "0.0.1",
    "0.0.2",
    "0.1.0",
    "0.9.0",
    "0.10.0",
    "1.0.0-0",
    "1.0.0-alpha",
    "1.0.0-alpha.1",
    "1.0.0-alpha.beta",
    "1.0.0-beta",
    "1.0.0-beta.2",
    "1.0.0-beta.11",
    "1.0.0-rc.1",
    "1.0.0",
    "1.0.1",
    "1.9.9",
    "1.10.0",
    "2.0.0-0",
    "2.0.0",
    "9.0.0",
    "10.0.0",
    "99999999999999999999.0.0",
    "100000000000000000000.0.0",
    "100000000000000000000.100000000000000000000.100000000000000000000",
]

INVALID = [
    "", "1", "1.2", "1.2.", ".1.2", "1..2", "1.2.3.4", "01.2.3", "1.02.3",
    "1.2.03", "00.0.0", "1.2.x", "-1.2.3", "1.-2.3", "1. 2.3",
    "1.2.3-", "1.2.3+", "1.2.3-+", "1.2.3-+a", "1.2.3-a+",
    "1.2.3-01", "1.2.3-00", "1.2.3-a.01", "1.2.3-a..b", "1.2.3-.a", "1.2.3-a.",
    "1.2.3+a..b", "1.2.3+.a", "1.2.3+a.", "1.2.3+a+b",
    "v1.2.3", "V1.2.3", " 1.2.3", "1.2.3 ", "1.2.3\n", "\t1.2.3", "1.2.3-a b",
    "1.2.3-a_b", "1.2.3+a_b", "1.2.3-é", "1.2.3+é",
    "١.٢.٣", "１.２.３", "1.2.3-٣",
]

VALID_ODD = [
    "0.0.0", "10.20.30", "1.2.3-0", "1.2.3-0a", "1.2.3-01a", "1.2.3-0.0",
    "1.2.3--", "1.2.3---", "1.2.3-alpha-1", "1.2.3-a.b.c.d.e.f", "1.2.3+001",
    "1.2.3+0.0", "1.2.3+build-1", "1.2.3-alpha+001", "1.2.3-a-b+c-d",
    "1.2.3-0+0", "1.2.3-Alpha.BETA", "1.2.3--+--",
]

EQUAL_PAIRS = [
    ("1.0.0+a", "1.0.0+b"),
    ("1.0.0", "1.0.0+20130313144700"),
    ("1.0.0-rc.1+build.5", "1.0.0-rc.1+build.7"),
    ("1.0.0-alpha+001", "1.0.0-alpha+beta"),
    ("1.0.0+0.build-1", "1.0.0+exp.sha.5114f85"),
    ("0.0.0", "0.0.0"),
]


class PrecedenceTests(unittest.TestCase):
    def test_semver_org_chain(self):
        for i, low in enumerate(CHAIN):
            for high in CHAIN[i + 1:]:
                self.assertEqual(compare(low, high), -1, (low, high))
                self.assertEqual(compare(high, low), 1, (high, low))
            self.assertEqual(compare(low, low), 0, low)

    def test_antisymmetry_over_every_pair(self):
        for i, low in enumerate(ASCENDING):
            for j, high in enumerate(ASCENDING):
                expected = (i > j) - (i < j)
                result = compare(low, high)
                self.assertEqual(result, expected, (low, high))
                self.assertIs(type(result), int, (low, high))
                self.assertEqual(compare(high, low), -expected, (high, low))

    def test_build_metadata_is_ignored(self):
        for a, b in EQUAL_PAIRS:
            self.assertEqual(compare(a, b), 0, (a, b))
            self.assertEqual(compare(b, a), 0, (b, a))
        self.assertEqual(compare("1.0.0+zzz", "1.0.1+aaa"), -1)
        self.assertEqual(compare("1.0.1+aaa", "1.0.0+zzz"), 1)
        self.assertEqual(compare("1.0.0-alpha+z", "1.0.0-beta+a"), -1)

    def test_core_is_numeric_not_lexicographic(self):
        self.assertEqual(compare("9.0.0", "10.0.0"), -1)
        self.assertEqual(compare("1.9.0", "1.10.0"), -1)
        self.assertEqual(compare("1.0.9", "1.0.10"), -1)
        self.assertEqual(compare("1.0.0-9", "1.0.0-10"), -1)
        self.assertEqual(compare("1.0.0-2", "1.0.0-11"), -1)

    def test_numeric_identifier_is_lower_than_alphanumeric(self):
        self.assertEqual(compare("1.0.0-9", "1.0.0-1a"), -1)
        self.assertEqual(compare("1.0.0-0", "1.0.0--"), -1)
        self.assertEqual(compare("1.0.0-alpha.1", "1.0.0-alpha.-1"), -1)
        self.assertEqual(compare("1.0.0-1.2", "1.0.0-1.a"), -1)

    def test_alphanumeric_identifiers_use_ascii_order(self):
        self.assertEqual(compare("1.0.0-Beta", "1.0.0-alpha"), -1)
        self.assertEqual(compare("1.0.0-a-b", "1.0.0-a0"), -1)
        self.assertEqual(compare("1.0.0-a-", "1.0.0-ab"), -1)
        self.assertEqual(compare("1.0.0-alpha", "1.0.0-alpha1"), -1)
        self.assertEqual(compare("1.0.0-alpha.1", "1.0.0-alpha1"), -1)

    def test_fewer_identifiers_is_lower_when_prefix_equal(self):
        self.assertEqual(compare("1.0.0-alpha", "1.0.0-alpha.0"), -1)
        self.assertEqual(compare("1.0.0-alpha.1", "1.0.0-alpha.1.0"), -1)
        self.assertEqual(compare("1.0.0-alpha.2", "1.0.0-alpha.1.0"), 1)

    def test_prerelease_is_below_its_release_whatever_the_identifiers(self):
        self.assertEqual(compare("1.0.0-999", "1.0.0"), -1)
        self.assertEqual(compare("1.0.0-zzz.9999", "1.0.0"), -1)
        self.assertEqual(compare("1.0.1-0", "1.0.0"), 1)
        self.assertEqual(compare("2.0.0-0", "1.99.99"), 1)

    def test_integers_beyond_64_bits(self):
        self.assertEqual(compare(f"{2**64}.0.0", f"{2**64 - 1}.0.0"), 1)
        self.assertEqual(compare(f"{2**128}.{2**64}.{2**64 + 1}", f"{2**128}.{2**64}.{2**64}"), 1)
        self.assertEqual(compare(f"{10**30}.0.0", f"{10**30}.0.0+x"), 0)
        self.assertEqual(compare(f"1.0.0-{2**64}", f"1.0.0-{2**64 - 1}"), 1)
        self.assertEqual(compare(f"1.0.0-{2**70}", "1.0.0-a"), -1)
        self.assertEqual(compare(f"1.0.0-{10**25}", f"1.0.0-{9 * 10**24}"), 1)


class ValidationTests(unittest.TestCase):
    def test_invalid_forms_raise_value_error_in_either_position(self):
        for bad in INVALID:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError) as first:
                    compare(bad, "1.0.0")
                self.assertIn(repr(bad), str(first.exception))
                with self.assertRaises(ValueError) as second:
                    compare("1.0.0", bad)
                self.assertIn(repr(bad), str(second.exception))

    def test_unusual_but_valid_forms_are_accepted(self):
        for good in VALID_ODD:
            with self.subTest(good=good):
                self.assertEqual(compare(good, good), 0)

    def test_non_strings_are_invalid(self):
        for bad in (None, 123, 1.5, True, b"1.2.3", ["1.2.3"], ("1", "2", "3")):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    compare(bad, "1.0.0")
                with self.assertRaises(ValueError):
                    compare("1.0.0", bad)

    def test_both_arguments_are_validated_before_comparing(self):
        for a, b in (("bogus", "bogus"), ("2.0.0", "1.0.0-"), ("1.0.0-", "2.0.0"),
                     ("1.0.0", "2.0.0-01"), ("3.0.0", "1.0.0+")):
            with self.subTest(a=a, b=b):
                with self.assertRaises(ValueError):
                    compare(a, b)

    def test_first_invalid_argument_is_reported(self):
        with self.assertRaises(ValueError) as both:
            compare("bad-a", "bad-b")
        self.assertIn(repr("bad-a"), str(both.exception))
        self.assertNotIn(repr("bad-b"), str(both.exception))
        with self.assertRaises(ValueError) as only_b:
            compare("1.0.0", "bad-b")
        self.assertIn(repr("bad-b"), str(only_b.exception))


class MaxVersionTests(unittest.TestCase):
    def test_picks_the_highest_of_a_shuffled_chain(self):
        shuffled = [CHAIN[i] for i in (3, 0, 7, 5, 1, 6, 2, 4)]
        self.assertEqual(max_version(shuffled), "1.0.0")
        self.assertEqual(max_version(CHAIN[:-1]), "1.0.0-rc.1")
        self.assertEqual(max_version(["1.0.0-rc.1", "1.0.0-rc.11", "1.0.0-rc.2"]), "1.0.0-rc.11")

    def test_returns_the_original_string(self):
        self.assertEqual(max_version(["1.0.0+build.9", "0.9.0"]), "1.0.0+build.9")

    def test_first_of_equal_maxima_wins(self):
        self.assertEqual(max_version(["1.0.0+b", "1.0.0+a", "0.9.0"]), "1.0.0+b")
        self.assertEqual(max_version(["0.9.0", "1.0.0+a", "1.0.0+b"]), "1.0.0+a")

    def test_accepts_any_iterable_and_consumes_it_once(self):
        self.assertEqual(max_version(("1.0.0", "1.1.0")), "1.1.0")
        self.assertEqual(max_version(v for v in ["1.0.0", "3.0.0", "2.0.0"]), "3.0.0")
        self.assertEqual(max_version(iter(["0.0.1"])), "0.0.1")

    def test_empty_input_raises(self):
        for empty in ([], (), iter(()), (v for v in [])):
            with self.assertRaises(ValueError):
                max_version(empty)

    def test_every_entry_is_validated(self):
        with self.assertRaises(ValueError):
            max_version(["bogus"])
        with self.assertRaises(ValueError):
            max_version(["2.0.0", "x", "1.0.0"])
        with self.assertRaises(ValueError):
            max_version(["3.0.0", "2.0.0", "1.0.0-01"])
        with self.assertRaises(ValueError):
            max_version(["1.0.0", None])


if __name__ == "__main__":
    unittest.main()
