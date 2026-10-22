# State — 2026-10-23

- **Phase:** idle — released 2.4.10 everywhere; awaiting operator GTM review.
- **Done:** 2.4.8 (2be30a44), 2.4.9 (3afb282d), 2.4.10 (1a3f80e6); release-loop enforcement (d9c006a9, e82a7a72, 1604cf84); /hmd:continue; SessionEnd hooks detached.
- **In progress:** none.
- **Next:** (1) GTM review of docs/GTM-2.4.x.md [operator, hard gate]; (2) ship.sh commits site page pins itself; (3) 3.x M1 skill registry (no behaviour change, no release before GTM review); (4) .planning/BACKLOG.md.
- **Blockers:** GTM review gates any new version.
- **Decisions:** one review per release, only BLOCKER/HIGH block, MEDIUM/LOW→backlog, one sweep last, --failed after red (enforced by hooks + heimdall-findings); pairing default-ON with gh token only to built-in/approved relay; operator opt-out read from real ~/.heimdall.
- **Key files:** test/run-all.sh, bin/lib/suite_closure.py, release/ship.sh, hooks/hooks.json, bin/heimdall-app, bin/lib/hmd_pair_optin.py, bin/lib/hmd_relay_approval.py, bin/lib/hmd_nofollow_write.py, bin/lib/hmd_sweep_guard.py, bin/heimdall-findings, bin/heimdall-continue, CLAUDE.md.
