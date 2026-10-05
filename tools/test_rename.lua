-- tools/rename.lua on a COPY of the project: rename it three times, run every other test after each hop, then rename back
-- and check that all files are byte-identical to the original. Also covers the dry run and bad names.
package.path = "./tools/?.lua;" .. package.path
local T = require("t")
local interpreter = arg and arg[-1] or "lua"
local P = dofile("tools/project.lua")

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function sh(cmd) local p = assert(io.popen(cmd .. " 2>&1")); local out = p:read("a"); p:close(); return out end
local function ok(cmd) return os.execute(cmd .. " > /dev/null 2>&1") == true end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end

-- the names used for the hops are assembled, never written out, so tools/rename.lua does not rewrite them inside this file
local function join(...) return table.concat({ ... }) end
local N1, S1 = join("Que", "Sheet"), join("que", "-", "sheet")
local N2, S2 = join("Cue", "Deck"), join("cue", "-", "deck")
local N3 = join("Deck", "Track")
local X1, X2, X3 = join("Q", "S"), join("CK", "D"), join("D", "T")      -- the module prefixes

-- the name the project had before the current one (still used by old projects): read from the project itself
local LEGACY = io.open("src/" .. P.prefix .. "Reaper.lua"):read("a"):match('section%s*=%s*"([^"]+)"')
assert(LEGACY, "no legacy section found in the Reaper module")

local tmp = os.tmpname(); os.remove(tmp)
os.execute("mkdir -p " .. q(tmp))
local work = tmp .. "/" .. P.slug
os.execute("mkdir -p " .. q(work) .. " && cp -R ./. " .. q(work) .. "/ && rm -rf " .. q(work .. "/dist"))
local function run(dir, args) return sh("cd " .. q(dir) .. " && " .. q(interpreter) .. " tools/rename.lua " .. args) end
local function same_as_original(dir) return ok("diff -r -x dist -x project.lua " .. q(".") .. " " .. q(dir)) end

-- bad input changes nothing
local out = run(work, "x")
T.ok(out:find("PascalCase", 1, true) ~= nil, "a too short name is refused")
T.ok(run(work, "lowercase"):find("PascalCase", 1, true) ~= nil, "a lower-case name is refused")
T.ok(run(work, "Fine --prefix abc"):find("prefix must be", 1, true) ~= nil, "a lower-case prefix is refused")
T.ok(run(work, "Fine --nope"):find("unknown option", 1, true) ~= nil, "an unknown option is refused")
T.ok(run(work, P.name):find("nothing to do", 1, true) ~= nil, "renaming to the current name does nothing")
T.ok(same_as_original(work), "refused renames changed nothing")

-- dry run
out = run(work, "DryRunName --dry-run")
T.ok(out:find("dry run: " .. P.name .. " -> DryRunName", 1, true) ~= nil, "dry run reports the rename")
T.ok(same_as_original(work), "dry run changed nothing"); T.ok(exists(work .. "/src/" .. P.prefix .. "App.lua"), "dry run renamed no file")

-- three hops (the folder is renamed with the project, as it would be for a user)
local function hop(dir, args, newname, prefix, slug)
  out = run(dir, args)
  T.ok(out:find("no leftovers", 1, true) ~= nil, newname .. ": no leftovers (" .. (out:match("leftover[^\n]*") or "") .. ")")
  T.ok(not out:find("WARNING", 1, true), newname .. ": no warnings")
  local root = dir:match("^(.*)/[^/]+$") .. "/" .. slug
  T.ok(exists(root .. "/tools/project.lua"), newname .. ": project folder moved to " .. slug)
  local p = dofile(root .. "/tools/project.lua")
  T.eq(p.name, newname, newname .. ": project.lua name"); T.eq(p.prefix, prefix, newname .. ": project.lua prefix")
  T.ok(exists(root .. "/src/" .. prefix .. "App.lua") and exists(root .. "/src/" .. newname .. ".lua"), newname .. ": source files renamed")
  T.ok(exists(root .. "/dist/" .. newname .. ".lua"), newname .. ": bundle rebuilt under the new name")
  T.ok(exists(root .. "/src/" .. P.prefix .. "App.lua") == (prefix == P.prefix), newname .. ": no file with the old prefix left")
  for _, t in ipairs({ "test_core", "test_sync", "test_ui", "test_bundle", "test_probe" }) do
    local res = sh("cd " .. q(root) .. " && " .. q(interpreter) .. " tools/" .. t .. ".lua")
    T.ok(res:find(" 0 failed", 1, true) ~= nil, newname .. ": " .. t .. " passes after the rename (" .. res:gsub("\n", " "):sub(1, 120) .. ")")
  end
  return root
end

local d1 = hop(work, N1, N1, X1, S1)
local d2 = hop(d1, N2 .. " --prefix " .. X2, N2, X2, S2)
-- the legacy lines keep the names old projects and old installs use, through every hop
local rep = io.open(d2 .. "/src/" .. X2 .. "Reaper.lua"):read("a")
T.ok(rep:find('section   = "' .. LEGACY .. '"', 1, true) ~= nil, "legacy section name survives the renames")
T.ok(rep:find('local SEC = "' .. N2 .. '"', 1, true) ~= nil, "the current section name follows the rename")
T.ok(io.open(d2 .. "/install_mac.sh"):read("a"):find(LEGACY, 1, true) ~= nil, "the installer still knows the old install")
local d3 = hop(d2, N3 .. " --keep-root", N3, X3, S2)      -- --keep-root: the folder keeps its name
local back = hop(d3, P.name .. " --prefix " .. P.prefix .. " --slug " .. P.slug .. " --keep-root", P.name, P.prefix, S2)
T.ok(same_as_original(back), "renaming back gives back every file, byte for byte")

os.execute("rm -rf " .. q(tmp))
T.done("test_rename")
