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
