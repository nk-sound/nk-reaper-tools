# REAPER Scripts

A collection of Lua ReaScripts for REAPER, built for film/sound post-production workflows.

## Scripts

| Script | Description |
|---|---|
| [Marker Spotter](marker-spotter/) | Scans project markers, matches them against user-defined rules, and commits MIDI notes to specified tracks. ReaImGui-based UI with rule cards, timeline view, and presets. |
| [Take n Bake](take-n-bake/) | Renders Take FX onto media items while preserving the full source audio file length, so handles can still be dragged out to the original file boundaries. |

## Installation

1. Download the `.lua` file for the script you want (or clone entire repo).
2. In REAPER: **Actions → Show Action List → New action... → Load ReaScript...**
3. Select the `.lua` file.
4. Run it from the Action List, or assign it to a toolbar button / shortcut.

Marker Spotter additionally requires the **ReaImGui** extension, installable via [ReaPack](https://reapack.com/).

## License

MIT — use, modify, and redistribute freely.
