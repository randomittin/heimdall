# PLAN — `hmd app connect`: Tailscale Funnel as the official remote path for the companion app

Status: DRAFT handoff from the hmdapp build session (2026-09-20, revised same day after the
operator ruled out any phone-side app). Run in a fresh `hmd` session inside
`/Users/rj/Downloads/heimdall`. Companion app: `/Users/rj/Downloads/hmdapp` (v0.2, currently
reaches hmd only over `adb reverse`).

## Why
`hmd ui` binds loopback (Decision 5). The relay (Decision 7 / Wave 5a) does not exist. The
operator's constraint: **no extra app on the phone**. Tailscale **Funnel** satisfies both:
the laptop-side `tailscale funnel` is a TLS-terminating reverse proxy that publishes a
loopback service at `https://<host>.<tailnet>.ts.net` to the public internet with a real
Let's Encrypt cert; the phone needs only a browser-grade HTTPS client. `hmd ui` keeps its
loopback bind; Funnel forwards to `127.0.0.1:<port>` on the same machine.

## Decisions (operator inputs, 2026-09-20)
- D1 Phone needs nothing installed beyond the companion app. Laptop-only dependency:
  Tailscale (CLI + daemon). `hmd app connect` installs it on first use with an explicit y/N
  consent prompt (macOS `brew install --cask tailscale`, fallback: download URL; Linux:
  official install script shown before running). Never silent.
- D2 Exposure model: Funnel makes the endpoint public. Auth stays the per-launch token
  (high-entropy, only in the printed URL). hmd adds: per-IP backoff on 401/403 (e.g. 5
  failures → 30 s), `/api/send` shares the same gate, and `hmd app connect` prints a clear
  "this URL is reachable from the internet; anyone with the token can read this session"
  warning + how to rotate (Ctrl-C and reconnect mints a new token).
- D3 `hmd ui` change is minimal: `--allow-host <name>` (repeatable) so the Funnel hostname
  passes the Host allowlist; the proxy sets `Host: <host>.<tailnet>.ts.net` (verify with a
  test that fakes the header). Bind stays 127.0.0.1. Also `--trust-proxy` so `X-Forwarded-*`
  from Funnel is used for the per-IP backoff (only when set).
- D4 Funnel constraints: public ports 443/8443/10000 only; HTTPS certs + `funnel` node
  attribute must be enabled in the tailnet admin (`tailscale funnel` prints the exact policy
  hint when missing — surface it verbatim). Path: `tailscale funnel --bg --https=443
  http://127.0.0.1:<hmd-port>` (or `tailscale serve … && tailscale funnel 443 on`, whichever
  the installed CLI version supports — detect via `tailscale funnel --help`).
- D5 Pairing payload unchanged: URL `https://<host>.<tailnet>.ts.net/?token=<token>` printed
  + ASCII QR (stdlib-only encoder). The app accepts `https` + `*.ts.net` hosts.

## Interface
```
hmd app connect [--repo DIR] [--port N] [--https-port 443|8443|10000] [--no-install]
    ensure tailscale (install w/ consent) → ensure `tailscale up` (login link) →
    start `hmd ui --no-open --port N --allow-host <ts.net name> --trust-proxy` →
    `tailscale funnel --bg …` → print public URL + QR + exposure warning → wait; Ctrl-C tears
    down funnel + ui
hmd app status          tailscale/funnel state, public URL (token redacted), 401 backoff hits
hmd app disconnect      `tailscale funnel … off` + stop the ui it started
hmd app doctor          checks: tailscale installed/logged in, HTTPS certs enabled, funnel
                        attribute granted, port allowed — prints the fix for each failure
```

## Waves (AI wall-clock, parallel agents)
- **Wave 1 (~40 min, 3 agents):**
  1.1 `sentinels/hmd-ui.py`: `--allow-host` (repeatable), `--trust-proxy`, per-IP 401/403
      backoff (in-memory, 5 → 30 s), `/api/state.transport = {"bind":"loopback",
      "public_host": <name>|null}`; tests in `test/heimdall-ui.test.sh` style (fake Host and
      X-Forwarded-For headers).
  1.2 `bin/lib/hmd_qr.py`: stdlib QR encoder (byte mode, ECC L, v1–10) + ASCII render;
      golden matrix fixture test.
  1.3 `bin/lib/hmd_tailscale.sh`: detect CLI (`command -v tailscale`,
      `/Applications/Tailscale.app/Contents/MacOS/Tailscale`), `status --json` (Self.Online,
      DNSName), `funnel` capability probe, install prompt; tests with a fake `tailscale`.
