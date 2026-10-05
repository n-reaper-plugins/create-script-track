package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
local App = require("CSTApp")
local RA = require("CSTReaper")

local C = require("CSTCore")
local FILE = os.tmpname()
local MD1 = [[
# Show

## Q 1 Opening
Lights fade up.
- house to half
- preset 4

## Q 1.1 Walk-on
Actor enters left.

## Q 2 Storm
SFX: thunder
]]

local function settle(app) for _ = 1, 3 do Mock.tick(1); app:tick() end end
local function names() return table.concat(Mock.marker_names(), " | ") end
local function count_undo(label) local n = 0 for _, l in ipairs(S.undo) do if l == label then n = n + 1 end end return n end

---------------------------------------------------------------------------------------------------------- empty project
local app = App.new()
T.eq(app.status, "none", "nothing linked: status none")
T.eq(#app.doc.cues, 0, "no cues yet")
settle(app)
T.eq(#app.timed, 0, "empty tick works")
T.eq(app.cfg.sync_mode, "source", "default sync mode")

---------------------------------------------------------------------------------------------------------- link a file
Mock.write(FILE, MD1)
app:set("prefix", "Q")
T.ok(app:set_file(FILE), "set_file ok")
T.eq(#app.doc.cues, 3, "three cues parsed with prefix Q")
T.eq(app.status, "live", "linked in source mode: live")
T.eq(RA.proj_get("src_path"), FILE, "path stored in the project")
T.eq(RA.load_local(), MD1, "local copy stored in the project")
T.ok(not app:set_file("/nonexistent/x.md"), "unreadable file refused"); T.ok(app.msg:find("Cannot read", 1, true), "reason shown")
T.eq(app.path, FILE, "failed link keeps the old path")

---------------------------------------------------------------------------------------------------------- marker mapping
Mock.marker(5, "Q1 opening")            -- sloppy name: adopted, then renamed
Mock.marker(10, "Q 2 Storm")
Mock.marker(15, "Q 9 Old cue")          -- orphan
Mock.marker(16, "Take 3")               -- unrelated: ignored
Mock.region(0, 20, "Q 1.1 Walk-on")     -- regions are not cue markers
settle(app)
local c = app:counts()
T.eq(c.mapped, 2, "two cues mapped"); T.eq(c.unmapped, 1, "1.1 has no marker"); T.eq(c.orphans, 1, "Q 9 is an orphan")
T.eq(app.row_by_id["1"].status, "mapped", "cue 1 mapped"); T.eq(app.row_by_id["1.1"].status, "unmapped", "cue 1.1 unmapped")
T.eq(app.orphans[1].id, "9", "orphan id")
T.eq(Mock.marker_named("Q 1 Opening") ~= nil, true, "sloppy marker renamed to the canonical name")
T.eq(names(), "Q 1 Opening | Q 2 Storm | Q 9 Old cue | Take 3", "unrelated markers and orphans untouched")
T.eq(#app.timed, 2, "timed list"); T.eq(app.timed[1].id, "1", "timed order")

-- title edit in the .md renames the marker
Mock.tick(2)
Mock.write(FILE, (MD1:gsub("Opening", "Overture")))
settle(app)
T.ok(Mock.marker_named("Q 1 Overture") ~= nil, "file change reached the marker name (source wins)")
T.eq(app.doc.cues[1].title, "Overture", "re-parsed")

-- rename off: markers keep the user's own names
app:set("rename_markers", false)
Mock.rename_marker(Mock.marker_named("Q 2 Storm"), "Q 2 my own name")
settle(app)
T.ok(Mock.marker_named("Q 2 my own name") ~= nil, "rename off leaves the name alone")
T.eq(app.row_by_id["2"].status, "mapped", "still mapped by id")
app:set("rename_markers", true); settle(app)
T.ok(Mock.marker_named("Q 2 Storm") ~= nil, "rename on restores the canonical name")

---------------------------------------------------------------------------------------------------------- following the position
S.cursor, S.playing = 0, false; settle(app)
T.eq(app.cur_id, nil, "before the first cue: none")
S.cursor = 7; settle(app); T.eq(app.cur_id, "1", "cursor between cues: previous cue")
S.playing, S.play_pos = true, 12; settle(app); T.eq(app.cur_id, "2", "playing: follows the playhead")
T.eq(app.want_scroll, "2", "change of cue asks the preview to scroll")
app:set("follow", "cursor"); settle(app); T.eq(app.cur_id, "1", "follow cursor ignores the playhead")
app:set("follow", "off"); app:select("2"); settle(app); T.eq(app.cur_id, "2", "follow off: the selected cue is current")
app:select("1"); settle(app); T.eq(app.cur_id, "1", "selection changes the current cue")
app:set("follow", "play"); S.playing = false; S.cursor = 11; settle(app)
T.eq(app.cur_id, "2", "stopped: edit cursor is used")
local cur, nxt = app:prompter_rows(); T.eq(cur.id, "2", "prompter current"); T.eq(nxt, nil, "no next after the last")
S.cursor = 0; settle(app); cur, nxt = app:prompter_rows(); T.eq(cur, nil, "prompter: nothing current yet"); T.eq(nxt.id, "1", "prompter: next is the first")

-- stepping
S.cursor = 7; settle(app)
T.ok(app:step(1), "next"); T.eq(S.cursor, 10, "next cue moves the cursor"); settle(app)
T.ok(app:step(-1), "previous"); T.eq(S.cursor, 5, "previous cue"); settle(app)
T.ok(not app:step(-1), "nothing before the first cue")
S.cursor = 7; settle(app); app:step(-1); T.eq(S.cursor, 5, "previous inside a cue goes to its start")
S.cursor = 20; settle(app); T.ok(not app:step(1), "nothing after the last cue")

---------------------------------------------------------------------------------------------------------- commands
S.cursor = 30; S.playing = false
local before = #S.undo
T.ok(app:set_to_cursor("1.1"), "set unmapped cue to cursor"); settle(app)
T.ok(Mock.marker_named("Q 1.1 Walk-on") ~= nil, "marker created with the cue name"); T.eq(Mock.marker_named("Q 1.1 Walk-on").pos, 30, "at the cursor")
T.eq(app.row_by_id["1.1"].status, "mapped", "now mapped"); T.eq(S.undo[#S.undo], "CreateScriptTrack: set cue 1.1", "one undo step"); T.eq(#S.undo, before + 1, "exactly one")
S.playing, S.play_pos = true, 31
app:set_to_cursor("1.1"); T.eq(Mock.marker_named("Q 1.1 Walk-on").pos, 31, "while playing the playhead is used"); S.playing = false
app:set_to_cursor("1.1"); settle(app)
local nm = 0 for _, n in ipairs(Mock.marker_names()) do if n:find("Q 1.1", 1, true) then nm = nm + 1 end end
T.eq(nm, 1, "setting again moves the marker, no second one")
T.ok(app:clear_marker("1.1"), "clear marker"); settle(app); T.eq(app.row_by_id["1.1"].status, "unmapped", "unmapped again")
T.ok(not app:clear_marker("1.1"), "nothing to clear")
T.ok(not app:set_to_cursor("77"), "unknown cue")
-- remap an orphan onto the unmapped cue
local orphan = app.orphans[1]
T.ok(app:remap(orphan.marker, "1.1"), "remap orphan"); settle(app)
T.ok(Mock.marker_named("Q 1.1 Walk-on") ~= nil, "orphan renamed to the cue"); T.eq(#app.orphans, 0, "no orphans left")
T.ok(not app:remap(Mock.marker_named("Q 1 Overture"), "2"), "cannot remap onto a cue that has a marker")
Mock.marker(40, "Q 8 Gone"); settle(app); T.eq(#app.orphans, 1, "new orphan"); app:delete_orphan(app.orphans[1].marker); settle(app); T.eq(#app.orphans, 0, "orphan deleted")

---------------------------------------------------------------------------------------------------------- duplicates
Mock.write(FILE, MD1 .. "\n## Q 2 Storm again\nsecond one\n")
app:sync_now(); settle(app)
T.eq(app.doc.dups, 1, "duplicate id seen"); T.eq(app:counts().duplicate, 1, "counted as duplicate")
T.eq(app.rows[#app.rows].status, "duplicate", "second occurrence is not mapped")
T.eq(app.row_by_id["2"].cue.title, "Storm", "first occurrence wins")
Mock.marker(50, "Q 2 extra marker"); settle(app)
T.eq(#app.orphans, 1, "a second marker for the same cue is an orphan"); T.eq(app.orphans[1].why, "second marker for this cue", "with a reason")
app:delete_orphan(app.orphans[1].marker)
Mock.write(FILE, MD1); app:sync_now(); settle(app)

---------------------------------------------------------------------------------------------------------- comment track
T.eq(Mock.track_named("Cues"), nil, "no comment track while off")
app:set("comments", true); settle(app)
local tr = Mock.track_named("Cues")
T.ok(tr ~= nil, "comment track created"); T.eq(S.tracks[1], tr, "as the first track"); T.eq(tr.ext.CST_comments, "1", "tagged")
local items = Mock.items_on(tr)
T.eq(#items, 3, "one item per mapped cue (1, 1.1 [remapped], 2)")
T.eq(items[1].notes, "Q 1 Opening\nLights fade up.\n- house to half", "title + first 2 lines")
T.eq(items[1].p.D_POSITION, 5, "item at the cue marker")
T.eq(items[1].p.D_LENGTH, items[2].p.D_POSITION - 5, "item runs to the next cue")
T.eq(items[#items].p.D_LENGTH, 8, "last item uses the last-cue length")
T.eq(items[1].ext.CST_cue, "1", "item tagged with the cue id")
local nitems = #tr.items
settle(app); T.eq(#tr.items, nitems, "settled: no duplicates created")
local dirty = S.dirty; settle(app); T.eq(S.dirty, dirty, "idle ticks write nothing")

app:set("comment_lines", 1); settle(app)
T.eq(Mock.items_on(tr)[1].notes, "Q 1 Opening\nLights fade up.", "n lines changed")
app:set("comment_lines", 0); app:set("comment_title", false); settle(app)
T.eq(Mock.items_on(tr)[1].notes, "", "n = 0 without title: empty")
app:set("comment_lines", 2); app:set("comment_title", true); settle(app)

-- marker moves -> item follows
Mock.move_marker(Mock.marker_named("Q 2 Storm"), 60); settle(app)
local last = Mock.items_on(tr); T.eq(last[#last].p.D_POSITION, 60, "item follows its marker")
-- user's own untagged item on the track is never touched
local mine = reaper.AddMediaItemToTrack(tr); reaper.SetMediaItemInfo_Value(mine, "D_POSITION", 1); reaper.GetSetMediaItemInfo_String(mine, "P_NOTES", "my note", true)
app:rebuild_comments(); settle(app)
T.ok(not mine.deleted and mine.notes == "my note", "untagged items are left alone")
-- cue removed from the md -> its item goes
Mock.write(FILE, (MD1:gsub("## Q 2 Storm\nSFX: thunder\n", "")))
app:sync_now(); settle(app)
local ids = {} for _, it in ipairs(tr.items) do if it.ext.CST_cue then ids[#ids + 1] = it.ext.CST_cue end end
table.sort(ids); T.eq(table.concat(ids, ","), "1,1.1", "item of the removed cue deleted")
T.ok(Mock.marker_named("Q 2 Storm") ~= nil, "its marker stays (it is now an orphan)"); T.eq(#app.orphans, 1, "orphan listed")
Mock.write(FILE, MD1); app:sync_now(); settle(app)

-- toggle off: hide / delete
app:set("comments", false); settle(app)
T.eq(tr.vals.B_SHOWINTCP, 0, "switched off: track hidden"); T.ok(not tr.deleted, "not deleted"); T.ok(#tr.items > 0, "items kept")
app:set("comments", true); settle(app)
T.eq(tr.vals.B_SHOWINTCP, 1, "switched on again: same track, visible");
local count_tracks = 0 for _, t in ipairs(S.tracks) do if t.ext.CST_comments == "1" then count_tracks = count_tracks + 1 end end
T.eq(count_tracks, 1, "never more than one comment track")
app:set("comment_off", "delete"); app:set("comments", false); settle(app)
T.ok(tr.deleted, "delete mode: track removed"); T.eq(Mock.track_named("Cues"), nil, "gone")
app:set("comments", true); settle(app)
T.ok(Mock.track_named("Cues") ~= nil, "recreated when switched on again"); T.eq(#Mock.items_on(Mock.track_named("Cues")), 3, "with its items")
app:set("comment_off", "hide")

---------------------------------------------------------------------------------------------------------- comment colour
local function native(rgb) return reaper.ColorToNative(rgb >> 16 & 0xFF, rgb >> 8 & 0xFF, rgb & 0xFF) | 0x1000000 end
local ctr = Mock.track_named("Cues")
T.eq(app.cfg.comment_color, 0x8542FA, "default colour is the accent"); T.eq(app.cfg.comment_color_on, true, "colouring on by default")
T.eq(ctr.vals.I_CUSTOMCOLOR, native(0x8542FA), "track has the colour")
for _, it in ipairs(ctr.items) do T.eq(it.p.I_CUSTOMCOLOR, native(0x8542FA), "item has the colour") end
app:set_comment_color(0x3FA7D6); settle(app)
T.eq(ctr.vals.I_CUSTOMCOLOR, native(0x3FA7D6), "new colour reaches the track")
for _, it in ipairs(ctr.items) do T.eq(it.p.I_CUSTOMCOLOR, native(0x3FA7D6), "and every item") end
T.eq(RA.proj_get("cfg_comment_color"), tostring(0x3FA7D6), "colour stored in the project")
-- a colour given by hand survives ordinary rebuilds ...
local hand = Mock.items_on(ctr)[1]; hand.p.I_CUSTOMCOLOR = native(0xFF0000)
Mock.move_marker(Mock.marker_named("Q 2 Storm"), 61); settle(app)
T.eq(hand.p.I_CUSTOMCOLOR, native(0xFF0000), "hand-coloured item untouched by a content rebuild")
app:rebuild_comments(); settle(app); T.eq(hand.p.I_CUSTOMCOLOR, native(0xFF0000), "also by Rebuild now")
-- ... and across restarting the script, but a new pick overrides it
local again = App.new(); settle(again)
T.eq(again.cfg.comment_color, 0x3FA7D6, "colour comes back with the project"); T.eq(hand.p.I_CUSTOMCOLOR, native(0xFF0000), "hand colour survives a restart")
app = again
app:set_comment_color(0x59CD90); settle(app)
T.eq(hand.p.I_CUSTOMCOLOR, native(0x59CD90), "picking a colour recolours every item, hand-coloured ones too")
-- picking while colouring is off turns it on
app:set("comment_color_on", false); settle(app)
T.eq(ctr.vals.I_CUSTOMCOLOR, 0, "off: track back to the default colour"); for _, it in ipairs(ctr.items) do T.eq(it.p.I_CUSTOMCOLOR, 0, "off: item default colour") end
app:set_comment_color(0xEE6352); settle(app)
T.eq(app.cfg.comment_color_on, true, "picking a colour switches colouring on"); T.eq(ctr.vals.I_CUSTOMCOLOR, native(0xEE6352), "and applies it")
app:set_comment_color(0); settle(app); T.eq(ctr.vals.I_CUSTOMCOLOR, 0, "pure black means no custom colour")
app:set_comment_color(0x59CD90 + 0x1000000); T.eq(app.cfg.comment_color, 0xFFFFFF, "out-of-range values are clamped"); settle(app)
app:set_comment_color(0x8542FA); settle(app)
-- a recreated track gets the colour again, even though the colour setting did not change
app:set("comment_off", "delete"); app:set("comments", false); settle(app); app:set("comment_off", "hide"); app:set("comments", true); settle(app)
local ctr2 = Mock.track_named("Cues"); T.eq(ctr2.vals.I_CUSTOMCOLOR, native(0x8542FA), "recreated track is coloured")
for _, it in ipairs(ctr2.items) do T.eq(it.p.I_CUSTOMCOLOR, native(0x8542FA), "recreated items are coloured") end
-- colour change while the comment track is off waits until it is switched on
app:set("comments", false); settle(app); app:set_comment_color(0x5ED1C4); settle(app)
T.eq(ctr2.vals.I_CUSTOMCOLOR, native(0x8542FA), "off: nothing is touched by a colour change")
app:set("comments", true); settle(app); T.eq(ctr2.vals.I_CUSTOMCOLOR, native(0x5ED1C4), "switched on: the new colour is applied")
-- frozen: no colour writes
app:set("live", false); app:set_comment_color(0xB38CF8); settle(app)
T.eq(ctr2.vals.I_CUSTOMCOLOR, native(0x5ED1C4), "frozen: colour not written"); app:set("live", true); settle(app)
T.eq(ctr2.vals.I_CUSTOMCOLOR, native(0xB38CF8), "live again: colour written")
app:set_comment_color(0x8542FA); settle(app)
tr = ctr2

---------------------------------------------------------------------------------------------------------- undo modes
S.undo = {}
Mock.move_marker(Mock.marker_named("Q 1 Opening"), 6); settle(app)
T.eq(#S.undo, 0, "silent mode: syncs add no undo points")
app:set("undo_mode", "steps")
Mock.move_marker(Mock.marker_named("Q 1 Opening"), 7); settle(app)
T.eq(count_undo("CreateScriptTrack: sync"), 1, "steps mode: one undo point for a changing sync")
settle(app); T.eq(count_undo("CreateScriptTrack: sync"), 1, "nothing changed: no further point")
-- a re-parse that changes nothing must not create an undo point or dirty the project
local pts, d0 = count_undo("CreateScriptTrack: sync"), S.dirty
app:set("min_level", 1); settle(app)
T.eq(count_undo("CreateScriptTrack: sync"), pts, "steps mode: an identical rebuild is not an undo point")
-- a track the user hid on purpose stays hidden while only the content changes
Mock.track_named("Cues").vals.B_SHOWINTCP = 0
Mock.move_marker(Mock.marker_named("Q 1 Opening"), 8); settle(app)
T.eq(Mock.track_named("Cues").vals.B_SHOWINTCP, 0, "a track you hid yourself is not shown again by a content change")
Mock.track_named("Cues").vals.B_SHOWINTCP = 1
app:set("undo_mode", "silent")

---------------------------------------------------------------------------------------------------------- frozen
app:set("live", false)
Mock.rename_marker(Mock.marker_named("Q 1 Opening"), "Q 1 hand-typed")
Mock.write(FILE, (MD1:gsub("Walk%-on", "Entrance"))); app:sync_now(); settle(app)
T.ok(Mock.marker_named("Q 1 hand-typed") ~= nil, "frozen: markers are not renamed")
T.eq(app.row_by_id["1.1"].cue.title, "Entrance", "frozen: the view still follows the file")
local pre = #Mock.items_on(Mock.track_named("Cues"))
Mock.move_marker(Mock.marker_named("Q 2 Storm"), 99); settle(app)
T.eq(Mock.items_on(Mock.track_named("Cues"))[3].p.D_POSITION ~= 99, true, "frozen: comment items are not touched")
app:set("live", true); settle(app)
T.ok(Mock.marker_named("Q 1 Opening") ~= nil, "live again: marker renamed"); T.eq(Mock.items_on(Mock.track_named("Cues"))[3].p.D_POSITION, 99, "live again: comment items follow")
Mock.write(FILE, MD1); app:sync_now(); settle(app)

---------------------------------------------------------------------------------------------------------- prefix change keeps the mapping
local ncues = app:counts().mapped
app:change_prefix("SC"); settle(app)
T.eq(app.cfg.prefix, "SC", "prefix stored")
T.eq(#app.doc.cues, 0, "the .md headers still say Q, so no cues match SC")
Mock.write(FILE, (MD1:gsub("Q ", "SC "))); app:sync_now(); settle(app)
T.eq(#app.doc.cues, 3, "after the .md uses the new prefix the cues are back")
app:change_prefix("Q"); Mock.write(FILE, MD1); app:sync_now(); settle(app)
T.eq(app:counts().mapped, ncues, "mapping survives a round trip of prefixes")
local pm = Mock.marker_named("Q 1 Opening"); T.ok(pm ~= nil, "markers carry the prefix again")

---------------------------------------------------------------------------------------------------------- sync modes
app:set("sync_mode", "manual")
Mock.write(FILE, (MD1:gsub("Lights fade up", "Lights SNAP up")))
settle(app); Mock.tick(2); settle(app)
T.eq(app.status, "changed", "manual: a changed file is only reported")
T.ok(not app.text:find("SNAP", 1, true), "manual: working copy unchanged")
app:pull(); T.ok(app.text:find("SNAP", 1, true) ~= nil, "pull adopts the file"); T.eq(app.status, "manual", "in sync again")
Mock.write(FILE, (MD1:gsub("Lights fade up", "Lights DIM up"))); Mock.tick(2); settle(app); Mock.tick(2); settle(app)
T.eq(app.status, "changed", "changed again"); app:keep(); settle(app)
T.eq(app.status, "manual", "keep: stops asking about this version"); T.ok(app.text:find("SNAP", 1, true) ~= nil, "keep: project copy stays")
Mock.write(FILE, (MD1:gsub("Lights fade up", "Lights OTHER up"))); Mock.tick(2); settle(app); Mock.tick(2); settle(app)
T.eq(app.status, "changed", "a further change asks again")
app:set("sync_mode", "local"); Mock.tick(2); settle(app)
T.eq(app.status, "local", "local mode: the file is ignored"); T.ok(app.text:find("SNAP", 1, true) ~= nil, "local copy used")
app:sync_now(); T.ok(app.text:find("OTHER", 1, true) ~= nil, "Sync now pulls even in local mode")
app:set("sync_mode", "source"); Mock.write(FILE, MD1); Mock.tick(2); settle(app); Mock.tick(2); settle(app)
T.eq(app.status, "live", "source mode: live again"); T.ok(app.text == MD1, "source wins")

---------------------------------------------------------------------------------------------------------- missing file, detach, reopen
os.remove(FILE); Mock.tick(2); settle(app); Mock.tick(2); settle(app)
T.eq(app.status, "missing", "deleted file: status missing"); T.eq(#app.doc.cues, 3, "cues still come from the local copy")
local reopened = App.new(); settle(reopened)
T.eq(reopened.status, "missing", "reopening the project with the file gone"); T.eq(#reopened.doc.cues, 3, "the project still works from its stored copy")
T.eq(reopened.cfg.prefix, "Q", "settings come back with the project"); T.eq(reopened.cfg.comments, true, "comment setting too")
T.eq(reopened.path, FILE, "path remembered")
reopened:detach(); T.eq(reopened.status, "local", "detached: local copy only"); T.eq(RA.proj_get("src_path"), "", "link removed from the project")
T.eq(#reopened.doc.cues, 3, "detaching keeps the cues")
Mock.write(FILE, MD1)
T.ok(reopened:set_file(FILE), "relink"); T.eq(reopened.status, "live", "live again")
app = reopened

-- opening a project whose file changed while it was closed
Mock.write(FILE, (MD1:gsub("Storm", "Hurricane")))
local re2 = App.new(); settle(re2)
T.eq(re2.status, "live", "source wins on open"); T.eq(re2.row_by_id["2"].cue.title, "Hurricane", "newer file content loaded")
app = re2
Mock.write(FILE, MD1); app:sync_now(); settle(app)
-- manual mode on open
app:set("sync_mode", "manual")
Mock.write(FILE, (MD1:gsub("Storm", "Gale")))
local re3 = App.new(); T.eq(re3.status, "changed", "manual mode on open: asks"); T.eq(re3.row_by_id and re3.doc.cues[3].title, "Storm", "stored copy used until pulled")
Mock.write(FILE, MD1); app:set("sync_mode", "source")

---------------------------------------------------------------------------------------------------------- big text, damaged copy, project switch
local big = {}
for i = 1, 400 do big[#big + 1] = string.format("## Q %d Cue number %d\nLine one of %d\nLine two \\ with a backslash\n", i, i, i) end
local bigtext = table.concat(big)
RA.save_local(bigtext)
T.eq(RA.load_local(), bigtext, "a 20 KB text survives the chunked project storage")
RA.save_local("short")
T.eq(RA.load_local(), "short", "shrinking removes stale chunks"); T.eq(RA.proj_get("local_5"), "", "old chunk deleted")
RA.save_local(""); T.eq(RA.load_local(), "", "empty text round trip")
RA.save_local("good"); S.proj_ext["CreateScriptTrack"]["local_0"] = "|goop"
local t, why = RA.load_local(); T.eq(t, nil, "damaged copy not used"); T.eq(why, "damaged", "and reported")
local dmg = App.new(); T.ok(dmg.msg and dmg.msg:find("damaged", 1, true), "app tells the user")

RA.save_local(MD1); RA.proj_set("src_path", FILE)
app = App.new(); settle(app)
local saved = {}
for k, v in pairs(S.proj_ext["CreateScriptTrack"]) do saved[k] = v end
S.proj_ext = {}; S.proj = "proj2"; S.markers = {}; settle(app)
T.eq(app.path, "", "other project tab: its own (empty) state"); T.eq(#app.doc.cues, 0, "no cues from the other project")
S.proj_ext = { CreateScriptTrack = saved }; S.proj = "proj1"; settle(app)
T.eq(#app.doc.cues, 3, "back to the first project: state restored")

---------------------------------------------------------------------------------------------------------- projects saved by the old name
if RA.LEGACY.section ~= RA.SECTION then
  Mock.write(FILE, MD1)
  local LS = RA.LEGACY.section
  local function key(tag) return tag:match("^P_EXT:(.+)$") end
  S.proj_ext = { [LS] = { src_path = FILE, local_n = "1", local_hash = C.hash(MD1), local_0 = "|" .. C.escape(MD1),
                          cfg_prefix = "Q", cfg_comments = "1", cfg_comment_lines = "3" } }
  S.tracks, S.markers = {}, {}
  local old_tr = Mock.track("Cues"); old_tr.ext[key(RA.LEGACY.track_tag)] = "1"
  local mine = Mock.track("Drums")
  for i, id in ipairs({ "1", "1.1", "2" }) do
    local it = reaper.AddMediaItemToTrack(old_tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", i * 10); reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 5)
    reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "old text", true)
    it.ext[key(RA.LEGACY.item_tag)] = id
  end
  Mock.marker(10, "Q 1 Opening"); Mock.marker(20, "Q 1.1 Walk-on"); Mock.marker(30, "Q 2 Storm")
  local mig = App.new(); settle(mig)
  T.ok(mig.msg and mig.msg:find("Imported", 1, true), "the user is told that old data was imported")
  T.eq(mig.cfg.prefix, "Q", "old settings moved"); T.eq(mig.cfg.comment_lines, 3, "numbers too"); T.eq(mig.cfg.comments, true, "booleans too")
  T.eq(mig.path, FILE, "old file link moved"); T.eq(#mig.doc.cues, 3, "old local copy moved")
  T.eq(RA.proj_get("src_path"), FILE, "now stored under the current name"); T.eq(S.proj_ext[LS], nil, "old section removed")
  local n_cues = 0 for _, t in ipairs(S.tracks) do if t.ext[key(RA.TRACK_TAG)] == "1" or t.ext[key(RA.LEGACY.track_tag)] == "1" then n_cues = n_cues + 1 end end
  T.eq(n_cues, 1, "the old comment track is reused: no second one")
  T.eq(old_tr.ext[key(RA.TRACK_TAG)], "1", "its tag is upgraded"); T.eq(old_tr.ext[key(RA.LEGACY.track_tag)], nil, "old tag removed")
  T.eq(#old_tr.items, 3, "its items are reused, none duplicated")
  for _, it in ipairs(old_tr.items) do T.ok(it.ext[key(RA.ITEM_TAG)] ~= nil and it.ext[key(RA.LEGACY.item_tag)] == nil, "item tag upgraded") end
  T.ok(Mock.items_on(old_tr)[1].notes:find("Lights fade up.", 1, true) ~= nil, "item text rewritten from the cue sheet")
  T.eq(#mine.items, 0, "other tracks untouched")
  -- a second start does not migrate again, and an already-current project is left alone
  local again = App.new(); settle(again); T.eq(again.msg, nil, "no migration message the second time")
  RA.proj_set("src_path", ""); RA.proj_set("local_n", "")
  S.proj_ext[LS] = { src_path = "/other.md" }
  local blank = App.new(); T.eq(blank.path, "/other.md", "old data fills an empty project once")
  RA.proj_set("src_path", FILE); S.proj_ext[LS] = { src_path = "/stale.md" }
  local keep = App.new(); T.eq(keep.path, FILE, "current data is never overwritten by old data")
end

os.remove(FILE)
T.done("test_sync")
