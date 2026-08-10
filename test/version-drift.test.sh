#!/usr/bin/env bash
#
# version-drift.test.sh — the version-drift gate: plugin.json is the SINGLE SOURCE.
#
#   bash test/version-drift.test.sh     (exit 0 = every surface agrees with plugin.json)
#
# .claude-plugin/plugin.json .version is authoritative. EVERY other surface in the repo
# that names the plugin version must equal it. This test goes RED the instant any one of
# them drifts. It is the gate that would have caught the live defect it was written for:
# packages/runheimdall/package.json sat at 2.0.5 while the manifest was at 2.2.6 — the npx
# wrapper `npx runheimdall` was installing a months-stale release, and nothing was red.
#
# Surfaces gated (each is RENDERED from the manifest, never hand-typed):
#   1. VERSION                              — bin/heimdall-render-version
#   2. README.md generated region + no stale semver pin anywhere in the file
#                                           — bin/heimdall-render-version
#   3. packages/runheimdall/package.json    — .version, .heimdall.tag, .heimdall.installScriptUrl
#                                           — release/sync-release.sh
#   4. vercel.json /install redirect target — release/sync-release.sh
#   5. _redirects  /install redirect target — release/sync-release.sh
#   6. install.sh  DEFAULT_REF              — release/ship.sh bump_default_ref
#   7. the marketing SITE (a SIBLING repo)  — hand-maintained; see below
#   8. every PINNED INSTALL DIGEST (sha256) — DISCOVERED by shape, never listed; see below
#
# Surface 7 is the runheimdall.dev checkout, which is NOT a subdirectory of this repo. Its
# version strings are hand-typed and nothing gated them, so they drifted three different ways
# at once while the plugin shipped 2.3.8: the <meta heimdall-version> tags sat at v2.0.16 and
# v2.2.2, the index.html JSON-LD softwareVersion at 2.3.3, and the llms-full.txt install URL
# at v2.2.6. That is how a public install one-liner reaches v2.0.16. Absent checkout =>
# SKIPPED and said out loud, never a failure — a contributor without the site must not eat a
# red. Point HEIMDALL_SITE_DIR at it to override the default sibling location.
#
# Scoped to FULL three-part semver (X.Y.Z). Two-part strings that are NOT the plugin
# version ("Claude Code 1.0+", "0.50 median reuse") are not version pins and are ignored.
# On the site this scoping matters more, not less: published pages legitimately name OTHER
# software's versions in prose (a pinned google-cloud-firestore==2.16.1, superx v1.1.0, the
# v2.0.5 incident write-up), so this gate asserts the SPECIFIC version-bearing fields listed
# above rather than sweeping every semver on the page.
#
# Surface 8 is a DIFFERENT defect class from 1-7: not a version that drifted, but a sha256
# that no longer describes the bytes it is printed next to. The published install command is
# an `&&` chain — curl → `shasum -a 256 -c -` → bash — so a wrong digest does not degrade the
# install, it ABORTS it: `shasum -c` prints FAILED and nothing after the `&&` ever runs. That
# shipped. README.md pinned fafe31e3… for an install.sh that really hashes to 28bbdcd…, so the
# primary install path advertised on the repo's front page was dead while every check above
# stayed green — and heimdall-site/netlify.toml carried the CORRECT digest at the same moment,
# so the two published surfaces contradicted each other and nothing noticed.
#
# Digest surfaces are therefore DISCOVERED BY SHAPE — an exactly-64-char hex token within
# DIGEST_WINDOW lines of a raw.githubusercontent install URL — and never from a hardcoded file
# list. A hardcoded list is the mechanism of the original defect: README.md would have been on
# it; netlify.toml and llms-full.txt would not. Two independent assertions run per discovery:
#   (a) CROSS-SURFACE — every digest pinned against the same ref must be identical. Pure string
#       comparison: no network, no git, catches the shipped defect on a plane.
#   (b) DIGEST↔BYTES  — each digest must equal the real sha256 of install.sh at the ref its own
#       URL fetches. Resolved OFFLINE from local git objects when the ref is in the checkout
#       (works in CI, offline, and when GitHub is rate-limited); a bounded network fetch is the
#       fallback ONLY for a ref this checkout does not have. An unreachable network yields a
#       loud SKIP that earns no PASS — never a quiet green.
#
# R6: this gate ships with a corrupt-and-confirm proof — `--self-test` plants a drift in a
# THROWAWAY copy of the repo, asserts the gate reports it, and restores nothing (the copy is
# discarded). A gate that cannot demonstrate going red proves nothing.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${VERSION_DRIFT_REPO:-$(cd "$SELF_DIR/.." && pwd)}"

