# AoE2 Map Overlay

A small always-on-top overlay for Age of Empires II: Definitive Edition. It is a single Python
script wrapped in a `.bat`, so double-clicking it runs it with `pythonw`.

It shows the map and its resources, your opponent's civ with likely openings and counters,
ladder ratings, a herd counter, an idle Town Center alert, your win/loss record, and a
ranked party invite helper with optional Discord posting.

It does not read game memory. It reads the replay file's lobby settings, the game's own data
files, the public ladder API, and text that is already on screen.

## Run

Needs Python 3 on PATH. Double-click `AoE2 Map Overlay.bat`.

Settings (Discord webhook, friends) and stats are stored in `%APPDATA%\AoE2MapOverlay`.

## Branches

- `Prod`: the version you play with.
- `dev`: work in progress. Merge into `Prod` once tested.
