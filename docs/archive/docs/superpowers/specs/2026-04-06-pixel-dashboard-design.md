# superx Pixel Art Dashboard — Design Specification

**Date:** 2026-04-06
**Status:** Approved

## Overview

A locally-running pixel art dashboard that serves as the visual face of superx. Modern pixel art aesthetic (Celeste/Stardew Valley style). Shows real-time activity as superx orchestrates tasks, with distinct character sprites for each agent type.

## Layout

Three panels on a single page:

### Top: Timeline Feed
- Scrolling event log with pixel art icons
- Events stream in real-time via SSE
- Each event: timestamp, tiny agent avatar, message
- Color-coded: green (success), yellow (in-progress), red (error), blue (info)

### Bottom: War Room
- Grid of agent cards
- Each agent type has a distinct 32x32 pixel art character sprite
- Cards show: agent name, current task, status, progress indicator
- Active agents animate (sprite bobs/works)
- Idle slots show dimmed "available" state

### Right Tab: Game Map
- Project directory structure as a pixel art town
- Directories = buildings, key files = landmarks
- Agent sprites walk to buildings they're working on
- Completed areas glow/light up
- Dependency paths between buildings

## Input & Control

- Text input box in the UI for typing prompts
- On submit: backend spawns claude with all permissions in background
- "Open Terminal" button top-right — slides open a dark terminal panel showing raw claude output
- Terminal uses pixel font, green-on-black aesthetic, resizable

## Agent Sprites (Distinct Characters)

| Agent | Character | Visual |
|---|---|---|
| superx | Purple monk in lotus/yoga position | Serene, meditating, orchestrating |
| architect | Blue figure with blueprints | Planning pose |
| coder | Green figure with laptop | Typing animation |
| design | Magenta figure with palette | Painting/drawing |
| test-runner | Yellow figure with checklist | Checking items off |
| lint-quality | Orange figure with broom | Sweeping/cleaning |
| docs-writer | Cyan figure with quill | Writing |
| reviewer | Red figure with magnifying glass | Inspecting |

## Tech Stack

- Backend: Python (stdlib + file watching)
- Frontend: Vanilla HTML/CSS/JS, Canvas for game map
- Sprites: CSS pixel art (box-shadow technique) or inline SVG/data URLs
- Real-time: Server-Sent Events (SSE)
- Process: Backend spawns `claude --dangerously-skip-permissions` subprocess

## Architecture

1. User opens dashboard (localhost:8080)
2. Types prompt in input box
3. Backend spawns claude process in background
4. Backend watches superx-state.json (polling every 500ms)
5. State changes → SSE → frontend
6. Frontend updates timeline, war room, and game map
7. Terminal panel streams raw stdout from claude process

## File Structure

```
ui/
├── server.py          # Python backend — HTTP + SSE + process manager
├── static/
│   ├── index.html     # Single page app
│   ├── style.css      # Pixel art theme, layout, animations
│   ├── app.js         # Dashboard logic, SSE handling, rendering
│   ├── map.js         # Game map canvas renderer
│   ├── sprites.js     # Pixel art sprite definitions
│   └── terminal.js    # Terminal panel logic
```
