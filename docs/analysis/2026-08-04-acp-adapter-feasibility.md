# hmd ACP adapter — feasibility (V11 scoping)

**Date:** 2026-08-04 · **Status:** investigation only, no code written · **Decision owner:** RJ

## Which "ACP" this scopes

**Agent Client Protocol** — <https://agentclientprotocol.com> — JSON-RPC 2.0 between a *Client* (editor/UI)
and an *Agent* (coding agent subprocess) [A1]. **Not** IBM/BeeAI's "Agent Communication Protocol", not
Anthropic's MCP. Disambiguator confirmed, not assumed: the owner named Agent Canvas, and OpenHands is
listed on ACP's own agents page [A8], while OpenHands' Agent Canvas docs describe driving external CLIs
"over JSON-RPC on stdio" and link `agentclientprotocol.com` [O1]. Ambiguity resolved; no flag needed.

Spec fetched live 2026-08-04 via `agentclientprotocol.com/llms-full.txt` (1.4 MB, all pages) + per-page
`.md`. **v1 is stable; v2 is published in Draft** [A9] — this doc scopes v1.

## 1. What an hmd ACP adapter would expose

The load-bearing fact: **ACP inverts the direction hmd needs.** In MCP a server advertises callable tools
(`tools/list` → `tools/call`). In ACP, tool calls flow *Agent → Client as reports* — "Agents report tool
calls through `session/update` notifications" with `sessionUpdate: "tool_call"`, fields `toolCallId`,
`title`, `kind`, `status` [A6]. The methods a Client exposes are a **fixed, capability-gated set**:
`fs/read_text_file`, `fs/write_text_file`, `terminal/*`, `session/request_permission`,
`elicitation/create` [A1, A3]. **There is no mechanism in ACP for an Agent to advertise arbitrary
callable tools to a Client.** hmd cannot re-expose its surfaces as ACP "tools".

| hmd surface | Nearest ACP construct | Mismatch |
|---|---|---|
| **gate_check** (`bin/heimdall-gate-run`) | Slash command: `session/update` → `available_commands_update`, `availableCommands[]` of `AvailableCommand{name, description, input}` [A5] | `AvailableCommandInput` "currently supports unstructured text input" — only a `hint` string, **no JSON Schema** [A5], vs MCP's typed `inputSchema`. Invocation is literal text in a `session/prompt` (`"/gate_check ..."`) [A5] → the gate is parsed out of prose, not called. Result returns as a conversational turn, not a typed value. Falsifiability survives (real exit codes) but machine-callability does not. |
| **verdict** (`bin/heimdall-verdict` → `.heimdall/verdict.json` `{verdict, phase, ts, gate, file, reasons[]}`; republished by `bin/heimdall-gate-surface` to `.planning/ledger/verdicts/{haid}.json`) | No typed home. Options: `ToolCallContent` on a `tool_call` update [A6], or `_meta` (present on all types, `{[key:string]: unknown}`) [A4] | ACP has no PASS/FAIL/evidence type. `_meta` carries it, but `_meta` is by definition ignorable — no client renders it. The closest *typed* structure is Agent Plan entries, which model plans, not verdicts. Verdict degrades to rendered text + an out-of-band `_meta` blob. |
| **wall** (live team/presence view; `bin/heimdall-board`, `heimdall-who team --gates`) | Nothing. Would need a custom notification `_heimdall.dev/wall` under the underscore-prefix extension rule [A4] | Worst fit. ACP sessions are **one Client ↔ one Agent**; the protocol has no multi-party, presence, or roster concept anywhere in v1. A custom notification is legal but zero clients would render it — it is a private channel wearing a standard's clothes. |

Extension mechanics are real and usable: `_meta` on every type, custom methods/notifications prefixed `_`,
and custom capabilities advertised via `_meta` inside capability objects [A4]. But implementations **MUST
NOT** add custom fields at the root of spec types [A4] — so all three surfaces live in `_meta` or in
underscore methods, i.e. **outside** what any stock ACP client understands.

## 2. Where it slots vs MCP Layer 1

**ACP complements MCP; it neither duplicates nor supersedes it. One adapter cannot serve both, and does
not need to.**

hmd already ships `bin/heimdall-ledger-mcp` — MCP `2024-11-05` over stdio JSON-RPC, 6 tools
(`read_claims`, `make_claim`, `release_claim`, `read_capsules`, `append_decision`, `raise_conflict_pr`),
tool-schema v1.0.0, contract in `PROTOCOL.md`, registered via `.mcp.json`.

ACP is explicitly **MCP-friendly**: it "re-uses MCP types where possible" [A2], and `session/new` takes
`cwd` plus an `mcpServers[]` array of `{name, command, args, env}` which the Agent connects to directly
[A7, A2]. So the free path is:

> An ACP Client (Agent Canvas) passes `heimdall-ledger-mcp` in `session/new.mcpServers` → **every** ACP
> agent (Claude Code, Codex, Gemini CLI, OpenHands) gets hmd's 6 ledger tools with **zero new hmd code**.

That is the highest-leverage move available and it requires building nothing. An ACP *adapter* only makes
hmd the driven agent — the thing being told to write code — which hmd is not.

Agent Canvas specifics: its Agent Server "spawns the agent's own CLI as a subprocess and relays each turn
to it"; settings write `agent_kind`/`acp_server`/`acp_command`/`acp_model` via `PATCH /api/settings`; and
critically **"Any stdio ACP server works: choose Custom in Settings → Agent and enter its launch
command"** [O1]. The Agent Server itself is a separate HTTP/WebSocket API (`/health`, `/ready`,
`/server_info`, `/api/*`, key via `X-Session-API-Key`) [O2] — a third integration surface, unrelated to
ACP, that hmd could target instead if the goal is observing conversations rather than being one.