# ── --self-test: the corrupt-and-confirm proof promised above ─────────────────
# Every mutation happens in a `mktemp -d` throwaway copy reached through the
# VERSION_DRIFT_REPO override; the real tree is never written to.
if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  SITE_TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP" "$SITE_TMP"' EXIT

  # Repo mutants must be blind to the real site: if the live site were drifted, every
  # one of them would "correctly go RED" with the mutation removed, and the proof
  # would be worth nothing. NO_SITE is never created.
  NO_SITE="$TMP/no-site-here"
  MUT_SITE="$NO_SITE"

  SELF_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$REPO/.claude-plugin/plugin.json" | head -1)"
  SELF_TAG="v$SELF_VER"

  # set_version <json-file> <semver> — rewrites the single top-level .version.
  # plugin.json and packages/runheimdall/package.json each carry exactly one
  # "version" key, so this is unambiguous without depending on jq being installed.
  set_version() {
    sed 's/"version"[[:space:]]*:[[:space:]]*"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"/"version": "'"$2"'"/' "$1" > "$1.mut" \
      && mv "$1.mut" "$1"
  }

  # ── Fixture for the digest mutants (surface 8) ─────────────────────────────
  # A digest mutant only proves something if the fixture it perturbs was CORRECT first:
  # mutating an already-drifted pin would "go red" with the mutation removed. TRUE_DIGEST is
  # the real sha256 of install.sh at $SELF_TAG, resolved exactly the way the gate resolves it.
  SELF_OWNER="$(bash "$SELF_DIR/version-drift.test.sh" --list-digests 2>/dev/null | awk -F'|' 'NF{print $3; exit}')"
  TRUE_DIGEST=""
  if git -C "$REPO" cat-file -e "$SELF_TAG:install.sh" 2>/dev/null; then
    TRUE_DIGEST="$(git -C "$REPO" show "$SELF_TAG:install.sh" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  elif [ -n "$SELF_OWNER" ]; then
    SELF_FETCH="$(mktemp)"
    curl -fsSL --max-time 15 -o "$SELF_FETCH" \
      "https://raw.githubusercontent.com/$SELF_OWNER/heimdall/$SELF_TAG/install.sh" 2>/dev/null \
      && TRUE_DIGEST="$(shasum -a 256 "$SELF_FETCH" | awk '{print $1}')"
    rm -f "$SELF_FETCH"
  fi
  if [ -z "$TRUE_DIGEST" ] || [ -z "$SELF_OWNER" ]; then
    echo "  ✗ SELF-TEST CANNOT RUN: $SELF_TAG:install.sh is not in this checkout and the network is unreachable — the digest mutants need the real bytes to mutate away from" >&2
    exit 1
  fi

  # normalize_digests <root> — repoint every discovered repo-side install URL at $SELF_TAG
  # and rewrite every pinned digest to that tag's true hash, yielding a fixture that is
  # correct by construction. The file list comes from the gate's OWN --list-digests, so a
  # newly added digest surface is normalised automatically instead of quietly falling out
  # of this proof the day someone adds one.
  normalize_digests() {
    local root="$1" rel f
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      f="$root/$rel"
      [ -f "$f" ] || continue
      sed -e "s#\(raw\.githubusercontent\.com/[^/]*/heimdall/\)[^/]*\(/install\.sh\)#\1$SELF_TAG\2#g" \
          -e "s#[0-9a-fA-F]\{64\}#$TRUE_DIGEST#g" "$f" > "$f.norm" && mv "$f.norm" "$f"
    done <<NORM
$(VERSION_DRIFT_REPO="$root" HEIMDALL_SITE_DIR="$NO_SITE" bash "$SELF_DIR/version-drift.test.sh" --list-digests 2>/dev/null | awk -F'|' 'NF&&$4=="repo"{print $5}' | sort -u)
NORM
  }

  # A pristine throwaway repo that is green before anything is planted, so a red can only
  # be attributable to the mutation planted after it.
  fresh_copy() {
    cp -R "$REPO/." "$TMP/" 2>/dev/null
    normalize_digests "$TMP"
  }

  # reset_site — a scratch site checkout with NOTHING left over from the previous mutant.
  # Overwriting one file is not enough once a mutant plants a whole subtree: a leftover
  # fixture would make the next mutant's red (or green) unattributable to its own plant.
  reset_site() {
    rm -rf "$SITE_TMP"
    mkdir -p "$SITE_TMP"
  }

  # assert_red <label> <expected-substring> — require BOTH a non-zero exit AND the
  # SPECIFIC failure the mutation should have caused. Asserting the reason rather
  # than a pass/fail count is deliberate: counts shift every time a surface is added,
  # which trains people to "just update the number" instead of reading the failure.
  assert_red() {
    local label="$1" want="$2" out summary
    if out="$(VERSION_DRIFT_REPO="$TMP" HEIMDALL_SITE_DIR="$MUT_SITE" bash "$SELF_DIR/version-drift.test.sh" 2>&1)"; then
      echo "  ✗ SELF-TEST FAILED: gate stayed GREEN with $label planted" >&2
      exit 1
    fi
    case "$out" in
      *"$want"*) ;;
      *) echo "  ✗ SELF-TEST FAILED: RED for the wrong reason with $label planted (wanted: $want)" >&2
         printf '%s\n' "$out" >&2
         exit 1 ;;
    esac
    summary="$(grep -E '^version-drift.test.sh:' <<<"$out" | tail -1)"
    echo "  ✓ RED on $label — ${summary:-<no summary line>}"
  }

  # assert_green <label> — the inverted direction. Without this, a mutant that goes
  # red for an unrelated reason looks like a working proof.
  assert_green() {
    local label="$1" out
    if out="$(VERSION_DRIFT_REPO="$TMP" HEIMDALL_SITE_DIR="$MUT_SITE" bash "$SELF_DIR/version-drift.test.sh" 2>&1)"; then
      echo "  ✓ GREEN on $label"
    else
      echo "  ✗ SELF-TEST FAILED: gate went RED on $label" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
  }

  echo "version-drift --self-test: asserting the gate goes RED on planted drift"

  # Mutant 1 — the SINGLE SOURCE itself moves. Every rendered surface must disagree.
  fresh_copy
  set_version "$TMP/.claude-plugin/plugin.json" 9.9.9
  assert_red "plugin.json .version=9.9.9" "VERSION drift"

  # Mutant 2 — THE HISTORICAL LIVE DEFECT. packages/runheimdall/package.json sat at
  # 2.0.5 while the manifest was current, so `npx runheimdall` fetched a months-stale
  # installScriptUrl and installed a months-stale Heimdall with nothing red. This is
  # the regression that actually happened in production; it stays in the proof set.
  fresh_copy
  set_version "$TMP/packages/runheimdall/package.json" 2.0.5
  assert_red "runheimdall package.json .version=2.0.5" "runheimdall package.json drift"

  # Mutants 3+4 — the SITE block, both directions. A site surface that is never proven
  # able to go red is exactly how the site drifted to v2.0.16 unnoticed. proof.html (not
  # index.html) carries the planted tag so ONLY the meta assertion is in play.
  fresh_copy
  MUT_SITE="$SITE_TMP"
  printf '<meta name="heimdall-version" content="v0.0.1">\n' > "$SITE_TMP/proof.html"
  assert_red "site meta heimdall-version=v0.0.1" "site meta heimdall-version drift"

  printf '<meta name="heimdall-version" content="%s">\n' "$SELF_TAG" > "$SITE_TMP/proof.html"
  assert_green "site meta heimdall-version=$SELF_TAG"

  # Mutant 5 — degrade, don't crash: no site checkout must never mean a red.
  MUT_SITE="$NO_SITE"
  assert_green "no site checkout (skipped, not failed)"

  # ── Digest mutants (surface 8) ──────────────────────────────────────────────

  # Mutant 6 — ONE character of a published digest is wrong. That is not a cosmetic typo:
  # `shasum -c` prints FAILED, the `&&` chain stops, and the advertised install is dead.
  fresh_copy
  MUT_SITE="$NO_SITE"
  # Remap only the first nibble through a fixed permutation — every hex char maps to a
  # different one, so the result is always a well-formed digest that always differs.
  BENT_DIGEST="$(printf '%s' "$TRUE_DIGEST" | cut -c1 | tr '0123456789abcdef' '1234567890badcfe')$(printf '%s' "$TRUE_DIGEST" | cut -c2-)"
  sed "s#$TRUE_DIGEST#$BENT_DIGEST#g" "$TMP/README.md" > "$TMP/README.md.mut" \
    && mv "$TMP/README.md.mut" "$TMP/README.md"
  assert_red "README install digest bent by one character" "does NOT match the bytes it claims to describe"

  # Mutant 7 — two WELL-FORMED surfaces pinning different digests for the same ref. This is
  # the shipped defect's exact shape (README.md vs heimdall-site/netlify.toml), and it is
  # caught with no network and no git: string comparison across discovered surfaces alone.
  fresh_copy
  MUT_SITE="$SITE_TMP"
  OTHER_DIGEST="$(printf '%s' "$TRUE_DIGEST" | tr '0123456789abcdef' '1234567890badcfe')"
  { printf '<meta name="heimdall-version" content="%s">\n' "$SELF_TAG"
    printf 'curl -fsSL https://raw.githubusercontent.com/%s/heimdall/%s/install.sh -o heimdall-install.sh\n' "$SELF_OWNER" "$SELF_TAG"
    printf 'echo "%s  heimdall-install.sh" | shasum -a 256 -c -\n' "$OTHER_DIGEST"
  } > "$SITE_TMP/proof.html"
  assert_red "two surfaces pinning different digests for $SELF_TAG" "DISAGREEMENT"

  # Mutant 8 — THE DEFECT THAT SHIPPED, byte for byte. README.md pinned this digest while the
  # install.sh it pointed at really hashed to something else, so the front-page install
  # aborted at `shasum -c` and every version gate stayed green through it. Permanent.
  fresh_copy
  MUT_SITE="$NO_SITE"
  SHIPPED_BAD_DIGEST="fafe31e30b481882a43ab93aaab742b1e90b0d4bde31498aa8f58f3f23585b33"
  sed "s#$TRUE_DIGEST#$SHIPPED_BAD_DIGEST#g" "$TMP/README.md" > "$TMP/README.md.mut" \
    && mv "$TMP/README.md.mut" "$TMP/README.md"
  assert_red "the shipped defect: README pins $SHIPPED_BAD_DIGEST" "pinned $SHIPPED_BAD_DIGEST, actual"

  # Mutant 9 — the anti-vacuous guard. Strip every pinned digest and the sweep must FAIL,
  # not sail through green because it had nothing left to assert over.
  fresh_copy
  MUT_SITE="$NO_SITE"
  while IFS= read -r void_rel; do
    [ -n "$void_rel" ] || continue
    sed "s#[0-9a-fA-F]\{64\}#DIGEST-REMOVED#g" "$TMP/$void_rel" > "$TMP/$void_rel.mut" \
      && mv "$TMP/$void_rel.mut" "$TMP/$void_rel"
  done <<VOID
