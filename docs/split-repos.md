# Split repos: hmd-skills and hmd-statusline

Heimdall's skills and statusline renderer are moving into their own repositories, `hmd-skills` and `hmd-statusline`. Development moves there. Heimdall keeps a copy of every moved file at the same path, pinned to a tag, so what a user runs does not change. This page says what moved, how heimdall consumes the copy, how to bump and roll back a pin, and how the operator publishes the two repos.

The decisions and the measured inventory are in `docs/superpowers/plans/2026-11-22-split-skills-statusline-repos.md`. The host side of each contract is in `docs/split/HOST-CONTRACT-skills.md` and `docs/split/HOST-CONTRACT-statusline.md`.

## What moved

| Repo | Moved | Files |
|---|---|---|
| `hmd-skills` | `skills/stacks`, `skills/designmatch`, `skills/self-improve`, `skills/system-health`, `skills/mac-deep-clean` | 21 |
| `hmd-statusline` | the statusline renderer and its parts (below), `conformance/statusline/`, and the test suites that call only the renderer | 18 runtime files, 26 conformance files, plus suites |

The statusline runtime files are:

- Hooks: `hooks/statusline.sh`, `hooks/subagent-statusline.sh`.
- Entry points: `bin/heimdall-statusline`, `bin/heimdall-statusline-register`, `bin/heimdall-statusline-register-cursor`, `bin/heimdall-sigil`, `bin/heimdall-sigil-png`.
- Renderer modules in `sentinels/`: `hmd-statusline.py`, `hmd_sigil.py`, `hmd_gauge.py`, `hmd_sigil_png.py`, `subagent-statusline.py`, `hmd-subagent-statusline.sh`, `hmd-sigil.py`, `hmd_layout.py`, `hmd_termcaps.py`, `hmd_ledger.py`, `hmd_wall.py`.

### What stays in heimdall

- `skills/heimdall/`, the orchestrator skill. Agents and hooks read its references by path.
- The skill registry: `skills.manifest.json`, `bin/heimdall-skills`, `bin/lib/skills_*.py`, `bin/skill-manager`.
- The helpers the moved skills call: `bin/designmatch`, `bin/heimdall-self-improve`, `bin/heimdall-sysmon`, `bin/heimdall-cleanup`, `bin/stack-pack`, `bin/stack-detect`.
- The statusline's host side, which the renderer calls by path: `bin/heimdall-identity`, `bin/heimdall-presence`, `bin/heimdall-tier`, `bin/heimdall-agents`, `bin/heimdall-ctx-meter`, `bin/heimdall-face`, and the ledger writer `bin/heimdall-status-json`.
- The statusline suites that need the host. They stay in heimdall as integration tests.

Every moved file keeps its path, so host code that reaches one by path (`bin/heimdall-board`, `bin/summary-card`, and `sentinels/hmd-banner.sh` loading `sentinels/hmd_sigil.py`) needed no edit.

## How heimdall consumes them

Each moved file is in heimdall at the same relative path as in its repo, with the same bytes and the same executable bit as the pinned tag. The new repos keep heimdall's layout (`skills/<id>/...`, `hooks/`, `bin/`, `sentinels/`, `conformance/statusline/`), so the copy is path for path with no renames.

The pin is `vendor/vendor.lock.json`, strict JSON with one entry per repo:

```json
{"schema": 1, "repos": [{"name": "hmd-skills", "repo": "git@github.com:randomittin/hmd-skills.git", "tag": "v1.0.0", "commit": "<40 hex>", "tree_sha256": "<64 hex>", "paths": ["skills/stacks/SKILL.md"]}]}
```

- `repo`: where the tag is fetched from, a URL or a local path.
- `tag` and `commit`: the tag, and the commit it must resolve to.
- `tree_sha256`: the hash of the mirrored files. `bin/heimdall-vendor --help` gives the exact recipe.
- `paths`: the mirrored files.

A person edits the lock, in a commit. The tool only reads it.

`bin/heimdall-vendor` is a launcher for `bin/lib/vendor_lock.py` (Python standard library only). `NAME` is `hmd-skills` or `hmd-statusline`.

| Command | What it does |
|---|---|
| `bin/heimdall-vendor verify NAME` or `verify --all` | Recomputes `tree_sha256` over the mirror, offline. Fails on any difference: an edited or missing mirrored file, or a lock whose hash no longer matches the files. |
| `bin/heimdall-vendor verify --all --upstream` | Also fetches each tag and requires it to resolve to the locked commit and hash to the locked tree. Fails if a tag has moved. |
| `bin/heimdall-vendor sync NAME` or `sync --all` | Fetches the tag and writes its files into the mirror, atomically. Refuses, writing nothing, unless the tag's commit and tree hash are the lock's. A second sync changes nothing. |
| `bin/heimdall-vendor diff NAME` or `diff --all` | Fetches the tag and shows a unified diff for each changed text file, plus the tag's commit and tree hash when they differ from the lock's. |

