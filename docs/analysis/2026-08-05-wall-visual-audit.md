# Team Wall — Hostile Visual Audit

**Date:** 2026-08-05
**Scope:** `hooks/statusline.sh` team-wall zone, as a stranger sees it in a screenshot.
**Method:** rendered live at COLUMNS 40/50/60/70/80/100/120/200 against two repos
(`/Users/rj/Downloads/heimdall`, 1 member; `/Users/rj/Downloads/code/rally`, 23 members),
in colour, through `sed 's/\x1b\[[0-9;]*m//g'`, and through the real `NO_COLOR=1 TERM=dumb`
degrade path. Every claim below quotes output actually produced. No code was modified.

**Verdict on the honesty property: FAIL.** A stranger looking at the rally screenshot would
believe those people are live. Detail in M1/M2.

---

## MUST-FIX BEFORE LAUNCH — 5

### M1. The presence drain is dead code. Every absent person renders as present.

`team_columns()` is written to drain the identity hue out of a non-present teammate's sigil
(`hmd-statusline.py:1076-1080`, `_drained()` at :1002). It never runs. `_MONO_CAPS` is built
in a `try/except` at `sentinels/hmd-statusline.py:71`:

```
_MONO_CAPS = SIG.tier_caps(TC.MONO, CAPS.unicode_tier)
```

`Caps` has no `unicode_tier` attribute — it is `unicode`. Verified attribute list:
`['_sgr_sub', 'color', 'emit', 'mode', 'term_program', 'tmux', 'unicode', 'use_color', 'width']`.
So line 71 raises `AttributeError` on every single render, the `except` sets `_MONO_CAPS = None`,
and line 1080 falls back to full-colour `CAPS` for **every** away / contributed / member row.

Proof — same seed (`anu`), driven through the real `team_columns()` at each tier:

```
online       sigil colors: ['38;2;19;21;29', '38;2;26;188;156']
contributed  sigil colors: ['38;2;19;21;29', '38;2;26;188;156']
away         sigil colors: ['38;2;19;21;29', '38;2;26;188;156']
member       sigil colors: ['38;2;19;21;29', '38;2;26;188;156']
```

Byte-identical. The mono path itself works fine when called correctly
(`SIG.eye_strip(seed, mono)` returns zero truecolor fg codes) — it is simply never reached.

Consequence in the hero screenshot: the sigil occupies **2 of the 4 rows** and is the only
saturated, eye-catching element in each column. On the rally wall — where **zero** people are
online — all nine visible faces glow at full identity saturation. A live 200-col render emits
teal `26;188;156` ×28, red `231;76;60` ×24, green `46;204;113` ×16, gold `241;196;15` ×10,
pink `224;86;160` ×10. That is a wall of vivid, alive-looking faces representing a repo with
nobody in it.

This is the single worst launch outcome available and it is currently shipping.

### M2. The only honest signal on the wall is its least legible pixel.

What actually distinguishes an absent person is (a) the name dropping to `FAINT` and (b) the
Row-4 word. Both are `#3A414D`. Measured WCAG contrast:

| element | hue | on `#000` | on `#1E1E1E` | on `#12141C` |
|---|---|---|---|---|
| absent name + `⌁git` / `⊘off` / `⌂mem` label | `#3A414D` | **2.04:1** | **1.62:1** | **1.79:1** |
| `+N` overflow tag | `#5A6472` | 3.50:1 | **2.78:1** | 3.06:1 |
| online teal | `#1ABC9C` | 8.72:1 | 6.92:1 | 7.63:1 |
| online green | `#2ECC71` | 9.99:1 | 7.93:1 | 8.75:1 |
| online gold | `#F1C40F` | 12.64:1 | 10.04:1 | 11.07:1 |

The truth fails AA and fails even the 3:1 large-text floor. The lie passes AA four times over.
The wall is optically tuned to say "everyone is here". Combined with M1 there is no surviving
at-a-glance cue that anyone is absent — you have to *read* 8-point grey text to learn it.

