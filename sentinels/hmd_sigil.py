#!/usr/bin/env python3
"""
hmd_sigil.py — deterministic watchman sigil from a HAID/identity seed.
Every Heimdall identity (user or agent) gets a unique, reproducible pixel watchman.
Same seed -> same sigil, forever. Used three ways:
  - compact  : the always-on statusline face (your watchman)
  - glyph     : a single colored cell for the team wall (teammates)
  - large     : the share card / banner / README avatar

Render is ANSI half-blocks (each text cell = 2 vertical pixels via ▀). A 2:1
monospace cell + half-block makes each PIXEL ~square, so an N×N pixel grid renders
as an EXACT SQUARE silhouette. The base grid is 8×8 px -> 8 cols × 4 text-rows: a
true square, width-stable in any monospace terminal (see .planning/ref).

ONE SHARED RENDER CORE
----------------------
`sigil_render(haid, size, caps)` is the single implementation every surface
(statusline, banner, `hmd sigil`, TUI) renders through. It was previously the case
that the statusline downgraded colors (via hmd_termcaps.Caps.emit) while the CLI +
banner emitted RAW 24-bit truecolor SGR blind — on a 256-color / tmux / 16-color
terminal that raw SGR is quantized unpredictably or swallowed (bg dropped), which
collapses the silhouette/eyes = the "morphed sigil" bug. The fix is structural:
sigil_render applies the capability tier ITSELF, so no caller can render blind.

  color tier  : truecolor | 256 (fixed xterm-cube LUT) | 16 (fixed 4-shade) | mono
  unicode tier: full (▀ half-blocks) | basic/ascii (translated by hmd_termcaps)
  sizes       : 'S' 4×4px (4c×2r) · 'M' 8×8px (8c×4r) · 'L' 16×16px (16c×8r)

Deterministic everywhere: same (haid, size, tier) -> byte-identical bytes. The
sha256(HAID) seed picks the silhouette; the transparent/OFF composite is done
BEFORE any downsample (OFF -> DIM filled block) so box-filtering never fringes.

Two ways a grid is born — a HYBRID that always yields a clean, legible face:
  - CURATED   : 4 hand-authored mockup identities (rj/nadia/arjun/priya) ship
                their exact grids + hue, so those seeds match the design 1:1.
  - GENERATED : every other seed (real HAIDs are arbitrary) maps DETERMINISTICALLY
                onto the ported superx SPRITE CAST — a set of hand-authored animal
                characters (owl / fox / cat / rabbit / panda / bear / dog / monk),
                each with its own unmistakable ear-and-body silhouette + hue. The
                hash picks ONE animal (sha256(seed)[0] % 8); the same seed always
                gets the same character. Distinct HAIDs -> distinct recognizable
                animals, never the one muddy guardian blob for everyone.

Both paths then get the universal watchman finish: a full-dark carved VISOR BAND
(grid rows 2+3, edge to edge) holding two FULL-CELL white square EYES (cols 2 & 5,
each punched across rows 2+3 = one whole text cell), with a defined gap between
them and the helm above / shoulders below framing the dark band so the eyes POP.
OFF pixels render as a DIM FILLED block (#13151d) so the face has a solid
silhouette / bounding box instead of fraying into transparent space.

  python3 hmd_sigil.py --seed rj-a3f9 --size compact
  python3 hmd_sigil.py --seed nadia   --size large
  python3 hmd_sigil.py --seed arjun   --size M --tier 256   # tiered render
  python3 hmd_sigil.py --seed arjun   --glyph               # single wall cell
"""
import hashlib, sys, os, re, argparse, importlib.util
from collections import Counter

# ── shared capability module (single source of the tier LUTs) ──────────────────
# Loaded by absolute path so `hmd_sigil.py` behaves identically whether imported
# (statusline/banner) or run as a script from any cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_tcspec = importlib.util.spec_from_file_location(
    "hmd_termcaps", os.path.join(_HERE, "hmd_termcaps.py"))
TC = importlib.util.module_from_spec(_tcspec); _tcspec.loader.exec_module(TC)

# ── curated identities (canonical mockup) — 4 hand-authored 8x8 faces + fixed hue.
#    pixel values: 0=off, 1=body hue, 2=eye. these seeds match the design pixel-for-pixel.
#    Rows 2+3 carry the eye marker (cols 2 & 5); the universal watchman finish carves
#    the full visor band and re-punches those eyes, so the band is identical for every
#    identity (one strong, consistent brand signature) while the body silhouette varies.
CURATED_GRIDS = {
    'rj':    ["00111100", "01111110", "00200200", "00200200",
              "01111110", "01100110", "00111100", "01100110"],
    'nadia': ["01100110", "01111110", "00200200", "00200200",
              "11111111", "01111110", "01011010", "11000011"],
    'arjun': ["00011000", "00111100", "00200200", "00200200",
              "01111110", "00111100", "00100100", "01100110"],
    'priya': ["01111110", "11111111", "00200200", "00200200",
              "11100111", "01111110", "01100110", "11011011"],
}
CURATED_HUES = {
    'rj':    (45, 212, 191),    # teal
    'nadia': (245, 158, 11),    # amber
    'arjun': (167, 139, 250),   # violet
    'priya': (244, 114, 182),   # pink
}

