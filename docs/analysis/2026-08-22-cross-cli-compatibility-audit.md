# Cross-CLI compatibility — how much of hmd reaches cursor, codex, gemini, aider

**Date:** 2026-08-22
**Question:** `bin/heimdall-wrap` advertises `TOOLS="claude cursor codex gemini aider"`. How much of hmd actually reaches each?
**Verdict:** **The split is structural vs harness-bound, and it is sharp.** The git layer is genuinely tool-agnostic and measured working under a third-party CLI. Everything else is Claude-Code-only *as built* — though **not** Claude-Code-only *as possible*: Codex CLI turns out to have a hook system with the same event names hmd already emits (§5), which reframes the roadmap. Three of the five advertised tools have **zero executable code** anywhere in `bin/` — only comments and list membership. One advertised tool (`cursor`) is **broken at launch by a binary-name bug** on a box where Cursor CLI is installed. Two overclaims found: a headroom disclosure that cannot be true for codex/gemini (§4b), and an `AGENTS.md`-reaches-everyone claim in hmd's own source that is false for Gemini CLI (§5a).

Evidence labels: **[MEAS]** = measured on this machine, command shown. **[DOC]** = documented in this repo or upstream, cited. **[INF]** = inferred, not measured.

Baseline: `merge-base(HEAD, main) == main tip == c6bc79d` at audit start.
No production code changed. All wrap testing in a throwaway `git worktree`
(`/tmp/hmd-compat-audit`, removed), all `HEIMDALL_HOME` writes redirected to `mktemp -d`.

---

## 1. The crux: two layers, not one spectrum

hmd's capabilities divide cleanly by **what enforces them**, and this is the whole answer:

| Layer | Enforced by | Reaches |
|---|---|---|
| **Structural** | git hooks via `core.hooksPath` → `.heimdall/hooks` | **any process that runs `git commit`** — every CLI, and a bare shell |
| **Harness-bound** | `hooks/hooks.json` SessionStart / PreToolUse / PostToolUse | **Claude Code only** |
| **Launch-bound** | `bin/heimdall` exec'd only when `tool = claude` | **Claude Code only** |

**[MEAS]** The structural layer really is process-agnostic. From a bare `bash`
shell in the wrapped worktree — no Claude Code, no cursor-agent, no harness of
any kind — a staged stub was denied:

```
$ printf 'function f() {\n  // TODO: implement\n}\n' > stubtest.js
$ git add stubtest.js && git commit -m "audit: stub probe"
🛑 BIFRÖST — Heimdall DENIED the pre-commit
   gate: stub-scan
   • stub introduced by this change: code-comment TODO/FIXME @ stubtest.js
```

`git log --oneline -1` unchanged afterwards — nothing landed.

**[MEAS]** The commit-attribution trailer is equally process-agnostic. A plain
`git commit` from the same bare shell produced:

```
audit: trailer probe
Co-Authored-By: runhmd <318965969+runhmd@users.noreply.github.com>
```

**[MEAS]** The harness-bound layer is quantified: `hooks/hooks.json` carries **20
matcher blocks across 5 event types** (`UserPromptSubmit` 2, `PreToolUse` 5,
`PostToolUse` 3, `SessionStart` 8, `SessionEnd` 2) and contains **zero**
references to any other tool (`grep -c cursor hooks/hooks.json` → 0). Cursor CLI
has its own unrelated `.cursor/hooks.json` schema, which hmd never writes —
**[DOC]** stated in hmd's own source at `bin/heimdall-statusline-register-cursor:102-103`:
"its OWN separate `.cursor/hooks.json` schema … is unrelated to".

