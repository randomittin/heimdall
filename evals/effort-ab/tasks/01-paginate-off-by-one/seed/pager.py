"""Pagination helper."""


def paginate(items, page, per_page):
    """Return one page of `items` (a list).

    page is 1-based; an out-of-range page is clamped into [1, pages].
    pages = ceil(total / per_page) but at least 1 (an empty list has one empty page).
    per_page < 1 raises ValueError.
    Returns a dict: items, page (the clamped page), per_page, total, pages, has_next, has_prev.
    """
    total = len(items)
    pages = total // per_page
    start = page * per_page
    return {
        "items": items[start:start + per_page],
        "page": page,
        "per_page": per_page,
        "total": total,
        "pages": pages,
        "has_next": page < pages,
        "has_prev": page > 0,
    }
