local util = require("util")
function PLUGIN:MisePath(ctx)
    return { util.join(os.getenv("PWD") or "", "bin") }
end