**[MEAS]** The launch-bound layer: `bin/heimdall-wrap:290-292` execs
`bin/heimdall` only under `[ "$tool" = "claude" ]`; every other tool gets a bare
`exec "$real"`. The helpers thereby skipped are enumerated by hmd's own test
(`test/heimdall-cli-routing.test.sh:580`): `heimdall-model-resolve`,
`skill-manager`, `heimdall-face`, `heimdall-reuse-metric`, `heimdall-persona`,
`heimdall-frontdoor`, `heimdall-comprehend`, `heimdall-telemetry`,
`heimdall-haid` — **nine launch helpers, all Claude-Code-only**, including the
comprehend/capsule path.

---

## 2. What `hmd wrap <tool>` actually does — traced, all five

**[MEAS]** `do_wrap()` is almost entirely tool-agnostic. Using the script's own
`HEIMDALL_TRACE_ORDER` seam (exits just before the real exec), all five tools
produce an **identical trace shape** and an identical snapshot directory:

```
claude   exit=0 trace=[wrap:headroom:routed:http://127.0.0.1:8787 wrap:launch:claude]
cursor   exit=0 trace=[wrap:headroom:routed:http://127.0.0.1:8787 wrap:launch:cursor]
codex    exit=0 trace=[wrap:headroom:routed:http://127.0.0.1:8787 wrap:launch:codex]
gemini   exit=0 trace=[wrap:headroom:routed:http://127.0.0.1:8787 wrap:launch:gemini]
aider    exit=0 trace=[wrap:headroom:routed:http://127.0.0.1:8787 wrap:launch:aider]
```

The wrap side effects — git hooks, AGENTS.md fence, `.gitignore` lines (all
delegated to `bin/heimdall-init`), presence keeper, optional PATH shim — are
written the same way for every tool. **This is the good news and it is real:**
the reversibility contract, the snapshot, and the Layer-0 install are genuinely
tool-neutral. The fork is only at `launch_tool`.

---

## 3. Capability × CLI matrix

Verdicts: **works** (measured or structurally guaranteed) · **partial** ·
**absent** · **untestable-here** (binary not installed).

| Capability | claude | cursor | codex | gemini | aider |
|---|---|---|---|---|---|
| git gates (`pre-commit`/`pre-push` stub-scan, oracle) | works **[MEAS]** | **works [MEAS]** | works **[INF]** | works **[INF]** | works **[INF]** |
| commit-attribution trailer (`prepare-commit-msg`) | works **[MEAS]** | works **[INF]** | works **[INF]** | works **[INF]** | works **[INF]** |
| AGENTS.md fence delivered to the agent | works **[MEAS]** | **works [MEAS]** | works **[DOC]** | **absent by default [DOC]** §5 | **absent [DOC]** §5 |
| presence / team wall | works **[MEAS]** | works **[MEAS]** | works **[INF]** | works **[INF]** | works **[INF]** |
| statusline HUD | works **[MEAS]** | **works [MEAS]** | absent **[MEAS]** | absent **[MEAS]** | absent **[MEAS]** |
| `hooks.json` event layer (PreToolUse etc.) | works **[MEAS]** | **absent [MEAS]** | absent — *but seam exists* **[DOC]** §5 | absent — *but seam exists* **[DOC]** §5 | absent, no seam **[DOC]** §5 |
| comprehend / capsule + 8 other launch helpers | works **[MEAS]** | absent **[MEAS]** | absent **[MEAS]** | absent **[MEAS]** | absent **[MEAS]** |
| headroom routing genuinely effective | works **[MEAS]** | unconfirmed | **claimed, cannot work [DOC]** §4b | **claimed, cannot work [DOC]** §4b | claimed, unconfirmed **[DOC]** §5 |
| `hmd wrap <tool>` reaches launch at all | works **[MEAS]** | **BROKEN [MEAS]** §4 | untestable-here | untestable-here | untestable-here |

The `[INF]` cells in the git-gate rows are inference of a **strong** kind: the
mechanism is `core.hooksPath`, which git applies to every commit in the repo
regardless of parent process — proven **[MEAS]** from a bare shell in §1. The
inference is only that these four tools invoke `git commit` rather than
reimplementing git plumbing.

