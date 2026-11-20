local loader = require("loader")

function PLUGIN:MisePath(ctx)
    local result = loader.load_cached(ctx)
    return result.paths or {}
end
