package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local util = require("util")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local quote = string.char(39)
local backslash = string.char(92)
eq(util.sh_quote("/a" .. quote .. "b"),
    quote .. "/a" .. quote .. backslash .. quote .. quote .. "b" .. quote,
    "sh_quote")
eq(util.trim("  x  "), "x", "trim")
eq(util.dir_of("/a/b/.envrc"), "/a/b", "dir_of")
eq(util.dir_of("/a"), "/", "dir_of root parent")
eq(util.basename("/a/b/.envrc"), ".envrc", "basename")
eq(util.join("/a", ".envrc"), "/a/.envrc", "join")
eq(util.join("/a", "lib", "*.sh"), "/a/lib/*.sh", "join three segments")
eq(util.path_prefix("/a/b", "/a/b"), true, "prefix exact")
eq(util.path_prefix("/a/b", "/a/bc"), false, "prefix boundary")
eq(util.path_prefix("/a/b", "/a/b/c"), true, "prefix child")
eq(util.expand_home("~/src", "/home/u"), "/home/u/src", "expand_home")
eq(#util.hash("/a/b"), 24, "hash length")
eq(util.hash("/a/b"), util.hash("/a/b"), "hash stable")
if util.hash("/a/b") == util.hash("/a/c") then error("hash collision") end

local dirs = util.ancestors("/a/b/c", "/a")
eq(table.concat(dirs, ","), "/a/b/c,/a/b,/a", "ancestors")
eq(table.concat(util.split("a:b::c", ":"), ","), "a,b,c", "split")

local found = util.find_up("/a/b/c", { ".envrc" }, function(p)
    return p == "/a/.envrc" and { is_file = true } or nil
end)
eq(found, "/a/.envrc", "find_up")

local seen = {}
local has = util.has_mise_config({ "/a/b" },
    function(p) seen[#seen + 1] = p; return {} end,
    function() return false end)
eq(has, false, "no mise config")
eq(#seen, 10, "glob pattern count")
local has2, where2 = util.has_mise_config({ "/a/b" },
    function() return {} end,
    function(p) return p == "/a/b/.tool-versions" end)
eq(has2, true, "tool-versions detected")
eq(where2, "/a/b", "tool-versions dir")
local has3 = util.has_mise_config({ "/a/b" },
    function(p) return p == "/a/b/mise*.toml" and { "/a/b/mise.toml" } or {} end,
    function() return false end)
eq(has3, true, "mise.toml glob detected")

local adds, bad = util.path_prepends("/old:/base", "/new1:/new2:/old:/base")
eq(bad, false, "prepends supported")
eq(table.concat(adds, ","), "/new1,/new2", "prepends value")
local _, bad2 = util.path_prepends("/old:/base", "/old:/base:/appended")
eq(bad2, true, "append unsupported")

local result = util.map_diff({
    FOO = "bar",
    GONE = stubs.NULL,
    DIRENV_DIFF = "internal",
    MISE_ENVRC_PLUGIN = "1",
    PATH = "/new:/old:/base",
}, "/old:/base", function(v) return v == stubs.NULL end,
    { env = {}, paths = {}, warnings = {} })
eq(#result.env, 1, "map_diff env count")
eq(result.env[1].key, "FOO", "map_diff key")
eq(result.paths[1], "/new", "map_diff path")
eq(#result.warnings, 1, "map_diff warning count")
if not result.warnings[1]:find("unset GONE", 1, true) then error("missing unset warning") end

print("test_util: ok")
