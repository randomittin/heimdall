#!/usr/bin/env python3
# rn.py — the React Native target for the designmatch v2 language seam.
#
# This is the ONE concrete target at launch (the seam exists so Flutter/Kotlin/
# Swift slot in later without editing the pipeline — see __init__.py). It converts
# a React/JS canonical's source into a FRESH React Native component: a new file
# derived from the canonical's VISUAL structure, applying the web-JSX -> RN idiom
# map. It is intentionally BEHAVIOR-FREE: handlers, state, API calls, navigation,
# effects and prop wiring are NOT carried here — the migration step re-attaches
# them and the behavioral diff proves it. `generate` produces only the visually-
# faithful skeleton the migration starts from.
#
# WHY translate at all (vs. emit a blank shell): the regenerate ethos is that the
# fresh component is provably DERIVED FROM THE DESIGN. So we read the canonical's
# JSX element tree and re-express it in RN primitives (<div> -> <View>, text ->
# <Text>, <button>/<a> -> <Pressable>, <input> -> <TextInput>, <img> -> <Image>),
# preserving the visible text and nesting. That makes the generated file faithful
# to the canonical's layout, while deliberately omitting behavior.
#
# Determinism: `generate` is a pure function of (canonical_src, screen) — same
# inputs, byte-identical output. No clock, no IO, no randomness (the pipeline owns
# provenance/timestamps via the hash-log).

from __future__ import annotations

import re

from . import Target, register


# Web tag -> (RN component, needs-text-wrap). The order matters only for the
# regex; resolution is exact-tag.
_WEB_TO_RN = {
    "div": "View",
    "section": "View",
    "header": "View",
    "footer": "View",
    "main": "View",
    "nav": "View",
    "article": "View",
    "aside": "View",
    "ul": "View",
    "ol": "View",
    "li": "View",
    "span": "Text",
    "p": "Text",
    "h1": "Text",
    "h2": "Text",
    "h3": "Text",
    "h4": "Text",
    "h5": "Text",
    "h6": "Text",
    "label": "Text",
    "a": "Pressable",
    "button": "Pressable",
    "input": "TextInput",
    "textarea": "TextInput",
    "img": "Image",
}

# The RN primitives we may emit; we import exactly the ones used so the generated
# file lints clean (no unused imports).
_PRIMITIVE_ORDER = ["View", "Text", "Image", "TextInput", "Pressable", "ScrollView"]


def _component_name(screen: str) -> str:
    """Normalize a screen name into a PascalCase RN component identifier."""
    cleaned = re.sub(r"[^0-9A-Za-z]+", " ", screen).strip()
    if not cleaned:
        cleaned = "Screen"
    parts = [p for p in cleaned.split(" ") if p]
    name = "".join(p[:1].upper() + p[1:] for p in parts)
    if not re.match(r"[A-Za-z_]", name):
        name = "S" + name
    return name


