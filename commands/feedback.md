---
name: feedback
description: Submit team feedback as a GitHub issue on the repo, straight from an hmd session. Use when a team dev wants to flag friction, request a change, or report something about the team flow. Files the dev's words + minimal context (hmd version, optional command/phase) via the existing issue-loop GitHub connector — NO session content, code, or secrets. Labels it `feedback`/`from-hmd` so it's filterable, and returns "filed as issue #N" with the URL.
---

# /hmd:feedback — File Team Feedback as a GitHub Issue

Use when a team dev wants to send feedback (friction, a request, a note on the
team flow). It raises a GitHub issue on the repo carrying the dev's words plus a
tiny context footer — nothing from the session, the codebase, or the environment.

## Process

1. **Take the dev's message verbatim.** Their words are the feedback. Do NOT
   paraphrase, expand with session details, or attach transcript/code. If the
   message is empty, ask once for it; otherwise proceed.

2. **Run the CLI** — it does the work (connector auth, secret-scan, labeling):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-feedback" "<the dev's message>"
   ```

   Optional minimal context (only if obviously relevant — never invent it):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/heimdall-feedback" "<message>" \
     --command "<hmd command in play>" --phase "<phase in play>"
   ```

   The CLI reuses the issue-loop's GitHub plumbing
   (`bin/lib/issue_config.py` for config + credential resolution and
   `bin/lib/connectors/github.py` for the POST). It auto-applies the `feedback`
   and `from-hmd` labels and appends only the hmd version (from `plugin.json`)
   plus any `--command`/`--phase` you pass.

3. **Relay the result.** On success the CLI prints `filed as issue #N` and the
   URL on the next line — pass both to the dev as one line: `Filed: <URL>`.

4. **On failure, surface the exact error** (don't retry blindly):
   - exit 1 `github connector is not configured` → the repo's
     `.heimdall/issue-loop.config.json` needs a `connectors.github` block
     (`repo` + `token_env`); see `.heimdall/issue-loop.config.json.example`.
   - exit 1 `no credential` → the named `token_env` env var isn't exported.
   - exit 5 `refused — ... credential` → the message contained a secret shape;
     tell the dev to strip the secret and resubmit. Do NOT work around this.

## Constraints

- **No-secret discipline.** Feedback is the dev's words ONLY. Never include
  session content, code snippets, file paths, stack traces, or secrets in the
  message. The CLI scans for credential shapes and refuses if it finds one —
  treat that refusal as correct, never bypass it.
- Files against the **repo's** issue tracker (the `connectors.github.repo` from
  the issue-loop config) — not necessarily the plugin repo. For bugs in Heimdall
  itself, use `/hmd:report-bug` instead.
- The CLI is mockable: `--dry-run` prints the JSON payload (title/body/labels)
  without filing — used by `test/feedback.test.sh`.

## Examples

Dev: "the merge gate is too slow when three of us land at once"
→ `heimdall-feedback "the merge gate is too slow when three of us land at once"`
→ Filed: https://github.com/owner/repo/issues/42

Dev: "branch push prompted me for permission — it shouldn't, it's reversible"
→ `heimdall-feedback "branch push prompted me for permission — it shouldn't, it's reversible" --phase land`
→ Filed: https://github.com/owner/repo/issues/43
