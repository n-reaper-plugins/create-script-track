-- The spike probe is only meaningful in real REAPER, but its own logic can be checked against the mock.
package.path = "./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
reaper.Undo_OnStateChange = function() end
reaper.GetPlayPosition2 = function() return 0 end
reaper.GetPlayState = function() return 0 end
reaper.GetCursorPosition = function() return 0 end
local out = {}
reaper.ShowConsoleMsg = function(s) out[#out + 1] = s end
local ok, err = pcall(dofile, "spikes/spike_1_probe.lua")
T.ok(ok, "probe runs: " .. tostring(err))
local text = table.concat(out)
T.ok(text:find("CreateScriptTrack probe", 1, true) ~= nil, "report printed")
local _, fails = text:gsub("%[FAIL%]", "")
T.eq(fails, 0, "no FAIL lines against the mock (" .. (text:match("%[FAIL%][^\n]*") or "") .. ")")
local _, passes = text:gsub("%[PASS%]", "")
T.ok(passes >= 8, "the checks actually ran: " .. passes)
T.eq(#S.markers, 0, "probe cleaned up its marker"); T.eq(#S.tracks, 0, "and its track")
T.done("test_probe")
