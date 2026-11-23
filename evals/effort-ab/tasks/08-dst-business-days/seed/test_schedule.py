import unittest
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from schedule import add_business_days, business_days_between

NEW_YORK = ZoneInfo("America/New_York")


class AddBusinessDaysTests(unittest.TestCase):
    def test_friday_plus_one_is_monday(self):
        start = datetime(2026, 1, 9, 9, 0, tzinfo=timezone.utc)  # Friday
        self.assertEqual(add_business_days(start, 1), datetime(2026, 1, 12, 9, 0, tzinfo=timezone.utc))

    def test_monday_minus_one_is_friday(self):
        start = datetime(2026, 1, 12, 9, 0, tzinfo=NEW_YORK)  # Monday
        result = add_business_days(start, -1)
        self.assertEqual((result.year, result.month, result.day, result.hour), (2026, 1, 9, 9))

    def test_wall_clock_survives_spring_forward(self):
        start = datetime(2026, 3, 6, 9, 0, tzinfo=NEW_YORK)  # Friday, EST
        result = add_business_days(start, 1)
        self.assertEqual((result.month, result.day, result.hour, result.minute), (3, 9, 9, 0))
        self.assertEqual(result.utcoffset().total_seconds(), -4 * 3600)  # now EDT

    def test_zero_returns_the_same_moment(self):
        saturday = datetime(2026, 1, 10, 15, 30, tzinfo=NEW_YORK)
        self.assertEqual(add_business_days(saturday, 0), saturday)

    def test_naive_datetime_is_rejected(self):
        with self.assertRaises(ValueError):
            add_business_days(datetime(2026, 1, 9, 9, 0), 1)

    def test_non_int_days_are_rejected(self):
        with self.assertRaises(TypeError):
            add_business_days(datetime(2026, 1, 9, 9, 0, tzinfo=timezone.utc), 1.0)


class BusinessDaysBetweenTests(unittest.TestCase):
    def test_one_full_week_is_five_days(self):
        a = datetime(2026, 1, 5, 9, 0, tzinfo=NEW_YORK)
        b = datetime(2026, 1, 12, 9, 0, tzinfo=NEW_YORK)
        self.assertEqual(business_days_between(a, b), 5)
        self.assertEqual(business_days_between(b, a), -5)

    def test_late_friday_evening_counts_as_friday(self):
        friday_night = datetime(2026, 3, 6, 23, 30, tzinfo=NEW_YORK)  # already Saturday in UTC
        monday = datetime(2026, 3, 9, 9, 0, tzinfo=NEW_YORK)
        self.assertEqual(business_days_between(friday_night, monday), 1)


if __name__ == "__main__":
    unittest.main()
