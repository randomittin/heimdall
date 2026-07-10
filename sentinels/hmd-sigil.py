#!/usr/bin/env python3
"""
hmd-sigil.py — the hyphenated CLI entry point for the watchman sigil.

This is a THIN LOADER, not a second implementation. The canonical renderer lives
in the sibling module `hmd_sigil.py` (importable, no hyphen). Previously the two
files were byte-identical TWINS — a fix to one silently left the other (and the
surface that imported it) broken, which is exactly how the sigil morphed on one
surface while looking fine on another. Collapsing to a single implementation means
every surface — statusline, banner, `hmd sigil`, TUI — renders through one code
path, so a fix lands everywhere at once.

  python3 hmd-sigil.py --seed rj --size M --tier 256
  python3 hmd-sigil.py --seed rj --debug
  python3 hmd-sigil.py --seed rj --glyph
"""
import os, sys, importlib.util

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "hmd_sigil", os.path.join(_HERE, "hmd_sigil.py"))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

# re-export the public API so `import`-by-loader callers see the same symbols.
sigil_render = _mod.sigil_render
render = _mod.render
render_large = _mod.render_large
render_detailed = _mod.render_detailed
glyph = _mod.glyph
grid_for = _mod.grid_for
detailed_grid_for = _mod.detailed_grid_for
detailed_family_for = _mod.detailed_family_for
detailed_name_for = _mod.detailed_name_for
DETAILED_SPRITES = _mod.DETAILED_SPRITES
BASE_FAMILIES = _mod.BASE_FAMILIES
cell_color = _mod.cell_color
color = _mod.color
tier_caps = _mod.tier_caps
SIZES = _mod.SIZES

if __name__ == '__main__':
    sys.exit(_mod._cli_main())