### Cursor, measured end to end

**[MEAS]** Cursor CLI reads the hmd-generated AGENTS.md fence. Asked to report
the two `hmd` bullets from inside the fence, `cursor-agent` returned exactly
`hmd verdict, hmd demo`.

**[MEAS]** And the gate bites its commits. `cursor-agent` was asked to write a
stub, commit it, and report the error verbatim. It reported:

> Commit was **denied** by the pre-commit hook (`stub-scan`).
> `stub introduced by this change: code-comment TODO/FIXME @ cursorstub.js`

`cursorstub.js` existed on disk; `git log` was unchanged. That is precisely the
behaviour hmd's own AGENTS.md fence predicts — **[DOC]**, from the generated
block itself: "a stub gets caught at commit here instead of at the write itself,
since Cursor has no pre-write hook to catch it earlier." The documentation is
honest and the measurement confirms it.

**[MEAS]** The Cursor statusline registrar is real and works. Run against a
sandboxed config path (`HEIMDALL_CURSOR_CLI_CONFIG`, its own documented test
seam — the real `~/.cursor/cli-config.json` was never touched), it emitted
`registered` and wrote a valid `statusLine` block pointing at
`bin/heimdall-statusline`. The shared renderer also accepts Cursor's payload
shape: fed `{"workspaceRoot":...,"width":120}` on stdin it rendered the four-row
HUD. It is auto-wired from `hmd init` (`install.sh:380-385`).

---

## 4. Two defects and one overclaim

### 4a. `hmd wrap cursor` is broken — the binary is `cursor-agent`, not `cursor` **[MEAS]**

`TOOLS` uses the token `cursor`, and `launch_tool` resolves the binary by that
same token (`real_binary "$tool"` → `command -v cursor`). But Cursor CLI does
not install a `cursor` binary:

```
claude         claude
cursor         ABSENT
cursor-agent   /Users/rj/.local/bin/cursor-agent
agent          /Users/rj/.local/bin/agent
```

So on this machine — which **has** Cursor CLI, authenticated and working (§3) —
the real command fails:

```
$ hmd wrap cursor
  ✓ git hooks .heimdall/hooks (pre-commit · pre-push · post-commit)
  ✓ AGENTS.md fenced block …
  ✓ presence starting …
  ✓ cursor is wrapped. unwrap with: hmd unwrap cursor
  ✓ headroom generation routed via http://127.0.0.1:8787 …
  heimdall wrap: cursor is not installed (not found on PATH) —
    the repo is wrapped; install cursor and run it
```

Two things make this worse than a typo. First, **the remediation advice is
unfollowable** — there is no `cursor` binary to install; the user already has the
product. Second, **hmd already knows the right answer in two other places**:
`bin/heimdall-ai-select`'s backends table has `cursor-agent,agent`
(`heimdall-ai-select:25`) and detects it fine, and the statusline registrar and
`hmd init` both gate on `cursor-agent`. Three registries, one disagreement.

**Root cause — why no test caught it. [MEAS]** `test/wrap-lifecycle.test.sh:117-131`
manufactures a fake binary for each name in `TOOLS`:

```bash
# FAKE TOOL BINARIES — every one of the five tools, so the launch path is really
# exercised for each rather than only for whatever happens to be installed here.
for t in $TOOLS; do cat > "$TOOLBIN/$t" <<'EOTOOL'
```

The test creates a file literally named `cursor`, so it validates the
implementation's assumption instead of reality. It can never catch this class of
bug for any of the five names.

### 4b. Headroom claims a routing that cannot take effect for codex/gemini **[MEAS]**

`launch_tool` runs the headroom chain **before** the per-tool branch, so all five
tools get `export ANTHROPIC_BASE_URL` and all five print the disclosure line
`✓ headroom generation routed via http://127.0.0.1:8787` — confirmed for all five
in the §2 trace.