## 3. Effort estimate

Dominant cost is **not** the wire protocol. hmd already runs a JSON-RPC-2.0-over-stdio server (~630 LOC,
Python stdlib only). The cost is that ACP forces hmd to **impersonate a conversational coding agent**:
session lifecycle, streamed `session/update` notifications, content blocks, stop reasons, cancellation.
That is protocol surface hmd has no existing analogue for and no product reason to want.

| Wave | Work | Depends on |
|---|---|---|
| 0 | Verify Agent Canvas forwards `mcpServers` to a Custom ACP server (see risk below). **If yes, waves 1–3 are unnecessary.** | — |
| 1 | ACP skeleton: `initialize` version/capability negotiation [A3], `session/new`, `session/prompt`, `session/cancel`, `session/update` streaming | 0 |
| 2 | Surface mapping: `available_commands_update` for gate_check; verdict → `ToolCallContent` + `_meta`; wall → `_heimdall.dev/*` custom notification | 1 |
| 3 | Conformance against ≥2 real clients (Zed, Agent Canvas Custom); absolute-path invariant (all paths **MUST** be absolute [A1]) | 2 |

Wave 1 is the bulk. Waves 1–3 are comparable in size to the existing MCP server **plus** the session/
streaming machinery it never needed — call it 2–3× `heimdall-ledger-mcp`.

**Riskiest unknown:** ACP v2 is in Draft *now* [A9]. Wave-1 work against v1 buys a migration; work against
v2 buys draft churn. Building today pays that tax for a surface (wave 0) that may make it moot.

## 4. Recommendation

**DON'T BUILD — do wave 0 only.** Verify MCP passthrough. hmd's value to an ACP world is as an MCP server
consumed *by* ACP agents, not as an ACP agent. Building the adapter means impersonating a coding agent to
expose three surfaces that ACP has no type for, two of which (verdict, wall) would render nowhere.

**What flips this to BUILD:**
1. Wave 0 proves Agent Canvas does **not** forward `mcpServers` on the Custom-ACP path — then a minimal
   ACP adapter is the only door into Canvas, and gate_check-as-slash-command becomes worth its cost.
2. The product goal changes to "a Canvas/Zed user picks **Heimdall** as their agent" — that is an ACP
   Agent by definition, and no MCP wiring substitutes.
3. ACP v2 stabilizes with a typed verdict/attestation or multi-party construct. Worth a re-read; v2's
   surface was not audited here.

## Could not determine (UNVERIFIED — not rounded up to fact)

- **Whether Agent Canvas populates `session/new.mcpServers` for a Custom ACP server.** The ACP spec says
  Clients pass MCP servers at `session/new` [A7]; the Agent Canvas ACP page [O1] does not state whether
  Canvas does. This is the single load-bearing unknown in the recommendation and is exactly wave 0.
- **ACP v2's message surface.** v1 only was audited; v2 is Draft [A9]. Any v2 claim here would be invented.
- **Whether any shipping ACP client renders `_meta` or underscore-prefixed custom notifications.** The spec
  permits both [A4]; no client behaviour was tested.
- **OpenHands Agent Server `/api/*` schemas.** Endpoint *names* are cited [O2]; request/response shapes
  were not fetched.

## Claim ledger

**32 protocol claims cited to a fetched spec page + named section/field · 4 items marked UNVERIFIED · 0
claims from memory.**

### Sources (all fetched 2026-08-04)

- [A1] Overview — Communication Model, Message Flow, Agent/Client method lists, Argument requirements. <https://agentclientprotocol.com/protocol/v1/overview>
- [A2] Architecture — Design Philosophy ("MCP-friendly"), Setup (stdin/stdout subprocess), MCP. <https://agentclientprotocol.com/get-started/architecture>
- [A3] Initialization — `protocolVersion`, `clientCapabilities`, `agentCapabilities`, "omitted ⇒ UNSUPPORTED". <https://agentclientprotocol.com/protocol/v1/initialization>
- [A4] Extensibility — `_meta`, Extension Methods (`_` prefix), Advertising Custom Capabilities, root-field prohibition. <https://agentclientprotocol.com/protocol/v1/extensibility>
- [A5] Slash Commands — `available_commands_update`, `AvailableCommand`, `AvailableCommandInput.hint`, Running commands. <https://agentclientprotocol.com/protocol/v1/slash-commands>
- [A6] Tool Calls — agent-reports-to-client model, `toolCallId`/`title`/`kind`/`status`, `ToolCallContent`. <https://agentclientprotocol.com/protocol/v1/tool-calls>
- [A7] Session Setup — `session/new` params `cwd`, `mcpServers[]`. <https://agentclientprotocol.com/protocol/v1/session-setup>
- [A8] Agents — OpenHands listed as an ACP agent. <https://agentclientprotocol.com/get-started/agents>
- [A9] ACP v2 is available in Draft. <https://agentclientprotocol.com/announcements/acp-v2-draft>
- [O1] Agent Canvas → ACP Agents — subprocess relay, `agent_kind`/`acp_command`, `PATCH /api/settings`, Custom ACP servers. <https://docs.openhands.dev/openhands/usage/agent-canvas/acp-agents>
- [O2] Agent Server Package — HTTP/WebSocket API, `/health`, `/ready`, `/server_info`, `/api/*`, `X-Session-API-Key`. <https://docs.openhands.dev/sdk/arch/agent-server>
- Local: `bin/heimdall-ledger-mcp`, `PROTOCOL.md` (MCP Interop Contract v1.0.0), `bin/heimdall-verdict`, `bin/heimdall-gate-surface`, `bin/heimdall-gate-run`, `bin/heimdall-board`.
