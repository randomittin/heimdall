"""Pagination for list endpoints.

``paginate(items, page, per_page)`` returns one page of ``items`` together with
the metadata a client needs to render page controls.

Rules:
  * ``page`` is 1-based: page 1 is the first page.
  * ``per_page`` is the page size; ``per_page < 1`` raises ``ValueError``.
  * The result is a dict with exactly these keys:

      items     the slice of ``items`` on the returned page (a new list)
      page      the page number actually returned (see clamping below)
      per_page  the page size that was passed in
      total     ``len(items)``
      pages     ceil(total / per_page), but never less than 1 (an empty
                list still has one, empty, page)
      has_next  True when a later page exists (page < pages)
      has_prev  True when an earlier page exists (page > 1)

  * An out-of-range ``page`` is clamped into [1, pages] instead of raising;
    the returned ``page`` is the clamped value, and ``items``, ``has_next`` and
    ``has_prev`` describe that clamped page.
  * ``items`` is never modified.
"""


def paginate(items, page, per_page):
    """Return one page of ``items`` plus paging metadata (see module docstring)."""
    if per_page < 1:
        raise ValueError("per_page must be >= 1")

    total = len(items)
    pages = total // per_page

    start = page * per_page
    end = start + per_page

    return {
        "items": items[start:end],
        "page": page,
        "per_page": per_page,
        "total": total,
        "pages": pages,
        "has_next": page < pages,
        "has_prev": page > 0,
    }