Fix direction: absent Row-4 labels need to clear 4.5:1 (roughly `#7A8494` or lighter), and the
`+N` tag needs to clear 3:1 on a `#1E1E1E` terminal.

### M3. The owner is two people, and the hue space collides on top of it.

Known and being fixed: `rj` renders as the hero sigil (left) while `randomittin` renders as a
wall column. On heimdall's own repo that is the *entire* wall:

```
▄▄▄▄▄▄▄▄ ⛭ HEIMDALL │ rj · Opus │ heimdall ◦ watching           ▄▄▄▄▄▄▄▄
▄▄▄▄▄▄▄▄  CTX 0%                                                ▄▄▄▄▄▄▄▄
▄▄▄▄▄▄▄▄ – gates offline                                        randomi…
▄▄▄▄▄▄▄▄ session                                                ⌁git 58m
```

A stranger cloning heimdall and running it sees a two-person team that is one man.

Worse, nothing else de-duplicates either. `_team_hue()` maps 11 real roster names onto **6**
hues:

```
#1abc9c  ['anu', 'ravikiran']
#2dd4bf  ['rj']
#2ecc71  ['madhavan', 'ravikiranm', 'ranjitha']
#3498db  ['priyadharshini']
#c8cdd2  ['tejashwini']
#e74c3c  ['akshat', 'madala', 'randomittin']
```

Three greens and three reds. At wall size the hue *is* the identity, so on the rally screenshot
several distinct humans are the same colour block. The strip reads as decorative noise rather
than as a roster of individuals.

### M4. The identity segment collapses non-monotonically and leaves orphan whitespace.

Row 1, same repo (rally), same moment, only COLUMNS varying — reproduced identically across
three consecutive runs:

```
[ 50] ⛭ HEIMDALL    ◦ watching        ← the owner's name is GONE
[ 60] ⛭ HEIMDALL │ rj │ rally ◦ watching
[ 70] ⛭ HEIMDALL │ rj │ rally ◦ watching
[ 80] ⛭ HEIMDALL │ rj  ◦ watching     ← two orphan spaces
[100] ⛭ HEIMDALL │ rj · Opus │ rally ◦ watching
[120] ⛭ HEIMDALL │ rj · Opus ◦ watching
[200] ⛭ HEIMDALL │ rj   ◦ watching    ← three orphan spaces
```

Two separate defects:

1. **Wider is worse.** 200 columns shows *less* identity than 100. The team zone is allocated
   first and starves the identity segment, so the more screen you have the less the header
   says. A demo recorded full-screen gets the worst header.
2. **Segments are blanked, not removed.** Dropping `· Opus` / `│ rally` leaves their padding
   behind — `rj  ◦` and `rj   ◦`. It reads as a missing value, i.e. a bug, not as a compact
   layout. At 50 columns the name vanishes entirely and leaves `HEIMDALL    ◦ watching`.

This is the top-left of the screenshot. It is the first thing anyone reads.

### M5. Truncation collides two distinct people into identical text.

rally at 200 columns, name row:

```
akshat           anu              madala           madhavan         priyadh…         ravikir…         ravikir…         ranjitha         tejashw… +13
```

Columns 6 and 7 are **both** `ravikir…` (`ravikiran` and `ravikiranm`). Adjacent, identical,
indistinguishable. A stranger reads that as the wall rendering the same person twice — which,
given M3, is a conclusion they have already been primed to draw.

On the truncation rule itself: `randomi…`, `priyadh…`, `tejashw…` cut at 7 chars + `…`. The
ellipsis is a real `…` and consistently applied, so it reads as *deliberate* rather than
broken — the rule is fine. The problem is that 7 characters is not enough entropy for this
roster, and there is no collision handling behind it.

---

## POLISH

