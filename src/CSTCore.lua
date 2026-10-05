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
