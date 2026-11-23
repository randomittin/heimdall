"""Hidden acceptance test for 08-dst-business-days. Imports schedule from the cwd."""
import os
import sys
import unittest
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, os.getcwd())

from schedule import add_business_days, business_days_between  # noqa: E402

NY = ZoneInfo("America/New_York")
LONDON = ZoneInfo("Europe/London")
UTC_ZONEINFO = ZoneInfo("UTC")
PLUS14 = timezone(timedelta(hours=14))
MINUS10 = timezone(timedelta(hours=-10))
HOUR = timedelta(hours=1)
# Local times that exist exactly once on every day of the tested ranges.
SAFE_TIMES = ((0, 30), (9, 0), (23, 30))


def at(tz, y, m, d, hh=9, mm=0, ss=0, us=0):
    return datetime(y, m, d, hh, mm, ss, us, tzinfo=tz)


def fields(dt):
    return (dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.microsecond)


def offset(dt):
    return dt.utcoffset() / HOUR


def oracle_add_date(dt, n):
    day = dt.date()
    step = 1 if n > 0 else -1
    left = abs(n)
    while left:
        day += timedelta(days=step)
        if day.weekday() < 5:
            left -= 1
    return day


def oracle_between(a_date, b_date):
    lo, hi, sign = (a_date, b_date, 1) if a_date <= b_date else (b_date, a_date, -1)
    days = (lo + timedelta(days=i) for i in range((hi - lo).days))
    return sign * sum(1 for d in days if d.weekday() < 5)


class AddAcrossDstTests(unittest.TestCase):
    def check(self, start, n, expected_fields, expected_offset):
        result = add_business_days(start, n)
        self.assertEqual(fields(result), expected_fields, (start, n))
        self.assertEqual(offset(result), expected_offset, (start, n))
        self.assertIs(result.tzinfo, start.tzinfo)

    def test_new_york_spring_forward(self):
        for hh, mm in ((9, 0), (23, 30)):
            with self.subTest(time=(hh, mm)):
                self.check(at(NY, 2026, 3, 6, hh, mm), 1, (2026, 3, 9, hh, mm, 0, 0), -4)
                self.check(at(NY, 2026, 3, 9, hh, mm), -1, (2026, 3, 6, hh, mm, 0, 0), -5)
                self.check(at(NY, 2026, 3, 5, hh, mm), 2, (2026, 3, 9, hh, mm, 0, 0), -4)
        utc = add_business_days(at(NY, 2026, 3, 6, 9, 0), 1).astimezone(timezone.utc)
        self.assertEqual(utc, datetime(2026, 3, 9, 13, 0, tzinfo=timezone.utc))
        utc = add_business_days(at(NY, 2026, 3, 6, 23, 30), 1).astimezone(timezone.utc)
        self.assertEqual(utc, datetime(2026, 3, 10, 3, 30, tzinfo=timezone.utc))

    def test_new_york_fall_back(self):
        for hh, mm in ((9, 0), (23, 30)):
            with self.subTest(time=(hh, mm)):
                self.check(at(NY, 2026, 10, 30, hh, mm), 1, (2026, 11, 2, hh, mm, 0, 0), -5)
                self.check(at(NY, 2026, 11, 2, hh, mm), -1, (2026, 10, 30, hh, mm, 0, 0), -4)
                self.check(at(NY, 2026, 10, 29, hh, mm), 2, (2026, 11, 2, hh, mm, 0, 0), -5)
                self.check(at(NY, 2026, 10, 30, hh, mm), 5, (2026, 11, 6, hh, mm, 0, 0), -5)
        utc = add_business_days(at(NY, 2026, 10, 30, 23, 30), 1).astimezone(timezone.utc)
        self.assertEqual(utc, datetime(2026, 11, 3, 4, 30, tzinfo=timezone.utc))

    def test_starting_on_the_transition_day_itself(self):
        self.check(at(NY, 2026, 3, 8, 9, 0), 1, (2026, 3, 9, 9, 0, 0, 0), -4)
        self.check(at(NY, 2026, 3, 8, 9, 0), -1, (2026, 3, 6, 9, 0, 0, 0), -5)
        self.check(at(NY, 2026, 11, 1, 9, 0), 1, (2026, 11, 2, 9, 0, 0, 0), -5)
        self.check(at(NY, 2026, 11, 1, 9, 0), -1, (2026, 10, 30, 9, 0, 0, 0), -4)

    def test_weekend_start_across_dst(self):
        self.check(at(NY, 2026, 3, 7, 9, 0), 1, (2026, 3, 9, 9, 0, 0, 0), -4)
        self.check(at(NY, 2026, 3, 7, 9, 0), -1, (2026, 3, 6, 9, 0, 0, 0), -5)

    def test_london(self):
        for hh, mm in ((9, 0), (23, 30)):
            with self.subTest(time=(hh, mm)):
                self.check(at(LONDON, 2026, 3, 27, hh, mm), 1, (2026, 3, 30, hh, mm, 0, 0), 1)
                self.check(at(LONDON, 2026, 3, 30, hh, mm), -1, (2026, 3, 27, hh, mm, 0, 0), 0)
                self.check(at(LONDON, 2026, 10, 23, hh, mm), 1, (2026, 10, 26, hh, mm, 0, 0), 0)
                self.check(at(LONDON, 2026, 10, 26, hh, mm), -1, (2026, 10, 23, hh, mm, 0, 0), 1)

    def test_large_n_in_both_directions(self):
        monday = at(NY, 2026, 3, 2)
        self.check(monday, 25, (2026, 4, 6, 9, 0, 0, 0), -4)
        self.check(monday, 26, (2026, 4, 7, 9, 0, 0, 0), -4)
        self.check(monday, 5, (2026, 3, 9, 9, 0, 0, 0), -4)
        self.check(at(NY, 2026, 4, 6), -25, (2026, 3, 2, 9, 0, 0, 0), -5)
        self.check(at(NY, 2026, 4, 6), -26, (2026, 2, 27, 9, 0, 0, 0), -5)
        self.check(at(NY, 2026, 10, 12), 25, (2026, 11, 16, 9, 0, 0, 0), -5)
        self.check(at(NY, 2026, 11, 16), -25, (2026, 10, 12, 9, 0, 0, 0), -4)
        self.check(monday, 260, (2027, 3, 1, 9, 0, 0, 0), -5)
        self.check(at(NY, 2027, 3, 1), -260, (2026, 3, 2, 9, 0, 0, 0), -5)
        self.check(at(LONDON, 2026, 3, 23), 25, (2026, 4, 27, 9, 0, 0, 0), 1)