$(VERSION_DRIFT_REPO="$TMP" HEIMDALL_SITE_DIR="$NO_SITE" bash "$SELF_DIR/version-drift.test.sh" --list-digests 2>/dev/null | awk -F'|' 'NF&&$4=="repo"{print $5}' | sort -u)
VOID
  assert_red "every pinned digest removed" "VACUOUS"

  # ── Scaffolding-exclusion mutants (surface 7) ────────────────────────────────
  # These three pin the FALSE-POSITIVE class, in all three directions: the fixture must be
  # ignored, a real published surface beside it must still be caught, and an exclusion that
  # swallows the whole site must go red rather than green.

  # Mutant 10 — A GATE'S OWN FIXTURE IS NOT DRIFT. heimdall-site/gates/copy-parity.js pins
  # LIVE_TAG='v9.9.9' on purpose (its whole method is to drive the page with a tag that
  # differs from the pinned one) and NAMES the meta tag inside a throw-message string it does
  # not declare. The sweep read both as shipped drift and went red against a clean site. That
  # is the worst kind of red — wrong, and therefore training everyone to ignore the next one.
  fresh_copy
  reset_site
  MUT_SITE="$SITE_TMP"
  printf '<meta name="heimdall-version" content="%s">\n' "$SELF_TAG" > "$SITE_TMP/proof.html"
  mkdir -p "$SITE_TMP/gates"
  { printf "const LIVE_TAG = 'v9.9.9';   // != the pinned tag, on purpose\n"
    printf "if (!m) throw new Error('no <meta name=\"heimdall-version\"> found');\n"
  } > "$SITE_TMP/gates/copy-parity.js"
  assert_green "site gates/ fixture pinning v9.9.9 (scaffolding, not a published surface)"

  # Mutant 11 — THE EXCLUSION MUST NOT BE TOO BROAD. Same fixture still in place, but now a
  # PUBLISHED file carries a genuinely stale fallback literal. Check (d) is one of the two the
  # false positive fired on, so it is precisely the check at risk of being neutered by the fix;
  # an over-broad rule would swallow this too and the gate would go quietly, wrongly green.
  printf "const FALLBACK = 'v0.0.1';\n" > "$SITE_TMP/version.js"
  assert_red "real fallback drift in a published file beside an excluded fixture" \
             "site JS version fallback drift"

  # Mutant 12 — the exclusion's OWN anti-vacuous guard. A checkout that is entirely scaffolding
  # must go RED for having examined nothing, never sail through green on an empty set. This is
  # the exact shape of the sibling gate's shipped bug: a filter discarded every hit and the
  # check passed vacuously with a real defect planted.
  reset_site
  mkdir -p "$SITE_TMP/gates"
  printf "const LIVE_TAG = 'v9.9.9';\n" > "$SITE_TMP/gates/copy-parity.js"
  assert_red "site checkout that is entirely scaffolding" "examined ZERO published files"

  echo "version-drift --self-test: PASS"
  exit 0
