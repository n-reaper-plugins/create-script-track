-- CSTReaper.lua
-- Every reaper.* call of CreateScriptTrack lives here (except the window itself, see CSTUI). Plain tables in, plain tables out.
-- Identity never depends on track or item names: the comment track and its items carry P_EXT tags.

local r = reaper
local C = require("CSTCore")

local RA = {}

local SEC = "CreateScriptTrack"                    -- project ext-state section
RA.SECTION = SEC
RA.TRACK_TAG = "P_EXT:CST_comments"          -- track: "1" = our comment track
RA.ITEM_TAG  = "P_EXT:CST_cue"               -- item: the cue id it shows

-- What version 0.1.0 called itself, before the rename. Projects saved with it still carry these names, so they are read once
-- and moved to the current ones. tools/rename.lua leaves lines marked "legacy:keep" alone.
RA.LEGACY = {
  section   = "ReaQScript",                 -- legacy:keep
  track_tag = "P_EXT:RQ_comments",          -- legacy:keep
  item_tag  = "P_EXT:RQ_cue",               -- legacy:keep
}
local HAS_LEGACY = RA.LEGACY.section ~= SEC

---------------------------------------------------------------------------------------------------------- project storage
function RA.proj_get(key)
  local n, v = r.GetProjExtState(0, SEC, key)
  if n and n > 0 then return v end
  return ""
end

-- an empty value deletes the key
function RA.proj_set(key, v) r.SetProjExtState(0, SEC, key, v or "") end

