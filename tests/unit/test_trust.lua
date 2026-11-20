package.path = "./lib/?.lua;./tests/unit/?.lua;" .. package.path
local stubs = require("stubs")
local mise = require("mise")

local function eq(a, b, label)
    if a ~= b then error((label or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local settings = {
    trusted_config_paths = {}, ignored_config_paths = {}, paranoid = false,
}
local records = { trusted = {}, ignored = {}, hashes = {} }
mise.settings = function() return settings end
mise.records = function() return records end

local opts = {}
local ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "untrusted default")
eq(reason, "not trusted", "untrusted reason")

records.trusted = { "/work/proj" }
ok = mise.is_trusted("/work/proj/sub", "/work/proj/sub/.envrc", opts)
eq(ok, true, "directory trust covers child")
records.trusted = {}

settings.trusted_config_paths = { "~/work" }
os.getenv = function(k) if k == "HOME" then return "/home/u" end return nil end
ok = mise.is_trusted("/home/u/work/proj", "/home/u/work/proj/.envrc", opts)
eq(ok, true, "trusted_config_paths with tilde")
settings.trusted_config_paths = {}

settings.ignored_config_paths = { "/work" }
records.trusted = { "/work/proj" }
ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "ignore overrides trust")
eq(reason, "ignored by settings", "ignore reason")
settings.ignored_config_paths = {}
records.trusted = {}

settings.paranoid = true
records.hashes = {}
ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "paranoid needs hash")
if not tostring(reason):find("approved", 1, true) then error("paranoid reason") end

records.hashes["/work/proj/.envrc"] = "deadbeef"
stubs.cmd.exec = function() return "cafebabe  /work/proj/.envrc\n" end
ok, reason = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, false, "paranoid hash mismatch")
if not tostring(reason):find("changed", 1, true) then error("paranoid mismatch reason") end

records.hashes["/work/proj/.envrc"] = "cafebabe"
ok = mise.is_trusted("/work/proj", "/work/proj/.envrc", opts)
eq(ok, true, "paranoid hash match")

print("test_trust: ok")
