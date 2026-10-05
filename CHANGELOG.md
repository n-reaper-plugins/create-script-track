# Changelog

## 0.1.1 – comment track colour, new name
* **Colour for the comment track:** a swatch row and a colour editor in the *Comment track* section; the track and its items get the
  colour (default: the accent). *Colour the track and its items* off = REAPER's default colour. A new pick recolours everything;
  colours you set on single items survive ordinary rebuilds and restarts.
  Projects saved by 0.1.0 are imported once (file link, stored copy, settings) and the old comment track and its items are reused.  <!-- legacy:keep -->
  The installer removes the old script and action.
* `tools/rename.lua` renames the whole project (code, files, docs, installer, folder) and verifies the result; `tools/project.lua` holds the names and `build.lua` reads them.
* Offline tests: 468 checks (colour, migration, rename round trip).

## 0.1.0 – first version
* Markdown cue sheet: headers `<prefix> 1 / 1.2 / 1.2.3 <title>`, settable prefix and header levels, code fences ignored, duplicate ids flagged.
* Link a `.md` (dialog, typed path, drag & drop); the full text is also stored in the project. Sync modes: Source wins / Manual (Pull, Keep mine) / Local wins; file missing falls back to the stored copy.
* Cues mapped to project markers by id: Set to playhead/cursor, Clear, adopt existing markers, rename to the canonical name (setting), orphan markers with Remap / Delete, Prev / Next.
* Preview with current-cue highlight and auto-scroll; follow playhead / edit cursor / off; large-text Prompter (current + next cue).
* Comment track: one text item per mapped cue (title + first n lines), follows markers and file edits, hide or delete when switched off; only tagged items are touched.
* Changing the prefix renames the markers that followed the old one.
* Undo modes "One step per edit" (silent syncs, default) and "Separate sync steps"; Freeze; per-project settings; project-tab switch reloads.
* ReaImGui window in the 262° theme; macOS installer; offline tests: 344 checks; probe script for the REAPER behaviours the tests only assume.
