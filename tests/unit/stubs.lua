local NULL = {}
local stubs = {
    NULL = NULL,
    file = {
        stat = function() return nil end,
        exists = function() return false end,
        glob = function() return {} end,
        read = function() error("file.read stub") end,
        symlink = function() end,
        move = function() end,
    },
    cmd = { exec = function() return "" end },
    json = {
        decode = function(s)
            if s == "null" then return NULL end
            error("json.decode stub only handles null")
        end,
        encode = function(v) return tostring(v) end,
    },
    log = {
        debug = function() end, info = function() end,
        warn = function() end, error = function() end,
    },
}
package.loaded["file"] = stubs.file
package.loaded["cmd"] = stubs.cmd
package.loaded["json"] = stubs.json
package.loaded["log"] = stubs.log
_G.RUNTIME = { osType = "linux", cacheDirPath = "/tmp/mise-envrc-test-cache" }
return stubs