`--source SRC` (with one NAME, not `--all`) fetches from a URL or a local clone instead of the lock's `repo`. Use it before a repo is published. Exit status: 0 ok; 1 a difference, a refusal, a failed fetch, or a missing or invalid lock; 2 bad usage.

Drift is a failure by design. A direct edit to a mirrored file in heimdall makes `verify` fail. Make the change in the new repo, then bump the pin.

The first step of the split adds no network access at install or render time, and the statusline stays bundled. Claude Code's `settings.json` and Cursor's config point at `hooks/statusline.sh`, `hooks/subagent-statusline.sh` and `bin/heimdall-statusline`, so those paths never move.

## Bump a pin

Example: `hmd-skills` from `v1.0.0` to `v1.1.0`.

1. In the new repo, commit the change, then tag it and push the tag:
   ```bash
   cd /Users/rj/Downloads/hmd-skills
   git tag -a v1.1.0 -m "hmd-skills 1.1.0" && git push origin v1.1.0
   ```
2. In heimdall, set that repo's `tag` to `v1.1.0` in `vendor/vendor.lock.json`. Leave `commit` and `tree_sha256` as they are, then read the values the new tag has:
   ```bash
   cd /Users/rj/Downloads/heimdall
   bin/heimdall-vendor diff hmd-skills
   ```
   Copy the printed commit into `commit` and the printed tree hash into `tree_sha256`. Update `paths` if the file list changed.
3. Write the files, then check them:
   ```bash
   bin/heimdall-vendor sync hmd-skills
   bin/heimdall-vendor verify --all
   ```
   A refused `sync` means the lock and the tag disagree. Fix the lock, never the mirror.
4. Commit the lock and the mirrored files together, staging them by path, for example `chore(vendor): bump hmd-skills to v1.1.0`.

Until a repo is published, pass `--source /Users/rj/Downloads/hmd-skills` to `diff` and `sync` (both take one NAME).

## Roll back

Rolling back reverts the lock. The old tag must still resolve to the locked commit: tags are not moved, and `sync` refuses when they disagree.

```bash
cd /Users/rj/Downloads/heimdall
git checkout <sha-before-the-bump> -- vendor/vendor.lock.json
bin/heimdall-vendor sync hmd-skills
bin/heimdall-vendor verify --all
```

Commit the restored lock and the mirrored files, staging them by path. If the bump was a single commit, `git revert <bump-sha>` restores the lock and the mirror together and is simpler. A path that the bump dropped from the lock is not deleted by `sync`; remove it by hand.

## Publish (operator only)

Agents never publish. These steps belong to the operator, in this order.

1. Scan each repo's full history before it is pushed, because the history becomes public:
   ```bash
   gitleaks detect --source /Users/rj/Downloads/hmd-skills --no-banner
   gitleaks detect --source /Users/rj/Downloads/hmd-statusline --no-banner
   ```
   Both must exit 0. `bin/heimdall-selfscan`, run inside the repo, is the in-house alternative.
2. Commit `vendor/vendor.lock.json` in heimdall first. `bin/heimdall-vendor verify --all` must exit 0 on that commit.
3. Create each repo on GitHub from its local copy, then tag `v1.0.0` on the commit the lock pins:
   ```bash
   gh repo create randomittin/hmd-skills --public --source=/Users/rj/Downloads/hmd-skills --push
   cd /Users/rj/Downloads/hmd-skills && git tag -a v1.0.0 -m "hmd-skills 1.0.0" && git push origin v1.0.0

   gh repo create randomittin/hmd-statusline --public --source=/Users/rj/Downloads/hmd-statusline --push
   cd /Users/rj/Downloads/hmd-statusline && git tag -a v1.0.0 -m "hmd-statusline 1.0.0" && git push origin v1.0.0
   ```
4. Confirm the published tags match the lock:
   ```bash
   cd /Users/rj/Downloads/heimdall && bin/heimdall-vendor verify --all --upstream
   ```
   Exit 0 means each tag resolves to the locked commit and hashes to the locked tree. Exit 1 prints one line per mismatch.

The first step of the split changes no path. A runtime fetch of the skills pack and removal of the bundled copies are later phases and are not part of this procedure.
