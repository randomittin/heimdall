"""Driver for the gitdiff adapter: feed it the fixture's change through each of its three sources."""


def variants(fixture):
    base = {
        "id": "conformance-1",
        "prompt": "conformance: edit NOTES.md and src/app.mjs, add src/new.txt, delete old.txt, make run.sh executable",
        "repo": fixture.repo,
        "base_sha": fixture.base_sha,
    }
    return [
        ("patch", dict(base, options={"gitdiff": {"patch": fixture.diff}})),
        ("patch_file", dict(base, options={"gitdiff": {"patch_file": fixture.patch_path}})),
        ("head", dict(base, options={"gitdiff": {"head": fixture.head_sha}})),
    ]
