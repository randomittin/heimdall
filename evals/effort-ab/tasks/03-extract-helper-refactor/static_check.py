"""Static checks for 03-extract-helper-refactor.  Run with cwd = the agent's workdir.

Stage tests-unchanged: every file under tests/ is byte-identical to the seed
    (manifest: $ACCEPT_DIR/tests.sha256; __pycache__ and *.pyc are ignored).
Stage refactor-static: the validation message literal exists exactly once in
    orders.py (docstrings and comments do not count), it lives in -- or is used
    by -- exactly one module-level helper function, and that helper is called
    from at least three distinct places.  The helper's name is not hardcoded.

Prints one STAGE line per stage; exit 0 only if both pass.
"""
import ast
import hashlib
import os
import sys

MESSAGE = "must be a positive integer"
MIN_CALL_SITES = 3
PUBLIC_FUNCTIONS = {"create_order", "update_quantity", "split_order"}


def sha256_of(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def read_manifest(path):
    manifest = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                digest, relpath = line.split(None, 1)
                manifest[relpath.strip()] = digest
    return manifest


def snapshot_tests(root="tests"):
    snapshot = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name != "__pycache__"]
        for name in filenames:
            if not name.endswith(".pyc"):
                path = os.path.join(dirpath, name)
                snapshot[path.replace(os.sep, "/")] = sha256_of(path)
    return snapshot


def check_tests_unchanged(manifest_path):
    if not os.path.isdir("tests"):
        return "tests/ directory is missing"
    want = read_manifest(manifest_path)
    got = snapshot_tests()
    problems = []
    for path in sorted(set(want) | set(got)):
        if path not in got:
            problems.append(f"missing {path}")
        elif path not in want:
            problems.append(f"added {path}")
        elif want[path] != got[path]:
            problems.append(f"modified {path}")
    return "; ".join(problems) or None


def docstring_nodes(tree):
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.body:
            first = node.body[0]
            if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                    and isinstance(first.value.value, str)):
                found.add(id(first.value))
    return found


def check_refactor(source_path="orders.py"):
    try:
        with open(source_path, encoding="utf-8") as handle:
            tree = ast.parse(handle.read(), filename=source_path)
    except (OSError, SyntaxError) as error:
        return f"cannot parse {source_path}: {error}"

    docstrings = docstring_nodes(tree)
    literals = [
        node for node in ast.walk(tree)
        if isinstance(node, ast.Constant) and isinstance(node.value, str)
        and MESSAGE in node.value and id(node) not in docstrings
    ]
    if len(literals) != 1:
        return (f"the validation message literal must appear exactly once in {source_path}, "
                f"found {len(literals)}")

    parents = {}
    for parent in ast.walk(tree):
        for child in ast.iter_child_nodes(parent):
            parents[child] = parent

    def ancestors(node):
        while node in parents:
            node = parents[node]
            yield node

    def module_level_function(node):
        """The module-level def containing ``node``, or None."""
        found = None
        for ancestor in ancestors(node):
            if (isinstance(ancestor, (ast.FunctionDef, ast.AsyncFunctionDef))
                    and isinstance(parents.get(ancestor), ast.Module)):
                found = ancestor
        return found

    literal = literals[0]
    helper = module_level_function(literal)
    if helper is None:
        owner = parents.get(literal)
        constant_name = None
        if (isinstance(owner, ast.Assign) and isinstance(parents.get(owner), ast.Module)
                and len(owner.targets) == 1 and isinstance(owner.targets[0], ast.Name)):
            constant_name = owner.targets[0].id
        elif (isinstance(owner, ast.AnnAssign) and isinstance(parents.get(owner), ast.Module)
                and isinstance(owner.target, ast.Name)):
            constant_name = owner.target.id
        if constant_name is None:
            return ("the message must live in a module-level helper function "
                    "(or in a module-level constant used by exactly one such helper)")
        users = {
            module_level_function(node) for node in ast.walk(tree)
            if isinstance(node, ast.Name) and node.id == constant_name and isinstance(node.ctx, ast.Load)
        }
        if len(users) != 1 or None in users:
            return f"the message constant {constant_name} must be used by exactly one module-level helper function"
        helper = users.pop()

    if helper.name in PUBLIC_FUNCTIONS:
        return f"the validation helper must be a separate function, not {helper.name}()"

    call_sites = sum(
        1 for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == helper.name
        and helper not in ancestors(node)
    )
    if call_sites < MIN_CALL_SITES:
        return (f"helper {helper.name}() is called from {call_sites} place(s) outside itself, "
                f"expected at least {MIN_CALL_SITES}")
    return None


def main():
    manifest_path = os.path.join(os.environ["ACCEPT_DIR"], "tests.sha256")
    failed = False
    for label, problem in (
        ("tests-unchanged", check_tests_unchanged(manifest_path)),
        ("refactor-static", check_refactor()),
    ):
        if problem:
            print(f"STAGE {label}: FAIL - {problem}")
            failed = True
        else:
            print(f"STAGE {label}: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
