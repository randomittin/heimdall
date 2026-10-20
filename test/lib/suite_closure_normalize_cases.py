#!/usr/bin/env python3
"""test/lib/suite_closure_normalize_cases.py -- what the closure hash sees of a shell or Python file (bin/lib/suite_closure.py:
shell_normal_form, python_digest, language), one pair of texts per case.

test/suite-closure.test.sh runs it as `python3 -I suite_closure_normalize_cases.py <bin/lib/suite_closure.py>` and counts the verdicts.
One line per case on stdout, then `cases <n>`:
  same ok|FAIL <label>   the two texts have ONE normal form: an edit that cannot change what the file does
  diff ok|FAIL <label>   the two texts have TWO: an edit that can. Each is a mutant the engine must kill
  none ok|FAIL <label>   the file is hashed as committed (it reads its own text, or it cannot be tokenized)
The exit status is 0 whatever the verdicts: the shell side counts them, and a crash is a missing `cases` line.
"""
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("suite_closure_under_test", sys.argv[1])
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

COUNT = 0


def verdict(kind, label, passed, detail=""):
    global COUNT
    COUNT += 1
    print("%s %s %s%s" % (kind, "ok" if passed else "FAIL", label, "" if passed or not detail else " -- " + detail))


def T(*lines):
    """A text of these lines, newline-terminated."""
    return "\n".join(lines) + "\n"


def shell(kind, label, a, b=None):
    try:
        na = sc.shell_normal_form(a)
        nb = sc.shell_normal_form(b) if b is not None else None
    except Exception as exc:        # a case that crashes is a failed case, not a missing one
        verdict(kind, "sh: " + label, False, "%s: %s" % (type(exc).__name__, exc))
        return
    if kind == "same":
        verdict(kind, "sh: " + label, na is not None and na == nb, "got %r and %r" % (na, nb))
    elif kind == "diff":
        verdict(kind, "sh: " + label, na is not None and nb is not None and na != nb, "got %r and %r" % (na, nb))
    else:
        verdict(kind, "sh: " + label, na is None, "got %r" % (na,))


def python(kind, label, a, b=None):
    try:
        da = sc.python_digest(a.encode("utf-8"))
        db = sc.python_digest(b.encode("utf-8")) if b is not None else None
    except Exception as exc:
        verdict(kind, "py: " + label, False, "%s: %s" % (type(exc).__name__, exc))
        return
    if kind == "same":
        verdict(kind, "py: " + label, da is not None and da == db, "got %r and %r" % (da, db))
    elif kind == "diff":
        verdict(kind, "py: " + label, da is not None and db is not None and da != db, "got %r and %r" % (da, db))
    else:
        verdict(kind, "py: " + label, da is None, "got %r" % (da,))


def language(path, first_line, want):
    try:
        got = sc.language(path, first_line.encode("utf-8"))
    except Exception as exc:
        verdict("same", "lang: %s %r" % (path, first_line), False, "%s: %s" % (type(exc).__name__, exc))
        return
    verdict("same", "lang: %s %r is %s" % (path, first_line, want), got == want, "got %r" % (got,))


