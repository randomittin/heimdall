# launch-docs/assets/ — the wall asset

"Install once, see your team's watchmen." A real, rendered set of the team
presence wall, for dropping into a deck, a README badge, or a prospect DM.
Nothing here is mocked up in a design tool — every pixel/character came out
of the actual Heimdall renderers, run against either this repo's own local
gate history (`bin/heimdall-clip`) or a 6-watchman fixture
(`sentinels/hmd-statusline.py` + `bin/heimdall-sigil-png`), using the same
fixture technique `conformance/statusline/viral-statusline.fixture.sh` and
`test/heimdall-team-board.test.sh` use for their own multi-teammate proofs.

## Provenance — read this before embedding anything here

**Every asset in this directory is currently `fixture`-provenance. None of them
may be referenced from README.md.** The renderers are real; some of the data
they rendered is seeded — `wall.png` labels five teammates who do not exist, and
the "14 merges proven" figure on `wall.svg` / `wall.json` / `wall.txt` counts
lines in a `printf`-written `beats.log`, not merges this repo proved.

That fact is stated honestly below, but prose in *this* file protects nobody: a
README reader never opens this directory. So provenance is also declared
machine-readably in **`provenance.json`** (one entry per asset: `real` or
`fixture`, each with a `reason` and a `receipt`), and enforced by
**`test/asset-provenance-gate.test.sh`**, which fails RED if a `fixture` asset is
referenced from README.md, the npm README mirror, or `site/`.

The gate is fail-closed: an asset that is undeclared, or carries an unrecognised
provenance value, is treated as `fixture`. That default lives in the test, not in
the manifest, so no edit to `provenance.json` can widen what counts as `real`.
Adding a file here without a `provenance.json` entry turns the gate RED (the
manifest and the directory must agree in both directions), which is the point —
a blocklist of filenames would rot the first time someone added `wall2.png`.

HTML comments are stripped before scanning, so README.md's `HEIMDALL:HERO-ASSET`
slot can keep naming `wall.gif` as the expected future path without tripping it.
Run `test/asset-provenance-gate.test.sh --self-test` to watch the gate go RED on
a planted fixture embed, a deleted manifest, an emptied manifest, and a
receipt-less provenance claim.

## Files

- **`wall.png`** — the shareable hero image (1576×520): 6 deterministic
  pixel-art sigil avatars (you + 5 fake teammates), each with a live
  name + status caption, a "N merges proven / N watchmen online" stat
  line, and the runheimdall.dev tag. Built from six real
  `bin/heimdall-sigil-png` renders composited with ImageMagick (`magick`).
  This is the primary asset — the richest tier this environment can
  produce headlessly.
- **`wall.svg`** — `bin/heimdall-clip --wall --svg` verbatim: the native
  "proven wall" share card (title + proven-merge count + last verdict +
  runheimdall.dev tag). Scalable vector, zero extra tooling, byte-for-byte
  what the installed `hmd clip --wall --svg` emits.
- **`wall.txt`** — the guaranteed plain-text floor: the ANSI-stripped
  `hmd-statusline.py` team wall + the `heimdall-clip` card, concatenated
  with explanatory headers.
- **`wall.json`** — `bin/heimdall-clip --wall --json` verbatim: the same
  proven-wall moment as structured data (`schema: clip_v1`). Its `file` field
  names `src/auth/session.ts` — a path this repo has never had (there is no
  `src/` directory at all), which is the clearest single tell that the clip
  assets were rendered against a seeded verdict rather than real gate history.
- **`provenance.json`** — the machine-readable provenance declaration the gate
  reads (`schema: asset_provenance_v1`). Not an asset; a receipt about the
  assets.

## Why there is no wall.gif

This environment has none of asciinema / agg / vhs / gifsicle installed
(checked with `command -v`; only ImageMagick (`magick`/`convert`) and
python3 are present). Per "never fake a GIF," the wall stops at the
richest REAL tier this box can produce headlessly — a real composited
PNG + a real SVG + real text — instead of manufacturing a fake or corrupt
`.gif`. `sentinels/hmd-gate-anim.sh`'s own export ladder
(`export_artifact`, lines 195–220) draws the exact same line: `.gif` only
with asciinema+agg present, else `.png`, else an honest `.txt` floor —
this asset follows that precedent rather than inventing a new one.

### The one command to get the TRUE animated wall.gif

Once asciinema + agg (or vhs) are installed locally:

```bash
brew install asciinema        # or: pip install asciinema / apt-get install asciinema
brew install agg              # or: cargo install --locked agg — https://github.com/asciinema/agg

# re-seed the 6-watchman fixture into $WS (see "Regenerating" step 2 below), then:
bin/heimdall-reel record . --out launch-docs/assets --name wall -- bash -c '
  WS="'"$WS"'"
  for t in 0 1 2 3 4 5 6 7 8 9 10 11; do
    clear
    printf "{\"workspace\":{\"current_dir\":\"%s\"}}" "$WS" \
      | HMD_NOW=$t COLUMNS=120 python3 sentinels/hmd-statusline.py
    sleep 0.25
  done
'
```

