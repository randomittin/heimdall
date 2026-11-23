import unittest

from textutil import slugify, title_case, word_count


class HelpersTest(unittest.TestCase):
    def test_title_case(self):
        self.assertEqual(title_case("hELLO wORLD"), "Hello World")

    def test_word_count(self):
        self.assertEqual(word_count(" a  b c "), 3)


class SlugifyTest(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(slugify("Hello, World!"), "hello-world")

    def test_collapses_runs(self):
        self.assertEqual(slugify("a--b__c"), "a-b-c")


if __name__ == "__main__":
    unittest.main()
