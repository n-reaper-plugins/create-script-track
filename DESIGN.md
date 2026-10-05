# CreateScriptTrack design (v0.1.1)

## The model in one paragraph

A **cue sheet** is a Markdown text. Parsing it gives an ordered list of **cues** `{id, title, level, body}`; the text itself is
never changed by the script. The **timeline** is a set of project **markers**. A cue is *mapped* when a marker exists whose
name starts with the same prefix and id. Everything the user sees is derived from those two inputs plus the transport position:

```
text --parse--> cues ──┐
                       ├─ map by id ─> rows {cue, marker, t, status} ─> timed (sorted by t) ─┬─> current cue (position)
markers ───────────────┘                                                                    ├─> preview / prompter
                                                                                            └─> comment items
```

## Decisions made, and how they are implemented

| Question | Decision | Implementation |
|---|---|---|
| Where do cue times come from? | **Markers** (Markdown has no timecodes) | `App:scan` maps `RA.markers()` to cues by id with the same parser the headers use (`C.match_cue_text`), so a name we write is always recognised again |
| "adds first n tracks as comments" | Read as the first **n non-empty lines** of the cue body, plus an optional title line | `C.comment_text`. *Assumption – say so if you meant n bullets or paragraphs* |
| Reference + local copy | Path and full text stored in **project ext-state**, chunked 4 000 chars, escaped to one line, each chunk prefixed `\|`, FNV-1a hash to detect damage | `RA.save_local` / `RA.load_local` |
| Sync | Source wins / Manual / Local wins. The file is polled every 1 s and compared **by content** (no mtime API in ReaScript) | `App:poll_file` |
| Identity of our track and items | `P_EXT` tags, never names: track `CST_comments=1`, item `CST_cue=<id>` | `RA.find_comment_track`, `our_items` |
| Marker names | Canonical `<prefix> <id> <title>`; renaming is a setting | `C.marker_name`, `App:sync` |
| Prefix change | Markers matching the old prefix are renamed first, so the mapping survives | `App:change_prefix` (applied when the field loses focus, not per keystroke) |
| Undo | Same two modes as AliasTrack: silent syncs (default) or one `CreateScriptTrack: sync` point per changing sync; commands are always one step | `App:sync`, `RA.undo_begin/end` |
| Settings scope | Per **project** (`cfg_*` keys in project ext-state) | `App:load_project`, `App:set`; a project-tab switch reloads (`EnumProjects(-1)`) |
| Comment track colour | One colour (0xRRGGBB, default the accent) or none, applied to the track and its items. New items always get it; **existing items are only recoloured when the colour setting changed** (compared with `color_applied`, stored in the project), so a colour you gave one item by hand survives rebuilds and restarts. A recreated track counts as a change. Pure black = none | `App:comment_rgb`, `App:set_comment_color`, `RA.set_comment_items(..., recolor)`, `RA.set_track_color` |
| Old name | Projects saved by 0.1.0 are migrated once: section keys copied only if the new section is empty, then the old section removed; tags on the comment track and its items are accepted and upgraded | `RA.LEGACY`, `RA.migrate_legacy`, `RA.find_comment_track`; lines marked `legacy:keep` are skipped by `tools/rename.lua` |
| Renaming | A script, not find-and-replace by hand: names derived from `NewName` (prefix = initials, slug, snake), replaced in code, docs and installer, files renamed, bundle rebuilt, leftovers listed | `tools/rename.lua`, `tools/project.lua`, `tools/test_rename.lua` |
| Colours of the window | The 262° theme | `CSTUI.lua` uses the `THEME` table, `push_theme` and a balanced `PopStyleColor` verbatim; a test checks 17 pushed and 17 popped, open and collapsed, and with preview text |

## What a sync does (0.3 s after the project stops changing, never while the mouse is down*)

1. **Scan**: markers -> rows. Duplicate cue ids: the first is mapped, the rest are `duplicate`. A second marker for one id,
   or a marker whose id is not in the file, is an **orphan** (listed, never changed automatically).
2. **Rename** mapped markers to the canonical name (if enabled).
3. **Comment track**: build the wanted items, hash them; if the hash and the item count equal the last run, stop. Otherwise
   create the track if needed, show it once when switched on, then create / move / re-text / delete **only tagged items**.
   Writes are lazy: the undo block opens at the first real write, so an identical rebuild leaves no undo point.
4. Switched off: hide the track once (or delete it, per setting). A track the user shows or hides afterwards is not fought.

\* only with js_ReaScriptAPI; otherwise the debounce alone applies.

Every tick (not only after a change) also reads the position (playhead while playing, otherwise the edit cursor; or the clicked
cue when *Follow* is off) and finds the current cue by a scan of the sorted `timed` list. That is a few getters, no project scan.

## Edge cases and what happens

| Case | Result |
|---|---|
| Two cues at the same time | Both mapped; the first (file order) gets a 0.1 s comment item, the later one runs to the next cue |
| Cue removed from the file | Its marker becomes an orphan (kept); its comment item is deleted |
| Cue renumbered in the file | Old marker = orphan, new id = unmapped. **Remap** moves the marker over (one click) |
| Marker is a region | Ignored (regions are not cue markers) |
| File deleted / moved | `FILE MISSING`, the stored copy keeps working |
| Stored copy damaged | Not used; message shown; relink the file |
| Header inside a code fence | Not a cue |
| Empty prefix | Bare numbers match, including `## 2024 Plan` |
| Project tab switched | State reloads from the other project |

## Open questions

1. **Regions** from each cue to the next (optional in the plan): not in 0.1.0 – wanted?
2. **Prefix per header level** (e.g. `#` = scene, `##` = cue)? Today one prefix for all levels.
3. Should an **unmapped cue** be placeable in bulk (e.g. all at the cursor, spaced by a gap), or is *Set* while playing enough?
4. A **cue-end** convention in the Markdown (e.g. `@ 01:23.5`) to create markers from the file itself, with markers still the truth afterwards?
