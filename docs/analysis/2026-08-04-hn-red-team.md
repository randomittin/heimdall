# HN Red Team — 2026-08-04 (IN PROGRESS)

Confirmed so far:
- Site publishes isolation oracle `6/6` next to the command that prints `23/23`.
- README + site never mention Headroom (default_included, consent_waived traffic proxy).
- Site hero CTA is `curl | bash` with no digest check.
- `hmd modules add` verifies no digest for upstream modules.

Full writeup pending.
