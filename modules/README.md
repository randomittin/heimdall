# The module registry

Optional capability modules for hmd. **The base install ships the system and
zero module payloads** — this directory holds manifests and class contracts, not
code. Driven by `bin/heimdall-modules`; gated by `test/modules-lifecycle.test.sh`.

The registry **is this repo**. A pin is a reviewed commit, not a network lookup,
so there is no code path that resolves "latest" and none that clones a payload.
**Depend, don't clone.**

## Layout

```
modules/
  _classes/<class>.json      four permission-class contracts
  <name>/manifest.json       one module, at a pin
```

A module directory holds its `manifest.json` and nothing else unless
`installs_via.kind` is `local`, in which case it also holds the pinned artifact.
The lifecycle test enforces that no module directory grows a vendored payload.

## Manifest schema

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | must equal the directory name |
| `description` | yes | one line, shown by `hmd modules list` |
| `upstream` | yes | where the thing actually comes from |
| `license` | yes | the upstream licence |
| `pinned_version` | yes | `{version, artifact, artifact_sha256}` — 64 lowercase hex |
| `permission_class` | yes | one of the four classes; **never defaulted** |
| `installs_via` | yes | `{kind:"local", artifact_path}` or `{kind:"upstream", fetch}` |
| `wires` | yes | array of `{kind, target}`; may be empty (reported as inert) |
| `invariants` | yes | `{<id>: {command, expect?, expect_exit?, timeout_sec?}}` |
| `tier` | yes | `available` or `suggested` |
| `tier_evidence` | if `suggested` | `{receipt}` — a green pre-registered A/B or equivalent |
| `consent_text` | if the class requires consent | what the operator is agreeing to |

A manifest with a missing or unknown `permission_class` is **refused, not
defaulted** — the class decides consent and which invariants are enforced, so
choosing one silently would be choosing a security posture on the operator's
behalf.

## Class contracts

Each `_classes/<class>.json` carries `consent_required` plus a
`requires_invariants` list, and the harness **discovers what to enforce by
reading that file**. Nothing is hardcoded per module; adding a class is a JSON
file, not a patch to the binary.

Each required invariant declares a check of one of two kinds:

- **`suite`** — the class owns the command. Used where the repo already holds
  the falsifier. `traffic-proxy` and `storage-codec` both consume
  `test/gate-judgment-uncompressed.test.sh` pinned at `25 passed, 0 failed`.
  That suite must never be weakened: the classes consume it, so softening it
  turns every module in those classes green for free.
- **`manifest`** — the module owns the command, under `invariants.<id>.command`.
  Used where only the module knows how to drive itself (a codec's round-trip, an
  adapter's wrap/unwrap).

A manifest that does not cover every required invariant is refused and the
message names the uncovered ids.

| Class | Consent | Enforces |
| --- | --- | --- |
| `traffic-proxy` | required | gates read raw · non-interactive passthrough · CP/enroll/signed traffic never routed |
| `storage-codec` | not required | round-trip fidelity · silent plain fallback when absent · never touches judgment inputs |
| `rule-pack` | not required | rules ship falsifiers · attribution preserved |
| `tool-adapter` | required | wrap/unwrap byte-identical · hooksPath / AGENTS.md fence preserved |

Checks run under a hard wall-clock alarm, from repo-tracked content — a manifest
lands through review exactly like any other file.

## Lifecycle

The order is the contract:

```
validate → class contract → consent → install + digest-verify → wire → invariants
```

Everything before `install` is read-only, so a manifest rejected at validate,
class or consent mutates nothing. From `install` onward every failure unwinds
through the **same removal path `remove` uses** — so a module that fails its own
class test leaves no trace, byte-identically. Wiring precedes invariants
deliberately: the contracts assert behaviour *with the module active*, so the
checks must run against a wired module or they prove nothing.

Digests are reported honestly. A `local` artifact is hashed at install and a
mismatch is refused; an `upstream` dependency has nothing on disk to hash yet, so
its receipt reads `deferred-upstream` and records the pin rather than claiming a
verification that did not happen.

`update` moves to the pin the manifest already holds — which a human edited and
committed. At the current pin it is a no-op.

## Tiers

`available` → `suggested`. A `suggested` module must carry `tier_evidence` or it
is refused: a recommendation without evidence is an advertisement. The tier
controls how loudly hmd **recommends** a module. It never controls whether one
installs — **nothing self-installs, ever.**

## Commands

```
hmd modules                 # list; honest when nothing is installed
hmd modules add <name>      # the full ordered pipeline
hmd modules remove <name>   # total removal
hmd modules update [<name>] # move to the manifest's human-set pin
hmd modules status <name>   # one module in detail
hmd modules verify [<name>] # re-run class invariants (the CI entry point)
```

All verbs accept `--json`; `add` accepts `--yes` to grant consent
non-interactively. `--registry` and `--state` relocate the registry and install
state, which is how the test suite runs hermetically.