fi

# ── Scaffolding exclusion — ONE rule, applied at TRAVERSAL, shared by both sweeps ────
# A gate's own FIXTURES carry deliberately-wrong data. heimdall-site/gates/copy-parity.js
# pins LIVE_TAG='v9.9.9' because its whole method is to drive each page with a tag that
# DIFFERS from the pinned one (a copy handler tracking the live tag on only one side has to
# fail there), and it names <meta name="heimdall-version"> inside a throw-message for a tag
# it does not declare. Reading either as a shipped version string is a FALSE RED — and a red
# that is WRONG is worse than no gate at all: the human who investigates once, finds "oh,
# it's just a fixture", and moves on has been trained to ignore the next red too, including
# a true one. Both false positives were live here: '<unparseable>' and 'v9.9.9'.
#
# The rule is DIRECTORY ROLE, never a filename blocklist. Both repos keep verification
# scaffolding in a dedicated directory — this repo in test/ and conformance/gates/ (whose
# contents are *.fixture.sh), the site in gates/ — and publish everything else. Naming
# copy-parity.js would rot the moment a second fixture lands; naming the ROLE does not.
# Role-scoping also preserves the sweep's entire reason to exist: it still discovers NEW
# published surfaces the day someone adds a page, which narrowing to a list of today's
# known-good files would destroy.
#
# Matched by BASENAME (-name), never by path substring, and applied to TRAVERSAL rather
# than to result strings. That is not a style preference — it is this session's other bug:
# a sibling gate filtered its results with `grep -v '/.claude/worktrees/'` while $ROOT was
# ITSELF inside a worktree, so the filter discarded every hit and the check went green with
# a real defect planted. A result-string filter can silently match everything; a prune by
# directory name cannot.
SCAFFOLDING_DIRS="test tests gates node_modules"

# Dated archives are pruned by that same one mechanism, and for the reason already given two
# paragraphs up for .planning/: a dated document is history, not drift. launch-docs/drafts/
# holds weekly changelogs whose lines are verbatim git commit subjects — `chore(release):
# v2.3.8 (063155f)` is a quotation of what commit 063155f actually said. It agrees with the
# manifest this week by coincidence and will disagree at the next bump, at which point this
# sweep would report a drift whose only correct fix is to falsify the record. A gate that can
# only be satisfied by lying is a gate that gets deleted, so it must not ask.
# test/version-pin-conformance.test.sh prunes the identical set and makes it prove, every run,
# that what it removed really was archival.
ARCHIVE_DIRS="drafts archive"

# find_files <mode> <root> <ext>...
#   published  — prune dot-dirs AND scaffolding; the set the sweeps actually assert over.
#   candidates — prune dot-dirs only; the denominator, so the sweep can REPORT how many
#                files its own exclusion removed instead of removing them silently.
#
# Dot-dirs are pruned in both modes: .git is binary object storage, and .planning archives
# design comps and incident write-ups pinned to long-dead tags (v2.0.5) — history, not drift.
#
# -mindepth 1 is the other half of the vacuous-filter lesson above: find evaluates the prune
# predicates against the START directory too, so a checkout that happens to BE named `gates`
# would prune its own root and yield ZERO files — a vacuous green from an empty set. Measured
# on this box: `find /tmp/x/gates -type d -name gates -prune -o -type f -print` prints nothing
# at all, while the same command with -mindepth 1 prints every file. (The pre-existing
# `-name '.?*'` rather than '.*' is the same defence for dot-names, and is kept.)
find_files() {
  local mode="$1" root="$2"; shift 2
  local fx d e first=1
  fx=( -mindepth 1 -type d '(' -name '.?*' )
  if [ "$mode" = published ]; then
    for d in $SCAFFOLDING_DIRS $ARCHIVE_DIRS; do fx+=( -o -name "$d" ); done
  fi
  fx+=( ')' -prune -o -type f '(' )
  for e in "$@"; do
    if [ "$first" -eq 1 ]; then
      fx+=( -name "$e" ); first=0
    else
      fx+=( -o -name "$e" )
    fi
  done
  fx+=( ')' -print )
  find "$root" "${fx[@]}" 2>/dev/null | sort
}