`heimdall-reel record` (`bin/heimdall-reel:163-224`) asciinema-records the
wrapped command and renders the `.cast` to `launch-docs/assets/wall.gif`
via `agg` automatically — no new code needed. This is the exact machinery
`test/heimdall-gate-anim-export.test.sh` already proves (re-ran it in this
session: **22 passed, 0 failed**) for the gate-animation case;
`heimdall-reel` is the same record→render ladder applied to any command's
terminal session, and the 12-tick loop matches `hmd-statusline.py`'s own
deterministic blink/look/glint eye cycle (`HMD_NOW % 12`) so the recorded
GIF shows the watchman's eyes actually animating over the seeded wall.

## Regenerating

The wall needs several fake teammates so it doesn't look like a lonely
1-member wall. This only touches two throwaway, `.heimdall/*`-gitignored
inputs in the repo (`.heimdall/verdict.json` +
`.heimdall/receipts/beats.log` — read-only inputs to `heimdall-clip`,
safe to delete any time) plus a scratch workspace for the statusline
fixture that never touches this repo's real `.heimdall/team/`.

**1. Seed the repo's own gate history** (what `heimdall-clip --wall` reads):

```bash
mkdir -p .heimdall/receipts
printf '{"verdict":"pass","phase":"gate","ts":"2026-07-25T09:14:22Z","gate":"oracle/falsify","file":"src/auth/session.ts","reasons":""}\n' \
  > .heimdall/verdict.json
# beats.log lines are  <iso-ts>\t<verdict>\t<file>  (bin/heimdall-badge:59) —
# this session used 14 "pass" + 1 "deny" line across 2026-07-11..25.
```

