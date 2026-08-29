# Pasted-secret filter — what is actually possible, and what this buys you

Owner's requirement, verbatim:

> "a filtering system to always use the keys pasted in chat as variable and never
> send them to target models just the variables that can be saved locally"

The desired shape is *substitution*: you paste `sk-ant-…`, the model receives
`{{HMD_SECRET_1}}`, and the real value stays on your disk. **That exact design is
not implementable in Claude Code.** What IS implementable is a strictly weaker but
genuinely protective control. This document records the evidence for that claim
first, because everything downstream depends on it.

## STEP 0 — what a `UserPromptSubmit` hook can do

Measured against the installed binary, **Claude Code 2.1.251**
(`/Users/rj/.local/share/claude/versions/2.1.251`, `claude --version` → `2.1.251`).

| Capability | Verdict |
|---|---|
| (a) BLOCK the prompt before it is transmitted | **YES** |
| (b) REWRITE / substitute the prompt text that reaches the model | **NO — impossible** |
| (c) ADD context alongside the untouched original text | **YES** |

### (b) is impossible — the field does not exist

Searching the binary for every plausible rewrite field name:

```
$ strings -a /Users/rj/.local/share/claude/versions/2.1.251 \
    | grep -oE '(updatedPrompt|modifiedPrompt|replacePrompt|rewritePrompt|updatedInput|promptOverride)' \
    | sort | uniq -c
  10 replacePrompt
 345 updatedInput
```

`updatedPrompt`, `modifiedPrompt`, `rewritePrompt`, `promptOverride`: **zero hits.**
The two that do appear are both false leads:

- All 10 `replacePrompt` hits are unrelated internal state setters —
  `replacePromptId`, `replacePromptIndex`, `replacePromptCache1hAllowlist`.
- `updatedInput` is the **PreToolUse** tool-input mutation field. It rewrites tool
  *arguments*, never prompt text.

The prompt-submit path itself confirms it. From the same binary:

```js
var JX=(e)=>e.origin?.kind==="plugin"?Rhe(e.text,e.origin.name,{midTurn:!1}):e.text;
var E9=(e,t,r)=>({proceeds:{text:e,sessionTitle:t,...r!==void 0&&r.length>0&&{context:r}}});
var W6e=(e,t,r)=>!e?{ended:XX()}:e.blocked?{...}:{...E9(JX(t),r,t.context),...};
```

On the proceed path the transmitted text is `JX(t)` → `t.text`, the **original**
prompt. Anything a hook returns arrives as a *separate* `context` field. There is
no code path in which hook output replaces `text`.

**Empirical falsification.** A throwaway hook returned every plausible rewrite field
at once (`updatedPrompt`, `modifiedPrompt`, `replacePrompt`, `updatedInput.prompt`,
top-level `prompt`), each set to `REPLACEDMARKERBBB`, plus an `additionalContext` of
`INJECTEDMARKERCCC`. The prompt contained `ORIGINALMARKERAAA`, and asked the model to
list every marker it could see. The model replied:

```
ORIGINALMARKERAAA
INJECTEDMARKERCCC
```

`REPLACEDMARKERBBB` never appeared. The original text was transmitted verbatim and
the hook's output was merely appended. **(b) is falsified, not merely undocumented.**

### (a) works, and the block is genuinely pre-transmission

A hook exiting 2 blocks the prompt:

```
UserPromptSubmit operation blocked by hook:
[…/blockhook.sh]: HOOK SAYS: canary found, blocking this prompt

Original prompt: Reply with the single word OK. ZZCANARYZZ
```

The decisive part is the machine-readable receipt from the same run
(`--output-format json`):

```json
"duration_api_ms": 0,  "num_turns": 0,  "total_cost_usd": 0,
"usage": { "input_tokens": 0, "output_tokens": 0, ... },  "modelUsage": {}
```

**Zero input tokens, zero API milliseconds, zero cost.** No request was made. This is
not an inference from source reading — it is the harness's own accounting, and it is
the strongest evidence in this document. The binary agrees: the blocked branch returns
`shouldQuery:!1`.

Claude Code's *own* fail-closed message for the case where the hooks did not run
confirms the gate sits before transmission:

```
Prompt blocked: the UserPromptSubmit hooks did not run over the submitted text.
```

### The echoed `Original prompt:` is local-only — verified, not assumed

The block message prints your original text back to your terminal so you can recover
it. That echo is **local**. Resuming the blocked session and asking the model what it
could see:

```
$ claude -p "List verbatim every message that exists in this conversation before
             this one. If there are none, reply exactly NOTHING_BEFORE." \
         --resume c2b28e73-8fb2-43bc-98d7-7452727b0d46
NOTHING_BEFORE
```

The blocked turn left no trace in the transmitted conversation. A secret caught by
the filter is not leaked on the blocking turn *or* on any later turn of that session.

## The design this forces: BLOCK-AND-COACH

Because (b) is impossible, seamless substitution cannot be built. The honest design is:

1. Detect credential shapes in the submitted prompt.
2. Store each value locally, `0600`, gitignored, and mint a reference
   `{{HMD_SECRET_N}}`.
3. **Refuse the prompt** (exit 2) and tell the user which references were minted.
4. The user re-sends using the reference instead of the value.

Less seamless than substitution, but it genuinely prevents transmission — which
substitution-by-hook cannot do at all, because it does not exist.

## Limitations — read this before trusting the filter

- **Nothing client-side can un-send a value already transmitted.** If a secret was
  pasted before this filter existed, or while it was disabled, or in a shape the
  detector does not know, it is on the wire and must be **rotated**. Treat rotation,
  not this filter, as the remedy for an exposed key.
- **A detector never catches every secret shape.** This one is tuned for *precision*
  over recall on purpose (see below). Unknown-shaped credentials — an internal token
  format, a bare password, a connection string with an unusual key name — pass through.
- **Precision/recall trade, chosen deliberately.** False positives are the failure
  mode that kills the feature: a filter that fires on ordinary code gets switched off,
  and then it protects nothing. Known misses, accepted knowingly:
  - values under 16 characters (`password=hunter2`),
  - all-lowercase-alphabetic values (`password=correcthorsebatterystaple`),
  - pure-hex values, excluded so git SHAs and hashes never trip it,
  - UUIDs, excluded for the same reason.
- **The vault is plaintext-equivalent.** It is protected by `0600` file permissions
  and nothing more — the same threat model as `~/.aws/credentials` or `~/.ssh/id_rsa`.
  Anyone who can read your user account can read it. It is not encrypted, because a
  key to decrypt it would itself have to be stored somewhere on the same disk.
- **Retrieval can leak if you use the wrong verb.** `get` prints the value to stdout.
  If an agent runs that inside a Bash tool call, the value lands in the tool output —
  which *is* transmitted. Use `exec` (env-injection into a child process, value never
  printed) for anything an agent might run. This is the sharpest edge in the design.
- **It only covers the prompt-submit path.** A secret read off disk by a tool, echoed
  by a command, or included in a file the model reads is out of scope entirely.
- **`HMD_SECRET_FILTER=off` disables it,** and the block message says so. That is
  deliberate: a security control users cannot turn off gets worked around in worse
  ways. Turning it off transmits the secret.

## What it can guarantee

Exactly one thing, and it holds firmly: **for a credential shape the detector
recognizes, in a prompt you submit while the filter is enabled, the value is not
transmitted** — proven by `input_tokens: 0` on the blocked turn, and by
`NOTHING_BEFORE` on the following one.