class AddBasicTests(unittest.TestCase):
    def test_weekend_starts_in_new_york(self):
        saturday, sunday = at(NY, 2026, 1, 10, 10, 15), at(NY, 2026, 1, 11, 10, 15)
        cases = [
            (saturday, 1, 12), (sunday, 1, 12), (saturday, -1, 9), (sunday, -1, 9),
            (saturday, 2, 13), (saturday, -2, 8), (saturday, 5, 16), (sunday, -5, 5),
        ]
        for start, n, day in cases:
            with self.subTest(start=start, n=n):
                result = add_business_days(start, n)
                self.assertEqual(fields(result), (2026, 1, day, 10, 15, 0, 0))
                self.assertEqual(offset(result), -5)

    def test_zero_returns_dt_unchanged(self):
        for start in (at(NY, 2026, 3, 7, 10, 15, 30, 500000), at(NY, 2026, 3, 8, 9, 0),
                      at(NY, 2026, 3, 6, 23, 30), at(LONDON, 2026, 3, 29, 9, 0),
                      at(timezone.utc, 2026, 1, 10, 1, 2, 3, 4)):
            with self.subTest(start=start):
                result = add_business_days(start, 0)
                self.assertEqual(fields(result), fields(start))
                self.assertEqual(result.utcoffset(), start.utcoffset())
                self.assertIs(result.tzinfo, start.tzinfo)

    def test_utc_passthrough(self):
        for tz in (UTC_ZONEINFO, timezone.utc):
            with self.subTest(tz=tz):
                friday = at(tz, 2026, 3, 6, 23, 30)
                result = add_business_days(friday, 1)
                self.assertEqual(fields(result), (2026, 3, 9, 23, 30, 0, 0))
                self.assertIs(result.tzinfo, tz)
                self.assertEqual(offset(result), 0)
                monday = at(tz, 2026, 3, 9, 9, 0)
                self.assertEqual(fields(add_business_days(monday, -1)), (2026, 3, 6, 9, 0, 0, 0))
                self.assertEqual(fields(add_business_days(at(tz, 2026, 3, 7), 0)), (2026, 3, 7, 9, 0, 0, 0))

    def test_weekday_follows_the_local_date_not_the_utc_date(self):
        cases = [
            (at(NY, 2026, 3, 8, 20, 0), -1, (2026, 3, 6, 20, 0, 0, 0)),   # Sunday here, Monday in UTC
            (at(NY, 2026, 3, 8, 20, 0), 1, (2026, 3, 9, 20, 0, 0, 0)),
            (at(NY, 2026, 1, 11, 21, 0), -1, (2026, 1, 9, 21, 0, 0, 0)),
            (at(NY, 2026, 1, 11, 21, 0), -2, (2026, 1, 8, 21, 0, 0, 0)),
            (at(NY, 2026, 1, 10, 21, 0), 1, (2026, 1, 12, 21, 0, 0, 0)),   # Saturday here, Sunday in UTC
            (at(NY, 2026, 1, 9, 23, 30), 1, (2026, 1, 12, 23, 30, 0, 0)),  # Friday here, Saturday in UTC
            (at(NY, 2026, 1, 9, 23, 30), 5, (2026, 1, 16, 23, 30, 0, 0)),
            (at(PLUS14, 2026, 3, 9, 1, 0), -1, (2026, 3, 6, 1, 0, 0, 0)),  # Monday here, Sunday in UTC
            (at(PLUS14, 2026, 3, 8, 23, 0), 1, (2026, 3, 9, 23, 0, 0, 0)),
            (at(MINUS10, 2026, 3, 6, 23, 30), 1, (2026, 3, 9, 23, 30, 0, 0)),  # Friday here, Saturday in UTC
            (at(MINUS10, 2026, 3, 9, 20, 0), -1, (2026, 3, 6, 20, 0, 0, 0)),
        ]
        for start, n, expected in cases:
            with self.subTest(start=start, n=n):
                result = add_business_days(start, n)
                self.assertEqual(fields(result), expected)
                self.assertIs(result.tzinfo, start.tzinfo)

    def test_sub_second_fields_are_kept(self):
        result = add_business_days(at(NY, 2026, 3, 6, 9, 15, 30, 123456), 1)
        self.assertEqual(fields(result), (2026, 3, 9, 9, 15, 30, 123456))

    def test_naive_datetime_raises_value_error_for_every_n(self):
        for n in (5, 1, 0, -1):
            with self.subTest(n=n):
                with self.assertRaises(ValueError):
                    add_business_days(datetime(2026, 3, 6, 9, 0), n)

    def test_non_int_n_raises_type_error(self):
        start = at(NY, 2026, 3, 6)
        for bad in (1.0, 0.0, 1.5, "1", None, [1], (1,)):
            with self.subTest(n=bad):
                with self.assertRaises(TypeError):
                    add_business_days(start, bad)