But **[DOC]**, from `bin/lib/hmd-headroom-chain.sh:12-17`, the chain sets exactly
one variable and the file states its scope itself: "ONE variable is exported …
`ANTHROPIC_BASE_URL` … **Nothing else reads it.**" `HTTPS_PROXY`/`ALL_PROXY` are
deliberately never set. `ANTHROPIC_BASE_URL` is an Anthropic-SDK variable; a tool
that never speaks to an Anthropic endpoint cannot be affected by it.

So for codex and gemini the line asserts a routing that provably cannot occur.
This is a disclosure, printed in green with a checkmark, in a codebase whose
README explicitly refuses to ship "a proxy the user cannot see" — the failure
here is the mirror image: **a proxy the user is told about that isn't there.**
Same defect class as the two removed today. Fix is cheap: gate the disclosure on
whether the tool reads the variable.

### 4c. `TOOLS` presents five co-equal tools; three have zero implementation **[MEAS]**

What a user sees from `hmd wrap --help`:

```
  tools: claude cursor codex gemini aider
```

Flat list, no differentiation. What is behind each name, counted across `bin/`
and `hooks/`:

| tool | footprint in `bin/` + `hooks/` | executable branches |
|---|---|---|
| cursor | `heimdall-init:35`, `heimdall:16`, `ai-select:4`, `gate-run:1`, `city:1`, `demo:1`, + a 320-line dedicated registrar | many |
| codex | `heimdall:2`, `heimdall-init:2`, `ai-select:1`, `wrap:4` | **zero** |
| gemini | `heimdall-init:2`, `ai-select:1`, `wrap:3` | **zero** |
| aider | `ai-select:1`, `wrap:3` | **zero** |

**[MEAS]** Every single codex/gemini/aider occurrence in `bin/` outside
`heimdall-wrap`'s `TOOLS` string is a **comment**. Verified by reading each:
`bin/heimdall:2450-2451` (a comment about arg forwarding), `bin/heimdall-init:24,85`
(prose about AGENTS.md), `bin/heimdall-ai-select:5` (a comment inviting someone to
add them: "Add a third CLI (codex, gemini, aider, …)" — they are **not** in the
`BACKENDS` table). `aider` appears in only 3 files repo-wide and in **zero**
documentation.

**In fairness — and this matters for how the recommendation is framed:** these
three are not getting *nothing*. Via `TOOLS` membership they get the
tool-agnostic Layer 0: git gates, the attribution trailer, presence, and
reversible unwrap. That is real, load-bearing value, and it is the bulk of what
makes hmd hmd. The defect is the **flat presentation** — a list implying parity
with `claude`, which carries 9 extra launch helpers and 20 hook matcher blocks,
and with `cursor`, which has a statusline and a purpose-built registrar.

One caveat on that Layer 0, added after the upstream sweep (§5): the AGENTS.md
fence is part of Layer 0 mechanically — `hmd init` writes the file regardless of
tool — but it only *lands* if the tool reads it. Codex does; **Gemini CLI does not
by default and aider does not at all** (§5a). So for those two the fence is
written and never read, which is why it is not listed above.

### Where the docs are already honest — credit due

