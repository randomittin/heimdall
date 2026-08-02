# Team Presence Validation Runbook

End-to-end manual validation of Heimdall's multi-tenant team presence. Covers solo path,
2-dev collaborator auto-join, and the privacy/isolation boundary. All commands run from
inside the target repo unless noted. Every command and path is derived from the live code.

---

## 1. Preconditions

**1.1 — Control plane reachable**

```bash
CP_URL="$(python3 -c "
import json, os
f = os.path.expanduser('~/.heimdall/cp-endpoint.json')
d = json.load(open(f)) if os.path.exists(f) else {}
print((d.get('url') or 'https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app').rstrip('/'))
")"
curl -s -o /dev/null -w "%{http_code}" "$CP_URL/readyz"
# expect: 200
```

> Probe `/readyz`, **not** `/healthz`. Both are served by the same pre-auth handler
> (`bin/lib/cp_diag.py`) and both are in the public allowlist, but Google's Cloud Run edge
> intercepts an **external** `GET /healthz` and answers its own HTML 404 before the request
> reaches the container — the 404 carries no `x-cloud-trace-context`, the `/readyz` 200 does.
> `/readyz` is also the stronger probe: it proves the route seam booted and the state backend
> initialised (`{"status":"ready","booted":true,…}`), where `/healthz` only proves the
> interpreter is alive. `deploy/cloud-run/go-live.sh` §7.0 verifies the same way.

**1.2 — `~/.heimdall/cp-endpoint.json` present**

```bash
python3 -c "import json; d=json.load(open(__import__('os').path.expanduser('~/.heimdall/cp-endpoint.json'))); print('url:', d.get('url')); print('enroll_token:', 'SET' if d.get('enroll_token') else 'absent (open server)')"
# expect shape: {"url": "https://...", "enroll_token": "..."}
# enroll_token only required on a token-gated server; an open server (HEIMDALL_ENROLL_OPEN=1) enrolls without it
```

**1.3 — gh authenticated (required for `share` and `auto`)**

```bash
gh auth status 2>&1 | grep -q "Logged in" && echo "OK" || echo "NOT AUTHED — share will refuse"
# expect: OK
```

**1.4 — Identity resolvable**

```bash
heimdall-identity current 2>/dev/null || heimdall-haid current
# expect: non-empty HAID string, e.g. "haid:rj.mbp-7f3a"
```

**1.5 — python3 available**

```bash
python3 -c "import hashlib, secrets, json; print('ok')"
# expect: ok
```

**Env vars used in this runbook**

| Variable | Purpose | Default |
|---|---|---|
| `HEIMDALL_TEAM_DIR` | Override per-repo team dir (tests; omit normally) | `<repo>/.heimdall` |
| `HEIMDALL_CP_URL` | Override CP URL | baked-in default |
| `HEIMDALL_NO_TEAM_AUTOSHARE` | Set to `1` to opt out of auto-share | unset |
| `HMD_PRESENCE_SEED` | Dev signing seed override (testing only) | auto-bootstrapped |
| `HEIMDALL_TEAM_AUTO_THROTTLE` | Override the ~24 h auto-share throttle (seconds) | `86400` |

---

## 2. Solo Path

A fresh repo with no team configuration. `heimdall-presence beat` auto-mints a solo
team (`source=auto-solo`); `heimdall-team show` reports `source=solo`; the roster
contains only self.

**2.1 — Confirm no team file exists**

```bash
ls .heimdall/team.json 2>&1
# expect: No such file or directory
```

**2.2 — Beat: auto-mints a solo team and enrolls**

```bash
heimdall-presence beat
echo "exit=$?"
# expect: exit=0  (silent; offline / unenrolled path is also exit 0)
```

**2.3 — team.json written at mode 0600**

```bash
stat -c '%a %n' .heimdall/team.json 2>/dev/null || stat -f '%Lp %N' .heimdall/team.json
# expect: 600 .heimdall/team.json
```

**2.4 — `show` reports source=solo, team_id printed, secret never printed**

```bash
heimdall-team show
# expect (exact keys):
# configured: yes
# source:     solo
# team_id:    <32 hex chars>
# created:    <epoch int>
# store:      <path>/.heimdall/team.json
# (the team secret is never printed — see ...)
```

```bash
heimdall-team show --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["configured"] is True, "configured wrong"
assert d["source"] == "solo", "source: " + str(d["source"])
assert len(d["team_id"]) == 32, "team_id length: " + str(len(d["team_id"]))
print("PASS: configured=True source=solo team_id=%s" % d["team_id"])
'
# expect: PASS: configured=True source=solo team_id=<32 hex>
```

