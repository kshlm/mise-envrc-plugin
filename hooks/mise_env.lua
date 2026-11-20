local loader = require("loader")

function PLUGIN:MiseEnv(ctx)
    local result = loader.load(ctx, false)
    return {
        env = result.env or {},
        cacheable = false,
        watch_files = result.watch_files or {},
        redact = false,
    }
end