- **The no-colour path erases identity completely.** Real `NO_COLOR=1 TERM=dumb` output:

  ```
   ______  ⛭ HEIMDALL | rj . Opus . watching           ........         ........         ........         ........
  |o    o| [-------------------------------]           ........         ........         ........         ........
  |_hmd__| – gates offline                             akshat           anu              madala           madhavan +18
           session                                     ⌁git 14h         ⌁git 15h         ⌁git 15h         ⌁git 15d
  ```

  Every teammate is `........`. Even under plain ANSI-stripping every sigil is the identical
  string `▄▄▄▄▄▄▄▄` — the shape lives entirely in fg/bg colour pairs on one repeated `▄`, so
  any screenshot-to-text or OCR pipeline yields four identical blobs. The `⌁git` labels and
  `+18` do survive, which is the one thing going right here.

- **Colourblind viewers get the worst two hues.** The two most-used identity hues are
  `#E74C3C` (3 people) and `#2ECC71` (3 people) — red and green, the classic deuteranopia
  confusion pair, carrying 6 of 11 identities between them.

- **`+N` is glued to the last name.** `madhavan +18` and `tejashw… +13` read as if `+18` were
  part of the name or a diff stat. It needs separation or a right-rail slot.

- **`+N` floats in dead space.** rally at 100 columns: `anu      +20` followed by ~30 blank
  columns. The tag is appended after the last member rather than right-aligned to the zone, so
  it lands mid-strip with nothing around it.

- **Large dead zone at width.** heimdall at 200 columns renders one 15-cell member column and
  then ~130 empty columns. The wall neither centres nor fills; a wide-terminal screenshot of a
  small team is mostly emptiness.

- **`– gates offline`** — the leading en-dash reads as a missing value. In a hero screenshot
  the second-most-prominent line saying "offline" next to a wall of faces is an unfortunate
  pairing regardless.

- **Month-old contributors sit at equal weight beside a live session.** rally at 200 shows
  `⌁git 15d`, `⌁git 20d`, `⌁git 22d`, `⌁git 22d`, `⌁git 26d`, `⌁git 27d`. Six people who have
  not touched the repo in three-plus weeks occupy six of nine hero slots. Even with M1/M2 fixed,
  a wall whose median entry is 22 days stale is not a presence wall.

---

## Density and rhythm

The 15-cell column (7 pad + 8 strip) with a 2-cell gap produces a clean, even beat — the
horizontal rhythm is genuinely good and the four-row block has a real typographic structure
(face / face / name / state). That part is well-judged.

What is missing is **a first landing point.** Every column has identical weight, identical
saturation, identical size. The eye has nowhere to go first, so it scans left-to-right and
gives up. There is no "3 online" summary, no separator between present and absent, no size or
brightness step. Fixing M1 would create that hierarchy for free — the online faces would be the
only saturated things on the strip and the eye would land on them instantly.

## The sigils

At 8×2 the sigils read as small mosaic faces and the eye-row is legible — they are charming and
not mush *when the hue is distinct*. Nothing is accidentally ugly or unfortunate-looking. Their
failure modes are all systemic, not aesthetic: six hues for eleven people (M3), zero shape
information without colour (polish item 1). No individual sigil needs redesign; the palette and
the mono fallback do.

## What a demo GIF would show

**Right now: no story.** Ten seconds of rally would show a static strip of glowing faces, a
`+18`, `CTX 0%`, and `– gates offline`. Nothing moves. Nobody is online, so no hue ever changes
and no state ever flips — and because of M1 it would look exactly the same if someone *did*
come online. The one dynamic, emotionally interesting property this wall exists to show is the
one property currently broken.

The GIF that works is: a teammate's face **ignites** from drained grey to full identity colour
as they start a session, their Row-4 flipping `⌁git 3h` → `⚡ wrk`, and the count at the head of
the strip ticking up. That requires M1 fixed and a present/absent summary added. It is a two-cue
change and it converts a static roster into the thing worth screenshotting.