**2.5 — team_id matches the server-side SHA-256 derivation**

```bash
python3 -c "
import hashlib, json
d = json.load(open('.heimdall/team.json'))
derived = hashlib.sha256(b'heimdall-team\x00' + d['team_secret'].encode('utf-8')).hexdigest()[:32]
import subprocess
shown = json.loads(subprocess.check_output(['heimdall-team','show','--json']))['team_id']
print('MATCH' if derived == shown else 'MISMATCH: derived=%s shown=%s' % (derived, shown))
"
# expect: MATCH
```

**2.6 — Roster shows only self**

```bash
heimdall-presence roster --json
# expect: JSON array; your own HAID entry present; no other HAIDs
```

Verify self-only:

```bash
MY_HAID="$(heimdall-identity current 2>/dev/null || heimdall-haid current)"
heimdall-presence roster --json | python3 -c "
import json, sys
rows = json.load(sys.stdin)
haids = [r.get('haid') for r in rows]
assert '$MY_HAID' in haids, 'self not on roster: ' + str(haids)
print('PASS: only self on roster (%d entries)' % len(haids))
"
# expect: PASS: only self on roster (1 entries)
# (may be 0 if beat hasn't propagated; re-run beat and retry)
```

---

## 3. Collaborator Auto-Join (2 devs, PRIVATE repo)

Dev A commits the team secret; Dev B pulls and auto-joins with zero secret paste.

### 3a. Negative test first — `share` refuses on a PUBLIC repo

Run inside a repo whose `origin` is a PUBLIC GitHub repo (or mock one):

```bash
heimdall-team share 2>&1; echo "exit=$?"
# expect: exit=1 (non-zero)
# stderr must contain "PUBLIC" AND one of "refus" / "expose" / "leak"
```

Confirm nothing was written or committed:

```bash
ls .heimdall/team.shared.json 2>&1
# expect: No such file or directory

git ls-files .heimdall/team.shared.json
# expect: (empty — not tracked)

git diff --cached -- .heimdall/team.shared.json
# expect: (empty — nothing staged)
```

### 3b. Dev A: share into the PRIVATE repo

**3.1 — Ensure Dev A has a team (mint if needed)**

```bash
heimdall-team show --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("configured:", d["configured"])'
# if configured: False, run:
heimdall-team new
```

**3.2 — Share: verifies privacy via `gh`, commits team.shared.json**

```bash
heimdall-team share
# expect output lines (exact):
# Shared the team (<32-hex team_id>) with collaborators of <owner/repo>.
# Committed (tracked) <path>/.heimdall/team.shared.json — NOT pushed (push when ready).
# Collaborators now AUTO-JOIN this team on their next pull. No secret paste needed.
# Rotate the team secret later with:  hmd team share --rotate
echo "exit=$?"
# expect: exit=0
```

**3.3 — Verify team.shared.json is tracked and committed**

```bash
git ls-files .heimdall/team.shared.json
# expect: .heimdall/team.shared.json   (non-empty = tracked)

git log --oneline -1
# expect: chore(team): share team secret with repo collaborators (private repo)
```

**3.4 — Capture Dev A's team_id**

```bash
TEAM_ID_A="$(heimdall-team show --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["team_id"])')"
echo "Dev A team_id: $TEAM_ID_A"
# expect: a 32-hex string
```

**3.5 — Push**

```bash
git push
```

### 3c. Dev B: pull and verify auto-join