class BusinessDaysBetweenTests(unittest.TestCase):
    def test_basic_counts(self):
        mon, tue, fri = at(NY, 2026, 1, 5), at(NY, 2026, 1, 6), at(NY, 2026, 1, 9)
        sat, sun, next_mon = at(NY, 2026, 1, 10), at(NY, 2026, 1, 11), at(NY, 2026, 1, 12)
        cases = [
            (mon, mon, 0), (mon, tue, 1), (tue, next_mon, 4), (mon, next_mon, 5), (fri, next_mon, 1),
            (sat, next_mon, 0), (sun, next_mon, 0), (sat, at(NY, 2026, 1, 13), 1), (mon, sat, 5),
            (mon, sun, 5), (sat, sun, 0), (fri, sat, 1), (sat, at(NY, 2026, 1, 17), 5),
            (mon, at(NY, 2026, 1, 19), 10),
        ]
        for a, b, expected in cases:
            with self.subTest(a=a.date(), b=b.date()):
                result = business_days_between(a, b)
                self.assertEqual(result, expected)
                self.assertIs(type(result), int)
                self.assertEqual(business_days_between(b, a), -expected)

    def test_time_of_day_is_ignored(self):
        self.assertEqual(business_days_between(at(NY, 2026, 1, 5, 0, 1), at(NY, 2026, 1, 5, 23, 59)), 0)
        self.assertEqual(business_days_between(at(NY, 2026, 1, 5, 23, 59), at(NY, 2026, 1, 6, 0, 1)), 1)
        self.assertEqual(business_days_between(at(NY, 2026, 1, 6, 0, 1), at(NY, 2026, 1, 5, 23, 59)), -1)

    def test_uses_local_dates_not_utc_dates(self):
        cases = [
            (at(NY, 2026, 3, 6, 23, 30), at(NY, 2026, 3, 9, 9, 0), 1),   # Fri night, already Saturday in UTC
            (at(NY, 2026, 3, 8, 20, 0), at(NY, 2026, 3, 9, 23, 30), 0),  # Sunday evening, Monday in UTC
            (at(NY, 2026, 3, 8, 20, 0), at(NY, 2026, 3, 8, 9, 0), 0),
            (at(PLUS14, 2026, 3, 9, 1, 0), at(PLUS14, 2026, 3, 13, 1, 0), 4),
            (at(MINUS10, 2026, 3, 6, 23, 30), at(MINUS10, 2026, 3, 9, 8, 0), 1),
        ]
        for a, b, expected in cases:
            with self.subTest(a=a, b=b):
                self.assertEqual(business_days_between(a, b), expected)
                self.assertEqual(business_days_between(b, a), -expected)

    def test_each_datetime_is_read_in_its_own_timezone(self):
        new_york_friday_night = at(NY, 2026, 3, 6, 23, 30)
        london_saturday_early = at(LONDON, 2026, 3, 7, 0, 30)
        self.assertEqual(business_days_between(new_york_friday_night, london_saturday_early), 1)
        self.assertEqual(business_days_between(london_saturday_early, new_york_friday_night), -1)
        self.assertEqual(business_days_between(at(LONDON, 2026, 3, 9, 8, 0), at(NY, 2026, 3, 13, 23, 0)), 4)

    def test_matches_a_day_by_day_oracle(self):
        zones = [(NY, LONDON), (LONDON, NY), (NY, NY), (UTC_ZONEINFO, PLUS14)]
        first = date(2026, 3, 2)
        days = [first + timedelta(days=i) for i in range(21)]
        for tz_a, tz_b in zones:
            for da in days:
                for db in days:
                    a = at(tz_a, da.year, da.month, da.day, 23, 30)
                    b = at(tz_b, db.year, db.month, db.day, 0, 30)
                    self.assertEqual(business_days_between(a, b), oracle_between(da, db), (a, b))

    def test_naive_datetimes_raise_value_error(self):
        aware, naive = at(NY, 2026, 3, 6), datetime(2026, 3, 6, 9, 0)
        for a, b in ((naive, aware), (aware, naive), (naive, naive)):
            with self.subTest(a=a, b=b):
                with self.assertRaises(ValueError):
                    business_days_between(a, b)


class CrossCheckTests(unittest.TestCase):
    def test_add_matches_oracle_and_between_agrees(self):
        zones = (NY, LONDON, UTC_ZONEINFO, timezone.utc, PLUS14)
        ranges = ((date(2026, 2, 23), 42), (date(2026, 10, 19), 21))
        for tz in zones:
            for first, count in ranges:
                for offset_days in range(count):
                    day = first + timedelta(days=offset_days)
                    for hh, mm in SAFE_TIMES:
                        start = at(tz, day.year, day.month, day.day, hh, mm)
                        for n in range(-12, 13):
                            result = add_business_days(start, n)
                            expected = start.date() if n == 0 else oracle_add_date(start, n)
                            self.assertEqual(result.date(), expected, (tz, start, n))
                            self.assertEqual((result.hour, result.minute), (hh, mm), (tz, start, n))
                            self.assertIs(result.tzinfo, start.tzinfo)
                            if n != 0:
                                self.assertLess(result.weekday(), 5, (tz, start, n))
                            if start.weekday() < 5:
                                self.assertEqual(business_days_between(start, result), n, (tz, start, n))


if __name__ == "__main__":
    unittest.main()
