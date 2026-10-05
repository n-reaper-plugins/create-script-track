-- Stub of ReaImGui: records calls, returns harmless defaults.
--   clicks[label]=true   makes that button / checkbox / selectable report a click (label without the ##id part)
--   radio[label]=true    makes that radio button report a click (label without the ##id part)
--   drop = path          simulates a file dropped on the window
local M = {}
function M.install(R)
  local st = { calls = {}, clicks = {}, radio = {}, texts = {}, drop = nil, input = {}, deact = {}, last_color = {} }
  local function base(label) return (label:gsub("##.*$", ""):gsub("\n.*$", "")) end
  local special = {
    ImGui_CreateContext = function() return "ctx" end,
    ImGui_Begin = function() return true, true end,
    ImGui_BeginTable = function() return true end,
    ImGui_BeginChild = function() return true end,
    ImGui_GetContentRegionAvail = function() return 600, 400 end,
    -- st.input[label] = new text: that InputText reports a change once. st.deact[label] = true: IsItemDeactivatedAfterEdit fires
    ImGui_InputText = function(_, label, buf)
      st.last_input = base(label)
      local v = st.input[base(label)]
      if v ~= nil then st.input[base(label)] = nil; return true, v end
      return false, buf
    end,
    ImGui_InputInt = function(_, label, v)
      local nv = st.input[base(label)]
      if nv ~= nil then st.input[base(label)] = nil; return true, nv end
      return false, v
    end,
    ImGui_IsItemDeactivatedAfterEdit = function()
      local d = st.deact[st.last_input]; st.deact[st.last_input or ""] = nil; return d or false
    end,
    ImGui_Button = function(_, label)
      st.calls[#st.calls + 1] = "Button:" .. label
      if st.clicks[base(label)] then st.clicks[base(label)] = nil; return true end
      return false
    end,
    ImGui_SmallButton = function(_, label)
      st.calls[#st.calls + 1] = "SmallButton:" .. label
      if st.clicks[base(label)] then st.clicks[base(label)] = nil; return true end
      return false
    end,
    ImGui_Selectable = function(_, label)
      st.calls[#st.calls + 1] = "Selectable:" .. label
      local b = base(label):gsub("^> ", "")
      if st.clicks["row:" .. b] then st.clicks["row:" .. b] = nil; return true end
      return false
    end,
    ImGui_Checkbox = function(_, label, v)
      if st.clicks[base(label)] then st.clicks[base(label)] = nil; return true, not v end
      return false, v
    end,
    ImGui_RadioButton = function(_, label)
      if st.radio[base(label)] then st.radio[base(label)] = nil; return true end
      return false
    end,
    -- st.input[label] = 0xRRGGBB: that ColorEdit3 reports a change once. st.clicks["swatch:<id>"] clicks a ColorButton.
    ImGui_ColorEdit3 = function(_, label, v)
      local nv = st.input[base(label)]
      if nv ~= nil then st.input[base(label)] = nil; return true, nv end
      return false, v
    end,
    ImGui_ColorButton = function(_, id)
      if st.clicks["swatch:" .. id] then st.clicks["swatch:" .. id] = nil; return true end
      return false
    end,
    ImGui_Text = function(_, t) st.texts[#st.texts + 1] = t end,
    ImGui_TextWrapped = function(_, t) st.texts[#st.texts + 1] = t end,
    ImGui_TextColored = function(_, c, t) st.texts[#st.texts + 1] = t; st.last_color[t] = c end,
    ImGui_BeginDragDropTarget = function() return st.drop ~= nil end,
    ImGui_AcceptDragDropPayloadFiles = function() return true, 1 end,
    ImGui_GetDragDropPayloadFile = function() local d = st.drop; st.drop = nil; return true, d end,
  }
  setmetatable(R, { __index = function(_, k)
    if type(k) ~= "string" or not k:match("^ImGui_") then return nil end
    if special[k] then return special[k] end
    if k:match("^ImGui_%a+Flags_") or k:match("^ImGui_Cond_") then return function() return 0 end end
    return function() return false end
  end })
  return st
end
return M
