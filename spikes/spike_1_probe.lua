-- CreateScriptTrack spike probe. Run it as a ReaScript in REAPER (a scratch project is best; it cleans up after itself).
-- It checks the REAPER behaviours that the offline mock only ASSUMES (see SPIKES.md, S1 to S5) and prints a report
-- to the ReaScript console. Nothing here needs ReaImGui.
local r = reaper
local report = {}
local function line(ok, name, extra)
  report[#report + 1] = string.format("[%s] %s%s", ok and "PASS" or "FAIL", name, extra and ("  (" .. extra .. ")") or "")
end
local SEC = "CreateScriptTrack_probe"

local function try(name, f)
  local ok, res, extra = pcall(f)
  if not ok then line(false, name, "error: " .. tostring(res)) else line(res and true or false, name, extra) end
end

-- S1: project ext state keeps long single-line values, quotes, braces, backslashes, unicode, edge characters
try("S1 ext-state: 4000-char chunk with a leading '|' round-trips", function()
  local v = "|" .. string.rep("ab\\n\"{}[];=\xE2\x80\x93 ", 250):sub(1, 3990)
  r.SetProjExtState(0, SEC, "chunk", v)
  local n, back = r.GetProjExtState(0, SEC, "chunk")
  return back == v, "stored " .. #v .. " got " .. #back
end)
try("S1 ext-state: trailing and leading spaces survive (or the '|' guard is needed)", function()
  r.SetProjExtState(0, SEC, "sp", "|  x  ")
  local _, back = r.GetProjExtState(0, SEC, "sp")
  return back == "|  x  ", "got '" .. back .. "'"
end)
try("S1 ext-state: an empty value deletes the key", function()
  r.SetProjExtState(0, SEC, "gone", "x"); r.SetProjExtState(0, SEC, "gone", "")
  local n = r.GetProjExtState(0, SEC, "gone")
  return n == 0
end)
try("S1 ext-state: 60 chunks of 4000 characters (240 KB) round-trip", function()
  for i = 0, 59 do r.SetProjExtState(0, SEC, "big" .. i, "|" .. string.rep(string.char(65 + i % 26), 4000)) end
  for i = 0, 59 do
    local _, v = r.GetProjExtState(0, SEC, "big" .. i)
    if #v ~= 4001 then return false, "chunk " .. i .. " has " .. #v end
  end
  return true
end)
r.SetProjExtState(0, SEC, "", "")      -- empty key: delete the whole probe section

-- S2: markers
local added
try("S2 markers: AddProjectMarker2 / EnumProjectMarkers3 / SetProjectMarker4 / DeleteProjectMarker", function()
  local idx = r.AddProjectMarker2(0, false, 12.5, 0, "probe marker", -1, r.ColorToNative(0x85, 0x42, 0xFA) | 0x1000000)
  added = idx
  local found
  local i = 0
  while true do
    local ret, isrgn, pos, _, name, num, col = r.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn and num == idx then found = { pos = pos, name = name, col = col } end
    i = i + 1
  end
  if not found then return false, "marker not found by its index" end
  if math.abs(found.pos - 12.5) > 1e-6 or found.name ~= "probe marker" then return false, "wrong pos/name" end
  r.SetProjectMarker4(0, idx, false, 20, 0, "probe marker 2", found.col, 0)
  local ok = false
  i = 0
  while true do
    local ret, isrgn, pos, _, name, num = r.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn and num == idx then ok = math.abs(pos - 20) < 1e-6 and name == "probe marker 2" end
    i = i + 1
  end
  r.DeleteProjectMarker(0, idx, false)
  return ok, "moved and renamed with SetProjectMarker4"
end)

-- S3: an empty item shows text from P_NOTES; tags on items and tracks
try("S3 empty item: P_NOTES, P_EXT and I_CUSTOMCOLOR can be written and read back", function()
  r.InsertTrackAtIndex(0, true)
  local tr = r.GetTrack(0, 0)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", "probe track", true)
  r.GetSetMediaTrackInfo_String(tr, "P_EXT:CST_comments", "1", true)
  local it = r.AddMediaItemToTrack(tr)
  r.SetMediaItemInfo_Value(it, "D_POSITION", 3); r.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
  r.GetSetMediaItemInfo_String(it, "P_NOTES", "Q 1 Opening\nLights fade up.", true)
  r.GetSetMediaItemInfo_String(it, "P_EXT:CST_cue", "1", true)
  r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", r.ColorToNative(0x85, 0x42, 0xFA) | 0x1000000)
  local _, notes = r.GetSetMediaItemInfo_String(it, "P_NOTES", "", false)
  local _, tag = r.GetSetMediaItemInfo_String(it, "P_EXT:CST_cue", "", false)
  local _, ttag = r.GetSetMediaTrackInfo_String(tr, "P_EXT:CST_comments", "", false)
  local tcol = r.ColorToNative(0x3F, 0xA7, 0xD6) | 0x1000000
  r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", tcol)
  local tback = r.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
  r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", 0)
  local tclear = r.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
  if tback ~= tcol or tclear ~= 0 then return false, "track I_CUSTOMCOLOR: wrote " .. tcol .. ", read " .. tostring(tback) .. "; after clearing " .. tostring(tclear) end
  local ok = notes == "Q 1 Opening\nLights fade up." and tag == "1" and ttag == "1" and r.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR") ~= 0
  report[#report + 1] = "      -> LOOK at the arrange view while this runs: does the item show its two lines of text, in violet? (S3, manual)"
  r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 0)
  local hidden = r.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP") == 0
  r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 1)
  r.DeleteTrack(tr)
  return ok and hidden, "notes/tags/colour read back; track hide flag works"
end)

-- S4: transport getters used by the follow logic
try("S4 transport: GetPlayPosition2 / GetCursorPosition / GetPlayState exist", function()
  return type(r.GetPlayPosition2()) == "number" and type(r.GetCursorPosition()) == "number" and type(r.GetPlayState()) == "number"
end)
try("S4 EnumProjects(-1) returns the active project", function() return r.EnumProjects(-1) ~= nil end)

-- S5: optional extensions
local function info(have, name) report[#report + 1] = string.format("[%s] %s", have and "found" or "missing", name) end
info(r.ImGui_CreateContext ~= nil, "ReaImGui (required for the window)")
info(r.JS_Dialog_BrowseForOpenFiles ~= nil, "js_ReaScriptAPI (optional: file dialog with a filter; syncing waits for mouse release)")
info(r.CF_ShellExecute ~= nil, "SWS (optional: 'Open in editor')")

r.Undo_OnStateChange("CreateScriptTrack probe (no changes kept)")
r.ShowConsoleMsg("\nCreateScriptTrack probe\n" .. table.concat(report, "\n") .. "\n")