-- Moves what the old name stored in this project (cue sheet link, local copy, settings) to the current section, once.
-- Only when the current section is still empty. `keys` = the settings keys to look for. Returns true if something moved.
function RA.migrate_legacy(keys)
  if not HAS_LEGACY then return false end
  if RA.proj_get("src_path") ~= "" or RA.proj_get("local_n") ~= "" then return false end
  local L = RA.LEGACY.section
  local function get(k) local n, v = r.GetProjExtState(0, L, k); if n and n > 0 then return v end return "" end
  local names = { "src_path", "local_n", "local_hash" }
  local n = tonumber(get("local_n")) or 0
  for i = 0, n - 1 do names[#names + 1] = "local_" .. i end
  for _, k in ipairs(keys or {}) do names[#names + 1] = "cfg_" .. k end
  local moved = 0
  for _, k in ipairs(names) do
    local v = get(k)
    if v ~= "" then RA.proj_set(k, v); moved = moved + 1 end
  end
  if moved > 0 then r.SetProjExtState(0, L, "", "") end      -- an empty key removes the whole old section
  return moved > 0
end

-- the local copy of the Markdown text: escaped, chunked, with a hash to detect a damaged copy
function RA.save_local(text)
  local old_n = tonumber(RA.proj_get("local_n")) or 0
  local parts = C.chunks(C.escape(text), 4000)
  -- every chunk gets a leading "|": an empty value would delete the key, and edge whitespace might be trimmed
  for i, p in ipairs(parts) do RA.proj_set("local_" .. (i - 1), "|" .. p) end
  for i = #parts, old_n - 1 do RA.proj_set("local_" .. i, "") end
  RA.proj_set("local_n", tostring(#parts))
  RA.proj_set("local_hash", C.hash(text))
end

-- returns text, or nil (nothing stored), or nil + "damaged"
function RA.load_local()
  local n = tonumber(RA.proj_get("local_n"))
  if not n or n < 1 then return nil end
  local parts = {}
  for i = 0, n - 1 do parts[#parts + 1] = RA.proj_get("local_" .. i):sub(2) end
  local text = C.unescape(table.concat(parts))
  if C.hash(text) ~= RA.proj_get("local_hash") then return nil, "damaged" end
  return text
end

function RA.clear_local()
  local n = tonumber(RA.proj_get("local_n")) or 0
  for i = 0, n - 1 do RA.proj_set("local_" .. i, "") end
  RA.proj_set("local_n", ""); RA.proj_set("local_hash", "")
end

---------------------------------------------------------------------------------------------------------- the .md file
function RA.read_file(path)
  if not path or path == "" then return nil, "no file" end
  local f, err = io.open(path, "rb")
  if not f then return nil, err or "cannot open" end
  local s = f:read("a")
  f:close()
  if not s then return nil, "cannot read" end
  return (s:gsub("^\xEF\xBB\xBF", ""))
end

-- native "open file" dialog; nil if cancelled
function RA.pick_file(start)
  if r.JS_Dialog_BrowseForOpenFiles then
    local ok, f = r.JS_Dialog_BrowseForOpenFiles("Choose the Markdown cue sheet", start or "", "", "Markdown (*.md;*.markdown;*.txt)\0*.md;*.markdown;*.txt\0All files (*.*)\0*.*\0", false)
    if ok == 1 and f and f ~= "" then return f end
    return nil
  end
  local ok, f = r.GetUserFileNameForRead(start or "", "Choose the Markdown cue sheet", "md")
  if ok and f and f ~= "" then return f end
  return nil
end

function RA.open_external(path)
  if r.CF_ShellExecute then r.CF_ShellExecute(path); return true end
  return false
end

---------------------------------------------------------------------------------------------------------- project / transport
function RA.proj_id() local p = r.EnumProjects(-1); return p end
function RA.change_count() return r.GetProjectStateChangeCount(0) end
function RA.cursor() return r.GetCursorPosition() end
function RA.playing() return (r.GetPlayState() & 1) == 1 end
function RA.play_pos() return r.GetPlayPosition2() end
function RA.set_cursor(t, seek) r.SetEditCurPos(t, true, seek and true or false) end

-- true while a mouse button is held (js_ReaScriptAPI only; without it the debounce alone applies)
function RA.mouse_down()
  if r.JS_Mouse_GetState then return (r.JS_Mouse_GetState(1) & 1) == 1 end
  return false
end

function RA.undo_begin() r.Undo_BeginBlock2(0) end
function RA.undo_end(label) r.Undo_EndBlock2(0, label, -1) end

-- 0xRRGGBB -> REAPER's native colour value. nil or 0 (pure black) = no custom colour, i.e. REAPER's default.
local function color(c)
  if not c or c == 0 then return 0 end
  return r.ColorToNative(c >> 16 & 0xFF, c >> 8 & 0xFF, c & 0xFF) | 0x1000000
end
RA.color = color

---------------------------------------------------------------------------------------------------------- markers
-- plain project markers (no regions), in timeline order
function RA.markers()
  local out, i = {}, 0
  while true do
    local ret, isrgn, pos, _, name, idx, col = r.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn then out[#out + 1] = { enum = i, pos = pos, name = name, idx = idx, color = col } end
    i = i + 1
  end
  table.sort(out, function(a, b) if a.pos ~= b.pos then return a.pos < b.pos end return a.enum < b.enum end)
  return out
end

function RA.add_marker(pos, name, rgb) return r.AddProjectMarker2(0, false, pos, 0, name, -1, color(rgb)) end
function RA.move_marker(m, pos, name) return r.SetProjectMarker4(0, m.idx, false, pos, 0, name or m.name, m.color, 0) end
function RA.delete_marker(m) return r.DeleteProjectMarker(0, m.idx, false) end

---------------------------------------------------------------------------------------------------------- comment track
local function tstr(tr, k) local ok, v = r.GetSetMediaTrackInfo_String(tr, k, "", false); return ok and v or "" end
local function istr(it, k) local ok, v = r.GetSetMediaItemInfo_String(it, k, "", false); return ok and v or "" end

-- returns the track, and true when it still carries the old name's tag (see RA.upgrade_track)
function RA.find_comment_track()
  local old
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if tstr(tr, RA.TRACK_TAG) == "1" then return tr, false end
    if HAS_LEGACY and not old and tstr(tr, RA.LEGACY.track_tag) == "1" then old = tr end
  end
  return old, old ~= nil
end

function RA.upgrade_track(tr)
  r.GetSetMediaTrackInfo_String(tr, RA.TRACK_TAG, "1", true)
  r.GetSetMediaTrackInfo_String(tr, RA.LEGACY.track_tag, "", true)
end

-- finds our track or creates it as the first track
function RA.ensure_comment_track(name)
  local tr = RA.find_comment_track()
  if tr then return tr, false end
  r.InsertTrackAtIndex(0, true)
  tr = r.GetTrack(0, 0)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  r.GetSetMediaTrackInfo_String(tr, RA.TRACK_TAG, "1", true)
  return tr, true
end

function RA.comment_track_visible(tr) return r.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP") == 1 end

function RA.show_comment_track(tr, show)
  local v = show and 1 or 0
  r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", v)
  r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", v)
end

function RA.set_track_color(tr, rgb) r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", color(rgb)) end

function RA.delete_comment_track(tr) r.DeleteTrack(tr) end

-- our items on the track: { [cue id] = { ptr, pos, len, notes } }, plus a list of strays (tagged items we no longer want)
local function our_items(tr)
  local by_id, list = {}, {}
  for j = 0, r.CountTrackMediaItems(tr) - 1 do
    local it = r.GetTrackMediaItem(tr, j)
    local id, old = istr(it, RA.ITEM_TAG), false
    if id == "" and HAS_LEGACY then id = istr(it, RA.LEGACY.item_tag); old = id ~= "" end
    if id ~= "" then
      local rec = { ptr = it, id = id, old = old, pos = r.GetMediaItemInfo_Value(it, "D_POSITION"), len = r.GetMediaItemInfo_Value(it, "D_LENGTH"),
                    notes = istr(it, "P_NOTES"), color = r.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR") }
      list[#list + 1] = rec
      if not by_id[id] then by_id[id] = rec end
    end
  end
  return by_id, list
end

function RA.comment_item_count(tr)
  local _, list = our_items(tr)
  return #list
end

-- wanted = { { id, pos, len, text, rgb } ... }. Only items carrying our tag are created, changed or deleted.
-- `touch` (optional) is called once before the first write, so the caller can open an undo block only when needed.
-- Colour: new items always get x.rgb. Existing items are only recoloured when `recolor` is set (the colour setting changed),
-- so a colour you gave one item by hand survives ordinary rebuilds.
-- Returns { created, updated, deleted }.
function RA.set_comment_items(tr, wanted, touch, recolor)
  local stats = { created = 0, updated = 0, deleted = 0 }
  local by_id, list = our_items(tr)
  local keep = {}
  local function w() if touch then touch(); touch = nil end end
  for _, x in ipairs(wanted) do
    local rec = by_id[x.id]
    local it = rec and rec.ptr
    local fresh = false
    if not it then
      w()
      it = r.AddMediaItemToTrack(tr)
      r.GetSetMediaItemInfo_String(it, RA.ITEM_TAG, x.id, true)
      fresh = true
    end
    keep[it] = true
    if rec and rec.old then      -- tagged by the old name: carry the tag over
      w()
      r.GetSetMediaItemInfo_String(it, RA.ITEM_TAG, rec.id, true)
      r.GetSetMediaItemInfo_String(it, RA.LEGACY.item_tag, "", true)
    end
    local changed = fresh
    if fresh or math.abs(rec.pos - x.pos) > 1e-9 then w(); r.SetMediaItemInfo_Value(it, "D_POSITION", x.pos); changed = true end
    if fresh or math.abs(rec.len - x.len) > 1e-9 then w(); r.SetMediaItemInfo_Value(it, "D_LENGTH", x.len); changed = true end
    if fresh or rec.notes ~= x.text then w(); r.GetSetMediaItemInfo_String(it, "P_NOTES", x.text, true); changed = true end
    local c = color(x.rgb)
    if fresh then
      if c ~= 0 then r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", c) end
      stats.created = stats.created + 1
    else
      if recolor and rec.color ~= c then w(); r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", c); changed = true end
      if changed then stats.updated = stats.updated + 1 end
    end
  end
  for _, rec in ipairs(list) do
    if not keep[rec.ptr] then w(); r.DeleteTrackMediaItem(tr, rec.ptr); stats.deleted = stats.deleted + 1 end
  end
  return stats
end

---------------------------------------------------------------------------------------------------------- misc
function RA.refresh() r.UpdateArrange() end
function RA.dirty() r.MarkProjectDirty(0) end
function RA.hold(on) r.PreventUIRefresh(on and 1 or -1) end

return RA