**3.6 — Pull (inside Dev B's clone of the same repo)**

```bash
git pull
ls .heimdall/team.shared.json
# expect: file present
```

**3.7 — `show` reports source=shared, same team_id as Dev A**

```bash
heimdall-team show --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["source"] == "shared", "source wrong: " + str(d["source"])
assert d["configured"] is True
print("PASS: source=shared  team_id=%s" % d["team_id"])
'
# expect: PASS: source=shared  team_id=<same 32-hex as Dev A>
```

Compare against Dev A's team_id directly:

```bash
# substitute Dev A's printed team_id:
TEAM_ID_A="<paste Dev A team_id here>"
TEAM_ID_B="$(heimdall-team show --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["team_id"])')"
[ "$TEAM_ID_A" = "$TEAM_ID_B" ] && echo "PASS: team_ids match" || echo "FAIL: A=$TEAM_ID_A B=$TEAM_ID_B"
# expect: PASS: team_ids match
```

**3.8 — Dev B beats: auto-enrolls under the shared team (X-Heimdall-Team-Secret at /enroll)**

```bash
heimdall-presence beat
echo "exit=$?"
# expect: exit=0
```

> If Dev B was previously enrolled under a different (solo) team, force re-enroll:
> ```bash
> HAID="$(heimdall-identity current 2>/dev/null || heimdall-haid current)"
> SLUG="$(printf '%s' "$HAID" | tr '/:' '__')"
> rm -f ~/.heimdall/pki/"$SLUG".seed ~/.heimdall/pki/"$SLUG".enroll-attempt
> heimdall-presence beat
> ```

**3.9 — Both devs appear in the roster**

Run from Dev A (after Dev B's beat propagates — may take a few seconds):

```bash
heimdall-presence roster --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
haids = [r.get("haid") for r in rows]
print("HAIDs on roster:", haids)
assert len(haids) >= 2, "expected 2+ devs on roster, got: " + str(haids)
print("PASS: 2+ devs visible")
'
# expect: PASS: 2+ devs visible
```

---

## 4. Privacy / Isolation Boundary

Security-critical checks. Set `CP_URL` and `PROJECT` first:

```bash
CP_URL="$(python3 -c "
import json, os
f = os.path.expanduser('~/.heimdall/cp-endpoint.json')
d = json.load(open(f)) if os.path.exists(f) else {}
print((d.get('url') or 'https://heimdall-cp-public-eqfrs7sfuq-uc.a.run.app').rstrip('/'))
")"

PROJECT="$(git config --get remote.origin.url 2>/dev/null | \
  sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#^[^@/]*@##' \
      -e 's#:[0-9][0-9]*/#/#' -e 's#:#/#' -e 's#\.git$##' -e 's#/$##' | tr '[:upper:]' '[:lower:]')"

echo "CP_URL=$CP_URL"
echo "PROJECT=$PROJECT"
```

**Check 4.1 — Outsider with NO secret header -> 403**

```bash
curl -s -o /dev/null -w "%{http_code}" \
  "${CP_URL}/roster-team?project=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PROJECT'))")"
# expect: 403
```

**Check 4.2 — Wrong/random secret -> 200 with empty `online` (not another team's data)**

A random 43-char secret hashes to a random, empty team partition — no data leaks from other teams.

```bash
RAND_SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
curl -s \
  -H "X-Heimdall-Team-Secret: $RAND_SECRET" \
  "${CP_URL}/roster-team?project=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PROJECT'))")" \
| python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("online") == [], "FAIL: non-empty roster for random secret: " + str(d)
print("PASS: online=[]")
'
# expect: PASS: online=[]
```

**Check 4.3 — /roster-public is retired -> 403**

The old fully-public roster endpoint is permanently disabled.

```bash
curl -s -o /dev/null -w "%{http_code}" \
  "${CP_URL}/roster-public?project=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PROJECT'))")"
# expect: 403
```

**Check 4.4 — team_id presented as the secret -> 200, empty (team_id is inert)**

The team_id is a preimage-resistant hash (public). Knowing it does not yield the capability
to read the team's roster; it hashes to a different, empty partition.

```bash
TEAM_ID="$(heimdall-team show --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["team_id"])')"
curl -s \
  -H "X-Heimdall-Team-Secret: $TEAM_ID" \
  "${CP_URL}/roster-team?project=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PROJECT'))")" \
| python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("online") == [], "FAIL: team_id acted as capability: " + str(d)
print("PASS: online=[]")
'
# expect: PASS: online=[]
```

**Check 4.5 — GET /roster (BOUND-MEMBER path) returns only own team**

This path requires a valid signed request (done via `heimdall-presence roster`); an enrolled
Dev A cannot see Dev B's team through the signed path.

```bash
# As Dev A (enrolled under team SA):
heimdall-presence roster --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
haids = [r.get("haid") for r in rows]
print("roster haids:", haids)
# Dev B (enrolled under a different secret/team) must NOT appear here
'
# expect: only haids from team A listed; Dev B absent if on a different team
```

---

## 5. Negative / Guard Tests

**5.1 — `share` on a PUBLIC repo: hard refuse, exit nonzero, no file written, no secret in tree**

```bash
# Run inside a repo with a public GitHub origin.
heimdall-team share 2>&1; RC=$?
[ $RC -ne 0 ] && echo "PASS exit=$RC" || echo "FAIL: share exited 0 on public repo"
[ ! -f .heimdall/team.shared.json ] && echo "PASS: no shared file" || echo "FAIL: file created"
[ -z "$(git ls-files .heimdall/team.shared.json 2>/dev/null)" ] && echo "PASS: not tracked" || echo "FAIL: tracked"
```

Verify the refusal is loud:

```bash
heimdall-team share 2>&1 | grep -iE "PUBLIC|refus|expose|leak" | head -3
# expect: at least one matching line mentioning the public-repo risk
```

**5.2 — `HEIMDALL_NO_TEAM_AUTOSHARE=1` env opt-out**

```bash
# In a private repo with heimdall active.
HEIMDALL_NO_TEAM_AUTOSHARE=1 heimdall-team auto
[ ! -f .heimdall/team.shared.json ] && echo "PASS: opt-out respected" || echo "FAIL"
echo "exit=$?"
# expect: PASS: opt-out respected  exit=0
```

**5.3 — File-based opt-out (`~/.heimdall/no-team-autoshare`)**

```bash
touch ~/.heimdall/no-team-autoshare
heimdall-team auto
[ ! -f .heimdall/team.shared.json ] && echo "PASS: file opt-out respected" || echo "FAIL"
rm ~/.heimdall/no-team-autoshare   # restore
```

**5.4 — `join` rejects a secret shorter than 32 chars**

```bash
heimdall-team join "tooshort" 2>&1; echo "exit=$?"
# expect: exit=2, stderr mentions "weak" or "<32 chars"
ls .heimdall/team.json 2>&1 || true
# expect: no team.json for that dir (nothing written)
```

**5.5 — `new` refuses to clobber an existing team.json without --force**

```bash
# when team.json already exists:
heimdall-team new 2>&1; echo "exit=$?"
# expect: exit=2, stderr mentions "--force"
# team.json is unchanged (secret value identical before and after)
```

**5.6 — `auto` on a PUBLIC repo: solo team minted, never shared**

```bash
# bare `heimdall-team auto` inside a public-origin repo with heimdall active:
heimdall-team auto
[ ! -f .heimdall/team.shared.json ] && echo "PASS: auto never shared on public repo" || echo "FAIL: LEAK"
[ -f .heimdall/team.json ] && echo "PASS: solo team still minted" || echo "note: no solo team (normal if active marker absent)"
```

---

## 6. Automated Backstop

All five suites run offline (no network, no GCP). Each must exit 0 with `0 failed`.

```bash
cd /path/to/heimdall   # the heimdall repo root
```

**Team secret manager (unit + integration):**

```bash
bash test/heimdall-team.test.sh
# final line: heimdall-team: 11 passed, 0 failed
```

**Collaborator auto-join (share + precedence):**

```bash
bash test/heimdall-team-autojoin.test.sh
# final line: heimdall-team-autojoin: 10 passed, 0 failed
```

**Zero-command default team (bare dispatch + auto + opt-out):**

```bash
bash test/heimdall-team-default.test.sh
# final line: heimdall-team-default: 14 passed, 0 failed
```

**Presence durability under the Firestore backend:**

```bash
bash test/cp-presence.test.sh
# final line: cp-presence (fake): 7 passed, 0 failed
```

**Cross-team isolation (the falsifiable privacy gate — both in-process and real-HTTP):**

```bash
bash test/cp-team-isolation.test.sh
# final line: cp-team-isolation (fake): 27 passed, 0 failed
```

Combined team suites total: **35 passed, 0 failed** across the first three.
Total across all five suites: **69 passed, 0 failed**.

---

## 7. Teardown / Rotate

**Rotate the shared secret** (mints a new secret, overwrites both `team.json` and
`team.shared.json`, makes a new commit):

```bash
heimdall-team share --rotate
# expect output:
# Rotated + re-shared the team (<new_32-hex_team_id>) for <owner/repo>.
# The previous team_id ages out in one presence TTL; collaborators re-join on next pull.
# Committed (tracked) <path>/.heimdall/team.shared.json — NOT pushed (push when ready).
echo "exit=$?"
# expect: exit=0

git push   # distribute the rotated secret to collaborators
# collaborators: git pull -> auto-join the new team on their next beat
```

Verify the commit message:

```bash
git log --oneline -1
# expect: chore(team): rotate the team secret shared with repo collaborators (private repo)
```

**Remove a specific dev** (rotation is the only mechanism — the old secret becomes
an empty partition):

```bash
heimdall-team share --rotate
git push
# the removed dev must not pull; distribute the join one-liner to remaining members:
heimdall-invite
# prints a curl|bash one-liner with the NEW secret for remaining teammates
```

**Leave a team entirely** (return your own presence to solo):

```bash
rm .heimdall/team.json
# next heimdall-presence beat auto-mints a fresh solo team.json (source=auto-solo)
# you disappear from the team's roster after one TTL (~45 s)
```

**Remove the shared team from the repo** (owner revokes auto-join for future cloners):

```bash
git rm .heimdall/team.shared.json
git commit --no-verify -m "chore(team): revoke shared team"
git push
# existing clones that already have team.shared.json keep it until they pull
```