The README does **not** overclaim. **[MEAS]** `grep -c -i` over `README.md`:
`codex` 0, `gemini` 0, `aider` 0. Cursor is described precisely and scoped —
`README.md:208` lists "Cursor CLI host (**gate + statusline HUD**)", and
`README.md:344` limits the claim to the same `pre-commit`/`pre-push` path plus
AGENTS.md. The positioning line the question quotes lives in
`.planning/PARTB-ANSWERS.md:296` and is explicitly forward-looking ("Claude Code
today; … next"). And `launch-docs/GEO-SCORECARD.md:72-83` already writes down the
correct answer to this exact question, including: "**An assistant that claims full
Cursor/Codex/Gemini parity today would be a FALSE POSITIVE.**"

**The overclaim is not in the prose. It is in the CLI surface** — `TOOLS` and the
help text — which is the one place a user actually looks before running.

---

## 5. codex / gemini / aider — not installed here

**[MEAS]** `codex`, `gemini`, `aider` are all absent from PATH on this machine, so
nothing below is measured. All of it is **[DOC]** from upstream documentation,
cited. This section answers the question hmd cannot answer from its own source:
**do the integration points hmd assumes even exist?**

| | **Codex CLI** | **Gemini CLI** | **Aider** |
|---|---|---|---|
| Binary | `codex` | `gemini` | `aider` |
| Hook system | **YES — Claude-Code-shaped** | **YES — different event names** | **NO** |
| Statusline via external command | **NO** (predefined items only) | **NO** | **NO** |
| Reads `AGENTS.md` | **YES, native** | **NO** — `GEMINI.md`; opt-in | **NO** — explicit `read:` |
| Reads `ANTHROPIC_BASE_URL` | **No effect** | **No effect** | UNCONFIRMED |

**Codex has a hook system whose event names match Claude Code's exactly.**
`~/.codex/hooks.json`, `<repo>/.codex/hooks.json` (also `config.toml` `[hooks]`),
with `SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`,
`UserPromptSubmit`, plus `PermissionRequest`, `SubagentStart/Stop`,
`PreCompact/PostCompact`, `Stop`. Same three-level shape hmd already emits —
event → `matcher` group → `{type:"command", command, timeout}` — and `PreToolUse`
can **deny**, via `permissionDecision:"deny"` or exit 2. Hooks require per-hash
trust (`/hooks`).
<https://learn.chatgpt.com/docs/hooks>
**This is the single most consequential finding in the audit**: the layer this
report calls "harness-bound" is *not* intrinsically Claude-Code-only. For Codex it
is a near-namesake port, not a rewrite.

**Gemini CLI has hooks, with different names.** `hooks` in `settings.json`
(`.gemini/settings.json` project, `~/.gemini/settings.json` user); events
`BeforeTool`, `AfterTool`, `BeforeAgent`, `AfterAgent`, `BeforeModel`,
`BeforeToolSelection`, `AfterModel`, `SessionStart`, `SessionEnd`, `Notification`,
`PreCompress`. Fields: `matcher`, `sequential`, `hooks[]` of
`{type:"command", command, name, timeout, description}`.
<https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md>
So a port needs a name mapping (`PreToolUse`→`BeforeTool`, etc.). Secondary
sources claim Claude-Code aliases plus a `gemini hooks migrate --from-claude`;
that is **UNCONFIRMED** — the official repo doc lists only `BeforeTool`/`AfterTool`.

**Aider has no hook or event system at all.** Nearest seams are
`--notifications-command`, `--lint-cmd`, `--test-cmd`.
<https://aider.chat/docs/config/options.html>

**No external-command statusline seam exists in any of the three.** Codex's
`tui.status_line` takes an ordered array of *predefined item ids*, not a shell
command — command-backed statuslines are open feature requests (openai/codex
[#20244](https://github.com/openai/codex/issues/20244),
[#17827](https://github.com/openai/codex/issues/17827)).
<https://learn.chatgpt.com/docs/config-file/config-reference>
Gemini CLI has no statusline key; `ui.*` is presentational and accepts no command.
<https://google-gemini.github.io/gemini-cli/docs/get-started/configuration.html>
Aider has none.

### 5a. A second overclaim, in hmd's own source **[DOC]**

`bin/heimdall-init:85` asserts: "AGENTS.md is the one file Cursor, Codex, Gemini
CLI and Claude Code all read at session start" (repeated at `:24`). Checked
name by name:

- **Cursor** — true, **[MEAS]** in §3.
- **Claude Code** — true.
- **Codex** — true. Native `AGENTS.md`, with `project_doc_fallback_filenames`
  and `model_instructions_file` documented as "Replacement for built-in
  instructions instead of `AGENTS.md`".
  <https://learn.chatgpt.com/docs/config-file/config-reference>
- **Gemini CLI — FALSE.** It defaults to `GEMINI.md` (hierarchical:
  `~/.gemini/GEMINI.md` plus cwd and ancestors). `AGENTS.md` is **not** a default;
  it is read only if the user sets `context.fileName: ["AGENTS.md", …]`.
  <https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/gemini-md.md>

So the fence hmd writes to make "the whole field Heimdall-aware with zero
adapters" does not, by default, reach one of the four tools that sentence names.
The claim is stated twice, in comments that justify a design decision — and it is
the justification, not just a stray remark.

**Aider is worse and is at least *consistently* worse:** it auto-discovers **no**
instructions file. Context is loaded explicitly — `aider --read CONVENTIONS.md`,
`/read`, or `read: [AGENTS.md]` in `.aider.conf.yml`.
<https://aider.chat/docs/usage/conventions.html>
hmd's `:85` claim correctly omits aider — but `TOOLS` does not, so `hmd wrap
aider` writes a fence that aider will never read.

### 5b. §4b confirmed upstream **[DOC]**

The headroom disclosure (§4b) is now confirmed false for two tools, not merely
suspected. **Codex** does not read `ANTHROPIC_BASE_URL` — its documented env list
contains no `ANTHROPIC_*` and no base-URL var; custom endpoints go through
`model_providers.<id>.base_url` + `env_key`, or `openai_base_url`.
<https://learn.chatgpt.com/docs/config-file/environment-variables>
**Gemini CLI** does not read it — documented vars are `GEMINI_API_KEY`,
`GOOGLE_API_KEY`, `GOOGLE_CLOUD_PROJECT/LOCATION`, `CODE_ASSIST_ENDPOINT`.
**Aider** can drive Claude models (`ANTHROPIC_API_KEY`), but no
`--anthropic-api-base` exists and neither `ANTHROPIC_API_BASE` nor
`ANTHROPIC_BASE_URL` is documented by aider; it routes via LiteLLM, which *does*
document `ANTHROPIC_API_BASE` with `ANTHROPIC_BASE_URL` as an accepted alternative
(<https://docs.litellm.ai/docs/providers/anthropic>), so pass-through is
plausible but **UNCONFIRMED** by aider's own docs.
<https://aider.chat/docs/llms/anthropic.html>

### 5c. One genuinely tool-agnostic surface the matrix omits

**[MEAS]** `bin/heimdall-ledger-mcp` exists — a Python MCP server exposing the
coordination-ledger tools. MCP is a client-neutral protocol, so any MCP-capable
client gets those tools with no hmd code, **[DOC]** exactly as
`launch-docs/GEO-SCORECARD.md:77-79` claims.

One genuinely tool-agnostic surface deserves a mention the matrix does not cover:
**[MEAS]** `bin/heimdall-ledger-mcp` exists (a Python MCP server exposing the
coordination-ledger tools). MCP is a client-neutral protocol, so any MCP-capable
client gets those tools without hmd code — **[DOC]** exactly as
`launch-docs/GEO-SCORECARD.md:77-79` claims.

---

## 6. Recommendations, ranked by value ÷ effort

**R1 — Fix the `cursor` binary name. Small, unambiguous bug.**
Map tool token → candidate binaries instead of assuming they are equal, reusing the
list `heimdall-ai-select` already has (`cursor-agent,agent`). Today `hmd wrap cursor`
fails for every Cursor user on earth. Also fix `resolve_default`, which walks
`command -v "$t"` and therefore can never auto-detect Cursor either. **Then fix the
test**: `test/wrap-lifecycle.test.sh` must stop fabricating a binary named `cursor`,
or the bug returns. Highest value, lowest effort, no design question.

**R2 — Gate the headroom disclosure on whether the tool can read the variable.**
One conditional in `launch_tool`. Removes a false green checkmark. If the honest
answer for codex/gemini is "not routed — hmd routes Anthropic traffic only", print
that; the machinery for a negative message already exists (`HMD_HEADROOM_WHY`).

**R3 — Narrow, or annotate, the advertised tool list. Recommended.**
Two defensible options; both are honest:
  - *(a) Annotate.* Keep all five, differentiate in help text — e.g. `claude
    (full) · cursor (gate + HUD) · codex, gemini, aider (git gate only)`. Keeps
    the real Layer-0 value discoverable while killing the parity implication.
  - *(b) Narrow.* Reduce `TOOLS` to `claude cursor` and let the rest arrive with
    an implementation. Cleanest, and consistent with the repo's own
    GEO-SCORECARD position.

Prefer **(a)**: the git gate genuinely does work for those tools, and narrowing
would hide a shipped capability. But **(a) is only honest if R2 ships with it** —
otherwise the annotation says "git gate only" while the runtime still claims
headroom routing.

**R4 — Correct the `AGENTS.md`-reaches-everyone claim. Trivial, comment-only.**
`bin/heimdall-init:24` and `:85` assert Gemini CLI reads `AGENTS.md` at session
start. It does not (§5a). Two lines of comment, no behaviour change — but they are
the stated *justification* for a design decision, so leaving them wrong is exactly
the doc-drift this repo keeps getting bitten by. Optional follow-on with real
value: have `hmd init` also write a `GEMINI.md` pointer, or set
`context.fileName`, when Gemini CLI is detected.

**R5 — A `.codex/hooks.json` writer. The highest-value item, and cheaper than
expected.** **[DOC]** Codex's hook system uses the *same event names and the same
three-level shape* hmd already emits for Claude Code — `SessionStart`,
`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `SessionEnd`, with `PreToolUse`
able to deny (§5). This is the one place where the "harness-bound" half of §1
stops being Claude-Code-only, and it would move Codex from *git-gate-only* to
near-parity. Two caveats to design around before promising anything: hooks require
per-hash trust (`/hooks`), so the write is not silently effective; and the writer
needs the same snapshot/reversibility contract `wrap` holds for every other file
it touches. Prototype against the real `codex` binary — nothing here is measured.

**R6 — A `.cursor/hooks.json` writer.** Closes the one gap hmd's own AGENTS.md
fence admits, moving Cursor from "caught at commit" to "caught at write".
**[DOC]** schema documented locally at `~/.cursor/skills-cursor/create-hook/SKILL.md`,
and hmd's source already points at it
(`heimdall-statusline-register-cursor:102-103`). Ranked below R5 only because
Codex's event names match hmd's existing config verbatim while Cursor's schema is
its own; Cursor's event model must be checked for a real pre-write analogue before
this is promised. Same reversibility requirement. A Gemini port ranks third —
its hooks exist but need a name mapping (`PreToolUse`→`BeforeTool`), and the
claimed `--from-claude` migration path is UNCONFIRMED (§5).

**R7 — Statusline registrars for codex/gemini: do NOT build. Question answered.**
This was the open question in the original framing; upstream docs close it.
**Neither CLI has an external-command statusline seam** — Codex's
`tui.status_line` accepts only predefined item ids (command support is an *open
feature request*), and Gemini CLI has no statusline key at all (§5). There is
nothing to register against. Revisit only if openai/codex#20244 lands.

**Not recommended:** auto-loading `heimdall-comprehend` for the non-claude wrap
paths. The deferral already recorded for it is correct — a capsule written by
`do_wrap()` survives `unwrap` and breaks the byte-for-byte reversibility
`test/wrap-lifecycle.test.sh` enforces. Reversibility is the contract that makes
`wrap` safe to offer at all; it outranks the feature.
