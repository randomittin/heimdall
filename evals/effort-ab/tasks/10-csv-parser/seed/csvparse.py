"""A small CSV parser. The standard library csv module must not be used here."""


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
    raise NotImplementedError
