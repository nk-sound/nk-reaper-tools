# Take n Bake

A REAPER Lua ReaScript that renders Take FX onto selected media items while
preserving the **full source file length** so that the resulting item's
handles remain draggable (is that a word?) out to the original file's boundaries

## Requirements

- REAPER

## Features

- Bakes all enabled Take FX into a new audio file per selected item
- Preserves the full source length (not just the trimmed item extent)
- Automatic mono/stereo channel detection from the source file
- Rendered file saved alongside the original source, suffixed `_fx` (auto-incremented on collision)
- Preserves fade in/out length, shape, and direction
- Correctly handles gain-sensitive FX (compressors, limiters, saturation) by
  leaving take/item volume in place during render rather than restoring it
  afterward — volume is baked into the audio rather than doubled
- Bakes in take envelope information and item properties as well, such as play rate and pitch

## Usage

1. Load script
2. Select one or more audio items with Take FX applied
3. Run **Take n Bake**
4. Each item is replaced with a new item referencing the rendered file, with
   the same position, length, and fades as before — but handles can now be
   dragged out to the full original source length.

Items skipped due to errors (no FX, MIDI take, offline media, etc.) are
reported in the REAPER console.
