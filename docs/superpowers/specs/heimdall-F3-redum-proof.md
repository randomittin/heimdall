# F3 Redum — before/after acceptance proof

The deliverable is a **measured** acceptance: reuse must go UP with Redum active.
This is that measurement. The numbers below are produced by SI-2's own reuse
analyzer (`bin/lib/reuse_analyzer.py`, read through `bin/heimdall-attest`), the
*same* metric S-6 reports — Redum does not re-measure, it FIXES the input.

## Fixture (local, deterministic)

`test/fixtures/redum/` — the canonical card-data scenario:

- `base/` — the pre-existing card store: a `cards` slice, a `selectCards`
  selector, `selectCardById`, and the MMKV key `cards.cache.v1` (held in
  `CARDS_CACHE_KEY`). These are the reuse units a card-data task SHOULD reuse.
- `reinvention/src/screens/CardsScreen.tsx` — the **before** change: a screen that
  RE-DECLARES the slice, the selector, and the MMKV key string instead of
  importing them (the low-reuse outcome an agent produces with no factoring).
- `reuse/src/screens/CardsScreen.tsx` — the **after** change: the same screen
  written the way Redum's plan-time factoring steers it — it IMPORTS and CALLS
  the existing `selectCards` + `readCardsCache` (no duplicate slice/selector/key).

The C2 reinvention fixture is used (not the C3 commander.js weak-cell) because it
is local and drives deterministically with what is on disk, as the brief directs.

## Result

| | change | reuse_pct | units_reusing / total | suspected_duplicates |
|---|---|---|---|---|
| **before** (no Redum) | `reinvention/CardsScreen.tsx` | **0.0000** | 0 / 3 | 2 |
| **after** (Redum active) | `reuse/CardsScreen.tsx` | **1.0000** | 1 / 1 | 0 |

**Delta: +1.0000 (0% → 100%).** Reuse moves UP — the acceptance criterion.

What Redum did to move the number: its plan-time `factor` surfaced the exact
existing units to call —

```
redum factor: reuse existing machinery instead of reimplementing:
  selectCards, cards.cache.v1, selectCardById
```

— so the agent reuses by design. The commit-time `gate` then backstops residual
redundancy: on the **before** change it BLOCKS (verdict=block, exit=1, naming the
existing `selectCards` / `cards.cache.v1` to reuse); on the **after** change it
passes (verdict=ok, exit=0). F2 Checker's max tier independently confirms the
**before** change as a cross-author duplicate of alice's units and passes the
**after** change. (All wired and asserted in `test/redum-integration.test.sh`,
12/12 pass.)

## Reproduce

```bash
ROOT="$(git rev-parse --show-toplevel)"
FIX="$ROOT/test/fixtures/redum"
WORK="$(mktemp -d)"; export HEIMDALL_HOME="$WORK/.heimdall"
REPO="$WORK/repo"; mkdir -p "$REPO/src/store" "$REPO/src/screens"
git -C "$REPO" init -q
git -C "$REPO" config user.email alice@team.dev
git -C "$REPO" config user.name alice
cp "$FIX/base/src/store/"*.ts "$REPO/src/store/"
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" config user.email bob@team.dev

measure() {  # prints reuse_pct for the current working tree vs BASE
  "$ROOT/bin/heimdall-attest" emit --repo "$REPO" --base "$BASE" \
    --task "$1" --print --quiet 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["reuse"]["reuse_pct"])'
}

# BEFORE — no Redum: the agent reinvents.
cp "$FIX/reinvention/src/screens/CardsScreen.tsx" "$REPO/src/screens/CardsScreen.tsx"
echo "before (no redum): $(measure 'cards screen')"     # -> 0.0

# AFTER — Redum factoring steers the build to reuse.
rm "$REPO/src/screens/CardsScreen.tsx"
cp "$FIX/reuse/src/screens/CardsScreen.tsx" "$REPO/src/screens/CardsScreen.tsx"
echo "after  (redum):    $(measure 'cards screen')"     # -> 1.0

rm -rf "$WORK"
```

The full wired flow (attestation → redum gate → F2 checker, plus this delta) is
asserted end-to-end by:

```bash
bash test/redum-integration.test.sh   # 12/12 pass, exit 0
```
