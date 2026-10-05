-- Rename the whole project: names inside the code, file names, the bundle, the installer, the docs and the folder.
--
--   lua tools/rename.lua NewName [--prefix XYZ] [--slug my-tool] [--dry-run] [--keep-root]
--
-- Run it from the project root (macOS / Linux: it uses find and mv). The current names come from tools/project.lua.
--   NewName     PascalCase, e.g. MyTool. Everything else is derived from it:
--                 prefix  initials of the words (MT)   slug  my-tool   snake  my_tool
--   --prefix    module prefix instead of the initials (2 to 4 capital letters: MTCore.lua, MTApp.lua ...)
--   --slug      folder / zip name instead of the derived one
--   --dry-run   only list what would change
--   --keep-root do not rename the project folder itself
--
-- What it rewrites:   <Name>, <slug>, <snake>, <lower> anywhere in *.lua *.sh *.md (not dist/, rebuilt afterwards)
--                     <Prefix>Version / Core / Reaper / App / UI and <Prefix>_ tags
-- What it leaves:     any line containing the marker  legacy:keep  (the old names that old projects and old installs still
--                     use, see the LEGACY table in the Reaper module and the "old install" part of the installer). If you rename
--                     again AFTER releasing under the current name, add that name to those places first.
-- Afterwards it rebuilds dist/ and lists any leftover occurrence of the old names.

local interpreter = arg and arg[-1] or "lua"

local function die(msg) io.stderr:write("rename: " .. msg .. "\n"); os.exit(1) end
local function esc(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
local function sh(cmd) local p = assert(io.popen(cmd)); local out = p:read("a"); p:close(); return out end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function read(p) local f = assert(io.open(p, "rb"), "cannot read " .. p); local s = f:read("a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb"), "cannot write " .. p); f:write(s); f:close() end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end

---------------------------------------------------------------------------------------------------------- arguments
if not exists("tools/project.lua") then die("run this from the project root (tools/project.lua not found)") end
local old = dofile("tools/project.lua")
local new_name, opts = nil, {}
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--dry-run" or a == "--keep-root" then opts[a:sub(3)] = true
    elseif a == "--prefix" or a == "--slug" then i = i + 1; opts[a:sub(3)] = arg[i] or die(a .. " needs a value")
    elseif a:sub(1, 2) == "--" then die("unknown option " .. a)
    elseif not new_name then new_name = a
    else die("unexpected argument " .. a) end
    i = i + 1
  end
end
if not new_name then die("usage: lua tools/rename.lua NewName [--prefix XYZ] [--slug my-tool] [--dry-run] [--keep-root]") end
if not new_name:match("^%u[%a%d]+$") or #new_name < 3 then die("the name must be PascalCase letters/digits, e.g. MyTool (got '" .. new_name .. "')") end

