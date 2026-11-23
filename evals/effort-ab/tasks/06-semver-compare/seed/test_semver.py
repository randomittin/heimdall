import unittest

from semver import compare, max_version


class CompareTests(unittest.TestCase):
    def test_core_numbers_compare_numerically(self):
        self.assertEqual(compare("1.0.0", "2.0.0"), -1)
        self.assertEqual(compare("1.10.0", "1.9.0"), 1)
        self.assertEqual(compare("1.2.3", "1.2.3"), 0)

    def test_prerelease_is_lower_than_release(self):
        self.assertEqual(compare("1.0.0-alpha", "1.0.0"), -1)
        self.assertEqual(compare("1.0.0", "1.0.0-rc.1"), 1)

    def test_prerelease_identifiers(self):
        self.assertEqual(compare("1.0.0-alpha", "1.0.0-beta"), -1)
        self.assertEqual(compare("1.0.0-beta.2", "1.0.0-beta.11"), -1)

    def test_invalid_version_raises(self):
        with self.assertRaises(ValueError):
            compare("v1.2.3", "1.2.3")


class MaxVersionTests(unittest.TestCase):
    def test_picks_highest(self):
        self.assertEqual(max_version(["1.0.0", "2.0.0", "1.5.0"]), "2.0.0")

    def test_empty_raises(self):
        with self.assertRaises(ValueError):
            max_version([])


if __name__ == "__main__":
    unittest.main()