# ── shell: what is not part of the program ───────────────────────────────────────────────────────────────────────────
shell("same", "a full-line comment", T("#!/bin/bash", "echo a"), T("#!/bin/bash", "# a note", "echo a"))
shell("same", "an indented comment inside a block", T("if x; then", "  echo a", "fi"), T("if x; then", "  # note", "  echo a", "fi"))
shell("same", "blank lines", T("echo a", "echo b"), T("echo a", "", "", "echo b", ""))
shell("same", "trailing blanks of a code line", T("echo a", "echo b"), T("echo a  ", "echo b\t"))
shell("same", "a shellcheck directive is a comment", T("# shellcheck disable=SC2086", "echo $x"), T("echo $x"))
shell("same", "a comment between a function and its caller", T("f() { :; }", "f"), T("f() { :; }", "# call it", "f"))
# ── shell: what is part of the program ───────────────────────────────────────────────────────────────────────────────
shell("diff", "the shebang", T("#!/bin/bash", "echo a"), T("#!/bin/sh", "echo a"))
shell("diff", "a code line", T("echo a"), T("echo b"))
shell("diff", "a #! line is kept wherever it is", T("echo a", "#!/bin/sh", "echo b"), T("echo a", "echo b"))
shell("diff", "a trailing comment belongs to its line", T("echo a # one"), T("echo a # two"))
shell("diff", "a carriage return is not a blank", "echo a\r\n", "echo a\n")
shell("same", "a CRLF comment line", "echo a\r\n# c\r\n", "echo a\r\n")
# ── shell: here-documents are data until their terminator ───────────────────────────────────────────────────────────
shell("diff", "a # line inside a here-document", T("cat <<'EOF'", "# body v1", "EOF"), T("cat <<'EOF'", "# body v2", "EOF"))
shell("diff", "trailing blanks inside a here-document", T("cat <<EOF", "payload  ", "EOF"), T("cat <<EOF", "payload", "EOF"))
shell("diff", "a blank line inside a here-document", T("cat <<EOF", "a", "", "b", "EOF"), T("cat <<EOF", "a", "b", "EOF"))
shell("same", "a comment after the terminator", T("cat <<EOF", "x", "EOF", "# n v1", "echo z"), T("cat <<EOF", "x", "EOF", "# n v2", "echo z"))
shell("same", "<<- ends at a tab-indented terminator", T("cat <<-EOT", "\tbody", "\tEOT", "# n v1"), T("cat <<-EOT", "\tbody", "\tEOT", "# n v2"))
shell("same", "a quoted delimiter with a blank", T('cat <<"END OF"', "body", "END OF", "# n v1"), T('cat <<"END OF"', "body", "END OF", "# n v2"))
shell("same", "a backslash delimiter", T("cat <<\\BS", "body", "BS", "# n v1"), T("cat <<\\BS", "body", "BS", "# n v2"))
shell("same", "two here-documents on one line", T("cat <<ONE <<TWO", "one", "ONE", "two", "TWO", "# n v1"), T("cat <<ONE <<TWO", "one", "ONE", "two", "TWO", "# n v2"))
shell("same", "a here-string starts no here-document", T('read -r w <<< "x"', "# n v1", "echo $w"), T('read -r w <<< "x"', "# n v2", "echo $w"))
shell("diff", "an unterminated here-document keeps the rest as data", T("cat <<EOF", "# n v1"), T("cat <<EOF", "# n v2"))
shell("none", "a here-document inside $( ) inside double quotes runs past the line: nested quoting the scanner cannot follow", T('x="$(cat <<EOF', "# body v1", "EOF", ')"'))
shell("none", "so a comment after that here-document is no longer dropped either: the whole file is hashed as committed", T('x="$(cat <<EOF', "body", "EOF", ')"', "# n v1"))
# ── shell: a # line inside a multi-line string is data ───────────────────────────────────────────────────────────────
shell("diff", "a # line inside a multi-line single-quoted string", T("x='first", "# looks like a comment v1", "last'"), T("x='first", "# looks like a comment v2", "last'"))
shell("diff", "a # line inside a multi-line double-quoted string", T('x="first', "# v1", 'last"'), T('x="first', "# v2", 'last"'))
shell("diff", "a # line inside a multi-line $'...' string", T("x=$'first", "# v1", "last'"), T("x=$'first", "# v2", "last'"))
shell("diff", "trailing blanks inside a multi-line string", T("x='a  ", "b'"), T("x='a", "b'"))
shell("same", "comments are dropped again once the string is closed", T("x='a", "b'", "# n v1", "echo x"), T("x='a", "b'", "# n v2", "echo x"))
shell("same", "an apostrophe in a trailing comment opens nothing", T("echo hi # don't", "# n v1", "echo x"), T("echo hi # don't", "# n v2", "echo x"))
shell("same", "an escaped apostrophe opens nothing", T("echo it\\'s", "# n v1"), T("echo it\\'s", "# n v2"))
shell("same", "an apostrophe inside double quotes opens nothing", T('echo "it\'s"', "# n v1"), T('echo "it\'s"', "# n v2"))
shell("same", "$# ${#a[@]} ${x#p} start no comment", T('echo $# ${#a[@]} ${x#p}', "# n v1"), T('echo $# ${#a[@]} ${x#p}', "# n v2"))
shell("same", "a # inside double quotes starts no comment", T('echo "a # b\'s"', "# n v1"), T('echo "a # b\'s"', "# n v2"))
shell("same", "an escaped quote inside $'...' does not close it", T("x=$'it\\'s'", "# n v1"), T("x=$'it\\'s'", "# n v2"))
shell("same", "a quoted hash", T("echo '#'", "# n v1"), T("echo '#'", "# n v2"))
# ── shell: a backslash joins the next line, comment or blank included ───────────────────────────────────────────────
shell("diff", "a comment after a continuation is kept", T("echo a \\", "# n v1", "  b"), T("echo a \\", "# n v2", "  b"))
shell("diff", "a blank line after a continuation is kept", T("echo a \\", "", "echo b"), T("echo a \\", "echo b"))
shell("diff", "a blank after the backslash is not a continuation", T("echo a \\ ", "echo b"), T("echo a \\", "echo b"))
shell("same", "a comment after a comment that ends in a backslash", T("# note \\", "# n v1", "echo x"), T("# note \\", "# n v2", "echo x"))
shell("same", "a comment after a chain of continuations", T("cmd \\", "  --a \\", "  --b", "# n v1"), T("cmd \\", "  --a \\", "  --b", "# n v2"))
# ── shell: a script that prints its own header is its comments ──────────────────────────────────────────────────────
shell("none", "sed -n over $0", T("# usage: x", "usage() { sed -n '2,3p' \"$0\"; }"))
shell("none", "sed -n over a variable that holds $0", T('SELF="$0"', "usage() { sed -n '2,3p' \"$SELF\"; }"))
shell("none", "grep over ${BASH_SOURCE[0]}", T("grep '^#' \"${BASH_SOURCE[0]}\""))
shell("none", "head over a variable that holds readlink -f $0", T('me="$(readlink -f "$0")"', 'head -n 5 "$me"'))
shell("none", "a read loop fed from $0", T('while read -r l; do :; done < "$0"'))
shell("none", "dirname $0 and a reader in one file: whole-file, because the path of the script can reach the reader by many routes", T('cd "$(dirname "$0")" && cat x', "# n v1"))
shell("same", "$0 inside an awk program is a field", T("awk '{ print $0 }' f", "# n v1"), T("awk '{ print $0 }' f", "# n v2"))
shell("same", "$0 in a usage message", T('echo "usage: $0 [opts]"', "# n v1"), T('echo "usage: $0 [opts]"', "# n v2"))
shell("none", "${0##*/} and a reader in one file", T('echo "${0##*/}" | tr a b', "# n v1"))
shell("none", "the full path of the script built from dirname and basename, read through a variable", T('SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"', "usage() { sed -n '2,5p' \"$SELF\"; }"))
shell("none", "$0 in single quotes handed to eval is expanded by the shell", T("eval 'cat \"$0\"'"))
shell("same", "a reader and no reference to the script's own path", T("cat x | tr a b", "# n v1"), T("cat x | tr a b", "# n v2"))
# ── shell: quoting inside a construct nested in double quotes ───────────────────────────────────────────────────────
shell("none", "a command substitution inside double quotes that runs past the line", T('x="$(printf %s "a', "# inside the nested string", 'b")"', "echo done"))
shell("none", "a backslash inside a command substitution inside double quotes", T('x="$(printf %s \\"a\\")"', "# n v1", "echo $x"))
shell("none", "a backslash inside double quotes inside a command substitution inside double quotes", T('x="$(echo "a\\"b")"', "# n v1", "echo $x"))
shell("none", "an unclosed apostrophe inside a command substitution inside double quotes", T('x="$(echo it\'s)"', "# n v1", "echo $x"))
shell("none", "an unclosed apostrophe inside a backtick construct inside double quotes", T('x="`echo it\'s`"', "# n v1", "echo $x"))
shell("none", "a # inside a command substitution inside double quotes", T('x="$(echo a # note)"', "# n v1", "echo $x"))
shell("same", "a command substitution whose quotes pair up is followed exactly", T('x="$(printf \'%s\' "${V:-a}" | tr a b)"', "# n v1", "echo $x"), T('x="$(printf \'%s\' "${V:-a}" | tr a b)"', "# n v2", "echo $x"))
shell("same", "arithmetic with a number base inside double quotes", T('echo "$((10#$v))"', "# n v1"), T('echo "$((10#$v))"', "# n v2"))
shell("same", "a plain ${name} and $(date) inside double quotes", T('echo "${a} $(date)"', "# n v1"), T('echo "${a} $(date)"', "# n v2"))
# ── python ───────────────────────────────────────────────────────────────────────────────────────────────────────────
python("same", "a comment line", T("import os", "x = 1"), T("import os", "# note", "x = 1"))
python("same", "blank lines", T("import os", "x = 1"), T("import os", "", "", "x = 1", ""))
python("same", "trailing whitespace", T("import os", "x = 1"), T("import os  ", "x = 1\t"))
python("same", "a comment inside brackets", T("x = [1,", "     2]"), T("x = [1,", "     # two", "     2]"))
python("same", "a comment line at the left margin inside a block", T("if a:", "    b()", "# n v1", "    c()"), T("if a:", "    b()", "# n v2", "    c()"))
python("same", "a trailing comment", T("x = 1  # one"), T("x = 1  # two"))
python("same", "a type comment", T("x = []"), T("x = []  # type: list"))
python("diff", "a code line", T("x = 1"), T("x = 2"))
python("diff", "a docstring is visible at run time", T('"""doc v1"""', "x = 1"), T('"""doc v2"""', "x = 1"))
python("diff", "a # inside a string is the string", T('x = "# not a comment v1"'), T('x = "# not a comment v2"'))
python("diff", "the shebang", T("#!/usr/bin/env python3", "x = 1"), T("#!/usr/bin/python3", "x = 1"))
python("diff", "indentation", T("if a:", "    b()"), T("if a:", "  b()"))
python("diff", "an encoding cookie", T("x = 1"), T("# -*- coding: latin-1 -*-", "x = 1"))
python("none", "a string that is never closed cannot be tokenized", T('x = """never closed', "# inside"))
python("none", "a file that reads its own source", T("import inspect", "src = inspect.getsource(inspect)"))
python("none", "__file__ and open() anywhere in the file", T("import os", "p = os.path.abspath(__file__)", "text = open(p).read()"))
python("none", "sys.argv[0] and open()", T("import sys", "text = open(sys.argv[0]).read()"))
python("none", "__file__ and Path.read_text", T("import pathlib", "t = pathlib.Path(__file__).read_text()"))
python("same", "__file__ with no open or read is a path, not the text", T("import os", "d = os.path.dirname(__file__)", "# n v1"), T("import os", "d = os.path.dirname(__file__)", "# n v2"))
# ── which language a file is ─────────────────────────────────────────────────────────────────────────────────────────
language("bin/x", "#!/usr/bin/env bash\n", "shell")
language("bin/x", "#!/bin/sh\n", "shell")
language("bin/x", "#!/bin/zsh\n", "shell")
language("bin/x", "#!/usr/bin/env -S bash -e\n", "shell")
language("hooks/pre-push", "#!/bin/bash -e\n", "shell")
language("bin/x", "#!/usr/bin/env python3\n", "python")
language("bin/x", "#!/usr/bin/python3.11\n", "python")
language("bin/x", "#!/usr/bin/perl\n", None)
language("bin/x", "echo no shebang\n", None)
language("bin/x.sh", "", "shell")
language("bin/x.py", "", "python")
language("bin/x.js", "#!/bin/bash\n", None)
language("bin/x.v2", "#!/bin/bash\n", None)
# ── text a shell file only prints is no edge (drop_display_text: the text the edges are read from) ────────────────────
def display(kind, label, a, b):
    try:
        da, db = sc.drop_display_text(a), sc.drop_display_text(b)
    except Exception as exc:
        verdict(kind, "dsp: " + label, False, "%s: %s" % (type(exc).__name__, exc))
        return
    verdict(kind, "dsp: " + label, (da == db) if kind == "same" else (da != db), "got %r and %r" % (da, db))


