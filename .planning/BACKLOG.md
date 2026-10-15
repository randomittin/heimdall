# BACKLOG

## 2026-10-14: deferred out of hmd 2.4.8

- [ ] ship.sh commits/checks/pushes the site pins in the release step (the operator requires the site committed and pushed in the same step as the release).
- [ ] A full ship publishes npm from the tag export, not the working tree.
- [ ] Narrow the kill guard to commands that could hit hmd's own processes.
- [ ] The push gate still allows (with a warning) a heimdall checkout with no heimdall-state.
- [ ] An aggregate-only relay counter of phone binds per week (no session id, IP or GitHub id), plus a DATA.md and store-privacy update.
- [ ] 496 of 531 suites still use bare mktemp and can leak on kill (adopt test/lib/private-tmp.sh); measured 2026-10-14 as test/*.test.sh files containing mktemp and not private-tmp (the earlier estimate was about 300).
- [ ] The Claude Code security-review pip bootstrap leaks pip-unpack-* dirs (not ours; report upstream).
- [ ] The session-login Keychain save blocks the bind for up to 40 s when the Keychain stalls.
- [ ] Suites still reach `security` under a sandboxed HOME: companion-cc-login-e2e, heimdall-ui-send-on-change, relay-client-enospc-recovery, app-upgrade-paired.
- [ ] `_write_device_record` (bin/heimdall-relay-client) emits an error every 15 s instead of once per outage.
- [ ] The hmdapp INBOX_CONSUMERS needs `wake` (hmdapp's job).
- [ ] The GTM homepage, privacy-page and site-changelog updates listed in docs/GTM-2.4.x.md.
- [ ] A repo that declares checks (`.heimdall/repo-checks.json`) and tracks `.planning/metrics.jsonl` (the rally layout: an hmd-initialised yarn project) cannot keep a clean-tree receipt: hmd keeps appending to the tracked file, so `bin/heimdall-repo-checks run` sees a tracked change before or after the checks (`git status --porcelain --untracked-files=no`, no exemption for hmd-owned paths), records `dirty: true` and the push gate blocks; `test/heimdall-push-gate-per-repo.test.sh` F4 gets a green receipt only by committing the churn first. Decide whether hmd-owned paths count as clean for the receipt, or whether managed repos stop tracking `metrics.jsonl`.
- [ ] The push gate (`bin/heimdall-precheck-bash`, `GP_RE`) does not arm on 11 ways of typing a push found in review, among them `bash --norc -c '...'` (a long option or `-o name` before `-c`), unquoted `eval git push`, a here-string (`bash <<< '...'`), a script piped into a shell (`echo '...' | bash`), process substitution (`bash <(...)`) and a variable as the command word (`$GIT push`), each confirmed unmatched against the matcher on 2026-10-15; only the native pre-push hook (core.hooksPath), where it is wired, gates them. Decide whether to widen the matcher or fail closed on a shell run over non-literal input.
