-- @description CreateScriptTrack: a Markdown cue sheet that follows the REAPER timeline (cue markers, live preview, comment track)
-- @version 0.1.1
-- @author _n_plugins
-- @about
--   Link a Markdown file whose headers are cue numbers (Q 1, Q 1.2, Q 1.2.3 ... the prefix is yours to set). The cues are
--   mapped to project markers; the preview scrolls to the cue under the playhead or edit cursor; an optional comment track
--   carries the first lines of every cue as text items. The file is also stored inside the project, so it still works when
--   the file moves. Needs ReaImGui (ReaPack > ReaTeam Extensions). Run the action again while the window is open to close it.
-- BUNDLED BUILD of CreateScriptTrack v0.1.1 - edit the files in src/, not this one.
local __preload = package.preload
__preload["CSTVersion"] = function(...)
return { VERSION = "0.1.1" }

end
__preload["CSTCore"] = function(...)
-- CSTCore.lua
-- Pure logic, no reaper.* calls (so it is fully testable offline): cue header parsing, cue ids, local-copy encoding,
-- Markdown blocks for the preview, current-cue lookup, comment text.

local C = {}

---------------------------------------------------------------------------------------------------------- hash / storage
-- FNV-1a, 32 bit. Only used to check that the stored local copy is intact.
function C.hash(s)
  local h = 0x811C9DC5
  for i = 1, #s do h = ((h ~ s:byte(i)) * 0x01000193) & 0xFFFFFFFF end
  return string.format("%08x", h)
end

-- project ext-state values are single lines: escape backslash and line breaks
function C.escape(s) return (s:gsub("[\\\r\n]", { ["\\"] = "\\\\", ["\r"] = "\\r", ["\n"] = "\\n" })) end
function C.unescape(s) return (s:gsub("\\([\\rn])", { ["\\"] = "\\", r = "\r", n = "\n" })) end

function C.chunks(s, size)
  size = size or 4000
  local out = {}
  for i = 1, #s, size do out[#out + 1] = s:sub(i, i + size - 1) end
  if #out == 0 then out[1] = "" end
  return out
end

---------------------------------------------------------------------------------------------------------- cue ids
-- "1", "1.2", "1.2.3": digits separated by single dots. What follows must be the end, a space or a separator,
-- so "1abc" is not an id. More than 8 segments is not an id either.
local MAX_SEGS = 8