# ── HERO SIGILS — hand-authored COMPLETE hero faces (RJ-authored 8×8, transcribed
#    VERBATIM from .planning/ref/custom-sigil-spec.md). Each carries its OWN full palette
#    and renders RAW: the animal-cast watchman band + forced eyes are BYPASSED (the face
#    already has its own eyes in the grid). A hero may use ANY SUBSET of the alphabet, so
#    a spec only carries the palette keys its grid actually references — the render
#    tolerates missing keys (hulk/superman have no accent7; black-panther no accent6/7;
#    joker no eye; ironman adds highlight; cyborg uses all eight).
#
#    grid alphabet (8×8):  . = bg       1 = hue      2 = eye       3 = highlight
#                          4 = shadow   5 = outline  6 = accent6   7 = accent7
#    Each token maps to a hex; the compact render (S/M/L) honors the FULL palette and the
#    one-pass tier downgrade (truecolor→256→16→mono) applies as usual.
#
#    Two roles:
#      • POOL   — HERO_SIGILS (keyed by hero NAME) is the AUTO-ASSIGN pool: every REAL
#                 HAID with no explicit choice maps DETERMINISTICALLY onto one hero
#                 (hero_for), so a dev gets a recognizable hero free — never the blob.
#      • PINNED — CUSTOM_SIGILS maps an EXACT seed (a full HAID / handle) to a hero;
#                 batsy stays pinned to RJ's own HAID (the sigil-custom contract).
#    ADDITIVE: curated (rj/nadia/arjun/priya) + the animal cast are UNCHANGED; only a
#    pinned seed, an explicit hero name, or a REAL HAID resolves to a hero.
HERO_SIGILS = {
    # batsy — RJ's bat-cowl homage: navy cowl(1)·white eyes(2)·near-black outline(5)·skin jaw(6)·blue accents(7)
    "batsy": {
        "name": "batsy",
        "grid": ["1......1", "11777171", "15117711", "15511151",
                 "12255221", "15555551", "16622661", ".166661."],
        "hue": "#141834", "eye": "#fffcf6", "outline": "#000000",
        "accent6": "#f8cfb1", "accent7": "#2f96ff", "bg": "#131c23",
    },
    "green-lantern": {
        "name": "green-lantern",
        "grid": [".111111.", "11111111", "16116661", "77766777",
                 "52577525", "55777755", "66622666", ".666666."],
        "hue": "#9a3b27", "eye": "#f9ede6", "outline": "#010200",
        "accent6": "#fcc39a", "accent7": "#06783b", "bg": "#392520",
    },
    "venom": {
        "name": "venom",
        "grid": [".111111.", "25555552", "21555512", "22511522",
                 "22211222", "56611665", "51122115", ".517715."],
        "hue": "#010002", "eye": "#faede7", "outline": "#151938",
        "accent6": "#b7b5b7", "accent7": "#f95c96", "bg": "#0e1515",
    },
    "hulk": {
        "name": "hulk",
        "grid": [".111111.", "11111111", "15151151", "51165115",
                 "52666625", "56622665", "56611665", ".566665."],
        "hue": "#010100", "eye": "#fdfdf7", "outline": "#08783b",
        "accent6": "#26e948", "bg": "#0e1515",
    },
    "thanos": {
        "name": "thanos",
        "grid": [".117711.", "75766757", "77666677", "65555556",
                 "62555526", "65111156", "61222216", ".111111."],
        "hue": "#6c6389", "eye": "#fef6fa", "outline": "#020002",
        "accent6": "#fa9627", "accent7": "#fbfa38", "bg": "#2c313b",
    },
    "black-panther": {
        "name": "black-panther",
        "grid": [".1....1.", "15155151", "11511511", "15555511",
                 "12555521", "11111111", "11111111", ".111111."],
        "hue": "#000001", "eye": "#fcfafa", "outline": "#141a38", "bg": "#0e1515",
    },
    "deadpool": {
        "name": "deadpool",
        "grid": [".566665.", "75556257", "11555511", "11155111",
                 "12111121", "11111111", "11755711", ".755555."],
        "hue": "#020001", "eye": "#fbe8e9", "outline": "#fa063a",
        "accent6": "#fb5a95", "accent7": "#b82545", "bg": "#0e1515",
    },
    "spiderman": {
        "name": "spiderman",
        "grid": [".7777777", "11111111", "15611651", "62566526",
                 "62255226", "62255226", "15566551", ".1111116"],
        "hue": "#fb0745", "eye": "#fdebe6", "outline": "#030101",
        "accent6": "#67153a", "accent7": "#fc5c94", "bg": "#541728",
    },
    "ironman": {
        "name": "ironman",
        "grid": [".111111.", "11511511", "16755231", "16672631",
                 "53366335", "56677735", "66755736", ".677276."],
        "hue": "#fa0745", "eye": "#fcf867", "highlight": "#feeae7",
        "outline": "#681537", "accent6": "#fa9717", "accent7": "#fbfa37",
        "bg": "#541728",
    },
    "cyborg": {
        "name": "cyborg",
        "grid": [".111111.", "11111111", "16611661", "17666661",
                 "65766616", "17666661", "16111161", "16161161"],
        "hue": "#000000", "outline": "#fc073d", "accent6": "#9a3c25",
        "accent7": "#4c433c", "bg": "#0e1515",
    },
    "joker": {
        "name": "joker",
        "grid": [".676676.", "67677676", "71166117", "16111161",
                 "15611651", "11111111", "13555531", ".133331."],
        "hue": "#fbf5e8", "highlight": "#fe0444", "outline": "#020100",
        "accent6": "#077739", "accent7": "#28e849", "bg": "#545956",
    },
    "flash": {
        "name": "flash",
        "grid": [".111111.", "11111111", "71111117", "76511567",
                 "16611661", "11166111", "16622661", ".166661."],
        "hue": "#fb063b", "eye": "#feebd6", "outline": "#772c36",
        "accent6": "#fbc49a", "accent7": "#fff939", "bg": "#541725",
    },
    "superman": {
        "name": "superman",
        "grid": [".555555.", "55555555", "55151155", "51115115",
                 "16111161", "11111111", "11122111", ".111111."],
        "hue": "#fdc39a", "eye": "#ffecd8", "outline": "#020101",
        "accent6": "#79d4fb", "bg": "#554b40",
    },
    "cyclops": {
        "name": "cyclops",
        "grid": ["77777777", "71111117", "15555551", "22222222",
                 "23333332", "51111115", "13666631", ".666666."],
        "hue": "#051746", "eye": "#fef845", "highlight": "#fd0944",
        "outline": "#010102", "accent6": "#fbc39b", "accent7": "#2499f7",
        "bg": "#0f1b28",
    },
    "human-torch": {
        "name": "human-torch",
        "grid": [".666622.", "66666662", "65556556", "11116133",
                 "17711773", "11177113", "51777715", "51777715"],
        "hue": "#fb0639", "eye": "#fdfb37", "highlight": "#fc5a96",
        "outline": "#9a3604", "accent6": "#fa9427", "accent7": "#fbc5a7",
        "bg": "#541725",
    },
    "lex-luthor": {
        "name": "lex-luthor",
        "grid": [".111111.", "11111111", "55511555", "16511561",
                 "12111121", "11111111", "11122111", ".111111."],
        "hue": "#fdc399", "eye": "#ffead7", "outline": "#040000",
        "accent6": "#76563b", "bg": "#554b40",
    },
    "doctor-strange": {
        "name": "doctor-strange",
        "grid": ["65555556", "55555555", "22151122", "21115112",
                 "15111151", "11155111", "11577511", "61511516"],
        "hue": "#ffc3a1", "eye": "#fffdff", "outline": "#000000",
        "accent6": "#d5133f", "accent7": "#9e2b3e", "bg": "#554b42",
    },
    "martian-manhunter": {
        "name": "martian-manhunter",
        "grid": [".111111.", "11111111", "66111166", "55611655",
                 "67566576", "61555516", "66122166", ".611116."],
        "hue": "#26e948", "eye": "#faf7e6", "outline": "#010201",
        "accent6": "#067939", "accent7": "#d71638", "bg": "#185629",
    },
    "green-goblin": {
        "name": "green-goblin",
        "grid": ["..33337.", ".7733777", "17677671", "14566541",
                 "14455441", "16166161", ".612216.", "..6116.."],
        "hue": "#28e747", "eye": "#f9f7e6", "highlight": "#fb5b99",
        "shadow": "#fcfc38", "outline": "#010401", "accent6": "#067838",
        "accent7": "#671539", "bg": "#195629",
    },
    "cloak": {
        "name": "cloak",
        "grid": [".626121.", "12111161", "11111116", "11111111",
                 "12111121", "11111111", "11122111", "61111116"],
        "hue": "#000000", "eye": "#fffa33", "accent6": "#eba329",
        "bg": "#0e1515",
    },
    "mr-fantastic": {
        "name": "mr-fantastic",
        "grid": [".666666.", "66666666", "22166122", "21111112",
                 "15111151", "11111111", "11122111", "1111111."],
        "hue": "#ffc198", "eye": "#ffefe3", "outline": "#060000",
        "accent6": "#a03828", "bg": "#554b3f",
    },
    "beast": {
        "name": "beast",
        "grid": ["66....66", "166..661", "17611661", "17611761",
                 "62511126", "65111116", ".1133116", ".711117."],
        "hue": "#219efa", "eye": "#ffff7a", "highlight": "#e7f4ff",
        "outline": "#060000", "accent6": "#15192d", "accent7": "#002058",
        "bg": "#17415b",
    },
    "antman": {
        "name": "antman",
        "grid": [".112211.", "12222221", "26122162", "26622662",
                 "21677612", "17111171", "15755751", ".155551."],
        "hue": "#b3b4b8", "eye": "#ffefe2", "outline": "#000000",
        "accent6": "#ff043e", "accent7": "#423d38", "bg": "#404748",
    },
    "loki": {
        "name": "loki",
        "grid": ["1..11..1", "15111151", "61111116", ".661166.",
                 ".221122.", "61111116", "11222211", "15222251"],
        "hue": "#fffb39", "eye": "#ffc49d", "outline": "#34513e",
        "accent6": "#f5932b", "bg": "#555b25",
    },
    "nick-fury": {
        "name": "nick-fury",
        "grid": [".666666.", "66666666", "25116622", "21511112",
                 "17155555", "11111551", "11122111", ".111111."],
        "hue": "#ffc59f", "eye": "#ffefe0", "outline": "#000000",
        "accent6": "#933e2d", "accent7": "#7ebced", "bg": "#554c41",
    },
    "black-bolt": {
        "name": "black-bolt",
        "grid": [".222222.", "21611612", "21166112", "11166111",
                 "61111116", "62122126", "61122116", ".612216."],
        "hue": "#000000", "eye": "#fff8ee", "accent6": "#b6b5b9",
        "bg": "#0e1515",
    },
    "red-skull": {
        "name": "red-skull",
        "grid": [".611116.", "61166616", "61111116", "67666676",
                 "52711725", "75177157", ".716617.", ".761167."],
        "hue": "#ff0339", "eye": "#fff2fc", "outline": "#000000",
        "accent6": "#ff5c96", "accent7": "#882e33", "bg": "#551625",
    },
    "magneto": {
        "name": "magneto",
        "grid": [".466664.", "46766764", "31177113", "61511516",
                 "61255216", "61222216", "37122176", ".312213."],
        "hue": "#695b86", "eye": "#fcc6a0", "highlight": "#ca2244",
        "shadow": "#a44972", "outline": "#18183d", "accent6": "#fa0338",
        "accent7": "#912233", "bg": "#2b2e3a",
    },
    "silver-surfer": {
        "name": "silver-surfer",
        "grid": [".111111.", "16666661", "12222221", "11622611",
                 "17622671", "16222261", "16266261", ".622226."],
        "hue": "#409ae6", "eye": "#ffefea", "accent6": "#afb4b6",
        "accent7": "#ecff5a", "bg": "#204055",
    },
    "vision": {
        "name": "vision",
        "grid": [".774447.", "71774717", "15177151", "16633661",
                 "11266211", "15566551", "15633651", ".566665."],
        "hue": "#000000", "eye": "#e1dd66", "highlight": "#ff63a4",
        "shadow": "#2fe05d", "outline": "#7e0c42", "accent6": "#f80840",
        "accent7": "#077936", "bg": "#0e1515",
    },
    "batgirl": {
        "name": "batgirl",
        "grid": ["56....65", "55666655", "51555515", "12111121",
                 "12311321", "11111111", "12277221", "..2222.."],
        "hue": "#1f143e", "eye": "#ffcbb2", "highlight": "#5bd043",
        "outline": "#656182", "accent6": "#f161a1", "accent7": "#cb587d",
        "bg": "#161a26",
    },
    "robin": {
        "name": "robin",
        "grid": [".555555.", "55555565", "55226665", "11111111",
                 "12211221", "11166111", "66622666", ".666666."],
        "hue": "#000000", "eye": "#fff2e8", "outline": "#9c3a27",
        "accent6": "#f7bf94", "bg": "#0e1515",
    },
    "daredevil": {
        "name": "daredevil",
        "grid": ["61....1.", "11111111", "11666611", "16555561",
                 "12655621", "16611111", "17722771", ".777777."],
        "hue": "#ff0340", "eye": "#ffedfe", "outline": "#101433",
        "accent6": "#671539", "accent7": "#ffc39c", "bg": "#551627",
    },
    "doom": {
        "name": "doom",
        "grid": [".111111.", "11333311", "13557111", "15662651",
                 "17726771", "15622651", "15677651", ".111111."],
        "hue": "#147743", "eye": "#fff3f7", "highlight": "#32e761",
        "outline": "#000000", "accent6": "#c0bec1", "accent7": "#504238",
        "bg": "#133628",
    },
    "captain-america": {
        "name": "captain-america",
        "grid": [".666666.", "26622662", "21211212", "11261211",
                 "17166171", "11677611", "11722711", ".777777."],
        "hue": "#02174a", "eye": "#fffff5", "accent6": "#3395f4",
        "accent7": "#ffc292", "bg": "#0e1b2a",
    },
    "thing": {
        "name": "thing",
        "grid": ["..1111..", ".112261.", "61111161", "65511556",
                 "62711726", "67111176", "61177116", "11155111"],
        "hue": "#993a28", "eye": "#fff2ec", "outline": "#63142d",
        "accent6": "#e99752", "accent7": "#ffc5a9", "bg": "#392520",
    },
    "kaonashi": {
        "name": "kaonashi",
        "grid": [".111111.", "11111111", "15511551", "11111111",
                 "15511551", "61111116", "11511511", ".115511."],
        "hue": "#fff1e5", "outline": "#000000", "accent6": "#e76990",
        "bg": "#555855",
    },
    "thor": {
        "name": "thor",
        "grid": ["22....22", ".266662.", "22666622", "61177116",
                 "63111136", "61111116", "76122167", "76111167"],
        "hue": "#f9be9b", "eye": "#fbefe2", "highlight": "#71c2e5",
        "accent6": "#c1c2c3", "accent7": "#fffc30", "bg": "#534a40",
    },
    "mystique": {
        "name": "mystique",
        "grid": [".111117.", "11722117", "13755117", "13366317",
                 "15266251", "15666651", "15611651", "13566531"],
        "hue": "#fc073d", "eye": "#fffd35", "highlight": "#6a1040",
        "outline": "#0e193f", "accent6": "#239bfc", "accent7": "#fc5d98",
        "bg": "#541726",
    },
    "harley-quinn": {
        "name": "harley-quinn",
        "grid": ["25....12", "..5511..", ".555111.", "52222221",
                 "51111111", "51611611", ".222222.", "..2222.."],
        "hue": "#000000", "eye": "#ffefe3", "outline": "#fc073d",
        "accent6": "#239bfc", "bg": "#0e1515",
    },
    "scarlett-witch": {
        "name": "scarlett-witch",
        "grid": ["1.5555.1", "11555511", "11151111", "16252261",
                 "15622651", "16666661", "51611615", "51666615"],
        "hue": "#fc073d", "eye": "#ffefe3", "outline": "#9a3c25",
        "accent6": "#fec29b", "bg": "#541726",
    },
    "gambit": {
        "name": "gambit",
        "grid": [".666666.", "6666336.", "55577556", "54155145",
                 "52111125", "51111115", "51111115", ".711117."],
        "hue": "#fec29b", "eye": "#ffefe3", "highlight": "#6a1040",
        "shadow": "#9a3c25", "outline": "#0e193f", "accent6": "#fc073d",
        "accent7": "#239bfc", "bg": "#554b40",
    },
    "war-machine": {
        "name": "war-machine",
        "grid": [".712217.", "71162117", "62162126", "62166126",
                 "15566551", "71666617", "71111117", "61777716"],
        "hue": "#0e193f", "eye": "#ffefe3", "outline": "#fc073d",
        "accent6": "#b6b7bc", "accent7": "#239bfc", "bg": "#121c27",
    },
    "plastic-man": {
        "name": "plastic-man",
        "grid": [".555555.", "55555555", "51111115", "66666666",
                 "66611666", "11111111", "11122111", ".111111."],
        "hue": "#fec29b", "eye": "#ffefe3", "outline": "#000000",
        "accent6": "#fc073d", "bg": "#554b40",
    },
    "hellboy": {
        "name": "hellboy",
        "grid": [".71..71.", ".117711.", "56611665", "51111115",
                 "52611625", "56111165", "51155115", "55555555"],
        "hue": "#fc073d", "eye": "#fffd35", "outline": "#000000",
        "accent6": "#6a1040", "accent7": "#fc5d98", "bg": "#541726",
    },
    "peacemaker": {
        "name": "peacemaker",
        "grid": [".111111.", "11111111", "11111111", "17111171",
                 "12711721", "11111111", "16666661", ".666666."],
        "hue": "#ffefe3", "eye": "#fffd35", "accent6": "#fec29b",
        "accent7": "#b6b7bc", "bg": "#555854",
    },
    "rhino": {
        "name": "rhino",
        "grid": ["...12...", ".111211.", "11622611", "16666661",
                 "16577561", "16777761", "11722711", "11111111"],
        "hue": "#b6b7bc", "eye": "#ffefe3", "outline": "#000000",
        "accent6": "#4c433c", "accent7": "#fec29b", "bg": "#41484a",
    },
    "doctor-fate": {
        "name": "doctor-fate",
        "grid": ["...11...", ".111211.", "11112116", "66122166",
                 "62112126", "67112176", "61112116", ".111111."],
        "hue": "#fffd35", "eye": "#ffefe3", "accent6": "#fd9321",
        "accent7": "#b6b7bc", "bg": "#555c24",
    },
    "rogue": {
        "name": "rogue",
        "grid": [".222226.", "26622226", "65565252", "61161216",
                 "65111156", "61111116", "61177116", "6.1111.6"],
        "hue": "#fec29b", "eye": "#ffefe3", "outline": "#000000",
        "accent6": "#9a3c25", "accent7": "#fc073d", "bg": "#554b40",
    },
    "steve": {
        "name": "steve",
        "grid": ["55555555", "55555555", "51111115", "11111111",
                 "12611621", "11155111", "11511511", "11555511"],
        "hue": "#deb3a0", "eye": "#fefefc", "outline": "#623517",
        "accent6": "#3a4aa0", "bg": "#4c4742",
    },
    "sheep": {
        "name": "sheep",
        "grid": ["11111111", "11111111", "16666661", "15166151",
                 "16666661", "11666611", "11677611", "11111111"],
        "hue": "#ffffff", "outline": "#08080a", "accent6": "#e0b5a4",
        "accent7": "#f076ab", "bg": "#555c5c",
    },
    "creeper": {
        "name": "creeper",
        "grid": ["1.111111", "11117111", "16611661", "16571561",
                 "11155.77", "71655611", "17555511", "11511571"],
        "hue": "#6bbe47", "outline": "#000000", "accent6": "#1d1d1f",
        "accent7": "#96c934", "bg": "#839f7d",
    },
    "chicken": {
        "name": "chicken",
        "grid": ["11111111", "11111111", "15111151", "11111111",
                 "11222211", "11777711", "11166111", "11166111"],
        "hue": "#ffffff", "eye": "#fdd840", "outline": "#070709",
        "accent6": "#d61f26", "accent7": "#cead29", "bg": "#555c5c",
    },
    "skeleton": {
        "name": "skeleton",
        "grid": ["11111111", "11111111", "11111111", "11111111",
                 "16611661", "11122111", "16666661", "11111111"],
        "hue": "#f1f1f3", "eye": "#c8c5c6", "accent6": "#7e8180",
        "bg": "#515859",
    },
    "enderman": {
        "name": "enderman",
        "grid": ["15111151", "15511551", "51555515", "11555515",
                 "76255267", "51155115", "15511551", "51111115"],
        "hue": "#000000", "eye": "#fbbed5", "outline": "#1c1c1c",
        "accent6": "#994ea0", "accent7": "#b670b3", "bg": "#0e1515",
    },
    "zombie": {
        "name": "zombie",
        "grid": ["11117171", "71211717", "12177171", "71271711",
                 "15511557", "71155112", "11571511", "21517512"],
        "hue": "#10a04b", "eye": "#005521", "outline": "#152a18",
        "accent7": "#1b7e41", "bg": "#508065",
    },
    "wolf": {
        "name": "wolf",
        "grid": ["11166111", "66666666", "11111111", "13311331",
                 "63577536", "67155376", "77111177", "61444416"],
        "hue": "#979495", "highlight": "#bfbdbe", "shadow": "#313035",
        "outline": "#0e0c0d", "accent6": "#6d6f73", "accent7": "#6a573d",
        "bg": "#383e3f",
    },
    "pig": {
        "name": "pig",
        "grid": ["11111111", "11111111", "11111111", "5..11..5",
                 "5..11..5", "11322311", "11111111", "11111111"],
        "hue": "#f9a8a1", "eye": "#eec8ca", "highlight": "#f28282",
        "outline": "#000000", "bg": "#ffffff",
    },
}

# fixed SORTED name order → the deterministic index a HAID hashes onto (hero_for). A
# stable sort means every surface (and the bash test parity) agrees on the mapping.
HERO_ORDER = sorted(HERO_SIGILS)

# PINNED customs — an EXACT seed → a hero face. batsy stays pinned to RJ's own HAID so
# the heimdall-sigil-custom contract (RJ's HAID → batsy, rendered RAW) is byte-identical.
CUSTOM_SIGILS = {
    "haid:rj.rishabhs-macbook-air-46d5": HERO_SIGILS["batsy"],
}

# A REAL HAID is the canonical `haid:human.machine-hash4[/role]` shape (mirrors
# bin/heimdall-haid `valid_haid`). Only a real HAID auto-assigns a hero — short demo /
# handle seeds (rj, you, teammate-xyz, haid:alice) stay on the curated/animal path, so
# every existing golden is untouched.
_HAID_RE = re.compile(r'^haid:[a-z0-9-]+\.[a-z0-9-]+-[0-9a-f]{4}(/[a-z0-9][a-z0-9-]*)?$')

def _is_haid(seed):
    return bool(_HAID_RE.match(seed or ""))

def hero_for(haid):
    """The hero a HAID deterministically auto-assigns to: sha256(haid) mod len(HERO_ORDER)
    indexed into the SORTED hero-name pool. Same HAID → same hero forever; roughly uniform
    across distinct HAIDs. This is the default sigil for any real HAID with no override."""
    idx = int(hashlib.sha256(haid.encode()).hexdigest(), 16) % len(HERO_ORDER)
    return HERO_ORDER[idx]

def _resolve_custom_spec(seed):
    """The hero spec a seed resolves to, or None (→ the unchanged curated/animal path):
        1. an EXPLICIT pin in CUSTOM_SIGILS (batsy → RJ's HAID) — always wins;
        2. an EXPLICIT hero NAME (the CLI/override seed, e.g. 'venom');
        3. a REAL HAID → its deterministic auto-assigned hero (hero_for)."""
    if seed in CUSTOM_SIGILS:
        return CUSTOM_SIGILS[seed]
    if seed in HERO_SIGILS:
        return HERO_SIGILS[seed]
    if _is_haid(seed):
        return HERO_SIGILS[hero_for(seed)]
    return None

# token → palette-key map for a hero spec. The palette is built for ONLY the keys a
# hero carries, so a spec that omits (say) accent7 renders fine — the render never
# references a token its grid does not use (asserted by the 57-hero load test).
_TOKEN_KEY = {'.': 'bg', '1': 'hue', '2': 'eye', '3': 'highlight',
              '4': 'shadow', '5': 'outline', '6': 'accent6', '7': 'accent7'}

