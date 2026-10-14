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