# ── Pinned-install-digest discovery (surface 8) ───────────────────────────────
# How close a 64-hex token has to sit to an install URL to be read as that URL's digest.
# The published snippets put them 1 line apart; netlify.toml comments the digest 3 lines
# above the redirect. 8 covers every real layout without reaching across unrelated prose.
DIGEST_WINDOW=8
DIGEST_RECORDS=""
DIGEST_N=0

# scan_one_file <scope> <relpath> <abspath>
# Appends "ref|digest|owner|scope|relpath|line" for each 64-hex token near an install URL.
scan_one_file() {
  local scope="$1" rel="$2" f="$3"
  local urls dl dline dtext dg ul uline urest uo ur best bestd uown d
  # Both shapes must be present or this file cannot pin a digest to a URL.
  grep -qE '[0-9a-fA-F]{64}' "$f" 2>/dev/null || return 0
  grep -qE 'raw\.githubusercontent\.com/[^/]+/heimdall/[^/]+/install\.sh' "$f" 2>/dev/null || return 0

  # "line|owner|ref" for every install URL in the file.
  urls="$(grep -noE 'raw\.githubusercontent\.com/[^/]+/heimdall/[^/]+/install\.sh' "$f" 2>/dev/null \
          | sed -n 's#^\([0-9][0-9]*\):raw\.githubusercontent\.com/\([^/]*\)/heimdall/\([^/]*\)/install\.sh$#\1|\2|\3#p')"
  [ -n "$urls" ] || return 0

  while IFS= read -r dl; do
    [ -n "$dl" ] || continue
    dline="${dl%%:*}"
    dtext="${dl#*:}"
    # Tokenise on non-hex so a 65+ hex run can never yield a bogus 64-char "digest",
    # and so two digests on one line are both seen.
    while IFS= read -r dg; do
      [ -n "$dg" ] || continue
      dg="$(printf '%s' "$dg" | tr 'ABCDEF' 'abcdef')"
      best=""; bestd=-1; uown=""
      while IFS= read -r ul; do
        [ -n "$ul" ] || continue
        uline="${ul%%|*}"; urest="${ul#*|}"; uo="${urest%%|*}"; ur="${urest#*|}"
        d=$((dline - uline)); [ "$d" -lt 0 ] && d=$((0 - d))
        if [ "$bestd" -lt 0 ] || [ "$d" -lt "$bestd" ]; then bestd="$d"; best="$ur"; uown="$uo"; fi
      done <<INNER
$urls
INNER
      [ "$bestd" -ge 0 ] && [ "$bestd" -le "$DIGEST_WINDOW" ] || continue
      DIGEST_RECORDS="${DIGEST_RECORDS}${best}|${dg}|${uown}|${scope}|${rel}|${dline}
"
      DIGEST_N=$((DIGEST_N+1))
    done <<TOKENS
$(printf '%s\n' "$dtext" | tr -c '0-9a-fA-F' '\n' | grep -xE '[0-9a-fA-F]{64}')
TOKENS
  done <<LINES
$(grep -nE '[0-9a-fA-F]{64}' "$f" 2>/dev/null)
LINES
}

# discover_digests <scope> <root>
# Scaffolding is pruned by the shared SCAFFOLDING_DIRS rule above, and for the same reason
# in both sweeps: gate FIXTURES carry deliberately-wrong digests — including this file's own
# historical-defect mutant, and any the site's copy-parity gate grows for the install command
# it exists to verify — so scanning them would gate the fixtures instead of the product.
discover_digests() {
  local scope="$1" root="$2" f rel
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$root/}"
    scan_one_file "$scope" "$rel" "$f"
  done <<FILES
$(find_files published "$root" '*.md' '*.txt' '*.json' '*.toml' '*.html' '*.js' '*.sh' '*.yml' '*.yaml')
FILES
}

# run_digest_discovery <site-dir>
run_digest_discovery() {
  local site="$1"
  DIGEST_RECORDS=""; DIGEST_N=0
  discover_digests repo "$REPO"
  [ -d "$site" ] && discover_digests site "$(cd "$site" && pwd)"
  return 0
}

digest_records() { printf '%s' "$DIGEST_RECORDS"; }

# --list-digests: the discovery result, machine-readable. `--self-test` consumes this to
# build its fixture, so a newly added digest surface is picked up by the proof automatically
# instead of silently falling out of it.
if [ "${1:-}" = "--list-digests" ]; then
  run_digest_discovery "${HEIMDALL_SITE_DIR:-$REPO/../heimdall-site}"
  digest_records
  exit 0
fi

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

MANIFEST="$REPO/.claude-plugin/plugin.json"
README="$REPO/README.md"
VERSION_FILE="$REPO/VERSION"
PKG="$REPO/packages/runheimdall/package.json"
VERCEL="$REPO/vercel.json"
REDIRECTS="$REPO/_redirects"
INSTALL="$REPO/install.sh"

# read_json <file> <jq-filter> <sed-fallback-pattern>
# jq when present; sed fallback keeps the gate runnable on a box without jq (the same
# dual resolution release/ship.sh read_version and bin/heimdall-render-version use).
read_version_field() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$file" 2>/dev/null
  else
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$file" | head -1
  fi
}

