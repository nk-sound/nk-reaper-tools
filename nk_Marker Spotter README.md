# Marker Spotter (v1.1)

A REAPER Lua ReaScript for film spotting workflows. Scans project markers, matches
them against user-defined rules, and commits MIDI notes to specified tracks at the
matched positions.

## Requirements

- REAPER
- [ReaImGui](https://reapack.com/) extension (install via ReaPack)

## Features

- **Rule cards** — color-coded, collapsible cards defining match criteria and MIDI output
- **Per-rule fields** — marker search string, destination track, MIDI note, velocity, note length, and timing offset
- **Copy / Paste** — copy one rule's settings and paste them into another
- **Presets** — save and load full rule sets, stored via REAPER's ExtState
- **Mini timeline preview** — collapsible strip showing queued note positions and a live playhead
- **Log panel** — color-coded scan/commit log

## Usage

1. Load the script
2. Add rules: enter a marker search string (case-insensitive substring match),
   destination track name, MIDI note (or range: `C2-E2`), velocity, note length, and timing offset.
3. Click **Scan** to preview matches against the current project's markers
4. Click **Commit** to write the MIDI notes to specified tracks
5. Optionally save the current rule set as a **Preset** for reuse across projects

## Version history

- **v1.1** — Removed the marker color filter. Added per-rule Copy/Paste. Added saveable/loadable presets via ExtState.
- **v1.0** — Initial full rewrite: rule card UI, color-coded log, collapsible mini
  timeline with live playhead.
