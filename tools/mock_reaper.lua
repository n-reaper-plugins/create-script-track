-- In-memory fake of the parts of the REAPER API that CreateScriptTrack uses. It checks OUR logic, not REAPER's behaviour.
-- Behaviours assumed on purpose (to confirm in real REAPER, see spikes/SPIKES.md):
--   * SetProjExtState with an empty value deletes the key; GetProjExtState returns (length, value)
--   * EnumProjectMarkers3 returns 0 as the first value when the index is past the end
--   * an item added with AddMediaItemToTrack has no take (an "empty item"); its text lives in P_NOTES

local M = {}

function M.install()
  local S = { tracks = {}, ext = {}, proj_ext = {}, markers = {}, statecount = 1, guid_n = 0, undo = {}, clock = 0, dirty = 0,
              cursor = 0, playing = false, play_pos = 0, picked = nil, next_marker = 1, hold = 0, proj = "proj1", js_mouse = nil }
  M.S = S
  local function bump() S.statecount = S.statecount + 1 end
  local function guid() S.guid_n = S.guid_n + 1; return string.format("{%08X-0000-4000-8000-%012X}", S.guid_n, S.guid_n) end
  local function tidx(t) for i, x in ipairs(S.tracks) do if x == t then return i end end end

  --------------------------------------------------------------------------------------------- scene helpers (the "user")
  function M.track(name)
    local t = { guid = guid(), name = name or "", ext = {}, items = {}, vals = { B_SHOWINTCP = 1, B_SHOWINMIXER = 1, I_CUSTOMCOLOR = 0 } }
    S.tracks[#S.tracks + 1] = t; bump(); return t
  end
  function M.marker(pos, name) local i = S.next_marker; S.next_marker = i + 1; S.markers[#S.markers + 1] = { idx = i, pos = pos, name = name, color = 0, rgn = false }; bump(); return S.markers[#S.markers] end
  function M.region(pos, e, name) local i = S.next_marker; S.next_marker = i + 1; S.markers[#S.markers + 1] = { idx = i, pos = pos, name = name, color = 0, rgn = true, e = e }; bump() end
  function M.move_marker(m, pos) m.pos = pos; bump() end
  function M.rename_marker(m, name) m.name = name; bump() end
  function M.marker_named(sub) for _, m in ipairs(S.markers) do if not m.rgn and m.name:find(sub, 1, true) then return m end end end
  function M.marker_names() local out = {} for _, m in ipairs(S.markers) do if not m.rgn then out[#out + 1] = m.name end end table.sort(out) return out end
  function M.track_named(name) for _, t in ipairs(S.tracks) do if t.name == name then return t end end end
  function M.items_on(t) local out = {} for _, it in ipairs(t.items) do out[#out + 1] = it end table.sort(out, function(a, b) return a.p.D_POSITION < b.p.D_POSITION end) return out end
  function M.write(path, text) local f = assert(io.open(path, "wb")); f:write(text); f:close() end
  function M.tick(dt) S.clock = S.clock + (dt or 1) end

  --------------------------------------------------------------------------------------------- API
  local R = {}
  reaper = R
  R.ShowConsoleMsg = function() end
  R.MB = function() return 1 end
  R.atexit = function() end
  R.defer = function() end
  R.time_precise = function() return S.clock end
  R.get_action_context = function() return true, "x", 0, 0, 0, 0 end
  R.SetToggleCommandState = function() end
  R.RefreshToolbar2 = function() end
  R.GetExtState = function(sec, k) return S.ext[sec .. "/" .. k] or "" end
  R.SetExtState = function(sec, k, v) S.ext[sec .. "/" .. k] = v end
  R.EnumProjects = function() return S.proj end
  R.GetProjectStateChangeCount = function() return S.statecount end
  R.PreventUIRefresh = function(n) S.hold = S.hold + n; assert(S.hold >= 0, "PreventUIRefresh unbalanced") end
  R.UpdateArrange = function() end
  R.MarkProjectDirty = function() S.dirty = S.dirty + 1 end
  R.Undo_BeginBlock2 = function() assert(not S.in_block, "nested undo block"); S.in_block = true end
  R.Undo_EndBlock2 = function(_, label) assert(S.in_block, "undo end without begin"); S.in_block = false; S.undo[#S.undo + 1] = label end
  R.ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end
  R.ColorFromNative = function(c) return c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF end
  R.format_timestr_pos = function(p) return string.format("%.3f", p) end
  R.GetUserFileNameForRead = function() if S.picked then return true, S.picked end return false, "" end

  -- project ext state
  R.SetProjExtState = function(_, sec, key, val)
    if key == "" then S.proj_ext[sec] = nil; return 0 end
    S.proj_ext[sec] = S.proj_ext[sec] or {}
    S.proj_ext[sec][key] = (val ~= "") and val or nil
    bump(); return 0
  end
  R.GetProjExtState = function(_, sec, key)
    local v = S.proj_ext[sec] and S.proj_ext[sec][key]
    if v then return #v, v end
    return 0, ""
  end

  -- transport
  R.GetCursorPosition = function() return S.cursor end
  R.SetEditCurPos = function(t, _, seek) S.cursor = t; if seek and S.playing then S.play_pos = t end end
  R.GetPlayState = function() return S.playing and 1 or 0 end
  R.GetPlayPosition2 = function() return S.play_pos end

  -- markers
  R.EnumProjectMarkers3 = function(_, i)
    local m = S.markers[i + 1]
    if not m then return 0 end
    return i + 2, m.rgn, m.pos, m.e or 0, m.name, m.idx, m.color
  end
  R.AddProjectMarker2 = function(_, isrgn, pos, e, name, want, color)
    local i = S.next_marker; S.next_marker = i + 1
    S.markers[#S.markers + 1] = { idx = i, pos = pos, name = name, color = color, rgn = isrgn, e = e }
    bump(); return i
  end
  R.SetProjectMarker4 = function(_, idx, isrgn, pos, e, name, color)
    for _, m in ipairs(S.markers) do
      if m.idx == idx and m.rgn == isrgn then m.pos, m.name, m.color = pos, name, color; bump(); return true end
    end
    return false
  end
  R.DeleteProjectMarker = function(_, idx, isrgn)
    for i, m in ipairs(S.markers) do
      if m.idx == idx and m.rgn == isrgn then table.remove(S.markers, i); bump(); return true end
    end
    return false
  end

  -- tracks
  R.CountTracks = function() return #S.tracks end
  R.GetTrack = function(_, i) return S.tracks[i + 1] end
  R.InsertTrackAtIndex = function(i)
    table.insert(S.tracks, i + 1, { guid = guid(), name = "", ext = {}, items = {}, vals = { B_SHOWINTCP = 1, B_SHOWINMIXER = 1, I_CUSTOMCOLOR = 0 } }); bump()
  end
  R.DeleteTrack = function(t) table.remove(S.tracks, assert(tidx(t), "DeleteTrack: unknown")); t.deleted = true; bump() end
  R.GetMediaTrackInfo_Value = function(t, k) assert(not t.deleted, "deleted track"); return assert(t.vals[k], "track value " .. k) end
  R.SetMediaTrackInfo_Value = function(t, k, v) assert(not t.deleted, "deleted track"); t.vals[k] = v; bump(); return true end
  R.GetSetMediaTrackInfo_String = function(t, k, v, set)
    assert(not t.deleted, "deleted track")
    if k == "P_NAME" then if set then t.name = v; bump(); return true, v end; return true, t.name end
    local ek = assert(k:match("^P_EXT:(.+)$"), "track string " .. k)
    if set then t.ext[ek] = (v ~= "") and v or nil; bump(); return true, v end
    return t.ext[ek] ~= nil, t.ext[ek] or ""
  end

  -- items (empty items only: no takes)
  R.CountTrackMediaItems = function(t) return #t.items end
  R.GetTrackMediaItem = function(t, i) return t.items[i + 1] end
  R.AddMediaItemToTrack = function(t)
    local it = { guid = guid(), track = t, ext = {}, notes = "", p = { D_POSITION = 0, D_LENGTH = 0, I_CUSTOMCOLOR = 0 } }
    t.items[#t.items + 1] = it; bump(); return it
  end
  R.DeleteTrackMediaItem = function(t, it)
    for i, x in ipairs(t.items) do if x == it then table.remove(t.items, i); it.deleted = true; bump(); return true end end
    error("DeleteTrackMediaItem: not on track")
  end
  R.GetMediaItemInfo_Value = function(it, k) assert(not it.deleted, "deleted item"); return assert(it.p[k], "item value " .. k) end
  R.SetMediaItemInfo_Value = function(it, k, v) assert(not it.deleted, "deleted item"); it.p[k] = v; bump(); return true end
  R.GetSetMediaItemInfo_String = function(it, k, v, set)
    assert(not it.deleted, "deleted item")
    if k == "P_NOTES" then if set then it.notes = v; bump(); return true, v end; return true, it.notes end
    local ek = assert(k:match("^P_EXT:(.+)$"), "item string " .. k)
    if set then it.ext[ek] = (v ~= "") and v or nil; bump(); return true, v end
    return it.ext[ek] ~= nil, it.ext[ek] or ""
  end

  return S
end

return M
