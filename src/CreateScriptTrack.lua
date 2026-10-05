-- @description CreateScriptTrack: a Markdown cue sheet that follows the REAPER timeline (cue markers, live preview, comment track)
-- @version @@VERSION@@
-- @author _n_plugins
-- @about
--   Link a Markdown file whose headers are cue numbers (Q 1, Q 1.2, Q 1.2.3 ... the prefix is yours to set). The cues are
--   mapped to project markers; the preview scrolls to the cue under the playhead or edit cursor; an optional comment track
--   carries the first lines of every cue as text items. The file is also stored inside the project, so it still works when
--   the file moves. Needs ReaImGui (ReaPack > ReaTeam Extensions). Run the action again while the window is open to close it.

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
