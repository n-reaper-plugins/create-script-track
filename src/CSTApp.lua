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
