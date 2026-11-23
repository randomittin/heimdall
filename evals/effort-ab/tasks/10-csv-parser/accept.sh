#!/usr/bin/env bash
# Hidden acceptance for 10-csv-parser. cwd = the agent's workdir.
set -u
: "${ACCEPT_DIR:?ACCEPT_DIR must be the absolute path of the task directory}"

[ -f csvparse.py ] || { echo "FAIL: csvparse.py missing in $PWD" >&2; exit 1; }

# The task forbids the stdlib csv module: static scan of the source (imports,
# from-imports, and the string "csv"/"_csv" used for dynamic imports).
python3 - <<'PY' || exit 1
import ast
import sys

with open("csvparse.py", encoding="utf-8") as handle:
    tree = ast.parse(handle.read(), "csvparse.py")
forbidden = ("csv", "_csv")
found = []
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        found += [a.name for a in node.names if a.name.split(".")[0] in forbidden]
    elif isinstance(node, ast.ImportFrom):
        if (node.module or "").split(".")[0] in forbidden:
            found.append(node.module)
    elif isinstance(node, ast.Constant) and node.value in forbidden:
        found.append(repr(node.value))
if found:
    print("FAIL: csvparse.py must not use the csv module:", found, file=sys.stderr)
    sys.exit(1)
PY

# Runtime scan: importing csvparse must not pull the csv module in by any route.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" python3 -c '
import sys
already = "csv" in sys.modules or "_csv" in sys.modules
import csvparse
if not already and ("csv" in sys.modules or "_csv" in sys.modules):
    sys.stderr.write("FAIL: importing csvparse loads the csv module\n")
    sys.exit(1)
' || exit 1

# 8 s hard cap so a hung solution cannot stall the runner (perl alarm survives exec).
limited() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 8 "$@"
  else
    "$@"
  fi
}

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" limited python3 "$ACCEPT_DIR/hidden_test.py"