# ── SUPERX SPRITE CAST (ported) — the generated path is a recognizable ANIMAL, not
#    a blob. The superx dashboard shipped a cast of full-body pixel characters (one
#    per agent role) that READ as characters because each had an unmistakable
#    SILHOUETTE. That cast is ported here to the statusline's 8x8 half-block grid:
#    the distinguishing cues that survive at 4-row terminal scale — EAR shape (top
#    text-row) + BODY silhouette (bottom two text-rows) — are hand-authored per
#    animal; the middle band (rows 2,3) is reserved for the universal watchman finish
#    (carved dark + full-cell eyes at cols 2 & 5), so every animal still reads as a
#    face. Values: 0=off (DIM silhouette block), 1=body hue, 2=eye. Every row is
#    vertically symmetric (mirror about the 3.5 axis) — the render/width invariant.
#    A HAID is mapped DETERMINISTICALLY onto one animal (sha256(seed)[0] % 8), so
#    each dev gets a STABLE, recognizable character forever — 8 animals × distinct
#    per-character hues, never the one muddy guardian for everyone.
ANIMALS = {
    # owl — architect: ear tufts at the outer corners, round tapered body, talons.
    'owl':    ["10000001", "11111111", "01111110", "01111110",
               "01111110", "01111110", "00111100", "01000010"],
    # fox — coder: pointed ears (wide at the base), a slim body, legs + shoes.
    'fox':    ["01000010", "11100111", "01111110", "01111110",
               "00111100", "00111100", "01100110", "11000011"],
    # cat — design: two-pronged pointed ears, slim body.
    'cat':    ["10100101", "01111110", "01111110", "01111110",
               "01111110", "00111100", "00111100", "01100110"],
    # rabbit — test-runner: tall thin centered ears merging into the crown.
    'rabbit': ["00100100", "00111100", "01111110", "01111110",
               "01111110", "01111110", "00111100", "01100110"],
    # panda — lint-quality: small round mid-ears, a wide belly.
    'panda':  ["01100110", "11111111", "01111110", "01111110",
               "11111111", "01111110", "01111110", "01100110"],
    # bear — reviewer: round ears at the extreme corners, a wide head + body.
    'bear':   ["11000011", "11111111", "01111110", "01111110",
               "01111110", "01111110", "01111110", "01100110"],
    # dog — docs-writer: floppy ears hang down the sides (cols 0,7 lit at row 4).
    'dog':    ["01111110", "11111111", "01111110", "01111110",
               "11111111", "01111110", "01111110", "01100110"],
    # monk — superx mascot: bald narrow crown (no ears), robe flares wide at the base.
    'monk':   ["00111100", "01111110", "01111110", "01111110",
               "01111110", "01111110", "11111111", "11111111"],
}
# fixed order → deterministic index from the HAID hash (bash-3.2 test parity too).
ANIMAL_ORDER = ['owl', 'fox', 'cat', 'rabbit', 'panda', 'bear', 'dog', 'monk']
# per-character hue — a well-separated categorical palette echoing the superx role
# colors, so two devs on different animals are also different COLORS (max distinction).
ANIMAL_HUES = {
    'owl':    (52, 152, 219),    # blue
    'fox':    (46, 204, 113),    # green
    'cat':    (224, 86, 160),    # magenta
    'rabbit': (241, 196, 15),    # yellow
    'panda':  (200, 205, 210),   # light slate (patches read against the dark band)
    'bear':   (231, 76, 60),     # red
    'dog':    (26, 188, 156),    # teal
    'monk':   (230, 126, 34),    # orange
}

EYE = (240, 248, 255)   # bright eye glint (aliceblue)
DIM = (19, 21, 29)       # OFF pixel — a DIM FILLED cell (#13151d) -> solid silhouette
OFF = None               # legacy transparent sentinel (kept for color()/glyph back-compat)

W, H = 8, 8
EYE_COLS = (2, W - 1 - 2)   # cols 2 & 5 — symmetric, with a defined gap between them

# pixel-grid resolution per size token. rendered N cols × N/2 text-rows (half-block),
# so each is an EXACT SQUARE: N px wide × N px tall.
SIZES = {'S': 4, 'M': 8, 'L': 16}


# ══════════════════════════════════════════════════════════════════════════════
# DETAILED TIER ('D') — RJ's 132 hand-authored 16×16 sprites + detailed-tier shading
# ══════════════════════════════════════════════════════════════════════════════
# The compact 8×8 cast (above) is the always-on statusline face: it must read at 4
# text-rows, so it drops to a silhouette + eyes and stays FLAT (byte-identical to the
# `sigil` branch — the statusline-density/render goldens key on it). The surfaces that
# HAVE the space (the share card / `hmd-banner --share`, the banner, `hmd watch`)
# render this richer 'D' tier: a 16×16 hand-authored sprite (16 cols × 8 half-block
# text-rows) with real 8-bit CHARACTER detail + tonal SHADING baked in by the artist.
#
# Baked LITERALS (parsed once at import — the render is then a dict lookup, well under
# 50ms; the delivery file is NOT shipped). Each sprite: a 16-row grid over the alphabet
#   . = bg   1 = body(hue)   2 = eye(full white)   3 = highlight   4 = shadow
#   5 = outline(near-black)  6 = accentA(accent6)  7 = accentB(accent7)
# plus hue / bg (always) and accent6 / accent7 (only when the grid uses 6 / 7).
#
# VALUE→COLOR at the 'D' tier (this IS the shading — highlight/shadow placement is
# hand-authored, the bg is a subtle top-left-lit diagonal gradient):
#   1 → hue            2 → full white eye        5 → carved outline (SILHOUETTE edge)
#   3 → hue lightened  4 → hue darkened          6 → accent6 hex   7 → accent7 hex
#   . → bg hex rendered as a subtle top-left-lit diagonal gradient (terminal-safe)
# 3 and 4 are DERIVED from the hue (the shading ramp); 6/7 are the authored accents.
#
# ANTI-SPECKLE (the load-bearing fix): value 5 is the INK LINE, but the artist also
# uses lone/short interior 5s for muzzle/mouth/nose marks. On the 2-px-per-cell `▀`
# pack a near-black interior 5 sitting over a body pixel renders as a half-black cell
# = a scattered BLACK DOT peppering the fill (RJ's #1 reject). So value 5 is split by
# POSITION at render time: a 5 that borders the bg ('.') is the true silhouette
# OUTLINE and keeps the ink color; a 5 with NO bg neighbor is an INTERIOR feature mark
# and is recolored to the soft SHADOW tone (value-4 color) — the mark survives (so
# emotion variants still differ) but never reads as a near-black speck. See
# `_render_detailed`. The eyes get a parallel de-speckle: a 2×2 eye block is grown to
# fill its text cell so a pixel-row-straddled eye reads as a solid white square, never
# a half-split checker (BUG 3).
WHITE   = (255, 255, 255)   # value 2 — a full, bright white eye (no pupil)
BLACK   = (0, 0, 0)
OUTLINE = (48, 52, 64)      # value 5 (SILHOUETTE edge) — a drawn dark edge, not a black void
HL_LIFT = 0.24              # value 3 highlight = hue lifted this far toward white
SH_DROP = 0.30              # value 4 shadow    = hue dropped this far toward black (keeps hue saturated)
BG_LIGHT = 0.15             # '.' top-left lit   (subtle diagonal gradient of bg hex, half strength)
BG_DARK  = 0.17             # '.' bottom-right shaded (half strength)


def _clamp8(x):
    x = int(round(x));  return 0 if x < 0 else 255 if x > 255 else x

def _mix(a, b, t):
    """Linear-interpolate two RGBs (t=0 → a, t=1 → b)."""
    return (_clamp8(a[0] + (b[0] - a[0]) * t),
            _clamp8(a[1] + (b[1] - a[1]) * t),
            _clamp8(a[2] + (b[2] - a[2]) * t))

def _hex_rgb(h):
    """'#rrggbb' → (r,g,b)."""
    h = h.lstrip('#');  return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

