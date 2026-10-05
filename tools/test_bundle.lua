-- The shipped single file must work without src/ on the path.
package.path = "./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

local P = dofile("tools/project.lua")
for k in pairs(package.loaded) do if k:sub(1, #P.prefix) == P.prefix then package.loaded[k] = nil end end
local S = Mock.install()
local st = Stub.install(reaper)
local deferred
reaper.defer = function(f) deferred = f end

local FILE = os.tmpname()
Mock.write(FILE, "## 1 Intro\nHello\n\n## 2 Outro\nBye\n")
S.proj_ext[P.name] = { src_path = FILE }
Mock.marker(3, "1 Intro")

local f = assert(loadfile("dist/" .. P.name .. ".lua"))
local ok, err = pcall(f)
T.ok(ok, "bundle runs: " .. tostring(err))
T.ok(deferred ~= nil, "main loop scheduled")
T.ok(package.preload["CSTApp"] ~= nil, "modules come from the bundle")
local src = io.open("dist/" .. P.name .. ".lua"):read("a")
local VER = dofile("src/CSTVersion.lua").VERSION
T.ok(src:find("@version " .. VER, 1, true) ~= nil, "version " .. VER .. " stamped into the ReaPack header")
T.ok(not src:find("@@VERSION@@", 1, true), "no placeholder left")

-- a few frames: the stored link is followed, the cue is found, comments can be switched on
for i = 1, 4 do S.clock = S.clock + 1; local d = deferred; deferred = nil; local ok2, e2 = pcall(d); T.ok(ok2, "frame " .. i .. ": " .. tostring(e2)) end
st.clicks["Show the cue text on a comment track"] = true
for _ = 1, 4 do S.clock = S.clock + 1; local d = deferred; deferred = nil; pcall(d) end
local tr = Mock.track_named("Cues")
T.ok(tr ~= nil, "comment track made by the running loop"); T.eq(#tr.items, 1, "one item for the one mapped cue")
T.eq(tr.items[1].notes, "1 Intro\nHello", "its text")
Mock.move_marker(Mock.marker_named("1 Intro"), 9)
for _ = 1, 4 do S.clock = S.clock + 1; local d = deferred; deferred = nil; pcall(d) end
T.eq(tr.items[1].p.D_POSITION, 9, "the running loop follows marker moves")

-- running the action again closes the window
reaper.GetExtState = function(sec, key) if key == "running" then return "1" end if key == "hb" then return tostring(os.time()) end return S.ext[sec .. "/" .. key] or "" end
local ok3 = pcall(assert(loadfile("dist/" .. P.name .. ".lua")))
T.ok(ok3, "second start runs"); T.eq(S.ext[P.name .. "App/stop"], "1", "second start asks the first to stop")

os.remove(FILE)
T.done("test_bundle")