**2. Seed a 6-watchman fixture** (you + 5 teammates) in a scratch
workspace — the exact `.heimdall/team/*.json` shape
`conformance/statusline/viral-statusline.fixture.sh` seeds
(`{"haid","name","agent","verdict","file","ts"}`; TTL is 30s per
`sentinels/hmd-statusline.py:549` `team_presence(cwd, ttl=30)` — re-seed
immediately before every render, don't let it go stale):

```bash
WS="$(mktemp -d)/acme-checkout"
mkdir -p "$WS/.heimdall/team"
NOW="$(python3 -c 'import time;print(int(time.time()))')"
printf '{"haid":"haid:arjun.laptop-7f3a","name":"arjun","agent":"reviewer","verdict":"pass","file":"checkout.tsx","ts":%s}'    "$NOW" > "$WS/.heimdall/team/arjun.json"
printf '{"haid":"haid:kai.laptop-2c9e","name":"kai","agent":"coder","verdict":"running","file":"billing.go","ts":%s}'         "$NOW" > "$WS/.heimdall/team/kai.json"
printf '{"haid":"haid:maya.laptop-5b1d","name":"maya","agent":"tester","verdict":"pass","file":"schema.sql","ts":%s}'         "$NOW" > "$WS/.heimdall/team/maya.json"
printf '{"haid":"haid:nadia.laptop-9e04","name":"nadia","agent":"coder","verdict":"running","file":"auth.ts","ts":%s}'        "$NOW" > "$WS/.heimdall/team/nadia.json"
printf '{"haid":"haid:priya.laptop-e6a2","name":"priya","agent":"architect","verdict":"pass","file":"onboarding.tsx","ts":%s}' "$NOW" > "$WS/.heimdall/team/priya.json"
```

**3. Render each artifact:**

```bash
# wall.svg / wall.json — heimdall-clip's native exports (repo's real .heimdall/)
bin/heimdall-clip --wall --svg  > launch-docs/assets/wall.svg
bin/heimdall-clip --wall --json > launch-docs/assets/wall.json
bin/heimdall-clip --wall                                  # the plain card, for wall.txt

# the team-wall text frame (ANSI-stripped; HMD_NOW=1 = a bright "glint" tick,
# not a blink, so the main watchman's eyes read as alert in a static frame)
printf '{"workspace":{"current_dir":"%s"}}' "$WS" \
  | HMD_NOW=1 COLUMNS=120 python3 sentinels/hmd-statusline.py \
  | sed -E 's/\x1b\[[0-9;]*m//g'

# wall.png — 6 sigil-png avatars, labeled + composited with ImageMagick
mkdir -p /tmp/av
bin/heimdall-sigil-png --seed rj                       --scale 12 --out /tmp/av/rj.png
bin/heimdall-sigil-png --seed "haid:arjun.laptop-7f3a" --scale 12 --out /tmp/av/arjun.png
bin/heimdall-sigil-png --seed "haid:kai.laptop-2c9e"   --scale 12 --out /tmp/av/kai.png
bin/heimdall-sigil-png --seed "haid:maya.laptop-5b1d"  --scale 12 --out /tmp/av/maya.png
bin/heimdall-sigil-png --seed "haid:nadia.laptop-9e04" --scale 12 --out /tmp/av/nadia.png
bin/heimdall-sigil-png --seed "haid:priya.laptop-e6a2" --scale 12 --out /tmp/av/priya.png

FONT=/System/Library/Fonts/Menlo.ttc   # find_font()-style fallback list: see
                                        # sentinels/hmd-gate-anim.sh:107-122
# label each avatar (name + status) under the sprite
magick /tmp/av/rj.png    -background '#0d1117' -gravity South -splice 0x34 -fill '#e6edf3' -font "$FONT" -pointsize 20 -gravity South -annotate +0+6 "rj (you)"        /tmp/av/tile_rj.png
magick /tmp/av/arjun.png -background '#0d1117' -gravity South -splice 0x34 -fill '#e6edf3' -font "$FONT" -pointsize 20 -gravity South -annotate +0+6 "arjun - pass"    /tmp/av/tile_arjun.png
magick /tmp/av/kai.png   -background '#0d1117' -gravity South -splice 0x34 -fill '#e6edf3' -font "$FONT" -pointsize 20 -gravity South -annotate +0+6 "kai - running"   /tmp/av/tile_kai.png
magick /tmp/av/maya.png  -background '#0d1117' -gravity South -splice 0x34 -fill '#e6edf3' -font "$FONT" -pointsize 20 -gravity South -annotate +0+6 "maya - pass"     /tmp/av/tile_maya.png
magick /tmp/av/nadia.png -background '#0d1117' -gravity South -splice 0x34 -fill '#e6edf3' -font "$FONT" -pointsize 20 -gravity South -annotate +0+6 "nadia - running" /tmp/av/tile_nadia.png
magick /tmp/av/priya.png -background '#0d1117' -gravity South -splice 0x34 -fill '#e6edf3' -font "$FONT" -pointsize 20 -gravity South -annotate +0+6 "priya - pass"    /tmp/av/tile_priya.png

# join the row, then compose the title / stat / tag card
magick /tmp/av/tile_rj.png /tmp/av/tile_arjun.png /tmp/av/tile_kai.png /tmp/av/tile_maya.png /tmp/av/tile_nadia.png /tmp/av/tile_priya.png \
  -bordercolor '#0d1117' -border 10x0 +append /tmp/av/avatar_row.png

magick -size 1568x512 xc:'#0d1117' \
  /tmp/av/avatar_row.png -geometry +40+120 -composite \
  -fill '#e6edf3' -font "$FONT" -pointsize 34 -gravity North -annotate +0+38 "HEIMDALL - your team's watchmen" \
  -fill '#7ee787' -font "$FONT" -pointsize 20 -gravity South -annotate +0+58 "14 merges proven by the watchman  *  6 watchmen online" \
  -fill '#00d4ff' -font "$FONT" -pointsize 20 -gravity South -annotate +0+22 "runheimdall.dev" \
  -bordercolor '#0d98ba' -border 4 \
  launch-docs/assets/wall.png
```

## Fixture identities used

`rj` (you — the repo's own curated identity) + `arjun`, `kai`, `maya`,
`nadia`, `priya` (fake teammates; names reused from
`conformance/statusline/viral-statusline.fixture.sh` and
`test/heimdall-team-board.test.sh`'s own fixtures, not invented from
scratch). `team_columns()` sorts teammates alphabetically and caps the
rendered sigils at 3 + a `+N` overflow tag by design
(`sentinels/hmd-statusline.py` `_team_members`) — arjun/kai/maya render
as sigils, nadia/priya fold into the `+2` tag. No `deny` verdict was
seeded into the fake team (kept the wall reading as a thriving, active
team) — the repo's own `beats.log` fixture (step 1) does include one real
`deny` beat among the 15, so the "14 merges proven" count stays an honest
`pass`-only tally, not a number with the failures quietly dropped.

## Verified

- `wall.png` — `file` reports `PNG image data, 1576 x 520, 16-bit/color
  RGBA, non-interlaced`; 145246 bytes.
- `wall.svg` — parses as well-formed XML (`xml.dom.minidom`), root
  element `svg`; 912 bytes.
- `wall.json` — parses as valid JSON (`python3 -m json.tool`); 205 bytes.
- `wall.txt` — `file` reports `Unicode text, UTF-8 text`; 2418 bytes.
- `test/heimdall-gate-anim-export.test.sh` (the export-ladder precedent
  this asset follows) re-run in this session: 22 passed, 0 failed.