display("same", "an echo message names a file", T('echo "see docs/a.md for more"'), T('echo "see docs/b.md for more"'))
display("same", "a printf message to stderr", T("printf '%s\\n' \"run bin/a to try\" >&2"), T("printf '%s\\n' \"run bin/b to try\" >&2"))
display("same", "the body of a bare cat here-document", T("cat <<'EOF'", "docs/a.md has the flags", "EOF"), T("cat <<'EOF'", "docs/b.md has the flags", "EOF"))
display("same", "a trailing comment", T("echo hi # see docs/a.md"), T("echo hi # see docs/b.md"))
display("diff", "an echo of a lone path is a value a function hands back", T('echo "docs/a.md"'), T('echo "docs/b.md"'))
display("diff", "an echo written to a file may be a generated script", T('echo "exec bin/a now" >> hook'), T('echo "exec bin/b now" >> hook'))
display("diff", "an echo piped on may be run", T('echo "run bin/a now" | sh'), T('echo "run bin/b now" | sh'))
display("diff", "an echo inside $( ) is captured", T('x="$(echo "see docs/a.md now")"'), T('x="$(echo "see docs/b.md now")"'))
display("diff", "an echo whose group is piped", T('{ echo "see docs/a.md now"; } | cat'), T('{ echo "see docs/b.md now"; } | cat'))
display("diff", "a message with a substitution inside it", T('echo "see $(cat docs/a.md) now"'), T('echo "see $(cat docs/b.md) now"'))
display("diff", "a here-document with a #! line is a script", T("cat > hook <<'EOF'", "#!/bin/sh", "bin/a --now", "EOF"), T("cat > hook <<'EOF'", "#!/bin/sh", "bin/b --now", "EOF"))
display("diff", "cat of a file reads it", T('cat "docs/a.md"'), T('cat "docs/b.md"'))
display("diff", "a file the lexer cannot read to its end drops nothing", T('echo "never closed docs/a.md'), T('echo "never closed docs/b.md'))
print("cases %d" % COUNT)
