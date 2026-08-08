# Image Triage — Keep or Clear from Context

**Read this the moment the user attaches one or more images**, before starting work on
the task those images belong to. If no image is attached, this file is irrelevant.

When the user attaches images, classify EACH image BEFORE starting work:

| Type | Examples | Action |
|---|---|---|
| **Reference** | Target design mockup, UI spec, wireframe, architecture diagram, brand guidelines, color palette | **KEEP in context.** Save to `.planning/ref/` for agents to reference throughout the task. These are the "north star" — needed until the task is fully verified. |
| **Bug evidence** | Screenshot of a broken UI, error message, console log, wrong layout, visual glitch | **Use then clear.** Read the image to understand the bug, extract the relevant details (error text, wrong element, expected vs actual), then proceed WITHOUT keeping the image in context. The fix doesn't need the screenshot — just the diagnosis. |
| **Informational** | Terminal output, docs page, API response, existing code screenshot | **Extract then clear.** Copy the relevant text/data from the image into your working context as plain text, then don't carry the image forward. Text is cheaper than pixels. |

## Why this matters
Images are expensive in context — a single screenshot can cost 1000+ tokens. A bug screenshot is only useful for diagnosis; once you know "the button is misaligned by 20px on mobile", the image is dead weight. But a design mockup needs to stay in context so every agent can verify their output matches the target.

## How to implement
- On receiving images, classify each one and announce: "Keeping design mockup in context as reference. Bug screenshot analyzed — extracting details, clearing from context."
- For reference images: save to `.planning/ref/<descriptive-name>.png` so subagents can `Read` them
- For bug/info images: extract details into a text note, then do NOT pass the image to subagents
- When spawning agents, only attach reference images — never bug screenshots