- **Wave 2 (~30 min, 1 agent, depends on 1):** `bin/heimdall-app` (`connect|status|
  disconnect|doctor`) + `bin/hmd` dispatch + help + teardown trap; e2e test with fake
  tailscale + real loopback hmd-ui + a fake Host header.
- **Wave 3 (~20 min, 1 agent, hmdapp repo):** pairing accepts `https://*.ts.net` (keep
  loopback-only for plain http); "public" badge on session header/profile with the hostname;
  README remote section.
- **Wave 4 (verify):** pinned-opus verifier over suites; manual: `hmd app connect` on the
  laptop, phone on mobile data (Wi-Fi off), scan → telemetry, panels, chat, send all work.

## Acceptance (runnable)
- New/updated suites green: `test/heimdall-ui.test.sh`, `test/heimdall-ui-allowhost.test.sh`,
  `test/hmd-qr.test.sh`, `test/hmd-tailscale.test.sh`, `test/heimdall-app.test.sh`; zero deps.
- `curl -H 'Host: demo.tail1234.ts.net' http://127.0.0.1:<p>/api/state?token=…` → 200 when
  `--allow-host demo.tail1234.ts.net`; → 403 without it; 6 bad tokens from one IP → 429.
- `hmd app connect --no-install` with fake tailscale prints `https://…ts.net/?token=` + QR.
- Companion app pairs with that URL from the phone on mobile data (no adb, no phone app).

## Risks
- Tailnet admin must enable HTTPS certs + Funnel (`hmd app doctor` names the exact toggle).
- Public exposure: mitigated by token + backoff + warning; rotate by reconnecting. Consider a
  short-lived pairing code exchange later (Decision 7 V2) if this proves insufficient.
- Funnel port set is fixed (443/8443/10000); the ui's own port is free.

## Handoff from the hmdapp session (2026-09-20) — land these FIRST
Two hmd:coder agents were dispatched from the hmdapp session into worktrees under
`/Users/rj/Downloads/heimdall/.claude/worktrees/` (`git worktree list`):
- `feat(ui): POST /api/send inbox for companion → session messages` — `sentinels/hmd-ui.py`,
  `bin/lib/companion_ui_inbox.py`, `bin/heimdall-ui` (`inbox` subcommand), `test/heimdall-ui-inbox.test.sh`.
- `feat(inbox): deliver companion messages into the session (Stop-hook long-poll, tmux, prompt
  fallback)` — `bin/heimdall-inbox-deliver`, `test/heimdall-inbox-deliver.test.sh`.
Land: `git checkout <branch> -- <paths>` on main, run their suites + `test/heimdall-ui*.test.sh`, commit.

### Contract the companion app codes against (do not change without updating hmdapp `src/transport/send.ts`)
`POST /api/send?token=<t>` · `Content-Type: application/json` · body `{"text": string}` (≤2000 chars, body ≤4096 B)
→ 202 `{"id": <uuid>, "queued": <n pending>}` · 400 bad JSON · 401 bad token · 403 Host · 404 (older hmd: app falls back to clipboard)
· 413 body too large · 415 content-type · 422 `{"error": "secret-shaped" | "empty" | "too-long"}`.
Inbox: `<repo>/.heimdall/ui/inbox.jsonl` lines `{id, ts, text, source:"companion"}`; delivered log `inbox-delivered.jsonl`;
`/api/state.inbox = {"pending": n}` (additive). Delivery: `bin/heimdall-inbox-deliver stop|tmux|prompt|status`
(Stop hook returns `{"decision":"block","reason":<text>}`; long-polls up to `HMD_INBOX_WAIT_S`=240 when the last
assistant message ends in `?`; write `.heimdall/ui/inbox-state.json {"waiting":bool,"since":ts}`).
hmdapp wires the hooks in its own `.claude/settings.json` (Stop timeout 300, UserPromptSubmit).

#### Status of the two in-flight worktrees (updated as they report)
- inbox delivery: DONE — branch `worktree-agent-a9811a5ba5c63e102` @ `d316724d`; `bin/heimdall-inbox-deliver` + `test/heimdall-inbox-deliver.test.sh` (36/36). Uses an inline flock+JSONL inbox reader; switch to `bin/lib/companion_ui_inbox.py` once the `/api/send` branch lands (same file protocol).
- `/api/send` inbox: DONE — branch `worktree-agent-a751777a88da442df` @ `2ac71267`; `sentinels/hmd-ui.py`, `bin/lib/companion_ui_inbox.py`, `bin/heimdall-ui` (`inbox ls|pop|peek`), `test/heimdall-ui-inbox.test.sh` (27/27; existing ui suites 30/30 + 57/57). Contract implemented exactly as listed above.