DETAILED_SPRITES = {
    # ── cat ──
    "cat": {"hue": "#e8a13c", "bg": "#4f4226", "grid": ["................", "...5........5...", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111111111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "cat-joy": {"hue": "#e8a13c", "bg": "#4f4226", "grid": ["................", "...5........5...", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".54111111111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "cat-grump": {"hue": "#8f9aa8", "bg": "#364044", "grid": ["................", "...5........5...", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".54111111111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "cat-shock": {"hue": "#8f9aa8", "bg": "#364044", "grid": ["................", "...5........5...", "..535......535..", "..531555555135..", "..533311113315..", ".53322111122145.", ".53122111122145.", ".51111111111145.", ".51111155111145.", ".51111155111145.", ".54111111111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "cat-blep": {"hue": "#e8d5b0", "accent7": "#e08a9b", "bg": "#4f5146", "grid": ["................", "...5........5...", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115555511145.", ".51111177111145.", ".54111111111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "cat-rage": {"hue": "#566073", "bg": "#263035", "grid": ["................", "...5........5...", "..535......535..", "..531555555135..", "..533311113315..", ".53351111115145.", ".53122111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".54111111111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "cat-shifty": {"hue": "#e8d5b0", "bg": "#4f5146", "grid": ["................", "...5........5...", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53152111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111111111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── fox ──
    "fox": {"hue": "#e0783c", "accent6": "#f0c8a0", "bg": "#4c3626", "grid": ["..5..........5..", "..55........55..", "..565......565..", "..561555555165..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "fox-grin": {"hue": "#e0783c", "accent6": "#f0c8a0", "accent7": "#e08a9b", "bg": "#4c3626", "grid": ["..5..........5..", "..55........55..", "..565......565..", "..561555555165..", "..533311113315..", ".53322111122145.", ".53122111122145.", ".51115555551145.", ".51115777751145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "fox-shifty": {"hue": "#e0783c", "accent6": "#f0c8a0", "bg": "#4c3626", "grid": ["..5..........5..", "..55........55..", "..565......565..", "..561555555165..", "..533311113315..", ".53311111111145.", ".53152111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "fox-rage": {"hue": "#b0503c", "accent6": "#f0c8a0", "bg": "#3f2b26", "grid": ["..5..........5..", "..55........55..", "..565......565..", "..561555555165..", "..533311113315..", ".53351111115145.", ".53122111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "fox-neutral": {"hue": "#d7dde3", "accent6": "#f0c8a0", "bg": "#4a5354", "grid": ["..5..........5..", "..55........55..", "..565......565..", "..561555555165..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "fox-blep": {"hue": "#d7dde3", "accent6": "#f0c8a0", "accent7": "#e08a9b", "bg": "#4a5354", "grid": ["..5..........5..", "..55........55..", "..565......565..", "..561555555165..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115555511145.", ".51111177111145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "fox-worry": {"hue": "#b0503c", "accent6": "#f0c8a0", "bg": "#3f2b26", "grid": ["..5..........5..", "..55........55..", "..565......565..", "..561555555165..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115151515145.", ".51151515151145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── rabbit ──
    "rabbit": {"hue": "#d7c8e8", "accent6": "#e08a9b", "bg": "#4a4d56", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511111111145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "rabbit-joy": {"hue": "#d7c8e8", "accent6": "#e08a9b", "bg": "#4a4d56", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511511115145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "rabbit-shock": {"hue": "#e8e4da", "accent6": "#e08a9b", "bg": "#4f5552", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..532211112245..", "..512211112245..", "..511111111145..", "..511115511145..", "..541115511445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "rabbit-worry": {"hue": "#e8e4da", "accent6": "#e08a9b", "bg": "#4f5552", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511515151545..", "..545151515445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "rabbit-blep": {"hue": "#a8845c", "accent6": "#e08a9b", "accent7": "#e08a9b", "bg": "#3d3a2f", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511555551145..", "..541117711445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "rabbit-glee": {"hue": "#a8845c", "accent6": "#e08a9b", "bg": "#3d3a2f", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..532211112245..", "..512211112245..", "..511555555145..", "..511555555145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "rabbit-grump": {"hue": "#d7c8e8", "accent6": "#e08a9b", "bg": "#4a4d56", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511155551145..", "..541511115445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── panda ──
    "panda": {"hue": "#e8e4dc", "accent6": "#2e3338", "bg": "#4f5552", "grid": ["................", "..555......555..", ".56665....56665.", "..565555555565..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "panda-joy": {"hue": "#e8e4dc", "accent6": "#2e3338", "bg": "#4f5552", "grid": ["................", "..555......555..", ".56665....56665.", "..565555555565..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "panda-blep": {"hue": "#e8e4dc", "accent6": "#2e3338", "accent7": "#e08a9b", "bg": "#4f5552", "grid": ["................", "..555......555..", ".56665....56665.", "..565555555565..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115555511145.", ".51111177111145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "panda-shock": {"hue": "#e8e4dc", "accent6": "#2e3338", "bg": "#4f5552", "grid": ["................", "..555......555..", ".56665....56665.", "..565555555565..", "..533311113315..", ".53322111122145.", ".53122111122145.", ".51111111111145.", ".51111155111145.", ".51111155111145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "panda-worry": {"hue": "#e8e4dc", "accent6": "#2e3338", "bg": "#4f5552", "grid": ["................", "..555......555..", ".56665....56665.", "..565555555565..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115151515145.", ".51151515151145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "panda-glee": {"hue": "#e8e4dc", "accent6": "#2e3338", "bg": "#4f5552", "grid": ["................", "..555......555..", ".56665....56665.", "..565555555565..", "..533311113315..", ".53322111122145.", ".53122111122145.", ".51115555551145.", ".51115555551145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "panda-shifty": {"hue": "#e8e4dc", "accent6": "#2e3338", "bg": "#4f5552", "grid": ["................", "..555......555..", ".56665....56665.", "..565555555565..", "..533311113315..", ".53311111111145.", ".53152111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── dog ──
    "dog": {"hue": "#c89b6a", "accent6": "#3a2f28", "bg": "#464033", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54511111111545.", ".54522111122545.", ".54522111122545.", ".55515111151555.", "...5115555145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "dog-glee": {"hue": "#c89b6a", "accent6": "#3a2f28", "bg": "#464033", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54522111122545.", ".54522111122545.", ".54515555551545.", ".55515555551555.", "...5115555145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "dog-blep": {"hue": "#c89b6a", "accent6": "#3a2f28", "accent7": "#e08a9b", "bg": "#464033", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54511111111545.", ".54522111122545.", ".54522111122545.", ".55515555511555.", "...5111771145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "dog-neutral": {"hue": "#98a8b8", "accent6": "#3a2f28", "bg": "#384448", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54511111111545.", ".54522111122545.", ".54522111122545.", ".55511111111555.", "...5115555145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "dog-worry": {"hue": "#98a8b8", "accent6": "#3a2f28", "bg": "#384448", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54511111111545.", ".54522111122545.", ".54522111122545.", ".55515151515555.", "...5515151545...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "dog-shock": {"hue": "#7a5236", "accent6": "#3a2f28", "bg": "#302c24", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54522111122545.", ".54522111122545.", ".54511111111545.", ".55511155111555.", "...5111551145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "dog-grin": {"hue": "#7a5236", "accent6": "#3a2f28", "accent7": "#e08a9b", "bg": "#302c24", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54522111122545.", ".54522111122545.", ".54515555551545.", ".55515777751555.", "...5115555145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── owl ──
    "owl": {"hue": "#8a7462", "accent6": "#e8963c", "accent7": "#d9c9a8", "bg": "#343530", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "owl-shifty": {"hue": "#8a7462", "accent6": "#e8963c", "accent7": "#d9c9a8", "bg": "#343530", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53152111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "owl-shock": {"hue": "#e3e0d5", "accent6": "#e8963c", "accent7": "#d9c9a8", "bg": "#4d5451", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53322111122145.", ".53122111122145.", ".51111111111145.", ".51111155111145.", ".51111155111145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "owl-grump": {"hue": "#e3e0d5", "accent6": "#e8963c", "accent7": "#d9c9a8", "bg": "#4d5451", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "owl-rage": {"hue": "#b58d4f", "accent6": "#e8963c", "accent7": "#d9c9a8", "bg": "#403c2b", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53351111115145.", ".53122111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "owl-joy": {"hue": "#b58d4f", "accent6": "#e8963c", "accent7": "#d9c9a8", "bg": "#403c2b", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "owl-worry": {"hue": "#8a7462", "accent6": "#e8963c", "accent7": "#d9c9a8", "bg": "#343530", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115151515145.", ".51151515151145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── frog ──
    "frog": {"hue": "#6fae4e", "bg": "#2d462b", "grid": ["...55......55...", "..5335....5335..", "..533555555335..", ".53322111122145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    "frog-joy": {"hue": "#6fae4e", "bg": "#2d462b", "grid": ["...55......55...", "..5335....5335..", "..533555555335..", ".53322111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    "frog-grump": {"hue": "#6fae4e", "bg": "#2d462b", "grid": ["...55......55...", "..5335....5335..", "..533555555335..", ".53322111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    "frog-worry": {"hue": "#8fd14f", "bg": "#364f2b", "grid": ["...55......55...", "..5335....5335..", "..533555555335..", ".53322111122145.", ".51122111122145.", ".51115151515145.", ".51151515151145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    "frog-shifty": {"hue": "#8fd14f", "bg": "#364f2b", "grid": ["...55......55...", "..5335....5335..", "..533555555335..", ".53352111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    "frog-blep": {"hue": "#4e8ba3", "accent7": "#e08a9b", "bg": "#243c43", "grid": ["...55......55...", "..5335....5335..", "..533555555335..", ".53322111122145.", ".51122111122145.", ".51115555511145.", ".51111177111145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    "frog-rage": {"hue": "#4e8ba3", "bg": "#243c43", "grid": ["...55......55...", "..5335....5335..", "..535555555535..", ".53322111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    # ── penguin ──
    "penguin": {"hue": "#4a5a6e", "accent6": "#eef2f0", "accent7": "#e8963c", "bg": "#222e34", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511111111145..", "..511155551145..", "..516666661145..", "..516666661145..", "..541666661445..", "..541666661445..", "..541111111145..", "..541111111145..", "...5775..5775...", "................"]},
    "penguin-joy": {"hue": "#4a5a6e", "accent6": "#eef2f0", "accent7": "#e8963c", "bg": "#222e34", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511511115145..", "..511155551145..", "..516666661145..", "..516666661145..", "..541666661445..", "..541666661445..", "..541111111145..", "..541111111145..", "...5775..5775...", "................"]},
    "penguin-shock": {"hue": "#4a5a6e", "accent6": "#eef2f0", "accent7": "#e8963c", "bg": "#222e34", "grid": ["................", "....55555555....", "...5333333115...", "..532211112215..", "..532211112245..", "..511111111145..", "..511115511145..", "..511115511145..", "..516666661145..", "..516666661145..", "..541666661445..", "..541666661445..", "..541111111145..", "..541111111145..", "...5775..5775...", "................"]},
    "penguin-worry": {"hue": "#37414f", "accent6": "#eef2f0", "accent7": "#e8963c", "bg": "#1d272b", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511515151545..", "..515151515145..", "..516666661145..", "..516666661145..", "..541666661445..", "..541666661445..", "..541111111145..", "..541111111145..", "...5775..5775...", "................"]},
    "penguin-glee": {"hue": "#37414f", "accent6": "#eef2f0", "accent7": "#e8963c", "bg": "#1d272b", "grid": ["................", "....55555555....", "...5333333115...", "..532211112215..", "..532211112245..", "..511555555145..", "..511555555145..", "..511155551145..", "..516666661145..", "..516666661145..", "..541666661445..", "..541666661445..", "..541111111145..", "..541111111145..", "...5775..5775...", "................"]},
    "penguin-shifty": {"hue": "#5d7288", "accent6": "#eef2f0", "accent7": "#e8963c", "bg": "#28353b", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", "..535211115245..", "..512211112245..", "..511111111145..", "..511155551145..", "..516666661145..", "..516666661145..", "..541666661445..", "..541666661445..", "..541111111145..", "..541111111145..", "...5775..5775...", "................"]},
    "penguin-grump": {"hue": "#5d7288", "accent6": "#eef2f0", "accent7": "#e8963c", "bg": "#28353b", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511155551145..", "..511511115145..", "..516666661145..", "..516666661145..", "..541666661445..", "..541666661445..", "..541111111145..", "..541111111145..", "...5775..5775...", "................"]},
    # ── robot ──
    "robot": {"hue": "#8f9aa8", "accent6": "#e8b23c", "bg": "#364044", "grid": [".......55.......", "......5665......", "..555555555555..", "..533333333315..", "..531111111145..", "..512211112245..", "..512211112245..", "..511111111145..", "..544455554445..", "..555555555555..", "...5411111145...", "...5411661145...", "...5411111145...", "...5411111145...", "....545..545....", "................"]},
    "robot-shock": {"hue": "#8f9aa8", "accent6": "#e8b23c", "bg": "#364044", "grid": [".......55.......", "......5665......", "..555555555555..", "..533333333315..", "..532211112245..", "..512211112245..", "..511111111145..", "..511115511145..", "..544445544445..", "..555555555555..", "...5411111145...", "...5411661145...", "...5411111145...", "...5411111145...", "....545..545....", "................"]},
    "robot-grump": {"hue": "#8f9aa8", "accent6": "#e8b23c", "bg": "#364044", "grid": [".......55.......", "......5665......", "..555555555555..", "..533333333315..", "..531111111145..", "..512211112245..", "..512211112245..", "..511155551145..", "..544544445445..", "..555555555555..", "...5411111145...", "...5411661145...", "...5411111145...", "...5411111145...", "....545..545....", "................"]},
    "robot-rage": {"hue": "#c07840", "accent6": "#e8b23c", "bg": "#433627", "grid": [".......55.......", "......5665......", "..555555555555..", "..533333333315..", "..535111111545..", "..512211112245..", "..512211112245..", "..511155551145..", "..544544445445..", "..555555555555..", "...5411111145...", "...5411661145...", "...5411111145...", "...5411111145...", "....545..545....", "................"]},
    "robot-glee": {"hue": "#c07840", "accent6": "#e8b23c", "bg": "#433627", "grid": [".......55.......", "......5665......", "..555555555555..", "..533333333315..", "..532211112245..", "..512211112245..", "..511555555145..", "..511555555145..", "..544455554445..", "..555555555555..", "...5411111145...", "...5411661145...", "...5411111145...", "...5411111145...", "....545..545....", "................"]},
    "robot-shifty": {"hue": "#6e8a94", "accent6": "#e8b23c", "bg": "#2c3c3e", "grid": [".......55.......", "......5665......", "..555555555555..", "..533333333315..", "..531111111145..", "..515211115245..", "..512211112245..", "..511111111145..", "..544455554445..", "..555555555555..", "...5411111145...", "...5411661145...", "...5411111145...", "...5411111145...", "....545..545....", "................"]},
    "robot-worry": {"hue": "#6e8a94", "accent6": "#e8b23c", "bg": "#2c3c3e", "grid": [".......55.......", "......5665......", "..555555555555..", "..533333333315..", "..531111111145..", "..512211112245..", "..512211112245..", "..511515151545..", "..545454545445..", "..555555555555..", "...5411111145...", "...5411661145...", "...5411111145...", "...5411111145...", "....545..545....", "................"]},
    # ── ghost ──
    "ghost": {"hue": "#cfd8de", "bg": "#485153", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".51111111111145.", ".51111111111145.", ".54111111111445.", ".51111111111145.", ".54114411441145.", ".55..55..55..55.", "................"]},
    "ghost-shock": {"hue": "#cfd8de", "bg": "#485153", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", ".53322111122145.", ".53122111122145.", ".51111111111145.", ".51111155111145.", ".51111155111145.", ".51111111111145.", ".51111111111145.", ".54111111111445.", ".51111111111145.", ".54114411441145.", ".55..55..55..55.", "................"]},
    "ghost-worry": {"hue": "#cfd8de", "bg": "#485153", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115151515145.", ".51151515151145.", ".51111111111145.", ".51111111111145.", ".54111111111445.", ".51111111111145.", ".54114411441145.", ".55..55..55..55.", "................"]},
    "ghost-joy": {"hue": "#cfd8de", "bg": "#485153", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".51111111111145.", ".51111111111145.", ".54111111111445.", ".51111111111145.", ".54114411441145.", ".55..55..55..55.", "................"]},
    "ghost-glee": {"hue": "#aebfd4", "bg": "#3e4a50", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", ".53322111122145.", ".53122111122145.", ".51115555551145.", ".51115555551145.", ".51111555511145.", ".51111111111145.", ".51111111111145.", ".54111111111445.", ".51111111111145.", ".54114411441145.", ".55..55..55..55.", "................"]},
    "ghost-shifty": {"hue": "#aebfd4", "bg": "#3e4a50", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", ".53311111111145.", ".53152111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".51111111111145.", ".51111111111145.", ".54111111111445.", ".51111111111145.", ".54114411441145.", ".55..55..55..55.", "................"]},
    "ghost-grump": {"hue": "#9aa8c4", "bg": "#39444c", "grid": ["................", "....55555555....", "...5333333115...", "..533111111115..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".51111111111145.", ".51111111111145.", ".54111111111445.", ".51111111111145.", ".54114411441145.", ".55..55..55..55.", "................"]},
    # ── slime ──
    "slime": {"hue": "#5fb86a", "bg": "#284833", "grid": ["................", "................", "......5555......", "....55333355....", "...5333111135...", "..533111111115..", ".53122111122145.", ".51122111122145.", ".51115111151145.", ".54111555511445.", ".54111111111445.", ".54111111111445.", "..544444444445..", "...5555555555...", "................", "................"]},
    "slime-glee": {"hue": "#5fb86a", "bg": "#284833", "grid": ["................", "................", "......5555......", "....55333355....", "...5333111135...", "..532211112215..", ".53122111122145.", ".51115555551145.", ".51115555551145.", ".54111555511445.", ".54111111111445.", ".54111111111445.", "..544444444445..", "...5555555555...", "................", "................"]},
    "slime-blep": {"hue": "#4a90c2", "accent7": "#e08a9b", "bg": "#223d4b", "grid": ["................", "................", "......5555......", "....55333355....", "...5333111135...", "..533111111115..", ".53122111122145.", ".51122111122145.", ".51115555511145.", ".54111177111445.", ".54111111111445.", ".54111111111445.", "..544444444445..", "...5555555555...", "................", "................"]},
    "slime-neutral": {"hue": "#4a90c2", "bg": "#223d4b", "grid": ["................", "................", "......5555......", "....55333355....", "...5333111135...", "..533111111115..", ".53122111122145.", ".51122111122145.", ".51111111111145.", ".54111555511445.", ".54111111111445.", ".54111111111445.", "..544444444445..", "...5555555555...", "................", "................"]},
    "slime-shock": {"hue": "#d878a8", "bg": "#4a3644", "grid": ["................", "................", "......5555......", "....55333355....", "...5333111135...", "..532211112215..", ".53122111122145.", ".51111111111145.", ".51111155111145.", ".54111155111445.", ".54111111111445.", ".54111111111445.", "..544444444445..", "...5555555555...", "................", "................"]},
    "slime-worry": {"hue": "#d878a8", "bg": "#4a3644", "grid": ["................", "................", "......5555......", "....55333355....", "...5333111135...", "..533111111115..", ".53122111122145.", ".51122111122145.", ".51115151515145.", ".54151515151445.", ".54111111111445.", ".54111111111445.", "..544444444445..", "...5555555555...", "................", "................"]},
    "slime-grin": {"hue": "#5fb86a", "accent7": "#e08a9b", "bg": "#284833", "grid": ["................", "................", "......5555......", "....55333355....", "...5333111135...", "..532211112215..", ".53122111122145.", ".51115555551145.", ".51115777751145.", ".54111555511445.", ".54111111111445.", ".54111111111445.", "..544444444445..", "...5555555555...", "................", "................"]},
    # ── dragon ──
    "dragon": {"hue": "#c25050", "accent6": "#e8d5b0", "accent7": "#e08a9b", "bg": "#442b2b", "grid": ["...66......66...", "....66....66....", "....55555555....", "...5333333115...", "..535111111515..", "..532211112245..", "..512211112245..", "..511155551145..", "..511511115145..", "..541166111445..", "..541111111145..", "..541111111145..", "..547474747445..", "..541111111145..", "...5445..5445...", "................"]},
    "dragon-grin": {"hue": "#c25050", "accent6": "#e8d5b0", "accent7": "#e08a9b", "bg": "#442b2b", "grid": ["...66......66...", "....66....66....", "....55555555....", "...5333333115...", "..532211112215..", "..532211112245..", "..511555555145..", "..511577775145..", "..511155551145..", "..541166111445..", "..541111111145..", "..541111111145..", "..547474747445..", "..541111111145..", "...5445..5445...", "................"]},
    "dragon-neutral": {"hue": "#4f9e6b", "accent6": "#e8d5b0", "accent7": "#e08a9b", "bg": "#244133", "grid": ["...66......66...", "....66....66....", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511111111145..", "..511155551145..", "..541166111445..", "..541111111145..", "..541111111145..", "..547474747445..", "..541111111145..", "...5445..5445...", "................"]},
    "dragon-joy": {"hue": "#4f9e6b", "accent6": "#e8d5b0", "accent7": "#e08a9b", "bg": "#244133", "grid": ["...66......66...", "....66....66....", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511511115145..", "..511155551145..", "..541166111445..", "..541111111145..", "..541111111145..", "..547474747445..", "..541111111145..", "...5445..5445...", "................"]},
    "dragon-shock": {"hue": "#4a7ec2", "accent6": "#e8d5b0", "accent7": "#e08a9b", "bg": "#22384b", "grid": ["...66......66...", "....66....66....", "....55555555....", "...5333333115...", "..532211112215..", "..532211112245..", "..511111111145..", "..511115511145..", "..511115511145..", "..541166111445..", "..541111111145..", "..541111111145..", "..547474747445..", "..541111111145..", "...5445..5445...", "................"]},
    "dragon-grump": {"hue": "#4a7ec2", "accent6": "#e8d5b0", "accent7": "#e08a9b", "bg": "#22384b", "grid": ["...66......66...", "....66....66....", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511155551145..", "..511511115145..", "..541166111445..", "..541111111145..", "..541111111145..", "..547474747445..", "..541111111145..", "...5445..5445...", "................"]},
    "dragon-shifty": {"hue": "#4f9e6b", "accent6": "#e8d5b0", "accent7": "#e08a9b", "bg": "#244133", "grid": ["...66......66...", "....66....66....", "....55555555....", "...5333333115...", "..533111111115..", "..535211115245..", "..512211112245..", "..511111111145..", "..511155551145..", "..541166111445..", "..541111111145..", "..541111111145..", "..547474747445..", "..541111111145..", "...5445..5445...", "................"]},
    # ── bat ──
    "bat": {"hue": "#7a68b8", "bg": "#303248", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5333111135...", "..532211112245..", ".54522111122545.", ".54511111111545.", ".55511555511555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "bat-shock": {"hue": "#7a68b8", "bg": "#303248", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5223111225...", "..532211112245..", ".54531111111545.", ".54511155111545.", ".55511155111555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "bat-shifty": {"hue": "#566073", "bg": "#263035", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5333111135...", "..535211115245..", ".54522111122545.", ".54511111111545.", ".55511555511555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "bat-rage": {"hue": "#566073", "bg": "#263035", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5533111155...", "..532211112245..", ".54522111122545.", ".54511555511545.", ".55515111151555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "bat-worry": {"hue": "#98a8b8", "bg": "#384448", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5333111135...", "..532211112245..", ".54522111122545.", ".54515151515545.", ".55551515151555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "bat-glee": {"hue": "#98a8b8", "bg": "#384448", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5223111225...", "..532211112245..", ".54535555551545.", ".54515555551545.", ".55511555511555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "bat-grump": {"hue": "#7a68b8", "bg": "#303248", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5333111135...", "..532211112245..", ".54522111122545.", ".54511555511545.", ".55515111151555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── monk ──
    "monk": {"hue": "#b05a3c", "accent6": "#d9a441", "bg": "#3f2e26", "grid": ["....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511111111145..", "..541155551445..", "..566666666665..", "..541111111145..", ".54111111111145.", ".54111111111145.", ".54111111111145.", ".54444444444445.", "..55........55..", "................"]},
    "monk-joy": {"hue": "#b05a3c", "accent6": "#d9a441", "bg": "#3f2e26", "grid": ["....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511511115145..", "..541155551445..", "..566666666665..", "..541111111145..", ".54111111111145.", ".54111111111145.", ".54111111111145.", ".54444444444445.", "..55........55..", "................"]},
    "monk-shifty": {"hue": "#b05a3c", "accent6": "#d9a441", "bg": "#3f2e26", "grid": ["....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..515211115245..", "..512211112245..", "..511111111145..", "..541155551445..", "..566666666665..", "..541111111145..", ".54111111111145.", ".54111111111145.", ".54111111111145.", ".54444444444445.", "..55........55..", "................"]},
    "monk-grump": {"hue": "#4f9e8b", "accent6": "#d9a441", "bg": "#24413c", "grid": ["....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511155551145..", "..541511115445..", "..566666666665..", "..541111111145..", ".54111111111145.", ".54111111111145.", ".54111111111145.", ".54444444444445.", "..55........55..", "................"]},
    "monk-worry": {"hue": "#4f9e8b", "accent6": "#d9a441", "bg": "#24413c", "grid": ["....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511515151545..", "..545151515445..", "..566666666665..", "..541111111145..", ".54111111111145.", ".54111111111145.", ".54111111111145.", ".54444444444445.", "..55........55..", "................"]},
    "monk-shock": {"hue": "#4f9e8b", "accent6": "#d9a441", "bg": "#24413c", "grid": ["....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511111111145..", "..511115511145..", "..541115511445..", "..566666666665..", "..541111111145..", ".54111111111145.", ".54111111111145.", ".54111111111145.", ".54444444444445.", "..55........55..", "................"]},
    "monk-glee": {"hue": "#b05a3c", "accent6": "#d9a441", "bg": "#3f2e26", "grid": ["....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511555555145..", "..511555555145..", "..541155551445..", "..566666666665..", "..541111111145..", ".54111111111145.", ".54111111111145.", ".54111111111145.", ".54444444444445.", "..55........55..", "................"]},
    # ── sprout ──
    "sprout": {"hue": "#7ab648", "accent6": "#4f8a2f", "bg": "#304829", "grid": ["......66........", ".....6666.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511511115145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "sprout-neutral": {"hue": "#7ab648", "accent6": "#4f8a2f", "bg": "#304829", "grid": ["......66........", ".....6666.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511111111145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "sprout-blep": {"hue": "#7ab648", "accent6": "#4f8a2f", "accent7": "#e08a9b", "bg": "#304829", "grid": ["......66........", ".....6666.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511555551145..", "..541117711445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "sprout-shock": {"hue": "#a4cf5a", "accent6": "#4f8a2f", "bg": "#3c4f2e", "grid": ["......66........", ".....6666.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511111111145..", "..511115511145..", "..541115511445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "sprout-worry": {"hue": "#a4cf5a", "accent6": "#4f8a2f", "bg": "#3c4f2e", "grid": ["......66........", ".....6666.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511515151545..", "..545151515445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "sprout-glee": {"hue": "#a4cf5a", "accent6": "#4f8a2f", "bg": "#3c4f2e", "grid": ["......66........", ".....6666.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511555555145..", "..511555555145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "sprout-shifty": {"hue": "#7ab648", "accent6": "#4f8a2f", "bg": "#304829", "grid": ["......66........", ".....6666.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..531111111145..", "..515211115245..", "..512211112245..", "..511111111145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── mouse ──
    "mouse": {"hue": "#8f9aa8", "accent6": "#e08a9b", "bg": "#364044", "grid": ["................", "..555......555..", ".53335....53335.", ".53315555551335.", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "mouse-joy": {"hue": "#8f9aa8", "accent6": "#e08a9b", "bg": "#364044", "grid": ["................", "..555......555..", ".53335....53335.", ".53315555551335.", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "mouse-glee": {"hue": "#a8845c", "accent6": "#e08a9b", "bg": "#3d3a2f", "grid": ["................", "..555......555..", ".53335....53335.", ".53315555551335.", "..533311113315..", ".53322111122145.", ".53122111122145.", ".51115555551145.", ".51115555551145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "mouse-shock": {"hue": "#a8845c", "accent6": "#e08a9b", "bg": "#3d3a2f", "grid": ["................", "..555......555..", ".53335....53335.", ".53315555551335.", "..533311113315..", ".53322111122145.", ".53122111122145.", ".51111111111145.", ".51111155111145.", ".51111155111145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "mouse-blep": {"hue": "#e8d5b0", "accent6": "#e08a9b", "accent7": "#e08a9b", "bg": "#4f5146", "grid": ["................", "..555......555..", ".53335....53335.", ".53315555551335.", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51115555511145.", ".51111177111145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "mouse-shifty": {"hue": "#e8d5b0", "accent6": "#e08a9b", "bg": "#4f5146", "grid": ["................", "..555......555..", ".53335....53335.", ".53315555551335.", "..533311113315..", ".53311111111145.", ".53152111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    "mouse-grump": {"hue": "#8f9aa8", "accent6": "#e08a9b", "bg": "#364044", "grid": ["................", "..555......555..", ".53335....53335.", ".53315555551335.", "..533311113315..", ".53311111111145.", ".53122111122145.", ".51122111122145.", ".51111555511145.", ".51115111151145.", ".54111166111445.", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── snap ──
    "snap": {"hue": "#4f9e4a", "accent6": "#d9b98a", "accent7": "#c25050", "bg": "#24412a", "grid": ["................", "....55555555....", "...5333333115...", "..575777777575..", "..532211112245..", "..512211112245..", "..511155551145..", "..511511115145..", "...5411111145...", ".51566666666515.", ".51466677666415.", ".55466666666455.", "...5666666665...", "....541..145....", "....555..555....", "................"]},
    # ── bolt ──
    "bolt": {"hue": "#4f9e4a", "accent6": "#d9b98a", "accent7": "#4a7ec2", "bg": "#24412a", "grid": ["................", "....55555555....", "...5333333115...", "..577777777775..", "..532211112245..", "..512211112245..", "..511111111145..", "..511155551145..", "...5411111145...", ".51566666666515.", ".51466677666415.", ".55466666666455.", "...5666666665...", "....541..145....", "....555..555....", "................"]},
    # ── sage ──
    "sage": {"hue": "#4f9e4a", "accent6": "#d9b98a", "accent7": "#7a68b8", "bg": "#24412a", "grid": ["................", "....55555555....", "...5333333115...", "..577777777775..", "..535211115245..", "..512211112245..", "..511111111145..", "..511155551145..", "...5411111145...", ".51566666666515.", ".51466677666415.", ".55466666666455.", "...5666666665...", "....541..145....", "....555..555....", "................"]},
    # ── zip ──
    "zip": {"hue": "#4f9e4a", "accent6": "#d9b98a", "accent7": "#e8963c", "bg": "#24412a", "grid": ["................", "....55555555....", "...5333333115...", "..577777777775..", "..532211112245..", "..512211112245..", "..511511115145..", "..511155551145..", "...5411111145...", ".51566666666515.", ".51466677666415.", ".55466666666455.", "...5666666665...", "....541..145....", "....555..555....", "................"]},
    # ── scoots ──
    "scoots": {"hue": "#a8734a", "accent6": "#3a2f28", "accent7": "#e08a9b", "bg": "#3d352a", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54511111111545.", ".54522111122545.", ".54522111122545.", ".55515555511555.", "...5111771145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── lanky ──
    "lanky": {"hue": "#7ab648", "accent6": "#e8c49a", "accent7": "#e8b23c", "bg": "#304829", "grid": ["................", "....55555555....", "...5333333115...", "..536666666645..", "..512266662245..", "..512266662245..", "..516565656545..", "..515656565645..", "...5466666645...", ".57511111111575.", ".57411177111475.", ".57411177111475.", ".55511111111555.", "....541..145....", "....577..775....", "................"]},
    # ── strawman ──
    "strawman": {"hue": "#c89b6a", "accent6": "#e8c49a", "accent7": "#7a5236", "bg": "#464033", "grid": [".......55.......", "......5115......", "...5511111155...", "..536666666645..", "..512266662245..", "..512266662245..", "..516565656545..", "..515656565645..", "...5466666645...", ".51511111111515.", ".51411177111415.", ".55411177111455.", "...5111111115...", "..541111111145..", "..544444444445..", "................"]},
    # ── emberimp ──
    "emberimp": {"hue": "#e8763c", "accent6": "#e8b23c", "accent7": "#e8b23c", "bg": "#4f3626", "grid": ["......77........", ".....7777.......", "......55........", "....55555555....", "...5333333115...", "..533111111115..", "..532211112245..", "..512211112245..", "..511555555145..", "..511577775145..", "..541155551445..", "..541666661145..", "..541666661145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── sparkbug ──
    "sparkbug": {"hue": "#e8c832", "bg": "#4f4d23", "grid": ["................", "....5......5....", "...535....535...", "...5315555135...", "...5223111225...", "..532211112245..", ".54535555551545.", ".54515555551545.", ".55511555511555.", "...5111111145...", "...5111111145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── aquabub ──
    "aquabub": {"hue": "#4a90c2", "bg": "#223d4b", "grid": ["...55......55...", "..5335....5335..", "..533555555335..", ".53322111122145.", ".51122111122145.", ".51115111151145.", ".51111555511145.", ".51111111111145.", ".54111111111445.", ".54111111111445.", ".54111111111445.", "..541111111145..", "..541111111145..", ".5445......5445.", "................", "................"]},
    # ── leafhop ──
    "leafhop": {"hue": "#7ab648", "accent6": "#4f8a2f", "bg": "#304829", "grid": ["....55....55....", "...5665..5665...", "...5665..5665...", "...5665..5665...", "...5615555165...", "..533111111115..", "..531111111145..", "..512211112245..", "..512211112245..", "..511111111145..", "..541155551445..", "..541111111145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── frostpup ──
    "frostpup": {"hue": "#9ec4e8", "accent6": "#4a5a6e", "accent7": "#e08a9b", "bg": "#3a4c56", "grid": ["................", "....55555555....", "...5333333115...", ".54531111113545.", ".54511111111545.", ".54522111122545.", ".54522111122545.", ".55515555511555.", "...5111771145...", "...5111111145...", "...5411661145...", "...5411111145...", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── shadowmoth ──
    "shadowmoth": {"hue": "#5a4a7a", "accent6": "#e8963c", "accent7": "#8a78b0", "bg": "#272a37", "grid": ["..5..........5..", "..55........55..", "..535......535..", "..531555555135..", "..533311113315..", ".53311111111145.", ".53152111152145.", ".51122111122145.", ".51111111111145.", ".51111555511145.", ".54111166111445.", "..541717171145..", "..541111111145..", "..541111111145..", "...5445..5445...", "................"]},
    # ── cherry ──
    "cherry": {"hue": "#d878a8", "accent6": "#f0d0b0", "accent7": "#d97a3c", "bg": "#4a3644", "grid": ["................", "....55555555....", "...5777777775...", "..577666666775..", "..572266662275..", "..572266662275..", "..576566665675..", "..576655556675..", "...5466666645...", "...5511111155...", "..551111111155..", ".55111111111155.", ".54444444444445.", "....55....55....", "....55....55....", "................"]},
    # ── berry ──
    "berry": {"hue": "#4a7ec2", "accent6": "#f0d0b0", "accent7": "#e8c832", "bg": "#22384b", "grid": ["................", "....55555555....", "...5777777775...", "..572266662275..", "..572266662275..", "..576555555675..", "..576555555675..", "..576655556675..", "...5466666645...", "...5511111155...", "..551111111155..", ".55111111111155.", ".54444444444445.", "....55....55....", "....55....55....", "................"]},
    # ── clover ──
    "clover": {"hue": "#4f9e6b", "accent6": "#f0d0b0", "accent7": "#2e3338", "bg": "#244133", "grid": ["................", "....55555555....", "...5777777775...", "..577666666775..", "..572266662275..", "..572266662275..", "..576655556675..", "..576566665675..", "...5466666645...", "...5511111155...", "..551111111155..", ".55111111111155.", ".54444444444445.", "....55....55....", "....55....55....", "................"]},
    # ── pearl ──
    "pearl": {"hue": "#e8c49a", "accent6": "#d9a441", "accent7": "#4a7ec2", "bg": "#26211c", "grid": ["....555555......", "...577777775....", "..57777777765...", "..5311111111765.", "..5122111122565.", "..5122111122565.", "..5111111111565.", "..5111555511565.", "...54111111256..", "....54445..256..", "..5666666666645.", "..5666666666645.", "..5666666666645.", "..5444444444445.", "................", "................"]},
    "pearl-glance": {"hue": "#e8c49a", "accent6": "#d9a441", "accent7": "#4a7ec2", "bg": "#26211c", "grid": ["....555555......", "...577777775....", "..57777777765...", "..5311111111765.", "..5152111152565.", "..5122111122565.", "..5111111111565.", "..5111555511565.", "...54111111256..", "....54445..256..", "..5666666666645.", "..5666666666645.", "..5666666666645.", "..5444444444445.", "................", "................"]},
    # ── lisa ── PORTRAIT transcribed from RJ's hand-authored reference
    #   (.planning/ref/sprites/lisa-16x16.jpg): brown hair frame, tan face, DARK
    #   Mona-Lisa eyes, a pink hand/blush accent, a dark robe, on a green backdrop.
    #   Unlike the creature sprites (white value-2 eyes), lisa's eyes are the DARK
    #   brown accent7 (value 7) — the reference's dark eyes render on BOTH the terminal
    #   and the PNG. hue=tan face · accent6=pink hand/blush · accent7=dark brown
    #   (hair+eyes+robe) · bg=green. No value 5/2 → the dark brown IS the silhouette.
    "lisa": {"hue": "#d9b98a", "accent6": "#e88a6c", "accent7": "#3a2b20", "bg": "#6f7a4e", "grid": ["................", "................", ".....77777......", "....7117777.....", "...71111177.....", "...71717177.....", "...717171777....", "...711111777....", "...711111777....", "...771116777....", "...777667777....", "...776116777....", "...7.1116.777...", "..77.111.77777..", ".77777777777777.", ".71167777777777."]},
    # ── howl ──
    "howl": {"hue": "#d9c8a8", "accent6": "#37414f", "bg": "#d97a3c", "grid": ["................", "....55555555....", "...5333333115...", "..532211112215..", "..532211112245..", "..511111111145..", "..511115511145..", ".54111155111145.", ".54111111111145.", "...541111145....", "...5466666645...", "...5466666645...", "...5466666645...", "...5466666645...", "....55555555....", "................"]},
}

# base families = every sprite whose name carries NO emotion suffix ('-'), SORTED for a
# stable deterministic index: a HAID picks its family by sha256 % len(BASE_FAMILIES), so
# the order must not shuffle across runs (each dev keeps the same character forever).
BASE_FAMILIES = sorted(n for n in DETAILED_SPRITES if '-' not in n)


def detailed_family_for(haid):
    """The deterministic BASE family a HAID maps onto: sha256(haid) % num_base_families,
    indexed into the fixed BASE_FAMILIES order. Same seed → same family, forever, on
    every detailed surface. (Its own scheme — independent of the compact 8×8 cast.)"""
    h = hashlib.sha256(haid.encode()).digest()
    return BASE_FAMILIES[int.from_bytes(h[:8], 'big') % len(BASE_FAMILIES)]

def detailed_name_for(haid, emotion=None):
    """The sprite NAME to render.

    DIRECT ADDRESSING (fixes the 'fox renders green' bug): when `haid` is itself a
    known sprite name — a base family ('fox') or a full variant ('fox-rage') — that
    EXACT sprite is previewed, so its OWN authored hue/bg/accents are used (the gallery,
    `--seed fox --emotion rage`, per-variant eyeballing). Previously every name was run
    through the family HASH, so 'fox' hashed onto an unrelated family (e.g. green
    'lanky') and its non-existent emotion variants all fell back to that one green base.

    A real arbitrary HAID (not a sprite name) still maps through the deterministic
    family hash. An `emotion` selects the '<family>-<emotion>' variant when it exists,
    else a graceful fall back to the base family (never crashes / never blank)."""
    if haid in BASE_FAMILIES:
        fam = haid
    elif haid in DETAILED_SPRITES:                 # a full variant name, e.g. 'fox-rage'
        base = haid.split('-', 1)[0]
        fam = base if base in BASE_FAMILIES else haid
    else:
        fam = detailed_family_for(haid)
    if emotion:
        cand = "%s-%s" % (fam, emotion)
        if cand in DETAILED_SPRITES:
            return cand
        return fam if fam in DETAILED_SPRITES else haid
    if haid in DETAILED_SPRITES:                    # honor a full variant name passed directly
        return haid
    return fam

def _detailed_palette(sprite, eye_override=None):
    """value char → RGB for one sprite. 3/4 are DERIVED from the hue (the shading ramp);
    6/7 are the authored accents (fall back to the ramp if a grid used them without a
    declared accent — belt-and-suspenders; the TDD suite asserts they never do)."""
    hue = _hex_rgb(sprite['hue'])
    a6 = _hex_rgb(sprite['accent6']) if sprite.get('accent6') else _mix(hue, WHITE, HL_LIFT)
    a7 = _hex_rgb(sprite['accent7']) if sprite.get('accent7') else _mix(hue, BLACK, SH_DROP)
    return {'1': hue,
            '2': eye_override or WHITE,
            '3': _mix(hue, WHITE, HL_LIFT),
            '4': _mix(hue, BLACK, SH_DROP),
            '5': OUTLINE,
            '6': a6,
            '7': a7}

def _bg_px(bg, r, c, N):
    """'.' backdrop pixel: a subtle top-left-lit diagonal gradient of the bg hex — lit
    toward white at the top-left corner, shaded toward black at the bottom-right, so the
    portrait has a tasteful sense of light. Terminal-safe (the tier downgrade bands it)."""
    t = (r + c) / (2.0 * (N - 1)) if N > 1 else 0.0   # 0 top-left .. 1 bottom-right
    if t <= 0.5:
        return _mix(bg, WHITE, (0.5 - t) * BG_LIGHT)
    return _mix(bg, BLACK, (t - 0.5) * BG_DARK)


def _borders_bg(grid, r, c, N):
    """True if (r,c) touches a background ('.') pixel in its 8-neighbourhood (or the
    grid border) — i.e. it sits on the SILHOUETTE edge. Used to tell a true OUTLINE
    ink pixel (value 5 bordering the bg) from an INTERIOR value-5 feature mark that
    must NOT render near-black (else it reads as a scattered black speckle dot)."""
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            if dr == 0 and dc == 0:
                continue
            rr, cc = r + dr, c + dc
            if not (0 <= rr < N and 0 <= cc < N) or grid[rr][cc] == '.':
                return True
    return False

def _eye_block_pixels(grid, N):
    """Every (r,c) that is a value-2 eye pixel belonging to a 2×2 block of '2' (the
    watchman 'double eye-pair'). ONLY these are grown to fill their text cell, so a
    2×2 eye that straddles the fixed pixel-row pairing renders as a solid white square
    instead of a half-split checker (BUG 3). A stray lone '2' glint is left as authored."""
    eyes = set()
    for r in range(N - 1):
        for c in range(N - 1):
            if (grid[r][c] == '2' and grid[r][c + 1] == '2'
                    and grid[r + 1][c] == '2' and grid[r + 1][c + 1] == '2'):
                eyes |= {(r, c), (r, c + 1), (r + 1, c), (r + 1, c + 1)}
    return eyes


_DETAILED_MEMO = {}
def detailed_grid_for(haid, emotion=None, eye_override=None):
    """(name, grid, palette, bg_rgb, N=16) for a seed's detailed sprite. Memoized so the
    render stays a cheap dict lookup (<50ms) even under repeated statusless calls."""
    key = (haid, emotion, eye_override)
    hit = _DETAILED_MEMO.get(key)
    if hit is not None:
        return hit
    name = detailed_name_for(haid, emotion)
    sp = DETAILED_SPRITES[name]
    res = (name, sp['grid'], _detailed_palette(sp, eye_override), _hex_rgb(sp['bg']), 16)
    _DETAILED_MEMO[key] = res
    return res



def _apply_watchman(g):
    """Universal finish on ANY grid (curated or generated): carve a FULL-DARK visor
    BAND across grid rows 2+3 (edge to edge), then punch FULL-CELL white square eyes
    at cols 2 & 5. Each eye spans both band rows so it fills one whole text cell
    (render pairs rows (2,3) into text-row 1) -> a crisp white ▀+white-bg square, not
    a sliver. The band is dark edge-to-edge so the two eyes are the only lit thing on
    it (helm above + shoulders below frame it vertically) -> the eyes POP."""
    for c in range(W):
        g[2][c] = 0                 # carve the whole visor band dark, both rows,
        g[3][c] = 0                 # so nothing competes with the eyes
    for col in EYE_COLS:            # cols 2 and 5, mirrored
        g[2][col] = 2               # top half of the eye cell
        g[3][col] = 2               # bottom half of the eye cell
    return g

def animal_for(seed):
    """The deterministic animal a HAID maps onto: sha256(seed)[0] % 8, indexed into
    the fixed ANIMAL_ORDER. Same seed -> same animal, forever, on every surface."""
    idx = hashlib.sha256(seed.encode()).digest()[0] % len(ANIMAL_ORDER)
    return ANIMAL_ORDER[idx]

def custom_for(seed, eye_override=None):
    """(token_grid, palette) for a hero sigil (pinned / hero-name / auto-assigned HAID),
    or None when the seed takes the curated/animal path. The token grid is the raw
    authored 8×8 (chars from the alphabet '.','1'..'7'); the palette maps each token →
    RGB, built for ONLY the palette keys the hero carries (missing keys tolerated). NO
    watchman finish — a hero is a complete authored face and renders its OWN pixels
    exactly. eye_override is ignored: the face carries its own authored eye color (2),
    so it renders identically in every animation frame."""
    spec = _resolve_custom_spec(seed)
    if not spec:
        return None
    grid = [list(row) for row in spec["grid"]]
    pal = {tok: _hex_rgb(spec[key]) for tok, key in _TOKEN_KEY.items() if key in spec}
    return grid, pal

def _custom_size_grid(seed, size, eye_override=None):
    """The token grid + palette for a pinned custom sigil at the target size, or None.
    M is the native authored 8×8; L is a nearest 2× upsample (crisp doubling); S is an
    8→4 box-majority downsample on the TOKENS (mirrors _size_grid), so shrinking never
    fringes the silhouette. The palette is unchanged across sizes."""
    got = custom_for(seed, eye_override)
    if got is None:
        return None
    g, pal = got
    N = SIZES[size]
    if N == W:                                             # M — native 8×8, raw
        tg = g
    elif N == 2 * W:                                       # L — nearest 2× upsample
        tg = [[g[r // 2][c // 2] for c in range(N)] for r in range(N)]
    else:                                                  # S — 8→4 box-majority
        step = W // N
        tg = [[_majority([g[step * R + dr][step * C + dc]
                          for dr in range(step) for dc in range(step)])
               for C in range(N)] for R in range(N)]
    return tg, pal

def grid_for(seed, eye_override=None):
    """8x8 vertically-symmetric watchman. A HERO sigil resolves FIRST — an explicit pin
    (batsy → RJ's HAID), an explicit hero name, or a REAL HAID's auto-assigned hero — and
    renders RAW (no watchman finish). Otherwise: curated for the 4 mockup seeds; every
    other seed maps deterministically onto a ported superx ANIMAL sprite. The curated +
    animal paths get the universal watchman finish."""
    spec = _resolve_custom_spec(seed)
    if spec is not None:
        # Hero resolves first. grid_for returns the int projection used by glyph /
        # glyph_color / --debug (bg→0, hue→1, eye→2, highlight/shadow/accents/outline
        # collapse to body); the compact FACE render honors the FULL palette via
        # _custom_size_grid in sigil_render (this int grid never paints the hero face).
        # No _apply_watchman — the hero face keeps its own pixels/eyes. A hero without
        # an authored eye (e.g. joker) falls back to the shared EYE for this projection
        # only (never used to paint the face).
        tok2v = {'.': 0, '1': 1, '2': 2, '3': 1, '4': 1, '5': 1, '6': 1, '7': 1}
        g = [[tok2v[ch] for ch in row] for row in spec["grid"]]
        hue = _hex_rgb(spec["hue"])
        eye = eye_override or (_hex_rgb(spec["eye"]) if "eye" in spec else EYE)
        return g, hue, eye
    if seed in CURATED_GRIDS:
        g = [[int(ch) for ch in row] for row in CURATED_GRIDS[seed]]
        hue = CURATED_HUES[seed]
    else:
        name = animal_for(seed)
        g = [[int(ch) for ch in row] for row in ANIMALS[name]]
        hue = ANIMAL_HUES[name]
    _apply_watchman(g)
    eye = eye_override or EYE
    return g, hue, eye

def color(rgb, layer):  # layer: 'fg' or 'bg'
    if rgb is None:
        return '\033[39m' if layer == 'fg' else '\033[49m'
    code = 38 if layer == 'fg' else 48
    return f'\033[{code};2;{rgb[0]};{rgb[1]};{rgb[2]}m'

def cell_color(v, hue, eye):
    # 0 -> DIM filled block (silhouette), 1 -> body hue, 2 -> eye glint
    return {0: DIM, 1: hue, 2: eye}[v]

def _cell(top, bot):
    """One text cell from a top/bot pixel pair. OFF (None) stays transparent;
    everything else is a filled block so the face has a solid bounding box.
    The sigil block is PURE `▄` — the LOWER-half glyph (fg = BOTTOM px, bg = TOP px).
    Displayed pixels are IDENTICAL to the old `▀` upper-half form (upper half = top px,
    lower half = bot px); only the glyph and the fg/bg assignment swap. `▄` is used so
    any half-block-font overshoot spills DOWN into the next row instead of bleeding above
    the top edge (the top-edge doubling `▀` caused in RJ's terminal font). A LONE single
    pixel renders as a FULL block `█` — a solid cell with no half ambiguity. Every emitted
    cell has wcwidth 1 — the width-invariant the conformance goldens assert."""
    if top is None and bot is None:
        return ' '
    if bot is None:
        return color(top, 'fg') + '█' + '\033[0m'
    if top is None:
        return color(bot, 'fg') + '█' + '\033[0m'
    return color(bot, 'fg') + color(top, 'bg') + '▄' + '\033[0m'


# ── tier plumbing ──────────────────────────────────────────────────────────────
def tier_caps(color_tier=None, unicode_tier=None):
    """Build a hmd_termcaps.Caps for an EXPLICIT tier (goldens / calibration / the
    --tier CLI flag). Defaults to truecolor + full = the byte-for-byte native path
    (Caps.emit is a NO-OP there), so render()/render_large()/glyph() and every
    existing conformance golden stay byte-identical."""
    ct = color_tier or TC.TRUECOLOR
    ut = unicode_tier or TC.FULL
    return TC.Caps(ct, ut, False, "", ct)

# the native (no-downgrade) caps: shared, cheap, immutable — the default for the
# legacy truecolor surfaces (banner/share/statusline-full path).
_NATIVE = tier_caps()


def _majority(vals):
    """Box-filter majority pixel value over a downsample region. Deterministic:
    the most common value wins; ties break toward the HIGHER value (eye 2 > body 1 >
    off 0) so eyes/body survive shrink instead of being eroded by the dim border."""
    cnt = Counter(vals)
    return max(cnt.items(), key=lambda kv: (kv[1], kv[0]))[0]


def _size_grid(seed, size, eye_override=None):
    """The value grid (0/1/2) at the target size. M is the native 8×8; L is a
    nearest 2× upsample (crisp doubling, no new colors); S is an 8→4 box-filter
    majority downsample done on the COMPOSITED grid (OFF already = DIM filled), so
    shrinking never fringes the silhouette."""
    g, hue, eye = grid_for(seed, eye_override)
    N = SIZES[size]
    if N == W:                                             # M — native 8×8
        vg = g
    elif N == 2 * W:                                       # L — nearest 2× upsample
        vg = [[g[r // 2][c // 2] for c in range(N)] for r in range(N)]
    else:                                                  # S — 8→4 box-majority
        step = W // N
        vg = [[_majority([g[step * R + dr][step * C + dc]
                          for dr in range(step) for dc in range(step)])
               for C in range(N)] for R in range(N)]
    return vg, hue, eye


def _render_detailed(haid, caps, eye_override=None, pad='', xscale=1, emotion=None):
    """Emit the DETAILED 'D' tier: RJ's hand-authored 16×16 sprite, value→color +
    the bg diagonal gradient (the shading), on the SAME `▀` half-block + one-pass
    tier-downgrade machinery as the compact path. Every cell is filled (the bg is a
    color, never transparent) so the portrait is a clean 16-wide × 8-row block —
    the width invariant every emitted line = 16 cells holds. Detailed-tier ONLY: the
    compact 8×8 path never reaches here, so it stays byte-identical to branch `sigil`."""
    _name, grid, pal, bg, N = detailed_grid_for(haid, emotion, eye_override)
    eyes = _eye_block_pixels(grid, N)      # 2×2 eye pixels to grow to solid cells (BUG 3)
    eye_rgb = eye_override or WHITE
    interior_mark = pal['4']               # soft shadow tone for INTERIOR value-5 marks
    def px(r, c):
        ch = grid[r][c]
        if ch == '.':
            return _bg_px(bg, r, c, N)
        if ch == '5' and not _borders_bg(grid, r, c, N):
            # ANTI-SPECKLE: an interior 5 is a muzzle/mouth/nose mark, not the ink line
            # — render it as the soft shadow tone so it never reads as a near-black dot.
            return interior_mark
        return pal[ch]
    lines = []
    for tr in range(0, N, 2):   # two pixel-rows per text-row (N=16 is even)
        line = pad
        for c in range(N):
            if (tr, c) in eyes or (tr + 1, c) in eyes:
                cell = _cell(eye_rgb, eye_rgb)   # grow the 2×2 eye to a solid white cell
            else:
                top = px(tr, c)
                bot = px(tr + 1, c) if tr + 1 < N else OFF
                cell = _cell(top, bot)
            line += cell * xscale
        lines.append(line)
    return caps.emit("\n".join(lines)).split("\n")


def sigil_render(haid, size='M', caps=None, eye_override=None, pad='', xscale=1, emotion=None):
    """THE shared watchman renderer — every surface goes through here.

    Builds the value grid at `size`, emits PURE `▀` half-block cells in 24-bit
    truecolor, then downgrades the whole block to `caps` in ONE pass (Caps.emit):
    truecolor = byte-identical NO-OP; 256 = nearest xterm-cube LUT; 16 = fixed
    4-shade; mono/ascii = ANSI stripped + glyphs translated. Because the tier is
    applied HERE, no caller (CLI, banner, TUI) can emit truecolor blind — the
    root cause of the morphed render. Returns a list of lines.

    size 'D' is the DETAILED tier (RJ's 16×16 hand-authored sprites + shading, with
    an optional `emotion` variant); S/M/L are the flat compact/animal grids and are
    byte-untouched by the detailed path. xscale doubles each cell horizontally (the
    legacy `large` share form)."""
    caps = caps or _NATIVE
    if size == 'D':
        return _render_detailed(haid, caps, eye_override, pad, xscale, emotion)
    # PINNED custom sigil (S/M/L): render the authored token grid RAW through the FULL
    # palette (.=bg 1=hue 2=eye 5=outline 6=accent6 7=accent7) — bypassing the animal
    # watchman band/eyes — then downgrade the whole block to `caps` in the same one pass
    # (truecolor NO-OP · 256 LUT · 16 · mono) as every other tier. Never reached for a
    # non-pinned seed, so all other seeds stay byte-identical.
    custom = _custom_size_grid(haid, size, eye_override) if size in ('S', 'M', 'L') else None
    if custom is not None:
        tg, pal = custom
        N = len(tg)
        lines = []
        for tr in range(0, N, 2):
            line = pad
            for c in range(N):
                top = pal[tg[tr][c]]
                bot = pal[tg[tr + 1][c]] if tr + 1 < N else OFF
                line += _cell(top, bot) * xscale
            lines.append(line)
        return caps.emit("\n".join(lines)).split("\n")
    vg, hue, eye = _size_grid(haid, size, eye_override)
    N = len(vg)
    lines = []
    for tr in range(0, N, 2):   # two pixel-rows per text-row (N is always even)
        line = pad
        for c in range(N):
            top = cell_color(vg[tr][c], hue, eye)
            bot = cell_color(vg[tr + 1][c], hue, eye) if tr + 1 < N else OFF
            line += _cell(top, bot) * xscale
        lines.append(line)
    return caps.emit("\n".join(lines)).split("\n")


def render(seed, eye_override=None, pad='  '):
    """Compact statusline/banner watchman (size M, native truecolor). Delegates to
    the shared core so the cell-emit + tier logic lives in exactly one place."""
    return sigil_render(seed, 'M', _NATIVE, eye_override, pad)

def render_large(seed, eye_override=None, pad='  '):
    """2x horizontal scale for share/banner — each pixel becomes ██-ish width."""
    return sigil_render(seed, 'M', _NATIVE, eye_override, pad, xscale=2)

def render_detailed(seed, caps=None, eye_override=None, pad='  ', emotion=None):
    """The DETAILED 16×16 tier for the space-having surfaces (share card /
    `hmd-banner --share`, banner, `hmd watch`): RJ's hand-authored sprite + shading,
    routed through the shared shaded/tier core. `emotion` selects a variant (default
    = the base family). More pixels → real character detail (ears, muzzle, accents)."""
    return sigil_render(seed, 'D', caps or _NATIVE, eye_override, pad, emotion=emotion)

def glyph(seed, eye_override=None):
    """single colored cell for the team wall: ◉ in the identity hue."""
    _, hue, _ = grid_for(seed)
    col = eye_override or hue
    return color(col, 'fg') + '◉' + '\033[0m'

def glyph_color(seed):
    """The DOMINANT sigil color (body hue) for a seed — the deterministic identity
    tint the statusline wall paints a teammate's glyph with (spec B §4: teammate
    glyphs tinted by glyph_color(), state shown by solid/dim/red-frame, NOT by
    recoloring). Same seed -> same hue, forever, on every surface."""
    _, hue, _ = grid_for(seed)
    return hue


def sigil_accent_color(seed):
    """The VIVID identity color of a seed's sigil — the palette swatch with the highest
    HSV saturation×value that is NEITHER near-black NOR near-white. This is the colour a
    human NAMES the hero by (batsy→blue #2f96ff, hulk→green, spiderman→red, joker→green),
    as opposed to glyph_color()'s DOMINANT body hue (often a near-black cowl/body that
    reads as "black"). The statusline gauge ramp samples THIS so the bar reads in the
    sigil's recognizable identity hue, not its dark body.

    For a HERO: scan its authored palette keys (hue/eye/accent6/accent7) and pick
    argmax(saturation×value) among the swatches that are neither near-black (v<0.22 — the
    dark body/outline) nor near-white (v>0.90 & s<0.20 — the eye glint). A non-hero seed
    (curated / animal) carries no such palette → its identity hue glyph_color(seed).
    Deterministic: same seed → same accent, forever."""
    import colorsys
    spec = _resolve_custom_spec(seed)
    if spec is None:
        return glyph_color(seed)
    best = None
    best_score = -1.0
    for key in ("hue", "eye", "accent6", "accent7"):
        hexv = spec.get(key)
        if not isinstance(hexv, str):
            continue
        try:
            r, g, b = _hex_rgb(hexv)
        except Exception:
            continue
        _h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
        if v < 0.22:                        # near-black — the dark cowl/body/outline
            continue
        if v > 0.90 and s < 0.20:           # near-white — the eye glint
            continue
        score = s * v
        if score > best_score:
            best_score = score
            best = (r, g, b)
    return best if best is not None else glyph_color(seed)


# ── TEAM-MINI — a high-quality 4×4 (2 text-row) teammate silhouette ──────────────
# The statusline team cluster gives each teammate a 4×4px mark (4 cols × 2 text rows): the
# TOP text-row rides Row1, the BOTTOM rides Row2, the NAME sits under it on Row3. The
# generic S-size 8→4 BOX-MAJORITY downsample (tie → higher token) makes almost EVERY box
# "on", so a hero collapses to a solid recoloured BLOCK — RJ: "a beige blob, not a
# recognizable hero". team_mini is a FEATURE-PRESERVING reduction instead: each 8×8 pixel
# is classed OFF (bg) / ON (body) / EYE, and each 2×2 box collapses by a rule that KEEPS the
# silhouette gaps + eyes rather than averaging them into mud —
#   • any eye pixel in the box → EYE  (eyes are 1–2px and define the face; they survive)
#   • else ON iff on-pixels STRICTLY outnumber off  (a tie → OFF, so the bg silhouette —
#     batsy's cowl ears, spiderman's lenses, ironman's faceplate slits — is CARVED, not
#     flooded to a solid block)
# The mark is recoloured to the teammate hue: ON → the hue, EYE → a bright tint of the hue
# (so eye POSITIONS pop against the body), OFF → the DIM silhouette block. So batsy reduces
# to a cowl+ears silhouette with an eye band, hulk to a solid brow + eye band, ironman to
# faceplate slits — recognizable, in the teammate's identity hue.
#
# DEDICATED PATH: sigil_render() is byte-UNTOUCHED (the S goldens and
# heimdall-sigil-render stay byte-stable); team_mini is a parallel projection over the SAME
# resolved 8×8 grid (custom_for for heroes, grid_for for curated/animal), packed via _cell.
TEAM_MINI_W, TEAM_MINI_H = 4, 4   # 4×4 px → 4 cols × 2 `▄` text-rows

def _team_mini_class_grid(seed):
    """The seed's 8×8 grid as an OFF/ON/EYE class per pixel. A hero classes its authored
    TOKEN grid ('.' → off, '2' → eye, else on); every other seed classes the composited
    VALUE grid (0 → off, 2 → eye, else on) — mirroring how micro resolves
    the grid, so team_mini never diverges from the seed's canonical silhouette."""
    got = custom_for(seed)
    if got is not None:
        grid, _pal = got
        return [[('eye' if grid[r][c] == '2' else 'off' if grid[r][c] == '.' else 'on')
                 for c in range(W)] for r in range(W)]
    g, _hue, _eye = grid_for(seed)
    return [[('eye' if g[r][c] == 2 else 'off' if g[r][c] == 0 else 'on')
             for c in range(W)] for r in range(W)]

def _team_mini_reduce(box):
    """Collapse a 2×2 class box to one OFF/ON/EYE pixel, feature-preserving: an eye survives
    (any eye → EYE); else ON only when on-pixels STRICTLY outnumber off (a tie → OFF), so the
    bg silhouette is carved rather than flooded to a solid block (the box-majority mud)."""
    if box.count('eye'):
        return 'eye'
    return 'on' if box.count('on') > box.count('off') else 'off'

def team_mini(seed, color=None, caps=None):
    """A high-quality 4×4 (2 text-row) teammate mark: a FEATURE-PRESERVING reduction of the
    seed's 8×8 hero/animal grid (see the section header), recoloured to `color` — the
    teammate hue. ON → the hue, EYE → a bright tint of the hue (eye-pop), OFF → the DIM
    silhouette block. `color` is a '#rrggbb' hex or an (r,g,b) tuple; None keeps the seed's
    own dominant hue (glyph_color). Returns a list of 2 text-row strings (4 cells each),
    tier-downgraded through `caps` in one pass (truecolor NO-OP · 256 LUT · 16 · mono). Any
    seed the sigil core resolves works (hero name / real HAID / pin / toy seed); never raises
    for a resolvable seed."""
    caps = caps or TC.detect()
    if color is None:
        hue = glyph_color(seed)
    elif isinstance(color, str):
        hue = _hex_rgb(color)
    else:
        hue = tuple(color)
    eye_col = _mix(hue, WHITE, 0.6)   # a bright tint of the identity hue so eye positions pop
    px = {'off': DIM, 'on': hue, 'eye': eye_col}
    cl = _team_mini_class_grid(seed)
    sx = sy = W // TEAM_MINI_W        # 2×2 source box per output pixel
    red = [[_team_mini_reduce([cl[sy * R + dr][sx * C + dc]
                               for dr in range(sy) for dc in range(sx)])
            for C in range(TEAM_MINI_W)] for R in range(TEAM_MINI_W)]
    lines = []
    for tr in range(0, TEAM_MINI_W, 2):
        line = ""
        for c in range(TEAM_MINI_W):
            top = px[red[tr][c]]
            bot = px[red[tr + 1][c]] if tr + 1 < TEAM_MINI_W else OFF
            line += _cell(top, bot)
        lines.append(line)
    return caps.emit("\n".join(lines)).split("\n")


# ── MICRO / CHIP render — a SINGLE text-row team-cluster mark ────────────────────
# The statusline Row-1 team cluster (`team <mark> <mark> name·name`) gives each
# teammate ONE text-row of height. This derives a tiny recognizable mark from the
# SAME 8×8 hero/animal grid every other size renders through — nothing new is
# hand-authored. The 8×8 is box-majority downsampled (the exact filter S uses, only
# to a 4×2 target) then packed into ONE `▄` text-row: 4 cells wide, each cell = a
# top/bot pixel pair (top px → bg, bot px → fg — the `_cell` ▄ convention), so one
# text-row encodes the 2 downsampled pixel-rows as a compressed silhouette.
MICRO_W, MICRO_H = 4, 2   # 4 px wide × 2 px tall → one `▄` text-row of 4 cells

def _micro_cells(seed):
    """Box-majority downsample the seed's 8×8 grid to MICRO_H×MICRO_W, returning
    (rows, is_on, base): `rows` is MICRO_H lists of MICRO_W items; `is_on(item)` is
    True for a silhouette (non-bg) pixel; `base(item)` is the item's OWN hero color.
    A hero (pin / hero-name / real-HAID auto-assign) downsamples its authored TOKEN
    grid over its full palette (mirrors _custom_size_grid's S path); every other seed
    downsamples the composited VALUE grid over its hue/eye (mirrors _size_grid's S
    path). Each MICRO cell box is (W//MICRO_W)=2 wide × (H//MICRO_H)=4 tall = 8 source
    px, majority-filtered (_majority — ties break toward the higher token/value so the
    silhouette survives the shrink, exactly as S does)."""
    sx, sy = W // MICRO_W, H // MICRO_H
    def down(grid):
        return [[_majority([grid[sy * R + dr][sx * C + dc]
                            for dr in range(sy) for dc in range(sx)])
                 for C in range(MICRO_W)] for R in range(MICRO_H)]
    got = custom_for(seed)
    if got is not None:                        # hero: authored token grid + full palette
        grid, pal = got
        rows = down(grid)
        return rows, (lambda tok: tok != '.'), (lambda tok: pal.get(tok, pal['.']))
    g, hue, eye = grid_for(seed)               # curated/animal: value grid (0 off,1 body,2 eye)
    rows = down(g)
    return rows, (lambda v: v != 0), (lambda v: cell_color(v, hue, eye))

def micro(seed_or_hero, color=None, caps=None):
    """A ONE-text-row compressed sigil mark (4 cells) for the statusline team cluster.

    Derived — never hand-authored: the seed's 8×8 hero/animal grid is box-majority
    downsampled to 4×2 px and packed into a single `▄` text-row via the shared `_cell`.
    `seed_or_hero` is any seed the sigil core resolves — an explicit hero NAME, a real
    HAID (→ its auto-assigned hero), a pinned HAID, or a toy seed (→ its animal); an
    unknown seed never crashes, it resolves deterministically like every other surface.

    RECOLOR CHOICE — at 4×2 px (8 pixels) a full multi-tone palette reads as mud, so a
    supplied `color` (a '#rrggbb' hex, e.g. a teammate's status.json team[].sigil) paints
    the compressed SILHOUETTE in that ONE hue: every on-pixel → the member's color, every
    off-pixel → the DIM silhouette block. The shape (which pixels are on) is preserved, so
    the mark still reads as the hero, now unmistakably in the member's color. With no
    `color`, the mark keeps the hero's OWN palette colors (its native look, shrunk).

    Terminal-safe: emitted truecolor is downgraded through `caps` in one pass (truecolor
    NO-OP · 256 LUT · 16 · mono strips color → a plain `▄`/`.` glyph, no SGR). `caps`
    defaults to the detected terminal. Returns ONE string (no trailing newline)."""
    caps = caps or TC.detect()
    rows, is_on, base = _micro_cells(seed_or_hero)
    over = _hex_rgb(color) if color else None
    line = ""
    for C in range(MICRO_W):
        top_item, bot_item = rows[0][C], rows[1][C]
        if over is not None:
            top = over if is_on(top_item) else DIM
            bot = over if is_on(bot_item) else DIM
        else:
            top, bot = base(top_item), base(bot_item)
        line += _cell(top, bot)
    return caps.emit(line)


# ── EYE-STRIP — the EYE band of the FULL 8×8 hero (pixel rows 3–6), NATURAL colors ─
# The statusline team rail shows each teammate as the recognizable EYE STRIP of their
# actual hero face — the brow + EYES + upper cheek — NOT a single-hue recoloured block
# (micro's mud at 4×2px) and NOT the top-of-head crop the old top_half() showed (pixel
# rows 0–3 = hair/ears/cowl only → the eyes were BELOW the crop, invisible: the bug).
#
# The default crop is pixel ROWS 3–6 (4 px = 2 `▄` text-rows), 8 cells wide, in the hero's
# OWN authored palette. But hero grids are hand-authored and the eye row varies per hero,
# so the crop AUTO-CENTERS on the eyes (Spec v2 §4): find the grid row carrying the most
# eye pixels (token '2' for a hero; value 2 for a curated/animal seed) and, when that eye
# row falls OUTSIDE the default [3,6] window, shift the 4-px window so the eye row sits in
# it (top = eye_row − 1, clamped to the grid 0–7 so it never runs off the edge). That
# guarantees the eyes are inside the returned strip for EVERY hero. A face with no eye
# pixel at all (e.g. joker) keeps the default rows 3–6 (there is nothing to center on).
#
# DEDICATED PATH: sigil_render()/the goldens are byte-UNTOUCHED — eye_strip is a parallel
# crop over the SAME resolved 8×8 grid (custom_for for heroes, grid_for for curated/animal),
# packed via the shared `_cell` (`▄`: fg = BOTTOM px, bg = TOP px). 8 cols × 2 text-rows.
def _eye_pixels(seed_or_hero):
    """(pxfn, eye_count) for a seed — the ONE resolution both strip widths share.

    `pxfn(r, c)` is the RGB of grid pixel (r, c); `eye_count[r]` is how many EYE pixels sit
    in grid row r (what _eye_strip_top centers the crop window on). A hero resolves through
    its authored TOKEN grid + palette; every other seed through the composited VALUE grid —
    exactly as before, so eye_strip's bytes are unchanged. Raises for a seed the sigil core
    cannot resolve; both callers catch that and degrade to blank rows."""
    got = custom_for(seed_or_hero)
    if got is not None:                                  # hero: authored token grid + palette
        grid, pal = got
        return ((lambda r, c: pal.get(grid[r][c], pal['.'])),
                [sum(1 for c in range(W) if grid[r][c] == '2') for r in range(W)])
    grid, hue, eye = grid_for(seed_or_hero)              # curated / animal: value grid
    return ((lambda r, c: cell_color(grid[r][c], hue, eye)),
            [sum(1 for c in range(W) if grid[r][c] == 2) for r in range(W)])


def _eye_strip_top(eye_count, default=3, win=4):
    """The top grid-row of the 4-px eye-strip crop window, auto-centered on the eyes.
    `eye_count[r]` = number of eye pixels in grid row r. Default window is rows
    [default, default+win-1] (= 3–6). If the row with the most eyes is INSIDE that window
    (or there are no eyes at all) the default is kept; otherwise the window shifts so the
    eye row is one below its top (top = eye_row − 1), clamped to [0, W − win] so the crop
    stays wholly on the grid."""
    if max(eye_count) <= 0:
        return default
    # eye row = most eye pixels; ties break toward the row nearest the grid center (3.5)
    eye_row = max(range(len(eye_count)), key=lambda r: (eye_count[r], -abs(r - 3.5)))
    if default <= eye_row <= default + win - 1:
        return default
    return max(0, min(eye_row - 1, W - win))

def eye_strip(seed_or_hero, caps=None):
    """The EYE STRIP of the seed's full 8×8 hero sigil — 2 `▄` text-rows (4 pixel-rows),
    8 cells wide, in the hero's OWN natural palette, cropped so the EYES are visible.

    Replaces top_half() (which cropped pixel rows 0–3 = the top of the head, leaving the
    eyes below the crop). The crop is pixel rows 3–6 by default, auto-centered on the eye
    row when a hero's eyes fall outside that window (see the section header + _eye_strip_top).

    `seed_or_hero` is any seed the sigil core resolves (hero NAME, real HAID → its
    auto-assigned hero, pinned HAID, or a toy seed → its animal). Returns a list of EXACTLY
    2 text-row strings, tier-downgraded through `caps` in one pass (truecolor NO-OP · 256
    LUT · 16 · mono); degrades to two blank 8-cell rows on any fault (never raises — the
    statusline must never error)."""
    caps = caps or TC.detect()
    blank = caps.emit(" " * W)
    try:
        pxfn, eye_count = _eye_pixels(seed_or_hero)
    except Exception:
        return [blank, blank]
    top = _eye_strip_top(eye_count)                      # 4-px window top row, eye-centered
    lines = []
    for tr in (top, top + 2):                            # two text-rows: (top,top+1),(top+2,top+3)
        line = ""
        for c in range(W):
            line += _cell(pxfn(tr, c), pxfn(tr + 1, c))  # ▄: bg = TOP px, fg = BOTTOM px
        lines.append(line)
    return caps.emit("\n".join(lines)).split("\n")


# ── EYE-STRIP MINI — the SAME eye band at HALF the width (4 cells) ───────────────
# The wall pays TEAM_MEMBER_W per teammate, and nine 15-cell columns (151 cells) starved the
# left content panel until its Row4 rate-limit BARS self-downgraded to plain text and the
# Row3 gate row dropped its details. Halving the strip is where the headroom comes from.
#
# WHY A BOX-AVERAGE AND NOT A CROP — this was MEASURED over all 58 heroes, not assumed
# (test/heimdall-sigil-eyestrip-mini.test.sh re-derives every number and locks it):
#   • 2×1 horizontal box-average : median 6 distinct shades, 1 hero under 3, 0 collisions
#   • face bounding-box crop     : median 3 shades, 8 heroes under 3, and it drains some
#                                  heroes to ONE shade — the exact 2-shade-blob regression
#                                  3f5e959 was written to fix
#   • eye-preserving average     : median 5 shades, 2 heroes under 3, 0 collisions
# The average WINS because it keeps all eight source columns' information: two adjacent
# pixels of different hues produce a THIRD, intermediate tone, so compressing the strip
# adds shades rather than spending them. The 4-cell strip collides on 0 of the 1653 hero
# pairs — exactly as identity-bearing as the 8-cell one.
EYE_STRIP_MINI_W = W // 2      # 4 cells: one output cell per adjacent source-column pair


def _px_avg(a, b):
    """The box-average of two adjacent pixels, per channel, rounded half-up."""
    return ((a[0] + b[0] + 1) // 2, (a[1] + b[1] + 1) // 2, (a[2] + b[2] + 1) // 2)


def eye_strip_mini(seed_or_hero, caps=None):
    """The seed's eye strip at HALF width — 2 `▄` text-rows, EXACTLY 4 cells each.

    Same contract as eye_strip (same seeds, same 4 pixel-rows of vertical detail, same
    auto-centered eye window, same one-pass `caps` tier downgrade, never raises), with the
    eight source columns box-averaged down to four (see the section header for why that
    compression and not a crop). Degrades to two blank 4-cell rows on ANY fault — the
    statusline must never error."""
    caps = caps or TC.detect()
    blank = caps.emit(" " * EYE_STRIP_MINI_W)
    try:
        pxfn, eye_count = _eye_pixels(seed_or_hero)
        top = _eye_strip_top(eye_count)                  # 4-px window top row, eye-centered
        lines = []
        for tr in (top, top + 2):                        # (top,top+1),(top+2,top+3)
            line = ""
            for c in range(EYE_STRIP_MINI_W):
                lo, hi = 2 * c, 2 * c + 1                # the adjacent source-column pair
                line += _cell(_px_avg(pxfn(tr, lo), pxfn(tr, hi)),
                              _px_avg(pxfn(tr + 1, lo), pxfn(tr + 1, hi)))
            lines.append(line)
    except Exception:
        return [blank, blank]
    return caps.emit("\n".join(lines)).split("\n")

# BACK-COMPAT ALIAS — top_half is the old teammate-render entry point still called by
# sentinels/hmd-statusline.py (:743) + test/heimdall-statusline-fullbleed.test.sh. It now
# resolves to eye_strip so the statusline immediately shows EYES (same signature, same
# 2-row × 8-cell shape). The caller migration to eye_strip is the integration agent's job.
top_half = eye_strip


def _sq(rgb, n, caps):
    """An n×n aspect-square block: n cols × n/2 half-block rows, each cell the same
    solid color (fg=bg). If the terminal's cell aspect is the assumed ~1:2, this
    renders as a VISUAL SQUARE — the 2-second eyeball check that the sigil isn't
    squished. n must be even."""
    line = "".join(_cell(rgb, rgb) for _ in range(n))
    return caps.emit("\n".join([line] * (n // 2))).split("\n")


def _checker(a, b, n, caps):
    """An n-wide × n/2-tall checkerboard alternating colors a/b per cell AND per
    half (top/bot swapped each cell) — a dense color-fidelity target: on a broken
    color tier the pattern smears or drops the bg. n even."""
    rows = []
    for r in range(n // 2):
        cells = []
        for c in range(n):
            top, bot = (a, b) if (r + c) % 2 == 0 else (b, a)
            cells.append(_cell(top, bot))
        rows.append("".join(cells))
    return caps.emit("\n".join(rows)).split("\n")


def calibration_card(haid, caps=None):
    """`hmd sigil --test` — a self-verification card the user reads in 2 seconds to
    confirm their terminal renders the watchman correctly (and to screenshot if not).
    Rendered through the DETECTED caps so it shows exactly what the statusline/banner
    will look like on THIS terminal. Contains: the resolved tier, the sigil at all 3
    sizes (S/M/L), an aspect-square (must look square, not tall/squished), and a
    2-color checkerboard (color fidelity). Returns a list of lines."""
    caps = caps or TC.detect()
    B = caps.emit("\033[1m"); X = caps.emit("\033[0m")
    D = caps.emit("\033[38;2;90;100;114m")
    out = []
    out.append(f"{B}Heimdall sigil calibration{X}  {D}seed={haid}{X}")
    out.append(f"{D}tier: color={caps.color} unicode={caps.unicode} "
               f"tmux={1 if caps.tmux else 0}{X}")
    out.append("")
    for size, label in (("S", "S 4x4"), ("M", "M 8x8"), ("L", "L 16x16")):
        out.append(f"{D}{label}{X}")
        out.extend("  " + ln for ln in sigil_render(haid, size, caps))
        out.append("")
    out.append(f"{D}aspect-square (must look SQUARE, not tall):{X}")
    out.extend("  " + ln for ln in _sq((45, 212, 191), 8, caps))
    out.append("")
    out.append(f"{D}checkerboard (color fidelity — no smear/dropout):{X}")
    out.extend("  " + ln for ln in _checker((45, 212, 191), (19, 21, 29), 8, caps))
    out.append("")
    out.append(f"{D}looks morphed? screenshot this + run: "
               f"HEIMDALL_STATUSLINE_MODE=256 hmd sigil --test{X}")
    return out


def _cli_main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', default=None)
    ap.add_argument('--test', action='store_true',
                    help="print the terminal calibration card (detected caps)")
    ap.add_argument('--size', default='compact',
                    help="compact|large|detailed (legacy) or S|M|L|D (tiered core)")
    ap.add_argument('--tier', default=None,
                    choices=['truecolor', '256', '16', 'mono', 'ascii'],
                    help="force a capability tier (default: truecolor)")
    ap.add_argument('--emotion', default=None,
                    help="detailed tier only: an emotion variant (e.g. rage, joy); "
                         "falls back to the base family when the variant is absent")
    ap.add_argument('--glyph', action='store_true')
    ap.add_argument('--micro', action='store_true',
                    help="print the 1-text-row compressed team-cluster mark (4 cells)")
    ap.add_argument('--color', default=None, metavar='#RRGGBB',
                    help="--micro only: recolor the mark to this hex (a teammate's sigil hue)")
    ap.add_argument('--debug', action='store_true')  # print ·/#/@ grid
    ap.add_argument('--hero-for', dest='hero_for', default=None, metavar='HAID',
                    help="print the hero a HAID auto-assigns to (deterministic pool pick)")
    ap.add_argument('--list-heroes', action='store_true',
                    help="print the hero auto-assign pool (one name per line, sorted)")
    ap.add_argument('--resolve', default=None, metavar='SEED',
                    help="print the hero NAME a seed resolves to (pin/name/auto), else empty")
    a = ap.parse_args(argv)
    if a.list_heroes:
        print('\n'.join(HERO_ORDER))
        return 0
    if a.hero_for:
        print(hero_for(a.hero_for))
        return 0
    if a.resolve:
        # The hero NAME a seed actually renders as (explicit pin > hero name > real HAID
        # auto-assign), or empty for a curated/animal seed. What `hmd sigil` reports.
        spec = _resolve_custom_spec(a.resolve)
        print(spec["name"] if spec else "")
        return 0
    if a.test:
        # calibration uses the DETECTED tier unless one is forced with --tier.
        cc = None
        if a.tier == 'ascii':   cc = tier_caps(TC.MONO, TC.ASCII)
        elif a.tier == 'mono':  cc = tier_caps(TC.MONO, TC.FULL)
        elif a.tier in ('256', '16', 'truecolor'): cc = tier_caps(a.tier, TC.FULL)
        print('\n'.join(calibration_card(a.seed or 'you', cc)))
        return 0
    if not a.seed:
        ap.error("--seed is required (or use --test for the calibration card)")
    if a.glyph:
        print(glyph(a.seed)); return 0
    if a.micro:
        # 1-text-row team-cluster mark. Honor an explicit --tier (goldens/scripts),
        # else auto-detect the terminal (morph-safe — never truecolor blind).
        if a.tier == 'ascii':   mc = tier_caps(TC.MONO, TC.ASCII)
        elif a.tier == 'mono':  mc = tier_caps(TC.MONO, TC.FULL)
        elif a.tier in ('256', '16', 'truecolor'): mc = tier_caps(a.tier, TC.FULL)
        else:                   mc = TC.detect()
        print(micro(a.seed, color=a.color, caps=mc)); return 0
    if a.debug:
        g, _, _ = grid_for(a.seed)
        for row in g:
            print(''.join({0: '·', 1: '#', 2: '@'}[v] for v in row))
        return 0
    # tier resolution. An explicit --tier is honored verbatim (goldens/scripts).
    # With NO --tier: the NEW S/M/L tokens auto-DETECT the terminal (morph-safe by
    # default — never truecolor blind on a 256/tmux/16-color terminal), while the
    # LEGACY compact/large tokens stay native truecolor (the banner/share + the
    # viral-sigil conformance contract expect the 24-bit path).
    if a.tier == 'ascii':
        caps = tier_caps(TC.MONO, TC.ASCII)
    elif a.tier == 'mono':
        caps = tier_caps(TC.MONO, TC.FULL)
    elif a.tier in ('256', '16', 'truecolor'):
        caps = tier_caps(TC.TRUECOLOR if a.tier == 'truecolor' else a.tier, TC.FULL)
    elif a.size in ('S', 'M', 'L', 'D'):
        caps = TC.detect()                     # new tokens: detect the real terminal
    else:
        caps = _NATIVE                         # legacy compact/large/detailed: truecolor
    if a.size in ('S', 'M', 'L', 'D'):
        lines = sigil_render(a.seed, a.size, caps, emotion=a.emotion)  # tiered tokens: no pad
    elif a.size == 'large':
        lines = sigil_render(a.seed, 'M', caps, pad='  ', xscale=2)  # legacy 2-sp pad
    elif a.size == 'detailed':
        lines = sigil_render(a.seed, 'D', caps, pad='  ', emotion=a.emotion)  # detailed 16×16
    else:  # compact
        lines = sigil_render(a.seed, 'M', caps, pad='  ')            # legacy 2-sp pad
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(_cli_main())