local words = {}
for w in new_name:gmatch("%u[%l%d]*") do words[#words + 1] = w end
local initials = {}
for _, w in ipairs(words) do initials[#initials + 1] = w:sub(1, 1) end
local new = { name = new_name }
local same = new_name == old.name           -- same name: keep the existing prefix and slug unless told otherwise
new.prefix = opts.prefix or (same and old.prefix) or table.concat(initials)
new.slug = opts.slug or (same and old.slug) or table.concat(words, "-"):lower()
new.snake = (new.slug:gsub("-", "_"))
new.lower = new_name:lower()
if not new.prefix:match("^%u%u%u?%u?$") then die("the prefix must be 2 to 4 capital letters (got '" .. new.prefix .. "'); pass --prefix") end
if not new.slug:match("^[%l%d%-]+$") then die("the slug must be lower-case letters, digits and dashes (got '" .. new.slug .. "')") end

if new.name == old.name and new.prefix == old.prefix and new.slug == old.slug then print("rename: already called " .. old.name .. " - nothing to do"); os.exit(0) end

---------------------------------------------------------------------------------------------------------- text rewriting
local prefix_pat = "%f[%w]" .. esc(old.prefix) .. "([%u_])"       -- <Prefix>App, <Prefix>UI, <Prefix>_tag ...
local function conv(s)
  local n, c = 0, 0
  s, c = s:gsub(esc(old.name), function() return new.name end); n = n + c
  s, c = s:gsub(esc(old.slug), function() return new.slug end); n = n + c
  s, c = s:gsub(esc(old.snake), function() return new.snake end); n = n + c
  s, c = s:gsub(esc(old.lower), function() return new.lower end); n = n + c
  s, c = s:gsub(prefix_pat, function(ch) return new.prefix .. ch end); n = n + c
  return s, n
end

local function transform(text)
  local out, total = {}, 0
  for line, nl in text:gmatch("([^\n]*)(\n?)") do
    if not line:find("legacy:keep", 1, true) then local n; line, n = conv(line); total = total + n end
    out[#out + 1] = line .. nl
  end
  return table.concat(out), total
end

local files = {}
for f in sh("find . -type f \\( -name '*.lua' -o -name '*.sh' -o -name '*.md' \\) -not -path './dist/*' -not -path './.git/*' | sort"):gmatch("[^\n]+") do
  local rel = f:gsub("^%./", "")
  if rel ~= "tools/rename.lua" and rel ~= "tools/project.lua" then files[#files + 1] = rel end
end

local dry = opts["dry-run"]
local changed, renames = 0, {}
for _, f in ipairs(files) do
  local text = read(f)
  local out, n = transform(text)
  if n > 0 then
    changed = changed + 1
    print(string.format("  %-28s %3d replacement(s)", f, n))
    if not dry then write(f, out) end
  end
  local dir, base = f:match("^(.-)([^/]*)$")
  local nb = conv(base)
  if nb ~= base then renames[#renames + 1] = { from = f, to = dir .. nb } end
end
for _, rn in ipairs(renames) do
  print(string.format("  rename %-22s -> %s", rn.from, rn.to))
  if not dry then assert(os.rename(rn.from, rn.to), "cannot rename " .. rn.from) end
end

local oldbundle = "dist/" .. old.name .. ".lua"
if not dry and exists(oldbundle) and old.name ~= new.name then os.remove(oldbundle); print("  removed " .. oldbundle .. " (rebuilt below)") end

if not dry then
  write("tools/project.lua", string.format(
    "-- The project's names, in one place. tools/build.lua reads this file; tools/rename.lua rewrites it.\nreturn { name = %q, prefix = %q, slug = %q, snake = %q, lower = %q }\n",
    new.name, new.prefix, new.slug, new.snake, new.lower))
end
print(string.format("%s: %s -> %s  (prefix %s -> %s, slug %s -> %s): %d file(s) changed, %d renamed",
  dry and "dry run" or "renamed", old.name, new.name, old.prefix, new.prefix, old.slug, new.slug, changed, #renames))
if dry then os.exit(0) end

---------------------------------------------------------------------------------------------------------- rebuild, check, move
if os.execute(q(interpreter) .. " tools/build.lua > /dev/null") ~= true then print("WARNING: the build failed - run  lua tools/build.lua  to see why") end

-- any old name left outside the legacy lines?
local left = 0
local all = {}
for _, f in ipairs(files) do
  local dir, base = f:match("^(.-)([^/]*)$")
  all[#all + 1] = dir .. conv(base)
end
all[#all + 1] = "tools/rename.lua"
for _, f in ipairs(all) do
  if exists(f) then
    local ln = 0
    for line in (read(f) .. "\n"):gmatch("([^\n]*)\n") do
      ln = ln + 1
      if not line:find("legacy:keep", 1, true) and old.name ~= new.name then
        local hit = line:find(old.name, 1, true) or line:find(old.slug, 1, true) or line:find(old.snake, 1, true)
          or line:find(old.lower, 1, true) or line:find("%f[%w]" .. esc(old.prefix) .. "%f[%W]") or line:find(prefix_pat)
        if hit and not line:find(new.name, 1, true) then left = left + 1; print(string.format("  leftover: %s:%d: %s", f, ln, line:gsub("^%s+", ""))) end
      end
    end
  end
end
if left > 0 then print("WARNING: " .. left .. " line(s) still mention the old names (see above)") else print("no leftovers: the old names only remain on legacy:keep lines") end

if not opts["keep-root"] then
  local cwd = sh("pwd"):gsub("%s+$", "")
  local base = cwd:match("([^/]+)$")
  if base == old.slug and new.slug ~= old.slug then
    local parent = cwd:match("^(.*)/[^/]+$")
    if os.execute("cd " .. q(parent) .. " && mv " .. q(old.slug) .. " " .. q(new.slug)) == true then
      print("moved the project folder: " .. cwd .. " -> " .. parent .. "/" .. new.slug)
      print("(your shell is still in the old path: cd " .. parent .. "/" .. new.slug .. ")")
    else print("WARNING: could not rename the project folder") end
  end
end
