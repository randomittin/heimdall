# companion-ui-panels fixtures

Planted panel files for `test/heimdall-ui-panels.test.sh` (PLAN-companion-ui.md
Wave 4, L722). Each file is a COMPLETE panel descriptor as a job would write it
straight into `<repo>/.heimdall/ui/panels/<id>.json` -- the trust boundary
Decision 6 names (L426-429: "a malicious or merely confused agent can write ANY
bytes ... the file is data, not code").

- `valid-timeseries.json`     accepted; served in `/api/state.panels[]`
- `valid-markdown-xss.json`   accepted; `data.text` carries `<script>alert(1)</script>`
                              (PLAN L730) -- must round-trip as DATA and never
                              appear in the served HTML
- `invalid-type-chart3d.json` dropped: `type` outside the closed set (L299-301)
- `invalid-source-key.json`   dropped: a top-level `source` key (L343-355); its
                              command must NEVER run (it would create a canary
                              file the test checks for)
- `invalid-no-updated-at.json` dropped: `updated_at` is required (L370-371)
- `invalid-not-json.txt`      dropped: unparsable; the server must stay alive

Secret-shaped and oversize payloads are assembled at RUNTIME by the script,
never planted here: `.gitleaks.toml` flags credential-shaped literals in any
tracked file, correctly, and a 201-row / 80 KB blob is generated in one line.
The test's `updated_at` in the valid fixtures is rewritten to `now` before
planting so the 24h TTL (L399-404) never reaps them mid-run.