# ── The single source of truth ───────────────────────────────────────────────
[ -f "$MANIFEST" ] || { printf 'version-drift: manifest missing: %s\n' "$MANIFEST" >&2; exit 1; }
VER="$(read_version_field "$MANIFEST")"
TAG="v$VER"

echo "version-drift harness  repo=$REPO  manifest=$VER"
echo "--------------------------------------------------------------------"

grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$VER" \
  && ok "plugin.json .version is a readable semver ($VER)" \
  || { bad "plugin.json .version not semver: '${VER:-<none>}'"; echo; echo "version-drift.test.sh: $PASS passed, $FAIL failed."; exit 1; }

# ── 1. VERSION ───────────────────────────────────────────────────────────────
if [ -f "$VERSION_FILE" ]; then
  VF="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [ "$VF" = "$VER" ] \
    && ok "VERSION == plugin.json ($VF)" \
    || bad "VERSION drift: VERSION='$VF' != plugin.json='$VER'"
else
  bad "VERSION missing at repo root (bin/heimdall-render-version must mirror plugin.json into it)"
fi

# ── 2. README: generated region carries the version, and no stale semver anywhere ──
if [ -f "$README" ]; then
  grep -Fq "badge/version-${VER}-" "$README" \
    && ok "README generated region carries the manifest version ($VER)" \
    || bad "README generated region does not carry '$VER' — run bin/heimdall-render-version"

  grep -Fq 'HEIMDALL:VERSION:BEGIN' "$README" \
    && ok "README version region is generated (markers present)" \
    || bad "README has no HEIMDALL:VERSION markers — the version is hand-typed and will drift"

  # Any three-part semver in README that is not the manifest version is a stale pin.
  README_DRIFT=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$v" = "$VER" ] && continue
    bad "README stale version pin: '$v' != plugin.json '$VER'"
    README_DRIFT=1
  done <<EOF
$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$README" | sort -u)
EOF
  [ "$README_DRIFT" -eq 0 ] && ok "README carries no stale version pin"
else
  bad "README.md missing"
fi

# ── 3. packages/runheimdall/package.json — the npx wrapper ───────────────────
# This is the surface that actually drifted in production (2.0.5 vs 2.2.6): `npx runheimdall`
# fetches .heimdall.installScriptUrl, so a stale tag here installs a stale Heimdall.
if [ -f "$PKG" ]; then
  PKG_VER="$(read_version_field "$PKG")"
  [ "$PKG_VER" = "$VER" ] \
    && ok "runheimdall package.json .version == plugin.json ($PKG_VER)" \
    || bad "runheimdall package.json drift: .version='$PKG_VER' != plugin.json='$VER'"

  if command -v jq >/dev/null 2>&1; then
    PKG_TAG="$(jq -r '.heimdall.tag // empty' "$PKG" 2>/dev/null)"
    PKG_URL="$(jq -r '.heimdall.installScriptUrl // empty' "$PKG" 2>/dev/null)"
    [ "$PKG_TAG" = "$TAG" ] \
      && ok "runheimdall .heimdall.tag == $TAG" \
      || bad "runheimdall .heimdall.tag drift: '$PKG_TAG' != '$TAG'"
    case "$PKG_URL" in
      */"$TAG"/install.sh) ok "runheimdall .heimdall.installScriptUrl pinned to $TAG" ;;
      *) bad "runheimdall .heimdall.installScriptUrl drift: '$PKG_URL' is not pinned to $TAG" ;;
    esac
  fi
else
  bad "packages/runheimdall/package.json missing"
fi

# ── 4/5. Vanity redirect targets (vercel.json + _redirects) ──────────────────
# runheimdall.dev/install 302s here; a stale target serves a stale installer.
if [ -f "$VERCEL" ]; then
  grep -Fq "/heimdall/${TAG}/install.sh" "$VERCEL" \
    && ok "vercel.json /install redirect targets $TAG" \
    || bad "vercel.json /install redirect drift: not pointed at $TAG (run release/sync-release.sh $TAG)"
else
  bad "vercel.json missing"
fi

if [ -f "$REDIRECTS" ]; then
  grep -Fq "/heimdall/${TAG}/install.sh" "$REDIRECTS" \
    && ok "_redirects /install targets $TAG" \
    || bad "_redirects /install drift: not pointed at $TAG (run release/sync-release.sh $TAG)"
else
  bad "_redirects missing"
fi

