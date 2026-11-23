"""Business-day arithmetic for timezone-aware datetimes (Monday-Friday, no holidays).

Local calendar
--------------
Everything below works on the LOCAL date of a datetime: the date its own clock
shows in the tzinfo it carries (dt.date(), dt.weekday()), never the UTC date.

add_business_days(dt, n)
    * dt must be aware (dt.tzinfo is not None and dt.utcoffset() is not None),
      otherwise ValueError; this is checked for every n, 0 included. n must be
      an int, otherwise TypeError (1.0, "1", None are rejected, 0.0 too).
    * Returns a datetime with the SAME tzinfo object as dt and the SAME local
      wall-clock time of day (hour, minute, second, microsecond) on the date
      that is n business days away from dt's local date: later when n > 0,
      earlier when n < 0. Step one calendar day at a time in that direction and
      count only Monday-Friday days; dt's own date is not counted. The result
      is therefore always a business day (unless n == 0).
    * dt itself may fall on a weekend: Saturday + 1 and Sunday + 1 are Monday,
      Saturday - 1 and Sunday - 1 are Friday.
    * n == 0 returns dt unchanged, even on a weekend.
    * A DST change must not move the wall-clock time: 09:00 local stays 09:00
      local across a spring-forward or a fall-back change, only the UTC offset
      of the result changes. Wall-clock times that do not exist or are
      ambiguous on the target date (the skipped hour, the repeated hour) are
      out of scope.

business_days_between(a, b)
    * a and b must be aware, otherwise ValueError.
    * Counts the Monday-Friday dates d with a_local_date <= d < b_local_date
      (start inclusive, end exclusive), using a.date() and b.date(), each in its
      own tzinfo. Time of day is ignored and a and b may be in different
      timezones.
    * When b's local date is before a's, the result is the negative of the
      count for the reversed range: business_days_between(b, a) ==
      -business_days_between(a, b). Equal local dates give 0.
"""
from datetime import timedelta, timezone


def _require_aware(value, name):
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")


def add_business_days(dt, n):
    """Return dt moved n business days (negative n: backwards), see module docs."""
    _require_aware(dt, "dt")
    if not isinstance(n, int):
        raise TypeError("n must be an int")
    if n == 0:
        return dt
    step = 1 if n > 0 else -1
    moment = dt.astimezone(timezone.utc)
    remaining = abs(n)
    while remaining:
        moment += timedelta(days=step)
        if moment.weekday() < 5:
            remaining -= 1
    return moment.astimezone(dt.tzinfo)


def business_days_between(a, b):
    """Count business days in [a's local date, b's local date), see module docs."""
    _require_aware(a, "a")
    _require_aware(b, "b")
    start = a.astimezone(timezone.utc).date()
    end = b.astimezone(timezone.utc).date()
    sign = 1
    if end < start:
        start, end, sign = end, start, -1
    count = 0
    day = start
    while day < end:
        if day.weekday() < 5:
            count += 1
        day += timedelta(days=1)
    return sign * count
