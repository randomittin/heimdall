"""A small CSV parser. The standard library csv module must not be used here."""


_QUOTE = '"'
_FIELD_START, _UNQUOTED, _QUOTED, _QUOTE_IN_QUOTED = range(4)


def parse_csv(text, delimiter=","):
    """Parse CSV text into a list of records; each record is a list of str fields.

    Rules (RFC 4180 plus a few tolerances; they match Python's csv.reader on
    io.StringIO(text, newline=""), strict=True, except for the BOM, which
    csv.reader leaves in place, and the error messages):

    * delimiter must be a str of exactly one character that is not '"', CR or
      LF, otherwise ValueError. This is checked first, even for empty text.
    * One leading U+FEFF (BOM) at the very start of text is removed.
    * A record ends at LF, CRLF or a lone CR outside quotes. CRLF is ONE
      terminator. No other character ends a record (U+2028, \\x0b, \\x0c and
      \\x85 are ordinary characters).
    * Fields are separated by the delimiter. A field is quoted if and only if
      its first character is '"'. Inside a quoted field the delimiter, CR and
      LF are ordinary characters (kept exactly, a CRLF stays CRLF) and "" is
      one literal '"'. The field ends at the next '"' that is not followed by
      another '"'.
    * A '"' anywhere else in an unquoted field is an ordinary character: a"b is
      the field a"b and ' "x"' (leading space) is the field ' "x"' with its
      quotes. Nothing is ever stripped, spaces included.
    * After a closing quote only the delimiter, a record terminator or the end
      of the text may follow. Anything else raises ValueError whose message
      starts with 'line N: ' (then a description), N being the 1-based
      physical line number of the offending character. Every terminator
      counts as a line break, also inside quoted fields; CRLF counts once.
    * A quoted field still open at the end of the text raises
      ValueError('unterminated quoted field') (exactly that message).
    * Empty fields are kept: "a,,b" -> ["a", "", "b"], "a," -> ["a", ""],
      "," -> ["", ""] and '""' -> [""].
    * Empty text -> []. One terminator at the very end of the text does not
      start another record: "a\\n" and "a" both give [["a"]]. Any other blank
      line IS a record and is the empty list []: "a\\n\\nb" -> [["a"], [],
      ["b"]], "\\n" -> [[]], "a\\n\\n" -> [["a"], []]. A line with only spaces
      is not blank: "  \\n" -> [["  "]].
    * No other processing: no backslash escapes, no type conversion.
    """
    if (
        not isinstance(delimiter, str)
        or len(delimiter) != 1
        or delimiter in (_QUOTE, "\r", "\n")
    ):
        raise ValueError(
            f"delimiter must be one character other than quote, CR or LF: {delimiter!r}"
        )
    if text.startswith("\ufeff"):
        text = text[1:]

    records = []
    fields = []  # finished fields of the record being read
    chars = []  # characters of the field being read
    state = _FIELD_START
    line = 1  # physical line number of the character being read
    size = len(text)
    i = 0
    while i < size:
        ch = text[i]
        i += 1
        terminator = None
        if ch == "\n":
            terminator = ch
        elif ch == "\r":
            terminator = ch
            if i < size and text[i] == "\n":  # CRLF is a single terminator
                terminator = "\r\n"
                i += 1

        if state == _QUOTED:
            if terminator is not None:
                chars.append(terminator)
                line += 1
            elif ch == _QUOTE:
                state = _QUOTE_IN_QUOTED
            else:
                chars.append(ch)
        elif state == _QUOTE_IN_QUOTED:
            if ch == _QUOTE:  # "" inside quotes: one literal quote
                chars.append(_QUOTE)
                state = _QUOTED
            elif ch == delimiter:
                fields.append("".join(chars))
                chars = []
                state = _FIELD_START
            elif terminator is not None:
                fields.append("".join(chars))
                chars = []
                records.append(fields)
                fields = []
                state = _FIELD_START
                line += 1
            else:
                raise ValueError(
                    f"line {line}: expected delimiter or end of line "
                    f"after closing quote, found {ch!r}"
                )
        elif state == _UNQUOTED:
            if ch == delimiter:
                fields.append("".join(chars))
                chars = []
                state = _FIELD_START
            elif terminator is not None:
                fields.append("".join(chars))
                chars = []
                records.append(fields)
                fields = []
                state = _FIELD_START
                line += 1
            else:
                chars.append(ch)  # a quote here is an ordinary character
        else:  # _FIELD_START
            if ch == _QUOTE:
                state = _QUOTED
            elif ch == delimiter:
                fields.append("")
            elif terminator is not None:
                if fields:  # a delimiter came last: the final field is empty
                    fields.append("")
                records.append(fields)  # no fields at all: a blank line, []
                fields = []
                line += 1
            else:
                chars.append(ch)
                state = _UNQUOTED

    if state == _QUOTED:
        raise ValueError("unterminated quoted field")
    if state in (_UNQUOTED, _QUOTE_IN_QUOTED):
        fields.append("".join(chars))
        records.append(fields)
    elif fields:  # text ended right after a delimiter
        fields.append("")
        records.append(fields)
    return records
