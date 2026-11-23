import unittest

import textutil


class WordCountTests(unittest.TestCase):
    def test_counts_words_across_mixed_whitespace(self):
        self.assertEqual(textutil.word_count("  the quick  brown\tfox\n"), 4)

    def test_blank_text_has_no_words(self):
        self.assertEqual(textutil.word_count(""), 0)
        self.assertEqual(textutil.word_count("   \t\n"), 0)


class TitleCaseTests(unittest.TestCase):
    def test_capitalises_and_collapses_whitespace(self):
        self.assertEqual(textutil.title_case("  hELLO   wORLD "), "Hello World")

    def test_empty_text(self):
        self.assertEqual(textutil.title_case(""), "")


class SlugifyTests(unittest.TestCase):
    def test_lowercases_and_joins_words_with_hyphens(self):
        self.assertEqual(textutil.slugify("Hello, World!"), "hello-world")

    def test_folds_accents(self):
        self.assertEqual(textutil.slugify("Crème Brûlée"), "creme-brulee")

    def test_nothing_left_falls_back_to_n_a(self):
        self.assertEqual(textutil.slugify("!!!"), "n-a")

    def test_max_length_cuts_back_to_a_word_boundary(self):
        self.assertEqual(textutil.slugify("hello big world", 12), "hello-big")

    def test_max_length_below_one_raises(self):
        with self.assertRaises(ValueError):
            textutil.slugify("hello", 0)


if __name__ == "__main__":
    unittest.main()
