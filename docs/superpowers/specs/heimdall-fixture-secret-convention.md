# Heimdall — Test-Fixture Secret Convention

The rule that keeps the gitleaks gate honest without ever blinding it.

## The rule

Test fixtures MUST NOT commit a real-format secret string. Two cases, two
treatments:

1. **Token-shaped input** (a fixture string that only exercises a code path —
   config parsing, redaction checks, "must not be echoed" assertions): use an
   obviously-fake, NON-MATCHING sentinel value. Break the secret's character run
   so the gitleaks rule does not fire (e.g. `REDACTED_SENTINEL_not_a_real_token`,
   `ghp_<<FAKE_TEST_PAT>>`). The test still gets its token-shaped input; the gate
   has nothing to flag.

2. **Gate-proof tokens** (a fixture that PLANTS a credential to prove the gate
   CATCHES it — a "secret-scan must fire" assertion): the token MUST be a real
   gitleaks match at RUNTIME, but MUST NOT exist as a static literal in source.
   Assemble it at runtime from fragments that are each individually non-matching;
   only the concatenation forms the detectable token. The canonical pattern is in
   `test/selfscan.test.sh`:

   ```sh
   _GP_PRE="ghp_"; _GP_A="0123456789abcdefghij"; _GP_B="ABCDEFGHIJ012345"
   PLANT_TOK="${_GP_PRE}${_GP_A}${_GP_B}"   # ghp_+36 at runtime; no literal in source
   ```

## Why

A real-format secret string committed in a fixture forces a choice between two
bad options: (a) let the bare scan flag it as a false positive (blocks every
push), or (b) path-allowlist the fixture file — which blinds the gate to a
GENUINE leaked credential checked in beside that fixture. Runtime assembly
removes the choice: source carries no secret, history carries no secret, the gate
stays fully armed on every path, and the gate-catch proof still fires on the
runtime value.

## Enforcement

- Bare `gitleaks detect` over the tree finds ZERO matches in fixture files.
- A fixture file should NEVER appear in `.gitleaks.toml`'s `paths` allowlist. The
  allowlist is reserved for sources whose secret-shaped strings are inherent to
  the tool (rule-definition strings in `bin/secret-scan`, `bin/corpus`, the demo).
  A new fixture-path allowlist entry is a code smell — fix the fixture instead.
- Reviewers reject any new committed string matching a gitleaks high-signal rule
  (`ghp_[A-Za-z0-9]{36}`, `AKIA[0-9A-Z]{16}`, `sk_live_…`, PEM private keys, etc.)
  in a test fixture; require the runtime-assembly pattern instead.