local function parse_id(s)
  local i, segs = 1, {}
  while #segs < MAX_SEGS do
    local d = s:match("^%d+", i)
    if not d or #d > 6 then break end
    segs[#segs + 1] = d
    i = i + #d
    if s:sub(i, i) == "." and s:sub(i + 1, i + 1):match("%d") then i = i + 1 else break end
  end
  if #segs == 0 then return nil end
  local rest = s:sub(i)
  if rest ~= "" and not rest:match("^[%s:%-%.%)%]]") and not rest:match("^\xE2\x80[\x93\x94]") then return nil end
  return table.concat(segs, "."), rest
end

local function strip_sep(s)
  while true do
    local n = s:gsub("^[%s:%-%.%)%]]+", "")
    n = n:gsub("^\xE2\x80[\x93\x94]", "")
    if n == s then return s end
    s = n
  end
end

-- text = a header's text or a marker's name. Returns id, title or nil.
function C.match_cue_text(text, prefix)
  prefix = prefix or ""
  local s = text
  if prefix ~= "" then
    if s:sub(1, #prefix):lower() ~= prefix:lower() then return nil end
    s = s:sub(#prefix + 1):gsub("^%s+", "")
  end
  local id, rest = parse_id(s)
  if not id then return nil end
  return id, (strip_sep(rest):gsub("%s+$", ""))
end

-- numeric, segment by segment: 1.2 < 1.10 < 2
function C.id_cmp(a, b)
  local ia, ib = {}, {}
  for n in a:gmatch("%d+") do ia[#ia + 1] = tonumber(n) end
  for n in b:gmatch("%d+") do ib[#ib + 1] = tonumber(n) end
  for i = 1, math.max(#ia, #ib) do
    local x, y = ia[i] or -1, ib[i] or -1
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

-- the marker name for a cue: "<prefix> <id> <title>"
function C.marker_name(prefix, cue)
  prefix = prefix or ""
  local p = prefix
  if p ~= "" and not p:match("%s$") then p = p .. " " end
  local name = p .. cue.id
  if cue.title ~= "" then name = name .. " " .. cue.title end
  return name
end

---------------------------------------------------------------------------------------------------------- Markdown
-- level, text of an ATX header line, or nil
function C.header(line)
  local h, t = line:match("^%s?%s?%s?(#+)[ \t]+(.-)%s*$")
  if not h or #h > 6 then return nil end
  t = t:gsub("%s+#+$", "")
  if t == "" then return nil end
  return #h, t
end

local function fence_of(line) return line:match("^%s*([`~][`~][`~]+)") end

-- doc = { lines, cues, cue_at_line, dups }
--   cue = { id, title, level, line, last, body = {lines}, dup, n }
-- opts: prefix ("" = bare numbers), min_level, max_level
function C.parse(text, opts)
  opts = opts or {}
  local prefix, lo, hi = opts.prefix or "", opts.min_level or 1, opts.max_level or 6
  text = (text or ""):gsub("^\xEF\xBB\xBF", "")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then lines[#lines] = nil end

  local heads, fence = {}, nil
  for i, line in ipairs(lines) do
    local f = fence_of(line)
    if fence then
      if f and f:sub(1, 1) == fence then fence = nil end
    elseif f then
      fence = f:sub(1, 1)
    else
      local level, t = C.header(line)
      if level and level >= lo and level <= hi then
        local id, title = C.match_cue_text(t, prefix)
        if id then heads[#heads + 1] = { line = i, level = level, id = id, title = title } end
      end
    end
  end

  local cues, seen, cue_at_line, dups = {}, {}, {}, 0
  for k, h in ipairs(heads) do
    local last = heads[k + 1] and heads[k + 1].line - 1 or #lines
    while last > h.line and lines[last]:match("^%s*$") do last = last - 1 end
    local body = {}
    for i = h.line + 1, last do body[#body + 1] = lines[i] end
    local dup = seen[h.id] ~= nil
    if dup then dups = dups + 1 end
    seen[h.id] = true
    cues[k] = { id = h.id, title = h.title, level = h.level, line = h.line, last = last, body = body, dup = dup, n = k }
    cue_at_line[h.line] = k
  end
  return { lines = lines, cues = cues, cue_at_line = cue_at_line, dups = dups }
end

-- strips the inline markers we cannot style: links, **bold**, `code`, *italic*
function C.inline(s)
  s = s:gsub("%[([^%]]+)%]%([^%)]*%)", "%1")
  s = s:gsub("%*%*(.-)%*%*", "%1")
  s = s:gsub("`([^`]+)`", "%1")
  s = s:gsub("^%*([^%s*][^*]-)%*", "%1")                      -- *italic*, only where it starts a word
  s = s:gsub("([%s%(%[])%*([^%s*][^*]-)%*", "%1%2")
  return s
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function is_rule(line)
  return line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") or line:match("^%s*___+%s*$")
end

-- blocks for the preview: { kind = h|p|li|task|code|quote|hr|blank, text, level, indent, checked, line, owner, cue }
--   owner = index of the cue this block belongs to (nil before the first cue); cue = set on a cue's own header
function C.blocks(doc)
  local B, fence, para, owner = {}, nil, nil, nil
  local function add(b) b.owner = owner; B[#B + 1] = b; return b end
  local function flush() if para then B[#B + 1] = para; para = nil end end
  for i, line in ipairs(doc.lines) do
    local ci = doc.cue_at_line[i]
    local f = fence_of(line)
    if fence then
      if f and f:sub(1, 1) == fence then fence = nil else add({ kind = "code", text = line, line = i }) end
    elseif f then
      flush(); fence = f:sub(1, 1)
    elseif line:match("^%s*$") then
      flush(); add({ kind = "blank", line = i })
    else
      local level, t = C.header(line)
      if level then
        flush()
        if ci then owner = ci end
        add({ kind = "h", level = level, text = t, line = i, cue = ci })
      elseif is_rule(line) then
        flush(); add({ kind = "hr", line = i })
      else
        local ind, chk, txt = line:match("^(%s*)[-*+]%s+%[([ xX])%]%s+(.*)$")
        local ind2, txt2 = line:match("^(%s*)[-*+]%s+(.*)$")
        local ind3, num, txt3 = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
        if ind then
          flush(); add({ kind = "task", text = txt, indent = #ind, checked = chk ~= " ", line = i })
        elseif ind2 then
          flush(); add({ kind = "li", text = txt2, indent = #ind2, line = i })
        elseif ind3 then
          flush(); add({ kind = "li", text = txt3, indent = #ind3, marker = num .. ".", line = i })
        elseif line:match("^%s*>") then
          flush(); add({ kind = "quote", text = trim((line:gsub("^%s*>%s?", ""))), line = i })
        elseif para then
          para.text = para.text .. " " .. trim(line)
        else
          para = { kind = "p", text = trim(line), line = i, owner = owner }
        end
      end
    end
  end
  flush()
  return B
end

---------------------------------------------------------------------------------------------------------- timeline
-- timed = { { t = seconds, ... }, ... } sorted by t. Index of the last entry at or before pos (nil before the first).
function C.current(timed, pos)
  local best
  for i, e in ipairs(timed) do
    if e.t <= pos + 1e-6 then best = i else break end
  end
  return best
end

-- text of a comment item: optional title line, then the first n non-empty body lines
function C.comment_text(cue, n, with_title, prefix)
  local out = {}
  if with_title then out[1] = C.marker_name(prefix, cue) end
  local got = 0
  for _, line in ipairs(cue.body) do
    if got >= n then break end
    local s = trim(line)
    if s ~= "" and not fence_of(s) then
      s = s:gsub("^#+%s*", "")
      out[#out + 1] = s
      got = got + 1
    end
  end
  return table.concat(out, "\n")
end

function C.fmt_clock(t)
  local m = math.floor(t / 60)
  return string.format("%d:%06.3f", m, t - m * 60)
end

return C

end
__preload["CSTReaper"] = function(...)
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

end
__preload["CSTApp"] = function(...)
-- CSTApp.lua
-- State, per-project settings, the debounced tick, file sync and the sync engine.
-- Reads the project through CSTReaper, decides with CSTCore.
--
-- One sync (every 0.3 s after the project stops changing, never while the mouse button is down):
--   1. scan markers -> map them to cues (mapped / unmapped / duplicate) and find orphan markers
--   2. rename mapped markers to "<prefix> <id> <title>" (setting)
--   3. comment track: create / update / delete our items, or hide / delete the track when switched off
-- Every tick also follows the playhead or edit cursor to find the current cue (cheap: a few getters, no scan).

local r = reaper
local C = require("CSTCore")
local RA = require("CSTReaper")

local App = {}
App.__index = App

local DEBOUNCE = 0.3
local POLL = 1.0                     -- seconds between looks at the .md file
local MARKER_RGB = 0x8542FA          -- 262 deg accent
local MIN_ITEM = 0.1                 -- shortest comment item (cues at the same time)

App.DEFAULTS = {
  live = true,                -- write markers / comment items. Off = look only.
  prefix = "",                -- "" = bare numbers
  min_level = 1, max_level = 6,
  sync_mode = "source",       -- source | manual | local
  follow = "play",            -- play (playhead while playing, else edit cursor) | cursor | off
  rename_markers = true,
  comments = false,
  comment_lines = 2,
  comment_title = true,
  comment_off = "hide",       -- hide | delete the track when switched off
  comment_name = "Cues",
  comment_color_on = true,    -- colour the comment track and its items
  comment_color = 0x8542FA,   -- 0xRRGGBB (default: the 262 deg accent)
  last_len = 8,               -- seconds the last comment item lasts
  undo_mode = "silent",       -- silent | steps
  prompter = false,
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

---------------------------------------------------------------------------------------------------------- project / settings
function App.new()
  local self = setmetatable({}, App)
  self.cfg = {}
  self.proj = RA.proj_id()
  self.seen, self.changed_at, self.pending, self.last_poll = -1, -1e9, true, -1e9
  self:load_project()
  return self
end

-- (re)load everything that belongs to the current project: settings, file link, stored copy
function App:load_project()
  local keys = {}
  for k in pairs(App.DEFAULTS) do keys[#keys + 1] = k end
  local migrated = RA.migrate_legacy(keys)
  for k, d in pairs(App.DEFAULTS) do
    local v = RA.proj_get("cfg_" .. k)
    if v == "" then self.cfg[k] = d
    elseif type(d) == "boolean" then self.cfg[k] = (v == "1")
    elseif type(d) == "number" then self.cfg[k] = tonumber(v) or d
    else self.cfg[k] = v end
  end
  self.path = RA.proj_get("src_path")
  self.text, self.disk, self.ignored = "", nil, nil
  self.status = "none"
  self.msg = migrated and "Imported the cue sheet and settings stored in this project by the earlier version of this script." or nil
  local t, why = RA.load_local()
  self.has_local = t ~= nil
  if t then self.text = t end
  if why == "damaged" then self.msg = "The stored local copy of the cue sheet is damaged." end
  self.rows, self.timed, self.orphans, self.row_by_id = {}, {}, {}, {}
  self.selected, self.cur, self.cur_id, self.want_scroll, self.pos = nil, nil, nil, nil, nil
  self.comment_sig, self.comment_shown = nil, false
  self.color_applied = RA.proj_get("color_applied")      -- the colour the comment track last got, to see when it changes
  self:reparse()
  self:poll_file(false)
  self.last_poll = r.time_precise()
  self.pending, self.changed_at = true, -1e9
end

function App:set(k, v)
  self.cfg[k] = v
  if type(App.DEFAULTS[k]) == "boolean" then RA.proj_set("cfg_" .. k, v and "1" or "0") else RA.proj_set("cfg_" .. k, tostring(v)) end
  if k == "min_level" or k == "max_level" then self:reparse() end
  if k == "sync_mode" then self.ignored = nil; self:poll_file(false) end
  self.pending, self.changed_at = true, -1e9
end

-- Changing the prefix keeps the mapping: markers that matched the old prefix are renamed to the new one first.
function App:change_prefix(new)
  new = trim(new)
  local old = self.cfg.prefix
  if new == old then return end
  local n = 0
  if self.cfg.rename_markers and self.cfg.live then
    local seen = {}
    local opened = false
    for _, m in ipairs(RA.markers()) do
      local id = C.match_cue_text(m.name, old)
      local cue = id and self.by_id[id]
      if cue and not seen[id] then
        seen[id] = true
        if not opened then RA.undo_begin(); opened = true end
        RA.move_marker(m, m.pos, C.marker_name(new, cue))
        n = n + 1
      end
    end
    if opened then RA.undo_end("CreateScriptTrack: change cue prefix"); RA.dirty() end
  end
  self:set("prefix", new)
  self:reparse()
  self.msg = n > 0 and string.format("Prefix changed; %d marker(s) renamed to follow it.", n) or "Prefix changed."
end

---------------------------------------------------------------------------------------------------------- the .md file
function App:reparse()
  self.doc = C.parse(self.text, { prefix = self.cfg.prefix, min_level = self.cfg.min_level, max_level = self.cfg.max_level })
  self.blocks = C.blocks(self.doc)
  self.by_id = {}
  for _, cue in ipairs(self.doc.cues) do if not cue.dup then self.by_id[cue.id] = cue end end
  if self.selected and not self.by_id[self.selected] then self.selected = nil end
  self.comment_sig = nil
end

-- text from the file (or a pasted/typed text) becomes the working copy and is stored in the project
function App:adopt(text)
  self.text, self.has_local, self.ignored = text, true, nil
  RA.save_local(text)
  self:reparse()
  self.pending, self.changed_at = true, -1e9
end

function App:poll_file(force)
  if self.path == "" then
    self.status = (self.text ~= "") and "local" or "none"; self.disk = nil
    return
  end
  local mode = self.cfg.sync_mode
  if mode == "local" and not force then self.status = "local"; return end
  local disk = RA.read_file(self.path)
  if not disk then self.status = "missing"; self.disk = nil; return end
  self.disk = disk
  local synced = (mode == "source") and "live" or "manual"
  if disk == self.text then self.status = synced; return end
  if force or mode == "source" or not self.has_local then
    self:adopt(disk); self.status = synced
  elseif self.ignored == disk then
    self.status = "manual"
  else
    self.status = "changed"
  end
end

function App:set_file(path)
  path = trim((path or ""):gsub('^"(.*)"$', "%1"))
  if path == "" then return false end
  local text, err = RA.read_file(path)
  if not text then self.msg = "Cannot read '" .. path .. "': " .. tostring(err); return false end
  self.path = path
  RA.proj_set("src_path", path)
  self:adopt(text)
  self:poll_file(true)
  self.msg = string.format("Linked %s: %d cue(s).", path:match("([^/\\]+)$") or path, #self.doc.cues)
  return true
end

function App:choose_file()
  local start = self.path ~= "" and (self.path:match("^(.*)[/\\][^/\\]*$") or "") or ""
  local f = RA.pick_file(start)
  if f then return self:set_file(f) end
  return false
end

function App:pull() if self.disk then self:adopt(self.disk); self.status = "manual"; self.msg = "Pulled the file's changes." end end
function App:keep() self.ignored = self.disk; self.status = "manual"; self.msg = "Keeping the project's copy; the file is left as it is." end

function App:detach()
  self.path = ""
  RA.proj_set("src_path", "")
  self.disk, self.ignored = nil, nil
  self:poll_file(false)
  self.msg = "File link removed. The copy stored in the project is still used."
end

function App:sync_now()
  self:poll_file(true)
  self.comment_sig = nil
  self.pending, self.changed_at = true, -1e9
end

function App:open_in_editor()
  if self.path == "" then return false end
  if not RA.open_external(self.path) then self.msg = "Opening files needs the SWS extension (CF_ShellExecute)."; return false end
  return true
end

---------------------------------------------------------------------------------------------------------- scan: markers <-> cues
function App:scan()
  local prefix = self.cfg.prefix
  local by_marker, extra = {}, {}
  for _, m in ipairs(RA.markers()) do
    local id = C.match_cue_text(m.name, prefix)
    if id then
      m.cue_id = id
      if not by_marker[id] then by_marker[id] = m else extra[#extra + 1] = m end
    end
  end
  local rows, timed, row_by_id = {}, {}, {}
  for _, cue in ipairs(self.doc.cues) do
    local row = { cue = cue, id = cue.id }
    if cue.dup then
      row.status = "duplicate"
    else
      local m = by_marker[cue.id]
      if m then row.marker, row.t, row.status = m, m.pos, "mapped"; timed[#timed + 1] = row
      else row.status = "unmapped" end
      row_by_id[cue.id] = row
    end
    rows[#rows + 1] = row
  end
  table.sort(timed, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.cue.n < b.cue.n end)
  local orphans = {}
  for id, m in pairs(by_marker) do
    if not self.by_id[id] then orphans[#orphans + 1] = { marker = m, id = id, why = "no such cue" } end
  end
  for _, m in ipairs(extra) do orphans[#orphans + 1] = { marker = m, id = m.cue_id, why = "second marker for this cue" } end
  table.sort(orphans, function(a, b) return a.marker.pos < b.marker.pos end)
  self.rows, self.timed, self.orphans, self.row_by_id = rows, timed, orphans, row_by_id
end

function App:counts()
  local n = { mapped = 0, unmapped = 0, duplicate = 0, orphans = #self.orphans }
  for _, row in ipairs(self.rows) do n[row.status] = n[row.status] + 1 end
  return n
end

---------------------------------------------------------------------------------------------------------- comment track
-- the colour the comment track and items should have (0xRRGGBB), or nil for REAPER's default
function App:comment_rgb()
  local c = self.cfg.comment_color
  if self.cfg.comment_color_on and c and c ~= 0 then return c end
  return nil
end

function App:set_comment_color(rgb)
  rgb = math.max(0, math.min(0xFFFFFF, math.floor(rgb)))
  self:set("comment_color", rgb)
  if not self.cfg.comment_color_on then self:set("comment_color_on", true) end
end

-- `open` is called before the first write (and not at all when nothing has to change).
function App:sync_comments(open)
  local cfg = self.cfg
  local tr, legacy = RA.find_comment_track()
  if not cfg.comments then
    self.comment_shown = false
    local sig = "off|" .. cfg.comment_off .. "|" .. (tr and "t" or "-")
    if sig == self.comment_sig then return end
    self.comment_sig = sig
    if not tr then return end
    if cfg.comment_off == "delete" then open(); RA.delete_comment_track(tr)
    elseif RA.comment_track_visible(tr) then open(); RA.show_comment_track(tr, false) end
    return
  end

  local rgb = self:comment_rgb()
  local wanted, parts = {}, {}
  for i, e in ipairs(self.timed) do
    local nxt = self.timed[i + 1]
    local len = math.max(nxt and (nxt.t - e.t) or cfg.last_len, MIN_ITEM)
    local text = C.comment_text(e.cue, cfg.comment_lines, cfg.comment_title, cfg.prefix)
    wanted[#wanted + 1] = { id = e.id, pos = e.t, len = len, text = text, rgb = rgb }
    parts[#parts + 1] = string.format("%s@%.9f+%.9f:%s", e.id, e.t, len, text)
  end
  local count = tr and RA.comment_item_count(tr) or -1
  local want_sig = "on|" .. C.hash(table.concat(parts, "\30") .. "#" .. tostring(rgb))
  if want_sig .. "|" .. count == self.comment_sig and self.comment_shown then return end   -- same content, same number of items
  local made = false
  if not tr then open(); tr, made = RA.ensure_comment_track(cfg.comment_name)
  elseif legacy then open(); RA.upgrade_track(tr) end         -- a track tagged by the old name becomes ours
  if not self.comment_shown then
    -- switched on (or first look): make sure the track is visible. Not repeated, so a track you hide yourself stays hidden.
    if not RA.comment_track_visible(tr) then open(); RA.show_comment_track(tr, true) end
    self.comment_shown = true
  end
  local cs = rgb and tostring(rgb) or "none"
  local recolor = made or self.color_applied ~= cs
  if recolor then open(); RA.set_track_color(tr, rgb) end
  RA.set_comment_items(tr, wanted, open, recolor)
  if recolor then
    self.color_applied = cs
    RA.proj_set("color_applied", cs)
  end
  self.comment_sig = want_sig .. "|" .. #wanted
end

function App:rebuild_comments() self.comment_sig = nil; self.pending, self.changed_at = true, -1e9 end

---------------------------------------------------------------------------------------------------------- sync
function App:sync()
  self:scan()
  if not self.cfg.live then return end
  local opened = false
  local steps = self.cfg.undo_mode == "steps"
  local function open()
    if opened then return end
    opened = true
    RA.hold(true)
    if steps then RA.undo_begin() end
  end
  if self.cfg.rename_markers then
    for _, row in ipairs(self.rows) do
      local m = row.marker
      if m then
        local want = C.marker_name(self.cfg.prefix, row.cue)
        if m.name ~= want then open(); RA.move_marker(m, m.pos, want); m.name = want end
      end
    end
  end
  self:sync_comments(open)
  if opened then
    if steps then RA.undo_end("CreateScriptTrack: sync") end
    RA.hold(false); RA.dirty(); RA.refresh()
  end
end

---------------------------------------------------------------------------------------------------------- position -> current cue
function App:update_position()
  local f = self.cfg.follow
  local idx
  if f == "off" then
    if self.selected then for i, e in ipairs(self.timed) do if e.id == self.selected then idx = i end end end
  else
    local pos = (f == "play" and RA.playing()) and RA.play_pos() or RA.cursor()
    self.pos = pos
    idx = C.current(self.timed, pos)
  end
  local id = idx and self.timed[idx].id or nil
  if id ~= self.cur_id then self.cur_id = id; if id then self.want_scroll = id end end
  self.cur = idx
end

-- the cue shown in the prompter and the one after it
function App:prompter_rows()
  local cur = self.cur and self.timed[self.cur] or nil
  local nxt = self.timed[(self.cur or 0) + 1]
  return cur, nxt
end

function App:tick()
  local now = r.time_precise()
  local proj = RA.proj_id()
  if proj ~= self.proj then self.proj = proj; self:load_project() end
  if now - self.last_poll >= POLL then self.last_poll = now; self:poll_file(false) end
  local cc = RA.change_count()
  if cc ~= self.seen then self.seen = cc; self.changed_at = now; self.pending = true end
  if self.pending and now - self.changed_at >= DEBOUNCE and not RA.mouse_down() then
    self.pending = false
    self:sync()
  end
  self:update_position()
end

---------------------------------------------------------------------------------------------------------- commands
function App:select(id) self.selected = id; self.want_scroll = id end

function App:goto_cue(id)
  local row = self.row_by_id[id]
  self.selected = id
  if row and row.t then RA.set_cursor(row.t, RA.playing()); self.want_scroll = id; return true end
  return false
end

function App:step(dir)                          -- dir = 1 next, -1 previous (by time)
  if #self.timed == 0 then return false end
  local i = self.cur
  local target
  if dir > 0 then target = self.timed[(i or 0) + 1] else target = i and self.timed[i - 1] or nil end
  -- standing between two cues: "previous" is the one we are inside, so go to its start
  if dir < 0 and i and self.pos and self.timed[i].t < self.pos - 1e-3 and self.cfg.follow ~= "off" then target = self.timed[i] end
  if not target then return false end
  return self:goto_cue(target.id)
end

function App:set_to_cursor(id)
  local row = self.row_by_id[id]
  if not row then return false end
  local pos = RA.playing() and RA.play_pos() or RA.cursor()
  local name = C.marker_name(self.cfg.prefix, row.cue)
  RA.undo_begin()
  if row.marker then RA.move_marker(row.marker, pos, name) else RA.add_marker(pos, name, MARKER_RGB) end
  RA.undo_end("CreateScriptTrack: set cue " .. id)
  RA.dirty()
  self.pending, self.changed_at = true, -1e9
  return true
end

function App:clear_marker(id)
  local row = self.row_by_id[id]
  if not row or not row.marker then return false end
  RA.undo_begin(); RA.delete_marker(row.marker); RA.undo_end("CreateScriptTrack: remove cue marker " .. id); RA.dirty()
  self.pending, self.changed_at = true, -1e9
  return true
end

-- an orphan marker takes over a cue that has no marker yet
function App:remap(marker, cue_id)
  local row = self.row_by_id[cue_id]
  if not row or row.marker then return false end
  RA.undo_begin()
  RA.move_marker(marker, marker.pos, C.marker_name(self.cfg.prefix, row.cue))
  RA.undo_end("CreateScriptTrack: remap marker to cue " .. cue_id)
  RA.dirty()
  self.pending, self.changed_at = true, -1e9
  return true
end

function App:delete_orphan(marker)
  RA.undo_begin(); RA.delete_marker(marker); RA.undo_end("CreateScriptTrack: delete orphan marker"); RA.dirty()
  self.pending, self.changed_at = true, -1e9
end

return App

end
__preload["CSTUI"] = function(...)
-- CSTUI.lua
-- ReaImGui window. Reads App state, calls App methods. Same layout conventions as the other _n_plugins:
-- status line, button row, amber section titles with a rule, tables, a settings block at the bottom.

local r = reaper
local V = require("CSTVersion")
local C = require("CSTCore")

local UI = {}

local COL_HEAD = 0xFFCC44FF
local COL_DIM  = 0x999999FF
local COL_WARN, COL_ERR, COL_OK = 0xFFAA33FF, 0xFF5F5FFF, 0x5FE07FFF
local COL_ACCENT = 0xB38CF8FF          -- cue headers in the preview (light violet)
local COL_TEXT   = 0xE6E6E6FF
local COL_CODE   = 0xC8B070FF

-- Accent colour scheme. Hue 262 deg (from #4700C2); saturation, brightness and alpha are those of ImGui's default dark
-- style (its blue is hue 212 deg), so buttons/headers are translucent like the default instead of solid and heavy.
local BG = 0x181A1AFF
local THEME = {
  { "WindowBg", BG }, { "PopupBg", BG }, { "ChildBg", BG },
  { "FrameBg", 0x47297A8A }, { "FrameBgHovered", 0x8542FA66 }, { "FrameBgActive", 0x8542FAAB },
  { "Button", 0x8542FA66 }, { "ButtonHovered", 0x8542FAFF }, { "ButtonActive", 0x650FFAFF },
  { "SliderGrab", 0x793DE0FF }, { "SliderGrabActive", 0x8542FAFF }, { "CheckMark", 0x8542FAFF },
  { "Header", 0x8542FA4F }, { "HeaderHovered", 0x8542FACC }, { "HeaderActive", 0x8542FAFF },
  { "PlotHistogram", 0x8542FAFF }, { "TitleBgActive", 0x47297AFF },
}

-- pushes the theme and returns how many colours were pushed
-- (a colour name missing in an older ReaImGui is skipped instead of raising an error)
local function push_theme(ctx)
  local n = 0
  for _, c in ipairs(THEME) do
    local get = r["ImGui_Col_" .. c[1]]
    if get then r.ImGui_PushStyleColor(ctx, get(), c[2]); n = n + 1 end
  end
  return n
end

local function fmt_time(t)
  if r.format_timestr_pos then return r.format_timestr_pos(t, "", -1) end
  return C.fmt_clock(t)
end

-- swatches for the comment track colour (0xRRGGBB): the accent, then the palette AliasTrack groups use
local PALETTE = { 0x8542FA, 0x3FA7D6, 0x59CD90, 0xFAC05E, 0xF79D84, 0xEE6352, 0xB38CF8, 0x5ED1C4 }

local PREVIEW_H = 300
local PROMPTER_SCALE = 1.6

function UI.new(app)
  local ui = {}
  local ctx = r.ImGui_CreateContext("CreateScriptTrack")
  local title = "CreateScriptTrack v" .. V.VERSION .. "###create_script_track_main"
  local state = { path_buf = nil, path_seen = nil, prefix_buf = nil }
  ui.state = state

  local function tip(t) if r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(ctx, t) end end
  local function heading(t) r.ImGui_Spacing(ctx); r.ImGui_TextColored(ctx, COL_HEAD, t); r.ImGui_Separator(ctx) end
  local function btn(label, t, disabled)
    if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
    local clicked = r.ImGui_Button(ctx, label)
    if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
    if t then tip(t) end
    return clicked and not disabled
  end
  local function small(label, t, disabled)
    if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
    local clicked = r.ImGui_SmallButton(ctx, label)
    if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
    if t then tip(t) end
    return clicked and not disabled
  end
  local function checkbox(label, key, t)
    local ch, v = r.ImGui_Checkbox(ctx, label, app.cfg[key])
    if t then tip(t) end
    if ch then app:set(key, v) end
  end
  local function radio(label, key, value, t)
    if r.ImGui_RadioButton(ctx, label .. "##" .. key .. "_" .. value, app.cfg[key] == value) then app:set(key, value) end
    if t then tip(t) end
  end
  local function number(label, key, lo, hi, width)
    r.ImGui_SetNextItemWidth(ctx, width or 90)
    local ch, v = r.ImGui_InputInt(ctx, label, app.cfg[key])
    if ch then app:set(key, math.max(lo, math.min(hi, v))) end
  end
  -- coloured text: the push is always popped again, so the colour stack stays balanced
  local function ctext(col, text, wrapped)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col)
    if wrapped then r.ImGui_TextWrapped(ctx, text) else r.ImGui_Text(ctx, text) end
    r.ImGui_PopStyleColor(ctx, 1)
  end

  ------------------------------------------------------------------------------------------------ top
  local STATUS = {
    live    = { COL_OK,   "LIVE",             "- following the file" },
    manual  = { COL_OK,   "SYNCED",           "- the file is only read when you press Pull or Sync now" },
    changed = { COL_WARN, "CHANGED ON DISK",  "- the file differs from the copy stored in the project" },
    missing = { COL_WARN, "FILE MISSING",     "- using the copy stored in the project" },
    ["local"] = { COL_WARN, "LOCAL COPY",     "- using the copy stored in the project" },
    none    = { COL_DIM,  "NO CUE SHEET",     "- choose a Markdown file or drop it here" },
  }

  local function draw_top()
    local s = STATUS[app.status] or STATUS.none
    r.ImGui_TextColored(ctx, s[1], s[2])
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, s[3])
    if not app.cfg.live then r.ImGui_TextColored(ctx, COL_WARN, "FROZEN - markers and comment items are left alone") end
    if btn("Choose file...", "Pick the Markdown file with the cue headers.") then app:choose_file() end
    r.ImGui_SameLine(ctx)
    if btn("Sync now", "Read the file again (whatever the sync mode) and run one full sync.") then app:sync_now() end
    r.ImGui_SameLine(ctx)
    if btn(app.cfg.live and "Freeze" or "Go live", "Freeze: markers and comment items are not written. The preview keeps following.") then
      app:set("live", not app.cfg.live)
    end
    if app.status == "changed" then
      r.ImGui_SameLine(ctx)
      if btn("Pull", "Replace the project's copy with the file.") then app:pull() end
      r.ImGui_SameLine(ctx)
      if btn("Keep mine", "Keep the project's copy; stop asking until the file changes again.") then app:keep() end
    end
    if app.path ~= "" then
      r.ImGui_SameLine(ctx)
      if btn("Open in editor", "Needs the SWS extension.") then app:open_in_editor() end
      r.ImGui_SameLine(ctx)
      if btn("Detach", "Remove the link to the file. The copy stored in the project stays.") then app:detach() end
    end

    if state.path_seen ~= app.path then state.path_seen = app.path; state.path_buf = app.path end
    r.ImGui_SetNextItemWidth(ctx, 420)
    local ch, v = r.ImGui_InputText(ctx, "File##path", state.path_buf or "")
    if ch then state.path_buf = v end
    if r.ImGui_BeginDragDropTarget(ctx) then
      local ok, n = r.ImGui_AcceptDragDropPayloadFiles(ctx)
      if ok and n and n > 0 then
        local _, f = r.ImGui_GetDragDropPayloadFile(ctx, 0)
        if f then app:set_file(f) end
      end
      r.ImGui_EndDragDropTarget(ctx)
    end
    tip("Type or paste a path, or drop a .md file here.")
    r.ImGui_SameLine(ctx)
    if btn("Load", "Link the file at this path.", (state.path_buf or "") == "") then app:set_file(state.path_buf) end
    if app.err then r.ImGui_TextColored(ctx, COL_ERR, app.err) end
    if state.err then r.ImGui_TextColored(ctx, COL_ERR, "UI: " .. state.err) end
  end

  ------------------------------------------------------------------------------------------------ cues
  local function draw_cues()
    local n = app:counts()
    heading(string.format("Cues (%d)", #app.rows))
    if #app.rows == 0 then
      local why = app.text == "" and "Nothing loaded yet." or "No header matches."
      r.ImGui_TextColored(ctx, COL_DIM, why .. " A cue is a Markdown header that starts with the prefix and a number: 1, 1.2 or 1.2.3 (see Settings).")
      return
    end
    r.ImGui_TextColored(ctx, COL_OK, string.format("%d mapped to markers", n.mapped))
    if n.unmapped > 0 then r.ImGui_SameLine(ctx); r.ImGui_TextColored(ctx, COL_WARN, string.format("%d without a marker", n.unmapped)) end
    if n.duplicate > 0 then
      r.ImGui_TextColored(ctx, COL_ERR, string.format("%d duplicate id(s) in the file - the first one of each is used", n.duplicate))
    end

    if small("< Prev", "Go to the previous cue marker.") then app:step(-1) end
    r.ImGui_SameLine(ctx)
    if small("Next >", "Go to the next cue marker.") then app:step(1) end
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, "Follow:")
    r.ImGui_SameLine(ctx); radio("Playhead", "follow", "play", "While playing the playhead, otherwise the edit cursor.")
    r.ImGui_SameLine(ctx); radio("Edit cursor", "follow", "cursor", "Always the edit cursor.")
    r.ImGui_SameLine(ctx); radio("Off", "follow", "off", "The cue you click is the current one.")

    local flags = r.ImGui_TableFlags_Borders and r.ImGui_TableFlags_Borders() or 0
    if r.ImGui_BeginTable(ctx, "cues##tbl", 5, flags) then
      for _, h in ipairs({ "Cue", "Title", "Time", "Status", "" }) do r.ImGui_TableSetupColumn(ctx, h) end
      r.ImGui_TableHeadersRow(ctx)
      for _, row in ipairs(app.rows) do
        r.ImGui_PushID(ctx, "cue" .. row.cue.n)
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableSetColumnIndex(ctx, 0)
        local label = (row.id == app.cur_id and "> " or "") .. row.id .. "##sel"
        if r.ImGui_Selectable(ctx, label, app.selected == row.id) then
          if row.status == "mapped" then app:goto_cue(row.id) else app:select(row.id) end
        end
        r.ImGui_TableSetColumnIndex(ctx, 1); r.ImGui_Text(ctx, row.cue.title)
        r.ImGui_TableSetColumnIndex(ctx, 2)
        if row.t then r.ImGui_Text(ctx, fmt_time(row.t)) else r.ImGui_TextColored(ctx, COL_DIM, "-") end
        r.ImGui_TableSetColumnIndex(ctx, 3)
        if row.status == "mapped" then r.ImGui_TextColored(ctx, COL_OK, "mapped")
        elseif row.status == "duplicate" then r.ImGui_TextColored(ctx, COL_ERR, "duplicate")
        else r.ImGui_TextColored(ctx, COL_WARN, "no marker") end
        r.ImGui_TableSetColumnIndex(ctx, 4)
        if row.status ~= "duplicate" then
          if small("Set", "Put this cue's marker at the playhead (while playing) or the edit cursor.") then app:set_to_cursor(row.id) end
          if row.marker then
            r.ImGui_SameLine(ctx)
            if small("Clear", "Remove this cue's marker.") then app:clear_marker(row.id) end
          end
        end
        r.ImGui_PopID(ctx)
      end
      r.ImGui_EndTable(ctx)
    end

    if #app.orphans > 0 then
      heading(string.format("Orphan markers (%d)", #app.orphans))
      local sel = app.selected and app.row_by_id[app.selected]
      local can_remap = sel ~= nil and sel.status == "unmapped"
      for _, o in ipairs(app.orphans) do
        r.ImGui_PushID(ctx, "orph" .. o.marker.idx)
        r.ImGui_TextColored(ctx, COL_WARN, o.marker.name)
        r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, COL_DIM, string.format("at %s - %s", fmt_time(o.marker.pos), o.why))
        r.ImGui_SameLine(ctx)
        if small("Remap", "Make this marker the one of the cue selected in the table (it must have no marker).", not can_remap) then
          app:remap(o.marker, app.selected)
        end
        r.ImGui_SameLine(ctx)
        if small("Delete", "Delete this marker.") then app:delete_orphan(o.marker) end
        r.ImGui_PopID(ctx)
      end
    end
  end

  ------------------------------------------------------------------------------------------------ preview
  local function draw_blocks()
    local cur = app.cur_id and app.by_id[app.cur_id]
    local cur_n = cur and cur.n or nil
    for _, b in ipairs(app.blocks) do
      local in_cur = cur_n ~= nil and b.owner == cur_n
      local body_col = in_cur and COL_TEXT or COL_DIM
      if b.kind == "h" then
        local is_cur = b.cue ~= nil and b.cue == cur_n
        local col = b.cue and (is_cur and COL_OK or COL_ACCENT) or (b.level == 1 and COL_HEAD or body_col)
        ctext(col, (is_cur and "> " or "") .. C.inline(b.text), true)
        if b.cue and app.want_scroll and app.doc.cues[b.cue].id == app.want_scroll then
          r.ImGui_SetScrollHereY(ctx, 0.15)
          app.want_scroll = nil
        end
      elseif b.kind == "blank" then r.ImGui_Dummy(ctx, 0, 4)
      elseif b.kind == "p" then ctext(body_col, C.inline(b.text), true)
      elseif b.kind == "li" then ctext(body_col, string.rep(" ", b.indent) .. (b.marker or "-") .. " " .. C.inline(b.text), true)
      elseif b.kind == "task" then ctext(body_col, string.rep(" ", b.indent) .. (b.checked and "[x] " or "[ ] ") .. C.inline(b.text), true)
      elseif b.kind == "code" then ctext(in_cur and COL_CODE or COL_DIM, "  " .. b.text, false)
      elseif b.kind == "quote" then ctext(COL_DIM, "| " .. C.inline(b.text), true)
      elseif b.kind == "hr" then r.ImGui_Separator(ctx) end
    end
  end

  local function draw_prompter()
    local cur, nxt = app:prompter_rows()
    local scaled = r.ImGui_SetWindowFontScale ~= nil
    if scaled then r.ImGui_SetWindowFontScale(ctx, PROMPTER_SCALE) end
    if cur then
      ctext(COL_OK, C.marker_name(app.cfg.prefix, cur.cue), true)
      for _, line in ipairs(cur.cue.body) do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if s == "" then r.ImGui_Dummy(ctx, 0, 4) else ctext(COL_TEXT, C.inline(s:gsub("^#+%s*", "")), true) end
      end
    else
      ctext(COL_DIM, "Waiting for the first cue...", true)
    end
    if nxt then
      r.ImGui_Separator(ctx)
      ctext(COL_ACCENT, "NEXT  " .. C.marker_name(app.cfg.prefix, nxt.cue), true)
      for _, line in ipairs(nxt.cue.body) do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if s ~= "" then ctext(COL_DIM, C.inline(s:gsub("^#+%s*", "")), true); break end
      end
    end
    if scaled then r.ImGui_SetWindowFontScale(ctx, 1.0) end
  end

  local function draw_preview()
    heading("Preview")
    checkbox("Prompter", "prompter", "Large text: only the current cue and the next one.")
    if r.ImGui_BeginChild(ctx, "preview##child", 0, PREVIEW_H) then
      if app.text == "" then r.ImGui_TextColored(ctx, COL_DIM, "Nothing to show yet.")
      elseif app.cfg.prompter then draw_prompter()
      else draw_blocks() end
      r.ImGui_EndChild(ctx)
    end
  end

  ------------------------------------------------------------------------------------------------ comment track
  local function draw_comments()
    heading("Comment track")
    checkbox("Show the cue text on a comment track", "comments",
      "A track named '" .. app.cfg.comment_name .. "' gets one text item per cue marker, with the first lines of the cue as its notes.")
    number("lines of each cue##clines", "comment_lines", 0, 50)
    tip("How many non-empty lines of the cue's text go into each item (0 = only the title).")
    checkbox("Start with the cue title", "comment_title")
    checkbox("Colour the track and its items", "comment_color_on",
      "Off: the track and its items use REAPER's default colour.\nOn: they get the colour below. Items you colour by hand are left alone until you pick a new colour here.")
    if app.cfg.comment_color_on then
      for i, c in ipairs(PALETTE) do
        if i > 1 then r.ImGui_SameLine(ctx) end
        if r.ImGui_ColorButton(ctx, "swatch" .. i, (c << 8) | 0xFF, 0, 18, 18) then app:set_comment_color(c) end
        tip(string.format("#%06X", c))
      end
      if r.ImGui_ColorEdit3 then
        r.ImGui_SameLine(ctx)
        local flags = r.ImGui_ColorEditFlags_NoInputs and r.ImGui_ColorEditFlags_NoInputs() or 0
        local ch, c = r.ImGui_ColorEdit3(ctx, "Colour##ccolor", app.cfg.comment_color, flags)
        if ch then app:set_comment_color(c & 0xFFFFFF) end
        tip("Pick any colour.")
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_TextColored(ctx, COL_DIM, string.format("#%06X", app.cfg.comment_color))
    end
    number("s long for the last item##clast", "last_len", 1, 3600)
    r.ImGui_Text(ctx, "When switched off:")
    r.ImGui_SameLine(ctx); radio("Hide the track", "comment_off", "hide", "The track and its items stay, hidden.")
    r.ImGui_SameLine(ctx); radio("Delete the track", "comment_off", "delete", "The track and its items are removed.")
    if btn("Rebuild now", "Rewrite every comment item from the cues and markers.", not app.cfg.comments or not app.cfg.live) then app:rebuild_comments() end
  end

  ------------------------------------------------------------------------------------------------ settings
  local function draw_settings()
    heading("Settings")
    r.ImGui_SetNextItemWidth(ctx, 140)
    local ch, v = r.ImGui_InputText(ctx, "Cue prefix##prefix", state.prefix_buf or app.cfg.prefix)
    if ch then state.prefix_buf = v end
    if r.ImGui_IsItemDeactivatedAfterEdit(ctx) and state.prefix_buf ~= nil then
      app:change_prefix(state.prefix_buf); state.prefix_buf = nil
    end
    tip("Headers must start with this, then a number (Q 1.2 Door). Empty = bare numbers.\nMarkers that follow the old prefix are renamed.")
    r.ImGui_Text(ctx, "Header levels:")
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, 90)
    local c1, lo = r.ImGui_InputInt(ctx, "from##lvlmin", app.cfg.min_level)
    if c1 then lo = math.max(1, math.min(6, lo)); app:set("min_level", lo); if app.cfg.max_level < lo then app:set("max_level", lo) end end
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, 90)
    local c2, hi = r.ImGui_InputInt(ctx, "to##lvlmax", app.cfg.max_level)
    if c2 then hi = math.max(1, math.min(6, hi)); app:set("max_level", hi); if app.cfg.min_level > hi then app:set("min_level", hi) end end

    r.ImGui_Text(ctx, "File sync:")
    r.ImGui_SameLine(ctx); radio("Source wins", "sync_mode", "source", "The file is checked every second; when it changes the project follows it.")
    r.ImGui_SameLine(ctx); radio("Manual", "sync_mode", "manual", "A changed file is only reported; you decide with Pull / Keep mine.")
    r.ImGui_SameLine(ctx); radio("Local wins", "sync_mode", "local", "The file is ignored; the copy stored in the project is used.")
    checkbox("Rename markers to follow the cue titles", "rename_markers",
      "On: a marker that belongs to a cue is renamed to '<prefix> <id> <title>'.\nOff: your own marker names are left alone (they still map by id).")

    r.ImGui_Text(ctx, "Undo:")
    r.ImGui_SameLine(ctx); radio("One step per edit", "undo_mode", "silent", "Syncs add no undo points; Ctrl+Z undoes your own edit and the next sync derives everything again. Recommended.")
    r.ImGui_SameLine(ctx); radio("Separate sync steps", "undo_mode", "steps", "Every sync that changes something is its own undo point 'CreateScriptTrack: sync'.")
  end

  local function draw_ui()
    draw_top()
    draw_cues()
    draw_preview()
    draw_comments()
    draw_settings()
    if app.msg then r.ImGui_Spacing(ctx); r.ImGui_TextColored(ctx, COL_DIM, app.msg) end
  end
  ui.draw_ui = draw_ui

  function ui.frame()
    local pushed = push_theme(ctx)
    r.ImGui_SetNextWindowSize(ctx, 760, 960, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, title, true)
    if visible then
      local ok, e = pcall(draw_ui)
      if not ok then state.err = tostring(e) else state.err = nil end
      r.ImGui_End(ctx)
    end
    r.ImGui_PopStyleColor(ctx, pushed)   -- also when the window is collapsed: the colour stack must stay balanced
    return open
  end

  return ui
end

return UI

end

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "CreateScriptTrack", 0)
  return
end

local App = require("CSTApp")
local UI  = require("CSTUI")

local EXT = "CreateScriptTrackApp"

-- running again while open = close
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

local app = App.new()
local ui = UI.new(app)

local function shutdown()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end
  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then last_err = tostring(err); app.err = "Error: " .. last_err end
  if ok then app.err = nil; last_err = nil end
  if ui.frame() then r.defer(loop) else shutdown() end
end

loop()

