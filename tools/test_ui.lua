package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
local Stub = require("imgui_stub")
local st = Stub.install(reaper)
local App = require("CSTApp")
local UI = require("CSTUI")

local FILE = os.tmpname()
local MD = "# Show\n\n## Q 1 Opening\nLights fade up.\n- house to half\n\n```\ncode line\n```\n\n## Q 2 Storm\nSFX: thunder\n"
Mock.write(FILE, MD)

local app = App.new()
local ui = UI.new(app)
local function frame() st.calls, st.texts = {}, {}; return ui.frame() end
local function settle() for _ = 1, 3 do Mock.tick(1); app:tick() end end
local function has(call) for _, c in ipairs(st.calls) do if c == call then return true end end return false end
local function has_text(sub) for _, t in ipairs(st.texts) do if t:find(sub, 1, true) then return true end end return false end
local function has_call(prefix) for _, c in ipairs(st.calls) do if c:sub(1, #prefix) == prefix then return true end end return false end

-- colour stack: theme + any text colours are always popped again
local pushes, pops = 0, 0
reaper.ImGui_PushStyleColor = function() pushes = pushes + 1 end
reaper.ImGui_PopStyleColor = function(_, n) pops = pops + (n or 1) end
T.ok(frame(), "window stays open")
T.eq(ui.state.err, nil, "empty window draws without error")
T.eq(pushes, 17, "all 17 theme colours pushed"); T.eq(pushes, pops, "colour stack balanced when open")
local real_begin = reaper.ImGui_Begin
reaper.ImGui_Begin = function() return false, true end
pushes, pops = 0, 0; frame()
T.eq(pushes, 17, "theme pushed when collapsed too"); T.eq(pops, 17, "and popped: balanced when collapsed")
reaper.ImGui_Begin = real_begin
frame()
T.ok(has_text("NO CUE SHEET"), "empty state"); T.ok(has_text("Nothing loaded yet."), "hint when nothing is loaded")

-- choose a file through the dialog
S.picked = FILE
st.clicks["Choose file..."] = true; frame()
T.eq(app.path, FILE, "Choose file... links the picked file"); T.eq(#app.doc.cues, 0, "no prefix set: 'Q 1' headers do not match bare numbers")
-- set the prefix through the text field (applies when the field is deactivated)
st.input["Cue prefix"] = "Q"; st.deact["Cue prefix"] = true
frame()
T.eq(app.cfg.prefix, "Q", "prefix applied on deactivation"); T.eq(#app.doc.cues, 2, "cues found")
pushes, pops = 0, 0
Mock.marker(5, "Q 1 Opening"); S.cursor = 6; settle(); frame()
T.eq(ui.state.err, nil, "window with cues draws without error")
T.eq(pushes, pops, "colour stack balanced with preview text")
T.ok(has_text("LIVE"), "live status"); T.ok(has_text("Opening"), "cue listed"); T.ok(has_text("mapped"), "status listed")
T.ok(has_text("> Opening") or has_text("> Q 1 Opening") or has_text("> Opening"), "current cue marked in the preview")
T.ok(has_text("Lights fade up."), "preview shows the cue text"); T.ok(has_text("- house to half"), "bullets rendered")
T.ok(has_text("  code line"), "code block rendered")
T.ok(has("Selectable:> 1##sel"), "current cue marked in the table")
T.ok(has_text("1 without a marker"), "unmapped count shown")

-- drag and drop a file
local other = os.tmpname(); Mock.write(other, "## Q 7 Dropped\nbody\n")
st.drop = other; frame()
T.eq(app.path, other, "dropping a file links it"); T.eq(app.doc.cues[1].id, "7", "and loads it")
st.drop = FILE; frame(); os.remove(other)
settle()

-- cue row: click goes to the marker; Set creates a missing one
st.clicks["row:1"] = true; frame()
T.eq(S.cursor, 5, "clicking a mapped cue moves the cursor")
st.clicks["Set"] = true; S.cursor = 20; frame()           -- the first row's Set: moves its marker
T.eq(Mock.marker_named("Q 1 Opening").pos, 20, "Set button moves the marker to the cursor")
Mock.marker(30, "Q 2 Storm"); settle(); frame()
st.clicks["Clear"] = true; frame(); settle()
T.eq(app.rows[1].status, "unmapped", "Clear button removes the marker")

-- orphans
Mock.marker(40, "Q 9 Old"); settle(); frame()
T.ok(has_text("Orphan markers (1)"), "orphan section"); T.ok(has_text("Q 9 Old"), "orphan listed")
st.clicks["row:1"] = true; frame()                          -- select the unmapped cue
st.clicks["Remap"] = true; frame(); settle()
T.eq(app.rows[1].status, "mapped", "Remap hands the orphan marker to the selected cue")
Mock.marker(41, "Q 8 Stray"); settle(); frame()
st.clicks["Delete"] = true; frame(); settle()
T.eq(#app.orphans, 0, "Delete removes the orphan marker")

-- toggles and radios
st.clicks["Show the cue text on a comment track"] = true; frame(); settle()
T.eq(app.cfg.comments, true, "comment checkbox"); T.ok(Mock.track_named("Cues") ~= nil, "and the track appears")
-- colour controls
T.ok(has_call("Selectable:") and app.cfg.comment_color_on, "colour controls are shown while colouring is on")
st.clicks["swatch:swatch2"] = true; frame(); settle()
T.eq(app.cfg.comment_color, 0x3FA7D6, "clicking a swatch picks that colour"); T.eq(Mock.track_named("Cues").vals.I_CUSTOMCOLOR ~= 0, true, "and the track is coloured")
st.input["Colour"] = 0x112233; frame(); T.eq(app.cfg.comment_color, 0x112233, "the colour editor picks any colour")
st.clicks["Colour the track and its items"] = true; frame(); T.eq(app.cfg.comment_color_on, false, "checkbox switches colouring off")
st.clicks["swatch:swatch1"] = true; frame()
T.eq(app.cfg.comment_color_on, false, "swatches are hidden while colouring is off (click ignored)")
st.clicks["swatch:swatch1"] = nil
st.clicks["Colour the track and its items"] = true; frame(); T.eq(app.cfg.comment_color_on, true, "and back on")
st.clicks["Prompter"] = true; frame()
T.eq(app.cfg.prompter, true, "prompter checkbox"); T.eq(ui.state.err, nil, "prompter draws"); T.ok(has_text("Waiting for the first cue...") or has_text("NEXT"), "prompter content")
S.cursor = 35; settle(); frame()      -- Storm is at 30, Opening was remapped to 40
T.ok(has_text("Q 2 Storm"), "prompter shows the current cue"); T.ok(has_text("NEXT  Q 1 Opening"), "and the next one")
T.ok(has_text("SFX: thunder"), "with its text")
st.clicks["Prompter"] = true; frame()
st.radio["Manual"] = true; frame(); T.eq(app.cfg.sync_mode, "manual", "sync mode radio")
st.radio["Playhead"] = true; st.radio["Edit cursor"] = true; frame(); T.eq(app.cfg.follow, "cursor", "follow radio")
st.radio["Separate sync steps"] = true; frame(); T.eq(app.cfg.undo_mode, "steps", "undo radio")
st.radio["Delete the track"] = true; frame(); T.eq(app.cfg.comment_off, "delete", "comment-off radio")
st.input["lines of each cue"] = 5; frame(); T.eq(app.cfg.comment_lines, 5, "lines input")
st.input["lines of each cue"] = 500; frame(); T.eq(app.cfg.comment_lines, 50, "lines input is clamped")
st.input["from"] = 3; frame(); T.eq(app.cfg.min_level, 3, "min level"); T.eq(app.cfg.max_level, 6, "max level untouched")
st.input["to"] = 2; frame(); T.eq(app.cfg.max_level, 2, "max level"); T.eq(app.cfg.min_level, 2, "min follows when it would exceed max")
app:set("min_level", 1); app:set("max_level", 6)

-- manual mode: Pull / Keep mine appear when the file changed
Mock.write(FILE, MD .. "\n## Q 3 Added\nnew\n"); Mock.tick(2); settle(); Mock.tick(2); settle(); frame()
T.eq(app.status, "changed", "changed file noticed"); T.ok(has_text("CHANGED ON DISK"), "status shown")
T.ok(has("Button:Pull") and has("Button:Keep mine"), "Pull and Keep mine offered")
st.clicks["Pull"] = true; frame(); T.eq(#app.doc.cues, 3, "Pull button adopts the file")
frame(); T.ok(not has("Button:Pull"), "Pull gone again")
app:set("sync_mode", "source")

-- freeze
st.clicks["Freeze"] = true; frame(); T.eq(app.cfg.live, false, "Freeze button"); frame()
T.ok(has_text("FROZEN - markers and comment items are left alone"), "frozen state shown"); T.ok(has("Button:Go live"), "Go live offered")
st.clicks["Go live"] = true; frame(); T.eq(app.cfg.live, true, "Go live")

-- detach, missing file
st.clicks["Detach"] = true; frame(); T.eq(app.path, "", "Detach button"); frame(); T.ok(has_text("LOCAL COPY"), "local copy status")
os.remove(FILE)
st.input["File"] = FILE; frame(); st.clicks["Load"] = true; frame()
T.ok(app.msg:find("Cannot read", 1, true) ~= nil, "loading a missing path says why"); T.ok(has_text("Cannot read"), "message shown in the window")

T.done("test_ui")