# ── 6. install.sh DEFAULT_REF ────────────────────────────────────────────────
# A fresh `curl|bash` resolves this ref; a stale default is the historical v2.0.5 downgrade.
if [ -f "$INSTALL" ]; then
  DEF_REF="$(sed -n 's/.*local DEFAULT_REF="\(v[0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$INSTALL" | head -1)"
  if [ -z "$DEF_REF" ]; then
    bad "install.sh has no DEFAULT_REF=\"vX.Y.Z\" line to gate"
  else
    [ "$DEF_REF" = "$TAG" ] \
      && ok "install.sh DEFAULT_REF == $TAG" \
      || bad "install.sh DEFAULT_REF drift: '$DEF_REF' != '$TAG'"
  fi
else
  bad "install.sh missing"
fi

# ── 7. The marketing site — a SIBLING repo, absent means SKIPPED not FAILED ───
HEIMDALL_SITE_DIR="${HEIMDALL_SITE_DIR:-$REPO/../heimdall-site}"
if [ ! -d "$HEIMDALL_SITE_DIR" ]; then
  echo "  site: SKIPPED — nothing at $HEIMDALL_SITE_DIR (set HEIMDALL_SITE_DIR to gate it)"
else
  # Published surfaces only — dot-dirs and scaffolding pruned by the shared rule above.
  SITE_PUB=()
  SITE_PUB_N=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SITE_PUB+=("$f"); SITE_PUB_N=$((SITE_PUB_N+1))
  done <<EOF
$(find_files published "$HEIMDALL_SITE_DIR" '*.html' '*.js' '*.txt')
EOF
  SITE_CAND_N="$(find_files candidates "$HEIMDALL_SITE_DIR" '*.html' '*.js' '*.txt' | grep -c .)"
  SITE_EXCL_N=$((SITE_CAND_N - SITE_PUB_N))
  echo "  site: $HEIMDALL_SITE_DIR ($SITE_PUB_N published files examined, $SITE_EXCL_N excluded as scaffolding)"
  SITE_CHECKED=0

  # The exclusion's own anti-vacuous guard. Every filter can be too broad, and a filter that
  # is too broad does not announce itself — it just leaves nothing to assert over and the
  # sweep passes for free. Printing the excluded count above makes an over-broad rule visible
  # rather than silent; failing here makes a TOTALLY-broad one impossible to miss.
  # The two ways this can happen are different defects with different fixes, so they are
  # reported differently: a gate whose failure text misdescribes the cause sends the reader
  # hunting the wrong thing, which is the same wolf-crying this exclusion exists to stop.
  if [ "$SITE_PUB_N" -eq 0 ] && [ "$SITE_CAND_N" -gt 0 ]; then
    bad "site present at $HEIMDALL_SITE_DIR but the sweep examined ZERO published files — all $SITE_CAND_N candidate(s) were excluded as scaffolding ($SCAFFOLDING_DIRS). An exclusion that swallows the whole site is a vacuous sweep, not a clean one"
  elif [ "$SITE_PUB_N" -eq 0 ]; then
    bad "site present at $HEIMDALL_SITE_DIR but it holds no .html/.js/.txt files at all — HEIMDALL_SITE_DIR is pointed at the wrong directory, or the checkout is empty. Gating nothing is not gating cleanly"
  fi

  # (a) <meta name="heimdall-version"> on every published page. Matched with the
  # leading '<meta ' so the JS that READS the tag (querySelector('meta[name=...]'))
  # is not mistaken for a tag that declares one.
  if [ "$SITE_PUB_N" -gt 0 ]; then
    SITE_META_N=0; SITE_META_BAD=0
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      SITE_META_N=$((SITE_META_N+1))
      mval="$(printf '%s' "$hit" | sed -n 's/.*content="\([^"]*\)".*/\1/p')"
      if [ "$mval" != "$TAG" ]; then
        bad "site meta heimdall-version drift: '${mval:-<unparseable>}' != '$TAG' (${hit%%:*})"
        SITE_META_BAD=1
      fi
    done <<EOF
$(grep -rn '<meta name="heimdall-version"' "${SITE_PUB[@]}" 2>/dev/null)
EOF
    SITE_CHECKED=$((SITE_CHECKED+SITE_META_N))
    [ "$SITE_META_N" -gt 0 ] && [ "$SITE_META_BAD" -eq 0 ] \
      && ok "site meta heimdall-version == $TAG ($SITE_META_N page(s))"
  fi

  # (b) index.html JSON-LD softwareVersion — what search engines and AI answers cite.
  IDX="$HEIMDALL_SITE_DIR/index.html"
  if [ -f "$IDX" ]; then
    SITE_CHECKED=$((SITE_CHECKED+1))
    SV="$(sed -n 's/.*"softwareVersion"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "$IDX" | head -1)"
    [ "$SV" = "$VER" ] \
      && ok "site index.html JSON-LD softwareVersion == $VER" \
      || bad "site index.html JSON-LD softwareVersion drift: '${SV:-<none>}' != '$VER'"
  fi

  # (c) llms-full.txt install URL. EVERY pinned URL must be the current tag — asserting
  # merely that the right one is present would stay green with a stale one beside it.
  LLMS="$HEIMDALL_SITE_DIR/llms-full.txt"
  if [ -f "$LLMS" ]; then
    LLMS_N=0; LLMS_BAD=0
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      LLMS_N=$((LLMS_N+1))
      [ "$u" = "$TAG" ] && continue
      bad "site llms-full.txt install URL drift: '$u' != '$TAG'"
      LLMS_BAD=1
    done <<EOF
$(grep -oE '/heimdall/v[0-9]+\.[0-9]+\.[0-9]+/install\.sh' "$LLMS" 2>/dev/null | sed -e 's|^/heimdall/||' -e 's|/install\.sh$||' | sort -u)
EOF
    SITE_CHECKED=$((SITE_CHECKED+LLMS_N))
    if [ "$LLMS_N" -eq 0 ]; then
      bad "site llms-full.txt carries no pinned /heimdall/<tag>/install.sh URL to gate"
    elif [ "$LLMS_BAD" -eq 0 ]; then
      ok "site llms-full.txt install URL pinned to $TAG"
    fi
  fi

  # (d) The hardcoded JS version fallback — what every visitor sees when the GitHub
  # API call is cold, rate-limited, or offline. version.js has one, and index.html and
  # team.html each inline the same construct; gating only version.js would leave the
  # other two free to drift, which is the same gap in miniature.
  if [ "$SITE_PUB_N" -gt 0 ]; then
    FB_N=0; FB_BAD=0
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      FB_N=$((FB_N+1))
      fval="${hit##*:}"
      if [ "$fval" != "'$TAG'" ]; then
        bad "site JS version fallback drift: $fval != '$TAG' (${hit%%:*})"
        FB_BAD=1
      fi
    done <<EOF
$(grep -rnoE "'v[0-9]+\.[0-9]+\.[0-9]+'" "${SITE_PUB[@]}" 2>/dev/null)
EOF
    SITE_CHECKED=$((SITE_CHECKED+FB_N))
    [ "$FB_N" -gt 0 ] && [ "$FB_BAD" -eq 0 ] \
      && ok "site JS version fallbacks == '$TAG' ($FB_N literal(s))"
  fi

  # A checkout that yields zero version-bearing fields is a VACUOUS pass, not a clean
  # one — the same shape of false green that let the site drift in the first place.
  [ "$SITE_CHECKED" -eq 0 ] \
    && bad "site present at $HEIMDALL_SITE_DIR but ZERO version-bearing fields found — vacuous sweep, not a clean one"
fi

# ── 8. Pinned install digests — the sha256 must describe the bytes it sits next to ──
run_digest_discovery "$HEIMDALL_SITE_DIR"

DIGEST_COMPARED=0
DIGEST_SKIPPED=0

if [ "$DIGEST_N" -eq 0 ]; then
  # Discovering nothing is the same false green that let the digest drift: a sweep that
  # asserts over an empty set passes for free.
  bad "ZERO pinned install digests discovered under $REPO — the digest sweep is VACUOUS, not clean (looked for a 64-hex token within $DIGEST_WINDOW lines of a raw.githubusercontent .../heimdall/<ref>/install.sh URL)"
else
  DIGEST_FILES="$(digest_records | awk -F'|' 'NF{print $4":"$5}' | sort -u | grep -c .)"
  echo "  install digests: $DIGEST_N pin(s) discovered across $DIGEST_FILES file(s)"
  digest_records | awk -F'|' 'NF{printf "    %s:%s:%s  %s…  ref=%s\n", $4, $5, $6, substr($2,1,12), $1}'

  for dref in $(digest_records | awk -F'|' 'NF{print $1}' | sort -u); do
    DREF_DIGESTS="$(digest_records | awk -F'|' -v r="$dref" 'NF&&$1==r{print $2}' | sort -u)"
    DREF_COUNT="$(printf '%s\n' "$DREF_DIGESTS" | grep -c .)"

    # (a) CROSS-SURFACE — offline, string-only. This alone catches the shipped defect:
    # README said fafe31e3… while netlify.toml said 28bbdcd… for the same install.sh.
    if [ "$DREF_COUNT" -gt 1 ]; then
      bad "pinned install digest DISAGREEMENT for ref $dref — $DREF_COUNT different digests describe the SAME file; at most one can be right and every surface pinning the others aborts the install:"
      digest_records | awk -F'|' -v r="$dref" 'NF&&$1==r{printf "         %s  at %s:%s:%s\n", $2, $4, $5, $6}' | sort -u
    else
      ok "pinned install digests agree across all surfaces for ref $dref ($DREF_DIGESTS)"
    fi

    # (b) DIGEST↔BYTES — local git objects first: offline, immune to rate limits, and the
    # blob at a given ref is content-addressed, so it is byte-identical to what the URL serves.
    DACTUAL=""; DSRC=""
    if git -C "$REPO" cat-file -e "$dref:install.sh" 2>/dev/null; then
      DACTUAL="$(git -C "$REPO" show "$dref:install.sh" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
      DSRC="local git $dref:install.sh, offline"
    else
      DOWNER="$(digest_records | awk -F'|' -v r="$dref" 'NF&&$1==r{print $3; exit}')"
      DURL="https://raw.githubusercontent.com/$DOWNER/heimdall/$dref/install.sh"
      DTMP="$(mktemp)"
      # -o + exit status, never `curl | shasum`: a failed pipe would hash EMPTY input to a
      # perfectly valid sha256 and quietly compare it, which is a green built out of nothing.
      if curl -fsSL --max-time 15 -o "$DTMP" "$DURL" 2>/dev/null; then
        DACTUAL="$(shasum -a 256 "$DTMP" | awk '{print $1}')"
        DSRC="network fetch $DURL"
      fi
      rm -f "$DTMP"
    fi

    if [ -z "$DACTUAL" ]; then
      printf '  \033[33mSKIP\033[0m %s\n' "digest↔bytes for ref $dref: not in this checkout AND unreachable over the network — NOT verified, and NOT counted as a pass"
      DIGEST_SKIPPED=$((DIGEST_SKIPPED+1))
      continue
    fi

    for ddig in $DREF_DIGESTS; do
      DIGEST_COMPARED=$((DIGEST_COMPARED+1))
      if [ "$ddig" = "$DACTUAL" ]; then
        ok "pinned digest matches the real install.sh at $dref [$DSRC]"
      else
        bad "pinned install digest does NOT match the bytes it claims to describe at ref $dref: pinned $ddig, actual $DACTUAL [$DSRC] — the published \`shasum -a 256 -c -\` prints FAILED and the && chain aborts the install before it runs:"
        digest_records | awk -F'|' -v r="$dref" -v d="$ddig" 'NF&&$1==r&&$2==d{printf "         pinned at %s:%s:%s\n", $4, $5, $6}'
      fi
    done
  done

  # An unreachable network must never be the reason this section looks clean.
  [ "$DIGEST_COMPARED" -eq 0 ] \
    && bad "$DIGEST_N pinned digest(s) discovered but NONE could be checked against real bytes ($DIGEST_SKIPPED ref(s) unresolvable offline and unreachable over the network) — an unverifiable digest sweep is not a green one"
fi

echo ""
echo "version-drift.test.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] || exit 1
exit 0
