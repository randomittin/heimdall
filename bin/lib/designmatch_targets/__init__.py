#!/usr/bin/env python3
# designmatch_targets — the LANGUAGE-PLUGGABLE TARGET SEAM for designmatch v2.
#
# The regenerate pipeline converts a React/JS canonical design directly into a
# FRESH front-end component in the target language. designmatch launches
# React-Native-only, but the architecture is language-pluggable: Flutter /
# Kotlin / Swift slot in LATER by implementing an interface, NOT by editing the
# regenerate pipeline. The conversion lives behind a SEAM: a small `Target`
# interface plus a registry. The pipeline asks the registry for a target by name
# (`rn` at launch) and calls one method — `generate(canonical_src, screen)`.
# Adding a second target is `register(FlutterTarget())` + an impl file; the
# pipeline code is untouched.

from __future__ import annotations

import abc
from typing import Dict, List, Type


class Target(abc.ABC):
    """The language-pluggable conversion interface. One concrete subclass per
    target front-end language. The regenerate pipeline depends ONLY on this
    interface, so a new language is added by implementing it + registering."""

    #: short, lowercase registry key (e.g. "rn", "flutter").
    name: str = ""
    #: human-readable language label (e.g. "React Native").
    language: str = ""
    #: generated-file extension WITHOUT the leading dot (e.g. "tsx", "dart").
    extension: str = ""

    @abc.abstractmethod
    def generate(self, canonical_src: str, screen: str) -> str:
        """Convert a React/JS canonical's source into a FRESH component in this
        target's language. Deterministic; no IO. Behavior-free by design — the
        migration step re-attaches behavior, the behavioral diff proves it."""
        raise RuntimeError("Target.generate must be overridden by a subclass")


_REGISTRY: Dict[str, Target] = {}


def register(target: Target) -> Target:
    """Register a concrete Target instance under its `.name`. Re-registering the
    same name REPLACES the prior entry."""
    if not isinstance(target, Target):
        raise TypeError("register() expects a Target instance, got %r" % (target,))
    if not target.name:
        raise ValueError("target %r has no .name" % (target,))
    _REGISTRY[target.name] = target
    return target


def register_class(cls: Type[Target]) -> Type[Target]:
    """Instantiate a Target subclass and register the instance."""
    register(cls())
    return cls


def get_target(name: str) -> Target:
    """Return the registered Target for `name`, or raise KeyError listing the
    available keys (so a typo'd target fails loudly, never silently RN)."""
    try:
        return _REGISTRY[name]
    except KeyError:
        raise KeyError(
            "no designmatch target %r — available: %s"
            % (name, ", ".join(sorted(_REGISTRY)) or "(none)")
        )


def available() -> List[str]:
    """Sorted list of registered target keys."""
    return sorted(_REGISTRY)


def is_registered(name: str) -> bool:
    return name in _REGISTRY


# RN is the ONLY target at launch. A new language adds its own module + register
# call; this import line is the single place the launch set is declared.
from . import rn  # noqa: E402,F401  (import side effect: registers "rn")