def _strip_jsx_return(src: str) -> str:
    """Best-effort: pull the JSX returned by the canonical so we can re-express its
    element tree. We look for the outermost return(...) / => (...) JSX block. If we
    cannot locate one, we fall back to scanning the whole source for web tags (the
    canonical is still the source of structure either way)."""
    # Prefer the body of a `return ( ... );` block.
    m = re.search(r"return\s*\(", src)
    if m:
        start = m.end() - 1  # at the '('
        depth = 0
        for i in range(start, len(src)):
            c = src[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return src[start + 1 : i]
    return src


def _collect_web_tags(jsx: str):
    """Return the ORDERED list of (rn_component, visible_text) the canonical's JSX
    implies. visible_text is the immediate text content for text-y tags (used so
    the generated component shows the same labels), else ''."""
    out = []
    # Match opening tags of known web elements (self-closing or not). We capture
    # the tag name and, for non-self-closing text tags, the inner text up to the
    # matching close (shallow — good enough for a faithful skeleton).
    tag_re = re.compile(
        r"<\s*([a-zA-Z][a-zA-Z0-9]*)\b([^>]*?)(/?)>",
        re.DOTALL,
    )
    for mt in tag_re.finditer(jsx):
        tag = mt.group(1).lower()
        rn = _WEB_TO_RN.get(tag)
        if rn is None:
            continue
        text = ""
        if rn == "Text":
            # Grab inner text until the next '<' (shallow inner-text capture).
            rest = jsx[mt.end():]
            inner = re.match(r"\s*([^<{][^<{]*)", rest)
            if inner:
                text = inner.group(1).strip()
        out.append((rn, text))
    return out


def _render_tree(tags) -> str:
    """Render a flat, faithful RN JSX body from the collected tags. We keep it a
    single ScrollView root with each collected element as a child, so the visible
    text + element kinds match the canonical without inventing nesting we cannot
    prove. Behavior props are deliberately absent."""
    lines = []
    indent = "        "
    for rn, text in tags:
        if rn == "Text":
            label = text if text else ""
            if label:
                # Escape braces/backslashes minimally for a JSX string child.
                safe = label.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
                lines.append("%s<Text style={s.text}>%s</Text>" % (indent, safe))
            else:
                lines.append("%s<Text style={s.text} />" % indent)
        elif rn == "Image":
            lines.append("%s<Image style={s.image} source={{ uri: '' }} />" % indent)
        elif rn == "TextInput":
            lines.append("%s<TextInput style={s.input} />" % indent)
        elif rn == "Pressable":
            # Behavior-free: NO onPress — the migration step wires handlers.
            lines.append("%s<Pressable style={s.pressable} />" % indent)
        else:  # View
            lines.append("%s<View style={s.view} />" % indent)
    if not lines:
        lines.append("%s<Text style={s.text} />" % indent)
    return "\n".join(lines)


def _used_primitives(tags):
    # ScrollView + View are ALWAYS in the emitted skeleton (root + screen wrapper);
    # Text is the fallback child. Import them unconditionally so the generated file
    # never references an unimported primitive (would not compile / lint clean).
    used = {"ScrollView", "View", "Text"}
    for rn, _ in tags:
        used.add(rn)
    return [p for p in _PRIMITIVE_ORDER if p in used]


class ReactNativeTarget(Target):
    name = "rn"
    language = "React Native"
    extension = "tsx"

    def generate(self, canonical_src: str, screen: str) -> str:
        comp = _component_name(screen)
        jsx = _strip_jsx_return(canonical_src)
        tags = _collect_web_tags(jsx)
        body = _render_tree(tags)
        prims = _used_primitives(tags)
        import_line = "import { %s } from 'react-native';" % ", ".join(prims)

        # The generated header records that this file is DERIVED FROM THE CANONICAL
        # and is behavior-free until migration. It is not a guide — it is a stamp.
        header = (
            "// %s.tsx — REGENERATED by designmatch v2 (target: React Native).\n"
            "// Derived from the canonical design — visually faithful, BEHAVIOR-FREE.\n"
            "// Handlers / state / API / navigation / effects / prop wiring are NOT\n"
            "// present yet: the migration step re-attaches them from the quarantined\n"
            "// old component, and the behavioral diff must report K=0 before the old\n"
            "// file leaves tmp. Do not hand-edit structure here — re-run regen.\n"
        ) % comp

        return (
            header
            + "import React from 'react';\n"
            + import_line
            + "\n"
            + "import { StyleSheet } from 'react-native';\n"
            + "\n"
            + "export default function %s() {\n" % comp
            + "  return (\n"
            + "    <ScrollView style={s.root} contentContainerStyle={s.content}>\n"
            + "      <View style={s.screen}>\n"
            + body
            + "\n"
            + "      </View>\n"
            + "    </ScrollView>\n"
            + "  );\n"
            + "}\n"
            + "\n"
            + "const s = StyleSheet.create({\n"
            + "  root: { flex: 1 },\n"
            + "  content: { flexGrow: 1 },\n"
            + "  screen: { flex: 1 },\n"
            + "  view: {},\n"
            + "  text: {},\n"
            + "  image: {},\n"
            + "  input: {},\n"
            + "  pressable: {},\n"
            + "});\n"
        )


# Self-register the launch target.
register(ReactNativeTarget())
